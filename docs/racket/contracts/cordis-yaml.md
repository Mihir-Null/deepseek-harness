# Interface contract: `cordis-yaml`

Reads and writes the YAML dialect dsh uses for `cordis.yml`, patch files and snapshot manifests, and evaluates the `!!js` JavaScript expressions those files contain. An unmodified dsh profile or patch must load in the Racket harness, so the reader follows js-yaml 4.3.2 (the version dsh pins) with dsh's `entryListSchema`, and the evaluator follows JavaScript for a stated subset and fails loudly outside it.

Package `racket/cordis-yaml/`, collection `cordis-yaml`, `(define deps '("base" "cordis-data"))`, `(define build-deps '("rackunit-lib"))`. Sources of behaviour: `vendor/include/src/index.ts` (the schema), `vendor/loader/src/config/utils.ts` (evaluation), js-yaml 4.3.2 `lib/loader.js` and `lib/dumper.js`. When this document and those sources disagree about what a file means, the sources are right and this document has a defect.

## 1. Modules

| Module | Provides |
|---|---|
| `cordis-yaml` (`main.rkt`) | section 2: the reader, the writer, `exn:fail:yaml`, and the `js-expr` bindings of section 3 |
| `cordis-yaml/js-expr` | sections 3 to 6: expression nodes, the parser and its AST, the evaluator, environments, host objects, the Node `process` object |

Internal modules live under `private/`.

## 2. YAML (`cordis-yaml`)

```racket
(yaml-read in #:source [source #f] #:schema [schema 'entry-list]) -> any/c
(yaml-read-all in #:source [source #f] #:schema [schema 'entry-list]) -> list?
(yaml-write v [out (current-output-port)] #:line-width [line-width 80]) -> void?
(yaml->string v #:line-width [line-width 80]) -> string?
(yaml-value? v) -> boolean?                    ; deep check of what the writer accepts
(yaml-value->jvalue v) -> any/c                ; every js-expr becomes the object {"__jsExpr": source}
(jvalue->yaml-value v) -> any/c                ; every object with a string "__jsExpr" member becomes a js-expr
(struct exn:fail:yaml exn:fail (reason source line column position))
```

`in` is a string, a byte string or an input port. Bytes and ports are read to the end and decoded as UTF-8 the way Node's `readFile(path, 'utf8')` does (an invalid sequence becomes U+FFFD). `source` names the input in error messages and in the `srcloc` of expression nodes; it defaults to the port's `object-name` for a port and to `#f` otherwise.

### 2.1 Values

| YAML node | Racket value |
|---|---|
| mapping | `jobject`; keys are symbols in document order |
| sequence | list |
| string scalar | immutable string |
| integer scalar | exact integer |
| float scalar | flonum, including `+inf.0`, `-inf.0`, `+nan.0` and `-0.0` |
| boolean scalar | `#t`, `#f` |
| null scalar, empty node | `'null` |
| `!!js` scalar | `js-expr` (section 3); the reader never evaluates it |

`yaml-read` returns the single document. An input with no document (empty, or spaces only) returns `(void)`, as js-yaml's `load` returns `undefined`; an input that holds only comments or line breaks is one empty document and returns `'null`. More than one document raises `exn:fail:yaml` with reason `expected a single document in the stream, but found more`. `yaml-read-all` returns the list of documents.

`+inf.0`, `-inf.0` and `+nan.0` are not jvalues (ADR 0006); they appear only when a file writes `.inf` or `.nan`.

### 2.2 What the reader accepts

The reader is js-yaml's loader, function for function, so it accepts and rejects the same texts:

- block and flow mappings and sequences, including compact nested forms (`- - a`, `- k: v`), explicit keys (`? k`), single-pair mappings inside flow sequences, and a block sequence at its parent mapping's indentation;
- plain scalars (multi-line plain scalars fold), single-quoted scalars (`''` escape), double-quoted scalars with the escapes `\0 \a \b \t \n \v \f \r \e \" \/ \\ \N \_ \L \P`, a backslash before a space or a tab, a backslash at a line end, `\xHH`, `\uHHHH`, `\UHHHHHHHH`;
- literal (`|`) and folded (`>`) block scalars with the chomping indicators `+` and `-` and an explicit indentation digit, in either order;
- comments, a byte order mark, CRLF and CR line ends, the document markers `---` and `...`, the directives `%YAML` and `%TAG`;
- anchors and aliases: an alias yields the anchored value itself (the two are `eq?`);
- the tags `!!str`, `!!seq`, `!!map`, `!!null`, `!!bool`, `!!int`, `!!float`, `!!js`, their verbatim forms (`!<tag:yaml.org,2002:str>`), and the non-specific tag `!`, which keeps a scalar a string.

