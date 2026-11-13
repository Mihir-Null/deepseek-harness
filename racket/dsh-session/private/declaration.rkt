#lang racket/base
;; Session event type declarations and the run-time half of `define-session-event`.
;;
;; A declaration records the type tag, the data fields in the order dsh writes them, and one
;; flat contract per field. The constructor that `define-session-event` generates calls
;; `build-fields-input` or `build-data-input` here; both check every value and raise
;; `exn:fail:contract` that names the constructor and the field. `event-declaration-violation`
;; is the same check for data that is already a jobject, reported as text.

(require racket/contract/base
         (only-in racket/contract/combinator coerce-flat-contract)
         cordis-data
         "base.rkt"
         "names.rkt"
         "event.rkt")

(provide event-declaration?
         event-declaration-tag
         event-declaration-ignorable?
         event-declaration-surface?
         event-declaration-field-list
         event-declaration-violation
         make-fields-declaration
         make-data-declaration
         make-field-spec
         build-fields-input
         build-data-input
         event-of-type?
         committed-event-of-type?
         event-with-object-data?
         event-field-ref
         plugin-record-input-type)

;; name : symbol?, the Racket field name; key : symbol?, the JSON key; contract : a flat
;; contract; predicate : its first-order test.
(struct field-spec (name key optional? contract predicate))

;; `fields` is a list of field-spec, or #f for a declaration of the whole data value, in
;; which case `data-contract` and `data-predicate` describe that value.
(struct event-declaration (tag ignorable? surface? fields data-contract data-predicate)
  #:property prop:custom-write
  (lambda (t port mode)
    (write-string (format "#<session-event-type ~a>" (event-declaration-tag t)) port)))

;; make-field-spec : symbol? symbol? string? boolean? any/c -> field-spec?
;; `who` names the declaring form in the error for a value that is not a flat contract.
(define (make-field-spec who name json-key optional? contract-value)
  (define contract (coerce-flat-contract who contract-value))
  (field-spec name (string->symbol json-key) optional? contract
              (flat-contract-predicate contract)))

(define (make-fields-declaration tag ignorable? specs)
  (event-declaration tag ignorable? (surface-type-name? tag) specs #f #f))

(define (make-data-declaration who tag ignorable? contract-value)
  (define contract (coerce-flat-contract who contract-value))
  (event-declaration tag ignorable? (surface-type-name? tag) #f contract
                     (flat-contract-predicate contract)))

;; event-declaration-field-list : event-declaration? -> (listof (list/c symbol? string? boolean?))
;; Racket name, JSON key and whether the field is optional, in write order; '() for a
;; declaration of the whole data value.
(define (event-declaration-field-list t)
  (for/list ([spec (in-list (or (event-declaration-fields t) '()))])
    (list (field-spec-name spec)
          (symbol->string (field-spec-key spec))
          (field-spec-optional? spec))))

;; event-declaration-violation : event-declaration? any/c -> (or/c #f string?)
;; The first violation in declared order: `data must be an object`, `lacks field "<key>"` or
;; `field "<key>" is invalid`; `data is invalid` for a declaration of the whole data value.
;; Keys that the declaration does not name are ignored.
(define (event-declaration-violation t data)
  (define specs (event-declaration-fields t))
  (cond
    [(not specs)
     (and (not ((event-declaration-data-predicate t) data)) "data is invalid")]
    [(not (record? data)) "data must be an object"]
    [else
     (for/or ([spec (in-list specs)])
       (define value (jref data (field-spec-key spec) absent))
       (cond
         [(absent? value)
          (and (not (field-spec-optional? spec))
               (format "lacks field \"~a\"" (field-spec-key spec)))]
         [((field-spec-predicate spec) value) #f]
         [else (format "field \"~a\" is invalid" (field-spec-key spec))]))]))

;; ---- constructors ----

(define (raise-field-error who what contract value)
  (define expected (format "~s" (contract-name contract)))
  (raise-arguments-error who
                         "contract violation"
                         "field" (unquoted-printing-string what)
                         "expected" (unquoted-printing-string expected)
                         "given" value))

(define (check-surface-arguments who t op sources)
  (when (event-declaration-surface? t)
    (unless (or (eq? op 'append) (surface-replace? op))
      (raise-argument-error who "(or/c 'append surface-replace?)" op))
    (unless (or (absent? sources) (not sources)
                (and (list? sources) (andmap session-seq? sources)))
      (raise-argument-error who "(or/c #f (listof session-seq?))" sources))))

;; The input value for checked data: a plugin record input for an ignorable declaration, an
;; event input otherwise.
(define (wrap t data op sources)
  (cond
    [(event-declaration-ignorable? t) (plugin-record-input t data)]
    [(event-declaration-surface? t)
     (make-session-event-input (event-declaration-tag t) data #:surface-op op #:sources sources)]
    [else (make-session-event-input (event-declaration-tag t) data)]))

;; build-fields-input : symbol? event-declaration? list? any/c any/c -> input
;; `values` holds one value per declared field, in declared order, `absent` for an optional
;; field that was not given. The data jobject has the present fields in that order.
(define (build-fields-input who t values op sources)
  (check-surface-arguments who t op sources)
  (define members
    (for/list ([spec (in-list (event-declaration-fields t))]
               [value (in-list values)]
               #:unless (absent? value))
      (unless ((field-spec-predicate spec) value)
        (raise-field-error who (symbol->string (field-spec-name spec))
                           (field-spec-contract spec) value))
      (cons (field-spec-key spec) value)))
  (wrap t (make-jobject members) op sources))

;; build-data-input : symbol? event-declaration? any/c any/c any/c -> input
(define (build-data-input who t data op sources)
  (check-surface-arguments who t op sources)
  (unless ((event-declaration-data-predicate t) data)
    (raise-field-error who "data" (event-declaration-data-contract t) data))
  (wrap t data op sources))

;; ---- predicates and accessors ----

;; The type tag and data of an event, an event input or a plugin record input.
(define (tag+data v)
  (cond
    [(session-event? v) (values (session-event-type v) (session-event-data v))]
    [(session-event-input? v) (values (session-event-input-type v) (session-event-input-data v))]
    [(plugin-record-input? v)
     (values (plugin-record-input-type v) (plugin-record-input-data v))]
    [else (values #f #f)]))

(define (event-of-type? v tag)
  (define-values (type data) (tag+data v))
  (and type (string=? type tag)))

;; True for a committed event of that type: what a pattern of a whole-data declaration matches.
(define (committed-event-of-type? v tag)
  (and (session-event? v) (string=? (session-event-type v) tag)))

;; True for a committed event of that type whose data is an object: what a pattern of a
;; declaration with fields matches.
(define (event-with-object-data? v tag)
  (and (session-event? v)
       (string=? (session-event-type v) tag)
       (record? (session-event-data v))))

;; event-field-ref : symbol? symbol? string? any/c symbol? -> any/c
;; The field value, or #f when the key is absent or the data is not an object. `who` is the
;; accessor and `predicate-name` the predicate named in the error for a value of another type.
(define (event-field-ref who predicate-name tag v key)
  (define-values (type data) (tag+data v))
  (unless (and type (string=? type tag))
    (raise-argument-error who (symbol->string predicate-name) v))
  (if (record? data) (jref data key #f) #f))

(define (plugin-record-input-type i)
  (event-declaration-tag (plugin-record-input-declaration i)))
