# Recon 04: the core data plane

Pinned commit `e8f7b93a3`. Paths are relative to the repository root. `file:line` references point into `packages/core/<pkg>/src/` at that commit unless a longer path is given. "The loop" means `packages/core/agent-loop` and "the agent package" means `packages/core/agent`; another recon note owns both, and this note states only what they write into or read from the data plane.

Findings that differ from the task brief or from prose docs, each checked in source:

- None of the six packages registers a model-facing tool. `run_code` is only a reserved name here (`tools/src/contracts.ts:13`); the PTC executor owns it.
- `Session.deriveMessages()` reads only surface nodes. `request/header`, `request/context`, `assistant/attempt`, turn and step boundaries and `tool/call` never produce a message. They feed three other folds on the same object: `requestHeader()`, `requestContext()` and `toolHistory()`. A model request is built from all four (`packages/core/agent-loop/src/agent.ts:662-750`).
- `docs/subsystems/session.md` ("Live-session fork API") says fork rejects a prefix that ends inside an open turn. The code and `session/tests/fork.spec.ts:257-418` close the open tail with synthetic `forked` closers instead. The code is the authority.
- `docs/cookbook/adding-a-tool.md` says `presentationMeta` is skipped for nested dispatches. `createSuccessResult` (`tools/src/pipeline.ts:545-575`) runs it for every success, and `tools/tests/tools.spec.ts:678` pins "native and nested".
- `session/flush` is declared `@mode parallel` but is not dispatched with Cordis `parallel`. `SessionStore.flush` resolves a listener snapshot, awaits `Promise.allSettled`, and rethrows the first rejection value unchanged (no `AggregateError`).
- `dsh-tool-executor-native` has no Config schema. Its concurrency fallback `10` is a constructor default that the loop always overrides with its own `maxParallelToolCalls` (default `10`, `packages/core/agent-loop/src/constants.ts:6`).

Depth: `session`, `tools`, `system-prompt`, `scope` and `tool-executor-native` are covered in depth. `agent-tool-presentation` is a 54-line deprecated selector and is covered completely but briefly. The UI presentation vocabulary (`tools/src/presentation.ts`) is cataloged field by field without commentary. The TypeScript type-inference machinery of the schema DSL (`InferArgs`, `InferValue`) is described only by its runtime effect.

## Scope

| Package dir | npm name | Role | Src lines |
|---|---|---|---|
| `packages/core/session` | `@deepseek-ai/dsh-session` | Append-only typed event log (`Session`), in-memory store service `ctx.sessions`, surface fold, derived model history, request-header/context/tool-history folds, fork seed, tail repair, plugin records, seq-range codec | 3485 |
| `packages/core/system-prompt` | `@deepseek-ai/dsh-system-prompt` | `ctx.systemPrompt`: scoped registry of prompt sections, runtime contexts, variables and tool-schema providers; assembly waterfall; rendering and strict `{{var}}` interpolation; tool ordering | 699 |
| `packages/core/tools` | `@deepseek-ai/dsh-tools` | `ctx.tools`: scoped tool registry, restrictions, step admission, guards, executor selection; shared `ToolExecutionPipeline`; batch scheduler; schema DSL; enforced JSON Schema subset; UI render-intent types | 3784 |
| `packages/core/scope` | `@deepseek-ai/dsh-scope` | Library (no service): scope keys, scoped contexts, scope-filtered dispatch carriers, parent chain, `ScopedLayers` / `NamedEntries` / `AnonymousEntries` registry storage | 471 |
| `packages/core/agent-tool-presentation` | `@deepseek-ai/dsh-agent-tool-presentation` | Deprecated function plugin: `mode: native \| ptc` mounts the matching executor plugin as a child | 54 |
| `packages/core/tool-executor-native` | `@deepseek-ai/dsh-tool-executor-native` | Function plugin: registers `NativeToolExecutor` (direct function calls, bounded parallel batches) for the mounting scope | 35 |

Supporting code read because the area depends on it: `packages/util/values/src/index.ts` (lossless JSON snapshot, `deepFreeze`), `packages/llm/llm/src/{message,types,call-config,assistant-stream}.ts` (message and block types), `packages/core/agent/src/types.ts` and `packages/core/tool-executor-ptc/src/types.ts` (the other `SessionEventMap` members declared in `packages/core`), `packages/core/agent-loop/src/{agent,runtime-context}.ts` (producer of system, header and context events), `vendor/cordis/src/events.ts:161-183` (`dispatch`).

Docs read: `docs/subsystems/{session,system-prompt,tools,scope}.md`, `docs/tool-execution-pipeline.md`, `docs/cookbook/adding-a-tool.md`, the six package READMEs.

## Services

### `ctx.sessions` — `SessionStore` (`session/src/index.ts:1144`)

Service class, default export, registered as `sessions`. No Config. No static `inject`; it optionally uses `typert` through `ctx.inject(['typert'], …)` to register the lookup `session` (`parameter: 'session'`, `wire: 'sessionId'`, `resource: 'session'`, `resolve: id => this.get(id)`). State: `Map<SessionId, SessionEntry>` in insertion order, an id counter, and the list of registered message projections.

