#lang racket/base
;; Provides the `jobject` representation, the coercion of plain hashes to it, and the JSON text
;; writer. The writer lives beside the struct because a jobject prints as its JSON text.
;;
;; A jobject is immutable. Its keys are symbols held in insertion order as `front` followed by
;; the reverse of `rear`, so adding a key is constant time; `table` maps each key to its value.
;; Nothing here checks argument types beyond what each comment states: `cordis-data` (main.rkt)
;; attaches the contracts.

(require racket/fixnum
         racket/flonum
         racket/symbol
         "number.rkt")

(provide jobject?
         make-raw-jobject
         jobject-front
         jobject-rear
         jobject-table
         jobject-key-list
         empty-jobject
         absent
         absent?
         key->symbol
         check-storable
         object-like?
         hash->jobject
         ->jobject
         lookup
         jvalue->text
         raise-not-jvalue)

;; ---------------------------------------------------------------------------------------------
;; Representation

(struct jobject (front rear table)
  #:constructor-name make-raw-jobject
  #:omit-define-syntaxes
  #:methods gen:equal+hash
  [(define (equal-proc a b recur) (recur (jobject-table a) (jobject-table b)))
   (define (hash-proc a recur) (recur (jobject-table a)))
   (define (hash2-proc a recur) (recur (jobject-table a)))]
  #:methods gen:custom-write
  [(define (write-proc obj port mode)
     (write-string "#<jobject " port)
     (write-string (jvalue->text 'jobject obj #f #t) port)
     (write-string ">" port))])

(define empty-jobject (make-raw-jobject '() '() #hasheq()))

;; The keys of a jobject in insertion order. The result may share structure with the jobject.
(define (jobject-key-list obj)
  (define rear (jobject-rear obj))
  (if (null? rear)
      (jobject-front obj)
      (append (jobject-front obj) (reverse rear))))

;; Stands for "no such key" inside this package; never stored and never returned to callers.
(define absent (string->uninterned-symbol "absent"))
(define (absent? v) (eq? v absent))

;; key->symbol : symbol? (or/c symbol? string?) -> symbol?
(define (key->symbol who key)
  (cond
    [(symbol? key) key]
    [(string? key) (string->symbol key)]
    [else (raise-argument-error who "(or/c symbol? string?)" key)]))

;; Raises unless `value` may be stored in a jobject. `(void)` stands for JavaScript's
;; `undefined`, which is the absence of a key and is never stored.
(define (check-storable who value)
  (when (void? value)
    (raise-arguments-error who "(void) cannot be stored in a jobject; omit the key instead")))

;; ---------------------------------------------------------------------------------------------
;; Plain hashes as objects

(define (object-like? v)
  (or (jobject? v) (hash? v)))

;; hash->jobject : symbol? hash? -> jobject?
;; Keys are converted to symbols and taken in `symbol<?` order. Raises `exn:fail:contract` for a
;; key that is neither a symbol nor a string, for a symbol and a string that name the same key,
;; and for a `(void)` value.
(define (hash->jobject who h)
  (define entries
    (sort (hash-map h (lambda (k v)
                        (unless (or (symbol? k) (string? k))
                          (raise-arguments-error who "hash key is not a symbol or a string"
                                                 "key" k "hash" h))
                        (check-storable who v)
                        (cons (key->symbol who k) v)))
          symbol<?
          #:key car))
  (let loop ([rest entries])
    (when (and (pair? rest) (pair? (cdr rest)))
      (when (eq? (caar rest) (caadr rest))
        (raise-arguments-error who "hash holds the same key as a symbol and as a string"
                               "key" (caar rest) "hash" h))
      (loop (cdr rest))))
  (make-raw-jobject (map car entries)
                    '()
                    (for/fold ([table #hasheq()]) ([entry (in-list entries)])
                      (hash-set table (car entry) (cdr entry)))))

;; ->jobject : symbol? any/c -> jobject?
(define (->jobject who v)
  (cond
    [(jobject? v) v]
    [(hash? v) (hash->jobject who v)]
    [else (raise-argument-error who "(or/c jobject? hash?)" v)]))

;; lookup : symbol? (or/c jobject? hash?) symbol? -> any/c
;; The value stored under `key`, or `absent`. A hash is searched for the symbol and then for the
;; string of the same name.
(define (lookup who obj key)
  (cond
    [(jobject? obj) (hash-ref (jobject-table obj) key absent)]
    [(hash? obj)
     (define by-symbol (hash-ref obj key absent))
     (cond
       [(not (absent? by-symbol)) by-symbol]
       [(hash-equal? obj) (hash-ref obj (symbol->immutable-string key) absent)]
       [else
        ;; An `eq?`- or `eqv?`-keyed hash cannot be probed with a fresh string.
        (define name (symbol->immutable-string key))
        (define found
          (for/first ([(k v) (in-hash obj)]
                      #:when (and (string? k) (string=? k name)))
            (box v)))
        (if found (unbox found) absent)])]
    [else (raise-argument-error who "(or/c jobject? hash?)" obj)]))

;; ---------------------------------------------------------------------------------------------
;; JSON text

;; Escapes for the characters below U+0020, indexed by code point.
(define control-escapes
  (let ([table (make-vector 32 #f)])
    (for ([code (in-range 32)])
      (vector-set! table code
                   (string-append "\\u00" (if (< code 16) "0" "") (number->string code 16))))
    (vector-set! table 8 "\\b")
    (vector-set! table 9 "\\t")
    (vector-set! table 10 "\\n")
    (vector-set! table 12 "\\f")
    (vector-set! table 13 "\\r")
    table))

;; jvalue->text : symbol? any/c (or/c #f exact-positive-integer?) boolean? -> string?
;; The text `JSON.stringify(root, null, indent)` produces. When `lenient?` is false a value that
;; is not a jvalue raises `exn:fail:contract`; when true it is written with `write`, which is
;; what printing a jobject wants.
(define (jvalue->text who root indent lenient?)
  (define buffer (make-string 256))
  (define used 0)
  (define spaces (make-string 64 #\space))

  (define (reserve! extra)
    (define needed (fx+ used extra))
    (when (fx> needed (string-length buffer))
      (define larger (make-string (fxmax needed (fx* 2 (string-length buffer)))))
      (string-copy! larger 0 buffer 0 used)
      (set! buffer larger)))

  (define (add-char! c)
    (reserve! 1)
    (string-set! buffer used c)
    (set! used (fx+ used 1)))

  (define (add-substring! s start end)
    (reserve! (fx- end start))
    (string-copy! buffer used s start end)
    (set! used (fx+ used (fx- end start))))

  (define (add-string! s)
    (add-substring! s 0 (string-length s)))

  (define (add-quoted! s)
    (define n (string-length s))
    (add-char! #\")
    (let loop ([start 0] [i 0])
      (cond
        [(fx= i n) (add-substring! s start n)]
        [else
         (define c (string-ref s i))
         (cond
           [(char<? c #\space)
            (add-substring! s start i)
            (add-string! (vector-ref control-escapes (char->integer c)))
            (loop (fx+ i 1) (fx+ i 1))]
           [(or (char=? c #\") (char=? c #\\))
            (add-substring! s start i)
            (add-char! #\\)
            (add-char! c)
            (loop (fx+ i 1) (fx+ i 1))]
           [else (loop start (fx+ i 1))])]))
    (add-char! #\"))

  ;; With an indent, starts a new line at nesting `level`; without one, writes nothing.
  (define (add-line-break! level)
    (when indent
      (define width (fx* indent level))
      (when (fx> width (string-length spaces))
        (set! spaces (make-string (fx* 2 width) #\space)))
      (add-char! #\newline)
      (add-substring! spaces 0 width)))

  (define (add-flonum! x)
    (cond
      [(fl< -inf.0 x +inf.0) (add-string! (flonum->js-string x))]
      [lenient? (add-string! (number->string x))]
      [else (add-string! "null")]))

  (define (add-object! obj level)
    (define table (jobject-table obj))
    (define keys (jobject-key-list obj))
    (cond
      [(null? keys) (add-string! "{}")]
      [else
       (add-char! #\{)
       (let loop ([keys keys])
         (define key (car keys))
         (add-line-break! (fx+ level 1))
         (add-quoted! (symbol->immutable-string key))
         (add-char! #\:)
         (when indent (add-char! #\space))
         (add-value! (hash-ref table key) (fx+ level 1))
         (unless (null? (cdr keys))
           (add-char! #\,)
           (loop (cdr keys))))
       (add-line-break! level)
       (add-char! #\})]))

  ;; `items` is a pair. A tail that is not a list makes the whole value a non-jvalue.
  (define (add-array! items level)
    (cond
      [(list? items)
       (add-char! #\[)
       (let loop ([items items])
         (add-line-break! (fx+ level 1))
         (add-value! (car items) (fx+ level 1))
         (unless (null? (cdr items))
           (add-char! #\,)
           (loop (cdr items))))
       (add-line-break! level)
       (add-char! #\])]
      [else (add-other! items)]))

  (define (add-other! v)
    (if lenient?
        (add-string! (let ([out (open-output-string)])
                       (write v out)
                       (get-output-string out)))
        (raise-not-jvalue who root v)))

  (define (add-value! v level)
    (cond
      [(string? v) (add-quoted! v)]
      [(jobject? v) (add-object! v level)]
      [(pair? v) (add-array! v level)]
      [(null? v) (add-string! "[]")]
      [(eq? v #t) (add-string! "true")]
      [(eq? v #f) (add-string! "false")]
      [(eq? v 'null) (add-string! "null")]
      [(fixnum? v) (add-string! (js-number->string v))]
      [(flonum? v) (add-flonum! v)]
      [(real? v) (add-flonum! (real->double-flonum v))]
      ;; Printing shows a hash as itself, so it can be told apart from a jobject.
      [(and (hash? v) (not lenient?)) (add-object! (hash->jobject who v) level)]
      [else (add-other! v)]))

  (add-value! root 0)
  (substring buffer 0 used))

;; Raises `exn:fail:contract` naming the offending value and, when it is nested, where it is.
(define (raise-not-jvalue who root bad)
  (if (eq? root bad)
      (raise-argument-error who "jvalue?" root)
      (raise-arguments-error who "value holds something that is not a jvalue"
                             "not a jvalue" bad
                             "at" (or (path-to root bad) "?")
                             "value" root)))

;; A JavaScript-style path such as `a.b[2]` from `root` to the value `eq?` to `target`, or #f.
(define (path-to root target)
  (let search ([v root] [path ""])
    (define (member-path key)
      (format "~a~a~a" path (if (string=? path "") "" ".") key))
    (cond
      [(eq? v target) path]
      [(jobject? v)
       (for/or ([key (in-list (jobject-key-list v))])
         (search (hash-ref (jobject-table v) key) (member-path key)))]
      [(hash? v)
       (for/or ([(key value) (in-hash v)])
         (search value (member-path key)))]
      [(pair? v)
       (let loop ([rest v] [index 0])
         (cond
           [(pair? rest)
            (or (search (car rest) (format "~a[~a]" path index))
                (loop (cdr rest) (add1 index)))]
           [else #f]))]
      [else #f])))
