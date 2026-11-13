#lang racket/base
;; The lossless JSON domain check of dsh (`snapshotJsonValue` and `isJsonValue`).
;;
;; A value is lossless JSON when it is a jvalue of `cordis-data` and no number in it is -0.0.
;; `lossless-json?` tests that. `snapshot-json` also returns the value in normal form: every
;; plain hash becomes a jobject (keys in `symbol<?` order), every mutable string an immutable
;; copy, and every exact rational that is not an integer its flonum. A value that is already
;; normal is returned itself, so a second snapshot costs no allocation.
;;
;; `snapshot-json` returns #f for a value that is not lossless JSON, and also for the JSON
;; value #f. A caller that must tell the two apart asks `lossless-json?` first.
;; source: packages/util/values/src/index.ts

(require racket/contract/base
         cordis-data)

(provide
 (contract-out
  ;; True when the value is a jvalue with no -0.0 in it.
  [lossless-json? predicate/c]
  ;; The normal form of a lossless JSON value, or #f when the value is not lossless JSON.
  [snapshot-json (-> any/c any/c)]))

;; The result of a failed walk; distinct from every jvalue.
(define invalid (string->uninterned-symbol "invalid"))

;; A hash that holds the same key as a symbol and as a string has no single object form.
(define (hash-keys-distinct? h)
  (define seen (make-hasheq))
  (for/and ([key (in-hash-keys h)])
    (define sym (if (symbol? key) key (string->symbol key)))
    (begin0 (not (hash-ref seen sym #f))
            (hash-set! seen sym #t))))

(define (hash-key? key)
  (or (symbol? key) (string? key)))

;; normalize : any/c (listof hash?) -> any/c
;; Returns the normal form of `v`, `v` itself when nothing changed, or `invalid`. `ancestors`
;; holds the mutable hashes on the path from the root, the only containers that can form a
;; cycle.
(define (normalize v ancestors)
  (cond
    [(or (eq? v 'null) (eq? v #t) (eq? v #f)) v]
    [(string? v) (if (immutable? v) v (string->immutable-string v))]
    [(real? v)
     (cond
       [(exact-integer? v) v]
       [(flonum? v) (if (or (nan? v) (infinite? v) (eqv? v -0.0)) invalid v)]
       [(exact? v) (exact->inexact v)]
       [else invalid])]
    [(null? v) v]
    [(pair? v) (if (list? v) (normalize-list v ancestors) invalid)]
    [(jobject? v) (normalize-jobject v ancestors)]
    [(hash? v)
     (cond
       [(memq v ancestors) invalid]
       [(not (for/and ([key (in-hash-keys v)]) (hash-key? key))) invalid]
       [(not (hash-keys-distinct? v)) invalid]
       ;; `jobject->alist` raises for a hash that holds `(void)`.
       [(for/or ([value (in-hash-values v)]) (void? value)) invalid]
       [else (normalize-members (jobject->alist v) (cons v ancestors))])]
    [else invalid]))

(define (nan? v) (not (= v v)))
(define (infinite? v) (or (= v +inf.0) (= v -inf.0)))

;; Keeps the list itself when no member changed.
(define (normalize-list lst ancestors)
  (let loop ([rest lst] [acc '()] [changed? #f])
    (cond
      [(null? rest) (if changed? (reverse acc) lst)]
      [else
       (define member (normalize (car rest) ancestors))
       (if (eq? member invalid)
           invalid
           (loop (cdr rest) (cons member acc) (or changed? (not (eq? member (car rest))))))])))

;; Keeps the jobject itself when no member changed.
(define (normalize-jobject obj ancestors)
  (define members (jobject->alist obj))
  (let loop ([rest members] [acc '()] [changed? #f])
    (cond
      [(null? rest) (if changed? (make-jobject (reverse acc)) obj)]
      [else
       (define value (normalize (cdar rest) ancestors))
       (if (eq? value invalid)
           invalid
           (loop (cdr rest)
                 (cons (cons (caar rest) value) acc)
                 (or changed? (not (eq? value (cdar rest))))))])))

;; A hash always becomes a new jobject.
(define (normalize-members members ancestors)
  (let loop ([rest members] [acc '()])
    (cond
      [(null? rest) (make-jobject (reverse acc))]
      [else
       (define value (normalize (cdar rest) ancestors))
       (if (eq? value invalid)
           invalid
           (loop (cdr rest) (cons (cons (caar rest) value) acc)))])))

;; The same rules as `normalize`, without building the normal form.
(define (lossless? v ancestors)
  (cond
    [(or (eq? v 'null) (eq? v #t) (eq? v #f) (string? v) (null? v)) #t]
    [(real? v)
     (cond
       [(flonum? v) (not (or (nan? v) (infinite? v) (eqv? v -0.0)))]
       [else (exact? v)])]
    [(pair? v) (and (list? v) (for/and ([member (in-list v)]) (lossless? member ancestors)))]
    [(jobject? v) (for/and ([value (in-list (jvalues v))]) (lossless? value ancestors))]
    [(hash? v)
     (and (not (memq v ancestors))
          (for/and ([key (in-hash-keys v)]) (hash-key? key))
          (hash-keys-distinct? v)
          (let ([inner (cons v ancestors)])
            (for/and ([value (in-hash-values v)]) (lossless? value inner))))]
    [else #f]))

(define (lossless-json? v)
  (lossless? v '()))

(define (snapshot-json v)
  (define result (normalize v '()))
  (if (eq? result invalid) #f result))
