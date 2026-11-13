#lang racket/base
;; Tests of derived history in `dsh-session/surface`: rules 22 and 23 of the dsh-session
;; contract as pure functions. An incremental derivation that extends by the new nodes and
;; rebuilds when the content generation changes (the algorithm of the session cache) must
;; equal `derive-messages` over the same log, and events that are not messages must never
;; change history.
;; Mirrors packages/core/session/tests/derived-cache.spec.ts and properties.spec.ts. The last
;; test compares the cache of the session object itself and is skipped while the module
;; `dsh-session/session` of the other work unit is not present.

(require rackunit
         racket/list
         cordis-data
         dsh-session/types
         dsh-session/events
         dsh-session/surface
         "support/log.rkt")

;; ---- fixtures ----

(define (user-input text)
  (user/message (user-message text) #:surface-op 'append))

(define (assistant-input content #:usage [usage absent] #:step [step 1])
  (assistant/message #:turn 1 #:step step
                     #:message (assistant-message content)
                     #:usage usage
                     #:stream '()
                     #:surface-op 'append))

(define (tool-input call-id content #:error? [error? #f])
  (tool/result #:turn 1 #:step 1
               #:message (tool-result-message call-id content #:error? error?)
               #:surface-op 'append))

(define (event-of input [seq 0])
  (car (inputs->events (list input) #:from seq)))

;; The derivation the session cache performs: project only the nodes added since the last
;; read, and start over when the content generation changed. Returns the history after each
;; event of the log.
(define (incremental-histories events #:projections [projections '()])
  (define log (list->vector events))
  (define (event-ref seq)
    (and (< seq (vector-length log)) (vector-ref log seq)))
  (define-values (st derived derived-nodes generation rev-histories)
    (for/fold ([st (surface-state-empty)]
               [derived '()]
               [derived-nodes 0]
               [generation 0]
               [rev-histories '()])
              ([e (in-list events)])
      (define next (surface-step st e event-ref projections))
      (define rebuilt? (not (= (surface-state-content-generation next) generation)))
      (define base (if rebuilt? '() derived))
      (define start (if rebuilt? 0 derived-nodes))
      (define added
        (for*/list ([seq (in-list (surface-state-nodes-from next start))]
                    [message (in-value
                              (derive-event-message
                               (event-ref seq) (surface-state-projected-messages next)))]
                    #:when message)
          message))
      (define history (append base added))
      (values next
              history
              (surface-state-node-count next)
              (surface-state-content-generation next)
              (cons history rev-histories))))
  (reverse rev-histories))

;; Requires each message of `actual` to be the very object in `expected`.
(define (check-same-messages actual expected)
  (check-equal? (length actual) (length expected))
  (for ([a (in-list actual)] [b (in-list expected)])
    (check-eq? a b)))

;; ---- rule 22: derive-event-message ----

(test-case "rule 22: user/message gives its data"
  (define event (event-of (user-input "hi")))
  (check-eq? (derive-event-message event) (session-event-data event))
  (check-eq? (jref (derive-event-message event) 'content)
             (jref (session-event-data event) 'content)))

(test-case "rule 22: system, developer and assistant events give their message"
  (define system
    (event-of (system/message #:turn 1 #:step 1 #:message (system-message "be brief")
                              #:surface-op 'append)))
  (check-eq? (derive-event-message system) (system/message-message system))
  (define developer
    (event-of (developer/message #:turn 1 #:step 1
                                 #:message (developer-message (list (tool-removal-block "x")))
                                 #:surface-op 'append)))
  (check-eq? (derive-event-message developer) (developer/message-message developer))
  (define assistant (event-of (assistant-input "reply")))
  (check-eq? (derive-event-message assistant) (assistant/message-message assistant)))

(test-case "rule 22: an empty system, developer or assistant message gives #f"
  (check-false
   (derive-event-message
    (event-of (system/message #:turn 1 #:step 1 #:message (system-message "")
                              #:surface-op 'append))))
  (check-false
   (derive-event-message
    (event-of (developer/message #:turn 1 #:step 1 #:message (developer-message '())
                                 #:surface-op 'append))))
  (check-false
   (derive-event-message
    (event-of (assistant-input '() #:usage (jobject 'inputTokens 1 'outputTokens 0))))))

(test-case "rule 22: tool/result gives its message, even when the content is empty"
  (define result (event-of (tool-input "call" "out")))
  (check-eq? (derive-event-message result) (tool/result-message result))
  (define empty (event-of (tool-input "call" '())))
  (check-eq? (derive-event-message empty) (tool/result-message empty)))

(test-case "rule 22: an empty user message still gives its data"
  (define event (event-of (user-input '())))
  (check-eq? (derive-event-message event) (session-event-data event)))

(test-case "rule 22: every other type gives #f"
  (for ([input (list (turn/start #:turn 1)
                     (step/start #:turn 1 #:step 1)
                     (step/end #:turn 1 #:step 1)
                     (turn/end #:turn 1 #:reason (jobject 'kind "completed"))
                     (assistant/attempt #:turn 1 #:step 1 #:stream '())
                     (tool/call #:turn 1 #:step 1 #:call-id "c" #:name "n" #:arguments "{}")
                     (request/context #:provider "p" #:model "m")
                     (session/end-seed))])
    (check-false (derive-event-message (event-of input))))
  (check-false (derive-event-message (raw-event "plugin:x/y" 0 (jobject 'message "no"))))
  (check-false (derive-event-message (raw-event "custom/event" 0 (user-message "no")))))

(test-case "rule 22: a projected message for the event's seq wins"
  (define event (event-of (user-input "original") 4))
  (define replacement (user-message "projected"))
  (check-eq? (derive-event-message event (hasheqv 4 replacement)) replacement)
  (check-eq? (derive-event-message event (hasheqv 5 replacement)) (session-event-data event))
  (check-eq? (derive-event-message event #f) (session-event-data event))
  ;; A projection can give a message to an event that derives none on its own.
  (define boundary (event-of (turn/start #:turn 1) 4))
  (check-eq? (derive-event-message boundary (hasheqv 4 replacement)) replacement))

;; ---- rule 23: derive-messages ----

(test-case "rule 23: history follows the surface, not the log"
  (define events
    (inputs->events
     (list (turn/start #:turn 1)
           (user-input "hello")
           (assistant/attempt #:turn 1 #:step 1 #:stream '())
           (assistant-input "hi")
           (turn/end #:turn 1 #:reason (jobject 'kind "completed")))))
  (define messages (derive-messages events))
  (check-equal? (map (lambda (message) (jref message 'role)) messages) '("user" "assistant"))
  (check-same-messages messages
                       (list (session-event-data (list-ref events 1))
                             (assistant/message-message (list-ref events 3)))))

(test-case "rule 23: the sample log derives system, user, assistant and tool messages"
  (define log (sample-log))
  (define messages (derive-messages log))
  (check-equal? (map (lambda (message) (jref message 'role)) messages)
                '("system" "user" "assistant" "tool"))
  (check-equal? (map (lambda (message) (jref message 'id)) messages)
                '("system-1" "user-1" "assistant-1" "tool-1")))

(test-case "rule 23: the messages are the logged objects and each call returns a fresh list"
  (define log (sample-log))
  (define first-read (derive-messages log))
  (define second-read (derive-messages log))
  (check-not-eq? first-read second-read)
  (check-same-messages first-read second-read)
  (check-eq? (car first-read) (system/message-message (list-ref log 2)))
  (check-eq? (cadr first-read) (session-event-data (list-ref log 3))))

(test-case "rule 23: a surface node that derives no message is skipped"
  (define events
    (inputs->events
     (list (user-input "one")
           (assistant-input '() #:usage (jobject 'inputTokens 1 'outputTokens 0))
           (user-input "two"))))
  (check-equal? (surface-fold-result-nodes (fold-surface events)) '(0 1 2))
  (check-equal? (map (lambda (message) (jref* message '(content 0 text)))
                     (derive-messages events))
                '("one" "two")))

(test-case "rule 23: a replacement takes the position of the range it shadowed"
  (define events
    (inputs->events
     (list (turn/start #:turn 1)
           (user-input "one")
           (user-input "two")
           (user-input "three")
           (user/message (user-message "summary"
                                       #:source (jobject 'kind "compact-checkpoint"
                                                         'compactionId "c1"))
                         #:surface-op (surface-replace 1 2)
                         #:sources '(1 2)))))
  (check-equal? (map (lambda (message) (jref* message '(content 0 text)))
                     (derive-messages events))
                '("summary" "three"))
  (check-equal? (length (derive-messages (take events 4))) 3))

(test-case "rule 23: an empty system head projects no message and keeps its node"
  (define events
    (inputs->events
     (list (system/message #:turn 1 #:step 1 #:message (system-message "be brief")
                           #:surface-op 'append)
           (user-input "hi")
           (system/message #:turn 1 #:step 1 #:message (system-message "")
                           #:surface-op (surface-replace 0 0)
                           #:sources '(0)))))
  (check-equal? (map (lambda (message) (jref message 'role)) (derive-messages (take events 2)))
                '("system" "user"))
  (check-equal? (map (lambda (message) (jref message 'role)) (derive-messages events))
                '("user"))
  (check-equal? (length (surface-fold-result-nodes (fold-surface events))) 2))

(test-case "rule 23: projections change content in place"
  (define projection
    (message-projection
     "test/project"
     (lambda (event context)
       (define target (jref (session-event-data event) 'seq))
       (define source ((projection-context-event-ref context) target))
       (define original (derive-event-message source (projection-context-messages context)))
       (hasheqv target (jset original 'content (list (text-block "projected")))))))
  (define events
    (append (inputs->events (list (user-input "one") (user-input "two")))
            (list (raw-event "test/project" 2 (jobject 'seq 0)))))
  (define messages (derive-messages events #:projections (list projection)))
  (check-equal? (map (lambda (message) (jref* message '(content 0 text))) messages)
                '("projected" "two"))
  (check-eq? (cadr messages) (session-event-data (cadr events)))
  (check-equal? (jref (car messages) 'id) (jref (session-event-data (car events)) 'id)))

;; ---- generated logs ----

(define (random-text)
  (list->string (for/list ([i (in-range (random 6))])
                  (integer->char (+ 97 (random 26))))))

(define (random-content)
  (for/list ([i (in-range (random 4))]) (text-block (random-text))))

;; An event that produces a message, or would if its content were not empty.
(define (random-message-input)
  (case (random 4)
    [(0) (user-input (random-content))]
    [(1) (assistant-input (random-content))]
    [(2) (assistant-input (random-content) #:usage (jobject 'inputTokens 1 'outputTokens 1))]
    [else (tool-input (format "call-~a" (random 1000)) (random-content)
                      #:error? (zero? (random 2)))]))

;; An event that is trace data and must not affect history.
(define (random-noise-input)
  (case (random 5)
    [(0) (turn/start #:turn 1)]
    [(1) (turn/end #:turn 1 #:reason (jobject 'kind "completed"))]
    [(2) (step/start #:turn 1 #:step 1)]
    [(3) (step/end #:turn 1 #:step 1)]
    [else (assistant/attempt
           #:turn 1 #:step 1
           #:stream (list (jobject 'type "text-chunks" 'time0 1 'index 0 'dt '()
                                   'texts (list (random-text)))))]))

(define (random-inputs count make)
  (for/list ([i (in-range count)]) (make)))

;; A random merge that keeps the relative order inside each list.
(define (interleave a b)
  (cond
    [(null? a) b]
    [(null? b) a]
    [(zero? (random 2)) (cons (car a) (interleave (cdr a) b))]
    [else (cons (car b) (interleave a (cdr b)))]))

(define-syntax-rule (with-seed seed body ...)
  (parameterize ([current-pseudo-random-generator (make-pseudo-random-generator)])
    (random-seed seed)
    body ...))

(test-case "rule 23: derivation is deterministic and seqs are contiguous"
  (with-seed 11
    (for ([trial (in-range 40)])
      (define inputs
        (interleave (random-inputs (random 13) random-message-input)
                    (random-inputs (random 13) random-noise-input)))
      (define events (inputs->events inputs))
      (check-equal? (map session-event-seq events) (range (length events)))
      (check-same-messages (derive-messages events) (derive-messages events))
      (for ([message (in-list (derive-messages events))])
        (check-true (and (member (jref message 'role) '("user" "assistant" "system" "tool"))
                         #t))))))

(test-case "rule 23: non-message events never change history, in any interleaving"
  (with-seed 23
    (for ([trial (in-range 60)])
      (define messages (random-inputs (random 13) random-message-input))
      (define noise (random-inputs (random 13) random-noise-input))
      (define clean (derive-messages (inputs->events messages)))
      (define with-noise (derive-messages (inputs->events (interleave messages noise))))
      (check-same-messages with-noise clean))))

(test-case "rule 23: the incremental derivation equals derive-messages as a log grows"
  (with-seed 37
    (for ([trial (in-range 40)])
      (define inputs
        (interleave (random-inputs (+ 1 (random 12)) random-message-input)
                    (random-inputs (random 8) random-noise-input)))
      (define events (inputs->events inputs))
      (for ([history (in-list (incremental-histories events))] [count (in-naturals 1)])
        (check-same-messages history (derive-messages (take events count)))))))

(test-case "rule 23: the incremental derivation rebuilds on a replacement"
  (with-seed 41
    (for ([trial (in-range 40)])
      ;; Appended user messages with an occasional replacement of a random node range.
      (define-values (rev-inputs nodes)
        (for/fold ([rev-inputs '()] [nodes '()]) ([seq (in-range (+ 4 (random 20)))])
          (cond
            [(and (pair? nodes) (zero? (random 4)))
             (define start (random (length nodes)))
             (define end (+ start (random (- (length nodes) start))))
             (define shadowed (take (drop nodes start) (add1 (- end start))))
             (values (cons (user/message (user-message (format "summary ~a" seq))
                                         #:surface-op (surface-replace (first shadowed)
                                                                       (last shadowed))
                                         #:sources shadowed)
                           rev-inputs)
                     (append (take nodes start) (list seq) (drop nodes (add1 end))))]
            [else
             (values (cons (user-input (format "text ~a" seq)) rev-inputs)
                     (append nodes (list seq)))])))
      (define events (inputs->events (reverse rev-inputs)))
      (check-equal? (surface-fold-result-nodes (fold-surface events)) nodes)
      (for ([history (in-list (incremental-histories events))] [count (in-naturals 1)])
        (check-same-messages history (derive-messages (take events count)))))))

;; ---- the session object's cache (other work unit) ----

(define (optional-export module-path name)
  ;; exn:fail: the module or the binding does not exist yet; the caller reports the skip.
  (with-handlers ([exn:fail? (lambda (e) #f)])
    (dynamic-require module-path name)))

(test-case "rule 23: the session cache equals derive-messages over the same log"
  (define make-session (optional-export 'dsh-session/session 'make-session))
  (define session-append! (optional-export 'dsh-session/session 'session-append!))
  (define session-derive-messages
    (optional-export 'dsh-session/session 'session-derive-messages))
  (define session-events (optional-export 'dsh-session/session 'session-events))
  (cond
    [(not (and make-session session-append! session-derive-messages session-events))
     (displayln
      (string-append "session cache comparison skipped: dsh-session/session does not provide "
                     "make-session, session-append!, session-derive-messages and "
                     "session-events yet")
      (current-error-port))]
    [else
     (with-seed 53
       (for ([trial (in-range 20)])
         (define session (make-session (format "derived-cache-~a" trial)))
         (for ([input (in-list (interleave (random-inputs (+ 1 (random 12)) random-message-input)
                                           (random-inputs (random 8) random-noise-input)))])
           (session-append! session input)
           (check-same-messages (session-derive-messages session)
                                (derive-messages (session-events session))))))]))
