# Interface contract: `cordis-schema`

The schema DSL every plugin uses for its `Config`: the Racket port of Schemastery as vendored (`vendor/schemastery/src/index.ts`, package version 3.19.0 over upstream 3.18.0, local modification V22), together with cosmokit's volatile references (`vendor/cosmokit/src/volatile.ts`) and the raw-config comparison the loader runs before a volatile commit (`vendor/loader/src/config/diff.ts`).

Package `racket/cordis-schema/`, collection `cordis-schema`, `(define deps '("base" "cordis-data"))`, `(define build-deps '("rackunit-lib"))`. Values are jvalues from [cordis-data](cordis-data.md) ([ADR 0006](../../adr/0006-ordered-json-value-model.md)). When this document and the TypeScript sources disagree about a result or a message, the sources are right and this document has a defect, except for the differences listed in section 13.

## 1. Modules

| Module | Provides |
|---|---|
| `cordis-schema` (`main.rkt`) | everything in sections 2 to 12 |
| `cordis-schema/volatile` | section 9 alone, for code that handles references without schemas |

Internal modules live under `private/`.

## 2. Values and JavaScript correspondences

| JavaScript | Racket |
|---|---|
| `undefined`, an absent key | `(void)`; never stored in a jobject |
| `null` | `'null` |
| string, boolean | string, boolean |
| number | real number (exact integer or flonum); arithmetic and number text follow doubles |
| array | list |
| plain object | `jobject`; a `hash` is accepted on input and read in `cordis-data` key order |
| function | procedure (a schema is not a procedure for this purpose) |
| `Volatile<T>` | `volatile?` reference (section 9) |
| `Date` | `date*` in UTC (`racket/base`); any `date?` is accepted on input |
| `RegExp` | `regexp?` or `byte-regexp?` value |
| `ArrayBuffer` and views | `bytes?` |

"Nullable" means `(void)` or `'null`. A result list may hold `(void)` where Schemastery leaves `undefined` in an array (an autofixed element, a callback result); a result jobject omits a key whose value would be `undefined`.

## 3. Schemas

```racket
(schema? v) -> boolean?
(s [data (void)] #:autofix? [autofix? #f] #:ignore [ignore #f] #:path [path '()]) -> any/c
(schema-resolve s data #:autofix? [autofix? #f] #:ignore [ignore #f] #:path [path '()]
                #:strict? [strict? #f] #:options [options #f]) -> (values any/c any/c)
(schema-validate s data) -> (values any/c (or/c #f (listof (cons/c list? string?))))
(struct exn:fail:schema exn:fail (path))
(raise-schema-error message [where '()]) -> none/c      ; where : path list or resolve-options?
```

A schema is an immutable value. Every constructor and modifier returns a new schema and leaves its arguments unchanged; two schemas are `equal?` only when they are `eq?`. A schema is applicable: `(s data)` validates `data`, fills defaults and returns the resolved value, as Schemastery's `schema(data, options)` does, or raises `exn:fail:schema`. `(s)` resolves an absent value.

- `#:autofix?`: a property that fails is removed and replaced by its schema's default instead of raising (Schemastery `autofix`).
- `#:ignore`: `(-> data schema any/c)`; a true result returns `data` unvalidated for that node (Schemastery `ignore`).
- `#:path`: list of symbols, strings and exact nonnegative integers that prefixes the path of every error.
- `exn:fail:schema`: `exn-message` is the Schemastery `ValidationError` message exactly, path prefix included (section 7). `path` is the list of object keys (symbols) and array indexes (exact nonnegative integers) from the root, starting with the `#:path` prefix.
- `schema-resolve` is `Schema.resolve`. Its second value is the input as Schemastery leaves it after resolving in place: the first value's counterpart on the raw side, with a bitset written as its key list, dictionary keys renamed by the key schema, a non-preserving transform applied, and, with `autofix?`, failed properties removed. It is `eq?` to `data` when nothing changed. `#:strict?` is Schemastery's fourth argument (unknown keys are not copied). `#:options` passes a `resolve-options?` received by a custom resolver (section 4.4) and overrides the three option keywords.
- `schema-validate` is the Standard Schema face (`schema['~standard'].validate`): it returns `(values value #f)`, or `(values (void) (list (cons path message)))` for an `exn:fail:schema`, with `message` the full message and `path` the error path. Any other exception propagates.
- A schema prints as `#<schema TYPE-STRING>` (section 6).

