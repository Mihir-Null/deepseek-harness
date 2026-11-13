#lang racket/base
;; Revertible effects: contract section 4, rules 1 to 10, the effect result forms, and the
;; behaviour of a disposer whose cleanup is interrupted.
(require rackunit
         racket/generator
         racket/list
         cordis
         cordis/testing
         "common.rkt")

(define (labels f) (map disposer-label (fiber-effects f)))

;; A plugin fiber to register effects on; `body` receives the fiber's context.
(define (mount ctx [body void])
  (define f (ctx-plugin ctx (lambda (c config) (body c) (void))))
  (await/t f)
  f)

;; ---------------------------------------------------------------------------------------
;; Effect results

(test-case "results: void and #f collect nothing; the disposer is applicable"
  (with-root-context (ctx)
    (define f (mount ctx))
    (define c (fiber-context f))
    (define d1 (ctx-effect c void))
    (define d2 (ctx-effect c (lambda () #f) #:label "nothing"))
    (check-true (disposer? d1))
    (check-false (disposer? void))
    (check-true (procedure? d1))
    (check-equal? (disposer-label d1) "anonymous")
    (check-equal? (disposer-label d2) "nothing")
    (check-equal? (labels f) '("anonymous" "nothing"))
    (check-equal? (d1) (void))
    (check-equal? (dispose! d2) (void))
    (check-equal? (labels f) '())))

(test-case "results: a procedure, a list, nested lists, a generator, multiple values"
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (define c (fiber-context (mount ctx)))
    (define (inverse tag) (lambda () (note tag)))
    ((ctx-effect c (lambda () (inverse 'single))))
    ((ctx-effect c (lambda () (list (inverse 'l1) #f (list (inverse 'l2) (void)) (inverse 'l3)))))
    ((ctx-effect c (lambda ()
                     (generator ()
                       (yield (inverse 'g1))
                       (yield (list (inverse 'g2) (inverse 'g3)))
                       (inverse 'g-return)))))
    ((ctx-effect c (lambda () (values (inverse 'v1) (inverse 'v2)))))
    ((ctx-effect c (lambda () '()))))
  (check-equal? (notes) '(single l3 l2 l1 g-return g3 g2 g1 v2 v1)))

(test-case "results: anything else raises exn:fail:contract and leaves nothing registered"
  (with-root-context (ctx)
    (define f (mount ctx))
    (define c (fiber-context f))
    (for ([bad (list 5 "text" 'symbol (hasheq) (lambda (x) x) (list void 7))])
      (check-exn-message exn:fail:contract? #rx"invalid effect"
                         (lambda () (ctx-effect c (lambda () bad)))))
    (check-equal? (labels f) '())))

(test-case "results: a task or evt makes setup asynchronous; its result is an effect result"
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (define f (mount ctx))
    (define c (fiber-context f))
    (define g (gate))
    (define d
      (ctx-effect c (lambda ()
                      (spawn-task (lambda ()
                                    (gate-wait g)
                                    (list (lambda () (note 'from-task))
                                          (wrap-evt always-evt
                                                    (lambda (_) (lambda () (note 'from-evt))))))))
                  #:label "async"))
    ;; ctx-effect returned without waiting for setup
    (check-false (sync/timeout 0 d))
    (gate-open! g)
    (check-eq? (await/t d) d)
    (check-eq? (sync/t d) d)
    (d)
    (check-equal? (labels f) '()))
  (check-equal? (notes) '(from-evt from-task)))

(test-case "results: an evt that is its own result, and a fiber, collect nothing"
  (with-root-context (ctx)
    (define f (mount ctx))
    (define c (fiber-context f))
    (define sema (make-semaphore 1))
    (define d (ctx-effect c (lambda () sema)))
    (check-eq? (await/t d) d)
    (define child #f)
    (define d2 (ctx-effect c (lambda ()
                               (set! child (ctx-plugin c (lambda (c config) (void))))
                               child)))
    (check-eq? (await/t d2) d2)
    (check-eq? (fiber-state child) 'active)
    (fiber-dispose! f)
    (check-eq? (fiber-state child) 'disposed)))

(test-case "thunk runs with current-context and the owner's custodian; the effect macro labels"
  (with-root-context (ctx)
    (define f (mount ctx))
    (define c (fiber-context f))
    (define seen #f)
    (ctx-effect c (lambda ()
                    (set! seen (list (eq? (current-context) c)
                                     (eq? (current-custodian) (fiber-custodian f))))
                    (lambda ()
                      (set! seen (append seen (list (eq? (current-context) c)))))))
    (check-equal? seen '(#t #t))
    (define d1 (effect c (void)))
    (define d2 (effect c #:label "keyword" (void)))
    (define d3 (effect c "string" (void) void))
    (check-regexp-match #rx"^effect-test[.]rkt:[0-9]+:[0-9]+$" (disposer-label d1))
    (check-equal? (disposer-label d2) "keyword")
    (check-equal? (disposer-label d3) "string")
    (fiber-dispose! f)
    (check-equal? seen '(#t #t #t))))

;; ---------------------------------------------------------------------------------------
;; Rule 1

(test-case "rule 1 / law 5: no effect on a disposed or unloading fiber"
  (with-root-context (ctx)
    (define f (mount ctx))
    (define c (fiber-context f))
    (define during-unload #f)
    (ctx-effect c (lambda ()
                    (lambda ()
                      (set! during-unload
                            (with-handlers ([exn:fail:cordis:inactive? exn-message])
                              (ctx-effect c void)
                              'registered)))))
    (fiber-dispose! f)
    (check-equal? during-unload "cannot create effect on inactive context")
    (check-exn-message exn:fail:cordis:inactive? #rx"^cannot create effect on inactive context$"
                       (lambda () (ctx-effect c void)))
    (check-exn exn:fail:cordis:inactive? (lambda () (ctx-on c 'event void)))
    (check-exn exn:fail:cordis:inactive? (lambda () (ctx-provide c 'service 1)))
    (check-exn exn:fail:cordis:inactive? (lambda () (ctx-plugin c (lambda (c config) (void)))))))

(test-case "rule 1: effects are legal while the fiber is pending and while it is loading"
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (ctx-on ctx 'internal/plugin
            (lambda (f)
              (when (fiber-uid f)
                (note (fiber-state f))
                (ctx-effect (fiber-context f) (lambda () (lambda () (note 'pending-cleanup)))))))
    (define f (ctx-plugin ctx (lambda (c config)
                                (note (fiber-state (context-fiber c)))
                                (ctx-effect c (lambda () (lambda () (note 'loading-cleanup))))
                                (void))))
    (await/t f)
    (fiber-dispose! f))
  (check-equal? (notes) '(pending loading loading-cleanup pending-cleanup)))

;; ---------------------------------------------------------------------------------------
;; Rule 2

(test-case "rule 2: the disposer is registered before the thunk runs"
  (with-root-context (ctx)
    (define f (mount ctx))
    (define c (fiber-context f))
    (define inside #f)
    (ctx-effect c (lambda () (set! inside (labels f)) (void)) #:label "early")
    (check-equal? inside '("early"))))

;; ---------------------------------------------------------------------------------------
;; Rule 3 and law 2

(test-case "rule 3 / law 2: inverses run in reverse order, each to completion"
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (define c (fiber-context (mount ctx)))
    (define g (gate))
    (define d
      (ctx-effect c (lambda ()
                      (list (lambda () (note 'first-registered))
                            (lambda () (note 'slow-start) (gate-wait g) (note 'slow-end))
                            (lambda () (note 'last-registered))))))
    (define disposal (spawn-task (lambda () (d))))
    (yield-task)
    (check-equal? (notes) '(last-registered slow-start))
    (gate-open! g)
    (await/t disposal))
  (check-equal? (notes) '(last-registered slow-start slow-end first-registered)))

(test-case "rule 3: an inverse that returns a task is waited for before the next inverse"
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (define c (fiber-context (mount ctx)))
    (define g (gate))
    (define d
      (ctx-effect c (lambda ()
                      (list (lambda () (note 'after-task))
                            (lambda ()
                              (spawn-task (lambda () (gate-wait g) (note 'task-done))))))))
    (define disposal (spawn-task (lambda () (d))))
    (yield-task)
    (yield-task)
    (check-equal? (notes) '())
    (gate-open! g)
    (await/t disposal))
  (check-equal? (notes) '(task-done after-task)))

(test-case "rule 3: a raising inverse is logged; the rest run; the first failure is re-raised"
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (define f (mount ctx))
    (define c (fiber-context f))
    (define d
      (ctx-effect c (lambda ()
                      (list (lambda () (note 'a))
                            (lambda () (raise-user-error "second inverse failed"))
                            (lambda () (note 'c))
                            (lambda () (raise-user-error "first inverse failed"))))
                  #:label "fragile"))
    (define-values (raised events)
      (capture-log (lambda () (with-handlers ([exn:fail:user? exn-message]) (d) 'no-exception))))
    (check-regexp-match #rx"first inverse failed" raised)
    (check-equal? (length events) 2)
    (for ([e (in-list events)])
      (check-eq? (vector-ref e 0) 'error)
      (check-regexp-match #rx"fragile" (vector-ref e 1))
      (check-pred exn:fail:user? (vector-ref e 2)))
    (check-equal? (labels f) '())
    ;; the failure is not raised a second time
    (check-equal? (d) (void)))
  (check-equal? (notes) '(c a)))

;; ---------------------------------------------------------------------------------------
;; Rule 4 and law 3

(test-case "rule 4 / law 3: a disposer runs its inverses once"
  (define count 0)
  (with-root-context (ctx)
    (define f (mount ctx))
    (define d (ctx-effect (fiber-context f) (lambda () (lambda () (set! count (add1 count))))))
    (check-equal? (d) (void))
    (check-equal? (d) (void))
    (check-equal? (dispose! d) (void))
    (fiber-dispose! f))
  (check-equal? count 1))

(test-case "rule 4: a concurrent second call waits for the first and runs nothing"
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (define c (fiber-context (mount ctx)))
    (define g (gate))
    (define started (gate))
    (define d (ctx-effect c (lambda ()
                              (lambda () (note 'start) (gate-open! started) (gate-wait g)
                                      (note 'end)))))
    (define first-call (spawn-task (lambda () (d) (note 'first-returned))))
    (gate-wait started)
    (define second-call (spawn-task (lambda () (d) (note 'second-returned))))
    (yield-task)
    (yield-task)
    (check-false (task-done? second-call))
    (gate-open! g)
    (await-all (list first-call second-call)))
  (check-equal? (notes) '(start end first-returned second-returned)))

(test-case "rule 4: an inverse that calls its own disposer does not wait for itself"
  (define count 0)
  (with-root-context (ctx)
    (define c (fiber-context (mount ctx)))
    (define d #f)
    (set! d (ctx-effect c (lambda () (lambda () (set! count (add1 count)) (d)))))
    (d))
  (check-equal? count 1))

;; ---------------------------------------------------------------------------------------
;; Rule 5

(test-case "rule 5: disposing during asynchronous setup waits for setup, then reverts"
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (define f (mount ctx))
    (define c (fiber-context f))
    (define g (gate))
    (define d (ctx-effect c (lambda ()
                              (spawn-task (lambda ()
                                            (gate-wait g)
                                            (note 'setup-done)
                                            (lambda () (note 'reverted)))))))
    (define disposal (spawn-task (lambda () (d) (note 'disposed))))
    (yield-task)
    (yield-task)
    (check-false (task-done? disposal))
    (check-equal? (notes) '())
    (gate-open! g)
    (await/t disposal)
    (check-equal? (labels f) '()))
  (check-equal? (notes) '(setup-done reverted disposed)))

(test-case "rule 5: a fiber unload waits for asynchronous setup too"
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (define f (mount ctx))
    (define g (gate))
    (ctx-effect (fiber-context f)
                (lambda ()
                  (spawn-task (lambda () (gate-wait g) (lambda () (note 'reverted))))))
    (define disposal (spawn-task (lambda () (fiber-dispose! f))))
    (yield-task)
    (yield-task)
    (check-eq? (fiber-state f) 'unloading)
    (gate-open! g)
    (await/t disposal)
    (check-eq? (fiber-state f) 'disposed))
  (check-equal? (notes) '(reverted)))

;; ---------------------------------------------------------------------------------------
;; Rule 6 and law 4

(test-case "rule 6 / law 4: a synchronous setup failure rolls back and propagates"
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (define f (mount ctx))
    (define c (fiber-context f))
    (check-exn #rx"setup failed"
               (lambda ()
                 (ctx-effect c (lambda ()
                                 (generator ()
                                   (yield (lambda () (note 'one)))
                                   (yield (lambda () (note 'two)))
                                   (raise-user-error "setup failed"))))))
    (check-equal? (labels f) '())
    (check-eq? (fiber-state f) 'active))
  (check-equal? (notes) '(two one)))

(test-case "rule 6: a failure before anything was collected registers nothing"
  (with-root-context (ctx)
    (define f (mount ctx))
    (check-exn #rx"immediate"
               (lambda () (ctx-effect (fiber-context f)
                                      (lambda () (raise-user-error "immediate")))))
    (check-equal? (labels f) '())))

(test-case "rule 6: an asynchronous setup failure rolls back, is logged, and is raised by await"
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (define f (mount ctx))
    (define c (fiber-context f))
    (define g (gate))
    (define d #f)
    (define-values (_ events)
      (capture-log
       (lambda ()
         (set! d (ctx-effect c (lambda ()
                                 (generator ()
                                   (yield (lambda () (note 'rolled-back)))
                                   (yield (spawn-task (lambda () (gate-wait g) (void))))
                                   (raise-user-error "late failure")))
                             #:label "late"))
         (gate-open! g)
         (check-exn #rx"late failure" (lambda () (await/t d))))))
    (check-equal? (length events) 1)
    (check-regexp-match #rx"late failure" (vector-ref (car events) 1))
    (check-equal? (labels f) '())
    ;; the first call after an asynchronous failure reports it; cleanup already ran
    (check-exn #rx"late failure" (lambda () (d)))
    (check-equal? (d) (void)))
  (check-equal? (notes) '(rolled-back)))

;; ---------------------------------------------------------------------------------------
;; Rule 7

(test-case "rule 7 / law 2: a returned or yielded effect becomes a child"
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (define f (mount ctx))
    (define c (fiber-context f))
    (define outer
      (ctx-effect c (lambda ()
                      (generator ()
                        (yield (ctx-effect c (lambda () (lambda () (note 'child-1)))
                                           #:label "child-1"))
                        (yield (lambda () (note 'plain)))
                        (ctx-effect c (lambda () (lambda () (note 'child-2))) #:label "child-2")))
                  #:label "outer"))
    (check-equal? (labels f) '("outer"))
    (check-equal? (map disposer-label (disposer-children outer)) '("child-1" "child-2"))
    (outer)
    (check-equal? (labels f) '()))
  (check-equal? (notes) '(child-2 plain child-1)))

(test-case "rule 7: an effect that is merely created inside another stays top-level"
  (with-root-context (ctx)
    (define f (mount ctx))
    (define c (fiber-context f))
    (define outer
      (ctx-effect c (lambda () (ctx-effect c void #:label "independent") (void))
                  #:label "outer"))
    (check-equal? (labels f) '("outer" "independent"))
    (check-equal? (disposer-children outer) '())
    (outer)
    (check-equal? (labels f) '("independent"))))

;; ---------------------------------------------------------------------------------------
;; Rule 8

(test-case "rule 8: a disposer is an evt, ready when setup has settled"
  (with-root-context (ctx)
    (define c (fiber-context (mount ctx)))
    (define d (ctx-effect c void))
    (check-true (evt? d))
    (check-eq? (sync/timeout 0 d) d)
    (check-eq? (await d) d)
    (check-eq? (await/timeout 1 d) d)))

;; ---------------------------------------------------------------------------------------
;; Rule 9

(test-case "rule 9: disposal during a generator stops it at the next step"
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (define f (mount ctx))
    (define c (fiber-context f))
    (define g (gate))
    (define d
      (ctx-effect c (lambda ()
                      (generator ()
                        (yield (lambda () (note 'inverse-1)))
                        (yield (spawn-task (lambda () (gate-wait g) (lambda () (note 'inverse-2)))))
                        (note 'step-3-ran)
                        (yield (lambda () (note 'inverse-3)))
                        (void)))))
    (define disposal (spawn-task (lambda () (d))))
    (yield-task)
    (gate-open! g)
    (await/t disposal)
    (check-equal? (labels f) '()))
  ;; the step in flight completed and its inverse was kept; the generator was not resumed
  (check-equal? (notes) '(inverse-2 inverse-1)))

;; ---------------------------------------------------------------------------------------
;; Rule 10

(test-case "rule 10: after a fiber unloads it owns no effects"
  (with-root-context (ctx)
    (define f (mount ctx (lambda (c)
                           (ctx-effect c void)
                           (ctx-on c 'event void)
                           (ctx-provide c 'service 1)
                           (ctx-effect c (lambda () (spawn-task void))))))
    (check-equal? (length (fiber-effects f)) 4)
    (fiber-restart! f)
    (check-equal? (length (fiber-effects f)) 4)
    (fiber-dispose! f)
    (check-equal? (fiber-effects f) '())))

;; ---------------------------------------------------------------------------------------
;; Interrupted cleanup

(test-case "a break during cleanup hands the rest to the kernel; the caller gets the break"
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (define f (mount ctx))
    (define c (fiber-context f))
    (define started (gate))
    (define g (gate))
    (define d
      (ctx-effect c (lambda ()
                      (list (lambda () (note 'last))
                            (lambda () (gate-open! started) (gate-wait g) (note 'unreached))))))
    (define disposal (spawn-task (lambda () (d))))
    (gate-wait started)
    (task-cancel! disposal)
    (check-exn exn:break? (lambda () (await/t disposal)))
    ;; the remaining inverse runs although the caller is gone
    (check-not-false (wait-for (lambda () (null? (labels f)))))
    (check-equal? (d) (void)))
  (check-equal? (notes) '(last)))

(test-case "an inverse that re-raises another task's break is a failed inverse, not a break"
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (define f (mount ctx))
    (define c (fiber-context f))
    (define started (gate))
    (define cancelled
      (spawn-task (lambda () (gate-open! started) (await (make-semaphore 0)))))
    (gate-wait started)
    (task-cancel! cancelled)
    (define d
      (ctx-effect c (lambda ()
                      (list (lambda () (note 'last))
                            (lambda () (await cancelled))))))
    (define-values (outcome events)
      (capture-log (lambda ()
                     (with-handlers ([exn:break? (lambda (e) 'stored-break-raised)])
                       (d)
                       'nothing-raised))))
    (check-equal? outcome 'stored-break-raised)
    (check-equal? (length events) 1)
    ;; the cleanup ran to its end in this task, and this task was not broken
    (check-equal? (notes) '(last))
    (check-equal? (labels f) '())
    (yield-task)
    (check-equal? (await/t (spawn-task (lambda () 'still-running))) 'still-running)))

(test-case "a killed cleanup is continued by whoever waits for it"
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (define f (mount ctx))
    (define c (fiber-context f))
    (define started (gate))
    (define d
      (ctx-effect c (lambda ()
                      (list (lambda () (note 'last))
                            (lambda () (gate-open! started) (await (make-semaphore 0)))))))
    (define disposal (spawn-task (lambda () (d))))
    (gate-wait started)
    (task-kill! disposal)
    (fiber-dispose! f)
    (check-equal? (labels f) '())
    (check-eq? (fiber-state f) 'disposed))
  (check-equal? (notes) '(last)))

(test-case "a killed setup counts as failed; disposal reverts what it had collected"
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (define f (mount ctx))
    (define c (fiber-context f))
    (define started (gate))
    (define creator
      (spawn-task
       (lambda ()
         (ctx-effect c (lambda ()
                         (generator ()
                           (yield (lambda () (note 'collected)))
                           (gate-open! started)
                           (await (make-semaphore 0))
                           (void)))
                     #:label "stuck"))))
    (gate-wait started)
    (check-equal? (labels f) '("stuck"))
    (task-kill! creator)
    (fiber-dispose! f)
    (check-equal? (labels f) '()))
  (check-equal? (notes) '(collected)))

(test-case "effects may be created and disposed from a thread that is not a task"
  (define-values (note notes) (make-recorder))
  (define root (make-root-context))
  (check-false (in-task? (context-scheduler root)))
  (define s (context-scheduler root))
  (define d (ctx-effect root (lambda ()
                               (note (in-task? s))
                               (lambda () (note (list 'inverse (in-task? s)))))))
  (check-equal? (map disposer-label (fiber-effects (context-fiber root))) '("anonymous"))
  (check-eq? (await d) d)
  (d)
  (dispose! d)
  (check-equal? (notes) '(#t (inverse #t)))
  (context-shutdown! root)
  ;; a finished disposer stays callable after the kernel is gone
  (check-equal? (d) (void)))
