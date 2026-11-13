#lang racket/base
;; Provides `parse-js-expression`: a hand-written tokenizer and a precedence-climbing parser for
;; the JavaScript expression subset of `!!js` nodes. The result is the S-expression AST that the
;; interface contract documents (plain lists, symbols, strings, numbers and booleans) and a
;; table from each AST node (by `eq?`) to the 0-based offset in the source where it starts or
;; where its operator stands.
;;
;; Text that is not JavaScript raises exn:fail:js-expr:syntax; JavaScript outside the subset
;; raises exn:fail:js-expr:unsupported with the name of the construct. Both carry the offset.

(require racket/list
         cordis-data
         "js-error.rkt"
         "js-value.rkt")

(provide parse-js-expression)

;; ---------------------------------------------------------------------------------------------
;; Tokens

;; type : 'num, 'str, 'id, 'kw, 'punct, 'backtick or 'eof. value : the number, the string
;; value, or the text of the identifier, keyword or punctuator. newline? : whether a line
;; terminator stands between the previous token and this one.
(struct token (type value start end newline?))

(define reserved-words
  '("break" "case" "catch" "class" "const" "continue" "debugger" "default" "delete" "do" "else"
    "enum" "export" "extends" "false" "finally" "for" "function" "if" "import" "in"
    "instanceof" "new" "null" "return" "super" "switch" "this" "throw" "true" "try" "typeof"
    "var" "void" "while" "with"))

;; Longest first, so that the first match is the token.
(define punctuators
  '(">>>=" "..." "===" "!==" "**=" "<<=" ">>=" ">>>" "&&=" "||=" "??="
    "=>" "==" "!=" "<=" ">=" "&&" "||" "??" "?." "++" "--" "+=" "-=" "*=" "/=" "%=" "&=" "|="
    "^=" "<<" ">>" "**"
    "{" "}" "(" ")" "[" "]" "." ";" "," "<" ">" "+" "-" "*" "/" "%" "&" "|" "^" "!" "~" "?"
    ":" "="))

