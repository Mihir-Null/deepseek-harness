#lang racket/base
;; Checks cordis-schema against tests/data/node-table.rktd, the table of results the vendored
;; Schemastery computed under Node (tests/gen/gen-node-table.mjs writes it and documents the
;; encoding). `check-node-table` returns the number of rows checked per section and a list of
;; failure descriptions.
;;
;; Every schema of the table is built twice: with the public constructors and modifiers from
;; its specification, and by `jvalue->schema` from the JSON form Node printed. Both must give
;; the results Node gave.

(require racket/list
         racket/match
         racket/string
         cordis-data
         cordis-schema)

(provide check-node-table
         datum->value
         value->datum
         build-schema)

;; ---------------------------------------------------------------------------------------------
;; Values

;; The Racket value of an encoded JavaScript value.
(define (datum->value d)
  (cond
    [(eq? d 'undefined) (void)]
    [(vector? d) (map datum->value (vector->list d))]
    [(or (null? d) (pair? d))
     (make-jobject (for/list ([member (in-list d)]
                              #:unless (eq? (cdr member) 'undefined))
                     (cons (car member) (datum->value (cdr member)))))]
    [else d]))

(define (safe-integer? n)
  (and (rational? n) (integer? n) (<= (abs n) 9007199254740991)))

;; The encoding of a Racket value, for comparison with what Node printed.
(define (value->datum v)
  (cond
    [(void? v) 'undefined]
    [(real? v) (if (safe-integer? v) (inexact->exact v) (real->double-flonum v))]
    [(string? v) (string->immutable-string v)]
    [(or (boolean? v) (eq? v 'null)) v]
    [(list? v) (list->vector (map value->datum v))]
    [(jobject? v)
     (for/list ([(key item) (in-jobject v)])
       (cons (symbol->string key) (value->datum item)))]
    [(volatile? v) (make-prefab-struct 'volatile (value->datum (volatile-ref v)))]
    [(procedure? v) (make-prefab-struct 'function)]
    [else (make-prefab-struct 'opaque (format "~a" v))]))

;; Datums as the reader gives them, with strings made comparable to computed ones.
(define (normalize-datum d)
  (cond
    [(string? d) (string->immutable-string d)]
    [(pair? d) (cons (normalize-datum (car d)) (normalize-datum (cdr d)))]
    [(vector? d) (list->vector (map normalize-datum (vector->list d)))]
    [(prefab-struct-key d)
     (apply make-prefab-struct (prefab-struct-key d)
            (map normalize-datum (cdr (vector->list (struct->vector d)))))]
    [else d]))

;; ---------------------------------------------------------------------------------------------
;; Callbacks and ignore predicates: the Racket twins of those in the generator

(define callbacks
  (hash "trim" (lambda (v) (string-trim v))
        "upper" string-upcase
        "length" (lambda (v) (if (string? v) (utf16-length v) (length v)))
        "double" (lambda (v) (* v 2))
        "wrap" (lambda (v) (if (void? v) (jobject) (jobject 'value v)))
        "keys" (lambda (v) (map symbol->string (jkeys v)))
        "same" (lambda (v) "same")
        "undef" (lambda (v) (void))
        "prefix" (lambda (v) (string-append "x-" v))
        "boom" (lambda (v) (error "boom"))))

(define ignores
  (hash "strings" (lambda (data s) (equal? (schema-type s) "string"))
        "nulls" (lambda (data s) (eq? data 'null))
        "objects" (lambda (data s) (and (equal? (schema-type s) "object") (list? data)))))

;; ---------------------------------------------------------------------------------------------
;; Schemas from specifications

;; build-schema : spec (hash name -> source) -> schema source
;; The result of a `from` or `prim` specification is the shorthand value itself.
(define (build-schema spec sources)
  (let build ([spec spec])
    (define (flag modifier s rest)
      (if (null? rest) (modifier s) (modifier s (car rest))))
    (define (bound modifier key s n)
      (if (real? n) (modifier s n) (schema-extra s key (datum->value n))))
    (define (modify s mod)
      (match mod
        [(list* 'required rest) (flag schema-required s rest)]
        [(list* 'hidden rest) (flag schema-hidden s rest)]
        [(list* 'disabled rest) (flag schema-disabled s rest)]
        [(list* 'collapse rest) (flag schema-collapse s rest)]
        [(list* 'loose rest) (flag schema-loose s rest)]
        [(list 'default v) (schema-default s (datum->value v))]
        [(list 'description v) (schema-description s (datum->value v))]
        [(list 'comment v) (schema-comment s v)]
        [(list 'link v) (schema-link s v)]
        [(list 'min n) (bound schema-min 'min s n)]
        [(list 'max n) (bound schema-max 'max s n)]
        [(list 'step n) (bound schema-step 'step s n)]
        [(list 'role role) (schema-role s role)]
        [(list 'role role extra) (schema-role s role (datum->value extra))]
        [(list 'pattern source) (schema-pattern s source)]
        [(list 'pattern source flags) (schema-pattern s source #:flags flags)]
        [(list 'deprecated) (schema-deprecated s)]
        [(list 'experimental) (schema-experimental s)]
        [(list 'volatile) (schema-volatile s)]
        [(list 'extra key v) (schema-extra s key (datum->value v))]))
    (match spec
      [(list 'from v) (datum->value v)]
      [(list 'prim name) (string->symbol (string-downcase name))]
      [(list 'with inner mods)
       (for/fold ([s (schema-from (build inner))]) ([mod (in-list mods)])
         (modify s mod))]
      [(list 'any) (schema-any)]
      [(list 'never) (schema-never)]
      [(list 'string) (schema-string)]
      [(list 'number) (schema-number)]
      [(list 'natural) (schema-natural)]
      [(list 'percent) (schema-percent)]
      [(list 'boolean) (schema-boolean)]
      [(list 'function) (schema-function)]
      [(list 'const v) (schema-const (datum->value v))]
      [(list 'bitset bits) (schema-bitset (datum->value bits))]
      [(list 'is name) (schema-is name)]
      [(list 'array inner) (schema-array (build inner))]
      [(list 'dict inner) (schema-dict (build inner))]
      [(list 'dict inner key) (schema-dict (build inner) (build key))]
      [(list 'tuple members) (schema-tuple (map build members))]
      [(list 'union members) (schema-union (map build members))]
      [(list 'intersect members) (schema-intersect (map build members))]
      [(list 'object fields)
       (schema-object (for/list ([field (in-list fields)])
                        (cons (car field) (build (cdr field)))))]
      [(list 'transform inner name)
       (schema-transform (build inner) (hash-ref callbacks name) #:source (hash-ref sources name))]
      [(list 'transform inner name preserve)
       (schema-transform (build inner) (hash-ref callbacks name) preserve
                         #:source (hash-ref sources name))]
      [(list 'lazy inner) (schema-lazy (lambda () (schema-from (build inner))))]
      ;; A type without a resolver, as `new Schema({ type })` makes one.
      [(list 'custom type) (jvalue->schema (jobject 'type type))])))

(define (spec-mentions? spec symbol)
  (let search ([d spec])
    (cond
      [(pair? d) (or (search (car d)) (search (cdr d)))]
      [else (eq? d symbol)])))

;; ---------------------------------------------------------------------------------------------
;; Running

;; The outcome of `thunk` in the table's encoding: its value, (error MESSAGE PATH) for a
;; validation failure, or (throw) for any other failure.
(define (outcome thunk)
  (with-handlers ([exn:fail:schema?
                   (lambda (e)
                     (list 'error
                           (string->immutable-string (exn-message e))
                           (for/vector ([segment (in-list (exn:fail:schema-path e))])
                             (if (symbol? segment)
                                 (string->immutable-string (symbol->string segment))
                                 segment))))]
                  [exn:fail? (lambda (e) (list 'throw))])
    (thunk)))

;; Node's (throw NAME MESSAGE) carries JavaScript's own wording, which is not compared.
(define (comparable result)
  (match result
    [(list* 'throw _) (list 'throw)]
    [(list 'ok value adapted simplified) (list 'ok value adapted (comparable simplified))]
    [_ result]))

(define (run-case make-schema input options)
  (outcome
   (lambda ()
     (define s (make-schema))
     (define-values (value adapted)
       (schema-resolve s
                       (datum->value input)
                       #:autofix? (and (assq 'autofix options) #t)
                       #:strict? (and (assq 'strict options) #t)
                       #:ignore (cond
                                  [(assq 'ignore options) => (lambda (p) (hash-ref ignores (cdr p)))]
                                  [else #f])
                       #:path (cond
                                [(assq 'path options)
                                 => (lambda (p)
                                      (for/list ([segment (in-vector (cdr p))])
                                        (if (string? segment) (string->symbol segment) segment)))]
                                [else '()])))
     (list 'ok
           (value->datum value)
           (value->datum adapted)
           (outcome (lambda () (list 'ok (value->datum (schema-simplify s value)))))))))

;; check-node-table : path-string? -> (values (hash symbol -> count) (listof string?))
(define (check-node-table path)
  (define table
    (normalize-datum (call-with-input-file path read)))
  (define (section name) (cdr (assq name table)))
  (define sources
    (for/hash ([entry (in-list (section 'callbacks))])
      (values (car entry) (cdr entry))))
  (define revive
    (let ([by-source (for/hash ([(name source) (in-hash sources)])
                       (values source (hash-ref callbacks name)))])
      (lambda (source) (hash-ref by-source source #f))))
  (define failures '())
  (define counts (make-hasheq))
  (define (count! key) (hash-update! counts key add1 0))
  (define (fail! . parts)
    (set! failures (cons (apply format parts) failures)))
  (define (expect! what context actual expected)
    (unless (equal? actual expected)
      (fail! "~a: ~a\n  expected ~s\n  actual   ~s" what context expected actual)))

  ;; ---- rows: type strings, JSON form, resolution, simplification ----
  (for ([row (in-list (section 'rows))])
    (define name (cadr (assq 'name row)))
    (define spec (cadr (assq 'spec row)))
    (define describe (cadr (assq 'describe row)))
    (define (direct) (schema-from (build-schema spec sources)))
    (count! 'schemas)
    (expect! "describe" name
             (comparable
              (outcome
               (lambda ()
                 (define s (direct))
                 (list 'ok
                       (string->immutable-string (schema->string s))
                       (string->immutable-string (schema->string s #t))
                       (string->immutable-string (jvalue->string (schema->jvalue s)))))))
             (comparable describe))
    ;; A lazy node read from JSON is checked for volatile placement before it is used, so a
    ;; schema with both is not expected to fail at the same path.
    (define hydrated
      (and (eq? (car describe) 'ok)
           (not (and (spec-mentions? spec 'lazy) (spec-mentions? spec 'volatile)))
           (lambda () (jvalue->schema (string->jvalue (cadddr describe)) #:revive revive))))
    (when hydrated
      (count! 'hydrated)
      (expect! "hydrated JSON form" name
               (outcome (lambda () (jvalue->string (schema->jvalue (hydrated)))))
               (cadddr describe)))
    (for ([case (in-list (cdr (assq 'cases row)))])
      (define input (cadr (assq 'input case)))
      (define options (cdr (assq 'options case)))
      (define expected (comparable (cadr (assq 'result case))))
      (define context (format "~a, input ~s, options ~s" name input options))
      (count! 'cases)
      (expect! "resolve" context (comparable (run-case direct input options)) expected)
      (when hydrated
        (expect! "resolve hydrated" context
                 (comparable (run-case hydrated input options))
                 expected))))

  ;; ---- simplify ----
  (for ([row (in-list (section 'simplify))])
    (match-define (list spec value expected) row)
    (count! 'simplify)
    (expect! "simplify" (format "~s on ~s" spec value)
             (comparable
              (outcome
               (lambda ()
                 (list 'ok
                       (value->datum (schema-simplify (schema-from (build-schema spec sources))
                                                      (datum->value value)))))))
             (comparable expected)))

  ;; ---- i18n ----
  (for ([row (in-list (section 'i18n))])
    (match-define (list spec messages expected) row)
    (count! 'i18n)
    (expect! "i18n" (format "~s with ~s" spec messages)
             (comparable
              (outcome
               (lambda ()
                 (list 'ok
                       (string->immutable-string
                        (jvalue->string
                         (schema->jvalue (schema-i18n (schema-from (build-schema spec sources))
                                                      (datum->value messages)))))))))
             (comparable expected)))

  ;; ---- raw-config comparison ----
  (for ([row (in-list (section 'diff))])
    (match-define (list spec a b expected without-schema) row)
    (count! 'diff)
    (define context (format "~s: ~s vs ~s" spec a b))
    (expect! "equal-except-volatile?" context
             (comparable
              (outcome
               (lambda ()
                 (list 'ok
                       (equal-except-volatile? (datum->value a)
                                               (datum->value b)
                                               (schema-from (build-schema spec sources)))))))
             (comparable expected))
    (expect! "equal-except-volatile? without a schema" context
             (equal-except-volatile? (datum->value a) (datum->value b) #f)
             without-schema))

  (values (for/hasheq ([(key n) (in-hash counts)]) (values key n))
          (reverse failures)))
