#lang racket/base
;; One-off fuzz driver, not part of `raco test`: checks cordis-data against tables of any size
;; produced by gen-node-table.mjs and exits nonzero on the first table with a mismatch.
;;
;;   node tests/gen/gen-node-table.mjs --scale 40 --seed 7 --out /tmp/fuzz-7.rktd
;;   racket tests/gen/fuzz.rkt /tmp/fuzz-7.rktd ...

(require "../support/node-table.rkt")

(module test racket/base)

(module+ main
  (define paths (vector->list (current-command-line-arguments)))
  (when (null? paths)
    (eprintf "usage: racket fuzz.rkt TABLE ...\n")
    (exit 2))
  (for ([path (in-list paths)])
    (define-values (counts failures) (check-node-table path))
    (printf "~a: ~a rows, ~a mismatches\n"
            path
            (for/sum ([count (in-hash-values counts)]) count)
            (length failures))
    (for ([(section count) (in-hash counts)])
      (printf "  ~a: ~a\n" section count))
    (for ([failure (in-list failures)]
          [_ (in-range 25)])
      (eprintf "~a\n" failure))
    (unless (null? failures)
      (exit 1))))
