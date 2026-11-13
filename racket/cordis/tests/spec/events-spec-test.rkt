#lang racket/base
;; Black-box specification tests for events: contract section 7
;; (docs/racket/contracts/cordis-kernel.md), read against
;; vendor/cordis/src/events.ts, plus recon case 8 and the supplementary cases
;; S7 to S11 of docs/racket/recon/01-cordis-core.md.
;; The comment in front of each case names its source.
(require cordis
         cordis/testing
         rackunit
         racket/list
         "support.rkt")

;; source: contract 7, "ctx-on is an effect labelled ctx.on(\"name\")"
(test-case "events/on: registration is a labelled effect; the disposer removes the listener"
  (with-root (ctx)
    (define rf (context-fiber ctx))
    (define before (labels-of rf))
    (define log (make-recorder))
    (check-equal? (ctx-listeners ctx 'spec/event) '())
    (define d (ctx-on ctx 'spec/event (lambda (x) (note! log x))))
    (check-true (disposer? d))
    (check-equal? (disposer-label d) "ctx.on(\"spec/event\")")
    (check-equal? (labels-of rf) (append before '("ctx.on(\"spec/event\")")))
    (check-equal? (length (ctx-listeners ctx 'spec/event)) 1)
    (check-true (andmap procedure? (ctx-listeners ctx 'spec/event)))
    (check-equal? (ctx-emit ctx 'spec/event 1) (void))
    (check-equal? (d) (void))
    (ctx-emit ctx 'spec/event 2)
    (check-equal? (notes log) '(1))
    (check-equal? (ctx-listeners ctx 'spec/event) '())
    (check-equal? (labels-of rf) before)))

;; source: contract 7, "Listeners are kept in registration order, prepend? ones
;; in front"; recon 01 S7 (observed: d-prepend, c-prepend, a, b)
(test-case "events/on / S7: registration order, with prepended listeners in front"
  (with-root (ctx)
    (define log (make-recorder))
    (ctx-on ctx 'spec/order (lambda () (note! log 'a)))
    (ctx-on ctx 'spec/order (lambda () (note! log 'b)))
    (ctx-on ctx 'spec/order (lambda () (note! log 'c-prepend)) #:prepend? #t)
    (ctx-on ctx 'spec/order (lambda () (note! log 'd-prepend)) #:prepend? #t)
    (ctx-emit ctx 'spec/order)
    (check-equal? (notes log) '(d-prepend c-prepend a b))
    (check-equal? (length (ctx-listeners ctx 'spec/order)) 4)))

;; source: contract 7, "A listener is called with the dispatch arguments, with
;; current-context set to the registering context"
(test-case "events/listener: receives the arguments and its registering context"
  (with-root (ctx)
    (define seen (make-recorder))
    (define derived (context-extend ctx (hasheq 'tag 'derived)))
    (ctx-on derived 'spec/args
            (lambda args (note! seen (list args (eq? (current-context) derived)))))
    (ctx-emit ctx 'spec/args 1 'two "three")
    (ctx-emit ctx 'spec/args)
    (check-equal? (notes seen) '(((1 two "three") #t) (() #t)))))

;; source: contract 3, "Functions that take a key also accept a string"
(test-case "events/keys: a string event name is the same event as its symbol"
  (with-root (ctx)
    (define log (make-recorder))
    (ctx-on ctx "spec/text" (lambda (x) (note! log x)))
    (ctx-emit ctx 'spec/text 1)
    (ctx-emit ctx "spec/text" 2)
    (check-equal? (notes log) '(1 2))
    (check-equal? (length (ctx-listeners ctx "spec/text")) 1)))

;; source: packages/AGENTS.md "Registry contributions prove disposal";
;; CONVENTIONS "A registration test disposes the fiber and observes the removal"
(test-case "events/on: a listener disappears when its fiber is disposed"
  (with-root (ctx)
    (define log (make-recorder))
    (define f (ctx-plugin ctx (lambda (c config)
                                (ctx-on c 'spec/owned (lambda (x) (note! log x)))
                                (void))))
    (await f)
    (ctx-emit ctx 'spec/owned 1)
    (fiber-dispose! f)
    (ctx-emit ctx 'spec/owned 2)
    (check-equal? (notes log) '(1))
    (check-equal? (ctx-listeners ctx 'spec/owned) '())))

;; source: recon 01 Events, "There is no filtering by the listener owner's
;; fiber state. A listener receives events from the moment it is registered"
(test-case "events/on: a listener registered through a pending fiber still receives events"
  (with-root (ctx)
    (define log (make-recorder))
    (define f (ctx-inject ctx '(missing) void))
    (check-eq? (fiber-state f) 'pending)
    (ctx-on (fiber-context f) 'spec/pending (lambda (x) (note! log x)))
    (ctx-emit ctx 'spec/pending 'delivered)
    (check-equal? (notes log) '(delivered))))

;; source: contract 7, emit bullet; events.ts emit; recon 01 S8
(test-case "events/emit / S8: runs in the calling task; the first exception stops delivery"
  (with-root (ctx)
    (define log (make-recorder))
    (define me (current-thread))
    (ctx-on ctx 'spec/emit (lambda () (note! log (list 'first (eq? (current-thread) me)))))
    (ctx-on ctx 'spec/emit (lambda () (raise-user-error "listener failed")))
    (ctx-on ctx 'spec/emit (lambda () (note! log 'third)))
    (check-exn #rx"listener failed" (lambda () (ctx-emit ctx 'spec/emit)))
    (check-equal? (notes log) '((first #t)))
    ;; Return values are ignored.
    (ctx-on ctx 'spec/emit-values (lambda () 'ignored))
    (check-equal? (ctx-emit ctx 'spec/emit-values) (void))
    (check-equal? (ctx-emit ctx 'spec/nobody 1 2 3) (void))))

;; source: contract 7, parallel bullet, "run every listener as its own task"
(test-case "events/parallel: listeners run as separate tasks and all are awaited"
  (with-root (ctx)
    (define log (make-recorder))
    (define handoff (make-gate))
    (define me (current-thread))
    ;; The first listener can only finish after the second has started.
    (ctx-on ctx 'spec/parallel
            (lambda (x)
              (gate-wait handoff)
              (note! log (list 'first x (eq? (current-thread) me)))))
    (ctx-on ctx 'spec/parallel
            (lambda (x)
              (note! log (list 'second x (eq? (current-thread) me)))
              (gate-open! handoff)))
    (check-equal? (ctx-parallel ctx 'spec/parallel 'arg) (void))
    (check-equal? (notes log) '((second arg #f) (first arg #f)))
    (check-equal? (ctx-parallel ctx 'spec/nobody) (void))))

;; source: contract 7, parallel bullet, exn:fail:cordis:aggregate; events.ts
;; parallel; recon 01 S8
(test-case "events/parallel / S8: failures are collected after every listener ran"
  (with-root (ctx)
    (define log (make-recorder))
    (ctx-on ctx 'spec/parallel-fail (lambda () (raise-user-error "first failure")))
    (ctx-on ctx 'spec/parallel-fail (lambda () (yield-task) (note! log 'survivor)))
    (ctx-on ctx 'spec/parallel-fail (lambda () (raise-user-error "second failure")))
    (define e (with-handlers ([exn:fail? values]) (ctx-parallel ctx 'spec/parallel-fail)))
    (check-pred exn:fail:cordis:aggregate? e)
    (check-pred exn:fail:cordis? e)
    (check-equal? (notes log) '(survivor))
    (define errors (exn:fail:cordis:aggregate-errors e))
    (check-equal? (length errors) 2)
    (check-equal? (sort (map exn-message errors) string<?)
                  '("first failure" "second failure"))))

;; source: contract 7, serial and bail bullet; events.ts isBailed; recon 01 S8
(define (first-bailed-result dispatch)
  (with-root (ctx)
    (define log (make-recorder))
    (check-equal? (dispatch ctx 'spec/nobody 1) (void))
    (ctx-on ctx 'spec/bail (lambda (x) (note! log 'returns-false) #f))
    (ctx-on ctx 'spec/bail (lambda (x) (note! log 'returns-void) (void)))
    (ctx-on ctx 'spec/bail (lambda (x) (note! log 'returns-null) 'null))
    (check-equal? (dispatch ctx 'spec/bail 1) (void))
    (ctx-on ctx 'spec/bail (lambda (x) (yield-task) (note! log 'returns-zero) 0))
    (ctx-on ctx 'spec/bail (lambda (x) (note! log 'never-called) 'late))
    (check-equal? (dispatch ctx 'spec/bail 1) 0)
    (check-equal? (drop (notes log) 3)
                  '(returns-false returns-void returns-null returns-zero))
    (ctx-on ctx 'spec/bail-throw (lambda () (raise-user-error "bail failed")))
    (ctx-on ctx 'spec/bail-throw (lambda () (note! log 'after-throw) 'value))
    (check-exn #rx"bail failed" (lambda () (dispatch ctx 'spec/bail-throw)))
    (check-false (memq 'after-throw (notes log)))))

;; source: contract 7, serial and bail bullet (bail); events.ts bail; recon 01 S8
(test-case "events/bail / S8: returns the first bailed result, else void"
  (first-bailed-result ctx-bail))

;; source: contract 7, serial and bail bullet (serial); events.ts serial; recon 01 S8
(test-case "events/serial / S8: returns the first bailed result, else void"
  (first-bailed-result ctx-serial))

;; source: contract 7, signature of bailed?; events.ts isBailed ("0 and '' bail")
(test-case "events/bailed?: everything except #f, void and 'null bails"
  (check-false (bailed? #f))
  (check-false (bailed? (void)))
  (check-false (bailed? 'null))
  (check-true (bailed? 0))
  (check-true (bailed? ""))
  (check-true (bailed? '()))
  (check-true (bailed? #t)))

;; source: contract 7, waterfall bullet; events.ts waterfall; recon 01 S9
(test-case "events/waterfall / S9: listeners wrap the rest of the chain ending in inner"
  (with-root (ctx)
    (define log (make-recorder))
    (check-eq? (ctx-waterfall ctx 'spec/waterfall 'arg (lambda () 'inner-only)) 'inner-only)
    (ctx-on ctx 'spec/waterfall
            (lambda (x next) (note! log (list 'w1 x)) (list 'w1 (next))))
    (ctx-on ctx 'spec/waterfall
            (lambda (x next) (note! log (list 'w2 x)) (list 'w2 (next))))
    (define result
      (ctx-waterfall ctx 'spec/waterfall 'arg (lambda () (note! log 'inner) 'inner)))
    (check-equal? result '(w1 (w2 inner)))
    (check-equal? (notes log) '((w1 arg) (w2 arg) inner))))

;; source: contract 7, waterfall bullet; events.ts waterfall ("A listener that
;; returns without calling next() vetoes the rest, including inner")
(test-case "events/waterfall: a listener that does not call next short-circuits the chain"
  (with-root (ctx)
    (define log (make-recorder))
    (ctx-on ctx 'spec/veto (lambda (next) (note! log 'outer) 'vetoed))
    (ctx-on ctx 'spec/veto (lambda (next) (note! log 'skipped) (next)))
    (check-eq? (ctx-waterfall ctx 'spec/veto (lambda () (note! log 'inner) 'inner)) 'vetoed)
    (check-equal? (notes log) '(outer))))

;; source: contract 7, error bullet `next() called multiple times`;
;; cordis-core-lifecycle.spec.ts "supports symbol events and rejects repeated
;; waterfall delegation" (recon case 8). A JavaScript symbol event name maps
;; to an uninterned symbol here.
(test-case "case 8: uninterned-symbol events and the waterfall next() guard"
  (with-root (ctx)
    (define name (string->uninterned-symbol "rc11-event"))
    (define received (make-recorder))
    (ctx-on ctx name (lambda (x) (note! received x)))
    (ctx-emit ctx name 1)
    (check-equal? (notes received) '(1))
    (define waterfall (string->uninterned-symbol "rc11-waterfall"))
    (ctx-on ctx waterfall (lambda (next) (next) (next)))
    (define e (with-handlers ([exn:fail? values]) (ctx-waterfall ctx waterfall (lambda () 1))))
    (check-pred exn:fail:cordis? e)
    (check-regexp-match #rx"next\\(\\) called multiple times" (exn-message e))))

;; source: contract 7, "#:filter ... listeners registered with #:global? #t
;; bypass it"; events.ts _resolve; recon 01 S11
(test-case "events/filter / S11: a filtered dispatch reaches matching and global listeners only"
  (with-root (ctx)
    (define log (make-recorder))
    (define red (context-extend ctx (hasheq 'color 'red)))
    (define blue (context-extend ctx (hasheq 'color 'blue)))
    (ctx-on red 'spec/filtered (lambda (x) (note! log 'red)))
    (ctx-on blue 'spec/filtered (lambda (x) (note! log 'blue)))
    (ctx-on blue 'spec/filtered (lambda (x) (note! log 'blue-global)) #:global? #t)
    (define (red? c) (eq? (context-meta c 'color) 'red))
    (ctx-dispatch ctx 'emit 'spec/filtered '(1) #:filter red?)
    (check-equal? (notes log) '(red blue-global))
    (ctx-dispatch ctx 'emit 'spec/filtered '(1))
    (check-equal? (drop (notes log) 2) '(red blue blue-global))
    (check-equal? (ctx-dispatch ctx 'bail 'spec/filtered '(1)
                                #:filter (lambda (c) #f))
                  (void))))

;; source: recon 01 S11, "a Service dispatching with itself as receiver reaches
;; only its own scope"; service.ts [symbols.filter]
(test-case "events/filter / S11: a realm filter delivers to listeners of one scope"
  (with-root (ctx)
    (define log (make-recorder))
    (ctx-provide ctx 'svc 'shared)
    (define iso (context-isolate ctx 'svc))
    (ctx-provide iso 'svc 'private)
    (ctx-on ctx 'svc/changed (lambda () (note! log 'shared-scope)))
    (ctx-on iso 'svc/changed (lambda () (note! log 'isolated-scope)))
    (define (same-scope-as owner)
      (lambda (c) (eq? (context-realm c 'svc) (context-realm owner 'svc))))
    (ctx-dispatch iso 'emit 'svc/changed '() #:filter (same-scope-as iso))
    (ctx-dispatch ctx 'emit 'svc/changed '() #:filter (same-scope-as ctx))
    (check-equal? (notes log) '(isolated-scope shared-scope))))

;; source: contract 7, "Before a non-internal dispatch, if 'internal/dispatch
;; has listeners, emit (mode name args)"; recon 01 S10
(test-case "events/internal-dispatch / S10: observes non-internal dispatches only"
  (with-root (ctx)
    (define seen (make-recorder))
    (ctx-on ctx 'internal/dispatch
            (lambda (mode name args) (note! seen (list (format "~a" mode) name args))))
    (ctx-emit ctx 'e 0)
    (ctx-bail ctx 'spec/b 'x 'y)
    (ctx-serial ctx 'spec/s)
    (ctx-parallel ctx 'spec/p 1)
    (ctx-emit ctx 'internal/custom 1)
    (ctx-provide ctx 'svc 1)
    (check-equal? (notes seen)
                  '(("emit" e (0))
                    ("bail" spec/b (x y))
                    ("serial" spec/s ())
                    ("parallel" spec/p (1))))
    (ctx-waterfall ctx 'spec/w 'arg (lambda () 'inner))
    (define last-seen (last (notes seen)))
    (check-equal? (take last-seen 2) '("waterfall" spec/w))
    (check-equal? (first (third last-seen)) 'arg)))

;; source: contract 7, "The listener list used by a dispatch is the list at the
;; time the dispatch starts"; recon 01 S7
(test-case "events/snapshot / S7: listeners added or removed during a dispatch"
  (with-root (ctx)
    (define log (make-recorder))
    (define remove-b (box #f))
    (ctx-on ctx 'spec/snapshot
            (lambda ()
              (note! log 'a)
              ((unbox remove-b))
              (ctx-on ctx 'spec/snapshot (lambda () (note! log 'added-late)))))
    (set-box! remove-b (ctx-on ctx 'spec/snapshot (lambda () (note! log 'b))))
    (ctx-emit ctx 'spec/snapshot)
    ;; b was removed during the dispatch and still ran; the new listener did not.
    (check-equal? (notes log) '(a b))
    (ctx-emit ctx 'spec/snapshot)
    (check-equal? (drop (notes log) 2) '(a added-late))))

;; source: contract 7, signature of ctx-once; events.ts once; recon 01 S7
(test-case "events/once / S7: the listener runs for one dispatch and is then removed"
  (with-root (ctx)
    (define log (make-recorder))
    (define d (ctx-once ctx 'spec/once (lambda (x) (note! log x) 'result)))
    (check-true (disposer? d))
    (check-equal? (length (ctx-listeners ctx 'spec/once)) 1)
    (check-eq? (ctx-bail ctx 'spec/once 1) 'result)
    (ctx-emit ctx 'spec/once 2)
    (check-equal? (notes log) '(1))
    (check-equal? (ctx-listeners ctx 'spec/once) '())
    (define never (ctx-once ctx 'spec/once (lambda (x) (note! log 'never))))
    (never)
    (ctx-emit ctx 'spec/once 3)
    (check-equal? (notes log) '(1))
    (define front (ctx-once ctx 'spec/once-order (lambda () (note! log 'prepended)) #:prepend? #t))
    (ctx-on ctx 'spec/once-order (lambda () (note! log 'regular)))
    (ctx-emit ctx 'spec/once-order)
    (check-equal? (drop (notes log) 1) '(prepended regular))
    (check-true (disposer? front))))

;; source: contract 7, "It first offers (ctx name listener options) to
;; 'internal/listener through bail ... a bailed result is returned instead of
;; registering"; events.ts on
(test-case "events/internal-listener: a bailed result replaces the registration"
  (with-root (ctx)
    (define offers (make-recorder))
    (ctx-on ctx 'internal/listener
            (lambda (c name listener options)
              (note! offers (list (eq? c ctx)
                                  name
                                  (procedure? listener)
                                  (hash-ref options 'prepend 'missing)
                                  (hash-ref options 'global 'missing)))
              (and (eq? name 'claimed/event)
                   (ctx-effect c void #:label "claimed-by-service"))))
    (define log (make-recorder))
    (define claimed (ctx-on ctx 'claimed/event (lambda () (note! log 'claimed)) #:prepend? #t))
    (define normal (ctx-on ctx 'spec/unclaimed (lambda () (note! log 'normal)) #:global? #t))
    (check-equal? (disposer-label claimed) "claimed-by-service")
    (check-equal? (disposer-label normal) "ctx.on(\"spec/unclaimed\")")
    (check-equal? (ctx-listeners ctx 'claimed/event) '())
    (ctx-emit ctx 'claimed/event)
    (ctx-emit ctx 'spec/unclaimed)
    (check-equal? (notes log) '(normal))
    (check-equal? (notes offers)
                  '((#t claimed/event #t #t #f) (#t spec/unclaimed #t #f #t)))))

;; source: contract 7, signature of ctx-dispatch
(test-case "events/dispatch: ctx-dispatch runs any mode by name"
  (with-root (ctx)
    (define log (make-recorder))
    (ctx-on ctx 'spec/generic (lambda (x) (note! log x) (* x 2)))
    (check-equal? (ctx-dispatch ctx 'emit 'spec/generic '(1)) (void))
    (check-equal? (ctx-dispatch ctx 'parallel 'spec/generic '(2)) (void))
    (check-equal? (ctx-dispatch ctx 'bail 'spec/generic '(3)) 6)
    (check-equal? (ctx-dispatch ctx 'serial 'spec/generic '(4)) 8)
    (check-equal? (notes log) '(1 2 3 4))
    (ctx-on ctx 'spec/generic-waterfall (lambda (x next) (list x (next))))
    (check-equal? (ctx-dispatch ctx 'waterfall 'spec/generic-waterfall '(5)
                                #:inner (lambda () 'inner))
                  '(5 inner))))

;; source: contract 7, serial bullet, "In Racket both may await"
(test-case "events/serial: listeners may await and still run one after another"
  (with-root (ctx)
    (define log (make-recorder))
    (define gate (make-gate))
    (ctx-on ctx 'spec/serial-await
            (lambda ()
              (note! log 'first-start)
              (gate-wait gate)
              (note! log 'first-end)
              #f))
    (ctx-on ctx 'spec/serial-await (lambda () (note! log 'second) 'done))
    (define dispatching (spawn-task (lambda () (ctx-serial ctx 'spec/serial-await))))
    (yield-until (lambda () (pair? (notes log))))
    (yield-times 3)
    (check-equal? (notes log) '(first-start))
    (gate-open! gate)
    (check-eq? (await dispatching) 'done)
    (check-equal? (notes log) '(first-start first-end second))))
