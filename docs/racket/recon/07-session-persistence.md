# Recon 07: the durable session plane

Pinned commit `e8f7b93a3`. Paths are relative to the repository root. Line numbers refer to files under `packages/session/<pkg>/src/` or `packages/session-query/<pkg>/src/` at that commit. "Core" means `packages/core/session` (`@deepseek-ai/dsh-session`), which another recon note owns; this note only states what the session plane needs from it.

Two corrections to the task brief, both verified in source:

- `SessionPersistence` has `create`, `open`, `flush`, `stat`, `list`. It has no `export` method. Export is a separate package (`session-log-export`) built on read handles.
- `packages/session` holds 22 packages and `packages/session-query` holds 3 (25 total).

Depth: storage (`session-persistence`, `session-persistence-jsonl`, `session-format*`), projections, titles, stats, outline, telemetry capture, checkpoint policy, DeepSeek log upload, working directory, `session-query`, `session-query-sqlite`, and the host half of `session-log-export` are covered in depth. Catalog depth only: `message-quotes` (browser UI), the SDK transport inside `session-telemetry-otel`, the browser half of `session-log-export`, `win32.ts` and `zstd-private-decoder.ts` in the JSONL backend, the per-field tables in `session-format-v0-to-v1/src/payload-validation.ts` (summarized with pointers), and the generated `docs/persistence-catalog.md` / `docs/persistence-schema.json`.

## Scope

| Package dir | npm name (`@deepseek-ai/dsh-…`) | Role | Src lines |
|---|---|---|---|
| `packages/session/session-persistence` | `session-persistence` | Abstract `ctx.sessionPersistence` service, handle interface, typed errors, backend-shared validation helpers | 636 |
| `packages/session/session-persistence-jsonl` | `session-persistence-jsonl` | The only shipped backend: per-session JSONL generations, optional Zstandard frames, flock lease, torn-tail repair, historical migration and exclusive publication | 5086 |
| `packages/session/session-format` | `session-format` | Pure library: JSON helpers, adjacent migration chain, codec/catalog compiler, canonical generation filename | 945 |
| `packages/session/session-format-catalog` | `session-format-catalog` | Build-static assembly of codecs v0..v4 and edges 0→1→2→3→4; child-bound catalog; historical v0..v3 catalog; installed-Session validation | 153 |
| `packages/session/session-format-v0-to-v1` | `session-format-v0-to-v1` | Frozen v0 and v1 physical codecs (packed chunk rows), legacy normalization, frozen payload and relationship validators | 2879 |
| `packages/session/session-format-v1-to-v2` | `session-format-v1-to-v2` | v2 codec (one event per row, `isSeeded`), embed assistant chunks into messages/attempts, dense seq remap | 1256 |
| `packages/session/session-format-v2-to-v3` | `session-format-v2-to-v3` | v3 codec, system-prompt promotion to `system/message`, PTC rename, `startSeq/endSeq` | 815 |
| `packages/session/session-format-v3-to-v4` | `session-format-v3-to-v4` | v4 codec (current), tool-role lift, producer-owned sources, catalog completion, native V4 admission and relationships | 1702 |
| `packages/session/session-projection` | `session-projection` | `ctx.sessionProjections`: projection unit registry, eager drive, snapshot, checkpoint, restore, hydrate | 1031 |
| `packages/session/session-projection-cache` | `session-projection-cache` | `ctx.sessionProjectionCache`: durable per-session checkpoint records on the `session_projcache` storage domain | 579 |
| `packages/session/session-title` | `session-title` | `ctx.sessionTitle`: `session/title` event, fallback title, single provider slot, `title` and `titleInput` projections | 1027 |
| `packages/session/session-title-llm` | `session-title-llm` | Library: bounded auxiliary LLM title request and `session/title-llm-request` event | 291 |
| `packages/session/session-title-first-prompt-llm` | `session-title-first-prompt-llm` | Title provider that titles from the first human message | 167 |
| `packages/session/session-stats` | `session-stats` | `sessionStats` projection unit (turn/step counts, wall times) | 299 |
| `packages/session/session-turn-outline` | `session-turn-outline` | `turnOutline` projection unit (turn, `turn/start` seq, previews) | 229 |
| `packages/session/session-telemetry` | `session-telemetry` | Abstract `ctx.sessionTelemetry` backend plus capture coordinator and `session-telemetry/record` waterfall | 479 |
| `packages/session/session-telemetry-otel` | `session-telemetry-otel` | OTel logs backend, modes `FEEDBACK_ONLY` / `DISABLED` | 278 |
| `packages/session/session-checkpoint-policy` | `session-checkpoint-policy` | Flush the session before each model request, top-level tool body, and step | 83 |
| `packages/session/session-log-deepseek` | `session-log-deepseek` | `ctx.sessionLogDeepSeek`: incremental `dsh_session_log` request field and acceptance watermark event | 396 |
| `packages/session/working-directory` | `working-directory` | `ctx.workingDirectory`: effective cwd per session, `working-directory/change`, model notices | 290 |
| `packages/session/tool-working-directory` | `tool-working-directory` | The `working_directory` tool | 43 |
| `packages/session/message-quotes` | `message-quotes` | Browser-only quote selection and blockquote rendering; host entry is a no-op | 208 |
| `packages/session-query/session-query` | `session-query` | Abstract `ctx.sessionQuery`: live-preferred corpus, exact reads, traces, filters, observations | 2241 |
| `packages/session-query/session-query-sqlite` | `session-query-sqlite` | Concrete `ctx.sessionQuery` with SQLite FTS5 search | 1781 |
| `packages/session-query/session-log-export` | `session-log-export` | `/export` command, ZIP and Markdown HTTP routes, pure Markdown formatter, browser controllers | 1923 |

Docs read: `docs/subsystems/{session,persistence,working-directory}.md`, `docs/session-format-status.md` (writer = finalized = released = 4, evidence tag `dsh-v0.2.0-rc.2`), `docs/persistence-catalog.md` and `docs/persistence-schema.json` (generated type inventory: `formatVersion: 2`, 66 roots, 636 types, SHA-256 digests per normalized type), `docs/persistence-changes/historical-formats/` (schema snapshots for v0..v3).

## Services

### `ctx.sessionPersistence` — `SessionPersistence` (abstract; `session-persistence/src/index.ts:144`)

`extends Service`, registered under key `sessionPersistence`. Field `identity: symbol` (process-local instance identity; consumers compare it instead of the context proxy).

| Method | Semantics |
|---|---|
| `create(header, options?) → Promise<SessionHandle>` | `options = { signal?, inheritedEventCount? }`. Stores a new session and returns a `write` handle. `inheritedEventCount` is required when `header.isSeeded`, must be omitted or `0` otherwise. Rejects `SessionAlreadyExistsError`. |
| `open(id, access, options?) → Promise<SessionHandle>` | `access: 'read' | 'write'`. `read` takes no ownership and works while a writer exists. `write` claims single-writer ownership. Rejects `SessionPersistenceNotFoundError`, `SessionAlreadyOwnedError`. |
| `flush() → Promise<void>` | Flushes every active write handle of this instance; a handle closed concurrently counts as flushed; failures aggregate into `AggregateError`. |
| `stat(id, options?) → Promise<SessionPersistenceSnapshot | undefined>` | Header-only observation, no ownership, no body read. `undefined` when absent. |
| `list(options?) → Promise<readonly SessionPersistenceSnapshot[]>` | Every session visible to this process, no promised order. |

`SessionPersistenceSnapshot`: `{ header: SessionHeader, formatStatus?: 'current' | 'migration-required', revision: SessionPersistenceRevision, eventCount?: number, sizeBytes?: number, location?: { kind: string, path: string } }`. `revision` is an opaque string token: equal revisions (same instance, same id) may be treated as an unchanged log; unequal promise nothing; ownership churn does not change it.

`SessionHeader` (core, `packages/core/session/src/types.ts:95`): `{ version: 4, id, createdAt (non-negative safe integer ms), cwd? (absolute), parentSession?, isSeeded: boolean, origin?: 'subagent', delegationDepth?: number, agentPreset?: string }`.

`SessionHandle` (`handle.ts:59`, `AsyncDisposable`): fields `id`, `header`, `inheritedEventCount`, `access`. Methods:

- `read(offset = 0, length = rest, { signal? }) → { eventState: 'detached' | 'shared-frozen', events }`. Returns a slice of the valid contiguous log; a torn tail is never returned; repeated reads on one handle never go backwards. `eventState` tells the consumer whether event objects are exclusively owned or shared deep-frozen values; slicing keeps the producer's state.
- `append(events, { signal? })`. First event `seq` must equal the stored next seq. On resolution the batch is ordered and visible to later reads on this backend instance. `SessionReadOnlyError` on read handles.
- `flush({ signal? })`. Durability barrier; materializes an empty created session. `SessionReadOnlyError` on read handles.
- `close()`. Idempotent, not cancellable. Write handle drains and releases ownership. Every later operation rejects `SessionHandleClosedError`.

Visibility rule: a created session is observable (`stat`/`list`/`open`) in the creating process as soon as `create` resolves; other processes see it only after materialization; a session never materialized before a crash never existed.

Errors (`errors.ts`), with exact messages:

- `SessionPersistenceNotFoundError(sessionId)`: `session "<id>" not found`
- `SessionAlreadyExistsError`: `session "<id>" already exists`
- `SessionAlreadyOwnedError`: `session "<id>" is already owned by an active write handle`
- `SessionReadOnlyError(id, op)`: `session "<id>": <op> is not available on a read handle`
- `SessionOwnershipLostError`: declared, never thrown by the shipped backend
- `SessionHandleClosedError(id, op)`: `session "<id>": <op> on a closed handle`
- `SessionPersistenceCorruptionError(message, { cause })`
- `SessionFormatUnsupportedError(message, location?)`
- `sessionFormatVersionRefusal(id, version)`: newer → `session "<id>" uses log format v<N>, but this harness reads only v4: the log was written by a newer harness — upgrade the harness to open it`; older → `session "<id>" uses log format v<N>, older than the supported v4, and this build ships no upgrade path for it`.

Backend-shared helpers (`storage-contract.ts`): `assertStoredId`, `assertVersion`, `validateStoredEvents` (unknown non-ignorable type → `SessionFormatUnsupportedError`; `request/header` with `data.reason === 'fallback'` → unsupported; then `adoptSessionEvent` per event, failure → `SessionPersistenceCorruptionError`), `materializeCreateHeader` (lossless-JSON snapshot, `createdAt` non-negative safe integer else `TypeError`), `materializeAppendBatch` (lossless-JSON snapshot else `TypeError`), `assertContiguous` (`append seq mismatch for "<id>": expected <n> at index <i>, got <seq>`).

### JSONL provider (same key)

`session-persistence-jsonl` is a function plugin whose `apply` creates a `JsonlBackendTracker`, installs its listeners, then mounts a child plugin that constructs the private `JsonlSessionPersistence` service (`index.ts:1824`). Teardown order: unloading the provider first unloads consumers that inject `sessionPersistence`, then removes listeners, then closes all open handles (each close drains).

### `ctx.sessionProjections` — `SessionProjectionRegistry` (`session-projection/src/index.ts:282`)

Service class, default export, no config, no injections. Subscribes once to `session/created` and `session/event`.

- `register(definition) → awaitable ProjectionHandle<S>`. `definition = { key, stateSchema, init(header, inheritedEventCount), apply(state, event), wire?: { viewSchema, view(state), summary?: boolean = true }, stateVersion: non-negative integer }`. Registration is an effect on the caller's fiber. Registrants sharing a key share one unit with a reference count; a second registrant with a different `stateVersion` or `summary` throws. The runtime return value is a callable thenable (legacy: calling it disposes). Handle: `stateOf(session)`, `readerFor(session) → () => S`, `dispose()`. A retained handle keeps folding with its original unit after release.
- `stateOf(session, key)` deprecated; warns once per key.
- `onChanged(listener(session, key, value, seq))`, `onEventChanged(listener(session, changes[{key,val}], seq))` — effect-scoped subscriptions; return a disposer.
- `snapshot(session, keys?) → { asOfSeq, values }` — synchronous, computes only client-visible selected units; `asOfSeq = session.seq - 1` (`-1` for empty).
- `cachedSnapshot(session, keys?)` deprecated.
- `summaryKeys() → ReadonlySet<string>` — stable set of wire keys without `summary: false`; identity changes only when the key table changes.
- `checkpoint(session) → Record<key, { ver, seq, val }>` — `val` is a structured clone; released units contribute their last cell.
- `restoreFloor(checkpoint) → SessionLogOffset | undefined`, `viewCheckpoint(checkpoint, keys?)`, `restore(checkpoint, events, baseSeq, header, inheritedEventCount) → { snapshot, checkpoint }`, `hydrate(session, checkpoint, events, baseSeq) → ProjectionSnapshot`.

