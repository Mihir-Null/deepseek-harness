# Recon 06: LLM model providers

Area: `packages/llm/*`, `packages/test-support/{llm-mock-server,llm-replay}`, `docs/subsystems/llm-streaming.md`, `docs/deepseek-llm-api-wire-extensions.md`, `docs/cookbook/adding-an-llm-adapter.md`. Pinned commit `e8f7b93a3` (dsh 0.2.2-rc.2). All paths are relative to the repository root. Line numbers refer to the pinned commit.

One fact changes the shape of this port and is easy to get wrong: the shipped DeepSeek adapter does not speak OpenAI Chat Completions. It speaks the Anthropic Messages protocol ("DeepSeek Messages") at `https://api.deepseek.com/anthropic/v1/messages`. There is no `tool_choice`, no `stream_options`, no `reasoning_content`, and no prefix-completion field anywhere in the request. Recorded fixtures made before that change still carry OpenAI-era usage fields (`reasoningTokens`, `call_00_...` ids); they replay through the provider-neutral vocabulary and need no adapter.

## Scope

| Package directory | npm name | Role | Source lines (no tests) |
|---|---|---|---|
| `packages/llm/llm` | `@deepseek-ai/dsh-llm` | Provider-neutral vocabulary (messages, blocks, chunks, failures, usage), `LlmRuntime` service on `ctx.llm`, `LlmAdapter` base class, `BlockAssembler`, compact timed stream, retry-policy resolution, request projections (files, images, tool updates) | ~4,250 |
| `packages/llm/llm-deepseek` | `@deepseek-ai/dsh-llm-deepseek` | Library, not a plugin: DeepSeek Messages transport (`DeepSeekAdapter`), request serializer, SSE translator, Files API client and upload index, `/models` listing cache, image-token calculator, shared Config schema | ~3,700 |
| `packages/llm/llm-deepseek-api-key` | `@deepseek-ai/dsh-llm-deepseek-api-key` | Function plugin registering route `deepseek-official` with `x-api-key` auth and the official model listing | ~185 |
| `packages/llm/llm-deepseek-account` | `@deepseek-ai/dsh-llm-deepseek-account` | Function plugin registering route `deepseek-account` with `x-dsh-auth-token` auth, the account model listing, `modelOverrides`, token invalidation on 401 | ~196 |
| `packages/llm/llm-pi-ai` | `@deepseek-ai/dsh-llm-pi-ai` | Function plugin wrapping the Node library `@earendil-works/pi-ai` (^1.3.0): one adapter instance serving a dict of provider routes (42 providers in the generated provider data plus hand-declared gateways), OAuth/API-key login flows, endpoint model discovery | ~4,640 (+160 generator script) |
| `packages/llm/llm-retry` | `@deepseek-ai/dsh-llm-retry` | Function plugin executing each provider's retry policy on the agent loop's `agent/request-error` waterfall; durable `llm/retry` events | ~320 |
| `packages/llm/token-meter` | `@deepseek-ai/dsh-token-meter` | Service on `ctx.tokenMeter`: heuristic request-pressure measurement plus four session projections (`tokenMeasurement`, `tokenUsage`, `contextPressure`, `contextBreakdown`) and the pure `deriveTurnTokenUsage` fold | ~1,625 |
| `packages/llm/deepseek-llm-api-extensions` | `@deepseek-ai/dsh-deepseek-llm-api-extensions` | Service on `ctx.deepseekLlmApiExtensions`: registry of plugin-owned top-level JSON fields on official DeepSeek requests with a prepare/accept transaction | ~205 |
| `packages/llm/plugin-package-inventory-deepseek` | `@deepseek-ai/dsh-plugin-package-inventory-deepseek` | Function plugin contributing the `dsh_plugin_packages` request field (active Loader-backed package names and versions) | ~235 |
| `packages/test-support/llm-mock-server` | `@deepseek-ai/dsh-llm-mock-server` | Scriptable local Messages HTTP/SSE fault server and its CLI | ~1,020 |
| `packages/test-support/llm-replay` | `@deepseek-ai/dsh-llm-replay` | Function plugin replaying recorded session logs as model output (keyless snapshot tests) | ~1,210 |

Depth. In depth: `llm`, `llm-deepseek` (request serializer, SSE translator, error mapping, extensions), `llm-deepseek-api-key`, `llm-deepseek-account`, `llm-retry`, `token-meter`, `deepseek-llm-api-extensions`, `plugin-package-inventory-deepseek`, `llm-mock-server`, `llm-replay`. Medium depth: `llm-deepseek` Files API store, upload index, and listing cache (wire formats and state rules are given; some diagnostics text is summarized). Catalog depth: `llm-pi-ai` provider data, compat-switch catalog, credential-store bridge, login flows, and endpoint discovery; the adapter mapping (context conversion, stream translation, replay state, error classification) is given in full because it defines behavior independent of the library. The vision-token calculator (`llm-deepseek/src/image-tokens.ts`) is summarized with constants; port it line by line from the source.

## Services

### `ctx.llm` — `LlmRuntime` (`packages/llm/llm/src/index.ts:369`)

Default export of `@deepseek-ai/dsh-llm`. A Service class (`extends TypertRemoteService`, constructed with `super(ctx, 'llm')`). No Config, no `inject`. It reads two optional services with `ctx.get`: `attachments` (`fileHostPath(ref)`) and `fs` (`processPathFromHostPath(hostPath)`). State: `adapters: Map<provider, {adapter, provider: {id, name}, retryPolicy}>` in registration order, `directory: Map<provider, LlmConfigurableProvider>` in declaration order, `discoveries: Map<settingsNs, fn>`. Methods marked Remote are exposed over the typert remote protocol.

| Method | Semantics |
|---|---|
| `registerAdapter(providers: string[], adapter: LlmAdapter): AdapterRegistrationHandle` | Effect-scoped (`ctx.effect`, label `llm.registerAdapter()`), disposed with the calling fiber. All-or-nothing. Throws `LlmError` `INVALID_ADAPTER` for an empty list ("an adapter must register at least one provider"), an empty name, or `adapter.providerInfo(p)` whose `id !== p` or whose `name` is empty; `DUPLICATE_ADAPTER` ("an adapter for provider \"p\" is already registered") for a repeat within the list or a route another registration holds. For each route it captures `adapter.providerRetryPolicy(p) ?? resolveRetryPolicy(undefined, ...)`. Emits `llm/adapters-updated` once after the commit. The returned handle is callable (dispose: delete owned routes, emit) and has `replace(providers: string[])`: validate the full candidate set treating currently owned routes as free, then swap in one synchronous section and emit once; an empty array is legal for `replace`; after disposal `replace` throws `REGISTRATION_DISPOSED`. |
| `listProviders(): LlmProviderInfo[]` (Remote) | Detached `{id, name}` in registration order. |
| `registerConfigurableProviders(entries): DirectoryRegistrationHandle` | Effect-scoped. Empty initial list throws `INVALID_DIRECTORY`. Each entry needs non-empty `provider`, `displayName`, `settingsNs` and no empty `settingsPath` segment (`INVALID_DIRECTORY`); a provider already declared by another registration or twice in the set throws `DUPLICATE_DIRECTORY`. Entries are detached copies. Emits `llm/adapters-updated` on commit and on disposal. Handle has `replace(entries)` with the same validate-then-swap rule; empty allowed; `REGISTRATION_DISPOSED` after disposal. |
| `listConfigurableProviders(): LlmConfigurableProvider[]` (Remote) | Detached entries in declaration order. |
| `registerModelDiscovery(settingsNs, discover): () => void` | Effect-scoped. Empty namespace throws `INVALID_DISCOVERY`; a second registration for the same namespace throws `DUPLICATE_DISCOVERY`. `discover(request, signal?) => Promise<readonly LlmDiscoveredModel[]>`. |
| `discoverModels(settingsNs, request, signal?)` (Remote as `discoverModels`, implemented by `remoteDiscoverModels`) | `NO_DISCOVERY` when nothing serves the namespace; `INVALID_DISCOVERY` when both `request.provider` and `request.baseURL` are empty. Calls the registered function, drops entries without a non-empty string `id`, deduplicates by id keeping endpoint order, returns only `{id, name?, contextWindow?, maxTokens?, inputModalities?}`. The remote variant wraps any failure in `RemoteError('llm/model-discovery-rejected', message, {settingsNs, baseURL?})`. |
| `providerRetryPolicy(provider): ResolvedRetryPolicy` | The policy captured at registration; `NO_ADAPTER` for an unknown route. |
| `imageRequestPricing(provider, model): LlmImageRequestPricing \| undefined` | Synchronous. Unknown provider returns `undefined` (does not throw). |
| `imageRequestTarget(provider, model, image): ImageRequestTarget` | Delegates to the adapter; `NO_ADAPTER` for an unknown route. |
| `fileRequestText(ref: FileAttachmentRef): string` | `fileHandleText(ref, path)` where `path` comes from `attachments.fileHostPath` mapped through `fs.processPathFromHostPath`; any throw or missing service yields the no-path text. |
| `listModels(provider): Promise<LlmModelInfo[]>` | Calls `adapter.listModels`, validates each entry (`provider` equal to the route, non-empty `id` and `name`, string `description` when present, no duplicate id) else `INVALID_CATALOG`; returns detached `{provider, id, name, description?, inputModalities?, badge?}`. |
| `resolveModelInfo(provider, model, signal?): Promise<LlmResolvedModelInfo>` | `adapter.resolveModel` then `normalizeModelInfo` (see Algorithms). Never returns `badge`. |
| `resolveCallConfig(config, signal?): Promise<LlmCallConfig>` | Validates and materializes defaults without binding a dispatch. |
| `prepareCall(config, signal?, configure?): Promise<PreparedLlmCall>` | Binds model metadata, config, retry policy, and dispatch to one adapter registration. One-shot `stream`. See Algorithms. |
| `stream(options: GenerateOptions): AsyncIterable<StreamChunk>` | Runs the `llm/stream` waterfall whose terminal continuation is the adapter boundary. Always ends with exactly one `finish` chunk when the adapter boundary is reached; adapter throws become `finish {kind: 'error' \| 'aborted'}`. Middleware and consumer exceptions stay thrown. One provider attempt, never retried here. |

Ownership rules: every registration is an effect bound to the registering fiber; disposing the fiber removes the routes, the directory entries, or the discovery offer. A route belongs to exactly one adapter instance. The retry policy is a snapshot taken at registration (or `replace`), not read per request.

Model selection. `GenerateOptions.provider` selects the adapter and nothing else; `GenerateOptions.model` is passed through to it, so any model id is routable on a registered provider. The catalog from `listModels` is advisory: core resolution and streaming accept unlisted ids, while catalog-driven surfaces (the GUI) restrict selection to listed models. Which provider and model an agent uses is session state owned by the core agent packages (the base bundle sets `provider: deepseek-official`, `model: deepseek-flash` through `@deepseek-ai/dsh-agent-default-model`); this area only validates and prepares the chosen route. Reasoning effort is an opaque per-model id: each adapter lists its own efforts in increasing order with an optional default, and the runtime validates membership without clamping.

### The adapter seam — `LlmAdapter` (`packages/llm/llm/src/index.ts:223`)

Abstract class; only `stream` is required. Defaults in parentheses.

| Method | Semantics |
|---|---|
| `providerInfo(provider): LlmProviderInfo` | (`{id: provider, name: provider}`) |
| `providerRetryPolicy(provider): ResolvedRetryPolicy \| undefined` | (`undefined`, meaning normal defaults) |
| `imageRequestPricing(provider, model): LlmImageRequestPricing \| undefined` | (`undefined`) Must be synchronous and free of I/O. |
| `imageRequestTarget(provider, model, image): ImageRequestTarget` | (`{width: image.width, height: image.height, maxBytes: image.bytes}`) |
| `listModels(provider): Promise<readonly LlmModelInfo[]>` | (`[]`) Advisory catalog. |
| `resolveModel(provider, model, signal?): Promise<LlmResolvedModelInfo>` | (`{provider, id: model, name: model}`) Exact-model metadata; must settle promptly after abort. |
| `prepareCall(provider, model, signal?): Promise<PreparedAdapterCall>` | (`{model: await resolveModel(...), stream: options => this.stream(options)}`) Dynamic adapters override it so capabilities and endpoint come from one configuration generation. |
| `stream(options: GenerateOptions): AsyncIterable<StreamChunk>` | Abstract. Must honor `options.signal`. |

`PreparedAdapterCall = {model: LlmResolvedModelInfo, stream(options): AsyncIterable<StreamChunk>}`.

`PreparedLlmCall` (returned by `ctx.llm.prepareCall`, frozen): `config: LlmCallConfig` (deep-frozen, defaults materialized), `retryPolicy: ResolvedRetryPolicy`, `context?: {contextWindow}`, `inputModalities?: readonly ModelModality[]`, `systemPromptUpdate?: 'in-history'`, `toolUpdate?: 'in-history' | 'addition-only'`, `adapterDefaults: {reasoningEffort?: true, maxTokens?: true}`, `stream(options)` (once only; config must equal `config`).

Adapter contract (from `docs/subsystems/llm-streaming.md`, verified against both adapters):

- `usage` before `finish`; nothing after `finish`.
- Tool-call `arguments` are raw JSON strings end to end; fragments stream as `argumentsDelta`.
- Block `index` values are allocated in first-seen order and reused for every delta of that block.
- Two failure paths, one payload type: throw (an `LlmError` with a stable code) or end with `finish {kind: 'error' | 'aborted', failure}`.
- One adapter call is one provider attempt; library retries are disabled.
- Idle stalls are bounded by a watchdog (`streamIdleTimeoutMs`, default 300000) armed only while a read is outstanding; expiry maps to `TIMEOUT`, an earlier caller abort to `ABORTED`.
- Context overflow always surfaces as `CONTEXT_WINDOW_EXCEEDED`; a normal stop with zero content blocks surfaces as `EMPTY_RESPONSE`.
- Every provider HTTP request carries `attributionHeaders()` (the `user-agent` header).
- A request option the provider cannot honor throws `UNSUPPORTED_OPTION` (pi-ai does this for `stop`).
- Replay state is adapter-private; the `{response, blocks?}` split is the shared part.

### `ctx.deepseekLlmApiExtensions` — `DeepSeekLlmApiExtensionRegistry` (`packages/llm/deepseek-llm-api-extensions/src/index.ts:66`)

Default export, Service class, no Config, no `inject`.

- `register(field, provider): () => Promise<void>` — `field` must be non-empty and equal to its trimmed form (else `Error('deepseek-llm-api-extensions: field must be a non-blank trimmed string')`). Effect-scoped; a second registration of the same field throws `deepseek-llm-api-extensions: field "x" is already registered`. `provider.prepare(request)` returns `{value, accept?()}`, `undefined`, or a promise of either.
- `prepare(request: {body, sessionId?, purpose?, signal}): Promise<{fields, accept()}>` — throws at once if `signal` is aborted. Calls every registered provider concurrently. A provider that throws, or whose value cannot be structured-cloned, is omitted; the first failure per field is logged (warn) and later ones are silent. Values are structured-cloned and recursively frozen. The whole wait is abandoned (rejects with the abort reason) when `signal` aborts. `fields` is a frozen null-prototype object. `accept()` is memoized: the first call runs every `accept` callback (each started in a microtask), waits for all to settle, then rethrows the single failure or an `AggregateError('DeepSeek LLM API extension acceptance failed')`; later calls return the same promise.

### `ctx.tokenMeter` — `TokenMeter` (`packages/llm/token-meter/src/index.ts:87`)

Default export, Service class, `static inject = ['sessionProjections']`, `static Config = z.object({})`; the constructor throws `TokenMeterConfig: unknown key "k" (no settings are supported)` for any key. `Service.init` registers four projections in order (`tokenMeasurement`, `tokenUsage`, `contextPressure`, `contextBreakdown`) and listens to `session/event` to keep already-read sessions caught up. Reads `ctx.get('llm')` optionally.

- `contextPressure(session): {pressureTokens?, contextWindow?}` — from the `contextPressure` projection state.
- `measure(session, requestHeader?: EpochHeader): TokenMeasurement` — detached, deep-frozen `{logRevision, baseline, surfaceDeltaTokens, totalTokens, surfaceTokens, nodes}`. See Algorithms.
- `estimateMessage(message): number` — the fixed heuristic for one message.

### Services this area consumes but does not own

`attachments` (`readImageRequest(ref, target, signal)`, `imageHostPath(ref)`, `fileHostPath(ref)`), `fs` (`processPathFromHostPath`), `credentials` (`resolve(ref)`, `describe(ref)`, record CRUD), `deepseekAccount` (`resolveToken(endpoint)`, `rejectToken(token)`), `settings` (`configure({auto: false}, fiber)`), `authorization` (`registerFlow`), `loader` (entry tree), `agents` (`get(sessionId)`), `agentPresets` (`inspectCompositions`), `pluginPackages` (`packageOf`), `sessionProjections` (`register(definition)` returning a handle with `stateOf(session)`), and the launch environment (`launchEnvironmentOf(ctx).get(name)?.value`). All except `llm`, `sessionProjections`, `agents`, `loader`, and `deepseekLlmApiExtensions` (where injected) are read with `ctx.get` and may be absent.

