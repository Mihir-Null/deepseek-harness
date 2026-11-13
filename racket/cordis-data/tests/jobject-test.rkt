#lang racket/base
;; Tests for section 1 of docs/racket/contracts/cordis-data.md: jvalues, jobject construction,
;; lookup, functional update, merging, iteration, jsexpr conversion, `equal?`, printing, the
;; acceptance of plain hashes, and the `jobj-pat` match expander.

(require rackunit
         racket/match
         syntax/macro-testing
         cordis-data)

(define sample (jobject 'b 1 'a 2 'c 3))

(test-case "jobject keeps insertion order and interns string keys"
  (check-true (jobject? sample))
  (check-equal? (jkeys sample) '(b a c))
  (check-equal? (jvalues sample) '(1 2 3))
  (check-equal? (jkeys (jobject "x" 1 'y 2 "z" 3)) '(x y z))
  (check-equal? (jref (jobject "x" 1) 'x) 1)
  (check-equal? (jcount sample) 3)
  (check-equal? (jcount (jobject)) 0)
  (check-false (jobject? (hash 'a 1)))
  (check-false (jobject? '((a . 1)))))

(test-case "a later duplicate key replaces the value and keeps the first position"
  (define obj (jobject 'a 1 'b 2 "a" 3))
  (check-equal? (jobject->alist obj) '((a . 3) (b . 2)))
  (check-equal? (jobject->alist (make-jobject '((a . 1) ("b" . 2) (a . 3) (c . 4))))
                '((a . 3) (b . 2) (c . 4))))

(test-case "constructors reject malformed arguments and (void)"
  (check-exn exn:fail:contract? (lambda () (jobject 'a)))
  (check-exn exn:fail:contract? (lambda () (jobject 1 2)))
  (check-exn exn:fail:contract? (lambda () (jobject 'a (void))))
  (check-exn exn:fail:contract? (lambda () (make-jobject '((a . 1) b))))
  (check-exn exn:fail:contract? (lambda () (make-jobject (list (cons 'a (void))))))
  (check-exn exn:fail:contract? (lambda () (make-jobject (list (cons 5 1))))))

(test-case "empty-jobject is the empty object"
  (check-true (jobject? empty-jobject))
  (check-equal? (jkeys empty-jobject) '())
  (check-equal? empty-jobject (jobject))
  (check-equal? empty-jobject (make-jobject '())))

(test-case "jobj builds from clauses in order and honours #:when"
  (define order '())
  (define (note tag value)
    (set! order (cons tag order))
    value)
  (define obj
    (jobj [(note 'k1 'first) (note 'v1 1)]
          #:when (note 't2 #f) [(note 'k2 'skipped) (note 'v2 2)]
          #:when (note 't3 #t) ["third" (note 'v3 3)]
          ['first (note 'v4 4)]))
  (check-equal? (jobject->alist obj) '((first . 4) (third . 3)))
  ;; Keys and values are evaluated left to right; a clause whose test is false evaluates neither.
  (check-equal? (reverse order) '(k1 v1 t2 t3 v3 v4))
  (check-equal? (jobj) empty-jobject)
  (check-exn exn:fail:contract? (lambda () (jobj [5 1])))
  (check-exn exn:fail:contract? (lambda () (jobj ['a (void)]))))

(test-case "jobj reports a malformed clause at expansion"
  (check-exn #rx"jobj clause" (lambda () (convert-compile-time-error (jobj ['a]))))
  (check-exn #rx"jobj clause" (lambda () (convert-compile-time-error (jobj ['a 1] "b"))))
  (check-exn exn:fail:syntax? (lambda () (convert-compile-time-error (jobj #:when #t)))))

(test-case "jvalue? is a deep check"
  (check-true (jvalue? sample))
  (check-true (jvalue? (list 1 2.5 "x" #t #f 'null '() (jobject 'a (list (jobject))))))
  (check-true (jvalue? 1/3))
  (check-true (jvalue? (expt 10 400)))
  (check-true (jvalue? (hash 'a (list 1 (hash "b" 'null)))))
  (check-false (jvalue? +nan.0))
  (check-false (jvalue? +inf.0))
  (check-false (jvalue? -inf.0))
  (check-false (jvalue? (void)))
  (check-false (jvalue? 'undefined))
  (check-false (jvalue? #\a))
  (check-false (jvalue? (vector 1 2)))
  (check-false (jvalue? (cons 1 2)))
  (check-false (jvalue? (list 1 (list 2 (void)))))
  (check-false (jvalue? (jobject 'a (list 1 +nan.0))))
  (check-false (jvalue? (jobject 'a car)))
  (check-false (jvalue? (hash 1 2)))
  (check-false (jvalue? 1+2i)))

(test-case "jref and jhas?"
  (check-equal? (jref sample 'a) 2)
  (check-equal? (jref sample "a") 2)
  (check-equal? (jref sample 'missing) #f)
  (check-equal? (jref sample 'missing 'fallback) 'fallback)
  (check-equal? (jref sample 'missing (lambda () (+ 40 2))) 42)
  (check-equal? (jref (jobject 'a #f) 'a 'fallback) #f)
  (check-equal? (jref (jobject 'a 'null) 'a 'fallback) 'null)
  (check-true (jhas? sample 'c))
  (check-true (jhas? sample "c"))
  (check-false (jhas? sample 'd))
  (check-true (jhas? (jobject 'a #f) 'a))
  (check-exn exn:fail:contract? (lambda () (jref '(1 2) 'a)))
  (check-exn exn:fail:contract? (lambda () (jref sample 5))))

(test-case "jref* follows keys and indexes"
  (define doc (jobject 'a (list 10 (jobject 'b (list 'null "deep"))) 'n 5))
  (check-equal? (jref* doc '()) doc)
  (check-equal? (jref* doc '(n)) 5)
  (check-equal? (jref* doc '(a 0)) 10)
  (check-equal? (jref* doc '("a" 1 b 1)) "deep")
  (check-equal? (jref* doc '(a 1 b 0)) 'null)
  (check-equal? (jref* doc '(a 2)) #f)
  (check-equal? (jref* doc '(a 2) 'none) 'none)
  (check-equal? (jref* doc '(a x) 'none) 'none)
  (check-equal? (jref* doc '(n 0) 'none) 'none)
  (check-equal? (jref* doc '(n x) 'none) 'none)
  (check-equal? (jref* doc '(0) 'none) 'none)
  (check-equal? (jref* doc '(zz y) (lambda () 'computed)) 'computed)
  (check-equal? (jref* (list 1 (list 2 3)) '(1 1)) 3)
  (check-equal? (jref* (hash 'a (hash "b" 1)) '(a b)) 1)
  (check-exn exn:fail:contract? (lambda () (jref* doc '(a -1))))
  (check-exn exn:fail:contract? (lambda () (jref* doc 'a))))

(test-case "jset keeps an existing position and appends a new key"
  (check-equal? (jobject->alist (jset sample 'a 20)) '((b . 1) (a . 20) (c . 3)))
  (check-equal? (jobject->alist (jset sample "d" 4)) '((b . 1) (a . 2) (c . 3) (d . 4)))
  (check-equal? (jobject->alist (jset (jset sample 'd 4) 'e 5))
                '((b . 1) (a . 2) (c . 3) (d . 4) (e . 5)))
  ;; The original is unchanged.
  (check-equal? (jobject->alist sample) '((b . 1) (a . 2) (c . 3)))
  (check-exn exn:fail:contract? (lambda () (jset sample 'a (void)))))

(test-case "many incremental jsets keep order"
  (define count 20000)
  (define built
    (for/fold ([obj empty-jobject]) ([i (in-range count)])
      (jset obj (string->symbol (format "k~a" i)) i)))
  (check-equal? (jcount built) count)
  (check-equal? (jvalues built) (for/list ([i (in-range count)]) i))
  (check-equal? (jref built 'k19999) 19999))

(test-case "jset* updates deeply and creates what is missing"
  (define doc (jobject 'a (jobject 'b 1) 'list (list 1 2)))
  (check-equal? (jset* doc '() 5) 5)
  (check-equal? (jset* doc '(a b) 2) (jobject 'a (jobject 'b 2) 'list (list 1 2)))
  (check-equal? (jkeys (jset* doc '(a c) 3)) '(a list))
  (check-equal? (jref* (jset* doc '(a c) 3) '(a c)) 3)
  (check-equal? (jset* doc '(x y z) 1)
                (jobject 'a (jobject 'b 1) 'list (list 1 2) 'x (jobject 'y (jobject 'z 1))))
  (check-equal? (jref (jset* doc '(list 0) 'first) 'list) '(first 2))
  (check-equal? (jref (jset* doc '(list 2) 'appended) 'list) '(1 2 appended))
  (check-equal? (jref (jset* doc '(list 4) 'padded) 'list) '(1 2 null null padded))
  (check-equal? (jset* empty-jobject '(items 1 name) "n")
                (jobject 'items (list 'null (jobject 'name "n"))))
  (check-equal? (jset* '() '(0) 1) '(1))
  (check-equal? (jset* (hash 'a 1) '(b) 2) (jobject 'a 1 'b 2))
  (check-exn exn:fail:contract? (lambda () (jset* doc '(a b c) 1)))
  (check-exn exn:fail:contract? (lambda () (jset* doc '(list key) 1)))
  (check-exn exn:fail:contract? (lambda () (jset* doc '(a 0) 1)))
  (check-exn exn:fail:contract? (lambda () (jset* (jobject 'a 'null) '(a b) 1)))
  (check-exn exn:fail:contract? (lambda () (jset* doc '(a) (void)))))

(test-case "jupdate and jremove"
  (check-equal? (jobject->alist (jupdate sample 'a add1)) '((b . 1) (a . 3) (c . 3)))
  (check-equal? (jobject->alist (jupdate sample 'n add1 0)) '((b . 1) (a . 2) (c . 3) (n . 1)))
  (check-equal? (jref (jupdate sample 'n add1 (lambda () 9)) 'n) 10)
  (check-equal? (jref (jupdate sample "n" (lambda (v) (list v))) 'n) '(#f))
  (check-exn exn:fail:contract? (lambda () (jupdate sample 'a void)))
  (check-equal? (jobject->alist (jremove sample 'a)) '((b . 1) (c . 3)))
  (check-equal? (jobject->alist (jremove sample "b")) '((a . 2) (c . 3)))
  (check-equal? (jremove sample 'missing) sample)
  (check-equal? (jobject->alist (jset (jremove sample 'b) 'b 9)) '((a . 2) (c . 3) (b . 9)))
  (check-equal? (jobject->alist (jremove (jset sample 'd 4) 'd)) '((b . 1) (a . 2) (c . 3))))

(test-case "jobject->hasheq is shallow"
  (define inner (jobject 'x 1))
  (define table (jobject->hasheq (jobject 'a inner 'b 2)))
  (check-true (and (hash? table) (hash-eq? table) (immutable? table)))
  (check-eq? (hash-ref table 'a) inner)
  (check-equal? (hash-ref table 'b) 2))

(test-case "jvalue->jsexpr and jsexpr->jvalue convert deeply"
  (define doc (jobject 'b (list 1 (jobject 'z 'null 'y 1/4)) 'a "s"))
  (define jsexpr (jvalue->jsexpr doc))
  (check-equal? jsexpr (hasheq 'b (list 1 (hasheq 'z 'null 'y 0.25)) 'a "s"))
  (check-true (hash? (cadr (hash-ref jsexpr 'b))))
  (check-equal? (jvalue->jsexpr (hash "k" (list (hash 'n 1)))) (hasheq 'k (list (hasheq 'n 1))))
  (check-exn exn:fail:contract? (lambda () (jvalue->jsexpr (jobject 'a +nan.0))))
  (check-exn exn:fail:contract? (lambda () (jvalue->jsexpr (list 1 (vector)))))
  (define back (jsexpr->jvalue (hasheq 'b (list 1 (hasheq 'z 'null 'y 0.25)) 'a "s")))
  (check-true (jobject? back))
  (check-equal? (jkeys back) '(a b))
  (check-equal? (jkeys (cadr (jref back 'b))) '(y z))
  (check-equal? back (jobject 'a "s" 'b (list 1 (jobject 'y 0.25 'z 'null))))
  ;; A jobject already inside keeps its order.
  (check-equal? (jkeys (jref (jsexpr->jvalue (hasheq 'k (jobject 'z 1 'a (hash 'q 1)))) 'k)) '(z a))
  (check-exn exn:fail:contract? (lambda () (jsexpr->jvalue (hasheq 'a (void)))))
  (check-exn exn:fail:contract? (lambda () (jsexpr->jvalue (list +inf.0)))))

(test-case "jmerge is shallow and right-biased, keeping first positions"
  (check-equal? (jmerge) empty-jobject)
  (check-equal? (jobject->alist (jmerge sample)) '((b . 1) (a . 2) (c . 3)))
  (check-equal? (jobject->alist (jmerge sample (jobject 'd 4 'a 20) (jobject 'b 10 'e 5)))
                '((b . 10) (a . 20) (c . 3) (d . 4) (e . 5)))
  (check-equal? (jmerge (jobject 'a (jobject 'x 1)) (jobject 'a (jobject 'y 2)))
                (jobject 'a (jobject 'y 2)))
  (check-equal? (jobject->alist (jmerge (hash 'b 1 'a 2) (hash "c" 3))) '((a . 2) (b . 1) (c . 3))))

(test-case "jmerge-deep merges objects recursively and lets the second value win otherwise"
  (define a (jobject 'keep 1 'obj (jobject 'x 1 'y (jobject 'p 1)) 'list (list 1 2) 's "old"))
  (define b (jobject 'obj (jobject 'y (jobject 'q 2) 'z 3) 'list (list 3) 's (jobject 'n 1) 'new #t))
  (define merged (jmerge-deep a b))
  (check-equal? (jkeys merged) '(keep obj list s new))
  (check-equal? (jref merged 'obj) (jobject 'x 1 'y (jobject 'p 1 'q 2) 'z 3))
  (check-equal? (jkeys (jref merged 'obj)) '(x y z))
  (check-equal? (jref merged 'list) '(3))
  (check-equal? (jref merged 's) (jobject 'n 1))
  (check-equal? (jmerge-deep 1 2) 2)
  (check-equal? (jmerge-deep a 'null) 'null)
  (check-equal? (jmerge-deep '(1) a) a)
  (check-true (jobject? (jmerge-deep 1 (hash 'a 1))))
  (check-equal? (jmerge-deep (hash 'a (hash 'x 1)) (hash 'a (hash 'y 2)))
                (jobject 'a (jobject 'x 1 'y 2))))

(test-case "in-jobject yields keys and values in order"
  (check-equal? (for/list ([(key value) (in-jobject sample)]) (cons key value))
                '((b . 1) (a . 2) (c . 3)))
  (check-equal? (for/list ([(key value) (in-jobject (jset sample 'd 4))]) key) '(b a c d))
  (check-equal? (for/list ([(key value) (in-jobject empty-jobject)]) key) '())
  ;; Used as an expression rather than directly in a `for` clause.
  (define sequence (in-jobject sample))
  (check-equal? (for/list ([(key value) sequence]) (list key value)) '((b 1) (a 2) (c 3)))
  (check-equal? (for/list ([(key value) (in-jobject (hash "y" 2 "x" 1))]) (cons key value))
                '((x . 1) (y . 2)))
  (check-exn exn:fail:contract? (lambda () (for ([(key value) (in-jobject 5)]) key))))

(test-case "jmap and jfilter"
  (check-equal? (jobject->alist (jmap (lambda (key value) (list key (* 10 value))) sample))
                '((b . (b 10)) (a . (a 20)) (c . (c 30))))
  (check-equal? (jobject->alist (jfilter (lambda (key value) (odd? value)) sample))
                '((b . 1) (c . 3)))
  (check-equal? (jobject->alist (jfilter (lambda (key value) (not (eq? key 'b))) (jset sample 'd 4)))
                '((a . 2) (c . 3) (d . 4)))
  (check-exn exn:fail:contract? (lambda () (jmap (lambda (key value) (void)) sample)))
  (check-exn exn:fail:contract? (lambda () (jmap add1 sample))))

(test-case "equal? compares jobjects as maps and equal-hash agrees"
  (define one (jobject 'a 1 'b (list (jobject 'x 1 'y 2))))
  (define two (jobject 'b (list (jobject 'y 2 'x 1)) 'a 1))
  (check-equal? one two)
  (check-equal? (equal-hash-code one) (equal-hash-code two))
  (check-equal? (equal-secondary-hash-code one) (equal-secondary-hash-code two))
  (check-not-equal? one (jobject 'a 1))
  (check-not-equal? one (jobject 'a 1 'b (list (jobject 'x 1 'y 3))))
  (check-not-equal? (jobject 'a 1) (jobject 'a 1.0))
  (check-not-equal? (jobject 'a 1) (hasheq 'a 1))
  (check-equal? (jset (jremove one 'a) 'a 1) two)
  ;; Usable as a key in an `equal?`-based table.
  (check-equal? (hash-ref (hash one 'found) two #f) 'found))

(test-case "a jobject prints as compact JSON"
  (check-equal? (format "~a" (jobject 'a 1 'b 2)) "#<jobject {\"a\":1,\"b\":2}>")
  (check-equal? (format "~s" (jobject 'a 1 'b 2)) "#<jobject {\"a\":1,\"b\":2}>")
  (check-equal? (format "~v" (jobject 'a 1 'b 2)) "#<jobject {\"a\":1,\"b\":2}>")
  (check-equal? (format "~a" (jobject 'k (list "x\n" 1.0 'null (jobject))))
                "#<jobject {\"k\":[\"x\\n\",1,null,{}]}>")
  (check-equal? (format "~a" empty-jobject) "#<jobject {}>")
  ;; Values outside the model do not stop it printing.
  (check-equal? (format "~a" (jobject 'p car 'h (hash 'x 1)))
                "#<jobject {\"p\":#<procedure:car>,\"h\":#hash((x . 1))}>")
  (check-regexp-match #rx"nan" (format "~a" (jobject 'n +nan.0))))

(test-case "a plain hash is read as an object with its keys in symbol<? order"
  (define by-symbol (hash 'b 1 'a 2 'c 3))
  (define by-string (make-hash '(("b" . 1) ("a" . 2) ("c" . 3))))
  (for ([table (in-list (list by-symbol by-string))])
    (check-equal? (jkeys table) '(a b c))
    (check-equal? (jvalues table) '(2 1 3))
    (check-equal? (jcount table) 3)
    (check-equal? (jref table 'a) 2)
    (check-equal? (jref table "b") 1)
    (check-equal? (jref table 'zz 'none) 'none)
    (check-true (jhas? table "c"))
    (check-false (jhas? table 'd))
    (check-equal? (jobject->alist table) '((a . 2) (b . 1) (c . 3)))
    (check-true (jobject? (jset table 'd 4)))
    (check-equal? (jkeys (jset table 'd 4)) '(a b c d))
    (check-equal? (jkeys (jremove table 'b)) '(a c))
    (check-equal? (jref (jupdate table 'a add1) 'a) 3)
    (check-equal? (jobject->hasheq table) (hasheq 'a 2 'b 1 'c 3)))
  ;; An eq?-keyed hash with string keys is still found by name.
  (check-equal? (jref (hasheq (string-copy "k") 1) "k") 1)
  (check-equal? (jref (hasheq (string-copy "k") 1) 'other 'none) 'none)
  (check-exn exn:fail:contract? (lambda () (jkeys (hash 1 2))))
  (check-exn exn:fail:contract? (lambda () (jkeys (hash 'a 1 "a" 2))))
  (check-exn exn:fail:contract? (lambda () (jkeys (hash 'a (void))))))

(test-case "jobj-pat matches keys, defaults and the rest"
  (check-equal? (match sample [(jobj-pat [a x] [c y]) (list x y)]) '(2 3))
  (check-equal? (match sample [(jobj-pat) 'any-object]) 'any-object)
  (check-equal? (match sample
                  [(jobj-pat [missing _]) 'wrong]
                  [(jobj-pat [a (? string?)]) 'wrong-type]
                  [(jobj-pat [a (? number? n)]) n])
                2)
  (check-equal? (match sample [(jobj-pat [missing m #:default 'dflt] [a n #:default 0]) (list m n)])
                '(dflt 2))
  (check-equal? (match sample
                  [(jobj-pat [a _] #:rest others) (jobject->alist others)])
                '((b . 1) (c . 3)))
  (check-equal? (match sample [(jobj-pat [b 1] [a 2] [c 3] #:rest others) others]) empty-jobject)
  (check-equal? (match (jobject 'type "text" 'text "hi" 'extra 1)
                  [(jobj-pat [type "image"]) 'image]
                  [(jobj-pat [type "text"] [text body]) body])
                "hi")
  (check-equal? (match (jobject '$ref "#/defs/x" 'nested (jobject 'deep (list 1 2)))
                  [(jobj-pat ["$ref" ref] [nested (jobj-pat [deep (list _ second)])]) (list ref second)])
                '("#/defs/x" 2))
  ;; A key that holds #f or 'null is present.
  (check-equal? (match (jobject 'flag #f 'none 'null)
                  [(jobj-pat [flag f #:default 'unset] [none n]) (list f n)])
                '(#f null))
  (check-equal? (match 5 [(jobj-pat) 'object] [_ 'not-an-object]) 'not-an-object)
  (check-equal? (match '(1 2) [(jobj-pat [a _]) 'object] [_ 'not-an-object]) 'not-an-object)
  (check-equal? (match (hash 'a 1 "b" 2) [(jobj-pat [a x] [b y] #:rest others) (list x y others)])
                (list 1 2 empty-jobject))
  ;; The default expression is evaluated only when the key is absent.
  (check-equal? (match sample [(jobj-pat [a n #:default (error "not evaluated")]) n]) 2))

(test-case "jobj-pat reports malformed clauses at expansion"
  (check-exn #rx"duplicate key"
             (lambda () (convert-compile-time-error (match sample [(jobj-pat [a x] [a y]) x]))))
  (check-exn #rx"jobj-pat clause"
             (lambda () (convert-compile-time-error (match sample [(jobj-pat [a]) 1]))))
  (check-exn #rx"literal key"
             (lambda () (convert-compile-time-error (match sample [(jobj-pat [(a) x]) x])))))
