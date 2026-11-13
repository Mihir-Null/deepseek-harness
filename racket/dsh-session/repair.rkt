#lang racket/base
;; Tail repair: the synthetic events that close a turn left open at the end of a log, and the
;; tracker of assistant tool requests that have no result yet.
;;
;; `open-turn-closers` is a pure function of the events. A `tool-call-recovery` is a mutable
;; tracker fed with the committed events of one session in seq order;
;; `tool-call-recovery-results` builds events without changing it. The returned events carry
;; seqs that continue the observed log and the time of the last observed event. A caller that
;; commits them to a live session appends inputs made from their data instead, so the session
;; assigns seq and time.
;; source: packages/core/session/src/repair.ts

(require racket/contract/base
         cordis-data
         "types.rkt"
         (only-in "private/base.rkt" field js-strict-equal? js-string))

(provide
 (contract-out
  ;; Recovery code of a tool request that never reached a recorded call start.
  [tool-not-started string?]
  ;; Recovery code of a recorded call whose outcome was not recorded.
  [tool-outcome-unknown string?]
  [tool-call-recovery? predicate/c]
  [make-tool-call-recovery (->* () (close-cause/c) tool-call-recovery?)]
  ;; Consumes the next committed event of the session.
  [tool-call-recovery-observe! (-> tool-call-recovery? session-event? void?)]
  ;; One error `tool/result` per pending call, in request order; '() when nothing was observed.
  [tool-call-recovery-results (-> tool-call-recovery? (listof session-event?))]
  ;; The events that close the open tail turn of `events`: recovery results, `step/end` when a
  ;; step is open, then `turn/end`; '() for a balanced or empty log.
  [open-turn-closers (-> (listof session-event?) close-cause/c (listof session-event?))]
  ;; `open-turn-closers` with the cause 'interrupted.
  [interrupted-turn-closers (-> (listof session-event?) (listof session-event?))]))

(define close-cause/c (or/c 'interrupted 'forked))

;; source: packages/core/session/src/repair.ts (TOOL_NOT_STARTED, TOOL_OUTCOME_UNKNOWN)
(define tool-not-started "TOOL_NOT_STARTED")
(define tool-outcome-unknown "TOOL_OUTCOME_UNKNOWN")

;; Model-visible wording of the synthetic error tool results, by cause and call state.
;; source: packages/core/session/src/repair.ts (CLOSER_TEXT)
(define interrupted-started-text
  (string-append
   "The tool call was interrupted after it was recorded, but no result was durably recorded. "
   "Its outcome is unknown. Decide whether to retry from the tool semantics: retry only if "
   "the operation is read-only or idempotent; if it may have side effects, first verify "
   "external state or ask the user. Do not retry blindly."))

(define interrupted-not-started-text
  (string-append
   "The tool call was interrupted before the Harness recorded it as started. "
   "Retry it if it is still needed."))

(define forked-started-text
  (string-append
   "The history inherited by this branch records this tool call starting but does not "
   "include its result. The parent session may have completed it after the fork point. "
   "Decide whether to retry from the tool semantics: retry only if the operation is "
   "read-only or idempotent; if it may have side effects, first verify external state or ask "
   "the user. Do not retry blindly."))

(define forked-not-started-text
  (string-append
   "The history inherited by this branch has no record of this tool call starting. The "
   "parent session may have executed it after the fork point. Decide whether to retry from "
   "the tool semantics: retry only if the operation is read-only or idempotent; if it may "
   "have side effects, first verify external state or ask the user. Do not retry blindly."))

(define (closer-text cause started?)
  (case cause
    [(interrupted) (if started? interrupted-started-text interrupted-not-started-text)]
    [else (if started? forked-started-text forked-not-started-text)]))

;; ---- pending tool requests ----

;; One unanswered request. `call-seq` is the seq of its `tool/call`, or #f.
(struct pending (call-id turn step call-seq))

