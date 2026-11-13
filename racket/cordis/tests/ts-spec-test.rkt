#lang racket/base
;; Ports of the kernel-level TypeScript specs that pin the vendored behaviour, numbered as
;; in docs/racket/recon/01-cordis-core.md ("Tests worth porting"), and tests of what the
;; port adds around them: breaks that reach a task inside a kernel operation.
;; source: scripts/cordis-core-lifecycle.spec.ts,
;;         packages/extensions/tool-cordis/tests/cordis-lifecycle.spec.ts,
;;         scripts/cordis-config-access.spec.ts
(require rackunit
         racket/generator
         racket/list
         cordis
         cordis/testing
         cordis/private/loader-support
         "common.rkt")

(define (labels f) (map disposer-label (fiber-effects f)))

;; ---------------------------------------------------------------------------------------
;; cordis-core-lifecycle.spec.ts

(define (latest-update-wins inject)
  (define-values (applied note-applied) (let-values ([(n ns) (make-recorder)]) (values ns n)))
  (define-values (cleaned note-cleaned) (let-values ([(n ns) (make-recorder)]) (values ns n)))
  (with-root-context (ctx)
    (when (pair? inject) (ctx-provide ctx (car inject) 'dependency))
    (define block (gate))
    (define blocked (gate))
    (define f
      (ctx-plugin ctx
                  (make-plugin (lambda (c config)
                                 (define value (hash-ref config 'value))
                                 (note-applied value)
                                 (ctx-effect c (lambda () (lambda () (note-cleaned value))))
                                 (when (= value 1)
                                   (gate-open! blocked)
                                   (gate-wait block)))
                               #:inject inject)
                  (hasheq 'value 0)))
    (await/t f)
    (define updates (list (spawn-task (lambda () (fiber-update! f (hasheq 'value 1))))))
    (gate-wait blocked)
    (check-eq? (fiber-state f) 'loading)
    ;; two more updates arrive while the activation for value 1 is still loading
    (set! updates (append updates
                          (list (spawn-task (lambda () (fiber-update! f (hasheq 'value 2))))
                                (spawn-task (lambda () (fiber-update! f (hasheq 'value 3)))))))
    (yield-task)
    (yield-task)
    (gate-open! block)
    (await-all updates)
    (check-equal? (applied) '(0 1 3))
    (check-equal? (cleaned) '(0 1))
    (check-eq? (fiber-state f) 'active)
    (check-equal? (fiber-effective-config f) (hasheq 'value 3))
    (fiber-dispose! f)
    (check-equal? (cleaned) '(0 1 3))))

(test-case "case 1: the latest update wins while loading"
  (latest-update-wins '()))

(test-case "case 1: the latest update wins while loading, with an injection"
  (latest-update-wins '(dependency)))

(define (providers-outlive-dependents stop!)
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (define scope (context-isolate ctx 'service))
    (define alive? #f)
    (define release (gate))
    (define cleaning (gate))
    (define provider
      (ctx-plugin scope (lambda (c config)
                          (set! alive? #t)
                          (ctx-provide c 'service 'value)
                          (ctx-effect c (lambda ()
                                          (lambda () (set! alive? #f) (note 'provider)))))))
    (define consumer
      (ctx-plugin scope (make-plugin
                         (lambda (c config)
                           (ctx-effect c (lambda ()
                                           (lambda ()
                                             (gate-open! cleaning)
                                             (gate-wait release)
                                             (check-true alive?)
                                             (check-equal? (ctx-ref c 'service) 'value)
                                             (note 'consumer)))))
                         #:inject '(service))))
    (await/t provider)
    (await/t consumer)
    (define stopping (spawn-task (lambda () (stop! provider))))
    (gate-wait cleaning)
    (yield-task)
    (yield-task)
    ;; nothing is cleaned until the dependent's disposer is released
    (check-equal? (notes) '())
    (check-true alive?)
    (gate-open! release)
    (await/t stopping)
    (check-equal? (take (notes) 2) '(consumer provider))))

(test-case "case 3: providers outlive dependent teardown on dispose"
  (providers-outlive-dependents fiber-dispose!))

(test-case "case 3: providers outlive dependent teardown on restart"
  (providers-outlive-dependents fiber-restart!))

(test-case "case 4: an own isolated provision is separate from a committed injection"
  (with-root-context (ctx)
    (define outer (ctx-provide ctx 'value 'outer))
    (define plugin-ctx #f)
    (define isolated #f)
    (define child-ctx #f)
    (define inner #f)
    (define f
      (ctx-plugin ctx (make-plugin
                       (lambda (c config)
                         (set! plugin-ctx c)
                         (set! isolated (context-isolate c 'value))
                         (set! inner (ctx-provide isolated 'value 'inner))
                         (ctx-plugin isolated (lambda (cc config) (set! child-ctx cc) (void)))
                         (void))
                       #:inject '(value))))
    (await/t f)
    (check-not-false (wait-for (lambda () child-ctx)))
    (check-equal? (ctx-ref plugin-ctx 'value) 'outer)
    (check-equal? (ctx-ref isolated 'value) 'inner)
    (check-equal? (ctx-ref child-ctx 'value) 'inner)
    ;; once the provision is withdrawn, the isolated context has no implementation; the
    ;; fiber's committed view of its injection is all that is left
    (inner)
    (check-equal? (ctx-ref plugin-ctx 'value) 'outer)
    (check-equal? (ctx-ref isolated 'value) 'outer)
    (check-equal? (ctx-ref child-ctx 'value) 'outer)
    ;; a name provided only under an isolated context is not readable from the own context
    (define own-ctx #f)
    (define g (ctx-plugin ctx (lambda (c config)
                                (set! own-ctx c)
                                (ctx-provide (context-isolate c 'private) 'private 1)
                                (void))))
    (await/t g)
    (check-exn-message exn:fail:cordis:inject? #rx"cannot get property \"private\" without inject"
                       (lambda () (ctx-ref own-ctx 'private)))))

;; A plugin whose own internal/update listener keeps the instance and waits on `hold`.
(define (retaining-plugin received hold held)
  (lambda (c config)
    (set-box! received config)
    (ctx-on c 'internal/update
            (lambda (fiber resolved next)
              (gate-open! held)
              (gate-wait hold)
              'retained))
    (void)))

;; `internal/config` listener that makes every resolution a fresh object.
(define (copy-config! ctx)
  (ctx-on ctx 'internal/config (lambda (fiber next) (hash-copy (next)))))

(test-case "case 6: no publication after raw retention"
  (with-root-context (ctx)
    (copy-config! ctx)
    (define received (box #f))
    (define hold (gate))
    (define held (gate))
    (define f (ctx-plugin ctx (retaining-plugin received hold held) (make-hasheq '((v . 0)))))
    (await/t f)
    (define update (spawn-task (lambda () (fiber-update! f (make-hasheq '((v . 1)))))))
    (gate-wait held)
    (fiber-set-raw-config! f (make-hasheq '((v . 2))))
    (gate-open! hold)
    (await/t update)
    (check-eq? (fiber-effective-config f) (unbox received))
    (check-equal? (hash-ref (fiber-effective-config f) 'v) 0)
    (check-equal? (hash-ref (fiber-config f) 'v) 2)))

(test-case "case 6: no publication after a restart"
  (with-root-context (ctx)
    (copy-config! ctx)
    (define received (box #f))
    (define hold (gate))
    (define held (gate))
    (define f (ctx-plugin ctx (retaining-plugin received hold held) (make-hasheq '((v . 0)))))
    (await/t f)
    (define update (spawn-task (lambda () (fiber-update! f (make-hasheq '((v . 1)))))))
    (gate-wait held)
    (fiber-restart! f)
    (define after-restart (unbox received))
    (check-equal? (hash-ref after-restart 'v) 1)
    (gate-open! hold)
    (await/t update)
    (check-eq? (fiber-effective-config f) after-restart)))

(test-case "case 6: no publication after disposal"
  (with-root-context (ctx)
    (copy-config! ctx)
    (define received (box #f))
    (define hold (gate))
    (define held (gate))
    (define f (ctx-plugin ctx (retaining-plugin received hold held) (make-hasheq '((v . 0)))))
    (await/t f)
    (define update (spawn-task (lambda () (fiber-update! f (make-hasheq '((v . 1)))))))
    (gate-wait held)
    (fiber-dispose! f)
    (gate-open! hold)
    (await/t update)
    (check-eq? (fiber-effective-config f) (unbox received))
    (check-equal? (hash-ref (fiber-effective-config f) 'v) 0)))

(test-case "case 7: a delegating listener keeps the identity the restart produced"
  (with-root-context (ctx)
    (copy-config! ctx)
    (define received (box #f))
    (define f (ctx-plugin ctx (lambda (c config)
                                (set-box! received config)
                                (ctx-on c 'internal/update
                                        (lambda (fiber resolved next) (next)))
                                (void))
                          (make-hasheq '((v . 0)))))
    (await/t f)
    (fiber-update! f (make-hasheq '((v . 1))))
    (check-equal? (hash-ref (unbox received) 'v) 1)
    (check-eq? (fiber-effective-config f) (unbox received))))

;; ---------------------------------------------------------------------------------------
;; cordis-lifecycle.spec.ts (lifecycle hardening)

(test-case "case 9: a restart started inside setup waits for setup and for cleanup"
  (with-root-context (ctx)
    (define rf (context-fiber ctx))
    (define setup (gate))
    (define cleanup (gate))
    (define cleaning (gate))
    (define restart #f)
    (ctx-effect ctx (lambda ()
                      (set! restart (spawn-task (lambda () (fiber-restart! rf))))
                      (spawn-task (lambda ()
                                    (gate-wait setup)
                                    (lambda () (gate-open! cleaning) (gate-wait cleanup))))))
    (yield-task)
    (yield-task)
    (check-false (task-done? restart))
    (check-eq? (fiber-state rf) 'unloading)
    (gate-open! setup)
    (gate-wait cleaning)
    (check-false (task-done? restart))
    (gate-open! cleanup)
    (await/t restart)
    (check-equal? (fiber-effects rf) '())
    (check-eq? (fiber-state rf) 'active)))

(test-case "case 11: a restart started inside a failing setup waits for the rollback"
  (with-root-context (ctx)
    (define rf (context-fiber ctx))
    (define cleanup (gate))
    (define cleaning (gate))
    (define restart #f)
    (define creation
      (spawn-task
       (lambda ()
         (ctx-effect ctx (lambda ()
                           (generator ()
                             (yield (lambda () (gate-open! cleaning) (gate-wait cleanup)))
                             (set! restart (spawn-task (lambda () (fiber-restart! rf))))
                             (raise-user-error "setup failed")))))))
    (gate-wait cleaning)
    (yield-task)
    (check-false (task-done? restart))
    (gate-open! cleanup)
    (check-exn #rx"setup failed" (lambda () (await/t creation)))
    (await/t restart)
    (check-equal? (fiber-effects rf) '())
    (check-eq? (fiber-state rf) 'active)))

(test-case "case 13: registration from a cleanup during a restart is refused"
  (with-root-context (ctx)
    (define rf (context-fiber ctx))
    (define refusal #f)
    (ctx-effect ctx (lambda ()
                      (lambda ()
                        (set! refusal (with-handlers ([exn:fail:cordis:inactive? values])
                                        (ctx-effect ctx void))))))
    (fiber-restart! rf)
    (check-pred exn:fail:cordis:inactive? refusal)
    (check-eq? (fiber-state rf) 'active)
    (check-equal? (fiber-effects rf) '())))

(test-case "case 15: dependencies added by an internal/plugin observer are honoured"
  (with-root-context (ctx)
    (ctx-provide ctx 'late-dependency 'value)
    (define applies 0)
    (ctx-on ctx 'internal/plugin
            (lambda (f)
              (when (and (fiber-uid f) (equal? (fiber-name f) "extended"))
                (hash-set! (fiber-inject f) 'late-dependency #f))))
    (define f (ctx-plugin ctx (make-plugin (lambda (c config) (set! applies (add1 applies)))
                                           #:name "extended")))
    (await/t f)
    (check-equal? applies 1)
    (check-eq? (fiber-state f) 'active)
    (check-equal? (fiber-committed f) (hasheq 'late-dependency 'value))
    ;; and a dependency that is missing keeps the fiber pending
    (ctx-on ctx 'internal/plugin
            (lambda (f)
              (when (and (fiber-uid f) (equal? (fiber-name f) "waiting"))
                (fiber-add-inject! f 'never-provided))))
    (define g (ctx-plugin ctx (make-plugin (lambda (c config) (void)) #:name "waiting")))
    (yield-task)
    (check-eq? (fiber-state g) 'pending)))

(test-case "case 18: a loading parent joins a child cleanup that started earlier"
  (with-root-context (ctx)
    (define cleanup (gate))
    (define cleaning (gate))
    (define parent #f)
    (define child #f)
    (define disposals '())
    (ctx-on ctx 'internal/plugin
            (lambda (f)
              (when (and (fiber-uid f) (equal? (fiber-name f) "child"))
                (set! child f)
                (ctx-effect (fiber-context f)
                            (lambda () (lambda () (gate-open! cleaning) (gate-wait cleanup))))
                (set! disposals
                      (list (spawn-task (lambda () (fiber-dispose! parent)))
                            (spawn-task (lambda () (fiber-dispose! f))))))))
    (define mounted
      (ctx-plugin ctx (make-plugin (lambda (c config)
                                     (set! parent (context-fiber c))
                                     (ctx-plugin c (make-plugin (lambda (cc config) (void))
                                                                #:name "child"))
                                     (void))
                                   #:name "parent")))
    (gate-wait cleaning)
    (yield-task)
    (yield-task)
    (check-false (task-done? (car disposals)))
    (gate-open! cleanup)
    (await-all disposals)
    (check-false (fiber-uid child))
    (check-false (fiber-uid parent))
    (check-eq? (fiber-state mounted) 'disposed)
    (check-eq? (fiber-state child) 'disposed)))

(test-case "case 19: disposing the parent during publication drains the unpublished child"
  (with-root-context (ctx)
    (define cleanup (gate))
    (define cleaning (gate))
    (define parent-ctx #f)
    (define parent (ctx-plugin ctx (lambda (c config) (set! parent-ctx c) (void))))
    (await/t parent)
    (define child-ran? #f)
    (define disposal #f)
    (ctx-on ctx 'internal/plugin
            (lambda (f)
              (when (and (fiber-uid f) (equal? (fiber-name f) "unpublished"))
                (ctx-effect (fiber-context f)
                            (lambda () (lambda () (gate-open! cleaning) (gate-wait cleanup)))))))
    (ctx-on ctx 'internal/plugin
            (lambda (f)
              (when (and (fiber-uid f) (equal? (fiber-name f) "unpublished"))
                (set! disposal (spawn-task (lambda () (fiber-dispose! parent))))
                ;; let the disposal reach the child before publication continues
                (gate-wait cleaning))))
    (define child (ctx-plugin parent-ctx (make-plugin (lambda (c config) (set! child-ran? #t))
                                                      #:name "unpublished")))
    (check-false (fiber-uid child))
    (yield-task)
    (check-false (task-done? disposal))
    (gate-open! cleanup)
    (await/t disposal)
    (check-false child-ran?)
    (check-eq? (fiber-state child) 'disposed)
    (check-eq? (fiber-state parent) 'disposed)))

;; ---------------------------------------------------------------------------------------
;; cordis-config-access.spec.ts

(test-case "case 21: retaining raw config does not update; resolution is pure"
  (with-root-context (ctx)
    (define applies 0)
    (define resolutions '())
    (ctx-on ctx 'internal/config
            (lambda (fiber next)
              (set! resolutions (cons fiber resolutions))
              (next)))
    (define initial (hasheq 'v 0))
    (define raw (hasheq 'v 1))
    (define f (ctx-plugin ctx (lambda (c config) (set! applies (add1 applies))) initial))
    (await/t f)
    (set! resolutions '())
    (fiber-set-raw-config! f raw)
    (check-eq? (fiber-config f) raw)
    (check-eq? (fiber-effective-config f) initial)
    (check-eq? (fiber-resolve-config f raw) raw)
    (check-equal? resolutions (list f))
    (check-equal? applies 1)
    (fiber-restart! f)
    (check-eq? (fiber-effective-config f) raw)
    (check-equal? applies 2)))

(test-case "case 22: an update reaches the body and both configs"
  (with-root-context (ctx)
    (define calls '())
    (define raw (hasheq 'v 1))
    (define f (ctx-plugin ctx (lambda (c config) (set! calls (cons (list c config) calls)))
                          (hasheq 'v 0)))
    (await/t f)
    (fiber-update! f raw)
    (check-eq? (first (car calls)) (fiber-context f))
    (check-eq? (second (car calls)) raw)
    (check-eq? (fiber-config f) raw)
    (check-eq? (fiber-effective-config f) raw)))

;; ---------------------------------------------------------------------------------------
;; Breaks inside kernel operations

(test-case "break: a caller broken while it waits for a disposal leaves the disposal to finish"
  (with-root-context (ctx)
    (define cleanup (gate))
    (define cleaning (gate))
    (define f (ctx-plugin ctx (lambda (c config)
                                (lambda () (gate-open! cleaning) (gate-wait cleanup)))))
    (await/t f)
    (define caller (spawn-task (lambda () (fiber-dispose! f))))
    (gate-wait cleaning)
    (task-cancel! caller)
    (check-exn exn:break? (lambda () (await/t caller)))
    (check-eq? (fiber-state f) 'unloading)
    (gate-open! cleanup)
    (await/t (wrap-evt f void))
    (check-eq? (fiber-state f) 'disposed)
    (check-not-false (wait-for (lambda () (null? (labels (context-fiber ctx))))))
    (check-equal? (fiber-dispose! f) (void))))

(test-case "break: a broken thread outside the kernel cancels the operation it started"
  (define-values (note notes) (make-recorder))
  (define root (make-root-context))
  (define listening (make-semaphore 0))
  (ctx-on root 'slow
          (lambda ()
            (with-handlers ([exn:break? (lambda (e) (note 'listener-broken) (raise e))])
              (semaphore-post listening)
              (await (make-semaphore 0)))))
  (define outcome (make-channel))
  (define caller
    (thread (lambda ()
              (channel-put outcome
                           (with-handlers ([exn:break? (lambda (e) 'caller-broken)])
                             (ctx-emit root 'slow)
                             'returned)))))
  (sync/t listening)
  (break-thread caller)
  (check-equal? (sync/t outcome) 'caller-broken)
  (check-not-false (wait-for (lambda () (equal? (notes) '(listener-broken)))))
  ;; the kernel is still in order
  (check-equal? (ctx-bail root 'nobody-listens) (void))
  (context-shutdown! root))

(test-case "break: a break never leaves a registration half made"
  ;; The break may arrive anywhere in the worker. User code between two kernel calls can be
  ;; interrupted, so an effect may be left registered; but whatever is in a kernel table is
  ;; then also owned by the root fiber, and disposing what the fiber owns restores the kernel.
  (with-root-context (ctx)
    (define rf (context-fiber ctx))
    (for ([round (in-range 40)])
      (check-kernel-restored
       (lambda ()
         (define started (gate))
         (define worker
           (spawn-task
            (lambda ()
              (gate-open! started)
              (let loop ([n 0])
                (define d (ctx-effect ctx (lambda ()
                                            (list (ctx-on ctx 'event void)
                                                  (ctx-provide ctx 'service n)
                                                  (ctx-accessor ctx 'shortcut #:get void)))))
                (d)
                (when (zero? (modulo n 7)) (yield-task))
                (loop (add1 n))))))
         (gate-wait started)
         (for ([n (in-range (modulo round 6))]) (yield-task))
         (task-cancel! worker)
         (check-exn exn:break? (lambda () (await/t worker)))
         (for ([d (in-list (fiber-effects rf))]) (d)))
       ctx))))