Accessors, for code that walks a schema (settings forms, secret redaction):

```racket
(schema-type s) -> string?                           ; "object", "string", ...
(schema-meta s) -> jobject?                          ; defined metadata, in the order it was set
(schema-meta-ref s key [default (void)]) -> any/c    ; key : symbol?
(schema-inner s) -> (or/c schema? #f)                ; array, dict, transform; a lazy schema is built first
(schema-key-schema s) -> (or/c schema? #f)           ; dict (Schemastery sKey)
(schema-members s) -> (or/c (listof schema?) #f)     ; tuple, union, intersect (Schemastery list)
(schema-fields s) -> (or/c jobject? #f)              ; object: key -> schema (Schemastery dict)
(schema-bits s) -> (or/c jobject? #f)                ; bitset
(schema-const-value s) -> any/c                      ; const; (void) otherwise
(schema-callback s) -> any/c                         ; transform: procedure, or the unrevived source string
(schema-constructor s) -> (or/c string? #f)          ; is
```

Metadata keys are Schemastery's: `default`, `required`, `volatile`, `disabled`, `collapse`, `badges`, `hidden`, `loose`, `role`, `extra`, `link`, `description`, `comment`, `pattern`, `max`, `min`, `step`.

## 4. Constructors

```racket
(schema-any)                                   ; z.any()
(schema-never)                                 ; z.never()
(schema-const value)                           ; z.const(value)
(schema-string)                                ; z.string()
(schema-number)                                ; z.number()
(schema-natural)                               ; z.natural()  = number, step 1, min 0
(schema-percent)                               ; z.percent()  = number, step 0.01, min 0, max 1, role "slider"
(schema-boolean)                               ; z.boolean()
(schema-date)                                  ; z.date()
(schema-regexp [flag ""])                      ; z.regExp(flag)
(schema-array-buffer [encoding #f])            ; z.arrayBuffer(encoding); encoding : #f, 'hex or 'base64
(schema-bitset bits)                           ; z.bitset(bits); bits : jobject, hash or alist of key -> integer
(schema-function)                              ; z.function()
(schema-is constructor [pred #f])              ; z.is(...); constructor : string?
(schema-array inner)                           ; z.array(inner)
(schema-dict inner [key (schema-string)])      ; z.dict(inner, sKey)
(schema-tuple members)                         ; z.tuple(list)
(schema-object fields)                         ; z.object(dict); fields : jobject, hash or alist
(schema-union members)                         ; z.union(list)
(schema-intersect members)                     ; z.intersect(list)
(schema-transform inner callback [preserve (void)] #:source [source #f])   ; z.transform(inner, callback, preserve)
(schema-lazy builder)                          ; z.lazy(builder); builder : (-> schema?)
(schema-from x) -> schema?                     ; Schema.from(x)
(schema-custom type resolve #:format [format #f])   ; new Schema({ type }) with Schema.extend(type, resolve)
```

The vendored source defines no `computed` type, so there is none here.

### 4.1 Shorthand

Wherever a constructor takes a schema (`inner`, `key`, each member, each field), it takes anything `schema-from` accepts:

| `x` | Result | Schemastery |
|---|---|---|
| a schema | itself | itself |
| `(void)`, `'null` | `(schema-any)` | `null`, `undefined` |
| string, real, boolean | `(schema-required (schema-const x))` | primitive value |
| `'string`, `'number`, `'boolean`, `'function` | the required primitive schema | `String`, `Number`, `Boolean`, `Function` |

Anything else raises `exn:fail:contract` with the message `cannot infer schema from` followed by the value. So `(schema-array 'string)` is `z.array(String)` and `(schema-union '("legacy" "timed"))` is `z.union(['legacy', 'timed'])`.

### 4.2 Options