## Events

### Cordis events declared in this area

| Event | Mode | Payload | Producer | Consumers | Notes |
|---|---|---|---|---|---|
| `llm/adapters-updated` | emit | none | `LlmRuntime` at every route or directory commit and at registration disposal | settings and model-selector surfaces; they re-read `listProviders()`, `listModels()`, `listConfigurableProviders()` | Fired after the registry already holds the new state. Listener failures (sync throw or async rejection) are contained and logged with `llm: an llm/adapters-updated listener failed`; they cannot veto the mutation or starve later listeners (`index.ts:382-400` dispatches each listener individually). One event per `replace`. |
| `llm/models-updated` | emit | `(provider: string)` | DeepSeek listing cache via `createModelListingCache` when a loaded listing differs from the previous one, when the route stops following a listing, or when it loses authentication | clients reloading `listModels(provider)` | Only after the cache view changed. |
| `llm/stream` | waterfall | `(this: LlmRuntime, options: GenerateOptions, next: () => AsyncIterable<StreamChunk>) => AsyncIterable<StreamChunk>` | `LlmRuntime.stream` and prepared-call `stream` | `llm-replay` in catch-all mode (returns its own stream and never calls `next`), any routing or observing plugin | Listeners must call `next()` to delegate. Adapter lookup happens only in the terminal continuation, so a listener can short-circuit a request for an unregistered provider. Loop-built requests are deep-frozen and carry the `markAgentLoopRequest` identity. |
| `llm-pi-ai/request-headers` | waterfall, synchronous | `(request: PiAiRequestHeaderContext, headers: Headers, next: () => Headers) => Headers` | `llm-pi-ai` once per inference call (not for discovery) | header-contributing plugins | `request = {provider, model, baseURL, sessionId?, purpose?}` frozen. A throw fails the call with `REQUEST_HEADERS`. After the waterfall the adapter overwrites the attribution header. |

### Cordis events consumed

| Event | Owner | Use here |
|---|---|---|
| `agent/request-error` (waterfall) | `dsh-agent` (`packages/core/agent/src/runtime-types.ts:390`) | `llm-retry` listener. Payload `{agent, turn, step, provider, failure: LlmFailure, retryPolicy: ResolvedRetryPolicy \| undefined, signal}`; result `{kind: 'retry'} \| undefined`. |
| `loader/volatile-update` (emit) | plugin loader | DeepSeek host re-registers the route when the resolved retry policy changed; api-key plugin invalidates the listing cache when it starts or stops following a listing; pi-ai re-evaluates route set and directory. |
| `internal/config` (waterfall) | cordis | pi-ai validates a candidate config for its own fiber with `assertServiceable` before it is accepted. |
| `session/event` | session | token meter catch-up. |

### Session-log events

Produced here (declared in `packages/llm/llm-retry/src/types.ts`): `llm/retry` and `llm/retry-started` (both non-surface; fields under Formats).

Read here: `assistant/message` `{turn, step, message, stream, usage?, interrupted?}`, `assistant/attempt` `{turn, step, stream}`, `request/header`, `request/context`, `step/start`, `step/end`, `turn/start`, `turn/end`, `image/offload`, `compaction/summary`, `compaction/prune`, `system/message`, and every surface event (through `isSurfaceEvent` and `deriveEventMessage`).

Ordering guarantees an implementer must keep: `llm/retry` is appended before the backoff timer starts; `llm/retry-started` is appended after the wait and before the listener returns `{kind: 'retry'}`; the loop appends `assistant/attempt` for the failed attempt before it runs the `agent/request-error` waterfall (`packages/core/agent-loop/src/agent.ts:547-570`).

## Tools

None. No package in this area registers a model-facing tool.

Two model-visible artifacts are produced here and must be reproduced byte for byte; both are specified under Formats: the deterministic text lines that stand in for images and files, and the placeholder tool declaration `DeferredToolPlaceholder` that `llm-pi-ai` adds to an Anthropic request whose projected tools are all deferred.

## Configuration

Conventions shared by every plugin here: schemas are Schemastery objects; fields marked volatile are `Volatile<T>` references read with `.get()` once per operation, so a settings change reaches the next request without re-registration. The settings namespace a plugin declares to the provider directory is `ctx.fiber.entry?.options.id ?? name`, that is, the `id` of its `cordis.yml` entry (`llm-deepseek`, `llm-deepseek-account`, `llm-pi-ai` in `packages/bundle/base/cordis.patch.yml`). Programmatic and settings-driven construction can bypass schema validation, so every resolver re-checks every bound and throws a plain `Error` with a `<plugin>: ...` prefix at load.

### `@deepseek-ai/dsh-llm`

Service class `LlmRuntime` (default export). No Config. No inject.

### Shared DeepSeek protocol fields — `deepSeekConfigFields` (`packages/llm/llm-deepseek/src/config.ts:92-111`)

`@deepseek-ai/dsh-llm-deepseek` is a library with no `name`/`apply`. Its fields are embedded by both provider plugins. All are volatile.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `baseURL` | string | none; resolves to `$DEEPSEEK_BASE_URL` from the launch environment, then `https://api.deepseek.com/anthropic` | Messages root. Must be http(s) with no credentials, query, or fragment. |
| `thinking` | `'enabled' \| 'disabled'` | unset | `disabled` limits the route to effort `off`; combined with a non-`off` `reasoningEffort` it fails at load. |
| `reasoningEffort` | `'off' \| 'low' \| 'high' \| 'max'` | unset (effective `high`, or `off` when thinking is disabled) | Default effort. |
| `maxTokens` | integer ≥ 1 | `256000` | Default per-request output cap. |
| `defaultContextWindow` | integer ≥ 1 | `1000000` | Context capacity for a model with no exact value. |
| `models` | array of catalog models | built-in catalog (below) | Advisory catalog and per-model capabilities. |
| `streamIdleTimeoutMs` | number in (0, 2147483647] | `300000` | Idle watchdog. |
| `maxRequestFilesBytes` | integer ≥ 1 | `134217728` (128 MiB) | Raw-byte image budget in Files mode. |
| `maxInlineRequestImageBytes` | integer ≥ 1 | `20971520` (20 MiB) | Base64-length image budget in inline fallback. |
| `maxImagesPerRequest` | integer ≥ 1 | `600` | Retained image count bound. |
| `imageOffloadByteQuantum` | integer ≥ 1, ≤ `maxRequestFilesBytes` | `67108864` (64 MiB) | Removal step, Files mode. |
| `inlineImageOffloadByteQuantum` | integer ≥ 1, ≤ `maxInlineRequestImageBytes` | `10485760` (10 MiB) | Removal step, inline mode. |
| `imageOffloadCountQuantum` | integer ≥ 1, ≤ `maxImagesPerRequest` | `20` | Removal step for count overflow. |
| `filesApiTimeoutMs` | number in (0, 2147483647] | `60000` | Deadline for resolving one request image through the Files API. |
| `fileExpiresAfterSeconds` | integer 3600..2592000 | `604800` | Upload lifetime. |
| `fileRefreshMarginSeconds` | integer ≥ 0 and < `fileExpiresAfterSeconds` | `3600` | Remaining lifetime below which a cached file id is not reused. |
| `fileQuotaCleanupBatch` | integer 1..1000 | `100` | Oldest harness-owned files deleted before one quota retry. |
| `retryPolicy` | `RetryPolicySchema` | unset (normal defaults) | See below. |

Catalog model entry (`DeepSeekCatalogModel`): `id` (required, non-empty, unique), `name?` (non-empty), `description?`, `contextWindow?` (positive integer), `maxTokens?` (positive integer), `inputModalities?` (non-empty subset of `text`, `image` without duplicates; default `['text']`), `imagePixelBudget?` (positive safe integer or `'low'`; image models only), `imageMaxBytes?` (positive safe integer; image models only; resolved default `2097152`), `systemPromptUpdate?` (`'in-history'` only), `toolUpdate?` (`'in-history' | 'addition-only'`). A key `imageDetail` throws `llm-deepseek: catalog model imageDetail is no longer supported; use imagePixelBudget`. A config key `protocol` throws `llm-deepseek: protocol is not configurable; remove it and use a Messages-compatible baseURL`.

Built-in catalog (`packages/llm/llm-deepseek/src/models.ts`): `{id: 'deepseek-flash', name: 'DeepSeek-V4.1-Flash', contextWindow: 1048576, inputModalities: ['text', 'image'], systemPromptUpdate: 'in-history', toolUpdate: 'addition-only'}` and `{id: 'deepseek-v4-pro', name: 'DeepSeek-V4-Pro', description: 'Stronger agentic coding, knowledge, and difficult reasoning; suited to complex or quality-critical tasks at higher cost.', contextWindow: 1048576}`.

Listing fields (`modelListingConfigFields`, volatile): `modelsTimeoutMs` number in (0, 2147483647], default `5000`; `modelsMaxAgeMs` non-negative safe integer, default `600000` (`0` refreshes on each access and disables the timer).

`RetryPolicySchema` (`packages/llm/llm/src/retry-policy.ts`), a union: `{mode: 'normal', maxRetries?: integer ≥ 0 (default 5), retryableCodes?: non-empty string[] without duplicates (default ['EMPTY_RESPONSE', 'RATE_LIMIT', 'SERVER', 'TIMEOUT', 'TRANSPORT']), backoff?}` or `{mode: 'always', backoff?}`. `backoff = {initialDelayMs?: (0, 2147483647], default 500; maxDelayMs?: same range, default 10000; jitterRatio?: [0, 1], default 0.1}` with `initialDelayMs ≤ maxDelayMs`. Unknown keys throw `<path>: unknown key "k"`. Always mode accepts and ignores leftover `maxRetries` and `retryableCodes`. Codes offered to settings forms (`RETRY_CODE_CHOICES`): `EMPTY_RESPONSE`, `MALFORMED_RESPONSE`, `QUOTA`, `RATE_LIMIT`, `SERVER`, `STREAM_CLOSED`, `TIMEOUT`, `TRANSPORT`; any non-empty string is accepted.

### `@deepseek-ai/dsh-llm-deepseek-api-key`

Function plugin. `name = 'llm-deepseek-api-key'`, `inject = ['llm']`. Config = shared protocol fields + listing fields + `apiKeyEnv: string` (role `credential-ref`, default `'DEEPSEEK_API_KEY'`, volatile). Route `deepseek-official`, provider name `DeepSeek`, directory entry `{provider: 'deepseek-official', displayName: 'DeepSeek', settingsNs, settingsPath: []}`. The route follows the official `/models` listing only when the resolved `baseURL` origin equals `https://api.deepseek.com` and `models` equals the built-in catalog.

### `@deepseek-ai/dsh-llm-deepseek-account`

Function plugin. `name = 'llm-deepseek-account'`, `inject = ['llm']`. Config = shared protocol fields without `models` + listing fields + `modelOverrides: dict<modelId, override>` (default `{}`, volatile), where an override takes the catalog model fields except `id` (an `inputModalities` of `[]` or an undefined field means "inherit"). A config key `models` throws `llm-deepseek-account: models is no longer configurable; ...`. Route `deepseek-account`, provider name `DeepSeek Account`. Authentication comes only from `ctx.get('deepseekAccount')`.

### `@deepseek-ai/dsh-llm-pi-ai`

Function plugin. `name = 'llm-pi-ai'`, `inject = ['llm']`. Config: `providers: dict<route, profile>` (default `{}`, volatile). A bare mount with no profiles registers no route (dormant). Profile fields (`packages/llm/llm-pi-ai/src/config.ts:355-380`):

| Field | Type | Default |
|---|---|---|
| `apiKeyEnv` | string (credential ref) | none (provider-native discovery) |
| `displayName` | non-empty string | route key |
| `api` | `'openai-completions' \| 'openai-responses' \| 'anthropic-messages' \| 'google-generative-ai'` | each catalog model's own protocol |
| `baseURL` | non-empty string | catalog endpoint |
| `models` | array of `{id, name?, contextWindow?, maxTokens?, input?, reasoningEfforts?, compat?}` | installed catalog for the route |
| `modelOverrides` | dict keyed by model id with the same fields minus `id` | none |
| `compat` | compat switch object (26 switches, catalog depth) | none |
| `defaultContextWindow` | integer ≥ 1 | `1000000` |
| `defaultMaxTokens` | integer ≥ 1 | `128000` |
| `defaultInput` | non-empty array of `text`, `image` | `['text']` |
| `headers` | dict of string | none |
| `reasoning` | `off \| minimal \| low \| medium \| high \| xhigh \| max` | none |
| `thinkingBudgets` | `{minimal, low, medium, high}` numbers | none |
| `cacheRetention` | `none \| short \| long` | none |
| `transport` | `sse \| websocket \| websocket-cached \| auto` | none |
| `timeoutMs`, `websocketConnectTimeoutMs` | natural number | none |
| `streamIdleTimeoutMs` | (0, 2147483647] | `300000` |
| `maxRequestImageBytes` | integer ≥ 1 (base64 length) | `20971520` |
| `maxRequestImages` | integer ≥ 1 | `50` |
| `imageOffloadCountQuantum` | integer ≥ 1, ≤ `maxRequestImages` | `min(10, maxRequestImages)` |
| `requestImagePixelBudget` | integer ≥ 1 | `4194304` (2048×2048) |
| `requestImageMaxBytes` | integer ≥ 1 | `1048576` |
| `retryPolicy` | `RetryPolicySchema` | normal defaults |

`reasoningEfforts` on a model: absent inherits the catalog; `false` declares a non-reasoning model; a dict maps offered level to wire spelling (only `off` may have an empty value; at least one level beyond `off` is required). Removed fields `provider`, `maxRetries`, `maxRetryDelayMs` throw with a pointer to their replacement. `providers` given as an array throws.

### `@deepseek-ai/dsh-llm-retry`

Function plugin (async `apply`). `name = 'llm-retry'`, `inject = ['agents', 'sessionProjections']`. Config is empty; a key `retryPolicy` throws `llm-retry: retryPolicy belongs under each provider configuration`, any other key throws `llm-retry: unknown key "k"`. A third `apply` argument `{random?: () => number}` exists for tests only.

### `@deepseek-ai/dsh-token-meter`

Service class `TokenMeter`, `static inject = ['sessionProjections']`, empty Config (any key throws).

### `@deepseek-ai/dsh-deepseek-llm-api-extensions`

Service class `DeepSeekLlmApiExtensionRegistry`. No Config, no inject.

### `@deepseek-ai/dsh-plugin-package-inventory-deepseek`

Function plugin. `name = 'plugin-package-inventory-deepseek'`, `inject = ['agents', 'deepseekLlmApiExtensions', 'loader']`. Config: `enabled: boolean` default `true`; `false` registers nothing.

### `@deepseek-ai/dsh-llm-replay` (test support)

Function plugin. `name = 'llm-replay'`, `inject = ['llm']`. Config: `file?: string` (default `$DSH_SNAPSHOT_FILE`; required from one of the two), `overrideFile?: string` (default `$DSH_SNAPSHOT_OVERRIDE`), `childFiles?: string[]` (default `$DSH_SNAPSHOT_CHILD_FILES` split on the platform path delimiter), `providers?: ReplayProviderConfig[]`, `paceMs?: non-negative integer`. `ReplayProviderConfig = {id, name?, models?: ReplayModelConfig[], retryPolicy?}`. `ReplayModelConfig = {id, name?, description?, contextWindow?, inputModalities?, defaultMaxTokens?, imageRequestTokens?, reasoningEfforts?: string[], defaultReasoningEffort?, systemPromptUpdate?, toolUpdate?, badge?}`. Load-time checks: `inputModalities` only `text`/`image`; `imageRequestTokens` positive safe integer and only with `image`; `systemPromptUpdate` only `in-history`; `toolUpdate` only the two modes; `badge` needs non-blank text (literal or translations containing `en`) and a known tone.

### `@deepseek-ai/dsh-llm-mock-server` (test support)

Library plus CLI source (`src/bin.ts`); not a plugin and no installed binary (run through the repository script `pnpm run mock:llm`). Options under Formats.

## Formats

### 1. Message vocabulary (`packages/llm/llm/src/message.ts`, `types.ts`)

A conversation is an ordered list of immutable (deep-frozen, structured-cloned) messages. Every durable message has `id: MessageId` (a random UUID string), `role`, `content: ContentBlock[]`, `source`.

