#lang racket/base
;; dsh-util/error: the harness error base, the Racket form of dsh HarnessError.
;;
;; source: packages/util/error/src/index.ts
;;
;; An exn:fail:harness carries the dsh error class name ("LlmError", "ToolArgsError", ...; a
;; direct instance is "HarnessError"), a stable machine-routable code, optional JSON details and
;; a chained cause. Callers route on the code, never on the message text. The struct is exported
;; with its struct information so other packages can declare substructs; `define-harness-error`
;; declares one together with a constructor that fills in the dsh name.
;;
;; A raised exn:fail:harness is, by convention of this port, an expected failure: one a tool
;; result or a caller is prepared to carry. Any other exception is unexpected.

(require racket/contract/base
         cordis-data
         (for-syntax racket/base
                     racket/syntax
                     syntax/parse))

(provide (struct-out exn:fail:harness)
         prop:error-cause
         define-harness-error
         (contract-out
          [make-harness-error
           (->* (string? string? string?) (#:details (or/c jvalue? #f) #:cause any/c)
                exn:fail:harness?)]
          [raise-harness-error
           (->* (string? string?)
                (#:name string? #:details (or/c jvalue? #f) #:cause any/c)
                #:rest list?
                none/c)]
          [harness-error? (-> any/c boolean?)]
          [harness-error-name (-> exn:fail:harness? string?)]
          [harness-error-code (-> exn:fail:harness? string?)]
          [harness-error-details (-> exn:fail:harness? (or/c jvalue? #f))]
          [harness-error-cause (-> exn:fail:harness? any/c)]
          [harness-error-message (-> exn:fail:harness? string?)]
          [harness-error->jvalue
           (->* (exn:fail:harness?) (#:message? any/c #:details? any/c) jobject?)]
          [harness-error->string (-> exn:fail:harness? string?)]
          [error-cause (-> any/c any/c)]
          [error-chain (-> any/c list?)]))

;; A structure type property holding (-> self any/c): the value's cause, or #f. Any exception
;; struct may carry it so that `error-cause` and `error-chain` follow causes across packages.
(define-values (prop:error-cause has-error-cause? error-cause-ref)
  (make-struct-type-property 'error-cause))

;; name    : dsh error class name
;; code    : stable failure code
;; details : jvalue or #f; data a caller may attach for programs, never needed to route
;; cause   : the underlying raised value, or #f
(struct exn:fail:harness exn:fail (name code details cause)
  #:transparent
  #:property prop:error-cause (lambda (e) (exn:fail:harness-cause e))
  #:guard (lambda (message marks name code details cause struct-name)
            (unless (string? name)
              (raise-argument-error struct-name "string?" name))
            (unless (string? code)
              (raise-argument-error struct-name "string?" code))
            (unless (or (not details) (jvalue? details))
              (raise-argument-error struct-name "(or/c jvalue? #f)" details))
            (values message marks name code details cause)))

;; Builds, without raising, a harness error with an explicit dsh name. This is the constructor
;; for errors of packages the caller may not require (a "JobError" made by dsh-exec).
(define (make-harness-error name code message #:details [details #f] #:cause [cause #f])
  (exn:fail:harness (string->immutable-string message) (current-continuation-marks)
                    name code details cause))

;; Raises a harness error whose message is (format fmt arg ...).
(define (raise-harness-error code fmt
                             #:name [name "HarnessError"]
                             #:details [details #f]
                             #:cause [cause #f]
                             . args)
  (raise (make-harness-error name code (apply format fmt args) #:details details #:cause cause)))

(define (harness-error? v) (exn:fail:harness? v))
(define (harness-error-name e) (exn:fail:harness-name e))
(define (harness-error-code e) (exn:fail:harness-code e))
(define (harness-error-details e) (exn:fail:harness-details e))
(define (harness-error-cause e) (exn:fail:harness-cause e))
(define (harness-error-message e) (exn-message e))

;; The identity a failed tool result persists: {name, code}.
;; source: packages/core/tools/src/pipeline.ts (errorInfo)
;; With #:message? the object also carries `message`; with #:details? it carries `details` when
;; the error has any. Both are Racket-side conveniences for logs and wire layers.
(define (harness-error->jvalue e #:message? [message? #f] #:details? [details? #f])
  (jobj ['name (exn:fail:harness-name e)]
        ['code (exn:fail:harness-code e)]
        #:when message? ['message (exn-message e)]
        #:when (and details? (exn:fail:harness-details e)) ['details (exn:fail:harness-details e)]))

;; JavaScript String(error): "<name>: <message>", or the name alone for an empty message.
(define (harness-error->string e)
  (define message (exn-message e))
  (if (string=? message "")
      (exn:fail:harness-name e)
      (string-append (exn:fail:harness-name e) ": " message)))

;; The cause recorded on a value that carries prop:error-cause; #f for anything else.
(define (error-cause v)
  (and (has-error-cause? v) ((error-cause-ref v) v)))

;; The value followed by its causes, outermost first. A cycle ends the list.
(define (error-chain v)
  (let loop ([v v] [seen '()])
    (define cause (error-cause v))
    (if (and cause (not (memq cause seen)) (not (eq? cause v)))
        (cons v (loop cause (cons v seen)))
        (list v))))

;; (define-harness-error id name-string)
;; (define-harness-error id name-string (field ...))
;; Declares `id` as a substruct of exn:fail:harness with the extra fields, and
;; (make-<id> code message field ... #:details [d #f] #:cause [c #f]) which builds one with the
;; dsh error name `name-string`. It does not raise.
(define-syntax (define-harness-error stx)
  (syntax-parse stx
    [(_ id:id name:str (~optional (field:id ...) #:defaults ([(field 1) '()])))
     #:with make-id (format-id #'id "make-~a" #'id)
     #'(begin
         (struct id exn:fail:harness (field ...) #:transparent)
         (define (make-id code message field ... #:details [details #f] #:cause [cause #f])
           (id (string->immutable-string message) (current-continuation-marks)
               name code details cause field ...)))]))