Every constructor also accepts the modifiers of section 5 as keyword arguments. They are applied after construction in this fixed order, whatever order they are written in: `#:pattern` (source string), `#:step`, `#:min`, `#:max`, `#:role`, `#:required?`, `#:default`, `#:description`, `#:comment`, `#:link`, `#:hidden?`, `#:disabled?`, `#:collapse?`, `#:loose?`, `#:deprecated?`, `#:experimental?`, `#:volatile?`. The last three do nothing when false. `(schema-number #:step 1 #:min 1 #:default 3)` is `z.number().step(1).min(1).default(3)`. Use the modifier functions when the order of metadata keys in the JSON form must follow another call order, or for `role` with extra data and `pattern` with flags.

### 4.3 Types

Each resolver receives non-nullable data, except `lazy` (section 7.1). Messages are in section 7.3.

- `any`: returns the data.
- `never`: always fails.
- `const`: accepts data `deep-equal?` (loose) to `value`; returns `value`.
- `string`: a string; with `pattern`, it must match; `min` and `max` bound its length in UTF-16 units.
- `number`: a real number within `min` and `max`; with a non-zero `step`, `data - (min or 0)` must be a multiple of `step`, computed as Schemastery does (in doubles, shifting decimal digits when `step` prints with a fraction).
- `boolean`: a boolean. `function`: a procedure that is not a schema.
- `bitset`: a number is kept; a list of key strings is OR-ed into a 32-bit integer (unknown keys add nothing; a member that is not a string fails). Default `0`. The adapted input is the key list unless the value equals the default.
- `is`: with `pred`, data that satisfies `pred`, like `z.is(Constructor)`. Without it, like `z.is('Name')`: data whose JavaScript-side constructor chain contains the name. The chain of a Racket value is: `String`, `Number`, `Boolean`, `Function` for those types; `Array` for a list; `Date` for a `date?`; `RegExp` for a regexp; `ArrayBuffer` for bytes; the names of a struct's visible struct types; and `Object` for every value.
- `array`: a list; `min` and `max` bound its length (the minimum is skipped when `inner` has a non-nullable default); each element resolves as a property with its index. Default `'()`.
- `dict`: an object; each key resolves through `key` (in strict mode a rejected key is skipped, otherwise the failure propagates), each value through `inner` as a property; the result maps resolved keys to values. Default the empty jobject.
- `tuple`: a list; position `i` resolves through member `i` as a property; elements beyond the members are appended unvalidated unless strict. Default `'()`.
- `object`: an object; fields resolve in schema order, each as a property; a field is stored when its value is not nullable or its key is present in the input; then, unless strict, input keys not yet in the result are appended in input order. Default the empty jobject.
- `union`: the first member that resolves the data wins.
- `intersect`: no members returns the data. Otherwise each member resolves the data in strict mode; nullable results are skipped; the first other result is the base; a later result of another JavaScript type, or an unequal primitive, fails; object results add the keys the base lacks (list results extend the base list). Unless strict, and when the data is an object, input keys the result lacks are appended.
- `transform`: resolves `inner` in strict mode and returns `(callback result)`. Unless `preserve` is true, the callback is called a second time, on the adapted input, to produce the adapted value; this is Schemastery's behaviour and a callback must tolerate it. `#:source` is the JavaScript text of the callback for the JSON form.
- `lazy`: `builder` runs on first use (resolution, `schema-inner`, serialization) and its result is cached in that schema value. The built schema's metadata is the lazy node's metadata overridden by its own.
- `date`: `union` of `is "Date"` and a preserving transform of `string` with role `datetime` that parses the ECMAScript date-time format (`YYYY-MM-DD`, `YYYY-MM-DDTHH:mm[:ss[.sss]]` with `Z`, an offset, or local time) into a UTC `date*`.
- `regexp`: `union` of `is "RegExp"` and a preserving transform of `string` with role `regexp` and extra `{"flag": flag}` that compiles the text, read as JavaScript regular-expression syntax, into a Racket regexp.
- `array-buffer`: `union` of `is "ArrayBuffer"`, `is "SharedArrayBuffer"`, a preserving transform of `any` that accepts bytes, and, with an encoding, a preserving transform of `string` that decodes hex or base64 as Node's `Buffer.from` does.

A "property" is Schemastery's `property()`: the child resolves with the key appended to the path; with `autofix?` a failure of any kind removes the key from the adapted input and yields the child's default (wrapped in a reference when the child is volatile).

### 4.4 Custom types

