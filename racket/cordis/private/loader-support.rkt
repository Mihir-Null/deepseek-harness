#lang racket/base
;; Kernel internals for the loader (contract section 3, "Loader support"). Other packages
;; do not require this module.
;;
;; A rebindable context keeps its parent link, its own realm table and its own intercept
;; table in a mutable cell; lookups on it and on every context derived from it read through
;; the cell. After a rebind the caller notifies for the affected names with `ctx-notify!`.
(require racket/contract/base
         "breaks.rkt"
         "core.rkt"
         "lifecycle.rkt")

(provide
 (contract-out
  [context-derive/rebindable (-> context? context?)]
  [context-rebind! (->* (context?)
                        (#:parent (or/c context? #f)
                         #:realms (or/c (hash/c key? symbol? #:flat? #t) #f)
                         #:intercepts (or/c (hash/c key? any/c #:flat? #t) #f))
                        void?)]
  [context-own-realms (-> context? (hash/c symbol? symbol? #:flat? #t))]
  [context-own-intercepts (-> context? (hash/c symbol? any/c #:flat? #t))]
  ;; Re-evaluates the fibers that inject one of `keys` and emits internal/service.
  ;; `#:filter` : (-> context? symbol? any/c) replaces the default "same realm as ctx" test.
  [ctx-notify! (->* (context? (listof key?)) (#:filter (or/c #f procedure?)) void?)]
  ;; Adds `key` to the fiber's inject list, or replaces its interception config.
  [fiber-add-inject! (->* (fiber? key?) (any/c) void?)]
  ;; Re-checks every injected key and refreshes the fiber's target.
  [fiber-recheck! (-> fiber? void?)]
  ;; Changes the context the fiber counts as created on. Does not move its disposer.
  [fiber-reparent! (-> fiber? context? void?)]
  ;; Stores raw config for the next activation without triggering an update.
  [fiber-set-raw-config! (-> fiber? any/c void?)]
  ;; The validated form of a candidate config; stores nothing.
  [fiber-resolve-config (-> fiber? any/c any/c)]
  ;; Data attached to a fiber, for example its loader entry.
  [fiber-prop-ref (->* (fiber? symbol?) (any/c) any/c)]
  [fiber-prop-set! (-> fiber? symbol? any/c void?)]
  ;; Moves the implementation stored under realm `from` to realm `to` when `to` is free.
  ;; Returns whether it moved. Notifies nobody.
  [service-move! (-> context? symbol? symbol? boolean?)]))

(define (ctx-notify! ctx keys #:filter [accept? #f])
  (call/kernel ctx (lambda () (critical (notify! ctx (map ->key keys) accept?)) (void))))

(define (fiber-add-inject! f key [config #f])
  (define name (->key key))
  (unless (fiber-injects? f name)
    (set-fiber-inject-order! f (append (fiber-inject-keys f) (list name))))
  (hash-set! (fiber-inject-table f) name config)
  (void))

(define (fiber-recheck! f)
  (call/kernel (fiber-ctx f) (lambda () (critical (recheck! f)) (void))))

(define (fiber-reparent! f ctx)
  (set-fiber-parent-ctx! f ctx)
  (void))

(define (fiber-set-raw-config! f config)
  (set-fiber-raw-config! f config)
  (set-fiber-config-revision! f (add1 (fiber-config-revision f)))
  (void))

(define (fiber-prop-ref f key [default #f])
  (hash-ref (fiber-props f) key default))

(define (fiber-prop-set! f key value)
  (hash-set! (fiber-props f) key value))

(define (service-move! ctx from to)
  (call/kernel
   ctx
   (lambda ()
     (critical
      (define store (kernel-store (context-kernel ctx)))
      (define i (hash-ref store from #f))
      (cond
        [(and i (not (hash-ref store to #f)))
         (hash-remove! store from)
         (hash-set! store to i)
         (set-impl-realm! i to)
         #t]
        [else #f])))))
