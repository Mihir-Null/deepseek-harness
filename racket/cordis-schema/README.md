# cordis-schema

The schema DSL every dsh plugin uses for its `Config`, as a Racket collection. It is the port of Schemastery as vendored in `vendor/schemastery` (package version 3.19.0 over upstream 3.18.0, with local modification V22), of cosmokit's volatile references (`vendor/cosmokit/src/volatile.ts`), and of the raw-config comparison the loader runs before a volatile commit (`vendor/loader/src/config/diff.ts`).

The interface contract is [docs/racket/contracts/cordis-schema.md](../../docs/racket/contracts/cordis-schema.md). It lists every exported binding, the resolution algorithm, every error message, the JSON form and the deliberate differences from Schemastery.

## What it provides

```racket
(require cordis-schema cordis-data)

(define-config tool-jobs-config
  [waitTimeoutMs #:as wait-timeout-ms (schema-number #:min 1 #:default 30000)]
  [completionDelivery (schema-union '("quiet" "wakeup") #:default "wakeup")]
  [maxConsecutiveWakes (schema-number #:min 1)])

(define cfg (tool-jobs-config (jobject 'completionDelivery "quiet")))
(tool-jobs-config-wait-timeout-ms cfg)          ; 30000
(tool-jobs-config-maxConsecutiveWakes cfg 5)    ; 5
(tool-jobs-config (jobject 'waitTimeoutMs 0))
;; raises exn:fail:schema: $.waitTimeoutMs expected number >= 1 but got 0
```

- A schema is an immutable value that is applicable: `(s data)` validates `data`, fills defaults and returns the resolved value, or raises `exn:fail:schema` with Schemastery's message and the path.
- Constructors `schema-any`, `schema-never`, `schema-const`, `schema-string`, `schema-number`, `schema-natural`, `schema-percent`, `schema-boolean`, `schema-date`, `schema-regexp`, `schema-array-buffer`, `schema-bitset`, `schema-function`, `schema-is`, `schema-array`, `schema-dict`, `schema-tuple`, `schema-object`, `schema-union`, `schema-intersect`, `schema-transform`, `schema-lazy`, `schema-custom`, and the shorthand `schema-from`.
- Modifiers as functions (`schema-required`, `schema-default`, `schema-min`, `schema-volatile`, ...) and as keyword options of every constructor (`#:default`, `#:min`, `#:required?`, ...).
- `schema-resolve` (the resolved value and the rewritten input), `schema-validate` (the Standard Schema face), `schema-simplify`, `schema-i18n`, `schema->string`.
- `schema->jvalue` and `jvalue->schema`: Schemastery's serialized JSON form with its uid and refs table.
- Volatile references (`make-volatile`, `volatile-ref`, `volatile-update!`, `volatile-entries`) and `equal-except-volatile?`.
- The declaration forms `define-config` and `schema-object*`. A misspelled accessor of a `define-config` is an unbound identifier at compile time.

Config values are jvalues from `cordis-data`: objects are `jobject`s that keep key order, arrays are lists, `null` is `'null`, and `(void)` stands for JavaScript's `undefined`.

## Modules

| Module | Contents |
|---|---|
| `main.rkt` | the collection `cordis-schema`: everything below, re-exported |
| `volatile.rkt` | `cordis-schema/volatile`: references alone, for code that handles them without schemas |
| `private/api.rkt` | the functions with their contracts |
| `private/forms.rkt` | `define-config`, `schema-object*` |
| `private/schema.rkt` | the schema value, type strings, volatile placement, resolution |
| `private/build.rkt` | constructors, modifiers, option keywords |
| `private/json.rkt` | the JSON form |
| `private/ops.rkt` | simplification, i18n, raw-config comparison |
| `private/js.rkt` | the JavaScript coercions the algorithms depend on: `String(v)`, `JSON.stringify(v)`, double arithmetic, regular-expression source translated to Racket, the ECMAScript date-time format |

The package depends on `base` and `cordis-data`.

## Tests

```sh
raco link -n cordis-schema racket/cordis-schema    # once
raco make racket/cordis-schema/*.rkt racket/cordis-schema/tests/*.rkt
raco test racket/cordis-schema
```

or `make -C racket test`. The tests need neither Node nor a network.

`tests/data/node-table.rktd` is a differential table computed by the vendored Schemastery under Node: 298 schemas with 1195 inputs (resolved value or error message with its path, the rewritten input, the simplified value), the type strings and JSON form of every schema, 72 `simplify` rows, 14 `i18n` rows, 36 rows of the loader's `equalExceptVolatile`, and 127 regular expressions against 70 strings each. `tests/node-table-test.rkt` checks every row twice, with the schema built through the public constructors and with the schema read back from Node's JSON form. Regenerate the table with:

```sh
node --experimental-transform-types racket/cordis-schema/tests/gen/gen-node-table.mjs
```

The generator loads `vendor/schemastery/src/index.ts`, `vendor/cosmokit/src/index.ts` and `vendor/loader/src/config/diff.ts` directly, with a resolve hook for `@deepseek-ai/cosmokit`, and uses Node built-ins only. `--seed N --random N --out FILE` writes a larger random table elsewhere, which `check-node-table` from `tests/support/node-table.rkt` checks the same way.

The other test files port `scripts/volatile-config.spec.ts` and `scripts/loader-config-diff.spec.ts` and cover what the table cannot reach: Racket-specific values (procedures, dates, regexps, bytes, hashes, structs), every modifier and option keyword, contracts, hydration of malformed and recursive JSON, the syntax errors of the declaration forms, and the deliberate differences from Schemastery (`tests/differences-test.rkt`).

## dsh correspondence

| dsh | Here |
|---|---|
| `vendor/schemastery` (`@deepseek-ai/schemastery`) | the whole collection |
| `vendor/cosmokit/src/volatile.ts` | `volatile.rkt` |
| `vendor/loader/src/config/diff.ts` | `equal-except-volatile?` |
| `import z from '@deepseek-ai/schemastery'`; `z.object({ ... })` in a plugin | `define-config` or `schema-object*` |
