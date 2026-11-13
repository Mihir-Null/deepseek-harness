#lang racket/base
;; Schema constructors, the `schema-from` shorthand, the option keywords every constructor takes,
;; and the modifiers. Every function returns a new schema and leaves its arguments unchanged.
;; source: vendor/schemastery/src/index.ts (defineMethod calls, Schema.from, prototype methods)
;;
;; Nothing here checks argument types beyond what each comment states; `private/api.rkt`
;; attaches the contracts.

(require (for-syntax racket/base)
         cordis-data
         "js.rkt"
         "schema.rkt")

(provide schema-from
         normalize-value
         ;; constructors
         schema-any
         schema-never
         schema-const
         schema-string
         schema-number
         schema-natural
         schema-percent
         schema-boolean
         schema-date
         schema-regexp
         schema-array-buffer
         schema-bitset
         schema-function
         schema-is
         schema-array
         schema-dict
         schema-tuple
         schema-object
         schema-union
         schema-intersect
         schema-transform
         schema-lazy
         schema-custom
         ;; modifiers
         schema-required
         schema-hidden
         schema-disabled
         schema-collapse
         schema-loose
         schema-default
         schema-description
         schema-comment
         schema-link
         schema-min
         schema-max
         schema-step
         schema-role
         schema-pattern
         schema-deprecated
         schema-experimental
         schema-volatile
         schema-extra
         schema-set
         schema-push)

;; ---------------------------------------------------------------------------------------------
;; Values

;; A value as a schema stores it: every hash inside lists and objects becomes a jobject.
(define (normalize-value v)
  (cond
    [(jobject? v) (jmap (lambda (key item) (normalize-value item)) v)]
    [(hash? v) (jmap (lambda (key item) (normalize-value item)) (->object v))]
    [(and (pair? v) (list? v)) (map normalize-value v)]
    [else v]))

(define (contract-error message)
  (raise (make-exn:fail:contract message (current-continuation-marks))))

;; A jobject from a jobject, a hash, or a list of (key . value) pairs.
(define (->entries who v)
  (cond
    [(or (jobject? v) (hash? v)) (->object v)]
    [(and (list? v) (andmap pair? v)) (make-jobject v)]
    [else (raise-argument-error who "(or/c jobject? hash? (listof pair?))" v)]))

;; ---------------------------------------------------------------------------------------------
;; Modifiers

