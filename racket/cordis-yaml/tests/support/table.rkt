#lang racket/base
;; Provides the reader of the differential table that tests/gen/gen-js-yaml-table.mjs writes,
;; the two directions of its value encoding, and the comparison the table tests use.
;;
;; The table encodes a JavaScript value as a datum Racket's reader rebuilds without the code
;; under test: an object is a list of (key . value) pairs in JavaScript's enumeration order,
;; an array a vector, null and undefined the symbols of those names, an expression node
;; (js "source"), a URL (url "href"), a function (function).

(require racket/list
         racket/runtime-path
         cordis-data
         cordis-yaml
         cordis-yaml/js-expr)

(provide table-path
         load-table
         table-rows
         datum->value
         value->datum
         same-datum?
         js-ordered)

(define-runtime-path table-path "../data/js-yaml-table.rktd")

;; load-table : [path-string?] -> hash?   Section name (symbol) -> rows.
(define (load-table [path table-path])
  (for/hasheq ([section (in-list (call-with-input-file path read))])
    (values (car section) (cdr section))))

(define (table-rows table name)
  (hash-ref table name))

;; datum->value : any/c -> any/c   The Racket value an encoded value stands for.
(define (datum->value d)
  (cond
    [(eq? d 'null) 'null]
    [(eq? d 'undefined) (void)]
    [(vector? d) (for/list ([item (in-vector d)]) (datum->value item))]
    [(null? d) empty-jobject]
    [(and (pair? d) (eq? (car d) 'js)) (make-js-expr (cadr d))]
    [(and (pair? d) (pair? (car d)))
     (make-jobject (for/list ([member (in-list d)])
                     (cons (string->symbol (car member)) (datum->value (cdr member)))))]
    [else d]))

(define (index-key? name)
  (and (regexp-match? #px"^(?:0|[1-9][0-9]*)$" name)
       (< (string->number name 10) 4294967295)))

;; JavaScript's own-key order: array indexes ascending, then the other keys as written.
(define (js-key-order members)
  (define-values (indexes others) (partition (lambda (m) (index-key? (car m))) members))
  (append (sort indexes < #:key (lambda (m) (string->number (car m) 10))) others))

;; value->datum : any/c #:js-order? boolean? -> any/c
;; The table encoding of a Racket value. With `js-order?` the members of every object are put
;; in JavaScript's order, which is how js-yaml's result enumerates them.
(define (value->datum v #:js-order? [js-order? #f])
  (let encode ([v v])
    (cond
      [(void? v) 'undefined]
      [(js-expr? v) (list 'js (js-expr-source v))]
      [(list? v) (for/vector ([item (in-list v)]) (encode item))]
      [(or (jobject? v) (hash? v))
       (define members
         (for/list ([(key item) (in-jobject (if (jobject? v) v (jmerge v)))])
           (cons (symbol->string key) (encode item))))
       (if js-order? (js-key-order members) members)]
      [(procedure? v) '(function)]
      [(js-object? v)
       (define href (js-get-property v "href"))
       (if (string? href) (list 'url href) '(object))]
      [else v])))

;; js-ordered : any/c -> any/c   `v` with the members of every object in JavaScript's order.
(define (js-ordered v)
  (cond [(list? v) (map js-ordered v)]
        [(jobject? v)
         (make-jobject
          (for/list ([member (in-list (js-key-order
                                       (for/list ([(key item) (in-jobject v)])
                                         (cons (symbol->string key) (js-ordered item)))))])
            (cons (string->symbol (car member)) (cdr member))))]
        [else v]))

;; same-datum? : any/c any/c -> boolean?
;; Structural equality of two encoded values. Numbers are compared as doubles, with NaN equal
;; to NaN and -0 different from 0, as the table means them.
(define (same-datum? a b)
  (cond
    [(and (real? a) (real? b))
     (eqv? (real->double-flonum a) (real->double-flonum b))]
    [(and (string? a) (string? b)) (string=? a b)]
    [(and (vector? a) (vector? b))
     (and (= (vector-length a) (vector-length b))
          (for/and ([x (in-vector a)] [y (in-vector b)]) (same-datum? x y)))]
    [(and (pair? a) (pair? b))
     (and (same-datum? (car a) (car b)) (same-datum? (cdr a) (cdr b)))]
    [else (equal? a b)]))
