#lang racket/base
;; Provides `js-number->string`: the text JavaScript's `String(n)` produces for a number, following
;; the ECMAScript `Number::toString` algorithm in radix 10.
;;
;; An exact integer or exact rational is first rounded to the nearest double (ties to even), as
;; JavaScript does when it reads the number, so an exact integer with a magnitude above 2^53
;; prints the digits of that double and not its own digits.

(require racket/flonum
         racket/fixnum)

(provide js-number->string
         flonum->js-string)

;; 2^53: every integer up to this magnitude is a double, so its own digits are the JS digits.
(define max-safe-magnitude 9007199254740992)
(define max-safe-magnitude.0 9007199254740992.0)

;; js-number->string : real? -> string?
(define (js-number->string n)
  (cond
    [(fixnum? n)
     (if (and (fx<= n max-safe-magnitude) (fx>= n (fx- 0 max-safe-magnitude)))
         (number->string n)
         (flonum->js-string (fx->fl n)))]
    [(flonum? n) (flonum->js-string n)]
    [else (flonum->js-string (real->double-flonum n))]))

;; flonum->js-string : flonum? -> string?
(define (flonum->js-string x)
  (cond
    [(not (fl= x x)) "NaN"]
    [(fl= x 0.0) "0"]
    [(fl= x +inf.0) "Infinity"]
    [(fl= x -inf.0) "-Infinity"]
    [(and (fl< (flabs x) max-safe-magnitude.0) (fl= x (flfloor x)))
     (number->string (fl->exact-integer x))]
    [(fl< x 0.0) (string-append "-" (positive-flonum->js-string (fl- 0.0 x)))]
    [else (positive-flonum->js-string x)]))

;; x is positive and finite. `number->string` yields the shortest digits that read back as x,
;; in the form digits[.digits][e[+-]digits]; only the layout differs from JavaScript's.
(define (positive-flonum->js-string x)
  (define s (number->string x))
  (define len (string-length s))
  (define e-index (find-char s #\e len))
  (define dot-index (find-char s #\. e-index))
  (define exponent (if (fx= e-index len) 0 (string->number (substring s (fx+ e-index 1)) 10)))
  (define all-digits
    (if (fx= dot-index e-index)
        (substring s 0 e-index)
        (string-append (substring s 0 dot-index) (substring s (fx+ dot-index 1) e-index))))
  ;; The value is 0.<all-digits> x 10^point.
  (define point (+ dot-index exponent))
  (define count (string-length all-digits))
  (define first-nonzero
    (let loop ([i 0])
      (if (and (fx< i count) (char=? (string-ref all-digits i) #\0)) (loop (fx+ i 1)) i)))
  (define end-nonzero
    (let loop ([i count])
      (if (and (fx> i first-nonzero) (char=? (string-ref all-digits (fx- i 1)) #\0))
          (loop (fx- i 1))
          i)))
  (define n (- point first-nonzero))
  (layout-digits (even-on-tie x (substring all-digits first-nonzero end-nonzero) n) n))

;; `digits` are the shortest digits Racket chose for x, with x = 0.<digits> x 10^n. When x lies
;; exactly halfway between two shortest candidates Racket takes the upper one, while
;; Number::toString takes the one whose last digit is even; this returns the even candidate in
;; that case and `digits` otherwise. Such a tie needs at least 16 digits, because below that
;; two neighbouring candidates are too far apart to both read back as x.
(define (even-on-tie x digits n)
  (define k (string-length digits))
  (cond
    [(and (fx>= k 16)
          (odd? (char->integer (string-ref digits (fx- k 1))))
          (halfway-below? x (string->number digits 10) (- k n)))
     (define lower (- (string->number digits 10) 1))
     ;; The lower candidate counts only if it too reads back as x.
     (if (fl= x (real->double-flonum (* lower (expt 10 (- n k)))))
         (number->string lower)
         digits)]
    [else digits]))

;; Whether x x 10^scale is exactly `upper` - 1/2, for an exact integer `upper`.
(define (halfway-below? x upper scale)
  (and
   ;; With `scale` decimal places the halfway point has exactly scale + 1 binary places, so a
   ;; flonum test rules out nearly every x before any exact arithmetic.
   (or (< scale 0)
       (let ([shifted (fl* x (flexpt 2.0 (fx->fl (+ scale 1))))])
         (fl= shifted (flfloor shifted))))
   (= (* 2 (inexact->exact x) (expt 10 scale)) (- (* 2 upper) 1))))

;; Index of the first `c` in s before `end`, or `end`.
(define (find-char s c end)
  (let loop ([i 0])
    (cond
      [(fx= i end) end]
      [(char=? (string-ref s i) c) i]
      [else (loop (fx+ i 1))])))

;; Number::toString steps 6 to 10. `digits` has k characters, no leading or trailing zero, and
;; the value is 0.<digits> x 10^n.
(define (layout-digits digits n)
  (define k (string-length digits))
  (cond
    [(and (<= k n) (<= n 21)) (string-append digits (make-string (- n k) #\0))]
    [(and (< 0 n) (<= n 21)) (string-append (substring digits 0 n) "." (substring digits n))]
    [(and (< -6 n) (<= n 0)) (string-append "0." (make-string (- n) #\0) digits)]
    [else
     (define e (- n 1))
     (define exponent-text (string-append (if (< e 0) "e-" "e+") (number->string (abs e))))
     (if (= k 1)
         (string-append digits exponent-text)
         (string-append (substring digits 0 1) "." (substring digits 1) exponent-text))]))
