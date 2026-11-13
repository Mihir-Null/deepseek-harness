#lang racket/base
;; `schema-simplify`, `schema-i18n` and `equal-except-volatile?`. The comparison cases are those
;; of scripts/loader-config-diff.spec.ts.

(require rackunit
         cordis-data
         cordis-schema)

(test-case "simplify removes what equals a default"
  (define s (schema-object* [a (schema-number #:default 1)] [b (schema-string)]))
  ;; source: docs/racket/contracts/cordis-schema.md, section 8
  (check-equal? (schema-simplify s (jobject 'a 1 'b "x" 'c 2)) (jobject 'b "x"))
  (check-equal? (schema-simplify s (jobject 'a 1)) 'null)
  (check-equal? (schema-simplify s (jobject)) 'null)
  (check-equal? (schema-simplify s 'null) 'null)
  (check-equal? (schema-simplify s (hash 'a 2)) (jobject 'a 2))
  (check-equal? (schema-simplify (schema-string) (void)) 'null)
  (check-true (void? (schema-simplify (schema-string #:default "d") (void))))
  (check-equal? (schema-simplify (schema-string #:default "d") "d") 'null)
  (check-equal? (schema-simplify (schema-string #:default "d") "e") "e")
  ;; A dict keeps every key and compares with its default strictly.
  (check-equal? (schema-simplify (schema-dict (schema-number #:default 1)) (jobject 'a 1 'b 2))
                (jobject 'a 'null 'b 2))
  (check-equal? (schema-simplify (schema-dict 'string) (jobject)) 'null)
  (check-true (void? (schema-simplify (schema-dict 'string) (void))))
  (check-equal? (schema-simplify (schema-array (schema-number #:default 1)) (list 1 2))
                (list 'null 2))
  (check-equal? (schema-simplify (schema-array 'string #:default (list ".")) (list ".")) 'null)
  (check-equal? (schema-simplify (schema-tuple (list (schema-number #:default 1) 'string))
                                 (list 1 "a" #t))
                (list 'null "a" #t))
  (check-equal?
   (schema-simplify (schema-intersect (list (schema-object* [a (schema-number #:default 1)])
                                            (schema-object* [b (schema-string #:default "x")])))
                    (jobject 'a 2 'b "x"))
   (jobject 'a 2))
  (define u
    (schema-union (list (schema-object* [kind "a"] [n (schema-number #:default 1)])
                        (schema-object* [kind "b"] [s (schema-string #:default "x")]))))
  (check-equal? (schema-simplify u (jobject 'kind "b" 's "x")) (jobject 'kind "b"))
  (check-equal? (schema-simplify u "other") "other")
  (check-equal? (schema-simplify (schema-transform 'string values) " a ") " a ")
  (check-exn exn:fail? (lambda () (schema-simplify (schema-array 'string) (jobject 'a 1)))))

(test-case "simplify reads through references"
  (define s
    (schema-object* [title (schema-volatile (schema-string #:default "hello"))]
                    [size (schema-volatile (schema-number))]))
  (check-equal? (schema-simplify s (s (jobject))) 'null)
  (check-equal? (schema-simplify s (s (jobject 'title "t" 'size 2))) (jobject 'title "t" 'size 2))
  (check-equal? (schema-simplify (schema-string) (make-volatile "v")) "v"))

(test-case "i18n merges per-locale descriptions into the schema and its children"
  (define s
    (schema-object* [a (schema-description (schema-string) "Original")]
                    [b (schema-array (schema-object* [id (schema-string)]))]))
  (define localized
    (schema-i18n s (jobject 'en (jobject '$description "Root"
                                         'a "Field a"
                                         'b (jobject '$description "List" 'id "Element id"))
                            'zh (jobject 'a (jobject '$desc "Jia")))))
  (check-equal? (schema-meta-ref localized 'description) (jobject 'en "Root"))
  (define fields (schema-fields localized))
  (check-equal? (schema-meta-ref (jref fields 'a) 'description)
                (jobject "" "Original" 'en "Field a" 'zh "Jia"))
  (check-equal? (schema-meta-ref (jref fields 'b) 'description) (jobject 'en "List"))
  (check-equal? (schema-meta-ref (jref (schema-fields (schema-inner (jref fields 'b))) 'id)
                                 'description)
                (jobject 'en "Element id"))
  ;; The original is unchanged.
  (check-true (void? (schema-meta-ref s 'description)))
  (check-equal? (schema-meta-ref (jref (schema-fields s) 'a) 'description) "Original")
  ;; Validation is unaffected.
  (check-equal? (localized (jobject 'a "x")) (s (jobject 'a "x")))
  ;; Messages without a description leave the metadata as it was.
  (check-equal? (jvalue->string (schema-meta (schema-i18n (schema-string) (jobject 'en 5)))) "{}")
  (define d (schema-i18n (schema-dict 'number 'string)
                         (hash 'en (hash '$key "Key" '$value "Value"))))
  (check-equal? (schema-meta-ref (schema-key-schema d) 'description) (jobject 'en "Key"))
  (check-equal? (schema-meta-ref (schema-inner d) 'description) (jobject 'en "Value")))

;; ---------------------------------------------------------------------------------------------
;; source: scripts/loader-config-diff.spec.ts

(define equal equal-except-volatile?)
(define (js-expr source) (jobject '__jsExpr source))

(test-case "ignores volatile fields without running schema callbacks"
  (define calls 0)
  (define (validate value) (set! calls (add1 calls)) value)
  (define s
    (schema-object* [title (schema-volatile (schema-transform (schema-string) validate))]
                    [fixed (schema-string)]))
  (define previous (jobject 'title "old" 'fixed "same"))
  (define next (jobject 'title (js-expr "throw new Error(\"must not run\")") 'fixed "same"))
  (check-true (equal previous next s))
  (check-true (equal previous next s))
  (check-equal? calls 0))

(test-case "ignores absent, nested and whole-object, array and union volatile fields"
  (define s
    (schema-object*
     [nested (schema-object* [value (schema-volatile (schema-string))])]
     [block (schema-volatile (schema-object* [title (schema-string)]))]
     [list (schema-volatile (schema-array (schema-string)))]
     [choice (schema-volatile (schema-union (list (schema-string) (schema-number))))]))
  (define next
    (jobject 'nested (jobject 'value "new") 'block (jobject 'title "new") 'list (list "new")
             'choice 1))
  (check-true (equal (jobject) next s))
  (check-true (equal next (jobject) s))
  (check-true (equal "old" "new" (schema-volatile (schema-string))))
  (define restored (jvalue->schema (string->jvalue (jvalue->string (schema->jvalue s)))))
  (check-true (equal (jobject) next restored)))

(test-case "preserves ordinary and unknown fields, object defaults and parent expressions"
  (define s
    (schema-object*
     [nested (schema-default (schema-object* [live (schema-volatile (schema-string))]
                                             [fixed (schema-string)])
                             (jobject 'fixed "default"))]))
  (check-true (equal (jobject) (jobject 'nested (jobject 'live "new" 'fixed "default")) s))
  (check-false (equal (jobject) (jobject 'nested (jobject 'live "new")) s))
  (check-false (equal (jobject) (jobject 'unknown "new") s))
  (check-false (equal (jobject 'nested (js-expr "source.a")) (jobject 'nested (js-expr "source.b"))
                      s))
  (check-false (equal (jobject 'nested "invalid") (jobject 'nested (jobject 'live "new")) s))
  (check-false (equal (jobject 'nested (seconds->date 0 #f)) (jobject 'nested (seconds->date 1 #f))
                      s))
  (check-false (equal (jobject 'nested '()) (jobject 'nested (list "new")) s)))

(test-case "keeps ordinary raw changes even if validation would normalize them to equal values"
  (define calls 0)
  (define (normalize value) (set! calls (add1 calls)) "same")
  (define s
    (schema-object* [fixed (schema-transform (schema-string) normalize)]
                    [live (schema-volatile (schema-string))]))
  (check-false (equal (jobject 'fixed "first") (jobject 'fixed "second") s))
  (check-equal? calls 0)
  ;; A validator of another kind, or none, compares everything raw.
  (check-false (equal "first" "second" (lambda (value) value)))
  (check-false (equal "first" "second" #f)))

(test-case "compares raw values strictly without a schema"
  (check-false (equal (list (void)) (list 'null) #f))
  (check-false (equal (void) 'null #f))
  (check-true (equal (jobject 'fixed "same") (jobject 'fixed "same") #f))
  (check-false (equal (jobject 'list (list (void))) (jobject 'list (list "new")) #f)))

(test-case "compares recursive schemas conservatively and visits shared nodes at each path"
  ;; A schema cannot contain itself; a lazy node closes the cycle and is never built here.
  (define built 0)
  (define recursive
    (schema-extra
     (schema-object* [value (schema-string)]
                     [child (schema-lazy (lambda () (set! built (add1 built)) recursive))])
     'default
     (void)))
  (check-false (equal (jobject 'value "old") (jobject 'value "new") recursive))
  (check-false (equal (jobject 'child (jobject 'value "old"))
                      (jobject 'child (jobject 'value "new"))
                      recursive))
  (check-equal? built 0)
  (define shared (schema-object* [value (schema-volatile (schema-string))]))
  (define s (schema-object* [first shared] [second shared]))
  (check-true (equal (jobject)
                     (jobject 'first (jobject 'value "one") 'second (jobject 'value "two"))
                     s)))

(test-case "equates absent objects with defaults while preserving ordinary field differences"
  (define s
    (schema-object*
     [nested (schema-default (schema-object* [fixed (schema-string)])
                             (jobject 'fixed "default"))]))
  (for ([absent (list (void) 'null)])
    (check-true (equal absent (jobject) s))
    (check-true (equal (jobject) absent s)))
  (check-true (equal (jobject 'nested 'null) (jobject 'nested (jobject 'fixed "default")) s))
  (check-true (equal (jobject) (jobject 'nested (jobject 'fixed "default")) s))
  (check-false (equal (jobject) (jobject 'nested (jobject 'fixed "changed")) s))
  (check-false (equal (jobject) (jobject 'nested (jobject)) s)))

(test-case "preserves parent expression edits even when their marker matches a volatile field"
  (define s (schema-object* [__jsExpr (schema-volatile (schema-string))]))
  (check-false (equal (jobject '__jsExpr "first") (jobject '__jsExpr "second") s)))

(test-case "detects ordinary array edits in both directions"
  (define s
    (schema-object* [list (schema-array (schema-string))]
                    [live (schema-volatile (schema-string))]))
  (define before (jobject 'list (list (void)) 'live "before"))
  (define after (jobject 'list (list "new") 'live "after"))
  (check-false (equal before after s))
  (check-false (equal after before s)))

(test-case "compares unknown fields whose names match JavaScript prototype properties"
  (define s (schema-object* [live (schema-volatile (schema-string))]))
  (for ([key (list 'constructor 'toString '__proto__)])
    (define previous (jobject key "first" 'live "old"))
    (check-false (equal previous (jobject key "second" 'live "new") s))
    (check-true (equal previous (jobject key "first" 'live "new") s))))

(test-case "compares metadata-free serialized schema nodes and reads hashes"
  (define s
    (jvalue->schema
     (string->jvalue
      (string-append "{\"type\":\"object\",\"dict\":{\"nested\":{\"type\":\"object\","
                     "\"dict\":{\"enabled\":{\"type\":\"boolean\"}}}}}"))))
  (check-false (equal (jobject 'nested (jobject 'enabled #t))
                      (jobject 'nested (jobject 'enabled #f))
                      s))
  (check-true (equal (hash 'nested (hash 'enabled #t)) (jobject 'nested (jobject 'enabled #t)) s)))
