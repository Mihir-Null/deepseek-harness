#lang racket/base
;; Unit tests of the `!!js` evaluator: the value of each language construct, JavaScript's
;; coercions, name resolution, errors and their positions, the fallback parameter and
;; `js-interpolate`. js-yaml-table-test.rkt holds the results Node computed for the same areas.

(require rackunit
         cordis-data
         cordis-yaml/js-expr)

(define (u . codes) (list->string (map integer->char codes)))

(define empty-env (make-js-env (hash)))

(define (ev source [env empty-env])
  (js-eval source env))

(define-syntax-rule (check-js source expected)
  (check-equal? (ev source) expected source))

;; The exception evaluating `source` raises.
(define (eval-error source [env empty-env])
  (with-handlers ([exn:fail? values])
    (define v (js-eval source env))
    (fail (format "expected an error from ~s, got ~s" source v))))

;; The JavaScript error name evaluating `source` raises.
(define (error-name source [env empty-env])
  (define e (eval-error source env))
  (cond [(exn:fail:js-expr:unsupported? e) 'unsupported]
        [(exn:fail:js-expr? e) (car (regexp-match #rx"^[A-Za-z]+" (exn-message e)))]
        [else e]))

;; ---------------------------------------------------------------------------------------------
;; Values

(test-case "literals and the value model"
  (check-js "1" 1)
  (check-js "1.5" 1.5)
  (check-js "'a'" "a")
  (check-js "true" #t)
  (check-js "false" #f)
  (check-js "null" 'null)
  (check-pred void? (ev "undefined"))
  (check-pred void? (ev ""))
  (check-js "[1, 'a', [true]]" '(1 "a" (#t)))
  (check-js "({a: 1, b: {c: null}})" (jobject 'a 1 'b (jobject 'c 'null)))
  (check-pred procedure? (ev "x => x"))
  (check-js "`a${1 + 1}b${'c'}`" "a2bc")
  (check-js "`${null} ${undefined} ${[1, 2]} ${{}}`" "null undefined 1,2 [object Object]"))

(test-case "numbers are exact integers when integral, else flonums"
  (check-pred exact-integer? (ev "4 / 2"))
  (check-js "4 / 2" 2)
  (check-js "1 / 2" 0.5)
  (check-js "0.1 + 0.2" 0.30000000000000004)
  (check-js "1e21" 1e21)
  (check-pred flonum? (ev "1e21"))
  (check-js "9007199254740992 + 1" 9007199254740992)
  (check-js "1 / 0" +inf.0)
  (check-js "-1 / 0" -inf.0)
  (check-true (eqv? (ev "0 / 0") +nan.0))
  (check-true (eqv? (ev "-0") -0.0))
  (check-true (eqv? (ev "0 * -1") -0.0))
  (check-js "1 / -0" -inf.0))

(test-case "objects keep JavaScript's key order and drop undefined members"
  (check-equal? (jkeys (ev "({b: 1, a: 2})")) '(b a))
  (check-equal? (jkeys (ev "({b: 1, 2: 0, 1: 0, a: 2})")) '(|1| |2| b a))
  (check-js "({a: 1, a: 2})" (jobject 'a 2))
  (check-js "({a: undefined, b: 1})" (jobject 'b 1))
  (check-js "({['k' + 1]: 1})" (jobject 'k1 1))
  (check-js "({...{a: 1, b: 2}, b: 3, ...null})" (jobject 'a 1 'b 3))
  (check-js "({...[5, 6]})" (jobject '|0| 5 '|1| 6))
  (check-js "[...[1, 2], ...'ab']" '(1 2 "a" "b"))
  (check-js "(x => ({x}))(5)" (jobject 'x 5)))

;; ---------------------------------------------------------------------------------------------
;; Operators

(test-case "truthiness"
  (for ([source '("0" "-0" "NaN" "''" "null" "undefined" "false")])
    (check-equal? (ev (string-append "!!(" source ")")) #f source))
  (for ([source '("1" "-1" "'0'" "' '" "[]" "({})" "(() => 0)" "Infinity")])
    (check-equal? (ev (string-append "!!(" source ")")) #t source))
  (check-false (js-truthy? 0))
  (check-false (js-truthy? -0.0))
  (check-false (js-truthy? +nan.0))
  (check-false (js-truthy? ""))
  (check-false (js-truthy? 'null))
  (check-false (js-truthy? (void)))
  (check-true (js-truthy? '()))
  (check-true (js-truthy? empty-jobject))
  (check-true (js-truthy? "0")))

(test-case "unary operators"
  (check-js "!0" #t)
  (check-js "-'5'" -5)
  (check-js "+'12'" 12)
  (check-js "+' 1.5 '" 1.5)
  (check-js "+''" 0)
  (check-js "+'0x1f'" 31)
  (check-true (eqv? (ev "+'12px'") +nan.0))
  (check-js "+null" 0)
  (check-js "+true" 1)
  (check-js "+[]" 0)
  (check-js "+[7]" 7)
  (check-true (eqv? (ev "+undefined") +nan.0))
  (check-true (eqv? (ev "+{}") +nan.0))
  (check-pred void? (ev "void 'x'"))
  (check-js "typeof 1" "number")
  (check-js "typeof 'a'" "string")
  (check-js "typeof true" "boolean")
  (check-js "typeof undefined" "undefined")
  (check-js "typeof null" "object")
  (check-js "typeof []" "object")
  (check-js "typeof {}" "object")
  (check-js "typeof (x => x)" "function")
  (check-js "typeof JSON" "object")
  (check-js "typeof Number" "function")
  ;; typeof of a name that is not defined does not throw.
  (check-js "typeof nope" "undefined"))

(test-case "+ concatenates when either operand is a string after ToPrimitive"
  (check-js "1 + 2" 3)
  (check-js "'a' + 'b'" "ab")
  (check-js "'a' + 1" "a1")
  (check-js "1 + 2 + 'a'" "3a")
  (check-js "'a' + 1 + 2" "a12")
  (check-js "'a' + null" "anull")
  (check-js "'a' + undefined" "aundefined")
  (check-js "1 + null" 1)
  (check-js "1 + true" 2)
  (check-js "[] + []" "")
  (check-js "[1, 2] + [3]" "1,23")
  (check-js "({}) + 'x'" "[object Object]x")
  (check-js "1 + [2]" "12")
  (check-js "'' + 1e21" "1e+21")
  (check-js "'' + 0.000001" "0.000001")
  (check-js "'' + 1e-7" "1e-7")
  (check-js "'' + -0" "0")
  (check-js "'a' + ({toString: () => 'T'})" "aT")
  (check-js "1 + ({valueOf: () => 41})" 42)
  (check-true (eqv? (ev "1 + undefined") +nan.0)))

(test-case "arithmetic"
  (check-js "'5' - 2" 3)
  (check-js "'5' * '2'" 10)
  (check-js "10 / 4" 2.5)
  (check-js "10 % 3" 1)
  (check-js "-10 % 3" -1)
  (check-js "5.5 % 2" 1.5)
  (check-true (eqv? (ev "5 % 0") +nan.0))
  (check-true (eqv? (ev "-4 % 2") -0.0))
  (check-js "2 % Infinity" 2)
  (check-js "2 * 3 + 4" 10)
  (check-js "2 + 3 * 4" 14)
  (check-js "(2 + 3) * 4" 20)
  (check-js "10 - 2 - 3" 5)
  (check-js "1e308 * 10" +inf.0)
  (check-true (eqv? (ev "'a' - 1") +nan.0)))

(test-case "relational operators"
  (check-js "1 < 2" #t)
  (check-js "2 <= 2" #t)
  (check-js "1 > 2" #f)
  (check-js "1 >= 2" #f)
  (check-js "'a' < 'b'" #t)
  (check-js "'10' < '9'" #t)
  (check-js "'10' < 9" #f)
  (check-js "null >= 0" #t)
  (check-js "undefined < 1" #f)
  (check-js "NaN >= NaN" #f)
  ;; Strings compare by UTF-16 code units: U+1F600 starts with the unit D83D.
  (check-equal? (ev (string-append "'" (u #x1f600) "' < '" (u #xff5e) "'")) #t))

(test-case "strict and loose equality"
  (check-js "1 === 1" #t)
  (check-js "1 === 1.0" #t)
  (check-js "1 === '1'" #f)
  (check-js "null === undefined" #f)
  (check-js "NaN === NaN" #f)
  (check-js "0 === -0" #t)
  (check-js "'a' !== 'b'" #t)
  (check-js "[1] === [1]" #f)
  (check-js "(a => a === a)([1])" #t)
  (check-js "1 == '1'" #t)
  (check-js "0 == ''" #t)
  (check-js "null == undefined" #t)
  (check-js "null == 0" #f)
  (check-js "true == 1" #t)
  (check-js "true == 'true'" #f)
  (check-js "[1] == 1" #t)
  (check-js "[1, 2] == '1,2'" #t)
  (check-js "NaN == NaN" #f)
  (check-js "1 != '1'" #f)
  (check-js "'a' != 'b'" #t))

(test-case "the identity of two empty arrays cannot be decided"
  ;; Racket has one empty list, JavaScript a new array per literal.
  (check-equal? (error-name "[] === []") 'unsupported)
  (check-equal? (error-name "(a => a === a)([])") 'unsupported)
  (check-js "[] === [1]" #f))

(test-case "logical operators short-circuit and yield an operand"
  (check-js "1 && 2" 2)
  (check-js "0 && nope" 0)
  (check-js "'' || 'd'" "d")
  (check-js "'a' || nope" "a")
  (check-js "null ?? 'd'" "d")
  (check-js "undefined ?? 'd'" "d")
  (check-js "0 ?? 'd'" 0)
  (check-js "'' ?? 'd'" "")
  (check-js "false ?? nope" #f)
  (check-js "1 && 0 || 3" 3)
  (check-js "1 || 2 && nope" 1)
  (check-js "(null || undefined) ?? 'x'" "x"))

(test-case "the conditional operator evaluates one branch"
  (check-js "1 ? 'a' : nope" "a")
  (check-js "0 ? nope : 'b'" "b")
  (check-js "'' ? 1 : [] ? 2 : 3" 2)
  (check-js "1 > 2 ? 'gt' : 'le'" "le"))

(test-case "member access and optional chaining"
  (check-js "({a: {b: 3}}).a.b" 3)
  (check-js "({a: 1})['a']" 1)
  (check-pred void? (ev "({a: 1}).b"))
  (check-js "[1, 2, 3][1]" 2)
  (check-pred void? (ev "[1, 2, 3][5]"))
  (check-js "'abc'[1]" "b")
  (check-js "'abc'.length" 3)
  (check-js "[1, 2].length" 2)
  (check-pred void? (ev "null?.a"))
  (check-pred void? (ev "undefined?.a.b.c"))
  (check-pred void? (ev "null?.[nope]"))
  (check-pred void? (ev "null?.(nope)"))
  (check-pred void? (ev "({}).f?.(nope)"))
  (check-js "({a: {b: 1}}).a?.b" 1)
  (check-js "({a: 'x'}).a?.toUpperCase()" "X")
  (check-js "undefined?.a ?? 'd'" "d")
  ;; The short circuit stops at parentheses.
  (check-equal? (error-name "(null?.a).b") "TypeError"))

(test-case "arrow functions are closures"
  (check-js "(x => x + 1)(1)" 2)
  (check-js "((a, b) => a + b)(1, 2)" 3)
  (check-js "(x => y => x + y)(1)(2)" 3)
  (check-pred void? (ev "((a, b) => b)(1)"))
  (check-js "((a) => a)(1, 2, 3)" 1)
  (check-js "((f) => f(f(1)))((x) => x * 3)" 9)
  (check-js "[1, 2, 3].map((x, i) => x * i)" '(0 2 6))
  (check-js "((x) => ((x) => x)(2) + x)(1)" 3)
  ;; An arrow function is a Racket procedure the host can call.
  (define f (ev "(a, b) => a + (b ?? 10)"))
  (check-equal? (f 1 2) 3)
  (check-equal? (f 1) 11)
  (check-equal? (f 1 2 3) 3))

(test-case "runaway recursion is a RangeError"
  (check-equal? (error-name "(f => f(f))(f => f(f))") "RangeError"))

;; ---------------------------------------------------------------------------------------------
;; Methods and globals

(test-case "string methods"
  (check-js "'Hello'.startsWith('He')" #t)
  (check-js "'Hello'.endsWith('lo')" #t)
  (check-js "'Hello'.includes('ell')" #t)
  (check-js "'a,b,,c'.split(',')" '("a" "b" "" "c"))
  (check-js "'a,b'.split(',', 1)" '("a"))
  (check-js "'abc'.split('')" '("a" "b" "c"))
  (check-js "'a-b-c'.replace('-', '+')" "a+b-c")
  (check-js "'a-b-c'.replaceAll('-', '+')" "a+b+c")
  (check-js "'abc'.replace('b', '[$&]')" "a[b]c")
  (check-js "'abc'.replace('b', m => m.toUpperCase())" "aBc")
  (check-js "'  a b  '.trim()" "a b")
  (check-js "'  a'.trimStart() + 'b  '.trimEnd()" "ab")
  (check-js "'aBc'.toLowerCase()" "abc")
  (check-js "'aBc'.toUpperCase()" "ABC")
  (check-js "'Hello'.slice(1, 3)" "el")
  (check-js "'Hello'.slice(-3)" "llo")
  (check-js "'Hello'.substring(3, 1)" "el")
  (check-js "'Hello'.at(-1)" "o")
  (check-js "'Hello'.charAt(1)" "e")
  (check-js "'Hello'.indexOf('l')" 2)
  (check-js "'Hello'.indexOf('z')" -1)
  (check-js "'a'.concat('b', 1)" "ab1")
  (check-js "'5'.padStart(3, '0')" "005")
  (check-js "'5'.padEnd(3, 'ab')" "5ab")
  (check-js "'ab'.repeat(2)" "abab")
  (check-js "'a'.toString() + 'b'.valueOf()" "ab")
  (check-equal? (error-name "'ab'.repeat(-1)") "RangeError"))

(test-case "string positions are UTF-16 code units"
  (define s (string-append "'a" (u #x1f600) "b'"))
  (check-equal? (ev (string-append s ".length")) 4)
  (check-equal? (ev (string-append s ".indexOf('b')")) 3)
  (check-equal? (ev (string-append s ".slice(1, 3)")) (u #x1f600))
  (check-equal? (ev (string-append "[..." s "].length")) 3)
  ;; Half of a surrogate pair has no Racket character.
  (check-equal? (error-name (string-append s ".slice(0, 2)")) 'unsupported)
  (check-equal? (error-name (string-append s "[1]")) 'unsupported))

(test-case "array methods"
  (check-js "[3, 1, 2].includes(2)" #t)
  (check-js "[NaN].includes(NaN)" #t)
  (check-js "[3, 1, 2].indexOf(2)" 2)
  (check-js "[NaN].indexOf(NaN)" -1)
  (check-js "[3, 1, 2].join('-')" "3-1-2")
  (check-js "[null, undefined, 1].join()" ",,1")
  (check-js "[3, 1, 2].map(x => x * 2)" '(6 2 4))
  (check-js "[3, 1, 2].filter(x => x > 1)" '(3 2))
  (check-js "[3, 1, 2].find(x => x < 3)" 1)
  (check-pred void? (ev "[3, 1, 2].find(x => x > 5)"))
  (check-js "[0, false].find(x => x === false)" #f)
  (check-js "[3, 1, 2].every(x => x > 0)" #t)
  (check-js "[3, 1, 2].some(x => x > 2)" #t)
  (check-js "[3, 1, 2].slice(1)" '(1 2))
  (check-js "[3, 1, 2].slice(-2, -1)" '(1))
  (check-js "[3, 1, 2].concat([4], 5)" '(3 1 2 4 5))
  (check-js "[3, 1, 2].at(-1)" 2)
  (check-js "[1, [2, 3]].toString()" "1,2,3")
  (check-js "['1', '2', '10'].map(Number)" '(1 2 10))
  (check-equal? (error-name "[1].map(5)") "TypeError"))

(test-case "number and boolean methods"
  (check-js "(1.005).toFixed(2)" "1.00")
  (check-js "(2.5).toFixed(0)" "3")
  (check-js "(255).toString(16)" "ff")
  (check-js "(35).toString(36)" "z")
  (check-js "(1.5).toString()" "1.5")
  (check-js "true.toString()" "true")
  (check-equal? (error-name "(1).toFixed(101)") "RangeError"))

(test-case "Number, String, Boolean, parseInt, parseFloat"
  (check-js "Number('12')" 12)
  (check-js "Number('')" 0)
  (check-true (eqv? (ev "Number('12px')") +nan.0))
  (check-true (eqv? (ev "Number(undefined)") +nan.0))
  (check-js "Number(null)" 0)
  (check-js "Number()" 0)
  (check-js "Number.isInteger(5)" #t)
  (check-js "Number.isInteger('5')" #f)
  (check-js "Number.isNaN(NaN)" #t)
  (check-js "Number.MAX_SAFE_INTEGER" 9007199254740991)
  (check-js "String(1.50)" "1.5")
  (check-js "String(null)" "null")
  (check-js "String(undefined)" "undefined")
  (check-js "String([1, [2, 3]])" "1,2,3")
  (check-js "String({})" "[object Object]")
  (check-js "Boolean('0')" #t)
  (check-js "Boolean('')" #f)
  (check-js "Boolean()" #f)
  (check-js "parseInt('42px')" 42)
  (check-js "parseInt('1f', 16)" 31)
  (check-js "parseInt('0x1f')" 31)
  (check-js "parseInt('z', 36)" 35)
  (check-true (eqv? (ev "parseInt('abc')") +nan.0))
  (check-js "parseFloat('1.5px')" 1.5)
  (check-js "parseFloat('.5')" 0.5)
  (check-js "isNaN('x')" #t)
  (check-js "isFinite('1')" #t))

(test-case "JSON"
  (check-js "JSON.parse('{\"a\":[1,2,{\"b\":null}]}')"
            (jobject 'a (list 1 2 (jobject 'b 'null))))
  (check-js "JSON.parse('[]')" '())
  (check-js "JSON.parse('1.0')" 1)
  (check-equal? (jkeys (ev "JSON.parse('{\"b\":1,\"2\":2,\"1\":3}')")) '(|1| |2| b))
  (check-equal? (error-name "JSON.parse('{a:1}')") "SyntaxError")
  (check-equal? (error-name "JSON.parse(undefined)") "SyntaxError")
  (check-js "JSON.stringify({a: 1, b: [1, null]})" "{\"a\":1,\"b\":[1,null]}")
  (check-js "JSON.stringify({a: undefined, b: () => 1, c: 1})" "{\"c\":1}")
  (check-js "JSON.stringify([undefined])" "[null]")
  (check-pred void? (ev "JSON.stringify(undefined)"))
  (check-js "JSON.stringify({a: [1]}, null, 2)" "{\n  \"a\": [\n    1\n  ]\n}")
  (check-js "JSON.stringify(NaN)" "null"))

(test-case "Math, Array, Object and the URI functions"
  (check-js "Math.max(1, 3, 2)" 3)
  (check-js "Math.min(1, 3, 2)" 1)
  (check-js "Math.round(2.5)" 3)
  (check-js "Math.round(-2.5)" -2)
  (check-js "Math.floor(-1.2)" -2)
  (check-js "Math.ceil(1.2)" 2)
  (check-js "Math.trunc(-1.9)" -1)
  (check-js "Math.abs(-5)" 5)
  (check-js "Math.sign(-3)" -1)
  (check-js "Math.PI" 3.141592653589793)
  (check-js "Array.isArray([])" #t)
  (check-js "Array.isArray('a')" #f)
  (check-js "Object.keys({b: 1, a: 2})" '("b" "a"))
  (check-js "Object.values({a: 1, b: [2]})" '(1 (2)))
  (check-js "Object.entries({a: 1})" '(("a" 1)))
  (check-js "encodeURIComponent('a b&c/d')" "a%20b%26c%2Fd")
  (check-js "decodeURIComponent('a%20b%2Fc')" "a b/c")
  (check-js "encodeURI('http://x/a b?q=1')" "http://x/a%20b?q=1")
  (check-js "decodeURI('%2F%20')" "%2F ")
  (check-equal? (error-name "decodeURIComponent('%')") "URIError"))

(test-case "URL"
  (check-js "new URL('./runner.mjs', 'file:///opt/dsh/snapshots/x/snapshot.yml').pathname"
            "/opt/dsh/snapshots/x/runner.mjs")
  (check-js "new URL('../../y.ts', 'file:///a/b/c/d.yml').href" "file:///a/y.ts")
  (check-js "decodeURIComponent(new URL('file:///a b/c').pathname)" "/a b/c")
  (check-js "new URL('https://user:pw@Example.COM:8443/p?q=1#h').host" "example.com:8443")
  (check-js "new URL('http://example.com:80/').href" "http://example.com/")
  (check-js "new URL('http://a/b?x=1#y').search + new URL('http://a/b?x=1#y').hash" "?x=1#y")
  (check-js "new URL('http://a/b').origin" "http://a")
  (check-js "'' + new URL('http://a/b')" "http://a/b")
  (check-js "JSON.stringify(new URL('http://a/b'))" "\"http://a/b\"")
  (check-js "typeof new URL('http://a')" "object")
  (check-equal? (error-name "new URL('nope')") "TypeError")
  (check-equal? (error-name "URL('http://a')") "TypeError")
  (check-equal? (error-name "new URL('mailto:a@b')") 'unsupported)
  (check-equal? (error-name "new URL('http://a/?x=1').searchParams") 'unsupported))

;; ---------------------------------------------------------------------------------------------
;; Environments

(test-case "names resolve to parameters, then the lookup, the bindings, the globals"
  (define env
    (make-js-env (hash "a" 1 'b 2 "JSON" "shadowed" "c" 30)
                 #:lookup (lambda (name failure)
                            (case name
                              [("c") 3]
                              [("Number") "from lookup"]
                              [else (failure)]))))
  (check-equal? (ev "a + b" env) 3)
  (check-equal? (ev "c" env) 3)
  (check-equal? (ev "Number" env) "from lookup")
  (check-equal? (ev "JSON" env) "shadowed")
  (check-equal? (ev "(a => a)(9)" env) 9)
  (check-equal? (ev "(c => c)(9)" env) 9)
  (check-equal? (ev "String(a)" env) "1")
  (check-equal? (js-env-bindings env) (hash "a" 1 "b" 2 "JSON" "shadowed" "c" 30))
  (check-pred js-env? env))

(test-case "globals can be replaced"
  (define env (make-js-env (hash) #:globals (hash "answer" 42)))
  (check-equal? (ev "answer" env) 42)
  (check-equal? (error-name "JSON" env) "ReferenceError")
  (check-true (hash-has-key? js-standard-globals "JSON"))
  (check-true (hash-has-key? js-standard-globals "URL")))

(test-case "a name that is not defined"
  (check-equal? (error-name "nope") "ReferenceError")
  (check-equal? (error-name "nope.a") "ReferenceError")
  ;; A real JavaScript or Node global that is not implemented is unsupported instead.
  (check-equal? (error-name "Date.now()") 'unsupported)
  (check-equal? (error-name "process.env.X") 'unsupported)
  (check-equal? (error-name "typeof Date") 'unsupported)
  (check-equal? (error-name "globalThis") 'unsupported))

(test-case "values from the host"
  (define env
    (make-js-env (hash "n" 5/2
                       "big" (expt 10 30)
                       "list" '(1 2 3)
                       "obj" (hash 'a 1 "b" (list 2))
                       "add" (lambda (a b) (+ a b))
                       "any" (lambda args (length args))
                       "opt" (lambda (a [b 10]) (list a b)))))
  (check-equal? (ev "n + 1" env) 3.5)
  (check-equal? (ev "big / 1e30" env) 1)
  (check-equal? (ev "list.map(x => x * n)" env) '(2.5 5 7.5))
  (check-equal? (ev "obj.a + obj.b[0]" env) 3)
  (check-equal? (ev "({...obj, c: 3})" env) (jobject 'a 1 'b '(2) 'c 3))
  (check-equal? (ev "add(1, 2)" env) 3)
  ;; Extra arguments are dropped and missing ones are undefined, as in a JavaScript call.
  (check-equal? (ev "add(1, 2, 3)" env) 3)
  (check-equal? (ev "any(1, 2, 3)" env) 3)
  (check-equal? (ev "opt(1)" env) '(1 10))
  (check-equal? (ev "opt(1, 2, 3)" env) '(1 2))
  (check-equal? (ev "typeof add" env) "function")
  (check-equal? (ev "[1, 2].map(add)" env) '(1 3)))

(test-case "an exception from a host procedure passes through"
  (define env (make-js-env (hash "boom" (lambda () (raise-user-error 'boom "host failure")))))
  (define e (eval-error "boom()" env))
  (check-pred exn:fail:user? e)
  (check-false (exn:fail:js-expr? e)))

;; ---------------------------------------------------------------------------------------------
;; Errors

(test-case "run-time errors carry the JavaScript name, the source and the position"
  (define e (eval-error "({}).a.b"))
  (check-pred exn:fail:js-expr? e)
  (check-false (exn:fail:js-expr:unsupported? e))
  (check-equal? (exn:fail:js-expr-source e) "({}).a.b")
  (check-equal? (exn:fail:js-expr-position e) 6)
  (check-equal? (exn-message e)
                (string-append "TypeError: Cannot read properties of undefined (reading 'b')"
                               "\n  expression: ({}).a.b\n  position: 6"))
  (check-equal? (exn-message (eval-error "nope + 1"))
                "ReferenceError: nope is not defined\n  expression: nope + 1\n  position: 0")
  (check-equal? (exn-message (eval-error "'x'.missing()"))
                (string-append "TypeError: \"x\".missing is not a function"
                               "\n  expression: 'x'.missing()\n  position: 11"))
  (check-equal? (error-name "null.a") "TypeError")
  (check-equal? (error-name "undefined()") "TypeError")
  (check-equal? (error-name "(1)()") "TypeError")
  (check-equal? (error-name "new (x => x)()") "TypeError")
  (check-equal? (error-name "[...5]") "TypeError"))

(test-case "unsupported members are reported by name with the position"
  (define e (eval-error "1 + [3, 1].sort()[0]"))
  (check-pred exn:fail:js-expr:unsupported? e)
  (check-equal? (exn:fail:js-expr:unsupported-construct e) "Array.prototype.sort")
  (check-equal? (exn:fail:js-expr-position e) 15)
  (check-equal? (error-name "'abc'.match('b')") 'unsupported)
  (check-equal? (error-name "Math.random()") 'unsupported)
  (check-equal? (error-name "({}).toString()") 'unsupported)
  (check-equal? (error-name "(1.5).toString(2)") 'unsupported)
  (check-equal? (error-name "'a'.trim.call('b')") 'unsupported)
  (check-equal? (error-name "new Number(1)") 'unsupported)
  ;; A name JavaScript does not define reads as undefined.
  (check-pred void? (ev "'abc'.nope"))
  (check-pred void? (ev "[1].nope")))

(test-case "a syntax error from js-eval"
  (define e (eval-error "1 +"))
  (check-pred exn:fail:js-expr:syntax? e)
  (check-equal? (exn:fail:js-expr-position e) 3))

;; ---------------------------------------------------------------------------------------------
;; Fallback, expression nodes, interpolation

(test-case "the fallback is consulted before unsupported is raised, and only then"
  (define calls '())
  (define (fallback source env)
    (set! calls (cons source calls))
    (list 'delegated source))
  (parameterize ([current-js-fallback fallback])
    (check-equal? (ev "1 + 1") 2)
    (check-equal? (ev "2 ** 3") '(delegated "2 ** 3"))
    (check-equal? (ev "Date.now()") '(delegated "Date.now()"))
    (check-equal? (ev "[3, 1].sort()") '(delegated "[3, 1].sort()"))
    ;; Ordinary errors are not delegated.
    (check-equal? (error-name "nope") "ReferenceError")
    (check-equal? (error-name "1 +") "SyntaxError")
    ;; js-parse never consults it.
    (check-exn exn:fail:js-expr:unsupported? (lambda () (js-parse "2 ** 3"))))
  (check-equal? (reverse calls) '("2 ** 3" "Date.now()" "[3, 1].sort()"))
  (check-false (current-js-fallback))
  (check-equal? (error-name "2 ** 3") 'unsupported))

(test-case "the fallback receives the environment"
  (define env (make-js-env (hash "x" 7)))
  (parameterize ([current-js-fallback
                  (lambda (source env) (hash-ref (js-env-bindings env) "x"))])
    (check-equal? (ev "x ** 2" env) 7)))

(test-case "js-eval accepts an expression node and keeps its parse"
  (define e (make-js-expr "a + 1"))
  (check-equal? (js-eval e (make-js-env (hash "a" 1))) 2)
  (check-equal? (js-eval e (make-js-env (hash "a" 10))) 11)
  (check-equal? (js-expr-source e) "a + 1")
  (check-pred js-expr? e)
  (check-false (js-expr? "a + 1"))
  (check-equal? (make-js-expr "a") (make-js-expr "a"))
  (check-equal? (equal-hash-code (make-js-expr "a")) (equal-hash-code (make-js-expr "a"))))

(test-case "js-interpolate replaces the expression nodes inside a configuration"
  (define env (make-js-env (hash "port" 8080 "missing" (void))))
  (define config
    (jobject 'host "localhost"
             'port (make-js-expr "port + 1")
             'tags (list "a" (make-js-expr "'b'.toUpperCase()") (make-js-expr "missing"))
             'nested (jobject 'gone (make-js-expr "missing")
                              'kept (jobject '__jsExpr "port > 80"))))
  (define result (js-interpolate config env))
  (check-equal? (jkeys result) '(host port tags nested))
  (check-equal? (jref result 'port) 8081)
  ;; An array keeps an undefined element; an object drops an undefined member.
  (check-equal? (jref result 'tags) (list "a" "B" (void)))
  (check-equal? (jref result 'nested) (jobject 'kept #t))
  (check-equal? (js-interpolate (make-js-expr "port") env) 8080)
  (check-equal? (js-interpolate "port" env) "port")
  (check-equal? (js-interpolate (hash 'a (make-js-expr "1")) env) (jobject 'a 1)))
