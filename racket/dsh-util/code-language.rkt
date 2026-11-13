#lang racket/base
;; dsh-util/code-language: the file-extension to highlight-language table shared by the code
;; preview, the diff review and the read tool's persisted `lang` hint.
;;
;; source: packages/util/code-language/src/index.ts
;;
;; Both tables are copied verbatim: the `lang` value is written into session logs, so a suffix
;; must keep the value recorded sessions already hold.

(require racket/contract/base
         racket/string
         "private/js.rkt")

(provide (contract-out
          [code-highlight-extensions (listof string?)]
          [language-for-path (-> string? (or/c string? #f))]
          [read-lang-hint-for-path (-> string? (or/c string? #f))]
          ;; Aliases under the names the wave 4 contracts use.
          [lang-from-path (-> string? (or/c string? #f))]))

;; source: LANGUAGE_EXTENSIONS, in declaration order
(define language-extensions
  '(("typescript" "ts" "tsx" "mts" "cts")
    ("javascript" "js" "jsx" "mjs" "cjs")
    ("shellscript" "sh" "bash" "zsh")
    ("fish" "fish")
    ("json" "json" "jsonc" "jsonl" "ndjson" "ipynb")
    ("csv" "csv")
    ("python" "py" "pyw" "pyi")
    ("ruby" "rb" "rake" "gemspec")
    ("go" "go")
    ("rust" "rs")
    ("java" "java")
    ("c" "c" "h")
    ("cpp" "cc" "cpp" "cxx" "hh" "hpp" "hxx")
    ("csharp" "cs")
    ("kotlin" "kt" "kts")
    ("swift" "swift")
    ("php" "php")
    ("yaml" "yaml" "yml")
    ("toml" "toml")
    ("ini" "ini" "conf" "cfg" "properties")
    ("dotenv" "env")
    ("log" "log")
    ("diff" "diff" "patch")
    ("http" "http")
    ("markdown" "md" "markdown")
    ("mdx" "mdx")
    ("rst" "rst")
    ("latex" "tex" "sty" "cls")
    ("bibtex" "bib")
    ("asciidoc" "adoc")
    ("html" "html" "htm" "xhtml")
    ("css" "css")
    ("scss" "scss")
    ("less" "less")
    ("sql" "sql")
    ("xml" "xml" "xsd" "xsl" "xslt" "plist" "svg")
    ("lua" "lua")
    ("bat" "bat" "cmd")
    ("powershell" "ps1" "psm1" "psd1")
    ("r" "r")
    ("julia" "jl")
    ("dart" "dart")
    ("scala" "scala")
    ("clojure" "clj" "cljs" "edn")
    ("erlang" "erl" "hrl")
    ("elixir" "ex" "exs")
    ("haskell" "hs")
    ("fsharp" "fs" "fsi" "fsx")
    ("vb" "vb")
    ("perl" "pl" "pm")
    ("verilog" "v")
    ("system-verilog" "sv" "svh")
    ("graphql" "graphql" "gql")
    ("proto" "proto")
    ("hcl" "tf" "tfvars" "hcl")
    ("nix" "nix")
    ("vue" "vue")
    ("svelte" "svelte")
    ("make" "makefile" "mk")
    ("cmake" "cmake")
    ("groovy" "gradle" "groovy")))

;; Lowercase extension -> canonical language id.
(define languages
  (for*/hash ([row (in-list language-extensions)]
              [extension (in-list (cdr row))])
    (values extension (car row))))

;; Every recognized filename suffix, once each, in table order.
(define code-highlight-extensions
  (for*/list ([row (in-list language-extensions)]
              [extension (in-list (cdr row))])
    extension))

;; source: READ_LANG_BY_EXTENSION
(define read-lang-by-extension
  (hash "tsx" "tsx" "jsx" "jsx" "tf" "tf" "tfvars" "tfvars" "gradle" "gradle"))

;; source: SHORT_BY_LANGUAGE
(define short-by-language
  (hash "typescript" "ts" "javascript" "js" "shellscript" "sh" "fish" "fish" "json" "json"
        "csv" "csv" "python" "py" "ruby" "rb" "go" "go" "rust" "rs" "java" "java" "c" "c"
        "cpp" "cpp" "csharp" "cs" "kotlin" "kotlin" "swift" "swift" "php" "php" "yaml" "yaml"
        "toml" "toml" "ini" "ini" "dotenv" "env" "log" "log" "diff" "diff" "http" "http"
        "markdown" "md" "mdx" "mdx" "rst" "rst" "latex" "tex" "bibtex" "bib" "asciidoc" "adoc"
        "html" "html" "css" "css" "scss" "scss" "less" "less" "sql" "sql" "xml" "xml"
        "lua" "lua" "bat" "bat" "powershell" "ps1" "r" "r" "julia" "jl" "dart" "dart"
        "scala" "scala" "clojure" "clj" "erlang" "erl" "elixir" "ex" "haskell" "hs"
        "fsharp" "fs" "vb" "vb" "perl" "pl" "verilog" "v" "system-verilog" "sv"
        "graphql" "graphql" "proto" "proto" "hcl" "hcl" "nix" "nix" "vue" "vue"
        "svelte" "svelte" "make" "make" "cmake" "cmake" "groovy" "groovy"))

;; The lowercased text after the last dot of the final path segment, or #f without a dot.
;; Both `/` and `\` separate segments; a leading dot still counts as the separator.
(define (extension-for-path path)
  (define slash (max (or (string-last-index-of path #\/) -1) (or (string-last-index-of path #\\) -1)))
  (define base (substring path (add1 slash)))
  (define dot (string-last-index-of base #\.))
  (and dot (string-downcase (substring base (add1 dot)))))

;; The canonical highlight language of a filename or path, or #f for an unrecognized or absent
;; suffix.
(define (language-for-path path)
  (define extension (extension-for-path path))
  (and extension (hash-ref languages extension #f)))

;; The `lang` hint the read tool persists for a path: the language's short name, or the suffix
;; itself where it names the file better (`tsx`, `jsx`, `tf`, `tfvars`, `gradle`). #f when the
;; table does not recognize the suffix.
(define (read-lang-hint-for-path path)
  (define extension (extension-for-path path))
  (define canonical (and extension (hash-ref languages extension #f)))
  (and canonical
       (or (hash-ref read-lang-by-extension extension #f)
           (hash-ref short-by-language canonical))))

(define lang-from-path read-lang-hint-for-path)
