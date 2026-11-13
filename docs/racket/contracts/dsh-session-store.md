# Interface contract: `dsh-session-store`

This is the binding interface for `racket/dsh-session-store/`. It covers the durable session plane: the `sessionPersistence` seam and its JSONL backend, the Session format library with the codecs of generations 0 to 4 and the four migration edges, the projection registry and its durable cache, titles, stats, the turn outline, telemetry capture, the checkpoint policy, the DeepSeek log upload field, the working directory service and its tool, the session query service with its SQLite full-text index, and session log export. Sources: [recon 07](../recon/07-session-persistence.md) (cited as R7 with a section name or "Algorithms N"), `packages/session/*` and `packages/session-query/*` at commit `e8f7b93a3`, `docs/session-format-status.md`, `docs/persistence-catalog.md`. When this document and the TypeScript disagree about behaviour, the TypeScript is right and this document gets fixed. When they disagree about names and argument order of the Racket surface, this document is right. Read [dsh-session.md](dsh-session.md), [dsh-llm.md](dsh-llm.md), [dsh-tools.md](dsh-tools.md) and [dsh-agent.md](dsh-agent.md) first; this contract uses their vocabulary without repeating it (`absent`, `session-event`, `define-session-event`, `define-jrecord`, `projection-definition`, cancel events, `define-tool`, `agent-inject!`).

Package: directory `racket/dsh-session-store/`, collection `dsh-session-store`, `(define deps '("base" "db-lib" "cordis" "cordis-data" "cordis-schema" "dsh-util" "dsh-session" "dsh-llm" "dsh-tools" "dsh-agent"))`, `(define build-deps '("rackunit-lib" "dsh-test-support"))`. From the base distribution it uses `ffi/unsafe`, `ffi/unsafe/port`, `racket/generic`, `racket/match`, `file/gzip`, `net/base64` and the `sha256-bytes` of `racket/base`; from `db-lib` only `db/base` and `db/sqlite3`. It loads two system libraries through the FFI: the C library (`fsync`, `link`, `flock`, `open`, `close`) and, when a root uses Zstandard, `libzstd` version 1. No third-party Racket package.

Terms. A *generation* is one physical file of a session in one format version. A *format event* is a jobject with the envelope keys of its generation; inside the format library events are format events, not `session-event` values, because historical envelopes differ from the current one. *Current* means format version 4. "Raise" without a struct name means the error struct that the section's Data table assigns to the dsh error class.

## Scope

Every package of `packages/session` (22) and `packages/session-query` (3).

| dsh package | npm name | Status |
|---|---|---|
| `session/session-persistence` | `@deepseek-ai/dsh-session-persistence` | native: `dsh-session-store/persistence`. The service value also implements `gen:session-persistence-port` of `dsh-agent/ports`. |
| `session/session-persistence-jsonl` | `@deepseek-ai/dsh-session-persistence-jsonl` | native: `dsh-session-store/jsonl`. Not applicable in this port: `win32.ts` (named semaphore, `MoveFileExW`) and `zstd-private-decoder.ts` (a Node-private synchronous decoder). Adapted: the publication verifier runs on a `blocking` thread, not a Worker Thread (rule J27). |
| `session/session-format` | `@deepseek-ai/dsh-session-format` | native: `dsh-session-store/format`. Stages are pure state machines (Racket design notes). |
| `session/session-format-catalog` | `@deepseek-ai/dsh-session-format-catalog` | native: `dsh-session-store/format/catalog`. The generated assembly (`generated.ts`) is a hand-written module. |
| `session/session-format-v0-to-v1` | `@deepseek-ai/dsh-session-format-v0-to-v1` | native: `dsh-session-store/format/v0-v1` |
| `session/session-format-v1-to-v2` | `@deepseek-ai/dsh-session-format-v1-to-v2` | native: `dsh-session-store/format/v1-v2` |
| `session/session-format-v2-to-v3` | `@deepseek-ai/dsh-session-format-v2-to-v3` | native: `dsh-session-store/format/v2-v3` |
| `session/session-format-v3-to-v4` | `@deepseek-ai/dsh-session-format-v3-to-v4` | native: `dsh-session-store/format/v3-v4` |
| `session/session-projection` | `@deepseek-ai/dsh-session-projection` | native: `dsh-session-store/projection`. It replaces `racket:session-projections` of `dsh-agent` behind `gen:projection-port`. Not reproduced: the deprecated `stateOf(session, key)` and `cachedSnapshot` of the registry, and the callable thenable that `register` returns. |
| `session/session-projection-cache` | `@deepseek-ai/dsh-session-projection-cache` | native over the storage-domain port (`dsh-session-store/ports`) |
| `session/session-title` | `@deepseek-ai/dsh-session-title` | native: `dsh-session-store/title`. `client.ts` is not applicable (ADR 0010). |
| `session/session-title-llm` | `@deepseek-ai/dsh-session-title-llm` | native library: `dsh-session-store/title-llm`. No plugin, as in dsh. |
| `session/session-title-first-prompt-llm` | `@deepseek-ai/dsh-session-title-first-prompt-llm` | native |
| `session/session-stats` | `@deepseek-ai/dsh-session-stats` | native: `dsh-session-store/stats`. `client.ts` not applicable. |
| `session/session-turn-outline` | `@deepseek-ai/dsh-session-turn-outline` | native: `dsh-session-store/turn-outline`. `client.ts` not applicable. |
| `session/session-telemetry` | `@deepseek-ai/dsh-session-telemetry` | native library: `dsh-session-store/telemetry` |
| `session/session-telemetry-otel` | `@deepseek-ai/dsh-session-telemetry-otel` | adapted: the backend, its modes, its config checks and its capture rules are native; the OTLP reporter is reached through the `otel` port, whose provider is `dsh-platform`. Without an `otel` service the plugin stays pending, as in dsh. |
| `session/session-checkpoint-policy` | `@deepseek-ai/dsh-session-checkpoint-policy` | native |
| `session/session-log-deepseek` | `@deepseek-ai/dsh-session-log-deepseek` | native: `dsh-session-store/log-deepseek` |
| `session/working-directory` | `@deepseek-ai/dsh-working-directory` | native over the directory port (`fs` service of `dsh-fs`) |
| `session/tool-working-directory` | `@deepseek-ai/dsh-tool-working-directory` | native |
| `session/message-quotes` | `@deepseek-ai/dsh-message-quotes` | The host entry is a no-op plugin and is native. The client half (quote selection, blockquote rendering) is not applicable in this port: the browser UI belongs to `dsh-web` (ADR 0010). |
| `session-query/session-query` | `@deepseek-ai/dsh-session-query` | native: `dsh-session-store/query`. Abstract in dsh; here a library plus the generic interface that the SQLite engine implements. |
| `session-query/session-query-sqlite` | `@deepseek-ai/dsh-session-query-sqlite` | native through `db/sqlite3` with dsh's schema |
| `session-query/session-log-export` | `@deepseek-ai/dsh-session-log-export` | The host half is native: the `/export` command, the two HTTP routes (through the command and route ports), the ZIP stream, the Markdown formatter. The browser half (`src/client/*`) is not applicable. |
| (none) | `racket:session-fixture-decoder` | Racket-only. Provides the optional service key `racket:sessionFixtureDecoder` that the `llm-replay` plugin of `dsh-llm` reads ([WAVE3.md](WAVE3.md), Racket-only extensions; dsh-llm rule I2), so that recorded fixtures of generations 0 to 3 replay through this package's format catalog. |

