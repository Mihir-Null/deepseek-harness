#lang racket/base
;; Provides the string length units dsh mixes: UTF-16 code units (JavaScript's `str.length`),
;; UTF-8 bytes and code points, with truncation that never splits a character, and JavaScript's
;; default string ordering.
;;
;; A Racket string is a sequence of code points and cannot hold half of a surrogate pair. Where
;; JavaScript would return such a half (a slice that cuts through a pair), these functions drop
;; the whole character. A function that returns a prefix may return its argument itself.

(require racket/fixnum)

(provide utf16-length
         utf16-substring
         utf16-truncate
         utf8-length
         utf8-truncate
         code-point-length
         js-string<?)

;; UTF-16 code units a character occupies.
(define (char-utf16-width c)
  (if (fx> (char->integer c) #xFFFF) 2 1))

;; utf16-length : string? -> exact-nonnegative-integer?
(define (utf16-length str)
  (define n (string-length str))
  (let loop ([i 0] [units 0])
    (if (fx= i n)
        units
        (loop (fx+ i 1) (fx+ units (char-utf16-width (string-ref str i)))))))

;; utf16-substring : string? exact-nonnegative-integer? [(or/c exact-nonnegative-integer? #f)]
;;                   -> string?
;; The characters that lie wholly inside the UTF-16 unit range [start, end); `end` #f means the
;; end of the string. An `end` at or before `start` yields "".
(define (utf16-substring str start [end #f])
  (define n (string-length str))
  ;; Index of the first character that begins at or after unit `start`, and its unit offset.
  (define-values (from from-units)
    (let loop ([i 0] [units 0])
      (if (or (fx= i n) (>= units start))
          (values i units)
          (loop (fx+ i 1) (fx+ units (char-utf16-width (string-ref str i)))))))
  (define to
    (if end
        (let loop ([i from] [units from-units])
          (cond
            [(fx= i n) n]
            [else
             (define next (fx+ units (char-utf16-width (string-ref str i))))
             (if (> next end) i (loop (fx+ i 1) next))]))
        n))
  (if (and (fx= from 0) (fx= to n)) str (substring str from to)))

;; utf16-truncate : string? exact-nonnegative-integer? -> string?
(define (utf16-truncate str max-units)
  (if (<= (* 2 (string-length str)) max-units)
      str
      (utf16-substring str 0 max-units)))

;; utf8-length : string? -> exact-nonnegative-integer?
(define (utf8-length str)
  (string-utf-8-length str))

;; utf8-truncate : string? exact-nonnegative-integer? -> string?
(define (utf8-truncate str max-bytes)
  (define n (string-length str))
  (cond
    [(<= (* 4 n) max-bytes) str]
    [else
     (define to
       (let loop ([i 0] [bytes 0])
         (cond
           [(fx= i n) n]
           [else
            (define next (fx+ bytes (char-utf-8-length (string-ref str i))))
            (if (> next max-bytes) i (loop (fx+ i 1) next))])))
     (if (fx= to n) str (substring str 0 to))]))

;; code-point-length : string? -> exact-nonnegative-integer?
(define (code-point-length str)
  (string-length str))

;; js-string<? : string? string? -> boolean?
;; Orders by UTF-16 code units. This differs from `string<?` only where a character above
;; U+FFFF meets one in U+E000..U+FFFF: the surrogates that encode the former sort lower.
(define (js-string<? a b)
  (define na (string-length a))
  (define nb (string-length b))
  (let loop ([i 0])
    (cond
      [(fx= i nb) #f]
      [(fx= i na) #t]
      [else
       (define ca (string-ref a i))
       (define cb (string-ref b i))
       (if (char=? ca cb)
           (loop (fx+ i 1))
           (fx< (first-utf16-difference-key ca cb) (first-utf16-difference-key cb ca)))])))

;; A key that orders two different characters as their UTF-16 encodings order. Two characters
;; on the same side of U+FFFF order by code point; otherwise the one above U+FFFF is
;; represented by its high surrogate.
(define (first-utf16-difference-key c other)
  (define code (char->integer c))
  (if (and (fx> code #xFFFF) (fx<= (char->integer other) #xFFFF))
      (fx+ #xD800 (fxrshift (fx- code #x10000) 10))
      code))
