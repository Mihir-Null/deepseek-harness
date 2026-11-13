#lang racket/base
;; The `cordis-yaml/js-expr` module: `!!js` expression nodes, the parser and its S-expression
;; AST, the evaluator, environments, host objects and the Node `process` object.
;; Interface contract: docs/racket/contracts/cordis-yaml.md, sections 3 to 6.
;;
;; `js-eval` implements a stated subset of JavaScript with JavaScript's semantics and raises
;; exn:fail:js-expr:unsupported for anything else; it never approximates. Values: (void) is
;; undefined, 'null is null, numbers are reals, arrays are lists, plain objects are jobjects,
;; functions are procedures, and host objects implement `gen:js-object`.

(require racket/contract/base
         cordis-data
         "private/expr.rkt"
         "private/js-builtins.rkt"
         "private/js-error.rkt"
         "private/js-eval.rkt"
         "private/js-object.rkt"
         "private/js-process.rkt"
         "private/js-value.rkt")

(define bindings/c (hash/c (or/c string? symbol?) any/c))
(define lookup/c (or/c #f (-> string? (-> any) any)))
(define fallback/c (or/c #f (-> string? js-env? any)))
(define env-source/c
  (or/c hash? jobject? environment-variables? (-> string? (or/c string? #f))))
(define directory/c (or/c path-string? (-> path-string?)))

(provide
 ;; Generic interface of host objects: implement `js-get-property`, and `js-call-method` when
 ;; a method call must differ from reading the property and calling it.
 gen:js-object
 (struct-out exn:fail:js-expr)
 (struct-out exn:fail:js-expr:syntax)
 (struct-out exn:fail:js-expr:unsupported)
 ;; Expression nodes; the same bindings as in `cordis-yaml`.
 js-expr?
 make-js-expr
 js-expr-source
 js-expr-srcloc
 (contract-out
  ;; ---- parsing ----
  ;; The AST of the contract's section 4: plain lists, symbols, strings, numbers, booleans.
  [js-parse (-> string? list?)]

  ;; ---- evaluation ----
  [js-eval (-> (or/c js-expr? string?) js-env? any)]
  ;; Replaces every expression node inside lists and objects by its value.
  [js-interpolate (-> any/c js-env? any)]
  ;; JavaScript's Boolean(v).
  [js-truthy? (-> any/c boolean?)]
  [make-js-env (->* (bindings/c) (#:lookup lookup/c #:globals (hash/c string? any/c)) js-env?)]
  [js-env? predicate/c]
  ;; The caller's bindings with every key a string.
  [js-env-bindings (-> js-env? hash?)]
  [js-standard-globals (hash/c string? any/c)]
  ;; Called with the source and the environment in place of raising unsupported.
  [current-js-fallback (parameter/c fallback/c)]

  ;; ---- host objects ----
  [js-object? predicate/c]
  ;; (void) for an absent property.
  [js-get-property (-> js-object? string? any)]
  [js-call-method (-> js-object? string? list? any)]
  [make-js-object (->* ((-> string? any)) ((or/c #f (-> string? list? any))) js-object?)]
  [make-node-process-object
   (->* ()
        (#:env env-source/c
         #:cwd directory/c
         #:platform string?
         #:exec-path (or/c path-string? #f)
         #:resolve (or/c #f (-> string? string? string?))
         #:homedir (or/c path-string? #f)
         #:extra (hash/c string? any/c))
        js-object?)]))
