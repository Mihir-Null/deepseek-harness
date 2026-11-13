#lang racket/base
;; Black-box specification tests for plugins and fibers: contract section 6
;; (docs/racket/contracts/cordis-kernel.md), read against
;; vendor/cordis/src/fiber.ts, plus the supplementary cases S1 to S4, S17, S19,
;; S20, S23, S24 and S28 of docs/racket/recon/01-cordis-core.md, the root and
;; thread rules of contract section 3, and addendum 3 of contract section 12.
;; The comment in front of each case names its source.
(require cordis
         cordis/testing
         rackunit
         racket/list
         "support.rkt")

(define inactive-message #rx"cannot create effect on inactive context")

;; Records every 'internal/status change of fibers named `name` as (old . new).
(define (record-status! ctx name log)
  (ctx-on ctx 'internal/status
          (lambda (f old)
            (when (equal? (fiber-name f) name)
              (note! log (cons old (fiber-state f)))))))

(define (named name apply #:inject [inject '()] #:config [schema #f])
  (make-plugin apply #:name name #:inject inject #:config schema))

;; source: contract 3, root context bullet; recon 01 "Root fiber"
(test-case "context/root: the root fiber is active, has uid 0, no plugin and no injections"
  (with-root (ctx)
    (define rf (context-fiber ctx))
    (check-true (context? ctx))
    (check-true (root-context? ctx))
    (check-eq? (context-root ctx) ctx)
    (check-false (context-parent ctx))
    (check-true (fiber? rf))
    (check-eq? (fiber-state rf) 'active)
    (check-equal? (fiber-uid rf) 0)
    (check-false (fiber-plugin rf))
    (check-equal? (hash-count (fiber-inject rf)) 0)
    (check-equal? (fiber-name rf) "root")
    (check-true (scheduler? (context-scheduler ctx)))
    (check-true (custodian? (context-custodian ctx)))
    (define child (context-extend ctx (hasheq 'color 'red)))
    (check-false (root-context? child))
    (check-eq? (context-root child) ctx)
    (check-eq? (context-parent child) ctx)
    (check-eq? (context-fiber child) rf)
    (check-eq? (context-meta child 'color) 'red)
    (check-false (context-meta ctx 'color))
    (check-eq? (context-meta ctx 'color 'none) 'none)
    (check-eq? (context-meta (context-extend child (hasheq 'color 'blue)) 'color) 'blue)
    (check-eq? (call-with-context child (lambda () (current-context))) child)))

;; source: contract 6, signatures of make-plugin and the plugin accessors
(test-case "plugin/surface: make-plugin records its declaration"
  (define (schema raw) raw)
  (define p (make-plugin (lambda (c config) (void))
                         #:name "declared"
                         #:inject '(a b)
                         #:config schema
                         #:provides '(svc)
                         #:meta (hasheq 'kind 'test)))
  (check-true (plugin? p))
  (check-false (plugin? (lambda (c config) (void))))
  (check-equal? (plugin-name p) "declared")
  (check-eq? (plugin-config-schema p) schema)
  (check-equal? (plugin-provides p) '(svc))
  (check-eq? (hash-ref (plugin-meta p) 'kind) 'test)
  (check-false (plugin-name (make-plugin (lambda (c config) (void))))))

;; source: contract 6 rule 1; recon 01 G1, G2, S1
(test-case "fiber rule 1 / S1: ctx-plugin returns before the body runs; bodies run in start order"
  (with-root (ctx)
    (define rf (context-fiber ctx))
    (define log (make-recorder))
    (define a (ctx-plugin ctx (lambda (c config) (note! log 'A) (void))))
    (define b (ctx-plugin ctx (lambda (c config) (note! log 'B) (void))))
    (check-true (fiber? a))
    (check-eq? (fiber-state a) 'loading)
    (check-eq? (fiber-state b) 'loading)
    (check-false (sync/timeout 0 a))
    (note! log 'sync-after)
    (check-equal? (filter (lambda (l) (equal? l "ctx.plugin()")) (labels-of rf))
                  '("ctx.plugin()" "ctx.plugin()"))
    (check-eq? (await a) a)
    (check-eq? (fiber-await b) b)
    (check-eq? (sync/timeout 0 a) a)
    (check-equal? (notes log) '(sync-after A B))
    (check-eq? (fiber-state a) 'active)))

;; source: contract 6 rule 1, "emits 'internal/plugin with the fiber (state
;; 'pending), then checks each injected name and refreshes"
(test-case "fiber rule 1: internal/plugin sees the new fiber pending, owned and unresolved"
  (with-root (ctx)
    (ctx-provide ctx 'svc 'value)
    (define seen (make-recorder))
    (ctx-on ctx 'internal/plugin
            (lambda (f)
              (note! seen (list (fiber-state f)
                                (and (fiber-uid f) #t)
                                (and (member "ctx.plugin()" (labels-of (context-fiber ctx))) #t)
                                (fiber-committed f)))))
    (define f (ctx-inject ctx '(svc) void))
    (check-equal? (notes seen) '((pending #t #t #f)))
    (check-eq? (fiber-state f) 'loading)
    (await f)))

;; source: contract 6, fiber accessors; recon 01 S23 (uids, names)
(test-case "fiber/surface: uid, name, plugin, parent, context, config and ctx-fibers"
  (with-root (ctx)
    (define p (named "outer-plugin" (lambda (c config) (void))))
    (define parent-ctx (context-extend ctx (hasheq 'where 'here)))
    (define f1 (ctx-plugin parent-ctx p 'config-1))
    (define f2 (ctx-plugin ctx p 'config-2))
    (define f3 (ctx-plugin ctx (lambda (c config) (void))))
    (await f1)
    (await f2)
    (await f3)
    (define uids (map fiber-uid (list f1 f2 f3)))
    (check-true (andmap exact-positive-integer? uids))
    (check-true (apply < uids))
    (check-eq? (fiber-plugin f1) p)
    (check-eq? (fiber-plugin f2) p)
    (check-false (eq? f1 f2))
    (check-eq? (fiber-parent f1) parent-ctx)
    (check-eq? (context-fiber (fiber-context f1)) f1)
    (check-eq? (context-meta (fiber-context f1) 'where) 'here)
    (check-eq? (fiber-config f1) 'config-1)
    (check-eq? (fiber-effective-config f2) 'config-2)
    (check-false (fiber-error f1))
    (check-true (custodian? (fiber-custodian f1)))
    (check-equal? (fiber-name f1) "outer-plugin")
    (check-equal? (fiber-name f3) "root")
    (define nested (ctx-plugin (fiber-context f1) (lambda (c config) (void))))
    (define injected (ctx-inject (fiber-context f1) '() void))
    (await nested)
    (check-equal? (fiber-name nested) "outer-plugin")
    (check-equal? (fiber-name injected) "outer-plugin")
    (check-equal? (ctx-fibers ctx) (list f1 f2 f3 nested injected))
    (check-equal? (ctx-fibers (fiber-context f1)) (ctx-fibers ctx))))

;; source: contract 6 rule 1 (inactive parent); recon 01 S19
(test-case "fiber rule 1 / S19: a disposed context rejects plugin, effect and listener"
  (with-root (ctx)
    (define f (ctx-plugin ctx (lambda (c config) (void))))
    (await f)
    (define dead (fiber-context f))
    (fiber-dispose! f)
    (define inactive? (raises? exn:fail:cordis:inactive? inactive-message))
    (check-exn inactive? (lambda () (ctx-plugin dead (lambda (c config) (void)))))
    (check-exn inactive? (lambda () (ctx-effect dead void)))
    (check-exn inactive? (lambda () (ctx-on dead 'spec/event void)))
    (check-exn inactive? (lambda () (ctx-provide dead 'svc 1)))
    ;; source: registry.ts "invalid plugin"; the contract restricts the argument
    (check-exn exn:fail? (lambda () (ctx-plugin ctx 42)))))

;; source: recon 01 "Fiber construction", "legal on a PENDING parent; the child
;; then activates on its own dependencies"
(test-case "fiber rule 1: a child of a pending parent activates on its own dependencies"
  (with-root (ctx)
    (define parent (ctx-inject ctx '(missing) void))
    (check-eq? (fiber-state parent) 'pending)
    (define child (ctx-plugin (fiber-context parent) (lambda (c config) (void))))
    (await child)
    (check-eq? (fiber-state child) 'active)
    (check-eq? (fiber-state parent) 'pending)
    (fiber-dispose! parent)
    (check-eq? (fiber-state child) 'disposed)))

;; source: contract 6 rule 2; analysis law 6; recon 01 S5
(test-case "fiber rule 2: the target follows the providers; pending until all are active"
  (with-root (ctx)
    (define runs (make-recorder))
    (define f
      (ctx-inject ctx '(a b) (lambda (c) (note! runs (list (ctx-ref c 'a) (ctx-ref c 'b))))))
    (check-eq? (fiber-state f) 'pending)
    (check-eq? (sync/timeout 0 f) f)
    (define da (ctx-provide ctx 'a 1))
    (check-eq? (fiber-state f) 'pending)
    (ctx-provide ctx 'b 2)
    (check-eq? (fiber-state f) 'loading)
    (await f)
    (check-eq? (fiber-state f) 'active)
    (da)
    (settle f)
    (check-eq? (fiber-state f) 'pending)
    (check-equal? (notes runs) '((1 2)))))

;; source: contract 6 rule 3, "commit the resolved providers"; rule 4, "clear
;; the committed view"
(test-case "fiber rule 3: the committed view holds the injected values while loaded"
  (with-root (ctx)
    (define d (ctx-provide ctx 'svc 'value))
    (define f (ctx-inject ctx '(svc) void))
    (define plain (ctx-plugin ctx (lambda (c config) (void))))
    (check-false (fiber-committed (ctx-inject ctx '(absent) void)))
    (await f)
    (await plain)
    (check-equal? (hash->list (fiber-committed f)) '((svc . value)))
    (check-equal? (hash-count (fiber-committed plain)) 0)
    (d)
    (settle f)
    (check-false (fiber-committed f))))

;; source: contract 6, "Plugin body": arguments, current-context, custodian
(test-case "fiber/body: runs with its context, validated config and the fiber's custodian"
  (with-root (ctx)
    (define seen (box #f))
    (define f (ctx-plugin ctx
                          (lambda (c config)
                            (set-box! seen (list (eq? (current-context) c)
                                                 config
                                                 (eq? (current-custodian)
                                                      (fiber-custodian (context-fiber c)))
                                                 (in-task? (context-scheduler c))))
                            (void))
                          'the-config))
    (await f)
    (check-equal? (unbox seen) '(#t the-config #t #t))
    (check-eq? (context-fiber (fiber-context f)) f)))

;; source: contract 6, "Plugin body": "the fiber stays 'loading until it
;; returns and every asynchronous effect result it returned has settled"
(test-case "fiber/body: stays loading until asynchronous effect results settle"
  (with-root (ctx)
    (define gate (make-gate))
    (define log (make-recorder))
    (define f (ctx-plugin ctx (lambda (c config)
                                (spawn-task (lambda ()
                                              (gate-wait gate)
                                              (lambda () (note! log 'async-inverse)))
                                            #:scheduler (context-scheduler c)))))
    (yield-times 5)
    (check-eq? (fiber-state f) 'loading)
    (gate-open! gate)
    (await f)
    (check-eq? (fiber-state f) 'active)
    (fiber-dispose! f)
    (check-equal? (notes log) '(async-inverse))))

;; source: contract 6 rule 3, body failure; rule 9; recon 01 S4
(test-case "fiber rule 3 / S4: a failing body is logged, unloads its effects and ends failed"
  (with-root (ctx)
    (define log (make-recorder))
    (define status (make-recorder))
    (record-status! ctx "fragile" status)
    (define attempts 0)
    (define f (box #f))
    (define-values (result logs)
      (capture-log
       (lambda ()
         (set-box! f (ctx-plugin ctx
                                 (named "fragile"
                                        (lambda (c config)
                                          (set! attempts (add1 attempts))
                                          (ctx-effect c (lambda ()
                                                          (lambda () (note! log 'cleaned))))
                                          (when (eq? config 'bad)
                                            (raise-user-error "body exploded"))
                                          (void)))
                                 'bad))
         (settle (unbox f)))
       #:level 'error
       #:topic 'cordis))
    (define fb (unbox f))
    (check-true (pair? logs))
    (check-eq? (fiber-state fb) 'failed)
    (check-regexp-match #rx"body exploded" (exn-message (fiber-error fb)))
    (check-equal? (notes log) '(cleaned))
    (check-equal? (fiber-effects fb) '())
    ;; source: recon 01 "Observed sequences": failing body 0->1, 1->5, 5->3
    (check-equal? (notes status)
                  '((pending . loading) (loading . unloading) (unloading . failed)))
    (check-exn #rx"body exploded" (lambda () (await fb)))
    (check-exn #rx"body exploded" (lambda () (fiber-await fb)))
    (check-eq? (sync/timeout 0 fb) fb)
    ;; rule 9: restart does not retry a failed fiber
    (check-exn #rx"body exploded" (lambda () (fiber-restart! fb)))
    (check-equal? attempts 1)
    ;; rule 9: update clears the error and retries
    (fiber-update! fb 'good)
    (check-eq? (fiber-state fb) 'active)
    (check-false (fiber-error fb))
    (check-equal? attempts 2)
    (check-equal? (drop (notes status) 3) '((failed . loading) (loading . active)))))

;; source: contract 6, fiber-error "(or/c exn? any/c #f)"; recon 01 "a thrown
;; non-error value" (the contract keeps the raised value instead of wrapping it)
(test-case "fiber rule 3: a body that raises a non-exception value fails the fiber"
  (with-root (ctx)
    (define f (ctx-plugin ctx (lambda (c config) (raise 'not-an-exception))))
    (settle f)
    (check-eq? (fiber-state f) 'failed)
    (check-true (and (fiber-error f) #t))))

;; source: contract 6 rule 9; digest law 32 (not retried by notifications)
(test-case "fiber rule 9: a failed fiber is not retried by dependency notifications"
  (with-root (ctx)
    (define attempts 0)
    (define d (ctx-provide ctx 'svc 1))
    (define f (ctx-inject ctx '(svc) (lambda (c)
                                       (set! attempts (add1 attempts))
                                       (raise-user-error "always fails"))))
    (settle f)
    (check-eq? (fiber-state f) 'failed)
    (d)
    (ctx-provide ctx 'svc 2)
    (yield-times 5)
    (settle f)
    (check-eq? (fiber-state f) 'failed)
    (check-equal? attempts 1)))

;; source: contract 6 rule 3, "yield once; if the target is unchanged";
;; recon 01 G3, S2
(test-case "fiber rule 3 / S2: disposing right after ctx-plugin skips the body"
  (with-root (ctx)
    (define ran? #f)
    (define f (ctx-plugin ctx (lambda (c config) (set! ran? #t) (void))))
    (fiber-dispose! f)
    (check-false ran?)
    (check-eq? (fiber-state f) 'disposed)
    (check-false (fiber-uid f))))

;; source: contract 6 rule 3, fresh custodian per activation; rule 4, custodian
;; shutdown; ADR 0004; analysis law 14 (custodian backstop)
(test-case "fiber rule 3/4: each activation has its own custodian, shut down at unload"
  (with-root (ctx)
    (define threads (make-recorder))
    (define custodians (make-recorder))
    (define f (ctx-plugin ctx (lambda (c config)
                                (note! custodians (current-custodian))
                                ;; A leaked thread: the body returns no inverse for it.
                                (note! threads (thread (lambda () (sync (make-semaphore 0)))))
                                (void))))
    (await f)
    (define first-thread (first (notes threads)))
    (check-false (thread-dead? first-thread))
    (fiber-restart! f)
    (check-true (thread-dead? first-thread))
    (check-equal? (length (notes custodians)) 2)
    (check-false (eq? (first (notes custodians)) (second (notes custodians))))
    (define second-thread (second (notes threads)))
    (check-false (thread-dead? second-thread))
    (fiber-dispose! f)
    (check-true (thread-dead? second-thread))))

;; source: contract 6, make-plugin "#:custodian 'inherit"; rule 3; ADR 0004
(test-case "fiber rule 3: custodian mode 'inherit creates no activation custodian"
  (with-root (ctx)
    (define leaked (box #f))
    (define stop (make-semaphore 0))
    (define f (ctx-plugin ctx (make-plugin (lambda (c config)
                                             (set-box! leaked (thread (lambda () (sync stop))))
                                             (void))
                                           #:custodian 'inherit)))
    (await f)
    (fiber-dispose! f)
    (check-false (thread-dead? (unbox leaked)))
    (semaphore-post stop)))

;; source: contract 6 rule 4, effect disposal order; recon 01 "Disposal order
;; summary" and S17
(test-case "fiber rule 4 / S17: unload starts top-level disposers in reverse registration order"
  (with-root (ctx)
    (define log (make-recorder))
    (define g2-gate (make-gate))
    (define e2-gate (make-gate))
    (define g2-started (make-gate))
    (define e1-ran (make-gate))
    (define child-ran (make-gate))
    (define child (box #f))
    (define f
      (ctx-plugin
       ctx
       (lambda (c config)
         (set-box! child
                   (ctx-plugin c (lambda (cc config)
                                   (ctx-effect cc (lambda ()
                                                    (lambda ()
                                                      (note! log 'child-e)
                                                      (gate-open! child-ran))))
                                   (void))))
         (ctx-effect c (lambda () (lambda () (note! log 'e1) (gate-open! e1-ran))))
         (ctx-effect c (lambda ()
                         (lambda ()
                           (note! log 'e2-start)
                           (gate-wait e2-gate)
                           (note! log 'e2-end))))
         (ctx-effect c (lambda () (lambda () (note! log 'e3))))
         (ctx-effect c (lambda ()
                         (list (lambda () (note! log 'g1))
                               (lambda ()
                                 (note! log 'g2-start)
                                 (gate-open! g2-started)
                                 (gate-wait g2-gate)
                                 (note! log 'g2-end))
                               (lambda () (note! log 'g3)))))
         (lambda () (note! log 'returned-disposer)))))
    (await f)
    (await (unbox child))
    (define disposing (spawn-task (lambda () (fiber-dispose! f))))
    (gate-wait g2-started)
    (gate-wait e1-ran)
    (gate-wait child-ran)
    (check-false (task-done? disposing))
    (gate-open! g2-gate)
    (yield-until (lambda () (memq 'g1 (notes log))))
    (gate-open! e2-gate)
    (await disposing)
    (check-equal? (notes log)
                  '(returned-disposer g3 g2-start e3 e2-start e1 child-e g2-end g1 e2-end))))

;; source: contract 6 rule 4, "logging failures"; fiber.ts _unload
(test-case "fiber rule 4: a failing disposer is logged and does not stop the others"
  (with-root (ctx)
    (define log (make-recorder))
    (define f (ctx-plugin ctx (lambda (c config)
                                (ctx-effect c (lambda () (lambda () (note! log 'first))))
                                (ctx-effect c (lambda ()
                                                (lambda () (raise-user-error "disposer failed"))))
                                (ctx-effect c (lambda () (lambda () (note! log 'third))))
                                (void))))
    (await f)
    (define-values (result logs)
      (capture-log (lambda () (fiber-dispose! f)) #:level 'error #:topic 'cordis))
    (check-equal? result (void))
    (check-true (pair? logs))
    (check-equal? (notes log) '(third first))
    (check-eq? (fiber-state f) 'disposed)))

;; source: contract 6 rule 5; fiber.ts _updateState; recon 01 "Observed
;; sequences" and S3
(test-case "fiber rule 5 / S3: every state change emits internal/status with the old state"
  (with-root (ctx)
    (define status (make-recorder))
    (record-status! ctx "watched" status)
    (define f (ctx-plugin ctx (named "watched" (lambda (c config) (void)))))
    (await f)
    (check-equal? (notes status) '((pending . loading) (loading . active)))
    (fiber-restart! f)
    (check-equal? (drop (notes status) 2)
                  '((active . unloading) (unloading . loading) (loading . active)))
    (fiber-dispose! f)
    (check-equal? (drop (notes status) 5) '((active . unloading) (unloading . disposed)))))

;; source: contract 6 rule 5, second sentence; recon 01 G5
(test-case "fiber rule 5: entering and leaving active notifies for the names the fiber provides"
  (with-root (ctx)
    (define events (make-recorder))
    (ctx-on ctx 'internal/service
            (lambda (name value) (when (eq? name 'svc) (note! events value))))
    (define gate (make-gate))
    (define provided (make-gate))
    (define provider (ctx-plugin ctx (lambda (c config)
                                       (ctx-provide c 'svc 'value)
                                       (gate-open! provided)
                                       (gate-wait gate)
                                       (void))))
    (define consumer (ctx-inject ctx '(svc) void))
    (gate-wait provided)
    (yield-times 3)
    ;; Provided by a loading fiber: no notification yet, the consumer waits.
    (check-equal? (notes events) '())
    (check-eq? (fiber-state consumer) 'pending)
    (gate-open! gate)
    (await provider)
    (await consumer)
    (check-eq? (fiber-state consumer) 'active)
    (check-equal? (notes events) '(value))
    (check-equal? (fiber-provisions provider) '(svc))
    (fiber-dispose! provider)
    (settle consumer)
    (check-eq? (fiber-state consumer) 'pending)
    (check-eq? (last (notes events)) #f)))

;; source: contract 6 rule 6; fiber.ts disposer; recon 01 S3 (uid null in the
;; disposal internal/plugin, state still the pre-disposal value)
(test-case "fiber rule 6: dispose clears the uid, publishes, detaches and waits"
  (with-root (ctx)
    (define rf (context-fiber ctx))
    (define seen (make-recorder))
    (ctx-on ctx 'internal/plugin
            (lambda (f) (note! seen (list (and (fiber-uid f) #t) (fiber-state f)))))
    (define log (make-recorder))
    (define f (ctx-plugin ctx (lambda (c config) (lambda () (note! log 'unloaded)))))
    (await f)
    (check-equal? (ctx-fibers ctx) (list f))
    (check-equal? (fiber-dispose! f) (void))
    (check-equal? (notes seen) '((#t pending) (#f active)))
    (check-false (fiber-uid f))
    (check-eq? (fiber-state f) 'disposed)
    (check-equal? (ctx-fibers ctx) '())
    (check-false (member "ctx.plugin()" (labels-of rf)))
    (check-equal? (notes log) '(unloaded))
    (check-eq? (sync/timeout 0 f) f)
    ;; A second dispose does nothing.
    (check-equal? (fiber-dispose! f) (void))
    (check-equal? (notes log) '(unloaded))
    (check-exn (raises? exn:fail:cordis:inactive? inactive-message)
               (lambda () (fiber-restart! f)))
    (check-exn (raises? exn:fail:cordis:inactive? inactive-message)
               (lambda () (fiber-update! f 'config)))))

;; source: contract 6 rule 6, last sentence; analysis law 10; digest law 29
(test-case "fiber rule 6: disposing a parent disposes its children and grandchildren"
  (with-root (ctx)
    (define log (make-recorder))
    (define child (box #f))
    (define grandchild (box #f))
    (define parent
      (ctx-plugin
       ctx
       (lambda (c config)
         (set-box! child
                   (ctx-plugin c (lambda (cc config)
                                   (set-box! grandchild
                                             (ctx-plugin cc (lambda (gc config)
                                                              (lambda () (note! log 'grandchild)))))
                                   (lambda () (note! log 'child)))))
         (void))))
    (await parent)
    (await (unbox child))
    (await (unbox grandchild))
    (fiber-dispose! parent)
    (check-equal? (map fiber-state (list parent (unbox child) (unbox grandchild)))
                  '(disposed disposed disposed))
    (check-equal? (sort (notes log) symbol<?) '(child grandchild))
    (check-equal? (ctx-fibers ctx) '())))

;; source: contract 6 rule 7, fiber-restart!
(test-case "fiber rule 7: restart unloads, reloads with the same raw config and waits"
  (with-root (ctx)
    (define log (make-recorder))
    (define f (ctx-plugin ctx
                          (lambda (c config)
                            (note! log (list 'apply config))
                            (lambda () (note! log 'unload)))
                          'cfg))
    (await f)
    (check-equal? (fiber-restart! f) (void))
    (check-eq? (fiber-state f) 'active)
    (check-equal? (notes log) '((apply cfg) unload (apply cfg)))))

;; source: contract 6 rule 7, fiber-update!; recon 01 "Config update" and S24
(test-case "fiber rule 7: update commits, stores the raw config and restarts"
  (with-root (ctx)
    (define commits (make-recorder))
    (ctx-on ctx 'internal/commit (lambda (f raw) (note! commits raw)))
    (define log (make-recorder))
    (define f (ctx-plugin ctx
                          (lambda (c config)
                            (note! log (list 'apply config))
                            (lambda () (note! log 'unload)))
                          'v1))
    (await f)
    (check-equal? (fiber-update! f 'v2) (void))
    (check-equal? (notes commits) '(v2))
    (check-eq? (fiber-config f) 'v2)
    (check-eq? (fiber-effective-config f) 'v2)
    (check-equal? (notes log) '((apply v1) unload (apply v2)))
    ;; #:save? #f suppresses internal/commit
    (fiber-update! f 'v3 #:save? #f)
    (check-equal? (notes commits) '(v2))
    (check-eq? (fiber-effective-config f) 'v3)
    (check-equal? (drop (notes log) 3) '(unload (apply v3)))))

;; source: contract 6 rule 7, "A listener that returns without calling next
;; keeps the instance"; rule 8; recon 01 S12
(test-case "fiber rule 7/8 / S12: a fiber-local internal/update listener can keep the instance"
  (with-root (ctx)
    (define applied (make-recorder))
    (define seen (make-recorder))
    (define f (ctx-plugin ctx
                          (lambda (c config)
                            (note! applied config)
                            (ctx-on c 'internal/update
                                    (lambda (fiber resolved next)
                                      (note! seen (list (eq? fiber (context-fiber c)) resolved))
                                      (void)))
                            (void))
                          'v1))
    (await f)
    (check-true (and (member "ctx.on(\"internal/update\")" (labels-of f)) #t))
    (fiber-update! f 'v2)
    (check-equal? (notes applied) '(v1))
    (check-equal? (notes seen) '((#t v2)))
    (check-eq? (fiber-config f) 'v2)
    (check-eq? (fiber-effective-config f) 'v2)
    (check-eq? (fiber-state f) 'active)))

;; source: contract 6 rule 8; events.ts kernel listeners; recon 01 "Resulting
;; internal/update order"
(test-case "fiber rule 8: local update listeners see their own fiber only; order of the chain"
  (with-root (ctx)
    (define log (make-recorder))
    (define (plugin tag)
      (lambda (c config)
        (ctx-on c 'internal/update
                (lambda (fiber resolved next) (note! log (list 'local tag resolved)) (next)))
        (void)))
    (define a (ctx-plugin ctx (plugin 'a) 'a1))
    (define b (ctx-plugin ctx (plugin 'b) 'b1))
    (await a)
    (await b)
    (ctx-on ctx 'internal/update
            (lambda (fiber resolved next) (note! log (list 'global resolved)) (next))
            #:global? #t)
    (ctx-on ctx 'internal/update
            (lambda (fiber resolved next) (note! log (list 'global-prepended resolved)) (next))
            #:global? #t
            #:prepend? #t)
    (fiber-update! a 'a2)
    (check-equal? (notes log) '((global-prepended a2) (local a a2) (global a2)))
    (fiber-update! b 'b2)
    (check-equal? (drop (notes log) 3) '((global-prepended b2) (local b b2) (global b2)))))

;; source: contract 6, "Config schemas" (procedure form); recon 01 S24
(test-case "fiber/config: a schema procedure validates; defaults reach the body, raw stays raw"
  (with-root (ctx)
    (define (schema raw)
      (hash-set raw 'port (hash-ref raw 'port 8080)))
    (define seen (make-recorder))
    (define raw (hasheq 'host "localhost"))
    (define f (ctx-plugin ctx
                          (named "configured" (lambda (c config) (note! seen config) (void))
                                 #:config schema)
                          raw))
    (await f)
    (check-eq? (fiber-config f) raw)
    (check-equal? (hash-ref (first (notes seen)) 'port) 8080)
    (check-eq? (fiber-effective-config f) (first (notes seen)))))

;; source: contract 6, "Config schemas", exn:fail:cordis:validation and its
;; message format; fiber.ts ValidationError; recon 01 S24
(test-case "fiber/config: an invalid initial config fails the fiber with the validation error"
  (with-root (ctx)
    (define message "invalid config:\n  - expected a number (at server.port)")
    (define (schema raw)
      (unless (number? raw)
        (raise (exn:fail:cordis:validation message
                                           (current-continuation-marks)
                                           (list (cons '(server port) "expected a number")))))
      raw)
    (define ran? #f)
    (define f (ctx-plugin ctx
                          (named "strict" (lambda (c config) (set! ran? #t) (void)) #:config schema)
                          'not-a-number))
    (settle f)
    (check-false ran?)
    (check-eq? (fiber-state f) 'failed)
    (define e (fiber-error f))
    (check-pred exn:fail:cordis:validation? e)
    (check-pred exn:fail:cordis? e)
    (check-equal? (exn-message e) message)
    (check-equal? (exn:fail:cordis:validation-issues e)
                  (list (cons '(server port) "expected a number")))
    ;; rule 9: an update with a valid config recovers the failed fiber.
    (fiber-update! f 7)
    (check-eq? (fiber-state f) 'active)
    (check-true ran?)))

;; source: contract 6 rule 7, "validates the candidate ... when the fiber is
;; loaded"; fiber.ts update step 2; recon 01 S24
(test-case "fiber/config: an invalid update of a loaded fiber raises and changes nothing"
  (with-root (ctx)
    (define (schema raw)
      (unless (number? raw)
        (raise (exn:fail:cordis:validation "invalid config:\n  - expected a number"
                                           (current-continuation-marks)
                                           (list (cons '() "expected a number")))))
      raw)
    (define commits (make-recorder))
    (ctx-on ctx 'internal/commit (lambda (f raw) (note! commits raw)))
    (define applied (make-recorder))
    (define f (ctx-plugin ctx
                          (named "strict" (lambda (c config) (note! applied config) (void))
                                 #:config schema)
                          1))
    (await f)
    (check-exn exn:fail:cordis:validation? (lambda () (fiber-update! f 'bad)))
    (check-equal? (notes commits) '())
    (check-eqv? (fiber-config f) 1)
    (check-eqv? (fiber-effective-config f) 1)
    (check-eq? (fiber-state f) 'active)
    (check-equal? (notes applied) '(1))))

;; source: contract 6, "Config schemas", "any value applicable to one argument
;; (a procedure, or a struct with prop:procedure such as a cordis-schema schema)"
(test-case "fiber/config: a struct with prop:procedure is a schema"
  (with-root (ctx)
    (struct at-least (minimum)
      #:property prop:procedure
      (lambda (self raw) (max raw (at-least-minimum self))))
    (define schema (at-least 10))
    (define seen (make-recorder))
    (define p (named "clamped" (lambda (c config) (note! seen config) (void)) #:config schema))
    (check-eq? (plugin-config-schema p) schema)
    (define f (ctx-plugin ctx p 3))
    (await f)
    (check-equal? (notes seen) '(10))
    (check-eqv? (fiber-config f) 3)
    (check-eqv? (fiber-effective-config f) 10)))

;; source: contract 6, "Config schemas", "Whatever it raises propagates
;; unchanged and is what the fiber records as its error"
(test-case "fiber/config: what a schema raises is recorded and propagated unchanged"
  (with-root (ctx)
    (define failure (make-exn:fail:user "schema says no" (current-continuation-marks)))
    (define (schema raw) (if (eq? raw 'bad) (raise failure) raw))
    (define f (ctx-plugin ctx
                          (named "picky" (lambda (c config) (void)) #:config schema)
                          'bad))
    (settle f)
    (check-eq? (fiber-state f) 'failed)
    (check-eq? (fiber-error f) failure)
    (check-eq? (with-handlers ([exn:fail? values]) (fiber-await f)) failure)
    (fiber-update! f 'good)
    (check-eq? (fiber-state f) 'active)
    ;; A loaded fiber validates the candidate in the caller: the same object
    ;; reaches the caller of fiber-update! and the fiber stays as it was.
    (check-eq? (with-handlers ([exn:fail? values]) (fiber-update! f 'bad)) failure)
    (check-eq? (fiber-state f) 'active)
    (check-eq? (fiber-config f) 'good)
    (check-false (fiber-error f))))

;; source: contract 6, "Config schemas", exn:fail:cordis:validation message and
;; "(raise-validation-error issues)"; fiber.ts ValidationError; recon 01
;; Formats ("  - <message> (at <path joined by .>)")
(test-case "fiber/config: raise-validation-error builds the Cordis ValidationError text"
  (define raise-validation-error (optional-binding 'cordis 'raise-validation-error))
  (check-true (procedure? raise-validation-error) "cordis must export raise-validation-error")
  (when (procedure? raise-validation-error)
    (define issues (list (cons '(server port) "expected a number")
                         (cons '(name) "required")))
    (define e (with-handlers ([exn:fail? values]) (raise-validation-error issues) 'returned))
    (check-pred exn:fail:cordis:validation? e)
    (check-pred exn:fail:cordis? e)
    (check-equal? (exn:fail:cordis:validation-issues e) issues)
    (check-equal? (exn-message e)
                  "invalid config:\n  - expected a number (at server.port)\n  - required (at name)")
    ;; fiber.ts prints an issue that has no path without the "(at ...)" part;
    ;; the contract does not say how a path-less issue is written, so only the
    ;; start of its line is checked.
    (define pathless
      (with-handlers ([exn:fail? values]) (raise-validation-error (list (cons '() "bad value")))))
    (check-pred exn:fail:cordis:validation? pathless)
    (check-regexp-match #rx"^invalid config:\n  - bad value" (exn-message pathless))
    ;; A schema that uses the helper fails its fiber with that exception.
    (with-root (ctx)
      (define (schema raw)
        (unless (number? raw) (raise-validation-error (list (cons '(port) "expected a number"))))
        raw)
      (define f (ctx-plugin ctx
                            (named "validated" (lambda (c config) (void)) #:config schema)
                            'not-a-number))
      (settle f)
      (check-eq? (fiber-state f) 'failed)
      (check-pred exn:fail:cordis:validation? (fiber-error f))
      (check-equal? (exn-message (fiber-error f))
                    "invalid config:\n  - expected a number (at port)"))))

;; source: contract 12 addendum 3, "A fiber's context is derived from the
;; context ctx-plugin was called on, so it inherits that context's meta, realms
;; and interception layers"
(test-case "fiber/context: a fiber's context inherits meta, realms and intercept layers"
  (with-root (ctx)
    (define scoped
      (context-intercept
       (context-isolate (context-extend ctx (hasheq 'loader/entry-id "entry-1" 'tier 'outer))
                        'scoped-service)
       'scoped-service
       (hasheq 'level 1)))
    (define child (box #f))
    (define f
      (ctx-plugin scoped
                  (lambda (c config)
                    (set-box! child (ctx-plugin (context-extend c (hasheq 'tier 'inner))
                                                (lambda (cc config) (void))))
                    (void))))
    (await f)
    (await (unbox child))
    (define fc (fiber-context f))
    (define cc (fiber-context (unbox child)))
    (check-eq? (fiber-parent f) scoped)
    (check-eq? (context-root cc) ctx)
    (check-equal? (context-meta fc 'loader/entry-id) "entry-1")
    (check-equal? (context-meta cc 'loader/entry-id) "entry-1")
    (check-eq? (context-meta fc 'tier) 'outer)
    (check-eq? (context-meta cc 'tier) 'inner)
    (define realm (context-realm scoped 'scoped-service))
    (check-true (symbol? realm))
    (check-eq? (context-realm fc 'scoped-service) realm)
    (check-eq? (context-realm cc 'scoped-service) realm)
    (check-false (eq? (context-realm ctx 'scoped-service) realm))
    (check-equal? (context-intercepts fc 'scoped-service) (list (hasheq 'level 1)))
    (check-equal? (context-intercepts cc 'scoped-service) (list (hasheq 'level 1)))
    ;; A service provided through the fiber's context lands in the inherited realm.
    (ctx-provide fc 'scoped-service 'inside)
    (check-eq? (ctx-get scoped 'scoped-service) 'inside)
    (check-false (ctx-get ctx 'scoped-service))))

;; source: contract 6 rule 3, "validate the config through the
;; 'internal/config waterfall"; events.ts kernel listener; recon 01 S13
(test-case "fiber/config: internal/config listeners wrap validation for every fiber"
  (with-root (ctx)
    (define log (make-recorder))
    (define (schema raw) (list 'validated raw))
    (ctx-on ctx 'internal/config
            (lambda (f next)
              (define inner (next))
              (note! log (list 'later-listener inner))
              (list 'evaluated inner)))
    (ctx-on ctx 'internal/config
            (lambda (f next)
              (define result (next))
              (note! log (list 'prepended-listener result))
              result)
            #:prepend? #t)
    (define seen (box #f))
    (define f (ctx-plugin ctx
                          (named "resolved" (lambda (c config) (set-box! seen config) (void))
                                 #:config schema)
                          'raw))
    (await f)
    ;; Later-registered listeners are inner and see the raw value; validation
    ;; runs on their result; a prepended listener sees the validated value.
    (check-equal? (unbox seen) '(validated (evaluated raw)))
    (check-equal? (notes log)
                  '((later-listener raw) (prepended-listener (validated (evaluated raw)))))))

;; source: recon 01 S20; "Dependency tracking" consequences (provider restart)
(test-case "S20: a provider restart unloads dependents first and reloads them after"
  (with-root (ctx)
    (define log (make-recorder))
    (define provider
      (ctx-plugin ctx (lambda (c config)
                        (note! log 'prov-apply)
                        (define alive (box #t))
                        (ctx-provide c 'svc alive)
                        (lambda () (note! log 'prov-cleanup) (set-box! alive #f)))))
    (define consumer
      (ctx-inject ctx '(svc)
                  (lambda (c)
                    (note! log 'cons-apply)
                    (lambda ()
                      (note! log (list 'cons-cleanup 'alive (unbox (ctx-ref c 'svc))))))))
    (await provider)
    (await consumer)
    (check-equal? (notes log) '(prov-apply cons-apply))
    (fiber-restart! provider)
    (settle consumer)
    (check-equal? (drop (notes log) 2)
                  '((cons-cleanup alive #t) prov-cleanup prov-apply cons-apply))
    (check-eq? (fiber-state consumer) 'active)))

;; source: recon 01 S28, "Root fiber" (dispose is restart); contract 3,
;; context-dispose!
(test-case "S28: disposing the root unloads everything and leaves a working root"
  (with-root (ctx)
    (define rf (context-fiber ctx))
    (define before (labels-of rf))
    (define log (make-recorder))
    (define f (ctx-plugin ctx (lambda (c config) (lambda () (note! log 'plugin)))))
    (ctx-effect ctx (lambda () (lambda () (note! log 'effect))))
    (ctx-provide ctx 'svc 1)
    (ctx-on ctx 'spec/event void)
    (await f)
    (check-equal? (context-dispose! ctx) (void))
    (check-eq? (fiber-state rf) 'active)
    (check-equal? (fiber-uid rf) 0)
    (check-eq? (fiber-state f) 'disposed)
    (check-equal? (sort (notes log) symbol<?) '(effect plugin))
    (check-equal? (ctx-fibers ctx) '())
    (check-equal? (labels-of rf) before)
    (check-false (ctx-has? ctx 'svc))
    (check-equal? (ctx-listeners ctx 'spec/event) '())
    ;; The kernel still works afterwards.
    (ctx-provide ctx 'svc 2)
    (define again (ctx-inject ctx '(svc) void))
    (await again)
    (check-eq? (fiber-state again) 'active)))

;; source: recon 01 S13, "double resolution during an update"; fiber.ts update
;; (candidate resolution) and _execute (activation resolution)
(test-case "S13: an update resolves the config for the candidate and again for the activation"
  (with-root (ctx)
    (define resolutions (make-recorder))
    (define f (ctx-plugin ctx (lambda (c config) (void)) 'v1))
    (await f)
    (ctx-on ctx 'internal/config
            (lambda (target next)
              (define raw (next))
              (when (eq? target f) (note! resolutions raw))
              raw))
    (fiber-update! f 'v2)
    (check-equal? (notes resolutions) '(v2 v2))
    (check-eq? (fiber-effective-config f) 'v2)))

;; source: contract 3, "Every public kernel operation that mutates state may be
;; called from any thread. When called outside a task it runs through
;; call-in-kernel on the root's scheduler"; contract 2 rule 5 (await of a fiber
;; outside a task) and rule 7
(test-case "context/threads: kernel operations may be called from a plain thread"
  (with-root (ctx)
    (define sched (context-scheduler ctx))
    (define log (make-recorder))
    (ctx-on ctx 'spec/threaded (lambda (x) (note! log (list 'heard x (in-task? sched)))))
    (define outcome (box 'not-run))
    (define worker
      (thread
       (lambda ()
         (set-box!
          outcome
          (with-handlers ([(lambda (e) #t) values])
            (define d (ctx-provide ctx 'threaded 'value))
            (define f
              (ctx-inject ctx '(threaded)
                          (lambda (c)
                            (note! log (list 'apply (ctx-ref c 'threaded) (in-task? sched)))
                            (lambda () (note! log 'unload)))))
            (define awaited (await f))
            (define state (fiber-state f))
            (ctx-emit ctx 'spec/threaded 1)
            (fiber-dispose! f)
            (d)
            (list (eq? awaited f) state (fiber-state f) (ctx-has? ctx 'threaded)
                  (in-task? sched)))))))
    (await (thread-dead-evt worker))
    (check-equal? (unbox outcome) '(#t active disposed #f #f))
    (check-equal? (notes log) '((apply value #t) (heard 1 #t) unload))))
