#lang racket/base
;; Black-box specification tests for the declaration macro of cordis/plugin:
;; contract section 9 (docs/racket/contracts/cordis-kernel.md) and ADRs 0003
;; and 0005. Section 9 is outside the coverage this suite must have; the cases
;; are kept in their own file so that a difference in the macro's grammar
;; cannot stop the other spec files from compiling.
(require cordis
         cordis/plugin
         cordis/testing
         rackunit
         "support.rkt")

(define log (make-recorder))

;; source: contract 9, define-plugin grammar (lambda body form)
(define-plugin spec-greeter
  #:inject (spec-tools [spec-approval #:optional])
  #:provides (spec-greeting)
  (lambda (ctx config)
    (note! log (list 'handle?
                     (service-handle? spec-tools)
                     (eq? (use-context spec-tools) ctx)
                     (service-handle-key spec-tools)))
    (note! log (list 'tools (service-value spec-tools 'spec-tools)))
    (note! log (list 'approval spec-approval))
    (ctx-provide ctx 'spec-greeting (list 'hello config))
    (void)))

;; source: contract 9, "#:name name-expr ; string; defaults to the symbol name of id"
(define-plugin spec-named
  #:name "explicit-name"
  (lambda (ctx config) (void)))

;; source: contract 9, "Defines id as a plugin?"; ADR 0005
(test-case "plugin/define-plugin: defines a plugin value with its declaration"
  (check-true (plugin? spec-greeter))
  (check-equal? (plugin-name spec-greeter) "spec-greeter")
  (check-equal? (plugin-name spec-named) "explicit-name")
  (check-equal? (plugin-provides spec-greeter) '(spec-greeting)))

;; source: contract 9, plugin-info bullet
(test-case "plugin/define-plugin: plugin-info lists required and optional injections"
  (define plugin-info (optional-binding 'cordis/plugin 'plugin-info))
  (check-true (procedure? plugin-info) "cordis/plugin must export plugin-info")
  (when (procedure? plugin-info)
    (define info (plugin-info spec-greeter))
    (check-equal? (hash-ref info 'name) "spec-greeter")
    (check-equal? (hash-ref info 'inject) '(spec-tools))
    (check-equal? (hash-ref info 'optional) '(spec-approval))
    (check-equal? (hash-ref info 'provides) '(spec-greeting))
    (check-false (hash-ref info 'config-schema))
    ;; A plugin made by make-plugin has no optional keys.
    (define made (make-plugin (lambda (ctx config) (void)) #:inject '(spec-tools)))
    (check-equal? (hash-ref (plugin-info made) 'inject) '(spec-tools))
    (check-equal? (hash-ref (plugin-info made) 'optional) '())))

;; source: contract 9, "each required injected key is bound as a variable
;; holding (service-handle ctx 'key). An #:optional key is not part of the
;; inject list; its identifier ... expands to (ctx-get ctx 'key)"; ADR 0003
(test-case "plugin/define-plugin: required keys are handles, optional keys read through ctx-get"
  (with-root (ctx)
    (define f (ctx-plugin ctx spec-greeter 'config))
    (check-eq? (fiber-state f) 'pending)
    (check-equal? (hash-keys (fiber-inject f)) '(spec-tools))
    (ctx-provide ctx 'spec-tools 'the-tools)
    (await f)
    (check-equal? (notes log)
                  '((handle? #t #t spec-tools) (tools the-tools) (approval #f)))
    (check-equal? (ctx-get ctx 'spec-greeting) '(hello config))
    (check-equal? (fiber-name f) "spec-greeter")
    ;; The optional service is not an injection: providing it reloads nothing,
    ;; and the next activation reads the value.
    (ctx-provide ctx 'spec-approval 'granted)
    (yield-times 5)
    (settle f)
    (check-equal? (length (notes log)) 3)
    (fiber-restart! f)
    (check-equal? (list-ref (notes log) 5) '(approval granted))))
