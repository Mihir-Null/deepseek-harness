#lang racket/base
;; dsh-util/partial-json: a lazily scanned view of one JSON object's top-level fields, the Racket
;; form of dsh `PartialArguments`.
;;
;; source: packages/util/values/src/partial-json.ts
;;
;; The view is built from text that may still be streaming (a model's tool-call arguments) or
;; from a parsed object. Nothing is scanned until a reader asks. A streaming view remembers every
;; question it answered, and `partial-arguments-refresh!` reports whether any answer changed.
;; Every reader is total: an absent or differently typed field answers #f (or the given
;; default), never raises.
;;
;; Lengths and limits count UTF-16 code units, as JavaScript `length` does. A Racket string
;; cannot hold half of a surrogate pair, so a prefix cut that falls inside a pair ends before the
;; pair, and an escaped high surrogate is held back until the escape that follows it is known.
;; A lone escaped surrogate decodes to U+FFFD.
;;
;; A view is a mutable value owned by one task at a time.

(require racket/contract/base
         cordis-data)

(provide (contract-out
          [make-partial-arguments (-> partial-arguments?)]
          [partial-arguments? (-> any/c boolean?)]
          [partial-arguments-empty partial-arguments?]
          [partial-arguments-from-text (-> string? partial-arguments?)]
          [partial-arguments-from-object (-> any/c partial-arguments?)]
          [partial-arguments-sealed? (-> partial-arguments? boolean?)]
          [partial-arguments-invalid? (-> partial-arguments? boolean?)]
          [partial-arguments-append! (-> partial-arguments? string? void?)]
          [partial-arguments-settle! (-> partial-arguments? string? partial-arguments?)]
          [partial-arguments-refresh! (-> partial-arguments? boolean?)]
          [partial-arguments-closed? (-> partial-arguments? boolean?)]
          [partial-arguments-keys (-> partial-arguments? (listof symbol?))]
          [partial-arguments-has? (-> partial-arguments? key/c boolean?)]
          [partial-arguments-complete? (-> partial-arguments? key/c boolean?)]
          [partial-arguments-string-length
           (->* (partial-arguments? key/c) (#:step real? #:offset real?)
                (or/c exact-nonnegative-integer? #f))]
          [partial-arguments-string-exceeds? (-> partial-arguments? key/c real? boolean?)]
          [partial-arguments-text (-> partial-arguments? key/c (or/c string? #f))]
          [partial-arguments-text-prefix (-> partial-arguments? key/c real? (or/c string? #f))]
          [partial-arguments-value (->* (partial-arguments? key/c) (any/c) any/c)]))

(define key/c (or/c symbol? string?))

;; One reader's progress through a string field: `at` is the next raw index, `units` the decoded
;; UTF-16 length so far, `out` the decoded text when the reader materializes it.
(struct sread ([at #:mutable] [units #:mutable] out [cache #:mutable]) #:authentic)

;; A string field. Raw indexes exclude the quotes; `end` is -1 while the string is open.
(struct sentry (start [end #:mutable] [invalid-at #:mutable]
                      [length-read #:mutable] [text-read #:mutable] prefixes)
  #:authentic)

;; A non-string field. The raw range includes the value's own brackets.
(struct ventry (start [end #:mutable] [parsed #:mutable] [parsed? #:mutable] [invalid? #:mutable])
  #:authentic)

;; One answered question: `answer` recomputes it, `last` is the answer last published.
(struct remembered (completion? answer [last #:mutable]) #:authentic)

(struct partial-arguments
  ([buffer #:mutable]          ; mutable string holding the text so far
   [size #:mutable]            ; characters of `buffer` in use
   [object #:mutable]          ; jobject for a parsed source, else #f
   [sealed? #:mutable]
   [consumed #:mutable]        ; characters the scanner has classified
   [mode #:mutable]
   [key-start #:mutable]
   [key #:mutable]
   [current #:mutable]         ; the entry being scanned, or #f
   [nested-ends #:mutable]     ; stack of expected closing brackets
   [nested-in-string? #:mutable]
   [invalid-at #:mutable]
   [invalid-value? #:mutable]
   entries                     ; symbol -> entry
   [order #:mutable]           ; keys, newest first
   reads)                      ; (cons kind key) -> remembered
  #:authentic)

(define (fresh object sealed?)
  (partial-arguments (make-string 64) 0 object sealed? 0 'root 0 #f #f '() #f #f #f
                     (make-hasheq) '() (make-hash)))

;; A streaming view with no text yet.
(define (make-partial-arguments) (fresh #f #f))

;; A sealed view over finished argument text; it is not scanned until a reader asks.
(define (partial-arguments-from-text text)
  (define view (fresh #f #f))
  (partial-arguments-append! view text)
  (set-partial-arguments-sealed?! view #t)
  view)

;; A sealed view over an already parsed payload. A value that is not an object has no fields.
(define (partial-arguments-from-object value)
  (fresh (cond [(jobject? value) value]
               [(hash? value) (jmerge value)]
               [else empty-jobject])
         #t))

;; The view of a call with no arguments available.
(define partial-arguments-empty (partial-arguments-from-object empty-jobject))

;; Whether indexing or a content read found invalid JSON. Unread value contents are not checked.
(define (partial-arguments-invalid? view)
  (scan! view)
  (or (eq? (partial-arguments-mode view) 'invalid)
      (partial-arguments-invalid-value? view)))

;; Retains streamed text without scanning it. Raises exn:fail for a sealed view.
(define (partial-arguments-append! view fragment)
  (when (partial-arguments-sealed? view)
    (raise (make-exn:fail "PartialArguments: cannot append to a sealed view"
                          (current-continuation-marks))))
  (define n (string-length fragment))
  (unless (zero? n)
    (define size (partial-arguments-size view))
    (define needed (+ size n))
    (when (> needed (string-length (partial-arguments-buffer view)))
      (define grown (make-string (max needed (* 2 (string-length (partial-arguments-buffer view))))))
      (string-copy! grown 0 (partial-arguments-buffer view) 0 size)
      (set-partial-arguments-buffer! view grown))
    (string-copy! (partial-arguments-buffer view) size fragment)
    (set-partial-arguments-size! view needed)))

;; Reconciles a streamed prefix with the authoritative complete text. Returns this view, sealed
;; with its caches kept, when every character matches; otherwise a new sealed view over `text`.
(define (partial-arguments-settle! view text)
  (define size (partial-arguments-size view))
  (cond
    [(or (partial-arguments-object view)
         (not (= (string-length text) size))
         (not (for/and ([i (in-range size)])
                (char=? (string-ref text i) (string-ref (partial-arguments-buffer view) i)))))
     (partial-arguments-from-text text)]
    [else
     (set-partial-arguments-sealed?! view #t)
     view]))

;; Compares remembered answers with the current ones and advances their baseline. Returns
;; whether any answer changed since its first read or the previous refresh. A view nobody read
;; stays unscanned. Sealing ends change tracking.
(define (partial-arguments-refresh! view)
  (define reads (partial-arguments-reads view))
  (cond
    [(zero? (hash-count reads)) #f]
    [else
     (scan! view)
     (define (refresh-read! r)
       (define now ((remembered-answer r)))
       (cond [(equal? now (remembered-last r)) #f]
             [else (set-remembered-last! r now) #t]))
     (define all (hash-values reads))
     (define changed?
       (for/fold ([changed? #f]) ([r (in-list all)] #:unless (remembered-completion? r))
         (or (refresh-read! r) changed?)))
     ;; A content read can find an error that changes a field's completion answer.
     (define changed-completion?
       (for/fold ([changed? #f]) ([r (in-list all)] #:when (remembered-completion? r))
         (or (refresh-read! r) changed?)))
     (when (partial-arguments-sealed? view) (hash-clear! reads))
     (or changed? changed-completion?)]))

;; ---------------------------------------------------------------------------------------------
;; Readers

(define (key->symbol key) (if (symbol? key) key (string->symbol key)))

;; Answers a question and, on a streaming view, remembers it for change detection.
(define (remember view kind key read [comparison #f])
  (scan! view)
  (define result (read))
  (unless (partial-arguments-sealed? view)
    (define id (cons kind key))
    (define reads (partial-arguments-reads view))
    (unless (hash-has-key? reads id)
      (hash-set! reads id
                 (remembered (equal? kind "complete")
                             (if comparison (lambda () (comparison (read))) read)
                             (if comparison (comparison result) result)))))
  result)

;; Whether no further fields can arrive: the outer object closed, indexing failed, or the view
;; is sealed.
(define (partial-arguments-closed? view)
  (remember view "closed" '||
            (lambda ()
              (or (partial-arguments-sealed? view)
                  (and (memq (partial-arguments-mode view) '(closed invalid)) #t)))))

;; Top-level keys seen so far, in first-appearance order.
(define (partial-arguments-keys view)
  (remember view "keys" '||
            (lambda ()
              (if (partial-arguments-object view)
                  (jkeys (partial-arguments-object view))
                  (reverse (partial-arguments-order view))))
            length))

;; Whether a top-level field has appeared (a string opened or another value began).
(define (partial-arguments-has? view key)
  (define k (key->symbol key))
  (remember view "has" k
            (lambda ()
              (if (partial-arguments-object view)
                  (jhas? (partial-arguments-object view) k)
                  (hash-has-key? (partial-arguments-entries view) k)))))

;; Whether a field's closing delimiter has arrived and no content reader reported an error for
;; it. The contents are not validated.
(define (partial-arguments-complete? view key)
  (define k (key->symbol key))
  (remember view "complete" k
            (lambda ()
              (cond
                [(partial-arguments-object view) (jhas? (partial-arguments-object view) k)]
                [else
                 (define entry (hash-ref (partial-arguments-entries view) k #f))
                 (cond
                   [(sentry? entry) (and (>= (sentry-end entry) 0) (not (sentry-invalid-at entry)))]
                   [(ventry? entry) (and (>= (ventry-end entry) 0) (not (ventry-invalid? entry)))]
                   [else #f])]))))

;; Decoded UTF-16 length of a string field so far, without building its text; #f when the field
;; is absent or not a string. `step` and `offset` only set the granularity of change detection:
;; a change is reported when ceiling((length + offset) / step) moves.
(define (partial-arguments-string-length view key #:step [step 1] #:offset [offset 0])
  (define k (key->symbol key))
  (define granularity (max 1 (floor-integer step)))
  (remember view (format "length:~a:~a" granularity offset) k
            (lambda () (length-now view k +inf.0))
            (lambda (len) (and len (ceiling (/ (+ len offset) granularity))))))

;; Whether a string field is longer than `max-length` UTF-16 units; #f when absent or not a
;; string. The limit is floored to at least zero.
(define (partial-arguments-string-exceeds? view key max-length)
  (define k (key->symbol key))
  (define limit (max 0 (floor-integer max-length)))
  (remember view (format "exceeds:~a" limit) k
            (lambda () (> (or (length-now view k (add1 limit)) 0) limit))))

;; The decoded text of a string field so far, including a streaming prefix; #f when absent or
;; not a string.
(define (partial-arguments-text view key)
  (define k (key->symbol key))
  (remember view "text" k (lambda () (text-now view k))))

;; At most the first `max-length` UTF-16 units of a string field; #f when absent or not a
;; string. The limit is floored to at least one.
(define (partial-arguments-text-prefix view key max-length)
  (define k (key->symbol key))
  (define limit (max 1 (floor-integer max-length)))
  (remember view (format "prefix:~a" limit) k (lambda () (text-prefix-now view k limit))))

;; The parsed value of a completed non-string field; `default` (#f unless given) while the field
;; is open, absent, malformed, or a string. Pass a default of your own to tell JSON false from
;; absence.
(define (partial-arguments-value view key [default #f])
  (define k (key->symbol key))
  (define result (remember view "value" k (lambda () (value-now view k absent))))
  (if (eq? result absent) default result))

;; The reader's answer for "no parsed value"; distinct from every jvalue.
(define absent (string->uninterned-symbol "absent"))

(define (floor-integer x)
  (define f (floor x))
  (if (exact? f) f (inexact->exact f)))

(define (length-now view k limit)
  (cond
    [(partial-arguments-object view)
     (define field (jref (partial-arguments-object view) k #f))
     (and (string? field) (utf16-length field))]
    [else
     (define entry (hash-ref (partial-arguments-entries view) k #f))
     (cond
       [(not (sentry? entry)) #f]
       [(and (sentry-text-read entry) (= (sread-at (sentry-text-read entry)) (sentry-end entry)))
        (sread-units (sentry-text-read entry))]
       [else
        (unless (sentry-length-read entry)
          (set-sentry-length-read! entry (sread (sentry-start entry) 0 #f #f)))
        (define read (sentry-length-read entry))
        (read-string! view entry read limit)
        (sread-units read)])]))

(define (sread-text read)
  (or (sread-cache read)
      (let ([text (string->immutable-string (get-output-string (sread-out read)))])
        (set-sread-cache! read text)
        text)))

(define (text-now view k)
  (cond
    [(partial-arguments-object view)
     (define field (jref (partial-arguments-object view) k #f))
     (and (string? field) field)]
    [else
     (define entry (hash-ref (partial-arguments-entries view) k #f))
     (cond
       [(not (sentry? entry)) #f]
       [else
        (unless (sentry-text-read entry)
          (set-sentry-text-read! entry (sread (sentry-start entry) 0 (open-output-string) #f)))
        (define read (sentry-text-read entry))
        (read-string! view entry read +inf.0)
        (sread-text read)])]))

(define (text-prefix-now view k limit)
  (cond
    [(partial-arguments-object view)
     (define field (jref (partial-arguments-object view) k #f))
     (and (string? field) (utf16-truncate field limit))]
    [else
     (define entry (hash-ref (partial-arguments-entries view) k #f))
     (cond
       [(not (sentry? entry)) #f]
       [else
        (define prefixes (sentry-prefixes entry))
        (define read
          (or (hash-ref prefixes limit #f)
              (let ([r (sread (sentry-start entry) 0 (open-output-string) #f)])
                (hash-set! prefixes limit r)
                r)))
        (read-string! view entry read limit)
        (sread-text read)])]))

(define (value-now view k absent)
  (cond
    [(partial-arguments-object view)
     (define obj (partial-arguments-object view))
     (cond
       [(not (jhas? obj k)) absent]
       [else
        (define field (jref obj k))
        (if (string? field) absent field)])]
    [else
     (define entry (hash-ref (partial-arguments-entries view) k #f))
     (cond
       [(or (not (ventry? entry)) (< (ventry-end entry) 0) (ventry-invalid? entry)) absent]
       [(ventry-parsed? entry) (ventry-parsed entry)]
       [else
        (define raw (substring (partial-arguments-buffer view) (ventry-start entry) (ventry-end entry)))
        ;; A malformed value is expected input here: the model wrote it. The field then has no
        ;; parsed result and the view is marked invalid.
        (define parsed
          (with-handlers ([exn:fail:json? (lambda (_) absent)])
            (string->jvalue raw)))
        (cond
          [(eq? parsed absent)
           (set-ventry-invalid?! entry #t)
           (set-partial-arguments-invalid-value?! view #t)
           absent]
          [else
           (set-ventry-parsed! entry parsed)
           (set-ventry-parsed?! entry #t)
           parsed])])]))

;; ---------------------------------------------------------------------------------------------
;; String content reader

(define (hex-value c)
  (cond [(char<=? #\0 c #\9) (- (char->integer c) 48)]
        [(char<=? #\a c #\f) (- (char->integer c) 87)]
        [(char<=? #\A c #\F) (- (char->integer c) 55)]
        [else #f]))

;; source: SIMPLE_ESCAPES
(define (simple-escape c)
  (case c
    [(#\") #\"] [(#\\) #\\] [(#\/) #\/]
    [(#\b) #\backspace] [(#\f) #\page] [(#\n) #\newline] [(#\r) #\return] [(#\t) #\tab]
    [else #f]))

;; Reads four hex digits at `at`. Returns the code, 'short when fewer than four characters are
;; available before `end` and all of them are hex digits, or #f for a non-hex character.
(define (read-hex4 buffer at end)
  (define stop (min end (+ at 4)))
  (let loop ([i at] [acc 0])
    (cond
      [(= i stop) (if (= (- stop at) 4) acc 'short)]
      [else
       (define d (hex-value (string-ref buffer i)))
       (and d (loop (add1 i) (+ (* acc 16) d)))])))

;; Advances `read` through the decoded content of `entry` until `limit` UTF-16 units are counted
;; or the available content ends. A reader with an output port stops before a two-unit character
;; that would pass the limit; a counting reader counts it.
(define (read-string! view entry read limit)
  (define buffer (partial-arguments-buffer view))
  (define open? (< (sentry-end entry) 0))
  (define end
    (let* ([e (if open? (partial-arguments-consumed view) (sentry-end entry))]
           [e (if (sentry-invalid-at entry) (min e (sentry-invalid-at entry)) e)]
           [e (if (partial-arguments-invalid-at view) (min e (partial-arguments-invalid-at view)) e)])
      e))
  (define out (sread-out read))
  (define (invalid! at)
    (set-sentry-invalid-at! entry at)
    (set-partial-arguments-invalid-value?! view #t))
  ;; Emits one decoded character of `units` UTF-16 units that spans `width` raw characters.
  ;; Returns #f when a materializing reader has no room for it.
  (define (emit! ch units width)
    (cond
      [(and out (> (+ (sread-units read) units) limit)) #f]
      [else
       (when out
         (write-char ch out)
         (set-sread-cache! read #f))
       (set-sread-units! read (+ (sread-units read) units))
       (set-sread-at! read (+ (sread-at read) width))
       #t]))
  (define replacement (integer->char #xFFFD))
  (let loop ()
    (define at (sread-at read))
    (when (and (< at end) (< (sread-units read) limit))
      (define c (string-ref buffer at))
      (cond
        [(char=? c #\\)
         (cond
           [(>= (add1 at) end) (unless open? (invalid! at))]
           [(char=? (string-ref buffer (add1 at)) #\u)
            (define code (read-hex4 buffer (+ at 2) end))
            (cond
              [(not code) (invalid! at)]
              [(eq? code 'short) (unless open? (invalid! at))]
              [(<= #xD800 code #xDBFF)
               ;; A high surrogate pairs with a directly following \uDC00..\uDFFF escape.
               (define next (+ at 6))
               (define low
                 (cond
                   [(>= next end) (if open? 'wait #f)]
                   [(not (char=? (string-ref buffer next) #\\)) #f]
                   [(>= (add1 next) end) (if open? 'wait #f)]
                   [(not (char=? (string-ref buffer (add1 next)) #\u)) #f]
                   [else
                    (define code2 (read-hex4 buffer (+ next 2) end))
                    (cond
                      [(eq? code2 'short) (if open? 'wait #f)]
                      [(and code2 (<= #xDC00 code2 #xDFFF)) code2]
                      [else #f])]))
               (cond
                 [(eq? low 'wait) (void)]
                 [low
                  (when (emit! (integer->char (+ #x10000 (* (- code #xD800) #x400) (- low #xDC00)))
                               2 12)
                    (loop))]
                 [else (when (emit! replacement 1 6) (loop))])]
              [(<= #xDC00 code #xDFFF) (when (emit! replacement 1 6) (loop))]
              [else (when (emit! (integer->char code) 1 6) (loop))])]
           [else
            (define decoded (simple-escape (string-ref buffer (add1 at))))
            (if decoded
                (when (emit! decoded 1 2) (loop))
                (invalid! at))])]
        [(char<? c #\space) (invalid! at)]
        [else
         (when (emit! c (if (> (char->integer c) #xFFFF) 2 1) 1)
           (loop))]))))

;; ---------------------------------------------------------------------------------------------
;; Field scanner: locates field ranges without decoding or parsing their contents.

(define (whitespace? c)
  (or (char=? c #\space) (char=? c #\newline) (char=? c #\return) (char=? c #\tab)))

(define (fail! view at)
  (set-partial-arguments-invalid-at! view at)
  (set-partial-arguments-mode! view 'invalid)
  (set-partial-arguments-current! view #f))

(define (open-entry! view entry)
  (define key (partial-arguments-key view))
  (define entries (partial-arguments-entries view))
  (unless (hash-has-key? entries key)
    (set-partial-arguments-order! view (cons key (partial-arguments-order view))))
  (hash-set! entries key entry)
  (set-partial-arguments-current! view entry))

(define (close-value! view end)
  (set-ventry-end! (partial-arguments-current view) end)
  (set-partial-arguments-current! view #f))

;; Finds the unescaped quote that ends the string containing index `from`. Returns its index,
;; or the index where scanning must pause: the buffer end, or a backslash whose escaped
;; character has not arrived.
(define (string-boundary buffer from size)
  (let loop ([i from])
    (cond
      [(>= i size) i]
      [else
       (define c (string-ref buffer i))
       (cond
         [(char=? c #\") i]
         [(char=? c #\\) (if (>= (add1 i) size) i (loop (+ i 2)))]
         [else (loop (add1 i))])])))

(define (scan! view)
  (unless (or (partial-arguments-object view)
              (partial-arguments-invalid-at view))
    (define buffer (partial-arguments-buffer view))
    (define size (partial-arguments-size view))
    (let loop ()
      (define at (partial-arguments-consumed view))
      (when (and (< at size) (not (eq? (partial-arguments-mode view) 'invalid)))
        (define mode (partial-arguments-mode view))
        (cond
          [(eq? mode 'string)
           (define entry (partial-arguments-current view))
           (define stop (string-boundary buffer at size))
           (cond
             [(and (< stop size) (char=? (string-ref buffer stop) #\"))
              (set-sentry-end! entry stop)
              (set-partial-arguments-current! view #f)
              (set-partial-arguments-mode! view 'comma-or-end)
              (set-partial-arguments-consumed! view (add1 stop))
              (loop)]
             [else (set-partial-arguments-consumed! view stop)])]
          [(and (eq? mode 'nested) (partial-arguments-nested-in-string? view))
           (define stop (string-boundary buffer at size))
           (cond
             [(and (< stop size) (char=? (string-ref buffer stop) #\"))
              (set-partial-arguments-nested-in-string?! view #f)
              (set-partial-arguments-consumed! view (add1 stop))
              (loop)]
             [else (set-partial-arguments-consumed! view stop)])]
          [(eq? mode 'key)
           (define stop (string-boundary buffer at size))
           (define control
             (for/first ([i (in-range at stop)] #:when (char<? (string-ref buffer i) #\space)) i))
           (cond
             [control (fail! view control)]
             [(and (< stop size) (char=? (string-ref buffer stop) #\"))
              (define raw (substring buffer (partial-arguments-key-start view) stop))
              ;; An invalid key escape prevents identifying the fields that follow.
              (define key
                (with-handlers ([exn:fail:json? (lambda (_) #f)])
                  (string->jvalue (string-append "\"" raw "\""))))
              (cond
                [key
                 (set-partial-arguments-key! view (string->symbol key))
                 (set-partial-arguments-mode! view 'colon)
                 (set-partial-arguments-consumed! view (add1 stop))
                 (loop)]
                [else (fail! view stop)])]
             [else (set-partial-arguments-consumed! view stop)])]
          [else
           (step! view (string-ref buffer at) at)
           (unless (eq? (partial-arguments-mode view) 'invalid)
             (set-partial-arguments-consumed! view (add1 at)))
           (loop)])))))

(define (begin-key! view at)
  (set-partial-arguments-mode! view 'key)
  (set-partial-arguments-key-start! view (add1 at)))

(define (step! view c at)
  (case (partial-arguments-mode view)
    [(root)
     (cond [(whitespace? c) (void)]
           [(char=? c #\{) (set-partial-arguments-mode! view 'key-or-end)]
           [else (fail! view at)])]
    [(key-or-end)
     (cond [(whitespace? c) (void)]
           [(char=? c #\}) (set-partial-arguments-mode! view 'closed)]
           [(char=? c #\") (begin-key! view at)]
           [else (fail! view at)])]
    [(key-only)
     (cond [(whitespace? c) (void)]
           [(char=? c #\") (begin-key! view at)]
           [else (fail! view at)])]
    [(colon)
     (cond [(whitespace? c) (void)]
           [(char=? c #\:) (set-partial-arguments-mode! view 'value)]
           [else (fail! view at)])]
    [(value)
     (cond
       [(whitespace? c) (void)]
       [(char=? c #\")
        (open-entry! view (sentry (add1 at) -1 #f #f #f (make-hasheqv)))
        (set-partial-arguments-mode! view 'string)]
       [(memv c '(#\} #\, #\: #\])) (fail! view at)]
       [else
        (open-entry! view (ventry at -1 #f #f #f))
        (cond
          [(or (char=? c #\{) (char=? c #\[))
           (set-partial-arguments-mode! view 'nested)
           (set-partial-arguments-nested-ends! view (list (if (char=? c #\{) #\} #\])))
           (set-partial-arguments-nested-in-string?! view #f)]
          [else (set-partial-arguments-mode! view 'scalar)])])]
    [(scalar)
     (when (or (char=? c #\,) (char=? c #\}) (whitespace? c))
       (close-value! view at)
       (set-partial-arguments-mode! view
                                    (cond [(char=? c #\,) 'key-only]
                                          [(char=? c #\}) 'closed]
                                          [else 'comma-or-end])))]
    [(nested)
     (cond
       [(char=? c #\") (set-partial-arguments-nested-in-string?! view #t)]
       [(or (char=? c #\{) (char=? c #\[))
        (set-partial-arguments-nested-ends!
         view (cons (if (char=? c #\{) #\} #\]) (partial-arguments-nested-ends view)))]
       [(or (char=? c #\}) (char=? c #\]))
        (define ends (partial-arguments-nested-ends view))
        (cond
          [(or (null? ends) (not (char=? (car ends) c))) (fail! view at)]
          [else
           (set-partial-arguments-nested-ends! view (cdr ends))
           (when (null? (cdr ends))
             (close-value! view (add1 at))
             (set-partial-arguments-mode! view 'comma-or-end))])]
       [else (void)])]
    [(comma-or-end)
     (cond [(whitespace? c) (void)]
           [(char=? c #\,) (set-partial-arguments-mode! view 'key-only)]
           [(char=? c #\}) (set-partial-arguments-mode! view 'closed)]
           [else (fail! view at)])]
    [(closed)
     (unless (whitespace? c) (fail! view at))]
    [else (void)]))
