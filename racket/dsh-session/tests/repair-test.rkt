#lang racket/base
;; Tests of `dsh-session/repair`: rules 30 and 31 of the dsh-session contract, the four
;; model-visible texts, the ids and the key order of synthetic events.
;; Mirrors packages/core/session/tests/repair.spec.ts.

(require rackunit
         racket/file
         racket/string
         cordis-data
         dsh-session/types
         dsh-session/events
         dsh-session/surface
         dsh-session/repair
         "support/log.rkt")

;; ---- fixtures ----

(define (turn-start turn seq)
  (raw-event "turn/start" seq (jobject 'turn turn)))

(define (step-start turn step seq)
  (raw-event "step/start" seq (jobject 'turn turn 'step step)))

(define (step-end turn step seq)
  (raw-event "step/end" seq (jobject 'turn turn 'step step)))

(define (turn-end turn seq)
  (raw-event "turn/end" seq (jobject 'turn turn 'reason (jobject 'kind "completed"))))

;; An assistant message of `turn` and `step` that requests one tool call per id.
(define (tool-requests turn step seq call-ids #:time [time seq] #:text [text #f])
  (raw-event "assistant/message" seq
             (jobject 'turn turn 'step step 'stream '()
                      'message (assistant-message
                                (append (if text (list (text-block text)) '())
                                        (for/list ([id (in-list call-ids)])
                                          (tool-call-block id "bash" "{}")))))
             #:time time
             #:surface-op "append"))

(define (tool-call turn step seq call-id #:time [time seq])
  (raw-event "tool/call" seq
             (jobject 'turn turn 'step step 'callId call-id 'name "bash" 'arguments "{}")
             #:time time))

(define (tool-answer turn step seq call-id
                     #:time [time seq]
                     #:op [op "append"]
                     #:sources [sources absent])
  (raw-event "tool/result" seq
             (jobject 'turn turn 'step step 'message (tool-result-message call-id "old result"))
             #:time time #:surface-op op #:sources sources))

(define (summary event)
  (define data (session-event-data event))
  (list (session-event-seq event)
        (session-event-time event)
        (jref data 'turn)
        (jref data 'step)
        (jref* data '(message toolCallId))
        (jref* data '(error code))
        (session-event-source-seqs event)))

(define (result-text event)
  (jref* (session-event-data event) '(message content 0 text)))

(define causes '(interrupted forked))

(define (take-results events)
  (filter (lambda (e) (equal? (session-event-type e) "tool/result")) events))

;; ---- the four texts ----
;; source: packages/core/session/src/repair.ts (CLOSER_TEXT)

(define interrupted-started
  (string-append
   "The tool call was interrupted after it was recorded, but no result was durably "
   "recorded. Its outcome is unknown. Decide whether to retry from the tool "
   "semantics: retry only if the operation is read-only or idempotent; if it may "
   "have side effects, first verify external state or ask the user. Do not retry "
   "blindly."))

(define interrupted-not-started
  (string-append
   "The tool call was interrupted before the Harness recorded it as started. Retry "
   "it if it is still needed."))

(define forked-started
  (string-append
   "The history inherited by this branch records this tool call starting but does "
   "not include its result. The parent session may have completed it after the "
   "fork point. Decide whether to retry from the tool semantics: retry only if the "
   "operation is read-only or idempotent; if it may have side effects, first "
   "verify external state or ask the user. Do not retry blindly."))

(define forked-not-started
  (string-append
   "The history inherited by this branch has no record of this tool call starting. "
   "The parent session may have executed it after the fork point. Decide whether "
   "to retry from the tool semantics: retry only if the operation is read-only or "
   "idempotent; if it may have side effects, first verify external state or ask "
   "the user. Do not retry blindly."))

(define (expected-text cause started?)
  (case cause
    [(interrupted) (if started? interrupted-started interrupted-not-started)]
    [else (if started? forked-started forked-not-started)]))

;; An open turn with one unanswered call; `started?` also logs its tool/call.
(define (open-call started?)
  (append (list (turn-start 1 0) (step-start 1 1 1) (tool-requests 1 1 2 '("call-1")))
          (if started? (list (tool-call 1 1 3 "call-1")) '())))

;; ---- rule 31: the recovery tracker ----

(test-case "rule 31: the two recovery codes"
  (check-equal? tool-not-started "TOOL_NOT_STARTED")
  (check-equal? tool-outcome-unknown "TOOL_OUTCOME_UNKNOWN"))

(test-case "rule 31: a live step is observed and repairs last until their commits arrive"
  (define recovery (make-tool-call-recovery))
  (check-true (tool-call-recovery? recovery))
  (check-equal? (tool-call-recovery-results recovery) '())
  (tool-call-recovery-observe! recovery (step-start 3 2 20))
  (tool-call-recovery-observe! recovery
                               (tool-requests 3 2 21 '("started" "pending") #:time 110))
  (tool-call-recovery-observe! recovery (tool-call 3 2 22 "started" #:time 120))
  (define results (tool-call-recovery-results recovery))
  (check-equal? (map summary results)
                (list (list 23 120 3 2 "started" tool-outcome-unknown '(22))
                      (list 24 120 3 2 "pending" tool-not-started #f)))
  ;; Building the results does not change the tracker.
  (check-equal? (tool-call-recovery-results recovery) results)
  (for ([event (in-list results)] [index (in-naturals 1)])
    (tool-call-recovery-observe! recovery event)
    (check-equal? (map (lambda (e) (jref* (session-event-data e) '(message toolCallId)))
                       (tool-call-recovery-results recovery))
                  (list-tail '("started" "pending") index))))

(test-case "rule 31: a result that reuses the id does not answer another turn, step or node"
  (for ([answer (list (tool-answer 3 2 22 "started" #:time 120
                                   #:op (replace-op 10 10) #:sources (list 10))
                      (tool-answer 2 2 22 "started" #:time 120)
                      (tool-answer 3 1 22 "started" #:time 120))])
    (define recovery (make-tool-call-recovery))
    (tool-call-recovery-observe! recovery (tool-requests 3 2 21 '("started" "pending")))
    (tool-call-recovery-observe! recovery answer)
    (check-equal? (map (lambda (e) (jref* (session-event-data e) '(message toolCallId)))
                       (tool-call-recovery-results recovery))
                  '("started" "pending"))))

(test-case "rule 31: boundaries clear the pending calls"
  (for ([boundary (list (turn-start 4 22) (turn-end 3 22) (step-end 3 2 22))])
    (define recovery (make-tool-call-recovery))
    (tool-call-recovery-observe! recovery (tool-requests 3 2 21 '("a" "b")))
    (check-equal? (length (tool-call-recovery-results recovery)) 2)
    (tool-call-recovery-observe! recovery boundary)
    (check-equal? (tool-call-recovery-results recovery) '()))
  ;; step/start and unrelated events keep them.
  (define recovery (make-tool-call-recovery))
  (tool-call-recovery-observe! recovery (tool-requests 3 2 21 '("a")))
  (tool-call-recovery-observe! recovery (step-start 3 3 22))
  (tool-call-recovery-observe! recovery (raw-event "request/context" 23 (jobject)))
  (check-equal? (map summary (tool-call-recovery-results recovery))
                (list (list 24 23 3 2 "a" tool-not-started #f))))

(test-case "rule 31: a repeated request id keeps its position and loses its recorded call"
  (define recovery (make-tool-call-recovery))
  (tool-call-recovery-observe! recovery (tool-requests 1 1 0 '("a" "b")))
  (tool-call-recovery-observe! recovery (tool-call 1 1 1 "a"))
  (tool-call-recovery-observe! recovery (tool-requests 1 2 2 '("a")))
  (check-equal? (map summary (tool-call-recovery-results recovery))
                (list (list 3 2 1 2 "a" tool-not-started #f)
                      (list 4 2 1 1 "b" tool-not-started #f))))

(test-case "rule 31: the synthetic result, key for key"
  (define started
    (car (tool-call-recovery-results
          (let ([recovery (make-tool-call-recovery)])
            (for ([event (in-list (open-call #t))])
              (tool-call-recovery-observe! recovery event))
            recovery))))
  (check-equal?
   (jvalue->string (session-event->jvalue started))
   (string-append
    "{\"type\":\"tool/result\",\"seq\":4,\"time\":3,\"data\":{\"turn\":1,\"step\":1,"
    "\"message\":{\"id\":\"interrupted-tool-result-call-1-4\",\"role\":\"tool\","
    "\"toolCallId\":\"call-1\",\"isError\":true,"
    "\"source\":{\"kind\":\"tool\",\"callId\":\"call-1\"},"
    "\"content\":[{\"type\":\"text\",\"text\":" (jvalue->string interrupted-started) "}]},"
    "\"error\":{\"name\":\"ToolOutcomeUnknownError\",\"code\":\"TOOL_OUTCOME_UNKNOWN\"}},"
    "\"surfaceOp\":\"append\",\"sourceEventSeqs\":[3]}"))
  (define not-started
    (car (tool-call-recovery-results
          (let ([recovery (make-tool-call-recovery 'forked)])
            (for ([event (in-list (open-call #f))])
              (tool-call-recovery-observe! recovery event))
            recovery))))
  (check-equal?
   (jvalue->string (session-event->jvalue not-started))
   (string-append
    "{\"type\":\"tool/result\",\"seq\":3,\"time\":2,\"data\":{\"turn\":1,\"step\":1,"
    "\"message\":{\"id\":\"forked-tool-result-call-1-3\",\"role\":\"tool\","
    "\"toolCallId\":\"call-1\",\"isError\":true,"
    "\"source\":{\"kind\":\"tool\",\"callId\":\"call-1\"},"
    "\"content\":[{\"type\":\"text\",\"text\":" (jvalue->string forked-not-started) "}]},"
    "\"error\":{\"name\":\"ToolNotStartedError\",\"code\":\"TOOL_NOT_STARTED\"}},"
    "\"surfaceOp\":\"append\"}")))

(test-case "rule 31: a synthetic result is a valid surface event"
  (for* ([cause (in-list causes)] [started? (list #f #t)])
    (define result (car (open-turn-closers (open-call started?) cause)))
    (check-eq? (check-session-event result) result)
    (check-eq? (session-event-surface-op result) 'append)
    (check-true (tool/result? result))
    (check-false (session-event-type-violation tool/result-type (session-event-data result)))
    (check-not-exn
     (lambda ()
       (check-event-shape "tool/result" (session-event-data result) "E")
       (validate-session-event-data "tool/result" (session-event-data result) "E")))))

(test-case "rule 31: a live caller appends inputs made from the results"
  (define result (car (open-turn-closers (open-call #t) 'interrupted)))
  (define input
    (make-session-event-input "tool/result" (session-event-data result)
                              #:surface-op 'append
                              #:sources (session-event-source-seqs result)))
  (check-equal? (session-event-input-sources input) '(3))
  (check-eq? (session-event-input-data input) (session-event-data result)))

;; ---- rule 30: closing an open tail ----

(for ([cause (in-list causes)])
  (define reason (jobject 'kind (symbol->string cause)))
  (define (closers events) (open-turn-closers events cause))
  (define (types events) (map session-event-type (closers events)))
  (define (seqs events) (map session-event-seq (closers events)))

  (test-case (format "rule 30 (~a): a balanced log needs no closers" cause)
    (check-equal? (closers (list (turn-start 1 0) (turn-end 1 1))) '()))

  (test-case (format "rule 30 (~a): an empty log needs no closers" cause)
    (check-equal? (closers '()) '()))

  (test-case (format "rule 30 (~a): an open turn with no open step gets turn/end only" cause)
    (define result (closers (list (turn-start 1 0))))
    (check-equal? (map session-event-type result) '("turn/end"))
    (check-equal? (session-event-seq (car result)) 1)
    (check-equal? (turn/end-reason (car result)) reason)
    (check-equal? (jvalue->string (session-event->jvalue (car result)))
                  (format "{\"type\":\"turn/end\",\"seq\":1,\"time\":0,\"data\":~a}"
                          (jvalue->string (jobject 'turn 1 'reason reason)))))

  (test-case (format "rule 30 (~a): an open step is closed before its turn" cause)
    (define events (list (turn-start 1 0) (step-start 1 1 1)))
    (check-equal? (types events) '("step/end" "turn/end"))
    (check-equal? (seqs events) '(2 3))
    (check-equal? (jvalue->string (session-event->jvalue (car (closers events))))
                  "{\"type\":\"step/end\",\"seq\":2,\"time\":1,\"data\":{\"turn\":1,\"step\":1}}"))

  (test-case (format "rule 30 (~a): a request with no recorded call was not started" cause)
    (define events
      (list (turn-start 2 0)
            (step-start 2 1 1)
            (tool-requests 2 1 2 '("call-1") #:text "calling a tool")))
    (check-equal? (types events) '("tool/result" "step/end" "turn/end"))
    (check-equal? (seqs events) '(3 4 5))
    (define result (car (closers events)))
    (define data (session-event-data result))
    (check-equal? (jref data 'turn) 2)
    (check-equal? (jref data 'step) 1)
    (check-equal? (jref* data '(message id)) (format "~a-tool-result-call-1-3" cause))
    (check-equal? (jref* data '(message source callId)) "call-1")
    (check-equal? (jref* data '(message role)) "tool")
    (check-equal? (jref* data '(message toolCallId)) "call-1")
    (check-eq? (jref* data '(message isError)) #t)
    (check-equal? (jref* data '(error code)) tool-not-started)
    (check-equal? (jref* data '(message content))
                  (list (text-block (expected-text cause #f))))
    (check-false (session-event-source-seqs result)))

  (test-case (format "rule 30 (~a): an answered call gets no synthetic result" cause)
    (check-equal? (types (list (turn-start 2 0)
                               (step-start 2 1 1)
                               (tool-requests 2 1 2 '("call-1"))
                               (tool-answer 2 1 3 "call-1")))
                  '("step/end" "turn/end")))

  (test-case (format "rule 30 (~a): a closed step is never repaired" cause)
    (define result
      (closers (list (turn-start 2 0)
                     (step-start 2 1 1)
                     (tool-requests 2 1 2 '("call-1"))
                     (step-end 2 1 3))))
    (check-equal? (map (lambda (e) (jvalue->string (session-event->jvalue e))) result)
                  (list (format "{\"type\":\"turn/end\",\"seq\":4,\"time\":3,\"data\":~a}"
                                (jvalue->string (jobject 'turn 2 'reason reason))))))

  (test-case (format "rule 30 (~a): only the open turn is repaired" cause)
    (define events
      (list (turn-start 1 0)
            (step-start 1 1 1)
            (tool-requests 1 1 2 '("old-call"))
            (tool-answer 1 1 3 "old-call")
            (step-end 1 1 4)
            (turn-end 1 5)
            (turn-start 2 6)
            (step-start 2 1 7)
            (tool-requests 2 1 8 '("new-call"))))
    (check-equal? (types events) '("tool/result" "step/end" "turn/end"))
    (check-equal? (seqs events) '(9 10 11))
    (check-equal? (jref* (session-event-data (car (closers events))) '(message source callId))
                  "new-call"))

  (test-case (format "rule 30 (~a): each unanswered call gets a result, in request order" cause)
    (define one-answered
      (list (turn-start 1 0)
            (step-start 1 1 1)
            (tool-requests 1 1 2 '("call-a" "call-b"))
            (tool-answer 1 1 3 "call-a")))
    (check-equal? (types one-answered) '("tool/result" "step/end" "turn/end"))
    (check-equal? (jref* (session-event-data (car (closers one-answered)))
                         '(message source callId))
                  "call-b")
    (define none-answered
      (list (turn-start 1 0)
            (step-start 1 1 1)
            (tool-requests 1 1 2 '("call-a" "call-b" "call-c"))
            (tool-call 1 1 3 "call-b")))
    (check-equal? (types none-answered)
                  '("tool/result" "tool/result" "tool/result" "step/end" "turn/end"))
    (check-equal? (seqs none-answered) '(4 5 6 7 8))
    (check-equal? (map (lambda (e) (jref* (session-event-data e) '(message id)))
                       (take-results (closers none-answered)))
                  (list (format "~a-tool-result-call-a-4" cause)
                        (format "~a-tool-result-call-b-5" cause)
                        (format "~a-tool-result-call-c-6" cause)))
    (check-equal? (map session-event-source-seqs (take-results (closers none-answered)))
                  '(#f (3) #f)))

  (test-case (format "rule 30 (~a): a recorded call gives an unknown outcome that cites it" cause)
    (define result (car (closers (open-call #t))))
    (check-equal? (types (open-call #t)) '("tool/result" "step/end" "turn/end"))
    (check-eq? (session-event-surface-op result) 'append)
    (check-equal? (session-event-source-seqs result) '(3))
    (check-equal? (jref (session-event-data result) 'error)
                  (jobject 'name "ToolOutcomeUnknownError" 'code tool-outcome-unknown))
    (check-true (string-contains? (result-text result)
                                  "retry only if the operation is read-only or idempotent"))
    (check-true (string-contains? (result-text result)
                                  "first verify external state or ask the user")))

  (test-case (format "rule 30 (~a): a tool/call with no request is not answered" cause)
    (check-equal? (types (list (turn-start 1 0) (step-start 1 1 1) (tool-call 1 1 2 "orphan")))
                  '("step/end" "turn/end")))

  (test-case (format "rule 30 (~a): closers continue the seqs and reuse the last time" cause)
    (define events
      (list (raw-event "turn/start" 0 (jobject 'turn 7) #:time 500)
            (raw-event "step/start" 1 (jobject 'turn 7 'step 3) #:time 600)
            (tool-requests 7 3 2 '("x") #:time 700)))
    (define result (closers events))
    (check-equal? (map session-event-seq result) '(3 4 5))
    (check-equal? (map session-event-time result) '(700 700 700))
    (check-equal? (session-event-data (cadr result)) (jobject 'turn 7 'step 3))
    (check-equal? (session-event-data (caddr result)) (jobject 'turn 7 'reason reason)))

  (test-case (format "rule 30 (~a): the log with its closers is balanced and folds" cause)
    (define events (open-call #t))
    (define closed (append events (closers events)))
    (check-equal? (open-turn-closers closed cause) '())
    (check-equal? (surface-fold-result-nodes (fold-surface closed)) '(2 4))))

;; ---- the model-visible wording ----

(test-case "rule 31: each cause and call state has its exact text"
  (for* ([cause (in-list causes)] [started? (list #f #t)])
    (check-equal? (result-text (car (open-turn-closers (open-call started?) cause)))
                  (expected-text cause started?))))

(test-case "rule 31: the texts are the ones in the dsh source"
  (define source-path
    (repository-file "packages" "core" "session" "src" "repair.ts"))
  (cond
    [(not source-path)
     (displayln "repair text comparison skipped: packages/core/session/src/repair.ts not found"
                (current-error-port))]
    [else
     (define source (file->string source-path))
     (define literals
       (map cadr (regexp-match* #px"(?:started|notStarted): '([^']*)'" source
                                #:match-select values)))
     (check-equal? literals
                   (list interrupted-started interrupted-not-started
                         forked-started forked-not-started))]))

(test-case "rule 31: both causes share the error identities"
  (for ([cause (in-list causes)])
    (check-equal? (jref (session-event-data (car (open-turn-closers (open-call #f) cause)))
                        'error)
                  (jobject 'name "ToolNotStartedError" 'code tool-not-started))
    (check-equal? (jref (session-event-data (car (open-turn-closers (open-call #t) cause)))
                        'error)
                  (jobject 'name "ToolOutcomeUnknownError" 'code tool-outcome-unknown))))

(test-case "rule 30: interrupted-turn-closers is open-turn-closers with the cause interrupted"
  (define events (open-call #t))
  (check-equal? (interrupted-turn-closers events) (open-turn-closers events 'interrupted))
  (define end (car (reverse (interrupted-turn-closers events))))
  (check-equal? (turn/end-reason end) (jobject 'kind "interrupted")))

(test-case "rule 30: the cause is one of the two symbols"
  (check-exn exn:fail:contract? (lambda () (open-turn-closers '() 'crashed)))
  (check-exn exn:fail:contract? (lambda () (make-tool-call-recovery "interrupted"))))

(test-case "rule 30: the sample log is balanced"
  (check-equal? (interrupted-turn-closers (sample-log)) '())
  ;; Cut after the tool/call: the call is answered with an unknown outcome.
  (define cut (for/list ([event (in-list (sample-log))] [index (in-range 8)]) event))
  (define closers (interrupted-turn-closers cut))
  (check-equal? (map session-event-type closers) '("tool/result" "step/end" "turn/end"))
  (check-equal? (session-event-source-seqs (car closers)) '(7)))
