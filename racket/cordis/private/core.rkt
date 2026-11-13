#lang racket/base
;; Data definitions of the kernel and the operations that only read them: the shared kernel
;; record, contexts (derivation and lookup), fibers (accessors and waiting), service
;; implementations, listener hooks, plugin records.
;;
;; Mutable kernel state is changed only by a task that holds the baton of the kernel's
;; scheduler. Readers on other threads see a consistent value of each single field.
(require racket/list
         "scheduler.rkt"
         "errors.rkt"
         "log.rkt"
         "dlist.rkt")

(provide (struct-out kernel)
         (struct-out context)
         (struct-out rebind-cell)
         (struct-out fiber)
         (struct-out impl)
         (struct-out hook)
         (struct-out runtime)
         (struct-out plugin)
         (struct-out accessor)
         prop:config-schema config-schema? config-schema-ref
         ->key key? json-string
         make-realm
         current-context call-with-context
         context-root context-parent context-fiber context-scheduler root-context?
         context-realm context-intercepts context-meta
         context-isolate context-intercept context-extend context-derive
         context-derive/rebindable context-rebind! context-own-realms context-own-intercepts
         fiber-name fiber-root? fiber-custodian fiber-idle-evt fiber-await fiber-wait
         fiber-inject-keys fiber-injects? call-as-waiter
         set-inertia! busy-add! busy-remove! await-quiescence
         spawn-kernel-task call/kernel
         log-error-once log-fiber-error)

;; ---------------------------------------------------------------------------------------
;; Keys

(define (key? v) (or (symbol? v) (string? v)))
(define (->key v) (if (string? v) (string->symbol v) v))

