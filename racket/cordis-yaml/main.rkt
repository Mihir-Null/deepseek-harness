#lang racket/base
;; The `cordis-yaml` collection: reads and writes the YAML dialect dsh uses for cordis.yml,
;; patch files and snapshot manifests (js-yaml's JSON schema plus the `!!js` scalar tag).
;; Interface contract: docs/racket/contracts/cordis-yaml.md.
;;
;; Mappings are read as cordis-data jobjects in document order, sequences as lists, and a
;; `!!js` scalar as a `js-expr` node that the reader does not evaluate; evaluation is in
;; `cordis-yaml/js-expr`. The writer's text is what js-yaml's `dump` writes for the same data.

(require racket/contract/base
         racket/port
         cordis-data
         "private/expr.rkt"
         "private/yaml-error.rkt"
         "private/yaml-read.rkt"
         "private/yaml-write.rkt")

(define input/c (or/c string? bytes? input-port?))
(define schema/c (or/c 'entry-list 'json))
(define line-width/c (or/c #f exact-positive-integer?))

(provide
 (struct-out exn:fail:yaml)
 (contract-out
  ;; The single document of the input; (void) when the input holds no document.
  [yaml-read (->* (input/c) (#:source any/c #:schema schema/c) any)]
  ;; Every document of the input, in order.
  [yaml-read-all (->* (input/c) (#:source any/c #:schema schema/c) list?)]
  ;; Writes the text js-yaml's dump produces; `line-width` #f means no folding.
  [yaml-write (->* (any/c) (output-port? #:line-width line-width/c) void?)]
  [yaml->string (->* (any/c) (#:line-width line-width/c) string?)]
  ;; Deep check of what the writer accepts.
  [yaml-value? predicate/c]
  ;; Every js-expr becomes the object {"__jsExpr": source}, dsh's form of an expression node.
  [yaml-value->jvalue (-> any/c any/c)]
  ;; Every object with a string "__jsExpr" member becomes a js-expr.
  [jvalue->yaml-value (-> any/c any/c)]
  [js-expr? predicate/c]
  [make-js-expr (->* (string?) ((or/c srcloc? #f)) js-expr?)]
  [js-expr-source (-> js-expr? string?)]
  [js-expr-srcloc (-> js-expr? (or/c srcloc? #f))]))

;; The text of `in` and the name to report: a port is read to its end and decoded as UTF-8
;; with U+FFFD for each invalid sequence, as Node's readFile(path, 'utf8') decodes.
(define (input-text in source)
  (cond
    [(string? in) (values in source)]
    [(bytes? in) (values (bytes->string/utf-8 in #\UFFFD) source)]
    [else
     (values (bytes->string/utf-8 (port->bytes in) #\UFFFD)
             (or source
                 (let ([name (object-name in)])
                   (and (or (path? name) (string? name)) name))))]))

(define (yaml-read-all in #:source [source #f] #:schema [schema 'entry-list])
  (define-values (text name) (input-text in source))
  (load-yaml-documents text name (eq? schema 'entry-list)))

(define (yaml-read in #:source [source #f] #:schema [schema 'entry-list])
  (define-values (text name) (input-text in source))
  (define documents (load-yaml-documents text name (eq? schema 'entry-list)))
  (cond [(null? documents) (void)]
        [(null? (cdr documents)) (car documents)]
        [else
         (raise-yaml-error/no-mark
          "expected a single document in the stream, but found more" name)]))

(define (yaml->string v #:line-width [line-width 80])
  (dump-yaml v line-width))

;; The whole text is built before anything is written, so nothing is written when `v` is not
;; a value the writer accepts.
(define (yaml-write v [out (current-output-port)] #:line-width [line-width 80])
  (write-string (dump-yaml v line-width) out)
  (void))

(define (yaml-value->jvalue v)
  (cond [(js-expr? v) (jobject '__jsExpr (js-expr-source v))]
        [(list? v) (map yaml-value->jvalue v)]
        [(jobject? v) (jmap (lambda (k item) (yaml-value->jvalue item)) v)]
        [(hash? v) (yaml-value->jvalue (jmerge v))]
        [else v]))

(define (jvalue->yaml-value v)
  (cond [(list? v) (map jvalue->yaml-value v)]
        [(or (jobject? v) (hash? v))
         (define source (jref v '__jsExpr #f))
         (if (string? source)
             (make-js-expr source)
             (jmap (lambda (k item) (jvalue->yaml-value item)) v))]
        [else v]))
