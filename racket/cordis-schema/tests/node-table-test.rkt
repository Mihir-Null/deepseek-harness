#lang racket/base
;; Differential test against the vendored Schemastery: every row of tests/data/node-table.rktd
;; holds results that Schemastery computed under Node (type strings, the JSON form, resolved
;; values or error messages, the rewritten input, simplification, i18n, the loader's raw-config
;; comparison, and regular-expression matches), and cordis-schema must produce the same.
;; Regenerate the table with
;; `node --experimental-transform-types tests/gen/gen-node-table.mjs`; this test needs no Node.

(require rackunit
         racket/runtime-path
         "support/node-table.rkt")

(define-runtime-path table-path "data/node-table.rktd")

(define-values (counts failures) (check-node-table table-path))

(test-case "cordis-schema agrees with Schemastery on every row of the table"
  (for ([failure (in-list failures)]
        [_ (in-range 20)])
    (eprintf "~a\n" failure))
  (check-equal? (length failures) 0))

(test-case "the table is as large as the contract requires"
  (check-true (>= (hash-ref counts 'schemas) 150))
  (check-true (>= (hash-ref counts 'cases) 150))
  (check-true (>= (hash-ref counts 'hydrated) 150))
  (check-true (>= (hash-ref counts 'simplify) 40))
  (check-true (>= (hash-ref counts 'i18n) 10))
  (check-true (>= (hash-ref counts 'diff) 30))
  (check-true (>= (hash-ref counts 'patterns) 1000)))
