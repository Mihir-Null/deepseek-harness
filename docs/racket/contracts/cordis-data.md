# Interface contract: `cordis-data`

The value model shared by every other package: JSON-like data whose object key order is preserved, JSON text that matches JavaScript's `JSON.stringify` and `JSON.parse`, structural equality with cosmokit's rules, and helpers for the string length units dsh mixes (UTF-16 code units, UTF-8 bytes, code points).

Package `racket/cordis-data/`, collection `cordis-data`, depends on `base` only (`rackunit-lib` for tests). Decision record: [ADR 0006](../../adr/0006-ordered-json-value-model.md).

## 1. Values

A *jvalue* is one of: a `jobject`; a list of jvalues (a JSON array); a string; a real number that is not NaN or infinite (exact integers and flonums); `#t`; `#f`; `'null`. JavaScript `undefined` has no jvalue: an absent key is "undefined", and `(void)` is never stored.

For convenience every function that reads a jvalue also accepts an immutable or mutable `hash` with symbol or string keys wherever a `jobject` is expected; its keys are taken in `symbol<?` / `string<?` order. Functions that build objects always return `jobject`s.

```racket
(jobject? v) -> boolean?
(jvalue? v) -> boolean?                       ; deep check
(jobject k v ... ...) -> jobject?             ; (jobject 'a 1 'b 2); keys are symbols or strings (strings are interned to symbols)
(jobj [k-expr v-expr] ...)                    ; macro; same, one pair per clause; a clause #:when test [k v] is included only when test is true
(make-jobject alist) -> jobject?              ; alist of (cons key value); later duplicates replace the value but keep the first position
empty-jobject

(jref obj key [default #f]) -> any/c          ; default may be a procedure (called for its value) as in hash-ref
(jref* v path [default #f]) -> any/c          ; path : list of keys (symbols/strings) and array indexes (exact nonnegative integers); default when any step is missing
(jhas? obj key) -> boolean?
(jset obj key value) -> jobject?              ; existing key keeps its position; new key goes last
(jset* v path value) -> jvalue?               ; functional deep update; creates missing objects along the path
(jupdate obj key proc [default #f]) -> jobject?
(jremove obj key) -> jobject?
(jkeys obj) -> (listof symbol?)               ; insertion order
(jvalues obj) -> list?
(jcount obj) -> exact-nonnegative-integer?
(jobject->alist obj) -> (listof (cons/c symbol? any/c))
(jobject->hasheq obj) -> hash?                ; shallow
(jvalue->jsexpr v) -> jsexpr?                 ; deep conversion to racket/json's representation (order lost)
(jsexpr->jvalue v) -> jvalue?                 ; deep; hash keys sorted
(jmerge obj ...) -> jobject?                  ; shallow, right-biased; a key keeps its first position
(jmerge-deep a b) -> jvalue?                  ; objects merge recursively, everything else: b wins
(in-jobject obj)                              ; sequence of two values: key, value, in order
(jmap proc obj) -> jobject?                   ; proc : key value -> value
(jfilter pred obj) -> jobject?                ; pred : key value -> any
```

- `jobject` is an opaque immutable struct. Lookup is O(1) expected. `equal?` on two jobjects compares them as maps: same key set and `equal?` values, ignoring order. `equal-hash` agrees with that.
- `jobject`s print as `#<jobject {"a":1,"b":2}>` (compact JSON) so test failures are readable.
- A `match` expander `(jobj-pat [key pat] ... maybe-rest)` is provided: each `key` is a literal symbol; matching fails if a listed key is absent; `#:rest id` binds a jobject of the remaining keys; a clause `[key pat #:default expr]` matches `pat` against `expr` when the key is absent.

## 2. JSON text

```racket
(string->jvalue str #:who [who 'string->jvalue]) -> jvalue?
(read-jvalue [in (current-input-port)]) -> (or/c jvalue? eof-object?)   ; reads one value; skips leading whitespace
(bytes->jvalue bs) -> jvalue?                  ; UTF-8
(jvalue->string v #:indent [indent #f]) -> string?
(jvalue->bytes v #:indent [indent #f]) -> bytes?
(write-jvalue v [out (current-output-port)] #:indent [indent #f]) -> void?
(struct exn:fail:json exn:fail (position))
```

Parsing follows `JSON.parse`: RFC 8259 grammar; duplicate keys keep the last value at the first key's position; numbers without fraction or exponent that are integers become exact integers, all other numbers become flonums (`1.0` parses to `1.0`, `1e3` to `1000.0`); `-0` parses to `-0.0`; a lone surrogate escape (`\ud800`) is replaced by U+FFFD because Racket strings cannot hold it. Errors raise `exn:fail:json` with the character position.

Writing follows `JSON.stringify` exactly:

- objects write keys in insertion order; `indent` is `#f` (no whitespace at all) or a number of spaces 1 to 10 with the same layout as `JSON.stringify(v, null, n)` (empty object `{}`, empty array `[]`);
- strings escape `"`, `\`, U+0008, U+000C, U+000A, U+000D, U+0009 with their short forms, other characters below U+0020 as `\u00xx` in lowercase hex, and nothing else (no escaping of `/`, of non-ASCII, or of U+2028/U+2029);
- numbers use the ECMAScript `Number::toString` algorithm: exact integers and integral flonums print without a decimal point (`1.0` prints as `1`, `-0.0` as `0`); magnitudes at or above 1e21 and below 1e-6 use exponent form (`1e+21`, `1e-7`); other flonums print as the shortest decimal that round-trips;
- exact rationals that are not integers are converted to flonums first; NaN and infinities write as `null`;
- a value that is not a jvalue raises `exn:fail:contract`.

## 3. Equality

```racket
(deep-equal? a b #:strict? [strict? #f]) -> boolean?
```

Structural equality over jvalues. Objects compare as maps regardless of key order. With `strict?` false, `'null` equals an absent key's stand-in `(void)` and an object key whose value is `'null` equals the key being absent, mirroring cosmokit's loose `deepEqual` treatment of `null` and `undefined`; with `strict?` true they differ. Numbers compare with `=` (so `1` equals `1.0`), and `-0.0` equals `0.0`.

## 4. Text length units

```racket
(utf16-length str) -> exact-nonnegative-integer?           ; JavaScript's str.length
(utf16-substring str start [end]) -> string?               ; JavaScript's str.slice for non-negative indexes; a cut inside a surrogate pair drops the half pair
(utf16-truncate str max-units) -> string?                  ; longest prefix of at most max-units UTF-16 units that does not split a pair
(utf8-length str) -> exact-nonnegative-integer?            ; Buffer.byteLength(str, 'utf8')
(utf8-truncate str max-bytes) -> string?                   ; longest prefix of at most max-bytes UTF-8 bytes that does not split a character
(code-point-length str) -> exact-nonnegative-integer?      ; [...str].length
(js-string<? a b) -> boolean?                              ; JavaScript's default string ordering (by UTF-16 code units)
(js-number->string n) -> string?                           ; String(n)
```

## 5. Tests

`raco test racket/cordis-data` covers every bullet above, including: key order through read, update and write; round trips of the number cases listed; escaping; indentation layouts; equality ignoring order; the match expander; and the length helpers on strings with astral characters. A table of at least 60 `(value . expected-text)` pairs generated from Node (`node -e` with `JSON.stringify`) is checked in as test data together with the script that produced it, so the suite itself needs no Node.
