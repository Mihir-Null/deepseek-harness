#lang racket/base
;; JavaScript text primitives that the dsh utility sources rely on and Racket spells
;; differently: String.prototype.trim and the \s class, encodeURIComponent,
;; decodeURIComponent (strict, as JavaScript raises URIError), and base64.
;; Internal to dsh-util.

(require racket/string
         racket/list
         net/uri-codec
         net/base64)

(provide js-whitespace?
         js-trim
         js-blank?
         js-split-whitespace
         encode-uri-component
         decode-uri-component
         bytes->base64-string
         base64-string->bytes
         string-index-of
         string-last-index-of)

;; ECMAScript WhiteSpace and LineTerminator code points: what trim() and /\s/ match.
(define (js-whitespace? c)
  (define n (char->integer c))
  (or (<= 9 n 13)
      (= n #x20) (= n #xA0) (= n #x1680)
      (<= #x2000 n #x200A)
      (= n #x2028) (= n #x2029) (= n #x202F) (= n #x205F) (= n #x3000) (= n #xFEFF)))

;; str.trim()
(define (js-trim s)
  (define n (string-length s))
  (define start
    (let loop ([i 0]) (if (and (< i n) (js-whitespace? (string-ref s i))) (loop (add1 i)) i)))
  (define end
    (let loop ([i n]) (if (and (> i start) (js-whitespace? (string-ref s (sub1 i)))) (loop (sub1 i)) i)))
  (if (and (= start 0) (= end n)) s (substring s start end)))

;; str.trim() === ''
(define (js-blank? s)
  (for/and ([c (in-string s)]) (js-whitespace? c)))

;; str.split(/\s+/): keeps a leading or trailing empty string as JavaScript does.
(define (js-split-whitespace s)
  (define n (string-length s))
  (let loop ([i 0] [start 0] [acc '()])
    (cond
      [(= i n) (reverse (cons (substring s start n) acc))]
      [(js-whitespace? (string-ref s i))
       (define j (let skip ([j i]) (if (and (< j n) (js-whitespace? (string-ref s j))) (skip (add1 j)) j)))
       (loop j j (cons (substring s start i) acc))]
      [else (loop (add1 i) start acc)])))

;; encodeURIComponent: UTF-8 percent-encoding of everything except A-Z a-z 0-9 - _ . ! ~ * ' ( ).
;; net/uri-codec's uri-encode keeps exactly that unreserved set.
(define (encode-uri-component s) (uri-encode s))

(define (hex-digit c)
  (cond [(char<=? #\0 c #\9) (- (char->integer c) 48)]
        [(char<=? #\a c #\f) (- (char->integer c) 87)]
        [(char<=? #\A c #\F) (- (char->integer c) 55)]
        [else #f]))

;; decodeURIComponent: the decoded string, or #f where JavaScript raises URIError (a `%` not
;; followed by two hex digits, or escapes that are not well-formed UTF-8).
(define (decode-uri-component s)
  (define n (string-length s))
  (define out (open-output-bytes))
  (let loop ([i 0])
    (cond
      [(= i n)
       (define bs (get-output-bytes out))
       (and (utf-8-well-formed? bs) (bytes->string/utf-8 bs))]
      [(char=? (string-ref s i) #\%)
       (define hi (and (<= (+ i 3) n) (hex-digit (string-ref s (+ i 1)))))
       (define lo (and hi (hex-digit (string-ref s (+ i 2)))))
       (and lo
            (begin (write-byte (+ (* 16 hi) lo) out)
                   (loop (+ i 3))))]
      [else
       (write-string (string (string-ref s i)) out)
       (loop (add1 i))])))

;; Strict UTF-8 as JavaScript's Decode requires: no overlong forms, no surrogates, at most U+10FFFF.
(define (utf-8-well-formed? bs)
  (define n (bytes-length bs))
  (define (cont? i) (and (< i n) (= (bitwise-and (bytes-ref bs i) #xC0) #x80)))
  (let loop ([i 0])
    (cond
      [(= i n) #t]
      [else
       (define b (bytes-ref bs i))
       (cond
         [(< b #x80) (loop (add1 i))]
         [(<= #xC2 b #xDF) (and (cont? (+ i 1)) (loop (+ i 2)))]
         [(<= #xE0 b #xEF)
          (and (cont? (+ i 1)) (cont? (+ i 2))
               (let ([b1 (bytes-ref bs (+ i 1))])
                 (and (not (and (= b #xE0) (< b1 #xA0)))
                      (not (and (= b #xED) (>= b1 #xA0)))))
               (loop (+ i 3)))]
         [(<= #xF0 b #xF4)
          (and (cont? (+ i 1)) (cont? (+ i 2)) (cont? (+ i 3))
               (let ([b1 (bytes-ref bs (+ i 1))])
                 (and (not (and (= b #xF0) (< b1 #x90)))
                      (not (and (= b #xF4) (>= b1 #x90)))))
               (loop (+ i 4)))]
         [else #f])])))

;; Canonical base64 with padding and no line breaks (btoa, Buffer.toString('base64')).
(define (bytes->base64-string bs)
  (bytes->string/latin-1 (base64-encode bs #"")))

(define (base64-string->bytes s)
  (base64-decode (string->bytes/latin-1 s (char->integer #\?))))

;; str.indexOf(ch, from) and str.lastIndexOf(ch) for one character; #f when absent.
(define (string-index-of s ch [from 0])
  (for/first ([i (in-range from (string-length s))] #:when (char=? (string-ref s i) ch)) i))

(define (string-last-index-of s ch)
  (for/first ([i (in-range (sub1 (string-length s)) -1 -1)] #:when (char=? (string-ref s i) ch)) i))
