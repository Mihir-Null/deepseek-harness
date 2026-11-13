#lang racket/base
;; Expansion-time helpers of `define-session-event`: the two transformers behind the
;; identifier that is both a constructor and a `match` pattern.
;;
;; `dsh-session/types` requires this module for-syntax. The identifiers passed in are syntax
;; objects that carry the binding of the declaring module, so the transformers work in any
;; module that imports the event identifier.

(require syntax/parse)

(provide make-event-expression-transformer
         make-event-pattern-transformer)

;; make-event-expression-transformer : identifier? -> (-> syntax? syntax?)
;; In an expression, the event identifier stands for its constructor procedure. An
;; application keeps the lexical context of its use, so keyword arguments are applied by the
;; `#%app` of the using module.
(define (make-event-expression-transformer constructor)
  (lambda (stx)
    (syntax-parse stx
      [(_ . arguments) (datum->syntax stx (cons constructor #'arguments) stx stx)]
      [_:id constructor])))

;; make-event-pattern-transformer :
;;   identifier? (listof (cons/c keyword? identifier?)) (or/c identifier? #f)
;;   -> (-> syntax? syntax?)
;; `matches?` names a predicate on the matched value. For a declaration with fields,
;; `accessors` maps each field keyword to its accessor and `data-accessor` is #f; the pattern
;; is `(id #:field pat ...)`. For a declaration of the whole data value, `data-accessor` names
;; `session-event-data` and the pattern is `(id)` or `(id data-pat)`.
(define (make-event-pattern-transformer matches? accessors data-accessor)
  (lambda (stx)
    (cond
      [data-accessor
       (syntax-parse stx
         [(_) #`(? #,matches?)]
         [(_ data-pattern) #`(? #,matches? (app #,data-accessor data-pattern))]
         [(_ . _)
          (raise-syntax-error #f "expected at most one pattern, for the event data" stx)])]
      [else
       (syntax-parse stx
         [(_ (~seq field:keyword pattern) ...)
          (define seen (make-hasheq))
          (define field-accessors
            (for/list ([keyword-stx (in-list (syntax->list #'(field ...)))])
              (define keyword (syntax-e keyword-stx))
              (define entry (assq keyword accessors))
              (unless entry
                (raise-syntax-error
                 #f
                 (format "unknown field keyword; the declared fields are ~a"
                         (map car accessors))
                 stx keyword-stx))
              (when (hash-ref seen keyword #f)
                (raise-syntax-error #f "duplicate field keyword" stx keyword-stx))
              (hash-set! seen keyword #t)
              (cdr entry)))
          (with-syntax ([(accessor ...) field-accessors])
            #`(? #,matches? (app accessor pattern) ...))]
         [(_ . _)
          (raise-syntax-error #f "expected a sequence of field keywords and patterns" stx)])])))
