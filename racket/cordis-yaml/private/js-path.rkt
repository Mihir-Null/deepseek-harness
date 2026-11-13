#lang racket/base
;; Provides Node's POSIX path algorithms on strings: `posix-normalize`, `posix-join`,
;; `posix-resolve`, `posix-dirname`, `posix-basename`, `posix-extname`, `posix-absolute?`.
;; source: Node.js lib/path.js (the `posix` object)
;;
;; None of them touches the file system.

(require racket/list
         racket/string)

(provide posix-normalize
         posix-join
         posix-resolve
         posix-dirname
         posix-basename
         posix-extname
         posix-absolute?)

(define (slash? c) (char=? c #\/))

;; Resolves "." and ".." segments and drops empty ones. `allow-above-root?` keeps leading ".."
;; segments, which a relative path may have.
(define (normalize-segments path allow-above-root?)
  (define kept
    (for/fold ([kept '()]) ([segment (in-list (string-split path "/" #:trim? #f))])
      (cond [(or (string=? segment "") (string=? segment ".")) kept]
            [(string=? segment "..")
             (cond [(and (pair? kept) (not (string=? (car kept) ".."))) (cdr kept)]
                   [allow-above-root? (cons ".." kept)]
                   [else kept])]
            [else (cons segment kept)])))
  (string-join (reverse kept) "/"))

;; posix-absolute? : string? -> boolean?
(define (posix-absolute? path)
  (and (positive? (string-length path)) (slash? (string-ref path 0))))

;; posix-normalize : string? -> string?
(define (posix-normalize path)
  (cond
    [(string=? path "") "."]
    [else
     (define absolute? (posix-absolute? path))
     (define trailing? (slash? (string-ref path (sub1 (string-length path)))))
     (define normalized (normalize-segments path (not absolute?)))
     (cond [(string=? normalized "")
            (cond [absolute? "/"] [trailing? "./"] [else "."])]
           [else
            (string-append (if absolute? "/" "") normalized (if trailing? "/" ""))])]))

;; posix-join : (listof string?) -> string?
(define (posix-join paths)
  (define non-empty (filter (lambda (path) (not (string=? path ""))) paths))
  (if (null? non-empty)
      "."
      (posix-normalize (string-join non-empty "/"))))

;; posix-resolve : (listof string?) string? -> string?
;; Resolves `paths` right to left until an absolute path is built; `cwd` is the directory a
;; relative result starts from.
(define (posix-resolve paths cwd)
  (define-values (resolved absolute?)
    (for/fold ([resolved ""] [absolute? #f])
              ([path (in-list (reverse (cons cwd paths)))]
               #:break absolute?
               #:unless (string=? path ""))
      (values (string-append path "/" resolved) (posix-absolute? path))))
  (define normalized (normalize-segments resolved (not absolute?)))
  (cond [absolute? (string-append "/" normalized)]
        [(string=? normalized "") "."]
        [else normalized]))

;; posix-dirname : string? -> string?
(define (posix-dirname path)
  (define len (string-length path))
  (cond
    [(zero? len) "."]
    [else
     (define has-root? (slash? (string-ref path 0)))
     ;; The index of the slash that ends the directory part, skipping trailing slashes.
     (define end
       (let loop ([i (sub1 len)] [matched-slash? #t])
         (cond [(< i 1) #f]
               [(slash? (string-ref path i)) (if matched-slash? (loop (sub1 i) #t) i)]
               [else (loop (sub1 i) #f)])))
     (cond [(not end) (if has-root? "/" ".")]
           [(and has-root? (= end 1)) "//"]
           [else (substring path 0 end)])]))

;; The start and end of the last path component, ignoring trailing slashes; end is #f when the
;; path holds only slashes.
(define (last-component path)
  (let loop ([i (sub1 (string-length path))] [end #f])
    (cond [(< i 0) (values 0 end)]
          [(slash? (string-ref path i)) (if end (values (add1 i) end) (loop (sub1 i) #f))]
          [else (loop (sub1 i) (or end (add1 i)))])))

;; posix-basename : string? [(or/c string? #f)] -> string?
(define (posix-basename path [suffix #f])
  (define-values (start end) (last-component path))
  (cond
    [(not end) ""]
    [else
     (define base (substring path start end))
     (cond
       [(and suffix
             (positive? (string-length suffix))
             (<= (string-length suffix) (string-length path)))
        (cond [(string=? suffix path) ""]
              ;; A component that is exactly the suffix is kept whole.
              [(and (> (string-length base) (string-length suffix))
                    (string-suffix? base suffix))
               (substring base 0 (- (string-length base) (string-length suffix)))]
              [else base])]
       [else base])]))

;; posix-extname : string? -> string?
(define (posix-extname path)
  (define-values (start end) (last-component path))
  (cond
    [(not end) ""]
    [else
     (define base (substring path start end))
     (define dot
       (for/last ([c (in-string base)] [i (in-naturals)] #:when (char=? c #\.)) i))
     (cond [(or (not dot) (zero? dot)) ""]
           ;; The component ".." has no extension.
           [(string=? base "..") ""]
           [else (substring base dot)])]))
