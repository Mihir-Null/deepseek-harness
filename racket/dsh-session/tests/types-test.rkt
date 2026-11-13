#lang racket/base
;; Tests of `dsh-session/types`: scalar contracts, the session header (rule 3), the event
;; envelope (rule 2), the key order of written events, plugin records, the message predicates
;; and `define-session-event`.
;; Mirrors packages/core/session/tests/sequence-types.spec.ts and the envelope parts of
;; canonical-envelopes.spec.ts.

(require rackunit
         racket/match
         (only-in racket/contract/base or/c)
         syntax/macro-testing
         cordis-data
         dsh-session/types
         "support/log.rkt")

;; ---- scalars and the absent marker ----

(test-case "scalars: non-negative safe integers are admitted as seqs and offsets"
  (check-equal? (->session-seq 3) 3)
  (check-equal? (->session-log-offset 4) 4)
  (check-equal? (->session-seq 0) 0)
  (check-equal? (->session-seq max-safe-integer) max-safe-integer)
  (check-equal? max-safe-integer 9007199254740991)
  (check-equal? session-format-version 4))

(test-case "scalars: an integral flonum is admitted and returned exact"
  (check-equal? (->session-seq 3.0) 3)
  (check-true (exact? (->session-seq 3.0)))
  (check-equal? (->session-log-offset 0.0) 0)
  (check-true (exact? (->session-log-offset 7.0))))

