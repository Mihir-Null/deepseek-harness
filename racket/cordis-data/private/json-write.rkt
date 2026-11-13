#lang racket/base
;; Provides the JSON writers, whose text is what JavaScript's `JSON.stringify(v, null, indent)`
;; produces: keys in insertion order, the same string escapes, `Number::toString` number text,
;; and the same line layout when indented. NaN and the infinities are written as `null`; any
;; other value that is not a jvalue raises `exn:fail:contract` before anything is written.

(require "core.rkt")

(provide jvalue->string
         jvalue->bytes
         write-jvalue)

;; jvalue->string : any/c #:indent (or/c #f (integer-in 1 10)) -> string?
(define (jvalue->string v #:indent [indent #f])
  (jvalue->text 'jvalue->string v indent #f))

;; jvalue->bytes : any/c #:indent (or/c #f (integer-in 1 10)) -> bytes?
;; The UTF-8 encoding of the text.
(define (jvalue->bytes v #:indent [indent #f])
  (string->bytes/utf-8 (jvalue->text 'jvalue->bytes v indent #f)))

;; write-jvalue : any/c [output-port?] #:indent (or/c #f (integer-in 1 10)) -> void?
;; The whole text is produced first and written in one call.
(define (write-jvalue v [out (current-output-port)] #:indent [indent #f])
  (write-string (jvalue->text 'write-jvalue v indent #f) out)
  (void))
