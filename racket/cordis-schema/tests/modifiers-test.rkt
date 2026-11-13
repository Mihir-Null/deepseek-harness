#lang racket/base
;; Modifiers, the option keywords of the constructors, the `schema-from` shorthand, the
;; accessors, and the contracts of the public functions.

(require rackunit
         cordis-data
         cordis-schema)

(define (json s) (jvalue->string (schema->jvalue s)))

;; The JSON text of the single node of a childless schema's metadata.
(define (meta-json s) (jvalue->string (schema-meta s)))

(test-case "every modifier returns a new schema and leaves its argument unchanged"
  (define base (schema-string))
  (for ([modify (list schema-required schema-hidden schema-disabled schema-collapse schema-loose
                      schema-deprecated schema-experimental schema-volatile
                      (lambda (s) (schema-default s "d"))
                      (lambda (s) (schema-description s "text"))
                      (lambda (s) (schema-comment s "text"))
                      (lambda (s) (schema-link s "https://example.com"))
                      (lambda (s) (schema-min s 1))
                      (lambda (s) (schema-max s 2))
                      (lambda (s) (schema-step s 3))
                      (lambda (s) (schema-role s "secret"))
                      (lambda (s) (schema-pattern s "^a"))
                      (lambda (s) (schema-extra s 'custom 1))
                      (lambda (s) (schema-i18n s (jobject 'en "text"))))])
    (define modified (modify base))
    (check-true (schema? modified))
    (check-false (eq? modified base))
    (check-equal? (meta-json base) "{}")))

(test-case "flag modifiers"
  (check-equal? (meta-json (schema-required (schema-string))) "{\"required\":true}")
  (check-equal? (meta-json (schema-required (schema-string) #f)) "{\"required\":false}")
  (check-equal? (meta-json (schema-hidden (schema-string))) "{\"hidden\":true}")
  (check-equal? (meta-json (schema-disabled (schema-string))) "{\"disabled\":true}")
  (check-equal? (meta-json (schema-collapse (schema-string))) "{\"collapse\":true}")
  (check-equal? (meta-json (schema-loose (schema-string))) "{\"loose\":true}")
  (check-equal? (meta-json (schema-hidden (schema-hidden (schema-string)) #f))
                "{\"hidden\":false}"))

(test-case "value modifiers keep the position of a key's first assignment"
  (define s
    (schema-max
     (schema-min (schema-default (schema-step (schema-min (schema-number) 5) 1) 7) 0)
     9))
  (check-equal? (meta-json s) "{\"min\":0,\"step\":1,\"default\":7,\"max\":9}")
  (check-equal? (meta-json (schema-comment (schema-link (schema-description (schema-string) "d")
                                                        "https://example.com")
                                           "c"))
                "{\"description\":\"d\",\"link\":\"https://example.com\",\"comment\":\"c\"}")
  (check-equal? (meta-json (schema-description (schema-string) (hash 'en "E" 'zh "Z")))
                "{\"description\":{\"en\":\"E\",\"zh\":\"Z\"}}")
  ;; A default that is a hash is stored as a jobject.
  (check-true (jobject? (schema-meta-ref (schema-default (schema-any) (hash 'a 1)) 'default)))
  ;; (void) records the key as undefined: absent from the metadata, but in its place.
  (define cleared (schema-default (schema-object '()) (void)))
  (check-equal? (meta-json cleared) "{}")
  (check-true (void? (schema-meta-ref cleared 'default)))
  (check-equal? (schema-meta-ref cleared 'default 'none) 'none)
  (check-true (void? (cleared)))
  (check-equal? (meta-json (schema-required (schema-default cleared (jobject 'a 1))))
                "{\"default\":{\"a\":1},\"required\":true}"))

(test-case "role, pattern, badges, volatile, extra"
  (check-equal? (meta-json (schema-role (schema-string) "secret")) "{\"role\":\"secret\"}")
  (check-equal? (meta-json (schema-role (schema-string) "regexp" (hash 'flag "i")))
                "{\"role\":\"regexp\",\"extra\":{\"flag\":\"i\"}}")
  ;; role replaces a previous extra, as Schemastery's `{ ...meta, role, extra }` does.
  (check-equal? (meta-json (schema-role (schema-role (schema-string) "a" 1) "b"))
                "{\"role\":\"b\"}")
  (check-equal? (meta-json (schema-pattern (schema-string) "^a/b[/]$" #:flags "ig"))
                "{\"pattern\":{\"source\":\"^a\\\\/b[/]$\",\"flags\":\"gi\"}}")
  (check-equal? (meta-json (schema-pattern (schema-string) ""))
                "{\"pattern\":{\"source\":\"(?:)\",\"flags\":\"\"}}")
  (check-equal? (meta-json (schema-deprecated (schema-string)))
                "{\"badges\":[{\"text\":\"deprecated\",\"type\":\"danger\"}]}")
  (define base (schema-experimental (schema-string)))
  (check-equal? (meta-json (schema-deprecated base))
                (string-append "{\"badges\":[{\"text\":\"experimental\",\"type\":\"warning\"},"
                               "{\"text\":\"deprecated\",\"type\":\"danger\"}]}"))
  ;; No aliasing: the schema a badge was added to keeps its own list.
  (check-equal? (meta-json base) "{\"badges\":[{\"text\":\"experimental\",\"type\":\"warning\"}]}")
  (check-equal? (meta-json (schema-volatile (schema-string))) "{\"volatile\":true}")
  (check-equal? (meta-json (schema-extra (schema-extra (schema-string) "custom" (hash 'x 1))
                                         'default
                                         "q"))
                "{\"custom\":{\"x\":1},\"default\":\"q\"}")
  (check-equal? ((schema-extra (schema-string) 'default "q")) "q"))

(test-case "set and push are functional"
  (define base (schema-object* [a (schema-string)]))
  (define extended (schema-set (schema-set base 'b 'number) "a" (schema-boolean)))
  (check-equal? (schema->string base) "{ a?: string }")
  (check-equal? (schema->string extended) "{ a?: boolean, b: number }")
  (check-exn exn:fail:contract? (lambda () (schema-set (schema-string) 'a (schema-string))))
  (define u (schema-union (list "a")))
  (check-equal? (schema->string (schema-push (schema-push u "b") (schema-number)))
                "\"a\" | \"b\" | number")
  (check-equal? (schema->string u) "\"a\"")
  (check-equal? (schema->string (schema-push (schema-tuple '()) 'string)) "[string]")
  (check-equal? (schema->string (schema-push (schema-intersect '()) (schema-object '()))) "{}")
  (check-exn exn:fail:contract? (lambda () (schema-push (schema-string) (schema-string)))))

(test-case "option keywords equal the modifier chain in the documented order"
  (check-equal? (json (schema-number #:default 3 #:min 1 #:step 1))
                (json (schema-default (schema-min (schema-step (schema-number) 1) 1) 3)))
  (define all
    (schema-string #:volatile? #t #:experimental? #t #:deprecated? #t #:loose? #t #:collapse? #f
                   #:disabled? #t #:hidden? #t #:link "l" #:comment "c" #:description "d"
                   #:default "x" #:required? #f #:role "r" #:max 9 #:min 1 #:step 2
                   #:pattern "^x"))
  (check-equal?
   (jkeys (schema-meta all))
   '(pattern step min max role required default description comment link hidden disabled collapse
             loose badges volatile))
  (check-equal? (schema-meta-ref all 'badges)
                (list (jobject 'text "deprecated" 'type "danger")
                      (jobject 'text "experimental" 'type "warning")))
  (check-equal? (schema-meta-ref all 'collapse) #f)
  ;; The last three do nothing when false.
  (check-equal? (meta-json (schema-string #:deprecated? #f #:experimental? #f #:volatile? #f))
                "{}")
  ;; Options apply after the constructor's own metadata.
  (check-equal? (meta-json (schema-array 'string #:default (list ".") #:role "table"))
                "{\"default\":[\".\"],\"role\":\"table\"}")
  (check-equal? (meta-json (schema-natural #:min 1 #:default 5))
                "{\"step\":1,\"min\":1,\"default\":5}")
  ;; Every constructor takes them.
  (for ([s (list (schema-any #:hidden? #t) (schema-never #:hidden? #t)
                 (schema-const 1 #:hidden? #t) (schema-boolean #:hidden? #t)
                 (schema-percent #:hidden? #t) (schema-date #:hidden? #t)
                 (schema-regexp "i" #:hidden? #t) (schema-array-buffer 'hex #:hidden? #t)
                 (schema-bitset '() #:hidden? #t) (schema-function #:hidden? #t)
                 (schema-is "Date" #:hidden? #t) (schema-dict 'string #:hidden? #t)
                 (schema-tuple '() #:hidden? #t) (schema-object '() #:hidden? #t)
                 (schema-union '() #:hidden? #t) (schema-intersect '() #:hidden? #t)
                 (schema-transform 'string values #:hidden? #t)
                 (schema-lazy schema-string #:hidden? #t)
                 (schema-custom "t" (lambda (d s o strict?) d) #:hidden? #t))])
    (check-equal? (schema-meta-ref s 'hidden) #t)))

(test-case "schema-from shorthand"
  (define s (schema-string))
  (check-eq? (schema-from s) s)
  (check-equal? (json (schema-from (void))) (json (schema-any)))
  (check-equal? (json (schema-from 'null)) (json (schema-any)))
  (check-equal? (json (schema-from "x")) (json (schema-required (schema-const "x"))))
  (check-equal? (json (schema-from 1)) (json (schema-required (schema-const 1))))
  (check-equal? (json (schema-from #f)) (json (schema-required (schema-const #f))))
  (check-equal? (json (schema-from 'string)) (json (schema-required (schema-string))))
  (check-equal? (json (schema-from 'number)) (json (schema-required (schema-number))))
  (check-equal? (json (schema-from 'boolean)) (json (schema-required (schema-boolean))))
  (check-equal? (json (schema-from 'function)) (json (schema-required (schema-function))))
  (check-exn (lambda (e)
               (and (exn:fail:contract? e)
                    (equal? (exn-message e) "cannot infer schema from [object Object]")))
             (lambda () (schema-from (jobject))))
  (check-exn #rx"^cannot infer schema from Symbol\\(other\\)$" (lambda () (schema-array 'other)))
  ;; Wherever a constructor takes a schema it takes the shorthand.
  (check-equal? (json (schema-dict 'string 'string))
                (json (schema-dict (schema-required (schema-string))
                                   (schema-required (schema-string)))))
  (check-equal? (schema->string (schema-tuple (list 'string 1 (void)))) "[string, 1, any]")
  (check-equal? (schema->string (schema-object (list (cons "a" 'number) (cons 'b "x"))))
                "{ a: number, b: \"x\" }")
  (check-equal? (schema->string (schema-transform 'string values)) "string")
  (check-equal? (schema->string (schema-union (list -1 (schema-number)))) "-1 | number"))

(test-case "accessors"
  (define inner (schema-number))
  (define key (schema-string))
  (define d (schema-dict inner key))
  (check-equal? (schema-type d) "dict")
  (check-eq? (schema-inner d) inner)
  (check-eq? (schema-key-schema d) key)
  (check-false (schema-members d))
  (check-false (schema-fields d))
  (check-false (schema-bits d))
  (check-false (schema-constructor d))
  (check-false (schema-callback d))
  (check-true (void? (schema-const-value d)))
  (check-equal? (schema-meta d) (jobject 'default (jobject)))
  (define o (schema-object* [a inner] [b key]))
  (check-equal? (jkeys (schema-fields o)) '(a b))
  (check-eq? (jref (schema-fields o) 'a) inner)
  (check-false (schema-inner o))
  (define u (schema-union (list inner key)))
  (check-equal? (schema-members u) (list inner key))
  (check-equal? (schema-const-value (schema-const (hash 'a 1))) (jobject 'a 1))
  (check-equal? (schema-type (schema-natural)) "number")
  (check-equal? (schema-meta-ref (schema-natural) 'step) 1)
  (check-true (void? (schema-meta-ref (schema-natural) 'max))))

(test-case "contracts reject arguments of the wrong kind"
  (check-exn exn:fail:contract? (lambda () (schema-min (schema-number) "1")))
  (check-exn exn:fail:contract? (lambda () (schema-number #:min "1")))
  (check-exn exn:fail:contract? (lambda () (schema-required "not a schema")))
  (check-exn exn:fail:contract? (lambda () (schema-required (schema-string) 'yes)))
  (check-exn exn:fail:contract? (lambda () (schema-description (schema-string) 5)))
  (check-exn exn:fail:contract? (lambda () (schema-object "fields")))
  (check-exn exn:fail:contract? (lambda () (schema-union "members")))
  (check-exn exn:fail:contract? (lambda () (schema-transform (schema-string) "callback")))
  (check-exn exn:fail:contract? (lambda () (schema-lazy 5)))
  (check-exn exn:fail:contract? (lambda () (schema-array-buffer 'utf8)))
  (check-exn exn:fail:contract? (lambda () (schema-resolve "s" 1)))
  (check-exn exn:fail:contract? (lambda () (schema-resolve (schema-string) 1 #:path '(1.5))))
  (check-exn exn:fail:contract? (lambda () (schema->jvalue 5)))
  (check-exn exn:fail:contract? (lambda () (jvalue->schema "text")))
  (check-exn exn:fail:contract? (lambda () (schema-meta-ref (schema-string) "default")))
  ;; A pattern JavaScript rejects, or one that does not translate, fails when it is set.
  (check-exn exn:fail:contract? (lambda () (schema-pattern (schema-string) "(")))
  (check-exn exn:fail:contract? (lambda () (schema-pattern (schema-string) "a" #:flags "x")))
  (check-exn exn:fail:contract? (lambda () (schema-pattern (schema-string) "a" #:flags "gg")))
  (check-exn exn:fail:contract?
             (lambda () (schema-pattern (schema-string) "\\p{Script=Greek}" #:flags "u"))))
