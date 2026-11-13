#lang racket/base
;; Break discipline for kernel code.
;;
;; A task runs with breaks disabled and accepts a break only at a release point reached
;; under the break state it started with (see scheduler.rkt). `critical` runs kernel
;; bookkeeping under a break state of its own, so a wait inside it is never interrupted, and
;; remembers the break state of the code that entered the kernel. `call-user` runs a
;; callback (plugin body, listener, inverse, or a wait made on the caller's behalf) under
;; that remembered state, so a wait there accepts a break exactly when the caller's own
;; wait would. A break therefore reaches user code at its wait points and never a half-done
;; kernel update. On a thread that is not a task, where breaks may be enabled, `critical`
;; also keeps an asynchronous break out of the bookkeeping.
(provide critical call-critical call-user)

(define user-breaks-key (make-continuation-mark-key 'cordis-user-breaks))

;; Nested uses without an intervening `call-user` keep the outermost break state.
(define (call-critical thunk)
  (if (continuation-mark-set-first #f user-breaks-key #f)
      (thunk)
      (let ([bpz (current-break-parameterization)])
        (with-continuation-mark user-breaks-key bpz
          (parameterize-break #f (thunk))))))

(define-syntax-rule (critical body ...)
  (call-critical (lambda () body ...)))

;; Outside any `critical` section this is a plain call.
(define (call-user thunk)
  (define bpz (continuation-mark-set-first #f user-breaks-key #f))
  (if bpz
      (with-continuation-mark user-breaks-key #f
        (call-with-break-parameterization bpz thunk))
      (thunk)))
