#lang racket/base
;; The corpus: every *.yml file under packages/, apps/ and snapshots/ of the repository, and
;; every distinct `!!js` expression in them. Each file must parse, survive write and read, and
;; give the JSON and the dump text js-yaml gives (by the digests in the differential table);
;; each expression must parse and evaluate inside the supported subset.
;;
;; The test is skipped, with a message, when the repository tree is not there. A file whose
;; content differs from the digest in the table is still checked for parsing and round trip
;; and is counted as stale.

(require rackunit
         racket/file
         racket/list
         racket/match
         racket/string
         file/sha1
         cordis-data
         cordis-yaml
         cordis-yaml/js-expr
         "support/corpus.rkt"
         "support/environment.rkt"
         "support/table.rkt")

(define files (corpus-files))
(define table (load-table))

(define (sha256-hex text)
  (bytes->hex-string (sha256-bytes (string->bytes/utf-8 text))))

(define (collect-expressions v counts)
  (cond [(js-expr? v) (hash-update! counts (js-expr-source v) add1 0)]
        [(list? v) (for ([item (in-list v)]) (collect-expressions item counts))]
        [(jobject? v) (for ([(key item) (in-jobject v)]) (collect-expressions item counts))]
        [else (void)]))

(cond
  [(not files)
   (eprintf "corpus-test: the repository tree is not present; corpus checks skipped\n")]
  [else
   (define expression-counts (make-hash))
   (define digests
     (for/hash ([row (in-list (table-rows table 'corpus))])
       (values (first row) (rest row))))
   (define stale '())
   (define mismatches '())

   (test-case "every corpus file parses, round-trips and matches js-yaml"
     (check-true (>= (length files) 100))
     (for ([relative (in-list files)])
       (define text (file->string (corpus-file-path relative)))
       (define documents (yaml-read-all text #:source relative))
       (for ([document (in-list documents)]) (collect-expressions document expression-counts))
       ;; Reading what the writer wrote gives the same values; expression sources included,
       ;; because two expression nodes are equal when their sources are.
       (define written (map yaml->string documents))
       (unless (equal? (map yaml-read written) documents)
         (set! mismatches (cons (list 'round-trip relative) mismatches)))
       (match (hash-ref digests relative #f)
         [(list content-digest json-digest dump-digest)
          #:when (equal? content-digest (sha256-hex text))
          ;; js-yaml enumerates object keys in JavaScript's order.
          (define ordered (map js-ordered documents))
          (unless (equal? (sha256-hex (jvalue->string (map yaml-value->jvalue ordered)))
                          json-digest)
            (set! mismatches (cons (list 'json relative) mismatches)))
          (unless (equal? (sha256-hex (string-join (map yaml->string ordered) "---\n"))
                          dump-digest)
            (set! mismatches (cons (list 'dump relative) mismatches)))]
         [_ (set! stale (cons relative stale))]))
     (check-equal? mismatches '())
     (unless (null? stale)
       (eprintf "corpus-test: ~a of ~a files differ from the table's digests (stale table)\n"
                (length stale) (length files)))
     (when (null? stale)
       (check-equal? (length files) (length (table-rows table 'corpus)))))

   (define sources (sort (hash-keys expression-counts) string<?))

   (test-case "the corpus holds the expressions the table lists"
     (check-true (>= (length sources) 100))
     (when (null? stale)
       (check-equal? sources (sort (map first (table-rows table 'corpus-expressions)) string<?))
       (for ([row (in-list (table-rows table 'corpus-expressions))])
         (check-equal? (hash-ref expression-counts (first row)) (second row) (first row)))))

   (test-case "every corpus expression parses to a printable, readable tree"
     (for ([source (in-list sources)])
       (define ast (js-parse source))
       (check-pred list? ast source)
       ;; The tree is plain data: printing it and reading it back gives an equal tree.
       (check-equal? (read (open-input-string (format "~s" ast))) ast source)))

   (define snapshot-variables
     (hash "DSH_SNAPSHOT" "replay"
           "DSH_SNAPSHOT_FILE" "/opt/dsh/snapshots/cases/demo/snapshot.yml"
           "DSH_PERMISSION_MODE" "danger-full-access"
           "DSH_CONTEXT_WINDOW" "64000"
           "DSH_GITHUB_WEBHOOK_PORT" "4455"
           "DSH_TEST_CHILD_PATCHES" "[{\"insert\":{\"id\":\"child\"}}]"
           "DSH_MAX_TOKENS_AS_SUCCESS" "false"
           "LIVESHARE_ALLOWED_SUBJECTS" "alice, bob"
           "MEMORY_FILE_PATH" " /data/memory.jsonl "
           "DSH_PRIMARY_RUNTIME" "/opt/runtime"
           "DSH_SNAPSHOT_SPILL_ROOT" "/var/spill"
           "DSH_TEST_ACP_MODE" "diagnostic"))

   (test-case "every corpus expression evaluates inside the supported subset"
     (for* ([variables (in-list (list (hash) snapshot-variables))]
            [platform (in-list '("linux" "darwin"))]
            [profile (in-list (list (void) (jobject 'name "desktop")))]
            [source (in-list sources)])
       (define-values (env log)
         (make-recording-environment #:env variables #:platform platform #:profile profile))
       (check-not-exn (lambda () (js-eval source env)) source))
     ;; On win32 the five expressions that use node:path are outside the subset, and say so.
     (define-values (env log) (make-recording-environment #:platform "win32"))
     (define outside
       (for/list ([source (in-list sources)]
                  #:when (with-handlers ([exn:fail:js-expr:unsupported? (lambda (e) #t)])
                           (js-eval source env)
                           #f))
         source))
     (check-equal? (length outside) 5)
     (check-true (andmap (lambda (source) (string-contains? source "node:path")) outside)))

   (define (evaluate/log source #:env [variables (hash)] #:profile [profile (void)])
     (define-values (env log) (make-recording-environment #:env variables #:profile profile))
     (define value (js-eval source env))
     (values value (recording-log log)))

   (test-case "expressions reach the context and its services in the expected way"
     (let-values ([(value log) (evaluate/log "ctx.headlessStartup.task")])
       (check-pred js-object? value)
       (check-equal? log '((get "ctx" "headlessStartup") (get "ctx" "headlessStartup" "task"))))
     (let-values ([(value log) (evaluate/log "ctx.webStartup.port ?? 3080")])
       (check-pred js-object? value)
       (check-equal? (last log) '(get "ctx" "webStartup" "port")))
     (let-values ([(value log) (evaluate/log "dshHomePath('office-kit', 'outputs')")])
       (check-equal? value "/home/dsh/.dsh/office-kit/outputs")
       (check-equal? log '((call ("dshHomePath") "office-kit" "outputs"))))
     (let-values ([(value log) (evaluate/log "!ctx.get('profileContext')")])
       (check-equal? value #t)
       (check-equal? log '((get "ctx" "get") (call ("ctx" "get") "profileContext"))))
     (let-values ([(value log)
                   (evaluate/log "ctx.get('profileContext')?.name !== 'desktop'"
                                 #:profile (jobject 'name "desktop"))])
       (check-equal? value #f))
     (let-values ([(value log)
                   (evaluate/log
                    (string-append
                     "process.getBuiltinModule('node:path').join("
                     "process.getBuiltinModule('node:path').dirname("
                     "process.getBuiltinModule('node:module').createRequire(baseUrl)"
                     ".resolve('@deepseek-ai/dsh-agent-preset/package.json')), 'skills')"))])
       (check-equal? value "/opt/dsh/node_modules/@deepseek-ai/dsh-agent-preset/skills")
       (check-equal? log
                     '((call ("require" "resolve")
                             "@deepseek-ai/dsh-agent-preset/package.json"
                             "file:///opt/dsh/packages/bundle/base/cordis.patch.yml"))))
     (let-values ([(value log)
                   (evaluate/log
                    (string-append "decodeURIComponent(new URL('./runner.mjs', 'file://' + "
                                   "process.env.DSH_SNAPSHOT_FILE).pathname)")
                    #:env snapshot-variables)])
       (check-equal? value "/opt/dsh/snapshots/cases/demo/runner.mjs")))])
