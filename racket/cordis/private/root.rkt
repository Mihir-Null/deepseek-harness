#lang racket/base
;; The root context: construction, disposal, shutdown, and the logger front end
;; (contract sections 3 and 8; vendor/cordis/src/context.ts).
(require "scheduler.rkt"
         "breaks.rkt"
         "errors.rkt"
         "log.rkt"
         "core.rkt"
         "dlist.rkt"
         "events.rkt"
         "lifecycle.rkt")

(provide make-root-context context-custodian context-dispose! context-shutdown!
         context-kill! ctx-logger call-contained hyphenate)

;; The root fiber is active, has uid 0, no plugin and an empty inject list. The kernel's
;; own listeners are installed outside the root fiber's effect list, so they survive
;; `context-dispose!`.
(define (make-root-context #:name [name 'root]
                           #:scheduler [s #f]
                           #:custodian [c (current-custodian)])
  (define kernel-custodian (make-custodian c))
  (define scheduler (or s (make-scheduler #:name name #:custodian kernel-custodian)))
  (define k
    (kernel name scheduler (not s) kernel-custodian (current-parameterization)
            #f #f
            (make-hasheq) (make-hasheq) (make-hasheq) (make-hasheq) (make-hasheq) (make-dlist)
            0 0 0
            (make-hasheq) #f (make-weak-hasheq) (make-weak-hasheq) #f))
  (define root-fiber (make-root-fiber k))
  (define root (context k #f root-fiber #f (hasheq) (hasheq) (hasheq) #f))
  (set-fiber-ctx! root-fiber root)
  (set-kernel-root-ctx! k root)
  (set-kernel-root-fiber! k root-fiber)
  (install-event-hooks! k root)
  (install-config-hook! k root)
  root)

;; The current custodian of the fiber that owns `ctx`.
(define (context-custodian ctx)
  (fiber-custodian (context-fiber ctx)))

;; Unloads everything registered through the root (plugins, listeners, services) by
;; restarting the root fiber, then waits until nothing is in flight. The root stays usable.
(define (context-dispose! ctx)
  (define k (context-kernel ctx))
  (call/kernel
   ctx
   (lambda ()
     (fiber-restart! (kernel-root-fiber k))
     (await-quiescence k)
     (void))))

;; `context-dispose!`, then the end of the kernel: its scheduler, if the root created it,
;; and its custodian. Later kernel operations raise `exn:fail:cordis:inactive`. Idempotent.
(define (context-shutdown! ctx)
  (define k (context-kernel ctx))
  (unless (kernel-shutdown? k)
    (dynamic-wind
     void
     (lambda () (context-dispose! ctx))
     (lambda () (context-kill! ctx))))
  (void))

;; Shutdown without disposal: for a kernel that no longer makes progress.
(define (context-kill! ctx)
  (define k (context-kernel ctx))
  (unless (kernel-shutdown? k)
    (set-kernel-shutdown?! k #t)
    (when (kernel-owns-scheduler? k)
      (scheduler-shutdown! (kernel-scheduler k)))
    (custodian-shutdown-all (kernel-custodian k)))
  (void))

;; ---------------------------------------------------------------------------------------
;; Loggers

;; source: vendor/cosmokit/src/string.ts (paramCase)
(define (hyphenate source)
  (define out (open-output-string))
  (define n (string-length source))
  (let loop ([i 0] [state 'delim])
    (when (< i n)
      (define c (string-ref source i))
      (cond
        [(char<=? #\A c #\Z)
         (cond
           [(eq? state 'upper)
            (when (and (< (add1 i) n) (char<=? #\a (string-ref source (add1 i)) #\z))
              (write-char #\- out))]
           [(not (eq? state 'delim)) (write-char #\- out)])
         (write-char (char-downcase c) out)
         (loop (add1 i) 'upper)]
        [(char<=? #\a c #\z)
         (write-char c out)
         (loop (add1 i) 'lower)]
        [(or (char=? c #\-) (char=? c #\_))
         (unless (eq? state 'delim) (write-char #\- out))
         (loop (add1 i) 'delim)]
        [else
         (write-char c out)
         (loop (add1 i) state)])))
  (get-output-string out))

;; A child of the cordis logger. Its name, which is also the default topic of what is logged
;; on it, is `topic` or the hyphenated name of the fiber that owns `ctx`.
(define (ctx-logger ctx [topic #f])
  (define k (context-kernel ctx))
  (define f (context-fiber ctx))
  (define name (if topic (->key topic) (string->symbol (hyphenate (fiber-name f)))))
  (define by-name
    (or (hash-ref (kernel-loggers k) f #f)
        (let ([h (make-hasheq)])
          (hash-set! (kernel-loggers k) f h)
          h)))
  (or (hash-ref by-name name #f)
      (let ([l (make-logger name cordis-logger)])
        (hash-set! by-name name l)
        l)))

;; Calls `thunk` and returns its values. An `exn:fail` it raises is logged at `error` through
;; the logger of `ctx`'s fiber, under the topic `cordis` and with the exception as the event's
;; data, and the result is then (void). Breaks and other raised values propagate.
(define (call-contained ctx thunk #:label [label #f])
  (with-handlers ([exn:fail?
                   (lambda (e)
                     (define f (context-fiber ctx))
                     (hash-set! (kernel-logged (context-kernel ctx)) e #t)
                     (define logger (ctx-logger ctx))
                     (when (log-level? logger 'error 'cordis)
                       (log-message logger 'error 'cordis
                                    (if label
                                        (format "~a: ~a: ~a" (fiber-name f) label (exn-message e))
                                        (format "~a: ~a" (fiber-name f) (exn-message e)))
                                    e #t))
                     (void))])
    (thunk)))