(define (with-meta s key value)
  (copy-node s #:meta (meta-set (node-meta s) key value)))

(define (schema-required s [value #t]) (with-meta s 'required value))
(define (schema-hidden s [value #t]) (with-meta s 'hidden value))
(define (schema-disabled s [value #t]) (with-meta s 'disabled value))
(define (schema-collapse s [value #t]) (with-meta s 'collapse value))
(define (schema-loose s [value #t]) (with-meta s 'loose value))

(define (schema-default s value) (with-meta s 'default (normalize-value value)))
(define (schema-description s text) (with-meta s 'description (normalize-value text)))
(define (schema-comment s text) (with-meta s 'comment text))
(define (schema-link s url) (with-meta s 'link url))
(define (schema-min s n) (with-meta s 'min n))
(define (schema-max s n) (with-meta s 'max n))
(define (schema-step s n) (with-meta s 'step n))

;; Sets `role` and `extra` together, as Schemastery does; `extra` is recorded as undefined when
;; it is not given.
(define (schema-role s role [extra (void)])
  (copy-node s #:meta (meta-set (meta-set (node-meta s) 'role role)
                                'extra
                                (normalize-value extra))))

;; `source` is JavaScript regular-expression source. Raises `exn:fail:contract` when the flags
;; are not JavaScript's or the source does not translate to a Racket regexp.
(define (schema-pattern s source #:flags [flags ""])
  (js-regexp source flags)
  (with-meta s 'pattern (jobject 'source (js-regexp-source source)
                                 'flags (js-regexp-flags flags))))

(define (add-badge s text type)
  (define badges (meta-ref (node-meta s) 'badges))
  (with-meta s 'badges (append (if (list? badges) badges '())
                               (list (jobject 'text text 'type type)))))

(define (schema-deprecated s) (add-badge s "deprecated" "danger"))
(define (schema-experimental s) (add-badge s "experimental" "warning"))

(define (schema-volatile s)
  (when (js-truthy? (meta-ref (node-meta s) 'volatile))
    (contract-error "volatile schema is already wrapped"))
  (with-meta s 'volatile #t))

(define (schema-extra s key value)
  (with-meta s (if (string? key) (string->symbol key) key) (normalize-value value)))

(define (schema-set s key child)
  (unless (node-fields s)
    (raise-argument-error 'schema-set "a schema with fields (an object schema)" s))
  (copy-node s #:fields (jset (node-fields s) key (schema-from child))))

(define (schema-push s child)
  (unless (node-members s)
    (raise-argument-error 'schema-push "a schema with members (tuple, union or intersect)" s))
  (copy-node s #:members (append (node-members s) (list (schema-from child)))))

;; ---------------------------------------------------------------------------------------------
;; Option keywords

(define unset (string->uninterned-symbol "unset"))
(define (set? v) (not (eq? v unset)))

;; Applies the given options in the documented order; an option equal to `unset` is skipped.
(define (apply-options s pattern step min max role required default description comment link
                       hidden disabled collapse loose deprecated experimental volatile)
  (let* ([s (if (set? pattern) (schema-pattern s pattern) s)]
         [s (if (set? step) (schema-step s step) s)]
         [s (if (set? min) (schema-min s min) s)]
         [s (if (set? max) (schema-max s max) s)]
         [s (if (set? role) (schema-role s role) s)]
         [s (if (set? required) (schema-required s required) s)]
         [s (if (set? default) (schema-default s default) s)]
         [s (if (set? description) (schema-description s description) s)]
         [s (if (set? comment) (schema-comment s comment) s)]
         [s (if (set? link) (schema-link s link) s)]
         [s (if (set? hidden) (schema-hidden s hidden) s)]
         [s (if (set? disabled) (schema-disabled s disabled) s)]
         [s (if (set? collapse) (schema-collapse s collapse) s)]
         [s (if (set? loose) (schema-loose s loose) s)]
         [s (if deprecated (schema-deprecated s) s)]
         [s (if experimental (schema-experimental s) s)]
         [s (if volatile (schema-volatile s) s)])
    s))

;; (define-constructor (name formal ...) body ...): defines `name` with the given formals plus
;; the option keywords of the interface contract, section 4.2.
(define-syntax-rule (define-constructor (name formal ...) body ...)
  (define (name formal ...
                #:pattern [pattern unset]
                #:step [step unset]
                #:min [min unset]
                #:max [max unset]
                #:role [role unset]
                #:required? [required unset]
                #:default [default unset]
                #:description [description unset]
                #:comment [comment unset]
                #:link [link unset]
                #:hidden? [hidden unset]
                #:disabled? [disabled unset]
                #:collapse? [collapse unset]
                #:loose? [loose unset]
                #:deprecated? [deprecated #f]
                #:experimental? [experimental #f]
                #:volatile? [volatile #f])
    (apply-options (let () body ...)
                   pattern step min max role required default description comment link
                   hidden disabled collapse loose deprecated experimental volatile)))

;; ---------------------------------------------------------------------------------------------
;; Shorthand
;; source: vendor/schemastery/src/index.ts (Schema.from)

(define (schema-from x)
  (cond
    [(schema? x) x]
    [(nullable? x) (schema-any)]
    [(or (string? x) (real? x) (boolean? x)) (schema-required (schema-const x))]
    [(eq? x 'string) (schema-required (schema-string))]
    [(eq? x 'number) (schema-required (schema-number))]
    [(eq? x 'boolean) (schema-required (schema-boolean))]
    [(eq? x 'function) (schema-required (schema-function))]
    [else (contract-error (format "cannot infer schema from ~a" (js-string x)))]))

;; ---------------------------------------------------------------------------------------------
;; Constructors
;; The `#:order` of a node lists its properties as Schemastery's JSON form writes them.

(define-constructor (schema-any) (make-node "any"))
(define-constructor (schema-never) (make-node "never"))
(define-constructor (schema-string) (make-node "string"))
(define-constructor (schema-number) (make-node "number"))
(define-constructor (schema-boolean) (make-node "boolean"))
(define-constructor (schema-function) (make-node "function"))

(define-constructor (schema-const value)
  (make-node "const" #:value (normalize-value value) #:order '(type meta value)))

(define-constructor (schema-natural)
  (schema-min (schema-step (schema-number) 1) 0))

(define-constructor (schema-percent)
  (schema-role (schema-max (schema-min (schema-step (schema-number) 0.01) 0) 1) "slider"))

;; Entries whose value is not a number are dropped, as Schemastery drops them.
(define-constructor (schema-bitset bits)
  (make-node "bitset"
             #:meta (list (cons 'default 0))
             #:bits (jfilter (lambda (key bit) (real? bit)) (->entries 'schema-bitset bits))
             #:order '(type meta bits)))

;; With `pred`, the schema accepts what `pred` accepts; without it, a value whose constructor
;; chain holds the name.
(define-constructor (schema-is constructor [pred #f])
  (make-node "is" #:constructor constructor #:pred pred #:order '(type meta constructor)))

(define-constructor (schema-array inner)
  (make-node "array"
             #:meta (list (cons 'default '()))
             #:inner (schema-from inner)
             #:order '(type meta inner)))

(define-constructor (schema-dict inner [key (void)])
  (make-node "dict"
             #:meta (list (cons 'default empty-jobject))
             #:inner (schema-from inner)
             #:key (if (nullable? key) (schema-string) (schema-from key))
             #:order '(type meta inner sKey)))

(define-constructor (schema-tuple members)
  (make-node "tuple"
             #:meta (list (cons 'default '()))
             #:members (map schema-from members)
             #:order '(type meta list)))

(define-constructor (schema-object fields)
  (make-node "object"
             #:meta (list (cons 'default empty-jobject))
             #:fields (jmap (lambda (key child) (schema-from child))
                            (->entries 'schema-object fields))
             #:order '(type meta dict)))

(define-constructor (schema-union members)
  (make-node "union" #:members (map schema-from members) #:order '(type meta list)))

(define-constructor (schema-intersect members)
  (make-node "intersect" #:members (map schema-from members) #:order '(type meta list)))

;; `source` is the JavaScript text of `callback`, written into the JSON form.
(define-constructor (schema-transform inner callback [preserve (void)] #:source [source #f])
  (make-node "transform"
             #:inner (schema-from inner)
             #:callback callback
             #:source source
             #:preserve preserve
             #:order '(type meta inner callback preserve)))

;; `builder` runs once per schema value, on first use.
(define-constructor (schema-lazy builder)
  (make-node "lazy" #:builder builder #:order '(type inner meta)))

;; `resolve : data schema options strict? -> (values value adapted)` or one value;
;; `format : schema inline? -> string`.
(define-constructor (schema-custom type resolve #:format [format #f])
  (make-node type #:resolver resolve #:formatter format))

;; ---------------------------------------------------------------------------------------------
;; Composite constructors
;; source: vendor/schemastery/src/index.ts (Schema.date, Schema.regExp, Schema.arrayBuffer)
;; The callback sources are the text of that file.

(define date-source
  (string-append
   "(value, options) => {\n"
   "      const date = new Date(value)\n"
   "      if (isNaN(+date)) throw new ValidationError(`invalid date \"${value}\"`, options)\n"
   "      return date\n"
   "    }"))

(define regexp-source
  (string-append
   "(value, options) => {\n"
   "      try {\n"
   "        return new RegExp(value, flag)\n"
   "      } catch (e: any) {\n"
   "        throw new ValidationError(e.message, options)\n"
   "      }\n"
   "    }"))

(define array-buffer-source
  (string-append
   "(value, options) => {\n"
   "      if (Binary.isSource(value)) return Binary.fromSource(value)\n"
   "      throw new ValidationError(`expected ArrayBufferSource but got ${value}`, options)\n"
   "    }"))

(define encoded-buffer-source
  (string-append
   "(value, options) => {\n"
   "      try {\n"
   "        return encoding === 'base64'\n"
   "          ? Binary.fromBase64(value)\n"
   "          : Binary.fromHex(value)\n"
   "      } catch (e: any) {\n"
   "        throw new ValidationError(e.message, options)\n"
   "      }\n"
   "    }"))

(define-constructor (schema-date)
  (schema-union
   (list (schema-is "Date" date?)
         (schema-transform (schema-role (schema-string) "datetime")
                           (lambda (value)
                             (or (iso-string->date value)
                                 (raise-schema-error (format "invalid date \"~a\"" value))))
                           #t
                           #:source date-source))))

(define-constructor (schema-regexp [flag ""])
  (schema-union
   (list (schema-is "RegExp" regexp-value?)
         (schema-transform (schema-role (schema-string) "regexp" (jobject 'flag flag))
                           (lambda (value) (js-regexp value flag #:units? #f))
                           #t
                           #:source regexp-source))))

(define-constructor (schema-array-buffer [encoding #f])
  (schema-union
   (append
    (list (schema-is "ArrayBuffer" bytes?)
          (schema-is "SharedArrayBuffer" (lambda (value) #f))
          (schema-transform (schema-any)
                            (lambda (value)
                              (if (bytes? value)
                                  value
                                  (raise-schema-error
                                   (format "expected ArrayBufferSource but got ~a"
                                           (js-string value)))))
                            #t
                            #:source array-buffer-source))
    (if encoding
        (list (schema-transform (schema-string)
                                (lambda (value)
                                  (if (eq? encoding 'base64)
                                      (bytes-from-base64 value)
                                      (bytes-from-hex value)))
                                #t
                                #:source encoded-buffer-source))
        '()))))
