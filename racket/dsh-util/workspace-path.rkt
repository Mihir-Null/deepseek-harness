#lang racket/base
;; dsh-util/workspace-path: workspace path display helpers and the `dsh-resource://file/...`
;; address grammar. Everything is string arithmetic: no filesystem is touched and both POSIX and
;; Windows spellings are handled on every host.
;;
;; source: packages/util/workspace-path/src/index.ts, src/file-address.ts

(require racket/contract/base
         racket/string
         racket/list
         "private/js.rkt"
         "private/url.rkt")

(provide (struct-out file-address)
         (contract-out
          [absolute-workspace-path? (-> string? boolean?)]
          [resolve-workspace-path (-> (or/c string? #f) string? string?)]
          [abbreviate-home-path (->* (string?) ((or/c string? #f)) string?)]
          [workspace-title-of (-> string? string?)]
          [path-parts-of (-> string? (values string? string?))]
          [relativize-to-cwd (-> string? (or/c string? #f) string?)]
          [file-address-for (-> string? (or/c string? #f) string? string?)]
          [session-file-address (-> string? string? string?)]
          [absolute-file-address (-> string? string?)]
          [parse-file-address (-> string? (or/c file-address? #f))]
          [file-media-url (-> string? string? (or/c string? #f))]))

;; A parsed file address. `scope` is 'session or 'absolute; `session-id` is #f for 'absolute.
(struct file-address (scope session-id path) #:transparent)

;; Whether a path uses a Windows drive or UNC prefix.
(define (windows-style-path? value)
  (or (regexp-match? #rx"^[A-Za-z]:[/\\\\]" value)
      (string-prefix? value "\\\\")))

;; Whether a path is absolute in either spelling the host accepts: POSIX, Windows drive, or UNC.
(define (absolute-workspace-path? path)
  (or (string-prefix? path "/") (windows-style-path? path)))

;; Joins a workspace-relative path onto the session workspace root; an absolute path, or a path
;; without a known root, is returned unchanged. Leading `./` segments are dropped.
(define (resolve-workspace-path cwd path)
  (cond
    [(absolute-workspace-path? path) path]
    [(or (not cwd) (string=? cwd "")) path]
    [else
     (define separator (if (and (windows-style-path? cwd) (string-contains? cwd "\\")) "\\" "/"))
     (define base (regexp-replace #rx"[/\\\\]+$" cwd ""))
     (define relative (regexp-replace #rx"^(?:[.]?[/\\\\])+" path ""))
     (string-append base separator relative)]))

;; `~` or `~/...` for the POSIX home and its descendants, otherwise the path unchanged.
(define (abbreviate-home-path path [home #f])
  (cond
    [(or (not home) (string=? home "")) path]
    [(or (windows-style-path? path) (windows-style-path? home)) path]
    [else
     (define root (regexp-replace #rx"/+$" home ""))
     (cond
       [(or (string=? root "") (string=? root "/")) path]
       [(string=? (regexp-replace #rx"/+$" path "") root) "~"]
       [(string-prefix? path (string-append root "/"))
        (string-append "~" (substring path (string-length root)))]
       [else path])]))

(define (last-separator s)
  (max (or (string-last-index-of s #\/) -1) (or (string-last-index-of s #\\) -1)))

;; The final non-empty segment of a workspace path; "" for a separator-only path.
(define (workspace-title-of path)
  (define trimmed (regexp-replace #rx"[/\\\\]+$" path ""))
  (substring trimmed (add1 (last-separator trimmed))))

;; Splits a path for display: (values directory name), the directory keeping its last separator.
;; A path with no separator, or a separator-only path, is all name.
(define (path-parts-of path)
  (define trimmed (regexp-replace #rx"[/\\\\]+$" path ""))
  (cond
    [(string=? trimmed "") (values "" path)]
    [else
     (define cut (add1 (last-separator trimmed)))
     (values (substring trimmed 0 cut) (substring trimmed cut))]))

;; Strips the workspace root from a workspace-rooted absolute path (display only).
(define (relativize-to-cwd text cwd)
  (cond
    [(or (not cwd) (string=? cwd "")) text]
    [else
     (define root (regexp-replace #rx"[/\\\\]+$" cwd ""))
     (if (or (string-prefix? text (string-append root "/"))
             (string-prefix? text (string-append root "\\")))
         (substring text (add1 (string-length root)))
         text)]))

;; ---------------------------------------------------------------------------------------------
;; File addresses
;; source: packages/util/workspace-path/src/file-address.ts

(define file-address-prefix "dsh-resource://file/")

(define (backslashes->slashes s) (string-replace s "\\" "/"))

;; Component-encodes one id or path segment, keeping `:` literal for drive letters.
(define (encode-segment segment)
  (regexp-replace* #rx"%3[Aa]" (encode-uri-component segment) ":"))

(define (encode-path path)
  (string-join (map encode-segment (string-split path "/" #:trim? #f)) "/"))

;; The address of a file read through one session:
;; dsh-resource://file/session/<sessionId>/<path>. Backslashes become `/` and leading `./`
;; prefixes are dropped.
(define (session-file-address session-id path)
  (define normalized (regexp-replace #rx"^(?:[.]/)+" (backslashes->slashes path) ""))
  (string-append file-address-prefix "session/" (encode-segment session-id) "/"
                 (encode-path normalized)))

;; The address of a file by its absolute path: dsh-resource://file/absolute/<path>, the leading
;; `/` dropped; a UNC path keeps one empty first segment.
(define (absolute-file-address path)
  (define normalized (backslashes->slashes path))
  (define unc? (string-prefix? normalized "//"))
  (define absolute (regexp-replace #rx"^/+" normalized ""))
  (string-append file-address-prefix "absolute/" (if unc? "/" "") (encode-path absolute)))

;; The address for a path as a caller holds it: a relative path, or an absolute path inside the
;; session workspace, becomes a path relative to it; any other absolute path is kept.
(define (file-address-for session-id cwd path)
  (define normalized (backslashes->slashes path))
  (cond
    [(not (absolute-workspace-path? normalized)) (session-file-address session-id normalized)]
    [else
     (define root (if cwd (regexp-replace #rx"/+$" (backslashes->slashes cwd) "") ""))
     (cond
       [(and (not (string=? root "")) (string=? normalized root))
        (session-file-address session-id "")]
       [(and (not (string=? root "")) (string-prefix? normalized (string-append root "/")))
        (session-file-address session-id (substring normalized (add1 (string-length root))))]
       [else (session-file-address session-id normalized)])]))

;; Reads a file address back into its parts without resolving `.` or `..`. A query or fragment
;; suffix is ignored. #f when the text is not a dsh-resource://file/ address in a known scope
;; with a path, or a segment is not validly percent-encoded.
(define (parse-file-address address)
  (and (string-prefix? address file-address-prefix)
       (let* ([end (for/first ([c (in-string address)] [i (in-naturals)]
                               #:when (or (char=? c #\?) (char=? c #\#)))
                     i)]
              [body (substring address (string-length file-address-prefix)
                               (or end (string-length address)))]
              [parts (string-split body "/" #:trim? #f)]
              [scope (car parts)]
              [rest (cdr parts)])
         (cond
           [(string=? scope "session")
            (and (pair? rest)
                 (not (string=? (car rest) ""))
                 (pair? (cdr rest))
                 (let ([id (decode-uri-component (car rest))]
                       [segments (map decode-uri-component (cdr rest))])
                   (and id
                        (andmap values segments)
                        (file-address 'session id (string-join segments "/")))))]
           [(string=? scope "absolute")
            ;; An empty first segment with more behind it is a UNC path's `//`.
            (define unc? (and (pair? rest) (string=? (car rest) "") (pair? (cdr rest))))
            (define segments (map decode-uri-component (if unc? (cdr rest) rest)))
            (cond
              [(or (null? segments) (not (andmap values segments)) (string=? (car segments) "")) #f]
              [unc? (file-address 'absolute #f (string-append "//" (string-join segments "/")))]
              [(regexp-match? #rx"^[A-Za-z]:$" (car segments))
               (file-address 'absolute #f (string-join segments "/"))]
              [else (file-address 'absolute #f (string-append "/" (string-join segments "/")))])]
           [else #f]))))

;; The authenticated file route for a decoded absolute native path:
;; <base>/api/file?path=<encoded path>, resolved against `base` as a URL reference. #f for a base
;; that is neither http(s) nor dsh-app://app/, a path that is not absolute, a UNC path, or a path
;; with a control character.
(define (file-media-url base path)
  (and (or (regexp-match? #rx"^https?:" base) (string-prefix? base "dsh-app://app/"))
       (absolute-workspace-path? path)
       (not (regexp-match? #rx"^[/\\\\][/\\\\]" path))
       (not (for/or ([c (in-string path)])
              (or (char<? c #\space) (char=? c #\rubout))))
       (let ([resolved (wurl-resolve (string-append "api/file?path=" (encode-uri-component path))
                                     base)])
         (and resolved (wurl-href resolved)))))
