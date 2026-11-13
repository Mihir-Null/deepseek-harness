#lang info
;; Package description for the session data plane and store: one collection, `dsh-session`.
(define collection "dsh-session")
(define version "0.1")
(define pkg-desc
  "Append-only session event log, surface fold, derived history, request folds and the store")
(define deps '("base" "cordis" "cordis-data" "dsh-util"))
(define build-deps '("rackunit-lib"))
