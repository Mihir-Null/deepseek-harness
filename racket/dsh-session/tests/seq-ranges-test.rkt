#lang racket/base
;; Tests of `dsh-session/seq-ranges`: rule 33 of the dsh-session contract.
;; Mirrors packages/core/session/tests/seq-ranges.spec.ts.

(require rackunit
         racket/list
         dsh-session/types
         dsh-session/seq-ranges
         "support/log.rkt")

(test-case "rule 33: encoding then decoding gives the list back"
  (for ([values (list '()
                      '(5)
                      '(10 11 12 13 14)
                      '(16 17 100 200 201 202 203)
                      '(3 2)
                      (list (- max-safe-integer 1) 0 (- max-safe-integer 2)))])
    (check-equal? (decode-seq-ranges (encode-seq-ranges values)) values)))

(test-case "rule 33: only runs of three or more increasing seqs become pairs"
  (check-equal? (encode-seq-ranges '(1 3 4 5 7)) '(1 (3 5) 7))
  (check-equal? (encode-seq-ranges '(1 3 4 7)) '(1 3 4 7))
  (check-equal? (encode-seq-ranges '(3 2)) '(3 2))
  (check-equal? (encode-seq-ranges '(10 11 12 13 14)) '((10 14)))
  (check-equal? (encode-seq-ranges '(16 17 100 200 201 202 203)) '(16 17 100 (200 203)))
  (check-equal? (encode-seq-ranges '(0 1 2 4 5 6 8)) '((0 2) (4 6) 8))
  (check-equal? (encode-seq-ranges '()) '())
  (check-equal? (encode-seq-ranges '(7)) '(7)))

(test-case "rule 33: a list that is not strictly increasing is returned unchanged"
  (check-equal? (encode-seq-ranges '(1 2 3 3 4 5)) '(1 2 3 3 4 5))
  (check-equal? (encode-seq-ranges '(5 4 3 2 1)) '(5 4 3 2 1))
  (check-equal? (encode-seq-ranges '(1 2 3 0)) '(1 2 3 0)))

(test-case "rule 33: a source list of any length is encoded"
  (define values (range 1000001))
  (check-equal? (encode-seq-ranges values) '((0 1000000)))
  (check-equal? (length (decode-seq-ranges '((0 1000000)))) 1000001))

(test-case "rule 33: decoding expands pairs between plain seqs"
  (check-equal? (decode-seq-ranges '(1 (3 5) 7)) '(1 3 4 5 7))
  (check-equal? (decode-seq-ranges '((4 4))) '(4))
  (check-equal? (decode-seq-ranges '(2.0 (4.0 5))) '(2 4 5))
  (check-true (andmap exact? (decode-seq-ranges '(2.0 (4.0 5)))))
  ;; Without a pair the order of the stored list is kept as it is.
  (check-equal? (decode-seq-ranges '(3 2 2)) '(3 2 2))
  (check-equal? (decode-seq-ranges '()) '()))

(test-case "rule 33: malformed or impossible expansions are rejected with the dsh text"
  (check-exn (contract-error "sourceEventSeqs must be an array")
             (lambda () (decode-seq-ranges "nope")))
  (check-exn (contract-error "sourceEventSeqs must be an array")
             (lambda () (decode-seq-ranges 'null)))
  (for ([entry (list -1 0.5 (add1 max-safe-integer) +nan.0 +inf.0)])
    (check-exn (contract-error "sourceEventSeqs must contain non-negative safe integers")
               (lambda () (decode-seq-ranges (list entry)))))
  (for ([entry (list '(1) '(1 2 3) '() "1" 'null #t)])
    (check-exn (contract-error "sourceEventSeqs range entries must be [start, end] pairs")
               (lambda () (decode-seq-ranges (list entry)))))
  (check-exn (contract-error "sourceEventSeqs must contain non-negative safe integers")
             (lambda () (decode-seq-ranges '((-1 2)))))
  (check-exn (contract-error "sourceEventSeqs must contain non-negative safe integers")
             (lambda () (decode-seq-ranges '((1 "2")))))
  (check-exn (contract-error "sourceEventSeqs ranges require start <= end")
             (lambda () (decode-seq-ranges '((4 2)))))
  (check-exn (contract-error "sourceEventSeqs ranges must be strictly increasing")
             (lambda () (decode-seq-ranges '((2 5) (4 7)))))
  (check-exn (contract-error "sourceEventSeqs ranges must be strictly increasing")
             (lambda () (decode-seq-ranges '(9 (2 5)))))
  (check-exn (contract-error "sourceEventSeqs exceeds its event sequence")
             (lambda () (decode-seq-ranges '(0) 0)))
  (check-exn (contract-error "sourceEventSeqs exceeds its event sequence")
             (lambda () (decode-seq-ranges '(0 1 2) 2)))
  (check-exn (contract-error "sourceEventSeqs range exceeds its event sequence")
             (lambda () (decode-seq-ranges '((0 10)) 10)))
  (check-equal? (length (decode-seq-ranges '((0 10)) 11)) 11))

(test-case "rule 33: a negative zero is rejected as a seq"
  (check-exn (contract-error "SessionSeq must be a non-negative safe integer, got 0")
             (lambda () (decode-seq-ranges '(-0.0))))
  (check-exn (contract-error "SessionSeq must be a non-negative safe integer, got 0")
             (lambda () (decode-seq-ranges '((-0.0 2))))))

(test-case "rule 33: generated lists round trip"
  (parameterize ([current-pseudo-random-generator (make-pseudo-random-generator)])
    (random-seed 7)
    (for ([trial (in-range 200)])
      (define increasing
        (let loop ([seq (random 5)] [count (random 30)] [acc '()])
          (if (zero? count)
              (reverse acc)
              (loop (+ seq 1 (if (zero? (random 3)) (random 4) 0)) (sub1 count) (cons seq acc)))))
      (define encoded (encode-seq-ranges increasing))
      (check-equal? (decode-seq-ranges encoded) increasing)
      (check-true (<= (length encoded) (length increasing)))
      (define shuffled (shuffle increasing))
      (check-equal? (decode-seq-ranges (encode-seq-ranges shuffled)) shuffled))))
