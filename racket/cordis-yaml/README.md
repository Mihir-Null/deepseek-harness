# cordis-yaml

Reads and writes the YAML dialect dsh uses for `cordis.yml`, patch files and snapshot manifests, and evaluates the `!!js` JavaScript expressions those files contain. An unmodified dsh profile or patch loads in the Racket harness through this package.

- `(require cordis-yaml)`: `yaml-read`, `yaml-read-all`, `yaml-write`, `yaml->string`, `exn:fail:yaml`. Mappings are `cordis-data` jobjects in document order, sequences are lists, and a `!!js` scalar is a `js-expr` node that the reader does not evaluate. The reader is js-yaml 4.3.2's loader with dsh's `entryListSchema`, function for function; the writer produces the text js-yaml's `dump` produces.
- `(require cordis-yaml/js-expr)`: `js-parse`, `js-eval`, `js-interpolate`, `make-js-env`, `gen:js-object`, `make-node-process-object`, `current-js-fallback`. The parser is a hand-written tokenizer and a precedence-climbing parser that returns a plain S-expression tree; the evaluator is a `match` over that tree. It implements a stated subset of JavaScript with JavaScript's semantics and raises `exn:fail:js-expr:unsupported` for anything else.

The interface is specified by the [cordis-yaml contract](../../docs/racket/contracts/cordis-yaml.md).

## Correspondence with dsh

| dsh | Here |
|---|---|
| `js-yaml` with `entryListSchema` in [vendor/include/src/index.ts](../../vendor/include/src/index.ts) | `cordis-yaml` |
| `evaluate`, `interpolate` and `isJsExpr` in [vendor/loader/src/config/utils.ts](../../vendor/loader/src/config/utils.ts) | `js-eval`, `js-interpolate`, `js-expr?` |
| the JavaScript engine and Node's `process`, `node:path`, `node:module`, `node:os`, `URL` | `cordis-yaml/js-expr`, for the subset the contract lists |

## Example

