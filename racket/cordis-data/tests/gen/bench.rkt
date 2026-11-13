#lang racket/base
;; Benchmark driver, not part of `raco test`: times reading and writing JSON documents of about
;; 5 MB and prints the best of several runs in milliseconds.
;;
;;   racket tests/gen/bench.rkt
;;
;; Three documents: records such as a session log holds (short keys, mixed values, text with
;; escapes), an array of full-precision doubles, and one made of long strings.

(require cordis-data)

(module test racket/base)

;; A deterministic stand-in for random numbers, so every run times the same document.
(define seed 12345)
(define (next-random! n)
  (set! seed (modulo (+ (* seed 1103515245) 12345) 2147483648))
  (modulo (quotient seed 65536) n))

(define words
  (vector "alpha" "beta" "gamma" "delta" "session" "tool_call" "arguments" "content" "assistant"
          "the quick brown fox" "line one\nline two\ttabbed" "say \"hello\"" "path\\to\\file"
          (string (integer->char #xE9) (integer->char #x4E2D) (integer->char #x1F600))))

(define (random-word)
  (vector-ref words (next-random! (vector-length words))))

(define (random-text count)
  (apply string-append (for/list ([_ (in-range count)]) (string-append (random-word) " "))))

(define (make-record index)
  (jobject 'id index
           'type (random-word)
           'timestamp (+ 1700000000000 (* index 1000))
           'score (/ (next-random! 1000000) 1000.0)
           'ratio (exact->inexact (/ (+ 1 (next-random! 999983)) 999983))
           'ok (even? (next-random! 2))
           'parent (if (zero? (next-random! 3)) 'null (next-random! 100000))
           'tags (for/list ([_ (in-range (next-random! 5))]) (random-word))
           'message (jobject 'role "assistant"
                             'content (random-text (+ 3 (next-random! 12)))
                             'usage (jobject 'input (next-random! 5000)
                                             'output (next-random! 800)))))

;; A list of `make-item` results whose compact JSON text is at least `target` characters.
(define (build-document make-item target)
  (let loop ([items '()] [size 0] [index 0])
    (if (>= size target)
        (reverse items)
        (let ([item (make-item index)])
          (loop (cons item items)
                (+ size 1 (string-length (jvalue->string item)))
                (add1 index))))))

;; Best wall-clock time of `runs` calls, in milliseconds, after a garbage collection.
(define (best-ms thunk [runs 7])
  (for/fold ([best +inf.0]) ([_ (in-range runs)])
    (collect-garbage)
    (define start (current-inexact-milliseconds))
    (thunk)
    (min best (- (current-inexact-milliseconds) start))))

(define (report name doc)
  (define text (jvalue->string doc))
  (define bytes (string->bytes/utf-8 text))
  (define indented (jvalue->string doc #:indent 2))
  (printf "~a: ~a characters, ~a bytes as UTF-8\n" name (string-length text) (bytes-length bytes))
  (define (row label thunk)
    (printf "  ~a ~a ms\n" label (real->decimal-string (best-ms thunk) 1)))
  (row "jvalue->string           " (lambda () (jvalue->string doc)))
  (row "jvalue->string #:indent 2" (lambda () (jvalue->string doc #:indent 2)))
  (row "jvalue->bytes            " (lambda () (jvalue->bytes doc)))
  (row "write-jvalue (bytes port)" (lambda () (write-jvalue doc (open-output-bytes))))
  (row "string->jvalue           " (lambda () (string->jvalue text)))
  (row "string->jvalue (indented)" (lambda () (string->jvalue indented)))
  (row "bytes->jvalue            " (lambda () (bytes->jvalue bytes)))
  (row "read-jvalue (bytes port) " (lambda () (read-jvalue (open-input-bytes bytes))))
  (unless (deep-equal? (string->jvalue text) doc #:strict? #t)
    (error 'bench "~a does not round-trip" name)))

(module+ main
  (define target 5000000)
  (report "records" (build-document make-record target))
  (report "doubles"
          (build-document (lambda (index)
                            (* (- (next-random! 2000001) 1000000.0)
                               (exact->inexact (/ (+ 1 (next-random! 999983)) 7919))))
                          target))
  (report "long strings" (build-document (lambda (index) (random-text 400)) target)))
