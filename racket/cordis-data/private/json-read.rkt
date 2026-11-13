#lang racket/base
;; Provides the JSON reader, which accepts what JavaScript's `JSON.parse` accepts (the RFC 8259
;; grammar and nothing more) and builds jvalues: objects keep their key order, a duplicate key
;; keeps its first position and its last value, a number written without fraction or exponent
;; is an exact integer and any other number a flonum, `-0` is -0.0, and an escaped lone
;; surrogate becomes U+FFFD because a Racket string cannot hold one.
;;
;; A syntax error raises `exn:fail:json` whose `position` is the 0-based index of the offending
;; character: an index into the string for `string->jvalue`, into the decoded text for
;; `bytes->jvalue`, and counted from where the call began reading for `read-jvalue`.

(require racket/fixnum
         racket/flonum
         "core.rkt")

(provide (struct-out exn:fail:json)
         string->jvalue
         bytes->jvalue
         read-jvalue)

(struct exn:fail:json exn:fail (position))

;; ---------------------------------------------------------------------------------------------
;; Characters and numbers

(define (digit? c)
  (and (char>=? c #\0) (char<=? c #\9)))

(define (digit-value c)
  (fx- (char->integer c) 48))

;; U+FFFD, which stands in for anything a Racket string cannot hold.
(define replacement-char (integer->char #xFFFD))

;; The value of a hexadecimal digit, or #f.
(define (hex-value c)
  (cond
    [(digit? c) (digit-value c)]
    [(and (char>=? c #\a) (char<=? c #\f)) (fx- (char->integer c) 87)]
    [(and (char>=? c #\A) (char<=? c #\F)) (fx- (char->integer c) 55)]
    [else #f]))

;; 10^0 .. 10^22, the powers of ten that are doubles.
(define exact-powers-of-ten
  (for/vector #:length 23 ([k (in-range 23)])
    (real->double-flonum (expt 10 k))))

;; The double nearest to mantissa x 10^exponent10, where `digit-count` is at least the number
;; of decimal digits in `mantissa` (an exact nonnegative integer).
(define (decimal->flonum mantissa digit-count exponent10)
  (cond
    [(eqv? mantissa 0) 0.0]
    [(and (fx<= digit-count 15) (fx<= -22 exponent10 22))
     ;; Both operands are doubles, so one rounded operation gives the nearest double.
     (if (fx< exponent10 0)
         (fl/ (fx->fl mantissa) (vector-ref exact-powers-of-ten (fx- 0 exponent10)))
         (fl* (fx->fl mantissa) (vector-ref exact-powers-of-ten exponent10)))]
    ;; At least 10^309, above every double.
    [(>= exponent10 309) +inf.0]
    ;; Below 10^-324, less than half the smallest positive double.
    [(< (+ digit-count exponent10) -324) 0.0]
    [(< exponent10 0) (real->double-flonum (/ mantissa (expt 10 (- exponent10))))]
    [else (real->double-flonum (* mantissa (expt 10 exponent10)))]))

;; ---------------------------------------------------------------------------------------------
;; Parser

;; parse-json : symbol? string? exact-nonnegative-integer? -> any/c
;; Parses all of `text` as one JSON value surrounded by optional whitespace. `base` is added to
;; the position an error reports.
(define (parse-json who text base)
  (define end (string-length text))
  ;; Index of the first character after the value most recently parsed.
  (define pos 0)

  (define (fail message at)
    (define position (+ base at))
    (raise (exn:fail:json (format "~a: ~a at position ~a" who message position)
                          (current-continuation-marks)
                          position)))

  (define (fail-unexpected at)
    (if (fx>= at end)
        (fail "unexpected end of JSON input" at)
        (fail (format "unexpected character ~s" (string (string-ref text at))) at)))

  (define (skip-whitespace i)
    (if (fx< i end)
        (let ([c (string-ref text i)])
          (if (or (char=? c #\space) (char=? c #\newline) (char=? c #\return) (char=? c #\tab))
              (skip-whitespace (fx+ i 1))
              i))
        i))

  (define (skip-digits i)
    (if (and (fx< i end) (digit? (string-ref text i)))
        (skip-digits (fx+ i 1))
        i))

  ;; The character at `i` is `c`.
  (define (at? i c)
    (and (fx< i end) (char=? (string-ref text i) c)))

  (define (parse-value i)
    (when (fx>= i end) (fail-unexpected i))
    (define c (string-ref text i))
    (cond
      [(char=? c #\") (parse-string (fx+ i 1))]
      [(char=? c #\{) (parse-object (fx+ i 1))]
      [(char=? c #\[) (parse-array (fx+ i 1))]
      [(or (digit? c) (char=? c #\-)) (parse-number i)]
      [(char=? c #\t) (parse-literal i "true" #t)]
      [(char=? c #\f) (parse-literal i "false" #f)]
      [(char=? c #\n) (parse-literal i "null" 'null)]
      [else (fail-unexpected i)]))

  (define (parse-literal i word value)
    (define n (string-length word))
    (let loop ([k 0])
      (cond
        [(fx= k n)
         (set! pos (fx+ i n))
         value]
        [(at? (fx+ i k) (string-ref word k)) (loop (fx+ k 1))]
        [else (fail-unexpected (fx+ i k))])))

  ;; `i` is the index after the opening bracket.
  (define (parse-array i)
    (define first (skip-whitespace i))
    (cond
      [(at? first #\])
       (set! pos (fx+ first 1))
       '()]
      [else
       (let loop ([i first] [items '()])
         (define item (parse-value i))
         (define after (skip-whitespace pos))
         (cond
           [(at? after #\,) (loop (skip-whitespace (fx+ after 1)) (cons item items))]
           [(at? after #\])
            (set! pos (fx+ after 1))
            (reverse (cons item items))]
           [(fx>= after end) (fail-unexpected after)]
           [else (fail "expected ',' or ']' after array element" after)]))]))

  ;; `i` is the index after the opening brace.
  (define (parse-object i)
    (define first (skip-whitespace i))
    (cond
      [(at? first #\})
       (set! pos (fx+ first 1))
       empty-jobject]
      [else
       (let loop ([i first] [keys '()] [table #hasheq()])
         (unless (at? i #\")
           (if (fx>= i end)
               (fail-unexpected i)
               (fail "expected double-quoted property name" i)))
         (define key (string->symbol (parse-string (fx+ i 1))))
         (define colon (skip-whitespace pos))
         (unless (at? colon #\:)
           (if (fx>= colon end)
               (fail-unexpected colon)
               (fail "expected ':' after property name" colon)))
         (define value (parse-value (skip-whitespace (fx+ colon 1))))
         (define updated (hash-set table key value))
         ;; A duplicate key replaces the value and keeps its first position.
         (define keys+ (if (fx= (hash-count table) (hash-count updated)) keys (cons key keys)))
         (define after (skip-whitespace pos))
         (cond
           [(at? after #\,) (loop (skip-whitespace (fx+ after 1)) keys+ updated)]
           [(at? after #\})
            (set! pos (fx+ after 1))
            (make-raw-jobject (reverse keys+) '() updated)]
           [(fx>= after end) (fail-unexpected after)]
           [else (fail "expected ',' or '}' after property value" after)]))]))

  ;; `i` is the index after the opening quote.
  (define (parse-string i)
    (let loop ([j i])
      (when (fx>= j end) (fail "unterminated string" j))
      (define c (string-ref text j))
      (cond
        [(char=? c #\")
         (set! pos (fx+ j 1))
         (substring text i j)]
        [(char=? c #\\) (parse-escaped-string i j)]
        [(char<? c #\space) (fail "bad control character in string literal" j)]
        [else (loop (fx+ j 1))])))

  ;; The four hexadecimal digits at `k` as a number, or #f. `k`+4 is within the text.
  (define (hex4 k)
    (let loop ([m 0] [value 0])
      (if (fx= m 4)
          value
          (let ([digit (hex-value (string-ref text (fx+ k m)))])
            (and digit (loop (fx+ m 1) (fx+ (fx* value 16) digit)))))))

  ;; A string that starts at `i` and has its first backslash at `first-escape`.
  (define (parse-escaped-string i first-escape)
    (define close
      (let loop ([j first-escape])
        (cond
          [(fx>= j end) (fail "unterminated string" end)]
          [(char=? (string-ref text j) #\\) (loop (fx+ j 2))]
          [(char=? (string-ref text j) #\") j]
          [else (loop (fx+ j 1))])))
    ;; Every escape is at least as long as the character it stands for.
    (define decoded (make-string (fx- close i)))
    (string-copy! decoded 0 text i first-escape)
    (let loop ([j first-escape] [n (fx- first-escape i)])
      (define (emit c next)
        (string-set! decoded n c)
        (loop next (fx+ n 1)))
      (cond
        [(fx= j close)
         (set! pos (fx+ close 1))
         (substring decoded 0 n)]
        [else
         (define c (string-ref text j))
         (cond
           [(char=? c #\\)
            ;; The scan for `close` stepped over the character after each backslash, so it exists.
            (define e (string-ref text (fx+ j 1)))
            (cond
              [(char=? e #\u)
               (define unit (and (fx<= (fx+ j 6) close) (hex4 (fx+ j 2))))
               (cond
                 [(not unit) (fail "bad Unicode escape" (fx+ j 1))]
                 [(fx<= #xD800 unit #xDBFF)
                  (define low
                    (and (fx<= (fx+ j 12) close)
                         (char=? (string-ref text (fx+ j 6)) #\\)
                         (char=? (string-ref text (fx+ j 7)) #\u)
                         (hex4 (fx+ j 8))))
                  (if (and low (fx<= #xDC00 low #xDFFF))
                      (emit (integer->char (fx+ #x10000
                                                (fxlshift (fx- unit #xD800) 10)
                                                (fx- low #xDC00)))
                            (fx+ j 12))
                      (emit replacement-char (fx+ j 6)))]
                 [(fx<= #xDC00 unit #xDFFF) (emit replacement-char (fx+ j 6))]
                 [else (emit (integer->char unit) (fx+ j 6))])]
              [(or (char=? e #\") (char=? e #\\) (char=? e #\/)) (emit e (fx+ j 2))]
              [(char=? e #\n) (emit #\newline (fx+ j 2))]
              [(char=? e #\t) (emit #\tab (fx+ j 2))]
              [(char=? e #\r) (emit #\return (fx+ j 2))]
              [(char=? e #\b) (emit #\backspace (fx+ j 2))]
              [(char=? e #\f) (emit #\page (fx+ j 2))]
              [else (fail "bad escaped character" (fx+ j 1))])]
           [(char<? c #\space) (fail "bad control character in string literal" j)]
           [else (emit c (fx+ j 1))])])))

  (define (parse-number i)
    (define negative? (char=? (string-ref text i) #\-))
    (define int-start (if negative? (fx+ i 1) i))
    (define int-end
      (cond
        [(at? int-start #\0) (fx+ int-start 1)]
        [(and (fx< int-start end) (digit? (string-ref text int-start)))
         (skip-digits (fx+ int-start 1))]
        [(fx>= int-start end) (fail-unexpected int-start)]
        [else (fail "no number after minus sign" int-start)]))
    (define frac-end
      (cond
        [(at? int-end #\.)
         (define digits-end (skip-digits (fx+ int-end 1)))
         (when (fx= digits-end (fx+ int-end 1))
           (fail "unterminated fractional number" digits-end))
         digits-end]
        [else int-end]))
    (define exponent-start
      (cond
        [(or (at? frac-end #\e) (at? frac-end #\E))
         (if (or (at? (fx+ frac-end 1) #\-) (at? (fx+ frac-end 1) #\+))
             (fx+ frac-end 2)
             (fx+ frac-end 1))]
        [else #f]))
    (define number-end
      (cond
        [exponent-start
         (define digits-end (skip-digits exponent-start))
         (when (fx= digits-end exponent-start)
           (fail "exponent part is missing a number" digits-end))
         digits-end]
        [else frac-end]))
    (set! pos number-end)
    (cond
      [(fx= number-end int-end)
       (define magnitude (digits->integer int-start int-end))
       (cond
         [(not negative?) magnitude]
         [(eqv? magnitude 0) -0.0]
         [else (- magnitude)])]
      [else
       (define fraction-digits (if (fx> frac-end int-end) (fx- frac-end (fx+ int-end 1)) 0))
       (define digit-count (fx+ (fx- int-end int-start) fraction-digits))
       (define mantissa
         (cond
           [(fx= fraction-digits 0) (digits->integer int-start int-end)]
           [(fx<= digit-count 18)
            (accumulate-digits (fx+ int-end 1) frac-end (accumulate-digits int-start int-end 0))]
           [else
            (string->number (string-append (substring text int-start int-end)
                                           (substring text (fx+ int-end 1) frac-end))
                            10)]))
       (define exponent
         (if exponent-start
             (let ([magnitude (exponent-magnitude exponent-start number-end)])
               (if (char=? (string-ref text (fx- exponent-start 1)) #\-) (- magnitude) magnitude))
             0))
       (define magnitude (decimal->flonum mantissa digit-count (- exponent fraction-digits)))
       (if negative? (fl* -1.0 magnitude) magnitude)]))

  ;; `value` extended by the decimal digits in [from, to), in fixnum arithmetic: the caller
  ;; keeps the total at 18 digits or fewer.
  (define (accumulate-digits from to value)
    (if (fx= from to)
        value
        (accumulate-digits (fx+ from 1)
                           to
                           (fx+ (fx* value 10) (digit-value (string-ref text from))))))

  ;; The decimal digits in [from, to) as an exact integer.
  (define (digits->integer from to)
    (if (fx<= (fx- to from) 18)
        (accumulate-digits from to 0)
        (string->number (substring text from to) 10)))

  ;; The exponent digits in [from, to) as an exact integer, saturated near 10^15 so that an
  ;; absurdly long exponent costs nothing; `decimal->flonum` treats anything that large alike.
  (define (exponent-magnitude from to)
    (let loop ([j from] [value 0])
      (if (or (fx= j to) (fx>= value 1000000000000000))
          value
          (loop (fx+ j 1) (fx+ (fx* value 10) (digit-value (string-ref text j)))))))

  (define value (parse-value (skip-whitespace 0)))
  (define after (skip-whitespace pos))
  (unless (fx= after end)
    (fail "unexpected non-whitespace character after JSON" after))
  value)

;; ---------------------------------------------------------------------------------------------
;; UTF-8

;; bytes->string/replace : bytes? -> string?
;; Decodes UTF-8 as JavaScript's `TextDecoder` and Node's `buffer.toString('utf8')` do: each
;; maximal invalid byte sequence becomes one U+FFFD. A byte order mark is kept.
(define (bytes->string/replace bs)
  (if (bytes-utf-8-length bs #f)
      (bytes->string/utf-8 bs)
      (decode-utf-8/replace bs)))

;; The WHATWG Encoding Standard's UTF-8 decoder with replacement.
(define (decode-utf-8/replace bs)
  (define n (bytes-length bs))
  (define out (make-string n))
  (let loop ([i 0] [used 0] [needed 0] [seen 0] [code 0] [lower #x80] [upper #xBF])
    (define (emit c next)
      (string-set! out used c)
      (loop next (fx+ used 1) 0 0 0 #x80 #xBF))
    (cond
      [(fx= i n)
       (cond
         [(fx= needed 0) (substring out 0 used)]
         [else
          (string-set! out used replacement-char)
          (substring out 0 (fx+ used 1))])]
      [else
       (define b (bytes-ref bs i))
       (cond
         [(fx= needed 0)
          (cond
            [(fx<= b #x7F) (emit (integer->char b) (fx+ i 1))]
            [(fx<= #xC2 b #xDF) (loop (fx+ i 1) used 1 0 (fxand b #x1F) #x80 #xBF)]
            [(fx<= #xE0 b #xEF)
             (loop (fx+ i 1) used 2 0 (fxand b #xF)
                   (if (fx= b #xE0) #xA0 #x80)
                   (if (fx= b #xED) #x9F #xBF))]
            [(fx<= #xF0 b #xF4)
             (loop (fx+ i 1) used 3 0 (fxand b #x7)
                   (if (fx= b #xF0) #x90 #x80)
                   (if (fx= b #xF4) #x8F #xBF))]
            [else (emit replacement-char (fx+ i 1))])]
         ;; The sequence is cut short: replace it and decode this byte afresh.
         [(not (fx<= lower b upper)) (emit replacement-char i)]
         [else
          (define code+ (fxior (fxlshift code 6) (fxand b #x3F)))
          (if (fx= (fx+ seen 1) needed)
              (emit (integer->char code+) (fx+ i 1))
              (loop (fx+ i 1) used needed (fx+ seen 1) code+ #x80 #xBF))])])))

;; ---------------------------------------------------------------------------------------------
;; Entry points

;; string->jvalue : string? #:who symbol? -> any/c
;; `who` names the caller in the error message.
(define (string->jvalue str #:who [who 'string->jvalue])
  (parse-json who str 0))

;; bytes->jvalue : bytes? -> any/c
(define (bytes->jvalue bs)
  (parse-json 'bytes->jvalue (bytes->string/replace bs) 0))

(define (whitespace-byte? b)
  (or (eqv? b 32) (eqv? b 10) (eqv? b 13) (eqv? b 9)))

;; A byte that ends a number or literal when it follows one.
(define (delimiter-byte? b)
  (or (whitespace-byte? b)
      (eqv? b 44) ; ,
      (eqv? b 58) ; :
      (eqv? b 34) ; "
      (eqv? b 91) ; [
      (eqv? b 93) ; ]
      (eqv? b 123) ; {
      (eqv? b 125))) ; }

;; read-jvalue : [input-port?] -> any/c
;; Skips whitespace, then reads exactly one value and leaves the port just after it, so
;; consecutive calls read consecutive values. Returns eof when only whitespace remains. A number
;; or literal ends at whitespace, a structural character or the end of input, so the call waits
;; until one of those arrives. After a syntax error the port is left after the malformed text.
(define (read-jvalue [in (current-input-port)])
  (define skipped
    (let loop ([count 0])
      (if (whitespace-byte? (peek-byte in))
          (begin
            (read-byte in)
            (loop (fx+ count 1)))
          count)))
  (if (eof-object? (peek-byte in))
      eof
      (parse-json 'read-jvalue (bytes->string/replace (read-value-bytes in)) skipped)))

;; Consumes and returns the bytes of the next value in `in`, which is not at eof or whitespace.
;; The extent is found from brackets and string quotes alone; the parser judges the content.
(define (read-value-bytes in)
  (define out (open-output-bytes))
  (define chunk (make-bytes 4096))
  (define first (peek-byte in))
  ;; Nesting depth of brackets and braces, whether inside a string, whether after a backslash.
  (define depth 0)
  (define in-string? #f)
  (define escaped? #f)

  ;; Advances the bracket scanner over one byte; true when that byte closes the value.
  (define (closes-value? b)
    (cond
      [escaped?
       (set! escaped? #f)
       #f]
      [in-string?
       (cond
         [(eqv? b 92) (set! escaped? #t) #f]
         [(eqv? b 34) (set! in-string? #f) (fx= depth 0)]
         [else #f])]
      [(eqv? b 34) (set! in-string? #t) #f]
      [(or (eqv? b 91) (eqv? b 123)) (set! depth (fx+ depth 1)) #f]
      [(or (eqv? b 93) (eqv? b 125)) (set! depth (fx- depth 1)) (fx= depth 0)]
      [else #f]))

  ;; How many of the first `n` bytes of `chunk` belong to the value, and whether it ends there.
  (define (scan-bracketed n)
    (let loop ([i 0])
      (cond
        [(fx= i n) (values n #f)]
        [(closes-value? (bytes-ref chunk i)) (values (fx+ i 1) #t)]
        [else (loop (fx+ i 1))])))

  (define (scan-scalar n)
    (let loop ([i 0])
      (cond
        [(fx= i n) (values n #f)]
        [(delimiter-byte? (bytes-ref chunk i)) (values i #t)]
        [else (loop (fx+ i 1))])))

  (define (copy-extent scan)
    (let loop ()
      (define n (peek-bytes-avail! chunk 0 #f in))
      (when (exact-positive-integer? n)
        (define-values (count done?) (scan n))
        (write-bytes chunk out 0 count)
        (read-bytes! chunk in 0 count)
        (unless done? (loop)))))

  (cond
    [(or (eqv? first 34) (eqv? first 91) (eqv? first 123)) (copy-extent scan-bracketed)]
    ;; A character that cannot start a value is consumed alone so that the error it causes
    ;; does not repeat on the next call.
    [(delimiter-byte? first) (write-byte (read-byte in) out)]
    [else (copy-extent scan-scalar)])
  (get-output-bytes out))
