#lang racket/base
;; Unit tests of the YAML reader: how each kind of scalar resolves, the quoted and block scalar
;; styles, block and flow collections, anchors, tags, directives and document markers. The
;; expectations are written by hand from the interface contract; js-yaml-table-test.rkt holds
;; the same areas with results that js-yaml computed.

(require rackunit
         cordis-data
         cordis-yaml)

(define (u . codes) (list->string (map integer->char codes)))
(define bs (string #\\))

;; The value of the single key `k` in a one-entry mapping whose value is written as `text`.
(define (scalar text)
  (jref (yaml-read (string-append "k: " text)) 'k))

(define (check-read text expected)
  (check-equal? (yaml-read text) expected text))

;; ---------------------------------------------------------------------------------------------
;; Scalar resolution

(test-case "null"
  (for ([text '("~" "null" "Null" "NULL")])
    (check-equal? (scalar text) 'null text))
  (check-equal? (scalar "") 'null)
  (check-equal? (yaml-read "- \n- ~") '(null null))
  (for ([text '("nUll" "nil" "NIL" "None" "~~")])
    (check-equal? (scalar text) text text)))

(test-case "booleans"
  (for ([text '("true" "True" "TRUE")]) (check-equal? (scalar text) #t text))
  (for ([text '("false" "False" "FALSE")]) (check-equal? (scalar text) #f text))
  ;; YAML 1.1 booleans are strings in the JSON schema.
  (for ([text '("yes" "no" "on" "off" "y" "n" "Yes" "NO" "tRue" "T")])
    (check-equal? (scalar text) text text)))

(test-case "integers"
  (check-equal? (scalar "0") 0)
  (check-equal? (scalar "12") 12)
  (check-equal? (scalar "+12") 12)
  (check-equal? (scalar "-12") -12)
  (check-equal? (scalar "012") 12)
  (check-equal? (scalar "0x1F") 31)
  (check-equal? (scalar "0x1f") 31)
  (check-equal? (scalar "-0x1F") -31)
  (check-equal? (scalar "0o17") 15)
  (check-equal? (scalar "-0o17") -15)
  (check-equal? (scalar "0b101") 5)
  (check-equal? (scalar "+0b101") 5)
  (check-equal? (scalar "-0") 0)
  (check-pred exact-integer? (scalar "-0"))
  (check-pred exact-integer? (scalar "12"))
  ;; An integer of any size stays exact.
  (check-equal? (scalar "123456789012345678901234567890") 123456789012345678901234567890)
  (for ([text '("0o" "0x" "0b" "0o8" "0b2" "0xG" "0X1F" "0O17" "0B11" "1_000" "0x_1" "--1" "1-"
                "12abc" "+")])
    (check-equal? (scalar text) text text)))

(test-case "floats"
  (check-equal? (scalar "1.5") 1.5)
  (check-equal? (scalar "-1.5") -1.5)
  (check-equal? (scalar "+1.5") 1.5)
  (check-equal? (scalar "1.") 1.0)
  (check-equal? (scalar ".5") 0.5)
  (check-equal? (scalar "1e3") 1000.0)
  (check-equal? (scalar "1E3") 1000.0)
  (check-equal? (scalar "1e+3") 1000.0)
  (check-equal? (scalar "1e-3") 0.001)
  (check-equal? (scalar "1.5e3") 1500.0)
  (check-equal? (scalar ".5e1") 5.0)
  (check-equal? (scalar "0.0") 0.0)
  (check-equal? (scalar "-0.0") -0.0)
  (check-equal? (scalar "1.0") 1.0)
  (check-pred flonum? (scalar "1.0"))
  (check-equal? (scalar ".inf") +inf.0)
  (check-equal? (scalar ".Inf") +inf.0)
  (check-equal? (scalar ".INF") +inf.0)
  (check-equal? (scalar "-.inf") -inf.0)
  (check-equal? (scalar "+.inf") +inf.0)
  (check-true (eqv? (scalar ".nan") +nan.0))
  (check-true (eqv? (scalar ".NaN") +nan.0))
  (check-true (eqv? (scalar ".NAN") +nan.0))
  (check-equal? (scalar "0.30000000000000004") 0.30000000000000004)
  (check-equal? (scalar "5e-324") 5e-324)
  (check-equal? (scalar "1e-400") 0.0)
  ;; Too large for a double: js-yaml keeps the text.
  (check-equal? (scalar "1e400") "1e400")
  (for ([text '("-.5" "+.5" "1e" "e3" "1.5.5" "1_000.5" ".iNf" "-.nan" "inf" "nan" "Infinity" "NaN"
                "0x1.8" ".e3" "." "1..2")])
    (check-equal? (scalar text) text text)))

(test-case "plain strings"
  (check-equal? (scalar "a") "a")
  (check-equal? (scalar "a b") "a b")
  (check-equal? (scalar "a  b  ") "a  b")
  (check-equal? (scalar "a:b") "a:b")
  (check-equal? (scalar "a#b") "a#b")
  (check-equal? (scalar "a # comment") "a")
  (check-equal? (scalar "http://x:80/y?z#w") "http://x:80/y?z#w")
  (check-equal? (scalar "-a") "-a")
  (check-equal? (scalar "?a") "?a")
  (check-equal? (scalar ":a") ":a")
  (check-equal? (scalar "a, b") "a, b")
  (check-equal? (scalar "a [b] {c}") "a [b] {c}")
  (check-equal? (scalar (u #xe9 #x1f600)) (u #xe9 #x1f600))
  ;; A multi-line plain scalar folds: one line break is a space, two are one line break.
  (check-read "a\n b" "a b")
  (check-read "a\n\n b" "a\nb")
  (check-read "k: a\n  b\n\n\n  c" (jobject 'k "a b\n\nc"))
  (check-read "- a\n  b" '("a b")))

(test-case "scalars are immutable strings"
  (check-pred immutable? (yaml-read "'a'"))
  (check-pred immutable? (yaml-read "a")))

;; ---------------------------------------------------------------------------------------------
;; Quoted scalars

(test-case "single-quoted scalars"
  (check-read "''" "")
  (check-read "'a b'" "a b")
  (check-read "'it''s'" "it's")
  (check-read "''''" "'")
  (check-read "' a '" " a ")
  (check-read "'#'" "#")
  (check-read "'a: b'" "a: b")
  ;; Backslashes are literal, and typed-looking text stays a string.
  (check-read (string-append "'" bs "n'") (string-append bs "n"))
  (check-read "'true'" "true")
  (check-read "'12'" "12")
  (check-read "'~'" "~")
  (check-read "'a\nb'" "a b")
  (check-read "'a\n\nb'" "a\nb")
  (check-read "'a  \n  b'" "a b"))

(test-case "double-quoted scalars and their escapes"
  (define (dq body) (string-append "\"" body "\""))
  (define (escape text) (yaml-read (dq (string-append bs text))))
  (check-read (dq "") "")
  (check-read (dq "a b") "a b")
  (check-equal? (escape "0") (u 0))
  (check-equal? (escape "a") (u 7))
  (check-equal? (escape "b") (u 8))
  (check-equal? (escape "t") (u 9))
  (check-equal? (escape "\t") (u 9))
  (check-equal? (escape "n") (u 10))
  (check-equal? (escape "v") (u 11))
  (check-equal? (escape "f") (u 12))
  (check-equal? (escape "r") (u 13))
  (check-equal? (escape "e") (u 27))
  (check-equal? (escape " ") " ")
  (check-equal? (escape "\"") "\"")
  (check-equal? (escape "/") "/")
  (check-equal? (escape bs) bs)
  (check-equal? (escape "N") (u #x85))
  (check-equal? (escape "_") (u #xa0))
  (check-equal? (escape "L") (u #x2028))
  (check-equal? (escape "P") (u #x2029))
  (check-equal? (escape "x41") "A")
  (check-equal? (escape "u0041") "A")
  (check-equal? (escape "U00000041") "A")
  (check-equal? (escape "u263A") (u #x263a))
  (check-equal? (escape "U0001F600") (u #x1f600))
  ;; A surrogate pair written as two escapes is one character; a lone half is U+FFFD.
  (check-equal? (yaml-read (dq (string-append bs "uD83D" bs "uDE00"))) (u #x1f600))
  (check-equal? (escape "uD83D") (u #xfffd))
  (check-equal? (yaml-read (dq (string-append bs "uDE00x"))) (u #xfffd #x78))
  ;; A backslash at a line end joins the lines without a space.
  (check-read (dq (string-append "a" bs "\n  b")) "ab")
  (check-read (dq "a\n  b") "a b")
  (check-read (dq "a\n\n  b") "a\nb")
  (check-read (dq "true") "true")
  (check-read (dq "12") "12"))

;; ---------------------------------------------------------------------------------------------
;; Block scalars

(test-case "literal block scalars and chomping"
  (check-read "|\n a\n b" "a\nb\n")
  (check-read "|\n a\n b\n" "a\nb\n")
  (check-read "|-\n a\n b\n" "a\nb")
  (check-read "|+\n a\n b\n" "a\nb\n")
  (check-read "|+\n a\n\n\n" "a\n\n\n")
  (check-read "|-\n a\n\n\n" "a")
  (check-read "|\n a\n\n\n" "a\n")
  (check-read "|\n\n a" "\na\n")
  (check-read "|\n a\n\n b" "a\n\nb\n")
  ;; Indentation beyond the first line's is content.
  (check-read "|\n  a\n   b\n  c" "a\n b\nc\n")
  (check-read "k: |\n  a\n  b\nj: 1" (jobject 'k "a\nb\n" 'j 1))
  (check-read "- |\n  a\n- b" '("a\n" "b"))
  (check-read "k: |\n  # not a comment\n" (jobject 'k "# not a comment\n"))
  (check-read "k: | # a comment\n  a\n" (jobject 'k "a\n")))

(test-case "indentation indicators"
  (check-read "k: |2\n    a\n   b\n" (jobject 'k "  a\n b\n"))
  (check-read "k: |1\n  a" (jobject 'k " a\n"))
  ;; The chomping and indentation indicators come in either order.
  (check-read "k: |1-\n  a\n" (jobject 'k " a"))
  (check-read "k: |-1\n  a\n" (jobject 'k " a"))
  (check-read "k: |+2\n    a\n\n" (jobject 'k "  a\n\n"))
  (check-read "k: |2+\n    a\n\n" (jobject 'k "  a\n\n")))

(test-case "folded block scalars"
  (check-read ">\n a\n b" "a b\n")
  (check-read ">-\n a\n b\n" "a b")
  (check-read ">+\n a\n b\n\n" "a b\n\n")
  (check-read ">\n a\n\n b\n" "a\nb\n")
  (check-read ">\n a\n\n\n b\n" "a\n\nb\n")
  ;; A more indented line keeps its line breaks.
  (check-read ">\n a\n  b\n c\n" "a\n b\nc\n")
  (check-read "k: >\n  a\n  b\nj: 1" (jobject 'k "a b\n" 'j 1)))

;; ---------------------------------------------------------------------------------------------
;; Collections

(test-case "block mappings keep document order"
  (define v (yaml-read "zebra: 1\napple: 2\nmango: 3\n10: a\n9: b"))
  (check-pred jobject? v)
  (check-equal? (jkeys v) '(zebra apple mango |10| |9|))
  (check-equal? (jref v 'apple) 2)
  (check-read "a:\n  b:\n    c: 1" (jobject 'a (jobject 'b (jobject 'c 1))))
  (check-read "a: 1 # c\n# c\nb: 2" (jobject 'a 1 'b 2))
  (check-read "\"a b\": 1\n'c d': 2" (jobject '|a b| 1 '|c d| 2)))

(test-case "block sequences"
  (check-read "- a\n- b" '("a" "b"))
  (check-read "- - a\n  - b\n- c" '(("a" "b") "c"))
  (check-read "-\n  a" '("a"))
  (check-read "- a: 1\n  b: 2\n- c: 3" (list (jobject 'a 1 'b 2) (jobject 'c 3)))
  ;; A sequence may sit at the indentation of its parent mapping's key.
  (check-read "a:\n- 1\n- 2\nb: 3" (jobject 'a '(1 2) 'b 3))
  (check-read "a:\n  - 1\n  - 2" (jobject 'a '(1 2))))

(test-case "flow collections"
  (check-read "[]" '())
  (check-read "{}" empty-jobject)
  (check-read "[a, b, ]" '("a" "b"))
  (check-read "[a, [b, [c]]]" '("a" ("b" ("c"))))
  (check-read "{a: 1, b: [2, 3], c: {d: e}}" (jobject 'a 1 'b '(2 3) 'c (jobject 'd "e")))
  (check-read "{a, b: }" (jobject 'a 'null 'b 'null))
  (check-read "{\"a\":1}" (jobject 'a 1))
  ;; A pair inside a flow sequence is a one-entry mapping.
  (check-read "[a: 1, b]" (list (jobject 'a 1) "b"))
  (check-read "[\n  a,\n  b # c\n]" '("a" "b"))
  (check-read "k: [a, b]\nj: {c: d}" (jobject 'k '("a" "b") 'j (jobject 'c "d"))))

(test-case "mapping keys are JavaScript's String(key)"
  (check-equal? (jkeys (yaml-read "1: a\n1.5: b\n0x10: c\nnull: d\ntrue: e"))
                '(|1| |1.5| |16| null true))
  (check-equal? (jkeys (yaml-read "~: a")) '(null))
  (check-equal? (jkeys (yaml-read "'': a")) '(||))
  (check-equal? (jkeys (yaml-read "? [a, b]\n: c")) '(|a,b|))
  (check-equal? (jkeys (yaml-read "? {a: b}\n: c")) '(|[object Object]|))
  (check-read "? a\n: b" (jobject 'a "b"))
  (check-read "? a" (jobject 'a 'null))
  ;; The dsh schema has no merge key.
  (check-read "<<: {a: 1}\nb: 2" (jobject '<< (jobject 'a 1) 'b 2)))

;; ---------------------------------------------------------------------------------------------
;; Anchors, tags, directives, documents

(test-case "anchors and aliases"
  (check-read "a: &x 1\nb: *x" (jobject 'a 1 'b 1))
  (define v (yaml-read "a: &x [1, 2]\nb: *x"))
  (check-equal? v (jobject 'a '(1 2) 'b '(1 2)))
  ;; An alias is the anchored value itself.
  (check-eq? (jref v 'a) (jref v 'b))
  (check-read "- &x a\n- &y b\n- [*x, *y]" '("a" "b" ("a" "b")))
  (check-read "a: &x 1\nb: &x 2\nc: *x" (jobject 'a 1 'b 2 'c 2)))

(test-case "tags"
  (check-read "!!str 1" "1")
  (check-read "!!str true" "true")
  (check-read "!!str" "")
  (check-read "!!int \"12\"" 12)
  (check-read "!!int 0x1F" 31)
  (check-read "!!float 1" 1.0)
  (check-pred flonum? (yaml-read "!!float 1"))
  (check-read "!!bool \"false\"" #f)
  (check-read "!!null ~" 'null)
  (check-read "!!seq [a]" '("a"))
  (check-read "!!map {a: 1}" (jobject 'a 1))
  (check-read "!<tag:yaml.org,2002:str> 1" "1")
  ;; The non-specific tag keeps a scalar a string.
  (check-read "! 1" "1")
  (check-read "! true" "true"))

(test-case "the !!js tag reads an expression node and does not evaluate it"
  (define v (yaml-read "disabled: !!js \"!ctx.get('profileContext')\"\nn: !!js 1 + 2"))
  (check-pred js-expr? (jref v 'disabled))
  (check-equal? (js-expr-source (jref v 'disabled)) "!ctx.get('profileContext')")
  (check-equal? (js-expr-source (jref v 'n)) "1 + 2")
  ;; The source is the scalar's content after unquoting or folding.
  (check-equal? (js-expr-source (yaml-read "!!js 'it''s'")) "it's")
  (check-equal? (js-expr-source (yaml-read "!!js |\n  a +\n  b\n")) "a +\nb\n")
  (check-equal? (js-expr-source (yaml-read "!!js >\n  a +\n  b\n")) "a + b\n")
  (check-equal? (js-expr-source (yaml-read "!!js true")) "true")
  (check-equal? (js-expr-source (yaml-read "!<tag:yaml.org,2002:js> a + b")) "a + b")
  (check-equal? (yaml-read "[!!js a, !!js b]") (list (make-js-expr "a") (make-js-expr "b")))
  ;; Two nodes are equal when their sources are, whatever their locations.
  (check-equal? (yaml-read "!!js a") (yaml-read "\n\n  !!js a"))
  (check-not-equal? (yaml-read "!!js a") (yaml-read "!!js b"))
  (check-equal? (format "~a" (yaml-read "!!js 1 + 2")) "#<js-expr 1 + 2>"))

(test-case "an expression node records where its tag starts"
  (define v (yaml-read "a: 1\nb:\n  - !!js x\n" #:source "conf/cordis.yml"))
  (define loc (js-expr-srcloc (car (jref v 'b))))
  (check-equal? (srcloc-source loc) "conf/cordis.yml")
  (check-equal? (srcloc-line loc) 3)
  (check-equal? (srcloc-column loc) 4)
  (check-equal? (srcloc-position loc) 13)
  (check-false (js-expr-srcloc (make-js-expr "x"))))

(test-case "directives and document markers"
  (check-read "%YAML 1.2\n---\na" "a")
  (check-read "%TAG !e! tag:yaml.org,2002:\n---\n!e!str 1" "1")
  (check-read "--- a\n..." "a")
  (check-read "---\n- a" '("a"))
  (check-read "a\n...\n" "a"))

(test-case "documents"
  ;; No document: the empty text, or spaces and at most one line break.
  (check-pred void? (yaml-read ""))
  (check-pred void? (yaml-read "  "))
  (check-pred void? (yaml-read "\n"))
  (check-pred void? (yaml-read "  \n"))
  ;; An empty document.
  (check-equal? (yaml-read "# only a comment") 'null)
  (check-equal? (yaml-read "\n\n") 'null)
  (check-equal? (yaml-read "---") 'null)
  (check-equal? (yaml-read-all "") '())
  (check-equal? (yaml-read-all "a") '("a"))
  (check-equal? (yaml-read-all "a: 1\n---\n- b\n---\n!!js c")
                (list (jobject 'a 1) '("b") (make-js-expr "c")))
  (check-equal? (yaml-read-all "---\n---\n---") '(null null null)))

(test-case "inputs: strings, bytes, ports, line ends, byte order mark"
  (check-equal? (yaml-read #"a: 1") (jobject 'a 1))
  (check-equal? (yaml-read (open-input-string "a: 1")) (jobject 'a 1))
  (check-equal? (yaml-read (open-input-bytes (string->bytes/utf-8 (u #xfeff #x61 #x3a #x20 #xe9))))
                (jobject 'a (u #xe9)))
  ;; An invalid UTF-8 sequence becomes U+FFFD, as Node decodes a file.
  (check-equal? (yaml-read (bytes-append #"a: x" (bytes #xff) #"y"))
                (jobject 'a (u #x78 #xfffd #x79)))
  (check-equal? (yaml-read "a: 1\r\nb: 2\r\n") (jobject 'a 1 'b 2))
  (check-equal? (yaml-read "a: 1\rb: 2\r") (jobject 'a 1 'b 2))
  (check-equal? (yaml-read "a: |\r\n  x\r\n  y\r\n") (jobject 'a "x\ny\n")))

(test-case "the json schema has no !!js tag"
  (check-equal? (yaml-read "a: [1, yes, 0x10]" #:schema 'json) (jobject 'a '(1 "yes" 16)))
  (check-exn exn:fail:yaml? (lambda () (yaml-read "a: !!js b" #:schema 'json)))
  (check-pred js-expr? (jref (yaml-read "a: !!js b" #:schema 'entry-list) 'a)))

(test-case "a dsh patch file reads as dsh reads it"
  (define text
    (string-append
     "- insert:\n"
     "    id: timer\n"
     "    name: '@deepseek-ai/cordis-plugin-timer'\n"
     "    disabled: !!js \"!ctx.get('profileContext')\"\n"
     "    config:\n"
     "      root: []\n"
     "      permission: !!js process.env.DSH_PERMISSION_MODE ?? 'workspace-write'\n"
     "- id: sessions\n"
     "  config: {path: !!js \"dshHomePath('sessions')\", zstd: on, level: 010}\n"))
  (define v (yaml-read text))
  (check-equal? (jkeys (jref (car v) 'insert)) '(id name disabled config))
  (check-equal? (jref* v '(0 insert name)) "@deepseek-ai/cordis-plugin-timer")
  (check-equal? (jref* v '(0 insert config root)) '())
  (check-equal? (js-expr-source (jref* v '(0 insert config permission)))
                "process.env.DSH_PERMISSION_MODE ?? 'workspace-write'")
  (check-equal? (jref* v '(1 config zstd)) "on")
  (check-equal? (jref* v '(1 config level)) 10))
