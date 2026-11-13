#lang racket/base
;; Services: contract section 5. Provide and withdraw, the reflective read, in-place set,
;; the checked read with its three failures, checks, accessors, mixins, interception
;; config and service handles.
(require rackunit
         racket/list
         cordis
         cordis/testing
         "common.rkt")

(define (labels f) (map disposer-label (fiber-effects f)))

(define (mount ctx body #:inject [inject '()] #:name [name #f])
  (ctx-plugin ctx (make-plugin (lambda (c config) (body c) (void)) #:inject inject #:name name)))

;; ---------------------------------------------------------------------------------------
;; ctx-provide

(test-case "provide: an effect labelled ctx.provide(\"key\"); has?, get; withdraw removes it"
  (with-root-context (ctx)
    (check-false (ctx-has? ctx 'db))
    (check-false (context-realm ctx 'db))
    (define d (ctx-provide ctx 'db 'the-db))
    (check-equal? (disposer-label d) "ctx.provide(\"db\")")
    (check-true (symbol? (context-realm ctx 'db)))
    (check-false (symbol-interned? (context-realm ctx 'db)))
    (check-true (ctx-has? ctx 'db))
    (check-equal? (ctx-get ctx 'db) 'the-db)
    (check-equal? (ctx-get ctx "db") 'the-db)
    (check-equal? (fiber-provisions (context-fiber ctx)) '(db))
    (d)
    (check-false (ctx-has? ctx 'db))
    (check-false (ctx-get ctx 'db))
    (check-equal? (ctx-get ctx 'db #:default 'none) 'none)
    (check-equal? (fiber-provisions (context-fiber ctx)) '())
    ;; the name keeps its root realm
    (check-true (symbol? (context-realm ctx 'db)))))

(test-case "provide: the default value is void; uids are fresh for every provision"
  (with-root-context (ctx)
    (ctx-provide ctx 'flag)
    (check-true (ctx-has? ctx 'flag))
    (check-equal? (ctx-get ctx 'flag #:default 'absent) (void))
    (check-equal? (ctx-ref ctx 'flag) (void))))

(test-case "provide: a second provider in the same realm raises and changes nothing"
  (with-root-context (ctx)
    (define f (mount ctx (lambda (c) (ctx-provide c 'db 'first)) #:name "first-provider"))
    (await/t f)
    (check-exn-message exn:fail:cordis:service?
                       #rx"^service \"db\" has been registered at <first-provider>$"
                       (lambda () (ctx-provide ctx 'db 'second)))
    (check-equal? (ctx-get ctx 'db) 'first)
    (check-equal? (labels (context-fiber ctx)) '("ctx.plugin()"))
    (check-equal? (exn:fail:cordis:service-key
                   (with-handlers ([exn:fail:cordis:service? values]) (ctx-provide ctx 'db 2)))
                  'db)))

(test-case "provide: a provider that is not active is invisible to strict reads and dependents"
  (with-root-context (ctx)
    (define g (gate))
    (define provider (mount ctx (lambda (c) (ctx-provide c 'db 'early) (gate-wait g))))
    (define consumer (mount ctx void #:inject '(db)))
    (yield-task)
    (check-eq? (fiber-state provider) 'loading)
    (check-true (ctx-has? ctx 'db))
    (check-false (ctx-get ctx 'db))
    (check-equal? (ctx-get ctx 'db #:strict? #f) 'early)
    (check-eq? (fiber-state consumer) 'pending)
    (gate-open! g)
    (await/t provider)
    (check-equal? (ctx-get ctx 'db) 'early)
    (await/t consumer)
    (check-eq? (fiber-state consumer) 'active)))

(test-case "provide: an active fiber that provides late notifies at once"
  (with-root-context (ctx)
    (define consumer (mount ctx void #:inject '(late)))
    (check-eq? (fiber-state consumer) 'pending)
    (ctx-provide ctx 'late 1)
    (check-eq? (fiber-state consumer) 'loading)
    (await/t consumer)
    (check-eq? (fiber-state consumer) 'active)))

(test-case "notify: internal/service reaches listeners of the same realm only"
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (define isolated (context-isolate ctx 'db))
    (ctx-on ctx 'internal/service (lambda (name value) (note (list 'shared name value))))
    (ctx-on isolated 'internal/service (lambda (name value) (note (list 'isolated name value))))
    (ctx-on isolated 'internal/service (lambda (name value) (note (list 'global name value)))
            #:global? #t)
    (define d (ctx-provide ctx 'db 1))
    (d)
    (define d2 (ctx-provide isolated 'db 2))
    (d2))
  (check-equal? (notes)
                '((shared db 1) (global db 1) (shared db #f) (global db #f)
                  (isolated db 2) (global db 2) (isolated db #f) (global db #f))))

(test-case "withdraw: waits for dependents, which can still read the service"
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (define g (gate))
    (define started (gate))
    (define d (ctx-provide ctx 'db 'alive))
    (define consumer
      (mount ctx
             (lambda (c)
               (ctx-effect c (lambda ()
                               (lambda ()
                                 (gate-open! started)
                                 (gate-wait g)
                                 (note (list 'consumer-cleanup (ctx-ref c 'db)))))))
             #:inject '(db)))
    (await/t consumer)
    (define withdrawal (spawn-task (lambda () (d) (note 'withdrawn))))
    (gate-wait started)
    (check-false (task-done? withdrawal))
    ;; out of the store at once, still held by the provider until the dependent is done
    (check-false (ctx-has? ctx 'db))
    (check-equal? (fiber-provisions (context-fiber ctx)) '(db))
    (gate-open! g)
    (await/t withdrawal)
    (check-equal? (fiber-provisions (context-fiber ctx)) '())
    (check-eq? (fiber-state consumer) 'pending))
  (check-equal? (notes) '((consumer-cleanup alive) withdrawn)))

;; ---------------------------------------------------------------------------------------
;; ctx-set!

(test-case "set!: replaces the value in place without notifying dependents"
  (define applies 0)
  (with-root-context (ctx)
    (ctx-provide ctx 'config 1)
    (define consumer (mount ctx (lambda (c) (set! applies (add1 applies))) #:inject '(config)))
    (await/t consumer)
    (define events '())
    (ctx-on ctx 'internal/service (lambda (name value) (set! events (cons name events))))
    (check-equal? (ctx-set! ctx 'config 2) (void))
    (yield-task)
    (check-equal? (ctx-get ctx 'config) 2)
    (check-equal? (ctx-ref (fiber-context consumer) 'config) 2)
    (check-equal? (hash-ref (fiber-committed consumer) 'config) 2)
    (check-eq? (fiber-state consumer) 'active)
    (check-equal? events '()))
  (check-equal? applies 1))

(test-case "set!: the three failures"
  (with-root-context (ctx)
    (check-exn-message exn:fail:cordis:service?
                       #rx"^cannot set property \"nothing\" without provide$"
                       (lambda () (ctx-set! ctx 'nothing 1)))
    (define d (ctx-provide ctx 'db 1))
    (define other (mount ctx void))
    (await/t other)
    (check-exn-message exn:fail:cordis:service? #rx"^cannot set property \"db\" in multiple fibers$"
                       (lambda () (ctx-set! (fiber-context other) 'db 2)))
    (check-equal? (ctx-get ctx 'db) 1)
    (d)
    ;; declared once, now without an implementation
    (check-exn-message exn:fail:cordis:service? #rx"^cannot set property \"db\" without provide$"
                       (lambda () (ctx-set! ctx 'db 3)))))

(test-case "set!: runs the internal/set waterfall around the in-place replacement"
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (ctx-provide ctx 'db 1)
    (define d (ctx-on ctx 'internal/set
                      (lambda (c name value next)
                        (note (list (eq? c ctx) name value))
                        (next))))
    (ctx-set! ctx 'db 2)
    (check-equal? (ctx-get ctx 'db) 2)
    (d)
    ;; a listener that does not call next vetoes the write
    (ctx-on ctx 'internal/set (lambda (c name value next) 'vetoed))
    (ctx-set! ctx 'db 3)
    (check-equal? (ctx-get ctx 'db) 2))
  (check-equal? (notes) '((#t db 2))))

;; ---------------------------------------------------------------------------------------
;; ctx-ref

(test-case "ref step 2: a context of the root fiber reads unchecked and non-strictly"
  (with-root-context (ctx)
    (check-exn-message exn:fail:cordis:inject? #rx"^cannot get property \"db\" without inject$"
                       (lambda () (ctx-ref ctx 'db)))
    (define g (gate))
    (define provider (mount ctx (lambda (c) (ctx-provide c 'db 'loading-value) (gate-wait g))))
    (yield-task)
    (check-eq? (fiber-state provider) 'loading)
    (check-equal? (ctx-ref ctx 'db) 'loading-value)
    (check-equal? (ctx-ref (context-extend ctx (hasheq 'x 1)) "db") 'loading-value)
    (gate-open! g)
    (await/t provider)
    (check-eq? (fiber-state provider) 'active)))

(test-case "ref step 3: injection, own provision, ancestors, and the two failures"
  (with-root-context (ctx)
    (ctx-provide ctx 'root-service 'from-root)
    (define provider (mount ctx (lambda (c) (ctx-provide c 'db 'the-db)) #:name "provider"))
    (await/t provider)
    (define child-ctx #f)
    (define sibling-ctx #f)
    (define consumer
      (mount ctx
             (lambda (c)
               (ctx-provide c 'own 'own-value)
               (ctx-plugin c (lambda (inner config) (set! child-ctx inner) (void))))
             #:inject '(db)))
    (define sibling (mount ctx (lambda (c) (set! sibling-ctx c))))
    (await/t consumer)
    (await/t sibling)
    (yield-task)
    (define c (fiber-context consumer))
    ;; committed injection, own provision, a service of the root
    (check-equal? (ctx-ref c 'db) 'the-db)
    (check-equal? (ctx-ref c 'own) 'own-value)
    (check-equal? (ctx-ref c 'root-service) 'from-root)
    ;; a child inherits what its parent may read
    (check-equal? (ctx-ref child-ctx 'db) 'the-db)
    (check-equal? (ctx-ref child-ctx 'own) 'own-value)
    ;; a sibling declared nothing
    (check-exn-message exn:fail:cordis:inject? #rx"^cannot get property \"db\" without inject$"
                       (lambda () (ctx-ref sibling-ctx 'db)))
    (check-exn-message exn:fail:cordis:inject? #rx"^cannot get property \"own\" without inject$"
                       (lambda () (ctx-ref sibling-ctx 'own)))
    ;; the reflective read ignores inject
    (check-equal? (ctx-get sibling-ctx 'db) 'the-db)
    ;; an injected name that is not committed
    (fiber-dispose! provider)
    (check-eq? (fiber-state consumer) 'pending)
    (check-exn-message exn:fail:cordis:inject?
                       #rx"^cannot get required service \"db\" in inactive context$"
                       (lambda () (ctx-ref c 'db)))
    (check-equal? (exn:fail:cordis:inject-key
                   (with-handlers ([exn:fail:cordis:inject? values]) (ctx-ref c 'db)))
                  'db)))

(test-case "ref step 3: the walk stops where a parent maps the name to another realm"
  (with-root-context (ctx)
    (ctx-provide ctx 'db 'outer)
    (define inner-ctx #f)
    (define plugin-ctx #f)
    (define child-ctx #f)
    (define f
      (mount ctx
             (lambda (c)
               (set! plugin-ctx c)
               (set! inner-ctx (context-isolate c 'db))
               (ctx-provide inner-ctx 'db 'inner)
               (ctx-plugin inner-ctx (lambda (cc config) (set! child-ctx cc) (void))))
             #:inject '(db)))
    (await/t f)
    (yield-task)
    ;; own isolated provision against committed injection
    (check-equal? (ctx-ref plugin-ctx 'db) 'outer)
    (check-equal? (ctx-ref inner-ctx 'db) 'inner)
    (check-equal? (ctx-ref child-ctx 'db) 'inner)
    ;; a plugin mounted on an isolated context cannot reach across the realm boundary
    (define island (context-isolate ctx 'db))
    (define island-ctx #f)
    (define g (mount island (lambda (c) (set! island-ctx c))))
    (await/t g)
    (check-exn-message exn:fail:cordis:inject? #rx"without inject"
                       (lambda () (ctx-ref island-ctx 'db)))))

(test-case "ref: the internal/get waterfall wraps reads from plugin contexts"
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (ctx-provide ctx 'db 'real)
    (define f (mount ctx void))
    (await/t f)
    (define c (fiber-context f))
    (define d (ctx-on ctx 'internal/get
                      (lambda (reader name next)
                        (note (list (eq? reader c) name))
                        (if (eq? name 'virtual) 'made-up (next)))))
    (check-equal? (ctx-ref c 'db) 'real)
    (check-equal? (ctx-ref c 'virtual) 'made-up)
    ;; reads through the root fiber do not run the waterfall
    (check-equal? (ctx-ref ctx 'db) 'real)
    (d))
  (check-equal? (notes) '((#t db) (#t virtual))))

;; ---------------------------------------------------------------------------------------
;; #:check

(test-case "check: called with the dependent's context; false or an exception hides the service"
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (define allowed (context-extend ctx (hasheq 'role 'admin)))
    (define denied (context-extend ctx (hasheq 'role 'guest)))
    (define exploding (context-extend ctx (hasheq 'role 'explode)))
    (ctx-provide ctx 'vault 'gold
                 #:check (lambda (c)
                           (note (context-meta c 'role))
                           (case (context-meta c 'role)
                             [(admin) #t]
                             [(explode) (raise-user-error "check exploded")]
                             [else #f])))
    (define f1 (mount allowed void #:inject '(vault)))
    (define f2 (mount denied void #:inject '(vault)))
    (define f3 #f)
    (define-values (_ events)
      (capture-log (lambda () (set! f3 (mount exploding void #:inject '(vault))))))
    (await/t f1)
    (check-eq? (fiber-state f1) 'active)
    (check-eq? (fiber-state f2) 'pending)
    (check-eq? (fiber-state f3) 'pending)
    (check-equal? (length events) 1)
    (check-regexp-match #rx"check exploded" (vector-ref (car events) 1)))
  (check-equal? (notes) '(admin guest explode)))

;; ---------------------------------------------------------------------------------------
;; Accessors and mixins

(test-case "accessor: getter and setter run with the using context; names are exclusive"
  (with-root-context (ctx)
    (define store (make-hasheq))
    (define d (ctx-accessor ctx 'whoami
                            #:get (lambda (c) (fiber-name (context-fiber c)))
                            #:set (lambda (c v)
                                    (hash-set! store (fiber-name (context-fiber c)) v))))
    (check-equal? (disposer-label d) "ctx.accessor(\"whoami\")")
    (define f (mount ctx void #:name "reader"))
    (await/t f)
    (check-equal? (ctx-ref ctx 'whoami) "root")
    (check-equal? (ctx-ref (fiber-context f) 'whoami) "reader")
    (ctx-set! (fiber-context f) 'whoami 7)
    (check-equal? (hash-ref store "reader") 7)
    (check-exn-message exn:fail:cordis:service?
                       #rx"^property \"whoami\" is already declared as accessor$"
                       (lambda () (ctx-accessor ctx 'whoami #:get void)))
    (check-exn-message exn:fail:cordis:service?
                       #rx"^property \"whoami\" is already declared as accessor$"
                       (lambda () (ctx-provide ctx 'whoami 1)))
    (ctx-provide ctx 'db 1)
    (check-exn-message exn:fail:cordis:service?
                       #rx"^property \"db\" is already declared as service$"
                       (lambda () (ctx-accessor ctx 'db #:get void)))
    (define read-only (ctx-accessor ctx 'read-only #:get (lambda (c) 1)))
    (check-exn exn:fail:cordis:service? (lambda () (ctx-set! ctx 'read-only 2)))
    (d)
    (check-exn exn:fail:cordis:inject? (lambda () (ctx-ref ctx 'whoami)))))

(test-case "mixin: members of a hash-valued service become accessors, as child effects"
  (with-root-context (ctx)
    (define timer (make-hasheq (list (cons 'set-timeout (lambda (ms) (list 'timeout ms)))
                                     (cons 'now 12))))
    (ctx-provide ctx 'timer timer)
    (define d (ctx-mixin ctx 'timer '(set-timeout now)))
    (check-equal? (disposer-label d) "ctx.mixin(\"timer\")")
    (check-equal? (map disposer-label (disposer-children d))
                  '("ctx.accessor(\"set-timeout\")" "ctx.accessor(\"now\")"))
    (check-equal? ((ctx-ref ctx 'set-timeout) 5) '(timeout 5))
    (check-equal? (ctx-ref ctx 'now) 12)
    ;; writes through a mixin reach the source
    (ctx-set! ctx 'now 13)
    (check-equal? (hash-ref timer 'now) 13)
    ;; a member needs the access rights of its source
    (define f (mount ctx void))
    (define injecting (mount ctx void #:inject '(timer)))
    (await/t f)
    (await/t injecting)
    (check-equal? (ctx-ref (fiber-context injecting) 'now) 13)
    (check-equal? (ctx-ref (fiber-context f) 'now) 13)
    (define island (mount (context-isolate ctx 'timer) void))
    (await/t island)
    (check-exn-message exn:fail:cordis:inject? #rx"cannot get property \"timer\" without inject"
                       (lambda () (ctx-ref (fiber-context island) 'now)))
    (d)
    (check-exn exn:fail:cordis:inject? (lambda () (ctx-ref ctx 'now)))
    (check-equal? (map disposer-label (fiber-effects (context-fiber ctx)))
                  '("ctx.provide(\"timer\")" "ctx.plugin()" "ctx.plugin()" "ctx.plugin()"))))

(test-case "mixin: the hash form renames; a conflict rolls back; other values use the resolver"
  (with-root-context (ctx)
    (struct clock (now))
    (ctx-provide ctx 'clock (clock 99))
    (ctx-provide ctx 'taken 1)
    (check-exn exn:fail:cordis:service?
               (lambda () (ctx-mixin ctx 'clock (hasheq 'now 'clock-now 'other 'taken))))
    ;; the accessor made before the conflict is gone again
    (check-exn exn:fail:cordis:inject? (lambda () (ctx-ref ctx 'clock-now)))
    (ctx-mixin ctx 'clock (hasheq 'now 'clock-now))
    (check-exn exn:fail:cordis:service? (lambda () (ctx-ref ctx 'clock-now)))
    (parameterize ([current-mixin-resolver
                    (lambda (service member)
                      (case member
                        [(now) (clock-now service)]
                        [else #f]))])
      (check-equal? (ctx-ref ctx 'clock-now) 99))))

;; ---------------------------------------------------------------------------------------
;; Interception

(test-case "resolve-config: base, layers from outermost to innermost, head"
  (with-root-context (ctx)
    (define outer (context-intercept ctx 'http (hasheq 'timeout 1 'proxy "outer")))
    (define inner (context-intercept outer 'http (hasheq 'timeout 2)))
    (check-equal? (context-intercepts ctx 'http) '())
    (check-equal? (context-intercepts inner 'http)
                  (list (hasheq 'timeout 1 'proxy "outer") (hasheq 'timeout 2)))
    (check-equal? (context-intercepts inner 'other) '())
    (check-equal? (service-resolve-config inner 'http)
                  (hasheq 'timeout 2 'proxy "outer"))
    (check-equal? (service-resolve-config inner 'http
                                          #:base (hasheq 'timeout 0 'retries 3)
                                          #:head (hasheq 'proxy "head"))
                  (hasheq 'timeout 2 'retries 3 'proxy "head"))
    (check-equal? (service-resolve-config ctx 'http) (hasheq))
    (check-equal? (service-resolve-config inner 'http #:merge list)
                  (list (hasheq 'timeout 1 'proxy "outer") (hasheq 'timeout 2)))
    (check-equal? (service-resolve-config inner 'http #:merge (lambda (a b) (list a b)))
                  (list (hasheq 'timeout 1 'proxy "outer") (hasheq 'timeout 2)))
    ;; values that are not hashes: the last one wins
    (check-equal? (default-merge 1 #f 2 #f) 2)
    (check-equal? (default-merge) (hasheq))
    (check-equal? (service-resolve-config (context-intercept ctx 'level 3) 'level #:base 1) 3)))

(test-case "resolve-config: a plugin's inject config is the innermost layer of its context"
  (with-root-context (ctx)
    (ctx-provide ctx 'http 'client)
    (define outer (context-intercept ctx 'http (hasheq 'timeout 1 'proxy "outer")))
    (define f (ctx-plugin outer (make-plugin (lambda (c config) (void))
                                             #:inject (hasheq 'http (hasheq 'timeout 9)))))
    (await/t f)
    (check-equal? (fiber-inject f) (make-hasheq (list (cons 'http (hasheq 'timeout 9)))))
    (check-equal? (service-resolve-config (fiber-context f) 'http)
                  (hasheq 'timeout 9 'proxy "outer"))
    (check-equal? (service-resolve-config (service-handle (fiber-context f) 'http) 'http)
                  (hasheq 'timeout 9 'proxy "outer"))))

;; ---------------------------------------------------------------------------------------
;; Handles

(test-case "handles: use-context and service-value"
  (with-root-context (ctx)
    (ctx-provide ctx 'db 'the-db)
    (define f (mount ctx void #:inject '(db)))
    (await/t f)
    (define c (fiber-context f))
    (define h (service-handle c 'db))
    (check-true (service-handle? h))
    (check-eq? (service-handle-ctx h) c)
    (check-eq? (service-handle-key h) 'db)
    (check-eq? (use-context h) c)
    (check-eq? (use-context c) c)
    (check-equal? (service-value h 'db) 'the-db)
    (check-equal? (service-value c 'db) 'the-db)
    (check-exn exn:fail:contract? (lambda () (service-value h 'other)))
    ;; a handle resolves at each use, so it is never stale
    (ctx-set! ctx 'db 'replaced)
    (check-equal? (service-value h 'db) 'replaced)))

(test-case "service operations work from a thread that is not a task"
  (define root (make-root-context))
  (define d (ctx-provide root 'db 1))
  (check-equal? (ctx-ref root 'db) 1)
  (ctx-set! root 'db 2)
  (check-equal? (ctx-get root 'db) 2)
  (define a (ctx-accessor root 'twice #:get (lambda (c) (* 2 (ctx-ref c 'db)))))
  (check-equal? (ctx-ref root 'twice) 4)
  (a)
  (d)
  (check-false (ctx-has? root 'db))
  (context-shutdown! root))
