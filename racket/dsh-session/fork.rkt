#lang racket/base
;; Fork seed construction over an exact prefix of a source log.
;;
;; The seed is the source events through the boundary, the marker `session/end-seed
;; {inherited: true}` at the next seq with the time of the boundary event, and the closers
;; that end a turn left open at the cut, with the cause `forked`. The caller has checked that
;; the boundary is the seq of an existing event of a contiguous log.
;; source: packages/core/session/src/fork.ts

(require racket/contract/base
         racket/list
         cordis-data
         "types.rkt"
         "repair.rkt")

(provide
 (contract-out
  ;; `boundary` is the inclusive seq the child inherits through; it must index `events`.
  [build-fork-seed
   (->i ([events (listof session-event?)]
         [boundary (events) (and/c session-seq? (</c (length events)))])
        [result (listof session-event?)])]))

(define (build-fork-seed events boundary)
  (define inherited (take events (add1 boundary)))
  (define marker
    (make-session-event "session/end-seed"
                        (add1 boundary)
                        (session-event-time (list-ref events boundary))
                        (jobject 'inherited #t)))
  (define prefix (append inherited (list marker)))
  (append prefix (open-turn-closers prefix 'forked)))
