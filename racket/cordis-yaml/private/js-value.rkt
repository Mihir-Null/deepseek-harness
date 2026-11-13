#lang racket/base
;; Provides JavaScript's value semantics over the evaluator's value model: the conversions
;; (ToNumber, ToString, ToPrimitive, ToBoolean), the equality and relational comparisons, the
;; arithmetic operators, `typeof`, UTF-16 views of strings, and JavaScript's own-key order.
;;
;; Value model: (void) is undefined, 'null is null, booleans, reals, strings, lists (arrays),
;; jobjects and hashes (plain objects), procedures (functions) and `gen:js-object` values (host
;; objects). A number these functions return is canonical: an exact integer when it is integral,
;; not -0 and at most 2^53 in magnitude, else a flonum.

(require racket/flonum
         racket/list
         racket/string
         cordis-data
         "js-error.rkt"
         "js-object.rkt")

(provide js-undefined?
         js-nullish?
         js-primitive?
         js-plain-object?
         js-truthy?
         js-typeof
         normalize-number
         js-fl
         decimal->number
         js-negate
         js->number
         js->string
         js->primitive
         js->property-key
         js-strict-equal?
         js-loose-equal?
         js-same-value-zero?
         js-compare
         js-add
         js-arithmetic
         ->integer-or-infinity
         array-index
         string->units
         units->string
         js-whitespace?
         js-trim
         own-entries
         js-key-order
         deep-js-key-order
         entries->jobject
         describe-value)

;; ---------------------------------------------------------------------------------------------
;; Kinds of value

