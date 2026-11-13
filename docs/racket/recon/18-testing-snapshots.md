# Recon 18 — Test infrastructure and recorded sessions

Area: `docs/testing.md`, `snapshots/**`, `packages/test-support/*`, `vitest.snapshot.config.ts`, the scripts that drive snapshot record/replay, `python/sdk/tests`. Pinned commit `e8f7b93a3` (dsh 0.2.2-rc.2, Session writer format v4). All paths are relative to the repository root; line numbers refer to the pinned commit.

Depth. In depth: `llm-replay`, `session-snapshot`, the three snapshot drivers (`snapshots/session/headless.snapshot.ts`, `snapshots/sdk/sdk.snapshot.ts`, `snapshots/acp/acp.snapshot.ts`), the corpus layout and gates, `agent-loop-testkit`, `tool-testkit`, `loader-smoke`, `llm-mock-server`. Catalog depth: `remote-mock`, `client-runtime` (browser test benches, see recon 15), the Web browser lane (`apps/web/tests/scaffold.ts`), `python/sdk/tests`, `scripts/snapshots/python-sdk-single-exe`. Session format details (headers, event payloads, migrations) belong to recon 07; LLM chunk and adapter contracts to recon 06; profile boot to recon 03. This note repeats only what a test harness needs.

The single most important fact: **replay does not use a base URL, an HTTP mock, or request matching.** A replay patch disables the real provider plugin and inserts the in-process plugin `@deepseek-ai/dsh-llm-replay`, which registers an `LlmAdapter` (or a catch-all `llm/stream` waterfall listener) that plays recorded `StreamChunk` sequences back **by position** per live session. The recording is the committed Session JSONL itself: the same file supplies the user input, the model script, and the expected persisted log.

## Scope

| Directory | npm name | Role | Source lines (no tests) |
|---|---|---|---|
| `packages/test-support/llm-replay` | `@deepseek-ai/dsh-llm-replay` | Function plugin: derive a per-session model script from recorded Session JSONL and replay it through `ctx.llm` | 1,211 |
| `packages/test-support/session-snapshot` | `@deepseek-ai/dsh-session-snapshot` | Manifest parser, fixture filename grammar, identity redaction, normalizers, workspace capture, ACP launcher + scenario harness + suite factory | 4,796 (`suite.ts` 1,764; `harness.ts` 846; `normalize.ts` 665; `launcher.ts` 465; `manifest.ts` 432; `session-files.ts` 253; `identity.ts` 135; `workspace.ts` 116; `index.ts` 120) |
| `packages/test-support/loader-smoke` | `@deepseek-ai/dsh-loader-smoke` | Dual-mode (`src` via tsx / `lib` via plain Node) subprocess launcher `runLoaderSmoke`, and in-process `runFixtureTurn` | 375 |
| `packages/test-support/agent-loop-testkit` | `@deepseek-ai/dsh-agent-loop-testkit` | Mount the AgentLoop prerequisite services; production loop driver; Inbox/Model/WorkingDirectory stubs | 211 |
| `packages/test-support/tool-testkit` | `@deepseek-ai/dsh-tool-testkit` | Content-tool fixture definition; run one tool call through the pipeline or the selected executor | 92 |
| `packages/test-support/llm-mock-server` | `@deepseek-ai/dsh-llm-mock-server` | Scriptable Messages-protocol HTTP/SSE fault server plus CLI (`dsh-llm-mock-server`) for recovery tests | 1,018 |
| `packages/test-support/remote-mock` | `@deepseek-ai/dsh-remote-mock` | Endpoint-named mock for Typert Remote traffic (browser client tests without a Host) | ~930 |
| `packages/test-support/client-runtime` | `@deepseek-ai/dsh-client-test-runtime` | jsdom slot test bench and whole-client test fixture | ~3,100 |
| `snapshots/session/` | — | 190 headless scenarios + driver `headless.snapshot.ts` (1,646 lines) + shared `loopback-fixture-server.mjs` | corpus |
| `snapshots/sdk/` | — | 40 SDK scenarios + driver `sdk.snapshot.ts` (1,779 lines) + `legacy-context.patch.yml` | corpus |
| `snapshots/acp/` | — | 9 ACP scenarios + driver `acp.snapshot.ts` (92 lines) | corpus |
| `snapshots/web/` | — | 74 Web scenarios (46 own a session, 28 borrow one); drivers live in `apps/web/tests/*.e2e.ts` and `*.snapshot.ts` | corpus |
| `scripts/session-snapshot-corpus.corpus.ts`, `scripts/session-snapshot-corpus-policy.ts` | — | Repository-wide corpus ownership, storage and generation gates | 330 |
| `scripts/snapshot-spill-locators.ts`, `scripts/snapshot-shell-path.ts`, `scripts/snapshot-workspace-parent.ts` | — | Fixture plugins/helpers used by scenario patches | 142 |
| `scripts/session-fixture-layout.ts`, `scripts/migrate-packed-session-fixtures.ts`, `scripts/run-web-snapshots.ts` | — | Fixture projection helper, temporary migrator, Web lane runner | — |
| `scripts/snapshots/python-sdk-single-exe/` | — | 8 installed-runtime Python snapshots (physical JSONL, `result.json`, `requests.json`, `model-visible.json`) | corpus |
| `python/sdk/tests/` | — | 26 `test_*.py` modules plus two manual smokes and helpers (about 6,600 lines including `expected/*.json`) for the Python SDK; mostly fake-peer JSON-RPC tests | — |
| `vitest.snapshot.config.ts`, `vitest.web.config.ts`, `vitest.e2e.config.ts`, `vitest.expected.config.ts` | — | Tier configurations | — |

## Services

No test-support package defines a new `ctx.<key>`. They consume or patch existing services:

- `llm-replay` (`inject = ['llm']`): calls `ctx.llm.registerAdapter(providerIds, adapter)` when `providers` is non-empty, else `ctx.on('llm/stream', (options, _next) => replay(options))` (`llm-replay/src/index.ts:1087-1090`). Optional read of `ctx.get('deepseekLlmApiExtensions')`: for `options.provider === 'deepseek-official'` and an entry that counts as provider-accepted, it calls `extensions.prepare({ body: { messages: [] }, signal, sessionId?, purpose? })` then `prepared.accept()` before yielding chunks, to reproduce post-2xx side effects (`index.ts:1070-1083`). `installLlmReplay(ctx, config)` returns `ReplayHandle { dispose(), assertConsumed() }`; the plugin `apply` discards the handle (only the Web scaffold keeps it).
- `agent-loop-testkit.provideWorkingDirectoryFixture(ctx, defaultDirectory = process.cwd())`: `ctx.provide('workingDirectory', { defaultDirectory, get(session) => session.header.cwd ?? defaultDirectory, ensure(agent) => Promise<string> })` with no filesystem checks.
- `scripts/snapshot-spill-locators.ts` (`inject = ['spillStore', 'fs']`): wraps `spillStore.saveText`, `fs.resolve`, `fs.processPathFromHostPath` inside `ctx.effect` so saved spill locators are reported under a fixed logical root and mapped back to the real files; a locator under the logical root that this run did not save throws `snapshot spill locator was not saved by this run`.
- `scripts/snapshot-shell-path.ts` (`inject = ['shell']`): wraps `shell.execute` so one exact recorded command has `recordedPath` replaced by the shell-quoted `livePath`.
- `loader-smoke.runFixtureTurn(ctx, { task, onEvent? })`: requires `ctx.get('agents')` with exactly one non-subagent agent, uses `agent.followup`, `agent.whenIdle()`, `ctx.sessions.flush(session)`.

Lifecycle rule for all of them: every patch is an effect; disposing the owning fiber restores the original method or removes the adapter/listener (pinned by `removes the waterfall listener when the owning fiber is disposed (HMR safety)` in `llm-replay.spec.ts`).

## Events

The test infrastructure defines no events. It consumes:

| Event | Mode | Consumer | Use |
|---|---|---|---|
| `llm/stream` | waterfall | `llm-replay` catch-all mode; `snapshots/sdk/manual-compact/capture-requests.mjs` | Replay short-circuits (never calls `next`). The capture fixture appends `{provider, model, purpose, maxTokens, reasoningEffort, messages, tools}` as one JSON line per call to a file, then `yield* next()`. |
| `session/event` | emit `(session, event)` | `runFixtureTurn`; scenario fixtures such as `settlement-order.mjs` | Observe canonical events of one session. `runFixtureTurn` starts forwarding only after the `agent/inbox/spliced` event that inserted its own message id. |
| `agent/created` | emit | `runFixtureTurn` | Wait for the first configured root agent to publish. |
| `agent/status` | emit `({agent, status})` | agent-loop specs (`waitForIdle`) | Wait for `status === 'idle'`. |
| `agent/pre-step`, `tools/execute` | waterfall | scenario fixture plugins | Hold a child step or observe a tool call to make ordering deterministic. |

`llm-mock-server` has its own (non-Cordis) telemetry callback `onEvent(MockLlmServerEvent)`: `{type:'request', attempt, scriptBehavior, behavior, path}` and `{type:'result', attempt, scriptBehavior, behavior, outcome, chunksSent}`; the CLI prints each as a JSON line on stdout.

## Tools

None are shipped to product users. Test-only tool surfaces:

- `tool-testkit.defineContentToolFixture(options)` builds a `ToolDefinition` whose canonical value is its content-block array: `output.schema = { type: 'array', items: { type: 'json' } }`, `render = (_args, value) => value`. Options are `DefineToolOptions` minus `output`/`execute`, plus `execute(args, exec): Promise<ContentBlock[]>`.
- Scenario fixture plugins register throwaway tools that appear in recorded request headers: `snapshot_ping`, `snapshot_initial`, `snapshot_later` (dynamic and deferred tool scenarios), `mystery` (Web auto-review), `fixture-write` (SDK approval), `mcp__fixture__inspect`, `mcp__demo__ping`, `mcp__protected__ping` (fixture MCP servers). Their schemas live in the scenario's `tool-schemas.expected.json`.
- `llm-mock-server` behavior `tool_call_success` emits a tool call named `toolName` (default `mock_tool`) with id `mock-call-1` and raw arguments `toolArguments` (default `{"value":"mock"}`).

## Configuration

### `@deepseek-ai/dsh-llm-replay` — function plugin, `name = 'llm-replay'`, `inject = ['llm']`

| Field | Type | Default | Meaning |
|---|---|---|---|
| `file` | string | `$DSH_SNAPSHOT_FILE` | Primary (parent) fixture path. Missing/empty → throw `llm-replay: a fixture path is required (Config.file or $DSH_SNAPSHOT_FILE)`. |
| `overrideFile` | string | `$DSH_SNAPSHOT_OVERRIDE` | Sidecar replacing or patching the derived primary script. Used only if the file exists. |
| `childFiles` | string[] | `$DSH_SNAPSHOT_CHILD_FILES` split on the platform path delimiter | Recorded child-session logs. A listed file that does not exist throws `llm-replay: child fixture not found: <path> — re-record the scenario`. |
| `providers` | `ReplayProviderConfig[]` | none | Non-empty → routed adapter for these provider ids; empty/absent → catch-all waterfall. |
| `paceMs` | non-negative integer | 0 | Wait before each chunk; abort during the wait rejects with `aborted`. Other values throw `llm-replay: paceMs must be a non-negative integer, got <v>`. |

`ReplayProviderConfig`: `id` (string), `name?` (default `id`), `models?: ReplayModelConfig[]`, `retryPolicy?: RetryPolicyConfig` (resolved with `resolveRetryPolicy`). `ReplayModelConfig`: `id`, `name?`, `description?`, `contextWindow?` (→ `context.contextWindow`), `inputModalities?` (array of `"text"`/`"image"` only), `defaultMaxTokens?`, `imageRequestTokens?` (positive safe integer; requires `image` modality; prices every retained request image at this many visual tokens plus handle text, offloaded images at 0), `reasoningEfforts?: string[]` (least to greatest), `defaultReasoningEffort?`, `systemPromptUpdate?` (only `"in-history"`), `toolUpdate?` (`"in-history"` or `"addition-only"`), `badge?` (`{text: string | {en: …, …}, tone: 'neutral'|'info'|'success'|'warning'}`). Validation errors are thrown at `apply` (`index.ts:1142-1192`). Adapter answers: `providerInfo → {id, name}`, `listModels → [{provider, id, name, description?, inputModalities?, badge?}]`, `resolveModel → {provider, id, name, description?, inputModalities?, context?, defaultMaxTokens?, systemPromptUpdate?, toolUpdate?, reasoning?: {efforts: [{id, name: id}], defaultEffort?}}`; an unlisted model id resolves to `{provider, id: model, name: model}`.

