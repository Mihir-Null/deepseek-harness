#lang racket/base
;; Tests for dsh-util/code-language. Mirrors
;; packages/util/code-language/tests/code-language.spec.ts.

(require rackunit
         racket/list
         dsh-util/code-language)

(test-case "resolves extensions to canonical languages"
  (for ([row '(("build.bat" "bat") ("build.cmd" "bat") ("deploy.ps1" "powershell")
               ("module.psm1" "powershell") ("data.psd1" "powershell") ("config.fish" "fish")
               ("app.properties" "ini") ("app.conf" "ini") ("app.cfg" "ini")
               (".env" "dotenv") ("server.log" "log")
               ("change.diff" "diff") ("fix.patch" "diff") ("api.http" "http")
               ("notebook.ipynb" "json") ("table.csv" "csv")
               ("guide.rst" "rst") ("paper.tex" "latex") ("style.sty" "latex")
               ("doc.cls" "latex") ("refs.bib" "bibtex") ("Info.plist" "xml")
               ("logo.svg" "xml") ("manual.adoc" "asciidoc")
               ("analysis.r" "r") ("model.jl" "julia") ("main.dart" "dart")
               ("Main.scala" "scala") ("core.clj" "clojure") ("ui.cljs" "clojure")
               ("data.edn" "clojure") ("app.erl" "erlang") ("app.hrl" "erlang")
               ("app.ex" "elixir") ("app.exs" "elixir") ("Main.hs" "haskell")
               ("Types.fs" "fsharp") ("Types.fsi" "fsharp") ("script.fsx" "fsharp")
               ("Form.vb" "vb") ("script.pl" "perl") ("Module.pm" "perl")
               ("top.v" "verilog") ("top.sv" "system-verilog") ("defs.svh" "system-verilog")
               ("schema.graphql" "graphql") ("query.gql" "graphql") ("message.proto" "proto")
               ("main.tf" "hcl") ("terraform.tfvars" "hcl") ("stack.hcl" "hcl")
               ("build.groovy" "groovy") ("flake.nix" "nix") ("App.vue" "vue")
               ("App.svelte" "svelte") ("Makefile" #f) ("build.mk" "make")
               ("CMakeLists.cmake" "cmake") ("build.gradle" "groovy"))])
    (check-equal? (language-for-path (car row)) (cadr row) (car row))))

(test-case "resolves the extensions the preview and read tables agree on"
  (check-equal? (language-for-path "src/a.ts") "typescript")
  (check-equal? (language-for-path "src/a.TSX") "typescript")
  (check-equal? (language-for-path "/abs/module.mjs") "javascript")
  (check-equal? (language-for-path "conf.yml") "yaml")
  (check-equal? (language-for-path "README.md") "markdown")
  (check-equal? (language-for-path "C:\\src\\main.rs") "rust")
  (for ([extension '("jsonl" "ndjson" "pyw" "pyi" "rake" "gemspec" "hh" "hxx" "kts" "xhtml"
                     "xsd" "xsl" "xslt")])
    (check-not-false (language-for-path (string-append "file." extension)) extension)))

(test-case "is case-insensitive and accepts Windows separators"
  (check-equal? (language-for-path "C:\\path\\X.PS1") "powershell")
  (check-equal? (language-for-path "C:\\Proj\\Build.CMD") "bat")
  (check-equal? (language-for-path "dir\\sub\\Main.SCALA") "scala"))

(test-case "reads the suffix after the last path segment and last dot"
  (check-false (language-for-path "a.py.bak"))
  (check-false (language-for-path "archive.tar.gz"))
  (check-false (language-for-path "/dir.py/plain"))
  (check-false (language-for-path "dir.ts/README")))

(test-case "returns #f for a dotfile, an extensionless name, a trailing dot and unknown suffixes"
  (for ([path '(".gitignore" "/etc/hosts" "trailingdot." "data.unknownext" "foo.constructor"
                "foo.__proto__" "foo.toString" "foo.hasOwnProperty" "table.tsv"
                "secret.pem" "secret.crt" "secret.key" "secret.cer" "secret.lock")])
    (check-false (language-for-path path) path)
    (check-false (read-lang-hint-for-path path) path)))

(test-case "keeps the read card short hints recorded sessions already hold"
  (for ([row '(("src/a.ts" "ts") ("src/a.tsx" "tsx") ("src/a.mts" "ts") ("src/a.cts" "ts")
               ("src/a.js" "js") ("src/a.jsx" "jsx") ("src/a.mjs" "js") ("src/a.cjs" "js")
               ("src/a.jsonc" "json") ("src/a.cc" "cpp") ("src/a.hpp" "cpp") ("src/a.sh" "sh")
               ("src/a.kt" "kotlin") ("README.md" "md") ("README.markdown" "md")
               ("page.htm" "html")
               ("build.ps1" "ps1") ("table.csv" "csv") (".env" "env") ("infra.tf" "tf")
               ("paper.tex" "tex") ("server.log" "log") ("message.proto" "proto")
               ("nomad.hcl" "hcl") ("main.tf" "tf") ("terraform.tfvars" "tfvars")
               ("build.gradle" "gradle") ("build.groovy" "groovy"))])
    (check-equal? (read-lang-hint-for-path (car row)) (cadr row) (car row))
    (check-equal? (lang-from-path (car row)) (cadr row))))

(test-case "persists a short id for every suffix"
  (define allowed
    '("ts" "js" "sh" "fish" "json" "csv" "py" "rb" "go" "rs" "java" "c" "cpp" "cs" "kotlin"
      "swift" "php" "yaml" "toml" "ini" "env" "log" "diff" "http" "md" "mdx" "rst" "tex" "bib"
      "adoc" "html" "css" "scss" "less" "sql" "xml" "lua" "bat" "ps1" "r" "jl" "dart" "scala"
      "clj" "erl" "ex" "hs" "fs" "vb" "pl" "v" "sv" "graphql" "proto" "hcl" "nix" "vue" "svelte"
      "make" "cmake" "groovy" "tsx" "jsx" "tf" "tfvars" "gradle"))
  (for ([extension (in-list code-highlight-extensions)])
    (define hint (read-lang-hint-for-path (string-append "file." extension)))
    (check-not-false (member hint allowed) extension)
    (check-not-false (language-for-path (string-append "file." extension)) extension)))

(test-case "lists every recognized suffix exactly once"
  (check-equal? (length (remove-duplicates code-highlight-extensions))
                (length code-highlight-extensions))
  (check-true (> (length code-highlight-extensions) 100))
  (check-equal? (take code-highlight-extensions 5) '("ts" "tsx" "mts" "cts" "js")))
