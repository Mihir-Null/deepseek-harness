#lang racket/base
;; Black-box specification tests for revertible effects: contract section 4
;; (docs/racket/contracts/cordis-kernel.md) and the effect-ownership cases of
;; packages/extensions/tool-cordis/tests/cordis-lifecycle.spec.ts.
;; The comment in front of each case names its source.
(require cordis
         cordis/testing
         rackunit
         racket/generator
         racket/list
         "support.rkt")

(define inactive-message #rx"cannot create effect on inactive context")

;; source: contract 4, effect results "(void) or #f: no inverse"; digest law 5
(test-case "effect/result: void and #f have no inverse"
  (with-root (ctx)
    (define d1 (ctx-effect ctx void))
    (define d2 (ctx-effect ctx (lambda () #f)))
    (check-true (disposer? d1))
    (check-false (disposer? void))
    (check-equal? (d1) (void))
    (check-equal? (d2) (void))))

;; source: contract 4, effect results "a procedure of arity 0"
(test-case "effect/result: a procedure is one inverse"
  (with-root (ctx)
    (define log (make-recorder))
    (define d (ctx-effect ctx (lambda () (note! log 'setup) (lambda () (note! log 'inverse)))))
    (check-equal? (notes log) '(setup))
    (d)
    (check-equal? (notes log) '(setup inverse))))

;; source: contract 4, effect results "a list of effect results: collected in order"
(test-case "effect/result: a list is collected in order, nested lists included"
  (with-root (ctx)
    (define log (make-recorder))
    (define (inv tag) (lambda () (note! log tag)))
    (define d (ctx-effect ctx (lambda () (list (inv 1) #f (list (inv 2) (void) (inv 3)) (inv 4)))))
    (d)
    (check-equal? (notes log) '(4 3 2 1))))

;; source: contract 4, effect results "a generator ... each yielded value and
;; the final return value are effect results"
(test-case "effect/result: a generator's yields and return value are collected"
  (with-root (ctx)
    (define log (make-recorder))
    (define (inv tag) (lambda () (note! log tag)))
    (define d (ctx-effect ctx (lambda ()
                                (generator ()
                                  (yield (inv 'y1))
                                  (yield #f)
                                  (yield (list (inv 'y2) (inv 'y3)))
                                  (inv 'returned)))))
    (d)
    (check-equal? (notes log) '(returned y3 y2 y1))))

;; source: contract 4, effect results "a task or other evt: awaited ...
;; ctx-effect returns the disposer immediately without waiting"
(test-case "effect/result: a task makes setup asynchronous"
  (with-root (ctx)
    (define log (make-recorder))
    (define gate (make-gate))
    (define d (ctx-effect ctx (lambda ()
                                (spawn-task (lambda ()
                                              (gate-wait gate)
                                              (note! log 'setup-done)
                                              (lambda () (note! log 'inverse)))))))
    (check-true (disposer? d))
    (yield-times 3)
    (check-equal? (notes log) '())
    (check-false (sync/timeout 0 d))
    (gate-open! gate)
    (check-eq? (await d) d)
    (check-equal? (notes log) '(setup-done))
    (d)
    (check-equal? (notes log) '(setup-done inverse))))

;; source: contract 4, effect results "a task or other evt" (plain evt case)
(test-case "effect/result: a plain evt is awaited and its value is an effect result"
  (with-root (ctx)
    (define log (make-recorder))
    (define sem (make-semaphore 0))
    (define d (ctx-effect ctx (lambda ()
                                (wrap-evt (semaphore-peek-evt sem)
                                          (lambda (_) (lambda () (note! log 'inverse)))))))
    (check-false (sync/timeout 0 d))
    (semaphore-post sem)
    (await d)
    (d)
    (check-equal? (notes log) '(inverse))))

;; source: contract 4, "Anything else raises exn:fail:contract (invalid effect)";
;; recon 01 Formats: TypeError "Invalid effect"
(test-case "effect/result: anything else raises exn:fail:contract"
  (with-root (ctx)
    (define rf (context-fiber ctx))
    (define before (labels-of rf))
    (define invalid (raises? exn:fail:contract? #rx"(?i:invalid effect)"))
    (check-exn invalid (lambda () (ctx-effect ctx (lambda () 42) #:label "bad-number")))
    (check-exn invalid (lambda () (ctx-effect ctx (lambda () "text") #:label "bad-string")))
    (check-exn invalid (lambda () (ctx-effect ctx (lambda () (hasheq 'a 1)) #:label "bad-hash")))
    (check-exn invalid (lambda () (ctx-effect ctx (lambda () #t) #:label "bad-true")))
    (check-exn invalid (lambda () (ctx-effect ctx (lambda () (lambda (x) x)) #:label "bad-arity")))
    (check-equal? (labels-of rf) before)))

;; source: contract 4, "thunk is called ... with current-context set to ctx and
;; current-custodian set to the owning fiber's custodian"
(test-case "effect/thunk: runs with current-context and the fiber's custodian"
  (with-root (ctx)
    (define seen (box #f))
    (ctx-effect ctx (lambda ()
                      (set-box! seen (list (eq? (current-context) ctx)
                                           (eq? (current-custodian) (context-custodian ctx))))
                      (void)))
    (check-equal? (unbox seen) '(#t #t))
    (define child-seen (box #f))
    (define f (ctx-plugin ctx (lambda (c config)
                                (ctx-effect c (lambda ()
                                                (set-box! child-seen
                                                          (list (eq? (current-context) c)
                                                                (eq? (current-custodian)
                                                                     (fiber-custodian
                                                                      (context-fiber c)))))
                                                (void))))))
    (await f)
    (check-equal? (unbox child-seen) '(#t #t))))

;; source: contract 4, signatures of dispose!, disposer-label, fiber-effects
(test-case "effect/surface: labels, dispose! and registration order"
  (with-root (ctx)
    (define rf (context-fiber ctx))
    (define before (labels-of rf))
    (define log (make-recorder))
    (define d0 (ctx-effect ctx (lambda () (lambda () (note! log 'd0)))))
    (define d1 (ctx-effect ctx void #:label "first"))
    (define d2 (ctx-effect ctx void #:label "second"))
    (check-equal? (disposer-label d0) "anonymous")
    (check-equal? (disposer-label d1) "first")
    (check-equal? (labels-of rf) (append before '("anonymous" "first" "second")))
    (check-equal? (disposer-children d1) '())
    (check-equal? (dispose! d0) (void))
    (check-equal? (notes log) '(d0))
    (check-equal? (labels-of rf) (append before '("first" "second")))
    (dispose! d2)
    (dispose! d1)
    (check-equal? (labels-of rf) before)))

;; source: contract 4, "(effect ctx maybe-label body ...+) ; label defaults to file:line:col"
(test-case "effect/macro: the effect form wraps its body and labels it by source location"
  (with-root (ctx)
    (define log (make-recorder))
    (define d (effect ctx
                (note! log 'setup)
                (lambda () (note! log 'inverse))))
    (check-true (disposer? d))
    (check-regexp-match #rx"effect-spec-test[.]rkt:[0-9]+:[0-9]+$" (disposer-label d))
    (d)
    (check-equal? (notes log) '(setup inverse))))

;; source: contract 4 rule 1 (disposed fiber); recon 01 S19
(test-case "effect rule 1: ctx-effect on a disposed fiber raises exn:fail:cordis:inactive"
  (with-root (ctx)
    (define child-ctx (box #f))
    (define f (ctx-plugin ctx (lambda (c config) (set-box! child-ctx c) (void))))
    (await f)
    (fiber-dispose! f)
    (check-exn (raises? exn:fail:cordis:inactive? inactive-message)
               (lambda () (ctx-effect (unbox child-ctx) void)))
    (check-exn exn:fail:cordis? (lambda () (ctx-effect (unbox child-ctx) void)))))

;; source: contract 4 rule 1 ('unloading fiber); analysis law 5
(test-case "effect rule 1: ctx-effect on an unloading fiber raises"
  (with-root (ctx)
    (define outcome (box 'not-run))
    (define f (ctx-plugin ctx (lambda (c config)
                                (lambda ()
                                  (set-box! outcome
                                            (with-handlers ([(lambda (e) #t) values])
                                              (ctx-effect c void #:label "too-late")
                                              (fiber-state (context-fiber c))))))))
    (await f)
    (fiber-dispose! f)
    (check-pred exn:fail:cordis:inactive? (unbox outcome))
    (check-regexp-match inactive-message (exn-message (unbox outcome)))))

;; source: contract 4 rule 2
(test-case "effect rule 2: the disposer is registered before the thunk runs"
  (with-root (ctx)
    (define rf (context-fiber ctx))
    (define seen (box #f))
    (define d (ctx-effect ctx
                          (lambda () (set-box! seen (labels-of rf)) (void))
                          #:label "rule2"))
    (check-true (and (member "rule2" (unbox seen)) #t))
    (d)))

;; source: contract 4 rule 3, first two sentences; digest law 1; analysis law 2
(test-case "effect rule 3: inverses run in reverse order, one after another, and may await"
  (with-root (ctx)
    (define log (make-recorder))
    (define gate (make-gate))
    (define d (ctx-effect ctx (lambda ()
                                (list (lambda () (note! log 'first-collected))
                                      (lambda ()
                                        (note! log 'second-start)
                                        (gate-wait gate)
                                        (note! log 'second-end))
                                      (lambda () (note! log 'third-collected))))))
    (define disposing (spawn-task (lambda () (d))))
    (yield-until (lambda () (member 'second-start (notes log))))
    (yield-times 3)
    ;; The first-collected inverse must not start before the blocked one returns.
    (check-equal? (notes log) '(third-collected second-start))
    (gate-open! gate)
    (await disposing)
    (check-equal? (notes log) '(third-collected second-start second-end first-collected))))

;; source: contract 4 rule 3, last sentence
(test-case "effect rule 3: a raising inverse is logged, the rest run, the first error is re-raised"
  (with-root (ctx)
    (define log (make-recorder))
    (define d (ctx-effect ctx
                          (lambda ()
                            (list (lambda () (note! log 'survivor))
                                  (lambda () (raise-user-error "inverse two failed"))
                                  (lambda () (raise-user-error "inverse three failed"))))
                          #:label "rule3-effect"))
    (define-values (outcome logs)
      (capture-log (lambda () (with-handlers ([exn:fail? values]) (d) 'no-exception))
                   #:level 'error
                   #:topic 'cordis))
    (check-pred exn:fail? outcome)
    (check-regexp-match #rx"inverse three failed" (exn-message outcome))
    (check-equal? (notes log) '(survivor))
    (check-true (>= (length logs) 2))
    (check-true (and (memf (lambda (v) (regexp-match? #rx"rule3-effect" (vector-ref v 1))) logs) #t)
                "the log record names the effect label")
    (check-equal? (d) (void))))

;; source: contract 4 rule 4; digest law 7; analysis law 3;
;; cordis-lifecycle.spec.ts "keeps ordinary teardown synchronous and the public
;; disposer single-shot" (recon case 12)
(test-case "effect rule 4 / case 12: the disposer is single-shot"
  (with-root (ctx)
    (define rf (context-fiber ctx))
    (define before (labels-of rf))
    (define cleanups 0)
    (define d (ctx-effect ctx (lambda () (lambda () (set! cleanups (add1 cleanups))))
                          #:label "sync-effect"))
    (check-equal? (d) (void))
    (check-equal? cleanups 1)
    (check-equal? (d) (void))
    (check-equal? cleanups 1)
    (check-equal? (labels-of rf) before)))

;; source: contract 4 rule 4, "a concurrent one from another task waits for the first"
(test-case "effect rule 4: a concurrent second call waits for the first and runs nothing"
  (with-root (ctx)
    (define log (make-recorder))
    (define gate (make-gate))
    (define d (ctx-effect ctx (lambda ()
                                (lambda ()
                                  (note! log 'inverse-start)
                                  (gate-wait gate)
                                  (note! log 'inverse-end)))))
    (define first-call (spawn-task (lambda () (d))))
    (yield-until (lambda () (pair? (notes log))))
    (define second-call (spawn-task (lambda () (d))))
    (yield-times 5)
    (check-false (task-done? first-call))
    (check-false (task-done? second-call))
    (gate-open! gate)
    (check-equal? (await-all (list first-call second-call)) (list (void) (void)))
    (check-equal? (notes log) '(inverse-start inverse-end))))

;; source: contract 4 rule 5
(test-case "effect rule 5: disposing during asynchronous setup waits for setup, then reverts"
  (with-root (ctx)
    (define log (make-recorder))
    (define gate (make-gate))
    (define d (ctx-effect ctx (lambda ()
                                (spawn-task (lambda ()
                                              (gate-wait gate)
                                              (note! log 'setup-done)
                                              (lambda () (note! log 'inverse)))))))
    (define disposing (spawn-task (lambda () (d))))
    (yield-times 5)
    (check-false (task-done? disposing))
    (check-equal? (notes log) '())
    (gate-open! gate)
    (await disposing)
    (check-equal? (notes log) '(setup-done inverse))))

;; source: contract 4 rule 6, first sentence; analysis law 4;
;; cordis-lifecycle.spec.ts "rolls back collected cleanup and its owner-list
;; entry when setup throws synchronously" (recon case 10)
(test-case "effect rule 6 / case 10: a synchronous setup failure rolls back"
  (with-root (ctx)
    (define rf (context-fiber ctx))
    (define before (labels-of rf))
    (define cleanups 0)
    (check-exn #rx"setup failed"
               (lambda ()
                 (ctx-effect ctx
                             (lambda ()
                               (generator ()
                                 (yield (lambda () (set! cleanups (add1 cleanups))))
                                 (raise-user-error "setup failed")))
                             #:label "throwing-setup")))
    (check-equal? cleanups 1)
    (check-equal? (labels-of rf) before)))

;; source: contract 4 rule 6, first sentence (an invalid result after valid ones)
(test-case "effect rule 6: an invalid result rolls back what was collected before it"
  (with-root (ctx)
    (define rf (context-fiber ctx))
    (define before (labels-of rf))
    (define log (make-recorder))
    (check-exn exn:fail:contract?
               (lambda ()
                 (ctx-effect ctx (lambda () (list (lambda () (note! log 'rolled-back)) 42)))))
    (check-equal? (notes log) '(rolled-back))
    (check-equal? (labels-of rf) before)))

;; source: contract 4 rule 6, second sentence; recon 01 S18
(test-case "effect rule 6: an asynchronous setup failure rolls back, is logged, and fails await"
  (with-root (ctx)
    (define rf (context-fiber ctx))
    (define before (labels-of rf))
    (define log (make-recorder))
    (define gate (make-gate))
    (define d (box #f))
    (define-values (outcome logs)
      (capture-log
       (lambda ()
         (set-box! d (ctx-effect ctx
                                 (lambda ()
                                   (list (lambda () (note! log 'rolled-back))
                                         (spawn-task
                                          (lambda ()
                                            (gate-wait gate)
                                            (raise-user-error "async setup failed")))))
                                 #:label "async-failure"))
         (gate-open! gate)
         (with-handlers ([exn:fail? values]) (await (unbox d)) 'no-exception))
       #:level 'error
       #:topic 'cordis))
    (check-pred exn:fail? outcome)
    (check-regexp-match #rx"async setup failed" (exn-message outcome))
    (check-equal? (notes log) '(rolled-back))
    (check-true (pair? logs) "the setup error is logged")
    (yield-times 3)
    (check-equal? (labels-of rf) before)))

;; source: contract 4 rule 7; digest law 10; recon 01 "ctx.effect" step 2
(test-case "effect rule 7: a returned nested effect becomes a child of the outer effect"
  (with-root (ctx)
    (define rf (context-fiber ctx))
    (define before (labels-of rf))
    (define log (make-recorder))
    (define outer
      (ctx-effect ctx
                  (lambda ()
                    (define inner (ctx-effect ctx (lambda () (lambda () (note! log 'inner)))
                                              #:label "inner"))
                    (list (lambda () (note! log 'outer-own)) inner))
                  #:label "outer"))
    (check-equal? (labels-of rf) (append before '("outer")))
    (check-equal? (map disposer-label (disposer-children outer)) '("inner"))
    (outer)
    (check-equal? (notes log) '(inner outer-own))
    (check-equal? (labels-of rf) before)))

;; source: contract 4 rule 7 (yielded form)
(test-case "effect rule 7: nested effects yielded by a generator become children"
  (with-root (ctx)
    (define rf (context-fiber ctx))
    (define before (labels-of rf))
    (define log (make-recorder))
    (define (sub tag)
      (ctx-effect ctx (lambda () (lambda () (note! log tag))) #:label (symbol->string tag)))
    (define outer
      (ctx-effect ctx
                  (lambda () (generator () (yield (sub 'a)) (yield (sub 'b)) (void)))
                  #:label "outer"))
    (check-equal? (labels-of rf) (append before '("outer")))
    (check-equal? (map disposer-label (disposer-children outer)) '("a" "b"))
    (outer)
    (check-equal? (notes log) '(b a))))

;; source: recon 01 "ctx.effect" step 2, "a nested effect that is merely
;; created inside execute stays a separate top-level effect"
(test-case "effect rule 7: a nested effect that is not returned stays top-level"
  (with-root (ctx)
    (define rf (context-fiber ctx))
    (define log (make-recorder))
    (define stray (box #f))
    (define outer
      (ctx-effect ctx
                  (lambda ()
                    (set-box! stray (ctx-effect ctx (lambda () (lambda () (note! log 'stray)))
                                                #:label "stray"))
                    (lambda () (note! log 'outer)))
                  #:label "outer"))
    (check-true (and (member "stray" (labels-of rf)) #t))
    (check-equal? (disposer-children outer) '())
    (outer)
    (check-equal? (notes log) '(outer))
    ((unbox stray))
    (check-equal? (notes log) '(outer stray))))

;; source: contract 4 rule 8
(test-case "effect rule 8: a disposer is an evt that is ready when setup has settled"
  (with-root (ctx)
    (define sync-d (ctx-effect ctx void))
    (check-true (evt? sync-d))
    (check-eq? (await sync-d) sync-d)
    (define gate (make-gate))
    (define async-d (ctx-effect ctx (lambda () (spawn-task (lambda () (gate-wait gate) (void))))))
    (define waiter (spawn-task (lambda () (await async-d))))
    (yield-times 3)
    (check-false (task-done? waiter))
    (gate-open! gate)
    (check-eq? (await waiter) async-d)))

;; source: contract 4 rule 9; digest law 8 (ctx-effect guard: the disposer was called)
(test-case "effect rule 9: a called disposer stops a generator at the next step boundary"
  (with-root (ctx)
    (define log (make-recorder))
    (define gate (make-gate))
    (define in-step-2 (make-gate))
    (define holder (box #f))
    (define setup
      (spawn-task
       (lambda ()
         (ctx-effect ctx
                     (lambda ()
                       (generator ()
                         (yield (lambda () (note! log 'inverse-1)))
                         (gate-open! in-step-2)
                         (gate-wait gate)
                         (note! log 'step-2)
                         (yield (lambda () (note! log 'inverse-2)))
                         (note! log 'step-3)
                         (yield (lambda () (note! log 'inverse-3)))
                         (void)))
                     #:label "guarded"))))
    (gate-wait in-step-2)
    (define rf (context-fiber ctx))
    (define guarded (findf (lambda (d) (equal? (disposer-label d) "guarded")) (fiber-effects rf)))
    (check-true (disposer? guarded))
    (define disposing (spawn-task (lambda () (guarded))))
    (yield-times 5)
    (check-false (task-done? disposing))
    (gate-open! gate)
    (await disposing)
    (await setup)
    (check-equal? (notes log) '(step-2 inverse-2 inverse-1))))

;; source: contract 4 rule 10; digest law 28
(test-case "effect rule 10: after a fiber unloads it owns no effects"
  (with-root (ctx)
    (define log (make-recorder))
    (define f (ctx-plugin ctx (lambda (c config)
                                (ctx-effect c (lambda () (lambda () (note! log 'e1))) #:label "e1")
                                (ctx-effect c (lambda () (lambda () (note! log 'e2))) #:label "e2")
                                (ctx-on c 'spec/event void)
                                (void))))
    (await f)
    (check-equal? (length (fiber-effects f)) 3)
    (fiber-dispose! f)
    (check-equal? (fiber-effects f) '())
    (check-equal? (sort (notes log) symbol<?) '(e1 e2))))

;; source: cordis-lifecycle.spec.ts "makes an effect visible to a reentrant
;; owner restart and awaits setup plus cleanup" (recon case 9)
(test-case "case 9: a re-entrant owner restart sees the effect and awaits setup and cleanup"
  (with-root (ctx)
    (define rf (context-fiber ctx))
    (define before (labels-of rf))
    (define setup-gate (make-gate))
    (define cleanup-gate (make-gate))
    (define cleanup-started (make-gate))
    (define restarted (box #f))
    (define setup-finished? #f)
    (define cleanup-finished? #f)
    (ctx-effect ctx
                (lambda ()
                  (set-box! restarted (spawn-task (lambda () (fiber-restart! rf))))
                  (spawn-task (lambda ()
                                (gate-wait setup-gate)
                                (set! setup-finished? #t)
                                (lambda ()
                                  (gate-open! cleanup-started)
                                  (gate-wait cleanup-gate)
                                  (set! cleanup-finished? #t)))))
                #:label "reentrant-restart")
    (yield-times 5)
    (check-false (task-done? (unbox restarted)))
    (gate-open! setup-gate)
    (gate-wait cleanup-started)
    (check-true setup-finished?)
    (yield-times 5)
    (check-false (task-done? (unbox restarted)))
    (gate-open! cleanup-gate)
    (await (unbox restarted))
    (check-true cleanup-finished?)
    (check-equal? (labels-of rf) before)
    (check-eq? (fiber-state rf) 'active)))

;; source: cordis-lifecycle.spec.ts "makes a reentrant owner restart await
;; asynchronous rollback after synchronous setup failure" (recon case 11).
;; An inverse that awaits blocks the failing ctx-effect call, so the call runs
;; in its own task here.
(test-case "case 11: a re-entrant owner restart awaits the rollback of a failed setup"
  (with-root (ctx)
    (define rf (context-fiber ctx))
    (define before (labels-of rf))
    (define cleanup-gate (make-gate))
    (define cleanup-started (make-gate))
    (define restarted (box #f))
    (define failing
      (spawn-task
       (lambda ()
         (ctx-effect ctx
                     (lambda ()
                       (generator ()
                         (yield (lambda ()
                                  (gate-open! cleanup-started)
                                  (gate-wait cleanup-gate)))
                         (set-box! restarted (spawn-task (lambda () (fiber-restart! rf))))
                         (raise-user-error "setup failed after restart")))
                     #:label "reentrant-throw"))))
    (gate-wait cleanup-started)
    (yield-times 5)
    (check-false (task-done? (unbox restarted)))
    (gate-open! cleanup-gate)
    (await (unbox restarted))
    (check-exn #rx"setup failed after restart" (lambda () (await failing)))
    (check-equal? (labels-of rf) before)))

;; source: cordis-lifecycle.spec.ts "rejects cleanup-time registration while a
;; restart is unloading" (recon case 13)
(test-case "case 13: registration inside a cleanup during restart raises INACTIVE_EFFECT"
  (with-root (ctx)
    (define rf (context-fiber ctx))
    (define before (labels-of rf))
    (define registration-error (box #f))
    (ctx-effect ctx
                (lambda ()
                  (lambda ()
                    (with-handlers ([(lambda (e) #t) (lambda (e) (set-box! registration-error e))])
                      (ctx-effect ctx (lambda () void) #:label "too-late"))))
                #:label "restart-cleanup")
    (fiber-restart! rf)
    (check-pred exn:fail:cordis:inactive? (unbox registration-error))
    (check-regexp-match inactive-message (exn-message (unbox registration-error)))
    (check-eq? (fiber-state rf) 'active)
    (check-equal? (labels-of rf) before)))

;; source: digest law 2 (tracking does not change forward behaviour)
(test-case "law 2: an action has the same forward result with and without effect tracking"
  (with-root (ctx)
    (define (action table) (hash-set! table 'k 'v) (lambda () (hash-remove! table 'k)))
    (define plain (make-hasheq))
    (define tracked (make-hasheq))
    (action plain)
    (ctx-effect ctx (lambda () (action tracked)))
    (check-equal? tracked plain)))

;; source: digest law 3 (composition)
(test-case "law 3: two sub-effects in one effect equal two nested effect calls"
  (with-root (ctx)
    (define (run-variant build)
      (define table (make-hasheq))
      (define (add! k) (hash-set! table k #t) (lambda () (hash-remove! table k)))
      (define d (build add!))
      (define forward (hash-copy table))
      (d)
      (list forward (hash-copy table)))
    (define flat
      (run-variant (lambda (add!) (ctx-effect ctx (lambda () (list (add! 'a) (add! 'b)))))))
    (define nested
      (run-variant (lambda (add!)
                     (ctx-effect ctx (lambda ()
                                       (list (ctx-effect ctx (lambda () (add! 'a)))
                                             (ctx-effect ctx (lambda () (add! 'b)))))))))
    (check-equal? flat nested)
    (check-equal? (hash-count (second flat)) 0)))

;; source: digest law 6 (early dispose)
(test-case "law 6: an early dispose reverts one effect and the unload does not run it again"
  (with-root (ctx)
    (define table (make-hasheq))
    (define runs (make-hasheq))
    (define disposers (box '()))
    (define f
      (ctx-plugin ctx
                  (lambda (c config)
                    (for ([k (in-list '(a b c))])
                      (define d (ctx-effect c (lambda ()
                                                (hash-set! table k #t)
                                                (lambda ()
                                                  (hash-update! runs k add1 0)
                                                  (hash-remove! table k)))))
                      (set-box! disposers (cons (cons k d) (unbox disposers))))
                    (void))))
    (await f)
    ((cdr (assq 'b (unbox disposers))))
    (check-equal? (sort (hash-keys table) symbol<?) '(a c))
    (fiber-dispose! f)
    (check-equal? (hash-count table) 0)
    (check-equal? (for/list ([k (in-list '(a b c))]) (hash-ref runs k 0)) '(1 1 1))))

;; source: digest law 9 (a plain effect equals a one-step iterator)
(test-case "law 9: a returned disposer and a generator yielding it behave the same"
  (with-root (ctx)
    (define (run-variant wrap)
      (define log (make-recorder))
      (define d (ctx-effect ctx (lambda ()
                                  (note! log 'setup)
                                  (wrap (lambda () (note! log 'inverse))))))
      (define after-setup (notes log))
      (d)
      (d)
      (list after-setup (notes log)))
    (check-equal? (run-variant values)
                  (run-variant (lambda (inverse) (generator () (yield inverse) (void)))))))
