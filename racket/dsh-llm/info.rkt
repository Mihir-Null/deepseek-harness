#lang info
;; Package description for the model-provider layer: one collection, `dsh-llm`.
(define collection "dsh-llm")
(define version "0.1")
(define pkg-desc
  "Model-provider layer: message and stream vocabulary, the llm service and adapter seam, retry, DeepSeek and pi-ai routes, mock and replay providers")
(define deps '("base" "cordis" "cordis-data" "cordis-schema" "dsh-util" "dsh-session"))
(define build-deps '("rackunit-lib"))
;; tests/support holds helpers that are not test modules.
(define test-omit-paths '("tests/support"))
