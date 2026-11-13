#lang racket/base
;; The plugin struct API (contract section 6). `cordis/plugin` and `cordis` both re-export
;; these bindings.
(require racket/contract/base
         "core.rkt")

(provide
 prop:config-schema
 (contract-out
  ;; `apply` is called as (apply ctx config); its result is an effect result.
  ;; `#:inject` lists required services: keys, pairs (key . interception-config), or a hash
  ;; from key to interception config. `#:config` is #f, a procedure that returns the
  ;; validated config or raises, or a value with `prop:config-schema`.
  ;; `#:custodian 'inherit` runs the plugin under the custodian of the fiber it is mounted on.
  [make-plugin (->* ((and/c procedure? (procedure-arity-includes/c 2)))
                    (#:name (or/c string? symbol? #f)
                     #:inject inject/c
                     #:config schema/c
                     #:provides (listof key?)
                     #:custodian (or/c 'own 'inherit)
                     #:meta hash?)
                    plugin?)]
  [plugin? (-> any/c boolean?)]
  [plugin-name (-> plugin? (or/c string? #f))]
  [plugin-inject (-> plugin? inject/c)]
  [plugin-config-schema (-> plugin? schema/c)]
  [plugin-provides (-> plugin? (listof symbol?))]
  [plugin-apply (-> plugin? procedure?)]
  [plugin-meta (-> plugin? hash?)]
  [plugin-custodian-mode (-> plugin? (or/c 'own 'inherit))]
  [config-schema? (-> any/c boolean?)]))

(define inject/c
  (or/c (listof (or/c key? (cons/c key? any/c)))
        (hash/c key? any/c #:flat? #t)))

(define schema/c
  (or/c #f config-schema? (and/c procedure? (procedure-arity-includes/c 1))))

(define (make-plugin apply
                     #:name [name #f]
                     #:inject [inject '()]
                     #:config [schema #f]
                     #:provides [provides '()]
                     #:custodian [mode 'own]
                     #:meta [meta (hasheq)])
  (plugin (if (symbol? name) (symbol->string name) name)
          (cond
            [(hash? inject) (for/hasheq ([(key config) (in-hash inject)])
                              (values (->key key) config))]
            [else (for/list ([entry (in-list inject)])
                    (if (pair? entry) (cons (->key (car entry)) (cdr entry)) (->key entry)))])
          schema
          (map ->key provides)
          apply
          meta
          mode
          apply))
