#lang racket/base
;; The `cordis-schema` collection: the schema DSL every plugin uses for its Config, the port of
;; Schemastery as vendored in vendor/schemastery, with cosmokit's volatile references and the
;; loader's raw-config comparison. Interface contract: docs/racket/contracts/cordis-schema.md.
;;
;; A schema is an immutable value that is applicable: `(s data)` validates `data`, fills
;; defaults and returns the resolved value, or raises `exn:fail:schema` whose message is
;; Schemastery's. Config values are jvalues from cordis-data; `(void)` stands for JavaScript's
;; `undefined`.

(require "private/api.rkt"
         "private/forms.rkt"
         "volatile.rkt")

(provide (all-from-out "private/api.rkt")
         ;; (schema-object* option ... [key schema-expr] ...): an object schema with unquoted
         ;; keys.
         schema-object*
         ;; (define-config name option ... field ...): an object schema and one accessor per
         ;; field.
         define-config
         (all-from-out "volatile.rkt"))
