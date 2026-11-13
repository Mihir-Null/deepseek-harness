#lang racket/base
;; Plugin fibers: creation, the inertial state machine, dependency tracking, disposal,
;; restart and config update (contract section 6; vendor/cordis/src/fiber.ts, registry.ts
;; and `notify` in reflect.ts).
;;
;; A transition (reload or unload) is a kernel task stored in the fiber's `inertia` field.
;; Once started it runs to completion; a target that changes meanwhile is acted on when the
;; transition ends, by chaining into the next one. The part of a transition that the
;; TypeScript runs before its first `await` runs here in the task that triggers it.
(require racket/list
         "scheduler.rkt"
         "breaks.rkt"
         "errors.rkt"
         "core.rkt"
         "effect.rkt"
         "events.rkt"
         "dlist.rkt")

(provide get-impl check-impl! refresh! recheck! notify!
         ctx-plugin ctx-inject normalize-inject
         fiber-inject fiber-committed fiber-provisions fiber-config fiber-effective-config
         fiber-error fiber-context fiber-parent
         fiber-dispose! fiber-restart! fiber-update! fiber-resolve-config ctx-fibers
         make-root-fiber install-config-hook!)

;; ---------------------------------------------------------------------------------------
;; Public views of a fiber

;; The fiber's inject table itself: an `internal/plugin` observer adds a dependency by
;; storing a key in it before the fiber's dependencies are resolved.
(define (fiber-inject f)
  (fiber-inject-table f))

(define (fiber-committed f)
  (define c (fiber-commit f))
  (and c (for/hasheq ([(key i) (in-hash c)]) (values key (impl-value i)))))

(define (fiber-provisions f)
  (map impl-key (fiber-provided f)))

(define (fiber-config f) (fiber-raw-config f))
(define (fiber-effective-config f) (fiber-effective f))
(define (fiber-error f) (fiber-failure f))
(define (fiber-context f) (fiber-ctx f))
(define (fiber-parent f) (fiber-parent-ctx f))

