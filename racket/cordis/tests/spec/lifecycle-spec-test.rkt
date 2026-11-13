#lang racket/base
;; One-to-one ports of the kernel-level TypeScript lifecycle specs:
;;   scripts/cordis-core-lifecycle.spec.ts             (recon cases 1 to 3, 5 to 7)
;;   packages/extensions/tool-cordis/tests/cordis-lifecycle.spec.ts (cases 14 to 19)
;;   scripts/cordis-config-access.spec.ts              (cases 21 to 23)
;; Case numbers are those of docs/racket/recon/01-cordis-core.md, "Tests worth
;; porting". Cases 4, 8 and 9 to 13 are in service-, events- and
;; effect-spec-test.rkt; skipped cases are listed in MANIFEST.md.
;;
;; A TypeScript call that returns a promise (update, restart, dispose) blocks
;; its caller here, so a test that needs it in flight runs it in its own task.
(require cordis
         cordis/testing
         rackunit
         racket/list
         "support.rkt")

;; source: cordis-core-lifecycle.spec.ts "awaits the latest update while
;; loading (inject: %s)" (recon case 1)
(define (latest-update-wins inject?)
  (with-root (ctx)
    (ctx-provide ctx 'rc11-dependency 1)
    (define started (make-gate))
    (define release (make-gate))
    (define applied (make-recorder))
    (define disposed (make-recorder))
    (define f
      (ctx-plugin
       ctx
       (make-plugin (lambda (owner config)
                      (define value (hash-ref config 'value))
                      (note! applied value)
                      (when (= value 1)
                        (gate-open! started)
                        (gate-wait release))
                      (ctx-effect owner (lambda () (lambda () (note! disposed value))))
                      (void))
                    #:inject (if inject? '(rc11-dependency) '()))
       (hasheq 'value 0)))
    (await f)
    (define u1 (spawn-task (lambda () (fiber-update! f (hasheq 'value 1)))))
    (gate-wait started)
    (define u2 (spawn-task (lambda () (fiber-update! f (hasheq 'value 2)))))
    (define u3 (spawn-task (lambda () (fiber-update! f (hasheq 'value 3)))))
    ;; Both later updates are issued while the activation for 1 is loading.
    (check-true (yield-until (lambda () (equal? (fiber-config f) (hasheq 'value 3)))))
    (check-eq? (fiber-state f) 'loading)
    (gate-open! release)
    (await-all (list u1 u2 u3))
    (check-equal? (notes applied) '(0 1 3))
    (check-equal? (notes disposed) '(0 1))
    (check-eq? (fiber-state f) 'active)
    (check-equal? (fiber-effective-config f) (hasheq 'value 3))
    (fiber-dispose! f)
    (check-equal? (notes disposed) '(0 1 3))))

;; source: cordis-core-lifecycle.spec.ts "awaits the latest update while loading (inject: false)"
(test-case "case 1: the latest update wins while loading (without inject)"
  (latest-update-wins #f))

;; source: cordis-core-lifecycle.spec.ts "awaits the latest update while loading (inject: true)"
(test-case "case 1: the latest update wins while loading (with inject)"
  (latest-update-wins #t))

;; source: cordis-core-lifecycle.spec.ts "cleans up a superseded activation
;; failure and accepts the latest update" (recon case 2)
(test-case "case 2: a superseded activation failure is cleaned up and the update wins"
  (with-root (ctx)
    (define started (make-gate))
    (define release (make-gate))
    (define cleanups 0)
    (define f
      (ctx-plugin ctx
                  (lambda (owner config)
                    (ctx-effect owner (lambda () (lambda () (set! cleanups (add1 cleanups)))))
                    (when (eqv? config 1)
                      (gate-open! started)
                      (gate-wait release)
                      (raise-user-error "superseded activation"))
                    (void))
                  1))
    (gate-wait started)
    (define updating (spawn-task (lambda () (fiber-update! f 2))))
    (check-true (yield-until (lambda () (eqv? (fiber-config f) 2))))
    (gate-open! release)
    (await updating)
    (check-equal? cleanups 1)
    (check-eq? (fiber-state f) 'active)
    (check-eqv? (fiber-effective-config f) 2)
    (check-false (fiber-error f))))

;; source: cordis-core-lifecycle.spec.ts "retains isolated providers through
;; dependent teardown on %s" (recon case 3); analysis law 8
(define (providers-outlive-dependents action)
  (with-root (ctx)
    (define realm-ctx (context-isolate ctx 'rc11-service))
    (define realm (context-realm realm-ctx 'rc11-service))
    (define disposing (make-gate))
    (define release (make-gate))
    (define events (make-recorder))
    (define provider
      (ctx-plugin ctx
                  (lambda (owner config)
                    (define alive (box #t))
                    (ctx-provide (context-isolate owner 'rc11-service realm) 'rc11-service alive)
                    (ctx-effect owner (lambda ()
                                        (lambda ()
                                          (note! events 'provider)
                                          (set-box! alive #f))))
                    (void))))
    (await provider)
    (define consumer
      (ctx-inject realm-ctx '(rc11-service)
                  (lambda (owner)
                    (lambda ()
                      (gate-open! disposing)
                      (gate-wait release)
                      (note! events
                             (if (unbox (ctx-ref owner 'rc11-service))
                                 'consumer
                                 'consumer-saw-dead-service))))))
    (await consumer)
    (define task (spawn-task (lambda () (action provider))))
    (gate-wait disposing)
    (check-equal? (notes events) '())
    (gate-open! release)
    (await task)
    (settle consumer)
    (check-equal? (notes events) '(consumer provider))))

;; source: cordis-core-lifecycle.spec.ts "retains isolated providers through dependent
;; teardown on dispose"
(test-case "case 3: providers outlive dependent teardown on dispose"
  (providers-outlive-dependents fiber-dispose!))

;; source: cordis-core-lifecycle.spec.ts "retains isolated providers through dependent
;; teardown on restart"
(test-case "case 3: providers outlive dependent teardown on restart"
  (providers-outlive-dependents fiber-restart!))

;; source: cordis-core-lifecycle.spec.ts "publishes successful
;; retained-instance updates and ignores stale or rejected completions"
;; (recon case 5). A listener that returned a pending promise blocks here; a
;; rejected promise is a listener that raises after it was released.
(test-case "case 5: retained-instance updates publish; stale and rejected ones do not"
  (with-root (ctx)
    (define old (make-gate))
    (define failed (make-gate))
    (define values-seen (make-recorder))
    (define f
      (ctx-plugin ctx
                  (lambda (owner config)
                    (note! values-seen config)
                    (ctx-on owner 'internal/update
                            (lambda (fiber resolved next)
                              (cond [(eqv? resolved 1) (gate-wait old)]
                                    [(eqv? resolved 3)
                                     (gate-wait failed)
                                     (raise-user-error "update rejected")]
                                    [else (void)])))
                    (void))
                  0))
    (await f)
    (define u1 (spawn-task (lambda () (fiber-update! f 1))))
    (check-true (yield-until (lambda () (eqv? (fiber-config f) 1))))
    (yield-times 3)
    (check-eqv? (fiber-effective-config f) 0)
    (fiber-update! f 2)
    (gate-open! old)
    (await u1)
    (check-eqv? (fiber-effective-config f) 2)
    (define u3 (spawn-task (lambda () (fiber-update! f 3))))
    (check-true (yield-until (lambda () (eqv? (fiber-config f) 3))))
    (gate-open! failed)
    (check-exn #rx"update rejected" (lambda () (await u3)))
    (check-eqv? (fiber-config f) 3)
    (check-eqv? (fiber-effective-config f) 2)
    (check-equal? (notes values-seen) '(0))))

;; source: cordis-core-lifecycle.spec.ts "does not publish an old update after
;; %s" (recon case 6), variants restart and dispose. The 'raw retention'
;; variant is skipped: see MANIFEST.md.
(define (no-stale-publication action)
  (with-root (ctx)
    (define release (make-gate))
    (define configs (make-recorder))
    (define f
      (ctx-plugin ctx
                  (lambda (owner config)
                    (note! configs config)
                    (ctx-on owner 'internal/update
                            (lambda (fiber resolved next) (gate-wait release)))
                    (void))
                  (hasheq 'value 0)))
    (await f)
    (define candidate (hasheq 'value 1))
    (define old (spawn-task (lambda () (fiber-update! f candidate))))
    (check-true (yield-until (lambda () (eq? (fiber-config f) candidate))))
    (yield-times 3)
    (action f)
    (gate-open! release)
    (await old)
    (check-eq? (fiber-effective-config f) (last (notes configs)))))

;; source: cordis-core-lifecycle.spec.ts "does not publish an old update after restart"
(test-case "case 6: an old update does not publish after restart"
  (no-stale-publication fiber-restart!))

;; source: cordis-core-lifecycle.spec.ts "does not publish an old update after dispose"
(test-case "case 6: an old update does not publish after dispose"
  (no-stale-publication fiber-dispose!))

;; source: cordis-core-lifecycle.spec.ts "keeps the restarted config identity
;; when a listener delegates" (recon case 7)
(test-case "case 7: a delegating listener keeps the identity the new activation received"
  (with-root (ctx)
    (define applied (make-recorder))
    (define f
      (ctx-plugin ctx
                  (lambda (owner config)
                    (note! applied config)
                    (ctx-on owner 'internal/update (lambda (fiber resolved next) (next)))
                    (void))
                  (hasheq)))
    (await f)
    ;; Copies the candidate, so a published candidate differs from the object
    ;; the restarted activation receives.
    (ctx-on (fiber-context f) 'internal/config
            (lambda (fiber next)
              (for/hasheq ([(k v) (in-hash (next))]) (values k v))))
    (fiber-update! f (hasheq 'value 1))
    (check-equal? (length (notes applied)) 2)
    (check-eq? (fiber-effective-config f) (last (notes applied)))))

;; source: cordis-lifecycle.spec.ts "keeps effect registration legal while
;; child fibers are PENDING and LOADING" (recon case 14)
(test-case "case 14: effects may be registered while a fiber is pending and loading"
  (with-root (ctx)
    (define states (make-recorder))
    (define pending-cleanup? #f)
    (define loading-cleanup? #f)
    (ctx-on ctx 'internal/plugin
            (lambda (fiber)
              (when (and (equal? (fiber-name fiber) "state-probe") (fiber-uid fiber))
                (note! states (list 'observer (fiber-state fiber)))
                (ctx-effect (fiber-context fiber)
                            (lambda () (lambda () (set! pending-cleanup? #t)))
                            #:label "pending-effect"))))
    (define f
      (ctx-plugin ctx
                  (make-plugin (lambda (inner config)
                                 (note! states (list 'body (fiber-state (context-fiber inner))))
                                 (ctx-effect inner
                                             (lambda () (lambda () (set! loading-cleanup? #t)))
                                             #:label "loading-effect")
                                 (void))
                               #:name "state-probe")))
    (await f)
    (check-equal? (notes states) '((observer pending) (body loading)))
    (fiber-dispose! f)
    (check-true pending-cleanup?)
    (check-true loading-cleanup?)))

;; source: cordis-lifecycle.spec.ts "resolves dependencies that
;; internal/plugin adds before child activation" (recon case 15). The contract
;; names no mutator for a fiber's inject table; the port writes to the table
;; that fiber-inject returns, which is what `fiber.inject[name] = {}` does.
(test-case "case 15: dependencies added by an internal/plugin observer are honoured"
  (with-root (ctx)
    (ctx-provide ctx 'late-inject (hasheq))
    (define apply-calls 0)
    (define mutable-table? (box 'not-observed))
    (ctx-on ctx 'internal/plugin
            (lambda (fiber)
              (when (and (equal? (fiber-name fiber) "loader-shaped") (fiber-uid fiber))
                (define table (fiber-inject fiber))
                (set-box! mutable-table? (not (immutable? table)))
                (unless (immutable? table)
                  (hash-set! table 'late-inject (hasheq))))))
    (define f
      (ctx-plugin ctx (make-plugin (lambda (c config) (set! apply-calls (add1 apply-calls)) (void))
                                   #:name "loader-shaped")))
    (check-eq? (unbox mutable-table?) #t
               "fiber-inject must return the fiber's mutable inject table to observers")
    (await f)
    (check-equal? apply-calls 1)
    (check-eq? (fiber-state f) 'active)
    (check-true (hash-has-key? (fiber-inject f) 'late-inject))
    (check-true (and (fiber-committed f) (hash-has-key? (fiber-committed f) 'late-inject)))))

;; source: cordis-lifecycle.spec.ts "rolls back parent and runtime ownership
;; when internal/plugin publication throws" (recon case 16)
(test-case "case 16: a publication failure rolls back parent and registry ownership"
  (with-root (ctx)
    (define rf (context-fiber ctx))
    (define p (make-plugin (lambda (c config) (void)) #:name "publication-failure"))
    (ctx-on ctx 'internal/plugin
            (lambda (fiber)
              (when (and (equal? (fiber-name fiber) "publication-failure") (fiber-uid fiber))
                (raise-user-error "publication failed"))))
    (check-exn #rx"publication failed" (lambda () (ctx-plugin ctx p)))
    (check-true (yield-until (lambda () (not (member "ctx.plugin()" (labels-of rf))))))
    (check-equal? (filter (lambda (fiber) (eq? (fiber-plugin fiber) p)) (ctx-fibers ctx)) '())))

;; source: cordis-lifecycle.spec.ts "contains teardown notification failures
;; so ownership cleanup and peers complete" (recon case 17)
(test-case "case 17: a failing teardown observer is contained and logged once"
  (with-root (ctx)
    (define observed (make-recorder))
    (define (disposal-of-probe? fiber)
      (and (equal? (fiber-name fiber) "contained-teardown") (not (fiber-uid fiber))))
    (ctx-on ctx 'internal/plugin
            (lambda (fiber)
              (when (disposal-of-probe? fiber)
                (raise-user-error "broken teardown observer"))))
    (ctx-on ctx 'internal/plugin
            (lambda (fiber)
              (when (disposal-of-probe? fiber) (note! observed 'disposed))))
    (define child (ctx-plugin ctx (make-plugin (lambda (c config) (void))
                                               #:name "contained-teardown")))
    (await child)
    (define-values (result logs)
      (capture-log (lambda () (fiber-dispose! child)) #:level 'error #:topic 'cordis))
    (check-equal? result (void))
    (check-equal? (notes observed) '(disposed))
    (check-equal? (length logs) 1)
    (when (pair? logs)
      (define record (first logs))
      (define data (vector-ref record 2))
      (check-true (or (and (exn? data)
                           (regexp-match? #rx"broken teardown observer" (exn-message data)))
                      (regexp-match? #rx"broken teardown observer" (vector-ref record 1)))))
    (check-false (fiber-uid child))))

;; source: cordis-lifecycle.spec.ts "makes a LOADING parent join child cleanup
;; started before its unload snapshot" (recon case 18). The observer starts
;; both disposals as tasks and yields so that they reach their first wait
;; before ctx-plugin continues, as the synchronous part of dispose() does.
(test-case "case 18: a loading parent joins a child cleanup that started earlier"
  (with-root (ctx)
    (define sched (context-scheduler ctx))
    (define cleanup-gate (make-gate))
    (define cleanup-started (make-gate))
    (define owner-fiber (box #f))
    (define child-fiber (box #f))
    (define owner-disposal (box #f))
    (define child-disposal (box #f))
    (ctx-on ctx 'internal/plugin
            (lambda (fiber)
              (when (and (equal? (fiber-name fiber) "loading-child") (fiber-uid fiber))
                (set-box! child-fiber fiber)
                (ctx-effect (fiber-context fiber)
                            (lambda ()
                              (lambda ()
                                (gate-open! cleanup-started)
                                (gate-wait cleanup-gate)))
                            #:label "loading-child-cleanup")
                (set-box! owner-disposal
                          (spawn-task (lambda () (fiber-dispose! (unbox owner-fiber)))
                                      #:scheduler sched))
                (set-box! child-disposal
                          (spawn-task (lambda () (fiber-dispose! fiber)) #:scheduler sched))
                (yield-until (lambda () (not (fiber-uid fiber)))))))
    (define owner-mount
      (ctx-plugin ctx
                  (make-plugin (lambda (inner config)
                                 (set-box! owner-fiber (context-fiber inner))
                                 (ctx-plugin inner (make-plugin (lambda (c config) (void))
                                                                #:name "loading-child"))
                                 (void))
                               #:name "loading-owner")))
    (gate-wait cleanup-started)
    (yield-times 5)
    (check-false (task-done? (unbox owner-disposal)))
    (gate-open! cleanup-gate)
    (await-all (list (unbox owner-disposal) (unbox child-disposal)))
    (settle owner-mount)
    (check-false (fiber-uid (unbox child-fiber)))
    (check-false (fiber-uid (unbox owner-fiber)))
    (check-eq? (fiber-state owner-mount) 'disposed)))

;; source: cordis-lifecycle.spec.ts "lets parent disposal during
;; internal/plugin await the unpublished child to quiescence" (recon case 19)
(test-case "case 19: disposing the parent during publication drains the unpublished child"
  (with-root (ctx)
    (define sched (context-scheduler ctx))
    (define owner-ctx (box #f))
    (define owner
      (ctx-plugin ctx (make-plugin (lambda (inner config) (set-box! owner-ctx inner) (void))
                                   #:name "owner")))
    (await owner)
    (define cleanup-gate (make-gate))
    (define cleanup-started (make-gate))
    (define cleanup-finished? #f)
    (define child-apply-calls 0)
    (define parent-disposal (box #f))
    (define observed-state (box #f))
    (define (new-child? fiber)
      (and (equal? (fiber-name fiber) "child") (fiber-uid fiber)))
    (ctx-on ctx 'internal/plugin
            (lambda (fiber)
              (when (new-child? fiber)
                (set-box! observed-state (fiber-state fiber))
                (ctx-effect (fiber-context fiber)
                            (lambda ()
                              (lambda ()
                                (gate-open! cleanup-started)
                                (gate-wait cleanup-gate)
                                (set! cleanup-finished? #t)))
                            #:label "pending-child-cleanup"))))
    (ctx-on ctx 'internal/plugin
            (lambda (fiber)
              (when (new-child? fiber)
                (set-box! parent-disposal
                          (spawn-task (lambda () (fiber-dispose! owner)) #:scheduler sched))
                ;; Let the disposal reach its wait: the parent is then unloading.
                (yield-until (lambda () (eq? (fiber-state owner) 'unloading))))))
    (define child
      (ctx-plugin (unbox owner-ctx)
                  (make-plugin (lambda (c config)
                                 (set! child-apply-calls (add1 child-apply-calls))
                                 (void))
                               #:name "child")))
    (check-eq? (unbox observed-state) 'pending)
    (gate-wait cleanup-started)
    (yield-times 5)
    (check-false (task-done? (unbox parent-disposal)))
    (gate-open! cleanup-gate)
    (await (unbox parent-disposal))
    (check-true cleanup-finished?)
    (check-equal? child-apply-calls 0)
    (check-false (fiber-uid child))
    (check-eq? (fiber-state child) 'disposed)))

;; source: scripts/cordis-config-access.spec.ts "uses the canonical fiber
;; through registry wrappers and retains raw input without updating" (recon
;; case 21), reduced: ctx-plugin returns the canonical fiber, so only the
;; internal/config receiver and the restart re-resolution remain.
(test-case "case 21 (reduced): internal/config receives the fiber; restart resolves again"
  (with-root (ctx)
    (define initial (hasheq 'value 1))
    (define apply-calls 0)
    (define targets (make-recorder))
    (define f (ctx-plugin ctx
                          (lambda (c config) (set! apply-calls (add1 apply-calls)) (void))
                          initial))
    (await f)
    (ctx-on ctx 'internal/config
            (lambda (target next)
              (note! targets target)
              (next)))
    (check-eq? (context-fiber (fiber-context f)) f)
    (check-eq? (fiber-config f) initial)
    (check-eq? (fiber-effective-config f) initial)
    (check-equal? apply-calls 1)
    (fiber-restart! f)
    (check-equal? (notes targets) (list f))
    (check-eq? (fiber-effective-config f) initial)
    (check-equal? apply-calls 2)))

;; source: scripts/cordis-config-access.spec.ts "publishes updates through
;; registry wrappers to the canonical fiber" (recon case 22)
(test-case "case 22: an update reaches the body and publishes raw and effective config"
  (with-root (ctx)
    (define initial (hasheq 'value 1))
    (define calls (make-recorder))
    (define f (ctx-plugin ctx (lambda (c config) (note! calls (list c config)) (void)) initial))
    (await f)
    (define raw (hasheq 'value 2))
    (fiber-update! f raw)
    (fiber-await f)
    (check-equal? (length (notes calls)) 2)
    (define last-call (last (notes calls)))
    (check-eq? (first last-call) (fiber-context f))
    (check-eq? (second last-call) raw)
    (check-eq? (fiber-config f) raw)
    (check-eq? (fiber-effective-config f) raw)))

;; source: scripts/cordis-config-access.spec.ts "retains a pending raw update
;; until its injection is available" (recon case 23)
(test-case "case 23: a pending fiber retains a raw update until its injection arrives"
  (with-root (ctx)
    (define calls (make-recorder))
    (define f
      (ctx-plugin ctx
                  (make-plugin (lambda (c config) (note! calls config) (void))
                               #:inject '(config-access-test))
                  (hasheq 'value 1)))
    (define raw (hasheq 'value 2))
    (fiber-update! f raw)
    (check-eq? (fiber-config f) raw)
    (check-pred unset? (fiber-effective-config f))
    (check-eq? (fiber-state f) 'pending)
    (ctx-provide ctx 'config-access-test (hasheq))
    (await f)
    (check-eq? (fiber-effective-config f) raw)
    (check-equal? (length (notes calls)) 1)
    (check-eq? (first (notes calls)) raw)))
