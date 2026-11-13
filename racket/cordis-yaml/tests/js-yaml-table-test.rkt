#lang racket/base
;; Differential test against js-yaml and Node: every row of tests/data/js-yaml-table.rktd holds
;; a result that js-yaml 4.3.2 computed with the dsh schema (load, loadAll, dump) or that Node
;; computed for an expression under `with (ctx) { return eval(expr) }`, and cordis-yaml must
;; produce the same. Regenerate the table with tests/gen/gen-js-yaml-table.mjs; this test needs
;; neither Node nor the network. The corpus rows are checked by corpus-test.rkt.

(require rackunit
         racket/list
         racket/match
         racket/string
         cordis-yaml
         cordis-yaml/js-expr
         "support/environment.rkt"
         "support/table.rkt")

(define table (load-table))

(define failures '())
(define (fail! section what expected actual)
  (set! failures
        (cons (format "~a ~s\n  expected: ~s\n  actual:   ~s" section what expected actual)
              failures)))

(define (report-failures! section)
  (define mine (filter (lambda (f) (string-prefix? f (symbol->string section))) failures))
  (for ([failure (in-list (reverse mine))] [_ (in-range 15)])
    (eprintf "~a\n" failure))
  (length mine))

;; ---------------------------------------------------------------------------------------------
;; load

;; The outcome of reading, in the table's result form.
(define (read-outcome thunk)
  (with-handlers ([exn:fail:yaml?
                   (lambda (e)
                     (list 'error (exn:fail:yaml-reason e) (exn:fail:yaml-line e)
                           (exn:fail:yaml-column e) (exn:fail:yaml-position e) (exn-message e)))])
    (list 'ok (thunk))))

(define (check-load-rows! section read)
  (for ([row (in-list (table-rows table section))])
    (match-define (list text expected) row)
    (define actual
      (match (read-outcome (lambda () (read text)))
        [(list 'ok value) (list 'ok (value->datum value #:js-order? #t))]
        [outcome outcome]))
    (unless (same-datum? actual expected)
      (fail! section text expected actual))))

(test-case "yaml-read agrees with js-yaml load on every hand-written text"
  (check-load-rows! 'load (lambda (text) (yaml-read text)))
  (check-equal? (report-failures! 'load) 0)
  (check-true (>= (length (table-rows table 'load)) 800)))

(test-case "yaml-read reports the source name as js-yaml reports its filename option"
  (check-load-rows! 'load-named (lambda (text) (yaml-read text #:source "conf/cordis.yml")))
  (check-equal? (report-failures! 'load-named) 0))

(test-case "yaml-read reads the texts js-yaml writes in its other styles"
  (check-load-rows! 'load-styled (lambda (text) (yaml-read text)))
  (check-equal? (report-failures! 'load-styled) 0)
  (check-true (>= (length (table-rows table 'load-styled)) 300)))

(test-case "yaml-read-all agrees with js-yaml loadAll"
  (check-load-rows! 'load-all (lambda (text) (yaml-read-all text)))
  (check-equal? (report-failures! 'load-all) 0))

(test-case "the json schema agrees with js-yaml's JSON_SCHEMA"
  (check-load-rows! 'load-json (lambda (text) (yaml-read text #:schema 'json)))
  (check-equal? (report-failures! 'load-json) 0))

;; ---------------------------------------------------------------------------------------------
;; dump

(test-case "yaml->string writes the text js-yaml dump writes"
  (for ([row (in-list (table-rows table 'dump))])
    (match-define (list value width expected) row)
    (define actual
      (with-handlers ([exn:fail? (lambda (e) (list 'raised (exn-message e)))])
        (yaml->string (datum->value value) #:line-width width)))
    (unless (equal? actual expected)
      (fail! 'dump (list value width) expected actual)))
  (check-equal? (report-failures! 'dump) 0)
  (check-true (>= (length (table-rows table 'dump)) 2000)))

;; ---------------------------------------------------------------------------------------------
;; eval

(define environments
  (for/hasheq ([row (in-list (table-rows table 'environments))])
    (values (car row) (cons (cdr row) (table-environment (cdr row))))))

(define (environment name) (cdr (hash-ref environments name)))
(define (environment-field name key) (cadr (assq key (car (hash-ref environments name)))))

;; The outcome of evaluating, in the table's result form; the name of a JavaScript error is
;; the text before the first colon of the message.
(define (eval-outcome source env)
  (with-handlers ([exn:fail:js-expr:unsupported?
                   (lambda (e) (list 'unsupported (exn:fail:js-expr:unsupported-construct e)))]
                  [exn:fail:js-expr:syntax? (lambda (e) (list 'error "SyntaxError"))]
                  [exn:fail:js-expr?
                   (lambda (e) (list 'error (car (regexp-match #rx"^[A-Za-z]+" (exn-message e)))))]
                  [exn:fail? (lambda (e) (list 'raised (exn-message e)))])
    (list 'ok (value->datum (js-eval source env)))))

;; Node applies its Windows path algorithms on win32; this package raises unsupported there.
(define (windows-path-row? source env-name)
  (and (equal? (environment-field env-name 'platform) "win32")
       (regexp-match? #rx"getBuiltinModule[(]'node:path'[)]" source)))

(test-case "js-eval agrees with Node on every expression of the table"
  (define windows-path-rows 0)
  (for ([row (in-list (table-rows table 'eval))])
    (match-define (list source env-name kind expected) row)
    (define actual (eval-outcome source (environment env-name)))
    (define same?
      (match* (actual expected)
        [((list 'ok a) (list 'ok b)) (same-datum? a b)]
        [((list 'error a) (list 'error b _)) (equal? a b)]
        [((list 'unsupported _) _)
         (and (windows-path-row? source env-name)
              (set! windows-path-rows (add1 windows-path-rows))
              #t)]
        [(_ _) #f]))
    (unless same?
      (fail! 'eval (list source env-name kind) expected actual)))
  (check-equal? (report-failures! 'eval) 0)
  ;; The corpus has five distinct expressions that use node:path.
  (check-equal? windows-path-rows 5)
  (check-true (>= (length (table-rows table 'eval)) 2500)))

(test-case "every corpus expression is in the table under every environment"
  (define sources (map car (table-rows table 'corpus-expressions)))
  (check-equal? (length sources) 106)
  (for ([env-name (in-hash-keys environments)])
    (define evaluated
      (for/list ([row (in-list (table-rows table 'eval))]
                 #:when (and (eq? (second row) env-name) (eq? (third row) 'corpus)))
        (first row)))
    (check-equal? (sort evaluated string<?) (sort sources string<?))))

(test-case "text that Node rejects with SyntaxError raises exn:fail:js-expr:syntax"
  (for ([source (in-list (table-rows table 'syntax-error))])
    (define actual (eval-outcome source (environment 'snapshot)))
    (unless (equal? actual '(error "SyntaxError"))
      (fail! 'syntax-error source '(error "SyntaxError") actual)))
  (check-equal? (report-failures! 'syntax-error) 0)
  (check-true (>= (length (table-rows table 'syntax-error)) 150)))

(test-case "JavaScript outside the subset raises exn:fail:js-expr:unsupported"
  (for ([source (in-list (table-rows table 'unsupported))])
    (define actual (eval-outcome source (environment 'snapshot)))
    (unless (eq? (car actual) 'unsupported)
      (fail! 'unsupported source 'unsupported actual)))
  (check-equal? (report-failures! 'unsupported) 0)
  (check-true (>= (length (table-rows table 'unsupported)) 200)))
