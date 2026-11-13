#lang racket/base
;; Provides `deep-equal?`, structural equality over jvalues with the rules of cosmokit's
;; `deepEqual`.
;; source: vendor/cosmokit/src/types.ts (deepEqual)
;;
;; `(void)` stands for JavaScript's `undefined`: it is what an absent object key compares as.
;; Values outside the jvalue model (anything cosmokit would call an opaque object) compare
;; with `equal?`.

(require "core.rkt")

(provide deep-equal?)

;; deep-equal? : any/c any/c #:strict? any/c -> boolean?
;; Objects compare as maps, whatever their key order; arrays element by element; numbers with
;; `=`, so 1 equals 1.0, -0.0 equals 0.0 and NaN equals nothing. When `strict?` is false, 'null
;; and `(void)` are equal to each other, so a key holding 'null equals an absent key.
(define (deep-equal? a b #:strict? [strict? #f])
  (define (nullish? v)
    (or (eq? v 'null) (void? v)))

  (define (compare a b)
    (cond
      [(real? a) (and (real? b) (= a b))]
      [(eq? a b) #t]
      [(and (not strict?) (nullish? a)) (nullish? b)]
      [(string? a) (and (string? b) (string=? a b))]
      [(object-like? a) (and (object-like? b) (compare-objects a b))]
      [(pair? a) (and (pair? b) (compare-arrays a b))]
      [(or (null? a) (boolean? a) (symbol? a) (void? a)) #f]
      [else (equal? a b)]))

  (define (compare-arrays a b)
    (cond
      [(and (pair? a) (pair? b)) (and (compare (car a) (car b)) (compare-arrays (cdr a) (cdr b)))]
      [(or (pair? a) (pair? b)) #f]
      ;; Both lists ended, or the values are not lists at all.
      [else (equal? a b)]))

  ;; Every key of either object must compare equal, an absent key comparing as `(void)`.
  (define (compare-objects a b)
    (define left (->jobject 'deep-equal? a))
    (define right (->jobject 'deep-equal? b))
    (define left-table (jobject-table left))
    (define right-table (jobject-table right))
    (and (for/and ([(key value) (in-immutable-hash left-table)])
           (compare value (hash-ref right-table key (void))))
         (for/and ([(key value) (in-immutable-hash right-table)])
           (or (hash-has-key? left-table key)
               (compare (void) value)))))

  (compare a b))
