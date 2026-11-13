#lang racket/base
;; Tests for dsh-util/brand. packages/util/brand/tests/brand.spec.ts checks that branding leaves
;; the runtime value unchanged; here the wrapper is distinct and the underlying value is what
;; `unbrand`, `display` and the unwrapper give back.

(require rackunit
         racket/format
         racket/contract
         dsh-util/brand)

(define-brand session-id)
(define-brand tool-call-id)
(define-brand event-ordinal #:kind number)
(define-brand agent-id #:check (lambda (s) (positive? (string-length s))))

(test-case "a number brand keeps its value"
  (define value (event-ordinal 7))
  (check-pred event-ordinal? value)
  (check-equal? (event-ordinal->number value) 7)
  (check-equal? (unbrand value) 7))

(test-case "a string brand wraps, unwraps and is idempotent"
  (define id (session-id "s-1"))
  (check-pred session-id? id)
  (check-pred branded? id)
  (check-equal? (session-id->string id) "s-1")
  (check-eq? (session-id id) id)
  (check-equal? (brand-value id) "s-1")
  (check-eq? (brand-name id) 'session-id))

(test-case "brands of different names do not mix"
  (define sid (session-id "x"))
  (define tid (tool-call-id "x"))
  (check-false (tool-call-id? sid))
  (check-false (session-id? tid))
  (check-false (session-id? "x"))
  (check-false (equal? sid tid))
  (check-exn exn:fail:contract? (lambda () (session-id->string tid)))
  (define/contract (takes-session id) (-> session-id? string?) (session-id->string id))
  (check-equal? (takes-session sid) "x")
  (check-exn exn:fail:contract? (lambda () (takes-session tid))))

(test-case "equal underlying values of one brand are equal and hash alike"
  (check-equal? (session-id "a") (session-id "a"))
  (check-not-equal? (session-id "a") (session-id "b"))
  (check-equal? (hash-ref (hash (session-id "a") 1) (session-id "a")) 1))

(test-case "ids serialise as their plain text"
  (define id (session-id "s-1"))
  (check-equal? (~a id) "s-1")
  (check-equal? (format "~s" id) "#<session-id \"s-1\">")
  (check-equal? (unbrand id) "s-1")
  (check-equal? (unbrand "plain") "plain")
  (check-equal? (~a (event-ordinal 3)) "3"))

(test-case "the constructor checks its argument"
  (check-exn exn:fail:contract? (lambda () (session-id 5)))
  (check-exn exn:fail:contract? (lambda () (event-ordinal "5")))
  (check-exn exn:fail:contract? (lambda () (event-ordinal +nan.0)))
  (check-exn exn:fail:contract? (lambda () (agent-id "")))
  (check-pred agent-id? (agent-id "main")))