| Member | Semantics |
|---|---|
| `create(id?, options?) → Session` | `prepare` + one generator effect owned by the calling fiber: `yield enter(session)` then `announce(session)`. A throwing `session/created` listener rolls the entry back. Disposing the calling fiber detaches the session. |
| `prepare(id?, options?) → Session` | Mints `session-<n>` when `id` is omitted (`++counter`, skipping ids in the store). Throws `session "<id>" already exists` on a live duplicate. With `options.eventState` (`'detached' \| 'shared-frozen'`) it calls `Session.fromRestore(id, seed, meta, inheritedEventCount, eventState, projections)` and adopts values without copying. Otherwise it builds a header `{version, id, createdAt: meta.createdAt ?? now, cwd?, parentSession?, isSeeded: meta.isSeeded ?? false, origin?, delegationDepth?, agentPreset?}` (absent optionals are omitted, in that key order) and calls `Session.create`. The result is store-owned but unentered: appends throw. |
| `enter(session) → () => void` | Rechecks the id (`already exists`) and attachment (`is already attached to a store`). Captures `carrier = scopeTarget(session, scopeOf(this.ctx))` and `emitCtx = this.ctx`. Adds the entry with `announcement: 'pending'`. Returns a single-shot detach. Detach requested while a creation dispatch or an append publication is running is deferred until that unwinds. Emits nothing. |
| `announce(session)` | Requires a live entry in state `pending` (else `session "<id>" was already announced`). Sets `dispatching`, resolves the `session/created` listener snapshot, calls each listener synchronously. A synchronous throw sets `failed` and propagates. A returned rejected promise is logged at `warn` and ignored. Success sets `complete`, which enables appends. A deferred detach runs in `finally`. |
| `flush(session) → Promise<boolean>` | Requires a live entry (`session "<id>" is not live in this store`). Calls every `session/flush` listener (a synchronous throw becomes that listener's rejection), awaits all, rethrows the first rejection reason, else returns whether at least one listener ran. |
| `get(id) → Session \| undefined`, `list() → Session[]` | Live sessions only; `list` is a fresh array in creation order. |
| `fork(source, boundary?, childSessionId?) → Session` | See "Fork" under Algorithms. Errors are `SessionForkError` with `code` in `SESSION_NOT_FOUND`, `SESSION_NOT_LIVE`, `SESSION_ALREADY_EXISTS`, `INVALID_BOUNDARY`. |
| `registerMessageProjection(projection) → disposer` | One definition per event `type` (duplicate throws `session message projection "<type>" is already registered`). Effect-owned (`ctx.effect`, label `sessions.registerMessageProjection()`). The store passes its live projection array to every session it prepares; removing a definition a session has used makes that session's surface reads throw. |
| `messageProjections` (getter) | The live borrowed array, for detached replay. |

Ownership rules. A `Session` built by `Session.create` / `Session.fromRestore` outside a store is independent: it appends freely and publishes nothing. Once a store prepares or enters it, the module-private `attachments` weak map holds `null` (owned, unentered) or the live `SessionEntry`. Appends require an entry whose `announcement === 'complete'`. After detach the map holds `null` again, so writes stay disabled permanently. `session/disposed` is emitted on detach only if the announcement left `pending` (so a failed or partial announcement is still paired with a disposal). A given session object can be attached to at most one store.

### `Session` (plain class, not a service; `session/src/index.ts:555`)

| Member | Semantics |
|---|---|
| `static create(id, seed?, header?, inheritedEventCount?, projections?)` | Snapshot mode: every seed event and the header are validated and deep-copied through the lossless JSON pass, then deep-frozen. |
| `static fromRestore(id, seed, header, inheritedEventCount, eventState, projections?)` | Adopt mode: same validation, no copy and no freeze. The header must be a plain record (prototype `Object.prototype` or `null`) and is frozen in place. |
| `header: SessionHeader` | Frozen. Synthesized as `{version, id, createdAt: now, isSeeded: false}` when none is supplied. `id` reads `header.id`. |
| `inheritedEventCount`, `firstLiveSeq`, `firstLifecycleSeq` (`SessionLogOffset`) | See "Seed construction". The last two are in-process offsets and are never persisted. |
| `seq` | Next sequence number, always `log.length`. |
| `append(type, data, opts?) → SessionEvent` and `append(inputs[]) → SessionEvent[]` | See "Append". `opts` is `{surfaceOp, sourceEventSeqs?}`; required for the five surface types, forbidden otherwise. |
| `surface: SessionSurface` | `{nodes: readonly SessionSeq[], replaceGeneration, contentGeneration}`, a stable live view. |
| `deriveMessages() → Message[]` | Cached projection of the surface; fresh array per call, shared frozen messages. |
| `deriveEventMessage(event) → Message \| null` | One event with all committed message projections applied. |
| `requestHeader() → EpochHeader \| undefined` | Incremental fold of `request/header` events; frozen. |
| `requestContext() → RequestContext \| undefined` | Latest `request/context` payload (shallow copy, frozen). |
| `toolHistory() → ToolHistory` | Incremental fold of headers and developer messages. |
| `eventAt(seq)`, `snapshotEvents(from?, toExclusive?)`, `ownEvents()` | Deprecated synchronous readers, still used widely. `snapshotEvents()` with full range returns one cached frozen array until the next append; a partial range returns a fresh frozen slice. `ownEvents()` is `snapshotEvents(inheritedEventCount)`. |
| `isOwnSeq(seq)` | `inheritedEventCount <= seq < this.seq`. |
| `currentBatchPublication` | The batch member being delivered to `session/event` observers, else `undefined`. |

Module functions exported beside the class: `adoptSessionEvent(event)` (validate event-local rules, freeze the message in place), `snapshotSessionEvent(event)` (`structuredClone` then adopt), `appendPluginRecord(session, type, data) → SessionSeq`, `pluginRecordOf(event) → PluginRecord | undefined`, `buildForkSeed`, `interruptedTurnClosers`, `ToolCallRecovery`, `TOOL_NOT_STARTED`, `TOOL_OUTCOME_UNKNOWN`, `deriveEventMessage`, `foldSurface`, `isSurfaceEvent`, `isAppendSurfaceEvent`, `isReplacementSurfaceEvent`, `isSurfaceEligibleType`, `canonicalHeader`, `headerEquals`, `foldRequestHeader`, `KNOWN_SESSION_EVENT_TYPES`, `encodeSeqRanges`, `decodeSeqRanges`, `SessionPreparation`, the brand constructors `SessionId`, `SessionSeq`, `SessionLogOffset`, and `SESSION_FORMAT_VERSION`. Subpath exports: `./types`, `./fork`, `./surface` (browser-safe, no Node imports).

`SessionPreparation.create(session, {release?})` wraps one unpublished session with a synchronous, idempotent `[Symbol.dispose]` that calls `release` once (`session/src/preparation.ts`).

### `ctx.systemPrompt` — `SystemPrompt` (`system-prompt/src/index.ts:436`)

Service class, default export, registered as `systemPrompt`. No `inject`. All registrations are scoped by the calling context (`scopeOf(this.ctx)`), are Cordis effects, and emit `system-prompt/change` on registration and on disposal.

| Member | Semantics |
|---|---|
| `section(section) → disposer` | `PromptSection = {name, order, text: string \| (ctx: AssembleContext) => string, interpolate?: boolean, complete?: boolean}`. `order` must be finite (`TypeError prompt section "<name>" order must be a finite number`). Duplicate name in one layer throws; a scoped section shadows a same-named global or ancestor section. |
| `context(context) → disposer` | `PromptContext = {name, order, text, interpolate?, required?}`. Same duplicate and finite-order rules. |
| `variable(name, provider) → disposer` | `name` must match `/^[a-z][a-z0-9_]*$/`; `provider(ctx) → string \| undefined`. Scoped shadows global. |
| `tools(provider) → disposer` | `provider(ctx) → {schemas: ToolSchema[], knownNames?: string[]}`. Global and every scope-chain provider contribute (no shadowing). |
| `suppressRuntimeContext() → disposer` | Adds one suppressor to the calling scope's layer. While any suppressor exists in the global layer or the viewing scope's chain, only `required` contexts survive. |
| `getSectionOrder(name)`, `getContextOrder(name)` | Central order tables (see Formats). |
| `assemble(context = {}) → Promise<PromptAssembly>` | See "System prompt assembly". |
| `refreshContext(assembly, context = {}) → PromptAssembly` | Re-reads registered context providers without rerunning sections, tools, variables or the waterfall. |

Exported functions: `renderPrompt(assembly) → string`, `renderContextSections(assembly) → {name, text}[]`, `joinContextSections(sections) → string`, `renderContextSnapshot(assembly) → string`. Constants: `PERSONA_PREFIX_SECTION = 'deployment:persona-prefix'`, `PERSONA_SUFFIX_SECTION = 'deployment:persona-suffix'`, `TOOL_ORDER_REST = '<unlisted-tools>'`.

`AssembleContext` is merge-extensible: the base is `{scope?: ScopeKey, signal?: AbortSignal}`; the agent package adds `agent?` and `modelSelection?` (`packages/core/agent/src/runtime-types.ts:19-25`); the tools package adds `toolSet?: ResolvedToolSet` (`tools/src/index.ts:18-23`). `assembleContextFor(agent, signal)` returns `{agent, scope: agent, signal?}`.

### `ctx.tools` — `ToolsService`, also exported as `ToolRuntime` (`tools/src/index.ts:99`)

Service class, default export, registered as `tools`, `static inject = ['systemPrompt']`. On construction it registers one global tool-schema provider with `ctx.systemPrompt.tools`: for `{scope, toolSet}` it selects the scope's executor, calls `executor.describe(this.definitions(scope, toolSet))`, and returns that description with `knownNames` defaulting to the scope view's pre-restriction names.

| Member | Semantics |
|---|---|
| `register(definition, options = {}) → disposer` | Validates `output` (`TypeError tool "<name>" must declare output { schema, render, presentationMeta? }`), runs `assertSupportedJsonSchema(output.schema)`, validates `timeoutMs` (positive finite), refuses the name `run_code`. Inserts into the calling scope's layer. Duplicate name in the same layer throws `tool "<name>" is already registered …`. `options.when(context) → boolean \| Promise<boolean>` is the step-time activation condition. Emits `tools/change`. |
| `restrict({allow?, deny?}) → disposer` | Scoped contexts only. Rejects an empty filter, the name `run_code`, and any name that is not currently an inherited (global or ancestor) tool. Filters are compiled to sets at registration. Emits `tools/change`. |
| `get(name, scope?, toolSet?)` | The definition as that scope sees it; with `toolSet`, as the step admitted it. |
| `executable(name, scope?, toolSet?)` | Execution lookup. With `toolSet`, the set decides. Without one, a registration that has a `when` condition is unavailable. |
| `resolve({agent, modelSelection, signal}) → Promise<ResolvedToolSet>` | Evaluates `when` once per visible registration for one step. |
| `definitions(scope?, toolSet?)`, `schemas(scope?, toolSet?)` | Visible definitions; `schemas` projects each to `{name, description, parameters (deep-copied), deferLoading?}`. |
| `setExecutor(executor) → disposer` | One executor per scope (`Only one tool executor may be registered in each scope`). Registers the executor's `sections` as prompt sections whose text is `''` unless this executor is the one selected for the assembling scope. Disposal leaves the record in place with `executor = undefined`, so later lookups throw `ToolExecutorUnavailableError` and do not fall through to an outer scope. Does not emit `tools/change`. |
| `execute(input: ToolBatchInput) → Promise<ToolBatchResult>` | `selectExecutor(input.agent).execute(input)`. |
| `guard(guard) → disposer` | Appends a monotonic guard to the calling scope's guard layer. No change event. |
| `checkGuards(exec) → ToolGuardDenial \| undefined` | Runs global guards, then guards along `exec.agent`'s chain from the farthest ancestor to the agent, each layer in insertion order; the first non-`undefined` return wins. A string return becomes `{reason}`. |

### Capability interfaces that plugins implement

`ToolExecutor` (`tools/src/executor.ts`): `{sections?: ToolPromptSection[], describe(tools) → {schemas, knownNames?}, execute(input) → Promise<ToolBatchResult>}`. `ToolPromptSection = {name, order, interpolate?, text: string | (tools) => string}`.

`ToolExecutionPipeline` (`tools/src/pipeline.ts:63`, subpath `@deepseek-ai/dsh-tools/pipeline`): constructed with `(ctx, source?)` where `source = {get?(name, scope, toolSet), reject?(name, nested) → Error | undefined}` lets an executor own lookup and pre-policy refusal. Methods: `executionMode(input) → {kind: 'parallel' | 'exclusive'}`, `prepare(input)`, `dispatch(exec)`, `complete(exec, outcome)`. `executeToolBatch(input, pipeline, maxParallel)` is exported from the same subpath.

### The scope library (`scope/src/index.ts`, `scope/src/store.ts`)

Not a service. `createScope(ctx, key, {parent?}) → {ctx, rawDispose, dispose}`; `scopeOf(ctx) → ScopeKey | undefined`; `scopeTarget(base, key) → Scoped<T>`; `isScopeCarrier(value)`; `carrierKeyOf(value)`; `bindScopeParent(key, parent) → {rebind(parent)}`; `scopeParentOf(key)`; `scopeChainOf(key) → [key, parent, …]`; classes `ScopedLayers<L>`, `NamedEntries<V>`, `AnonymousEntries<V>`; interface `ScopeLayer {isEmpty()}`. Details are under Algorithms.

## Events

All four `session/*` events and the three `tools/*` policy waterfalls plus `tools/result` and `system-prompt/assemble` are scope-filtered: they are dispatched with a carrier from `scopeTarget(subject, key)` as the Cordis `this`. An untagged listener always receives them; a listener registered through a scoped context receives them only when its tag equals the dispatch key or one of its ancestors.

| Event | Mode | Payload | Producer | Guarantees |
|---|---|---|---|---|
| `session/created` | emit | `(session)` | `SessionStore.announce` | Carrier key is the scope of the context that called `enter`. Listeners run synchronously in registration order while the session is read-only. A synchronous throw vetoes creation. An async rejection is logged (`session "<id>": session/created listener rejected: …`). |
| `session/disposed` | emit | `(session)` | `SessionStore` detach | Same carrier as creation. Exactly once per announced session. Each listener is contained; failures are logged at `warn`. |
| `session/event` | emit | `(session, event)` | `Session.append` on a store-entered session | The listener snapshot (including Cordis `internal/dispatch` observers) is resolved before the event enters the log; a failure there rejects the append and leaves the log unchanged. Callbacks run after the push, in order, each contained (`listener threw` / `listener rejected` warnings). `session.seq` and `session.surface` already include the event. For an array append, all members are in the log and surface before the first callback runs; `session.currentBatchPublication` names the member being delivered. Seed events are never published. |
| `session/flush` | parallel (awaited by hand) | `(session)` → `Promise<void> \| void` | `SessionStore.flush` | All listeners run; the caller awaits all; first rejection is rethrown. |
| `system-prompt/assemble` | waterfall | `(assembly: PromptPresentation, context: AssembleContext, next)` → `Promise<PromptPresentation>` | `SystemPrompt.assemble` | Carrier key is `context.scope`. The returned value replaces sections, contexts and variables; tools are not in the payload. A registered `complete` section is restored afterwards. |
| `system-prompt/change` | emit | none | `SystemPrompt` registrations and disposals | Unfiltered (`ctx.emit`). Emitted after the mutation. A throwing listener rolls a new registration back. |
| `tools/pre-execute` | waterfall | `(exec: ToolExecution, next)` → `Promise<PreToolDecision>` | `ToolExecutionPipeline.prepare` | Default `{kind: 'allow'}`. Carrier key is `exec.agent`. Runs once per call, in model order across a batch. |
| `tools/execute` | waterfall | `(exec: ToolDispatchExecution, next)` → `Promise<ToolExecutionResult>` | `ToolExecutionPipeline.dispatch` | The innermost `next` runs the tool body. A wrapper may replace `exec.signal` only. May overlap with sibling calls. |
| `tools/post-execute` | waterfall | `(exec, result, next)` → `Promise<PostToolDecision>` | `ToolExecutionPipeline.complete` | Default `{kind: 'accept'}`. Runs in model order. Not run for `final-result` outcomes (pipeline failures, executor refusals, pre-aborted calls). |
| `tools/result` | emit | `(exec, result)` | `ToolExecutionPipeline` finish | `exec` is frozen (`Object.freeze`) first; `result` is deep-frozen lossless JSON plus the frozen canonical `value`. Each listener is contained; failures log `tool "<name>" (<callId>): tools/result observer failed: …`. Fires exactly once per call, before the durable `tool/result` append. |
| `tools/change` | emit | none | `ToolsService.register`, `restrict` and their disposals | Unfiltered. Not emitted by `guard` or `setExecutor`. |

Consumers live outside this area: persistence writers and projections (`session/event`, `session/created`, `session/disposed`, `session/flush`), the loop's `ToolCallRecovery` observer and runtime-context tracker (`session/event`), permission, sandbox, hook, approval, timeout and spill plugins (`tools/*`), preset and persona plugins (`system-prompt/assemble`). `tools/ptc-dispatch-log` (waterfall) is listed in `docs/subsystems/tools.md` but is declared by the PTC executor.

## Tools

None. These packages register no model-facing tool.

What they do contribute to model-visible tool traffic:

- Every failed call's content is exactly one text block `Error: <message>` (`tools/src/pipeline.ts:719-726`). Structured `error.info.reason` is never added to model content.
- Cancellation results: `Error: tool call aborted` (code `ABORTED`) and `Error: tool call aborted before dispatch` (code `ABORTED_BEFORE_DISPATCH`), both with `info.name = 'AbortError'`.
- Unknown tool: `Error: unknown tool "<name>"` (`ToolNotFoundError`, code `UNKNOWN_TOOL`); with a `reachableFrom` hint: `unknown tool "<name>": <hint>`.
- Approval denials (error name `ApprovalError`): `tool "<name>" requires approval (not yet supported)` when no approval service exists and the ask gave no reason (otherwise the ask's own `reason`), `tool "<name>" requires approval, but the call has no agent to route it through`, `the user rejected tool "<name>"`, `approval for tool "<name>" was cancelled`, `tool "<name>" requires approval, but no approval channel is available`.
- Argument validation (`ToolArgsError`, `INVALID_ARGS`): `invalid arguments: <violation>; <violation>…`.
- Output validation (`ToolOutputError`, `INVALID_TOOL_OUTPUT`): `tool "<name>" returned invalid output: <violations>`.
- Synthetic recovery results from `session/src/repair.ts:32-41` (four fixed texts, quoted under Formats).
- `developer/message` blocks `tool-addition` / `tool-removal` with source `{kind: 'tool-registry'}` (written by the loop, validated here).

## Configuration

| Plugin (package) | Form | `name` / service key | `inject` | Config |
|---|---|---|---|---|
| `dsh-session` | Service class, default export `SessionStore` | `sessions` | none (optional `typert` via `ctx.inject`) | none |
| `dsh-system-prompt` | Service class, default export `SystemPrompt` | `systemPrompt` | none | see below |
| `dsh-tools` | Service class, default export `ToolsService` | `tools` | `['systemPrompt']` | see below |
| `dsh-scope` | Library | — | — | — |
| `dsh-tool-executor-native` | Function plugin (`name`, `inject`, `apply`) | `name = 'native-tool-executor'` | `['tools']` | none |
| `dsh-agent-tool-presentation` | Function plugin (`name`, `inject`, `Config`, `apply`), deprecated | `name = 'tool-presentation'` | `['tools']` | see below |

`SystemPrompt.Config` (`system-prompt/src/index.ts:437-444`):

| Field | Type | Default | Meaning |
|---|---|---|---|
| `includeHarnessIdentity` | boolean | `true` | Register section `harness:identity` at order `-1000` with text `You are an AI agent powered by DeepSeek Harness.` |
| `includeRuntimeContext` | boolean | `true` | When `false`, the constructor calls `suppressRuntimeContext()` globally. |
| `personaPrefix` | string | `''` | Text of section `deployment:persona-prefix` at order `0`. Always registered, even when empty. `{{var}}` references are strict. |
| `personaSuffix` | string | `''` | Text of section `deployment:persona-suffix` at order `10200`. |
| `toolOrder` | string[] | absent (must stay `undefined`, not `[]`) | Model-facing tool order. Must contain `'<unlisted-tools>'` exactly once and no duplicates, checked at construction: `toolOrder lists "<name>" more than once`, `toolOrder must contain the "<unlisted-tools>" rest entry (where unlisted tools are inserted)`. Unknown names fail at assembly. |

Shipped values: `packages/bundle/base/cordis.patch.yml:526` sets `personaPrefix: ''`; `packages/bundle/sdk-minimal/cordis.patch.yml:114` sets `includeHarnessIdentity: false`, `includeRuntimeContext: false`, `personaPrefix: !!js process.env.DSH_SYSTEM_PROMPT ?? 'You are a helpful software engineer assistant.'`.

`ToolsService.Config` (`tools/src/index.ts:101-104`): `mode: never` ("Removed. Mount a native or PTC tool executor instead.") and `maxParallelSubCalls: never` ("Moved to the PTC tool executor configuration."). Supplying either key fails plugin mounting (`tools/tests/tools.spec.ts:55`). There are no accepted fields.

`dsh-agent-tool-presentation` Config: `mode: 'native' | 'ptc'`, required, no default. `apply` runs `ctx.plugin(mode === 'native' ? NativeToolExecutor : PtcToolExecutor)`. With `ptc` the child waits for its runtime; until then the inherited executor stays active.

`dsh-tool-executor-native` `apply(ctx)`: `ctx.tools.setExecutor(new NativeToolExecutor(ctx))`. `NativeToolExecutor(ctx, maxParallel = () => 10)`: `describe(tools)` returns `{schemas: tools.map(d => projectToolSchema(d, false))}` (parameters are not copied here; assembly copies them); `execute(input)` is `executeToolBatch(input, new ToolExecutionPipeline(ctx), maxParallel)`; no `sections`.

Composition rows (`packages/bundle/base/cordis.patch.yml`): `- id: session, name: '@deepseek-ai/dsh-session'`; `- id: tools, name: '@deepseek-ai/dsh-tools'`; `- id: tool-executor-native, name: '@deepseek-ai/dsh-tool-executor-native'`; `- id: tool-executor-ptc … disabled: true`; `- id: system-prompt, name: '@deepseek-ai/dsh-system-prompt', config: {personaPrefix: ''}`.

## Formats

### Session event envelope

`SessionEvent` (`session/src/types.ts:506-529`) in memory and on the wire is a JSON object with exactly these keys:

| Key | Type | Rule |
|---|---|---|
| `type` | string | A `SessionEventMap` key, or a `plugin:` record type, or an unknown type that carries `ignorable: true`. |
| `seq` | number | Non-negative safe integer, not `-0`. Equals the event's index in the log. |
| `time` | number | Safe integer, Unix epoch milliseconds (`Date.now()` at append). |
| `data` | lossless JSON | Must be present. |
| `surfaceOp` | `'append'` or `{op: 'replace', startSeq, endSeq}` | Required on the five surface types, forbidden on known log-only types. The replace object has exactly those three keys. |
| `sourceEventSeqs` | number[] | Optional on `system/message`, `developer/message`, `user/message`, `tool/result`; forbidden on `assistant/message` and on log-only types. Non-empty, unique, each `< seq`. |
| `ignorable` | `true` | Optional. Absent means required-on-read. |

Any other key on a seed event is rejected (`seed event at index <i> has an invalid event envelope`, `session/src/index.ts:206-234`). Key order of a freshly appended event is `type, seq, time, data, sourceEventSeqs?, surfaceOp?` (`index.ts:531-542`); a plugin record is `type, seq, time, data, ignorable`. Unknown ignorable events keep any `surfaceOp` / `sourceEventSeqs` they carry as opaque data and never touch the surface (`surface.ts:304-306`).

`SESSION_FORMAT_VERSION = 4` (`session/src/types.ts:90`). It is one monotonic integer stamped into every new header. The core accepts only this value.

Numeric position types: `SessionSeq` (an existing event), `SessionLogOffset` (a gap or prefix length, may equal the event count), `SessionSeqCursor = SessionSeq | -1`, `OptionalSessionSeq = SessionSeq | null`. The constructors throw `TypeError` for anything but a non-negative safe integer that is not `-0`. Brands vanish at runtime.

### `SessionHeader`

`{version: 4, id: SessionId, createdAt: number, cwd?: string, parentSession?: SessionId, isSeeded: boolean, origin?: 'subagent', delegationDepth?: number, agentPreset?: string}`. Validation (`session/src/index.ts:98-140`): plain record; no own key `seedLength`; `version === 4`; `id` equals the session id; `createdAt` and `delegationDepth` non-negative safe integers; `cwd` a string that is an absolute path (`node:path` `isAbsolute`); `isSeeded` boolean; `origin` only `'subagent'`. Unknown extra keys are retained. The header is not an event.

### Every `SessionEventMap` member declared in `packages/core`

No member below is ever written with `ignorable`; `Session.append` has no way to set it. Only `appendPluginRecord` writes `ignorable: true`. "Surface" means the event carries `surfaceOp` and can produce a model message.

| Type | Declared in | Surface | `data` fields |
|---|---|---|---|
| `turn/start` | session | no | `{turn: number}` |
| `turn/end` | session | no | `{turn: number, reason: TurnEndReason}` |
| `step/start` | session | no | `{turn, step}` |
| `step/end` | session | no | `{turn, step}` |
| `user/message` | session | yes | A `UserMessage` directly (no wrapper): `{id, role: 'user', content: ContentBlock[], source: MessageSource}` |
| `developer/message` | session | yes | `{turn, step, message: DeveloperMessage, headerSeq?: SessionSeq}` |
| `system/message` | session | yes | `{turn, step, message: SystemMessage}` |
| `assistant/message` | session | yes | `{turn, step, message: AssistantMessage, stream: AssistantStreamRecord[], usage?: TokenUsage, interrupted?: true}` |
| `assistant/attempt` | session | no | `{turn, step, stream: AssistantStreamRecord[]}` |
| `tool/call` | session | no | `{turn, step, callId: ToolCallId, name: string, arguments: string}` (`arguments` is the raw model JSON text, unparsed) |
| `tool/result` | session | yes | `{turn, step, message: ToolResultMessage, error?: {name, code, reason?}, meta?: JsonValue}` |
| `request/header` | session | no | `{header: EpochHeader, reason: 'initial' \| 'resume' \| 'change' \| 'series', startsSeries?: true}` |
| `request/context` | session | no | `RequestContext` directly: `{provider, model, contextWindow?: number, systemPromptUpdate?: 'in-history'}` |
| `session/end-seed` | session | no | `{inherited?: true}` |
| `agent/inbox/spliced` | agent | no | `{target: 'next-turn' \| 'next-step', start: number, removedCount?: number, inserted: UserMessage[], outcome?: 'canceled'}` |
| `model/selection` | agent | no | `{provider, model, reasoningEffort?}` |
| `tool/ptc-dispatch-start` | tool-executor-ptc | no | `{rootCallId, parentCallId, subCallId, name, arguments: unknown}` |
| `tool/ptc-dispatch` | tool-executor-ptc | no | the start fields plus `{isError: boolean, content: ContentBlock[], meta?: JsonValue, error?: {name, code, reason?}}` |

`TurnEndReason` variants (merge-extensible, `types.ts:206-235`): `{kind: 'completed'}`, `{kind: 'aborted', reason: TurnEndCancelCause}`, `{kind: 'blocked'}`, `{kind: 'error', error: LlmFailure}`, `{kind: 'max-tokens'}`, `{kind: 'interrupted'}`, `{kind: 'forked'}`. `TurnEndCancelCause` is `{kind: 'user'} | {kind: 'parent'} | {kind: 'hook', reason: string} | {kind: 'disposed'} | {kind: 'legacy'}`. `LlmFailure = {message, code, status?, providerRetryAfterMs?, requestId?, offloadImages?}`. The loop never writes `interrupted` or `forked` live.

`EpochHeader = {config: LlmCallConfig, adapterDefaults?: {reasoningEffort?: true, maxTokens?: true}, tools?: ToolSchema[]}`. `LlmCallConfig = {provider, model, reasoningEffort?, temperature?, maxTokens?, stop?: string[]}`. Canonical rules enforced at append, seed and adoption (`surface.ts:200-211`): no own key `system` (even with value `undefined`), no `tools: []`, no `adapterDefaults: {}`. `ToolSchema = {deferLoading?: true, name, description, parameters}`.

Messages (`packages/llm/llm/src/message.ts`): every message has `id` (non-empty string; `createMessage` uses a random UUID), `content: ContentBlock[]`, `source: {kind, …}`, and `role`. `SystemMessage`: role `system`, source `{kind: 'system-prompt'}`, content `[]` for an empty prompt or one text block. `DeveloperMessage`: role `developer`. `UserMessage`: role `user`, any source kind. `AssistantMessage`: role `assistant`, source `{kind: 'model', provider, model, replayState?}`. `ToolResultMessage`: role `tool`, source `{kind: 'tool', callId}`, `toolCallId` equal to `source.callId`, `isError?: boolean`. Content block types: `text {text}`, `reasoning {text}`, `image {attachment, offloaded?}`, `file {attachment}`, `tool-call {id, name, arguments}`, `tool-addition {toolName}`, `tool-removal {toolName}`. Source kinds declared in this area: `user`, `model`, `tool`, `system-prompt` (llm), `tool-registry` (tools), `ptc-mode` (PTC), `runtime-context` (loop, with `form: 'snapshot'` and `sections: {name, text}[]`).

`AssistantStreamRecord` (opaque to the session, owned by the LLM note): `text-chunks` / `reasoning-chunks` `{type, time0, index, dt[], texts[]}`, `tool-call-chunks` `{type, time0, index, dt[], id, name?, args[]}`, `chunk` `{type, time, chunk}`.

### Known event types and plugin records

`KNOWN_SESSION_EVENT_TYPES` (`session/src/known-event-types.ts`, generated by `scripts/gen-persistence-catalog.ts`) holds 63 names: `agent-preset/selected`, `agent/inbox/spliced`, `approval/asked`, `approval/decided`, `approval/policy`, `assistant/attempt`, `assistant/message`, `command/done`, `command/run`, `compaction/end`, `compaction/prune`, `compaction/start`, `compaction/summary`, `deliverables/presented`, `developer/message`, `feedback/message-delete`, `feedback/message-put`, `feedback/record`, `goal/change`, `hook/invoked`, `hook/result`, `image/offload`, `job/registered`, `job/settled`, `llm/retry`, `llm/retry-started`, `model/selection`, `permission/preset`, `plan/mode`, `request/context`, `request/header`, `sandbox/mode`, `schedule/change`, `session-log-deepseek/delivery-accepted`, `session/end-seed`, `session/title`, `session/title-llm-request`, `step/end`, `step/start`, `subagent/catalog`, `subagent/descriptor`, `subagent/model-selection-policy`, `system/message`, `team/member`, `team/message/delivered`, `team/message/queued`, `team/mode`, `team/task`, `todo/write`, `tool-workflow/agent-end`, `tool-workflow/agent-start`, `tool-workflow/run-end`, `tool-workflow/run-start`, `tool/call`, `tool/ptc-dispatch`, `tool/ptc-dispatch-start`, `tool/result`, `turn/end`, `turn/start`, `user/message`, `web/deepseek-search-llm-request`, `working-directory/change`, `workspace/changes`.

`MESSAGE_PROJECTION_EVENT_TYPES = {'image/offload'}`: an event of this type cannot be accepted (append, seed or fold) unless a projection definition for it is supplied.

Plugin record type grammar: `/^plugin:[a-z0-9][a-z0-9._-]*(?:\/[a-z0-9][a-z0-9._-]*)*$/u`. Naming convention `plugin:<owner>/<record>`. `PluginRecord = {type, seq, time, data: unknown}`; `pluginRecordOf` returns it only when `event.ignorable === true` and the type matches the grammar.

### `sourceEventSeqs` range encoding (storage form)

`encodeSeqRanges(values)` (`session/src/seq-ranges.ts:19-30`): if the list is not strictly increasing, return it unchanged; otherwise replace each run of three or more consecutive integers with the pair `[first, last]` and keep shorter runs as plain numbers. `decodeSeqRanges(value, maxEntries)` expands pairs, requires `start <= end`, non-negative safe integers, total length within `maxEntries`, and, if any pair was present, a strictly increasing result. Errors are `TypeError` with messages starting `sourceEventSeqs …`. The in-memory event always holds the expanded list; the JSONL backend applies the encoding.

### Synthetic recovery results (`session/src/repair.ts`)

Message id: `<cause>-tool-result-<callId>-<seq>` where cause is `interrupted` or `forked`. Event: `tool/result` with `surfaceOp: 'append'`, `data.error = {name: 'ToolOutcomeUnknownError', code: 'TOOL_OUTCOME_UNKNOWN'}` plus `sourceEventSeqs: [callSeq]` when a `tool/call` was logged, else `{name: 'ToolNotStartedError', code: 'TOOL_NOT_STARTED'}` and no sources. `isError: true`. Text:

- interrupted, started: `The tool call was interrupted after it was recorded, but no result was durably recorded. Its outcome is unknown. Decide whether to retry from the tool semantics: retry only if the operation is read-only or idempotent; if it may have side effects, first verify external state or ask the user. Do not retry blindly.`
- interrupted, not started: `The tool call was interrupted before the Harness recorded it as started. Retry it if it is still needed.`
- forked, started: `The history inherited by this branch records this tool call starting but does not include its result. The parent session may have completed it after the fork point. Decide whether to retry from the tool semantics: retry only if the operation is read-only or idempotent; if it may have side effects, first verify external state or ask the user. Do not retry blindly.`
- forked, not started: `The history inherited by this branch has no record of this tool call starting. The parent session may have executed it after the fork point. Decide whether to retry from the tool semantics: retry only if the operation is read-only or idempotent; if it may have side effects, first verify external state or ask the user. Do not retry blindly.`

### System prompt order tables and strings

`SECTION_ORDERS` (`system-prompt/src/index.ts:136-173`): `HARNESS_IDENTITY -1000`, `DEPLOYMENT_PERSONA_PREFIX 0`, `PLAN_POLICY 500`, `TEAM_POLICY 600`, `PTC_ONLY 800`, `FILE_REFERENCE 900`, `TOOL_BASH 1000`, `TOOL_PWSH 1010`, `TOOL_READ 1100`, `TOOL_WRITE 1200`, `TOOL_EDIT 1300`, `TOOL_APPLY_PATCH 1350`, `TOOL_GLOB 1400`, `TOOL_GREP 1500`, `TOOL_JOBS 1600`, `TOOL_PTY 1700`, `TOOL_PTY_PANEL 1710`, `TOOL_WEB_SEARCH 2000`, `TOOL_WEB_FETCH 2100`, `TOOL_LSP 2200`, `TOOL_SESSION_QUERY 2300`, `TOOL_GOAL 2400`, `TOOL_SCHEDULE 2500`, `TOOL_WORKFLOW 2600`, `TOOL_RALPH 2700`, `TOOL_SUBAGENT 2800`, `TOOL_REPORT 2900`, `TOOL_COMPUTER_USE 3000`, `MCP_SERVERS 3100`, `TOOLS_SDK 5000`, `DELIVERABLE_FILE_REFERENCES 9000`, `STRUCTURED_OUTPUT 9900`, `HARNESS_SOURCE 10000`, `WEB_SURFACE 10100`, `DEPLOYMENT_PERSONA_SUFFIX 10200`.

`CONTEXT_ORDERS` (`:178-186`): `WORKING_DIRECTORY 100`, `SANDBOX_POLICY 110`, `APPROVAL_POLICY 115`, `SUBAGENT_DELEGATION 120`, `HARNESS_SOURCE 200`, `WEB_SURFACE 210`.

`joinContextSections` prefix: `Current runtime context. This snapshot supersedes earlier runtime-context snapshots.` followed by a blank line and the section texts joined with blank lines; empty body gives `''`.

### Tool definition and execution data

`ToolDefinition` (`tools/src/contracts.ts:27-103`), in full:

| Field | Type | Notes |
|---|---|---|
| `name`, `description`, `parameters` | string, string, JSON Schema object | The model-facing `ToolSchema`. |
| `deferLoading` | `true`, optional | Kept through schema projection and assembly. |
| `output` | `{schema: JsonSchemaNode, render(args, value) → ContentBlock[], presentationMeta?(args, value) → JsonValue}` | Mandatory. |
| `execute(args, exec: ToolRunContext)` | `Promise<unknown>` | Returns the canonical JSON value only. |
| `projectContent?(exec, result)` | `ContentBlock[] \| undefined` | Runs once before `tools/post-execute`. |
| `finalizeContent?(exec, result)` | `ContentBlock[] \| undefined` | Runs exactly once on every normalized outcome, last. Synchronous. |
| `timeoutMs?` | positive finite number | Declarative; enforced by a separate `tools/execute` wrapper plugin. |
| `isConcurrencySafe?(args)` | boolean | Only an exact `true` opts in to parallel execution. |
| `presentCall?(args)` | `ToolCallView \| undefined` | Pure. |
| `presentResult?(args, result: ToolResult)` | `ToolResultView \| undefined` | Pure. `ToolResult = {content, isError, meta?}`. |

Only `name`, `description`, `parameters` and `deferLoading` ever reach a model.

`ToolExecutionInput = {callId, rootCallId?, name, schema?, arguments, agent?, toolSet?, parent?: ToolExecutionToken, signal}`. `ToolExecution` adds resolved `rootCallId` (defaults to `callId`) and `token` (a fresh unique symbol-like identity). `ToolRunContext` adds `deferContext(userMessage)` and `concludeTurn()`. `ToolDispatchExecution` is the same object with a writable `signal`.

`ToolExecutionResult` is `{isError: false, value: JsonValue, content, meta?, additionalContexts?: UserMessage[], concludesTurn?: true}` or `{isError: true, error: {message, info?: {name, code, reason?}}, content, meta?, additionalContexts?}`.

`PreToolDecision`: `{kind: 'allow'}`, `{kind: 'deny', reason, info?}`, `{kind: 'cancel'}`, `{kind: 'ask', reason?, displayReason?: {en, [locale]: string}}`. `PostToolDecision`: `{kind: 'accept', content?, additionalContexts?}`, `{kind: 'accept', value, additionalContexts?}`, `{kind: 'block', feedback: ContentBlock[], info?, additionalContexts?}`. `ToolGuard = (exec) => string | {reason, info?} | undefined`. `ToolRestriction = {allow?: string[], deny?: string[]}`.

`ToolBatchInput = {calls: ToolCallBlock[], signal, maxParallelToolCalls?, agent?, toolSet?, log?: {turn, step}}`. `ToolBatchResult = {results: {callId, result}[], additionalContexts: UserMessage[], concluded: boolean}`.

Error identities recorded on results (persisted strings):

| name | code | Origin |
|---|---|---|
| `AbortError` | `ABORTED` | Cancellation after the body was invoked |
| `AbortError` | `ABORTED_BEFORE_DISPATCH` | Cancellation before the body was invoked, and skipped batch members |
| `ToolNotFoundError` | `UNKNOWN_TOOL` | Unknown, hidden, unadmitted or removed tool |
| `ToolArgsError` | `INVALID_ARGS` | `defineTool` argument validation |
| `ToolOutputError` | `INVALID_TOOL_OUTPUT` | Body value, renderer or projector violates the output contract |
| `ToolContextUnavailableError` | `TOOL_CONTEXT_UNAVAILABLE` | Thrown by tool bodies that lack an agent, service or open turn |
| `ApprovalError` | `APPROVAL_REJECTED`, `APPROVAL_CANCELLED`, `APPROVAL_UNAVAILABLE` | Non-granted `ask` |
| `ToolActivationError` | `TOOL_ACTIVATION_FAILED` | A `when` condition threw (fails step preparation, not a tool result) |
| `ToolExecutorUnavailableError` | `TOOL_EXECUTOR_UNAVAILABLE` | Selected executor missing or unloaded (batch rejects) |
| `JsonSchemaError` | `UNSUPPORTED_SCHEMA` | Schema outside the subset (registration time) |
| `ToolOutcomeUnknownError` / `ToolNotStartedError` | `TOOL_OUTCOME_UNKNOWN` / `TOOL_NOT_STARTED` | Recovery results |

Any thrown `HarnessError` contributes `{name: error.name, code: error.code}`; any other thrown value yields an `error` without `info`.

### Schema DSL and the enforced JSON Schema subset

Author DSL (`tools/src/schema.ts`): a value node is one of `{type: 'string'|'number'|'integer'|'boolean'|'null', enum?, const?}`, `{type: 'array', items?}`, `{type: 'object', properties?, additionalProperties: boolean}` (openness is mandatory), `{type: 'json'}` (unconstrained, author-only), or `{oneOf: [a, b, …]}` (at least two). Every node may carry `description`, `title`, `default`, `examples`. A parameter map is `{[name]: node & {required?: true}}`. Compilation: `parameterSchemaSpecToJsonSchema(spec)` gives `{type: 'object', properties: {…}, required?: [names in property order]}` with no `additionalProperties` key (the root is open); `required` is removed from each property and is emitted only when non-empty. `{type: 'json'}` compiles to a node with annotations only. Property order is preserved. Unknown author keys throw `JsonSchemaError`.

Raw subset (`tools/src/json-schema.ts`): constraint keywords `type`, `oneOf`, `properties`, `required`, `additionalProperties`, `items`, `enum`, `const`; annotation keywords `description`, `title`, `default`, `examples`. Any other keyword is a violation. `type` is a single string from `object/array/string/number/integer/boolean/null`. `type` and `oneOf` are mutually exclusive; the other constraint keywords need one of them and are invalid beside `oneOf`. `properties`, `required`, `additionalProperties` only on `object`; `items` only on `array`; `enum` / `const` only on scalars, type-correct, `enum` non-empty, `const` a member of `enum` when both exist. `required` names must be declared in `properties`. `additionalProperties` must be boolean. Annotations must be lossless JSON; `description` and `title` strings. Cycles are violations. `assertSupportedJsonSchema` collects every violation and throws one `JsonSchemaError` whose message is `unsupported JSON schema: <v1>; <v2>…`. `assertObjectJsonSchema` adds `schema.type must be "object" (structured output is object-rooted)`.

Value validation (`validateJsonSchemaValue(schema, value, path = 'value')`, `json-schema.ts:487-656`) returns violation strings in walk order. The parameter validator passes path `''`, which prints as `arguments` at the root and as bare property paths below it. Message templates: `"<path>" must be an object`, `missing required property "<path.key>"`, `"<path.key>" is not a declared property (additionalProperties: false)`, `"<path>" must be an array`, `"<path>" must be a string`, `"<path>" must be a number`, `"<path>" must be a finite JSON number`, `"<path>" must be an integer`, `"<path>" must be a boolean`, `"<path>" must be null`, `"<path>" must be one of <JSON array>`, `"<path>" must be <JSON const>`, `"<path>" must match exactly one oneOf branch (matched <n>)`, `"<path>" must be a lossless JSON value`, `"<path>" must be a lossless JSON object`, `"<path>" must be a dense lossless JSON array`. Array item paths are `<path>[<i>]`. A property present with value `undefined` counts as missing. Required-property violations come first, then property violations in schema order, then undeclared-key violations.

### UI presentation vocabulary (`tools/src/presentation.ts`), catalog depth

`ToolCallKind`: `read | edit | delete | move | search | execute | fetch | other`. `FileLocation {path, line?}`. `FileDiff {path, oldText: string | null, newText}`. `ReadFileLine {number, text}`.

`ToolCallView`: `{card: 'generic', title, kind?, rawInput?, content?, locations?}`, `{card: 'terminal', title, description?, cwd?}`, `{card: 'diff', title, diffs, locations?}`.

`ToolResultView`: `{card: 'generic', title?, content?}`, `{card: 'terminal', title?, output?, exitCode?, signal?}`, `{card: 'diff', title?, diffs}`, `{card: 'search', shape: 'matches', title?, files: {path, matches: {lineNumber, line}[]}[], truncated, total}`, `{card: 'search', shape: 'paths', title?, paths, truncated, total}`, `{card: 'read', title?, path, offset, lines, totalLines, lang?, content?}`, `{card: 'web', kind: 'search', title?, sources: {url, title?, snippet?, publishedAt?}[], answer?, truncated}`, `{card: 'web', kind: 'fetch', title?, url, statusCode, truncated}`.

## Algorithms and invariants

### Lossless JSON (`packages/util/values/src/index.ts:66-168`)

`snapshotJsonValue(v)` validates and deep-copies in one iterative pass; it returns `undefined` when the value is not lossless JSON. Accepted: `null`, booleans, strings, finite numbers other than `-0`, dense arrays with the intrinsic array prototype and no extra own keys, objects with prototype `Object.prototype` or `null` whose own keys are all enumerable strings. Rejected: `undefined` anywhere (including as an object property value), BigInt, functions, symbols, `NaN`, infinities, `-0`, sparse arrays, class instances, `Map`/`Set`/`Date`, cycles. A shared (non-cyclic) child is copied at each occurrence. Each property is read exactly once. Object key order is preserved, and `__proto__` is copied as an ordinary key. `isJsonValue` is the same walk without copying. `deepFreeze` freezes every reachable enumerable child except `AbortSignal` instances.

Every boundary in this area uses it: event `data`, surface metadata, seed events, headers, tool arguments, tool body values, renderer and projector output, final tool results.

### Append, single event (`session/src/index.ts:858-871`, `972-992`)

1. `publicationEntry()`: a store-owned unentered session throws `session "<id>" cannot append outside a SessionStore`; an unannounced one throws `… cannot append before session/created completes`; an append made while another append of the same session is publishing throws `session append cannot reenter while another append is being published`.
2. Snapshot `data` (`session event "<type>" carries non-JSON-serializable data`) and the surface metadata object (`… carries non-JSON-serializable surface metadata`). Only `surfaceOp` and `sourceEventSeqs` are read from `opts`.
3. Call `publicationEntry()` again, because reading the payload may have run code that changed membership.
4. Build `{type, seq: log.length, time: Date.now(), data, …surface}`, deep-freeze it, run `validateSessionEventData`.
5. `surfaceManager.validateNext(event)` plans the surface transition without mutating state. Any failure throws and the log is unchanged.
6. Set `entry.appending`, resolve the `session/event` listener snapshot (may throw; still nothing committed), push to the log, invalidate the cached full snapshot, invoke the listeners with containment, clear `appending`, run a deferred detach.

The return value is the frozen logged event, not the caller's input.

`validateSessionEventData` (`surface.ts:166-220`) rules: on surface events, type `developer/message` and message role `developer` must occur together; `tool-addition` / `tool-removal` blocks require role `developer`; in a developer message each such block needs a non-empty `toolName`, a `tool-addition` must not carry an own key `tool`, and `headerSeq` must be a valid seq exactly when at least one addition exists and must be absent otherwise. On `request/header`: the canonical-header rules above. On `tool/result`: `data.error` is allowed only when `message.isError === true`.

### Append, array form (`index.ts:879-917`)

An empty array returns `[]` after the membership check. Otherwise snapshot every member first (error subject `session batch member <i> ("<type>")`), recheck membership, assign consecutive seqs from the current length (a payload getter that appended in the meantime shifts them), build and validate every event, then `surfaceManager.prepareBatch(events)` validates all members against an isolated copy of the fold in which earlier members are visible to later ones (a member may replace an earlier member, and a developer message may reference a header earlier in the same batch). Then resolve every member's listener snapshot, push all events, apply the surface transitions, and only then publish each member in order with `currentBatchPublication` set. Any failure before the push leaves the log and surface unchanged.

### Seed construction and markers (`index.ts:660-733`)

For each seed event at index `i`: in snapshot mode copy it through the lossless pass (`seed event at index <i> is not losslessly JSON-serializable`); check the envelope (allowed keys, types); run `validateSessionEventData`; for `request/header`, the five message types and `assistant/attempt` run the current-shape checks; require `seq === i` (`seed must be contiguous from 0`); run the surface transition (`invalid seed event at index <i>: <reason>`); push (frozen in snapshot mode).

Current-shape checks on seeds (`index.ts:250-386`): `request/header` needs non-empty `config.provider` and `config.model`, a non-empty string `reasoningEffort` if present, `adapterDefaults` with keys only from `{reasoningEffort, maxTokens}`, values `true`, each backed by a defined config field, `reason` in the four values, and `startsSeries` either absent or `true`. `assistant/message` and `assistant/attempt` need non-negative safe-integer `turn` and `step` and an array `stream` (the stream content is not inspected). A message needs a non-empty string `id`, the role that matches its event type, a `source` with non-empty `kind`, and an array `content`; `system/message` needs source kind `system-prompt`; `assistant/message` needs source kind `model` with non-empty `provider` and `model`; `tool/result` needs source kind `tool`, non-empty `callId`, and `toolCallId === source.callId`. Live appends skip these shape checks (the TypeScript types are trusted in process) but run everything else.

After the seed: `firstLiveSeq = log.length`. Header rules: `isSeeded` requires an explicit seed and an explicit `inheritedEventCount`; a non-seeded header requires count `0`; the count must not exceed the log length. Let `markedSeed` be true when `log[inheritedEventCount]` is `session/end-seed` with `inherited: true`. In snapshot mode a seeded session must either have `inheritedEventCount === log.length` or be `markedSeed`. No later event may be another inherited marker. `firstLifecycleSeq` is `inheritedEventCount` for a fresh seeded child (snapshot mode) and `firstLiveSeq` otherwise.

Marker appended by the constructor: a fresh seeded child that is not `markedSeed` appends `session/end-seed {inherited: true}`. Any other construction with a seed (replay, restore, even an empty array) appends `session/end-seed {}` unless the log already ends in a `session/end-seed` of either form. A session with no seed appends nothing. These constructor appends are not published.

### Surface fold (`session/src/surface.ts`)

State: `nodes` (ordered seqs), `replaceGeneration`, `contentGeneration`, `projectedMessages` (seq → message), and the set of projection definitions used. For each event in seq order (`planSurfaceEvent`, `:507-553`):

1. Require `event.seq` to equal the expected position.
2. Validate event-local metadata (`surfaceOpOf`, `validateSurfaceMetadata`): a known non-surface type must not carry `surfaceOp` or `sourceEventSeqs`; a surface type must carry `surfaceOp`; a replace op must be the exact three-key object with both endpoints earlier than the event; `sourceEventSeqs` if present must be a non-empty array of unique valid seqs, all earlier than the event, and absent on `assistant/message`.
3. For `developer/message` with `headerSeq`: the referenced event must be an earlier `request/header`; each `tool-addition` name must match exactly one tool in that header, with a string `description` and an object `parameters`; `deferLoading`, if present there, must be `true`.
4. If a projection definition is registered for the event type, call `projection.project(event, {nodes, events, baseSeq, messages})` and plan `project`. Else if the type is in `MESSAGE_PROJECTION_EVENT_TYPES`, throw `session event "<type>" requires a message projection; load its owning plugin or supply its projection definition`.
5. No `surfaceOp`: no change. `'append'`: push the seq to `nodes`.
6. Replace: find `startSeq` and `endSeq` in `nodes` (`surface replace: start seq <n> not found in surface`, `… end seq …`, `start … is after end …`). The shadowed nodes are the inclusive range. `sourceEventSeqs` must include every shadowed seq. A replacing `tool/result` must shadow exactly one node, that node must be a `tool/result`, and the two `data` values must be deep-equal after setting `message.content` to `null` on both (so only content may change; id, call id, `isError`, source, turn, step, `error` and `meta` must match). If the range starts at node 0 and node 0 is a `system/message`, the replacing event must be a `system/message` over exactly that one node. Apply: splice the range out and put the new seq in its place; increment both generations.
7. `project` plan: merge the returned messages into `projectedMessages`, record the definition, increment `contentGeneration`.

`foldSurface(events, projections)` runs this over a whole log and returns `{nodes, replacements: [{seq, start, end, shadowedSeqs}], projectedMessages}`. `SurfaceManager` runs it incrementally over the live log array (or a loaded window with a non-zero `baseSeq`); `validateNext` keeps the validated plan so the committed event is not planned twice, and every read first checks that all used projection definitions are still registered (`session message projection "<type>" was removed or replaced; restore the session with its owning plugin`).

### Derived history

`deriveEventMessage(event, projectedMessages?)` (`surface.ts:120-152`): if `projectedMessages` has an entry for `event.seq`, return it. Otherwise by type: `user/message` → `event.data`; `system/message`, `developer/message`, `assistant/message` → `event.data.message`, or `null` when its `content` is empty; `tool/result` → `event.data.message`; anything else → `null`.

`Session.deriveMessages()` (`index.ts:1079-1100`):

```
if surface.contentGeneration != cachedGeneration:
    derived = []; derivedNodes = 0; cachedGeneration = surface.contentGeneration
for seq in surface.nodes[derivedNodes:]:
    m = deriveEventMessage(log[seq], projectedMessages)
    if m != null: append m to derived
derivedNodes = len(surface.nodes)
return copy of derived
```

Consequences an implementer must keep: pure tail growth costs only the new nodes; any replacement or message projection rebuilds; the returned array is new each call; the message objects are the logged frozen objects themselves (identity is shared with the log) except where a projection supplied a derived copy; the order is surface order, so a replacement takes the position of the range it shadowed; projections never change node membership or message ids.

What each event family contributes to a model request (assembled by the loop at `agent.ts:662-750`):

- `messages` = `deriveMessages()`: system prompt nodes, developer tool-change messages, user messages (prompts, injected context, runtime-context snapshots), assistant messages (non-empty), tool results.
- Request config and `tools` = the header just logged, equal to `requestHeader()` after the append. `foldRequestHeader` takes the latest `request/header` and canonicalizes it (`canonicalHeader`: keep `adapterDefaults` only if a marker is `true`, keep `tools` only if non-empty).
- `toolHistory` = `toolHistory()`.
- `request/context` is not part of the request. `requestContext()` returns the latest record.
- `assistant/attempt`, `tool/call`, boundaries, `model/selection`, inbox splices, PTC dispatch events and plugin records contribute nothing to the request.

`headerEquals(a, b)`: `callConfigEquals` on config (provider, model, reasoningEffort, temperature, maxTokens, `stop` element-wise with `undefined` distinct from a list), equal `adapterDefaults` markers, same number of tools, and `JSON.stringify` equality of each tool pairwise in order. This comparison is sensitive to key order inside tool schemas.

`ToolHistoryProjection` (`session/src/tool-history.ts`). On `request/header`: remember the tool list under the event seq; if this is the first header, or `reason === 'series'`, or `startsSeries`, or any tool name already declared in the current series now has a different `JSON.stringify` definition, start a new series (`baseline = this seq`, `declared = tools`, `history = {tools, updates: []}`, `available = names`); always set `active = tools`. On `developer/message`: resolve each `tool-addition` through the tool list of its `headerSeq` (`tool history: missing definition for <name>`), add them to `declared`, update `available` for additions and removals in block order, append `{messageId: message.id, additions}` to `history.updates`. `snapshot()`: if the names in `active` and `available` differ as sets, return `{tools: active, updates: []}` (covers logs written before update records existed); else return `history`. All snapshots are frozen and unaffected by later events.

### System prompt, header and context admission (loop side, summarized)

Per request attempt the loop: (1) renders the prompt once per step with `renderPrompt(assembly)`; (2) asks `SystemPromptProjection.project(rendered, {inHistory, startsSeries})` (`agent-loop/src/runtime-context.ts:99-114`) for commits and appends each as `system/message`: with no system node yet, append one (even when empty, reserving node 0); otherwise let `latest` be the last non-empty system node (or the head); if the route is not `in-history`, or the rendering is empty, or a new series starts and `latest.text` differs, replace every non-empty later system node with empty content and then replace the head if its text differs (each replacement is `{op: 'replace', startSeq: s, endSeq: s}` with `sourceEventSeqs: [s]`); else if `latest.text` equals the rendering do nothing; else append a new system node; (3) on the first attempt appends the step's `user/message` events, and appends a runtime-context snapshot when it changed; (4) logs `request/header` with reason `initial` (no earlier header in the log) or `resume` (first header of this loop instance) plus `startsSeries: true` when applicable, or `change` when the canonical header differs from the fold, or `series` when unchanged but a series starts; (5) when a header was logged and tool names differ from the previous fold, appends a `developer/message` with `tool-addition` blocks then `tool-removal` blocks, source `{kind: 'tool-registry'}`, and `headerSeq` only if there are additions; (6) appends `request/context` when provider, model, `contextWindow` or `systemPromptUpdate` differs from the previous record; (7) derives the request. For the header, a series starts when a pre-step listener declares it (first attempt only) or `surface.contentGeneration` changed since the last request. For the system-prompt decision in (2) there is a third trigger: the assembled tools differ from the folded header on a route that declares no `toolUpdate` mode. The `inHistory` input is the prepared call's `systemPromptUpdate === 'in-history'`, not the last `request/context` record.

### Store lifecycle state machine

`prepared` (attachments = `null`) → `enter` → entry with `announcement = 'pending'` → `announce` → `'dispatching'` → `'complete'` or `'failed'` → detach → removed, attachments = `null`. Detach during `'dispatching'` or while `appending` sets `detachRequested` and runs when the dispatch unwinds. Detach removes the entry only if the store still maps the id to that exact entry.

### Fork (`index.ts:1483-1535`, `fork.ts`)

1. If `childSessionId` names a live session → `SESSION_ALREADY_EXISTS` (checked before the boundary).
2. Resolve the source: an id must be live (`SESSION_NOT_FOUND`); an object must be the store's live instance for its id (`SESSION_NOT_FOUND` / `SESSION_NOT_LIVE`).
3. Boundary: explicit, or the last event's seq; an empty source with no boundary forks an empty child. It must be a non-negative safe integer, less than the event count, and `events[boundary].seq === boundary` (`INVALID_BOUNDARY`).
4. `buildForkSeed(events, boundary)`: the events `0..boundary` (same objects), then `session/end-seed {inherited: true}` at seq `boundary + 1` with `time` copied from the boundary event, then `openTurnClosers(prefix-with-marker, {kind: 'forked'})`.
5. `create(childSessionId, {seed, inheritedEventCount: boundary + 1 (or 0), meta: {cwd: source cwd if any, isSeeded: true}})`. No `parentSession`, `origin`, `delegationDepth` or `agentPreset` is copied. The constructor deep-copies and freezes the seed.

### Tail repair (`repair.ts:53-198`)

`openTurnClosers(events, cause)` scans once: `turn/start` opens a turn and clears the open step; `turn/end` closes both; `step/start` / `step/end` open and close a step. If no turn is open at the end, return `[]`. Otherwise return, with seqs continuing the log and `time` equal to the last event's time: one synthetic error `tool/result` per pending call, then `step/end {turn, step}` if a step is open, then `turn/end {turn, reason: {kind: cause.kind}}`.

`ToolCallRecovery.observe(event)`: `turn/start`, `turn/end`, `step/end` clear pending calls; `assistant/message` adds each `tool-call` block id with its turn and step (insertion order is transcript order); `tool/call` records its seq on the matching pending entry; a `tool/result` with `surfaceOp === 'append'` whose turn and step match removes the entry. `results()` builds the synthetic results without changing state. The loop uses one instance per step and appends its results before `step/end` when the step fails (`agent.ts:369-395`). Closed steps are never repaired, even if a result is missing.

### Scope (`scope/src/index.ts`, `scope/src/store.ts`)

- `createScope(ctx, key, {parent?})`: bind the parent link if given, mount a no-op child plugin under `ctx`, extend that fiber's context with the private tag `kScope → key`. `rawDispose` is the fiber's own disposer; `dispose()` awaits the fiber's teardown to quiescence and is shared by racing callers. The scoped context is usable synchronously.
- `scopeOf(ctx)`: the nearest inherited tag. A context has one tag; nesting lives in the key-level parent relation.
- `bindScopeParent(key, parent)`: once per key (`dsh-scope: scope key is already bound to a parent; …`); rejects a cycle (`dsh-scope: scope parent link would form a cycle`); returns the only handle that may `rebind`. `scopeChainOf(key)` is nearest-first.
- `scopeTarget(base, key)`: a carrier object whose Cordis filter is: the base's own filter must pass; an untagged listener context passes; a tagged one passes iff its tag is `key` or an ancestor of `key`. With `key === undefined` only untagged listeners pass. Listeners registered `{global: true}` bypass the filter (Cordis). The carrier becomes the listeners' `this`; the subject travels in the arguments.
- `NamedEntries.insert(name, value)`: duplicate throws the layer's error; returns an idempotent undo for that exact entry. `AnonymousEntries.append(value)`: every append is a separate registration. Both iterate in insertion order and iterate live; when a table empties it swaps to a fresh map so iterators from the previous generation do not see later insertions.
- `ScopedLayers(createLayer, onChange)`: one eager global layer, lazily created exact-scope layers. `peek(scope)` reads one exact layer without creating it. `chainLayers(scope)` returns existing layers farthest ancestor first, exact scope last. `merge(scope, pick)` copies the global named entries then overlays each chain layer, so the nearest scope wins a name while the first insertion position of that name is kept. `effect(ctx, action, {label, notify = true})` runs inside `ctx.effect` as a generator: pick or create the layer for `scopeOf(ctx)`, run `action(layer)` to get an undo (on throw, drop a layer that was created empty), yield a disposer that runs the undo, deletes the scoped layer if the whole layer is empty, and calls `onChange`; then call `onChange`. A throwing `onChange` therefore rolls the registration back. The returned value is the exact Cordis effect disposer.

### System prompt assembly, refresh and rendering

`assemble(context)` (`system-prompt/src/index.ts:621-696`):

1. `scopeLayers = chainLayers(context.scope)`; `suppressed` = any suppressor in the global layer or the chain.
2. Variables: evaluate every global provider, then each chain layer's providers farthest first, so the nearest value wins.
3. Sections and contexts: `merge` by name (scoped shadows global before any text provider runs).
4. Tool providers: global providers then chain providers, each called once with `context`; each schema is copied as `{name, description, parameters: deep copy, deferLoading?}`; `knownNames` accumulates `result.knownNames ?? schema names`.
5. Sort sections by `order` ascending, ties by UTF-16 code-unit comparison of `name`. More than one section with `complete: true` throws `multiple complete prompt sections are active: "<a>", "<b>"`. Resolve each section's text.
6. `orderTools` (`:233-247`): a provider returning a tool named `<unlisted-tools>` throws. Without `toolOrder`, sort by name (code-unit order, stable, so same-named tools keep collection order). With `toolOrder`: any listed name not in `knownNames` throws `toolOrder lists unregistered tool(s) "<x>"…; known tools: <sorted list or (none)>`; unlisted tools sort by name and are inserted at the rest marker; listed names that are known but not visible are simply absent.
7. Contexts: drop non-`required` ones when suppressed, stable-sort by `order` only, resolve text.
8. Run the `system-prompt/assemble` waterfall with `{sections, contexts, variables}`; the default returns it unchanged.
9. Return `{…transformed, tools}`; if a complete section exists, `sections` becomes `[that section as resolved before the waterfall]`; if suppressed, `contexts` is filtered to names of `required` registered contexts (so waterfall additions are dropped).

`refreshContext(assembly, context)` (`:589-609`): for each context in the accepted assembly, in order: if a registered provider with that name exists, re-resolve it, else keep the accepted value (a waterfall addition); when suppressed, keep only those whose provider is `required`. Then insert every `required` registered context that was missing, before the first entry whose registered order is greater, else at the end.

`renderPrompt(assembly)`: for each section, use the text as is when `interpolate === false`, else interpolate; drop empty strings; join with `\n\n`. `renderContextSections` does the same per context and returns `{name, text}` for non-empty ones.

Interpolation (`:347-384`): scan for `{{`. If the text at that position matches `{{<no braces>}}`, the name must match `/^[a-z][a-z0-9_]*$/` (`malformed prompt variable reference "{{<name>}}" in <kind> "<owner>" …`), must be an own key of `variables` (`unknown prompt variable "{{<name>}}" in <kind> "<owner>"; registered variables: <list or (none)>`), and must have a defined value (`prompt variable "{{<name>}}" has no value for this assembly (<kind> "<owner>")`). If it does not match but a `}}` occurs anywhere later, throw `malformed prompt variable reference at "<16 chars>…" …`; if no `}}` follows, the `{{` is literal. Substituted values are not rescanned.

### Tool registry view, restriction and admission (`tools/src/index.ts:199-297`)

View for a scope: `inherited` = global tools, overlaid in order by every chain layer except the scope's own (nearest ancestor wins a name). Each inherited name enters `knownNames` and `restrictableNames`; it is visible only if every layer on the chain (including the scope's own) admits it, where a layer admits a name when each of its restrictions has `allow` containing it (if `allow` exists) and `deny` not containing it. Then the scope's own registrations are added unconditionally and shadow inherited names. Restrictions are evaluated live against the current registry on every view. The global view (`scope` undefined) is just the global layer.

`resolve({agent, modelSelection, signal})`: throw if aborted; take the view once; for each visible tool in view order evaluate `when` sequentially (absent means enabled); a throw becomes `ToolActivationError` unless the signal aborted meanwhile, in which case the abort reason is thrown; check the signal after each. The returned frozen `ResolvedToolSet.view(scope)` returns an empty map when disposed or when `scope` is not that agent; otherwise it returns each admitted name whose current visible definition and current registration object are still identical to the admitted ones. So removal, same-name replacement and new restrictions take effect for unstarted calls, and nothing can be added after admission.

Executor selection: walk `scopeChainOf(scope)` nearest first and take the first scope that ever had an executor record, else the root record; a record whose executor was disposed throws `ToolExecutorUnavailableError`.

### Guarded execution pipeline (`tools/src/pipeline.ts`)

Stage results are tagged: `dispatch` (run the body), `post-result` (go through `tools/post-execute`), `final-result` (skip it).

`createExecution` (`:117-183`): mint the token; `rootCallId = input.rootCallId ?? callId`; look the tool up (`source.get` or `tools.executable(name, agent, toolSet)`); if found, ask `source.reject(name, nested)` where `nested = parent !== undefined`; capture the definition's `finalizeContent` and `projectContent` now. Snapshot and deep-freeze the arguments. If the snapshot fails (including a throwing getter), the outcome is `final-result` with the error result for `TypeError tool execution arguments must be losslessly JSON-serializable` (or the thrown error) and `arguments: undefined`; this wins over a pre-aborted signal. If the executor rejected: `final-result` aborted-before-dispatch when the signal is already aborted, else the error result of the rejection; the finalizer is kept only in the aborted case. An unknown tool is not an error yet; it proceeds through policy and fails at dispatch.

`prepare` (`:191-234`): caller already cancelled → `final-result` aborted-before-dispatch. Run `tools/pre-execute`. `ask` → `serviceAsk`: no `approval` service (read with `ctx.get('approval')`) or no agent → deny with `APPROVAL_UNAVAILABLE`; else `approval.request({agent, toolName, callId, reason?, displayReason?, signal})` and map `allowed-once` → allow, `rejected` / `cancelled` / `unavailable` → deny with the matching code. Then, in this order: caller cancelled and the approval reported `cancelled` → `post-result` aborted-before-dispatch; decision `cancel` → `post-result` aborted-before-dispatch; decision `allow` → `tools.checkGuards(exec)`; a deny or guard denial → `post-result` `{content: [text "Error: <reason>"], isError: true, error: {message: reason, info?}}`; caller cancelled → `post-result` aborted-before-dispatch; else `dispatch`. A denial that settles after cancellation is therefore kept as a denial. Any throw in this stage → `final-result` error.

`dispatch` (`:302-332`) runs `tools/execute` around `dispatchToolBody` (`:263-293`): fuse the caller's signal with the signal currently on `exec` (which a wrapper may have replaced); if already aborted return aborted-before-dispatch; set `exec.signal` to the fused signal; look the tool up again (`ToolNotFoundError` if gone); mark the body invoked; `await tool.execute(exec.arguments, exec)`; build the success result; if the fused signal aborted meanwhile, replace it with the `ABORTED` result. On a throw: if the signal is aborted and the thrown value has no `HarnessError` identity and is either the signal's reason or an `Error` named `AbortError`, the result keeps the thrown message and gets `{name: 'AbortError', code: 'ABORTED'}`; otherwise the ordinary error result. Finally remove the fuse listeners and restore the wrapper's signal. The body's promise is always awaited; cancellation never abandons it.

After the waterfall: `normalizeDispatchResult` accepts a result that this pipeline produced for this exact token as is; rebuilds a wrapper-authored failure from `{error, content, meta?, additionalContexts?}`; re-validates and re-renders a wrapper-authored success from its `value`. Contexts deferred by the body are prepended to the result's `additionalContexts`. If the caller cancelled and the result is a success, replace it with `ABORTED` (body invoked) or `ABORTED_BEFORE_DISPATCH` (not invoked), keeping the contexts. Return `post-result`. A throwing wrapper → `final-result` error.

`createSuccessResult` (`:545-575`): snapshot the body value (`value is not lossless JSON` / `value snapshot failed: …`), validate against `output.schema` with path `value`, freeze, call `output.render(args, value)` and snapshot it, call `output.presentationMeta` if declared and snapshot it; any failure throws `ToolOutputError` (`output.render failed: …`, `output.render returned non-lossless JSON`, same for `presentationMeta`). Add `concludesTurn: true` if the body called `concludeTurn()`.

`complete` (`:343-371`): `final-result` → `finish`. `post-result` → run the captured `projectContent(exec, result)` once (a non-`undefined` return replaces `content`); run `tools/post-execute`; if the caller cancelled and the post result is a success, replace it with the cancellation result; `finish`. Any throw → `finish(error result)`.

`postExecute` (`:494-533`): `block` → `{content: feedback, isError: true, error: {message, info?}, additionalContexts: only the decision's}` where `message` is the feedback's text blocks joined by `\n` (non-text blocks render as `[<type> content]`) or `tool result blocked by post-execute policy` when empty; contexts deferred by the body are dropped. `accept` with both `content` and `value` keys → `TypeError tools/post-execute accept decision cannot replace both value and content`. `accept` with `value` → rejected on a failed result (`tools/post-execute cannot replace the value of a failed result`), else re-validate and re-render through the tool's output contract (the tool is looked up again). `accept` with `content` → replace content only, keeping `value` and `meta`. Additional contexts are `[…result's, …decision's]`.

`finish` (`:381-396`): materialize the candidate (lossless snapshot and deep-freeze of `{isError, error?, content, meta?, additionalContexts?, concludesTurn?}`, with the already frozen `value` attached); if that fails, materialize the error result of the failure (`tool result must be losslessly JSON-serializable`). Call the captured `finalizeContent(exec, result)` exactly once; a non-`undefined` return replaces `content`; materialize again; if the finalizer or the second materialization throws, the result is the error result of that throw and the finalizer is not called again. Freeze `exec`, emit `tools/result`, return the result.

`executionMode(input)`: resolve the tool as execution would; no tool, no classifier, a throw, or any return other than `true` gives `exclusive`. `defineTool` wraps the classifier so invalid arguments give `false`.

Signal fusion (`:737-764`): if both signals are the same object use it; otherwise a new controller aborted with the reason of whichever source aborts first (wrapper checked first when both are already aborted), with listeners removed on abort or on dispose.

### Batch scheduling (`tools/src/batch.ts`)

`executeToolBatch(input, pipeline, maxParallel)`:

1. An explicit `maxParallelToolCalls` must be a positive integer (`RangeError maxParallelToolCalls must be a positive integer`).
2. Parse each call's arguments: empty string → `{}`; valid JSON → the parsed value; invalid JSON → the raw string (so the tool's validator reports `"arguments" must be an object`).
3. Loop over unscheduled calls: classify the first; `parallel` → the group is all remaining calls; `exclusive` → the group is that one call. Run the group with limit `maxParallelToolCalls ?? maxParallel()` (read per group).
4. Group (`runGroup`, `:117-234`): fill the pool while not aborted, calls remain, and in-flight dispatches are below the limit. Before starting any call after the first in a parallel group, reclassify it; if it is no longer `parallel`, stop filling (it becomes the next barrier). Starting a call: append `tool/call {turn, step, callId, name, arguments: raw text}` (only when `input.log` is set) and remember its seq; `await pipeline.prepare(...)`; a `dispatch` outcome starts `pipeline.dispatch` without awaiting it; other outcomes fill the slot immediately. After each start: commit ready slots, then note an abort. Then repeatedly wait for any in-flight dispatch to settle, commit ready slots, note an abort, and refill.
5. Commit ready (`:139-150`): advance over contiguous settled slots in model order; for each, `await pipeline.complete(exec, slot)`, then append `tool/result {turn, step, message: createToolResultMessage({callId, content, isError}), error?: result.error.info, meta?}` with `{surfaceOp: 'append', sourceEventSeqs: [callSeq]}` (only with `log`), record the result, and collect its `additionalContexts`.
6. Abort: stop starting; started calls drain and commit; every unstarted call of the group, then every later call of the batch, gets a `tool/call` and a synthetic aborted-before-dispatch result in order. The batch resolves normally.
7. Scheduler failure (a throw from classification, `prepare`, `dispatch` or `complete` machinery): stop starting, await all in-flight dispatches, then reject with `ToolBatchExecutionError(cause, partial)` where `partial` is the committed results and contexts. The loop re-queues `partial.additionalContexts`, records recovery results for unanswered calls, and rethrows the cause.
8. `concluded` is true when any committed result has `concludesTurn === true`.