### `ctx.sessionProjectionCache` — `SessionProjectionCache`

- `cachedSnapshot(meta, keys?) → ProjectionSnapshot | undefined` — zero-I/O listing read from the in-memory domain table; matches lifecycle identity only.
- `cachedPredecessorTitle(meta)` — title-only hint from a record written under an older Session format.
- `hydratePrepared(session, events) → ProjectionSnapshot` — seeds cells for a prepared (unpublished) session; retries from an empty checkpoint when cached rows fail.
- `write(session) → Promise<void>` — checkpoint now (not fail-soft).
- `coldSnapshot(meta, inheritedEventCount, events) → ProjectionSnapshot` — restore over a complete log, then fire-and-forget write-back.

### `ctx.sessionTitle` — `SessionTitleService`

- `get(session) → SessionTitleSnapshot | undefined` — folds the latest `session/title` from the log.
- `rename(session, title) → SessionTitleSnapshot` — user title; throws `SessionTitleInvalidError('session title must contain visible characters')` when it normalizes to empty; throws `session "<id>" is not live in this store` for a non-live session.
- `refresh(session, signal?) → Promise<SessionTitleSnapshot | undefined>` — rerun provider or re-derive fallback (also the "unpin" for a user title).
- `register(provider) → disposer` — one provider at a time: `{ id, automatic: 'first-prompt' | 'all-prompts', generate(request) → { title, messageSeqs, model? } }`. A second live registration throws `session-title provider "<id>" is already registered`.

### `ctx.sessionTelemetry` — `SessionTelemetryBackend` (abstract)

`sharing: 'full' | 'feedback-only' | 'disabled'`, `emit(record)`, optional `flush()`, `shutdown()`. A backend composes `new SessionTelemetryCoordinator(ctx, sink, { capture?: 'live' | 'on-demand', includeHistory?: boolean })`; the coordinator exposes `captureSession(session, throughSeq?)`.

### `ctx.sessionLogDeepSeek` — `SessionLogDeepSeekService`

`registerExclusion(exclude: (request: { sessionId, purpose? }) => boolean) → disposer`. Any exclusion returning `true` suppresses both the request field and its acceptance callback.

### `ctx.workingDirectory` — `WorkingDirectoryService`

`defaultDirectory: string`; `get(session) → string` (no I/O); `ensure(agent, signal?) → Promise<string>`; `set(agent, path, signal?) → Promise<string>`. Errors are `WorkingDirectoryError` (a `HarnessError`) with codes `WORKING_DIRECTORY_INVALID`, `WORKING_DIRECTORY_NOT_FOUND`, `WORKING_DIRECTORY_UNAVAILABLE`.

### `ctx.sessionQuery` — `SessionQueryEngine` (abstract) / `SqliteSessionQueryEngine`

Backend-independent, implemented in the base class: `observeSession(id, { signal?, projectionMode?: 'all' | 'none' }) → SessionObservation` (a `Disposable` lease), `inspectSession(id, read(session), signal?)`, `listSessions(signal?)`, `readSession(id)`, `filterSessions(filters, signal?)`, `readTitle`, `readTitleSnapshot`, `readTitleSnapshots(ids, signal?)`, `listEvents(id)`, `filterEvents(id, filters)`, `readSurface(id)`, `traceSession(id, signal?)`, `traceEvent({ sessionId, seq }, signal?)`, `readEvent({ sessionId, seq, before?, after? }, signal?)`. Abstract and provided by SQLite: `searchSessions(request, exec?)`, `searchEvents(request, exec?)`. SQLite adds `close()`.

Errors: `SessionQueryError` (`HarnessError`) with codes `SESSION_QUERY_ABORTED`, `_CORRUPT_SESSION`, `_EVENT_NOT_FOUND`, `_INDEX_FAILED`, `_INVALID_CONFIG`, `_INVALID_CURSOR`, `_INVALID_FILTER`, `_INVALID_LIMIT`, `_INVALID_QUERY`, `_INVALID_LINEAGE`, `_INVALID_SURFACE`, `_INVALID_WINDOW`, `_PERSISTENCE_FAILED`, `_SEARCH_DISABLED`, `_SESSION_NOT_FOUND`, `_STALE_CURSOR`, `_SOURCE_CONFLICT`.

### Libraries without a ctx key

`session-format` (`createSessionFormatCatalog`, `createSessionFormatChain`, `defineSessionFormatMigration`, `sessionFormatLogFilename`, `parseSessionFormatLogFilename`, JSON guards), `session-format-catalog` (`sessionFormatCatalog`, `createSessionFormatCatalogWithChildren`, `historicalSessionFormatCatalog`, `currentSessionMessageProjections`), the four edge packages, `session-title-llm` (`executeSessionTitleLlm`, `resolveSessionTitleLlmConfig`), and the pure exports of `session-log-export` (`formatSessionMarkdown`, `serializeSessionLog`, `readSessionLogText`, `sessionLogZipEntries`, `streamSessionLogZip`, `sessionLogZipFilename`, `flushLiveSessionLog`).

## Events

Cordis events defined in this area:

| Event | Mode | Payload | Producer | Consumers |
|---|---|---|---|---|
| `session-telemetry/record` | waterfall | `(record: SessionTelemetryRecord, next)`; innermost `next` returns the record unchanged | `SessionTelemetryCoordinator.redact` at capture time | Deployment redaction rules. A throwing listener withholds that record (fail-closed). |
| `working-directory/access` | waterfall | `({ agent, path: string | null, signal }, next: () => Promise<string>)`; `path: null` means validate current | `WorkingDirectoryService.ensure/set` | Listeners that must wait for a resource operation on the directory, then call `next()`. A rejection fails the access and leaves state unchanged. |

Core events this area consumes (all defined in core or other areas):

| Event | Mode | Consumers here | Ordering notes |
|---|---|---|---|
| `session/created(session)` | emit | projection registry (init cells when `session.seq === 0`), projection cache (mandatory write), live telemetry coordinator (adopt) | — |
| `session/event(session, event)` | emit (synchronous, stop-on-throw) | JSONL tracker (route into the write handle buffer), projection registry (drive), projection cache (dirty count; `turn/end` write), title service, telemetry, telemetry-otel | Listeners run in registration order; every handler here contains its own failures or is cheap. |
| `session/flush(session)` | parallel (awaited) | JSONL tracker (`drainLive` + `flush`), live telemetry (flush hint, returns void) | Produced by `ctx.sessions.flush(session)`. |
| `session/disposed(session)` | emit | JSONL tracker (close handle, warn on failure), projection cache (final write), title service (abort work), telemetry (shutdown marker) | — |
| `llm/stream(options, next)` | waterfall | checkpoint policy (flush before `next()`), title service (`{ global: true, prepend: true }`, starts pending title work, always calls `next()`) | — |
| `tools/execute(exec, next)` | waterfall | checkpoint policy | — |
| `agent/pre-step({ agent }, next)` | waterfall | checkpoint policy | — |
| `agent/error({ agent, turn, step, error })` | emit | live telemetry (ops record) | — |
| `system-prompt/assemble(assembly, context, next)` | waterfall | working-directory (`{ prepend: true }`) | — |
| `feedback/committed(inspection: SessionInspection)` | parallel | telemetry-otel | Produced by `message-feedback` after a feedback commit on a stored session. |

Session log event types declared in this area (payloads are durable):

- `session/title`: `{ title: string, messageSeqs: SessionSeq[], source: { kind: 'fallback' } | { kind: 'provider', provider, model?: { provider, model } } | { kind: 'user' } }`. Log-only. `messageSeqs` is empty exactly when `source.kind === 'user'`.
- `session/title-llm-request`: `{ titleProvider, messageSeqs, route: { provider, model }, system, messages: Message[], maxTokens, reasoningEffort? }`. Log-only, appended before dispatch.
- `session-log-deepseek/delivery-accepted`: `{ sessionId, sessionFormatVersion?: number (absent = 0), throughSeq }`. Log-only.
- `working-directory/change`: `{ cwd: string }` (absolute). Log-only.

Projection keys registered here: `title` (wire, `string | null`, `stateVersion 1`), `titleInput` (host-only, `stateVersion 3`), `sessionStats` (wire, `summary: false`, `stateVersion 1`), `turnOutline` (wire, `summary: false`, `stateVersion 2`), `workingDirectory` (wire, `string | null`, `stateVersion 1`).

Projection change feed (registry callbacks, not Cordis events): for one committed event, units are driven in registration order; each client-visible unit whose raw `view` result changed by reference calls every `onChanged` listener; after all units, `onEventChanged` listeners get one call with all changes. If a unit or listener throws, `onEventChanged` still receives the changes collected so far, then the error propagates.

## Tools

One model-facing tool.

**`working_directory`** (`tool-working-directory/src/index.ts:19`)

- Description (exact): `Read the current working directory, or change it with cd. Relative paths use the current directory. Existing shells and running processes keep their own directories.`
- Parameters (exact JSON schema as snapshotted in `snapshots/web/plugin-recommendations/tool-schemas.expected.json`):

```json
{ "type": "object",
  "properties": { "cd": { "type": "string", "description": "Existing directory to enter. Omit to read the current directory." } } }
```

No `required` list.

- Output schema: `{ type: 'object', additionalProperties: false, properties: { cwd: { type: 'string', required: true, description: 'Current absolute working directory.' } } }`. Model-visible rendering is one text block containing `cwd`.
- Execute: no agent → `ToolContextUnavailableError('working_directory requires an agent Session')`. `cd === ''` → `ToolArgsError(['cd must not be empty; omit it to read the current directory'])`. `cd` absent → `ctx.workingDirectory.ensure(agent, signal)`; else `ctx.workingDirectory.set(agent, cd, signal)`. Result `{ cwd }`.
- Errors surfaced from the service: `WORKING_DIRECTORY_NOT_FOUND` (`working-directory: directory does not exist: "<path>"`), `WORKING_DIRECTORY_UNAVAILABLE`, `WORKING_DIRECTORY_INVALID`.
- Approval/sandbox: the tool declares no approval hook. It does not change sandbox writable roots or project membership (those stay anchored to the header cwd); it only changes the directory later operations resolve against.

Not a model tool: the human slash command `/export` (definition id `@deepseek-ai/dsh-session-log-export`, name `export`, description `Download this Session log as a ZIP archive`). Empty input → `{ kind: 'success', text: 'Session log download requested.' }`; any argument → `{ kind: 'error', text: 'The Web /export command does not accept a path.' }`.

## Configuration