;; The JSON spelling of a key, as `JSON.stringify(name)` produces in effect labels.
(define (json-string key)
  (define s (if (symbol? key) (symbol->string key) key))
  (define out (open-output-string))
  (write-char #\" out)
  (for ([c (in-string s)])
    (case c
      [(#\") (write-string "\\\"" out)]
      [(#\\) (write-string "\\\\" out)]
      [(#\newline) (write-string "\\n" out)]
      [(#\tab) (write-string "\\t" out)]
      [(#\return) (write-string "\\r" out)]
      [else (write-char c out)]))
  (write-char #\" out)
  (get-output-string out))

;; A realm is an uninterned symbol named after the key it scopes.
(define (make-realm key)
  (string->uninterned-symbol (symbol->string (->key key))))

;; ---------------------------------------------------------------------------------------
;; Kernel record: everything the root context owns

(struct kernel
  (name
   scheduler
   owns-scheduler?
   custodian            ; kernel custodian: transition tasks and, when owned, the manager
   paramz               ; parameterization under which kernel tasks run
   [root-ctx #:mutable]
   [root-fiber #:mutable]
   realms               ; mutable hasheq: key -> root realm, assigned at first provide
   store                ; mutable hasheq: realm -> impl
   props                ; mutable hasheq: key -> 'service or accessor
   hooks                ; mutable hasheq: event name -> (listof hook) in dispatch order
   runtimes             ; mutable hasheq: plugin identity -> runtime
   runtime-order        ; dlist of runtime, registration order
   [fiber-counter #:mutable]
   [impl-counter #:mutable]
   [fiber-seq #:mutable]
   busy                 ; mutable hasheq: fiber or disposer with work in flight -> #t
   [idle-latch #:mutable]
   logged               ; weak hasheq: exception already reported -> #t
   loggers              ; weak hasheq: fiber -> (hash topic -> logger)
   [shutdown? #:mutable]))

;; ---------------------------------------------------------------------------------------
;; Plugins, runtimes, implementations, hooks

(define-values (prop:config-schema config-schema? config-schema-ref)
  (make-struct-type-property 'config-schema))

;; `key` is the registry identity (`eq?`): the apply procedure, or for `ctx-inject` the
;; callback. `inject` is the declaration as given, with symbol keys.
(struct plugin (name inject config-schema provides apply meta custodian-mode key)
  #:property prop:procedure
  (lambda (p ctx config) ((plugin-apply p) ctx config))
  #:property prop:custom-write
  (lambda (p port mode) (fprintf port "#<plugin:~a>" (or (plugin-name p) "anonymous"))))

;; One record per plugin identity; `name` and `schema` come from the first registration.
(struct runtime (key name schema fibers))

;; `dependents` is a mutable hasheq used as a set of fibers. `release` is a latch opened
;; when the last dependent has unloaded, or #f.
(struct impl (uid key [value #:mutable] ctx check [realm #:mutable] dependents
                  [release #:mutable]))

(struct hook (ctx callback prepend? global?))

(struct accessor (get set))

;; ---------------------------------------------------------------------------------------
;; Contexts

;; The three overlays hold what was derived since `base`, the cell of the nearest rebindable
;; ancestor-or-self, or since the root when `base` is #f. `intercept-overlay` maps a key to
;; its layers, innermost first. `own-fiber` is #f when the fiber is inherited through
;; `base`. `static-parent` is #f for the root and for a rebindable context, whose parent
;; lives in its cell.
(struct context (kernel static-parent own-fiber base
                        realm-overlay intercept-overlay meta-overlay rebindable?)
  #:property prop:custom-write
  (lambda (c port mode) (fprintf port "#<context:~a>" (fiber-name (context-fiber c)))))

;; `intercepts` here maps a key to one config: the layer this cell contributes.
(struct rebind-cell ([parent #:mutable] [realms #:mutable] [intercepts #:mutable]))

(define current-context (make-parameter #f))

(define (call-with-context ctx thunk)
  (parameterize ([current-context ctx]) (thunk)))

(define (context-root ctx)
  (kernel-root-ctx (context-kernel ctx)))

(define (root-context? ctx)
  (and (context? ctx) (eq? ctx (context-root ctx))))

(define (context-scheduler ctx)
  (kernel-scheduler (context-kernel ctx)))

;; The context this one was derived from; #f for the root.
(define (context-parent ctx)
  (if (context-rebindable? ctx)
      (rebind-cell-parent (context-base ctx))
      (context-static-parent ctx)))

(define (context-fiber ctx)
  (or (context-own-fiber ctx)
      (let ([cell (context-base ctx)])
        (if cell
            (context-fiber (rebind-cell-parent cell))
            (kernel-root-fiber (context-kernel ctx))))))

;; The realm `key` resolves in from `ctx`; #f while the key has no realm at all.
(define (context-realm ctx key)
  (let lookup ([ctx ctx] [key (->key key)])
    (cond
      [(hash-ref (context-realm-overlay ctx) key #f)]
      [(context-base ctx)
       => (lambda (cell)
            (or (hash-ref (rebind-cell-realms cell) key #f)
                (lookup (rebind-cell-parent cell) key)))]
      [else (hash-ref (kernel-realms (context-kernel ctx)) key #f)])))

;; Interception layers for `key`, outermost first.
(define (context-intercepts ctx key)
  (let lookup ([ctx ctx] [key (->key key)])
    (define own (reverse (hash-ref (context-intercept-overlay ctx) key '())))
    (define cell (context-base ctx))
    (cond
      [cell
       (define mine (rebind-cell-intercepts cell))
       (append (lookup (rebind-cell-parent cell) key)
               (if (hash-has-key? mine key) (list (hash-ref mine key)) '())
               own)]
      [else own])))

(define (context-meta ctx key [default #f])
  (let lookup ([ctx ctx] [key (->key key)])
    (define own (context-meta-overlay ctx))
    (cond
      [(hash-has-key? own key) (hash-ref own key)]
      [(context-base ctx) => (lambda (cell) (lookup (rebind-cell-parent cell) key))]
      [else default])))

;; The general derivation: a child of `ctx` with the given additions.
(define (context-derive ctx
                        #:fiber [f #f]
                        #:realms [realms '()]            ; alist key -> realm
                        #:intercepts [intercepts '()]    ; alist key -> config, outer first
                        #:meta [meta #f])                ; hash or #f
  (context
   (context-kernel ctx)
   ctx
   (or f (context-own-fiber ctx))
   (context-base ctx)
   (for/fold ([h (context-realm-overlay ctx)]) ([p (in-list realms)])
     (hash-set h (car p) (cdr p)))
   (for/fold ([h (context-intercept-overlay ctx)]) ([p (in-list intercepts)])
     (hash-set h (car p) (cons (cdr p) (hash-ref h (car p) '()))))
   (if meta
       (for/fold ([h (context-meta-overlay ctx)]) ([(k v) (in-hash meta)])
         (hash-set h (->key k) v))
       (context-meta-overlay ctx))
   #f))

(define (context-isolate ctx key [realm (make-realm key)])
  (context-derive ctx #:realms (list (cons (->key key) realm))))

(define (context-intercept ctx key config)
  (context-derive ctx #:intercepts (list (cons (->key key) config))))

(define (context-extend ctx meta)
  (context-derive ctx #:meta meta))

;; A child whose parent link, own realm table and own intercept table live in a mutable
;; cell. Lookups on it and on every context derived from it read through the cell.
(define (context-derive/rebindable ctx)
  (context (context-kernel ctx) #f #f
           (rebind-cell ctx (hasheq) (hasheq))
           (hasheq) (hasheq) (hasheq) #t))

(define (context-rebind! ctx
                         #:parent [parent #f]
                         #:realms [realms #f]
                         #:intercepts [intercepts #f])
  (unless (context-rebindable? ctx)
    (raise-argument-error 'context-rebind! "a context made by context-derive/rebindable" ctx))
  (define cell (context-base ctx))
  (when parent (set-rebind-cell-parent! cell parent))
  (when realms (set-rebind-cell-realms! cell (normalize-table realms)))
  (when intercepts (set-rebind-cell-intercepts! cell (normalize-table intercepts)))
  (void))

(define (normalize-table h)
  (for/hasheq ([(k v) (in-hash h)]) (values (->key k) v)))

(define (context-own-realms ctx)
  (unless (context-rebindable? ctx)
    (raise-argument-error 'context-own-realms "a context made by context-derive/rebindable" ctx))
  (rebind-cell-realms (context-base ctx)))

(define (context-own-intercepts ctx)
  (unless (context-rebindable? ctx)
    (raise-argument-error 'context-own-intercepts
                          "a context made by context-derive/rebindable" ctx))
  (rebind-cell-intercepts (context-base ctx)))

;; ---------------------------------------------------------------------------------------
;; Fibers

;; Field names differ from the public accessors that present them (`fiber-inject`,
;; `fiber-committed`, ...), which are defined in lifecycle.rkt.
(struct fiber
  (kernel
   seq                         ; creation order
   plugin                      ; plugin or #f for the root fiber
   runtime                     ; runtime or #f for the root fiber
   [uid #:mutable]             ; #f once disposal has started
   [ctx #:mutable]
   [parent-ctx #:mutable]      ; the context the fiber was created on, #f for the root
   inject-table                ; mutable hasheq: key -> intercept config or #f
   [inject-order #:mutable]    ; keys of inject-table in declaration order
   [raw-config #:mutable]
   [effective #:mutable]
   [state #:mutable]
   [failure #:mutable]         ; exn or #f
   [revision #:mutable]
   [config-revision #:mutable]
   [target #:mutable]          ; #f or (list revision provider-uid ...)
   [available #:mutable]       ; immutable hasheq: key -> impl that passed its check
   [commit #:mutable]          ; #f or immutable hasheq: key -> impl of this activation
   [activation #:mutable]      ; number of reloads started so far
   [provided #:mutable]        ; (listof impl) in provide order
   [inertia #:mutable]         ; task of the transition in flight, or #f
   disposables                 ; dlist of top-level disposers and collected inverses
   [update-hooks #:mutable]    ; (listof hook): fiber-local internal/update listeners
   [release #:mutable]         ; latch opened when a provision loses its last dependent
   [own-custodian #:mutable]   ; custodian of the current activation, #f in mode 'inherit
   [dispose-proc #:mutable]    ; disposer of the ctx.plugin() effect, #f for the root
   props                       ; mutable hasheq for data attached by the loader
   [custodian-parent #:mutable] ; the custodian own-custodian was made under
   waiting)                    ; mutable hasheq: thread that waits for this fiber -> depth
  #:property prop:evt
  (lambda (f) (fiber-idle-evt f))
  #:property prop:awaitable
  (awaiter (lambda (f) (fiber-await f))
           (lambda (f) (not (fiber-inertia f)))
           (lambda (f) (fiber-idle-evt f)))
  #:property prop:custom-write
  (lambda (f port mode)
    (fprintf port "#<fiber:~a:~a>" (fiber-name f) (fiber-state f))))

(define (fiber-root? f)
  (not (fiber-runtime f)))

;; Injected keys in order: declaration order, then keys that observers added to the table
;; (`fiber-inject` hands the table itself to `internal/plugin` observers), by name.
(define (fiber-inject-keys f)
  (define table (fiber-inject-table f))
  (define order (fiber-inject-order f))
  (cond
    [(and (= (length order) (hash-count table))
          (andmap (lambda (key) (hash-has-key? table key)) order))
     order]
    [else
     (define known (filter (lambda (key) (hash-has-key? table key)) order))
     (define added
       (sort (for/list ([key (in-list (hash-keys table))]
                        #:when (symbol? key)
                        #:unless (memq key known))
               key)
             symbol<?))
     (define keys (append known added))
     (set-fiber-inject-order! f keys)
     keys]))

(define (fiber-injects? f key)
  (hash-has-key? (fiber-inject-table f) key))

;; The nearest plugin name up the chain of creating contexts; "root" when there is none.
(define (fiber-name f)
  (let loop ([f f])
    (define rt (fiber-runtime f))
    (cond
      [(and rt (runtime-name rt))]
      [(fiber-parent-ctx f)
       => (lambda (pctx)
            (define pf (context-fiber pctx))
            (if (eq? pf f) "root" (loop pf)))]
      [else "root"])))

;; Mode 'inherit uses the custodian of the fiber of the creating context.
(define (fiber-custodian f)
  (or (fiber-own-custodian f)
      (let ([pctx (fiber-parent-ctx f)])
        (if pctx
            (fiber-custodian (context-fiber pctx))
            (kernel-custodian (fiber-kernel f))))))

;; Ready when no transition is in flight; the synchronization result is the fiber.
(define (fiber-idle-evt f)
  (guard-evt
   (lambda ()
     (define i (fiber-inertia f))
     (if (and i (not (task-done? i)))
         (replace-evt i (lambda (_) (fiber-idle-evt f)))
         (wrap-evt always-evt (lambda (_) f))))))

;; Waits until no transition is in flight. A call from the fiber's own transition task
;; returns at once, because waiting there could never finish.
(define (fiber-wait f)
  (when (fiber-inertia f)
    (call-as-waiter
     f
     (lambda ()
       (let loop ()
         (define i (fiber-inertia f))
         (when (and i (not (eq? i (current-task))))
           (task-result i)
           (when (eq? (fiber-inertia f) i)
             (raise-cordis "fiber ~a: a transition ended without settling" (fiber-name f)))
           (loop))))))
  (void))

;; Marks the current thread as waiting for `f` while `thunk` runs. A thread so marked is not
;; killed by the custodian shutdown that ends an unload it waits for (see lifecycle.rkt).
(define (call-as-waiter f thunk)
  (define th (current-thread))
  (define table (fiber-waiting f))
  (define depth (hash-ref table th 0))
  (dynamic-wind
   (lambda () (hash-set! table th (add1 depth)))
   thunk
   (lambda ()
     (if (zero? depth)
         (hash-remove! table th)
         (hash-set! table th depth)))))

(define (fiber-await f)
  (fiber-wait f)
  (define e (fiber-failure f))
  (when e (raise e))
  f)

;; ---------------------------------------------------------------------------------------
;; Work in flight and quiescence

(define (busy-add! k v)
  (hash-set! (kernel-busy k) v #t))

(define (busy-remove! k v)
  (hash-remove! (kernel-busy k) v)
  (when (zero? (hash-count (kernel-busy k)))
    (define l (kernel-idle-latch k))
    (when l
      (set-kernel-idle-latch! k #f)
      (latch-open! l))))

(define (set-inertia! f t)
  (set-fiber-inertia! f t)
  (if t
      (busy-add! (fiber-kernel f) f)
      (busy-remove! (fiber-kernel f) f)))

;; Waits until no fiber has a transition in flight and no effect has setup or cleanup in
;; flight. Call from a task of the kernel's scheduler.
(define (await-quiescence k)
  (let loop ()
    (unless (zero? (hash-count (kernel-busy k)))
      (define l (or (kernel-idle-latch k)
                    (let ([l (make-latch (kernel-scheduler k))])
                      (set-kernel-idle-latch! k l)
                      l)))
      (latch-wait l)
      (loop))))

;; ---------------------------------------------------------------------------------------
;; Kernel tasks and entry

;; A task owned by the kernel custodian that runs under the parameterization captured when
;; the root was created. A raised value is logged; the task itself always finishes normally.
(define (spawn-kernel-task k thunk #:name [name 'kernel])
  (call-with-parameterization
   (kernel-paramz k)
   (lambda ()
     (parameterize ([current-custodian (kernel-custodian k)])
       (spawn-task (lambda ()
                     (with-handlers ([(lambda (e) #t)
                                      (lambda (e)
                                        (log-error-once k (format "kernel task ~a" name) e))])
                       (thunk)))
                   #:name name
                   #:scheduler (kernel-scheduler k))))))

;; Runs `thunk` in a task of the kernel's scheduler: directly when the caller is one.
(define (call/kernel ctx thunk)
  (define k (context-kernel ctx))
  (when (kernel-shutdown? k)
    (raise-inactive "context has been shut down"))
  (call-in-kernel thunk #:scheduler (kernel-scheduler k)))

;; ---------------------------------------------------------------------------------------
;; Error reports

;; Logs `e` at `error` on the cordis logger with `e` as the event data. An exception object
;; is reported once however many handlers see it.
(define (log-error-once k what e)
  (define logged (kernel-logged k))
  (unless (and (exn? e) (hash-ref logged e #f))
    (when (exn? e) (hash-set! logged e #t))
    (log-cordis 'error (format "~a: ~a" what (error->string e)) e)))

(define (log-fiber-error f e)
  (log-error-once (fiber-kernel f) (fiber-name f) e))
