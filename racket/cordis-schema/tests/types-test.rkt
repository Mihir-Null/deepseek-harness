#lang racket/base
;; Every schema type: accepted values, defaults, exact error messages and paths, the options of
;; a resolve (autofix, ignore, path, strict), the rewritten input, and type strings. The
;; differential table covers the same ground against Node; these cases pin the behaviour that
;; is specific to Racket values (procedures, dates, regexps, bytes, hashes, structs).

(require rackunit
         racket/date
         cordis-data
         cordis-schema)

;; The message of the exn:fail:schema that `thunk` raises.
(define (message-of thunk)
  (with-handlers ([exn:fail:schema? exn-message])
    (thunk)
    'no-error))

(define-syntax-rule (check-message expr expected)
  (check-equal? (message-of (lambda () expr)) expected))

(test-case "a schema is an applicable immutable value"
  (define s (schema-string))
  (check-true (schema? s))
  (check-true (procedure? s))
  (check-false (schema? "string"))
  (check-equal? (s "x") "x")
  (check-true (void? (s)))
  (check-equal? (format "~a" s) "#<schema string>")
  (check-equal? (format "~a" (schema-object* [a 'number] [b (schema-array 'string)]))
                "#<schema { a: number, b?: string[] }>")
  ;; Two schemas are equal only when they are the same value.
  (check-false (equal? (schema-string) (schema-string)))
  (check-true (equal? s s)))

(test-case "any, never, const"
  (check-equal? ((schema-any) (jobject 'a 1)) (jobject 'a 1))
  (check-equal? ((schema-any) 'null) 'null)
  (check-true (void? ((schema-never))))
  (check-equal? ((schema-never) 'null) 'null)
  (check-message ((schema-never) 0) "expected nullable but got 0")
  (check-message ((schema-never) (list 1 'null 2)) "expected nullable but got 1,,2")
  (check-equal? ((schema-const "on") "on") "on")
  (check-equal? ((schema-const 1) 1.0) 1)
  (check-equal? ((schema-const (hash 'a (list 1))) (jobject 'a (list 1))) (jobject 'a (list 1)))
  (check-message ((schema-const "on") "off") "expected on but got off")
  (check-message ((schema-const 1) "1") "expected 1 but got 1")
  (check-message ((schema-const #t) #f) "expected true but got false")
  (check-true (void? ((schema-const "on")))))

(test-case "string"
  (check-equal? ((schema-string) "") "")
  (check-message ((schema-string) 1) "expected string but got 1")
  (check-message ((schema-string) #t) "expected string but got true")
  (check-message ((schema-string) (jobject)) "expected string but got [object Object]")
  (check-message ((schema-string) (hash 'a 1)) "expected string but got [object Object]")
  (check-message ((schema-string) (list "a" (list 1 2))) "expected string but got a,1,2")
  (check-message ((schema-string) 1e21) "expected string but got 1e+21")
  (check-message ((schema-string) 0.1) "expected string but got 0.1")
  (check-message ((schema-string) car) "expected string but got function car() { [native code] }")
  (check-message ((schema-string #:min 2) "a") "expected string length >= 2 but got 1")
  (check-message ((schema-string #:max 2) "abc") "expected string length <= 2 but got 3")
  ;; Lengths count UTF-16 code units.
  (check-equal? ((schema-string #:max 2) "\U1F600") "\U1F600")
  (check-message ((schema-string #:max 1) "\U1F600") "expected string length <= 1 but got 2")
  (check-equal? ((schema-string #:pattern "^[a-z]+$") "abc") "abc")
  (check-message ((schema-string #:pattern "^[a-z]+$") "ABC")
                 "expect string to match regexp /^[a-z]+$/")
  (check-message ((schema-pattern (schema-string) "^a/b$" #:flags "gi") "x")
                 "expect string to match regexp /^a\\/b$/gi")
  (check-equal? ((schema-pattern (schema-string) "^a/b$" #:flags "gi") "A/B") "A/B"))

(test-case "number, natural, percent"
  (check-equal? ((schema-number) 1.5) 1.5)
  (check-message ((schema-number) "1") "expected number but got 1")
  (check-message ((schema-number) 'null #:path '(a)) 'no-error)
  (check-message ((schema-number #:min 0) -1) "expected number >= 0 but got -1")
  (check-message ((schema-number #:max 10) 10.5) "expected number <= 10 but got 10.5")
  (check-message ((schema-number #:min 5 #:max 1) 3) "expected number <= 1 but got 3")
  (check-message ((schema-number #:step 1) 1.5) "expected number multiple of 1 but got 1.5")
  (check-equal? ((schema-number #:step 0.1) 0.3) 0.3)
  (check-equal? ((schema-number #:step 0.1 #:min 0.05) 0.35) 0.35)
  (check-message ((schema-number #:step 0.01) 1.005)
                 "expected number multiple of 0.01 but got 1.005")
  (check-equal? ((schema-number #:step 3 #:min 1) 7) 7)
  (check-message ((schema-number #:step 3 #:min 1) 8) "expected number multiple of 3 but got 8")
  (check-equal? ((schema-number) +inf.0) +inf.0)
  (check-message ((schema-number #:max 5) +inf.0) "expected number <= 5 but got Infinity")
  (check-message ((schema-number #:step 2) +nan.0) "expected number multiple of 2 but got NaN")
  (check-equal? ((schema-natural) 3) 3)
  (check-message ((schema-natural) -1) "expected number >= 0 but got -1")
  (check-message ((schema-natural) 2.5) "expected number multiple of 1 but got 2.5")
  (check-equal? ((schema-percent) 0.57) 0.57)
  (check-message ((schema-percent) 1.01) "expected number <= 1 but got 1.01")
  (check-message ((schema-percent) 0.123) "expected number multiple of 0.01 but got 0.123")
  (check-equal? (schema-meta (schema-percent))
                (jobject 'step 0.01 'min 0 'max 1 'role "slider")))

(test-case "boolean, function, is"
  (check-equal? ((schema-boolean) #f) #f)
  (check-message ((schema-boolean) 0) "expected boolean but got 0")
  (check-eq? ((schema-function) car) car)
  (check-message ((schema-function) 1) "expected function but got 1")
  ;; A schema is a function value, as in Schemastery, and prints as its type string.
  (check-true (schema? ((schema-function) (schema-string))))
  (check-message ((schema-string) (schema-array 'number)) "expected string but got number[]")
  (check-equal? ((schema-is "Array") '()) '())
  (check-equal? ((schema-is "Object") "str") "str")
  (check-equal? ((schema-is "String") "str") "str")
  (check-equal? ((schema-is "Number") 1) 1)
  (check-equal? ((schema-is "Boolean") #t) #t)
  (check-eq? ((schema-is "Function") car) car)
  (check-true (date? ((schema-is "Date") (current-date))))
  (check-true (regexp? ((schema-is "RegExp") #rx"a")))
  (check-equal? ((schema-is "ArrayBuffer") #"ab") #"ab")
  (check-message ((schema-is "Foo") (jobject)) "expected Foo but got [object Object]")
  (check-message ((schema-is "Array") "x") "expected Array but got x")
  (struct point (x y) #:transparent)
  (struct point3 point (z) #:transparent)
  (check-true (point? ((schema-is "point") (point3 1 2 3))))
  (check-true (point? ((schema-is "point3") (point3 1 2 3))))
  (check-message ((schema-is "point3") (point 1 2)) "expected point3 but got #(struct:point 1 2)")
  ;; With a predicate the name only labels the schema.
  (define even (schema-is "Even" (lambda (v) (and (exact-integer? v) (even? v)))))
  (check-equal? (even 4) 4)
  (check-message (even 3) "expected Even but got 3")
  (check-equal? (schema->string even) "Even")
  (check-equal? (schema-constructor even) "Even"))

(test-case "bitset"
  (define s (schema-bitset (list (cons 'read 1) (cons 'write 2) (cons 'exec 4))))
  (check-equal? (s) 0)
  (check-equal? (s 5) 5)
  (check-equal? (s (list "read" "exec")) 5)
  (check-equal? (s (list "nope")) 0)
  (check-message (s (list "read" 1)) "expected string but got 1")
  (check-message (s "read") "expected number or array but got read")
  (check-equal? (schema-bits s) (jobject 'read 1 'write 2 'exec 4))
  (check-equal? (schema-bits (schema-bitset (hash 'a 1 'b "x"))) (jobject 'a 1))
  ;; The rewritten input is the key list, unless the value is the default.
  (define-values (value adapted) (schema-resolve s 3))
  (check-equal? value 3)
  (check-equal? adapted (list "read" "write"))
  (define-values (zero unchanged) (schema-resolve s 0))
  (check-equal? unchanged 0))

(test-case "array and tuple"
  (define s (schema-array (schema-number)))
  (check-equal? (s) '())
  (check-equal? (s (list 1 2)) (list 1 2))
  (check-equal? (s (list 1 'null)) (list 1 'null))
  (check-message (s "x") "expected array but got x")
  (check-message (s (jobject)) "expected array but got [object Object]")
  (check-message (s (list 1 "x")) "$[1] expected number but got x")
  (check-message ((schema-array (schema-number) #:min 2) (list 1))
                 "expected array length >= 2 but got 1")
  (check-message ((schema-array (schema-number) #:max 1) (list 1 2))
                 "expected array length <= 1 but got 2")
  (check-equal? ((schema-array (schema-number #:default 7) #:min 2) (list 'null)) (list 7))
  (check-equal? (s (list 1 "x" 3) #:autofix? #t) (list 1 (void) 3))
  (define t (schema-tuple (list (schema-number) (schema-string))))
  (check-equal? (t) (list (void) (void)))
  (check-equal? ((schema-tuple '())) '())
  (check-equal? (t (list 1)) (list 1 (void)))
  (check-equal? (t (list 1 "a" #t)) (list 1 "a" #t))
  (check-message (t (list "a")) "$[0] expected number but got a")
  (check-message (t (jobject)) "expected array but got [object Object]")
  (define-values (strict _) (schema-resolve t (list 1 "a" #t) #:strict? #t))
  (check-equal? strict (list 1 "a")))

(test-case "dict"
  (define s (schema-dict (schema-number)))
  (check-equal? (s) (jobject))
  (check-equal? (s (jobject 'b 2 'a 1)) (jobject 'b 2 'a 1))
  (check-equal? (jkeys (s (jobject 'b 2 'a 1))) '(b a))
  (check-message (s (list 1)) "expected object but got 1")
  (check-message (s (jobject 'a "x")) "$.a expected number but got x")
  (define renamed (schema-dict (schema-number) (schema-transform (schema-string) string-upcase)))
  (define-values (value adapted) (schema-resolve renamed (jobject 'a 1 'b 2)))
  (check-equal? value (jobject 'A 1 'B 2))
  (check-equal? adapted (jobject 'A 1 'B 2))
  (define keyed (schema-dict (schema-number) (schema-string #:pattern "^[a-z]+$")))
  (check-message (keyed (jobject 'ab 1 'AB 2)) "expect string to match regexp /^[a-z]+$/")
  (define-values (kept _) (schema-resolve keyed (jobject 'ab 1 'AB 2) #:strict? #t))
  (check-equal? kept (jobject 'ab 1))
  (check-equal? (schema->string (schema-key-schema keyed)) "string"))

(test-case "object: fields resolve in schema order and unknown keys follow in input order"
  (define s
    (schema-object* [b (schema-number #:default 2)]
                    [a (schema-string)]
                    [c (schema-boolean #:default #t)]))
  (check-equal? (jkeys (s (jobject 'z 1 'a "x" 'y 2))) '(b a c z y))
  (check-equal? (s) (jobject 'b 2 'c #t))
  (check-equal? (s 'null) (jobject 'b 2 'c #t))
  (check-equal? (s (jobject 'a 'null)) (jobject 'b 2 'a 'null 'c #t))
  (check-message (s "str") "expected object but got str")
  (check-message (s (list)) "expected object but got ")
  (check-message (s (jobject 'a 1)) "$.a expected string but got 1")
  (check-message ((schema-object* [a (schema-string #:required? #t)]) (jobject))
                 "$.a missing required value")
  ;; A hash is read in sorted key order.
  (check-equal? (jkeys ((schema-object '()) (hash 'q 1 'p 2))) '(p q))
  (check-equal? ((schema-object (hash 'x 'number)) (hash 'x 1 'y 2)) (jobject 'x 1 'y 2))
  ;; Keys named like members every JavaScript object inherits are never copied.
  (check-equal? ((schema-object '()) (jobject 'toString "x" 'constructor 1 'kept 2))
                (jobject 'kept 2))
  (define-values (strict _) (schema-resolve s (jobject 'a "x" 'z 1) #:strict? #t))
  (check-equal? strict (jobject 'b 2 'a "x" 'c #t)))

(test-case "union and intersect"
  (define u (schema-union (list "legacy" "timed")))
  (check-equal? (u "timed") "timed")
  (check-true (void? (u)))
  (check-message (u "other") "expected \"legacy\" | \"timed\" but got \"other\"")
  (check-message (u (jobject 'a (list 1 "x")))
                 "expected \"legacy\" | \"timed\" but got {\"a\":[1,\"x\"]}")
  (check-message ((schema-union '()) 1) "expected  but got 1")
  (check-message ((schema-object* [mode u]) (jobject 'mode 3))
                 "$.mode expected \"legacy\" | \"timed\" but got 3")
  (define i
    (schema-intersect (list (schema-object* [a (schema-number #:default 1)])
                            (schema-object* [b (schema-string #:default "x")]))))
  (check-equal? (i) (jobject 'a 1 'b "x"))
  (check-equal? (i (jobject 'c #t)) (jobject 'a 1 'b "x" 'c #t))
  (check-message (i (jobject 'b 1)) "$.b expected string but got 1")
  (check-message ((schema-intersect (list (schema-string) (schema-number))) "a")
                 "expected number but got a")
  (check-equal? ((schema-intersect '()) 5) 5)
  (check-message
   ((schema-intersect (list (schema-transform (schema-string) string-upcase #t) (schema-string)))
    "a")
   "expected string & string but got \"a\"")
  ;; A failure that is not a validation error is an ordinary exception.
  (check-exn (lambda (e) (and (exn:fail? e) (not (exn:fail:schema? e))))
             (lambda () ((schema-intersect (list (schema-loose (schema-never)))) (jobject 'a 1)))))

(test-case "transform"
  (define calls '())
  (define s
    (schema-transform (schema-string)
                      (lambda (v) (set! calls (cons v calls)) (string-append v "!"))))
  (define-values (value adapted) (schema-resolve s "a"))
  (check-equal? value "a!")
  (check-equal? adapted "a!")
  ;; Without preserve the callback also runs on the input, as in Schemastery.
  (check-equal? calls '("a" "a"))
  (define p (schema-transform (schema-string) string-upcase #t))
  (define-values (upper kept) (schema-resolve p "a"))
  (check-equal? upper "A")
  (check-equal? kept "a")
  (check-message (p 1) "expected string but got 1")
  (check-true (procedure? (schema-callback p)))
  (check-equal? (schema->string (schema-inner p)) "string")
  ;; The inner schema resolves in strict mode.
  (check-equal? ((schema-transform (schema-object* [a 'number]) values #t) (jobject 'a 1 'b 2))
                (jobject 'a 1)))

(test-case "lazy"
  (define built 0)
  (define s (schema-lazy (lambda () (set! built (add1 built)) (schema-number #:default 4))))
  (check-equal? built 0)
  (check-equal? (s) 4)
  (check-equal? (s 2) 2)
  (check-equal? built 1)
  (check-equal? (schema->string s) "Schema<lazy>")
  (check-equal? (schema-type s) "lazy")
  (check-equal? (schema-type (schema-inner s)) "number")
  ;; Metadata of the lazy node is the built schema's, unless the built schema sets the key.
  (define described
    (schema-description (schema-default (schema-lazy (lambda () (schema-number #:default 4))) 9)
                        "lazy"))
  (check-equal? (schema-meta (schema-inner described)) (jobject 'default 4 'description "lazy"))
  (check-exn exn:fail:contract? (lambda () ((schema-lazy (lambda () "not a schema")) 1))))

(test-case "date, regexp, array-buffer"
  (define d (schema-date))
  (check-equal? (schema->string d) "Date | string")
  (define parsed (d "2020-01-02T03:04:05Z"))
  (check-equal? (list (date-year parsed) (date-month parsed) (date-day parsed) (date-hour parsed)
                      (date-minute parsed) (date-second parsed) (date-time-zone-offset parsed))
                (list 2020 1 2 3 4 5 0))
  (check-equal? (date->seconds (d "2020-01-02") #f) 1577923200)
  (check-equal? (date->seconds (d "2020-01-02T00:00:00+02:00") #f) (- 1577923200 7200))
  (check-equal? (date*-nanosecond (d "2020-01-02T03:04:05.250Z")) 250000000)
  (define now (current-date))
  (check-eq? (d now) now)
  (check-message (d "nope") "expected Date | string but got \"nope\"")
  (check-message (d 5) "expected Date | string but got 5")
  (define r (schema-regexp "i"))
  (check-equal? (schema->string r) "RegExp | string")
  (check-true (regexp-match? (r "^ab+c$") "ABBC"))
  (check-false (regexp-match? ((schema-regexp) "^ab+c$") "ABBC"))
  (check-true (regexp-match? ((schema-regexp) "^\\d{2}/\\w+$") "12/ab"))
  (check-eq? (r #px"x") #px"x")
  (check-message (r "(") "expected RegExp | string but got \"(\"")
  (check-equal? (schema-meta (cadr (schema-members r))) (jobject))
  (check-equal? (schema-meta (schema-inner (cadr (schema-members r))))
                (jobject 'role "regexp" 'extra (jobject 'flag "i")))
  (define b (schema-array-buffer))
  (check-equal? (schema->string b) "ArrayBuffer | SharedArrayBuffer | any")
  (check-equal? (b #"\1\2") #"\1\2")
  (check-message (b "0102") "expected ArrayBuffer | SharedArrayBuffer | any but got \"0102\"")
  (check-equal? ((schema-array-buffer 'hex) "0102ff") (bytes 1 2 255))
  (check-equal? ((schema-array-buffer 'hex) "01zz") (bytes 1))
  (check-equal? ((schema-array-buffer 'base64) "aGVsbG8=") #"hello")
  (check-equal? ((schema-array-buffer 'base64) "aGVsbG8") #"hello")
  (check-equal? (schema->string (schema-array-buffer 'hex))
                "ArrayBuffer | SharedArrayBuffer | any | string"))

(test-case "custom types"
  (define even
    (schema-custom
     "even"
     (lambda (data s options strict?)
       (unless (and (exact-integer? data) (even? data))
         (raise-schema-error (format "expected even number but got ~a" data) options))
       data)
     #:format (lambda (s inline?) (if inline? "(even)" "even"))))
  (check-equal? (even 4) 4)
  (check-message (even 3) "expected even number but got 3")
  (check-message ((schema-object* [n (schema-array even)]) (jobject 'n (list 2 3)))
                 "$.n[1] expected even number but got 3")
  (check-equal? (schema->string even) "even")
  (check-equal? (schema->string (schema-array even)) "(even)[]")
  (check-equal? (schema-type even) "even")
  ;; A resolver may resolve children and return the rewritten input as a second value.
  (define pair
    (schema-custom
     "pair"
     (lambda (data s options strict?)
       (define-values (left _l)
         (schema-resolve (schema-number) (car data)
                         #:options (resolve-options-extend options 0)))
       (define-values (right _r)
         (schema-resolve (schema-string) (cadr data)
                         #:options (resolve-options-extend options 1)))
       (check-true (resolve-options? options))
       (check-false (resolve-options-autofix? options))
       (check-false (resolve-options-ignore options))
       (values (cons left right) (list right left)))))
  (define-values (value adapted) (schema-resolve pair (list 1 "a") #:path '(root)))
  (check-equal? value (cons 1 "a"))
  (check-equal? adapted (list "a" 1))
  (check-message (pair (list 1 2) #:path '(root)) "$.root[1] expected string but got 2")
  (check-equal? (schema->string pair) "Schema<pair>")
  ;; A type name without a resolver fails when it is resolved.
  (define unknown (jvalue->schema (jobject 'type "mystery")))
  (check-message (unknown 1) "unsupported type \"mystery\"")
  (check-true (void? (unknown))))

(test-case "defaults, required, loose"
  (check-equal? ((schema-string #:default "d")) "d")
  (check-equal? ((schema-string #:default "d") 'null) "d")
  (check-message ((schema-string #:required? #t)) "missing required value")
  (check-message ((schema-string #:required? #t #:default "d")) "missing required value")
  (check-equal? ((schema-loose (schema-string #:default "d")) 5) "d")
  (check-true (void? ((schema-loose (schema-string)) 5)))
  (check-message ((schema-loose (schema-string) #f) 5) "expected string but got 5")
  ;; A default is itself resolved.
  (check-message ((schema-number #:default "x")) "expected number but got x")
  (check-equal? ((schema-object* #:default (jobject 'b 2) [a (schema-number #:default 1)]))
                (jobject 'a 1 'b 2)))

(test-case "options: autofix, ignore, path"
  (define s
    (schema-object* [a (schema-number)]
                    [b (schema-string #:default "d")]
                    [c (schema-array (schema-number))]))
  (define-values (value adapted)
    (schema-resolve s (jobject 'a "x" 'b 1 'c (list 1 "y")) #:autofix? #t))
  (check-equal? value (jobject 'b "d" 'c (list 1 (void))))
  (check-equal? adapted (jobject 'c (list 1 (void))))
  (check-equal? (s (jobject 'a "x") #:ignore (lambda (data schema) (string? data)))
                (jobject 'a "x" 'b "d" 'c '()))
  (check-equal? (s (jobject 'a 1 'c "y")
                   #:ignore (lambda (data schema) (equal? (schema-type schema) "array")))
                (jobject 'a 1 'b "d" 'c "y"))
  (check-message (s (jobject 'a "x" 'c "y")
                    #:ignore (lambda (data schema) (equal? (schema-type schema) "array")))
                 "$.a expected number but got x")
  (check-message (s (jobject 'a "x") #:path '(plugins "tool-fs" 0 config))
                 "$.plugins.tool-fs[0].config.a expected number but got x")
  (check-equal?
   (with-handlers ([exn:fail:schema? exn:fail:schema-path])
     (s (jobject 'c (list 1 "y")) #:path '(root)))
   '(root c 1))
  (check-exn exn:fail:contract? (lambda () (s (jobject) #:path "root")))
  ;; The input is never changed, and the rewritten input is the input itself when nothing was
  ;; rewritten.
  (define input (jobject 'a 1 'c (list 1 2)))
  (define-values (same unchanged) (schema-resolve s input))
  (check-eq? unchanged input))

(test-case "schema-validate is the Standard Schema face"
  (define s (schema-object* [a (schema-number #:required? #t)]))
  (define-values (value issues) (schema-validate s (jobject 'a 1)))
  (check-equal? value (jobject 'a 1))
  (check-false issues)
  (define-values (none failed) (schema-validate s (jobject 'a "x")))
  (check-true (void? none))
  (check-equal? failed (list (cons '(a) "$.a expected number but got x")))
  ;; Other exceptions propagate.
  (check-exn #rx"boom"
             (lambda ()
               (schema-validate (schema-transform (schema-any) (lambda (v) (error "boom"))) 1))))

(test-case "raise-schema-error formats the path as Schemastery does"
  (check-message (raise-schema-error "bad") "bad")
  (check-message (raise-schema-error "bad" '(a 0 "b" c)) "$.a[0].b.c bad")
  (check-equal? (with-handlers ([exn:fail:schema? exn:fail:schema-path])
                  (raise-schema-error "bad" '(a 0)))
                '(a 0)))

(test-case "type strings"
  (check-equal? (schema->string (schema-const "a\"b")) "\"a\\\"b\"")
  (check-equal? (schema->string (schema-const 5)) "5")
  (check-equal? (schema->string (schema-const #f)) "false")
  (check-equal? (schema->string (schema-const 'null)) "Schema<const>")
  (check-equal? (schema->string (schema-dict (schema-union (list 'string 'number))))
                "{ [key: string]: string | number }")
  (check-equal? (schema->string (schema-array (schema-union (list 1 2)))) "(1 | 2)[]")
  (check-equal? (schema->string (schema-tuple (list 'string (schema-array 'number))))
                "[string, number[]]")
  (check-equal? (schema->string
                 (schema-intersect (list (schema-union (list 1 2))
                                         (schema-object* [a 'string] [b (schema-string)]))))
                "(1 | 2) & { a: string, b?: string }")
  (check-equal? (schema->string (schema-object '())) "{}")
  (check-equal? (schema->string (schema-transform (schema-union (list 1 2)) values) #t) "(1 | 2)")
  (check-equal? (schema->string (schema-bitset '())) "bitset")
  (check-equal? (schema->string (schema-function)) "function"))