| Plugin (package) | Export form | `name` | inject | Config fields |
|---|---|---|---|---|
| `session-persistence-jsonl` | function plugin (`name`, `Config`, `apply`; no `inject`) | `session-persistence-jsonl` | none | `root: string` required, no default; `compression: 'zstd' | 'none'` default `'zstd'`; `listConcurrency: natural ≥ 1` default `3` |
| `session-projection` | Service class default export | (class `SessionProjectionRegistry`) | none | none |
| `session-projection-cache` | Service class default export | (class) | `storageDomain`, `sessionProjections`, `sessions` | `writeEveryEvents: natural ≥ 1` required; `writeIntervalMs: natural ≥ 1` required. Shipped: `200`, `5000` |
| `session-title` | Service class default export | (class) | `sessions`, `sessionProjections`, `agents` | `fallbackMaxWords`, `fallbackMaxBytes`, `maxTitleBytes`: positive integers, all required; `fallbackMaxBytes ≤ maxTitleBytes`. Shipped: `5`, `40`, `80` |
| `session-title-first-prompt-llm` | function plugin | `session-title-first-prompt-llm` | `sessionTitle`, `llm`, `sessions` | `targetWords`, `targetCjkCharacters`, `maxInputBytes`, `maxOutputTokens`, `timeoutMs` (≤ 2147483647): positive integers, all required; `provider?`, `model?` strings, must be supplied together. Shipped: `5`, `10`, `4096`, `4096`, `60000` |
| `session-stats` | function plugin | `session-stats` | `sessionProjections` | none |
| `session-turn-outline` | function plugin | `session-turn-outline` | `sessionProjections` | none |
| `session-telemetry-otel` | Service class default export (`OpenTelemetrySessionBackend`) | (class) | `sessions`, `otel` | `mode: 'FEEDBACK_ONLY' | 'DISABLED'` default `FEEDBACK_ONLY`; `exporter?: { url?, …transport }` (`url` required and http(s) unless disabled); `processor?` (`maxExportBatchSize` positive integer when present); `shutdownTimeoutMillis?` default `3000`, `0 < x ≤ 2147483647`; `maxRequestBytes?` integer 1..4000000. Shipped: `mode: !!js process.env.DSH_TELEMETRY_MODE || 'FEEDBACK_ONLY'`, `shutdownTimeoutMillis: 3000`, `maxRequestBytes: 4000000`, `exporter.url: !!js process.env.DSH_TELEMETRY_OTLP_URL ?? 'https://dsh-otel-collector.deepseeksvc.com/v1/logs'` |
| `session-checkpoint-policy` | function plugin | `session-checkpoint-policy` | `llm`, `sessionPersistence`, `sessions`, `tools` | none |
| `session-log-deepseek` | function plugin (mounts `SessionLogDeepSeekService` with `ctx.plugin`) | `session-log-deepseek` | `deepseekLlmApiExtensions`, `sessions` | `enabled: boolean` default `true`, volatile (read per request); `maxBytes: integer ≥ 1` default `8388608` |
| `working-directory` | Service class default export | (class) | `fs`, `sessionProjections`, `systemPrompt` | `defaultDirectory?: string` absolute; default `process.cwd()` at construction |
| `tool-working-directory` | function plugin | `tool-working-directory` | `tools`, `workingDirectory` | none |
| `message-quotes` | host `apply()` no-op; client plugin | `message-quotes` (client) | client: `slots`, `locale`, `sessions`, `uiConversation` | none |
| `session-query-sqlite` | Service class default export | (class) | `sessions`; optional `sessionPersistence` through `ctx.inject` | `path: string` required (`:memory:` allowed); `openAt: 'startup' | 'first-search' | 'never'` default `startup`; `journalMode: 'wal' | 'delete' | 'truncate' | 'persist'` default `wal`; `defaultLimit` default `20`; `maxLimit` default `100` (both 1..2^53−2, `defaultLimit ≤ maxLimit`); `snippetChars` default `240`; `readWindowMax` default `50` (≥ 0); `persistedReadConcurrency` default `4`; `preparedSessionCacheSize` default `5`. Shipped: `path: ':memory:'`, `openAt: never` |
| `session-log-export` | function plugin | `session-log-download` | `commands`, `connection`; reads `sessionQuery`, `sessionPersistence`, `attachments`, `sessions` with `ctx.get` | `compressionLevel: integer 0..9` default `6` |

Shipped rows live in `packages/bundle/base/cordis.patch.yml` (ids `session-title`, `session-title-llm`, `session-persistence-jsonl` with `root: !!js dshHomePath('sessions')`, `session-query-sqlite`, `working-directory`, `tool-working-directory`, `session-projection`, `session-projection-cache`, `session-telemetry-otel`, `session-checkpoint-policy`, `session-log-deepseek`) and `packages/bundle/web-app/cordis.patch.yml` (`session-log-download`, `session-stats`, `session-turn-outline`, restated `session-query-sqlite`).

## Formats

### Directory layout

```text
$DSH_HOME/                               # default ~/.dsh; env DSH_HOME overrides
  sessions/                              # JSONL backend root
    --<project-key>--/                   # one per normalized header cwd; "_no-cwd" when header has no cwd
      <encodeSegment(sessionId)>/        # session-owned directory, mode 0700
        session.jsonl[.zstd]             # generation v0 (historical)
        session.v1.jsonl[.zstd]          # v1
        session.v2.jsonl[.zstd]          # v2
        session.v3.jsonl[.zstd]          # v3
        session.v4.jsonl[.zstd]          # v4 = current append target
        session.lock                     # POSIX flock target; never removed
        session.v4.jsonl.zstd.<12 hex>.tmp        # first-materialization temp
        session.migration.<16 hex>.jsonl.zstd.tmp # migration stage temp
  storages/session_projcache/sessions/<id>.json   # projection cache (storage-json backend)
  .anonymous-user-id                     # telemetry user.id
```

(The JSONL README layout table still labels v3 as current; source says v4.)

