#lang racket/base
;; Cooperative tasks on Racket threads (ADR 0002).
;;
;; A scheduler owns one baton. A manager thread grants it to one request at a time in FIFO
;; order and takes it back when the holder releases it or dies. A task is a thread that runs
;; its thunk only while it holds the baton, so code between two wait points is never
;; interleaved with another task of the same scheduler.
;;
;; Invariants the rest of the kernel relies on:
;; - at most one request per thread is queued or granted (the manager drops duplicates), so
;;   a waiter may be queued on its behalf by the task that completes what it waits for;
;; - every wait reacquires the baton before it returns or raises;
;; - a task's waiter list and a latch's waiter list are touched only by baton holders.
;;
;; Breaks are cooperative. A task's thunk runs with breaks disabled, and a break is raised
;; only at a release point, after the baton is reacquired. A release point accepts a break
;; when the code that reaches it has not masked breaks itself: its break-enabled cell is
;; still the one the task started with, or it enabled breaks explicitly. Code under
;; `parameterize-break #f`, an exception handler or a `dynamic-wind` pre or post thunk
;; therefore waits without being interrupted, as it would on a plain thread. The cell is
;; read through `break-enabled-key` of '#%paramz, the key `parameterize-break` itself uses;
;; tests/task-test.rkt pins the behaviour this depends on.
(require racket/list
         (only-in '#%paramz break-enabled-key)
         "errors.rkt"
         "log.rkt")

(provide current-scheduler current-baton-warn-ms
         make-scheduler scheduler? scheduler-name scheduler-shutdown! scheduler-alive?
         spawn-task task? task-name task-scheduler task-done? task-result task-thread
         task-cancel! task-kill! task-wait task-failure task-observe!
         current-task in-task? own-break?
         await await/timeout await-all yield-task task-check-break task-sleep blocking
         call-in-kernel
         prop:awaitable awaitable? (struct-out awaiter)
         make-latch latch? latch-open! latch-open? latch-wait)

;; ---------------------------------------------------------------------------------------
;; Parameters and thread-local state

(define current-scheduler (make-parameter #f))

;; Milliseconds a task may hold the baton between two release points before the manager
;; logs a warning; #f disables the check. Read by the task when it requests the baton.
(define current-baton-warn-ms (make-parameter 2000))

;; The task whose thunk the current thread runs, or #f. Not inherited by new threads.
(define task-cell (make-thread-cell #f #f))
(define (current-task) (thread-cell-ref task-cell))

;; Break exceptions that ended another thread and were stored as its outcome. Raising one
;; again, from `task-result` or `blocking`, reports that thread's cancellation; it is not a
;; break of the thread that raises it.
(define stored-breaks (make-weak-hasheq))

;; True for a break that was delivered to the thread that sees it.
(define (own-break? e)
  (and (exn:break? e) (not (hash-ref stored-breaks e #f))))

;; The thread cell that holds the break-enabled state of the current continuation.
(define (current-break-cell)
  (continuation-mark-set-first #f break-enabled-key))

;; True when a release point reached now by task `me` accepts a break.
(define (breakable? me)
  (or (break-enabled)
      (eq? (current-break-cell) (task-break-cell me))))

;; Raises a break that is pending for the current thread.
(define (raise-pending-break)
  (parameterize-break #t (void)))

;; ---------------------------------------------------------------------------------------
;; Awaitables

;; A struct with this property chooses what `await` does for it. The value is an `awaiter`:
;; await : (-> self any) waits and produces the result or raises;
;; ready? : (-> self boolean?) is true when `await` would not wait;
;; evt : (-> self evt?) becomes ready when `ready?` may have changed.
(define-values (prop:awaitable awaitable? awaitable-ref)
  (make-struct-type-property 'awaitable))
(struct awaiter (await ready? evt))

;; ---------------------------------------------------------------------------------------
;; Scheduler and manager

(struct scheduler (name custodian channel [manager #:mutable] wills unobserved)
  #:property prop:custom-write
  (lambda (s port mode) (fprintf port "#<scheduler:~a>" (scheduler-name s))))

;; A baton request. `label` names the requester in the hold-time warning.
(struct req (thread grant warn-ms label))

(define (make-scheduler #:name [name 'cordis] #:custodian [cust (current-custodian)])
  (define s (scheduler name cust (make-channel) #f (make-will-executor) (make-weak-hasheq)))
  (define ch (scheduler-channel s))
  (define wills (scheduler-wills s))
  (set-scheduler-manager!
   s
   (parameterize ([current-custodian cust])
     (parameterize-break #f
       (thread (lambda () (manager-loop name ch wills))))))
  s)

(define (scheduler-alive? s)
  (not (thread-dead? (scheduler-manager s))))

;; The loop state is the holder's request (or #f), a two-list FIFO of waiting requests, the
;; set of threads that have a queued request, and the time at which to warn about the holder.
(define (manager-loop name ch wills)
  (let loop ([holder #f] [front '()] [back '()] [queued (hasheq)] [deadline #f])
    (define (enqueue r holder)
      (define th (req-thread r))
      (if (or (hash-ref queued th #f) (and holder (eq? (req-thread holder) th)))
          (loop holder front back queued deadline)
          (loop holder front (cons r back) (hash-set queued th #t) deadline)))
    (cond
      [(and (not holder) (or (pair? front) (pair? back)))
       (define-values (r front* back*)
         (if (pair? front)
             (values (car front) (cdr front) back)
             (let ([f (reverse back)]) (values (car f) (cdr f) '()))))
       (define queued* (hash-remove queued (req-thread r)))
       (cond
         [(thread-dead? (req-thread r)) (loop #f front* back* queued* #f)]
         [else
          (semaphore-post (req-grant r))
          (loop r front* back* queued*
                (and (req-warn-ms r)
                     (+ (current-inexact-monotonic-milliseconds) (req-warn-ms r))))])]
      [else
       (sync
        (handle-evt
         ch
         (lambda (msg)
           (case (car msg)
             [(request) (enqueue (cdr msg) holder)]
             [(release)
              (if (and holder (eq? (req-thread holder) (cdr msg)))
                  (loop #f front back queued #f)
                  (loop holder front back queued deadline))]
             [(yield)
              (define r (cdr msg))
              (if (and holder (eq? (req-thread holder) (req-thread r)))
                  (if (hash-ref queued (req-thread r) #f)
                      (loop #f front back queued #f)
                      (loop #f front (cons r back) (hash-set queued (req-thread r) #t) #f))
                  (enqueue r holder))]
             [(shutdown) (void)]
             [else (loop holder front back queued deadline)])))
        (if holder
            (handle-evt (thread-dead-evt (req-thread holder))
                        (lambda (_) (loop #f front back queued #f)))
            never-evt)
        (if deadline
            (handle-evt (alarm-evt deadline #t)
                        (lambda (_)
                          (log-cordis
                           'warning
                           (format "task ~a has held the baton of scheduler ~a for more than ~a ms"
                                   (req-label holder) name (req-warn-ms holder)))
                          (loop holder front back queued #f)))
            never-evt)
        (handle-evt wills
                    (lambda (_)
                      (will-execute wills)
                      (loop holder front back queued deadline))))])))

;; Delivers `msg` to the manager. Returns #f when the manager is gone. Call with breaks off.
(define (send! s msg)
  (sync (handle-evt (channel-put-evt (scheduler-channel s) msg) (lambda (_) #t))
        (handle-evt (thread-dead-evt (scheduler-manager s)) (lambda (_) #f))))

;; A task of a scheduler that was shut down never runs again.
(define (block-forever)
  (semaphore-wait (make-semaphore 0)))

(define (scheduler-shutdown! s)
  (when (scheduler-alive? s)
    (for ([t (in-list (hash-keys (scheduler-unobserved s)))])
      (report-unobserved! t))
    (parameterize-break #f
      (send! s (cons 'shutdown #f))))
  (void))

;; ---------------------------------------------------------------------------------------
;; Completions: one-shot "done" marks with an ordered waiter list

;; `waiters` holds the requests of tasks waiting, newest first. The task that marks the
;; completion done queues those requests itself, so waiters resume in the order in which
;; they started to wait, whatever order their threads wake in.
(struct completion ([done? #:mutable] [waiters #:mutable]))

;; Called by any thread. Only a task of scheduler `s` hands the baton queue to the waiters;
;; other callers leave the wake-up to each waiter's fallback event.
(define (complete! c s)
  (unless (completion-done? c)
    (set-completion-done?! c #t)
    (define me (current-task))
    (when (and me (eq? (task-scheduler me) s))
      (define waiters (reverse (completion-waiters c)))
      (set-completion-waiters! c '())
      (parameterize-break #f
        (for ([r (in-list waiters)])
          (send! s (cons 'request r)))))))

;; ---------------------------------------------------------------------------------------
;; Tasks

;; outcome : #f while running, (cons 'values list) or (cons 'raise value) once finished.
;; `custodian` is the spawner's current custodian; it manages the task's thread.
;; `break-cell` is the break-enabled cell the thunk starts with; see `breakable?`.
(struct task (name scheduler grant done custodian
                   [thread #:mutable] [outcome #:mutable] [observed? #:mutable]
                   [break-cell #:mutable])
  #:property prop:evt
  (lambda (t) (wrap-evt (thread-dead-evt (task-thread t)) (lambda (_) t)))
  #:property prop:awaitable
  (awaiter (lambda (t) (task-result t))
           (lambda (t) (task-done? t))
           (lambda (t) (thread-dead-evt (task-thread t))))
  #:property prop:custom-write
  (lambda (t port mode) (fprintf port "#<task:~a>" (task-name t))))

(define (make-request t)
  (req (task-thread t) (task-grant t) (current-baton-warn-ms) (task-name t)))

(define (spawn-task thunk #:name [name #f] #:scheduler [s (current-scheduler)])
  (unless (scheduler? s)
    (raise-argument-error 'spawn-task "scheduler? (no current scheduler)" s))
  (unless (scheduler-alive? s)
    (raise-cordis "spawn-task: scheduler ~a has been shut down" (scheduler-name s)))
  (define t (task (or name (object-name thunk) 'task) s (make-semaphore 0)
                  (completion #f '()) (current-custodian) #f #f #f #f))
  ;; The request is queued here, before this procedure returns, so tasks start in spawn
  ;; order. The new thread starts with breaks off and keeps them off.
  (parameterize-break #f
    (define th
      (parameterize ([current-scheduler s])
        (thread (lambda () (task-main t thunk)))))
    (set-task-thread! t th)
    (unless (send! s (cons 'request (make-request t)))
      (kill-thread th)))
  t)

(define (task-main t thunk)
  (define s (task-scheduler t))
  (thread-cell-set! task-cell t)
  (wait-grant s t)
  (define outcome
    (with-handlers ([(lambda (e) #t) (lambda (e) (cons 'raise e))])
      (call-with-values (lambda ()
                          (parameterize-break #f
                            (set-task-break-cell! t (current-break-cell))
                            (thunk)))
                        (lambda vs (cons 'values vs)))))
  (set-task-outcome! t outcome)
  (when (eq? (car outcome) 'raise)
    (note-failure! t (cdr outcome)))
  (complete! (task-done t) s)
  (send! s (cons 'release (current-thread))))

(define (wait-grant s t)
  (sync (task-grant t)
        (handle-evt (thread-dead-evt (scheduler-manager s)) (lambda (_) (block-forever)))))

;; Releases nothing; queues a request for `t` and waits for the grant. Breaks must be off.
(define (acquire! s t)
  (if (send! s (cons 'request (make-request t)))
      (wait-grant s t)
      (block-forever)))

(define (release! s t)
  (send! s (cons 'release (task-thread t)))
  (void))

(define (task-done? t)
  (and (or (task-outcome t) (thread-dead? (task-thread t))) #t))

(define (in-task? [s (current-scheduler)])
  (define me (current-task))
  (and me (eq? (task-scheduler me) s)))

(define (task-cancel! t)
  (break-thread (task-thread t))
  (void))

;; `kill-thread` wants a current custodian that manages the thread. That is the custodian
;; the task was spawned under, unless the thread was handed to another one since (the kernel
;; does that for a task that waits for the unload of its own fiber); the scheduler's
;; custodian, which the kernel's custodians descend from, is tried next.
(define (task-kill! t)
  (define th (task-thread t))
  (define (kill-under custodian)
    (parameterize ([current-custodian custodian])
      (kill-thread th)))
  (unless (thread-dead? th)
    (with-handlers ([exn:fail:contract?
                     (lambda (e) (kill-under (scheduler-custodian (task-scheduler t))))])
      (kill-under (task-custodian t))))
  (void))

;; Marks a failure as seen so that it is not reported as unobserved.
(define (task-observe! t)
  (set-task-observed?! t #t))

;; The value the task's thunk raised, an `exn:fail:cordis:task-killed` if its thread died
;; without an outcome, or #f. Never waits; marks the failure observed.
(define (task-failure t)
  (define o (task-outcome t))
  (cond
    [(and o (eq? (car o) 'raise)) (task-observe! t) (cdr o)]
    [o #f]
    [(thread-dead? (task-thread t))
     (if (task-outcome t)
         (task-failure t)
         (exn:fail:cordis:task-killed (format "task ~a was killed" (task-name t))
                                      (current-continuation-marks)))]
    [else #f]))

(define (note-failure! t e)
  (define s (task-scheduler t))
  (when (exn:break? e)
    (hash-set! stored-breaks e #t))
  (log-cordis 'debug (format "task ~a raised: ~a" (task-name t) (error->string e)) e)
  (hash-set! (scheduler-unobserved s) t #t)
  (will-register (scheduler-wills s) t report-unobserved!))

(define (report-unobserved! t)
  (unless (task-observed? t)
    (task-observe! t)
    (define o (task-outcome t))
    (when (and o (eq? (car o) 'raise))
      (log-cordis 'error
                  (format "unobserved failure of task ~a: ~a"
                          (task-name t) (error->string (cdr o)))
                  (cdr o)))))

;; Waits until `t` has finished, without producing its result. Returns with the baton held
;; when called from a task. A break is raised only after the baton is reacquired.
(define (task-wait t)
  (define me (current-task))
  (when (eq? me t)
    (raise-cordis "task ~a cannot wait for itself" (task-name t)))
  (let loop ()
    (unless (task-done? t)
      (define dead (thread-dead-evt (task-thread t)))
      (cond
        [(and me (eq? (task-scheduler me) (task-scheduler t)))
         (baton-wait me (task-done t) dead)]
        [me (baton-sync me dead)]
        [else (sync dead)])
      (loop))))

(define (task-result t)
  (task-wait t)
  (define o (task-outcome t))
  (cond
    [(not o)
     (task-observe! t)
     (raise-task-killed (format "task ~a was killed" (task-name t)))]
    [(eq? (car o) 'values) (apply values (cdr o))]
    [else
     (task-observe! t)
     (raise (cdr o))]))

;; ---------------------------------------------------------------------------------------
;; Waiting with the baton released

;; Waits for completion `c` or for `fallback` to become ready. The caller holds the baton
;; of `me`'s scheduler and holds it again on return. `fallback` must become ready whenever
;; `c` is marked done by a thread that does not hold the baton, or will never be marked.
;; A break is accepted while waiting when `breakable?` holds on entry.
(define (baton-wait me c fallback)
  (define s (task-scheduler me))
  (define r (make-request me))
  (set-completion-waiters! c (cons r (completion-waiters c)))
  (define breaks? (breakable? me))
  (define broken
    (parameterize-break #f
      (release! s me)
      (define choice
        (choice-evt (handle-evt (task-grant me) (lambda (_) 'granted))
                    (handle-evt fallback (lambda (_) 'fallback))))
      (define outcome
        (with-handlers ([exn:break? values])
          (if breaks? (sync/enable-break choice) (sync choice))))
      (unless (eq? outcome 'granted)
        (acquire! s me))
      (set-completion-waiters! c (remq r (completion-waiters c)))
      (and (exn? outcome) outcome)))
  (when broken (raise broken)))

;; `sync` on `evt` with the baton released; returns the synchronization result. A break is
;; accepted while waiting when `breakable?` holds on entry.
(define (baton-sync me evt)
  (define s (task-scheduler me))
  (define breaks? (breakable? me))
  (define outcome
    (parameterize-break #f
      (release! s me)
      (define o
        (with-handlers ([(lambda (e) #t) (lambda (e) (cons 'raise e))])
          (call-with-values (lambda () (if breaks? (sync/enable-break evt) (sync evt)))
                            (lambda vs (cons 'values vs)))))
      (acquire! s me)
      o))
  (if (eq? (car outcome) 'raise)
      (raise (cdr outcome))
      (apply values (cdr outcome))))

;; Raises a break that is pending for the current thread, unless the calling code masks
;; breaks. A cancellation point that neither waits nor releases the baton.
(define (task-check-break)
  (define me (current-task))
  (when (if me (breakable? me) (break-enabled))
    (raise-pending-break))
  (void))

;; Every `await` is a cancellation point, also when what it awaits has already settled.
(define (await x)
  (cond
    [(awaitable? x)
     (task-check-break)
     ((awaiter-await (awaitable-ref x)) x)]
    [(evt? x)
     (define me (current-task))
     (if me (baton-sync me x) (sync x))]
    [else (raise-argument-error 'await "(or/c task? fiber? evt?)" x)]))

(define (await/timeout secs x [on-timeout (lambda () #f)])
  (define deadline
    (alarm-evt (+ (current-inexact-monotonic-milliseconds) (* 1000.0 secs)) #t))
  (define timeout (string->uninterned-symbol "timeout"))
  (cond
    [(awaitable? x)
     (define a (awaitable-ref x))
     (task-check-break)
     (let loop ()
       (cond
         [((awaiter-ready? a) x) ((awaiter-await a) x)]
         [else
          (define r
            (await (choice-evt (handle-evt ((awaiter-evt a) x) (lambda _ 'step))
                               (handle-evt deadline (lambda (_) timeout)))))
          (if (eq? r timeout) (on-timeout) (loop))]))]
    [(evt? x)
     (call-with-values
      (lambda () (await (choice-evt x (handle-evt deadline (lambda (_) timeout)))))
      (lambda vs
        (if (and (pair? vs) (eq? (car vs) timeout))
            (on-timeout)
            (apply values vs))))]
    [else (raise-argument-error 'await/timeout "(or/c task? fiber? evt?)" x)]))

;; Results in order, one value per element (a list when the element produced another number
;; of values). Every element is awaited; the first failure in list order is raised after
;; all have settled. A break of the calling task is raised at once.
(define (await-all xs)
  (task-check-break)
  (define outcomes
    (for/list ([x (in-list xs)])
      (cond
        [(task? x)
         (task-wait x)
         (define e (task-failure x))
         (if e
             (cons 'raise e)
             (cons 'values (cdr (task-outcome x))))]
        [else
         (with-handlers ([(lambda (e) (not (own-break? e))) (lambda (e) (cons 'raise e))])
           (call-with-values (lambda () (await x)) (lambda vs (cons 'values vs))))])))
  (define failed (findf (lambda (o) (eq? (car o) 'raise)) outcomes))
  (when failed (raise (cdr failed)))
  (for/list ([o (in-list outcomes)])
    (define vs (cdr o))
    (if (and (pair? vs) (null? (cdr vs))) (car vs) vs)))

;; The break check comes after the baton is back: a break that arrived while the task was
;; queued is raised under the baton, like one that arrives during `await`.
(define (yield-task)
  (define me (current-task))
  (cond
    [me
     (define s (task-scheduler me))
     (define breaks? (breakable? me))
     (parameterize-break #f
       (if (send! s (cons 'yield (make-request me)))
           (wait-grant s me)
           (block-forever)))
     (when breaks? (raise-pending-break))]
    [else (sleep 0)])
  (void))

(define (task-sleep secs)
  (await (alarm-evt (+ (current-inexact-monotonic-milliseconds) (* 1000.0 secs)) #t))
  (void))

;; Outside a task the thunk is simply called. Inside a task it runs on a helper thread while
;; the baton is released. If the waiting task is broken, the helper is broken as well and
;; killed one second later if it is still running; the break is raised without waiting.
(define (blocking thunk)
  (cond
    [(current-task)
     (define outcome #f)
     (define helper
       (parameterize-break #f
         (thread
          (lambda ()
            (set! outcome
                  (with-handlers ([(lambda (e) #t)
                                   (lambda (e)
                                     (when (exn:break? e)
                                       (hash-set! stored-breaks e #t))
                                     (cons 'raise e))])
                    (call-with-values (lambda () (parameterize-break #t (thunk)))
                                      (lambda vs (cons 'values vs)))))))))
     (with-handlers ([own-break?
                      (lambda (e)
                        (break-thread helper)
                        (thread (lambda ()
                                  (unless (sync/timeout 1 (thread-dead-evt helper))
                                    (kill-thread helper))))
                        (raise e))])
       (await (thread-dead-evt helper)))
     (cond
       [(not outcome) (raise-task-killed "blocking: the helper thread was killed")]
       [(eq? (car outcome) 'raise) (raise (cdr outcome))]
       [else (apply values (cdr outcome))])]
    [else (thunk)]))

(define (call-in-kernel thunk #:scheduler [s (current-scheduler)])
  (unless (scheduler? s)
    (raise-argument-error 'call-in-kernel "scheduler? (no current scheduler)" s))
  (define me (current-task))
  (cond
    [(and me (eq? (task-scheduler me) s)) (thunk)]
    [else
     (define t (spawn-task thunk #:name 'call-in-kernel #:scheduler s))
     (define done
       (choice-evt (thread-dead-evt (task-thread t))
                   (thread-dead-evt (scheduler-manager s))))
     ;; A break of the caller cancels the task; the caller does not wait for it.
     (with-handlers ([exn:break? (lambda (e)
                                   (task-cancel! t)
                                   (task-observe! t)
                                   (raise e))])
       (if me (baton-sync me done) (sync done)))
     (unless (task-done? t)
       (task-observe! t)
       (raise-cordis "call-in-kernel: scheduler ~a was shut down" (scheduler-name s)))
     (task-result t)]))

;; ---------------------------------------------------------------------------------------
;; Latches: one-shot events for kernel code

;; A latch belongs to one scheduler; tasks of that scheduler that wait for it resume in the
;; order in which they started to wait. Any thread may open it, and any thread may `sync`
;; on it.
(struct latch (scheduler done sema)
  #:property prop:evt
  (lambda (l) (wrap-evt (semaphore-peek-evt (latch-sema l)) (lambda (_) l)))
  #:property prop:awaitable
  (awaiter (lambda (l) (latch-wait l) l)
           (lambda (l) (latch-open? l))
           (lambda (l) (semaphore-peek-evt (latch-sema l)))))

(define (make-latch s)
  (latch s (completion #f '()) (make-semaphore 0)))

(define (latch-open? l)
  (completion-done? (latch-done l)))

(define (latch-open! l)
  (unless (latch-open? l)
    (complete! (latch-done l) (latch-scheduler l))
    (semaphore-post (latch-sema l)))
  (void))

;; Returns when the latch is open or `extra` is ready; `latch-open?` tells which.
(define (latch-wait l [extra never-evt])
  (unless (latch-open? l)
    (define me (current-task))
    (define fallback (choice-evt (semaphore-peek-evt (latch-sema l)) extra))
    (cond
      [(and me (eq? (task-scheduler me) (latch-scheduler l)))
       (baton-wait me (latch-done l) fallback)]
      [me (baton-sync me fallback)]
      [else (sync fallback)]))
  (void))
