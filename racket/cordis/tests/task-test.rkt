#lang racket/base
;; Tasks and the baton: contract section 2, rules 1 to 11, and law 15 (kill safety).
(require rackunit
         racket/list
         cordis
         cordis/testing
         "common.rkt")

;; ---------------------------------------------------------------------------------------
;; Rule 1: one task at a time, no descheduling between wait points

(test-case "rule 1: a task runs without interleaving until it waits"
  (define-values (note notes) (make-recorder))
  (call-with-scheduler
   (lambda ()
     (define (worker tag)
       (lambda ()
         (note (cons tag 'begin))
         ;; long enough for the thread scheduler to preempt the thread many times
         (for ([i (in-range 300000)]) (void))
         (note (cons tag 'end))))
     (await-all (for/list ([tag '(a b c)]) (spawn-task (worker tag))))))
  (check-equal? (notes)
                '((a . begin) (a . end) (b . begin) (b . end) (c . begin) (c . end))))

(test-case "rule 1: unsynchronized read-modify-write across tasks loses no update"
  (define counter 0)
  (call-with-scheduler
   (lambda ()
     (await-all
      (for/list ([i (in-range 8)])
        (spawn-task (lambda ()
                      (for ([j (in-range 2000)])
                        (when (zero? (modulo j 500)) (yield-task))
                        (define v counter)
                        (for ([n (in-range 50)]) (void))
                        (set! counter (add1 v)))))))))
  (check-equal? counter 16000))

(test-case "rule 1: yield-task goes to the back of the queue"
  (define-values (note notes) (make-recorder))
  (call-with-scheduler
   (lambda ()
     (define a (spawn-task (lambda () (note 'a1) (yield-task) (note 'a2))))
     (define b (spawn-task (lambda () (note 'b1) (yield-task) (note 'b2))))
     (await-all (list a b))))
  (check-equal? (notes) '(a1 b1 a2 b2)))

;; ---------------------------------------------------------------------------------------
;; Rule 2: spawn order and resume order

(test-case "rule 2: tasks spawned from a plain thread start in spawn order"
  (define-values (note notes) (make-recorder))
  (define cust (make-custodian))
  (define s (make-scheduler #:custodian cust))
  ;; hold the baton so that every request is queued before any task starts
  (define hold (make-semaphore 0))
  (define holder (spawn-task (lambda () (sync hold)) #:scheduler s))
  (define tasks
    (for/list ([i (in-range 50)])
      (spawn-task (lambda () (note i)) #:scheduler s)))
  (semaphore-post hold)
  (for ([t (in-list tasks)]) (sync/t t))
  (check-equal? (notes) (range 50))
  (custodian-shutdown-all cust))

(test-case "rule 2: tasks spawned from a task start in spawn order, after the spawner yields"
  (define-values (note notes) (make-recorder))
  (call-with-scheduler
   (lambda ()
     (define tasks (for/list ([i (in-range 20)]) (spawn-task (lambda () (note i)))))
     (note 'spawner)
     (await-all tasks)))
  (check-equal? (notes) (cons 'spawner (range 20))))

(test-case "rule 2: waiters of one task resume in the order in which they began to wait"
  (define-values (note notes) (make-recorder))
  (call-with-scheduler
   (lambda ()
     (define g (gate))
     (define source (spawn-task (lambda () (gate-wait g) 'done)))
     (define waiters
       (for/list ([i (in-range 10)])
         (spawn-task (lambda () (await source) (note i)))))
     ;; let every waiter reach its await before the source finishes
     (yield-task)
     (gate-open! g)
     (await-all waiters)))
  (check-equal? (notes) (range 10)))

(test-case "rule 2: a resumed waiter queues behind a task that was already waiting"
  (define-values (note notes) (make-recorder))
  (call-with-scheduler
   (lambda ()
     (define g (gate))
     (define sleeper (spawn-task (lambda () (gate-wait g) (note 'sleeper))))
     (yield-task)
     ;; `queued` asks for the baton now; `sleeper` asks only after its gate opens
     (define queued (spawn-task (lambda () (note 'queued))))
     (gate-open! g)
     (await-all (list sleeper queued))))
  (check-equal? (notes) '(queued sleeper)))

;; ---------------------------------------------------------------------------------------
;; Rule 3: await

(test-case "rule 3: await of a task returns its values; of an evt, its sync result"
  (call-with-scheduler
   (lambda ()
     (check-equal? (await (spawn-task (lambda () 42))) 42)
     (check-equal? (call-with-values (lambda () (await (spawn-task (lambda () (values 1 2)))))
                                     list)
                   '(1 2))
     (define sema (make-semaphore 1))
     (check-eq? (await sema) sema)
     (check-equal? (await (wrap-evt always-evt (lambda (_) 'wrapped))) 'wrapped)
     (check-equal? (task-result (spawn-task (lambda () 'direct))) 'direct))))

(test-case "rule 3: the baton is released while a task waits"
  (define-values (note notes) (make-recorder))
  (call-with-scheduler
   (lambda ()
     (define g (gate))
     (define waiter (spawn-task (lambda () (note 'wait) (gate-wait g) (note 'resumed))))
     (define other (spawn-task (lambda () (note 'other) (gate-open! g))))
     (await-all (list waiter other))))
  (check-equal? (notes) '(wait other resumed)))

(test-case "rule 3: await of something that is not awaitable is a contract error"
  (call-with-scheduler
   (lambda ()
     (check-exn exn:fail:contract? (lambda () (await 5))))))

;; ---------------------------------------------------------------------------------------
;; Rule 4: breaks

(test-case "rule 4: a break during await is raised only after the baton is reacquired"
  (define-values (note notes) (make-recorder))
  (define cust (make-custodian))
  (define s (make-scheduler #:custodian cust))
  (define waiting (make-semaphore 0))
  (define release (make-semaphore 0))
  (define holding (make-semaphore 0))
  (define victim
    (spawn-task (lambda ()
                  (with-handlers ([exn:break? (lambda (e) (note 'broken) (in-task?))])
                    (semaphore-post waiting)
                    (await (make-semaphore 0))))
                #:scheduler s))
  (sync/t waiting)
  ;; this task takes the baton and keeps it, without awaiting, until told to finish
  (define holder
    (spawn-task (lambda () (semaphore-post holding) (sync release) (note 'holder-done))
                #:scheduler s))
  (sync/t holding)
  (task-cancel! victim)
  (semaphore-post release)
  (sync/t victim)
  (check-equal? (task-result victim) #t)
  (check-equal? (notes) '(holder-done broken))
  (custodian-shutdown-all cust))

(test-case "rule 4: a break while the task runs stays pending until its next release point"
  (define-values (note notes) (make-recorder))
  (define cust (make-custodian))
  (define s (make-scheduler #:custodian cust))
  (define started (make-semaphore 0))
  (define go (make-semaphore 0))
  (define t
    (spawn-task (lambda ()
                  (with-handlers ([exn:break? (lambda (e) (note 'broken) (in-task?))])
                    (semaphore-post started)
                    ;; a plain `sync` keeps the baton: the task counts as running
                    (sync go)
                    (note 'ran-on)
                    (for ([i (in-range 100000)]) (void))
                    (note 'still-running)
                    (yield-task)
                    (note 'unreached)))
                #:scheduler s))
  (sync/t started)
  (task-cancel! t)
  (semaphore-post go)
  (sync/t t)
  (check-equal? (task-result t) #t)
  (check-equal? (notes) '(ran-on still-running broken))
  (custodian-shutdown-all cust))

(test-case "rule 4: every release point raises a pending break"
  (define (broken-at release-point)
    (call-with-scheduler
     (lambda ()
       (define done (spawn-task void))
       (await done)
       (define t
         (spawn-task (lambda ()
                       (break-thread (current-thread))
                       (with-handlers ([exn:break? (lambda (e) 'broken)])
                         (release-point done)
                         'not-broken))))
       (await/t t))))
  (check-equal? (broken-at (lambda (done) (await (make-semaphore 1)))) 'broken)
  (check-equal? (broken-at (lambda (done) (await done))) 'broken)
  (check-equal? (broken-at (lambda (done) (await-all (list done)))) 'broken)
  (check-equal? (broken-at (lambda (done) (await/timeout patience done))) 'broken)
  (check-equal? (broken-at (lambda (done) (yield-task))) 'broken)
  (check-equal? (broken-at (lambda (done) (task-sleep 0))) 'broken)
  (check-equal? (broken-at (lambda (done) (blocking void))) 'broken)
  (check-equal? (broken-at (lambda (done) (task-result (spawn-task void)))) 'broken)
  (check-equal? (broken-at (lambda (done) (task-check-break))) 'broken)
  ;; reading the result of a finished task is not a release point
  (check-equal? (broken-at (lambda (done) (task-result done))) 'not-broken))

(test-case "rule 4: task-check-break returns when no break is pending"
  (call-with-scheduler
   (lambda ()
     (check-equal? (task-check-break) (void))))
  ;; outside a task, with breaks enabled, nothing can be pending
  (check-equal? (task-check-break) (void)))

(test-case "rule 4: a task that reaches no release point is stopped only by task-kill!"
  (define cust (make-custodian))
  (define s (make-scheduler #:custodian cust))
  (define started (make-semaphore 0))
  (define release (make-semaphore 0))
  (define passed (make-semaphore 0))
  (define spinner
    (spawn-task (lambda ()
                  (semaphore-post started)
                  ;; holds the baton, breaks stay pending
                  (sync release)
                  (semaphore-post passed)
                  (let loop () (loop)))
                #:scheduler s))
  (define next (spawn-task (lambda () 'next) #:scheduler s))
  (sync/t started)
  (task-cancel! spinner)
  (semaphore-post release)
  ;; the break did not end the plain wait, nor the code after it
  (sync/t passed)
  (check-false (task-done? spinner))
  (check-false (task-done? next))
  (task-kill! spinner)
  (sync/t spinner)
  (check-exn exn:fail:cordis:task-killed? (lambda () (task-result spinner)))
  (check-equal? (begin (sync/t next) (task-result next)) 'next)
  (custodian-shutdown-all cust))

(test-case "rule 4: code that masks breaks waits without being interrupted"
  (define (survives-cancel body)
    (define cust (make-custodian))
    (define s (make-scheduler #:custodian cust))
    (define waiting (make-semaphore 0))
    (define go (make-semaphore 0))
    (define holding (make-semaphore 0))
    (define release (make-semaphore 0))
    (define completed? #f)
    (define t
      (spawn-task (lambda ()
                    (body (lambda ()
                            (semaphore-post waiting)
                            (await go)
                            (set! completed? #t))))
                  #:scheduler s))
    (sync/t waiting)
    ;; while another task holds the baton, the break cannot be overtaken by the wake-up
    (spawn-task (lambda () (semaphore-post holding) (sync release)) #:scheduler s)
    (sync/t holding)
    (task-cancel! t)
    (semaphore-post go)
    (semaphore-post release)
    (sync/t t)
    (custodian-shutdown-all cust)
    completed?)
  (check-true (survives-cancel (lambda (wait) (parameterize-break #f (wait)))))
  (check-true (survives-cancel
               (lambda (wait)
                 (with-handlers ([symbol? (lambda (e) (wait))]) (raise 'to-the-handler)))))
  (check-true (survives-cancel (lambda (wait) (dynamic-wind void void wait))))
  (check-true (survives-cancel (lambda (wait) (dynamic-wind wait void void))))
  ;; without a mask the same wait is interrupted
  (check-false (survives-cancel (lambda (wait) (wait))))
  (check-false (survives-cancel (lambda (wait) (dynamic-wind void wait void))))
  (check-false (survives-cancel
                (lambda (wait)
                  (parameterize ([current-output-port (current-output-port)]) (wait)))))
  ;; a mask ends with its extent: the break is raised at the next release point after it
  (check-false (survives-cancel
                (lambda (wait)
                  (parameterize-break #f
                    (void))
                  (wait)))))

(test-case "rule 4: a break masked during one wait is raised at the next unmasked one"
  (define-values (note notes) (make-recorder))
  (define cust (make-custodian))
  (define s (make-scheduler #:custodian cust))
  (define waiting (make-semaphore 0))
  (define go (make-semaphore 0))
  (define t
    (spawn-task (lambda ()
                  (with-handlers ([exn:break? (lambda (e) (note 'broken))])
                    (parameterize-break #f
                      (semaphore-post waiting)
                      (await go)
                      (note 'masked-wait-done))
                    (note 'after-mask)
                    (yield-task)
                    (note 'unreached)))
                #:scheduler s))
  (sync/t waiting)
  (task-cancel! t)
  (semaphore-post go)
  (sync/t t)
  (check-equal? (notes) '(masked-wait-done after-mask broken))
  (custodian-shutdown-all cust))

;; ---------------------------------------------------------------------------------------
;; Rule 5: await outside a task

(test-case "rule 5: await outside a task is plain sync and never touches a baton"
  (check-false (in-task?))
  (define sema (make-semaphore 1))
  (check-eq? (await sema) sema)
  (define cust (make-custodian))
  (define s (make-scheduler #:custodian cust))
  (check-equal? (await (spawn-task (lambda () 'from-task) #:scheduler s)) 'from-task)
  (check-equal? (await/timeout 0.01 (make-semaphore 0) (lambda () 'timed-out)) 'timed-out)
  (check-equal? (await-all (list (spawn-task (lambda () 1) #:scheduler s)
                                 (wrap-evt always-evt (lambda (_) 2))))
                '(1 2))
  (yield-task)
  (task-sleep 0)
  (check-equal? (blocking (lambda () 'direct)) 'direct)
  (custodian-shutdown-all cust))

;; ---------------------------------------------------------------------------------------
;; await/timeout, await-all, task-sleep

(test-case "await/timeout: value in time, on-timeout otherwise"
  (call-with-scheduler
   (lambda ()
     (check-equal? (await/timeout patience (spawn-task (lambda () 'fast))) 'fast)
     (check-false (await/timeout 0.01 (make-semaphore 0)))
     (define stuck (spawn-task (lambda () (await (make-semaphore 0)))))
     (check-equal? (await/timeout 0.01 stuck (lambda () 'late)) 'late)
     (task-kill! stuck)
     (check-equal? (task-sleep 0.001) (void)))))

(test-case "await-all: results in order; the first failure is raised after all settled"
  (call-with-scheduler
   (lambda ()
     (define g (gate))
     (define ok (spawn-task (lambda () 1)))
     (define bad (spawn-task (lambda () (raise-user-error "first failure"))))
     (define worse (spawn-task (lambda () (raise-user-error "second failure"))))
     (define slow (spawn-task (lambda () (gate-wait g) 4)))
     (define opener (spawn-task (lambda () (yield-task) (yield-task) (gate-open! g))))
     (check-exn #rx"first failure" (lambda () (await-all (list ok bad worse slow))))
     (check-true (task-done? slow))
     (check-equal? (await-all (list ok slow opener (wrap-evt always-evt (lambda (_) 'evt))))
                   (list 1 4 (void) 'evt)))))

;; ---------------------------------------------------------------------------------------
;; Rule 6: blocking

(test-case "rule 6: blocking runs outside the baton and propagates values and exceptions"
  (define-values (note notes) (make-recorder))
  (call-with-scheduler
   (lambda ()
     (define g (make-semaphore 0))
     (define other (spawn-task (lambda () (note 'other-ran) (semaphore-post g))))
     ;; the helper can only finish if `other` gets the baton meanwhile
     (check-equal? (blocking (lambda () (sync g) (in-task?))) #f)
     (check-equal? (call-with-values (lambda () (blocking (lambda () (values 1 2)))) list)
                   '(1 2))
     (check-exn #rx"helper failed"
                (lambda () (blocking (lambda () (raise-user-error "helper failed")))))
     (await other)))
  (check-equal? (notes) '(other-ran)))

(test-case "rule 6: a break of the waiting task breaks the helper thread"
  (define cust (make-custodian))
  (define s (make-scheduler #:custodian cust))
  (define helper-started (make-semaphore 0))
  (define helper-broken (make-semaphore 0))
  (define t
    (spawn-task (lambda ()
                  (blocking (lambda ()
                              (with-handlers ([exn:break? (lambda (e)
                                                            (semaphore-post helper-broken))])
                                (semaphore-post helper-started)
                                (sync (make-semaphore 0))))))
                #:scheduler s))
  (sync/t helper-started)
  (task-cancel! t)
  (sync/t helper-broken)
  (sync/t t)
  (check-exn exn:break? (lambda () (task-result t)))
  (custodian-shutdown-all cust))

(test-case "rule 6: a helper that ignores the break is killed"
  (define cust (make-custodian))
  (define s (make-scheduler #:custodian cust))
  (define helper (box #f))
  (define helper-started (make-semaphore 0))
  (define t
    (spawn-task (lambda ()
                  (blocking (lambda ()
                              (set-box! helper (current-thread))
                              (parameterize-break #f
                                (semaphore-post helper-started)
                                (sync (make-semaphore 0))))))
                #:scheduler s))
  (sync/t helper-started)
  (task-cancel! t)
  (sync/t t)
  (check-true (and (sync/timeout patience (thread-dead-evt (unbox helper))) #t))
  (custodian-shutdown-all cust))

;; ---------------------------------------------------------------------------------------
;; Rule 7: call-in-kernel

(test-case "rule 7: call-in-kernel from a plain thread runs a task and returns its result"
  (define cust (make-custodian))
  (define s (make-scheduler #:custodian cust))
  (define outer (current-thread))
  (check-equal? (call-in-kernel (lambda () (list (in-task? s) (eq? (current-thread) outer)))
                                #:scheduler s)
                '(#t #f))
  (check-equal? (call-with-values (lambda () (call-in-kernel (lambda () (values 1 2))
                                                             #:scheduler s))
                                  list)
                '(1 2))
  (check-exn #rx"kernel failure"
             (lambda () (call-in-kernel (lambda () (raise-user-error "kernel failure"))
                                        #:scheduler s)))
  (parameterize ([current-scheduler s])
    (check-equal? (call-in-kernel (lambda () 'by-parameter)) 'by-parameter))
  (custodian-shutdown-all cust))

(test-case "rule 7: call-in-kernel inside a task of the scheduler calls the thunk directly"
  (call-with-scheduler
   (lambda ()
     (define me (current-thread))
     (check-true (call-in-kernel (lambda () (eq? (current-thread) me)))))))

(test-case "rule 7: call-in-kernel without a scheduler is a contract error"
  (check-exn exn:fail:contract? (lambda () (call-in-kernel void))))

;; ---------------------------------------------------------------------------------------
;; Rule 8 and law 15: kill safety

(test-case "rule 8 / law 15: killing the baton holder releases the baton"
  (define cust (make-custodian))
  (define s (make-scheduler #:custodian cust))
  (define running (make-semaphore 0))
  (define holder (spawn-task (lambda () (semaphore-post running) (let loop () (loop)))
                             #:scheduler s))
  (define next (spawn-task (lambda () 'survivor) #:scheduler s))
  (sync/t running)
  (task-kill! holder)
  (sync/t next)
  (check-equal? (task-result next) 'survivor)
  (check-true (task-done? holder))
  (check-exn exn:fail:cordis:task-killed? (lambda () (task-result holder)))
  (custodian-shutdown-all cust))

(test-case "rule 8 / law 15: dead waiters are skipped"
  (define cust (make-custodian))
  (define s (make-scheduler #:custodian cust))
  (define hold (make-semaphore 0))
  (define holding (make-semaphore 0))
  (define holder (spawn-task (lambda () (semaphore-post holding) (sync hold)) #:scheduler s))
  (sync/t holding)
  (define doomed (for/list ([i (in-range 5)]) (spawn-task (lambda () 'never) #:scheduler s)))
  (define last-one (spawn-task (lambda () 'ran) #:scheduler s))
  (for-each task-kill! doomed)
  (semaphore-post hold)
  (sync/t last-one)
  (check-equal? (task-result last-one) 'ran)
  (for ([t (in-list doomed)])
    (check-exn exn:fail:cordis:task-killed? (lambda () (task-result t))))
  (custodian-shutdown-all cust))

(test-case "rule 8 / law 15: killing a task at any wait point leaves the others running"
  (call-with-scheduler
   (lambda ()
     (define g (gate))
     (define source (spawn-task (lambda () (gate-wait g) 'source)))
     (define in-await (spawn-task (lambda () (await (make-semaphore 0)))))
     (define in-task-wait (spawn-task (lambda () (await source))))
     (define in-sleep (spawn-task (lambda () (task-sleep 3600))))
     (define in-blocking (spawn-task (lambda () (blocking (lambda () (sync (make-semaphore 0)))))))
     (define in-yield (spawn-task (lambda () (let loop () (yield-task) (loop)))))
     (yield-task)
     (yield-task)
     (for-each task-kill! (list in-await in-task-wait in-sleep in-blocking in-yield))
     (gate-open! g)
     (check-equal? (await source) 'source)
     (check-equal? (await (spawn-task (lambda () 'still-running))) 'still-running)
     ;; a waiter of a killed task learns that it was killed
     (check-exn exn:fail:cordis:task-killed? (lambda () (await in-await))))))

(test-case "law 15: random kills never stop the scheduler"
  (define cust (make-custodian))
  (define s (make-scheduler #:custodian cust))
  (define rng (make-pseudo-random-generator))
  (parameterize ([current-pseudo-random-generator rng])
    (random-seed 20261113)
    (for ([round (in-range 30)])
      (define tasks
        (for/list ([i (in-range 6)])
          (spawn-task (lambda ()
                        (for ([j (in-range 20)])
                          (case (modulo (+ i j) 3)
                            [(0) (yield-task)]
                            [(1) (await (wrap-evt always-evt void))]
                            [else (for ([n (in-range 200)]) (void))])))
                      #:scheduler s)))
      (for ([t (in-list tasks)] #:when (zero? (random 2)))
        (task-kill! t))
      (define probe (spawn-task (lambda () round) #:scheduler s))
      (check-equal? (sync/t (wrap-evt probe task-result)) round)))
  (custodian-shutdown-all cust))

;; ---------------------------------------------------------------------------------------
;; Rule 9: custodians and parameterizations

(define a-parameter (make-parameter 'default))

(test-case "rule 9: a task inherits the spawner's parameterization and custodian"
  (define sched-cust (make-custodian))
  (define s (make-scheduler #:custodian sched-cust))
  (define task-cust (make-custodian))
  (define g (make-semaphore 0))
  (define seen (box #f))
  (define t
    (parameterize ([a-parameter 'inherited] [current-custodian task-cust])
      (spawn-task (lambda ()
                    (set-box! seen (list (a-parameter)
                                         (eq? (current-custodian) task-cust)
                                         (eq? (current-scheduler) s)))
                    (await g))
                  #:scheduler s)))
  (check-true (thread? (task-thread t)))
  (sync/t (wrap-evt (spawn-task void #:scheduler s) void))
  (check-equal? (unbox seen) '(inherited #t #t))
  ;; the task's thread belongs to the spawner's custodian, not to the scheduler's
  (custodian-shutdown-all task-cust)
  (sync/t t)
  (check-exn exn:fail:cordis:task-killed? (lambda () (task-result t)))
  (check-equal? (sync/t (wrap-evt (spawn-task (lambda () 'alive) #:scheduler s) task-result))
                'alive)
  (custodian-shutdown-all sched-cust))

(test-case "rule 9: the manager belongs to the scheduler's custodian"
  (define cust (make-custodian))
  (define s (make-scheduler #:name 'doomed #:custodian cust))
  (check-equal? (call-in-kernel (lambda () 'before) #:scheduler s) 'before)
  (custodian-shutdown-all cust)
  (check-exn exn:fail:cordis? (lambda () (spawn-task void #:scheduler s))))

(test-case "scheduler-shutdown!: pending tasks never run; later spawns raise"
  (define cust (make-custodian))
  (define s (make-scheduler #:custodian cust))
  (define waiting (make-semaphore 0))
  (define go (make-semaphore 0))
  (define resumed? #f)
  (define t (spawn-task (lambda () (semaphore-post waiting) (await go) (set! resumed? #t))
                        #:scheduler s))
  (sync/t waiting)
  (scheduler-shutdown! s)
  (scheduler-shutdown! s)
  (semaphore-post go)
  (check-false (sync/timeout 0.05 t))
  (check-false resumed?)
  (check-exn exn:fail:cordis? (lambda () (spawn-task void #:scheduler s)))
  (check-exn exn:fail:cordis? (lambda () (call-in-kernel void #:scheduler s)))
  (custodian-shutdown-all cust))

;; ---------------------------------------------------------------------------------------
;; Rule 10: failures

(test-case "rule 10: a failure is stored and re-raised by task-result and await"
  (call-with-scheduler
   (lambda ()
     (define t (spawn-task (lambda () (raise-user-error "stored failure"))))
     (check-exn #rx"stored failure" (lambda () (await t)))
     (check-exn #rx"stored failure" (lambda () (task-result t)))
     (check-true (task-done? t))
     (define non-exn (spawn-task (lambda () (raise 'a-symbol))))
     (check-equal? (with-handlers ([symbol? values]) (await non-exn)) 'a-symbol))))

(test-case "rule 10: an unobserved failure is logged at scheduler shutdown, an observed one is not"
  (define cust (make-custodian))
  (define s (make-scheduler #:custodian cust))
  (define unobserved (spawn-task (lambda () (raise-user-error "nobody saw this")) #:scheduler s))
  (define observed (spawn-task (lambda () (raise-user-error "somebody saw this"))
                               #:scheduler s))
  (sync/t unobserved)
  (sync/t observed)
  (check-exn #rx"somebody saw this" (lambda () (task-result observed)))
  (define-values (_ events) (capture-log (lambda () (scheduler-shutdown! s))))
  (check-equal? (length events) 1)
  (check-eq? (vector-ref (car events) 0) 'error)
  (check-regexp-match #rx"nobody saw this" (vector-ref (car events) 1))
  (check-pred exn:fail:user? (vector-ref (car events) 2))
  (custodian-shutdown-all cust))

(test-case "rule 10: an unobserved failure is logged when the task is collected"
  (define cust (make-custodian))
  (define s (make-scheduler #:custodian cust))
  (define receiver (make-log-receiver cordis-logger 'error 'cordis))
  ;; the failing task is reachable only inside this procedure
  (define (spawn-and-forget)
    (sync/t (wrap-evt (spawn-task (lambda () (raise-user-error "collected failure"))
                                  #:scheduler s)
                      void)))
  (spawn-and-forget)
  (define event
    (let loop ([tries 0])
      (collect-garbage)
      (or (sync/timeout 0.1 receiver)
          (and (< tries 100) (loop (add1 tries))))))
  (check-true (and event (regexp-match? #rx"collected failure" (vector-ref event 1))))
  (custodian-shutdown-all cust))

;; ---------------------------------------------------------------------------------------
;; Rule 11: baton hold warning

(test-case "rule 11: holding the baton past the threshold logs a warning naming the task"
  (define cust (make-custodian))
  (define s (make-scheduler #:custodian cust))
  (define-values (_ events)
    (capture-log
     (lambda ()
       (parameterize ([current-baton-warn-ms 1])
         ;; `sleep` blocks the thread without releasing the baton
         (sync/t (wrap-evt (spawn-task (lambda () (sleep 0.1)) #:name 'baton-hog #:scheduler s)
                           void))))
     #:level 'warning))
  (check-equal? (length events) 1)
  (check-eq? (vector-ref (car events) 0) 'warning)
  (check-regexp-match #rx"baton-hog" (vector-ref (car events) 1))
  (custodian-shutdown-all cust))

(test-case "rule 11: #f disables the warning, and waiting does not count as holding"
  (define cust (make-custodian))
  (define s (make-scheduler #:custodian cust))
  (define-values (_ events)
    (capture-log
     (lambda ()
       (parameterize ([current-baton-warn-ms #f])
         (sync/t (wrap-evt (spawn-task (lambda () (sleep 0.05)) #:scheduler s) void)))
       ;; The task waits longer than the threshold but holds the baton only for the instants
       ;; before and after the wait. The threshold is far above any pause of the machine.
       (parameterize ([current-baton-warn-ms 250])
         (define waiting (make-semaphore 0))
         (define go (make-semaphore 0))
         (define t (spawn-task (lambda () (semaphore-post waiting) (await go)) #:scheduler s))
         (sync/t waiting)
         (sync/timeout 0.3 never-evt)
         (semaphore-post go)
         (sync/t t)))
     #:level 'warning))
  (check-equal? events '())
  (check-equal? (current-baton-warn-ms) 2000)
  (custodian-shutdown-all cust))

;; ---------------------------------------------------------------------------------------
;; Tasks as values

(test-case "a task is an evt whose result is the task; predicates and accessors"
  (define cust (make-custodian))
  (define s (make-scheduler #:custodian cust))
  (check-true (scheduler? s))
  (check-false (scheduler? 's))
  (define g (make-semaphore 0))
  (define t (spawn-task (lambda () (await g) 'value) #:scheduler s))
  (check-true (task? t))
  (check-false (task? g))
  (check-false (task-done? t))
  (check-false (sync/timeout 0 t))
  (semaphore-post g)
  (check-eq? (sync/t t) t)
  (check-true (task-done? t))
  (check-equal? (task-result t) 'value)
  (check-false (current-scheduler))
  (check-exn exn:fail:contract? (lambda () (spawn-task void)))
  (custodian-shutdown-all cust))
