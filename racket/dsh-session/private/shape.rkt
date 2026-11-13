#lang racket/base
;; The current-shape checks that dsh runs on seed events (`assertCurrentLlmShape`,
;; `assertMessageEventShape`, `assertAssistantSettlementShape`, `assertAdapterDefaults`).
;;
;; Each procedure returns the first violation as the text that follows the subject in the dsh
;; error message, or #f when the value passes. Callers add the subject and raise. The message
;; predicates of `dsh-session/types` are these checks applied to one message.
;; source: packages/core/session/src/index.ts:250-394

(require cordis-data
         "base.rkt")

(provide message-event-role
         message-violation
         message-event-violation
         settlement-violation
         epoch-header-violation
         request-header-violation
         provider-model?
         message-jvalue?
         system-message-jvalue?
         developer-message-jvalue?
         user-message-jvalue?
         assistant-message-jvalue?
         tool-result-message-jvalue?)

;; source: packages/core/session/src/index.ts (MESSAGE_ROLE_BY_TYPE)
(define (message-event-role type)
  (cond
    [(equal? type "system/message") "system"]
    [(equal? type "developer/message") "developer"]
    [(equal? type "user/message") "user"]
    [(equal? type "assistant/message") "assistant"]
    [(equal? type "tool/result") "tool"]
    [else #f]))

;; `hasProviderModel`
(define (provider-model? v)
  (and (nonempty-string? (field v 'provider))
       (nonempty-string? (field v 'model))))

;; The checks every identified message passes, whatever its role.
(define (identified? message)
  (and (record? message) (nonempty-string? (field message 'id))))

(define (valid-source? source)
  (and (record? source) (nonempty-string? (field source 'kind))))

;; message-violation : string? any/c -> (or/c #f string?)
;; `type` is one of the five message event types; `message` is the candidate message.
(define (message-violation type message)
  (define role (message-event-role type))
  (define source (field message 'source))
  (cond
    [(not (identified? message)) "lacks an identified message"]
    [(not (equal? (field message 'role) role)) (format "message must have role \"~a\"" role)]
    [(not (valid-source? source)) "message has invalid source"]
    [(not (list? (field message 'content))) "message has invalid content"]
    [(equal? type "system/message")
     (and (not (equal? (field source 'kind) "system-prompt"))
          "message must have system-prompt source")]
    [(equal? type "assistant/message")
     (and (not (and (equal? (field source 'kind) "model") (provider-model? source)))
          "message must have model source")]
    [(equal? type "tool/result")
     (cond
       [(not (and (equal? (field source 'kind) "tool")
                  (nonempty-string? (field source 'callId))))
        "message must have tool source"]
       [(not (js-strict-equal? (field message 'toolCallId) (field source 'callId)))
        "message has mismatched tool call ids"]
       [else #f])]
    [else #f]))

;; message-event-violation : string? any/c -> (or/c #f string?)
;; The same check for the `data` of a message event; #f for any other event type.
(define (message-event-violation type data)
  (and (message-event-role type)
       (message-violation type (if (equal? type "user/message") data (field data 'message)))))

;; settlement-violation : any/c -> (or/c #f string?)
;; For the data of `assistant/message` and `assistant/attempt`.
(define (settlement-violation data)
  (and (not (and (valid-seq? (field data 'turn))
                 (valid-seq? (field data 'step))
                 (list? (field data 'stream))))
       "has invalid settlement fields"))

(define (adapter-defaults-valid? defaults config)
  (or (absent? defaults)
      (and (record? defaults)
           (for/and ([member (in-list (jobject->alist defaults))])
             (and (memq (car member) '(reasoningEffort maxTokens))
                  (eq? (cdr member) #t)))
           (not (and (eq? (field defaults 'reasoningEffort) #t)
                     (absent? (field config 'reasoningEffort))))
           (not (and (eq? (field defaults 'maxTokens) #t)
                     (absent? (field config 'maxTokens)))))))

;; epoch-header-violation : any/c -> (or/c #f string?)
;; The config and adapter-default checks on the `header` of a `request/header` event.
(define (epoch-header-violation header)
  (define config (field header 'config))
  (define effort (field config 'reasoningEffort))
  (cond
    [(not (provider-model? config)) "lacks provider/model"]
    [(not (or (absent? effort) (nonempty-string? effort))) "has an invalid reasoningEffort"]
    [(not (adapter-defaults-valid? (field header 'adapterDefaults) config))
     "has invalid adapterDefaults"]
    [else #f]))

;; request-header-violation : any/c -> (or/c #f string?)
;; For the data of `request/header`.
(define (request-header-violation data)
  (define starts-series (field data 'startsSeries))
  (or (epoch-header-violation (field data 'header))
      (and (not (member (field data 'reason) '("initial" "resume" "change" "series")))
           "has an invalid reason")
      (and (not (or (absent? starts-series) (eq? starts-series #t)))
           "has an invalid startsSeries marker")))

;; ---- predicates over messages ----

(define (message-jvalue? v)
  (and (identified? v)
       (member (field v 'role) '("system" "developer" "user" "assistant" "tool"))
       (valid-source? (field v 'source))
       (list? (field v 'content))
       #t))

(define (system-message-jvalue? v)
  (not (message-violation "system/message" v)))

(define (developer-message-jvalue? v)
  (not (message-violation "developer/message" v)))

(define (user-message-jvalue? v)
  (not (message-violation "user/message" v)))

(define (assistant-message-jvalue? v)
  (not (message-violation "assistant/message" v)))

(define (tool-result-message-jvalue? v)
  (not (message-violation "tool/result" v)))
