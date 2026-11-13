#lang racket/base
;; Tests of `dsh-session/lossless`: rule 1 of the dsh-session contract.
;; Mirrors packages/core/session/tests/json.spec.ts without the JavaScript realm, getter,
;; Proxy and prototype cases, which have no counterpart for immutable jvalues.

(require rackunit
         cordis-data
         dsh-session/lossless)

(struct exotic (value))

(test-case "rule 1: the JSON scalar vocabulary is kept and unsupported scalars are rejected"
  (check-eq? (snapshot-json 'null) 'null)
  (check-eq? (snapshot-json #t) #t)
  (check-equal? (snapshot-json "text") "text")
  (check-equal? (snapshot-json 1.25) 1.25)
  (check-equal? (snapshot-json 7) 7)
  (check-false (snapshot-json -0.0))
  (check-false (lossless-json? -0.0))
  (check-false (snapshot-json +nan.0))
  (check-false (snapshot-json +inf.0))
  (check-false (snapshot-json -inf.0))
  (check-false (snapshot-json (lambda () (void))))
  (check-false (snapshot-json 'value))
  (check-false (snapshot-json (void)))
  (check-false (snapshot-json #\a))
  (check-false (snapshot-json #"bytes"))
  (check-false (snapshot-json '#:keyword)))

(test-case "rule 1: lossless-json? recognises supported scalars and rejects lossy ones"
  (check-true (lossless-json? 'null))
  (check-true (lossless-json? #f))
  (check-true (lossless-json? "text"))
  (check-true (lossless-json? 1.25))
  (check-true (lossless-json? 0.0))
  (check-true (lossless-json? 1/3))
  (check-false (lossless-json? -0.0))
  (check-false (lossless-json? +nan.0))
  (check-false (lossless-json? (lambda () (void))))
  (check-false (lossless-json? 'value))
  (check-false (lossless-json? (void))))

(test-case "rule 1: the value #f is lossless although its snapshot is #f"
  (check-true (lossless-json? #f))
  (check-eq? (snapshot-json #f) #f))

(test-case "rule 1: arrays and objects are accepted at any depth"
  (check-true (lossless-json? (list 1 (jobject 'nested 'null) (jobject 'value #t))))
  (check-true (lossless-json? (jobject 'value (list 1 2))))
  (check-true (lossless-json? '()))
  (check-true (lossless-json? empty-jobject))
  (check-true (lossless-json? (hash 'a (list (hash "b" 1))))))

(test-case "rule 1: a value that is already normal is returned unchanged"
  (define value
    (jobject 'list (list (jobject 'shared (jobject 'value 1)) 2.5 "text")
             'alias (jobject 'value 1)
             'empty '()))
  (check-eq? (snapshot-json value) value)
  (define nested (list value (list value)))
  (check-eq? (snapshot-json nested) nested))

(test-case "rule 1: every plain hash becomes a jobject with sorted keys"
  (define snapshot (snapshot-json (hash 'b 1 'a (hash "d" 'null "c" (list (hash 'z #t))))))
  (check-true (jobject? snapshot))
  (check-equal? (jkeys snapshot) '(a b))
  (check-true (jobject? (jref snapshot 'a)))
  (check-equal? (jkeys (jref snapshot 'a)) '(c d))
  (check-true (jobject? (car (jref* snapshot '(a c)))))
  (check-equal? (jvalue->string snapshot) "{\"a\":{\"c\":[{\"z\":true}],\"d\":null},\"b\":1}")
  (define mutable (make-hash (list (cons "k" 1))))
  (define mutable-snapshot (snapshot-json mutable))
  (hash-set! mutable "k" 2)
  (check-equal? (jref mutable-snapshot 'k) 1))

(test-case "rule 1: a jobject that holds a hash is rebuilt in its own key order"
  (define snapshot (snapshot-json (jobject 'z 1 'a (hash 'k "v"))))
  (check-equal? (jkeys snapshot) '(z a))
  (check-true (jobject? (jref snapshot 'a))))

(test-case "rule 1: every mutable string becomes an immutable copy"
  (define text (string-copy "mutable"))
  (define snapshot (snapshot-json (jobject 'text text 'list (list text))))
  (string-set! text 0 #\M)
  (check-equal? (jref snapshot 'text) "mutable")
  (check-true (immutable? (jref snapshot 'text)))
  (check-true (immutable? (car (jref snapshot 'list))))
  (define parsed (string->jvalue "{\"a\":[\"x\",{\"b\":\"y\"}]}"))
  (define normal (snapshot-json parsed))
  (check-true (immutable? (car (jref normal 'a))))
  (check-true (immutable? (jref* normal '(a 1 b))))
  (check-equal? normal parsed)
  (check-eq? (snapshot-json normal) normal))

(test-case "rule 1: an exact rational that is not an integer becomes its flonum"
  (check-equal? (snapshot-json 1/4) 0.25)
  (check-equal? (jref (snapshot-json (jobject 'ratio 1/2 'whole 4)) 'ratio) 0.5)
  (check-equal? (jref (snapshot-json (jobject 'ratio 1/2 'whole 4)) 'whole) 4))

(test-case "rule 1: a shared child is accepted at each occurrence in a wide array"
  (define shared (jobject 'nested (list (jobject 'value 1))))
  (define source (for/list ([i (in-range 4096)]) shared))
  (check-true (lossless-json? source))
  (check-eq? (snapshot-json source) source))

(test-case "rule 1: deeply nested valid JSON is accepted"
  (define value
    (for/fold ([value "leaf"]) ([depth (in-range 5000)]) (list value)))
  (check-true (lossless-json? value))
  (define leaf
    (for/fold ([cursor (snapshot-json value)]) ([depth (in-range 5000)])
      (check-true (pair? cursor))
      (car cursor)))
  (check-equal? leaf "leaf"))

(test-case "rule 1: exotic containers, cycles and invalid children are rejected"
  (define cyclic (make-hasheq))
  (hash-set! cyclic 'self cyclic)
  (define deep-cycle (make-hasheq))
  (hash-set! deep-cycle 'inner (list (jobject 'back deep-cycle)))
  ;; The failure message names the index: printing a cyclic value may not terminate.
  (for ([index (in-naturals)]
        [value (list (exotic 1)
                     (vector 1)
                     (box 1)
                     (cons 1 2)
                     (mcons 1 '())
                     (hash 1 "numeric key")
                     (hash 'a 1 "a" 2)
                     cyclic
                     deep-cycle
                     (list (void))
                     (hash 'value (void))
                     (list 1 (list -0.0))
                     (jobject 'value +nan.0)
                     (jobject 'value (jobject 'inner 'symbol))
                     (list (vector)))])
    (check-false (snapshot-json value) (format "value ~a" index))
    (check-false (lossless-json? value) (format "value ~a" index))))

(test-case "rule 1: an invalid member does not hide behind a valid prefix"
  (check-false (snapshot-json (list 1 2 3 (hash 'ok #t 'bad (vector)))))
  (check-false (lossless-json? (jobject 'first "ok" 'last -0.0))))

(test-case "rule 1: a key that looks like a prototype name is an ordinary key"
  (define snapshot (snapshot-json (hash "__proto__" (jobject 'safe #t))))
  (check-true (jhas? snapshot '__proto__))
  (check-equal? (jref snapshot '__proto__) (jobject 'safe #t)))

(test-case "rule 1: a lossless value is a jvalue"
  (for ([value (list 'null #t "x" 1 1.5 1/3 '() (list 1 "a")
                     (jobject 'a (list 1)) (hash 'a 1))])
    (check-true (lossless-json? value))
    (check-true (jvalue? value))))
