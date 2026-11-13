#lang racket/base
;; Provides the evaluator of the `!!js` expression AST: `js-eval`, `js-interpolate`, `js-parse`,
;; environments (`make-js-env`) and the fallback parameter `current-js-fallback`.
;;
;; The evaluator is a `match` over the AST that the parser documents. It never mutates
;; anything: an evaluation reads the environment and builds new values. A construct outside
;; the implemented subset raises exn:fail:js-expr:unsupported, which `js-eval` hands to the
;; fallback when one is installed.

(require racket/list
         racket/match
         cordis-data
         "expr.rkt"
         "js-builtins.rkt"
         "js-error.rkt"
         "js-object.rkt"
         "js-parse.rkt"
         "js-value.rkt")

(provide js-parse
         js-eval
         js-interpolate
         make-js-env
         js-env?
         js-env-bindings
         current-js-fallback)

;; ---------------------------------------------------------------------------------------------
;; Environments

;; bindings : immutable hash from name (string) to value. lookup : #f, or a procedure
;; (name failure-thunk) -> value that is asked before `bindings`. globals : hash from name to
;; value, asked last.
(struct js-env (bindings lookup globals))

;; make-js-env : hash? #:lookup (or/c #f procedure?) #:globals hash? -> js-env?
;; `bindings` maps global names, as strings or symbols, to values.
(define (make-js-env bindings #:lookup [lookup #f] #:globals [globals js-standard-globals])
  (js-env (for/hash ([(name value) (in-hash bindings)])
            (values (if (symbol? name) (symbol->string name) name) value))
          lookup
          globals))

;; current-js-fallback : (parameter/c (or/c #f (-> string? js-env? any)))
;; Consulted by `js-eval` before it raises exn:fail:js-expr:unsupported.
(define current-js-fallback (make-parameter #f))

(define unbound (string->uninterned-symbol "unbound"))

;; The value of the identifier `name`, or `unbound`. `scope` holds arrow-function parameters.
(define (resolve-identifier name scope env)
  (define local (hash-ref scope name unbound))
  (cond
    [(not (eq? local unbound)) local]
    [else
     (define lookup (js-env-lookup env))
     (define looked-up (if lookup (lookup name (lambda () unbound)) unbound))
     (cond
       [(not (eq? looked-up unbound)) looked-up]
       [else
        (hash-ref (js-env-bindings env) name
                  (lambda () (hash-ref (js-env-globals env) name unbound)))])]))

(define (identifier-value name scope env)
  (define value (resolve-identifier name scope env))
  (cond [(not (eq? value unbound)) value]
        [(unimplemented-global? name) (raise-js-unsupported (format "the global ~a" name))]
        [else (raise-js-error "ReferenceError" (format "~a is not defined" name))]))

;; ---------------------------------------------------------------------------------------------
;; Parsing

;; js-parse : string? -> list?   The AST of an expression source.
(define (js-parse source)
  (define-values (ast positions) (parse-js-expression source))
  ast)

;; The AST and position table of `e`, a js-expr or a source string. A js-expr keeps its parse.
(define (parsed e)
  (cond
    [(string? e) (parse-js-expression e)]
    [(js-expr-cached-ast e) => (lambda (cached) (values (car cached) (cdr cached)))]
    [else
     (define-values (ast positions) (parse-js-expression (js-expr-source e)))
     (set-js-expr-cached-ast! e (cons ast positions))
     (values ast positions)]))

;; ---------------------------------------------------------------------------------------------
;; Evaluation

;; What an evaluation carries: the environment, the source and the position table.
(struct evaluation (env source positions))

;; JavaScript engines stop runaway recursion with a RangeError; so does this limit on nested
;; arrow-function calls.
(define max-call-depth 2000)
(define current-call-depth (make-parameter 0))

;; A short rendering of a callee for "is not a function" messages.
(define (ast->text node)
  (match node
    [(list 'id name) name]
    [(list (or 'member 'opt-member) object name) (string-append (ast->text object) "." name)]
    [(list 'chain inner) (ast->text inner)]
    [(list (or 'call 'opt-call) callee _ ...) (string-append (ast->text callee) "(...)")]
    [(list 'str text) (format "~s" text)]
    [(list 'undefined) "undefined"]
    [(list 'null) "null"]
    [_ "expression"]))

;; ev : evaluates `node`. `scope` maps arrow-function parameters to values. `escape` is the
;; continuation of the enclosing optional chain, called with undefined when a `?.` link finds
;; null or undefined; it is #f outside the links of a chain.
(define (ev node scope ctx escape)
  (with-js-site (evaluation-source ctx) (hash-ref (evaluation-positions ctx) node #f)
    (match node
      [(list 'num n) n]
      [(list 'str s) s]
      [(list 'bool b) b]
      [(list 'null) 'null]
      [(list 'undefined) (void)]
      [(list 'id name) (identifier-value name scope (evaluation-env ctx))]
      [(list 'template parts ...)
       (apply string-append
              (for/list ([part (in-list parts)])
                (if (string? part) part (js->string (ev part scope ctx #f)))))]
      [(list 'array elements ...) (ev-items elements scope ctx)]
      [(list 'object properties ...)
       (entries->jobject
        (append*
         (for/list ([property (in-list properties)])
           (match property
             [(list 'prop name value) (list (cons name (ev value scope ctx #f)))]
             [(list 'computed key value)
              (define name (js->property-key (ev key scope ctx #f)))
              (list (cons name (ev value scope ctx #f)))]
             [(list 'spread value) (spread-entries (ev value scope ctx #f))]))))]
      [(list 'member object name) (get-member (ev object scope ctx escape) name)]
      [(list 'opt-member object name)
       (define value (ev object scope ctx escape))
       (if (js-nullish? value) (escape (void)) (get-member value name))]
      [(list 'index object key)
       (define value (ev object scope ctx escape))
       (get-index value (ev key scope ctx #f))]
      [(list 'opt-index object key)
       (define value (ev object scope ctx escape))
       (if (js-nullish? value) (escape (void)) (get-index value (ev key scope ctx #f)))]
      [(list 'call callee arguments ...) (ev-call callee arguments scope ctx escape #f)]
      [(list 'opt-call callee arguments ...) (ev-call callee arguments scope ctx escape #t)]
      [(list 'new callee arguments ...)
       (define constructor (ev callee scope ctx #f))
       (construct constructor (ev-items arguments scope ctx) (ast->text callee))]
      [(list 'chain inner) (let/ec escape (ev inner scope ctx escape))]
      [(list 'unary operator operand) (ev-unary operator operand scope ctx)]
      [(list 'binary operator left right)
       (define a (ev left scope ctx #f))
       (define b (ev right scope ctx #f))
       (case operator
         [(+) (js-add a b)]
         [(- * / %) (js-arithmetic operator a b)]
         [(< > <= >=) (js-compare operator a b)]
         [(===) (js-strict-equal? a b)]
         [(!==) (not (js-strict-equal? a b))]
         [(==) (js-loose-equal? a b)]
         [else (not (js-loose-equal? a b))])]
      [(list 'and left right)
       (define a (ev left scope ctx #f))
       (if (js-truthy? a) (ev right scope ctx #f) a)]
      [(list 'or left right)
       (define a (ev left scope ctx #f))
       (if (js-truthy? a) a (ev right scope ctx #f))]
      [(list 'coalesce left right)
       (define a (ev left scope ctx #f))
       (if (js-nullish? a) (ev right scope ctx #f) a)]
      [(list 'if test consequent alternate)
       (if (js-truthy? (ev test scope ctx #f))
           (ev consequent scope ctx #f)
           (ev alternate scope ctx #f))]
      [(list 'arrow (list parameters ...) body)
       (lambda arguments
         (define depth (add1 (current-call-depth)))
         (when (> depth max-call-depth)
           (with-js-site (evaluation-source ctx) (hash-ref (evaluation-positions ctx) node #f)
             (raise-js-error "RangeError" "Maximum call stack size exceeded")))
         (define inner
           (for/fold ([inner scope] [rest arguments] #:result inner)
                     ([parameter (in-list parameters)])
             (if (pair? rest)
                 (values (hash-set inner parameter (car rest)) (cdr rest))
                 (values (hash-set inner parameter (void)) rest))))
         (parameterize ([current-call-depth depth])
           (ev body inner ctx #f)))]
      [_ (raise-arguments-error 'js-eval "malformed expression tree" "node" node)])))

;; The values of array elements or call arguments, with spread elements expanded.
(define (ev-items nodes scope ctx)
  (append*
   (for/list ([node (in-list nodes)])
     (match node
       [(list 'spread inner) (iterate-value (ev inner scope ctx #f))]
       [_ (list (ev node scope ctx #f))]))))

;; The value of object[key].
(define (get-index object key)
  (cond
    [(and (list? object) (array-index key))
     => (lambda (i) (if (< i (length object)) (list-ref object i) (void)))]
    [else (get-member object (js->property-key key))]))

;; A call. A callee that is a member access is a method call on the object it reads from.
;; `optional?` marks the form f?.(...), which yields undefined for a null or undefined callee.
(define (ev-call callee arguments scope ctx escape optional?)
  (define (method-call object-node name-of link-optional?)
    (define this (ev object-node scope ctx escape))
    (when (and link-optional? (js-nullish? this)) (escape (void)))
    (define name (name-of))
    (when (and optional? (js-nullish? (get-member this name))) (escape (void)))
    (call-method this name (ev-items arguments scope ctx) (ast->text callee)))
  (match callee
    [(list 'member object name) (method-call object (lambda () name) #f)]
    [(list 'opt-member object name) (method-call object (lambda () name) #t)]
    [(list 'index object key)
     (method-call object (lambda () (js->property-key (ev key scope ctx #f))) #f)]
    [(list 'opt-index object key)
     (method-call object (lambda () (js->property-key (ev key scope ctx #f))) #t)]
    [_
     (define f (ev callee scope ctx escape))
     (when (and optional? (js-nullish? f)) (escape (void)))
     (call-function f (ev-items arguments scope ctx) (ast->text callee))]))

(define (ev-unary operator operand scope ctx)
  (case operator
    [(typeof)
     (match operand
       ;; typeof of a name that is not defined is "undefined", not a ReferenceError.
       [(list 'id name)
        (define value (resolve-identifier name scope (evaluation-env ctx)))
        (cond [(not (eq? value unbound)) (js-typeof value)]
              [(unimplemented-global? name)
               (raise-js-unsupported (format "the global ~a" name))]
              [else "undefined"])]
       [_ (js-typeof (ev operand scope ctx #f))])]
    [(!) (not (js-truthy? (ev operand scope ctx #f)))]
    [(-) (js-negate (js->number (ev operand scope ctx #f)))]
    [(+) (js->number (ev operand scope ctx #f))]
    [else
     (ev operand scope ctx #f)
     (void)]))

;; js-eval : (or/c js-expr? string?) js-env? -> any
;; The value of the expression in `env`.
(define (js-eval e env)
  (define source (if (js-expr? e) (js-expr-source e) e))
  (define (evaluate)
    (define-values (ast positions) (parsed e))
    (with-js-site source #f
      (ev ast (hash) (evaluation env source positions) #f)))
  (define fallback (current-js-fallback))
  (cond
    [fallback
     ;; The fallback runs after the handler has returned, outside the failed evaluation.
     (define outcome
       (with-handlers ([exn:fail:js-expr:unsupported? (lambda (x) unbound)])
         (box (evaluate))))
     (if (eq? outcome unbound)
         (fallback source env)
         (unbox outcome))]
    [else (evaluate)]))

;; js-interpolate : any/c js-env? -> any/c
;; `v` with every expression node inside its lists and objects replaced by its value, as dsh's
;; `interpolate` does. An object with a string `__jsExpr` member is an expression node too.
(define (js-interpolate v env)
  (cond
    [(js-expr? v) (js-eval v env)]
    [(list? v) (for/list ([item (in-list v)]) (js-interpolate item env))]
    [(js-plain-object? v)
     (define source (jref v '__jsExpr (void)))
     (if (string? source)
         (js-eval source env)
         (make-jobject
          (for*/list ([(key item) (in-jobject (if (jobject? v) v (jmerge v)))]
                      [value (in-value (js-interpolate item env))]
                      #:unless (void? value))
            (cons key value))))]
    [else v]))