Not reproduced anywhere in this package, and why: deep-freeze and `structuredClone` passes (jvalues are immutable); the tsx worker bootstrap (`worker.ts`); v8-coverage guards; Zod and Schemastery runtime types (contracts and explicit validators); the typert decorators of the query service (the remote surface is `dsh-web`'s).

## Modules

| Module | Provides |
|---|---|
| `dsh-session-store` (`main.rkt`) | re-exports `persistence`, `projection`, `title`, `working-directory`, `query`: what a plugin that consumes this package requires |
| `dsh-session-store/ports` | generic interfaces for services of sibling packages: `gen:storage-domain-port`, `gen:storage-domain`, `gen:kv-table`, `domain-spec`, `gen:directory-port`, `gen:session-log-reporter-port`, `gen:attachment-read-port`, `gen:command-port`, `gen:fetch-route-port`, `http-request`, `http-response` |
| `dsh-session-store/format` | the format library: errors, JSON guards, generation filenames, `format-artifact`, `event-run`, `migration-stage`, `migration`, `format-codec`, `make-format-chain`, `make-format-catalog`, the restore procedures |
| `dsh-session-store/format/validators` | the validator combinators and `define-frozen-inventory` used by the four edge modules |
| `dsh-session-store/format/v0-v1` | `released-v0-codec`, `released-v1-codec`, `migration-v0->v1`, the frozen payload and relationship validators of generations 0 and 1 |
| `dsh-session-store/format/v1-v2` | `released-v2-codec`, `migration-v1->v2`, `encode-source-event-ranges`, `restore-released-v2-artifact` |
| `dsh-session-store/format/v2-v3` | `released-v3-codec`, `migration-v2->v3`, `restore-released-v3-artifact`, `assert-released-v3-header` |
| `dsh-session-store/format/v3-v4` | `released-v4-codec`, `migration-v3->v4`, `make-migration-v3->v4`, `assert-v4-row-admission`, `assert-released-v4-relationships`, `restore-released-v4-artifact`, `assert-released-v4-header`, `released-v3-event-types`, `historical-child-catalog-source` |
| `dsh-session-store/format/catalog` | `session-format-catalog`, `make-session-format-catalog/children`, `historical-session-format-catalog`, `current-session-message-projections`, `validate-installed-current-artifact` |
| `dsh-session-store/fixture-decoder` | `decode-session-fixture` |
| `dsh-session-store/persistence` | the seam: `gen:session-persistence`, `gen:session-handle`, the two base structs, `persistence-snapshot`, the error structs, the storage-contract helpers, the `sessionPersistence` service definition |
| `dsh-session-store/persistence/testing` | `make-memory-persistence`, `persistence-contract-tests`, `live-write-contract-tests` (the two shared seam suites as procedures over a backend factory) |
| `dsh-session-store/jsonl` | `make-jsonl-persistence`, `install-jsonl-tracker!`, path helpers (`encode-segment`, `project-key`, `session-dir`, `generation-log-path`, `log-path`, `generation-log-filename`, `parse-generation-log-filename`), `header-line`, `event-line`, `event-lines`, `make-log-scanner` and its operations |
| `dsh-session-store/jsonl/zstd` | `scan-zstd-frames`, `zstd-available?`, `zstd-compress-frame`, `zstd-decompress-frame`, `zstd-decompress-prefix` |
| `dsh-session-store/jsonl/durable-io` | `fsync-port`, `fsync-directory`, `link-file`, `try-flock-exclusive`, `file-identity`, `read-stable-file`, `write-synced-new-file`, `truncate-and-sync` |
| `dsh-session-store/projection` | the `sessionProjections` service definition, `make-projection-registry`, `checked-projection-definition`, `make-projection-definition`, the handle and registry procedures, `projection-snapshot`, `same-value?` |
| `dsh-session-store/projection-cache` | the `sessionProjectionCache` service definition and procedures, `projection-cache-domain-spec`, the record validators |
| `dsh-session-store/title` | the `sessionTitle` service definition and procedures, `session/title`, `title-projection`, `fold-session-title`, `normalize-session-title`, `fallback-session-title`, `truncate-title-utf8`, `title-provider`, `exn:fail:session-title-invalid` |
| `dsh-session-store/title-llm` | `execute-session-title-llm`, `resolve-session-title-llm-config`, `session-title-llm-config-fields`, `session/title-llm-request`, `session-title-timeout-code` |
| `dsh-session-store/stats` | `session-stats-projection` |
| `dsh-session-store/turn-outline` | `turn-outline-projection`, `turn-outline-preview` |
| `dsh-session-store/telemetry` | the `sessionTelemetry` service definition, `gen:session-telemetry-backend`, `make-telemetry-coordinator`, `telemetry-capture-session!`, the `session-telemetry/record` event, `telemetry-record` |
| `dsh-session-store/log-deepseek` | the `sessionLogDeepSeek` service definition, `log-deepseek-register-exclusion!`, `accepted-through`, `session-log-deepseek/delivery-accepted`, the wire builders |
| `dsh-session-store/working-directory` | the `workingDirectory` service definition and procedures, `working-directory/change`, the `working-directory/access` event, `working-directory-projection`, the error constructor and codes |
| `dsh-session-store/query` | the `sessionQuery` service definition, `gen:session-search`, the engine procedures, records, filters, `extract-session-event-text`, `build-session-event-records`, `build-session-event-search-documents`, `read-cold-session-log`, `assert-session-headers-compatible`, the error constructor and codes |
| `dsh-session-store/query-sqlite` | `make-sqlite-session-query`, `open-search-database`, the query builders, `make-snippet`, constants |
| `dsh-session-store/export` | `serialize-session-log`, `read-session-log-text`, `flush-live-session-log`, `session-log-zip-entries`, `write-session-log-zip`, `session-log-zip-filename`, `format-session-markdown`, `make-zip-writer` and its operations, route paths and constants |
| `dsh-session-store/plugin/<name>` | sixteen plugin modules, each providing `plugin` (Plugins) |
| `dsh-session-store/plugins` | `plugin-table` |

Private modules, suggested: `private/lane.rkt` (the serial lane of rule J10), `private/jsonl-handle.rkt`, `private/jsonl-tracker.rkt`, `private/jsonl-generation.rkt` (stable snapshots, staging, verification, publication), `private/jsonl-catalog-facts.rkt`, `private/zstd-ffi.rkt`, `private/libc-ffi.rkt`, `private/v0-payloads.rkt`, `private/v0-relationships.rkt`, `private/v4-relationships.rkt`, `private/title-work.rkt`, `private/query-corpus.rkt`, `private/query-observation.rkt`, `private/query-tracing.rkt`, `private/sqlite-reconcile.rkt`, `private/zip.rkt`, `private/markdown-scan.rkt`. Work units names the modules that cross unit lines.

## Data

### Errors

Where dsh throws a plain `Error` this package raises `exn:fail` with the same message; where dsh throws `TypeError` it raises `exn:fail:contract` with the same message; where dsh throws `AggregateError` it raises `exn:fail:persistence:aggregate`. The classes below have their own structs because consumers branch on them. Messages are in `session-persistence/src/errors.ts` and are copied verbatim (R7 Services, "Errors").

```racket
exn:fail:persistence-not-found                                   ; re-export of dsh-agent/ports; SessionPersistenceNotFoundError; field session-id
(struct exn:fail:persistence exn:fail (session-id))              ; common parent of the five below
(struct exn:fail:persistence:already-exists exn:fail:persistence ())    ; session "<id>" already exists
(struct exn:fail:persistence:already-owned exn:fail:persistence ())     ; session "<id>" is already owned by an active write handle
(struct exn:fail:persistence:read-only exn:fail:persistence ())         ; session "<id>": <op> is not available on a read handle
(struct exn:fail:persistence:ownership-lost exn:fail:persistence ())    ; session "<id>": write ownership was lost; close this handle and reopen (declared, never raised by the JSONL backend)
(struct exn:fail:persistence:handle-closed exn:fail:persistence ())     ; session "<id>": <op> on a closed handle
(struct exn:fail:persistence:corruption exn:fail (cause))               ; SessionPersistenceCorruptionError
(struct exn:fail:persistence:format-unsupported exn:fail (location))    ; SessionFormatUnsupportedError; location : (or/c #f session-location?)
(struct exn:fail:persistence:aggregate exn:fail (errors))               ; errors : (listof any/c)
(struct session-location (kind path) #:transparent)                     ; kind : string?, "jsonl" for this backend; path : string?
(session-format-version-refusal id version) -> string?                  ; the two refusal texts of errors.ts:131-137
(struct exn:fail:session-format exn:fail ())                            ; SessionFormatError
(struct exn:fail:session-format:unsupported exn:fail:session-format ()) ; SessionFormatUnsupportedMigrationError
(struct exn:fail:session-title-invalid exn:fail ())                     ; SessionTitleInvalidError
(struct exn:fail:session-title-llm exn:fail (code))                     ; a model finish of kind error or aborted (rule T12)
(struct exn:fail:timeout-reason exn:fail (code timeout-ms))             ; dsh TimeoutReason; message "<code> after <ms>ms"
```

Two coded errors are `exn:fail:harness` values of `dsh-util`, built only through these constructors so that no call site depends on that struct's field list:

```racket
(make-working-directory-error message code #:cause [cause #f]) -> exn:fail:harness?   ; name "WorkingDirectoryError"
working-directory-error-codes      ; '("WORKING_DIRECTORY_INVALID" "WORKING_DIRECTORY_NOT_FOUND" "WORKING_DIRECTORY_UNAVAILABLE")
(make-session-query-error message code #:cause [cause #f]) -> exn:fail:harness?       ; name "SessionQueryError"
(session-query-error? v [code #f]) -> boolean?                    ; with code, also checks the code
session-query-error-codes          ; the seventeen codes of session-query/src/config.ts:18-35, as strings
```

### Persistence values

```racket
(struct persistence-snapshot (header format-status revision event-count size-bytes location) #:transparent)
;; header : session-header?            format-status : (or/c 'current 'migration-required #f)
;; revision : string?                  event-count, size-bytes : (or/c exact-nonnegative-integer? #f)
;; location : (or/c session-location? #f)
(session-access? v)                    ; 'read or 'write
(session-event-state? v)               ; 'detached or 'shared-frozen
```

A revision is an opaque token: equal revisions from the same service instance and session id may be treated as an unchanged log; unequal revisions promise nothing. `event-count` is never filled by the JSONL backend. The two event states are equivalent in Racket; the value is kept because `sessions-prepare` takes it.

### The v4 physical log

Header record, the first line, a jobject with these keys in this order; optional keys are omitted when absent and never `null` (`session-format-v1-to-v2/src/codec.ts:155-172`, `session-format-v3-to-v4/src/codec.ts:33-36`):

| Key | Contract | Presence |
|---|---|---|
| `type` | `"session"` | always |
| `version` | `4` | always |
| `id` | `string?` | always |
| `createdAt` | non-negative safe integer | always |
| `cwd` | absolute path string | optional |
| `parentSession` | `string?` | optional |
| `isSeeded` | boolean | always |
| `origin` | `"subagent"` | optional |
| `delegationDepth` | non-negative safe integer; `0` when the logical header has none | always |
| `agentPreset` | `string?` | optional |

Any other key is corruption. `(header-line header [inherited-event-count #f]) -> jobject?` in `dsh-session-store/jsonl` builds it from a `session-header?`; it raises `seeded session header requires an inherited event count` and `unseeded session header inherited event count must be 0` (`format.ts:119-134`). The header line does not store the inherited cut; the cut is the seq of the last `session/end-seed` event whose `data.inherited` is `true`.

Event row: `(event-line event) -> string?` is `(jvalue->string (encode-source-event-ranges (session-event->jvalue event)))`. `encode-source-event-ranges` replaces the value of `sourceEventSeqs`, when the key is present, by `(encode-seq-ranges seqs)` of `dsh-session`, keeping the key's position. The key order of a row is therefore the order of the event's own JSON form, which for events appended by the Racket harness is the order dsh's writers use (dsh-session, "session-event"). Envelope keys allowed in a row: `type`, `seq`, `time`, `data`, `ignorable`, `sourceEventSeqs`, `surfaceOp`; no others (`codec.ts:19-22`). `(event-lines events)` joins rows with `"\n"` without a trailing newline.

### Format library values (`dsh-session-store/format`)

```racket
(struct format-artifact (header inherited-event-count events) #:transparent)
;; header : jobject? (logical header with a version key)   events : (listof jobject?) dense from seq 0
(struct event-run (run-type first-seq event-count fields expand))
;; run-type : symbol?   fields : immutable hasheq of run-specific values   expand : (-> (listof jobject?))
(format-item? v)                                   ; a format event (jobject?) or an event-run?
(struct migration-stage (state step finish header-inherited-event-count))
;; step : (-> any/c format-item? (values any/c (listof format-item?)))       state item -> next state, emitted items
;; finish : (-> any/c (values exact-nonnegative-integer? (listof format-item?)))   state -> target cut, trailing items
;; header-inherited-event-count : (or/c exact-nonnegative-integer? #f)        a cut the stage declares before it runs
(struct migration (name from-version to-version migrate-header make-stage validate-target-header))
(struct format-codec (version decode-header make-decoder))
(struct artifact-decoder (header header-inherited-event-count stage))        ; stage consumes raw row jvalues
(struct current-encoder (encode-header encode-event))
(struct header-read-result (status stored-version target-version header reason) #:transparent)
;; status : 'current 'migration-required 'unsupported 'malformed; header only for the first two; reason only for the last two
```

The one run type is `'released-assistant-chunks`, a packed chunk row of generations 0 and 1; its `fields` are `'turn`, `'step`, `'last-seq`, `'last-time` and `'stream` (the compact stream record jobject), and `expand` yields one `assistant/chunk` format event per member (`session-format-v0-to-v1/src/codec.ts:240-322`).

Historical physical headers and rows are R7 "Historical generations" and the codec files; their key sets are given in Behaviour C.

### Session events declared here

Declared with `define-session-event`; all are log-only (not surface-eligible, not ignorable) and all four names are in `known-session-event-types`.

| Racket id | Module | dsh type | Data fields in write order (JSON key: contract) |
|---|---|---|---|
| `session/title` | `title` | `session/title` | `title`: non-empty `string?`; `messageSeqs` (`message-seqs`): `(listof session-seq?)`; `source`: `title-source?` |
| `session/title-llm-request` | `title-llm` | `session/title-llm-request` | `titleProvider` (`title-provider`): `string?`; `messageSeqs`: `(listof session-seq?)`; `route`: jobject `{provider, model}`; `system`: `string?`; `messages`: `(listof message-jvalue?)`; `maxTokens` (`max-tokens`): positive integer; `reasoningEffort?` (`reasoning-effort`): `string?` |
| `session-log-deepseek/delivery-accepted` | `log-deepseek` | same | `sessionId` (`session-id`): `string?`; `sessionFormatVersion?` (`session-format-version`): non-negative safe integer, absent meaning 0; `throughSeq` (`through-seq`): `session-seq?` |
| `working-directory/change` | `working-directory` | `working-directory/change` | `cwd`: absolute path `string?` |

`title-source?` is one of `{kind: "fallback"}`, `{kind: "provider", provider, model?: {provider, model}}`, `{kind: "user"}`, keys in that order. `messageSeqs` is empty exactly when the source kind is `"user"`. The Racket writer always writes `sessionFormatVersion`.

Message source kinds introduced here (open union of `dsh-llm`): `{kind: "working-directory"}` and `{kind: "dsh-session-title-llm"}`.

### Projection values

```racket
(struct checked-projection-definition projection-definition (state-ok? view-ok?))
(make-projection-definition #:key key #:state-version n #:init init #:apply apply #:view [view #f]
                            #:summary? [summary? #t] #:state-ok? [state-ok? lossless-json?]
                            #:view-ok? [view-ok? lossless-json?]) -> checked-projection-definition?
(struct projection-snapshot (as-of-seq values) #:transparent)   ; as-of-seq : -1 or a session-seq?; values : jobject? keyed by projection key
(projection-checkpoint? v)                                        ; jobject from key to {ver, seq, val}
(same-value? a b) -> boolean?                                     ; JavaScript Object.is over jvalues (rule P1)
```

`projection-definition` is the struct of `dsh-llm/ports`. `state-ok?` stands in for dsh's `stateSchema.parse` and `view-ok?` for `viewSchema.parse`; a plain `projection-definition` is treated as having `lossless-json?` for both. A checkpoint row is the jobject `{ver, seq, val}` in that key order: `ver` a non-negative integer, `seq` an integer at least `-1`, `val` lossless JSON.

Projection units registered by this package. States are jvalues with the keys in the order shown; `null` is `'null`.

| Binding | Key | `stateVersion` | State | Wire view | In summaries |
|---|---|---|---|---|---|
| `title-projection` | `title` | 1 | a non-empty string or `null`; initially `null` | the state | yes |
| (private to `title`) | `titleInput` | 3 | `{first: {seq, text} or null, count, lastSeq}`; initially `{first: null, count: 0, lastSeq: null}` | none | n/a |
| `session-stats-projection` | `sessionStats` | 1 | `{turns, steps, llmMs, toolMs, ttftMs, ttftSteps, decodeMs, decodeTokens, lastTurn, openStep, pendingCalls}`; counters start at 0, `lastTurn` and `openStep` at `null`, `pendingCalls` at `{}`; `openStep` is `{turn, step, startTime, firstTokenTime}` | the first eight keys, in that order | no |
| `turn-outline-projection` | `turnOutline` | 2 | `{turns: [{turn, seq, prompt, response}…], draft}`; initially `{turns: [], draft: ""}` | `turns` | no |
| `working-directory-projection` | `workingDirectory` | 1 | an absolute path string or `null`; initially the header `cwd` or `null` | the state | yes |

State checks (`state-ok?`), from the Zod schemas in the sources: `title` a non-empty string or `null`; `titleInput` exactly those three keys, `first` exactly `{seq, text}`, and either all empty (`null`, 0, `null`) or `first` and `lastSeq` present with `count > 0` and `first.seq <= lastSeq`; `sessionStats` the eleven keys with non-negative numbers (integers for `turns`, `steps`, `ttftSteps`, `lastTurn`, the two coordinates of `openStep`); `turnOutline` exactly `turns` and `draft`, entries exactly the four keys with `prompt` at most 50 and `response` and `draft` at most 120 UTF-16 units and turns strictly increasing; `workingDirectory` a non-empty absolute path or `null`.

### Projection cache record

Storage domain `session_projcache`, version `7`, compatible versions `3`, `4`, `5`, `6`, layout `per-record`, invalid records `backup-and-skip`, one table `sessions` keyed by session id (`session-projection-cache/src/spec.ts`). The record value is the jobject

```text
{"identity": {"formatVersion": n, "createdAt": n, "cwd": s, "isSeeded": b, "inheritedEventCount": n},
 "rows": {"<key>": {"ver": n, "seq": n, "val": <lossless JSON>}, …}}
```

with `cwd` omitted when the header has none. A stored record may lack `formatVersion`, `isSeeded` and `inheritedEventCount` (older writers); the validator accepts that. The document around the record (`{"version": 7, "record": …}`) and its file location `$DSH_HOME/storages/session_projcache/sessions/<id>.json` belong to the storage-domain provider of `dsh-platform`; this package hands it the spec and reads and writes record values only.

### Titles

```racket
(title-snapshot? v)        ; jobject {title, messageSeqs, source, eventSeq, updatedAt}
(struct title-provider (id automatic generate))
;; id : non-empty string?   automatic : (or/c 'first-prompt 'all-prompts)   generate : (-> title-request? title-result?), may wait
(struct title-request (session messages route current-title cancel))
;; messages : (listof jobject?) each {seq, text}   route : (or/c #f jobject?) {provider, model}
;; current-title : (or/c #f title-snapshot?)       cancel : evt?
(struct title-result (title message-seqs model))   ; model : (or/c #f jobject?) {provider, model}
(struct title-llm-prepared (system input message-seqs select-reasoning-effort))
;; select-reasoning-effort : (-> jobject? (or/c string? #f)), given the resolved model info
(struct title-llm-response (blocks finish model))  ; finish : jobject with kind "stop", "tool-calls" or "max-tokens"
```

### Telemetry record

A jobject, declared with `define-jrecord` as `telemetry-record`, keys in this order: `sourceEvent?` (`{sessionId, envelope}`, where `envelope` is the event's JSON form without `data`), `channel` (`"ledger"` or `"ops"`), `time`, `severity` (`"info"`, `"warn"`, `"error"`), `attributes` (a jobject from attribute name to string or number), `body` (any jvalue). Attribute names and their order are in rule L3.

### `dsh_session_log` extension value

The jobject `{version: 1, sessionFormatVersion, session, afterSeq, throughSeq, events}` in that key order. `session` is `{version, id, createdAt, cwd?, parentSession?, seedLength?, origin?, delegationDepth?, agentPreset?}` with `seedLength` present only for a seeded session. Each member of `events` has the keys `seq, time, data, ignorable?, type, surfaceOp?, sourceEventSeqs?` in that order, which is the order `wireEvent` builds (`session-log-deepseek/src/index.ts:79-112`); `sourceEventSeqs` is the expanded number list, never range-encoded.

### Query values

Results cross to user interfaces as JSON, so they are jobjects declared with `define-jrecord` in `dsh-session-store/query`; events inside them are `session-event?` values and headers are `session-header?` values, converted at the wire by `dsh-web`. Keys, in order (`session-query/src/types.ts`):

| jrecord | Keys |
|---|---|
| `session-record` | `header`, `live`, `persisted`, `formatStatus?` (`"current"` or `"migration-required"`) |
| `session-log-snapshot` | `session`, `inheritedEventCount`, `events` |
| `session-surface-snapshot` | `session`, `inheritedEventCount`, `capturedThroughSeq` (a seq or `null`), `events` |
| `session-event-record` | `sessionId`, `seq`, `type`, `time`, `surface` (`"current"`, `"shadowed"`, `"log-only"`) |
| `session-event-search-document` | the keys of `session-event-record`, then `text` |
| `session-lineage-node` | `session`, `descendants` |
| `session-lineage-trace` | `target`, `ancestors`, `descendants`, `complete`, then `root` when complete, else `unresolvedParentId` |
| `session-event-trace` | `target`, `replacedBy?`, `replacementChain`, `replacedEventSeqs`, `sourceEventSeqs`, `derivedEventSeqs`; the observation form has `session` first |
| `session-event-window` | `session`, `inheritedEventCount`, `target`, `events`, `startSeq`, `endSeq` |
| `session-title-observation` | `session`, `title?` |
| `session-search-hit` | `header`, `live`, `persisted`, `bestMatch` |
| `session-event-search-hit` | the keys of `session-event-record`, then `snippet` |
| `session-search-page` | `items`, `nextCursor?`; the event page has `session` before them |

A session filter is a jobject or hash with `kind` one of `"id"` (`values`: strings), `"cwd"` (`values`: strings or `null`), `"created-at"` (`from?`, `to?`), `"parent"` (`values`: strings or `null`), `"availability"` (`values`: `"live"`, `"persisted"`). An event filter has `kind` one of `"seq"`, `"time"` (ranges), `"type"`, `"surface"` (`values`), `"text"` (`text`). A metadata filter is an event filter other than `"text"`. Requests are keyword arguments (Services).

```racket
(session-observation? v) -> boolean?                              ; opaque; a lease on one consistent cut of a session
(session-observation-source obs) -> (or/c 'live 'prepared)
(session-observation-header obs) -> session-header?
(session-observation-inherited-event-count obs) -> session-log-offset?
(session-observation-events obs) -> (listof session-event?)      ; materialised on first use for a live source
(session-observation-cursor obs) -> exact-integer?                ; -1 or the last seq of the cut
(session-observation-revision obs) -> (or/c string? #f)           ; the persistence revision of a prepared source
(session-observation-projections obs) -> (or/c projection-snapshot? #f)
(session-observation-release! obs) -> void?                       ; idempotent; dsh [Symbol.dispose]
(session-observation-retain obs) -> session-observation?          ; a second lease; raises session observation "<id>" is disposed after release
(struct cold-session-log (event-state header inherited-event-count events) #:transparent)
(struct title-observation-result (session-id status value reason) #:transparent)   ; status : 'fulfilled or 'rejected
```

### SQLite index

`application_id` `#x44534851`, `user_version` `8`. The DDL is `session-query-sqlite/src/schema.ts:93-150`, executed verbatim: the persistent tables `search_state` and `persisted_sessions` (both `STRICT`), the FTS5 table `persisted_docs(text, session_id UNINDEXED, seq UNINDEXED, type UNINDEXED, time UNINDEXED, surface UNINDEXED, codepoint_length UNINDEXED, tokenize = 'unicode61')`, and in the temp schema `live_sessions` (the header columns plus `fingerprint`, `persisted`, `generation`) and `temp.live_docs` with the same FTS5 columns. `seed_length` is the inherited event count for a seeded session and `NULL` otherwise. A search cursor is the base64url text (no padding) of the JSON `{version: 1, instance, scope, fingerprint, generation, offset}` in that key order, where `instance` is a random version 4 UUID minted per engine instance and `scope` is `"sessions"` or `"events"`.

### Export values

```racket
(struct zip-entry (path source) #:transparent)
;; source : string? (UTF-8 text) | bytes? | input-port? (a streamed file; the writer closes it)
session-log-filename                      ; "session.v4.jsonl"
session-log-export-path                   ; "/api/session.export"
session-markdown-export-path              ; "/api/session.markdown"
default-session-log-compression-level     ; 6
```

### Ports data (`dsh-session-store/ports`)

```racket
(struct domain-spec (name version compatible-versions invalid-records layout tables) #:transparent)
;; tables : (listof (cons/c string? (-> jvalue? jvalue?)))   table name -> validator that returns the parsed value or raises
(struct http-request (method url headers cancel) #:transparent)       ; method : "GET" or "HEAD"; url : string?; cancel : evt?
(struct http-response (status headers body) #:transparent)
;; headers : (listof (cons/c string? string?))   body : (or/c #f string? bytes? (-> output-port? evt? any)) a writer given the response port and a cancel evt
```

## Services

`x` is a context or a handle for the service; "the caller's context" is `(use-context x)`. A procedure that takes a service value or a handle object first (the generic operations of the seams) registers nothing on any context unless its row says so.

### `sessionPersistence` (key `'sessionPersistence`): the seam

`(define-service session-persistence 'sessionPersistence #:contract session-persistence?)` in `dsh-session-store/persistence` defines `session-persistence-key`, `session-persistence-ref`, `session-persistence-get` and `provide-session-persistence`.

```racket
(define-generics session-persistence
  (session-persistence-create session-persistence header #:inherited-event-count [n #f] #:cancel [cancel #f])  ; -> session-handle?, waits
  (session-persistence-open session-persistence id access #:cancel [cancel #f])                                ; -> session-handle?, waits
  (session-persistence-flush! session-persistence)                                                             ; -> void?, waits
  (session-persistence-stat session-persistence id #:cancel [cancel #f])                                       ; -> (or/c persistence-snapshot? #f), waits
  (session-persistence-list session-persistence #:cancel [cancel #f]))                                         ; -> (listof persistence-snapshot?), waits
(define-generics session-handle
  (session-handle-id session-handle)                                   ; -> session-id?
  (session-handle-header session-handle)                               ; -> session-header?
  (session-handle-inherited-event-count session-handle)                ; -> session-log-offset?
  (session-handle-access session-handle)                               ; -> session-access?
  (session-handle-read session-handle [offset 0] [length #f] #:cancel [cancel #f])   ; -> (values (listof session-event?) session-event-state?), waits
  (session-handle-append! session-handle events #:cancel [cancel #f])  ; events : (listof session-event?); -> void?, waits until durable
  (session-handle-flush! session-handle #:cancel [cancel #f])          ; -> void?, waits
  (session-handle-close! session-handle))                              ; -> void?, waits; idempotent; not cancellable

(struct session-persistence-base (identity))       ; parent struct of every backend
(struct session-handle-base ())                    ; parent struct of every handle
(make-persistence-identity) -> symbol?             ; a fresh uninterned symbol
(session-persistence-identity p) -> symbol?        ; process-local instance identity, compared with eq?
```

How the seam satisfies the persistence port of `dsh-agent`. `session-persistence-base` implements `gen:session-persistence-port` and `session-handle-base` implements `gen:stored-session` of `dsh-agent/ports`, each method delegating to the generic operation above on the same value. A backend is a substruct of `session-persistence-base` that implements `gen:session-persistence`; struct inheritance carries the port implementation, so the one value mounted under `sessionPersistence` satisfies both `session-persistence?` and `session-persistence-port?`. The delegation is exactly:

| Port operation (`dsh-agent/ports`) | Delegates to |
|---|---|
| `(persistence-create p header #:inherited-event-count n #:cancel c)` | `(session-persistence-create p header #:inherited-event-count n #:cancel c)` |
| `(persistence-open p id 'write #:cancel c)` | `(session-persistence-open p id 'write #:cancel c)`; absence raises `exn:fail:persistence-not-found` |
| `(stored-session-header h)`, `(stored-session-inherited-event-count h)` | `session-handle-header`, `session-handle-inherited-event-count` |
| `(stored-session-read h from to #:cancel c)` | `(session-handle-read h from (and to (- to from)) #:cancel c)`; `to` less than `from` raises `exn:fail:contract` |
| `(stored-session-append! h events)` | `(session-handle-append! h events)` |
| `(stored-session-close! h)` | `(session-handle-close! h)` |

Semantics shared by every backend (R7 Services; `session-persistence/src/index.ts:124-211`, `handle.ts`):

| Operation | Semantics and errors |
|---|---|
| `session-persistence-create` | Stores a new session and returns a `'write` handle owned by the caller. `n` is required when the header is seeded and must be `#f` or 0 otherwise. Raises `exn:fail:persistence:already-exists`. The session is observable through `stat`, `list` and `open` in this process as soon as the call returns; other processes see it only after materialization; a session never materialized before a crash never existed. |
| `session-persistence-open` | `'read` takes no ownership and works while a writer exists, in this or another process. `'write` claims single-writer ownership. Raises `exn:fail:persistence-not-found`, `exn:fail:persistence:already-owned`. |
| `session-persistence-flush!` | Flushes every active write handle of this instance: its routed live events drain durably and its session materializes. A handle closed concurrently counts as flushed. Failures are collected and raised as `exn:fail:persistence:aggregate`; the remaining handles still flush. |
| `session-persistence-stat` | Header-only observation, no ownership, no body read; `#f` when absent. |
| `session-persistence-list` | Every session visible to this process, in no promised order. |
| `session-handle-read` | A slice of the valid contiguous log: `length` `#f` means the rest. A torn tail is never returned. Reads on one handle never go backwards. Closed-handle refusal comes before argument checks. `offset` or `length` that is not a non-negative safe integer raises `exn:fail:contract` `read offset must be a non-negative safe integer, got <v>` or `read length must be a non-negative safe integer, got <v>`. |
| `session-handle-append!` | The first event's seq must equal the stored next seq (`assert-contiguous`). When it returns, the batch is ordered, durable and visible to later reads on this backend instance. `exn:fail:persistence:read-only` on a read handle. The batch is validated as lossless JSON before it is queued. An empty batch is a no-op. |
| `session-handle-flush!` | Durability barrier; materializes an empty created session. `exn:fail:persistence:read-only` on a read handle. |
| `session-handle-close!` | A write handle drains and releases ownership. Every later operation raises `exn:fail:persistence:handle-closed` with the operation name `read`, `append` or `flush`. Closing a created handle that never materialized erases the session. |

Storage-contract helpers, shared by backends (`storage-contract.ts`; rule S1 to S6):

```racket
(assert-stored-id id header) -> void?
(assert-version header [location #f]) -> void?
(validate-stored-events header events [location #f]) -> (listof session-event?)   ; events : (listof (or/c jobject? session-event?))
(materialize-create-header header) -> session-header?
(materialize-append-batch events) -> (listof session-event?)
(assert-contiguous id events cursor) -> void?
```

### The JSONL backend (library surface of `dsh-session-store/jsonl`)

```racket
(make-jsonl-tracker [name "session-persistence-jsonl"] #:custodian [custodian (current-custodian)]
                    #:batch-delay [make-delay-evt default-live-write-delay]) -> jsonl-tracker?
(install-jsonl-tracker! ctx tracker) -> disposer?
(make-jsonl-persistence ctx tracker #:root root #:compression [compression 'zstd] #:list-concurrency [n 3]
                        #:catalog [catalog session-format-catalog]) -> session-persistence?
live-write-batch-max-delay-ms                       ; 200
(default-live-write-delay) -> evt?                  ; an alarm 200 ms from the call
```

`make-jsonl-persistence` resolves `root` to a complete path once and checks that the root is listable when it exists. The tracker holds the custodian that owns the backend's resources: every port the backend opens (lock files, logs, temporaries) and every task it spawns (write-behind timers, drains, publication) is created with `current-custodian` set to the tracker's custodian, whichever task calls. A lock file opened under a caller's custodian would be released when that caller's agent scope is disposed, before the handle has drained (dsh-agent rule 60 disposes the scope before it closes the stored session). `compression` is `'zstd` or `'none`. `make-delay-evt` is a test seam: a thunk that returns the event whose readiness ends the write-behind window. `install-jsonl-tracker!` registers one effect on `ctx` labelled `session-persistence-jsonl live routing and open handles` whose collected inverses are, in registration order, "close every open handle" and the three listeners of rule J16; the result is that effect's disposer. The plugin (Plugins) is the only production caller of these three procedures.

### `sessionProjections` (key `'sessionProjections`)

`(define-service session-projections 'sessionProjections #:contract projection-registry?)` in `dsh-session-store/projection`. The value is an opaque `projection-registry` that implements `gen:projection-port` of `dsh-llm/ports`, so `(projection-register! registry ctx definition)` and `(projection-state registry handle session)` work on it unchanged and every wave 3 consumer runs against it without a code change.

```racket
(make-projection-registry) -> projection-registry?
(install-projection-registry! ctx registry) -> disposer?         ; the session/created and session/event listeners (rules P5, P6)
(projections-register! x definition) -> projection-handle?        ; (projection-register! (session-projections-ref x) (use-context x) definition)
(projection-handle? v) -> boolean?
(projection-handle-key h) -> string?
(projection-handle-state h session) -> jvalue?                    ; dsh handle.stateOf; folds forward to the session cursor
(projection-handle-reader h session) -> (-> jvalue?)              ; dsh handle.readerFor
(projection-handle-dispose! h) -> void?                           ; releases this registration's reference; idempotent
(projections-on-changed! x listener) -> disposer?                 ; listener : (-> session? string? jvalue? session-seq? any)
(projections-on-event-changed! x listener) -> disposer?           ; listener : (-> session? (listof (cons/c string? jvalue?)) session-seq? any)
(projections-snapshot x session [keys #f]) -> projection-snapshot?
(projections-summary-keys x) -> (listof string?)                  ; registration order; the same (eq?) list until the key table changes
(projections-checkpoint x session) -> projection-checkpoint?
(projections-restore-floor x checkpoint) -> (or/c session-log-offset? #f)
(projections-view-checkpoint x checkpoint [keys #f]) -> jobject?
(projections-restore x checkpoint events base-seq header inherited-event-count) -> (values projection-snapshot? projection-checkpoint?)
(projections-hydrate! x session checkpoint events base-seq) -> projection-snapshot?
```

`keys` is `#f` (every client-visible unit) or a list of projection keys. `header` is a `session-header?`; `init` functions receive `(session-header->jvalue header)`.

| Procedure | Semantics and errors | Effects on the caller's context |
|---|---|---|
| `projection-register!`, `projections-register!` | Rules P2 and P3. Returns once the registration is usable. | one effect `sessionProjections.register()`; the inverse releases one reference |
| `projection-state`, `projection-handle-state`, `projection-handle-reader` | Rule P4. Readable after release. | none |
| `projection-handle-dispose!` | Runs that registration's disposer. | none |
| `projections-on-changed!`, `projections-on-event-changed!` | Rule P6. | one effect `sessionProjections.onChanged()` or `sessionProjections.onEventChanged()`; the inverse unsubscribes |
| `projections-snapshot` | Rule P7. Synchronous; folds only the selected client-visible units. | none |
| `projections-summary-keys` | Rule P8. | none |
| `projections-checkpoint`, `projections-restore-floor`, `projections-view-checkpoint`, `projections-restore`, `projections-hydrate!` | Rules P9 to P13. None waits. | none |

### `sessionProjectionCache` (key `'sessionProjectionCache`)

`(define-service session-projection-cache 'sessionProjectionCache #:contract projection-cache?)` in `dsh-session-store/projection-cache`.

```racket
(projection-cache-cached-snapshot x header [keys #f]) -> (or/c projection-snapshot? #f)     ; zero I/O; lifecycle identity only
(projection-cache-cached-predecessor-title x header) -> (or/c projection-snapshot? #f)       ; title only, from a record of an older format
(projection-cache-hydrate-prepared! x session events) -> projection-snapshot?                ; for a prepared, unpublished session
(projection-cache-write! x session) -> void?                                                 ; waits; not fail-soft
(projection-cache-cold-snapshot x header inherited-event-count events) -> projection-snapshot?   ; restore over a complete log, then write back without waiting
```

Rules K1 to K6. None registers an effect on the caller's context. `projection-cache-write!` is the only one that waits.

### `sessionTitle` (key `'sessionTitle`)

`(define-service session-title 'sessionTitle #:contract session-title-service?)` in `dsh-session-store/title`. The dsh method `get(session)` is named `session-title-of` because `session-title-get` is the optional read of the service value.

```racket
(session-title-of x session) -> (or/c title-snapshot? #f)
(session-title-rename! x session title) -> title-snapshot?
(session-title-refresh! x session #:cancel [cancel #f]) -> (or/c title-snapshot? #f)        ; waits
(session-title-register! x provider) -> disposer?                                            ; provider : title-provider?
(fold-session-title events) -> (or/c title-snapshot? #f)                                     ; pure; events : (listof session-event?)
(normalize-session-title text max-bytes) -> string?
(fallback-session-title text max-words max-bytes) -> string?
(truncate-title-utf8 text max-bytes) -> string?
```

| Procedure | Semantics and errors | Effects on the caller's context |
|---|---|---|
| `session-title-of` | The latest `session/title` of the session's log, live or replayed. | none |
| `session-title-rename!` | Rule T8. Raises `exn:fail:session-title-invalid` `session title must contain visible characters` when the title normalizes to empty; `exn:fail` `session "<id>" is not live in this store` for a session that is not the store's live instance; `session-title service disposed` after disposal. | none; appends `session/title` |
| `session-title-refresh!` | Rule T9. | none |
| `session-title-register!` | Rule T3. One provider at a time: a second live registration raises `session-title provider "<id>" is already registered`. | one effect `sessionTitle.register()`; the inverse aborts that provider's pending and active work and waits until its calls have settled |

### `sessionTelemetry` (key `'sessionTelemetry`)

`(define-service session-telemetry 'sessionTelemetry #:contract session-telemetry-backend?)` in `dsh-session-store/telemetry`.

```racket
(define-generics session-telemetry-backend
  (telemetry-backend-sharing session-telemetry-backend)             ; -> (or/c 'full 'feedback-only 'disabled)
  (telemetry-backend-emit! session-telemetry-backend record)        ; -> void?; must not wait
  (telemetry-backend-flush! session-telemetry-backend)              ; -> void?; default does nothing; must not wait
  (telemetry-backend-shutdown! session-telemetry-backend))          ; -> void?, waits
(struct telemetry-sink (emit flush shutdown))                       ; emit : (-> jobject? any); flush : (or/c #f (-> any)); shutdown : (-> any), may wait
(make-telemetry-coordinator ctx sink #:capture [capture 'live] #:include-history? [history? #f]) -> telemetry-coordinator?
(telemetry-capture-session! coordinator session [through-seq #f]) -> void?
```

`make-telemetry-coordinator` registers on `ctx`: with `'live`, listeners for `session/created`, `session/disposed`, `session/event`, `session/flush` and `agent/error`; and in every mode one effect labelled `telemetry capture` whose inverse emits the shutdown markers and shuts the sink down (rules L1 to L6). `capture` is `'live` or `'on-demand`.

### `sessionLogDeepSeek` (key `'sessionLogDeepSeek`)

`(define-service session-log-deepseek 'sessionLogDeepSeek #:contract log-deepseek-service?)` in `dsh-session-store/log-deepseek`.

```racket
(log-deepseek-register-exclusion! x exclude) -> disposer?      ; exclude : (-> jobject? any/c), given {sessionId, purpose?}
(accepted-through service session) -> exact-integer?            ; -1 or the highest accepted seq; incremental (rule D1)
```

`log-deepseek-register-exclusion!` registers one effect `sessionLogDeepSeek.registerExclusion()` on the caller's context. Any exclusion that returns a true value suppresses both the request field and its acceptance callback.

### `workingDirectory` (key `'workingDirectory`)

`(define-service working-directory 'workingDirectory #:contract working-directory-service?)` in `dsh-session-store/working-directory`. The dsh method `get(session)` is named `working-directory-of`.

```racket
(working-directory-default x) -> string?                                          ; dsh defaultDirectory
(working-directory-of x session) -> string?                                       ; no I/O
(working-directory-ensure x agent #:cancel [cancel #f]) -> string?               ; waits
(working-directory-set! x agent path #:cancel [cancel #f]) -> string?             ; waits
```

Rules W1 to W8. Neither registers an effect on the caller's context; both append to the agent's session and may queue a notice with `agent-inject!`. Errors are `make-working-directory-error` values with the three codes.

### `sessionQuery` (key `'sessionQuery`)

`(define-service session-query 'sessionQuery #:contract session-query-engine?)` in `dsh-session-store/query`. The value is an opaque `session-query-engine` that holds the corpus reader, the observation reader, the read-window bound, and a search provider.

```racket
(define-generics session-search
  (search-sessions session-search request #:cancel [cancel #f])     ; request : jobject? with the keys of SessionSearchRequest; -> session-search-page
  (search-events session-search request #:cancel [cancel #f])       ; -> the event page
  (search-close! session-search))                                   ; -> void?, waits; default does nothing
(make-session-query-engine ctx #:search search #:read-window-max [n 50] #:persisted-read-concurrency [c 4]
                           #:prepared-session-cache-size [k 5]) -> session-query-engine?

(session-query-observe-session x session-id #:cancel [cancel #f] #:projection-mode [mode 'all]) -> session-observation?
(call-with-session-observation x session-id proc #:cancel [cancel #f] #:projection-mode [mode 'all]) -> any   ; releases on every exit
(session-query-inspect-session x session-id read #:cancel [cancel #f]) -> any               ; read : (-> session? any)
(session-query-list-sessions x #:cancel [cancel #f]) -> (listof jobject?)           ; session-record
(session-query-read-session x session-id) -> jobject?                               ; session-log-snapshot
(session-query-filter-sessions x filters #:cancel [cancel #f]) -> (listof jobject?)
(session-query-read-title x session-id #:cancel [cancel #f]) -> (or/c title-snapshot? #f)
(session-query-read-title-snapshot x session-id #:cancel [cancel #f]) -> jobject?   ; session-title-observation
(session-query-read-title-snapshots x session-ids #:cancel [cancel #f]) -> (listof title-observation-result?)
(session-query-list-events x session-id) -> (listof jobject?)                       ; session-event-record
(session-query-filter-events x session-id filters) -> (listof jobject?)             ; session-event-search-document
(session-query-read-surface x session-id) -> jobject?                               ; session-surface-snapshot
(session-query-trace-session x session-id #:cancel [cancel #f]) -> jobject?         ; session-lineage-trace
(session-query-trace-event x session-id seq #:cancel [cancel #f]) -> jobject?       ; session-event-trace with session
(session-query-read-event x session-id seq #:before [before #f] #:after [after #f] #:cancel [cancel #f]) -> jobject?   ; session-event-window
(session-query-search-sessions x query #:session-filters [sf '()] #:event-filters [ef '()] #:limit [limit #f]
                               #:cursor [cursor #f] #:cancel [cancel #f]) -> jobject?
(session-query-search-events x session-id query #:filters [fs '()] #:limit [limit #f] #:cursor [cursor #f]
                             #:cancel [cancel #f]) -> jobject?
```

Every procedure waits. `make-session-query-engine` registers on `ctx` the optional binding to `sessionPersistence` (an injected child, effect `sessionQuery.optionalPersistence`; inside it `sessionQuery.persistenceBinding`). Rules R1 to R14 give semantics and error codes. Pure library procedures of the same module: `(extract-session-event-text event)`, `(build-session-event-records session-id events)`, `(build-session-event-search-documents session-id events)`, `(filter-session-results records filters)`, `(filter-session-event-documents documents filters)`, `(materialize-session-result-filters filters)`, `(materialize-session-event-result-filters filters)`, `(compile-session-text-filter text) -> regexp?`, `(assert-session-headers-compatible a b)`, `(read-cold-session-log persistence session-id #:cancel [cancel #f]) -> cold-session-log?`, `(trace-session-lineage records session-id)`, `(trace-session-event session-id events seq)`.

The SQLite engine (`dsh-session-store/query-sqlite`):

```racket
(make-sqlite-session-query ctx config) -> session-query-engine?      ; config : the validated plugin config jobject
(sqlite-session-query-close! engine) -> void?                         ; waits; idempotent
(open-search-database path journal-mode) -> connection?               ; rule I1; raises exn:fail with the texts of schema.ts
```

### Libraries without a service key

```racket
;; dsh-session-store/format
(format-count v label) -> exact-nonnegative-integer?           ; "<label> must be a non-negative safe integer"
(format-safe-integer v label) -> exact-integer?                ; "<label> must be a safe integer"
(inspect-format-version header-jv) -> exact-nonnegative-integer?
(snapshot-format-json v [label "Session value"]) -> jvalue?    ; "<label> is not lossless JSON"
(snapshot-format-header h [label "Session header"]) -> jobject?
(session-format-log-filename version) -> string?               ; "session.jsonl" for 0, else "session.v<N>.jsonl"
(parse-session-format-log-filename name) -> (or/c exact-nonnegative-integer? #f)
(make-migration #:name name #:from from #:to to #:migrate-header mh #:make-stage ms #:validate-target-header vh) -> migration?
(stage-feed stage item) -> (values migration-stage? (listof format-item?))
(stage-end stage) -> (values exact-nonnegative-integer? (listof format-item?))
(compose-stages stage ...) -> migration-stage?
(make-format-chain #:current-version n #:migrations ms #:restore-current-header rh) -> format-chain?
(format-chain-migrate-header chain header) -> jobject?
(format-chain-stage chain header source-cut) -> (values jobject? migration-stage?)     ; target header, composed stage
(make-format-catalog #:current-version n #:codecs cs #:migrations ms #:current-encoder enc
                     #:restore-current rc #:restore-transformed-current rtc #:restore-current-header rh) -> format-catalog?
(format-catalog-current-version c) -> exact-nonnegative-integer?
(format-catalog-read-header c header-jv) -> header-read-result?
(format-catalog-encode-header c header cut) -> jobject?
(format-catalog-encode-event c event) -> jobject?
(make-format-restore c header-jv #:recovery recovery #:validation validation) -> format-restore?
(format-restore-header r) -> jobject?
(format-restore-row r row-jv) -> format-restore?                ; pure: the next restore value
(format-restore-finish r) -> format-artifact?
(restore-format-artifact c header-jv rows #:recovery recovery #:validation validation) -> format-artifact?
;; dsh-session-store/format/catalog
session-format-catalog                                          ; codecs 0 to 4, edges 0->1->2->3->4
(make-session-format-catalog/children children) -> format-catalog?    ; children : (listof jobject?) child catalog sources
historical-session-format-catalog                               ; codecs 0 to 3, current version 3
current-session-message-projections                             ; (listof message-projection?): the image-offload projection
;; dsh-session-store/fixture-decoder
(decode-session-fixture header rows) -> (values jobject? (listof session-event?) exact-nonnegative-integer?)   ; header, current events, inherited count
;; dsh-session-store/jsonl (pure helpers)
(encode-segment raw) -> string?
(project-key cwd) -> string?
(session-dir root cwd id) -> string?                            ; cwd : (or/c string? #f)
(generation-log-path root cwd id version compression) -> string?
(log-path root cwd id compression) -> string?                   ; the generation 4 path
(generation-log-filename version compression) -> string?
(parse-generation-log-filename name compression) -> (or/c exact-nonnegative-integer? #f)
(header-line header [inherited-event-count #f]) -> jobject?
(event-line event) -> string?
(event-lines events) -> string?
(make-log-scanner header-record [recovery 'recoverable]) -> log-scanner?     ; header-record : bytes?, the first line with its newline
(log-scanner-write scanner bytes) -> log-scanner?               ; pure: the next scanner value
(log-scanner-checkpoint scanner) -> (values exact-nonnegative-integer? exact-nonnegative-integer? exact-nonnegative-integer?)   ; input bytes, committed bytes, event count
(log-scanner-finish scanner) -> (values session-header? session-log-offset? (listof jobject?) exact-nonnegative-integer?)        ; header, cut, events, committed bytes
;; dsh-session-store/jsonl/zstd
(scan-zstd-frames bytes [max-frames #f]) -> (values (listof (cons/c exact-nonnegative-integer? exact-nonnegative-integer?)) (or/c exact-nonnegative-integer? #f))
(zstd-available?) -> boolean?
(zstd-compress-frame bytes) -> bytes?
(zstd-decompress-frame bytes) -> bytes?
(zstd-decompress-prefix bytes) -> bytes?
;; dsh-session-store/jsonl/durable-io: plain blocking I/O, called under `blocking`
(fsync-port port) -> void?
(fsync-directory path) -> void?
(link-file existing new) -> void?                               ; link(2); raises exn:fail:filesystem:exists for EEXIST
(try-flock-exclusive port) -> boolean?                          ; flock(LOCK_EX | LOCK_NB); #f for EAGAIN and EWOULDBLOCK
(file-identity path-or-port) -> (or/c (list/c exact-integer? exact-integer? exact-integer? exact-integer? exact-integer?) #f)   ; device, inode, size, mtime ns, ctime ns; #f when absent
(read-stable-file path) -> (values bytes? list?)                ; rule J23: bytes and identity
(write-synced-new-file path bytes) -> void?                     ; exclusive create with mode #o600, write, fsync
(truncate-and-sync path size) -> void?
;; dsh-session-store/title-llm
(resolve-session-title-llm-config config) -> jobject?
(execute-session-title-llm ctx config request provider-id prepared) -> title-llm-response?   ; waits; request : title-request?
;; dsh-session-store/export
(serialize-session-log header events) -> string?
(read-session-log-text persistence id #:cancel [cancel #f]) -> (or/c string? #f)             ; waits; #f when the session does not exist
(flush-live-session-log ctx id #:cancel [cancel #f]) -> void?                                ; waits
(session-log-zip-filename session-id) -> string?
(session-log-zip-entries ctx root-content session-id include-descendants? #:cancel [cancel #f]) -> (-> (or/c zip-entry? eof-object?))   ; a pull thunk; each pull may wait
(write-session-log-zip out entries level #:cancel [cancel #f]) -> void?                      ; waits; entries : the pull thunk
(format-session-markdown events [source-path #f]) -> string?
```

`recovery` is `'strict` or `'recoverable`; `validation` is `'transformed` or `'current`. `decode-session-fixture` is the `decode` procedure of dsh-llm rule I2: it restores the normalised header row and the completed body rows through `(make-session-format-catalog/children '())` with recovery `'strict` and validation `'current`, which is what dsh's replay parser does (`packages/test-support/llm-replay/src/index.ts:244`), and returns the current header, the events converted with `jvalue->session-event`, and the inherited event count; failures propagate for the caller to prefix with the line number. `stage-feed`, `stage-end`, `format-restore-row` and `format-restore-finish` never mutate their argument.

### Ports: services of other packages consumed here (`dsh-session-store/ports`)

Six services are provided by sibling packages of wave 4 and by wave 5, which this package may not require. Each need is a generic interface owned here, with the convention of [WAVE3.md](WAVE3.md): a method takes the provider's value first and, when it registers an effect, the owning context second.

```racket
(define-generics storage-domain-port
  (storage-domain-open storage-domain-port ctx spec))            ; spec : domain-spec?; -> a domain value, waits; the caller owns its close
(define-generics storage-domain
  (storage-domain-table storage-domain name)                     ; -> a table value
  (storage-domain-close! storage-domain))                        ; -> void?, waits; drains queued writes
(define-generics kv-table
  (kv-table-ref kv-table key)                                    ; -> (or/c jvalue? #f); no I/O, reads the in-memory table
  (kv-table-put! kv-table key value))                            ; -> void?, waits until stored; raises after close
(define-generics directory-port
  (directory-resolve directory-port path #:cwd [cwd #f] #:cancel [cancel #f])   ; -> an opaque target; dsh fs.resolve
  (directory-stat directory-port target #:cancel [cancel #f])                   ; -> (or/c #f 'directory 'file 'other); dsh fs.stat
  (directory-process-path directory-port target))                               ; -> string?; dsh fs.processPath
(define-generics session-log-reporter-port
  (create-session-log-reporter session-log-reporter-port options))              ; options : jobject?; -> a reporter; dsh otel.createSessionLogReporter
(define-generics session-log-reporter
  (report-session-log! session-log-reporter record)              ; record : jobject? {sessionId, event, severityNumber, attributes}; must not wait
  (reporter-shutdown! session-log-reporter)                      ; -> void?, waits
  (reporter-stop-pending! session-log-reporter))                 ; -> void?
(define-generics attachment-read-port
  (attachment-read-image attachment-read-port image-ref #:cancel [cancel #f])   ; -> bytes?, waits
  (attachment-read-file attachment-read-port file-ref #:cancel [cancel #f]))    ; -> input-port?, the file's bytes
(define-generics command-port
  (command-register! command-port ctx definition handler))       ; definition : jobject? {definitionId, name, description}; handler : (-> string? jobject?) raw input -> command result; an effect on ctx
(define-generics fetch-route-port
  (fetch-route-register! fetch-route-port ctx path methods handler))   ; handler : (-> http-request? http-response?), may wait; an effect on ctx
```

Every consumer in this package calls a wrapper procedure of the same module, never a generic method directly. A wrapper takes a context, reads the service with `ctx-get`, and calls the method when the mounted value implements the interface (test doubles do, and so does a provider that adopts it). Otherwise it calls the provider's own procedure named in the third column, resolved once with `dynamic-require`; a missing module or binding raises `exn:fail` `dsh-session-store: service "<key>" is mounted but its provider module <module> does not export <name>`. This is the convention the sibling contracts `dsh-context` and `dsh-subagent` use for the services of this package.

| Wrapper | Service key | Assumed provider procedure |
|---|---|---|
| `(port-domain-open ctx spec)`, `(port-domain-table domain name)`, `(port-domain-close! domain)`, `(port-kv-ref table key)`, `(port-kv-put! table key value)` | `storageDomain` | `dsh-platform/storage/domain`: `domain-open` on a spec built with `make-domain-spec` and `domain-table-spec`, `domain-table`, `domain-close!`, `kv-table-ref`, `kv-table-put!` |
| `(port-directory-resolve ctx path #:cwd cwd #:cancel cancel)`, `(port-directory-stat ctx target #:cancel cancel)`, `(port-directory-process-path ctx target)` | `fs` | `dsh-fs`: `fs-resolve`, `fs-stat` (the type of its info value), `fs-process-path` |
| `(port-create-session-log-reporter ctx options)`, `(port-report-session-log! reporter record)`, `(port-reporter-shutdown! reporter)`, `(port-reporter-stop-pending! reporter)` | `otel` | `dsh-platform`: `otel-create-session-log-reporter`, `session-log-report!`, `session-log-shutdown!`, `session-log-stop-pending!` |
| `(port-attachment-read-image ctx ref #:cancel cancel)`, `(port-attachment-read-file ctx ref #:cancel cancel)` | `attachments` | `dsh-fs`: `attachments-read-image`, `attachments-read-file` |
| `(port-command-register! ctx definition handler)` | `commands` | `dsh-interaction`: `commands-register!` |
| `(port-fetch-route-register! ctx path methods handler)` | `connection` | `dsh-web`: the fetch route registration of the `connection` service |
| `(port-anonymous-user-id)` | none (a library) | `dsh-platform/anonymous-user-id`: `get-or-create-anonymous-user-id` |

`(port-mounted? ctx key)` tells whether a service is mounted. `agents`, `sessions`, `llm`, `tools`, `systemPrompt` and `deepseekLlmApiExtensions` are used through their own wave 3 definitions. In Behaviour, a call written with a generic method name (`directory-resolve`, `kv-table-put!`, …) means the corresponding wrapper.

Sibling packages reach the services of this package the same way, by these procedure names: `working-directory-ensure`, `working-directory-set!`, `working-directory-of`, `session-persistence-stat`, `session-persistence-list`, `session-query-observe-session` with the `session-observation-…` accessors, `session-query-list-sessions`, `session-query-read-surface`. They are part of this contract's stable surface.

### Waiting and cancellation

Every procedure that can wait says how it is cancelled:

- `session-persistence-create`, `-open`, `-stat`, `-list`, `session-handle-read`, `session-handle-append!`, `session-handle-flush!`: `#:cancel`. The backend checks it before and between I/O steps and raises the cancel reason with `check-cancelled!`. An append or flush that has started its durable write completes it; cancellation is observed only before the write is queued behind the handle's lane and when its turn starts.
- `session-handle-close!`, `session-persistence-flush!`, `storage-domain-close!`, `sqlite-session-query-close!`: no cancel event, because a durable drain must complete. A break of the waiting task ends that task's wait only; the drain continues in the lane.
- A shared historical preparation (rule J25): each waiter passes its own cancel event; the preparation is cancelled only when its last waiter has left.
- `session-title-refresh!` and a provider's `generate`: `#:cancel` composed with the service's lifetime source and the work's own source; a provider receives the composed event as `title-request-cancel`.
- `execute-session-title-llm`: the request's cancel event composed with a deadline of `timeoutMs`; on expiry the composed event's reason is a timeout reason with code `SESSION_TITLE_TIMEOUT` and message `SESSION_TITLE_TIMEOUT after <ms>ms` (rule T12), and the call raises it.
- `working-directory-ensure`, `working-directory-set!`: `#:cancel` composed with the service's lifetime source; listeners of `working-directory/access` receive the composed event.
- The `sessionQuery` procedures: `#:cancel`. Observation raises code `SESSION_QUERY_ABORTED` `session observation was aborted`; search raises the same code with `session-search aborted`; the other reads raise the cancel reason.
- `write-session-log-zip` and the entry pull thunk: `#:cancel`, which the route composes from the request's event.
- `projection-cache-write!` and `telemetry-backend-shutdown!` take no cancel event, as in dsh. The OTel backend bounds its own shutdown by `shutdownTimeoutMillis`.

No procedure of this package catches a break. Blocking file and SQLite work runs under `blocking` (cordis-kernel section 2 rule 6) and touches no harness state there.

## Events

Two events are declared here. Both are dispatched with the plain generated dispatcher on the declaring service's own context; neither is scope-filtered, as in dsh (`ctx.waterfall`).

```racket
(define-event session-telemetry/record 'session-telemetry/record #:mode waterfall #:args (jobject?) #:result jobject?)
(define-event working-directory/access 'working-directory/access #:mode waterfall #:args (hash?) #:result string?)
```

| Event | Mode | Arguments | Dispatched by, when | Guarantees |
|---|---|---|---|---|
| `session-telemetry/record` | waterfall | `(record next)`; `(next)` takes no argument and returns the record | the telemetry coordinator, once per record, at capture time and before `emit` (rule L4) | The innermost step returns the record unchanged. The returned value is what the sink receives. A listener that raises withholds that one record: the failure is contained and logged, and capture continues with the next event. Listeners must not wait. |
| `working-directory/access` | waterfall | `(request next)`; `request` is an immutable `hasheq` with `'agent` (an agent), `'path` (a string, or `#f` for "validate the current directory") and `'cancel` (an evt); `(next)` returns the resulting directory | `working-directory-ensure` and `working-directory-set!`, once per operation, inside the session's serial lane (rule W3) | The innermost step performs the access. A listener that must wait for a resource operation on the directory waits and then calls `(next)`. A listener that raises fails the operation and leaves the directory unchanged. |

Events of other packages consumed here, registered with `ctx-on` or the owner's `on-…` binding on the consuming plugin's context:

| Event | Mode | Consumers here | Notes |
|---|---|---|---|
| `session/created` | emit | projection registry (rule P5), projection cache (mandatory write), live telemetry coordinator (adopt) | none may wait; the cache starts its write as a task |
| `session/event` | emit | JSONL tracker (route into the write handle's buffer), projection registry (drive), projection cache (dirty count, `turn/end` write), title service, telemetry coordinator, OTel backend | Listeners run in registration order after the commit. Every listener here contains its own failures or cannot fail. None waits; work that waits is started as a task and that task is returned. |
| `session/flush` | parallel | JSONL tracker (`drain-live`, then `flush`), live telemetry (flush hint) | produced by `sessions-flush` |
| `session/disposed` | emit | JSONL tracker (close the handle in a task; a failure is logged at `warning`), projection cache (final write), title service (abort work), telemetry (shutdown marker) | |
| `llm/stream` | waterfall | checkpoint policy (flush before the first pull of `(next)`), title service (registered with `#:global? #t #:prepend? #t`; starts pending title work and always returns `(next)`) | |
| `tools/execute` | waterfall | checkpoint policy | |
| `agent/pre-step` | waterfall | checkpoint policy | |
| `agent/error` | emit | live telemetry (an ops record) | |
| `system-prompt/assemble` | waterfall | working directory, registered with `#:prepend? #t` | |
| `feedback/committed` | parallel | OTel backend | Owned by the feedback package of `dsh-interaction`; registered by name with `ctx-on`. Its one argument is a session inspection: a jobject or struct with the header, the inherited event count and the complete event list (rule L8). |

## Tools

One model-facing tool, registered by `dsh-session-store/plugin/tool-working-directory`. Source: `packages/session/tool-working-directory/src/index.ts:19-42`; the parameter schema is pinned by `snapshots/web/plugin-recommendations/tool-schemas.expected.json`.

```racket
(define-tool working-directory-tool
  #:name "working_directory"
  #:description "Read the current working directory, or change it with cd. Relative paths use the current directory. Existing shells and running processes keep their own directories."
  #:parameters ([cd (v-string #:description "Existing directory to enter. Omit to read the current directory.")])
  #:output (v-object #:additional? #f
                     #:properties (parameters (param "cwd" (v-string #:description "Current absolute working directory.")
                                                     #:required? #t)))
  (render (value) (list (text-block (jref value 'cwd))))
  (execute (exec) …))
```

- Parameters sent to the model: `{"type": "object", "properties": {"cd": {"type": "string", "description": "Existing directory to enter. Omit to read the current directory."}}}`, with no `required` list.
- Result: the value `{cwd}`; the model sees one text block whose text is the directory.
- `execute`, in order: no agent on the execution (`(tool-execution-agent exec)` is `#f`) raises `(make-tool-context-unavailable-error "working_directory requires an agent Session")`; `cd` equal to `""` raises `(make-tool-args-error (list "cd must not be empty; omit it to read the current directory"))`; `cd` absent calls `(working-directory-ensure working-directory agent #:cancel (tool-execution-cancel exec))`; otherwise `(working-directory-set! working-directory agent cd #:cancel …)`. The result is `(jobj [cwd directory])`.
- Errors that surface from the service as tool failures with their harness identity: `WORKING_DIRECTORY_NOT_FOUND` (`working-directory: directory does not exist: "<path>"`), `WORKING_DIRECTORY_UNAVAILABLE`, `WORKING_DIRECTORY_INVALID`.
- The tool declares no approval hook, no timeout and no concurrency predicate. It does not change sandbox roots or project membership, which stay anchored to the header `cwd`.

Not a model tool: the human slash command `export` (definition id `@deepseek-ai/dsh-session-log-export`, description `Download this Session log as a ZIP archive`), registered through the command port (rule E1).

## Plugins

Each module provides `plugin`, whose `#:name` is the name in the first column: the npm name, or the `racket:` name of the one Racket-only plugin. "Short name" is the dsh `name` export or service class; it appears in log and error texts, which are written literally.

| dsh npm name | Module (`dsh-session-store/plugin/…`) | Inject | Provides | Config |
|---|---|---|---|---|
| `@deepseek-ai/dsh-session-persistence-jsonl` | `session-persistence-jsonl` | none | `sessionPersistence` (from a child plugin named `session-persistence-jsonl-service`) | below |
| `@deepseek-ai/dsh-session-projection` | `session-projection` | none | `sessionProjections` | none |
| `@deepseek-ai/dsh-session-projection-cache` | `session-projection-cache` | `storageDomain`, `sessionProjections`, `sessions` | `sessionProjectionCache` | below |
| `@deepseek-ai/dsh-session-title` | `session-title` | `sessions`, `sessionProjections`, `agents` | `sessionTitle` | below |
| `@deepseek-ai/dsh-session-title-first-prompt-llm` | `session-title-first-prompt-llm` | `sessionTitle`, `llm`, `sessions` | none | below |
| `@deepseek-ai/dsh-session-stats` | `session-stats` | `sessionProjections` | none | none |
| `@deepseek-ai/dsh-session-turn-outline` | `session-turn-outline` | `sessionProjections` | none | none |
| `@deepseek-ai/dsh-session-telemetry-otel` | `session-telemetry-otel` | `sessions`, `otel` | `sessionTelemetry` | below |
| `@deepseek-ai/dsh-session-checkpoint-policy` | `session-checkpoint-policy` | `llm`, `sessionPersistence`, `sessions`, `tools` | none | none |
| `@deepseek-ai/dsh-session-log-deepseek` | `session-log-deepseek` | `deepseekLlmApiExtensions`, `sessions` | `sessionLogDeepSeek` (from a child plugin) | below |
| `@deepseek-ai/dsh-working-directory` | `working-directory` | `fs`, `sessionProjections`, `systemPrompt` | `workingDirectory` | below |
| `@deepseek-ai/dsh-tool-working-directory` | `tool-working-directory` | `tools`, `workingDirectory` | none | none |
| `@deepseek-ai/dsh-message-quotes` | `message-quotes` | none | none | none |
| `@deepseek-ai/dsh-session-query-sqlite` | `session-query-sqlite` | `sessions`; optional `sessionPersistence`, `sessionProjections`, `sessionProjectionCache` | `sessionQuery` | below |
| `@deepseek-ai/dsh-session-log-export` | `session-log-export` | `commands`, `connection`; optional reads `sessionQuery`, `sessionPersistence`, `attachments`, `sessions` | none | below |
| `racket:session-fixture-decoder` | `session-fixture-decoder` | none | `racket:sessionFixtureDecoder` | none |

Config schemas use `cordis-schema`; the fields are exactly the dsh keys (R7 Configuration and the `Config` exports of each package). A rejected config raises `exn:fail:cordis:validation` with the `invalid config:` text, by the convention of [WAVE3.md](WAVE3.md) ("Config validation text"); checks that dsh makes in a constructor after schema validation are made by the plugin body and raise the dsh message as `exn:fail`.

`@deepseek-ai/dsh-session-persistence-jsonl` (`session-persistence-jsonl/src/index.ts:1819-1823`):

| Field | Type | Default |
|---|---|---|
| `root` | string, required | none |
| `compression` | `"zstd"` or `"none"` | `"zstd"` |
| `listConcurrency` | natural, at least 1 | `3` |
| `x-racket.zstdFallbackRoot` | string; Racket-only (rule Z6) | absent |

`@deepseek-ai/dsh-session-projection-cache`: `writeEveryEvents` natural at least 1, required; `writeIntervalMs` natural at least 1, required. Shipped values `200` and `5000`.

`@deepseek-ai/dsh-session-title`: `fallbackMaxWords`, `fallbackMaxBytes`, `maxTitleBytes`: number, step 1, at least 1, all required. Shipped `5`, `40`, `80`. The body also checks, with these messages: `session-title: configuration is required`, `session-title: <name> must be a positive integer`, `session-title: fallbackMaxBytes must not exceed maxTitleBytes`.

`@deepseek-ai/dsh-session-title-first-prompt-llm`: `targetWords`, `targetCjkCharacters`, `maxInputBytes`, `maxOutputTokens`: number, step 1, at least 1, required; `timeoutMs`: number, step 1, at least 1, at most 2147483647, required; `provider`, `model`: string, optional, supplied together. Shipped `5`, `10`, `4096`, `4096`, `60000`. Body checks: `session-title-first-prompt-llm: <name> must be a positive integer` and those of rule T12.

`@deepseek-ai/dsh-session-telemetry-otel` (`session-telemetry-otel/src/index.ts:82-88`): `mode` `"FEEDBACK_ONLY"` or `"DISABLED"`, default `"FEEDBACK_ONLY"`; `exporter` any (an object whose `url` is required unless disabled; the other keys are passed to the reporter unchanged); `processor` any; `shutdownTimeoutMillis` number, default `3000` applied by the body; `maxRequestBytes` number, step 1, at least 1, at most 4000000. Body checks are rule L7.

`@deepseek-ai/dsh-session-log-deepseek`: `enabled` boolean, default `true`, volatile (read on every request); `maxBytes` number, step 1, at least 1, default `8388608`.

`@deepseek-ai/dsh-working-directory`: `defaultDirectory` string, optional; when absent the body uses `(path->string (current-directory))` read once at construction. A value that is not a complete path raises `working-directory: defaultDirectory must be absolute`.

`@deepseek-ai/dsh-session-query-sqlite` (`session-query-sqlite/src/index.ts:206-224`):

| Field | Type | Default |
|---|---|---|
| `path` | string, required; `":memory:"` allowed | none |
| `openAt` | `"startup"`, `"first-search"`, `"never"` | `"startup"` |
| `journalMode` | `"wal"`, `"delete"`, `"truncate"`, `"persist"` | `"wal"` |
| `defaultLimit` | number, step 1, 1 to 9007199254740990 | `20` |
| `maxLimit` | number, step 1, 1 to 9007199254740990 | `100` |
| `snippetChars` | number, step 1, at least 1 | `240` |
| `readWindowMax` | number, step 1, at least 0 | `50` |
| `persistedReadConcurrency` | number, step 1, 1 to 9007199254740991 | `4` |
| `preparedSessionCacheSize` | number, step 1, 1 to 9007199254740991 | `5` |

Shipped: `path: ':memory:'`, `openAt: never`. The body re-validates with the messages of `resolveConfig` (`index.ts:1026-1068`), each `session-search SQLite config: <detail>` with code `SESSION_QUERY_INVALID_CONFIG`.

`@deepseek-ai/dsh-session-log-export`: `compressionLevel` number, step 1, 0 to 9, default `6`.

Plugin bodies. Where dsh orders teardown through one generator effect, the body registers one effect whose result is the list of inverses, because separate top-level effects of a fiber are disposed concurrently (cordis-kernel section 6 rule 4) while the inverses of one effect run one after another in reverse order.

- `session-persistence-jsonl`: resolve the Zstandard mode (rule Z6); then one effect labelled `session-persistence-jsonl resources` whose thunk creates the tracker with `(make-jsonl-tracker "session-persistence-jsonl" #:custodian (context-custodian ctx))`, calls `install-jsonl-tracker!`, mounts with `ctx-plugin` a child plugin without config named `session-persistence-jsonl-service` whose body is `(provide-session-persistence service-ctx (make-jsonl-persistence service-ctx tracker …))`, and returns the list `(tracker-disposer service-disposer)`; then `(fiber-await service)`. Unload therefore runs, in order: dispose the service child, which first waits for every consumer that injects `sessionPersistence` to unload; remove the `session/disposed`, `session/flush` and `session/event` listeners; close every open handle, each close draining. A failure of several closes raises `exn:fail:persistence:aggregate` `session-persistence-jsonl dispose failed`.
- `session-projection`: `(make-projection-registry)`, `install-projection-registry!`, `provide-session-projections`.
- `session-projection-cache`: `(port-domain-open ctx projection-cache-domain-spec)` and wait; register the effect `sessionProjectionCache.domainClose` whose inverse closes the domain; install the write path (rule K4) including the effect `sessionProjectionCache.timers`; then provide the service. The timers effect is registered after the close effect so that timers are cleared before the domain closes; both are members of one effect's inverse list in that order.
- `session-title`: validate the config; register the effect `sessionTitle lifecycle` (rule T10); register the `session/event`, `llm/stream` and `session/disposed` listeners; register `title-projection` and wait; register the `titleInput` unit and wait, keeping its handle; then provide the service.
- `session-title-first-prompt-llm`: resolve the config; `(session-title-register! session-title provider)` with id `session-title-first-prompt-llm` and mode `'first-prompt` (rule T11).
- `session-stats`, `session-turn-outline`: `(projections-register! session-projections <definition>)`.
- `session-telemetry-otel`: rule L7; provides the backend last.
- `session-checkpoint-policy`: the three listeners of rule Q1 to Q3.
- `session-log-deepseek`: mount a child plugin that injects `deepseekLlmApiExtensions` and `sessions`, creates the service, registers the field `dsh_session_log` with `deepseek-extensions-register!` (rule D2) and provides `sessionLogDeepSeek`; wait for the child.
- `working-directory`: rule W1.
- `tool-working-directory`: `(tools-register! tools working-directory-tool)`.
- `message-quotes`: nothing.
- `session-query-sqlite`: re-validate the config; create the engine with `make-sqlite-session-query`, which registers the optional persistence binding and the effect `sessionQuerySqlite.close` whose inverse is `sqlite-session-query-close!`; when `openAt` is `"startup"`, open the index and wait, an open failure failing the mount with the error of rule I2; then `provide-session-query`.
- `session-log-export`: register the command inside an effect labelled `session-log-download: command`, then the two routes (rules E1 to E3).
- `session-fixture-decoder`: `(ctx-provide ctx 'racket:sessionFixtureDecoder decode-session-fixture)`.

`dsh-session-store/plugins` provides `plugin-table`:

```racket
(define plugin-table
  '(("@deepseek-ai/dsh-session-persistence-jsonl"        . dsh-session-store/plugin/session-persistence-jsonl)
    ("@deepseek-ai/dsh-session-projection"               . dsh-session-store/plugin/session-projection)
    ("@deepseek-ai/dsh-session-projection-cache"         . dsh-session-store/plugin/session-projection-cache)
    ("@deepseek-ai/dsh-session-title"                    . dsh-session-store/plugin/session-title)
    ("@deepseek-ai/dsh-session-title-first-prompt-llm"   . dsh-session-store/plugin/session-title-first-prompt-llm)
    ("@deepseek-ai/dsh-session-stats"                    . dsh-session-store/plugin/session-stats)
    ("@deepseek-ai/dsh-session-turn-outline"             . dsh-session-store/plugin/session-turn-outline)
    ("@deepseek-ai/dsh-session-telemetry-otel"           . dsh-session-store/plugin/session-telemetry-otel)
    ("@deepseek-ai/dsh-session-checkpoint-policy"        . dsh-session-store/plugin/session-checkpoint-policy)
    ("@deepseek-ai/dsh-session-log-deepseek"             . dsh-session-store/plugin/session-log-deepseek)
    ("@deepseek-ai/dsh-working-directory"                . dsh-session-store/plugin/working-directory)
    ("@deepseek-ai/dsh-tool-working-directory"           . dsh-session-store/plugin/tool-working-directory)
    ("@deepseek-ai/dsh-message-quotes"                   . dsh-session-store/plugin/message-quotes)
    ("@deepseek-ai/dsh-session-query-sqlite"             . dsh-session-store/plugin/session-query-sqlite)
    ("@deepseek-ai/dsh-session-log-export"               . dsh-session-store/plugin/session-log-export)
    ("racket:session-fixture-decoder"                    . dsh-session-store/plugin/session-fixture-decoder)))
```

The ten library packages without a row (`session-persistence`, `session-format`, `session-format-catalog`, the four edges, `session-title-llm`, `session-telemetry`, `session-query`) are not mountable in dsh either.

## Behaviour

Rule numbers are for tests. A letter names the area. "Raise format" means `exn:fail:session-format`; "raise unsupported" means `exn:fail:session-format:unsupported`. Every message quoted from a TypeScript file is copied verbatim into the Racket source with a `; source:` comment. Where a rule says "messages are those of `<file>`", the implementer copies each message string of that file at the matching check; the file is the specification of the text.

### F. Format library (`session-format/src`; R7 Algorithms 14, 15)

F1. Guards (`json.ts`). `format-count` accepts a non-negative safe integer that is not `-0.0` and returns it exact; `format-safe-integer` accepts any safe integer that is not `-0.0`. `inspect-format-version` raises format `Session header must be a JSON object` for a value that is not an object, and otherwise applies `format-count` to its `version` with label `Session format version`. `snapshot-format-json` is `snapshot-json` of `dsh-session/lossless` with the failure `<label> is not lossless JSON`. `snapshot-format-header` also requires an object (`<label> must be a JSON object`), a string `id` (`<label> id must be a string`), a count `createdAt`, a boolean `isSeeded` (`<label> isSeeded must be a boolean`) and a count `delegationDepth`.

F2. Filenames (`filename.ts`). The canonical pattern is `^session(?:\.v([1-9][0-9]*))?\.jsonl$`. Version 0 has no `.vN` part. `.v0`, a leading zero, an upper-case letter and a temporary name are not generations. `parse-session-format-log-filename` returns `#f` for a non-match and for a number beyond the safe range.

F3. `make-migration` (`chain.ts:26-36`): the name must be a non-empty string (`Session migration name must be a non-empty string`); `to` must be `from + 1` (`<name> must declare adjacent v<from>->v<from+1>`).

F4. `make-format-chain` (`chain.ts:50-78`): one migration per source version (`Session migration v<a>->v<b> is duplicated`), unique names (`Session migration name <JSON string> is duplicated`), every adjacent pair from 0 to the current version present (raise unsupported `Session migration v<n>->v<n+1> is missing`), none beyond (`Session migration from v<n> does not lead to current v<c>`).

F5. `format-chain-migrate-header` (`chain.ts:128-158`): snapshot the header (label `stored Session header`); for each edge from the header's version: call `migrate-header` on a snapshot (label `<name> header input`), snapshot the result (`<name> header output`), require its version to be the edge's target (`<name> header returned v<x>; expected v<to>`), call `validate-target-header`; then call the chain's `restore-current-header`, snapshot it (`current Session header restoration`) and require the current version (`current Session header restorer returned v<x>; expected v<c>`). A header newer than the chain raises unsupported `stored Session uses newer format v<n>; this build writes v<c>`.

F6. `format-chain-stage` builds one composed stage for the edges from the header's version to the current one. For edge `i` it advances the header as in F5 and calls `make-stage` with `#:source-header`, `#:target-header`, `#:source-cut` (the given cut for the first edge, the previous stage's `header-inherited-event-count` for the others) and `#:source-kind` (`'decoded` for the first edge, `'transformed` for the others). Composition is depth-first: each item a stage emits is fed through all later stages before the stage sees its next input, which is the order dsh's chained contexts produce. `stage-end` of the composition ends stage 1, feeds its trailing items through the later stages, ends stage 2, and so on; a stage whose returned cut differs from its declared `header-inherited-event-count` raises format `<name> changed its predeclared inherited cut`; the last stage's cut, checked with `format-count` (label `finished Session inherited event count`), is the result.

F7. Runs. A stage's `step` receives a format event or an `event-run`. Which stages keep a run packed is stated per edge (M rules). Whatever leaves the last stage of a restore is collected in order; a run is expanded there with its `expand` thunk.

F8. Refusal wrapping (`chain.ts:245-256`). Any `exn:fail` that is not already an unsupported error and that is raised by an edge's `migrate-header`, `validate-target-header`, `make-stage`, `step` or `finish` is re-raised as unsupported with the message `<edge name> refuses this format v<from> <subject>: <detail>`, where `<subject>` is `Session header` for the two header procedures and `Session` otherwise, and `<detail>` is the original message.

F9. `make-format-catalog` (`catalog.ts:29-45`): exactly one codec per version 0 to current (`Session format codec v<n> is duplicated`, `Session format codec v<n> is missing`, `Session format codec v<n> is newer than current v<c>`), and the chain of F4.

F10. `format-catalog-read-header` (`catalog.ts:47-97`): a version that cannot be read gives `'malformed` without a stored version; a version above current gives `'unsupported` with reason `stored Session uses newer format v<n>; this build writes v<c>`; otherwise decode with the codec, snapshot (label `format v<n> header`) and migrate with F5, giving `'current` or `'migration-required` with the migrated header; an unsupported error gives `'unsupported` with its message; any other failure gives `'malformed` with the stored version and its message.

F11. `make-format-restore` (`catalog.ts:120-150`, `:160-240`). Select the codec by the header's version (newer: raise unsupported as in F10) and make its decoder with the recovery mode. Current version: rows go to the decoder; `finish` ends the decoder, requires the cut to equal the decoder's declared cut when it declared one (`streaming decoder changed its predeclared inherited cut`), applies `restore-current` when validation is `'current` and nothing otherwise, and requires the artifact's header version to be current (`current Session restorer returned v<x>; expected v<c>`). Older version: decoder items go through the composed stage of F6; `finish` ends the decoder (same cut check), ends the stage, builds the artifact with the chain's target header and applies `restore-current` (validation `'current`) or `restore-transformed-current` (validation `'transformed`); under `'transformed`, a restorer failure that is not an unsupported error is re-raised as unsupported `Session migration from v<s> to v<c> refuses the transformed artifact: <detail>`.

F12. `format-catalog-encode-header` requires a current-version header (`encodeCurrent requires Session format v<c>`) and a current-version result (`current Session codec returned a non-current header`). `format-catalog-encode-event` is the current encoder's `encode-event`.

F13. Recoverable decoding, shared by every codec (R7 Algorithms 15). In `'recoverable` mode the first malformed row or seq gap is remembered and the row is dropped; every later row is dropped too, except that a later decoded event of type `turn/end` re-raises the remembered error, because it shows that the bad region was committed. In `'strict` mode the first error is raised at once. A stage state carries the remembered error; nothing is mutated.

### C. Codecs (physical forms of generations 0 to 4)

C1. Generations 0 and 1 (`session-format-v0-to-v1/src/codec.ts`). Physical header: required keys `type`, `version`, `id`, `createdAt`, `delegationDepth`; optional `cwd`, `parentSession`, `seedLength`, `origin`, `agentPreset`; no others. The logical header is `{version, id, createdAt, cwd?, parentSession?, isSeeded, origin?, delegationDepth, agentPreset?}` with `isSeeded` true exactly when `seedLength` is present. The decoder declares the cut `seedLength`, or 0. Messages are those of `codec.ts:118-160`.

C2. Rows of generations 0 and 1. A row whose `type` is `text-chunks`, `reasoning-chunks` or `tool-call-chunks` is a packed row with exactly the keys `type`, `seq0`, `time0`, `data`; `data` has exactly `turn`, `step`, `index`, `dt`, `texts`, or for tool calls `turn`, `step`, `index`, `id`, `dt`, `args` and optionally `name`. The payload (`texts` or `args`) is a non-empty string list and `dt` has one member fewer. The decoder emits one `event-run` of type `'released-assistant-chunks` with `first-seq` `seq0` and `event-count` the payload length; its stream record is `{type, time0, index, dt, texts}` or `{type, time0, index, dt, id, name?, args}`. Any other row is an event row; a `sourceEventSeqs` value is decoded with C4 and the event's `seq` as bound. Seq continuity counts the members of a run. `finish` raises format `Session inheritedEventCount exceeds its event count` when the declared cut exceeds the number of events. Messages: `codec.ts:60-112`, `:185-240`.

C3. Generation 2 (`session-format-v1-to-v2/src/codec.ts`). Physical header: the v4 header table of Data with `version` 2. Row: required `type`, `seq`, `time`, `data`; optional `ignorable` (only `true`), `sourceEventSeqs`, `surfaceOp`; no others; `type` a string; `time` a safe integer; messages `released v2 row <i> …` (`codec.ts:128-150`). A seq that differs from the count of accepted events is a gap (`released v2 row <i> has seq gap (expected <n>, got <s>)`). Each accepted `session/end-seed` whose `data.inherited` is `true` sets the cut to its seq. `finish` raises `released v2 seeded Session lacks an inherited end-seed marker` or `released v2 unseeded Session contains an inherited end-seed marker` and returns the cut, or 0.

C4. Range-encoded `sourceEventSeqs` (`codec.ts:186-232`). Decoding with bound `max` (the event's seq): the value must be an array (`sourceEventSeqs must be an array`); a number member is a count; an array member must be a pair `[start, end]` (`sourceEventSeqs range must be a [start, end] pair`) with `start <= end < max` and an expansion that fits in `max` minus the members so far (`sourceEventSeqs range exceeds its event seq`); all expanded members are unique and below `max` (`sourceEventSeqs ranges must contain unique earlier seqs`); when any range was present the expanded list is strictly increasing (`sourceEventSeqs ranges must be strictly increasing`). Encoding is `encode-seq-ranges` of `dsh-session`: a list that is not strictly increasing is written unchanged; otherwise each maximal run of three or more consecutive integers is written as `[first, last]`, a run of two as two numbers, a single as a number.

C5. Generation 3 (`session-format-v2-to-v3/src/codec.ts`) is the generation 2 physical form with `version` 3 (`expected format v3 physical Session header`). Each row passes `assertV3RowAdmission` before decoding, and each decoded event passes `assertV3EventAdmission` and, until an error is remembered, `assertV3Event` (`payload.ts`, `validation.ts`); the recoverable rule F13 applies to that validator too, and when an error was remembered `finish` uses the last accepted inherited marker (`format v3 seeded Session lacks an accepted inherited end-seed marker`, `format v3 unseeded Session contains an inherited end-seed marker`).

C6. Generation 4 (`session-format-v3-to-v4/src/codec.ts`) is the generation 2 physical form with `version` 4 (`expected format v4 physical header`). `decode-row` applies `assert-v4-row-admission` (rule V1) and then the generation 2 decoder. `encode-header` applies `assert-released-v4-header` (rule V3) and writes the generation 2 header with `version` 4 in the same key position. `encode-event` applies `assert-v4-row-admission` to the event (and, for an ignorable `developer/message`, the developer-data and retired-syntax checks first) and then range-encodes `sourceEventSeqs` in place.

### M. Migration edges (R7 "Migration edges")

Every edge is a `migration` whose stage is a pure state machine (Data). The edge names are the npm names: `@deepseek-ai/dsh-session-format-v0-to-v1`, `…-v1-to-v2`, `…-v2-to-v3`, `…-v3-to-v4`; they appear in the refusal text of F8. Each rule cites the file that fixes its details and messages.

**M0. v0 to v1** (`session-format-v0-to-v1/src/migration.ts`, `dispositions.ts`, `payload-validation.ts`, `relationships.ts`). Header: `version` only. Packed runs pass through unexpanded. Per event, in this order:

1. Rename `compact/start`, `compact/summary`, `compact/end`, `compact/prune` to `compaction/…`.
2. Raise unsupported for `request/header-delta`, `mode/set`, and `request/header` whose `data.reason` is `"fallback"`.
3. `turn/start` with a `trigger`: require exactly the keys `turn` and `trigger`, `turn >= 1`, a non-empty string `trigger.kind`; write `{turn}`.
4. `turn/end` reasons: `completed`, `blocked`, `max-tokens`, `interrupted` unchanged; `aborted` without `reason` becomes `{kind: "aborted", reason: {kind: "legacy"}}`; `disposed` becomes `{kind: "aborted", reason: {kind: "disposed"}}`; `error` without `error`: `{kind, step, failure: {message, code, status?, providerRetryAfterMs?, requestId?}}` becomes `{kind: "error", error: failure}`, and `{kind, step, message, code?}` becomes `{kind: "error", error: {message, code: code or "UNKNOWN"}}`.
5. `request/header`: remove `data.header.messagePrefix`, which must be an array.
6. `steering/message` becomes `user/message`: `{turn, message}` gives data `message`; `{turn, content, source}` gives `{content, source, id: "legacy-message:<sessionId>:<seq>", role: "user"}`.
7. `llm/retry` without `retryId`: reuse the id of the same chain, keyed by the JSON texts of `turn`, `step`, `provider`, `policyKey` joined with U+0000, or mint `legacy-retry:<sessionId>:<seq>`.
8. Compaction ids: `compaction/start` without `compactionId` gets `legacy-compaction:<sessionId>:<seq>`; while a compaction is open, `compaction/summary`, `compaction/end` and a `user/message` with source `{kind: "plugin", plugin: "compact"}` that lack `compactionId` receive it; `compaction/end` and `session/end-seed` close it.
9. Legacy message wrappers. A `user/message` with `content` and `source` but no `id`, `role` or `message` gains `id: "legacy-message:<sessionId>:<seq>"` and `role: "user"`. An `assistant/message` with flat `content` and a legacy source object stored under the key spelled by joining `pro` and `venance` becomes `{…rest, message: {id: <legacy id>, role: "assistant", content, source: {…legacySource, kind: "model"}}}`. A `tool/result` with flat `callId`, `content`, `isError` becomes `message: {id, role: "user", content: [{type: "tool-result", toolCallId: callId, content, isError}], source: {kind: "tool", callId}}`; for a replacement the id is the id of the message at `surfaceOp.start` (`tool/result <seq> replacement cites a message without identity`).
10. Validate the payload against the frozen inventory: the event type must be in `released-v0-event-dispositions` (unknown types are refused even when ignorable), the payload must have every required member and no member outside required and optional, and `assert-released-payload-semantics` must pass (`payload-validation.ts:17-297`, with the helpers to line 1072).
11. A `session-log-deepseek/delivery-accepted` marker for generation 0 that names another session is allowed only inside the inherited prefix of a session with `parentSession` (`current-generation delivery marker names the wrong Session`).

`finish` returns the declared cut. Artifact relationships of generations 0 and 1 are `assert-released-artifact-relationships` (`relationships.ts`, 497 lines), applied by `restore-released-v1-artifact` and reused by the generation 2 and 3 restorers.

**M1. v1 to v2** (`session-format-v1-to-v2/src/migration.ts`). Header: `version` only; the physical header gains `isSeeded` and loses `seedLength`. State: at most one pending attempt `{turn, step, chunk seqs, accumulator, terminal?}`, the events buffered after its last chunk, the map from source seq to target seq, the next target seq, the target cut.

1. An `assistant/chunk` event or a packed run joins the pending attempt when it has the same `turn` and `step` and the attempt is not terminal; otherwise the pending attempt is finished (step 3) and a new one starts. Chunks are compacted with `accumulator-push` of `dsh-llm` (R7 Algorithms 16), a packed run contributing its stream record as one run. A `finish` chunk marks the attempt terminal.
2. `assistant/message`: with a non-empty `sourceEventSeqs` the list must equal the pending attempt's chunk seqs in order, else raise `chunk references are not one complete ordered attempt`; the output is the message without `sourceEventSeqs` and with `data.stream` the compact records. An empty or absent `sourceEventSeqs` gives `stream: []`; absent with a pending attempt of the same step is refused.
3. `turn/end`, `step/end`, `llm/retry`, `llm/retry-started` close the pending attempt: emit `assistant/attempt {turn, step, stream}` at the position and time of its last chunk, then the buffered events.
4. Any other event that arrives while an attempt is pending is buffered. A later chunk of the same attempt, or the claiming message, first emits the buffered events in order; an unclaimed attempt emits its `assistant/attempt` first and the buffered events after it. The relative order of non-chunk events never changes.
5. Every emitted event gets the next dense target seq. References are remapped: envelope `sourceEventSeqs`, `surfaceOp.start` and `end`, `command/done.sourceEventSeq`, `compaction/summary` and `compaction/prune` `shadowedRange.{start,end}` and `shadowedSeqs`, `session/title` and `session/title-llm-request` `messageSeqs`. A reference to a consumed chunk is refused.
6. Seeded sessions: the first emitted event whose source seq is at or beyond the source cut fixes the target cut. A `session/end-seed` exactly at the cut is rewritten to `data: {inherited: true}`; otherwise a new `session/end-seed {inherited: true}` is inserted at the cut. If the cut is never reached, one is appended in `finish` with the time of the last event. A cut that splits an attempt is refused.
7. Legacy restart: `turn/start N+1` while turn `N` is open with no open step, when the previous event is `agent/inbox/spliced {target: "next-turn", inserted: non-empty}`, first inserts `turn/end {turn: N, reason: {kind: "interrupted"}}`. Any other `turn/start` over an open turn is refused.
8. Legacy goal: a `user/message` with source `{kind: "goal", change}` emits `goal/change` with data `change`, then the message with source `{kind: "plugin", plugin: "goal"}`.

**M2. v2 to v3** (`session-format-v2-to-v3/src/migration.ts`, `payload.ts`, `references.ts`). Header: `version: 3`; `agentPreset: "code"` becomes `"ptc"`.

1. Source audit (`payload.ts:42`): only the released generation 2 inventory types plus `feedback/message-put` and `feedback/message-delete`; exact envelope and payload members; content kinds `text`, `reasoning`, `image`, `file`, `tool-call`, `tool-result`; message source kinds as listed there. Source events must be dense (`format v2 source events must be dense`).
2. System head. After the first `step/start`, insert a `system/message` with surface op `append` and `content: []`. At each `request/header`, the prompt is `header.system` when it is a string and `""` otherwise; when it differs from the current prompt, insert immediately before that header a `system/message` that replaces the current head (`surfaceOp {op: "replace", start: head, end: head}`, `sourceEventSeqs: [head]`); always remove `header.system`. The synthetic event is `{type, seq, time, data: {turn, step, message: {id, role: "system", source: {kind: "plugin", plugin: "@deepseek-ai/dsh-system-prompt"}, content}}, …}` with `content` `[]` for the empty prompt and `[{type: "text", text: prompt}]` otherwise, `time` the anchor event's time, and `id` the string `v2-to-v3-system-` followed by the lower-case hex SHA-256 of the UTF-8 bytes of `(jvalue->string (list "session-format-v2-to-v3" session-id anchor-seq anchor-type))`. Refusals, with the messages of `migration.ts:57-116`: a surface event before the first step, a prompt change outside an open step, an id collision in either direction.
3. Renames: `tool/code-dispatch-start` to `tool/ptc-dispatch-start`, `tool/code-dispatch` to `tool/ptc-dispatch`; `agent-preset/selected.agentPreset` `"code"` to `"ptc"`; `source.plugin` `"tools-code-mode"` to `"tools-ptc"` in `user/message.data.source`, `agent/inbox/spliced.data.inserted[].source`, `session/title-llm-request.data.messages[].source`.
4. Canonical forms: `{op: "replace", start, end}` becomes `{op: "replace", startSeq, endSeq}`; `tools: []` and `adapterDefaults: {}` are removed from `request/header.data.header`.
5. Dense remap of the reference fields of M1 step 5 (`references.ts:14`). The cut is the target seq of the last `session/end-seed {inherited: true}`.
6. Delivery markers: a generation 2 marker that claims generation 3 is refused (`format v2 delivery marker claims target format v3`); a generation 2 marker naming another session is allowed only before the cut with `parentSession`.

**M3. v3 to v4** (`session-format-v3-to-v4/src/migration.ts` and the files named per step). `migration-v3->v4` is the unbound edge: its `make-stage` raises unsupported `V3 catalog migration requires explicit historical child facts, including an empty array for a parent without children`. `(make-migration-v3->v4 children)` is the bound edge; `children` is a list of child catalog sources `{childId, childCreatedAt, descriptorCount, descriptor, sourcePath?}` (`facts.ts`). Header: `version: 4` only.

1. Interrupted turn: as M1 step 7, the inserted `turn/end` taking the time of the `turn/start`.
2. An ignorable event whose type is not in `released-v3-event-types` (`extension-identities.ts:8-74`, copied verbatim) gets the type `plugin:<original>`; payload and envelope metadata are untouched and only `seq` is renumbered. An unknown required type is refused.
3. Reference remap when a seq changed (`references.ts:18`): the fields of M1 step 5 with `startSeq` and `endSeq`, plus `image/offload.targets[].seq`.
4. Message sources (`sources.ts:59`), applied to `user/message.data`, to `data.message` of `developer/message`, `system/message`, `assistant/message` and `tool/result`, to `agent/inbox/spliced.data.inserted[]` and to `session/title-llm-request.data.messages[]`: `{kind: "plugin", plugin: P, …rest}` becomes `{kind: K, …rest}`, where `K` is `system-prompt` when `P` is `@deepseek-ai/dsh-system-prompt` and the role is `system`; else `compact-checkpoint` for `compact`, `ptc-mode` for `tools-code-mode` and `tools-ptc`, `compact-basic` for `dsh-compaction-basic`, `runtime-context` for `@deepseek-ai/dsh-system-prompt`; else `P` itself when `P` is in `RELEASED_SAME_NAME_PRODUCERS` of `sources.ts` (copied verbatim); else `plugin:<P>`. A source with exactly the two keys `kind` and `plugin` becomes `{kind: K}`; otherwise the result keeps the source's other keys in their original order with `kind` replaced in place and `plugin` removed. Other kinds are kept unchanged. A `plugin` that is not a string raises format `plugin source at seq <n> is not canonical: plugin requires a string`.
5. Tool-result lift (`tool-role.ts:36`) for a `tool/result` whose message role is `user`: require a non-empty `id`, source `{kind: "tool", callId}`, exactly one content block `{type: "tool-result", toolCallId = callId, content: array, isError?: boolean}` and no nested `tool-result`. The output message has the keys `role: "tool"`, `source`, `toolCallId`, `content` (the wrapper's content), `isError?`, `id`, then `plugin:message:<k>` for each extra message key and `plugin:result:<k>` for each extra wrapper key, in that order.
6. Content tags (`content.ts:55`): a block type outside `text`, `reasoning`, `image`, `file`, `tool-call`, `tool-result` becomes `plugin:<type>` in message content, in `compaction/summary` `summary` and `rawOutput`, in `tool/ptc-dispatch.content`, in `team/message/queued.message.content`, and in embedded stream `chunk` records (`block-end.block.type`, `block-start.blockType`). A `request/header` tool definition with its own `deferLoading` is refused.
7. Delivery markers: a generation 3 marker that claims generation 4 is refused; generation 3 markers are validated as in M2 step 6.
8. Catalog completion in `finish` (`migration.ts:137-175`): collect the session's own `subagent/catalog` payloads after the last inherited marker (`duplicate catalog child <id>`). For each supplied child, sorted by `childCreatedAt` and then by `childId` in JavaScript string order: when an entry exists, require equal `childCreatedAt` and, when the child has exactly one supported descriptor, equal `mode` and `label` (`<subject> conflicts with its parent catalog`); otherwise append `subagent/catalog` with the fact of `child-catalog-fact` (`{version: 0, childId, childCreatedAt, mode, label?}` for exactly one descriptor of version 1, 2 or 3; mode `continuable` for version 1, the descriptor's mode otherwise) or else `{version: 1, childId, childCreatedAt, mode: "unknown"}`. Appended events take dense seqs after all source events and the time of the last source event, or the header `createdAt` for an empty log.

### V. Native v4 admission and relationships

V1. `(assert-v4-row-admission row [known-event-types #f])` (`codec.ts:60-75`), for an object row, in order: an ignorable `developer/message` is skipped entirely unless `known-event-types` contains `developer/message`; `assertV4DeveloperData` (`developer.ts`); `assertV4SourceRowAdmission` (`message-sources.ts`: no `source.kind` equal to `"plugin"`); `assertV4RetiredSyntax` (`retired-syntax.ts`: a non-ignorable `tool/code-dispatch` or `tool/code-dispatch-start`, `request/header.data.header.system`, `tool-result` blocks in interpreted content positions or stream chunks); `assertV4SystemMessageFields` (`system-message.ts`); and for `tool/result` rows `assertV4ToolResultMessage` (`tool-role.ts`) and `assertV4ForkResult` (`fork-result.ts`). Messages are those of the six files.

V2. `(assert-released-v4-relationships artifact known-event-types)` (`validation.ts:79-157`, `relationships.ts`, 385 lines) checks, over known event types only: developer data and message sources per event; delivery markers (`validateDeliveryAccepted`; a generation 4 marker at or after the cut must name this session: `current-generation delivery marker names the wrong Session`); own `subagent/catalog` facts at or after the cut (versions 0 to 2 as `catalogFact` of `facts.ts` accepts them; version 3 with `mode` `continuable` or `external` and a `name` that matches `^[a-z][a-z0-9-]{0,31}$` and is not `lead`; otherwise `subagent/catalog requires a supported versioned catalog fact`), unique by `childId` (`duplicate catalog child <id>`) and by `name` (`duplicate catalog child name <name>`); and the lifecycle relationships: `turn/start` opens the next turn and `step/start` the next step, no unresolved tool call at `step/end` or `turn/end`, each assistant `tool-call` block advertises a unique id, `tool/call` matches name and arguments, an appended `tool/result` settles one call, a result for an unstarted call is exactly the `TOOL_NOT_STARTED` repair of dsh-session rule 31 (error `{name: "ToolNotStartedError", code: "TOOL_NOT_STARTED"}`, `isError: true`, no `sourceEventSeqs`, id `interrupted-tool-result-<callId>-<integer>` with the one text block of `CLOSER_TEXT`, or a `forked-tool-result-<callId>-<seq>` id), the surface fold with a protected first system head, PTC dispatch pairing, retry chains, title citations, `command/run` with `command/done`, compaction transactions, and the `developer/message.headerSeq` binding. Open tails stay open: a log that ends inside a turn is valid.

V3. `assert-released-v4-header` (`validation.ts:11-37`): version 4 (`expected format v4 header`), the required keys `version`, `id`, `createdAt`, `isSeeded`, `delegationDepth`, the optional keys `cwd`, `parentSession`, `origin`, `agentPreset`, and the messages `format v4 header lacks required field <k>`, `… has unexpected field <k>`, `… id must be a string`, `… isSeeded must be boolean`, `… cwd must be absolute`, `… <k> must be a string`, `… origin must be "subagent"`.

V4. `restore-released-v4-artifact` (`validation.ts:38-70`): V3; the cut is a count not above the event count (`format v4 inherited event count exceeds its events`) and 0 for an unseeded header (`unseeded format v4 Session has inherited events`); per event: an unknown type that is not ignorable raises unsupported `format v4 contains unknown event type <JSON string> at seq <i>`; `seq` equals the index (`format v4 event <i> is not dense`); for known types the retired-syntax, system-message, tool-result and fork-result checks; the last inherited marker must equal the cut for a seeded header (`format v4 seeded header disagrees with its last inherited end-seed marker`) and be absent for an unseeded one (`format v4 unseeded Session contains an inherited end-seed marker`); then V2.

V5. The static catalog (`session-format-catalog/src/generated.ts`): current version 4; codecs 0 to 4; encoder the generation 4 codec; `restore-current` is V4 with `known-session-event-types` followed by `validate-installed-current-artifact`; `restore-transformed-current` is V4 alone; `restore-current-header` is V3 followed by constructing an empty restored session from the header (`restore-session` with an empty seed, count 0, state `'detached`), which applies dsh-session rule 3. `validate-installed-current-artifact` requires version 4 (`installed Session format is v4, got v<x>`) and calls `(restore-session id events header cut #:event-state 'detached #:projections current-session-message-projections)` on the artifact's events converted with `jvalue->session-event`; any failure propagates. `make-session-format-catalog/children` is the same catalog with `(make-migration-v3->v4 children)` in place of the unbound edge. `historical-session-format-catalog` has current version 3, codecs 0 to 3, the generation 3 encoder and `restore-released-v3-artifact` with `released-v3-event-types` for both restorers.

### S. The storage contract (`session-persistence/src/storage-contract.ts`)

S1. `assert-stored-id`: a header id different from the requested id raises `exn:fail` `stored session identity mismatch: requested "<id>", header contains "<hid>"`.

S2. `assert-version`: a header version other than 4 raises `exn:fail:persistence:format-unsupported` with `(session-format-version-refusal id version)`, followed by ` (raw log: <path>)` when a location is given.

S3. `validate-stored-events`, per event in order: a type outside `known-session-event-types` that is not ignorable raises format-unsupported `session "<id>" contains event type "<type>" (seq <n>) unknown to this harness and not marked ignorable; refusing to interpret the log — it was likely written by a newer harness`; a `request/header` whose `data.reason` is `"fallback"` raises format-unsupported `session "<id>" contains a request/header event (seq <n>) with the unsupported legacy reason "fallback"; refusing to interpret the log — it was written by a retired pre-release harness`; both get the location suffix of S2. Then every event is converted with `jvalue->session-event` and checked with `check-session-event` of `dsh-session`; a failure raises `exn:fail:persistence:corruption` `stored session "<id>" failed validation: <text>` with the original as cause, where `<text>` is `Error: <message>` as JavaScript `String(error)` prints it.

S4. `materialize-create-header`: a header that is not lossless JSON raises `exn:fail:contract` `session metadata must be losslessly JSON-serializable`; a `createdAt` that is not a non-negative safe integer raises `exn:fail:contract` `session metadata createdAt must be a non-negative safe integer`.

S5. `materialize-append-batch`: a batch with data that is not lossless JSON raises `exn:fail:contract` `session event batch is not losslessly JSON-serializable because it contains non-JSON-serializable data`.

S6. `assert-contiguous`: for the event at index `i`, a seq other than `cursor + i` raises `exn:fail` `append seq mismatch for "<id>": expected <n> at index <i>, got <seq>`.

S7. JavaScript `String(error)` appears inside several persisted or logged texts of this package. `(js-error-string v)` (private) returns `<name>: <message>` for an exception, where `<name>` is the dsh class name the Data table assigns to its struct (`Error` for a plain `exn:fail`, `TypeError` for `exn:fail:contract`, the harness name for an `exn:fail:harness`), and the `display` form of any other value.

### J. The JSONL backend (`session-persistence-jsonl/src`; R7 Formats, Algorithms 1 to 13)

**Layout**

J1. The backend root is the configured `root` (shipped: `$DSH_HOME/sessions`, where `DSH_HOME` defaults to `~/.dsh`). A session lives at `<root>/<project>/<segment>/`, where `<project>` is `_no-cwd` when the header has no `cwd` and `(project-key cwd)` otherwise, and `<segment>` is `(encode-segment id)`. Directories are created with mode `0700`. Inside the session directory: one file per generation (`session.jsonl`, `session.v1.jsonl`, …, `session.v4.jsonl`, each with the suffix `.zstd` in a Zstandard root), the lock file `session.lock`, and transient files `session.v4.jsonl[.zstd].<12 hex>.tmp` (first materialization) and `session.migration.<16 hex>.jsonl[.zstd].tmp` (publication stage).

J2. `(encode-segment raw)` (`format.ts:199-214`): the empty string raises `exn:fail` `cannot encode an empty path segment`; `"."` gives `~002E`; `".."` gives `~002E~002E`; otherwise, per UTF-16 code unit of `raw`, a unit in `[A-Za-z0-9._-]` is kept and every other unit, `~` included, becomes `~` followed by four upper-case hex digits of the unit. An astral character therefore becomes two escapes.

J3. `(project-key cwd)` (`format.ts:225-245`): the empty string raises `cannot encode an empty project path`; per UTF-16 code unit, a run of `/`, `\` and `:` becomes one `-`, a unit in `[A-Za-z0-9._-]` is kept, and any other unit becomes `~XXXX` as in J2; leading `-` characters are removed; an empty result is `root`; the key is `--` followed by the first 251 characters and `--`. `/home/u/proj` gives `--home-u-proj--`.

J4. `(generation-log-filename version compression)` is `(session-format-log-filename version)` plus `.zstd` for `'zstd`. `(parse-generation-log-filename name compression)` requires that suffix and parses the rest with F2. The append target of a session is always the generation 4 file.

J5. A root belongs to one encoding. A generation file of the other encoding anywhere under the root raises `exn:fail` `session artifact "<path>" uses <.jsonl or .jsonl.zstd>, but this backend is configured for compression "<mode>"; use a separate root or select the matching compression mode` (the path and the mode are printed as JSON strings). A regular file whose name ends in `.jsonl` or `.jsonl.zstd` directly inside a project directory, and a file `<project>/<segment>.jsonl[.zstd]` for a requested id, raise `session artifact "<path>" uses the unsupported flat-file layout; use a separate root or move it into a project/session directory before loading`. The whole-root check runs once per backend instance before its first operation and its result is memoised, failure included; per-directory resolution and materialization repeat the check for the directory they touch.

J6. Generation selection (`index.ts:1536-1590`). For an id, look in every project directory of the root for `<project>/<segment>/` and in each pick the numerically highest canonical generation of the configured encoding. More than one project directory holding the id raises `duplicate JSONL session id "<id>" appears in multiple project directories`. Selected version below 4: the historical path (J25). Equal to 4: current. Above 4: `exn:fail:persistence:format-unsupported` with the newer-harness refusal and ` (raw log: <path>)`.

J7. Identity (`index.ts:1592-1628`). The header's `version` must equal the filename's version (`session generation filename identifies v<a>, but its header identifies v<b>`). The header's `id` and `cwd` must map back to the file's own path through J1; a different path is accepted only when both paths resolve to the same file (`resolve-path` equality, for case-insensitive file systems). Messages: `corrupt session log "<path>": requested id "<id>" does not match header id "<hid>"`, `corrupt session log "<path>": header id cannot name a storage path`, `corrupt session log "<path>": header id "<hid>" and cwd identify "<expected>"`.

**Create, open, single writer**

J8. `session-persistence-create` (`index.ts:360-379`), in order: check the cancel event; `materialize-create-header`; check the seeded and cut agreement by building the header line (the two messages of Data); J5; raise `exn:fail:persistence:already-exists` when the id is pending in this process or any generation of it exists on disk; register the session as pending with the revision `memory:session-persistence-jsonl:<n>`, `n` counting from 1 per tracker; return a write handle with cursor 0 that is not materialized. Nothing is written and no lock is taken.

J9. `session-persistence-open` (`index.ts:388-465`). `'read`: a pending session gives a read handle over its header with no events; otherwise load the stored log (J22, J25), retrying once when the source changed during a historical preparation, and return a read handle; a prepared historical log is kept on the handle as its primed content. `'write`: claim the id in the tracker (an existing claim, including a pending creator, raises `exn:fail:persistence:already-owned`); find the log (absent: `exn:fail:persistence-not-found`); take the lease on the session directory (J17) before reading; load the stored log; when it is a prepared historical log, publish its successor (J26); return a write handle with cursor the event count, the torn-tail state of J20, and the log as primed content. On any failure release the lease and the claim; when the release fails too, raise `exn:fail:persistence:aggregate` `session "<id>": write open failed and its lock release failed`.

J10. The handle lane (`storage.ts:85`, `:497-510`). Every mutation of one handle (`append`, `flush`, a live drain) runs through one FIFO lane: an operation starts only after every operation submitted before it has settled, a failed operation does not prevent later ones, and the submitter receives its own operation's result or exception. `session-handle-append!` validates and snapshots its batch with `materialize-append-batch` before entering the lane. Closed-handle refusal is checked on entry and again when the operation's turn starts.

J11. `persist-contiguous`, the body of every durable write (`storage.ts:319-345`), in order: a read handle raises read-only with operation `append`; an empty batch returns; take the lease when the handle has none; `assert-contiguous` against the cursor; when a torn-tail truncation is pending, perform it (J20) and clear it; when a recovered tail is pending, write it durably as one batch and clear it; write the batch (J13 or J14); then set materialized, advance the cursor by the batch length, drop the primed content, and set the handle's observed length to the cursor. Each step's pending state is cleared only after that step succeeded, so a failed step is retried by the next mutation.

J12. In-process ownership (`storage.ts:391-470`). The tracker maps a session id to its write handle, or to a claim marker while the handle is being built. `create` on a claimed id raises already-exists; `open` for write raises already-owned. A handle's close removes the entry and, when the session never materialized, its pending entry too.

**Durable writes**

J13. Materialization, the first durable write of a created session (`index.ts:1265-1388`), under `blocking`: refuse a generation of the other encoding in the session directory (J5); create root, project and session directories with mode `0700`, calling `fsync-directory` on the parent after each creation (the root's parent, the root, the project directory); when any generation already exists in the session directory raise `refusing to materialize "<id>": a log already exists on disk (open it instead)`; write the content to `<final>.<12 lower-case hex digits>.tmp`, created exclusively with mode `0600`, and `fsync` it; publish with `link(tmp, final)`, which fails with `EEXIST` and never overwrites; `fsync-directory` the session directory; remove the temporary, ignoring a failure of that removal only. When the link fails the temporary is removed and the failure propagates. The content is the header line plus `"\n"`, followed, when the batch is not empty, by the event lines plus `"\n"`; in a Zstandard root the header text is one frame and the batch text a second frame, never one combined frame.

J14. Append to a materialized log (`index.ts:1413-1451`), under `blocking`: encode the batch (the event lines plus `"\n"`; one Zstandard frame in a Zstandard root); open the generation 4 file for appending; record its size; write; `fsync`. On a write or sync failure: close, truncate the file back to the recorded size, `fsync`, and re-raise the original failure; when the rollback fails too, raise `exn:fail:persistence:aggregate` `failed to roll back append to "<path>"` holding both. The handle's cursor does not advance on failure, so the batch can be retried without duplicate seqs.

J15. `session-handle-flush!` (`storage.ts:190-200`), through the lane: a read handle raises read-only with operation `flush`; a materialized handle returns (appends are durable when they return); otherwise take the lease and materialize the header alone (J13 with an empty batch).

J16. Live write-behind (`storage.ts:245-317`, `:535-570`). The tracker's `session/event` listener appends the event to the buffer of the write handle for that session id; without a handle nothing is stored. The first buffered event arms one timer through the tracker's delay thunk (200 ms); later events join without re-arming it. When the timer fires, a task runs `drain-live` and reports a failure at `warning` on the plugin's logger as `session-persistence: background write for session "<id>" failed (buffered events retained): <js-error-string>`. `drain-live` is single-flight: a second caller waits for the running drain. It cancels the timer, clears the paused flag, and loops while the buffer is not empty, each pass taking the whole buffer inside one lane turn and writing it with J11. On failure the batch is put back at the front of the buffer, the paused flag is set (no timer is armed while it is set) and the failure is raised to the drain's caller. The `session/flush` listener returns `#f` without a writer and otherwise runs `drain-live` and then J15, so a failed background write is retried by an explicit flush and its failure reaches the flusher. The `session/disposed` listener starts `session-handle-close!` as a task and logs a failure at `warning` as `session-persistence: final drain for session "<id>" failed: <js-error-string>`.

J17. `session-handle-close!` (`storage.ts:203-243`), memoised so that every caller waits for the same completion: loop `drain-live`, wait for the lane, and repeat until a full pass leaves the buffer empty, stopping at the first drain failure; wait for the lane; release the lease; release the tracker entry whatever happened. One failure is re-raised as itself; a drain failure together with a release failure raises `exn:fail:persistence:aggregate` `session "<id>": close failed to drain and to release its write lock`.

J18. `session-persistence-flush!` (`storage.ts:472-490`): for each write handle present at the call, `drain-live` then J15; a handle-closed error counts as flushed; other failures are collected and raised as `exn:fail:persistence:aggregate` `session-persistence-jsonl flush failed`. Read handles and prepared historical logs are untouched: a service flush never publishes a migration.

J19. The lease (`lease.ts`; R7 Algorithms 6). Path `<session dir>/session.lock`. Acquisition, at most three attempts: create the session directory with mode `0700` if needed; open the lock file for writing, creating or truncating it (dsh mode `'w'`); call `flock(fd, LOCK_EX | LOCK_NB)`; `EAGAIN` or `EWOULDBLOCK` raises `exn:fail:persistence:already-owned`; compare the device and inode of the locked descriptor with those of the path now; when the path is gone or names another file, close and retry. After three mismatches raise already-owned. The port stays open for the handle's lifetime and is owned by the tracker's custodian; release closes it. The lock file is never deleted or renamed. `flock` is called through the FFI on the port's descriptor, so the lock is the same kernel lock family dsh's `tryLockExclusive` uses; `port-try-file-lock?` is not used.

**Reading**

J20. Torn tails (`format.ts:386-522`, `index.ts:815-872`, `:944-948`, `:994-1077`). Raw root: the bytes after the header line are split at `"\n"`; each complete record is parsed and passes rule V1 before anything else; a record that cannot be parsed (`corrupt session log: unparsable committed event at line <n>`) or that the decoder rejects (`corrupt session log: invalid committed event at line <n>: <detail>`) sets a remembered issue; later records are ignored, except that a later record whose `type` is `turn/end` re-raises the issue; the committed byte offset advances only past accepted records; a final fragment without a newline is dropped. When the committed offset is below the file size, the truncation offset is the committed offset and the recovered tail is empty. Zstandard root: Z1 scans frames; no complete frame raises `empty or header-less Zstandard session log`; frame 1 must decode to exactly one line ending in `"\n"` (`corrupt Zstandard session log: first frame is not exactly one header line`); every complete frame's plaintext is fed to the scanner and must leave no partial record (`corrupt Zstandard session log: complete frame contains a torn JSONL record`); for a torn final frame, Z5 yields the plaintext the partial frame produced (possibly none), the scanner takes it, the complete records in it are the *recovered tail*, and the truncation offset is the torn frame's start. An admission refusal of rule V1 is raised even after a remembered issue. `finish` ends the restore (strict header validation, recovery as stated) and applies V2 with `known-session-event-types`. Read handles serve the log without the torn bytes and with the recovered tail. A write handle, before its first new batch, truncates the file to the truncation offset and syncs, logs at `warning` `sessionPersistence: session "<id>" recovered from a torn tail; incomplete tail bytes were discarded`, and then durably rewrites the recovered tail as one batch (J11).

J21. Header record (`format.ts:340-378`), in order: the record must be one newline-terminated line (`empty or header-less session log`); valid JSON (`corrupt session log: header line is not valid JSON`); an object (`corrupt session log: first line is not a JSON object`); a numeric `version` other than 4 raises format-unsupported with the version refusal before any structural check; `sandboxMode` or `approvalPolicy` raises `session header uses retired policy baseline fields`; then the key set and field checks of the header table (`corrupt session log: first line is not a session header`).

J22. Loading a current log (`index.ts:780-872`). A memo of at most two parsed logs, keyed by session id and guarded by revision, serves repeated loads; every local mutation for an id deletes its entry; insertion evicts the oldest entry beyond two. A miss reads the file with J23 and decodes it with J20. A decode failure that is a format-unsupported error is re-raised with ` (raw log: <path>)` and the location; any other failure raises `exn:fail:persistence:corruption` `session "<id>": stored log is corrupt: <js-error-string> (raw log: <path>)`. Then J7, S1 and S3 with the location. The event state is `'shared-frozen`; only an unmaterialized pending session reports `'detached` with no events.

J23. Stable read (`generation.ts:255-285`): stat, read the whole file, stat again; equal identities end the read; otherwise repeat once; if the identities still differ, return the second read truncated to the size seen before it, with that earlier identity. An identity is the five integers device, inode, size, modification time and change time in nanoseconds.

J24. `session-handle-read` (`storage.ts:101-163`). After the argument checks: a handle with primed content serves it when it is a write handle, or when no generation 4 file exists yet; a read handle whose session has gained a generation 4 file drops the primed content and reads the current file. A write handle that is not materialized returns no events with state `'detached`. Otherwise resolve the current file: read it (J22); or, when only a pending entry exists, return no events; or raise not-found. A read that finds fewer events than this handle already observed raises `session "<id>": stored log shrank below a previously observed prefix (<n> < <m>)`. The result is the slice `[offset, offset + length)` of the log.

J25. Historical generations (`index.ts:569-760`; R7 Algorithms 10). One shared preparation exists per session id for a given source path and source revision; callers join it; it is cancelled (`session migration preparation aborted`) only when its last waiter has left; a failure is wrapped as `session migration preparation failed` with the cause unless it is a typed persistence error. Steps: from a header listing take the direct children (`origin` `"subagent"` and `parentSession` equal to this id); for each child decode its selected generation with recovery `'recoverable` and validation `'current` through `historical-session-format-catalog` (version at most 3) or `session-format-catalog`, record a stat witness, and build its catalog source with `historical-child-catalog-source`; a child that cannot be decoded contributes `{childId, childCreatedAt, descriptorCount: 0, descriptor: null, sourcePath}` and a `warning` `sessionPersistence: session "<id>" catalog retained a child with unknown descriptor (raw log: <path>): <js-error-string>`; a child whose decoded header disagrees with its listing raises the source-changed error. Then decode and migrate the parent with `(make-session-format-catalog/children facts)`, recovery `'recoverable`, validation `'transformed`; re-validate the children's membership and witnesses; S3; memoise the result as a *prepared* log. A read open returns it without writing anything. `stat` and `list` never start a preparation. A refusal of the migration surfaces as `exn:fail:persistence:format-unsupported` `<reason>; source v<N> artifact remains unchanged (raw log: <path>)`.

**Publication of a successor** (write open only; `generation.ts:660-1000`; R7 Algorithms 11)

J26. Stage: encode the migrated artifact into `session.migration.<16 lower-case hex digits>.jsonl[.zstd].tmp` in the session directory, created exclusively with mode `0600` (a name collision picks a new token): the generation 4 header line, then every event line, each with `"\n"`; in a Zstandard root the header is one frame and all event rows together are one frame. Hash the written bytes with SHA-256 and count them; `fsync`. A write failure removes the stage (`failed to clean migration temporary "<path>" after an earlier failure` when that fails too).

J27. Verify the staged file independently of the encoder state, on a `blocking` thread, with at most two verifications running per backend instance: read the file between two stats that must agree (`current session generation changed during verification`); decode it strictly as a current log with no torn tail (`current session generation has a torn physical tail`); S3; the header id must be the expected id (`current session generation contains id "<a>", expected "<b>"`) and the event count the expected count (`current session generation contains <n> events, expected <m>`); construct a restored session from it (`restore-session` with `current-session-message-projections`); and replay every embedded stream: for each `assistant/message` and `assistant/attempt`, `expand-assistant-stream` and assembly must succeed (`seed <type> at index <i> has an invalid embedded stream`), and for an `assistant/message` with a non-empty stream the assembled blocks (the interrupted blocks when `interrupted` is true), usage and replay state must equal `message.content`, `usage` and `message.source.replayState` (`… content disagrees with its embedded stream`, `… usage disagrees …`, `… replay state disagrees …`). The verifier's byte count and digest must equal the stage's (`staged session generation changed during verification`).

J28. Publish: re-validate the related child sources; stat the source and compare with the identity read at preparation (a difference raises the source-changed error; a write open fails once and the next write open prepares again); `link(stage, session.v4.jsonl[.zstd])`; `fsync-directory`; remove the stage. When the link fails with `EEXIST`, accept the existing target only if the directory entry has exactly the canonical name (`target resolves to noncanonical directory entry "<name>"`), is a regular file and not a symbolic link (`target is a symbolic link`, `target is a non-regular file`), has at least the stage's byte count (`target bytes are shorter than the migrated generation`) and its first bytes hash to the stage's digest (`target bytes do not begin with the migrated generation`); an appended tail is allowed. Otherwise raise a target-conflict error. The source generation is never modified, renamed or deleted.

**Observation**

J29. Revisions (`index.ts:200-210`, `:1121-1136`). Current generation: the five identity integers of J23 in decimal joined with `:`. Historical generation: that string, `:`, and the lower-case hex SHA-256 over the concatenation, for every selected generation path under the root sorted in JavaScript string order, of `(jvalue->string (list path revision))`, where a vanished file contributes the revision `"missing"`. One `list` computes the corpus hash once.

J30. `session-persistence-stat` (`index.ts:483-514`): a pending session gives `{header, revision}` only; otherwise select the generation, read its header (J31), and return header, format status, revision, size and location `{kind: "jsonl", path}`; a file that vanished gives `#f`. `session-persistence-list` (`index.ts:522-566`, `:1138-1170`): snapshot the pending entries first, then scan storage, so that a session materializing during the scan is not lost; pending sessions not found on disk are appended as `{header, revision}`. Directory, header and stat reads share one limiter of `listConcurrency` concurrent operations. A header that is unsupported or corrupt, including a corrupt Zstandard header frame, omits its session from the list; a filename and header version mismatch, an identity and path mismatch (J7), and a duplicate id reject the listing.

J31. Header-only reads (`index.ts:1472-1532`) read the file in 8192-byte chunks until the first newline (raw) or until Z1 finds the first complete frame, which alone is decompressed and must be one header line; a failure there raises corruption `corrupt Zstandard session log: header frame failed validation: <js-error-string> (raw log: <path>)`. The header value goes through `format-catalog-read-header`; `'unsupported` raises format-unsupported with the reason, or the version refusal for a newer version, and the raw-log suffix; `'malformed` and unparsable JSON give "no header". `sandboxMode` or `approvalPolicy` raise as in J21.

### Z. Zstandard (`zstd.ts`, `zstd-public-decoder.ts`)

Z1. `(scan-zstd-frames bytes [max-frames #f]) -> (values (listof (cons/c start end)) (or/c torn-start #f))` is pure and is ported exactly from `zstd.ts:48-105`: each frame starts with the magic number `#xFD2FB528` stored little-endian (`corrupt Zstandard session log: invalid frame magic at byte <o>`); the descriptor byte has reserved bits `#x18` clear (`… reserved frame-header bit at byte <o>`); the content-size flag (top two bits), the single-segment bit `#x20`, the checksum bit `#x04` and the dictionary flag (low two bits; 3 means four bytes) give the remaining header length `(if single-segment 0 1) + dictionary bytes + content-size bytes`, where content-size bytes is `(if single-segment 1 0)` for flag 0 and `2^flag` otherwise; blocks follow, each with a three-byte little-endian header whose bit 0 is "last block", bits 1 to 2 the type (3 raises `… reserved block type at byte <o>`) and the rest the size, the payload being one byte for type 1 (RLE) and `size` bytes otherwise; a four-byte checksum follows the last block when the checksum bit is set. Running out of bytes anywhere inside a frame, including fewer than four bytes at a frame start, ends the scan with that frame's start as the torn start. Skippable frames are not accepted, as in dsh.

Z2. The binding (`private/zstd-ffi.rkt`) loads `(ffi-lib "libzstd" '("1" #f))` lazily, on first use, and binds only: `ZSTD_createCCtx`, `ZSTD_freeCCtx`, `ZSTD_CCtx_setParameter`, `ZSTD_compress2`, `ZSTD_compressBound`, `ZSTD_createDCtx`, `ZSTD_freeDCtx`, `ZSTD_decompressStream`, `ZSTD_DStreamOutSize`, `ZSTD_isError`, `ZSTD_getErrorName`. `(zstd-available?)` is `#t` when the library loads and the symbols resolve; it never raises. Contexts are created per call and freed in a `dynamic-wind` post thunk. All calls run under `blocking`.

Z3. `(zstd-compress-frame bytes) -> bytes?` produces exactly one frame with `ZSTD_c_checksumFlag` (parameter 201) set to 1 and the library's default level, as `zstdCompress(input, {params: {[ZSTD_c_checksumFlag]: 1}})` does. Every frame this package writes has the checksum bit set in its descriptor.

Z4. `(zstd-decompress-frame bytes) -> bytes?` decodes one complete frame with the streaming API until `ZSTD_decompressStream` returns 0, with all input consumed; an error code, leftover input, or a frame that does not end raises `exn:fail`. The library verifies the checksum. The log reader wraps a failure as `corrupt Zstandard session log: frame at byte <start> failed validation`. The streaming API is used because frames written by a streaming compressor (dsh's publication stage) carry no content size.

Z5. `(zstd-decompress-prefix bytes) -> bytes?` feeds an incomplete frame and returns whatever plaintext the decoder produced before the input ran out, which is what `zstdDecompress` with `finishFlush: ZSTD_e_flush` returns; an error code from the decoder gives the plaintext produced before the error, and a frame torn before any plaintext gives `#""`.

Z6. Availability. With `compression: "none"` the library is never loaded. With `compression: "zstd"` (the default) and the library available, the root is a Zstandard root. With `compression: "zstd"` and the library unavailable: when `x-racket.zstdFallbackRoot` is absent, the plugin fails at load with `session-persistence-jsonl: compression "zstd" needs libzstd.so.1, which could not be loaded (<reason>); install it, or set compression "none" with a separate root`; when it is set, the backend runs with compression `'none` on that root and logs once at `warning` `session-persistence-jsonl: libzstd is unavailable; storing uncompressed JSONL under "<fallback root>" (open it from dsh with compression "none")`. The backend never writes `.jsonl` files into a root configured for Zstandard, because rule J5 would make dsh refuse that whole root.

Z7. dsh yields to its event loop between frames when 500 ms have passed. Here frame decoding runs under `blocking`, so other tasks keep running; the reader checks the cancel event between frames.

### X. Interoperability with dsh

These invariants are what makes a session written by the Racket harness openable by dsh at the pinned commit, and a session written by dsh openable by the Racket harness. Each is pinned by a test named in Tests ("Interoperability").

*Racket writes, dsh reads.*

X1. Location. The file is at the path J1 to J4 compute from the header's `id` and `cwd` and the configured encoding. dsh finds a session by listing project directories and looking for the encoded id, and then checks that the header maps back to the same path (J7), so the path functions must agree with dsh for every id and cwd, astral characters included.

X2. Generation. The Racket harness writes only `session.v4.jsonl[.zstd]`, never a higher or lower generation, and never modifies, renames or deletes another generation in the directory.

X3. Header bytes. Line 1 is `(jvalue->string (header-line header cut))` plus `"\n"`: the ten keys in the order of the header table, optional keys omitted, `delegationDepth` always present.

X4. Row bytes. Every further line is `(event-line event)` plus `"\n"`: the envelope keys in the order dsh's producers write them, `data` in the producer's key order, `sourceEventSeqs` range-encoded by C4, numbers and strings formatted by `cordis-data` as `JSON.stringify` formats them. No blank lines, no byte order mark, no carriage returns.

X5. Framing. Raw root: UTF-8 text, every record ends in `"\n"`. Zstandard root: a concatenation of independent standard frames, each with the content checksum; frame 1 holds exactly the header line; every later frame holds whole records and ends on a record boundary; one frame per durable batch. dsh's structural scanner (Z1) and Node's decoder accept any standard frame header variant, so the library version and level do not matter.

X6. Content admission. Everything the Racket harness appends passes rules V1, V2 and S3, which are the checks dsh applies when it opens the file: only known or ignorable event types, dense seqs from 0, safe-integer times, surface metadata on exactly the five surface types, no retired syntax, producer-owned message sources, tool-role results, and the inherited marker agreeing with `isSeeded`. The Racket log may end inside a turn; dsh accepts open tails and repairs them on resume as the Racket harness does.

X7. Exclusion. A Racket write handle holds `flock(LOCK_EX)` on `session.lock` for its lifetime, taken with the same system call dsh uses, and never deletes the lock file. A dsh process that tries to resume the session meanwhile gets `SessionAlreadyOwnedError`, and the reverse.

X8. Crash states. A crash of the Racket writer leaves either a complete file, a file with a torn last record or frame, or no file; J13 and J14 never leave a partly written file under the final name without a preceding complete header, and dsh's tail repair handles the torn cases exactly as J20 does.

*dsh writes, Racket reads.*

X9. Every generation 0 to 4 is read through the codec of its version and the four edges; a historical generation is migrated in memory for readers and published as a generation 4 successor only by a write open, with the source untouched (J25 to J28). The frozen validators decide which historical logs are accepted and refuse the rest with dsh's texts.

X10. Events keep their JSON form. A row whose keys are in an order the Racket writer would not produce, or that carries an unknown ignorable event type, is read, served and, if it is ever re-encoded (publication, export), written back with its own key order.

X11. Both encodings, every frame header variant of Z1, range-encoded and plain `sourceEventSeqs`, packed chunk rows, and torn tails are accepted as dsh accepts them, and refused where dsh refuses them, with the same error class and text.

*Shared home.*

X12. The projection cache record (Data), the SQLite index (schema, `application_id`, `user_version`, revision strings of J29) and the `delivery-accepted` watermark events are written in dsh's forms, so derived data left by one implementation is usable, or at worst discarded and rebuilt, by the other. Nothing in this package writes a file that would make dsh refuse a root.

Known limit: a session id or `cwd` that contains a lone UTF-16 surrogate cannot be represented in a Racket string. `cordis-data` reads such an escape as U+FFFD, so the header no longer maps to its path and J7 refuses the session. dsh mints UUID-based ids, so no shipped producer creates such an id.

### P. Projection registry (`session-projection/src/index.ts`; R7 Algorithms 17, 18)

P1. `(same-value? a b)` is JavaScript `Object.is` over jvalues, which is the gate dsh uses for "the state changed" and "the view changed": two strings are the same when `string=?`; two numbers when they are `=` and have the same zero sign; booleans and `'null` when `eq?`; every other value (a jobject, a list) when `eq?`. An `apply` function must return its argument itself when nothing changes. One consequence differs from dsh: every empty list is `eq?` in Racket, so a view that returns a fresh empty array on each call counts as unchanged here and as changed in dsh; no unit of this corpus has such a view.

P2. `projection-register!` validates before registering: a `state-version` that is not a non-negative safe integer raises `exn:fail` `session projection <JSON string of key> stateVersion must be a non-negative integer, got <v>`.

P3. Units and references (`index.ts:379-444`). The registry keeps an insertion-ordered table from key to unit; a unit holds the definition, a weak `eq?` table from session to cell, and a reference count. Registration is one effect on the caller's context labelled `sessionProjections.register()`. Inside it: when the key has no unit, or its unit has count 0, install a new unit with count 1 in the key's table position (a released unit is replaced by the new one; a new key goes last) and drop the cached summary key list; otherwise the existing unit's `state-version` must equal the new one (`session projection key <JSON key> is already registered at stateVersion <a>; refusing to share it with stateVersion <b>`) and its summary mark must equal the new one (`session projection key <JSON key> is already registered with summary=<a>; refusing to share it with summary=<b>`), and the count is incremented. The summary mark of a definition is `undefined` when it has no view and otherwise `true` or `false`, printed with those words. The inverse decrements the count and, at 0, drops the cached summary key list; the unit stays in the table as *released*. After the effect is registered the procedure yields once (`yield-task`) and then requires the caller's fiber to be loading or active, raising `exn:fail:cordis:inactive` otherwise, so that a registration disposed during the hand-off never exposes a handle. The handle keeps its unit, so it stays readable after release and keeps folding its own cells.

P4. Cells (`index.ts:826-879`). A cell is `(state, observed seq, previous view, current view)`; the observed seq is `-1` before any event; a view slot may be unset. `cell-for` of a unit and a session: when no cell exists, fold `init` (called with the header jobject and the inherited event count) and then `apply` over the session's whole log and store the cell at the last seq; otherwise advance it through `(- (session-seq session) 1)`. Advancing applies `apply` to each event in seq order, shifting the view slots (previous becomes current, current becomes unset) whenever the state changed by P1; a missing or misnumbered event raises `session projection <JSON key> cannot advance across missing seq <n>`. `projection-state` and `projection-handle-state` return `cell-for`'s state.

P5. On `session/created` (`index.ts:297-308`): only when the session has no events, every live unit (count above 0) without a cell for it gets a cell from `init` at observed seq `-1`. A session with events is folded lazily.

P6. Eager drive on `session/event` (`index.ts:887-947`). For each live unit in table order: skip when its cell already observed this seq; build a missing cell over the log prefix before this event, or advance an existing cell to the previous seq; `next = (apply state event)`; `changed` is `(not (same-value? next state))`; store the state and the observed seq. For a unit with a view when `changed`: the previous view slot takes the current one; when at least one change listener of either kind is registered, compute `(view next)` into the current slot and, if it is not the same value as the previous slot (an unset previous slot never is), require `view-ok?` (a failure raises `exn:fail`), record the change `(key . value)` and call every `on-changed` listener in registration order with `(session key value seq)`; when no listener is registered the current slot becomes unset. After all units, and also when a unit or a listener raised, every `on-event-changed` listener is called once with the changes collected so far, if any, and `(session changes seq)`; then the exception propagates to the store, which contains and logs it. An unchanged state keeps its view slots.

P7. `projections-snapshot` (`index.ts:514-528`): for each live unit that has a view and is selected by `keys`, `cell-for` and the checked view; `as-of-seq` is the session's last seq, or `-1`. Units that are not selected, and units without a view, are neither folded nor advanced by this read.

P8. `projections-summary-keys` (`index.ts:570-584`): the keys of live units whose view is part of summaries, in table order. The same list object is returned until a registration installs a unit or a release drops a unit to count 0.

P9. `projections-checkpoint` (`index.ts:605-619`): one row `{ver, seq, val}` per unit in table order: a live unit through `cell-for`; a released unit only when it already has a cell for this session, with that cell as it stands.

P10. `projections-restore-floor` (`index.ts:637-648`): over live units, `need` is `(max (+ row.seq 1) 0)` when the checkpoint has a row whose `ver` equals the unit's `state-version`, else 0; the result is `(max (- (min need …) 1) 0)`, or `#f` when no unit is live.

P11. `projections-view-checkpoint` (`index.ts:661-683`): for each live selected unit with a view whose row has a matching `ver`: when the row's `val` passes `state-ok?`, the value is the checked view of that state; a row that fails `state-ok?` is skipped. No log is read.

P12. `projections-restore` (`index.ts:711-757`). `end` is the seq of the last supplied event, or `base-seq - 1`. For each live unit: its row is usable when its `ver` matches and `base-seq - 1 <= row.seq <= end`; an unusable row with `base-seq > 0` raises `session projection <JSON key> cannot restore from seq <base>: its checkpoint row is missing, version-mismatched, or beyond the supplied log end; re-read from seq 0`; the starting state is the row's `val` (which must pass `state-ok?`, else `exn:fail`) or `init`; fold `apply` over the events after the row's seq, each of which must carry the expected seq (`session projection <JSON key> cannot restore across missing seq <n>`); the snapshot value is the checked view; the refreshed row is `{ver, seq: end, val: state}`. The results are the snapshot at `end` and the refreshed checkpoint, which covers live units only.

P13. `projections-hydrate!` (`index.ts:769-816`): when every live unit already has a cell for the session at exactly `end`, return the checked views of those cells; otherwise run P12 with the session's header and inherited count and install each refreshed row as that unit's cell, unless the unit already has a cell beyond the row's seq.

### K. Projection cache (`session-projection-cache/src/index.ts`; R7 Algorithms 19)

K1. Identities. The lifecycle identity of a header is `{formatVersion: <header version>, createdAt, cwd?, isSeeded}`; the full identity adds `inheritedEventCount` and raises `exn:fail` `unseeded projection-cache identity inherited event count must be 0` for an unseeded header with a non-zero count. A stored identity matches a lifecycle identity when `createdAt` is equal, `cwd` is equal (absent equal only to absent) and `isSeeded` (absent meaning false) is equal; the *current* match also requires an equal `formatVersion`; the *full* match also requires an equal `inheritedEventCount` (absent meaning 0); the *predecessor* match requires the stored `formatVersion` to be absent or lower than the header's.

K2. `projection-cache-cached-snapshot`: read the record for the header's id from the in-memory table; return `#f` without a record or without a current match; otherwise `projections-view-checkpoint` over its rows with `keys`, and `as-of-seq` the lowest `seq` among the rows whose key produced a value; `#f` when no key did.

K3. `projection-cache-cached-predecessor-title`: as K2 with the predecessor match and the single key `title`.

K4. Write policy (`index.ts:312-372`). On `session/created`: a write with trigger `create`. On `session/event`: `turn/end` starts a write with trigger `turn/end`; any other event increments the session's dirty count and, when the count reaches `writeEveryEvents`, starts a write with trigger `count threshold`, and otherwise arms one timer of `writeIntervalMs` when none is armed, whose expiry starts a write with trigger `interval`. On `session/disposed`: a write with trigger `detach`, then the session's dirty state is cleared and dropped. Each of these writes is a spawned task that calls K5 and logs a failure at `warning` as `session projection cache: <trigger> write for "<id>" failed (cache stays stale): <js-error-string>`. The effect `sessionProjectionCache.timers` cancels every armed timer and clears the dirty table. The timer is an injected delay thunk, as in J16, for tests.

K5. `projection-cache-write!` (`index.ts:228-245`), in order: take `projections-checkpoint`; reset the session's dirty count and cancel its timer; when the session is still the store's live instance for its id, `(sessions-flush sessions session)` and wait, so that the cache never leads the durable log; then `kv-table-put!` the record `{identity: <full identity>, rows}`. Rows that are not lossless JSON raise `exn:fail:contract` `projection checkpoint is not losslessly JSON-serializable (a unit state violates the plain-JSON contract)`.

K6. `projection-cache-hydrate-prepared!`: with a record that has a full match, `projections-hydrate!` with its rows and base seq 0, and on any failure of that call a second attempt with an empty checkpoint; without such a record, the empty checkpoint directly. `projection-cache-cold-snapshot`: `projections-restore` with the matching record's rows, or none, over the complete log from seq 0; return the snapshot; start a task that puts the refreshed rows and logs a failure at `warning` as `session projection cache: cold-read write-back for "<id>" failed (cache stays stale): <js-error-string>`.

### T. Titles (`session-title`, `session-title-llm`, `session-title-first-prompt-llm`; R7 Algorithms 20)

T1. Normalization (`normalize.ts`). `clean` removes, in this order: OSC sequences (`ESC ]` or U+009D up to BEL, `ESC \` or the end of the text), CSI sequences (`ESC [` or U+009B, parameter bytes `0` to `?`, intermediate bytes space to `/`, one final byte `@` to `~`), two-character escapes (`ESC` followed by `@` to `_`), the control characters U+0000 to U+0008, U+000B, U+000C, U+000E to U+001F and U+007F to U+009F, and the characters U+200B, U+200E, U+200F, U+202A to U+202E, U+2060 to U+2064, U+2066 to U+206F and U+FEFF; then replaces every run of JavaScript whitespace (`\s`) by one space and trims. `truncate-title-utf8` returns the text when it fits in `max-bytes` UTF-8 bytes and otherwise the longest prefix of whole characters that fits; `max-bytes` that is not a positive integer raises `maxBytes must be a positive integer`. `normalize-session-title` is `clean`, truncate, trim the end. `fallback-session-title` is `clean`, the first `max-words` space-separated non-empty words joined by single spaces (`maxWords must be a positive integer`), truncate to `max-bytes`, trim the end. The five regular expressions are `normalize.ts:1-5`.

T2. An *eligible message* is a `user/message` event whose `source.kind` is `"user"` and whose text blocks, joined with `"\n"`, normalize (with no byte limit) to a non-empty string; its record is `{seq, text}` with the joined, unnormalized text. The `titleInput` unit keeps the first such record, their count and the last seq. `fold-session-title` returns the snapshot of the last `session/title` event: `{title, messageSeqs, source, eventSeq: <event seq>, updatedAt: <event time>}`.

T3. `session-title-register!` (`index.ts:482-507`, `:777-797`) validates the provider with the messages `session-title service disposed`, `session-title provider must be an object`, `session-title provider id must be a non-empty string`, `session-title provider automatic mode is invalid`, `session-title provider "<id>" requires generate()`, then refuses a second live registration. A registration whose disposal has started no longer counts as live, so a replacement may register while the old provider's calls drain; the old provider's late results never commit.

T4. On an eligible message (`index.ts:510-539`). When the service's own fiber is still loading: start a task that waits for the fiber and then, if the service is active and the session is still live, runs T5; nothing else. Otherwise: do nothing when the service is not active or the current title's source kind is `"user"`. When a provider is registered and not closing, schedule automatic work if its mode is `'all-prompts`, or if the header is not seeded, its origin is not `"subagent"`, the `titleInput` count is 1 and no title exists; scheduling supersedes the session's work (T7) with the reason `newer user message superseded title generation` and records `pending {registration, revision, throughSeq: <event seq>}`. Then, always, start a task that runs T5 and logs a failure at `warning` as `session "<id>": fallback title update failed: <js-error-string>`. The listener itself never waits and never appends; the tasks run after the append that published the message has returned.

T5. `ensure-fallback` (`index.ts:810-853`): return the current title when one exists; return `#f` when `titleInput` has no first message or its fallback title (T1 with `fallbackMaxWords` and `fallbackMaxBytes`) is empty; join an in-flight fallback of the same session; otherwise, in a new task step, require the service to be active and the session live (`session "<id>" is not live in this store`), re-check for a title, and append `session/title {title, messageSeqs: [first.seq], source: {kind: "fallback"}}`.

T6. Starting pending work (`index.ts:542-590`). A `request/header` event whose seq is greater than the pending `throughSeq` starts it with the route `{provider, model}` of the header's config. An `llm/stream` request starts it when the request is loop-built (`agent-loop-request?`), has a session id whose live session has pending work, the session's last step boundary is a start (`agents-turn-boundary-of`), and the request's provider and model equal those of the session's current request header; the route is the request's. Starting removes the pending record and spawns a task that re-checks that the registration is still the live one, that the session's work state is the same and that its revision is the pending revision, activates the work, runs T7, and logs a failure that is not a supersession at `warning` as `session "<id>": automatic title generation failed: <js-error-string>`. The `llm/stream` listener always returns `(next)`.

T7. Work, supersession and the provider call (`index.ts:593-760`). Each session has `{revision, pending?, active?, fallback?}`. *Superseding* cancels the active work's cancel source with the given reason, drops the pending record, and increments the revision. *Activating* creates a cancel source and a composed cancel event (the work's source, the service's lifetime source, and the caller's event for a refresh). The provider run, each step preceded by a check that the service is active, the work not cancelled and still the session's active work at the same revision: T5; collect the eligible messages through `throughSeq` and the current title; call `generate` with a `title-request`; validate the result: a string title (`session-title provider title must be a string`) that normalizes with `maxTitleBytes` to non-empty (`session-title provider returned an empty title`); a non-empty `message-seqs` list (`session-title provider must identify at least one source message seq`) whose members are seqs of the request's messages in strictly increasing request order (`session-title provider messageSeqs must be unique, ordered seqs from the request`); a `model` that is absent or has non-empty `provider` and `model` strings (`session-title provider result model must contain non-empty provider and model strings`); then append `session/title {title, messageSeqs, source: {kind: "provider", provider: <id>, model?}}`. The active record is cleared when the run ends.

T8. `session-title-rename!` (`index.ts:411-431`): service active; session live; normalize with `maxTitleBytes`; empty raises the invalid-title error; supersede with `user rename superseded automatic title generation`; append `session/title {title, messageSeqs: [], source: {kind: "user"}}`; return the snapshot. A user title pins the title: T4 schedules nothing while it stands.

T9. `session-title-refresh!` (`index.ts:440-473`): check the cancel event, the service and liveness. Without a live provider, or without any eligible message: when the current title is a user title and a first message exists, append the fallback over it and return the snapshot; otherwise T5. With a provider: supersede with `explicit title refresh superseded older generation`, activate work through the last eligible seq with the caller's event, and run T7 with the route of the session's current request header, if any.

T10. Disposal. The effect `sessionTitle lifecycle` cancels the lifetime source with `session-title service disposed`, marks the registration closing and removes it, drops every pending record, cancels every active work, waits until every in-flight task has settled, and clears the work table. `session/disposed` cancels the session's active work with `session disposed during title generation` and drops its state. A provider's disposer cancels its work with `session-title provider "<id>" was disposed`.

T11. The first-prompt provider (`session-title-first-prompt-llm/src/index.ts`). `generate` takes the first request message (`first-prompt title provider requires one human message`) and calls T12 with: the system prompt, the five lines of `index.ts:64-70` joined with `"\n"`, with `targetWords` and `targetCjkCharacters` interpolated; the input `Generate the session title from this JSON array of human messages:\n` followed by `(jvalue->string (list (jobj [seq …] [text …])))`; `message-seqs` the first seq; and the reasoning effort selector that returns the id of the model's first listed effort, or `#f`. The title is taken from the response: a finish kind `tool-calls`, or any `tool-call` block, raises `session-title-llm: title output must contain text only`; `max-tokens` raises `session-title-llm: title output reached maxOutputTokens`; the text blocks are joined with one space; the first non-empty trimmed line is taken; when the whole line is wrapped in one, two or three `*` on both sides with non-space inner ends and the inner text does not contain that marker, the inner text is taken; the result is normalized with no byte limit; empty raises `session-title-llm: title model produced no text`. The result is `(title-result title (list first-seq) <response model>)`.

T12. `resolve-session-title-llm-config` and `execute-session-title-llm` (`session-title-llm/src/index.ts`). Config checks, in order: `session-title-llm: configuration is required`; an unknown key (`session-title-llm: unknown config key "<k>"`; the keys are `maxInputBytes`, `maxOutputTokens`, `timeoutMs`, `provider`, `model`); the three positive integers (`session-title-llm: <name> must be a positive integer`); `session-title-llm: timeoutMs must not exceed 2147483647`; `session-title-llm: provider and model must be supplied together`; `session-title-llm: provider and model overrides must be non-empty strings`. Execution, in order: check the request's cancel event; no message seqs raises `session-title-llm: at least one source message is required`; an input above `maxInputBytes` UTF-8 bytes raises `session-title-llm: input is <n> bytes, exceeding maxInputBytes <m>`; the route is the configured pair, else the request's route, else raise `session-title-llm: no logged request route is available; configure provider and model together`; build one user message with the input as its text block and source `{kind: "dsh-session-title-llm"}`; start a deadline of `timeoutMs` composed with the request's cancel event: a cancel event that becomes ready when the request's event does, with its reason, or when the time is up, with the reason `(exn:fail:timeout-reason "SESSION_TITLE_TIMEOUT after <ms>ms" marks "SESSION_TITLE_TIMEOUT" ms)` (dsh `TimeoutReason` of `packages/util/timeout`; the deadline helper of `dsh-util` when it exports one, else a private one), and that is released when the call ends; `(llm-prepare-call llm (jobj [provider …] [model …] [maxTokens <maxOutputTokens>]) #:cancel deadline #:configure …)` where `configure` adds `reasoningEffort` when the selector returns one; append `session/title-llm-request` (Data) to the request's session before any chunk is pulled; check the deadline; stream the prepared call with a request that has the call's config, the messages, the system prompt, the session id, purpose `"session-title"` and the deadline as cancel event, pushing every chunk into an assembly and checking the deadline per chunk; a finish of kind `error` or `aborted` raises `exn:fail:session-title-llm`, a plain `exn:fail` substruct with a `code` field, holding the failure's message and code (dsh throws an `Error` with a `code` property, so S7 prints it as `Error: <message>`); the result is the assembled blocks, the finish reason and the route.

### U. Stats and turn outline

U1. `session-stats-projection` (`session-stats/src/projection.ts:107-190`; R7 Algorithms 21). `step/start` sets `openStep` to `{turn, step, startTime: <event time>, firstTokenTime: null}`. `assistant/attempt` for the open step (same turn and step) records `(assistant-stream-first-token-time stream)` once, when it exists and none is recorded. `assistant/message` for the open step adds `(max 0 (- time startTime))` to `llmMs`, clears `openStep`, and, when a first token time exists (recorded, or from this message's stream), adds `(max 0 (- firstToken startTime))` to `ttftMs`, 1 to `ttftSteps`, and, when `usage.outputTokens` is a non-negative finite number, `(max 0 (- time firstToken))` to `decodeMs` and the tokens to `decodeTokens`. `tool/call` stores the event time under its `callId` in `pendingCalls`. `tool/result` whose `message.source.callId` is a key of `pendingCalls` adds `(max 0 (- time dispatched))` to `toolMs` and removes the key. `step/end` adds 1 to `steps`, adds 1 to `turns` when its turn differs from `lastTurn`, sets `lastTurn` and clears `openStep`. `turn/end` empties `pendingCalls` when it is not empty. Every other case returns the same state.

U2. `turn-outline-projection` (`session-turn-outline/src/projection.ts`; R7 Algorithms 22). `turn/start` with a turn greater than the last entry's appends `{turn, seq: <event seq>, prompt: "", response: ""}` and clears `draft`. A `user/message` with source kind `"user"`, when the last entry's `prompt` is empty, sets it to `(turn-outline-preview content 50)` unless that is empty. An `assistant/message` sets `draft` to `(turn-outline-preview message.content 120)` unless that is empty or equal to the current draft, keeping the `turns` list itself. `turn/end` with a non-empty draft commits it as the last entry's `response` (when there is an entry and it differs) and clears `draft`. `(turn-outline-preview content limit)`: join the text blocks with single spaces, stopping and marking "unread" before a block once the text has reached `2 × limit` UTF-16 units and clipping a block longer than `2 × limit` units to that length (also "unread"); replace whitespace runs by one space and trim; when the result is longer than `limit - 1` units, cut it to `limit - 1` units, trim the end and append `…`; otherwise append `…` only when "unread". Lengths are UTF-16 units (`utf16-length`, `utf16-substring`).

### L. Telemetry (`session-telemetry`, `session-telemetry-otel`; R7 Algorithms 23)

L1. The handoff cursor is a module-level weak `eq?` table from session to the highest seq handed to a sink, shared by every coordinator in the process, as in dsh, so that a reloaded backend does not hand the same events over twice. This is the one module-level table of this package (Racket design notes).

L2. `telemetry-capture-session!` (`coordinator.ts:118-131`): start after the session's cursor; without a cursor start at seq 0 when `include-history?` is true or the session's first lifecycle seq is 0, else at `(session-first-lifecycle-seq session)`. For each event from there, stopping after `through-seq` when given, run L3 inside its own containment (L6).

L3. One ledger record per event: `sourceEvent {sessionId, envelope}`, `channel "ledger"`, `time` the event time, `severity` `"error"` for a `tool/result` whose `message.isError` is true and for a `turn/end` whose `reason.kind` is `"error"`, else `"info"`, `attributes` with, in order, `session.id`, `session.format_version`, `event.type`, `event.seq`, then `session.cwd`, `session.parent_id` and `session.seed_length` (the inherited event count, for a seeded session) when applicable, and `body` the event data. The record goes through L4 and is then delivered: `emit`, then the cursor is set to the event's seq.

L4. Redaction: `(dispatch-session-telemetry/record ctx record (lambda () record))`; the result is the record delivered.

L5. Live mode (`coordinator.ts:60-113`). Sessions are adopted on `session/created` and, at construction, for every session `sessions-list` returns; adopting runs L2 once. `session/event` captures the event (L3). `session/flush` calls the sink's `flush` when the session is adopted; the listener returns at once and never waits for the sink. `session/disposed` removes the adoption and delivers an ops record `{channel: "ops", time: now, severity: "info", attributes: {telemetry.op: "shutdown", session.id}, body: {op: "shutdown"}}`. `agent/error` delivers an ops record with severity `"error"`, attributes `telemetry.op: "agent-error"`, `session.id`, `agent.id`, `error.name`, `turn`, `step` in that order, and body `{name, message}`: for an exception the dsh class name that S7 assigns and its message, for any other value `Error` and its `display` form; `error.name` is that same name. The effect `telemetry capture`, in every mode: deliver a shutdown record for each session still adopted, then call the sink's `shutdown` and log a failure at `warning` as `telemetry: backend shutdown failed: <js-error-string>`.

L6. Containment: each capture step runs in a handler for `exn:fail` that logs at `warning` `telemetry: capture step failed: <js-error-string>` and continues; a record whose redaction or emit failed is withheld and the cursor does not advance past it.

L7. The OTel backend body (`session-telemetry-otel/src/index.ts:96-200`). Resolve the mode (`session-telemetry-otel: unsupported mode <JSON>`); `sharing` is `'feedback-only` or `'disabled`. `DISABLED`: no reporter; a `session/event` listener logs at `warning` `OpenTelemetry session upload is DISABLED; this feedback is not uploaded through OpenTelemetry` for each feedback event (L8); provide the backend. Otherwise check, with these messages: `session-telemetry-otel: exporter.url is required (the full OTLP logs endpoint)`; `session-telemetry-otel: exporter.url is not a valid URL: <JSON>`; `session-telemetry-otel: exporter.url must be http(s), got <scheme>:`; `session-telemetry-otel: processor.maxExportBatchSize must be a positive integer, got <v>`; `session-telemetry-otel: shutdownTimeoutMillis must be a positive finite number no greater than 2147483647, got <v>`. Create the reporter through the port with the options `{scope: {name: "@deepseek-ai/dsh-session-telemetry-otel", version}, exporter: {…exporter, url}, processor?, maxRequestBytes?, resourceAttributes: {service.name, service.version, user.id}}`, where name and version come from `app-identity` of `dsh-llm` and `user.id` is `(port-anonymous-user-id)`. The sink's `emit` drops a record without `sourceEvent` with the `warning` `Session log record withheld: redaction removed sourceEvent` and otherwise reports `{sessionId, event: {…envelope, data: body}, severityNumber, attributes}` with severity numbers 9, 13 and 17 for `info`, `warn` and `error`. The coordinator is on-demand with history. The backend's own `telemetry-backend-emit!` does nothing. `telemetry-backend-shutdown!` waits for the reporter's shutdown or for `shutdownTimeoutMillis`, whichever comes first; on timeout it calls `reporter-stop-pending!` and raises `session-telemetry-otel: provider shutdown exceeded <n>ms`.

L8. Feedback release. An event is *feedback* when its seq is at or after the session's inherited event count and its type is `feedback/record`, or `feedback/message-put` or `feedback/message-delete` with `data.sessionId` equal to the session id. On `session/event` with a feedback event: when the event is not the log's own entry at that seq (`eq?` with `session-event-at`), log `session telemetry ignored an event absent from the canonical session log` at `warning`; otherwise `(telemetry-capture-session! coordinator session seq)`. On `feedback/committed`: build a restored session from the inspection (`restore-session` with state `'detached` and the store's live message projections) and, when its last supplied event is feedback, capture through that event's seq.

### Q. Checkpoint policy (`session-checkpoint-policy/src/index.ts`; R7 Algorithms 26)

Q1. `llm/stream`: a request without a session id, or whose id has no live session, returns `(next)`. Otherwise the listener returns a chunk stream whose first pull calls `(sessions-flush sessions session)` and only then `(next)`; later pulls delegate; closing it closes the inner stream if it was created. A flush failure is raised from the first pull and the model request is never dispatched.

Q2. `tools/execute`: an execution without an agent, or with a parent, returns `(next)`. Otherwise flush the agent's session; when the execution's cancel event is then ready, return `(make-tool-failure "tool call aborted before dispatch" (list (text-block "Error: tool call aborted before dispatch")) #:info (tool-error-info "AbortError" tool-aborted-before-dispatch #f))`; else `(next)`.

Q3. `agent/pre-step`: flush the payload agent's session, then return `(next)`.

### D. DeepSeek log upload (`session-log-deepseek/src/index.ts`; R7 Algorithms 25)

D1. `accepted-through` (`index.ts:122-160`) folds incrementally, per service and session (a weak table remembers the scanned length and the result): for each new `session-log-deepseek/delivery-accepted` event: the format version is `sessionFormatVersion`, or 0 when absent, and must be a non-negative safe integer (`session-log-deepseek: malformed acceptance format version at seq <n>`); an event for another format version than the header's is skipped; `throughSeq` must be a valid seq below the event's seq and `sessionId` a non-empty string (`session-log-deepseek: malformed acceptance watermark at seq <n>`); an event naming another session is skipped; the result is the highest accepted `throughSeq`, or `-1`.

D2. The field provider for `dsh_session_log` (`index.ts:169-262`), given an `extension-request`: return `#f` when `enabled` is false now, when the request has no session id, when no live session has that id, or when an exclusion returns true for `{sessionId, purpose?}`. Otherwise `after` is D1; the pending events are those after it; the envelope is `{version: 1, sessionFormatVersion: <header version>, session: <wire header>, afterSeq: after}`. Size accounting, in UTF-8 bytes of `jvalue->string`: `bytes` starts as the size of `{…envelope, throughSeq: 0, events: []}` minus 1; for each pending event in order, `next = bytes + (1 if an event was already taken, else 0) + size(wire event)` and `candidate = next + <number of decimal digits of the event's seq>`; when `candidate > maxBytes` stop; else take the event and set `bytes = next`. When no event was taken: if there is a first pending event and its seq was not yet reported for this session, log once at `warning` `session-log-deepseek: event <seq> of session "<id>" needs a <candidate>-byte dsh_session_log field, above maxBytes <max>; this session's upload stays at event <seq> until maxBytes admits it`; return `#f`. Otherwise return `(extension-value {…envelope, throughSeq: <last taken seq>, events} accept)`.

D3. `accept`, called by the adapter after a 2xx response, appends `session-log-deepseek/delivery-accepted {sessionId, sessionFormatVersion: <header version>, throughSeq}` to the session.

D4. Wire forms (`index.ts:62-112`). The wire header is Data's `session`. A wire event: the common part `seq, time, data, ignorable?`; then for `developer/message`, `system/message`, `user/message` and `tool/result`: `type`, `surfaceOp` (`"append"` or `{op: "replace", startSeq, endSeq}`), `sourceEventSeqs?`; for `assistant/message`: `type`, `surfaceOp`; for an unknown ignorable type: `type` and the stored `surfaceOp` and `sourceEventSeqs` values unchanged when present; for every other type: `type`.

### W. Working directory (`working-directory/src/index.ts`; R7 Algorithms 27)

W1. Plugin body, in order: the default directory (Plugins); register `working-directory-projection` and keep its handle; register the prompt context `(make-prompt-context #:name "working-directory:current" #:order (system-prompt-context-order system-prompt 'WORKING_DIRECTORY) #:required? #t #:interpolate? #f #:text …)` whose text is `""` without an agent in the assemble context and W7's text otherwise; register the `system-prompt/assemble` listener with `#:prepend? #t` (W8); register an effect whose inverse cancels the lifetime source with a `WORKING_DIRECTORY_UNAVAILABLE` error `working-directory service disposed` and waits until every running operation has settled; provide the service.

W2. `working-directory-of` is the projection state for the session, or the default directory when that is `null`. No I/O.

W3. Serialization (`index.ts:238-254`). Operations on one session run one after another in submission order, each after the previous one settled, whatever its outcome. Before an operation starts, its composed cancel event is checked and the agent's context fiber must be active. The body runs as the innermost step of `working-directory/access` with the request `{agent, path, cancel}`.

W4. `working-directory-ensure` (path `#f`): `current` is W2; resolve it with `directory-resolve` and stat it; check the cancel event and the agent's fiber; when it is a directory: if the projection state is `null`, append `working-directory/change {cwd: current}`; return `current`. Otherwise the original directory is the header `cwd`, or the default; resolve and stat it with W6, where a missing directory raises `WORKING_DIRECTORY_UNAVAILABLE` `working-directory: directory does not exist: <JSON original>; the current working directory <JSON current> is also unavailable`; commit it as recovered (W5) and return it.

W5. Commit (`index.ts:215-236`): check the cancel event and the agent's fiber; when the directory equals W2, do nothing; append `working-directory/change {cwd: directory}`; build a user message with source `{kind: "working-directory"}` and one text block: `The working directory <JSON previous> is unavailable. The working directory is now <JSON directory>.` when recovered, else `The working directory changed from <JSON previous> to <JSON directory>.`; queue it with `agent-inject!`; a failure of the injection is logged at `warning` as `working-directory: committed <JSON directory>, but could not queue its notice: <js-error-string>` and does not fail the operation. `<JSON x>` is `(jvalue->string x)`.

W6. Directory resolution (`index.ts:200-213`): `(directory-resolve fs path #:cwd cwd #:cancel cancel)`, `(directory-stat fs target #:cancel cancel)`, check the cancel event, require `'directory` (else `WORKING_DIRECTORY_NOT_FOUND` `working-directory: directory does not exist: <JSON path>`, or the caller's error), and return `(directory-process-path fs target)`.

W7. `working-directory-set!`: the empty path raises `WORKING_DIRECTORY_INVALID` `working-directory: cd must not be empty`; resolve `path` against W2 with W6; commit (not recovered); return the directory. The context text is `Current working directory: <JSON directory>.`.

W8. The `system-prompt/assemble` listener: without an agent in the assemble context, return `(next)`. Otherwise `working-directory-ensure` with the context's cancel event; `(next)`; raise the lifetime reason if the service was disposed meanwhile; then set, in the returned presentation's contexts, the entry named `working-directory:current` to W7's text with `interpolate?` false, replacing an existing entry in place or adding a new one at the front.

### R. Session query (`session-query/src`; R7 Algorithms 28)

R1. Construction (`index.ts:86-115`). `read-window-max` must be a non-negative integer (`session-query: readWindowMax must be a non-negative integer`), `persisted-read-concurrency` and `prepared-session-cache-size` positive safe integers (`session-query: persistedReadConcurrency must be a positive safe integer`, `session-query: preparedSessionCacheSize must be a positive safe integer`); each failure has code `SESSION_QUERY_INVALID_CONFIG`. The engine binds `sessionPersistence` optionally: an injected child context stores the service value while it is mounted and clears it when it unmounts.

R2. The corpus (`corpus.ts`). Live sessions shadow persisted ones. `session-query-list-sessions`: list persistence when bound (a failure raises `SESSION_QUERY_PERSISTENCE_FAILED` `session persistence listing failed: <message>`), one record per snapshot with `live: #f`, `persisted: #t` and its format status; then for each live session a record with `live: #t`, `persisted` true when a persisted record existed, `formatStatus: "current"`, after `assert-session-headers-compatible` with the persisted header; sort by `createdAt` descending and then by id (rule R13).

R3. `assert-session-headers-compatible` (`sources.ts`): `id`, `createdAt`, `cwd`, `parentSession`, `isSeeded` and `delegationDepth` (absent meaning 0) must be equal, else `SESSION_QUERY_SOURCE_CONFLICT` `session source headers conflict for session "<id>"`.

R4. Loading one session (`corpus.ts:92-122`): a live session gives its header, inherited count and events. Otherwise, without persistence, or when the listing does not contain the id, raise `SESSION_QUERY_SESSION_NOT_FOUND` `session "<id>" not found`; read it cold (R5); when the session became live meanwhile, use the live one; else check R3 between the loaded and the listed header. A cold read failure raises `SESSION_QUERY_CORRUPT_SESSION` `stored session "<id>" is corrupt: <message>` for a corruption error and `SESSION_QUERY_PERSISTENCE_FAILED` `failed to read stored session "<id>": <message>` otherwise.

R5. `read-cold-session-log` (`cold-read.ts`): open a read handle, read everything, close it (on a read failure close and ignore a close failure), and return the header, the inherited count, the event state and the events followed by `(interrupted-turn-closers events)` of `dsh-session`. Nothing is written.

R6. Exact reads (`index.ts:150-330`). `session-query-read-session`: R4, then construct a session from the loaded log with `make-session` and `current-session-message-projections` to validate it, and return the snapshot. `session-query-read-surface`: R4 and the current surface events of R9, with `capturedThroughSeq` the last seq or `null`. `session-query-list-events`: R4 and the records of R9. `session-query-filter-events`: R4, the search documents of R10, the filters of R11. `session-query-read-event`: `before` and `after` default to 0 and must be integers from 0 to `read-window-max` (`SESSION_QUERY_INVALID_WINDOW` `<before|after> must be an integer between 0 and <max>`); R4; the target must exist at `seq` (`SESSION_QUERY_EVENT_NOT_FOUND` `session "<id>" has no event at seq <n>`); the window is `[max(0, seq - before), min(last, seq + after)]`.

R7. Titles (`index.ts:172-200`, `corpus.ts:124-205`). `session-query-read-title-snapshots` removes duplicate ids keeping first occurrences; live sessions are projected at once with `fold-session-title`; the others are resolved through one persistence listing and at most `persisted-read-concurrency` concurrent cold reads; each id yields `'fulfilled` with `{session, title?}` or `'rejected` with the failure, so one bad session does not fail the batch; results are in the order of the deduplicated ids. A listing failure rejects every unresolved id with that failure. Cancellation raises instead of rejecting. `session-query-read-title-snapshot` returns the value or raises the reason; `session-query-read-title` returns its title or `#f`.

R8. Observation (`observation.ts`). `session-query-observe-session`, in a loop: check the cancel event (`SESSION_QUERY_ABORTED` `session observation was aborted`); a live session gives a live observation: the cut is the log length now, `cursor` its last seq or `-1`, events materialised on first use as the prefix below the cut, projections `(projections-snapshot …)` unless the mode is `'none` or no registry is mounted, and a projection failure raises `SESSION_QUERY_CORRUPT_SESSION` `failed to project session "<id>": <message>`. Otherwise, without persistence raise not-found; `stat` the session (failures mapped: not-found; corruption to `SESSION_QUERY_CORRUPT_SESSION` `stored session "<id>" is corrupt: <message>`; others to `SESSION_QUERY_PERSISTENCE_FAILED` `failed to observe session "<id>": <message>`; a snapshot for another id raises `SESSION_QUERY_SOURCE_CONFLICT` `session persistence returned "<a>" for "<b>"`); re-check liveness; look up the prepared cache by session id, requiring the same persistence identity and revision; on a miss read the log cold (R5), re-check liveness, and call `(sessions-prepare sessions id #:seed events #:meta header #:inherited-event-count n #:event-state state)`; when that raises and the id is now live, restart the loop, else raise `SESSION_QUERY_CORRUPT_SESSION` `stored session "<id>" is corrupt: <message>`; store the entry. Projections for a prepared entry come from `projection-cache-hydrate-prepared!` when the cache is mounted, else `(projections-hydrate! … (jobj) events 0)`, else none. The prepared cache is an LRU of `prepared-session-cache-size` entries; an entry with a live lease, and the entry just stored, are never evicted; releasing the last lease of an entry re-runs eviction. `session-query-inspect-session` observes with mode `'none`, calls `read` on the live or prepared session, and releases.

R9. Surface classification (`tracing.ts:205-240`, `documents.ts`): fold the surface with `fold-surface` and `current-session-message-projections`; a failure raises `SESSION_QUERY_INVALID_SURFACE` `invalid session surface: <message>`; a seq is `"current"` when it is a node, `"shadowed"` when a replacement shadowed it, else `"log-only"`.

R10. `extract-session-event-text` (`extraction.ts`): `user/message`: the content text; `assistant/message`: the message content text; `tool/call`: name and arguments; `tool/result`: the content text, `error.name`, `error.code`; `todo/write`: for each todo its `status` and `content`; `turn/end`: `error` and the error message for kind `error`, `aborted`, `max-tokens`, `interrupted` for those kinds, nothing for the others; every other type: `""`. Content text takes the `text` of text blocks and the `name` and `arguments` of tool-call blocks and nothing from reasoning or unknown blocks. Parts are trimmed, empty parts dropped, and the rest joined with `"\n"`. A search document exists only for an event with non-empty text.

R11. Filters (`filters.ts`). Materialization validates and copies: `session filters must be an array`; `session <kind> filter values must be an array of strings` (or `… of strings or null` for `cwd` and `parent`); `session <kind> filter contains unknown value "<v>"` for `availability` and `surface`; ranges: `session <kind> filter from must be finite`, `… to must be finite`, `… from must be less than or equal to to`; `session text filter text must be a string`; `session unknown filter kind "<k>"` or `… (missing)`; all with code `SESSION_QUERY_INVALID_FILTER`. A record passes when every filter accepts it: `id`, `cwd` (a session without cwd matches `null`), `parent` likewise, `created-at` inclusive range, `availability` (any listed value holds); for events `seq`, `time`, `type`, `surface`, and `text`: `compile-session-text-filter` trims the text (`session text filter must contain non-whitespace text`), splits it at whitespace, escapes each part literally and joins the parts with `\s+`, matching case-insensitively.

R12. Tracing (`tracing.ts`). `session-query-trace-session`: build the id table from R2; an unknown target raises not-found; walk `parentSession` upward collecting ancestors, raising `SESSION_QUERY_INVALID_LINEAGE` `session lineage contains a cycle at "<id>"` on a repeat and stopping with `complete: #f` and `unresolvedParentId` at a parent that is not in the corpus; children of each session are sorted by `createdAt` ascending and then id (R13); descendants are the tree below the target in that order; a complete trace has `root`, the last ancestor or the target. `session-query-trace-event`: the target must exist; `replacedBy` is the replacement that shadowed it, `replacementChain` follows `replacedBy` repeatedly, `replacedEventSeqs` are the seqs this event shadowed, `sourceEventSeqs` its own sources, `derivedEventSeqs` the later events that list it as a source.

R13. Ordering by id uses `js-string<?` (UTF-16 code unit order). dsh uses `localeCompare`; the two agree for the ASCII ids dsh mints (Open questions).

R14. Search (`index.ts:128-136`): `session-query-search-sessions` and `session-query-search-events` build the request jobject (`{query, sessionFilters?, eventFilters?, limit?, cursor?}` and `{sessionId, query, filters?, limit?, cursor?}`) and call the engine's search provider.

### I. SQLite index (`session-query-sqlite/src`; R7 Algorithms 29)

I1. `open-search-database` (`schema.ts:28-66`): for a path other than `:memory:`, resolve it, create its directory with mode `0700` and the file exclusively with mode `0600` when it does not exist; connect with `sqlite3-connect`; read `application_id`, `user_version` and the user tables (`SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT GLOB 'sqlite_*' ORDER BY name`); an id that is neither 0 nor ours raises `session-search database at "<path>" belongs to another application`; id 0 with user tables raises `… is not an empty or recognized derived index`; our id with a table outside the eight derived names raises `… has unrecognized user tables: <names>`; our id with another `user_version` drops every user table and sets `user_version` to 0; then `PRAGMA journal_mode = <MODE>`, the persistent schema, `PRAGMA user_version = 8`, and the temp schema. A failure closes the connection.

I2. Opening and serialization (`index.ts:330-400`). With `openAt` `"never"` both searches raise `SESSION_QUERY_SEARCH_DISABLED` `session search is disabled: this deployment configures the session-query index with openAt "never"` before any other work, and the database is never opened. Otherwise the index opens once, at startup or on the first search; an open failure raises `SESSION_QUERY_INDEX_FAILED` `session-search SQLite index failed to open: <message>` for every search. All searches run one at a time in submission order; a search on a closed engine raises `SESSION_QUERY_INDEX_FAILED` `session-search SQLite index is closed`. Database calls run under `blocking` on a connection owned by the plugin's custodian.

I3. Request normalization (`query.ts:60-95`, `:255-330`). The query must be a string (`session-search query must be text`), is trimmed with whitespace runs collapsed to one space, must be non-empty (`session-search query must contain non-whitespace text`) and free of U+0000 (`session-search query must not contain NUL`), all `SESSION_QUERY_INVALID_QUERY`; the characters U+0000, U+FDD0 and U+FDD1 are replaced by U+FFFD in queries and indexed text. Metadata filters reject a `text` clause (`session-search metadata filters do not accept text clauses`). The limit defaults to `defaultLimit` and must be an integer from 1 to `min(maxLimit, 9007199254740990)` (`SESSION_QUERY_INVALID_LIMIT` `session-search limit must be an integer between 1 and <max>`). A cursor must be a string (`SESSION_QUERY_INVALID_CURSOR` `session-search cursor must be text`).

I4. Stable observation and reconciliation (`index.ts:385-560`), before every query. Up to two attempts: remember the live id set; when persistence is bound, list it, re-read (R5) every listed session whose revision differs from the indexed one and that is not live, list again, and require the two listings to agree on ids, revisions and headers and the binding to be unchanged; observe every live session; require the live id set to be unchanged. Failing twice raises `SESSION_QUERY_PERSISTENCE_FAILED` `session-search persistence observation did not stabilize after one retry`; other observation failures raise the same code with `session-search persistence observation failed: <message>`. Then, in one `BEGIN IMMEDIATE` transaction when anything changed: delete persisted rows of vanished ids; replace the rows and documents of re-read sessions with the next main generation and store it in `search_state`; delete live rows of sessions no longer live; replace live sessions whose fingerprint (base64url SHA-256 of the JSON text of `{header, inheritedEventCount, events}`) or persisted flag changed, each with a fresh local generation above the main one. A failure rolls back and raises `SESSION_QUERY_INDEX_FAILED` `session-search reconciliation failed: <message>`. The in-memory global generation increases when anything was written or the persistence binding changed; a binding change also increases the persistence epoch. A document row stores the sanitised text, the session id, seq, type, time, surface and the text's code point count.

I5. Queries (`index.ts:640-700`, `:790-850`). The user text becomes one FTS5 phrase: `"` + the text with each `"` doubled + `"`. The `candidates` and `matched` common table expressions are `selectedDocumentsSql` verbatim, with the bindings of `selectedDocumentsParams`: `highlight()` with the markers U+FDD0 and U+FDD1, `match_count` the number of start markers, persisted documents hidden when persistence is unbound or a live row exists for the session. Events of one session: `WHERE session_id = ?` and the event predicates, `ORDER BY match_count DESC, document_length ASC, time DESC, seq DESC`. Sessions: the best event per session by that order (`ROW_NUMBER() OVER (PARTITION BY session_id …) = 1`), then `ORDER BY match_count DESC, document_length ASC, time DESC, session_id ASC, seq DESC`. Paging is `LIMIT <limit + 1> OFFSET <offset>`; a page with more than `limit` rows has a `nextCursor` at `offset + limit`. Predicates are built by `buildSessionWhere` and `buildEventWhere` (`query.ts:97-170`, `:335-395`): an empty value list is the clause `0`; ranges use `CAST(<column> AS INTEGER)`; at most 14 predicates in total (`session-search request exceeds the supported SQLite FTS5 outer-predicate budget of 14; reduce filters`) and 32766 bound variables (`session-search request exceeds SQLite's portable 32766-variable limit; reduce filter values`), both `SESSION_QUERY_INVALID_FILTER`. `search-events` for an id in neither table raises not-found.

I6. Cursors (`index.ts:985-1020`, `query.ts:180-200`). A cursor is valid only for the same engine instance, scope and request fingerprint and a non-negative safe integer offset, else `SESSION_QUERY_INVALID_CURSOR` `session-search cursor is invalid`. The fingerprint is the JSON text of `{scope: "events", sessionId, query, filters, limit}` or `{scope: "sessions", query, sessionFilters, eventFilters, limit}` with filters in canonical form (value lists sorted with `null` first, ranges as `{kind, from, to}` with `null` for an absent bound, the filters sorted by their JSON text). The generation is the global generation as a string for session searches, and `live:<n>` or `persisted:<epoch>:<n>` for event searches; a different generation raises `SESSION_QUERY_STALE_CURSOR` `session-search cursor is stale because its relevant corpus changed`.

I7. `make-snippet` (`query.ts:201-250`): remove the markers, remembering the code point index of the first start marker; collapse whitespace runs to one space and drop a trailing space; when the text has at most `snippetChars` code points return it; when `snippetChars` is 1 return `…`; otherwise take a window that starts `floor(snippetChars / 3)` code points before the match, shifted so that it contains the match and fills up to the end of the text, with `…` at each clipped end counted inside the limit.

### E. Export (`session-log-export/src`; R7 Formats "Export formats and HTTP routes", Algorithms 24, 30)

E1. The command: `(command-register! commands ctx (jobj [definitionId "@deepseek-ai/dsh-session-log-export"] [name "export"] [description "Download this Session log as a ZIP archive"]) handler)`; the handler returns `{kind: "success", text: "Session log download requested."}` for input that trims to empty and `{kind: "error", text: "The Web /export command does not accept a path."}` otherwise.

E2. `GET` and `HEAD` `/api/session.export?sessionId=<id>&includeDescendants=true|false` (`index.ts:167-232`). A missing or empty `sessionId`, or an `includeDescendants` other than `true` or `false`, answers 400 `missing or invalid sessionId query parameter`. A missing `sessionQuery`, `sessionPersistence` or `attachments` service answers 500 `session log export is unavailable: missing session-query, session-persistence, or attachments service`. Before answering, flush the live root session (`flush-live-session-log`) and read its log text (`read-session-log-text`); any failure there answers 500 `session log export failed to read the stored log`, without the error text; an absent session answers 404 `session not found`. Success answers 200 with `content-type: application/zip`, `content-disposition: attachment; filename="<session-log-zip-filename id>"` and the ZIP stream as body. `HEAD` answers the same status and headers with no body and produces no entries.

E3. `GET` and `HEAD` `/api/session.markdown?sessionId=<id>` (`index.ts:119-152`): 400 as above; without `sessionQuery` 500 `session markdown export is unavailable: missing session-query service`; `session-query-read-session`, then the stored location from `session-persistence-stat` when persistence is mounted; 200 `content-type: text/markdown; charset=utf-8` with `(format-session-markdown events path)`; a failure whose code is `SESSION_QUERY_SESSION_NOT_FOUND` answers 404 `session not found`; any other failure 500 `session markdown export failed to read the stored log`. A request whose cancel event is ready raises its reason instead of answering.

E4. `serialize-session-log` (`archive.ts:110-135`): the header line with the keys and order of the v4 physical header (`delegationDepth` 0 when absent), then `(jvalue->string (session-event->jvalue event))` per event, with `sourceEventSeqs` expanded, each line followed by `"\n"`. `session-log-zip-filename` is `dsh-session-` + the id with every character outside `[A-Za-z0-9_-]` replaced by `_` + `.zip`.

E5. `session-log-zip-entries` (`archive.ts:225-290`), in this order: `session.v4.jsonl` with the root text; when descendants are included, for each node of the lineage trace's descendants in depth-first order, skipping ids already seen: flush it if live, read its text (absent raises `exn:fail` `subagent "<id>" has no stored log`), and yield `subagents/<safe id>/session.v4.jsonl`; then one `media/<attachmentId>.<png|jpg|webp|gif>` per distinct image attachment id, the extension chosen by the reference's `mediaType` (`image/png`, `image/jpeg`, `image/webp`, `image/gif`), with the bytes of `attachment-read-image`; then one `files/<digest[0:2]>/<digest>/<safe name>` per distinct pair of attachment id and name with the port of `attachment-read-file`, opened only when the entry is pulled, where the digest is the attachment id without a leading `sha256:` and the safe name replaces `\`, `/`, the control characters U+0000 to U+001F and U+007F by `_` and is `file` when it would be empty, `.` or `..`. Attachment references are collected from each artifact's lines as `collectEventAttachmentRefs` does (`archive.ts:165-215`): image and file blocks in `user/message` and `tool/ptc-dispatch` content, in the message content of `system/message`, `developer/message`, `tool/result`, `team/message/queued` and `assistant/message`, in `agent/inbox/spliced` inserted messages, in `compaction/summary` `summary` and `rawOutput`, and in `block-end` chunk records of assistant streams. Entries are produced lazily: a descendant is flushed and read only when its entry is pulled. No manifest entry.

E6. `write-session-log-zip` writes a standard ZIP stream with one entry per pulled `zip-entry`: a local header with the UTF-8 name flag and the data-descriptor flag, the data (method 8, DEFLATE, for a level from 1 to 9; method 0, stored, for level 0), a data descriptor with CRC-32 and sizes, and at the end the central directory and its end record. Text is encoded as UTF-8. Data is produced in pieces of at most 65536 bytes, the cancel event is checked between pieces, and each piece is written to `out` before the next is produced, so a slow consumer bounds memory. An entry or archive that would need ZIP64 raises `exn:fail`. A failure while pulling an entry propagates and leaves the stream truncated, as in dsh.

E7. `format-session-markdown` (`markdown.ts:65-367`; R7 Algorithms 24). Heading `# <title>`, the latest `session/title` with line breaks replaced by spaces and trimmed, or `# Untitled Session`. With a non-empty source path, the section `Session file:` and a fenced `text` block. Turns are delimited by `turn/start` and `turn/end`; events outside a turn open one. Segments: an appended `user/message` with source kind `user` and visible content (text blocks; `[Image: <name> (<W>×<H>, <N> bytes)]`; `[File: <name> (<N> bytes)]`; joined by blank lines; an empty or missing name is `attachment`, `]` is escaped), an appended `assistant/message` with visible text, a `tool/call`, and an appended `tool/result` attached to its call by `toolCallId` (a result without a call makes an entry named `unknown`). The final reply is the last segment when it is an assistant entry without tool calls. Before it, user segments render as blockquotes (`> ` per line, `>` for an empty line), and each run of assistant and tool entries renders as `<details><summary>N previous message(s)</summary>` containing `**Assistant**` blocks and tool blocks ``**Tool: `<name>`**`` with the arguments as pretty-printed JSON in a `json` fence, or the raw text when they do not parse, or `(no arguments)`, then `**Result**` or `**Result (error)**` with `(no result recorded)`, `Error: <reason>` followed by the fenced text when any, `(no output)`, or the fenced text. A fence is one backtick longer than the longest backtick run in its content and at least three. An assistant text that ends inside a code fence gets the closing fence; `<details>` and `<summary>` tags outside code are escaped. Sections are joined by blank lines and the output ends with exactly one newline. The exact strings and the fence and escaping scanner are those of `markdown.ts`.

## Racket design notes

- **A migration edge is a pure state machine.** dsh's stages are objects with mutable closure state that push into a context (`emitEvent`, `emitRun`). Here a stage is `(state, step, finish)` where `step` maps a state and one item to the next state and the emitted items. A chain is the composition of stages, a restore is a fold over rows, and the recoverable rule F13 is a field of the state. Nothing is mutated, so a failed row leaves the caller holding the previous restore value, and every edge can be tested by feeding it a list.
- **Format events are jobjects; `session-event` values exist only at the seam.** Historical envelopes have other keys (`seq0`, `start` and `end`, flat tool results), so the format layer works on jobjects and the JSONL backend converts with `jvalue->session-event` once a log is current. Events keep their JSON form, which is what makes rule X10 hold without a per-generation writer.
- **The agent's persistence port is inherited, not adapted.** `session-persistence-base` and `session-handle-base` implement the two generic interfaces of `dsh-agent/ports` by calling this package's generics on the same value. A backend is a substruct, so one value serves both vocabularies and no wrapper object stands between the loop and the handle.
- **A lane replaces the promise chain.** Each handle owns a FIFO lane (`private/lane.rkt`): `(lane-run lane thunk)` runs the thunk as a task after every earlier submission has settled and gives the submitter the thunk's result or exception. File work inside the thunk runs under `blocking`. The working directory service and the SQLite engine use the same lane.
- **Backend resources belong to the backend.** ADR 0004 gives a resource to the use site. A lock file is the stated exception (`#:custodian 'inherit` in spirit): the tracker's custodian owns every descriptor and task of the backend, because the handle outlives the agent scope that caused it to open (Services, the JSONL backend).
- **Verification runs on a thread, not in a worker.** The property dsh needs is that publication happens only after an independent strict re-read of the staged bytes with digest equality. The verifier is a pure function of the file's bytes, so it runs under `blocking`; a place would add a second copy of every module for no additional isolation of the data it checks. The limit of two concurrent verifications is per backend instance, because module-level counters are not allowed.
- **FFI in place of packages.** `libzstd` and four C library calls are bound directly (about 150 lines). The `zstd` catalog package offers only one-shot `compress` and `decompress`, without the checksum parameter and without the streaming decoder that the torn-frame recovery needs. `port-try-file-lock?` is not used because its lock family is an implementation detail of the Racket build, while rule X7 needs `flock` exactly.
- **`define-frozen-inventory`** (`dsh-session-store/format/validators`) declares, per event type of one frozen generation, its required, optional and opaque payload members and its semantic check in one clause:

  ```racket
  (define-frozen-inventory id
    #:label label-expr
    [type-string #:required (key ...) (~optional (~seq #:optional (key ...)))
                 (~optional (~seq #:opaque (key ...))) (~optional (~seq #:check check-expr))] ...)
  ```

  It defines `id-types` (the type strings in clause order), `(id-disposition type)` and `(id-assert-payload event version)`, which checks the member sets and then calls the clause's check with the payload, the event, a label and the version. In dsh the member table (`dispositions.ts`) and the semantic switch (`payload-validation.ts`) are parallel structures of 131 and 1072 lines; the classes of error the form removes are a type present in one and missing in the other, a duplicate type (a syntax error here), and a type whose member-set check was forgotten (it is generated for every clause). The module also provides the validator combinators the checks are written with (`v:string`, `v:nonempty-string`, `v:count`, `v:positive-integer`, `v:literal`, `v:array-of`, `v:exact-record`, …), each raising format with the label it is given.
- **Change gates use `same-value?`.** dsh gates the change feed on `Object.is`. Racket strings are not interned, so `eq?` would report a change for an equal title string; `same-value?` compares scalars by value and structures by identity.
- **Observation leases are explicit.** dsh's `Disposable` becomes `session-observation-release!` and `call-with-session-observation`, which releases in a `dynamic-wind` post thunk.
- **One module-level table.** The telemetry handoff cursor (rule L1) is a module-level weak table, as in dsh, so that a reloaded backend does not hand events over twice. Every other per-session table of this package (the acceptance fold, the blocked-seq warnings, title work, dirty counts) hangs off its service value.
- **The search provider is a generic interface.** dsh's abstract class with two abstract methods becomes `gen:session-search`; the engine value holds the provider, and `make-session-query-engine` is usable with any provider, which is how the query tests run without SQLite.
- **The ZIP writer is this package's own** (about 150 lines over `deflate` of `file/gzip`), because `file/zip` writes from files and cannot stream an entry whose size is unknown in advance. `file/gzip` has one compression level, so `compressionLevel` selects only between stored (0) and DEFLATE (1 to 9); archives stay readable by every ZIP reader.
- **Racket-only additions**, for the coordinator's ADR list: the config key `x-racket.zstdFallbackRoot` (rule Z6); the plugin `racket:session-fixture-decoder`, provider of the service key `racket:sessionFixtureDecoder` that wave 3 reserved; `checked-projection-definition` and `make-projection-definition`; `call-with-session-observation`; `make-memory-persistence` and the two seam suites as procedures (`dsh-session-store/persistence/testing`); the delay thunks of the tracker and the projection cache (test seams, not config); `projections-summary-keys` returning a list. None changes what an unmodified dsh configuration writes.

## Work units

The package is far above one implementer's size: about 28,000 lines of TypeScript source map to an estimated 18,000 to 22,000 lines of Racket with tests. It is split into three units, the maximum this contract may name. Each unit is still large; the delivery order inside a unit is given so that an implementer can stage it, and the last column names the line along which the coordinator can hand part of a unit to a further implementer without a new interface.

| Unit | Modules | Depends on | Further split line |
|---|---|---|---|
| A: formats | `format`, `format/validators`, `format/v0-v1`, `format/v1-v2`, `format/v2-v3`, `format/v3-v4`, `format/catalog`, `fixture-decoder`, the plugin `session-fixture-decoder`, their tests and the fixture corpus tests | `cordis-data`, `dsh-session`, `dsh-llm` (`accumulator-push`, `expand-assistant-stream`, the assembly) | the frozen validators of generations 0 and 1 (`private/v0-payloads.rkt`, `private/v0-relationships.rkt`) |
| B: persistence | `persistence`, `persistence/testing`, `jsonl`, `jsonl/zstd`, `jsonl/durable-io`, the plugins `session-persistence-jsonl` and `session-checkpoint-policy`, the interoperability tests | unit A, `cordis`, `dsh-agent/ports` | `jsonl/zstd` and `jsonl/durable-io`, which need nothing else |
| C: derived plane | `ports`, `projection`, `projection-cache`, `title`, `title-llm`, `stats`, `turn-outline`, `telemetry`, `log-deepseek`, `working-directory`, `query`, `query-sqlite`, `export`, the other thirteen plugins, `plugins`, `main` | the `persistence` module of unit B, `format/catalog` of unit A (only `current-session-message-projections`), wave 3 | `query`, `query-sqlite` and `export` |

Interfaces between the units, all listed with signatures under Services:

- A to B: `session-format-catalog`, `make-session-format-catalog/children`, `historical-session-format-catalog`, `format-catalog-read-header`, `format-catalog-encode-header`, `format-catalog-encode-event`, `make-format-restore`, `format-restore-row`, `format-restore-finish`, `restore-format-artifact`, `assert-v4-row-admission`, `assert-released-v4-relationships`, `historical-child-catalog-source`, `current-session-message-projections`, `session-format-log-filename`, `parse-session-format-log-filename`, `encode-source-event-ranges`, the two format error structs.
- B to C: everything `dsh-session-store/persistence` exports (the two generic interfaces, `persistence-snapshot`, `session-location`, the error structs, the service definition) and `make-memory-persistence` of `persistence/testing`. Unit C never requires `dsh-session-store/jsonl`.
- A to C: `current-session-message-projections` and `session-format-log-filename` only.

Build order. First, by unit A's implementer: `format` (library core, about 600 lines) and, by unit B's implementer, `persistence` with `persistence/testing` (about 700 lines); units B and C start against these. Unit A then delivers `v3-v4` with the v4 codec, admission and relationships (unit B needs the current path first), then `catalog`, then the edges in order `v2-v3`, `v1-v2`, `v0-v1`. Unit B delivers `jsonl/zstd` and `jsonl/durable-io`, the current-generation read and write path, the tracker, then historical preparation and publication once unit A's edges exist. Unit C delivers `ports` and `projection` first (the registry must replace `racket:session-projections` before any other derived module is tested through the loop), then the projection units and `title`, then `working-directory`, `log-deepseek`, `telemetry`, `projection-cache`, then `query`, `query-sqlite`, `export`.

## Tests

Tests live in `racket/dsh-session-store/tests/`. `raco test racket/dsh-session-store` passes with no network, no API key and no Node. Every wait has a timeout; timers are replaced through the delay thunks; each file works in a temporary directory it creates and removes.

| Racket test file | Mirrors (under `packages/`) | Pins |
|---|---|---|
| `format-test.rkt` | `session/session-format/tests/{catalog,chain,filename,json}.spec.ts` | F1 to F13 |
| `v0-v1-test.rkt` | `session/session-format-v0-to-v1/tests/{codec,legacy,migration,relationships,validation}.spec.ts` | C1, C2, C4, M0; the fixture `session-persistence-jsonl/tests/fixtures/released-v0-real-shapes.jsonl` |
| `v1-v2-test.rkt` | `session/session-format-v1-to-v2/tests/*` | C3, C4, M1 |
| `v2-v3-test.rkt` | `session/session-format-v2-to-v3/tests/*` (notably `combined-migration`, `canonical-envelopes`, `content-admission`) | C5, M2; the synthetic system id hash |
| `v3-v4-test.rkt` | `session/session-format-v3-to-v4/tests/*` (20 files) | C6, M3, V1 to V4 |
| `catalog-test.rkt` | `session/session-format-catalog/tests/*`, `session-persistence-jsonl/tests/catalog-migration.spec.ts` | V5; the child-bound catalog |
| `format-corpus-test.rkt` | (the parsing step of `test-support/llm-replay`) | `(parse-session-fixture text #:decode decode-session-fixture)` of `dsh-llm/replay` succeeds for every `snapshots/session/*/session*.jsonl` of every generation (generations 0 to 3 through the edges, strict recovery, validation `'current`), and for a generation 4 file returns the same events as the default decoder |
| `storage-contract-test.rkt` | `session/session-persistence/tests/storage-contract.spec.ts` | S1 to S7 |
| `persistence-contract-test.rkt` | `session/session-persistence/tests/contract.ts` (21 cases), `live-write-contract.ts` (12 cases), run against the memory backend and the JSONL backend in both encodings | the seam table of Services; J8 to J18 |
| `jsonl-test.rkt` | `session/session-persistence-jsonl/tests/{jsonl,load-path,migration-refusal,fork-delivery}.spec.ts` | J1 to J9, J20 to J25, J29 to J31; every refusal text |
| `jsonl-admission-test.rkt` | `…/tests/{current-event-admission,content-admission,retired-content-admission,native-developer-admission,native-source-admission}.spec.ts` | V1 through the backend; refusals survive tail recovery |
| `jsonl-generation-test.rkt` | `…/tests/{generation,multi-edge-publication,v2-system-migration,v2-ptc-migration,v3-restart-migration,migration-verifier}.spec.ts` | J25 to J28: staging, digest check, exclusive publish, race-winner acceptance, source drift, sources untouched |
| `zstd-test.rkt` | `…/tests/{zstd,zstd.compat}.spec.ts` | Z1 to Z5; header variants, RLE blocks, multiple blocks, torn frames at every byte of a small frame |
| `lease-test.rkt` | `…/tests/{lease.spec.ts,lease.two-process.e2e.ts}` | J19; a second handle in the process; a second process |
| `projection-test.rkt` | `session/session-projection/tests/{registry,registration-reader,summary,compatibility}.spec.ts` | P1 to P13; disposal of the registering fiber releases the reference; the agent loop's wave 3 tests pass with this registry in place of the memory one |
| `projection-cache-test.rkt` | `session/session-projection-cache/tests/{cache,fixtures}.spec.ts` with `fixtures/*.json` | K1 to K6; the record validators on the five committed documents |
| `title-test.rkt` | `session/session-title/tests/*.spec.ts`, `session-title-llm/tests/llm.spec.ts`, `session-title-first-prompt-llm/tests/provider.spec.ts` | T1 to T12 |
| `stats-outline-test.rkt` | `session/session-stats/tests/projection.spec.ts`, `session-turn-outline/tests/projection.spec.ts` | U1, U2 |
| `telemetry-test.rkt` | `session/session-telemetry/tests/{telemetry,redact}.spec.ts`, `session-telemetry-otel/tests/{otel,egress}.spec.ts` (with a recording reporter port) | L1 to L8 |
| `checkpoint-policy-test.rkt` | `session/session-checkpoint-policy/tests/session-checkpoint-policy.spec.ts` | Q1 to Q3 |
| `log-deepseek-test.rkt` | `session/session-log-deepseek/tests/upload.spec.ts` | D1 to D4; exact byte accounting at `maxBytes`, one below and one above |
| `working-directory-test.rkt` | `session/working-directory/tests/{working-directory,admission}.spec.ts`, the tool through `execute-model-tool-fixture` | W1 to W8, Tools |
| `query-test.rkt` | `session-query/session-query/tests/{session-query,observation,tracing,search-helpers}.spec.ts` | R1 to R14 |
| `query-sqlite-test.rkt` | `session-query/session-query-sqlite/tests/{sqlite,query}.spec.ts` | I1 to I7; the DDL as read back from `sqlite_master` |
| `export-test.rkt` | `session-query/session-log-export/tests/{archive,markdown,route,markdown-route,command}.host.spec.ts` | E1 to E7; the ZIP is read back with `file/unzip` |
| `plugins-test.rkt` | (none) | every row of `plugin-table` loads; each config schema accepts the shipped config and rejects one invalid value per field; a registration test per plugin disposes the fiber and observes removal |

Fixtures.

- *Fixture materialization.* Committed session fixtures are projected logs (R18 Formats 3): no `seq` and `time`, identity tokens, `{{cwd}}`, `{{tools}}`. `format-corpus-test.rkt` reads them with `parse-session-fixture` of `dsh-llm/replay` (dsh-llm rule I2). `interop-writer-bytes-test.rkt` uses its own helper, so that the position of `seq` and `time` is fixed by this package: a header `cwd` that starts with `{{cwd}}` has that prefix replaced by `/dsh-snapshot-cwd`; each event gets `seq` (its index) and `time` `0` inserted directly after `type`; a `request/header` whose `tools` is the string `{{tools}}` loses that key, and a `tools` list of names becomes `[{name, description: "", parameters: {}}]`; the expected line of such a row is the JSON text of the row after the same change.
- The physical dsh home `packages/experimental/webworker-runtime/tests/fixtures/vfs-example/home/sessions`: four sessions under `--dsh-workspace--`, uncompressed, with generation 2, 3 and 4 files side by side.
- `tests/fixtures/node-zstd/`: Zstandard files produced by Node's `zlib.zstdCompress` with the checksum flag, exactly as `compressZstdFrame` calls it (a header frame, two batch frames, one file with a torn last frame, one written by the streaming compressor without content size), committed together with the script `make-fixtures.mjs` that produced them. The script uses only `node:zlib` and `node:fs`.
- An in-memory storage-domain port, directory port (over a table of paths), reporter port, attachment port, command port and route port.

Recorded-session snapshots that exercise this package. Every scenario under `snapshots/session` stores logs that dsh harvested from a JSONL root, so all of them are inputs of `format-corpus-test.rkt` and of the writer test below. Those that pin behaviour owned here: `text-turn` (generation 1 input, `writer.expected.jsonl`), `packed-chunks`, `empty-response-retry`, `error-finish` and `subagent-multi` (generation 0 inputs: packed rows, retry failures, multi-hop migration with child catalog completion), `office-render-tools` and `office-render-tools-ptc` (retired tools in generation 4), `working-directory`, `working-directory-admission`, `working-directory-consumers`, `persistence-provider-unload`, `session-query-spill`, `subagent-archive-lineage`, `team-historical-records`; and every scenario's `session/title` row with source `fallback`. `snapshots/web/plugin-recommendations/tool-schemas.expected.json` pins the `working_directory` schema.

Interoperability. These tests are the demonstration of section X; dsh itself is not run, because the repository at the pinned commit has no built dsh.

| Test | What it shows | Rules |
|---|---|---|
| `interop-paths-test.rkt` | `encode-segment`, `project-key` and the generation names give dsh's values for the vectors of `jsonl.spec.ts:377-520`, astral characters included | X1 |
| `interop-writer-bytes-test.rkt` | For every `session*.v4.jsonl` and `writer*.expected.jsonl` under `snapshots/session`: materialize it; create the session through the JSONL backend (for a seeded header with the cut at the fixture's last inherited `session/end-seed`) and append its events in three batches; then, in a raw root, line 1 of the file equals the fixture's header line (with the cwd materialized) byte for byte, and every further line, with `seq` and `time` removed and `sourceEventSeqs` expanded, equals the fixture's line byte for byte; a fresh backend instance reopens the file and returns equal events, which runs V1, V2 and S3 over it. The same in a Zstandard root after `scan-zstd-frames`: one header frame plus one frame per batch, every descriptor with the checksum bit, every frame decoding on its own. | X2 to X6 |
| `interop-dsh-home-test.rkt` | The vfs-example home, copied to a temporary root with `compression: none`: `list` returns the four sessions with their format status; each opens for reading; the sessions with only historical generations are served migrated without any file being written; a write open publishes `session.v4.jsonl` beside them and leaves the older files byte-identical; the facts asserted by `vfs-example-fixture.spec.ts` hold (the 28-turn inherited prefix, the two `subagent/catalog` entries of the main session). | X9, X10 |
| `interop-zstd-node-test.rkt` | The committed Node-written files decode to their known text, the torn one yields its recovered tail, and the Racket backend appends to a Node-written file and reads the result. When `node` 22.15 or later is on `PATH`, a file written by the Racket backend is also passed to `tests/interop/read-zstd.mjs`, which holds a copy of dsh's frame scanner and decodes each frame with `zstdDecompressSync`, and must print the original text; without `node` that part is skipped with a visible message. | X5, X11 |
| `interop-lock-test.rkt` | While a Racket write handle is open, a child process (`python3 -c` with `fcntl.flock(fd, LOCK_EX | LOCK_NB)`, the system call dsh's addon makes) fails to lock `session.lock`; while such a child holds the lock, a Racket write open raises already-owned; the lock file survives close. Skipped with a visible message when `python3` is absent. | X7 |
| `interop-crash-test.rkt` | A file cut at every byte offset inside its last record or frame opens for reading with the committed prefix (and the recovered tail), and a write open truncates, rewrites and appends; the result passes the writer-bytes comparison. | X8 |
| `interop-loop-test.rkt` | The wave 3 gate fixtures (`text-turn`, `fs-read`, `tool-call-turn`) replayed through the agent loop with `@deepseek-ai/dsh-session-persistence-jsonl`, `@deepseek-ai/dsh-session-projection`, `@deepseek-ai/dsh-session-title` and `@deepseek-ai/dsh-session-checkpoint-policy` mounted: the log read back from disk by a fresh backend equals the in-memory log; every physical event line starts with `{"type":…,"seq":…,"time":…,"data":`; and after normalization its lines, `session/title` included, equal the fixture's at the positions the fixture has them. A second run resumes the stored session through `agents-resume` and appends one more turn. | X4, X6, T4, T5 |

Acceptance gate: `raco test racket/dsh-session-store` passes; every numbered rule has at least one test that names it; `format-corpus-test.rkt` and `interop-writer-bytes-test.rkt` pass for every committed fixture, with any scenario they cannot handle listed by name and reason in the test file rather than skipped silently; `interop-dsh-home-test.rkt`, `interop-zstd-node-test.rkt` (committed files) and `interop-crash-test.rkt` pass; the wave 3 packages' own suites still pass with `@deepseek-ai/dsh-session-projection` substituted for `racket:session-projections`.

## Open questions

1. **Ports in both directions.** This package consumes `storageDomain`, `fs`, `otel`, `attachments`, `commands` and `connection` through the wrappers of `dsh-session-store/ports`, whose fallback names were taken from the drafts of `dsh-platform.md` and `dsh-fs.md` and guessed for `commands` and `connection`. Sibling contracts consume `workingDirectory`, `sessionPersistence` and `sessionQuery` through their own ports and name this package's procedures as fallbacks (`dsh-exec`, `dsh-connect`, `dsh-context`, `dsh-subagent`; `dsh-platform` expects a `session-catalog-list`, which `session-persistence-list` answers). Recommended default: the wrapper convention as written; the wave 4 consistency review fixes any name that differs, in the one wrapper that carries it.
2. **Home of the image-offload projection.** `current-session-message-projections` needs the pure projection of `packages/compaction/compaction-image-offload/src/projection.ts`, which `dsh-context/image-offload` exports as `image-offload-projection`. A static require would make this package depend on a wave 4 sibling. Recommended default: a private copy in `private/image-offload-projection.rkt` (the 74 lines plus `project-message.ts`), with a test that compares it with the sibling's binding on the fixtures that contain `image/offload` when that module is installed; the coordinator may hoist the projection into a wave 3 package and delete the copy.
3. **Anonymous user id** for the OTel resource attribute `user.id`. Recommended default: `port-anonymous-user-id` resolves `get-or-create-anonymous-user-id` of `dsh-platform/anonymous-user-id` with `dynamic-require`; the OTel plugin injects `otel`, which the same package provides, so the module is present whenever the plugin runs.
4. **Position of the fallback title event.** dsh appends it from a deferred microtask, and the fixtures show it after `request/context` and before `assistant/message`. Rule T4 spawns a task, which runs at the driver's next release point. Recommended default: keep the spawn; `interop-loop-test.rkt` pins the position; if the Racket loop has a release point between the user message and the request header that dsh does not have, the fix belongs to the loop's contract, not to a delay here.
5. **`localeCompare`.** dsh orders session ids with `localeCompare` (R2, R12, I6). Recommended default: `js-string<?`, which agrees for ASCII ids; the difference for other ids is recorded in the parity table.
6. **Lone surrogates in ids and paths** (section X, known limit). Recommended default: refuse through J7, as described.
7. **Zstandard fallback.** Rule Z6 never mixes encodings in one root, so the fallback is an explicit second root. Recommended default: as written; the coordinator records `x-racket.zstdFallbackRoot` in an ADR.
8. **`feedback/committed` payload.** Rule L8 assumes an inspection with header, inherited count and events. Recommended default: accept a jobject with the keys `meta`, `inheritedEventCount`, `events`, or the struct the feedback contract defines; only the listener's first three lines depend on it.
9. **A deadline helper and `exn:fail:timeout-reason`** belong to `packages/util/timeout`. Recommended default: use `dsh-util`'s when it exports them; otherwise the private definitions of this contract.
10. **Constructor of `exn:fail:harness`.** `make-working-directory-error` and `make-session-query-error` need to build harness errors with a name and a code. Recommended default: whatever `dsh-util` exports for that purpose, as `dsh-tools/errors` does; both constructors are the only call sites.
11. **`db` and blocking.** Whether the installed `db-lib` accepts `#:use-place 'os-thread` for SQLite connections was not probed. Recommended default: open the connection plainly and run every call under `blocking`; searches are short and `openAt` is `never` in the shipped profiles.
12. **DEFLATE level.** `compressionLevel` 1 to 9 all use the single level of `file/gzip`. Recommended default: accept that; a binding to `libz` is a later optimisation with no observable effect besides archive size.
13. **Test-support hooks.** `call-with-loop-harness` has no keyword for the projections plugin and mounts `#:plugins` after the loop. Recommended default: the tests of this package call `mount-agent-loop-test-dependencies` with `#:projections` and mount the JSONL plugin before creating an agent, both of which the wave 3 contracts allow; no change to `dsh-test-support` is required.
14. **Catalog fact versions.** `facts.ts` accepts fact versions 0 to 2 and `validation.ts` adds version 3 with a name, while R7 summarises "versions 0..3". Recommended default: follow the two source files as rule V2 states.
