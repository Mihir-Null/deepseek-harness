#lang racket/base
;; Tests for the WHATWG URL subset in dsh-util/private/url. tests/data/url-table.json holds what
;; Node's URL gives for each input (tests/gen/gen-url-table.mjs produced it).

(require rackunit
         racket/runtime-path
         racket/port
         cordis-data
         dsh-util/private/url)

(define-runtime-path table-path "data/url-table.json")
(define table (call-with-input-file table-path (lambda (in) (string->jvalue (port->string in)))))

(define (describe u)
  (and u
       (jobj ['href (wurl-href u)]
             ['protocol (wurl-protocol u)]
             ['hostname (wurl-hostname u)]
             ['port (wurl-port-string u)]
             ['pathname (wurl-pathname u)]
             ['origin (wurl-origin u)]
             ['username (wurl-username u)]
             ['password (wurl-password u)]
             ['search (wurl-search u)]
             ['hash (wurl-hash u)])))

(define (check-url actual expected label)
  (define wanted (if (eq? expected 'null) #f expected))
  (check-equal? (describe actual) wanted label))

(test-case "URL.parse of one input matches Node"
  (for ([row (in-list (jref table 'parse))])
    (define input (jref row 'input))
    (check-url (wurl-parse input) (jref row 'url) (format "~s" input))))

(test-case "URL.parse with a base matches Node"
  (for ([row (in-list (jref table 'resolve))])
    (define reference (jref row 'reference))
    (define base (jref row 'base))
    (check-url (wurl-resolve reference base) (jref row 'url) (format "~s against ~s" reference base))))