;; Live plugin fibers in creation order.
(define (ctx-fibers ctx)
  (define k (context-kernel ctx))
  (sort (for*/list ([rt (in-list (dlist->list (kernel-runtime-order k)))]
                    [f (in-list (dlist->list (runtime-fibers rt)))])
          f)
        < #:key fiber-seq))

;; ---------------------------------------------------------------------------------------
;; Dependency tracking

;; The implementation of `key` in the realm `key` has in `ctx`. With `strict?`, only when
;; the providing fiber is active.
(define (get-impl ctx key strict?)
  (define realm (context-realm ctx key))
  (define i (and realm (hash-ref (kernel-store (context-kernel ctx)) realm #f)))
  (and i
       (or (not strict?)
           (eq? (fiber-state (context-fiber (impl-ctx i))) 'active))
       i))

;; Records whether `key` is available to `f` now: an active provider in f's realm whose
;; check accepts f's context. A check that raises counts as a rejection and is logged.
(define (check-impl! f key)
  (define i (get-impl (fiber-ctx f) key #t))
  (define ok?
    (and i
         (or (not (impl-check i))
             ;; the check runs with breaks off: it is consulted in the middle of a
             ;; notification that must reach every dependent
             (with-handlers ([(lambda (e) #t)
                              (lambda (e)
                                (contain e (lambda (e)
                                             (log-fiber-error (context-fiber (impl-ctx i)) e)))
                                #f)])
               (and ((impl-check i) (fiber-ctx f)) #t)))))
  (set-fiber-available!
   f (if ok?
         (hash-set (fiber-available f) key i)
         (hash-remove (fiber-available f) key))))

;; Recomputes the target: #f when an injected key is unavailable, else the revision
;; followed by the uid of each key's provider in inject order.
(define (refresh! f)
  (set-target!
   f
   (let loop ([keys (fiber-inject-keys f)] [uids '()])
     (cond
       [(null? keys) (cons (fiber-revision f) (reverse uids))]
       [(hash-ref (fiber-available f) (car keys) #f)
        => (lambda (i) (loop (cdr keys) (cons (impl-uid i) uids)))]
       [else #f]))))

;; Re-checks every injected key, then refreshes.
(define (recheck! f)
  (for ([key (in-list (fiber-inject-keys f))])
    (check-impl! f key))
  (refresh! f))

;; Notification for `keys` from `ctx`. `accept?` : (-> context? symbol? any/c) selects the
;; contexts concerned; by default those that map the key to the realm it has in `ctx`.
(define (notify! ctx keys [accept? #f])
  (define k (context-kernel ctx))
  (define (concerned? c key)
    (if accept?
        (accept? c key)
        (eq? (context-realm c key) (context-realm ctx key))))
  (for* ([rt (in-list (dlist->list (kernel-runtime-order k)))]
         [f (in-list (dlist->list (runtime-fibers rt)))])
    ;; a fiber disposed by an earlier step of this notification is skipped
    (when (fiber-uid f)
      (define updated?
        (for/fold ([updated? #f]) ([key (in-list keys)])
          (cond
            [(and (fiber-injects? f key) (concerned? (fiber-ctx f) key))
             (check-impl! f key)
             #t]
            [else updated?])))
      (when updated? (refresh! f))))
  (for ([key (in-list keys)])
    (define i (get-impl ctx key #f))
    (dispatch-emit ctx 'internal/service (list key (and i (impl-value i)))
                   #:filter (lambda (c) (concerned? c key))
                   #:atomic? #t)))

;; ---------------------------------------------------------------------------------------
;; State machine

(define (stable-state f)
  (cond
    [(not (fiber-uid f)) 'disposed]
    [(fiber-failure f) 'failed]
    [(fiber-target f) 'active]
    [else 'pending]))

;; `change` may start a transition and return its state; when it returns #f the fiber takes
;; its stable state. A change into or out of 'active notifies for the fiber's services.
(define (update-state! f change)
  (define old (fiber-state f))
  (define new (or (change) (stable-state f)))
  (set-fiber-state! f new)
  (unless (eq? old new)
    (dispatch-emit (fiber-ctx f) 'internal/status (list f old) #:atomic? #t)
    (when (or (eq? old 'active) (eq? new 'active))
      (define store (kernel-store (fiber-kernel f)))
      (for ([i (in-list (fiber-provided f))])
        (when (eq? (hash-ref store (impl-realm i) #f) i)
          (notify! (context-isolate (impl-ctx i) (impl-key i) (impl-realm i))
                   (list (impl-key i))))))))

(define (set-target! f target)
  (define old (fiber-target f))
  (unless (equal? target old)
    ;; a failed fiber recovers only through fiber-update!, which clears the failure
    (unless (fiber-failure f)
      (set-fiber-target! f target)
      (unless (fiber-inertia f)
        (update-state! f (lambda ()
                           (cond
                             [(and target (not old)) (start-reload! f) 'loading]
                             [else (start-unload! f) 'unloading])))))))

(define (spawn-transition! f name body)
  (define t
    (spawn-kernel-task
     (fiber-kernel f)
     (lambda ()
       (critical
        (with-handlers ([(lambda (e) #t)
                         (lambda (e)
                           (log-fiber-error f e)
                           ;; never leave the fiber waiting for a transition that is gone
                           (when (eq? (fiber-inertia f) (current-task))
                             (set-inertia! f #f)))])
          (body))))
     #:name name))
  (set-inertia! f t))

(define (make-activation-custodian f)
  (define pctx (fiber-parent-ctx f))
  (define parent
    (if pctx
        (fiber-custodian (context-fiber pctx))
        (kernel-custodian (fiber-kernel f))))
  (set-fiber-custodian-parent! f parent)
  ;; a parent that was already shut down stands in for the child's custodian
  (with-handlers ([exn:fail? (lambda (e) parent)])
    (make-custodian parent)))

;; Ends the activation's custodian. A task that belongs to it and waits for this fiber, or
;; for a fiber up the chain whose teardown this unload is part of, is first handed to the
;; parent custodian: it waits for the outcome of the unload and gets to see it.
(define (shutdown-activation-custodian! f)
  (define c (fiber-own-custodian f))
  (when c
    (define home (fiber-custodian-parent f))
    (unless (or (custodian-shut-down? c) (custodian-shut-down? home))
      (define managed #f)
      ;; this fiber, then each fiber up the chain of creating contexts
      (let loop ([a f])
        (define waiting (fiber-waiting a))
        (for ([th (in-list (hash-keys waiting))])
          (cond
            [(thread-dead? th) (hash-remove! waiting th)]
            [else
             (unless managed
               (set! managed (custodian-managed-list c (kernel-custodian (fiber-kernel f)))))
             (when (memq th managed)
               (thread-resume th home))]))
        (define pctx (fiber-parent-ctx a))
        (when pctx
          (define pf (context-fiber pctx))
          (unless (eq? pf a) (loop pf)))))
    (custodian-shutdown-all c)
    (when (fiber-uid f)
      (set-fiber-own-custodian! f (make-activation-custodian f)))))

;; Reload. Runs in the triggering task up to the point where the body would start: the
;; providers are committed and learn of their new dependent at once.
(define (start-reload! f)
  (define commit (fiber-available f))
  (set-fiber-commit! f commit)
  (set-fiber-activation! f (add1 (fiber-activation f)))
  (for ([(key i) (in-hash commit)])
    (unless (eq? (context-fiber (impl-ctx i)) f)
      (hash-set! (impl-dependents i) f #t)))
  (define target (fiber-target f))
  (spawn-transition! f 'reload (lambda () (reload-body f target))))

(define (reload-body f target)
  (with-handlers ([(lambda (e) #t)
                   (lambda (e)
                     (define err (value->error e))
                     (log-fiber-error f err)
                     ;; a superseded load is cleaned up but cannot fail the new target
                     (when (equal? (fiber-target f) target)
                       (set-fiber-failure! f err)
                       (set-fiber-target! f #f)))])
    (when (equal? (fiber-target f) target)
      (execute-plugin! f target)))
  (update-state! f (lambda ()
                     (cond
                       [(equal? (fiber-target f) target) (set-inertia! f #f) #f]
                       [else (start-unload! f) 'unloading]))))

;; Validates the config and runs the plugin body. The body's result is an effect result
;; whose inverses join the fiber's top-level list; an evt in it is awaited here, so the
;; fiber stays 'loading until it settles.
(define (execute-plugin! f target)
  (define pl (fiber-plugin f))
  (when pl
    (define ctx (fiber-ctx f))
    (define config (fiber-resolve-config f (fiber-raw-config f)))
    (set-fiber-effective! f config)
    (define results
      (run-user ctx f (lambda ()
                        (call-with-values (lambda () ((plugin-apply pl) ctx config)) list))))
    (interpret-results
     results 'async
     #:collect (lambda (inv) (dlist-push! (fiber-disposables f) inv))
     #:continue? (lambda () (equal? (fiber-target f) target))
     #:resume (lambda (g) (run-user ctx f (lambda () (call-with-values g list)))))
    (void)))

(define (provisions-have-dependents? f)
  (for/or ([i (in-list (fiber-provided f))])
    (positive? (hash-count (impl-dependents i)))))

;; Unload. When no provision has dependents, the top-level list is taken and its entries
;; are queued in the triggering task, as the TypeScript does before its first `await`.
(define (start-unload! f)
  (cond
    [(provisions-have-dependents? f)
     (spawn-transition! f 'unload
                        (lambda ()
                          (wait-for-dependents f)
                          (finish-unload! f (begin-teardown! f))))]
    [else
     (define tasks (begin-teardown! f))
     (spawn-transition! f 'unload (lambda () (finish-unload! f tasks)))]))

;; Dependents were told when this fiber left 'active; each wakes this wait as it finishes
;; its own unload.
(define (wait-for-dependents f)
  (let loop ()
    (when (provisions-have-dependents? f)
      (define l (make-latch (kernel-scheduler (fiber-kernel f))))
      (set-fiber-release! f l)
      (latch-wait l)
      (loop))))

;; Starts every top-level entry, newest first, each in its own kernel task.
(define (begin-teardown! f)
  (set-fiber-release! f #f)
  (for/list ([inv (in-list (dlist-clear! (fiber-disposables f)))])
    (spawn-kernel-task (fiber-kernel f)
                       (lambda () (run-top-level! f inv))
                       #:name 'dispose)))

(define (finish-unload! f tasks)
  (for ([t (in-list tasks)])
    (task-wait t))
  ;; inverses restored the context; the custodian reclaims what they did not name
  (shutdown-activation-custodian! f)
  ;; let go of the providers and wake those that wait for their last dependent
  (define commit (or (fiber-commit f) (hasheq)))
  (for ([key (in-list (fiber-inject-keys f))])
    (define i (hash-ref commit key #f))
    (when (and i (hash-ref (impl-dependents i) f #f))
      (hash-remove! (impl-dependents i) f)
      (when (zero? (hash-count (impl-dependents i)))
        (when (impl-release i)
          (latch-open! (impl-release i)))
        (define provider (context-fiber (impl-ctx i)))
        (when (fiber-release provider)
          (latch-open! (fiber-release provider))))))
  (set-fiber-commit! f #f)
  (update-state! f (lambda ()
                     (cond
                       [(not (fiber-target f)) (set-inertia! f #f) #f]
                       [else (start-reload! f) 'loading]))))

;; ---------------------------------------------------------------------------------------
;; Config

;; The validated form of `candidate` for `f`, through the `internal/config` waterfall.
;; Stores nothing.
(define (fiber-resolve-config f candidate)
  (dispatch-waterfall (fiber-ctx f) 'internal/config (list f) (lambda () candidate)))

;; The kernel's `internal/config` listener: validates what inner listeners produced with
;; the schema of the fiber's plugin.
(define (install-config-hook! k root)
  (add-hook!
   k 'internal/config
   (hook root
         (lambda (f next)
           (define config (next))
           (define rt (fiber-runtime f))
           (define schema (and rt (runtime-schema rt)))
           (cond
             [(not schema) config]
             [(config-schema? schema) ((config-schema-ref schema) schema config)]
             [else (schema config)]))
         #f #f)))

;; ---------------------------------------------------------------------------------------
;; Creation

;; An inject declaration as an association list key -> intercept config or #f, in
;; declaration order (a hash is ordered by key name).
(define (normalize-inject decl)
  (define pairs
    (cond
      [(hash? decl)
       (sort (for/list ([(key config) (in-hash decl)]) (cons (->key key) config))
             symbol<? #:key car)]
      [else
       (for/list ([entry (in-list decl)])
         (if (pair? entry)
             (cons (->key (car entry)) (cdr entry))
             (cons (->key entry) #f)))]))
  (for/fold ([acc '()] #:result (reverse acc)) ([p (in-list pairs)])
    (if (assq (car p) acc)
        (map (lambda (q) (if (eq? (car q) (car p)) p q)) acc)
        (cons p acc))))

;; The root fiber has no custodian of its own: what runs through a root context belongs to
;; the kernel custodian and lives until `context-shutdown!`.
(define (make-root-fiber k)
  (fiber k 0 #f #f 0 #f #f (make-hasheq) '() #f #f 'active #f 0 0 '(0) (hasheq) (hasheq) 0
         '() #f (make-dlist) '() #f #f #f (make-hasheq) #f (make-hasheq)))

(define (get-runtime! k pl)
  (or (hash-ref (kernel-runtimes k) (plugin-key pl) #f)
      (let ([rt (runtime (plugin-key pl) (plugin-name pl) (plugin-config-schema pl)
                         (make-dlist))])
        (hash-set! (kernel-runtimes k) (plugin-key pl) rt)
        (dlist-push! (kernel-runtime-order k) rt)
        rt)))

(define (drop-runtime-if-empty! k rt)
  (when (and (zero? (dlist-count (runtime-fibers rt)))
             (eq? (hash-ref (kernel-runtimes k) (runtime-key rt) #f) rt))
    (hash-remove! (kernel-runtimes k) (runtime-key rt))
    (dlist-delete! (kernel-runtime-order k) rt)))

(define (ctx-plugin ctx p [config #f])
  (define pl (if (plugin? p) p (plugin #f '() #f '() p (hasheq) 'own p)))
  (call/kernel ctx (lambda () (create-fiber! ctx pl config))))

;; A nameless plugin whose identity is `proc`.
(define (ctx-inject ctx keys proc)
  (define pl (plugin #f keys #f '() (lambda (c config) (proc c)) (hasheq) 'own proc))
  (call/kernel ctx (lambda () (create-fiber! ctx pl #f))))

(define (create-fiber! ctx pl config)
  (critical
   (define k (context-kernel ctx))
   (unless (fiber-uid (context-fiber ctx))
     (raise-inactive))
   (define rt (get-runtime! k pl))
   (define injects (normalize-inject (plugin-inject pl)))
   (set-kernel-fiber-counter! k (add1 (kernel-fiber-counter k)))
   (set-kernel-fiber-seq! k (add1 (kernel-fiber-seq k)))
   (define f
     (fiber k (kernel-fiber-seq k) pl rt (kernel-fiber-counter k) #f ctx
            (make-hasheq injects) (map car injects) config #f
            'pending #f 0 0 #f (hasheq) #f 0 '() #f (make-dlist) '() #f #f #f (make-hasheq)
            #f (make-hasheq)))
   ;; the plugin's own interception config is the innermost layer of its context
   (set-fiber-ctx! f (context-derive ctx #:fiber f #:intercepts (filter cdr injects)))
   ;; The fiber is an effect of the fiber it was created on. Its inverses run newest first:
   ;; the second starts the disposal, the first makes the cleanup wait for the unload.
   (define d
     (with-handlers ([(lambda (e) #t)
                      (lambda (e)
                        (drop-runtime-if-empty! k rt)
                        (raise e))])
       (ctx-effect* ctx
                    (lambda ()
                      (dlist-push! (runtime-fibers rt) f)
                      (list (kernel-inverse (lambda () f))
                            (kernel-inverse (lambda () (begin-dispose! f)))))
                    "ctx.plugin()"
                    #:kernel? #t)))
   (set-fiber-dispose-proc! f d)
   (when (eq? (plugin-custodian-mode pl) 'own)
     (set-fiber-own-custodian! f (make-activation-custodian f)))
   ;; Publish only now that the parent owns the disposer: an observer may dispose this
   ;; fiber or its parent, add to its inject list, or register effects on it.
   (with-handlers ([(lambda (e) #t)
                    (lambda (e)
                      (with-handlers ([(lambda (x) #t) (lambda (x) (log-fiber-error f x))])
                        (dispose! d #:detach? #t))
                      (raise e))])
     (dispatch-emit (fiber-ctx f) 'internal/plugin (list f)))
   (when (and (fiber-uid f)
              (not (eq? (fiber-state (context-fiber ctx)) 'unloading)))
     (recheck! f))
   f))

;; ---------------------------------------------------------------------------------------
;; Disposal, restart, update

;; The part of disposal that happens at once: the fiber leaves the registry and its target
;; becomes inactive. The unload itself runs as a transition.
(define (begin-dispose! f)
  (critical
   (define k (fiber-kernel f))
   (define rt (fiber-runtime f))
   (set-fiber-uid! f #f)
   (emit-contained (fiber-ctx f) 'internal/plugin (list f)
                   (lambda (e) (log-fiber-error f e)))
   (when (eq? (hash-ref (kernel-runtimes k) (runtime-key rt) #f) rt)
     (dlist-delete! (runtime-fibers rt) f)
     (drop-runtime-if-empty! k rt))
   (set-target! f #f)
   ;; a pending or failed fiber may own effects although no transition is due
   (unless (fiber-inertia f)
     (update-state! f (lambda () (start-unload! f) 'unloading)))
   (void)))

(define (fiber-dispose! f)
  (call/kernel
   (fiber-ctx f)
   (lambda ()
     (cond
       [(fiber-dispose-proc f)
        => (lambda (d) (call-as-waiter f (lambda () (dispose! d))))]
       ;; disposing the root fiber unloads everything registered through the root
       [else (fiber-restart! f)])
     (void))))

(define (fiber-restart! f)
  (call/kernel
   (fiber-ctx f)
   (lambda ()
     (critical
      (unless (fiber-uid f)
        (raise-inactive))
      (set-fiber-revision! f (add1 (fiber-revision f)))
      (refresh! f))
     (fiber-await f)
     (void))))

(define (fiber-update! f config #:save? [save? #t])
  (call/kernel
   (fiber-ctx f)
   (lambda ()
     (define-values (loaded? resolved config-revision target activation)
       (critical
        (unless (fiber-uid f)
          (raise-inactive))
        (define loaded? (and (fiber-target f) #t))
        ;; an invalid candidate raises here and changes nothing
        (define resolved (and loaded? (fiber-resolve-config f config)))
        (when save?
          (dispatch-emit (fiber-ctx f) 'internal/commit (list f config)))
        (set-fiber-raw-config! f config)
        (set-fiber-failure! f #f)
        (set-fiber-config-revision! f (add1 (fiber-config-revision f)))
        (values loaded? resolved (fiber-config-revision f) (fiber-target f)
                (and (fiber-commit f) (fiber-activation f)))))
     (define restarted? #f)
     (define (restart)
       (set! restarted? #t)
       (fiber-restart! f))
     (define result
       (if loaded?
           (dispatch-waterfall (fiber-ctx f) 'internal/update (list f resolved) restart)
           (restart)))
     ;; a listener that kept the instance may hand back a task that finishes the update
     (when (task? result)
       (task-result result))
     ;; publish only if nothing newer happened: no restart, no later update, same activation
     (when (and (not restarted?)
                (fiber-uid f)
                (= config-revision (fiber-config-revision f))
                (equal? target (fiber-target f))
                (eqv? activation (and (fiber-commit f) (fiber-activation f))))
       (set-fiber-effective! f resolved))
     (void))))
