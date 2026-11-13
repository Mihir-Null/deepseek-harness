#lang racket/base
;; The session header: validated storage metadata that is kept outside the event log.
;;
;; A `session-header` wraps the jobject it was read from or built as, so unknown keys and the
;; original key order survive `session-header->jvalue`. Validation raises `exn:fail:session`
;; with the dsh messages, in the dsh order.
;; source: packages/core/session/src/types.ts:95-136, packages/core/session/src/index.ts:98-161

(require cordis-data
         "base.rkt"
         "../lossless.rkt")

(provide session-header?
         make-session-header
         jvalue->session-header
         session-header->jvalue
         session-header-version
         session-header-id
         session-header-created-at
         session-header-cwd
         session-header-parent-session
         session-header-seeded?
         session-header-origin
         session-header-delegation-depth
         session-header-agent-preset)

(struct session-header (jv)
  #:property prop:equal+hash
  (list (lambda (a b recur) (recur (session-header-jv a) (session-header-jv b)))
        (lambda (h recur) (recur (session-header-jv h)))
        (lambda (h recur) (recur (session-header-jv h))))
  #:property prop:custom-write
  (lambda (h port mode)
    (write-string "#<session-header " port)
    (write-string (jvalue->string (session-header-jv h)) port)
    (write-string ">" port)))

;; `Number.isSafeInteger(v) && v >= 0` on a value that already passed the lossless check.
(define (count? v)
  (and (safe-integer? v) (>= v 0)))

;; `isAbsolute` of node:path on the host platform.
(define (absolute-path-string? s)
  (and (path-string? s) (complete-path? s)))

;; validate! : string? jobject? -> void?
;; source: packages/core/session/src/index.ts (validateSessionHeader)
(define (validate! id record)
  (define (present? key) (jhas? record key))
  (define (ref key) (jref record key absent))
  (when (present? 'seedLength)
    (raise-session-error "session header has invalid field \"seedLength\""))
  (unless (js-strict-equal? (ref 'version) session-format-version)
    (raise-session-error "session header version must be ~a, got ~a"
                         session-format-version (js-string (ref 'version))))
  (unless (js-strict-equal? (ref 'id) id)
    (raise-session-error "session header id \"~a\" does not match session id \"~a\""
                         (js-string (ref 'id)) id))
  (unless (count? (ref 'createdAt))
    (raise-session-error "session header createdAt must be a non-negative safe integer"))
  (when (present? 'cwd)
    (unless (string? (ref 'cwd))
      (raise-session-error "session header cwd must be a string"))
    (unless (absolute-path-string? (ref 'cwd))
      (raise-session-error "session header cwd must be an absolute path, got \"~a\""
                           (ref 'cwd))))
  (when (and (present? 'parentSession) (not (string? (ref 'parentSession))))
    (raise-session-error "session header parentSession must be a string"))
  (unless (boolean? (ref 'isSeeded))
    (raise-session-error "session header isSeeded must be a boolean"))
  (when (and (present? 'origin) (not (equal? (ref 'origin) "subagent")))
    (raise-session-error "session header origin must be \"subagent\""))
  (when (and (present? 'delegationDepth) (not (count? (ref 'delegationDepth))))
    (raise-session-error "session header delegationDepth must be a non-negative safe integer"))
  (when (and (present? 'agentPreset) (not (string? (ref 'agentPreset))))
    (raise-session-error "session header agentPreset must be a string")))

;; jvalue->session-header : string? any/c -> session-header?
;; Validates `jv` as the header of session `id`. The stored form is the lossless normal form
;; of `jv`, which is `jv` itself when it is already normal.
(define (jvalue->session-header id jv)
  (unless (lossless-json? jv)
    (raise-session-error "session header is not losslessly JSON-serializable"))
  (define record (snapshot-json jv))
  (unless (jobject? record)
    (raise-session-error "session header is not a plain JSON record"))
  (validate! id record)
  (session-header record))

;; Keys in the order dsh writes them; an optional key is written unless its value is `absent`.
;; source: packages/core/session/src/index.ts:1272-1282
(define (make-session-header #:id id
                             #:created-at created-at
                             #:seeded? [seeded? #f]
                             #:cwd [cwd absent]
                             #:parent-session [parent-session absent]
                             #:origin [origin absent]
                             #:delegation-depth [delegation-depth absent]
                             #:agent-preset [agent-preset absent])
  (define (optional key value)
    (if (absent? value) '() (list (cons key value))))
  (define members
    (append (list (cons 'version session-format-version)
                  (cons 'id id)
                  (cons 'createdAt created-at))
            (optional 'cwd cwd)
            (optional 'parentSession parent-session)
            (list (cons 'isSeeded seeded?))
            (optional 'origin origin)
            (optional 'delegationDepth delegation-depth)
            (optional 'agentPreset agent-preset)))
  (when (for/or ([member (in-list members)]) (void? (cdr member)))
    (raise-session-error "session header is not losslessly JSON-serializable"))
  (jvalue->session-header id (make-jobject members)))

(define (session-header->jvalue h)
  (session-header-jv h))

(define (optional-ref h key)
  (jref (session-header-jv h) key #f))

(define (session-header-version h) session-format-version)
(define (session-header-id h) (jref (session-header-jv h) 'id))
(define (session-header-created-at h) (inexact->exact (jref (session-header-jv h) 'createdAt)))
(define (session-header-cwd h) (optional-ref h 'cwd))
(define (session-header-parent-session h) (optional-ref h 'parentSession))
(define (session-header-seeded? h) (jref (session-header-jv h) 'isSeeded))
(define (session-header-origin h) (optional-ref h 'origin))
(define (session-header-agent-preset h) (optional-ref h 'agentPreset))

(define (session-header-delegation-depth h)
  (define depth (optional-ref h 'delegationDepth))
  (and depth (inexact->exact depth)))