- Canonical filename regex (`session-format/src/filename.ts:5`): `^session(?:\.v([1-9][0-9]*))?\.jsonl$`, plus suffix `.zstd` when `compression: 'zstd'`. Version 0 has no `.vN`. `.v0`, leading zeros, uppercase, and temp names are not generations.
- `encodeSegment(raw)` (`format.ts:199`): empty → error; `"."` → `~002E`; `".."` → `~002E~002E`; otherwise per UTF-16 code unit: keep `[A-Za-z0-9._-]`, replace everything else (including `~`) with `~` + 4 uppercase hex digits of the code unit. Astral characters therefore become two escapes (surrogate pair).
- `projectKey(cwd)` (`format.ts:225`): per code unit, a run of `/`, `\`, `:` becomes one `-`; safe units kept; others `~XXXX`. Strip leading `-`; empty → `root`; result `--<first 251 chars>--`. Lossy by design. `/home/u/proj` → `--home-u-proj--`.
- A root belongs to one encoding. Any generation with the other suffix anywhere under the root rejects with `session artifact "<path>" uses <suffix>, but this backend is configured for compression "<mode>"; use a separate root or select the matching compression mode`. A file ending `.jsonl` or `.jsonl.zstd` directly inside a project directory rejects as `… uses the unsupported flat-file layout; use a separate root or move it into a project/session directory before loading`.

### Current (v4) physical log

Line 1, header record, keys in this order, absent optionals omitted (never null):

```json
{"type":"session","version":4,"id":"<id>","createdAt":<ms>,"cwd":"<abs>","parentSession":"<id>","isSeeded":false,"origin":"subagent","delegationDepth":0,"agentPreset":"<id>"}
```

Required: `type`, `version`, `id`, `createdAt`, `isSeeded`, `delegationDepth`. Optional: `cwd`, `parentSession`, `origin`, `agentPreset`. Any other key is corruption. `sandboxMode` or `approvalPolicy` on a header → `session header uses retired policy baseline fields`. A header whose numeric `version` differs from 4 is refused with the version refusal text before any structural check. The header does not store the inherited cut.

Lines 2..N, one event per line, written by `JSON.stringify` of the event object. Live events are built as `{ type, seq, time, data, sourceEventSeqs?, surfaceOp? }` (plus `ignorable: true` where set). Envelope rules: required `type` (string), `seq` (dense from 0), `time` (safe integer), `data` (JSON); optional `ignorable` (exactly `true`), `surfaceOp`, `sourceEventSeqs`; no other keys.

- `surfaceOp`: `"append"` or `{ "op": "replace", "startSeq": n, "endSeq": m }`. Required on the five surface types `system/message`, `developer/message`, `user/message`, `assistant/message`, `tool/result`; forbidden on known log-only events.
- `sourceEventSeqs` storage form (`session-format-v1-to-v2/src/codec.ts:217`): if the list is not strictly increasing, stored verbatim. Otherwise each maximal run of consecutive integers of length ≥ 3 is stored as `[start, end]`; a run of length 2 as two numbers; singletons as numbers. Decoding (`:186`): numbers and 2-element arrays; `start ≤ end < eventSeq`; all members unique and `< eventSeq`; total expansion bounded by `eventSeq`; when any range is present the whole expanded list must be strictly increasing.
- Inherited cut: the seq of the last `session/end-seed` event whose `data.inherited === true`. A seeded header without such a marker, or an unseeded header with one, is an error.

Framing:

- `compression: 'none'`: UTF-8 text, each record terminated by `\n`. A final fragment without `\n` is a torn tail.
- `compression: 'zstd'`: concatenation of independent Zstandard frames, each with the content checksum flag (`ZSTD_c_checksumFlag = 1`), default level. Frame 1 holds exactly the header line. Each durable append batch is one more frame holding `event lines joined by \n` plus a trailing `\n`. A migrated generation is header frame plus one streamed frame for all events. Every complete frame must end on a record boundary.

### Historical generations (what each version looked like)

| Version | Physical header | Body rows | Distinguishing logical features |
|---|---|---|---|
| 0 | required `type,version,id,createdAt,delegationDepth`; optional `cwd,parentSession,seedLength,origin,agentPreset`. `isSeeded = seedLength present`; cut = `seedLength ?? 0` | event rows, or packed rows `{ type: 'text-chunks' | 'reasoning-chunks', seq0, time0, data: { turn, step, index, dt: number[], texts: string[] } }` and `{ type: 'tool-call-chunks', seq0, time0, data: { turn, step, index, id, name?, dt, args: string[] } }`; `dt.length === payload.length - 1` | Top-level `assistant/chunk` events; `assistant/message` cites its chunks in `sourceEventSeqs`; surface types `user/message`, `assistant/message`, `tool/result`; replace op is `{ op, start, end }`; tool results are user-role messages wrapping one `tool-result` block; system prompt in `request/header.data.header.system`; legacy shapes may appear (below) |
| 1 | same as v0 with `version: 1` | same as v0 | Canonical v0 vocabulary only; `delivery-accepted` may carry `sessionFormatVersion` |
| 2 | required `type,version,id,createdAt,isSeeded,delegationDepth`; optional `cwd,parentSession,origin,agentPreset` | one event per row; range-encoded `sourceEventSeqs` | `assistant/message.data.stream` and log-only `assistant/attempt { turn, step, stream }`; no `assistant/chunk`; `session/end-seed { inherited: true }` marks the cut |
| 3 | as v2 with `version: 3` | as v2 | Fourth surface type `system/message`; no `header.system`; replace op `{ op, startSeq, endSeq }`; `tool/ptc-dispatch[-start]`; preset `ptc`; empty `tools`/`adapterDefaults` omitted |
| 4 | as v2 with `version: 4` | as v2 | `tool/result` message has role `tool` with flat `toolCallId`, `content`, `isError`; message `source.kind` is producer-owned (never `plugin`); fifth surface type `developer/message`; `subagent/catalog` facts; unknown extension names are `plugin:<name>` |

### Migration edges (reader logic)

All edges are streaming stages: `transformEvent(event, ctx)`, `transformRun(run, ctx)`, `finish(ctx) → targetCut`. The chain is compiled once; any stage error that is not already `SessionFormatUnsupportedMigrationError` is wrapped as `<edge name> refuses this format v<N> Session: <detail>`.

**v0 → v1** (`session-format-v0-to-v1/src/migration.ts:85`). Header: `version` only. Per event, in this order:

1. Rename `compact/start|summary|end|prune` → `compaction/…`.
2. Refuse `request/header-delta`, `mode/set`, and `request/header` with `reason: 'fallback'` (unsupported migration).
3. `turn/start` with `trigger`: require keys `turn, trigger`, `turn ≥ 1`, `trigger.kind` non-empty string; output `{ turn }`.
4. `turn/end` reasons: `completed|blocked|max-tokens|interrupted` unchanged; `aborted` without `reason` → `{ kind: 'aborted', reason: { kind: 'legacy' } }`; `disposed` → `{ kind: 'aborted', reason: { kind: 'disposed' } }`; `error` without `error`: `{ kind, step, failure: { message, code, status?, providerRetryAfterMs?, requestId? } }` → `{ kind: 'error', error: failure }`, or `{ kind, step, message, code? }` → `{ kind: 'error', error: { message, code: code ?? 'UNKNOWN' } }`.
5. `request/header`: drop `data.header.messagePrefix` (must be an array).
6. `steering/message` → `user/message`: `{ turn, message }` → data = `message`; `{ turn, content, source }` → `{ content, source, id: 'legacy-message:<sessionId>:<seq>', role: 'user' }`.
7. `llm/retry` without `retryId`: reuse the id of the same chain (`[turn, step, provider, policyKey]`, each JSON-stringified, joined by NUL) or mint `legacy-retry:<sessionId>:<seq>`.
8. Compaction ids: `compaction/start` without `compactionId` gets `legacy-compaction:<sessionId>:<seq>`; while a compaction is open, `compaction/summary`, `compaction/end`, and `user/message` with `source { kind: 'plugin', plugin: 'compact' }` lacking `compactionId` receive it; `compaction/end` and `session/end-seed` clear the open id.
9. Legacy message wrappers: `user/message` with `content` and `source` but no `id`/`role`/`message` gains `id: 'legacy-message:<sessionId>:<seq>'`, `role: 'user'`. `assistant/message` with flat `content` and a legacy source object stored under the key spelled `['pro', 'venance'].join('')` becomes `{ …rest, message: { id: legacy id, role: 'assistant', content, source: { …legacySource, kind: 'model' } } }`. `tool/result` with flat `callId, content, isError` becomes `message: { id, role: 'user', content: [{ type: 'tool-result', toolCallId: callId, content, isError }], source: { kind: 'tool', callId } }`; for a replacement the id is the id of the message at `surfaceOp.start`.
10. Validate the payload against the frozen inventory (`dispositions.ts:37`, `payload-validation.ts`). Unknown event types are refused even when ignorable. Unexpected payload members are refused.
11. A `delivery-accepted` marker for generation 0 naming another session is allowed only inside the inherited prefix of a session with `parentSession`.

Packed chunk runs pass through unexpanded. Recoverable decoding (`codec.ts:70`): the first malformed row or seq gap is remembered; later rows are dropped; a later decoded `turn/end` rethrows the remembered error.

**v1 → v2** (`session-format-v1-to-v2/src/migration.ts:124`). Header: `version` only (physical header gains `isSeeded`, loses `seedLength`). State: one pending attempt `{ turn, step, spans, stream, terminal }`, events buffered after its last chunk, source→target seq map, target cut.

- `assistant/chunk` (or a packed run): join the pending attempt when same `turn`/`step` and not terminal, else finish the pending attempt and start a new one. Chunks compact with the `AssistantStreamAccumulator` rules (see Algorithms 16). A `finish` chunk marks the attempt terminal.
- `assistant/message`: with non-empty `sourceEventSeqs` it must equal exactly the pending attempt's chunk seqs in order, else refuse (`chunk references are not one complete ordered attempt`). Output is the message without `sourceEventSeqs` and with `data.stream` = compact records. Empty or absent `sourceEventSeqs` yields `stream: []` (absent with a pending same-step attempt refuses).
- `turn/end`, `step/end`, `llm/retry`, `llm/retry-started` close the pending attempt: emit `assistant/attempt { turn, step, stream }` at the last chunk's position and time, then flush buffered events.
- Any other event arriving while an attempt is pending is buffered. A later chunk of the same attempt, or the claiming message, first emits the buffered events in order; an unclaimed attempt emits its `assistant/attempt` first and the buffered events after it. Relative order of non-chunk events is preserved.
- Every emitted event gets the next dense target seq; references are remapped: envelope `sourceEventSeqs`, `surfaceOp.start/end`, `command/done.sourceEventSeq`, `compaction/summary|prune.shadowedRange.{start,end}` and `shadowedSeqs`, `session/title[-llm-request].messageSeqs`. A reference to a consumed chunk refuses.
- Seeded sessions: the first emitted event whose source seq ≥ source cut fixes the target cut; a `session/end-seed` at exactly the cut is rewritten to `data: { inherited: true }`, otherwise a new `session/end-seed { inherited: true }` is inserted at the cut. If never reached, one is appended at `finish` with the last event time. A cut that splits an attempt refuses.
- Legacy restart: `turn/start N+1` while turn N is open with no open step and the previous event is `agent/inbox/spliced { target: 'next-turn', inserted: non-empty }` → insert `turn/end { turn: N, reason: { kind: 'interrupted' } }` first. Any other `turn/start` over an open turn refuses.
- Legacy goal: `user/message` with `source { kind: 'goal', change }` → emit `goal/change` (data = `change`) then the message with `source: { kind: 'plugin', plugin: 'goal' }`.

**v2 → v3** (`session-format-v2-to-v3/src/migration.ts:24`).

- Header: `version: 3`; `agentPreset: 'code'` → `'ptc'`.
- Source audit (`payload.ts:42`): only released-v2 inventory types plus `feedback/message-put` and `feedback/message-delete`; exact envelope and payload members; content kinds limited to `text, reasoning, image, file, tool-call, tool-result`; message source kinds limited to `user, plugin, model, tool, agent-instructions, session-reference, team-message, goal, skill-invocation, skill-catalog, coordinator, subagent-report, subagent-settled, webhook, agent-message`.
- System head: after the first `step/start`, insert `system/message` (append, `content: []`). At each `request/header`, `prompt = header.system` if a string else `''`; if it differs from the current prompt insert, immediately before that header, a `system/message` replacing the current head (`surfaceOp { op: 'replace', start: head, end: head }`, `sourceEventSeqs: [head]`); always drop `header.system`. Synthetic message: `data: { turn, step, message: { id, role: 'system', source: { kind: 'plugin', plugin: '@deepseek-ai/dsh-system-prompt' }, content: prompt === '' ? [] : [{ type: 'text', text: prompt }] } }`, `time` = anchor time, `id = 'v2-to-v3-system-' + sha256hex(JSON.stringify(['session-format-v2-to-v3', sessionId, anchor.seq, anchor.type]))`. Refuse: a surface event before the first step, a prompt change outside an open step, an id collision.
- Renames: `tool/code-dispatch-start` → `tool/ptc-dispatch-start`, `tool/code-dispatch` → `tool/ptc-dispatch`; `agent-preset/selected.agentPreset 'code'` → `'ptc'`; `source.plugin 'tools-code-mode'` → `'tools-ptc'` in `user/message.data.source`, `agent/inbox/spliced.data.inserted[].source`, `session/title-llm-request.data.messages[].source`.
- Canonicalization: `{ op: 'replace', start, end }` → `{ op: 'replace', startSeq, endSeq }`; drop `tools: []` and `adapterDefaults: {}` from `request/header.data.header`.
- Dense remap of the same reference fields as v1→v2 (`references.ts:14`). Cut = target seq of the last `session/end-seed { inherited: true }`.
- Delivery: a v2 marker claiming generation 3 refuses; a generation-2 marker naming another session is allowed only before the cut with `parentSession`.

**v3 → v4** (`session-format-v3-to-v4/src/migration.ts:41`). Requires explicit child evidence (`createSessionFormatV3ToV4(children)`; the unbound edge's `createStage` throws).

- Header: `version: 4` only.
- Interrupted-turn insertion: same pattern as v1→v2 (open turn, no open step, previous event a non-empty `next-turn` splice, `turn/start` for turn+1) → insert `turn/end { reason: { kind: 'interrupted' } }` with the start's time.
- Unknown ignorable event (type not in `RELEASED_V3_EVENT_TYPES`, `extension-identities.ts:8`) → type becomes `plugin:<original>`, payload and envelope metadata untouched, only `seq` renumbered. Unknown required type refuses.
- Reference remap when seq changed (`references.ts:18`): `sourceEventSeqs`, `surfaceOp.startSeq/endSeq`, `command/done.sourceEventSeq`, compaction `shadowedRange`/`shadowedSeqs`, title `messageSeqs`, `image/offload.targets[].seq`.
- Message sources (`sources.ts:59`), applied to `user/message.data`, `.data.message` of `developer|system|assistant/message` and `tool/result`, `agent/inbox/spliced.data.inserted[]`, `session/title-llm-request.data.messages[]`: `{ kind: 'plugin', plugin: P, …rest }` → `{ kind: K, …rest }` where K = `system-prompt` if `P === '@deepseek-ai/dsh-system-prompt'` and role is `system`; else `compact` → `compact-checkpoint`, `tools-code-mode`|`tools-ptc` → `ptc-mode`, `dsh-compaction-basic` → `compact-basic`, `@deepseek-ai/dsh-system-prompt` → `runtime-context`; else P itself when P is one of `agent-instructions, session-reference, team-message, goal, skill-invocation, skill-catalog, coordinator, subagent-report, subagent-settled, webhook, agent-message, model-selection, plan-mode, time-context, tmux-context, user-approval, repeat-tool-reminder, tool-cordis, cordis-host-runner, tool-goal, tool-jobs, hooks-codex, hooks-claude-code, schedule, dsh-session-title-llm`; else `plugin:<P>`. Non-plugin kinds are kept.
- Tool-result lift (`tool-role.ts:36`) for `tool/result` whose message role is `user`: require non-empty `id`, `source { kind: 'tool', callId }`, exactly one content block `{ type: 'tool-result', toolCallId === callId, content: array, isError?: boolean }`, no nested `tool-result`. Output message: `{ role: 'tool', source, toolCallId, content: wrapper.content, isError?, id, 'plugin:message:<k>': v for extra message keys, 'plugin:result:<k>': v for extra wrapper keys }`.
- Content tags (`content.ts:55`): block types outside `text, reasoning, image, file, tool-call, tool-result` → `plugin:<type>` in message content, `compaction/summary.summary|rawOutput`, `tool/ptc-dispatch.content`, `team/message/queued.message.content`, and in embedded stream `chunk` records (`block-end.block.type`, `block-start.blockType`). A `request/header` tool definition with own `deferLoading` refuses.
- Delivery: a v3 marker claiming generation 4 refuses; generation-3 markers validated as in v2→v3.
- Catalog completion at `finish` (`migration.ts:137`): collect own `subagent/catalog` payloads after the last inherited marker (duplicates refuse). For each supplied child (sorted by `childCreatedAt`, then `childId`): if an entry exists, require equal `childCreatedAt` and, when exactly one supported descriptor exists, equal `mode` and `label`; otherwise append `subagent/catalog` with `{ version: 0, childId, childCreatedAt, mode, label? }` when the child has exactly one descriptor of version 1 (mode `continuable`), 2 or 3 (mode from descriptor, `continuable` or `one-shot`), else `{ version: 1, childId, childCreatedAt, mode: 'unknown' }`. Appended events take dense seqs after all source events and the last source event's time (header `createdAt` for an empty log).

### Native V4 admission (current reader)

Row admission before tail recovery (`session-format-v3-to-v4/src/codec.ts:62`): developer-message rules, no `source.kind: 'plugin'`, retired syntax (non-ignorable `tool/code-dispatch[-start]`; `request/header.data.header.system`; `tool-result` blocks in interpreted content positions or stream chunks), system-message fields, tool-role message, fork-result identity. These refuse the file even after an earlier malformed row.

Artifact relationships (`relationships.ts:266`, applied by the JSONL scanner at `finish`): turn/step ordering (`turn/start` must open `nextTurn`; `step/start` must be `nextStep`), no unresolved tool call at `step/end` or `turn/end`; tool lifecycle (assistant `tool-call` blocks advertise unique ids; `tool/call` must match name and arguments; an appended `tool/result` settles one call; a result for an unstarted call must be the exact `TOOL_NOT_STARTED` repair: error `{ name: 'ToolNotStartedError', code: 'TOOL_NOT_STARTED' }`, `isError: true`, no `sourceEventSeqs`, id `interrupted-tool-result-<callId>-<integer>` with the single text block `The tool call was interrupted before the Harness recorded it as started. Retry it if it is still needed.`, or a `forked-tool-result-<callId>-<seq>` id); surface fold with a protected first system head (replaceable only by one `system/message` covering exactly it; compaction spans may not include it); PTC dispatch pairing; retry chains; title citations; `command/run`/`command/done`; compaction transactions; `developer/message.headerSeq` binding to an earlier `request/header` tool definition; own `subagent/catalog` uniqueness (versions 0..3; version 3 adds `name` matching `^[a-z][a-z0-9-]{0,31}$`, not `lead`); generation-4 delivery markers must name this session unless inherited. Open tails stay open.

### Projection cache record (`session_projcache` domain, version 7, compatible `[3,4,5,6]`, layout `per-record`, `invalidRecords: 'backup-and-skip'`)

Document on the JSON storage backend: `{ "version": 7, "record": { "identity": { "formatVersion"?: n, "createdAt": n, "cwd"?: s, "isSeeded"?: b, "inheritedEventCount"?: n }, "rows": { "<key>": { "ver": n ≥ 0, "seq": n ≥ -1, "val": <lossless JSON> } } } }`. Table name `sessions`, key = session id.

### SQLite derived index (`session-query-sqlite/src/schema.ts`)

`PRAGMA application_id = 0x44534851`, `PRAGMA user_version = 8`. A file with another application id, or id 0 with user tables, is refused. A recognized file with another `user_version` has all its tables dropped and recreated. Missing file is created with mode 0600 (directory 0700).

```sql
CREATE TABLE search_state (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), global_generation INTEGER NOT NULL) STRICT;
INSERT OR IGNORE INTO search_state (singleton, global_generation) VALUES (1, 0);
CREATE TABLE persisted_sessions (id TEXT PRIMARY KEY, version INTEGER NOT NULL, created_at INTEGER NOT NULL, cwd TEXT,
  parent_session TEXT, seed_length INTEGER, delegation_depth INTEGER, agent_preset TEXT, revision TEXT NOT NULL, generation INTEGER NOT NULL) STRICT;
