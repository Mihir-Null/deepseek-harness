#lang racket/base
;; Declaration forms: `schema-object*` writes an object schema with unquoted keys, and
;; `define-config` defines an object schema together with one accessor per field, so that a
;; misspelled field in plugin code is an unbound identifier at compile time.

(require (for-syntax racket/base
                     racket/list
                     racket/syntax
                     syntax/parse)
         cordis-data
         "api.rkt")

(provide schema-object*
         define-config)

(define unset (string->uninterned-symbol "unset"))

;; The value of `key` in a resolved config. With a default, an absent or null value gives the
;; default, as JavaScript's `config.key ?? default`; a procedure default is called.
(define (config-ref who config key default)
  (unless (or (jobject? config) (hash? config))
    (raise-argument-error who "(or/c jobject? hash?)" config))
  (define value (jref config key (void)))
  (cond
    [(eq? default unset) value]
    [(or (void? value) (eq? value 'null)) (if (procedure? default) (default) default)]
    [else value]))

(begin-for-syntax
  ;; #:keyword expr, passed to `schema-object`.
  (define-splicing-syntax-class option
    #:description "schema option (#:keyword expr)"
    #:attributes (keyword value)
    (pattern (~seq keyword:keyword value:expr)
             #:fail-when (and (eq? (syntax-e #'keyword) '#:as) #'keyword)
             "#:as belongs inside a field clause"))

  ;; [key schema-expr], key an identifier or a string literal.
  (define-syntax-class object-field
    #:description "field clause [key schema-expr]"
    #:attributes (key schema)
    (pattern [name:id schema:expr]
             #:with key #'name)
    (pattern [name:str schema:expr]
             #:with key (datum->syntax #'name (string->symbol (syntax-e #'name)) #'name)))

  ;; [key schema-expr] or [key #:as accessor-suffix schema-expr].
  (define-syntax-class config-field
    #:description "field clause [key schema-expr] or [key #:as accessor-suffix schema-expr]"
    #:attributes (key suffix schema)
    (pattern [name:id schema:expr]
             #:with key #'name
             #:with suffix #'name)
    (pattern [name:id #:as suffix:id schema:expr]
             #:with key #'name)
    (pattern [name:str #:as suffix:id schema:expr]
             #:with key (datum->syntax #'name (string->symbol (syntax-e #'name)) #'name))
    (pattern [name:str schema:expr]
             #:fail-when #'name "a string-literal key needs #:as and an accessor suffix"
             #:with key #'name
             #:with suffix #'name))

  ;; The first syntax object whose datum repeats an earlier one, or #f.
  (define (duplicate-datum stxs)
    (let loop ([rest stxs] [seen '()])
      (cond
        [(null? rest) #f]
        [(memq (syntax-e (car rest)) seen) (car rest)]
        [else (loop (cdr rest) (cons (syntax-e (car rest)) seen))]))))

;; (schema-object* option ... [key schema-expr] ...)
(define-syntax (schema-object* stx)
  (syntax-parse stx
    [(_ opt:option ... field:object-field ...)
     #:fail-when (duplicate-datum (syntax->list #'(field.key ...))) "duplicate field key"
     #'(schema-object (list (cons 'field.key field.schema) ...)
                      (~@ opt.keyword opt.value) ...)]))

;; (define-config name option ... field ...)
;; Defines `name` as the object schema of the fields and, for each field, an accessor
;; `name-KEY` (or `name-SUFFIX` with #:as): (accessor config [default]).
(define-syntax (define-config stx)
  (syntax-parse stx
    [(_ name:id opt:option ... field:config-field ...)
     #:fail-when (duplicate-datum (syntax->list #'(field.key ...))) "duplicate field key"
     #:with (accessor ...)
     (for/list ([suffix (in-list (syntax->list #'(field.suffix ...)))])
       (format-id #'name "~a-~a" #'name suffix #:source suffix))
     #:fail-when (check-duplicate-identifier (syntax->list #'(accessor ...)))
     "duplicate accessor name"
     #'(begin
         (define name
           (schema-object (list (cons 'field.key field.schema) ...)
                          (~@ opt.keyword opt.value) ...))
         (define (accessor config [default unset])
           (config-ref 'accessor config 'field.key default))
         ...)]))
