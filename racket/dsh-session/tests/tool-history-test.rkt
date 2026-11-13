#lang racket/base
;; Tests of `dsh-session/tool-history`: rule 25 of the dsh-session contract.
;; Mirrors packages/core/session/tests/tool-history.spec.ts as folds over logs built through
;; the constructors. The projection of updates onto a model request belongs to `dsh-llm`.

(require rackunit
         cordis-data
         dsh-session/types
         dsh-session/events
         dsh-session/tool-history
         "support/log.rkt")

(define search (jobject 'name "search" 'description "Search" 'parameters (jobject)))
(define fetch (jobject 'name "fetch" 'description "Fetch" 'parameters (jobject)))
(define config (jobject 'provider "test" 'model "test"))

(define (header tools #:reason [reason "change"] #:starts-series? [starts-series? #f])
  (request/header #:header (if (null? tools)
                               (jobject 'config config)
                               (jobject 'config config 'tools tools))
                  #:reason reason
                  #:starts-series (if starts-series? #t absent)))

(define (update id content #:header-seq [header-seq absent])
  (developer/message #:turn 1
                     #:step 1
                     #:message (developer-message content #:id id
                                                  #:source (jobject 'kind "test"))
                     #:header-seq header-seq
                     #:surface-op 'append))

(define (add name) (tool-addition-block name))
(define (remove name) (tool-removal-block name))

;; The first three events of every log: the initial header is at seq 2.
(define (opened tools)
  (list (turn/start #:turn 1) (step/start #:turn 1 #:step 1) (header tools #:reason "initial")))

(define (fold events [st (tool-history-state-empty)])
  (for/fold ([st st]) ([e (in-list events)])
    (tool-history-apply st e)))

(define (history . input-lists)
  (tool-history-snapshot (fold (inputs->events (apply append input-lists)))))

(define (update-record id . additions)
  (jobject 'messageId id 'additions additions))

(define (last-update snapshot)
  (car (reverse (jref snapshot 'updates))))

(test-case "rule 25: the empty state has no tools and no updates"
  (define st (tool-history-state-empty))
  (check-true (tool-history-state? st))
  (check-equal? (jvalue->string (tool-history-snapshot st)) "{\"tools\":[],\"updates\":[]}"))

(test-case "rule 25: an initial header gives its tools and no updates"
  (define snapshot (history (opened (list search))))
  (check-equal? snapshot (jobject 'tools (list search) 'updates '()))
  (check-equal? (jkeys snapshot) '(tools updates))
  (check-eq? (car (jref snapshot 'tools)) search))

(test-case "rule 25: additions resolve from their header and earlier snapshots do not change"
  (define events
    (inputs->events
     (append (opened (list search))
             (list (header (list search fetch))                       ; seq 3
                   (update "added" (list (add "fetch")) #:header-seq 3)
                   (header (list search))
                   (update "removed" (list (remove "fetch") (text-block "fetch is disabled")))))))
  (define initial-state (fold (list (list-ref events 0) (list-ref events 1) (list-ref events 2))))
  (define initial (tool-history-snapshot initial-state))
  (define after-addition-state (fold (list (list-ref events 3) (list-ref events 4)) initial-state))
  (define after-addition (tool-history-snapshot after-addition-state))
  (check-equal? after-addition
                (jobject 'tools (list search) 'updates (list (update-record "added" fetch))))
  (check-equal? (jkeys (car (jref after-addition 'updates))) '(messageId additions))
  (define final
    (tool-history-snapshot
     (fold (list (list-ref events 5) (list-ref events 6)) after-addition-state)))
  (check-equal? final
                (jobject 'tools (list search)
                         'updates (list (update-record "added" fetch)
                                        (update-record "removed"))))
  ;; The earlier states and snapshots are unchanged by the later events.
  (check-equal? initial (jobject 'tools (list search) 'updates '()))
  (check-equal? (tool-history-snapshot initial-state) initial)
  (check-equal? (length (jref after-addition 'updates)) 1)
  (check-equal? (tool-history-snapshot after-addition-state) after-addition))

(test-case "rule 25: an explicit series start restarts the declarations"
  (for ([restart (list (header (list search fetch) #:reason "series")
                       (header (list search fetch) #:starts-series? #t))])
    (define prefix
      (append (opened (list search))
              (list (header (list search fetch))                      ; seq 3
                    (update "first" (list (add "fetch")) #:header-seq 3)
                    restart)))                                        ; seq 5
    (check-equal? (history prefix) (jobject 'tools (list search fetch) 'updates '()))
    (check-equal? (history prefix (list (update "again" (list (add "fetch")) #:header-seq 5)))
                  (jobject 'tools (list search fetch)
                           'updates (list (update-record "again" fetch))))))

(test-case "rule 25: a retained name with a changed definition restarts the declarations"
  (define changed (jset fetch 'description "Fetch v2"))
  (check-equal?
   (history (opened (list search fetch))
            (list (header (list search))
                  (update "removed" (list (remove "fetch")))
                  (header (list search changed))                      ; seq 5
                  (update "added" (list (add "fetch")) #:header-seq 5)))
   (jobject 'tools (list search changed)
            'updates (list (update-record "added" changed)))))

(test-case "rule 25: a definition that differs only in key order counts as changed"
  (define reordered (jobject 'description "Fetch" 'name "fetch" 'parameters (jobject)))
  (check-equal? reordered fetch)
  (check-equal?
   (history (opened (list search fetch))
            (list (header (list search))
                  (update "removed" (list (remove "fetch")))
                  (header (list search reordered))                    ; seq 5
                  (update "added" (list (add "fetch")) #:header-seq 5)))
   (jobject 'tools (list search reordered)
            'updates (list (update-record "added" reordered)))))

(test-case "rule 25: deferred baseline tools are activated through recorded additions"
  (define deferred (jset fetch 'deferLoading #t))
  (define snapshot
    (history (opened (list search deferred))
             (list (update "added" (list (add "search") (add "fetch")) #:header-seq 2)
                   (update "duplicate" (list (add "fetch")) #:header-seq 2))))
  (check-equal? (jref snapshot 'tools) (list search deferred))
  (check-equal? (jref snapshot 'updates)
                (list (update-record "added" search deferred)
                      (update-record "duplicate" deferred))))

(test-case "rule 25: a retained name restored unchanged continues the series"
  (check-equal?
   (history (opened (list search fetch))
            (list (header (list search))
                  (update "removed" (list (remove "fetch")))
                  (header (list search fetch))                        ; seq 5
                  (update "restored" (list (add "fetch")) #:header-seq 5)))
   (jobject 'tools (list search fetch)
            'updates (list (update-record "removed") (update-record "restored" fetch)))))

(test-case "rule 25: a header without its update record falls back to the active tools"
  (define prefix (append (opened (list search)) (list (header (list search fetch)))))  ; seq 3
  (check-equal? (history prefix) (jobject 'tools (list search fetch) 'updates '()))
  (define with-update (list (update "added" (list (add "fetch")) #:header-seq 3)))
  (check-equal? (history prefix with-update)
                (jobject 'tools (list search) 'updates (list (update-record "added" fetch))))
  (check-equal? (history prefix with-update (list (header (list search))))
                (jobject 'tools (list search) 'updates '())))

(test-case "rule 25: a tool-less header leaves no active tools"
  (check-equal? (history (opened (list search)) (list (header '())))
                (jobject 'tools '() 'updates '()))
  (check-equal? (history (opened '())) (jobject 'tools '() 'updates '())))

(test-case "rule 25: folding a restored log equals the live fold and continues from it"
  (define events
    (inputs->events
     (append (opened (list search))
             (list (header (list search fetch))
                   (update "added" (list (add "fetch")) #:header-seq 3)))))
  (define live (fold events))
  (define restored (fold events))
  (check-equal? (tool-history-snapshot restored) (tool-history-snapshot live))
  (define continued
    (fold (inputs->events (list (header (list search))
                                (update "removed" (list (remove "fetch"))))
                          #:from (length events))
          restored))
  (check-equal? (last-update (tool-history-snapshot continued)) (update-record "removed"))
  (check-equal? (length (jref (tool-history-snapshot live) 'updates)) 1))

(test-case "rule 25: an addition whose header lacks the definition is refused"
  (define (header-at seq reason)
    (raw-event "request/header" seq
               (jobject 'reason reason 'header (jobject 'config config 'tools (list search)))))
  (define developer
    (raw-event "developer/message" 2
               (jobject 'turn 1 'step 1
                        'message (developer-message (list (add "fetch")) #:id "d")
                        'headerSeq 1)
               #:surface-op "append"))
  (define st (fold (list (header-at 0 "initial") (header-at 1 "change"))))
  (check-exn (session-error "tool history: missing definition for fetch")
             (lambda () (tool-history-apply st developer)))
  ;; The state is unchanged by the refused event.
  (check-equal? (tool-history-snapshot st) (jobject 'tools (list search) 'updates '())))

(test-case "rule 25: an addition without a known header is refused"
  (define st (fold (inputs->events (opened (list search)))))
  (define (developer header-seq)
    (raw-event "developer/message" 3
               (let ([data (jobject 'turn 1 'step 1
                                    'message (developer-message (list (add "search")) #:id "d"))])
                 (if (absent? header-seq) data (jset data 'headerSeq header-seq)))
               #:surface-op "append"))
  (check-exn (session-error "tool history: missing definition for search")
             (lambda () (tool-history-apply st (developer absent))))
  (check-exn (session-error "tool history: missing definition for search")
             (lambda () (tool-history-apply st (developer 1))))
  (check-not-exn (lambda () (tool-history-apply st (developer 2)))))

(test-case "rule 25: other events leave the state as it is"
  (define st (fold (inputs->events (opened (list search)))))
  (for ([e (in-list (sample-log))]
        #:unless (member (session-event-type e) '("request/header" "developer/message")))
    (check-eq? (tool-history-apply st e) st)))

(test-case "rule 25: the sample log declares its one tool"
  (define snapshot (tool-history-snapshot (fold (sample-log))))
  (check-equal? (map (lambda (tool) (jref tool 'name)) (jref snapshot 'tools)) '("read"))
  (check-equal? (jref snapshot 'updates) '()))