CREATE VIRTUAL TABLE persisted_docs USING fts5(text, session_id UNINDEXED, seq UNINDEXED, type UNINDEXED, time UNINDEXED,
  surface UNINDEXED, codepoint_length UNINDEXED, tokenize = 'unicode61');
CREATE TEMP TABLE live_sessions (… same header columns …, fingerprint TEXT NOT NULL, persisted INTEGER NOT NULL CHECK (persisted IN (0,1)), generation INTEGER NOT NULL) STRICT;
CREATE VIRTUAL TABLE temp.live_docs USING fts5(… same columns …, tokenize = 'unicode61');
```

`seed_length` is the inherited event count when `isSeeded`, else NULL. Search cursor: base64url of JSON `{ version: 1, instance: <uuid of this service instance>, scope: 'sessions' | 'events', fingerprint: <canonical request JSON>, generation: <string>, offset: n }`.

### `dsh_session_log` request extension (`session-log-deepseek/src/types.ts`)

`{ version: 1, sessionFormatVersion, session: { version, id, createdAt, cwd?, parentSession?, seedLength?, origin?, delegationDepth?, agentPreset? }, afterSeq, throughSeq, events: [{ type, seq, time, data, ignorable?, surfaceOp?, sourceEventSeqs? }] }`. `seedLength` appears only for seeded sessions. `sourceEventSeqs` is a plain number list here (no range encoding).

### Telemetry record

`{ sourceEvent?: { sessionId, envelope: event without data }, channel: 'ledger' | 'ops', time, severity: 'info' | 'warn' | 'error', attributes, body }`. Ledger attributes: `session.id`, `session.format_version`, `event.type`, `event.seq`, optional `session.cwd`, `session.parent_id`, `session.seed_length`. Ops attributes: `telemetry.op` (`agent-error` | `shutdown`), `session.id`, and for `agent-error` `agent.id`, `error.name`, `turn`, `step`. OTel mapping: scope name `@deepseek-ai/dsh-session-telemetry-otel`; resource `service.name`, `service.version`, `user.id`; body is the whole event (`envelope` + `data`).

### Export formats and HTTP routes

- `GET|HEAD /api/session.export?sessionId=<id>&includeDescendants=true|false` → `application/zip`, `content-disposition: attachment; filename="dsh-session-<id with [^A-Za-z0-9_-] → _>.zip"`. 400 `missing or invalid sessionId query parameter`; 404 `session not found`; 500 `session log export is unavailable: missing session-query, session-persistence, or attachments service` or `session log export failed to read the stored log`.
- `GET|HEAD /api/session.markdown?sessionId=<id>` → `text/markdown; charset=utf-8`. 404 `session not found`; 500 `session markdown export failed to read the stored log`.
- ZIP entries, in order: `session.v4.jsonl` (root), `subagents/<safe id>/session.v4.jsonl` per descendant in lineage order (depth-first), `media/<attachmentId>.<png|jpg|webp|gif>` per distinct image, `files/<digest[0:2]>/<digest>/<safe name>` per distinct `(attachmentId, name)` file (`sha256:` prefix stripped; name chars `\ / control DEL` → `_`; `.`, `..`, empty → `file`). No manifest. Each entry DEFLATE at the configured level.
- Exported log text (`archive.ts:110`): header line as in the v4 physical header, then `JSON.stringify(event)` per event (expanded `sourceEventSeqs`), `\n` after every line.
- Markdown transcript: see Algorithms 24.

### Environment variables

`DSH_HOME` (home root), `DSH_TELEMETRY_MODE`, `DSH_TELEMETRY_OTLP_URL`, `DSH_TELEMETRY_DISABLED` (any non-empty value makes launchers disable the telemetry row). No CLI flags are defined in this area.

## Algorithms and invariants

1. **Generation selection** (`session-persistence-jsonl/src/index.ts:1536`, `:1575`). For an id, scan every project directory under the root for `<project>/<encodeSegment(id)>/`; in each, pick the numerically highest canonical generation for the configured suffix. More than one project directory holding the id → `duplicate JSONL session id "<id>" appears in multiple project directories`. Selected version < 4 → historical path; = 4 → current; > 4 → `SessionFormatUnsupportedError` with `(raw log: <path>)`. The header's `version` must equal the filename's version, and the header `id` + `cwd` must map back to the same path (same file by `realpath` is accepted for case-insensitive filesystems).

2. **Lazy materialization** (`index.ts:360`, `:1265`). `create` validates and snapshots the header, checks pending and on-disk duplicates, registers a pending entry (revision `memory:session-persistence-jsonl:<counter>`), and writes nothing. The first `append` or `flush` on the handle: acquire the lease, `mkdir -p` root, project, session directories with mode 0700 fsyncing each parent, refuse if any generation already exists in the directory, write `<final>.<12 hex>.tmp` with `O_EXCL` mode 0600, fsync, `link(tmp, final)` (fails with `EEXIST` instead of overwriting), fsync the session directory, best-effort remove tmp. Windows: `MoveFileExW` with `MOVEFILE_WRITE_THROUGH`, no replace. Closing a create handle that never materialized erases the session.

3. **Append** (`index.ts:1413`). Encode the batch (one frame or raw lines), open with `O_APPEND`, record size, write, fsync. On write or sync failure close, truncate back to the recorded size, fsync, rethrow (`AggregateError` if rollback also fails). The handle cursor does not advance on failure, so the batch can be retried without duplicate seqs.

4. **Handle mutation chain** (`storage.ts:85`). All mutations of one handle run serially on a promise chain; a failed operation does not poison the chain. `append` snapshots the batch before queueing. `persistContiguous` (`:319`): read-only check, empty batch no-op, `ensureLease`, `assertContiguous` against `cursor`, pending torn-tail truncate, pending recovered-tail rewrite, write, then `materialized = true`, `cursor += n`, drop the primed prefix.

5. **Live write-behind** (`storage.ts:274`, `:535`). `session/event` routes a structured clone of the event into the active write handle for that session id (no handle → nothing persisted). The first buffered event arms one 200 ms timer (`LIVE_WRITE_BATCH_MAX_DELAY_MS`); later events join without resetting it. `drainLive` is single-flight: cancels the timer and loops, each pass splicing the whole buffer inside a chained turn. On failure the batch is put back at the front, `drainPaused = true` (timer stays quiet), and the error is reported: background failures log a warning, explicit `session/flush` rejects. `session/flush` = `drainLive` then `flush`. `session/disposed` = `close` (warn on failure). `close` loops drain until the buffer is empty, releases the lease, releases the in-process claim even on failure, and aggregates failures.

6. **Single writer** (`storage.ts:391`, `lease.ts`). In-process: a map id → handle (or `null` while constructing); `create` on a claimed id → `SessionAlreadyExistsError`; `open(write)` → `SessionAlreadyOwnedError`. Cross-process: non-blocking exclusive `flock(2)` on `<session dir>/session.lock` (opened with `'w'`), held for the handle lifetime; `EAGAIN`/`EWOULDBLOCK` → `SessionAlreadyOwnedError`. After locking, compare the locked inode (`dev`,`ino`) with the path's current inode; mismatch → close and retry, 3 attempts, then `SessionAlreadyOwnedError`. The lock file is never deleted. Write open takes the lease before reading the log; a created session takes it immediately before first materialization. Windows uses a named semaphore `Local\dsh-session-lock-<sha256hex(lowercase resolved lock path)>`.

7. **Current-generation scan and tail repair** (`format.ts:386`, `index.ts:815`, `:994`).
   - Raw mode: split on `\n`; an unparsable or invalid row sets a sticky issue; later rows are ignored, except that a later row with `type: 'turn/end'` rethrows the issue (corruption inside a committed region). `committedBytes` advances only past accepted rows. A final fragment without newline is dropped. If `committedBytes < file size`, `tornTruncateTo = committedBytes`.
   - Zstd mode: structural frame scan (`zstd.ts:48`): magic `0xFD2FB528` little-endian; frame header descriptor (reserved bits `0x18` must be 0; content-size flag, single-segment, checksum, dictionary flags size the header); blocks with 3-byte headers (last-block bit, type, size; type 3 invalid; RLE payload is 1 byte); optional 4-byte checksum. EOF inside a frame returns `tornStart`. Complete frames are decompressed and checksum-verified; frame 1 must be exactly one header line; complete frames must end on a record boundary and every row in them must decode (else corruption). For a torn final frame, decompress whatever plaintext the partial frame yields (flush mode, no end-of-frame requirement), feed it to the scanner, and keep complete records as `recoveredTail`; `tornTruncateTo = tornStart`.
   - Row admission (`assertV4RowAdmission`) runs before recovery suppression. `finish` runs the codec finish and `assertReleasedV4Relationships`.
   - Read handles only omit the tail. A write handle, before its first new batch, truncates the file to `tornTruncateTo`, fsyncs, logs `…recovered from a torn tail; incomplete tail bytes were discarded`, then durably rewrites `recoveredTail` as one batch. Each step clears its state only after success.
   - Decoding yields to the event loop when more than 500 ms elapsed between frames.

8. **Stable read** (`generation.ts:262`). `stat`, read whole file, `stat`; identical identity (`dev:ino:size:mtimeNs:ctimeNs`) → done; else retry once; if still different return the second read truncated to the pre-read size with that identity.

9. **Cold log memo** (`index.ts:67`, `:875`). LRU of at most 2 parsed logs keyed by session id and guarded by revision. Every local mutation for an id deletes its entry. Events are deep-frozen once before memoization and reported `shared-frozen`; only an unmaterialized pending log reports `detached` (empty).

10. **Read of a historical generation** (`index.ts:569`, `:679`). One shared preparation per `(id, source path, source revision)`; callers join it; it aborts only when its last waiter leaves. Steps: list direct children (`origin: 'subagent'`, `parentSession === id`) from header listing; `prepareCatalogFacts` decodes each child with `recovery: 'recoverable', validation: 'current'` through `historicalSessionFormatCatalog` (v ≤ 3) or the static catalog, records a stat witness per child, and turns each into `{ childId, childCreatedAt, descriptorCount, descriptor, sourcePath }` (failures become `descriptorCount: 0, descriptor: null` plus a logged warning); decode and migrate the parent with `createSessionFormatCatalogWithChildren(facts)` and `{ recovery: 'recoverable', validation: 'transformed' }`; re-validate child membership and witnesses; `validateStoredEvents`; freeze; memoize as `prepared`. A read open returns it without writing (one retry on `JsonlGenerationSourceChangedError`). `stat`/`list` never start a migration.

11. **Exclusive successor publication** (write open only; `generation.ts:884`). Encode the current artifact into `session.migration.<16 hex><suffix>.tmp` (`O_EXCL`, 0600) in ~1 MiB row slices and 4 MiB writes while hashing (SHA-256) and counting bytes; fsync. Verify the staged file in a Worker Thread (at most 2 concurrent verifiers process-wide): strict decode, `validateStoredEvents`, id and event-count match, `Session.fromRestore`, and full replay of every embedded assistant stream (assembled content, usage, and replay state must equal the stored message). The verifier's byte count and digest must equal the stage's. Re-validate related sources, re-stat the source (changed → `JsonlGenerationSourceChangedError`), then `link(stage, session.v4.jsonl…)` and fsync the directory. On `EEXIST` accept the existing target only if it is a regular canonical file whose first `stage.bytes` bytes hash to the stage digest (an appended tail is allowed). Remove the stage. The source file is never modified or deleted. Unsupported-migration failures surface as `SessionFormatUnsupportedError('<reason>; source v<N> artifact remains unchanged (raw log: <path>)')`.

12. **Revisions** (`index.ts:200`, `:1121`). Current: `dev:ino:size:mtimeNs:ctimeNs` of the selected file. Historical: that string plus `:` plus SHA-256 hex over `JSON.stringify([path, revision])` for every selected generation path under the root, sorted by path (missing → `'missing'`), because historical logical events depend on child logs. One `list()` computes the corpus hash once.

13. **Listing** (`index.ts:522`, `:1138`). Snapshot pending entries first, then scan storage (so a session materializing mid-scan is not lost). Directory, header, and stat reads share one limiter (`listConcurrency`). Headers that are unsupported or corrupt (including corrupt zstd header frames) are omitted from `list`; a filename/header version mismatch, an identity/path mismatch, or a duplicate id rejects the listing. Header-only reads use 8 KiB chunks and, for zstd, decode only frame 1.

14. **Format catalog dispatch** (`session-format/src/catalog.ts:29`). Construction requires exactly one codec per version 0..current and exactly one edge per adjacent pair. `readHeader` → `current | migration-required | unsupported | malformed`. `createRestore(header, { recovery, validation })`: current version → codec decoder plus `restoreCurrent` when `validation: 'current'`, identity otherwise; older → decoder feeding the compiled stage chain into a collector, then `restoreCurrent` or `restoreTransformedCurrent`. A decoder or stage that changes a predeclared inherited cut is an error.

15. **Recoverable decoding rule shared by all codecs**: first bad row or seq gap is remembered; subsequent rows are discarded; a later `turn/end` proves the bad region was committed and rethrows. Strict mode throws immediately.

16. **Assistant stream compaction** (`packages/llm/llm/src/assistant-stream.ts:100`, used by v1→v2 and by verification). Consecutive `text-delta` (or `reasoning-delta`) chunks with the same `index` pack into `{ type: 'text-chunks' | 'reasoning-chunks', time0, index, dt: [gaps], texts: [...] }`; `tool-call-delta` chunks with same `index`, `id`, and name presence/value pack into `{ type: 'tool-call-chunks', time0, index, dt, id, name?, args }` (a delta with empty `id` or empty `name` stays raw); every other chunk is `{ type: 'chunk', time, chunk }`. Token boundaries are never joined.

17. **Projection drive** (`session-projection/src/index.ts:887`). Per event, per live registration in registration order: skip if the cell already observed this seq; build a missing cell by folding `init` over the log prefix before this event; advance a lagging cell; `next = apply(state, event)`; `changed = !eq(next, state)`; set `observedSeq`. For wire units when changed: shift the two-slot view cache; if any listener exists compute `view(next)`, and if it differs by reference from the previous view, schema-validate and notify. `session/created` with `seq === 0` pre-creates cells from `init`.

18. **Checkpoint restore** (`:637`, `:711`). `restoreFloor` = `max(min over live units of (usable row ? row.seq + 1 : 0) - 1, 0)`; usable means `row.ver === stateVersion`. `restore` treats a row as usable iff `ver` matches and `baseSeq - 1 ≤ row.seq ≤ endSeq`; an unusable row with `baseSeq > 0` throws (`…re-read from seq 0`); folds events after the row's seq, requiring contiguous seqs; returns wire values and refreshed rows at `endSeq`. `hydrate` installs restored states as cells on a prepared session unless cells already sit at the cut. `viewCheckpoint` serves `view(stateSchema.parse(row.val))` for version-matching rows, skipping rows that fail the schema.

19. **Projection cache write policy** (`session-projection-cache/src/index.ts:312`). Mandatory writes: `session/created`, every `turn/end`, `session/disposed`. Throttled: each other event increments a per-session counter; reaching `writeEveryEvents` writes; otherwise arm one timer of `writeIntervalMs`. `write`: take `checkpoint(session)`, reset dirty state, `await ctx.sessions.flush(session)` if the session is still in the store (log durability first, so the cache can trail but never lead the log), then replace the whole record. Background writes log warnings on failure. Identity match for fold use: same `formatVersion`, `createdAt`, `cwd`, `isSeeded` (absent → false) and `inheritedEventCount` (absent → 0); listing use omits the cut; `cachedPredecessorTitle` requires stored `formatVersion` absent or lower.

20. **Title pipeline** (`session-title/src/index.ts`).
    - Eligible message: `user/message` with `source.kind === 'user'` whose text blocks joined by `\n` normalize to non-empty.
    - Normalization (`normalize.ts:59`): remove OSC sequences, CSI sequences, two-byte ESC sequences, C0/C1 controls except whitespace, and directional/invisible controls (`U+200B, 200E, 200F, 202A–202E, 2060–2064, 2066–206F, FEFF`); collapse whitespace runs to one space; trim; truncate to `maxBytes` UTF-8 bytes without splitting a code point; trim end. Fallback (`:70`): cleaned text, first `fallbackMaxWords` space-separated words, truncate to `fallbackMaxBytes`, trim end.
    - On each eligible message (`:510`): if a user title is standing, do nothing. If a provider is registered, schedule when `automatic === 'all-prompts'`, or when the session is not seeded, not `origin: 'subagent'`, this is the first eligible message, and no title exists. Scheduling aborts active work, bumps the session revision, and records `pending { registration, revision, throughSeq: event.seq }`. Then, always, defer `ensureFallback`: if no title exists append `session/title { title: fallback, messageSeqs: [first.seq], source: { kind: 'fallback' } }`.
    - Pending work starts when a `request/header` event with `seq > throughSeq` is logged (route = its `config.provider/model`), or on an agent-loop `llm/stream` request for that session whose provider/model equal the session's current request header while the last step boundary is a start. The provider call receives messages through `throughSeq`, the current title, the route, and an abort signal (superseded by newer messages, rename, refresh, provider or service disposal, session disposal). The result is accepted only if the work is still current: `title` normalizes non-empty; `messageSeqs` non-empty, unique, in request order, all from the request. Append `session/title` with `source { kind: 'provider', provider: id, model? }`.
    - `rename` appends `{ title, messageSeqs: [], source: { kind: 'user' } }` and supersedes automatic work. `refresh` without a provider re-derives the fallback over a user title.
    - First-prompt provider (`session-title-first-prompt-llm/src/index.ts:81`): system prompt is five lines (exact text in source); user input is `Generate the session title from this JSON array of human messages:\n` + `JSON.stringify([{ seq, text }])`; reasoning effort = the route's least effort; output = first non-empty line, with whole-line `*`/`**`/`***` emphasis stripped; `tool-calls` or `max-tokens` finishes are errors.
    - `executeSessionTitleLlm` (`session-title-llm/src/index.ts:236`): input byte limit, route = explicit config pair or the logged route, deadline `timeoutMs` with reason code `SESSION_TITLE_TIMEOUT`, append `session/title-llm-request` before streaming, request `purpose: 'session-title'`, message source `{ kind: 'dsh-session-title-llm' }`.

21. **Stats fold** (`session-stats/src/projection.ts:107`). `step/start` opens `{ turn, step, startTime, firstTokenTime: null }`. `assistant/attempt` for the open step records the first token time once. `assistant/message` for the open step adds `max(0, time - startTime)` to `llmMs`, closes the step, and if a first token exists adds `ttftMs`, `ttftSteps += 1`, and (when `usage.outputTokens` is a finite non-negative number) `decodeMs`, `decodeTokens`. `tool/call` stores dispatch time by `callId`; `tool/result` (own-key lookup by `message.source.callId`) adds `toolMs`. `step/end` increments `steps` and increments `turns` when its turn differs from `lastTurn`. `turn/end` clears pending calls. All other events return the same state.

22. **Turn outline fold** (`session-turn-outline/src/projection.ts:85`). `turn/start` with a turn greater than the last entry appends `{ turn, seq, prompt: '', response: '' }`. The first human `user/message` of the newest turn sets `prompt` (limit 50). Each text-bearing `assistant/message` updates `draft` (limit 120). `turn/end` commits `draft` into `response`. `preview(content, limit)`: join text blocks with spaces, each block clipped to `2 × limit` UTF-16 units, collapse whitespace, trim; if longer than `limit - 1` units cut to `limit - 1`, trim end, append `…`; if input was clipped append `…`.

23. **Telemetry capture** (`session-telemetry/src/coordinator.ts`). A module-level weak map Session → highest handed-off seq. `captureSession(session, throughSeq?)` starts after the cursor, or at `firstLifecycleSeq` (0 with `includeHistory`), builds one ledger record per event (deep copies), runs the waterfall, calls `backend.emit`, then advances the cursor; each event is contained separately. Live mode adopts sessions on `session/created` and at construction, captures on `session/event`, emits a `shutdown` ops record on `session/disposed` and at teardown, and relays `agent/error`. Severity: `error` for `tool/result` with `message.isError === true` and `turn/end` with `reason.kind === 'error'`, else `info`. OTel backend: on-demand with history; a `feedback/record`, or `feedback/message-put|delete` naming this session, at or after the inherited cut, triggers `captureSession(session, event.seq)` only if the event object is the canonical log entry; `feedback/committed` does the same on a detached restore. The public `emit` drops records. `DISABLED` only warns when feedback is recorded. Shutdown races the provider against `shutdownTimeoutMillis`.

24. **Markdown transcript** (`session-log-export/src/markdown.ts:65`). Heading `# <latest session/title, newlines → spaces>` or `# Untitled Session`. Optional `Session file:` plus a fenced `text` block. Turns are delimited by `turn/start`/`turn/end`. Segments: appended human `user/message` (text, `[Image: name (W×H, N bytes)]`, `[File: name (N bytes)]` joined by blank lines), appended `assistant/message` with visible text, `tool/call`, appended `tool/result` matched by call id. The final reply is the last segment when it is an assistant entry without tool calls. Before it: user segments render as blockquotes (`> ` per line, `>` for empty lines); runs of assistant/tool entries render as `<details><summary>N previous message(s)</summary>` containing `**Assistant**` blocks and `**Tool: \`name\`**` blocks (arguments pretty-printed JSON in a `json` fence or `(no arguments)`; `**Result**` or `**Result (error)**`; `(no result recorded)`, `(no output)`, `Error: <reason>`). Fences use one more backtick than the longest run in the content. Unfinished code fences are closed. `<details>`/`<summary>` tags outside code are escaped to `&lt;`. Output ends with exactly one newline.

