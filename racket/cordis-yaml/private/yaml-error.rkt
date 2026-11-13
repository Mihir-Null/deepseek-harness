#lang racket/base
;; Provides `exn:fail:yaml` and `raise-yaml-error`, which builds the message js-yaml builds for
;; a YAMLException: the reason, the location as (line:column), and a snippet of the source with
;; a caret under the position.
;; source: js-yaml 4.3.2 lib/exception.js, lib/snippet.js

(require racket/string)

(provide (struct-out exn:fail:yaml)
         raise-yaml-error
         raise-yaml-error/no-mark)

;; reason : string. source : the #:source name or #f. line, column : 1-based, or #f.
;; position : 0-based character offset, or #f.
(struct exn:fail:yaml exn:fail (reason source line column position))

;; raise-yaml-error : string? any/c string? fixnum fixnum fixnum -> none
;; `buffer` is the text being read; `line` is 0-based and `line-start` is the offset of the
;; line that holds `position`, as the reader tracks them.
(define (raise-yaml-error reason source buffer position line line-start)
  (define column (- position line-start))
  (define where
    (string-append (if source (format "in \"~a\" " (source->string source)) "")
                   (format "(~a:~a)" (add1 line) (add1 column))))
  (define snippet (make-snippet buffer position line))
  (raise (exn:fail:yaml (string-append reason " " where "\n\n" snippet)
                        (current-continuation-marks)
                        reason source (add1 line) (add1 column) position)))

;; raise-yaml-error/no-mark : string? any/c -> none
(define (raise-yaml-error/no-mark reason source)
  (raise (exn:fail:yaml reason (current-continuation-marks) reason source #f #f #f)))

(define (source->string source)
  (cond [(string? source) source]
        [(path? source) (path->string source)]
        [else (format "~a" source)]))

;; ---------------------------------------------------------------------------------------------
;; The snippet: up to three lines before the position, the line itself, a caret line, and up
;; to two lines after, each cut to fit 79 columns.

(define max-length 79)
(define snippet-indent 1)
(define lines-before 3)
(define lines-after 2)

;; Returns the starts and ends of the lines of `buffer` and the index of the line that holds
;; `position`. A line ends at LF, CR, CRLF or NUL.
(define (line-table buffer position)
  (define len (string-length buffer))
  (let loop ([i 0] [starts '(0)] [ends '()] [found #f])
    (cond
      [(= i len)
       (define starts* (list->vector (reverse starts)))
       (values starts*
               (list->vector (reverse ends))
               (or found (sub1 (vector-length starts*))))]
      [else
       (define c (string-ref buffer i))
       (define width
         (cond [(and (char=? c #\return) (< (add1 i) len)
                     (char=? (string-ref buffer (add1 i)) #\newline))
                2]
               [(or (char=? c #\newline) (char=? c #\return) (char=? c #\nul)) 1]
               [else 0]))
       (cond
         [(zero? width) (loop (add1 i) starts ends found)]
         [else
          (loop (+ i width)
                (cons (+ i width) starts)
                (cons i ends)
                (or found (and (<= position i) (sub1 (length starts)))))])])))

;; One line of the snippet, cut around `position` when it is longer than `max-line-length`.
;; Returns the text and the offset of `position` inside it.
(define (snippet-line buffer line-start line-end position max-line-length)
  (define max-half (sub1 (quotient max-line-length 2)))
  (define-values (head start)
    (if (> (- position line-start) max-half)
        (values " ... " (+ (- position max-half) 5))
        (values "" line-start)))
  (define-values (tail end)
    (if (> (- line-end position) max-half)
        (values " ..." (- (+ position max-half) 4))
        (values "" line-end)))
  (values (string-append head
                         (string-replace (safe-substring buffer start end) "\t" "\U2192")
                         tail)
          (+ (- position start) (string-length head))))

(define (safe-substring s start end)
  (define len (string-length s))
  (define a (max 0 (min start len)))
  (define b (max a (min end len)))
  (substring s a b))

(define (pad-start s width)
  (string-append (make-string (max 0 (- width (string-length s))) #\space) s))

(define (make-snippet buffer position line)
  (define-values (starts ends found) (line-table buffer position))
  (define line-count (vector-length ends))
  (define (end-of i) (if (< i line-count) (vector-ref ends i) (string-length buffer)))
  (define number-width
    (string-length (number->string (min (+ line lines-after) line-count))))
  (define max-line-length (- max-length (+ snippet-indent number-width 3)))
  (define (numbered n text)
    (string-append (make-string snippet-indent #\space)
                   (pad-start (number->string n) number-width)
                   " | " text "\n"))
  (define before
    (for/list ([i (in-range lines-before 0 -1)]
               #:when (>= (- found i) 0))
      (define-values (text _pos)
        (snippet-line buffer
                      (vector-ref starts (- found i))
                      (end-of (- found i))
                      (- position (- (vector-ref starts found) (vector-ref starts (- found i))))
                      max-line-length))
      (numbered (+ (- line i) 1) text)))
  (define-values (text pos)
    (snippet-line buffer (vector-ref starts found) (end-of found) position max-line-length))
  (define after
    (for/list ([i (in-range 1 (add1 lines-after))]
               #:when (< (+ found i) line-count))
      (define-values (text _pos)
        (snippet-line buffer
                      (vector-ref starts (+ found i))
                      (end-of (+ found i))
                      (- position (- (vector-ref starts found) (vector-ref starts (+ found i))))
                      max-line-length))
      (numbered (+ line i 1) text)))
  (define all
    (string-append (apply string-append before)
                   (numbered (add1 line) text)
                   (make-string (+ snippet-indent number-width 3 pos) #\-) "^\n"
                   (apply string-append after)))
  ;; js-yaml drops one trailing newline.
  (substring all 0 (sub1 (string-length all))))
