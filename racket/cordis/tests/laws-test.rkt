#lang racket/base
;; The fifteen laws of docs/racket/cordis-analysis.md section 7, one group per law, with
;; randomized-schedule property tests for reversal, satisfaction, inertia and confluence.
;; Random choices come from seeded generators, so every run takes the same schedule.
(require rackunit
         racket/generator
         racket/list
         racket/tcp
         cordis
         cordis/testing
         "common.rkt")

(define (labels f) (map disposer-label (fiber-effects f)))

(define (busy? f) (and (memq (fiber-state f) '(loading unloading)) #t))

;; Waits until none of `fibers` has a transition in flight, including transitions started
;; when earlier ones ended.
(define (settle fibers)
  (let loop ([rounds 0])
    (when (> rounds 10000) (error 'settle "no quiescence"))
    (yield-task)
    (yield-task)
    (define busy (filter busy? fibers))
    (unless (null? busy)
      (for ([f (in-list busy)]) (await/t (wrap-evt f void)))
      (loop (add1 rounds)))))

(define-syntax-rule (with-seed seed body ...)
  (parameterize ([current-pseudo-random-generator (make-pseudo-random-generator)])
    (random-seed seed)
    body ...))

;; ---------------------------------------------------------------------------------------
;; Law 1: reversal

;; Installs a random mix of effects through `c` and returns nothing an owner must keep.
(define (install-random-effects c depth)
  (for ([i (in-range (+ 1 (random 6)))])
    (define tag (string->symbol (format "k~a-~a-~a" depth i (random 1000000))))
    (case (random 7)
      [(0) (ctx-on c tag void)]
      [(1) (ctx-on c 'shared-event void #:prepend? (zero? (random 2)))]
      [(2) (ctx-provide c tag i)]
      [(3) (ctx-accessor c tag #:get (lambda (reader) i))]
      [(4) (ctx-effect c (lambda ()
                           (generator ()
                             (yield (ctx-on c tag void))
                             (yield (ctx-provide c tag i))
                             (void))))]
      [(5) (ctx-provide c tag (make-hasheq (list (cons 'member i))))
           (ctx-mixin c tag (hasheq 'member (string->symbol (format "~a/member" tag))))]
      [else
       (when (< depth 3)
         (ctx-plugin c (lambda (inner config)
                         (install-random-effects inner (add1 depth))
                         (void))))])))

(test-case "law 1: disposing a fiber restores the listener table, store and property table"
  (with-root-context (ctx)
    (ctx-on ctx 'shared-event void)
    (ctx-provide ctx 'base 0)
    (with-seed 1001
      (for ([round (in-range 40)])
        (check-kernel-restored
         (lambda ()
           (define f (ctx-plugin ctx (lambda (c config)
                                       (install-random-effects c 0)
                                       (void))))
           (await/t f)
           (check-eq? (fiber-state f) 'active)
           (fiber-dispose! f))
         ctx)))))

(test-case "law 1: a restart ends in the same observable state"
  (with-root-context (ctx)
    (define f (ctx-plugin ctx (lambda (c config)
                                (ctx-on c 'event void)
                                (ctx-provide c 'service 1)
                                (ctx-plugin c (lambda (inner config)
                                                (ctx-on inner 'event void)
                                                (void)))
                                (void))))
    (await/t f)
    (yield-task)
    (check-kernel-restored (lambda () (fiber-restart! f)) ctx)))

(test-case "law 1: effects disposed in any order leave nothing behind"
  (with-root-context (ctx)
    (with-seed 1002
      (for ([round (in-range 20)])
        (check-kernel-restored
         (lambda ()
           (define disposers
             (for/list ([i (in-range 12)])
               (case (modulo i 3)
                 [(0) (ctx-on ctx 'event void)]
                 [(1) (ctx-provide ctx (string->symbol (format "s~a" i)) i)]
                 [else (ctx-accessor ctx (string->symbol (format "a~a" i))
                                     #:get (lambda (c) i))])))
           (for ([d (in-list (shuffle disposers))])
             (d)))
         ctx)))))

;; ---------------------------------------------------------------------------------------
;; Law 2: LIFO

(test-case "law 2: inverses run in reverse order; a nested effect runs within its parent"
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (define d
      (ctx-effect ctx (lambda ()
                        (list (lambda () (note 1))
                              (ctx-effect ctx (lambda ()
                                                (list (lambda () (note 'nested-1))
                                                      (lambda () (note 'nested-2)))))
                              (lambda () (note 3))))))
    (d))
  (check-equal? (notes) '(3 nested-2 nested-1 1)))

;; ---------------------------------------------------------------------------------------
;; Law 3: single shot

(test-case "law 3: a disposer runs its inverses at most once, whoever calls it"
  (define count 0)
  (with-root-context (ctx)
    (define f (ctx-plugin ctx (lambda (c config) (void))))
    (await/t f)
    (define d (ctx-effect (fiber-context f) (lambda () (lambda () (set! count (add1 count))))))
    (define callers (for/list ([i (in-range 5)]) (spawn-task (lambda () (d)))))
    (check-equal? (await-all callers) (make-list 5 (void)))
    (fiber-dispose! f)
    (check-equal? (d) (void)))
  (check-equal? count 1))

;; ---------------------------------------------------------------------------------------
;; Law 4: setup failure rolls back

(test-case "law 4: a failing setup runs what it yielded and leaves nothing registered"
  (with-root-context (ctx)
    (check-kernel-restored
     (lambda ()
       (check-exn #rx"setup failed"
                  (lambda ()
                    (ctx-effect ctx (lambda ()
                                      (generator ()
                                        (yield (ctx-on ctx 'event void))
                                        (yield (ctx-provide ctx 'service 1))
                                        (raise-user-error "setup failed")))))))
     ctx)
    (check-equal? (labels (context-fiber ctx)) '())))

;; ---------------------------------------------------------------------------------------
;; Law 5: no effect while unloading

(test-case "law 5: every registration form raises on an unloading and on a disposed fiber"
  (with-root-context (ctx)
    (define refused '())
    (define (attempt name thunk)
      (with-handlers ([exn:fail:cordis:inactive? (lambda (e) (set! refused (cons name refused)))])
        (thunk)))
    (define c #f)
    (define (try-all)
      (attempt 'effect (lambda () (ctx-effect c void)))
      (attempt 'on (lambda () (ctx-on c 'event void)))
      (attempt 'provide (lambda () (ctx-provide c 'service 1)))
      (attempt 'accessor (lambda () (ctx-accessor c 'name #:get void)))
      (attempt 'plugin (lambda () (ctx-plugin c (lambda (inner config) (void))))))
    (define f (ctx-plugin ctx (lambda (inner config) (set! c inner) try-all)))
    (await/t f)
    (fiber-dispose! f)
    (check-equal? (reverse refused) '(effect on provide accessor plugin))
    (set! refused '())
    (try-all)
    (check-equal? (reverse refused) '(effect on provide accessor plugin))))

;; ---------------------------------------------------------------------------------------
;; Laws 6 and 13: satisfaction and confluence over random schedules

;; A universe of plugins over the keys 0..3. Plugin i provides key i when i < 4 and injects
;; only smaller keys, so the dependency relation has no cycle; plugins 4..7 provide nothing.
(define plugin-count 8)

(define (plugin-injects i)
  (case i
    [(0) '()] [(1) '(0)] [(2) '(0 1)] [(3) '(1)]
    [(4) '(0)] [(5) '(2 3)] [(6) '(3)] [else '()]))

(define (key-name k) (string->symbol (format "key~a" k)))

;; `yields` is how often the body gives the baton away before it returns.
(define (universe-plugin i yields)
  (make-plugin (lambda (c config)
                 (when (< i 4) (ctx-provide c (key-name i) i))
                 (ctx-on c 'universe-event void)
                 (for ([n (in-range yields)]) (yield-task))
                 (void))
               #:name (format "plugin-~a" i)
               #:inject (map key-name (plugin-injects i))))

;; The plugins that must be active when exactly `mounted` are mounted: the least set closed
;; under "every injected key is provided by an active plugin".
(define (expected-active mounted)
  (let loop ([active '()])
    (define next
      (for/list ([i (in-list mounted)]
                 #:when (andmap (lambda (k) (memv k active)) (plugin-injects i)))
        i))
    (if (equal? next active) active (loop next))))

;; Runs a random schedule of mounts, disposals, restarts and yields, then mounts or
;; disposes until exactly `final` is mounted. Returns a table from plugin index to fiber.
(define (run-schedule ctx final steps)
  (define mounted (make-hasheqv))
  (define all-fibers '())
  (define (mount! i)
    (define f (ctx-plugin ctx (universe-plugin i (random 3))))
    (hash-set! mounted i f)
    (set! all-fibers (cons f all-fibers)))
  (define (dispose! i)
    (define f (hash-ref mounted i))
    (hash-remove! mounted i)
    (fiber-dispose! f))
  (for ([step (in-range steps)])
    (define i (random plugin-count))
    (case (random 4)
      [(0 1) (unless (hash-has-key? mounted i) (mount! i))]
      [(2) (when (hash-has-key? mounted i) (dispose! i))]
      [else
       (define f (hash-ref mounted i #f))
       (cond
         [(and f (eq? (fiber-state f) 'active)) (spawn-task (lambda () (fiber-restart! f)))]
         [else (yield-task)])]))
  (for ([i (in-range plugin-count)])
    (cond
      [(and (memv i final) (not (hash-has-key? mounted i))) (mount! i)]
      [(and (not (memv i final)) (hash-has-key? mounted i)) (dispose! i)]))
  (settle all-fibers)
  mounted)

(test-case "law 6: after any schedule, active fibers are exactly the satisfied ones"
  (with-seed 6001
    (for ([round (in-range 25)])
      (define final (for/list ([i (in-range plugin-count)] #:when (zero? (random 2))) i))
      (with-root-context (ctx)
        (define mounted (run-schedule ctx final 30))
        (define active (expected-active final))
        (for ([i (in-list final)])
          (define f (hash-ref mounted i))
          (check-eq? (fiber-state f) (if (memv i active) 'active 'pending)
                     (format "plugin ~a of ~a" i final))
          ;; a loaded fiber's committed view names live, active providers
          (when (memv i active)
            (for ([k (in-list (plugin-injects i))])
              (check-equal? (hash-ref (fiber-committed f) (key-name k)) k)
              (check-eq? (fiber-state (hash-ref mounted k)) 'active))))
        (check-equal? (length (ctx-fibers ctx)) (length final))))))

(test-case "law 6: withdrawing a dependency makes its dependents pending"
  (with-root-context (ctx)
    (define d (ctx-provide ctx 'dep 1))
    (define direct (ctx-plugin ctx (make-plugin (lambda (c config) (ctx-provide c 'derived 2))
                                                #:inject '(dep))))
    (define indirect (ctx-plugin ctx (make-plugin (lambda (c config) (void))
                                                  #:inject '(derived))))
    (settle (list direct indirect))
    (check-equal? (map fiber-state (list direct indirect)) '(active active))
    (d)
    (settle (list direct indirect))
    (check-equal? (map fiber-state (list direct indirect)) '(pending pending))))

(test-case "law 13: the final state does not depend on the order or the history"
  (with-seed 13001
    (for ([round (in-range 12)])
      (define final (for/list ([i (in-range plugin-count)] #:when (zero? (random 2))) i))
      (define (observe steps)
        (with-root-context (ctx)
          (define mounted (run-schedule ctx final steps))
          (list (kernel-snapshot ctx)
                (for/list ([i (in-list final)])
                  (cons i (fiber-state (hash-ref mounted i)))))))
      ;; loaded once from scratch, and reached through two different histories
      (define fresh (observe 0))
      (check-equal? (observe 25) fresh)
      (check-equal? (observe 40) fresh))))

(test-case "law 13: two independent plugins in either order"
  (define (a c config) (ctx-provide c 'a 1) (ctx-on c 'event void) (void))
  (define (b c config) (ctx-provide c 'b 2) (ctx-on c 'event void) (ctx-on c 'other void) (void))
  (define (observe . bodies)
    (with-root-context (ctx)
      (define fibers (for/list ([body (in-list bodies)])
                       (ctx-plugin ctx (make-plugin body #:name (symbol->string
                                                                 (object-name body))))))
      (settle fibers)
      (hash-update (kernel-snapshot ctx) 'fibers (lambda (names) (sort names string<?)))))
  (check-equal? (observe a b) (observe b a)))

;; ---------------------------------------------------------------------------------------
;; Law 7: provider replacement

(test-case "law 7: a replaced provider reloads dependents, even with an equal value"
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (define d (ctx-provide ctx 'config (list 1 2 3)))
    (define f (ctx-plugin ctx (make-plugin (lambda (c config)
                                             (note 'apply)
                                             (lambda () (note 'cleanup)))
                                           #:inject '(config))))
    (await/t f)
    (d)
    (ctx-provide ctx 'config (list 1 2 3))
    (settle (list f))
    (check-eq? (fiber-state f) 'active)
    (check-equal? (notes) '(apply cleanup apply))
    ;; in-place replacement is invisible to dependents
    (ctx-set! ctx 'config 'something-else)
    (settle (list f))
    (check-equal? (notes) '(apply cleanup apply))
    (check-equal? (ctx-ref (fiber-context f) 'config) 'something-else)))

;; ---------------------------------------------------------------------------------------
;; Law 8: coeffect ordering

(test-case "law 8: dependents unload first and can read the provider throughout"
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (define provider
      (ctx-plugin ctx (make-plugin (lambda (c config)
                                     (ctx-provide c 'db 'alive)
                                     (lambda () (note 'provider-inverse)))
                                   #:name "provider")))
    (define (consumer name)
      (ctx-plugin ctx (make-plugin (lambda (c config)
                                     (lambda ()
                                       (yield-task)
                                       (yield-task)
                                       (note (list name (ctx-ref c 'db)))))
                                   #:name name #:inject '(db))))
    (await/t provider)
    (define consumers (map consumer '("c1" "c2" "c3")))
    (settle consumers)
    (fiber-dispose! provider)
    (check-equal? (last (notes)) 'provider-inverse)
    (check-equal? (sort (drop-right (notes) 1) string<? #:key car)
                  '(("c1" alive) ("c2" alive) ("c3" alive)))
    (check-equal? (map fiber-state consumers) '(pending pending pending))))

;; ---------------------------------------------------------------------------------------
;; Law 9: inertia

(test-case "law 9: toggling a dependency during slow transitions never overlaps them"
  (with-seed 9001
    (with-root-context (ctx)
      (define in-flight 0)
      (define overlaps 0)
      (define (enter!)
        (set! in-flight (add1 in-flight))
        (when (> in-flight 1) (set! overlaps (add1 overlaps))))
      (define (leave!) (set! in-flight (sub1 in-flight)))
      (define f
        (ctx-plugin ctx (make-plugin (lambda (c config)
                                       (enter!)
                                       (for ([n (in-range (random 4))]) (yield-task))
                                       (leave!)
                                       (lambda ()
                                         (enter!)
                                         (for ([n (in-range (random 4))]) (yield-task))
                                         (leave!)))
                                     #:inject '(dep))))
      (define d #f)
      (define withdrawals '())
      (for ([step (in-range 60)])
        (cond
          [d (let ([old d])
               (set! d #f)
               ;; the withdrawal waits for the dependent, so it gets a task of its own;
               ;; one yield lets it take the service out of the store
               (set! withdrawals (cons (spawn-task (lambda () (old))) withdrawals))
               (yield-task))]
          [else (set! d (ctx-provide ctx 'dep step))])
        (for ([n (in-range (random 3))]) (yield-task)))
      (await-all withdrawals)
      (settle (list f))
      (check-equal? overlaps 0)
      (check-equal? in-flight 0)
      ;; the final state matches the final target
      (check-eq? (fiber-state f) (if d 'active 'pending)))))

;; ---------------------------------------------------------------------------------------
;; Law 10: cascade

(test-case "law 10: children are disposed before their parent is"
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (ctx-on ctx 'internal/status
            (lambda (f old) (when (eq? (fiber-state f) 'disposed) (note (fiber-name f)))))
    (define (tree name . children)
      (make-plugin (lambda (c config)
                     (for ([child (in-list children)]) (ctx-plugin c child))
                     (void))
                   #:name name))
    (define parent (ctx-plugin ctx (tree "parent"
                                         (tree "child-a" (tree "grandchild"))
                                         (tree "child-b"))))
    (check-not-false (wait-for (lambda () (= (length (ctx-fibers ctx)) 4))))
    (settle (ctx-fibers ctx))
    (fiber-dispose! parent)
    (check-equal? (ctx-fibers ctx) '())
    (check-equal? (last (notes)) "parent")
    (check-true (< (index-of (notes) "grandchild") (index-of (notes) "child-a")))
    (check-equal? (sort (notes) string<?) '("child-a" "child-b" "grandchild" "parent"))))

;; ---------------------------------------------------------------------------------------
;; Law 11: isolation

(test-case "law 11: a realm hides its service, and notifications stay inside it"
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (define realm-a (context-isolate ctx 'db))
    (define realm-b (context-isolate ctx 'db))
    (define (consumer c name)
      (ctx-plugin c (make-plugin (lambda (inner config)
                                   (note (list name (ctx-ref inner 'db)))
                                   (void))
                                 #:inject '(db))))
    (define in-a (consumer realm-a 'a))
    (define in-b (consumer realm-b 'b))
    (define shared (consumer ctx 'shared))
    (ctx-provide realm-a 'db 'for-a)
    (settle (list in-a in-b shared))
    (check-equal? (map fiber-state (list in-a in-b shared)) '(active pending pending))
    (check-false (ctx-get ctx 'db))
    (check-false (ctx-get realm-b 'db))
    (ctx-provide realm-b 'db 'for-b)
    (ctx-provide ctx 'db 'for-all)
    (settle (list in-a in-b shared))
    (check-equal? (map fiber-state (list in-a in-b shared)) '(active active active))
    ;; each consumer was applied once: no notification crossed a realm
    (check-equal? (notes) '((a for-a) (b for-b) (shared for-all)))))

;; ---------------------------------------------------------------------------------------
;; Law 12: dispatch modes

(test-case "law 12: ordering, short-circuit and failure behaviour of each mode"
  (with-seed 12001
    (with-root-context (ctx)
      (for ([round (in-range 30)])
        (define-values (note notes) (make-recorder))
        (define results
          (for/list ([i (in-range (+ 1 (random 6)))])
            (list-ref (list #f (void) 'null i (lambda () (raise i))) (random 5))))
        (define disposers
          (for/list ([r (in-list results)] [i (in-naturals)])
            (ctx-on ctx 'event (lambda () (note i) (if (procedure? r) (r) r)))))
        (define first-stop (index-where results (lambda (r) (or (procedure? r) (bailed? r)))))
        (define first-raise (index-where results procedure?))
        (define (run thunk) (with-handlers ([number? (lambda (n) (list 'raised n))]) (thunk)))
        ;; bail and serial stop at the first bailed result or the first failure
        (for ([dispatch (in-list (list ctx-bail ctx-serial))])
          (define before (length (notes)))
          (define outcome (run (lambda () (dispatch ctx 'event))))
          (check-equal? (drop (notes) before)
                        (range (if first-stop (add1 first-stop) (length results))))
          (cond
            [(not first-stop) (check-equal? outcome (void))]
            [(procedure? (list-ref results first-stop))
             (check-equal? outcome (list 'raised first-stop))]
            [else (check-equal? outcome (list-ref results first-stop))]))
        ;; emit ignores results and stops at the first failure
        (let ([before (length (notes))])
          (run (lambda () (ctx-emit ctx 'event)))
          (check-equal? (drop (notes) before)
                        (range (if first-raise (add1 first-raise) (length results)))))
        ;; parallel runs every listener and reports every failure
        (let ([before (length (notes))])
          (define outcome
            (with-handlers ([exn:fail:cordis:aggregate? exn:fail:cordis:aggregate-errors])
              (ctx-parallel ctx 'event)))
          (check-equal? (drop (notes) before) (range (length results)))
          (check-equal? (if (void? outcome) '() outcome)
                        (for/list ([r (in-list results)] [i (in-naturals)] #:when (procedure? r))
                          i)))
        (for ([d (in-list disposers)]) (d))))))

;; ---------------------------------------------------------------------------------------
;; Law 14: custodian backstop

(test-case "law 14: threads, ports and listeners a plugin leaks are gone after it unloads"
  (with-root-context (ctx)
    (define leaks #f)
    (define f
      (ctx-plugin ctx (lambda (c config)
                        (define listener (tcp-listen 0 4 #t "127.0.0.1"))
                        (define-values (_host port _peer-host _peer-port)
                          (tcp-addresses listener #t))
                        (define-values (in out) (tcp-connect "127.0.0.1" port))
                        (define worker (thread (lambda () (sync (make-semaphore 0)))))
                        (define task (spawn-task (lambda () (await (make-semaphore 0)))))
                        ;; no inverse is returned for any of them
                        (set! leaks (list in out listener worker task))
                        (void))))
    (await/t f)
    (define-values (in out listener worker task) (apply values leaks))
    (check-false (thread-dead? worker))
    (check-false (port-closed? out))
    (fiber-dispose! f)
    (check-true (thread-dead? worker))
    (check-true (task-done? task))
    (check-true (port-closed? in))
    (check-true (port-closed? out))
    (check-exn exn:fail? (lambda () (tcp-accept-ready? listener)))))

(test-case "law 14: the custodian tree follows the fiber tree"
  (with-root-context (ctx)
    (define child-thread #f)
    (define child-custodian #f)
    (define parent
      (ctx-plugin ctx (lambda (c config)
                        (ctx-plugin c (lambda (inner config)
                                        (set! child-custodian (current-custodian))
                                        (set! child-thread
                                              (thread (lambda () (sync (make-semaphore 0)))))
                                        (void)))
                        (void))))
    (check-not-false (wait-for (lambda () child-thread)))
    (check-not-false (memq child-custodian
                           (custodian-managed-list (fiber-custodian parent)
                                                   (context-custodian ctx))))
    (fiber-dispose! parent)
    (check-true (thread-dead? child-thread))))

;; ---------------------------------------------------------------------------------------
;; Law 15: kill safety at the kernel level

(test-case "law 15: killing tasks inside kernel operations leaves the kernel running"
  (with-root-context (ctx)
    (define g (gate))
    (ctx-on ctx 'slow (lambda () (gate-wait g)))
    (define f (ctx-plugin ctx (lambda (c config) (lambda () (gate-wait g)))))
    (await/t f)
    (define victims
      (list (spawn-task (lambda () (ctx-emit ctx 'slow)))
            (spawn-task (lambda () (ctx-parallel ctx 'slow)))
            (spawn-task (lambda () (ctx-serial ctx 'slow)))
            (spawn-task (lambda () (fiber-await (ctx-plugin ctx (lambda (c config)
                                                                  (gate-wait g))))))
            (spawn-task (lambda () (fiber-dispose! f)))
            (spawn-task (lambda () (ctx-effect ctx (lambda () (gate-wait g)))))))
    (yield-task)
    (yield-task)
    (for-each task-kill! victims)
    (gate-open! g)
    ;; the kernel still dispatches, mounts and unloads
    (define-values (note notes) (make-recorder))
    (ctx-on ctx 'probe note)
    (ctx-emit ctx 'probe 'delivered)
    (check-equal? (notes) '(delivered))
    (define h (ctx-plugin ctx (lambda (c config) (void))))
    (await/t h)
    (check-eq? (fiber-state h) 'active)
    (fiber-dispose! f)
    (check-eq? (fiber-state f) 'disposed)))
