#lang racket/base
;; Test fixtures for the session data plane: message builders, a builder of events from
;; inputs, a builder of raw events with arbitrary metadata, a small valid log, and predicates
;; for the two kinds of error the package raises.
;;
;; Messages use the key order of recorded dsh logs (`role, content, source, id`; a tool
;; result is `role, source, toolCallId, content, isError, id`). Message ids are explicit, or
;; taken from a per-builder counter when omitted.

(require racket/list
         cordis-data
         dsh-session/types
         dsh-session/events)

(provide text-block
         tool-call-block
         tool-addition-block
         tool-removal-block
         user-message
         assistant-message
         system-message
         developer-message
         tool-result-message
         tool-schema
         inputs->events
         raw-event
         replace-op
         sample-log
         session-error
         contract-error
         repository-file)

;; ---- blocks and messages ----

(define (text-block text)
  (jobject 'type "text" 'text text))

(define (tool-call-block id name arguments)
  (jobject 'type "tool-call" 'id id 'name name 'arguments arguments))

(define (tool-addition-block name)
  (jobject 'type "tool-addition" 'toolName name))

(define (tool-removal-block name)
  (jobject 'type "tool-removal" 'toolName name))

(define next-id
  (let ([counter 0])
    (lambda ()
      (set! counter (add1 counter))
      (format "message-~a" counter))))

(define (content-of v)
  (cond
    [(string? v) (list (text-block v))]
    [else v]))

;; `content` is a list of blocks, or a string for one text block.
(define (user-message content #:id [id (next-id)] #:source [source (jobject 'kind "user")])
  (jobject 'role "user" 'content (content-of content) 'source source 'id id))

(define (assistant-message content
                           #:id [id (next-id)]
                           #:provider [provider "mock"]
                           #:model [model "mock"])
  (jobject 'role "assistant"
           'content (content-of content)
           'source (jobject 'kind "model" 'provider provider 'model model)
           'id id))

;; An empty text gives a message with no content, as dsh's `createSystemMessage` does.
(define (system-message text #:id [id (next-id)])
  (jobject 'role "system"
           'content (if (string=? text "") '() (list (text-block text)))
           'source (jobject 'kind "system-prompt")
           'id id))

(define (developer-message content
                           #:id [id (next-id)]
                           #:source [source (jobject 'kind "tool-registry")])
  (jobject 'role "developer" 'content (content-of content) 'source source 'id id))

(define (tool-result-message call-id content #:id [id (next-id)] #:error? [error? #f])
  (jobject 'role "tool"
           'source (jobject 'kind "tool" 'callId call-id)
           'toolCallId call-id
           'content (content-of content)
           'isError error?
           'id id))

(define (tool-schema name #:description [description "A tool."] #:defer? [defer? #f])
  (define schema
    (jobject 'name name
             'description description
             'parameters (jobject 'type "object" 'properties empty-jobject)))
  (if defer? (jset schema 'deferLoading #t) schema))

;; ---- events ----

;; inputs->events : (listof session-event-input?) -> (listof session-event?)
;; Gives the inputs consecutive seqs from `from`; the time of an event is its seq plus
;; `time-base`. Metadata is written in the order of a live append.
(define (inputs->events inputs #:from [from 0] #:time-base [time-base 1000])
  (for/list ([input (in-list inputs)] [seq (in-naturals from)])
    (make-session-event (session-event-input-type input)
                        seq
                        (+ time-base seq)
                        (session-event-input-data input)
                        #:sources (or (session-event-input-sources input) absent)
                        #:surface-op (or (session-event-input-surface-op input) absent))))

;; The JSON form of a replace operation, for `raw-event`.
(define (replace-op start end)
  (jobject 'op "replace" 'startSeq start 'endSeq end))

;; raw-event : string? number jvalue ... -> session-event?
;; Reads an envelope whose metadata is any JSON value, valid or not. A keyword left at
;; `absent` writes no key. The time defaults to the seq.
(define (raw-event type seq data
                   #:time [time seq]
                   #:surface-op [surface-op absent]
                   #:sources [sources absent]
                   #:ignorable [ignorable absent])
  (define (optional key value)
    (if (absent? value) '() (list (cons key value))))
  (jvalue->session-event
   (make-jobject (append (list (cons 'type type) (cons 'seq seq) (cons 'time time)
                               (cons 'data data))
                         (optional 'sourceEventSeqs sources)
                         (optional 'surfaceOp surface-op)
                         (optional 'ignorable ignorable)))))

;; A valid log of one completed turn: turn and step boundaries, a system prompt, a user
;; prompt, a request header and context, an assistant message with one tool call, the call,
;; its result, and the closers. The `tool/call` is at seq 7 and its result cites it.
(define (sample-log)
  (inputs->events
   (list (turn/start #:turn 1)
         (step/start #:turn 1 #:step 1)
         (system/message #:turn 1 #:step 1
                         #:message (system-message "be brief" #:id "system-1")
                         #:surface-op 'append)
         (user/message (user-message "hello" #:id "user-1") #:surface-op 'append)
         (request/header #:header (jobject 'config (jobject 'provider "mock" 'model "mock")
                                           'tools (list (tool-schema "read")))
                         #:reason "initial")
         (request/context #:provider "mock" #:model "mock")
         (assistant/message #:turn 1 #:step 1
                            #:message (assistant-message
                                       (list (text-block "reading")
                                             (tool-call-block "call-1" "read" "{}"))
                                       #:id "assistant-1")
                            #:usage (jobject 'inputTokens 3 'outputTokens 2)
                            #:stream '()
                            #:surface-op 'append)
         (tool/call #:turn 1 #:step 1 #:call-id "call-1" #:name "read" #:arguments "{}")
         (tool/result #:turn 1 #:step 1
                      #:message (tool-result-message "call-1" "contents" #:id "tool-1")
                      #:surface-op 'append
                      #:sources '(7))
         (step/end #:turn 1 #:step 1)
         (turn/end #:turn 1 #:reason (jobject 'kind "completed")))))

;; ---- error predicates ----

(define ((error-matching kind?) expected)
  (lambda (e)
    (and (kind? e)
         (if (string? expected)
             (string=? (exn-message e) expected)
             (regexp-match? expected (exn-message e))))))

;; (session-error expected) -> predicate for `check-exn`: an `exn:fail:session` whose message
;; equals the string `expected` or matches the regexp `expected`.
(define session-error (error-matching exn:fail:session?))

;; The same for `exn:fail:contract`.
(define contract-error (error-matching exn:fail:contract?))

;; ---- repository files ----

;; repository-file : string? ... -> (or/c path? #f)
;; A file of the dsh repository this package is checked out in, or #f when the package is
;; used outside it.
(define (repository-file . elements)
  (define here (collection-file-path "info.rkt" "dsh-session"))
  (define-values (package-directory name must-be-directory?) (split-path here))
  (define path
    (apply build-path package-directory 'up 'up elements))
  (and (file-exists? path) (simplify-path path)))