25. **DeepSeek log upload** (`session-log-deepseek/src/index.ts:151`, `:196`). `acceptedThrough(session)`: incremental fold over `delivery-accepted` events for this session id and current format version; highest `throughSeq`; malformed markers throw. `prepare(request)`: skip when disabled, no session, or excluded; pending = events after the watermark; add events while the serialized field size stays ≤ `maxBytes`, computed as `bytes(envelope with throughSeq 0 and empty events) - 1 + per-event bytes + separators + digits of the candidate throughSeq`; if not even the first event fits, warn once per blocked seq and contribute nothing. `accept()` (called on a 2xx) appends `delivery-accepted { sessionId, sessionFormatVersion, throughSeq }`.

26. **Checkpoint policy** (`session-checkpoint-policy/src/index.ts:63`). `llm/stream` with a live session id: return a stream that awaits `ctx.sessions.flush(session)` before pulling from `next()`; a flush rejection prevents dispatch. `tools/execute` with an agent and no parent: flush, then if the signal is aborted return `{ content: [{ type: 'text', text: 'Error: tool call aborted before dispatch' }], isError: true, error: { message: 'tool call aborted before dispatch', info: { name: 'AbortError', code: TOOL_ABORTED_BEFORE_DISPATCH } } }`, else `next()`. `agent/pre-step`: flush, then `next()`.

27. **Working directory** (`working-directory/src/index.ts`). Operations per session are serialized. Projection: `init = header.cwd ?? null`; `working-directory/change` sets it. `get` = projection ?? `defaultDirectory`. `ensure`: resolve and stat the current directory; if it is a directory, record it once when nothing is recorded; else restore the header cwd (or default), and if that is missing throw `WORKING_DIRECTORY_UNAVAILABLE` (`working-directory: directory does not exist: "<original>"; the current working directory "<current>" is also unavailable`). `set`: resolve `path` against the current directory, require a directory, canonicalize through `fs.processPath`. `commit`: no-op when unchanged; append `working-directory/change`; inject a user message with source `{ kind: 'working-directory' }` and text `The working directory changed from "<prev>" to "<dir>".` or `The working directory "<prev>" is unavailable. The working directory is now "<dir>".` (paths JSON-quoted); an inject failure only warns. System prompt: a required context entry `working-directory:current` with text `Current working directory: "<dir>".`, refreshed on each `system-prompt/assemble` after `ensure`.

