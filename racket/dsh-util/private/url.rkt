#lang racket/base
;; A subset of the WHATWG URL parser and serializer: what `URL.parse`, `new URL(input, base)`,
;; `href`, `origin`, `protocol`, `hostname`, `port`, `pathname`, `username` and `password` give
;; for the URLs the dsh utility sources read (proxy variables, request targets, market index
;; links, the file route). Internal to dsh-util.
;;
;; Covered: special schemes (http, https, ws, wss, ftp, file), other schemes with an authority,
;; a rooted path or an opaque path, credentials, ports and default ports, IPv4 number forms,
;; IPv6 literals, dot segments, the percent-encode sets, and relative references.
;; Not covered: Windows drive-letter quirks of `file:` URLs, and full UTS 46 processing of
;; non-ASCII domains (such a domain is NFKC-normalized, lowercased and Punycode-encoded, which
;; equals UTS 46 for ordinary names).

(require racket/string
         racket/list)

(provide wurl?
         wurl-parse
         wurl-resolve
         wurl-href
         wurl-protocol
         wurl-scheme
         wurl-hostname
         wurl-port
         wurl-port-string
         wurl-pathname
         wurl-search
         wurl-hash
         wurl-origin
         wurl-username
         wurl-password
         wurl-special?)

;; scheme   : lowercase string without the colon
;; username, password : percent-encoded strings ("" when absent)
;; host     : serialized host string, "" for an empty host, #f for no host
;; port     : exact integer, or #f for none or the scheme's default
;; path     : list of segments (a hierarchical path) or a string (an opaque path)
;; query, fragment : strings without the leading `?` or `#`, or #f
(struct wurl (scheme username password host port path query fragment) #:transparent)

(define special-ports (hash "ftp" 21 "file" #f "http" 80 "https" 443 "ws" 80 "wss" 443))

(define (special-scheme? scheme) (hash-has-key? special-ports scheme))
(define (wurl-special? u) (special-scheme? (wurl-scheme u)))

;; ---------------------------------------------------------------------------------------------
;; Percent encoding

(define (c0-control-set? n) (or (< n #x20) (> n #x7E)))
(define (fragment-set? n) (or (c0-control-set? n) (memv n '(#x20 #x22 #x3C #x3E #x60))))
(define (query-set? n) (or (c0-control-set? n) (memv n '(#x20 #x22 #x23 #x3C #x3E))))
(define (special-query-set? n) (or (query-set? n) (= n #x27)))
(define (path-set? n) (or (query-set? n) (memv n '(#x3F #x5E #x60 #x7B #x7D))))
(define (userinfo-set? n)
  (or (path-set? n) (memv n '(#x2F #x3A #x3B #x3D #x40 #x5B #x5C #x5D #x7C))))

(define hex-digits "0123456789ABCDEF")

(define (percent-encode s in-set?)
  (define out (open-output-string))
  (for ([c (in-string s)])
    (define n (char->integer c))
    (cond
      [(and (< n #x80) (not (in-set? n))) (write-char c out)]
      [else
       (for ([b (in-bytes (string->bytes/utf-8 (string c)))])
         (write-char #\% out)
         (write-char (string-ref hex-digits (quotient b 16)) out)
         (write-char (string-ref hex-digits (remainder b 16)) out))]))
  (get-output-string out))

(define (hex-value c)
  (cond [(char<=? #\0 c #\9) (- (char->integer c) 48)]
        [(char<=? #\a c #\f) (- (char->integer c) 87)]
        [(char<=? #\A c #\F) (- (char->integer c) 55)]
        [else #f]))

;; Percent-decodes to bytes; a `%` not followed by two hex digits stays literal.
(define (percent-decode s)
  (define bs (string->bytes/utf-8 s))
  (define n (bytes-length bs))
  (define out (open-output-bytes))
  (let loop ([i 0])
    (when (< i n)
      (define b (bytes-ref bs i))
      (define hi (and (= b 37) (< (+ i 2) n) (hex-value (integer->char (bytes-ref bs (+ i 1))))))
      (define lo (and hi (hex-value (integer->char (bytes-ref bs (+ i 2))))))
      (cond
        [lo (write-byte (+ (* 16 hi) lo) out) (loop (+ i 3))]
        [else (write-byte b out) (loop (add1 i))])))
  (get-output-bytes out))

;; ---------------------------------------------------------------------------------------------
;; Hosts

(define forbidden-host-chars
  (map char->integer (string->list "\u0000\t\n\r #/:<>?@[\\]^|")))

(define (forbidden-host-code-point? n) (memv n forbidden-host-chars))

(define (forbidden-domain-code-point? n)
  (or (forbidden-host-code-point? n) (<= n #x1F) (= n #x25) (= n #x7F)))

;; Parses one IPv4 number: decimal, 0x hexadecimal or 0-prefixed octal. #f on failure.
(define (parse-ipv4-number part)
  (cond
    [(string=? part "") #f]
    [(and (>= (string-length part) 2) (member (substring part 0 2) '("0x" "0X")))
     (define digits (substring part 2))
     (cond [(string=? digits "") 0]
           [(regexp-match? #rx"^[0-9A-Fa-f]+$" digits) (string->number digits 16)]
           [else #f])]
    [(and (>= (string-length part) 2) (char=? (string-ref part 0) #\0))
     (and (regexp-match? #rx"^[0-7]+$" part) (string->number part 8))]
    [else (and (regexp-match? #rx"^[0-9]+$" part) (string->number part 10))]))

;; Whether the last label of a domain is numeric, which makes the host an IPv4 address.
(define (ends-in-a-number? domain)
  (define parts
    (let ([ps (string-split domain "." #:trim? #f)])
      (if (and (pair? ps) (string=? (last ps) "") (pair? (cdr ps))) (drop-right ps 1) ps)))
  (and (pair? parts)
       (let ([last-part (last parts)])
         (or (and (not (string=? last-part "")) (regexp-match? #rx"^[0-9]+$" last-part))
             (and (parse-ipv4-number last-part) #t)))))

;; The dotted form of an IPv4 host written with 1 to 4 number parts, or #f.
(define (parse-ipv4 domain)
  (define parts
    (let ([ps (string-split domain "." #:trim? #f)])
      (if (and (pair? ps) (string=? (last ps) "") (pair? (cdr ps))) (drop-right ps 1) ps)))
  (define numbers (map parse-ipv4-number parts))
  (cond
    [(> (length parts) 4) #f]
    [(not (andmap values numbers)) #f]
    [(for/or ([n (in-list (drop-right numbers 1))]) (> n 255)) #f]
    [(>= (last numbers) (expt 256 (- 5 (length numbers)))) #f]
    [else
     (define value
       (for/fold ([acc (last numbers)]) ([n (in-list (drop-right numbers 1))] [i (in-naturals)])
         (+ acc (* n (expt 256 (- 3 i))))))
     (string-join (for/list ([shift '(24 16 8 0)])
                    (number->string (bitwise-and (arithmetic-shift value (- shift)) 255)))
                  ".")]))

;; Parses the text between the brackets of an IPv6 literal into eight 16-bit pieces, or #f.
(define (parse-ipv6 text)
  (define n (string-length text))
  (define pieces (make-vector 8 0))
  (define (ch i) (and (< i n) (string-ref text i)))
  (let/ec return
    (define piece-index 0)
    (define compress #f)
    (define pointer 0)
    (when (eqv? (ch 0) #\:)
      (unless (eqv? (ch 1) #\:) (return #f))
      (set! pointer 2)
      (set! piece-index 1)
      (set! compress 1))
    (let loop ()
      (when (< pointer n)
        (when (= piece-index 8) (return #f))
        (cond
          [(eqv? (ch pointer) #\:)
           (when compress (return #f))
           (set! pointer (add1 pointer))
           (set! piece-index (add1 piece-index))
           (set! compress piece-index)
           (loop)]
          [else
           (define start pointer)
           (define value
             (let digits ([value 0] [len 0])
               (define d (and (< len 4) (ch pointer) (hex-value (ch pointer))))
               (cond [d (set! pointer (add1 pointer)) (digits (+ (* value 16) d) (add1 len))]
                     [else value])))
           (cond
             [(eqv? (ch pointer) #\.)
              ;; An embedded IPv4 address fills the last two pieces.
              (when (= pointer start) (return #f))
              (set! pointer start)
              (when (> piece-index 6) (return #f))
              (let v4 ([seen 0])
                (when (< pointer n)
                  (when (> seen 0)
                    (unless (and (eqv? (ch pointer) #\.) (< seen 4)) (return #f))
                    (set! pointer (add1 pointer)))
                  (unless (and (ch pointer) (char-numeric? (ch pointer)) (char<=? (ch pointer) #\9))
                    (return #f))
                  (define octet
                    (let digits ([value #f])
                      (define c (ch pointer))
                      (cond
                        [(and c (char<=? #\0 c #\9))
                         (define d (- (char->integer c) 48))
                         (when (eqv? value 0) (return #f))
                         (define next (if value (+ (* value 10) d) d))
                         (when (> next 255) (return #f))
                         (set! pointer (add1 pointer))
                         (digits next)]
                        [else value])))
                  (vector-set! pieces piece-index (+ (* (vector-ref pieces piece-index) 256) octet))
                  (when (or (= seen 1) (= seen 3)) (set! piece-index (add1 piece-index)))
                  (v4 (add1 seen)))
                (unless (or (< pointer n) (= seen 4)) (return #f)))]
             [else
              (cond
                [(eqv? (ch pointer) #\:)
                 (set! pointer (add1 pointer))
                 (when (= pointer n) (return #f))]
                [(< pointer n) (return #f)])
              (vector-set! pieces piece-index value)
              (set! piece-index (add1 piece-index))
              (loop)])])))
    (cond
      [compress
       (define swaps (- piece-index compress))
       (for ([k (in-range swaps)])
         (define from (- (+ compress swaps) k 1))
         (define to (- 7 k))
         (define tmp (vector-ref pieces to))
         (vector-set! pieces to (vector-ref pieces from))
         (vector-set! pieces from tmp))]
      [(not (= piece-index 8)) (return #f)])
    pieces))

;; The serialization of eight pieces: lowercase hex, the first longest run of two or more zero
;; pieces written as `::`.
(define (serialize-ipv6 pieces)
  (define-values (best-start best-len)
    (let loop ([i 0] [best-start #f] [best-len 0])
      (cond
        [(= i 8) (values best-start best-len)]
        [(zero? (vector-ref pieces i))
         (define run-end (let run ([j i]) (if (and (< j 8) (zero? (vector-ref pieces j))) (run (add1 j)) j)))
         (define len (- run-end i))
         (if (and (> len 1) (> len best-len))
             (loop run-end i len)
             (loop run-end best-start best-len))]
        [else (loop (add1 i) best-start best-len)])))
  (define out (open-output-string))
  (let loop ([i 0])
    (when (< i 8)
      (cond
        [(and best-start (= i best-start))
         (write-string (if (= i 0) "::" ":") out)
         (loop (+ i best-len))]
        [else
         (write-string (number->string (vector-ref pieces i) 16) out)
         (when (< i 7) (write-string ":" out))
         (loop (add1 i))])))
  (get-output-string out))

;; RFC 3492 Punycode of one label's code points (already lowercased).
(define (punycode-encode label)
  (define cps (map char->integer (string->list label)))
  (define basic (filter (lambda (c) (< c 128)) cps))
  (define out (open-output-string))
  (for ([c (in-list basic)]) (write-char (integer->char c) out))
  (define b (length basic))
  (when (> b 0) (write-char #\- out))
  (define (digit d) (integer->char (if (< d 26) (+ d 97) (+ d 22))))
  (define (adapt delta numpoints first?)
    (let loop ([delta (let ([d (if first? (quotient delta 700) (quotient delta 2))])
                        (+ d (quotient d numpoints)))]
               [k 0])
      (if (> delta 455)
          (loop (quotient delta 35) (+ k 36))
          (+ k (quotient (* 36 delta) (+ delta 38))))))
  (let loop ([n 128] [delta 0] [bias 72] [h b])
    (when (< h (length cps))
      (define m (apply min (filter (lambda (c) (>= c n)) cps)))
      (define delta* (+ delta (* (- m n) (add1 h))))
      (define-values (delta-out bias-out h-out)
        (for/fold ([delta delta*] [bias bias] [h h]) ([c (in-list cps)])
          (cond
            [(< c m) (values (add1 delta) bias h)]
            [(= c m)
             (let emit ([q delta] [k 36])
               (define t (cond [(<= k bias) 1] [(>= k (+ bias 26)) 26] [else (- k bias)]))
               (cond
                 [(< q t) (write-char (digit q) out)]
                 [else
                  (write-char (digit (+ t (remainder (- q t) (- 36 t)))) out)
                  (emit (quotient (- q t) (- 36 t)) (+ k 36))]))
             (values 0 (adapt delta (add1 h) (= h b)) (add1 h))]
            [else (values delta bias h)])))
      (loop (add1 m) (add1 delta-out) bias-out h-out)))
  (get-output-string out))

(define (domain->ascii domain)
  (define normalized (string-downcase (string-normalize-nfkc domain)))
  (string-join
   (for/list ([label (in-list (string-split normalized "." #:trim? #f))])
     (if (for/and ([c (in-string label)]) (< (char->integer c) 128))
         label
         (string-append "xn--" (punycode-encode label))))
   "."))

;; The serialized host for `input` in a special or other scheme, or #f on failure.
(define (parse-host input special?)
  (cond
    [(and (> (string-length input) 0) (char=? (string-ref input 0) #\[))
     (and (char=? (string-ref input (sub1 (string-length input))) #\])
          (let ([pieces (parse-ipv6 (substring input 1 (sub1 (string-length input))))])
            (and pieces (string-append "[" (serialize-ipv6 pieces) "]"))))]
    [(not special?)
     (and (not (for/or ([c (in-string input)]) (forbidden-host-code-point? (char->integer c))))
          (percent-encode input c0-control-set?))]
    [else
     (define decoded (bytes->string/utf-8 (percent-decode input) #�))
     (define ascii (domain->ascii decoded))
     (cond
       [(string=? ascii "") #f]
       [(for/or ([c (in-string ascii)]) (forbidden-domain-code-point? (char->integer c))) #f]
       [(ends-in-a-number? ascii) (parse-ipv4 ascii)]
       [else ascii])]))

;; ---------------------------------------------------------------------------------------------
;; Parsing

(define (single-dot? segment) (member (string-downcase segment) '("." "%2e")))
(define (double-dot? segment)
  (member (string-downcase segment) '(".." ".%2e" "%2e." "%2e%2e")))

;; Splits path text into encoded segments and resolves dot segments on top of `initial`
;; (a list of segments, newest last).
(define (parse-path text special? initial)
  (define separators (if special? '(#\/ #\\) '(#\/)))
  (define raw
    (let loop ([chars (string->list text)] [current '()] [acc '()])
      (cond
        [(null? chars) (reverse (cons (list->string (reverse current)) acc))]
        [(memv (car chars) separators)
         (loop (cdr chars) '() (cons (list->string (reverse current)) acc))]
        [else (loop (cdr chars) (cons (car chars) current) acc)])))
  (let loop ([segments raw] [path (reverse initial)])
    (cond
      [(null? segments) (reverse path)]
      [else
       (define segment (car segments))
       (define last? (null? (cdr segments)))
       (cond
         [(double-dot? segment)
          (define shortened (if (pair? path) (cdr path) path))
          (loop (cdr segments) (if last? (cons "" shortened) shortened))]
         [(single-dot? segment)
          (loop (cdr segments) (if last? (cons "" path) path))]
         [else (loop (cdr segments) (cons (percent-encode segment path-set?) path))])])))

(define (strip-url-text s)
  (define trimmed
    (let* ([n (string-length s)]
           [strip? (lambda (c) (<= (char->integer c) #x20))]
           [start (let loop ([i 0]) (if (and (< i n) (strip? (string-ref s i))) (loop (add1 i)) i))]
           [end (let loop ([i n]) (if (and (> i start) (strip? (string-ref s (sub1 i)))) (loop (sub1 i)) i))])
      (substring s start end)))
  (list->string (filter (lambda (c) (not (memv c '(#\tab #\newline #\return)))) (string->list trimmed))))

;; Splits "rest" into (values before-query query-or-#f fragment-or-#f).
(define (split-query-fragment rest)
  (define hash-at (for/first ([c (in-string rest)] [i (in-naturals)] #:when (char=? c #\#)) i))
  (define before-hash (if hash-at (substring rest 0 hash-at) rest))
  (define fragment (and hash-at (substring rest (add1 hash-at))))
  (define query-at (for/first ([c (in-string before-hash)] [i (in-naturals)] #:when (char=? c #\?)) i))
  (values (if query-at (substring before-hash 0 query-at) before-hash)
          (and query-at (substring before-hash (add1 query-at)))
          fragment))

(define (encode-query query special?)
  (and query (percent-encode query (if special? special-query-set? query-set?))))

(define (encode-fragment fragment)
  (and fragment (percent-encode fragment fragment-set?)))

;; Parses "authority + path" text (after the slashes) for `scheme`. Returns a wurl or #f.
(define (parse-authority+path scheme text query fragment)
  (define special? (special-scheme? scheme))
  (define end
    (or (for/first ([c (in-string text)] [i (in-naturals)]
                    #:when (or (char=? c #\/) (and special? (char=? c #\\))))
          i)
        (string-length text)))
  (define authority (substring text 0 end))
  (define path-text (substring text end))
  (define at (for/last ([c (in-string authority)] [i (in-naturals)] #:when (char=? c #\@)) i))
  (define credentials (if at (substring authority 0 at) ""))
  (define host+port (if at (substring authority (add1 at)) authority))
  (define colon (for/first ([c (in-string credentials)] [i (in-naturals)] #:when (char=? c #\:)) i))
  (define username (percent-encode (if colon (substring credentials 0 colon) credentials) userinfo-set?))
  (define password (if colon (percent-encode (substring credentials (add1 colon)) userinfo-set?) ""))
  ;; The port follows the last colon that is outside an IPv6 literal's brackets.
  (define port-colon
    (let ([close (for/last ([c (in-string host+port)] [i (in-naturals)] #:when (char=? c #\])) i)])
      (for/last ([c (in-string host+port)] [i (in-naturals)]
                 #:when (and (char=? c #\:) (or (not close) (> i close))))
        i)))
  (define host-text (if port-colon (substring host+port 0 port-colon) host+port))
  (define port-text (if port-colon (substring host+port (add1 port-colon)) ""))
  (define port
    (cond [(string=? port-text "") #f]
          [(regexp-match? #rx"^[0-9]+$" port-text) (string->number port-text)]
          [else 'bad]))
  (cond
    [(eq? port 'bad) #f]
    [(and port (> port 65535)) #f]
    [(and (string=? host-text "") (or at port-colon)) #f]
    [(and (string=? host-text "") special? (not (equal? scheme "file"))) #f]
    [else
     (define host (if (string=? host-text "") "" (parse-host host-text special?)))
     (and host
          (let ([host (if (and (equal? scheme "file") (equal? host "localhost")) "" host)])
            (wurl scheme username password host
                  (and port (not (eqv? port (hash-ref special-ports scheme #f))) port)
                  (cond
                    [(string=? path-text "") (if special? '("") '())]
                    [else (parse-path (substring path-text 1) special? '())])
                  (encode-query query special?)
                  (encode-fragment fragment))))]))

(define (without-last segments)
  (if (pair? segments) (drop-right segments 1) segments))

;; URL.parse(input, base): a wurl, or #f where the parser fails. `base` is a wurl, a string or #f.
(define (wurl-parse input [base #f])
  (define base-url (if (string? base) (wurl-parse base) base))
  (define text (strip-url-text input))
  (define scheme-match (regexp-match #rx"^([A-Za-z][A-Za-z0-9+.-]*):(.*)$" text))
  (cond
    [(and base (not base-url)) #f]
    [scheme-match
     (define scheme (string-downcase (cadr scheme-match)))
     (define-values (rest query fragment) (split-query-fragment (caddr scheme-match)))
     (define special? (special-scheme? scheme))
     (cond
       [(and special? base-url (equal? (wurl-scheme base-url) scheme)
             (not (regexp-match? #rx"^[/\\\\]" rest))
             (not (equal? scheme "file")))
        ;; "http:path" against a base of the same special scheme is a relative reference.
        (resolve-relative (caddr scheme-match) base-url)]
       [(equal? scheme "file")
        (define after (regexp-replace #rx"^[/\\\\][/\\\\]" rest ""))
        (if (equal? after rest)
            (wurl scheme "" "" ""  #f
                  (parse-path (regexp-replace #rx"^[/\\\\]" rest "") #t '())
                  (encode-query query #t) (encode-fragment fragment))
            (parse-authority+path scheme after query fragment))]
       [special?
        (parse-authority+path scheme (regexp-replace #rx"^[/\\\\]*" rest "") query fragment)]
       [(string-prefix? rest "//")
        (parse-authority+path scheme (substring rest 2) query fragment)]
       [(string-prefix? rest "/")
        (wurl scheme "" "" #f #f (parse-path (substring rest 1) #f '())
              (encode-query query #f) (encode-fragment fragment))]
       [else
        (wurl scheme "" "" #f #f (percent-encode rest c0-control-set?)
              (encode-query query #f) (encode-fragment fragment))])]
    [base-url (resolve-relative text base-url)]
    [else #f]))

(define (resolve-relative text base)
  (define scheme (wurl-scheme base))
  (define special? (special-scheme? scheme))
  (define-values (rest query fragment) (split-query-fragment text))
  (define (with-path path query fragment)
    (struct-copy wurl base [path path] [query query] [fragment fragment]))
  (cond
    [(string? (wurl-path base))
     ;; A base with an opaque path only accepts a fragment-only reference.
     (and (string=? rest "") (not query) fragment
          (struct-copy wurl base [fragment (encode-fragment fragment)]))]
    [(or (string-prefix? rest "//") (and special? (regexp-match? #rx"^[/\\\\][/\\\\]" rest)))
     (parse-authority+path scheme (substring rest 2) query fragment)]
    [(or (string-prefix? rest "/") (and special? (string-prefix? rest "\\")))
     (with-path (parse-path (substring rest 1) special? '())
       (encode-query query special?) (encode-fragment fragment))]
    [(string=? rest "")
     (with-path (wurl-path base)
       (if query (encode-query query special?) (wurl-query base))
       (encode-fragment fragment))]
    [else
     (with-path (parse-path rest special? (without-last (wurl-path base)))
       (encode-query query special?) (encode-fragment fragment))]))

;; new URL(reference, base): the resolved wurl or #f.
(define (wurl-resolve reference base) (wurl-parse reference base))

;; ---------------------------------------------------------------------------------------------
;; Getters

(define (wurl-protocol u) (string-append (wurl-scheme u) ":"))
(define (wurl-hostname u) (or (wurl-host u) ""))
(define (wurl-port-string u) (if (wurl-port u) (number->string (wurl-port u)) ""))

(define (wurl-pathname u)
  (define path (wurl-path u))
  (if (string? path)
      path
      (apply string-append (for/list ([segment (in-list path)]) (string-append "/" segment)))))

(define (wurl-search u)
  (if (and (wurl-query u) (not (string=? (wurl-query u) ""))) (string-append "?" (wurl-query u)) ""))

(define (wurl-hash u)
  (if (and (wurl-fragment u) (not (string=? (wurl-fragment u) "")))
      (string-append "#" (wurl-fragment u))
      ""))

(define (wurl-href u)
  (string-append
   (wurl-scheme u) ":"
   (cond
     [(wurl-host u)
      (string-append
       "//"
       (cond
         [(or (not (string=? (wurl-username u) "")) (not (string=? (wurl-password u) "")))
          (string-append (wurl-username u)
                         (if (string=? (wurl-password u) "") "" (string-append ":" (wurl-password u)))
                         "@")]
         [else ""])
       (wurl-host u)
       (if (wurl-port u) (string-append ":" (number->string (wurl-port u))) ""))]
     [(and (list? (wurl-path u)) (> (length (wurl-path u)) 1) (string=? (car (wurl-path u)) "")) "/."]
     [else ""])
   (wurl-pathname u)
   (if (wurl-query u) (string-append "?" (wurl-query u)) "")
   (if (wurl-fragment u) (string-append "#" (wurl-fragment u)) "")))

;; The serialized origin: scheme://host[:port] for http, https, ws, wss and ftp; "null" otherwise.
(define (wurl-origin u)
  (if (member (wurl-scheme u) '("http" "https" "ws" "wss" "ftp"))
      (string-append (wurl-scheme u) "://" (wurl-host u)
                     (if (wurl-port u) (string-append ":" (number->string (wurl-port u))) ""))
      "null"))
