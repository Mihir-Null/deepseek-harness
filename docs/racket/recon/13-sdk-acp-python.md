# Recon 13: out-of-process interfaces (SDK JSON-RPC, TypeScript client, Python SDK, runtime wheel, ACP)

Pinned commit `e8f7b93a3` (dsh 0.2.2-rc.2). All paths are relative to the repository root. Line numbers refer to that commit.

## Scope

Depth: `packages/sdk/*`, `packages/acp/acp`, the three bundles, `python/sdk` and `python/sdk-runtime` are covered in depth. `packages/subagent/subagent-dsh-sdk`, `python/sdk/src/deepseek_harness/office.py`, the Python examples and the two snapshot corpora are covered at catalog depth.

| Directory | Package / module | Role | Source lines (no tests) |
|---|---|---|---|
| `packages/sdk/protocol` | `@deepseek-ai/dsh-sdk-protocol` | Pure library: newline-delimited JSON-RPC 2.0 transport class plus the named wire types. No plugin. | 571 (`transport.ts` 286, `types.ts` 242, `index.ts` 43) |
| `packages/sdk/server` | `@deepseek-ai/dsh-sdk-jsonrpc-server` | Function plugin `sdk-jsonrpc-server`: serves the SDK protocol on stdio, owns one Agent per `sessionId`. | 1049 (`server.ts` 605, `query-activity.ts` 161, `index.ts` 104, `user-questions.ts` 78, `query-content.ts` 74, `query-input.ts` 27) |
| `packages/sdk/client` | `@deepseek-ai/dsh-sdk-client` | Pure library: spawns `dsh --profile sdk`, low-level `HarnessClient`, high-level `DeepSeekHarness` / `HarnessSession`. | 1425 (`client.ts` 661, `api.ts` 383, `launch.ts` 157, `dispose.ts` 99, `types.ts` 91, `index.ts` 34) |
| `packages/acp/acp` | `@deepseek-ai/dsh-acp` | Function plugin `acp`: Agent Client Protocol v1 server on stdio (automation only), built on `@agentclientprotocol/sdk` 1.4.0. | 1781 (`session.ts` 532, `index.ts` 529, `content.ts` 237, `model-control.ts` 194, `mcp.ts` 143, `updates.ts` 111, `codec.ts` 35) |
| `packages/bundle/sdk-app` | `@deepseek-ai/dsh-sdk-app` | Bundle for the `sdk` profile: startup plugin `sdk-app-startup` (argv parse, stdin-EOF exit) plus a `cordis.patch.yml` layered over `dsh-base`. | 62 TS + 87-line patch |
| `packages/bundle/sdk-minimal` | `@deepseek-ai/dsh-sdk-minimal` | Bundle for the `sdk-minimal` profile: a complete standalone Cordis tree (no `dsh-base`). Patch only. | 9 TS + 179-line patch |
| `packages/bundle/acp-app` | `@deepseek-ai/dsh-acp-app` | Bundle for the `acp` profile: startup plugin `acp-app-startup` plus a patch over `dsh-base`. | 48 TS + 23-line patch |
| `packages/subagent/subagent-dsh-sdk` | `@deepseek-ai/dsh-subagent-dsh-sdk` | Subagent provider `dsh-sdk`: runs each child as a separate `dsh --profile sdk` process through the TS client. Catalog depth. | 561 (`run.ts` 376, `index.ts` 185) |
| `python/sdk` | dist `deepseek-harness-sdk`, module `deepseek_harness` | Synchronous Python client: `HarnessClient`, `DeepSeekHarness`, `Session`, Office CLI wrappers. | 1447 (`client.py` 735, `api.py` 335, `office.py` 219, `models.py` 107, `__init__.py` 28, `errors.py` 23); examples 442; tests about 8,000 |
| `python/sdk-runtime` | dist `deepseek-harness-runtime-bin`, module `deepseek_harness_runtime` | Platform wheel that carries the single-file `dsh` executable; locator, download helpers, `dsh` console script. | 338 Python + `hatch_build.py` 108 + `runtime-bootstrap.mjs` 112 |
| `python/README.md`, `python/development.md` | docs | Package map and contributor workflows (build, validate, release). | n/a |
| `snapshots/sdk` | test corpus | 41 scenario directories plus `sdk.snapshot.ts` (1779 lines): recorded sessions replayed through the real `sdk` / `sdk-minimal` profile and the TS client. | n/a |
| `snapshots/acp` | test corpus | 9 scenario directories plus `acp.snapshot.ts` (92 lines): scripted ACP wire sessions with exact expected stdout. | n/a |

Out-of-area code that this area depends on and that an implementer must also read: `packages/boot/cmdline/src/index.ts` (`parseCmdline`, `exitOnStdinEnd`), `apps/cli/src/args.ts` (launcher argv), `apps/cli/src/process-shutdown.ts`, `packages/util/official-bundles/src/bundles.ts` (profile templates), `packages/interaction/commands/src/{types,builtin}.ts`, `packages/interaction/user-questions/src/types.ts`, `packages/interaction/user-approval/src/types.ts`.

## Services

This area defines no ordinary `ctx.<key>` capability service. It provides three readiness markers and consumes many services owned elsewhere.

### Markers provided

| Key | Provider | Value | Purpose |
|---|---|---|---|
| `sdkAppStartup` | `sdk-app-startup` (`packages/bundle/sdk-app/src/index.ts:59`) | `{ accepted: true }` | Published from the commander action after a successful argv parse. The `sdk-jsonrpc-server` row declares `inject: [sdkAppStartup, loader]`, so `--help` or a usage error never mounts the transport. |
| `acpAppStartup` | `acp-app-startup` (`packages/bundle/acp-app/src/index.ts:45`) | `{ accepted: true }` | Same gate for the `acp` row (`inject: [acpAppStartup]`). |
| `sdkSessionActivation` | `sdk-jsonrpc-server` (`packages/sdk/server/src/index.ts:64`) | `{ ready: true }` | Published once the server has installed its `schedule/resolve-agent` listener. The `schedule` row in the `sdk` profile declares `inject: [sdkSessionActivation]`, so reminders are delivered through the SDK session owner. |

All three are provided with `ctx.provide(name, value)` inside `apply`, so they disappear when the providing fiber is disposed.

### Services consumed

`sdk-jsonrpc-server` (`inject = ['agents', 'workingDirectory']`):

- `ctx.agents.create({ sessionId, meta: { cwd }, agentOptions })`, `ctx.agents.resume({ resumeSessionId, agentOptions, setup })`, `ctx.agents.get(id)`. Each returns an `AgentHandle { agent, dispose() }`; `agent` exposes `id`, `session` (`id`, `seq`, `header`), `status` (`'idle' | 'running'`), `followup(message)`, `whenIdle()`, `model.current()`, `model.select(selection)`.
- `ctx.workingDirectory.ensure(agent)` and `.set(agent, path)`, both returning an absolute path.
- Optional, read with `ctx.get(name)`: `loader` (`.await()`), `llm` (`listProviders()`, `resolveCallConfig()`), `attachments` (used by `admitEncodedImages`), `commands` (`list(agent)`, `execute(agent, line, attachments, signal)`), `subagents` (`rootOf(agent)`, `waitForTreeWork(agent)`, `drainDescendants(agents)`), `sessionPersistence` (`stat(id)`), `goals` (`get(agent)`), `logger`.

`acp` (`inject = ['agents', 'llm', 'sessionPersistence', 'sessions']`):

- `ctx.agents.create/resume/get`, `ctx.llm.listProviders/listModels/resolveModelInfo/resolveCallConfig`, `ctx.sessionPersistence.stat/list`, `ctx.sessions.get/flush`.
- Optional: `attachments` (`imageLimits.mediaTypes`, `saveImages`, `readImage`), `tokenMeter` (`measure(session).totalTokens`), `subagents`.

`sdk-app-startup` and `acp-app-startup` (`inject = ['cmdlineArgs']`): read `cmdlineArgs`, `appExit`, `appReady` through `ctx.get`.

`subagent-dsh-sdk` (`inject = ['subagents']`): calls `ctx.subagents.registerProvider(provider)`.

### Ownership rules

- The SDK server owns exactly the Agents it created or resumed, keyed by wire `sessionId` in `sessions: Map<string, SessionRecord>` where `SessionRecord = { handle, failure }`. Ownership checks always compare the live registry entry with the retained instance (`ctx.agents.get(agent.id) === agent`), never ids alone (`server.ts:390-412`).
- A descendant subagent is "owned" for approval routing when `subagents.rootOf(agent)` is an exact SDK-owned root instance. A `rootOf` failure with `name === 'SubagentError'` and `code === 'UNAUTHORIZED'` means "not mine" (delegate with `next()`); any other failure propagates.
- User questions are forwarded only for exact owned root Agents, not for descendants (`server.ts:142-143`).
- The ACP bridge owns one `AcpSession` per ACP session id; `owns(agent)` and `ownsSession(session)` are identity comparisons.

## Events

This area declares no new Cordis event. It listens to these (all owned by other packages):

| Event | Mode | Payload | Listener in this area | Effect |
|---|---|---|---|---|
| `session/event` | emit | `(session, event)` | SDK server | Writes `session.event` notification `{ sessionId, event }` for every session in the runtime. Also clears `record.failure` when `event.type === 'turn/end'` on the owned session and `event.seq >= failure.atOffset`. |
| `session/event` | emit | same | `QueryActivity` (one per in-flight command query) | Tracks `command/run`, `agent/inbox/spliced`, `goal/change`, `assistant/message`, `turn/end` for one Agent. |
| `session/event` | emit | same | ACP bridge | Routes to the owning `AcpSession.onSessionEvent`. |
| `agent/status` | emit | `{ agent, status }` | SDK server | Writes `session.status` `{ sessionId, status }` for every Agent. `QueryActivity` re-checks completion. ACP uses it to finish a cancelled prompt. |
| `agent/error` | emit | `{ agent, turn, step, error }` | SDK server | Sets `record.failure = { error, atOffset: agent.session.seq }` for an owned Agent. `QueryActivity` sets `turnReason = 'error'`. ACP records `agentError`. |
| `agent/disposed` | emit | `{ agent }` | `QueryActivity` | Finishes with `('error', 'The Session Agent was disposed before the input finished.')`. |
| `agent/inbox/claimed` | emit | `{ agent, message, turn }` | ACP | Correlates the in-flight prompt's `messageId` with its turn number. |
| `session/created` | emit | `(session)` | SDK server | When `session.header.origin === 'subagent'` and `header.parentSession` is defined, writes `subagent.started`. |
| `subagent/end` | emit | `SubagentRunEndInfo` (`local`, `provider`, `id`, `parentSessionId`, `stopReason`, `lastAssistantMessage?`) | SDK server | When `info.local` is true, writes `subagent.finished`. |
| `approval/request` | waterfall | `(request, next)`, request = `{ agent, toolName, callId?, reason?, displayReason?, signal? }`, result `'allowed-once' | 'rejected' | 'cancelled' | 'unavailable'` | SDK server, ACP | Answer from the client or delegate with `next()`. |
| `user-questions/request` | waterfall | `(request, next)`, request = `{ questions, agent?, signal?, wait? }`, result `{ answers }` | `SdkUserQuestionBridge` | Forward to the client as `user-question/ask` or delegate. |
| `schedule/resolve-agent` | waterfall | `(sessionId, next)` returning an Agent | SDK server | Always claims: waits for `initialize`, then returns the owned Agent or restores the session with `openSession(sessionId, true)`. |
| `goal/activation-changed` | emit | `{ sessionId, goal? }` | `QueryActivity` | When the tracked goal becomes `activation === 'disarmed'` while still `phase === 'active'`, marks `goalStopped`. |
| `llm/adapters-updated` | emit | none | ACP | Every session republishes its config options. |

Ordering guarantees that the wire inherits:

- `session.event` notifications are written synchronously in the `session/event` listener, so wire order equals commit order per session, and events of different sessions interleave in commit order.
- A request's response is written when its handler resolves. Any notification emitted before that point precedes the response on the pipe. `session/wait` relies on this: every notification committed during the wait precedes its `{}` response.
- `session.query.completed` may precede or follow the `session/query` response; `command/run` and `command/done` for that command always precede the response.

## Tools

None. No package in this area registers a model-facing tool. The bundles only compose tools owned elsewhere:

- `sdk` profile: the full `dsh-base` roster plus `tool-office`, `tool-workspace-dependencies` (only with `DSH_PRIMARY_RUNTIME`), `tool-schedule`, `tool-ask-user`, `tool-present`, and `tool-plugin-manager` (enabled by this bundle).
- `sdk-minimal` profile: exactly `bash` (or `pwsh` on Windows), `read_image`, `working_directory`. The bundle overrides the persistent shell tool description. Exact text for bash (`packages/bundle/sdk-minimal/cordis.patch.yml:149-156`):

```
Run commands in a bash shell
* When invoking this tool, the contents of the "command" parameter does NOT need to be XML-escaped.
* Network access depends on the task environment. Prefer configured mirrors/proxies when they are available.
* State is persistent across command calls and discussions with the user.
* To inspect a particular line range of a file, e.g. lines 10-25, try 'sed -n 10,25p /path/to/the/file'.
* Please avoid commands that may produce a very large amount of output.
* Please run long lived commands in the background, e.g. 'sleep 10 &' or start a server in the background.
```

Exact text for pwsh (same file, lines 163-170):

```
Run commands in a PowerShell shell
* When invoking this tool, the contents of the "command" parameter does NOT need to be XML-escaped.
* You don't have access to the internet via this tool.
* State is persistent across command calls and discussions with the user.
* Use native Windows paths (C:\...) and $env:NAME variables; this is PowerShell, not bash.
* Please avoid commands that may produce a very large amount of output.
* Please run long lived commands in the background, e.g. 'Start-Job' or start a server with Start-Process.
```

The Python SDK cannot define tools or hooks in Python. See "Python SDK public API" under Formats.

## Configuration

### `@deepseek-ai/dsh-sdk-jsonrpc-server`

Function plugin. Exports `name = 'sdk-jsonrpc-server'`, `inject = ['agents', 'workingDirectory']`, `Config`, `apply`; no default export (a default export would make the Loader drop the namespace).

| Field | Type | Default | Meaning |
|---|---|---|---|
| `maxTokensAsSuccess` | boolean | `false` | Report a `max-tokens` subagent stop reason as `status: 'ok'` in `subagent.finished`. Only that mapping reads it (`successStatus`, `server.ts:79-82`). |
| `input`, `output`, `exit` | runtime-only hooks | `process.stdin`, `process.stdout`, `process.exit` | Not in the schema; tests inject them. |

### `@deepseek-ai/dsh-sdk-app`

Function plugin. `name = 'sdk-app-startup'`, `inject = ['cmdlineArgs']`.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `profile` | string | `'sdk'` | Profile name rendered in the command name `dsh --profile <profile>` and help text. |

Command grammar: zero options except `-h, --help` (`'show this help'`). Description: `Serve DeepSeek Harness SDK clients over stdio JSON-RPC.` Help epilogue: `Example:\n  dsh --profile <profile>     serve one SDK runtime until its client disconnects`. Any extra inner argument is a commander usage error, which writes to stderr and calls `ctx.appExit(exitCode)`.

Bundle patch (`packages/bundle/sdk-app/cordis.patch.yml`), applied over `dsh-base`, in order:

1. `system-prompt` config `personaPrefix: "You are a coding agent powered by the {{model}} model."`
2. `session-title-llm` disabled.
3. Insert `sdk-app-startup` (`@deepseek-ai/dsh-sdk-app`, config `profile: sdk`) and `sdk-jsonrpc-server` (`@deepseek-ai/dsh-sdk-jsonrpc-server`, `inject: [sdkAppStartup, loader]`, config `maxTokensAsSuccess: !!js "process.env.DSH_MAX_TOKENS_AS_SUCCESS === undefined ? true : JSON.parse(process.env.DSH_MAX_TOKENS_AS_SUCCESS)"`).
4. `hmr` disabled.
5. `tool-plugin-manager` `disabled: false`.
6. Insert `office-kit` (`outputDirectory: !!js dshHomePath('office-kit', 'outputs')`), `tool-office`, `workspace-dependencies` (`disabled: !!js "!process.env.DSH_PRIMARY_RUNTIME"`, `source` = resolved `DSH_PRIMARY_RUNTIME`), `skill-office` (`pythonEnvironment` = `'workspace-dependencies'` when `DSH_PRIMARY_RUNTIME` is set, else `'user'`).
7. Insert `connection` (`dsh-client-connection`), `file-upload` (`dsh-client-file-upload`), `workspace` (`dsh-workspace`), `schedule` (`dsh-schedule`, `inject: [sdkSessionActivation]`), `time-context`, `tool-schedule`, `tool-ask-user`, `present` (`dsh-tool-present`), `file-reference-local`, `deliverable-file-references`.

### `@deepseek-ai/dsh-sdk-minimal`

No plugin code (`export {}`). The patch is one `insert` list that is the whole tree, in this order (id → package, notable config):

`sdk-app-startup` (`profile: sdk-minimal`), `sdk-jsonrpc-server` (`inject: [sdkAppStartup, loader]`, `maxTokensAsSuccess: false`), `deepseek-llm-api-extensions`, `session-log-deepseek`, `plugin-package-inventory-deepseek`, `llm-deepseek` (`dsh-llm-deepseek-api-key`: `apiKeyEnv: DEEPSEEK_API_KEY`, `defaultContextWindow: !!js Number(process.env.DSH_CONTEXT_WINDOW ?? 1000000)`, `streamIdleTimeoutMs: 172800000`), `sandbox` (`dsh-sandbox-local`), `filesystem` (`dsh-fs-local`), `attachment-local`, `tool-fs` (`read: false, readImage: true, write: false, edit: false`), `working-directory`, `tool-working-directory`, `session-projection`, `token-meter`, `compaction-basic`, `image-offload` (`dsh-compaction-image-offload`), `sandbox-policy` (`mode: danger-full-access`, `workspaceRoot: !!js process.cwd()`), `subprocess` (`dsh-subprocess-local`), `pty` (`dsh-terminal`), `terminal-bash` (`dsh-terminal-bash`, disabled on win32, `timeoutMs: 300000`), `terminal-pwsh` (`dsh-terminal-bash`, disabled off win32, `shellDialect: pwsh`, `timeoutMs: 300000`), `timer` (`cordis-plugin-timer`), `llm`, `session`, `session-title` (`fallbackMaxWords: 5`, `fallbackMaxBytes: 40`, `maxTitleBytes: 80`), `system-prompt` (`includeHarnessIdentity: false`, `includeRuntimeContext: false`, `personaPrefix: !!js process.env.DSH_SYSTEM_PROMPT ?? 'You are a helpful software engineer assistant.'`), `tools`, `tool-executor-native`, `mcp-resources`, `agent`, `llm-retry`, `jobs` (`dsh-jobs-local`), `agent-loop` (`agents: []`), `persistent-bash` (`dsh-tool-bash-persistent`, disabled on win32, `timeoutMs: 300000`, description above), `persistent-pwsh` (`dsh-tool-pwsh-persistent`, disabled off win32, `timeoutMs: 300000`), `sessions` (`dsh-session-persistence-jsonl`: `root: !!js dshHomePath('sessions')`, `compression: none`), `session-checkpoint-policy`.

There is no `commands` service in this tree, so `session/query` never routes a slash command there.

### `@deepseek-ai/dsh-acp-app`

Function plugin. `name = 'acp-app-startup'`, `inject = ['cmdlineArgs']`, no config. Command name `dsh --profile acp`, description `Serve automation clients over Agent Client Protocol stdio.`

Bundle patch over `dsh-base`: `system-prompt.personaPrefix` as for sdk; `session-title-llm` disabled; insert `acp-app-startup` and `acp` (`@deepseek-ai/dsh-acp`, `inject: [acpAppStartup]`, config `provider: deepseek-official`, `model: deepseek-v4-flash`); `hmr` disabled.

### `@deepseek-ai/dsh-acp`

Function plugin. `name = 'acp'`, `inject = ['agents', 'llm', 'sessionPersistence', 'sessions']`.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `provider` | string | none | Provider route for created Agents. |
| `model` | string | none | Model for created Agents. |
| `sessionListPageSize` | natural, min 1 | `100` | Page size of `session/list`. |
| `stream` | runtime-only | stdio ndjson | Test transport override. |

### `@deepseek-ai/dsh-subagent-dsh-sdk` (catalog)

Function plugin. `name = 'subagent-dsh-sdk'`, `inject = ['subagents']`.

| Field | Type | Default |
|---|---|---|
| `providerName` | string | `'dsh-sdk'` |
| `dshBin` | string | none (resolved to an existing file at load) |
| `profile` | string | `'sdk'` |
| `patches` | string[] | `[]` (each resolved to an existing file at load) |
| `dshHome` | string, required, absolute | none |
| `provider` | string | `'deepseek-official'` |
| `model` | string | `'deepseek-v4-flash'` |
| `maxTokens` | integer 1..MAX_SAFE_INTEGER | none |
| `env` | dict of string | `{}` (merged over `scrubbedParentEnv()`) |
| `shutdownTimeoutMs` | number, positive finite | `1000` |
| `disposeEofGraceMs` | number, positive finite | `6000` |
| `disposeGraceMs` | number, positive finite | `3000` |

Load-time failures: `subagent-dsh-sdk <field> must name an existing file: <path>`, `subagent-dsh-sdk dshHome must be an absolute path`, `subagent-dsh-sdk maxTokens must be a positive safe integer`.

### Shipped profile templates

`packages/util/official-bundles/src/bundles.ts`: `sdk` = `['@deepseek-ai/dsh-base', '@deepseek-ai/dsh-sdk-app']`, `sdk-minimal` = `['@deepseek-ai/dsh-sdk-minimal']`, `acp` = `['@deepseek-ai/dsh-base', '@deepseek-ai/dsh-acp-app']`. On first use the launcher writes `$DSH_HOME/profiles/<name>/package.json` with `dsh.profile.bundles` equal to that list (a Python test asserts it).

## Formats

### 1. SDK transport and framing

Source: `packages/sdk/protocol/src/transport.ts`.

- Bytes: UTF-8. One JSON-RPC 2.0 object per line, terminated by `\n`. The writer emits `JSON.stringify(message) + "\n"`. The reader splits on `\n`, trims each line (so `\r\n` is tolerated), and skips empty lines. Multibyte characters split across chunks are reassembled.
- Stdin carries client-to-server frames, stdout carries server-to-client frames, stderr carries diagnostics only. Nothing else may be written to stdout. There is no banner and no length prefix.
- Frame classification (`handleLine`, lines 207-230): `id` (string or number) and `method` (string) → request; `id` only → response; `method` only → notification; anything else is ignored. A line that is not valid JSON or not an object is ignored silently.
- `params` is normalized: anything that is not a plain object (missing, array, scalar) becomes `{}`.
- Response: `{"jsonrpc":"2.0","id":<same id>,"result":<value>}` or `{"jsonrpc":"2.0","id":<same id>,"error":{"code":<int>,"message":<string>}}`. The id is echoed with its original type.
- Ids generated by this transport for its own outbound requests: `req_` + 32 lowercase hex characters. The Python client generates `str(uuid4())` (with dashes) and looks responses up by `str(id)`. The smoke script uses literal ids such as `"initialize"`. The server must echo any string or number id.
- A notification without params has no `params` member.
- Each inbound line is handled as an independent asynchronous task, so requests run concurrently and responses may be written out of request order.
- On input end the transport drains complete lines, then fails every pending outbound request with `JSON-RPC input closed`. A trailing fragment without `\n` is dropped. `close()` fails pending requests with `JSON-RPC transport closed`. The first failure is permanent: later `request()` calls reject immediately.
- `flush()` writes an empty chunk and waits for its callback.

### 2. Error codes

| Code | When | Message |
|---|---|---|
| `-32601` | Transport has no request handler installed. Not reachable on the server after mount. The Python examples answer unknown server requests with it. | `method not found: <method>` |
| `-32603` | Any handler rejection, including unknown method, validation failure, runtime failure. | The thrown error's `message` (or `String(error)`). |
| `-32602` | Sent only by the Python client when it rejects a server request. | `invalid user-question/ask parameters`, `duplicate user-question requestId` |