(test-case "scalars: invalid positions are rejected with the dsh TypeError text"
  (for ([value (list -1 -0.0 0.5 (add1 max-safe-integer) +nan.0)]
        [shown (list "-1" "0" "0.5" "9007199254740992" "NaN")])
    (check-exn (contract-error
                (format "SessionSeq must be a non-negative safe integer, got ~a" shown))
               (lambda () (->session-seq value)))
    (check-exn (contract-error
                (format "SessionLogOffset must be a non-negative safe integer, got ~a" shown))
               (lambda () (->session-log-offset value))))
  (check-exn (contract-error #rx"^SessionSeq must be a non-negative safe integer, got ")
             (lambda () (->session-seq "3"))))

(test-case "scalars: the predicates"
  (check-true (safe-integer? 0))
  (check-true (safe-integer? -5))
  (check-true (safe-integer? 2.0))
  (check-true (safe-integer? max-safe-integer))
  (check-true (safe-integer? (- max-safe-integer)))
  (check-false (safe-integer? -0.0))
  (check-false (safe-integer? 0.5))
  (check-false (safe-integer? (add1 max-safe-integer)))
  (check-false (safe-integer? +inf.0))
  (check-false (safe-integer? +nan.0))
  (check-false (safe-integer? "1"))
  (check-true (session-seq? 0))
  (check-true (session-seq? max-safe-integer))
  (check-false (session-seq? -1))
  (check-false (session-seq? 1.0))
  (check-false (session-seq? (add1 max-safe-integer)))
  (check-true (session-log-offset? 12))
  (check-false (session-log-offset? 1.0))
  (check-true (session-id? "session-1"))
  (check-false (session-id? 'session-1)))

(test-case "absent: one value, distinct from #f and null"
  (check-true (absent? absent))
  (check-false (absent? #f))
  (check-false (absent? 'null))
  (check-false (absent? (void)))
  (check-equal? (format "~a" absent) "#<absent>"))

;; ---- session header (rule 3) ----

(test-case "rule 3: a built header writes the dsh keys in the dsh order"
  (check-equal?
   (jvalue->string (session-header->jvalue (make-session-header #:id "s1" #:created-at 12)))
   "{\"version\":4,\"id\":\"s1\",\"createdAt\":12,\"isSeeded\":false}")
  (define full
    (make-session-header #:id "s2"
                         #:created-at 5
                         #:seeded? #t
                         #:cwd "/work"
                         #:parent-session "s1"
                         #:origin "subagent"
                         #:delegation-depth 2
                         #:agent-preset "reviewer"))
  (check-equal?
   (jvalue->string (session-header->jvalue full))
   (string-append "{\"version\":4,\"id\":\"s2\",\"createdAt\":5,\"cwd\":\"/work\","
                  "\"parentSession\":\"s1\",\"isSeeded\":true,\"origin\":\"subagent\","
                  "\"delegationDepth\":2,\"agentPreset\":\"reviewer\"}"))
  (check-equal? (session-header-version full) 4)
  (check-equal? (session-header-id full) "s2")
  (check-equal? (session-header-created-at full) 5)
  (check-equal? (session-header-cwd full) "/work")
  (check-equal? (session-header-parent-session full) "s1")
  (check-true (session-header-seeded? full))
  (check-equal? (session-header-origin full) "subagent")
  (check-equal? (session-header-delegation-depth full) 2)
  (check-equal? (session-header-agent-preset full) "reviewer"))

(test-case "rule 3: accessors of absent optional fields return #f"
  (define header (make-session-header #:id "s1" #:created-at 0))
  (check-false (session-header-cwd header))
  (check-false (session-header-parent-session header))
  (check-false (session-header-seeded? header))
  (check-false (session-header-origin header))
  (check-false (session-header-delegation-depth header))
  (check-false (session-header-agent-preset header)))

(test-case "rule 3: a header read from JSON keeps unknown keys and its key order"
  (define text
    (string-append "{\"id\":\"s1\",\"future\":{\"nested\":[1,null]},\"isSeeded\":false,"
                   "\"version\":4,\"createdAt\":7}"))
  (define header (jvalue->session-header "s1" (string->jvalue text)))
  (check-true (session-header? header))
  (check-equal? (jvalue->string (session-header->jvalue header)) text)
  (check-equal? (session-header-created-at header) 7)
  (check-equal? header (jvalue->session-header "s1" (string->jvalue text)))
  (check-not-equal? header (make-session-header #:id "s1" #:created-at 7)))

(test-case "rule 3: a hash is accepted as the header object"
  (define header
    (jvalue->session-header "s1" (hash 'version 4 'id "s1" 'createdAt 1 'isSeeded #f)))
  (check-true (jobject? (session-header->jvalue header)))
  (check-equal? (session-header-id header) "s1"))

;; A valid header of session "s1" with the given keys set.
(define (header-with . key-values)
  (let loop ([header (jobject 'version 4 'id "s1" 'createdAt 1 'isSeeded #f)]
             [rest key-values])
    (if (null? rest)
        header
        (loop (jset header (car rest) (cadr rest)) (cddr rest)))))

(test-case "rule 3: every rejection has the dsh message"
  (define (rejected jv)
    (lambda () (jvalue->session-header "s1" jv)))
  (for ([jv (list 'null '() 1 "invalid" #f (list 1 2))])
    (check-exn (session-error "session header is not a plain JSON record") (rejected jv)))
  (check-exn (session-error "session header has invalid field \"seedLength\"")
             (rejected (header-with 'seedLength 3)))
  (check-exn (session-error "session header version must be 4, got 3")
             (rejected (header-with 'version 3)))
  (check-exn (session-error "session header version must be 4, got undefined")
             (rejected (jremove (header-with) 'version)))
  (check-exn (session-error "session header version must be 4, got 4")
             (rejected (header-with 'version "4")))
  (check-exn (session-error "session header id \"other\" does not match session id \"s1\"")
             (rejected (header-with 'id "other")))
  (check-exn (session-error "session header id \"undefined\" does not match session id \"s1\"")
             (rejected (jremove (header-with) 'id)))
  (for ([created-at (list -1 0.5 "1" 'null (add1 max-safe-integer))])
    (check-exn (session-error "session header createdAt must be a non-negative safe integer")
               (rejected (header-with 'createdAt created-at))))
  (check-exn (session-error "session header createdAt must be a non-negative safe integer")
             (rejected (jremove (header-with) 'createdAt)))
  (check-exn (session-error "session header cwd must be a string")
             (rejected (header-with 'cwd 5)))
  (check-exn (session-error "session header cwd must be a string")
             (rejected (header-with 'cwd 'null)))
  (check-exn (session-error "session header cwd must be an absolute path, got \"relative/dir\"")
             (rejected (header-with 'cwd "relative/dir")))
  (check-exn (session-error "session header cwd must be an absolute path, got \"\"")
             (rejected (header-with 'cwd "")))
  (check-exn (session-error "session header parentSession must be a string")
             (rejected (header-with 'parentSession 1)))
  (check-exn (session-error "session header isSeeded must be a boolean")
             (rejected (header-with 'isSeeded "false")))
  (check-exn (session-error "session header isSeeded must be a boolean")
             (rejected (jremove (header-with) 'isSeeded)))
  (check-exn (session-error "session header origin must be \"subagent\"")
             (rejected (header-with 'origin "fork")))
  (for ([depth (list -1 1.5 "1")])
    (check-exn
     (session-error "session header delegationDepth must be a non-negative safe integer")
     (rejected (header-with 'delegationDepth depth))))
  (check-exn (session-error "session header agentPreset must be a string")
             (rejected (header-with 'agentPreset #t))))

(test-case "rule 3: the checks run in the dsh order"
  (check-exn (session-error "session header has invalid field \"seedLength\"")
             (lambda ()
               (jvalue->session-header "s1" (jobject 'seedLength 1 'version 3 'id "x"))))
  (check-exn (session-error "session header version must be 4, got 3")
             (lambda () (jvalue->session-header "s1" (jobject 'version 3 'id "x"))))
  (check-exn (session-error "session header id \"x\" does not match session id \"s1\"")
             (lambda () (jvalue->session-header "s1" (jobject 'version 4 'id "x")))))

(test-case "rule 3: a header that is not lossless JSON is rejected"
  (for ([jv (list (header-with 'createdAt -0.0)
                  (header-with 'extra (list +nan.0))
                  (header-with 'extra 'symbol)
                  (vector 1))])
    (check-exn (session-error "session header is not losslessly JSON-serializable")
               (lambda () (jvalue->session-header "s1" jv)))))

(test-case "rule 3: make-session-header validates what it builds"
  (check-exn (session-error "session header cwd must be an absolute path, got \"rel\"")
             (lambda () (make-session-header #:id "s1" #:created-at 1 #:cwd "rel")))
  (check-exn (session-error "session header createdAt must be a non-negative safe integer")
             (lambda () (make-session-header #:id "s1" #:created-at -1)))
  (check-exn (session-error "session header origin must be \"subagent\"")
             (lambda () (make-session-header #:id "s1" #:created-at 1 #:origin "other")))
  (check-exn (session-error "session header isSeeded must be a boolean")
             (lambda () (make-session-header #:id "s1" #:created-at 1 #:seeded? 'null)))
  (check-exn (session-error "session header is not losslessly JSON-serializable")
             (lambda () (make-session-header #:id "s1" #:created-at 1 #:cwd (void)))))

;; ---- event envelope (rule 2) ----

(define (envelope . key-values)
  (apply jobject key-values))

(test-case "rule 2: a valid envelope is read and keeps its JSON form"
  (define text
    (string-append "{\"data\":{\"turn\":1},\"time\":1700000000000,\"seq\":0,"
                   "\"type\":\"turn/start\"}"))
  (define event (jvalue->session-event (string->jvalue text)))
  (check-true (session-event? event))
  (check-equal? (session-event-type event) "turn/start")
  (check-equal? (session-event-seq event) 0)
  (check-equal? (session-event-time event) 1700000000000)
  (check-equal? (session-event-data event) (jobject 'turn 1))
  (check-false (session-event-surface-op event))
  (check-false (session-event-source-seqs event))
  (check-false (session-event-ignorable? event))
  (check-equal? (jvalue->string (session-event->jvalue event)) text))

(test-case "rule 2: an integral flonum seq or time is read as an exact integer"
  (define event (jvalue->session-event (string->jvalue
                                        "{\"type\":\"x\",\"seq\":2.0,\"time\":5.0,\"data\":null}")))
  (check-equal? (session-event-seq event) 2)
  (check-true (exact? (session-event-seq event)))
  (check-equal? (session-event-time event) 5)
  (check-true (exact? (session-event-time event)))
  (check-eq? (session-event-data event) 'null))

(test-case "rule 2: a negative time is a valid time"
  (check-equal? (session-event-time
                 (jvalue->session-event (envelope 'type "x" 'seq 0 'time -5 'data 1)))
                -5))

(test-case "rule 2: a hash envelope is accepted"
  (define event (jvalue->session-event (hash 'type "turn/start" 'seq 0 'time 1 'data 'null)))
  (check-equal? (session-event-type event) "turn/start")
  (check-true (jobject? (session-event->jvalue event))))

(test-case "rule 2: malformed envelopes are rejected with the subject in the message"
  (define message "session event has an invalid event envelope")
  (define (rejected jv)
    (lambda () (jvalue->session-event jv)))
  (for ([jv (list 'null '() 1 "invalid" #t (list 1))])
    (check-exn (session-error message) (rejected jv)))
  (define valid (envelope 'type "turn/start" 'seq 0 'time 1 'data (jobject 'turn 1)))
  (check-not-exn (rejected valid))
  (for ([jv (list (jset valid 'extra 1)
                  (jset valid 'surface 'null)
                  (jset valid 'type 5)
                  (jset valid 'type 'null)
                  (jremove valid 'type)
                  (jset valid 'seq -1)
                  (jset valid 'seq -0.0)
                  (jset valid 'seq 0.5)
                  (jset valid 'seq "0")
                  (jset valid 'seq (add1 max-safe-integer))
                  (jremove valid 'seq)
                  (jset valid 'time 0.5)
                  (jset valid 'time "1")
                  (jset valid 'time (add1 max-safe-integer))
                  (jremove valid 'time)
                  (jremove valid 'data)
                  (jset valid 'ignorable #f)
                  (jset valid 'ignorable "true")
                  (jset valid 'ignorable 'null))])
    (check-exn (session-error message) (rejected jv))))

(test-case "rule 2: the subject of the error is the caller's"
  (check-exn (session-error "seed event at index 3 has an invalid event envelope")
             (lambda ()
               (jvalue->session-event (envelope 'type "turn/start" 'seq -0.0 'time 1 'data 1)
                                      #:subject "seed event at index 3"))))

(test-case "rule 2: the envelope check does not interpret surface metadata"
  (define event
    (jvalue->session-event
     (envelope 'type "user/message" 'seq 4 'time 1 'data (jobject 'anything #t)
               'surfaceOp (jobject 'opaque (list "not" "placement"))
               'sourceEventSeqs (jobject 'opaque (list 'null #t))
               'ignorable #t)))
  (check-false (session-event-surface-op event))
  (check-false (session-event-source-seqs event))
  (check-true (session-event-ignorable? event))
  (check-equal? (jref (session-event->jvalue event) 'surfaceOp)
                (jobject 'opaque (list "not" "placement"))))

(test-case "rule 2: the metadata accessors parse valid stored values"
  (define appended
    (jvalue->session-event
     (envelope 'type "user/message" 'seq 4 'time 1 'data (jobject)
               'sourceEventSeqs (list 1 2.0 3) 'surfaceOp "append")))
  (check-eq? (session-event-surface-op appended) 'append)
  (check-equal? (session-event-source-seqs appended) '(1 2 3))
  (define replaced
    (jvalue->session-event
     (envelope 'type "tool/result" 'seq 9 'time 1 'data (jobject)
               'surfaceOp (jobject 'endSeq 7 'op "replace" 'startSeq 5.0))))
  (check-equal? (session-event-surface-op replaced) (surface-replace 5 7))
  (check-false (session-event-source-seqs replaced))
  ;; A log-only type has no surface operation, whatever it stores.
  (define log-only
    (jvalue->session-event
     (envelope 'type "turn/start" 'seq 0 'time 1 'data (jobject) 'surfaceOp "append"
               'sourceEventSeqs (list 0))))
  (check-false (session-event-surface-op log-only))
  (check-equal? (session-event-source-seqs log-only) '(0))
  (for ([raw (list (jobject 'op "replace" 'startSeq 0 'endSeq 0 'extra #t)
                   (jobject 'op "replace" 'start 0 'end 0)
                   (jobject 'op "replace" 'startSeq -1 'endSeq 0)
                   (jobject 'op "replace" 'startSeq -0.0 'endSeq 0)
                   (jobject 'op "swap" 'startSeq 0 'endSeq 0)
                   "replace"
                   'null)])
    (check-false
     (session-event-surface-op
      (jvalue->session-event
       (envelope 'type "user/message" 'seq 4 'time 1 'data (jobject) 'surfaceOp raw)))))
  (for ([raw (list "invalid" (list 0.5) (list -1) (list "0") 'null)])
    (check-false
     (session-event-source-seqs
      (jvalue->session-event
       (envelope 'type "user/message" 'seq 4 'time 1 'data (jobject) 'surfaceOp "append"
                 'sourceEventSeqs raw))))))

;; ---- key order of written events ----

(define (written event)
  (jvalue->string (session-event->jvalue event)))

(test-case "key order: a live append writes type, seq, time, data, sourceEventSeqs, surfaceOp"
  (check-equal? (written (make-session-event "turn/start" 0 10 (jobject 'turn 1)))
                "{\"type\":\"turn/start\",\"seq\":0,\"time\":10,\"data\":{\"turn\":1}}")
  (check-equal?
   (written (make-session-event "user/message" 3 10 (jobject 'id "m")
                                #:surface-op 'append
                                #:sources '(1 2)))
   (string-append "{\"type\":\"user/message\",\"seq\":3,\"time\":10,\"data\":{\"id\":\"m\"},"
                  "\"sourceEventSeqs\":[1,2],\"surfaceOp\":\"append\"}"))
  (check-equal?
   (written (make-session-event "user/message" 3 10 (jobject 'id "m")
                                #:surface-op (surface-replace 1 2)
                                #:sources '(1 2)))
   (string-append "{\"type\":\"user/message\",\"seq\":3,\"time\":10,\"data\":{\"id\":\"m\"},"
                  "\"sourceEventSeqs\":[1,2],"
                  "\"surfaceOp\":{\"op\":\"replace\",\"startSeq\":1,\"endSeq\":2}}")))

(test-case "key order: a synthetic recovery result writes surfaceOp before sourceEventSeqs"
  (check-equal?
   (written (make-session-event "tool/result" 3 10 (jobject 'turn 1)
                                #:surface-op 'append
                                #:sources '(2)
                                #:metadata-order 'op-first))
   (string-append "{\"type\":\"tool/result\",\"seq\":3,\"time\":10,\"data\":{\"turn\":1},"
                  "\"surfaceOp\":\"append\",\"sourceEventSeqs\":[2]}")))

(test-case "key order: a plugin record writes type, seq, time, data, ignorable"
  (define event
    (make-session-event "plugin:owner/record" 5 10 (jobject 'note "x") #:ignorable? #t))
  (check-equal?
   (written event)
   (string-append "{\"type\":\"plugin:owner/record\",\"seq\":5,\"time\":10,"
                  "\"data\":{\"note\":\"x\"},\"ignorable\":true}"))
  (check-true (session-event-ignorable? event))
  (check-false (session-event-ignorable? (make-session-event "turn/start" 0 1 'null))))

(test-case "events: a written event reads back equal, and equality follows the JSON form"
  (define event
    (make-session-event "user/message" 3 10 (jobject 'id "m" 'content (list 1 "a" 'null))
                        #:surface-op 'append
                        #:sources '(1 2)))
  (define reread (jvalue->session-event (string->jvalue (written event))))
  (check-equal? reread event)
  (check-equal? (equal-hash-code reread) (equal-hash-code event))
  (check-equal? (written reread) (written event))
  (check-not-equal? event (make-session-event "user/message" 3 11 (jobject 'id "m")
                                              #:surface-op 'append))
  (check-eq? (session-event-surface-op event) 'append)
  (check-equal? (session-event-source-seqs event) '(1 2)))

(test-case "events: absent and #f both leave a metadata key out"
  (define plain (make-session-event "user/message" 0 1 (jobject)))
  (check-equal? (make-session-event "user/message" 0 1 (jobject) #:sources #f #:surface-op #f)
                plain)
  (check-equal? (make-session-event "user/message" 0 1 (jobject)
                                    #:sources absent #:surface-op absent)
                plain)
  ;; The empty list is a given list.
  (check-true (jhas? (session-event->jvalue
                      (make-session-event "user/message" 0 1 (jobject) #:sources '()))
                     'sourceEventSeqs))
  (define input (make-session-event-input "user/message" (jobject) #:surface-op 'append))
  (define event
    (make-session-event (session-event-input-type input) 0 1 (session-event-input-data input)
                        #:sources (session-event-input-sources input)
                        #:surface-op (session-event-input-surface-op input)))
  (check-equal? (jkeys (session-event->jvalue event)) '(type seq time data surfaceOp)))

(test-case "events: make-session-event states its preconditions as contracts"
  (check-exn exn:fail:contract? (lambda () (make-session-event 'turn/start 0 1 'null)))
  (check-exn exn:fail:contract? (lambda () (make-session-event "turn/start" -1 1 'null)))
  (check-exn exn:fail:contract? (lambda () (make-session-event "turn/start" 0 0.5 'null)))
  (check-exn exn:fail:contract? (lambda () (make-session-event "turn/start" 0 1 (void))))
  (check-exn exn:fail:contract?
             (lambda () (make-session-event "turn/start" 0 1 'null #:surface-op "append")))
  (check-exn exn:fail:contract?
             (lambda () (make-session-event "turn/start" 0 1 'null #:sources '(-1))))
  (check-exn exn:fail:contract?
             (lambda () (make-session-event "turn/start" 0 1 'null #:metadata-order 'other))))

(test-case "events: an event prints as its JSON form"
  (check-equal? (format "~a" (make-session-event "turn/start" 0 1 (jobject 'turn 1)))
                (string-append "#<session-event {\"type\":\"turn/start\",\"seq\":0,\"time\":1,"
                               "\"data\":{\"turn\":1}}>")))

;; ---- event inputs ----

(test-case "inputs: an input carries its type, data and optional surface metadata"
  (define plain (make-session-event-input "turn/start" (jobject 'turn 1)))
  (check-true (session-event-input? plain))
  (check-equal? (session-event-input-type plain) "turn/start")
  (check-equal? (session-event-input-data plain) (jobject 'turn 1))
  (check-false (session-event-input-surface-op plain))
  (check-false (session-event-input-sources plain))
  (define surfaced
    (make-session-event-input "user/message" (jobject)
                              #:surface-op (surface-replace 0 1)
                              #:sources '(0 1)))
  (check-equal? (session-event-input-surface-op surfaced) (surface-replace 0 1))
  (check-equal? (session-event-input-sources surfaced) '(0 1))
  (check-false (session-event? plain))
  (check-exn exn:fail:contract?
             (lambda () (make-session-event-input "user/message" (jobject) #:surface-op 'replace))))

;; ---- plugin records ----

(test-case "rule 32: the plugin record type grammar"
  (for ([type (list "plugin:a" "plugin:owner/record" "plugin:a.b_c-d/e.f/9x" "plugin:0/1")])
    (check-true (plugin-record-type? type) type))
  (for ([type (list "plugin:" "plugin" "plugin:A" "plugin:a/" "plugin:/a" "plugin:a//b"
                    "plugin:.a" "plugin:a/-b" "plugin:a b" "turn/start" "xplugin:a"
                    "plugin:a\n" "Plugin:a")])
    (check-false (plugin-record-type? type) type))
  (check-false (plugin-record-type? 'plugin:a)))

(test-case "rule 32: the read side of a plugin record is plain data"
  (check-equal? (plugin-record "plugin:a/b" 1 2 (jobject 'k 1))
                (plugin-record "plugin:a/b" 1 2 (jobject 'k 1)))
  (check-equal? (plugin-record-type (plugin-record "plugin:a/b" 1 2 'null)) "plugin:a/b"))

;; ---- message predicates ----

(test-case "message predicates: each role"
  (define user (user-message "hi" #:id "u"))
  (define assistant (assistant-message "ok" #:id "a"))
  (define system (system-message "prompt" #:id "s"))
  (define developer (developer-message '() #:id "d"))
  (define tool (tool-result-message "call-1" "out" #:id "t"))
  (for ([message (list user assistant system developer tool)])
    (check-true (message-jvalue? message)))
  (check-true (user-message-jvalue? user))
  (check-true (assistant-message-jvalue? assistant))
  (check-true (system-message-jvalue? system))
  (check-true (developer-message-jvalue? developer))
  (check-true (tool-result-message-jvalue? tool))
  (check-false (user-message-jvalue? assistant))
  (check-false (assistant-message-jvalue? user))
  (check-false (system-message-jvalue? user))
  (check-false (developer-message-jvalue? user))
  (check-false (tool-result-message-jvalue? user)))

(test-case "message predicates: the shape checks of rule 5"
  (define user (user-message "hi" #:id "u"))
  (check-false (message-jvalue? (jset user 'id "")))
  (check-false (message-jvalue? (jremove user 'id)))
  (check-false (message-jvalue? (jset user 'id 5)))
  (check-false (message-jvalue? (jset user 'role "narrator")))
  (check-false (message-jvalue? (jset user 'source "user")))
  (check-false (message-jvalue? (jset user 'source (jobject 'kind ""))))
  (check-false (message-jvalue? (jset user 'content "text")))
  (check-false (message-jvalue? 'null))
  (check-false (message-jvalue? (list user)))
  (check-false (user-message-jvalue? (jset user 'content 'null)))
  (check-true (user-message-jvalue? (jset user 'source (jobject 'kind "watcher" 'extra 1))))
  (define system (system-message "prompt" #:id "s"))
  (check-false (system-message-jvalue? (jset system 'source (jobject 'kind "user"))))
  (define assistant (assistant-message "ok" #:id "a"))
  (check-false (assistant-message-jvalue? (jset assistant 'source (jobject 'kind "model"))))
  (check-false (assistant-message-jvalue?
                (jset assistant 'source (jobject 'kind "model" 'provider "p" 'model ""))))
  (check-false (assistant-message-jvalue?
                (jset assistant 'source (jobject 'kind "user" 'provider "p" 'model "m"))))
  (define tool (tool-result-message "call-1" "out" #:id "t"))
  (check-false (tool-result-message-jvalue? (jset tool 'toolCallId "call-2")))
  (check-false (tool-result-message-jvalue? (jremove tool 'toolCallId)))
  (check-false (tool-result-message-jvalue? (jset tool 'source (jobject 'kind "tool"))))
  (check-false (tool-result-message-jvalue?
                (jset tool 'source (jobject 'kind "tool" 'callId "")))))

;; ---- define-session-event ----

(define-session-event sample/call
  #:type "sample/call"
  #:fields ([turn session-seq?]
            [call-id "callId" string?]
            [note string? #:optional]
            [mode (or/c "fast" "slow") #:optional]
            [flag #t #:optional]
            [meta "meta" jvalue? #:optional]))

(define-session-event sample/blob
  #:type "sample/blob"
  #:data string?)

(define-session-event sample/user
  #:type "user/message"
  #:data user-message-jvalue?)

(define-session-event sample/result
  #:type "tool/result"
  #:fields ([turn session-seq?]
            [message tool-result-message-jvalue?]))

(define-session-event sample/assistant
  #:type "assistant/message"
  #:fields ([turn session-seq?]
            [message assistant-message-jvalue?]))

(define-session-event sample/record
  #:type "plugin:sample/record"
  #:ignorable
  #:fields ([text string?]
            [count session-seq? #:optional]))

(define-session-event sample/opaque
  #:type "plugin:sample/opaque"
  #:ignorable
  #:data jobject?)

(test-case "define-session-event: the declaration value"
  (check-true (session-event-type? sample/call-type))
  (check-false (session-event-type? "sample/call"))
  (check-equal? (session-event-type-tag sample/call-type) "sample/call")
  (check-false (session-event-type-ignorable? sample/call-type))
  (check-false (session-event-type-surface? sample/call-type))
  (check-equal? (session-event-type-fields sample/call-type)
                '((turn "turn" #f)
                  (call-id "callId" #f)
                  (note "note" #t)
                  (mode "mode" #t)
                  (flag "flag" #t)
                  (meta "meta" #t)))
  (check-equal? (session-event-type-fields sample/blob-type) '())
  (check-true (session-event-type-surface? sample/user-type))
  (check-true (session-event-type-surface? sample/result-type))
  (check-true (session-event-type-ignorable? sample/record-type))
  (check-equal? (session-event-type-tag sample/record-type) "plugin:sample/record"))

(test-case "define-session-event: the constructor writes the fields in declared order"
  (define input (sample/call #:call-id "c1" #:turn 2))
  (check-true (session-event-input? input))
  (check-equal? (session-event-input-type input) "sample/call")
  (check-equal? (jvalue->string (session-event-input-data input)) "{\"turn\":2,\"callId\":\"c1\"}")
  (check-false (session-event-input-surface-op input))
  (check-false (session-event-input-sources input))
  (define full
    (sample/call #:meta #f #:flag #t #:mode "slow" #:note "n" #:call-id "c1" #:turn 2))
  (check-equal? (jvalue->string (session-event-input-data full))
                (string-append "{\"turn\":2,\"callId\":\"c1\",\"note\":\"n\",\"mode\":\"slow\","
                               "\"flag\":true,\"meta\":false}")))

(test-case "define-session-event: absent omits a key and every other value writes it"
  (check-equal?
   (jvalue->string (session-event-input-data
                    (sample/call #:turn 1 #:call-id "c" #:note absent #:meta 'null)))
   "{\"turn\":1,\"callId\":\"c\",\"meta\":null}")
  (check-true (jhas? (session-event-input-data (sample/call #:turn 1 #:call-id "c" #:meta #f))
                     'meta)))

(test-case "define-session-event: the constructor checks each value against its contract"
  (check-exn (contract-error #rx"sample/call: contract violation.*field: turn")
             (lambda () (sample/call #:turn -1 #:call-id "c")))
  (check-exn (contract-error #rx"field: call-id")
             (lambda () (sample/call #:turn 1 #:call-id 'c)))
  (check-exn (contract-error #rx"field: note")
             (lambda () (sample/call #:turn 1 #:call-id "c" #:note #f)))
  (check-exn (contract-error #rx"field: flag")
             (lambda () (sample/call #:turn 1 #:call-id "c" #:flag #f)))
  (check-exn (contract-error #rx"field: mode")
             (lambda () (sample/call #:turn 1 #:call-id "c" #:mode "medium")))
  (check-exn exn:fail:contract? (lambda () (sample/call #:turn 1)))
  (check-exn (contract-error #rx"sample/blob: contract violation.*field: data")
             (lambda () (sample/blob 5))))

(test-case "define-session-event: the predicate and the accessors take events and inputs"
  (define input (sample/call #:turn 2 #:call-id "c1" #:meta #f))
  (define event (car (inputs->events (list input))))
  (for ([value (list input event)])
    (check-true (sample/call? value))
    (check-false (sample/blob? value))
    (check-equal? (sample/call-turn value) 2)
    (check-equal? (sample/call-call-id value) "c1")
    (check-false (sample/call-note value))
    (check-false (sample/call-mode value))
    (check-false (sample/call-meta value)))
  (check-false (sample/call? "sample/call"))
  (check-false (sample/call? (jobject 'turn 2)))
  (check-exn (contract-error #rx"sample/call-turn: contract violation.*expected: sample/call\\?")
             (lambda () (sample/call-turn (sample/blob "x"))))
  ;; A stored event whose data is not an object has no fields.
  (check-false (sample/call-turn (make-session-event "sample/call" 0 1 "text"))))

(test-case "define-session-event: a declaration of the whole data value"
  (define input (sample/blob "payload"))
  (check-equal? (session-event-input-type input) "sample/blob")
  (check-equal? (session-event-input-data input) "payload")
  (check-true (sample/blob? input))
  (check-true (sample/blob? (car (inputs->events (list input))))))

(test-case "define-session-event: a surface-eligible type takes surface-op and sources"
  (define message (user-message "hi" #:id "u"))
  (define appended (sample/user message #:surface-op 'append))
  (check-eq? (session-event-input-surface-op appended) 'append)
  (check-false (session-event-input-sources appended))
  (check-eq? (session-event-input-data appended) message)
  (define replaced (sample/user message #:surface-op (surface-replace 1 2) #:sources '(1 2)))
  (check-equal? (session-event-input-surface-op replaced) (surface-replace 1 2))
  (check-equal? (session-event-input-sources replaced) '(1 2))
  (check-exn exn:fail:contract? (lambda () (sample/user message)))
  (check-exn (contract-error #rx"sample/user: contract violation")
             (lambda () (sample/user message #:surface-op "append")))
  (check-exn (contract-error #rx"sample/user: contract violation")
             (lambda () (sample/user message #:surface-op 'append #:sources '(-1))))
  (define result
    (sample/result #:turn 1 #:message (tool-result-message "c" "out" #:id "t")
                   #:surface-op 'append #:sources '(3)))
  (check-equal? (session-event-input-sources result) '(3))
  ;; A log-only type takes neither keyword.
  (check-exn exn:fail:contract?
             (lambda () (keyword-apply sample/call '(#:call-id #:surface-op #:turn)
                                       (list "c" 'append 1) '()))))

(test-case "define-session-event: assistant/message takes surface-op but no sources"
  (define message (assistant-message "ok" #:id "a"))
  (define input (sample/assistant #:turn 1 #:message message #:surface-op 'append))
  (check-eq? (session-event-input-surface-op input) 'append)
  (check-exn exn:fail:contract?
             (lambda () (keyword-apply sample/assistant '(#:message #:sources #:surface-op #:turn)
                                       (list message '(0) 'append 1) '()))))

(test-case "define-session-event: an ignorable declaration builds plugin record inputs"
  (define input (sample/record #:text "hello"))
  (check-true (plugin-record-input? input))
  (check-false (session-event-input? input))
  (check-equal? (plugin-record-input-type input) "plugin:sample/record")
  (check-equal? (jvalue->string (plugin-record-input-data input)) "{\"text\":\"hello\"}")
  (check-eq? (plugin-record-input-declaration input) sample/record-type)
  (check-true (sample/record? input))
  (check-equal? (sample/record-text input) "hello")
  (check-false (sample/record-count input))
  (check-exn (contract-error #rx"field: text") (lambda () (sample/record #:text 5)))
  (define opaque (sample/opaque (jobject 'k 1)))
  (check-true (plugin-record-input? opaque))
  (check-equal? (plugin-record-input-data opaque) (jobject 'k 1)))

(test-case "define-session-event: the match pattern"
  (define event
    (car (inputs->events (list (sample/call #:turn 2 #:call-id "c1" #:note "n")))))
  (check-equal? (match event [(sample/call #:call-id id #:turn turn) (list id turn)])
                '("c1" 2))
  (check-equal? (match event [(sample/call) 'matched]) 'matched)
  ;; An absent optional field is matched against #f.
  (check-equal? (match event [(sample/call #:mode mode #:note note) (list mode note)])
                '(#f "n"))
  (check-equal? (match event
                  [(sample/blob) 'blob]
                  [(sample/call #:turn 3) 'other-turn]
                  [(and e (sample/call #:turn 2)) (session-event-seq e)])
                0)
  ;; The pattern matches committed events only, and only with object data.
  (check-equal? (match (sample/call #:turn 2 #:call-id "c1") [(sample/call) 'input] [_ 'no])
                'no)
  (check-equal? (match (make-session-event "sample/call" 0 1 "text") [(sample/call) 'yes] [_ 'no])
                'no)
  (check-equal? (match 5 [(sample/call) 'yes] [_ 'no]) 'no)
  (define blob (car (inputs->events (list (sample/blob "payload")))))
  (check-equal? (match blob [(sample/blob data) data]) "payload")
  (check-equal? (match blob [(sample/call) 'call] [(sample/blob) 'blob]) 'blob))

(test-case "define-session-event: the identifier is a first-class constructor"
  (define inputs (map sample/blob (list "a" "b")))
  (check-equal? (map session-event-input-data inputs) '("a" "b"))
  (check-equal? (object-name sample/call) 'sample/call)
  (check-equal? (session-event-input-data (apply sample/blob (list "c"))) "c"))

(test-case "define-session-event: session-event-type-violation reports the first violation"
  (check-false (session-event-type-violation sample/call-type (jobject 'turn 1 'callId "c")))
  (check-false (session-event-type-violation
                sample/call-type (jobject 'callId "c" 'unknown (list 1) 'turn 1)))
  (check-equal? (session-event-type-violation sample/call-type "text") "data must be an object")
  (check-equal? (session-event-type-violation sample/call-type '()) "data must be an object")
  (check-equal? (session-event-type-violation sample/call-type (jobject 'callId "c"))
                "lacks field \"turn\"")
  (check-equal? (session-event-type-violation sample/call-type (jobject 'turn 1))
                "lacks field \"callId\"")
  (check-equal? (session-event-type-violation sample/call-type (jobject 'turn -1 'callId 5))
                "field \"turn\" is invalid")
  (check-equal? (session-event-type-violation sample/call-type (jobject 'turn 1 'callId 5))
                "field \"callId\" is invalid")
  (check-equal? (session-event-type-violation
                 sample/call-type (jobject 'turn 1 'callId "c" 'flag #f))
                "field \"flag\" is invalid")
  (check-false (session-event-type-violation sample/call-type (hash 'turn 1 'callId "c")))
  (check-false (session-event-type-violation sample/blob-type "text"))
  (check-equal? (session-event-type-violation sample/blob-type 5) "data is invalid"))

(test-case "define-session-event: definitions work in an internal-definition context"
  (define-session-event local/note
    #:type "local/note"
    #:fields ([text string?]))
  (define event (car (inputs->events (list (local/note #:text "x")))))
  (check-true (local/note? event))
  (check-equal? (local/note-text event) "x")
  (check-equal? (match event [(local/note #:text text) text]) "x")
  (check-equal? (session-event-type-tag local/note-type) "local/note"))

(define-syntax-rule (check-syntax-error pattern form)
  (check-exn (lambda (e) (and (exn:fail:syntax? e) (regexp-match? pattern (exn-message e))))
             (lambda () (convert-syntax-error (let () form (void))))))

(test-case "define-session-event: syntax errors name the clause at fault"
  (check-syntax-error
   #rx"duplicate field"
   (define-session-event bad/event #:type "bad/event" #:fields ([x string?] [x string?])))
  (check-syntax-error
   #rx"duplicate JSON key"
   (define-session-event bad/event #:type "bad/event"
     #:fields ([x "key" string?] [y "key" string?])))
  (check-syntax-error
   #rx"duplicate JSON key"
   (define-session-event bad/event #:type "bad/event" #:fields ([x string?] [y "x" string?])))
  (check-syntax-error
   #rx"#:ignorable requires a type tag in the plugin record grammar"
   (define-session-event bad/event #:type "bad/event" #:ignorable #:fields ([x string?])))
  (check-syntax-error
   #rx"plugin record grammar requires #:ignorable"
   (define-session-event bad/event #:type "plugin:bad/event" #:fields ([x string?])))
  (check-syntax-error
   #rx"#:optional is not allowed on a #:data declaration"
   (define-session-event bad/event #:type "bad/event" #:data string? #:optional))
  (check-syntax-error
   #rx"field clause"
   (define-session-event bad/event #:type "bad/event" #:fields ([x])))
  (check-syntax-error
   #rx"field clause"
   (define-session-event bad/event #:type "bad/event" #:fields ([x string? #:required])))
  (check-syntax-error
   #rx"#:type"
   (define-session-event bad/event #:fields ([x string?])))
  (check-syntax-error
   #rx"#:type"
   (define-session-event bad/event #:type bad/event #:fields ([x string?])))
  (check-syntax-error
   #rx"#:fields clause"
   (define-session-event bad/event #:type "bad/event" #:fields [x string?]))
  (check-syntax-error
   #rx"collide with the declaration binding"
   (define-session-event bad/event #:type "bad/event" #:fields ([type string?])))
  (check-syntax-error
   #rx"reserves the keywords"
   (define-session-event bad/event #:type "user/message" #:fields ([sources string?]))))

(test-case "define-session-event: a pattern with an unknown or repeated field is a syntax error"
  (check-syntax-error
   #rx"unknown field keyword"
   (match 1 [(sample/call #:missing v) v]))
  (check-syntax-error
   #rx"duplicate field keyword"
   (match 1 [(sample/call #:turn a #:turn b) a]))
  (check-syntax-error
   #rx"at most one pattern"
   (match 1 [(sample/blob a b) a])))
