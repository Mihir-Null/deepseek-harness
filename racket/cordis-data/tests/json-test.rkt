#lang racket/base
;; Tests for section 2 of docs/racket/contracts/cordis-data.md: reading JSON text as
;; `JSON.parse` does and writing it as `JSON.stringify` does. The row-by-row comparison with
;; Node is in node-table-test.rkt; these tests pin each rule of the contract by hand.

(require rackunit
         racket/port
         cordis-data)

;; A string of the given code points; keeps this file ASCII.
(define (chars . codes)
  (apply string (map integer->char codes)))

(define e-acute (chars #xE9))
(define grinning-face (chars #x1F600))
(define replacement (chars #xFFFD))

;; The position an `exn:fail:json` reports for `thunk`, or the value it returned.
(define (error-position thunk)
  (with-handlers ([exn:fail:json? exn:fail:json-position])
    (thunk)))

;; ---------------------------------------------------------------------------------------------
;; Reading

(test-case "the reader keeps key order, also in nested objects"
  (define doc (string->jvalue "{\"b\":1,\"a\":[true,false,null],\"c\":{\"z\":1,\"y\":2}}"))
  (check-true (jobject? doc))
  (check-equal? (jkeys doc) '(b a c))
  (check-equal? (jref doc 'a) '(#t #f null))
  (check-equal? (jkeys (jref doc 'c)) '(z y)))

(test-case "a duplicate key keeps the last value at the first position"
  (check-equal? (jobject->alist (string->jvalue "{\"a\":1,\"b\":2,\"a\":3}")) '((a . 3) (b . 2)))
  (check-equal? (jobject->alist (string->jvalue "{\"a\":1,\"a\":{\"x\":1},\"a\":[]}")) '((a . ()))))

(test-case "numbers without fraction or exponent are exact integers, all others flonums"
  (define (reads-as text expected)
    (define value (string->jvalue text))
    (check-true (eqv? value expected) (format "~a read as ~s" text value)))
  (reads-as "0" 0)
  (reads-as "1" 1)
  (reads-as "-5" -5)
  (reads-as "1234567890123456789" 1234567890123456789)
  (reads-as "123456789012345678901234567890" 123456789012345678901234567890)
  (reads-as "-123456789012345678901234567890" -123456789012345678901234567890)
  (reads-as "1.0" 1.0)
  (reads-as "1e3" 1000.0)
  (reads-as "1E3" 1000.0)
  (reads-as "1e+3" 1000.0)
  (reads-as "1.5e-3" 0.0015)
  (reads-as "0.1" 0.1)
  (reads-as "0.0" 0.0)
  (reads-as "-0" -0.0)
  (reads-as "-0.0" -0.0)
  (reads-as "-0e5" -0.0)
  (reads-as "4.9e-324" 5e-324)
  (reads-as "1.7976931348623157e308" 1.7976931348623157e308)
  (reads-as "1e400" +inf.0)
  (reads-as "-1e400" -inf.0)
  (reads-as "1e-400" 0.0)
  (reads-as "123456789012345678901234567890.0" 1.2345678901234568e29)
  (reads-as "0.1000000000000000055511151231257827021181583404541015625" 0.1)
  (reads-as "9007199254740993.0" 9007199254740992.0)
  (reads-as "1e99999999999999999999" +inf.0)
  (reads-as "1e-99999999999999999999" 0.0)
  (reads-as "0e99999999999999999999" 0.0))

(test-case "decimal texts of any length round to the nearest double, ties to even"
  ;; Exactly halfway between 1 and the next double.
  (define midpoint "1.00000000000000011102230246251565404236316680908203125")
  (check-eqv? (string->jvalue midpoint) 1.0)
  (check-eqv? (string->jvalue (string-append midpoint "1")) 1.0000000000000002)
  (check-eqv? (string->jvalue (string-append midpoint (make-string 2000 #\0))) 1.0)
  (check-eqv? (string->jvalue (string-append midpoint (make-string 2000 #\0) "1"))
              1.0000000000000002)
  ;; Halfway between the next two doubles, where the even neighbour is the upper one.
  (check-eqv? (string->jvalue "1.00000000000000033306690738754696212708950042724609375")
              1.0000000000000004)
  (check-eqv? (string->jvalue (string-append "0." (make-string 5000 #\0) "1")) 0.0)
  (check-eqv? (string->jvalue (string-append "0." (make-string 5000 #\0) "1e5001")) 1.0)
  (check-eqv? (string->jvalue (string-append "1" (make-string 5000 #\0) "e-5000")) 1.0)
  (check-eqv? (string->jvalue (string-append "1" (make-string 400 #\0) ".0")) +inf.0)
  (check-eqv? (string->jvalue (string-append "0." (make-string 3000 #\7))) 0.7777777777777778)
  (check-eqv? (string->jvalue (string-append (make-string 30 #\9) ".5")) 1e30))

(test-case "whitespace is space, tab, line feed and carriage return only"
  (check-equal? (string->jvalue " \t\n\r[ 1 ,\n2 ]\r\n") '(1 2))
  (check-equal? (string->jvalue "{ \"a\" : 1 , \"b\" : [ ] }") (jobject 'a 1 'b '()))
  (check-exn exn:fail:json? (lambda () (string->jvalue (string-append (chars #xA0) "1"))))
  (check-exn exn:fail:json? (lambda () (string->jvalue (string-append (chars #xFEFF) "1"))))
  (check-exn exn:fail:json? (lambda () (string->jvalue (string-append "1" (chars #x0C))))))

(test-case "string escapes"
  (check-equal? (string->jvalue "\"a\\\"b\\\\c\\/d\\be\\ff\\ng\\rh\\ti\"")
                (string-append "a\"b\\c/d" (chars 8) "e" (chars 12) "f\ng\rh\ti"))
  (check-equal? (string->jvalue "\"\\u0041\\u00e9\\u00E9\"") (string-append "A" e-acute e-acute))
  (check-equal? (string->jvalue "\"\\ud83d\\ude00\"") grinning-face)
  (check-equal? (string->jvalue "\"\\uD83D\\uDE00!\"") (string-append grinning-face "!"))
  (check-equal? (string->jvalue (string-append "\"" grinning-face e-acute "\""))
                (string-append grinning-face e-acute))
  (check-equal? (string->jvalue "\"\\u0000\"") (chars 0))
  (check-equal? (string->jvalue "\"\"") "")
  (check-equal? (jkeys (string->jvalue "{\"a\\nb\":1,\"\\u00e9\":2,\"\":3}"))
                (list (string->symbol "a\nb") (string->symbol e-acute) (string->symbol ""))))

(test-case "an escaped lone surrogate becomes U+FFFD"
  (check-equal? (string->jvalue "\"\\ud800\"") replacement)
  (check-equal? (string->jvalue "\"\\udc00\"") replacement)
  (check-equal? (string->jvalue "\"a\\ud83dz\"") (string-append "a" replacement "z"))
  (check-equal? (string->jvalue "\"\\ud83d\\u0041\"") (string-append replacement "A"))
  (check-equal? (string->jvalue "\"\\ud83d\\ud83d\\ude00\"")
                (string-append replacement grinning-face))
  (check-equal? (string->jvalue "\"\\ude00\\ud83d\"") (string-append replacement replacement))
  (check-equal? (string->jvalue "\"\\ud83d\\n\"") (string-append replacement "\n")))

(test-case "syntax errors raise exn:fail:json with the character position"
  (define (position-of text)
    (error-position (lambda () (string->jvalue text))))
  (check-equal? (position-of "") 0)
  (check-equal? (position-of "   ") 3)
  (check-equal? (position-of "[1,]") 3)
  (check-equal? (position-of "[1 2]") 3)
  (check-equal? (position-of "{\"a\":1") 6)
  (check-equal? (position-of "{\"a\" 1}") 5)
  (check-equal? (position-of "{a:1}") 1)
  (check-equal? (position-of "{\"a\":1,}") 7)
  (check-equal? (position-of "tru") 3)
  (check-equal? (position-of "nulL") 3)
  (check-equal? (position-of "[1] x") 4)
  (check-equal? (position-of "1 2") 2)
  (check-equal? (position-of "01") 1)
  (check-equal? (position-of "-") 1)
  (check-equal? (position-of "-x") 1)
  (check-equal? (position-of "1.") 2)
  (check-equal? (position-of "1.e3") 2)
  (check-equal? (position-of ".5") 0)
  (check-equal? (position-of "+1") 0)
  (check-equal? (position-of "1e") 2)
  (check-equal? (position-of "1e+") 3)
  (check-equal? (position-of "\"abc") 4)
  (check-equal? (position-of "\"a\nb\"") 2)
  (check-equal? (position-of "\"a\\qb\"") 3)
  (check-equal? (position-of "\"\\u12g4\"") 2)
  (check-equal? (position-of "\"\\u12\"") 2)
  (check-equal? (position-of "\"\\") 2)
  (check-equal? (position-of "'a'") 0)
  (check-equal? (position-of "NaN") 0)
  (check-equal? (position-of "[1,2") 4)
  ;; The position counts characters, not UTF-16 units or bytes.
  (check-equal? (position-of (string-append "[\"" grinning-face e-acute "\" x]")) 6))

(test-case "exn:fail:json is an exn:fail that names the caller"
  (define raised
    (with-handlers ([exn:fail:json? values])
      (string->jvalue "[1,]")))
  (check-true (exn:fail? raised))
  (check-false (exn:fail:contract? raised))
  (check-equal? (exn:fail:json-position raised) 3)
  (check-regexp-match #rx"^string->jvalue: .* at position 3$" (exn-message raised))
  (define named
    (with-handlers ([exn:fail:json? values])
      (string->jvalue "{" #:who 'load-settings)))
  (check-regexp-match #rx"^load-settings: " (exn-message named))
  (check-exn exn:fail:contract? (lambda () (string->jvalue 5)))
  (check-exn exn:fail:contract? (lambda () (string->jvalue #"1")))
  (check-exn exn:fail:contract? (lambda () (string->jvalue "1" #:who "me"))))

(test-case "bytes->jvalue decodes UTF-8 as JavaScript does"
  (check-equal? (bytes->jvalue #"{\"k\":[1,2.5,\"x\"]}") (jobject 'k (list 1 2.5 "x")))
  (define accented (string-append e-acute grinning-face))
  (check-equal? (bytes->jvalue (string->bytes/utf-8 (string-append "[\"" accented "\"]")))
                (list accented))
  ;; An invalid byte, and a sequence cut short, each decode to one U+FFFD.
  (check-equal? (bytes->jvalue #"\"a\377b\"") (string-append "a" replacement "b"))
  (check-equal? (bytes->jvalue #"\"\342\202\"") replacement)
  (check-equal? (bytes->jvalue #"\"\342\202A\"") (string-append replacement "A"))
  ;; A byte order mark is not whitespace.
  (check-equal? (error-position (lambda () (bytes->jvalue #"\357\273\2771"))) 0)
  (check-equal? (error-position (lambda () (bytes->jvalue #"[1,,2]"))) 3)
  (check-exn exn:fail:contract? (lambda () (bytes->jvalue "1"))))

(test-case "read-jvalue reads one value at a time and then eof"
  (define in (open-input-string " {\"a\":1}\n[2,[3]] \"x\" 4.5 true null\n12 "))
  (check-equal? (read-jvalue in) (jobject 'a 1))
  ;; The port is left just after the value.
  (check-equal? (peek-char in) #\newline)
  (check-equal? (read-jvalue in) '(2 (3)))
  (check-equal? (read-jvalue in) "x")
  (check-equal? (read-jvalue in) 4.5)
  (check-equal? (read-jvalue in) #t)
  (check-equal? (read-jvalue in) 'null)
  (check-equal? (read-jvalue in) 12)
  (check-true (eof-object? (read-jvalue in)))
  (check-true (eof-object? (read-jvalue in)))
  (check-true (eof-object? (read-jvalue (open-input-string ""))))
  (check-true (eof-object? (read-jvalue (open-input-string " \n\t\r "))))
  (check-exn exn:fail:contract? (lambda () (read-jvalue "1"))))

(test-case "read-jvalue separates adjacent values"
  (define in (open-input-string "[1][2]\"a\"\"b\"{}{\"k\":\"}]\\\"\"}7"))
  (check-equal? (for/list ([value (in-port read-jvalue in)]) value)
                (list '(1) '(2) "a" "b" empty-jobject (jobject 'k "}]\"") 7)))

(test-case "read-jvalue uses the current input port by default"
  (check-equal? (parameterize ([current-input-port (open-input-string "[1,2] 3")])
                  (list (read-jvalue) (read-jvalue) (read-jvalue)))
                (list '(1 2) 3 eof)))

(test-case "read-jvalue reads values larger than its buffer"
  (define strings
    (for/list ([i (in-range 3000)])
      (string-append (number->string i) grinning-face e-acute "\"]}\\")))
  (define doc (jobject 'items strings 'count 3000))
  (define text (jvalue->string doc))
  (check-true (> (string-length text) 20000))
  (define in (open-input-bytes (bytes-append (string->bytes/utf-8 text) #" 99")))
  (check-equal? (read-jvalue in) doc)
  (check-equal? (jkeys (read-jvalue (open-input-string text))) '(items count))
  (check-equal? (read-jvalue in) 99)
  (check-true (eof-object? (read-jvalue in)))
  (define long-number (make-string 9000 #\7))
  (check-equal? (read-jvalue (open-input-string (string-append long-number " 1")))
                (string->number long-number)))

(test-case "read-jvalue returns a bracketed value without waiting for what follows"
  (define-values (in out) (make-pipe))
  (write-string "{\"a\":[1,2]} " out)
  (flush-output out)
  (define result (make-channel))
  (define reader (thread (lambda () (channel-put result (read-jvalue in)))))
  (check-equal? (sync/timeout 10 result) (jobject 'a '(1 2)))
  (close-output-port out)
  (check-true (eof-object? (read-jvalue in)))
  (check-false (thread-running? reader)))

(test-case "read-jvalue reports errors by position and moves past the malformed text"
  (check-equal? (error-position (lambda () (read-jvalue (open-input-string "  [1,]")))) 5)
  (check-equal? (error-position (lambda () (read-jvalue (open-input-string "{\"a\":")))) 5)
  (define in (open-input-string "12] tru 5"))
  (check-equal? (read-jvalue in) 12)
  (check-exn exn:fail:json? (lambda () (read-jvalue in)))
  (check-exn exn:fail:json? (lambda () (read-jvalue in)))
  (check-equal? (read-jvalue in) 5)
  (check-true (eof-object? (read-jvalue in)))
  ;; Text that runs two tokens together is one malformed value, not two values.
  (check-exn exn:fail:json? (lambda () (read-jvalue (open-input-string "1true"))))
  (check-exn exn:fail:json? (lambda () (read-jvalue (open-input-string "nullnull")))))

(test-case "deeply nested text is read and written"
  (define depth 20000)
  (define text (string-append (make-string depth #\[) (make-string depth #\])))
  (define value (string->jvalue text))
  (check-equal? (jvalue->string value) text)
  (check-equal? (let loop ([v value] [n 0]) (if (null? v) n (loop (car v) (add1 n)))) (sub1 depth)))

;; ---------------------------------------------------------------------------------------------
;; Writing

(test-case "key order survives read, update and write"
  (define text "{\"zeta\":1,\"alpha\":{\"y\":true,\"x\":null},\"mid\":[]}")
  (define doc (string->jvalue text))
  (check-equal? (jvalue->string doc) text)
  (define updated (jset (jset (jremove doc 'mid) 'alpha 2) 'new "n"))
  (check-equal? (jvalue->string updated) "{\"zeta\":1,\"alpha\":2,\"new\":\"n\"}")
  (check-equal? (jvalue->string (jset* doc '(alpha w) 0))
                "{\"zeta\":1,\"alpha\":{\"y\":true,\"x\":null,\"w\":0},\"mid\":[]}")
  (check-equal? (jvalue->string (jmerge doc (jobject 'alpha 'null 'omega 9)))
                "{\"zeta\":1,\"alpha\":null,\"mid\":[],\"omega\":9}"))

(test-case "numbers are written by Number::toString"
  (define (writes-as value expected)
    (check-equal? (jvalue->string value) expected))
  (writes-as 0 "0")
  (writes-as 42 "42")
  (writes-as -7 "-7")
  (writes-as 1.0 "1")
  (writes-as -1.0 "-1")
  (writes-as 0.0 "0")
  (writes-as -0.0 "0")
  (writes-as 100.0 "100")
  (writes-as 1.5 "1.5")
  (writes-as 0.1 "0.1")
  (writes-as 0.30000000000000004 "0.30000000000000004")
  (writes-as 1e20 "100000000000000000000")
  (writes-as 123456789012345680000.0 "123456789012345680000")
  (writes-as 1e21 "1e+21")
  (writes-as -1e21 "-1e+21")
  (writes-as 1.5e300 "1.5e+300")
  (writes-as 0.000001 "0.000001")
  (writes-as 0.00000123 "0.00000123")
  (writes-as 1e-7 "1e-7")
  (writes-as 1.5e-7 "1.5e-7")
  (writes-as -1e-7 "-1e-7")
  (writes-as 5e-324 "5e-324")
  (writes-as 1.7976931348623157e308 "1.7976931348623157e+308")
  (writes-as 9007199254740992 "9007199254740992")
  ;; An exact integer beyond 2^53 is written as the double JavaScript would hold.
  (writes-as 9007199254740993 "9007199254740992")
  (writes-as (expt 2 64) "18446744073709552000")
  (writes-as (expt 10 21) "1e+21")
  (writes-as (- (expt 10 22)) "-1e+22")
  (writes-as (expt 10 400) "null")
  ;; Exact rationals are converted to flonums first.
  (writes-as 1/2 "0.5")
  (writes-as 1/3 "0.3333333333333333")
  (writes-as -22/7 "-3.142857142857143")
  (writes-as 1/10000000 "1e-7")
  ;; Ties between two shortest candidates go to the even digit, as in JavaScript.
  (writes-as 88.114288330078125 "88.11428833007812")
  (writes-as -1063617249360974.25 "-1063617249360974.2")
  (writes-as +nan.0 "null")
  (writes-as +inf.0 "null")
  (writes-as -inf.0 "null")
  (writes-as (list 1.0 +nan.0 (jobject 'x -inf.0)) "[1,null,{\"x\":null}]"))

(test-case "number texts round-trip through read and write"
  (for ([text (in-list '("0" "1" "-1" "1.5" "-0.5" "1e+21" "1e-7" "1.5e-7" "123456789012345680000"
                             "0.000001" "5e-324" "1.7976931348623157e+308" "0.30000000000000004"
                             "9007199254740992" "4.35" "100" "1.2345678901234568e+29"))])
    (check-equal? (jvalue->string (string->jvalue text)) text))
  ;; Spellings JavaScript normalises.
  (for ([(text normal) (in-hash (hash "1.0" "1" "1e3" "1000" "-0" "0" "1E2" "100" "0.10" "0.1"
                                      "1e21" "1e+21" "0.0000001" "1e-7" "100e-2" "1"
                                      "9007199254740993" "9007199254740992"
                                      "123456789012345678901234567890" "1.2345678901234568e+29"))])
    (check-equal? (jvalue->string (string->jvalue text)) normal text)))

(test-case "strings escape exactly what JSON.stringify escapes"
  (check-equal? (jvalue->string "plain") "\"plain\"")
  (check-equal? (jvalue->string "") "\"\"")
  (check-equal? (jvalue->string "a\"b\\c") "\"a\\\"b\\\\c\"")
  (check-equal? (jvalue->string (chars 8 12 10 13 9)) "\"\\b\\f\\n\\r\\t\"")
  (check-equal? (jvalue->string (chars 0 1 #x0B #x1A #x1F))
                "\"\\u0000\\u0001\\u000b\\u001a\\u001f\"")
  ;; Not escaped: the slash, DEL, non-ASCII, and the line and paragraph separators.
  (define untouched (string-append "/<>&'" (chars #x7F #xE9 #x4E2D #x2028 #x2029 #x1F600 #xFFFD)))
  (check-equal? (jvalue->string untouched) (string-append "\"" untouched "\""))
  (check-equal? (jvalue->string (jobject "k\"\n" 1 e-acute 2))
                (string-append "{\"k\\\"\\n\":1,\"" e-acute "\":2}"))
  (for ([code (in-range 32)])
    (define text (jvalue->string (chars code)))
    (check-equal? (string->jvalue text) (chars code))
    (check-true (for/and ([c (in-string text)]) (char>=? c #\space)))))

(define layout-sample
  (jobject 'a 1 'b (list 1 "two" (jobject 'c 'null)) 'empty-object (jobject) 'empty-array '()
           'nested (list '() (jobject) (list 1))))

(test-case "without an indent there is no whitespace at all"
  (check-equal? (jvalue->string layout-sample)
                (string-append "{\"a\":1,\"b\":[1,\"two\",{\"c\":null}],\"empty-object\":{},"
                               "\"empty-array\":[],\"nested\":[[],{},[1]]}"))
  (check-equal? (jvalue->string layout-sample #:indent #f) (jvalue->string layout-sample))
  (check-equal? (jvalue->string (jobject)) "{}")
  (check-equal? (jvalue->string '()) "[]")
  (check-equal? (jvalue->string (list #t #f 'null)) "[true,false,null]"))

(test-case "an indent lays the text out as JSON.stringify(v, null, n) does"
  (check-equal? (jvalue->string layout-sample #:indent 2)
                (string-append "{\n"
                               "  \"a\": 1,\n"
                               "  \"b\": [\n"
                               "    1,\n"
                               "    \"two\",\n"
                               "    {\n"
                               "      \"c\": null\n"
                               "    }\n"
                               "  ],\n"
                               "  \"empty-object\": {},\n"
                               "  \"empty-array\": [],\n"
                               "  \"nested\": [\n"
                               "    [],\n"
                               "    {},\n"
                               "    [\n"
                               "      1\n"
                               "    ]\n"
                               "  ]\n"
                               "}"))
  (check-equal? (jvalue->string (jobject 'k (list 1 2)) #:indent 1)
                "{\n \"k\": [\n  1,\n  2\n ]\n}")
  (check-equal? (jvalue->string (list (jobject 'k 1)) #:indent 4)
                "[\n    {\n        \"k\": 1\n    }\n]")
  (check-equal? (jvalue->string (list 1) #:indent 10) "[\n          1\n]")
  (check-equal? (jvalue->string (jobject) #:indent 2) "{}")
  (check-equal? (jvalue->string '() #:indent 2) "[]")
  (check-equal? (jvalue->string "x" #:indent 2) "\"x\"")
  (check-equal? (jvalue->string 1.0 #:indent 2) "1")
  (for ([indent (in-range 1 11)])
    (check-equal? (string->jvalue (jvalue->string layout-sample #:indent indent)) layout-sample)))

(test-case "the indent is #f or 1 to 10"
  (for ([bad (in-list (list 0 11 -1 2.0 "  " #t))])
    (check-exn exn:fail:contract? (lambda () (jvalue->string '(1) #:indent bad)))
    (check-exn exn:fail:contract? (lambda () (jvalue->bytes '(1) #:indent bad)))
    (check-exn exn:fail:contract?
               (lambda () (write-jvalue '(1) (open-output-string) #:indent bad)))))

(test-case "jvalue->bytes and write-jvalue produce the same text"
  (define doc (jobject 'name (string-append e-acute grinning-face) 'n (list 1 2.5)))
  (define text (jvalue->string doc))
  (check-equal? (jvalue->bytes doc) (string->bytes/utf-8 text))
  (check-equal? (jvalue->bytes doc #:indent 3)
                (string->bytes/utf-8 (jvalue->string doc #:indent 3)))
  (check-equal? (bytes->jvalue (jvalue->bytes doc)) doc)
  (define out (open-output-string))
  (check-true (void? (write-jvalue doc out)))
  (check-equal? (get-output-string out) text)
  (check-equal? (with-output-to-string (lambda () (write-jvalue doc))) text)
  (check-equal? (with-output-to-string (lambda () (write-jvalue doc #:indent 2)))
                (jvalue->string doc #:indent 2))
  (define byte-out (open-output-bytes))
  (write-jvalue doc byte-out #:indent 1)
  (check-equal? (get-output-bytes byte-out) (jvalue->bytes doc #:indent 1)))

(test-case "a hash is written as an object with its keys in symbol<? order"
  (check-equal? (jvalue->string (hash 'b 1 'a (hash "d" 2 "c" (list (hasheq 'z 0 'y 1)))))
                "{\"a\":{\"c\":[{\"y\":1,\"z\":0}],\"d\":2},\"b\":1}")
  (check-equal? (jvalue->string (jobject 'outer (make-hasheq '((k . "v")))))
                "{\"outer\":{\"k\":\"v\"}}"))

(test-case "a value that is not a jvalue raises exn:fail:contract"
  (for ([bad (in-list (list (void) 'symbol #\a (vector 1) car (cons 1 2) #"bytes" 1+2i
                            (list 1 (void)) (jobject 'a (list (jobject 'b 'undefined)))
                            (hash 1 2) (hash 'a 1 "a" 2) (list 1 (cons 2 3))))])
    (check-exn exn:fail:contract? (lambda () (jvalue->string bad)))
    (check-exn exn:fail:contract? (lambda () (jvalue->bytes bad))))
  ;; The message says where the offending value sits.
  (check-exn #rx"a\\[1\\]\\.b" (lambda () (jvalue->string (jobject 'a (list 0 (jobject 'b car))))))
  ;; Nothing reaches the port when the value is rejected.
  (define out (open-output-string))
  (check-exn exn:fail:contract? (lambda () (write-jvalue (list 1 2 (void)) out)))
  (check-equal? (get-output-string out) ""))
