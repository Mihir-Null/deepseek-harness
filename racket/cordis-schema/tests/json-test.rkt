#lang racket/base
;; The JSON form: `schema->jvalue` writes what `JSON.stringify(schema)` writes, with uids
;; numbered at serialization, and `jvalue->schema` reads it back.

(require rackunit
         racket/string
         cordis-data
         cordis-schema)

(define (json s) (jvalue->string (schema->jvalue s)))
(define (hydrate text #:revive [revive #f] #:resolvers [resolvers (hash)])
  (jvalue->schema (string->jvalue text) #:revive revive #:resolvers resolvers))

(test-case "the envelope, node property order and post-order uids"
  ;; source: docs/racket/recon/02-cordis-loader.md (Schemastery JSON serialization); Node prints
  ;; the same nodes under the uids 2, 4 and 5 of its process-wide counter.
  (check-equal?
   (json (schema-object* [root (schema-default (schema-role (schema-array 'string) "table")
                                               (list "."))]))
   (string-append
    "{\"uid\":2,\"refs\":{"
    "\"0\":{\"type\":\"string\",\"meta\":{\"required\":true}},"
    "\"1\":{\"type\":\"array\",\"meta\":{\"default\":[\".\"],\"role\":\"table\"},\"inner\":0},"
    "\"2\":{\"type\":\"object\",\"meta\":{\"default\":{}},\"dict\":{\"root\":1}}}}"))
  (check-equal? (json (schema-dict (schema-number) (schema-string)))
                (string-append
                 "{\"uid\":2,\"refs\":{\"0\":{\"type\":\"number\",\"meta\":{}},"
                 "\"1\":{\"type\":\"string\",\"meta\":{}},"
                 "\"2\":{\"type\":\"dict\",\"meta\":{\"default\":{}},\"inner\":0,\"sKey\":1}}}"))
  (check-equal? (json (schema-const (hash 'b 1 'a (list 'null))))
                (string-append "{\"uid\":0,\"refs\":{\"0\":{\"type\":\"const\",\"meta\":{},"
                               "\"value\":{\"a\":[null],\"b\":1}}}}"))
  (check-equal? (json (schema-bitset (list (cons 'a 1) (cons 'b 2))))
                (string-append "{\"uid\":0,\"refs\":{\"0\":{\"type\":\"bitset\","
                               "\"meta\":{\"default\":0},\"bits\":{\"a\":1,\"b\":2}}}}"))
  (check-equal? (json (schema-is "Date"))
                (string-append "{\"uid\":0,\"refs\":{\"0\":{\"type\":\"is\",\"meta\":{},"
                               "\"constructor\":\"Date\"}}}"))
  (check-true (jobject? (schema->jvalue (schema-string)))))

(test-case "values JSON cannot hold"
  ;; Infinity is null, an undefined default is dropped, -0 is 0.
  (check-equal? (jvalue->string (jref* (schema->jvalue (schema-max (schema-number) +inf.0))
                                       '(refs |0| meta)))
                "{\"max\":null}")
  (check-equal? (jvalue->string (jref* (schema->jvalue (schema-default (schema-number) -0.0))
                                       '(refs |0| meta)))
                "{\"default\":0}")
  (check-equal? (json (schema-const (void)))
                "{\"uid\":0,\"refs\":{\"0\":{\"type\":\"const\",\"meta\":{}}}}")
  (check-equal? (jvalue->string
                 (jref* (schema->jvalue (schema-default (schema-any) (list 1 (void) car)))
                        '(refs |0| meta)))
                "{\"default\":[1,null,null]}"))

(test-case "transform: callback text and preserve"
  (define (trim v) (string-trim v))
  (check-equal? (json (schema-transform (schema-string) trim #:source "(v) => v.trim()"))
                (string-append "{\"uid\":1,\"refs\":{\"0\":{\"type\":\"string\",\"meta\":{}},"
                               "\"1\":{\"type\":\"transform\",\"meta\":{},\"inner\":0,"
                               "\"callback\":\"(v) => v.trim()\"}}}"))
  ;; Without a source the procedure's name stands for it.
  (check-equal? (jref* (schema->jvalue (schema-transform (schema-string) trim #f))
                       '(refs |1|))
                (jobject 'type "transform" 'meta (jobject) 'inner 0 'callback "trim"
                         'preserve #f))
  (check-equal? (jref* (schema->jvalue (schema-transform (schema-string) trim #t))
                       '(refs |1| preserve))
                #t)
  ;; The callbacks of the composite constructors carry the text of the TypeScript source.
  (define date-callback (jref* (schema->jvalue (schema-date)) '(refs |2| callback)))
  (check-true (string-prefix? date-callback
                              "(value, options) => {\n      const date = new Date(value)"))
  (check-equal? (jref* (schema->jvalue (schema-date)) '(refs |2| preserve)) #t)
  (check-equal? (jref* (schema->jvalue (schema-date)) '(refs |3| list)) '(0 2)))

(test-case "one node per schema value"
  (define shared (schema-string))
  (define s (schema-object* [first shared] [second shared] [third (schema-string)]))
  (check-equal? (jref* (schema->jvalue s) '(refs |2| dict)) (jobject 'first 0 'second 0 'third 1))
  (define restored (jvalue->schema (schema->jvalue s)))
  (check-eq? (jref (schema-fields restored) 'first) (jref (schema-fields restored) 'second))
  (check-false (eq? (jref (schema-fields restored) 'first)
                    (jref (schema-fields restored) 'third)))
  ;; Serializing twice gives the same text: uids are not stored in schemas.
  (check-equal? (json s) (json s))
  (check-equal? (json restored) (json s)))

(test-case "lazy and recursive schemas"
  (define tree
    (schema-object* [name (schema-string)]
                    [children (schema-array (schema-lazy (lambda () tree)))]))
  (define text
    (string-append
     "{\"uid\":3,\"refs\":{\"0\":{\"type\":\"string\",\"meta\":{}},"
     "\"1\":{\"type\":\"lazy\",\"inner\":3,\"meta\":{}},"
     "\"2\":{\"type\":\"array\",\"meta\":{\"default\":[]},\"inner\":1},"
     "\"3\":{\"type\":\"object\",\"meta\":{\"default\":{}},"
     "\"dict\":{\"name\":0,\"children\":2}}}}"))
  (check-equal? (json tree) text)
  (define restored (hydrate text))
  (check-equal? (json restored) text)
  (define data (jobject 'name "a" 'children (list (jobject 'name "b"))))
  (check-equal? (restored data)
                (jobject 'name "a" 'children (list (jobject 'name "b" 'children '()))))
  (check-exn #rx"^\\$.children\\[0\\].name expected string but got 1$"
             (lambda () (restored (jobject 'children (list (jobject 'name 1))))))
  ;; Metadata of a lazy node reaches the schema it builds, also in the JSON form.
  (check-equal?
   (json (schema-description (schema-lazy (lambda () (schema-string #:default "x"))) "d"))
   (string-append "{\"uid\":1,\"refs\":{"
                  "\"0\":{\"type\":\"string\",\"meta\":{\"description\":\"d\",\"default\":\"x\"}},"
                  "\"1\":{\"type\":\"lazy\",\"inner\":0,\"meta\":{\"description\":\"d\"}}}}"))
  ;; A schema that contains itself without a lazy node reads back with a lazy node at the
  ;; reference that closes the cycle.
  (define cyclic
    (hydrate (string-append
              "{\"uid\":1,\"refs\":{\"0\":{\"type\":\"string\",\"meta\":{}},"
              "\"1\":{\"type\":\"object\",\"meta\":{},"
              "\"dict\":{\"value\":0,\"child\":1}}}}")))
  (check-equal? (schema-type (jref (schema-fields cyclic) 'child)) "lazy")
  (check-true (eq? (schema-inner (jref (schema-fields cyclic) 'child)) cyclic))
  (check-equal? (cyclic (jobject 'child (jobject 'value "v" 'child (jobject))))
                (jobject 'child (jobject 'value "v" 'child (jobject))))
  (check-exn #rx"^\\$.child.child.value expected string but got 2$"
             (lambda () (cyclic (jobject 'child (jobject 'child (jobject 'value 2))))))
  ;; With a default on the cycle a resolve has no end; it stops as a JavaScript stack does.
  (define endless
    (hydrate (string-append
              "{\"uid\":0,\"refs\":{\"0\":{\"type\":\"object\",\"meta\":{\"default\":{}},"
              "\"dict\":{\"child\":0}}}}")))
  (check-exn (lambda (e)
               (and (exn:fail? e)
                    (not (exn:fail:schema? e))
                    (regexp-match? #rx"Maximum call stack size exceeded" (exn-message e))))
             (lambda () (endless (jobject)))))

(test-case "reading: bare nodes, missing metadata, hashes, property order"
  (define bare (hydrate "{\"type\":\"object\",\"dict\":{\"enabled\":{\"type\":\"boolean\"}}}"))
  (check-equal? (bare (jobject 'enabled #t)) (jobject 'enabled #t))
  (check-exn #rx"^\\$.enabled expected boolean but got 1$"
             (lambda () (bare (jobject 'enabled 1))))
  ;; A node keeps the property order it was read with; metadata it lacked goes last.
  (check-equal? (json bare)
                (string-append "{\"uid\":1,\"refs\":{\"0\":{\"type\":\"boolean\",\"meta\":{}},"
                               "\"1\":{\"type\":\"object\",\"dict\":{\"enabled\":0},"
                               "\"meta\":{}}}}"))
  (check-equal? ((jvalue->schema (hash 'type "number" 'meta (hash 'min 1 'default 2)))) 2)
  (check-equal? ((jvalue->schema (hash "type" "array" "inner" (hash "type" "string"))) (list "a"))
                (list "a"))
  ;; uids may be written as numbers or strings.
  (check-equal? ((hydrate (string-append "{\"uid\":\"1\",\"refs\":{\"0\":{\"type\":\"number\"},"
                                         "\"1\":{\"type\":\"array\",\"inner\":\"0\"}}}"))
                 (list 1))
                (list 1)))

(test-case "reading: callbacks, custom resolvers, malformed input"
  (define text (json (schema-transform (schema-string) string-upcase #:source "upper")))
  ;; A callback that is not revived stays a string; resolving through it is an error.
  (define unrevived (hydrate text))
  (check-equal? (schema-callback unrevived) "upper")
  (check-exn (lambda (e) (and (exn:fail? e) (not (exn:fail:schema? e))))
             (lambda () (unrevived "a")))
  (check-equal? (json unrevived) text)
  (define revived
    (hydrate text #:revive (lambda (source) (and (equal? source "upper") string-upcase))))
  (check-equal? (revived "a") "A")
  (check-equal? (json revived) text)
  (define custom
    (hydrate "{\"type\":\"array\",\"inner\":{\"type\":\"even\"}}"
             #:resolvers (hash "even"
                               (lambda (data s options strict?)
                                 (if (even? data)
                                     data
                                     (raise-schema-error "expected even" options))))))
  (check-equal? (custom (list 2 4)) (list 2 4))
  (check-exn #rx"^\\$\\[1\\] expected even$" (lambda () (custom (list 2 3))))
  (check-exn #rx"unsupported type \"even\""
             (lambda () ((hydrate "{\"type\":\"even\"}") 1)))
  (for ([bad (list "{}"
                   "{\"meta\":{}}"
                   "{\"type\":5}"
                   "{\"uid\":3,\"refs\":{\"0\":{\"type\":\"string\"}}}"
                   "{\"uid\":0,\"refs\":{\"0\":{\"type\":\"array\",\"inner\":7}}}"
                   "{\"uid\":0,\"refs\":{\"0\":{\"meta\":{}}}}"
                   "{\"uid\":0,\"refs\":[]}"
                   "{\"type\":\"array\",\"inner\":true}"
                   "{\"type\":\"lazy\"}")])
    (check-exn exn:fail:contract? (lambda () (hydrate bad)) bad)))

(test-case "round trip of a real plugin config keeps behaviour"
  ;; source: packages mcp/mcp-client (docs/racket/recon/17-plugin-authoring-surface.md)
  (define server-name (schema-pattern (schema-required (schema-string)) "^[A-Za-z0-9_-]{1,32}$"))
  (define s
    (schema-union
     (list (schema-object* [transport (schema-const "stdio")]
                           [serverName server-name]
                           [command (schema-string #:required? #t)]
                           [args (schema-array 'string #:default '())]
                           [env (schema-dict 'string #:default (jobject))])
           (schema-object* [transport (schema-const "streamable-http")]
                           [serverName server-name]
                           [url (schema-string #:required? #t)]
                           [headers (schema-dict 'string #:default (jobject))]))))
  (define restored (hydrate (json s)))
  (check-equal? (json restored) (json s))
  (define input (jobject 'transport "streamable-http" 'serverName "web" 'url "https://example.com"))
  (check-equal? (restored input) (s input))
  (check-equal? (restored input)
                (jobject 'transport "streamable-http" 'serverName "web"
                         'url "https://example.com" 'headers (jobject)))
  (check-equal? (schema->string restored) (schema->string s))
  (for ([bad (list (jobject 'transport "stdio" 'serverName "bad name" 'command "x")
                   (jobject 'transport "ws"))])
    (check-equal? (with-handlers ([exn:fail:schema? exn-message]) (restored bad))
                  (with-handlers ([exn:fail:schema? exn-message]) (s bad)))))
