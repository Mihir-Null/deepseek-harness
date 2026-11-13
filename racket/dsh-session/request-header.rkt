#lang racket/base
;; Reconstruction of the request header from `request/header` events: the canonical form of
;; a header, equality of two canonical headers, and the fold that yields the header in force
;; after the last snapshot of a log.
;;
;; `header-equal?` compares tool schemas as JSON text, so it is sensitive to the key order
;; inside a tool schema. Config equality is a private copy of the rule of `callConfigEquals`,
;; because the package that owns the call config sits above this one.
;; source: packages/core/session/src/request-header.ts, packages/llm/llm/src/call-config.ts:67-77

(require racket/contract/base
         cordis-data
         "types.rkt"
         (only-in "private/base.rkt" record? field js-strict-equal?))

(provide
 (contract-out
  ;; `{config, adapterDefaults?, tools?}`: `adapterDefaults` is kept only when a marker is
  ;; true and `tools` only when non-empty.
  [canonical-header (-> record? jobject?)]
  ;; Field-wise equality over canonical headers; tool schemas compare in order.
  [header-equal? (-> record? record? boolean?)]
  ;; The canonical form of the latest `request/header` in `events`, or `from`.
  [fold-request-header
   (->* ((listof session-event?)) ((or/c record? #f)) (or/c record? #f))]))

;; source: packages/core/session/src/request-header.ts (canonicalHeader)
(define (canonical-header header)
  (define config (field header 'config))
  (define defaults (field header 'adapterDefaults))
  (define tools (field header 'tools))
  (make-jobject
   (append (if (absent? config) '() (list (cons 'config config)))
           (if (or (eq? (field defaults 'reasoningEffort) #t) (eq? (field defaults 'maxTokens) #t))
               (list (cons 'adapterDefaults defaults))
               '())
           (if (and (pair? tools) (list? tools))
               (list (cons 'tools tools))
               '()))))

;; source: packages/llm/llm/src/call-config.ts (callConfigEquals)
(define (config-equal? a b)
  (define (same? key)
    (js-strict-equal? (field a key) (field b key)))
  (define stop-a (field a 'stop))
  (define stop-b (field b 'stop))
  (and (same? 'provider)
       (same? 'model)
       (same? 'reasoningEffort)
       (same? 'temperature)
       (same? 'maxTokens)
       (cond
         [(or (absent? stop-a) (absent? stop-b)) (and (absent? stop-a) (absent? stop-b))]
         [(and (list? stop-a) (list? stop-b))
          (and (= (length stop-a) (length stop-b))
               (andmap js-strict-equal? stop-a stop-b))]
         [else (js-strict-equal? stop-a stop-b)])))

(define (tool-list header)
  (define tools (field header 'tools))
  (if (list? tools) tools '()))

;; source: packages/core/session/src/request-header.ts (headerEquals)
(define (header-equal? a b)
  (define defaults-a (field a 'adapterDefaults))
  (define defaults-b (field b 'adapterDefaults))
  (define tools-a (tool-list a))
  (define tools-b (tool-list b))
  (and (config-equal? (field a 'config) (field b 'config))
       (js-strict-equal? (field defaults-a 'reasoningEffort) (field defaults-b 'reasoningEffort))
       (js-strict-equal? (field defaults-a 'maxTokens) (field defaults-b 'maxTokens))
       (= (length tools-a) (length tools-b))
       (for/and ([tool-a (in-list tools-a)] [tool-b (in-list tools-b)])
         (string=? (jvalue->string tool-a) (jvalue->string tool-b)))))

;; source: packages/core/session/src/request-header.ts (foldRequestHeader)
(define (fold-request-header events [from #f])
  (for/fold ([state from]) ([e (in-list events)])
    (cond
      [(equal? (session-event-type e) "request/header")
       (define header (field (session-event-data e) 'header))
       (unless (record? header)
         (raise-argument-error 'fold-request-header
                               "a request/header event whose data has a header object" e))
       (canonical-header header)]
      [else state])))