28. **session-query corpus** (`session-query/src/corpus.ts`, `observation.ts`). Live sessions shadow persisted ones. `listSessions` sorts by `createdAt` descending then id. A cold read (`cold-read.ts:31`) opens a read handle, reads all, closes, and appends in-memory `interruptedTurnClosers(events)`; nothing is written. Headers from two observations must agree on `id, createdAt, cwd, parentSession, isSeeded, delegationDepth ?? 0` (`SESSION_QUERY_SOURCE_CONFLICT`). `observeSession`: live → lease over the live log at the current length (events materialized lazily); cold → `stat`, then an LRU cache per id keyed by `(persistence.identity, revision)` holding an unpublished prepared Session; capacity `preparedSessionCacheSize`, entries with active leases are never evicted; projections come from `sessionProjectionCache.hydratePrepared` or `registry.hydrate`. `readEvent` window bounds 0..`readWindowMax`. Text filter: literal, case-insensitive, whitespace-flexible regex. Semantic text per event (`extraction.ts:15`): user and assistant text blocks and tool-call name/arguments (no reasoning), `tool/call` name + arguments, `tool/result` text + error name/code, `todo/write` status + content, `turn/end` (`error` + message, `aborted`, `max-tokens`, `interrupted`); everything else empty. Surface class: `current`, `shadowed`, `log-only` from one `foldSurface`.

29. **SQLite search** (`session-query-sqlite/src/index.ts`). All searches are serialized on one promise tail. Reconcile before each query: list persistence twice around the work and require identical `(id, revision, header)` sets, require the live id set to be stable, one retry, else `SESSION_QUERY_PERSISTENCE_FAILED`. Re-index a persisted session when its revision differs (skipping ids that are live); delete rows for vanished ids; re-index a live session when its fingerprint (`sha256 base64url` of `JSON.stringify({ header, inheritedEventCount, events })`) or persisted flag changed. One `BEGIN IMMEDIATE` transaction. Generations: persistent `global_generation` bumps on persisted changes; live rows get increasing local generations. Query: the user text is whitespace-normalized, NUL-free, wrapped as one FTS5 phrase (`"…"` with `"` doubled); `highlight()` with markers `U+FDD0`/`U+FDD1`; `match_count` = number of start markers; persisted docs are hidden when a live row exists for the session. Order for events: `match_count DESC, document_length ASC, time DESC, seq DESC`; for sessions: best event per session by that order, then `match_count DESC, document_length ASC, time DESC, session_id ASC, seq DESC`. Paging is `LIMIT limit+1 OFFSET offset`. A cursor is valid only for the same instance, scope, and canonical request; a generation change → `SESSION_QUERY_STALE_CURSOR`. Limits: at most 14 outer predicates, 32766 bound variables. Snippet (`query.ts:269`): strip markers, collapse whitespace, at most `snippetChars` code points, window starts `floor(max/3)` before the first match, `…` at clipped ends.

30. **ZIP streaming** (`session-log-export/src/archive.ts:545`). Flush the live root session, read and serialize it before answering (so 404/500 can be clean). Entries are produced lazily; each descendant is flushed if live and read right before it is written; a missing descendant fails the stream. Text is pushed in 65536-code-unit chunks without splitting a surrogate pair; binary in 65536-byte chunks; the response queue high-water mark is 65536 bytes and the producer waits for consumer pull. Request abort and consumer cancel share one signal.

## Tests worth porting

Shared seam suites (run against any backend):

- `packages/session/session-persistence/tests/contract.ts` — 21 cases: round trip and offset/length defaults, argument validation, duplicate create (pending, concurrent, materialized), absent open, single write holder, read-handle refusals, closed-handle refusals and idempotent close, service flush, pending visibility and erasure, empty-session flush, freshness, cursor continuation in a fresh instance, contiguity error text, non-JSON rejection, unknown-type fail-closed, torn tail never served and truncated by the writer, stable revisions.
- `packages/session/session-persistence/tests/live-write-contract.ts` — 12 cases for routing, batching window, flush retry semantics, disposal drain, teardown sweep, failed-drain ordering.
- `packages/session/session-persistence/tests/storage-contract.spec.ts`.

JSONL backend (`packages/session/session-persistence-jsonl/tests/`): `jsonl.spec.ts` (layout, encodings, materialization, repair), `zstd.spec.ts` and `zstd.compat.spec.ts` (frame scanner, torn frames), `generation.spec.ts` and `multi-edge-publication.spec.ts` (staging, exclusive publish, race winner acceptance, source drift), `lease.spec.ts`, `lease.two-process.e2e.ts` with `fixtures/lease-holder.mjs`, `load-path.spec.ts`, `migration-refusal.spec.ts`, `catalog-migration.spec.ts`, `v2-system-migration.spec.ts`, `v2-ptc-migration.spec.ts`, `v3-restart-migration.spec.ts`, `fork-delivery.spec.ts`, the admission specs (`current-event-admission`, `content-admission`, `retired-content-admission`, `native-developer-admission`, `native-source-admission`), and the fixture `fixtures/released-v0-real-shapes.jsonl`.

Format library and edges: `session-format/tests/{catalog,chain,filename,json}.spec.ts`; `session-format-catalog/tests/*`; `session-format-v0-to-v1/tests/{codec,legacy,migration,relationships,validation}.spec.ts`; `session-format-v1-to-v2/tests/*`; `session-format-v2-to-v3/tests/*` (notably `combined-migration`, `canonical-envelopes`, `content-admission`); `session-format-v3-to-v4/tests/*` (20 files: `tool-role`, `sources`, `catalog-completion`, `interrupted-turn`, `fork`, `developer*`, `relationships`, `retired-*`, `open-vocabulary`, `corpus`).

Golden corpora: `snapshots/session/<case>/session.v2.jsonl`, `session.v3.jsonl`, `session.v4.jsonl` (normalized recorded sessions per generation; many cases) and `snapshots/web/plugin-recommendations/tool-schemas.expected.json` (tool schema). `docs/persistence-changes/historical-formats/v{0..3}.schema.json`.

Projections: `session-projection/tests/{registry,registration-reader,summary,compatibility}.spec.ts`; `session-projection-cache/tests/cache.spec.ts`, `fixtures.spec.ts` with `fixtures/v3-single-unit.json`, `v4-session-doc.json`, `v5-session-doc.json`, `v5-lineageless-doc.json`, `v7-opaque-session-doc.json`; `session-stats/tests/projection.spec.ts`; `session-turn-outline/tests/projection.spec.ts`.

Titles: `session-title/tests/{session-title,provider,rename,projection,persistence,initialization,service-contracts}.spec.ts`; `session-title-llm/tests/llm.spec.ts`; `session-title-first-prompt-llm/tests/provider.spec.ts`.

Others: `session-telemetry/tests/{telemetry,redact}.spec.ts`; `session-telemetry-otel/tests/{otel,egress}.spec.ts`; `session-checkpoint-policy/tests/session-checkpoint-policy.spec.ts` and `crash-recovery.e2e.ts`; `session-log-deepseek/tests/upload.spec.ts`; `working-directory/tests/{working-directory,admission}.spec.ts`; `session-query/tests/{session-query,observation,tracing,search-helpers}.spec.ts`; `session-query-sqlite/tests/{sqlite,query}.spec.ts`; `session-log-export/tests/{archive.host,markdown.host,route.host,markdown-route.host,command.host}.spec.ts`.

## Porting notes

Essential product behavior:

- The `SessionPersistence`/`SessionHandle` contract, including lazy materialization, single writer, freshness, torn-tail semantics, and the error vocabulary.
- Byte-level compatibility with existing `~/.dsh/sessions` trees: directory naming, generation filenames, header and event records, range-encoded `sourceEventSeqs`, Zstandard frame container, `session.lock`.
- Reading v0..v3 and publishing v4 successors without touching sources.
- Projection units (keys, state versions, state JSON) and the cache record, so a shared home works with either implementation.
- The `session/title`, `session/title-llm-request`, `delivery-accepted`, `working-directory/change` payloads; the `working_directory` tool text and schema; the model-visible notice and context strings.

Node/TypeScript machinery that need not be reproduced literally:

- Deep-freeze and `structuredClone` passes, the `eventState` flag (keep the field; immutable Racket data makes both states equivalent), the Node-private synchronous zstd decoder, the tsx worker bootstrap, the callable-thenable registration value, deprecated registry methods, v8-coverage guards, Windows semaphore and `MoveFileExW` paths (unless Windows is a target).
- The Worker Thread for publication verification can be a place or a plain thread; the required property is that publication happens only after an independent strict re-read of the staged bytes with digest equality.

Suggested Racket decomposition:

- `session-format/` — `json.rkt` (safe-integer, count, lossless JSON checks), `filename.rkt`, `chain.rkt`, `catalog.rkt`; stages as structs of closures or a `gen:migration-stage` generic. Codec decoders are small state machines; represent compact chunk runs as a struct with a lazy `expand`.
- `session-format/v0-v1.rkt` … `v3-v4.rkt`, `catalog.rkt` (static lists; a function for the child-bound catalog).
- `session-persistence/` — `gen:session-persistence` and `gen:session-handle` (or structs of procedures), exception structs per error class, `storage-contract.rkt`.
- `session-persistence-jsonl/` — `format.rkt`, `zstd.rkt` (pure frame scanner + FFI), `lease.rkt`, `handle.rkt` (per-handle serializing thread or semaphore-guarded queue; batching timer with `alarm-evt`), `generation.rkt`, `plugin.rkt`.
- `session-projection/` (registry with `make-weak-hasheq` cells keyed by session; `eq?` gates) and `session-projection-cache/`.
- One module each for title, title-llm, first-prompt provider, stats, outline, telemetry, telemetry-otel, checkpoint policy, deepseek log, working directory, tool.
- `session-query/` (corpus, observation, filters, tracing, extraction), `session-query-sqlite/`, `session-log-export/`.
- Cancellation: map `AbortSignal` to the kernel port's cancellation token; custodians own file descriptors, timers, and worker places; plugin effects become custodian-registered disposers. Zod and Schemastery schemas become contracts or explicit validators that return parsed values.

Hard parts and risks:

1. **Zstandard.** Racket has no built-in zstd. Bind libzstd through `ffi/unsafe`: one-shot compress with the checksum flag, one-shot decompress with checksum verification per frame, and streaming decompress of a partial frame to recover the torn-frame prefix. The structural frame scanner is pure and must be ported exactly. Fallback: `compression: 'none'` roots work without the library, but the shipped default is zstd.
2. **Durability primitives.** Racket exposes no `fsync`, no directory sync, and no hard `link(2)`. All three need FFI (`fsync` on a file descriptor from `unsafe-port->file-descriptor`, `open`+`fsync` on directories, `link`). `O_EXCL` creation is `#:exists 'error`.
3. **Lock interoperability.** The Node backend uses `flock(2)` on `session.lock`. Racket's `port-try-file-lock?` must use the same lock family on each platform to exclude a concurrently running dsh; verify per platform or call `flock` through FFI. Keep the inode re-check and never delete the lock file.
4. **JSON fidelity.** Several behaviors depend on exact `JSON.stringify` output: the title-request frame text (model-visible and re-validated by the v0/v1 relationship checker), the legacy goal-state content check, the v2→v3 synthetic system id hash, `maxBytes` accounting for `dsh_session_log`, retry-chain keys. Use an order-preserving JSON object representation and a writer that matches JavaScript escaping and number formatting. Racket `hasheq` jsexprs lose key order.
5. **UTF-16 semantics.** `encodeSegment`/`projectKey` escape per UTF-16 code unit; turn-outline limits and schema `max` lengths count UTF-16 units; Racket strings cannot hold lone surrogates, so ids or texts containing them cannot round-trip. Decide and document the behavior (refuse such ids).
6. **`isAbsolute` and `localeCompare`.** Header `cwd` validation uses the host platform's notion of absolute. Session ordering by id uses `localeCompare`; code-point order is equivalent for UUID ids but not in general.
7. **SQLite.** Needs FTS5 with `highlight()` and `STRICT` tables in the linked libsqlite3; temp-schema FTS tables; synchronous access serialized by one queue. The shipped default is `openAt: never`, so search can land late, but the non-search methods of `ctx.sessionQuery` are used by export, references, and the session list.
8. **Historical validators.** The frozen v0/v1 payload validator (1072 lines) and relationship checker (497 lines) are reused by v2 and v3 restoration. They define which historical logs migrate and which are refused; port them table-driven and test against `snapshots/session/*/session.v2.jsonl|v3.jsonl` and the v0 fixture.
9. **Installed-current validation.** `restoreCurrent` and publication verification call core `Session.fromRestore` with `currentSessionMessageProjections` (currently only the image-offload projection). The session-plane port depends on the core session port for that step.
10. **OTel.** Either wrap an OTLP/HTTP logs exporter or implement the JSON protocol; byte-bounded batching and the serial request queue live in `dsh-otel` (another area).
11. **ZIP streaming.** Needs a streaming DEFLATE zip writer with backpressure; `file/zip` may need replacement to bound memory for large attachments.

