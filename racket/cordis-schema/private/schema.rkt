#lang racket/base
;; The schema value, its metadata, type strings, volatile placement and resolution: the port of
;; `Schema.resolve` and the built-in resolvers.
;; source: vendor/schemastery/src/index.ts
;;
;; A schema is an immutable struct that is applicable to data. Internally a resolver returns
;; three values: the result, the adapted input Schemastery returns as the second element of its
;; pair (`(void)` when there is none), and the data as Schemastery's in-place writes would
;; leave it. The third value is what makes the port free of mutation.
;;
;; The one cache in a schema is the built schema of a `lazy` node. Nothing here checks argument
;; types beyond what each comment states; `cordis-schema` (main.rkt) attaches the contracts.

(require racket/list
         racket/string
         cordis-data
         "js.rkt"
         "../volatile.rkt")

(provide (struct-out node)
         (rename-out [node? schema?])
         make-node
         copy-node
         ;; metadata
         meta-ref
         meta-set
         meta->jobject
         schema-meta-ref
         schema-meta-jobject
         ;; lazy nodes
         lazy-inner
         lazy-built
         ;; options and errors
         (struct-out exn:fail:schema)
         resolve-options?
         make-resolve-options
         resolve-options-autofix?
         resolve-options-ignore
         resolve-options-path
         resolve-options-extend
         raise-schema-error
         valid-path?
         ;; operations
         schema->string
         resolve
         schema-resolve
         schema-validate)

;; ---------------------------------------------------------------------------------------------
;; Representation

