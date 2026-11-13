#lang racket/base
;; Provides the YAML corpus of the repository: every *.yml file under packages/, apps/ and
;; snapshots/, which are the files dsh ships or tests with. `corpus-files` is #f when the
;; package is used outside the repository tree.

(require racket/list
         racket/path
         racket/runtime-path
         racket/string)

(provide repository-root
         corpus-files
         corpus-file-path)

(define-runtime-path repository-root "../../../..")

(define corpus-directories '("packages" "apps" "snapshots"))

;; corpus-files : -> (or/c (listof string?) #f)
;; The corpus as paths relative to the repository root, with "/" separators, sorted.
(define (corpus-files)
  (and (andmap (lambda (dir) (directory-exists? (build-path repository-root dir)))
               corpus-directories)
       (sort
        (for*/list ([dir (in-list corpus-directories)]
                    [path (in-directory
                           (build-path repository-root dir)
                           (lambda (sub)
                             (not (equal? (path->string (last (explode-path sub)))
                                          "node_modules"))))]
                    #:when (and (file-exists? path)
                                (regexp-match? #rx"[.]yml$" (path->string path))))
          (string-join (map path->string
                            (explode-path (find-relative-path
                                           (simplify-path (path->complete-path repository-root))
                                           (simplify-path (path->complete-path path)))))
                       "/"))
        string<?)))

;; corpus-file-path : string? -> path?
(define (corpus-file-path relative)
  (apply build-path repository-root (string-split relative "/")))