### Fixture plugins used by scenario patches

- `scripts/snapshot-spill-locators.ts` — `name = 'snapshot-spill-locators'`, `inject = ['spillStore', 'fs']`, `Config { root: string; locatorRoot: string }`.
- `scripts/snapshot-shell-path.ts` — `name = 'snapshot-shell-path'`, `inject = ['shell']`, `Config { command: string; recordedPath: string; livePath: string }`.
- `snapshots/sdk/manual-compact/capture-requests.mjs` — function plugin, `config.path` (output JSONL).

### `llm-mock-server` — `startMockLlmServer(options)` (library; no plugin)

`host` (`127.0.0.1`), `port` (0 = OS-assigned; CLI default 8000), `apiKey?` (exact `x-api-key`; absent accepts any), `sequence` (required non-empty list of behaviors), `repeatLast` (false), `randomSeed?` (uint32; generated when absent), `randomWeights?`, `successText` (`mock response recovered`), `partialText` (`discarded partial response`), `reasoningText` (`mock reasoning`), `chunkSize` (8 code points), `chunkDelayMs` (25), `disconnectDelayMs` (10), `retryAfterMs` (1000), `requestId?`, `toolName` (`mock_tool`), `toolArguments` (`{"value":"mock"}`), `onEvent?`. Returns `{ baseURL, port, randomSeed, requests, close() }`.

### `loader-smoke` — `runLoaderSmoke(options)`

`label`, `binScript` (source bin), `libBinScript?`, `configPath`, `binArgs?` (default `[configPath]`), `tsconfigPath`, `mode?` (`src`/`lib`, default `$DSH_EXAMPLE_MODE`, default `src`), `sourceImport?: 'tsx/esm'`, `env?`, `processTimeoutMs?` (30,000), `prepare?(cwd)`, `inspect?(cwd)`, `expectedExitCode?` (0), and either `tempDirPrefix` (+ optional `tempDirParent`) or a caller-owned `cwd`. Sets `DSH_HOME=<cwd>/.dsh`, `DSH_AGENTS_HOME=<cwd>/.agents`, clears proxy variables, closes stdin immediately (`input: ''`), kills with SIGKILL at the deadline. `LOADER_SMOKE_TEST_TIMEOUT_MS = 45_000`.

### Vitest snapshot lane (`vitest.snapshot.config.ts`)

Includes `scripts/session-snapshot-corpus.corpus.ts`, `snapshots/**/*.snapshot.ts`, and `apps/web/tests/**/*.snapshot.ts` only when `DSH_EXAMPLE_MODE=lib`. `testTimeout` 120 s, `hookTimeout` 30 s. `maxConcurrency = DSH_SNAPSHOT_MAX_CONCURRENCY` (default `min(5, cpus)`); `maxWorkers = DSH_SNAPSHOT_MAX_WORKERS` when set; file parallelism only in replay mode. `.env` is loaded only when `DSH_SNAPSHOT=record`. Setup file `scripts/test-proxy-environment.ts` deletes proxy variables.

## Formats

### 1. Scenario directory layout

One directory per scenario: `snapshots/<tree>/<scenario>/`. Trees: `session` (profile `headless`), `sdk` (profiles `sdk`, `sdk-minimal`), `acp`, `web`. Files (present only when the manifest or role requires them):

| File | Format | Meaning |
|---|---|---|
| `snapshot.yml` | YAML (JSON schema, closed key set) | Manifest; required in every scenario directory. |
| `session[.vN].jsonl` | projected Session JSONL | Parent role. v0 omits `.v0`; `N ≥ 1` uses lowercase `.vN`. Filename version must equal the header `version`. |
| `session.<k>[.vN].jsonl` | projected Session JSONL | Child role `k ≥ 1`, contiguous. |
| `writer.expected.jsonl`, `writer.<k>.expected.jsonl` | projected Session JSONL | Only for scenarios with `sessionFormat`: the normalized native-writer output oracle; never replay input. |
| `system-prompt.expected.md`, `system-prompt.<k>.expected.md` | Markdown | Readable prompt sidecar (class pin / child pin). May be a symlink to another tree's owner when the manifest names that source. |
| `tool-schemas.expected.json`, `tool-schemas.<k>.expected.json` | JSON `{ "initial": [ToolSchema…], "changes": [[ToolSchema…], …] }` | Tool catalogs for the initial request header and each later full header. |
| `replay.override.json` | JSON | Present exactly when `replay.override: true`. |
| `cordis.yml` | Cordis patch list | Live-recording patch; its presence makes the scenario the owner of its `composition`. |
| `cordis.snapshot.yml` | Cordis patch list | Replay sibling of `cordis.yml` (same directory, same basename rule). |
| `model.cordis.yml` | Cordis patch list | Only in `session/text-turn`: sets `agent-default-model` from `DSH_SNAPSHOT_PROVIDER`/`DSH_SNAPSHOT_MODEL`. |
| `runtime.cordis.yml` | Cordis patch list | Optional scenario-local execution-fixture patch, applied last (headless, SDK). |
| `workspace/` | directory | Seed copied into the generated cwd before launch. |
| `workspace.expected/` | directory | Complete expected final workspace; present exactly when `workspace.final: true`. A root `.empty` marker means "empty workspace"; a nested `<dir>/.empty` means "empty directory". |
| `input.json` | JSON `InputScript` | ACP only (the gate rejects it elsewhere). |
| `stdout.expected.jsonl` (+ `stdout.expected.windows.jsonl`) | NDJSON of normalized JSON-RPC frames | ACP only. |
| `notifications.expected.jsonl` (`notifications.current.expected.jsonl` when retained), `result.expected.json` | NDJSON / one JSON line | SDK wire projections, only for scenarios that commit them (14 of 40). |
| `*.expected.md`, `protocol.expected.json`, `feedback-release.expected.json` | ARIA snapshot text / JSON | Web UI goldens. |
| `*.mjs`, `*.ts`, `*.d.mts`, `profile.patch.yml`, `capture.cordis.yml`, `child.cordis.yml`, `replay.cordis.yml`, `paging.patch.yml` | code / patches | Scenario-local fixture plugins and extra patches referenced from the patches above. |

### 2. `snapshot.yml` (closed schema, `session-snapshot/src/manifest.ts:201-432`)

Parsed with `yaml.JSON_SCHEMA` (no JS tags). Unknown keys at any level throw `… has unknown field(s): …`. Names match `^[a-z0-9]+(?:-[a-z0-9]+)*$`.

```yaml
version: 1                      # required, must equal 1
scenario: <name>                # must equal the directory name (corpus gate)
profile: headless | sdk | sdk-minimal | acp | web
composition: <name>             # composition id; the scenario holding cordis.yml owns its patches
recording: live | authored      # live = re-recordable against the real API; authored = never re-recorded
header:
  class: <name>                 # header class; required key of `header`
  pin: true                     # exactly one pin per <composition>/<class>
  systemPromptSource: <name | tree/name>   # pin reuses another pin's prompt sidecar
  toolSchemasSource: <name | tree/name>
  childSystemPrompts: [1, …]    # child fixture indexes with their own prompt sidecar
  childToolSchemas: [1, …]
  changes: <n ≥ 0>              # request/header events with reason "change" after the first
  promptChanges: <n ≥ 0>        # later system/message events after the first
replay: { override: true }
platform: posix | pwsh          # skip on Windows / skip without a usable pwsh
permission: read-only | workspace-write | danger-full-access   # exported as DSH_PERMISSION_MODE
environment: { UPPER_NAME: "string", … }                       # extra subprocess env
workspace: { setup: <name>, final: true, parent: outside-temp } # at least one key
input:
  task: "<text>"                # one-shot task only when no user event was accepted or no fixture exists yet
  attachments: [{ id: "sha256:…", mediaType: "image/png", data: "<base64>" }]
session: { source: "../other/session.v4.jsonl" }   # borrower: read-only reference to an owner's selected parent
sessionFormat: { version: <n ≥ 0>, coverage: [multi-hop | packed-row | retry-failure | shipped-profile | adjacent-migration | retired-tools] }
```

`sessionFormat` and `session` are mutually exclusive. `writesCurrentSessionFixtures(manifest, mode)` is `mode !== 'replay' && session === undefined && sessionFormat === undefined`.

### 3. Committed Session fixture ("projected" JSONL)

Line 1 is the Session header exactly as persisted except for tokens: `{"type":"session","version":4,"id":"{{session:1}}","createdAt":<real ms>,"cwd":"{{cwd}}","isSeeded":false,"delegationDepth":0}` (children add `parentSession`, `origin`, seed fields; see recon 07). Every later line is one event **without the top-level `seq` and `time` envelope** (historical packed rows omit `seq0`/`time0`): `{"type":…,"data":…,"surfaceOp"?:…,"sourceEventSeqs"?:[…]}`. Rules:

- Event order is the log order. Replay and comparison synthesize `seq = dense index from 0` and `time = 0` (`llm-replay/src/index.ts:253-276`). A file must be all-projected or all-complete; mixing throws.
- `sourceEventSeqs` is stored as an expanded number array (historical generations may store `[start, end]` ranges; `decodeSeqRanges` expands them).
- Embedded clocks are kept as recorded in storage (`createdAt`, `assistant/message.data.stream[*].time|time0|dt`, `job/*.startedAt|finishedAt`, …) and zeroed only at comparison time.
- `system/message` text is the token `{{system}}`; `request/header.data.header.tools` is the token `{{tools}}` (or an array of tool **names** when the log contains any `developer/message`, so addition references stay checkable).
- Identity tokens: `{{session:N}}`, `{{message:N}}`, `{{approval:N}}`, `{{workflow:N}}`, `{{command:N}}`, `{{rpc:N}}`, `{{retry:N}}`, `{{id:N}}`, each numbered by first appearance across the parent-first set of logs of one scenario. Legacy tokens `{{sessionId}}`, `{{messageId}}` occur in ACP stdout goldens and old fixtures.
- Other tokens: `{{cwd}}`, `{{spillLocator:<filename>}}`, `{{eventTime}}`, `{{eventOmittedBytes}}`, `{{usedTokens}}` (ACP `usage_update.used`), `{{sourceSessionFormatVersion}}` (comparison only), and Web-only `{{harnessHome}}`, `{{anonymousUserId}}`, `{{sourceRoot}}`, `{{webUrl}}`, `{{webSearchEndpoint}}`.

Event sequence of a minimal current fixture (`snapshots/session/tool-call-turn/session.v4.jsonl`): `session` header; `permission/preset`; `sandbox/mode`; `approval/policy`; `agent/inbox/spliced` (insert user message); `turn/start`; `agent/inbox/spliced` (`removedCount: 1`); `step/start`; `system/message` (`surfaceOp: append`); `user/message` (source `user`); `user/message` (source `runtime-context`, text wrapped in `<system-reminder>`); `request/header` (`reason: initial`); `request/context`; `session/title` (source `fallback`); `assistant/message` (message + `usage` + compact `stream`); `tool/call`; `job/registered`; `job/settled`; `tool/result` (`sourceEventSeqs`, `surfaceOp: append`, `meta`); `step/end`; `step/start`; `assistant/message`; `step/end`; `turn/end` (`reason: {kind: completed}`).

The model output of one call is embedded in `assistant/message.data.stream` (or `assistant/attempt.data.stream` for a failed/retried attempt) as `AssistantStreamRecord[]`: `{type:'chunk', time, chunk: StreamChunk}` and packed runs `{type:'text-chunks'|'reasoning-chunks', time0, index, dt[], texts[]}`, `{type:'tool-call-chunks', time0, index, dt[], id, name?, args[]}`. `expandAssistantStream` (`packages/llm/llm/src/assistant-stream.ts:202-232`) turns each run member into a `text-delta` / `reasoning-delta` / `tool-call-delta` chunk (`time = time0 + Σ dt`). Historical v0/v1 fixtures instead carry top-level `assistant/chunk` events and packed rows `text-chunks`/`reasoning-chunks`/`tool-call-chunks`; the format catalog migrates them in memory before derivation.

