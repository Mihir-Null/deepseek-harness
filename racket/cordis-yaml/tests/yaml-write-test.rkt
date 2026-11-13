#lang racket/base
;; Unit tests of the YAML writer: the layout of collections, which style each string gets,
;; numbers, expression nodes, the line width, the values it rejects, and the conversions between
;; expression nodes and dsh's `{"__jsExpr": source}` objects. js-yaml-table-test.rkt compares
;; the writer with js-yaml's dump on a few thousand values.

(require rackunit
         racket/match
         racket/string
         cordis-data
         cordis-yaml
         "support/table.rkt")

(define (u . codes) (list->string (map integer->char codes)))

(define (check-write v expected)
  (check-equal? (yaml->string v) expected))

;; ---------------------------------------------------------------------------------------------
;; Layout

(test-case "block style with two spaces per level"
  (check-write (jobject 'a 1 'b (jobject 'c 2 'd (jobject 'e 3)))
               "a: 1\nb:\n  c: 2\n  d:\n    e: 3\n")
  (check-write '(1 (2 3) ((4))) "- 1\n- - 2\n  - 3\n- - - 4\n")
  ;; A sequence under a key is indented by two; a mapping in a sequence starts on the dash.
  (check-write (jobject 'a '(1 2)) "a:\n  - 1\n  - 2\n")
  (check-write (list (jobject 'id "x" 'name "y") (jobject 'id "z"))
               "- id: x\n  name: 'y'\n- id: z\n")
  (check-write (jobject 'a (list (jobject 'b 1 'c '(2)))) "a:\n  - b: 1\n    c:\n      - 2\n"))

(test-case "empty collections and scalars at the top"
  (check-write '() "[]\n")
  (check-write empty-jobject "{}\n")
  (check-write (jobject 'a '() 'b empty-jobject) "a: []\nb: {}\n")
  (check-write (list '() empty-jobject) "- []\n- {}\n")
  (check-write 'null "null\n")
  (check-write #t "true\n")
  (check-write #f "false\n")
  (check-write "a" "a\n")
  (check-write 12 "12\n"))

(test-case "objects are written in their key order; a hash in sorted key order"
  (check-write (jobject 'zebra 1 'apple 2 '|10| 3 '|9| 4) "zebra: 1\napple: 2\n'10': 3\n'9': 4\n")
  (check-write (hash 'b 1 'a 2) "a: 2\nb: 1\n")
  (check-write (hash "b" (hash 'd 1 'c 2)) "b:\n  c: 2\n  d: 1\n"))

;; ---------------------------------------------------------------------------------------------
;; Strings

(test-case "plain strings"
  (for ([s '("a" "a b" "a:b" "a#b" "http://example.com/a?b=c#d" "deepseek-ai/dsh" "a'b" "a\"b" "x-y"
             "tru" "nul" "1a" "$HOME" "a,b" "(a)" "a]" "a}")])
    (check-equal? (yaml->string (list s)) (string-append "- " s "\n") s))
  (check-write (jobject 'a (u #xe9 #x1f600)) (string-append "a: " (u #xe9 #x1f600) "\n")))

(test-case "strings that would read back as another type are single-quoted"
  (for ([s '("true" "True" "TRUE" "false" "null" "Null" "~" "12" "-12" "012" "0x1F" "0o17" "0b11"
             "1.5" ".5" "1e3" ".inf" "-.inf" ".nan" "")])
    (check-equal? (yaml->string (list s)) (string-append "- '" s "'\n") s))
  ;; The YAML 1.1 booleans and base-60 numbers are quoted too, for older readers.
  (for ([s '("y" "Y" "yes" "Yes" "YES" "n" "no" "NO" "on" "On" "off" "OFF" "1:30" "190:20:30.15")])
    (check-equal? (yaml->string (list s)) (string-append "- '" s "'\n") s)))

(test-case "strings that start or end unsafely are single-quoted"
  (for ([s '(" a" "a " "- a" "-" "? a" ": a" "a: b" "a #b" "#a" "[a]" "{a}" "&a" "*a" "!a" "|a" ">a"
             "'a'" "\"a\"" "%a" "@a" "`a" "a:" ", a" "=")])
    (check-equal? (yaml->string (list s))
                  (string-append "- '" (string-replace s "'" "''") "'\n")
                  s)))

(test-case "strings with characters that cannot be written literally are double-quoted"
  (define bs (string #\\))
  (check-write (list "a\tb") (string-append "- \"a" bs "tb\"\n"))
  (check-write (list (u 0)) (string-append "- \"" bs "0\"\n"))
  (check-write (list (u 7 27)) (string-append "- \"" bs "a" bs "e\"\n"))
  (check-write (list (u #x61 #x0d #x62)) (string-append "- \"a" bs "rb\"\n"))
  (check-write (list (u #x85 #xa0)) (string-append "- \"" bs "N" bs "_\"\n"))
  (check-write (list (u #x2028 #x2029)) (string-append "- \"" bs "L" bs "P\"\n"))
  (check-write (list (u #xfeff)) (string-append "- \"" bs "uFEFF\"\n"))
  (check-write (list (u #x7f)) (string-append "- \"" bs "x7F\"\n"))
  (check-write (list (string-append "q\"" (u 9))) (string-append "- \"q" bs "\"" bs "t\"\n")))

(test-case "strings with line breaks are literal block scalars"
  (check-write (jobject 'a "x\ny") "a: |-\n  x\n  y\n")
  (check-write (jobject 'a "x\ny\n") "a: |\n  x\n  y\n")
  (check-write (jobject 'a "x\ny\n\n") "a: |+\n  x\n  y\n\n")
  (check-write (jobject 'a "x\n\ny") "a: |-\n  x\n\n  y\n")
  ;; A text that starts with a space needs the indentation indicator.
  (check-write (jobject 'a " x\ny") "a: |2-\n   x\n  y\n")
  (check-write (jobject 'a "\n x") "a: |2-\n\n   x\n")
  (check-write (list "x\ny\n") "- |\n  x\n  y\n")
  (check-write (jobject 'a (jobject 'b "x\ny\n")) "a:\n  b: |\n    x\n    y\n")
  ;; A key is never a block scalar.
  (check-write (make-jobject (list (cons (string->symbol "x\ny") 1)))
               (string-append "\"x" (string #\\) "ny\": 1\n")))

(test-case "long lines are folded at the line width"
  (define words (string-join (for/list ([i 20]) (format "word~a" i)) " "))
  (check-equal? (yaml->string (jobject 'a words))
                (string-append "a: >-\n"
                               "  word0 word1 word2 word3 word4 word5 word6 word7 word8 word9"
                               " word10 word11\n"
                               "  word12 word13 word14 word15 word16 word17 word18 word19\n"))
  (check-equal? (yaml->string (jobject 'a words) #:line-width #f)
                (string-append "a: " words "\n"))
  (check-equal? (yaml->string (jobject 'a "aaa bbb ccc ddd eee fff") #:line-width 10)
                "a: >-\n  aaa bbb\n  ccc ddd\n  eee fff\n")
  ;; The width left for a scalar shrinks with its indentation, down to min(line-width, 40):
  ;; at ten levels the 60 columns that remain allow ten words, at forty levels still seven.
  (define (nested depth v)
    (for/fold ([v v]) ([_ (in-range depth)]) (jobject 'k v)))
  (define (longest-line text)
    (apply max (map (lambda (line) (string-length (string-trim line)))
                    (string-split text "\n"))))
  (define sentence (string-join (for/list ([i 40]) "abcde") " "))
  (check-equal? (longest-line (yaml->string (nested 1 sentence))) 77)
  (check-equal? (longest-line (yaml->string (nested 10 sentence))) 59)
  (check-equal? (longest-line (yaml->string (nested 40 sentence))) 35)
  (check-equal? (longest-line (yaml->string (nested 60 sentence))) 35)
  ;; A long line without a space is a folded scalar too, with nowhere to break.
  (check-equal? (yaml->string (list (make-string 100 #\x)))
                (string-append "- >-\n  " (make-string 100 #\x) "\n")))

(test-case "reading a folded or literal scalar gives the string back"
  (for ([s (list "x\ny" "x\ny\n" "x\n\n\ny\n\n" " x\n  y\n z" "\n\nx"
                 (string-join (for/list ([i 40]) (format "w~a" i)) " ")
                 (string-append (string-join (for/list ([i 40]) "ab") " ") "\n\n"
                                (string-join (for/list ([i 40]) "cd") " ") "\n")
                 (string-append (string-join (for/list ([i 40]) "ab") " ")
                                "\n  indented line\nx"))])
    (for ([width (list 80 20 #f)])
      (check-equal? (yaml-read (yaml->string (jobject 'k s) #:line-width width)) (jobject 'k s)))))

;; ---------------------------------------------------------------------------------------------
;; Numbers and expression nodes

(test-case "numbers are written as JavaScript writes them"
  (check-write '(0 1 -1 100) "- 0\n- 1\n- -1\n- 100\n")
  (check-write '(1.5 -0.5 0.1) "- 1.5\n- -0.5\n- 0.1\n")
  ;; An integral flonum has no fraction in JavaScript.
  (check-write '(1.0 100.0) "- 1\n- 100\n")
  (check-write '(1e21 1e-7 5e-324) "- 1e+21\n- 1.e-7\n- 5.e-324\n")
  (check-write (list +inf.0 -inf.0 +nan.0 -0.0) "- .inf\n- -.inf\n- .nan\n- -0.0\n")
  (check-write (list (expt 2 53) (add1 (expt 2 53))) "- 9007199254740992\n- 9007199254740992\n")
  (check-write '(1/2) "- 0.5\n"))

(test-case "an expression node is written with the !!js tag"
  (check-write (jobject 'disabled (make-js-expr "!ctx.get('profileContext')"))
               "disabled: !!js '!ctx.get(''profileContext'')'\n")
  (check-write (list (make-js-expr "process.cwd()")) "- !!js process.cwd()\n")
  (check-write (make-js-expr "1 + 2") "!!js 1 + 2\n")
  (check-write (jobject 'a (make-js-expr "x ? y : z")) "a: !!js 'x ? y : z'\n")
  (check-write (jobject 'a (make-js-expr "true")) "a: !!js 'true'\n")
  (check-write (jobject 'a (make-js-expr "a +\nb")) "a: !!js |-\n  a +\n  b\n")
  (check-write (jobject 'a (make-js-expr "")) "a: !!js ''\n")
  ;; dsh's representation of an expression node is written the same way.
  (check-write (jobject 'a (jobject '__jsExpr "x.y")) "a: !!js x.y\n")
  (check-write (jobject 'a (hash '__jsExpr "x.y")) "a: !!js x.y\n")
  ;; A member that is not a string is no expression: the object is an ordinary mapping.
  (check-write (jobject 'a (jobject '__jsExpr 5)) "a:\n  __jsExpr: 5\n"))

(test-case "a very long key uses the explicit form"
  (define long-key (make-string 1025 #\k))
  (check-write (make-jobject (list (cons (string->symbol long-key) 1)))
               (string-append "? " long-key "\n: 1\n"))
  (check-write (make-jobject (list (cons (string->symbol (make-string 1024 #\k)) 1)))
               (string-append (make-string 1024 #\k) ": 1\n")))

;; ---------------------------------------------------------------------------------------------
;; Where js-yaml's own text does not read back

(test-case "root scalars that js-yaml writes in a form it cannot read are written otherwise"
  (define rows (table-rows (load-table) 'load))
  (define bs (string #\\))
  ;; (value text): the text this writer produces, which the table shows js-yaml reads to value.
  (for ([case (in-list
               (list (list "..." "'...'\n")
                     (list "... a" "'... a'\n")
                     (list (make-jobject (list (cons '|... a| "... a"))) "'... a': ... a\n")
                     (list "\n" (string-append "\"" bs "n\"\n"))
                     (list "\n\n" (string-append "\"" bs "n" bs "n\"\n"))
                     (list " a\nb" (string-append "\" a" bs "nb\"\n"))
                     (list "\n a" (string-append "\"" bs "n a\"\n"))
                     (list (make-js-expr "\n") (string-append "!!js \"" bs "n\"\n"))
                     (list (make-js-expr " a\nb") (string-append "!!js \" a" bs "nb\"\n"))
                     (list (make-js-expr "...") "!!js ...\n")))])
    (match-define (list value text) case)
    (check-equal? (yaml->string value) text)
    (check-equal? (yaml-read text) value)
    (match (assoc text rows)
      [(list _ (list 'ok expected))
       (check-true (same-datum? (value->datum value) expected) text)]
      [other (fail (format "the table has no js-yaml result for ~s" text))]))
  ;; Below the root these forms are safe, and are js-yaml's.
  (check-write (list "..." "\n" " a\nb") "- ...\n- |+\n\n- |2-\n   a\n  b\n")
  (check-write (jobject '... "...") "...: ...\n")
  (check-write (jobject 'a (jobject '|... a| 1)) "a:\n  ... a: 1\n"))

;; ---------------------------------------------------------------------------------------------
;; The interface

(test-case "yaml-write writes to a port and returns void"
  (define out (open-output-string))
  (check-pred void? (yaml-write (jobject 'a 1) out))
  (check-equal? (get-output-string out) "a: 1\n")
  (define default-out (open-output-string))
  (parameterize ([current-output-port default-out])
    (yaml-write '(1) #:line-width 40))
  (check-equal? (get-output-string default-out) "- 1\n"))

(test-case "values outside the model are rejected with their path, and nothing is written"
  (define (rejection v)
    (with-handlers ([exn:fail:contract? exn-message])
      (yaml->string v)
      #f))
  (check-regexp-match #rx"the top level" (rejection (void)))
  (check-regexp-match #rx"a > 1" (rejection (jobject 'a (list 1 'symbol))))
  (check-regexp-match #rx"0 > b" (rejection (list (jobject 'b (vector 1)))))
  (define out (open-output-string))
  (check-exn exn:fail:contract? (lambda () (yaml-write (list 1 2 (box 3)) out)))
  (check-equal? (get-output-string out) "")
  (check-exn exn:fail:contract? (lambda () (yaml->string '(1) #:line-width 0))))

(test-case "yaml-value?"
  (check-true (yaml-value? (jobject 'a (list 1 "x" #t 'null (make-js-expr "y") +inf.0 1.5))))
  (check-true (yaml-value? (hash 'a (hash "b" '()))))
  (check-false (yaml-value? (void)))
  (check-false (yaml-value? 'symbol))
  (check-false (yaml-value? (jobject 'a (list (vector)))))
  (check-false (yaml-value? (hash 1 2))))

(test-case "conversion between expression nodes and dsh's objects"
  (define v (jobject 'a (make-js-expr "x") 'b (list (make-js-expr "y") 1) 'c "z"))
  (define j (jobject 'a (jobject '__jsExpr "x") 'b (list (jobject '__jsExpr "y") 1) 'c "z"))
  (check-equal? (yaml-value->jvalue v) j)
  (check-true (jvalue? (yaml-value->jvalue v)))
  (check-equal? (jvalue->yaml-value j) v)
  (check-equal? (jvalue->yaml-value (string->jvalue "{\"disabled\":{\"__jsExpr\":\"!x\"}}"))
                (jobject 'disabled (make-js-expr "!x")))
  ;; Only a string member makes an expression node.
  (check-equal? (jvalue->yaml-value (jobject '__jsExpr 5)) (jobject '__jsExpr 5))
  (check-equal? (yaml-value->jvalue (hash 'a (make-js-expr "x")))
                (jobject 'a (jobject '__jsExpr "x"))))

(test-case "what is written reads back equal"
  (define v
    (list (jobject 'id "timer"
                   'name "@deepseek-ai/cordis-plugin-timer"
                   'disabled (make-js-expr "!ctx.get('profileContext')")
                   'config (jobject 'root '()
                                    'empty empty-jobject
                                    'text "line one\nline two\n"
                                    'quoted "yes"
                                    'number 1.5
                                    'flags (list #t #f 'null)
                                    'nested (list (list 1 2)
                                                  (jobject 'k (make-js-expr "a ? b : c")))))
          "plain"
          12))
  (check-equal? (yaml-read (yaml->string v)) v)
  (check-equal? (yaml->string (yaml-read (yaml->string v))) (yaml->string v)))
