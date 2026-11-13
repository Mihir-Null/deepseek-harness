#lang racket/base
;; Events (contract section 7; vendor/cordis/src/events.ts).
;;
;; Listeners are global to the kernel: a dispatch reaches every listener registered for the
;; name unless the dispatch carries a filter. A dispatch uses the listener list as it was
;; when the dispatch started. A listener runs in the dispatching task with
;; `current-context` set to the context that registered it.
(require racket/list
         "scheduler.rkt"
         "breaks.rkt"
         "errors.rkt"
         "core.rkt"
         "effect.rkt")

(provide bailed?
         ctx-on ctx-once ctx-emit ctx-parallel ctx-serial ctx-bail ctx-waterfall
         ctx-dispatch ctx-listeners
         dispatch-emit dispatch-bail dispatch-waterfall emit-contained
         add-hook! install-event-hooks! contain)

;; source: vendor/cordis/src/events.ts (isBailed); 'null stands for the JSON null.
(define (bailed? v)
  (not (or (not v) (void? v) (eq? v 'null))))

;; ---------------------------------------------------------------------------------------
;; Listener table

(define (add-hook! k name h)
  (define old (hash-ref (kernel-hooks k) name '()))
  (hash-set! (kernel-hooks k) name
             (if (hook-prepend? h) (cons h old) (append old (list h)))))

(define (remove-hook! k name h)
  (define new (remq h (hash-ref (kernel-hooks k) name '())))
  (if (null? new)
      (hash-remove! (kernel-hooks k) name)
      (hash-set! (kernel-hooks k) name new)))

(define (ctx-listeners ctx name)
  (map hook-callback (hash-ref (kernel-hooks (context-kernel ctx)) (->key name) '())))

(define internal-names (make-weak-hasheq))

(define (internal-name? name)
  (define known (hash-ref internal-names name #f))
  (cond
    [known (eq? known 'yes)]
    [else
     (define s (symbol->string name))
     (define internal?
       (and (>= (string-length s) 9) (string=? (substring s 0 9) "internal/")))
     (hash-set! internal-names name (if internal? 'yes 'no))
     internal?]))

;; ---------------------------------------------------------------------------------------
;; Dispatch

;; The hooks a dispatch delivers to, after `internal/dispatch` observers were told.
(define (resolve ctx mode name args accept?)
  (define table (kernel-hooks (context-kernel ctx)))
  (unless (internal-name? name)
    (when (pair? (hash-ref table 'internal/dispatch '()))
      (dispatch-emit ctx 'internal/dispatch (list mode name args))))
  (define hooks (hash-ref table name '()))
  (if accept?
      (for/list ([h (in-list hooks)]
                 #:when (or (hook-global? h)
                            (call-user (lambda () (accept? (hook-ctx h))))))
        h)
      hooks))

(define (call-listener h args)
  (call-user
   (lambda ()
     (parameterize ([current-context (hook-ctx h)])
       (apply (hook-callback h) args)))))

(define (dispatch-emit ctx name args #:filter [accept? #f])
  (for ([h (in-list (resolve ctx 'emit name args accept?))])
    (call-listener h args))
  (void))

;; `serial` and `bail` differ only in the mode reported to `internal/dispatch`.
(define (dispatch-bail ctx name args #:filter [accept? #f] #:mode [mode 'bail])
  (let loop ([hooks (resolve ctx mode name args accept?)])
    (cond
      [(null? hooks) (void)]
      [else
       (define r (call-listener (car hooks) args))
       (if (bailed? r) r (loop (cdr hooks)))])))

(define (dispatch-waterfall ctx name args inner #:filter [accept? #f])
  (let run ([hooks (resolve ctx 'waterfall name (append args (list inner)) accept?)])
    (cond
      [(null? hooks) (inner)]
      [else
       (define called? #f)
       (define (next)
         (when called?
           ;; source: vendor/cordis/src/events.ts
           (raise-cordis "next() called multiple times"))
         (set! called? #t)
         (run (cdr hooks)))
       (call-listener (car hooks) (append args (list next)))])))

;; Each listener runs as its own task, started in listener order. A break of the waiting
;; task cancels the listener tasks and is raised without waiting for them.
(define (dispatch-parallel ctx name args #:filter [accept? #f])
  (define hooks (resolve ctx 'parallel name args accept?))
  (define s (context-scheduler ctx))
  (define tasks
    (for/list ([h (in-list hooks)])
      (spawn-task (lambda () (call-listener h args) (void))
                  #:name 'parallel-listener
                  #:scheduler s)))
  (with-handlers ([exn:break?
                   (lambda (e)
                     (for ([t (in-list tasks)])
                       (task-observe! t)
                       (task-cancel! t))
                     (raise e))])
    (call-user (lambda () (for ([t (in-list tasks)]) (task-wait t)))))
  (define errors (filter values (map task-failure tasks)))
  (unless (null? errors)
    (raise (exn:fail:cordis:aggregate
            (format "~a of ~a listeners of ~s failed: ~a"
                    (length errors) (length tasks) (symbol->string name)
                    (error->string (car errors)))
            (current-continuation-marks)
            errors)))
  (void))

;; `emit` to each listener separately: a listener that raises is reported to `on-error`
;; and the others still run. A break is kept for the caller's next break point.
(define (emit-contained ctx name args on-error)
  (define hooks
    (with-handlers ([(lambda (e) #t) (lambda (e) (contain e on-error) '())])
      (resolve ctx 'emit name args #f)))
  (for ([h (in-list hooks)])
    (with-handlers ([(lambda (e) #t) (lambda (e) (contain e on-error))])
      (call-listener h args))))

;; For handlers that swallow a failure of user code: a break is not a failure of that
;; code, so it is queued again for the current thread instead of being reported.
(define (contain e on-error)
  (if (exn:break? e)
      (break-thread (current-thread))
      (on-error e)))

;; ---------------------------------------------------------------------------------------
;; Public dispatchers

(define (ctx-emit ctx name . args)
  (define key (->key name))
  (call/kernel ctx (lambda () (dispatch-emit ctx key args))))

(define (ctx-parallel ctx name . args)
  (define key (->key name))
  (call/kernel ctx (lambda () (dispatch-parallel ctx key args))))

(define (ctx-serial ctx name . args)
  (define key (->key name))
  (call/kernel ctx (lambda () (dispatch-bail ctx key args #:mode 'serial))))

(define (ctx-bail ctx name . args)
  (define key (->key name))
  (call/kernel ctx (lambda () (dispatch-bail ctx key args))))

;; The last argument is the innermost procedure.
(define (ctx-waterfall ctx name . args+inner)
  (define key (->key name))
  (when (null? args+inner)
    (raise-arguments-error 'ctx-waterfall "expected an innermost procedure as last argument"))
  (define inner (last args+inner))
  (unless (and (procedure? inner) (procedure-arity-includes? inner 0))
    (raise-argument-error 'ctx-waterfall "(-> any) as last argument" inner))
  (define args (drop-right args+inner 1))
  (call/kernel ctx (lambda () (dispatch-waterfall ctx key args inner))))

(define (ctx-dispatch ctx mode name args #:filter [accept? #f] #:inner [inner #f])
  (define key (->key name))
  (call/kernel
   ctx
   (lambda ()
     (case mode
       [(emit) (dispatch-emit ctx key args #:filter accept?)]
       [(parallel) (dispatch-parallel ctx key args #:filter accept?)]
       [(serial) (dispatch-bail ctx key args #:filter accept? #:mode 'serial)]
       [(bail) (dispatch-bail ctx key args #:filter accept?)]
       [(waterfall) (dispatch-waterfall ctx key args (or inner void) #:filter accept?)]
       [else (raise-argument-error 'ctx-dispatch
                                   "(or/c 'emit 'parallel 'serial 'bail 'waterfall)" mode)]))))

;; ---------------------------------------------------------------------------------------
;; Registration

(define (ctx-on ctx name listener #:prepend? [prepend? #f] #:global? [global? #f])
  (define key (->key name))
  (call/kernel
   ctx
   (lambda ()
     (critical
      (unless (fiber-uid (context-fiber ctx))
        (raise-inactive))
      (define options (hasheq 'prepend (and prepend? #t) 'global (and global? #t)))
      (define claimed (dispatch-bail ctx 'internal/listener (list ctx key listener options)))
      (cond
        [(bailed? claimed) claimed]
        [else
         (define k (context-kernel ctx))
         (define h (hook ctx listener (and prepend? #t) (and global? #t)))
         (ctx-effect* ctx
                      (lambda ()
                        (add-hook! k key h)
                        (lambda () (remove-hook! k key h)))
                      (format "ctx.on(~a)" (json-string key)))])))))

;; The listener removes itself before its first call.
(define (ctx-once ctx name listener #:prepend? [prepend? #f] #:global? [global? #f])
  (define d #f)
  (define (once . args)
    (when (procedure? d) (d))
    (apply listener args))
  (set! d (ctx-on ctx name once #:prepend? prepend? #:global? global?))
  d)

;; ---------------------------------------------------------------------------------------
;; Kernel listeners (vendor/cordis/src/events.ts, constructor). They are not effects, so
;; they survive a restart of the root fiber.

(define (install-event-hooks! k root)
  ;; A non-global `internal/update` listener is kept on the registering fiber and sees
  ;; updates of that fiber only.
  (add-hook!
   k 'internal/listener
   (hook root
         (lambda (ctx name listener options)
           (cond
             [(and (eq? name 'internal/update) (not (hash-ref options 'global #f)))
              (define f (context-fiber ctx))
              (define h (hook ctx listener (hash-ref options 'prepend #f) #f))
              (ctx-effect* ctx
                           (lambda ()
                             (define old (fiber-update-hooks f))
                             (set-fiber-update-hooks!
                              f (if (hook-prepend? h) (cons h old) (append old (list h))))
                             (lambda ()
                               (set-fiber-update-hooks! f (remq h (fiber-update-hooks f)))))
                           "ctx.on(\"internal/update\")")]
             [else #f]))
         #f #f))
  ;; Runs the updated fiber's own listeners, in registration order, inside the chain.
  (add-hook!
   k 'internal/update
   (hook root
         (lambda (f config next)
           (let run ([hooks (fiber-update-hooks f)])
             (if (null? hooks)
                 (next)
                 (call-listener (car hooks)
                                (list f config (lambda () (run (cdr hooks))))))))
         #t #t)))
