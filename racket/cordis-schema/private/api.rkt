#lang racket/base
;; The functions of the `cordis-schema` collection with their contracts. `cordis-schema`
;; (main.rkt) re-exports this module together with the declaration forms and the volatile
;; references. Interface contract: docs/racket/contracts/cordis-schema.md.

(require (for-syntax racket/base
                     syntax/parse)
         racket/contract/base
         cordis-data
         (only-in "schema.rkt"
                  schema?
                  node-type
                  node-inner
                  node-key
                  node-members
                  node-fields
                  node-bits
                  node-value
                  node-callback
                  node-constructor
                  node-builder
                  lazy-inner
                  schema-meta-ref
                  schema-meta-jobject
                  exn:fail:schema
                  exn:fail:schema?
                  exn:fail:schema-path
                  resolve-options?
                  resolve-options-path
                  resolve-options-autofix?
                  resolve-options-ignore
                  resolve-options-extend
                  raise-schema-error
                  schema->string
                  schema-resolve
                  schema-validate)
         "build.rkt"
         "json.rkt"
         "ops.rkt")

;; ---------------------------------------------------------------------------------------------
;; Accessors

(define (schema-type s) (node-type s))
(define (schema-meta s) (schema-meta-jobject s))
(define (schema-inner s) (if (node-builder s) (lazy-inner s) (node-inner s)))
(define (schema-key-schema s) (node-key s))
(define (schema-members s) (node-members s))
(define (schema-fields s) (node-fields s))
(define (schema-bits s) (node-bits s))
(define (schema-const-value s) (node-value s))
(define (schema-callback s) (node-callback s))
(define (schema-constructor s) (node-constructor s))

;; ---------------------------------------------------------------------------------------------
;; Contracts

;; Anything `schema-from` accepts. `schema-from` itself rejects other values with the message
;; Schemastery uses, so the positions that take a schema source are not narrowed here.
(define schema-source/c any/c)

(define object/c (or/c jobject? hash?))

;; A jobject, a hash, or a list of (key . value) pairs.
(define entries/c
  (or/c jobject? hash? (listof (cons/c (or/c symbol? string?) any/c))))

(define path/c (listof (or/c symbol? string? exact-nonnegative-integer?)))

(define key/c (or/c symbol? string?))

;; (->schema (mandatory ...) (optional ...)): the contract of a constructor, which also takes
;; the option keywords of section 4.2.
(define-syntax (->schema stx)
  (syntax-parse stx
    [(_ (mandatory ...) (optional ...))
     #'(->* (mandatory ...)
            (optional ...
                      #:pattern string?
                      #:step real?
                      #:min real?
                      #:max real?
                      #:role string?
                      #:required? boolean?
                      #:default any/c
                      #:description (or/c string? object/c)
                      #:comment string?
                      #:link string?
                      #:hidden? boolean?
                      #:disabled? boolean?
                      #:collapse? boolean?
                      #:loose? boolean?
                      #:deprecated? any/c
                      #:experimental? any/c
                      #:volatile? any/c)
            schema?)]))

