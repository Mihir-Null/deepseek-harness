#lang racket/base
;; Services (contract section 5; vendor/cordis/src/reflect.ts and service.ts): the store of
;; implementations by realm, the reflective and the checked read, accessors and mixins,
;; interception config, and service handles.
(require racket/list
         "scheduler.rkt"
         "breaks.rkt"
         "errors.rkt"
         "core.rkt"
         "effect.rkt"
         "events.rkt"
         "lifecycle.rkt")

(provide ctx-provide ctx-get ctx-set! ctx-ref ctx-has? ctx-accessor ctx-mixin
         service-resolve-config default-merge current-mixin-resolver
         (struct-out service-handle) use-context service-value)

;; ---------------------------------------------------------------------------------------
;; Provide, get, set

(define (ctx-provide ctx key [value (void)] #:check [check #f])
  (define name (->key key))
  (call/kernel
   ctx
   (lambda ()
     (ctx-effect* ctx
                  (lambda () (provide! ctx name value check))
                  (format "ctx.provide(~a)" (json-string name))
                  #:kernel? #t))))

;; Installs the implementation and returns its inverse.
(define (provide! ctx name value check)
  (critical
   (define k (context-kernel ctx))
   (define props (kernel-props k))
   (define store (kernel-store k))
   (when (accessor? (hash-ref props name #f))
     (raise-service name (format "property \"~a\" is already declared as accessor" name)))
   (hash-set! props name 'service)
   ;; the default realm of a name is created at its first provide
   (unless (hash-ref (kernel-realms k) name #f)
     (hash-set! (kernel-realms k) name (make-realm name)))
   (define realm (context-realm ctx name))
   (set-kernel-impl-counter! k (add1 (kernel-impl-counter k)))
   (define existing (hash-ref store realm #f))
   (when existing
     (raise-service name
                    (format "service \"~a\" has been registered at <~a>"
                            name (fiber-name (context-fiber (impl-ctx existing))))))
   (define i (impl (kernel-impl-counter k) name value ctx check realm (make-hasheq) #f))
   (define f (context-fiber ctx))
   (hash-set! store realm i)
   (set-fiber-provided! f (append (fiber-provided f) (list i)))
   ;; a provider that is not active yet becomes visible when its fiber activates
   (when (eq? (fiber-state f) 'active)
     (notify! ctx (list name)))
   (kernel-inverse (lambda () (withdraw! ctx f i)))))

;; The inverse of a provision. Dependents are told first and may still read the service
;; while they unload; the provision leaves its fiber only when the last one is done.
(define (withdraw! ctx f i)
  (critical
   (define k (context-kernel ctx))
   (define store (kernel-store k))
   (define name (impl-key i))
   (when (eq? (hash-ref store (impl-realm i) #f) i)
     (hash-remove! store (impl-realm i)))
   (notify! (context-isolate ctx name (impl-realm i)) (list name))
   (cond
     ;; yield even without dependents, so that cleanup of child fibers queued behind this
     ;; inverse can still read the service
     [(zero? (hash-count (impl-dependents i))) (yield-task)]
     [else
      (define l (make-latch (kernel-scheduler k)))
      (set-impl-release! i l)
      (latch-wait l)])
   (set-impl-release! i #f)
   (set-fiber-provided! f (remq i (fiber-provided f)))
   (void)))

(define (ctx-get ctx key #:strict? [strict? #t] #:default [default #f])
  (define i (get-impl ctx (->key key) strict?))
  (if i (impl-value i) default))

(define (ctx-has? ctx key)
  (and (get-impl ctx (->key key) #f) #t))

;; An accessor name goes to its setter. A service name goes through the `internal/set`
;; waterfall, whose innermost step replaces the value in place without notifying anyone.
(define (ctx-set! ctx key value)
  (define name (->key key))
  (call/kernel
   ctx
   (lambda ()
     (define decl (hash-ref (kernel-props (context-kernel ctx)) name #f))
     (cond
       [(accessor? decl)
        (unless (accessor-set decl)
          (raise-service name (format "cannot set property \"~a\" without setter" name)))
        ((accessor-set decl) ctx value)]
       [(not decl)
        (raise-service name (format "cannot set property \"~a\" without provide" name))]
       [else
        (dispatch-waterfall ctx 'internal/set (list ctx name value)
                            (lambda () (replace-value! ctx name value)))])
     (void))))

;; source: vendor/cordis/src/reflect.ts (set)
(define (replace-value! ctx name value)
  (define i (get-impl ctx name #f))
  (unless i
    (raise-service name (format "cannot set property \"~a\" without provide" name)))
  (unless (eq? (context-fiber (impl-ctx i)) (context-fiber ctx))
    (raise-service name (format "cannot set property \"~a\" in multiple fibers" name)))
  (set-impl-value! i value)
  #t)

;; ---------------------------------------------------------------------------------------
;; Checked read (vendor/cordis/src/reflect.ts, the proxy `get` trap)

(define without-inject "cannot get property \"~a\" without inject")
(define inactive-inject "cannot get required service \"~a\" in inactive context")

(define (ctx-ref ctx key)
  (define name (->key key))
  (call/kernel ctx (lambda () (checked-read ctx name))))

(define (checked-read ctx name)
  (define decl (hash-ref (kernel-props (context-kernel ctx)) name #f))
  (cond
    [(accessor? decl) ((accessor-get decl) ctx)]
    ;; a context of the root fiber cannot declare inject and reads unchecked, non-strictly
    [(fiber-root? (context-fiber ctx))
     (define i (get-impl ctx name #f))
     (unless i (raise-inject name without-inject))
     (impl-value i)]
    [else
     (dispatch-waterfall ctx 'internal/get (list ctx name)
                         (lambda () (authorized-read ctx name)))]))

;; Walks from the reading fiber upward. A fiber authorizes the read through its committed
;; view or through its own provision in the reader's realm. The walk ends at the root and at
;; a parent that maps the name to another realm.
(define (authorized-read ctx name)
  (define realm (context-realm ctx name))
  (let loop ([f (context-fiber ctx)])
    (define commit (fiber-commit f))
    (define i
      (or (for/last ([p (in-list (fiber-provided f))]
                     #:when (and (eq? (impl-key p) name)
                                 (eq? (context-realm (impl-ctx p) name) realm)))
            p)
          (and commit (hash-ref commit name #f))))
    (cond
      [i (impl-value i)]
      [(fiber-injects? f name) (raise-inject name inactive-inject)]
      [(fiber-root? f) (raise-inject name without-inject)]
      [(not (eq? (context-realm (fiber-parent-ctx f) name) realm))
       (raise-inject name without-inject)]
      [else (loop (context-fiber (fiber-parent-ctx f)))])))

;; ---------------------------------------------------------------------------------------
;; Accessors and mixins

(define (ctx-accessor ctx name #:get getter #:set [setter #f])
  (define key (->key name))
  (call/kernel
   ctx
   (lambda ()
     (ctx-effect*
      ctx
      (lambda ()
        (define props (kernel-props (context-kernel ctx)))
        (define decl (hash-ref props key #f))
        (when decl
          (raise-service key
                         (format "property \"~a\" is already declared as ~a"
                                 key (if (accessor? decl) "accessor" "service"))))
        (hash-set! props key (accessor getter setter))
        (kernel-inverse (lambda () (hash-remove! props key))))
      (format "ctx.accessor(~a)" (json-string key))
      #:kernel? #t))))

;; Resolves a member of a service value that is not a hash: (-> service-value symbol? any/c).
(define current-mixin-resolver
  (make-parameter
   (lambda (service member)
     (raise-service member
                    (format "cannot resolve mixin member \"~a\" of a service that is not a hash"
                            member)))))

;; names : a list of member names, or a hash from member name to the name on the context.
;; Each mixed-in name is an accessor, collected as a child of this effect.
(define (ctx-mixin ctx source names)
  (define src (->key source))
  (define entries
    (if (hash? names)
        (sort (for/list ([(member name) (in-hash names)]) (cons (->key member) (->key name)))
              symbol<? #:key car)
        (for/list ([member (in-list names)]) (cons (->key member) (->key member)))))
  (call/kernel
   ctx
   (lambda ()
     (ctx-effect*
      ctx
      (lambda ()
        ;; all accessors or none: one that cannot be declared undoes those before it
        (let loop ([entries entries] [made '()])
          (cond
            [(null? entries) (reverse made)]
            [else
             (define member (caar entries))
             (define d
               (with-handlers ([(lambda (e) #t)
                                (lambda (e)
                                  (for ([m (in-list made)]) (dispose! m))
                                  (raise e))])
                 (ctx-accessor ctx (cdar entries)
                               #:get (lambda (c) (mixin-ref c src member))
                               #:set (lambda (c v) (mixin-set! c src member v)))))
             (loop (cdr entries) (cons d made))])))
      (format "ctx.mixin(~a)" (json-string src))
      #:kernel? #t))))

(define (mixin-ref ctx source member)
  (define service (ctx-ref ctx source))
  (cond
    [(or (not service) (void? service) (eq? service 'null)) service]
    [(hash? service) (hash-ref service member #f)]
    [else ((current-mixin-resolver) service member)]))

(define (mixin-set! ctx source member value)
  (define service (ctx-ref ctx source))
  (unless (and (hash? service) (not (immutable? service)))
    (raise-service member
                   (format "cannot set mixin member \"~a\" of a service that is not a mutable hash"
                           member)))
  (hash-set! service member value))

;; ---------------------------------------------------------------------------------------
;; Interception config

;; Hashes merge right-biased; when a config is not a hash the last config wins. #f is skipped.
(define (default-merge . configs)
  (define present (filter values configs))
  (cond
    [(null? present) (hasheq)]
    [(andmap hash? present)
     (for/fold ([acc (let ([h (car present)])
                       (if (immutable? h)
                           h
                           (for/hasheq ([(key v) (in-hash h)]) (values key v))))])
               ([h (in-list (cdr present))])
       (for/fold ([acc acc]) ([(key v) (in-hash h)])
         (hash-set acc key v)))]
    [else (last present)]))

;; `merge` receives all configs as arguments; a merge of exactly two arguments is folded
;; from the left instead.
(define (service-resolve-config x key
                                #:base [base #f]
                                #:head [head #f]
                                #:merge [merge default-merge])
  (define configs
    (append (if base (list base) '())
            (context-intercepts (use-context x) (->key key))
            (if head (list head) '())))
  (cond
    [(procedure-arity-includes? merge (length configs)) (apply merge configs)]
    [(and (pair? configs) (procedure-arity-includes? merge 2))
     (for/fold ([acc (car configs)]) ([c (in-list (cdr configs))])
       (merge acc c))]
    [else (apply merge configs)]))

;; ---------------------------------------------------------------------------------------
;; Service handles (ADR 0003)

;; A capability: service `key` as seen from `ctx`.
(struct service-handle (ctx key) #:transparent)

(define (use-context x)
  (if (service-handle? x) (service-handle-ctx x) x))

(define (service-value x key)
  (define name (->key key))
  (when (and (service-handle? x) (not (eq? (service-handle-key x) name)))
    (raise-arguments-error 'service-value "handle is for another service"
                           "handle key" (service-handle-key x)
                           "requested key" name))
  (ctx-ref (use-context x) name))
