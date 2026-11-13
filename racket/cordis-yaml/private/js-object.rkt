#lang racket/base
;; Provides the host-object interface of the `!!js` evaluator: `gen:js-object`, the closure-based
;; `make-js-object`, the `js-function` struct for builtin functions that carry properties or can
;; be constructed with `new`, and `apply-js-function`, which calls a Racket procedure with
;; JavaScript's rule for a wrong number of arguments.

(require racket/generic
         "js-error.rkt")

(provide gen:js-object
         js-object?
         js-get-property
         js-call-method
         make-js-object
         (struct-out js-function)
         apply-js-function
         call-property)

;; js-get-property : the value of property `name` (a string); (void) when it is absent.
;; js-call-method : the result of obj.name(args...); `args` is a list. The default reads the
;; property and calls it.
(define-generics js-object
  (js-get-property js-object name)
  (js-call-method js-object name args)
  #:fallbacks
  [(define/generic get-property js-get-property)
   (define (js-call-method obj name args)
     (call-property (get-property obj name) name args))])

;; call-property : calls the value read from property `name`, or raises TypeError when it is
;; not a function.
(define (call-property f name args)
  (if (procedure? f)
      (apply-js-function f args)
      (raise-js-error "TypeError" (format "~a is not a function" name))))

;; A host object built from closures. get : string -> any. call : #f, or string list -> any.
(struct closure-object (get call)
  #:methods gen:js-object
  [(define (js-get-property obj name)
     ((closure-object-get obj) name))
   (define (js-call-method obj name args)
     (define call (closure-object-call obj))
     (if call
         (call name args)
         (call-property ((closure-object-get obj) name) name args)))])

;; make-js-object : (-> string? any) [(or/c #f (-> string? list? any))] -> js-object?
(define (make-js-object get [call #f])
  (closure-object get call))

;; A builtin function. call : the procedure a plain call applies. construct : #f, or the
;; procedure `new` applies to the argument list. statics : hash from property name to value.
(struct js-function (name call construct statics)
  #:property prop:procedure (struct-field-index call))

;; apply-js-function : procedure? list? -> any
;; Applies `f` to `args`. When `f` does not accept that many arguments, extra ones are dropped
;; or missing ones are passed as (void), as a JavaScript call does.
(define (apply-js-function f args)
  (define n (length args))
  (cond
    [(procedure-arity-includes? f n) (apply f args)]
    [else
     (define fewer
       (for/first ([k (in-range (sub1 n) -1 -1)]
                   #:when (procedure-arity-includes? f k))
         k))
     (cond
       [fewer (apply f (for/list ([a (in-list args)] [_ (in-range fewer)]) a))]
       [else
        ;; A procedure accepts finitely many arities below any bound, so 64 more is enough to
        ;; find one that takes more arguments.
        (define more
          (for/first ([k (in-range (add1 n) (+ n 65))]
                      #:when (procedure-arity-includes? f k))
            k))
        (unless more
          (raise-js-error "TypeError"
                          (format "host procedure ~a cannot be called with ~a arguments"
                                  (or (object-name f) "anonymous") n)))
        (apply f (append args (build-list (- more n) (lambda (_) (void)))))])]))