;; type        : string
;; meta        : (listof (cons symbol any)) in the order the keys were first set; a value of
;;               (void) is a key set to `undefined`
;; inner       : schema or #f (array, dict, transform); unused by lazy nodes
;; key         : schema or #f (dict: Schemastery sKey)
;; members     : (listof schema) or #f (tuple, union, intersect: Schemastery list)
;; fields      : jobject of schemas or #f (object: Schemastery dict)
;; bits        : jobject or #f
;; value       : the const value; (void) otherwise
;; callback    : procedure, or the source string of a callback that was not revived, or #f
;; source      : JavaScript text of the callback for the JSON form, or #f
;; constructor : string or #f (is)
;; pred        : predicate or #f (is with a predicate)
;; preserve    : (void) when not passed, else the value passed (transform)
;; builder     : thunk or #f (lazy)
;; cell        : box holding the built schema or #f (lazy); #f for other types
;; prebuilt?   : a lazy node read from JSON; its builder only looks the built schema up, so it
;;               may run at any time
;; resolver    : custom resolver or #f
;; formatter   : custom type-string procedure or #f
;; order       : the node's property names in the order the JSON form writes them
(struct node (type meta inner key members fields bits value callback source constructor pred
                     preserve builder cell prebuilt? resolver formatter order)
  #:constructor-name raw-node
  #:property prop:procedure
  (lambda (self [data (void)] #:autofix? [autofix? #f] #:ignore [ignore #f] #:path [path '()])
    (unless (valid-path? path)
      (raise-argument-error 'schema "(listof (or/c symbol? string? exact-nonnegative-integer?))"
                            path))
    (define-values (value adapted data*)
      (resolve data self (make-resolve-options autofix? ignore path) #f))
    value)
  #:methods gen:custom-write
  [(define (write-proc s port mode)
     (write-string "#<schema " port)
     (write-string (schema->string s) port)
     (write-string ">" port))])

(define (make-node type
                   #:meta [meta '()]
                   #:inner [inner #f]
                   #:key [key #f]
                   #:members [members #f]
                   #:fields [fields #f]
                   #:bits [bits #f]
                   #:value [value (void)]
                   #:callback [callback #f]
                   #:source [source #f]
                   #:constructor [constructor #f]
                   #:pred [pred #f]
                   #:preserve [preserve (void)]
                   #:builder [builder #f]
                   #:prebuilt? [prebuilt? #f]
                   #:resolver [resolver #f]
                   #:formatter [formatter #f]
                   #:order [order '(type meta)])
  (raw-node type meta inner key members fields bits value callback source constructor pred
              preserve builder (and builder (box #f)) prebuilt? resolver formatter order))

;; A copy of `s` with the given parts replaced. A copy of a lazy node builds its own schema, so
;; that metadata set on the copy reaches what it builds.
(define (copy-node s
                   #:meta [meta (node-meta s)]
                   #:inner [inner (node-inner s)]
                   #:key [key (node-key s)]
                   #:members [members (node-members s)]
                   #:fields [fields (node-fields s)]
                   #:builder [builder (node-builder s)])
  (raw-node (node-type s) meta inner key members fields (node-bits s) (node-value s)
              (node-callback s) (node-source s) (node-constructor s) (node-pred s)
              (node-preserve s) builder (and builder (box #f)) (node-prebuilt? s)
              (node-resolver s) (node-formatter s) (node-order s)))

;; ---------------------------------------------------------------------------------------------
;; Metadata

(define (meta-ref meta key)
  (define entry (assq key meta))
  (if entry (cdr entry) (void)))

;; `{ ...meta, [key]: value }`: an existing key keeps its position.
(define (meta-set meta key value)
  (if (assq key meta)
      (for/list ([entry (in-list meta)])
        (if (eq? (car entry) key) (cons key value) entry))
      (append meta (list (cons key value)))))

(define (meta->jobject meta)
  (make-jobject (filter (lambda (entry) (not (void? (cdr entry)))) meta)))

(define (schema-meta-ref s key [default (void)])
  (define value (meta-ref (node-meta s) key))
  (if (void? value) default value))

(define (schema-meta-jobject s)
  (meta->jobject (node-meta s)))

(define (meta-true? s key)
  (js-truthy? (meta-ref (node-meta s) key)))

;; ---------------------------------------------------------------------------------------------
;; Lazy nodes

;; The schema a lazy node stands for, built on first use. The built schema's metadata is the
;; lazy node's, overridden by its own. When that leaves the built schema's metadata as it is,
;; the node stands for the built schema itself, so a recursive schema refers back to the same
;; value.
(define (lazy-inner s)
  (define cell (node-cell s))
  (or (unbox cell)
      (let* ([built ((node-builder s))]
             [_ (unless (node? built)
                  (raise-arguments-error 'schema-lazy "builder did not return a schema"
                                         "result" built))]
             [merged (for/fold ([meta (node-meta s)]) ([entry (in-list (node-meta built))])
                       (meta-set meta (car entry) (cdr entry)))]
             [inner (if (equal? merged (node-meta built))
                        built
                        (copy-node built #:meta merged))])
        (set-box! cell inner)
        inner)))

;; The built schema, or #f when the node was not used yet. Never runs a caller's builder.
(define (lazy-built s)
  (cond
    [(unbox (node-cell s)) => values]
    [(node-prebuilt? s) (lazy-inner s)]
    [else #f]))

(define (lazy? s)
  (and (node-builder s) #t))

;; ---------------------------------------------------------------------------------------------
;; Options and errors

;; rpath is the path from the root, innermost key first. checked? records that volatile
;; placement was validated for this top-level call.
(struct resolve-options (autofix? ignore rpath checked?))

(define (valid-path? path)
  (and (list? path)
       (for/and ([segment (in-list path)])
         (or (symbol? segment) (string? segment) (exact-nonnegative-integer? segment)))))

(define (make-resolve-options autofix? ignore path)
  (resolve-options (and autofix? #t) ignore (reverse path) #f))

(define (resolve-options-path options)
  (reverse (resolve-options-rpath options)))

(define (resolve-options-extend options key)
  (struct-copy resolve-options options [rpath (cons key (resolve-options-rpath options))]))

(struct exn:fail:schema exn:fail (path))

;; source: vendor/schemastery/src/index.ts (ValidationError)
(define (path-prefix path)
  (define text
    (apply string-append
           "$"
           (for/list ([segment (in-list path)])
             (if (exact-integer? segment)
                 (format "[~a]" segment)
                 (format ".~a" segment)))))
  (if (string=? text "$") "" (string-append text " ")))

;; raise-schema-error : string? (or/c list? resolve-options?) -> none
(define (raise-schema-error message [where '()])
  (define path (if (resolve-options? where) (resolve-options-path where) where))
  (raise (exn:fail:schema (string-append (path-prefix path) message)
                          (current-continuation-marks)
                          path)))

;; A JavaScript TypeError that Schemastery lets escape; not a validation failure.
(define (raise-type-error message)
  (raise (make-exn:fail (string-append "TypeError: " message) (current-continuation-marks))))

;; ---------------------------------------------------------------------------------------------
;; Type strings
;; source: vendor/schemastery/src/index.ts (formatters)

(define (schema->string s [inline? #f])
  (define type (node-type s))
  (define text
    (cond
      [(node-formatter s) => (lambda (format) (format s inline?))]
      [else (format-builtin s type inline?)]))
  (if (nullable? text)
      (format "Schema<~a>" type)
      (js-string text)))

(define (child->string child [inline? #f])
  (if child (schema->string child inline?) "undefined"))

(define (format-builtin s type inline?)
  (case type
    [("any" "never" "string" "number" "boolean" "bitset" "function") type]
    [("is") (node-constructor s)]
    [("const")
     (define value (node-value s))
     (if (string? value) (jvalue->string value) value)]
    [("array") (string-append (child->string (node-inner s) #t) "[]")]
    [("dict")
     (format "{ [key: ~a]: ~a }" (child->string (node-key s)) (child->string (node-inner s)))]
    [("tuple")
     (format "[~a]" (string-join (map child->string (or (node-members s) '())) ", "))]
    [("object")
     (define fields (or (node-fields s) empty-jobject))
     (if (zero? (jcount fields))
         "{}"
         (format "{ ~a }"
                 (string-join
                  (for/list ([(key child) (in-jobject fields)])
                    (format "~a~a: ~a" key (if (meta-true? child 'required) "" "?")
                            (schema->string child)))
                  ", ")))]
    [("union")
     (define text (string-join (map child->string (or (node-members s) '())) " | "))
     (if inline? (string-append "(" text ")") text)]
    [("intersect")
     (string-join (for/list ([member (in-list (or (node-members s) '()))])
                    (schema->string member #t))
                  " & ")]
    [("transform") (child->string (node-inner s) inline?)]
    [else (void)]))

;; ---------------------------------------------------------------------------------------------
;; Volatile placement
;; source: vendor/schemastery/src/index.ts (validateVolatileSchema)

(define placement-message
  "volatile fields require a fixed object path without an enclosing volatile field")

;; Raises unless every volatile node below `s` sits on a path of object fields with no
;; enclosing volatile node. A lazy node that is not built is not expanded.
(define (validate-volatile s rpath blocked?)
  ;; schema -> 1 when seen unblocked, 2 when seen blocked, 3 for both
  (define seen (make-hasheq))
  (let visit ([s s] [rpath rpath] [blocked? blocked?])
    (define bit (if blocked? 2 1))
    (define states (hash-ref seen s 0))
    (when (zero? (bitwise-and states bit))
      (hash-set! seen s (bitwise-ior states bit))
      (define volatile? (meta-true? s 'volatile))
      (when (and volatile? blocked?)
        (raise-schema-error placement-message (reverse rpath)))
      (define nested? (or blocked? volatile?))
      (when (node-fields s)
        (for ([(key child) (in-jobject (node-fields s))])
          (visit child (cons key rpath) nested?)))
      (when (node-key s)
        (visit (node-key s) (cons '<key> rpath) #t))
      (define inner (if (lazy? s) (lazy-built s) (node-inner s)))
      (when inner
        (visit inner (cons '* rpath) #t))
      (when (node-members s)
        (for ([member (in-list (node-members s))]
              [index (in-naturals)])
          (visit member (cons (string->symbol (number->string index)) rpath) #t))))))

;; ---------------------------------------------------------------------------------------------
;; Resolution
;; source: vendor/schemastery/src/index.ts (Schema.resolve)

;; resolve : any/c (or/c schema? #f) resolve-options? boolean? -> (values any/c any/c any/c)
;; The result, the adapted input or (void), and the data after Schemastery's in-place writes.
(define (resolve data s options strict?)
  (cond
    [(not s) (values data (void) data)]
    [(not (resolve-options-checked? options))
     (validate-volatile s (resolve-options-rpath options) #f)
     (resolve* data s (struct-copy resolve-options options [checked? #t]) strict?)]
    [else (resolve* data s options strict?)]))

(define (resolve* data s options strict?)
  (cond
    [(meta-true? s 'volatile)
     (define plain (copy-node s #:meta (meta-set (node-meta s) 'volatile #f)))
     (define-values (value adapted data*) (resolve* data plain options strict?))
     (values (wrap-volatile value options) adapted data*)]
    [(let ([ignore (resolve-options-ignore options)])
       (and ignore (ignore data s)))
     (values data (void) data)]
    [(and (nullable? data) (not (lazy? s)))
     (when (meta-true? s 'required)
       (raise-schema-error "missing required value" options))
     (define fallback (fallback-default s))
     (cond
       [(nullable? fallback) (values data (void) data)]
       [else
        ;; The resolver works on a copy of the default, so the caller's data stays as it was.
        (define-values (value adapted default*) (run-resolver fallback s options strict?))
        (values value adapted data)])]
    [else (run-resolver data s options strict?)]))

;; The default of `s`, or of the first member of an intersect that has none, recursively.
(define (fallback-default s)
  (let loop ([current s])
    (define fallback (meta-ref (node-meta current) 'default))
    (define members (node-members current))
    (if (and (nullable? fallback)
             (equal? (node-type current) "intersect")
             (pair? members))
        (loop (car members))
        fallback)))

(define (wrap-volatile value options)
  ;; make-volatile rejects functions, cycles and opaque values with cosmokit's message.
  (with-handlers ([exn:fail:contract? (lambda (e) (raise-schema-error (exn-message e) options))])
    (make-volatile value)))

(define (run-resolver data s options strict?)
  (define resolver
    (cond
      [(node-resolver s) => custom-resolver]
      [(lazy? s) resolve-lazy]
      [else (hash-ref resolvers (node-type s) #f)]))
  (unless resolver
    (raise-schema-error (format "unsupported type \"~a\"" (node-type s)) options))
  (if (meta-true? s 'loose)
      ;; Schemastery returns the default whatever the resolver threw.
      (with-handlers ([exn:fail? (lambda (e)
                                   (values (meta-ref (node-meta s) 'default) (void) data))])
        (resolver data s options strict?))
      (resolver data s options strict?)))

;; A resolver given to `schema-custom` returns one value, or the value and the adapted input.
(define ((custom-resolver proc) data s options strict?)
  (call-with-values
   (lambda () (proc data s options strict?))
   (case-lambda
     [(value) (values value (void) data)]
     [(value adapted) (values value adapted data)])))

(define (expected what data options)
  (raise-schema-error (format "expected ~a but got ~a" what (js-string data)) options))

;; source: vendor/schemastery/src/index.ts (checkWithinRange)
(define (check-within-range n meta description options skip-min?)
  (define max (meta-ref meta 'max))
  (define min (meta-ref meta 'min))
  (when (and (not (void? max)) (> (js-number n) (js-number max)))
    (raise-schema-error
     (format "expected ~a <= ~a but got ~a" description (js-string max) (js-string n))
     options))
  (when (and (not (void? min)) (not skip-min?) (< (js-number n) (js-number min)))
    (raise-schema-error
     (format "expected ~a >= ~a but got ~a" description (js-string min) (js-string n))
     options)))

;; source: vendor/schemastery/src/index.ts (decimalShift)
(define (decimal-shift x digits)
  (define text (js-number->string x))
  (define point (for/first ([c (in-string text)] [i (in-naturals)] #:when (char=? c #\.)) i))
  (cond
    [(or (string-contains? text "e") (not point)) (* x (expt 10.0 digits))]
    [else
     (define integer (substring text 0 point))
     (define fraction (substring text (+ point 1)))
     (define shifted
       (if (<= (string-length fraction) digits)
           (string-append integer
                          fraction
                          (make-string (- digits (string-length fraction)) #\0))
           (string-append integer
                          (substring fraction 0 digits)
                          "."
                          (substring fraction digits))))
     (real->double-flonum (string->number shifted 10))]))

;; source: vendor/schemastery/src/index.ts (isMultipleOf)
(define (multiple-of? data min step)
  (define x (js-number data))
  (define low (js-number min))
  (define size (abs (js-number step)))
  (define text (js-number->string size))
  (cond
    [(regexp-match? #px"^[0-9]+[.][0-9]+$" text)
     (define digits (string-length (cadr (string-split text "."))))
     (js-remainder-zero? (abs (- (decimal-shift x digits) (decimal-shift low digits)))
                         (decimal-shift size digits))]
    [else (js-remainder-zero? (- x low) size)]))

;; ---------------------------------------------------------------------------------------------
;; Containers as Schemastery sees them

(define (container-ref container key)
  (cond
    [(list? container)
     (let loop ([rest container] [index key])
       (cond
         [(null? rest) (void)]
         [(zero? index) (car rest)]
         [else (loop (cdr rest) (- index 1))]))]
    [else (jref container key (void))]))

;; `container[key] = value`; a list is padded with (void), which stands for a hole.
(define (container-set container key value)
  (cond
    [(list? container)
     (let loop ([rest container] [index key])
       (cond
         [(zero? index) (cons value (if (pair? rest) (cdr rest) '()))]
         [(pair? rest) (cons (car rest) (loop (cdr rest) (- index 1)))]
         [else (cons (void) (loop '() (- index 1)))]))]
    [(void? value) (jremove container key)]
    [else (jset container key value)]))

;; `delete container[key]`.
(define (container-remove container key)
  (cond
    [(list? container)
     (if (< key (length container))
         (container-set container key (void))
         container)]
    [else (jremove container key)]))

;; source: vendor/schemastery/src/index.ts (property)
;; Returns the resolved value and the container after the write-back.
(define (property container key child options)
  (define current (container-ref container key))
  (define child-options (resolve-options-extend options key))
  (define (resolved)
    (define-values (value adapted data*) (resolve current child child-options #f))
    (define written (if (void? adapted) data* adapted))
    (values value
            (if (or (eq? written current) (and (void? written) (void? current)))
                container
                (container-set container key written))))
  (if (resolve-options-autofix? options)
      ;; With autofix a failure of any kind removes the property and yields the default.
      (with-handlers ([exn:fail?
                       (lambda (e)
                         (define fallback (if child (meta-ref (node-meta child) 'default) (void)))
                         (values (if (and child (meta-true? child 'volatile))
                                     (make-volatile fallback)
                                     fallback)
                                 (container-remove container key)))])
        (resolved))
      (resolved)))

;; ---------------------------------------------------------------------------------------------
;; Built-in resolvers
;; source: vendor/schemastery/src/index.ts (Schema.extend calls)

(define (resolve-lazy data s options strict?)
  (define built? (lazy-built s))
  (define inner (lazy-inner s))
  (unless built?
    (validate-volatile inner (resolve-options-rpath options) #t))
  (resolve data inner options strict?))

(define (resolve-any data s options strict?)
  (values data (void) data))

(define (resolve-never data s options strict?)
  (expected "nullable" data options))

(define (resolve-const data s options strict?)
  (define value (node-value s))
  (unless (deep-equal? data value)
    (expected (js-string value) data options))
  (values value (void) data))

(define (resolve-string data s options strict?)
  (unless (string? data)
    (expected "string" data options))
  (define meta (node-meta s))
  (define pattern (meta-ref meta 'pattern))
  (when (js-truthy? pattern)
    (define source
      (let ([source (and (plain-object? pattern) (jref (->object pattern) 'source (void)))])
        (if (string? source) source "")))
    (define flags
      (let ([flags (and (plain-object? pattern) (jref (->object pattern) 'flags (void)))])
        (if (string? flags) flags "")))
    (unless (regexp-match? (js-regexp source flags) data)
      (raise-schema-error
       (format "expect string to match regexp ~a" (js-regexp-text source flags))
       options)))
  (check-within-range (utf16-length data) meta "string length" options #f)
  (values data (void) data))

(define (resolve-number data s options strict?)
  (unless (real? data)
    (expected "number" data options))
  (define meta (node-meta s))
  (check-within-range data meta "number" options #f)
  (define step (meta-ref meta 'step))
  (when (js-truthy? step)
    (define min (meta-ref meta 'min))
    (unless (multiple-of? data (if (nullable? min) 0 min) step)
      (raise-schema-error
       (format "expected number multiple of ~a but got ~a" (js-string step) (js-string data))
       options)))
  (values data (void) data))

(define (resolve-boolean data s options strict?)
  (unless (boolean? data)
    (expected "boolean" data options))
  (values data (void) data))

(define (resolve-function data s options strict?)
  (unless (procedure? data)
    (expected "function" data options))
  (values data (void) data))

(define (resolve-bitset data s options strict?)
  (define bits (or (node-bits s) empty-jobject))
  (define-values (value keys)
    (cond
      [(real? data)
       (values data
               (for/list ([(key bit) (in-jobject bits)]
                          #:unless (zero? (bitwise-and (js-int32 data) (js-int32 bit))))
                 (symbol->string key)))]
      [(list? data)
       (values (for/fold ([value 0]) ([key (in-list data)])
                 (unless (string? key)
                   (expected "string" key options))
                 (if (jhas? bits key)
                     (js-int32 (bitwise-ior value (js-int32 (jref bits key))))
                     value))
               data)]
      [else (expected "number or array" data options)]))
  (define fallback (meta-ref (node-meta s) 'default))
  (if (and (real? fallback) (= value fallback))
      (values value (void) data)
      (values value keys data)))

;; The names on a value's JavaScript-side constructor chain.
(define (constructor-names v)
  (define own
    (cond
      [(string? v) '("String")]
      [(real? v) '("Number")]
      [(boolean? v) '("Boolean")]
      [(procedure? v) '("Function")]
      [(list? v) '("Array")]
      [(date? v) '("Date")]
      [(regexp-value? v) '("RegExp")]
      [(bytes? v) '("ArrayBuffer")]
      [else (struct-type-names v)]))
  (append own '("Object")))

;; The names of the struct types of `v` that the current inspector can see, most specific first.
(define (struct-type-names v)
  (define-values (type skipped?) (struct-info v))
  (let loop ([type type])
    (cond
      [(not type) '()]
      [else
       (define-values (name init auto ref set immutables super skipped?) (struct-type-info type))
       (cons (symbol->string name) (loop super))])))

(define (resolve-is data s options strict?)
  (define name (node-constructor s))
  (define pred (node-pred s))
  (unless (if pred
              (pred data)
              (and (not (nullable? data)) (member name (constructor-names data))))
    (expected (js-string name) data options))
  (values data (void) data))

(define (resolve-array data s options strict?)
  (unless (list? data)
    (expected "array" data options))
  (define inner (node-inner s))
  (check-within-range (length data) (node-meta s) "array length" options
                      (and inner (not (nullable? (meta-ref (node-meta inner) 'default)))))
  (define-values (results data*)
    (for/fold ([results '()] [data* data]) ([index (in-range (length data))])
      (define-values (value next) (property data* index inner options))
      (values (cons value results) next)))
  (values (reverse results) (void) data*))

;; Schemastery assigns `result[key] = value`; assigning `undefined` leaves no key behind here.
(define (assign result key value)
  (if (void? value) (jremove result key) (jset result key value)))

(define (resolve-dict data s options strict?)
  (unless (plain-object? data)
    (expected "object" data options))
  (define object (->object data))
  (define-values (result data*)
    (for/fold ([result empty-jobject] [data* object]) ([key (in-list (jkeys object))])
      (define resolved-key
        (cond
          ;; A key an earlier rename removed is not visited.
          [(not (jhas? data* key)) #f]
          [strict?
           ;; In strict mode Schemastery skips a key its key schema rejects.
           (with-handlers ([exn:fail? (lambda (e) #f)])
             (resolve-key key s options))]
          [else (resolve-key key s options)]))
      (cond
        [(not resolved-key) (values result data*)]
        [else
         (define-values (value written) (property data* key (node-inner s) options))
         (define moved (container-set written resolved-key (jref written key (void))))
         (values (assign result resolved-key value)
                 (if (eq? key resolved-key) written (jremove moved key)))])))
  (values result (void) (if (eq? data* object) data data*)))

(define (resolve-key key s options)
  (define-values (value adapted data*) (resolve (symbol->string key) (node-key s) options #f))
  (string->symbol (js-string value)))

(define (resolve-tuple data s options strict?)
  (unless (list? data)
    (expected "array" data options))
  (define members (or (node-members s) '()))
  (define-values (results data*)
    (for/fold ([results '()] [data* data]) ([member (in-list members)] [index (in-naturals)])
      (define-values (value next) (property data* index member options))
      (values (cons value results) next)))
  (define rest
    (if (or strict? (<= (length data*) (length members)))
        '()
        (list-tail data* (length members))))
  (values (append (reverse results) rest) (void) data*))

;; Names every JavaScript object inherits. Schemastery tests `key in result`, which is true for
;; them, so `merge` never copies a key with one of these names.
(define inherited-keys
  '(constructor toString toLocaleString valueOf hasOwnProperty isPrototypeOf propertyIsEnumerable
                __proto__ __defineGetter__ __defineSetter__ __lookupGetter__ __lookupSetter__))

;; source: vendor/schemastery/src/index.ts (merge)
;; `result` with the keys of `data` it lacks, in the order of `data`. `claimed` lists keys the
;; result holds as `undefined`, which Schemastery does not overwrite either.
(define (merge-missing result data [claimed '()])
  (for/fold ([result result]) ([(key value) (in-jobject data)])
    (if (or (jhas? result key) (memq key claimed) (memq key inherited-keys))
        result
        (jset result key value))))

(define (resolve-object data s options strict?)
  (unless (plain-object? data)
    (expected "object" data options))
  (define object (->object data))
  (define-values (result claimed data*)
    (for/fold ([result empty-jobject] [claimed '()] [data* object])
              ([(key child) (in-jobject (or (node-fields s) empty-jobject))])
      (define-values (value written) (property data* key child options))
      (if (or (not (nullable? value)) (jhas? written key))
          (values (assign result key value) (cons key claimed) written)
          (values result claimed written))))
  (values (if strict? result (merge-missing result data* claimed))
          (void)
          (if (eq? data* object) data data*)))

(define (expected-type s data options)
  (raise-schema-error
   (format "expected ~a but got ~a" (schema->string s) (js-json-text data))
   options))

(define (resolve-union data s options strict?)
  (let loop ([members (or (node-members s) '())])
    (cond
      [(null? members) (expected-type s data options)]
      [else
       ;; Schemastery discards whatever a member throws and tries the next one.
       (define result
         (with-handlers ([exn:fail? (lambda (e) #f)])
           (call-with-values (lambda () (resolve data (car members) options strict?)) list)))
       (if result
           (apply values result)
           (loop (cdr members)))])))

(define (resolve-intersect data s options strict?)
  (define members (or (node-members s) '()))
  (cond
    [(null? members) (values data (void) data)]
    [else
     (define-values (result data*)
       (for/fold ([result (void)] [data* data]) ([member (in-list members)])
         (define-values (value adapted next) (resolve data* member options #t))
         ;; A mismatch reports the data as the members resolved so far have left it.
         (values
          (cond
            [(nullable? value) result]
            [(nullable? result) value]
            [(not (eq? (js-typeof result) (js-typeof value))) (expected-type s next options)]
            [(eq? (js-typeof value) 'object) (merge-values result value)]
            [(not (js-strict-equal? result value)) (expected-type s next options)]
            [else result])
          next)))
     (values (if (and (not strict?) (plain-object? data*))
                 (merge-input result (->object data*))
                 result)
             (void)
             data*)]))

;; `merge(result, value)` for two values whose JavaScript type is object.
(define (merge-values result value)
  (cond
    [(and (list? result) (list? value))
     (if (> (length value) (length result))
         (append result (list-tail value (length result)))
         result)]
    [(list? result) result]
    [(list? value)
     (merge-missing (->object result)
                    (make-jobject (for/list ([item (in-list value)]
                                             [index (in-naturals)]
                                             #:unless (void? item))
                                    (cons (number->string index) item))))]
    [(and (plain-object? result) (plain-object? value))
     (if (or (jobject? result) (hash? result))
         (merge-missing (->object result) (->object value))
         result)]
    [else result]))

;; `merge(result, data)` at the end of an intersect, for a plain-object input.
(define (merge-input result data)
  (cond
    [(or (jobject? result) (hash? result)) (merge-missing (->object result) data)]
    [(zero? (jcount data)) result]
    [(and (eq? (js-typeof result) 'object) (not (eq? result 'null))) result]
    [else
     ;; JavaScript's `in` rejects a right-hand side that is not an object.
     (raise-type-error
      (format "Cannot use 'in' operator to search for '~a' in ~a"
              (car (jkeys data))
              (js-string result)))]))

(define (resolve-transform data s options strict?)
  (define-values (result adapted data*) (resolve data (node-inner s) options #t))
  (define callback (node-callback s))
  (unless (procedure? callback)
    (raise-type-error "callback is not a function"))
  (cond
    [(js-truthy? (node-preserve s)) (values (callback result) (void) data*)]
    [else
     (define value (callback result))
     (values value (callback (if (void? adapted) data* adapted)) data*)]))

(define resolvers
  (hash "any" resolve-any
        "never" resolve-never
        "const" resolve-const
        "string" resolve-string
        "number" resolve-number
        "boolean" resolve-boolean
        "bitset" resolve-bitset
        "function" resolve-function
        "is" resolve-is
        "array" resolve-array
        "dict" resolve-dict
        "tuple" resolve-tuple
        "object" resolve-object
        "union" resolve-union
        "intersect" resolve-intersect
        "transform" resolve-transform))

;; ---------------------------------------------------------------------------------------------
;; Public entry points

;; schema-resolve : `Schema.resolve`. Returns the result and the input as Schemastery leaves it.
(define (schema-resolve s data
                        #:autofix? [autofix? #f]
                        #:ignore [ignore #f]
                        #:path [path '()]
                        #:strict? [strict? #f]
                        #:options [options #f])
  (define-values (value adapted data*)
    (resolve data s (or options (make-resolve-options autofix? ignore path)) (and strict? #t)))
  (values value (if (void? adapted) data* adapted)))

;; schema-validate : the Standard Schema `validate`. Returns the value and #f, or (void) and a
;; list of (path . message) issues.
(define (schema-validate s data)
  (with-handlers ([exn:fail:schema?
                   (lambda (e)
                     (values (void) (list (cons (exn:fail:schema-path e) (exn-message e)))))])
    (define-values (value adapted data*) (resolve data s (make-resolve-options #f #f '()) #f))
    (values value #f)))
