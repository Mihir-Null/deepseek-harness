#lang racket/base
;; The declaration forms `schema-object*` and `define-config`: what they define, how accessors
;; read a resolved config, and the syntax errors they report.

(require rackunit
         cordis-data
         cordis-schema)

;; source: docs/racket/contracts/cordis-schema.md, section 12 (the dsh tool-jobs Config)
(define-config tool-jobs-config
  [waitTimeoutMs #:as wait-timeout-ms (schema-number #:min 1 #:default 30000)]
  [completionDelivery (schema-union '("quiet" "wakeup") #:default "wakeup")]
  [maxConsecutiveWakes (schema-number #:min 1)])

(define-config described-config
  #:description "A described config."
  #:default (jobject 'mode "fast")
  [mode (schema-union '("fast" "slow") #:default "slow")]
  ["x-racket" #:as racket-options (schema-object '())]
  [apiKeyEnv #:as api-key-env (schema-volatile (schema-string #:default "DEEPSEEK_API_KEY"))])

(define-config empty-config)

(test-case "define-config defines the object schema"
  (check-true (schema? tool-jobs-config))
  (check-equal? (schema-type tool-jobs-config) "object")
  (check-equal? (jkeys (schema-fields tool-jobs-config))
                '(waitTimeoutMs completionDelivery maxConsecutiveWakes))
  (check-equal? (schema->string tool-jobs-config)
                (string-append "{ waitTimeoutMs?: number, "
                               "completionDelivery?: \"quiet\" | \"wakeup\", "
                               "maxConsecutiveWakes?: number }"))
  (check-equal? (tool-jobs-config (jobject)) (jobject 'waitTimeoutMs 30000
                                                      'completionDelivery "wakeup"))
  (check-exn #rx"^\\$.waitTimeoutMs expected number >= 1 but got 0$"
             (lambda () (tool-jobs-config (jobject 'waitTimeoutMs 0))))
  (check-equal? (empty-config) (jobject))
  (check-equal? (schema->string empty-config) "{}"))

(test-case "accessors read a resolved config"
  (define cfg (tool-jobs-config (jobj ['completionDelivery "quiet"])))
  (check-equal? (tool-jobs-config-wait-timeout-ms cfg) 30000)
  (check-equal? (tool-jobs-config-completionDelivery cfg) "quiet")
  (check-true (void? (tool-jobs-config-maxConsecutiveWakes cfg)))
  ;; With a default: JavaScript's `config.key ?? default`.
  (check-equal? (tool-jobs-config-maxConsecutiveWakes cfg 5) 5)
  (check-equal? (tool-jobs-config-maxConsecutiveWakes cfg (lambda () 6)) 6)
  (check-equal? (tool-jobs-config-maxConsecutiveWakes (jobject 'maxConsecutiveWakes 'null) 7) 7)
  (check-equal? (tool-jobs-config-maxConsecutiveWakes (jobject 'maxConsecutiveWakes 0) 7) 0)
  (check-equal? (tool-jobs-config-completionDelivery (jobject 'completionDelivery #f) #t) #f)
  ;; A hash is accepted where a config is expected.
  (check-equal? (tool-jobs-config-wait-timeout-ms (hash 'waitTimeoutMs 1)) 1)
  (check-exn exn:fail:contract? (lambda () (tool-jobs-config-wait-timeout-ms "cfg")))
  (check-exn #rx"tool-jobs-config-wait-timeout-ms"
             (lambda () (tool-jobs-config-wait-timeout-ms 5))))

(test-case "options, string keys and volatile fields"
  (check-equal? (schema-meta-ref described-config 'description) "A described config.")
  (define cfg (described-config))
  (check-equal? (described-config-mode cfg) "fast")
  (check-equal? (jkeys (schema-fields described-config)) '(mode x-racket apiKeyEnv))
  (check-equal? (described-config-racket-options
                 (described-config (jobject 'x-racket (jobject 'trace #t))))
                (jobject 'trace #t))
  ;; A volatile field yields its reference.
  (check-true (volatile? (described-config-api-key-env cfg)))
  (check-equal? (volatile-ref (described-config-api-key-env cfg)) "DEEPSEEK_API_KEY"))

(test-case "schema-object* is schema-object with unquoted keys"
  (define s
    (schema-object* #:description "Compact." #:hidden? #t
                    [name 'string]
                    ["content-type" (schema-string #:default "text/plain")]
                    [size (schema-natural)]))
  (check-equal? (jvalue->string (schema->jvalue s))
                (jvalue->string
                 (schema->jvalue
                  (schema-object (list (cons 'name 'string)
                                       (cons "content-type" (schema-string #:default "text/plain"))
                                       (cons 'size (schema-natural)))
                                 #:description "Compact."
                                 #:hidden? #t))))
  (check-equal? (schema->string (schema-object*)) "{}")
  (check-equal? (s (jobject 'name "n")) (jobject 'name "n" 'content-type "text/plain")))

;; ---------------------------------------------------------------------------------------------
;; Syntax errors

(define-namespace-anchor anchor)
(define namespace (namespace-anchor->namespace anchor))

;; The message of the syntax error that expanding `form` raises.
(define (syntax-error form)
  (with-handlers ([exn:fail:syntax? exn-message])
    (parameterize ([current-namespace namespace])
      (expand form))
    'no-error))

(define-syntax-rule (check-syntax-error form pattern)
  (check-regexp-match pattern (syntax-error 'form)))

(test-case "a misspelled field is a compile-time error"
  (check-regexp-match
   #rx"tool-config-timeuot: unbound identifier"
   (syntax-error
    '(module misspelled racket/base
       (require cordis-schema cordis-data)
       (define-config tool-config [timeout (schema-number #:default 1)])
       (tool-config-timeuot (tool-config (jobject)))))))

(test-case "define-config reports malformed clauses"
  (check-syntax-error (define-config) #rx"define-config")
  (check-syntax-error (define-config "name" [a (schema-string)]) #rx"expected identifier")
  (check-syntax-error (define-config c [a]) #rx"field clause")
  (check-syntax-error (define-config c [a (schema-string) extra]) #rx"field clause")
  (check-syntax-error (define-config c [5 (schema-string)]) #rx"field clause")
  (check-syntax-error (define-config c a) #rx"field clause")
  (check-syntax-error (define-config c ["quoted key" (schema-string)])
                      #rx"a string-literal key needs #:as")
  (check-syntax-error (define-config c [a #:as "suffix" (schema-string)]) #rx"field clause")
  (check-syntax-error (define-config c [a (schema-string)] [b (schema-string)] [a (schema-number)])
                      #rx"duplicate field key")
  (check-syntax-error (define-config c [a (schema-string)] ["a" #:as other (schema-number)])
                      #rx"duplicate field key")
  (check-syntax-error (define-config c [a #:as same (schema-string)] [b #:as same (schema-number)])
                      #rx"duplicate accessor name")
  (check-syntax-error (define-config c [a-b (schema-string)] [a #:as a-b (schema-number)])
                      #rx"duplicate accessor name")
  (check-syntax-error (define-config c #:as x [a (schema-string)]) #rx"#:as belongs inside")
  (check-syntax-error (define-config c [a (schema-string)] #:hidden? #t) #rx"field clause"))

(test-case "schema-object* reports malformed clauses"
  (check-syntax-error (schema-object* [a]) #rx"field clause")
  (check-syntax-error (schema-object* [a (schema-string)] [a (schema-number)])
                      #rx"duplicate field key")
  (check-syntax-error (schema-object* [a #:as b (schema-string)]) #rx"field clause")
  (check-syntax-error (schema-object* #:default) #rx"schema-object\\*"))
