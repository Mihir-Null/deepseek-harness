# cordis-data

The JSON value model that every other Racket package of the port shares. `(require cordis-data)` provides:

- `jobject`, an immutable JSON object that keeps its keys in insertion order, with lookup, functional update, merging, iteration, the `jobj` constructor macro and the `jobj-pat` match pattern;
- JSON text that matches JavaScript: the readers accept what `JSON.parse` accepts, and the writers produce what `JSON.stringify(v, null, indent)` produces, character for character;
- `deep-equal?`, with the loose and strict rules of cosmokit's `deepEqual`;
- the string length units dsh mixes (UTF-16 code units, UTF-8 bytes, code points), JavaScript's string ordering, and `js-number->string` for `String(n)`.

The interface is specified by the [cordis-data contract](../../docs/racket/contracts/cordis-data.md), whose last section records the choices this implementation makes where the contract leaves room. The decision behind the value model is [ADR 0006](../../docs/adr/0006-ordered-json-value-model.md).

## Correspondence with dsh

No dsh package maps to this one. It stands in for what dsh gets from JavaScript itself (object key order, `JSON.parse`, `JSON.stringify`, `String(n)`, `str.length`, `Buffer.byteLength`) and for `deepEqual` in [vendor/cosmokit/src/types.ts](../../vendor/cosmokit/src/types.ts).

## Example

```racket
(require cordis-data racket/match)

(define call (string->jvalue "{\"name\":\"bash\",\"arguments\":{\"command\":\"ls\"},\"id\":7}"))
(jkeys call)                            ; '(name arguments id), the order of the text
(jref* call '(arguments command))       ; "ls"
(define updated (jset* call '(arguments timeout) 30.0))
(jvalue->string updated)
; "{\"name\":\"bash\",\"arguments\":{\"command\":\"ls\",\"timeout\":30},\"id\":7}"
(match updated
  [(jobj-pat [name tool] [arguments (jobj-pat [timeout seconds #:default 60])] #:rest others)
   (list tool seconds (jkeys others))]) ; '("bash" 30.0 (id))
(jobj ['role "user"] #:when (pair? '()) ['attachments '()] ['content "hi"])
; #<jobject {"role":"user","content":"hi"}>
(deep-equal? (jobject 'a 1 'b 'null) (jobject 'a 1.0))               ; #t
(deep-equal? (jobject 'a 1 'b 'null) (jobject 'a 1.0) #:strict? #t)  ; #f
(utf16-length "a\U1F600")               ; 3, JavaScript's "a\u{1F600}".length
```

## Layout

| Path | Holds |
|---|---|
| `main.rkt` | The public module: every export with its contract |
| `private/core.rkt` | The `jobject` struct, hashes read as objects, and the JSON text writer that also prints a jobject |
| `private/jobject.rkt` | Operations on jvalues, `jobj`, `jobj-pat`, `in-jobject`, jsexpr conversion |
| `private/json-read.rkt` | The JSON reader, UTF-8 decoding with replacement, `read-jvalue` |
| `private/json-write.rkt` | `jvalue->string`, `jvalue->bytes`, `write-jvalue` |
| `private/number.rkt` | `Number::toString` |
| `private/equal.rkt` | `deep-equal?` |
| `private/text.rkt` | Length units, truncation, `js-string<?` |

The package depends on `base` only; the tests also use `rackunit-lib`.

## Tests

```sh
raco link -n cordis-data racket/cordis-data   # once, so the collection resolves
raco test racket/cordis-data
```

The suite needs neither Node nor a network. `tests/node-table-test.rkt` compares the package with [tests/data/node-table.rktd](tests/data/node-table.rktd), a table of results that Node computed: `JSON.stringify` texts, `JSON.parse` results and rejections, `String(n)` for doubles given by bit pattern, decimal texts with the double they parse to (including texts at the midpoint between two doubles), string lengths, slices, orderings, UTF-8 decoding of invalid bytes, and the verdicts of the vendored `deepEqual`. The other test files pin each rule of the contract by hand.

Regenerate the table after changing the generator; the seed is fixed, so the same Node version writes the same file:

```sh
node --experimental-transform-types racket/cordis-data/tests/gen/gen-node-table.mjs
```

`tests/gen/` is left out of `raco test`. It also holds two drivers:

- `fuzz.rkt` checks tables of any size, for example `node --experimental-transform-types tests/gen/gen-node-table.mjs --scale 100 --number-scale 700 --seed 3 --out /tmp/fuzz.rktd` followed by `racket tests/gen/fuzz.rkt /tmp/fuzz.rktd`.
- `bench.rkt` times reading and writing three documents of 5 MB each. On the container the package was developed in, reading takes 60 to 190 ms and writing 90 to 360 ms, the slowest case being an array of full-precision doubles.

## Limits

- A jobject keeps keys in insertion order always. JavaScript moves keys that are array indexes (`"0"`, `"42"`) to the front in numeric order, so an object with such keys is written in a different order than dsh writes it.
- Racket strings cannot hold a lone surrogate. An escaped one in JSON text is read as U+FFFD, and the UTF-16 helpers drop a half pair where JavaScript would keep it.
