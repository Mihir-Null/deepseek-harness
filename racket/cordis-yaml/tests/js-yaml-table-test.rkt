#lang racket/base
;; Differential test against js-yaml and Node: every row of tests/data/js-yaml-table.rktd holds
;; a result that js-yaml 4.3.2 computed with the dsh schema (load, loadAll, dump) or that Node
;; computed for an expression under `with (ctx) { return eval(expr) }`, and cordis-yaml must
;; produce the same. Regenerate the table with tests/gen/gen-js-yaml-table.mjs; this test needs
;; neither Node nor the network. The corpus rows are checked by corpus-test.rkt.

(require rackunit
         racket/list
         "support/table-check.rkt"
         "support/table.rkt")

(define table (load-table))

(define (row-count section)
  (length (table-rows table section)))

;; Checks a section, printing the first differences.
(define (check-no-differences section)
  (define failures (check-section table section))
  (for ([failure (in-list failures)] [_ (in-range 15)])
    (eprintf "~a\n" failure))
  (check-equal? (length failures) 0 (symbol->string section)))

(test-case "yaml-read agrees with js-yaml load on every hand-written text"
  (check-no-differences 'load)
  (check-true (>= (row-count 'load) 800)))

(test-case "yaml-read reports the source name as js-yaml reports its filename option"
  (check-no-differences 'load-named))

(test-case "yaml-read reads the texts js-yaml writes in its other styles"
  (check-no-differences 'load-styled)
  (check-true (>= (row-count 'load-styled) 300)))

(test-case "yaml-read-all agrees with js-yaml loadAll"
  (check-no-differences 'load-all))

(test-case "the json schema agrees with js-yaml's JSON_SCHEMA"
  (check-no-differences 'load-json))

(test-case "yaml->string writes the text js-yaml dump writes"
  (check-no-differences 'dump)
  (check-true (>= (row-count 'dump) 2000)))

(test-case "yaml->string departs from js-yaml where js-yaml's text does not read back"
  (check-no-differences 'dump-unstable)
  (check-true (>= (row-count 'dump-unstable) 10)))

(test-case "js-eval agrees with Node on every expression of the table"
  (check-no-differences 'eval)
  (check-true (>= (row-count 'eval) 2500))
  ;; The corpus has five distinct expressions that use node:path; under the win32 environment
  ;; they are the only rows where unsupported is the expected outcome.
  (check-equal? (count (lambda (row) (windows-path-row? table row)) (table-rows table 'eval)) 5))

(test-case "every corpus expression is in the table under every environment"
  (define sources (map first (table-rows table 'corpus-expressions)))
  (check-equal? (length sources) 106)
  (for ([environment (in-list (table-rows table 'environments))])
    (define evaluated
      (for/list ([row (in-list (table-rows table 'eval))]
                 #:when (and (eq? (second row) (first environment)) (eq? (third row) 'corpus)))
        (first row)))
    (check-equal? (sort evaluated string<?) (sort sources string<?))))

(test-case "text that Node rejects with SyntaxError raises exn:fail:js-expr:syntax"
  (check-no-differences 'syntax-error)
  (check-true (>= (row-count 'syntax-error) 150)))

(test-case "JavaScript outside the subset raises exn:fail:js-expr:unsupported"
  (check-no-differences 'unsupported)
  (check-true (>= (row-count 'unsupported) 200)))
