#lang racket/base
;; The deliberate differences from Schemastery that section 13 of the interface contract lists
;; and that no other test file pins. Each case states what Schemastery gives for the same
;; input, as observed with the vendored source under Node.

(require rackunit
         racket/date
         cordis-data
         cordis-schema)

(define bits (schema-bitset (list (cons 'a 1) (cons 'b 2))))

(test-case "a union member that fails leaves no trace for later members"
  (define s
    (schema-union (list (schema-object* [f bits] [g (schema-number)])
                        (schema-object* [f (schema-any)] [g (schema-string)]))))
  (define input (jobject 'f 3 'g "x"))
  (define-values (value adapted) (schema-resolve s input))
  ;; Schemastery: the first member rewrote f to ["a","b"] before it failed on g, so the second
  ;; member returns { f: ["a","b"], g: "x" }.
  (check-equal? value (jobject 'f 3 'g "x"))
  (check-eq? adapted input)
  ;; The message of a union shows the input, not what a failed member left of it.
  (check-exn #rx"but got {\"f\":3,\"g\":true}$"
             (lambda () (s (jobject 'f 3 'g #t)))))

(test-case "a loose schema whose resolver fails leaves the input as it was"
  (define s (schema-loose (schema-object* [f bits] [g (schema-number)])))
  (define input (jobject 'f 3 'g "x"))
  (define-values (value adapted) (schema-resolve s input))
  (check-equal? value (jobject))
  ;; Schemastery: the input object is left as { f: ["a","b"], g: "x" }.
  (check-eq? adapted input))

(test-case "a result that is the input itself does not follow later rewrites of the input"
  (define s
    (schema-intersect
     (list (schema-any)
           (schema-object* [name (schema-boolean #:default #t)]))))
  (define-values (value adapted)
    (schema-resolve s (jobject 'name (list "a") 'more '()) #:autofix? #t))
  ;; Schemastery: `any` returns the input object, autofix deletes its `name`, and the merge
  ;; writes the default into it: { more: [], name: true }.
  (check-equal? value (jobject 'name (list "a") 'more '()))
  (check-equal? adapted (jobject 'more '())))

(test-case "a member that is undefined is omitted, and callbacks do not see its key"
  (define inner (schema-object* [a (schema-loose (schema-number))] [b (schema-number)]))
  (check-equal? (inner (jobject 'a "x" 'b 1)) (jobject 'b 1))
  ;; Schemastery: Object.keys of the result is ["a", "b"].
  (check-equal? ((schema-transform inner jkeys #t) (jobject 'a "x" 'b 1)) '(b))
  ;; The key still counts as present for the merges: no later member and no input fills it.
  (check-equal?
   ((schema-intersect (list inner (schema-object* [a (schema-string #:default "filled")])))
    (jobject 'a "x" 'b 1))
   (jobject 'b 1)))

(test-case "the type string of a const holding an object or a list"
  ;; Schemastery: String(schema) throws a TypeError; inside a union's message the same text
  ;; appears.
  (check-equal? (schema->string (schema-const (jobject 'a 1))) "[object Object]")
  (check-equal? (schema->string (schema-const (list 1 2))) "1,2")
  (check-exn #rx"^expected \\[object Object\\] \\| 1,2 but got 5$"
             (lambda ()
               ((schema-union (list (schema-const (jobject 'a 1)) (schema-const (list 1 2)))) 5))))

(test-case "date and pattern accept a subset of what JavaScript accepts"
  ;; Schemastery: new Date("Jan 2 2020") is a valid date.
  (check-exn exn:fail:schema? (lambda () ((schema-date) "Jan 2 2020")))
  ;; Schemastery: /\p{Script=Greek}/u is a valid pattern.
  (check-exn exn:fail:contract?
             (lambda () (schema-pattern (schema-string) "\\p{Script=Greek}" #:flags "u"))))

(test-case "opaque values count as objects without keys"
  (define s (schema-object* [a (schema-number #:default 1)]))
  ;; Schemastery resolves a Date the same way; a class instance with enumerable fields would
  ;; contribute them, where a struct contributes none.
  (struct point (x y))
  (for ([opaque (list (current-date) #"bytes" #rx"a" (point 1 2))])
    (check-equal? (s opaque) (jobject 'a 1))))

(test-case "keys keep insertion order, integer-like ones included"
  ;; Schemastery: { "2": 3, "10": 2, b: 1 }.
  (check-equal? (jkeys ((schema-object '()) (jobject 'b 1 '|10| 2 '|2| 3))) '(b |10| |2|))
  (check-equal? (jkeys ((schema-dict (schema-number)) (jobject 'b 1 '|10| 2 '|2| 3)))
                '(b |10| |2|)))
