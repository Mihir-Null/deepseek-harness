#lang racket/base
;; Property tests over random schedules: laws 18 to 21 and 36 to 39 of
;; docs/racket/recon/19-paper-digest.md, "Laws an implementation should test".
;;
;; Each property runs `schedule-count` schedules. A schedule draws everything
;; from its own pseudo-random generator, seeded from the base seed, the
;; property number and the schedule index. The base seed is the environment
;; variable CORDIS_TEST_SEED or a fixed default, and every failure message
;; prints it together with the schedule index.
;;
;; Laws 21 and 36 to 39 use small random acyclic inject/provide graphs: specs
;; are ranked, a spec injects only keys whose provider has a lower rank, a
;; child's parent has a lower rank, and each key has at most one provider.
;; Invariants are checked through public observations only: kernel-snapshot,
;; fiber states, committed views and ctx-get results.
(require cordis
         cordis/testing
         rackunit
         racket/list
         "support.rkt")

(define schedule-count 200)

(define base-seed
  (let ([v (getenv "CORDIS_TEST_SEED")])
    (or (and v (string->number v) (exact-nonnegative-integer? (string->number v))
             (string->number v))
        20261113)))

(define (schedule-rng property index)
  (define g (make-pseudo-random-generator))
  (parameterize ([current-pseudo-random-generator g])
    (random-seed (modulo (+ base-seed (* 1000003 property) (* 7919 index)) 2147483647)))
  g)

(define (pick g lst) (list-ref lst (random (length lst) g)))
(define (chance? g p) (< (random g) p))
(define (shuffle/g g lst)
  (parameterize ([current-pseudo-random-generator g]) (shuffle lst)))

;; Runs `schedule` for every index until one reports a failure. `schedule`
;; takes the generator and returns #f or a description of what went wrong.
(define (check-schedules property schedule)
  (let loop ([index 0])
    (when (< index schedule-count)
      (define failure
        (with-handlers ([exn:fail? (lambda (e) (format "exception: ~a" (exn-message e)))])
          (schedule (schedule-rng property index))))
      (if failure
          (fail (format "law ~a, schedule ~a of ~a: ~a (rerun with CORDIS_TEST_SEED=~a)"
                        property index schedule-count failure base-seed))
          (loop (add1 index))))))

(define (report problems)
  (and (pair? (notes problems)) (format "~s" (notes problems))))

(define (problem! problems fmt . args)
  (note! problems (apply format fmt args)))

;; ---------------------------------------------------------------------------
;; Law 18: any-order revert

