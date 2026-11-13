#lang racket/base
;; Provides `dump-yaml`: the YAML writer. It follows js-yaml's dumper with the options dsh uses
;; (`{ schema: entryListSchema, noRefs: true, lineWidth }`), so its text is the text
;; `yaml.dump` produces for the same data: block collections, two spaces per level, the same
;; choice among plain, single-quoted, double-quoted, literal and folded scalars.
;; source: js-yaml 4.3.2 lib/dumper.js; vendor/include/src/index.ts (the `!!js` type)
;;
;; Widths are counted in UTF-16 code units, as js-yaml counts them.

(require racket/list
         racket/string
         cordis-data
         "expr.rkt"
         "yaml-scalar.rkt")

(provide dump-yaml
         yaml-value?)

(define indent-per-level 2)

;; ---------------------------------------------------------------------------------------------
;; The accepted values

(define (special-flonum? v)
  (and (flonum? v) (or (eqv? v +inf.0) (eqv? v -inf.0) (eqv? v +nan.0))))

(define (object? v) (or (jobject? v) (hash? v)))

;; yaml-value? : any/c -> boolean?
;; Whether the writer accepts `v`: a jvalue, a js-expr, one of the three special flonums, or a
;; list or object of such values.
(define (yaml-value? v)
  (cond [(or (string? v) (boolean? v) (eq? v 'null) (js-expr? v)) #t]
        [(real? v) #t]
        [(list? v) (andmap yaml-value? v)]
        [(jobject? v) (for/and ([(k item) (in-jobject v)]) (yaml-value? item))]
        [(hash? v)
         (for/and ([(k item) (in-hash v)])
           (and (or (symbol? k) (string? k)) (yaml-value? item)))]
        [else #f]))

;; An object with a string `__jsExpr` member is an expression node in dsh's representation.
(define (marker-source v)
  (and (object? v)
       (let ([source (jref v '__jsExpr #f)])
         (and (string? source) source))))

;; ---------------------------------------------------------------------------------------------
;; Character classes

(define (printable? n)
  (or (<= #x20 n #x7E)
      (and (<= #xA1 n #xD7FF) (not (= n #x2028)) (not (= n #x2029)))
      (and (<= #xE000 n #xFFFD) (not (= n #xFEFF)))
      (<= #x10000 n #x10FFFF)))

(define (ns-char-or-whitespace? n)
  (and n (printable? n) (not (= n #xFEFF)) (not (= n 13)) (not (= n 10))))

(define (blank? n) (or (= n 32) (= n 9)))

;; Whether code point `c` may continue a plain scalar after `prev` (#f at the start).
(define (plain-safe? c prev in-block?)
  (define c-ok? (ns-char-or-whitespace? c))
  (define c-ns? (and c-ok? (not (blank? c))))
  (or (and (if in-block?
               c-ok?
               (and c-ok? (not (memv c '(44 91 93 123 125)))))
           (not (= c 35))
           (not (and (eqv? prev 58) (not c-ns?))))
      (and (ns-char-or-whitespace? prev) (not (blank? prev)) (= c 35))
      (and (eqv? prev 58) c-ns?)))

;; Code points of the indicators that cannot start a plain scalar.
(define indicator-codes
  (map char->integer (string->list "-?:,[]{}#&*!|=>'\"%@`")))

;; Whether code point `c` may start a plain scalar: printable, not blank, not an indicator.
(define (plain-safe-first? c)
  (and (printable? c)
       (not (= c #xFEFF))
       (not (blank? c))
       (not (memv c indicator-codes))))

(define (plain-safe-last? c)
  (and (not (blank? c)) (not (= c 58))))

(define (utf16-width c) (if (>= c #x10000) 2 1))

;; ---------------------------------------------------------------------------------------------
;; Scalars

(define deprecated-booleans
  '("y" "Y" "yes" "Yes" "YES" "on" "On" "ON" "n" "N" "no" "No" "NO" "off" "Off" "OFF"))

(define deprecated-base60 #px"^[-+]?[0-9_]+(?::[0-9_]+)+(?:\\.[0-9_]*)?$")

;; choose-scalar-style : the style js-yaml picks for a non-empty string: 'plain, 'single,
;; 'literal, 'folded or 'double. `line-width` is #f for no limit.
(define (choose-scalar-style str single-line-only? line-width in-block?)
  (define len (string-length str))
  (define first-code (char->integer (string-ref str 0)))
  (define last-code (char->integer (string-ref str (sub1 len))))
  (let loop ([i 0]                    ; character index
             [units 0]                ; UTF-16 offset of character i
             [prev #f]
             [plain? (and (plain-safe-first? first-code) (plain-safe-last? last-code))]
             [has-line-break? #f]
             [has-foldable-line? #f]
             [previous-break -1]      ; UTF-16 offset of the last line break
             [after-break 0])         ; character index after the last line break
    ;; A line is foldable when it is longer than the width and does not start with a space.
    (define (foldable-line?)
      (and line-width
           (> (- units previous-break 1) line-width)
           (not (and (< after-break len) (char=? (string-ref str after-break) #\space)))))
    (cond
      [(= i len)
       (define foldable? (or has-foldable-line? (and (not single-line-only?) (foldable-line?))))
       (cond
         [(and (not has-line-break?) (not foldable?))
          (if (and plain? (not (resolves-implicitly? str))) 'plain 'single)]
         [foldable? 'folded]
         [else 'literal])]
      [else
       (define c (char->integer (string-ref str i)))
       (cond
         [(and (not single-line-only?) (= c 10))
          (loop (add1 i) (add1 units) c (and plain? (plain-safe? c prev in-block?))
                #t (or has-foldable-line? (foldable-line?)) units (add1 i))]
         [(not (printable? c)) 'double]
         [else
          (loop (add1 i) (+ units (utf16-width c)) c (and plain? (plain-safe? c prev in-block?))
                has-line-break? has-foldable-line? previous-break after-break)])])))

(define (need-indent-indicator? str)
  (regexp-match? #rx"^\n* " str))

(define (block-header str)
  (define len (string-length str))
  (define clip? (char=? (string-ref str (sub1 len)) #\newline))
  (define keep?
    (and clip?
         (or (string=? str "\n")
             (and (>= len 2) (char=? (string-ref str (- len 2)) #\newline)))))
  (string-append (if (need-indent-indicator? str) (number->string indent-per-level) "")
                 (cond [keep? "+"] [clip? ""] [else "-"])
                 "\n"))

(define (drop-ending-newline str)
  (define len (string-length str))
  (if (and (positive? len) (char=? (string-ref str (sub1 len)) #\newline))
      (substring str 0 (sub1 len))
      str))

;; Indents every line of `str`; a line that is only a line break stays empty.
(define (indent-string str spaces)
  (define pad (make-string spaces #\space))
  (define len (string-length str))
  (define out (open-output-string))
  (let loop ([position 0])
    (when (< position len)
      (define next
        (let find ([i position])
          (cond [(= i len) #f]
                [(char=? (string-ref str i) #\newline) i]
                [else (find (add1 i))])))
      (define end (if next (add1 next) len))
      (unless (and (= (- end position) 1) (char=? (string-ref str position) #\newline))
        (write-string pad out))
      (write-string str out position end)
      (loop end)))
  (get-output-string out))

;; fold-line : breaks one line at spaces so that each piece is at most `width` UTF-16 units
;; where a break point allows it. A line that starts with a space cannot be folded.
(define (fold-line line width)
  (cond
    [(or (string=? line "") (char=? (string-ref line 0) #\space)) line]
    [else
     (define len (string-length line))
     ;; units[i] is the UTF-16 offset of character i.
     (define units
       (let ([v (make-vector (add1 len) 0)])
         (for ([i (in-range len)])
           (vector-set! v (add1 i)
                        (+ (vector-ref v i) (utf16-width (char->integer (string-ref line i))))))
         v))
     (define (distance from to) (- (vector-ref units to) (vector-ref units from)))
     (define out (open-output-string))
     (define-values (start curr)
       (for/fold ([start 0] [curr 0])
                 ([match (in-list (regexp-match-positions* #rx" [^ ]" line))])
         (define next (car match))
         (cond
           [(> (distance start next) width)
            (define end (if (> curr start) curr next))
            (write-string "\n" out)
            (write-string line out start end)
            (values (add1 end) next)]
           [else (values start next)])))
     (write-string "\n" out)
     (cond
       [(and (> (distance start len) width) (> curr start))
        (write-string line out start curr)
        (write-string "\n" out)
        (write-string line out (add1 curr) len)]
       [else (write-string line out start len)])
     ;; The first piece was written after a joining line break too.
     (substring (get-output-string out) 1)]))

;; fold-string : the folded-style text of `str`: in a folded scalar one line break between two
;; ordinary lines reads back as a space, so each is doubled.
(define (fold-string str width)
  (define len (string-length str))
  (define first-end
    (or (for/first ([c (in-string str)] [i (in-naturals)] #:when (char=? c #\newline)) i)
        len))
  (define out (open-output-string))
  (write-string (fold-line (substring str 0 first-end) width) out)
  (for/fold ([prev-more-indented? (or (char=? (string-ref str 0) #\newline)
                                      (char=? (string-ref str 0) #\space))])
            ([match (in-list (regexp-match* #rx"(\n+)([^\n]*)" str first-end
                                            #:match-select cdr))])
    (define prefix (first match))
    (define line (second match))
    (define more-indented? (and (positive? (string-length line))
                                (char=? (string-ref line 0) #\space)))
    (write-string prefix out)
    (when (and (not prev-more-indented?) (not more-indented?) (not (string=? line "")))
      (write-string "\n" out))
    (write-string (fold-line line width) out)
    more-indented?)
  (get-output-string out))

(define escape-sequences
  (hasheqv #x00 "\\0" #x07 "\\a" #x08 "\\b" #x09 "\\t" #x0A "\\n" #x0B "\\v" #x0C "\\f"
           #x0D "\\r" #x1B "\\e" #x22 "\\\"" #x5C "\\\\" #x85 "\\N" #xA0 "\\_"
           #x2028 "\\L" #x2029 "\\P"))

(define (encode-hex n)
  (define digits (string-upcase (number->string n 16)))
  (define-values (handle width)
    (cond [(<= n #xFF) (values "x" 2)]
          [(<= n #xFFFF) (values "u" 4)]
          [else (values "U" 8)]))
  (string-append "\\" handle (make-string (- width (string-length digits)) #\0) digits))

(define (escape-string str)
  (define out (open-output-string))
  (for ([c (in-string str)])
    (define n (char->integer c))
    (cond [(hash-ref escape-sequences n #f) => (lambda (seq) (write-string seq out))]
          [(printable? n) (write-char c out)]
          [else (write-string (encode-hex n) out)]))
  (get-output-string out))

;; write-scalar : the text of string `str` as a scalar at nesting `level`. `root?` says that
;; the scalar is the whole document, `line-start?` that it starts at the first column.
;;
;; In three cases js-yaml writes a text that it does not read back, and this writer picks
;; another style: a plain scalar at the first column that begins like the document end marker
;; "..." is single-quoted, and a root block scalar that is all line breaks, or that needs an
;; indentation indicator, is double-quoted.
(define (write-scalar str level key? in-block? line-width root? line-start?)
  (cond
    [(string=? str "") "''"]
    [(or (member str deprecated-booleans) (regexp-match? deprecated-base60 str))
     (string-append "'" str "'")]
    [else
     (define indent (* indent-per-level (max 1 level)))
     ;; The width shrinks with the indentation down to min(line-width, 40).
     (define width (and line-width (max (min line-width 40) (- line-width indent))))
     (define (single-quoted) (string-append "'" (string-replace str "'" "''") "'"))
     (define (double-quoted) (string-append "\"" (escape-string str) "\""))
     (define style (choose-scalar-style str key? width in-block?))
     (case style
       [(plain)
        ;; A key is followed by its colon, so only "... " can be taken for the marker there.
        (if (and line-start?
                 (regexp-match? (if key? #rx"^[.][.][.] " #rx"^[.][.][.]($| )") str))
            (single-quoted)
            str)]
       [(single) (single-quoted)]
       [(literal folded)
        (cond
          [(and root? (or (need-indent-indicator? str) (regexp-match? #rx"^\n+$" str)))
           (double-quoted)]
          [(eq? style 'literal)
           (string-append "|" (block-header str) (drop-ending-newline (indent-string str indent)))]
          [else
           (string-append ">" (block-header str)
                          (drop-ending-newline (indent-string (fold-string str width) indent)))])]
       [else (double-quoted)])]))

(define (number->yaml n)
  (define x (if (flonum? n) n #f))
  (cond
    [(and x (not (= x x))) ".nan"]
    [(and x (= x +inf.0)) ".inf"]
    [(and x (= x -inf.0)) "-.inf"]
    [(and x (eqv? x -0.0)) "-0.0"]
    [else
     (define text (js-number->string n))
     ;; YAML wants a dot before the exponent: 5e-100 is written 5.e-100.
     (if (and (not (integer? n)) (regexp-match? #rx"^[-+]?[0-9]+e" text))
         (regexp-replace #rx"e" text ".e")
         text)]))

;; ---------------------------------------------------------------------------------------------
;; Nodes

(define (next-line level)
  (string-append "\n" (make-string (* indent-per-level level) #\space)))

(define (starts-with-newline? str)
  (and (positive? (string-length str)) (char=? (string-ref str 0) #\newline)))

;; dump-yaml : any/c (or/c #f exact-positive-integer?) -> string?
;; The YAML text of `value`, with a final newline. Raises exn:fail:contract for a value outside
;; the model, naming where it is.
(define (dump-yaml value line-width)
  ;; write-node : the text of `v` at `level`. `compact?` lets a block collection start on the
  ;; line of its parent's "- ". `path` is the reverse path of `v`, for the error message.
  ;; `root?` says that `v` is the document, `line-start?` that its text starts a line.
  (define (write-node v level compact? key? path [root? #f] [line-start? #f])
    (cond
      [(string? v) (write-scalar v level key? #t line-width root? line-start?)]
      [(eq? v 'null) "null"]
      [(eq? v #t) "true"]
      [(eq? v #f) "false"]
      [(real? v) (number->yaml v)]
      [(js-expr? v)
       (string-append "!!js " (write-scalar (js-expr-source v) level key? #t line-width root? #f))]
      [(marker-source v)
       => (lambda (source)
            (string-append "!!js " (write-scalar source level key? #t line-width root? #f)))]
      [(list? v)
       (if (null? v) "[]" (write-block-sequence v level compact? path))]
      [(object? v)
       (define obj (if (jobject? v) v (jmerge v)))
       (if (zero? (jcount obj)) "{}" (write-block-mapping obj level compact? path))]
      [else
       (raise-arguments-error
        'yaml-write "value cannot be written as YAML"
        "value" v
        "at" (if (null? path)
                 "the top level"
                 (string-join (map (lambda (step) (format "~a" step)) (reverse path)) " > ")))]))
  (define (write-block-sequence items level compact? path)
    (define out (open-output-string))
    (for ([item (in-list items)] [index (in-naturals)])
      (define text (write-node item (add1 level) #t #f (cons index path)))
      (unless (and compact? (zero? index))
        (write-string (next-line level) out))
      (write-string (if (starts-with-newline? text) "-" "- ") out)
      (write-string text out))
    (get-output-string out))
  (define (write-block-mapping obj level compact? path)
    (define out (open-output-string))
    (for ([(key item) (in-jobject obj)] [index (in-naturals)])
      (unless (and compact? (zero? index))
        (write-string (next-line level) out))
      ;; The keys of the root mapping start at the first column.
      (define key-text (write-node (symbol->string key) (add1 level) #t #t path #f (zero? level)))
      ;; A very long key is written in the explicit "? key" form.
      (define explicit? (> (utf16-length key-text) 1024))
      (when explicit?
        (write-string (if (starts-with-newline? key-text) "?" "? ") out))
      (write-string key-text out)
      (when explicit? (write-string (next-line level) out))
      (define text (write-node item (add1 level) explicit? #f (cons key path)))
      (write-string (if (starts-with-newline? text) ":" ": ") out)
      (write-string text out))
    (get-output-string out))
  (string-append (write-node value 0 #t #f '() #t #t) "\n"))
