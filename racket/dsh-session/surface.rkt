#lang racket/base
;; The surface: the ordered view of the events that produce model messages, the checks an
;; event passes before it enters a log, and the derivation of message history.
;;
;; The fold is a pure function over an immutable `surface-state`. `surface-plan` validates one
;; event against a state and changes nothing; `surface-apply` returns the next state. A plan
;; is valid only for the state it was made from. Appending a node costs constant time; a
;; replacement and the first read of `surface-state-nodes` on a state cost time linear in the
;; node count.
;;
;; Every check raises `exn:fail:session` with the dsh message. The checks read the raw
;; envelope of an event, so they also report metadata that the accessors of
;; `dsh-session/types` hide.
;; source: packages/core/session/src/surface.ts, packages/core/session/src/index.ts:172-386

(require racket/contract/base
         racket/list
         racket/set
         racket/string
         cordis-data
         "types.rkt"
         (only-in "private/base.rkt"
                  raise-session-error record? field has-field? valid-seq? nonempty-string?
                  js-string js-strict-equal? json-deep-equal?)
         (only-in "private/names.rkt" surface-type-name?)
         (only-in "private/shape.rkt"
                  message-event-role message-event-violation settlement-violation
                  request-header-violation)
         (only-in "private/catalog.rkt" known-session-event-types message-projection-event-types)
         (only-in "private/event.rkt" jvalue->surface-op))

