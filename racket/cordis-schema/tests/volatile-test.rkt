#lang racket/base
;; Volatile references and volatile schemas: the cases of scripts/volatile-config.spec.ts, with
;; scripts/volatile-config.fixture.ts as the shared config.

(require rackunit
         racket/date
         cordis-data
         cordis-schema
         (prefix-in only: cordis-schema/volatile))

;; source: scripts/volatile-config.fixture.ts
(define config
  (schema-object*
   [fixed (schema-string #:default "fixed")]
   [title (schema-volatile (schema-default (schema-string) "hello"))]
   [optional (schema-volatile (schema-string))]
   [nested (schema-object* #:default (jobject)
                           [count (schema-default (schema-volatile (schema-min (schema-number) 0))
                                                  1)])]
   [group (schema-volatile
           (schema-default (schema-object* [list (schema-array (schema-string))])
                           (jobject 'list '())))]))

(define (raises-with fragment thunk)
  (check-exn (lambda (e)
               (and (exn:fail:schema? e)
                    (regexp-match? (regexp-quote fragment) (exn-message e))))
             thunk))

(test-case "the volatile module is the same binding set as the main module"
  (check-eq? only:make-volatile make-volatile)
  (check-eq? only:volatile? volatile?))

(test-case "parses references with defaults and absent values while preserving schema metadata"
  (define parsed (config (jobject)))
  (check-equal? (volatile-ref (jref parsed 'title)) "hello")
  (check-true (void? (volatile-ref (jref parsed 'optional))))
  (check-equal? (volatile-ref (jref* parsed '(nested count))) 1)
  (check-equal? (volatile-ref ((schema-default (schema-description (schema-volatile (schema-string))
                                                                   "Live text")
                                               "text")))
                "text")
  (check-equal? (volatile-ref ((schema-volatile (schema-required (schema-string))) "text")) "text")
  (check-equal? (schema-type (jref (schema-fields config) 'title)) "string")
  (check-equal? (schema-meta-ref (jref (schema-fields config) 'title) 'default) "hello")
  (check-equal? (schema-simplify config parsed) 'null)
  (define reconstructed
    (jvalue->schema (string->jvalue (jvalue->string (schema->jvalue config)))))
  (check-equal? (volatile-ref (jref (reconstructed (jobject 'title "changed")) 'title)) "changed")
  (check-equal? (schema-simplify reconstructed (reconstructed (jobject 'title "changed")))
                (jobject 'title "changed"))
  (check-equal? (volatile-ref ((schema-required (schema-volatile (schema-string))) "present"))
                "present")
  (raises-with "missing required value"
               (lambda () ((schema-required (schema-volatile (schema-string))))))
  (check-exn exn:fail:schema? (lambda () (config (jobject 'nested (jobject 'count -1)))))
  (check-equal?
   (volatile-ref (jref* (config (jobject 'nested (jobject 'count -1)) #:autofix? #t)
                        '(nested count)))
   1))

(test-case "copies data snapshots without sharing the input"
  (define inner (make-hash (list (cons 'list (list "a")))))
  (define input (make-hash (list (cons 'group inner))))
  (define parsed (config input))
  (hash-set! inner 'list (list "a" "b"))
  (check-equal? (volatile-ref (jref parsed 'group)) (jobject 'list (list "a")))
  (check-true (jobject? (volatile-ref (jref parsed 'group))))
  (raises-with "plain objects"
               (lambda () ((schema-volatile (schema-any)) (current-date))))
  (define cyclic (make-hash))
  (hash-set! cyclic 'self cyclic)
  (raises-with "cycles" (lambda () ((schema-volatile (schema-any)) cyclic)))
  (raises-with "functions" (lambda () ((schema-volatile (schema-any)) (list car)))))

(test-case "rejects placements below arrays, dicts, unions, tuples, intersects and transforms"
  (define volatile-string (schema-volatile (schema-string)))
  (define titled (schema-object* [title volatile-string]))
  (for ([entry
         (list (list (schema-object* [items (schema-array volatile-string)]) "$.items.* ")
               (list (schema-object* [items (schema-dict volatile-string)]) "$.items.* ")
               (list (schema-union (list titled (schema-string))) "$.0.title ")
               (list (schema-object* [items (schema-tuple (list volatile-string))]) "$.items.0 ")
               (list (schema-intersect (list titled)) "$.0.title ")
               (list (schema-transform titled values) "$.*.title ")
               (list (schema-object* [block (schema-volatile titled)]) "$.block.title ")
               (list (schema-object* [items (schema-dict (schema-string) volatile-string)])
                     "$.items.<key> "))])
    (define s (car entry))
    (define prefix (cadr entry))
    (check-exn
     (lambda (e)
       (and (exn:fail:schema? e)
            (equal? (exn-message e)
                    (string-append
                     prefix
                     "volatile fields require a fixed object path without an enclosing "
                     "volatile field"))))
     (lambda () (s (jobject)))
     prefix))
  ;; The path of the exception is the schema path.
  (check-equal?
   (with-handlers ([exn:fail:schema? exn:fail:schema-path])
     ((schema-object* [items (schema-array (schema-volatile (schema-string)))]) (jobject)))
   '(items *)))

(test-case "rejects repeat wrapping and supports an entire array or union as a value"
  (check-exn #rx"^volatile schema is already wrapped$"
             (lambda () (schema-volatile (schema-volatile (schema-string)))))
  (check-exn exn:fail:contract?
             (lambda () (schema-volatile (schema-volatile (schema-string)))))
  (check-exn exn:fail:contract? (lambda () (schema-string #:volatile? #t #:pattern "(")))
  (check-equal? (volatile-ref ((schema-volatile (schema-array (schema-string))) (list "a")))
                (list "a"))
  (check-equal? (volatile-ref ((schema-union (list (schema-string) (schema-number)) #:volatile? #t)
                               1))
                1)
  (define s (schema-volatile (schema-string)))
  (check-false (eq? (s "first") (s "first")))
  (check-true (equal? (s "first") (s "second"))))

(test-case "retains ordinary fields and metadata of a volatile block in the serialized schema"
  (define s
    (schema-object*
     [block (schema-volatile (schema-object* [apiKey (schema-role (schema-string) "secret")]
                                             [title (schema-string)]))]))
  (define restored (jvalue->schema (string->jvalue (jvalue->string (schema->jvalue s)))))
  (define block (jref (schema-fields restored) 'block))
  (check-equal? (schema-type block) "object")
  (check-equal? (schema-meta-ref block 'volatile) #t)
  (check-equal? (schema-meta-ref (jref (schema-fields block) 'apiKey) 'role) "secret")
  ;; A walker in the style of dsh's redactSecrets reads the snapshot with the field schemas.
  (define value (restored (jobject 'block (jobject 'apiKey "secret" 'title "public"))))
  (define snapshot (volatile-ref (jref value 'block)))
  (check-equal?
   (jfilter (lambda (key item)
              (not (equal? (schema-meta-ref (jref (schema-fields block) key) 'role) "secret")))
            snapshot)
   (jobject 'title "public")))

(test-case "accepts metadata-free serialized nodes and checks their nested volatile declarations"
  (define s
    (jvalue->schema
     (string->jvalue "{\"type\":\"object\",\"dict\":{\"enabled\":{\"type\":\"boolean\"}}}")))
  (check-equal? (s (jobject 'enabled #t)) (jobject 'enabled #t))
  (check-equal? (s (jobject)) (jobject))
  (define dynamic
    (jvalue->schema
     (string->jvalue
      (string-append "{\"type\":\"object\",\"dict\":{\"items\":{\"type\":\"array\",\"inner\":"
                     "{\"type\":\"string\",\"meta\":{\"volatile\":true}}}}}"))))
  (raises-with "items" (lambda () (dynamic (jobject 'items '())))))

(test-case "resolves recursive lazy schemas only for the supplied data"
  (define (tree)
    (schema-object* [name (schema-string)]
                    [children (schema-array (schema-lazy tree) #:default '())]))
  (check-equal? ((tree) (jobject 'name "root")) (jobject 'name "root" 'children '()))
  (check-equal? ((tree) (jobject 'name "root" 'children (list (jobject 'name "leaf"))))
                (jobject 'name "root"
                         'children (list (jobject 'name "leaf" 'children '()))))
  ;; A lazy schema below an array is not expanded for data that does not reach it.
  (define (lazy-items)
    (schema-object*
     [items (schema-array (schema-lazy (lambda () (schema-volatile (schema-string)))))]))
  (check-equal? ((lazy-items) (jobject)) (jobject 'items '()))
  (define items (lazy-items))
  ;; It is checked when it is built, with the data path of that moment.
  (raises-with "$.items[0] " (lambda () (items (jobject 'items (list "a")))))
  ;; Once built, the same schema value is rejected up front, with the schema path.
  (raises-with "$.items.*.* " (lambda () (items (jobject))))
  ;; A lazy field is built even when the input omits it, as in Schemastery.
  (define s
    (schema-object*
     [lazy (schema-lazy (lambda () (schema-object* [live (schema-volatile (schema-string))])))]))
  (raises-with "$.lazy.live " (lambda () (s (jobject 'lazy (jobject 'live "value")))))
  (raises-with "$.lazy.*.live " (lambda () (s (jobject)))))

(test-case "comparison ignores reference contents while retaining ordinary differences"
  (define first (config (jobject 'title "a")))
  (define second (config (jobject 'title "b")))
  (check-true (deep-equal? first second #:strict? #t))
  (check-true (equal? first second))
  (check-false (deep-equal? first (config (jobject 'fixed "changed")) #:strict? #t))
  (check-false (deep-equal? (jref first 'title) "a" #:strict? #t))
  (check-false (deep-equal? "a" (jref first 'title) #:strict? #t))
  (check-false (equal? (jref first 'title) "a")))

(test-case "enumerates references through shared containers without entering snapshots or cycles"
  (define ref (make-volatile (jobject 'nested "value")))
  (define shared (jobject 'live ref))
  (define cfg (make-hash))
  (hash-set! cfg 'list (list shared shared))
  (hash-set! cfg 'opaque (current-date))
  (hash-set! cfg 'plain "value")
  (hash-set! cfg 'self cfg)
  (define entries (volatile-entries cfg))
  (check-equal? (map car entries) '((list 0 live) (list 1 live)))
  (check-true (andmap (lambda (entry) (eq? (cdr entry) ref)) entries))
  (check-equal? (map car (volatile-entries ref)) '(()))
  (check-eq? (cdar (volatile-entries ref)) ref)
  (check-equal? (volatile-entries "plain") '())
  ;; A path works with jref*.
  (define parsed (config (jobject)))
  (for ([entry (in-list (volatile-entries parsed))])
    (check-eq? (jref* parsed (car entry)) (cdr entry)))
  (check-equal? (map car (volatile-entries parsed))
                '((title) (optional) (nested count) (group))))

(test-case "reports unsupported volatile values as validation issues with their path"
  (define s
    (schema-object* [block (schema-object* [when (schema-volatile (schema-date))])]))
  (define epoch (seconds->date 0 #f))
  (check-exn
   (lambda (e)
     (and (exn:fail:schema? e)
          (equal? (exn:fail:schema-path e) '(block when))
          (equal? (exn-message e)
                  "$.block.when volatile config objects must be plain objects or arrays")))
   (lambda () (s (jobject 'block (jobject 'when epoch)))))
  (check-true (void? (volatile-ref (jref* (s (jobject 'block (jobject))) '(block when))))))

(test-case "references: creation, update and printing"
  (define a (make-volatile (hash 'k (list 1 2))))
  (define b (make-volatile "next"))
  (check-true (volatile? a))
  (check-false (volatile? (jobject)))
  (check-equal? (volatile-ref a) (jobject 'k (list 1 2)))
  (check-true (immutable? (volatile-ref (make-volatile (string-copy "text")))))
  (check-true (void? (volatile-ref (make-volatile (void)))))
  (check-equal? (volatile-ref (make-volatile 'null)) 'null)
  (check-equal? (volatile-update! a b) (void))
  (check-equal? (volatile-ref a) "next")
  (check-equal? (volatile-ref b) "next")
  (check-equal? (format "~a" (make-volatile 1)) "#<volatile 1>")
  (check-exn #rx"^volatile config cannot contain functions$" (lambda () (make-volatile car)))
  (check-exn #rx"^volatile config objects must be plain objects or arrays$"
             (lambda () (make-volatile (make-volatile 1))))
  (check-exn exn:fail:contract? (lambda () (volatile-ref 5))))

(test-case "a commit of new references leaves readers holding the same reference"
  ;; What the loader does for a volatile-only change: parse the candidate, then copy each new
  ;; snapshot into the reference the plugin already holds.
  (define current (config (jobject 'title "old")))
  (define held (jref current 'title))
  (define candidate (config (jobject 'title "new" 'group (jobject 'list (list "x")))))
  (for ([target (in-list (volatile-entries current))]
        [source (in-list (volatile-entries candidate))])
    (check-equal? (car target) (car source))
    (volatile-update! (cdr target) (cdr source)))
  (check-equal? (volatile-ref held) "new")
  (check-equal? (volatile-ref (jref current 'group)) (jobject 'list (list "x"))))