## Feature checklist

- session-persistence: abstract service with `create`, `open`, `flush`, `stat`, `list` and `identity`
- session-persistence: handle `read(offset, length)` with monotonic reads and `eventState`
- session-persistence: handle `append` contiguity check with exact error text
- session-persistence: handle `flush` materializes an empty created session
- session-persistence: idempotent `close`; closed-handle and read-only refusals
- session-persistence: typed errors and version refusal texts
- session-persistence: `validateStoredEvents` unknown-type and legacy `fallback` refusal
- session-persistence: lossless-JSON materialization of headers and batches
- session-persistence-jsonl: config `root` (required), `compression`, `listConcurrency`
- session-persistence-jsonl: project/session directory layout, `_no-cwd`, `encodeSegment`, `projectKey`
- session-persistence-jsonl: canonical generation filenames and highest-generation selection
- session-persistence-jsonl: v4 header record encode/decode with exact key set
- session-persistence-jsonl: one event per row with range-encoded `sourceEventSeqs`
- session-persistence-jsonl: Zstandard concatenated checksummed frames (header frame + batch frames)
- session-persistence-jsonl: raw newline-delimited mode
- session-persistence-jsonl: root encoding exclusivity and flat-layout refusal
- session-persistence-jsonl: lazy materialization with temp file, fsync, no-overwrite link, directory fsync
- session-persistence-jsonl: append with fsync and rollback to prior size on failure
- session-persistence-jsonl: live event routing with 200 ms batching window and single-flight drain
- session-persistence-jsonl: failed drain retains order, pauses timer, retried by flush
- session-persistence-jsonl: `session/flush` and `session/disposed` handling; teardown close sweep
- session-persistence-jsonl: in-process write claim and pending-session visibility
- session-persistence-jsonl: `session.lock` flock lease with inode re-check
- session-persistence-jsonl: raw torn-tail detection and truncation offset
- session-persistence-jsonl: Zstandard structural frame scan and torn-frame record recovery
- session-persistence-jsonl: write-path truncate plus durable rewrite of recovered tail
- session-persistence-jsonl: `turn/end` after a bad row is corruption
- session-persistence-jsonl: row admission refusals survive tail recovery
- session-persistence-jsonl: `stat`/`list` header-only reads with `formatStatus`, `sizeBytes`, `location`, revision
- session-persistence-jsonl: historical revision includes corpus fingerprint
- session-persistence-jsonl: list omits unreadable headers and rejects duplicates
- session-persistence-jsonl: stable-read retry
- session-persistence-jsonl: cold log memo (2 entries, revision-guarded)
- session-persistence-jsonl: read-only historical preparation without publication
- session-persistence-jsonl: child catalog fact collection with stat witnesses and warnings
- session-persistence-jsonl: staged successor encode, isolated verification, digest check
- session-persistence-jsonl: exclusive publication and race-winner acceptance
- session-persistence-jsonl: source-drift refusal on write open, single retry on read open
- session-persistence-jsonl: unsupported-migration error names the unchanged source
- session-format: safe-integer and count guards, lossless JSON snapshot
- session-format: `sessionFormatLogFilename` / `parseSessionFormatLogFilename`
- session-format: adjacent migration chain compiler with gap and duplicate checks
- session-format: catalog `readHeader` classification (`current`, `migration-required`, `unsupported`, `malformed`)
- session-format: `createRestore` with `recovery` and `validation` policies
- session-format: stage failure wrapping as unsupported migration
- session-format-catalog: static v0..v4 catalog
- session-format-catalog: child-bound catalog factory
- session-format-catalog: historical v0..v3 catalog for child evidence
- session-format-catalog: installed-current header and artifact validation
- session-format-v0-to-v1: v0/v1 physical header with `seedLength`
- session-format-v0-to-v1: packed text/reasoning/tool-call chunk rows
- session-format-v0-to-v1: range-encoded `sourceEventSeqs` decode
- session-format-v0-to-v1: recoverable row scanning rule
- session-format-v0-to-v1: `compact/*` rename
- session-format-v0-to-v1: `steering/message` conversion
- session-format-v0-to-v1: legacy `turn/start.trigger` and `turn/end` reason normalization
- session-format-v0-to-v1: legacy message wrappers and deterministic ids
- session-format-v0-to-v1: legacy retry and compaction ids
- session-format-v0-to-v1: `messagePrefix` removal
- session-format-v0-to-v1: refusal of `request/header-delta`, `mode/set`, `fallback`, unknown types
- session-format-v0-to-v1: frozen payload inventory and semantics validation
- session-format-v0-to-v1: frozen relationship validation
- session-format-v1-to-v2: v2 physical header with `isSeeded`
- session-format-v1-to-v2: v2 codec encode/decode and inherited marker derivation
- session-format-v1-to-v2: chunk embedding into `assistant/message.stream`
- session-format-v1-to-v2: `assistant/attempt` for unclaimed attempts
- session-format-v1-to-v2: dense seq remap of declared references
- session-format-v1-to-v2: inherited `session/end-seed` marker insertion
- session-format-v1-to-v2: legacy interrupted-turn closure
- session-format-v1-to-v2: legacy goal message split
- session-format-v1-to-v2: refusal of split attempts and consumed-chunk references
- session-format-v2-to-v3: preset `code` → `ptc`
- session-format-v2-to-v3: system head insertion and prompt-change replacements
- session-format-v2-to-v3: deterministic synthetic system message ids
- session-format-v2-to-v3: PTC event and plugin-source renames
- session-format-v2-to-v3: `startSeq/endSeq` and empty-optional canonicalization
- session-format-v2-to-v3: source audit of types, content kinds, source kinds
- session-format-v2-to-v3: v3 codec admission and recoverable validation
- session-format-v2-to-v3: v3 artifact restoration with protected system head
- session-format-v3-to-v4: tool-result lift to tool-role message
- session-format-v3-to-v4: plugin source to producer kind mapping
- session-format-v3-to-v4: unknown content tag and ignorable event namespacing
- session-format-v3-to-v4: interrupted-turn insertion with reference remap
- session-format-v3-to-v4: parent catalog completion from child evidence
- session-format-v3-to-v4: delivery generation guards
- session-format-v3-to-v4: v4 codec with row admission
- session-format-v3-to-v4: retired-syntax refusal
- session-format-v3-to-v4: developer-message and `deferLoading` validation
- session-format-v3-to-v4: fork-result identity validation
- session-format-v3-to-v4: native lifecycle relationships
- session-format-v3-to-v4: native catalog fact validation including version 3 names
- session-projection: unit registration with shared keys and reference counts
- session-projection: retained handle `stateOf` / `readerFor` after release
- session-projection: eager drive with reference gates
- session-projection: `onChanged` and `onEventChanged` feeds
- session-projection: `snapshot` with key selection and `asOfSeq`
- session-projection: `summaryKeys` stable set
- session-projection: `checkpoint` with detached values and released units
- session-projection: `restoreFloor`, `restore`, `viewCheckpoint`, `hydrate`
- session-projection-cache: domain spec version 7 with compatible predecessors
- session-projection-cache: mandatory writes at create, `turn/end`, dispose
- session-projection-cache: count and interval throttles
- session-projection-cache: log flush before cache write
- session-projection-cache: identity matching for fold and listing
- session-projection-cache: `cachedSnapshot`, `cachedPredecessorTitle`, `hydratePrepared`, `coldSnapshot`
- session-title: `session/title` event and `title` projection
- session-title: `titleInput` host projection
- session-title: title normalization and UTF-8 truncation
- session-title: deterministic fallback title
- session-title: single provider registration and disposal
- session-title: automatic scheduling rules (`first-prompt`, `all-prompts`)
- session-title: pending start on request header or main request
- session-title: supersession and cancellation
- session-title: provider result validation
- session-title: `rename` pin and `refresh` unpin
- session-title-llm: bounded request execution with deadline
- session-title-llm: `session/title-llm-request` logging before dispatch
- session-title-llm: route resolution (explicit pair or logged route)
- session-title-first-prompt-llm: system prompt and framed input
- session-title-first-prompt-llm: output line extraction and finish checks
- session-stats: `sessionStats` fold of counts and wall times
- session-stats: summary exclusion
- session-turn-outline: `turnOutline` fold with prompt and response previews
- session-turn-outline: preview clipping rules
- session-telemetry: backend contract and sharing status
- session-telemetry: live capture with adoption and handoff cursor
- session-telemetry: on-demand capture through an inclusive seq
- session-telemetry: `session-telemetry/record` redaction waterfall, fail-closed
- session-telemetry: ops records `agent-error` and `shutdown`
- session-telemetry-otel: `FEEDBACK_ONLY` capture on feedback events
- session-telemetry-otel: `DISABLED` mode warning
- session-telemetry-otel: config validation and shutdown deadline
- session-checkpoint-policy: flush before model stream
- session-checkpoint-policy: flush before top-level tool body with abort result
- session-checkpoint-policy: flush before each step
- session-log-deepseek: acceptance watermark fold
- session-log-deepseek: byte-bounded incremental `dsh_session_log` field
- session-log-deepseek: acceptance event on success
- session-log-deepseek: upload exclusions
- session-log-deepseek: blocked-event warning once per seq
- working-directory: `workingDirectory` projection and `get`
- working-directory: `ensure` validation and recovery to the original project
- working-directory: `set` with relative resolution and canonicalization
- working-directory: change event plus injected notice
- working-directory: required system-prompt context entry
- working-directory: `working-directory/access` waterfall
- working-directory: per-session serialization and disposal abort
- tool-working-directory: `working_directory` tool schema, description, and result
- tool-working-directory: empty `cd` and missing-agent errors
- message-quotes: blockquote range recognition and decoding (client)
- message-quotes: quote selection action and rendering (client)
- session-query: live-preferred corpus listing and ordering
- session-query: cold read with in-memory interrupted-turn closers
- session-query: header compatibility check
- session-query: `readSession`, `readSurface`, `listEvents`, `readEvent` window
- session-query: session and event filters with validation
- session-query: literal text filter compilation
- session-query: semantic text extraction
- session-query: lineage trace with cycle detection and partial ancestry
- session-query: event trace (replacement chain, sources, derived)
- session-query: title snapshots with per-session failure isolation
- session-query: observation leases with prepared-session LRU cache
- session-query: `inspectSession`
- session-query-sqlite: schema, application id, version reset
- session-query-sqlite: `openAt` modes including `never`
- session-query-sqlite: stable observation and reconciliation transaction
- session-query-sqlite: live shadowing of persisted documents
- session-query-sqlite: phrase query quoting and marker sanitization
- session-query-sqlite: ranking order for events and sessions
- session-query-sqlite: opaque cursors with stale detection
- session-query-sqlite: snippets
- session-query-sqlite: predicate and binding limits
- session-log-export: `/export` command contract
- session-log-export: ZIP route with status codes and filename
- session-log-export: canonical log serialization
- session-log-export: descendant inclusion in lineage order
- session-log-export: attachment collection and archive paths
- session-log-export: bounded streaming with backpressure and cancellation
- session-log-export: Markdown route
- session-log-export: Markdown transcript formatting
- session-log-export: browser download and copy controllers (client)
