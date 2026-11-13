#lang racket/base
;; Values and helpers that every module of the data plane shares: the `absent` marker, the
;; scalar predicates of session positions, `exn:fail:session`, and readers that treat a jvalue
;; the way the TypeScript source treats a JavaScript value (`String(v)`, truthiness, `===`,
;; structural equality, optional member access).
;;
;; Nothing here is exported to other packages directly; `dsh-session/types` re-exports the
;; public part with contracts.

(require racket/string
         cordis-data)

(provide absent
         absent?
         max-safe-integer
         safe-integer?
         session-seq?
         session-log-offset?
         session-id?
         ->session-seq
         ->session-log-offset
         valid-seq?
         session-format-version
         (struct-out exn:fail:session)
         raise-session-error
         raise-contract-error
         record?
         field
         has-field?
         js-string
         js-truthy?
         js-strict-equal?
         json-deep-equal?
         nonempty-string?)

;; ---- the absent marker ----

(struct absent-marker ()
  #:property prop:custom-write
  (lambda (v port mode) (write-string "#<absent>" port)))

;; The one value that stands for "key not present".
(define absent (absent-marker))

(define (absent? v) (eq? v absent))

;; ---- scalars ----

;; source: Number.MAX_SAFE_INTEGER
(define max-safe-integer 9007199254740991)

;; An exact integer, or an integral flonum other than -0.0, of magnitude at most 2^53 - 1.
(define (safe-integer? v)
  (and (real? v)
       (or (exact-integer? v)
           (and (flonum? v) (integer? v) (not (eqv? v -0.0))))
       (<= (abs v) max-safe-integer)))

(define (session-seq? v)
  (and (exact-integer? v) (<= 0 v max-safe-integer)))

(define (session-log-offset? v)
  (session-seq? v))

(define (session-id? v)
  (string? v))

;; True for a number that JavaScript would accept as an event seq: an exact or integral
;; flonum value from 0 to 2^53 - 1, not -0.0.
(define (valid-seq? v)
  (and (safe-integer? v) (>= v 0)))

;; source: packages/core/session/src/types.ts (SessionSeq, SessionLogOffset)
(define (->session-seq v)
  (if (valid-seq? v)
      (inexact->exact v)
      (raise-contract-error "SessionSeq must be a non-negative safe integer, got ~a"
                            (js-string v))))

(define (->session-log-offset v)
  (if (valid-seq? v)
      (inexact->exact v)
      (raise-contract-error "SessionLogOffset must be a non-negative safe integer, got ~a"
                            (js-string v))))

;; source: packages/core/session/src/types.ts (SESSION_FORMAT_VERSION)
(define session-format-version 4)

;; ---- errors ----

;; The counterpart of a dsh `Error` thrown by the session package.
(struct exn:fail:session exn:fail ())

(define (raise-session-error fmt . args)
  (raise (exn:fail:session (apply format fmt args) (current-continuation-marks))))

;; The counterpart of a dsh `TypeError`; the message is the dsh text with no prefix.
(define (raise-contract-error fmt . args)
  (raise (exn:fail:contract (apply format fmt args) (current-continuation-marks))))

;; ---- JavaScript-shaped readers ----

;; `isRecord`: a JSON object, as opposed to an array or scalar.
(define (record? v)
  (or (jobject? v) (hash? v)))

;; `value?.[key]`: the member, or `absent` when `v` is not an object or lacks the key.
(define (field v key)
  (if (record? v) (jref v key absent) absent))

;; `Object.hasOwn(value, key)` for an object; #f for anything else.
(define (has-field? v key)
  (and (record? v) (jhas? v key)))

(define (nonempty-string? v)
  (and (string? v) (not (string=? v ""))))

;; `String(v)` for a jvalue or `absent`.
(define (js-string v)
  (cond
    [(or (absent? v) (void? v)) "undefined"]
    [(eq? v 'null) "null"]
    [(eq? v #t) "true"]
    [(eq? v #f) "false"]
    [(string? v) v]
    [(real? v) (js-number->string v)]
    [(list? v)
     (string-join (for/list ([member (in-list v)])
                    (if (or (eq? member 'null) (absent? member)) "" (js-string member)))
                  ",")]
    [(record? v) "[object Object]"]
    [else (format "~a" v)]))

;; JavaScript truthiness of a jvalue or `absent`.
(define (js-truthy? v)
  (not (or (absent? v)
           (eq? v #f)
           (eq? v 'null)
           (and (real? v) (zero? v))
           (and (string? v) (string=? v "")))))

;; `a === b` for scalars and `absent`; containers compare by identity.
(define (js-strict-equal? a b)
  (cond
    [(and (real? a) (real? b)) (= a b)]
    [(and (string? a) (string? b)) (string=? a b)]
    [else (eq? a b)]))

;; source: packages/core/session/src/surface.ts (isDeepEqualJson)
(define (json-deep-equal? a b)
  (cond
    [(js-strict-equal? a b) #t]
    [(or (list? a) (list? b))
     (and (list? a) (list? b)
          (= (length a) (length b))
          (andmap json-deep-equal? a b))]
    [(and (record? a) (record? b))
     (and (= (jcount a) (jcount b))
          (for/and ([member (in-list (jobject->alist a))])
            (and (jhas? b (car member))
                 (json-deep-equal? (cdr member) (jref b (car member))))))]
    [else #f]))
