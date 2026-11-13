#lang racket/base
;; Differential test against Node: every row of tests/data/node-table.rktd holds a result that
;; Node computed (JSON.stringify, JSON.parse, String(n), str.length, Buffer.byteLength, slice,
;; `<`, UTF-8 decoding, and the vendored cosmokit deepEqual), and cordis-data must produce the
;; same. Regenerate the table with
;; `node --experimental-transform-types tests/gen/gen-node-table.mjs`; this test needs no Node.

(require rackunit
         racket/runtime-path
         "support/node-table.rkt")

(define-runtime-path table-path "data/node-table.rktd")

(define-values (counts failures) (check-node-table table-path))

(test-case "cordis-data agrees with Node on every row of the table"
  (for ([failure (in-list failures)]
        [_ (in-range 20)])
    (eprintf "~a\n" failure))
  (check-equal? (length failures) 0))

(test-case "the table is as large as the contract requires"
  (check-true (>= (hash-ref counts 'stringify) 60))
  (for ([section (in-list '(parse parse-error numbers number-texts lengths slices truncations
                                  order utf8 equality))])
    (check-true (>= (hash-ref counts section) 40) (symbol->string section))))
