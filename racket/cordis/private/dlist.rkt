#lang racket/base
;; An insertion-ordered set of values compared with `eq?`: the counterpart of
;; `DisposableList` in vendor/cordis/src/utils.ts. Not thread-safe; kernel code uses it
;; under the baton.
(provide make-dlist dlist? dlist-push! dlist-push-front! dlist-delete! dlist-member?
         dlist-clear! dlist->list dlist-count)

;; by-sn : serial number -> value; by-value : value -> serial number
(struct dlist (by-sn by-value [next #:mutable] [first #:mutable]))

(define (make-dlist)
  (dlist (make-hasheqv) (make-hasheq) 1 0))

;; Appends `v`; a value already present moves to the end.
(define (dlist-push! l v)
  (dlist-delete! l v)
  (define sn (dlist-next l))
  (set-dlist-next! l (add1 sn))
  (hash-set! (dlist-by-sn l) sn v)
  (hash-set! (dlist-by-value l) v sn))

;; Inserts `v` before every present value; a value already present moves to the front.
(define (dlist-push-front! l v)
  (dlist-delete! l v)
  (define sn (dlist-first l))
  (set-dlist-first! l (sub1 sn))
  (hash-set! (dlist-by-sn l) sn v)
  (hash-set! (dlist-by-value l) v sn))

;; Returns #t when `v` was present.
(define (dlist-delete! l v)
  (define sn (hash-ref (dlist-by-value l) v #f))
  (cond
    [sn
     (hash-remove! (dlist-by-value l) v)
     (hash-remove! (dlist-by-sn l) sn)
     #t]
    [else #f]))

(define (dlist-member? l v)
  (and (hash-ref (dlist-by-value l) v #f) #t))

(define (dlist-count l)
  (hash-count (dlist-by-sn l)))

;; Values in insertion order.
(define (dlist->list l)
  (define by-sn (dlist-by-sn l))
  (for/list ([sn (in-list (sort (hash-keys by-sn) <))])
    (hash-ref by-sn sn)))

;; Empties the list and returns the values, newest first.
(define (dlist-clear! l)
  (define vs (reverse (dlist->list l)))
  (hash-clear! (dlist-by-sn l))
  (hash-clear! (dlist-by-value l))
  vs)