The server never sends `-32700`, `-32600`, or `-32602`, and never includes `error.data`. Clients preserve `code` and `data` when present (`JsonRpcResponseError(code, message, data)`, Python `JsonRpcError`).

### 3. Handshake and versioning

There is no protocol-version negotiation. `initialize` returns `{ "serverInfo": { "name": "deepseek-harness-sdk-runtime", "version": "0.0.1" } }`. `serverInfo.name` is wire-stable. The TS client requires both `name` and `version` to be strings; the Python client accepts either missing. Neither client checks the values, but `python/sdk/tests/test_bundled_runtime.py` asserts the name.

`initialize` is the only readiness signal. Before dispatching it the plugin awaits `ctx.get('loader')?.await()` so that every sibling Loader entry has settled (`index.ts:86-88`). Every other method except `shutdown` and unknown methods rejects with `SDK server is not initialized` until one `initialize` has succeeded. A second `initialize` is not rejected; it overwrites the stored route (the class comment says reinitialization is unsupported).

### 4. Client-to-server requests

All results are JSON objects.

#### `initialize`

Params (`InitializeParams`):

| Field | Type | Required | Rule |
|---|---|---|---|
| `cwd` | string | yes | Resolved to an absolute path with `path.resolve`. Recorded as `meta.cwd` on every created session. |
| `provider` | string | yes | Provider route id. |
| `model` | string | yes | Model id. |
| `reasoningEffort` | string | no | Non-empty, else `initialize reasoningEffort must be a non-empty string`. |
| `maxTokens` | integer | no | Positive safe integer, else `initialize maxTokens must be a positive safe integer`. |
| `approvalRequests` | boolean | no | Non-boolean → `initialize approvalRequests must be a boolean`. Only `true` enables `approval/request`. |
| `capabilities` | `{ userQuestions?: boolean }` | no | Only `userQuestions === true` enables `user-question/ask`. |

Steps (`server.ts:215-255`): validate; if no registered adapter has `id === provider`, then for `provider === 'deepseek-official'` mount `@deepseek-ai/dsh-llm-deepseek-api-key` as a child plugin (kept as `llmFiber`, disposed at shutdown), otherwise fail with `no adapter registered for provider "<provider>"`; call `llm.resolveCallConfig({ provider, model, reasoningEffort?, maxTokens? })`, which rejects an unavailable model or unsupported effort; store the route; resolve the initialization gate.

Result: `{ serverInfo: { name: 'deepseek-harness-sdk-runtime', version: '0.0.1' } }`.

#### `session/prompt`

Params: `{ sessionId: string, contentBlocks: SdkPromptContentBlock[] }`. Result: `{ messageId: string }`.

No slash-command routing. Steps (`server.ts:262-281`): require initialization; get or create the session; convert inline images; build `createUserMessage({ content, source: { kind: 'user' } })`; `agent.followup(message)`; return the message id at once. The id identifies the queued inbox message only.

Content blocks: any durable `ContentBlock` (for example `{ "type": "text", "text": "..." }`, `{ "type": "image", "attachment": {...} }`) or an inline image `SdkEncodedImageBlock`:

```json
{ "type": "image", "data": "<canonical base64>", "mimeType": "image/png|image/jpeg|image/webp|image/gif", "name": "optional display name" }
```

An image block is "encoded" when it has a `data` member. Encoded images are admitted through `admitEncodedImages(attachments, [{ data, mediaType: mimeType, name? }])` and replaced in place by `{ type: 'image', attachment: <ref> }`, so the log never stores base64. Without an `attachments` service: `SDK image prompt requires an attachment store`.

#### `session/query`

Params: exactly `{ sessionId: non-empty string, contentBlocks: [...] }`; any other key → `session/query requires only a non-empty sessionId and contentBlocks`.

Result: `{ "kind": "prompt", "messageId": "..." }` or `{ "kind": "command", "execution": { "commandId": "...", "result": { "kind": "success", "text"?: string, "sourceEventSeq"?: integer } | { "kind": "error", "text": string } } }`. Optional fields are omitted, never `null` (the Python model rejects `null`).

Content validation (`query-content.ts`), each a `TypeError` returned as `-32603`:

- not an array or empty → `session/query requires a non-empty contentBlocks array`
- block not an object with a string `type` → `SDK content blocks require a string type`
- text block with a non-string `text` or any key besides `type`/`text` → `SDK text blocks require only type and string text`
- image block with `data`: `data` must be a string, `mimeType` one of the four raster types, `name` a string if present, no other keys → `SDK encoded images require string data, a supported mimeType and an optional string name`
- image block without `data` and without an object `attachment` → `SDK image blocks require encoded data or a durable attachment reference`
- every block is a blank text block → `session/query requires non-blank text or non-text content`
- other block types pass through unchanged.

Routing is described under Algorithms.

#### `session/resume`

Params: `{ sessionId: non-empty string }` (else `session/resume requires a non-empty sessionId string`). Result `{}` after the Agent is ready. Errors: `SDK session is already open or opening: <id>`, `subagent session "<id>" cannot be resumed directly; resume its root session instead`, plus whatever `agents.resume` raises for a missing, unreadable, or incompatible log. Never creates a replacement session. Old events are not replayed as notifications; a model-selection event recorded during resume is notified before the response.

#### `session/wait`

Params: `{ sessionId: string }` (else `session/wait requires a sessionId string`). Result `{}`. Errors: `unknown SDK session: <id>` (never creates a session), `session agent was disposed outside the server: <id>`, or the retained live Agent failure.

#### `session/working-directory/get` and `session/working-directory/set`

