#lang racket/base
;; Provides `load-yaml-documents`: the YAML reader. It is js-yaml's loader, kept function for
;; function (the names below are js-yaml's in kebab-case), so that it accepts and rejects the
;; texts js-yaml does and reports the same reasons at the same positions. The schema is dsh's
;; `entryListSchema`: js-yaml's JSON schema plus the scalar tag `!!js`.
;; source: js-yaml 4.3.2 lib/loader.js; vendor/include/src/index.ts (the `!!js` type)
;;
;; Differences from js-yaml, which the interface contract lists: mappings become jobjects in
;; document order, an alias to a collection that is still being read raises, positions count
;; characters, integers stay exact, and there is no merge-key type (dsh's schema has none).

(require racket/list
         racket/string
         cordis-data
         "expr.rkt"
         "uri.rkt"
         "yaml-error.rkt"
         "yaml-scalar.rkt")

(provide load-yaml-documents)

;; ---------------------------------------------------------------------------------------------
;; State

;; input : the text followed by a NUL, which every loop treats as the end.
;; length : the text's length without the NUL. buffer : the text, for error snippets.
;; tag : #f, "?" (a plain scalar awaiting resolution), "!" or a full tag name.
;; kind : #f, 'scalar, 'sequence or 'mapping. result : 'null when the node has no content.
;; anchors : immutable hash from anchor name to value, or to `in-progress`.
(struct st (input length buffer source js?
            [position #:mutable] [line #:mutable] [line-start #:mutable]
            [line-indent #:mutable] [first-tab #:mutable] [depth #:mutable]
            [tag #:mutable] [anchor #:mutable] [kind #:mutable] [result #:mutable]
            [anchors #:mutable] [tag-map #:mutable] [version #:mutable]))

(define max-depth 100)

;; Stands for a collection whose anchor is declared but whose content is still being read.
(define in-progress (string->uninterned-symbol "in-progress"))

(define-syntax-rule (pos s) (st-position s))
(define-syntax-rule (cur s) (string-ref (st-input s) (st-position s)))
(define-syntax-rule (char-at s i) (string-ref (st-input s) i))
(define-syntax-rule (advance! s) (set-st-position! s (add1 (st-position s))))

(define (throw-error s reason)
  (raise-yaml-error reason (st-source s) (st-buffer s)
                    (st-position s) (st-line s) (st-line-start s)))

(define (eol? c) (or (char=? c #\newline) (char=? c #\return)))
(define (white-space? c) (or (char=? c #\tab) (char=? c #\space)))
(define (ws-or-eol? c) (or (white-space? c) (eol? c)))
(define (flow-indicator? c) (and (memv c '(#\, #\[ #\] #\{ #\})) #t))
(define (end? c) (char=? c #\nul))

(define (store-anchor! s name value)
  (set-st-anchors! s (hash-set (st-anchors s) name value)))

;; The fields `tryReadBlockMappingFromProperty` saves and restores.
(struct snapshot (position line line-start line-indent first-tab tag anchor kind result))

(define (snapshot-state s)
  (snapshot (st-position s) (st-line s) (st-line-start s) (st-line-indent s) (st-first-tab s)
            (st-tag s) (st-anchor s) (st-kind s) (st-result s)))

(define (restore-state! s snap)
  (set-st-position! s (snapshot-position snap))
  (set-st-line! s (snapshot-line snap))
  (set-st-line-start! s (snapshot-line-start snap))
  (set-st-line-indent! s (snapshot-line-indent snap))
  (set-st-first-tab! s (snapshot-first-tab snap))
  (set-st-tag! s (snapshot-tag snap))
  (set-st-anchor! s (snapshot-anchor snap))
  (set-st-kind! s (snapshot-kind snap))
  (set-st-result! s (snapshot-result snap)))

;; ---------------------------------------------------------------------------------------------
;; Scalar text accumulation

;; Characters js-yaml's PATTERN_NON_PRINTABLE rejects in plain and block scalars.
(define (non-printable? c)
  (define n (char->integer c))
  (or (<= #x00 n #x08) (= n #x0B) (= n #x0C) (<= #x0E n #x1F)
      (<= #x7F n #x84) (<= #x86 n #x9F) (= n #xFFFE) (= n #xFFFF)))

;; capture-segment! : appends input[start, end) to `out`. `json?` selects the check quoted
;; scalars get (a tab or anything from U+0020 up); otherwise the non-printable check applies.
(define (capture-segment! s out start end json?)
  (when (< start end)
    (define input (st-input s))
    (for ([i (in-range start end)])
      (define c (string-ref input i))
      (if json?
          (unless (or (char=? c #\tab) (char>=? c #\space))
            (throw-error s "expected valid JSON character"))
          (when (non-printable? c)
            (throw-error s "the stream contains non-printable characters"))))
    (write-string input out start end)))

(define (write-folded-lines! out count)
  (cond [(= count 1) (write-char #\space out)]
        [(> count 1) (write-string (make-string (sub1 count) #\newline) out)]))

;; ---------------------------------------------------------------------------------------------
;; Line structure

(define (read-line-break! s)
  (define c (cur s))
  (cond [(char=? c #\newline) (advance! s)]
        [(char=? c #\return)
         (advance! s)
         (when (char=? (cur s) #\newline) (advance! s))]
        [else (throw-error s "a line break is expected")])
  (set-st-line! s (add1 (st-line s)))
  (set-st-line-start! s (pos s))
  (set-st-first-tab! s -1))

;; skip-separation-space! : skips spaces, tabs, comments when allowed, and line breaks, leaving
;; `line-indent` at the indentation of the line reached. Returns the number of line breaks.
(define (skip-separation-space! s allow-comments?)
  (let loop ([line-breaks 0])
    (let skip-white ()
      (define c (cur s))
      (when (white-space? c)
        (when (and (char=? c #\tab) (= (st-first-tab s) -1))
          (set-st-first-tab! s (pos s)))
        (advance! s)
        (skip-white)))
    (when (and allow-comments? (char=? (cur s) #\#))
      (let skip-comment ()
        (advance! s)
        (define c (cur s))
        (unless (or (eol? c) (end? c)) (skip-comment))))
    (cond
      [(eol? (cur s))
       (read-line-break! s)
       (set-st-line-indent! s 0)
       (let count-indent ()
         (when (char=? (cur s) #\space)
           (set-st-line-indent! s (add1 (st-line-indent s)))
           (advance! s)
           (count-indent)))
       (loop (add1 line-breaks))]
      [else line-breaks])))

;; Whether `---` or `...` followed by a blank or the end stands at the position. Callers test
;; that the position is at a line start.
(define (test-document-separator s)
  (define p (pos s))
  (define c (char-at s p))
  (and (or (char=? c #\-) (char=? c #\.))
       (char=? c (char-at s (+ p 1)))
       (char=? c (char-at s (+ p 2)))
       (let ([after (char-at s (+ p 3))])
         (or (end? after) (ws-or-eol? after)))))

;; ---------------------------------------------------------------------------------------------
;; Scalars

(define plain-scalar-forbidden-first
  '(#\# #\& #\* #\! #\| #\> #\' #\" #\% #\@ #\`))

(define (read-plain-scalar s node-indent within-flow?)
  (define c0 (cur s))
  (cond
    [(or (ws-or-eol? c0) (flow-indicator? c0) (memv c0 plain-scalar-forbidden-first)
         (and (or (char=? c0 #\?) (char=? c0 #\-))
              (let ([following (char-at s (add1 (pos s)))])
                (or (ws-or-eol? following)
                    (and within-flow? (flow-indicator? following))))))
     #f]
    [else
     (define saved-kind (st-kind s))
     (define saved-result (st-result s))
     (define out (open-output-string))
     (set-st-kind! s 'scalar)
     (let loop ([capture-start (pos s)] [capture-end (pos s)]
                [pending? #f] [break-line #f])
       ;; Appends the text captured so far and the folded line breaks after it.
       (define (flush-pending!)
         (capture-segment! s out capture-start capture-end #f)
         (write-folded-lines! out (- (st-line s) break-line)))
       ;; Consumes the character at the position as content.
       (define (take c capture-start capture-end)
         (define next-end (if (white-space? c) capture-end (add1 (pos s))))
         (advance! s)
         (loop capture-start next-end #f break-line))
       (define (finish capture-start capture-end)
         (capture-segment! s out capture-start capture-end #f))
       (define c (cur s))
       (define (content)
         (cond [pending?
                (flush-pending!)
                (take c (pos s) (pos s))]
               [else (take c capture-start capture-end)]))
       (cond
         [(end? c) (finish capture-start capture-end)]
         [(char=? c #\:)
          (define following (char-at s (add1 (pos s))))
          (if (or (ws-or-eol? following) (and within-flow? (flow-indicator? following)))
              (finish capture-start capture-end)
              (content))]
         [(char=? c #\#)
          (if (ws-or-eol? (char-at s (sub1 (pos s))))
              (finish capture-start capture-end)
              (content))]
         [(or (and (= (pos s) (st-line-start s)) (test-document-separator s))
              (and within-flow? (flow-indicator? c)))
          (finish capture-start capture-end)]
         [(eol? c)
          (define line (st-line s))
          (define line-start (st-line-start s))
          (define line-indent (st-line-indent s))
          (skip-separation-space! s #f)
          (cond
            [(>= (st-line-indent s) node-indent)
             (loop capture-start capture-end #t line)]
            [else
             (set-st-position! s capture-end)
             (set-st-line! s line)
             (set-st-line-start! s line-start)
             (set-st-line-indent! s line-indent)
             (finish capture-start capture-end)])]
         [else (content)]))
     (define text (get-output-string out))
     (cond [(string=? text "")
            (set-st-kind! s saved-kind)
            (set-st-result! s saved-result)
            #f]
           [else
            (set-st-result! s text)
            #t])]))

(define (read-single-quoted-scalar s node-indent)
  (cond
    [(not (char=? (cur s) #\')) #f]
    [else
     (define out (open-output-string))
     (set-st-kind! s 'scalar)
     (advance! s)
     (let loop ([capture-start (pos s)] [capture-end (pos s)])
       (define c (cur s))
       (cond
         [(end? c)
          (throw-error s "unexpected end of the stream within a single quoted scalar")]
         [(char=? c #\')
          (capture-segment! s out capture-start (pos s) #t)
          (advance! s)
          (cond [(char=? (cur s) #\')
                 (define start (pos s))
                 (advance! s)
                 (loop start (pos s))]
                [else (set-st-result! s (get-output-string out))])]
         [(eol? c)
          (capture-segment! s out capture-start capture-end #t)
          (write-folded-lines! out (skip-separation-space! s #f))
          (loop (pos s) (pos s))]
         [(and (= (pos s) (st-line-start s)) (test-document-separator s))
          (throw-error s "unexpected end of the document within a single quoted scalar")]
         [else
          (advance! s)
          (loop capture-start (if (white-space? c) capture-end (pos s)))]))
     #t]))

(define (simple-escape c)
  (case c
    [(#\0) #\nul] [(#\a) #\u07] [(#\b) #\backspace] [(#\t #\tab) #\tab] [(#\n) #\newline]
    [(#\v) #\vtab] [(#\f) #\page] [(#\r) #\return] [(#\e) #\u1B] [(#\space) #\space]
    [(#\") #\"] [(#\/) #\/] [(#\\) #\\] [(#\N) #\u85] [(#\_) #\uA0] [(#\L) #\U2028]
    [(#\P) #\U2029]
    [else #f]))

(define (escaped-hex-length c)
  (case c [(#\x) 2] [(#\u) 4] [(#\U) 8] [else 0]))

(define (hex-digit-value c)
  (cond [(char<=? #\0 c #\9) (- (char->integer c) 48)]
        [(char<=? #\a c #\f) (- (char->integer c) 87)]
        [(char<=? #\A c #\F) (- (char->integer c) 55)]
        [else #f]))

(define (high-surrogate? n) (<= #xD800 n #xDBFF))
(define (low-surrogate? n) (<= #xDC00 n #xDFFF))

(define (read-double-quoted-scalar s node-indent)
  (cond
    [(not (char=? (cur s) #\")) #f]
    [else
     (define out (open-output-string))
     ;; A \uD8xx escape waits here for the \uDCxx that completes the pair.
     (define pending-high #f)
     (define (flush-high!)
       (when pending-high
         (write-char #\UFFFD out)
         (set! pending-high #f)))
     (define (write-code-point! n)
       (cond
         [(and pending-high (low-surrogate? n))
          (write-char (integer->char (+ #x10000
                                        (arithmetic-shift (- pending-high #xD800) 10)
                                        (- n #xDC00)))
                      out)
          (set! pending-high #f)]
         [else
          (flush-high!)
          (cond [(high-surrogate? n) (set! pending-high n)]
                [(low-surrogate? n) (write-char #\UFFFD out)]
                [(> n #x10FFFF)
                 (throw-error s "escape sequence is outside the Unicode range")]
                [else (write-char (integer->char n) out)])]))
     (define (capture! start end)
       (when (< start end) (flush-high!))
       (capture-segment! s out start end #t))
     (set-st-kind! s 'scalar)
     (advance! s)
     (let loop ([capture-start (pos s)] [capture-end (pos s)])
       (define c (cur s))
       (cond
         [(end? c)
          (throw-error s "unexpected end of the stream within a double quoted scalar")]
         [(char=? c #\")
          (capture! capture-start (pos s))
          (flush-high!)
          (advance! s)
          (set-st-result! s (get-output-string out))]
         [(char=? c #\\)
          (capture! capture-start (pos s))
          (advance! s)
          (define e (cur s))
          (cond
            [(eol? e) (skip-separation-space! s #f)]
            [(simple-escape e)
             => (lambda (replacement)
                  (flush-high!)
                  (write-char replacement out)
                  (advance! s))]
            [(positive? (escaped-hex-length e))
             (define code
               (for/fold ([code 0]) ([_ (in-range (escaped-hex-length e))])
                 (advance! s)
                 (define digit (hex-digit-value (cur s)))
                 (unless digit (throw-error s "expected hexadecimal character"))
                 (+ (* code 16) digit)))
             (write-code-point! code)
             (advance! s)]
            [else (throw-error s "unknown escape sequence")])
          (loop (pos s) (pos s))]
         [(eol? c)
          (capture! capture-start capture-end)
          (define breaks (skip-separation-space! s #f))
          (when (positive? breaks) (flush-high!))
          (write-folded-lines! out breaks)
          (loop (pos s) (pos s))]
         [(and (= (pos s) (st-line-start s)) (test-document-separator s))
          (throw-error s "unexpected end of the document within a double quoted scalar")]
         [else
          (advance! s)
          (loop capture-start (if (white-space? c) capture-end (pos s)))]))
     #t]))

(define (read-block-scalar s node-indent)
  (define indicator (cur s))
  (cond
    [(not (or (char=? indicator #\|) (char=? indicator #\>))) #f]
    [else
     (define folding? (char=? indicator #\>))
     (define out (open-output-string))
     (set-st-kind! s 'scalar)
     ;; The header: chomping and indentation indicators in either order.
     (define-values (chomping detected-indent? text-indent)
       (let header ([chomping 'clip] [detected? #f] [text-indent node-indent])
         (advance! s)
         (define c (cur s))
         (cond
           [(or (char=? c #\+) (char=? c #\-))
            (unless (eq? chomping 'clip)
              (throw-error s "repeat of a chomping mode identifier"))
            (header (if (char=? c #\+) 'keep 'strip) detected? text-indent)]
           [(char<=? #\0 c #\9)
            (define digit (- (char->integer c) 48))
            (cond
              [(zero? digit)
               (throw-error
                s
                (string-append "bad explicit indentation width of a block scalar; "
                               "it cannot be less than one"))]
              [detected? (throw-error s "repeat of an indentation width identifier")]
              [else (header chomping #t (+ node-indent digit -1))])]
           [else (values chomping detected? text-indent)])))
     (when (white-space? (cur s))
       (let skip () (advance! s) (when (white-space? (cur s)) (skip)))
       (when (char=? (cur s) #\#)
         (let skip ()
           (advance! s)
           (unless (or (eol? (cur s)) (end? (cur s))) (skip)))))
     (let loop ([detected-indent? detected-indent?] [text-indent text-indent]
                [did-read-content? #f] [empty-lines 0] [at-more-indented? #f])
       (unless (end? (cur s))
         (read-line-break! s)
         (set-st-line-indent! s 0)
         (let count-indent ()
           (when (and (or (not detected-indent?) (< (st-line-indent s) text-indent))
                      (char=? (cur s) #\space))
             (set-st-line-indent! s (add1 (st-line-indent s)))
             (advance! s)
             (count-indent)))
         (define text-indent*
           (if (and (not detected-indent?) (> (st-line-indent s) text-indent))
               (st-line-indent s)
               text-indent))
         (define c (cur s))
         (define (line-breaks n) (write-string (make-string n #\newline) out))
         (cond
           [(eol? c)
            (loop detected-indent? text-indent* did-read-content? (add1 empty-lines)
                  at-more-indented?)]
           [(and (not detected-indent?) (zero? text-indent*))
            (throw-error s "missing indentation for block scalar")]
           ;; The scalar ends at the first line indented less than its text.
           [(< (st-line-indent s) text-indent*)
            (case chomping
              [(keep) (line-breaks (if did-read-content? (add1 empty-lines) empty-lines))]
              [(clip) (when did-read-content? (line-breaks 1))]
              [else (void)])]
           [else
            (define more-indented?
              (cond
                [(not folding?)
                 (line-breaks (if did-read-content? (add1 empty-lines) empty-lines))
                 at-more-indented?]
                ;; A line that starts with white space is more indented and is not folded.
                [(white-space? c)
                 (line-breaks (if did-read-content? (add1 empty-lines) empty-lines))
                 #t]
                [at-more-indented?
                 (line-breaks (add1 empty-lines))
                 #f]
                [(zero? empty-lines)
                 (when did-read-content? (write-char #\space out))
                 #f]
                [else
                 (line-breaks empty-lines)
                 #f]))
            (define capture-start (pos s))
            (let scan ()
              (unless (or (eol? (cur s)) (end? (cur s)))
                (advance! s)
                (scan)))
            (capture-segment! s out capture-start (pos s) #f)
            (loop #t text-indent* #t 0 more-indented?)])))
     (set-st-result! s (get-output-string out))
     #t]))

;; ---------------------------------------------------------------------------------------------
;; Collections

;; A mapping under construction: the keys seen and the pairs in reverse order.
(struct builder (seen [pairs #:mutable]))

(define (make-builder) (builder (make-hash) '()))

(define (builder->jobject b)
  (make-jobject (reverse (builder-pairs b))))

;; JavaScript's String(value) for a value used as a mapping key.
(define (key->string s key)
  (define (element->string v)
    (cond [(list? v) (throw-error s "nested arrays are not supported inside keys")]
          [(or (eq? v 'null) (void? v)) ""]
          [else (scalar->string v)]))
  (define (scalar->string v)
    (cond [(string? v) v]
          [(eq? v 'null) "null"]
          [(eq? v #t) "true"]
          [(eq? v #f) "false"]
          [(real? v) (js-number->string v)]
          [(eq? v in-progress) (throw-error s "recursive aliases are not supported")]
          [else "[object Object]"]))
  (if (list? key)
      (string-join (map element->string key) ",")
      (scalar->string key)))

;; store-mapping-pair! : adds key and value to `b`; the three positions are where the key
;; starts, for the duplicate-key error.
(define (store-mapping-pair! s b key-node value-node start-line start-line-start start-pos)
  (define key (key->string s key-node))
  (when (hash-ref (builder-seen b) key #f)
    ;; js-yaml writes `startLine || state.line`: a start of 0 leaves the current value.
    (define (given v current) (if (and v (not (zero? v))) v current))
    (set-st-line! s (given start-line (st-line s)))
    (set-st-line-start! s (given start-line-start (st-line-start s)))
    (set-st-position! s (given start-pos (pos s)))
    (throw-error s "duplicated mapping key"))
  (hash-set! (builder-seen b) key #t)
  (set-builder-pairs! b (cons (cons (string->symbol key) (checked-value s value-node))
                              (builder-pairs b))))

;; A value about to be stored in a collection; an alias to an unfinished collection would need
;; a cyclic value.
(define (checked-value s v)
  (when (eq? v in-progress) (throw-error s "recursive aliases are not supported"))
  v)

(define (read-flow-collection s node-indent)
  (define open (cur s))
  (cond
    [(not (or (char=? open #\[) (char=? open #\{))) #f]
    [else
     (define mapping? (char=? open #\{))
     (define terminator (if mapping? #\} #\]))
     (define saved-tag (st-tag s))
     (define saved-anchor (st-anchor s))
     (define b (make-builder))
     (when saved-anchor (store-anchor! s saved-anchor in-progress))
     (advance! s)
     (let loop ([read-next? #t] [items '()])
       (when (end? (cur s))
         (throw-error s "unexpected end of the stream within a flow collection"))
       (skip-separation-space! s #t)
       (define c (cur s))
       (cond
         [(char=? c terminator)
          (advance! s)
          (set-st-tag! s saved-tag)
          (set-st-anchor! s saved-anchor)
          (set-st-kind! s (if mapping? 'mapping 'sequence))
          (set-st-result! s (if mapping? (builder->jobject b) (reverse items)))]
         [(not read-next?)
          (throw-error s "missed comma between flow collection entries")]
         [(char=? c #\,)
          (throw-error s "expected the node content, but found ','")]
         [else
          (define explicit-pair?
            (and (char=? c #\?)
                 (ws-or-eol? (char-at s (add1 (pos s))))
                 (begin (advance! s)
                        (skip-separation-space! s #t)
                        #t)))
          (define line (st-line s))
          (define line-start (st-line-start s))
          (define start (pos s))
          (compose-node s node-indent 'flow-in #f #t)
          (define key-node (st-result s))
          (skip-separation-space! s #t)
          (define pair?
            (and (or explicit-pair? (= (st-line s) line))
                 (char=? (cur s) #\:)))
          (define value-node
            (cond [pair?
                   (advance! s)
                   (skip-separation-space! s #t)
                   (compose-node s node-indent 'flow-in #f #t)
                   (st-result s)]
                  [else 'null]))
          (define items*
            (cond
              [mapping?
               (store-mapping-pair! s b key-node value-node line line-start start)
               items]
              [(or pair? explicit-pair?)
               (define single (make-builder))
               (store-mapping-pair! s single key-node value-node line line-start start)
               (cons (builder->jobject single) items)]
              [else (cons (checked-value s key-node) items)]))
          (skip-separation-space! s #t)
          (cond [(char=? (cur s) #\,)
                 (advance! s)
                 (loop #t items*)]
                [else (loop #f items*)])]))
     #t]))

(define (read-block-sequence s node-indent)
  (cond
    ;; A tab before the token rules out a block collection here.
    [(not (= (st-first-tab s) -1)) #f]
    [else
     (define saved-tag (st-tag s))
     (define saved-anchor (st-anchor s))
     (when saved-anchor (store-anchor! s saved-anchor in-progress))
     (let loop ([items '()] [detected? #f])
       (define (finish)
         (cond [detected?
                (set-st-tag! s saved-tag)
                (set-st-anchor! s saved-anchor)
                (set-st-kind! s 'sequence)
                (set-st-result! s (reverse items))
                #t]
               [else #f]))
       (define c (cur s))
       (cond
         [(end? c) (finish)]
         [else
          (unless (= (st-first-tab s) -1)
            (set-st-position! s (st-first-tab s))
            (throw-error s "tab characters must not be used in indentation"))
          (cond
            [(not (and (char=? c #\-) (ws-or-eol? (char-at s (add1 (pos s))))))
             (finish)]
            [else
             (advance! s)
             (cond
               [(and (positive? (skip-separation-space! s #t))
                     (<= (st-line-indent s) node-indent))
                (loop (cons 'null items) #t)]
               [else
                (define line (st-line s))
                (compose-node s node-indent 'block-in #f #t)
                (define items* (cons (checked-value s (st-result s)) items))
                (skip-separation-space! s #t)
                (cond
                  [(and (or (= (st-line s) line) (> (st-line-indent s) node-indent))
                        (not (end? (cur s))))
                   (throw-error s "bad indentation of a sequence entry")]
                  [(< (st-line-indent s) node-indent)
                   (set-st-tag! s saved-tag)
                   (set-st-anchor! s saved-anchor)
                   (set-st-kind! s 'sequence)
                   (set-st-result! s (reverse items*))
                   #t]
                  [else (loop items* #t)])])])]))]))

(define (read-block-mapping s node-indent flow-indent)
  (cond
    [(not (= (st-first-tab s) -1)) #f]
    [else
     (define saved-tag (st-tag s))
     (define saved-anchor (st-anchor s))
     (define b (make-builder))
     (when saved-anchor (store-anchor! s saved-anchor in-progress))
     ;; The state js-yaml keeps in local variables across the entries of the mapping.
     (define key-node 'null)
     (define value-node 'null)
     (define at-explicit-key? #f)
     (define detected? #f)
     (define allow-compact? #f)
     (define key-line #f)
     (define key-line-start #f)
     (define key-pos #f)
     (define (store-pair! value)
       (store-mapping-pair! s b key-node value key-line key-line-start key-pos)
       (set! key-node 'null)
       (set! value-node 'null))
     ;; Returns 'done at the end of the mapping, or 'keep when the node read is not a mapping
     ;; and its result must stand as it is.
     (define outcome
       (let loop ()
         (define c (cur s))
         (cond
           [(end? c) 'done]
           [else
            (when (and (not at-explicit-key?) (not (= (st-first-tab s) -1)))
              (set-st-position! s (st-first-tab s))
              (throw-error s "tab characters must not be used in indentation"))
            (define following (char-at s (add1 (pos s))))
            (define line (st-line s))
            (define step
              (cond
                ;; Explicit notation: "? key" and ": value" on their own lines.
                [(and (or (char=? c #\?) (char=? c #\:)) (ws-or-eol? following))
                 (cond
                   [(char=? c #\?)
                    (when at-explicit-key? (store-pair! 'null))
                    (set! detected? #t)
                    (set! at-explicit-key? #t)
                    (set! allow-compact? #t)]
                   [at-explicit-key?
                    (set! at-explicit-key? #f)
                    (set! allow-compact? #t)]
                   [else
                    (throw-error
                     s
                     (string-append "incomplete explicit mapping pair; a key node is missed; "
                                    "or followed by a non-tabulated empty line"))])
                 (advance! s)
                 'continue]
                ;; Implicit notation: a flow-style node as the key, then ":" and the value.
                [else
                 (set! key-line (st-line s))
                 (set! key-line-start (st-line-start s))
                 (set! key-pos (pos s))
                 (cond
                   [(not (compose-node s flow-indent 'flow-out #f #t)) 'break]
                   [(= (st-line s) line)
                    (let skip () (when (white-space? (cur s)) (advance! s) (skip)))
                    (cond
                      [(char=? (cur s) #\:)
                       (advance! s)
                       (unless (ws-or-eol? (cur s))
                         (throw-error
                          s
                          (string-append "a whitespace character is expected after the "
                                         "key-value separator within a block mapping")))
                       (when at-explicit-key?
                         (define implicit-key (st-result s))
                         (store-pair! 'null)
                         (set-st-result! s implicit-key))
                       (set! detected? #t)
                       (set! at-explicit-key? #f)
                       (set! allow-compact? #f)
                       (set! key-node (st-result s))
                       'continue]
                      [detected?
                       (throw-error
                        s "can not read an implicit mapping pair; a colon is missed")]
                      [else 'keep])]
                   [detected?
                    (throw-error
                     s
                     (string-append "can not read a block mapping entry; "
                                    "a multiline key may not be an implicit key"))]
                   [else 'keep])]))
            (case step
              [(break) 'done]
              [(keep) 'keep]
              [else
               ;; Common to both notations: the node after "?" or ":".
               (when (or (= (st-line s) line) (> (st-line-indent s) node-indent))
                 (when at-explicit-key?
                   (set! key-line (st-line s))
                   (set! key-line-start (st-line-start s))
                   (set! key-pos (pos s)))
                 (when (compose-node s node-indent 'block-out #t allow-compact?)
                   (if at-explicit-key?
                       (set! key-node (st-result s))
                       (set! value-node (st-result s))))
                 (unless at-explicit-key? (store-pair! value-node))
                 (skip-separation-space! s #t))
               (cond
                 [(and (or (= (st-line s) line) (> (st-line-indent s) node-indent))
                       (not (end? (cur s))))
                  (throw-error s "bad indentation of a mapping entry")]
                 [(< (st-line-indent s) node-indent) 'done]
                 [else (loop)])])])))
     (case outcome
       [(keep)
        (set-st-tag! s saved-tag)
        (set-st-anchor! s saved-anchor)
        #t]
       [else
        ;; The last entry may hold only an explicit key.
        (when at-explicit-key? (store-pair! 'null))
        (when detected?
          (set-st-tag! s saved-tag)
          (set-st-anchor! s saved-anchor)
          (set-st-kind! s 'mapping)
          (set-st-result! s (builder->jobject b)))
        detected?])]))

;; ---------------------------------------------------------------------------------------------
;; Node properties

(define tag-handle-pattern #px"^(?:!|!!|![0-9A-Za-z-]+!)$")
(define tag-uri-pattern
  #px"^(?:!|[^,\\[\\]{}])(?:%[0-9a-fA-F]{2}|[0-9a-zA-Z\\-#;/?:@&=+$,_.!~*'()\\[\\]])*$")

(define (read-tag-property s)
  (cond
    [(not (char=? (cur s) #\!)) #f]
    [else
     (when (st-tag s) (throw-error s "duplication of a tag property"))
     (advance! s)
     (define-values (verbatim? named? handle)
       (cond [(char=? (cur s) #\<) (advance! s) (values #t #f #f)]
             [(char=? (cur s) #\!) (advance! s) (values #f #t "!!")]
             [else (values #f #f "!")]))
     (define start (pos s))
     (define-values (tag-handle tag-name)
       (cond
         [verbatim?
          (let scan ()
            (advance! s)
            (unless (or (end? (cur s)) (char=? (cur s) #\>)) (scan)))
          (unless (< (pos s) (st-length s))
            (throw-error s "unexpected end of the stream within a verbatim tag"))
          (define name (substring (st-input s) start (pos s)))
          (advance! s)
          (values #f name)]
         [else
          (let scan ([named? named?] [handle handle] [name-start start])
            (define c (cur s))
            (cond
              [(or (end? c) (ws-or-eol? c))
               (define name (substring (st-input s) name-start (pos s)))
               (when (regexp-match? #rx"[][,{}]" name)
                 (throw-error s "tag suffix cannot contain flow indicator characters"))
               (values handle name)]
              [(char=? c #\!)
               (when named?
                 (throw-error s "tag suffix cannot contain exclamation marks"))
               (define named-handle (substring (st-input s) (sub1 name-start) (add1 (pos s))))
               (unless (regexp-match? tag-handle-pattern named-handle)
                 (throw-error s "named tag handle cannot contain such characters"))
               (advance! s)
               (scan #t named-handle (pos s))]
              [else
               (advance! s)
               (scan named? handle name-start)]))]))
     (when (and (not (string=? tag-name "")) (not (regexp-match? tag-uri-pattern tag-name)))
       (throw-error s (string-append "tag name cannot contain such characters: " tag-name)))
     (define decoded
       (or (uri-decode tag-name "")
           (throw-error s (string-append "tag name is malformed: " tag-name))))
     (set-st-tag!
      s
      (cond [verbatim? decoded]
            [(hash-ref (st-tag-map s) tag-handle #f)
             => (lambda (prefix) (string-append prefix decoded))]
            [(string=? tag-handle "!") (string-append "!" decoded)]
            [(string=? tag-handle "!!") (string-append "tag:yaml.org,2002:" decoded)]
            [else
             (throw-error s (string-append "undeclared tag handle \"" tag-handle "\""))]))
     #t]))

;; Scans a name that ends at a blank, a flow indicator or the end; returns it.
(define (scan-anchor-name! s)
  (define start (pos s))
  (let scan ()
    (define c (cur s))
    (unless (or (end? c) (ws-or-eol? c) (flow-indicator? c))
      (advance! s)
      (scan)))
  (substring (st-input s) start (pos s)))

(define (read-anchor-property s)
  (cond
    [(not (char=? (cur s) #\&)) #f]
    [else
     (when (st-anchor s) (throw-error s "duplication of an anchor property"))
     (advance! s)
     (define name (scan-anchor-name! s))
     (when (string=? name "")
       (throw-error s "name of an anchor node must contain at least one character"))
     (set-st-anchor! s name)
     #t]))

(define (read-alias s)
  (cond
    [(not (char=? (cur s) #\*)) #f]
    [else
     (advance! s)
     (define name (scan-anchor-name! s))
     (when (string=? name "")
       (throw-error s "name of an alias node must contain at least one character"))
     (define value
       (hash-ref (st-anchors s) name
                 (lambda ()
                   (throw-error s (string-append "unidentified alias \"" name "\"")))))
     (set-st-result! s value)
     (skip-separation-space! s #t)
     #t]))

;; Re-reads tag and anchor properties as part of the first implicit key of a block mapping
;; (`!!str key: value` on its own line) rather than as properties of the node.
(define (try-read-block-mapping-from-property s property-start node-indent flow-indent)
  (define fallback (snapshot-state s))
  (define anchors (st-anchors s))
  (restore-state! s property-start)
  (set-st-tag! s #f)
  (set-st-anchor! s #f)
  (set-st-kind! s #f)
  (set-st-result! s 'null)
  (cond
    [(and (read-block-mapping s node-indent flow-indent) (eq? (st-kind s) 'mapping)) #t]
    [else
     (set-st-anchors! s anchors)
     (restore-state! s fallback)
     #f]))

;; ---------------------------------------------------------------------------------------------
;; Types

(define tag-prefix "tag:yaml.org,2002:")

;; resolve-tagged : the value of a node that carries the explicit tag `tag`. `data` is the
;; node's content: a string for a scalar, 'null for no content, or a collection. `tag-start`
;; is the reader state where the tag begins, or #f.
(define (resolve-tagged s tag kind data tag-start)
  (define (unknown) (throw-error s (string-append "unknown tag !<" tag ">")))
  (define (cannot-resolve)
    (throw-error s (string-append "cannot resolve a node with !<" tag "> explicit tag")))
  ;; type-kind is the kind of node the tag's type applies to.
  (define (typed type-kind construct)
    (unless (or (not kind) (eq? kind type-kind)) (unknown))
    (when (and (not (eq? data 'null)) (not (eq? type-kind kind)))
      (throw-error
       s
       (format "unacceptable node kind for !<~a> tag; it should be \"~a\", not \"~a\""
               tag type-kind kind)))
    (construct))
  (define (scalar-type resolve)
    (typed 'scalar
           (lambda ()
             (define v (resolve data))
             (if (eq? v no-match) (cannot-resolve) v))))
  (define name
    (and (>= (string-length tag) (string-length tag-prefix))
         (string=? (substring tag 0 (string-length tag-prefix)) tag-prefix)
         (substring tag (string-length tag-prefix))))
  (case name
    [("str") (scalar-type (lambda (d) (if (eq? d 'null) "" d)))]
    [("null") (scalar-type resolve-null)]
    [("bool") (scalar-type resolve-bool)]
    [("int") (scalar-type resolve-int)]
    [("float")
     (scalar-type
      (lambda (d)
        (define v (resolve-float d))
        (if (eq? v no-match) v (exact->inexact v))))]
    [("seq") (typed 'sequence (lambda () (if (eq? data 'null) '() data)))]
    [("map") (typed 'mapping (lambda () (if (eq? data 'null) empty-jobject data)))]
    [("js")
     (unless (st-js? s) (unknown))
     (scalar-type
      (lambda (d)
        (cond [(string? d)
               (make-js-expr
                d
                (and tag-start
                     (srcloc (st-source s)
                             (add1 (snapshot-line tag-start))
                             (- (snapshot-position tag-start) (snapshot-line-start tag-start))
                             (add1 (snapshot-position tag-start))
                             #f)))]
              [else no-match])))]
    [else (unknown)]))

;; ---------------------------------------------------------------------------------------------
;; Nodes and documents

;; compose-node : reads one node into `tag`, `anchor`, `kind` and `result`. `context` is
;; 'flow-in, 'flow-out, 'block-in or 'block-out. Returns whether a node was read.
(define (compose-node s parent-indent context allow-to-seek? allow-compact?)
  (when (>= (st-depth s) max-depth)
    (throw-error s (format "nesting exceeded maxDepth (~a)" max-depth)))
  (set-st-depth! s (add1 (st-depth s)))
  (set-st-tag! s #f)
  (set-st-anchor! s #f)
  (set-st-kind! s #f)
  (set-st-result! s 'null)
  (define allow-block-styles? (and (memq context '(block-out block-in)) #t))
  (define allow-block-scalars? allow-block-styles?)
  (define allow-block-collections? allow-block-styles?)
  ;; 1: indented more than the parent, 0: the same, -1: less.
  (define indent-status 1)
  (define at-new-line? #f)
  (define has-content? #f)
  (define property-start #f)
  ;; The reader state where this node's tag begins.
  (define tag-start #f)
  (define (update-indent-status!)
    (set! indent-status
          (cond [(> (st-line-indent s) parent-indent) 1]
                [(= (st-line-indent s) parent-indent) 0]
                [else -1])))
  (when (and allow-to-seek? (positive? (skip-separation-space! s #t)))
    (set! at-new-line? #t)
    (update-indent-status!))
  (when (= indent-status 1)
    (let loop ()
      (define c (cur s))
      (define property-state (snapshot-state s))
      ;; A second tag or anchor after a line break may start the first key of a nested block
      ;; mapping.
      (unless (and at-new-line?
                   (or (and (char=? c #\!) (st-tag s))
                       (and (char=? c #\&) (st-anchor s))))
        (when (or (read-tag-property s) (read-anchor-property s))
          (unless property-start (set! property-start property-state))
          (when (and (st-tag s) (not (snapshot-tag property-state)))
            (set! tag-start property-state))
          (cond [(positive? (skip-separation-space! s #t))
                 (set! at-new-line? #t)
                 (set! allow-block-collections? allow-block-styles?)
                 (update-indent-status!)]
                [else (set! allow-block-collections? #f)])
          (loop)))))
  (when allow-block-collections?
    (set! allow-block-collections? (or at-new-line? allow-compact?)))
  (when (or (= indent-status 1) (eq? context 'block-out))
    (define flow-indent
      (if (memq context '(flow-in flow-out)) parent-indent (add1 parent-indent)))
    (define block-indent (- (pos s) (st-line-start s)))
    (cond
      [(= indent-status 1)
       (cond
         [(or (and allow-block-collections?
                   (or (read-block-sequence s block-indent)
                       (read-block-mapping s block-indent flow-indent)))
              (read-flow-collection s flow-indent))
          (set! has-content? #t)]
         [else
          (define c (cur s))
          (cond
            [(and property-start allow-block-styles? (not allow-block-collections?)
                  (not (char=? c #\|)) (not (char=? c #\>))
                  (try-read-block-mapping-from-property
                   s property-start
                   (- (snapshot-position property-start) (snapshot-line-start property-start))
                   flow-indent))
             (set! has-content? #t)]
            [(or (and allow-block-scalars? (read-block-scalar s flow-indent))
                 (read-single-quoted-scalar s flow-indent)
                 (read-double-quoted-scalar s flow-indent))
             (set! has-content? #t)]
            [(read-alias s)
             (set! has-content? #t)
             (when (or (st-tag s) (st-anchor s))
               (throw-error s "alias node should not have any properties"))]
            [(read-plain-scalar s flow-indent (eq? context 'flow-in))
             (set! has-content? #t)
             (unless (st-tag s) (set-st-tag! s "?"))])
          (when (st-anchor s) (store-anchor! s (st-anchor s) (st-result s)))])]
      [(= indent-status 0)
       ;; A block sequence may sit at the indentation of its parent mapping.
       (set! has-content? (and allow-block-collections? (read-block-sequence s block-indent)))]))
  (define tag (st-tag s))
  (cond
    [(not tag)
     (when (st-anchor s) (store-anchor! s (st-anchor s) (st-result s)))]
    [(string=? tag "?")
     (when (and (not (eq? (st-result s) 'null)) (not (eq? (st-kind s) 'scalar)))
       (throw-error
        s
        (format "unacceptable node kind for !<?> tag; it should be \"scalar\", not \"~a\""
                (st-kind s))))
     (when (string? (st-result s))
       (define resolved (resolve-plain-scalar (st-result s)))
       (unless (string? resolved)
         (set-st-result! s resolved)
         (when (st-anchor s) (store-anchor! s (st-anchor s) resolved))))]
    [(string=? tag "!") (void)]
    [else
     (set-st-result! s (resolve-tagged s tag (st-kind s) (st-result s) tag-start))
     (when (st-anchor s) (store-anchor! s (st-anchor s) (st-result s)))])
  (set-st-depth! s (sub1 (st-depth s)))
  (or (and (st-tag s) #t) (and (st-anchor s) #t) has-content?))

(define (handle-yaml-directive! s args)
  (when (st-version s) (throw-error s "duplication of %YAML directive"))
  (unless (= (length args) 1)
    (throw-error s "YAML directive accepts exactly one argument"))
  (define m (regexp-match #px"^([0-9]+)\\.([0-9]+)$" (car args)))
  (unless m (throw-error s "ill-formed argument of the YAML directive"))
  (unless (= (string->number (cadr m)) 1)
    (throw-error s "unacceptable YAML version of the document"))
  (set-st-version! s (car args)))

(define (handle-tag-directive! s args)
  (unless (= (length args) 2)
    (throw-error s "TAG directive accepts exactly two arguments"))
  (define handle (first args))
  (define prefix (second args))
  (unless (regexp-match? tag-handle-pattern handle)
    (throw-error s "ill-formed tag handle (first argument) of the TAG directive"))
  (when (hash-ref (st-tag-map s) handle #f)
    (throw-error
     s (string-append "there is a previously declared suffix for \"" handle "\" tag handle")))
  (unless (regexp-match? tag-uri-pattern prefix)
    (throw-error s "ill-formed tag prefix (second argument) of the TAG directive"))
  (define decoded
    (or (uri-decode prefix "")
        (throw-error s (string-append "tag prefix is malformed: " prefix))))
  (set-st-tag-map! s (hash-set (st-tag-map s) handle decoded)))

;; read-document : reads one document and returns its value.
(define (read-document s)
  (set-st-version! s #f)
  (set-st-tag-map! s (hash))
  (set-st-anchors! s (hash))
  (define has-directives?
    (let loop ([has-directives? #f])
      (cond
        [(end? (cur s)) has-directives?]
        [else
         (skip-separation-space! s #t)
         (cond
           [(or (positive? (st-line-indent s)) (not (char=? (cur s) #\%))) has-directives?]
           [else
            (advance! s)
            (define name-start (pos s))
            (let scan ()
              (unless (or (end? (cur s)) (ws-or-eol? (cur s))) (advance! s) (scan)))
            (define name (substring (st-input s) name-start (pos s)))
            (when (string=? name "")
              (throw-error s "directive name must not be less than one character in length"))
            (define args
              (let read-args ([args '()])
                (let skip () (when (white-space? (cur s)) (advance! s) (skip)))
                (define c (cur s))
                (cond
                  [(end? c) (reverse args)]
                  [(char=? c #\#)
                   (let skip ()
                     (advance! s)
                     (unless (or (end? (cur s)) (eol? (cur s))) (skip)))
                   (reverse args)]
                  [(eol? c) (reverse args)]
                  [else
                   (define start (pos s))
                   (let scan ()
                     (unless (or (end? (cur s)) (ws-or-eol? (cur s))) (advance! s) (scan)))
                   (read-args (cons (substring (st-input s) start (pos s)) args))])))
            (unless (end? (cur s)) (read-line-break! s))
            (cond [(string=? name "YAML") (handle-yaml-directive! s args)]
                  [(string=? name "TAG") (handle-tag-directive! s args)]
                  ;; js-yaml warns about an unknown directive and goes on.
                  [else (void)])
            (loop #t)])])))
  (skip-separation-space! s #t)
  (cond
    [(and (zero? (st-line-indent s))
          (char=? (cur s) #\-)
          (char=? (char-at s (+ (pos s) 1)) #\-)
          (char=? (char-at s (+ (pos s) 2)) #\-))
     (set-st-position! s (+ (pos s) 3))
     (skip-separation-space! s #t)]
    [has-directives? (throw-error s "directives end mark is expected")])
  (compose-node s (sub1 (st-line-indent s)) 'block-out #f #t)
  (skip-separation-space! s #t)
  (define result (st-result s))
  (cond
    [(and (= (pos s) (st-line-start s)) (test-document-separator s))
     (when (char=? (cur s) #\.)
       (set-st-position! s (+ (pos s) 3))
       (skip-separation-space! s #t))]
    [(< (pos s) (sub1 (st-length s)))
     (throw-error s "end of the stream or a document separator is expected")])
  (when (eq? result in-progress) (throw-error s "recursive aliases are not supported"))
  result)

;; load-yaml-documents : string? any/c boolean? -> list?
;; The documents of `text`, in order. `js?` selects whether the `!!js` tag is known.
(define (load-yaml-documents text source js?)
  (define stripped
    (if (and (positive? (string-length text)) (char=? (string-ref text 0) #\UFEFF))
        (substring text 1)
        text))
  ;; js-yaml appends the line break before it strips the mark, so a text that is only the mark
  ;; still gains one.
  (define buffer
    (cond [(zero? (string-length text)) ""]
          [(memv (string-ref text (sub1 (string-length text))) '(#\newline #\return)) stripped]
          [else (string-append stripped "\n")]))
  (define s
    (st (string-append buffer "\u0000") (string-length buffer) buffer source js?
        0 0 0 0 -1 0 #f #f #f 'null (hash) (hash) #f))
  (define nul-index
    (for/first ([c (in-string buffer)] [i (in-naturals)] #:when (char=? c #\nul)) i))
  (when nul-index
    ;; js-yaml reports this error before it appends its terminator, so its snippet is cut from
    ;; the text without the last character.
    (raise-yaml-error "null byte is not allowed in input" source
                      (substring buffer 0 (sub1 (string-length buffer))) nul-index 0 0))
  (let skip ()
    (when (char=? (cur s) #\space)
      (set-st-line-indent! s (add1 (st-line-indent s)))
      (advance! s)
      (skip)))
  (let loop ([documents '()])
    (if (< (pos s) (sub1 (st-length s)))
        (loop (cons (read-document s) documents))
        (reverse documents))))
