#lang racket/base
;; Provides `make-node-process-object`: the host object a `!!js` expression sees as Node's
;; `process`, with the members dsh configuration uses: `env`, `cwd()`, `platform`, `execPath`
;; and `getBuiltinModule` for `node:path`, `node:module` and `node:os`.
;;
;; Everything the object answers comes from the arguments, so an evaluation is repeatable and
;; a test can describe another machine. Any other member, and any other builtin module, raises
;; exn:fail:js-expr:unsupported.

(require racket/string
         cordis-data
         "js-builtins.rkt"
         "js-error.rkt"
         "js-object.rkt"
         "js-path.rkt"
         "js-url.rkt"
         "js-value.rkt")

(provide make-node-process-object
         host-platform)

;; host-platform : -> string?   Node's process.platform for the machine Racket runs on.
(define (host-platform)
  (case (system-type 'os*)
    [(linux) "linux"]
    [(macosx darwin) "darwin"]
    [(windows) "win32"]
    [(freebsd) "freebsd"]
    [(openbsd) "openbsd"]
    [(netbsd) "netbsd"]
    [(solaris) "sunos"]
    [(aix) "aix"]
    [else (symbol->string (system-type 'os*))]))

(define (path-text p)
  (if (path? p) (path->string p) p))

;; A directory as Node prints it: no trailing separator except on a root.
(define (directory-text p)
  (define text (path-text p))
  (define len (string-length text))
  (if (and (> len 1)
           (memv (string-ref text (sub1 len)) '(#\/ #\\))
           (not (regexp-match? #rx"^[A-Za-z]:[/\\\\]$" text)))
      (substring text 0 (sub1 len))
      text))

;; The lookup procedure for `env`: string -> string or #f.
(define (environment-lookup env windows?)
  (define (from-pairs pairs)
    (lambda (name)
      (define exact (assoc name pairs))
      (cond [exact (cdr exact)]
            ;; Windows compares variable names without regard to case.
            [windows?
             (define folded (string-foldcase name))
             (for/first ([p (in-list pairs)]
                         #:when (string=? (string-foldcase (car p)) folded))
               (cdr p))]
            [else #f])))
  (cond
    [(procedure? env) env]
    [(environment-variables? env)
     (lambda (name)
       (define key (string->bytes/utf-8 name))
       (define value
         (and (bytes-environment-variable-name? key) (environment-variables-ref env key)))
       (and value (bytes->string/utf-8 value (integer->char #xFFFD))))]
    [(jobject? env)
     (from-pairs (for/list ([(k v) (in-jobject env)]) (cons (symbol->string k) v)))]
    [else
     (from-pairs (for/list ([(k v) (in-hash env)])
                   (cons (if (symbol? k) (symbol->string k) k) v)))]))

(define (require-string! who name v)
  (unless (string? v)
    (raise-js-error
     "TypeError"
     (format "[ERR_INVALID_ARG_TYPE] ~a: the \"~a\" argument must be of type string, received ~a"
             who name (describe-value v)))))

(define (strings! who name arguments)
  (for ([a (in-list arguments)]) (require-string! who name a))
  arguments)

;; node:path with the POSIX algorithms.
(define (posix-path-module cwd)
  (namespace-object
   "path"
   (hash "sep" "/"
         "delimiter" ":"
         "join" (lambda paths (posix-join (strings! "path.join" "path" paths)))
         "normalize" (lambda (path)
                       (require-string! "path.normalize" "path" path)
                       (posix-normalize path))
         "resolve" (lambda paths (posix-resolve (strings! "path.resolve" "paths" paths) (cwd)))
         "dirname" (lambda (path)
                     (require-string! "path.dirname" "path" path)
                     (posix-dirname path))
         "basename" (lambda (path [suffix (void)])
                      (require-string! "path.basename" "path" path)
                      (unless (void? suffix) (require-string! "path.basename" "suffix" suffix))
                      (posix-basename path (if (void? suffix) #f suffix)))
         "extname" (lambda (path)
                     (require-string! "path.extname" "path" path)
                     (posix-extname path))
         "isAbsolute" (lambda (path)
                        (require-string! "path.isAbsolute" "path" path)
                        (posix-absolute? path)))))

;; node:module: only createRequire(base).resolve(specifier), answered by `resolve`.
(define (module-module resolve)
  (define (create-require base)
    (define base-text
      (cond [(url-object? base) (url-object-href base)]
            [(string? base) base]
            [else #f]))
    (unless (and base-text
                 (or (regexp-match? #rx"^file:" base-text)
                     (regexp-match? #rx"^(?:/|[A-Za-z]:[/\\\\])" base-text)))
      (raise-js-error
       "TypeError"
       (format (string-append "[ERR_INVALID_ARG_VALUE] createRequire: the argument 'filename' "
                              "must be a file URL object, file URL string, or absolute path "
                              "string, received ~a")
               (describe-value base))))
    (js-function
     "require"
     (lambda arguments (raise-js-unsupported "call of a require function"))
     #f
     (hash "resolve"
           (lambda (specifier [options (void)])
             (require-string! "require.resolve" "request" specifier)
             (unless (void? options)
               (raise-js-unsupported "require.resolve with options"))
             (unless resolve
               (raise-js-error
                "Error"
                (format "cannot resolve '~a': the process object was made without a resolver"
                        specifier)))
             (define resolved (resolve specifier base-text))
             (unless (string? resolved)
               (raise-argument-error 'make-node-process-object
                                     "a resolver that returns a string" resolved))
             resolved))))
  (namespace-object "module" (hash "createRequire" create-require)))

(define (os-module lookup platform homedir)
  (define windows? (string=? platform "win32"))
  (namespace-object
   "os"
   (hash "homedir"
         (lambda ()
           (directory-text
            (or homedir
                (lookup (if windows? "USERPROFILE" "HOME"))
                (find-system-path 'home-dir))))
         "tmpdir"
         (lambda ()
           (when windows? (raise-js-unsupported "os.tmpdir() on win32"))
           (define dir (or (non-empty (lookup "TMPDIR")) (non-empty (lookup "TMP"))
                           (non-empty (lookup "TEMP")) "/tmp"))
           (if (and (> (string-length dir) 1) (string-suffix? dir "/"))
               (substring dir 0 (sub1 (string-length dir)))
               dir))
         "platform" (lambda () platform)
         "EOL" (if windows? "\r\n" "\n"))))

(define (non-empty s)
  (and s (not (string=? s "")) s))

;; make-node-process-object : ... -> js-object?
;; env : a hash or jobject from variable name to string, an environment-variables set, or a
;; procedure from name to string or #f. cwd : a path-string, or a thunk that returns one.
;; exec-path : a path-string or #f. resolve : #f, or (specifier base) -> path string, where
;; base is the string given to createRequire. homedir : a path-string or #f. extra : a hash of
;; further members.
(define (make-node-process-object #:env [env (current-environment-variables)]
                                  #:cwd [cwd (current-directory)]
                                  #:platform [platform (host-platform)]
                                  #:exec-path [exec-path (find-executable-path "node")]
                                  #:resolve [resolve #f]
                                  #:homedir [homedir #f]
                                  #:extra [extra (hash)])
  (define windows? (string=? platform "win32"))
  (define lookup (environment-lookup env windows?))
  (define (current-cwd) (directory-text (if (procedure? cwd) (cwd) cwd)))
  (define env-object
    (make-js-object
     (lambda (name)
       (define value (lookup name))
       (if (string? value) value (void)))))
  (define (get-builtin-module id)
    (require-string! "process.getBuiltinModule" "id" id)
    (define name (if (string-prefix? id "node:") (substring id 5) id))
    (cond
      [(string=? name "path")
       (if windows?
           (raise-js-unsupported "node:path on win32")
           (posix-path-module current-cwd))]
      [(string=? name "module") (module-module resolve)]
      [(string=? name "os") (os-module lookup platform homedir)]
      [else (raise-js-unsupported (format "process.getBuiltinModule('~a')" id))]))
  (define members
    (hash "env" env-object
          "cwd" current-cwd
          "platform" platform
          "getBuiltinModule" get-builtin-module))
  (make-js-object
   (lambda (name)
     (cond
       [(hash-has-key? extra name) (hash-ref extra name)]
       [(string=? name "execPath")
        (unless exec-path
          (raise-js-error "Error" "process.execPath is unknown: no node executable was given"))
        (path-text exec-path)]
       [else
        (hash-ref members name
                  (lambda () (raise-js-unsupported (format "process.~a" name))))]))))
