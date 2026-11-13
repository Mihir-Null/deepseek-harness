#lang racket/base
;; Provides `check-section`, which compares cordis-yaml with the rows of one section of a
;; differential table written by tests/gen/gen-js-yaml-table.mjs, and returns one description
;; per row that differs. The expected results in the table come from js-yaml and Node.

(require racket/list
         racket/match
         cordis-yaml
         cordis-yaml/js-expr
         "environment.rkt"
         "table.rkt")

(provide check-section
         windows-path-row?)

(define (failure section what expected actual)
  (format "~a ~s\n  expected: ~s\n  actual:   ~s" section what expected actual))

;; The outcome of reading, in the table's result form.
(define (read-outcome thunk)
  (with-handlers ([exn:fail:yaml?
                   (lambda (e)
                     (list 'error (exn:fail:yaml-reason e) (exn:fail:yaml-line e)
                           (exn:fail:yaml-column e) (exn:fail:yaml-position e) (exn-message e)))]
                  [exn:fail? (lambda (e) (list 'raised (exn-message e)))])
    (list 'ok (value->datum (thunk) #:js-order? #t))))

(define (check-load-rows section rows read)
  (for*/list ([row (in-list rows)]
              [actual (in-value (read-outcome (lambda () (read (first row)))))]
              #:unless (same-datum? actual (second row)))
    (failure section (first row) (second row) actual)))

(define (check-dump-rows rows)
  (for*/list ([row (in-list rows)]
              [actual (in-value
                       (with-handlers ([exn:fail? (lambda (e) (list 'raised (exn-message e)))])
                         (yaml->string (datum->value (first row)) #:line-width (second row))))]
              #:unless (equal? actual (third row)))
    (failure 'dump (list (first row) (second row)) (third row) actual)))

;; For these values js-yaml writes a text that js-yaml does not read back; the writer must
;; write another one, which reads back.
(define (check-unstable-dump-rows rows)
  (for*/list ([row (in-list rows)]
              [value (in-value (datum->value (first row)))]
              [text (in-value (yaml->string value #:line-width (second row)))]
              [back (in-value
                     (with-handlers ([exn:fail? (lambda (e) (list 'raised (exn-message e)))])
                       (yaml-read text)))]
              #:unless (and (not (equal? text (third row)))
                            (equal? back (jvalue->yaml-value value))))
    (failure 'dump-unstable (list (first row) (second row)) value (list text back))))

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

(define (environment-fields table name)
  (cdr (assq name (table-rows table 'environments))))

;; windows-path-row? : hash? list? -> boolean?
;; Whether an eval row uses node:path under a win32 environment, where Node applies its
;; Windows path algorithms and this package raises unsupported.
(define (windows-path-row? table row)
  (and (equal? (cadr (assq 'platform (environment-fields table (second row)))) "win32")
       (regexp-match? #rx"getBuiltinModule[(]'node:path'[)]" (first row))))

(define (check-eval-rows table rows)
  (define environments (make-hasheq))
  (define (environment name)
    (hash-ref! environments name (lambda () (table-environment (environment-fields table name)))))
  (for*/list ([row (in-list rows)]
              [actual (in-value (eval-outcome (first row) (environment (second row))))]
              #:unless (match* (actual (fourth row))
                         [((list 'ok a) (list 'ok b)) (same-datum? a b)]
                         [((list 'error a) (list 'error b _)) (equal? a b)]
                         [((list 'unsupported _) _) (windows-path-row? table row)]
                         [(_ _) #f]))
    (failure 'eval (take row 3) (fourth row) actual)))

(define (check-rejection-rows table section rows accepted?)
  (define env (table-environment (environment-fields table 'snapshot)))
  (for*/list ([source (in-list rows)]
              [actual (in-value (eval-outcome source env))]
              #:unless (accepted? actual))
    (failure section source section actual)))

;; check-section : hash? symbol? -> (listof string?)
;; One description per row of `section` on which cordis-yaml differs from the table.
(define (check-section table section)
  (define rows (table-rows table section))
  (case section
    [(load load-styled) (check-load-rows section rows yaml-read)]
    [(load-named)
     (check-load-rows section rows (lambda (text) (yaml-read text #:source "conf/cordis.yml")))]
    [(load-all) (check-load-rows section rows yaml-read-all)]
    [(load-json) (check-load-rows section rows (lambda (text) (yaml-read text #:schema 'json)))]
    [(dump) (check-dump-rows rows)]
    [(dump-unstable) (check-unstable-dump-rows rows)]
    [(eval) (check-eval-rows table rows)]
    [(syntax-error)
     (check-rejection-rows table section rows
                           (lambda (actual) (equal? actual '(error "SyntaxError"))))]
    [(unsupported)
     (check-rejection-rows table section rows
                           (lambda (actual) (eq? (car actual) 'unsupported)))]
    [else (raise-argument-error 'check-section "a checked section name" section)]))