`(schema-custom type resolve)` makes a schema of type `type` whose resolver is `resolve : (-> data schema options strict? (values value adapted))`; `adapted` is `(void)` when the input needs no rewriting, and returning one value means the same. `options` is opaque:

```racket
(resolve-options? v) -> boolean?
(resolve-options-path o) -> list?
(resolve-options-autofix? o) -> boolean?
(resolve-options-ignore o) -> (or/c procedure? #f)
(resolve-options-extend o key) -> resolve-options?     ; the same options with key appended to the path
```

A resolver resolves a child with `(schema-resolve child data #:options options)` and fails with `(raise-schema-error message options)`. `#:format` is `(-> schema inline? string?)` for section 6. There is no global resolver table: a type name without a resolver fails with `unsupported type "TYPE"` when resolved.

## 5. Modifiers

Each returns a new schema; `value` flags default to `#t`.

```racket
(schema-required s [value #t])        (schema-hidden s [value #t])
(schema-disabled s [value #t])        (schema-collapse s [value #t])
(schema-loose s [value #t])
(schema-default s value)              (schema-description s text)      ; text : string or locale -> string object
(schema-comment s text)               (schema-link s url)
(schema-min s n)                      (schema-max s n)                 (schema-step s n)
(schema-role s role [extra (void)])   ; sets role and extra
(schema-pattern s source #:flags [flags ""])
(schema-deprecated s)                 ; appends the badge {"text":"deprecated","type":"danger"}
(schema-experimental s)               ; appends the badge {"text":"experimental","type":"warning"}
(schema-volatile s)                   ; raises exn:fail:contract "volatile schema is already wrapped" on repeat
(schema-extra s key value)            ; any metadata key; key : symbol or string
(schema-set s key child)              ; object: add or replace a field
(schema-push s child)                 ; tuple, union, intersect: append a member
(schema-i18n s messages)              ; merge per-locale descriptions (Schemastery i18n)
(schema-simplify s value) -> any/c    ; section 8
```

- A metadata key keeps the position of its first assignment; a value of `(void)` records the key as undefined (it is then absent from `schema-meta` and from the JSON form), as `.extra('default', undefined)` does.
- `schema-pattern` takes the pattern as JavaScript regular-expression source, as it appears between the slashes in the TypeScript, and stores `{"source": ..., "flags": ...}` with the source as `RegExp.prototype.source` prints it and the flags in canonical order. The source is translated to a Racket `pregexp` for matching: character classes, anchors, quantifiers, groups (named groups included), lookaround, backreferences and the escapes `\d \w \s \b \t \n \r \f \v \0 \xHH \uHHHH \u{H} \cX` with the flags `i`, `m`, `s`, `y` are supported; `g`, `u`, `d`, `v` are accepted and have no effect on a single test. A source that cannot be translated raises `exn:fail:contract` from `schema-pattern`.
- `schema-set` and `schema-push` return a new schema; Schemastery mutates in place. A recursive schema is written with `schema-lazy`.
- `schema-i18n` follows Schemastery: `messages` maps a locale to a string or an object with `$description` or `$desc`, `$value` or `$inner`, `$key`, and per-field or per-index entries; descriptions become a locale object whose `""` entry is the previous plain description.
- `schema-volatile` marks the node as parsed into a reference. Placement is checked when a schema is resolved (section 7.2).

## 6. Type strings

```racket
(schema->string s [inline? #f]) -> string?     ; Schemastery toString(inline)
```

`any`, `never`, `string`, `number`, `boolean`, `bitset`, `function` by name; `const` as JSON text for a string and as the JavaScript string of any other value (`Schema<const>` for a nullable value); `is` as the constructor name; `array` as `INNER[]` with the inner printed inline; `dict` as `{ [key: K]: V }`; `tuple` as `[A, B]`; `object` as `{ key?: T, other: U }` with `?` unless the field is required, `{}` when empty; `union` as members joined with ` | `, parenthesized when inline; `intersect` as members printed inline and joined with ` & `; `transform` as its inner; every other type, `lazy` included, as `Schema<TYPE>`.

## 7. Resolution

### 7.1 Algorithm (`Schema.resolve`)

For data `d`, schema `s`, options and a strict flag:

1. Once per top-level call, check volatile placement (7.2).
2. If `s` is volatile: resolve `d` with the same schema without the mark, and wrap the value with `make-volatile`. A value a reference cannot hold fails with that error's message and the current path.
3. If `ignore` returns true for `d` and `s`, the result is `d`.
4. If `d` is nullable and `s` is not `lazy`: when `required` is true, fail with `missing required value`. Otherwise take the default; while it is nullable and the schema is an `intersect`, look at the first member's default instead. With no default the result is `d` itself. Otherwise continue with the default as the data; the adapted input stays `d` unless the type's resolver produces one.
5. Run the type's resolver. A type without one fails with `unsupported type "TYPE"`.
6. If the resolver raises anything and `loose` is true, the result is the default.

Results are deterministic and never alias mutable state: the same schema and data always give `equal?` results, except that every volatile field yields a fresh reference.

### 7.2 Volatile placement (`validateVolatileSchema`)

A volatile node is legal only on a path of object fields with no enclosing volatile node. A volatile node below an `inner` (array, dict, transform, built lazy), a member list (union, tuple, intersect), a dict key schema, or another volatile node fails with `volatile fields require a fixed object path without an enclosing volatile field`, whose path is the schema path: the field keys, then `*` for an inner, `<key>` for a key schema, the member index as a key (so `$.items.*`, `$.0.title`). The check runs on every top-level resolve, whether or not the input has the field. A lazy schema that is not built yet is not expanded; it is checked once when built, with the data path of that moment.

### 7.3 Messages

`exn-message` is the path prefix and the message. The prefix is `$` followed by `.KEY` for each key and `[N]` for each index, then a space; an empty path has no prefix: `$.root[1] expected string but got 1`, `$.a missing required value`, `expected object but got str`.

`DATA` below is the JavaScript string of the value (`String(data)`): a string as is; a number as `js-number->string`; `true`, `false`, `null`, `undefined`; a list as its members joined with `,` (nullable members empty); an object as `[object Object]`; a procedure as `function NAME() { [native code] }`. `JSON` is `JSON.stringify(data)`.

| Type | Message |
|---|---|
| any nullable data | `missing required value` |
| unknown type | `unsupported type "TYPE"` |
| `never` | `expected nullable but got DATA` |
| `const` | `expected VALUE but got DATA` |
| `string` | `expected string but got DATA`; `expect string to match regexp /SOURCE/FLAGS`; `expected string length <= MAX but got N`; `expected string length >= MIN but got N` |
| `number` | `expected number but got DATA`; `expected number <= MAX but got DATA`; `expected number >= MIN but got DATA`; `expected number multiple of STEP but got DATA` |
| `boolean`, `function` | `expected boolean but got DATA`; `expected function but got DATA` |
| `bitset` | `expected number or array but got DATA`; `expected string but got MEMBER` |
| `is` | `expected NAME but got DATA` |
| `array`, `tuple` | `expected array but got DATA`; `expected array length <= MAX but got N`; `expected array length >= MIN but got N` |
| `dict`, `object` | `expected object but got DATA` |
| `union`, `intersect` | `expected TYPE-STRING but got JSON` |
| volatile placement | `volatile fields require a fixed object path without an enclosing volatile field` |
| reference contents | `volatile config cannot contain functions`; `volatile config cannot contain cycles`; `volatile config objects must be plain objects or arrays` |

The maximum is checked before the minimum. A failing union member's own error is discarded; a failing intersect member's error propagates.

## 8. Simplification (`schema.simplify`)

`(schema-simplify s value)` removes what equals a default, for writing a config back. A reference is replaced by its contents first. A value `deep-equal?` to the schema's default gives `'null` (strict comparison for `dict`, loose otherwise). A nullable value is returned as is. `object`: each key of the value is simplified by its field schema and kept when the result is not nullable; keys without a field schema are dropped; a result equal to the default gives `'null`. `dict`: every key is kept with its simplified value. `array`, `tuple`: elements are simplified by `inner` or the member at the same index. `intersect`: the members' results are merged left to right. `union`: the first member that resolves the value simplifies it. Other types return the value.

`(z.object({ a: z.number().default(1), b: z.string() })).simplify({ a: 1, b: 'x', c: 2 })` is `{ b: 'x' }`.

