#lang racket/base
;; The data vocabulary of the session log: the `absent` marker, the scalar contracts of log
;; positions, the session header, the event envelope, event inputs, plugin records, the
;; message predicates this package uses as field contracts, `exn:fail:session`, and
;; `define-session-event`, the one form that declares a session event type.
;;
;; Non-obvious points:
;; - `absent` is the default of every optional constructor keyword. Passing any other value,
;;   #f and 'null included, writes the key.
;; - A `session-event` keeps the JSON object it was created or read with; `equal?` on two
;;   events compares those objects. `jvalue->session-event` checks the envelope only.
;; - `session-event-type` is the accessor that returns an event's type tag. A declaration made
;;   by `define-session-event` is recognised by `session-event-type?` and read with
;;   `session-event-type-tag` and the other `session-event-type-...` procedures.
;; - Where dsh throws `Error` this package raises `exn:fail:session` with the same message;
;;   where dsh throws `TypeError` it raises `exn:fail:contract` with the same message.
;; source: packages/core/session/src/types.ts

(require racket/contract/base
         racket/match
         cordis-data
         "private/base.rkt"
         "private/header.rkt"
         "private/event.rkt"
         "private/declaration.rkt"
         "private/shape.rkt"
         (for-syntax racket/base
                     racket/syntax
                     syntax/parse
                     "private/names.rkt"
                     "private/event-syntax.rkt"))

;; A value for an optional keyword: `absent`, or one that satisfies `c`.
(define (maybe/c c)
  (or/c absent? c))

