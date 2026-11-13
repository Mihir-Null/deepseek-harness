#lang racket/base
;; Tests for dsh-util/error. Mirrors packages/util/error/tests/error.spec.ts and covers the
;; Racket-side constructors, the tool-result identity and the cause chain.

(require rackunit
         cordis-data
         dsh-util/error)

(define-harness-error exn:fail:sample "SampleError")
(define-harness-error exn:fail:args "ToolArgsError" (violations))

(test-case "carries a code, a cause and the declared class name"
  (define cause (make-exn:fail "underlying failure" (current-continuation-marks)))
  (define e (make-exn:fail:sample "SAMPLE_FAILED" "operation failed" #:cause cause))
  (check-pred exn:fail? e)
  (check-pred exn:fail:harness? e)
  (check-pred exn:fail:sample? e)
  (check-equal? (harness-error-name e) "SampleError")
  (check-equal? (harness-error-code e) "SAMPLE_FAILED")
  (check-equal? (exn-message e) "operation failed")
  (check-eq? (harness-error-cause e) cause)
  (check-false (harness-error-details e)))

(test-case "names a direct instance HarnessError"
  (define e
    (with-handlers ([exn:fail:harness? values])
      (raise-harness-error "FAILED" "failed")))
  (check-equal? (harness-error-name e) "HarnessError")
  (check-equal? (exn:fail:harness-code e) "FAILED")
  (check-equal? (harness-error-message e) "failed"))

(test-case "raise-harness-error formats its message and keeps details and cause"
  (define e
    (with-handlers ([exn:fail:harness? values])
      (raise-harness-error "FS_NOT_FOUND" "no such file: ~a (~s)" "a.txt" 3
                           #:name "FsError"
                           #:details (jobj ['path "a.txt"])
                           #:cause 'enoent)))
  (check-equal? (exn-message e) "no such file: a.txt (3)")
  (check-equal? (harness-error-name e) "FsError")
  (check-equal? (harness-error-details e) (jobj ['path "a.txt"]))
  (check-eq? (harness-error-cause e) 'enoent))

(test-case "make-harness-error builds without raising"
  (define e (make-harness-error "JobError" "JOB_NOT_FOUND" "unknown job j1"))
  (check-pred harness-error? e)
  (check-equal? (list (harness-error-name e) (harness-error-code e) (exn-message e))
                '("JobError" "JOB_NOT_FOUND" "unknown job j1"))
  (check-true (immutable? (exn-message e))))

(test-case "substruct constructors take their extra fields"
  (define e (make-exn:fail:args "INVALID_ARGS" "bad arguments" '("path must be a string")))
  (check-equal? (exn:fail:args-violations e) '("path must be a string"))
  (check-equal? (harness-error-name e) "ToolArgsError"))

(test-case "the tool-result identity is {name, code} in that order"
  (define e (make-exn:fail:sample "SAMPLE_FAILED" "operation failed"))
  (check-equal? (jvalue->string (harness-error->jvalue e))
                "{\"name\":\"SampleError\",\"code\":\"SAMPLE_FAILED\"}")
  (define detailed (make-harness-error "X" "C" "m" #:details (jobj ['n 1])))
  (check-equal? (jvalue->string (harness-error->jvalue detailed #:message? #t #:details? #t))
                "{\"name\":\"X\",\"code\":\"C\",\"message\":\"m\",\"details\":{\"n\":1}}")
  (check-equal? (jvalue->string (harness-error->jvalue e #:details? #t))
                "{\"name\":\"SampleError\",\"code\":\"SAMPLE_FAILED\"}"))

(test-case "the string form is JavaScript's String(error)"
  (check-equal? (harness-error->string (make-harness-error "LlmError" "RATE_LIMIT" "slow down"))
                "LlmError: slow down")
  (check-equal? (harness-error->string (make-harness-error "LlmError" "RATE_LIMIT" ""))
                "LlmError"))

(test-case "error-cause and error-chain follow causes"
  (define root (make-exn:fail "root" (current-continuation-marks)))
  (define middle (make-harness-error "A" "A_CODE" "middle" #:cause root))
  (define top (make-harness-error "B" "B_CODE" "top" #:cause middle))
  (check-eq? (error-cause top) middle)
  (check-false (error-cause root))
  (check-false (error-cause 'not-an-error))
  (check-equal? (error-chain top) (list top middle root))
  (check-equal? (error-chain 5) '(5)))

(test-case "the guard rejects a non-string name or code and non-JSON details"
  (check-exn exn:fail:contract?
             (lambda () (exn:fail:harness "m" (current-continuation-marks) 'name "C" #f #f)))
  (check-exn exn:fail:contract?
             (lambda () (exn:fail:harness "m" (current-continuation-marks) "N" 'code #f #f)))
  (check-exn exn:fail:contract?
             (lambda () (exn:fail:harness "m" (current-continuation-marks) "N" "C" (void) #f))))
