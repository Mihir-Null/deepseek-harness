#lang racket/base
;; Tests for dsh-util/partial-json. The first part replays tests/data/partial-json-table.json,
;; which records the answers of dsh `PartialArguments` for scripted reads over chunked argument
;; text (tests/gen/gen-partial-json.mjs produced it from the TypeScript source). The second part
;; mirrors cases of packages/util/values/tests/partial-json.spec.ts that the table cannot state:
;; sealing, laziness, change detection granularity, and the surrogate rules of this port.

(require rackunit
         racket/runtime-path
         racket/port
         cordis-data
         dsh-util/partial-json)

(define-runtime-path table-path "data/partial-json-table.json")

(define table (call-with-input-file table-path (lambda (in) (string->jvalue (port->string in)))))
(define undefined-marker (jref table 'undefined))

(define (expected->racket v)
  (if (equal? v undefined-marker) #f v))

;; Applies one recorded read and returns its answer in the table's terms.
(define (run-read view op)
  (define kind (car op))
  (define (arg n) (list-ref op n))
  (case kind
    [("closed") (partial-arguments-closed? view)]
    [("keys") (map symbol->string (partial-arguments-keys view))]
    [("has") (partial-arguments-has? view (arg 1))]
    [("complete") (partial-arguments-complete? view (arg 1))]
    [("length") (partial-arguments-string-length view (arg 1) #:step (arg 2) #:offset (arg 3))]
    [("exceeds") (partial-arguments-string-exceeds? view (arg 1) (arg 2))]
    [("text") (partial-arguments-text view (arg 1))]
    [("prefix") (partial-arguments-text-prefix view (arg 1) (arg 2))]
    [("value") (partial-arguments-value view (arg 1) undefined-marker)]
    [("invalid") (partial-arguments-invalid? view)]
    [("sealed") (partial-arguments-sealed? view)]
    [("refresh") (partial-arguments-refresh! view)]
    [else (error 'run-read "unknown op ~s" op)]))

(test-case "answers match dsh PartialArguments for every recorded scenario"
  (for ([scenario (in-list (jref table 'scenarios))])
    (define name (jref scenario 'name))
    (define view (make-partial-arguments))
    (for ([step (in-list (jref scenario 'steps))] [index (in-naturals)])
      (define op (jref step 'op))
      (define kind (car op))
      (cond
        [(equal? kind "append") (partial-arguments-append! view (cadr op))]
        [(equal? kind "from-text") (set! view (partial-arguments-from-text (cadr op)))]
        [(equal? kind "from-object") (set! view (partial-arguments-from-object (cadr op)))]
        [(equal? kind "settle")
         (define settled (partial-arguments-settle! view (cadr op)))
         (check-equal? (eq? settled view) (jref step 'result) (format "~a step ~a settle" name index))
         (set! view settled)]
        [else
         (define expected (jref step 'result))
         (define actual (run-read view op))
         (define ok?
           (if (equal? kind "value")
               (deep-equal? actual expected #:strict? #t)
               (equal? actual (expected->racket expected))))
         (unless ok?
           (fail-check (format "~a step ~a ~s: expected ~s, got ~s" name index op expected actual)))]))))

(test-case "reports sealing independently of object closure and refuses appends"
  (define view (make-partial-arguments))
  (check-false (partial-arguments-sealed? view))
  (partial-arguments-append! view "{\"a\":1}")
  (check-false (partial-arguments-sealed? view))
  (define sealed (partial-arguments-from-text "{\"a\":"))
  (check-true (partial-arguments-sealed? sealed))
  (check-true (partial-arguments-closed? sealed))
  (check-exn #rx"PartialArguments: cannot append to a sealed view"
             (lambda () (partial-arguments-append! sealed "1}")))
  (check-exn #rx"cannot append to a sealed view"
             (lambda () (partial-arguments-append! partial-arguments-empty "{}"))))

(test-case "the empty view answers every reader with absence"
  (define view partial-arguments-empty)
  (check-equal? (partial-arguments-keys view) '())
  (check-false (partial-arguments-has? view 'a))
  (check-false (partial-arguments-text view 'a))
  (check-false (partial-arguments-string-length view 'a))
  (check-eq? (partial-arguments-value view 'a 'none) 'none)
  (check-false (partial-arguments-refresh! view)))

(test-case "a parsed object answers from its fields; a value that is not an object has none"
  (define view (partial-arguments-from-object (jobj ['path "a.ts"] ['n 1] ['flag #f])))
  (check-equal? (partial-arguments-keys view) '(path n flag))
  (check-equal? (partial-arguments-text view "path") "a.ts")
  (check-equal? (partial-arguments-value view 'n) 1)
  (check-eq? (partial-arguments-value view 'flag 'none) #f)
  (check-eq? (partial-arguments-value view 'path 'none) 'none)
  (check-equal? (partial-arguments-keys (partial-arguments-from-object '(1 2))) '())
  (check-equal? (partial-arguments-keys (partial-arguments-from-object (hash 'b 1 'a 2))) '(a b)))

(test-case "a length read reports a change only when its rounded-up step moves"
  (define view (make-partial-arguments))
  (partial-arguments-append! view "{\"content\":\"")
  (check-equal? (partial-arguments-string-length view 'content #:step 4) 0)
  (partial-arguments-append! view "abc")
  (check-true (partial-arguments-refresh! view))    ; 0 -> ceiling(3/4) = 1
  (partial-arguments-append! view "d")
  (check-false (partial-arguments-refresh! view))   ; ceiling(4/4) = 1
  (partial-arguments-append! view "e")
  (check-true (partial-arguments-refresh! view))    ; ceiling(5/4) = 2
  (check-equal? (partial-arguments-string-length view 'content #:step 4) 5))

(test-case "a text read reports every decoded character and a bounded prefix stops at its limit"
  (define view (make-partial-arguments))
  (partial-arguments-append! view "{\"t\":\"ab")
  (check-equal? (partial-arguments-text view 't) "ab")
  (check-equal? (partial-arguments-text-prefix view 't 3) "ab")
  (check-false (partial-arguments-refresh! view))
  (partial-arguments-append! view "c")
  (check-true (partial-arguments-refresh! view))
  (partial-arguments-append! view "d")
  (check-true (partial-arguments-refresh! view))
  (check-equal? (partial-arguments-text-prefix view 't 3) "abc")
  (check-equal? (partial-arguments-text view 't) "abcd"))

(test-case "a surrogate pair of two escapes is one character counted as two UTF-16 units"
  (define face (string (integer->char #x1F600)))
  (define view (partial-arguments-from-text "{\"e\":\"a\\ud83d\\ude00b\"}"))
  (check-equal? (partial-arguments-text view 'e) (string-append "a" face "b"))
  (check-equal? (partial-arguments-string-length view 'e) 4)
  ;; a cut inside the pair ends before it
  (check-equal? (partial-arguments-text-prefix view 'e 2) "a")
  (check-equal? (partial-arguments-text-prefix view 'e 3) (string-append "a" face))
  (check-true (partial-arguments-string-exceeds? view 'e 2))
  (check-true (partial-arguments-string-exceeds? view 'e 3))
  (check-false (partial-arguments-string-exceeds? view 'e 4)))

(test-case "an escaped high surrogate is held back until the next escape is known"
  (define face (string (integer->char #x1F600)))
  (define view (make-partial-arguments))
  (partial-arguments-append! view "{\"e\":\"a\\ud83d")
  (check-equal? (partial-arguments-text view 'e) "a")
  (partial-arguments-append! view "\\ude")
  (check-equal? (partial-arguments-text view 'e) "a")
  (partial-arguments-append! view "00")
  (check-equal? (partial-arguments-text view 'e) (string-append "a" face))
  (define lone (make-partial-arguments))
  (partial-arguments-append! lone "{\"e\":\"a\\ud83dz")
  (check-equal? (partial-arguments-text lone 'e) (string #\a (integer->char #xFFFD) #\z)))

(test-case "settling matching text seals the view and keeps what was read"
  (define view (make-partial-arguments))
  (partial-arguments-append! view "{\"a\":\"x")
  (check-equal? (partial-arguments-text view 'a) "x")
  (partial-arguments-append! view "y\"}")
  (define settled (partial-arguments-settle! view "{\"a\":\"xy\"}"))
  (check-eq? settled view)
  (check-true (partial-arguments-sealed? settled))
  (check-equal? (partial-arguments-text settled 'a) "xy")
  (define other (make-partial-arguments))
  (partial-arguments-append! other "{\"a\":\"x")
  (define replaced (partial-arguments-settle! other "{\"a\":\"z\"}"))
  (check-false (eq? replaced other))
  (check-equal? (partial-arguments-text replaced 'a) "z"))
