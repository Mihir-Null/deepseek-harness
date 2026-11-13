#lang racket/base
;; Provides the evaluation environments the tests share: `table-environment` rebuilds an
;; environment that the differential table describes, and `make-recording-environment` gives a
;; `ctx` whose services are stubs that record how an expression used them.

(require racket/list
         racket/string
         cordis-data
         cordis-yaml/js-expr
         "../../private/js-path.rkt"
         "table.rkt")

(provide table-environment
         make-recording-environment
         recording-log)

(define (field fields name)
  (cadr (assq name fields)))

;; A context object in the manner of a cordis context: `get(name)` answers optional services,
;; and every member is also a bare identifier inside an expression (dsh evaluates under
;; `with (ctx)`).
(struct context (members)
  #:methods gen:js-object
  [(define (js-get-property self name)
     (hash-ref (context-members self) name (void)))])

;; table-environment : list? -> js-env?
;; The environment for the `(name field ...)` row of the table's `environments` section.
(define (table-environment fields)
  (define env-variables (datum->value (field fields 'env)))
  (define resolve-root (field fields 'resolve-root))
  (define process
    (make-node-process-object
     #:env env-variables
     #:cwd (field fields 'cwd)
     #:platform (field fields 'platform)
     #:exec-path (field fields 'exec-path)
     #:resolve (and resolve-root
                    (lambda (specifier base) (string-append resolve-root "/" specifier)))))
  (define services (datum->value (field fields 'services)))
  (define profile (datum->value (field fields 'profile)))
  (define dsh-home (field fields 'dsh-home))
  (define members
    (for/fold ([members
                (hash "baseUrl" (field fields 'base-url)
                      "get" (lambda (name)
                              (cond [(equal? name "profileContext")
                                     (if (eq? profile 'null) (void) profile)]
                                    [(string? name) (jref services name (void))]
                                    [else (void)]))
                      "dshHomePath" (lambda parts (posix-join (cons dsh-home parts)))
                      "scratch" 0)])
              ([(name service) (in-jobject services)])
      (hash-set members (symbol->string name) service)))
  (make-js-env (hash "ctx" (context members) "process" process)
               #:lookup (lambda (name failure) (hash-ref members name failure))))

;; A stub that stands for a service, or for anything read from one. Every property read and
;; every method call is appended to `log` and yields another stub.
(struct recorder (path log)
  #:methods gen:js-object
  [(define (js-get-property self name)
     (define path (append (recorder-path self) (list name)))
     (record! (recorder-log self) (cons 'get path))
     (recorder path (recorder-log self)))
   (define (js-call-method self name arguments)
     (define path (append (recorder-path self) (list name)))
     (record! (recorder-log self) (list* 'call path arguments))
     (recorder (append path '("()")) (recorder-log self)))])

(define (record! log entry)
  (set-box! log (cons entry (unbox log))))

;; make-recording-environment : #:env hash? #:platform string? -> (values js-env? box?)
;; An environment whose `ctx` answers every property with a recording stub, except that
;; `ctx.get('profileContext')` yields `profile`. `dshHomePath` records its arguments and
;; returns a path under "/home/dsh/.dsh". The second value is the log.
(define (make-recording-environment #:env [env (hash)]
                                    #:platform [platform "linux"]
                                    #:profile [profile (void)])
  (define log (box '()))
  (define (get name)
    (record! log (list 'call '("ctx" "get") name))
    (if (equal? name "profileContext") profile (recorder (list "ctx" "get()" name) log)))
  (define ctx
    (make-js-object
     (lambda (name)
       (record! log (list 'get "ctx" name))
       (if (string=? name "get") get (recorder (list "ctx" name) log)))))
  (define (dsh-home-path . parts)
    (record! log (list* 'call '("dshHomePath") parts))
    (string-join (cons "/home/dsh/.dsh" parts) "/"))
  (define process
    (make-node-process-object
     #:env env
     #:cwd "/work/project"
     #:platform platform
     #:exec-path "/usr/local/bin/node"
     #:homedir "/home/dsh"
     #:resolve (lambda (specifier base)
                 (record! log (list 'call '("require" "resolve") specifier base))
                 (string-append "/opt/dsh/node_modules/" specifier))))
  (values
   (make-js-env (hash "ctx" ctx "process" process)
                #:lookup (lambda (name failure)
                           (case name
                             [("dshHomePath") dsh-home-path]
                             [("baseUrl") "file:///opt/dsh/packages/bundle/base/cordis.patch.yml"]
                             [else (failure)])))
   log))

;; recording-log : box? -> list?   The recorded entries, oldest first.
(define (recording-log log)
  (reverse (unbox log)))
