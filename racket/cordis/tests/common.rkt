#lang racket/base
;; Shared helpers for the kernel's own tests: bounded waits and a recorder for the order in
;; which things happen. Nothing here sleeps to let something happen; a wait ends when its
;; event is ready or fails after `patience` seconds.
(require rackunit
         cordis)

(provide patience
         sync/t await/t
         call-with-scheduler
         make-recorder
         gate gate-open! gate-wait
         check-exn-message)

(define patience 10)

;; `sync` that fails the test instead of hanging. Returns the first synchronization value.
(define (sync/t evt)
  (define timeout (string->uninterned-symbol "timeout"))
  (define v (sync/timeout patience
                          (wrap-evt evt (lambda vs (if (null? vs) (void) (car vs))))
                          (wrap-evt never-evt void)))
  (define r (if v v (sync/timeout 0 (wrap-evt evt (lambda vs timeout)))))
  (when (and (not v) (not r))
    (error 'sync/t "nothing happened within ~a seconds" patience))
  v)

;; `await` that fails the test instead of hanging.
(define (await/t x)
  (await/timeout patience x
                 (lambda () (error 'await/t "nothing happened within ~a seconds" patience))))

;; Runs (proc) as a task of a fresh scheduler under a fresh custodian and returns its
;; values. `current-scheduler` is the new scheduler inside.
(define (call-with-scheduler proc)
  (define cust (make-custodian))
  (dynamic-wind
   void
   (lambda ()
     (parameterize ([current-custodian cust])
       (define s (make-scheduler #:custodian cust))
       (parameterize ([current-scheduler s])
         (define t (spawn-task proc))
         (unless (sync/timeout patience t)
           (error 'call-with-scheduler "no result within ~a seconds" patience))
         (task-result t))))
   (lambda () (custodian-shutdown-all cust))))

;; (define-values (note notes) (make-recorder)): `note` appends a value, `notes` returns
;; what was recorded so far, in order.
(define (make-recorder)
  (define items '())
  (values (lambda (x) (set! items (cons x items)))
          (lambda () (reverse items))))

;; A gate is a semaphore used as a one-shot signal that stays open.
(define (gate) (make-semaphore 0))
(define (gate-open! g) (semaphore-post g))
(define (gate-wait g) (await/t (semaphore-peek-evt g)) (void))

(define-check (check-exn-message pred rx thunk)
  (with-handlers ([(lambda (e) #t)
                   (lambda (e)
                     (unless (pred e)
                       (with-check-info (['raised e])
                         (fail-check "wrong kind of exception")))
                     (unless (regexp-match? rx (if (exn? e) (exn-message e) (format "~a" e)))
                       (with-check-info (['message (if (exn? e) (exn-message e) e)]
                                         ['expected rx])
                         (fail-check "wrong message"))))])
    (thunk)
    (fail-check "no exception raised")))
