#lang racket/base
;; Provides the property protocol of the `!!js` evaluator over its value model (`get-member`,
;; `call-method`, `call-function`, `construct`, `iterate-value`, `spread-entries`), the methods
;; of strings, arrays, numbers and booleans, and `js-standard-globals`.
;;
;; A property or method that JavaScript defines and this module does not implement raises
;; exn:fail:js-expr:unsupported; a name JavaScript does not define reads as undefined. String
;; positions and lengths are UTF-16 code units.

(require racket/flonum
         racket/list
         racket/string
         cordis-data
         "js-error.rkt"
         "js-object.rkt"
         "js-url.rkt"
         "js-value.rkt"
         "uri.rkt")

(provide get-member
         call-method
         call-function
         construct
         iterate-value
         spread-entries
         namespace-object
         js-standard-globals
         unimplemented-global?)

(define (arg arguments i)
  (if (> (length arguments) i) (list-ref arguments i) (void)))

(define (clamp x low high)
  (cond [(< x low) low] [(> x high) high] [else x]))

;; The index a relative position (negative counts from the end) denotes in a sequence of
;; `len` items.
(define (relative-index v len)
  (define relative (->integer-or-infinity v))
  (if (< relative 0)
      (clamp (+ len relative) 0 len)
      (clamp relative 0 len)))

;; V8's longest string; a longer result is a RangeError there.
(define max-string-length 536870888)

(define (check-string-length! n)
  (when (> n max-string-length)
    (raise-js-error "RangeError" "Invalid string length")))

(define (require-function f)
  (unless (procedure? f)
    (raise-js-error "TypeError" (format "~a is not a function" (describe-value f))))
  f)

;; ---------------------------------------------------------------------------------------------
;; Names JavaScript defines on the prototypes; reading one that is not implemented here must
;; fail loudly instead of yielding undefined.

(define object-prototype-names
  '("constructor" "hasOwnProperty" "isPrototypeOf" "propertyIsEnumerable" "toLocaleString"
    "toString" "valueOf" "__proto__" "__defineGetter__" "__defineSetter__" "__lookupGetter__"
    "__lookupSetter__"))

(define string-prototype-names
  '("anchor" "at" "big" "blink" "bold" "charAt" "charCodeAt" "codePointAt" "concat" "endsWith"
    "fixed" "fontcolor" "fontsize" "includes" "indexOf" "isWellFormed" "italics" "lastIndexOf"
    "link" "localeCompare" "match" "matchAll" "normalize" "padEnd" "padStart" "repeat"
    "replace" "replaceAll" "search" "slice" "small" "split" "startsWith" "strike" "sub"
    "substr" "substring" "sup" "toLocaleLowerCase" "toLocaleUpperCase" "toLowerCase"
    "toUpperCase" "toWellFormed" "trim" "trimEnd" "trimLeft" "trimRight" "trimStart"))

(define array-prototype-names
  '("at" "concat" "copyWithin" "entries" "every" "fill" "filter" "find" "findIndex" "findLast"
    "findLastIndex" "flat" "flatMap" "forEach" "includes" "indexOf" "join" "keys" "lastIndexOf"
    "map" "pop" "push" "reduce" "reduceRight" "reverse" "shift" "slice" "some" "sort" "splice"
    "toReversed" "toSorted" "toSpliced" "unshift" "values" "with"))

