#lang racket/base
;; dsh-util/brand: nominal ids, the Racket form of dsh `Branded<B>` and `BrandedNumber<B>`.
;;
;; source: packages/util/brand/src/index.ts
;;
;; dsh brands exist only in the type checker. Racket has no such checker at package boundaries,
;; so a brand here is a distinct structure type wrapping a string or a number:
;; `(define-brand session-id)` defines the constructor `session-id`, the predicate `session-id?`
;; and the unwrapper `session-id->string`. A value of one brand never satisfies another brand's
;; predicate, so a contract `session-id?` rejects a tool-call id. Two values of the same brand
;; are `equal?` when their underlying values are. `display` writes the underlying text, and
;; `unbrand` returns the plain string or number for JSON and files, where ids stay plain.

(require racket/contract/base
         (for-syntax racket/base
                     racket/syntax
                     syntax/parse))

(provide define-brand
         (contract-out
          [branded? (-> any/c boolean?)]
          [brand-value (-> branded? (or/c string? real?))]
          [brand-name (-> branded? symbol?)]
          [unbrand (-> any/c any/c)]))

;; The common supertype of every brand. `name` is the brand's identifier as a symbol.
(struct branded (value)
  #:transparent
  #:property prop:custom-write
  (lambda (v port mode)
    (define raw (branded-value v))
    (cond
      [(eq? mode #f) (display raw port)]
      [else
       (write-string "#<" port)
       (write-string (symbol->string (brand-name v)) port)
       (write-string " " port)
       (write raw port)
       (write-string ">" port)])))

(define-values (prop:brand-name brand-name? brand-name-ref)
  (make-struct-type-property 'brand-name))

;; The underlying string or number of any branded value.
(define (brand-value v) (branded-value v))

;; The identifier the brand was defined with.
(define (brand-name v) (brand-name-ref v))

;; The underlying value of a branded value; any other value unchanged.
(define (unbrand v) (if (branded? v) (branded-value v) v))

(define (check-raw who kind check raw)
  (define ok?
    (case kind
      [(string) (string? raw)]
      [(number) (and (real? raw) (not (and (flonum? raw) (or (nan? raw) (infinite? raw)))))]))
  (unless ok?
    (raise-argument-error who (if (eq? kind 'string) "string?" "real?") raw))
  (when (and check (not (check raw)))
    (raise-arguments-error who "value is not admitted by this brand" "value" raw)))

(define (nan? x) (not (= x x)))
(define (infinite? x) (and (= x x) (not (= (- x x) 0.0))))

;; (define-brand name)                     a string brand
;; (define-brand name #:kind number)       a number brand
;; (define-brand name #:check pred-expr)   additionally requires (pred-expr raw)
;;
;; Defines:
;;   (name raw) -> name?        wraps a string (or number); a value already of this brand is
;;                              returned unchanged, as dsh brandString accepts `string | T`
;;   (name? v) -> boolean?
;;   (name->string v) -> string?    or (name->number v) for a number brand
(define-syntax (define-brand stx)
  (syntax-parse stx
    [(_ name:id
        (~alt (~optional (~seq #:kind (~and kind (~or (~datum string) (~datum number))))
                         #:name "#:kind option"
                         #:defaults ([kind #'string]))
              (~optional (~seq #:check check:expr)
                         #:name "#:check option"
                         #:defaults ([check #'#f])))
        ...)
     #:with struct-id (format-id #'name "brand:~a" #'name)
     #:with struct-pred (format-id #'struct-id "~a?" #'struct-id)
     #:with pred (format-id #'name "~a?" #'name)
     #:with unwrap (format-id #'name (if (eq? (syntax-e #'kind) 'string) "~a->string" "~a->number")
                              #'name)
     #'(begin
         (struct struct-id branded ()
           #:transparent
           #:reflection-name 'name
           #:property prop:brand-name 'name)
         (define check-proc check)
         (define (name raw)
           (cond
             [(struct-pred raw) raw]
             [else
              (check-raw 'name 'kind check-proc raw)
              (struct-id (if (string? raw) (string->immutable-string raw) raw))]))
         (define (pred v) (struct-pred v))
         (define (unwrap v)
           (unless (struct-pred v)
             (raise-argument-error 'unwrap (symbol->string 'pred) v))
           (branded-value v)))]))
