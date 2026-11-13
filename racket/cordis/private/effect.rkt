#lang racket/base
;; Revertible effects (contract section 4; `effect` in vendor/cordis/src/fiber.ts).
;;
;; A disposer records the inverses its effect collected and is a small state machine:
;; setup is running, settled or failed; cleanup has not started, is running or is done.
;; All of that state lives in the struct, never in a suspended computation, so cleanup can
;; be continued by another thread: by a kernel task when the thread that started it is
;; broken, and by whoever waits for it when that thread was killed.
(require racket/generator
         racket/list
         "scheduler.rkt"
         "breaks.rkt"
         "errors.rkt"
         "core.rkt"
         "dlist.rkt")

(provide disposer? dispose! dispose-effect! disposer-label disposer-children disposer-owner
         ctx-effect ctx-effect* fiber-effects
         (struct-out kernel-inverse)
         interpret-results run-user run-top-level!)

;; An inverse that is kernel bookkeeping (remove a listener, withdraw a service). It runs
;; with breaks off, like the setup that returned it, so that a break cannot leave a kernel
;; table changed without its inverse or an inverse dropped without its change.
(struct kernel-inverse (proc))

(struct disposer
  (kernel
   owner                      ; fiber that owns the effect
   ctx                        ; context the effect was registered through
   label
   [inverses #:mutable]       ; collected inverses, newest first
   [kids #:mutable]           ; collected effect disposers, newest first
   [released? #:mutable]      ; the disposer was called, or setup failed synchronously
   [setup #:mutable]          ; 'running, 'ok or (box raised-value)
   [setup-worker #:mutable]   ; thread that runs setup
   setup-latch                ; open once setup has settled
   [cleanup #:mutable]        ; #f, 'running or 'done
   [worker #:mutable]         ; thread that runs cleanup, or #f
   [pending #:mutable]        ; task or fiber the cleanup waits for, or #f
   [failure #:mutable]        ; box of the first value an inverse raised, or #f
   done-latch)                ; open once cleanup has finished
  #:property prop:procedure
  (lambda (d) (dispose-effect! d))
  #:property prop:evt
  (lambda (d) (wrap-evt (disposer-setup-latch d) (lambda (_) d)))
  #:property prop:awaitable
  (awaiter (lambda (d) (await-setup d))
           (lambda (d) (not (eq? (disposer-setup d) 'running)))
           (lambda (d) (disposer-setup-latch d)))
  #:property prop:custom-write
  (lambda (d port mode) (fprintf port "#<disposer:~a>" (disposer-label d))))

;; Child effects in the order they were collected.
(define (disposer-children d) (reverse (disposer-kids d)))

;; Top-level effects the fiber owns, in registration order.
(define (fiber-effects f)
  (filter disposer? (dlist->list (fiber-disposables f))))

;; Runs user code on behalf of fiber `f` through context `ctx`.
(define (run-user ctx f thunk)
  (call-user
   (lambda ()
     (parameterize ([current-context ctx]
                    [current-custodian (fiber-custodian f)])
       (thunk)))))

;; ---------------------------------------------------------------------------------------
;; Effect results

(define (raise-invalid-effect v)
  (raise (exn:fail:contract
          (format (string-append "invalid effect: expected (void), #f, a procedure of no "
                                 "arguments, a list, a generator, a task or an evt\n"
                                 "  given: ~e")
                  v)
          (current-continuation-marks))))

;; Interprets effect results. `items` is a list of results still to interpret, first one
;; first. `collect` receives each inverse. `continue?` is the guard checked before each
;; generator resume; when it returns #f interpretation stops and what was collected stays.
;; `resume` resumes a generator and returns its values as a list.
;; In mode 'sync an evt stops interpretation: the result is (cons 'async remaining-items).
;; In mode 'async an evt is awaited in the calling task. Otherwise the result is 'done.
(define (interpret-results items mode
                           #:collect collect
                           #:continue? continue?
                           #:resume resume)
  (let loop ([stack items])
    (cond
      [(null? stack) 'done]
      [else
       (define item (car stack))
       (define rest (cdr stack))
       (cond
         [(or (void? item) (not item) (null? item)) (loop rest)]
         [(or (disposer? item) (kernel-inverse? item)) (collect item) (loop rest)]
         [(generator? item)
          (cond
            [(not (continue?)) 'done]
            [(eq? (generator-state item) 'done) (loop rest)]
            [else
             (define vs (resume item))
             (if (eq? (generator-state item) 'done)
                 (loop (append vs rest))
                 (loop (append vs (cons item rest))))])]
         [(procedure? item)
          (unless (procedure-arity-includes? item 0)
            (raise-invalid-effect item))
          (collect item)
          (loop rest)]
         [(list? item) (loop (append item rest))]
         [(evt? item)
          (if (eq? mode 'sync)
              (cons 'async stack)
              (loop (append (await-effect-result item) rest)))]
         [else (raise-invalid-effect item)])])))

;; A task yields its thunk's values and a fiber yields nothing once it has settled. Another
;; evt yields its synchronization result, except the evt itself: many evts (threads,
;; semaphores) are their own result, which would otherwise be awaited forever.
(define (await-effect-result x)
  (cond
    [(task? x) (call-with-values (lambda () (task-result x)) list)]
    [(fiber? x) (fiber-await x) '()]
    [else (remq* (list x) (call-with-values (lambda () (await x)) list))]))

;; ---------------------------------------------------------------------------------------
;; Creating an effect

(define (ctx-effect ctx thunk #:label [label "anonymous"])
  (call/kernel ctx (lambda () (ctx-effect* ctx thunk label))))

;; As `ctx-effect`, for callers that already run in a kernel task. With `kernel?` the thunk
;; is kernel bookkeeping: it runs with breaks off and returns `kernel-inverse`s.
(define (ctx-effect* ctx thunk label #:kernel? [kernel? #f])
  (critical
   (define f (context-fiber ctx))
   (unless (and (fiber-uid f) (not (eq? (fiber-state f) 'unloading)))
     (raise-inactive))
   (define k (context-kernel ctx))
   (define s (kernel-scheduler k))
   (define d (disposer k f ctx label '() '() #f 'running (current-thread) (make-latch s)
                       #f #f #f #f (make-latch s)))
   ;; Registered before the thunk runs, so an unload that starts inside it finds the effect.
   (dlist-push! (fiber-disposables f) d)
   (define outcome
     (with-handlers ([(lambda (e) #t)
                      (lambda (e)
                        (setup-failed! d e #t)
                        (raise e))])
       (interpret d
                  (if kernel?
                      (call-with-values thunk list)
                      (run-user ctx f (lambda () (call-with-values thunk list))))
                  'sync)))
   (if (eq? outcome 'done)
       (setup-ok! d)
       (continue-setup! d (cdr outcome)))
   d))

(define (interpret d items mode)
  (interpret-results
   items mode
   #:collect (lambda (inv) (collect! d inv))
   #:continue? (lambda () (not (disposer-released? d)))
   #:resume (lambda (g)
              (run-user (disposer-ctx d) (disposer-owner d)
                        (lambda () (call-with-values g list))))))

;; A collected inverse leaves the owner's top-level list: it now belongs to this effect.
(define (collect! d inv)
  (set-disposer-inverses! d (cons inv (disposer-inverses d)))
  (dlist-delete! (fiber-disposables (disposer-owner d)) inv)
  (when (disposer? inv)
    (set-disposer-kids! d (cons inv (disposer-kids d)))))

(define (setup-ok! d)
  (set-disposer-setup! d 'ok)
  (latch-open! (disposer-setup-latch d)))

;; Setup met an evt: the rest runs in a kernel task and the caller gets the disposer now.
(define (continue-setup! d items)
  (define k (disposer-kernel d))
  (define token (disposer-setup-latch d))
  (busy-add! k token)
  (define t
    (spawn-kernel-task
     k
     (lambda ()
       (critical
        (set-disposer-setup-worker! d (current-thread))
        (with-handlers ([(lambda (e) #t)
                         (lambda (e)
                           (setup-failed! d e #f)
                           (log-error-once k (effect-name d) e))])
          (interpret d items 'async)
          (setup-ok! d))
        (busy-remove! k token)))
     #:name 'effect-setup))
  (set-disposer-setup-worker! d (task-thread t)))

;; Records the failure and rolls back what was collected. A caller that is already waiting
;; for setup in order to dispose finds the cleanup done when it wakes.
(define (setup-failed! d e sync?)
  (set-disposer-setup! d (box e))
  (when sync?
    (set-disposer-released?! d #t))
  (latch-open! (disposer-setup-latch d))
  (unless (eq? (disposer-cleanup d) 'done)
    (unless (disposer-cleanup d)
      (start-cleanup! d))
    ;; Whoever holds the cleanup now is waiting for this setup and has run no inverse.
    (claim! d)
    (drive-cleanup! d sync?)))

(define (effect-name d)
  (format "~a: effect ~a" (fiber-name (disposer-owner d)) (disposer-label d)))

;; ---------------------------------------------------------------------------------------
;; Waiting for setup

;; Waits until setup has settled. If the thread that ran setup died first, setup counts as
;; failed and what it collected is left for cleanup. Call from a kernel task.
(define (wait-setup! d)
  (let loop ()
    (when (eq? (disposer-setup d) 'running)
      (define w (disposer-setup-worker d))
      (cond
        [(thread-dead? w)
         (set-disposer-setup! d (box (setup-killed d)))
         (latch-open! (disposer-setup-latch d))]
        [else
         (call-user
          (lambda () (latch-wait (disposer-setup-latch d) (thread-dead-evt w))))
         (loop)]))))

(define (setup-killed d)
  (exn:fail:cordis:task-killed (format "~a: setup was killed" (effect-name d))
                               (current-continuation-marks)))

;; `await` on a disposer: the disposer once setup has settled; raises the setup failure.
;; Changes nothing, so it may run on any thread.
(define (await-setup d)
  (let loop ()
    (when (eq? (disposer-setup d) 'running)
      (define w (disposer-setup-worker d))
      (when (thread-dead? w)
        (raise (setup-killed d)))
      (latch-wait (disposer-setup-latch d) (thread-dead-evt w))
      (loop)))
  (define s (disposer-setup d))
  (when (box? s) (raise (unbox s)))
  d)

;; ---------------------------------------------------------------------------------------
;; Cleanup

(define (start-cleanup! d)
  (set-disposer-cleanup! d 'running)
  (busy-add! (disposer-kernel d) (disposer-done-latch d)))

;; The public entry: a disposer may be called from any thread. A finished one needs no
;; kernel task.
(define (dispose-effect! d)
  (unless (and (disposer-released? d) (eq? (disposer-cleanup d) 'done))
    (call/kernel (disposer-ctx d) (lambda () (dispose! d))))
  (void))

;; Calling a disposer. The first call runs the collected inverses, newest first, each to
;; completion, after setup has settled; it raises the setup failure if setup failed after
;; `ctx-effect` returned, else the first value an inverse raised. Every later call waits for
;; that cleanup and returns. With `detach?` the call never waits: what cannot be done at
;; once continues in a kernel task.
(define (dispose! d #:detach? [detach? #f])
  (critical
   (cond
     [(disposer-released? d)
      (unless detach? (join-cleanup! d))
      (void)]
     [else
      (set-disposer-released?! d #t)
      (define outcome
        (cond
          [(disposer-cleanup d)
           (if detach?
               'detached
               (begin (join-cleanup! d) 'done))]
          [else
           (start-cleanup! d)
           (claim! d)
           (drive-cleanup! d detach?)]))
      (when (eq? outcome 'done)
        (define s (disposer-setup d))
        (cond
          [(box? s) (raise (unbox s))]
          [(disposer-failure d) => (lambda (b) (raise (unbox b)))]
          [else (void)]))])))

;; Makes the current thread the one that advances the cleanup.
(define (claim! d)
  (set-disposer-worker! d (current-thread)))

;; Advances the cleanup in the current thread, which must hold the claim, until it is done,
;; and returns 'done. If another thread claims the cleanup while this one waits, this one
;; joins it. With `detach?`, returns 'detached instead of waiting, after handing the rest
;; to a kernel task. A break of the current thread, in an inverse or in a wait, hands the
;; rest to a kernel task and is re-raised. Any other value an inverse raises is logged with
;; the effect label and the remaining inverses still run.
(define (drive-cleanup! d detach?)
  (define me (current-thread))
  (let loop ()
    (cond
      [(eq? (disposer-cleanup d) 'done) 'done]
      [(not (eq? (disposer-worker d) me))
       ;; another thread took the cleanup over while this one waited
       (if detach?
           'detached
           (begin (join-cleanup! d) 'done))]
      [(eq? (disposer-setup d) 'running)
       (cond
         [(or detach? (eq? (disposer-setup-worker d) me))
          ;; never wait for a setup that this very thread is running
          (hand-over! d)
          'detached]
         [else
          (guarded d (lambda () (wait-setup! d)))
          (loop)])]
      [(disposer-pending d)
       => (lambda (p)
            (cond
              [(or (and detach? (not (settled? p))) (self-wait? p))
               (hand-over! d)
               'detached]
              [else
               (guarded d (lambda () (wait-pending p)))
               (when (eq? (disposer-worker d) me)
                 (set-disposer-pending! d #f))
               (loop)]))]
      [(pair? (disposer-inverses d))
       (define inv (car (disposer-inverses d)))
       (define started? (box #f))
       (set-disposer-inverses! d (cdr (disposer-inverses d)))
       (guarded d
                (lambda ()
                  (define r (call-inverse d inv started?))
                  (when (or (task? r) (fiber? r))
                    (set-disposer-pending! d r)))
                ;; an inverse that the break kept from starting is still due
                (lambda ()
                  (unless (unbox started?)
                    (set-disposer-inverses! d (cons inv (disposer-inverses d))))))
       (loop)]
      [else
       (finish-cleanup! d)
       'done])))

(define (guarded d thunk [before-hand-over void])
  (with-handlers ([own-break?
                   (lambda (e)
                     (when (and (eq? (disposer-worker d) (current-thread))
                                (not (eq? (disposer-cleanup d) 'done)))
                       (before-hand-over)
                       (hand-over! d))
                     (raise e))]
                  [(lambda (e) #t)
                   (lambda (e)
                     (log-error-once (disposer-kernel d) (effect-name d) e)
                     (unless (disposer-failure d)
                       (set-disposer-failure! d (box e))))])
    (thunk)))

;; An inverse that is an effect disposer is disposed and joined. Another inverse is called;
;; when it returns a task or a fiber, the cleanup waits for that before the next inverse.
;; `started?` is set once the inverse itself has begun to run. A child disposer never counts
;; as started: calling it again later joins whatever it had begun.
(define (call-inverse d inv started?)
  (cond
    [(disposer? inv) (dispose! inv) #f]
    [(kernel-inverse? inv)
     (set-box! started? #t)
     (call-with-values (kernel-inverse-proc inv)
                       (lambda vs (and (pair? vs) (car vs))))]
    [else
     (call-with-values (lambda ()
                         (run-user (disposer-ctx d) (disposer-owner d)
                                   (lambda () (set-box! started? #t) (inv))))
                       (lambda vs (and (pair? vs) (car vs))))]))

(define (settled? p)
  (cond
    [(task? p) (task-done? p)]
    [(fiber? p) (not (fiber-inertia p))]
    [else #t]))

;; True when the current task is the very transition `p` would have to wait for: a plugin
;; body that disposes its own fiber.
(define (self-wait? p)
  (and (fiber? p)
       (let ([i (fiber-inertia p)])
         (and i (eq? i (current-task))))))

(define (wait-pending p)
  (cond
    [(task? p) (call-user (lambda () (task-result p))) (void)]
    [(fiber? p) (call-user (lambda () (fiber-wait p)))]
    [else (void)]))

(define (finish-cleanup! d)
  (dlist-delete! (fiber-disposables (disposer-owner d)) d)
  (set-disposer-cleanup! d 'done)
  (set-disposer-worker! d #f)
  (busy-remove! (disposer-kernel d) (disposer-done-latch d))
  (latch-open! (disposer-done-latch d)))

;; Continues the cleanup in a kernel task.
(define (hand-over! d)
  (define t
    (spawn-kernel-task
     (disposer-kernel d)
     (lambda ()
       (critical
        (when (and (eq? (disposer-cleanup d) 'running)
                   (eq? (disposer-worker d) (current-thread)))
          (drive-cleanup! d #f))))
     #:name 'effect-cleanup))
  (set-disposer-worker! d (task-thread t)))

;; Waits until a cleanup that another thread runs is done. If that thread died, the
;; cleanup is continued here. A call from the thread that runs the cleanup (an inverse that
;; calls its own disposer) returns at once.
(define (join-cleanup! d)
  (let loop ()
    (define w (disposer-worker d))
    (cond
      [(not (eq? (disposer-cleanup d) 'running)) (void)]
      [(eq? w (current-thread)) (void)]
      [(or (not w) (thread-dead? w))
       (claim! d)
       (drive-cleanup! d #f)
       (void)]
      [else
       (call-user
        (lambda () (latch-wait (disposer-done-latch d) (thread-dead-evt w))))
       (loop)])))

;; One entry of a fiber's top-level list at unload: an effect disposer, or an inverse the
;; plugin body returned. Failures are logged; nothing is raised.
(define (run-top-level! f inv)
  (critical
   (with-handlers ([(lambda (e) #t) (lambda (e) (log-fiber-error f e))])
     (cond
       [(disposer? inv) (dispose! inv)]
       [else
        (wait-pending
         (call-with-values (lambda () (run-user (fiber-ctx f) f inv))
                           (lambda vs (and (pair? vs) (car vs)))))]))))