## 9. Volatile references (`cordis-schema/volatile`)

```racket
(volatile? v) -> boolean?
(make-volatile value) -> volatile?                    ; createVolatile
(volatile-ref v) -> any/c                             ; get(): the current snapshot
(volatile-update! target source) -> void?             ; updateVolatile: target takes source's snapshot
(volatile-entries value) -> (listof (cons/c list? volatile?))   ; volatileEntries: (path . reference)
```

- A reference holds an immutable snapshot: a jvalue, `(void)` for an absent value, or lists and jobjects of those. `make-volatile` copies hashes into jobjects and raises `exn:fail:contract` with cosmokit's messages for a procedure (`volatile config cannot contain functions`), a mutable hash that contains itself (`volatile config cannot contain cycles`) and any other value (`volatile config objects must be plain objects or arrays`).
- References are opaque and compared specially: any two references are `equal?`, whatever they hold, and a reference is never `equal?` to anything else. This is cosmokit's `deepEqual` rule, and it makes `deep-equal?` and `equal?` from `cordis-data` ignore reference contents inside a parsed config. Identity is `eq?`; every resolve creates new references.
- Only the owner of a config calls `volatile-update!` (the loader, when it commits a volatile-only change). Readers keep the reference and call `volatile-ref` at each use.
- `volatile-entries` walks jobjects, hashes and lists, without entering snapshots, and returns each reference with its path: symbols for keys and exact integers for list indexes, usable with `jref*`. A value that is itself a reference gives one entry with the empty path.
- A reference prints as `#<volatile SNAPSHOT>`.

## 10. Raw-config comparison (`equalExceptVolatile`)

```racket
(equal-except-volatile? previous next schema) -> boolean?
```

Whether two raw configs differ at most in volatile fields. With `schema` not a `schema?` (no schema, or a validator of another kind) it is `(deep-equal? previous next #:strict? #t)`. Otherwise, at each node: a volatile schema node is equal whatever the values; a node that is not an `object` schema, or one already being compared further up (a recursive schema), compares strictly; for an object node a nullable side is replaced by the schema's default, and if either side is then not a jobject or hash the two compare strictly; otherwise every key of either side must be equal under its field schema, keys without one strictly. It never resolves, runs a callback or builds a lazy schema.

## 11. JSON form

```racket
(schema->jvalue s) -> jobject?                 ; schema.toJSON()
(jvalue->schema v #:resolvers [resolvers (hash)] #:revive [revive #f]) -> schema?    ; new Schema(json)
```

`schema->jvalue` returns `{"uid": ROOT, "refs": {"UID": NODE, ...}}`, a jvalue that `jvalue->string` writes as `JSON.stringify(schema)` writes it:

- a node has `type`, `meta` (defined metadata in the order it was set) and, in Schemastery's property order, the fields of its type: `inner`; `inner`, `sKey`; `list`; `dict`; `bits`; `value`; `constructor`; `inner`, `callback`, `preserve`. Child schemas appear as uids. A lazy node is `{"type":"lazy","inner":UID,"meta":{...}}` with the uid of the built schema;
- `callback` is the `#:source` text when one was given, else the procedure's name; `preserve` appears only when it was passed; `constructor` is the name; values that JSON cannot hold are dropped from objects and written as `null` in arrays, and infinities as `null`;
- uids are assigned by this function, not stored in schemas: the distinct schema values reachable from `s` are numbered from 0 in depth-first post-order (children before parents; `inner`, then the key schema, then members, then fields), so the root has the highest uid and `refs` lists nodes in increasing uid order. The same schema value always gets one node. Schemastery's uids come from a process-wide counter, so its numbers differ; the node contents do not.

`jvalue->schema` accepts that envelope, a jobject or hash, and also a bare node whose children are inline nodes (`{"type":"object","dict":{"enabled":{"type":"boolean"}}}`). A node without `meta` gets empty metadata. Shared uids stay shared. A reference back to a node that is still being built (a schema that contains itself without a lazy node) becomes a lazy node. A string `callback` stays a string unless `revive : (-> string? (or/c procedure? #f))` returns a procedure for it; resolving a transform whose callback is not a procedure raises `exn:fail`. `resolvers` maps custom type names to resolvers (4.4). Malformed input (no `type`, an unknown uid) raises `exn:fail:contract`.

