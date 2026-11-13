#lang racket/base
;; Unit tests of the YAML reader's errors: the reason, the 1-based line and column, the 0-based
;; position, the source name and the message with js-yaml's snippet, for each class of error.

(require rackunit
         racket/file
         racket/string
         cordis-data
         cordis-yaml)

(define (u . codes) (list->string (map integer->char codes)))

;; The exn:fail:yaml that reading `text` raises.
(define (read-error text #:source [source #f] #:schema [schema 'entry-list])
  (with-handlers ([exn:fail:yaml? values])
    (define v (yaml-read text #:source source #:schema schema))
    (fail (format "expected an error from ~s, got ~s" text v))))

;; Checks the reason and the 1-based line and column of the error `text` raises.
(define (check-error text reason line column)
  (define e (read-error text))
  (check-equal? (list (exn:fail:yaml-reason e) (exn:fail:yaml-line e) (exn:fail:yaml-column e))
                (list reason line column)
                text))

(test-case "the fields of exn:fail:yaml"
  (define e (read-error "a: 1\nb: [1, 2\nc: 3\n" #:source "conf/cordis.yml"))
  (check-pred exn:fail? e)
  (check-equal? (exn:fail:yaml-reason e) "missed comma between flow collection entries")
  (check-equal? (exn:fail:yaml-source e) "conf/cordis.yml")
  (check-equal? (exn:fail:yaml-line e) 3)
  (check-equal? (exn:fail:yaml-column e) 1)
  (check-equal? (exn:fail:yaml-position e) 14)
  (check-equal? (exn-message e)
                (string-append
                 "missed comma between flow collection entries in \"conf/cordis.yml\" (3:1)\n\n"
                 " 1 | a: 1\n"
                 " 2 | b: [1, 2\n"
                 " 3 | c: 3\n"
                 "-----^")))

(test-case "the message without a source name, and with a path as the source"
  (define e (read-error "a: [\n"))
  (check-false (exn:fail:yaml-source e))
  (check-true (string-prefix? (exn-message e)
                              "unexpected end of the stream within a flow collection (2:1)\n\n"))
  (define e2 (read-error "a: [\n" #:source (string->path "dir/x.yml")))
  (check-true (string-contains? (exn-message e2) "in \"dir/x.yml\" (2:1)")))

(test-case "a port's name is the default source"
  (define (port-error port)
    (with-handlers ([exn:fail:yaml? values])
      (yaml-read port)))
  ;; A string port's name is a symbol, which is not taken for a source name.
  (check-false (exn:fail:yaml-source (port-error (open-input-string "a: ["))))
  (check-equal? (exn:fail:yaml-source (port-error (open-input-string "a: [" "named.yml")))
                "named.yml")
  ;; A file port is named by its path.
  (define file (make-temporary-file "cordis-yaml-~a.yml"))
  (dynamic-wind
   void
   (lambda ()
     (call-with-output-file file #:exists 'truncate (lambda (out) (write-string "a: [" out)))
     (define e (call-with-input-file file port-error))
     (check-equal? (exn:fail:yaml-source e) file)
     (check-true (string-contains? (exn-message e) (path->string file)))
     ;; An explicit source wins.
     (define e2
       (call-with-input-file file
         (lambda (port)
           (with-handlers ([exn:fail:yaml? values])
             (yaml-read port #:source "explicit.yml")))))
     (check-equal? (exn:fail:yaml-source e2) "explicit.yml"))
   (lambda () (delete-file file))))

(test-case "the snippet shows the lines around the position"
  ;; Three lines before the position and two after it.
  (define e (read-error "l1: 1\nl2: 2\nl3: 3\nl4: 4\nl5: [\nl6: 6\nl7: 7\nl8: 8\nl9: 9\nl10: 10\n"))
  (check-equal? (exn-message e)
                (string-append
                 "missed comma between flow collection entries (7:1)\n\n"
                 " 4 | l4: 4\n"
                 " 5 | l5: [\n"
                 " 6 | l6: 6\n"
                 " 7 | l7: 7\n"
                 "-----^\n"
                 " 8 | l8: 8\n"
                 " 9 | l9: 9")))

(test-case "indentation errors"
  (check-error "a: 1\n b: 2" "bad indentation of a mapping entry" 2 3)
  (check-error "a:\n  b: 1\n c: 2" "bad indentation of a mapping entry" 3 2)
  (check-error "- a\n -b: [" "bad indentation of a sequence entry" 2 4)
  (check-error "a: b\nc"
               "can not read a block mapping entry; a multiline key may not be an implicit key"
               3 1)
  (check-error "a: 1\n\tb: 2" "tab characters must not be used in indentation" 2 1)
  (check-error "a:\n  - b\n\t- c" "tab characters must not be used in indentation" 3 1))

(test-case "mapping errors"
  (check-error "a: 1\na: 2" "duplicated mapping key" 2 1)
  (check-error "{a: 1, a: 2}" "duplicated mapping key" 1 8)
  (check-error "a:\n  b: 1\n  b: 2" "duplicated mapping key" 3 3))

(test-case "flow collection errors"
  (check-error "[a" "unexpected end of the stream within a flow collection" 2 1)
  (check-error "{a: 1" "unexpected end of the stream within a flow collection" 2 1)
  (check-error "[a b" "unexpected end of the stream within a flow collection" 2 1)
  (check-error "[a, , b]" "expected the node content, but found ','" 1 5)
  (check-error "[a] b" "end of the stream or a document separator is expected" 1 5))

(test-case "quoted scalar errors"
  (check-error "'a" "unexpected end of the stream within a single quoted scalar" 2 1)
  (check-error "\"a" "unexpected end of the stream within a double quoted scalar" 2 1)
  (check-error "'a\n---\nb'" "unexpected end of the document within a single quoted scalar" 2 1)
  (check-error "\"a\n...\nb\"" "unexpected end of the document within a double quoted scalar" 2 1)
  (check-error (string-append "\"" (string #\\) "q\"") "unknown escape sequence" 1 3)
  (check-error (string-append "\"" (string #\\) "x4\"") "expected hexadecimal character" 1 5)
  (check-error (string-append "\"" (string #\\) "U00110000\"")
               "escape sequence is outside the Unicode range" 1 11))

(test-case "block scalar errors"
  (check-error "|0\n a"
               "bad explicit indentation width of a block scalar; it cannot be less than one"
               1 2)
  (check-error "|--\n a" "repeat of a chomping mode identifier" 1 3)
  (check-error "|12\n a" "repeat of an indentation width identifier" 1 3))

(test-case "anchor, alias and tag errors"
  (check-error "a: *x" "unidentified alias \"x\"" 1 6)
  (check-error "&a &b c" "duplication of an anchor property" 1 4)
  (check-error "& a" "name of an anchor node must contain at least one character" 1 2)
  (check-error "* a" "name of an alias node must contain at least one character" 1 2)
  (check-error "!!str !!int 1" "duplication of a tag property" 1 7)
  ;; A tag is checked once its node has been read, so the position is after the node.
  (check-error "!!foo a" "unknown tag !<tag:yaml.org,2002:foo>" 2 1)
  (check-error "!local a" "unknown tag !<!local>" 2 1)
  (check-error "!!timestamp 2001-01-01" "unknown tag !<tag:yaml.org,2002:timestamp>" 2 1)
  (check-error "!!binary aGk=" "unknown tag !<tag:yaml.org,2002:binary>" 2 1)
  (check-error "!!int a" "cannot resolve a node with !<tag:yaml.org,2002:int> explicit tag" 2 1)
  (check-error "!e!x a" "undeclared tag handle \"!e!\"" 1 5))

(test-case "the !!js tag applies to scalars only"
  ;; js-yaml looks a tag up among the types of the node's kind, so it reports the tag as unknown.
  (check-error "!!js [a]" "unknown tag !<tag:yaml.org,2002:js>" 1 9)
  (check-error "!!js {a: 1}" "unknown tag !<tag:yaml.org,2002:js>" 1 12)
  (define no-scalar "cannot resolve a node with !<tag:yaml.org,2002:js> explicit tag")
  (check-error "a: !!js\nb: 1" no-scalar 2 1)
  (check-error "!!js" no-scalar 2 1)
  (define e (read-error "a: !!js b" #:schema 'json))
  (check-equal? (exn:fail:yaml-reason e) "unknown tag !<tag:yaml.org,2002:js>"))

(test-case "directive and document errors"
  (check-error "%YAML 1.2\n%YAML 1.2\n---\na" "duplication of %YAML directive" 3 1)
  (check-error "%YAML 2.0\n---\na" "unacceptable YAML version of the document" 2 1)
  (check-error "%YAML 1.2\na" "directives end mark is expected" 2 1)
  (check-error "a\nb: c" "end of the stream or a document separator is expected" 2 2)
  (define e (read-error "a\n---\nb"))
  (check-equal? (exn:fail:yaml-reason e)
                "expected a single document in the stream, but found more")
  ;; This is the one error without a position.
  (check-equal? (list (exn:fail:yaml-line e) (exn:fail:yaml-column e) (exn:fail:yaml-position e))
                '(#f #f #f))
  (check-equal? (exn-message e) "expected a single document in the stream, but found more"))

(test-case "characters that may not appear"
  (check-error (string-append "a: " (u 1)) "the stream contains non-printable characters" 1 5)
  (check-error (string-append "\"" (u 1) "\"") "expected valid JSON character" 1 3)
  (check-error (string-append "ab" (u 0) "c") "null byte is not allowed in input" 1 3))

(test-case "nesting deeper than js-yaml's maxDepth"
  (define (nested n) (string-append (make-string n #\[) "a" (make-string n #\])))
  (check-equal? (let loop ([v (yaml-read (nested 98))] [depth 0])
                  (if (list? v) (loop (car v) (add1 depth)) depth))
                98)
  (check-error (nested 99) "nesting exceeded maxDepth (100)" 1 100))

(test-case "a recursive alias is an error, where js-yaml would build a cyclic value"
  (check-error "&a [*a]" "recursive aliases are not supported" 1 7)
  (check-error "&a {k: *a}" "recursive aliases are not supported" 1 10)
  (check-error "&a\n- b\n- *a" "recursive aliases are not supported" 4 1))

(test-case "positions count characters"
  ;; The character U+1F600 is two UTF-16 units: js-yaml reports position 9 and column 9 here.
  (define e (read-error (string-append "a: [" (u #x1f600) " x")))
  (check-equal? (exn:fail:yaml-reason e) "unexpected end of the stream within a flow collection")
  (check-equal? (exn:fail:yaml-position e) 8)
  (define e2 (read-error (string-append "a: " (u #x1f600) " b: c")))
  (check-equal? (exn:fail:yaml-reason e2) "bad indentation of a mapping entry")
  ;; Column 7 where js-yaml reports 8.
  (check-equal? (list (exn:fail:yaml-line e2) (exn:fail:yaml-column e2)) '(1 7)))
