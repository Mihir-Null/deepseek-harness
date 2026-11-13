#lang racket/base
;; dsh-util/chunked-list: persistent append-only lists stored as chunks of at most 64 values.
;;
;; source: packages/util/chunked-list/src/index.ts
;;
;; A chunked list is the dsh JSON checkpoint value itself: a jobject {values, previous?} whose
;; `values` is a non-empty list in insertion order and whose `previous` is the next older chunk.
;; #f is the empty list (dsh `undefined`). A projection keeps its facts in this form so that a
;; checkpoint written by either implementation restores in the other. Appending copies at most
;; one chunk and shares every older chunk.

(require racket/contract/base
         cordis-data)

(provide chunk-capacity
         (contract-out
          [chunked-list-append (-> (or/c jobject? hash? #f) any/c jobject?)]
          [chunked-list->list (-> (or/c jobject? hash? #f) list?)]
          [in-chunked-list (-> (or/c jobject? hash? #f) sequence?)]
          [chunked-list-length (-> (or/c jobject? hash? #f) exact-nonnegative-integer?)]
          [chunked-list-valid? (->* (any/c) ((-> any/c any/c)) boolean?)]))

;; source: CHUNK_CAPACITY
(define chunk-capacity 64)

;; Appends `value` without modifying `head`; the result shares the unchanged older chunks.
(define (chunked-list-append head value)
  (cond
    [(or (not head) (= (length (jref head 'values)) chunk-capacity))
     (jobj ['values (list value)]
           #:when head ['previous head])]
    [else
     (define previous (jref head 'previous))
     (jobj ['values (append (jref head 'values) (list value))]
           #:when previous ['previous previous])]))

;; All values in insertion order.
(define (chunked-list->list head)
  (let loop ([chunk head] [acc '()])
    (if chunk
        (loop (jref chunk 'previous) (append (jref chunk 'values) acc))
        acc)))

(define (in-chunked-list head) (chunked-list->list head))

(define (chunked-list-length head)
  (let loop ([chunk head] [n 0])
    (if chunk (loop (jref chunk 'previous) (+ n (length (jref chunk 'values)))) n)))

;; The checkpoint check of dsh `chunkedListSchema`: every chunk is an object with exactly the
;; key `values` and optionally `previous`; `values` holds 1 to 64 members that each satisfy
;; `value-ok?`. #f (the empty list) is not a checkpoint and is not valid here.
(define (chunked-list-valid? v [value-ok? (lambda (_) #t)])
  (let loop ([v v])
    (and (or (jobject? v) (hash? v))
         (let ([keys (jkeys v)])
           (and (memq 'values keys)
                (for/and ([k (in-list keys)]) (memq k '(values previous)))
                #t))
         (let ([values (jref v 'values)])
           (and (list? values)
                (<= 1 (length values) chunk-capacity)
                (for/and ([member (in-list values)]) (and (value-ok? member) #t))))
         (or (not (jhas? v 'previous))
             (loop (jref v 'previous))))))