Plain scalars resolve by js-yaml's JSON schema rules, in this order; anything else is a string:

| Type | Texts |
|---|---|
| null | `~`, `null`, `Null`, `NULL` |
| boolean | `true`, `True`, `TRUE`, `false`, `False`, `FALSE` |
| integer | optional sign, then decimal digits (leading zeros allowed: `012` is 12), `0x` hex digits, `0o` octal digits or `0b` binary digits; `-0` is 0 |
| float | `[-+]?digits[.digits][e[-+]digits]`, `.digits[e[-+]digits]`, `[-+]?.inf`, `.nan` (also `.Inf`, `.INF`, `.NaN`, `.NAN`) |

`yes`, `no`, `on`, `off`, timestamps, `1_000`, `0o` without digits and `-.5` are strings. An integer or float too large for a double is a string, as in js-yaml. Quoted and block scalars are strings unless tagged. Merge keys are not part of the dsh schema: `<<` is an ordinary key.

A mapping key is converted to a string the way JavaScript's `String(key)` does (`1: a` has the key `"1"`, `null: a` the key `"null"`, `[a, b]: c` the key `"a,b"`, a mapping key `"[object Object]"`). A duplicated key raises `duplicated mapping key`.

`!!js` is a scalar tag: `!!js` on a collection, and `!!js` with no scalar after it, raise `exn:fail:yaml`. The source of the expression node is the scalar's content after YAML unquoting or block-scalar folding. With `#:schema 'json` the tag `!!js` is unknown and raises, as with js-yaml's `JSON_SCHEMA`; everything else is the same.

### 2.3 Errors

A syntax error raises `exn:fail:yaml`. `reason` is js-yaml's reason text (`bad indentation of a mapping entry`, `duplicated mapping key`, `unknown tag !<tag:yaml.org,2002:foo>`, ...). `line` and `column` are 1-based, as js-yaml prints them; `position` is the 0-based character offset; all three are `#f` for the one error that has no position (more than one document). `source` is the `#:source` name. The message is js-yaml's message: `reason (line:column)`, or `reason in "source" (line:column)` when there is a source name, then a blank line and js-yaml's source snippet with a caret.

### 2.4 The writer

`yaml-write` and `yaml->string` produce the text of `yaml.dump(value, { schema: entryListSchema, noRefs: true, lineWidth })`: block style, two spaces per level, a sequence under a mapping key indented by two, `- ` items compacted (`- id: a`), empty collections as `[]` and `{}`, and a final newline.