Ordering guarantees: `tools/pre-execute`, guards, `tools/post-execute`, `finalizeContent`, `tools/result`, the `tool/result` append and context collection all happen in model call order, one call at a time. Only `tools/execute` and tool bodies overlap. `tool/call` events are appended in model order at start time and may interleave with earlier calls' `tool/result` events. With limit `1` execution is fully serial. An already aborted signal starts nothing.

### `defineTool` (`tools/src/schema.ts:555-633`)

Compiles `parameters` and `output.schema`, validates `timeoutMs`. The produced `execute` validates arguments with path `''` and throws `ToolArgsError` before calling the user body. `presentCall`, `presentResult` return `undefined` and `isConcurrencySafe` returns `false` when the arguments do not validate (they run on replayed, possibly obsolete arguments and must not throw). `projectContent` and `finalizeContent` pass through. `deferLoading` and `timeoutMs` are copied only when set. A raw `ToolDefinition` registered directly gets no argument validation.

## Tests worth porting

Session (`packages/core/session/tests/`):

- `session.spec.ts` (1825 lines): derivation from the log, seed replay equality, every seed rejection path with its message, single-read-per-property snapshots, freezing, snapshot caching, header validation, store create/enter/announce/detach ordering, observer containment, reentrancy.
- `append.spec.ts`: array append atomicity, member-replaces-earlier-member, publication after full commit, reentrant append containment.
- `surface.spec.ts` (1030 lines): fold and incremental manager equivalence, replacement range rules, source coverage, tool-result rewrite rule, system-head protection, developer message rules, windowed folds with `baseSeq`.
- `canonical-envelopes.spec.ts`: canonical header rules, replace-op key strictness, opaque metadata on unknown ignorable events, located error messages.
- `derived-cache.spec.ts`, `properties.spec.ts` (fast-check): cache equals from-scratch derivation, determinism, non-message events never affect history.
- `fork.spec.ts`: boundaries, error codes, open-tail closing with each recovery text, plugin brackets left untouched, cuts before and after a replacement.
- `repair.spec.ts`: closer ordering, started versus not-started, exact wording per cause, deterministic ids.
- `request-header.spec.ts`, `tool-history.spec.ts`, `developer-header.spec.ts`: canonicalization, equality, incremental folds, series restarts, header binding of additions.
- `message-projections.spec.ts`, `plugin-records.spec.ts`, `store-membership.spec.ts`, `scoped.spec.ts`, `seq-ranges.spec.ts`, `sequence-types.spec.ts`, `json.spec.ts` (the lossless JSON rules; skip the JavaScript-realm cases).

