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
;; in the form digits.digits or digits[.digits]e[+-]digits; only the layout, and the digit
;; chosen on a tie, differ from JavaScript's.
(define (positive-flonum->js-string x)
  (define s (number->string x))
  (define len (string-length s))
  ;; In this range JavaScript writes plain positional digits; when Racket did too, `point` is
  ;; the index of its decimal point.
  (define point (and (fl>= x 1e-6) (fl< x 1e21) (plain-point-index s len)))
  (cond
    [(not point) (digits->js-string x s len)]
    ;; An integer of 2^53 or more, to which Racket appends ".0".
    [(and (fx= point (fx- len 2)) (char=? (string-ref s (fx- len 1)) #\0))
     (digits->js-string x s len)]
    ;; Sixteen or more digits ending in an odd one may be the upper side of a tie.
    [(and (fx>= len 17)
          (odd-digit? (string-ref s (fx- len 1)))
          (may-be-halfway? x (fx- (fx- len point) 1)))
     (digits->js-string x s len)]
    [else s]))

;; The index of the decimal point when s is plain positional digits such as "12.5"; #f when s
;; has an exponent.
(define (plain-point-index s len)
  (let loop ([i 0] [point #f])
    (cond
      [(fx= i len) point]
      [(char=? (string-ref s i) #\e) #f]
      [(char=? (string-ref s i) #\.) (loop (fx+ i 1) i)]
      [else (loop (fx+ i 1) point)])))

(define (odd-digit? c)
  (fx= 1 (fxand 1 (char->integer c))))

;; The general case: takes Racket's text `s` apart into digits and a decimal exponent and lays
;; them out again by Number::toString's rules.
(define (digits->js-string x s len)
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
  (define scale (- k n))
  (cond
    [(and (fx>= k 16)
          (odd-digit? (string-ref digits (fx- k 1)))
          (may-be-halfway? x scale))
     (define upper (string->number digits 10))
     (define lower (- upper 1))
     (if (and
          ;; x x 10^scale is exactly upper - 1/2,
          (= (* 2 (inexact->exact x) (expt 10 scale)) (- (* 2 upper) 1))
          ;; and the lower candidate too reads back as x.
          (fl= x (real->double-flonum (* lower (expt 10 (- scale))))))
         (number->string lower)
         digits)]
    [else digits]))

;; A cheap necessary condition for x x 10^scale to end in exactly one half: with `scale`
;; decimal places such a value has exactly scale + 1 binary places. It rules out nearly every
;; x before any exact arithmetic.
(define (may-be-halfway? x scale)
  (or (< scale 0)
      (let ([shifted (fl* x (flexpt 2.0 (fx->fl (+ scale 1))))])
        (fl= shifted (flfloor shifted)))))

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