(define (any-order-revert g)
  (with-root (ctx)
    (define problems (make-recorder))
    (define before (kernel-snapshot ctx))
    (define table (make-hasheqv))
    (define n (add1 (random 8 g)))
    (define (service-key i) (string->symbol (format "law18-service-~a" i)))
    (define (accessor-name i) (string->symbol (format "law18-accessor-~a" i)))
    (define entries
      (for/list ([i (in-range n)])
        (define kind (pick g '(table listener service accessor)))
        (define disposer
          (case kind
            [(table) (ctx-effect ctx (lambda ()
                                       (hash-set! table i #t)
                                       (lambda () (hash-remove! table i))))]
            [(listener) (ctx-on ctx 'law18/event (lambda (log) (note! log i))
                                #:prepend? (chance? g 0.3))]
            [(service) (ctx-provide ctx (service-key i) i)]
            [else (ctx-accessor ctx (accessor-name i) #:get (lambda (reader) i))]))
        (list i kind disposer)))
    (define (present)
      (define heard (make-recorder))
      (ctx-emit ctx 'law18/event heard)
      (sort (append (hash-keys table)
                    (notes heard)
                    (for/list ([e (in-list entries)]
                               #:when (and (eq? (second e) 'service)
                                           (eqv? (ctx-get ctx (service-key (first e))
                                                          #:default 'absent)
                                                 (first e))))
                      (first e))
                    (for/list ([e (in-list entries)]
                               #:when (and (eq? (second e) 'accessor)
                                           (with-handlers ([exn:fail? (lambda (x) #f)])
                                             (eqv? (ctx-ref ctx (accessor-name (first e)))
                                                   (first e)))))
                      (first e)))
            <))
    (unless (equal? (present) (range n))
      (problem! problems "after registration: ~s of ~s" (present) n))
    (for/fold ([remaining (range n)]) ([e (in-list (shuffle/g g entries))])
      ((third e))
      (define expected (remove (first e) remaining))
      (unless (equal? (present) expected)
        (problem! problems "after disposing ~s (~s): ~s, expected ~s"
                  (first e) (second e) (present) expected))
      expected)
    (unless (equal? (kernel-snapshot ctx) before)
      (problem! problems "kernel snapshot not restored"))
    (report problems)))

;; source: digest law 18 (Theorem 43; Definition 46)
(test-case "law 18: effects on table-valued services revert in any order"
  (check-schedules 18 any-order-revert))

;; ---------------------------------------------------------------------------
;; Law 19: operations on different services commute

(define (different-services-commute g)
  (with-root (ctx)
    (define problems (make-recorder))
    (define before (kernel-snapshot ctx))
    (define (side-operations side)
      (for/list ([j (in-range (add1 (random 4 g)))])
        (if (chance? g 0.7)
            (list 'listener side j (chance? g 0.3))
            (list 'service side j))))
    (define (event-of side) (string->symbol (format "law19/~a" side)))
    (define (key-of side j) (string->symbol (format "law19-~a-~a" side j)))
    (define (perform! op)
      (define side (second op))
      (define j (third op))
      (case (first op)
        [(listener) (ctx-on ctx (event-of side) (lambda (log) (note! log j))
                            #:prepend? (fourth op))]
        [else (ctx-provide ctx (key-of side j) (list side j))]))
    (define xs (side-operations 'x))
    (define ys (side-operations 'y))
    (define (interleave)
      (let loop ([xs xs] [ys ys])
        (cond [(null? xs) ys]
              [(null? ys) xs]
              [(chance? g 0.5) (cons (car xs) (loop (cdr xs) ys))]
              [else (cons (car ys) (loop xs (cdr ys)))])))
    (define (observe)
      (list (for/list ([side (in-list '(x y))])
              (define heard (make-recorder))
              (ctx-emit ctx (event-of side) heard)
              (notes heard))
            (for/list ([op (in-list (append xs ys))] #:when (eq? (first op) 'service))
              (ctx-get ctx (key-of (second op) (third op))))
            (kernel-snapshot ctx)))
    (define (run order)
      (define disposers (map perform! order))
      (begin0 (observe)
        (for-each (lambda (d) (d)) (shuffle/g g disposers))))
    (define canonical (run (append xs ys)))
    (unless (equal? (kernel-snapshot ctx) before)
      (problem! problems "kernel snapshot not restored between runs"))
    (define interleaved-order (interleave))
    (define interleaved (run interleaved-order))
    (unless (equal? canonical interleaved)
      (problem! problems "order ~s observed ~s, canonical order observed ~s"
                interleaved-order interleaved canonical))
    (report problems)))

;; source: digest law 19 (Theorem 45)
(test-case "law 19: registrations on different services commute"
  (check-schedules 19 different-services-commute))

;; ---------------------------------------------------------------------------
;; Law 20: removing one component leaves an unrelated one untouched

(define (remove-unrelated-component g)
  (with-root (ctx)
    (define problems (make-recorder))
    (define events '(law20/e0 law20/e1 law20/e2))
    (define table (make-hash))
    (define (contributions who)
      (for/list ([j (in-range (add1 (random 5 g)))])
        (case (random 3 g)
          [(0) (list 'listener (pick g events) (list who j) (chance? g 0.3))]
          [(1) (list 'service (string->symbol (format "law20-~a-~a" who j)) (list who j))]
          [else (list 'entry (list who j))])))
    (define (plugin-for who contribs)
      (make-plugin
       (lambda (c config)
         (for ([x (in-list contribs)])
           (case (first x)
             [(listener) (ctx-on c (second x) (lambda (log) (note! log (third x)))
                                 #:prepend? (fourth x))]
             [(service) (ctx-provide c (second x) (third x))]
             [else (ctx-effect c (lambda ()
                                   (hash-set! table (second x) #t)
                                   (lambda () (hash-remove! table (second x)))))])
           (yield-times (random 2 g)))
         (void))
       #:name (format "law20-~a" who)))
    (define contribs (hasheq 'a (contributions 'a) 'b (contributions 'b)))
    (define fibers
      (for/hasheq ([who (in-list (shuffle/g g '(a b)))])
        (values who (ctx-plugin ctx (plugin-for who (hash-ref contribs who))))))
    (settle-all (hash-values fibers))
    (define (heard-from who)
      (for/list ([event (in-list events)])
        (define heard (make-recorder))
        (ctx-emit ctx event heard)
        (filter (lambda (tag) (eq? (first tag) who)) (notes heard))))
    (define (services-of who)
      (for/list ([x (in-list (hash-ref contribs who))] #:when (eq? (first x) 'service))
        (ctx-get ctx (second x))))
    (define (entries-of who)
      (sort (filter (lambda (tag) (eq? (first tag) who)) (hash-keys table)) < #:key second))
    (define (observe who)
      (define f (hash-ref fibers who))
      (list (heard-from who) (services-of who) (entries-of who) (fiber-state f) (labels-of f)))
    (define before (observe 'b))
    (unless (eq? (fiber-state (hash-ref fibers 'b)) 'active)
      (problem! problems "b is ~s before the removal" (fiber-state (hash-ref fibers 'b))))
    (fiber-dispose! (hash-ref fibers 'a))
    (unless (equal? (observe 'b) before)
      (problem! problems "b observed ~s before and ~s after removing a" before (observe 'b)))
    (unless (and (andmap null? (heard-from 'a))
                 (andmap not (services-of 'a))
                 (null? (entries-of 'a)))
      (problem! problems "a left contributions behind"))
    (report problems)))

;; source: digest law 20 (Theorem 68)
(test-case "law 20: unloading one component leaves an unrelated one unchanged"
  (check-schedules 20 remove-unrelated-component))

;; ---------------------------------------------------------------------------
;; Random acyclic graphs and the schedule driver for laws 21 and 36 to 39

;; rank: position in the dependency order; key: the provided key or #f;
;; injects: keys of lower-rank providers, possibly a key nobody provides;
;; parent: rank of the top-level spec whose body mounts this spec, or #f.
(struct spec (rank name key injects parent) #:transparent)

(define missing-key 'sched-never-provided)

(define (random-graph g)
  (define keys
    (for/list ([i (in-range (+ 3 (random 2 g)))]) (string->symbol (format "sched-k~a" i))))
  (define count (+ 4 (random 3 g)))
  (let loop ([rank 0] [specs '()] [free keys] [provided '()])
    (cond
      [(= rank count) (reverse specs)]
      [else
       (define tops (filter (lambda (s) (not (spec-parent s))) specs))
       (define parent (and (pair? tops) (chance? g 0.25) (spec-rank (pick g tops))))
       (define key (and (pair? free) (chance? g 0.65) (car free)))
       (define injects
         (append (filter (lambda (k) (chance? g 0.4)) provided)
                 (if (chance? g 0.06) (list missing-key) '())))
       (loop (add1 rank)
             (cons (spec rank (format "sched-s~a" rank) key injects parent) specs)
             (if key (cdr free) free)
             (if key (append provided (list key)) provided))])))

(define (graph-keys specs)
  (filter values (map spec-key specs)))

;; One top-level spec's place in a running schedule.
(struct slot (fiber config busy) #:mutable)

;; A schedule in progress on one root. `serving` maps a key to #t from the
;; moment a provider's body has provided it until that provider's own inverse
;; has started to run.
(struct env (ctx g specs slots children tracked problems interleave? serving))

(define (make-env ctx g specs interleave?)
  (env ctx
       g
       specs
       (for/hasheqv ([s (in-list specs)] #:unless (spec-parent s))
         (values (spec-rank s) (slot #f 0 #f)))
       (make-hasheqv)
       (box '())
       (make-recorder)
       interleave?
       (make-hasheq)))

(define (track! e f)
  (set-box! (env-tracked e) (cons f (unbox (env-tracked e)))))

(define (slot-of e s) (hash-ref (env-slots e) (spec-rank s)))
(define (top-level e) (filter (lambda (s) (not (spec-parent s))) (env-specs e)))
(define (children-of e s)
  (filter (lambda (c) (eqv? (spec-parent c) (spec-rank s))) (env-specs e)))

(define (spec-plugin e s)
  (define g (env-g e))
  (make-plugin
   (lambda (c config)
     ;; law 22: the body starts only while every declared key has an active provider
     (for ([k (in-list (spec-injects s))])
       (unless (ctx-get c k)
         (problem! (env-problems e) "~a applied without an active provider of ~a"
                   (spec-name s) k)))
     (ctx-on c (string->symbol (format "sched/~a" (spec-name s))) void)
     (when (spec-key s)
       (ctx-provide c (spec-key s) (list (spec-name s) config))
       (hash-set! (env-serving e) (spec-key s) #t))
     (when (env-interleave? e) (yield-times (random 3 g)))
     ;; A fiber disposed while its body yielded can no longer mount children.
     (when (fiber-uid (context-fiber c))
       (for ([child (in-list (children-of e s))])
         (define f (ctx-plugin c (spec-plugin e child) config))
         (track! e f)
         (hash-set! (env-children e) (spec-rank child) f)))
     (lambda ()
       (define (check-providers! when)
         (for ([k (in-list (spec-injects s))])
           ;; law 23: no inverse of a provider runs before this consumer has unloaded
           (unless (hash-ref (env-serving e) k #f)
             (problem! (env-problems e) "~a ~a its teardown after the provider of ~a ran its own"
                       (spec-name s) when k))
           ;; law 24: an injected service is still readable during teardown
           (with-handlers ([exn:fail? (lambda (x)
                                        (problem! (env-problems e)
                                                  "~a could not read ~a during teardown: ~a"
                                                  (spec-name s) k (exn-message x)))])
             (ctx-ref c k))))
       (check-providers! "began")
       (when (env-interleave? e) (yield-times (random 2 g)))
       (check-providers! "ended")
       (when (spec-key s) (hash-set! (env-serving e) (spec-key s) #f))))
   #:name (spec-name s)
   #:inject (spec-injects s)))

;; Waits for the previous asynchronous operation on this slot, so that
;; operations on one spec are applied one after another.
(define (await-busy! e st)
  (define busy (slot-busy st))
  (when busy
    (await (wrap-evt busy void))
    (with-handlers ([exn:fail? (lambda (x)
                                 (problem! (env-problems e) "operation raised: ~a"
                                           (exn-message x)))])
      (task-result busy))
    (set-slot-busy! st #f)))

(define (insert! e s)
  (define st (slot-of e s))
  (unless (slot-fiber st)
    (await-busy! e st)
    (define f (ctx-plugin (env-ctx e) (spec-plugin e s) (slot-config st)))
    (track! e f)
    (set-slot-fiber! st f)))

(define (retire! e s)
  (define st (slot-of e s))
  (define f (slot-fiber st))
  (when f
    (await-busy! e st)
    (set-slot-fiber! st #f)
    (set-slot-busy! st (spawn-task (lambda () (fiber-dispose! f))))))

(define (replace! e s)
  (define st (slot-of e s))
  (define f (slot-fiber st))
  (when f
    (await-busy! e st)
    (fiber-dispose! f)
    (set-slot-fiber! st #f)
    (insert! e s)))

(define (update! e s config)
  (define st (slot-of e s))
  (define f (slot-fiber st))
  (set-slot-config! st config)
  (when f
    (await-busy! e st)
    (set-slot-busy! st (spawn-task (lambda () (fiber-update! f config))))))

(define (restart! e s)
  (define st (slot-of e s))
  (define f (slot-fiber st))
  (when f
    (await-busy! e st)
    (set-slot-busy! st (spawn-task (lambda () (fiber-restart! f))))))

(define (random-operation! e)
  (define g (env-g e))
  (define s (pick g (top-level e)))
  (case (random 9 g)
    [(0 1 2) (insert! e s)]
    [(3 4) (retire! e s)]
    [(5) (replace! e s)]
    [(6 7) (update! e s (random 3 g))]
    [else (restart! e s)])
  (yield-times (random 3 g)))

(define (quiesce! e)
  (for ([st (in-hash-values (env-slots e))]) (await-busy! e st))
  (let loop ()
    (define tracked (unbox (env-tracked e)))
    (settle-all tracked)
    (unless (eq? tracked (unbox (env-tracked e))) (loop))))

(define (state-of e s)
  (define f (if (spec-parent s)
                (hash-ref (env-children e) (spec-rank s) #f)
                (slot-fiber (slot-of e s))))
  (if (and f (not (eq? (fiber-state f) 'disposed))) (fiber-state f) 'absent))

;; The least solution of "present, parent active or top-level, every injected
;; key provided by an active spec" (digest law 37).
(define (expected-states e)
  (define specs (env-specs e))
  (define (provider-of k) (findf (lambda (s) (eq? (spec-key s) k)) specs))
  (define (exists? s active)
    (if (spec-parent s)
        (memv (spec-parent s) active)
        (slot-fiber (slot-of e s))))
  (define active
    (let loop ([active '()])
      (define next
        (for/list ([s (in-list specs)]
                   #:when (and (exists? s active)
                               (for/and ([k (in-list (spec-injects s))])
                                 (define p (provider-of k))
                                 (and p (memv (spec-rank p) active)))))
          (spec-rank s)))
      (if (equal? next active) active (loop next))))
  (for/list ([s (in-list specs)])
    (cons (spec-name s)
          (cond [(memv (spec-rank s) active) 'active]
                [(exists? s active) 'pending]
                [else 'absent]))))

(define (config-of e s)
  (slot-config (hash-ref (env-slots e) (or (spec-parent s) (spec-rank s)))))

(define (expected-values e)
  (define states (expected-states e))
  (for/list ([s (in-list (env-specs e))] #:when (spec-key s))
    (cons (spec-key s)
          (and (eq? (cdr (assoc (spec-name s) states)) 'active)
               (list (spec-name s) (config-of e s))))))

(define (observed-states e)
  (for/list ([s (in-list (env-specs e))]) (cons (spec-name s) (state-of e s))))

(define (observed-values e)
  (for/list ([k (in-list (graph-keys (env-specs e)))]) (cons k (ctx-get (env-ctx e) k))))

(define (observation e)
  ;; `comparable` ignores list order and realm identity: confluence is stated
  ;; up to observational equivalence, and creation order differs between
  ;; schedules.
  (list (observed-states e) (observed-values e) (comparable (kernel-snapshot (env-ctx e)))))

;; Digest law 21, checked through public accessors at any point of a schedule.
(define (check-well-formed! e where)
  (define ctx (env-ctx e))
  (define problems (env-problems e))
  (define live (ctx-fibers ctx))
  (define all (cons (context-fiber ctx) (unbox (env-tracked e))))
  ;; every parent exists: no listed fiber has a parent that finished disposal
  (for ([f (in-list live)])
    (when (eq? (fiber-state (context-fiber (fiber-parent f))) 'disposed)
      (problem! problems "~a: ~a is live under a disposed parent" where (fiber-name f))))
  ;; no two provisions share a key (the schedules use one realm per key)
  (for ([k (in-list (graph-keys (env-specs e)))])
    (define holders (filter (lambda (f) (memq k (fiber-provisions f))) all))
    (when (> (length holders) 1)
      (problem! problems "~a: ~a is provided by ~a fibers" where k (length holders))))
  (for ([f (in-list (unbox (env-tracked e)))])
    (define committed (fiber-committed f))
    (define injects (hash-keys (fiber-inject f)))
    (define state (fiber-state f))
    ;; a loaded fiber has a committed view that covers its inject keys
    (when (and (eq? state 'active) (not committed))
      (problem! problems "~a: ~a is active without a committed view" where (fiber-name f)))
    (when committed
      (for ([k (in-list injects)])
        (cond
          [(not (hash-has-key? committed k))
           (problem! problems "~a: committed view of ~a lacks ~a" where (fiber-name f) k)]
          ;; every provider named by a committed view is still loaded, and an
          ;; active fiber is committed to the provider that is active now
          [(not (equal? (hash-ref committed k)
                        (ctx-get (fiber-context f) k #:strict? (eq? state 'active))))
           (problem! problems "~a: ~a (~a) is committed to ~s for ~a but the store has ~s"
                     where (fiber-name f) state (hash-ref committed k) k
                     (ctx-get (fiber-context f) k #:strict? #f))])))
    (when (and (memq state '(pending disposed)) committed)
      (problem! problems "~a: ~a is ~a with a committed view" where (fiber-name f) state))))

(define (run-history! e steps #:check-each-step? [check-each-step? #f])
  (for ([step (in-range steps)])
    (random-operation! e)
    (when check-each-step? (check-well-formed! e (format "step ~a" step)))))

;; source: digest law 21 (Definition 63; Theorem 64)
(test-case "law 21: every step of a random schedule keeps the system well formed"
  (check-schedules
   21
   (lambda (g)
     (with-root (ctx)
       (define e (make-env ctx g (random-graph g) #t))
       (run-history! e (+ 6 (random 10 g)) #:check-each-step? #t)
       (quiesce! e)
       (check-well-formed! e "quiescence")
       (report (env-problems e))))))

;; source: digest law 36 (Theorem 73); the schedule also carries the probes of
;; laws 22, 23 and 24 in every plugin body and inverse
(test-case "law 36: every random schedule over an acyclic graph reaches quiescence"
  (check-schedules
   36
   (lambda (g)
     (with-root (ctx)
       (define e (make-env ctx g (random-graph g) #t))
       (run-history! e (+ 6 (random 14 g)))
       (quiesce! e)
       (yield-times 5)
       (for ([f (in-list (unbox (env-tracked e)))])
         (unless (memq (fiber-state f) '(pending active disposed))
           (problem! (env-problems e) "~a ended ~a" (fiber-name f) (fiber-state f)))
         (unless (sync/timeout 0 f)
           (problem! (env-problems e) "~a still has a transition in flight" (fiber-name f))))
       (report (env-problems e))))))

;; source: digest law 37 (Lemma 77)
(test-case "law 37: at quiescence the active fibers are the least supported set"
  (check-schedules
   37
   (lambda (g)
     (with-root (ctx)
       (define e (make-env ctx g (random-graph g) #t))
       (run-history! e (+ 4 (random 12 g)))
       (quiesce! e)
       (unless (equal? (observed-states e) (expected-states e))
         (problem! (env-problems e) "states ~s, expected ~s"
                   (observed-states e) (expected-states e)))
       (unless (equal? (observed-values e) (expected-values e))
         (problem! (env-problems e) "services ~s, expected ~s"
                   (observed-values e) (expected-values e)))
       (define live (filter (lambda (st) (not (eq? (cdr st) 'absent))) (observed-states e)))
       (unless (= (length (ctx-fibers ctx)) (length live))
         (problem! (env-problems e) "~a live fibers for ~a present specs"
                   (length (ctx-fibers ctx)) (length live)))
       (report (env-problems e))))))

;; A final configuration: which top-level specs are present, and their configs.
(define (random-final g specs)
  (for/list ([s (in-list specs)] #:unless (spec-parent s))
    (list s (chance? g 0.7) (random 3 g))))

;; Loads `final` once on a fresh root, in spec order, without interleaving.
(define (load-from-scratch g specs final)
  (with-root (ctx)
    (define e (make-env ctx g specs #f))
    (for ([entry (in-list final)])
      (set-slot-config! (slot-of e (first entry)) (third entry))
      (when (second entry) (insert! e (first entry))))
    (quiesce! e)
    (list (observation e) (report (env-problems e)))))

;; Brings a running schedule to `final`, in a random order with random yields.
(define (converge! e final)
  (define g (env-g e))
  (for ([entry (in-list (shuffle/g g final))])
    (define s (first entry))
    (cond [(second entry)
           (update! e s (third entry))
           (insert! e s)]
          [else
           (set-slot-config! (slot-of e s) (third entry))
           (retire! e s)])
    (yield-times (random 3 g))))

(define (compare-with-scratch property-history)
  (lambda (g)
    (define specs (random-graph g))
    (define final (random-final g specs))
    (define scratch (load-from-scratch g specs final))
    (define scheduled
      (with-root (ctx)
        (define e (make-env ctx g specs #t))
        (property-history e)
        (converge! e final)
        (quiesce! e)
        (list (observation e) (report (env-problems e)))))
    (cond [(second scratch) (format "scratch load: ~a" (second scratch))]
          [(second scheduled) (second scheduled)]
          [(equal? (first scratch) (first scheduled)) #f]
          [else (format "scheduled run observed ~s, loading once observed ~s"
                        (first scheduled) (first scratch))])))

;; source: digest law 38 (Theorem 80(2)): same plugins and configs, different
;; insertion orders and interleavings of asynchronous steps
(test-case "law 38: the quiescent observation does not depend on the schedule"
  (check-schedules 38 (compare-with-scratch void)))

;; source: digest law 39 (Theorem 80(1)): add, remove, add again, replace a
;; provider, update a config, then arrive at the final configuration
(test-case "law 39: the quiescent observation does not depend on the history"
  (check-schedules
   39
   (compare-with-scratch (lambda (e) (run-history! e (+ 5 (random 12 (env-g e))))))))
