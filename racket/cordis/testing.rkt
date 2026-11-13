#lang racket/base
;; cordis/testing: helpers for tests of code built on the kernel (contract section 10).
;;
;; Every helper that waits has a timeout, so a test that goes wrong fails instead of
;; hanging. `call-with-root-context` runs under a custodian of its own and shuts it down on
;; the way out, so no thread made inside the test survives it.
(require (for-syntax racket/base syntax/parse)
         racket/contract/base
         rackunit
         "private/scheduler.rkt"
         "private/log.rkt"
         "private/core.rkt"
         "private/lifecycle.rkt"
         "private/root.rkt")

(provide
 with-root-context
 check-kernel-restored
 (contract-out
  ;; Makes a root context, runs (proc root) as a task and returns its values; shuts the
  ;; kernel down in every case. Raises `exn:fail` when the task has not finished in time.
  [call-with-root-context (->* ((-> context? any)) (#:timeout (>=/c 0)) any)]
  ;; A summary to compare with `equal?`: provider fiber names by service realm name,
  ;; listener counts by event, accessor names, names of live plugin fibers. Every list is
  ;; sorted, so the summary does not depend on the order in which things were registered.
  [kernel-snapshot (-> context? hash?)]
  ;; Runs proc and returns its value and the log events received meanwhile on the cordis
  ;; logger at `level` or above. `#:topic #f` receives every topic.
  [capture-log (->* ((-> any/c))
                    (#:level (or/c 'fatal 'error 'warning 'info 'debug)
                     #:topic (or/c symbol? #f))
                    (values any/c (listof vector?)))]
  ;; Polls until pred returns a true value and returns it; #f when the time is up. In a
  ;; task the baton is released between polls.
  [wait-for (->* ((-> any/c)) (#:timeout (>=/c 0)) any/c)]))

(define (call-with-root-context proc #:timeout [secs 10])
  (define cust (make-custodian))
  (dynamic-wind
   void
   (lambda ()
     (parameterize ([current-custodian cust])
       (define root (make-root-context #:custodian cust))
       (define t
         (spawn-task (lambda () (proc root))
                     #:name 'test
                     #:scheduler (context-scheduler root)))
       (cond
         [(await/timeout secs (wrap-evt t (lambda (_) #t)) (lambda () #f))
          ;; take the outcome first, so that a failure of proc counts as observed
          (define outcome
            (with-handlers ([(lambda (e) #t) (lambda (e) (cons 'raise e))])
              (call-with-values (lambda () (task-result t)) (lambda vs (cons 'values vs)))))
          (shut-down root secs)
          (if (eq? (car outcome) 'raise)
              (raise (cdr outcome))
              (apply values (cdr outcome)))]
         [else
          (task-observe! t)
          (context-kill! root)
          (raise (exn:fail (format "call-with-root-context: no result after ~a seconds" secs)
                           (current-continuation-marks)))])))
   (lambda () (custodian-shutdown-all cust))))

;; Orderly shutdown; a kernel that does not finish it in time is killed.
(define (shut-down root secs)
  (define worker
    (thread (lambda ()
              (with-handlers ([(lambda (e) #t) void])
                (context-shutdown! root)))))
  (unless (sync/timeout secs worker)
    (context-kill! root)))

(define-syntax (with-root-context stx)
  (syntax-parse stx
    [(_ (ctx:id (~optional (~seq #:timeout secs:expr))) body:expr ...+)
     #'(call-with-root-context (lambda (ctx) body ...) (~? (~@ #:timeout secs)))]))

(define (kernel-snapshot root)
  (define k (context-kernel root))
  (define (snapshot)
    (hasheq
     'services
     (for/fold ([h (hash)]) ([(realm i) (in-hash (kernel-store k))])
       (hash-update h (symbol->string realm)
                    (lambda (names)
                      (sort (cons (fiber-name (context-fiber (impl-ctx i))) names) string<?))
                    '()))
     'listeners
     (for/hash ([(name hooks) (in-hash (kernel-hooks k))])
       (values name (length hooks)))
     'accessors
     (sort (for/list ([(name decl) (in-hash (kernel-props k))] #:when (accessor? decl)) name)
           symbol<?)
     'fibers
     (sort (map fiber-name (ctx-fibers root)) string<?)))
  (if (kernel-shutdown? k)
      (snapshot)
      (call/kernel root snapshot)))

;; Returns #f when the kernel still has work in flight after `secs` seconds.
(define (wait-for-quiescence root secs)
  (define k (context-kernel root))
  (define t
    (spawn-task (lambda () (await-quiescence k))
                #:name 'quiescence
                #:scheduler (kernel-scheduler k)))
  (cond
    [(await/timeout secs (wrap-evt t (lambda (_) #t)) (lambda () #f)) (task-result t) #t]
    [else (task-kill! t) #f]))

;; (check-kernel-restored thunk root): takes a snapshot, runs thunk, waits until the kernel
;; has no transition, effect setup or cleanup in flight, and fails unless the snapshot is
;; the same again.
(define-check (check-kernel-restored thunk root)
  (define before (kernel-snapshot root))
  (thunk)
  (unless (wait-for-quiescence root 10)
    (fail-check "the kernel did not become quiescent"))
  (define after (kernel-snapshot root))
  (unless (equal? before after)
    (with-check-info (['before before] ['after after])
      (fail-check "kernel state was not restored"))))

(define (capture-log proc #:level [level 'error] #:topic [topic 'cordis])
  (define receiver
    (if topic
        (make-log-receiver cordis-logger level topic)
        (make-log-receiver cordis-logger level)))
  (define result (proc))
  (define events
    (let loop ([acc '()])
      (define e (sync/timeout 0 receiver))
      (if e (loop (cons e acc)) (reverse acc))))
  (values result events))

(define (wait-for pred #:timeout [secs 5])
  (define deadline (+ (current-inexact-monotonic-milliseconds) (* 1000.0 secs)))
  (let loop ([pause 0.0005])
    (cond
      [(pred)]
      [(>= (current-inexact-monotonic-milliseconds) deadline) #f]
      [else
       (cond
         [(current-task) (yield-task) (task-sleep pause)]
         [else (sleep pause)])
       (loop (min 0.02 (* 2 pause)))])))