(define (line-terminator? c)
  (memv c '(#\newline #\return #\u2028 #\u2029)))

(define (identifier-start? c)
  (or (char=? c #\$) (char=? c #\_)
      (memq (char-general-category c) '(lu ll lt lm lo nl))))

(define (identifier-part? c)
  (or (identifier-start? c)
      (memq (char-general-category c) '(mn mc nd pc))
      (char=? c #\u200C) (char=? c #\u200D)))

(define (digit? c) (char<=? #\0 c #\9))

(define (hex-value c)
  (cond [(char<=? #\0 c #\9) (- (char->integer c) 48)]
        [(char<=? #\a c #\f) (- (char->integer c) 87)]
        [(char<=? #\A c #\F) (- (char->integer c) 55)]
        [else #f]))

(define (prefix-at? src pos text)
  (define end (+ pos (string-length text)))
  (and (<= end (string-length src))
       (string=? (substring src pos end) text)))

;; skip-trivia : the offset of the next token at or after `pos`, and whether a line terminator
;; was passed.
(define (skip-trivia src pos)
  (define len (string-length src))
  (let loop ([i pos] [newline? #f])
    (cond
      [(= i len) (values i newline?)]
      [else
       (define c (string-ref src i))
       (cond
         [(line-terminator? c) (loop (add1 i) #t)]
         [(js-whitespace? c) (loop (add1 i) newline?)]
         [(prefix-at? src i "//")
          (let skip ([j (+ i 2)])
            (if (or (= j len) (line-terminator? (string-ref src j)))
                (loop j newline?)
                (skip (add1 j))))]
         [(prefix-at? src i "/*")
          (let skip ([j (+ i 2)] [newline? newline?])
            (cond [(> (+ j 2) len) (raise-js-syntax-error "unterminated comment" i)]
                  [(prefix-at? src j "*/") (loop (+ j 2) newline?)]
                  [else (skip (add1 j) (or newline? (and (line-terminator? (string-ref src j))
                                                         #t)))]))]
         [else (values i newline?)])])))

;; lex : the token at or after `pos`.
(define (lex src pos)
  (define-values (start newline?) (skip-trivia src pos))
  (define len (string-length src))
  (cond
    [(= start len) (token 'eof "end of input" start start newline?)]
    [else
     (define c (string-ref src start))
     (cond
       [(or (digit? c)
            (and (char=? c #\.) (< (add1 start) len) (digit? (string-ref src (add1 start)))))
        (lex-number src start newline?)]
       [(or (char=? c #\") (char=? c #\'))
        (define-values (value end) (lex-string src start))
        (token 'str value start end newline?)]
       [(char=? c #\`) (token 'backtick "`" start (add1 start) newline?)]
       [(identifier-start? c)
        (define end
          (let scan ([i (add1 start)])
            (if (and (< i len) (identifier-part? (string-ref src i))) (scan (add1 i)) i)))
        (when (and (< end len) (char=? (string-ref src end) #\\))
          (raise-js-unsupported "Unicode escape in an identifier" end))
        (define name (substring src start end))
        (token (if (member name reserved-words) 'kw 'id) name start end newline?)]
       [(char=? c #\\) (raise-js-unsupported "Unicode escape in an identifier" start)]
       ;; a?.5:b is a conditional, not an optional chain.
       [(and (prefix-at? src start "?.") (< (+ start 2) len) (digit? (string-ref src (+ start 2))))
        (token 'punct "?" start (add1 start) newline?)]
       [(for/first ([p (in-list punctuators)] #:when (prefix-at? src start p)) p)
        => (lambda (p) (token 'punct p start (+ start (string-length p)) newline?))]
       [else (raise-js-syntax-error "Invalid or unexpected token" start)])]))

;; Digits of a base with `_` separators allowed between digits; returns the digits without
;; separators and the offset after them.
(define (scan-digits src pos digit-ok?)
  (define len (string-length src))
  (let loop ([i pos] [acc '()] [last-separator? #f])
    (define c (and (< i len) (string-ref src i)))
    (cond
      [(and c (digit-ok? c)) (loop (add1 i) (cons c acc) #f)]
      [(and c (char=? c #\_))
       (when (or (null? acc) last-separator?)
         (raise-js-syntax-error "Numeric separators are not allowed here" i))
       (loop (add1 i) acc #t)]
      [else
       (when last-separator?
         (raise-js-syntax-error "Numeric separators are not allowed at the end of numeric literals"
                                (sub1 i)))
       (values (list->string (reverse acc)) i)])))

(define (lex-number src start newline?)
  (define len (string-length src))
  (define (char-at i) (and (< i len) (string-ref src i)))
  (define (radix-literal radix digit-ok?)
    (define-values (digits end) (scan-digits src (+ start 2) digit-ok?))
    (when (string=? digits "")
      (raise-js-syntax-error "Invalid or unexpected token" start))
    (values (normalize-number (string->number digits radix)) end))
  (define second (char-at (add1 start)))
  (define-values (value end)
    (cond
      [(and (char=? (string-ref src start) #\0) second (memv second '(#\x #\X)))
       (radix-literal 16 hex-value)]
      [(and (char=? (string-ref src start) #\0) second (memv second '(#\o #\O)))
       (radix-literal 8 (lambda (c) (char<=? #\0 c #\7)))]
      [(and (char=? (string-ref src start) #\0) second (memv second '(#\b #\B)))
       (radix-literal 2 (lambda (c) (char<=? #\0 c #\1)))]
      [(and (char=? (string-ref src start) #\0) second (char=? second #\_))
       (raise-js-syntax-error "Numeric separator can not be used after leading 0" start)]
      [(and (char=? (string-ref src start) #\0) second (digit? second))
       (raise-js-unsupported "legacy octal literal" start)]
      [else
       (define-values (whole after-whole)
         (if (char=? (string-ref src start) #\.)
             (values "" start)
             (scan-digits src start digit?)))
       (define-values (fraction after-fraction)
         (cond [(eqv? (char-at after-whole) #\.)
                (if (and (char-at (add1 after-whole)) (digit? (char-at (add1 after-whole))))
                    (scan-digits src (add1 after-whole) digit?)
                    (values "" (add1 after-whole)))]
               [else (values "" after-whole)]))
       (define-values (exponent after-exponent)
         (cond
           [(memv (char-at after-fraction) '(#\e #\E))
            (define sign-at (add1 after-fraction))
            (define signed? (memv (char-at sign-at) '(#\+ #\-)))
            (define-values (digits end)
              (scan-digits src (if signed? (add1 sign-at) sign-at) digit?))
            (when (string=? digits "")
              (raise-js-syntax-error "Invalid or unexpected token" after-fraction))
            (values (* (if (eqv? (char-at sign-at) #\-) -1 1) (string->number digits 10)) end)]
           [else (values 0 after-fraction)]))
       (values (decimal->number whole fraction exponent) after-exponent)]))
  (define next (char-at end))
  (when next
    (cond [(char=? next #\n) (raise-js-unsupported "BigInt literal" start)]
          [(or (identifier-start? next) (digit? next) (char=? next #\\))
           (raise-js-syntax-error "Invalid or unexpected token" end)]))
  (token 'num value start end newline?))

;; read-escape : reads the escape sequence whose backslash is at `pos`, writes what it stands
;; for to `out` and returns the offset after it. `template?` selects the template rules.
;; `pending-high` is a box that holds the offset and value of a \uD8xx escape still waiting
;; for its low half.
(define (read-escape src pos out template? pending-high)
  (define len (string-length src))
  (when (>= (add1 pos) len)
    (raise-js-syntax-error "Invalid or unexpected token" pos))
  (define c (string-ref src (add1 pos)))
  (define (simple replacement)
    (write-char replacement out)
    (+ pos 2))
  (define (hex-digits from count)
    (for/fold ([code 0]) ([i (in-range from (+ from count))])
      (define digit (and (< i len) (hex-value (string-ref src i))))
      (unless digit (raise-js-syntax-error "Invalid hexadecimal escape sequence" pos))
      (+ (* code 16) digit)))
  ;; Writes a code point, joining the two halves of a surrogate pair.
  (define (write-code! code end)
    (define high (unbox pending-high))
    (when (and high (not (<= #xDC00 code #xDFFF)))
      (raise-js-unsupported "lone surrogate in a string literal" (car high)))
    (cond
      [(and high (<= #xDC00 code #xDFFF))
       (set-box! pending-high #f)
       (write-char (integer->char (+ #x10000 (arithmetic-shift (- (cdr high) #xD800) 10)
                                     (- code #xDC00)))
                   out)]
      [(<= #xD800 code #xDBFF) (set-box! pending-high (cons pos code))]
      [(<= #xDC00 code #xDFFF)
       (raise-js-unsupported "lone surrogate in a string literal" pos)]
      [else (write-char (integer->char code) out)])
    end)
  (case c
    [(#\n) (simple #\newline)]
    [(#\t) (simple #\tab)]
    [(#\r) (simple #\return)]
    [(#\b) (simple #\backspace)]
    [(#\f) (simple #\page)]
    [(#\v) (simple #\vtab)]
    [(#\0)
     (cond [(and (< (+ pos 2) len) (digit? (string-ref src (+ pos 2))))
            (if template?
                (raise-js-syntax-error "Octal escape sequences are not allowed in template strings"
                                       pos)
                (raise-js-unsupported "legacy octal escape" pos))]
           [else (simple #\nul)])]
    [(#\1 #\2 #\3 #\4 #\5 #\6 #\7 #\8 #\9)
     (if template?
         (raise-js-syntax-error "Octal escape sequences are not allowed in template strings" pos)
         (raise-js-unsupported "legacy octal escape" pos))]
    [(#\x) (write-code! (hex-digits (+ pos 2) 2) (+ pos 4))]
    [(#\u)
     (cond
       [(and (< (+ pos 2) len) (char=? (string-ref src (+ pos 2)) #\{))
        (define close
          (let scan ([i (+ pos 3)])
            (cond [(>= i len) (raise-js-syntax-error "Invalid Unicode escape sequence" pos)]
                  [(char=? (string-ref src i) #\}) i]
                  [else (scan (add1 i))])))
        (when (= close (+ pos 3))
          (raise-js-syntax-error "Invalid Unicode escape sequence" pos))
        (define code (hex-digits (+ pos 3) (- close pos 3)))
        (when (> code #x10FFFF)
          (raise-js-syntax-error "Undefined Unicode code-point" pos))
        (write-code! code (add1 close))]
       [else (write-code! (hex-digits (+ pos 2) 4) (+ pos 6))])]
    [(#\return)
     ;; A line continuation; CR LF is one line terminator.
     (if (and (< (+ pos 2) len) (char=? (string-ref src (+ pos 2)) #\newline))
         (+ pos 3)
         (+ pos 2))]
    [(#\newline #\u2028 #\u2029) (+ pos 2)]
    [else (simple c)]))

(define (check-no-pending-high! pending-high)
  (define high (unbox pending-high))
  (when high
    (raise-js-unsupported "lone surrogate in a string literal" (car high))))

;; lex-string : the value of the string literal that starts at `start`, and the offset after it.
(define (lex-string src start)
  (define len (string-length src))
  (define delimiter (string-ref src start))
  (define out (open-output-string))
  (define pending-high (box #f))
  (let loop ([i (add1 start)])
    (when (= i len)
      (raise-js-syntax-error "Invalid or unexpected token (unterminated string literal)" start))
    (define c (string-ref src i))
    (cond
      [(char=? c delimiter)
       (check-no-pending-high! pending-high)
       (values (get-output-string out) (add1 i))]
      [(char=? c #\\)
       (define escape-is-unicode?
         (and (< (add1 i) len) (memv (string-ref src (add1 i)) '(#\u #\x))))
       (unless escape-is-unicode? (check-no-pending-high! pending-high))
       (loop (read-escape src i out #f pending-high))]
      [(or (char=? c #\newline) (char=? c #\return))
       (raise-js-syntax-error "Invalid or unexpected token (unterminated string literal)" start)]
      [else
       (check-no-pending-high! pending-high)
       (write-char c out)
       (loop (add1 i))])))

;; lex-template-chars : reads template text from `pos` to the closing backtick or to the next
;; `${`. Returns the cooked text, 'end or 'substitution, and the offset after the delimiter.
(define (lex-template-chars src pos start)
  (define len (string-length src))
  (define out (open-output-string))
  (define pending-high (box #f))
  (let loop ([i pos])
    (when (= i len)
      (raise-js-syntax-error "Unterminated template literal" start))
    (define c (string-ref src i))
    (cond
      [(char=? c #\`)
       (check-no-pending-high! pending-high)
       (values (get-output-string out) 'end (add1 i))]
      [(prefix-at? src i "${")
       (check-no-pending-high! pending-high)
       (values (get-output-string out) 'substitution (+ i 2))]
      [(char=? c #\\)
       (define escape-is-unicode?
         (and (< (add1 i) len) (memv (string-ref src (add1 i)) '(#\u #\x))))
       (unless escape-is-unicode? (check-no-pending-high! pending-high))
       (loop (read-escape src i out #t pending-high))]
      ;; CR and CR LF are cooked to LF.
      [(char=? c #\return)
       (check-no-pending-high! pending-high)
       (write-char #\newline out)
       (loop (if (and (< (add1 i) len) (char=? (string-ref src (add1 i)) #\newline))
                 (+ i 2)
                 (add1 i)))]
      [else
       (check-no-pending-high! pending-high)
       (write-char c out)
       (loop (add1 i))])))

;; ---------------------------------------------------------------------------------------------
;; Parser state

;; tok : the current token. positions : hasheq from AST node to offset. parens : hasheq whose
;; keys are the nodes written inside parentheses. arrow-start : the offset at which an arrow
;; function may begin, or #f; only the start of an assignment-level expression qualifies.
(struct ps (src [tok #:mutable] positions parens [arrow-start #:mutable]))

(define (peek p) (ps-tok p))
(define (advance! p) (set-ps-tok! p (lex (ps-src p) (token-end (ps-tok p)))))
(define (peek-after p) (lex (ps-src p) (token-end (ps-tok p))))

(define (token-is? t type value)
  (and (eq? (token-type t) type) (string=? (token-value t) value)))
(define (punct? p value) (token-is? (ps-tok p) 'punct value))
(define (keyword? p value) (token-is? (ps-tok p) 'kw value))

;; node : builds an AST node and records its position.
(define (node p position . parts)
  (hash-set! (ps-positions p) parts position)
  parts)

(define (describe-token t)
  (case (token-type t)
    [(eof) "end of input"]
    [(num) "number"]
    [(str) "string"]
    [(id) (format "identifier '~a'" (token-value t))]
    [(backtick) "template literal"]
    [else (format "token '~a'" (token-value t))]))

(define (unexpected p)
  (define t (peek p))
  (raise-js-syntax-error
   (if (eq? (token-type t) 'eof)
       "Unexpected end of input"
       (string-append "Unexpected " (describe-token t)))
   (token-start t)))

(define (expect-punct! p value)
  (unless (punct? p value) (unexpected p))
  (advance! p))

(define assignment-operators
  '("=" "+=" "-=" "*=" "/=" "%=" "**=" "<<=" ">>=" ">>>=" "&=" "|=" "^=" "&&=" "||=" "??="))

;; ---------------------------------------------------------------------------------------------
;; Expressions

;; An Expression where JavaScript allows the comma operator, which this subset does not have.
(define (parse-expression p)
  (define e (parse-assignment p))
  (when (punct? p ",")
    (raise-js-unsupported "comma operator" (token-start (peek p))))
  e)

(define (parse-assignment p)
  (set-ps-arrow-start! p (token-start (peek p)))
  (define e (parse-conditional p))
  (define t (peek p))
  (cond
    [(and (eq? (token-type t) 'punct) (member (token-value t) assignment-operators))
     (raise-js-unsupported (format "assignment operator ~a" (token-value t)) (token-start t))]
    [(punct? p "=>")
     (if (and (pair? e) (eq? (car e) 'call) (equal? (cadr e) '(id "async")))
         (raise-js-unsupported "async arrow function" (token-start t))
         (raise-js-syntax-error "Malformed arrow function parameter list" (token-start t)))]
    [else e]))

(define (parse-conditional p)
  (define test (parse-binary p 1))
  (cond
    [(punct? p "?")
     (define position (token-start (peek p)))
     (advance! p)
     (define consequent (parse-assignment p))
     (expect-punct! p ":")
     (define alternate (parse-assignment p))
     (node p position 'if test consequent alternate)]
    [else test]))

;; Binary operators: text -> (list precedence kind operator). kind is 'binary, 'logical or
;; 'unsupported.
(define binary-operators
  (hash "??" '(1 logical coalesce)
        "||" '(2 logical or)
        "&&" '(3 logical and)
        "|" '(4 unsupported "bitwise operator |")
        "^" '(5 unsupported "bitwise operator ^")
        "&" '(6 unsupported "bitwise operator &")
        "==" '(7 binary ==) "!=" '(7 binary !=) "===" '(7 binary ===) "!==" '(7 binary !==)
        "<" '(8 binary <) "<=" '(8 binary <=) ">" '(8 binary >) ">=" '(8 binary >=)
        "instanceof" '(8 unsupported "instanceof operator")
        "in" '(8 unsupported "in operator")
        "<<" '(9 unsupported "shift operator <<")
        ">>" '(9 unsupported "shift operator >>")
        ">>>" '(9 unsupported "shift operator >>>")
        "+" '(10 binary +) "-" '(10 binary -)
        "*" '(11 binary *) "/" '(11 binary /) "%" '(11 binary %)
        "**" '(12 unsupported "exponentiation operator **")))

(define (binary-operator t)
  (and (memq (token-type t) '(punct kw))
       (hash-ref binary-operators (token-value t) #f)))

(define (parse-binary p minimum)
  (let loop ([left (parse-unary p)])
    (define t (peek p))
    (define info (binary-operator t))
    (cond
      [(and info (>= (first info) minimum))
       (when (eq? (second info) 'unsupported)
         (raise-js-unsupported (third info) (token-start t)))
       (advance! p)
       (define right (parse-binary p (add1 (first info))))
       (loop (case (second info)
               [(logical)
                (check-coalesce-mix! p (third info) left right (token-start t))
                (node p (token-start t) (third info) left right)]
               [else (node p (token-start t) 'binary (third info) left right)]))]
      [else left])))

;; JavaScript does not let ?? share an expression with || or && without parentheses.
(define (check-coalesce-mix! p operator left right position)
  (define (bare? e kinds)
    (and (pair? e) (memq (car e) kinds) (not (hash-ref (ps-parens p) e #f))))
  (when (if (eq? operator 'coalesce)
            (or (bare? left '(or and)) (bare? right '(or and)))
            (or (bare? left '(coalesce)) (bare? right '(coalesce))))
    (raise-js-syntax-error "?? cannot be mixed with || or && without parentheses" position)))

(define (parse-unary p)
  (define t (peek p))
  (define (operand operator)
    (advance! p)
    (node p (token-start t) 'unary operator (parse-unary p)))
  (cond
    [(punct? p "!") (operand '!)]
    [(punct? p "-") (operand '-)]
    [(punct? p "+") (operand '+)]
    [(keyword? p "typeof") (operand 'typeof)]
    [(keyword? p "void") (operand 'void)]
    [(punct? p "~") (raise-js-unsupported "bitwise operator ~" (token-start t))]
    [(keyword? p "delete") (raise-js-unsupported "delete operator" (token-start t))]
    [(or (punct? p "++") (punct? p "--"))
     (raise-js-unsupported (format "update operator ~a" (token-value t)) (token-start t))]
    [else
     (define e (parse-left-hand-side p))
     (define after (peek p))
     (when (and (or (punct? p "++") (punct? p "--")) (not (token-newline? after)))
       (raise-js-unsupported (format "update operator ~a" (token-value after))
                             (token-start after)))
     e]))

(define (parse-left-hand-side p)
  (define base (if (keyword? p "new") (parse-new p) (parse-primary p)))
  (parse-chain p base #t))

(define (parse-new p)
  (define position (token-start (peek p)))
  (advance! p)
  (when (punct? p ".")
    (if (token-is? (peek-after p) 'id "target")
        (raise-js-unsupported "new.target" position)
        (unexpected p)))
  (define base (if (keyword? p "new") (parse-new p) (parse-primary p)))
  (define callee (parse-chain p base #f))
  (define arguments (if (punct? p "(") (parse-arguments p) '()))
  (apply node p position 'new callee arguments))

(define (property-name! p)
  (define t (peek p))
  (unless (memq (token-type t) '(id kw)) (unexpected p))
  (advance! p)
  (token-value t))

;; parse-chain : the member accesses and calls that follow `base`. With `calls?` false (the
;; callee of `new`) it stops before an argument list.
(define (parse-chain p base calls?)
  (let loop ([e base] [optional? #f])
    (define t (peek p))
    (define position (token-start t))
    (cond
      [(punct? p ".")
       (advance! p)
       (loop (node p position 'member e (property-name! p)) optional?)]
      [(punct? p "?.")
       (unless calls?
         (raise-js-syntax-error "Invalid optional chain from new expression" position))
       (advance! p)
       (cond
         [(punct? p "(")
          (loop (apply node p position 'opt-call e (parse-arguments p)) #t)]
         [(punct? p "[")
          (advance! p)
          (define key (parse-expression p))
          (expect-punct! p "]")
          (loop (node p position 'opt-index e key) #t)]
         [(eq? (token-type (peek p)) 'backtick)
          (raise-js-syntax-error "Invalid tagged template on optional chain" position)]
         [else (loop (node p position 'opt-member e (property-name! p)) #t)])]
      [(punct? p "[")
       (advance! p)
       (define key (parse-expression p))
       (expect-punct! p "]")
       (loop (node p position 'index e key) optional?)]
      [(and calls? (punct? p "("))
       (loop (apply node p position 'call e (parse-arguments p)) optional?)]
      [(eq? (token-type t) 'backtick)
       (if optional?
           (raise-js-syntax-error "Invalid tagged template on optional chain" position)
           (raise-js-unsupported "tagged template" position))]
      [optional? (node p (hash-ref (ps-positions p) e position) 'chain e)]
      [else e])))

;; parse-arguments : the argument list at the current "(", as a list of nodes.
(define (parse-arguments p)
  (expect-punct! p "(")
  (let loop ([arguments '()])
    (cond
      [(punct? p ")")
       (advance! p)
       (reverse arguments)]
      [else
       (define argument (parse-spread-or-assignment p))
       (cond [(punct? p ",") (advance! p)]
             [(not (punct? p ")"))
              (raise-js-syntax-error "missing ) after argument list" (token-start (peek p)))])
       (loop (cons argument arguments))])))

(define (parse-spread-or-assignment p)
  (cond
    [(punct? p "...")
     (define position (token-start (peek p)))
     (advance! p)
     (node p position 'spread (parse-assignment p))]
    [else (parse-assignment p)]))

(define (parse-primary p)
  (define t (peek p))
  (define position (token-start t))
  (case (token-type t)
    [(num)
     (advance! p)
     (node p position 'num (token-value t))]
    [(str)
     (advance! p)
     (node p position 'str (token-value t))]
    [(backtick) (parse-template p)]
    [(id)
     (define name (token-value t))
     (define after (peek-after p))
     (cond
       [(token-is? after 'punct "=>") (parse-arrow p (list t) position)]
       [(and (string=? name "async") (not (token-newline? after))
             (or (token-is? after 'kw "function") (eq? (token-type after) 'id)))
        (raise-js-unsupported "async function" position)]
       [else
        (advance! p)
        (if (string=? name "undefined")
            (node p position 'undefined)
            (node p position 'id name))])]
    [(kw)
     (define name (token-value t))
     (cond
       [(string=? name "true") (advance! p) (node p position 'bool #t)]
       [(string=? name "false") (advance! p) (node p position 'bool #f)]
       [(string=? name "null") (advance! p) (node p position 'null)]
       [(member name '("function" "class" "this" "super" "import"))
        (raise-js-unsupported
         (cond [(string=? name "function") "function expression"]
               [(string=? name "class") "class expression"]
               [else name])
         position)]
       [else (unexpected p)])]
    [(punct)
     (define text (token-value t))
     (cond
       [(string=? text "(") (parse-parenthesized p)]
       [(string=? text "[") (parse-array p)]
       [(string=? text "{") (parse-object p)]
       [(or (string=? text "/") (string=? text "/="))
        (raise-js-unsupported "regular expression literal" position)]
       [else (unexpected p)])]
    [else (unexpected p)]))

;; parse-arrow : the arrow function whose parameter tokens were read; the current token is
;; the last parameter (single-identifier form) or "=>" (parenthesized form).
(define (parse-arrow p parameters position)
  (unless (eqv? position (ps-arrow-start p))
    (raise-js-syntax-error "Malformed arrow function parameter list" position))
  (unless (punct? p "=>") (advance! p))
  (when (token-newline? (peek p))
    (raise-js-syntax-error "Unexpected token '=>'" (token-start (peek p))))
  (advance! p)
  (define names
    (for/list ([t (in-list parameters)])
      (define name (token-value t))
      (when (string=? name "undefined")
        (raise-js-unsupported "a parameter named undefined" (token-start t)))
      name))
  (when (check-duplicates names)
    (raise-js-syntax-error "Duplicate parameter name not allowed in this context" position))
  (when (punct? p "{")
    (raise-js-unsupported "arrow function with a block body" (token-start (peek p))))
  (define body (parse-assignment p))
  (node p position 'arrow names body))

;; "(" starts a parenthesized expression or the parameter list of an arrow function; which one
;; is known only at the token after the matching ")".
(define (parse-parenthesized p)
  (define open (peek p))
  (define position (token-start open))
  (advance! p)
  (define may-be-arrow? (eqv? position (ps-arrow-start p)))
  (cond
    [(punct? p ")")
     (advance! p)
     (unless (punct? p "=>") (unexpected p))
     (unless may-be-arrow?
       (raise-js-syntax-error "Malformed arrow function parameter list" position))
     (set-ps-arrow-start! p position)
     (parse-arrow p '() position)]
    [else
     ;; Each item is kept with the token it started at, to turn identifiers into parameters.
     (define items
       (let loop ([items '()])
         (define first-token (peek p))
         (when (punct? p "...")
           (raise-js-unsupported "rest parameter" (token-start first-token)))
         (define e (parse-assignment p))
         (define items* (cons (cons first-token e) items))
         (cond [(punct? p ",")
                (advance! p)
                (when (punct? p ")")
                  ;; (a, b,) is valid only as a parameter list.
                  (unless (token-is? (peek-after p) 'punct "=>") (unexpected p)))
                (if (punct? p ")") (reverse items*) (loop items*))]
               [else (reverse items*)])))
     (expect-punct! p ")")
     (cond
       [(punct? p "=>")
        (unless may-be-arrow?
          (raise-js-syntax-error "Malformed arrow function parameter list" position))
        (for ([item (in-list items)])
          (define e (cdr item))
          (define kind (and (pair? e) (car e)))
          (cond
            [(and (memq kind '(id undefined)) (not (hash-ref (ps-parens p) e #f))) (void)]
            [(memq kind '(object array))
             (raise-js-unsupported "destructuring parameter" (token-start (car item)))]
            [else
             (raise-js-syntax-error "Malformed arrow function parameter list"
                                    (token-start (car item)))]))
        (set-ps-arrow-start! p position)
        (parse-arrow p (map car items) position)]
       [(pair? (cdr items))
        (raise-js-unsupported "comma operator" position)]
       [else
        (define e (cdar items))
        (hash-set! (ps-parens p) e #t)
        e])]))

(define (parse-array p)
  (define position (token-start (peek p)))
  (advance! p)
  (let loop ([elements '()])
    (cond
      [(punct? p "]")
       (advance! p)
       (apply node p position 'array (reverse elements))]
      [(punct? p ",")
       (raise-js-unsupported "array hole" (token-start (peek p)))]
      [else
       (define element (parse-spread-or-assignment p))
       (cond [(punct? p ",") (advance! p)]
             [(not (punct? p "]")) (unexpected p)])
       (loop (cons element elements))])))

(define (parse-object p)
  (define position (token-start (peek p)))
  (advance! p)
  (let loop ([properties '()])
    (cond
      [(punct? p "}")
       (advance! p)
       (apply node p position 'object (reverse properties))]
      [else
       (define property (parse-property p))
       (cond [(punct? p ",") (advance! p)]
             [(not (punct? p "}")) (unexpected p)])
       (loop (cons property properties))])))

(define (parse-property p)
  (define t (peek p))
  (define position (token-start t))
  (define (value-after-colon)
    (expect-punct! p ":")
    (parse-assignment p))
  (define (reject-method!)
    (when (punct? p "(")
      (raise-js-unsupported "method in an object literal" position)))
  (cond
    [(punct? p "...")
     (advance! p)
     (node p position 'spread (parse-assignment p))]
    [(punct? p "*") (raise-js-unsupported "generator method in an object literal" position)]
    [(punct? p "[")
     (advance! p)
     (define key (parse-expression p))
     (expect-punct! p "]")
     (reject-method!)
     (node p position 'computed key (value-after-colon))]
    [(memq (token-type t) '(str num))
     (advance! p)
     (reject-method!)
     (define name (if (string? (token-value t)) (token-value t) (js-number->string (token-value t))))
     (node p position 'prop name (value-after-colon))]
    [(memq (token-type t) '(id kw))
     (define name (token-value t))
     (advance! p)
     (cond
       [(punct? p ":")
        (when (string=? name "__proto__")
          (raise-js-unsupported "__proto__ in an object literal" position))
        (node p position 'prop name (value-after-colon))]
       [(punct? p "(") (raise-js-unsupported "method in an object literal" position)]
       [(and (member name '("get" "set" "async" "static"))
             (or (memq (token-type (peek p)) '(id kw str num)) (punct? p "[") (punct? p "*")))
        (raise-js-unsupported
         (if (string=? name "async")
             "async method in an object literal"
             "getter or setter in an object literal")
         position)]
       [(and (eq? (token-type t) 'id) (or (punct? p ",") (punct? p "}")))
        (node p position 'prop name
              (if (string=? name "undefined")
                  (node p position 'undefined)
                  (node p position 'id name)))]
       [else (unexpected p)])]
    [else (unexpected p)]))

;; parse-template : the template literal at the current backtick.
(define (parse-template p)
  (define position (token-start (peek p)))
  (define src (ps-src p))
  (let loop ([at (token-end (peek p))] [parts '()])
    (define-values (text kind end) (lex-template-chars src at position))
    (define parts* (if (string=? text "") parts (cons text parts)))
    (case kind
      [(end)
       (set-ps-tok! p (lex src end))
       (apply node p position 'template (reverse parts*))]
      [else
       (set-ps-tok! p (lex src end))
       (define e (parse-expression p))
       (unless (punct? p "}") (unexpected p))
       (loop (token-end (peek p)) (cons e parts*))])))

;; ---------------------------------------------------------------------------------------------
;; Program

(define statement-keywords
  '("var" "const" "if" "for" "while" "do" "return" "throw" "try" "switch" "break" "continue"
    "debugger" "import" "export" "with" "function" "class"))

;; parse-js-expression : string? -> (values list? hash?)
;; The AST of `src` and the position table. An empty source is `(undefined)`, the value of
;; JavaScript's eval('').
(define (parse-js-expression src)
  (with-js-site src #f
    (define p (ps src (lex src 0) (make-hasheq) (make-hasheq) #f))
    (define first-token (peek p))
    (define ast
      (cond
        [(eq? (token-type first-token) 'eof) (node p 0 'undefined)]
        [else
         (reject-statement-start! p)
         (define e (parse-assignment p))
         (define t (peek p))
         (cond
           [(eq? (token-type t) 'eof) e]
           [(punct? p ",") (raise-js-unsupported "comma operator" (token-start t))]
           [(punct? p ";") (raise-js-unsupported "statement separator ;" (token-start t))]
           [(token-newline? t)
            (raise-js-unsupported "more than one statement" (token-start t))]
           [else (unexpected p)])]))
    (values ast (ps-positions p))))

;; eval() parses its text as statements, so these starts are not expressions.
(define (reject-statement-start! p)
  (define t (peek p))
  (define position (token-start t))
  (cond
    [(punct? p "{")
     (raise-js-unsupported "block statement (a source that starts with {)" position)]
    [(punct? p ";") (raise-js-unsupported "empty statement" position)]
    [(and (eq? (token-type t) 'kw) (member (token-value t) statement-keywords))
     (raise-js-unsupported (format "~a statement" (token-value t)) position)]
    [(and (token-is? t 'id "let")
          (let ([after (peek-after p)])
            (or (eq? (token-type after) 'id)
                (token-is? after 'punct "[")
                (token-is? after 'punct "{"))))
     (raise-js-unsupported "let declaration" position)]
    [(and (eq? (token-type t) 'id) (token-is? (peek-after p) 'punct ":"))
     (raise-js-unsupported "labelled statement" position)]
    [else (void)]))