## 12. Declaration forms

```racket
(schema-object* option ... [key schema-expr] ...)
(define-config name option ... field ...)
;; option = #:keyword expr                 any option of 4.2, passed to schema-object
;; field  = [key schema-expr]
;;        | [key #:as accessor-suffix schema-expr]
;; key    = identifier | string literal    a string literal key needs #:as
```

`schema-object*` is `schema-object` over the listed fields, in order, with unquoted keys. Each `schema-expr` is anything `schema-from` accepts.

`define-config` defines `name` as that object schema and, for each field, an accessor `name-KEY` (or `name-SUFFIX` with `#:as`):

```racket
(name-KEY config [default]) -> any/c
```

`config` is a resolved config (jobject or hash). Without `default` the accessor returns the field's value, or `(void)` when the key is absent. With `default` it returns `default` when the value is absent or `'null` (JavaScript's `config.key ?? default`); a procedure `default` is called for its value. A volatile field yields its reference. A misspelled field is therefore an unbound identifier at compile time. Keys are the dsh config keys verbatim (`maxParallelSubCalls`); `#:as` gives the accessor a Racket-style name. Duplicate keys, duplicate accessor names, and a malformed clause are syntax errors that name the clause.

```racket
(define-config tool-jobs-config
  [waitTimeoutMs #:as wait-timeout-ms (schema-number #:min 1 #:default 30000)]
  [completionDelivery (schema-union '("quiet" "wakeup") #:default "wakeup")]
  [maxConsecutiveWakes (schema-number #:min 1)])
(define cfg (tool-jobs-config (jobj ['completionDelivery "quiet"])))
(tool-jobs-config-wait-timeout-ms cfg)          ; 30000
(tool-jobs-config-maxConsecutiveWakes cfg 5)    ; 5
```

## 13. Differences from Schemastery

Deliberate, each pinned by a test:

- **No in-place mutation.** Schemastery rewrites its input object while resolving; here the rewritten input is the second value of `schema-resolve`. A union member that fails leaves no trace for later members, where Schemastery may already have rewritten part of the input (only observable with bitset fields, non-preserving transforms or key-renaming dicts inside failing union members).
- **No metadata aliasing.** `schema-deprecated`, `schema-experimental` and `schema-i18n` do not change the schema they are applied to; in Schemastery the copy shares its metadata object with the original.
- **`set` and `push` are functional**, and a schema cannot contain itself; `schema-lazy` expresses recursion. A modifier applied to a lazy schema always reaches the built schema; Schemastery ignores one applied after the lazy node was first resolved.
- **uids** are assigned at serialization (section 11).
- **No global `Schema.extend` table**; the resolver travels with the schema (4.4).
- **Functions** print as `function NAME() { [native code] }` in messages, and a transform callback serializes as its `#:source` or its name, because a procedure has no source text.
- **`date`, `regexp`, `pattern`** accept the documented subset of what `new Date` and `new RegExp` accept.
- **Opaque values** (structs, bytes, regexps, dates) count as objects without keys where Schemastery tests `isPlainObject`.
- **Key order**: a jobject keeps insertion order for every key, where JavaScript moves integer-like keys first.

## 14. Tests

`raco test racket/cordis-schema` needs neither Node nor a network. It covers: every constructor, modifier and option keyword; every message of 7.3; defaults, `required`, `loose`, `autofix?`, `ignore`, `path`, strict mode; the adapted input; type strings; the JSON form and hydration, including metadata-free nodes and shared and recursive nodes; `simplify`; `i18n`; volatile references, placement rejections and `equal-except-volatile?`, porting `scripts/volatile-config.spec.ts` and `scripts/loader-config-diff.spec.ts`; `define-config` and `schema-object*`, including their syntax errors; and real plugin configs from `docs/racket/recon/17-plugin-authoring-surface.md`.

A differential table, `tests/data/node-table.rktd`, holds at least 150 (schema, input) rows whose expected output or error message, adapted input, type string and JSON form were computed by the vendored Schemastery under Node. `tests/gen/gen-node-table.mjs` writes it (`node --experimental-transform-types`, Node built-ins only, the vendored sources loaded through a resolve hook) and is checked in beside it.
