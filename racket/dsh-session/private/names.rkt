#lang racket/base
;; Names that the declaration macro needs while it expands and that the run-time checks need
;; too: the five surface-eligible type tags and the plugin record grammar. The module has no
;; other dependency so that it can be required at both phases.

(provide surface-event-type-names
         surface-type-name?
         assistant-message-type-name
         plugin-record-type-name?)

;; source: packages/core/session/src/surface.ts (SURFACE_EVENT_TYPES)
(define surface-event-type-names
  '("system/message" "developer/message" "user/message" "assistant/message" "tool/result"))

;; The one surface-eligible type that embeds its source stream and takes no `sourceEventSeqs`.
(define assistant-message-type-name "assistant/message")

;; (surface-type-name? v) -> boolean?
;; True for a string that is one of the five surface-eligible type tags.
(define (surface-type-name? v)
  (and (string? v) (member v surface-event-type-names) #t))

;; source: packages/core/session/src/index.ts (PLUGIN_RECORD_TYPE)
(define plugin-record-type-rx
  #px"^plugin:[a-z0-9][a-z0-9._-]*(?:/[a-z0-9][a-z0-9._-]*)*$")

;; (plugin-record-type-name? v) -> boolean?
;; True for a string in the plugin record grammar: `plugin:` and slash-separated segments.
(define (plugin-record-type-name? v)
  (and (string? v) (regexp-match? plugin-record-type-rx v)))
