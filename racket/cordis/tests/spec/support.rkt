#lang racket/base
;; Helpers shared by the black-box specification suite in this directory.
;; They use only the public modules cordis, cordis/task and cordis/testing, so
;; the suite checks docs/racket/contracts/cordis-kernel.md and the vendored
;; TypeScript semantics, not one implementation.
;;
;; Every wait in the suite is bounded: kernel tests run inside `with-root`
;; (call-with-root-context with #:timeout) and task tests wait with
;; sync/timeout. A timeout value is only a failure bound; no test outcome
;; depends on how long anything takes.
(require cordis
         cordis/testing
         rackunit
         racket/list)

(provide spec-timeout
         with-root
         with-scheduler
         run-task
         call-bounded
         make-gate gate-open! gate-wait
         make-recorder note! notes
         settle settle-all busy? yield-times yield-until
         make-spawner
         raises?
         labels-of
         comparable
         optional-binding
         unset?)

;; Upper bound in seconds for one test body.
(define spec-timeout 30)

;; Gates created while a `with-root` body runs; all are opened when it exits so
;; that a failed check cannot leave a disposer blocked during shutdown.
(define current-gates (make-parameter #f))

;; A gate is a semaphore used as a latch: closed until `gate-open!`.
(define (make-gate)
  (define g (make-semaphore 0))
  (define registry (current-gates))
  (when registry (set-box! registry (cons g (unbox registry))))
  g)

(define (gate-open! g) (semaphore-post g))

;; Waits for the gate from a task (releases the baton) or from a plain thread.
(define (gate-wait g)
  (await (semaphore-peek-evt g))
  (void))

;; Runs `proc` with a fresh root context as a task, bounded by `spec-timeout`.
;; `current-scheduler` is the root's scheduler in the body, so `spawn-task`
;; there needs no #:scheduler; code that runs in kernel-created tasks (plugin
;; bodies, inverses, listeners) passes the scheduler explicitly.
(define (call-with-root proc)
  (define gates (box '()))
  (call-with-root-context
   (lambda (ctx)
     (parameterize ([current-gates gates]
                    [current-scheduler (context-scheduler ctx)])
       (dynamic-wind
        void
        (lambda () (proc ctx))
        (lambda () (for ([g (in-list (unbox gates))]) (semaphore-post g))))))
   #:timeout spec-timeout))

(define-syntax-rule (with-root (ctx) body ...)
  (call-with-root (lambda (ctx) body ...)))

;; Runs `proc` in the calling (non-task) thread with a fresh scheduler that is
;; the value of `current-scheduler`; shuts the scheduler and its custodian down.
(define (call-with-fresh-scheduler proc)
  (define cust (make-custodian))
  (define s (make-scheduler #:name 'spec #:custodian cust))
  (dynamic-wind
   void
   (lambda ()
     (parameterize ([current-custodian cust]
                    [current-scheduler s])
       (proc s)))
   (lambda ()
     (scheduler-shutdown! s)
     (custodian-shutdown-all cust))))

(define-syntax-rule (with-scheduler (s) body ...)
  (call-with-fresh-scheduler (lambda (s) body ...)))

;; Spawns `thunk` on the current scheduler from a non-task thread and returns
;; its result; raises if it does not finish within `secs`.
(define (run-task thunk #:timeout [secs spec-timeout])
  (define t (spawn-task thunk #:name 'spec-main))
  (unless (sync/timeout secs t)
    (task-kill! t)
    (error 'run-task "task did not finish within ~a s" secs))
  (task-result t))

;; Calls `thunk` on a plain thread, which is not a task, and returns its
;; values or re-raises what it raised; raises if it does not return within
;; `secs`. For operations that a test must make from outside every task.
(define (call-bounded thunk #:timeout [secs spec-timeout])
  (define outcome #f)
  (define worker
    (thread (lambda ()
              (set! outcome
                    (with-handlers ([(lambda (e) #t) (lambda (e) (cons 'raised e))])
                      (call-with-values thunk (lambda vs (cons 'values vs))))))))
  (unless (sync/timeout secs worker)
    (kill-thread worker)
    (error 'call-bounded "no result within ~a s" secs))
  (if (eq? (car outcome) 'raised)
      (raise (cdr outcome))
      (apply values (cdr outcome))))

;; A recorder collects observations made inside plugin bodies, listeners and
;; inverses, where a failing check would be swallowed by kernel containment.
(define (make-recorder) (box '()))
(define (note! r v) (set-box! r (cons v (unbox r))))
(define (notes r) (reverse (unbox r)))

;; #t while a transition is in flight.
(define (busy? f)
  (and (memq (fiber-state f) '(loading unloading)) #t))

;; Waits until `f` has no transition in flight. Unlike `fiber-await` it does not
;; raise the recorded error of a failed fiber.
(define (settle f)
  (await (wrap-evt f void))
  (void))

(define (yield-times n)
  (for ([_ (in-range n)]) (yield-task)))

;; Yields until `pred` holds, at most `limit` times; returns whether it holds.
(define (yield-until pred [limit 200])
  (let loop ([n 0])
    (cond [(pred) #t]
          [(>= n limit) #f]
          [else (yield-task) (loop (add1 n))])))

;; Waits until none of `fs` has a transition in flight, including transitions
;; started by the completion of earlier ones.
(define (settle-all fs)
  (let loop ([rounds 0])
    (when (> rounds 100000)
      (error 'settle-all "fibers did not reach quiescence"))
    (yield-times 2)
    (define busy (filter busy? fs))
    (unless (null? busy)
      (for-each settle busy)
      (loop (add1 rounds)))))

;; Returns a procedure that spawns a thunk as a task on `ctx`'s scheduler under
;; the custodian that is current when `make-spawner` is called, which is the
;; test body's. A task spawned from a plugin body, an effect thunk, an inverse
;; or a listener otherwise belongs to the custodian of the fiber whose code is
;; running (contract 2 rule 9, ADR 0004) and is killed when that fiber unloads,
;; which a task that waits for that unload must survive.
(define (make-spawner ctx)
  (define cust (current-custodian))
  (define sched (context-scheduler ctx))
  (lambda (thunk)
    (parameterize ([current-custodian cust])
      (spawn-task thunk #:scheduler sched))))

;; Predicate for check-exn: exception kind and message.
(define ((raises? pred rx) e)
  (and (pred e) (regexp-match? rx (exn-message e))))

;; Labels of the top-level effects a fiber currently owns.
(define (labels-of f)
  (map disposer-label (fiber-effects f)))

;; A form of a kernel-snapshot, or of any nested value, for comparison between
;; two roots or two schedules. Hash entries and lists are sorted and symbols
;; are replaced by their names, so that neither creation order nor the
;; identity of uninterned realm symbols decides the comparison.
(define (comparable v)
  (define (repr x) (format "~s" x))
  (cond [(hash? v)
         (sort (for/list ([(k x) (in-hash v)]) (cons (repr k) (comparable x)))
               string<?
               #:key repr)]
        [(list? v) (sort (map comparable v) string<? #:key repr)]
        [(pair? v) (cons (comparable (car v)) (comparable (cdr v)))]
        [(vector? v) (comparable (vector->list v))]
        [(symbol? v) (symbol->string v)]
        [else v]))

;; A binding that the contract names only in prose, or that contract section
;; 12 added after the first implementation started. #f when the module does not
;; export it, so that one missing name fails one test case, not a file.
(define (optional-binding mod name)
  (dynamic-require mod name (lambda () #f)))

;; The contract does not say whether an unset optional value reads as #f or
;; void; both are accepted where TypeScript has `undefined`.
(define (unset? v)
  (or (not v) (void? v)))
