#lang racket/base
;; Tests for section 3 of docs/racket/contracts/cordis-data.md: `deep-equal?`, which follows
;; cosmokit's `deepEqual` in its loose and strict modes.
;; source: vendor/cosmokit/src/types.ts (deepEqual)

(require rackunit
         cordis-data)

(define (loose? a b)
  (and (deep-equal? a b) (deep-equal? b a)))

(define (strict? a b)
  (and (deep-equal? a b #:strict? #t) (deep-equal? b a #:strict? #t)))

;; Unequal in both modes and both argument orders.
(define (never? a b)
  (not (or (deep-equal? a b)
           (deep-equal? b a)
           (deep-equal? a b #:strict? #t)
           (deep-equal? b a #:strict? #t))))

(test-case "scalars"
  (for ([value (in-list (list 0 1 -1.5 "" "text" #t #f 'null))])
    (check-true (loose? value value))
    (check-true (strict? value value)))
  (check-true (never? 1 2))
  (check-true (never? "a" "b"))
  (check-true (never? #t #f))
  (check-true (never? 0 #f))
  (check-true (never? "" #f))
  (check-true (never? 0 ""))
  (check-true (never? 1 "1"))
  (check-true (never? 'null #f))
  (check-true (never? 'null 0))
  (check-true (never? 'null ""))
  (check-true (strict? (string #\a #\b) "ab")))

(test-case "numbers compare with ="
  (check-true (strict? 1 1.0))
  (check-true (strict? 0.0 -0.0))
  (check-true (strict? 0 -0.0))
  (check-true (strict? 1/2 0.5))
  (check-true (strict? (list 1 2.0) (list 1.0 2)))
  (check-true (strict? (jobject 'n 3) (jobject 'n 3.0)))
  (check-true (never? 1 1.0000000000000002))
  (check-true (never? +nan.0 +nan.0))
  (check-true (never? (list +nan.0) (list +nan.0)))
  (check-true (strict? +inf.0 +inf.0)))

(test-case "objects compare as maps, whatever the key order"
  (define one (jobject 'a 1 'b (jobject 'x (list 1 2) 'y "s") 'c 'null))
  (define two (jobject 'c 'null 'b (jobject 'y "s" 'x (list 1 2)) 'a 1))
  (check-true (loose? one two))
  (check-true (strict? one two))
  (check-true (never? one (jset two 'a 2)))
  (check-true (never? one (jset two 'd 4)))
  (check-true (never? one (jset* two '(b x) (list 2 1))))
  (check-true (never? (jobject 'a 1) (jobject 'b 1)))
  (check-true (strict? empty-jobject (jobject)))
  (check-true (never? empty-jobject '()))
  (check-true (never? empty-jobject 'null))
  (check-true (never? (jobject 'a 1) (list 1)))
  (check-true (never? (jobject 'length 0) '())))

(test-case "arrays compare element by element"
  (check-true (strict? '() '()))
  (check-true (strict? (list 1 "a" (list #t 'null)) (list 1 "a" (list #t 'null))))
  (check-true (never? (list 1 2) (list 2 1)))
  (check-true (never? (list 1 2) (list 1 2 3)))
  (check-true (never? (list 1 2 3) (list 1 2)))
  (check-true (never? '() (list 'null)))
  (check-true (never? (list (list)) (list (jobject))))
  (check-true (never? (list 1) 1))
  (check-true (never? '() #f))
  (check-true (never? '() 'null)))

(test-case "loosely, null equals undefined and a null member equals an absent one"
  (check-true (loose? 'null (void)))
  (check-true (loose? (void) (void)))
  (check-true (loose? (jobject 'a 1 'b 'null) (jobject 'a 1)))
  (check-true (loose? (jobject 'a 'null) empty-jobject))
  (check-true (loose? (jobject 'a (jobject 'b 'null 'c 2)) (jobject 'a (jobject 'c 2))))
  (check-true (loose? (list (jobject 'a 'null)) (list (jobject))))
  (check-true (loose? (jobject 'a 'null) (jobject 'b 'null)))
  ;; Only null stands in for an absent key.
  (check-false (deep-equal? (jobject 'a #f) empty-jobject))
  (check-false (deep-equal? (jobject 'a 0) empty-jobject))
  (check-false (deep-equal? (jobject 'a "") empty-jobject))
  (check-false (deep-equal? (jobject 'a '()) empty-jobject))
  (check-false (deep-equal? (jobject 'a (jobject)) empty-jobject))
  (check-false (deep-equal? 'null #f))
  (check-false (deep-equal? (void) #f))
  (check-false (deep-equal? 'null empty-jobject))
  ;; Array length still counts.
  (check-false (deep-equal? (list 1 'null) (list 1))))

(test-case "strictly, null and undefined differ"
  (check-false (deep-equal? 'null (void) #:strict? #t))
  (check-false (deep-equal? (void) 'null #:strict? #t))
  (check-true (strict? (void) (void)))
  (check-true (strict? 'null 'null))
  (check-false (deep-equal? (jobject 'a 1 'b 'null) (jobject 'a 1) #:strict? #t))
  (check-false (deep-equal? (jobject 'a 1) (jobject 'a 1 'b 'null) #:strict? #t))
  (check-false (deep-equal? (jobject 'a (jobject 'b 'null)) (jobject 'a (jobject)) #:strict? #t))
  (check-false (deep-equal? (list (jobject 'a 'null)) (list (jobject)) #:strict? #t))
  (check-true (strict? (jobject 'a 'null) (jobject 'a 'null)))
  ;; Any true value selects strict mode.
  (check-false (deep-equal? 'null (void) #:strict? 'yes)))

(test-case "a hash stands for an object"
  (check-true (strict? (hash 'a 1 'b (list (hash "c" 2))) (jobject 'b (list (jobject 'c 2)) 'a 1)))
  (check-true (strict? (hash "a" 1) (hasheq 'a 1.0)))
  (check-true (loose? (hash 'a 'null) (jobject)))
  (check-true (never? (hash 'a 1) (jobject 'a 2))))

(test-case "values outside the model compare with equal?"
  (check-true (strict? #"bytes" (bytes-copy #"bytes")))
  (check-true (strict? car car))
  (check-true (never? car cdr))
  (check-true (never? 'a 'b))
  (check-true (strict? (jobject 'f car) (jobject 'f car)))
  (check-true (never? (jobject 'f car) (jobject 'f cdr))))