| Role | Extra fields | `source` | Content rules |
|---|---|---|---|
| `system` | none | `{kind: 'system-prompt'}` | Text blocks only. `createSystemMessage('')` stores `content: []`, meaning "no system prompt". |
| `developer` | none | any `MessageSource` | Carries incremental session changes: `text`, `tool-addition`, `tool-removal` blocks. Tool-change blocks are legal only here. |
| `user` | none | any `MessageSource` (`{kind: 'user'}` or a producer's own kind) | `text`, `image`, `file`. |
| `assistant` | none | `{kind: 'model', provider, model, replayState?}` | `text`, `reasoning`, `tool-call` (role-neutral `image` is reserved; no adapter emits it). |
| `tool` | `toolCallId: ToolCallId`, `isError?: boolean` | `{kind: 'tool', callId}` | Result blocks: `text`, `image`, `file`. |

The role map is closed. `MessageSourceMap` is open (declaration merging): built-ins are `user`, `model`, `tool`, `system-prompt`; other packages add kinds. A source may also carry a context form: `form?: 'instructions' | 'catalog' | 'snapshot' | 'notice' | 'relay' | 'recall'`, with `sections: {name, text}[]` required for `snapshot` and `summary: string` required for `notice`. `CONTEXT_SUMMARY_MAX_CHARS = 120`; `boundContextSummary(s)` returns `s` when `s.length <= 120` (UTF-16 units), else the first 119 units plus `…`.

Request-only input: `RequestUserInput = {role: 'user', content}` with no `id` and no `source`. `RequestMessage = Message | RequestUserInput`.

Constructors: `createMessage`, `createUserMessage`, `createDeveloperMessage`, `createAssistantMessage({content, source: {provider, model, replayState?}})`, `createSystemMessage(text)`, `createToolResultMessage({callId, content, isError})`, `freezeMessage(message)`.

Content blocks (`ContentBlockMap`, open by declaration merging, keyed by `type`):

| `type` | Fields |
|---|---|
| `text` | `text: string` |
| `reasoning` | `text: string` |
| `image` | `attachment: ImageAttachmentRef`, `offloaded?: true` |
| `file` | `attachment: FileAttachmentRef` |
| `tool-call` | `id: ToolCallId`, `name: string`, `arguments: string` (raw JSON text as the model produced it) |
| `tool-addition` | `toolName: string` (the key `tool` is reserved and must be absent) |
| `tool-removal` | `toolName: string` |

Branded string ids (`brand.ts`): `MessageId`, `ToolCallId`, `ProviderRequestId`, `LlmAttemptId`, `ReasoningEffortId`. `ModelModality = 'text' | 'image'` (open map).

### 2. Request and model metadata

`GenerateOptions`: `provider: string`, `model: string`, `reasoningEffort?: ReasoningEffortId`, `messages: RequestMessage[]`, `system?: string` (one-shot callers only; loop requests leave it unset and carry the prompt as a leading `system` message), `tools?: ToolSchema[]`, `toolHistory?: ToolHistory`, `temperature?: number`, `maxTokens?: number`, `stop?: string[]`, `signal?: AbortSignal`, `sessionId?: SessionId`, `purpose?: string` (declared keys of `LlmRequestPurposeMap`; `'compaction'` is the one this area branches on). There is no `tool_choice`, `top_p`, or penalty field.

`ToolSchema = {name, description, parameters: object, deferLoading?: true}`. `ToolHistory = {tools: ToolSchema[], updates: {messageId: MessageId, additions: ToolSchema[]}[]}`.

`LlmCallControls = {reasoningEffort?, temperature?, maxTokens?, stop?}`; `LlmCallConfig = LlmCallControls + {provider, model}`. `callConfigEquals(a, b)` compares all six fields, `stop` element-wise (`undefined` equals only `undefined`). `ConfigureCall = (controls, model) => LlmCallControls` (sync, pure). `LlmCallConfigAdapterDefaults = {reasoningEffort?: true, maxTokens?: true}`. `markAgentLoopRequest(request)` / `isAgentLoopRequest(request)` use a process-local weak set of request object identities.

`LlmProviderInfo = {id, name}`. `LlmModelInfo = {provider, id, name, description?, inputModalities?, badge?}` where `badge = {text: string | {en: string, [lang]: string}, tone: 'neutral' | 'info' | 'success' | 'warning'}`. `LlmResolvedModelInfo = LlmModelInfo + {context?: {contextWindow}, defaultMaxTokens?, reasoning?: {efforts: {id, name, description?}[], defaultEffort?}, systemPromptUpdate?: 'in-history', toolUpdate?: 'in-history' | 'addition-only'}`. `LlmConfigurableProvider = {provider, displayName, settingsNs, settingsPath: string[], declared?, defaultBaseURL?, baseURLEnv?: string[], nativeAuth?: {env: string[], oauth: boolean}, error?}`. `LlmModelDiscoveryRequest = {provider?, baseURL?, api?, apiKey?}`; `LlmDiscoveredModel = {id, name?, contextWindow?, maxTokens?, inputModalities?}`. `LlmImageRequestBudget = {representation: 'raw' | 'base64', maxBytes?, maxImages?, byteQuantum?, countQuantum?}`. `LlmImageRequestPricing = {priceImages(images: ImageBlock[]): {visualTokens, text}[]}` (same length and order as the input).

### 3. Stream chunk vocabulary (`types.ts:496-508`)

A closed union on `type`; a consumer `switch` ends in `assertNever`.

| `type` | Fields |
|---|---|
| `block-start` | `index: number`, `blockType: ContentBlockType` |
| `text-delta` | `index`, `text` |
| `reasoning-delta` | `index`, `text` |
| `tool-call-delta` | `index`, `id: ToolCallId`, `name?: string`, `argumentsDelta: string` |
| `block-end` | `index`, `block: ContentBlock` (the complete block) |
| `usage` | `usage: TokenUsage` |
| `finish` | `reason: FinishReason`, `replayState?: ReplayEnvelope` |

`FinishReason` (open map on `kind`): `{kind: 'stop'}`, `{kind: 'tool-calls'}`, `{kind: 'max-tokens'}`, `{kind: 'aborted', failure: LlmFailure}`, `{kind: 'error', failure: LlmFailure}`.

`ReplayEnvelope = {response: unknown, blocks?: unknown[]}`: lossless JSON; `blocks` has one entry per emitted block in first-seen order.

`TokenUsage = {inputTokens, outputTokens, totalTokens?, cacheReadTokens?, cacheWriteTokens?, reasoningTokens?}`. Buckets are disjoint: `inputTokens` is uncached input only; billed input is `inputTokens + cacheReadTokens + cacheWriteTokens`; `reasoningTokens` is already inside `outputTokens`; `totalTokens` is the exact prompt-plus-output total when known.

`LlmFailure = {message: string (non-empty), code: string (non-empty), status?: integer 100..599, providerRetryAfterMs?: finite > 0, requestId?: ProviderRequestId (non-empty), offloadImages?: positive safe integer}`. `LlmError extends HarnessError` carries a frozen `failure`; its constructor validates those bounds and throws a plain `Error` on violation; `LlmError.fromFailure(failure, {cause?})` re-raises any code.

Failure codes (`LLM_FAILURE_CODES`, `error.ts:17-70`): `ABORTED`, `ACCOUNT_QUOTA`, `ACCOUNT_SIGN_IN_REQUIRED`, `ACCOUNT_TOKEN_INVALID`, `AUTH`, `CLIENT_UPGRADE_REQUIRED`, `CONTEXT_WINDOW_EXCEEDED`, `DISCOVERY_FAILED`, `DISCOVERY_UNSUPPORTED`, `DUPLICATE_ADAPTER`, `DUPLICATE_DIRECTORY`, `DUPLICATE_DISCOVERY`, `EMPTY_RESPONSE`, `FILES_API`, `IMAGE_OFFLOAD_REQUIRED`, `INVALID_ADAPTER`, `INVALID_CATALOG`, `INVALID_CONFIG`, `INVALID_CREDENTIAL`, `INVALID_DIRECTORY`, `INVALID_DISCOVERY`, `INVALID_MODEL_CONTEXT`, `INVALID_MODEL_INFO`, `INVALID_MODEL_MAX_TOKENS`, `INVALID_MODEL_REASONING`, `INVALID_PREPARED_CALL`, `INVALID_REPLAY_STATE`, `INVALID_REQUEST`, `INVALID_RESPONSE`, `MALFORMED_RESPONSE`, `MISSING_CREDENTIAL`, `MODEL_SWITCH_COMPACTION_FAILED`, `MODEL_UNSUPPORTED`, `NO_ADAPTER`, `NO_CREDENTIAL_STORE`, `NO_DISCOVERY`, `PI_AI_ERROR`, `QUOTA`, `RATE_LIMIT`, `REGISTRATION_DISPOSED`, `REQUEST_EXTENSION`, `REQUEST_HEADERS`, `SERVER`, `STREAM_CLOSED`, `TIMEOUT`, `TRANSPORT`, `UNKNOWN`, `UNKNOWN_MODEL`, `UNSTORABLE_PROVIDER_ID`, `UNSUPPORTED_CONTENT`, `UNSUPPORTED_OPTION`, `UNSUPPORTED_REASONING_EFFORT`, plus `HTTP_<status>` for an unclassified status.

### 4. Compact timed stream (`packages/llm/llm/src/assistant-stream.ts`)

The session log embeds one model attempt as `stream: AssistantStreamRecord[]` inside `assistant/message` (attempt that committed a surface message) or `assistant/attempt` (attempt that did not). Record kinds, with exact key sets (validation rejects any extra or missing key):

| `type` | Keys | Meaning |
|---|---|---|
| `text-chunks` | `type, time0, index, dt, texts` | Run of consecutive `text-delta` chunks for block `index`. |
| `reasoning-chunks` | `type, time0, index, dt, texts` | Run of consecutive `reasoning-delta` chunks. |
| `tool-call-chunks` | `type, time0, index, dt, id, args` plus optional `name` | Run of consecutive `tool-call-delta` chunks with the same `index`, `id`, and the same presence and value of `name`. |
| `chunk` | `type, time, chunk` | Any other chunk verbatim (`block-start`, `block-end`, `usage`, `finish`), and a `tool-call-delta` whose `id` is `''` or whose `name` is `''`. |

`time0` is the timestamp (safe integer, session clock milliseconds) of the first member; `dt[i]` is the gap between member `i` and member `i+1`, so `dt.length = members - 1`; `texts`/`args` hold one string per original delta (empty strings included). Member `k` has time `time0 + dt[0] + ... + dt[k-1]`. Example from `snapshots/session/bash-tool-turn/session.v2.jsonl`:

```json
{"type":"chunk","time":1788233485674,"chunk":{"type":"block-start","index":0,"blockType":"reasoning"}}
{"type":"reasoning-chunks","time0":1788233485674,"index":0,"dt":[1,0,0],"texts":["The"," user"," wants"," me"]}
{"type":"tool-call-chunks","time0":1788233485675,"index":1,"dt":[0,0],"id":"call_00_x","name":"bash","args":["","{","\"command\""]}
```

The accumulator, expander, validation rules, and record-level readers are under Algorithms.

### 5. Model-visible strings produced by this area (`packages/llm/llm/src/content.ts`)

`Q(x)` means `JSON.stringify(x)`. `ID(ref)` is `String(ref.attachmentId)` when `ref.name` is undefined, else `Q(ref.name) (attachmentId)`. `D8(ref)` is the 8 hex characters after `sha256:` in `ref.attachmentId`. `EXT` maps `image/png → .png`, `image/jpeg → .jpg`, `image/webp → .webp`, `image/gif → .gif`. `ACCESS(ref, path)` is:

```text
 Normalized copy (read-only; may be resized or re-encoded): Q(path) (WxHpx, mediaType). Source dimensions, format, and byte size may differ. Copy to a writable path ending in EXT before editing.
```

(with a leading space; `W`, `H`, `mediaType` from the durable ref).

| Function | Exact text |
|---|---|
| `textOnlyImageText(ref)` | `[image omitted because this model accepts text only; attachment sha256:D8]` |
| `requestImageHandleText(ref, version, access?)` without access | `Image ID; request preview WvxHvpx. It may be resized or re-encoded; source dimensions, format, and byte size may differ.` (`Wv`, `Hv` from the request version) |
| same, with access | `Image ID; request preview WvxHvpx.` + `ACCESS(ref, access.readonlyPath)` |
| `offloadedImageText(ref)` without access | `[image omitted to fit request image limits; ID. No local normalized image path is available; ask the user to attach it again if needed.]` |
| same, with access | `[image omitted to fit request image limits; ID.` + `ACCESS(...)` + `]` |
| `fileHandleText(ref, undefined)` | `[File Q(name) (N bytes, sha256:D8) was uploaded, but the current execution environment cannot access a readable path. Report that limitation if its contents are needed; do not claim to have read it.]` |
| `fileHandleText(ref, path)` | `[File Q(name) (N bytes, sha256:D8): verbatim read-only copy saved at Q(path). Read that path with your file tools when its contents are needed; copy it to a writable location before modifying it. When delegating file work, include this saved path in the delegation prompt; only subagents sharing this execution environment can read it.]` |

pi-ai only: a later `system` message on a model without mid-conversation system support is sent as a user message `<system-reminder>\n` + text with every `</system-reminder>` replaced by `<\/system-reminder>` + `\n</system-reminder>`. A tool result with empty text is sent as `(no output)`. The placeholder tool declaration is `{name: 'DeferredToolPlaceholder', description: 'Reserved placeholder that keeps deferred tool loading active; never call this tool.', parameters: {type: 'object', properties: {}}}`.

### 6. App attribution (`packages/llm/llm/src/attribution.ts`)

`APP_IDENTITY = {product: 'deepseek-harness', version: <dsh-llm package.json version>, url: 'https://github.com/deepseek-ai/deepseek-harness', suffix}` where `suffix` reads environment variable `DSH_USER_AGENT_SUFFIX` on every use (unset or empty means none; a value not matching the RFC 9110 product pattern below throws `DSH_USER_AGENT_SUFFIX must be an RFC 9110 product token; got "..."`).

```text
^[!#$%&'*+.^_`|~0-9A-Za-z-]+(?:\/[!#$%&'*+.^_`|~0-9A-Za-z-]+)?$
```

`userAgent()` is `product/version (+url)` plus ` suffix` when present, for example `deepseek-harness/0.2.2-rc.2 (+https://github.com/deepseek-ai/deepseek-harness) dsh-profile/web`. `attributionHeaders()` returns `{'user-agent': userAgent()}`.

API key check (`api-key.ts`): `normalizeApiKey(raw)` trims, then rejects `''` (`empty`) and anything not matching `^[\x21-\x7E]+$` (`illegalCharacters`). `assertUsableApiKey(raw, pkg, ref)` throws `INVALID_CREDENTIAL` with a message naming `ref` and never the key.

### 7. DeepSeek Messages wire format (`packages/llm/llm-deepseek/src`)

Endpoint. `POST {root}/messages`, where `root = messagesApiRoot(baseURL)`: strip trailing slashes; if the URL path already ends in `/v1` use it as is, else append `/v1`. Default: `https://api.deepseek.com/anthropic/v1/messages`. `fetch` is called with `redirect: 'error'` and the request signal.

Request headers, in merge order (later wins):

| Header | Value |
|---|---|
| `user-agent` | `userAgent()` |
| `content-type` | `application/json` |
| `accept` | `text/event-stream` |
| auth | `x-api-key: <key>` (route `deepseek-official`) or `x-dsh-auth-token: <token>` (route `deepseek-account`); no `Bearer` prefix in either |
| `anthropic-version` | `2023-06-01` |
| `anthropic-beta` | present only when needed: `files-api-2025-04-14` when the body references file ids, `mid-conversation-tool-changes-2026-07-01` when any message contains a `tool_addition` or `tool_removal` block; joined with `,` in that order |
| `x-deepseek-harness-user-id` | stable anonymous UUID of the harness home (`getOrCreateAnonymousUserId()`, resolved lazily after auth succeeded) |
| `x-deepseek-harness-session-id` | `String(options.sessionId)` when present |
| `x-deepseek-harness-compact` | `1` when `options.purpose === 'compaction'` |

Request body (`WireRequest`, `wire-types.ts`), plus any extension fields merged at top level:

```json
{
  "model": "deepseek-flash",
  "stream": true,
  "messages": [
    {"role": "user", "content": [{"type": "text", "text": "hello"}]},
    {"role": "assistant", "content": [
      {"type": "thinking", "thinking": "Read the file.", "signature": "..."},
      {"type": "text", "text": "Checking a."},
      {"type": "tool_use", "id": "a", "name": "read", "input": {"path": "a"}}]},
    {"role": "user", "content": [
      {"type": "tool_result", "tool_use_id": "a", "content": [{"type": "text", "text": "result"}], "is_error": false}]},
    {"role": "system", "content": [
      {"type": "text", "text": "new prompt"},
      {"type": "tool_addition", "tool": {"type": "tool_reference", "name": "grep"}}]}
  ],
  "max_tokens": 256000,
  "thinking": {"type": "enabled"},
  "output_config": {"effort": "high"},
  "system": "leading prompt",
  "temperature": 0.2,
  "stop_sequences": ["END"],
  "tools": [{"name": "read", "description": "...", "input_schema": {}, "defer_loading": true}]
}
```

Field rules: `model`, `stream: true`, `messages`, `max_tokens`, `thinking` are always present. `max_tokens = options.maxTokens ?? catalogModel.maxTokens ?? connection.maxTokens`. Effort `e = options.reasoningEffort ?? defaults.reasoningEffort ?? (defaults.thinking === 'disabled' ? 'off' : 'high')`; `thinking.type` is `disabled` when `e === 'off'`, else `enabled`; `output_config: {effort: e}` is present only when `e !== 'off'`. `system` is present only when non-empty. `temperature`, `stop_sequences`, `tools` are present only when the option is defined (an empty `tools` array is sent as `[]`). `defer_loading: true` only for a tool with `deferLoading === true`. Wire roles are `user`, `assistant`, `system`. Wire content block types: `text`, `image` (`source: {type: 'base64', media_type, data}` or `source: {type: 'file', file_id}`), `thinking` (`thinking`, optional `signature`), `tool_use` (`id`, `name`, `input` object), `tool_result` (`tool_use_id`, `content` of text/image blocks, optional `is_error`), `tool_addition` / `tool_removal` (`tool: {type: 'tool_reference', name}`).

Response. HTTP 2xx with an SSE body. Each frame's `data` is a JSON object with a string `type`; if the frame has an `event:` line it must equal `type`. Events the translator reads:

| SSE `type` | Fields read |
|---|---|
| `message_start` | `message.usage` (`input_tokens`, `output_tokens`, `cache_read_input_tokens`, `cache_creation_input_tokens`) |
| `content_block_start` | `index`, `content_block`: `{type: 'text', text}`, `{type: 'thinking', thinking, signature?}`, or `{type: 'tool_use', id, name, input}` |
| `content_block_delta` | `index`, `delta`: `{type: 'text_delta', text}`, `{type: 'thinking_delta', thinking}`, `{type: 'signature_delta', signature}`, `{type: 'input_json_delta', partial_json}` |
| `content_block_stop` | `index` |
| `message_delta` | `delta.stop_reason` (`end_turn`, `stop_sequence`, `tool_use`, `max_tokens`), `usage` (same four counters, cumulative, last value wins per counter) |
| `message_stop` | none |
| `error` | `error.type`, `error.code`, `error.message` (thrown as a provider error) |
| anything else (for example `ping`) | ignored; still counts as transport activity, as do SSE comment lines |

Usage mapping: `input_tokens → inputTokens`, `output_tokens → outputTokens`, `cache_read_input_tokens → cacheReadTokens`, `cache_creation_input_tokens → cacheWriteTokens`; each must be a non-negative safe integer when present. `input_tokens` is already uncached input (Anthropic semantics), so nothing is subtracted. At `message_stop` the adapter sets `totalTokens = inputTokens + outputTokens + (cacheReadTokens ?? 0) + (cacheWriteTokens ?? 0)`. `reasoningTokens` is never set by this adapter.

Replay envelope on a successful finish: `{response: {kind: 'deepseek-messages', version: 1, model: <requested model>}, blocks: [{type: 'text'} | {type: 'reasoning', signature?: string} | {type: 'tool-call'}, ...]}`, one entry per emitted block.

HTTP error bodies are read as `{"error": {"message", "type", "code"}}`; a non-JSON body is tolerated. Headers read from an error response: `retry-after` (decimal seconds, or an HTTP date) and the first present of `request-id`, `x-request-id`, `x-deepseek-request-id`.

### 8. DeepSeek Files API (`files-api.ts`, `file-store.ts`, `upload-index.ts`)

Base `{root}/files` with the same `root`. Every request sends `user-agent`, the auth headers, `anthropic-version: 2023-06-01`, `anthropic-beta: files-api-2025-04-14`, `redirect: 'error'`.

| Operation | Request | Response |
|---|---|---|
| upload | `POST /files`, multipart form: `expires_after[anchor]=created_at`, `expires_after[seconds]=<n>`, `file=<bytes>` with the media type and filename | `{id, type: 'file', mime_type, size_bytes, created_at (ISO string), filename}`; local `expiresAt = createdAt + expiresAfterSeconds` |
| list | `GET /files?after_id=<id>&limit=<n>` | `{data: [...], first_id?, last_id?, has_more}` |
| retrieve | `GET /files/<id>` | file object |
| delete | `DELETE /files/<id>` | `{id, type: 'file_deleted'}` |

Limits: upload ≤ 128 MiB (`INVALID_REQUEST`), expiry 3600..2592000 s, per-image store limit `MAX_IMAGE_BYTES = 32 MiB`. Uploaded filename: `dsh-<first 16 hex of attachmentId>-<first 8 hex of variantId>.<png|jpeg|webp|gif>`; the `dsh-` prefix marks harness ownership for quota cleanup. Files errors are `DeepSeekFilesError` with code `AUTH` (401/403), `RATE_LIMIT` (429), `SERVER` (≥500), else `FILES_API`; a transport failure is `TRANSPORT`; an invalid success body is `INVALID_RESPONSE`.

Upload index file: `$DSH_HOME/llm-deepseek/files-v3.json`, mode 0600 (directory 0700), written atomically under a file lock, pretty-printed with two spaces and a trailing newline:

```json
{"formatVersion": 3, "records": [{"scope": "<64 hex>", "attachmentId": "sha256:<64 hex>", "variantId": "sha256:<64 hex>", "fileId": "file-...", "bytes": 1234, "createdAt": 1780000000000, "expiresAt": 1780604800000}]}
```

Times are Unix milliseconds. `(scope, variantId)` is unique. An unreadable, invalid, or wrong-version file is treated as empty. `scope = sha256hex(root-without-trailing-slashes + "\0" + JSON.stringify(sorted [name, value] header pairs))`, for example the credentials string `[["x-api-key","sk-..."]]`.

### 9. DeepSeek model listing (`listing.ts`)

`GET <origin of baseURL>/models` (for the official route `https://api.deepseek.com/models`) with `user-agent`, `accept: application/json`, and the auth header; `redirect: 'error'`; deadline `modelsTimeoutMs`. Body `{"data": [entry, ...]}`. Entry fields read: `id` (required non-empty string; rows without one and repeated ids are skipped and counted), `name`, `client_requirements["deepseek-harness"].min_version`, `client_metadata["deepseek-harness"].badge = {text: string | {<lang>: string}, tone}`, `api_capabilities.anthropic_messages = {system_prompt_update?, tool_update?}`, `input_modalities`, `output_modalities`, `context_window`, `max_output_tokens`. Errors: `TIMEOUT`, `ABORTED`, `TRANSPORT`, `HTTP_<status>`, `INVALID_RESPONSE` (no `data` array, non-JSON, or no usable entry).

### 10. Request extension field `dsh_plugin_packages`

`{"version": 1, "packages": [{"name": "<npm name>", "version"?: "<version>"}]}`. Deduplicated by `(name, version ?? '')`, sorted by `name` then `version ?? ''` using plain code-unit string comparison (not locale collation). Present on every extended request when the plugin is enabled, including `packages: []`. The other shipped field, `dsh_session_log`, belongs to the session area; its transaction rules are the registry's.

### 11. Session events and projection state

`llm/retry` data: normal mode `{retryId, turn, step, provider, mode: 'normal', policyKey, retry, maxRetries, delayMs, failure}`; always mode the same without `maxRetries` and with `mode: 'always'`. `llm/retry-started` data: `{retryId, turn, step, retry}`. `retryId` is a random UUID shared by every retry in one step's chain.

`policyKey` is an exact string: normal mode `JSON.stringify([mode, maxRetries, sortedCodes, initialDelayMs, maxDelayMs, jitterRatio])`, for the default policy `["normal",5,["EMPTY_RESPONSE","RATE_LIMIT","SERVER","TIMEOUT","TRANSPORT"],500,10000,0.1]`; always mode `JSON.stringify(['always', initialDelayMs, maxDelayMs, jitterRatio])`. Codes sort by code-unit order.

Projection definitions (key, `stateVersion`, initial state):

| Key | Version | State | Wire view |
|---|---|---|---|
| `llmRetry` | 1 | `{[JSON.stringify([provider, policyKey])]: {retry: number, retryId: string}}`; init `{}` | none |
| `tokenMeasurement` | 2 | `{headerSeq: seq \| null, stepStart: {turn, step} \| null, anchor: {headerSeq, assistantTokens, usage \| null} \| null, invalidSeq: seq \| null}` | none |
| `tokenUsage` | 2 | `{totals: {uncachedInputTokens, outputTokens, cacheReadTokens, cacheWriteTokens}, last: {turn, step, buckets} \| null}` | `totals` |
| `contextPressure` | 5 | `{contextWindow?, pressureTokens?, surfaceTokens, sampledSurfaceTokens?, claim?: {start, end, tokens}}`; init `{surfaceTokens: 0}` | `{contextWindow?, pressureTokens?, projectedTokens?}`; excluded from summaries |
| `contextBreakdown` | 6 | `{systems: {seq, tokens}[], surfaceTokens, claim?: {start, end, tokens, systemSeqs}, breakdown: {systemTokens, toolsTokens, messageTokens}}` | `breakdown`; excluded from summaries |

### 12. pi-ai replay envelope (`llm-pi-ai/src/replay.ts`)

`response = {kind: 'pi-ai', version: 2, api, provider, model (requested), responseModel?, responseId?, providerThinkingLevel?, stopReason: 'stop' | 'length' | 'toolUse' | 'error' | 'aborted', prefixDigest?}`; `blocks[i]` is `{type: 'text', textSignature?}`, `{type: 'reasoning', thinkingSignature?, redacted?}`, or `{type: 'tool-call', thoughtSignature?, namespace?}`.

### 13. Mock LLM server (`packages/test-support/llm-mock-server/src/index.ts`)

`startMockLlmServer(options)` returns `{baseURL (no /v1), port, randomSeed, requests, close()}`. Options and defaults: `host` `'127.0.0.1'`, `port` `0`, `apiKey?` (when set, `x-api-key` must equal it), `sequence` (required, non-empty), `repeatLast` `false`, `randomSeed?` uint32 (generated when absent), `randomWeights?`, `successText` `'mock response recovered'`, `partialText` `'discarded partial response'`, `reasoningText` `'mock reasoning'`, `chunkSize` `8` (Unicode code points per delta), `chunkDelayMs` `25`, `disconnectDelayMs` `10`, `retryAfterMs` `1000` (≥ 1), `requestId?`, `toolName` `'mock_tool'`, `toolArguments` `'{"value":"mock"}'` (must parse as JSON), `onEvent?`.

Routing: a non-`POST` gets 405 with `allow: POST`; a path not ending in `/v1/messages` gets 404; a wrong key gets 401 `{"error":{"message":"invalid mock API key","code":"invalid_api_key"}}`; an unparseable body gets 400 `{"error":{"message":"request body must be valid JSON","code":"invalid_json"}}`. None of these consume the script. Each accepted request consumes the next script entry; after exhaustion the entry is the last one when `repeatLast`, else `script_exhausted` (HTTP 500 `{"error":{"message":"mock script exhausted","type":"mock_error","code":"MOCK_SCRIPT_EXHAUSTED"}}`).

SSE framing: `event: <type>\ndata: <json>\n\n`; headers `content-type: text/event-stream; charset=utf-8`, `cache-control: no-cache`, `connection: keep-alive`. Building blocks: `START = {type: 'message_start', message: {id: 'mock-message', type: 'message', role: 'assistant', model: 'mock-model', content: [], usage: {input_tokens: 3, output_tokens: 0}}}`; `TERMINAL(reason, n) = {type: 'message_delta', delta: {stop_reason: reason, stop_sequence: null}, usage: {output_tokens: n}}`; `STOP = {type: 'message_stop'}`; `TEXT(text, i)` = `content_block_start {index: i, content_block: {type: 'text', text: ''}}`, one `content_block_delta {index: i, delta: {type: 'text_delta', text}}` per `chunkSize` code points, `content_block_stop {index: i}`.

| Behavior | Wire result |
|---|---|
| `connection_reset` | destroy the socket before any response |
| `stream_disconnect` | SSE headers, wait `disconnectDelayMs`, destroy |
| `empty` | `START`, `TERMINAL('end_turn', 0)`, `STOP`, end |
| `empty_body` | SSE headers, end |
| `stream_eof` | `START`, end |
| `partial_eof` | `START`, text block start, deltas of `partialText`, end (no stop events) |
| `partial_disconnect` | `START`, text block start, deltas of `partialText` paced by `chunkDelayMs`, wait `disconnectDelayMs`, destroy |
| `stall` | SSE headers, then nothing until the client or server closes |
| `malformed_json` | one frame `data: {not-json` (no `event:` line), `STOP`, end |
| `malformed_event` | `content_block_start {index: 0, content_block: null}`, `STOP`, end |
| `wrong_content_type` | as `success` but `content-type: application/json` |
| `rate_limit` | 429 `{"error":{"message":"mock rate limit","type":"mock_error","code":"rate_limit"}}` with `retry-after: ceil(retryAfterMs/1000)` |
| `server_error` | 500, message `mock server error`, code `server_error` |
| `service_unavailable` | 503, message `mock service unavailable`, code `service_unavailable` |
| `auth_error` | 401, message `mock authentication failed`, code `invalid_api_key` |
| `invalid_request` | 400, message `mock invalid request`, code `invalid_request` |
| `context_overflow` | 400, message `mock input exceeds the model context window`, code `context_length_exceeded`, type `invalid_request_error` |
| `quota_exceeded` | 429, message `mock insufficient quota`, code `insufficient_quota` |
| `success` | `START`, `TEXT(successText, 0)`, `TERMINAL('end_turn', codePoints(successText))`, `STOP`, end |
| `reasoning_success` | `START`, `content_block_start {index: 0, content_block: {type: 'thinking', thinking: ''}}`, `thinking_delta` chunks of `reasoningText`, `content_block_stop {index: 0}`, then `TEXT(successText, 1)`, `TERMINAL('end_turn', ...)`, `STOP` |
| `tool_call_success` | `START`, `content_block_start {index: 0, content_block: {type: 'tool_use', id: 'mock-call-1', name: toolName, input: {}}}`, two `input_json_delta` frames splitting `toolArguments` at `max(1, floor(length/2))`, `content_block_stop`, `TERMINAL('tool_use', 2)`, `STOP` |
| `max_tokens` | as `success` with `TERMINAL('max_tokens', ...)` |
| `slow_success` | as `success` with `chunkDelayMs` between deltas |
| `random` | pick a concrete behavior by seeded weights (see Algorithms) |

All HTTP errors use `content-type: application/json` and add `x-request-id: <requestId>` when configured. Default random weights: `success 48, slow_success 10, max_tokens 2, connection_reset 5, stream_disconnect 5, partial_disconnect 10, empty 5, stall 2, rate_limit 5, server_error 4, service_unavailable 2, partial_eof 1, malformed_json 1`.

Records: `requests[i] = {attempt (1-based), scriptBehavior, behavior, path, headers, body, chunksSent, outcome?}` with `outcome ∈ completed | reset | stalled | client_closed | server_error`. Telemetry events: `{type: 'request', attempt, scriptBehavior, behavior, path}` and `{type: 'result', attempt, scriptBehavior, behavior, outcome, chunksSent}`.

CLI flags (`src/cli.ts`; strict parsing, no positionals): `--sequence <a,b,...>` (required), `--host`, `--port` (default `8000`), `--api-key`, `--listen-delay-ms` (default `750`, only with `connection_refused`), `--repeat-last`, `--seed`, `--random-weights <a=n,...>`, `--success-text`, `--partial-text`, `--reasoning-text`, `--chunk-size`, `--chunk-delay-ms`, `--disconnect-delay-ms`, `--retry-after-ms`, `--request-id`, `--tool-name`, `--tool-arguments`, `--help`. `connection_refused` is a CLI-only behavior allowed only as the first sequence entry and requires a nonzero `--port`: the process prints `{"type":"unavailable","baseURL":"http://host:port/v1","listenDelayMs":n}`, waits, then binds. `--seed` and `--random-weights` require `random` in the sequence. Stdout is JSONL: optional `unavailable`, then `{"type":"ready","baseURL":"<base>/v1","randomSeed":n}`, then the telemetry events. Exit codes: 130 on SIGINT, 143 on SIGTERM, 1 on an argument error (message plus usage on stderr). The usage text says `--api-key` validates a Bearer token; the server actually compares the `x-api-key` header.

### 14. Replay fixtures (`packages/test-support/llm-replay/src/index.ts`)

Primary fixture: one session log, `session.jsonl` (format v0) or `session.vN.jsonl`, a JSONL file whose first non-empty line is the session header (`{"type":"session","version":N,"id":...,"createdAt":...,...}`) and whose remaining lines are events. Body rows either all carry `seq` and `time` (packed historical rows: `seq0` and `time0`) or all omit them; when omitted, replay assigns dense sequence numbers starting at 0 and time 0 (a packed row advances the sequence by its member count). Fixture tokens: header `cwd` beginning `{{cwd}}` is read as `/dsh-snapshot-cwd`; `request/header` `data.header.tools` equal to the string `{{tools}}` is dropped for validation; a `tools` array of names is expanded to `{name, description: '', parameters: {}}`; a v0 header without `delegationDepth` gets `0`. The complete artifact is decoded and migrated through the session format catalog before use (session area).

Derived script (`deriveReplayScript`): walk events in order; each `assistant/message` and `assistant/attempt` yields one entry `{kind: 'chunks', chunks: expandAssistantStream(stream).map(chunk)}`, skipped when the expansion is empty, and an error when its last chunk is not `finish` (`llm-replay: model call T/S ended without a finish chunk (a thrown stream); this scenario needs a replay.override.json sidecar`). Each `compaction/summary` with `llmStreamCall === true` yields a synthetic entry from `rawOutput`: for each block `block-start {index, blockType}` then `block-end {index, block}`, then `usage` when recorded, then `finish {reason: {kind: 'stop'}}`.

`ReplayEntry`:

```ts
| { kind: 'chunks'; chunks: StreamChunk[] }
| { kind: 'throw'; chunks: StreamChunk[]; message: string; code: string; accepted?: boolean }
| { kind: 'hang'; readyFile?: string }
```

Override sidecar (`replay.override.json`): either a bare `ReplayEntry[]` (replaces the whole primary script) or `{"patches": [{"at": <0-based call index>, "entry": ReplayEntry}]}` (keeps the derived script; `at === derived length` appends; `at` greater than that or a duplicate `at` is an error). Validation is exact-key: `chunks` entries have exactly `kind, chunks`; `throw` exactly `kind, chunks, message, code` plus optional boolean `accepted`; `hang` exactly `kind` plus optional non-empty `readyFile`; each chunk needs a known `type`. Examples:

```json
[{ "kind": "hang", "readyFile": ".dsh-snapshot-stream-ready" }]
```

```json
[{"kind": "chunks", "chunks": [
  {"type": "block-start", "index": 0, "blockType": "tool-call"},
  {"type": "tool-call-delta", "index": 0, "id": "call_session_root", "name": "write", "argumentsDelta": "{\"file_path\":\"session-root.txt\",\"content\":\"session root\"}"},
  {"type": "block-end", "index": 0, "block": {"type": "tool-call", "id": "call_session_root", "name": "write", "arguments": "{\"file_path\":\"session-root.txt\",\"content\":\"session root\"}"}},
  {"type": "usage", "usage": {"inputTokens": 10, "outputTokens": 5}},
  {"type": "finish", "reason": {"kind": "tool-calls"}}]}]
```

Placeholders inside any string of an entry, resolved at replay time: `{{session:N}}` (N ≥ 1) becomes the live session id bound to recorded script N (error if that script is not bound yet); `{{fromRequest:<regex>}}` becomes the last match of the regex (global flag) in the corpus formed by every string leaf of the live request `messages` joined with `\n`, using capture group 1 when present, else the whole match. The placeholder ends at the last two braces of a run of `}` so a pattern may end in `{4}`. No match, an invalid pattern, or an unterminated placeholder is an error.

Child fixtures (`childFiles`): one log per recorded subagent session; only events from index `inheritedEventCount` onward are derived.

### 15. Environment variables and files

| Name | Reader | Meaning |
|---|---|---|
| `DEEPSEEK_API_KEY` | default credential reference of `llm-deepseek-api-key` (through `credentials`, or the launch environment when that service is absent) | API key |
| `DEEPSEEK_BASE_URL` | `resolveAdapterOptions` through the launch environment snapshot | Messages root override |
| `DSH_USER_AGENT_SUFFIX` | `attribution.ts`, read from `process.env` on each use | `User-Agent` suffix; the `dsh` launcher sets `dsh-profile/<profile>` |
| `DSH_SNAPSHOT_FILE`, `DSH_SNAPSHOT_OVERRIDE`, `DSH_SNAPSHOT_CHILD_FILES` | `llm-replay` `apply` | fixture paths |
| `DSH_HOME` (via `resolveDshHome()`) | upload index | `llm-deepseek/files-v3.json` |
| provider environment names listed in `llm-pi-ai/src/provider-data.generated.ts` | pi-ai native auth through `authContextFrom` (credentials first, then launch environment) | per-provider keys and endpoint parts |

## Algorithms and invariants

### A. `LlmRuntime` (`packages/llm/llm/src/index.ts`)

A1. Registry atomicity (`:416-491`). `prepareRoutes` validates the complete candidate set without mutating; `commitRoutes` deletes the owned routes, inserts the new ones, and emits once, all synchronously, so no reader sees a gap. A `released` flag (not an empty owned set) decides whether `replace` is still legal, because `replace([])` legally leaves a live registration with no routes.

A2. `normalizeModelInfo` (`:793-901`). Rejects with `INVALID_MODEL_INFO` when `provider`/`id` differ from the request, `name` is empty, `description` is not a string, `systemPromptUpdate` is anything but `'in-history'`, or `toolUpdate` is anything but the two modes; `INVALID_MODEL_CONTEXT` when `contextWindow` is not a positive integer; `INVALID_MODEL_MAX_TOKENS` when `defaultMaxTokens` is not a positive safe integer; `INVALID_MODEL_REASONING` when `efforts` is empty, an effort has an empty or duplicate `id` or empty `name`, or `defaultEffort` is not in the list. The result is a fresh object; `badge` is dropped.

A3. `resolveCallWithInfo` (`:927-961`). (1) If `config.maxTokens` is undefined and the model has `defaultMaxTokens`, set it. (2) If the model has no `reasoning` and the config names an effort, throw `UNSUPPORTED_REASONING_EFFORT` (`provider "p" model "m" does not support reasoning effort "e"`). (3) Otherwise `effective = requested ?? reasoning.defaultEffort`; when defined it must be one of `efforts` (same error); no clamping or aliasing; materialize it when the caller left it unset.

A4. `prepareCall` (`:975-1033`). Order: throw if aborted; look up the registration (`NO_ADAPTER`); `adapter.prepareCall(provider, model, signal)`; throw if aborted; normalize the returned model info; when `configure` is given call it once with deep-frozen clones of the controls and the model info and merge its result with the fixed `provider`/`model`; throw if aborted; `resolveCallWithInfo`; deep-freeze the config and context; compute `adapterDefaults` (`reasoningEffort: true` when the proposal had none and the result has one; same for `maxTokens`). The returned `stream(options)` throws `INVALID_PREPARED_CALL` synchronously when called twice (`a prepared LLM call can only be dispatched once`) or when `callConfigEquals(options, config)` is false (`prepared LLM call config changed before adapter dispatch`); otherwise it runs the `llm/stream` waterfall with the captured registration, model info, and adapter dispatch.

A5. Adapter boundary `adapterStream` (`:1083-1172`), the terminal continuation of the waterfall. Setup, all inside one `try` whose failure becomes a single terminal chunk:

1. Take the prepared registration or look it up (`NO_ADAPTER`).
2. Unprepared: `adapter.prepareCall(provider, model, options.signal)`, normalize, `resolveCallWithInfo(options, info)`. Prepared: reuse the captured values and re-check config equality.
3. If the resolved config differs from the options, overlay it (`{...options, ...resolvedConfig}`), keeping frozenness.
4. If any message contains a `file` block, replace every file block with a text block `fileHandleText(ref, path)` (`projectFilesToText`).
5. If the model declares `inputModalities` without `image` and any message contains an image, replace every image block with `textOnlyImageText(ref)` (`projectImagesForTextModel`). A model with undeclared modalities is not projected.
6. `projectToolUpdates(messages, tools, modelInfo.toolUpdate, toolHistory)` (A7).
7. `forAdapter` (`:1042-1056`): for each assistant message with `source.replayState`, keep it only when the adapter registered for `source.provider` is this same adapter instance; otherwise send a copy whose source is `{kind: 'model', provider, model}`.
8. Call the dispatch and obtain its async iterator.

Iteration: each `iterator.next()` is awaited inside its own `try`; a throw yields one failure chunk and ends. Values are yielded outside that `try`, so an exception thrown into the generator by a consumer or middleware is not converted. If the consumer stops early, `iterator.return()` is awaited. The failure chunk is `{type: 'finish', reason: {kind, failure: normalizeLlmFailure(error)}}` with `kind = 'aborted'` when `options.signal` is aborted or the failure code is `ABORTED`, else `'error'` (`:1203-1211`).

A6. `normalizeLlmFailure` (`adapter-failure.ts:17`). A non-`Error` throw becomes code `UNKNOWN` with message `String(value)` or `LLM adapter failed`. For an `Error`: if it has an own data property `failure` that validates as an `LlmFailure` and whose `code` equals the error's own data property `code`, use that snapshot; otherwise `{message: error.message or 'LLM adapter failed', code: HarnessError ? error.code : 'UNKNOWN'}`. Accessor properties are never invoked. Third-party error codes are never trusted.

A7. `projectToolUpdates` (`content.ts:439-510`).

1. Mode undefined: strip `deferLoading` from every tool and drop every developer message.
2. No `history`, or a `history.updates[].messageId` with no matching developer message in the request: drop every developer message, keep `tools` as given.
3. `addition-only` first rebases history (`:397-423`): walk the updates keeping `available` (initially the history tools by name). An update resets the baseline when it contains a `tool-removal` or when it adds tools while `available` is empty. Additions enter `available` without `deferLoading`; removals leave it. After a reset the baseline becomes the current `available` values and only later updates are retained.
4. Declarations: the (rebased) baseline tools, then every retained update's additions not already declared, marked `deferLoading: true`.
5. Walk messages. Non-developer messages pass. A developer message whose id is not in the original history is dropped. Otherwise filter its blocks: `tool-addition` survives only if its update is retained, the tool is declared, and it is not already offered (then it becomes offered); `tool-removal` survives only in `in-history` mode and only if the tool was offered (then it is no longer offered); other blocks survive. A message left empty is dropped.
6. Result tools are the declaration values in insertion order. In `in-history` mode a removed tool keeps its declaration. If nothing changed the original message array is returned.

A8. `requiredImageOffload` (`content.ts:285-333`). `lengths` = for each image block not marked `offloaded`, in message order, the request-version byte count, or `ceil(bytes/3)*4` for `base64`. `excessCount = max(0, n - maxImages)`, `excessBytes = max(0, sum - maxBytes)`; both zero returns 0. `removeCount = ceil(excessCount / countQuantum) * countQuantum`, `removeBytes = ceil(excessBytes / byteQuantum) * byteQuantum` (quanta default 1). Take oldest images until `count >= removeCount` and the byte target is met, where met means `removeBytes == 0`, or `removed >= removeBytes` when `byteQuantum == 1`, or `removed > removeBytes` otherwise. The route never offloads on its own: it fails with `IMAGE_OFFLOAD_REQUIRED` and `offloadImages = count`; `dsh-compaction-image-offload` logs an `image/offload` event and the step is retried.

A9. Text classifiers (`error.ts:111-160`), applied to `type + ' ' + code + ' ' + message`:

```text
context overflow, any of:
  /(?:^|[^a-z0-9])context[\s_-](?:length|window)[\s_-](?:exceed(?:ed|s)?|overflow(?:ed)?|limit[\s_-]exceeded)(?:$|[^a-z0-9])/i
  /\b(?:maximum|max)(?:\s+(?:allowed|supported))?\s+context\s+(?:length|window)\b/i
  /\b(?:request|prompt|input|messages?)\s+(?:is\s+|are\s+)?too\s+(?:large|long)\s+for\s+(?:(?:this|the)\s+)?(?:model(?:'s)?\s+)?context(?:\s+window)?\b/i
  /\b(?:input|prompt|request)\s+(?:is\s+)?too\s+(?:long|large)\s+for\s+(?:this|the)\s+model\b/i
  /\b(?:input|prompt|request|messages?)\b.{0,40}\b(?:exceed(?:s|ed)?|overflows?|is\s+larger\s+than)\b.{0,40}\b(?:the\s+)?(?:model(?:'s)?\s+)?context(?:\s+(?:length|window))?\b/i
quota, any of:
  /\binsufficient[\s_-]+(?:quota|balance|credits?)\b/i
  /\b(?:quota|usage[\s_-]+limit)[\s_-]+(?:exceeded|exhausted|reached)\b/i
  /\bexceed(?:ed|s)?[\s_-]+(?:(?:your|the)[\s_-]+)?(?:current[\s_-]+)?quota\b/i
  /\b(?:balance|credits?)[\s_-]+(?:exhausted|depleted)\b/i
  /\bout[\s_-]+of[\s_-]+(?:credits?|budget)\b/i
```

`errorChain(value)` renders `message [member; member]: cause` recursively, skipping a cause equal to its wrapper's message, with `<circular cause>` and `<unrenderable value>` guards.

### B. `BlockAssembler` (`packages/llm/llm/src/assembler.ts:49-190`)

State: partial blocks by `index` plus first-seen index order; last `usage`; last `finish` reason and replay envelope. Rules: a duplicate `block-start` is ignored; a delta for an unseen index creates the partial with the delta's block type (delta-only protocols work); deltas after `block-end` are ignored; the first `block-end` wins; a `tool-call-delta` sets the id (last wins), sets the name when non-empty, and appends arguments. Assembly of an open block: text/reasoning use accumulated text; tool-call uses `id ?? "call-<index>"`, `name ?? ''`, accumulated arguments; any other open type throws `cannot assemble incomplete block of type "X"`. `finish` defaults to `{kind: 'stop'}` when no finish chunk arrived.

One keep/drop decision (`:135`): when the finish kind is `max-tokens`, every `tool-call` block is dropped. The replay envelope follows: no `blocks` → passed through unchanged; `blocks.length` different from the total block count → `undefined`; otherwise the entries at dropped positions are removed. `interruptedBlocks()` returns text and reasoning blocks (open or closed) that contain a non-whitespace character and nothing else. `message(source)` builds a frozen assistant message with a fresh id.

### C. Compact stream (`packages/llm/llm/src/assistant-stream.ts`)

Accumulator `push({time, chunk})` (`:108-177`): `time` must be a safe integer and the chunk losslessly JSON-serializable (else `TypeError`); returns a frozen detached copy. A text or reasoning delta joins the previous record only when that record has the same type and `index` and `time - lastTime` is a safe integer (negative gaps are allowed); otherwise it starts a run. A tool-call delta with `id === ''` or `name === ''` is stored as a raw `chunk`; otherwise it joins the previous record only when `index`, `id`, and the presence and value of `name` all match. Everything else is a raw `chunk`. `snapshot()` returns detached frozen records.

`expandAssistantStream(records)` (`:202`) validates then expands to the exact `{time, chunk}` sequence. Validation (`:456-534`): exact key sets; non-empty `texts`/`args`; string members; `dt` of safe integers with length `members - 1`; every reconstructed time a safe integer; `index` a non-negative safe integer; tool `id` non-empty; `name` non-empty when present; raw chunk a JSON object. Any violation throws `TypeError`. Expansion is not memoized.

Single-chunk predicates: `isTokenDelta` (non-empty text or reasoning delta; tool-call delta with non-empty `argumentsDelta` or a defined `name`), `isVisibleChunk` (text or reasoning delta containing `/\S/`; `block-start` of a type other than text, reasoning, tool-call; `block-end` whose block is visible, where tool-call is never visible), `chunkHasVisibleText` (text delta or completed text block with `/\S/`). Record-level readers with early exit: `runFirstTokenTime`, `runFirstVisibleTime`, `assistantStreamFirstTokenTime`, `assistantStreamHasVisibleContent`, `assistantStreamHasVisibleText`, `lastAssistantStreamChunk(stream, type)`, `assistantStreamChunks(stream, type)`, `joinAssistantStreamText`, `assembleAssistantStream(stream, assembler?)` (pushes one joined delta per run; same blocks, usage, finish, and replay state as full expansion).

### D. DeepSeek adapter (`packages/llm/llm-deepseek/src`)

D1. Model metadata (`model-info.ts:63-102`). `context.contextWindow = entry.contextWindow ?? defaultContextWindow`; `defaultMaxTokens = entry.maxTokens ?? connection.maxTokens` (always present); an uncatalogued model is `{name: id, inputModalities: ['text']}`. Reasoning: with `thinking: 'disabled'` the only effort is `off` (default `off`); otherwise efforts are `off`, `low`, `high`, `max` in that order with `defaultEffort` = configured `reasoningEffort` or `high`. Names and descriptions: `Off` "Use for simple tasks that do not need reasoning.", `Low` "Prefer for routine or latency-sensitive tasks.", `High` "The default balance for most tasks.", `Max` "Reserve for the hardest quality-first tasks.". Consequence: every prepared call on a DeepSeek route has `maxTokens` and `reasoningEffort` materialized and flagged in `adapterDefaults` unless the caller set them.

D2. Request lifecycle (`adapter.ts:65-89`). One `AbortController` per call, fused with the caller signal; an idle watchdog (`idleWatchdog(signal, streamIdleTimeoutMs, 'MESSAGES_IDLE')`) arms a timer while a read is outstanding and is pulsed by every SSE event, SSE comment, and resolved file. Failure mapping in order: watchdog expired → `TIMEOUT` (`DeepSeek Messages stream idle timeout`); caller signal aborted → `ABORTED` (`DeepSeek Messages request aborted`); an `LlmError` → unchanged; anything else → `TRANSPORT` (`DeepSeek Messages transport failed`). On exit the controller is aborted and the inner iterator is closed without waiting.

D3. Request loop (`adapter.ts:91-181`).

1. `prepareImages` (`images.ts:38-61`): replace `offloaded` images with `offloadedImageText`; if images remain, require a catalog model with the `image` modality and an attachment service, and images only in user and tool messages (`UNSUPPORTED_CONTENT` otherwise); read one request version per distinct `attachmentId` with `attachments.readImageRequest(ref, resolveRequestImageTarget(model, ref), signal)`; fail with `IMAGE_OFFLOAD_REQUIRED` when the raw budget is exceeded.
2. `resolveAuth(connection)` (a missing credential fails here, before the anonymous user id is created).
3. Loop. Files mode first: resolve every image occurrence to a file id, each under its own `filesApiTimeoutMs` deadline. Any failure that is not caller cancellation switches the whole request to inline mode (never mixed), which re-checks the base64 budget.
4. `serialize` (D4), prepare extensions (D7), compute beta headers, `fetch`.
5. Non-2xx: read the body text, parse JSON if possible; if file ids were used and the error text names a missing, expired, deleted, or invalid file, invalidate those index entries and retry the loop once; otherwise throw the classified provider error (D6), with the message replaced by a normalized-image diagnostic when status is 400, file ids were used, and the detail says the image is unsupported, invalid, or cannot be decoded.
6. 2xx: `await extensions.accept()`, then a null body is `EMPTY_RESPONSE`, else stream `translate(parseSse(body))`.
7. Any error after auth resolved passes through `auth.onRequestError` when present (a throwing callback preserves the original error).

D4. `serialize` (`serialize.ts:57-169`).

- User and tool-result content: non-empty `text` → text block; `reasoning` and `tool-call` are skipped; `image` → a text block with `requestImageHandleText` followed by the image block (file reference when file ids are in use, else base64); any other type throws `UNSUPPORTED_CONTENT` (`DeepSeek Messages cannot represent user/tool-result content X`).
- Assistant content: non-empty `text` → text; `reasoning` → `thinking` with `signature` from validated replay state at the same position; `tool-call` → `tool_use` whose `input` is the parsed arguments when they parse to a JSON object, else `{}`; other types unsupported.
- Tool-change blocks outside a developer message throw `UNSUPPORTED_CONTENT`.
- System messages must be text only. For a model with `systemPromptUpdate: 'in-history'`, a system message that appears after at least one wire message is queued as a system update (empty text throws); every other system message replaces the top-level prompt (the latest wins). Top-level `system` is `[options.system, thatPrompt]` without empty parts joined by `\n\n`.
- Developer messages: `text` → text, `tool-addition` → `tool_addition`, `tool-removal` → `tool_removal`; queued as a `system`-role wire message when non-empty.
- Queued system updates are flushed immediately before the next non-empty assistant message and at the end. A flush requires the last wire message to be a `user` message (`system update without a preceding user or tool-result turn` otherwise).
- A tool message becomes a `user` wire message holding one `tool_result` (`is_error` present only when `isError` is defined; empty results keep their call id). Consecutive wire messages with the same role are merged. Empty user and assistant messages are skipped.
- Validation pass: an assistant message sets the pending set to its `tool_use` ids (duplicates → `INVALID_REQUEST` `DeepSeek Messages duplicate tool call id`); a user message must answer only pending ids (`tool result has no matching call`) and all of them (`tool calls need immediate results`), and its content is reordered with `tool_result` blocks first; history ending with pending calls is `history ends with unresolved tools`.
- Effort outside `off|low|high|max`, or any effort but `off` when thinking is disabled, throws `UNSUPPORTED_REASONING_EFFORT`.

D5. `translate` (`translate.ts:104-166`). State: blocks keyed by wire index (each gets the next dense local index), cumulative usage starting at zero, `started`, `reason`.

- `message_start` (once; a duplicate is malformed) must carry `message.usage`.
- Unknown event types are skipped, before the `started` check. Any known event before `message_start` is malformed.
- `content_block_start`: reject a repeated wire index or a start after the stop reason. Emit `block-start`; for text or thinking with non-empty initial text emit one delta with it; for `tool_use` emit `tool-call-delta {id, name, argumentsDelta: ''}`. Initial tool arguments are `JSON.stringify(input)`. An empty tool id or name is malformed; another block type is `UNSUPPORTED_CONTENT`.
- `content_block_delta`: requires an open block. `text_delta` and `thinking_delta` emit deltas; `signature_delta` appends to the block's replay signature and emits nothing; `input_json_delta` appends to the block's JSON buffer and emits `tool-call-delta {id, argumentsDelta}` without a name; any other pairing is malformed.
- `content_block_stop`: close; a tool call whose JSON buffer is non-empty takes the buffer as its `arguments`; emit `block-end` with a copy.
- `message_delta`: map `stop_reason` (`end_turn`, `stop_sequence` → `stop`; `tool_use` → `tool-calls`; `max_tokens` → `max-tokens`; anything else malformed); merge usage.
- `message_stop`: requires a stop reason and all blocks closed; zero blocks with `stop` is `EMPTY_RESPONSE`; unless the reason is `max-tokens`, every tool call's arguments must parse to a JSON object (else `MALFORMED_RESPONSE`); then emit `usage`, then `finish` with the replay envelope, and stop reading.
- Events ending without `message_stop` is `STREAM_CLOSED` (`DeepSeek Messages stream ended before message_stop`).

SSE framing (`sse.ts`): complete frames only (an unterminated tail is never delivered); invalid JSON, a non-object, a missing string `type`, or an `event:` name different from `type` is `MALFORMED_RESPONSE`; a frame of type `error` is thrown through the provider error classifier with no status.

D6. Provider error classification (`transport.ts:23-45`), first match wins: status 401 or 403, or type `authentication_error`/`permission_error` → `AUTH`; quota wording or status 402 → `QUOTA`; status 429 or type `rate_limit_error` → `RATE_LIMIT`; context-overflow wording → `CONTEXT_WINDOW_EXCEEDED`; status 400 or 413 or type `invalid_request_error` → `INVALID_REQUEST`; status ≥ 500 or type `api_error`/`overloaded_error` → `SERVER`; no status → `SERVER`; else `HTTP_<status>`. Message: `error.message` or `DeepSeek Messages request failed (<status or 'stream error'>)`. `providerRetryAfterMs`: `retry-after` matching `^\d+(?:\.\d+)?$` is seconds × 1000, otherwise `Date.parse(value) - now`; kept only when finite and positive. `requestId` from the three headers.

D7. Extensions (`request-extensions.ts`). `prepare({body, signal, sessionId?, purpose?})`; a rejection is `REQUEST_EXTENSION` (`DeepSeek request extension preparation failed: <errorChain>`); a field name already in the body is `REQUEST_EXTENSION` (`DeepSeek request extension field "x" collides with the base request`). Payload is `JSON.stringify({...body, ...fields})`; if that throws, the payload is the base body, the omitted field names are reported, and `accept` is a no-op. `accept` failures are reported and swallowed. Without the registry service the prepared value is `{fields: {}, accept: no-op}`.

D8. Replay validation (`replay.ts:48-64`). Used only when the message source is a model source with `replayState`. Any structural mismatch (not objects, kind or version, `response.model` different from the source model, block count different from content length, block type mismatch, a signature on a non-reasoning block or not a string) raises `INVALID_REPLAY_STATE` internally, which degrades that message to content without signatures and reports the reason once per `(provider/model, reason)`. Valid state for a different target model is dropped silently.

D9. Files store (`file-store.ts`, `request-files.ts`, `upload-index.ts`). `ensureUploaded(version, connection, policy, signal)` is single-flight per `(scope, variantId)`: waiters share one upload; a waiter's cancellation releases only that waiter, and the upload is aborted when the last waiter leaves before settlement. Steps: reject a version over 32 MiB; return a cached record whose `expiresAt - now > refreshMarginMs`; upload; on a quota error (detail matching `/(?:quota|storage|stored files|file count|too many files)/i`) delete up to `quotaCleanupBatch` of the oldest files whose name starts with `dsh-` (list pages of 1000, keep the oldest candidates across pages) and upload once more (rethrow when nothing was deleted); the response `size_bytes` must equal the sent length; commit to the index under a file lock, and if another process already published a reusable record for the same key, keep that record and delete the duplicate upload (delete failure ignored). The commit also prunes every non-reusable record. Stale-id recovery: invalidate the exact `(variantId, fileId)` pairs the error names, or all used pairs when none is named; only the first stale response per request allows a retry.

D10. Image request target and price (`request-pricing.ts`, `image-tokens.ts`). Target: `imagePixelBudget` `'low'` → total-pixel budget 262144; a number → that budget; absent → the token-grid projection; then if the longer side exceeds 4096, rescale the source to a 4096 long edge; `maxBytes = imageMaxBytes ?? 2097152`. Small images are never enlarged. Token grid constants: patch 14 px, 3:1 downsample (cell 42 px), cap 1024 tokens, pixel floor 544×544, `gridTokens(h, w) = h * (w + 1) + 2`, `gridCells(px) = ceil(floor(px / 14) / 3)`; `deepSeekImageTokens` iterates scale-pad-project to a fixpoint (at most 10 passes). Pricing per occurrence: text-only or uncatalogued model → `{0, textOnlyImageText}`; offloaded → `{0, offloadedImageText}`; retained → `{deepSeekImageTokens(target), requestImageHandleText(ref, target, access)}`.

D11. Listing cache (`listing-cache.ts`). Scope key = listing URL + `\n` + sha256 of the credential; no credential means unauthenticated and no listing. First access of a scope waits for the load (the caller's signal abandons only its wait); later accesses return immediately and start a background refresh when the listing is older than `modelsMaxAgeMs`. Loads are single-flight with a `modelsTimeoutMs` deadline. Success stores the listing, logs `model listing from <url> loaded N model(s), skipped M row(s)` to stderr, and notifies only when the listing changed (deep equality). Failure keeps the previous listing and warns once per failing streak (`...; using the bundled catalog` or `...; keeping the previous catalog`). After each settlement a timer (not keeping the process alive) schedules the next refresh at `max(1, maxAge - age)` unless `maxAge` is 0. A generation counter discards results from an aborted or rescoped load. Disposal aborts and awaits in-flight work.

D12. Listed catalog (`listed-catalog.ts:103-164`). Without a listing: offer the build's models (with overrides). With one, per entry in listing order: a declared `min_version` (valid semver) admits the model when the client version is greater or equal, else records refusal `upgrade-required`; no requirement admits only ids this build knows (others get refusal `unsupported` and stay hidden); an unreadable requirement is a problem and `unsupported`. An admitted entry must declare `api_capabilities.anthropic_messages`, text output, at least one known input modality, and valid capacities, else problem and `unsupported`. Offered entry = the build's entry (or `{id}`) layered with listed `name`, `contextWindow`, `maxTokens = min(routeMaxTokens, max_output_tokens)`, modalities, and update modes (a listed `leading-only` removes the inherited mode), then the override. Resolution list = offered + build models not offered. `admit` throws `CLIENT_UPGRADE_REQUIRED` (`DeepSeek model "m" requires DeepSeek Harness V or later; current version is C`) or `MODEL_UNSUPPORTED` before any network I/O. Badge text: trimmed, at most 12 grapheme clusters, at least one visible character, no control, line-separator, or bidi-control characters; a translations object needs language keys matching `^[a-z]{2,8}(?:-[a-z0-9]{1,8})*$` including `en`; an unknown tone becomes `neutral`.

D13. Provider plugins. `registerDeepSeekProvider` (`host.ts:44-91`) builds the adapter, registers `[provider]`, and on `loader/volatile-update` calls `registration.replace([provider])` when the resolved retry policy changed. Replay-degradation, omitted-extension, and unaccepted-extension warnings are logged once per key. API-key route: with an installed `credentials` service that service is authoritative (absence there is absence); only without it is the launch environment read; a missing key throws `MISSING_CREDENTIAL` (`llm-deepseek: no API key for provider route "deepseek-official"; store REF through the credentials service (the web Models page writes it), or export REF in the launching environment`). `listModels` returns `[]` when no key is configured or the route is unauthenticated. Account route: no token → `ACCOUNT_SIGN_IN_REQUIRED`; request errors map `QUOTA` → `ACCOUNT_QUOTA` and HTTP 401 → `ACCOUNT_TOKEN_INVALID` plus `deepseekAccount.rejectToken(token)`; `modelOverrides` problems are published as the directory entry's `error`.

### E. Retry executor (`packages/llm/llm-retry/src/index.ts:120-257`)

Listener on `agent/request-error`:

1. No `retryPolicy` (no adapter served the request) → `next()`.
2. Wait for projection registration. If the turn signal is aborted or the plugin is disposed → return `undefined` without calling `next`.
3. Always mode: run `next()` first, catching its failure (logged as a warning); if cancellation happened meanwhile return `undefined`; if downstream decided `{kind: 'retry'}` return that; otherwise continue. Normal mode: a code outside `retryableCodes` → `next()`.
4. Read state for `(provider, policyKey)`; `previous = entry.retry ?? 0`. Normal mode with `previous >= maxRetries` → `next()`. `retry = previous + 1`; `retryId = entry.retryId ?? randomUUID()`.
5. Delay. A valid `failure.providerRetryAfterMs` not above `maxDelayMs` is used verbatim (no jitter). Above `maxDelayMs`: normal mode → `next()` (no retry); always mode → local delay. Local delay: `min(min(initialDelayMs * 2^min(retry - 1, 1024), maxDelayMs) * (1 - j + 2 * j * random()), maxDelayMs)` with `random()` in [0, 1].
6. Append `llm/retry`; wait on a timer cancellable by the turn signal or plugin disposal; when cancelled return `undefined`; otherwise append `llm/retry-started` and return `{kind: 'retry'}`.

State fold (`llmRetry` projection): `step/start` and `turn/end` reset the state to `{}`; `llm/retry` stores `{retry, retryId}` under the key. So the budget is per step and per `(provider, exact policy)`; a different provider or policy on the next attempt starts at 1. The loop re-runs the same step inside the same open turn; failed chunks never enter derived messages. Disposal removes the listener, aborts waits, and awaits every active recovery; a callback captured before disposal returns `undefined`.

### F. Token meter (`packages/llm/token-meter/src`)

F1. Estimator (`estimate.ts`). All lengths are JavaScript string lengths (UTF-16 code units). `text`/`reasoning`: `ceil(len / 4) + 4`. `tool-call`: `ceil(name.length / 4) + ceil(arguments.length / 4) + 4`. Any other block: `4 + ceil(JSON.stringify(block).length / 4)` (an image is stringified without its `offloaded` key). Non-system message: sum of blocks + 4. System message: 0 for empty content, else `ceil(chars / 4) + 4` where a text block counts its text and any other block its JSON. Tools: 0 when the header has none, else `ceil(JSON.stringify(header.tools).length / 4) + 4`.

F2. `measure` (`index.ts:151-196`). Per session it keeps a rebuildable list of surface nodes `{seq, heuristicTokens, imageStructuralTokens, fileStructuralTokens, images, files}`, folded from surface events (`append` adds; `replace {startSeq, endSeq}` swaps the inclusive range for one node; a missing range throws), the latest canonical request header, and a snapshot of nodes and header taken at each `assistant/message` before that message's node is added (the anchor). An `image/offload` event marks `targets[].imageIndexes` of the node at `targets[].seq` as offloaded. Pricing (`route-pricing.ts`): a node's price is its heuristic price, minus the structural price of its files plus the estimate of each file's handle text when an llm service is mounted, minus the structural price of its images plus `visualTokens + estimate(text)` per image when the routed adapter declares image pricing (one `priceImages` call for the whole surface; a length mismatch throws). Result: if an anchor exists and its header equals the effective header, `anchorTokens = tools + price(anchorNodes) + anchor.assistantTokens`, baseline = provider usage (`input + cacheRead + cacheWrite + output`) when it is at least `anchorTokens`, else the estimate, and `surfaceDelta = currentSurface - (price(anchorNodes) + assistantTokens)`; otherwise baseline is `none` (no header and empty surface) or `estimated = tools + surface` with delta 0. `totalTokens = max(0, baseline + delta)`.

F3. Projections. `tokenUsage`: each `assistant/message` or `assistant/attempt` with a usage sample (the event's `usage`, else the last `usage` chunk of its stream) contributes its four buckets; a second sample for the same `(turn, step)` replaces the first; `llm/retry-started` for that `(turn, step)` closes the slot so the retried attempt adds. `contextPressure`: `pressureTokens = input + cacheRead + cacheWrite` of the newest sample, stamped together with the surface total at that moment; `contextWindow` from the newest `request/context`; a running surface total that grows by appended message estimates and shrinks at a replacement by the shadow price announced by the immediately preceding `compaction/summary` or `compaction/prune` event (`shadowedRange`, `shadowedTokenCount`); view `projectedTokens = max(0, pressure + surface - sampledSurface)`. A replacement with an armed claim for a different range throws; one without a claim folds with zero delta. `contextBreakdown`: `systemTokens` = last surviving non-empty system prompt, `toolsTokens` from the newest header, `messageTokens` = surface minus system.

F4. `deriveTurnTokenUsage(events)` (`turn-usage.ts:178`). A strict state machine over one turn (`turn/start` … `turn/end`): `step/start` opens an attempt; `assistant/attempt` closes it with its stream's usage; `assistant/message` closes it with `usage ?? stream usage` and the message's route; `llm/retry` settles an attempt for retry (closing an open one), `llm/retry-started` reopens it; `step/end` returns to idle. Any missing boundary, missing or unsafe usage, `reasoningTokens > outputTokens`, or contradictory `totalTokens` makes the result `undefined`. Per attempt the exact total is `totalTokens` when present (it must be at least the known prompt plus output, and equal when both cache buckets are present), else derivable only when both cache buckets are present. The aggregate sums attempts; optional buckets and `routes` appear only when every attempt reported them.

### G. Plugin package inventory (`plugin-package-inventory-deepseek/src/index.ts`)

Per request: collect Loader entries that are not groups, not disabled, and whose fiber is active; add the modules of the requesting session agent's preset compositions when `agentPresets` and the session's agent exist. Resolve each to a package manifest: a bare specifier names a package (`@scope/name` or `name`) located through `pluginPackages.packageOf` or Node resolution paths from the entry's base URLs; a relative or absolute module uses the nearest `package.json` upward; a `cordis:` module has none. A manifest needs a non-blank string `name`; `version` is included only when a non-blank string. An unresolvable bare package is logged once and omitted. Identities are cached for the process lifetime.

### H. pi-ai adapter (`packages/llm/llm-pi-ai/src`)

H1. Snapshots (`adapter.ts:302-311`). Profiles are resolved once per raw config identity; the adapter builds a new immutable provider collection per profiles identity and every operation captures one snapshot before its first await, so a configuration change never affects an in-flight call.

H2. Model metadata (`adapter.ts:376-393`). `context.contextWindow` from the model; `defaultMaxTokens` only when the profile explicitly set `maxTokens` for that model (a catalog capability is never a request default); `reasoning` only when the model reasons: efforts are the supported levels in the order `off, minimal, low, medium, high, xhigh, max` (`xhigh`/`max` only when the model maps them; a level mapped to `null` is excluded), names capitalized, `defaultEffort` = profile `reasoning` when supported. Update modes (`models.ts:75-92`): none unless the model's compat has `supportsMidConvoSystemMessages`; then `systemPromptUpdate: 'in-history'`, and `toolUpdate` is `in-history` for `anthropic-messages` with `supportsMidConvoToolChanges`, `addition-only` for `openai-completions` with `supportsMidConvoToolAdditions`, and `addition-only` for the OpenAI Responses family with `supportsAdditionalTools` or `supportsToolSearch`. `listModels` returns `[]` while the route's named credential is missing.

H3. Request (`adapter.ts:407-514`). `stop` → `UNSUPPORTED_OPTION`. Unknown route → `NO_ADAPTER`; unknown model → `UNKNOWN_MODEL`; a stored model diagnostic → `INVALID_CONFIG`. An explicit or profile effort the model does not support → `UNSUPPORTED_REASONING_EFFORT` (no clamping). Credential: a profile naming `apiKeyEnv` resolves it (credentials service, else launch environment) and fails with `MISSING_CREDENTIAL` on a miss; a profile naming none defers to provider-native discovery. Images require the model's `image` input and the attachment service (`UNSUPPORTED_CONTENT`); request versions use `requestImageDimensions(w, h, requestImagePixelBudget)` and `requestImageMaxBytes`; the base64 budget check uses `maxRequestImageBytes`, `maxRequestImages`, `imageOffloadCountQuantum` and fails with `IMAGE_OFFLOAD_REQUIRED`. Library options: `apiKey?`, `reasoning?` (omitted for `off`), `thinkingBudgets?`, `cacheRetention?`, `transport?`, `timeoutMs?`, `websocketConnectTimeoutMs?`, `maxRetries: 0`, `temperature?`, `maxTokens?`, `sessionId?`, `signal`, `headers`. Headers: profile headers, then the `llm-pi-ai/request-headers` waterfall, then attribution overwrites. Idle watchdog code `LLM_STREAM_IDLE_TIMEOUT`; expiry → `TIMEOUT` (`pi-ai stream idle timeout after Nms`), caller abort → `ABORTED`.

H4. Context conversion (`context.ts`). System prompt = `options.system` and the text of every leading system message, non-empty parts joined by `\n\n`. Declared tools = non-deferred tools as `{name, description, parameters}`. Developer message → one system message with text parts, `toolsAdded` (looked up in `options.tools`; undeclared → `INVALID_REQUEST`), `toolsRemoved: [{name}]`. Later system message → native system message, or the `<system-reminder>` user message. Assistant → native assistant message rebuilt from durable content plus validated replay state, or a "foreign" message (`api: 'dsh-foreign'`, stop reason `toolUse` when it has tool calls, else `stop`) when replay state is absent or unusable; unparseable tool arguments become `{}`. Tool → `toolResult {toolCallId, toolName (from the preceding assistant call, else 'unknown'), content, isError: isError ?? false, timestamp: 0}`. User → joined text, or text and image parts where each image is preceded by its handle text.

H5. Stream translation (`stream.ts`). Library events map one to one: `text_start/delta/end`, `thinking_start/delta/end`, `toolcall_start/delta/end` → `block-start`, deltas, `block-end` with `index = contentIndex`; tool arguments are re-stringified at `block-end`. `done` → `usage` then `finish` with replay state; a tool call with an arguments error raises `MALFORMED_RESPONSE` unless the stop reason is `length`. `error` → `usage` then an error or aborted finish. Usage: `inputTokens = input`, `outputTokens = output`, `totalTokens`, cache buckets only when greater than zero. Stop reasons: `stop` → `stop` (or `EMPTY_RESPONSE` with no content), `length` → `max-tokens`, `toolUse` → `tool-calls`, `aborted` → aborted finish with code `ABORTED`, `pending`/`deferred` → `PI_AI_ERROR`, context overflow (library detection or the shared classifier) → `CONTEXT_WINDOW_EXCEEDED`. Error text classification, first match wins, where status rules read only a leading `4xx`/`5xx` token when the message starts with one: 401/403 → `AUTH`; quota wording → `QUOTA`; 429 or `rate.?limit` → `RATE_LIMIT`; 413 or body-too-large wording → `INVALID_REQUEST`; 400 or `invalid.?request` → `INVALID_REQUEST`; 5xx → `SERVER`; timeout wording → `TIMEOUT`; `stream ended before|without`, network/connection/socket/fetch/`ECONN*`/`terminated`/`premature close` wording → `TRANSPORT`; else `PI_AI_ERROR`. A stream ending with no terminal event → `STREAM_CLOSED`.

H6. Prefix binding (`prefix-binding.ts`), Anthropic Messages only. Digest chain: `d0 = sha256hex(seed + "\0" + JSON.stringify({systemPrompt, tools}))` with seed `dsh-llm-pi-ai/prefix-binding/v1`, then `d(i+1) = sha256hex(d(i) + "\0" + JSON.stringify(message_i))`. A replayed assistant message keeps its signed or redacted thinking blocks only when the digest recorded in its replay state equals the chain value at its position; otherwise those blocks are removed (except, with manual thinking, the assistant message whose tool round the request continues). The final digest is stored in the new response's replay state.

H7. Catalog depth. Route materialization merges the installed catalog under configured entries field by field (`catalog.ts:858`); strict validation applies to writes, deferred validation keeps diagnostics for stored config. Providers: a catalog route with no `api` override reuses the library's provider; any other route is built over one of four protocols. Discovery (`discovery.ts`): catalog routes answer from the catalog; otherwise `GET {baseURL}/models` with `authorization: Bearer` (OpenAI protocols), `GET {root}/v1/models?limit=1000` with `x-api-key` and `anthropic-version: 2023-06-01`, or `GET {baseURL}/models?pageSize=1000` with `x-goog-api-key`; replies over 4 MiB are refused; failures are `DISCOVERY_FAILED` or `DISCOVERY_UNSUPPORTED`. Credential bridge (`auth.ts`): library credential records live in `ctx.credentials` under scope `llm-pi-ai`; ambient environment lookups go to the credential service first, then the launch environment. Login flows (`login.ts`): one `ctx.authorization` flow per catalog provider with methods `oauth` and/or `api-key` (OAuth for `openai` is not offered).

### I. Replay binding (`packages/test-support/llm-replay/src/index.ts:1018-1109`)

Scripts are ordered primary first, then children by `createdAt` and recorded id. Each call computes `key = options.sessionId ?? anonymous`. A key seen for the first time claims the next unclaimed script; the cursor for that key advances synchronously at call time, before the stream is consumed. Errors are deferred into the returned stream: an unrecorded extra session (`llm-replay: a model call arrived from an unrecorded session (#N); the scenario recorded only M session(s) — re-record it`) and an exhausted script (`llm-replay: script exhausted — session requested model call #k but its script has only n; re-record the scenario`). Before the first chunk, when `options.provider === 'deepseek-official'`, the extension registry is mounted, and the entry counts as accepted (`chunks` and `hang` always; `throw` when `accepted ?? chunks.length > 0`), replay calls `prepare({body: {messages: []}, signal, sessionId?, purpose?})` and `accept()` to reproduce post-2xx side effects. Entry playback: `chunks` yields each chunk (throwing `Error('aborted')` when the signal is aborted, waiting `paceMs` when set); `throw` yields its prefix then throws `LlmError.fromFailure({message, code})`; `hang` yields `block-start {index: 0, blockType: 'text'}` and `text-delta {index: 0, text: 'partial'}`, writes an empty `readyFile` when named, then waits for abort and throws `Error('aborted')`.

Two mounting modes with different failure behavior. With `providers`, replay registers a `ReplayAdapter` for those routes, so a thrown entry passes through the adapter boundary and reaches the loop as a terminal error finish with the scripted code (retry policies apply). Without `providers`, replay is an `llm/stream` listener that never calls `next`, so a thrown entry stays a thrown exception. `assertConsumed()` throws when a script was never bound or a bound cursor did not reach the end.

### J. Mock server randomness (`llm-mock-server/src/index.ts:608-632`)

Mulberry32 over a uint32 seed: `state = (state + 0x6D2B79F5) mod 2^32`; `m = state`; `m = imul(m xor (m >>> 15), m or 1)`; `m = m xor (m + imul(m xor (m >>> 7), m or 61))`; result `((m xor (m >>> 14)) mod 2^32) / 2^32`. Selection: `draw = random() * totalWeight`, then walk the positive weights in the configured key order subtracting each until `draw < weight`.

### Invariants to keep

- Model-visible implies logged: every input an adapter sends is derivable from the session log; projections applied at the adapter boundary (file handles, text-only placeholders, tool updates, offload placeholders) are pure functions of logged state plus the current execution-world path mapping.
- A loop-built request is deep-frozen; nothing in this area mutates it (copies are made, and stay frozen when the input was frozen).
- A stream delivered through the adapter boundary ends with exactly one `finish`; `usage` precedes it.
- Replay state never crosses adapter instances.
- The retry policy used for a failure is the one captured when the call was prepared.
- A scheduled retry is in the log before its wait begins.
- Registry notifications fire after the commit and cannot veto it.

## Tests worth porting

All paths are under `packages/`. Specs are Vitest files; the JSON and JSONL fixtures can be reused unchanged.

| Path | Behavior pinned |
|---|---|
| `llm/llm/tests/assembler.spec.ts`, `properties.spec.ts` (fast-check) | Block assembly, straggler handling, first-close-wins, id fallback, max-tokens pruning with replay alignment, interrupted prefix, idempotent `blocks()` |
| `llm/llm/tests/assistant-stream.spec.ts` | Run packing rules, exact expansion, validation errors, token/visibility readers, `assembleAssistantStream` equivalence |
| `llm/llm/tests/content.spec.ts` | Exact handle and placeholder texts, file and image projection, tool-update projection in every mode, offload counts at exact and quantized budgets |
| `llm/llm/tests/service.spec.ts` | Registration, `prepareCall` one-shot and config equality, default materialization, effort validation, failure normalization to finish chunks, replay-state filtering by adapter instance, waterfall short-circuit |
| `llm/llm/tests/topology.spec.ts` | `llm/adapters-updated` commit points and listener containment, atomic `replace`, directory and discovery registration |
| `llm/llm/tests/retry-policy.spec.ts`, `call-config.spec.ts`, `adapter-failure.spec.ts`, `api-key.spec.ts`, `attribution.spec.ts`, `message.spec.ts` | Policy defaults and bounds, config equality and freezing, hostile-throw normalization, key validation, `User-Agent` form, message constructors |
| `llm/llm-deepseek/tests/serialize.spec.ts` | Every serializer rule in D4, including system-update placement, tool-result grouping, replay degradation |
| `llm/llm-deepseek/tests/stream.spec.ts` | SSE framing at every byte split, event state machine, usage, malformed inputs, in-band errors, `Retry-After` |
| `llm/llm-deepseek/tests/adapter.spec.ts`, `runtime.spec.ts`, `tests/mock-server.ts`, `tests/fixtures/cordis.yml`, `tests/expected/degraded-replay.json` | Whole-route behavior against a local scripted Messages and Files server: headers, betas, error codes, idle timeout, abort, Files fallback to inline |
| `llm/llm-deepseek/tests/extensions.spec.ts`, `deepseek-llm-api-extensions/tests/registry.spec.ts` | Prepare/accept transaction, collisions, omission on failure, once-only logging |
| `llm/llm-deepseek/tests/files-api.spec.ts`, `file-store.spec.ts`, `files.spec.ts`, `upload-index.spec.ts` | Files wire, single-flight, quota recovery, index commit race, stale-id retry |
| `llm/llm-deepseek/tests/image-tokens.spec.ts`, `request-pricing.spec.ts` | Token-grid numbers and request targets (golden values) |
| `llm/llm-deepseek/tests/listing.spec.ts`, `listing-cache.spec.ts`, `listed-catalog.spec.ts`; `llm-deepseek-api-key/tests/*.spec.ts`; `llm-deepseek-account/tests/*.spec.ts` | Listing decoding, cache timing, version gating, overrides, credential-gated discovery, account quota and token invalidation |
| `llm/llm-deepseek/tests/loader-composition.spec.ts`, `dynamic-config.spec.ts`, `egress.spec.ts`, `credential.spec.ts` | Real Loader composition, live config changes, redirect refusal, credential precedence |
| `llm/llm-retry/tests/retry.spec.ts`, `transport-recovery.spec.ts` (drives `llm-mock-server`), `persistence.spec.ts`, `initialization.spec.ts`, `loader-composition.spec.ts` | Backoff math with injected `random`, `Retry-After` handling, budget per step and provider, always mode, cancellation and disposal draining, durable events |
| `llm/token-meter/tests/*.spec.ts` | Estimator numbers, anchor selection, route pricing, projections including shadow-price claims, `deriveTurnTokenUsage` fail-closed cases |
| `llm/plugin-package-inventory-deepseek/tests/inventory.spec.ts` | Inventory membership, ordering, deduplication |
| `llm/llm-pi-ai/tests/convert.spec.ts`, `context.spec.ts`, `protocol-roundtrip.spec.ts`, `prefix-binding.spec.ts`, `conversation-updates.spec.ts`, `request-headers.spec.ts`, `catalog.spec.ts`, `config.spec.ts`, `discovery.spec.ts` with `tests/fixtures/model-listings/*.json` | Context conversion, stream and error mapping, replay envelopes, digest binding, profile resolution, discovery parsing of real provider listings |
| `test-support/llm-mock-server/tests/server.spec.ts`, `cli.spec.ts` | Every behavior's wire output, script exhaustion, seeded randomness, CLI validation |
| `test-support/llm-replay/tests/llm-replay.spec.ts`, `session-format-corpus.spec.ts` | Script derivation, override validation, placeholders, session binding, consumption check |
| `snapshots/**/session.vN.jsonl`, `snapshots/**/replay.override.json` (46 sidecars), `snapshots/AGENTS.md` | The scripted sessions a Racket mock provider must replay |

Real-API specs (`*.e2e.ts` in `llm-deepseek` and `llm-pi-ai`) skip without `DEEPSEEK_API_KEY`; mirror them as an optional live smoke test.

## Porting notes

Essential product behavior: the vocabulary in Formats 1 to 4 (it is the session log's durable content), the `ctx.llm` registry and adapter boundary, the DeepSeek Messages wire format and error mapping, the retry executor with its durable events, the token estimator numbers (compaction thresholds depend on them), the extension transaction, and replay of recorded sessions. Node-specific machinery that should not be copied: `Volatile` references (use a parameter or a box read once per operation), `AbortSignal.any` and the watchdog class (use events, `sync/timeout`, and custodians), `WeakSet` request marking (use a weak hasheq), `structuredClone` plus deep freeze (Racket immutable data is the default; use immutable hashes and vectors), `using` disposal, declaration merging (open unions become registries or plain symbols), and the typert `@Remote` decorators (a separate RPC layer decides exposure).

Suggested Racket decomposition:

- `dsh-llm/vocab`: structs or tagged immutable hashes for messages, blocks, chunks, finish reasons, usage, failures, with contracts and JSON codecs that keep key order and omit absent optional fields. `LlmError` becomes an `exn:fail` subtype carrying `code` and the failure hash.
- `dsh-llm/assembler`, `dsh-llm/assistant-stream`, `dsh-llm/content` (texts and projections), `dsh-llm/retry-policy`, `dsh-llm/errors` (code table and classifiers), `dsh-llm/attribution`.
- `dsh-llm/runtime`: the service. An adapter is a struct of procedures (or a generic interface) with the defaults above. A stream is best modeled as a Racket generator or channel-backed sequence with an explicit close; the boundary rule "adapter failures become a finish chunk, consumer failures propagate" needs the same two-`try` structure as `adapterStream`.
- `dsh-llm-deepseek`: `serialize`, `sse` (a small incremental parser: UTF-8 decode across chunk splits, `event:`/`data:` fields, comment lines as activity, no flush of an unterminated tail), `translate`, `transport` (error classifier), `files`, `listing`, `image-tokens`, plus the two provider plugins. Pure HTTP; `net/http-client` or `net/url` with manual streaming is enough. Redirects must be refused.
- `dsh-llm-retry`, `dsh-token-meter`, `dsh-deepseek-llm-api-extensions`, `dsh-plugin-package-inventory-deepseek` as direct ports.
- `dsh-llm-mock-server` (a `tcp-listen` loop is enough; it must be able to reset a socket and to stall) and `dsh-llm-replay`.

Hard parts and risks:

- String length parity. The estimator, `boundContextSummary`, and the tool-arguments midpoint in the mock server use UTF-16 code-unit lengths; the mock server's chunking and `output_tokens` use code points. Racket strings are code-point sequences, so the estimator needs an explicit UTF-16 length function or token numbers will differ on non-BMP text.
- `JSON.stringify` parity. Several durable or compared strings are JSON renderings: `policyKey`, the retry projection key, the file-scope digest input, estimator inputs (`JSON.stringify(block)` and `JSON.stringify(header.tools)` lengths), and the pi-ai prefix digests. Key order, number formatting (`0.1`, `10000`), and escaping must match JavaScript for the first four; prefix digests only need to be self-consistent (a TypeScript-recorded digest will read as stale and drop signed thinking, which is the designed fallback).
- Safe-integer bounds (`Number.isSafeInteger`) appear in validation of times, indexes, and usage counters; Racket integers are unbounded, so the checks must be explicit.
- Regular expressions use JavaScript semantics (`\b`, `\s`, case-insensitive) and Unicode property classes (`\p{Cc}`, `\p{Zl}`, `\p{Zp}`, `\p{Bidi_Control}`, `\p{White_Space}`, `\p{Default_Ignorable_Code_Point}` in badge validation); the last three need explicit code-point sets in Racket. Badge length counts grapheme clusters. Listing gates need a semver comparison.
- Cancellation and timing: the idle watchdog must be armed only while a read is outstanding and must not wait for the transport to notice the abort; retry waits must be cancellable from two sources and drained on disposal; the Files single-flight has waiter-local cancellation.
- Image request versions come from the attachment service (resize and re-encode), which is outside this area; the adapter only chooses targets and budgets.
- Recorded fixtures predate the Messages switch for some scenarios (usage with `reasoningTokens`, OpenAI-style call ids); replay must treat usage and ids as opaque data. Older fixture generations also carry earlier message-source spellings (for example a system message with `{"kind":"plugin","plugin":"@deepseek-ai/dsh-system-prompt"}`); the session format migrations, not this area, rewrite them before replay reads events.
- `docs/subsystems/llm-streaming.md` mentions `llmRetryPolicyOf(stream)`; that function does not exist at the pinned commit (the policy travels on `PreparedLlmCall.retryPolicy`). Follow the source.

What can only be wrapped at first: `llm-pi-ai`. It delegates wire protocols, model catalogs for about forty providers, OAuth logins, SigV4 and cloud credential discovery, and WebSocket transports to a Node library. A practical path is a Node sidecar that exposes `listModels`, `resolveModel`, `stream`, login, and discovery over a pipe, with the Racket side owning profile resolution, the registry, image budgets, and the stream vocabulary. Native Racket implementations of the four hand-declarable protocols (`openai-completions`, `openai-responses`, `anthropic-messages`, `google-generative-ai`) can replace the sidecar route by route; the Anthropic one shares most code with the DeepSeek adapter. The pi-ai config schema must still parse unchanged for configuration compatibility even where a route is not yet servable (report it through the directory entry's `error`, as deferred validation does).

## Feature checklist

- llm: message roles `system`, `developer`, `user`, `assistant`, `tool` with required ids and sources
- llm: content blocks `text`, `reasoning`, `image`, `file`, `tool-call`, `tool-addition`, `tool-removal`
- llm: message constructors create frozen messages with fresh UUID ids; `createSystemMessage('')` yields empty content
- llm: context forms on sources with `sections` and `summary`; `boundContextSummary` at 120 units
- llm: request-only user input without id or source
- llm: stream chunk union with seven chunk types and closed-union handling
- llm: finish reasons `stop`, `tool-calls`, `max-tokens`, `aborted`, `error`
- llm: `TokenUsage` with disjoint buckets and optional exact total
- llm: `LlmFailure` validation and `LlmError` with `fromFailure`
- llm: full failure-code table plus `HTTP_<status>`
- llm: `BlockAssembler` delta assembly, stragglers ignored, first block-end wins
- llm: `BlockAssembler` drops tool calls on `max-tokens` and prunes replay entries in step
- llm: `BlockAssembler.interruptedBlocks` keeps only non-blank text and reasoning
- llm: `AssistantStreamAccumulator` packs delta runs with `time0`/`dt`
- llm: `expandAssistantStream` strict validation and exact expansion
- llm: record-level readers (first token time, visible content, visible text, last chunk, join text, assemble)
- llm: adapter registration all-or-nothing with `DUPLICATE_ADAPTER` and `INVALID_ADAPTER`
- llm: atomic `replace` on adapter registrations and `REGISTRATION_DISPOSED`
- llm: retry policy captured per route at registration
- llm: configurable-provider directory with atomic replace and detached entries
- llm: model discovery registration per settings namespace and deduplicated `discoverModels`
- llm: remote discovery maps failures to `llm/model-discovery-rejected`
- llm: `llm/adapters-updated` emitted at commit points with contained listener failures
- llm: `llm/models-updated` event
- llm: `listModels` validation (`INVALID_CATALOG`) and badge passthrough
- llm: `resolveModelInfo` normalization and its four error codes
- llm: `resolveCallConfig` materializes `maxTokens` and default effort; rejects unsupported effort
- llm: `prepareCall` with `configure` callback, `adapterDefaults`, one-shot dispatch, `INVALID_PREPARED_CALL`
- llm: `llm/stream` waterfall with terminal adapter lookup (`NO_ADAPTER`)
- llm: adapter failures normalized to terminal `error`/`aborted` finish; consumer failures stay thrown
- llm: file blocks projected to handle text on every route
- llm: images projected to placeholders for declared text-only models
- llm: tool-update projection for no mode, `addition-only` (with rebase), and `in-history`
- llm: replay state stripped unless the same adapter instance owns both routes
- llm: `requiredImageOffload` count with byte and count quanta
- llm: exact image handle, offload placeholder, text-only placeholder, and file handle texts
- llm: `imageRequestPricing`, `imageRequestTarget`, `fileRequestText` service methods
- llm: context-overflow and quota text classifiers; `errorChain`
- llm: `normalizeApiKey` / `assertUsableApiKey` with `INVALID_CREDENTIAL`
- llm: `User-Agent` attribution with `DSH_USER_AGENT_SUFFIX` validation
- llm: retry policy schema, defaults, bounds, unknown-key rejection, always mode ignoring normal-only fields
- llm: `callConfigEquals`, `markAgentLoopRequest`, `isAgentLoopRequest`
- llm-deepseek: endpoint resolution `{root}/v1/messages` with `/v1` reuse and redirect refusal
- llm-deepseek: request headers including `anthropic-version`, betas, user id, session id, compact marker
- llm-deepseek: request body fields `model`, `stream`, `messages`, `max_tokens`, `thinking`, `output_config`, `system`, `temperature`, `stop_sequences`, `tools` with `defer_loading`
- llm-deepseek: effort mapping `off|low|high|max` and `thinking: disabled` policy
- llm-deepseek: serializer role merging, tool-result grouping and pairing validation
- llm-deepseek: system prompt as top-level `system` or in-history system updates by model capability
- llm-deepseek: developer tool changes as `tool_addition` / `tool_removal` system blocks
- llm-deepseek: thinking signatures replayed from validated replay state; degradation diagnostic once per route and reason
- llm-deepseek: malformed historical tool arguments sent as `{}`
- llm-deepseek: SSE parsing with heartbeat activity and no flush of an unterminated frame
- llm-deepseek: event translation to chunks with dense block indexes and raw tool JSON
- llm-deepseek: usage mapping with cache read and creation counters and computed `totalTokens`
- llm-deepseek: `EMPTY_RESPONSE`, `STREAM_CLOSED`, `MALFORMED_RESPONSE`, `UNSUPPORTED_CONTENT` conditions
- llm-deepseek: HTTP and in-band error classification, `Retry-After`, request id
- llm-deepseek: idle watchdog `TIMEOUT`, caller abort `ABORTED`, other failures `TRANSPORT`
- llm-deepseek: replay envelope `deepseek-messages` version 1
- llm-deepseek: request extension merge, collision failure, serialization fallback, accept after 2xx
- llm-deepseek: image preparation, raw budget, `IMAGE_OFFLOAD_REQUIRED`
- llm-deepseek: Files upload with expiry, reuse index `files-v3.json`, single-flight, quota cleanup, duplicate cleanup
- llm-deepseek: stale file id invalidation and single retry; inline base64 fallback with its own budget
- llm-deepseek: normalized-image rejection diagnostic
- llm-deepseek: request image target (token grid, pixel budget, `low`, 4096 cap, byte target)
- llm-deepseek: vision token calculator and per-occurrence pricing
- llm-deepseek: catalog validation and built-in catalog (`deepseek-flash`, `deepseek-v4-pro`)
- llm-deepseek: exact-model metadata with reasoning efforts, default effort, `defaultMaxTokens`, update modes
- llm-deepseek: `/models` listing request and per-entry decoding with badges and client requirements
- llm-deepseek: listing cache (scope by credential, first-use wait, background refresh, last-known-good, timer)
- llm-deepseek: listed catalog gating (`CLIENT_UPGRADE_REQUIRED`, `MODEL_UNSUPPORTED`) and overrides
- llm-deepseek: route re-registration when the retry policy changes
- llm-deepseek-api-key: route `deepseek-official` with `x-api-key`, `apiKeyEnv` credential reference, `MISSING_CREDENTIAL`
- llm-deepseek-api-key: follows the official listing only for the official origin and built-in catalog
- llm-deepseek-api-key: credential-gated `listModels`
- llm-deepseek-account: route `deepseek-account` with `x-dsh-auth-token`, `ACCOUNT_SIGN_IN_REQUIRED`
- llm-deepseek-account: `ACCOUNT_QUOTA` and `ACCOUNT_TOKEN_INVALID` mapping with token rejection
- llm-deepseek-account: `modelOverrides` validation and directory `error` reporting
- llm-pi-ai: `providers` dict config with catalog and hand-declared routes; dormant bare mount
- llm-pi-ai: profile resolution, strict versus deferred validation, removed-field diagnostics
- llm-pi-ai: route and directory registration that follow live config
- llm-pi-ai: credential resolution with fail-loud named references and native discovery otherwise
- llm-pi-ai: model metadata (context, configured max tokens, reasoning levels, update modes)
- llm-pi-ai: context conversion including system-reminder fallback and tool-result naming
- llm-pi-ai: stream event translation, usage mapping, stop-reason and error-text classification
- llm-pi-ai: replay envelope `pi-ai` version 2 and foreign-history fallback
- llm-pi-ai: Anthropic prefix-digest binding of signed thinking
- llm-pi-ai: `stop` rejected with `UNSUPPORTED_OPTION`; unsupported effort rejected
- llm-pi-ai: image budgets and `IMAGE_OFFLOAD_REQUIRED`
- llm-pi-ai: `llm-pi-ai/request-headers` waterfall with attribution enforced afterwards
- llm-pi-ai: `DeferredToolPlaceholder` for all-deferred Anthropic tool lists
- llm-pi-ai: endpoint model discovery for OpenAI, Anthropic, and Gemini listings
- llm-pi-ai: login flows and credential-record bridge
- llm-retry: listener on `agent/request-error` with normal and always modes
- llm-retry: eligibility by code, per-step budget keyed by provider and policy key
- llm-retry: exponential backoff with symmetric jitter and cap
- llm-retry: provider `Retry-After` used verbatim within the cap; over-cap delegates (normal) or falls back (always)
- llm-retry: durable `llm/retry` before the wait and `llm/retry-started` after it
- llm-retry: cancellation during backoff and drain on disposal
- llm-retry: config rejection of `retryPolicy` and unknown keys
- token-meter: fixed heuristic estimator for blocks, messages, system prompt, tool schemas
- token-meter: `measure` with usage or estimated baseline and signed surface delta
- token-meter: route image pricing and file handle pricing in surface nodes
- token-meter: `image/offload` handling in the surface cache
- token-meter: `tokenUsage` projection with per-step replacement and retry boundary
- token-meter: `contextPressure` projection with shadow-price claims and `projectedTokens`
- token-meter: `contextBreakdown` projection
- token-meter: `tokenMeasurement` projection with invalid-position recording
- token-meter: `deriveTurnTokenUsage` exact per-turn accounting, fail closed
- deepseek-llm-api-extensions: one provider per field, effect-scoped registration
- deepseek-llm-api-extensions: concurrent prepare with per-field omission and once-only warning
- deepseek-llm-api-extensions: cloned frozen values and memoized joint `accept`
- plugin-package-inventory-deepseek: `dsh_plugin_packages` version 1 field, sorted and deduplicated
- plugin-package-inventory-deepseek: active Loader entries plus session preset modules; `enabled: false` omits the field
- llm-mock-server: `/v1/messages` routing, API key check, script consumption rules
- llm-mock-server: all 23 concrete behaviors plus `random` with seeded weights
- llm-mock-server: request records and telemetry events
- llm-mock-server: CLI flags, `connection_refused` pre-listen phase, JSONL stdout, exit codes
- llm-replay: fixture parsing with projected or complete envelopes and fixture tokens
- llm-replay: script derivation from `assistant/message`, `assistant/attempt`, and marked `compaction/summary`
- llm-replay: override sidecar as full replacement or patches with exact-key validation
- llm-replay: `chunks`, `throw`, `hang` entries, `readyFile`, `paceMs`
- llm-replay: `{{session:N}}` and `{{fromRequest:regex}}` placeholders
- llm-replay: per-session binding by first-call order with child scripts after the inherited cut
- llm-replay: adapter mode with replay provider catalog versus catch-all waterfall mode
- llm-replay: extension prepare/accept reproduction for `deepseek-official`
- llm-replay: `assertConsumed` teardown check and unrecorded-session or exhausted-script errors
- llm-replay: environment defaults `DSH_SNAPSHOT_FILE`, `DSH_SNAPSHOT_OVERRIDE`, `DSH_SNAPSHOT_CHILD_FILES`
