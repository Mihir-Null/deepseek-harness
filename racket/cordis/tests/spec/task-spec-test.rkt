#lang racket/base
;; Black-box specification tests for cordis/task: the scheduler, the baton and
;; `await`. At least one test case per numbered rule of contract section 2
;; (docs/racket/contracts/cordis-kernel.md); the comment in each case names it.
;; Rule 4 is tested as the cooperative-break rule of contract section 12,
;; addendum 1: a break reaches a task only at a release point.
(require cordis/task
         (only-in cordis exn:fail:cordis? exn:fail:cordis:task-killed?)
         (only-in cordis/testing capture-log)
         rackunit
         racket/list
         "support.rkt")

;; CPU work without a release point, long enough for a preemptive thread
;; switch to happen if the baton did not prevent it.
(define (spin)
  (for/fold ([acc 0]) ([i (in-range 3000000)]) (+ acc (bitwise-and i 7))))

(define never (make-semaphore 0))

;; source: contract 2, surface of make-scheduler / scheduler? / current-scheduler
(test-case "task/surface: scheduler values and the current-scheduler parameter"
  (check-false (current-scheduler))
  (with-scheduler (s)
    (check-true (scheduler? s))
    (check-false (scheduler? 'not-a-scheduler))
    (check-eq? (current-scheduler) s)))

;; source: contract 2, comments on task?, task-done?, task-result, task-thread
(test-case "task/surface: a task is an evt whose sync value is the task"
  (with-scheduler (s)
    (define gate (make-semaphore 0))
    (define t (spawn-task (lambda () (await gate) (values 1 2))))
    (check-true (task? t))
    (check-false (task? gate))
    (check-true (thread? (task-thread t)))
    (check-false (task-done? t))
    (semaphore-post gate)
    (check-eq? (sync/timeout spec-timeout t) t)
    (check-true (task-done? t))
    (check-equal? (call-with-values (lambda () (task-result t)) list) '(1 2))))

;; source: contract 2 rule 1
(test-case "task rule 1: at most one task runs; no descheduling between release points"
  (with-scheduler (s)
    (run-task
     (lambda ()
       (define log (make-recorder))
       (define counter 0)
       (define (worker id)
         (lambda ()
           (note! log (cons id 'start))
           (define seen counter)
           (spin)
           (set! counter (add1 seen))
           (note! log (cons id 'end))))
       (await-all (for/list ([id (in-list '(a b c))]) (spawn-task (worker id))))
       (check-equal? (notes log)
                     '((a . start) (a . end) (b . start) (b . end) (c . start) (c . end)))
       (check-equal? counter 3)))))

;; source: contract 2 rule 2, first sentence
(test-case "task rule 2: tasks start in spawn order and never inside spawn-task"
  (with-scheduler (s)
    (run-task
     (lambda ()
       (define log (make-recorder))
       (define ts (for/list ([i (in-range 5)]) (spawn-task (lambda () (note! log i)))))
       (note! log 'spawner-continues)
       (await-all ts)
       (check-equal? (notes log) '(spawner-continues 0 1 2 3 4))))))

;; source: contract 2 rule 2, first sentence (spawner is a plain thread)
(test-case "task rule 2: spawn order holds when a non-task thread spawns behind a holder"
  (with-scheduler (s)
    (define log (make-recorder))
    (define holding (make-semaphore 0))
    (define release (make-semaphore 0))
    ;; The holder keeps the baton while it blocks on a plain sync.
    (define holder (spawn-task (lambda () (semaphore-post holding) (sync release))))
    (check-true (and (sync/timeout spec-timeout holding) #t))
    (define ts (for/list ([i (in-range 4)]) (spawn-task (lambda () (note! log i)))))
    (semaphore-post release)
    (for ([t (in-list ts)]) (check-eq? (sync/timeout spec-timeout t) t))
    (check-equal? (notes log) '(0 1 2 3))))

;; source: contract 2 rule 2, second sentence
(test-case "task rule 2: a task resuming from await queues behind tasks already waiting"
  (with-scheduler (s)
    (run-task
     (lambda ()
       (define log (make-recorder))
       (define sem (make-semaphore 0))
       (define parked (make-semaphore 0))
       (define a (spawn-task (lambda ()
                               (semaphore-post parked)
                               (await sem)
                               (note! log 'a-resumed))))
       (await parked)
       (define b (spawn-task (lambda () (note! log 'b))))
       (define c (spawn-task (lambda () (note! log 'c))))
       ;; b and c asked for the baton before a's event became ready.
       (semaphore-post sem)
       (await-all (list a b c))
       (check-equal? (notes log) '(b c a-resumed))))))

;; source: contract 2 rule 3 (task and evt cases; the fiber case is in fiber-spec-test.rkt)
(test-case "task rule 3: await returns task results and evt sync results"
  (with-scheduler (s)
    (run-task
     (lambda ()
       (define t (spawn-task (lambda () 'done)))
       (check-eq? (await t) 'done)
       (define ch (make-channel))
       (define sender (spawn-task (lambda () (await (channel-put-evt ch 'hello)))))
       (check-eq? (await ch) 'hello)
       (await sender)
       (check-eq? (await (wrap-evt always-evt (lambda (_) 'wrapped))) 'wrapped)
       (define failing (spawn-task (lambda () (raise-user-error "task failed"))))
       (check-exn #rx"task failed" (lambda () (await failing)))))))

;; source: contract 2 rule 3, "while waiting the baton is released" and
;; "returns only after the baton is reacquired"
(test-case "task rule 3: await releases the baton and returns holding it"
  (with-scheduler (s)
    (run-task
     (lambda ()
       (define log (make-recorder))
       (define sem (make-semaphore 0))
       (define a (spawn-task (lambda ()
                               (note! log 'a-waits)
                               (await sem)
                               (note! log (if (in-task?) 'a-resumed 'a-without-baton)))))
       (define b (spawn-task (lambda ()
                               (semaphore-post sem)
                               (note! log 'b-posted)
                               (spin)
                               (note! log 'b-end))))
       (await-all (list a b))
       (check-equal? (notes log) '(a-waits b-posted b-end a-resumed))))))

;; source: contract 2 rule 4, first sentence
(test-case "task rule 4: a break during await is raised from await under the baton"
  (with-scheduler (s)
    (run-task
     (lambda ()
       (define log (make-recorder))
       (define parked (make-semaphore 0))
       (define a (spawn-task
                  (lambda ()
                    (with-handlers ([exn:break? (lambda (e)
                                                  (note! log 'a-broken)
                                                  'recovered)])
                      (semaphore-post parked)
                      (await never)
                      'not-broken))))
       (await parked)
       (define b (spawn-task (lambda ()
                               (task-cancel! a)
                               (note! log 'b-cancelled)
                               (spin)
                               (note! log 'b-end))))
       (check-eq? (await a) 'recovered)
       (await b)
       (check-equal? (notes log) '(b-cancelled b-end a-broken))))))

;; source: contract 2 rule 4, "Breaks are disabled while a task holds the baton"
;; and "A break delivered while the task runs stays pending and is raised at
;; its next release point"; contract 12 addendum 1
(test-case "task rule 4: a break while the task runs stays pending until the next release point"
  (with-scheduler (s)
    (define log (make-recorder))
    (define running (make-semaphore 0))
    (define resume (make-semaphore 0))
    (define t
      (spawn-task
       (lambda ()
         (with-handlers ([exn:break? (lambda (e) (note! log 'raised-at-release) 'broken)])
           (semaphore-post running)
           ;; A plain sync is not a release point: the task keeps the baton.
           (sync resume)
           (note! log 'ran-past-the-break)
           (spin)
           (note! log 'still-running)
           (yield-task)
           (note! log 'not-broken)
           'finished))))
    (check-true (and (sync/timeout spec-timeout running) #t))
    (task-cancel! t)
    (semaphore-post resume)
    (define finished (sync/timeout spec-timeout t))
    (unless finished (task-kill! t))
    (check-eq? finished t)
    (when finished (check-eq? (task-result t) 'broken))
    (check-equal? (notes log) '(ran-past-the-break still-running raised-at-release))))

;; source: contract 2, "(task-check-break) -> void? ; raise a pending break now,
;; if any"; rule 4, last sentence; rule 1 (it is not among the release points);
;; contract 12 addendum 1
(test-case "task rule 4: task-check-break raises a pending break and never releases the baton"
  (define check-break (optional-binding 'cordis/task 'task-check-break))
  (check-true (procedure? check-break) "cordis/task must export task-check-break")
  (when (procedure? check-break)
    (with-scheduler (s)
      (define log (make-recorder))
      (define running (make-semaphore 0))
      (define resume (make-semaphore 0))
      (define t
        (spawn-task
         (lambda ()
           (define other (spawn-task (lambda () (note! log 'other-task))))
           ;; Nothing is pending: the call returns and `other` has not run.
           (note! log (check-break))
           (note! log 'no-break-pending)
           (await other)
           (with-handlers ([exn:break? (lambda (e) (note! log 'raised-by-check) (in-task?))])
             (semaphore-post running)
             (sync resume)
             (note! log 'before-check)
             (check-break)
             (note! log 'not-broken)
             'finished))))
      (check-true (and (sync/timeout spec-timeout running) #t))
      (task-cancel! t)
      (semaphore-post resume)
      (define finished (sync/timeout spec-timeout t))
      (unless finished (task-kill! t))
      (check-eq? finished t)
      ;; The handler's value is (in-task?): the break was raised under the baton.
      (when finished (check-eq? (task-result t) #t))
      (check-equal? (notes log)
                    (list (void) 'no-break-pending 'other-task 'before-check 'raised-by-check)))))

;; source: contract 2 rule 4, "kernel and plugin code between two awaits is
;; never interrupted. A task that never reaches a release point can only be
;; stopped with task-kill!"
(test-case "task rule 4: a task without a release point is stopped by task-kill! only"
  (with-scheduler (s)
    (define log (make-recorder))
    (define running (make-semaphore 0))
    (define stop (make-semaphore 0))
    (define left (make-semaphore 0))
    (define t
      (spawn-task
       (lambda ()
         (with-handlers ([exn:break? (lambda (e) (note! log 'interrupted) (raise e))])
           (semaphore-post running)
           (let loop () (unless (semaphore-try-wait? stop) (loop)))
           (note! log 'first-loop-ran-to-its-end)
           (semaphore-post left)
           (let forever () (forever))))))
    (check-true (and (sync/timeout spec-timeout running) #t))
    (task-cancel! t)
    (semaphore-post stop)
    ;; `left` is posted only if the pending break did not interrupt the first loop.
    (check-eq? (sync/timeout spec-timeout left t) left)
    (check-equal? (notes log) '(first-loop-ran-to-its-end))
    (task-kill! t)
    (check-eq? (sync/timeout spec-timeout t) t)
    (check-exn exn:fail:cordis:task-killed? (lambda () (task-result t)))
    (check-eq? (run-task (lambda () 'next-task-ran)) 'next-task-ran)))

;; source: contract 2 rule 5
(test-case "task rule 5: await outside a task is plain sync"
  (with-scheduler (s)
    (check-false (in-task?))
    (define ready (make-semaphore 1))
    (check-eq? (await (wrap-evt (semaphore-peek-evt ready) (lambda (_) 'synced))) 'synced)
    (define t (spawn-task (lambda () 'from-task)))
    (check-eq? (await t) 'from-task)
    (define failing (spawn-task (lambda () (raise-user-error "outside failure"))))
    (check-exn #rx"outside failure" (lambda () (await failing)))))

;; source: contract 2 rule 5, "it never touches the baton"
(test-case "task rule 5: await outside a task does not wait for the baton"
  (with-scheduler (s)
    (define holding (make-semaphore 0))
    (define release (make-semaphore 0))
    (define holder (spawn-task (lambda () (semaphore-post holding) (sync release) 'held)))
    (check-true (and (sync/timeout spec-timeout holding) #t))
    (define ready (make-semaphore 1))
    (define result (make-channel))
    (define outsider
      (thread (lambda ()
                (channel-put result (await (wrap-evt (semaphore-peek-evt ready)
                                                     (lambda (_) 'no-baton-needed)))))))
    (check-eq? (sync/timeout spec-timeout result) 'no-baton-needed)
    (semaphore-post release)
    (check-eq? (sync/timeout spec-timeout holder) holder)))

;; source: contract 2 rule 6, first sentence
(test-case "task rule 6: blocking runs outside the baton and propagates values and exceptions"
  (with-scheduler (s)
    (run-task
     (lambda ()
       (define log (make-recorder))
       (define gate (make-semaphore 0))
       (define outer-thread (current-thread))
       (define a (spawn-task
                  (lambda ()
                    (call-with-values
                     (lambda ()
                       (blocking (lambda ()
                                   (sync gate)
                                   (values (in-task?) (eq? (current-thread) outer-thread)))))
                     list))))
       ;; If `blocking` kept the baton, b could never run and open the gate.
       (define b (spawn-task (lambda () (note! log 'b-ran) (semaphore-post gate))))
       (check-equal? (await a) '(#f #f))
       (await b)
       (check-equal? (notes log) '(b-ran))
       (check-exn #rx"blocking failed"
                  (lambda () (blocking (lambda () (raise-user-error "blocking failed")))))))))

;; source: contract 2 rule 6, second sentence
(test-case "task rule 6: breaking the awaiting task breaks the helper thread"
  (with-scheduler (s)
    (run-task
     (lambda ()
       (define in-helper (make-semaphore 0))
       (define helper-broken (make-semaphore 0))
       (define a (spawn-task
                  (lambda ()
                    (blocking (lambda ()
                                (with-handlers ([exn:break? (lambda (e)
                                                              (semaphore-post helper-broken)
                                                              (raise e))])
                                  (semaphore-post in-helper)
                                  (sync never)))))))
       (await in-helper)
       (task-cancel! a)
       (await helper-broken)
       (define outcome
         (with-handlers ([exn:break? (lambda (e) 'break)]
                         [(lambda (e) #t) (lambda (e) e)])
           (await a)
           'no-exception))
       (check-eq? outcome 'break)))))

;; source: contract 2 rule 6, "killed if it has not finished within 1 second"
(test-case "task rule 6: a helper that ignores the break is killed"
  (with-scheduler (s)
    (run-task
     (lambda ()
       (define in-helper (make-semaphore 0))
       (define helper (box #f))
       (define a (spawn-task
                  (lambda ()
                    (blocking (lambda ()
                                (set-box! helper (current-thread))
                                (parameterize-break #f
                                  (semaphore-post in-helper)
                                  (sync never)))))))
       (await in-helper)
       (task-cancel! a)
       (check-true (and (await/timeout spec-timeout (thread-dead-evt (unbox helper))) #t))))))

;; source: contract 2 rule 7
(test-case "task rule 7: call-in-kernel spawns from a plain thread and calls directly in a task"
  (with-scheduler (s)
    (define main (current-thread))
    (check-equal? (call-with-values
                   (lambda ()
                     (call-in-kernel (lambda ()
                                       (values (in-task?) (eq? (current-thread) main)))))
                   list)
                  '(#t #f))
    (check-equal? (call-in-kernel (lambda () 'by-keyword) #:scheduler s) 'by-keyword)
    (check-exn #rx"kernel failure"
               (lambda () (call-in-kernel (lambda () (raise-user-error "kernel failure")))))
    (check-true
     (run-task
      (lambda ()
        (define me (current-thread))
        (call-in-kernel (lambda () (eq? (current-thread) me))))))))

;; source: contract 2 rule 8; analysis law 15 (kill safety)
(test-case "task rule 8: killing the baton holder or a waiter never blocks other tasks"
  (with-scheduler (s)
    (define holding (make-semaphore 0))
    (define holder (spawn-task (lambda () (semaphore-post holding) (sync never))))
    (check-true (and (sync/timeout spec-timeout holding) #t))
    (define dead-waiter (spawn-task (lambda () 'never-runs)))
    (define live (spawn-task (lambda () 'ran)))
    (task-kill! dead-waiter)
    (task-kill! holder)
    (check-eq? (sync/timeout spec-timeout live) live)
    (check-eq? (task-result live) 'ran)
    (check-eq? (sync/timeout spec-timeout holder) holder)
    (check-eq? (sync/timeout spec-timeout dead-waiter) dead-waiter)
    ;; source: contract 2, comment on task-kill!
    (check-exn exn:fail:cordis:task-killed? (lambda () (task-result holder)))
    (check-exn exn:fail:cordis:task-killed? (lambda () (task-result dead-waiter)))
    (check-exn exn:fail:cordis? (lambda () (task-result holder)))))

;; source: contract 2 rule 8 (a task killed while it waits in await)
(test-case "task rule 8: a task killed during await does not hold the queue"
  (with-scheduler (s)
    (run-task
     (lambda ()
       (define parked (make-semaphore 0))
       (define a (spawn-task (lambda () (semaphore-post parked) (await never))))
       (await parked)
       (task-kill! a)
       (define b (spawn-task (lambda () 'after-kill)))
       (check-eq? (await b) 'after-kill)
       (check-exn exn:fail:cordis:task-killed? (lambda () (task-result a)))))))

;; source: contract 2 rule 9, parameterization and custodian of task threads
(test-case "task rule 9: task threads inherit the spawner's parameterization and custodian"
  (with-scheduler (s)
    (define p (make-parameter 'default))
    (define cust (make-custodian))
    (define parked (make-semaphore 0))
    (define seen (box #f))
    (define t
      (parameterize ([p 'inherited] [current-custodian cust])
        (spawn-task (lambda ()
                      (set-box! seen (list (p)
                                           (eq? (current-custodian) cust)
                                           (eq? (current-scheduler) s)))
                      (semaphore-post parked)
                      (await never)))))
    (check-true (and (sync/timeout spec-timeout parked) #t))
    (check-equal? (unbox seen) '(inherited #t #t))
    ;; The task thread belongs to the spawner's custodian, not the scheduler's.
    (custodian-shutdown-all cust)
    (check-true (and (sync/timeout spec-timeout (thread-dead-evt (task-thread t))) #t))
    (check-eq? (run-task (lambda () 'scheduler-still-works)) 'scheduler-still-works)))

;; source: contract 2 rule 9, "the manager thread runs under the scheduler's
;; custodian"; contract 2, comment on scheduler-shutdown!
(test-case "task rule 9: after scheduler-shutdown! pending tasks never run"
  (define cust (make-custodian))
  (define s (make-scheduler #:name 'doomed #:custodian cust))
  (define holding (make-semaphore 0))
  (define ran? (box #f))
  ;; The task threads belong to `cust` too, so that the test leaves none behind.
  (define-values (holder pending)
    (parameterize ([current-custodian cust])
      (define holder
        (spawn-task (lambda () (semaphore-post holding) (sync never)) #:scheduler s))
      (check-true (and (sync/timeout spec-timeout holding) #t))
      (values holder (spawn-task (lambda () (set-box! ran? #t)) #:scheduler s))))
  (scheduler-shutdown! s)
  (task-kill! holder)
  ;; Nothing can make `pending` run now; the bounded wait only gives a wrong
  ;; implementation the chance to run it.
  (sync/timeout 0.05 pending)
  (check-false (unbox ran?))
  (custodian-shutdown-all cust))

;; source: contract 2 rule 10, first sentence; comment on await-all
(test-case "task rule 10: an escaped exception is stored and re-raised on each observation"
  (with-scheduler (s)
    (run-task
     (lambda ()
       (define t (spawn-task (lambda () (raise-user-error "stored failure"))))
       (check-exn #rx"stored failure" (lambda () (await t)))
       (check-exn #rx"stored failure" (lambda () (task-result t)))
       (check-true (task-done? t))))))

;; source: contract 2, comment on await-all
(test-case "task/await-all: results in order; the exception is raised after all settle"
  (with-scheduler (s)
    (run-task
     (lambda ()
       (define gate (make-semaphore 0))
       (define ok (list (spawn-task (lambda () (await gate) 'slow))
                        (spawn-task (lambda () 'fast))))
       (semaphore-post gate)
       (check-equal? (await-all ok) '(slow fast))
       (check-equal? (await-all '()) '())
       (define gate2 (make-semaphore 0))
       (define slow (spawn-task (lambda () (await gate2) 'slow-done)))
       (define bad (spawn-task (lambda () (raise-user-error "one failed"))))
       (define opener (spawn-task (lambda () (yield-task) (semaphore-post gate2))))
       (check-exn #rx"one failed" (lambda () (await-all (list bad slow))))
       (check-true (task-done? slow))
       (await opener)))))

;; source: contract 2 rule 10, "logged at error level ... at scheduler shutdown"
(test-case "task rule 10: an unobserved failure is logged at scheduler shutdown"
  (define-values (result logs)
    (capture-log
     (lambda ()
       (define cust (make-custodian))
       (define s (make-scheduler #:name 'unobserved #:custodian cust))
       (define t (spawn-task (lambda () (raise-user-error "nobody looked")) #:scheduler s))
       (sync/timeout spec-timeout (thread-dead-evt (task-thread t)))
       (scheduler-shutdown! s)
       (custodian-shutdown-all cust)
       'done)
     #:level 'error
     #:topic 'cordis))
  (check-eq? result 'done)
  (check-true (pair? logs) "expected an error-level log record on the cordis logger"))

;; source: contract 2 rule 11
(test-case "task rule 11: holding the baton past current-baton-warn-ms logs a warning"
  (define warn-ms (optional-binding 'cordis/task 'current-baton-warn-ms))
  (check-true (and warn-ms (parameter? warn-ms)) "cordis/task must export current-baton-warn-ms")
  (when warn-ms
    (check-equal? (warn-ms) 2000)
    (define (run-slow limit)
      (define-values (result logs)
        (capture-log
         (lambda ()
           (parameterize ([warn-ms limit])
             (with-scheduler (s)
               ;; `sleep` holds the baton here on purpose: the rule is about
               ;; the time between two release points.
               (define t (spawn-task (lambda () (sleep 0.05) 'held) #:name 'slowpoke))
               (define finished (sync/timeout spec-timeout t))
               ;; A second task makes the scheduler take the baton back from
               ;; `slowpoke` before the log is read.
               (run-task void)
               (and finished (task-result t)))))
         #:level 'warning
         #:topic 'cordis))
      (check-eq? result 'held)
      logs)
    (define (names-task? v)
      (regexp-match? #rx"slowpoke" (vector-ref v 1)))
    (check-true (and (memf names-task? (run-slow 1)) #t)
                "expected a warning that names the task")
    (check-false (memf names-task? (run-slow #f)) "#f disables the warning")))

;; source: contract 2, comments on yield-task and task-sleep
(test-case "task/yield-task and task-sleep: both go to the back of the queue"
  (with-scheduler (s)
    (run-task
     (lambda ()
       (define log (make-recorder))
       (define (stepper id pause)
         (lambda () (note! log (cons id 1)) (pause) (note! log (cons id 2))))
       (await-all (list (spawn-task (stepper 'a yield-task))
                        (spawn-task (stepper 'b yield-task))))
       (check-equal? (notes log) '((a . 1) (b . 1) (a . 2) (b . 2)))
       ;; d already waits for the baton when c goes to sleep.
       (define log2 (make-recorder))
       (await-all (list (spawn-task (lambda ()
                                      (note! log2 'c1)
                                      (task-sleep 0.001)
                                      (note! log2 'c2)))
                        (spawn-task (lambda () (note! log2 'd)))))
       (check-equal? (notes log2) '(c1 d c2))
       (check-equal? (yield-task) (void))
       (check-equal? (task-sleep 0) (void))))))

;; source: contract 2, signature of await/timeout
(test-case "task/await-timeout: returns the result or the on-timeout value"
  (with-scheduler (s)
    (run-task
     (lambda ()
       (check-eq? (await/timeout spec-timeout (wrap-evt always-evt (lambda (_) 'ready))) 'ready)
       (check-false (await/timeout 0.01 never))
       (check-eq? (await/timeout 0.01 never (lambda () 'timed-out)) 'timed-out)
       (define t (spawn-task (lambda () 'task-value)))
       (check-eq? (await/timeout spec-timeout t) 'task-value)))))

;; source: contract 2, signature of in-task?
(test-case "task/in-task?: true only in a task of the given scheduler"
  (with-scheduler (s)
    (check-false (in-task?))
    (check-false (in-task? s))
    (check-true (run-task (lambda () (in-task?))))
    (check-true (run-task (lambda () (in-task? s))))
    (with-scheduler (other)
      (check-false (parameterize ([current-scheduler s])
                     (run-task (lambda () (in-task? other))))))))
