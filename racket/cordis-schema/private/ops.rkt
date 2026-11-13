#lang racket/base
;; Operations over a schema that do not resolve it as a whole: `schema-simplify` (Schemastery
;; `simplify`), `schema-i18n` (Schemastery `i18n`) and `equal-except-volatile?` (the loader's
;; raw-config comparison).
;; source: vendor/schemastery/src/index.ts (Schema.prototype.simplify, Schema.prototype.i18n)
;; source: vendor/loader/src/config/diff.ts

(require racket/list
         racket/string
         cordis-data
         "js.rkt"
         "schema.rkt"
         "../volatile.rkt")

(provide schema-simplify
         schema-i18n
         equal-except-volatile?)

;; ---------------------------------------------------------------------------------------------
;; JavaScript enumeration

(define (object? v)
  (or (jobject? v) (hash? v)))

;; The own enumerable properties of a value as `for...in` and `Object.entries` list them: the
;; members of an object, the elements of an array under their indexes, the characters of a
;; string under theirs, and nothing for any other value.
(define (enumerable v)
  (cond
    [(object? v) (->object v)]
    [(list? v)
     (make-jobject (for/list ([item (in-list v)] [index (in-naturals)] #:unless (void? item))
                     (cons (number->string index) item)))]
    [(string? v)
     (make-jobject (for/list ([char (in-string v)] [index (in-naturals)])
                     (cons (number->string index) (string char))))]
    [else empty-jobject]))

;; `Object.assign(result, source)`. An array element that is undefined takes its key out of the
;; result, which is how a member that is undefined reads here.
(define (assign-all result source)
  (cond
    [(list? source)
     (for/fold ([result result]) ([item (in-list source)] [index (in-naturals)])
       (define key (string->symbol (number->string index)))
       (if (void? item) (jremove result key) (jset result key item)))]
    [else (jmerge result (enumerable source))]))

;; ---------------------------------------------------------------------------------------------
;; Simplification

;; schema-simplify : schema? any/c -> any/c
;; `value` without what equals a default; 'null where the whole value equals the default.
(define (schema-simplify s value)
  (let simplify ([s s] [value value])
    (define type (node-type s))
    (define dict? (equal? type "dict"))
    (define default (meta-ref (node-meta s) 'default))
    (define (default? v) (deep-equal? v default #:strict? dict?))
    (define data (if (volatile? value) (volatile-ref value) value))
    (cond
      [(default? data) 'null]
      [(nullable? data) data]
      [(or dict? (equal? type "object"))
       (define result
         (for/fold ([result empty-jobject]) ([(key item) (in-jobject (enumerable data))])
           (define child
             (if dict?
                 (node-inner s)
                 (jref (or (node-fields s) empty-jobject) key #f)))
           (define simple (if child (simplify child item) (void)))
           (cond
             ;; A dict keeps every key; assigning `undefined` leaves no key behind here.
             [dict? (if (void? simple) result (jset result key simple))]
             [(nullable? simple) result]
             [else (jset result key simple)])))
       (if (default? result) 'null result)]
      [(member type '("array" "tuple"))
       (unless (list? data)
         (raise (make-exn:fail "TypeError: value.forEach is not a function"
                               (current-continuation-marks))))
       (define members (or (node-members s) '()))
       (for/list ([item (in-list data)] [index (in-naturals)])
         (define child
           (cond
             [(equal? type "array") (node-inner s)]
             [(< index (length members)) (list-ref members index)]
             [else #f]))
         (if child (simplify child item) item))]
      [(equal? type "intersect")
       (for/fold ([result empty-jobject]) ([member (in-list (or (node-members s) '()))])
         (assign-all result (simplify member data)))]
      [(equal? type "union")
       ;; The first member that resolves the value and simplifies it without failing; a
       ;; failure of either step moves on, as Schemastery's bare `catch` does.
       (let loop ([members (or (node-members s) '())])
         (cond
           [(null? members) data]
           [else
            (define attempt
              (with-handlers ([exn:fail? (lambda (e) failed)])
                (resolve data (car members) (make-resolve-options #f #f '()) #f)
                (simplify (car members) data)))
            (if (eq? attempt failed) (loop (cdr members)) attempt)]))]
      [else data])))

(define failed (string->uninterned-symbol "failed"))

;; ---------------------------------------------------------------------------------------------
;; Localized descriptions

;; source: vendor/schemastery/src/index.ts (mergeDesc)
;; The description of a schema after `messages` (locale -> message) is merged in.
(define (merge-description original messages)
  (define base
    (cond
      [(string? original) (jobject "" original)]
      [(object? original) (->object original)]
      [else empty-jobject]))
  (for/fold ([result base]) ([(locale value) (in-jobject messages)])
    (define description
      (and (object? value)
           (or (truthy-ref value '$description) (truthy-ref value '$desc))))
    (cond
      [description (jset result locale description)]
      [(string? value) (jset result locale value)]
      [else result])))

;; The member of `v` under `key` when `v` is an object and the member is truthy, else #f.
(define (truthy-ref v key)
  (define item (if (object? v) (jref v key (void)) (void)))
  (and (js-truthy? item) item))

(define (member-ref v key)
  (cond
    [(object? v) (jref v key (void))]
    [(list? v) (jref (enumerable v) key (void))]
    [else (void)]))

;; source: vendor/schemastery/src/index.ts (getInner): `value?.$value ?? value?.$inner`.
(define (inner-messages v)
  (define value (member-ref v '$value))
  (if (nullable? value) (member-ref v '$inner) value))

;; source: vendor/schemastery/src/index.ts (extractKeys)
(define (plain-keys v)
  (jfilter (lambda (key item) (not (string-prefix? (symbol->string key) "$")))
           (enumerable v)))

;; `valueMap(messages, proc)`; a locale whose result is undefined is dropped, which no reader
;; of the messages can tell from a member that is undefined.
(define (map-messages proc messages)
  (make-jobject
   (for*/list ([(locale data) (in-jobject messages)]
               [mapped (in-value (proc data))]
               #:unless (void? mapped))
     (cons locale mapped))))

;; schema-i18n : schema? (or/c jobject? hash?) -> schema?
;; A copy of `s`, children included, with descriptions merged from `messages`.
(define (schema-i18n s messages)
  (let localize ([s s] [messages (->object messages)])
    (define description
      (merge-description (meta-ref (node-meta s) 'description) messages))
    (define meta
      (if (zero? (jcount description))
          (node-meta s)
          (meta-set (node-meta s) 'description description)))
    (define (inner-of data)
      (define inner (inner-messages data))
      (if (js-truthy? inner) inner (plain-keys data)))
    (cond
      [(node-builder s)
       ;; The built schema is localized when it is built.
       (define builder (node-builder s))
       (copy-node s
                  #:meta meta
                  #:builder (lambda () (localize (builder) (map-messages inner-of messages))))]
      [else
       (copy-node
        s
        #:meta meta
        #:fields (and (node-fields s)
                      (jmap (lambda (key child)
                              (localize child
                                        (map-messages
                                         (lambda (data)
                                           (define nested (member-ref (inner-messages data) key))
                                           (if (nullable? nested) (member-ref data key) nested))
                                         messages)))
                            (node-fields s)))
        #:members (and (node-members s)
                       (for/list ([child (in-list (node-members s))] [index (in-naturals)])
                         (localize child
                                   (map-messages
                                    (lambda (data)
                                      (define inner (inner-messages data))
                                      (cond
                                        [(list? inner) (list-ref* inner index)]
                                        [(list? data) (list-ref* data index)]
                                        [else (plain-keys data)]))
                                    messages))))
        #:inner (and (node-inner s)
                     (localize (node-inner s) (map-messages inner-of messages)))
        #:key (and (node-key s)
                   (localize (node-key s)
                             (map-messages (lambda (data) (member-ref data '$key)) messages))))])))

(define (list-ref* items index)
  (if (< index (length items)) (list-ref items index) (void)))

;; ---------------------------------------------------------------------------------------------
;; Raw-config comparison

;; source: vendor/loader/src/config/diff.ts (isRecord)
;; An object that is not a serialized `!!js` expression node.
(define (record? v)
  (and (object? v) (not (jhas? v '__jsExpr))))

;; equal-except-volatile? : any/c any/c any/c -> boolean?
;; Whether two raw configs differ at most in fields `schema` declares volatile. Reads schema
;; metadata only: it resolves nothing, calls no callback and builds no lazy schema.
(define (equal-except-volatile? previous next schema)
  (define (strict-equal? a b)
    (deep-equal? a b #:strict? #t))
  (define (compare a b s ancestors)
    (cond
      [(and s (js-truthy? (meta-ref (node-meta s) 'volatile))) #t]
      [(or (not s)
           (not (equal? (node-type s) "object"))
           (not (node-fields s))
           (memq s ancestors))
       (strict-equal? a b)]
      [else
       (define default (meta-ref (node-meta s) 'default))
       (define left (if (nullable? a) default a))
       (define right (if (nullable? b) default b))
       (cond
         [(and (record? left) (record? right))
          (define fields (node-fields s))
          (define inner (cons s ancestors))
          (for/and ([key (in-list (remove-duplicates (append (jkeys left) (jkeys right))))])
            (compare (jref left key (void))
                     (jref right key (void))
                     (jref fields key #f)
                     inner))]
         [else (strict-equal? left right)])]))
  (if (schema? schema)
      (compare previous next schema '())
      (strict-equal? previous next)))
