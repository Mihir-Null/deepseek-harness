#lang info

(define collection "cordis-data")
(define version "0.1")
(define pkg-desc
  "Ordered JSON value model with JavaScript-compatible JSON text, equality and length units")
(define deps '("base"))
(define build-deps '("rackunit-lib"))
;; tests/gen holds the Node generator and the one-off fuzz and benchmark drivers.
(define test-omit-paths '("tests/gen"))
