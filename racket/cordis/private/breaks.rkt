#lang racket/base
;; Break discipline for kernel code. `critical` runs kernel bookkeeping with breaks disabled
;; and remembers the break state of the code that entered the kernel; `call-user` runs a
;; callback (plugin body, listener, inverse, or a wait made on the caller's behalf) under
;; that remembered state. A break therefore reaches user code and waits, never a half-done
;; kernel update.
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