;; `calls` holds the pending requests in the order the assistant made them. `last` is
;; `(cons seq time)` of the latest observed event, or #f.
(struct tool-call-recovery (cause [calls #:mutable] [last #:mutable]))

(define (make-tool-call-recovery [cause 'interrupted])
  (tool-call-recovery cause '() #f))

(define (same-call? entry call-id)
  (js-strict-equal? (pending-call-id entry) call-id))

;; A repeated id keeps its position and takes the new coordinates, as `Map.set` does.
(define (add-call calls call-id turn step)
  (define entry (pending call-id turn step #f))
  (if (ormap (lambda (existing) (same-call? existing call-id)) calls)
      (for/list ([existing (in-list calls)])
        (if (same-call? existing call-id) entry existing))
      (append calls (list entry))))

;; source: packages/core/session/src/repair.ts (ToolCallRecovery.observe)
(define (tool-call-recovery-observe! r e)
  (define type (session-event-type e))
  (define data (session-event-data e))
  (define calls (tool-call-recovery-calls r))
  (set-tool-call-recovery-last! r (cons (session-event-seq e) (session-event-time e)))
  (cond
    [(member type '("turn/start" "turn/end" "step/end"))
     (set-tool-call-recovery-calls! r '())]
    [(equal? type "assistant/message")
     (define content (field (field data 'message) 'content))
     (set-tool-call-recovery-calls!
      r
      (for/fold ([calls calls]) ([block (in-list (if (list? content) content '()))]
                                 #:when (equal? (field block 'type) "tool-call"))
        (add-call calls (field block 'id) (field data 'turn) (field data 'step))))]
    [(equal? type "tool/call")
     (define call-id (field data 'callId))
     (set-tool-call-recovery-calls!
      r
      (for/list ([entry (in-list calls)])
        (if (same-call? entry call-id)
            (struct-copy pending entry [call-seq (session-event-seq e)])
            entry)))]
    [(equal? type "tool/result")
     (define call-id (field (field (field data 'message) 'source) 'callId))
     (when (eq? (session-event-surface-op e) 'append)
       (set-tool-call-recovery-calls!
        r
        (for/list ([entry (in-list calls)]
                   #:unless (and (same-call? entry call-id)
                                 (js-strict-equal? (pending-turn entry) (field data 'turn))
                                 (js-strict-equal? (pending-step entry) (field data 'step))))
          entry)))]
    [else (void)]))

;; source: packages/core/session/src/repair.ts (ToolCallRecovery.results)
(define (tool-call-recovery-results r)
  (define last (tool-call-recovery-last r))
  (define cause (tool-call-recovery-cause r))
  (cond
    [(not last) '()]
    [else
     (define time (cdr last))
     (for/list ([entry (in-list (tool-call-recovery-calls r))]
                [seq (in-naturals (add1 (car last)))])
       (define call-id (pending-call-id entry))
       (define call-seq (pending-call-seq entry))
       ;; Key order of the message and of the event data is the order dsh writes.
       (define message
         (jobject 'id (format "~a-tool-result-~a-~a" cause (js-string call-id) seq)
                  'role "tool"
                  'toolCallId call-id
                  'isError #t
                  'source (jobject 'kind "tool" 'callId call-id)
                  'content (list (jobject 'type "text"
                                          'text (closer-text cause (and call-seq #t))))))
       (define data
         (jobject 'turn (pending-turn entry)
                  'step (pending-step entry)
                  'message message
                  'error (if call-seq
                             (jobject 'name "ToolOutcomeUnknownError"
                                      'code tool-outcome-unknown)
                             (jobject 'name "ToolNotStartedError"
                                      'code tool-not-started))))
       (make-session-event "tool/result" seq time data
                           #:surface-op 'append
                           #:sources (if call-seq (list call-seq) absent)
                           #:metadata-order 'op-first))]))

;; ---- closing an open tail ----

;; source: packages/core/session/src/repair.ts (openTurnClosers)
(define (open-turn-closers events cause)
  (define recovery (make-tool-call-recovery cause))
  (define-values (open-turn open-step)
    (for/fold ([open-turn absent] [open-step absent]) ([e (in-list events)])
      (tool-call-recovery-observe! recovery e)
      (define type (session-event-type e))
      (define data (session-event-data e))
      (cond
        [(equal? type "turn/start") (values (field data 'turn) absent)]
        [(equal? type "turn/end") (values absent absent)]
        [(equal? type "step/start") (values open-turn (field data 'step))]
        [(equal? type "step/end") (values open-turn absent)]
        [else (values open-turn open-step)])))
  (cond
    [(or (absent? open-turn) (null? events)) '()]
    [else
     (define last (car (reverse events)))
     (define time (session-event-time last))
     (define results (tool-call-recovery-results recovery))
     (define next-seq (+ (session-event-seq last) (length results) 1))
     (append
      results
      (if (absent? open-step)
          '()
          (list (make-session-event "step/end" next-seq time
                                    (jobject 'turn open-turn 'step open-step))))
      (list (make-session-event "turn/end"
                                (if (absent? open-step) next-seq (add1 next-seq))
                                time
                                (jobject 'turn open-turn
                                         'reason (jobject 'kind (symbol->string cause))))))]))

(define (interrupted-turn-closers events)
  (open-turn-closers events 'interrupted))
