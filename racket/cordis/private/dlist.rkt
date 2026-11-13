#lang racket/base
;; An insertion-ordered set of values compared with `eq?`: the counterpart of
;; `DisposableList` in vendor/cordis/src/utils.ts.
;;
;; Mutation is for the task that holds the baton. `dlist->list`, `dlist-count` and
;; `dlist-member?` may also be called by a thread that only reads: the cached order carries
;; the version it was computed for and is ignored once the list has changed. The version is
;; advanced after each change, so an order computed during a change is never trusted.
(provide make-dlist dlist? dlist-push! dlist-push-front! dlist-delete! dlist-member?
         dlist-clear! dlist->list dlist-count)

;; by-sn : serial number -> value; by-value : value -> serial number;
;; version : counts mutations; cache : (cons version values-in-order) or #f
(struct dlist (by-sn by-value
                     [next #:mutable] [first #:mutable] [version #:mutable] [cache #:mutable]))

(define (make-dlist)
  (dlist (make-hasheqv) (make-hasheq) 1 0 0 #f))

(define (touch! l)
  (set-dlist-version! l (add1 (dlist-version l))))

;; Appends `v`; a value already present moves to the end.
(define (dlist-push! l v)
  (dlist-delete! l v)
  (define sn (dlist-next l))
  (set-dlist-next! l (add1 sn))
  (hash-set! (dlist-by-sn l) sn v)
  (hash-set! (dlist-by-value l) v sn)
  (touch! l))

;; Inserts `v` before every present value; a value already present moves to the front.
(define (dlist-push-front! l v)
  (dlist-delete! l v)
  (define sn (dlist-first l))
  (set-dlist-first! l (sub1 sn))
  (hash-set! (dlist-by-sn l) sn v)
  (hash-set! (dlist-by-value l) v sn)
  (touch! l))

;; Returns #t when `v` was present.
(define (dlist-delete! l v)
  (define sn (hash-ref (dlist-by-value l) v #f))
  (cond
    [sn
     (hash-remove! (dlist-by-value l) v)
     (hash-remove! (dlist-by-sn l) sn)
     (touch! l)
     #t]
    [else #f]))

(define (dlist-member? l v)
  (and (hash-ref (dlist-by-value l) v #f) #t))

(define (dlist-count l)
  (hash-count (dlist-by-sn l)))

;; Values in insertion order.
(define (dlist->list l)
  (define version (dlist-version l))
  (define cache (dlist-cache l))
  (cond
    [(and cache (eqv? (car cache) version)) (cdr cache)]
    [else
     (define by-sn (dlist-by-sn l))
     (define vs
       (for*/list ([sn (in-list (sort (hash-keys by-sn) <))]
                   [v (in-value (hash-ref by-sn sn by-sn))]
                   #:unless (eq? v by-sn))
         v))
     (set-dlist-cache! l (cons version vs))
     vs]))

;; Empties the list and returns the values, newest first.
(define (dlist-clear! l)
  (define vs (reverse (dlist->list l)))
  (hash-clear! (dlist-by-sn l))
  (hash-clear! (dlist-by-value l))
  (touch! l)
  vs)
