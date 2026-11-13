#lang racket/base
;; Volatile config references: a stable reference to an immutable snapshot that only the owner of
;; a config replaces. Readers keep the reference and call `volatile-ref` at each use.
;; source: vendor/cosmokit/src/volatile.ts
;;
;; Any two references are `equal?`, whatever they hold, and a reference is `equal?` to nothing
;; else: cosmokit's `deepEqual` rule, which makes `deep-equal?` from cordis-data ignore reference
;; contents inside a parsed config. Identity is `eq?`.
;;
;; `make-volatile` raises `exn:fail:contract` whose message is cosmokit's text with no prefix,
;; because the schema resolver reports that text as a validation message.

(require racket/contract/base
         cordis-data)

(provide
 (contract-out
  [volatile? predicate/c]
  ;; A reference to an immutable copy of `value`: jvalues, `(void)` for an absent value, and
  ;; lists and objects of those. Hashes are copied into jobjects.
  [make-volatile (-> any/c volatile?)]
  ;; The current snapshot.
  [volatile-ref (-> volatile? any/c)]
  ;; `target` takes the snapshot `source` holds now. For the owner of the config only.
  [volatile-update! (-> volatile? volatile? void?)]
  ;; Every reference inside jobjects, hashes and lists of `value`, each as (path . reference).
  ;; A path holds symbols for keys and exact integers for list indexes; snapshots are not
  ;; entered. A value that is itself a reference gives one entry with the empty path.
  [volatile-entries (-> any/c (listof (cons/c list? volatile?)))]))

(struct volatile ([snapshot #:mutable])
  #:constructor-name raw-volatile
  #:omit-define-syntaxes
  #:property prop:equal+hash
  (list (lambda (a b recur) #t)
        (lambda (a recur) 1986)
        (lambda (a recur) 2026))
  #:methods gen:custom-write
  [(define (write-proc ref port mode)
     (write-string "#<volatile " port)
     (write (volatile-snapshot ref) port)
     (write-string ">" port))])

;; source: vendor/cosmokit/src/volatile.ts (snapshot)
(define (reject message)
  (raise (make-exn:fail:contract message (current-continuation-marks))))

;; An immutable copy of `value`, or an `exn:fail:contract` with cosmokit's message.
(define (snapshot value)
  (let copy ([v value] [ancestors '()])
    (cond
      [(procedure? v) (reject "volatile config cannot contain functions")]
      [(string? v) (string->immutable-string v)]
      [(or (real? v) (boolean? v) (eq? v 'null) (void? v) (null? v)) v]
      [(list? v) (for/list ([item (in-list v)]) (copy item ancestors))]
      [(jobject? v) (jmap (lambda (key item) (copy item ancestors)) v)]
      [(hash? v)
       (when (memq v ancestors)
         (reject "volatile config cannot contain cycles"))
       (define inner (cons v ancestors))
       (make-jobject
        (for/list ([key (in-list (jkeys v))]
                   #:unless (void? (jref v key)))
          (cons key (copy (jref v key) inner))))]
      [else (reject "volatile config objects must be plain objects or arrays")])))

(define (make-volatile value)
  (raw-volatile (snapshot value)))

(define (volatile-ref ref)
  (volatile-snapshot ref))

(define (volatile-update! target source)
  (set-volatile-snapshot! target (volatile-snapshot source)))

;; source: vendor/cosmokit/src/volatile.ts (volatileEntries)
(define (volatile-entries value)
  (let visit ([v value] [rpath '()] [ancestors '()])
    (cond
      [(volatile? v) (list (cons (reverse rpath) v))]
      [(jobject? v)
       (for*/list ([(key item) (in-jobject v)]
                   [entry (in-list (visit item (cons key rpath) ancestors))])
         entry)]
      [(hash? v)
       (if (memq v ancestors)
           '()
           (for*/list ([key (in-list (jkeys v))]
                       [entry (in-list (visit (jref v key) (cons key rpath) (cons v ancestors)))])
             entry))]
      [(and (pair? v) (list? v))
       (for*/list ([(item index) (in-parallel (in-list v) (in-naturals))]
                   [entry (in-list (visit item (cons index rpath) ancestors))])
         entry)]
      [else '()])))
