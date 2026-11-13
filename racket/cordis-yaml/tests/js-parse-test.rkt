#lang racket/base
;; Unit tests of the `!!js` expression parser: the S-expression tree of each construct, operator
;; precedence, and the class, construct name and position of each rejection.

(require rackunit
         racket/match
         cordis-yaml/js-expr)

(define bs (string #\\))
(define (u . codes) (list->string (map integer->char codes)))

(define (check-ast source expected)
  (check-equal? (js-parse source) expected source))

;; (list 'syntax position), (list 'unsupported construct position), or the tree.
(define (parse-outcome source)
  (with-handlers ([exn:fail:js-expr:unsupported?
                   (lambda (e)
                     (list 'unsupported
                           (exn:fail:js-expr:unsupported-construct e)
                           (exn:fail:js-expr-position e)))]
                  [exn:fail:js-expr:syntax?
                   (lambda (e) (list 'syntax (exn:fail:js-expr-position e)))])
    (js-parse source)))

(define (check-syntax-error source position)
  (check-equal? (parse-outcome source) (list 'syntax position) source))

(define (check-unsupported source construct position)
  (check-equal? (parse-outcome source) (list 'unsupported construct position) source))

;; ---------------------------------------------------------------------------------------------
;; The tree

(test-case "the tree is plain quoted data"
  (check-ast "process.platform" '(member (id "process") "platform"))
  (check-ast "ctx.get('profileContext')?.name !== 'desktop'"
             '(binary !==
                      (chain (opt-member (call (member (id "ctx") "get") (str "profileContext"))
                                         "name"))
                      (str "desktop")))
  ;; It prints and reads back, and `match` takes it apart.
  (define ast (js-parse "process.env.DSH_MODEL ?? 'deepseek-v4-flash'"))
  (check-equal? (read (open-input-string (format "~s" ast))) ast)
  (check-equal? (match ast
                  [`(coalesce (member (member (id "process") "env") ,name) (str ,default))
                   (list name default)])
                '("DSH_MODEL" "deepseek-v4-flash"))
  ;; A tool can walk it: the environment variables an expression reads.
  (define (env-reads node)
    (match node
      [`(member (member (id "process") "env") ,name) (list name)]
      [(list _ parts ...) (apply append (map env-reads (filter pair? parts)))]
      [_ '()]))
  (check-equal? (env-reads (js-parse "process.env.A ?? (process.env.B ? 'x' : process.env.C)"))
                '("A" "B" "C")))

(test-case "number literals"
  (check-ast "1" '(num 1))
  (check-ast "1.5" '(num 1.5))
  (check-ast ".5" '(num 0.5))
  (check-ast "5." '(num 5))
  (check-ast "1e3" '(num 1000))
  (check-ast "1E-3" '(num 0.001))
  (check-ast "0x1F" '(num 31))
  (check-ast "0o17" '(num 15))
  (check-ast "0b101" '(num 5))
  (check-ast "1_000_000" '(num 1000000))
  ;; Integral and at most 2^53: exact. Otherwise a flonum.
  (check-ast "1.0" '(num 1))
  (check-ast "9007199254740992" '(num 9007199254740992))
  (check-ast "1e21" '(num 1e21))
  (check-ast "0.1" '(num 0.1))
  (check-ast "2e308" '(num +inf.0)))

(test-case "string literals and their escapes"
  (check-ast "'a'" '(str "a"))
  (check-ast "\"a\"" '(str "a"))
  (check-ast (string-append "'it" bs "'s'") '(str "it's"))
  (check-ast (string-append "'a" bs "nb" bs "tc'") '(str "a\nb\tc"))
  (check-ast (string-append "'" bs "x41" bs "u0042" bs "u{43}'") '(str "ABC"))
  (check-ast (string-append "'" bs "u{1F600}'") (list 'str (u #x1f600)))
  (check-ast (string-append "'" bs "uD83D" bs "uDE00'") (list 'str (u #x1f600)))
  (check-ast (string-append "'" bs "0'") (list 'str (u 0)))
  (check-ast (string-append "'" bs "q" bs bs "'") (list 'str (string-append "q" bs)))
  ;; A backslash before a line break continues the line.
  (check-ast (string-append "'a" bs "\nb'") '(str "ab")))

(test-case "template literals"
  (check-ast "`a`" '(template "a"))
  (check-ast "``" '(template))
  (check-ast "`a${b}c`" '(template "a" (id "b") "c"))
  (check-ast "`${a}${b}`" '(template (id "a") (id "b")))
  (check-ast "`a${`b${c}`}d`" '(template "a" (template "b" (id "c")) "d"))
  (check-ast "`${ {a: 1}.a }`" '(template (member (object (prop "a" (num 1))) "a")))
  (check-ast (string-append "`" bs "${a}" bs "n`") '(template "${a}\n")))

(test-case "keywords, identifiers, arrays and objects"
  (check-ast "true" '(bool #t))
  (check-ast "false" '(bool #f))
  (check-ast "null" '(null))
  (check-ast "undefined" '(undefined))
  (check-ast "NaN" '(id "NaN"))
  (check-ast "$a_1" '(id "$a_1"))
  (check-ast "" '(undefined))
  (check-ast "  // nothing\n" '(undefined))
  (check-ast "[]" '(array))
  (check-ast "[1, 'a', [b],]" '(array (num 1) (str "a") (array (id "b"))))
  (check-ast "[...a, 1]" '(array (spread (id "a")) (num 1)))
  (check-ast "({})" '(object))
  (check-ast "({a: 1, 'b c': 2, 3: d, [e]: f, g, ...h,})"
             '(object (prop "a" (num 1)) (prop "b c" (num 2)) (prop "3" (id "d"))
                      (computed (id "e") (id "f")) (prop "g" (id "g")) (spread (id "h"))))
  (check-ast "({default: 1, new: 2, 0x10: 3, 1.5: 4})"
             '(object (prop "default" (num 1)) (prop "new" (num 2)) (prop "16" (num 3))
                      (prop "1.5" (num 4)))))

(test-case "member access, calls, new and optional chains"
  (check-ast "a.b.c" '(member (member (id "a") "b") "c"))
  (check-ast "a[b]['c']" '(index (index (id "a") (id "b")) (str "c")))
  (check-ast "a.new.typeof" '(member (member (id "a") "new") "typeof"))
  (check-ast "f()" '(call (id "f")))
  (check-ast "f(a, ...b)" '(call (id "f") (id "a") (spread (id "b"))))
  (check-ast "a.b(c)(d)" '(call (call (member (id "a") "b") (id "c")) (id "d")))
  (check-ast "new URL(a, b)" '(new (id "URL") (id "a") (id "b")))
  (check-ast "new URL" '(new (id "URL")))
  (check-ast "new a.b.C(x).y" '(member (new (member (member (id "a") "b") "C") (id "x")) "y"))
  (check-ast "a?.b" '(chain (opt-member (id "a") "b")))
  (check-ast "a?.[b]" '(chain (opt-index (id "a") (id "b"))))
  (check-ast "a?.(b)" '(chain (opt-call (id "a") (id "b"))))
  ;; The chain node spans the links a short circuit skips, and stops at parentheses.
  (check-ast "a?.b.c(d)" '(chain (call (member (opt-member (id "a") "b") "c") (id "d"))))
  (check-ast "(a?.b).c" '(member (chain (opt-member (id "a") "b")) "c"))
  (check-ast "a.b?.c?.d" '(chain (opt-member (opt-member (member (id "a") "b") "c") "d")))
  (check-ast "f(a?.b)" '(call (id "f") (chain (opt-member (id "a") "b")))))

(test-case "operators and precedence"
  (check-ast "!a" '(unary ! (id "a")))
  (check-ast "-a" '(unary - (id "a")))
  (check-ast "+a" '(unary + (id "a")))
  (check-ast "typeof a" '(unary typeof (id "a")))
  (check-ast "void 0" '(unary void (num 0)))
  (check-ast "!!a" '(unary ! (unary ! (id "a"))))
  (check-ast "- -a" '(unary - (unary - (id "a"))))
  (check-ast "1 + 2 * 3" '(binary + (num 1) (binary * (num 2) (num 3))))
  (check-ast "(1 + 2) * 3" '(binary * (binary + (num 1) (num 2)) (num 3)))
  (check-ast "1 - 2 - 3" '(binary - (binary - (num 1) (num 2)) (num 3)))
  (check-ast "a / b % c" '(binary % (binary / (id "a") (id "b")) (id "c")))
  (check-ast "a < b === c >= d"
             '(binary === (binary < (id "a") (id "b")) (binary >= (id "c") (id "d"))))
  (check-ast "a == b != c" '(binary != (binary == (id "a") (id "b")) (id "c")))
  (check-ast "a + b < c" '(binary < (binary + (id "a") (id "b")) (id "c")))
  (check-ast "a || b && c" '(or (id "a") (and (id "b") (id "c"))))
  (check-ast "a && b || c" '(or (and (id "a") (id "b")) (id "c")))
  (check-ast "a ?? b ?? c" '(coalesce (coalesce (id "a") (id "b")) (id "c")))
  (check-ast "(a || b) ?? c" '(coalesce (or (id "a") (id "b")) (id "c")))
  (check-ast "a === b || !c" '(or (binary === (id "a") (id "b")) (unary ! (id "c"))))
  (check-ast "!a.b" '(unary ! (member (id "a") "b")))
  (check-ast "-a * b" '(binary * (unary - (id "a")) (id "b")))
  (check-ast "typeof a === 'string'" '(binary === (unary typeof (id "a")) (str "string"))))

(test-case "the conditional operator"
  (check-ast "a ? b : c" '(if (id "a") (id "b") (id "c")))
  (check-ast "a ? b : c ? d : e" '(if (id "a") (id "b") (if (id "c") (id "d") (id "e"))))
  (check-ast "a ? b ? c : d : e" '(if (id "a") (if (id "b") (id "c") (id "d")) (id "e")))
  (check-ast "a || b ? c : d" '(if (or (id "a") (id "b")) (id "c") (id "d")))
  (check-ast "a ?? b ? c : d" '(if (coalesce (id "a") (id "b")) (id "c") (id "d")))
  ;; "?." before a digit is the conditional operator and a number.
  (check-ast "a ?.5 : 1" '(if (id "a") (num 0.5) (num 1))))

(test-case "arrow functions"
  (check-ast "x => x" '(arrow ("x") (id "x")))
  (check-ast "(x) => x + 1" '(arrow ("x") (binary + (id "x") (num 1))))
  (check-ast "() => 1" '(arrow () (num 1)))
  (check-ast "(a, b) => a" '(arrow ("a" "b") (id "a")))
  (check-ast "(a, b,) => a" '(arrow ("a" "b") (id "a")))
  (check-ast "x => y => x" '(arrow ("x") (arrow ("y") (id "x"))))
  (check-ast "x => ({a: x})" '(arrow ("x") (object (prop "a" (id "x")))))
  (check-ast "a.map((v) => v.trim())"
             '(call (member (id "a") "map") (arrow ("v") (call (member (id "v") "trim")))))
  (check-ast "a ? x => 1 : y => 2" '(if (id "a") (arrow ("x") (num 1)) (arrow ("y") (num 2)))))

(test-case "comments and white space"
  (check-ast "1 /* a */ + // b\n 2" '(binary + (num 1) (num 2)))
  (check-ast "a\n.b\n(c)" '(call (member (id "a") "b") (id "c")))
  (check-ast (string-append (u #xfeff #xa0) "1" (u #x2028)) '(num 1)))

;; ---------------------------------------------------------------------------------------------
;; Rejections

(test-case "syntax errors carry the position of the offending token"
  (check-syntax-error "1 +" 3)
  (check-syntax-error "(1" 2)
  (check-syntax-error "1)" 1)
  (check-syntax-error "a b" 2)
  (check-syntax-error "a." 2)
  (check-syntax-error "a ? b" 5)
  (check-syntax-error "'abc" 0)
  (check-syntax-error "`abc" 0)
  (check-syntax-error "1.toString()" 2)
  ;; The position is that of the "??" that is mixed with "||" or "&&".
  (check-syntax-error "a ?? b || c" 2)
  (check-syntax-error "a || b ?? c" 7)
  (check-syntax-error "a && b ?? c" 7)
  (check-syntax-error "(1) => 1" 1)
  (check-syntax-error "a || x => x" 5)
  (check-syntax-error "({a 1})" 4)
  (check-syntax-error "[1 2]" 3)
  (check-syntax-error "f(a b)" 4)
  (check-syntax-error "@" 0)
  (check-syntax-error "1_" 1)
  (check-syntax-error "0x" 0)
  (check-syntax-error (string-append "'" bs "u00'") 1)
  (check-syntax-error "/* open" 0)
  (check-syntax-error "new a?.b()" 5)
  (check-syntax-error "(a, a) => 1" 0))

(test-case "an error says what it is about and shows the source"
  (define e (with-handlers ([exn:fail:js-expr? values]) (js-parse "ctx.get(")))
  (check-pred exn:fail:js-expr:syntax? e)
  (check-equal? (exn:fail:js-expr-source e) "ctx.get(")
  (check-equal? (exn:fail:js-expr-position e) 8)
  (check-equal? (exn-message e)
                "SyntaxError: Unexpected end of input\n  expression: ctx.get(\n  position: 8"))

(test-case "JavaScript outside the subset is unsupported, by name and position"
  (check-unsupported "a = 1" "assignment operator =" 2)
  (check-unsupported "a += 1" "assignment operator +=" 2)
  (check-unsupported "a ??= 1" "assignment operator ??=" 2)
  (check-unsupported "a++" "update operator ++" 1)
  (check-unsupported "--a" "update operator --" 0)
  (check-unsupported "1, 2" "comma operator" 1)
  (check-unsupported "(1, 2)" "comma operator" 0)
  (check-unsupported "a[1, 2]" "comma operator" 3)
  (check-unsupported "1; 2" "statement separator ;" 1)
  (check-unsupported "1\n2" "more than one statement" 2)
  (check-unsupported "{ a: 1 }" "block statement (a source that starts with {)" 0)
  (check-unsupported "var a = 1" "var statement" 0)
  (check-unsupported "let a = 1" "let declaration" 0)
  (check-unsupported "if (a) b" "if statement" 0)
  (check-unsupported "function f() {}" "function statement" 0)
  (check-unsupported "a: 1" "labelled statement" 0)
  (check-unsupported "(function () {})" "function expression" 1)
  (check-unsupported "(class {})" "class expression" 1)
  (check-unsupported "() => { return 1 }" "arrow function with a block body" 6)
  (check-unsupported "async () => 1" "async arrow function" 9)
  (check-unsupported "async x => x" "async function" 0)
  (check-unsupported "(...a) => 1" "rest parameter" 1)
  (check-unsupported "({a}) => a" "destructuring parameter" 1)
  (check-unsupported "(undefined) => 1" "a parameter named undefined" 1)
  (check-unsupported "a.b(/x/)" "regular expression literal" 4)
  (check-unsupported "f`a`" "tagged template" 1)
  (check-unsupported "this.a" "this" 0)
  (check-unsupported "new.target" "new.target" 0)
  (check-unsupported "delete a.b" "delete operator" 0)
  (check-unsupported "'a' in b" "in operator" 4)
  (check-unsupported "a instanceof b" "instanceof operator" 2)
  (check-unsupported "2 ** 3" "exponentiation operator **" 2)
  (check-unsupported "1 | 2" "bitwise operator |" 2)
  (check-unsupported "1 & 2" "bitwise operator &" 2)
  (check-unsupported "1 ^ 2" "bitwise operator ^" 2)
  (check-unsupported "~1" "bitwise operator ~" 0)
  (check-unsupported "1 << 2" "shift operator <<" 2)
  (check-unsupported "8 >>> 1" "shift operator >>>" 2)
  (check-unsupported "1n" "BigInt literal" 0)
  (check-unsupported "017" "legacy octal literal" 0)
  (check-unsupported (string-append "'" bs "07'") "legacy octal escape" 1)
  (check-unsupported (string-append "'" bs "uD83D'") "lone surrogate in a string literal" 1)
  (check-unsupported (string-append "a" bs "u0062") "Unicode escape in an identifier" 1)
  (check-unsupported "[1, , 2]" "array hole" 4)
  (check-unsupported "({ f() {} })" "method in an object literal" 3)
  (check-unsupported "({ get a() { return 1 } })" "getter or setter in an object literal" 3)
  (check-unsupported "({ __proto__: null })" "__proto__ in an object literal" 3))

(test-case "the message of an unsupported construct names it"
  (define e (with-handlers ([exn:fail:js-expr? values]) (js-parse "a.b = 1")))
  (check-pred exn:fail:js-expr:unsupported? e)
  (check-equal? (exn:fail:js-expr:unsupported-construct e) "assignment operator =")
  (check-equal? (exn-message e)
                (string-append "unsupported JavaScript in a !!js expression: assignment operator ="
                               "\n  expression: a.b = 1\n  position: 4")))
