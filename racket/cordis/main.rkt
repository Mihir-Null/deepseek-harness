#lang racket/base
;; cordis: the kernel (contract sections 2 to 8).
;;
;; Tasks, contexts, revertible effects, services, plugin fibers, events, errors and logging.
;; Every operation that changes kernel state may be called from any thread: outside a task
;; it runs as a task of the root's scheduler and returns that task's result.
(require (for-syntax racket/base syntax/parse)
         racket/contract/base
         "task.rkt"
         "private/errors.rkt"
         "private/log.rkt"
         (only-in "private/core.rkt"
                  key? make-realm
                  context? context-root context-parent context-fiber context-scheduler
                  root-context? context-isolate context-intercept context-realm
                  context-intercepts context-extend context-meta
                  current-context call-with-context
                  fiber? fiber-state fiber-uid fiber-name fiber-plugin fiber-custodian
                  fiber-await)
         "private/effect.rkt"
         "private/events.rkt"
         "private/lifecycle.rkt"
         "private/service.rkt"
         "private/root.rkt"
         "private/plugin-api.rkt")

(provide
 (all-from-out "task.rkt")
 (all-from-out "private/plugin-api.rkt")

 ;; section 8: errors and logging
 (struct-out exn:fail:cordis:inactive)
 (struct-out exn:fail:cordis:inject)
 (struct-out exn:fail:cordis:service)
 (struct-out exn:fail:cordis:validation)
 (struct-out exn:fail:cordis:aggregate)
 cordis-logger
 log-ctx
 effect

 (contract-out
  ;; A validation failure with the message format of vendor/cordis/src/fiber.ts.
  ;; issues : (listof (cons path-list message)); an empty path omits the location.
  [make-validation-error (-> (listof (cons/c list? string?)) exn:fail:cordis:validation?)]
  [raise-validation-error (-> (listof (cons/c list? string?)) none/c)]
  [ctx-logger (->* (context?) ((or/c symbol? string? #f)) logger?)]
  ;; Calls thunk; an `exn:fail` it raises is logged at `error` on ctx's logger and the result
  ;; is then (void). Breaks and other raised values propagate.
  [call-contained (->* (context? (-> any)) (#:label (or/c string? symbol? #f)) any)]

  ;; section 3: contexts
  [make-root-context (->* ()
                          (#:name symbol?
                           #:scheduler (or/c scheduler? #f)
                           #:custodian custodian?)
                          context?)]
  [context? (-> any/c boolean?)]
  [context-root (-> context? context?)]
  [context-parent (-> context? (or/c context? #f))]
  [context-fiber (-> context? fiber?)]
  [context-scheduler (-> context? scheduler?)]
  [context-custodian (-> context? custodian?)]
  [root-context? (-> any/c boolean?)]
  ;; A child in which `key` resolves in `realm`; passing an existing realm joins it.
  [context-isolate (->* (context? key?) (symbol?) context?)]
  ;; A child with one more interception layer for `key`.
  [context-intercept (-> context? key? any/c context?)]
  [context-realm (-> context? key? (or/c symbol? #f))]
  [context-intercepts (-> context? key? list?)]
  [context-extend (-> context? (hash/c key? any/c #:flat? #t) context?)]
  [context-meta (->* (context? key?) (any/c) any/c)]
  [make-realm (-> key? symbol?)]
  ;; Set by the kernel around plugin bodies, effect thunks, inverses and listeners. For
  ;; diagnostics; ownership always follows the explicit context argument.
  [current-context (parameter/c (or/c context? #f))]
  [call-with-context (-> context? (-> any) any)]
  [context-dispose! (-> context? void?)]
  [context-shutdown! (-> context? void?)]

  ;; section 4: effects
  [ctx-effect (->* (context? (-> any)) (#:label string?) disposer?)]
  [disposer? (-> any/c boolean?)]
  [rename dispose-effect! dispose! (-> disposer? void?)]
  [disposer-label (-> disposer? string?)]
  [disposer-children (-> disposer? (listof disposer?))]
  [fiber-effects (-> fiber? (listof disposer?))]

  ;; section 5: services
  [ctx-provide (->* (context? key?)
                    (any/c #:check (or/c #f (and/c procedure? (procedure-arity-includes/c 1))))
                    disposer?)]
  [ctx-get (->* (context? key?) (#:strict? any/c #:default any/c) any/c)]
  [ctx-set! (-> context? key? any/c void?)]
  [ctx-ref (-> context? key? any/c)]
  [ctx-has? (-> context? key? boolean?)]
  [ctx-accessor (->* (context? key? #:get (and/c procedure? (procedure-arity-includes/c 1)))
                     (#:set (or/c #f (and/c procedure? (procedure-arity-includes/c 2))))
                     disposer?)]
  [ctx-mixin (-> context? key? (or/c (listof key?) (hash/c key? key? #:flat? #t)) disposer?)]
  [service-resolve-config (->* ((or/c context? service-handle?) key?)
                               (#:base any/c #:head any/c #:merge procedure?)
                               any/c)]
  [default-merge (->* () () #:rest list? any/c)]
  [current-mixin-resolver (parameter/c (and/c procedure? (procedure-arity-includes/c 2)))]
  [struct service-handle ([ctx context?] [key symbol?])]
  [use-context (-> (or/c context? service-handle?) context?)]
  [service-value (-> (or/c context? service-handle?) key? any/c)]

  ;; section 6: plugins and fibers
  [ctx-plugin (->* (context? (or/c plugin? (and/c procedure? (procedure-arity-includes/c 2))))
                   (any/c)
                   fiber?)]
  [ctx-inject (-> context?
                  (or/c (listof (or/c key? (cons/c key? any/c))) (hash/c key? any/c #:flat? #t))
                  (and/c procedure? (procedure-arity-includes/c 1))
                  fiber?)]
  [fiber? (-> any/c boolean?)]
  [fiber-state (-> fiber? (or/c 'pending 'loading 'active 'unloading 'failed 'disposed))]
  [fiber-uid (-> fiber? (or/c exact-nonnegative-integer? #f))]
  [fiber-name (-> fiber? string?)]
  [fiber-plugin (-> fiber? (or/c plugin? #f))]
  [fiber-context (-> fiber? context?)]
  [fiber-parent (-> fiber? (or/c context? #f))]
  [fiber-inject (-> fiber? (hash/c symbol? any/c #:flat? #t))]
  [fiber-committed (-> fiber? (or/c (hash/c symbol? any/c #:flat? #t) #f))]
  [fiber-provisions (-> fiber? (listof symbol?))]
  [fiber-config (-> fiber? any/c)]
  [fiber-effective-config (-> fiber? any/c)]
  [fiber-error (-> fiber? any/c)]
  [fiber-custodian (-> fiber? custodian?)]
  ;; Waits until no transition is in flight; raises the recorded error of a failed fiber.
  [fiber-await (-> fiber? fiber?)]
  [fiber-dispose! (-> fiber? void?)]
  [fiber-restart! (-> fiber? void?)]
  [fiber-update! (->* (fiber? any/c) (#:save? any/c) void?)]
  [ctx-fibers (-> context? (listof fiber?))]

  ;; section 7: events
  [ctx-on (->* (context? key? procedure?) (#:prepend? any/c #:global? any/c) any/c)]
  [ctx-once (->* (context? key? procedure?) (#:prepend? any/c #:global? any/c) any/c)]
  [ctx-emit (->* (context? key?) () #:rest list? void?)]
  [ctx-parallel (->* (context? key?) () #:rest list? void?)]
  [ctx-serial (->* (context? key?) () #:rest list? any/c)]
  [ctx-bail (->* (context? key?) () #:rest list? any/c)]
  [ctx-waterfall (->* (context? key?) () #:rest (non-empty-listof any/c) any)]
  [ctx-dispatch (->* (context? (or/c 'emit 'parallel 'serial 'bail 'waterfall) key? list?)
                     (#:filter (or/c #f (and/c procedure? (procedure-arity-includes/c 1)))
                      #:inner (or/c #f (-> any)))
                     any)]
  ;; The listeners a dispatch would call, in dispatch order, after `internal/dispatch` was
  ;; emitted as for a real dispatch. Each takes the dispatch arguments.
  [ctx-dispatch-callbacks (->* (context? (or/c 'emit 'parallel 'serial 'bail 'waterfall)
                                         key? list?)
                               (#:filter (or/c #f (and/c procedure?
                                                         (procedure-arity-includes/c 1))))
                               (listof procedure?))]
  [ctx-listeners (-> context? key? (listof procedure?))]
  [bailed? (-> any/c boolean?)]))

;; (effect ctx maybe-label body ...+) registers the body as an effect on `ctx`. The label is
;; `#:label expr`, a leading string literal, or else the source location of the form.
(define-syntax (effect stx)
  (define (location)
    (define src (syntax-source stx))
    (format "~a:~a:~a"
            (cond
              [(path? src)
               (define-values (base name dir?) (split-path src))
               (if (path? name) (path->string name) (path->string src))]
              [src (format "~a" src)]
              [else "unknown"])
            (or (syntax-line stx) "?")
            (or (syntax-column stx) "?")))
  (syntax-parse stx
    [(_ ctx:expr #:label label:expr body:expr ...+)
     #'(ctx-effect ctx (lambda () body ...) #:label label)]
    [(_ ctx:expr label:str body:expr ...+)
     #'(ctx-effect ctx (lambda () body ...) #:label label)]
    [(_ ctx:expr body:expr ...+)
     (with-syntax ([label (location)])
       #'(ctx-effect ctx (lambda () body ...) #:label label))]))

;; (log-ctx level ctx fmt arg ...) logs on the logger of `ctx`'s fiber; the message is
;; formatted only when a receiver wants the level.
(define-syntax (log-ctx stx)
  (syntax-parse stx
    [(_ level:id ctx:expr fmt:expr arg:expr ...)
     #:fail-unless (memq (syntax-e #'level) '(debug info warning error fatal))
     "expected the level debug, info, warning, error or fatal"
     #'(let ([l (ctx-logger ctx)])
         (when (log-level? l 'level)
           (log-message l 'level (format fmt arg ...) (current-continuation-marks))))]))
