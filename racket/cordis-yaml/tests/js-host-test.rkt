#lang racket/base
;; Unit tests of host objects in `!!js` expressions: the `gen:js-object` interface, the
;; closure-based `make-js-object`, and the Node `process` object with its builtin modules.

(require rackunit
         racket/generic
         racket/string
         cordis-data
         cordis-yaml/js-expr)

(define (error-name thunk)
  (with-handlers ([exn:fail:js-expr:unsupported? (lambda (e) 'unsupported)]
                  [exn:fail:js-expr?
                   (lambda (e) (car (regexp-match #rx"^[A-Za-z]+" (exn-message e))))])
    (thunk)
    'no-error))

;; ---------------------------------------------------------------------------------------------
;; gen:js-object

;; A service whose members are computed when an expression asks for them.
(struct lazy-service (reads)
  #:methods gen:js-object
  [(define (js-get-property self name)
     (set-box! (lazy-service-reads self) (cons name (unbox (lazy-service-reads self))))
     (case name
       [("task") "summarize"]
       [("limits") (jobject 'turns 3)]
       [("double") (lambda (n) (* 2 n))]
       [else (void)]))])

;; A context in the manner of cordis: `get` is a method, services are properties.
(struct context (services)
  #:methods gen:js-object
  [(define (js-get-property self name)
     (hash-ref (context-services self) name (void)))
   (define (js-call-method self name arguments)
     (case name
       [("get") (hash-ref (context-services self) (car arguments) (void))]
       [else (raise-arguments-error 'context "no such method" "name" name)]))])

(test-case "a struct that implements gen:js-object is read lazily"
  (define reads (box '()))
  (define service (lazy-service reads))
  (define env (make-js-env (hash "service" service)))
  (check-pred js-object? service)
  (check-equal? (unbox reads) '())
  (check-equal? (js-eval "service.task" env) "summarize")
  (check-equal? (unbox reads) '("task"))
  (check-equal? (js-eval "service.limits.turns + 1" env) 4)
  (check-pred void? (js-eval "service.nope" env))
  (check-equal? (js-eval "service.nope ?? 'default'" env) "default")
  (check-pred void? (js-eval "service.nope?.deeper" env))
  (check-equal? (js-eval "service['ta' + 'sk']" env) "summarize")
  (check-equal? (js-eval "typeof service" env) "object")
  (check-equal? (js-eval "!!service" env) #t))

(test-case "a method call reads the property and calls it by default"
  (define env (make-js-env (hash "service" (lazy-service (box '())))))
  (check-equal? (js-eval "service.double(21)" env) 42)
  (check-equal? (js-eval "service.double?.(4)" env) 8)
  (check-pred void? (js-eval "service.nope?.(4)" env))
  (check-equal? (error-name (lambda () (js-eval "service.task()" env))) "TypeError")
  (check-equal? (error-name (lambda () (js-eval "service.nope()" env))) "TypeError")
  (check-equal? (js-call-method (lazy-service (box '())) "double" '(5)) 10)
  (check-equal? (js-get-property (lazy-service (box '())) "task") "summarize"))

(test-case "a struct may implement method calls itself"
  (define ctx (context (hash "profileContext" (jobject 'name "desktop") "answer" 42)))
  (define env (make-js-env (hash "ctx" ctx)))
  (check-equal? (js-eval "ctx.get('profileContext')?.name" env) "desktop")
  (check-pred void? (js-eval "ctx.get('nope')?.name" env))
  (check-equal? (js-eval "!ctx.get('nope')" env) #t)
  (check-equal? (js-eval "ctx.answer" env) 42))

(test-case "make-js-object builds a host object from closures"
  (define calls '())
  (define plain (make-js-object (lambda (name) (if (equal? name "x") 1 (void)))))
  (define with-methods
    (make-js-object (lambda (name) (string-append "prop:" name))
                    (lambda (name arguments)
                      (set! calls (cons (cons name arguments) calls))
                      (length arguments))))
  (define env (make-js-env (hash "plain" plain "obj" with-methods)))
  (check-pred js-object? plain)
  (check-equal? (js-eval "plain.x" env) 1)
  (check-pred void? (js-eval "plain.y" env))
  (check-equal? (js-eval "obj.anything" env) "prop:anything")
  (check-equal? (js-eval "obj.run(1, 'two', [3])" env) 3)
  (check-equal? calls '(("run" 1 "two" (3)))))

(test-case "a host object cannot be enumerated, and converts by its toString"
  (define plain (make-js-object (lambda (name) (void))))
  (define named
    (make-js-object (lambda (name) (if (equal? name "toString") (lambda () "named!") (void)))))
  (define env (make-js-env (hash "plain" plain "named" named)))
  (check-equal? (js-eval "'' + plain" env) "[object Object]")
  (check-equal? (js-eval "`${named}`" env) "named!")
  (check-equal? (js-eval "named + 1" env) "named!1")
  (check-equal? (error-name (lambda () (js-eval "({...plain})" env))) 'unsupported)
  (check-equal? (error-name (lambda () (js-eval "Object.keys(plain)" env))) 'unsupported)
  (check-equal? (error-name (lambda () (js-eval "JSON.stringify(plain)" env))) 'unsupported)
  (check-equal? (error-name (lambda () (js-eval "[...plain]" env))) 'unsupported))

;; ---------------------------------------------------------------------------------------------
;; process

(define (process-env process . more)
  (make-js-env (apply hash "process" process more)))

(define linux
  (make-node-process-object
   #:env (hash "HOME" "/home/dsh" "DSH_MODEL" "deepseek-test" "EMPTY" "")
   #:cwd "/work/project/"
   #:platform "linux"
   #:exec-path "/usr/local/bin/node"
   #:resolve (lambda (specifier base) (string-append "/opt/dsh/node_modules/" specifier))))

(test-case "process.env"
  (define env (process-env linux))
  (check-equal? (js-eval "process.env.DSH_MODEL" env) "deepseek-test")
  (check-pred void? (js-eval "process.env.NOPE" env))
  (check-equal? (js-eval "process.env.NOPE ?? 'd'" env) "d")
  (check-equal? (js-eval "process.env.EMPTY ?? 'd'" env) "")
  (check-equal? (js-eval "process.env.EMPTY || 'd'" env) "d")
  (check-equal? (js-eval "process.env['HO' + 'ME']" env) "/home/dsh")
  (check-equal? (js-eval "typeof process.env" env) "object")
  (check-equal? (error-name (lambda () (js-eval "({...process.env})" env))) 'unsupported))

(test-case "the forms the environment may be given in"
  (define (model env-source)
    (js-eval "process.env.DSH_MODEL" (process-env (make-node-process-object #:env env-source))))
  (check-equal? (model (hash "DSH_MODEL" "a")) "a")
  (check-equal? (model (hash 'DSH_MODEL "b")) "b")
  (check-equal? (model (jobject 'DSH_MODEL "c")) "c")
  (check-equal? (model (lambda (name) (and (equal? name "DSH_MODEL") "d"))) "d")
  (check-equal? (model (make-environment-variables #"DSH_MODEL" #"e")) "e")
  (check-pred void? (model (hash)))
  (check-pred void? (model (make-environment-variables)))
  ;; The default is the environment of the Racket process.
  (parameterize ([current-environment-variables (make-environment-variables #"DSH_MODEL" #"f")])
    (check-equal? (js-eval "process.env.DSH_MODEL" (process-env (make-node-process-object))) "f")))

(test-case "variable names are case-insensitive on win32 only"
  (define (lookup platform)
    (js-eval "process.env.path"
             (process-env (make-node-process-object #:env (hash "Path" "C:\\bin")
                                                    #:platform platform))))
  (check-equal? (lookup "win32") "C:\\bin")
  (check-pred void? (lookup "linux")))

(test-case "cwd, platform and execPath"
  (define env (process-env linux))
  ;; No trailing separator, as Node prints a directory.
  (check-equal? (js-eval "process.cwd()" env) "/work/project")
  (check-equal? (js-eval "process.cwd() + '/runtime-source'" env) "/work/project/runtime-source")
  (check-equal? (js-eval "process.platform" env) "linux")
  (check-equal? (js-eval "process.platform === 'win32' ? ['pwsh', 'powershell'] : []" env) '())
  (check-equal? (js-eval "process.execPath" env) "/usr/local/bin/node")
  (check-equal? (js-eval "typeof process.cwd" env) "function")
  (define counter 0)
  (define moving
    (make-node-process-object #:cwd (lambda ()
                                      (set! counter (add1 counter))
                                      (build-path "/tmp" (number->string counter)))))
  (check-equal? (js-eval "process.cwd() + process.cwd()" (process-env moving)) "/tmp/1/tmp/2")
  (check-equal? (js-eval "process.cwd()" (process-env (make-node-process-object #:cwd "/"))) "/")
  ;; The defaults describe the machine Racket runs on.
  (define default (make-node-process-object))
  (check-pred string? (js-eval "process.platform" (process-env default)))
  (check-equal? (js-eval "process.cwd()" (process-env default))
                (let ([dir (path->string (current-directory))])
                  (if (> (string-length dir) 1) (string-trim dir "/" #:left? #f) dir))))

(test-case "execPath without a node executable is an error, not a guess"
  (define no-node (make-node-process-object #:exec-path #f))
  (check-equal? (error-name (lambda () (js-eval "process.execPath" (process-env no-node))))
                "Error")
  (check-equal? (js-eval "process.platform === process.platform" (process-env no-node)) #t))

(test-case "node:path"
  (define env (process-env linux))
  (define (path-call text)
    (js-eval (string-append "process.getBuiltinModule('node:path')." text) env))
  (check-equal? (path-call "join(process.cwd(), 'approved.txt')") "/work/project/approved.txt")
  (check-equal? (path-call "join('a', '..', '..', 'b')") "../b")
  (check-equal? (path-call "join()") ".")
  (check-equal? (path-call "normalize('/a/./b/../c/')") "/a/c/")
  (check-equal? (path-call "resolve('x', '../y')") "/work/project/y")
  (check-equal? (path-call "resolve('')") "/work/project")
  (check-equal? (path-call "resolve('/abs', 'x')") "/abs/x")
  (check-equal? (path-call "dirname('/a/b/c.txt')") "/a/b")
  (check-equal? (path-call "dirname('c.txt')") ".")
  (check-equal? (path-call "basename('/a/b/c.txt')") "c.txt")
  (check-equal? (path-call "basename('/a/b/c.txt', '.txt')") "c")
  (check-equal? (path-call "extname('/a/b/c.tar.gz')") ".gz")
  (check-equal? (path-call "isAbsolute('/a')") #t)
  (check-equal? (path-call "isAbsolute('a')") #f)
  (check-equal? (path-call "sep") "/")
  (check-equal? (path-call "delimiter") ":")
  (check-equal? (js-eval "process.getBuiltinModule('path').sep" env) "/")
  (check-equal? (error-name (lambda () (path-call "join('a', 5)"))) "TypeError")
  (check-equal? (error-name (lambda () (path-call "relative('/a', '/b')"))) 'unsupported)
  (check-equal? (error-name (lambda () (path-call "posix"))) 'unsupported))

(test-case "node:path on win32 is unsupported, because Node's Windows algorithms differ"
  (define windows (make-node-process-object #:env (hash) #:cwd "C:\\work" #:platform "win32"))
  (define env (process-env windows))
  (check-equal? (js-eval "process.cwd()" env) "C:\\work")
  (check-equal? (js-eval "process.platform === 'win32'" env) #t)
  (check-equal? (error-name (lambda () (js-eval "process.getBuiltinModule('node:path')" env)))
                'unsupported))

(test-case "node:module resolves through the caller's resolver"
  (define seen '())
  (define process
    (make-node-process-object
     #:env (hash) #:cwd "/w" #:platform "linux"
     #:resolve (lambda (specifier base)
                 (set! seen (cons (list specifier base) seen))
                 (string-append "/modules/" specifier))))
  (define env (process-env process "baseUrl" "file:///opt/dsh/cordis.yml"))
  (check-equal?
   (js-eval (string-append "process.getBuiltinModule('node:module').createRequire(baseUrl)"
                           ".resolve('@deepseek-ai/dsh-agent-preset/package.json')")
            env)
   "/modules/@deepseek-ai/dsh-agent-preset/package.json")
  ;; A URL object is passed to the resolver as its href.
  (js-eval "process.getBuiltinModule('node:module').createRequire(new URL(baseUrl)).resolve('x')"
           env)
  (js-eval "process.getBuiltinModule('module').createRequire('/abs/dir/file.js').resolve('y')" env)
  (check-equal? (reverse seen)
                '(("@deepseek-ai/dsh-agent-preset/package.json" "file:///opt/dsh/cordis.yml")
                  ("x" "file:///opt/dsh/cordis.yml")
                  ("y" "/abs/dir/file.js")))
  (define (module-error text)
    (error-name
     (lambda () (js-eval (string-append "process.getBuiltinModule('node:module')." text) env))))
  (check-equal? (module-error "createRequire('relative/path')") "TypeError")
  (check-equal? (module-error "createRequire(5)") "TypeError")
  (check-equal? (module-error "createRequire(baseUrl)('fs')") 'unsupported)
  (check-equal? (module-error "createRequire(baseUrl).resolve('x', {})") 'unsupported)
  (check-equal? (module-error "builtinModules") 'unsupported))

(test-case "node:module without a resolver fails when it is asked to resolve"
  (define process (make-node-process-object #:env (hash) #:cwd "/w" #:platform "linux"))
  (define env (process-env process))
  (check-equal?
   (js-eval "typeof process.getBuiltinModule('node:module').createRequire('/a/b.js')" env)
   "function")
  (check-equal?
   (error-name
    (lambda ()
      (js-eval "process.getBuiltinModule('node:module').createRequire('/a/b.js').resolve('x')"
               env)))
   "Error"))

(test-case "node:os"
  (define env (process-env linux))
  (check-equal? (js-eval "process.getBuiltinModule('node:os').homedir()" env) "/home/dsh")
  (check-equal? (js-eval "process.getBuiltinModule('node:os').tmpdir()" env) "/tmp")
  (check-equal? (js-eval "process.getBuiltinModule('node:os').platform()" env) "linux")
  (check-equal? (js-eval "process.getBuiltinModule('node:os').EOL" env) "\n")
  (define explicit
    (make-node-process-object #:env (hash "HOME" "/ignored" "TMPDIR" "/var/tmp/")
                              #:homedir "/home/explicit/" #:platform "linux"))
  (check-equal? (js-eval "process.getBuiltinModule('node:os').homedir()" (process-env explicit))
                "/home/explicit")
  (check-equal? (js-eval "process.getBuiltinModule('node:os').tmpdir()" (process-env explicit))
                "/var/tmp")
  (define windows
    (make-node-process-object #:env (hash "USERPROFILE" "C:\\Users\\dsh") #:platform "win32"))
  (check-equal? (js-eval "process.getBuiltinModule('node:os').homedir()" (process-env windows))
                "C:\\Users\\dsh")
  (check-equal? (js-eval "process.getBuiltinModule('node:os').EOL" (process-env windows)) "\r\n")
  (check-equal? (error-name (lambda () (js-eval "process.getBuiltinModule('node:os').cpus()" env)))
                'unsupported))

(test-case "other members and modules of process are unsupported; extras are added by the caller"
  (define env (process-env linux))
  (check-equal? (error-name (lambda () (js-eval "process.argv" env))) 'unsupported)
  (check-equal? (error-name (lambda () (js-eval "process.version" env))) 'unsupported)
  (check-equal? (error-name (lambda () (js-eval "process.getBuiltinModule('node:fs')" env)))
                'unsupported)
  (check-equal? (error-name (lambda () (js-eval "process.getBuiltinModule(5)" env))) "TypeError")
  (check-equal? (error-name (lambda () (js-eval "'' + process" env))) 'unsupported)
  (define extended
    (make-node-process-object #:env (hash) #:platform "linux"
                              #:extra (hash "version" "v24.9.0" "arch" "arm64")))
  (check-equal? (js-eval "process.version + '/' + process.arch" (process-env extended))
                "v24.9.0/arm64"))