`StreamChunk` (`packages/llm/llm/src/types.ts:496-508`): `block-start {index, blockType}`, `text-delta {index, text}`, `reasoning-delta {index, text}`, `tool-call-delta {index, id, name?, argumentsDelta}`, `block-end {index, block}`, `usage {usage: {inputTokens, outputTokens, totalTokens?, cacheReadTokens?, cacheWriteTokens?, reasoningTokens?}}`, `finish {reason: {kind: …}, replayState?}`. Usage precedes finish; nothing follows finish.

### 4. `replay.override.json` (`ReplayOverrideDoc`, `llm-replay/src/index.ts:516-741`)

Either a bare array of entries (whole-script replacement for the primary session) or `{ "patches": [{ "at": <0-based call index>, "entry": <entry> }] }` (keep the derived script; `at == derived length` appends; `at > length` or a duplicate `at` throws). Entry forms, each with an exact key set:

- `{ "kind": "chunks", "chunks": [StreamChunk…] }`
- `{ "kind": "throw", "chunks": [StreamChunk…], "message": "<non-empty>", "code": "<non-empty>", "accepted"?: boolean }` — yields the prefix chunks, then throws `LlmError.fromFailure({message, code})`. Provider-accepted defaults to `chunks.length > 0`.
- `{ "kind": "hang", "readyFile"?: "<path>" }` — yields `block-start {index 0, text}` and `text-delta "partial"`, writes an empty `readyFile` (relative to process cwd), then waits for abort and rejects `Error('aborted')`.

Chunk `type` must be one of the seven known types. Placeholders inside any string of an entry: `{{fromRequest:<regex>}}` (resolved against the live request, see Algorithms) and `{{session:N}}` (the live id bound to recorded script N).

### 5. Sidecars

- `system-prompt.expected.md`: the normalized initial prompt, with a trailing newline added if missing; each later prompt appended after the marker line `\n<!-- system/message change <n> -->\n\n` (`suite.ts:551-584`).
- `tool-schemas.expected.json`: `JSON.stringify({ initial, changes }, null, 2) + "\n"`; each element is the complete `ToolSchema` `{name, description, parameters, deferLoading?}` as logged in the request header.

### 6. ACP `input.json` (`InputScript`, `harness.ts:88-133`)

`{ "steps": [InputStep…], "permissionAnswers"?: [{ "kind": "allow_once" | "allow_always" | "reject_once" | "reject_always" }] }`. Steps: `initialize`; `newSession`; `newSessionExpectError {additionalDirectories?}`; `prompt {text}`; `promptContent {content}`; `promptAndWaitForAgentMessage {text, waitForText}`; `promptExpectError {text}`; `promptAndCancel {text, waitForFile?: {path, timeoutMs?}}`; `waitForFile {path, timeoutMs?}`; `waitForTurnStart {minimumTurn?, timeoutMs?}`; `waitForTurnEnd {timeoutMs?}`; `waitForSubagentTurnEnd {child?, minimumTurn?, timeoutMs?}`; `waitForGoalPhase {phase, timeoutMs?}`; `waitForInboxMessage {text, timeoutMs?}`; `waitForTitleAfterTurnEnd {timeoutMs?}`; `waitForEventAfterTurnEnd {type, timeoutMs?}`; `cancel {waitForFile?}`. Default wait 10 s, poll 10 ms. Permission answers are consumed FIFO and select by option **kind**; a request beyond the queue is answered `{outcome: 'cancelled'}`; a scripted kind that was not offered fails the run after the step settles.

### 7. Environment variables

| Name | Set by | Read by | Meaning |
|---|---|---|---|
| `DSH_SNAPSHOT` | scripts (`record`, `refresh`), drivers (`replay`/`record` for the child) | drivers, patches (`!!js`), profile boot | Mode. Unset or empty = `replay` for drivers. Patches use "defined" to choose `compression: none`, permission defaults (`danger-full-access` + approval `never` when defined and `DSH_PERMISSION_MODE` is unset). |
| `DSH_SNAPSHOT_FILE` | drivers | `llm-replay` | Primary fixture path. |
| `DSH_SNAPSHOT_CHILD_FILES` | drivers | `llm-replay` | Child fixture paths joined by the platform path delimiter. |
| `DSH_SNAPSHOT_OVERRIDE` | drivers | `llm-replay` | Override sidecar path. |
| `DSH_SNAPSHOT_PROVIDER`, `DSH_SNAPSHOT_MODEL` | headless and SDK drivers (from the first `request/header.data.header.config`) | `model.cordis.yml` | Replay route selection. |
| `DSH_SNAPSHOT_SESSIONS_ROOT` | ACP harness | ACP patch (`session-persistence-jsonl.root`) | Private sessions root. |
| `DSH_SNAPSHOT_SPILL_ROOT`, `DSH_SNAPSHOT_SPILL_LOCATOR_ROOT` | drivers | spill patches | Real temp spill root and the fixed logical root `/tmp/dsh-acp-snap-<first 9 hex of sha256(scenario dir name)>` (`/t/…` on Windows). |
| `DSH_PERMISSION_MODE` | manifest `permission` | sandbox-policy and approval patches | Permission preset. |
| `DSH_HOME`, `DSH_AGENTS_HOME` | launchers | profile boot | `<cwd>/.dsh`, `<cwd>/.agents`. |
| `DSH_TELEMETRY_DISABLED=1` | drivers | telemetry | — |
| `DEEPSEEK_API_KEY=snapshot-replay-key` | `REPLAY_CREDENTIAL_ENV` in replay/refresh | product (keeps `web_search` offered) | Placeholder credential. Record mode reads the real key from env or root `.env`. |
| `DSH_EXAMPLE_MODE` | CI (`lib`) | `resolveExampleMode` | `src` (tsx) or `lib` (built). |
| `DSH_SNAPSHOT_MAX_CONCURRENCY`, `DSH_SNAPSHOT_MAX_WORKERS`, `DSH_WEB_SNAPSHOT_WORKERS` | CI/dev | vitest configs, `run-web-snapshots.ts` | Parallelism budgets. |
| `NODE_OPTIONS += --disable-warning=ExperimentalWarning` | drivers | Node | Keeps stderr clean for exact comparison. |
| scenario-specific (`DSH_SNAPSHOT_PROVIDER_CWD`, `DSH_MCP_DEMO_URL`, `DSH_MCP_RESOURCES_FIXTURE`, `DSH_SNAPSHOT_FEEDBACK`, `DSH_TEST_CHILD_PATCH(ES)`, `DSH_TEST_CHILD_HOME`, `DSH_SYSTEM_PROMPT`, …) | manifest `environment` or driver tables | fixture plugins | Per-scenario fixtures. |

### 8. Commands and CLI

- `pnpm run test:snapshot` = `vitest run --config vitest.snapshot.config.ts`; `test:snapshot:record` = `DSH_SNAPSHOT=record … --update`; `test:snapshot:refresh` = `DSH_SNAPSHOT=refresh …`; `test:web:ci` = `tsx scripts/run-web-snapshots.ts`; CI gate `ci-snapshot` = build then snapshot.
- Headless launch: `node --import tsx/esm apps/cli/src/bin.ts --profile headless --patch .snapshot-patches/0-cordis.yml --patch .snapshot-patches/1-cordis.snapshot.yml [--patch …] "<task>"` with cwd = generated workspace. Additional flags used: `--session-id <id>` (resume), `--json` (stdout NDJSON: first `{"type":"session","sessionId","cwd"}`, last `{"type":"final","sessionId","reason","text"}`).
- ACP launch: `… bin.ts --profile acp --patch <cwd>/.dsh-profile-patches/launch-XXXXXX/0-cordis.yml --patch …/1-cordis.snapshot.yml`.
- SDK launch: through `new DeepSeekHarness({ profile, patches, dshHome, processCwd, env, cwd, provider, model, … })` (recon 13).
- `dsh-llm-mock-server --sequence <a,b,…> [--host] [--port (8000)] [--api-key] [--listen-delay-ms (750 with connection_refused)] [--repeat-last] [--seed] [--random-weights a=n,…] [--success-text] [--partial-text] [--reasoning-text] [--chunk-size] [--chunk-delay-ms] [--disconnect-delay-ms] [--retry-after-ms] [--request-id] [--tool-name] [--tool-arguments] [--help]`. `connection_refused` is allowed only first and needs a nonzero port. Stdout: optional `{"type":"unavailable","baseURL","listenDelayMs"}`, then `{"type":"ready","baseURL":"http://host:port/v1","randomSeed"}`, then telemetry lines. SIGINT exits 130, SIGTERM 143.

### 9. `llm-mock-server` wire

Only `POST` on a path ending `/v1/messages` consumes a behavior (other method → 405 `allow: POST`; other path → 404; wrong `x-api-key` → 401 `{error:{message:'invalid mock API key',code:'invalid_api_key'}}`; bad JSON → 400 `invalid_json`). SSE frames are `event: <type>\ndata: <json>\n\n` in the Anthropic Messages shape: `message_start` (`id: mock-message`, `model: mock-model`, `usage: {input_tokens: 3, output_tokens: 0}`), `content_block_start`, `content_block_delta` (`text_delta` / `thinking_delta` / `input_json_delta`), `content_block_stop`, `message_delta` (`stop_reason`, `usage.output_tokens`), `message_stop`. Behaviors: `connection_reset` (destroy socket), `stream_disconnect` (headers then destroy after `disconnectDelayMs`), `empty` (start, `end_turn` with 0 tokens, stop), `empty_body` (200 SSE, no frames), `stream_eof` (start then end), `partial_eof`, `partial_disconnect`, `stall` (headers, never ends), `malformed_json` (`data: {not-json`), `malformed_event` (`content_block: null`), `wrong_content_type` (`application/json` with a valid stream), `rate_limit` (429 `rate_limit`, `retry-after: ceil(retryAfterMs/1000)`), `server_error` (500), `service_unavailable` (503), `auth_error` (401 `invalid_api_key`), `invalid_request` (400), `context_overflow` (400 `context_length_exceeded`, type `invalid_request_error`), `quota_exceeded` (429 `insufficient_quota`), `success`, `reasoning_success` (thinking block index 0, text index 1), `tool_call_success` (`tool_use` block, arguments split at the midpoint, `stop_reason: tool_use`, 2 output tokens), `max_tokens`, `slow_success` (`chunkDelayMs` between deltas), `random` (weighted by a seeded mulberry32 generator; default weights success 48, slow_success 10, max_tokens 2, connection_reset 5, stream_disconnect 5, partial_disconnect 10, empty 5, stall 2, rate_limit 5, server_error 4, service_unavailable 2, partial_eof 1, malformed_json 1). After the sequence: 500 `MOCK_SCRIPT_EXHAUSTED` unless `repeatLast`. HTTP errors are `{error:{message,type,code}}` with optional `x-request-id`.

## Algorithms and invariants

### A. Replay end to end (headless; `snapshots/session/headless.snapshot.ts:1343-1645`)

