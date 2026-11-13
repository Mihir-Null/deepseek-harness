#lang racket/base
;; dsh-util/values: JSON value helpers of dsh util/values in jvalue terms.
;;
;; source: packages/util/values/src/index.ts
;;
;; jvalues are immutable, so `deepFreeze`, the cross-realm prototype checks and the
;; single-read-per-property walk of dsh have no counterpart. What remains is the lossless JSON
;; domain check (`isJsonValue`, `snapshotJsonValue`), structural equality (`deepEqualJson`),
;; `assertNever`, and `WeakMapWithValues`. `PartialArguments` is in dsh-util/partial-json and
;; re-exported here.

(require racket/contract/base
         cordis-data
         "partial-json.rkt")

(provide (all-from-out "partial-json.rkt")
         (contract-out
          [lossless-json? (-> any/c boolean?)]
          [snapshot-json (-> any/c any/c)]
          [deep-equal-json? (-> any/c any/c boolean?)]
          [assert-never (->* (any/c) ((or/c string? #f)) none/c)]
          [make-weak-map-with-values (-> weak-map-with-values?)]
          [weak-map-with-values? (-> any/c boolean?)]
          [weak-map-ref (->* (weak-map-with-values? any/c) (any/c) any/c)]
          [weak-map-has? (-> weak-map-with-values? any/c boolean?)]
          [weak-map-set! (-> weak-map-with-values? any/c any/c void?)]
          [weak-map-remove! (-> weak-map-with-values? any/c boolean?)]
          [weak-map-clear! (-> weak-map-with-values? void?)]
          [weak-map-values (-> weak-map-with-values? list?)]))

;; ---------------------------------------------------------------------------------------------
;; Lossless JSON

;; A unique value for "not lossless"; distinct from every jvalue, including #f.
(define invalid (string->uninterned-symbol "invalid"))

(define (object-key? k) (or (symbol? k) (string? k)))

;; A hash that holds one key both as a symbol and as a string has no single object form.
(define (distinct-keys? h)
  (define seen (make-hasheq))
  (for/and ([k (in-hash-keys h)])
    (define sym (if (symbol? k) k (string->symbol k)))
    (begin0 (not (hash-ref seen sym #f))
            (hash-set! seen sym #t))))

;; The normal form of v: v itself when nothing changes, a rebuilt value otherwise, or `invalid`.
;; `ancestors` holds the mutable hashes on the path from the root; only they can form a cycle.
(define (normalize v ancestors)
  (cond
    [(or (eq? v 'null) (eq? v #t) (eq? v #f)) v]
    [(string? v) (if (immutable? v) v (string->immutable-string v))]
    [(real? v)
     (cond
       [(exact-integer? v) v]
       [(flonum? v)
        ;; NaN and the infinities have no JSON text; JSON.parse never yields -0 from "0", so a
        ;; -0.0 would not survive a round trip.
        (if (or (not (= v v)) (= v +inf.0) (= v -inf.0) (eqv? v -0.0)) invalid v)]
       [(exact? v) (exact->inexact v)]
       [else invalid])]
    [(null? v) v]
    [(pair? v)
     (if (list? v)
         (let loop ([rest v] [acc '()] [changed? #f])
           (cond
             [(null? rest) (if changed? (reverse acc) v)]
             [else
              (define member (normalize (car rest) ancestors))
              (if (eq? member invalid)
                  invalid
                  (loop (cdr rest) (cons member acc)
                        (or changed? (not (eq? member (car rest))))))]))
         invalid)]
    [(jobject? v)
     (let loop ([rest (jobject->alist v)] [acc '()] [changed? #f])
       (cond
         [(null? rest) (if changed? (make-jobject (reverse acc)) v)]
         [else
          (define member (normalize (cdar rest) ancestors))
          (if (eq? member invalid)
              invalid
              (loop (cdr rest) (cons (cons (caar rest) member) acc)
                    (or changed? (not (eq? member (cdar rest))))))]))]
    [(hash? v)
     (cond
       [(memq v ancestors) invalid]
       [(not (for/and ([k (in-hash-keys v)]) (object-key? k))) invalid]
       [(not (distinct-keys? v)) invalid]
       [(for/or ([member (in-hash-values v)]) (void? member)) invalid]
       [else
        (define inner (cons v ancestors))
        (let loop ([rest (jobject->alist v)] [acc '()])
          (cond
            [(null? rest) (make-jobject (reverse acc))]
            [else
             (define member (normalize (cdar rest) inner))
             (if (eq? member invalid)
                 invalid
                 (loop (cdr rest) (cons (cons (caar rest) member) acc)))]))])]
    [else invalid]))

;; dsh isJsonValue: whether v is a jvalue with no -0.0 in it.
(define (lossless-json? v)
  (not (eq? (normalize v '()) invalid)))

;; dsh snapshotJsonValue: #f when v is not lossless JSON; otherwise an equal value in which every
;; plain hash is a jobject (keys in symbol<? order), every mutable string an immutable copy and
;; every exact non-integer rational its flonum. A value already in that form is returned itself.
;; The JSON value #f also gives #f; a caller that must tell the two apart asks `lossless-json?`.
(define (snapshot-json v)
  (define normal (normalize v '()))
  (if (eq? normal invalid) #f normal))

;; ---------------------------------------------------------------------------------------------
;; Equality and exhaustiveness

;; dsh deepEqualJson: structural equality where object key order is ignored and array order is
;; not. It is cordis-data's strict `deep-equal?`.
(define (deep-equal-json? a b)
  (deep-equal? a b #:strict? #t))

;; dsh assertNever: marks an unreachable branch of a closed case analysis. Always raises
;; exn:fail with "unreachable variant[ in <context>]: <value>", the value written as JSON when
;; it is a jvalue and with `display` otherwise.
(define (assert-never value [context #f])
  (define rendered
    (if (jvalue? value)
        (jvalue->string value)
        (let ([out (open-output-string)])
          (display value out)
          (get-output-string out))))
  (raise (make-exn:fail
          (string->immutable-string
           (string-append "unreachable variant"
                          (if (and context (not (string=? context ""))) (string-append " in " context) "")
                          ": "
                          rendered))
          (current-continuation-marks))))

;; ---------------------------------------------------------------------------------------------
;; WeakMapWithValues: weak keys (compared with eq?) with a strongly held, ordered set of values.
;; Each value belongs to one key. Nothing is cleaned up automatically: a value stays in
;; `weak-map-values` until its association is removed or the map is cleared, even after its key
;; is collected.

(struct weak-map-with-values ([keys #:mutable] [values #:mutable] [next #:mutable]))

(define missing (string->uninterned-symbol "missing"))

(define (make-weak-map-with-values)
  (weak-map-with-values (make-weak-hasheq) (make-hasheq) 0))

(define (weak-map-ref m key [default #f])
  (define v (hash-ref (weak-map-with-values-keys m) key missing))
  (if (eq? v missing) default v))

(define (weak-map-has? m key)
  (not (eq? (hash-ref (weak-map-with-values-keys m) key missing) missing)))

(define (weak-map-set! m key value)
  (define keys (weak-map-with-values-keys m))
  (define values (weak-map-with-values-values m))
  (define previous (hash-ref keys key missing))
  (unless (eq? previous value)
    (unless (eq? previous missing) (hash-remove! values previous))
    (hash-set! keys key value)
    (unless (hash-has-key? values value)
      (hash-set! values value (weak-map-with-values-next m))
      (set-weak-map-with-values-next! m (add1 (weak-map-with-values-next m))))))

;; Removes one association and its value; returns whether one existed.
(define (weak-map-remove! m key)
  (define keys (weak-map-with-values-keys m))
  (define previous (hash-ref keys key missing))
  (cond
    [(eq? previous missing) #f]
    [else
     (hash-remove! keys key)
     (hash-remove! (weak-map-with-values-values m) previous)
     #t]))

(define (weak-map-clear! m)
  (set-weak-map-with-values-keys! m (make-weak-hasheq))
  (hash-clear! (weak-map-with-values-values m)))

;; The live values in insertion order.
(define (weak-map-values m)
  (map car
       (sort (hash->list (weak-map-with-values-values m)) < #:key cdr)))
