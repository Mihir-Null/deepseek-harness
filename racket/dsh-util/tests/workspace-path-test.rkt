#lang racket/base
;; Tests for dsh-util/workspace-path. Mirrors packages/util/workspace-path/tests/index.spec.ts,
;; file-address.spec.ts and file-media-url.spec.ts.

(require rackunit
         racket/string
         dsh-util/workspace-path
         dsh-util/private/js)

;; Non-ASCII text for path cases, built from code points to keep this file ASCII.
(define cjk (string (integer->char #x6D4B) (integer->char #x8BD5)))

(test-case "addresses every path by session and keeps absolute paths outside the workspace"
  (check-equal? (file-address-for "s" "/w" "src/a.ts") "dsh-resource://file/session/s/src/a.ts")
  (check-equal? (file-address-for "s" #f "src/a.ts") "dsh-resource://file/session/s/src/a.ts")
  (check-equal? (file-address-for "s" "/w/" "/w/src/a.ts") "dsh-resource://file/session/s/src/a.ts")
  (check-equal? (file-address-for "s" "/w" "/w") "dsh-resource://file/session/s/")
  (check-equal? (file-address-for "s" "/w" "/work/a.ts") "dsh-resource://file/session/s//work/a.ts")
  (check-equal? (file-address-for "s" #f "/etc/hosts") "dsh-resource://file/session/s//etc/hosts")
  (check-equal? (file-address-for "s" "C:\\w" "C:\\w\\x.ts") "dsh-resource://file/session/s/x.ts")
  (check-equal? (file-address-for "s" "C:\\w" "D:\\x.ts") "dsh-resource://file/session/s/D:/x.ts")
  (check-equal? (file-address-for "s" #f "\\\\server\\share\\x.ts")
                "dsh-resource://file/session/s///server/share/x.ts")
  (check-equal? (file-address-for "s" "\\\\server\\share" "\\\\server\\share\\x.ts")
                "dsh-resource://file/session/s/x.ts"))

(test-case "round-trips a parent-relative address"
  (for ([cwd (list "/workspace" #f)])
    (define address (file-address-for "s" cwd "../outside/a.txt"))
    (check-equal? address "dsh-resource://file/session/s/../outside/a.txt")
    (check-equal? (parse-file-address address) (file-address 'session "s" "../outside/a.txt"))))

(test-case "classifies POSIX, Windows drive and UNC paths as absolute"
  (check-true (absolute-workspace-path? "/a/b"))
  (check-true (absolute-workspace-path? "C:\\x\\a.ts"))
  (check-true (absolute-workspace-path? "C:/x/a.ts"))
  (check-true (absolute-workspace-path? "\\\\server\\share"))
  (check-false (absolute-workspace-path? "src/a.ts"))
  (check-false (absolute-workspace-path? "")))

(test-case "resolves relative paths without changing absolute paths"
  (check-equal? (resolve-workspace-path "/w" "src/a.ts") "/w/src/a.ts")
  (check-equal? (resolve-workspace-path "/w" "././src/a.ts") "/w/src/a.ts")
  (check-equal? (resolve-workspace-path "C:\\w" ".\\src\\a.ts") "C:\\w\\src\\a.ts")
  (check-equal? (resolve-workspace-path "/w" "../a.ts") "/w/../a.ts")
  (check-equal? (resolve-workspace-path "/w/" "/abs/a.ts") "/abs/a.ts")
  (check-equal? (resolve-workspace-path #f "src/a.ts") "src/a.ts")
  (check-equal? (resolve-workspace-path "" "src/a.ts") "src/a.ts")
  (check-equal? (resolve-workspace-path "/w" "C:\\x\\a.ts") "C:\\x\\a.ts")
  (check-equal? (resolve-workspace-path "/w" "\\\\server\\share") "\\\\server\\share")
  (check-equal? (resolve-workspace-path "C:\\" "src\\a.ts") "C:\\src\\a.ts")
  (check-equal? (resolve-workspace-path "C:\\work\\" "src\\a.ts") "C:\\work\\src\\a.ts")
  (check-equal? (resolve-workspace-path "C:/work/" "src/a.ts") "C:/work/src/a.ts"))

(test-case "abbreviates only descendants of a POSIX home"
  (check-equal? (abbreviate-home-path "/Users/u" "/Users/u") "~")
  (check-equal? (abbreviate-home-path "/Users/u/" "/Users/u") "~")
  (check-equal? (abbreviate-home-path "/Users/u/Documents/project" "/Users/u") "~/Documents/project")
  (check-equal? (abbreviate-home-path "/Users/u2/a.ts" "/Users/u") "/Users/u2/a.ts")
  (check-equal? (abbreviate-home-path "/Users/u/a.ts") "/Users/u/a.ts")
  (check-equal? (abbreviate-home-path "/Users/u/a.ts" "") "/Users/u/a.ts")
  (check-equal? (abbreviate-home-path "/etc/hosts" "/") "/etc/hosts")
  (check-equal? (abbreviate-home-path "C:\\Users\\u\\project" "C:\\Users\\u") "C:\\Users\\u\\project")
  (check-equal? (abbreviate-home-path "\\\\server\\share\\u" "\\\\server\\share\\u")
                "\\\\server\\share\\u"))

(test-case "reads the final path segment on both path styles"
  (check-equal? (workspace-title-of "/work/project/") "project")
  (check-equal? (workspace-title-of "C:\\work\\project\\") "project")
  (check-equal? (workspace-title-of "/") ""))

(define (parts path) (call-with-values (lambda () (path-parts-of path)) list))

(test-case "splits a path for display after the last separator of either kind"
  (check-equal? (parts "/work/project/notes.md") '("/work/project/" "notes.md"))
  (check-equal? (parts "C:\\work\\project\\notes.md") '("C:\\work\\project\\" "notes.md"))
  (check-equal? (parts "\\\\host\\share/notes.md") '("\\\\host\\share/" "notes.md"))
  (check-equal? (parts "/work/project/") '("/work/" "project"))
  (check-equal? (parts "notes.md") '("" "notes.md"))
  (check-equal? (parts "/") '("" "/")))

(test-case "displays a path relative to its workspace only within that workspace"
  (for ([row (list '("/work/report.txt" "/work" "report.txt")
                   '("/work/reports/result.pdf" "/work/" "reports/result.pdf")
                   '("/work-other/report.txt" "/work" "/work-other/report.txt")
                   '("/other/report.txt" "/work" "/other/report.txt")
                   '("report.txt" "/work" "report.txt")
                   '("/work/report.txt" #f "/work/report.txt")
                   '("/work/report.txt" "" "/work/report.txt")
                   '("/report.txt" "/" "report.txt")
                   '("C:\\work\\reports\\result.pdf" "C:\\work" "reports\\result.pdf")
                   '("\\\\server\\share\\report.txt" "\\\\server\\share" "report.txt"))])
    (check-equal? (relativize-to-cwd (car row) (cadr row)) (caddr row))))

(test-case "round-trips a session-relative path with encoded segments"
  (define address (session-file-address "s 1" "w/a b#c?.txt"))
  (check-equal? address "dsh-resource://file/session/s%201/w/a%20b%23c%3F.txt")
  (check-equal? (parse-file-address address) (file-address 'session "s 1" "w/a b#c?.txt")))

(test-case "drops a leading ./ and names the root with an empty path"
  (check-equal? (session-file-address "s" "./src/a.ts") "dsh-resource://file/session/s/src/a.ts")
  (check-equal? (session-file-address "s" "././../outside/a.txt")
                "dsh-resource://file/session/s/../outside/a.txt")
  (check-equal? (session-file-address "s" "src\\a.ts") "dsh-resource://file/session/s/src/a.ts")
  (check-equal? (session-file-address "s" "") "dsh-resource://file/session/s/")
  (check-equal? (parse-file-address "dsh-resource://file/session/s/") (file-address 'session "s" "")))

(test-case "round-trips absolute paths in a session address"
  (for ([row '(("/etc/hosts" "/etc/hosts" "dsh-resource://file/session/s//etc/hosts")
               ("/" "/" "dsh-resource://file/session/s//")
               ("C:\\w\\x.ts" "C:/w/x.ts" "dsh-resource://file/session/s/C:/w/x.ts")
               ("\\\\server\\share\\x.ts" "//server/share/x.ts"
                                          "dsh-resource://file/session/s///server/share/x.ts")
               ("/a b#c?%.txt" "/a b#c?%.txt" "dsh-resource://file/session/s//a%20b%23c%3F%25.txt"))])
    (define address (session-file-address "s" (car row)))
    (check-equal? address (caddr row))
    (check-equal? (parse-file-address address) (file-address 'session "s" (cadr row)))))

(test-case "keeps unresolved dot segments"
  (for ([path '("../outside/a.txt" "dir/../outside/a.txt" "dir/./a.txt" "/workspace/../outside/a.txt"
                "C:/workspace/../outside/a.txt" "//server/share/workspace/../outside/a.txt")])
    (check-equal? (parse-file-address (session-file-address "s 1" path))
                  (file-address 'session "s 1" path)))
  (for ([path '("/workspace/../outside/a.txt" "C:/workspace/../outside/a.txt"
                "//server/share/workspace/../outside/a.txt")])
    (check-equal? (parse-file-address (absolute-file-address path))
                  (file-address 'absolute #f path))))

(test-case "decodes each segment once without resolving dot segments"
  (for ([row '(("./a.txt" "./a.txt") ("%2e%2E/outside/a.txt" "../outside/a.txt")
               ("dir/%2E/a.txt" "dir/./a.txt") ("%252e%252e/a.txt" "%2e%2e/a.txt")
               ("a%2Fb%5Cc.txt" "a/b\\c.txt"))])
    (check-equal? (parse-file-address (string-append "dsh-resource://file/session/s%2F1/" (car row)))
                  (file-address 'session "s/1" (cadr row)))))

(test-case "ignores a literal query or fragment suffix"
  (for ([suffix '("?download=1#section" "#section?download=1" "?ignored=%E0%A4%A" "#ignored=%ZZ")])
    (check-equal? (parse-file-address
                   (string-append "dsh-resource://file/session/s/dir/../a%3Fb%23c%25.txt" suffix))
                  (file-address 'session "s" "dir/../a?b#c%.txt"))
    (check-equal? (parse-file-address
                   (string-append "dsh-resource://file/absolute/workspace/../a%3Fb%23c%25.txt" suffix))
                  (file-address 'absolute #f "/workspace/../a?b#c%.txt"))))

(test-case "round-trips absolute addresses"
  (check-equal? (absolute-file-address "/home/me/notes.md")
                "dsh-resource://file/absolute/home/me/notes.md")
  (check-equal? (parse-file-address "dsh-resource://file/absolute/home/me/notes.md")
                (file-address 'absolute #f "/home/me/notes.md"))
  (check-equal? (absolute-file-address "C:\\w\\x.ts") "dsh-resource://file/absolute/C:/w/x.ts")
  (check-equal? (parse-file-address "dsh-resource://file/absolute/C:/w/x.ts")
                (file-address 'absolute #f "C:/w/x.ts"))
  (check-equal? (absolute-file-address "\\\\server\\share\\x.ts")
                "dsh-resource://file/absolute//server/share/x.ts")
  (check-equal? (parse-file-address "dsh-resource://file/absolute//server/share/x.ts")
                (file-address 'absolute #f "//server/share/x.ts")))

(test-case "decodes either spelling of a path segment"
  (check-equal? (file-address-path (parse-file-address "dsh-resource://file/session/s/w/a+b.txt"))
                "w/a+b.txt")
  (check-equal? (file-address-path (parse-file-address "dsh-resource://file/session/s/w/a%2Bb.txt"))
                "w/a+b.txt")
  (check-equal? (file-address-path (parse-file-address "dsh-resource://file/absolute/w/a%2Bb.txt"))
                "/w/a+b.txt"))

(test-case "rejects text that is not a file address"
  (for ([address '("dsh-resource://terminal/session/s/1"
                   "dsh-resource://File/session/s/w/x.ts"
                   "DSH-RESOURCE://file/session/s/w/x.ts"
                   "dsh-resource://file/shared/s/w/x"
                   "file://sessions/s/w/x.ts"
                   "file:///w/x.ts"
                   "dsh-resource://file/session/s"
                   "dsh-resource://file/session"
                   "dsh-resource://file/session//a.txt"
                   "dsh-resource://file/absolute"
                   "dsh-resource://file/absolute/"
                   "dsh-resource://file/absolute//"
                   "dsh-resource://file"
                   "sidebar://files"
                   "notes.txt"
                   "dsh-resource://file/session/s/%E0%A4%A"
                   "dsh-resource://file/session/%/a.txt"
                   "dsh-resource://file/absolute/a%ZZ.txt")])
    (check-false (parse-file-address address) address)))

;; The decoded `path` query parameter of a file route URL.
(define (path-parameter url)
  (decode-uri-component (cadr (regexp-match #rx"[?]path=(.*)$" url))))

(test-case "the file route preserves the decoded native path under a mounted application"
  (for ([path (list (string-append "/work/" cjk " file#100%.png")
                    (string-append "C:\\work\\" cjk " file.png"))])
    (define url (file-media-url "https://host/tools/dsh/" path))
    (check-true (string-prefix? url "https://host/tools/dsh/api/file?path="))
    (check-equal? (path-parameter url) path)
    (for ([base '("dsh-app://app/" "dsh-app://app/index.html")])
      (define app-url (file-media-url base path))
      (check-equal? (car (string-split app-url "?")) "dsh-app://app/api/file")
      (check-equal? (path-parameter app-url) path))))

(test-case "the file route rejects a non-local or invalid path and an unsupported base"
  (for ([path (list "image.png" "//host/image.png" "\\\\host\\image.png"
                    (string #\/ #\w (integer->char 0) #\. #\p) "/work/\n.png")])
    (check-false (file-media-url "https://host/" path)))
  (for ([base '("file:///app/" "dsh-app://shell/" "dsh-app://app.example/" "dsh-app://app:80/"
                "dsh-app://user@app/" "dsh-app://app@other/" "about:blank")])
    (check-false (file-media-url base "/work/image.png") base)))
