#lang racket/base
;; Tests of the event-type catalogue constants: rule 34 of the dsh-session contract.
;; Mirrors the name list of packages/core/session/tests/gen-persistence-catalog.spec.ts: the
;; generator itself is a dsh build tool and has no counterpart here.

(require rackunit
         racket/file
         racket/list
         racket/set
         dsh-session/types
         dsh-session/events
         "support/log.rkt")

(test-case "rule 34: the known set has 63 names"
  (check-equal? (set-count known-session-event-types) 63)
  (for ([name (in-set known-session-event-types)])
    (check-true (string? name))
    (check-true (immutable? name))))

(test-case "rule 34: every type declared in this package is a known type"
  (check-equal? (length core-session-event-types) 14)
  (for ([declaration (in-list core-session-event-types)])
    (check-true (set-member? known-session-event-types (session-event-type-tag declaration))
                (session-event-type-tag declaration)))
  (check-equal? (length (remove-duplicates (map session-event-type-tag core-session-event-types)))
                14))

(test-case "rule 34: the surface and projection types are known types"
  (check-true (subset? surface-event-types known-session-event-types))
  (check-true (subset? message-projection-event-types known-session-event-types))
  (check-equal? (set-count surface-event-types) 5))

(test-case "rule 34: the types that the packages above declare are known"
  (for ([name (list "llm/retry" "llm/retry-started" "agent/inbox/spliced" "model/selection"
                    "tool/ptc-dispatch" "tool/ptc-dispatch-start")])
    (check-true (set-member? known-session-event-types name) name)))

(test-case "rule 34: a plugin record type is never a known type"
  (for ([name (in-set known-session-event-types)])
    (check-false (plugin-record-type? name) name)))

(test-case "rule 34: membership does not depend on how the string was made"
  (check-true (set-member? known-session-event-types (string-copy "tool/call")))
  (check-true (set-member? surface-event-types (string-append "tool/" "result")))
  (check-false (set-member? known-session-event-types "tool/unknown")))

(test-case "rule 34: the names are the ones in the dsh source"
  (define source-path
    (repository-file "packages" "core" "session" "src" "known-event-types.ts"))
  (cond
    [(not source-path)
     (displayln
      "known type comparison skipped: packages/core/session/src/known-event-types.ts not found"
      (current-error-port))]
    [else
     (define source (file->string source-path))
     (define (names-of constant)
       (define body
         (cadr (regexp-match (pregexp (string-append constant "[^=]*= new Set\\(\\[([^]]*)\\]"))
                             source)))
       (map cadr (regexp-match* #px"'([^']+)'" body #:match-select values)))
     (define known (names-of "KNOWN_SESSION_EVENT_TYPES"))
     (check-equal? (length known) 63)
     (check-equal? (list->set known) known-session-event-types)
     (check-equal? (list->set (names-of "MESSAGE_PROJECTION_EVENT_TYPES"))
                   message-projection-event-types)]))
