#lang info

(define collection "cordis-yaml")
(define version "0.1")
(define pkg-desc
  "The YAML dialect of cordis.yml (js-yaml compatible reader and writer) and the !!js evaluator")
(define deps '("base" "cordis-data"))
(define build-deps '("rackunit-lib"))
;; tests/gen holds the Node generator of the differential table; tests/support holds helpers.
(define test-omit-paths '("tests/gen" "tests/support"))