(provide
 (contract-out
  ;; ---- schemas ----
  [schema? predicate/c]
  ;; `Schema.resolve`: the resolved value and the input as Schemastery leaves it.
  [schema-resolve (->* (schema? any/c)
                       (#:autofix? any/c
                        #:ignore (or/c #f (procedure-arity-includes/c 2))
                        #:path path/c
                        #:strict? any/c
                        #:options (or/c #f resolve-options?))
                       (values any/c any/c))]
  ;; The Standard Schema `validate`: the value and #f, or (void) and a list of
  ;; (path . message) issues.
  [schema-validate (-> schema? any/c (values any/c (or/c #f (listof (cons/c list? string?)))))]
  [struct (exn:fail:schema exn:fail)
    ([message string?]
     [continuation-marks continuation-mark-set?]
     [path list?])]
  ;; Raises `exn:fail:schema` with the path prefix Schemastery writes before `message`.
  [raise-schema-error (->* (string?) ((or/c path/c resolve-options?)) none/c)]

  ;; ---- accessors ----
  [schema-type (-> schema? string?)]
  ;; The defined metadata, in the order it was set.
  [schema-meta (-> schema? jobject?)]
  [schema-meta-ref (->* (schema? symbol?) (any/c) any)]
  ;; array, dict, transform; a lazy schema is built first.
  [schema-inner (-> schema? (or/c schema? #f))]
  [schema-key-schema (-> schema? (or/c schema? #f))]
  [schema-members (-> schema? (or/c (listof schema?) #f))]
  [schema-fields (-> schema? (or/c jobject? #f))]
  [schema-bits (-> schema? (or/c jobject? #f))]
  ;; (void) unless the schema is a const.
  [schema-const-value (-> schema? any)]
  ;; A procedure, the source string of a callback that was not revived, or #f.
  [schema-callback (-> schema? any)]
  [schema-constructor (-> schema? (or/c string? #f))]

  ;; ---- constructors ----
  [schema-any (->schema () ())]
  [schema-never (->schema () ())]
  [schema-const (->schema (any/c) ())]
  [schema-string (->schema () ())]
  [schema-number (->schema () ())]
  [schema-natural (->schema () ())]
  [schema-percent (->schema () ())]
  [schema-boolean (->schema () ())]
  [schema-date (->schema () ())]
  [schema-regexp (->schema () (string?))]
  [schema-array-buffer (->schema () ((or/c #f 'hex 'base64)))]
  [schema-bitset (->schema (entries/c) ())]
  [schema-function (->schema () ())]
  [schema-is (->schema (string?) ((or/c #f (procedure-arity-includes/c 1))))]
  [schema-array (->schema (schema-source/c) ())]
  [schema-dict (->schema (schema-source/c) (schema-source/c))]
  [schema-tuple (->schema ((listof schema-source/c)) ())]
  [schema-object (->schema (entries/c) ())]
  [schema-union (->schema ((listof schema-source/c)) ())]
  [schema-intersect (->schema ((listof schema-source/c)) ())]
  ;; callback : (-> any/c any/c); #:source is its JavaScript text for the JSON form.
  [schema-transform (->schema (schema-source/c (procedure-arity-includes/c 1))
                              (any/c #:source (or/c string? #f)))]
  [schema-lazy (->schema ((-> schema?)) ())]
  ;; resolve : data schema options strict? -> (values value adapted), or one value.
  [schema-custom (->schema (string? (procedure-arity-includes/c 4))
                           (#:format (or/c #f (procedure-arity-includes/c 2))))]
  ;; `Schema.from`; raises `exn:fail:contract` "cannot infer schema from ..." otherwise.
  [schema-from (-> schema-source/c schema?)]
  [resolve-options? predicate/c]
  [resolve-options-path (-> resolve-options? list?)]
  [resolve-options-autofix? (-> resolve-options? boolean?)]
  [resolve-options-ignore (-> resolve-options? (or/c procedure? #f))]
  ;; The same options with `key` appended to the path.
  [resolve-options-extend (-> resolve-options?
                              (or/c symbol? string? exact-nonnegative-integer?)
                              resolve-options?)]

  ;; ---- modifiers ----
  [schema-required (->* (schema?) (boolean?) schema?)]
  [schema-hidden (->* (schema?) (boolean?) schema?)]
  [schema-disabled (->* (schema?) (boolean?) schema?)]
  [schema-collapse (->* (schema?) (boolean?) schema?)]
  [schema-loose (->* (schema?) (boolean?) schema?)]
  [schema-default (-> schema? any/c schema?)]
  ;; A string, or an object from locale to string.
  [schema-description (-> schema? (or/c string? object/c) schema?)]
  [schema-comment (-> schema? string? schema?)]
  [schema-link (-> schema? string? schema?)]
  [schema-min (-> schema? real? schema?)]
  [schema-max (-> schema? real? schema?)]
  [schema-step (-> schema? real? schema?)]
  [schema-role (->* (schema? string?) (any/c) schema?)]
  ;; `source` is JavaScript regular-expression source; raises `exn:fail:contract` when it or
  ;; the flags cannot be used.
  [schema-pattern (->* (schema? string?) (#:flags string?) schema?)]
  [schema-deprecated (-> schema? schema?)]
  [schema-experimental (-> schema? schema?)]
  ;; Raises `exn:fail:contract` "volatile schema is already wrapped" on a volatile schema.
  [schema-volatile (-> schema? schema?)]
  [schema-extra (-> schema? key/c any/c schema?)]
  [schema-set (-> schema? key/c schema-source/c schema?)]
  [schema-push (-> schema? schema-source/c schema?)]
  [schema-i18n (-> schema? object/c schema?)]
  ;; `value` without what equals a default; 'null where the whole value equals the default.
  [schema-simplify (-> schema? any/c any)]

  ;; ---- type strings ----
  [schema->string (->* (schema?) (any/c) string?)]

  ;; ---- raw-config comparison ----
  ;; `schema` is a schema, or anything else for "no Schemastery schema".
  [equal-except-volatile? (-> any/c any/c any/c boolean?)]

  ;; ---- JSON form ----
  [schema->jvalue (-> schema? jobject?)]
  [jvalue->schema (->* (object/c)
                       (#:resolvers hash?
                        #:revive (or/c #f (-> string? any)))
                       schema?)]))