```racket
(require cordis-data cordis-yaml cordis-yaml/js-expr racket/list racket/match)

(define patch
  (yaml-read
   (string-append "- insert:\n"
                  "    id: hmr\n"
                  "    disabled: !!js \"!ctx.get('profileContext')\"\n"
                  "    config:\n"
                  "      sessions: !!js process.env.DSH_SESSIONS ?? dshHomePath('sessions')\n")
   #:source "cordis.patch.yml"))

(define disabled (jref* patch '(0 insert disabled)))
(js-expr-source disabled)               ; "!ctx.get('profileContext')"
(js-parse (js-expr-source disabled))
; '(unary ! (call (member (id "ctx") "get") (str "profileContext")))

;; The tree is data: which environment variables does the configuration read?
(define (env-reads node)
  (match node
    [`(member (member (id "process") "env") ,name) (list name)]
    [(list _ parts ...) (append* (map env-reads (filter pair? parts)))]
    [_ '()]))
(env-reads (js-parse (js-expr-source (jref* patch '(0 insert config sessions)))))  ; '("DSH_SESSIONS")

;; Evaluation: `ctx` is a host object, `dshHomePath` a name the context scope provides.
(define env
  (make-js-env
   (hash "ctx" (make-js-object (lambda (name) (void)) (lambda (name arguments) (void)))
         "process" (make-node-process-object #:env (hash) #:cwd "/work" #:platform "linux"))
   #:lookup (lambda (name failure)
              (if (equal? name "dshHomePath")
                  (lambda parts (string-append "/home/me/.dsh/" (car parts)))
                  (failure)))))
(js-eval disabled env)                               ; #t
(js-interpolate (jref* patch '(0 insert config)) env)
; #<jobject {"sessions":"/home/me/.dsh/sessions"}>

(yaml->string patch)                                 ; the text js-yaml's dump writes
```

## Layout

| Path | Holds |
|---|---|
| `main.rkt` | The `cordis-yaml` module: reader and writer entry points, conversions to dsh's `{"__jsExpr": ...}` form |
| `js-expr.rkt` | The `cordis-yaml/js-expr` module: every expression binding with its contract |
| `private/yaml-read.rkt` | The reader, a port of js-yaml's `lib/loader.js` |
| `private/yaml-write.rkt` | The writer, a port of js-yaml's `lib/dumper.js` |
| `private/yaml-scalar.rkt` | The null, boolean, integer and float types of the JSON schema |
| `private/yaml-error.rkt` | `exn:fail:yaml` and js-yaml's message with its source snippet |
| `private/expr.rkt` | The `js-expr` struct |
| `private/js-parse.rkt` | Tokenizer and parser; the tree and the table of node positions |
| `private/js-eval.rkt` | Evaluator, environments, fallback, `js-interpolate` |
| `private/js-value.rkt` | Conversions, equality, comparison and arithmetic with JavaScript's rules |
| `private/js-builtins.rkt` | Properties and methods of strings, arrays, numbers; the standard globals |
| `private/js-object.rkt` | `gen:js-object`, `make-js-object`, calling Racket procedures as functions |
| `private/js-url.rkt` | The WHATWG URL parser for the special schemes, and the `URL` object |
| `private/js-path.rkt` | Node's POSIX path algorithms |
| `private/js-process.rkt` | `make-node-process-object` |
| `private/js-error.rkt` | The `exn:fail:js-expr` family |
| `private/uri.rkt` | `encodeURI`, `decodeURI` and their component forms |

The package depends on `base` and `cordis-data`; the tests also use `rackunit-lib`.

## Tests

```sh
raco link -n cordis-yaml racket/cordis-yaml   # once, so the collection resolves
raco test racket/cordis-yaml
```

The suite needs neither Node nor a network.

- `tests/corpus-test.rkt` reads every `*.yml` file under `packages/`, `apps/` and `snapshots/` of this repository (736 files at the time of writing), checks that writing and reading gives the same values, compares the JSON and the dump text with js-yaml's by digest, and parses and evaluates every distinct `!!js` expression in them (106). It is skipped with a message outside the repository tree.
- `tests/js-yaml-table-test.rkt` compares the package with [tests/data/js-yaml-table.rktd](tests/data/js-yaml-table.rktd), a table of results from js-yaml 4.3.2 and Node 22: about 1,300 YAML texts with js-yaml's value or its error reason, position and message; about 2,500 values with js-yaml's dump text; about 2,850 expressions with the value or error name Node computed under four environments; texts Node rejects as `SyntaxError`; and JavaScript that must be reported as unsupported.
- The other test files pin each rule of the contract by hand: scalar resolution, quoting, block scalars, error positions, each language construct, each coercion, host objects and the `process` object.

Regenerate the table after changing the generator. js-yaml is taken from a scratch directory, because the repository has no `node_modules`; the seed is fixed, so the same Node installation writes the same file:

```sh
mkdir /tmp/js-yaml && (cd /tmp/js-yaml && npm install js-yaml@4.3.2)
node racket/cordis-yaml/tests/gen/gen-js-yaml-table.mjs --js-yaml /tmp/js-yaml
```

`tests/gen/` is left out of `raco test`. Its `fuzz.rkt` checks a table of any size, for example one with 30,000 mutated corpus files and 3,000 random values:

```sh
node racket/cordis-yaml/tests/gen/gen-js-yaml-table.mjs --js-yaml /tmp/js-yaml \
  --seed 5 --fuzz-load 30000 --random-dumps 3000 --out /tmp/fuzz.rktd
racket racket/cordis-yaml/tests/gen/fuzz.rkt /tmp/fuzz.rktd
```

## Limits

- The evaluator is a subset. Assignment, statements, `function`, classes, regular expressions, bitwise operators, `**`, destructuring and most of the standard library are reported as unsupported with the construct's name and position; `current-js-fallback` lets a host hand such an expression to Node.
- `node:path` is implemented with Node's POSIX algorithms only. Under `#:platform "win32"` it is unsupported.
- `URL` covers `http`, `https`, `ws`, `wss`, `ftp` and `file`. Other schemes, IPv6 hosts, hosts that need IDNA, and `searchParams` are unsupported.
- A jobject keeps the key order of the document. JavaScript moves keys that are array indexes (`"0"`, `"42"`) to the front, so js-yaml enumerates such a mapping in another order.
- Error columns and positions count characters where js-yaml counts UTF-16 code units; they differ on lines that hold characters above U+FFFF.
- Racket strings cannot hold a lone surrogate: a YAML escape of one is read as U+FFFD, and a JavaScript string operation that would cut a surrogate pair is unsupported.
- A recursive alias (`&a [*a]`) is an error; js-yaml builds a cyclic value.
- Three kinds of root scalar are written differently from js-yaml, because js-yaml does not read its own text back for them: a plain string that begins like the document end marker `...`, a string of line breaks only, and a multi-line string that starts with a space.
