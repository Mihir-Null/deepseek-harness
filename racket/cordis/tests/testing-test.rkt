#lang racket/base
;; cordis/testing (contract section 10) and errors and logging (contract section 8).
(require rackunit
         racket/list
         cordis
         cordis/testing
         (only-in cordis/private/root hyphenate)
         "common.rkt")

;; ---------------------------------------------------------------------------------------
;; call-with-root-context

(test-case "call-with-root-context: runs proc as a task and returns its values"
  (define seen #f)
  (define-values (a b)
    (call-with-root-context
     (lambda (ctx)
       (set! seen (list (root-context? ctx) (in-task? (context-scheduler ctx))))
       (values 1 2))))
  (check-equal? (list a b) '(1 2))
  (check-equal? seen '(#t #t)))

(test-case "call-with-root-context: shuts the kernel down, unloading what was mounted"
  (define-values (note notes) (make-recorder))
  (define escaped #f)
  (define leaked #f)
  (call-with-root-context
   (lambda (ctx)
     (set! escaped ctx)
     (set! leaked (thread (lambda () (sync (make-semaphore 0)))))
     (await/t (ctx-plugin ctx (lambda (c config) (lambda () (note 'unloaded)))))))
  (check-equal? (notes) '(unloaded))
  (check-exn exn:fail:cordis? (lambda () (ctx-emit escaped 'event)))
  ;; nothing made inside survives
  (check-true (thread-dead? leaked)))

(test-case "call-with-root-context: a failure of proc propagates after the shutdown"
  (define-values (note notes) (make-recorder))
  (define-values (_ events)
    (capture-log
     (lambda ()
       (check-exn #rx"proc failed"
                  (lambda ()
                    (call-with-root-context
                     (lambda (ctx)
                       (ctx-effect ctx (lambda () (lambda () (note 'disposed))))
                       (raise-user-error "proc failed"))))))))
  (check-equal? (notes) '(disposed))
  ;; the failure was observed by the caller, so it is not reported as unobserved
  (check-equal? events '()))

(test-case "call-with-root-context: raises when proc does not finish in time"
  (define leaked #f)
  (check-exn-message
   exn:fail? #rx"call-with-root-context"
   (lambda ()
     (call-with-root-context
      (lambda (ctx)
        (set! leaked (current-thread))
        (await (make-semaphore 0)))
      #:timeout 0.05)))
  (check-true (and (sync/timeout patience (thread-dead-evt leaked)) #t)))

(test-case "with-root-context: binds the root; accepts a timeout"
  (check-equal? (with-root-context (ctx) (fiber-uid (context-fiber ctx))) 0)
  (check-exn exn:fail? (lambda () (with-root-context (ctx #:timeout 0.05)
                                    (await (make-semaphore 0))))))

;; ---------------------------------------------------------------------------------------
;; kernel-snapshot and check-kernel-restored

(test-case "kernel-snapshot: summarizes services, listeners, accessors and fibers"
  (with-root-context (ctx)
    (define empty (kernel-snapshot ctx))
    (check-true (hash? empty))
    (check-equal? (kernel-snapshot ctx) empty)
    (ctx-provide ctx 'db 1)
    (ctx-provide (context-isolate ctx 'db) 'db 2)
    (ctx-on ctx 'event void)
    (ctx-on ctx 'event void)
    (ctx-accessor ctx 'shortcut #:get void)
    (define f (ctx-plugin ctx (make-plugin (lambda (c config) (ctx-provide c 'api 1) (void))
                                           #:name "named")))
    (await/t f)
    (define full (kernel-snapshot ctx))
    (check-false (equal? full empty))
    (check-equal? (hash-ref full 'services) (hash "db" '("root" "root") "api" '("named")))
    (check-equal? (hash-ref (hash-ref full 'listeners) 'event) 2)
    (check-equal? (hash-ref full 'accessors) '(shortcut))
    (check-equal? (hash-ref full 'fibers) '("named"))
    (context-dispose! ctx)
    (check-equal? (kernel-snapshot ctx) empty)))

(test-case "check-kernel-restored: passes when the thunk undoes what it did"
  (with-root-context (ctx)
    (check-kernel-restored void ctx)
    (check-kernel-restored
     (lambda ()
       ((ctx-on ctx 'event void))
       ;; the unload is still in flight when the thunk returns
       (define f (ctx-plugin ctx (lambda (c config)
                                   (ctx-provide c 'db 1)
                                   (lambda () (yield-task) (yield-task)))))
       (await/t f)
       (spawn-task (lambda () (fiber-dispose! f))))
     ctx)))

(test-case "check-kernel-restored: fails when something is left behind"
  (with-root-context (ctx)
    (check-exn exn:test:check?
               (lambda () (check-kernel-restored (lambda () (ctx-on ctx 'leaked void)) ctx)))
    (check-exn exn:test:check?
               (lambda () (check-kernel-restored (lambda () (ctx-provide ctx 'leaked 1)) ctx)))))

;; ---------------------------------------------------------------------------------------
;; capture-log, wait-for

(test-case "capture-log: returns proc's value and the events at the level or above"
  (define (emit-all)
    (log-message cordis-logger 'debug 'cordis "debug message" 'data-1 #f)
    (log-message cordis-logger 'warning 'cordis "warning message" 'data-2 #f)
    (log-message cordis-logger 'error 'cordis "error message" 'data-3 #f)
    (log-message cordis-logger 'error 'other-topic "other topic" #f #f)
    'result)
  (define-values (v errors) (capture-log emit-all))
  (check-equal? v 'result)
  (check-equal? (map (lambda (e) (vector-ref e 1)) errors) '("error message"))
  (check-equal? (vector-ref (car errors) 2) 'data-3)
  (define-values (_ warnings) (capture-log emit-all #:level 'warning))
  (check-equal? (map (lambda (e) (vector-ref e 0)) warnings) '(warning error))
  (define-values (__ all-topics) (capture-log emit-all #:topic #f))
  (check-equal? (length all-topics) 2)
  (define-values (___ other) (capture-log emit-all #:topic 'other-topic))
  (check-equal? (map (lambda (e) (vector-ref e 1)) other) '("other topic")))

(test-case "wait-for: returns the true value, or #f when the time is up"
  (check-equal? (wait-for (lambda () 'ready)) 'ready)
  (check-false (wait-for (lambda () #f) #:timeout 0.05))
  (define flag #f)
  (define setter (thread (lambda () (set! flag 'set-by-thread))))
  (check-equal? (wait-for (lambda () flag)) 'set-by-thread)
  (with-root-context (ctx)
    (define done #f)
    (spawn-task (lambda () (yield-task) (yield-task) (set! done 'set-by-task)))
    ;; inside a task the baton is released between polls
    (check-equal? (wait-for (lambda () done)) 'set-by-task)
    (check-false (wait-for (lambda () #f) #:timeout 0.02))))

;; ---------------------------------------------------------------------------------------
;; Errors and logging

(test-case "errors: every kernel exception is an exn:fail:cordis"
  (define marks (current-continuation-marks))
  (define all
    (list (exn:fail:cordis "m" marks)
          (exn:fail:cordis:inactive "m" marks)
          (exn:fail:cordis:inject "m" marks 'key)
          (exn:fail:cordis:service "m" marks 'key)
          (exn:fail:cordis:validation "m" marks '())
          (exn:fail:cordis:aggregate "m" marks '())
          (exn:fail:cordis:task-killed "m" marks)))
  (for ([e (in-list all)])
    (check-pred exn:fail:cordis? e)
    (check-pred exn:fail? e))
  (check-equal? (exn:fail:cordis:inject-key (third all)) 'key)
  (check-equal? (exn:fail:cordis:service-key (fourth all)) 'key)
  (check-equal? (exn-message (make-validation-error
                              (list (cons '(a b 0) "is wrong") (cons '() "is missing"))))
                "invalid config:\n  - is wrong (at a.b.0)\n  - is missing")
  (check-exn exn:fail:cordis:validation? (lambda () (raise-validation-error '()))))

(test-case "logging: ctx-logger is a child of the cordis logger named after the fiber"
  (with-root-context (ctx)
    (check-true (logger? cordis-logger))
    (check-eq? (logger-name cordis-logger) 'cordis)
    (check-eq? (logger-name (ctx-logger ctx)) 'root)
    (check-eq? (ctx-logger ctx) (ctx-logger ctx))
    (check-eq? (logger-name (ctx-logger ctx 'custom)) 'custom)
    (define f (ctx-plugin ctx (make-plugin (lambda (c config) (void)) #:name "HTTPServerPlugin")))
    (await/t f)
    (check-eq? (logger-name (ctx-logger (fiber-context f))) 'http-server-plugin)
    ;; what is logged there reaches receivers of the cordis logger
    (define-values (_ events)
      (capture-log (lambda ()
                     (log-ctx warning (fiber-context f) "value ~a and ~s" 1 "two")
                     (log-ctx debug (fiber-context f) "not received")
                     (log-ctx error ctx "from the root"))
                   #:level 'warning
                   #:topic #f))
    (check-equal? (map (lambda (e) (list (vector-ref e 0) (vector-ref e 1) (vector-ref e 3)))
                       events)
                  '((warning "http-server-plugin: value 1 and \"two\"" http-server-plugin)
                    (error "root: from the root" root)))))

(test-case "logging: hyphenate matches cosmokit's paramCase"
  ;; source: docs/racket/recon/01-cordis-core.md (observed values)
  (for ([pair (in-list '(("MyPluginName" . "my-plugin-name")
                         ("HTTPServer" . "http-server")
                         ("abc1Def" . "abc1-def")
                         ("foo_bar-Baz" . "foo-bar-baz")
                         ("_lead" . "lead")
                         ("a__b" . "a-b")
                         ("already-kebab" . "already-kebab")))])
    (check-equal? (hyphenate (car pair)) (cdr pair))))

(test-case "logging: kernel error reports carry the exception as data, once per exception"
  (with-root-context (ctx)
    (define (failing-inverse) (raise-user-error "inverse failed"))
    (define f (ctx-plugin ctx (make-plugin (lambda (c config)
                                             (ctx-effect c (lambda () failing-inverse))
                                             (void))
                                           #:name "reporter")))
    (await/t f)
    ;; the effect reports its inverse, the unload sees the same exception and stays quiet
    (define-values (_ events) (capture-log (lambda () (fiber-dispose! f))))
    (check-equal? (length events) 1)
    (check-eq? (vector-ref (car events) 0) 'error)
    (check-eq? (vector-ref (car events) 3) 'cordis)
    (check-pred exn:fail:user? (vector-ref (car events) 2))
    (check-regexp-match #rx"reporter" (vector-ref (car events) 1))))

;; ---------------------------------------------------------------------------------------
;; call-contained (contract section 12, item 4)

(test-case "call-contained: returns the thunk's values"
  (with-root-context (ctx)
    (check-equal? (call-contained ctx (lambda () 'value)) 'value)
    (check-equal? (call-with-values (lambda () (call-contained ctx (lambda () (values 1 2))))
                                    list)
                  '(1 2))
    (define-values (_ events) (capture-log (lambda () (call-contained ctx void))))
    (check-equal? events '())))

(test-case "call-contained: an exn:fail is logged on the context's logger and becomes void"
  (with-root-context (ctx)
    (define f (ctx-plugin ctx (make-plugin (lambda (c config) (void)) #:name "Container")))
    (await/t f)
    (define c (fiber-context f))
    (define failure (exn:fail:user "it failed" (current-continuation-marks)))
    ;; a receiver on the fiber's own logger and one on the cordis logger both see the report
    (define own (make-log-receiver (ctx-logger c) 'error))
    (define-values (result events)
      (capture-log (lambda () (call-contained c (lambda () (raise failure)) #:label "step"))))
    (check-equal? result (void))
    (check-equal? (length events) 1)
    (check-eq? (vector-ref (car events) 0) 'error)
    (check-equal? (vector-ref (car events) 1) "cordis: Container: step: it failed")
    (check-eq? (vector-ref (car events) 2) failure)
    (check-eq? (vector-ref (car events) 3) 'cordis)
    (check-eq? (vector-ref (sync/t own) 2) failure)
    ;; without a label; every call reports, also for an exception seen before
    (define-values (_ again)
      (capture-log (lambda ()
                     (call-contained c (lambda () (raise failure)))
                     (call-contained ctx (lambda () (raise failure)) #:label 'root-step))))
    (check-equal? (map (lambda (e) (vector-ref e 1)) again)
                  '("cordis: Container: it failed" "cordis: root: root-step: it failed"))))

(test-case "call-contained: breaks and values that are not exn:fail propagate"
  (with-root-context (ctx)
    (define-values (outcomes events)
      (capture-log
       (lambda ()
         (list (with-handlers ([symbol? values])
                 (call-contained ctx (lambda () (raise 'not-an-exception))))
               (with-handlers ([exn:break? (lambda (e) 'break)])
                 (call-contained ctx (lambda ()
                                       (break-thread (current-thread))
                                       (task-check-break)
                                       'not-broken)))))))
    (check-equal? outcomes '(not-an-exception break))
    (check-equal? events '())))

(test-case "call-contained: usable from a thread that is not a task"
  (define root (make-root-context))
  (define-values (result events)
    (capture-log (lambda () (call-contained root (lambda () (error "outside"))))))
  (check-equal? result (void))
  (check-equal? (length events) 1)
  (context-shutdown! root))