(define surface-op/c
  (or/c 'append surface-replace?))

(provide
 ;; (define-session-event id #:type tag [#:ignorable] #:fields ([field [json-key] contract
 ;; [#:optional]] ...)) or (define-session-event id #:type tag [#:ignorable] #:data contract).
 ;; Defines `id-type` (the declaration), `id` (constructor and `match` pattern), `id?` and one
 ;; accessor `id-field` per field.
 define-session-event

 (contract-out
  ;; ---- the absent marker and scalars ----
  ;; The unique value that stands for "key not present".
  [absent absent?]
  [absent? predicate/c]
  [max-safe-integer exact-positive-integer?]
  ;; An exact integer, or an integral flonum other than -0.0, of magnitude at most 2^53 - 1.
  [safe-integer? predicate/c]
  ;; An exact integer from 0 to 2^53 - 1: the position of an existing event.
  [session-seq? predicate/c]
  ;; The same set; names a gap or a prefix length, which may equal the event count.
  [session-log-offset? predicate/c]
  [session-id? predicate/c]
  ;; Accept an integral flonum and return the exact integer; raise `exn:fail:contract` with
  ;; the dsh `TypeError` text for anything else.
  [->session-seq (-> any/c session-seq?)]
  [->session-log-offset (-> any/c session-log-offset?)]
  [session-format-version exact-positive-integer?]

  ;; ---- errors ----
  [struct (exn:fail:session exn:fail)
    ([message string?] [continuation-marks continuation-mark-set?])]

  ;; ---- session header ----
  [session-header? predicate/c]
  ;; Builds and validates a header; a rejected field raises `exn:fail:session`.
  [make-session-header
   (->* (#:id session-id? #:created-at any/c)
        (#:seeded? any/c #:cwd any/c #:parent-session any/c #:origin any/c
         #:delegation-depth any/c #:agent-preset any/c)
        session-header?)]
  ;; Validates a header read from JSON for the session `id`; raises `exn:fail:session`.
  [jvalue->session-header (-> session-id? any/c session-header?)]
  ;; The header as written, unknown keys retained.
  [session-header->jvalue (-> session-header? jobject?)]
  [session-header-version (-> session-header? exact-positive-integer?)]
  [session-header-id (-> session-header? session-id?)]
  [session-header-created-at (-> session-header? exact-nonnegative-integer?)]
  [session-header-cwd (-> session-header? (or/c string? #f))]
  [session-header-parent-session (-> session-header? (or/c string? #f))]
  [session-header-seeded? (-> session-header? boolean?)]
  [session-header-origin (-> session-header? (or/c string? #f))]
  [session-header-delegation-depth (-> session-header? (or/c exact-nonnegative-integer? #f))]
  [session-header-agent-preset (-> session-header? (or/c string? #f))]

  ;; ---- session events ----
  [struct surface-replace ([start-seq session-seq?] [end-seq session-seq?])]
  [session-event? predicate/c]
  ;; The type tag of an event.
  [session-event-type (-> session-event? string?)]
  [session-event-seq (-> session-event? session-seq?)]
  ;; Unix epoch milliseconds.
  [session-event-time (-> session-event? exact-integer?)]
  [session-event-data (-> session-event? any/c)]
  ;; 'append or a `surface-replace` when the type is surface-eligible and the stored value has
  ;; the valid form; #f otherwise.
  [session-event-surface-op (-> session-event? (or/c #f 'append surface-replace?))]
  ;; The stored `sourceEventSeqs` when it is a list of valid seqs; #f otherwise.
  [session-event-source-seqs (-> session-event? (or/c #f (listof session-seq?)))]
  [session-event-ignorable? (-> session-event? boolean?)]
  ;; The envelope with its keys in the order the event was created or read with.
  [session-event->jvalue (-> session-event? jobject?)]
  ;; Checks the envelope only; raises `exn:fail:session` "<subject> has an invalid event
  ;; envelope".
  [jvalue->session-event (->* (any/c) (#:subject string?) session-event?)]
  ;; Key order: type, seq, time, data, the metadata keys in the selected order, ignorable.
  [make-session-event
   (->* (string? session-seq? (and/c exact-integer? safe-integer?) jvalue?)
        (#:sources (maybe/c (listof session-seq?))
         #:surface-op (maybe/c surface-op/c)
         #:ignorable? any/c
         #:metadata-order (or/c 'sources-first 'op-first))
        session-event?)]

  ;; ---- event inputs ----
  [session-event-input? predicate/c]
  ;; An event proposed for append. The data is checked when it is appended.
  [make-session-event-input
   (->* (string? any/c)
        (#:surface-op (maybe/c surface-op/c) #:sources (maybe/c (listof session-seq?)))
        session-event-input?)]
  [session-event-input-type (-> session-event-input? string?)]
  [session-event-input-data (-> session-event-input? any/c)]
  ;; #f when the input carries none.
  [session-event-input-surface-op (-> session-event-input? (or/c #f 'append surface-replace?))]
  [session-event-input-sources (-> session-event-input? (or/c #f (listof session-seq?)))]

  ;; ---- declarations ----
  ;; Recognises a declaration made by `define-session-event`.
  [rename event-declaration? session-event-type? predicate/c]
  [rename event-declaration-tag session-event-type-tag (-> event-declaration? string?)]
  [rename event-declaration-ignorable? session-event-type-ignorable?
          (-> event-declaration? boolean?)]
  [rename event-declaration-surface? session-event-type-surface?
          (-> event-declaration? boolean?)]
  ;; Racket name, JSON key and optional? of each field, in write order.
  [rename event-declaration-field-list session-event-type-fields
          (-> event-declaration? (listof (list/c symbol? string? boolean?)))]
  ;; The first violation of the declaration by `data` as text, or #f.
  [rename event-declaration-violation session-event-type-violation
          (-> event-declaration? any/c (or/c #f string?))]

  ;; ---- plugin records ----
  ;; True for a string in the grammar `plugin:` followed by slash-separated segments.
  [plugin-record-type? predicate/c]
  [struct plugin-record ([type string?] [seq session-seq?] [time exact-integer?] [data any/c])]
  ;; The write side of a declared record type; made only by the constructor of a declaration
  ;; with `#:ignorable`.
  [plugin-record-input? predicate/c]
  [plugin-record-input-type (-> plugin-record-input? string?)]
  [plugin-record-input-data (-> plugin-record-input? any/c)]
  ;; The declaration whose constructor made the input.
  [plugin-record-input-declaration (-> plugin-record-input? event-declaration?)]

  ;; ---- message predicates ----
  ;; A message of any role: a non-empty string `id`, a known `role`, a `source` object with a
  ;; non-empty string `kind`, and a `content` array.
  [message-jvalue? predicate/c]
  ;; Each holds exactly when the shape check for the matching event type passes.
  [system-message-jvalue? predicate/c]
  [developer-message-jvalue? predicate/c]
  [user-message-jvalue? predicate/c]
  [assistant-message-jvalue? predicate/c]
  [tool-result-message-jvalue? predicate/c]))

;; ---- define-session-event ----

(begin-for-syntax
  (define-syntax-class field-clause
    #:description "a field clause [field-id maybe-json-key contract-expr maybe-#:optional]"
    #:attributes (name key contract optional?)
    (pattern [name:id (~optional key-string:str) contract:expr
                      (~optional (~and #:optional optional-keyword))]
      #:attr key (or (attribute key-string)
                     (datum->syntax #'name (symbol->string (syntax-e #'name)) #'name))
      #:attr optional? (and (attribute optional-keyword) #t)))

  ;; The first clause whose JSON key repeats an earlier one, or #f.
  (define (duplicate-json-key keys)
    (let loop ([rest keys] [seen '()])
      (cond
        [(null? rest) #f]
        [(member (syntax-e (car rest)) seen) (car rest)]
        [else (loop (cdr rest) (cons (syntax-e (car rest)) seen))])))

  ;; The first field whose name is in `reserved`, or #f.
  (define (reserved-field names reserved)
    (for/first ([name (in-list names)] #:when (memq (syntax-e name) reserved)) name))

  (define (field-keyword name)
    (datum->syntax name (string->keyword (symbol->string (syntax-e name))) name)))

(define-syntax (define-session-event stx)
  (syntax-parse stx
    [(_ id:id
        (~describe "the clause #:type type-string" (~seq #:type tag:str))
        (~optional (~and #:ignorable ignorable-keyword))
        (~describe
         "a #:fields clause or a #:data clause"
         (~or* (~seq #:fields
                     (~describe "the #:fields clause, a parenthesised list of field clauses"
                                (clause:field-clause ...)))
               (~seq #:data data-contract:expr
                     (~optional (~and #:optional data-optional-keyword))))))
     #:fail-when (attribute data-optional-keyword)
     "#:optional is not allowed on a #:data declaration"
     #:do [(define type-tag (syntax-e #'tag))
           (define ignorable? (and (attribute ignorable-keyword) #t))
           (define surface? (surface-type-name? type-tag))
           (define assistant? (equal? type-tag assistant-message-type-name))
           (define names (or (attribute clause.name) '()))
           (define keys (or (attribute clause.key) '()))]
     #:fail-when (and ignorable? (not (plugin-record-type-name? type-tag)) #'tag)
     "#:ignorable requires a type tag in the plugin record grammar (plugin:owner/record)"
     #:fail-when (and (not ignorable?) (plugin-record-type-name? type-tag) #'tag)
     "a type tag in the plugin record grammar requires #:ignorable"
     #:fail-when (check-duplicate-identifier names)
     "duplicate field"
     #:fail-when (duplicate-json-key keys)
     "duplicate JSON key"
     #:fail-when (reserved-field names '(type))
     "a field named type would collide with the declaration binding"
     #:fail-when (and surface? (reserved-field names '(surface-op sources)))
     "a surface-eligible event reserves the keywords #:surface-op and #:sources"
     (with-syntax* ([id-type (format-id #'id "~a-type" #'id #:source #'id)]
                    [id? (format-id #'id "~a?" #'id #:source #'id)]
                    [(accessor ...)
                     (for/list ([name (in-list names)])
                       (format-id #'id "~a-~a" #'id name #:source name))]
                    [(argument ...) (generate-temporaries names)]
                    [(field-key ...) keys]
                    [(field-key-symbol ...)
                     (for/list ([key (in-list keys)])
                       (datum->syntax #f (string->symbol (syntax-e key))))]
                    [(formal-keyword ...) (map field-keyword names)]
                    [(field-name ...) names]
                    [(field-contract ...) (or (attribute clause.contract) '())]
                    [(field-optional? ...) (or (attribute clause.optional?) '())]
                    [((formal ...) ...)
                     (for/list ([name (in-list names)]
                                [argument (in-list (syntax->list #'(argument ...)))]
                                [optional? (in-list (or (attribute clause.optional?) '()))])
                       (list (field-keyword name)
                             (if optional? #`[#,argument absent] argument)))]
                    [(surface-formal ...)
                     (cond
                       [(not surface?) #'()]
                       [assistant? #'(#:surface-op op)]
                       [else #'(#:surface-op op #:sources [sources absent])])]
                    [op-argument (if surface? #'op #'absent)]
                    [sources-argument (if (and surface? (not assistant?)) #'sources #'absent)]
                    [ignorable (if ignorable? #'#t #'#f)])
       (if (attribute data-contract)
           #'(begin
               (define id-type (make-data-declaration 'id tag ignorable data-contract))
               (define constructor
                 (let ([id (lambda (data surface-formal ...)
                             (build-data-input 'id id-type data op-argument sources-argument))])
                   id))
               (define (id? v) (event-of-type? v tag))
               (define (matches? v) (committed-event-of-type? v tag))
               (define-match-expander id
                 (make-event-pattern-transformer (quote-syntax matches? #:local) '()
                                                 (quote-syntax session-event-data))
                 (make-event-expression-transformer (quote-syntax constructor #:local))))
           #'(begin
               (define id-type
                 (make-fields-declaration
                  tag ignorable
                  (list (make-field-spec 'id 'field-name field-key field-optional?
                                         field-contract)
                        ...)))
               (define constructor
                 (let ([id (lambda (formal ... ... surface-formal ...)
                             (build-fields-input 'id id-type (list argument ...)
                                                 op-argument sources-argument))])
                   id))
               (define (id? v) (event-of-type? v tag))
               (define (accessor v) (event-field-ref 'accessor 'id? tag v 'field-key-symbol))
               ...
               (define (matches? v) (event-with-object-data? v tag))
               (define-match-expander id
                 (make-event-pattern-transformer
                  (quote-syntax matches? #:local)
                  (list (cons 'formal-keyword (quote-syntax accessor #:local)) ...)
                  #f)
                 (make-event-expression-transformer (quote-syntax constructor #:local))))))]))
