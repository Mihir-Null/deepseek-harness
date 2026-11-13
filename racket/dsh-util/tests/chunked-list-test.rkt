#lang racket/base
;; Tests for dsh-util/chunked-list. Mirrors
;; packages/util/chunked-list/tests/chunked-list.spec.ts.

(require rackunit
         racket/list
         cordis-data
         dsh-util/chunked-list)

(test-case "iterates an empty list"
  (check-equal? (chunked-list->list #f) '())
  (check-equal? (chunked-list-length #f) 0)
  (check-equal? (chunked-list->list (chunked-list-append #f 'null)) '(null)))

(test-case "keeps every prefix unchanged across chunk rollovers and divergent appends"
  (define prefixes
    (for/fold ([acc '()] #:result (list->vector (reverse acc))) ([value (in-range 200)])
      (cons (chunked-list-append (if (null? acc) #f (car acc)) value) acc)))
  (for ([prefix (in-vector prefixes)] [index (in-naturals)])
    (check-equal? (chunked-list->list prefix) (range (add1 index)))
    (check-equal? (chunked-list-length prefix) (add1 index)))
  (check-eq? (jref (vector-ref prefixes 64) 'previous) (vector-ref prefixes 63))
  (check-eq? (jref (vector-ref prefixes 65) 'previous) (vector-ref prefixes 63))
  (check-equal? (chunked-list->list (chunked-list-append (vector-ref prefixes 64) -1))
                (append (range 65) '(-1)))
  (check-equal? (chunked-list->list (vector-ref prefixes 65)) (range 66)))

(test-case "retains stored values by reference"
  (define value (jobj ['id "first"]))
  (check-eq? (car (chunked-list->list (chunked-list-append #f value))) value))

(test-case "the checkpoint text is the dsh JSON form"
  (define head (for/fold ([head #f]) ([v (in-range 66)]) (chunked-list-append head v)))
  (check-equal? (jkeys head) '(values previous))
  (check-equal? (jvalue->string (chunked-list-append (chunked-list-append #f 1) 2))
                "{\"values\":[1,2]}")
  (check-equal? (length (jref head 'values)) 2)
  (check-equal? (length (jref* head '(previous values))) 64))

(test-case "restores JSON checkpoints and appends at and after rollover"
  (define head
    (for/fold ([head #f]) ([value (in-range 130)])
      (define next (string->jvalue (jvalue->string (chunked-list-append head value))))
      (check-true (chunked-list-valid? next exact-integer?))
      next))
  (check-equal? (chunked-list->list head) (range 130))
  (check-equal? (for/list ([v (in-chunked-list head)]) v) (range 130)))

(test-case "rejects an invalid checkpoint"
  (define zeros65 (make-list 65 0))
  (for ([checkpoint
         (list (jobj ['values '()])
               (jobj ['values zeros65])
               (jobj ['values '("invalid")])
               (jobj ['values '(0)] ['extra #t])
               (jobj ['values '(0)] ['previous (jobj ['values '()])])
               (jobj ['values '(0)] ['previous (jobj ['values zeros65])])
               (jobj ['values '(0)] ['previous (jobj ['values '("invalid")])])
               (jobj ['values '(0)] ['previous (jobj ['values '(1)] ['extra #t])])
               (jobj ['previous (jobj ['values '(1)])])
               '(0)
               #f)])
    (check-false (chunked-list-valid? checkpoint exact-integer?) (format "~s" checkpoint)))
  (check-true (chunked-list-valid? (jobj ['values '(0)] ['previous (jobj ['values '(1)])])
                                   exact-integer?)))
