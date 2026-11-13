#lang racket/base
;; Provides `check-node-table`, which compares cordis-data with every row of a table written by
;; tests/gen/gen-node-table.mjs. The table's expected results all come from Node.
;;
;; The table encodes a JSON value as a datum Racket's reader rebuilds without the code under
;; test: an object is a list of (key . value) pairs, an array a vector, null the symbol `null`.

(require racket/list
         cordis-data)

(provide check-node-table)

;; check-node-table : path-string? -> (values (hash/c symbol? exact-nonnegative-integer?)
;;                                            (listof string?))
;; Returns the number of rows checked per section and one description per mismatch.
(define (check-node-table path)
  (define table (call-with-input-file path read))
  (define failures '())
  (define (fail! section row what expected actual)
    (set! failures
          (cons (format "~a ~s\n  ~a\n  expected: ~s\n  actual:   ~s" section row what expected actual)
                failures)))
  ;; Records a mismatch unless `actual` (a thunk's result, or the exception it raised) is
  ;; `equal?` to `expected`.
  (define (expect! section row what expected thunk)
    (define actual
      (with-handlers ([exn:fail? (lambda (e) (list 'raised (exn-message e)))])
        (thunk)))
    (unless (equal? actual expected)
      (fail! section row what expected actual)))

  (for ([row (in-list (section-rows table 'stringify))])
    (define value (decode (first row)))
    (define indent (second row))
    (define text (third row))
    (expect! 'stringify row "jvalue->string" text (lambda () (jvalue->string value #:indent indent)))
    (expect! 'stringify row "jvalue->bytes" (string->bytes/utf-8 text)
             (lambda () (jvalue->bytes value #:indent indent)))
    (expect! 'stringify row "write-jvalue" text
             (lambda ()
               (define out (open-output-string))
               (write-jvalue value out #:indent indent)
               (get-output-string out)))
    (expect! 'stringify row "write of read of text" text
             (lambda () (jvalue->string (string->jvalue text) #:indent indent))))

  (for ([row (in-list (section-rows table 'parse))])
    (define text (first row))
    (define expected (decode (second row)))
    (define (check! what thunk)
      (define actual
        (with-handlers ([exn:fail? (lambda (e) (list 'raised (exn-message e)))])
          (thunk)))
      (unless (same-value? actual expected)
        (fail! 'parse row what expected actual)))
    (check! "string->jvalue" (lambda () (string->jvalue text)))
    (check! "bytes->jvalue" (lambda () (bytes->jvalue (string->bytes/utf-8 text))))
    (define in (open-input-bytes (string->bytes/utf-8 text)))
    (check! "read-jvalue" (lambda () (read-jvalue in)))
    (expect! 'parse row "read-jvalue at the end" eof (lambda () (read-jvalue in))))

  (for ([text (in-list (section-rows table 'parse-error))])
    (define (rejects? thunk)
      (with-handlers ([exn:fail:json? (lambda (e) #t)])
        (thunk)
        #f))
    (unless (rejects? (lambda () (string->jvalue text)))
      (fail! 'parse-error text "string->jvalue" 'exn:fail:json (string->jvalue text)))
    (unless (rejects? (lambda () (bytes->jvalue (string->bytes/utf-8 text))))
      (fail! 'parse-error text "bytes->jvalue" 'exn:fail:json 'value))
    ;; As a stream the text may begin with complete values; it must still end in eof or a
    ;; syntax error, never anything else.
    (define in (open-input-string text))
    (expect! 'parse-error text "read-jvalue until the end" 'done
             (lambda ()
               (let loop ([budget (+ 2 (string-length text))])
                 (cond
                   [(zero? budget) 'no-progress]
                   [(with-handlers ([exn:fail:json? (lambda (e) #f)])
                      (not (eof-object? (read-jvalue in))))
                    (loop (sub1 budget))]
                   [else 'done])))))

  (for ([row (in-list (section-rows table 'numbers))])
    (define x (bits->flonum (first row)))
    (define text (second row))
    (expect! 'numbers row "js-number->string" text (lambda () (js-number->string x)))
    (cond
      [(< -inf.0 x +inf.0)
       (expect! 'numbers row "jvalue->string" text (lambda () (jvalue->string x)))
       (expect! 'numbers row "read of the text" #t
                (lambda () (= x (real->double-flonum (string->jvalue text)))))]
      [else (expect! 'numbers row "jvalue->string" "null" (lambda () (jvalue->string x)))]))

  (for ([row (in-list (section-rows table 'number-texts))])
    (define text (first row))
    (define expected (bits->flonum (second row)))
    (expect! 'number-texts row "string->jvalue" expected
             (lambda () (real->double-flonum (string->jvalue text))))
    (expect! 'number-texts row "exactness" (integer-token? text)
             (lambda () (exact-integer? (string->jvalue text)))))

  (for ([row (in-list (section-rows table 'lengths))])
    (define str (first row))
    (expect! 'lengths row "utf16-length" (second row) (lambda () (utf16-length str)))
    (expect! 'lengths row "utf8-length" (third row) (lambda () (utf8-length str)))
    (expect! 'lengths row "code-point-length" (fourth row) (lambda () (code-point-length str))))

  (for ([row (in-list (section-rows table 'slices))])
    (define-values (str start end slice) (apply values row))
    (expect! 'slices row "utf16-substring" slice
             (lambda () (if end (utf16-substring str start end) (utf16-substring str start)))))

  (for ([row (in-list (section-rows table 'truncations))])
    (define-values (str limit utf16-prefix utf8-prefix) (apply values row))
    (expect! 'truncations row "utf16-truncate" utf16-prefix (lambda () (utf16-truncate str limit)))
    (expect! 'truncations row "utf8-truncate" utf8-prefix (lambda () (utf8-truncate str limit))))

  (for ([row (in-list (section-rows table 'order))])
    (expect! 'order row "js-string<?" (third row) (lambda () (js-string<? (first row) (second row)))))

  (for ([row (in-list (section-rows table 'utf8))])
    (define quoted (bytes-append #"\"" (apply bytes (first row)) #"\""))
    (expect! 'utf8 row "bytes->jvalue" (second row) (lambda () (bytes->jvalue quoted)))
    (expect! 'utf8 row "read-jvalue" (second row) (lambda () (read-jvalue (open-input-bytes quoted)))))

  (values (for/hasheq ([section (in-list table)])
            (values (car section) (length (cdr section))))
          (reverse failures)))

(define (section-rows table name)
  (cdr (or (assq name table) (error 'check-node-table "the table has no ~a section" name))))

;; The jvalue a table datum stands for.
(define (decode datum)
  (cond
    [(vector? datum) (for/list ([element (in-vector datum)]) (decode element))]
    [(list? datum)
     (make-jobject (for/list ([entry (in-list datum)])
                     (cons (car entry) (decode (cdr entry)))))]
    [else datum]))

(define (bits->flonum bits)
  (floating-point-bytes->real (integer->integer-bytes bits 8 #f #t) #t))

;; JavaScript enumerates keys that are array indexes first, in numeric order, so a parsed
;; object that has one does not list its keys in the order of the text.
(define (array-index-key? key)
  (define name (symbol->string key))
  (and (regexp-match? #rx"^(0|[1-9][0-9]*)$" name)
       (< (string->number name) 4294967295)))

;; Whether the reader's result is the value JSON.parse produced: the same keys in the same
;; order (as a set when JavaScript reordered them), the same strings, and numbers that are the
;; same double.
(define (same-value? actual expected)
  (cond
    [(jobject? expected)
     (and (jobject? actual)
          (let ([expected-keys (jkeys expected)]
                [actual-keys (jkeys actual)])
            (and (if (ormap array-index-key? expected-keys)
                     (equal? (sort actual-keys symbol<?) (sort expected-keys symbol<?))
                     (equal? actual-keys expected-keys))
                 (for/and ([key (in-list expected-keys)])
                   (same-value? (jref actual key) (jref expected key))))))]
    [(list? expected)
     (and (list? actual)
          (= (length actual) (length expected))
          (andmap same-value? actual expected))]
    [(real? expected)
     (and (real? actual)
          (equal? (real->double-flonum actual) (real->double-flonum expected)))]
    [(string? expected) (and (string? actual) (string=? actual expected))]
    [else (eq? actual expected)]))

;; Whether a JSON number text has neither fraction nor exponent and is not negative zero, which
;; is when the reader yields an exact integer.
(define (integer-token? text)
  (and (not (regexp-match? #rx"[.eE]" text))
       (not (regexp-match? #rx"^-0+$" text))))