(define (js-undefined? v) (void? v))
(define (js-nullish? v) (or (void? v) (eq? v 'null)))
(define (js-primitive? v)
  (or (string? v) (real? v) (boolean? v) (void? v) (eq? v 'null)))
(define (js-plain-object? v) (or (jobject? v) (hash? v)))

;; js-truthy? : any/c -> boolean?   JavaScript's Boolean(v).
(define (js-truthy? v)
  (cond [(boolean? v) v]
        [(void? v) #f]
        [(eq? v 'null) #f]
        [(real? v) (not (or (zero? v) (and (flonum? v) (not (fl= v v)))))]
        [(string? v) (not (string=? v ""))]
        [else #t]))

;; js-typeof : any/c -> string?
(define (js-typeof v)
  (cond [(void? v) "undefined"]
        [(boolean? v) "boolean"]
        [(real? v) "number"]
        [(string? v) "string"]
        [(procedure? v) "function"]
        [else "object"]))

;; ---------------------------------------------------------------------------------------------
;; Numbers

(define max-safe-magnitude 9007199254740992)

;; normalize-number : real? -> real?   The canonical form of a JavaScript number.
(define (normalize-number x)
  (cond
    [(flonum? x)
     (if (and (fl= x (flfloor x))
              (fl<= (flabs x) 9007199254740992.0)
              (not (eqv? x -0.0)))
         (fl->exact-integer x)
         x)]
    [(exact-integer? x)
     (if (<= (abs x) max-safe-magnitude) x (normalize-number (real->double-flonum x)))]
    [else (normalize-number (real->double-flonum x))]))

;; js-fl : real? -> flonum?   The double a JavaScript number stands for.
(define (js-fl x)
  (if (flonum? x) x (real->double-flonum x)))

;; decimal->number : string? string? exact-integer? -> real?
;; The number written with integer digits `whole`, fraction digits `fraction` and decimal
;; exponent `exponent`, rounded to the nearest double.
(define (decimal->number whole fraction exponent)
  (define digits (string->number (string-append "0" whole fraction) 10))
  (define scale (- exponent (string-length fraction)))
  ;; The value lies in [10^(magnitude-1), 10^magnitude).
  (define magnitude (+ scale (string-length (number->string digits))))
  (cond
    [(zero? digits) 0]
    ;; Beyond these bounds the result is infinite or zero whatever the digits are.
    [(> magnitude 400) +inf.0]
    [(< magnitude -400) 0]
    [else (normalize-number (* digits (expt 10 scale)))]))

;; js-negate : real? -> real?   Unary minus; the negation of 0 is -0.
(define (js-negate x)
  (normalize-number (fl* -1.0 (js-fl x))))

(define (js-whitespace? c)
  (or (memv c '(#\tab #\newline #\vtab #\page #\return #\space #\uA0 #\uFEFF #\u2028 #\u2029))
      (eq? (char-general-category c) 'zs)))

;; js-trim : string? boolean? boolean? -> string?   Removes JavaScript white space.
(define (js-trim s start? end?)
  (define len (string-length s))
  (define from
    (if start?
        (let loop ([i 0])
          (if (and (< i len) (js-whitespace? (string-ref s i))) (loop (add1 i)) i))
        0))
  (define to
    (if end?
        (let loop ([i len])
          (if (and (> i from) (js-whitespace? (string-ref s (sub1 i)))) (loop (sub1 i)) i))
        len))
  (substring s from to))

(define decimal-pattern
  #px"^([-+]?)(?:([0-9]+)(?:\\.([0-9]*))?|\\.([0-9]+))(?:[eE]([-+]?[0-9]+))?$")

;; ECMAScript's StringToNumber.
(define (string->js-number s)
  (define text (js-trim s #t #t))
  (cond
    [(string=? text "") 0]
    [(regexp-match #px"^([-+]?)Infinity$" text)
     => (lambda (m) (if (string=? (cadr m) "-") -inf.0 +inf.0))]
    [(regexp-match #px"^0[xX]([0-9a-fA-F]+)$" text)
     => (lambda (m) (normalize-number (string->number (cadr m) 16)))]
    [(regexp-match #px"^0[oO]([0-7]+)$" text)
     => (lambda (m) (normalize-number (string->number (cadr m) 8)))]
    [(regexp-match #px"^0[bB]([01]+)$" text)
     => (lambda (m) (normalize-number (string->number (cadr m) 2)))]
    [(regexp-match decimal-pattern text)
     => (lambda (m)
          (define magnitude
            (decimal->number (or (list-ref m 2) "")
                             (or (list-ref m 3) (list-ref m 4) "")
                             (if (list-ref m 5) (string->number (list-ref m 5) 10) 0)))
          (if (string=? (list-ref m 1) "-") (js-negate magnitude) magnitude))]
    [else +nan.0]))

;; js->number : any/c -> real?   ECMAScript's ToNumber.
(define (js->number v)
  (cond [(real? v) (normalize-number v)]
        [(string? v) (string->js-number v)]
        [(eq? v #t) 1]
        [(eq? v #f) 0]
        [(eq? v 'null) 0]
        [(void? v) +nan.0]
        [else (js->number (js->primitive v 'number))]))

;; ->integer-or-infinity : any/c -> (or/c exact-integer? +inf.0 -inf.0)
;; ECMAScript's ToIntegerOrInfinity.
(define (->integer-or-infinity v)
  (define x (js-fl (js->number v)))
  (cond [(not (fl= x x)) 0]
        [(or (fl= x +inf.0) (fl= x -inf.0)) x]
        [else (fl->exact-integer (fltruncate x))]))

;; ---------------------------------------------------------------------------------------------
;; Strings and primitives

;; js->string : any/c -> string?   ECMAScript's ToString.
(define (js->string v)
  (cond [(string? v) v]
        [(real? v) (js-number->string v)]
        [(eq? v #t) "true"]
        [(eq? v #f) "false"]
        [(eq? v 'null) "null"]
        [(void? v) "undefined"]
        [else (js->string (js->primitive v 'string))]))

(define (array->string v)
  (string-join (for/list ([item (in-list v)])
                 (if (js-nullish? item) "" (js->string item)))
               ","))

;; js->primitive : any/c (or/c 'default 'number 'string) -> any/c   ECMAScript's ToPrimitive.
(define (js->primitive v hint)
  (cond
    [(js-primitive? v) v]
    [(list? v) (array->string v)]
    [(js-plain-object? v) (plain-object->primitive v hint)]
    [(js-object? v)
     (cond [(procedure? (js-get-property v "toString"))
            (define text (js-call-method v "toString" '()))
            (unless (js-primitive? text)
              (raise-js-error "TypeError" "Cannot convert object to primitive value"))
            text]
           [else "[object Object]"])]
    [(procedure? v) (raise-js-unsupported "conversion of a function to a primitive value")]
    [else (raise-js-unsupported (format "a value outside the JavaScript model: ~e" v))]))

;; An own `valueOf` or `toString` member that is a function is called, in the order the hint
;; gives; otherwise Object.prototype's apply: valueOf yields the object, toString the tag.
(define (plain-object->primitive obj hint)
  (let try ([names (if (eq? hint 'string) '(toString valueOf) '(valueOf toString))])
    (cond
      [(null? names) (raise-js-error "TypeError" "Cannot convert object to primitive value")]
      [else
       (define member (jref obj (car names) (void)))
       (cond
         [(procedure? member)
          (define result (apply-js-function member '()))
          (if (js-primitive? result) result (try (cdr names)))]
         [(not (void? member)) (try (cdr names))]
         [(eq? (car names) 'toString) "[object Object]"]
         [else (try (cdr names))])])))

;; js->property-key : any/c -> string?   ECMAScript's ToPropertyKey.
(define (js->property-key v)
  (js->string (js->primitive v 'string)))

;; array-index : any/c -> (or/c exact-nonnegative-integer? #f)
;; The array index a property key denotes: a non-negative integer, or its canonical text.
(define (array-index key)
  (cond [(exact-nonnegative-integer? key) key]
        [(and (flonum? key) (fl= key (flfloor key)) (fl>= key 0.0) (fl< key 4294967295.0))
         (fl->exact-integer key)]
        [(and (string? key) (regexp-match? #px"^(?:0|[1-9][0-9]*)$" key))
         (define n (string->number key 10))
         (and (< n 4294967295) n)]
        [else #f]))

;; string->units : string? -> (vectorof fixnum)   The UTF-16 code units of `s`.
(define (string->units s)
  (define units (make-vector (utf16-length s) 0))
  (for/fold ([i 0]) ([c (in-string s)])
    (define n (char->integer c))
    (cond [(< n #x10000)
           (vector-set! units i n)
           (add1 i)]
          [else
           (define offset (- n #x10000))
           (vector-set! units i (+ #xD800 (arithmetic-shift offset -10)))
           (vector-set! units (add1 i) (+ #xDC00 (bitwise-and offset #x3FF)))
           (+ i 2)]))
  units)

;; units->string : vector? [start end] -> string?
;; The string of the UTF-16 code units in [start, end). Half of a surrogate pair has no Racket
;; character, so it raises unsupported.
(define (units->string units [start 0] [end (vector-length units)])
  (define out (open-output-string))
  (let loop ([i start])
    (when (< i end)
      (define n (vector-ref units i))
      (cond
        [(and (<= #xD800 n #xDBFF) (< (add1 i) end)
              (<= #xDC00 (vector-ref units (add1 i)) #xDFFF))
         (write-char (integer->char (+ #x10000
                                       (arithmetic-shift (- n #xD800) 10)
                                       (- (vector-ref units (add1 i)) #xDC00)))
                     out)
         (loop (+ i 2))]
        [(<= #xD800 n #xDFFF)
         (raise-js-unsupported "a string operation that splits a surrogate pair")]
        [else
         (write-char (integer->char n) out)
         (loop (add1 i))])))
  (get-output-string out))

;; ---------------------------------------------------------------------------------------------
;; Equality and order

(define (object-value? v)
  (not (js-primitive? v)))

;; Identity of two object values. Racket shares one empty list and may share one empty object,
;; where JavaScript creates a new object for every literal, so `eq?` cannot decide for them.
(define (identical-objects? a b)
  (cond [(not (eq? a b)) #f]
        [(or (null? a) (and (jobject? a) (zero? (jcount a))))
         (raise-js-unsupported "identity comparison of empty arrays or objects")]
        [else #t]))

;; js-strict-equal? : any/c any/c -> boolean?   The === operator.
(define (js-strict-equal? a b)
  (cond [(and (real? a) (real? b)) (fl= (js-fl a) (js-fl b))]
        [(and (string? a) (string? b)) (string=? a b)]
        [(and (boolean? a) (boolean? b)) (eq? a b)]
        [(and (void? a) (void? b)) #t]
        [(and (eq? a 'null) (eq? b 'null)) #t]
        [(and (object-value? a) (object-value? b)) (identical-objects? a b)]
        [else #f]))

;; js-same-value-zero? : any/c any/c -> boolean?   As ===, except that NaN equals NaN.
(define (js-same-value-zero? a b)
  (if (and (real? a) (real? b))
      (let ([x (js-fl a)] [y (js-fl b)])
        (or (fl= x y) (and (not (fl= x x)) (not (fl= y y)))))
      (js-strict-equal? a b)))

;; js-loose-equal? : any/c any/c -> boolean?   The == operator.
(define (js-loose-equal? a b)
  (cond
    [(and (js-nullish? a) (js-nullish? b)) #t]
    [(or (js-nullish? a) (js-nullish? b)) #f]
    [(or (and (real? a) (real? b)) (and (string? a) (string? b))
         (and (boolean? a) (boolean? b)) (and (object-value? a) (object-value? b)))
     (js-strict-equal? a b)]
    [(and (real? a) (string? b)) (js-strict-equal? a (js->number b))]
    [(and (string? a) (real? b)) (js-strict-equal? (js->number a) b)]
    [(boolean? a) (js-loose-equal? (if a 1 0) b)]
    [(boolean? b) (js-loose-equal? a (if b 1 0))]
    [(object-value? b) (js-loose-equal? a (js->primitive b 'default))]
    [(object-value? a) (js-loose-equal? (js->primitive a 'default) b)]
    [else #f]))

;; js-compare : (or/c '< '> '<= '>=) any/c any/c -> boolean?   The relational operators.
(define (js-compare op a b)
  (define pa (js->primitive a 'number))
  (define pb (js->primitive b 'number))
  (cond
    [(and (string? pa) (string? pb))
     (case op
       [(<) (js-string<? pa pb)]
       [(>) (js-string<? pb pa)]
       [(<=) (not (js-string<? pb pa))]
       [else (not (js-string<? pa pb))])]
    [else
     (define x (js-fl (js->number pa)))
     (define y (js-fl (js->number pb)))
     (case op
       [(<) (fl< x y)]
       [(>) (fl> x y)]
       [(<=) (fl<= x y)]
       [else (fl>= x y)])]))

;; ---------------------------------------------------------------------------------------------
;; Arithmetic

;; js-add : any/c any/c -> (or/c string? real?)   The + operator.
(define (js-add a b)
  (define pa (js->primitive a 'default))
  (define pb (js->primitive b 'default))
  (if (or (string? pa) (string? pb))
      (string-append (js->string pa) (js->string pb))
      (normalize-number (fl+ (js-fl (js->number pa)) (js-fl (js->number pb))))))

;; The remainder with the sign of the dividend, as the % operator computes it.
(define (fl-remainder x y)
  (cond [(or (not (fl= x x)) (not (fl= y y))) +nan.0]
        [(or (fl= x +inf.0) (fl= x -inf.0) (fl= y 0.0)) +nan.0]
        [(or (fl= y +inf.0) (fl= y -inf.0)) x]
        [(fl= x 0.0) x]
        [else
         (define a (inexact->exact x))
         (define b (inexact->exact y))
         (define r (- a (* b (truncate (/ a b)))))
         (if (zero? r)
             (if (fl< x 0.0) -0.0 0.0)
             (real->double-flonum r))]))

;; js-arithmetic : (or/c '- '* '/ '%) any/c any/c -> real?
(define (js-arithmetic op a b)
  (define x (js-fl (js->number a)))
  (define y (js-fl (js->number b)))
  (normalize-number
   (case op
     [(-) (fl- x y)]
     [(*) (fl* x y)]
     [(/) (fl/ x y)]
     [else (fl-remainder x y)])))

;; ---------------------------------------------------------------------------------------------
;; Objects

(define (index-key? name)
  (and (regexp-match? #px"^(?:0|[1-9][0-9]*)$" name)
       (< (string->number name 10) 4294967295)))

;; js-key-order : (listof (cons/c string? any/c)) -> (listof (cons/c string? any/c))
;; JavaScript's own-key order: array indexes ascending, then the other keys as given.
(define (js-key-order entries)
  (define-values (indexes others) (partition (lambda (e) (index-key? (car e))) entries))
  (if (null? indexes)
      entries
      (append (sort indexes < #:key (lambda (e) (string->number (car e) 10))) others)))

;; own-entries : (or/c jobject? hash?) -> (listof (cons/c string? any/c))
;; The members of a plain object in JavaScript's enumeration order.
(define (own-entries obj)
  (js-key-order
   (for/list ([(key value) (in-jobject (if (jobject? obj) obj (jmerge obj)))])
     (cons (symbol->string key) value))))

;; entries->jobject : (listof (cons/c string? any/c)) -> jobject?
;; The object with these members in JavaScript's order. A later duplicate replaces the value
;; and keeps the first position; a member whose value is undefined is left out.
(define (entries->jobject entries)
  (define latest (make-hash))
  (for ([e (in-list entries)]) (hash-set! latest (car e) (cdr e)))
  (define seen (make-hash))
  (define unique
    (for/list ([e (in-list entries)]
               #:unless (hash-ref seen (car e) #f))
      (hash-set! seen (car e) #t)
      (cons (car e) (hash-ref latest (car e)))))
  (make-jobject
   (for/list ([e (in-list (js-key-order unique))]
              #:unless (void? (cdr e)))
     (cons (string->symbol (car e)) (cdr e)))))

;; deep-js-key-order : any/c -> any/c
;; `v` with every plain object inside it in JavaScript's key order and every number canonical.
(define (deep-js-key-order v)
  (cond [(real? v) (normalize-number v)]
        [(list? v) (map deep-js-key-order v)]
        [(js-plain-object? v)
         (entries->jobject
          (for/list ([e (in-list (own-entries v))])
            (cons (car e) (deep-js-key-order (cdr e)))))]
        [else v]))

;; describe-value : any/c -> string?   A short text for error messages.
(define (describe-value v)
  (cond [(string? v) (format "~s" v)]
        [(js-primitive? v) (js->string v)]
        [(list? v) "an array"]
        [(procedure? v) "a function"]
        [else "an object"]))
