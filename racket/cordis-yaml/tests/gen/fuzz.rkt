#lang racket/base
;; One-off driver: checks cordis-yaml against every section of a differential table of any
;; size, for example one that tests/gen/gen-js-yaml-table.mjs wrote with another seed or with
;; --fuzz-load. Prints the first differences of each section and exits with status 1 when
;; there are any.
;;
;;   racket tests/gen/fuzz.rkt /tmp/fuzz.rktd

(require racket/cmdline
         "../support/table-check.rkt"
         "../support/table.rkt")

(define path
  (command-line #:args (table-file) table-file))

(define table (load-table path))

(define sections
  '(load load-named load-styled load-all load-json dump dump-unstable eval syntax-error
         unsupported))

(define total
  (for/sum ([section (in-list sections)]
            #:when (hash-has-key? table section))
    (define failures (check-section table section))
    (printf "~a: ~a rows, ~a differences\n"
            section (length (table-rows table section)) (length failures))
    (for ([failure (in-list failures)] [_ (in-range 10)])
      (printf "~a\n" failure))
    (length failures)))

(exit (if (zero? total) 0 1))
