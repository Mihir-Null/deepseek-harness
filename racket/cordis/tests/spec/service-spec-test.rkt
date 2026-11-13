#lang racket/base
;; Black-box specification tests for services: contract section 5
;; (docs/racket/contracts/cordis-kernel.md), the service cases of
;; scripts/cordis-core-lifecycle.spec.ts and the supplementary cases S5, S6,
;; S14 to S16, S22, S25 and S26 of docs/racket/recon/01-cordis-core.md.
;; The comment in front of each case names its source.
(require cordis
         cordis/testing
         rackunit
         racket/list
         "support.rkt")

(define (try-ref c key)
  (with-handlers ([exn:fail? values]) (ctx-ref c key)))

;; Key-sorted association list of a symbol-keyed hash, so that comparisons do
;; not depend on which hash variant the kernel returns.
(define (alist h)
  (sort (hash->list h) symbol<? #:key car))

(define (inject-error? rx)
  (lambda (v) (and (exn:fail:cordis:inject? v) (regexp-match? rx (exn-message v)))))

(define without-inject? (inject-error? #rx"cannot get property \"[^\"]+\" without inject"))
(define inactive-context?
  (inject-error? #rx"cannot get required service \"[^\"]+\" in inactive context"))

;; source: contract 5, "ctx-provide is an effect labelled ctx.provide(\"key\")";
;; recon 01 Formats, effect labels
(test-case "service/provide: is a labelled effect that installs and withdraws the value"
  (with-root (ctx)
    (define rf (context-fiber ctx))
    (check-false (ctx-has? ctx 'svc))
    (check-false (ctx-get ctx 'svc))
    (define d (ctx-provide ctx 'svc 'value))
    (check-true (disposer? d))
    (check-equal? (disposer-label d) "ctx.provide(\"svc\")")
    (check-true (and (member "ctx.provide(\"svc\")" (labels-of rf)) #t))
    (check-true (ctx-has? ctx 'svc))
    (check-eq? (ctx-get ctx 'svc) 'value)
    (check-true (and (memq 'svc (fiber-provisions rf)) #t))
    (d)
    (check-false (ctx-has? ctx 'svc))
    (check-false (ctx-get ctx 'svc))
    (check-false (memq 'svc (fiber-provisions rf)))))

;; source: contract 5, signature "(ctx-provide ctx key [value (void)])"
(test-case "service/provide: the value defaults to void and still counts as a provider"
  (with-root (ctx)
    (ctx-provide ctx 'flag)
    (check-true (ctx-has? ctx 'flag))
    (check-equal? (ctx-get ctx 'flag #:default 'absent) (void))))

;; source: contract 5, "assigns key a root realm on first use"; contract 3,
;; context-realm
(test-case "service/provide: the first provide assigns the root realm"
  (with-root (ctx)
    (check-false (context-realm ctx 'fresh))
    (ctx-provide ctx 'fresh 1)
    (define realm (context-realm ctx 'fresh))
    (check-true (symbol? realm))
    (define child (context-extend ctx (hasheq 'tag 'child)))
    (check-eq? (context-realm child 'fresh) realm)))

;; source: contract 5, error bullet `service "key" has been registered at
;; <fiber-name>`; reflect.ts provide; digest law 11; recon 01 S14
(test-case "service/provide: a second provider in the same realm raises and keeps the first"
  (with-root (ctx)
    (define rf (context-fiber ctx))
    (ctx-provide ctx 'svc 'first)
    (define before (labels-of rf))
    (define (attempt)
      (with-handlers ([exn:fail? values]) (ctx-provide ctx 'svc 'second)))
    (define e (attempt))
    (check-pred exn:fail:cordis:service? e)
    (check-pred exn:fail:cordis? e)
    (check-regexp-match #rx"service \"svc\" has been registered at <?root>?" (exn-message e))
    (check-eq? (exn:fail:cordis:service-key e) 'svc)
    (check-eq? (ctx-get ctx 'svc) 'first)
    (check-equal? (labels-of rf) before)
    (define named (ctx-plugin ctx (make-plugin (lambda (c config) (ctx-provide c 'owned 1) (void))
                                               #:name "owner-plugin")))
    (await named)
    (define e2 (with-handlers ([exn:fail? values]) (ctx-provide ctx 'owned 2)))
    (check-pred exn:fail:cordis:service? e2)
    (check-regexp-match #rx"service \"owned\" has been registered at <?owner-plugin>?"
                        (exn-message e2))))

;; source: contract 5, "If the providing fiber is 'active it notifies" and the
;; Notify bullet; digest law 12; recon 01 S26 (late provide notifies at once)
(test-case "service/notify: provide and withdraw re-check dependents and emit internal/service"
  (with-root (ctx)
    (define events (make-recorder))
    (define log (make-recorder))
    (ctx-on ctx 'internal/service
            (lambda (name value) (when (eq? name 'svc) (note! events (list name value)))))
    (define consumer
      (ctx-inject ctx '(svc)
                  (lambda (c)
                    (note! log (list 'apply (ctx-ref c 'svc)))
                    (lambda () (note! log 'unload)))))
    (check-eq? (fiber-state consumer) 'pending)
    (define d (ctx-provide ctx 'svc 'v1))
    (check-eq? (fiber-state consumer) 'loading)
    (await consumer)
    (check-eq? (fiber-state consumer) 'active)
    (d)
    (settle consumer)
    (check-eq? (fiber-state consumer) 'pending)
    (check-equal? (notes log) '((apply v1) unload))
    (check-equal? (notes events) '((svc v1) (svc #f)))))

;; source: contract 5, ctx-get bullet; digest law 13 (absent get); recon 01 S26
(test-case "service/get: returns the default when absent or, strictly, when not active"
  (with-root (ctx)
    (check-false (ctx-get ctx 'unknown))
    (check-eq? (ctx-get ctx 'unknown #:default 'fallback) 'fallback)
    (check-false (ctx-get ctx 'unknown #:strict? #f))
    (define gate (make-gate))
    (define provided (make-gate))
    (define provider
      (ctx-plugin ctx (lambda (c config)
                        (ctx-provide c 'slow 'value)
                        (gate-open! provided)
                        (gate-wait gate)
                        (void))))
    (gate-wait provided)
    (check-eq? (fiber-state provider) 'loading)
    (check-true (ctx-has? ctx 'slow))
    (check-false (ctx-get ctx 'slow))
    (check-eq? (ctx-get ctx 'slow #:default 'not-yet) 'not-yet)
    (check-eq? (ctx-get ctx 'slow #:strict? #f) 'value)
    (gate-open! gate)
    (await provider)
    (check-eq? (ctx-get ctx 'slow) 'value)))

;; source: contract 5, ctx-set! bullet (in-place, no notification); digest law
;; 17 second half; recon 01 quirk 8
(test-case "service/set: replaces the value in place without notifying"
  (with-root (ctx)
    (define events (make-recorder))
    (define log (make-recorder))
    (ctx-provide ctx 'svc 'v1)
    (ctx-on ctx 'internal/service (lambda (name value) (note! events (list name value))))
    (define consumer (ctx-inject ctx '(svc) (lambda (c) (note! log (ctx-ref c 'svc)) (void))))
    (await consumer)
    (check-equal? (ctx-set! ctx 'svc 'v2) (void))
    (yield-times 5)
    (settle consumer)
    (check-eq? (ctx-get ctx 'svc) 'v2)
    (check-eq? (ctx-ref (fiber-context consumer) 'svc) 'v2)
    (check-eq? (fiber-state consumer) 'active)
    (check-equal? (notes log) '(v1))
    (check-equal? (notes events) '())))

;; source: contract 5, error bullets `cannot set property "key" without provide`
;; and `cannot set property "key" in multiple fibers`; recon 01 S14
(test-case "service/set: raises without a provider and from another fiber"
  (with-root (ctx)
    (ctx-provide ctx 'svc 'v1)
    (define other (ctx-plugin ctx (lambda (c config) (void))))
    (await other)
    (check-exn (raises? exn:fail:cordis:service?
                        #rx"cannot set property \"nope\" without provide")
               (lambda () (ctx-set! ctx 'nope 1)))
    (define e (with-handlers ([exn:fail? values]) (ctx-set! (fiber-context other) 'svc 'v2)))
    (check-pred exn:fail:cordis:service? e)
    (check-regexp-match #rx"cannot set property \"svc\" in multiple fibers" (exn-message e))
    (check-eq? (exn:fail:cordis:service-key e) 'svc)
    (check-eq? (ctx-get ctx 'svc) 'v1)))

;; source: contract 5, ctx-set! bullet ("For an accessor name it calls the
;; accessor's setter and raises exn:fail:cordis:service when the accessor has
;; none") and accessor bullet ("setter as (setter ctx value) with the writing
;; context"); reflect.ts handler.set
(test-case "service/set: an accessor name goes to its setter with the writing context"
  (with-root (ctx)
    (define cell (box 'initial))
    (define writers (make-recorder))
    (ctx-accessor ctx 'spec-cell
                  #:get (lambda (c) (unbox cell))
                  #:set (lambda (c v) (note! writers c) (set-box! cell v)))
    (define writer (context-extend ctx (hasheq 'who 'writer)))
    (ctx-set! writer 'spec-cell 'written)
    (check-eq? (ctx-ref ctx 'spec-cell) 'written)
    (check-equal? (length (notes writers)) 1)
    (check-eq? (first (notes writers)) writer)
    ;; An accessor without a setter cannot be written.
    (ctx-accessor ctx 'spec-read-only #:get (lambda (c) 'fixed))
    (check-exn exn:fail:cordis:service? (lambda () (ctx-set! ctx 'spec-read-only 'other)))
    (check-eq? (ctx-ref ctx 'spec-read-only) 'fixed)))

;; source: contract 5, ctx-set! bullet ("For a service name it runs the
;; 'internal/set waterfall (ctx name value next) whose innermost step replaces
;; the impl's value in place"); contract 7, internal events; reflect.ts
;; handler.set
(test-case "service/set: a service name runs the internal/set waterfall around the replacement"
  (with-root (ctx)
    (define log (make-recorder))
    (ctx-provide ctx 'svc 'v0)
    (define d
      (ctx-on ctx 'internal/set
              (lambda (c name value next)
                (note! log (list 'before (eq? c ctx) name value (ctx-get ctx 'svc)))
                (next)
                (note! log (list 'after (ctx-get ctx 'svc))))))
    (ctx-set! ctx 'svc 'v1)
    (check-equal? (notes log) '((before #t svc v1 v0) (after v1)))
    (d)
    ;; A listener that returns without calling next vetoes the write.
    (ctx-on ctx 'internal/set (lambda (c name value next) 'vetoed))
    (ctx-set! ctx 'svc 'v2)
    (check-eq? (ctx-get ctx 'svc) 'v1)
    ;; A name that was never provided fails before the waterfall runs.
    (check-exn (raises? exn:fail:cordis:service?
                        #rx"cannot set property \"never-provided\" without provide")
               (lambda () (ctx-set! ctx 'never-provided 1)))))

;; source: contract 5, ctx-ref step 1; recon 01 S15 (accessor get runs with the
;; reading context)
(test-case "service/ref step 1: an accessor's getter is called with the reading context"
  (with-root (ctx)
    (define d (ctx-accessor ctx 'whoami #:get (lambda (c) (list 'read-by c))))
    (check-equal? (disposer-label d) "ctx.accessor(\"whoami\")")
    (check-equal? (ctx-ref ctx 'whoami) (list 'read-by ctx))
    (define f (ctx-plugin ctx (lambda (c config) (void))))
    (await f)
    (define fc (fiber-context f))
    (check-equal? (ctx-ref fc 'whoami) (list 'read-by fc))
    (d)
    (check-pred without-inject? (try-ref fc 'whoami))))

;; source: contract 5, ctx-ref step 2 (root fiber: unchecked, non-strict) and
;; step 4 message
(test-case "service/ref step 2: a root-fiber context reads unchecked and non-strictly"
  (with-root (ctx)
    (define gate (make-gate))
    (define provided (make-gate))
    (define provider
      (ctx-plugin ctx (lambda (c config)
                        (ctx-provide c 'slow 'value)
                        (gate-open! provided)
                        (gate-wait gate)
                        (void))))
    (gate-wait provided)
    (check-eq? (ctx-ref ctx 'slow) 'value)
    (check-eq? (ctx-ref (context-extend ctx (hasheq 'k 1)) 'slow) 'value)
    (define e (try-ref ctx 'absent))
    (check-pred exn:fail:cordis:inject? e)
    (check-regexp-match #rx"cannot get property \"absent\" without inject" (exn-message e))
    (check-eq? (exn:fail:cordis:inject-key e) 'absent)
    (gate-open! gate)
    (await provider)
    (check-eq? (fiber-state provider) 'active)))

;; source: contract 5, ctx-ref step 3; reflect.ts handler.get; recon 01 S6
(test-case "service/ref step 3: visibility follows injections and provisions up the fiber chain"
  (with-root (ctx)
    (ctx-provide ctx 'root-svc 'from-root)
    (define provider
      (ctx-plugin ctx (make-plugin (lambda (c config) (ctx-provide c 'sib-svc 'from-sibling) (void))
                                   #:name "provider")))
    (await provider)
    (define seen (make-hasheq))
    (define child (box #f))
    (define consumer
      (ctx-plugin
       ctx
       (make-plugin
        (lambda (c config)
          (hash-set! seen 'own-injection (try-ref c 'sib-svc))
          (ctx-provide c 'own-svc 'mine)
          (hash-set! seen 'own-provision (try-ref c 'own-svc))
          (hash-set! seen 'root-provided (try-ref c 'root-svc))
          (set-box! child
                    (ctx-plugin c (lambda (cc config)
                                    (hash-set! seen 'inherited-injection (try-ref cc 'sib-svc))
                                    (hash-set! seen 'inherited-provision (try-ref cc 'own-svc))
                                    (void))))
          (void))
        #:name "consumer"
        #:inject '(sib-svc))))
    (await consumer)
    (await (unbox child))
    (define outsider
      (ctx-plugin ctx (lambda (c config)
                        (hash-set! seen 'sibling (try-ref c 'sib-svc))
                        (hash-set! seen 'sibling-own (try-ref c 'own-svc))
                        (hash-set! seen 'get-anywhere (ctx-get c 'sib-svc))
                        (void))))
    (await outsider)
    (check-eq? (hash-ref seen 'own-injection) 'from-sibling)
    (check-eq? (hash-ref seen 'own-provision) 'mine)
    (check-eq? (hash-ref seen 'root-provided) 'from-root)
    (check-eq? (hash-ref seen 'inherited-injection) 'from-sibling)
    (check-eq? (hash-ref seen 'inherited-provision) 'mine)
    (check-pred without-inject? (hash-ref seen 'sibling))
    (check-pred without-inject? (hash-ref seen 'sibling-own))
    (check-eq? (hash-ref seen 'get-anywhere) 'from-sibling)))

;; source: contract 5, ctx-ref step 3 error `cannot get required service "key"
;; in inactive context`; digest law 13; recon 01 S5
(test-case "service/ref step 3: a declared but uncommitted injection raises its own error"
  (with-root (ctx)
    (define f (ctx-inject ctx '(missing) (lambda (c) (void))))
    (check-eq? (fiber-state f) 'pending)
    (define e (try-ref (fiber-context f) 'missing))
    (check-pred inactive-context? e)
    (check-regexp-match #rx"cannot get required service \"missing\" in inactive context"
                        (exn-message e))
    (check-eq? (exn:fail:cordis:inject-key e) 'missing)
    (define undeclared (try-ref (fiber-context f) 'other))
    (check-pred without-inject? undeclared)
    (check-false (ctx-get (fiber-context f) 'missing))
    (ctx-provide ctx 'missing 'arrived)
    (await f)
    (check-eq? (ctx-ref (fiber-context f) 'missing) 'arrived)))

;; source: contract 5, ctx-ref step 3, "f's parent context maps key to a
;; different realm than ctx does"; reflect.ts handler.get
(test-case "service/ref step 3: the walk stops at an isolation boundary"
  (with-root (ctx)
    (ctx-provide ctx 'root-svc 'from-root)
    (define seen (make-hasheq))
    (define child (box #f))
    (define parent
      (ctx-plugin ctx (lambda (c config)
                        (hash-set! seen 'parent (try-ref c 'root-svc))
                        (set-box! child
                                  (ctx-plugin (context-isolate c 'root-svc)
                                              (lambda (cc config)
                                                (hash-set! seen 'isolated-child
                                                           (try-ref cc 'root-svc))
                                                (void))))
                        (void))))
    (await parent)
    (await (unbox child))
    (check-eq? (hash-ref seen 'parent) 'from-root)
    (check-pred without-inject? (hash-ref seen 'isolated-child))))

;; source: contract 5, ctx-ref step 3, "run the 'internal/get waterfall
;; (ctx key next)"; contract 7, internal events
(test-case "service/ref step 3: internal/get wraps reads from plugin contexts only"
  (with-root (ctx)
    (ctx-provide ctx 'real 'real-value)
    (define calls (make-recorder))
    (ctx-on ctx 'internal/get
            (lambda (c name next)
              (note! calls name)
              (if (eq? name 'virtual) 'from-hook (next))))
    (define f (ctx-plugin ctx (lambda (c config) (void))))
    (await f)
    (define fc (fiber-context f))
    (check-eq? (ctx-ref fc 'virtual) 'from-hook)
    (check-eq? (ctx-ref fc 'real) 'real-value)
    (check-equal? (notes calls) '(virtual real))
    ;; Step 2 answers for the root fiber before the waterfall is consulted.
    (check-pred without-inject? (try-ref ctx 'virtual))
    (check-equal? (notes calls) '(virtual real))))

;; source: contract 5, #:check bullet; fiber.ts _checkImpl
(test-case "service/check: a false result hides the service from that dependent"
  (with-root (ctx)
    (define checked (make-recorder))
    (ctx-provide ctx 'gated 'value
                 #:check (lambda (c)
                           (note! checked c)
                           (context-meta c 'allowed #f)))
    (define allowed (ctx-inject (context-extend ctx (hasheq 'allowed #t)) '(gated) void))
    (define denied (ctx-inject ctx '(gated) void))
    (await allowed)
    (settle denied)
    (check-eq? (fiber-state allowed) 'active)
    (check-eq? (fiber-state denied) 'pending)
    (check-true (and (memq (fiber-context allowed) (notes checked)) #t)
                "check receives the dependent's context")
    (check-true (and (memq (fiber-context denied) (notes checked)) #t))
    ;; The reflective read ignores check.
    (check-eq? (ctx-get (fiber-context denied) 'gated) 'value)))

;; source: contract 5, #:check bullet, "an exception (logged)"
(test-case "service/check: a raising check is logged and counts as absent"
  (with-root (ctx)
    (define f (box #f))
    (define-values (result logs)
      (capture-log
       (lambda ()
         (ctx-provide ctx 'fragile 'value
                      #:check (lambda (c) (raise-user-error "check exploded")))
         (set-box! f (ctx-inject ctx '(fragile) void))
         (settle (unbox f))
         (fiber-state (unbox f)))
       #:level 'error
       #:topic 'cordis))
    (check-eq? result 'pending)
    (check-true (pair? logs))))

;; source: recon 01 S22, "check with intercept config from object inject and
;; from ctx.intercept"; contract 6 make-plugin #:inject hash form
(test-case "service/check: sees intercept config from the inject map and from context-intercept"
  (with-root (ctx)
    (define (allowed? c)
      (define layers (context-intercepts c 'guarded))
      (and (pair? layers) (hash-ref (last layers) 'allow #f)))
    (ctx-provide ctx 'guarded 'value #:check allowed?)
    (define by-inject
      (ctx-plugin ctx (make-plugin (lambda (c config) (void))
                                   #:inject (hasheq 'guarded (hasheq 'allow #t)))))
    (define by-context
      (ctx-inject (context-intercept ctx 'guarded (hasheq 'allow #t)) '(guarded) void))
    (define plain (ctx-inject ctx '(guarded) void))
    (await by-inject)
    (await by-context)
    (settle plain)
    (check-eq? (fiber-state by-inject) 'active)
    (check-eq? (fiber-state by-context) 'active)
    (check-eq? (fiber-state plain) 'pending)))

;; source: contract 5, accessor bullet `property "name" is already declared as
;; service|accessor`; recon 01 S15
(test-case "service/accessor: a name is a service or an accessor, not both"
  (with-root (ctx)
    (ctx-provide ctx 'svc 1)
    (ctx-accessor ctx 'acc #:get (lambda (c) 'computed))
    (check-exn (raises? exn:fail? #rx"property \"svc\" is already declared as service")
               (lambda () (ctx-accessor ctx 'svc #:get (lambda (c) 0))))
    (check-exn (raises? exn:fail? #rx"property \"acc\" is already declared as accessor")
               (lambda () (ctx-provide ctx 'acc 2)))
    (check-exn (raises? exn:fail? #rx"property \"acc\" is already declared as accessor")
               (lambda () (ctx-accessor ctx 'acc #:get (lambda (c) 1))))
    (check-eq? (ctx-ref ctx 'acc) 'computed)
    (check-eq? (ctx-get ctx 'svc) 1)))

;; source: contract 5, "ctx-accessor and ctx-mixin are effects"
(test-case "service/accessor: the accessor disappears with its owning fiber"
  (with-root (ctx)
    (define f (ctx-plugin ctx (lambda (c config)
                                (ctx-accessor c 'temp #:get (lambda (reader) 'temporary))
                                (void))))
    (await f)
    (check-eq? (ctx-ref ctx 'temp) 'temporary)
    (fiber-dispose! f)
    (check-pred without-inject? (try-ref ctx 'temp))
    (define again (ctx-accessor ctx 'temp #:get (lambda (reader) 'redeclared)))
    (check-eq? (ctx-ref ctx 'temp) 'redeclared)
    (again)))

;; source: contract 5, mixin bullet (hash-valued service); recon 01 S16
(test-case "service/mixin: list and map forms expose members of a hash-valued service"
  (with-root (ctx)
    (define (set-timeout) 'set)
    (define (clear-timeout) 'cleared)
    (ctx-provide ctx 'timer (hasheq 'set-timeout set-timeout 'clear clear-timeout))
    (define m1 (ctx-mixin ctx 'timer '(set-timeout)))
    (define m2 (ctx-mixin ctx 'timer (hasheq 'clear 'clear-timeout)))
    (check-equal? (disposer-label m1) "ctx.mixin(\"timer\")")
    (check-equal? (map disposer-label (disposer-children m1)) '("ctx.accessor(\"set-timeout\")"))
    (check-equal? (map disposer-label (disposer-children m2))
                  '("ctx.accessor(\"clear-timeout\")"))
    (check-eq? (ctx-ref ctx 'set-timeout) set-timeout)
    (check-eq? (ctx-ref ctx 'clear-timeout) clear-timeout)
    (m1)
    (check-pred without-inject? (try-ref ctx 'set-timeout))
    (check-eq? (ctx-ref ctx 'clear-timeout) clear-timeout)
    (m2)
    (check-pred without-inject? (try-ref ctx 'clear-timeout))))

;; source: contract 5, mixin bullet, "otherwise the result of
;; ((current-mixin-resolver) service-value name)"
(test-case "service/mixin: a non-hash service is resolved through current-mixin-resolver"
  (define resolver (optional-binding 'cordis 'current-mixin-resolver))
  (check-true (and resolver (parameter? resolver)) "cordis must export current-mixin-resolver")
  (when resolver
    (with-root (ctx)
      (define service (vector 'opaque))
      (ctx-provide ctx 'device service)
      (parameterize ([resolver (lambda (value name) (list 'resolved value name))])
        (ctx-mixin ctx 'device '(power))
        (check-equal? (ctx-ref ctx 'power) (list 'resolved service 'power))))))

;; source: contract 5, mixin bullet ("The member is read through (ctx-ref ctx
;; source) on the reading context, so a mixed-in name needs the access rights
;; of its source"; "ctx-set! on a mixed-in name stores the member in a mutable
;; hash-valued service"); recon 01 quirk 12 and S16
(test-case "service/mixin: a member needs its source's access rights; a write reaches the source"
  (with-root (ctx)
    (define timer (make-hasheq (list (cons 'now 12))))
    (ctx-provide ctx 'timer timer)
    (ctx-mixin ctx 'timer '(now))
    ;; A plugin under the root may read a root-provided service, so it reads the member.
    (define near (ctx-plugin ctx (lambda (c config) (void))))
    (await near)
    (check-equal? (ctx-ref (fiber-context near) 'now) 12)
    ;; A plugin whose context maps `timer` to another realm cannot read the source.
    (define far (ctx-plugin (context-isolate ctx 'timer) (lambda (c config) (void))))
    (await far)
    (check-exn (raises? exn:fail:cordis:inject?
                        #rx"cannot get property \"timer\" without inject")
               (lambda () (ctx-ref (fiber-context far) 'now)))
    ;; A write through the mixed-in name stores the member in the service value.
    (ctx-set! ctx 'now 13)
    (check-equal? (hash-ref timer 'now) 13)
    (check-equal? (ctx-ref ctx 'now) 13)
    ;; A service value that is not a mutable hash cannot be written through.
    (ctx-provide ctx 'frozen (hasheq 'member 1))
    (ctx-mixin ctx 'frozen '(member))
    (check-exn exn:fail:cordis:service? (lambda () (ctx-set! ctx 'member 2)))
    (check-equal? (ctx-ref ctx 'member) 1)))

;; source: contract 5, service-resolve-config bullet; service.ts resolveConfig;
;; recon 01 S22 (merge order)
(test-case "service/resolve-config: merges base, intercept layers outermost first, then head"
  (with-root (ctx)
    (define c1 (context-intercept ctx 'svc (hasheq 'a 1 'b 1)))
    (define c2 (context-intercept c1 'svc (hasheq 'b 2 'c 2)))
    (check-equal? (context-intercepts ctx 'svc) '())
    (check-equal? (context-intercepts c2 'svc) (list (hasheq 'a 1 'b 1) (hasheq 'b 2 'c 2)))
    (check-equal? (context-intercepts c1 'svc) (list (hasheq 'a 1 'b 1)))
    (check-equal? (alist (service-resolve-config c2 'svc)) '((a . 1) (b . 2) (c . 2)))
    (check-equal? (alist (service-resolve-config c2 'svc
                                                 #:base (hasheq 'a 0 'z 0)
                                                 #:head (hasheq 'c 3)))
                  '((a . 1) (b . 2) (c . 3) (z . 0)))
    (check-equal? (alist (service-resolve-config c2 'other #:base (hasheq 'only 'base)))
                  '((only . base)))
    ;; default-merge on non-hash values takes the last non-#f value.
    (define s1 (context-intercept ctx 'level 1))
    (define s2 (context-intercept s1 'level 2))
    (check-equal? (service-resolve-config s2 'level #:base 0) 2)
    (check-equal? (service-resolve-config s2 'level #:head 9) 9)
    (check-equal? (service-resolve-config ctx 'level #:base 0) 0)))

;; source: contract 5, "default-merge merges hashes right-biased and otherwise
;; takes the last non-#f value"
(test-case "service/resolve-config: default-merge is exported and right-biased"
  (define default-merge (optional-binding 'cordis 'default-merge))
  (check-true (procedure? default-merge) "cordis must export default-merge")
  (when (procedure? default-merge)
    (with-root (ctx)
      (define c1 (context-intercept ctx 'svc (hasheq 'a 1)))
      (check-equal? (alist (service-resolve-config c1 'svc
                                                   #:head (hasheq 'a 2 'b 3)
                                                   #:merge default-merge))
                    '((a . 2) (b . 3))))))

;; source: analysis 3.1, "A plugin's own inject: { name: config } value is
;; written as the innermost layer of its fiber's context"; fiber.ts constructor;
;; digest law 16 (the port follows the code: the declared value has the last word)
(test-case "service/intercept: a plugin's inject config is the innermost layer"
  (with-root (ctx)
    (ctx-provide ctx 'svc 'value)
    (define outer (context-intercept ctx 'svc (hasheq 'a 'outer 'b 'outer)))
    (define seen (box #f))
    (define f
      (ctx-plugin outer
                  (make-plugin (lambda (c config)
                                 (set-box! seen (list (context-intercepts c 'svc)
                                                      (alist (service-resolve-config c 'svc))))
                                 (void))
                               #:inject (hasheq 'svc (hasheq 'b 'declared)))))
    (await f)
    (check-equal? (unbox seen)
                  (list (list (hasheq 'a 'outer 'b 'outer) (hasheq 'b 'declared))
                        '((a . outer) (b . declared))))
    (check-equal? (alist (fiber-inject f)) (list (cons 'svc (hasheq 'b 'declared))))
    (check-equal? (context-intercepts outer 'svc) (list (hasheq 'a 'outer 'b 'outer)))))

;; source: contract 5, service-handle / use-context / service-value; ADR 0003
(test-case "service/handle: a handle pairs a context with a key"
  (with-root (ctx)
    (ctx-provide ctx 'svc 'value)
    (define h (service-handle ctx 'svc))
    (check-true (service-handle? h))
    (check-eq? (service-handle-ctx h) ctx)
    (check-eq? (service-handle-key h) 'svc)
    (check-eq? (use-context h) ctx)
    (check-eq? (use-context ctx) ctx)
    (check-eq? (service-value h 'svc) 'value)
    (check-eq? (service-value ctx 'svc) 'value)
    (check-exn exn:fail? (lambda () (service-value h 'other)))
    ;; A handle resolves at each use, so it is never stale.
    (ctx-set! ctx 'svc 'replaced)
    (check-eq? (service-value h 'svc) 'replaced)))

;; source: contract 3, "Functions that take a key also accept a string"
(test-case "service/keys: a string key names the same service as its symbol"
  (with-root (ctx)
    (define d (ctx-provide ctx "text-key" 'value))
    (check-eq? (ctx-get ctx 'text-key) 'value)
    (check-eq? (ctx-get ctx "text-key") 'value)
    (check-eq? (ctx-ref ctx "text-key") 'value)
    (check-true (ctx-has? ctx "text-key"))
    (ctx-set! ctx "text-key" 'changed)
    (check-eq? (ctx-get ctx 'text-key) 'changed)
    (define f (ctx-inject ctx '("text-key") void))
    (await f)
    (check-eq? (fiber-state f) 'active)
    (check-equal? (hash-keys (fiber-inject f)) '(text-key))
    (d)))

;; source: contract 3, context-isolate / make-realm; digest law 15; analysis law
;; 11; recon 01 S25
(test-case "service/isolate: realms hold independent bindings and can be joined"
  (with-root (ctx)
    (ctx-provide ctx 'svc 'shared)
    (define iso (context-isolate ctx 'svc))
    (define realm (context-realm iso 'svc))
    (check-true (symbol? realm))
    (check-false (eq? realm (context-realm ctx 'svc)))
    (check-false (ctx-has? iso 'svc))
    (check-false (ctx-get iso 'svc))
    (define d (ctx-provide iso 'svc 'private))
    (check-eq? (ctx-get iso 'svc) 'private)
    (check-eq? (ctx-get ctx 'svc) 'shared)
    ;; A key that was never isolated resolves in the shared realm.
    (ctx-provide ctx 'other 'everywhere)
    (check-eq? (ctx-get iso 'other) 'everywhere)
    ;; Passing an existing realm joins that scope.
    (define joined (context-isolate ctx 'svc realm))
    (check-eq? (context-realm joined 'svc) realm)
    (check-eq? (ctx-get joined 'svc) 'private)
    (define fresh (make-realm 'svc))
    (check-true (symbol? fresh))
    (check-false (symbol-interned? fresh))
    (check-false (ctx-get (context-isolate ctx 'svc fresh) 'svc))
    (d)
    (check-false (ctx-get joined 'svc))
    (check-eq? (ctx-get ctx 'svc) 'shared)))

;; source: contract 5, Notify bullet (same realm only); digest law 15; recon 01
;; S25 (scoped internal/service) and S11 (global listeners)
(test-case "service/isolate: notifications and internal/service stay inside the realm"
  (with-root (ctx)
    (define iso (context-isolate ctx 'svc))
    (define log (make-recorder))
    (ctx-on ctx 'internal/service (lambda (name value) (note! log (list 'shared name value))))
    (ctx-on iso 'internal/service (lambda (name value) (note! log (list 'isolated name value))))
    (ctx-on ctx 'internal/service (lambda (name value) (note! log (list 'global name value)))
            #:global? #t)
    (define shared-consumer (ctx-inject ctx '(svc) void))
    (define isolated-consumer (ctx-inject iso '(svc) void))
    (define d (ctx-provide iso 'svc 'private))
    (await isolated-consumer)
    (settle shared-consumer)
    (check-eq? (fiber-state isolated-consumer) 'active)
    (check-eq? (fiber-state shared-consumer) 'pending)
    (check-equal? (notes log) '((isolated svc private) (global svc private)))
    (d)
    (settle isolated-consumer)
    (check-eq? (fiber-state isolated-consumer) 'pending)))

;; source: recon 01 S26, "provide through a PENDING fiber is hidden until it
;; activates"; recon 01 G5
(test-case "service/visibility: a provision through a pending fiber is hidden until it activates"
  (with-root (ctx)
    (define provider (ctx-inject ctx '(prerequisite) void))
    (check-eq? (fiber-state provider) 'pending)
    (ctx-provide (fiber-context provider) 'early 'value)
    (define consumer (ctx-inject ctx '(early) void))
    (settle consumer)
    (check-false (ctx-get ctx 'early))
    (check-eq? (ctx-get ctx 'early #:strict? #f) 'value)
    (check-eq? (fiber-state consumer) 'pending)
    (ctx-provide ctx 'prerequisite #t)
    (await provider)
    (await consumer)
    (check-eq? (ctx-get ctx 'early) 'value)
    (check-eq? (fiber-state consumer) 'active)))

;; source: scripts/cordis-core-lifecycle.spec.ts "separates own isolated
;; provisions from the committed injection" (recon case 4)
(test-case "case 4: own isolated provision versus committed injection"
  (with-root (ctx)
    (ctx-provide ctx 'rc11-view 'outer)
    (define seen (make-recorder))
    (define first-plugin
      (ctx-inject ctx '(rc11-view)
                  (lambda (owner)
                    (define isolated (context-isolate owner 'rc11-view))
                    (define withdraw (ctx-provide isolated 'rc11-view 'inner))
                    (note! seen (list 'owner (try-ref owner 'rc11-view)))
                    (note! seen (list 'isolated (try-ref isolated 'rc11-view)))
                    (settle (ctx-plugin isolated
                                        (lambda (child config)
                                          (note! seen (list 'child (try-ref child 'rc11-view)))
                                          (void))))
                    (withdraw)
                    (note! seen (list 'owner-after (try-ref owner 'rc11-view)))
                    (note! seen (list 'isolated-after (try-ref isolated 'rc11-view)))
                    (void))))
    (await first-plugin)
    (check-equal? (notes seen)
                  '((owner outer) (isolated inner) (child inner)
                    (owner-after outer) (isolated-after outer)))
    (define private (box #f))
    (define second-plugin
      (ctx-plugin ctx (lambda (owner config)
                        (ctx-provide (context-isolate owner 'rc11-private) 'rc11-private #t)
                        (set-box! private (try-ref owner 'rc11-private))
                        (void))))
    (await second-plugin)
    (check-pred without-inject? (unbox private))))

;; source: recon 01 S21 and "Use site and definition site" items 4 and 5, in
;; the form ADR 0003 gives them: a service procedure registers on the context
;; or handle it is passed (use site) and resolves its own dependencies through
;; the provider's context (definition site, lexical scope).
(test-case "S21: an effect registered through a caller's handle belongs to the caller"
  (with-root (ctx)
    (ctx-provide ctx 'clock 'root-clock)
    (define registry (make-hasheq))
    (define provider
      (ctx-plugin
       ctx
       (make-plugin
        (lambda (c config)
          (define clock (service-handle c 'clock))
          (define (register! x name)
            (ctx-effect (use-context x)
                        (lambda ()
                          (hash-set! registry name (service-value clock 'clock))
                          (lambda () (hash-remove! registry name)))
                        #:label "registry.register"))
          (ctx-provide c 'registry (hasheq 'register! register!))
          (void))
        #:name "registry-provider"
        #:inject '(clock))))
    (await provider)
    (define caller
      (ctx-plugin
       (context-isolate ctx 'clock)
       (make-plugin
        (lambda (c config)
          (define registry-handle (service-handle c 'registry))
          ((hash-ref (service-value registry-handle 'registry) 'register!) registry-handle 'entry)
          (void))
        #:name "registry-caller"
        #:inject '(registry))))
    (await caller)
    ;; Owned by the caller, although the provider's code created it; the
    ;; provider read `clock` through its own context, which the caller cannot.
    (check-true (and (member "registry.register" (labels-of caller)) #t))
    (check-false (member "registry.register" (labels-of provider)))
    (check-equal? (hash-ref registry 'entry #f) 'root-clock)
    (check-pred exn:fail:cordis:inject? (try-ref (fiber-context caller) 'clock))
    (fiber-dispose! caller)
    (check-false (hash-has-key? registry 'entry))
    (check-eq? (fiber-state provider) 'active)))
