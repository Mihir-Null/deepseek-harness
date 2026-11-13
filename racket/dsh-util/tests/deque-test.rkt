#lang racket/base
;; Tests for dsh-util/deque. Mirrors the ordering cases of
;; packages/util/deque/tests/deque.spec.ts; the backing-storage cases have no counterpart
;; because the Racket deque is a linked queue.

(require rackunit
         dsh-util/deque)

(test-case "removes tail-appended entries in FIFO order"
  (define d (make-deque))
  (check-equal? (deque-size d) 0)
  (check-false (deque-pop-front! d))
  (deque-push-back! d 1)
  (deque-push-back! d 2)
  (check-equal? (deque-size d) 2)
  (check-equal? (deque-pop-front! d) 1)
  (check-equal? (deque-pop-front! d) 2)
  (check-equal? (deque-size d) 0)
  (check-true (deque-empty? d)))

(test-case "prepends entries before the existing head"
  (define d (make-deque))
  (deque-push-back! d 3)
  (deque-push-front! d 2)
  (deque-push-front! d 1)
  (check-equal? (deque->list d) '(1 2 3))
  (check-equal? (list (deque-pop-front! d) (deque-pop-front! d) (deque-pop-front! d)) '(1 2 3)))

(test-case "preserves order across interleaved growth and removal"
  (define d (make-deque))
  (for ([v (in-range 32)]) (deque-push-back! d v))
  (for ([v (in-range 24)]) (check-equal? (deque-pop-front! d) v))
  (for ([v (in-range 32 128)]) (deque-push-back! d v))
  (for ([v (in-range 24 128)]) (check-equal? (deque-pop-front! d) v))
  (check-equal? (deque-size d) 0))

(test-case "clear drops every entry and the deque stays usable"
  (define d (make-deque))
  (for ([i (in-range 64)]) (deque-push-back! d (list i)))
  (deque-clear! d)
  (check-equal? (deque-size d) 0)
  (check-false (deque-pop-front! d))
  (deque-push-back! d 'value)
  (check-eq? (deque-pop-front! d) 'value))

(test-case "size and the default distinguish a false entry from an empty deque"
  (define d (make-deque))
  (deque-push-back! d #f)
  (check-equal? (deque-size d) 1)
  (check-false (deque-pop-front! d 'empty))
  (check-eq? (deque-pop-front! d 'empty) 'empty))
