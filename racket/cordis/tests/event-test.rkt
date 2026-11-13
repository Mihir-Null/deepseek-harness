#lang racket/base
;; Events: contract section 7. Registration, the five dispatch modes, filters, and the
;; internal events that concern dispatch.
(require rackunit
         racket/list
         cordis
         cordis/testing
         "common.rkt")

(define (labels f) (map disposer-label (fiber-effects f)))

;; ---------------------------------------------------------------------------------------
;; Registration

(test-case "on: an effect labelled ctx.on(\"name\"); order with prepend; removal"
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (define (listener tag) (lambda () (note tag)))
    (define a (listener 'a))
    (define da (ctx-on ctx 'event a))
    (ctx-on ctx 'event (listener 'b))
    (ctx-on ctx 'event (listener 'c-prepend) #:prepend? #t)
    (ctx-on ctx 'event (listener 'd-prepend) #:prepend? #t)
    (check-true (disposer? da))
    (check-equal? (disposer-label da) "ctx.on(\"event\")")
    (check-equal? (labels (context-fiber ctx)) (make-list 4 "ctx.on(\"event\")"))
    (check-equal? (length (ctx-listeners ctx 'event)) 4)
    (check-eq? (third (ctx-listeners ctx 'event)) a)
    (check-equal? (ctx-listeners ctx 'nothing) '())
    (check-equal? (ctx-emit ctx 'event) (void))
    (check-equal? (notes) '(d-prepend c-prepend a b))
    (check-equal? (da) (void))
    (ctx-emit ctx 'event)
    (check-equal? (drop (notes) 4) '(d-prepend c-prepend b))))

(test-case "on: listeners die with the fiber that registered them"
  (with-root-context (ctx)
    (define before (ctx-listeners ctx 'event))
    (define f (ctx-plugin ctx (lambda (c config) (ctx-on c 'event void) (void))))
    (await/t f)
    (check-equal? (length (ctx-listeners ctx 'event)) 1)
    (fiber-dispose! f)
    (check-equal? (ctx-listeners ctx 'event) before)))

(test-case "on: the same procedure registered twice is two registrations"
  (define count 0)
  (with-root-context (ctx)
    (define (listener) (set! count (add1 count)))
    (define d1 (ctx-on ctx 'event listener))
    (define d2 (ctx-on ctx 'event listener))
    (ctx-emit ctx 'event)
    (d1)
    (ctx-emit ctx 'event)
    (d2)
    (ctx-emit ctx 'event))
  (check-equal? count 3))

(test-case "on: a listener runs with current-context set to the registering context"
  (with-root-context (ctx)
    (define f (ctx-plugin ctx (lambda (c config) (void))))
    (await/t f)
    (define seen #f)
    (ctx-on (fiber-context f) 'event (lambda () (set! seen (current-context))))
    (ctx-emit ctx 'event)
    (check-eq? seen (fiber-context f))))

(test-case "once: the listener is removed before its first call"
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (ctx-once ctx 'event (lambda (x)
                           (note (list x (length (ctx-listeners ctx 'event))))))
    (check-equal? (length (ctx-listeners ctx 'event)) 1)
    (ctx-emit ctx 'event 1)
    (ctx-emit ctx 'event 2)
    (check-equal? (labels (context-fiber ctx)) '())
    (define d (ctx-once ctx 'event note))
    (d)
    (ctx-emit ctx 'event 3))
  (check-equal? (notes) '((1 0))))

(test-case "internal/listener: a bailed result replaces the registration"
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (define (listener) 'unused)
    (ctx-on ctx 'internal/listener
            (lambda (c name l options)
              (note (list (eq? c ctx) name (eq? l listener) options))
              (and (eq? name 'claimed) 'claimed-by-service)))
    (check-equal? (ctx-on ctx 'claimed listener #:prepend? #t) 'claimed-by-service)
    (check-equal? (ctx-listeners ctx 'claimed) '())
    (check-true (disposer? (ctx-on ctx 'free listener #:global? #t)))
    (check-equal? (ctx-listeners ctx 'free) (list listener)))
  (check-equal? (notes)
                (list (list #t 'claimed #t (hasheq 'prepend #t 'global #f))
                      (list #t 'free #t (hasheq 'prepend #f 'global #t)))))

;; ---------------------------------------------------------------------------------------
;; emit

(test-case "emit: listeners run in order in the calling task; a failure stops delivery"
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (define me (current-thread))
    (ctx-on ctx 'event (lambda (a b) (note (list 'first a b (eq? (current-thread) me))) 'ignored))
    (ctx-on ctx 'event (lambda (a b) (raise-user-error "listener failed")))
    (ctx-on ctx 'event (lambda (a b) (note 'unreached)))
    (check-exn #rx"listener failed" (lambda () (ctx-emit ctx 'event 1 2)))
    (check-equal? (ctx-emit ctx 'nobody-listens 1 2 3) (void)))
  (check-equal? (notes) '((first 1 2 #t))))

(test-case "dispatch uses the listener list as it was when the dispatch started"
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (define late #f)
    (define d-second #f)
    (ctx-on ctx 'event (lambda ()
                         (note 'first)
                         (unless late
                           (set! late (ctx-on ctx 'event (lambda () (note 'added-during)))))
                         (d-second)))
    (set! d-second (ctx-on ctx 'event (lambda () (note 'second))))
    (ctx-emit ctx 'event)
    (check-equal? (notes) '(first second))
    (ctx-emit ctx 'event)
    (check-equal? (drop (notes) 2) '(first added-during))))

;; ---------------------------------------------------------------------------------------
;; parallel

(test-case "parallel: every listener is its own task; all are awaited; failures aggregate"
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (define me (current-thread))
    (define g (gate))
    (ctx-on ctx 'event (lambda (x) (note 'a-start) (gate-wait g) (note 'a-end)))
    (ctx-on ctx 'event (lambda (x) (note (list 'b (eq? (current-thread) me))) (gate-open! g)))
    (check-equal? (ctx-parallel ctx 'event 1) (void))
    (check-equal? (notes) '(a-start (b #f) a-end))
    (ctx-on ctx 'event (lambda (x) (raise-user-error "one")))
    (ctx-on ctx 'event (lambda (x) (note 'after-failure)))
    (ctx-on ctx 'event (lambda (x) (raise 'two)))
    (define e (with-handlers ([exn:fail:cordis:aggregate? values]) (ctx-parallel ctx 'event 1)))
    (check-pred exn:fail:cordis:aggregate? e)
    (check-equal? (length (exn:fail:cordis:aggregate-errors e)) 2)
    (check-pred exn:fail:user? (first (exn:fail:cordis:aggregate-errors e)))
    (check-equal? (second (exn:fail:cordis:aggregate-errors e)) 'two)
    (check-not-false (memq 'after-failure (notes)))
    (check-equal? (ctx-parallel ctx 'nobody-listens) (void))))

;; ---------------------------------------------------------------------------------------
;; serial and bail

(test-case "serial, bail: the first bailed result; #f, void and 'null do not bail"
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (check-true (bailed? 0))
    (check-true (bailed? ""))
    (check-true (bailed? '()))
    (check-false (bailed? #f))
    (check-false (bailed? (void)))
    (check-false (bailed? 'null))
    (ctx-on ctx 'event (lambda (x) (note 1) #f))
    (ctx-on ctx 'event (lambda (x) (note 2) (void)))
    (ctx-on ctx 'event (lambda (x) (note 3) 'null))
    (check-equal? (ctx-bail ctx 'event 'arg) (void))
    (check-equal? (ctx-serial ctx 'event 'arg) (void))
    (ctx-on ctx 'event (lambda (x) (note 4) 0))
    (ctx-on ctx 'event (lambda (x) (note 5) 'too-late))
    (check-equal? (ctx-bail ctx 'event 'arg) 0)
    (check-equal? (ctx-serial ctx 'event 'arg) 0)
    (check-equal? (ctx-bail ctx 'nobody-listens) (void))
    ;; a listener may wait; the others run after it
    (define g (gate))
    (ctx-on ctx 'slow (lambda () (gate-wait g) #f))
    (ctx-on ctx 'slow (lambda () 'after-wait))
    (define dispatch (spawn-task (lambda () (ctx-serial ctx 'slow))))
    (yield-task)
    (gate-open! g)
    (check-equal? (await/t dispatch) 'after-wait)
    (ctx-on ctx 'failing (lambda () (raise-user-error "serial failed")))
    (check-exn #rx"serial failed" (lambda () (ctx-serial ctx 'failing)))
    (check-exn #rx"serial failed" (lambda () (ctx-bail ctx 'failing))))
  (check-equal? (notes) '(1 2 3 1 2 3 1 2 3 4 1 2 3 4)))

;; ---------------------------------------------------------------------------------------
;; waterfall

(test-case "waterfall: listeners wrap the rest of the chain, ending in inner"
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (check-equal? (ctx-waterfall ctx 'event 1 (lambda () 'inner-only)) 'inner-only)
    (ctx-on ctx 'event (lambda (x next) (note (list 'w1 x)) (list 'w1 (next))))
    (ctx-on ctx 'event (lambda (x next) (note (list 'w2 x)) (list 'w2 (next))))
    (check-equal? (ctx-waterfall ctx 'event 5 (lambda () (note 'inner) 'core))
                  '(w1 (w2 core)))
    (check-equal? (notes) '((w1 5) (w2 5) inner))
    ;; a listener that does not call next short-circuits the chain, inner included
    (define d (ctx-on ctx 'event (lambda (x next) 'vetoed) #:prepend? #t))
    (check-equal? (ctx-waterfall ctx 'event 5 (lambda () (note 'unreached))) 'vetoed)
    (check-equal? (length (notes)) 3)
    (d)
    (check-exn exn:fail:contract? (lambda () (ctx-waterfall ctx 'event 5 'not-a-procedure)))))

(test-case "waterfall: a second call to the same next raises"
  (with-root-context (ctx)
    (ctx-on ctx 'event (lambda (next) (next) (next)))
    (check-exn-message exn:fail:cordis? #rx"^next\\(\\) called multiple times$"
                       (lambda () (ctx-waterfall ctx 'event (lambda () 'inner))))))

;; ---------------------------------------------------------------------------------------
;; ctx-dispatch, filters, internal/dispatch

(test-case "ctx-dispatch: every mode; #:filter applies to registering contexts; global bypasses"
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (define scope-a (context-extend ctx (hasheq 'scope 'a)))
    (define scope-b (context-extend ctx (hasheq 'scope 'b)))
    (ctx-on scope-a 'event (lambda (x) (note (list 'a x)) #f))
    (ctx-on scope-b 'event (lambda (x) (note (list 'b x)) 'from-b))
    (ctx-on scope-b 'event (lambda (x) (note (list 'global x)) #f) #:global? #t)
    (define (in-a? c) (eq? (context-meta c 'scope) 'a))
    (check-equal? (ctx-dispatch ctx 'emit 'event '(1) #:filter in-a?) (void))
    (check-equal? (notes) '((a 1) (global 1)))
    (check-equal? (ctx-dispatch ctx 'bail 'event '(2) #:filter in-a?) (void))
    (check-equal? (ctx-dispatch ctx 'bail 'event '(3)) 'from-b)
    (check-equal? (ctx-dispatch ctx 'serial 'event '(4)) 'from-b)
    (check-equal? (ctx-dispatch ctx 'parallel "event" '(5) #:filter in-a?) (void))
    (ctx-on scope-a 'wrap (lambda (x next) (list 'a (next))))
    (ctx-on scope-b 'wrap (lambda (x next) (list 'b (next))))
    (check-equal? (ctx-dispatch ctx 'waterfall 'wrap '(6) #:inner (lambda () 'core)) '(a (b core)))
    (check-equal? (ctx-dispatch ctx 'waterfall 'wrap '(6) #:filter in-a? #:inner (lambda () 'core))
                  '(a core))
    (check-equal? (ctx-dispatch ctx 'waterfall 'nobody '()) (void))
    (check-exn exn:fail:contract? (lambda () (ctx-dispatch ctx 'broadcast 'event '())))))

(test-case "internal/dispatch: told of every dispatch of a name that is not internal"
  (define-values (note notes) (make-recorder))
  (with-root-context (ctx)
    (ctx-emit ctx 'before-any-observer)
    (define inner (lambda () 'core))
    (ctx-on ctx 'internal/dispatch (lambda (mode name args) (note (list mode name args))))
    (ctx-emit ctx 'e 0 'x)
    (ctx-bail ctx 'b)
    (ctx-serial ctx 's 1)
    (ctx-parallel ctx 'p 2)
    (ctx-waterfall ctx 'w 3 inner)
    ;; internal events are not reported
    (ctx-provide ctx 'db 1)
    (await/t (ctx-plugin ctx (lambda (c config) (void))))
    (check-equal? (notes)
                  (list '(emit e (0 x)) '(bail b ()) '(serial s (1)) '(parallel p (2))
                        (list 'waterfall 'w (list 3 inner))))))

(test-case "dispatch works from a thread that is not a task"
  (define-values (note notes) (make-recorder))
  (define root (make-root-context))
  (define s (context-scheduler root))
  (ctx-on root 'event (lambda (x) (note (list x (in-task? s))) x))
  (ctx-emit root 'event 1)
  (check-equal? (ctx-bail root 'event 2) 2)
  (check-equal? (ctx-serial root 'event 3) 3)
  (ctx-parallel root 'event 4)
  (check-equal? (ctx-waterfall root 'other (lambda () 'inner)) 'inner)
  (check-equal? (notes) '((1 #t) (2 #t) (3 #t) (4 #t)))
  (context-shutdown! root))
