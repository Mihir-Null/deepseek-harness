#lang racket/base
;; The `cordis-data` collection: the JSON value model every other package shares.
;;
;; A jvalue is a `jobject` (an immutable object that keeps its keys in insertion order), a list
;; (a JSON array), a string, a real number that is not NaN or infinite, #t, #f, or 'null.
;; This module provides the operations on jvalues, JSON text that matches JavaScript's
;; `JSON.parse` and `JSON.stringify`, `deep-equal?` with cosmokit's rules, and the UTF-16,
;; UTF-8 and code-point length helpers. Interface contract: docs/racket/contracts/cordis-data.md.
;;
;; Wherever an object is read, a plain hash with symbol or string keys is accepted in its place
;; and read in `symbol<?` key order. `(void)` stands for JavaScript's `undefined`: it is never
;; stored, and storing it raises `exn:fail:contract`.

(require racket/contract/base
         "private/core.rkt"
         "private/jobject.rkt"
         "private/json-read.rkt"
         "private/json-write.rkt"
         "private/equal.rkt"
         "private/text.rkt"
         "private/number.rkt")

;; A key names an object member; a string key is interned to a symbol.
(define jkey/c (or/c symbol? string?))

;; A jobject, or a hash standing for one.
(define object/c (or/c jobject? hash?))

;; Anything but `(void)` may be stored.
(define storable/c (not/c void?))

(define path/c (listof (or/c symbol? string? exact-nonnegative-integer?)))

(define indent/c (or/c #f (integer-in 1 10)))

(define (keys+values? args)
  (let loop ([rest args])
    (cond
      [(null? rest) #t]
      [(and (pair? (cdr rest))
            (or (symbol? (car rest)) (string? (car rest)))
            (not (void? (cadr rest))))
       (loop (cddr rest))]
      [else #f])))

(define keys+values/c
  (flat-named-contract '(key value ... ...) keys+values?))

(provide
 ;; (jobj [key-expr value-expr] ...): builds a jobject; `#:when test` before a clause makes it
 ;; conditional.
 jobj
 ;; (jobj-pat [key pat] ... [key pat #:default expr] ... #:rest pat): `match` pattern.
 jobj-pat
 ;; (in-jobject obj): sequence of two values, key and value, in key order.
 in-jobject

 (contract-out
  ;; ---- values ----
  [jobject? predicate/c]
  ;; Deep check; a hash with symbol or string keys counts as an object.
  [jvalue? predicate/c]
  ;; (jobject 'a 1 "b" 2): a later duplicate key replaces the value, keeping the position.
  [jobject (->* () #:rest keys+values/c jobject?)]
  [make-jobject (-> (listof (cons/c jkey/c storable/c)) jobject?)]
  [empty-jobject jobject?]

  ;; A procedure default is called for its value, as with `hash-ref`.
  [jref (->* (object/c jkey/c) (any/c) any)]
  ;; Follows keys and array indexes; the default when any step is missing.
  [jref* (->* (any/c path/c) (any/c) any)]
  [jhas? (-> object/c jkey/c boolean?)]
  ;; An existing key keeps its position; a new key goes last.
  [jset (-> object/c jkey/c storable/c jobject?)]
  ;; Functional deep update; creates the objects and arrays a missing step needs.
  [jset* (-> any/c path/c storable/c any)]
  [jupdate (->* (object/c jkey/c (procedure-arity-includes/c 1)) (any/c) jobject?)]
  [jremove (-> object/c jkey/c jobject?)]
  ;; Symbols, in insertion order.
  [jkeys (-> object/c list?)]
  [jvalues (-> object/c list?)]
  [jcount (-> object/c exact-nonnegative-integer?)]
  ;; Pairs of symbol and value, in insertion order.
  [jobject->alist (-> object/c list?)]
  ;; Shallow; an immutable `hasheq` keyed by symbol.
  [jobject->hasheq (-> object/c hash?)]
  ;; Deep conversion to the `racket/json` representation; raises `exn:fail:contract` for a
  ;; value that is not a jvalue.
  [jvalue->jsexpr (-> any/c any)]
  ;; Deep conversion from it; hash keys are sorted. Raises `exn:fail:contract` likewise.
  [jsexpr->jvalue (-> any/c any)]
  ;; Shallow and right-biased; a key keeps its first position.
  [jmerge (->* () #:rest (listof object/c) jobject?)]
  ;; Objects merge recursively; for anything else the second argument wins.
  [jmerge-deep (-> any/c any/c any)]
  ;; proc : key value -> value
  [jmap (-> (procedure-arity-includes/c 2) object/c jobject?)]
  ;; pred : key value -> any
  [jfilter (-> (procedure-arity-includes/c 2) object/c jobject?)]

  ;; ---- JSON text ----
  [struct (exn:fail:json exn:fail)
    ([message string?]
     [continuation-marks continuation-mark-set?]
     [position exact-nonnegative-integer?])]
  ;; All three readers raise `exn:fail:json` on a syntax error.
  [string->jvalue (->* (string?) (#:who symbol?) any)]
  ;; One value from the port after leading whitespace, or eof.
  [read-jvalue (->* () (input-port?) any)]
  ;; UTF-8; invalid sequences decode to U+FFFD as in JavaScript.
  [bytes->jvalue (-> bytes? any)]
  ;; The writers raise `exn:fail:contract` for a value that is not a jvalue, except that NaN
  ;; and the infinities are written as null.
  [jvalue->string (->* (any/c) (#:indent indent/c) string?)]
  [jvalue->bytes (->* (any/c) (#:indent indent/c) bytes?)]
  [write-jvalue (->* (any/c) (output-port? #:indent indent/c) void?)]

  ;; ---- equality ----
  [deep-equal? (->* (any/c any/c) (#:strict? any/c) boolean?)]

  ;; ---- text length units ----
  ;; JavaScript's `str.length`.
  [utf16-length (-> string? exact-nonnegative-integer?)]
  ;; JavaScript's `str.slice(start, end)`, minus any half surrogate pair at a cut.
  [utf16-substring (->* (string? exact-nonnegative-integer?)
                        ((or/c exact-nonnegative-integer? #f))
                        string?)]
  [utf16-truncate (-> string? exact-nonnegative-integer? string?)]
  ;; `Buffer.byteLength(str, 'utf8')`.
  [utf8-length (-> string? exact-nonnegative-integer?)]
  [utf8-truncate (-> string? exact-nonnegative-integer? string?)]
  ;; `[...str].length`.
  [code-point-length (-> string? exact-nonnegative-integer?)]
  ;; JavaScript's `a < b` on strings.
  [js-string<? (-> string? string? boolean?)]
  ;; JavaScript's `String(n)`.
  [js-number->string (-> real? string?)]))
