#lang racket/base
;; `define-plugin` and `plugin-info` (contract section 9; ADRs 0003 and 0005).
;;
;; `define-plugin` builds a plugin from a declaration. In its body each required injected
;; service is a variable that holds a service handle on the plugin's context, and each
;; optional service is an identifier macro that reads the service with `ctx-get` at every
;; use. A body that names a service it did not declare has an unbound identifier.
;; `plugin-info` returns a plugin's declaration as data.
(require (for-syntax racket/base
                     syntax/parse)
         racket/contract/base
         (only-in "core.rkt" plugin plugin-optional)
         (only-in "lifecycle.rkt" normalize-inject)
         (only-in "service.rkt" service-handle ctx-get)
         "plugin-api.rkt")

(provide define-plugin
         (contract-out
          ;; 'name : string or #f; 'inject : required keys in declaration order;
          ;; 'optional : keys a `define-plugin` body reads when they exist;
          ;; 'provides : declared keys; 'config-schema : the schema or #f.
          [plugin-info (-> plugin? (and/c hash? immutable?))]))

(define (plugin-info p)
  (hasheq 'name (plugin-name p)
          'inject (map car (normalize-inject (plugin-inject p)))
          'optional (plugin-optional p)
          'provides (plugin-provides p)
          'config-schema (plugin-config-schema p)))

;; `make-plugin` plus the optional keys of the declaration. Not exported from the package.
(define (declare-plugin apply name inject optional schema provides mode meta)
  (struct-copy plugin
               (make-plugin apply
                            #:name name
                            #:inject inject
                            #:config schema
                            #:provides provides
                            #:custodian mode
                            #:meta meta)
               [optional optional]))

(begin-for-syntax
  (define option-keywords '(#:name #:inject #:config #:provides #:custodian #:meta))

  (define (keyword-of stx)
    (define v (syntax-e stx))
    (and (keyword? v) v))

  ;; Splits the forms after the plugin's name into an option table (keyword -> syntax of
  ;; its value) and the body forms. `#:apply` starts the body.
  (define (split-options stx forms)
    (let loop ([forms forms] [options (hasheq)])
      (define kw (and (pair? forms) (keyword-of (car forms))))
      (cond
        [(or (not kw) (eq? kw '#:apply)) (values options forms)]
        [(not (memq kw option-keywords))
         (raise-syntax-error
          #f
          (string-append "unknown keyword; expected #:name, #:inject, #:config, #:provides, "
                         "#:custodian, #:meta or #:apply")
          stx (car forms))]
        [(hash-ref options kw #f)
         (raise-syntax-error #f (format "duplicate #:~a clause" (keyword->string kw))
                             stx (car forms))]
        [(null? (cdr forms))
         (raise-syntax-error #f (format "missing value after #:~a" (keyword->string kw))
                             stx (car forms))]
        [else (loop (cddr forms) (hash-set options kw (cadr forms)))])))

  (define-syntax-class inject-clause
    #:description
    "an inject clause: key, [key #:optional], [key #:as local-id] or [key #:intercept expr]"
    #:attributes (key local optional? intercept)
    (pattern key:id
             #:with local #'key
             #:attr optional? #f
             #:attr intercept #f)
    (pattern [key:id #:optional]
             #:with local #'key
             #:attr optional? #t
             #:attr intercept #f)
    (pattern [key:id #:as local:id]
             #:attr optional? #f
             #:attr intercept #f)
    (pattern [key:id #:intercept intercept:expr]
             #:with local #'key
             #:attr optional? #f))

  (define (check-distinct-keys stx keys what)
    (let loop ([keys keys] [seen '()])
      (unless (null? keys)
        (when (memq (syntax-e (car keys)) seen)
          (raise-syntax-error #f (format "duplicate ~a" what) stx (car keys)))
        (loop (cdr keys) (cons (syntax-e (car keys)) seen))))))

(define-syntax (define-plugin stx)
  (syntax-parse stx
    [(_ plugin-id:id form ...)
     (define-values (options body) (split-options stx (syntax->list #'(form ...))))
     (define (option kw) (hash-ref options kw #f))

     (define/syntax-parse (inj:inject-clause ...)
       (syntax-parse (or (option '#:inject) #'())
         #:context stx
         [(clause:inject-clause ...) #'(clause ...)]
         [_ (raise-syntax-error #f "expected a parenthesized list of inject clauses after #:inject"
                                stx (option '#:inject))]))
     (check-distinct-keys stx (syntax->list #'(inj.key ...)) "injected key")
     (define/syntax-parse (provided:id ...)
       (syntax-parse (or (option '#:provides) #'())
         #:context stx
         [(key:id ...) #'(key ...)]
         [_ (raise-syntax-error #f "expected a parenthesized list of keys after #:provides"
                                stx (option '#:provides))]))
     (check-distinct-keys stx (syntax->list #'(provided ...)) "provided key")

     (define clauses
       (for/list ([key (in-list (syntax->list #'(inj.key ...)))]
                  [local (in-list (syntax->list #'(inj.local ...)))]
                  [optional? (in-list (attribute inj.optional?))]
                  [intercept (in-list (attribute inj.intercept))])
         (list key local optional? intercept)))
     (define required (filter (lambda (c) (not (caddr c))) clauses))
     (define optional (filter caddr clauses))

     (define/syntax-parse name
       (syntax-parse (or (option '#:name) #'(symbol->string 'plugin-id))
         #:context stx
         [(~var e (expr/c #'(or/c string? symbol?) #:name "#:name value")) #'e.c]))
     (define/syntax-parse schema
       (syntax-parse (or (option '#:config) #'#f)
         #:context stx
         [e:expr #'e]))
     (define/syntax-parse mode
       (syntax-parse (or (option '#:custodian) #''own)
         #:context stx
         [(~or (~datum own) (~datum inherit)) #`(quote #,this-syntax)]
         [(~var e (expr/c #'(or/c 'own 'inherit) #:name "#:custodian value")) #'e.c]))
     (define/syntax-parse meta
       (syntax-parse (or (option '#:meta) #'(hasheq))
         #:context stx
         [(~var e (expr/c #'hash? #:name "#:meta value")) #'e.c]))
     (define/syntax-parse (inject-entry ...)
       (for/list ([c (in-list required)])
         (if (cadddr c)
             #`(cons '#,(car c) #,(cadddr c))
             #`'#,(car c))))
     (define/syntax-parse (optional-key ...) (map car optional))

     ;; The body as a procedure of (ctx config). In the two forms that spell the body out,
     ;; the injected services are bound around it.
     (define (bind-services ctx-id config-id forms)
       (define locals (map cadr clauses))
       (define duplicate (check-duplicate-identifier locals))
       (when duplicate
         (raise-syntax-error #f "duplicate name for an injected service" stx duplicate))
       (for ([local (in-list locals)])
         (when (or (bound-identifier=? local ctx-id) (bound-identifier=? local config-id))
           (raise-syntax-error
            #f "an injected service has the name of the body's context or config argument"
            stx local)))
       (with-syntax ([ctx ctx-id]
                     [config config-id]
                     [(body-form ...) forms]
                     [((required-key required-local) ...)
                      (map (lambda (c) (list (car c) (cadr c))) required)]
                     [((optional-key optional-local) ...)
                      (map (lambda (c) (list (car c) (cadr c))) optional)])
         #'(lambda (ctx config)
             (let ([the-ctx ctx])
               (let ([required-local (service-handle the-ctx 'required-key)] ...)
                 (let-syntax ([optional-local
                               (make-optional-service #'the-ctx #'optional-key)]
                              ...)
                   body-form ...))))))
     (define/syntax-parse apply-proc
       (syntax-parse (datum->syntax #f body)
         #:context stx
         #:literals (lambda λ)
         [(#:apply (~var e (expr/c #'(and/c procedure? (procedure-arity-includes/c 2))
                                   #:name "#:apply value")))
          #'e.c]
         [(#:apply . _)
          (raise-syntax-error #f "expected exactly one expression after #:apply" stx)]
         [(((~or lambda λ) (ctx:id config:id) e:expr ...+))
          (bind-services #'ctx #'config (syntax->list #'(e ...)))]
         [(((~or lambda λ) . _))
          (raise-syntax-error
           #f
           (string-append "a lambda body takes exactly a context and a config argument and "
                          "has at least one body form; pass another procedure with #:apply")
           stx (car body))]
         [((ctx:id config:id) e:expr ...+)
          (bind-services #'ctx #'config (syntax->list #'(e ...)))]
         [()
          (raise-syntax-error
           #f
           (string-append "missing body; expected (lambda (ctx config) body ...), "
                          "(ctx config) body ..., or #:apply expr")
           stx)]
         [_
          (raise-syntax-error
           #f
           (string-append "the body is not a lambda form and there is no #:apply; expected "
                          "(lambda (ctx config) body ...), (ctx config) body ..., "
                          "or #:apply expr")
           stx (car body))]))

     #'(define plugin-id
         (declare-plugin (let ([plugin-id apply-proc]) plugin-id)
                         name
                         (list inject-entry ...)
                         '(optional-key ...)
                         schema
                         '(provided ...)
                         mode
                         meta))]))

;; The transformer of an optional service's identifier: each use reads the service as it is
;; now, and is #f while nothing provides it.
(begin-for-syntax
  (define (make-optional-service ctx-id key-id)
    (make-set!-transformer
     (lambda (stx)
       (syntax-case stx (set!)
         [(set! name . _)
          (raise-syntax-error #f "cannot assign to an optional service" stx #'name)]
         [(name arg ...)
          (with-syntax ([ctx ctx-id] [key key-id])
            (syntax/loc stx ((ctx-get ctx 'key) arg ...)))]
         [name
          (identifier? #'name)
          (with-syntax ([ctx ctx-id] [key key-id])
            (syntax/loc stx (ctx-get ctx 'key)))])))))
