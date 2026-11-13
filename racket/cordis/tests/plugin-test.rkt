#lang racket/base
;; `define-plugin` and `plugin-info`: contract section 9. The three body forms, the four
;; inject clauses, every option, and the syntax errors that name the clause at fault.
(require rackunit
         syntax/macro-testing
         cordis
         cordis/plugin
         cordis/testing
         "common.rkt")

;; Expands `form` at run time and returns the message of the syntax error it raises.
(define-syntax-rule (syntax-error-message form)
  (with-handlers ([exn:fail:syntax? exn-message])
    (convert-compile-time-error (let () form (void)))
    "no syntax error"))

;; ---------------------------------------------------------------------------------------
;; The declaration

(define-plugin lambda-form
  #:inject (tools [approval #:optional] [store #:as db] [llm #:intercept (hasheq 'model "m")])
  #:config (lambda (raw) (or raw 'default-config))
  #:provides (greeting farewell)
  #:custodian inherit
  #:meta (hasheq 'doc "text")
  (lambda (ctx config)
    (list ctx config tools approval db llm)
    (void)))

(define-plugin short-form
  #:name "short"
  (ctx config)
  (define seen (list ctx config))
  (void seen))

(define (apply-proc ctx config) (void))
(define-plugin apply-form
  #:name 'from-symbol
  #:custodian 'own
  #:inject (tools [approval #:optional])
  #:apply apply-proc)

(test-case "define-plugin: defines a plugin with its declaration"
  (check-true (plugin? lambda-form))
  (check-equal? (plugin-name lambda-form) "lambda-form")
  (check-equal? (plugin-inject lambda-form)
                (list 'tools 'store (cons 'llm (hasheq 'model "m"))))
  (check-equal? (plugin-provides lambda-form) '(greeting farewell))
  (check-equal? (plugin-custodian-mode lambda-form) 'inherit)
  (check-equal? (plugin-meta lambda-form) (hasheq 'doc "text"))
  (check-equal? ((plugin-config-schema lambda-form) #f) 'default-config)
  (check-equal? (object-name (plugin-apply lambda-form)) 'lambda-form)
  (check-equal? (plugin-name short-form) "short")
  (check-equal? (plugin-inject short-form) '())
  (check-equal? (plugin-custodian-mode short-form) 'own)
  (check-equal? (plugin-name apply-form) "from-symbol")
  (check-equal? (plugin-inject apply-form) '(tools)))

(test-case "plugin-info: the declaration as data, for declared and for made plugins"
  (define info (plugin-info lambda-form))
  (check-equal? (hash-ref info 'name) "lambda-form")
  (check-equal? (hash-ref info 'inject) '(tools store llm))
  (check-equal? (hash-ref info 'optional) '(approval))
  (check-equal? (hash-ref info 'provides) '(greeting farewell))
  (check-eq? (hash-ref info 'config-schema) (plugin-config-schema lambda-form))
  (check-equal? (hash-ref (plugin-info apply-form) 'optional) '(approval))
  (define made (make-plugin apply-proc #:inject (hasheq 'b 1 'a #f) #:provides '(c)))
  (check-equal? (plugin-info made)
                (hasheq 'name #f 'inject '(a b) 'optional '() 'provides '(c)
                        'config-schema #f)))

;; ---------------------------------------------------------------------------------------
;; Bindings in the body

(test-case "body: required keys are handles, #:as renames, #:intercept is the inner layer"
  (define-values (note notes) (make-recorder))
  (define-plugin consumer
    #:inject (tools [store #:as db] [llm #:intercept 'inner])
    (lambda (ctx config)
      (note (list (service-handle? tools) (eq? (use-context tools) ctx)
                  (service-handle-key tools) (service-value tools 'tools)))
      (note (list (service-handle-key db) (service-value db 'store)))
      (note (context-intercepts (use-context llm) 'llm))
      (note config)))
  (with-root-context (ctx)
    (ctx-provide ctx 'tools 'the-tools)
    (ctx-provide ctx 'store 'the-store)
    (ctx-provide ctx 'llm 'the-llm)
    (define f (ctx-plugin (context-intercept ctx 'llm 'outer) consumer 'raw))
    (await/t f)
    (check-equal? (fiber-name f) "consumer")
    (check-equal? (notes)
                  '((#t #t tools the-tools) (store the-store) (outer inner) raw))
    (fiber-dispose! f)
    (check-equal? (ctx-fibers ctx) '())))

(test-case "body: an optional key reads the service at each use and is not injected"
  (define-values (note notes) (make-recorder))
  (define release (gate))
  (define-plugin reader
    #:inject ([approval #:optional] [callable #:optional])
    (ctx config)
    (note approval)
    (gate-wait release)
    (note approval)
    (note (callable 1 2)))
  (with-root-context (ctx)
    (define f (ctx-plugin ctx reader))
    (check-equal? (hash-count (fiber-inject f)) 0)
    (check-true (wait-for (lambda () (equal? (notes) '(#f)))))
    (define d (ctx-provide ctx 'approval 'granted))
    (ctx-provide ctx 'callable +)
    (gate-open! release)
    (await/t f)
    (check-equal? (notes) '(#f granted 3))
    ;; withdrawing an optional service leaves the reader active
    (d)
    (check-eq? (fiber-state f) 'active)
    (fiber-dispose! f)
    (check-equal? (ctx-fibers ctx) '())))

(test-case "body: internal definitions, the plugin's own name, and an effect result"
  (define-values (note notes) (make-recorder))
  (define-plugin self-aware
    (lambda (ctx config)
      (define mine (fiber-plugin (context-fiber ctx)))
      (note (eq? mine self-aware))
      (lambda () (note 'cleanup))))
  (with-root-context (ctx)
    (define f (ctx-plugin ctx self-aware))
    (await/t f)
    (fiber-dispose! f)
    (check-equal? (notes) '(#t cleanup))))

(test-case "body: #:apply takes any procedure of a context and a config"
  (define-values (note notes) (make-recorder))
  (define-plugin applied
    #:inject (tools)
    #:apply (lambda (ctx config) (note (list (ctx-ref ctx 'tools) config))))
  (with-root-context (ctx)
    (ctx-provide ctx 'tools 't)
    (await/t (ctx-plugin ctx applied 'c))
    (check-equal? (notes) '((t c))))
  (check-exn exn:fail:contract?
             (lambda ()
               (define-plugin wrong-arity #:apply (lambda (ctx) (void)))
               wrong-arity))
  (check-exn exn:fail:contract?
             (lambda ()
               (define-plugin wrong-name #:name 42 #:apply apply-proc)
               wrong-name)))

;; ---------------------------------------------------------------------------------------
;; Syntax errors

(test-case "syntax: an undeclared service is an unbound identifier"
  (check-regexp-match
   #rx"undeclared-service: unbound identifier"
   (syntax-error-message
    (define-plugin p #:inject (tools) (lambda (ctx config) undeclared-service)))))

(test-case "syntax: duplicate keys"
  (check-regexp-match
   #rx"duplicate injected key"
   (syntax-error-message
    (define-plugin p #:inject (tools [tools #:optional]) (lambda (ctx config) (void)))))
  (check-regexp-match
   #rx"duplicate provided key"
   (syntax-error-message
    (define-plugin p #:provides (a b a) (lambda (ctx config) (void)))))
  (check-regexp-match
   #rx"duplicate name for an injected service"
   (syntax-error-message
    (define-plugin p #:inject (tools [store #:as tools]) (lambda (ctx config) (void)))))
  (check-regexp-match
   #rx"name of the body's context or config argument"
   (syntax-error-message
    (define-plugin p #:inject (config) (lambda (ctx config) (void))))))

(test-case "syntax: unknown and repeated keywords"
  (check-regexp-match
   #rx"unknown keyword; expected #:name, #:inject"
   (syntax-error-message
    (define-plugin p #:injects (tools) (lambda (ctx config) (void)))))
  (check-regexp-match
   #rx"duplicate #:name clause"
   (syntax-error-message
    (define-plugin p #:name "a" #:name "b" (lambda (ctx config) (void)))))
  (check-regexp-match
   #rx"missing value after #:meta"
   (syntax-error-message (define-plugin p #:meta))))

(test-case "syntax: malformed inject clauses"
  (check-regexp-match
   #rx"inject clause"
   (syntax-error-message
    (define-plugin p #:inject ([tools #:required]) (lambda (ctx config) (void)))))
  (check-regexp-match
   #rx"list of inject clauses after #:inject"
   (syntax-error-message
    (define-plugin p #:inject tools (lambda (ctx config) (void)))))
  (check-regexp-match
   #rx"list of keys after #:provides"
   (syntax-error-message
    (define-plugin p #:provides ("a") (lambda (ctx config) (void))))))

(test-case "syntax: the body must be a lambda form, a (ctx config) form or #:apply"
  (check-regexp-match
   #rx"not a lambda form and there is no #:apply"
   (syntax-error-message (define-plugin p #:name "p" apply-proc)))
  (check-regexp-match
   #rx"missing body"
   (syntax-error-message (define-plugin p #:name "p")))
  (check-regexp-match
   #rx"a lambda body takes exactly a context and a config argument"
   (syntax-error-message (define-plugin p (lambda (ctx) (void)))))
  (check-regexp-match
   #rx"exactly one expression after #:apply"
   (syntax-error-message (define-plugin p #:apply apply-proc #:name "late")))
  (check-regexp-match
   #rx"cannot assign to an optional service"
   (syntax-error-message
    (define-plugin p
      #:inject ([approval #:optional])
      (lambda (ctx config) (set! approval 1))))))
