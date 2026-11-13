#lang racket/base
;; The 14 session event types that dsh declares in `packages/core/session`, each declared
;; once with `define-session-event`, and the constant sets of type names.
;;
;; For an event `turn/end` this module provides `turn/end` (constructor and `match` pattern),
;; `turn/end?`, `turn/end-type` and one accessor per field (`turn/end-turn`,
;; `turn/end-reason`). Fields are declared in the order dsh writes them, so a constructor
;; produces the data object with the dsh key order. The constructors of the five
;; surface-eligible types also take `#:surface-op` (required) and, except for
;; `assistant/message`, `#:sources`.
;; source: packages/core/session/src/types.ts (SessionEventMap)

(require racket/contract/base
         racket/set
         cordis-data
         "types.rkt"
         (only-in "private/base.rkt" record? field)
         (only-in "private/shape.rkt" epoch-header-violation)
         "private/catalog.rkt")

(provide
 turn/start turn/start? turn/start-type turn/start-turn
 turn/end turn/end? turn/end-type turn/end-turn turn/end-reason
 step/start step/start? step/start-type step/start-turn step/start-step
 step/end step/end? step/end-type step/end-turn step/end-step
 user/message user/message? user/message-type
 developer/message developer/message? developer/message-type developer/message-turn
 developer/message-step developer/message-message developer/message-header-seq
 system/message system/message? system/message-type system/message-turn system/message-step
 system/message-message
 assistant/message assistant/message? assistant/message-type assistant/message-turn
 assistant/message-step assistant/message-message assistant/message-interrupted
 assistant/message-usage assistant/message-stream
 assistant/attempt assistant/attempt? assistant/attempt-type assistant/attempt-turn
 assistant/attempt-step assistant/attempt-stream
 tool/call tool/call? tool/call-type tool/call-turn tool/call-step tool/call-call-id
 tool/call-name tool/call-arguments
 tool/result tool/result? tool/result-type tool/result-turn tool/result-step
 tool/result-message tool/result-error tool/result-meta
 request/header request/header? request/header-type request/header-header
 request/header-reason request/header-starts-series
 request/context request/context? request/context-type request/context-provider
 request/context-model request/context-context-window request/context-system-prompt-update
 session/end-seed session/end-seed? session/end-seed-type session/end-seed-inherited

 (contract-out
  ;; An object with a string `kind`; `aborted` also needs a `reason` object with a string
  ;; `kind`, and `error` an `error` object with string `message` and `code`. Other kinds are
  ;; accepted as they are, because plugins extend the set.
  [turn-end-reason? predicate/c]
  ;; The `header` of `request/header`: `{config, adapterDefaults?, tools?}` whose config names
  ;; a provider and a model, with valid adapter-default markers and tool objects that have a
  ;; string `name`.
  [epoch-header? predicate/c]
  ;; `{name, code, reason?}`, all strings.
  [tool-error-identity? predicate/c]
  ;; The 14 declarations, in the order of the dsh interface.
  [core-session-event-types (listof session-event-type?)]
  ;; The 63 type names this build knows.
  [known-session-event-types (set/c string?)]
  ;; The five surface-eligible type names; the set is closed.
  [surface-event-types (set/c string?)]
  ;; The type names whose events are accepted only with a message projection.
  [message-projection-event-types (set/c string?)]))

;; ---- embedded shapes ----

;; source: packages/core/session/src/types.ts (TurnEndReasonMap, TurnEndCancelCause, LlmFailure)
(define (turn-end-reason? v)
  (define kind (field v 'kind))
  (and (string? kind)
       (cond
         [(string=? kind "aborted") (string? (field (field v 'reason) 'kind))]
         [(string=? kind "error")
          (and (string? (field (field v 'error) 'message))
               (string? (field (field v 'error) 'code)))]
         [else #t])))

;; source: packages/core/session/src/types.ts (EpochHeader)
(define (epoch-header? v)
  (define tools (field v 'tools))
  (and (record? v)
       (not (epoch-header-violation v))
       (or (absent? tools)
           (and (list? tools)
                (for/and ([tool (in-list tools)]) (string? (field tool 'name)))))))

(define (tool-error-identity? v)
  (define reason (field v 'reason))
  (and (string? (field v 'name))
       (string? (field v 'code))
       (or (absent? reason) (string? reason))))

;; ---- declarations ----
;; Field order is the order the dsh producers write. For `assistant/message` that is
;; `interrupted`, `usage`, `stream`.
;; source: packages/core/agent-loop/src/agent.ts:511-525 and :582-588

(define-session-event turn/start
  #:type "turn/start"
  #:fields ([turn session-seq?]))

(define-session-event turn/end
  #:type "turn/end"
  #:fields ([turn session-seq?]
            [reason turn-end-reason?]))

(define-session-event step/start
  #:type "step/start"
  #:fields ([turn session-seq?]
            [step session-seq?]))

(define-session-event step/end
  #:type "step/end"
  #:fields ([turn session-seq?]
            [step session-seq?]))

(define-session-event user/message
  #:type "user/message"
  #:data user-message-jvalue?)

(define-session-event developer/message
  #:type "developer/message"
  #:fields ([turn session-seq?]
            [step session-seq?]
            [message developer-message-jvalue?]
            [header-seq "headerSeq" session-seq? #:optional]))

(define-session-event system/message
  #:type "system/message"
  #:fields ([turn session-seq?]
            [step session-seq?]
            [message system-message-jvalue?]))

(define-session-event assistant/message
  #:type "assistant/message"
  #:fields ([turn session-seq?]
            [step session-seq?]
            [message assistant-message-jvalue?]
            [interrupted #t #:optional]
            [usage jobject? #:optional]
            [stream (listof jvalue?)]))

(define-session-event assistant/attempt
  #:type "assistant/attempt"
  #:fields ([turn session-seq?]
            [step session-seq?]
            [stream (listof jvalue?)]))

(define-session-event tool/call
  #:type "tool/call"
  #:fields ([turn session-seq?]
            [step session-seq?]
            [call-id "callId" string?]
            [name string?]
            [arguments string?]))

(define-session-event tool/result
  #:type "tool/result"
  #:fields ([turn session-seq?]
            [step session-seq?]
            [message tool-result-message-jvalue?]
            [error tool-error-identity? #:optional]
            [meta jvalue? #:optional]))

(define-session-event request/header
  #:type "request/header"
  #:fields ([header epoch-header?]
            [reason (or/c "initial" "resume" "change" "series")]
            [starts-series "startsSeries" #t #:optional]))

(define-session-event request/context
  #:type "request/context"
  #:fields ([provider string?]
            [model string?]
            [context-window "contextWindow" real? #:optional]
            [system-prompt-update "systemPromptUpdate" "in-history" #:optional]))

(define-session-event session/end-seed
  #:type "session/end-seed"
  #:fields ([inherited #t #:optional]))

(define core-session-event-types
  (list turn/start-type
        turn/end-type
        step/start-type
        step/end-type
        user/message-type
        developer/message-type
        system/message-type
        assistant/message-type
        assistant/attempt-type
        tool/call-type
        tool/result-type
        request/header-type
        request/context-type
        session/end-seed-type))
