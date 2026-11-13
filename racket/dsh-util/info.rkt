#lang info

(define collection "dsh-util")
(define version "0.1")
(define pkg-desc
  "DeepSeek Harness utility layer: harness errors, branded ids, Harness home paths, atomic writes, timeouts, retention, time and recurrence")
(define deps '("base" "cordis" "cordis-data"))
(define build-deps '("rackunit-lib"))
;; tests/gen holds the Node generators of the checked-in expectation tables; tests/data and
;; tests/support hold data and helpers that are not test modules.
(define test-omit-paths '("tests/gen" "tests/data" "tests/support"))
(define compile-omit-paths '("tests/gen" "tests/data"))
