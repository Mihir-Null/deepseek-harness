#lang racket/base
;; The serialized JSON form of a schema: `schema->jvalue` is Schemastery's `toJSON` and
;; `jvalue->schema` is `new Schema(json)`.
;; source: vendor/schemastery/src/index.ts (Schema.prototype.toJSON, the Schema constructor)
;;
;; Schemastery numbers schemas with a process-wide counter. Here the numbers are assigned when
;; a schema is serialized: the distinct schema values reachable from the root are numbered from
;; 0 in depth-first post-order, so equal schemas give equal text.

(require racket/list
         cordis-data
         "js.rkt"
         "schema.rkt"
         "build.rkt")

(provide schema->jvalue
         jvalue->schema)

;; ---------------------------------------------------------------------------------------------
;; Writing

;; The child schemas of `s` in numbering order: inner, key schema, members, fields. A lazy node
;; is built here.
(define (children s)
  (append (cond
            [(node-builder s) (list (lazy-inner s))]
            [(node-inner s) (list (node-inner s))]
            [else '()])
          (if (node-key s) (list (node-key s)) '())
          (or (node-members s) '())
          (if (node-fields s) (jvalues (node-fields s)) '())))

;; schema->jvalue : schema? -> jobject?
;; {"uid": ROOT, "refs": {"UID": NODE, ...}}, with the nodes in increasing uid order.
(define (schema->jvalue s)
  (define uids (make-hasheq))
  (define ordered
    (let ([done '()])
      (let visit ([s s])
        (unless (hash-has-key? uids s)
          (hash-set! uids s #f)
          (for-each visit (children s))
          (hash-set! uids s (length done))
          (set! done (cons s done))))
      (reverse done)))
  (define (uid-of child) (hash-ref uids child))
  (jobject 'uid (uid-of s)
           'refs (make-jobject
                  (for/list ([node (in-list ordered)])
                    (cons (number->string (uid-of node)) (node->jvalue node uid-of))))))

;; One node: the properties named by the node's order, those without a JSON value left out.
(define (node->jvalue s uid-of)
  (make-jobject
   (for*/list ([property (in-list (node-order s))]
               [value (in-value (property-value s property uid-of))]
               #:unless (json-absent? value))
     (cons property value))))

(define absent (js-json-value (void)))

(define (property-value s property uid-of)
  (case property
    [(type) (node-type s)]
    [(meta)
     (define meta (js-json-value (meta->jobject (node-meta s))))
     (if (json-absent? meta) empty-jobject meta)]
    [(inner)
     (cond
       [(node-builder s) (uid-of (lazy-inner s))]
       [(node-inner s) => uid-of]
       [else absent])]
    [(sKey) (if (node-key s) (uid-of (node-key s)) absent)]
    [(list) (if (node-members s) (map uid-of (node-members s)) absent)]
    [(dict) (if (node-fields s) (jmap (lambda (key child) (uid-of child)) (node-fields s)) absent)]
    [(bits) (if (node-bits s) (js-json-value (node-bits s)) absent)]
    [(value) (js-json-value (node-value s))]
    [(callback)
     (define callback (node-callback s))
     (cond
       [(node-source s) => values]
       [(string? callback) callback]
       [(and (procedure? callback) (symbol? (object-name callback)))
        (symbol->string (object-name callback))]
       [else absent])]
    [(constructor) (or (node-constructor s) absent)]
    [(preserve) (js-json-value (node-preserve s))]
    [else absent]))

;; ---------------------------------------------------------------------------------------------
;; Reading

(define node-properties '(type meta inner sKey list dict bits value callback constructor preserve))

(define (object? v)
  (or (jobject? v) (hash? v)))

(define (malformed message . fields)
  (apply raise-arguments-error 'jvalue->schema message fields))

;; The key of the refs table a uid names: 5 and "5" name "5".
(define (uid-key uid)
  (cond
    [(exact-nonnegative-integer? uid) (string->symbol (number->string uid))]
    [(and (real? uid) (integer? uid) (>= uid 0))
     (string->symbol (number->string (inexact->exact uid)))]
    [(string? uid) (string->symbol uid)]
    [else #f]))

;; The property of a node, or (void) when it is absent or null.
(define (property node key)
  (define value (jref node key (void)))
  (if (nullable? value) (void) value))

;; The child references of a node, as the JSON holds them.
(define (child-specs node)
  (append (let ([inner (property node 'inner)]) (if (void? inner) '() (list inner)))
          (let ([key (property node 'sKey)]) (if (void? key) '() (list key)))
          (let ([members (property node 'list)]) (if (list? members) members '()))
          (let ([fields (property node 'dict)]) (if (object? fields) (jvalues fields) '()))))

;; jvalue->schema : (or/c jobject? hash?) #:resolvers hash? #:revive (or/c procedure? #f)
;;                  -> schema?
;; Accepts the envelope `schema->jvalue` writes and a bare node with inline child nodes. Raises
;; `exn:fail:contract` for a node without a type and for a uid the refs table lacks.
(define (jvalue->schema v #:resolvers [resolvers (hash)] #:revive [revive #f])
  (unless (object? v)
    (malformed "expected a schema object" "given" v))
  (define refs
    (let ([refs (property v 'refs)])
      (cond
        [(void? refs) empty-jobject]
        [(object? refs) (->object refs)]
        [else (malformed "refs is not an object" "refs" refs)])))

  ;; Every node has a type and names only uids the table holds.
  (define (check node)
    (unless (object? node)
      (malformed "schema node is not an object" "node" node))
    (unless (string? (jref node 'type (void)))
      (malformed "schema node has no type" "node" node))
    (when (and (equal? (jref node 'type) "lazy") (void? (property node 'inner)))
      (malformed "lazy schema node has no inner schema" "node" node))
    (for ([spec (in-list (child-specs node))])
      (cond
        [(object? spec) (check spec)]
        [(uid-key spec) => (lambda (key)
                             (unless (jhas? refs key)
                               (malformed "unknown schema uid" "uid" spec)))]
        [else (malformed "schema reference is neither a uid nor a node" "reference" spec)])))

  (define built (make-hasheq))
  (define building (make-hasheq))

  ;; The schema of a uid. A reference back to a node that is still being built is a lazy node
  ;; that looks the finished schema up.
  (define (ref key)
    (cond
      [(hash-ref built key #f) => values]
      [(hash-ref building key #f)
       (make-node "lazy"
                  #:builder (lambda () (hash-ref built key))
                  #:prebuilt? #t
                  #:order '(type inner meta))]
      [else
       (hash-set! building key #t)
       (define s (build (jref refs key)))
       (hash-remove! building key)
       (hash-set! built key s)
       s]))

  (define (child spec)
    (if (object? spec)
        (build spec)
        (ref (uid-key spec))))

  (define (build node)
    (define type (jref node 'type))
    (define meta
      (let ([meta (property node 'meta)])
        (if (object? meta)
            (for/list ([(key value) (in-jobject (->object meta))])
              (cons key (normalize-value value)))
            '())))
    (define order
      (let ([present (filter (lambda (key) (memq key node-properties)) (jkeys node))])
        (if (memq 'meta present) present (append present '(meta)))))
    (define (child-of key)
      (define spec (property node key))
      (if (void? spec) #f (child spec)))
    (define callback (property node 'callback))
    (define revived
      (and (string? callback) revive (revive callback)))
    (define resolver
      (or (hash-ref resolvers type #f)
          (hash-ref resolvers (string->symbol type) #f)))
    (cond
      [(equal? type "lazy")
       (define spec (property node 'inner))
       (make-node type
                  #:meta meta
                  #:builder (lambda () (child spec))
                  #:prebuilt? #t
                  #:resolver resolver
                  #:order order)]
      [else
       (make-node type
                  #:meta meta
                  #:inner (child-of 'inner)
                  #:key (child-of 'sKey)
                  #:members (let ([members (property node 'list)])
                              (and (list? members) (map child members)))
                  #:fields (let ([fields (property node 'dict)])
                             (and (object? fields)
                                  (jmap (lambda (key spec) (child spec)) (->object fields))))
                  #:bits (let ([bits (property node 'bits)])
                           (and (object? bits) (->object bits)))
                  #:value (normalize-value (jref node 'value (void)))
                  #:callback (cond
                               [(procedure? revived) revived]
                               [(string? callback) callback]
                               [else #f])
                  #:source (and (string? callback) callback)
                  #:constructor (let ([name (property node 'constructor)])
                                  (and (string? name) name))
                  #:preserve (jref node 'preserve (void))
                  #:resolver resolver
                  #:order order)]))

  (cond
    [(void? (property v 'refs))
     (check v)
     (build v)]
    [else
     (for ([node (in-list (jvalues refs))])
       (check node))
     (define key (uid-key (jref v 'uid (void))))
     (unless (and key (jhas? refs key))
       (malformed "unknown schema uid" "uid" (jref v 'uid (void))))
     (ref key)]))
