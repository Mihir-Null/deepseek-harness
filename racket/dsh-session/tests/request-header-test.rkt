#lang racket/base
;; Tests of `dsh-session/request-header`: rule 24 of the dsh-session contract.
;; Mirrors the pure parts of packages/core/session/tests/request-header.spec.ts.

(require rackunit
         cordis-data
         dsh-session/types
         dsh-session/events
         dsh-session/request-header
         "support/log.rkt")

(define config (jobject 'provider "mock" 'model "m"))

(define (tool name [description "d"])
  (jobject 'name name 'description description 'parameters (jobject 'type "object")))

(define base (canonical-header (jobject 'config config 'tools (list (tool "a")))))

;; ---- canonical-header ----

(test-case "rule 24: empty optional fields become absent and populated fields are kept"
  (check-equal? (jvalue->string
                 (canonical-header (jobject 'config config 'adapterDefaults (jobject) 'tools '())))
                "{\"config\":{\"provider\":\"mock\",\"model\":\"m\"}}")
  (define full
    (canonical-header (jobject 'tools (list (tool "a"))
                               'adapterDefaults (jobject 'maxTokens #t)
                               'config (jset config 'maxTokens 256000))))
  (check-equal? (jkeys full) '(config adapterDefaults tools))
  (check-equal? full
                (jobject 'config (jset config 'maxTokens 256000)
                         'adapterDefaults (jobject 'maxTokens #t)
                         'tools (list (tool "a")))))

(test-case "rule 24: adapterDefaults is kept only when a marker is true"
  (check-false (jhas? (canonical-header
                       (jobject 'config config 'adapterDefaults (jobject 'maxTokens #f)))
                      'adapterDefaults))
  (check-true (jhas? (canonical-header
                      (jobject 'config config
                               'adapterDefaults (jobject 'reasoningEffort #t)))
                     'adapterDefaults))
  (check-false (jhas? (canonical-header (jobject 'config config 'adapterDefaults 'null))
                      'adapterDefaults)))

(test-case "rule 24: keys outside the canonical three are dropped and the values are shared"
  (define tools (list (tool "a")))
  (define header (canonical-header (jobject 'config config 'tools tools 'extra 1)))
  (check-equal? (jkeys header) '(config tools))
  (check-eq? (jref header 'config) config)
  (check-eq? (jref header 'tools) tools))

;; ---- header-equal? ----

(test-case "rule 24: every canonical field is compared and tool order matters"
  (check-true (header-equal? base (string->jvalue (jvalue->string base))))
  (check-false (header-equal? base (jset base 'config (jobject 'provider "mock" 'model "other"))))
  (check-false (header-equal? base (jset base 'config (jset config 'reasoningEffort "high"))))
  (check-false
   (header-equal? (jset base 'config (jset config 'maxTokens 256000))
                  (jset (jset base 'config (jset config 'maxTokens 256000))
                        'adapterDefaults (jobject 'maxTokens #t))))
  (check-false (header-equal? base (jset base 'tools '())))
  (check-false (header-equal? base (jset base 'tools (list (tool "a" "changed")))))
  (check-false (header-equal? (jobject 'config config 'tools (list (tool "a") (tool "b")))
                              (jobject 'config config 'tools (list (tool "b") (tool "a"))))))

(test-case "rule 24: an absent and an empty tool list are equal"
  (check-true (header-equal? (jobject 'config config) (jobject 'config config 'tools '())))
  (check-true (header-equal? (jobject 'config config 'tools '()) (jobject 'config config)))
  (check-true (header-equal? (jobject 'config config) (jobject 'config config))))

(test-case "rule 24: tool schemas compare as JSON text, so key order matters"
  (define reordered
    (jobject 'description "d" 'name "a" 'parameters (jobject 'type "object")))
  (check-equal? reordered (tool "a"))
  (check-false (header-equal? base (jset base 'tools (list reordered))))
  (check-true (header-equal? base (jset base 'tools (list (tool "a"))))))

(test-case "rule 24: config equality"
  (define (with . key-values)
    (jobject 'config (apply jobject 'provider "mock" 'model "m" key-values)))
  (check-true (header-equal? (with 'temperature 1) (with 'temperature 1.0)))
  (check-false (header-equal? (with 'temperature 1) (with 'temperature 0.5)))
  (check-false (header-equal? (with 'temperature 1) (with)))
  (check-false (header-equal? (with 'maxTokens 5) (with 'maxTokens 6)))
  (check-true (header-equal? (with 'maxTokens 5 'temperature 0) (with 'temperature 0 'maxTokens 5)))
  (check-true (header-equal? (with 'stop (list "a" "b")) (with 'stop (list "a" "b"))))
  (check-false (header-equal? (with 'stop (list "a" "b")) (with 'stop (list "b" "a"))))
  (check-false (header-equal? (with 'stop (list "a")) (with 'stop (list "a" "b"))))
  ;; An absent stop list differs from every list, the empty one included.
  (check-false (header-equal? (with) (with 'stop '())))
  (check-false (header-equal? (with 'stop '()) (with)))
  (check-true (header-equal? (with 'stop '()) (with 'stop '())))
  ;; A field outside the six is not compared.
  (check-true (header-equal? (with 'extra 1) (with 'extra 2))))

(test-case "rule 24: adapter-default markers are compared one by one"
  (define (with defaults)
    (jobject 'config (jset (jset config 'maxTokens 5) 'reasoningEffort "high")
             'adapterDefaults defaults))
  (check-true (header-equal? (with (jobject 'maxTokens #t)) (with (jobject 'maxTokens #t))))
  (check-false (header-equal? (with (jobject 'maxTokens #t))
                              (with (jobject 'reasoningEffort #t))))
  (check-false (header-equal? (with (jobject 'maxTokens #t))
                              (with (jobject 'maxTokens #t 'reasoningEffort #t)))))

;; ---- fold-request-header ----

(define (header-input header reason)
  (request/header #:header header #:reason reason))

(test-case "rule 24: the baseline is returned when no snapshot follows"
  (define from (jobject 'config config 'tools (list (tool "baseline"))))
  (define unrelated (inputs->events (list (turn/start #:turn 1))))
  (check-false (fold-request-header unrelated))
  (check-eq? (fold-request-header unrelated from) from)
  (check-false (fold-request-header '()))
  (check-eq? (fold-request-header '() from) from))

(test-case "rule 24: the latest snapshot wins and unrelated events are skipped"
  (define events
    (inputs->events
     (list (turn/start #:turn 1)
           (header-input (jobject 'config config 'tools (list (tool "first"))) "initial")
           (user/message (user-message "hi") #:surface-op 'append)
           (header-input (jobject 'config (jobject 'provider "mock" 'model "other")) "change"))))
  (check-equal? (jvalue->string (fold-request-header events))
                "{\"config\":{\"provider\":\"mock\",\"model\":\"other\"}}")
  (check-equal? (fold-request-header (list (car events) (cadr events)))
                (jobject 'config config 'tools (list (tool "first"))))
  ;; Folding a suffix from the state of the prefix gives the fold of the whole log.
  (define prefix (fold-request-header (list (car events) (cadr events))))
  (check-equal? (fold-request-header (cddr events) prefix) (fold-request-header events))
  (check-eq? (fold-request-header (list (caddr events)) prefix) prefix))

(test-case "rule 24: the fold returns the canonical form of what was logged"
  (define logged
    (raw-event "request/header" 0
               (jobject 'header (jobject 'tools (list (tool "a"))
                                         'config config
                                         'extension (jobject 'nested #t))
                        'reason "initial")))
  (check-equal? (jkeys (fold-request-header (list logged))) '(config tools))
  (check-true (header-equal? (fold-request-header (list logged)) base)))

(test-case "rule 24: the sample log folds to its header"
  (define header (fold-request-header (sample-log)))
  (check-equal? (jref* header '(config provider)) "mock")
  (check-equal? (length (jref header 'tools)) 1))
