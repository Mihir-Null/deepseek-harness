#lang racket/base
;; Provides the scalar types of js-yaml's JSON schema: which plain scalar texts are a null, a
;; boolean, an integer or a float, and the value each one constructs. The reader uses them to
;; resolve plain and explicitly tagged scalars; the writer uses `resolves-implicitly?` to decide
;; which strings must be quoted.
;; source: js-yaml 4.3.2 lib/type/null.js, bool.js, int.js, float.js

(require (only-in racket/math infinite?))

(provide resolve-null
         resolve-bool
         resolve-int
         resolve-float
         resolve-plain-scalar
         resolves-implicitly?
         no-match)

;; Each `resolve-*` takes the scalar text, or 'null for a node without content, and returns the
;; constructed value or `no-match`.
(define no-match (string->uninterned-symbol "no-match"))

(define (resolve-null data)
  (cond [(eq? data 'null) 'null]
        [(member data '("~" "null" "Null" "NULL")) 'null]
        [else no-match]))

(define (resolve-bool data)
  (cond [(eq? data 'null) no-match]
        [(member data '("true" "True" "TRUE")) #t]
        [(member data '("false" "False" "FALSE")) #f]
        [else no-match]))

;; An optional sign, then decimal digits, or 0b, 0o, 0x and digits of that base. The value must
;; be finite as a double; js-yaml tests `isFinite(parseInt(...))`.
(define (resolve-int data)
  (cond
    [(eq? data 'null) no-match]
    [(regexp-match #px"^([-+]?)(?:0b([01]+)|0x([0-9a-fA-F]+)|0o([0-7]+)|([0-9]+))$" data)
     => (lambda (m)
          (define magnitude
            (cond [(list-ref m 2) => (lambda (digits) (string->number digits 2))]
                  [(list-ref m 3) => (lambda (digits) (string->number digits 16))]
                  [(list-ref m 4) => (lambda (digits) (string->number digits 8))]
                  [else (string->number (list-ref m 5) 10)]))
          (cond [(infinite? (exact->inexact magnitude)) no-match]
                [(string=? (list-ref m 1) "-") (- magnitude)]
                [else magnitude]))]
    [else no-match]))

(define float-pattern
  (pregexp (string-append "^(?:[-+]?(?:[0-9]+)(?:\\.[0-9]*)?(?:[eE][-+]?[0-9]+)?"
                          "|\\.[0-9]+(?:[eE][-+]?[0-9]+)?"
                          "|[-+]?\\.(?:inf|Inf|INF)"
                          "|\\.(?:nan|NaN|NAN))$")))

(define (resolve-float data)
  (cond
    [(eq? data 'null) no-match]
    [(not (regexp-match? float-pattern data)) no-match]
    [else
     (define lowered (string-downcase data))
     (define negative? (char=? (string-ref lowered 0) #\-))
     (define unsigned
       (if (memv (string-ref lowered 0) '(#\- #\+)) (substring lowered 1) lowered))
     (cond
       [(string=? unsigned ".inf") (if negative? -inf.0 +inf.0)]
       [(string=? unsigned ".nan") +nan.0]
       [else
        (define magnitude (decimal->flonum unsigned))
        (cond [(infinite? magnitude) no-match]
              [negative? (- magnitude)]
              [else magnitude])])]))

;; The double nearest to an unsigned decimal text of the forms digits[.digits][e[+-]digits] and
;; .digits[e[+-]digits], as JavaScript's `parseFloat` reads it.
(define (decimal->flonum text)
  (define m (regexp-match #px"^([0-9]*)(?:\\.([0-9]*))?(?:e([-+]?[0-9]+))?$" text))
  (define whole (if (string=? (list-ref m 1) "") "0" (list-ref m 1)))
  (define fraction (or (list-ref m 2) ""))
  (define exponent (if (list-ref m 3) (string->number (list-ref m 3) 10) 0))
  (define digits (string->number (string-append whole fraction) 10))
  (define scale (- exponent (string-length fraction)))
  ;; The value lies in [10^(magnitude-1), 10^magnitude).
  (define magnitude (+ scale (string-length (number->string digits))))
  (cond
    [(zero? digits) 0.0]
    ;; Beyond these bounds the result is infinite or zero whatever the digits are, and the
    ;; exact power of ten would be needlessly large.
    [(> magnitude 400) +inf.0]
    [(< magnitude -400) 0.0]
    [else (exact->inexact (* digits (expt 10 scale)))]))

;; resolve-plain-scalar : string? -> any/c
;; The value of a plain scalar: the first type that matches, in js-yaml's order, else the text.
(define (resolve-plain-scalar text)
  (let try ([resolvers (list resolve-null resolve-bool resolve-int resolve-float)])
    (cond [(null? resolvers) text]
          [else
           (define v ((car resolvers) text))
           (if (eq? v no-match) (try (cdr resolvers)) v)])))

;; resolves-implicitly? : string? -> boolean?
;; Whether a plain scalar with this text would read back as something other than a string.
(define (resolves-implicitly? text)
  (not (string? (resolve-plain-scalar text))))
