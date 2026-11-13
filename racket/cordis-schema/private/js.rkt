#lang racket/base
;; JavaScript coercions the Schemastery algorithms depend on, over the values of this port:
;; `typeof`, truthiness, `String(v)`, `JSON.stringify(v)`, double arithmetic for the `step`
;; check, `ToInt32`, regular-expression source translated to a Racket `pregexp`, and the
;; ECMAScript date-time format.
;;
;; `(void)` is `undefined` and 'null is `null`. A value outside the JavaScript model (a struct,
;; bytes, a regexp, a date) is an object without enumerable keys.

(require racket/date
         racket/list
         racket/math
         racket/string
         cordis-data
         "../volatile.rkt")

(provide nullable?
         js-truthy?
         js-typeof
         plain-object?
         ->object
         js-string
         js-json-value
         js-json-text
         json-absent?
         js-strict-equal?
         js-number
         js-remainder-zero?
         js-int32
         regexp-value?
         js-regexp
         js-regexp-source
         js-regexp-flags
         js-regexp-text
         iso-string->date
         date->iso-string
         bytes-from-hex
         bytes-from-base64)

;; ---------------------------------------------------------------------------------------------
;; Types

;; cosmokit `isNullable`.
(define (nullable? v)
  (or (void? v) (eq? v 'null)))

(define (regexp-value? v)
  (or (regexp? v) (byte-regexp? v)))

(define (js-truthy? v)
  (cond
    [(or (eq? v #f) (nullable? v)) #f]
    [(real? v) (not (or (zero? v) (nan? (real->double-flonum v))))]
    [(string? v) (not (string=? v ""))]
    [else #t]))

;; js-typeof : any/c -> (or/c 'undefined 'string 'number 'boolean 'function 'symbol 'object)
(define (js-typeof v)
  (cond
    [(void? v) 'undefined]
    [(string? v) 'string]
    [(real? v) 'number]
    [(boolean? v) 'boolean]
    [(eq? v 'null) 'object]
    [(procedure? v) 'function]
    [(symbol? v) 'symbol]
    [else 'object]))

;; cosmokit `isPlainObject`: any object that is not an array, opaque values included.
(define (plain-object? v)
  (and (eq? (js-typeof v) 'object)
       (not (eq? v 'null))
       (not (list? v))))

;; The enumerable keys and values of a plain object: a jobject for a jobject or hash, and the
;; empty jobject for an opaque value.
(define (->object v)
  (cond
    [(jobject? v) v]
    [(hash? v) (jmerge v)]
    [else empty-jobject]))

;; JavaScript `a === b` for values that are not both objects; objects compare with `eq?`.
(define (js-strict-equal? a b)
  (cond
    [(and (real? a) (real? b)) (= a b)]
    [(and (string? a) (string? b)) (string=? a b)]
    [else (eq? a b)]))

;; ---------------------------------------------------------------------------------------------
;; String(v)

(define (js-string v)
  (cond
    [(string? v) v]
    [(real? v) (js-number->string v)]
    [(eq? v #t) "true"]
    [(eq? v #f) "false"]
    [(eq? v 'null) "null"]
    [(void? v) "undefined"]
    [(list? v)
     (string-join (for/list ([item (in-list v)])
                    (if (nullable? item) "" (js-string item)))
                  ",")]
    [(or (jobject? v) (hash? v) (volatile? v)) "[object Object]"]
    ;; A procedure has no source text; this is what JavaScript prints for a native function.
    [(procedure? v)
     (define name (object-name v))
     (format "function ~a() { [native code] }" (if (symbol? name) name ""))]
    [(symbol? v) (format "Symbol(~a)" v)]
    [(date? v) (date->js-string v)]
    [(regexp-value? v) (format "/~a/" (object-name v))]
    [(bytes? v) "[object ArrayBuffer]"]
    [else (format "~a" v)]))

;; ---------------------------------------------------------------------------------------------
;; JSON.stringify(v)

(define json-absent (string->uninterned-symbol "absent"))
(define (json-absent? v) (eq? v json-absent))

;; The jvalue `JSON.parse(JSON.stringify(v))` yields, or a value satisfying `json-absent?`
;; where `JSON.stringify` yields `undefined`.
(define (js-json-value v)
  (define shaped (json-shape v))
  (if (json-absent? shaped)
      shaped
      (string->jvalue (jvalue->string shaped))))

;; `JSON.stringify(v)` as text; "undefined" where it yields `undefined`.
(define (js-json-text v)
  (define shaped (json-shape v))
  (if (json-absent? shaped)
      "undefined"
      (jvalue->string shaped)))

;; A jvalue with what `JSON.stringify` drops removed.
(define (json-shape v)
  (cond
    [(or (string? v) (boolean? v) (eq? v 'null)) v]
    [(real? v) (if (rational? v) v 'null)]
    [(or (void? v) (procedure? v) (symbol? v)) json-absent]
    [(list? v)
     (for/list ([item (in-list v)])
       (define shaped (json-shape item))
       (if (json-absent? shaped) 'null shaped))]
    [(or (jobject? v) (hash? v))
     (make-jobject
      (for*/list ([(key item) (in-jobject (->object v))]
                  [shaped (in-value (json-shape item))]
                  #:unless (json-absent? shaped))
        (cons key shaped)))]
    [(date? v) (date->iso-string v)]
    [else empty-jobject]))

;; ---------------------------------------------------------------------------------------------
;; Numbers

;; The double a JavaScript number operation sees. 'null is 0, as in `data > null`; anything
;; else that is not a number is NaN.
(define (js-number v)
  (cond
    [(real? v) (real->double-flonum v)]
    [(eq? v 'null) 0.0]
    [else +nan.0]))

;; Whether JavaScript's `x % y === 0` for doubles `x` and `y`. The remainder of two finite
;; doubles is exact, so exact arithmetic decides it.
(define (js-remainder-zero? x y)
  (cond
    [(or (nan? x) (nan? y) (infinite? x) (zero? y)) #f]
    [(infinite? y) (zero? x)]
    [else (integer? (/ (inexact->exact x) (inexact->exact y)))]))

;; ECMAScript ToInt32.
(define (js-int32 v)
  (define x (js-number v))
  (cond
    [(or (nan? x) (infinite? x)) 0]
    [else
     (define n (modulo (truncate (inexact->exact x)) 4294967296))
     (if (>= n 2147483648) (- n 4294967296) n)]))

;; ---------------------------------------------------------------------------------------------
;; Regular expressions

(define canonical-flags "dgimsuvy")

;; The flags in the order `RegExp.prototype.flags` prints them; raises `exn:fail:contract` for
;; an unknown or repeated flag, as `new RegExp` throws.
(define (js-regexp-flags flags)
  (define chars (string->list flags))
  (unless (and (for/and ([c (in-list chars)]) (memv c (string->list canonical-flags)))
               (not (check-duplicates chars)))
    (raise (make-exn:fail:contract
            (format "Invalid flags supplied to RegExp constructor '~a'" flags)
            (current-continuation-marks))))
  (list->string (for/list ([c (in-string canonical-flags)] #:when (memv c chars)) c)))

;; `new RegExp(source).source`: the empty pattern prints as (?:), and a slash outside a class
;; and a line break are escaped.
(define (js-regexp-source source)
  (cond
    [(string=? source "") "(?:)"]
    [else
     (define out (open-output-string))
     (let loop ([i 0] [in-class? #f])
       (when (< i (string-length source))
         (define c (string-ref source i))
         (cond
           [(and (char=? c #\\) (< (+ i 1) (string-length source)))
            (write-char c out)
            (write-char (string-ref source (+ i 1)) out)
            (loop (+ i 2) in-class?)]
           [(and (char=? c #\/) (not in-class?)) (write-string "\\/" out) (loop (+ i 1) #f)]
           [(char=? c #\newline) (write-string "\\n" out) (loop (+ i 1) in-class?)]
           [(char=? c #\return) (write-string "\\r" out) (loop (+ i 1) in-class?)]
           [(char=? c #\[) (write-char c out) (loop (+ i 1) #t)]
           [(char=? c #\]) (write-char c out) (loop (+ i 1) #f)]
           [else (write-char c out) (loop (+ i 1) in-class?)])))
     (get-output-string out)]))

;; `String(new RegExp(source, flags))`.
(define (js-regexp-text source flags)
  (format "/~a/~a" (js-regexp-source source) (js-regexp-flags flags)))

;; What JavaScript's \s matches.
(define js-space-chars
  (string-append "\t\n\v\f\r    -     　﻿"))

(define (hex-char? c)
  (and (char? c) (or (char-numeric? c) (memv (char-downcase c) '(#\a #\b #\c #\d #\e #\f)))))

;; js-regexp : string? string? -> regexp?
;; A Racket regexp that matches what `new RegExp(source, flags).test(str)` accepts. Raises
;; `exn:fail:contract` for flags JavaScript rejects and for a source that does not translate.
(define (js-regexp source flags)
  (define normal-flags (js-regexp-flags flags))
  (define (flag? c) (and (memv c (string->list normal-flags)) #t))
  (define length (string-length source))
  (define (peek i) (and (< i length) (string-ref source i)))
  (define (invalid why)
    (raise (make-exn:fail:contract
            (format "Invalid regular expression: /~a/~a: ~a" source normal-flags why)
            (current-continuation-marks))))

  ;; The index of the first `target` at or after `from`, or #f.
  (define (find-char target from)
    (for/first ([i (in-range from length)] #:when (char=? (string-ref source i) target)) i))

  ;; Names of the capturing groups, in the order their parentheses open; #f for unnamed ones.
  (define group-names
    (let loop ([i 0] [in-class? #f] [names '()])
      (define c (peek i))
      (cond
        [(not c) (reverse names)]
        [(char=? c #\\) (loop (+ i 2) in-class? names)]
        [in-class? (loop (+ i 1) (not (char=? c #\])) names)]
        [(char=? c #\[) (loop (+ i 1) #t names)]
        [(char=? c #\()
         (cond
           [(not (eqv? (peek (+ i 1)) #\?)) (loop (+ i 1) #f (cons #f names))]
           [(and (eqv? (peek (+ i 2)) #\<) (not (memv (peek (+ i 3)) '(#\= #\!))))
            (define close (or (find-char #\> (+ i 3)) (invalid "Invalid capture group name")))
            (loop (+ close 1) #f (cons (substring source (+ i 3) close) names))]
           [else (loop (+ i 1) #f names)])]
        [else (loop (+ i 1) #f names)])))

  (define out (open-output-string))
  (define (emit text) (write-string text out))
  ;; A literal character, escaped where the pregexp syntax gives it a meaning.
  (define (literal c in-class?)
    (define special (if in-class? "\\]^-[" "\\.[]{}()*+?^$|"))
    (when (for/or ([s (in-string special)]) (char=? s c)) (emit "\\"))
    (emit (string c)))

  ;; Translates the escape whose backslash is at `i`; returns the index after it.
  (define (escape i in-class?)
    (define c (or (peek (+ i 1)) (invalid "\\ at end of pattern")))
    (define (hex from count)
      (define digits (and (<= (+ from count) length) (substring source from (+ from count))))
      (and digits
           (for/and ([d (in-string digits)]) (hex-char? d))
           (string->number digits 16)))
    (define (code-point n next)
      (literal (integer->char n) in-class?)
      next)
    (case c
      [(#\d #\D #\w #\W) (emit (string #\\ c)) (+ i 2)]
      [(#\s) (emit (if in-class? js-space-chars (string-append "[" js-space-chars "]"))) (+ i 2)]
      [(#\S)
       (emit (if in-class? "\\S" (string-append "[^" js-space-chars "]")))
       (+ i 2)]
      [(#\b) (if in-class? (literal #\backspace #t) (emit "\\b")) (+ i 2)]
      [(#\B) (if in-class? (literal #\B #t) (emit "\\B")) (+ i 2)]
      [(#\t) (literal #\tab in-class?) (+ i 2)]
      [(#\n) (literal #\newline in-class?) (+ i 2)]
      [(#\r) (literal #\return in-class?) (+ i 2)]
      [(#\f) (literal #\page in-class?) (+ i 2)]
      [(#\v) (literal #\vtab in-class?) (+ i 2)]
      [(#\0) (literal #\nul in-class?) (+ i 2)]
      [(#\x)
       (define n (hex (+ i 2) 2))
       (if n (code-point n (+ i 4)) (begin (literal #\x in-class?) (+ i 2)))]
      [(#\u)
       (cond
         [(eqv? (peek (+ i 2)) #\{)
          (define close (or (find-char #\} (+ i 3)) (invalid "Invalid Unicode escape")))
          (define n (string->number (substring source (+ i 3) close) 16))
          (unless (and n (<= n #x10FFFF)) (invalid "Invalid Unicode escape"))
          (code-point n (+ close 1))]
         [(hex (+ i 2) 4) => (lambda (n) (code-point n (+ i 6)))]
         [else (literal #\u in-class?) (+ i 2)])]
      [(#\c)
       (define letter (peek (+ i 2)))
       (if (and letter (char-alphabetic? letter))
           (code-point (modulo (char->integer letter) 32) (+ i 3))
           (begin (literal #\\ in-class?) (+ i 1)))]
      [(#\k)
       (cond
         [(and (not in-class?) (eqv? (peek (+ i 2)) #\<))
          (define close (or (find-char #\> (+ i 3)) (invalid "Invalid named reference")))
          (define index (index-of group-names (substring source (+ i 3) close)))
          (unless index (invalid "Invalid named capture referenced"))
          (emit (format "\\~a" (+ index 1)))
          (+ close 1)]
         [else (literal #\k in-class?) (+ i 2)])]
      [(#\p #\P)
       (define close (and (eqv? (peek (+ i 2)) #\{) (find-char #\} (+ i 3))))
       (cond
         [close (emit (substring source i (+ close 1))) (+ close 1)]
         [else (literal c in-class?) (+ i 2)])]
      [else
       (cond
         [(and (char-numeric? c) (not in-class?)) (emit (string #\\ c)) (+ i 2)]
         [else (literal c in-class?) (+ i 2)])]))

  ;; Translates the class that opens at `i`; returns the index after its closing bracket.
  (define (class i)
    (define negated? (eqv? (peek (+ i 1)) #\^))
    (define start (if negated? (+ i 2) (+ i 1)))
    (cond
      [(eqv? (peek start) #\])
       ;; [] matches nothing and [^] matches any character.
       (emit (if negated? "(?s:.)" "(?:(?!x)x)"))
       (+ start 1)]
      [else
       (emit (if negated? "[^" "["))
       (let loop ([j start])
         (define c (or (peek j) (invalid "Unterminated character class")))
         (cond
           [(char=? c #\]) (emit "]") (+ j 1)]
           [(char=? c #\\) (loop (escape j #t))]
           [(char=? c #\-) (emit "-") (loop (+ j 1))]
           [else (literal c #t) (loop (+ j 1))]))]))

  (let loop ([i 0])
    (define c (peek i))
    (when c
      (case c
        [(#\\) (loop (escape i #f))]
        [(#\[) (loop (class i))]
        [(#\.)
         (emit (if (flag? #\s) "(?s:.)" "[^\n\r  ]"))
         (loop (+ i 1))]
        [(#\()
         (cond
           [(and (eqv? (peek (+ i 1)) #\?)
                 (eqv? (peek (+ i 2)) #\<)
                 (not (memv (peek (+ i 3)) '(#\= #\!))))
            (emit "(")
            (loop (+ (find-char #\> (+ i 3)) 1))]
           [else (emit "(") (loop (+ i 1))])]
        [(#\{)
         (define quantifier (regexp-match #px"^\\{[0-9]+(?:,[0-9]*)?\\}" source i))
         (cond
           [quantifier (emit (car quantifier)) (loop (+ i (string-length (car quantifier))))]
           [else (emit "\\{") (loop (+ i 1))])]
        [(#\} #\]) (emit (string #\\ c)) (loop (+ i 1))]
        [else (emit (string c)) (loop (+ i 1))])))

  (define body (get-output-string out))
  (define with-case (if (flag? #\i) (format "(?i:~a)" body) (format "(?:~a)" body)))
  (define with-lines (if (flag? #\m) (format "(?m:~a)" with-case) with-case))
  (define anchored (if (flag? #\y) (string-append "^" with-lines) with-lines))
  (with-handlers ([exn:fail:contract? (lambda (e) (invalid "unsupported pattern"))])
    (pregexp anchored)))

;; ---------------------------------------------------------------------------------------------
;; Dates

(define (days-from-civil year month day)
  ;; Days since 1970-01-01 in the proleptic Gregorian calendar.
  (define y (if (<= month 2) (- year 1) year))
  (define era (floor (/ y 400)))
  (define yoe (- y (* era 400)))
  (define doy (+ (quotient (+ (* 153 (+ month (if (> month 2) -3 9))) 2) 5) (- day 1)))
  (define doe (+ (* yoe 365) (quotient yoe 4) (- (quotient yoe 100)) doy))
  (+ (* era 146097) doe -719468))

(define iso-pattern
  (pregexp
   (string-append
    "^([+-][0-9]{6}|[0-9]{4})(?:-([0-9]{2})(?:-([0-9]{2}))?)?"
    "(?:T([0-9]{2}):([0-9]{2})(?::([0-9]{2})(?:[.]([0-9]{1,9}))?)?"
    "(Z|[+-][0-9]{2}:[0-9]{2})?)?$")))

;; iso-string->date : string? -> (or/c date*? #f)
;; Parses the ECMAScript date-time string format into a UTC date, or #f. A date without a time
;; is UTC; a date and time without an offset is local time.
(define (iso-string->date text)
  (define parts (regexp-match iso-pattern text))
  (and
   parts
   (let* ([number (lambda (i default) (if (list-ref parts i) (string->number (list-ref parts i)) default))]
          [year (number 1 0)]
          [month (number 2 1)]
          [day (number 3 1)]
          [hour (number 4 0)]
          [minute (number 5 0)]
          [second (number 6 0)]
          [fraction (list-ref parts 7)]
          [millis (if fraction
                      (floor (* 1000 (/ (string->number fraction) (expt 10 (string-length fraction)))))
                      0)]
          [zone (list-ref parts 8)]
          [has-time? (and (list-ref parts 4) #t)])
     (and (<= 1 month 12)
          (<= 1 day 31)
          (or (<= hour 23) (and (= hour 24) (= minute 0) (= second 0) (= millis 0)))
          (<= minute 59)
          (<= second 59)
          (let* ([local-seconds (+ (* 86400 (days-from-civil year month day))
                                   (* 3600 hour) (* 60 minute) second)]
                 [offset
                  (cond
                    [(not has-time?) 0]
                    [(not zone) (local-offset year month day hour minute second)]
                    [(string=? zone "Z") 0]
                    [else
                     (* (if (char=? (string-ref zone 0) #\-) -1 1)
                        (+ (* 3600 (string->number (substring zone 1 3)))
                           (* 60 (string->number (substring zone 4 6)))))])])
            (and offset
                 (seconds->date (+ (- local-seconds offset) (/ millis 1000)) #f)))))))

;; The offset of local time from UTC, in seconds, at the given local wall-clock time, or #f
;; when the platform cannot represent that time.
(define (local-offset year month day hour minute second)
  (with-handlers ([exn:fail? (lambda (e) #f)]) ; find-seconds rejects times the platform lacks
    (date-time-zone-offset
     (seconds->date (find-seconds second minute hour day month year #t) #t))))

;; Milliseconds since the epoch.
(define (date->milliseconds d)
  (define nanoseconds (if (date*? d) (date*-nanosecond d) 0))
  (+ (* 1000 (- (+ (* 86400 (days-from-civil (date-year d) (date-month d) (date-day d)))
                   (* 3600 (date-hour d))
                   (* 60 (date-minute d))
                   (date-second d))
                (date-time-zone-offset d)))
     (quotient nanoseconds 1000000)))

(define (pad n width)
  (define text (number->string n))
  (string-append (make-string (max 0 (- width (string-length text))) #\0) text))

;; The UTC date at `ms` milliseconds since the epoch.
(define (utc-date ms)
  (seconds->date (/ ms 1000) #f))

;; `Date.prototype.toISOString`.
(define (date->iso-string d)
  (define ms (date->milliseconds d))
  (define utc (utc-date ms))
  (define year (date-year utc))
  (format "~a-~a-~aT~a:~a:~a.~aZ"
          (if (<= 0 year 9999)
              (pad year 4)
              (string-append (if (negative? year) "-" "+") (pad (abs year) 6)))
          (pad (date-month utc) 2)
          (pad (date-day utc) 2)
          (pad (date-hour utc) 2)
          (pad (date-minute utc) 2)
          (pad (date-second utc) 2)
          (pad (modulo ms 1000) 3)))

;; `String(date)` as a process whose time zone is UTC prints it.
(define (date->js-string d)
  (define utc (utc-date (date->milliseconds d)))
  (format "~a ~a ~a ~a ~a:~a:~a GMT+0000 (Coordinated Universal Time)"
          (list-ref '("Sun" "Mon" "Tue" "Wed" "Thu" "Fri" "Sat") (date-week-day utc))
          (list-ref '("Jan" "Feb" "Mar" "Apr" "May" "Jun" "Jul" "Aug" "Sep" "Oct" "Nov" "Dec")
                    (- (date-month utc) 1))
          (pad (date-day utc) 2)
          (pad (date-year utc) 4)
          (pad (date-hour utc) 2)
          (pad (date-minute utc) 2)
          (pad (date-second utc) 2)))

;; ---------------------------------------------------------------------------------------------
;; Binary text

;; `Buffer.from(text, 'hex')`: whole byte pairs up to the first character that is not a hex
;; digit.
(define (bytes-from-hex text)
  (define out (open-output-bytes))
  (let loop ([i 0])
    (when (and (< (+ i 1) (string-length text))
               (hex-char? (string-ref text i))
               (hex-char? (string-ref text (+ i 1))))
      (write-byte (string->number (substring text i (+ i 2)) 16) out)
      (loop (+ i 2))))
  (get-output-bytes out))

(define (base64-value c)
  (cond
    [(char<=? #\A c #\Z) (- (char->integer c) 65)]
    [(char<=? #\a c #\z) (+ 26 (- (char->integer c) 97))]
    [(char<=? #\0 c #\9) (+ 52 (- (char->integer c) 48))]
    [(memv c '(#\+ #\-)) 62]
    [(memv c '(#\/ #\_)) 63]
    [else #f]))

;; `Buffer.from(text, 'base64')`: both alphabets, characters outside them skipped, decoding
;; stopped at the first padding character.
(define (bytes-from-base64 text)
  (define sextets
    (for/list ([c (in-string text)]
               #:break (char=? c #\=)
               #:when (base64-value c))
      (base64-value c)))
  (define out (open-output-bytes))
  (let loop ([rest sextets])
    (cond
      [(and (pair? rest) (pair? (cdr rest)))
       (define a (car rest))
       (define b (cadr rest))
       (write-byte (bitwise-ior (arithmetic-shift a 2) (arithmetic-shift b -4)) out)
       (define more (cddr rest))
       (when (pair? more)
         (define c (car more))
         (write-byte (bitwise-and 255 (bitwise-ior (arithmetic-shift b 4) (arithmetic-shift c -2)))
                     out)
         (when (pair? (cdr more))
           (write-byte (bitwise-and 255 (bitwise-ior (arithmetic-shift c 6) (cadr more))) out)
           (loop (cddr more))))]
      [else (void)]))
  (get-output-bytes out))
