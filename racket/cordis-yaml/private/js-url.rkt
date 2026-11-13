#lang racket/base
;; Provides the `URL` global of the `!!js` evaluator: the WHATWG URL parser and serializer for
;; the special schemes (http, https, ws, wss, ftp, file), and the object `new URL(...)` yields.
;; source: https://url.spec.whatwg.org/ (basic URL parser, host parser, URL serializer)
;;
;; Not implemented, and raised as unsupported: other schemes, IPv6 hosts, hosts that need IDNA,
;; and `searchParams`.

(require racket/list
         racket/string
         "js-error.rkt"
         "js-object.rkt"
         "js-value.rkt")

(provide url-constructor
         url-object?
         url-object-href
         parse-url
         url-href)

;; host : a string for the special schemes ("" for a file URL without a host).
;; port : #f for the scheme's default port, else an exact integer.
;; path : the list of path segments. query, fragment : #f when absent.
(struct url-record (scheme username password host port path query fragment)
  #:mutable)

(define default-ports
  (hash "ftp" 21 "file" #f "http" 80 "https" 443 "ws" 80 "wss" 443))

(define (ascii-alpha? c) (or (char<=? #\a c #\z) (char<=? #\A c #\Z)))
(define (ascii-digit? c) (char<=? #\0 c #\9))

;; ---------------------------------------------------------------------------------------------
;; Percent-encoding

(define (code-in? n chars)
  (for/or ([c (in-string chars)]) (= n (char->integer c))))

(define (c0-control-set? n) (or (<= n #x1F) (> n #x7E)))
(define (fragment-set? n) (or (c0-control-set? n) (code-in? n " \"<>`")))
(define (query-set? n) (or (c0-control-set? n) (code-in? n " \"#<>")))
(define (special-query-set? n) (or (query-set? n) (= n 39)))
;; Node 22 leaves "^" in a path as written, so it is not in this set.
(define (path-set? n) (or (query-set? n) (code-in? n "?`{}")))
(define (userinfo-set? n) (or (path-set? n) (code-in? n "/:;=@[\\]|")))

;; The character itself, or the %XX escapes of its UTF-8 bytes when it is in the set.
(define (percent-encode c in-set?)
  (cond
    [(in-set? (char->integer c))
     (apply string-append
            (for/list ([b (in-bytes (string->bytes/utf-8 (string c)))])
              (string-append "%"
                             (if (< b 16) "0" "")
                             (string-upcase (number->string b 16)))))]
    [else (string c)]))

(define (percent-encode-string s in-set?)
  (apply string-append (for/list ([c (in-string s)]) (percent-encode c in-set?))))

;; ---------------------------------------------------------------------------------------------
;; Hosts

(define forbidden-domain-characters " #/:<>?@[\\]^|%")

(define (forbidden-domain-code-point? c)
  (define n (char->integer c))
  (or (<= n #x1F) (= n #x7F) (code-in? n forbidden-domain-characters)))

;; The value of one part of an IPv4 address, or #f. Hexadecimal and octal forms are accepted.
(define (parse-ipv4-number part)
  (define-values (digits radix)
    (cond [(regexp-match? #rx"^0[xX]" part) (values (substring part 2) 16)]
          [(and (>= (string-length part) 2) (char=? (string-ref part 0) #\0))
           (values (substring part 1) 8)]
          [else (values part 10)]))
  (cond [(string=? part "") #f]
        [(string=? digits "") 0]
        [(regexp-match? (case radix
                          [(16) #rx"^[0-9a-fA-F]+$"]
                          [(8) #rx"^[0-7]+$"]
                          [else #rx"^[0-9]+$"])
                        digits)
         (string->number digits radix)]
        [else #f]))

(define (domain-parts domain)
  (define parts (string-split domain "." #:trim? #f))
  (if (and (pair? parts) (pair? (cdr parts)) (string=? (last parts) ""))
      (drop-right parts 1)
      parts))

(define (ends-in-a-number? domain)
  (define parts (domain-parts domain))
  (define final (last parts))
  (and (not (string=? final ""))
       (or (regexp-match? #rx"^[0-9]+$" final)
           (and (parse-ipv4-number final) #t))))

;; The dotted-decimal form of an IPv4 address, or #f.
(define (parse-ipv4 domain)
  (define parts (domain-parts domain))
  (define numbers (map parse-ipv4-number parts))
  (cond
    [(> (length parts) 4) #f]
    [(memq #f numbers) #f]
    [(for/or ([n (in-list (drop-right numbers 1))]) (> n 255)) #f]
    [(>= (last numbers) (expt 256 (- 5 (length numbers)))) #f]
    [else
     (define address
       (for/fold ([address (last numbers)])
                 ([n (in-list (drop-right numbers 1))] [i (in-naturals)])
         (+ address (* n (expt 256 (- 3 i))))))
     (string-join (for/list ([shift (in-list '(24 16 8 0))])
                    (number->string (bitwise-and (arithmetic-shift address (- shift)) 255)))
                  ".")]))

(define (hex-digit c)
  (cond [(char<=? #\0 c #\9) (- (char->integer c) 48)]
        [(char<=? #\a c #\f) (- (char->integer c) 87)]
        [(char<=? #\A c #\F) (- (char->integer c) 55)]
        [else #f]))

;; The bytes of `input` with every %XX sequence replaced by the byte it names; a "%" that is
;; not followed by two hexadecimal digits stays.
(define (percent-decode input)
  (define bytes (string->bytes/utf-8 input))
  (define len (bytes-length bytes))
  (define out (open-output-bytes))
  (let loop ([i 0])
    (when (< i len)
      (define b (bytes-ref bytes i))
      (define (digit-at j) (hex-digit (integer->char (bytes-ref bytes j))))
      (define high (and (= b 37) (< (+ i 2) len) (digit-at (+ i 1))))
      (define low (and high (digit-at (+ i 2))))
      (cond [low
             (write-byte (+ (* 16 high) low) out)
             (loop (+ i 3))]
            [else
             (write-byte b out)
             (loop (add1 i))])))
  (get-output-bytes out))

;; parse-host : the serialized host of a special URL, or #f for an invalid host.
(define (parse-host input)
  (define decoded (percent-decode input))
  (cond
    [(and (positive? (string-length input)) (char=? (string-ref input 0) #\[))
     (if (char=? (string-ref input (sub1 (string-length input))) #\])
         (raise-js-unsupported "IPv6 host in a URL")
         #f)]
    [(for/or ([b (in-bytes decoded)]) (> b #x7F))
     (raise-js-unsupported "URL host that needs IDNA")]
    [else
     (define domain (string-downcase (bytes->string/latin-1 decoded)))
     (cond
       [(regexp-match? #rx"(^|[.])xn--" domain)
        (raise-js-unsupported "URL host with a punycode label")]
       [(string=? domain "") #f]
       [(for/or ([c (in-string domain)]) (forbidden-domain-code-point? c)) #f]
       [(ends-in-a-number? domain) (parse-ipv4 domain)]
       [else domain])]))

;; ---------------------------------------------------------------------------------------------
;; Paths

(define (windows-drive-letter? s)
  (and (= (string-length s) 2)
       (ascii-alpha? (string-ref s 0))
       (memv (string-ref s 1) '(#\: #\|))
       #t))

(define (normalized-windows-drive-letter? s)
  (and (windows-drive-letter? s) (char=? (string-ref s 1) #\:)))

(define (starts-with-windows-drive-letter? text from)
  (define len (- (string-length text) from))
  (and (>= len 2)
       (windows-drive-letter? (substring text from (+ from 2)))
       (or (= len 2)
           (memv (string-ref text (+ from 2)) '(#\/ #\\ #\? #\#)))
       #t))

(define (single-dot-segment? s)
  (and (member (string-downcase s) '("." "%2e")) #t))

(define (double-dot-segment? s)
  (and (member (string-downcase s) '(".." ".%2e" "%2e." "%2e%2e")) #t))

(define (shorten-path! url)
  (define path (url-record-path url))
  (unless (or (null? path)
              (and (string=? (url-record-scheme url) "file")
                   (null? (cdr path))
                   (normalized-windows-drive-letter? (car path))))
    (set-url-record-path! url (drop-right path 1))))

;; ---------------------------------------------------------------------------------------------
;; The basic URL parser

(define (strip-input input)
  (define len (string-length input))
  (define (c0-or-space? c) (<= (char->integer c) #x20))
  (define start
    (let loop ([i 0]) (if (and (< i len) (c0-or-space? (string-ref input i))) (loop (add1 i)) i)))
  (define end
    (let loop ([i len])
      (if (and (> i start) (c0-or-space? (string-ref input (sub1 i)))) (loop (sub1 i)) i)))
  (list->string (for/list ([c (in-string input start end)]
                           #:unless (memv c '(#\tab #\newline #\return)))
                  c)))

;; parse-url : string? (or/c url-record? #f) -> (or/c url-record? #f)
;; The URL record of `input` against `base`; #f where the specification returns failure.
(define (parse-url input base)
  (define text (strip-input input))
  (define len (string-length text))
  (define url (url-record "" "" "" #f #f '() #f #f))
  (define buffer "")
  (define at-sign-seen? #f)
  (define inside-brackets? #f)
  (define password-token-seen? #f)
  (define (buffer+! s) (set! buffer (string-append buffer s)))
  (define (remaining-starts-with-slash? pointer)
    (and (< (add1 pointer) len) (char=? (string-ref text (add1 pointer)) #\/)))
  (define (slash? c) (or (eqv? c #\/) (eqv? c #\\)))
  (define (copy-from-base! . fields)
    (for ([field (in-list fields)])
      (case field
        [(username) (set-url-record-username! url (url-record-username base))]
        [(password) (set-url-record-password! url (url-record-password base))]
        [(host) (set-url-record-host! url (url-record-host base))]
        [(port) (set-url-record-port! url (url-record-port base))]
        [(path) (set-url-record-path! url (url-record-path base))]
        [else (set-url-record-query! url (url-record-query base))])))
  (define (push-path! segment)
    (set-url-record-path! url (append (url-record-path url) (list segment))))
  (let loop ([state 'scheme-start] [pointer 0])
    ;; c is #f at the end of the input, which every state sees once.
    (define c (and (< pointer len) (string-ref text pointer)))
    (define (next state) (if (>= pointer len) url (loop state (add1 pointer))))
    (define (again state) (loop state pointer))
    (define (start-query-or-fragment-or next-state)
      (cond [(eqv? c #\?)
             (set-url-record-query! url "")
             (next 'query)]
            [(eqv? c #\#)
             (set-url-record-fragment! url "")
             (next 'fragment)]
            [else (next-state)]))
    (case state
      [(scheme-start)
       (cond [(and c (ascii-alpha? c))
              (buffer+! (string (char-downcase c)))
              (next 'scheme)]
             [else (again 'no-scheme)])]
      [(scheme)
       (cond
         [(and c (or (ascii-alpha? c) (ascii-digit? c) (memv c '(#\+ #\- #\.))))
          (buffer+! (string (char-downcase c)))
          (next 'scheme)]
         [(eqv? c #\:)
          (define scheme buffer)
          (set! buffer "")
          (unless (hash-has-key? default-ports scheme)
            (raise-js-unsupported (format "URL scheme ~a:" scheme)))
          (set-url-record-scheme! url scheme)
          (cond [(string=? scheme "file") (next 'file)]
                [(and base (string=? (url-record-scheme base) scheme))
                 (next 'special-relative-or-authority)]
                [else (next 'special-authority-slashes)])]
         [else
          (set! buffer "")
          (loop 'no-scheme 0)])]
      [(no-scheme)
       (cond [(not base) #f]
             [(string=? (url-record-scheme base) "file") (again 'file)]
             [else (again 'relative)])]
      [(special-relative-or-authority)
       (if (and (eqv? c #\/) (remaining-starts-with-slash? pointer))
           (loop 'special-authority-ignore-slashes (+ pointer 2))
           (again 'relative))]
      [(relative)
       (set-url-record-scheme! url (url-record-scheme base))
       (cond
         [(slash? c) (next 'relative-slash)]
         [else
          (copy-from-base! 'username 'password 'host 'port 'path 'query)
          (start-query-or-fragment-or
           (lambda ()
             (cond [c
                    (set-url-record-query! url #f)
                    (shorten-path! url)
                    (again 'path)]
                   [else url])))])]
      [(relative-slash)
       (cond [(slash? c) (next 'special-authority-ignore-slashes)]
             [else
              (copy-from-base! 'username 'password 'host 'port)
              (again 'path)])]
      [(special-authority-slashes)
       (if (and (eqv? c #\/) (remaining-starts-with-slash? pointer))
           (loop 'special-authority-ignore-slashes (+ pointer 2))
           (again 'special-authority-ignore-slashes))]
      [(special-authority-ignore-slashes)
       (if (slash? c)
           (next 'special-authority-ignore-slashes)
           (again 'authority))]
      [(authority)
       (cond
         [(eqv? c #\@)
          (when at-sign-seen? (set! buffer (string-append "%40" buffer)))
          (set! at-sign-seen? #t)
          (for ([code-point (in-string buffer)])
            (cond
              [(and (char=? code-point #\:) (not password-token-seen?))
               (set! password-token-seen? #t)]
              [password-token-seen?
               (set-url-record-password!
                url (string-append (url-record-password url)
                                   (percent-encode code-point userinfo-set?)))]
              [else
               (set-url-record-username!
                url (string-append (url-record-username url)
                                   (percent-encode code-point userinfo-set?)))]))
          (set! buffer "")
          (next 'authority)]
         [(or (not c) (memv c '(#\/ #\? #\# #\\)))
          (cond [(and at-sign-seen? (string=? buffer "")) #f]
                [else
                 (define back (string-length buffer))
                 (set! buffer "")
                 (loop 'host (- pointer back))])]
         [else
          (buffer+! (string c))
          (next 'authority)])]
      [(host)
       (cond
         [(and (eqv? c #\:) (not inside-brackets?))
          (define host (and (not (string=? buffer "")) (parse-host buffer)))
          (cond [host
                 (set-url-record-host! url host)
                 (set! buffer "")
                 (next 'port)]
                [else #f])]
         [(or (not c) (memv c '(#\/ #\? #\# #\\)))
          (define host (and (not (string=? buffer "")) (parse-host buffer)))
          (cond [host
                 (set-url-record-host! url host)
                 (set! buffer "")
                 (again 'path-start)]
                [else #f])]
         [else
          (when (eqv? c #\[) (set! inside-brackets? #t))
          (when (eqv? c #\]) (set! inside-brackets? #f))
          (buffer+! (string c))
          (next 'host)])]
      [(port)
       (cond
         [(and c (ascii-digit? c))
          (buffer+! (string c))
          (next 'port)]
         [(or (not c) (memv c '(#\/ #\? #\# #\\)))
          (cond
            [(string=? buffer "") (again 'path-start)]
            [else
             (define port (string->number buffer 10))
             (cond [(> port 65535) #f]
                   [else
                    (set-url-record-port!
                     url (if (eqv? port (hash-ref default-ports (url-record-scheme url))) #f port))
                    (set! buffer "")
                    (again 'path-start)])])]
         [else #f])]
      [(file)
       (set-url-record-scheme! url "file")
       (set-url-record-host! url "")
       (cond
         [(slash? c) (next 'file-slash)]
         [(and base (string=? (url-record-scheme base) "file"))
          (copy-from-base! 'host 'path 'query)
          (start-query-or-fragment-or
           (lambda ()
             (cond [c
                    (set-url-record-query! url #f)
                    (if (starts-with-windows-drive-letter? text pointer)
                        (set-url-record-path! url '())
                        (shorten-path! url))
                    (again 'path)]
                   [else url])))]
         [else (again 'path)])]
      [(file-slash)
       (cond
         [(slash? c) (next 'file-host)]
         [else
          (when (and base (string=? (url-record-scheme base) "file"))
            (set-url-record-host! url (url-record-host base))
            (define base-path (url-record-path base))
            (when (and (not (starts-with-windows-drive-letter? text pointer))
                       (pair? base-path)
                       (normalized-windows-drive-letter? (car base-path)))
              (push-path! (car base-path))))
          (again 'path)])]
      [(file-host)
       (cond
         [(or (not c) (memv c '(#\/ #\\ #\? #\#)))
          (cond
            ;; The drive letter stays in the buffer and becomes the first path segment.
            [(windows-drive-letter? buffer) (again 'path)]
            [(string=? buffer "")
             (set-url-record-host! url "")
             (again 'path-start)]
            [else
             (define host (parse-host buffer))
             (cond [host
                    (set-url-record-host! url (if (string=? host "localhost") "" host))
                    (set! buffer "")
                    (again 'path-start)]
                   [else #f])])]
         [else
          (buffer+! (string c))
          (next 'file-host)])]
      [(path-start)
       (if (slash? c) (next 'path) (again 'path))]
      [(path)
       (cond
         [(or (not c) (memv c '(#\/ #\\ #\? #\#)))
          (cond
            [(double-dot-segment? buffer)
             (shorten-path! url)
             (unless (slash? c) (push-path! ""))]
            [(single-dot-segment? buffer)
             (unless (slash? c) (push-path! ""))]
            [else
             (when (and (string=? (url-record-scheme url) "file")
                        (null? (url-record-path url))
                        (windows-drive-letter? buffer))
               (set! buffer (string (string-ref buffer 0) #\:)))
             (push-path! buffer)])
          (set! buffer "")
          (start-query-or-fragment-or (lambda () (next 'path)))]
         [else
          (buffer+! (percent-encode c path-set?))
          (next 'path)])]
      [(query)
       (cond
         [(or (not c) (eqv? c #\#))
          (set-url-record-query!
           url (string-append (url-record-query url)
                              (percent-encode-string buffer special-query-set?)))
          (set! buffer "")
          (cond [c
                 (set-url-record-fragment! url "")
                 (next 'fragment)]
                [else url])]
         [else
          (buffer+! (string c))
          (next 'query)])]
      [else
       (cond [c
              (set-url-record-fragment!
               url (string-append (url-record-fragment url) (percent-encode c fragment-set?)))
              (next 'fragment)]
             [else url])])))

;; ---------------------------------------------------------------------------------------------
;; Serialization

(define (url-host+port url)
  (string-append (url-record-host url)
                 (if (url-record-port url) (format ":~a" (url-record-port url)) "")))

(define (url-pathname url)
  (apply string-append (for/list ([segment (in-list (url-record-path url))])
                         (string-append "/" segment))))

;; url-href : url-record? -> string?
(define (url-href url)
  (define credentials?
    (not (and (string=? (url-record-username url) "") (string=? (url-record-password url) ""))))
  (string-append
   (url-record-scheme url) "://"
   (if credentials?
       (string-append (url-record-username url)
                      (if (string=? (url-record-password url) "")
                          ""
                          (string-append ":" (url-record-password url)))
                      "@")
       "")
   (url-host+port url)
   (url-pathname url)
   (if (url-record-query url) (string-append "?" (url-record-query url)) "")
   (if (url-record-fragment url) (string-append "#" (url-record-fragment url)) "")))

;; ---------------------------------------------------------------------------------------------
;; The JavaScript object

(define (url-property url name)
  (define (prefixed prefix value)
    (if (or (not value) (string=? value "")) "" (string-append prefix value)))
  (case name
    [("href") (url-href url)]
    [("protocol") (string-append (url-record-scheme url) ":")]
    [("username") (url-record-username url)]
    [("password") (url-record-password url)]
    [("host") (url-host+port url)]
    [("hostname") (url-record-host url)]
    [("port") (if (url-record-port url) (number->string (url-record-port url)) "")]
    [("pathname") (url-pathname url)]
    [("search") (prefixed "?" (url-record-query url))]
    [("hash") (prefixed "#" (url-record-fragment url))]
    [("origin")
     (if (string=? (url-record-scheme url) "file")
         "null"
         (string-append (url-record-scheme url) "://" (url-host+port url)))]
    [("toString" "toJSON") (lambda () (url-href url))]
    [("searchParams") (raise-js-unsupported "URL.prototype.searchParams")]
    [else (void)]))

;; The value of `new URL(...)`. It is immutable: the evaluator has no assignment.
(struct url-object (record)
  #:methods gen:js-object
  [(define (js-get-property obj name)
     (url-property (url-object-record obj) name))]
  #:methods gen:custom-write
  [(define (write-proc obj port mode)
     (write-string "#<URL " port)
     (write-string (url-href (url-object-record obj)) port)
     (write-string ">" port))])

(define (url-object-href obj)
  (url-href (url-object-record obj)))

(define (construct-url . arguments)
  (when (null? arguments)
    (raise-js-error "TypeError" "The \"url\" argument must be specified"))
  (define (invalid) (raise-js-error "TypeError" "Invalid URL"))
  (define base
    (and (pair? (cdr arguments))
         (not (void? (cadr arguments)))
         (or (parse-url (js->string (cadr arguments)) #f) (invalid))))
  (url-object (or (parse-url (js->string (car arguments)) base) (invalid))))

;; url-constructor : the `URL` global.
(define url-constructor
  (js-function "URL"
               (lambda arguments
                 (raise-js-error "TypeError"
                                 "Class constructor URL cannot be invoked without 'new'"))
               construct-url
               (hash)))
