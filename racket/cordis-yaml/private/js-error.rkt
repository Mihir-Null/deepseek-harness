#lang racket/base
;; Provides the exceptions of the `!!js` evaluator and the procedures that raise them.
;;
;; A raise reads the expression source and the position of the node being evaluated from the
;; continuation mark `js-site-key`, which the parser and the evaluator set, so library code
;; that implements a JavaScript method raises without knowing where it was called from.

(provide (struct-out exn:fail:js-expr)
         (struct-out exn:fail:js-expr:syntax)
         (struct-out exn:fail:js-expr:unsupported)
         js-site-key
         with-js-site
         current-js-site
         raise-js-error
         raise-js-syntax-error
         raise-js-unsupported)

;; source : the expression text, or #f when raised outside an evaluation.
;; position : 0-based character offset in `source`, or #f.
(struct exn:fail:js-expr exn:fail (source position))

;; The text is not JavaScript.
(struct exn:fail:js-expr:syntax exn:fail:js-expr ())

;; The text is JavaScript that this evaluator does not implement. construct : string.
(struct exn:fail:js-expr:unsupported exn:fail:js-expr (construct))

;; The mark's value is (cons source position).
(define js-site-key (make-continuation-mark-key 'js-site))

;; (with-js-site source position body ...): evaluates the body with the site set.
(define-syntax-rule (with-js-site source position body ...)
  (with-continuation-mark js-site-key (cons source position)
    (let () body ...)))

;; current-js-site : -> (values (or/c string? #f) (or/c exact-nonnegative-integer? #f))
(define (current-js-site)
  (define site (continuation-mark-set-first #f js-site-key))
  (if site
      (values (car site) (cdr site))
      (values #f #f)))

(define (site-suffix source position)
  (string-append (if source (format "\n  expression: ~a" source) "")
                 (if position (format "\n  position: ~a" position) "")))

;; raise-js-error : string? string? -> none
;; A JavaScript run-time error; `name` is the JavaScript error name (TypeError, ...).
(define (raise-js-error name text)
  (define-values (source position) (current-js-site))
  (raise (exn:fail:js-expr (string-append name ": " text (site-suffix source position))
                           (current-continuation-marks)
                           source position)))

;; raise-js-syntax-error : string? [position] -> none
(define (raise-js-syntax-error text [at #f])
  (define-values (source position) (current-js-site))
  (define where (or at position))
  (raise (exn:fail:js-expr:syntax
          (string-append "SyntaxError: " text (site-suffix source where))
          (current-continuation-marks)
          source where)))

;; raise-js-unsupported : string? [position] -> none
;; `construct` names what is not implemented, for example "regular expression literal".
(define (raise-js-unsupported construct [at #f])
  (define-values (source position) (current-js-site))
  (define where (or at position))
  (raise (exn:fail:js-expr:unsupported
          (string-append "unsupported JavaScript in a !!js expression: " construct
                         (site-suffix source where))
          (current-continuation-marks)
          source where construct)))
