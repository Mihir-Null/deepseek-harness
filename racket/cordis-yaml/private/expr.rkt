#lang racket/base
;; Provides the `js-expr` struct: a `!!js` expression node, read from YAML and not yet
;; evaluated. Two nodes are `equal?` when their sources are; the location and the cached parse
;; do not take part.

(require racket/contract/base)

;; `cordis-yaml` and `cordis-yaml/js-expr` both export the first four bindings; the contracts
;; are attached here so that the two modules export the same bindings and a client may require
;; both.
(provide (contract-out
          [js-expr? predicate/c]
          [make-js-expr (->* (string?) ((or/c srcloc? #f)) js-expr?)]
          [js-expr-source (-> js-expr? string?)]
          ;; Where the node's tag starts in the YAML text it was read from, or #f.
          [js-expr-srcloc (-> js-expr? (or/c srcloc? #f))])
         js-expr-cached-ast
         set-js-expr-cached-ast!)

;; source : immutable string. srcloc : srcloc or #f. cached-ast : #f, or the parse of `source`
;; and its position table as the evaluator stored them.
(struct js-expr (source srcloc [cached-ast #:mutable])
  #:constructor-name construct-js-expr
  #:omit-define-syntaxes
  #:property prop:equal+hash
  (list (lambda (a b recur) (string=? (js-expr-source a) (js-expr-source b)))
        (lambda (a recur) (equal-hash-code (js-expr-source a)))
        (lambda (a recur) (equal-secondary-hash-code (js-expr-source a))))
  #:methods gen:custom-write
  [(define (write-proc e port mode)
     (write-string "#<js-expr " port)
     (write-string (js-expr-source e) port)
     (write-string ">" port))])

;; make-js-expr : string? [(or/c srcloc? #f)] -> js-expr?
(define (make-js-expr source [srcloc #f])
  (construct-js-expr (string->immutable-string source) srcloc #f))
