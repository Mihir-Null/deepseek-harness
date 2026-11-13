#lang racket/base
;; dsh-util/deque: the dsh `Deque<T>` operations as a thin layer over `data/queue`.
;;
;; source: packages/util/deque/src/index.ts
;;
;; dsh keeps a circular buffer that doubles when full and halves at one quarter load, because a
;; JavaScript array has no cheap removal at the front. `data/queue` is a linked queue with
;; constant-time insertion at both ends and removal at the front, and it drops a removed cell at
;; once, so there is no capacity policy to mirror. A deque is not safe for concurrent mutation
;; from plain threads; tasks of one scheduler may share one.

(require racket/contract/base
         data/queue)

(provide (contract-out
          [make-deque (-> deque?)]
          [deque? (-> any/c boolean?)]
          [deque-size (-> deque? exact-nonnegative-integer?)]
          [deque-empty? (-> deque? boolean?)]
          [deque-push-back! (-> deque? any/c void?)]
          [deque-push-front! (-> deque? any/c void?)]
          [deque-pop-front! (->* (deque?) (any/c) any/c)]
          [deque-clear! (-> deque? void?)]
          [deque->list (-> deque? list?)]))

(struct deque ([queue #:mutable]))

(define (make-deque) (deque (make-queue)))

;; Number of entries available to remove.
(define (deque-size d) (queue-length (deque-queue d)))

(define (deque-empty? d) (queue-empty? (deque-queue d)))

;; Appends one entry after the current tail.
(define (deque-push-back! d v) (enqueue! (deque-queue d) v))

;; Inserts one entry before the current head.
(define (deque-push-front! d v) (enqueue-front! (deque-queue d) v))

;; Removes and returns the head entry, or `default` (#f unless given) when the deque is empty.
;; A caller whose entries may equal the default distinguishes the cases with `deque-size`.
(define (deque-pop-front! d [default #f])
  (define q (deque-queue d))
  (if (queue-empty? q) default (dequeue! q)))

;; Drops every entry and the storage that held them.
(define (deque-clear! d) (set-deque-queue! d (make-queue)))

;; The entries from head to tail, without removing them.
(define (deque->list d) (queue->list (deque-queue d)))