(provide
 (contract-out
  ;; ---- surface state ----
  [surface-state? predicate/c]
  ;; The state before event `base`: no nodes, next seq `base`.
  [surface-state-empty (->* () (#:base-seq session-log-offset?) surface-state?)]
  ;; Node seqs in model-visible order.
  [surface-state-nodes (-> surface-state? (listof session-seq?))]
  ;; The nodes from position `index` to the end, in order, in time linear in their number.
  [surface-state-nodes-from (-> surface-state? exact-nonnegative-integer? (listof session-seq?))]
  [surface-state-node-count (-> surface-state? exact-nonnegative-integer?)]
  ;; Count of applied positional replacements.
  [surface-state-replace-generation (-> surface-state? exact-nonnegative-integer?)]
  ;; Count of applied replacements and message projections.
  [surface-state-content-generation (-> surface-state? exact-nonnegative-integer?)]
  ;; Projected messages keyed by the seq of the event they replace the message of.
  [surface-state-projected-messages (-> surface-state? (and/c hash? immutable?))]
  ;; The seq the next event must have.
  [surface-state-next-seq (-> surface-state? session-log-offset?)]
  ;; The seq of the first event the state folded, or would fold.
  [surface-state-base-seq (-> surface-state? session-log-offset?)]
  ;; The projection definitions the state has applied, oldest first.
  [surface-state-projections (-> surface-state? (listof message-projection?))]
  ;; Raises when a definition the state has applied is not in `projections` (by identity).
  [check-surface-projections (-> surface-state? (listof message-projection?) void?)]

  [struct surface-replacement ([seq session-seq?]
                               [start session-seq?]
                               [end session-seq?]
                               [shadowed-seqs (listof session-seq?)])]
  [struct surface-fold-result ([nodes (listof session-seq?)]
                               [replacements (listof surface-replacement?)]
                               [projected-messages (and/c hash? immutable?)])]
  ;; `type` is a type tag; `project` maps an event and the history before it to the changed
  ;; messages, keyed by their original event seq, or raises.
  [struct message-projection ([type string?]
                              [project (-> session-event? projection-context? hash?)])]
  ;; `event-ref` reads a committed event, or an earlier member of the batch being planned.
  [struct projection-context ([nodes (listof session-seq?)]
                              [event-ref (-> exact-nonnegative-integer? any/c)]
                              [base-seq session-log-offset?]
                              [messages (and/c hash? immutable?)])]

  ;; ---- transitions ----
  [rename plan? surface-plan? predicate/c]
  ;; Validates `e` as the next event of `st`. `event-ref` returns the event at a seq, or #f.
  [surface-plan (-> surface-state?
                    session-event?
                    (-> exact-nonnegative-integer? any/c)
                    (listof message-projection?)
                    plan?)]
  ;; The replacement a plan performs, or #f.
  [surface-plan-replacement (-> plan? (or/c surface-replacement? #f))]
  ;; `plan` must have been made from `st`.
  [surface-apply (-> surface-state? plan? surface-state?)]
  [surface-step (-> surface-state?
                    session-event?
                    (-> exact-nonnegative-integer? any/c)
                    (listof message-projection?)
                    surface-state?)]
  ;; Folds a whole log from seq 0.
  [fold-surface (->* ((listof session-event?))
                     (#:projections (listof message-projection?))
                     surface-fold-result?)]

  ;; ---- derived history ----
  ;; The message one event derives to, or #f. A projected message for the event's seq wins.
  [derive-event-message (->* (session-event?) ((or/c hash? #f)) any/c)]
  ;; The message history of a whole log, in surface order.
  [derive-messages (->* ((listof session-event?))
                        (#:projections (listof message-projection?))
                        list?)]

  ;; ---- checks ----
  ;; The event-local rules on request headers, developer messages and tool failures.
  [validate-session-event-data (-> string? any/c string? void?)]
  ;; The event-local rules on `surfaceOp` and `sourceEventSeqs`; returns the operation.
  [validate-surface-metadata (-> session-event? (or/c 'append surface-replace? #f))]
  ;; The current-shape checks on request headers, messages and assistant settlements.
  [check-event-shape (-> string? any/c string? void?)]
  ;; Checks `data` against the declaration for `type` in `types`, when there is one.
  [check-declared-fields (-> (listof session-event-type?) string? any/c string? void?)]
  ;; The checks an event passes when it is imported on its own; returns the event.
  [check-session-event (-> session-event? session-event?)]

  ;; ---- predicates ----
  [surface-eligible-type? predicate/c]
  ;; A surface-eligible event that carries a `surfaceOp`.
  [surface-event? (-> session-event? boolean?)]
  ;; A surface event that entered the surface at its own position.
  [append-surface-event? (-> session-event? boolean?)]
  ;; A surface event that replaced a range.
  [replacement-surface-event? (-> session-event? boolean?)]))

;; ---- data ----

;; `rev-nodes` holds the node seqs newest first, so an append is one cons. `forward` caches
;; the model-visible order once it has been asked for, and is #f until then.
;; `rev-projections` holds the definitions applied so far, newest first.
(struct surface-state (base-seq
                       next-seq
                       rev-nodes
                       node-count
                       replace-generation
                       content-generation
                       projected-messages
                       rev-projections
                       [forward #:mutable]))

(struct surface-replacement (seq start end shadowed-seqs) #:transparent)
(struct surface-fold-result (nodes replacements projected-messages) #:transparent)
(struct message-projection (type project))
(struct projection-context (nodes event-ref base-seq messages))

;; `origin` is the state the plan was made from. `kind` is 'none, 'append, 'replace or
;; 'project; `payload` is #f, #f, `(list start-index end-index replacement)` or
;; `(cons projection messages)`.
(struct plan (origin seq kind payload))

(define (surface-state-empty #:base-seq [base 0])
  (surface-state base base '() 0 0 0 (hasheqv) '() '()))

(define (surface-state-nodes st)
  (or (surface-state-forward st)
      (let ([forward (reverse (surface-state-rev-nodes st))])
        (set-surface-state-forward! st forward)
        forward)))

(define (surface-state-nodes-from st index)
  (define count (surface-state-node-count st))
  (if (>= index count)
      '()
      (reverse (take (surface-state-rev-nodes st) (- count index)))))

(define (surface-state-projections st)
  (reverse (surface-state-rev-projections st)))

;; source: packages/core/session/src/surface.ts (SurfaceManager._assertProjections)
(define (check-surface-projections st projections)
  (for ([projection (in-list (surface-state-projections st))])
    (unless (memq projection projections)
      (raise-session-error
       (string-append "session message projection \"~a\" was removed or replaced; "
                      "restore the session with its owning plugin")
       (message-projection-type projection)))))

;; ---- predicates ----

(define (surface-eligible-type? v)
  (surface-type-name? v))

(define (raw-member e key)
  (jref (session-event->jvalue e) key absent))

;; source: packages/core/session/src/surface.ts (isSurfaceEvent, isAppendSurfaceEvent,
;;         isReplacementSurfaceEvent)
(define (surface-event? e)
  (and (surface-type-name? (session-event-type e))
       (not (absent? (raw-member e 'surfaceOp)))))

(define (append-surface-event? e)
  (and (surface-event? e) (equal? (raw-member e 'surfaceOp) "append")))

(define (replacement-surface-event? e)
  (and (surface-event? e) (not (equal? (raw-member e 'surfaceOp) "append"))))

;; ---- derived history ----

;; source: packages/core/session/src/surface.ts (deriveEventMessage)
(define (derive-event-message e [projected-messages #f])
  (define projected
    (and projected-messages (hash-ref projected-messages (session-event-seq e) #f)))
  (define type (session-event-type e))
  (define data (session-event-data e))
  (cond
    [projected projected]
    [(equal? type "user/message") (and (record? data) data)]
    [(member type '("system/message" "developer/message" "assistant/message"))
     (define message (field data 'message))
     (and (record? message)
          (not (null? (field message 'content)))
          message)]
    [(equal? type "tool/result")
     (define message (field data 'message))
     (and (record? message) message)]
    [else #f]))

(define (derive-messages events #:projections [projections '()])
  (define log (list->vector events))
  (define result (fold-surface events #:projections projections))
  (define projected (surface-fold-result-projected-messages result))
  (for*/list ([seq (in-list (surface-fold-result-nodes result))]
              [message (in-value (derive-event-message (vector-ref log seq) projected))]
              #:when message)
    message))

;; ---- event-local data rules ----

(define (tool-change-block? block)
  (and (record? block)
       (member (field block 'type) '("tool-addition" "tool-removal"))
       #t))

;; source: packages/core/session/src/surface.ts (validateSessionEventData)
(define (validate-session-event-data type data subject)
  (when (and (surface-type-name? type) (record? data))
    (define message (if (equal? type "user/message") data (field data 'message)))
    (when (record? message)
      (define developer-type? (equal? type "developer/message"))
      (define developer-role? (equal? (field message 'role) "developer"))
      (define content (field message 'content))
      (unless (eq? developer-type? developer-role?)
        (raise-session-error "~a developer/message and developer role must occur together"
                             subject))
      (when (and (not developer-role?) (list? content) (ormap tool-change-block? content))
        (raise-session-error "~a tool-change blocks require developer role" subject))
      (when (and developer-type? (list? content))
        (define has-additions?
          (for/fold ([has-additions? #f]) ([block (in-list content)]
                                           #:when (tool-change-block? block))
            (unless (nonempty-string? (field block 'toolName))
              (raise-session-error "~a ~a requires a nonempty toolName"
                                   subject (field block 'type)))
            (cond
              [(equal? (field block 'type) "tool-addition")
               (when (has-field? block 'tool)
                 (raise-session-error "~a tool-addition must omit inline tool definitions"
                                      subject))
               #t]
              [else has-additions?])))
        (when (if has-additions?
                  (not (valid-seq? (field data 'headerSeq)))
                  (has-field? data 'headerSeq))
          (raise-session-error
           "~a requires headerSeq exactly when tool additions are present" subject)))))
  (cond
    [(equal? type "request/header")
     (unless (record? data)
       (raise-session-error "~a data must be an object" subject))
     (define header (field data 'header))
     (unless (record? header)
       (raise-session-error "~a header must be an object" subject))
     (when (has-field? header 'system)
       (raise-session-error "~a must omit header.system; use system/message" subject))
     (when (null? (field header 'tools))
       (raise-session-error "~a must omit empty tools" subject))
     (define defaults (field header 'adapterDefaults))
     (when (and (record? defaults) (zero? (jcount defaults)))
       (raise-session-error "~a must omit empty adapterDefaults" subject))]
    [(equal? type "tool/result")
     (unless (record? data)
       (raise-session-error "~a data must be an object" subject))
     (unless (absent? (field data 'error))
       (unless (eq? (field (field data 'message) 'isError) #t)
         (raise-session-error "~a error requires message.isError === true" subject)))]
    [else (void)]))

;; ---- current-shape checks ----

(define (raise-violation subject violation)
  (when violation
    (raise-session-error "~a ~a" subject violation)))

;; source: packages/core/session/src/index.ts (assertCurrentLlmShape)
(define (check-event-shape type data subject)
  (cond
    [(equal? type "request/header")
     (raise-violation subject (request-header-violation data))]
    [(equal? type "assistant/attempt")
     (raise-violation subject (settlement-violation data))]
    [(message-event-role type)
     (raise-violation subject (message-event-violation type data))
     (when (equal? type "assistant/message")
       (raise-violation subject (settlement-violation data)))]
    [else (void)]))

(define (check-declared-fields types type data subject)
  (define declaration
    (for/first ([candidate (in-list types)]
                #:when (equal? (session-event-type-tag candidate) type))
      candidate))
  (when declaration
    (raise-violation subject (session-event-type-violation declaration data))))

;; source: packages/core/session/src/index.ts (adoptSessionEvent)
(define (check-session-event e)
  (define subject (format "session event at seq ~a" (session-event-seq e)))
  (define type (session-event-type e))
  (define data (session-event-data e))
  (validate-session-event-data type data subject)
  (validate-surface-metadata e)
  (raise-violation subject (message-event-violation type data))
  e)

;; ---- event-local surface metadata ----

;; source: packages/core/session/src/surface.ts (surfaceOpOf)
(define (surface-op-of e)
  (define type (session-event-type e))
  (define raw-op (raw-member e 'surfaceOp))
  (cond
    [(not (surface-type-name? type))
     (cond
       ;; An unknown ignorable record keeps opaque metadata and never touches the surface.
       [(and (not (set-member? known-session-event-types type)) (session-event-ignorable? e))
        #f]
       [(not (absent? raw-op))
        (raise-session-error
         "session event \"~a\" is not surface-eligible and cannot carry surfaceOp" type)]
       [(not (absent? (raw-member e 'sourceEventSeqs)))
        (raise-session-error
         "session event \"~a\" is not surface-eligible and cannot carry sourceEventSeqs" type)]
       [else #f])]
    [(absent? raw-op)
     (raise-session-error
      "session event \"~a\" is surface-eligible and requires a surfaceOp marker" type)]
    [(equal? raw-op "append") 'append]
    [(not (record? raw-op))
     (raise-session-error "session event \"~a\" carries an invalid surfaceOp" type)]
    [else
     (or (jvalue->surface-op raw-op)
         (raise-session-error "session event \"~a\" carries an invalid replace surfaceOp"
                              type))]))

;; check-source-references : session-event? (listof session-seq?) -> void?
;; `shadowed` holds the surface nodes a replacement removes; every one must be cited.
;; source: packages/core/session/src/surface.ts (assertSourceEventReferences)
(define (check-source-references e shadowed)
  (define type (session-event-type e))
  (define seq (session-event-seq e))
  (define raw (raw-member e 'sourceEventSeqs))
  (when (and (equal? type "assistant/message") (not (absent? raw)))
    (raise-session-error
     "assistant/message embeds its source stream and cannot carry sourceEventSeqs"))
  (define sources (make-hasheqv))
  (unless (absent? raw)
    (unless (list? raw)
      (raise-session-error "sourceEventSeqs on event at seq ~a must be an array when present"
                           seq))
    (when (null? raw)
      (raise-session-error "sourceEventSeqs must not be empty"))
    (define non-earlier
      (for/fold ([non-earlier #f]) ([source (in-list raw)])
        (unless (valid-seq? source)
          (raise-session-error
           (string-append "session event \"~a\" sourceEventSeqs must densely contain "
                          "non-negative safe integers")
           type))
        (define exact-source (inexact->exact source))
        (hash-set! sources exact-source #t)
        (or non-earlier (and (>= exact-source seq) exact-source))))
    (unless (= (hash-count sources) (length raw))
      (raise-session-error "sourceEventSeqs must not contain duplicates"))
    (when non-earlier
      (raise-session-error "sourceEventSeqs must reference earlier events: ~a >= current seq ~a"
                           non-earlier seq)))
  (define missing
    (for/list ([node (in-list shadowed)] #:unless (hash-ref sources node #f)) node))
  (unless (null? missing)
    (raise-session-error
     "surface replace: sourceEventSeqs must include every shadowed surface node; missing ~a"
     (string-join (map number->string missing) ", "))))

;; source: packages/core/session/src/surface.ts (validateSurfaceMetadata)
(define (validate-surface-metadata e)
  (define op (surface-op-of e))
  (define seq (session-event-seq e))
  (when (and (surface-replace? op)
             (or (>= (surface-replace-start-seq op) seq)
                 (>= (surface-replace-end-seq op) seq)))
    (raise-session-error
     "surface replace at seq ~a: startSeq and endSeq must reference earlier events" seq))
  (when op
    (check-source-references e '()))
  op)

;; ---- history rules ----

;; source: packages/core/session/src/surface.ts (assertDeveloperHeader)
(define (check-developer-header e event-ref)
  (define seq (session-event-seq e))
  (define data (session-event-data e))
  (validate-session-event-data "developer/message" data
                               (format "developer/message at seq ~a" seq))
  (define header-seq (field data 'headerSeq))
  (unless (absent? header-seq)
    (define header-event
      (and (valid-seq? header-seq) (< header-seq seq) (event-ref (inexact->exact header-seq))))
    (unless (and (session-event? header-event)
                 (equal? (session-event-type header-event) "request/header"))
      (raise-session-error
       "developer/message headerSeq must reference an earlier request/header"))
    (define header-tools
      (let ([tools (field (field (session-event-data header-event) 'header) 'tools)])
        (if (list? tools) tools '())))
    (define content
      (let ([blocks (field (field data 'message) 'content)])
        (if (list? blocks) blocks '())))
    (for ([block (in-list content)]
          #:when (equal? (field block 'type) "tool-addition"))
      (define name (field block 'toolName))
      (define definitions
        (for/list ([tool (in-list header-tools)]
                   #:when (js-strict-equal? (field tool 'name) name))
          tool))
      (unless (= (length definitions) 1)
        (raise-session-error
         "developer/message tool-addition \"~a\" must name exactly one tool in headerSeq ~a"
         (js-string name) (js-string header-seq)))
      (define definition (car definitions))
      (unless (and (string? (field definition 'description))
                   (record? (field definition 'parameters)))
        (raise-session-error
         (string-append "developer/message tool-addition \"~a\" requires a complete tool "
                        "definition in headerSeq ~a")
         (js-string name) (js-string header-seq)))
      (when (and (has-field? definition 'deferLoading)
                 (not (eq? (field definition 'deferLoading) #t)))
        (raise-session-error
         "developer/message referenced tool deferLoading must be true when present")))))

(define (node-index nodes seq)
  (index-of nodes seq eqv?))

;; replacement-range : (listof session-seq?) surface-replace? -> (values index index list)
;; source: packages/core/session/src/surface.ts (replacementRange)
(define (replacement-range nodes op)
  (define start (surface-replace-start-seq op))
  (define end (surface-replace-end-seq op))
  (define start-index (node-index nodes start))
  (unless start-index
    (raise-session-error "surface replace: start seq ~a not found in surface" start))
  (define end-index (node-index nodes end))
  (unless end-index
    (raise-session-error "surface replace: end seq ~a not found in surface" end))
  (when (> start-index end-index)
    (raise-session-error
     "surface replace: start seq ~a (index ~a) is after end seq ~a (index ~a)"
     start start-index end end-index))
  (values start-index
          end-index
          (take (drop nodes start-index) (add1 (- end-index start-index)))))

;; The data of a tool result with its message content set to null: the part a rewrite keeps.
(define (without-content data)
  (define record (if (record? data) data empty-jobject))
  (define message
    (let ([message (field record 'message)])
      (if (record? message) message empty-jobject)))
  (jset record 'message (jset message 'content 'null)))

;; source: packages/core/session/src/surface.ts (assertToolResultRewrite)
(define (check-tool-result-rewrite e shadowed event-ref)
  (when (equal? (session-event-type e) "tool/result")
    (unless (= (length shadowed) 1)
      (raise-session-error
       "tool/result surface replacement must rewrite exactly one current node"))
    (define original (event-ref (car shadowed)))
    (unless (and (session-event? original)
                 (equal? (session-event-type original) "tool/result"))
      (raise-session-error "tool/result surface replacement must target a current tool/result"))
    (unless (json-deep-equal? (without-content (session-event-data original))
                              (without-content (session-event-data e)))
      (raise-session-error "tool/result surface replacement may change only content"))))

;; source: packages/core/session/src/surface.ts (assertSystemHeadRewrite)
(define (check-system-head-rewrite e nodes start-index shadowed event-ref)
  (when (zero? start-index)
    (define head (event-ref (car nodes)))
    (when (and (session-event? head)
               (equal? (session-event-type head) "system/message")
               (not (and (equal? (session-event-type e) "system/message")
                         (= (length shadowed) 1))))
      (raise-session-error
       (string-append "surface replace: node 0 holds the system prompt and may be rewritten "
                      "only by a system/message over exactly that node")))))

;; ---- transitions ----

;; source: packages/core/session/src/surface.ts (planSurfaceEvent)
(define (surface-plan st e event-ref projections)
  (define seq (session-event-seq e))
  (define type (session-event-type e))
  (unless (= seq (surface-state-next-seq st))
    (raise-session-error "session event seq ~a is not contiguous; expected ~a"
                         seq (surface-state-next-seq st)))
  (define op (validate-surface-metadata e))
  (when (equal? type "developer/message")
    (check-developer-header e event-ref))
  (define projection
    (for/first ([candidate (in-list projections)]
                #:when (equal? (message-projection-type candidate) type))
      candidate))
  (cond
    [projection
     (define messages
       ((message-projection-project projection)
        e
        (projection-context (surface-state-nodes st)
                            event-ref
                            (surface-state-base-seq st)
                            (surface-state-projected-messages st))))
     (plan st seq 'project (cons projection messages))]
    [(set-member? message-projection-event-types type)
     (raise-session-error
      (string-append "session event \"~a\" requires a message projection; load its owning "
                     "plugin or supply its projection definition")
      type)]
    [(not op) (plan st seq 'none #f)]
    [(eq? op 'append) (plan st seq 'append #f)]
    [else
     (define nodes (surface-state-nodes st))
     (define-values (start-index end-index shadowed) (replacement-range nodes op))
     (check-source-references e shadowed)
     (check-tool-result-rewrite e shadowed event-ref)
     (check-system-head-rewrite e nodes start-index shadowed event-ref)
     (plan
      st seq 'replace
      (list start-index
            end-index
            (surface-replacement seq
                                 (surface-replace-start-seq op)
                                 (surface-replace-end-seq op)
                                 shadowed)))]))

(define (surface-plan-replacement p)
  (and (eq? (plan-kind p) 'replace)
       (caddr (plan-payload p))))

;; source: packages/core/session/src/surface.ts (applySurfacePlan)
(define (surface-apply st p)
  (unless (eq? st (plan-origin p))
    (raise-arguments-error 'surface-apply
                           "the plan was made from another surface state"
                           "plan seq" (plan-seq p)
                           "state next seq" (surface-state-next-seq st)))
  (define next-seq (add1 (surface-state-next-seq st)))
  (define payload (plan-payload p))
  (case (plan-kind p)
    [(append)
     (struct-copy surface-state st
                  [next-seq next-seq]
                  [rev-nodes (cons (plan-seq p) (surface-state-rev-nodes st))]
                  [node-count (add1 (surface-state-node-count st))]
                  [forward #f])]
    [(replace)
     (define nodes (surface-state-nodes st))
     (define start-index (car payload))
     (define end-index (cadr payload))
     (define replaced
       (append (take nodes start-index)
               (list (plan-seq p))
               (drop nodes (add1 end-index))))
     (struct-copy surface-state st
                  [next-seq next-seq]
                  [rev-nodes (reverse replaced)]
                  [node-count (length replaced)]
                  [replace-generation (add1 (surface-state-replace-generation st))]
                  [content-generation (add1 (surface-state-content-generation st))]
                  [forward replaced])]
    [(project)
     (define projection (car payload))
     (define used (surface-state-rev-projections st))
     (struct-copy surface-state st
                  [next-seq next-seq]
                  [projected-messages
                   (for/fold ([messages (surface-state-projected-messages st)])
                             ([(seq message) (in-hash (cdr payload))])
                     (hash-set messages seq message))]
                  [rev-projections (if (memq projection used) used (cons projection used))]
                  [content-generation (add1 (surface-state-content-generation st))])]
    [else (struct-copy surface-state st [next-seq next-seq])]))

(define (surface-step st e event-ref projections)
  (surface-apply st (surface-plan st e event-ref projections)))

;; source: packages/core/session/src/surface.ts (foldSurface)
(define (fold-surface events #:projections [projections '()])
  (define log (list->vector events))
  (define (event-ref seq)
    (and (< seq (vector-length log)) (vector-ref log seq)))
  (define-values (final rev-replacements)
    (for/fold ([st (surface-state-empty)] [rev-replacements '()])
              ([e (in-list events)])
      (define p (surface-plan st e event-ref projections))
      (define replacement (surface-plan-replacement p))
      (values (surface-apply st p)
              (if replacement (cons replacement rev-replacements) rev-replacements))))
  (surface-fold-result (surface-state-nodes final)
                       (reverse rev-replacements)
                       (surface-state-projected-messages final)))
