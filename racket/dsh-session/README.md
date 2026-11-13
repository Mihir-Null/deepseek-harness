# dsh-session

The session event log of the Racket port: the append-only log of typed events, the surface fold that decides which events are model-visible, the message history derived from it, the request-header and tool-history folds, fork seeds, tail repair, and the in-memory store service `sessions`.

The interface is specified by the [dsh-session contract](../../docs/racket/contracts/dsh-session.md). Coding rules are in [CONVENTIONS.md](../../docs/racket/CONVENTIONS.md).

## Correspondence with dsh

| dsh package | Covered by |
|---|---|
| `packages/core/session` (`@deepseek-ai/dsh-session`) | the whole collection |
| `packages/core/scope` (`@deepseek-ai/dsh-scope`), the scope tag, parent relation and scope-filtered dispatch | `dsh-session/scope-core`, re-exported by `dsh-tools/scope` |
| `packages/util/values` (`@deepseek-ai/dsh-util-values`), the lossless JSON check | `dsh-session/lossless` |

Every durable name is the dsh name: event type tags, data keys and their order, header keys, error messages, and the four model-visible recovery texts. A log written by one implementation is read by the other.

## Layout

The package has two work units. The data plane needs only `cordis-data`; the session object and the store also need the `cordis` kernel.

| Module | Unit | Holds |
|---|---|---|
| `lossless.rkt` | data plane | `lossless-json?`, `snapshot-json` |
| `types.rkt` | data plane | `absent`, scalar contracts, the session header, the event envelope, event inputs, plugin records, message predicates, `exn:fail:session`, `define-session-event` |
| `events.rkt` | data plane | the 14 core event declarations and the constant sets of type names |
| `surface.rkt` | data plane | the surface state and fold, the event-local checks, `derive-event-message`, `derive-messages` |
| `request-header.rkt` | data plane | `canonical-header`, `header-equal?`, `fold-request-header` |
| `tool-history.rkt` | data plane | the tool-history fold |
| `repair.rkt` | data plane | `open-turn-closers`, `interrupted-turn-closers`, the tool-call recovery tracker |
| `fork.rkt` | data plane | `build-fork-seed` |
| `seq-ranges.rkt` | data plane | the range encoding of `sourceEventSeqs` |
| `private/` | data plane | shared helpers: JavaScript-shaped readers, the header, the envelope, declarations, shape checks, the name sets, the expansion-time half of `define-session-event` |
| `scope-core.rkt`, `session.rkt`, `store.rkt`, `plugin.rkt`, `plugins.rkt`, `main.rkt` | object and store | the scope routing core, the session object, the `sessions` service and its plugin |

## Declaring an event type

`define-session-event` states a type tag, the data fields in the order dsh writes them, and one flat contract per field. It defines the declaration value, a constructor that is also a `match` pattern, a predicate and one accessor per field.

```racket
(require dsh-session/types dsh-session/events racket/match cordis-data)

(define-session-event model/selection
  #:type "model/selection"
  #:fields ([provider string?]
            [model string?]
            [reasoning-effort "reasoningEffort" string? #:optional]))

(define input (model/selection #:model "m" #:provider "p"))
(jvalue->string (session-event-input-data input))   ; "{\"provider\":\"p\",\"model\":\"m\"}"
(model/selection-reasoning-effort input)            ; #f, the key is absent

(define event (make-session-event "model/selection" 0 1 (session-event-input-data input)))
(match event
  [(model/selection #:provider provider) provider]) ; "p"
```

The constructor of a surface-eligible type also takes `#:surface-op` and, except for `assistant/message`, `#:sources`. A declaration with `#:ignorable` is a plugin record type; its constructor returns a `plugin-record-input`.

## Tests

```sh
raco link -n dsh-session racket/dsh-session   # once, so the collection resolves
raco make racket/dsh-session/*.rkt racket/dsh-session/tests/*.rkt
raco test racket/dsh-session
```

The suite needs no network and no API key. Three tests read files of the dsh repository and are skipped, with a line on standard error, when the package is used outside it:

- `tests/events-test.rkt` rebuilds every event line of `snapshots/session/fs-read/session.v4.jsonl` through `make-session-event` and through the generated constructors and requires the same text;
- `tests/corpus-test.rkt` runs every recorded current-format session under `snapshots/session/` through the envelope reader, the event-local checks, the core declarations, the surface fold, the request folds, tail repair and fork seeds;
- `tests/repair-test.rkt` and `tests/catalog-test.rkt` compare the four recovery texts and the known type names with the TypeScript source.

`tests/support/log.rkt` holds the fixtures: message builders, `inputs->events`, `raw-event` for envelopes with arbitrary metadata, and `sample-log`, a small valid log built through the constructors.
