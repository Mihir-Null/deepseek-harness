#lang racket/base
;; Tests of `dsh-session/events`: the 14 core declarations, the data key order their
;; constructors write, the embedded shapes, and the key-order fixture taken from a recorded
;; dsh session.

(require rackunit
         racket/list
         racket/port
         racket/set
         racket/string
         cordis-data
         dsh-session/types
         dsh-session/events
         "support/log.rkt")

(define (data-text input)
  (jvalue->string (session-event-input-data input)))

(define turn-fields '((turn "turn" #f)))
(define step-fields '((turn "turn" #f) (step "step" #f)))

;; ---- declarations ----

(test-case "core events: the 14 declarations with their tags, in the dsh order"
  (check-equal? (map session-event-type-tag core-session-event-types)
                '("turn/start" "turn/end" "step/start" "step/end" "user/message"
                  "developer/message" "system/message" "assistant/message"
                  "assistant/attempt" "tool/call" "tool/result" "request/header"
                  "request/context" "session/end-seed"))
  (check-equal? (length core-session-event-types) 14)
  (for ([type (in-list core-session-event-types)])
    (check-false (session-event-type-ignorable? type))))

(test-case "core events: exactly the five surface types are surface-eligible"
  (check-equal? (for/list ([type (in-list core-session-event-types)]
                           #:when (session-event-type-surface? type))
                  (session-event-type-tag type))
                '("user/message" "developer/message" "system/message" "assistant/message"
                  "tool/result"))
  (check-equal? surface-event-types
                (set "system/message" "developer/message" "user/message" "assistant/message"
                     "tool/result"))
  (check-equal? message-projection-event-types (set "image/offload")))

(test-case "core events: fields are declared in the order dsh writes them"
  (check-equal? (session-event-type-fields turn/start-type) turn-fields)
  (check-equal? (session-event-type-fields turn/end-type)
                '((turn "turn" #f) (reason "reason" #f)))
  (check-equal? (session-event-type-fields step/start-type) step-fields)
  (check-equal? (session-event-type-fields step/end-type) step-fields)
  (check-equal? (session-event-type-fields user/message-type) '())
  (check-equal? (session-event-type-fields developer/message-type)
                (append step-fields '((message "message" #f) (header-seq "headerSeq" #t))))
  (check-equal? (session-event-type-fields system/message-type)
                (append step-fields '((message "message" #f))))
  (check-equal? (session-event-type-fields assistant/message-type)
                (append step-fields
                        '((message "message" #f)
                          (interrupted "interrupted" #t)
                          (usage "usage" #t)
                          (stream "stream" #f))))
  (check-equal? (session-event-type-fields assistant/attempt-type)
                (append step-fields '((stream "stream" #f))))
  (check-equal? (session-event-type-fields tool/call-type)
                (append step-fields
                        '((call-id "callId" #f) (name "name" #f) (arguments "arguments" #f))))
  (check-equal? (session-event-type-fields tool/result-type)
                (append step-fields '((message "message" #f) (error "error" #t) (meta "meta" #t))))
  (check-equal? (session-event-type-fields request/header-type)
                '((header "header" #f) (reason "reason" #f) (starts-series "startsSeries" #t)))
  (check-equal? (session-event-type-fields request/context-type)
                '((provider "provider" #f)
                  (model "model" #f)
                  (context-window "contextWindow" #t)
                  (system-prompt-update "systemPromptUpdate" #t)))
  (check-equal? (session-event-type-fields session/end-seed-type)
                '((inherited "inherited" #t))))

;; ---- constructors ----

(test-case "core events: boundary constructors"
  (check-equal? (data-text (turn/start #:turn 1)) "{\"turn\":1}")
  (check-equal? (data-text (turn/end #:reason (jobject 'kind "completed") #:turn 1))
                "{\"turn\":1,\"reason\":{\"kind\":\"completed\"}}")
  (check-equal? (data-text (step/start #:step 2 #:turn 1)) "{\"turn\":1,\"step\":2}")
  (check-equal? (data-text (step/end #:step 2 #:turn 1)) "{\"turn\":1,\"step\":2}")
  (check-equal? (session-event-input-type (turn/start #:turn 1)) "turn/start")
  (check-false (session-event-input-surface-op (turn/start #:turn 1)))
  (check-exn exn:fail:contract? (lambda () (turn/start #:turn 1.0)))
  (check-exn exn:fail:contract? (lambda () (turn/end #:turn 1 #:reason "completed"))))

(test-case "core events: assistant/message writes interrupted, usage, then stream"
  (define message (assistant-message "ok" #:id "a"))
  (define stream (list (jobject 'type "chunk" 'time 1 'chunk (jobject 'type "finish"))))
  (define input
    (assistant/message #:stream stream
                       #:usage (jobject 'inputTokens 1)
                       #:interrupted #t
                       #:message message
                       #:step 2
                       #:turn 1
                       #:surface-op 'append))
  (check-equal? (jkeys (session-event-input-data input))
                '(turn step message interrupted usage stream))
  (check-equal? (jkeys (session-event-input-data
                        (assistant/message #:turn 1 #:step 2 #:message message #:stream '()
                                           #:surface-op 'append)))
                '(turn step message stream))
  (check-eq? (assistant/message-message input) message)
  (check-equal? (assistant/message-usage input) (jobject 'inputTokens 1))
  (check-true (assistant/message-interrupted input))
  (check-equal? (assistant/message-stream input) stream)
  (check-exn exn:fail:contract?
             (lambda ()
               (assistant/message #:turn 1 #:step 2 #:message message #:stream '()
                                  #:interrupted #f #:surface-op 'append)))
  (check-exn exn:fail:contract?
             (lambda ()
               (assistant/message #:turn 1 #:step 2 #:message (user-message "x") #:stream '()
                                  #:surface-op 'append))))

(test-case "core events: tool/call and tool/result"
  (check-equal?
   (data-text (tool/call #:turn 1 #:step 1 #:call-id "c" #:name "read" #:arguments "{\"a\":1}"))
   "{\"turn\":1,\"step\":1,\"callId\":\"c\",\"name\":\"read\",\"arguments\":\"{\\\"a\\\":1}\"}")
  (define message (tool-result-message "c" "out" #:id "t" #:error? #t))
  (define input
    (tool/result #:meta #f
                 #:error (jobject 'name "ToolError" 'code "FAILED")
                 #:message message
                 #:step 1
                 #:turn 1
                 #:surface-op 'append
                 #:sources '(4)))
  (check-equal? (jkeys (session-event-input-data input)) '(turn step message error meta))
  (check-equal? (session-event-input-sources input) '(4))
  (check-false (tool/result-meta input))
  (check-true (jhas? (session-event-input-data input) 'meta))
  (check-equal? (tool/result-error input) (jobject 'name "ToolError" 'code "FAILED"))
  (check-equal? (tool/call-call-id (tool/call #:turn 1 #:step 1 #:call-id "c" #:name "n"
                                              #:arguments ""))
                "c")
  (check-exn exn:fail:contract?
             (lambda ()
               (tool/result #:turn 1 #:step 1 #:message message #:error (jobject 'name "E")
                            #:surface-op 'append))))

(test-case "core events: request/header and request/context"
  (define header
    (jobject 'config (jobject 'provider "p" 'model "m" 'maxTokens 5)
             'adapterDefaults (jobject 'maxTokens #t)
             'tools (list (tool-schema "read"))))
  (check-equal? (jkeys (session-event-input-data
                        (request/header #:starts-series #t #:reason "change" #:header header)))
                '(header reason startsSeries))
  (check-eq? (request/header-header (request/header #:header header #:reason "initial")) header)
  (for ([reason (list "initial" "resume" "change" "series")])
    (check-equal? (request/header-reason (request/header #:header header #:reason reason))
                  reason))
  (check-exn exn:fail:contract?
             (lambda () (request/header #:header header #:reason "restart")))
  (check-exn exn:fail:contract?
             (lambda () (request/header #:header header #:reason "initial" #:starts-series #f)))
  (check-exn exn:fail:contract?
             (lambda () (request/header #:header (jobject 'config (jobject 'provider "p"))
                                        #:reason "initial")))
  (check-equal? (data-text (request/context #:model "m" #:provider "p"))
                "{\"provider\":\"p\",\"model\":\"m\"}")
  (check-equal?
   (data-text (request/context #:system-prompt-update "in-history" #:context-window 128000
                               #:model "m" #:provider "p"))
   (string-append "{\"provider\":\"p\",\"model\":\"m\",\"contextWindow\":128000,"
                  "\"systemPromptUpdate\":\"in-history\"}"))
  (check-exn exn:fail:contract?
             (lambda ()
               (request/context #:provider "p" #:model "m" #:system-prompt-update "inline"))))

(test-case "core events: message events and the seed marker"
  (define user (user-message "hi" #:id "u"))
  (check-eq? (session-event-input-data (user/message user #:surface-op 'append)) user)
  (check-exn exn:fail:contract?
             (lambda () (user/message (assistant-message "x") #:surface-op 'append)))
  (define developer (developer-message (list (tool-addition-block "read")) #:id "d"))
  (check-equal? (jkeys (session-event-input-data
                        (developer/message #:header-seq 3 #:message developer #:step 1 #:turn 1
                                           #:surface-op 'append)))
                '(turn step message headerSeq))
  (check-equal? (developer/message-header-seq
                 (developer/message #:turn 1 #:step 1 #:message developer #:header-seq 3
                                    #:surface-op 'append))
                3)
  (check-false (developer/message-header-seq
                (developer/message #:turn 1 #:step 1 #:message developer #:surface-op 'append)))
  (define system (system-message "prompt" #:id "s"))
  (check-equal? (jkeys (session-event-input-data
                        (system/message #:message system #:step 1 #:turn 1
                                        #:surface-op (surface-replace 0 0) #:sources '(0))))
                '(turn step message))
  (check-equal? (data-text (assistant/attempt #:turn 1 #:step 1 #:stream '()))
                "{\"turn\":1,\"step\":1,\"stream\":[]}")
  (check-equal? (data-text (session/end-seed)) "{}")
  (check-equal? (data-text (session/end-seed #:inherited #t)) "{\"inherited\":true}")
  (check-true (session/end-seed-inherited (session/end-seed #:inherited #t)))
  (check-false (session/end-seed-inherited (session/end-seed)))
  (check-exn exn:fail:contract? (lambda () (session/end-seed #:inherited #f))))

;; ---- embedded shapes ----

(test-case "embedded shapes: turn-end-reason?"
  (for ([reason (list (jobject 'kind "completed")
                      (jobject 'kind "blocked")
                      (jobject 'kind "max-tokens")
                      (jobject 'kind "interrupted")
                      (jobject 'kind "forked")
                      (jobject 'kind "aborted" 'reason (jobject 'kind "user"))
                      (jobject 'kind "aborted" 'reason (jobject 'kind "hook" 'reason "stop"))
                      (jobject 'kind "aborted" 'reason (jobject 'kind "legacy"))
                      (jobject 'kind "error" 'error (jobject 'message "boom" 'code "UNKNOWN"))
                      (jobject 'kind "error"
                               'error (jobject 'message "m" 'code "RATE_LIMIT" 'status 429))
                      (jobject 'kind "plugin-defined" 'detail 1))])
    (check-true (turn-end-reason? reason)))
  (for ([reason (list "completed"
                      'null
                      (jobject)
                      (jobject 'kind 1)
                      (jobject 'kind "aborted")
                      (jobject 'kind "aborted" 'reason "user")
                      (jobject 'kind "error")
                      (jobject 'kind "error" 'error (jobject 'message "boom")))])
    (check-false (turn-end-reason? reason))))

(test-case "embedded shapes: epoch-header?"
  (define config (jobject 'provider "p" 'model "m"))
  (check-true (epoch-header? (jobject 'config config)))
  (check-true (epoch-header? (jobject 'config config 'extension (jobject 'nested #t))))
  (check-true (epoch-header? (jobject 'config (jset config 'reasoningEffort "high")
                                      'adapterDefaults (jobject 'reasoningEffort #t))))
  (check-true (epoch-header? (jobject 'config config 'tools (list (tool-schema "read")))))
  (check-false (epoch-header? (jobject 'config (jobject 'provider "p"))))
  (check-false (epoch-header? (jobject 'config (jobject 'provider "" 'model "m"))))
  (check-false (epoch-header? (jobject 'config (jset config 'reasoningEffort ""))))
  (check-false (epoch-header? (jobject 'config config
                                       'adapterDefaults (jobject 'maxTokens #t))))
  (check-false (epoch-header? (jobject 'config config
                                       'adapterDefaults (jobject 'temperature #t))))
  (check-false (epoch-header? (jobject 'config config 'tools "{{tools}}")))
  (check-false (epoch-header? (jobject 'config config 'tools (list (jobject 'description "")))))
  (check-false (epoch-header? 'null))
  (check-false (epoch-header? (list config))))

(test-case "embedded shapes: tool-error-identity?"
  (check-true (tool-error-identity? (jobject 'name "ToolError" 'code "FAILED")))
  (check-true (tool-error-identity? (jobject 'name "ApprovalError" 'code "X" 'reason "no")))
  (check-false (tool-error-identity? (jobject 'name "ToolError")))
  (check-false (tool-error-identity? (jobject 'name "ToolError" 'code 5)))
  (check-false (tool-error-identity? (jobject 'name "E" 'code "C" 'reason 'null)))
  (check-false (tool-error-identity? "ToolError")))

;; ---- the sample log ----

(test-case "fixtures: the sample log is built through the constructors"
  (define log (sample-log))
  (check-equal? (map session-event-seq log) (range 11))
  (check-equal? (map session-event-type log)
                '("turn/start" "step/start" "system/message" "user/message" "request/header"
                  "request/context" "assistant/message" "tool/call" "tool/result" "step/end"
                  "turn/end"))
  (for ([event (in-list log)])
    (define declaration
      (findf (lambda (type) (equal? (session-event-type-tag type) (session-event-type event)))
             core-session-event-types))
    (check-false (session-event-type-violation declaration (session-event-data event)))))

;; ---- the key-order fixture ----
;; A normalised dsh recording: the first line is the header and the event lines carry no seq
;; and no time. Rebuilding each line through this package must give the line back.

(define fixture-path
  (repository-file "snapshots" "session" "fs-read" "session.v4.jsonl"))

;; The recording replaces the tool list by a token; a real list stands in for it here.
(define tools-token "\"{{tools}}\"")
(define tools-text
  "[{\"name\":\"read\",\"description\":\"Read a file.\",\"parameters\":{\"type\":\"object\"}}]")

(define constructors
  (hash "turn/start" turn/start
        "turn/end" turn/end
        "step/start" step/start
        "step/end" step/end
        "user/message" user/message
        "developer/message" developer/message
        "system/message" system/message
        "assistant/message" assistant/message
        "assistant/attempt" assistant/attempt
        "tool/call" tool/call
        "tool/result" tool/result
        "request/header" request/header
        "request/context" request/context
        "session/end-seed" session/end-seed))

(define (declaration-of type)
  (findf (lambda (declaration) (equal? (session-event-type-tag declaration) type))
         core-session-event-types))

;; Calls the generated constructor of a core type with the fields of `data`.
(define (rebuild-through-constructor type data op sources)
  (define declaration (declaration-of type))
  (define constructor (hash-ref constructors type))
  (define surface-arguments
    (append (if op (list (cons '#:surface-op op)) '())
            (if sources (list (cons '#:sources sources)) '())))
  (define field-arguments
    (for/list ([spec (in-list (session-event-type-fields declaration))]
               #:when (jhas? data (cadr spec)))
      (cons (string->keyword (symbol->string (car spec))) (jref data (cadr spec)))))
  (define arguments
    (sort (append surface-arguments
                  (if (null? (session-event-type-fields declaration)) '() field-arguments))
          keyword<?
          #:key car))
  (keyword-apply constructor
                 (map car arguments)
                 (map cdr arguments)
                 (if (null? (session-event-type-fields declaration)) (list data) '())))

(define (without-position event)
  (jvalue->string (jremove (jremove (session-event->jvalue event) 'seq) 'time)))

(test-case "key-order fixture: every recorded event line is rebuilt byte for byte"
  (cond
    [(not fixture-path)
     (displayln "key-order fixture skipped: snapshots/session/fs-read/session.v4.jsonl not found"
                (current-error-port))]
    [else
     (define lines
       (filter (lambda (line) (not (string=? line "")))
               (call-with-input-file fixture-path port->lines)))
     (check-true (> (length lines) 10))
     (check-equal? (jref (string->jvalue (car lines)) 'type) "session")
     (define core-lines 0)
     (for ([recorded (in-list (cdr lines))] [index (in-naturals)])
       (define line (string-replace recorded tools-token tools-text))
       (define row (string->jvalue line))
       (define type (jref row 'type))
       (define data (jref row 'data))
       (define parsed (jvalue->session-event (jset (jset row 'seq index) 'time 0)))
       (define op (session-event-surface-op parsed))
       (define sources (session-event-source-seqs parsed))
       (check-equal? (not op) (not (jhas? row 'surfaceOp)) line)
       (check-equal? (not sources) (not (jhas? row 'sourceEventSeqs)) line)
       (define rebuilt
         (make-session-event type index 0 data
                             #:sources (or sources absent)
                             #:surface-op (or op absent)))
       (check-equal? (without-position rebuilt) line)
       (when (declaration-of type)
         (set! core-lines (add1 core-lines))
         (define input (rebuild-through-constructor type data op sources))
         (define through-constructor
           (make-session-event type index 0 (session-event-input-data input)
                               #:sources (or (session-event-input-sources input) absent)
                               #:surface-op (or (session-event-input-surface-op input) absent)))
         (check-equal? (without-position through-constructor) line)))
     ;; The recording holds a tool call turn, so every kind of core line is exercised.
     (check-true (>= core-lines 14))]))