(define number-prototype-names '("toExponential" "toFixed" "toPrecision"))

(define function-prototype-names
  '("apply" "bind" "call" "name" "length" "prototype" "arguments" "caller"))

;; The value of a property that the value itself does not hold.
(define (prototype-miss owner names name)
  (if (or (member name names) (member name object-prototype-names))
      (raise-js-unsupported (format "~a.prototype.~a" owner name))
      (void)))

;; What reading a builtin method without calling it yields: a function that cannot be called,
;; because a call would have lost the object it was read from.
(struct detached-method (owner name)
  #:property prop:procedure
  (lambda (self . arguments)
    (raise-js-unsupported
     (format "call of ~a.prototype.~a detached from its object"
             (detached-method-owner self) (detached-method-name self)))))

;; ---------------------------------------------------------------------------------------------
;; Strings

;; The first index at or after `from` where `needle` occurs in `hay`, both unit vectors.
(define (units-index hay needle from)
  (define hay-len (vector-length hay))
  (define needle-len (vector-length needle))
  (let loop ([i from])
    (cond [(> (+ i needle-len) hay-len) #f]
          [(for/and ([j (in-range needle-len)])
             (= (vector-ref hay (+ i j)) (vector-ref needle j)))
           i]
          [else (loop (add1 i))])))

(define (units-match-at? hay needle at)
  (and (>= at 0)
       (<= (+ at (vector-length needle)) (vector-length hay))
       (for/and ([j (in-range (vector-length needle))])
         (= (vector-ref hay (+ at j)) (vector-ref needle j)))))

;; ECMAScript's GetSubstitution for a string pattern, which has no captures.
(define (expand-replacement template matched position units)
  (define len (string-length template))
  (define out (open-output-string))
  (let loop ([i 0])
    (when (< i len)
      (define c (string-ref template i))
      (define next (and (< (add1 i) len) (string-ref template (add1 i))))
      (cond
        [(and (char=? c #\$) next (char=? next #\$))
         (write-char #\$ out)
         (loop (+ i 2))]
        [(and (char=? c #\$) next (char=? next #\&))
         (write-string matched out)
         (loop (+ i 2))]
        [(and (char=? c #\$) next (char=? next #\`))
         (write-string (units->string units 0 position) out)
         (loop (+ i 2))]
        [(and (char=? c #\$) next (char=? next #\'))
         (write-string (units->string units (+ position (utf16-length matched))) out)
         (loop (+ i 2))]
        [else
         (write-char c out)
         (loop (add1 i))])))
  (get-output-string out))

;; The text that replaces the match at `position`.
(define (replacement-text replacement s matched position units)
  (if (procedure? replacement)
      (js->string (apply-js-function replacement (list matched position s)))
      (expand-replacement replacement matched position units)))

(define (string-replace-method s arguments all?)
  (define search (js->string (arg arguments 0)))
  (define replacement
    (let ([r (arg arguments 1)]) (if (procedure? r) r (js->string r))))
  (define units (string->units s))
  (define needle (string->units search))
  (define len (vector-length units))
  (define needle-len (vector-length needle))
  (define positions
    (let loop ([from 0] [found '()])
      (define at (and (<= from len) (units-index units needle from)))
      (cond [(not at) (reverse found)]
            [all? (loop (+ at (max 1 needle-len)) (cons at found))]
            [else (list at)])))
  (cond
    [(null? positions) s]
    [else
     (define out (open-output-string))
     (define end-of-last
       (for/fold ([end-of-last 0]) ([at (in-list positions)])
         (write-string (units->string units end-of-last at) out)
         (write-string (replacement-text replacement s search at units) out)
         (+ at needle-len)))
     (when (< end-of-last len)
       (write-string (units->string units end-of-last len) out))
     (get-output-string out)]))

(define (string-split-method s arguments)
  (define separator (arg arguments 0))
  (define limit
    (let ([l (arg arguments 1)])
      (if (void? l)
          4294967295
          (let ([n (->integer-or-infinity l)])
            (if (exact-integer? n) (modulo n 4294967296) 0)))))
  (define units (string->units s))
  (define len (vector-length units))
  (cond
    [(void? separator) (if (zero? limit) '() (list s))]
    [else
     (define needle (string->units (js->string separator)))
     (define needle-len (vector-length needle))
     (cond
       [(zero? limit) '()]
       [(zero? needle-len)
        (for/list ([i (in-range (min len limit))])
          (units->string units i (add1 i)))]
       [(zero? len) (list s)]
       [else
        (let loop ([start 0] [pieces '()])
          (define at (units-index units needle start))
          (cond
            [(not at) (reverse (cons (units->string units start len) pieces))]
            [else
             (define pieces* (cons (units->string units start at) pieces))
             (if (= (length pieces*) limit)
                 (reverse pieces*)
                 (loop (+ at needle-len) pieces*))]))])]))

(define (string-pad-method s arguments at-start?)
  (define units (string->units s))
  (define len (vector-length units))
  (define target (clamp (->integer-or-infinity (arg arguments 0)) 0 9007199254740991))
  (define filler (let ([f (arg arguments 1)]) (if (void? f) " " (js->string f))))
  (cond
    [(or (<= target len) (string=? filler "")) s]
    [else
     (check-string-length! target)
     (define fill-units (string->units filler))
     (define fill-len (- target len))
     (define padding
       (units->string
        (for/vector #:length fill-len ([i (in-range fill-len)])
          (vector-ref fill-units (modulo i (vector-length fill-units))))))
     (if at-start? (string-append padding s) (string-append s padding))]))

;; string-method : the implementation of String.prototype.NAME as (-> string list any), or #f.
(define (string-method name)
  (case name
    [("at")
     (lambda (s arguments)
       (define units (string->units s))
       (define len (vector-length units))
       (define relative (->integer-or-infinity (arg arguments 0)))
       (define k (if (>= relative 0) relative (+ len relative)))
       (if (or (< k 0) (>= k len)) (void) (units->string units k (add1 k))))]
    [("charAt")
     (lambda (s arguments)
       (define units (string->units s))
       (define k (->integer-or-infinity (arg arguments 0)))
       (if (or (< k 0) (>= k (vector-length units))) "" (units->string units k (add1 k))))]
    [("concat")
     (lambda (s arguments) (apply string-append s (map js->string arguments)))]
    [("endsWith")
     (lambda (s arguments)
       (define units (string->units s))
       (define needle (string->units (js->string (arg arguments 0))))
       (define end
         (let ([e (arg arguments 1)])
           (if (void? e)
               (vector-length units)
               (clamp (->integer-or-infinity e) 0 (vector-length units)))))
       (units-match-at? units needle (- end (vector-length needle))))]
    [("includes")
     (lambda (s arguments)
       (define units (string->units s))
       (define from (clamp (->integer-or-infinity (arg arguments 1)) 0 (vector-length units)))
       (and (units-index units (string->units (js->string (arg arguments 0))) from) #t))]
    [("indexOf")
     (lambda (s arguments)
       (define units (string->units s))
       (define from (clamp (->integer-or-infinity (arg arguments 1)) 0 (vector-length units)))
       (or (units-index units (string->units (js->string (arg arguments 0))) from) -1))]
    [("padEnd") (lambda (s arguments) (string-pad-method s arguments #f))]
    [("padStart") (lambda (s arguments) (string-pad-method s arguments #t))]
    [("repeat")
     (lambda (s arguments)
       (define count (->integer-or-infinity (arg arguments 0)))
       (unless (and (exact-integer? count) (>= count 0))
         (raise-js-error "RangeError"
                         (format "Invalid count value: ~a" (js->string (arg arguments 0)))))
       (check-string-length! (* count (utf16-length s)))
       (apply string-append (for/list ([_ (in-range count)]) s)))]
    [("replace") (lambda (s arguments) (string-replace-method s arguments #f))]
    [("replaceAll") (lambda (s arguments) (string-replace-method s arguments #t))]
    [("slice")
     (lambda (s arguments)
       (define units (string->units s))
       (define len (vector-length units))
       (define from (relative-index (arg arguments 0) len))
       (define to (let ([e (arg arguments 1)]) (if (void? e) len (relative-index e len))))
       (if (>= from to) "" (units->string units from to)))]
    [("split") string-split-method]
    [("startsWith")
     (lambda (s arguments)
       (define units (string->units s))
       (define at (clamp (->integer-or-infinity (arg arguments 1)) 0 (vector-length units)))
       (units-match-at? units (string->units (js->string (arg arguments 0))) at))]
    [("substring")
     (lambda (s arguments)
       (define units (string->units s))
       (define len (vector-length units))
       (define start (clamp (->integer-or-infinity (arg arguments 0)) 0 len))
       (define end
         (let ([e (arg arguments 1)])
           (if (void? e) len (clamp (->integer-or-infinity e) 0 len))))
       (units->string units (min start end) (max start end)))]
    [("toLowerCase") (lambda (s arguments) (string-downcase s))]
    [("toUpperCase") (lambda (s arguments) (string-upcase s))]
    [("toString" "valueOf") (lambda (s arguments) s)]
    [("trim") (lambda (s arguments) (js-trim s #t #t))]
    [("trimStart") (lambda (s arguments) (js-trim s #t #f))]
    [("trimEnd") (lambda (s arguments) (js-trim s #f #t))]
    [else #f]))

;; ---------------------------------------------------------------------------------------------
;; Arrays

(define (array-callback arguments)
  (require-function (arg arguments 0)))

;; array-method : the implementation of Array.prototype.NAME as (-> list list any), or #f.
(define (array-method name)
  (case name
    [("at")
     (lambda (items arguments)
       (define len (length items))
       (define relative (->integer-or-infinity (arg arguments 0)))
       (define k (if (>= relative 0) relative (+ len relative)))
       (if (or (< k 0) (>= k len)) (void) (list-ref items k)))]
    [("concat")
     (lambda (items arguments)
       (apply append items
              (for/list ([a (in-list arguments)]) (if (list? a) a (list a)))))]
    [("every")
     (lambda (items arguments)
       (define f (array-callback arguments))
       (for/and ([item (in-list items)] [i (in-naturals)])
         (js-truthy? (apply-js-function f (list item i items)))))]
    [("some")
     (lambda (items arguments)
       (define f (array-callback arguments))
       (for/or ([item (in-list items)] [i (in-naturals)])
         (js-truthy? (apply-js-function f (list item i items)))))]
    [("filter")
     (lambda (items arguments)
       (define f (array-callback arguments))
       (for/list ([item (in-list items)] [i (in-naturals)]
                  #:when (js-truthy? (apply-js-function f (list item i items))))
         item))]
    [("find")
     (lambda (items arguments)
       (define f (array-callback arguments))
       (or (for/first ([item (in-list items)] [i (in-naturals)]
                       #:when (js-truthy? (apply-js-function f (list item i items))))
             (found item))
           (found (void))))]
    [("map")
     (lambda (items arguments)
       (define f (array-callback arguments))
       (for/list ([item (in-list items)] [i (in-naturals)])
         (apply-js-function f (list item i items))))]
    [("includes")
     (lambda (items arguments)
       (define from (relative-index (arg arguments 1) (length items)))
       (for/or ([item (in-list (list-tail items from))])
         (js-same-value-zero? item (arg arguments 0))))]
    [("indexOf")
     (lambda (items arguments)
       (define from (relative-index (arg arguments 1) (length items)))
       (or (for/first ([item (in-list (list-tail items from))] [i (in-naturals from)]
                       #:when (js-strict-equal? item (arg arguments 0)))
             i)
           -1))]
    [("join")
     (lambda (items arguments)
       (define separator (let ([s (arg arguments 0)]) (if (void? s) "," (js->string s))))
       (string-join (for/list ([item (in-list items)])
                      (if (js-nullish? item) "" (js->string item)))
                    separator))]
    [("slice")
     (lambda (items arguments)
       (define len (length items))
       (define from (relative-index (arg arguments 0) len))
       (define to (let ([e (arg arguments 1)]) (if (void? e) len (relative-index e len))))
       (if (>= from to) '() (take (list-tail items from) (- to from))))]
    [("toString") (lambda (items arguments) (js->string items))]
    [else #f]))

;; `find` wraps its result so that a found #f is not taken for a miss by `for/first`.
(struct found (value))

(define (method-result v)
  (if (found? v) (found-value v) v))

;; ---------------------------------------------------------------------------------------------
;; Numbers and booleans

(define (number->fixed x digits)
  (define value (js-fl x))
  (cond
    [(or (not (fl= value value)) (fl>= (flabs value) 1e21)) (js->string x)]
    [(fl< value 0.0) (string-append "-" (number->fixed (fl* -1.0 value) digits))]
    [else
     (define scaled (* (inexact->exact value) (expt 10 digits)))
     ;; The nearest integer; a tie goes to the larger one.
     (define n (floor (+ scaled 1/2)))
     (define text (number->string n))
     (cond
       [(zero? digits) text]
       [else
        (define padded
          (if (<= (string-length text) digits)
              (string-append (make-string (- (add1 digits) (string-length text)) #\0) text)
              text))
        (define split (- (string-length padded) digits))
        (string-append (substring padded 0 split) "." (substring padded split))])]))

(define (number-method name)
  (case name
    [("toFixed")
     (lambda (x arguments)
       (define digits (->integer-or-infinity (arg arguments 0)))
       (unless (and (exact-integer? digits) (<= 0 digits 100))
         (raise-js-error "RangeError" "toFixed() digits argument must be between 0 and 100"))
       (number->fixed x digits))]
    [("toString")
     (lambda (x arguments)
       (define radix
         (let ([r (arg arguments 0)]) (if (void? r) 10 (->integer-or-infinity r))))
       (unless (and (exact-integer? radix) (<= 2 radix 36))
         (raise-js-error "RangeError" "toString() radix must be between 2 and 36"))
       (define value (normalize-number x))
       (cond [(= radix 10) (js->string value)]
             [(exact-integer? value) (number->string value radix)]
             [(and (flonum? value) (or (not (fl= value value)) (fl= (flabs value) +inf.0)))
              (js->string value)]
             [(and (flonum? value) (fl= value (flfloor value)))
              (number->string (fl->exact-integer value) radix)]
             [else
              (raise-js-unsupported "Number.prototype.toString of a fraction in a radix other than 10")]))]
    [("valueOf") (lambda (x arguments) (normalize-number x))]
    [else #f]))

(define (boolean-method name)
  (case name
    [("toString") (lambda (b arguments) (if b "true" "false"))]
    [("valueOf") (lambda (b arguments) b)]
    [else #f]))

;; ---------------------------------------------------------------------------------------------
;; The property protocol

(define (string-unit-at s i)
  (define units (string->units s))
  (if (< i (vector-length units)) (units->string units i (add1 i)) (void)))

(define (builtin-method v name)
  (cond [(string? v) (string-method name)]
        [(list? v) (array-method name)]
        [(real? v) (number-method name)]
        [(boolean? v) (boolean-method name)]
        [else #f]))

;; get-member : any/c string? -> any   The value of v.NAME.
(define (get-member v name)
  (cond
    [(js-nullish? v)
     (raise-js-error "TypeError"
                     (format "Cannot read properties of ~a (reading '~a')" (js->string v) name))]
    [(string? v)
     (cond [(string=? name "length") (utf16-length v)]
           [(array-index name) => (lambda (i) (string-unit-at v i))]
           [(string-method name) (detached-method "String" name)]
           [else (prototype-miss "String" string-prototype-names name)])]
    [(list? v)
     (cond [(string=? name "length") (length v)]
           [(array-index name) => (lambda (i) (if (< i (length v)) (list-ref v i) (void)))]
           [(array-method name) (detached-method "Array" name)]
           [else (prototype-miss "Array" array-prototype-names name)])]
    [(real? v)
     (if (number-method name)
         (detached-method "Number" name)
         (prototype-miss "Number" number-prototype-names name))]
    [(boolean? v)
     (if (boolean-method name)
         (detached-method "Boolean" name)
         (prototype-miss "Boolean" '() name))]
    [(js-plain-object? v)
     (define member (jref v name (void)))
     (if (void? member) (prototype-miss "Object" '() name) member)]
    [(js-function? v)
     (hash-ref (js-function-statics v) name
               (lambda () (raise-js-unsupported (format "~a.~a" (js-function-name v) name))))]
    [(js-object? v) (js-get-property v name)]
    [(procedure? v) (prototype-miss "Function" function-prototype-names name)]
    [else (raise-js-unsupported (format "a value outside the JavaScript model: ~e" v))]))

;; call-function : any/c list? string? -> any   The call f(arguments...); `text` names the
;; callee in the error for a value that is not a function.
(define (call-function f arguments text)
  (unless (procedure? f)
    (raise-js-error "TypeError" (format "~a is not a function" text)))
  (apply-js-function f arguments))

;; call-method : any/c string? list? string? -> any   The call this.NAME(arguments...).
(define (call-method this name arguments text)
  (cond
    [(js-nullish? this) (get-member this name)]
    [(builtin-method this name) => (lambda (method) (method-result (method this arguments)))]
    [(and (js-object? this) (not (js-function? this))) (js-call-method this name arguments)]
    [else (call-function (get-member this name) arguments text)]))

;; construct : any/c list? string? -> any   The expression new f(arguments...).
(define (construct f arguments text)
  (cond
    [(and (js-function? f) (js-function-construct f))
     => (lambda (construct) (apply construct arguments))]
    [else (raise-js-error "TypeError" (format "~a is not a constructor" text))]))

;; iterate-value : any/c -> list?   The items a spread element or argument contributes.
(define (iterate-value v)
  (cond
    [(list? v) v]
    [(string? v) (for/list ([c (in-string v)]) (string c))]
    [(and (js-object? v) (not (js-function? v)))
     (raise-js-unsupported "spread of a host object")]
    [else (raise-js-error "TypeError" (format "~a is not iterable" (describe-value v)))]))

;; spread-entries : any/c -> (listof (cons/c string? any/c))
;; The own enumerable properties an object spread or Object.entries reads from `v`.
(define (spread-entries v)
  (cond
    [(js-nullish? v) '()]
    [(js-plain-object? v) (own-entries v)]
    [(list? v) (for/list ([item (in-list v)] [i (in-naturals)]) (cons (number->string i) item))]
    [(string? v)
     (define units (string->units v))
     (for/list ([i (in-range (vector-length units))])
       (cons (number->string i) (units->string units i (add1 i))))]
    [(or (real? v) (boolean? v)) '()]
    [(procedure? v) (raise-js-unsupported "enumeration of a function's properties")]
    [(js-object? v) (raise-js-unsupported "enumeration of a host object")]
    [else (raise-js-unsupported (format "a value outside the JavaScript model: ~e" v))]))

;; ---------------------------------------------------------------------------------------------
;; Globals

;; namespace-object : string? hash? -> js-object?
;; A host object with the given members; any other member raises unsupported.
(define (namespace-object name members)
  (make-js-object
   (lambda (member)
     (hash-ref members member
               (lambda () (raise-js-unsupported (format "~a.~a" name member)))))))

(define (wrapper-constructor name)
  (lambda arguments
    (raise-js-unsupported (format "new ~a (wrapper objects)" name))))

(define (number-value? v) (real? v))
(define (finite-number? v)
  (and (real? v) (let ([x (js-fl v)]) (and (fl= x x) (not (fl= (flabs x) +inf.0))))))
(define (integral-number? v)
  (and (finite-number? v) (let ([x (js-fl v)]) (fl= x (flfloor x)))))
(define (nan-value? v)
  (and (real? v) (let ([x (js-fl v)]) (not (fl= x x)))))

(define (to-int32 v)
  (define n (->integer-or-infinity v))
  (cond [(exact-integer? n)
         (define m (modulo n 4294967296))
         (if (>= m 2147483648) (- m 4294967296) m)]
        [else 0]))

(define (digit-value c)
  (cond [(char<=? #\0 c #\9) (- (char->integer c) 48)]
        [(char<=? #\a c #\z) (- (char->integer c) 87)]
        [(char<=? #\A c #\Z) (- (char->integer c) 55)]
        [else 99]))

(define (js-parse-int . arguments)
  (define trimmed (js-trim (js->string (arg arguments 0)) #t #f))
  (define negative? (and (positive? (string-length trimmed)) (char=? (string-ref trimmed 0) #\-)))
  (define unsigned
    (if (and (positive? (string-length trimmed)) (memv (string-ref trimmed 0) '(#\+ #\-)))
        (substring trimmed 1)
        trimmed))
  (define given-radix (to-int32 (arg arguments 1)))
  (cond
    [(and (not (zero? given-radix)) (not (<= 2 given-radix 36))) +nan.0]
    [else
     (define hex-prefix?
       (and (memv given-radix '(0 16)) (regexp-match? #rx"^0[xX]" unsigned)))
     (define radix (cond [hex-prefix? 16] [(zero? given-radix) 10] [else given-radix]))
     (define body (if hex-prefix? (substring unsigned 2) unsigned))
     (define digits
       (list->string (for/list ([c (in-string body)] #:break (>= (digit-value c) radix)) c)))
     (cond [(string=? digits "") +nan.0]
           [else
            (define magnitude (normalize-number (string->number digits radix)))
            (if negative? (js-negate magnitude) magnitude)])]))

(define parse-float-pattern
  #px"^([-+]?)(?:(Infinity)|([0-9]+)(?:\\.([0-9]*))?(?:[eE]([-+]?[0-9]+))?|\\.([0-9]+)(?:[eE]([-+]?[0-9]+))?)")

(define (js-parse-float . arguments)
  (define trimmed (js-trim (js->string (arg arguments 0)) #t #f))
  (define m (regexp-match parse-float-pattern trimmed))
  (cond
    [(not m) +nan.0]
    [else
     (define magnitude
       (cond [(list-ref m 2) +inf.0]
             [(list-ref m 3)
              (decimal->number (list-ref m 3) (or (list-ref m 4) "")
                               (if (list-ref m 5) (string->number (list-ref m 5) 10) 0))]
             [else
              (decimal->number "" (list-ref m 6)
                               (if (list-ref m 7) (string->number (list-ref m 7) 10) 0))]))
     (if (string=? (list-ref m 1) "-") (js-negate magnitude) magnitude)]))

(define number-function
  (js-function
   "Number"
   (lambda arguments (if (null? arguments) 0 (js->number (car arguments))))
   (wrapper-constructor "Number")
   (hash "isFinite" (lambda (v) (finite-number? v))
         "isInteger" (lambda (v) (integral-number? v))
         "isNaN" (lambda (v) (nan-value? v))
         "isSafeInteger" (lambda (v)
                           (and (integral-number? v) (<= (abs (js-fl v)) 9007199254740991.0)))
         "parseFloat" js-parse-float
         "parseInt" js-parse-int
         "MAX_SAFE_INTEGER" 9007199254740991
         "MIN_SAFE_INTEGER" -9007199254740991
         "MAX_VALUE" 1.7976931348623157e308
         "MIN_VALUE" 5e-324
         "EPSILON" 2.220446049250313e-16
         "POSITIVE_INFINITY" +inf.0
         "NEGATIVE_INFINITY" -inf.0
         "NaN" +nan.0)))

(define string-function
  (js-function "String"
               (lambda arguments (if (null? arguments) "" (js->string (car arguments))))
               (wrapper-constructor "String")
               (hash)))

(define boolean-function
  (js-function "Boolean"
               (lambda arguments (and (pair? arguments) (js-truthy? (car arguments))))
               (wrapper-constructor "Boolean")
               (hash)))

(define array-function
  (js-function "Array"
               (lambda arguments (raise-js-unsupported "call of the Array constructor"))
               (lambda arguments (raise-js-unsupported "new Array"))
               (hash "isArray" (lambda (v) (list? v)))))

(define (object-entries v)
  (when (js-nullish? v)
    (raise-js-error "TypeError" "Cannot convert undefined or null to object"))
  (spread-entries v))

(define object-function
  (js-function "Object"
               (lambda arguments (raise-js-unsupported "call of the Object constructor"))
               (lambda arguments (raise-js-unsupported "new Object"))
               (hash "keys" (lambda (v) (map car (object-entries v)))
                     "values" (lambda (v) (map cdr (object-entries v)))
                     "entries" (lambda (v)
                                 (for/list ([e (in-list (object-entries v))])
                                   (list (car e) (cdr e)))))))

;; ---- JSON ----

(define absent (string->uninterned-symbol "absent"))

;; The jvalue JSON.stringify serializes for `v`, or `absent` where it writes nothing.
(define (json-prepare v key)
  (cond
    [(or (void? v) (procedure? v)) absent]
    [(or (string? v) (boolean? v) (eq? v 'null)) v]
    [(real? v)
     (define x (js-fl v))
     (if (or (not (fl= x x)) (fl= (flabs x) +inf.0)) 'null (normalize-number v))]
    [(list? v)
     (for/list ([item (in-list v)] [i (in-naturals)])
       (define prepared (json-prepare item (number->string i)))
       (if (eq? prepared absent) 'null prepared))]
    [(js-plain-object? v)
     (define to-json (jref v 'toJSON (void)))
     (if (procedure? to-json)
         (json-prepare (apply-js-function to-json (list key)) key)
         (make-jobject
          (for*/list ([e (in-list (own-entries v))]
                      [prepared (in-value (json-prepare (cdr e) (car e)))]
                      #:unless (eq? prepared absent))
            (cons (string->symbol (car e)) prepared))))]
    [(js-object? v)
     (if (procedure? (js-get-property v "toJSON"))
         (json-prepare (js-call-method v "toJSON" (list key)) key)
         (raise-js-unsupported "JSON.stringify of a host object"))]
    [else (raise-js-unsupported (format "a value outside the JavaScript model: ~e" v))]))

(define (json-stringify . arguments)
  (unless (js-nullish? (arg arguments 1))
    (raise-js-unsupported "JSON.stringify with a replacer"))
  (define space (arg arguments 2))
  (define indent
    (cond [(real? space)
           (define n (clamp (->integer-or-infinity space) 0 10))
           (and (>= n 1) n)]
          [(string? space)
           (if (string=? space "")
               #f
               (raise-js-unsupported "JSON.stringify with a string indent"))]
          [else #f]))
  (define prepared (json-prepare (arg arguments 0) ""))
  (if (eq? prepared absent)
      (void)
      (jvalue->string prepared #:indent indent)))

(define (json-parse . arguments)
  (unless (void? (arg arguments 1))
    (raise-js-unsupported "JSON.parse with a reviver"))
  (define text (js->string (arg arguments 0)))
  (deep-js-key-order
   (with-handlers ([exn:fail:json?
                    (lambda (e)
                      (raise-js-error "SyntaxError"
                                      (format "~a is not valid JSON (~a)"
                                              (if (> (string-length text) 40)
                                                  (string-append (substring text 0 40) "...")
                                                  text)
                                              (exn-message e))))])
     (string->jvalue text))))

;; ---- Math ----

(define (math-unary f)
  (lambda arguments (normalize-number (f (js-fl (js->number (arg arguments 0)))))))

(define (math-round x)
  (cond [(or (not (fl= x x)) (fl= (flabs x) +inf.0) (fl= x (flfloor x))) x]
        [else
         (define n (floor (+ (inexact->exact x) 1/2)))
         (if (and (zero? n) (fl< x 0.0)) -0.0 (real->double-flonum n))]))

(define (math-sign x)
  (cond [(or (not (fl= x x)) (fl= x 0.0)) x]
        [(fl> x 0.0) 1.0]
        [else -1.0]))

;; Math.max and Math.min: `better?` decides between two operands, and of two zeros the one
;; with the wanted sign wins.
(define (math-extreme start better? wanted-zero)
  (lambda arguments
    (define operands (for/list ([a (in-list arguments)]) (js-fl (js->number a))))
    (normalize-number
     (for/fold ([best start]) ([x (in-list operands)])
       (cond [(or (not (fl= best best)) (not (fl= x x))) +nan.0]
             [(better? x best) x]
             [(and (fl= x best) (fl= x 0.0) (eqv? x wanted-zero)) x]
             [else best])))))

(define math-object
  (namespace-object
   "Math"
   (hash "abs" (math-unary flabs)
         "ceil" (math-unary flceiling)
         "floor" (math-unary flfloor)
         "round" (math-unary math-round)
         "sign" (math-unary math-sign)
         "trunc" (math-unary fltruncate)
         "max" (math-extreme -inf.0 fl> 0.0)
         "min" (math-extreme +inf.0 fl< -0.0)
         "PI" 3.141592653589793)))

;; ---- URI functions ----

(define (uri-decoder keep)
  (lambda arguments
    (or (uri-decode (js->string (arg arguments 0)) keep)
        (raise-js-error "URIError" "URI malformed"))))

(define (uri-encoder unescaped?)
  (lambda arguments
    (uri-encode (js->string (arg arguments 0)) unescaped?)))

;; js-standard-globals : (hash/c string? any/c)
(define js-standard-globals
  (hash "NaN" +nan.0
        "Infinity" +inf.0
        "Number" number-function
        "String" string-function
        "Boolean" boolean-function
        "Array" array-function
        "Object" object-function
        "parseInt" js-parse-int
        "parseFloat" js-parse-float
        "isNaN" (lambda arguments (nan-value? (js->number (arg arguments 0))))
        "isFinite" (lambda arguments (finite-number? (js->number (arg arguments 0))))
        "JSON" (namespace-object "JSON" (hash "parse" json-parse "stringify" json-stringify))
        "Math" math-object
        "encodeURIComponent" (uri-encoder uri-component-unescaped?)
        "decodeURIComponent" (uri-decoder "")
        "encodeURI" (uri-encoder uri-unescaped?)
        "decodeURI" (uri-decoder uri-reserved-characters)
        "URL" url-constructor))

;; Globals of JavaScript and Node that exist and are not implemented: an expression that
;; names one must fail as unsupported, not as a ReferenceError.
(define unimplemented-globals
  '("globalThis" "global" "process" "Date" "RegExp" "Buffer" "require" "module" "exports"
    "Promise" "Symbol" "Map" "Set" "WeakMap" "WeakSet" "WeakRef" "Proxy" "Reflect" "Error"
    "TypeError" "RangeError" "SyntaxError" "ReferenceError" "EvalError" "URIError"
    "AggregateError" "Function" "BigInt" "Intl" "console" "eval" "escape" "unescape"
    "setTimeout" "setInterval" "setImmediate" "clearTimeout" "clearInterval" "clearImmediate"
    "queueMicrotask" "structuredClone" "fetch" "performance" "crypto" "navigator"
    "TextEncoder" "TextDecoder" "URLSearchParams" "AbortController" "AbortSignal" "Event"
    "EventTarget" "ArrayBuffer" "SharedArrayBuffer" "DataView" "Atomics" "WebAssembly"
    "Int8Array" "Uint8Array" "Uint8ClampedArray" "Int16Array" "Uint16Array" "Int32Array"
    "Uint32Array" "Float32Array" "Float64Array" "BigInt64Array" "BigUint64Array" "Blob"
    "File" "FormData" "Headers" "Request" "Response" "WebSocket" "MessageChannel"
    "BroadcastChannel" "Iterator" "FinalizationRegistry" "arguments" "atob" "btoa"))

(define (unimplemented-global? name)
  (and (member name unimplemented-globals) #t))
