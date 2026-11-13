#lang racket/base
;; The session event envelope, event inputs and plugin records.
;;
;; A `session-event` is an immutable parsed view of one log entry. It keeps the JSON object it
;; was created or read with, so writing an event back yields the same keys in the same order.
;; `jvalue->session-event` checks the envelope only; it does not interpret `surfaceOp` or
;; `sourceEventSeqs`. The two metadata accessors return a parsed value when the stored value
;; has the valid form and #f otherwise; `validate-surface-metadata` of `dsh-session/surface`
;; is the procedure that reports malformed metadata.
;; source: packages/core/session/src/types.ts:470-562, packages/core/session/src/index.ts:206-234

(require cordis-data
         "base.rkt"
         "names.rkt")

(provide (struct-out surface-replace)
         session-event?
         session-event-type
         session-event-seq
         session-event-time
         session-event-data
         session-event-surface-op
         session-event-source-seqs
         session-event-ignorable?
         session-event->jvalue
         jvalue->session-event
         make-session-event
         surface-op->jvalue
         jvalue->surface-op
         session-event-input?
         make-session-event-input
         session-event-input-type
         session-event-input-data
         session-event-input-surface-op
         session-event-input-sources
         (struct-out plugin-record)
         plugin-record-type?
         plugin-record-input
         plugin-record-input?
         plugin-record-input-declaration
         plugin-record-input-data)

;; A positional replacement: this event takes the place of the surface nodes from `start-seq`
;; through `end-seq`, both inclusive.
(struct surface-replace (start-seq end-seq) #:transparent)

(struct session-event (jv type seq time data surface-op source-seqs ignorable?)
  #:property prop:equal+hash
  (list (lambda (a b recur) (recur (session-event-jv a) (session-event-jv b)))
        (lambda (e recur) (recur (session-event-jv e)))
        (lambda (e recur) (recur (session-event-jv e))))
  #:property prop:custom-write
  (lambda (e port mode)
    (write-string "#<session-event " port)
    (write-string (printable-json (session-event-jv e)) port)
    (write-string ">" port)))

;; Printing must not raise for an event whose data is not a jvalue.
(define (printable-json jv)
  ;; exn:fail:contract: `jvalue->string` rejects a value outside the jvalue model; the printed
  ;; form then falls back to the type and seq, which are always valid.
  (with-handlers ([exn:fail:contract?
                   (lambda (e) (format "~a seq ~a" (jref jv 'type) (jref jv 'seq)))])
    (jvalue->string jv)))

;; ---- surface metadata ----

;; source: packages/core/session/src/types.ts (SurfaceOp); key order op, startSeq, endSeq
(define (surface-op->jvalue op)
  (if (eq? op 'append)
      "append"
      (jobject 'op "replace"
               'startSeq (surface-replace-start-seq op)
               'endSeq (surface-replace-end-seq op))))

;; jvalue->surface-op : any/c -> (or/c 'append surface-replace? #f)
;; #f for anything but "append" or the exact three-key replace object.
;; source: packages/core/session/src/surface.ts (isReplaceOp)
(define (jvalue->surface-op raw)
  (cond
    [(equal? raw "append") 'append]
    [(and (record? raw)
          (= (jcount raw) 3)
          (equal? (field raw 'op) "replace")
          (valid-seq? (field raw 'startSeq))
          (valid-seq? (field raw 'endSeq)))
     (surface-replace (inexact->exact (field raw 'startSeq))
                      (inexact->exact (field raw 'endSeq)))]
    [else #f]))

(define (parse-source-seqs raw)
  (and (list? raw)
       (andmap valid-seq? raw)
       (map inexact->exact raw)))

;; ---- reading and building ----

(define envelope-keys '(type seq time data surfaceOp sourceEventSeqs ignorable))

;; `Number.isSafeInteger(time)`, which admits -0.
(define (valid-time? v)
  (or (safe-integer? v) (eqv? v -0.0)))

;; view : jobject? -> session-event?
;; Builds the parsed view of an envelope that already passed the envelope check.
(define (view jv)
  (define type (string->immutable-string (jref jv 'type)))
  (session-event jv
                 type
                 (inexact->exact (jref jv 'seq))
                 (inexact->exact (jref jv 'time))
                 (jref jv 'data)
                 (and (surface-type-name? type) (jvalue->surface-op (jref jv 'surfaceOp absent)))
                 (parse-source-seqs (jref jv 'sourceEventSeqs absent))
                 (eq? (jref jv 'ignorable absent) #t)))

;; jvalue->session-event : any/c #:subject string? -> session-event?
;; source: packages/core/session/src/index.ts (assertSessionEventEnvelope, envelope part)
(define (jvalue->session-event jv #:subject [subject "session event"])
  (define (reject)
    (raise-session-error "~a has an invalid event envelope" subject))
  (unless (record? jv) (reject))
  (define envelope (if (jobject? jv) jv (make-jobject (jobject->alist jv))))
  (for ([key (in-list (jkeys envelope))])
    (unless (memq key envelope-keys) (reject)))
  (define ignorable (jref envelope 'ignorable absent))
  (unless (and (string? (jref envelope 'type absent))
               (valid-seq? (jref envelope 'seq absent))
               (valid-time? (jref envelope 'time absent))
               (jhas? envelope 'data)
               (or (absent? ignorable) (eq? ignorable #t)))
    (reject))
  (view envelope))

;; `absent` and #f both mean that a surface operation or a source list is not given, so the
;; result of an input accessor can be passed on as it is. The empty list is a given list.
(define (not-given? v)
  (or (absent? v) (not v)))

;; make-session-event : string? session-seq? exact-integer? jvalue? ... -> session-event?
;; Key order: type, seq, time, data, then the two metadata keys in the order `order` selects
;; (`sourceEventSeqs` first for a live append, `surfaceOp` first for a synthetic recovery
;; result), then `ignorable`.
;; source: packages/core/session/src/index.ts:531-542 and :936-942,
;;         packages/core/session/src/repair.ts:176-192
(define (make-session-event type seq time data
                            #:sources [sources absent]
                            #:surface-op [op absent]
                            #:ignorable? [ignorable? #f]
                            #:metadata-order [order 'sources-first])
  (define source-members
    (if (not-given? sources) '() (list (cons 'sourceEventSeqs sources))))
  (define op-members
    (if (not-given? op) '() (list (cons 'surfaceOp (surface-op->jvalue op)))))
  (view
   (make-jobject
    (append (list (cons 'type (string->immutable-string type))
                  (cons 'seq seq)
                  (cons 'time time)
                  (cons 'data data))
            (if (eq? order 'op-first)
                (append op-members source-members)
                (append source-members op-members))
            (if ignorable? (list (cons 'ignorable #t)) '())))))

(define (session-event->jvalue e)
  (session-event-jv e))

;; ---- inputs ----

;; One event proposed for append, before it has a seq and a time. `surface-op` and `sources`
;; are #f when not given.
(struct session-event-input (type data surface-op sources))

(define (make-session-event-input type data #:surface-op [op absent] #:sources [sources absent])
  (session-event-input (string->immutable-string type)
                       data
                       (if (not-given? op) #f op)
                       (if (not-given? sources) #f sources)))

;; ---- plugin records ----

(define (plugin-record-type? v)
  (plugin-record-type-name? v))

;; The read side of a plugin record: one committed ignorable event of a `plugin:` type.
(struct plugin-record (type seq time data) #:transparent)

;; The write side for a declared record type. `declaration` is the value the declaring
;; `define-session-event` form created; its tag is the record type.
(struct plugin-record-input (declaration data))
