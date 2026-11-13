#lang racket/base
;; The range encoding of `sourceEventSeqs` in stored session logs.
;;
;; The storage form is a list whose members are seqs and inclusive pairs `(list first last)`.
;; Events in memory always hold the expanded list; a storage backend applies the encoding.
;; Decoding raises `exn:fail:contract` with the dsh `TypeError` messages.
;; source: packages/core/session/src/seq-ranges.ts

(require racket/contract/base
         "types.rkt"
         (only-in "private/base.rkt" raise-contract-error))

(provide
 (contract-out
  ;; Each run of three or more consecutive seqs becomes a pair; a list that is not strictly
  ;; increasing is returned unchanged.
  [encode-seq-ranges (-> (listof session-seq?) list?)]
  ;; Expands pairs. `max-entries` bounds the length of the result.
  [decode-seq-ranges (->* (any/c) (exact-nonnegative-integer?) (listof session-seq?))]))

;; `seqs` is a list of exact integers.
(define (strictly-increasing? seqs)
  (or (null? seqs)
      (for/and ([previous (in-list seqs)] [next (in-list (cdr seqs))])
        (> next previous))))

;; source: packages/core/session/src/seq-ranges.ts (encodeSeqRanges)
(define (encode-seq-ranges seqs)
  (cond
    [(not (strictly-increasing? seqs)) seqs]
    [else
     (let loop ([rest seqs] [encoded '()])
       (cond
         [(null? rest) (reverse encoded)]
         [else
          ;; `run` is the maximal run of consecutive seqs at the head of `rest`, reversed.
          (define-values (run tail)
            (let scan ([run (list (car rest))] [tail (cdr rest)])
              (if (and (pair? tail) (= (car tail) (add1 (car run))))
                  (scan (cons (car tail) run) (cdr tail))
                  (values run tail))))
          (loop tail
                (if (>= (length run) 3)
                    (cons (list (car (reverse run)) (car run)) encoded)
                    (append run encoded)))]))]))

;; `Number.isSafeInteger(value) && value >= 0`, which admits -0.
(define (stored-seq? v)
  (and (real? v)
       (or (exact-integer? v) (and (flonum? v) (integer? v)))
       (<= 0 v max-safe-integer)))

(define (check-stored-seq! v)
  (unless (stored-seq? v)
    (raise-contract-error "sourceEventSeqs must contain non-negative safe integers")))

;; source: packages/core/session/src/seq-ranges.ts (decodeSeqRanges)
(define (decode-seq-ranges value [max-entries max-safe-integer])
  (unless (list? value)
    (raise-contract-error "sourceEventSeqs must be an array"))
  (define-values (rev-decoded count has-range?)
    (for/fold ([rev-decoded '()] [count 0] [has-range? #f]) ([entry (in-list value)])
      (cond
        [(real? entry)
         (check-stored-seq! entry)
         (when (>= count max-entries)
           (raise-contract-error "sourceEventSeqs exceeds its event sequence"))
         (values (cons (->session-seq entry) rev-decoded) (add1 count) has-range?)]
        [(and (list? entry) (= (length entry) 2))
         (define start (car entry))
         (define end (cadr entry))
         (check-stored-seq! start)
         (check-stored-seq! end)
         (when (< end start)
           (raise-contract-error "sourceEventSeqs ranges require start <= end"))
         (define last-seq (inexact->exact end))
         (define span (add1 (- last-seq (inexact->exact start))))
         (when (> span (- max-entries count))
           (raise-contract-error "sourceEventSeqs range exceeds its event sequence"))
         (define first-seq (->session-seq start))
         (values (for/fold ([rev-decoded rev-decoded])
                           ([seq (in-range first-seq (add1 last-seq))])
                   (cons seq rev-decoded))
                 (+ count span)
                 #t)]
        [else
         (raise-contract-error "sourceEventSeqs range entries must be [start, end] pairs")])))
  (define decoded (reverse rev-decoded))
  (when (and has-range? (not (strictly-increasing? decoded)))
    (raise-contract-error "sourceEventSeqs ranges must be strictly increasing"))
  decoded)
