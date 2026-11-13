#lang racket/base
;; Plugins and fibers: contract section 6, rules 1 to 9, plugin forms and config schemas.
(require rackunit
         racket/generator
         racket/list
         cordis
         cordis/plugin
         cordis/testing
         "common.rkt")

(define (labels f) (map disposer-label (fiber-effects f)))

;; Records every state change of fibers named `name` as (old . new).
(define (watch-status ctx name note)
  (ctx-on ctx 'internal/status
          (lambda (f old)
            (when (equal? (fiber-name f) name)
              (note (cons old (fiber-state f)))))))

;; ---------------------------------------------------------------------------------------
;; Plugin values

(test-case "make-plugin: accessors, defaults, and the plugin as a procedure"
  (define (body ctx config) (list ctx config))
  (define p (make-plugin body
                         #:name 'named
                         #:inject '(db "cache" (http . options))
                         #:config (lambda (raw) raw)
                         #:provides '("api")
                         #:meta (hasheq 'doc "text")))
  (check-true (plugin? p))
  (check-false (plugin? body))
  (check-equal? (plugin-name p) "named")
  (check-equal? (plugin-inject p) '(db cache (http . options)))
  (check-true (procedure? (plugin-config-schema p)))
  (check-equal? (plugin-provides p) '(api))
  (check-equal? (plugin-meta p) (hasheq 'doc "text"))
  (check-eq? (plugin-apply p) body)
  (check-equal? (plugin-custodian-mode p) 'own)
  (check-equal? (p 'ctx 'config) '(ctx config))
  (define q (make-plugin body #:inject (hash "db" 1)))
  (check-false (plugin-name q))
  (check-equal? (plugin-inject q) (hasheq 'db 1))
  (check-false (plugin-config-schema q))
  (check-equal? (plugin-provides q) '())
  (check-exn exn:fail:contract? (lambda () (make-plugin (lambda (ctx) ctx))))
  (check-exn exn:fail:contract? (lambda () (make-plugin body #:custodian 'shared))))

(test-case "names: the nearest named plugin up the chain, else root; uids increase"
  (with-root-context (ctx)
    (define inner #f)
    (define anonymous-inner #f)
    (define named
      (ctx-plugin ctx (make-plugin
                       (lambda (c config)
                         (set! anonymous-inner (ctx-plugin c (lambda (cc config) (void))))
                         (set! inner (ctx-plugin c (make-plugin (lambda (cc config) (void))
                                                                #:name "inner")))
                         (void))
                       #:name "outer")))
    (define anonymous (ctx-plugin ctx (lambda (c config) (void))))
    (define injected (ctx-inject ctx '() (lambda (c) (void))))
    (await/t named)
    (check-equal? (fiber-name named) "outer")
    (check-equal? (fiber-name anonymous-inner) "outer")
    (check-equal? (fiber-name inner) "inner")
    (check-equal? (fiber-name anonymous) "root")
    (check-equal? (fiber-name injected) "root")
    (check-equal? (map fiber-uid (list named anonymous injected anonymous-inner inner))
                  '(1 2 3 4 5))
    (check-equal? (ctx-fibers ctx) (list named anonymous injected anonymous-inner inner))
    (check-true (plugin? (fiber-plugin anonymous)))
    (check-eq? (fiber-parent named) ctx)
    (check-eq? (context-parent (fiber-context named)) ctx)
    (check-eq? (context-fiber (fiber-context named)) named)
    (check-eq? (fiber-parent inner) (fiber-context named))))

(test-case "registry: fibers of one body share the name and schema of its first registration"
  (with-root-context (ctx)
    (define (body c config) (void))
    (define first (ctx-plugin ctx (make-plugin body #:name "first-name")))
    (define second (ctx-plugin ctx (make-plugin body #:name "second-name")))
    (define bare (ctx-plugin ctx body))
    (check-equal? (map fiber-name (list first second bare))
                  '("first-name" "first-name" "first-name"))
    (await-all (list first second bare))
    (for-each fiber-dispose! (list first second bare))
    ;; the record is gone with its last fiber
    (define again (ctx-plugin ctx (make-plugin body #:name "second-name")))
    (check-equal? (fiber-name again) "second-name")))

;; ---------------------------------------------------------------------------------------
;; Rule 1

(test-case "rule 1: ctx-plugin returns at once; bodies run later, in start order"
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (define published '())
    (ctx-on ctx 'internal/plugin
            (lambda (f) (set! published (cons (list (fiber-state f) (fiber-uid f)) published))))
    (define a (ctx-plugin ctx (lambda (c config) (note 'a))))
    (define b (ctx-plugin ctx (lambda (c config) (note 'b))))
    (note 'after-plugin-calls)
    (check-equal? (reverse published) '((pending 1) (pending 2)))
    (check-eq? (fiber-state a) 'loading)
    (check-equal? (labels (context-fiber ctx))
                  '("ctx.on(\"internal/plugin\")" "ctx.plugin()" "ctx.plugin()"))
    (check-eq? (await/t a) a)
    (check-eq? (await/t b) b)
    (check-eq? (fiber-state a) 'active))
  (check-equal? (notes) '(after-plugin-calls a b)))

(test-case "rule 1: the body never runs when the fiber is disposed right away"
  (define ran? #f)
  (with-root-context (ctx)
    (define f (ctx-plugin ctx (lambda (c config) (set! ran? #t))))
    (fiber-dispose! f)
    (check-eq? (fiber-state f) 'disposed)
    (check-false (fiber-uid f))
    (check-equal? (ctx-fibers ctx) '())
    (check-exn exn:fail:cordis:inactive?
               (lambda () (ctx-plugin (fiber-context f) (lambda (c config) (void))))))
  (check-false ran?))

(test-case "rule 1: a throwing internal/plugin observer undoes the creation"
  (with-root-context (ctx)
    (define p (make-plugin (lambda (c config) (void)) #:name "unwanted"))
    (ctx-on ctx 'internal/plugin
            (lambda (f) (when (fiber-uid f) (raise-user-error "publication failed"))))
    (check-exn #rx"publication failed" (lambda () (ctx-plugin ctx p)))
    (check-not-false (wait-for (lambda () (equal? (labels (context-fiber ctx))
                                                 '("ctx.on(\"internal/plugin\")")))))
    (check-equal? (ctx-fibers ctx) '())))

(test-case "rule 1: no plugin under an unloading parent"
  (with-root-context (ctx)
    (define attempt #f)
    (define f
      (ctx-plugin ctx (lambda (c config)
                        (lambda ()
                          (set! attempt
                                (with-handlers ([exn:fail:cordis:inactive? (lambda (e) 'refused)])
                                  (ctx-plugin c (lambda (cc config) (void)))))))))
    (await/t f)
    (fiber-dispose! f)
    (check-equal? attempt 'refused)
    (check-equal? (ctx-fibers ctx) '())))

;; ---------------------------------------------------------------------------------------
;; Rules 2 and 5: targets and states

(test-case "rules 2, 5: state sequences for start, restart, dispose and failure"
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (watch-status ctx "watched" note)
    (define f (ctx-plugin ctx (make-plugin (lambda (c config) (void)) #:name "watched")))
    (await/t f)
    (check-equal? (notes) '((pending . loading) (loading . active)))
    (fiber-restart! f)
    (check-equal? (drop (notes) 2)
                  '((active . unloading) (unloading . loading) (loading . active)))
    (fiber-dispose! f)
    (check-equal? (drop (notes) 5) '((active . unloading) (unloading . disposed))))
  (define-values (note2 notes2) (make-recorder))
  (with-root-context (ctx)
    (watch-status ctx "watched" note2)
    (define f (ctx-plugin ctx (make-plugin (lambda (c config) (raise-user-error "body failed"))
                                           #:name "watched")))
    (check-exn #rx"body failed" (lambda () (await/t f)))
    (check-equal? (notes2) '((pending . loading) (loading . unloading) (unloading . failed)))))

(test-case "rule 2 / law 6: a fiber is active exactly while every injected name is provided"
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (define f (ctx-plugin ctx (make-plugin (lambda (c config)
                                             (note 'apply)
                                             (lambda () (note 'cleanup)))
                                           #:inject '(a b))))
    (check-eq? (fiber-state f) 'pending)
    (check-false (fiber-committed f))
    (check-eq? (await/t f) f)
    (define da (ctx-provide ctx 'a 1))
    (check-eq? (fiber-state f) 'pending)
    ;; a name the fiber does not inject changes nothing
    (ctx-provide ctx 'unrelated 0)
    (check-eq? (fiber-state f) 'pending)
    (define db (ctx-provide ctx 'b 2))
    (check-eq? (fiber-state f) 'loading)
    (check-equal? (fiber-committed f) (hasheq 'a 1 'b 2))
    (await/t f)
    (check-eq? (fiber-state f) 'active)
    (da)
    (check-eq? (fiber-state f) 'pending)
    (check-false (fiber-committed f))
    (set! da (ctx-provide ctx 'a 3))
    (await/t f)
    (check-eq? (fiber-state f) 'active)
    (check-equal? (fiber-committed f) (hasheq 'a 3 'b 2)))
  (check-equal? (notes) '(apply cleanup apply cleanup)))

(test-case "rule 2 / law 9: a target change during a transition is applied when it ends"
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (define g (gate))
    (define started (gate))
    (define d (ctx-provide ctx 'dep 1))
    (watch-status ctx "slow" note)
    (define f (ctx-plugin ctx (make-plugin (lambda (c config)
                                             (gate-open! started)
                                             (gate-wait g)
                                             (void))
                                           #:name "slow" #:inject '(dep))))
    (gate-wait started)
    ;; the dependency disappears and comes back while the body is still running; the
    ;; withdrawal itself waits for the dependent, so it runs in its own task
    (define withdrawal (spawn-task (lambda () (d))))
    (yield-task)
    (check-false (ctx-has? ctx 'dep))
    (check-eq? (fiber-state f) 'loading)
    (ctx-provide ctx 'dep 2)
    (check-eq? (fiber-state f) 'loading)
    (check-false (task-done? withdrawal))
    (gate-open! g)
    (await/t withdrawal)
    (await/t f)
    (check-eq? (fiber-state f) 'active)
    (check-equal? (fiber-committed f) (hasheq 'dep 2))
    ;; the superseded load is unloaded and a new one runs: no transition was interrupted
    (check-equal? (notes) '((pending . loading) (loading . unloading) (unloading . loading)
                            (loading . active)))))

;; ---------------------------------------------------------------------------------------
;; Rule 3: reload

(define (ctx-fibers-first ctx) (car (ctx-fibers ctx)))

(test-case "rule 3: body arguments, current-context, custodian, effective config"
  (with-root-context (ctx)
    (define seen #f)
    (define f (ctx-plugin ctx
                          (lambda (c config)
                            (set! seen (list (eq? c (current-context))
                                             (eq? (context-fiber c) (ctx-fibers-first ctx))
                                             (eq? (current-custodian) (context-custodian c))
                                             config
                                             (in-task? (context-scheduler c)))))
                          '(raw config)))
    (await/t f)
    (check-equal? seen '(#t #t #t (raw config) #t))
    (check-equal? (fiber-config f) '(raw config))
    (check-equal? (fiber-effective-config f) '(raw config))
    (check-false (fiber-error f))
    (check-false (eq? (fiber-custodian f) (context-custodian ctx)))))

(test-case "rule 3: the body's result is an effect result owned by the fiber"
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (define g (gate))
    (define f
      (ctx-plugin ctx (lambda (c config)
                        (ctx-on c 'event void)
                        (generator ()
                          (yield (lambda () (note 'yielded)))
                          (yield (spawn-task (lambda () (gate-wait g) (lambda () (note 'awaited)))))
                          (list (lambda () (note 'returned-1)) (lambda () (note 'returned-2)))))))
    (yield-task)
    (yield-task)
    ;; the fiber stays loading until the asynchronous result has settled
    (check-eq? (fiber-state f) 'loading)
    (gate-open! g)
    (await/t f)
    (check-eq? (fiber-state f) 'active)
    (check-equal? (labels f) '("ctx.on(\"event\")"))
    (fiber-dispose! f))
  ;; inverses of the body are top-level entries: started newest first
  (check-equal? (notes) '(returned-2 returned-1 awaited yielded)))

(test-case "rule 3: a body may return a disposer or a fiber it created"
  (with-root-context (ctx)
    (define child #f)
    (define f (ctx-plugin ctx (lambda (c config)
                                (ctx-on c 'event void)
                                (ctx-on c 'last-expression void))))
    (define g (ctx-plugin ctx (lambda (c config)
                                (set! child (ctx-plugin c (lambda (cc config) (void))))
                                child)))
    (await/t f)
    (await/t g)
    (check-eq? (fiber-state f) 'active)
    (check-eq? (fiber-state g) 'active)
    (check-eq? (fiber-state child) 'active)
    (check-equal? (labels f) '("ctx.on(\"event\")" "ctx.on(\"last-expression\")"))
    (fiber-dispose! f)
    (check-equal? (ctx-listeners ctx 'last-expression) '())))

(test-case "rule 3: an invalid body result fails the fiber"
  (with-root-context (ctx)
    (define f (ctx-plugin ctx (lambda (c config) 42)))
    (define-values (_ events)
      (capture-log (lambda () (check-exn exn:fail:contract? (lambda () (await/t f))))))
    (check-eq? (fiber-state f) 'failed)
    (check-equal? (length events) 1)))

(test-case "rule 3: a failing body is logged, recorded, and its effects are unloaded"
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (define f #f)
    (define-values (_ events)
      (capture-log
       (lambda ()
         (set! f (ctx-plugin ctx (make-plugin
                                  (lambda (c config)
                                    (ctx-effect c (lambda () (lambda () (note 'effect-cleaned))))
                                    (ctx-provide c 'half-made 1)
                                    (raise-user-error "body failed"))
                                  #:name "fragile")))
         (check-exn #rx"body failed" (lambda () (await/t f))))))
    (check-eq? (fiber-state f) 'failed)
    (check-pred exn:fail:user? (fiber-error f))
    (check-equal? (length events) 1)
    (check-regexp-match #rx"fragile.*body failed" (vector-ref (car events) 1))
    (check-eq? (vector-ref (car events) 2) (fiber-error f))
    (check-equal? (labels f) '())
    (check-false (ctx-has? ctx 'half-made))
    (check-not-false (fiber-uid f))
    ;; a raised value that is not an exception is wrapped
    (define g (ctx-plugin ctx (lambda (c config) (raise 'not-an-exception))))
    (check-exn #rx"not-an-exception" (lambda () (await/t g)))
    (check-pred exn:fail:cordis? (fiber-error g)))
  (check-equal? (notes) '(effect-cleaned)))

(test-case "rule 3: a failure of a superseded load does not fail the fiber"
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (define g (gate))
    (define started (gate))
    (define f (ctx-plugin ctx
                          (lambda (c config)
                            (note config)
                            (when (eqv? config 1)
                              (ctx-effect c (lambda () (lambda () (note 'cleanup-1))))
                              (gate-open! started)
                              (gate-wait g)
                              (raise-user-error "superseded failure")))
                          0))
    (await/t f)
    (define first-update (spawn-task (lambda () (fiber-update! f 1))))
    (gate-wait started)
    (define second-update (spawn-task (lambda () (fiber-update! f 2))))
    (yield-task)
    (gate-open! g)
    (await-all (list first-update second-update))
    (check-eq? (fiber-state f) 'active)
    (check-false (fiber-error f))
    (check-equal? (fiber-effective-config f) 2))
  (check-equal? (notes) '(0 1 cleanup-1 2)))

(test-case "rule 3 / law 14: each activation gets a fresh custodian, shut down at unload"
  (with-root-context (ctx)
    (define custodians '())
    (define threads '())
    (define ports '())
    (define f (ctx-plugin ctx (lambda (c config)
                                (set! custodians (cons (current-custodian) custodians))
                                ;; leaks: nothing here returns an inverse
                                (set! threads (cons (thread (lambda () (sync (make-semaphore 0))))
                                                    threads))
                                (define-values (in out) (make-pipe))
                                (set! ports (cons out ports))
                                (spawn-task (lambda () (await (make-semaphore 0))))
                                (void))))
    (await/t f)
    (check-eq? (fiber-custodian f) (car custodians))
    (check-false (thread-dead? (car threads)))
    (fiber-restart! f)
    (check-equal? (length custodians) 2)
    (check-false (eq? (first custodians) (second custodians)))
    (check-true (thread-dead? (second threads)))
    (check-true (custodian-shut-down? (second custodians)))
    (check-false (thread-dead? (first threads)))
    (fiber-dispose! f)
    (check-true (thread-dead? (first threads)))
    (check-true (custodian-shut-down? (first custodians)))))

(test-case "rule 3: custodian mode 'inherit uses the parent's custodian and shuts nothing down"
  (with-root-context (ctx)
    (define leaked #f)
    (define seen #f)
    (define f (ctx-plugin ctx (make-plugin (lambda (c config)
                                             (set! seen (current-custodian))
                                             (set! leaked (thread (lambda ()
                                                                    (sync (make-semaphore 0)))))
                                             (void))
                                           #:custodian 'inherit)))
    (await/t f)
    (check-eq? seen (context-custodian ctx))
    (check-eq? (fiber-custodian f) (context-custodian ctx))
    (fiber-dispose! f)
    (check-false (thread-dead? leaked))
    (kill-thread leaked)))

(test-case "a task that waits for its own fiber's unload is not killed by it"
  (with-root-context (ctx)
    (define restarter #f)
    (define activations 0)
    (define f (ctx-plugin ctx (lambda (c config)
                                (set! activations (add1 activations))
                                (when (= activations 1)
                                  ;; belongs to this activation's custodian
                                  (set! restarter
                                        (spawn-task (lambda ()
                                                      (fiber-restart! (context-fiber c))
                                                      'saw-the-restart))))
                                (void))))
    (check-not-false (wait-for (lambda () restarter)))
    (check-equal? (await/t restarter) 'saw-the-restart)
    (check-equal? activations 2)
    (check-eq? (fiber-state f) 'active)))

(test-case "a plugin body may dispose or restart its own fiber without waiting for itself"
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (define f (ctx-plugin ctx (lambda (c config)
                                (ctx-effect c (lambda () (lambda () (note 'cleaned))))
                                (fiber-dispose! (context-fiber c))
                                (note 'body-continues)
                                (void))))
    (await/t (wrap-evt f void))
    (check-eq? (fiber-state f) 'disposed)
    (check-equal? (map disposer-label (fiber-effects (context-fiber ctx))) '())
    (define runs 0)
    (define g (ctx-plugin ctx (lambda (c config)
                                (set! runs (add1 runs))
                                (when (= runs 1)
                                  (fiber-restart! (context-fiber c)))
                                (void))))
    (check-not-false (wait-for (lambda () (and (= runs 2) (eq? (fiber-state g) 'active))))))
  (check-equal? (notes) '(body-continues cleaned)))

;; ---------------------------------------------------------------------------------------
;; Rule 4: unload

(test-case "rule 4: top-level entries start newest first, each in its own task; all are awaited"
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (define g (gate))
    (define f
      (ctx-plugin ctx (lambda (c config)
                        (ctx-effect c (lambda () (lambda () (note 'e1))))
                        (ctx-effect c (lambda ()
                                        (lambda () (note 'e2-start) (gate-wait g) (note 'e2-end))))
                        (ctx-effect c (lambda () (lambda () (note 'e3))))
                        (lambda () (note 'returned)))))
    (await/t f)
    (define disposal (spawn-task (lambda () (fiber-dispose! f))))
    (check-not-false (wait-for (lambda () (member 'e1 (notes)))))
    (check-false (task-done? disposal))
    (check-equal? (notes) '(returned e3 e2-start e1))
    (gate-open! g)
    (await/t disposal)
    (check-eq? (fiber-state f) 'disposed))
  (check-equal? (notes) '(returned e3 e2-start e1 e2-end)))

(test-case "rule 4: a failing top-level entry is logged and does not stop the others"
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (define f
      (ctx-plugin ctx (make-plugin
                       (lambda (c config)
                         (ctx-effect c (lambda () (lambda () (note 'first))))
                         (ctx-effect c (lambda () (lambda () (raise-user-error "effect inverse"))))
                         (list (lambda () (raise-user-error "returned inverse"))
                               (lambda () (note 'last))))
                       #:name "leaky")))
    (await/t f)
    (define-values (_ events) (capture-log (lambda () (fiber-dispose! f))))
    (check-eq? (fiber-state f) 'disposed)
    (check-equal? (sort (for/list ([e (in-list events)]) (exn-message (vector-ref e 2))) string<?)
                  '("effect inverse" "returned inverse")))
  (check-equal? (notes) '(last first)))

(test-case "rule 4 / law 8: a provider unloads only after its dependents; they can read it"
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (define g (gate))
    (define started (gate))
    (define provider
      (ctx-plugin ctx (make-plugin (lambda (c config)
                                     (ctx-provide c 'db 'alive)
                                     (lambda () (note 'provider-cleanup)))
                                   #:name "provider")))
    (define consumer
      (ctx-plugin ctx (make-plugin (lambda (c config)
                                     (lambda ()
                                       (gate-open! started)
                                       (gate-wait g)
                                       (note (list 'consumer-cleanup (ctx-ref c 'db)))))
                                   #:name "consumer" #:inject '(db))))
    ;; a pending fiber has no transition to wait for: wait for the provider first
    (await/t provider)
    (await/t consumer)
    (check-eq? (fiber-state consumer) 'active)
    (define restart (spawn-task (lambda () (fiber-restart! provider))))
    (gate-wait started)
    ;; the provider is out of service at once, before any of its inverses run
    (check-eq? (fiber-state provider) 'unloading)
    (check-eq? (fiber-state consumer) 'unloading)
    (check-false (ctx-get ctx 'db))
    (check-equal? (notes) '())
    (gate-open! g)
    (await/t restart)
    (await/t consumer)
    (check-eq? (fiber-state consumer) 'active)
    (check-equal? (notes) '((consumer-cleanup alive) provider-cleanup))))

;; ---------------------------------------------------------------------------------------
;; Rule 5: notification on activation

(test-case "rule 5: entering and leaving 'active notifies for the fiber's services"
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (ctx-on ctx 'internal/service (lambda (name value) (note (list name value))))
    (define provider (ctx-plugin ctx (lambda (c config) (ctx-provide c 'db 'v) (void))))
    (check-equal? (notes) '())
    (await/t provider)
    (check-equal? (notes) '((db v)))
    (fiber-dispose! provider)
    ;; leaving 'active (value still stored), then the withdrawal
    (check-equal? (notes) '((db v) (db v) (db #f)))))

;; ---------------------------------------------------------------------------------------
;; Rule 6: disposal

(test-case "rule 6: disposal clears the uid, tells observers, and contains their failures"
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (define f (ctx-plugin ctx (make-plugin (lambda (c config) (void)) #:name "leaving")))
    (await/t f)
    (ctx-on ctx 'internal/plugin
            (lambda (fiber)
              (note (list 'first (fiber-uid fiber) (fiber-state fiber)))
              (raise-user-error "observer failed")))
    (ctx-on ctx 'internal/plugin (lambda (fiber) (note (list 'second (fiber-uid fiber)))))
    (define-values (_ events) (capture-log (lambda () (fiber-dispose! f))))
    (check-equal? (length events) 1)
    (check-regexp-match #rx"observer failed" (vector-ref (car events) 1))
    (check-eq? (fiber-state f) 'disposed)
    (check-false (fiber-uid f))
    (check-equal? (ctx-fibers ctx) '())
    ;; a second disposal is a no-op
    (check-equal? (fiber-dispose! f) (void))
    (check-exn exn:fail:cordis:inactive? (lambda () (fiber-restart! f)))
    (check-exn exn:fail:cordis:inactive? (lambda () (fiber-update! f 1))))
  (check-equal? (notes) '((first #f active) (second #f))))

(test-case "rule 6: effects registered while the fiber was pending are unloaded"
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (define f (ctx-plugin ctx (make-plugin (lambda (c config) (note 'never))
                                           #:inject '(missing))))
    (ctx-effect (fiber-context f) (lambda () (lambda () (note 'pending-effect))))
    (ctx-provide (fiber-context f) 'from-pending 1)
    (check-eq? (fiber-state f) 'pending)
    (fiber-dispose! f)
    (check-eq? (fiber-state f) 'disposed)
    (check-false (ctx-has? ctx 'from-pending)))
  (check-equal? (notes) '(pending-effect)))

(test-case "rule 6 / law 10: disposing a parent disposes children and grandchildren first"
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (define fibers '())
    (define (nested name . children)
      (make-plugin (lambda (c config)
                     (set! fibers (cons (context-fiber c) fibers))
                     (for ([child (in-list children)]) (ctx-plugin c child))
                     (lambda () (note name)))
                   #:name name))
    (define parent
      (ctx-plugin ctx (nested "parent"
                              (nested "child-1" (nested "grandchild"))
                              (nested "child-2"))))
    (check-not-false (wait-for (lambda () (= (length fibers) 4))))
    (await-all fibers)
    (fiber-dispose! parent)
    (check-true (andmap (lambda (f) (eq? (fiber-state f) 'disposed)) fibers))
    (check-equal? (ctx-fibers ctx) '()))
  (check-equal? (notes) '("parent" "child-2" "child-1" "grandchild"))
  (void))

;; ---------------------------------------------------------------------------------------
;; Rule 7: restart and update

(test-case "rule 7: restart unloads and reloads with the same raw config"
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (define f (ctx-plugin ctx (lambda (c config) (note config) (lambda () (note 'cleanup)))
                          'cfg))
    (await/t f)
    (check-equal? (fiber-restart! f) (void))
    (check-eq? (fiber-state f) 'active))
  (check-equal? (notes) '(cfg cleanup cfg cleanup)))

(test-case "rule 7: update validates, commits, stores, and restarts"
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (ctx-on ctx 'internal/commit (lambda (f raw) (note (list 'commit raw))))
    (define f (ctx-plugin ctx
                          (make-plugin (lambda (c config) (note (list 'apply config)))
                                       #:config (lambda (raw)
                                                  (unless (number? raw)
                                                    (raise-validation-error
                                                     '((() . "expected a number"))))
                                                  (* 2 raw)))
                          1))
    (await/t f)
    (check-equal? (fiber-effective-config f) 2)
    (check-equal? (fiber-update! f 5) (void))
    (check-equal? (fiber-config f) 5)
    (check-equal? (fiber-effective-config f) 10)
    ;; an invalid candidate raises and changes nothing
    (check-exn exn:fail:cordis:validation? (lambda () (fiber-update! f 'bad)))
    (check-equal? (fiber-config f) 5)
    (check-eq? (fiber-state f) 'active)
    ;; #:save? #f suppresses internal/commit
    (fiber-update! f 7 #:save? #f)
    (check-equal? (fiber-effective-config f) 14))
  (check-equal? (notes) '((apply 2) (commit 5) (apply 10) (apply 14))))

(test-case "rule 7: an update of a pending fiber only retains the raw config"
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (ctx-on ctx 'internal/commit (lambda (f raw) (note (list 'commit raw))))
    (define f (ctx-plugin ctx (make-plugin (lambda (c config) (note (list 'apply config)))
                                           #:inject '(missing))
                          'first))
    (fiber-update! f 'second)
    (check-equal? (fiber-config f) 'second)
    (check-false (fiber-effective-config f))
    (check-eq? (fiber-state f) 'pending)
    (ctx-provide ctx 'missing 1)
    (await/t f)
    (check-equal? (fiber-effective-config f) 'second))
  (check-equal? (notes) '((commit second) (apply second))))

(test-case "rule 7: a listener that does not call next keeps the instance"
  (define applies 0)
  (with-root-context (ctx)
    (define seen '())
    (define f (ctx-plugin ctx (lambda (c config) (set! applies (add1 applies)))
                          'initial))
    (await/t f)
    (ctx-on ctx 'internal/update
            (lambda (fiber resolved next)
              (set! seen (cons (list (eq? fiber f) resolved) seen))
              (if (eq? resolved 'restart-me) (next) 'kept))
            #:global? #t)
    (fiber-update! f 'keep-me)
    (check-equal? (fiber-effective-config f) 'keep-me)
    (check-equal? (fiber-config f) 'keep-me)
    (check-equal? applies 1)
    (fiber-update! f 'restart-me)
    (check-equal? applies 2)
    (check-equal? (fiber-effective-config f) 'restart-me)
    (check-equal? (reverse seen) '((#t keep-me) (#t restart-me)))))

(test-case "rule 7: a retained update is published only if nothing newer happened"
  (with-root-context (ctx)
    (define g (gate))
    (define started (gate))
    (define f (ctx-plugin ctx (lambda (c config)
                                (ctx-on c 'internal/update
                                        (lambda (fiber resolved next)
                                          (when (eqv? resolved 1)
                                            (gate-open! started)
                                            (gate-wait g))
                                          (when (eqv? resolved 3)
                                            (raise-user-error "listener rejected")))))
                          0))
    (await/t f)
    (define slow (spawn-task (lambda () (fiber-update! f 1))))
    (gate-wait started)
    (check-equal? (fiber-effective-config f) 0)
    (check-equal? (fiber-config f) 1)
    (fiber-update! f 2)
    (check-equal? (fiber-effective-config f) 2)
    (gate-open! g)
    (await/t slow)
    ;; the older update finished last and must not overwrite the newer one
    (check-equal? (fiber-effective-config f) 2)
    (check-exn #rx"listener rejected" (lambda () (fiber-update! f 3)))
    (check-equal? (fiber-config f) 3)
    (check-equal? (fiber-effective-config f) 2)))

;; ---------------------------------------------------------------------------------------
;; Rule 8: fiber-local update listeners

(test-case "rule 8: a non-global internal/update listener sees its own fiber only"
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (define (plugin name)
      (make-plugin (lambda (c config)
                     (ctx-on c 'internal/update
                             (lambda (fiber resolved next)
                               (note (list name 'local resolved))
                               (next)))
                     (void))
                   #:name name))
    (define a (ctx-plugin ctx (plugin "a")))
    (define b (ctx-plugin ctx (plugin "b")))
    (await-all (list a b))
    (check-equal? (labels a) '("ctx.on(\"internal/update\")"))
    (check-equal? (ctx-listeners ctx 'internal/update)
                  (ctx-listeners (fiber-context a) 'internal/update))
    (ctx-on ctx 'internal/update
            (lambda (fiber resolved next) (note (list 'global-late resolved)) (next))
            #:global? #t)
    (ctx-on ctx 'internal/update
            (lambda (fiber resolved next) (note (list 'global-first resolved)) (next))
            #:global? #t #:prepend? #t)
    (fiber-update! a 1)
    ;; the listener belongs to the activation: the restart removed and re-added it
    (fiber-update! b 2))
  (check-equal? (notes)
                '((global-first 1) ("a" local 1) (global-late 1)
                  (global-first 2) ("b" local 2) (global-late 2))))

;; ---------------------------------------------------------------------------------------
;; Rule 9: failure and recovery

(test-case "rule 9: a failed fiber recovers only through fiber-update!"
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (define dep (ctx-provide ctx 'dep 1))
    (define f (ctx-plugin ctx (make-plugin (lambda (c config)
                                             (note config)
                                             (when (eq? config 'bad)
                                               (raise-user-error "bad config")))
                                           #:inject '(dep))
                          'bad))
    (check-exn #rx"bad config" (lambda () (await/t f)))
    (check-eq? (fiber-state f) 'failed)
    ;; neither a dependency change nor a restart retries it
    (dep)
    (ctx-provide ctx 'dep 2)
    (yield-task)
    (check-eq? (fiber-state f) 'failed)
    (check-exn #rx"bad config" (lambda () (fiber-restart! f)))
    (check-eq? (fiber-state f) 'failed)
    (fiber-update! f 'good)
    (check-eq? (fiber-state f) 'active)
    (check-false (fiber-error f))
    (check-eq? (await/t f) f)
    ;; an update can fail again
    (check-exn #rx"bad config" (lambda () (fiber-update! f 'bad)))
    (check-eq? (fiber-state f) 'failed))
  (check-equal? (notes) '(bad good bad)))

;; ---------------------------------------------------------------------------------------
;; Fibers as events

(test-case "a fiber is an evt, ready when no transition is in flight"
  (define root (make-root-context))
  (define g (make-semaphore 0))
  (define f (ctx-plugin root (lambda (c config) (await g) (void))))
  (check-true (evt? f))
  (check-false (sync/timeout 0.02 f))
  (semaphore-post g)
  (check-eq? (sync/t f) f)
  (check-eq? (fiber-await f) f)
  (check-eq? (await f) f)
  (define failing (ctx-plugin root (lambda (c config) (raise-user-error "broken"))))
  ;; as an evt a failed fiber is just ready; fiber-await and await raise its error
  (check-eq? (sync/t failing) failing)
  (check-exn #rx"broken" (lambda () (fiber-await failing)))
  (check-exn #rx"broken" (lambda () (await failing)))
  (define pending (ctx-plugin root (make-plugin (lambda (c config) (void)) #:inject '(nothing))))
  (check-eq? (fiber-await pending) pending)
  (context-shutdown! root))

(test-case "fiber operations work from a thread that is not a task"
  (define-values (note notes) (make-recorder))
  (define root (make-root-context))
  (define f (ctx-plugin root (lambda (c config) (note config) (lambda () (note 'cleanup))) 1))
  (fiber-await f)
  (fiber-update! f 2)
  (fiber-restart! f)
  (fiber-dispose! f)
  (check-equal? (notes) '(1 cleanup 2 cleanup 2 cleanup))
  (context-shutdown! root))

;; ---------------------------------------------------------------------------------------
;; Config schemas

(struct range-schema (low high)
  #:property prop:config-schema
  (lambda (schema raw)
    (cond
      [(and (hash? raw) (real? (hash-ref raw 'port #f))
            (<= (range-schema-low schema) (hash-ref raw 'port) (range-schema-high schema)))
       (hash-set raw 'validated #t)]
      [else (raise-validation-error
             (list (cons '(server port) "expected a port in range")
                   (cons '() "invalid server section")))])))

(test-case "schemas: a struct with prop:config-schema validates; failures have issues"
  (with-root-context (ctx)
    (check-true (config-schema? (range-schema 1 2)))
    (define received #f)
    (define p (make-plugin (lambda (c config) (set! received config))
                           #:config (range-schema 1 1024)))
    (define f (ctx-plugin ctx p (hasheq 'port 80)))
    (await/t f)
    (check-equal? received (hasheq 'port 80 'validated #t))
    (check-equal? (fiber-config f) (hasheq 'port 80))
    (check-equal? (fiber-effective-config f) received)
    (define bad (ctx-plugin ctx p (hasheq 'port 99999)))
    (define e (with-handlers ([exn:fail:cordis:validation? values]) (await/t bad)))
    (check-eq? (fiber-state bad) 'failed)
    (check-pred exn:fail:cordis:validation? e)
    (check-equal? (exn-message e)
                  (string-append "invalid config:\n"
                                 "  - expected a port in range (at server.port)\n"
                                 "  - invalid server section"))
    (check-equal? (exn:fail:cordis:validation-issues e)
                  (list (cons '(server port) "expected a port in range")
                        (cons '() "invalid server section")))
    (check-pred exn:fail:cordis:validation? (make-validation-error '()))))

(test-case "schemas: internal/config listeners wrap validation; later ones are inner"
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (ctx-on ctx 'internal/config
            (lambda (fiber next)
              (define raw (next))
              (note (list 'inner raw))
              (if (number? raw) (add1 raw) raw)))
    (ctx-on ctx 'internal/config
            (lambda (fiber next)
              (define validated (next))
              (note (list 'outer validated))
              validated)
            #:prepend? #t)
    (define f (ctx-plugin ctx (make-plugin (lambda (c config) (note (list 'apply config)))
                                           #:config (lambda (raw) (* 10 raw)))
                          1))
    (await/t f))
  (check-equal? (notes) '((inner 1) (outer 20) (apply 20))))
