#lang racket/base
;; A sweep of the data plane over every current-format session recording of the dsh
;; repository (`snapshots/session/*/session*.v4.jsonl`): each recorded event line must be
;; rebuilt byte for byte, pass the event-local checks and the declarations of the core types,
;; and each log must fold, derive, and close without an error.
;;
;; The recordings are normalised: event lines carry no seq and no time, and the tool list of
;; a request header is the token "{{tools}}" or a list of tool names. The sweep gives each
;; line its index as seq and stands a tool schema in for each name. It is skipped when the
;; package is used outside the dsh repository.

(require rackunit
         racket/list
         racket/port
         racket/set
         cordis-data
         dsh-session/lossless
         dsh-session/types
         dsh-session/events
         dsh-session/surface
         dsh-session/request-header
         dsh-session/tool-history
         dsh-session/repair
         dsh-session/fork
         "support/log.rkt")

(define snapshot-root
  (let ([marker (repository-file "snapshots" "session" "fs-read" "session.v4.jsonl")])
    (and marker
         (let*-values ([(scenario name must-be-directory?) (split-path marker)]
                       [(root scenario-name scenario-directory?) (split-path scenario)])
           root))))

(define (recordings)
  (for*/list ([scenario (in-list (sort (directory-list snapshot-root #:build? #t) path<?))]
              #:when (directory-exists? scenario)
              [file (in-list (sort (directory-list scenario #:build? #t) path<?))]
              #:when (regexp-match? #rx"session([.][0-9]+)?[.]v4[.]jsonl$" (path->string file)))
    file))

(define (label file)
  (define-values (scenario name must-be-directory?) (split-path file))
  (define-values (root scenario-name scenario-directory?) (split-path scenario))
  (format "~a/~a" scenario-name name))

(define (stand-in-schema name)
  (jobject 'name name 'description "" 'parameters (jobject)))

;; The row with real tool schemas in place of the recording's token or name list.
(define (with-tool-schemas row)
  (define tools (jref* row '(data header tools) #f))
  (cond
    [(not (equal? (jref row 'type) "request/header")) row]
    [(equal? tools "{{tools}}") (jset* row '(data header tools) (list (stand-in-schema "tool")))]
    [(and (pair? tools) (andmap string? tools))
     (jset* row '(data header tools) (map stand-in-schema tools))]
    [else row]))

(define (declaration-of type)
  (findf (lambda (declaration) (equal? (session-event-type-tag declaration) type))
         core-session-event-types))

(define (without-position event)
  (jvalue->string (jremove (jremove (session-event->jvalue event) 'seq) 'time)))

;; A projection that changes nothing, for the types that are accepted only with one.
(define pass-through-projections
  (for/list ([type (in-set message-projection-event-types)])
    (message-projection type (lambda (event context) (hasheqv)))))

(define (fold-stepwise events)
  (define log (list->vector events))
  (define (event-ref seq)
    (and (< seq (vector-length log)) (vector-ref log seq)))
  (for/fold ([st (surface-state-empty)]) ([e (in-list events)])
    (surface-step st e event-ref pass-through-projections)))

;; check-recording : path? -> exact-nonnegative-integer?
;; Returns the number of event lines checked.
(define (check-recording file)
  (define where (label file))
  (define lines
    (filter (lambda (line) (not (string=? line "")))
            (call-with-input-file file port->lines)))
  (define header (string->jvalue (car lines)))
  (check-equal? (jref header 'type) "session" where)
  (check-equal? (jref header 'version) session-format-version where)
  (define events
    (for/list ([line (in-list (cdr lines))] [index (in-naturals)])
      (define at (format "~a line ~a" where (+ index 2)))
      (define row (string->jvalue line))
      (check-false (or (jhas? row 'seq) (jhas? row 'time)) at)
      (check-true (lossless-json? row) at)
      ;; The envelope as recorded is rebuilt with the same keys in the same order.
      (define recorded (jvalue->session-event (jset (jset row 'seq index) 'time 0)))
      (define rebuilt
        (make-session-event (session-event-type recorded) index 0 (session-event-data recorded)
                            #:sources (or (session-event-source-seqs recorded) absent)
                            #:surface-op (or (session-event-surface-op recorded) absent)
                            #:ignorable? (session-event-ignorable? recorded)))
      (check-equal? (without-position rebuilt) line at)
      (check-equal? rebuilt recorded at)
      ;; The event with real tool schemas passes every event-local check.
      (define event
        (jvalue->session-event (jset (jset (with-tool-schemas row) 'seq index) 'time 0)))
      (define type (session-event-type event))
      (define data (session-event-data event))
      (define declaration (declaration-of type))
      (when declaration
        (check-false (session-event-type-violation declaration data) at))
      (check-not-exn (lambda () (validate-session-event-data type data at)) at)
      (check-not-exn (lambda () (check-event-shape type data at)) at)
      (check-not-exn (lambda () (check-session-event event)) at)
      event))
  ;; The whole log folds, and the stepwise fold agrees with the whole-log fold.
  (define result (fold-surface events #:projections pass-through-projections))
  (define st (fold-stepwise events))
  (check-equal? (surface-state-nodes st) (surface-fold-result-nodes result) where)
  (check-equal? (surface-state-replace-generation st)
                (length (surface-fold-result-replacements result))
                where)
  (define messages (derive-messages events #:projections pass-through-projections))
  (check-true (<= (length messages) (length (surface-fold-result-nodes result))) where)
  (for ([message (in-list messages)])
    (check-true (message-jvalue? message) where))
  ;; The request folds accept the log.
  (define folded-header (fold-request-header events))
  (when folded-header
    (check-true (header-equal? folded-header (canonical-header folded-header)) where))
  (check-true (jobject? (tool-history-snapshot
                         (for/fold ([st (tool-history-state-empty)]) ([e (in-list events)])
                           (tool-history-apply st e))))
              where)
  ;; Closing the tail gives a balanced log, and a fork at the last event folds.
  (define closers (interrupted-turn-closers events))
  (check-equal? (interrupted-turn-closers (append events closers)) '() where)
  (unless (null? events)
    (define seed (build-fork-seed events (sub1 (length events))))
    (check-not-exn (lambda () (fold-surface seed #:projections pass-through-projections))
                   where))
  (length events))

(test-case "corpus: every recorded current-format session passes the data plane"
  (cond
    [(not snapshot-root)
     (displayln "corpus sweep skipped: snapshots/session not found" (current-error-port))]
    [else
     (define files (recordings))
     (check-true (>= (length files) 100))
     (define event-count
       (for/sum ([file (in-list files)]) (check-recording file)))
     (check-true (>= event-count 1000))]))
