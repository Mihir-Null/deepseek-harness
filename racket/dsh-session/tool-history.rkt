#lang racket/base
;; The tool-history fold: which tool definitions a request declares at the start of the
;; current series and which additions each developer message made since.
;;
;; The state is immutable; `tool-history-apply` returns the next state and a snapshot taken
;; earlier never changes. Events must be applied in log order. A snapshot is the jobject
;; `{tools, updates: [{messageId, additions}...]}` that a model request takes.
;; source: packages/core/session/src/tool-history.ts

(require racket/contract/base
         cordis-data
         "types.rkt"
         (only-in "private/base.rkt"
                  raise-session-error field valid-seq? js-string js-truthy? js-strict-equal?))

(provide
 (contract-out
  [tool-history-state? predicate/c]
  ;; The state before any event.
  [tool-history-state-empty (-> tool-history-state?)]
  ;; Folds one event; raises `exn:fail:session` for an addition whose header lacks the tool.
  [tool-history-apply (-> tool-history-state? session-event? tool-history-state?)]
  ;; `{tools, updates}` for the current series.
  [tool-history-snapshot (-> tool-history-state? jobject?)]))

;; headers : seq -> tool list of that `request/header`, for additions that cite it.
;; declared : name -> definition, every tool declared in the current series, removed ones
;;   included.
;; active : the tool list of the latest header.
;; available : name -> #t, the names the baseline and the recorded updates leave active.
;; baseline : the seq of the header that started the current series, or #f.
;; tools, rev-updates : the snapshot of the current series; updates newest first.
(struct tool-history-state (headers declared active available baseline tools rev-updates))

(define (tool-history-state-empty)
  (tool-history-state (hasheqv) (hash) '() (hash) #f '() '()))

(define (tool-name tool)
  (field tool 'name))

(define (same-definition? a b)
  (string=? (jvalue->string a) (jvalue->string b)))

(define (list-or-empty v)
  (if (list? v) v '()))

(define (apply-header st seq data)
  (define tools (list-or-empty (field (field data 'header) 'tools)))
  (define declared (tool-history-state-declared st))
  ;; A retained name cannot take a different definition inside one series.
  (define redeclared?
    (for/or ([tool (in-list tools)])
      (define before (hash-ref declared (tool-name tool) absent))
      (and (not (absent? before)) (not (same-definition? before tool)))))
  (define headers (hash-set (tool-history-state-headers st) seq tools))
  (if (or (not (tool-history-state-baseline st))
          (equal? (field data 'reason) "series")
          (js-truthy? (field data 'startsSeries))
          redeclared?)
      (tool-history-state headers
                          (for/hash ([tool (in-list tools)]) (values (tool-name tool) tool))
                          tools
                          (for/hash ([tool (in-list tools)]) (values (tool-name tool) #t))
                          seq
                          tools
                          '())
      (struct-copy tool-history-state st [headers headers] [active tools])))

(define (apply-developer-message st data)
  (define message (field data 'message))
  (define header-seq (field data 'headerSeq))
  (define definitions
    (and (valid-seq? header-seq)
         (hash-ref (tool-history-state-headers st) (inexact->exact header-seq) #f)))
  (define content (list-or-empty (field message 'content)))
  (define additions
    (for/list ([block (in-list content)]
               #:when (equal? (field block 'type) "tool-addition"))
      (define name (field block 'toolName))
      (or (for/first ([tool (in-list (or definitions '()))]
                      #:when (js-strict-equal? (tool-name tool) name))
            tool)
          (raise-session-error "tool history: missing definition for ~a" (js-string name)))))
  (define declared
    (for/fold ([declared (tool-history-state-declared st)]) ([tool (in-list additions)])
      (hash-set declared (tool-name tool) tool)))
  (define available
    (for/fold ([available (tool-history-state-available st)]) ([block (in-list content)])
      (define type (field block 'type))
      (cond
        [(equal? type "tool-addition") (hash-set available (field block 'toolName) #t)]
        [(equal? type "tool-removal") (hash-remove available (field block 'toolName))]
        [else available])))
  (define message-id (field message 'id))
  (define update
    (make-jobject
     (append (if (absent? message-id) '() (list (cons 'messageId message-id)))
             (list (cons 'additions additions)))))
  (struct-copy tool-history-state st
               [declared declared]
               [available available]
               [rev-updates (cons update (tool-history-state-rev-updates st))]))

;; source: packages/core/session/src/tool-history.ts (ToolHistoryProjection.apply)
(define (tool-history-apply st e)
  (define type (session-event-type e))
  (cond
    [(equal? type "request/header")
     (apply-header st (session-event-seq e) (session-event-data e))]
    [(equal? type "developer/message")
     (apply-developer-message st (session-event-data e))]
    [else st]))

;; source: packages/core/session/src/tool-history.ts (ToolHistoryProjection.snapshot)
(define (tool-history-snapshot st)
  (define active (tool-history-state-active st))
  (define available (tool-history-state-available st))
  ;; A log written before update records existed has headers without matching updates.
  (if (or (not (= (length active) (hash-count available)))
          (for/or ([tool (in-list active)])
            (not (hash-ref available (tool-name tool) #f))))
      (jobject 'tools active 'updates '())
      (jobject 'tools (tool-history-state-tools st)
               'updates (reverse (tool-history-state-rev-updates st)))))
