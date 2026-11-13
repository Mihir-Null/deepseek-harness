#lang info

(define collection "cordis-schema")
(define version "0.1")
(define pkg-desc
  "Schemastery config schemas over cordis-data values, with cosmokit's volatile references")
(define deps '("base" "cordis-data"))
(define build-deps '("rackunit-lib"))
;; tests/gen holds the Node generator of the differential table.
(define test-omit-paths '("tests/gen"))