1. Collect every `snapshots/session/*/snapshot.yml` with `profile: headless` and a `composition`. Build `compositionOwners` (scenario that has `cordis.yml`; two owners for one composition is an error) and `headerPins` keyed `<composition>/<class>` (two pins is an error). Every scenario must have an owner and a pin, and no pin may declare `sessionFormat`.
2. Select fixtures: `sessionFixtureNames(readdir(dir))` = highest generation per role, parent first, roles contiguous (`session-files.ts:89-110`); each must pass `assertSessionFixtureVersion`.
3. Derive inputs from the selected parent fixture: **task** = first single-text-block message with `source.kind === 'user'` in an `agent/inbox/spliced.data.inserted` list, else first such `user/message`, else `manifest.input.task` (`:330-357`); **model route** = first `request/header.data.header.config.{provider, model}` (falls back to the class pin's fixture) (`:472-483`).
4. Patches, in order: `text-turn/cordis.yml` (the `default` composition's live patch, always first); `<owner>/cordis.snapshot.yml` in replay/refresh (in record: `<owner>/cordis.yml`, skipped when the owner is the default); `text-turn/model.cordis.yml` when a model is known; `<scenario>/runtime.cordis.yml` if present (`:1385-1390`). Each is rewritten by `materializeProfilePatch` (`launcher.ts:417-444`) into `<cwd>/.snapshot-patches/<i>-<basename>`: relative plugin names (`./x`, `../x`) become absolute `file:` URLs relative to the authored patch; every bare package name is symlinked into `<cwd>/.dsh/profiles/<profile>/node_modules/<pkg>` when resolvable from the patch location.
5. Workspace: `mkdtemp(<tmp>/dsh-log-snap-XXXXXX)` (or beside the temp root / under home for `workspace.parent: outside-temp`; compaction scenarios pad the prefix so `JSON.stringify(cwd)` is exactly 192 characters); copy `workspace/*` (symlinks verbatim); run the named `workspace.setup` (table at `:502-585`: `readonly-patch-directory`, `cua-script-guidance`, `dsh-doc-resources`, `windows-acl-skill`, `office-skills`, `office-retired-ptc`, `git-worktree`, `skill-root-isolation`, `delimiter-path`, `fixed-search-mtimes`); capture the initial workspace ignoring root entries `.agents`, `.dsh`, `.snapshot-patches`.
6. Launch `dsh --profile headless … "<task>"` via `runLoaderSmoke` with the environment of Formats 7. Expected exit code: 0 when the fixture's last `turn/end.reason.kind` is `completed` (or there is no fixture / no turn end with a manifest task), else 1.
7. Inside the process the replay patch disables `llm-deepseek` (and `plugin-package-inventory-deepseek`, `session-title-llm`), forces `session-persistence-jsonl` `compression: none` with `root: dshHomePath('sessions')`, replaces the sandbox runner with a pass-through (`runnerCommand: [bash, -c, 'while [ "$1" != "--" ]; do shift; done; shift; exec "$@"', passthrough-runner]`, `runnerFailureSignatures: ['passthrough-runner: profile rejected']`), and inserts `llm-replay` with a provider catalog (`deepseek-official` and `deepseek-messages`, models `deepseek-v4-flash`, `deepseek-v4-pro`). The agent loop runs unchanged.
8. Harvest: read `<cwd>/.dsh/sessions/**` recursively, keep the highest raw generation per session directory (`latestPersistedSessionPaths`), require header version = current writer. Order: parent (no `parentSession`) first; siblings of one parent by the index of their `subagent/catalog` event in the parent log; otherwise by `createdAt` (`:199-225`). (ACP/SDK harvest orders children by `createdAt` then id.)
9. Assertions (`:1600-1644`):
   - `stdout === finalTextFromSession(parent fixture) + "\n"` where final text is the concatenated text blocks of the last `assistant/message`.
   - `stderr === stderrFromSession(parent fixture)`: after the first `turn/start`, reasoning deltas are printed under a header line `dsh: reasoning:\n`; a reasoning run is closed (newline added if missing) by any text delta, tool-call delta, non-reasoning block start/end, finish, new assistant settlement, or new turn; if the last turn ended with `kind: error`, append `dsh: <code>: <message>\n` (`:384-470`).
   - persisted session count = fixture count.
   - `normalizeSessionSnapshots(actual, ctxActual, {nativeWriterOutput: true})` deep-equals the same normalization of the expected logs, record by record, per role. Expected = the selected fixtures, or the `writer*.expected.jsonl` files for `sessionFormat` scenarios (and then the replay inputs must be byte-unchanged).
   - Header/prompt verification against the class pin (section F).
   - Workspace: `workspace.final` → final capture equals `workspace.expected/`; otherwise final capture must equal the initial capture.
   - Scenario-specific world checks (MCP fixture calls, git worktree state, spill file contents, audit files).
10. Replay tests run with `it.concurrent`; record and refresh run serially; record orders pins before dependents.

### B. Script derivation (`llm-replay/src/index.ts:467-508`, `806-837`)

- `parseSessionFixture` validates the header, completes projected envelopes, and decodes/migrates every row through the build-static Session format catalog (`recovery: 'strict'`, `validation: 'current'`). Before validation: a v0 header without `delegationDepth` gets `0`; a `cwd` starting with `{{cwd}}` is replaced by `/dsh-snapshot-cwd…`; a header `tools: "{{tools}}"` is dropped; a tools array of names becomes `[{name, description: '', parameters: {}}]`. Errors are re-thrown as `session snapshot line <n>: <detail>`.
- `deriveReplayScript(events)`: walk events in order. Each `assistant/message` or `assistant/attempt` yields one entry `{kind:'chunks', chunks: expandAssistantStream(stream).map(m => m.chunk)}`; an empty stream yields nothing; a stream whose last chunk is not `finish` throws `llm-replay: model call <turn>/<step> ended without a finish chunk (a thrown stream); this scenario needs a replay.override.json sidecar`. A `compaction/summary` with `llmStreamCall === true` yields a synthesized entry from `rawOutput` (for each block: `block-start {index, blockType}`, `block-end {index, block}`; then `usage` if present; then `finish {kind: 'stop'}`); a marked summary without `rawOutput` throws. All other events are ignored. Retries therefore produce several entries with the same turn/step.
- Children: `ownEvents = events.slice(inheritedEventCount)` so a forked child never replays its parent's seeded history. Children are sorted by `createdAt`, ties by recorded id; the primary is always first (`XXX(concurrent-subagents)`: concurrent children would need an explicit first-call ordinal).
- Override resolution: array → replaces the primary script (the JSONL may then be absent; header defaults to `id ''`, `createdAt 0`); `{patches}` → applied over the derived script.

### C. Binding and playback (`index.ts:1018-1109`)

- State: `scripts` in bind order, `bound: Map<liveKey, {entries, cursor}>`, `nextScript`. `liveKey = options.sessionId ?? '\0anon\0'` (all calls without a session id share one anonymous session).
- On a call from an unseen live key: claim `scripts[nextScript++]`. If none is left, the returned stream throws `llm-replay: a model call arrived from an unrecorded session (#<n>); the scenario recorded only <m> session(s) — re-record it`.
- The cursor advances **synchronously at call time** (`index = cursor++`), before any chunk is consumed, so interleaved sessions and aborted streams keep deterministic positions. Past the end: `llm-replay: script exhausted — session requested model call #<i> but its script has only <n>; re-record the scenario`.
- Before yielding: `{{session:N}}` tokens are replaced with the live id bound to script N (unbound → throw), then `{{fromRequest:<regex>}}` placeholders are resolved: corpus = every string leaf of `options.messages` joined with `\n`; the **last** match wins; the first capture group, or the whole match when there is none, is substituted; no match, invalid regex, or missing `}}` throws. The closing delimiter is the last two braces of a run of `}` so a pattern may end in `{4}`.
- Playback checks `signal.aborted` before each chunk and throws `Error('aborted')`.
- There is **no request matching**. Auxiliary model calls made with the session's id (for example session titles and local compaction) consume the same script, which is why replay patches disable `session-title-llm` and why local compaction calls are recorded as explicit script entries.
- `assertConsumed()` throws `llm-replay: fixture not fully consumed — <problems>; the scenario drove fewer model calls than recorded` when a script never bound or a cursor stopped early. Only the Web scaffold calls it; subprocess suites detect under-consumption through the session-log comparison.

Strictness therefore comes from four places: positional exhaustion errors; the complete session-log comparison (the model-visible ⟺ logged rule makes the log a request oracle: `system/message`, every surface message, `request/header` config and tools, `request/context`); the header and prompt pin check against readable sidecars; and, for seven SDK scenarios, a captured-request file asserted directly.

### D. Normalization before comparison (`session-snapshot/src/normalize.ts`, `identity.ts`)

`normalizeSessionSnapshots(rawLogs, ctx, {nativeWriterOutput})` (`normalize.ts:483-502`), applied identically to actual and expected:

1. Per log, if the header has a `version`: `prepareSessionSnapshotFixtureForComparison` (migrate to the current format in memory, re-encode with complete envelopes, restore the `{{cwd}}` header token and `{{tools}}` request tokens). Then `normalizeSessionFormatMetadata`: delete the header `version`; with `nativeWriterOutput`, replace `session-log-deepseek/delivery-accepted.data.sessionFormatVersion` by `{{sourceSessionFormatVersion}}` when it equals that log's original version.
2. `redactSessionSnapshotIds(logs)` over the whole parent-first set (`identity.ts:48-135`). Claim order: every header `id` as `session` (always); then a depth-first walk of each record in log order. A string is claimable only if it contains a UUID, ends in `-<16 hex>`, or already is a token (canonical tokens map to themselves and raise that kind's counter). Kinds by key: `id` inside `approval/asked`/`approval/decided` → `approval`; `commandId` → `command` (always); `rpcId` → `rpc` (always); `retryId` → `retry`; `runId` → `workflow`; any key matching `^id$|Id$|Ids$` → `id`; an object shaped like a message (`id` string, `role` string, `content` array, `source` object) → `message`; text `as message <36 chars>` → `message`; text `Anonymous user: <36 chars>` → `id`; `feedback/message-put.data.item.version` → `id`. Replacement: exact string match first, otherwise substring replacement longest source first.
3. `normalizeSessionLog(log, {…ctx, sessionIds: []}, {identityMode: 'preserve'})` (`normalize.ts:350-437`): header `createdAt = 0`; event `time = 0`; packed rows `time0 = 0`, every `data.dt` entry 0; inside `assistant/message|attempt.data.stream` every `time`, `time0` = 0 and `dt` entries 0; `hook/result.data.durationMs = 0`; `feedback/message-put.data.item.createdAt|updatedAt = 0`; `job/registered|settled.data.startedAt|finishedAt = 0`; `goal/change.data.createdAt|updatedAt = 0`; `subagent/catalog.data.childCreatedAt = 0`; `sourceEventSeqs` expanded. Then every string is scrubbed (`scrubString`, `:171-209`): each known cwd spelling (given cwd, aliases, and `/private`-prefixed macOS forms, longest first) → `{{cwd}}` only at path/text boundaries; `/private{{cwd}}` → `{{cwd}}`; in canonical mode backslashes become `/` only inside `{{cwd}}`-rooted paths, `<path>…</path>` tags, `Additional instructions from: …` lines, and values under a key named `path`; local spill paths `{{cwd}}/.spill/session-<12hex>/<12hex>-<name>` and snapshot spill paths `(/tmp|/t)/(dsh-acp-snap-<9hex>|dsh-acp-snapshot-spill)/session-<12hex>/<12hex>-<name>` → `{{spillLocator:<name>}}`; inside a `session_event_read` result envelope (`Session … — …\nTarget event seq N:\n```json`) the pretty-printed top-level `"time": N` → `{{eventTime}}` and `(Omitted N bytes.)` → `{{eventOmittedBytes}}`. In `legacy` identity mode (ACP stdout, SDK notifications without typed ids) additionally: known session ids and any UUID → `{{sessionId}}`, `messageId` values → `{{messageId}}`, job ids → `{{id:N}}`.
4. `scrubSessionSnapshot`: `system/message` first text block → `{{system}}`; `request/header.data.header.tools` → `{{tools}}` (or names when a `developer/message` exists); drop top-level `seq`/`time`/`seq0`/`time0`; expand `sourceEventSeqs`.
5. `projectSessionSnapshot`: drop envelopes again; one compact JSON object per line.

What is **not** normalized and must match exactly: event types and order, turn/step numbers, all message content (user, runtime-context, tool results, assistant content and usage), tool-call ids and arguments, model-recorded chunk sequences inside `stream` (texts and chunk boundaries), `request/header` config/reason, `request/context`, titles, policy events, job labels/status/detail, error codes and messages, `surfaceOp`, `sourceEventSeqs` values, relative identity relationships.

`normalizeStdout(raw, ctx, options)` (`:307-332`): split into lines, parse each as JSON (non-JSON throws — protocol stdout purity check), rewrite JSON-RPC `id` values to first-seen ordinals 1, 2, 3 …, scrub strings, replace `usage_update.used` by `{{usedTokens}}`, emit NDJSON.

### E. Fixture write-back (record/refresh)

`tokenizeSessionFixtureCwd` (replace known cwd spellings and any absolute path ending in the cwd basename by `{{cwd}}`) → `prepareSessionSnapshotFixtureForComparison` → `scrubSessionSnapshot` → `stabilizeFixtureMessageIds(fresh, prior)` (carry an existing message id into a fresh message whose id-less canonical JSON fingerprint is unique in both logs) → `redactSessionSnapshotIds`. Refresh first runs `stabilizeRefreshLog(fresh, existing, replacements, ctx)` (`suite.ts:1133-1187`): keep fresh semantics, but reuse the existing fixture's volatile leaves (header `id/createdAt/cwd/parentSession`, event `time`, hook `durationMs`, packed member times, other strings that are equal after normalization) when the record layout aligns and volatile strings form a consistent bijection; a newly inserted `session/title` takes the previous event's time. `reconcileCatalogCreationTimes(logs, 'validate')` requires every `subagent/catalog.childCreatedAt` to equal that child's header `createdAt` before normalization. Committed fixtures must be fixed points of `redactSessionSnapshotIds`, `scrubSystemPrompts`, and `scrubToolSchemas`. Record and refresh never rename or delete an existing generation, never write Session fixtures for `sessionFormat` scenarios (they write `writer*.expected.jsonl` in refresh), and never rewrite `workspace.expected/`.

### F. Header classes and pins (`headless.snapshot.ts:1010-1062`, `suite.ts:1490-1595`)

A header class groups scenarios whose assembled request header and system prompt are identical. Exactly one scenario per `<composition>/<class>` sets `pin: true`; it owns (or names the owner of) the prompt and schema sidecars. For every harvested log of every scenario in the class:

- the pin's fixture must contain exactly `1 + changes` non-`series` request headers, and the schema sidecar the same number of sets;
- each actual normalized `request/header.data.header` must deep-equal the pin's header with `tools` restored from the sidecar set (`restorePinnedToolSchemas`: the header must hold `{{tools}}` or the ordered sidecar names). Headless compares actual header index `i` to pinned index `i` (fallback index 0); ACP advances the revision on each `reason: 'change'`. Child logs listed in `childToolSchemas` use their own sidecar for `tools`;
- a `system/message` must precede the first `request/header`; the count of `system/message` events is `1 + promptChanges` for the parent (1 for children);
- `formatSystemPromptSnapshot(prompts[0], prompts.slice(1))` must equal the prompt sidecar (or the child sidecar).

Consequence for a port: to pass any scenario unchanged, the Racket system must assemble byte-identical system prompt text and tool schemas (names, descriptions, JSON parameter schemas, order) for that composition.

### G. Corpus gates (`scripts/session-snapshot-corpus.corpus.ts`, `…-policy.ts`)

- The `*.snapshot.ts(x)` suffix is reserved for exactly eight adapter files (three under `snapshots/`, five under `apps/web/tests/`).
- Every scenario directory has `snapshot.yml` with `scenario` = directory name, the tree's profile, `composition`, `recording`, `header`; a pin exists for its class.
- Owners have ≥ 1 Session fixture; borrowers have none and `session.source` resolves to another corpus owner's **selected parent** file (no chains).
- `replay.override.json` exists iff `replay.override`; `workspace.expected/` exists iff `workspace.final`; `input.json` exists iff the tree is `acp`; `stdout.expected.jsonl` only in `acp`.
- Sidecar symlinks must resolve to the manifest-declared source.
- Generation policy: a role's selected version must be 3 (retained baseline) or the current writer (4) unless the scenario declares `sessionFormat`; then every role must equal that version, version ≤ current, and equal to current only for `coverage: [retired-tools]`. v0 retained coverage must include `multi-hop`, `packed-row`, `retry-failure`, `shipped-profile` across the corpus; each of v1..v3 needs `adjacent-migration` (v3 is satisfied by any baseline role). At most 13 retained roles (currently exactly 13 roles in 10 scenarios); baseline + current roles must outnumber retained roles.
- Scenario HTTP fixtures (`*.mjs`) may only `listen(0, …)`, `listen({port: 0, …})`, or `listen({path})` (checked by a TypeScript AST walk).

### H. ACP adapter (`harness.ts:248-411`, `suite.ts:1230-1606`)

`runScenario(input, opts)`: `mkdtemp(<tmp>/acp-snap-cwd-)`, sessions root `acp-snap-sessions-`, spill root `acp-snap-spill-`; copy `workspace/`; capture the initial workspace ignoring `.agents`, `.dsh`, `.dsh-profile-patches`, `.dsh-snapshot-stream-ready`; spawn the agent with stdio pipes; connect an ACP SDK client (`initialize` sends `protocolVersion: PROTOCOL_VERSION`, `clientCapabilities: {}`; `newSession` sends `{cwd, mcpServers: []}`); tee raw stdout; run the steps; close stdin and await exit (flushes persistence); harvest logs; capture the final workspace; always tear down (SIGKILL fallback, remove all temp roots, aggregate teardown errors with the scenario error). Replay patch selection: `[base cordis.yml, sibling cordis.snapshot.yml of the selected live patch]`; other modes `[base, selected]` (`launcher.ts:344-369`). The suite compares normalized stdout with `stdout.expected.jsonl` (`toMatchFileSnapshot`), session logs when `comparesLog` (default: `hasModelTurn` and no `sessionFormat`), header pins, and workspace; it rejects any `tool/result` whose `data.error.code` is `UNKNOWN_TOOL`. Durable waits poll the raw JSONL for `\n{"type":"turn/end",` vs `\n{"type":"turn/start",` positions so cancellation scenarios do not turn `aborted` into `disposed`.

### I. SDK adapter (`snapshots/sdk/sdk.snapshot.ts:743-1054`)

- Corpus = `snapshots/session` + `snapshots/sdk` (compositions and pins can cross trees; a source key `tree/name`).
- cwd `mkdtemp(<realpath tmp>/sdk-snapshot-<name>-)`; replay fixtures are **hydrated** into `<cwd>/.replay-fixtures/` with every `{{cwd}}` replaced by the real cwd (so recorded tool arguments with absolute paths work; headless and ACP pass the committed file directly, so their recordings use relative paths).
- Patches: `legacy-context.patch.yml` first for 19 named legacy compositions (`legacySdkCompositions`, `:705-725`); then for `sdk-*` compositions `[owner cordis.yml, owner cordis.snapshot.yml (replay)]`, otherwise `[text-turn cordis.yml, owner cordis.snapshot.yml | cordis.yml, text-turn model.cordis.yml]`; then per-scenario extra patches.
- Actions are derived from the parent fixture (`sdkActions`, `:553-600`): each `turn/start … turn/end` whose first `user/message` has `source.kind === 'user'` becomes a `turn` action with that content; a turn without user content is awaited, not driven; with `replayStandaloneCommands`, each user `command/run` outside a turn becomes a `command` action with line `/<name><args>`; inputs spliced while a command runs belong to the command.
- The root session id is fixed: `fixture-root-session`. Child live ids are learned from `subagent.started` notifications and substituted for `{{session:N}}` in inputs. Image blocks are rebuilt from `manifest.input.attachments` by attachment id.
- `session-resume` closes the harness after turn 1, reopens it with model `deepseek-v4-pro`, checks `resumeSession('missing-session')` rejects, resumes, and uses a per-turn override script file written from `deriveReplayScript(events of that turn)`.
- Compared: persisted logs (as in A.9), header pins, optional `notifications.expected.jsonl` (each `session.event` payload normalized like a log line, with `seq` kept and `time` 0) and `result.expected.json` (`{sessionId, finalResponse}`), workspace, and per-scenario assertions on events and captured model requests.

### J. `runFixtureTurn` and testkit invariants

- `runFixtureTurn`: wait `agent.whenIdle()`; create a user message `{content: [{type:'text', text: task}], source: {kind:'user'}}`; `agent.followup(message)`; wait idle; `ctx.sessions.flush(session)`; return `{type:'result', sessionId, output, usage?}` where `output` is the text of the last `assistant/message` that had text and `usage` sums the last usage per `<turn>/<step>` key (so retries are not double counted; cache/reasoning fields summed only when present).
- `mountAgentLoopTestDependencies(ctx, options)` mounts, in this order: `LlmRuntime`, `SessionStore`, `SessionProjectionRegistry`, `SystemPrompt` (config `options.systemPrompt ?? {}`), optionally `FsLocal` (only if `ctx.get('fs')` is undefined) + `WorkingDirectory`, `ToolRuntime`, then `PtcToolExecutor` (with `maxParallelSubCalls`) or `NativeToolExecutor`, then `AgentRegistry`. It never mounts `AgentLoop` or an adapter.
- `mountAgentLoopTestHarness(ctx)` mounts `AgentLoop` with `{agents: []}` and returns `{ create(id, options = {}, meta = {}) → ctx.agentLoop.create(...)`, `claim(agent, target, turn) → agent.inbox.claim(target, turn) }`.
- `createInboxStub()`: two arrays keyed `next-turn` / `next-step`; `clear`, `append(target, msg)`, `prepend`, `replace(id, msg) → boolean`, `remove(id) → boolean`, `splice(target, start, deleteCount, inserted) → removed[]`. `unsupportedInbox()` / `unsupportedModel()`: every mutation or read throws `this test Agent does not support Inbox mutations` / `… model selection`.
- `executeToolFixture(ctx, input)`: `new ToolExecutionPipeline(ctx)`; `prepare(input)`; if `prepared.kind === 'dispatch'` then `dispatch(prepared.exec)`; `complete(prepared.exec, outcome)`. `executeModelToolFixture(ctx, {callId, name, arguments, signal, agent?, toolSet?})`: JSON-encode arguments (unencodable → `TypeError('Model tool fixture arguments must encode as JSON')`), call `ctx.tools.execute({calls: [{type:'tool-call', id, name, arguments}], signal, agent?, toolSet?})`, return `results[0].result` (missing → `Executor omitted the model tool fixture result`).
- `MockAdapter` (`packages/core/agent-loop/tests/mock-adapter.ts`, the canonical scripted model for unit tests): constructor `(script, reasoning?, defaultMaxTokens?)`; each `stream()` call records `options` in `requests` and shifts one script entry: `StreamChunk[]`, a function `(options) => StreamChunk[]`, `'hang'` (two chunks then wait for abort), `'hang-slow'` (same, rejecting 50 ms after abort), or `{hangAfter: StreamChunk[]}`; an empty script throws `MockAdapter: script exhausted`. Helpers: `textResponse(text)` (one `text-delta` per character; usage `{inputTokens: 10, outputTokens: text.length}`; finish `stop`), `maxTokensResponse(text)` (finish `max-tokens`), `toolCallResponse(callId, name, args, text?)` (optional text block; tool-call arguments split at 5 characters into two deltas, the first carrying `name`; usage `{10, 5}`; finish `tool-calls`). Registered with `ctx.llm.registerAdapter(['mock'], adapter)`.

## Tests worth porting

### Unit suites that define harness behavior

| Path | Behaviors pinned |
|---|---|
| `packages/test-support/llm-replay/tests/llm-replay.spec.ts` (2,317 lines) | Fixture parsing and line-numbered diagnostics; envelope synthesis; packed-row expansion; derivation rules (retries, compaction calls, unfinished streams); override forms and validation; positional and per-session replay; `{{fromRequest}}` and `{{session:N}}`; throw/hang/abort/pace semantics; `assertConsumed`; provider catalog registration; HMR disposal. |
| `packages/test-support/llm-replay/tests/session-format-corpus.spec.ts` + `-inventory.ts` | Every repository Session fixture decodes and migrates, except an exact list of expected refusals. |
| `packages/test-support/session-snapshot/tests/normalize.spec.ts` (1,323 lines) | Every normalization rule in section D, including boundary cases (file URIs, Windows separators, `/private`, spill paths, event-read regions). |
| `…/tests/identity.spec.ts`, `manifest.spec.ts`, `workspace.spec.ts`, `storage-policy.spec.ts` | Typed redaction relationships; closed manifest schema; workspace capture (text/binary/symlink/empty dir, `.empty` markers, NUL bytes → binary); highest-generation storage checks. |
| `…/tests/harness.spec.ts`, `suite.spec.ts` + `tests/fixtures/` (fake ACP agent, suite fixture trees) | ACP step interpreter, wait semantics, permission queue, teardown aggregation, guard block of the suite factory. |
| `packages/test-support/llm-mock-server/tests/{server,cli}.spec.ts` | Every behavior's wire output, random seeding, CLI validation. |
| `packages/test-support/loader-smoke/tests/*.spec.ts` | `src`/`lib` launch resolution, timeout and exit-code diagnostics, `runFixtureTurn`. |
| `packages/test-support/agent-loop-testkit/tests/agent-loop-testkit.spec.ts`, `tool-testkit/tests/model-call.spec.ts` | Testkit API contracts listed in section J. |
| `scripts/session-snapshot-corpus-policy.spec.ts`, `scripts/snapshot-{shell-path,spill-locators,workspace-parent,http-fixtures}.spec.ts`, `scripts/session-fixture-layout.spec.ts` | Corpus policy arithmetic; fixture plugins (path translation, spill locator mapping, outside-temp workspace parent, HTTP fixture lifecycle); canonical projected fixture layout and its idempotence. The listener-port rule and the stderr/task projections are pinned inside `snapshots/session/headless.snapshot.ts:1065-1340`. |
| `packages/core/agent-loop/tests/*.spec.ts` (30 files, with `mock-adapter.ts`) | The loop contract under a scripted model; the model for Racket loop unit tests. |
| `python/sdk/tests/test_run.py`, `test_client.py` | Python SDK against a fake JSON-RPC peer script written to a temp file (`_launch_args=(sys.executable, peer)`), request log via `REQUEST_LOG`. |

### Corpus inventory

Counts at the pinned commit: `session` 190 scenarios (185 select v4, 4 select v0, 1 selects v1; 49 `live`, 141 `authored`; 35 with overrides; 19 with children; 37 with `workspace.final`; 26 with `runtime.cordis.yml`; 101 composition owners); `sdk` 40 (39 v4, 1 v2; 8 live; 6 overrides; 10 with children); `acp` 9 (7 v4, 2 v3; 3 live; 2 overrides); `web` 74 (33 v4, 12 v3, 1 v2, 28 borrowers). Descriptions below are derived from each manifest, the recorded task text, and the recorded tool calls. `[P]` = header pin, `[O]` = override sidecar, `[W]` = final workspace oracle, `[R]` = `runtime.cordis.yml`, `[C:n]` = n child sessions, `posix`/`pwsh` = platform requirement. Composition is `default` unless named.

**`snapshots/session` (headless, 190)**

Core loop, providers, requests:
- `text-turn` — text reply `PONG`, no tools; owns the `default` composition patches and the shared prompt/schema sidecars; retained v1 input (`adjacent-migration`) plus `writer.expected.jsonl`.
- `tool-call-turn` [P] — one `bash` call (`echo SNAPSHOT_OK`) then `DONE`; pins `default/default`; replay also runs once from the retained `session.v3.jsonl` to check tool-result writer parity.
- `bash-tool-turn` — one `bash` call (`echo TERMINAL_OK`), job registered/settled.
- `bash-same-mode-empty-justification` — `bash` with `sandbox_permissions` equal to the current mode and an empty justification is accepted.
- `bash-startup-timeout` — `bash` with `timeoutMs: 1`; result `[still running after 1ms; moved to background job …]`; job settles after the turn.
- `bash-spill` (comp `fs`) — large bash output spilled with a preview and locator.
- `parallel-tool-calls` [P] (owns `fs`) — two `read` calls in one assistant message; results in call order.
- `todo-write` — `todo_write` with three todos; `todo/write` event.
- `repeat-tool-reminder` — identical `todo_write` calls trigger an injected `repeat-tool-reminder` user message.
- `toolcall-unused-args` [O] — goal tools and `grep` with unused arguments; override uses `{{fromRequest:goal-[0-9a-f-]+}}`.
- `error-finish` [O] — provider throw (`AUTH`) → `turn/end` error, exit 1; retained v0 (`retry-failure`).
- `empty-response-retry` (owns `retry`) — empty completion then retried reply; retained v0.
- `empty-response-retry-current` [P] (`retry`) — same in the current format; order `assistant/attempt`, `llm/retry`, `llm/retry-started`, `assistant/message`.
- `packed-chunks` — retained v0 fixture with packed chunk rows (`packed-row`).
- `persistence-provider-unload` [R] — persistence provider unload during the session lifecycle.
- `provider-cwd` [P] (`posix`, read-only) — provider-supplied session cwd; resume with `--session-id` refused on cwd mismatch, continued on match.
- `model-switch-notice` [P] — model switch mid-session: header change, prompt change, notice.
- `model-switch-compaction` [P] (`posix`) — model switch combined with compaction.
- `compaction-recovery` [P], `compaction-output-reserve` [P] (`posix`), `compaction-summary-headroom` [P] (`posix`) — automatic compaction with a local summary call, output reserve, and summary headroom.
- `system-prompt-in-history` [P][O] — prompt change appended in history on an `in-history` route.
- `in-history-series-start` [P] — in-history series start with a dynamic tool.
- `dynamic-tool-updates` [P], `dynamic-tool-prompt-updates` [P] — a tool (`snapshot_ping`) appears mid-session; header changes; with prompt change.
- `deepseek-deferred-tools` [P], `deepseek-all-deferred-tools` [P] — deferred tool loading (`developer/message` additions; 4 header changes) and an all-deferred catalog.
- `deepseek-messages-replay` [P], `deepseek-messages-degraded-replay`, `deepseek-messages-empty-text-history` [P][R], `deepseek-messages-input-history` [P], `deepseek-messages-invalid-tool-history` [P], `deepseek-messages-system-prompt` [P][O], `deepseek-protocol-system-prompt` [P][O] — Messages-protocol route replay metadata and history edge cases; prompt updates per protocol.
- `pi-ai-replay-metadata`, `pi-ai-malformed-tool-arguments` [W] (ends `MALFORMED_RESPONSE`), `pi-ai-conversation-updates` [P] — pi-ai adapter replay state, malformed tool arguments, conversation updates.
- `deepseek-fetch` [P] — `web_fetch` through the DeepSeek fetch route against a loopback fixture.

Filesystem, patch, search, images:
- `fs-read`, `fs-read-window` — `read`, and `read` with `offset`/`limit`.
- `fs-write` [W], `fs-write-overwrite` [W], `fs-write-overwrite-bounded` [P][W] (`fs-diff-bound`) — create, read-then-overwrite, bounded diff metadata.
- `fs-edit` [W] — `read` then `edit`.
- `fs-delete-recreate` [W] — read, delete via bash, re-read, recreate with `write`.
- `fs-policy-reject` [W][R] — `edit` without a prior read refused by the observation policy.
- `fs-same-mode-empty-justification` [W] — fs tools with same-mode `sandbox_permissions`.
- `fs-glob-sampling` [P] (`posix`) — `glob *` sampling order with fixed mtimes.
- `apply-patch-update` [P][W], `apply-patch-partial` [W], `apply-patch-rejected` [W][R] (all `posix`) — multi-file patch, partial application stop, refusal on an unread file.
- `workspace-edit` [W] — bash appends to a file.
- `working-directory` [W] (`posix`), `working-directory-consumers` [W] (`posix`, comp `claude-code-mods`), `working-directory-admission` [P] (`posix`) — `working_directory` changes, notices, consumers, admission.
- `worktree` [P][W] (`posix`) — `create_worktree` and work inside it.
- `read-image` [P], `read-image-attachment-path` [O], `read-image-dimension`, `read-image-gif`, `read-image-reencode`, `read-image-text-route` [P] — image reading variants and the text-only route refusal.
- `multimodal-spill-ends` [P], `multimodal-spill-middle` — spill of a mixed text/image MCP result.
- `session-query-spill` [P][O] (`posix`), `session-reference-spill` [P] — `session_event_read` spill and `@Session` reference message.
- `lsp-definition` [P] — `lsp` definition lookup.

Shell, sandbox, jobs, terminals:
- `background-job-notice` [O] (`posix`) — background job completion notice arrives in-session.
- `background-job-admission` [P][O][W] (`posix`) — background job limit and `job_kill`.
- `background-confinement-failure` [P][O][W], `foreground-confinement-timeout` [P][W] (`posix`, read-only) — confinement failure before spawn; preparation timeout.
- `missing-sandbox-runner`, `partial-landlock-child-failure` [P] (`posix`, read-only) — missing runner surfaced; child exit code preserved under partial Landlock.
- `session-sandbox-root` [P][O][W] — session workspace root grant outside temp.
- `pwsh-tool-turn` [P] (`pwsh`), `persistent-pwsh-tool-turn` [P] (`pwsh`), `persistent-pwsh-padded-completion` [P] — PowerShell tool variants.
- `pty-tools-sandbox-backend` [P], `terminal-panel-tools` [P] — PTY tools and user-terminal tools.
- `claude-code-mods` [P][W] — Claude Code mod compatibility (dangerous command handling).
- `headless-auto-review` [P][W][R] — Auto review decisions for four writes.
- `headless-credentials` — credential store inactive in headless.

Hooks (workspace `hooks.json` / `codex-hooks.json`): `hook-cc-invalid-matcher`, `hook-cc-pretool-ask`, `hook-cc-pretool-deny`, `hook-cc-posttool-block` [W], `hook-cc-posttool-context`, `hook-cc-promptsubmit-block` (turn ends `blocked`, no request), `hook-cc-promptsubmit-context`, `hook-cc-stop-continue` [W]; `hook-codex-invalid-matcher`, `hook-codex-pretool-block`, `hook-codex-posttool-block`, `hook-codex-posttool-context`, `hook-codex-promptsubmit-block`, `hook-codex-promptsubmit-context`, `hook-codex-stop-continue` [W] — each named hook point and decision for the two hook dialects.

Instructions and skills:
- `agent-instructions` [P][O] (`posix`), `agent-instructions-budget` [P], `agent-instructions-budget-chains`, `agent-instructions-group-failure` [P] — nested `AGENTS.md` discovery, delimiter-bearing path, byte budget, group failure.
- `skill-load` [P], `skill-root-isolation` [R] (`posix`), `windows-acl-skill`, `dsh-doc-load` — `skill` tool, root isolation with a broken root, bundled skills.
- `office-skills` [P], `office-skills-no-renderer` [P], `office-authoring-checker` [P], `office-progressive-native` [P], `office-progressive-ptc` [P], `office-render-tools` (retained v4 `retired-tools`), `office-render-tools-ptc` [O] (retained) — Office skills, progressive tool loading, retired render tools.

PTC and workflow:
- `ptc-turn` [P] (owns `ptc`), `both-mode-turn` [P], `ptc-python-turn` [P], `ptc-python-read-only` [W] — `run_code` programs calling tools (Node and Python).
- `ptc-console-enabled` [P], `ptc-inspect-output`, `ptc-inspect-image-error` [W], `ptc-read-image` [P][W], `ptc-read-image-attachment-path` [O] — inspect/console output and images from programs.
- `ptc-node-read-only` [P][O][W], `ptc-node-workspace` [P][O][W] — direct Node file access under the policy.
- `ptc-persistent` [P][O][W], `ptc-persistent-scoped` [P][O][W][R], `ptc-policy-change` [P][O][W], `ptc-reset` [P][O][W][R], `ptc-scoped-repl` [P][R], `ptc-script-fresh` [P][R], `ptc-script-imports` [P][O][R], `ptc-script-retained` [P][R], `ptc-timeout` [P][R], `ptc-timeout-fallback` [P][R], `ptc-tool-call-limit` [W][R], `ptc-workspace-context` [P][O] — retained state, resets, script modes, timeouts, sub-call limits.
- `workflow-run` [C:1], `workflow-confinement` [P][W] — `workflow` tool with one agent; confinement of workflow scripts.
- `advanced-toolchain` [P][R][C:2], `advanced-toolchain-runtime` [R][C:2] — native → PTC → subagent → workflow in one flow.
- `cordis-inspect-jsdoc` [P], `cordis-inspect-liveness` [P], `cordis-inspect-timeout` [P] — `cordis_inspect_query` results and client liveness/timeouts.
- `plugin-manager` [P], `plugin-manager-mcp` [P] — `plugin_manager` toggling a plugin and enabling an MCP entry.
- `workspace-dependencies` [P] — `load_workspace_dependencies`.

MCP, web, computer use:
- `mcp-empty` [P], `mcp-empty-ptc` [P], `mcp-resources` [P], `mcp-resources-ptc` [P], `mcp-template-error` [P] — no-server prompts, resource tools, redacted template error.
- `web-fetch` [P], `web-search-unconfigured` [P], `web-search-account-billing` [P], `web-search-api-key-billing` [P], `web-search-endpoint-guidance` [P], `web-search-legacy-endpoint-guidance` [P] — fetch and search availability, billing, endpoint guidance.
- `browser-use-chrome-devtools-mcp` [P][O], `browser-use-playwright-mcp` [P][O], `browser-use-stagehand-native` [P][O] — browser providers.
- `computer-use-cua-driver-mcp` [P][O], `computer-use-cua-driver-native` [P][O], `cua-native` [P][O], `cua-ptc` [P][O], `cua-run-code` [P][R], `cua-run-code-scoped` [P][R] — computer-use providers against fixtures.

Agents and teams:
- `subagent-spawn-in-process` [R][C:1] — one spawned child; settlement notice starts a second parent turn.
- `subagent-multi` [R][C:2] — two sequential children; retained v0 (`multi-hop`, `shipped-profile`).
- `subagent-parallel` [R][C:2] — two parallel `subagent` calls plus `wait_agent`.
- `subagent-max-tokens-partial` [C:1] — child cut off at max tokens returns partial output.
- `subagent-agent-preset` [P][C:1], `subagent-tool-filter` [P][C:1], `subagent-no-message-tool` [P][C:1], `subagent-structured-parent` [P][C:1] — child preset, tool filter, no message tool, structured result.
- `subagent-child-question-rejection` [P][C:1], `subagent-depth-two-rejection` [P][O][C:2], `subagent-depth-context-disabled` [R] — child `ask_user_question` rejected; depth limits.
- `subagent-archive-lineage` [W][R][C:3], `subagent-published-run-failure` [P][O][C:1] — archive lineage; published run failure.
- `subagent-acp-diagnostic` [P][O], `product-subagent-oar` [P], `product-subagent-codex` [P], `product-subagent-both` [P], `product-subagent-result-diagnostic` [P][O] — external subagent providers in the catalog and their diagnostics.
- `ralph-loop` [P][O][C:2] — two-round Ralph loop.
- `team-targets` [P], `team-session-mode` [P], `team-historical-records` [R], `team-direct-inbox` [W][C:1], `team-task-inbox` [R][C:1], `team-tree-messages` [O][C:2] — `list_agents`/`send_message` targeting, team mode, task board, inbox delivery.

**`snapshots/sdk` (40)**

`account-provider-signout` [P] (turn aborted by account sign-out hook); `approval` [W][R] (approval request protocol); `background-wait-steer` [P][O]; `bash-tool` [P] (owns `sdk-default`; wire goldens); `command-attachments` [P] (commands with image attachments); `command-identity` [R]; `desktop-context` [P] (owns `sdk-desktop`); `desktop-ptc-context` [P]; `dynamic-tool-updates`; `goal-rounds` [O]; `inline-image-prompt`; `manual-compact` (`/compact`); `max-tokens-continue`; `minimal-image-compaction` [P] (`sdk-minimal`); `multi-turn` (retained v2); `permission-switch` (`/permission`); `persistent-tools` [P][W] (`sdk-minimal`: `bash`, `str_replace_editor`, `working_directory`); `plan-review` [P] (4 header and prompt changes); `ptc-cancel` [R] (turn aborted); `ptc-turn` [R]; `serial-created` [P]; `session-resume` [P] (process restart and resume with another model); `session-title-after-turn` [P][O]; `session-title-stability` [P][O]; `subagent-activation-limit` [P][O][C:1]; `subagent-continuable` [C:1]; `subagent-continuable-inheritance` [P][C:1]; `subagent-dsh-sdk-diagnostic` [P]; `subagent-dsh-sdk-dynamic-route` [P][C:1]; `subagent-fork-in-process` [C:1]; `subagent-list-agents` [C:1]; `subagent-mixed` [C:2]; `subagent-send-message` [P][C:1]; `subagent-spawn-in-process` [R][C:1]; `system-prompt-in-history` [O]; `team-default-enabled` [P][C:1]; `team-session-mode` [P]; `text-turn` [P] (owns `sdk-upload`; feedback events; wire goldens); `tool-error-details` [P][R] (native denial then PTC inner denial); `tool-scheduler-recovery` [R].

**`snapshots/acp` (9)**

`handshake` (initialize + session/new only; v3); `reject-extra-dirs` (session/new with `additionalDirectories` rejected; v3); `cancel` [O] (hang entry, cancel mid-stream, turn `aborted`); `cancel-tool-calls` [O][W] (`posix`; cancel during the first of two bash calls); `escalation-approved` [P] (owns `acp-default`; permission `allow_once` for a `danger-full-access` bash escalation; sidecars are symlinks to `session/text-turn`); `escalation-rejected`; `fs-escalation-approved` [W]; `fs-same-mode` [W]; `image-compaction` [P] (owns `image-compaction`; six image attachments then compaction).

**`snapshots/web` (74)**

Owners: `approval-composer` [W]; `auto-review-approval` (v3); `auto-review-denial` [P] (v3); `autolink-cjk-punctuation`; `changed-files-turn` [W]; `code-language`; `cordis-tool-round` [P] (retained v3, `retired-tools`); `creation-recommendations` [P]; `creator-persona` [P]; `deepseek-messages-chat`; `diff-bounded` (v3); `feedback-command`; `file-upload-round` [O]; `fresh-round-trip` [P] (canonical bash round trip; reload and reconnect goldens); `goal-multi-turn-actions` [O]; `lifecycle-chrome` [O] (retry, cancel, error chrome); `live-interactions`; `markdown-file-links` (v3); `message-feedback-protocol` (v3); `minimal-compact` [P]; `minimal-preset` [P]; `minimal-read-image` [P]; `navigation-panes` (v3); `official-subagent-bundle` [P][W]; `optional-string-editor` [P][W]; `permission-policy-context` [W]; `plan-narrow-viewport` (v3); `plan-review`; `plugin-recommendations` [P]; `present` [W]; `present-after-closing-reply`; `present-svg` [W]; `preset-migration` (retained v2, one child); `ptc-escalation-approved` [W]; `ptc-round` [P]; `pwsh-terminal` (v3); `question-composer`; `question-composer-recommended`; `schedule-catalog` [P] (v3); `seeded-history` (v3); `standard-dsh-doc`; `steering`; `subagent-fork-schedule` [C:1]; `tool-details` (v3; many tool cards); `turn-tail-actions`; `web-search-round`.

Borrowers (UI goldens over another scenario's session): from `fresh-round-trip`: `background-job-list`, `default-workspace` [W], `session-inspector`, `voice-input`; from `seeded-history`: `collapse-timing`, `interrupted-turn`, `message-actions`, `open-in-app-ssh`, `rich-text-quotes`, `sidebar-scrollbar`, `user-text-secret-mask`, `workspace-management`, `workspace-recency`; from `lifecycle-chrome`: `details-session-lifecycle`, `document-preview`, `excel-opc`, `sidebar-browser`; from `live-interactions`: `queue-actions`, `queued-image`, `subagent-conversation`, `subagent-interrupt`; from `feedback-command`: `feedback-release`; from `acp/cancel-tool-calls`: `bash-abort-row`; from `session/cua-run-code`: `cua-run-code`; from `session/fs-edit`: `diff-context`; from `session/toolcall-unused-args`: `search-empty-include`; from `session/skill-load`: `skill-tool-row`; from `session/workflow-run`: `workflow-run`.

Web scenarios run in-process (`apps/web/tests/scaffold.ts`: the real Loader composition, `installLlmReplay` on the root context, Playwright Chromium) and compare normalized ARIA text (`{{clock}}`, `{{duration}}`, `{{throughput}}`, `{{age}}`, `{{uuid}}`, `{{workspace}}`, `{{timestamp}}`, `{{tokens}}`) plus the session log. They need the browser client and are out of reach for a Racket-only replay.

### The most valuable cases for unchanged replay in the Racket port

Selection rule: headless profile, `default` composition (only `text-turn`'s three patches), selected generation v4 (no migration needed), no `runtime.cordis.yml`, no JavaScript fixture plugin. Shared prerequisites for all of them: `snapshots/session/text-turn/{cordis.yml, cordis.snapshot.yml, model.cordis.yml, system-prompt.expected.md, tool-schemas.expected.json}` (the 25-tool default catalog: `apply_patch`, `bash`, `create_goal`, `edit`, `get_goal`, `glob`, `grep`, `job_kill`, `job_list`, `job_output`, `list_agents`, `read`, `read_image`, `send_message`, `skill`, `subagent`, `subagent_fork`, `todo_write`, `update_goal`, `wait_agent`, `web_fetch`, `web_search`, `workflow`, `working_directory`, `write`, and a 3,617-byte prompt).

| # | Scenario | Files in its directory | What it exercises |
|---|---|---|---|
| 1 | `pi-ai-replay-metadata` | `snapshot.yml`, `session.v4.jsonl` | Smallest text turn (17 lines); `finish.replayState` passes through. |
| 2 | `tool-call-turn` | `snapshot.yml`, `session.v4.jsonl` | Class pin; bash call, job events, two steps. |
| 3 | `bash-tool-turn` | same | Second bash case in the same class (pin equality). |
| 4 | `fs-read` | + `workspace/greeting.txt` | `read` result format (`<path>…</path><type>file</type><content>…`). |
| 5 | `fs-read-window` | + `workspace/big.txt` | `offset`/`limit`. |
| 6 | `fs-write` | + `workspace.expected/` | Workspace oracle for a created file. |
| 7 | `fs-edit` | + `workspace/`, `workspace.expected/` | Read-before-edit and edit result text. |
| 8 | `fs-write-overwrite` | + `workspace/`, `workspace.expected/` | Overwrite after read. |
| 9 | `fs-delete-recreate` | + `workspace/`, `workspace.expected/` | Stale-read handling across bash deletion. |
| 10 | `workspace-edit` | + `workspace/`, `workspace.expected/` | Two bash calls mutating the workspace. |
| 11 | `todo-write` | `snapshot.yml`, `session.v4.jsonl` | `todo/write` event and result text. |
| 12 | `repeat-tool-reminder` | same | Guard-injected reminder message and inbox splices mid-turn. |
| 13 | `bash-startup-timeout` | same | Foreground-to-background promotion; `job/settled` after `turn/end`. |
| 14 | `hook-cc-pretool-deny` | + `workspace/hooks.json` | `hook/invoked`, `hook/result`, tool error result. |
| 15 | `hook-cc-promptsubmit-block` | + `workspace/hooks.json` | Blocked prompt: `turn/end {kind: blocked}`, exit code 1, no model call. |
| 16 | `hook-codex-posttool-context` | + `workspace/codex-hooks.json` | Second hook dialect. |
| 17 | `skill-load` | + `workspace/.dsh/skills/**` | `skill` tool and skill discovery (class `skill`, sidecars from `text-turn`). |
| 18 | `toolcall-unused-args` | + `replay.override.json`, `workspace/seed/*` | Goal tools, `grep`, and the `{{fromRequest}}` placeholder. |
| 19 | `pi-ai-malformed-tool-arguments` | + `workspace.expected/` | `assistant/attempt`, error turn end (`MALFORMED_RESPONSE`), exit 1. |
| 20 | `subagent-max-tokens-partial` | + `session.1.v4.jsonl` | One child session, `subagent/catalog`, `subagent-settled` message, second parent turn. |

Next tier (need one extra pure-configuration composition or a small fixture equivalent): `empty-response-retry-current` (needs `empty-response-retry/cordis.snapshot.yml` retry policy), `parallel-tool-calls` (needs a spill-locator fixture), `background-job-notice` (whole-script override, `posix`), `working-directory` (`posix`), `subagent-spawn-in-process` (needs the `settlement-order` hold), `workflow-run` (needs the JavaScript workflow runtime), `acp/handshake` and `acp/cancel` (ACP transport and the `hang` entry).

What must match for these: stdout and stderr bytes; process exit code; number of persisted sessions; the complete normalized event sequence of each session (section D); the request header and system prompt pin (section F); and the workspace oracle. The Racket log must first be brought to the same projected form (header `version` is deleted before comparison, so only the event vocabulary and payloads of format v4 matter).

## Porting notes

Essential product behavior to keep:

- A recorded session is at once the input script, the model script, and the expected output. Keep that single-artifact design; it makes "replay a dsh recording and diff the Racket log" possible with no translation layer beyond normalization.
- Replay is an in-process model provider selected by configuration (a Cordis patch), driven by environment variables, positional per live session, with fail-loud exhaustion. Keep the same plugin name (`llm-replay`), config fields, environment variable names, and error messages so that existing `cordis.snapshot.yml` patches load unchanged.
- The normalizers and the manifest schema are pure data transforms and port directly.

Node/TypeScript machinery that need not be reproduced: vitest registration (`describe`/`it`, `toMatchFileSnapshot`), tsx/`lib` dual launch (`DSH_EXAMPLE_MODE`), `materializeProfilePatch`'s `node_modules` symlinking, the TypeScript AST listener-port check, coverage ignores, record/refresh stabilization (needed only if the Racket system becomes a recorder; start with replay-only and treat dsh fixtures as read-only).

Suggested Racket decomposition:

- `dsh/test/replay` — `(parse-session-fixture text)`, `(derive-replay-script events)`, `(load-session-scripts config)`, `(install-llm-replay ctx config) → (values dispose assert-consumed)`, and the plugin `apply`. Replay entries as a struct sum (`chunks`, `throw`, `hang`). The stream is a generator or channel that checks a cancellation evt before each chunk; `hang` blocks on that evt. Disposal through the fiber's effect (custodian-like ownership).
- `dsh/test/mock-model` — the `MockAdapter` equivalent for unit tests: a script list of chunk lists, procedures `(options → chunks)`, `'hang`, `'hang-slow`, `(hang-after chunks)`; a `requests` box; helpers `text-response`, `max-tokens-response`, `tool-call-response` with the same chunking and usage numbers so ported loop tests keep their assertions.
- `dsh/test/snapshot/manifest` (contract-checked hash with a closed key set), `…/files` (fixture name grammar and highest-generation selection), `…/identity`, `…/normalize`, `…/workspace` (capture to a sorted list of `text`/`binary`/`symlink`/`empty-directory` entries; byte-wise name ordering), `…/pins` (sidecar parse/format and header reconstruction).
- `dsh/test/snapshot/headless` — the driver of section A as a `rackunit` test-suite generator over a directory; a parameter for the mode (`replay` only at first); subprocess launch of the Racket `dsh` with the same argv and environment.
- `dsh/test/loop-kit` and `dsh/test/tool-kit` — `mount-agent-loop-test-dependencies`, `mount-agent-loop-test-harness` (`create`, `claim`), `make-inbox-stub`, `unsupported-inbox`, `unsupported-model`, `provide-working-directory-fixture`, `define-content-tool-fixture`, `execute-tool-fixture`, `execute-model-tool-fixture`, `run-fixture-turn`.
- `dsh/test/llm-mock-server` — a small HTTP/SSE server with the behavior table of Formats 9, for adapter recovery tests against the real HTTP client.

Hard parts and risks:

- **Byte-identical prompts and tool schemas.** Every unchanged replay requires the Racket composition to produce the exact system prompt and the exact ordered tool catalog (descriptions and JSON schemas) of the pinned class. This is the dominant cost of goal (b); it also makes the sidecars a ready-made conformance target for each tool package.
- **Byte-identical tool results.** Tool result text is compared verbatim after cwd tokenization (bash output framing, `read` envelope, edit/write messages, error strings, job labels and `detail`).
- **Event ordering under concurrency.** Fixtures pin the interleaving of `job/*`, `subagent/catalog`, inbox splices, and titles (`session/title` lands after `request/context` in v4). Several dsh scenarios need JavaScript fixture plugins to force an order; equivalents must be written for any such scenario adopted.
- **Auxiliary model calls share the session script.** Any Racket component that calls the model with the session id (title generation, compaction) must be disabled or recorded exactly as dsh does, or the positional cursor shifts.
- **`deepseek-official` acceptance side effects.** Replay calls the DeepSeek API extensions `prepare`/`accept` for accepted entries; scenarios with web-search billing or session-log delivery depend on it. The default replay composition disables `session-log-deepseek`.
- **Format generations.** 185 of 190 headless scenarios select v4, so a v4-only reader covers nearly all of them; the five retained scenarios (`text-turn`, `error-finish`, `empty-response-retry`, `packed-chunks`, `subagent-multi`) need the v0/v1 migrations of recon 07. Note that `text-turn`, the owner of the default patches and sidecars, is itself a retained v1 replay input; use its patches and sidecars but replay `pi-ai-replay-metadata` or `hook-cc-invalid-matcher` for the plain text turn.
- **`!!js` in patches.** The default patches use `!!js` expressions (`process.env.DSH_PERMISSION_MODE ?? …`, `dshHomePath('sessions')`, `process.cwd()`); the Racket loader needs its compatible evaluation of these (recon 02/03) before any corpus patch loads.
- **Sandbox runner override.** The replay patch replaces the sandbox runner with a bash pass-through; the Racket sandbox plugin must honor `runnerCommand` and `runnerFailureSignatures`.
- **Path spellings.** cwd tokenization depends on the header cwd and on realpath aliases; on macOS `/private` prefixes appear. Keep the boundary rules or prefixes of longer paths will be corrupted.

What can only be wrapped: the Web tree (needs the browser client and Playwright), SDK scenarios that drive `@deepseek-ai/dsh-sdk-client` (use the Racket SDK server with the existing TypeScript or Python client as a black-box conformance client), scenarios with `.mjs`/`.ts` fixture plugins, workflow and Node/Python PTC scenarios (need the JavaScript/Python runtimes), computer-use and browser-use fixtures, and `scripts/snapshots/python-sdk-single-exe` (installed single-executable runtime).

## Feature checklist

- llm-replay: plugin `llm-replay` with `inject ['llm']` and Config `file`/`overrideFile`/`childFiles`/`providers`/`paceMs`
- llm-replay: environment defaults `DSH_SNAPSHOT_FILE`, `DSH_SNAPSHOT_OVERRIDE`, `DSH_SNAPSHOT_CHILD_FILES` (path-delimiter list)
- llm-replay: missing fixture path fails at apply with the documented message
- llm-replay: parse projected fixtures (no `seq`/`time`), synthesizing dense seq and zero time
- llm-replay: reject mixed projected and complete body rows
- llm-replay: materialize `{{cwd}}` header and `{{tools}}`/tool-name projections before format validation
- llm-replay: derive one `chunks` entry per `assistant/message` and `assistant/attempt` stream
- llm-replay: derive a synthesized entry from `compaction/summary` with `llmStreamCall` and `rawOutput`
- llm-replay: reject a stream without a terminal `finish` chunk and name the turn/step
- llm-replay: override sidecar whole-script form
- llm-replay: override sidecar `{patches}` form with append at length, range and duplicate checks
- llm-replay: strict entry key-set validation for `chunks`/`throw`/`hang`
- llm-replay: child scripts skip inherited events and sort by `createdAt` then id
- llm-replay: bind live sessions to scripts in first-call order; anonymous calls share one script
- llm-replay: synchronous per-session cursor advance at call time
- llm-replay: unrecorded-session and script-exhausted errors
- llm-replay: `{{session:N}}` materialization after binding
- llm-replay: `{{fromRequest:<regex>}}` resolution (last match, first group, brace-run terminator)
- llm-replay: `throw` entry yields prefix chunks then raises an LlmError with the scripted code
- llm-replay: `hang` entry emits two chunks, writes `readyFile`, waits for abort
- llm-replay: abort checked before every chunk and during pace waits
- llm-replay: `paceMs` validation and pacing
- llm-replay: routed adapter mode with provider info, model list, resolved model facts, retry policy, image pricing
- llm-replay: catch-all `llm/stream` waterfall mode when no providers are configured
- llm-replay: `deepseek-official` accepted entries call API-extension `prepare` and `accept`
- llm-replay: `assertConsumed` reports unbound scripts and under-consumed cursors
- llm-replay: disposal removes the adapter or listener
- session-snapshot: closed `snapshot.yml` schema with every field of Formats 2
- session-snapshot: `writesCurrentSessionFixtures` rule
- session-snapshot: fixture filename grammar `session[.k][.vN].jsonl` and writer oracle names
- session-snapshot: highest-generation selection per role with contiguity and duplicate checks
- session-snapshot: filename version must agree with header version (versionless header = v0)
- session-snapshot: latest persisted session path selection per session directory
- session-snapshot: typed identity redaction with first-seen ordinals across parent and child logs
- session-snapshot: redaction fixed-point property on committed fixtures
- session-snapshot: clock zeroing for header, events, streams, hooks, jobs, goals, feedback, catalog
- session-snapshot: cwd tokenization with aliases, `/private`, and boundary rules
- session-snapshot: canonical separator conversion limited to cwd-rooted paths and path markers
- session-snapshot: spill path tokenization to `{{spillLocator:<name>}}`
- session-snapshot: event-read region time and omitted-byte tokenization
- session-snapshot: `{{system}}` and `{{tools}}` scrubbing; tool names retained when developer messages exist
- session-snapshot: envelope projection (drop `seq`/`time`, expand `sourceEventSeqs`)
- session-snapshot: multi-log comparison pipeline `normalizeSessionSnapshots` with native-writer option
- session-snapshot: stdout NDJSON normalization with JSON-RPC id renumbering and purity check
- session-snapshot: prompt sidecar format with change markers; tool-schema sidecar format
- session-snapshot: header pin reconstruction and per-class equality check
- session-snapshot: system prompt must precede the first request header
- session-snapshot: workspace capture (text, binary, symlink, empty directory; ignored root entries)
- session-snapshot: expected-workspace `.empty` marker semantics
- session-snapshot: unchanged-workspace assertion when `workspace.final` is absent
- session-snapshot: catalog child creation time validation
- session-snapshot: `UNKNOWN_TOOL` results rejected in scenarios and fixtures
- session-snapshot: ACP launcher with stdout tee, update waiters, fail-closed permission default, drain-on-close
- session-snapshot: ACP input script interpreter with all step kinds and durable waits
- session-snapshot: FIFO permission answers by option kind; unoffered kind fails the run
- session-snapshot: replay patch selection `cordis.yml` → sibling `cordis.snapshot.yml`
- session-snapshot: profile patch materialization (relative plugin names made absolute)
- session-snapshot: stable spill locator root derived from the scenario name hash
- session-snapshot: suite guards (no orphans, required files, one pin per class, unique sidecars, child sidecars)
- session-snapshot: record mode skips authored and retained scenarios; platform and pwsh skips
- session-snapshot: refresh stabilization of volatile fields and message ids
- headless-driver: task and model route derived from the selected parent fixture
- headless-driver: patch order default → composition replay patch → model patch → runtime patch
- headless-driver: stdout equals final assistant text plus newline
- headless-driver: stderr reasoning projection with `dsh: reasoning:` headers and error line
- headless-driver: exit code 0 for completed turns, 1 otherwise
- headless-driver: sibling child ordering by parent catalog order
- headless-driver: named workspace setups
- headless-driver: retained scenarios compared against `writer*.expected.jsonl` with inputs unchanged
- sdk-driver: actions derived from recorded turns and standalone commands
- sdk-driver: hydrated replay fixtures with real cwd
- sdk-driver: fixed root session id and live child id substitution
- sdk-driver: notification and result wire goldens
- sdk-driver: captured model-request assertions
- acp-driver: scenario table from manifests; normalized stdout golden
- corpus-gate: reserved `*.snapshot.ts` suffix inventory
- corpus-gate: ownership, borrower, override, workspace, input, and symlink rules
- corpus-gate: generation policy (baseline v3, current, bounded retained coverage)
- corpus-gate: OS-assigned listener ports in scenario fixtures
- loader-smoke: `src`/`lib` launch resolution and `DSH_EXAMPLE_MODE` validation
- loader-smoke: isolated cwd, private `DSH_HOME`/`DSH_AGENTS_HOME`, proxy clearing, stdin closed
- loader-smoke: timeout kill and expected-exit-code diagnostics with both streams
- loader-smoke: `runFixtureTurn` result with last text and per-step usage sum
- agent-loop-testkit: prerequisite mounting order and options (`workingDirectory`, `systemPrompt`, `tools.mode`)
- agent-loop-testkit: production loop harness `create` and `claim`
- agent-loop-testkit: in-memory Inbox stub operations
- agent-loop-testkit: fail-fast Inbox and Model placeholders
- agent-loop-testkit: fixed working-directory provider
- tool-testkit: content tool fixture with JSON-array output contract
- tool-testkit: pipeline stage runner `prepare`/`dispatch`/`complete`
- tool-testkit: single-call executor runner with JSON argument encoding check
- mock-adapter: scripted entries (chunks, function, hang, hang-slow, hangAfter) and recorded requests
- mock-adapter: `textResponse`, `maxTokensResponse`, `toolCallResponse` helpers
- llm-mock-server: route, method, API key, and JSON validation responses
- llm-mock-server: all 23 concrete behaviors plus `random` with seed and weights
- llm-mock-server: sequence exhaustion and `repeatLast`
- llm-mock-server: request records with headers, body, chunks sent, outcome
- llm-mock-server: CLI flags, `connection_refused` start delay, ready/unavailable lines, signal exit codes
- remote-mock: endpoint-named unary and stream mocks with unmatched-call reporting (catalog)
- client-runtime: jsdom slot bench and whole-client fixture (catalog)
- python-sdk-tests: fake JSON-RPC peer pattern with request log (catalog)
- python-sdk-tests: account sign-out projection against the built runtime in replay mode (catalog)
