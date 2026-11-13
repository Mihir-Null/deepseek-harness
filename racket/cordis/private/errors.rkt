#lang racket/base
;; Exception structs raised by the kernel, and helpers that build them with the exact
;; message texts of vendor/cordis/src. Every kernel failure is an `exn:fail:cordis`.
(require racket/string)
(provide (struct-out exn:fail:cordis)
         (struct-out exn:fail:cordis:inactive)
         (struct-out exn:fail:cordis:inject)
         (struct-out exn:fail:cordis:service)
         (struct-out exn:fail:cordis:validation)
         (struct-out exn:fail:cordis:aggregate)
         (struct-out exn:fail:cordis:task-killed)
         raise-cordis raise-inactive raise-inject raise-service raise-task-killed
         make-validation-error raise-validation-error
         inactive-message value->error error->string)

(struct exn:fail:cordis exn:fail ())
(struct exn:fail:cordis:inactive exn:fail:cordis ())
(struct exn:fail:cordis:inject exn:fail:cordis (key))
(struct exn:fail:cordis:service exn:fail:cordis (key))
(struct exn:fail:cordis:validation exn:fail:cordis (issues))
(struct exn:fail:cordis:aggregate exn:fail:cordis (errors))
(struct exn:fail:cordis:task-killed exn:fail:cordis ())

;; source: vendor/cordis/src/fiber.ts (CordisError.Code.INACTIVE_EFFECT)
(define inactive-message "cannot create effect on inactive context")

(define (raise-cordis fmt . args)
  (raise (exn:fail:cordis (apply format fmt args) (current-continuation-marks))))

(define (raise-inactive [message inactive-message])
  (raise (exn:fail:cordis:inactive message (current-continuation-marks))))

(define (raise-inject key fmt)
  (raise (exn:fail:cordis:inject (format fmt key) (current-continuation-marks) key)))

(define (raise-service key message)
  (raise (exn:fail:cordis:service message (current-continuation-marks) key)))

(define (raise-task-killed message)
  (raise (exn:fail:cordis:task-killed message (current-continuation-marks))))

;; issues : (listof (cons/c (listof any/c) string?)); an empty path omits the "(at ...)" part.
;; source: vendor/cordis/src/fiber.ts (ValidationError)
(define (make-validation-error issues)
  (define lines
    (for/list ([issue (in-list issues)])
      (define path (car issue))
      (if (null? path)
          (format "  - ~a" (cdr issue))
          (format "  - ~a (at ~a)" (cdr issue)
                  (string-join (map (lambda (p) (format "~a" p)) path) ".")))))
  (exn:fail:cordis:validation (string-append "invalid config:\n" (string-join lines "\n"))
                              (current-continuation-marks)
                              issues))

(define (raise-validation-error issues)
  (raise (make-validation-error issues)))

;; A raised value that is not an exception is wrapped so that a recorded failure is always
;; an exn (vendor/cordis/src/utils.ts wraps thrown non-errors the same way).
(define (value->error v)
  (if (exn? v)
      v
      (exn:fail:cordis (format "~a" v) (current-continuation-marks))))

(define (error->string v)
  (if (exn? v) (exn-message v) (format "~s" v)))
