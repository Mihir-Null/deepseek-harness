#lang racket/base
;; Tests of `dsh-session/fork`: rule 27 of the dsh-session contract, the seed that
;; `build-fork-seed` makes from a source log and a boundary.
;; Mirrors the seed parts of packages/core/session/tests/fork.spec.ts. The store checks of a
;; fork (rule 26) belong to the store tests.

(require rackunit
         racket/list
         cordis-data
         dsh-session/types
         dsh-session/events
         dsh-session/surface
         dsh-session/repair
         dsh-session/fork
         "support/log.rkt")

;; ---- fixtures ----

(define (closed-turn turn [text (format "hello ~a" turn)]
                     #:reason [reason (jobject 'kind "completed")])
  (list (turn/start #:turn turn)
        (user/message (user-message text) #:surface-op 'append)
        (turn/end #:turn turn #:reason reason)))

(define (tool-request call-id)
  (list (step/start #:turn 2 #:step 1)
        (assistant/message #:turn 2 #:step 1
                           #:message (assistant-message
                                      (list (tool-call-block call-id "bash" "{}")))
                           #:stream '()
                           #:surface-op 'append)))

;; A closed turn 1 followed by an open turn 2 and `inputs`.
(define (open-turn-source . inputs)
  (inputs->events (append (closed-turn 1 "first") (list (turn/start #:turn 2)) inputs)))

(define (last-seq events)
  (session-event-seq (last events)))

;; The seed split into the copied prefix, the marker and the closers.
(define (seed-parts events boundary)
  (define seed (build-fork-seed events boundary))
  (define-values (prefix rest) (split-at seed (add1 boundary)))
  (values seed prefix (car rest) (cdr rest)))

(define (texts events)
  (for/list ([message (in-list (derive-messages events))])
    (jref* message '(content 0 text))))

;; ---- rule 27 ----

(test-case "rule 27: a closed log is copied and marked, with no closers"
  (define source (inputs->events (closed-turn 1 "hello")))
  (define-values (seed prefix marker closers) (seed-parts source (last-seq source)))
  (check-equal? prefix source)
  (for ([copied (in-list prefix)] [original (in-list source)])
    (check-eq? copied original))
  (check-equal? closers '())
  (check-equal? (length seed) (add1 (length source)))
  (check-equal? (jvalue->string (session-event->jvalue marker))
                (format "{\"type\":\"session/end-seed\",\"seq\":3,\"time\":~a,\"data\":~a}"
                        (session-event-time (last source))
                        "{\"inherited\":true}"))
  (check-true (session/end-seed? marker))
  (check-true (session/end-seed-inherited marker)))

(test-case "rule 27: the marker takes the seq after the boundary and the boundary's time"
  (define source
    (list (raw-event "turn/start" 0 (jobject 'turn 1) #:time 500)
          (raw-event "turn/end" 1 (jobject 'turn 1 'reason (jobject 'kind "completed"))
                     #:time 900)
          (raw-event "turn/start" 2 (jobject 'turn 2) #:time 1200)))
  (define-values (seed prefix marker closers) (seed-parts source 1))
  (check-equal? (session-event-seq marker) 2)
  (check-equal? (session-event-time marker) 900)
  (check-equal? (map session-event-seq seed) '(0 1 2)))

(test-case "rule 27: an earlier boundary inherits only the events through it"
  (define source
    (inputs->events
     (append (closed-turn 1 "first")
             (closed-turn 2 "second")
             (list (turn/start #:turn 3)
                   (user/message (user-message "open 3") #:surface-op 'append)))))
  (define first-boundary 2)
  (define-values (seed prefix marker closers) (seed-parts source first-boundary))
  (check-equal? prefix (take source 3))
  (check-equal? closers '())
  (check-equal? (texts seed) '("first"))
  (check-equal? (length seed) 4))

(test-case "rule 27: stable log-only events after a closed turn are inherited"
  (define source
    (append (inputs->events (closed-turn 1 "hello"))
            (list (raw-event "test/log-only" 3 (jobject 'value "after execution")
                             #:time 1003))))
  (define-values (seed prefix marker closers) (seed-parts source (last-seq source)))
  (check-equal? prefix source)
  (check-equal? (session-event-type (last prefix)) "test/log-only")
  (check-equal? closers '()))

(test-case "rule 27: every turn/end reason is a valid boundary"
  (for ([reason (list (jobject 'kind "completed")
                      (jobject 'kind "aborted" 'reason (jobject 'kind "user"))
                      (jobject 'kind "error"
                               'error (jobject 'message "model failed" 'code "UNKNOWN"))
                      (jobject 'kind "aborted" 'reason (jobject 'kind "disposed"))
                      (jobject 'kind "max-tokens")
                      (jobject 'kind "interrupted"))])
    (define source (inputs->events (closed-turn 1 "x" #:reason reason)))
    (define-values (seed prefix marker closers) (seed-parts source (last-seq source)))
    (check-equal? (session-event-type (last prefix)) "turn/end")
    (check-equal? closers '())))

(test-case "rule 27: an empty open turn is closed with turn/end {forked}"
  (define source (open-turn-source))
  (define-values (seed prefix marker closers) (seed-parts source (last-seq source)))
  (check-equal? prefix source)
  (check-equal? (map session-event-type closers) '("turn/end"))
  (check-equal? (session-event-data (car closers))
                (jobject 'turn 2 'reason (jobject 'kind "forked")))
  ;; The closers follow the marker, outside the inherited prefix.
  (check-equal? (session-event-seq marker) (length source))
  (check-equal? (session-event-seq (car closers)) (add1 (length source)))
  (check-equal? (session-event-time (car closers)) (session-event-time marker)))

(test-case "rule 27: a cut on a closed step boundary closes only the turn"
  (define source
    (open-turn-source (step/start #:turn 2 #:step 1)
                      (assistant/message #:turn 2 #:step 1
                                         #:message (assistant-message "step done")
                                         #:stream '()
                                         #:surface-op 'append)
                      (step/end #:turn 2 #:step 1)))
  (define-values (seed prefix marker closers) (seed-parts source (last-seq source)))
  (check-equal? (map session-event-type closers) '("turn/end")))

(test-case "rule 27: a call cut before its tool/call gets a forked not-started result"
  (define source (apply open-turn-source (tool-request "call-ns")))
  (define-values (seed prefix marker closers) (seed-parts source (last-seq source)))
  (check-equal? (map session-event-type closers) '("tool/result" "step/end" "turn/end"))
  (define result (car closers))
  (define data (session-event-data result))
  (check-equal? (jref* data '(message id))
                (format "forked-tool-result-call-ns-~a" (session-event-seq result)))
  (check-equal? (jref* data '(message source callId)) "call-ns")
  (check-equal? (jref data 'error)
                (jobject 'name "ToolNotStartedError" 'code tool-not-started))
  (check-false (session-event-source-seqs result))
  ;; The synthetic result is part of the child's derived history.
  (define derived (derive-messages seed))
  (define final (last derived))
  (check-equal? (jref final 'role) "tool")
  (check-equal? (jref final 'source) (jobject 'kind "tool" 'callId "call-ns"))
  (check-equal? (jref final 'toolCallId) "call-ns")
  (check-eq? (jref final 'isError) #t)
  (check-equal? (jref* final '(content 0 type)) "text"))

(test-case "rule 27: a dispatched call cut before its result cites its tool/call"
  (define source
    (apply open-turn-source
           (append (tool-request "call-uo")
                   (list (tool/call #:turn 2 #:step 1 #:call-id "call-uo" #:name "bash"
                                    #:arguments "{}")))))
  (define call-seq (last-seq source))
  (define-values (seed prefix marker closers) (seed-parts source call-seq))
  (check-equal? (map session-event-type closers) '("tool/result" "step/end" "turn/end"))
  (check-equal? (jref (session-event-data (car closers)) 'error)
                (jobject 'name "ToolOutcomeUnknownError" 'code tool-outcome-unknown))
  (check-equal? (session-event-source-seqs (car closers)) (list call-seq))
  (check-equal? (map session-event-seq closers)
                (list (+ call-seq 2) (+ call-seq 3) (+ call-seq 4))))

(test-case "rule 27: a failed assistant attempt adds no message to the child's history"
  (define source
    (open-turn-source (step/start #:turn 2 #:step 1)
                      (assistant/attempt #:turn 2 #:step 1 #:stream '())))
  (define-values (seed prefix marker closers) (seed-parts source (last-seq source)))
  (check-equal? (map session-event-type closers) '("step/end" "turn/end"))
  (check-false (for/or ([message (in-list (derive-messages seed))])
                 (equal? (jref message 'role) "assistant"))))

(test-case "rule 27: a closed step with an unanswered call is preserved"
  (for ([turn-ended? (list #f #t)])
    (define failure
      (jobject 'kind "error" 'error (jobject 'message "scheduler failed" 'code "UNKNOWN")))
    (define source
      (apply open-turn-source
             (append (tool-request "call-dangling")
                     (list (tool/call #:turn 2 #:step 1 #:call-id "call-dangling" #:name "bash"
                                      #:arguments "{}")
                           (step/end #:turn 2 #:step 1))
                     (if turn-ended? (list (turn/end #:turn 2 #:reason failure)) '()))))
    (define-values (seed prefix marker closers) (seed-parts source (last-seq source)))
    (check-equal? prefix source)
    (check-equal?
     (map (lambda (event) (jvalue->string (session-event->jvalue event))) closers)
     (if turn-ended?
         '()
         (list (format "{\"type\":\"turn/end\",\"seq\":~a,\"time\":~a,\"data\":~a}"
                       (add1 (length source))
                       (session-event-time (last source))
                       "{\"turn\":2,\"reason\":{\"kind\":\"forked\"}}"))))
    (check-equal? (derive-messages seed) (derive-messages source))))

(test-case "rule 27: a plugin bracket left open at the cut is not closed"
  (define source
    (append (open-turn-source)
            (list (raw-event "test/bracket-open" 4 (jobject 'id "op-live") #:time 1004))))
  (define-values (seed prefix marker closers) (seed-parts source (last-seq source)))
  (check-equal? (map session-event-type closers) '("turn/end"))
  (check-equal? (session-event-type marker) "session/end-seed")
  (check-equal? (session-event-data marker) (jobject 'inherited #t)))

(test-case "rule 27: a cut before a surface replacement derives the original message"
  (define source
    (inputs->events
     (append (closed-turn 1 "original request")
             (list (turn/start #:turn 2)
                   (user/message (user-message "summary of earlier work"
                                               #:source (jobject 'kind "compact-checkpoint"
                                                                 'compactionId "open-bracket"))
                                 #:surface-op (surface-replace 1 1)
                                 #:sources '(1))))))
  (define replacement-seq (last-seq source))
  (check-equal? (texts (build-fork-seed source (sub1 replacement-seq))) '("original request"))
  (define after (build-fork-seed source replacement-seq))
  (check-equal? (texts after) '("summary of earlier work"))
  (check-equal? (session-event-type (last after)) "turn/end")
  (check-equal? (session-event-data (last after))
                (jobject 'turn 2 'reason (jobject 'kind "forked"))))

(test-case "rule 27: an ancestor marker in the prefix does not stop the child's own marker"
  (define source
    (append (inputs->events (closed-turn 1 "inherited"))
            (list (raw-event "session/end-seed" 3 (jobject 'inherited #t) #:time 1003))
            (inputs->events (list (turn/start #:turn 2)) #:from 4)))
  (define-values (seed prefix marker closers) (seed-parts source 4))
  (check-equal? (session-event-seq marker) 5)
  (check-equal? (session-event-data marker) (jobject 'inherited #t))
  (check-equal? (map session-event-type closers) '("turn/end")))

(test-case "rule 27: a seed is a contiguous log that folds and is balanced"
  (define source
    (apply open-turn-source
           (append (tool-request "call-1")
                   (list (tool/call #:turn 2 #:step 1 #:call-id "call-1" #:name "bash"
                                    #:arguments "{}")))))
  (for ([boundary (in-range (length source))])
    (define seed (build-fork-seed source boundary))
    (check-equal? (map session-event-seq seed) (range (length seed)))
    (check-not-exn (lambda () (fold-surface seed)))
    (check-equal? (open-turn-closers seed 'forked) '())
    (check-equal? (interrupted-turn-closers seed) '())
    (check-equal? (take seed (add1 boundary)) (take source (add1 boundary)))
    (check-equal? (session-event-type (list-ref seed (add1 boundary))) "session/end-seed")))

(test-case "rule 27: the sample log forks at every boundary"
  (define source (sample-log))
  (for ([boundary (in-range (length source))])
    (define seed (build-fork-seed source boundary))
    (check-not-exn (lambda () (fold-surface seed)))
    (check-equal? (open-turn-closers seed 'forked) '()))
  ;; Cut after the tool/call at seq 7: marker, unknown-outcome result, step/end, turn/end.
  (check-equal? (map session-event-type (drop (build-fork-seed source 7) 8))
                '("session/end-seed" "tool/result" "step/end" "turn/end")))

(test-case "rule 27: the boundary must be the seq of an event of the log"
  (define source (inputs->events (closed-turn 1)))
  (check-exn exn:fail:contract? (lambda () (build-fork-seed source 3)))
  (check-exn exn:fail:contract? (lambda () (build-fork-seed source -1)))
  (check-exn exn:fail:contract? (lambda () (build-fork-seed '() 0))))
