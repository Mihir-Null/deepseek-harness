#lang racket/base
;; Tests of `dsh-session/surface`: the event-local checks (rules 4 to 8 as pure procedures)
;; and the surface fold (rules 17 to 21), including windowed folds with a non-zero base seq
;; and equality of `fold-surface` with stepwise folding.
;; Mirrors packages/core/session/tests/surface.spec.ts, developer-header.spec.ts,
;; message-projections.spec.ts and the event-local parts of canonical-envelopes.spec.ts.

(require rackunit
         racket/list
         cordis-data
         dsh-session/types
         dsh-session/events
         dsh-session/surface
         "support/log.rkt")

;; ---- fixtures ----

(define (user-event seq [text (format "u~a" seq)] #:op [op "append"] #:sources [sources absent])
  (raw-event "user/message" seq (user-message text #:id (format "user-~a" seq))
             #:surface-op op #:sources sources))

(define (system-event seq text #:op [op "append"] #:sources [sources absent])
  (raw-event "system/message" seq
             (jobject 'turn 1 'step 1 'message (system-message text #:id (format "system-~a" seq)))
             #:surface-op op #:sources sources))

(define (tool-result-event seq call-id
                           #:op [op "append"]
                           #:sources [sources absent]
                           #:id [id (format "tool-~a" seq)]
                           #:meta [meta absent]
                           #:error? [error? #f])
  (define data
    (jobject 'turn 1 'step 1
             'message (tool-result-message call-id (format "result ~a" seq)
                                           #:id id #:error? error?)))
  (raw-event "tool/result" seq (if (absent? meta) data (jset data 'meta meta))
             #:surface-op op #:sources sources))

(define (assistant-event seq [content "hi"] #:op [op "append"] #:sources [sources absent])
  (raw-event "assistant/message" seq
             (jobject 'turn 1 'step 1
                      'message (assistant-message content #:id (format "assistant-~a" seq))
                      'stream '())
             #:surface-op op #:sources sources))

(define (boundary-event seq [type "turn/start"])
  (raw-event type seq (jobject 'turn 1)))

(define (header-event seq tools #:reason [reason "initial"])
  (define config (jobject 'provider "test" 'model "test"))
  (define header
    (if tools (jobject 'config config 'tools tools) (jobject 'config config)))
  (raw-event "request/header" seq (jobject 'header header 'reason reason)))

(define (developer-event seq content #:header-seq [header-seq absent]
                         #:op [op "append"] #:sources [sources absent])
  (define data
    (jobject 'turn 1 'step 1
             'message (developer-message content #:id (format "developer-~a" seq)
                                         #:source (jobject 'kind "test"))))
  (raw-event "developer/message" seq
             (if (absent? header-seq) data (jset data 'headerSeq header-seq))
             #:surface-op op #:sources sources))

;; Folds `events` one step at a time from the state before `base`; an event outside the
;; window reads as #f.
(define (fold-stepwise events #:base [base 0] #:projections [projections '()])
  (define log (list->vector events))
  (define (event-ref seq)
    (define index (- seq base))
    (and (>= index 0) (< index (vector-length log)) (vector-ref log index)))
  (for/fold ([st (surface-state-empty #:base-seq base)]) ([e (in-list events)])
    (surface-step st e event-ref projections)))

(define (nodes-of events)
  (surface-fold-result-nodes (fold-surface events)))

;; ---- rule 4: validate-session-event-data ----

(define config (jobject 'provider "mock" 'model "mock" 'maxTokens 1))
(define failure (jobject 'name "ToolError" 'code "FAILED"))

(define (tool-data error?)
  (jobject 'turn 1 'step 1 'message (tool-result-message "tool" '() #:id "t" #:error? error?)))

(test-case "rule 4: request/header data and header must be objects"
  (for ([data (list 'null '() 1 "invalid")])
    (check-exn (session-error "E data must be an object")
               (lambda () (validate-session-event-data "request/header" data "E")))
    (check-exn (session-error "E header must be an object")
               (lambda ()
                 (validate-session-event-data "request/header"
                                              (jobject 'header data 'reason "initial") "E")))
    (check-exn (session-error "E data must be an object")
               (lambda () (validate-session-event-data "tool/result" data "E"))))
  (check-exn (session-error "seed request/header at index 0 header must be an object")
             (lambda ()
               (validate-session-event-data "request/header" (jobject 'reason "initial")
                                            "seed request/header at index 0"))))

(test-case "rule 4: request/header must omit system, empty tools and empty adapterDefaults"
  (check-exn (session-error "E must omit empty tools")
             (lambda ()
               (validate-session-event-data
                "request/header" (jobject 'header (jobject 'config config 'tools '())) "E")))
  (check-exn (session-error "E must omit empty adapterDefaults")
             (lambda ()
               (validate-session-event-data
                "request/header"
                (jobject 'header (jobject 'config config 'adapterDefaults (jobject)))
                "E")))
  (for ([system (list "" " " "system" 'null '() (jobject))])
    (check-exn (session-error "E must omit header.system; use system/message")
               (lambda ()
                 (validate-session-event-data
                  "request/header" (jobject 'header (jobject 'config config 'system system))
                  "E")))))

(test-case "rule 4: accepted request headers and tool results"
  (for ([data (list (jobject 'header (jobject 'config config) 'reason "initial")
                    (jobject 'header
                             (jobject 'config config
                                      'extension (jobject 'nested #t)
                                      'tools (list (tool-schema "tool"))
                                      'adapterDefaults (jobject 'maxTokens #t))
                             'reason "initial"))])
    (check-not-exn (lambda () (validate-session-event-data "request/header" data "E"))))
  (for ([data (list (tool-data #f) (tool-data #t) (jset (tool-data #t) 'error failure))])
    (check-not-exn (lambda () (validate-session-event-data "tool/result" data "E")))))

(test-case "rule 4: a tool error needs message.isError to be true"
  (check-exn (session-error "E error requires message.isError === true")
             (lambda ()
               (validate-session-event-data "tool/result" (jset (tool-data #f) 'error failure)
                                            "E")))
  (for ([message (list absent 'null '() (jobject) (jobject 'isError "true")
                       (jobject 'content (list (jobject 'isError #t))))])
    (define data
      (let ([base (jobject 'turn 1 'step 1)])
        (jset (if (absent? message) base (jset base 'message message)) 'error failure)))
    (check-exn (session-error "E error requires message.isError === true")
               (lambda () (validate-session-event-data "tool/result" data "E")))))

(test-case "rule 4: developer/message and the developer role occur together"
  (define developer (developer-message '() #:id "d"))
  (check-exn (session-error "E developer/message and developer role must occur together")
             (lambda () (validate-session-event-data "user/message" developer "E")))
  (check-exn (session-error "E developer/message and developer role must occur together")
             (lambda ()
               (validate-session-event-data
                "developer/message"
                (jobject 'turn 1 'step 1 'message (jset developer 'role "user"))
                "E")))
  (check-not-exn
   (lambda ()
     (validate-session-event-data "developer/message"
                                  (jobject 'turn 1 'step 1 'message developer) "E"))))

(test-case "rule 4: tool-change blocks need the developer role"
  (for ([block (list (tool-addition-block "search") (tool-removal-block "search"))])
    (check-exn (session-error "E tool-change blocks require developer role")
               (lambda ()
                 (validate-session-event-data "user/message" (user-message (list block)) "E")))
    (check-exn (session-error "E tool-change blocks require developer role")
               (lambda ()
                 (validate-session-event-data
                  "assistant/message"
                  (jobject 'turn 1 'step 1 'message (assistant-message (list block)) 'stream '())
                  "E")))))

(test-case "rule 4: developer tool-change blocks and headerSeq"
  (define (data content . extra)
    (define base (jobject 'turn 1 'step 1 'message (developer-message content #:id "d")))
    (if (null? extra) base (jset base 'headerSeq (car extra))))
  (define (rejected message content . extra)
    (check-exn (session-error message)
               (lambda ()
                 (validate-session-event-data "developer/message" (apply data content extra)
                                              "E"))))
  (rejected "E tool-addition requires a nonempty toolName" (list (tool-addition-block "")) 2)
  (rejected "E tool-removal requires a nonempty toolName" (list (tool-removal-block "")))
  (rejected "E tool-addition requires a nonempty toolName"
            (list (jobject 'type "tool-addition")) 2)
  (rejected "E tool-addition must omit inline tool definitions"
            (list (jset (tool-addition-block "search") 'tool (tool-schema "search"))) 2)
  (rejected "E tool-addition must omit inline tool definitions"
            (list (jset (tool-addition-block "search") 'tool 'null)) 2)
  (define header-rule "E requires headerSeq exactly when tool additions are present")
  (rejected header-rule (list (tool-addition-block "search")))
  (rejected header-rule (list (tool-addition-block "search")) -1)
  (rejected header-rule (list (tool-addition-block "search")) "2")
  (rejected header-rule (list (tool-addition-block "search")) -0.0)
  (rejected header-rule (list (tool-removal-block "search")) 2)
  (rejected header-rule '() 2)
  (rejected header-rule '() 'null)
  (check-not-exn
   (lambda ()
     (validate-session-event-data "developer/message"
                                  (data (list (tool-removal-block "a") (tool-addition-block "b"))
                                        2)
                                  "E")))
  (check-not-exn
   (lambda ()
     (validate-session-event-data "developer/message" (data (list (tool-removal-block "a")))
                                  "E"))))

(test-case "rule 4: other types and non-object data are not inspected"
  (for ([type (list "turn/start" "assistant/attempt" "plugin:x/y" "user/message")])
    (check-not-exn (lambda () (validate-session-event-data type 'null "E")))
    (check-not-exn (lambda () (validate-session-event-data type (list 1) "E")))))

;; ---- rule 5: check-event-shape ----

(define subject "seed X at index 0")

(define (shape-rejected type data violation)
  (check-exn (session-error (string-append subject " " violation))
             (lambda () (check-event-shape type data subject))))

(test-case "rule 5: message checks, in order"
  (define user (user-message "hi" #:id "u"))
  (shape-rejected "user/message" 'null "lacks an identified message")
  (shape-rejected "user/message" (list user) "lacks an identified message")
  (shape-rejected "user/message" (jset user 'id "") "lacks an identified message")
  (shape-rejected "user/message" (jset user 'id 7) "lacks an identified message")
  (shape-rejected "user/message" (jset user 'role "assistant") "message must have role \"user\"")
  (shape-rejected "user/message" (jset user 'source 'null) "message has invalid source")
  (shape-rejected "user/message" (jset user 'source (jobject 'kind ""))
                  "message has invalid source")
  (shape-rejected "user/message" (jset user 'content (jobject)) "message has invalid content")
  ;; The role is reported before the source, and the source before the content.
  (shape-rejected "user/message" (jobject 'id "u" 'role "x") "message must have role \"user\"")
  (shape-rejected "user/message" (jobject 'id "u" 'role "user") "message has invalid source")
  (check-not-exn (lambda () (check-event-shape "user/message" user subject))))

(test-case "rule 5: wrapped messages and their sources"
  (define (wrapped message)
    (jobject 'turn 1 'step 1 'message message 'stream '()))
  (define system (system-message "prompt" #:id "s"))
  (shape-rejected "system/message" (jobject 'turn 1) "lacks an identified message")
  (shape-rejected "system/message" (wrapped (jset system 'role "user"))
                  "message must have role \"system\"")
  (for ([source (list (jobject 'kind "runtime-context")
                      (jobject 'kind "plugin" 'plugin "@deepseek-ai/dsh-system-prompt")
                      (jobject 'kind "user"))])
    (shape-rejected "system/message" (wrapped (jset system 'source source))
                    "message must have system-prompt source"))
  (check-not-exn (lambda () (check-event-shape "system/message" (wrapped system) subject)))
  (define developer (developer-message '() #:id "d"))
  (shape-rejected "developer/message" (wrapped (jset developer 'role "user"))
                  "message must have role \"developer\"")
  (check-not-exn
   (lambda () (check-event-shape "developer/message" (wrapped developer) subject)))
  (define assistant (assistant-message "ok" #:id "a"))
  (shape-rejected "assistant/message" (wrapped (jset assistant 'source (jobject 'kind "user")))
                  "message must have model source")
  (shape-rejected "assistant/message"
                  (wrapped (jset assistant 'source (jobject 'kind "model" 'provider "p")))
                  "message must have model source")
  (check-not-exn
   (lambda () (check-event-shape "assistant/message" (wrapped assistant) subject)))
  (define tool (tool-result-message "call" "out" #:id "t"))
  (shape-rejected "tool/result" (wrapped (jset tool 'source (jobject 'kind "model")))
                  "message must have tool source")
  (shape-rejected "tool/result" (wrapped (jset tool 'source (jobject 'kind "tool" 'callId "")))
                  "message must have tool source")
  (shape-rejected "tool/result" (wrapped (jset tool 'toolCallId "other"))
                  "message has mismatched tool call ids")
  (check-not-exn (lambda () (check-event-shape "tool/result" (wrapped tool) subject))))

(test-case "rule 5: settlement fields of assistant/message and assistant/attempt"
  (define assistant (assistant-message "ok" #:id "a"))
  (define valid (jobject 'turn 1 'step 0 'message assistant 'stream '()))
  (check-not-exn (lambda () (check-event-shape "assistant/message" valid subject)))
  (check-not-exn (lambda () (check-event-shape "assistant/attempt" valid subject)))
  (for ([type (list "assistant/message" "assistant/attempt")])
    (for ([data (list (jset valid 'turn -1)
                      (jset valid 'turn 0.5)
                      (jset valid 'turn -0.0)
                      (jset valid 'turn "1")
                      (jremove valid 'turn)
                      (jset valid 'step -1)
                      (jremove valid 'step)
                      (jset valid 'stream (jobject))
                      (jremove valid 'stream))])
      (shape-rejected type data "has invalid settlement fields")))
  (shape-rejected "assistant/attempt" 'null "has invalid settlement fields")
  ;; For assistant/message the message is checked before the settlement fields.
  (shape-rejected "assistant/message" (jobject 'turn -1) "lacks an identified message"))

(test-case "rule 5: request/header"
  (define (header-data header . rest)
    (apply jobject 'header header 'reason "initial" rest))
  (for ([config-value (list 'null "invalid" (jobject 'provider "p") (jobject 'model "m")
                            (jobject 'provider "" 'model "m") (jobject 'provider "p" 'model 5))])
    (shape-rejected "request/header" (header-data (jobject 'config config-value))
                    "lacks provider/model"))
  (shape-rejected "request/header" (header-data (jobject)) "lacks provider/model")
  (shape-rejected "request/header" 'null "lacks provider/model")
  (for ([effort (list "" 5 'null)])
    (shape-rejected "request/header"
                    (header-data (jobject 'config (jset config 'reasoningEffort effort)))
                    "has an invalid reasoningEffort"))
  (for ([defaults (list 'null '() "x"
                        (jobject 'temperature #t)
                        (jobject 'maxTokens "true")
                        (jobject 'maxTokens #f)
                        (jobject 'reasoningEffort #t))])
    (shape-rejected "request/header"
                    (header-data (jobject 'config config 'adapterDefaults defaults))
                    "has invalid adapterDefaults"))
  (shape-rejected "request/header"
                  (jobject 'header (jobject 'config config) 'reason "restart")
                  "has an invalid reason")
  (shape-rejected "request/header" (jobject 'header (jobject 'config config))
                  "has an invalid reason")
  (for ([marker (list #f 'null "true" 1)])
    (shape-rejected "request/header"
                    (header-data (jobject 'config config) 'startsSeries marker)
                    "has an invalid startsSeries marker"))
  (for ([data (list (header-data (jobject 'config config))
                    (header-data (jobject 'config config 'adapterDefaults (jobject 'maxTokens #t)))
                    (header-data (jobject 'config (jset config 'reasoningEffort "high")
                                          'adapterDefaults (jobject 'reasoningEffort #t)))
                    (header-data (jobject 'config config) 'startsSeries #t))])
    (check-not-exn (lambda () (check-event-shape "request/header" data subject)))))

(test-case "rule 5: other types are not checked"
  (for ([type (list "turn/start" "tool/call" "request/context" "plugin:x/y")])
    (check-not-exn (lambda () (check-event-shape type 'null subject)))))

;; ---- rule 6: check-declared-fields ----

(test-case "rule 6: data is checked against the declaration of its type"
  (define live "session event \"tool/call\" at seq 4")
  (check-not-exn
   (lambda ()
     (check-declared-fields core-session-event-types "tool/call"
                            (jobject 'turn 1 'step 1 'callId "c" 'name "n" 'arguments "{}")
                            live)))
  (check-exn (session-error "session event \"tool/call\" at seq 4 data must be an object")
             (lambda () (check-declared-fields core-session-event-types "tool/call" "x" live)))
  (check-exn (session-error "session event \"tool/call\" at seq 4 lacks field \"step\"")
             (lambda ()
               (check-declared-fields core-session-event-types "tool/call" (jobject 'turn 1)
                                      live)))
  (check-exn (session-error "session event \"tool/call\" at seq 4 field \"callId\" is invalid")
             (lambda ()
               (check-declared-fields core-session-event-types "tool/call"
                                      (jobject 'turn 1 'step 1 'callId 5) live))))

(test-case "rule 6: a type with no declaration is accepted unchecked"
  (check-not-exn
   (lambda () (check-declared-fields core-session-event-types "llm/retry" "anything" "E")))
  (check-not-exn (lambda () (check-declared-fields '() "tool/call" "anything" "E"))))

;; ---- rule 8: validate-surface-metadata ----

(test-case "rule 8: a log-only type carries no surface metadata"
  (check-false (validate-surface-metadata (boundary-event 0)))
  (check-exn
   (session-error "session event \"turn/start\" is not surface-eligible and cannot carry surfaceOp")
   (lambda () (validate-surface-metadata
               (raw-event "turn/start" 0 (jobject 'turn 1) #:surface-op "append"))))
  (check-exn
   (session-error
    "session event \"turn/start\" is not surface-eligible and cannot carry sourceEventSeqs")
   (lambda () (validate-surface-metadata
               (raw-event "turn/start" 0 (jobject 'turn 1) #:sources (list 0)))))
  ;; A type that is neither known nor ignorable is treated as log-only.
  (check-exn (session-error #rx"\"custom/event\" is not surface-eligible")
             (lambda () (validate-surface-metadata
                         (raw-event "custom/event" 0 (jobject) #:surface-op "append")))))

(test-case "rule 8: an unknown ignorable type keeps opaque metadata"
  (for ([type (list "extension/event" "tool/code-dispatch" "tool/code-dispatch-start")])
    (define event
      (raw-event type 0 (jobject 'nested (jobject 'retained #t))
                 #:surface-op (jobject 'opaque (list "not" "placement"))
                 #:sources (jobject 'opaque (list 'null #t))
                 #:ignorable #t))
    (check-false (validate-surface-metadata event))
    (check-equal? (nodes-of (list event)) '())
    (check-equal? (derive-messages (list event)) '())))

(test-case "rule 8: a known log-only type is rejected even when ignorable"
  (for* ([type (list "turn/start" "assistant/attempt" "request/context" "session/title"
                     "tool/ptc-dispatch")]
         [metadata (list 'op 'sources)])
    (define event
      (raw-event type 0 (jobject 'turn 1 'step 1 'stream '())
                 #:surface-op (if (eq? metadata 'op) "append" absent)
                 #:sources (if (eq? metadata 'sources) (list 0) absent)
                 #:ignorable #t))
    (check-exn (session-error #rx"is not surface-eligible")
               (lambda () (validate-surface-metadata event)))))

(test-case "rule 8: a surface type requires a valid marker"
  (check-exn
   (session-error
    "session event \"user/message\" is surface-eligible and requires a surfaceOp marker")
   (lambda () (validate-surface-metadata (user-event 0 #:op absent))))
  (for ([op (list 'null 5 "replace" '() (list "append") #t)])
    (check-exn (session-error "session event \"user/message\" carries an invalid surfaceOp")
               (lambda () (validate-surface-metadata (user-event 0 #:op op)))))
  (for ([op (list (jobject 'op "replace" 'start 0 'end 0)
                  (jobject 'op "replace" 'start 0 'endSeq 0)
                  (jobject 'op "replace" 'startSeq 0 'end 0)
                  (jobject 'op "replace" 'startSeq 0 'endSeq 0 'start 0)
                  (jobject 'op "replace" 'startSeq 0 'endSeq 0 'end 0)
                  (jobject 'op "replace" 'startSeq 0 'endSeq 0 'extra #t)
                  (jobject 'op "replace" 'startSeq -1 'endSeq 0)
                  (jobject 'op "replace" 'startSeq -0.0 'endSeq -0.0)
                  (jobject 'op "swap" 'startSeq 0 'endSeq 0)
                  (jobject))])
    (check-exn
     (session-error "session event \"user/message\" carries an invalid replace surfaceOp")
     (lambda () (validate-surface-metadata (user-event 3 #:op op))))))

(test-case "rule 8: the operation is returned"
  (check-eq? (validate-surface-metadata (user-event 0)) 'append)
  (check-equal? (validate-surface-metadata
                 (user-event 5 #:op (replace-op 1 3) #:sources (list 1 2 3)))
                (surface-replace 1 3)))

(test-case "rule 8: replace endpoints must be earlier than the event"
  (for ([endpoint (list 1 2)])
    (check-exn
     (session-error "surface replace at seq 1: startSeq and endSeq must reference earlier events")
     (lambda () (validate-surface-metadata (user-event 1 #:op (replace-op endpoint 0)))))
    (check-exn
     (session-error "surface replace at seq 1: startSeq and endSeq must reference earlier events")
     (lambda () (validate-surface-metadata (user-event 1 #:op (replace-op 0 endpoint)))))))

(test-case "rule 8: only local metadata is checked, not history or endpoint order"
  (check-equal? (validate-surface-metadata
                 (user-event 12 #:op (replace-op 11 4) #:sources (list 11 4)))
                (surface-replace 11 4)))

(test-case "rule 8: sourceEventSeqs rules"
  (check-exn
   (session-error "assistant/message embeds its source stream and cannot carry sourceEventSeqs")
   (lambda () (validate-surface-metadata (assistant-event 1 #:sources (list 0)))))
  (check-exn
   (session-error "assistant/message embeds its source stream and cannot carry sourceEventSeqs")
   (lambda () (validate-surface-metadata (assistant-event 1 #:sources '()))))
  (check-exn (session-error "sourceEventSeqs on event at seq 2 must be an array when present")
             (lambda () (validate-surface-metadata (user-event 2 #:sources "invalid"))))
  (check-exn (session-error "sourceEventSeqs must not be empty")
             (lambda () (validate-surface-metadata (user-event 2 #:sources '()))))
  (for ([sources (list (list "0") (list 0.5) (list -1) (list 'null) (list 0 -0.0)
                       (list (add1 max-safe-integer)))])
    (check-exn
     (session-error (string-append "session event \"user/message\" sourceEventSeqs must "
                                   "densely contain non-negative safe integers"))
     (lambda () (validate-surface-metadata (user-event 2 #:sources sources)))))
  (check-exn (session-error "sourceEventSeqs must not contain duplicates")
             (lambda () (validate-surface-metadata (user-event 2 #:sources (list 0 0)))))
  (check-exn (session-error "sourceEventSeqs must not contain duplicates")
             (lambda () (validate-surface-metadata (user-event 2 #:sources (list 1 1.0)))))
  (check-exn (session-error "sourceEventSeqs must reference earlier events: 0 >= current seq 0")
             (lambda () (validate-surface-metadata (user-event 0 #:sources (list 0)))))
  (check-exn (session-error "sourceEventSeqs must reference earlier events: 7 >= current seq 2")
             (lambda () (validate-surface-metadata (user-event 2 #:sources (list 1 7 9)))))
  ;; Duplicates are reported before a reference that is not earlier.
  (check-exn (session-error "sourceEventSeqs must not contain duplicates")
             (lambda () (validate-surface-metadata (user-event 2 #:sources (list 5 5)))))
  (check-eq? (validate-surface-metadata (user-event 2 #:sources (list 0 1))) 'append)
  (check-eq? (validate-surface-metadata (system-event 2 "p" #:sources (list 1))) 'append)
  (check-eq? (validate-surface-metadata (tool-result-event 2 "c" #:sources (list 0))) 'append))

;; ---- rule 7: check-session-event ----

(test-case "rule 7: an imported event passes the local rules and is returned"
  (define event (user-event 12 #:op (replace-op 11 4) #:sources (list 11 4)))
  (check-eq? (check-session-event event) event)
  (define header
    (raw-event "request/header" 0 (jobject 'header (jobject 'config config 'extra (list #t))
                                           'reason "initial" 'extra (list "retained"))))
  (check-eq? (check-session-event header) header))

(test-case "rule 7: the subject names the seq"
  (check-exn (session-error "session event at seq 0 data must be an object")
             (lambda () (check-session-event (raw-event "request/header" 0 'null))))
  (check-exn (session-error "session event at seq 3 error requires message.isError === true")
             (lambda ()
               (check-session-event
                (raw-event "tool/result" 3 (jset (tool-data #f) 'error failure)
                           #:surface-op "append"))))
  (check-exn (session-error "session event at seq 0 must omit header.system; use system/message")
             (lambda ()
               (check-session-event
                (raw-event "request/header" 0
                           (jobject 'header (jobject 'config config 'system 'null)
                                    'reason "initial")))))
  (check-exn (session-error "session event at seq 2 message must have system-prompt source")
             (lambda ()
               (check-session-event
                (raw-event "system/message" 2
                           (jobject 'turn 1 'step 1
                                    'message (jset (system-message "p") 'source
                                                   (jobject 'kind "user")))
                           #:surface-op "append"))))
  (check-exn (session-error #rx"developer/message and developer role must occur together")
             (lambda ()
               (check-session-event
                (raw-event "user/message" 0 (developer-message '()) #:surface-op "append")))))

(test-case "rule 7: surface metadata is validated, the header shape is not"
  (check-exn (session-error #rx"requires a surfaceOp marker")
             (lambda () (check-session-event (user-event 0 #:op absent))))
  (check-exn (session-error #rx"must reference earlier events")
             (lambda () (check-session-event (user-event 1 #:op (replace-op 1 0)))))
  (check-exn (session-error #rx"cannot carry sourceEventSeqs")
             (lambda () (check-session-event (assistant-event 1 #:sources (list 0)))))
  ;; Only the message checks of rule 5 run: a header without provider and model passes.
  (check-not-exn
   (lambda ()
     (check-session-event
      (raw-event "request/header" 0 (jobject 'header (jobject 'config (jobject))
                                             'reason "initial"))))))

;; ---- predicates ----

(test-case "predicates: surface-eligible-type?"
  (for ([type (list "user/message" "assistant/message" "tool/result" "system/message"
                    "developer/message")])
    (check-true (surface-eligible-type? type)))
  (check-false (surface-eligible-type? "turn/start"))
  (check-false (surface-eligible-type? "assistant/attempt"))
  (check-false (surface-eligible-type? 'user/message)))

(test-case "predicates: surface events by their marker"
  (define appended (user-event 1))
  (define replacement (user-event 4 #:op (replace-op 1 2) #:sources (list 1 2)))
  (define markerless (user-event 0 #:op absent))
  (define log-only (boundary-event 0))
  (check-true (surface-event? appended))
  (check-true (surface-event? replacement))
  (check-false (surface-event? markerless))
  (check-false (surface-event? log-only))
  (check-true (append-surface-event? appended))
  (check-false (replacement-surface-event? appended))
  (check-false (append-surface-event? replacement))
  (check-true (replacement-surface-event? replacement))
  (for ([event (list markerless log-only)])
    (check-false (append-surface-event? event))
    (check-false (replacement-surface-event? event)))
  (check-false (surface-event?
                (raw-event "turn/start" 0 (jobject 'turn 1) #:surface-op "append"))))

;; ---- rule 17: states and folds ----

(test-case "rule 17: the empty state"
  (define st (surface-state-empty))
  (check-true (surface-state? st))
  (check-equal? (surface-state-nodes st) '())
  (check-equal? (surface-state-node-count st) 0)
  (check-equal? (surface-state-replace-generation st) 0)
  (check-equal? (surface-state-content-generation st) 0)
  (check-equal? (surface-state-next-seq st) 0)
  (check-equal? (surface-state-base-seq st) 0)
  (check-equal? (hash-count (surface-state-projected-messages st)) 0)
  (check-equal? (surface-state-projections st) '())
  (check-equal? (surface-state-next-seq (surface-state-empty #:base-seq 40)) 40)
  (check-equal? (nodes-of '()) '()))

(test-case "rule 17: append markers fold into the ordered node list"
  (define events
    (list (boundary-event 0)
          (user-event 1 "hello")
          (assistant-event 2)
          (raw-event "turn/end" 3 (jobject 'turn 1 'reason (jobject 'kind "completed")))))
  (define result (fold-surface events))
  (check-equal? (surface-fold-result-nodes result) '(1 2))
  (check-equal? (surface-fold-result-replacements result) '())
  (check-equal? (hash-count (surface-fold-result-projected-messages result)) 0)
  (define st (fold-stepwise events))
  (check-equal? (surface-state-nodes st) '(1 2))
  (check-equal? (surface-state-node-count st) 2)
  (check-equal? (surface-state-next-seq st) 4)
  (check-equal? (surface-state-replace-generation st) 0))

(test-case "rule 17: plan validates without changing the state, apply returns the next one"
  (define st0 (surface-state-empty))
  (define first-event (user-event 0))
  (define plan (surface-plan st0 first-event (lambda (seq) #f) '()))
  (check-true (surface-plan? plan))
  (check-false (surface-plan-replacement plan))
  (check-equal? (surface-state-nodes st0) '())
  (check-equal? (surface-state-next-seq st0) 0)
  (define st1 (surface-apply st0 plan))
  (check-equal? (surface-state-nodes st1) '(0))
  (check-equal? (surface-state-next-seq st1) 1)
  (check-equal? (surface-state-nodes st0) '())
  ;; A log-only event advances the next seq and nothing else.
  (define st2 (surface-step st1 (boundary-event 1) (lambda (seq) #f) '()))
  (check-equal? (surface-state-nodes st2) '(0))
  (check-equal? (surface-state-next-seq st2) 2)
  (check-equal? (surface-state-nodes-from st2 0) '(0))
  (check-equal? (surface-state-nodes-from st2 1) '())
  (check-equal? (surface-state-nodes-from st2 5) '()))

(test-case "rule 17: a plan applies only to the state it was made from"
  (define st0 (surface-state-empty))
  (define plan (surface-plan st0 (user-event 0) (lambda (seq) #f) '()))
  (define st1 (surface-apply st0 plan))
  (check-exn exn:fail:contract? (lambda () (surface-apply st1 plan)))
  (check-exn exn:fail:contract? (lambda () (surface-apply (surface-state-empty) plan))))

(test-case "rule 17: a failed plan leaves the state usable"
  (define events (list (user-event 0 "a")))
  (define st (fold-stepwise events))
  (define log (list->vector events))
  (define (event-ref seq) (and (< seq (vector-length log)) (vector-ref log seq)))
  (check-exn (session-error #rx"missing 0")
             (lambda () (surface-plan st (assistant-event 1 #:op (replace-op 0 0)) event-ref '())))
  (check-equal? (surface-state-nodes st) '(0))
  (check-equal? (surface-state-replace-generation st) 0)
  (define next (surface-step st (user-event 1 "b") event-ref '()))
  (check-equal? (surface-state-nodes next) '(0 1))
  (check-equal? (surface-state-replace-generation next) 0))

(test-case "rule 17: nodes-from returns the tail added since a position"
  (define events (for/list ([seq (in-range 6)]) (user-event seq)))
  (define st (fold-stepwise events))
  (check-equal? (surface-state-nodes-from st 0) '(0 1 2 3 4 5))
  (check-equal? (surface-state-nodes-from st 4) '(4 5))
  (check-equal? (surface-state-nodes-from st 6) '()))

(test-case "rule 17: fold-surface equals stepwise folding on the sample log"
  (define log (sample-log))
  (define result (fold-surface log))
  (define st (fold-stepwise log))
  (check-equal? (surface-fold-result-nodes result) '(2 3 6 8))
  (check-equal? (surface-state-nodes st) (surface-fold-result-nodes result))
  (check-equal? (surface-state-projected-messages st)
                (surface-fold-result-projected-messages result))
  (check-equal? (surface-state-next-seq st) (length log)))

;; ---- rule 18: planning one event ----

(test-case "rule 18: the event seq must be the next seq"
  (check-exn (session-error "session event seq 2 is not contiguous; expected 1")
             (lambda () (fold-surface (list (user-event 0) (user-event 2 #:sources (list 1))))))
  (check-exn (session-error "session event seq 0 is not contiguous; expected 5")
             (lambda ()
               (surface-plan (surface-state-empty #:base-seq 5) (user-event 0)
                             (lambda (seq) #f) '()))))

(test-case "rule 18: metadata errors surface through the fold"
  (check-exn (session-error #rx"cannot carry sourceEventSeqs")
             (lambda ()
               (fold-surface (list (raw-event "turn/start" 0 (jobject 'turn 1)
                                              #:sources (list 0))))))
  (check-exn (session-error #rx"embeds its source stream")
             (lambda () (fold-surface (list (assistant-event 0 '() #:sources '())))))
  (check-exn (session-error #rx"surface-eligible and requires a surfaceOp marker")
             (lambda () (fold-surface (list (user-event 0 "hidden" #:op absent)))))
  (check-exn (session-error #rx"not surface-eligible and cannot carry surfaceOp")
             (lambda ()
               (fold-surface (list (raw-event "turn/start" 0 (jobject 'turn 1)
                                              #:surface-op "append")))))
  (check-exn (session-error #rx"invalid replace surfaceOp")
             (lambda ()
               (fold-surface (list (user-event 0 #:op (replace-op -0.0 -0.0)
                                               #:sources (list 0)))))))

(define first-tool
  (jobject 'name "search" 'description "First" 'parameters (jobject 'type "object")))
(define second-tool
  (jobject 'name "search" 'description "Second"
           'parameters (jobject 'properties (jobject 'query (jobject 'type "string")))))
(define other-tool (jobject 'name "other" 'description "Other" 'parameters (jobject)))

;; turn/start, step/start and a header with `tools` at seq 2.
(define (opened [tools (list first-tool)])
  (list (boundary-event 0)
        (raw-event "step/start" 1 (jobject 'turn 1 'step 1))
        (header-event 2 tools)))

(define addition (list (tool-addition-block "search")))

(test-case "rule 18: a tool addition resolves against an earlier request/header"
  (define events (append (opened) (list (developer-event 3 addition #:header-seq 2))))
  (check-equal? (nodes-of events) '(3))
  ;; The header may be an earlier member of the same batch.
  (define batch
    (list (header-event 0 (list first-tool)) (developer-event 1 addition #:header-seq 0)))
  (check-equal? (nodes-of batch) '(1)))

(test-case "rule 18: headerSeq must name an earlier request/header"
  (define message "developer/message headerSeq must reference an earlier request/header")
  (for ([reference (list 0 3 100)])
    (check-exn (session-error message)
               (lambda ()
                 (fold-surface
                  (append (opened) (list (developer-event 3 addition #:header-seq reference)))))))
  (for ([reference (list 1 2)])
    (check-exn (session-error message)
               (lambda ()
                 (fold-surface
                  (list (header-event 0 (list first-tool))
                        (developer-event 1 addition #:header-seq reference)))))))

(test-case "rule 18: the header must define each added tool exactly once"
  (for ([tools (list (list (jset first-tool 'name "different"))
                     (list first-tool second-tool)
                     #f)])
    (check-exn
     (session-error
      "developer/message tool-addition \"search\" must name exactly one tool in headerSeq 2")
     (lambda ()
       (fold-surface
        (append (opened tools) (list (developer-event 3 addition #:header-seq 2))))))))

(test-case "rule 18: the referenced definition must be complete"
  (define incomplete
    (string-append "developer/message tool-addition \"search\" requires a complete tool "
                   "definition in headerSeq 2"))
  (for ([tool (list (jobject 'name "search")
                    (jobject 'name "search" 'description 'null 'parameters (jobject))
                    (jobject 'name "search" 'description "" 'parameters '()))])
    (check-exn (session-error incomplete)
               (lambda ()
                 (fold-surface
                  (append (opened (list tool))
                          (list (developer-event 3 addition #:header-seq 2)))))))
  (check-exn
   (session-error "developer/message referenced tool deferLoading must be true when present")
   (lambda ()
     (fold-surface
      (append (opened (list (jset first-tool 'deferLoading #f)))
              (list (developer-event 3 addition #:header-seq 2))))))
  (check-equal?
   (nodes-of (append (opened (list (jset first-tool 'deferLoading #t)))
                     (list (developer-event 3 addition #:header-seq 2))))
   '(3)))

(test-case "rule 18: the developer rules of rule 4 are re-run with the seq as subject"
  (check-exn
   (session-error
    "developer/message at seq 3 requires headerSeq exactly when tool additions are present")
   (lambda () (fold-surface (append (opened) (list (developer-event 3 addition))))))
  (check-exn
   (session-error
    "developer/message at seq 3 requires headerSeq exactly when tool additions are present")
   (lambda ()
     (fold-surface
      (append (opened)
              (list (developer-event 3 (list (tool-removal-block "search")) #:header-seq 2))))))
  (check-exn
   (session-error "developer/message at seq 3 tool-addition must omit inline tool definitions")
   (lambda ()
     (fold-surface
      (append (opened)
              (list (developer-event
                     3 (list (jset (tool-addition-block "search") 'tool first-tool))
                     #:header-seq 2))))))
  (check-exn
   (session-error "developer/message at seq 3 tool-addition requires a nonempty toolName")
   (lambda ()
     (fold-surface
      (append (opened) (list (developer-event 3 (list (tool-addition-block ""))
                                              #:header-seq 2)))))))

(test-case "rule 18: an older header binding survives a later header and a replacement"
  (define compound
    (list (tool-removal-block "search") (tool-addition-block "search")
          (tool-addition-block "other")))
  (define events
    (append (opened (list first-tool other-tool))
            (list (header-event 3 (list second-tool) #:reason "change")
                  (developer-event 4 compound #:header-seq 2)
                  (developer-event 5 addition #:header-seq 2
                                   #:op (replace-op 4 4) #:sources (list 4)))))
  (check-equal? (nodes-of events) '(5))
  (check-equal? (map (lambda (message) (jref message 'content)) (derive-messages events))
                (list addition)))

(test-case "rule 18: an empty developer node keeps its position and derives no message"
  (define events (list (developer-event 0 '())))
  (check-equal? (nodes-of events) '(0))
  (check-equal? (derive-messages events) '()))

;; ---- rule 18 and 20: message projections ----

;; Rewrites the text of the message of the event named by `data.seq`; rejects the text
;; "reject".
(define test-projection
  (message-projection
   "test/project"
   (lambda (event context)
     (define data (session-event-data event))
     (define source ((projection-context-event-ref context) (jref data 'seq)))
     (define original (derive-event-message source (projection-context-messages context)))
     (when (equal? (jref data 'text) "reject")
       (error "rejected decision"))
     (hasheqv (session-event-seq source)
              (jset original 'content (list (text-block (jref data 'text))))))))

(define (project-event seq target text)
  (raw-event "test/project" seq (jobject 'seq target 'text text)))

(test-case "rule 18: an event that needs a projection is refused without one"
  (define event (raw-event "image/offload" 0 (jobject)))
  (check-exn
   (session-error (string-append "session event \"image/offload\" requires a message "
                                 "projection; load its owning plugin or supply its projection "
                                 "definition"))
   (lambda () (fold-surface (list event))))
  (define offload-projection
    (message-projection "image/offload" (lambda (event context) (hasheqv))))
  (check-equal? (surface-fold-result-nodes
                 (fold-surface (list event) #:projections (list offload-projection)))
                '()))

(test-case "rule 20: a projection changes message content, not nodes or positions"
  (define source (user-event 0 "original"))
  (define events (list source (project-event 1 0 "projected")))
  (define result (fold-surface events #:projections (list test-projection)))
  (check-equal? (surface-fold-result-nodes result) '(0))
  (check-equal? (surface-fold-result-replacements result) '())
  (define projected (surface-fold-result-projected-messages result))
  (check-equal? (jref (derive-event-message source projected) 'content)
                (list (text-block "projected")))
  (check-equal? (jref (session-event-data source) 'content) (list (text-block "original")))
  (check-equal? (map (lambda (message) (jref message 'content))
                     (derive-messages events #:projections (list test-projection)))
                (list (list (text-block "projected"))))
  (define st (fold-stepwise events #:projections (list test-projection)))
  (check-equal? (surface-state-replace-generation st) 0)
  (check-equal? (surface-state-content-generation st) 1)
  (check-equal? (surface-state-projections st) (list test-projection))
  (check-equal? (surface-state-nodes st) '(0)))

(test-case "rule 20: a rejected projection raises and changes nothing"
  (define source (user-event 0 "original"))
  (define st (fold-stepwise (list source)))
  (check-exn #rx"rejected decision"
             (lambda ()
               (surface-plan st (project-event 1 0 "reject") (lambda (seq) source)
                             (list test-projection))))
  (check-equal? (surface-state-content-generation st) 0)
  (check-equal? (surface-state-projections st) '())
  (check-exn #rx"rejected decision"
             (lambda ()
               (fold-surface (list source (project-event 1 0 "reject"))
                             #:projections (list test-projection)))))

(test-case "rule 20: later projections see earlier ones and each bumps the generation"
  (define events
    (list (user-event 0 "original")
          (project-event 1 0 "first")
          (project-event 2 0 "second")))
  (define st (fold-stepwise events #:projections (list test-projection)))
  (check-equal? (surface-state-content-generation st) 2)
  (check-equal? (surface-state-projections st) (list test-projection))
  (check-equal?
   (jref (hash-ref (surface-state-projected-messages st) 0) 'content)
   (list (text-block "second"))))

(test-case "rule 20: a projection applies to a loaded window with absolute seqs"
  (define first-input (user-event 0 "original"))
  (define source (user-event 1 "original"))
  (define window (list source (project-event 2 1 "window")))
  (define st (fold-stepwise window #:base 1 #:projections (list test-projection)))
  (check-equal? (surface-state-nodes st) '(1))
  (check-equal? (surface-state-base-seq st) 1)
  (check-equal? (jref (derive-event-message source (surface-state-projected-messages st))
                      'content)
                (list (text-block "window")))
  (check-equal? (jref (derive-event-message first-input (surface-state-projected-messages st))
                      'content)
                (list (text-block "original"))))

(test-case "rule 20: the projection context describes the history before the event"
  (define seen #f)
  (define recording
    (message-projection
     "test/project"
     (lambda (event context)
       (set! seen (list (projection-context-nodes context)
                        (projection-context-base-seq context)
                        (hash-count (projection-context-messages context))
                        (session-event-seq ((projection-context-event-ref context) 5))))
       (hasheqv))))
  (define window (list (user-event 5) (user-event 6) (project-event 7 5 "x")))
  (fold-stepwise window #:base 5 #:projections (list recording))
  (check-equal? seen '((5 6) 5 0 5)))

;; ---- rule 21: used projections must stay registered ----

(test-case "rule 21: a state refuses reads once a projection it used is gone"
  (define events (list (user-event 0 "original") (project-event 1 0 "changed")))
  (define st (fold-stepwise events #:projections (list test-projection)))
  (check-not-exn (lambda () (check-surface-projections st (list test-projection))))
  (define message
    (string-append "session message projection \"test/project\" was removed or replaced; "
                   "restore the session with its owning plugin"))
  (check-exn (session-error message) (lambda () (check-surface-projections st '())))
  ;; A different definition for the same type does not stand in for the one that was used.
  (define replacement
    (message-projection "test/project" (lambda (event context) (hasheqv))))
  (check-exn (session-error message)
             (lambda () (check-surface-projections st (list replacement)))))

(test-case "rule 21: a projection that was planned but never applied is not required"
  (define source (user-event 0 "original"))
  (define st (fold-stepwise (list source)))
  (surface-plan st (project-event 1 0 "unused") (lambda (seq) source) (list test-projection))
  (check-not-exn (lambda () (check-surface-projections st '())))
  (check-eq? (derive-event-message source (surface-state-projected-messages st))
             (session-event-data source)))

;; ---- rule 19: replacement ----

(test-case "rule 19: a replacement takes the place of the range it shadows"
  (check-equal? (nodes-of (list (boundary-event 0) (user-event 1) (assistant-event 2)
                                (boundary-event 3 "turn/end")
                                (user-event 4 #:op (replace-op 1 2) #:sources (list 1 2))))
                '(4))
  (check-equal? (nodes-of (list (user-event 0 "a") (user-event 1 "b") (user-event 2 "c")
                                (user-event 3 #:op (replace-op 0 1) #:sources (list 0 1))))
                '(3 2))
  (check-equal? (nodes-of (list (user-event 0 "a") (user-event 1 "b")
                                (user-event 2 #:op (replace-op 1 1) #:sources (list 1))))
                '(0 2))
  (check-equal? (nodes-of (list (user-event 0) (user-event 1) (user-event 2) (user-event 3)
                                (user-event 4 #:op (replace-op 1 2) #:sources (list 1 2))))
                '(0 4 3)))

(test-case "rule 19: accepted source references and complete coverage"
  (check-not-exn
   (lambda ()
     (fold-surface (list (user-event 0)
                         (user-event 1)
                         (user-event 2 #:op (replace-op 0 1) #:sources (list 0 1)))))))

(test-case "rule 19: replacement history is reported in event order"
  (define events
    (list (user-event 0 "a")
          (user-event 1 "b")
          (user-event 2 "summary" #:op (replace-op 0 0) #:sources (list 0))
          (user-event 3 "summary 2" #:op (replace-op 2 1) #:sources (list 2 1))))
  (define result (fold-surface events))
  (check-equal? (surface-fold-result-nodes result) '(3))
  (check-equal? (surface-fold-result-replacements result)
                (list (surface-replacement 2 0 0 '(0))
                      (surface-replacement 3 2 1 '(2 1))))
  (define st (fold-stepwise events))
  (check-equal? (surface-state-nodes st) '(3))
  (check-equal? (surface-state-replace-generation st) 2)
  (check-equal? (surface-state-content-generation st) 2)
  (check-equal? (surface-state-node-count st) 1))

(test-case "rule 19: the plan of a replacement names what it shadows"
  (define events (list (user-event 0) (user-event 1)))
  (define st (fold-stepwise events))
  (define plan
    (surface-plan st (user-event 2 #:op (replace-op 0 1) #:sources (list 0 1))
                  (lambda (seq) (list-ref events seq)) '()))
  (check-equal? (surface-plan-replacement plan) (surface-replacement 2 0 1 '(0 1)))
  (check-equal? (surface-state-nodes st) '(0 1)))

(test-case "rule 19: endpoints must be current nodes in surface order"
  (check-exn (session-error "surface replace: start seq 1 not found in surface")
             (lambda ()
               (fold-surface (list (user-event 0)
                                   (boundary-event 1)
                                   (user-event 2 #:op (replace-op 1 0) #:sources (list 0))))))
  (check-exn (session-error "surface replace: end seq 1 not found in surface")
             (lambda ()
               (fold-surface (list (user-event 0)
                                   (boundary-event 1)
                                   (user-event 2 #:op (replace-op 0 1) #:sources (list 0))))))
  (check-exn
   (session-error "surface replace: start seq 1 (index 1) is after end seq 0 (index 0)")
   (lambda ()
     (fold-surface (list (user-event 0)
                         (user-event 1)
                         (user-event 2 #:op (replace-op 1 0) #:sources (list 0 1))))))
  ;; A node that an earlier replacement shadowed is no longer a valid endpoint.
  (check-exn (session-error "surface replace: start seq 0 not found in surface")
             (lambda ()
               (fold-surface
                (list (user-event 0)
                      (user-event 1 #:op (replace-op 0 0) #:sources (list 0))
                      (user-event 2 #:op (replace-op 0 0) #:sources (list 0)))))))

(test-case "rule 19: sourceEventSeqs must include every shadowed node"
  (check-exn
   (session-error
    "surface replace: sourceEventSeqs must include every shadowed surface node; missing 1")
   (lambda ()
     (fold-surface (list (user-event 0)
                         (user-event 1)
                         (user-event 2 #:op (replace-op 0 1) #:sources (list 0))))))
  (check-exn
   (session-error
    "surface replace: sourceEventSeqs must include every shadowed surface node; missing 0, 2")
   (lambda ()
     (fold-surface (list (user-event 0)
                         (user-event 1)
                         (user-event 2)
                         (user-event 3 #:op (replace-op 0 2) #:sources (list 1))))))
  (check-exn (session-error #rx"missing 0")
             (lambda ()
               (fold-surface (list (user-event 0)
                                   (assistant-event 1 #:op (replace-op 0 0)))))))

(test-case "rule 19: a tool/result replacement rewrites one current tool/result"
  (check-exn
   (session-error "tool/result surface replacement must rewrite exactly one current node")
   (lambda ()
     (fold-surface (list (user-event 0)
                         (user-event 1)
                         (tool-result-event 2 "rewrite" #:op (replace-op 0 1)
                                            #:sources (list 0 1))))))
  (check-exn
   (session-error "tool/result surface replacement must target a current tool/result")
   (lambda ()
     (fold-surface (list (user-event 0)
                         (tool-result-event 1 "rewrite" #:op (replace-op 0 0)
                                            #:sources (list 0)))))))

(test-case "rule 19: a tool/result replacement may change only content"
  (define changed "tool/result surface replacement may change only content")
  (check-exn (session-error changed)
             (lambda ()
               (fold-surface
                (list (tool-result-event 0 "original" #:id "same")
                      (tool-result-event 1 "changed" #:id "same" #:op (replace-op 0 0)
                                         #:sources (list 0))))))
  ;; A different message id is a change outside content.
  (check-exn (session-error changed)
             (lambda ()
               (fold-surface
                (list (tool-result-event 0 "call" #:id "first")
                      (tool-result-event 1 "call" #:id "second" #:op (replace-op 0 0)
                                         #:sources (list 0))))))
  (check-exn (session-error changed)
             (lambda ()
               (fold-surface
                (list (tool-result-event 0 "call" #:id "same")
                      (tool-result-event 1 "call" #:id "same" #:error? #t
                                         #:op (replace-op 0 0) #:sources (list 0))))))
  ;; The content differs between the two events (the text names the seq) and is accepted.
  (check-equal?
   (nodes-of (list (tool-result-event 0 "call" #:id "same")
                   (tool-result-event 1 "call" #:id "same" #:op (replace-op 0 0)
                                      #:sources (list 0))))
   '(1)))

(test-case "rule 19: fields beside the message compare structurally"
  (define (rewrite original-meta replacement-meta)
    (list (tool-result-event 0 "c-meta" #:id "meta-message" #:meta original-meta)
          (tool-result-event 1 "c-meta" #:id "meta-message" #:meta replacement-meta
                             #:op (replace-op 0 0) #:sources (list 0))))
  (define changed (session-error "tool/result surface replacement may change only content"))
  (check-not-exn
   (lambda ()
     (fold-surface (rewrite (jobject 'tags (list "a" (jobject 'n 1)))
                            (jobject 'tags (list "a" (jobject 'n 1.0)))))))
  (check-not-exn
   (lambda ()
     (fold-surface (rewrite (jobject 'a 1 'b 2) (jobject 'b 2 'a 1)))))
  (check-exn changed
             (lambda () (fold-surface (rewrite (jobject 'tags (list "a"))
                                               (jobject 'tags (list "b"))))))
  (check-exn changed
             (lambda () (fold-surface (rewrite (jobject 'tags (list "a"))
                                               (jobject 'tags "a")))))
  (check-exn changed
             (lambda () (fold-surface (rewrite (jobject 'left 1) (jobject 'right 1)))))
  (check-exn changed
             (lambda () (fold-surface (rewrite (jobject 'one 1) (jobject 'one 1 'two 2)))))
  (check-exn changed
             (lambda () (fold-surface (rewrite (jobject 'one 1) absent))))
  (check-exn changed
             (lambda () (fold-surface (rewrite (jobject 'one 'null) (jobject))))))

(test-case "rule 19: node 0 holding the system prompt is rewritten only by a system/message"
  (define protected
    (string-append "surface replace: node 0 holds the system prompt and may be rewritten only "
                   "by a system/message over exactly that node"))
  (check-equal?
   (nodes-of (list (system-event 0 "v1")
                   (user-event 1)
                   (system-event 2 "v2" #:op (replace-op 0 0) #:sources (list 0))))
   '(2 1))
  (check-exn (session-error protected)
             (lambda ()
               (fold-surface
                (list (system-event 0 "v1")
                      (user-event 1)
                      (user-event 2 #:op (replace-op 0 1) #:sources (list 0 1))))))
  (check-exn (session-error protected)
             (lambda ()
               (fold-surface
                (list (system-event 0 "v1")
                      (user-event 1)
                      (system-event 2 "v2" #:op (replace-op 0 1) #:sources (list 0 1))))))
  (check-exn (session-error protected)
             (lambda ()
               (fold-surface
                (list (system-event 0 "v1")
                      (user-event 1 #:op (replace-op 0 0) #:sources (list 0)))))))

(test-case "rule 19: later system nodes and a non-system head are not protected"
  (check-equal?
   (nodes-of (list (system-event 0 "v1") (user-event 1) (system-event 2 "v2") (user-event 3)
                   (user-event 4 #:op (replace-op 1 3) #:sources (list 1 2 3))))
   '(0 4))
  (check-equal?
   (nodes-of (list (user-event 0) (user-event 1)
                   (user-event 2 #:op (replace-op 0 1) #:sources (list 0 1))))
   '(2)))

;; ---- windowed folds ----

(test-case "windows: a contiguous window folds with absolute seqs"
  (define base 400000)
  (define events
    (list (user-event base)
          (user-event (+ base 1))
          (user-event (+ base 2) #:op (replace-op base base) #:sources (list base))))
  (define st (fold-stepwise events #:base base))
  (check-equal? (surface-state-nodes st) (list (+ base 2) (+ base 1)))
  (check-equal? (surface-state-replace-generation st) 1)
  (check-equal? (surface-state-next-seq st) (+ base 3))
  (check-equal? (surface-state-base-seq st) base))

(test-case "windows: tool-result rewrites are validated against the window offset"
  (define base 400000)
  (define events
    (list (tool-result-event base "call" #:id "same")
          (tool-result-event (+ base 1) "call" #:id "same" #:op (replace-op base base)
                             #:sources (list base))))
  (check-equal? (surface-state-nodes (fold-stepwise events #:base base)) (list (+ base 1))))

(test-case "windows: a replacement cannot cross the head of a loaded window"
  (define base 400000)
  (define events
    (list (user-event base)
          (user-event (+ base 1) #:op (replace-op (- base 1) base)
                      #:sources (list (- base 1) base))))
  (check-exn (session-error "surface replace: start seq 399999 not found in surface")
             (lambda () (fold-stepwise events #:base base))))

(test-case "windows: a header before the window does not resolve an addition"
  (define window (list (developer-event 3 addition #:header-seq 2)))
  (check-exn
   (session-error "developer/message headerSeq must reference an earlier request/header")
   (lambda () (fold-stepwise window #:base 3))))

;; ---- fold-surface equals stepwise folding ----

(test-case "fold-surface equals stepwise folding for generated logs"
  (define generator (make-pseudo-random-generator))
  (parameterize ([current-pseudo-random-generator generator])
    (random-seed 20261113)
    (for ([trial (in-range 60)])
      (define-values (events nodes)
        (for/fold ([events '()] [nodes '()]) ([seq (in-range (+ 5 (random 40)))])
          (define choice (random 10))
          (cond
            [(< choice 3) (values (cons (boundary-event seq) events) nodes)]
            [(and (>= choice 8) (pair? nodes))
             ;; Replace a random inclusive range of the current nodes.
             (define start (random (length nodes)))
             (define end (+ start (random (- (length nodes) start))))
             (define shadowed (take (drop nodes start) (add1 (- end start))))
             (values (cons (user-event seq
                                       #:op (replace-op (first shadowed) (last shadowed))
                                       #:sources shadowed)
                           events)
                     (append (take nodes start) (list seq) (drop nodes (add1 end))))]
            [else (values (cons (user-event seq) events) (append nodes (list seq)))])))
      (define log (reverse events))
      (define result (fold-surface log))
      (define st (fold-stepwise log))
      (check-equal? (surface-fold-result-nodes result) nodes)
      (check-equal? (surface-state-nodes st) nodes)
      (check-equal? (surface-state-node-count st) (length nodes))
      (check-equal? (surface-state-replace-generation st)
                    (length (surface-fold-result-replacements result)))
      (check-equal? (surface-state-nodes-from st 0) nodes)
      (check-equal? (length (derive-messages log)) (length nodes)))))
