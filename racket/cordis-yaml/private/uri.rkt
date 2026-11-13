#lang racket/base
;; Provides ECMAScript's URI coding functions on Racket strings: `uri-decode` (decodeURI and
;; decodeURIComponent), which returns #f where JavaScript throws URIError, and `uri-encode`
;; (encodeURI and encodeURIComponent), which cannot fail because a Racket string holds no lone
;; surrogate.

(provide uri-decode
         uri-encode
         uri-reserved-characters
         uri-component-unescaped?
         uri-unescaped?)

;; Characters whose escapes `decodeURI` leaves in place.
(define uri-reserved-characters ";/?:@&=+$,#")

(define (hex-value c)
  (cond [(char<=? #\0 c #\9) (- (char->integer c) 48)]
        [(char<=? #\a c #\f) (- (char->integer c) 87)]
        [(char<=? #\A c #\F) (- (char->integer c) 55)]
        [else #f]))

;; The byte written as %XX at index i of s, or #f.
(define (escaped-byte s i)
  (and (< (+ i 2) (string-length s))
       (char=? (string-ref s i) #\%)
       (let ([hi (hex-value (string-ref s (+ i 1)))]
             [lo (hex-value (string-ref s (+ i 2)))])
         (and hi lo (+ (* 16 hi) lo)))))

;; uri-decode : string? string? -> (or/c string? #f)
;; Replaces each %XX sequence by the character its UTF-8 bytes encode. An escape of a character
;; in `keep` stays as written. #f for a malformed escape or invalid UTF-8.
(define (uri-decode s keep)
  (define len (string-length s))
  (define out (open-output-string))
  (let loop ([i 0])
    (cond
      [(= i len) (get-output-string out)]
      [(not (char=? (string-ref s i) #\%))
       (write-char (string-ref s i) out)
       (loop (add1 i))]
      [else
       (define b (escaped-byte s i))
       (cond
         [(not b) #f]
         [(< b #x80)
          (define c (integer->char b))
          (if (for/or ([k (in-string keep)]) (char=? k c))
              (write-string (substring s i (+ i 3)) out)
              (write-char c out))
          (loop (+ i 3))]
         [else
          (define count
            (cond [(= (bitwise-and b #xE0) #xC0) 2]
                  [(= (bitwise-and b #xF0) #xE0) 3]
                  [(= (bitwise-and b #xF8) #xF0) 4]
                  [else #f]))
          (define utf8
            (and count
                 (let collect ([k 1] [acc (list b)])
                   (cond
                     [(= k count) (apply bytes (reverse acc))]
                     [else
                      (define next (escaped-byte s (+ i (* 3 k))))
                      (and next
                           (= (bitwise-and next #xC0) #x80)
                           (collect (add1 k) (cons next acc)))]))))
          (define decoded
            (and utf8
                 ;; exn:fail:contract: the bytes are not valid UTF-8, which is a URIError.
                 (with-handlers ([exn:fail:contract? (lambda (e) #f)])
                   (bytes->string/utf-8 utf8))))
          (cond [decoded
                 (write-string decoded out)
                 (loop (+ i (* 3 count)))]
                [else #f])])])))

(define (alphanumeric? c)
  (or (char<=? #\a c #\z) (char<=? #\A c #\Z) (char<=? #\0 c #\9)))

;; What encodeURIComponent leaves unescaped.
(define (uri-component-unescaped? c)
  (or (alphanumeric? c) (and (memv c '(#\- #\_ #\. #\! #\~ #\* #\' #\( #\))) #t)))

;; What encodeURI leaves unescaped.
(define (uri-unescaped? c)
  (or (uri-component-unescaped? c)
      (for/or ([k (in-string uri-reserved-characters)]) (char=? k c))))

;; uri-encode : string? (-> char? boolean?) -> string?
;; Escapes the UTF-8 bytes of every character that `unescaped?` rejects, in uppercase hex.
(define (uri-encode s unescaped?)
  (define out (open-output-string))
  (for ([c (in-string s)])
    (if (unescaped? c)
        (write-char c out)
        (for ([b (in-bytes (string->bytes/utf-8 (string c)))])
          (write-string "%" out)
          (write-string (string-upcase (if (< b 16)
                                           (string-append "0" (number->string b 16))
                                           (number->string b 16)))
                        out))))
  (get-output-string out))