Params: `{ sessionId: non-empty string }` and `{ sessionId, path: string }`. Errors: `working-directory requests require a non-empty sessionId`, `working-directory set requires a path string`. Result: `{ cwd: <absolute path> }`. Both create an unknown session without starting a turn. `get` calls `workingDirectory.ensure(agent)` (recovers a missing directory to the origin); `set` calls `workingDirectory.set(agent, path)` (relative paths resolve against the session's current directory).

#### `shutdown`

No params (the Python client sends no `params` member; the TS client sends `{}`). Result `{}`. After the response is written the process flushes stdout, disposes the root context, and exits with code 0.

#### Unknown method

`-32603` with message `unknown DeepSeek Harness SDK runtime method: <method>`.

### 5. Server-to-client notifications

| Method | Params | Emitted when |
|---|---|---|
| `session.event` | `{ sessionId, event }` | Every committed session-log event of every session in the runtime (roots, subagents, sessions not created by the SDK). `event` is the full envelope: `{ "type", "seq", "time", "data", "surfaceOp"? , ... }`. |
| `session.status` | `{ sessionId, status: "idle" | "running" }` | Every whole-agent status transition of every Agent. |
| `session.query.completed` | `{ sessionId, commandId, finishReason, finalResponse }` | Once per command query that received a `commandId`, when its activity ends. |
| `subagent.started` | `{ parentSessionId, childSessionId }` | A session is created with `header.origin === 'subagent'` and a `header.parentSession`. |
| `subagent.finished` | `{ provider, agentId, parentSessionId, childSessionId, status: "ok" | "error", stopReason, lastAssistantMessage? }` | An in-process (`info.local`) subagent run ends. `agentId === childSessionId === String(info.id)`. `status` is `ok` for `completed`, and for `max-tokens` when `maxTokensAsSuccess`. `stopReason` ∈ `completed | aborted | error | max-tokens | refusal` (merge-extensible). `lastAssistantMessage` is a content-block array, omitted when the child produced no output. |
| `user-question.cancelled` | `{ requestId, sessionId }` | A pending `user-question/ask` was aborted by tool cancellation or server shutdown. |

Session events the clients read by field (the rest pass through opaque):

- `agent/inbox/spliced`: `data.inserted[]` each with `id` (the prompt receipt), `source.kind`.
- `command/run`: `data.commandId` (also `data.name`); `command/done`: `data.commandId`, `data.kind`, `data.text?`, `data.sourceEventSeq?`.
- `assistant/message`: `data.message.content[]` blocks with `type`; text blocks carry `text`. `data.turn`, `data.message.id`, `data.usage?`.
- `turn/end`: `data.turn`, `data.reason.kind` ∈ `completed | max-tokens | aborted | interrupted | blocked | error | ...`; for `aborted`, `data.reason.reason.kind` ∈ `user | parent | disposed | legacy | hook` and `hook` carries a string `reason`.
- `goal/change`: `data.operation`, `data.goal.{id,phase}`, `data.cleared.id`.

### 6. Server-to-client requests

`approval/request` (only after `initialize.approvalRequests === true`):

- Params: `{ sessionId, toolName, callId?, reason? }`. `sessionId` is the session of the asking Agent, which may be an owned descendant.
- Result: `{ "outcome": "allowed-once" | "rejected" | "cancelled" }`. Anything else makes the listener throw `approval/request response requires an allowed-once, rejected, or cancelled outcome`; the approval service then records `unavailable` (fail closed). A JSON-RPC error or lost transport has the same effect.
- Cancellation: the pending wire waiter is abandoned when the request's signal or the server lifetime aborts. No cancel notification is sent for approvals. Late replies are ignored.

`user-question/ask` (only after `initialize.capabilities.userQuestions === true`, only for exact owned root Agents):

- Params: `{ requestId: <uuid>, sessionId, questions: AskUserQuestionItem[] }`. Each question: `{ id, question, detail?, header?, options?: [{ label, description? }], multiSelect?, intent? }`. `intent` is `{ kind: 'plan-review', approve, callId? }` or `{ kind: 'approval', approve, reject, always?, subject?, display? }`.
- Result: `{ "answers": [{ "id", "selected": [string], "custom"?: string }] }` with every question id exactly once, or exactly `{ "cancelled": true }`.
- Mapping to `UserQuestionError` codes (`user-questions.ts`): `{cancelled:true}` → `ASK_CANCELLED` (`The user dismissed the SDK question`); malformed answers → `BAD_ANSWER` (`SDK host must answer each question id exactly once with selected labels and optional custom text`); JSON-RPC error or transport loss → `PROVIDER_ERROR` (`SDK host could not answer the user question`); abort → `ASK_ABORTED` (`SDK user question was cancelled`, or `SDK server is shutting down`).
- On abort the server sends `user-question.cancelled` and abandons the waiter.

### 7. Executable contract required by the Python client

This is what a Racket `dsh` must satisfy so that `DeepSeekHarness(dsh_bin="/path/to/racket-dsh", dsh_home=...)` works unchanged.

argv (`client.py:588-616`):

```
<dsh_bin resolved absolute> --profile <profile> [--patch <abs path>]...
```

- `dsh_bin` is executed directly as `argv[0]` (no interpreter prefix), after `Path(...).expanduser().resolve()`.
- `profile` defaults to `sdk`. Patches are made absolute and passed in order, one `--patch` each.
- Without `dsh_bin` the client calls `deepseek_harness_runtime.resolve_bundled_launch_args()` and prepends its tuple: `(exe,)` or `(node, runtime-bootstrap.mjs)`.
- Launcher rules that apply (`apps/cli/src/args.ts`): launcher flags come first; `--profile` may appear once; `--patch` is repeatable and single-valued; the first unknown token starts the app's own arguments; `dsh <name>` abbreviates `dsh --profile <name>`. The SDK app accepts no inner arguments except `-h/--help`.

Environment:

- Base is a copy of the parent environment, then `config.env` is merged over it. (The TS client instead replaces the environment entirely when `env` is given.)
- `DSH_HOME` is set to the resolved `dsh_home`. If `dsh_home` is `None`, a non-blank `DSH_HOME` must already be in the merged environment, otherwise `ValueError` before spawn. A blank `dsh_home` is a `ValueError`.
- `DeepSeekHarness` additionally sets `DEEPSEEK_BASE_URL` from `base_url` and `DEEPSEEK_API_KEY` from `api_key`.
- Tests and examples also pass `DSH_PERMISSION_MODE` (`danger-full-access`, `workspace-write`, `read-only`), `DSH_TELEMETRY_DISABLED=1`, `DSH_TOOLS_MODE=native`; these are read by `dsh-base` rows, not by this area.

Process:

- `cwd` = resolved `runtime_cwd`, else resolved workspace `cwd`.
- stdin, stdout, stderr are pipes; text mode, UTF-8, line buffered. Each request is `json.dumps(message, separators=(",", ":")) + "\n"` followed by a flush. Python's default `ensure_ascii=True` means non-ASCII arrives as `\uXXXX` escapes, including surrogate pairs.
- The reader thread iterates stdout lines, skips blank lines and lines that are not JSON, and dispatches the rest. Both clients ignore stray non-JSON stdout lines, but a stray line that happens to parse as a JSON object with `id` or `method` would be misread, so keep stdout clean.
- stderr is read continuously; the last 400 lines are kept and appended to timeout and transport errors as `exit code: N` and `stderr tail:\n...`.

Readiness: none besides the `initialize` response. The client writes `initialize` immediately after spawn, so the server must not lose bytes that arrive on stdin before its transport is mounted. Default bound: 30 s in Python (`initialize_timeout_seconds`), 10 s in TypeScript (`DEFAULT_INITIALIZE_TIMEOUT_MS`). On failure Python closes the runtime and re-raises; a timeout message ends with `selected dsh profile '<profile>'`.

Startup failure: a misconfigured profile (for example a patch that inserts `@deepseek-ai/dsh-does-not-exist`) must make `initialize` fail with a JSON-RPC error, or exit with the plugin name on stderr. `test_bundled_runtime.py` asserts that the missing package name appears in the raised error text.

Shutdown sequence the client performs (`client.py:103-149`):

1. Request `shutdown` with a bound of `shutdown_timeout_seconds` (default 1.0 s). Failure is only recorded as a stderr-tail line.
2. Close stdin.
3. If shutdown was answered, wait up to the same bound for exit.
4. If still alive, `terminate()` (SIGTERM), wait the same bound, then `kill()`.

So the server must: answer `shutdown` with `{}` and then exit 0; also exit 0 on stdin EOF after startup has committed (`exitOnStdinEnd`), within the launcher's 5 s bounded shutdown (`PROCESS_SHUTDOWN_TIMEOUT_MS`); treat SIGTERM as an ordinary stop (exit 0) and SIGINT as exit 130 (`apps/cli/src/profile-boot.ts:320-321`). A startup failure exits 1 with diagnostics on stderr.

Requirements that `Session.run()` places on the notification stream:

- Ordinary prompt: a `session.event` for the same `sessionId` whose `event.type` is `agent/inbox/spliced` and whose `data.inserted[]` contains `{ "id": <messageId> }`, later followed by `session.status` `idle` for that session. Notifications before the receipt are ignored. Without the receipt the call never returns.
- Command: a `session.event` `command/run` with `data.commandId`, a `command/done` with the same id, and one `session.query.completed` with the same `sessionId` and `commandId`, a string `finalResponse`, and a non-empty string `finishReason`. If the completion is read before `command/done` was recorded, the client drains already-queued notifications without blocking; if `command/done` is still missing it raises `SdkProtocolError("Command completion is missing matching lifecycle events")`.
- The last `turn/end` in the interval must have a string `data.reason.kind`.

### 8. TypeScript client API (`@deepseek-ai/dsh-sdk-client`)

Exports: `DeepSeekHarness`, `HarnessSession`, `validatedSessionEvent`, `HarnessClient`, `RequestTimeoutError`, `SdkProtocolError`, `TransportClosedError`, `JsonRpcResponseError`, and types `RunOptions`, `NotificationSubscription`, `ContentBlock`, `SdkEncodedImageBlock`, `SdkPromptContentBlock`, `SdkUserQuestionAnswer`, `SdkUserQuestionResult`, `SdkUserQuestionRequest`, `DeepSeekHarnessOptions`, `HarnessClientOptions`, `HarnessNotification`, `NotificationFilter`, `RunResult`.

`HarnessClientOptions`: `onUserQuestion?(request, { signal }) => Promise<SdkUserQuestionResult>`, `dshBin?`, `profile?` (default `sdk`), `patches?`, `dshHome?`, `processCwd?`, `env?` (replaces the whole environment), `initializeTimeoutMs?` (10000), `requestTimeoutMs?` (unbounded), `shutdownTimeoutMs?` (1000), `disposeEofGraceMs?` (6000), `disposeGraceMs?` (3000).

`DeepSeekHarnessOptions` adds: `cwd?` (default `processCwd`, else `process.cwd()`; made absolute), `provider?` (`deepseek-official`), `model?` (`deepseek-v4-flash`), `reasoningEffort?`, `maxTokens?`, `approvalRequests?`.

Launch (`launch.ts:128-157`): `command = process.execPath` (Node); `args = [...nodeArgs, '--profile', profile, ...patches.flatMap(p => ['--patch', p])]`. `nodeArgs` is `[resolve(dshBin)]` when given; else the installed `@deepseek-ai/dsh` package's `bin.dsh` after a same-version check (`dsh SDK client <v> requires the same dsh version, got <v2>`); when the built bin does not exist, the source launch `['--import', <tsx/esm loader URL>, <pkg>/src/bin.ts]` with the extra patch `<pkg>/src/sdk-source.cordis.patch.yml` (disables `typert-loader`) placed before caller patches and env `TSX_TSCONFIG_PATH=<pkg>/tsconfig.json`. `DSH_HOME` is set only when `dshHome` is given (the TS client does not require it).

`HarnessClient`: `start()`, `onRequest(handler)` (after `start`, before `close`), `initialize(params)` (adds `capabilities.userQuestions: true` when `onUserQuestion` is set), `prompt(sessionId, blocks) → messageId`, `resumeSession(id)`, `getWorkingDirectory(id)`, `setWorkingDirectory(id, path)`, `request(method, params?, timeoutMs?)`, `subscribe(filter?)`, `subscribeSessionTree(id)`, `close()`. `NotificationSubscription`: `next()`, `tryNext()`, `close()`, async iteration.

`DeepSeekHarness`: `client`, `start()` (memoized handshake; on failure closes the client, installs a fresh one, rethrows; if cleanup also fails throws `AggregateError([initError, cleanupError], 'DeepSeek Harness initialization and cleanup failed')`), `session(id?)` (fresh id `session-<32 hex>`), `resumeSession(id)`, `run(input, { sessionId?, onNotification? })`, `close()`, `[Symbol.asyncDispose]`.

`HarnessSession`: `id`, `harness`, `getWorkingDirectory()`, `setWorkingDirectory(path)`, `run(input, { onNotification? }) → RunResult { sessionId, finalResponse, finishReason: string | null, events, notifications }`.

Close ladder (`client.ts:493-510`, `dispose.ts`): request `shutdown` (bounded); end stdin and wait `disposeEofGraceMs`; on POSIX send SIGTERM and wait `disposeGraceMs`; send SIGKILL and wait `disposeGraceMs`. If no exit edge arrives, `close()` rejects with `runtime process did not exit within <ms>ms after SIGKILL was accepted` (or `refused`). Windows skips SIGTERM. `close()` is permanent: a closed `HarnessClient` refuses `start()`.

Server requests on the TS client: `user-question/ask` goes to `onUserQuestion` (missing callback, malformed params, or a duplicate `requestId` reject, which the transport returns as `-32603`); every other method goes to the `onRequest` handler, or rejects with `unknown runtime request: <method>` when none is installed.

Errors: `TransportClosedError` message is `<description>: <reason>` plus optional lines `spawn error: ...`, `exit code: N`, `stderr tail:\n...` where description is `dsh profile "<profile>"`. `RequestTimeoutError`: `<method> timed out after <ms>ms waiting for dsh profile "<profile>"` plus the stderr tail.

### 9. Python SDK public API (`deepseek_harness`)

Everything is synchronous and thread based. There is no asyncio API.

`__all__`: `DeepSeekHarness`, `DeepSeekHarnessConfig`, `Session`, `RunResult`, `HarnessClient`, `HarnessConfig`, `UserQuestionHandler`, `UserQuestionRequest`, `UserQuestionAnswer`, `UserQuestionAnswerItem`, `SdkProtocolError`, `ApprovalRequestParams`, `ApprovalRequestResult`, `IncomingRequest`, `InitializeResponse`, `JsonObject`, `Notification`, `ServerInfo`. Importable but not in `__all__`: `errors.HarnessError`, `errors.TransportClosedError`, `errors.JsonRpcError(code, message, data)`, `client.NotificationSubscription`, `models.CommandExecution`, `api.final_response`, `api.finish_reason`, and the `office` module.

`HarnessConfig` (dataclass): `dsh_bin: str | None = None`, `profile: str = "sdk"`, `patches: tuple[str, ...] = ()`, `dsh_home: str | None = None`, `cwd: str | None = None` (process cwd), `env: dict[str, str] | None = None`, `initialize_timeout_seconds: float = 30.0`, `request_timeout_seconds: float | None = None`, `shutdown_timeout_seconds: float | None = 1.0`, `on_user_question: UserQuestionHandler | None = None`.

`DeepSeekHarnessConfig` (dataclass, positional order matters; a test pins the first five): `provider = "deepseek-official"`, `model = "deepseek-v4-flash"`, `reasoning_effort = None`, `max_tokens = None`, `cwd = None` (workspace), `runtime_cwd = None`, `dsh_bin = None`, `profile = "sdk"`, `patches = ()`, `dsh_home = None`, `env = {}`, `initialize_timeout_seconds = 30.0`, `request_timeout_seconds = None`, `shutdown_timeout_seconds = 1.0`, `base_url = None`, `api_key = None`, `on_user_question = None`, `approval_requests = False`.

`HarnessClient(config=None, *, _launch_args=None)`; context manager (`start` on enter, `close` on exit).

| Method | Wire effect |
|---|---|
| `start()` | Spawn, start reader thread `dsh-runtime-reader` and stderr thread `dsh-runtime-stderr`. Idempotent while running; after `close()` a new `start()` spawns a new process. |
| `close()` | Shutdown sequence above; fails all waiters and subscriptions with `TransportClosedError`. |
| `initialize(*, cwd, provider, model, reasoning_effort=None, max_tokens=None, approval_requests=False) -> InitializeResponse` | `initialize` with `cwd` made absolute; `approvalRequests: true` only when requested; `capabilities: {"userQuestions": true}` only when a handler is configured. |
| `session_prompt(session_id, content_blocks, *, on_notification=None, notification_subscription=None) -> str` | `session/prompt`; returns `messageId`. |
| `resume_session(session_id)` | `session/resume`. |
| `_query(session_id, input) -> str | CommandExecution` | `session/query` (private; used by `Session.run`). A string becomes `[{"type":"text","text":input}]`. |
| `get_working_directory(session_id) -> str`, `set_working_directory(session_id, path) -> str` | the two working-directory methods. |
| `request(method, params, *, response_model, timeout_seconds=None, on_notification=None, notification_filter=None, notification_subscription=None)` | Any request; the result must be a JSON object and is validated by the pydantic model. `params=None` omits the member. |
| `notify(method, params=None)` | Client-to-server notification (the server ignores all of them). |
| `next_notification() -> Notification` | Blocking read of notifications that matched no subscription. |
| `subscribe_notifications(filter=None)`, `subscribe_session_notifications(session_id)` | Client-side subscriptions; the second scopes to a session tree. |
| `next_request() -> IncomingRequest` | Blocking read of server requests not handled by the question callback (`approval/request`, and `user-question/ask` when no handler is set). |
| `respond(request_id, result)`, `respond_error(request_id, *, code, message, data=None)` | Answer a server request. |

`NotificationSubscription`: context manager; `next(timeout_seconds=None)` (raises `TimeoutError("timed out waiting for an SDK notification")` without closing), `drain(callback)`, `close()`.

`DeepSeekHarness(config=None, **kwargs)` (either a config object or keyword options, not both): context manager; `client`, `start()`, `close()`, `start_session(session_id=None) -> Session` (fresh id `session-<uuid4 hex>`), `resume_session(session_id) -> Session`, `run(input, *, session_id=None, on_notification=None) -> RunResult`.

`Session`: `id`, `harness`, `get_working_directory()`, `set_working_directory(path)`, `run(input, *, on_notification=None) -> RunResult`.

`RunResult` (dataclass): `session_id`, `final_response`, `finish_reason: str | None`, `events: list[dict]` (root session only), `notifications: list[Notification]` (session tree).

Models: `Notification(method, payload)`, `IncomingRequest(id, method, payload)`, `ServerInfo(name?, version?)`, `InitializeResponse(serverInfo?)`, `ApprovalRequestParams(sessionId, toolName, callId?, reason?)`, `ApprovalRequestResult(outcome)`, `UserQuestionRequest(request_id ← requestId, session_id ← sessionId, questions: list[dict], min 1)`, `UserQuestionAnswerItem(id, selected, custom?)`, `UserQuestionAnswer(answers)`, `CommandExecution(command_id ← commandId, result)` with `CommandSuccessResult(kind='success', text?, source_event_seq ← sourceEventSeq, strict int 0..2^53-1, null rejected)` and `CommandErrorResult(kind='error', text non-blank)`.

User questions: `UserQuestionHandler = Callable[[UserQuestionRequest, threading.Event], UserQuestionAnswer | dict]`. Each `user-question/ask` runs the handler on its own daemon thread `dsh-user-question`; the event is set by `user-question.cancelled`, by `close()`, or by transport loss; a result is written only if the event is unset and the process is the same one. Handler exception → error response `-32603` with `str(exc)`. `close()` joins question threads for a shared 0.5 s.

Approvals: no callback API. The caller sets `approval_requests=True`, runs `next_request()` on its own thread while a turn runs, and answers with `respond(id, {"outcome": ...})`.

Hooks and tools in Python: not supported. The only Python callbacks are `on_user_question`, `on_notification` observers, and the manual approval loop. Tools, hooks and other behavior are added to the runtime as plugin bundles (`dsh plugin --profile sdk add file:/abs/bundle`) or through `--patch` files, and they execute inside the runtime process. A Racket port therefore needs no Python-to-runtime tool bridge; it needs its own plugin loading for the patch-inserted rows.

Profile and patch selection: `profile=` names any profile under `$DSH_HOME/profiles` or a shipped template; it must contain a `dsh-sdk-jsonrpc-server` row (the `web` profile has none). The launcher composes layers in this order (`apps/cli/src/profile-boot.ts:211-217`): bundle patches in `dsh.profile.bundles` order, the profile's user layer `$DSH_HOME/profiles/<name>/cordis.patch.yml`, the home layer `$DSH_HOME/cordis.patch.yml`, the `--patch` overlays in argv order, then the telemetry switch. `patches=` become those `--patch` overlays; later files win. Patch files are YAML patch lists; JSON is accepted as YAML (a test writes `[{"id":"system-prompt","config":{"persona":"..."}}]`).

`deepseek_harness.office` (catalog): `convert(input, output, *, sheet=None, options=None) -> ConversionResult`, `recalculate(input, output, *, options=None) -> ConversionResult`, `render_images(input, output_dir, *, pages, sheet, range, dpi, max_pages, max_pixels, max_dimension, options) -> RenderImagesResult`, `OfficeOptions` (limits and fonts mapped to `--kebab-case` flags, `--font-directory`, `--initial-font-family`, `--font-fallbacks <json>`), `OfficeError(code, message, exit_code)`. These spawn `<office node> <libreoffice-kit cli.js> render|convert|recalculate ...` and parse JSON from stdout (success) or stderr (`{code, error}`). They do not touch the SDK protocol.

### 10. Runtime wheel layout (`deepseek-harness-runtime-bin`)

Installed module directory `deepseek_harness_runtime/`:

```
__init__.py
_resources.py
deepseek-harness-runtime.json          {"name":"deepseek-harness-runtime-bin","version":"<version>"}
runtime/
  deepseek-harness-sdk-runtime-<plat>-<arch>[.exe]     single-file executable
  deepseek-harness-sdk-runtime-<plat>-<arch>-rg        ripgrep sidecar (Windows: ...-rg.exe)
  deepseek-harness-sdk-runtime-macos-<arch>-spawn-helper   macOS only (node-pty)
  <plat>-<arch>/downloads.json          {"target","identity"(64 hex),"office":[...],"pnpm":{...},"version"}
  node/                                 dev-only carrier, never in wheels (runtime-bootstrap.mjs + node_modules)
```

- `<plat>` ∈ `linux | macos | win`, `<arch>` ∈ `x64 | arm64`; Windows is x64 only. `downloads.json.target` uses `mac-` where the directory uses `macos-`.
- `platforms.json` maps targets to wheel tags: `manylinux_2_28_x86_64`, `manylinux_2_28_aarch64`, `macosx_14_0_arm64`, `macosx_14_0_x86_64`, `win_amd64`. The hatch hook sets tag `py3-none-<platform tag>`, rejects sdist builds, and rejects any payload that is not exactly the expected file set. `DSH_RUNTIME_PLATFORM_TAG` overrides the host tag.
- Console script `dsh = deepseek_harness_runtime:main`: requires non-blank `DSH_HOME` (else prints `dsh: the Python runtime command requires an explicit DSH_HOME; it never uses ~/.dsh implicitly` and exits 2), then `execvpe` on POSIX or run-and-forward-status on Windows.
- Module API: `bundled_package_dir()`, `bundled_runtime_path()`, `resolve_bundled_launch_args(mode=None)` (`mode` or `DSH_RUNTIME_MODE` ∈ `exe | node`; default finds the exe only; unknown → `ValueError`), `download_office()`, `download_primary_runtime()`, `resolve_office_launch_args()`, `main()`, constants `PACKAGE_METADATA_FILENAME`, `RUNTIME_MODE_ENV_VAR`.
- Downloads run the executable with `DSH_RUNTIME_DOWNLOAD=office|primary`; the bootstrap prints the resulting absolute path as one JSON string on stdout and exits. Cache root: `DSH_RESOURCE_CACHE` (absolute) or `~/.cache/deepseek-harness/resources`, then `<identity>/office` or `<identity>/primary`, each with a `complete` marker file whose content equals the identity.
- Bootstrap entry order (`runtime-bootstrap.mjs`): `DSH_RUNTIME_DOWNLOAD` → Windows ACL runner when `argv[2]` is that module → `DSH_PTC_RUNTIME_NODE=1` → `DSH_SUBPROCESS_RUNNER=<selection>` → otherwise `runCli({ packageManager })`, after defaulting `DSH_PRIMARY_RUNTIME` to the cached primary runtime when present.

Version coupling: the root `package.json` version is injected into both wheels; the SDK wheel pins `deepseek-harness-runtime-bin==<same version>`.

### 11. Environment variables seen in this area

`DSH_HOME`, `DEEPSEEK_API_KEY`, `DEEPSEEK_BASE_URL`, `DSH_RUNTIME_MODE`, `DSH_RUNTIME_DOWNLOAD`, `DSH_RESOURCE_CACHE`, `DSH_RESOURCE_DOWNLOAD_TIMEOUT_MS`, `DSH_OFFICE_SIDECAR`, `DSH_PRIMARY_RUNTIME`, `DSH_SUBPROCESS_RUNNER`, `DSH_PTC_RUNTIME_NODE`, `DSH_MAX_TOKENS_AS_SUCCESS` (sdk profile), `DSH_CONTEXT_WINDOW` and `DSH_SYSTEM_PROMPT` (sdk-minimal), `DSH_MODEL` (examples only), `TSX_TSCONFIG_PATH` (TS source launch), `DSH_RUNTIME_PLATFORM_TAG` (wheel build), `DSH_COMMANDS_TEST_RUNTIME` (`built | installed`, tests), `DSH_OFFICE_TEST_ARTIFACTS`, `DSH_SNAPSHOT` (`replay | record | refresh`) and its companions `DSH_SNAPSHOT_FILE`, `DSH_SNAPSHOT_CHILD_FILES`, `DSH_SNAPSHOT_OVERRIDE`, `DSH_SNAPSHOT_PROVIDER`, `DSH_SNAPSHOT_MODEL`.

### 12. ACP wire

Transport: newline-delimited JSON-RPC 2.0 on stdio through `ndJsonStream` of `@agentclientprotocol/sdk` 1.4.0. `PROTOCOL_VERSION` is `1`. Request ids are integer counters owned by each side of the ACP SDK connection; the ids in `stdout.expected.jsonl` are renumbered by the snapshot normalizer in first-seen order (by JSON value, regardless of direction), so they do not show the real values. Errors use the SDK's `RequestError`: invalid params → `{"code":-32602,"message":"Invalid params: <detail>"}`; internal → code `-32603`, message `Internal error: <detail>`.

Agent-side methods implemented (`index.ts:378-390`):

| Method | Params used | Result |
|---|---|---|
| `initialize` | ignored (any `protocolVersion` is answered with 1) | `{ protocolVersion: 1, agentInfo: { name: 'deepseek-harness-acp', version: '0.0.1' }, agentCapabilities: { mcpCapabilities: { http: true }, promptCapabilities: { image: <bool>, audio: false, embeddedContext: false }, sessionCapabilities: { close: {}, list: {}, resume: {} } }, authMethods: [] }` (this key order is pinned by snapshots) |
| `authenticate` | ignored | `{}` |
| `session/new` | `cwd` (absolute), `mcpServers`, `additionalDirectories` (must be empty or absent) | `{ sessionId: <uuid>, configOptions }` |
| `session/list` | `cwd?` (absolute), `cursor?` | `{ sessions: [{ sessionId, cwd }], nextCursor? }` |
| `session/resume` | `sessionId`, `cwd`, `mcpServers?` | `{ configOptions }` |
| `session/close` | `sessionId` | `{}` |
| `session/set_config_option` | `sessionId`, `configId`, `value` | `{ configOptions }` |
| `session/prompt` | `sessionId`, `prompt: ContentBlock[]` | `{ stopReason }` |
| `session/cancel` (notification) | `sessionId` | none |
| `$/cancel_request` (handled by the SDK) | request id | aborts that request's signal; for a prompt this is the same as cancel |

Client-side methods the agent calls: `session/update` (notification) and `session/request_permission` (request). Not implemented: `session/load`, session delete, fork, `session/set_mode`, modes, commands, plans, terminals, `fs/*`, elicitation, SSE MCP.

`configOptions` (`model-control.ts`): first `{ id: 'model', name: 'Model', category: 'model', type: 'select', currentValue, options: [{ group: <provider id>, name: <provider name>, options: [{ value, name, description? }] }] }` where every value is `JSON.stringify([provider, model])` and empty groups are dropped; then, only when the exact model declares reasoning, `{ id: 'reasoning_effort', name: 'Reasoning effort', category: 'thought_level', type: 'select', currentValue, options }` where `''` (label `Provider default`) is offered only when the model has no default effort. Returns `[]` when the session has no model selection.

`session/update` payloads (`updates.ts`), always `{ sessionId, update }`:

- `{ sessionUpdate: 'agent_thought_chunk', messageId, content: { type: 'text', text } }` per non-empty reasoning block.
- `{ sessionUpdate: 'agent_message_chunk', messageId, content }` per non-empty text block or image block (`{ type: 'image', data: <base64>, mimeType }`, re-read from the attachment store).
- `{ sessionUpdate: 'usage_update', used, size }` after an assistant message that has usage, when both `tokenMeter` and the request context window are known.
- `{ sessionUpdate: 'tool_call', toolCallId, title: <tool name>, kind: 'other', status: 'in_progress', rawInput }` where `rawInput` is the parsed arguments, or the raw string when they are not valid JSON.
- `{ sessionUpdate: 'tool_call_update', toolCallId, status: 'completed' | 'failed', content: [{ type: 'content', content }] }`.
- `{ sessionUpdate: 'config_option_update', configOptions }` after `llm/adapters-updated`.

`session/request_permission` params: `{ sessionId, toolCall: { toolCallId }, options: [{ optionId: 'allow-once', name: 'Allow once', kind: 'allow_once' }, { optionId: 'reject-once', name: 'Reject', kind: 'reject_once' }] }`. Response `{ outcome: { outcome: 'selected', optionId } | { outcome: 'cancelled' } }`: `cancelled` → `cancelled`, `optionId === 'allow-once'` → `allowed-once`, anything else → `rejected`. Requests without a `callId` and requests from Agents the bridge does not own are delegated with `next()`.

`session/list` cursor: base64url of `JSON.stringify([createdAt, sessionId])`; must match `^[A-Za-z0-9_-]+$`, decode to a two-element array of a non-negative safe integer and a non-empty string, and re-encode to the same text, else `Invalid params: session/list cursor is invalid`.

MCP server declarations (`mcp.ts`): no `type` → stdio `{ name, command (absolute), args, env: [{ name, value }] }` mounted with `transport: 'stdio'`, `cwd` = session cwd, `failOnStartupError: true`; `type: 'http'` → `{ name, url (http/https), headers: [{ name, value }] }` mounted with `transport: 'streamable-http'`; other types → `mcpServers[i] transport <type> is not supported`. Server names matching `^[A-Za-z0-9_-]{1,32}$` are kept; others become `<slug up to 20 chars>_<first 8 hex of sha256(name)>` cut to 32 characters, where slug = NFKD, runs of other characters → `_`, trimmed of `_`, or `server`. Duplicate normalized names, duplicate env names, case-insensitive duplicate header names, and invalid entries are rejected as invalid params.

Stop reasons (`codec.ts`): `completed → end_turn`, `max-tokens → max_tokens`, `aborted → end_turn`, `interrupted → cancelled`, `blocked → end_turn`, `error → end_turn` (but an `error` ending rejects the prompt instead, see Algorithms), default `end_turn`.

Prompt content admission (`content.ts`): `text` and `resource_link` are concatenated into text (a link renders as `\n[resource_link name=<JSON string> uri=<JSON string>]\n`); `image` requires the capability advertised at `initialize`, a supported MIME type, canonical RFC 4648 base64 (regex plus round trip), an attachment store, and a route whose `inputModalities` includes `image`; `audio` and `resource` are rejected. An image flushes pending text, so text/image order is preserved. A prompt with no image and only blank text → `Invalid params: empty prompt`.

### 13. Snapshot corpora

`snapshots/sdk/<scenario>/`:

- `snapshot.yml`: `version: 1`, `scenario`, `profile` (`sdk | sdk-minimal`), `composition`, `recording` (`live | authored`), optional `environment`, `header { class, pin?, systemPromptSource?, toolSchemasSource? }`, `replay.override`, `workspace.final`, `platform`, `sessionFormat`, `input.attachments`.
- `session[.vN].jsonl` (parent) and `session.<ordinal>[.vN].jsonl` (children): recorded session logs that are both replay input and expected persisted output.
- `result.expected.json`: `{"sessionId":"{{sessionId}}","finalResponse":"..."}` (optionally more result fields).
- `notifications.expected.jsonl`: one normalized notification per line, for example `{"method":"session.event","params":{"sessionId":"{{session:1}}","event":{"type":"turn/start","seq":4,"time":0,"data":{"turn":1}}}}`, `{"method":"session.status","params":{"sessionId":"{{session:1}}","status":"running"}}`, `{"method":"subagent.finished","params":{"provider":"spawn","agentId":"{{sessionId}}",...,"status":"ok","stopReason":"completed","lastAssistantMessage":[{"type":"text","text":"child answer 42."}]}}`. Volatile values are tokens (`{{session:N}}`, `{{message:N}}`, `{{command:N}}`, `{{id:N}}`, `{{cwd}}`, `{{system}}`, `{{tools}}`), and `time` is `0`. `session.query.completed` never appears because the run API consumes it.
- Optional `system-prompt[.N].expected.md`, `tool-schemas[.N].expected.json`, `workspace/` (seed), `workspace.expected/`, `cordis.yml` / `cordis.snapshot.yml` / `runtime.cordis.yml` / `capture.cordis.yml` (scenario patches), `replay.override.json`, helper `.mjs` plugins.

The harness starts `new DeepSeekHarness({ profile, patches, dshHome: <cwd>/.dsh, processCwd: cwd, env, cwd, provider, model, initializeTimeoutMs: 110000, requestTimeoutMs: 110000, approvalRequests?, onUserQuestion? })` and uses the fixed session id `fixture-root-session`.

`snapshots/acp/<scenario>/`: `input.json` (`{ steps: [{ op }...], permissionAnswers?: [{ kind: 'allow_once' | 'reject_once' }] }`, ops such as `initialize`, `newSession`, `newSessionExpectError`, `prompt`, `promptAndCancel` with `waitForFile`, `waitForTurnEnd`), `snapshot.yml`, `session.vN.jsonl`, and `stdout.expected.jsonl`: the exact normalized agent stdout, one JSON-RPC frame per line (tokens `{{sessionId}}`, `{{messageId}}`, `{{usedTokens}}`).

## Algorithms and invariants

1. **Session creation is coalesced** (`server.ts:544-600`). `getOrCreateSession` returns the existing record, else a pending creation promise from `sessionCreations`, else starts `openSession(id, false)`. A failed creation is removed so a retry can succeed. Concurrent prompts for a new id create one Agent.

2. **Agent options** for create and resume: `{ provider, model, reasoningEffort?, maxTokens? }` from `initialize`. On resume the `setup` callback forces the initialized route as the session's selection; when `initialize` gave no effort and the restored selection has the same provider and model with an explicit effort, that effort is kept (`server.ts:582-591`).

3. **Liveness re-check after every await.** `prompt` asserts `ctx.agents.get(id) === retained agent` before and after image admission, and checks the lifetime signal, so a prompt never reaches a disposed Agent or a server that started shutting down (`server.ts:262-281`).

4. **`session/query` routing** (`server.ts:289-332`, `query-input.ts`):
   - Find the first block with `type === 'text'`. If its trimmed text starts with `/` and a `commands` service exists: get or create the session, then `queryCommand(text, commands.list(agent))`.
   - `queryCommand`: trim; name = characters after `/` up to the first whitespace; `resolveCommand(name, descriptors)` picks an exact registered name first, else the English or Chinese alias (`goal/目标`, `plan/计划`, `feedback/反馈`, `compact/压缩`, `permission/权限`, `export/导出`) of a first-party definition id. `builtinCommandName` identifies the definition by `definitionId` (`@deepseek-ai/dsh-command-goal`, `@deepseek-ai/dsh-plan-mode`, `@deepseek-ai/dsh-command-compact`, `@deepseek-ai/dsh-permission-presets`, ...). Returned line: `/<registered name>` for bare `compact`; `/<name><rest>` for `permission` with arguments and for `plan` or `goal` with or without arguments; otherwise undefined. `<rest>` starts at the first whitespace; a first separator that is whitespace other than space, tab, CR, LF (for example U+3000) is replaced by one space.
   - Not recognized (`/compact extra`, bare `/permission`, `/model`, `/feedback x`, `/export`, unknown names, unrelated same-name definitions) → ordinary prompt with the original blocks.
   - Recognized: every other block must be an encoded image, else `Native SDK commands require one text block and optional encoded image blocks`. Create a `QueryActivity`, register it, and run `commands.execute(agent, line, images.map(i => ({ type: 'image', data, mediaType: mimeType, name? })), lifetimeSignal)` inside the per-invocation scope. `undefined` result → `The selected command is unavailable in this SDK profile`. Otherwise `activity.accept(execution)` and return `{ kind: 'command', execution }`. Any throw closes the activity; there is no prompt fallback.

5. **`QueryActivity` completion state machine** (`query-activity.ts`). State: `commandId`, `result`, `input`, `inputIdle`, `goalId`, `goalOutcome`, `goalStopped`, `response`, `turnReason = 'completed'`, `closed`. An event is "own" when the native result is not yet known and the event was emitted inside this invocation's asynchronous scope (`AsyncLocalStorage`).
   - Own `command/run` sets `commandId` once (nested commands keep the outer id).
   - Own `agent/inbox/spliced` that inserts a message with `source.kind === 'user'` sets `input`.
   - `goal/change`: own `create` or `resume` sets `goalId`. `clear` of the tracked goal sets `goalOutcome ??= 'aborted'`. A change of the tracked goal to a non-active phase sets `goalOutcome ??=` `completed` for phase `complete`, `aborted` for `paused`, else `error`. First outcome wins.
   - While `input` or `goalId` is set: every `assistant/message` overwrites `response` with its concatenated text blocks; every `turn/end` overwrites `turnReason` with `reason.kind`; `agent/error` sets `turnReason = 'error'`.
   - `accept(execution)`: store id and result; if `input`, wait for `agent.whenIdle()` and then set `inputIdle`.
   - `check()` (after every event): do nothing until the result is known. Result `error` → finish `('error', result.text)`. If `input && !inputIdle` → wait. If a goal is tracked → need an outcome (`goalOutcome`, or `error` when `goalStopped`) and `agent.status === 'idle'`; finish with reason `turnReason` when the outcome is `completed`, else the outcome; text is `response`, or `Goal execution stopped before reaching a terminal state.` when there was no durable outcome, or `''`. Else if `input` → finish `(turnReason, response ?? '')`. Else → finish `('completed', result.text ?? '')`.
   - `finish` writes `session.query.completed { sessionId, commandId, finishReason, finalResponse }` only when a `commandId` exists, then closes. Closing removes all listeners. Server shutdown closes every activity without a notification. Unloading the `goals` service finishes tracked-goal activities with `('error', 'The goal service was unloaded before the goal finished.')`.

6. **`session/wait` loop** (`server.ts:366-383`): repeat { assert live; `await agent.whenIdle()`; `idleSeq = session.seq`; `children = await subagents?.waitForTreeWork(agent)`; assert live; if no child work happened and the Agent is still idle at the same `seq` → throw `record.failure.error` if set, else return `{}` }. A live failure is recorded on `agent/error` with the log offset and cleared by a later `turn/end` at or after that offset.

7. **Approval bridge** (`server.ts:123-140`): active only when enabled and the Agent is owned (rule in Services). The wire request's signal is `AbortSignal.any([request.signal, lifetime])`.

8. **Scheduled sessions** (`server.ts:144-163`, `341-357`): `schedule/resolve-agent` waits for initialization, returns an owned Agent, joins a pending creation, or restores the session and remembers the promise in `scheduledSessions`. The client may `session/resume` such a session once (the entry is consumed); any other already-open session rejects resume. `getOrCreateSession` also clears the entry.

9. **Server teardown** (`server.ts:447-490`), memoized: set `shuttingDown`; abort the lifetime signal with `SDK server is shutting down`; close the question bridge; release the initialization gate; settle pending creations, then pending command tasks; clear maps; run listener disposers in reverse order collecting failures; `subagents.drainDescendants(roots)`; then in parallel dispose the goal watcher, every root handle, and the fallback adapter. One failure is rethrown as is; several as `AggregateError(failures, 'SDK server teardown failed')`.

10. **Process exit on `shutdown`** (`index.ts:66-95`): one shared task: flush the transport, dispose the root fiber, `exit(0)`, each step tolerant of the previous step failing. It is scheduled with `setImmediate` after the handler returns so the response is written first. Racing shutdown requests share the task. Disposing only the plugin fiber stops serving without exiting.

11. **Stdin EOF** (`packages/boot/cmdline/src/index.ts:123-145`): the startup plugin registers a one-shot `end` listener that, once `appReady` has committed, calls `appExit(0)`. It never reads stdin itself. A startup rejection that races EOF stays the process outcome.

12. **Client session-tree scoping** (TS `client.ts:469-539`, Python `client.py:622-666`): every `subagent.started` with distinct non-empty ids records `child → parent`. A notification belongs to root R when: for `subagent.started/finished`, `parentSessionId` is R or a descendant of R, or `childSessionId === R`; for others, `params.sessionId` is R or a descendant. The map lives for the process lifetime. In Python a notification that matches no subscription goes to the global queue read by `next_notification()`. A throwing filter fails only its own subscription.

13. **`run()` interval** (TS `api.ts:177-301`, Python `api.py:56-272`): subscribe to the session tree before sending; send `session/query`; then as in "Requirements that `Session.run()` places" above. `events` holds root-session events only; `notifications` holds the whole tree; `session.query.completed` is never recorded or passed to the observer. Prompt results: `finalResponse` = joined text of the last `assistant/message` in the interval (`''` if none), `finishReason` = `reason.kind` of the last `turn/end` or `null`.

14. **TS client validation** (`api.ts:305-359`): `turn/end` needs `data.reason.kind`; an `aborted` reason needs a known inner kind; `assistant/message` needs a `content` array of objects with string `type`. Violations raise `SdkProtocolError`.

15. **ACP prompt lifecycle** (`session.ts:219-306`, `478-531`). One in-flight prompt per session (`Invalid params: a prompt is already in flight for this session`). Admission: check Agent liveness, admit content, re-check, create the user message, `agent.followup`. Settlement loop: wait idle; record `seq`; wait for descendant work; if children ran or the Agent is not idle at the same `seq`, repeat; await the output chain; finish if still idle at that `seq`. Outcome precedence: cancelled → `stopReason: 'cancelled'`; assistant output delivery failure → `Internal error: assistant output delivery failed: ...`; a live Agent failure not superseded by the turn's `turn/end` → `Internal error: turn failed: ...`; no recorded end → `cancelled`; `error` end → `Internal error: turn failed: <message>`; else the mapped stop reason. Turn correlation: `agent/inbox/claimed` binds the prompt's message id to a turn; later `turn/start` events move the binding forward (retries and summary turns adopt the prompt).

16. **ACP ordering.** Each session has one promise chain `outputTail`; every update is appended to it, so updates are delivered in commit order even when image conversion is asynchronous. A permission request first awaits `drainUpdates()`, so the `tool_call` update precedes `session/request_permission` on the wire (pinned by snapshots). Notification failures are logged, never thrown into the Agent.

17. **ACP cancel** (`session.ts:308-313`, `459-476`): `session/cancel` aborts admission, and if the message was queued calls `agent.cancel({ kind: 'user' })`; with no prompt in flight it cancels autonomous work; unknown session ids are ignored. The prompt resolves `cancelled` after the cancelled activity is idle and its queued output is delivered.

18. **ACP close and teardown**: `close(detail)` is memoized: cancel; await admission, idle, and output; `subagents.drainDescendants([agent])`; `sessions.flush(session)`; dispose the Agent handle; aggregate failures. Connection close and plugin disposal run the same teardown for every session (`quiesce`). `session/new` flushes the empty session so it is listable; a failure after creation rolls the Agent back.

19. **ACP resume and list rules**: resume rejects an id that is active, activating, or live anywhere in `ctx.sessions` (`session is already active: <id>`); rejects a missing log or `origin === 'subagent'` (`session is not resumable: <id>`); requires the persisted cwd to be the same directory by `realpath`, falling back to lexical comparison (`session cwd does not match: <cwd>`). List excludes active or activating ids, live sessions, subagent origin, and headers without an absolute cwd; sorts by `createdAt` descending, then by session id bytes ascending.

20. **ACP model control**: `options()` and `set()` are serialized through one promise chain per session. The first `options()` must resolve the route; later failures fall back to the stored selection and omit the reasoning option. `set('model', value)` requires an advertised value; `set('reasoning_effort', value)` requires a declared effort, or `''` when the model has no default. Errors are `Invalid params:` `<id> requires a select value`, `this session has no model selection`, `unknown model option: <v>`, `unknown reasoning effort for <provider>/<model>: <v>`, `unknown session config option: <id>`.

21. **`subagent-dsh-sdk` run** (`run.ts:231-376`, catalog): create a `DeepSeekHarness` with `processCwd = child cwd`, `cwd = parent origin cwd`, env `scrubbedParentEnv() + config.env`; `start()` raced against cancellation; then on a private child session id `session-<32 hex>`: `setWorkingDirectory(cwd)`, low-level `prompt(request.prompt)`, `request('session/wait')`, drain queued `session.event` notifications into an `AssistantOutputFold`, map the last `turn/end` (`completed → completed`, `max-tokens → max-tokens`, `aborted → aborted`, `blocked → refusal`, `error | interrupted | none | unknown → error`). Model-visible diagnostics are fixed strings `Subagent failure (provider: DSH SDK; stage: <initialize|session-run|shutdown>; category: <configuration|protocol|transport|child-error|child-disposed|child-unknown|missing-terminal|unknown>)`. There is no wire cancel; cancellation settles locally and teardown closes the child process.

## Tests worth porting

Server behavior (TypeScript, hand-built contexts; mirror as Racket unit tests):

- `packages/sdk/protocol/tests/transport.spec.ts`: framing, classification, params normalization, malformed lines, split UTF-8, error mapping, abort, flush, input end, close.
- `packages/sdk/server/tests/server.spec.ts`: initialize validation and adapter fallback, prompt queueing, image admission, liveness errors, status forwarding, `subagent.started/finished` rules, unknown method, creation coalescing, teardown aggregation.
- `packages/sdk/server/tests/commands.spec.ts`, `query-input.spec.ts`, `query-activity.spec.ts`: command recognition table (leading whitespace including U+3000, aliases, non-commands), content validation, completion state machine including goal cases.
- `packages/sdk/server/tests/resume.spec.ts`, `wait.spec.ts`, `shutdown.spec.ts`, `approval.spec.ts`, `user-questions.spec.ts`, `plugin-apply.spec.ts` (initialize waits for the Loader, shutdown answers before exit exactly once, bare dispose does not exit).
- `packages/sdk/server/tests/{compact,goal,permission,plan}-parity.spec.ts`: SDK command entry produces the same model inputs as the native command.
- `packages/bundle/sdk-app/tests/startup.spec.ts`, `packages/bundle/acp-app/tests/startup.spec.ts`: readiness marker, EOF exit, help prints without binding stdin. `packages/bundle/sdk-minimal/tests/sdk-minimal.spec.ts`: the tree is exactly the allowlist.

Client behavior (reference for wire expectations): `packages/sdk/client/tests/{sdk-client,run,user-questions,launch,dispose}.spec.ts` with `tests/fake-runtime.ts` and `tests/fixtures/query.ts`.

ACP: `packages/acp/acp/tests/{bridge,turns,content,mcp,model-control,updates,approval,multi-session,dispose,edges,codec}.spec.ts`. The nine `snapshots/acp/*` scenarios are the strongest black-box target: drive the Racket `dsh --profile acp` with `input.json` and compare stdout to `stdout.expected.jsonl` after the same token normalization.

SDK snapshots: all `snapshots/sdk/*` scenarios replay recorded model responses through the real profile; they need the replay LLM plugin and scenario helper plugins, so port them after the session and LLM layers exist. Start with `text-turn`, `multi-turn`, `bash-tool`, `session-resume`, `manual-compact`, `permission-switch`, `plan-review`, `goal-rounds`, `approval`, `subagent-spawn-in-process`.

Python tests, by what they need:

1. No server needed (they launch small Python fake peers through `_launch_args`; treat each fake peer as an executable description of the expected server output): `test_client.py`, `test_run.py`, `test_approval.py`, `test_user_questions.py`, `test_resume.py`, `test_working_directory.py`, `test_cot_translation_projection.py`, `test_goal_example.py`, `test_plan_input.py`, `test_plan_input_posix.py`. Run them unchanged to confirm the Python client itself is intact.
2. Can run against a compatible executable with no test edit: `test_bundled_runtime.py` (three tests per mode; uses `resolve_bundled_launch_args`, so place the Racket executable at `deepseek_harness_runtime/runtime/deepseek-harness-sdk-runtime-<plat>-<arch>` with its `-rg` sidecar and a valid `<plat>-<arch>/downloads.json`, or provide a shim module). It checks: `initialize` succeeds with a dummy key and unreachable base URL, `serverInfo.name == "deepseek-harness-sdk-runtime"`, `$DSH_HOME/profiles/sdk/package.json` has `dsh.profile.bundles == ["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-sdk-app"]`, a JSON patch file loads, and a patch inserting `@deepseek-ai/dsh-does-not-exist` fails with that name in the error.
3. Can run against a compatible executable through `DSH_COMMANDS_TEST_RUNTIME=installed` (then `dsh_bin=None` and the bundled-runtime lookup is used) or by editing `_dsh_bin()` in `test_commands_runtime.py`: `test_commands_runtime.py`, `test_command_attachments_runtime.py`, `test_goal_runtime.py`, `test_goal_result_text_runtime.py`, `test_plan_runtime.py`, `test_plan_example.py` (the list in `tests/run_installed_commands.py`). They need the full `sdk` profile, the patch rows `session-persistence-jsonl` (`root`, `compression: none`) and `goal` (`defaultMaxGoalRounds`), env `DSH_PERMISSION_MODE`, `DSH_TELEMETRY_DISABLED`, `DSH_TOOLS_MODE=native`, a provider that calls `POST <DEEPSEEK_BASE_URL>/v1/messages` and parses an Anthropic-style SSE stream (`message_start`, `content_block_start`, `content_block_delta` with `text_delta` or `input_json_delta`, `content_block_stop`, `message_delta`, `message_stop`), tolerates `404` on `POST /v1/files`, and JSONL session logs readable as `session*.jsonl` whose first line is `{"type":"session","id":...}` followed by events in `seq` order.
4. Need a Racket replacement for a JavaScript fixture: `test_approval_runtime.py` (inserts `packages/sdk/server/tests/fixtures/approval.mjs`, a plugin that asks `ctx.approval.request` in `agent/pre-step`), `test_account_provider_snapshot.py` (uses `snapshots/sdk/account-provider-signout/cordis.yml`).
5. Not about the server: `test_runtime_resolution.py`, `test_release_version.py`, `test_macos_deployment_target.py`, `test_office*.py`, `test_smoke_model.py`.

Also usable with `--exe <racket executable>`: `scripts/smoke-python-runtime.py`. The `direct` scenario speaks raw JSON-RPC (`[exe, "--profile", "sdk", "--patch", patch]`, ids `"initialize"`, `"prompt"`, `"shutdown"`, waits for `session.status` `idle`, then checks one JSONL log whose header `cwd` equals the workspace). `sdk-minimal`, `sdk-snapshot`, `sdk-recovery`, `sdk-restart` compare against `scripts/snapshots/python-sdk-single-exe/`.

## Porting notes

Essential product behavior:

- The wire: framing, method names, field names, result shapes, the `-32603` error convention with exact messages where tests match on them, the notification stream, and the two server-to-client requests.
- The executable contract in Formats section 7, including exit behavior on `shutdown`, EOF, and SIGTERM.
- Command routing and the `QueryActivity` completion rules; `session/wait` semantics; ownership rules for approvals and questions.
- ACP v1 surface and its ordering rules.
- Bundle patches and profile templates (configuration compatibility).

Node-specific machinery that should be redesigned, not copied:

- `AsyncLocalStorage` for "own invocation" → a Racket parameter (`parameterize`) around the command execution, provided events emitted by the command handler are delivered in the same dynamic extent or carry the parameterization explicitly (preserved thread cells or continuation marks). If the Racket kernel dispatches listeners on another thread, pass an explicit invocation token instead.
- `AbortController` / `AbortSignal.any` → custodians plus a cancellation event (`make-semaphore` or a `evt`), with a combined event via `choice-evt`.
- Promise chains (`outputTail`, model-control `tail`, memoized shutdown) → one worker thread per session with an async channel, or a mutex-protected queue; memoization → a `delay/sync`-style once cell.
- `setImmediate` after the shutdown response → write response, flush the output port, then run teardown.
- Single-file Node executable, `node:sea`, the tsx source launch, same-version manifest checks, and the `runtime-bootstrap.mjs` selector dance are packaging details. The Racket equivalent is a `raco exe` / `raco distribute` binary named so the Python locator finds it, or simply `dsh_bin=`.

Suggested Racket decomposition:

- `dsh-sdk-protocol`: `jsonrpc-line-transport` (struct with input port, output port, pending table, handler boxes; one reader thread; a write lock so frames never interleave), contracts for each params/result shape, and the method-name constants.
- `dsh-sdk-server`: `sdk-server` struct, `handle-request` dispatch, `query-content`, `query-input`, `query-activity`, `user-question-bridge`; a Cordis plugin module exporting `name`, `inject`, `Config`, `apply`.
- `dsh-sdk-app`, `dsh-acp-app`: startup plugins on the Racket `cmdline` equivalent; ship the same `cordis.patch.yml` files unchanged (the `!!js` expressions need the port's expression evaluator: `process.env.X`, `process.platform`, `process.cwd()`, `dshHomePath(...)`, `Number(...)`, `JSON.parse(...)`, `??`, `?:`, `===`).
- `dsh-acp`: there is no Racket ACP SDK, so write the JSON-RPC layer directly on the same line transport, with `$/cancel_request` handling and the `RequestError` message prefixes. Split as upstream: `codec`, `content`, `mcp`, `model-control`, `updates`, `session`, `bridge`.
- Client side: keep the Python SDK as is. A Racket client library is optional; `subagent-dsh-sdk` needs one only if nested out-of-process children are in scope (it can spawn the Racket executable itself).

Hard parts and risks:

- Ordering: notifications must be written at commit time and before the response of the request that caused them. Use one writer with a lock and never buffer notifications behind responses.
- Concurrency of requests: `session/wait` and long `session/query` commands must not block `initialize`-independent requests, approvals, or `shutdown`. Each request needs its own thread or task.
- Early stdin bytes: the client writes `initialize` before the tree has mounted. Do not close or drain stdin during boot; the transport must see buffered bytes.
- Stdout purity: any Racket `printf` or logger on stdout corrupts the channel. Route all logs to stderr and consider making `current-output-port` an error port inside the runtime, leaving the transport a private handle to the real stdout.
- JSON fidelity: session events are forwarded verbatim. Key order in the expected files follows the insertion order of the TypeScript objects. The existing normalizer (`packages/test-support/session-snapshot/src/normalize.ts:307-332`) parses each stdout line, renumbers ids, scrubs volatile values, re-serializes with `JSON.stringify`, and compares text, so key order matters if that harness is reused. Racket `hasheq`-based JSON loses order: either compare parsed values in the Racket harness or use an ordered JSON writer that follows the field order shown in this note. Also preserve integers versus floats and omit absent optional fields instead of writing `null`.
- `QueryActivity` goal cases depend on goal, plan, and compaction packages; port those tests together.
- `initialize` must wait for full tree settlement; the Racket Loader needs an equivalent of `loader.await()`.
- The Python real-runtime tests assume the DeepSeek adapter speaks the `/v1/messages` SSE format and that session logs are JSONL in the dsh session format; those belong to other areas but gate these tests.

What can only be wrapped:

- JavaScript plugin fixtures and third-party JS bundles referenced from patches (`*.mjs` rows such as the approval fixture and snapshot helper plugins) cannot load in Racket. They need either Racket rewrites or the planned Node sidecar.
- `deepseek_harness.office` and the download helpers call the Node-based LibreOffice kit CLI and the Node runtime's download code. Keep them as Node subprocesses or leave them unsupported with a clear error.
- The wheel's hatch hook and release scripts are Python packaging; reuse them if the Racket executable is shipped in a wheel.

## Feature checklist

- sdk-protocol: frames are UTF-8 JSON objects, one per `\n`-terminated line, on stdin/stdout
- sdk-protocol: classifies request / response / notification by presence of `id` and `method`
- sdk-protocol: ignores blank lines, non-JSON lines, and non-object frames
- sdk-protocol: tolerates `\r\n` and multibyte characters split across reads
- sdk-protocol: normalizes missing, array, or scalar `params` to `{}`
- sdk-protocol: echoes request ids with their original type (string or number)
- sdk-protocol: handler failure becomes error `-32603` with the failure message
- sdk-protocol: no handler installed becomes error `-32601` `method not found: <method>`
- sdk-protocol: outbound requests use ids `req_<32 hex>` and resolve on the matching response
- sdk-protocol: error responses reject with code, message, and `data` preserved
- sdk-protocol: an aborted outbound request drops its pending entry and ignores late responses
- sdk-protocol: input end or close fails all pending and future outbound requests
- sdk-protocol: notifications without params omit the `params` member
- sdk-protocol: requests are dispatched concurrently
- sdk-server: plugin named `sdk-jsonrpc-server` with `inject` `agents`, `workingDirectory` and config `maxTokensAsSuccess` (default false)
- sdk-server: provides `sdkSessionActivation` `{ready: true}`
- sdk-server: `initialize` waits for Loader settlement before answering
- sdk-server: `initialize` validates `approvalRequests`, `reasoningEffort`, `maxTokens` with exact messages
- sdk-server: `initialize` mounts the DeepSeek adapter only for unowned `deepseek-official`; other unowned providers fail
- sdk-server: `initialize` resolves the exact route through the adapter before storing it
- sdk-server: `initialize` returns `serverInfo` `deepseek-harness-sdk-runtime` / `0.0.1`
- sdk-server: methods before `initialize` fail with `SDK server is not initialized`
- sdk-server: `session/prompt` creates the session lazily and returns `{messageId}` immediately
- sdk-server: one Agent per `sessionId`; concurrent creation is coalesced; failed creation can be retried
- sdk-server: sessions are created with `meta.cwd` = resolved `initialize.cwd` and the initialized route
- sdk-server: inline images are admitted to the attachment store and logged as references
- sdk-server: inline image without an attachment store fails with `SDK image prompt requires an attachment store`
- sdk-server: prompt rejects when the retained Agent was disposed outside the server
- sdk-server: `session/query` rejects extra keys and empty `sessionId`
- sdk-server: `session/query` validates content blocks with the six documented errors
- sdk-server: `session/query` routes bare `/compact`, `/permission <preset>`, `/plan [...]`, `/goal [...]` to native commands
- sdk-server: Chinese aliases `/压缩`, `/权限`, `/计划`, `/目标` route like their English names
- sdk-server: exact registered names win over aliases; unrelated same-name definitions stay prompts
- sdk-server: `/compact extra`, bare `/permission`, `/model`, unknown slash text stay ordinary prompts
- sdk-server: a recognized command with extra text or non-encoded blocks is rejected without fallback
- sdk-server: command images are passed to the native executor as `{type:'image', data, mediaType, name?}`
- sdk-server: `session/query` returns `{kind:'prompt', messageId}` or `{kind:'command', execution}`
- sdk-server: command failure never falls back to a prompt
- sdk-server: without a `commands` service every query is a prompt
- sdk-server: `session.query.completed` for a state-only command carries `completed` and the handler text
- sdk-server: `session.query.completed` for an error result carries `error` and the error text
- sdk-server: command-admitted user input delays completion until idle and reports the last turn reason and reply
- sdk-server: goal create/resume delays completion until the goal ends and the Agent is idle
- sdk-server: goal pause or clear reports `aborted`; blocked or lost activation reports `error`
- sdk-server: the first durable goal outcome is kept
- sdk-server: disposal of the Agent or unloading `goals` finishes the query with `error`
- sdk-server: `session/resume` restores a persisted session, sends no input, returns `{}`
- sdk-server: `session/resume` rejects open, opening, missing, and subagent sessions
- sdk-server: resume applies the initialized route and keeps a saved effort for the same route
- sdk-server: `session/wait` rejects unknown sessions and never creates one
- sdk-server: `session/wait` returns after root idle, descendant work, and a stable `seq`
- sdk-server: `session/wait` rejects with a live Agent failure not followed by a `turn/end`
- sdk-server: notifications committed during a wait precede its response
- sdk-server: `session/working-directory/get` and `/set` return `{cwd}` and create unknown sessions
- sdk-server: unknown methods fail with `unknown DeepSeek Harness SDK runtime method: <method>`
- sdk-server: `session.event` is sent for every session in the runtime in commit order
- sdk-server: `session.status` is sent for every Agent status transition
- sdk-server: `subagent.started` is sent only for `origin: subagent` sessions with a parent
- sdk-server: `subagent.finished` is sent only for local runs, with `status` mapped by `maxTokensAsSuccess`
- sdk-server: `approval/request` is sent only when enabled and the Agent or its tree root is owned
- sdk-server: invalid approval response, client error, or transport loss fails closed
- sdk-server: `user-question/ask` is sent only when the capability was advertised and the Agent is an owned root
- sdk-server: question answers are validated (each id once) and mapped to `BAD_ANSWER`, `ASK_CANCELLED`, `PROVIDER_ERROR`, `ASK_ABORTED`
- sdk-server: `user-question.cancelled` is sent when a pending question is aborted
- sdk-server: scheduled reminders restore sessions through the SDK owner after initialization
- sdk-server: `shutdown` answers `{}`, flushes, disposes the root, exits 0 exactly once
- sdk-server: plugin disposal drains descendants, disposes root Agents and the fallback adapter, aggregates failures
- sdk-app: `sdk-app-startup` parses inner argv, prints help without mounting the transport
- sdk-app: provides `sdkAppStartup` and exits 0 on stdin EOF after startup commits
- sdk-app: `cordis.patch.yml` loads unchanged over `dsh-base` (rows and `!!js` expressions)
- sdk-app: `DSH_MAX_TOKENS_AS_SUCCESS` controls `maxTokensAsSuccess` (default true in the `sdk` profile)
- sdk-minimal: profile is a standalone tree exposing only shell, `read_image`, `working_directory`
- sdk-minimal: `DSH_SYSTEM_PROMPT` and `DSH_CONTEXT_WINDOW` are honored
- sdk-minimal: slash input stays on the prompt path
- acp-app: `acp-app-startup` provides `acpAppStartup` and exits on stdin EOF
- acp-app: `cordis.patch.yml` loads unchanged over `dsh-base`
- acp: `initialize` answers protocol version 1 with the pinned capability object
- acp: image prompt capability is true only with an attachment store and an image-capable configured route
- acp: `authenticate` succeeds with `{}`
- acp: `session/new` validates absolute `cwd`, rejects `additionalDirectories`, returns `sessionId` and `configOptions`
- acp: `session/new` mounts stdio and HTTP MCP servers before publishing the Agent and rolls back on failure
- acp: MCP server names are normalized; duplicates and invalid entries are invalid params
- acp: `session/list` pages newest-first with an opaque canonical cursor and optional `cwd` filter
- acp: `session/resume` verifies the workspace, rejects active or non-resumable ids, replays nothing
- acp: `session/close` cancels, drains, flushes, disposes one session and leaves it resumable
- acp: `session/set_config_option` changes `model` or `reasoning_effort` serially and returns full state
- acp: `session/prompt` admits text, resource links, and images in order; rejects audio and embedded resources
- acp: one in-flight prompt per session
- acp: prompt settles after root idle, descendant work, and ordered update delivery
- acp: stop reasons map as `end_turn`, `max_tokens`, `cancelled`; failed turns reject with `Internal error: turn failed: ...`
- acp: `session/cancel` and `$/cancel_request` resolve the prompt as `cancelled`
- acp: `session/update` emits thought, message, tool_call, tool_call_update, usage_update, config_option_update
- acp: `session/request_permission` offers allow-once / reject-once and maps the answer
- acp: updates precede the permission request for the same tool call
- acp: connection close and plugin disposal quiesce every session
- sdk-client (TS): launch argv `node <bin> --profile <p> [--patch f]...`, absolute paths, same-version check, source fallback
- sdk-client (TS): `initialize` bound 10 s; request, shutdown, and dispose timeouts as documented
- sdk-client (TS): session-tree subscription scoping from `subagent.started`
- sdk-client (TS): `run()` prompt interval and command completion rules
- sdk-client (TS): close ladder shutdown → EOF → SIGTERM → SIGKILL
- python-sdk: launches `<dsh_bin> --profile <profile> [--patch <abs>]...` with `DSH_HOME` required
- python-sdk: merges `env` over the parent environment; sets `DEEPSEEK_BASE_URL` / `DEEPSEEK_API_KEY` from options
- python-sdk: `initialize` bound 30 s with profile name and stderr tail in diagnostics
- python-sdk: `Session.run` works for prompts (receipt to idle) and commands (lifecycle plus completion)
- python-sdk: `on_user_question` answers `user-question/ask` on a worker thread and honors cancellation
- python-sdk: `next_request` / `respond` handle `approval/request`
- python-sdk: `resume_session`, working-directory methods, low-level `session_prompt`
- python-sdk: close sends `shutdown`, closes stdin, waits, then SIGTERM, then SIGKILL
- python-sdk: no Python-defined tools or hooks (documented absence)
- python-sdk-runtime: locator finds `runtime/deepseek-harness-sdk-runtime-<plat>-<arch>[.exe]` with required sidecars and `downloads.json`
- python-sdk-runtime: `DSH_RUNTIME_MODE=exe|node` selection and unknown-mode error
- python-sdk-runtime: `dsh` console script requires `DSH_HOME` and forwards argv and exit status
- python-sdk-runtime: `DSH_RUNTIME_DOWNLOAD=office|primary` prints one JSON path and exits
- subagent-dsh-sdk: registers provider `dsh-sdk` that runs each child as a separate SDK runtime process
- subagent-dsh-sdk: maps child `turn/end` to subagent stop reasons with fixed safe diagnostics
- snapshots-acp: the nine scripted scenarios reproduce `stdout.expected.jsonl`
- snapshots-sdk: scenarios reproduce `result.expected.json`, `notifications.expected.jsonl`, and persisted session logs
