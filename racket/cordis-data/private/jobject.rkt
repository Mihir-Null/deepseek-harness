#lang racket/base
;; Provides the operations on jvalues: construction, lookup, functional update, merging,
;; iteration, conversion to and from `racket/json`-style jsexprs, the `jobj` constructor macro
;; and the `jobj-pat` match expander.
;;
;; Every operation that reads an object also accepts a plain hash with symbol or string keys and
;; reads its keys in `symbol<?` order; every operation that builds an object returns a jobject.
;; `(void)` stands for JavaScript's `undefined` and is rejected as a stored value. The functions
;; check only what the macros in this module can get wrong; `cordis-data` (main.rkt) attaches
;; the full contracts.

(require racket/fixnum
         racket/match
         (for-syntax racket/base
                     racket/list
                     syntax/parse)
         "core.rkt")

(provide jvalue?
         jobject
         jobj
         make-jobject
         jref
         jref*
         jhas?
         jset
         jset*
         jupdate
         jremove
         jkeys
         jvalues
         jcount
         jobject->alist
         jobject->hasheq
         jvalue->jsexpr
         jsexpr->jvalue
         jmerge
         jmerge-deep
         in-jobject
         jmap
         jfilter
         jobj-pat)

;; ---------------------------------------------------------------------------------------------
;; Predicates