- Accepted values: jvalues, `js-expr`, the flonums `+inf.0`, `-inf.0`, `+nan.0`, and a hash wherever an object may appear (read as `cordis-data` reads it). Anything else, `(void)` included, raises `exn:fail:contract` that names the path of the offending value.
- Strings are plain when js-yaml would write them plain; single-quoted when they would read back as another type (`'true'`, `'12'`, `'null'`), are empty, start with an indicator, contain `: ` or ` #`, or are one of the YAML 1.1 booleans (`'yes'`, `'on'`, ...); double-quoted with escapes when they hold a character that cannot be written literally; literal block scalars (`|`, `|-`, `|+`, with an indentation digit when the text starts with a space) when they contain a line break; folded block scalars (`>`) when a line is longer than the line width and can be folded. Keys are never block scalars.
- `line-width` is a positive integer, or `#f` for no limit (js-yaml's `lineWidth: -1`). As in js-yaml the width available to a scalar is `max(min(line-width, 40), line-width - indentation)`.
- Numbers: an integer-valued number is written in JavaScript's `String(n)` form; other flonums as `String(n)`, with `.inf`, `-.inf`, `.nan`, `-0.0` for the special values.
- A `js-expr` is written as `!!js` followed by its source as a scalar, styled as a string would be. A jobject with a string `__jsExpr` member is an expression node in dsh's representation and is written the same way.
- Objects are written in their key order. A key longer than 1024 UTF-16 units is written in the explicit `? key` form.
- Anchors and aliases are never written: values are immutable and sharing carries no meaning.

Guarantees: `(yaml-read (yaml->string v))` is `equal?` to `v` for every value the reader can produce, except that a number may come back in the other exactness (`1.0` is written `1` and read as `1`; an exact integer beyond 2^53 is written as the nearest double). js-yaml with `entryListSchema` loads every text the writer produces to the same data.

### 2.5 Differences from js-yaml

- Key order: a jobject keeps document order. JavaScript moves keys that are array indexes (`"0"`, `"42"`) to the front.
- Recursive aliases (`&a [*a]`) raise `exn:fail:yaml`; js-yaml builds a cyclic object.
- A lone surrogate escape (`"\ud800"`) becomes U+FFFD; an escaped pair becomes the one character. An escape above U+10FFFF raises.
- Integers of any size stay exact. Columns and widths count characters; js-yaml counts UTF-16 units, so they differ only on lines that hold characters above U+FFFF (the writer's width arithmetic does count UTF-16 units).
- The loader option `maxDepth` keeps its default of 100 nested nodes; deeper input raises as in js-yaml.

## 3. Expression nodes (`cordis-yaml/js-expr`, also exported by `cordis-yaml`)

```racket
(js-expr? v) -> boolean?
(make-js-expr source [srcloc #f]) -> js-expr?   ; source : string?
(js-expr-source e) -> string?
(js-expr-srcloc e) -> (or/c srcloc? #f)         ; source name, 1-based line, 0-based column, 1-based position, span #f
```

A `js-expr` is an opaque immutable value. Two are `equal?` when their sources are `string=?`; the location does not take part. It prints as `#<js-expr SOURCE>`. The location is where the scalar's tag starts in the YAML text.

## 4. Parsing (`cordis-yaml/js-expr`)

```racket
(js-parse str) -> list?        ; the AST below; raises exn:fail:js-expr:syntax or exn:fail:js-expr:unsupported
```

The parser is a hand-written tokenizer and a precedence-climbing parser. The AST is plain quoted data: lists whose first element is a symbol, with strings, numbers and booleans as leaves. It can be printed, compared with `equal?`, and taken apart with `racket/match`.

```
expr  = (num N)                         ; N: exact integer when the literal is integral and at most 2^53, else flonum
      | (str S)
      | (template PART ...)             ; PART: string (cooked text) or expr
      | (bool B) | (null) | (undefined)
      | (id NAME)
      | (array ELEM ...)                ; ELEM: expr or (spread expr)
      | (object PROP ...)               ; PROP: (prop NAME expr), (computed expr expr) or (spread expr)
      | (member expr NAME)              ; a.b
      | (index expr expr)               ; a[b]
      | (call expr ARG ...)             ; ARG: expr or (spread expr)
      | (new expr ARG ...)
      | (opt-member expr NAME)          ; a?.b
      | (opt-index expr expr)           ; a?.[b]
      | (opt-call expr ARG ...)         ; a?.(b)
      | (chain expr)                    ; wraps a member and call sequence that contains an optional link
      | (unary OP expr)                 ; OP: ! - + typeof void
      | (binary OP expr expr)           ; OP: + - * / % < <= > >= == != === !==
      | (and expr expr) | (or expr expr) | (coalesce expr expr)
      | (if expr expr expr)             ; a ? b : c
      | (arrow (NAME ...) expr)
```

`NAME` and `S` are strings, `OP` is a symbol. Examples: `process.platform` parses to `(member (id "process") "platform")`; `ctx.get('profileContext')?.name !== 'desktop'` to `(binary !== (chain (opt-member (call (member (id "ctx") "get") (str "profileContext")) "name")) (str "desktop"))`. `(chain e)` marks how far a short circuit reaches: when the value before a `?.` inside `e` is `null` or `undefined`, the whole of `e` is `undefined`. An empty source parses to `(undefined)`, the value JavaScript's `eval('')` gives.

Syntax covered: decimal, hex, octal and binary number literals with `_` separators; single- and double-quoted strings and template literals with the escapes `\n \t \r \b \f \v \0 \' \" \\ \xHH \uHHHH \u{H...}` and line continuations; `true`, `false`, `null`, `undefined`; identifiers; array literals and object literals (identifier, string and number keys, shorthand, computed keys, spread, trailing commas); member access, computed access, optional chaining; calls with spread; `new`; the operators listed in the AST; the conditional operator; parentheses; arrow functions with identifier parameters and an expression body; `//` and `/* */` comments.

Everything else that is JavaScript raises `exn:fail:js-expr:unsupported` with the name of the construct and its position: assignment and update operators, the comma operator, statements and semicolons, a source that starts with `{` (JavaScript parses it as a block, not an object literal), `function` and `class` expressions, block-bodied or `async` arrows, destructuring, default and rest parameters, regular expression literals, tagged templates, `this`, `super`, `new.target`, `import`, `await`, `yield`, `delete`, `in`, `instanceof`, `**`, bitwise and shift operators, BigInt literals, legacy octal literals and escapes, array holes, getters, setters and methods in object literals, `__proto__` in an object literal. Text that is not JavaScript at all (an unterminated string, a missing operand, `a ?? b || c` without parentheses) raises `exn:fail:js-expr:syntax`.

## 5. Evaluation (`cordis-yaml/js-expr`)

```racket
(js-eval e env) -> any                         ; e : (or/c js-expr? string?)
(js-interpolate v env) -> any/c                ; replaces every js-expr inside lists and objects by its value
(js-truthy? v) -> boolean?                     ; JavaScript's Boolean(v)
(make-js-env bindings #:lookup [lookup #f] #:globals [globals js-standard-globals]) -> js-env?
(js-env? v) -> boolean?
(js-env-bindings env) -> hash?                 ; the caller's bindings, keys as strings
js-standard-globals : hash?                    ; name (string) -> value
(current-js-fallback) -> (or/c #f (-> string? js-env? any))   ; parameter
(struct exn:fail:js-expr exn:fail (source position))          ; position: 0-based offset in the source, or #f
(struct exn:fail:js-expr:syntax exn:fail:js-expr ())
(struct exn:fail:js-expr:unsupported exn:fail:js-expr (construct))
```

`bindings` is a hash from global names (strings or symbols) to values. An identifier resolves, in order, against: the parameters of enclosing arrow functions; `lookup`, a procedure `(lookup name failure-thunk)` in the style of `hash-ref` that stands for dsh's `with (ctx)` scope; `bindings`; `globals`. A name found nowhere raises `exn:fail:js-expr` (`ReferenceError: NAME is not defined`), unless it is a standard JavaScript or Node global that this package does not implement (`Date`, `RegExp`, `Buffer`, `require`, `globalThis`, `process` when the caller bound none, ...), which raises `exn:fail:js-expr:unsupported`. The loader binds `ctx`, `process` and `expr` (dsh's evaluation function has the parameters `ctx` and `expr`) and passes the context's `has` test as `lookup`.

### 5.1 Values

| JavaScript | Racket |
|---|---|
| `undefined` | `(void)` |
| `null` | `'null` |
| boolean | `#t`, `#f` |
| number | real: a result that is integral, not `-0`, and at most 2^53 in magnitude is an exact integer; every other result is a flonum (`+nan.0`, `+inf.0`, `-inf.0`, `-0.0` included). Inputs may be any real. |
| string | string |
| array | list |
| plain object | `jobject` (a hash is accepted on input) |
| function | procedure; a call passes the arguments positionally. A procedure that does not accept the number of arguments given is called with the extra ones dropped or the missing ones as `(void)`, as JavaScript does. |
| host object | a value that implements `gen:js-object` (section 6) |

An object literal or spread drops members whose value is `undefined`, because a jobject cannot hold `(void)` (ADR 0006: absent and `undefined` are the same). An array keeps `(void)` elements. Object identity (`===` on arrays and objects) is `eq?`; all empty arrays are one object.

`js-eval` returns the value of the expression. `js-interpolate` walks lists and jobjects as dsh's `interpolate` does and returns the structure with each `js-expr` replaced by its value; an object member whose value is `undefined` is dropped, an array element stays `(void)`.

### 5.2 Semantics

Evaluation follows ECMAScript for the constructs of section 4: truthiness; `===` and `!==`; `==` and `!=` with their coercions; `+` with string concatenation after `ToPrimitive`; `- * / %` on doubles; relational operators on numbers or, when both operands are strings, on UTF-16 code units; short-circuit `&&`, `||`, `??`; `typeof` (including on an undeclared name); optional chaining; spread of arrays and strings into arrays and calls and of objects into objects; template literals; arrow functions as closures. String lengths and indexes are UTF-16 code units.

Properties and methods implemented:

- strings: `length`, index access, `at`, `charAt`, `concat`, `endsWith`, `includes`, `indexOf`, `padEnd`, `padStart`, `repeat`, `replace` and `replaceAll` (string pattern; string replacement with `$$`, `$&`, `` $` ``, `$'`, or a function), `slice`, `split` (string separator, optional limit), `startsWith`, `substring`, `toLowerCase`, `toString`, `toUpperCase`, `trim`, `trimEnd`, `trimStart`, `valueOf`;
- arrays: `length`, index access, `at`, `concat`, `every`, `filter`, `find`, `includes`, `indexOf`, `join`, `map`, `slice`, `some`, `toString`; callbacks receive element, index and array;
- numbers: `toFixed`, `toString` (radix 10; other radixes for integers), `valueOf`; booleans: `toString`, `valueOf`;
- objects: own members.

A member of `String.prototype`, `Array.prototype`, `Number.prototype` or `Object.prototype` that is not listed raises `exn:fail:js-expr:unsupported`; a name JavaScript does not define reads as `undefined`, and calling it raises `TypeError`.

`js-standard-globals` holds: `NaN`, `Infinity`, `Number` (callable; `isFinite`, `isInteger`, `isNaN`, `isSafeInteger`, `parseFloat`, `parseInt`, `MAX_SAFE_INTEGER`, `MIN_SAFE_INTEGER`, `MAX_VALUE`, `MIN_VALUE`, `EPSILON`, `POSITIVE_INFINITY`, `NEGATIVE_INFINITY`, `NaN`), `String`, `Boolean`, `parseInt`, `parseFloat`, `isNaN`, `isFinite`, `JSON` (`parse` without a reviver, `stringify` with an optional numeric indent), `Math` (`abs`, `ceil`, `floor`, `max`, `min`, `round`, `sign`, `trunc`, `PI`), `Array` (`isArray`), `Object` (`keys`, `values`, `entries` of plain objects and arrays), `encodeURIComponent`, `decodeURIComponent`, `encodeURI`, `decodeURI`, and `URL`.

`new URL(input, base)` implements the WHATWG URL parser for the special schemes `http`, `https`, `ws`, `wss`, `ftp` and `file`: relative references, dot segments, percent-encoding, default ports, user info, Windows drive letters in file URLs. The object has `href`, `protocol`, `username`, `password`, `host`, `hostname`, `port`, `pathname`, `search`, `hash`, `origin`, `toString()` and `toJSON()`, and converts to its `href` as a string. Other schemes, IPv6 hosts, hosts that need IDNA or percent-decoding, numeric hosts other than four decimal parts, and `searchParams` raise `exn:fail:js-expr:unsupported`. An invalid URL raises `TypeError: Invalid URL`.

### 5.3 Errors and the fallback

A JavaScript run-time error (`TypeError`, `ReferenceError`, `RangeError`, `URIError`, the `SyntaxError` of `JSON.parse`) raises `exn:fail:js-expr`; its message starts with the JavaScript error name. An exception raised by a host procedure passes through unchanged. Every message of this family ends with the expression source and, when known, the position.

Before `js-eval` raises `exn:fail:js-expr:unsupported`, whether from parsing or during evaluation, it consults `(current-js-fallback)`. When that is a procedure, `js-eval` returns `(fallback source env)` instead, so a host can delegate the expression to Node. Evaluation may already have called host procedures by then; expressions in configuration are expected to have no side effects. `js-parse` never consults the fallback.

## 6. Host objects and the `process` object (`cordis-yaml/js-expr`)

```racket
gen:js-object                                  ; generic interface
(js-object? v) -> boolean?
(js-get-property obj name) -> any              ; name : string?; (void) for an absent property
(js-call-method obj name args) -> any          ; args : list?; default: read the property and call it
(make-js-object get [call #f]) -> js-object?   ; get : (-> string? any); call : (or/c #f (-> string? list? any))

(make-node-process-object
  #:env [env (current-environment-variables)]  ; hash, jobject, environment-variables, or (-> string? (or/c string? #f))
  #:cwd [cwd (current-directory)]              ; path-string, or a thunk that returns one
  #:platform [platform <host platform>]        ; "linux", "darwin", "win32", ...
  #:exec-path [exec-path (find-executable-path "node")]   ; path-string or #f
  #:resolve [resolve #f]                       ; (or/c #f (-> string? string? string?)): specifier, base -> path
  #:homedir [homedir #f]                       ; path-string or #f: HOME from env, then the system home directory
  #:extra [extra (hash)])                      ; further members, name -> value
  -> js-object?
```

A struct implements `gen:js-object` to expose a context, a service or any other object lazily: `obj.name` calls `js-get-property`, `obj.name(args)` calls `js-call-method`. Returning `(void)` from `js-get-property` means the property is absent. `make-js-object` builds one from closures.

`make-node-process-object` returns the value to bind as `process`:

- `env`: an object whose member `NAME` is the variable's string value, or `undefined` when unset. It cannot be enumerated (spreading it or passing it to `JSON.stringify` raises unsupported).
- `cwd()`: the directory as a string without a trailing separator. `platform`: the string given. `execPath`: the path given; when `exec-path` is `#f`, reading it raises `exn:fail:js-expr`.
- `getBuiltinModule(id)`, with or without the `node:` prefix:
  - `path`: `sep`, `delimiter`, `join`, `normalize`, `resolve` (relative to `cwd()`), `dirname`, `basename`, `extname`, `isAbsolute`, with Node's POSIX algorithms. When `platform` is `"win32"` these raise unsupported, because Node would apply its Windows algorithms.
  - `module`: `createRequire(base)`, whose result has `resolve(specifier)`. It returns `(resolve specifier base)` with `base` as a string (the `href` of a `URL` object). Without a resolver it raises `exn:fail:js-expr`.
  - `os`: `homedir()`, `tmpdir()`, `platform()`, `EOL`.
  - any other id raises unsupported.
- the members given in `extra` (for example `"version"`).
- any other member raises unsupported.

## 7. Tests

`raco test racket/cordis-yaml` needs neither Node nor the network, and covers:

- every scalar resolution rule, every escape, block scalar header and chomping case, flow and block collection forms, anchors, tags, directives, document markers, and the position of each error class;
- the corpus: every `*.yml` file under `packages/`, `apps/` and `snapshots/` of the repository (736 at the pinned commit) parses; reading, writing and reading again yields `equal?` values with expression sources preserved; the test is skipped with a message when the repository tree is not present;
- every distinct `!!js` expression of the corpus (106) parses and evaluates without `unsupported` under realistic environments, with `ctx` and services as recording host objects;
- each language construct of section 4, each coercion rule and each listed method, and the position reported for unsupported constructs;
- a differential table checked in as `tests/data/js-yaml-table.rktd` with its generator `tests/gen/gen-js-yaml-table.mjs`: for every corpus file, digests of js-yaml's parse (as JSON) and of js-yaml's dump of it, which the reader and writer must reproduce; hand-written YAML texts with js-yaml's result or error; values with js-yaml's dump text; and expressions with the result Node computed under an equivalent environment. A corpus file whose content no longer matches the digest recorded for it is still checked for parsing and round trip, and is reported as stale without failing.