Tools (`packages/core/tools/tests/`): `tools.spec.ts` (3160 lines; the pipeline's full decision table: output contract failures, post-execute replace/block, context ordering, every cancellation interleaving at `:1262-1870`, approval routing at `:879-1022`, registration and disposal), `scoped.spec.ts` (scoped registration, restriction intersection and inheritance, guard ordering, single argument snapshot), `activation.spec.ts` (step admission), `execution-mode.spec.ts`, `json-schema.spec.ts`, `schema.spec.ts`, `properties.spec.ts` (fast-check: conversion and validation are total).

Batch scheduling is pinned from the loop side: `packages/core/agent-loop/tests/tool-calls.spec.ts` (parallel start, barriers, cap and replenishment, model-order commits, abort handling, scheduler failure recovery) and `tool-executors.spec.ts` (executor selection through the scope chain, unload behavior).

System prompt (`packages/core/system-prompt/tests/`): `system-prompt.spec.ts` (ordering, shadowing, complete section, suppression, refresh, every interpolation error message), `scoped.spec.ts`, `tool-order.spec.ts`.

Scope (`packages/core/scope/tests/`): `scope.spec.ts` (tagging, routing, ancestor admission, parent binding, disposal), `store.spec.ts` (entry tables, layer creation and reclamation, effect ordering and rollback).

`packages/core/agent-tool-presentation/tests/agent-tool-presentation.spec.ts`: mode required, per-preset executor, pending PTC runtime keeps the inherited executor.

Fixtures to reuse: `packages/test-support/tool-testkit` (tool definition fixtures), `packages/test-support/agent-loop-testkit`, and the recorded sessions under `snapshots/` (owned by other notes) as end-to-end checks of event sequences.

## Porting notes

Essential product behavior: the event envelope and every payload field; contiguous seqs; the surface fold with its replacement rules; the derivation rules; canonical headers and the three side folds; marker and fork semantics; recovery texts and ids; section and tool ordering; strict interpolation and its messages; the tool view, restriction and admission rules; the pipeline stage order, decision types, cancellation outcomes and all model-visible strings; batch ordering and the concurrency limit; the JSON Schema subset and its violation messages (models read them).

Node/TypeScript machinery that need not be reproduced literally: declaration merging and branded types (use contracts and a runtime registry); `WeakMap` side tables keyed by execution or session (use private struct fields); `deepFreeze` and `structuredClone` (immutable Racket data makes both identity operations, but the lossless-JSON domain check stays); single-read-of-getter and cross-realm prototype checks (JavaScript-specific); the generator form of effects (the kernel contract supports generators and `ctx-effect`); `Symbol` tokens (any fresh `eq?`-unique value).

Suggested Racket decomposition:

- `dsh-values`: `json-value?`, `snapshot-json` (validate, and normalize to immutable data), `json-equal?`.
- `dsh-scope`: scope key = any `eq?`-comparable value; `create-scope` on `ctx-plugin` + `context-extend`; `scope-target` returns a filter procedure for `ctx-dispatch #:filter` (plus the carrier key); weak `eq?` hash for the parent relation; `scoped-layers`, `named-entries`, `anonymous-entries` as small mutable structs with insertion-ordered storage.
- `dsh-session`: `types` (event struct or validated hash, header, brands as contracts), `surface` (pure fold over an immutable state struct, plus an incremental manager), `request-header`, `tool-history`, `repair`, `fork`, `seq-ranges`, `store` (service). A `define-session-event` form can register type name, surface eligibility and projection requirement, and a test can compare the registry to the 63-name list.
- `dsh-system-prompt`: service plus pure `render-prompt` / `interpolate`.
- `dsh-tools`: `contracts` (structs for definition, execution, result, decisions), `json-schema`, `schema` (DSL compiler; a macro can give compile-time checking of author forms), `registry` (service), `pipeline`, `batch`, `presentation` (data definitions only).
- `dsh-tool-executor-native` and `dsh-agent-tool-presentation`: thin plugins.

Hard parts and risks:

- JSON object key order. JavaScript objects keep insertion order and three behaviors depend on it: tool schemas are compared with `JSON.stringify` (`headerEquals`, tool-history redeclaration), schemas are sent to the model in author order (prompt-cache stability), and recorded snapshots are compared textually. Racket `hash` does not keep order. The port needs an order-preserving JSON object representation everywhere event data, schemas and results flow.
- Numbers. JavaScript has one number type. The port must accept integers and finite non-negative-zero floats, treat `1` and `1.0` as the same value for equality, print integer-valued numbers without a fraction, and reject values beyond the safe-integer range where seqs and times are concerned.
- String ordering. Section and tool names sort by UTF-16 code units; Racket `string<?` sorts by code point. They differ for characters above U+FFFF versus U+E000–U+FFFF. Implement the code-unit comparison.
- Listener snapshots. Appends and `tools/result` need "resolve the filtered listener list first, commit, then call each listener with its own error containment". Plain kernel `emit` stops at the first exception. The port needs `ctx-listeners` (or an equivalent) that applies the scope filter, honors `#:global?`, and runs the `internal/dispatch` hook so a validation veto still happens before the commit.
- Cancellation. `AbortSignal` semantics used here: an aborted flag, a reason value, one-shot listeners, fusion of two signals, and identity comparison of a thrown value with the reason. A small cancel-token struct covers it. Tool bodies must be awaited to quiescence; do not kill their thread on abort.
- The rolling pool. `Promise.race` over in-flight dispatches with sequential `prepare` and sequential commits maps to worker threads reporting on one channel; keep `prepare` and `complete` on the scheduler thread to preserve order.
- Message identity sharing. The derived history returns the logged message values themselves, and the loop tracks them by identity. With immutable Racket values this is natural, but projections must return new values while keeping ids.
- Surface batch validation must be atomic and must let later members see earlier ones.
- Live appends are not shape-checked in TypeScript because types guarantee the shape. Racket has no such guarantee; apply the seed-level message and header checks as contracts at append, without rejecting anything the seed path accepts.
- `cwd` absoluteness follows `node:path` for the host platform; use the platform's notion of a complete path.
- Stale docs: follow the code for fork open-tail handling and `presentationMeta` on nested calls (see the top of this note).

Nothing in this area needs Node at runtime. The only Node import is `isAbsolute`. Tool bodies, presenters, renderers and message projections are callbacks supplied by other packages; whether those can be ported or must be wrapped is decided in their own notes.

## Feature checklist

- session: event envelope with exactly `type, seq, time, data, surfaceOp?, sourceEventSeqs?, ignorable?`
- session: `SESSION_FORMAT_VERSION = 4` stamped in every new header
- session: header validation (version, id match, createdAt, absolute cwd, isSeeded, origin, delegationDepth, agentPreset, no `seedLength`)
- session: synthesized minimal header for a bare session
- session: all 14 core event types with their payload fields
- session: agent and PTC event types accepted as known log-only events
- session: 63-name `KNOWN_SESSION_EVENT_TYPES` set
- session: lossless JSON snapshot of data and surface metadata at append
- session: append returns the frozen logged event with `seq = log length` and `time = now`
- session: surface types require `surfaceOp`; log-only types reject surface metadata
- session: `assistant/message` rejects `sourceEventSeqs`
- session: `sourceEventSeqs` non-empty, unique, earlier than the event
- session: replace op is exactly `{op, startSeq, endSeq}` with earlier endpoints
- session: replacement range lookup, order check and splice
- session: replacement must cite every shadowed node
- session: `tool/result` replacement changes content only and shadows one result
- session: system head (node 0) rewritable only by a `system/message` over exactly that node
- session: developer message role, tool-change block and `headerSeq` rules
- session: tool additions resolve against the referenced earlier `request/header`
- session: canonical `request/header` (no `system`, no empty `tools`, no empty `adapterDefaults`)
- session: `tool/result.error` only with `message.isError === true`
- session: array append validates all members, commits atomically, publishes in order
- session: `currentBatchPublication` during batch publication
- session: reentrant append during publication is rejected
- session: observer failures after commit are contained and logged
- session: dispatch-resolution failure rejects the append with no log change
- session: `deriveEventMessage` rules per type, empty system/developer/assistant content gives no message
- session: `deriveMessages` cache with tail growth and rebuild on `contentGeneration` change
- session: derived messages are the logged immutable values
- session: `replaceGeneration` and `contentGeneration` counters
- session: message projection registration, required definitions, removal blocks reads
- session: `foldSurface` returns nodes, replacements and projected messages
- session: windowed surface manager with non-zero base seq
- session: `requestHeader()` incremental fold, canonical and frozen
- session: `headerEquals` field-wise with ordered tool comparison
- session: `requestContext()` latest record
- session: `toolHistory()` series, additions through `headerSeq`, removals, fallback snapshot
- session: seed validation (envelope keys, contiguity, shape checks, surface transitions) with located errors
- session: snapshot-mode seed is copied and frozen; restore mode adopts without copying
- session: `session/end-seed {}` appended after any non-fork seed not already ending in a marker
- session: `session/end-seed {inherited: true}` at the inherited cut of a fresh fork child
- session: `inheritedEventCount`, `firstLiveSeq`, `firstLifecycleSeq`, `isOwnSeq`, `ownEvents`
- session: `eventAt` and cached / ranged `snapshotEvents`
- session: plugin record grammar, `appendPluginRecord` writes `ignorable: true`, `pluginRecordOf`
- session: unknown ignorable events retained with opaque metadata and no surface effect
- session: `adoptSessionEvent` and `snapshotSessionEvent`
- session: store `create`, `prepare`, `enter`, `announce` with veto and rollback
- session: writes disabled before announcement, after failed announcement, and after detach
- session: deferred detach during creation dispatch or append publication
- session: `session/created`, `session/event`, `session/disposed` scope-filtered by the entering context
- session: `session/disposed` paired with every started announcement
- session: `flush` awaits all listeners, rethrows the first failure, returns participation
- session: minted ids `session-<n>` and duplicate-id rejection
- session: `fork` boundary rules and four error codes
- session: fork seed with inherited marker, forked tool results, `step/end`, `turn/end {forked}`
- session: fork copies `cwd` and sets `isSeeded`, nothing else
- session: `openTurnClosers` / `interruptedTurnClosers` ordering and timestamps
- session: `ToolCallRecovery` pending tracking and deterministic synthetic results
- session: four recovery texts and two recovery error identities
- session: `encodeSeqRanges` / `decodeSeqRanges`
- session: `SessionPreparation` idempotent release
- session: typert `session` lookup registration when `typert` is present
- system-prompt: scoped `section`, `context`, `variable`, `tools`, `suppressRuntimeContext` registrations as effects
- system-prompt: duplicate-name errors per layer and finite-order checks
- system-prompt: scoped entries shadow global and ancestor entries by name
- system-prompt: `system-prompt/change` on every registration and disposal, with rollback on a throwing listener
- system-prompt: config `includeHarnessIdentity`, `includeRuntimeContext`, `personaPrefix`, `personaSuffix`, `toolOrder`
- system-prompt: identity section text and order `-1000`
- system-prompt: section order table and context order table
- system-prompt: sections sorted by order then code-unit name
- system-prompt: single `complete` section restored after the waterfall; multiple is an error
- system-prompt: tool schemas collected from global and chain providers with copied parameters
- system-prompt: tool order lexicographic by default; `toolOrder` with rest marker; unknown-name error; reserved name error
- system-prompt: `system-prompt/assemble` scope-filtered waterfall over sections, contexts, variables
- system-prompt: runtime-context suppression keeps only `required` contexts
- system-prompt: `refreshContext` re-reads providers, keeps waterfall additions, restores required contexts in order
- system-prompt: `renderPrompt` drops empty sections and joins with blank lines
- system-prompt: strict `{{name}}` interpolation with four distinct errors and literal lone `{{`
- system-prompt: `interpolate: false` keeps literal text
- system-prompt: `renderContextSections`, `joinContextSections`, `renderContextSnapshot`
- tools: `register` validation (output declaration, output schema, timeout, reserved `run_code`)
- tools: scoped registration, shadowing, duplicate errors, disposal
- tools: `tools/change` on register, restrict and their disposal
- tools: `restrict` allow/deny masks, intersection, ancestor inheritance, own registrations exempt, error cases
- tools: `get`, `definitions`, `schemas` per scope and per admitted set
- tools: `schemas` projects only name, description, parameters, deferLoading
- tools: `executable` excludes conditional tools without an admitted set
- tools: `resolve` evaluates `when` once per step, sequentially, with cancellation and `TOOL_ACTIVATION_FAILED`
- tools: `ResolvedToolSet` is agent-specific, closes on dispose, drops replaced or restricted registrations
- tools: `setExecutor` one per scope, nearest scope wins, unloaded selection is unavailable
- tools: executor-owned prompt sections visible only for the selected executor
- tools: tool-schema provider registered with the system prompt, with `knownNames`
- tools: `execute` delegates a raw batch to the selected executor
- tools: `guard` and `checkGuards` order (global, then chain farthest first), monotonic denial
- tools: arguments snapshotted once, frozen, shared across all stages
- tools: execution token and `rootCallId` defaulting
- tools: `tools/pre-execute` allow / deny / cancel / ask
- tools: approval routing with three denial codes and degrade paths
- tools: denial result format `Error: <reason>` with optional identity
- tools: `tools/execute` around-dispatch waterfall with signal replacement and caller-signal fusion
- tools: tool looked up again at dispatch; unknown tool gives `UNKNOWN_TOOL`
- tools: body value snapshot, schema validation, render and presentationMeta with `INVALID_TOOL_OUTPUT`
- tools: wrapper-authored results normalized through the output contract
- tools: `deferContext` contexts prepended; dropped on block
- tools: `concludeTurn` marks success results
- tools: `projectContent` before post-execute
- tools: `tools/post-execute` accept, replace content, replace value, block, add contexts
- tools: `finalizeContent` exactly once on every outcome
- tools: final result is lossless JSON and frozen; failures to materialize become error results
- tools: `tools/result` contained observers after freezing the execution
- tools: cancellation codes `ABORTED` and `ABORTED_BEFORE_DISPATCH` by body-invoked state
- tools: cancellation replaces only successful outcomes; specific failures are kept
- tools: thrown abort reason or `AbortError` after cancellation keeps its message with `ABORTED`
- tools: `HarnessError` name and code preserved on results; other throws carry message only
- tools: `executionMode` fail-closed classification
- tools: batch argument parsing (empty → `{}`, invalid JSON → raw string)
- tools: exclusive barriers and rolling parallel pool with a positive-integer limit
- tools: reclassification of later calls before start
- tools: `tool/call` logged at start; `tool/result` logged in model order citing its call seq
- tools: policy, completion and context collection in model order
- tools: abort drains started calls and synthesizes results for skipped calls
- tools: scheduler failure drains and rejects with partial results
- tools: batch without `log` writes no session events
- tools: `concluded` flag
- tools: schema DSL compilation for parameters (open root, `required` list) and values
- tools: `defineTool` argument validation, soft presenters, safe classifier
- tools: enforced JSON Schema subset with all-violations reporting
- tools: value validation messages and paths
- tools: `assertObjectJsonSchema`
- tools: removed config keys `mode` and `maxParallelSubCalls` rejected
- tools: presentation view data types
- scope: `createScope` tags a context and owns registrations made through it
- scope: `scopeOf` nearest tag
- scope: `scopeTarget` filter (untagged global, tagged for key or ancestors, base filter kept)
- scope: `bindScopeParent` once, cycle check, privileged rebind
- scope: `scopeChainOf` nearest first
- scope: shared quiescent `dispose` and exact `rawDispose`
- scope: `NamedEntries` and `AnonymousEntries` insertion order, live iteration, idempotent undo
- scope: `ScopedLayers` peek, chainLayers, merge, effect with rollback and layer reclamation
- tool-executor-native: plugin registers one native executor in the mounting scope
- tool-executor-native: `describe` returns every visible schema; no prompt sections
- tool-executor-native: `execute` runs the shared batch scheduler with default limit 10
- agent-tool-presentation: required `mode: native | ptc` mounts the matching executor plugin
- agent-tool-presentation: inherited executor stays active until the PTC runtime is available