;; jvalue? : any/c -> boolean?
;; Deep check. A hash with symbol or string keys counts as an object, because every reader of
;; jvalues accepts one.
(define (jvalue? v)
  (cond
    [(string? v) #t]
    [(jobject? v)
     (for/and ([value (in-immutable-hash-values (jobject-table v))])
       (jvalue? value))]
    [(pair? v)
     (let loop ([rest v])
       (if (pair? rest)
           (and (jvalue? (car rest)) (loop (cdr rest)))
           (null? rest)))]
    [(null? v) #t]
    [(boolean? v) #t]
    [(eq? v 'null) #t]
    [(real? v) (or (exact? v) (< -inf.0 v +inf.0))]
    [(hash? v)
     (for/and ([(key value) (in-hash v)])
       (and (or (symbol? key) (string? key)) (jvalue? value)))]
    [else #f]))

;; ---------------------------------------------------------------------------------------------
;; Construction

;; Adds or replaces one entry. An existing key keeps its position; a new key goes last.
(define (set-key obj key value)
  (define table (jobject-table obj))
  (define updated (hash-set table key value))
  (make-raw-jobject (jobject-front obj)
                    (if (fx= (hash-count table) (hash-count updated))
                        (jobject-rear obj)
                        (cons key (jobject-rear obj)))
                    updated))

;; The same object with its key list held in one piece, so later iteration allocates nothing.
(define (compact obj)
  (if (null? (jobject-rear obj))
      obj
      (make-raw-jobject (jobject-key-list obj) '() (jobject-table obj))))

;; build-jobject : symbol? (listof (cons/c key any/c)) -> jobject?
;; A later duplicate key replaces the value and keeps the first position.
(define (build-jobject who entries)
  (let loop ([rest entries] [keys '()] [table #hasheq()])
    (cond
      [(null? rest) (make-raw-jobject (reverse keys) '() table)]
      [(and (pair? rest) (pair? (car rest)))
       (define key (key->symbol who (caar rest)))
       (define value (cdar rest))
       (check-storable who value)
       (define updated (hash-set table key value))
       (loop (cdr rest)
             (if (fx= (hash-count table) (hash-count updated)) keys (cons key keys))
             updated)]
      [else (raise-argument-error who "(listof pair?)" entries)])))

;; make-jobject : (listof (cons/c (or/c symbol? string?) any/c)) -> jobject?
(define (make-jobject alist)
  (build-jobject 'make-jobject alist))

;; jobject : (or/c symbol? string?) any/c ... ... -> jobject?
(define (jobject . keys+values)
  (let loop ([rest keys+values] [entries '()])
    (cond
      [(null? rest) (build-jobject 'jobject (reverse entries))]
      [(null? (cdr rest))
       (raise-arguments-error 'jobject "expected an even number of arguments (key value ...)"
                              "arguments" keys+values)]
      [else (loop (cddr rest) (cons (cons (car rest) (cadr rest)) entries))])))

(begin-for-syntax
  (define-splicing-syntax-class jobj-clause
    #:description "jobj clause ([key-expr value-expr], optionally after #:when test-expr)"
    #:attributes (test key value)
    (pattern (~seq #:when ~! test:expr [key:expr value:expr]))
    (pattern (~seq [key:expr value:expr])
             #:with test #'#t)))

;; (jobj clause ...), clause = [key-expr value-expr] | #:when test-expr [key-expr value-expr]
;; Builds a jobject from the clauses in order. A clause after `#:when` contributes, and has its
;; expressions evaluated, only when the test is true.
(define-syntax (jobj stx)
  (syntax-parse stx
    [(_ clause:jobj-clause ...)
     #'(build-jobject
        'jobj
        (let* ([entries '()]
               [entries (if clause.test (cons (cons clause.key clause.value) entries) entries)]
               ...)
          (reverse entries)))]))

;; ---------------------------------------------------------------------------------------------
;; Lookup

(define (default-value default)
  (if (procedure? default) (default) default))

;; jref : (or/c jobject? hash?) (or/c symbol? string?) [any/c] -> any/c
;; A procedure `default` is called for its value, as with `hash-ref`.
(define (jref obj key [default #f])
  (define value (lookup 'jref obj (key->symbol 'jref key)))
  (if (absent? value) (default-value default) value))

;; jhas? : (or/c jobject? hash?) (or/c symbol? string?) -> boolean?
(define (jhas? obj key)
  (not (absent? (lookup 'jhas? obj (key->symbol 'jhas? key)))))

;; The element at `index`, or `absent` when `items` is not a list that long.
(define (element-at items index)
  (let loop ([rest items] [i index])
    (cond
      [(not (pair? rest)) absent]
      [(eqv? i 0) (car rest)]
      [else (loop (cdr rest) (- i 1))])))

;; jref* : any/c (listof (or/c symbol? string? exact-nonnegative-integer?)) [any/c] -> any/c
;; Follows `path` from `v`: a key steps into an object, an index into an array. Any step that
;; does not apply (missing key, index past the end, wrong kind of value) yields the default.
(define (jref* v path [default #f])
  (let loop ([v v] [path path])
    (cond
      [(null? path) v]
      [else
       (define step (car path))
       (define next
         (cond
           [(exact-nonnegative-integer? step) (element-at v step)]
           [(object-like? v) (lookup 'jref* v (key->symbol 'jref* step))]
           [else absent]))
       (if (absent? next)
           (default-value default)
           (loop next (cdr path)))])))

;; ---------------------------------------------------------------------------------------------
;; Functional update

;; jset : (or/c jobject? hash?) (or/c symbol? string?) any/c -> jobject?
(define (jset obj key value)
  (check-storable 'jset value)
  (set-key (->jobject 'jset obj) (key->symbol 'jset key) value))

;; `items` with the element at `index` replaced by `(update old)`, where `old` is `absent` past
;; the end. Positions between the end and `index` are filled with 'null, which is how
;; JavaScript writes the holes such an assignment leaves.
(define (list-update/pad items index update)
  (let loop ([rest items] [i index])
    (cond
      [(eqv? i 0)
       (if (pair? rest)
           (cons (update (car rest)) (cdr rest))
           (list (update absent)))]
      [(pair? rest) (cons (car rest) (loop (cdr rest) (- i 1)))]
      [else (cons 'null (loop '() (- i 1)))])))

;; jset* : any/c (listof (or/c symbol? string? exact-nonnegative-integer?)) any/c -> any/c
;; Returns `v` with the value at `path` replaced. A key step into a missing key creates an
;; object, an index step creates or extends an array. Raises `exn:fail:contract` when a step
;; meets an existing value of the wrong kind (a key into an array or a scalar, an index into an
;; object or a scalar); 'null counts as an existing scalar.
(define (jset* v path value)
  (check-storable 'jset* value)
  (let update ([v v] [path path])
    (cond
      [(null? path) value]
      [(exact-nonnegative-integer? (car path))
       (define (update-element old) (update old (cdr path)))
       (cond
         [(absent? v) (list-update/pad '() (car path) update-element)]
         [(list? v) (list-update/pad v (car path) update-element)]
         [else
          (raise-arguments-error 'jset* "path indexes into a value that is not an array"
                                 "index" (car path) "value" v)])]
      [else
       (define key (key->symbol 'jset* (car path)))
       (cond
         [(absent? v) (set-key empty-jobject key (update absent (cdr path)))]
         [(object-like? v)
          (define obj (->jobject 'jset* v))
          (set-key obj key (update (lookup 'jset* obj key) (cdr path)))]
         [else
          (raise-arguments-error 'jset* "path names a key in a value that is not an object"
                                 "key" key "value" v)])])))

;; jupdate : (or/c jobject? hash?) (or/c symbol? string?) (-> any/c any/c) [any/c] -> jobject?
;; `proc` receives the current value, or the default (called if it is a procedure) when the key
;; is absent.
(define (jupdate obj key proc [default #f])
  (define o (->jobject 'jupdate obj))
  (define k (key->symbol 'jupdate key))
  (define current (lookup 'jupdate o k))
  (define value (proc (if (absent? current) (default-value default) current)))
  (check-storable 'jupdate value)
  (set-key o k value))

;; jremove : (or/c jobject? hash?) (or/c symbol? string?) -> jobject?
(define (jremove obj key)
  (remove-keys (->jobject 'jremove obj) (list (key->symbol 'jremove key))))

;; `obj` (a jobject) without `keys` (symbols).
(define (remove-keys obj keys)
  (for/fold ([obj obj]) ([key (in-list keys)])
    (define table (jobject-table obj))
    (if (hash-has-key? table key)
        (make-raw-jobject (remq key (jobject-front obj))
                          (remq key (jobject-rear obj))
                          (hash-remove table key))
        obj)))

;; ---------------------------------------------------------------------------------------------
;; Whole-object access

;; jkeys : (or/c jobject? hash?) -> (listof symbol?)
(define (jkeys obj)
  (jobject-key-list (->jobject 'jkeys obj)))

;; jvalues : (or/c jobject? hash?) -> list?
(define (jvalues obj)
  (define o (->jobject 'jvalues obj))
  (define table (jobject-table o))
  (for/list ([key (in-list (jobject-key-list o))])
    (hash-ref table key)))

;; jcount : (or/c jobject? hash?) -> exact-nonnegative-integer?
(define (jcount obj)
  (hash-count (jobject-table (->jobject 'jcount obj))))

;; jobject->alist : (or/c jobject? hash?) -> (listof (cons/c symbol? any/c))
(define (jobject->alist obj)
  (define o (->jobject 'jobject->alist obj))
  (define table (jobject-table o))
  (for/list ([key (in-list (jobject-key-list o))])
    (cons key (hash-ref table key))))

;; jobject->hasheq : (or/c jobject? hash?) -> (and/c hash? hash-eq? immutable?)
;; Shallow: the values are not converted.
(define (jobject->hasheq obj)
  (jobject-table (->jobject 'jobject->hasheq obj)))

;; in-jobject : (or/c jobject? hash?) -> sequence of (values symbol? any/c), in key order
(define (in-jobject/proc obj)
  (define o (->jobject 'in-jobject obj))
  (define table (jobject-table o))
  (make-do-sequence
   (lambda ()
     (values (lambda (rest) (values (car rest) (hash-ref table (car rest))))
             cdr
             (jobject-key-list o)
             pair?
             #f
             #f))))

(define-sequence-syntax in-jobject
  (lambda () #'in-jobject/proc)
  (lambda (stx)
    (syntax-case stx ()
      [[(key value) (_ obj-expr)]
       #'[(key value)
          (:do-in
           ([(table keys) (let ([o (->jobject 'in-jobject obj-expr)])
                            (values (jobject-table o) (jobject-key-list o)))])
           #t
           ([rest keys])
           (pair? rest)
           ([(key) (car rest)]
            [(value) (hash-ref table (car rest))])
           #t
           #t
           ((cdr rest)))]]
      [_ #f])))

;; jmap : (-> symbol? any/c any/c) (or/c jobject? hash?) -> jobject?
(define (jmap proc obj)
  (define o (->jobject 'jmap obj))
  (define table (jobject-table o))
  (define keys (jobject-key-list o))
  (make-raw-jobject keys
                    '()
                    (for/fold ([mapped table]) ([key (in-list keys)])
                      (define value (proc key (hash-ref table key)))
                      (check-storable 'jmap value)
                      (hash-set mapped key value))))

;; jfilter : (-> symbol? any/c any/c) (or/c jobject? hash?) -> jobject?
(define (jfilter pred obj)
  (define o (->jobject 'jfilter obj))
  (define table (jobject-table o))
  (for/fold ([keys '()]
             [kept #hasheq()]
             #:result (make-raw-jobject (reverse keys) '() kept))
            ([key (in-list (jobject-key-list o))])
    (define value (hash-ref table key))
    (if (pred key value)
        (values (cons key keys) (hash-set kept key value))
        (values keys kept))))

;; ---------------------------------------------------------------------------------------------
;; Merging

;; jmerge : (or/c jobject? hash?) ... -> jobject?
;; Shallow and right-biased, like JavaScript's `{...a, ...b}`: a later value replaces an earlier
;; one, and the key keeps its first position.
(define (jmerge . objs)
  (cond
    [(null? objs) empty-jobject]
    [else
     (compact
      (for/fold ([merged (->jobject 'jmerge (car objs))]) ([obj (in-list (cdr objs))])
        (define o (->jobject 'jmerge obj))
        (define table (jobject-table o))
        (for/fold ([merged merged]) ([key (in-list (jobject-key-list o))])
          (set-key merged key (hash-ref table key)))))]))

;; jmerge-deep : any/c any/c -> any/c
;; Two objects merge key by key, recursively; for any other pair of values `b` wins. Arrays are
;; replaced, not concatenated.
(define (jmerge-deep a b)
  (cond
    [(and (object-like? a) (object-like? b))
     (define into (->jobject 'jmerge-deep a))
     (define from (->jobject 'jmerge-deep b))
     (define from-table (jobject-table from))
     (compact
      (for/fold ([merged into]) ([key (in-list (jobject-key-list from))])
        (define ours (hash-ref (jobject-table merged) key absent))
        (define theirs (hash-ref from-table key))
        (set-key merged key (if (absent? ours) (plain-object theirs) (jmerge-deep ours theirs)))))]
    [else (plain-object b)]))

;; A hash standing for an object becomes a jobject (shallowly); other values are unchanged.
(define (plain-object v)
  (if (hash? v) (hash->jobject 'jmerge-deep v) v))

;; ---------------------------------------------------------------------------------------------
;; jsexpr conversion

;; jvalue->jsexpr : jvalue? -> jsexpr?
;; Deep conversion to the representation `racket/json` uses: an object becomes an immutable
;; `hasheq` (its key order is lost) and an exact non-integer becomes a flonum.
(define (jvalue->jsexpr root)
  (let convert ([v root])
    (cond
      [(string? v) v]
      [(jobject? v)
       (for/fold ([table #hasheq()]) ([(key value) (in-immutable-hash (jobject-table v))])
         (hash-set table key (convert value)))]
      [(pair? v)
       (if (list? v)
           (map convert v)
           (raise-not-jvalue 'jvalue->jsexpr root v))]
      [(or (null? v) (boolean? v) (eq? v 'null) (exact-integer? v)) v]
      [(and (real? v) (exact? v)) (real->double-flonum v)]
      [(and (real? v) (< -inf.0 v +inf.0)) v]
      [(hash? v) (convert (hash->jobject 'jvalue->jsexpr v))]
      [else (raise-not-jvalue 'jvalue->jsexpr root v)])))

;; jsexpr->jvalue : jsexpr? -> jvalue?
;; Deep conversion from the representation `racket/json` uses, with null as 'null. Each hash
;; becomes a jobject whose keys are in `symbol<?` order. Jobjects already inside are kept.
(define (jsexpr->jvalue root)
  (let convert ([v root])
    (cond
      [(string? v) v]
      [(object-like? v)
       (define obj (->jobject 'jsexpr->jvalue v))
       (define keys (jobject-key-list obj))
       (make-raw-jobject keys
                         '()
                         (for/fold ([table (jobject-table obj)]) ([key (in-list keys)])
                           (hash-set table key (convert (hash-ref table key)))))]
      [(pair? v)
       (if (list? v)
           (map convert v)
           (raise-not-jvalue 'jsexpr->jvalue root v))]
      [(or (null? v) (boolean? v) (eq? v 'null)) v]
      [(and (real? v) (or (exact? v) (< -inf.0 v +inf.0))) v]
      [else (raise-not-jvalue 'jsexpr->jvalue root v)])))

;; ---------------------------------------------------------------------------------------------
;; Pattern matching

(define (lookup-for-match obj key)
  (lookup 'jobj-pat obj key))

(define (present? v)
  (not (absent? v)))

(define (rest-for-match obj keys)
  (compact (remove-keys (->jobject 'jobj-pat obj) keys)))

(begin-for-syntax
  (define-syntax-class jobj-pat-key
    #:description "literal key (an identifier or a string)"
    #:attributes (name)
    (pattern key:id
             #:attr name (syntax-e #'key))
    (pattern key:str
             #:attr name (string->symbol (syntax-e #'key))))

  (define-syntax-class jobj-pat-clause
    #:description "jobj-pat clause ([key pattern] or [key pattern #:default expr])"
    #:attributes (name matcher)
    (pattern [key:jobj-pat-key pat #:default ~! default:expr]
             #:attr name (attribute key.name)
             #:with matcher
             #`(app (lambda (obj)
                      (let ([value (lookup-for-match obj '#,(attribute key.name))])
                        (if (present? value) value default)))
                    pat))
    (pattern [key:jobj-pat-key pat]
             #:attr name (attribute key.name)
             #:with matcher
             #`(app (lambda (obj) (lookup-for-match obj '#,(attribute key.name)))
                    (? present? pat)))))

;; (jobj-pat clause ... maybe-rest)
;;   clause     = [key pat] | [key pat #:default expr]
;;   maybe-rest = | #:rest pat
;; Matches a jobject (or a hash standing for one). `[key pat]` fails when the key is absent;
;; with `#:default`, `pat` is matched against `expr` instead. The pattern after `#:rest`,
;; usually an identifier, is matched against a jobject of the keys no clause names.
(define-match-expander jobj-pat
  (lambda (stx)
    (syntax-parse stx
      [(_ clause:jobj-pat-clause ... (~optional (~seq #:rest rest-pat)))
       #:fail-when (let ([names (attribute clause.name)])
                     (define duplicate (check-duplicates names eq?))
                     (and duplicate
                          (for/last ([name (in-list names)]
                                     [clause-stx (in-list (syntax->list #'(clause ...)))]
                                     #:when (eq? name duplicate))
                            clause-stx)))
       "duplicate key in jobj-pat"
       (with-syntax ([(name ...) (attribute clause.name)])
         #`(? object-like?
              clause.matcher ...
              #,@(if (attribute rest-pat)
                     (list #'(app (lambda (obj) (rest-for-match obj '(name ...))) rest-pat))
                     '())))])))
