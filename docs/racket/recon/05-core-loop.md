# Recon 05: agents and the loop

Pinned commit `e8f7b93a3`. Paths are relative to the repository root. A bare `agent.ts:NNN`, `index.ts:NNN`, `inbox.ts:NNN`, `runtime-context.ts:NNN` or `assistant-stream.ts:NNN` in the loop sections points into `packages/core/agent-loop/src/`; `agent/src/...` points into `packages/core/agent/src/`. "The loop" is `@deepseek-ai/dsh-agent-loop`, "the registry" is `AgentRegistry` in `@deepseek-ai/dsh-agent`, "the driver" is the class `ReactLoopAgent`.

Findings that differ from the task brief or from prose docs, each checked in source:

- `Agent` has no `interrupt` and no `meta` member. The complete member list is `id`, `options`, `session`, `model`, `inbox`, `status`, `ctx`, `cancel`, `whenIdle`, `runMaintenance`, `send`, `followup`, `steer`, `inject`. Session metadata lives on `agent.session.header`.
- `AgentRegistry` has no `dispose(id)` method. An agent leaves the registry through `AgentHandle.dispose()` (factory-made agents), the detach closure returned by `enter()`, or the effect disposer returned by `register()`.
- `packages/core/agent-loop/README.md` says chunk frames are emitted "only after the matching durable assistant-frame settlement" and that a failed settlement is `aborted`. The code emits every `chunk` frame live as the chunk arrives (`assistant-stream.ts:60-71`) and the terminal outcome kinds are `committed` and `abandoned`.
- `docs/subsystems/core.md` says `agent/request-error` "runs after a failed model step closes". In code the waterfall runs inside the open step, before `step/end`, and a retry stays in that step (`agent.ts:549-570`). `docs/agent-lifecycle.md` matches the code.
- `agent/request` is marked `@deprecated` and is listed under "undeclared event strings" in `docs/event-producer-consumer.md`, but the loop still dispatches it once per request attempt and `compaction-basic` listens to it. The port must keep it.
- The JSDoc of `Agent.cancel` says cancellation with no active activity is a no-op. As implemented, `cancel()` without `keepInbox` always clears both pending lists first, also while idle (`agent.ts:192-202`). Only the abort is skipped.
- A rejected first step, an empty first batch, or a failed or cancelled turn stops the driver even when prompts are still queued. They stay in the inbox until the next waking `send` (pinned by `tests/interception.spec.ts:498-535`).
- The loop has no retry counter and no turn budget. Retry policy belongs to `agent/request-error` listeners (`dsh-llm-retry`, compaction); turn bounding belongs to listeners that call `cancel`.
- `SessionStartSource` values `'clear'` and `'compact'` have no emitter. Only `'startup'` and `'resume'` are produced.

Depth: `agent`, `agent-loop` and `agent-default-model` are covered completely. `tool-executor-ptc` is covered at catalog depth; `docs/racket/recon/09-ptc-workflow.md` owns it in depth. Session, system-prompt, tools and scope internals are owned by `04-core-data.md`; the LLM runtime, stream chunk vocabulary and `dsh-llm-retry` by `06-llm.md`. This note states the exact calls the loop makes into them.

## Scope

| Package dir | npm name | Role | Src lines |
|---|---|---|---|
| `packages/core/agent` | `@deepseek-ai/dsh-agent` | `Agent` interface, `ctx.agents` registry, factory slot, process-local initiator scope, every `agent/*` event declaration, `agent/inbox/spliced` and `model/selection` session events, `turnBoundary` and `modelSelection` projection definitions, `AgentModel`, agent-scoped dispatch helpers, consumed-work fold, archive admission | 1790 |
| `packages/core/agent-loop` | `@deepseek-ai/dsh-agent-loop` | `ctx.agentLoop`: the one `AgentFactory`; creation, resume and teardown transactions; config-declared agents; the `ReactLoopAgent` turn and step machine; durable inbox; system-prompt and runtime-context admission; assistant stream framing | 2148 |
| `packages/core/agent-default-model` | `@deepseek-ai/dsh-agent-default-model` | `ctx.agentDefaultModel`: deployment default `{provider, model, reasoningEffort?}` read from volatile config and saved through the profile config editor | 97 |
| `packages/core/tool-executor-ptc` | `@deepseek-ai/dsh-tool-executor-ptc` | PTC tool executor: reserved `run_code` transport, generated SDK prompt text, nested-call scheduler and dispatch events, `createRunCodeTool`, host reset (catalog depth here) | 2476 |

Docs read: `docs/agent-lifecycle.md`, `docs/subsystems/core.md`, `docs/event-producer-consumer.md` (the `agent/*` and `agent-loop/*` rows), `docs/architecture.md` (Events, Turn flow, Session log), `docs/defensive-patterns/README.md` and `general.md`, the four package READMEs.

Supporting code read because the loop calls it: `packages/core/session/src/{types,repair,request-header,preparation,surface}.ts`, `packages/core/tools/src/{batch,executor,contracts,index}.ts`, `packages/core/scope/src/index.ts`, `packages/core/system-prompt/src/index.ts` (`renderPrompt`, `renderContextSections`, `refreshContext`), `packages/llm/llm/src/{index,call-config,assembler,assistant-stream,message,error,types}.ts`, `packages/session/session-projection/src/index.ts`, `packages/test-support/agent-loop-testkit/src/index.ts`, and the recorded session `snapshots/session/fs-read/session.v4.jsonl`.

## Services

### `ctx.agents`: `AgentRegistry` (`agent/src/index.ts:246`)

Service class, default export, registered under the key `agents`. `static inject = ['sessionProjections']`. No Config. State: `Map<SessionId, AgentEntry>` in insertion order, one factory slot, two `AsyncLocalStorage` instances for the initiator scope, and one projection handle.

Construction (`:259-289`): optionally (`ctx.inject(['typert'], ...)`) registers the typert lookup `agent` (`parameter: 'agent'`, `wire: 'agentId'`, `resource: 'session'`, `hostTypeSymbol: '@deepseek-ai/dsh-agent#Agent'`, `wireTypeSymbol: '@deepseek-ai/dsh-session/types#SessionId'`, `resolve: id => this.get(id)`) and the typert host context `agent` (`resolve: id => this.get(id)?.ctx`); listens to `internal/status` to close the initiator scope when the registry's own fiber or one of its ancestors enters `UNLOADING`; registers the initiator lifecycle effect; installs the archive admission listeners. `[Service.init]` awaits `ctx.sessionProjections.register(turnBoundaryProjectionDefinition)`, so the service is visible only after that projection is registered.

| Member | Semantics |
|---|---|
| `turnBoundaryOf(session) → TurnBoundaryProjection` | Reads the `turnBoundary` projection state of any session, live agent or not. Do not mutate the result. |
| `get(id) → Agent \| undefined` | Live agent by shared agent/session id. |
| `list() → Agent[]` | Fresh array in registration order. |
| `create(options: CreateAgentOptions) → Promise<AgentHandle>` | Requires a factory, else throws `no agent factory registered (load an agent-loop plugin)`. Calls `factory.createAgent(ownerCtx, options)` where `ownerCtx` is the context through which the caller reached `ctx.agents` (Cordis service tracing). The caller's fiber owns the transaction and the live agent. |
| `resume(options: ResumeAgentOptions) → Promise<AgentHandle>` | Same delegation to `factory.resume(ownerCtx, options)`. |
| `setFactory(factory) → disposer` | Effect (`agents.setFactory()`). Throws `an agent factory is already registered` when the slot is taken. A traced service is reduced to its original object before storing. Disposal clears the slot. Returns the exact effect disposer so a composite effect can adopt it as a child. |
| `register(agent) → effect disposer` | For already-constructed agents (custom drivers, tests). Async generator effect `agents.register()`: `yield this.enter(agent)`, then `await this.announce(agent, 'startup')`. Await it before using the agent. |
| `enter(agent) → () => void` | Inserts without announcing. Throws `agent id "<id>" does not match session id "<sid>"` when `agent.id !== agent.session.id`, and `agent "<id>" is already registered` on a duplicate. Builds the entry `{id, agent, carrier: scopeTarget(agent, agent), announced: false, announcing: false, detachRequested: false}`. Returns a single-shot detach closure bound to this exact entry. |
| `announce(agent, source, signal?) → Promise<void>` | Throws `agent "<id>" is not live in this registry` unless `agent` is the exact live entry, and `agent "<id>" was already announced` when announcement began before. Sets `announcing` and `announced` before dispatch, then `await ctx.serial(carrier, 'agent/created', {agent, source, signal?})` (the `signal` key is omitted when undefined). In `finally`: clears `announcing` and runs a deferred detach. A listener failure rejects `announce`. |
| `currentInitiator() → Agent \| undefined` | The agent of the enclosing `withInitiator` boundary on this asynchronous chain, or `undefined`. Throws `agent initiator scope is disposed` after disposal. |
| `requireInitiator() → Agent` | As above; throws `no initiating agent is active` when there is none. |
| `withInitiator(agent, operation) → T` | Runs `operation` with `agent` as initiator and returns its exact value (the same Promise object when it returns one). Throws `agent initiator scope is disposed` when the scope is closing or disposed. |
| `withoutInitiator(operation) → T` | Same, with the initiator hidden (`undefined`). |

Detach semantics (`:493-524`). The closure is idempotent. If called while `announcing` is true it only sets `detachRequested`; `announce` performs the removal after the serial dispatch settles. Removal deletes the map entry only if the map still holds this exact entry, then emits `agent/disposed` only when `announced` is true. An entry rolled back before `announce` emits nothing. Because `announced` is set before dispatch, a creation in which an early listener ran and a later one threw is still paired with `agent/disposed`.

`agent/disposed` dispatch (`:527-539`): resolve the listener list with `ctx.events.dispatch('emit', [carrier, 'agent/disposed', {agent}])`, call each listener, log `agent "<id>": agent/disposed listener threw: <error>` or `... listener rejected: <error>` at `warn`, and continue.

Initiator scope (`:593-676`). State machine `'active' → 'closing' → 'disposed'`. `runWithInitiator` refuses unless `'active'`. Each boundary is a tracked run `{active, parent}`; the counter `activeInitiatorRuns` is incremented on entry and released when the operation throws, returns a non-Promise, or its returned Promise settles (observed through `Promise.prototype.then.call`, so an overridden `then` is not invoked). `closeInitiators()` moves `active → closing`. `disposeInitiators()` (memoized) closes, releases every run on the current boundary chain (so a boundary that itself triggers teardown does not wait for itself), waits until the counter reaches zero, sets `'disposed'`, and disables both storages. The lifecycle effect yields `disposeInitiators` then `closeInitiators`, so on unload "close" runs first and "dispose" second.

Archive admission (`agent/src/archive-admission.ts`). Two listeners on the registry's context: `workspace/session-activity` (waterfall) samples `lookup(sessionId)?.status === 'running'` before `await next()` and returns `[{kind: 'turn'}, ...rest]` when it was running; `workspace/session-stop` (parallel) calls `agent.cancel({kind: 'user'})` when the agent is running (no `keepInbox`, nothing awaited). `SessionActivityKindMap` gains the key `turn: true`.

### `Agent` (interface; `agent/src/types.ts:16`, augmented in `agent/src/runtime-types.ts:190-273`)

| Member | Type | Semantics in the shipped driver |
|---|---|---|
| `id` | `SessionId` (readonly) | Equals `session.id`. |
| `options` | `AgentOptions` (readonly) | The exact object passed at creation (identity preserved, `tests/scope-lifecycle.spec.ts:401`). Read live: `provider`, `model`, `reasoningEffort` are a fallback until the session records a selection or a request; `maxTokens` seeds the first request of this loop instance. |
| `session` | `Session` (readonly) | The live session; its log is the source of truth. |
| `model` | `Model` (readonly) | `AgentModel` instance, see below. |
| `inbox` | `Inbox` (readonly) | `ReactLoopInbox` instance, see below. |
| `status` | `'idle' \| 'running'` (getter) | `'running'` only in phase `running`. Phases `idle` and `maintenance` both read `'idle'`. |
| `ctx` | `Context` (readonly) | The agent-scoped context (`createScope(loopCtx, agent).ctx`). Registrations through it are visible only to this agent and unwind at disposal; after disposal a registration throws (Cordis inactive-effect error). |
| `cancel(cause, options?)` | `void` | See "Cancel" under Algorithms. `cause: AgentCancelCause`; `options.keepInbox?: boolean`. |
| `whenIdle()` | `Promise<void>` | Awaits `activityDone` repeatedly until the reference stops changing, so it also follows a replacement driver started before the observed one retired. Resolves at once with no activity. It does not reject for turn failures or cancellation: the driver contains them. |
| `runMaintenance(task)` | `Promise<T>` | Throws synchronously `agent "<id>" already has active work` unless phase is `idle`. See "Maintenance". |
| `send(message, target, wakeup)` | `void` | Routes one identified `UserMessage` to `'next-turn'` or `'next-step'` and optionally wakes the driver. See "Send and wake". |
| `followup(message)` | `void` | `send(message, 'next-turn', true)`. |
| `steer(message)` | `void` | `send(message, 'next-step', true)`. |
| `inject(message)` | `void` | `send(message, 'next-step', false)`. |

The concrete class also exposes `scope: Scope` (`{ctx, rawDispose, dispose}`) for the factory. Nothing outside the loop package may use it.

Supporting types (`agent/src/runtime-types.ts`):

- `AgentOptions = { provider?: string; model?: string; reasoningEffort?: ReasoningEffortId; maxTokens?: number }`. Merge-extensible interface.
- `AgentCancelCause = {kind: 'user'} | {kind: 'parent'} | {kind: 'hook', reason: string} | {kind: 'disposed'}` (declared in `dsh-session`, re-exported).
- `CancelOptions = { keepInbox?: boolean }`.
- `AgentStatus = 'idle' | 'running'`.
- `InboxTarget = 'next-turn' | 'next-step'`.
- `PreStepDecision = {kind: 'reject'} | {kind: 'enter', messages: UserMessage[], startsRequestSeries?: true}`.
- `RequestErrorAction = {kind: 'retry'} | undefined`.
- `SessionStartSource = 'startup' | 'resume' | 'clear' | 'compact'`.
- `AssembleContext` (from `dsh-system-prompt`) gains `agent?: Agent` and `modelSelection?: Readonly<ModelSelection>`.

### `Model` (`agent.model`, class `AgentModel`, `agent/src/model-selection.ts:98-121`)

Constructed with `(readState: () => ModelSelectionProjectionState, session, options)`. Holds no copy of the choice.

- `current() → Readonly<ModelSelection> | undefined`: `recorded = state.pending ?? state.lastUsed`. If non-null return a shallow copy. Otherwise, if `options.provider` and `options.model` are both truthy, return `{provider, model, reasoningEffort?}` built from the live options (the effort key is omitted when undefined). Otherwise `undefined`.
- `select(selection) → void`: if `sameModelSelection(recorded, selection)` do nothing; otherwise `session.append('model/selection', {provider, model, reasoningEffort?})`. A selection equal only to the options fallback is still recorded, because `recorded` is null then. Equality compares provider, model and effort, with an absent effort as its own value. No availability validation.

### `Inbox` (`agent.inbox`, class `ReactLoopInbox`, `inbox.ts:73-232`)

Constructed with `(readState: () => InboxState, session, dispatch)`. The projection cell is the only state.

| Member | Semantics |
|---|---|
| `nextTurn`, `nextStep` | Live read of the projection lists. |
| `append(target, message)` | `splice(target, length, 0, [message])`. |
| `prepend(target, message)` | `splice(target, 0, 0, [message])`. |
| `replace(messageId, newMessage) → boolean` | Locates the id in `next-turn` first, then `next-step`; `false` when absent; otherwise `splice(target, index, 1, [newMessage])`. |
| `remove(messageId) → boolean` | Same lookup; `splice(target, index, 1, [])`. |
| `clear()` | `splice('next-step', 0, nextStep.length, [])` then `splice('next-turn', 0, nextTurn.length, [])`. An empty list appends nothing. |
| `splice(target, start, deleteCount, inserted) → UserMessage[]` | Normalized mutation with removed messages treated as cancelled. Returns the removed messages. |
| `hasPending` (loop only) | Either list non-empty. |
| `claim(target, turn) → UserMessage[]` (loop only) | Removes all of `next-step`, then when `target === 'next-turn'` the first `next-turn` message, through deletions that are not cancellations; then emits `agent/inbox/claimed {message, turn}` for each, in that order. |

### `AgentHandle`, `AgentFactory`, creation options (`agent/src/index.ts:40-206`)

- `AgentHandle = { agent: Agent; dispose(): Promise<void> }`. `dispose` is the owner's capability; it stops and drains the driver, unwinds the scope, closes the write handle, leaves the agent registry, then the session store.
- `AgentFactory = { createAgent(ownerCtx, options: CreateAgentOptions): Promise<AgentHandle>; resume(ownerCtx, options: ResumeAgentOptions): Promise<AgentHandle> }`.
- `CreateAgentOptions = { sessionId: SessionId; meta?: { cwd?: string; parentSession?: SessionId; isSeeded?: boolean; origin?: 'subagent'; delegationDepth?: number; agentPreset?: string }; inheritedEventCount?: SessionLogOffset; seed?: readonly SessionEvent[]; agentOptions?: AgentOptions; signal?: AbortSignal; setup?: AgentSetup }`.
- `ResumeAgentOptions = { resumeSessionId: SessionId; agentOptions?: AgentOptions; signal?: AbortSignal; setup?: AgentSetup }`.
- `AgentSetup = (agentCtx: Context, agent: Agent) => AgentSetupCommit | Promise<AgentSetupCommit | void> | void`; `AgentSetupCommit = { commit(): void }`. Setup runs after the session entered the store and `session/created` completed, before the agent enters the registry. `commit()` is called synchronously after setup settles and immediately before registry insertion. Setup composes the scoped world; it must not drive the agent. `signal` governs creation only and is detached before the handle is returned.

### `ctx.agentLoop`: `AgentLoop` (`index.ts:290`)

Service class, default export, key `agentLoop`. `static inject = ['agents', 'sessions', 'llm', 'tools', 'systemPrompt', 'sessionProjections']`. Optional services read with `ctx.get`: `sessionPersistence`, `configuredAgentIdentities`. Implements `AgentFactory`.

| Member | Semantics |
|---|---|
| `config: { agents, maxParallelToolCalls: Volatile<number> }` | Validated config after launcher identities are applied. `maxParallelToolCalls.get()` is read before every tool batch. |
| `create(id, options = {}, meta = {}) → Promise<Agent>` | Config and test helper. Prepares a fresh session `sessions.prepare(id, {meta})`, takes write ownership when persistence is mounted, initializes with source `'startup'`, returns the bare agent. The owner is the context through which `agentLoop` was accessed. |
| `createAgent(ownerCtx, options) → Promise<AgentHandle>` | Factory path for `ctx.agents.create`. Prepares the session with `seed`, `meta`, `inheritedEventCount`; source `'startup'`. |
| `resume(ownerCtx, options) → Promise<AgentHandle>` | Throws `cannot resume: session persistence is not configured (load a dsh-session-persistence backend)` without `sessionPersistence`. Source `'resume'`. |

`[Service.init]` order (`index.ts:328-370`): (1) effect `agentLoop.transactions()` whose disposer is `ownership.dispose()`; (2) await registration of `modelSelectionProjectionDefinition`; (3) await registration of `inboxProjectionDefinition`; (4) effect `agentLoop.setFactory()` calling `ctx.agents.setFactory(this)`; (5) `ctx.systemPrompt.variable('provider', c => c.modelSelection?.provider ?? c.agent?.options.provider)` and the same for `'model'`; (6) start configured agents without awaiting them. The factory is published only after both projections exist.

### `ctx.agentDefaultModel`: `AgentDefaultModelConfig` (`packages/core/agent-default-model/src/index.ts:48`)

Service class, default export, key `agentDefaultModel`, no static `inject`. On construction, when `settings` is available, it runs `child.settings.configure({ auto: false }, ownerContext.fiber)` as an effect.

- `currentSelection() → ModelSelection`: reads the three volatile config references at call time and returns a detached `{provider, model, reasoningEffort?}` (effort branded, omitted when undefined).
- `saveSelection(next) → Promise<void>`: no-op when the owning fiber has no Loader entry or `ctx.get('configEditor')` is undefined. Otherwise the new config object is `{provider, model, reasoningEffort?}` (omitting the effort removes it from the profile row) and the write is `editor.edit(entry, () => config)`. Saves are chained in submission order on one promise; a failed save rejects its own caller and does not block later saves.

Readers: `session-controller`, `headless`, `experimental/webhook`, each at agent creation time. The service does not validate catalog membership.

### `ctx.configuredAgentIdentities` (provided value, `index.ts:176-226`)

Not a service class. A launcher may `ctx.provide('configuredAgentIdentities', identities)` before the Loader mounts entries. Type: `Record<string, { id: SessionId; resume: boolean }>` keyed by the configured agent `id`. The loop reads it once in its constructor. The exported constant is `CONFIGURED_AGENT_IDENTITIES_KEY = 'configuredAgentIdentities'`.

### Library exports of `dsh-agent` that are not services

- `agentCarrier(agent) → Scoped<Agent>`: `scopeTarget(agent, agent)`.
- `agentEvents(ctx, agent, carrier?) → { emit, serial, waterfall }`: fused dispatcher. Every call injects `agent` into the payload last, so a caller-supplied `agent` key cannot override it, and uses the carrier as the dispatch receiver. `emit` resolves the listener list itself and contains each listener: log `agent event "<name>" listener threw: <error>` or `... listener rejected: <error>` at `warn`. `serial` and `waterfall` forward to `ctx.serial` and `ctx.waterfall` and propagate failures.
- `emitAgentEvent(ctx, agent, name, payload)`: one contained emit.
- `assembleContextFor(agent, signal?) → AssembleContext`: `{agent, scope: agent, signal?}`.
- `installModelSelection(agentCtx) → disposer`: scoped `agent/pre-step` listener, see Algorithms.
- `foldConsumedWork(events) → { end?: SessionEvent<'turn/end'>; droppedUnrun: boolean }`.
- `AgentModel`, `modelSelectionProjectionDefinition`, and the types.

### PTC executor (catalog)

`PtcExecutor` (`packages/core/tool-executor-ptc/src/index.ts:24`) implements the `ToolExecutor` interface of `dsh-tools` and is installed with `ctx.tools.setExecutor(new PtcExecutor(ctx, config))`. Members: `sections` (prompt sections `tools:ptc-only` at order `PTC_ONLY` and `tools:sdk` at order `TOOLS_SDK`, both `interpolate: false`), `describe(tools)` (one schema, `run_code`; `knownNames: ['run_code']`), `execute(batch)` (the shared `executeToolBatch` with a pipeline that rejects any model-direct name other than `run_code`), `reset(agent)` (clear the agent's retained program environment, then `agent.inject` a notice). `createRunCodeTool(ctx, {name, description, runtime, tools, limits?})` (subpath `/run-code`) builds an unregistered program tool over private bindings. `PtcCalls` serializes program runs and resets per session and aborts runs when the session logs a different `sandbox/mode`.

## Events

All `agent/*` events are dispatched with a scope carrier as receiver: `scopeTarget(agent, agent)`. A listener registered on an unscoped context hears every agent; a listener registered on some `agent.ctx` hears only that agent and agents whose scope has it as an ancestor. Emit-mode agent events are dispatched with per-listener containment (a throw or rejection is logged at `warn` and does not stop other listeners or the loop). Serial and waterfall events propagate failures to the loop. The two serial events use Cordis `serial`: the chain also stops at the first listener that returns a value other than `undefined`, `null` or `false`; their listeners are typed to return nothing.

| Event | Mode | Payload (besides `agent`) | Producer | Consumers at the pinned commit | Guarantees |
|---|---|---|---|---|---|
| `agent/created` | serial | `source: SessionStartSource`, `signal?: AbortSignal` | `AgentRegistry.announce` | `agent-team`, `browser-use-runtime`, `claude-code-mods`, `creation-recommendations`, `cua`, `file-reference-local`, `goal`, `goal-round-driver`, `hooks-claude-code`, `hooks-codex`, `liveshare`, `loader-smoke`, `permission-presets`, `session-controller`, `tool-subagent` | Listeners run in order, each awaited. A throw or rejection fails creation and skips later listeners. Fires after setup and its commit, with the agent already in the registry. Input sent during listeners is queued and released after the last listener. A listener must not await `agent.whenIdle()` or its own owner's disposal. |
| `agent/disposed` | emit (contained) | none | `AgentRegistry.detachEntered` | `action-cards`, `agent-loop`, `claude-code-mods`, `creation-recommendations`, `file-reference-local`, `goal-round-driver`, `server`, `session-controller`, `subagent`, `tool-office`, `tool-subagent-control` | Only for an announced entry. In the loop's teardown it fires after driver quiescence, scope unwind and write-handle close, and before `session/disposed`. `ctx.agents.get(id)` is already `undefined` and `ctx.sessions.get(id)` is still defined inside the listener (`tests/scope-lifecycle.spec.ts:1018`). |
| `agent/status` | emit (contained) | `status: AgentStatus` | driver `setPhase` | `acp`, `compaction-basic`, `goal-round-driver`, `server`, `session-controller` | Emitted synchronously on every `idle ⇄ running` flip, after the phase is committed. `running` is emitted inside the waking `send` call, before `turn/start`. Entering or leaving maintenance emits nothing. One `running` interval may span several turns. |
| `agent/inbox/inserted` | emit (contained) | `message: UserMessage` | `ReactLoopInbox.mutate` | `client-ui-forge`, `goal-round-driver`, `subagent`, `tool-jobs`, `tool-subagent-control` | After the `agent/inbox/spliced` event is committed. One per inserted message, in order, after any `discarded` emits of the same splice. |
| `agent/inbox/claimed` | emit (contained) | `message: UserMessage`, `turn: number` | `ReactLoopInbox.claim` | `acp`, `goal-round-driver`, `subagent`, `tool-jobs`, `user-questions` | After both deletion splices of the claim. Order: next-step messages, then the one next-turn message. A claimed message of a rejected step ends here; it is not discarded and not re-emitted. |
| `agent/inbox/discarded` | emit (contained) | `message: UserMessage` | `ReactLoopInbox.mutate` | `goal-round-driver`, `subagent`, `user-questions` | For each message removed by a public mutation (`remove`, `replace`, `clear`, `splice`), after the commit. Not emitted for claims. |
| `agent/pre-step` | waterfall | `messages: UserMessage[]`, `turn`, `step`, `signal: AbortSignal`, `modelSelection: Readonly<ModelSelection>`; `next: () => Promise<PreStepDecision>`; returns `Promise<PreStepDecision>` | driver `preStep` | `action-cards`, `agent` (`installModelSelection`), `agent-instructions`, `claude-code-mods`, `client-ui-forge`, `compaction-basic`, `goal-round-driver`, `hooks-claude-code`, `hooks-codex`, `liveshare`, `plan-mode`, `repeat-tool-reminder`, `session-checkpoint-policy`, `session-controller`, `session-reference`, `subagent`, `time-context`, `tmux-context`, `tool-skill` | Once per proposed step, after claim, tool-set resolution and prompt assembly, before `step/start`. The innermost `next` returns `{kind: 'enter', messages: [...claimed, runtimeContextCandidate?]}`. The returned decision is authoritative. Not repeated for retries. A throw fails the turn. |
| `agent/request` (deprecated) | waterfall | `turn`, `step`, `signal`; `next: () => Promise<LlmCallConfig>`; returns `Promise<LlmCallConfig>` | driver `prepareRequest` | `compaction-basic` | Once per request attempt, after `step/start`, before `prepareCall` and before any system or user commit. The innermost `next` returns the frozen seed config. The result must keep provider, model and reasoning effort (absent included) or the step fails. |
| `agent/request-error` | waterfall | `turn`, `step`, `provider: string`, `failure: LlmFailure`, `retryPolicy: ResolvedRetryPolicy \| undefined`, `signal`; `next: () => Promise<RequestErrorAction>`; returns `Promise<RequestErrorAction>` | driver `step` | `compaction-basic`, `compaction-image-offload`, `llm-retry` | Only for a stream that ended with a terminal `finish` of kind `error` or `aborted`. Runs after `assistant/attempt` is committed, inside the open step. Default `undefined` is terminal. `{kind: 'retry'}` repeats the attempt in the same step. Cancellation during the waterfall wins over a retry. Thrown stream failures do not enter this waterfall. |
| `agent/assistant-stream` | emit (contained) | `frame: AssistantStreamFrame` | `AssistantStreamAttempt` | `headless`, `session-controller` | Per attempt: one `start`, zero or more `chunk` with dense indexes from 0, exactly one `end`. `revision` is monotone per driver instance across all frames, starting at 1. A `committed` end follows the durable append whose `seq` it names. |
| `agent/turn-stopping` | serial | `turn`, `signal`; returns `void \| Promise<void>` | driver `turn` | `hooks-claude-code`, `hooks-codex`, `workspace-changes` | When a step left a turn ending and `inbox.nextStep` is empty. Listeners run in order, each awaited. Afterwards the loop re-reads `inbox.nextStep`: non-empty continues the turn, empty closes it. A throw ends the turn with `error`. |
| `agent/error` | emit (contained) | `turn`, `step`, `error: unknown` | driver `throwError` | `acp`, `deepseek-account`, `goal-round-driver`, `headless`, `server`, `session-controller`, `session-telemetry`, `subagent` | For every non-cancellation turn failure, emitted before `turn/end` is appended. Also for a failed `turn/start` or `turn/end` append. Not emitted for cancellation. `turn` and `step` are the phase counters at the time (`step` is 0 before the first step). |
| `agent-loop/config-start-failed` | emit (contained) | `sessionId: SessionId`, `error: unknown` (no `agent`, no scope carrier) | `AgentLoop.reportConfiguredStartupFailure` | none in tree | Only while the loop is active. Preceded by a `warn` log. |

Events the area consumes:

| Event | Listener | Purpose |
|---|---|---|
| `session/event` (agent-scoped ctx) | `RuntimeContextProjection` (`runtime-context.ts:145`) | Track the retained runtime-context snapshot and its removal by a replacement. |
| `session/event` (agent-scoped ctx, per step) | `ToolCallRecovery` observer (`agent.ts:370`) | Track unanswered tool calls of the open step. |
| `agent/disposed`, `session/disposed` | `waitForDrainingConfiguredIdentity` (`index.ts:445-446`) | Wait for a same-id lifecycle to leave both registries before a configured restore. |
| `internal/status` | `AgentRegistry` | Close the initiator scope when an owning fiber starts unloading. |
| `workspace/session-activity`, `workspace/session-stop` | `AgentRegistry` | Archive admission. |
| `agent/pre-step` (prepend) | `installModelSelection` | Model-switch notice. |
| `session/event` (global), PTC | `PtcCalls` | Abort program runs on a `sandbox/mode` change. |

Events dispatched indirectly through services the loop calls: `system-prompt/assemble` (inside `ctx.systemPrompt.assemble`), `llm/stream` (inside the prepared call), `tools/pre-execute`, `tools/execute`, `tools/post-execute`, `tools/result` (inside the executor), and `tools/ptc-dispatch-log` (PTC, waterfall, receiver `Scoped<ToolsService>`).

Durable session events declared in this area (`SessionEventMap` merges):

| Type | Data | Surface | Writer |
|---|---|---|---|
| `agent/inbox/spliced` | `{ target: InboxTarget; start: number; removedCount?: number; inserted: UserMessage[]; outcome?: 'canceled' }` | log-only | `ReactLoopInbox` |
| `model/selection` | `{ provider: string; model: string; reasoningEffort?: ReasoningEffortId }` | log-only | `AgentModel.select` |
| `tool/ptc-dispatch-start` | `{ rootCallId, parentCallId, subCallId, name, arguments }` | log-only | PTC bridge |
| `tool/ptc-dispatch` | the start fields plus `{ isError: boolean; content: ContentBlock[]; meta?: JsonValue; error?: { name, code, reason? } }` | log-only | PTC bridge |

Session events the loop itself appends (types owned by `dsh-session`): `turn/start`, `turn/end`, `step/start`, `step/end`, `system/message`, `user/message`, `developer/message`, `request/header`, `request/context`, `assistant/message`, `assistant/attempt`, and recovery `tool/result`. Ordinary `tool/call` and `tool/result` are appended by the executor's batch settlement (`packages/core/tools/src/batch.ts:243-266`).

## Tools

`dsh-agent`, `dsh-agent-loop` and `dsh-agent-default-model` register no model-facing tool.

`run_code` (owner `dsh-tool-executor-ptc`; full specification in `09-ptc-workflow.md`, section Tools). Summary for the parity table:

- Name `run_code` (`RUN_CODE_NAME`, `packages/core/tools/src/contracts.ts:13`). Reserved transport, not a registered capability; allow and deny lists cannot remove it. Under PTC it is the only schema the model receives.
- Parameters (property order): `code: string` (required), `description: string` (required), `timeoutMs: number` (only when the runtime has a timeout), `sandbox_permissions: string` with enum `["workspace-write", "danger-full-access"]` and `justification: string` (both only when the runtime can confine).
- Result: joined program text output and images in order, then a detail block (rendered `result`, sandbox notes); `(run_code completed with no output)` when empty.
- Errors: `CODE_RUN_FAILED` (program failure, call allowance exhausted), `ABORTED` (caller cancellation), `SANDBOX_ESCALATION_INVALID_ARGUMENT`, `UNKNOWN_TOOL` for any other model-direct name with the message ``unknown tool "<name>": only `run_code` is callable directly — call `<name>` from inside a `run_code` program instead``, `CODE_RESET_FAILED` (host reset).
- Root `run_code` calls are exclusive in the batch scheduler. Nested calls go through the same guarded pipeline with their own approvals.
- Host reset notice injected into the agent: `Program environment reset; retained variables cleared. Completed tool effects remain.` with source `{kind: 'ptc-mode'}`.
- Prompt section text `tools:ptc-only`: `` `run_code` is the only tool you can call directly — a tool call naming any other tool fails. Reach every tool the SDK declares below from inside the program.``

## Configuration

### `@deepseek-ai/dsh-agent`

Service class `AgentRegistry` (default export). `inject: ['sessionProjections']` (required), `typert` optional through `ctx.inject`. No Config schema. Base bundle row: `id: agent`, no config.

### `@deepseek-ai/dsh-agent-loop`

Service class `AgentLoop` (default export). `inject: ['agents', 'sessions', 'llm', 'tools', 'systemPrompt', 'sessionProjections']`. Optional: `sessionPersistence`, `configuredAgentIdentities`. Also exports `DEFAULT_MAX_PARALLEL_TOOL_CALLS = 10` and `CONFIGURED_AGENT_IDENTITIES_KEY`.

| Field | Schema | Default | Meaning |
|---|---|---|---|
| `maxParallelToolCalls` | number, integer step, `min 1`, volatile | `10` | Maximum parallel-safe tool calls in flight per step. `1` is serial. Volatile: a config edit changes the value read by the next batch without remounting the loop. `0` and `1.5` are rejected at load and on live update. Replacing the config without the key restores `10`. |
| `agents` | array of objects | `[]` | Agents created or resumed at plugin start. Not volatile. |
| `agents[].id` | string, required | none | Config label used in logs and as the fresh id prefix. |
| `agents[].sessionId` | string, `min 1` | absent | Exact identity. First use creates it; a remount with persistence resumes it. |
| `agents[].resumeSessionId` | string | absent | Resume this persisted session. The empty string counts as absent. |
| `agents[].provider` | string | absent | Initial provider route. |
| `agents[].model` | string | absent | Initial model id. |
| `agents[].reasoningEffort` | string, `min 1` | absent | Initial explicit reasoning effort. |
| `agents[].maxTokens` | number, integer step, `min 1`, `max Number.MAX_SAFE_INTEGER` | absent | Output-token cap for each request. |
| `agents[].cwd` | string | absent | Workspace directory written to a fresh session header. |

Load-time validation (`index.ts:272-287`), thrown from the constructor: `agent "<id>": sessionId and resumeSessionId are mutually exclusive` (when `sessionId` is set and `resumeSessionId` is non-empty), and `agents "<first>" and "<id>" use duplicate exact session identity "<x>"`. Launcher identities are applied first (`applyLauncherIdentities`): for every configured agent whose `id` has an entry, both identity keys are removed and replaced by `resumeSessionId: identity.id` when `identity.resume`, else `sessionId: identity.id`.

Shipped rows: base bundle and `sdk-minimal` both mount `id: agent-loop` with `config: { agents: [] }`. Product entry points create agents programmatically.

### `@deepseek-ai/dsh-agent-default-model`

Service class `AgentDefaultModelConfig` (default export). No static `inject`; optional `settings` and `configEditor`.

| Field | Schema | Default | Meaning |
|---|---|---|---|
| `provider` | string, required, volatile | none | Provider route for fresh agents. |
| `model` | string, required, volatile | none | Model id for fresh agents. |
| `reasoningEffort` | string, volatile | absent | Explicit effort; absent means adapter default. |

Base bundle row: `id: agent-default-model`, `config: { provider: deepseek-official, model: deepseek-flash }`.

### `@deepseek-ai/dsh-tool-executor-ptc`

Function plugin: `name = 'ptc-tool-executor'`, `inject = ['tools', 'systemPrompt', 'ptcRuntime']`, `apply(ctx, config)`. No default export.

| Field | Schema | Default | Meaning |
|---|---|---|---|
| `maxSubCallsPerMinute` | natural, `min 1` | `1024` | Nested tool-call attempts allowed per minute of the program's resolved timeout, failed calls included. |
| `maxParallelSubCalls` | natural, `min 1` | `10` | Maximum overlapping concurrency-safe subcalls. `1` is serial. |

Base bundle row: `id: tool-executor-ptc`, `disabled: true` (the native executor row `id: tool-executor-native` is enabled).

## Formats

### Durable event payloads written by this area

Key order below is the insertion order the code produces; it is the order in persisted JSONL and in recorded snapshots.

- `agent/inbox/spliced`: `{"target", "start", "removedCount"?, "inserted", "outcome"?}`. `removedCount` is omitted when 0. `inserted` is always present (possibly `[]`). `outcome` is `"canceled"` exactly when a public mutation removed at least one message; claims never carry it. `start` is the normalized index.
- `model/selection`: `{"provider", "model", "reasoningEffort"?}`.
- `turn/start`: `{"turn"}`. `turn/end`: `{"turn", "reason"}`.
- `step/start`, `step/end`: `{"turn", "step"}`.
- `system/message`: `{"turn", "step", "message"}`; intent `append` or `{op: 'replace', startSeq, endSeq}` with `sourceEventSeqs: [seq]` (single-node replacement).
- `user/message`: the `UserMessage` itself, intent `append`.
- `request/header`: `{"header": {"config", "adapterDefaults"?, "tools"?}, "reason", "startsSeries"?}`. `reason` is `'initial' | 'resume' | 'change' | 'series'`. `startsSeries: true` appears only with the first three reasons.
- `request/context`: `{"provider", "model", "contextWindow"?, "systemPromptUpdate"?}`.
- `developer/message`: `{"turn", "step", "message", "headerSeq"?}`, intent `append`. Message source `{kind: 'tool-registry'}`; content is `{type: 'tool-addition', toolName}` blocks followed by `{type: 'tool-removal', toolName}` blocks. `headerSeq` is present exactly when there is at least one addition.
- `assistant/message`: `{"turn", "step", "message", "usage"?, "stream"}`; interrupted form `{"turn", "step", "message", "interrupted": true, "usage"?, "stream"}`. Intent `append`.
- `assistant/attempt`: `{"turn", "step", "stream"}`. Log-only.
- Recovery `tool/result`: `{"turn", "step", "message", "error"}` with intent `append` and `sourceEventSeqs: [callSeq]` only when a `tool/call` was recorded.

`TurnEndReason` values the loop writes: `{kind: 'completed'}`, `{kind: 'max-tokens'}`, `{kind: 'blocked'}`, `{kind: 'aborted', reason: AgentCancelCause}`, `{kind: 'error', error: LlmFailure}`. Resume repair writes `{kind: 'interrupted'}`. Fork seeds carry `{kind: 'forked'}`. The aborted `reason` is a fresh object: `{kind}` for `user`, `parent`, `disposed`, and `{kind: 'hook', reason}` for hooks. The error value is `LlmError.failure` verbatim for an `LlmError`, otherwise `{message: errorChain(error), code}` with `code` `'TOOL_ACTIVATION_FAILED'` for a `ToolActivationError` and `'UNKNOWN'` for everything else.

Messages as created (`packages/llm/llm/src/message.ts`): user `{content, source, role: 'user', id}`; system `{role: 'system', content: [] | [{type: 'text', text}], source: {kind: 'system-prompt'}, id}`; assistant `{role: 'assistant', content, source: {kind: 'model', provider, model, replayState?}, id}`. `id` is a fresh random UUID. All are deep-frozen.

### Projection states

| Key | Owner | `stateVersion` | State | Wire view |
|---|---|---|---|---|
| `turnBoundary` | `AgentRegistry` | 2 | `{ openTurnStartSeq: seq \| null; lastStepStartSeq: seq \| null; lastStepBoundary: { kind: 'start' \| 'end'; seq } \| null; lastTurn: number }`, initial all null and `lastTurn: 0` | none (host-only) |
| `modelSelection` | `AgentLoop` | 3 | `{ lastUsed: ModelSelection \| null; pending: ModelSelection \| null }`, initial both null | `{ lastUsed, next: pending ?? lastUsed }` |
| `inbox` | `AgentLoop` | 1 | `{ 'next-turn': UserMessage[]; 'next-step': UserMessage[] }`, initial both empty | the state itself |

### Live frames

`AssistantStreamFrame`:

- `{ type: 'start', attemptId, revision, turn, step }`
- `{ type: 'chunk', attemptId, revision, index, time, chunk }` where `time` is `Date.now()` in milliseconds and `chunk` is the frozen JSON snapshot of the `StreamChunk`
- `{ type: 'end', attemptId, revision, index, outcome }` where `index` is the number of chunk frames and `outcome` is `{ kind: 'committed', eventType: 'assistant/message' | 'assistant/attempt', seq }` or `{ kind: 'abandoned' }`

`attemptId` is the string `<sessionId>:<n>` with `n` counting attempts of this driver instance from 1.

### Model request object

`{ ...header.config, messages, toolHistory, tools?, sessionId, signal }` (`agent.ts:741-748`): `header.config` spreads `provider`, `model` and present controls (`reasoningEffort`, `temperature`, `maxTokens`, `stop`); `messages = session.deriveMessages()`; `toolHistory = session.toolHistory()`; `tools` only when the header has tools; `sessionId = session.id`; `signal` is the live turn signal. There is no `system` field: the prompt travels as `system` messages in `messages`. The object is shallow-frozen and registered with `markAgentLoopRequest` so `isAgentLoopRequest(request)` is true for this exact object.

### Model-visible literal text owned by the loop and the agent package

- Runtime context, first snapshot: `<system-reminder>\nThe following information describes your current session:\n\n<body>\n</system-reminder>`.
- Runtime context, later snapshots: the intro line is `The following information describes your current session. It replaces earlier versions of this context, including any retained in conversation summaries.`.
- Runtime context, cleared: `<system-reminder>\nCurrent runtime context: none. Earlier runtime-context snapshots no longer apply.\n</system-reminder>`.
- `<body>` is the section texts joined with `\n\n`, with every match of `/<\/system-reminder\s*>/gi` rewritten to `<\` followed by the match without its first character (so `</system-reminder>` becomes `<\/system-reminder>`).
- Runtime-context message source: `{ kind: 'runtime-context', form: 'snapshot', sections: [{name, text}, ...] }`; the recorded section texts are not escaped.
- Model-switch notice: `[model changed: assistant turns above this point were generated by <from>; the session continues with <to>]`, source `{ kind: 'model-selection', form: 'notice', summary: boundContextSummary('<from> → <to>') }` (summary capped at 120 characters with a trailing `…`). A label is `<model>` when both routes share a provider, else `<provider>/<model>`.
- Recovery tool results (`packages/core/session/src/repair.ts:32-41`), cause `interrupted`. Started call: `The tool call was interrupted after it was recorded, but no result was durably recorded. Its outcome is unknown. Decide whether to retry from the tool semantics: retry only if the operation is read-only or idempotent; if it may have side effects, first verify external state or ask the user. Do not retry blindly.` with `error: { name: 'ToolOutcomeUnknownError', code: 'TOOL_OUTCOME_UNKNOWN' }`. Not started: `The tool call was interrupted before the Harness recorded it as started. Retry it if it is still needed.` with `error: { name: 'ToolNotStartedError', code: 'TOOL_NOT_STARTED' }`. Message id `interrupted-tool-result-<callId>-<seq>`, `isError: true`, `source: { kind: 'tool', callId }`.
- Skipped call after cancellation (written by the batch scheduler): content `Error: tool call aborted before dispatch`, `error: { name: 'AbortError', code: 'ABORTED_BEFORE_DISPATCH' }`.

### Identifiers and error strings

- Fresh config-created id: `<id>-session-<randomUUID>`.
- Driver errors: `agent "<id>" already has active work`; `agent "<id>" has no provider/model: set AgentOptions.provider and AgentOptions.model or record a model selection`; `agent "<id>": turn without driver reservation`; `agent "<id>": agent/request proposed "<p>/<m>" after step preparation fixed "<p0>/<m0>"; use agent.model.select() before step preparation`; `agent "<id>": agent/request proposed reasoning effort "<e or 'adapter default'>" after step preparation fixed "<e0 or 'adapter default'>"; use agent.model.select() before step preparation`.
- Aggregate messages: `Step failed and its pending tool results could not be recorded`; `Assistant stream failed and its durable settlement was rejected`.
- Inbox: `message "<id>" is already pending`; fold failure `invalid persisted inbox splice at session seq <seq>` with cause `invalid inbox splice` or the duplicate message.
- Factory: `agent maxTokens must be a positive safe integer` (`TypeError`); `agent "<id>" creation aborted` (wrapping a non-Error abort reason as `cause`); `agent "<id>" setup aborted: owner disposed during setup`; `agent "<id>" lifecycle disposed`; `agent loop is not active`; `agent "<id>" disposal failed` and `agent loop disposal failed` (AggregateError messages when more than one teardown step failed); log line `agent "<configId>": config-driven <restore|resume> of "<sessionId>" failed: <errorChain>`.

### CLI flags and environment variables

None in this area.

## Algorithms and invariants

### A. Phase machine (`agent.ts:53-61, 157-169`)

`Phase` is one of `{kind: 'idle', lastTurn}`, `{kind: 'maintenance', abort, lastTurn, wakeRequested}`, `{kind: 'running', abort, turn, step, wakeRequested}`. `status` is `'running'` only for `running`. `setPhase(next)` assigns the phase and then emits `agent/status` if the derived status changed. `activityDone` is a promise for the current driver or maintenance task, initially resolved. The initial phase is `{kind: 'idle', lastTurn}` where `lastTurn` comes from `ctx.agents.turnBoundaryOf(session).lastTurn`, so turn numbers continue across resume and fork.

### B. Send and wake (`agent.ts:171-178, 235-257`)

```
send(message, target, wakeup):
  wakingAfterAbort = wakeup and phase != idle and phase.abort.signal.aborted     ; captured before the insertion
  inbox.splice(wakingAfterAbort ? 'next-turn' : target, +Infinity, 0, [message]) ; append; may throw, then nothing else happens
  if wakeup: wakeDriver(wakingAfterAbort)

wakeDriver(wakeAfterAbort = false):
  if lifetimeSignal.aborted: return
  if phase != idle:
    reason = cancel cause of phase.abort.signal, if aborted
    if reason.kind != 'disposed' and (phase == maintenance or wakeAfterAbort): phase.wakeRequested = true
    return                                    ; a live driver claims queued work itself
  activityDone = new driver promise
  setPhase({running, abort: new AbortController, turn: phase.lastTurn, step: 0, wakeRequested: false})
  agents.withInitiator(this, () => kick()).then(resolve driver, reject driver)
```

Consequences an implementation must keep:

1. A waking send on an idle agent runs the driver's synchronous prefix inside the `send` call: after `send` returns, the log already holds the insert splice, `turn/start` and the claim splices, and `agent.status` is `'running'` (`tests/loop.spec.ts:1046-1055`). The first suspension point is the await of `ctx.tools.resolve`.
2. A `steer` during a live, non-aborted turn only inserts into `next-step`; the driver claims it at its next step boundary.
3. A `followup` during a live turn only inserts into `next-turn`; the driver starts another turn after the current one closes normally.
4. A waking send after the current activity was cancelled goes to `next-turn` regardless of the requested target and latches `wakeRequested`; it runs when the aborted activity converges to idle. A `disposed` cancel never latches.
5. `inject` never wakes. Injected context on an idle agent waits for the next waking send.
6. A wake sent while idle always opens a turn, even if its message is removed before the claim (for example by a synchronous `agent/status` listener). When the entered batch is then empty the turn closes `completed` without a step; a non-empty batch (pending injected context, or a first runtime-context snapshot) still runs a step.

### C. Cancel (`agent.ts:192-202`)

```
cancel(cause, {keepInbox} = {}):
  try:     if not keepInbox: inbox.clear()
  finally: if phase != idle:
             if not keepInbox: phase.wakeRequested = false
             phase.abort.abort(cause)
```

The abort reason is the caller's cause object itself. The first cause wins because a second `abort` on an aborted controller changes nothing. A failing inbox write still aborts the activity and then propagates to the caller. Each turn has its own controller (`agent.ts:434`), so a cancel never leaks into a later turn. There is no step-only cancel.

`abortedCancelCause(signal)` (`agent.ts:94-109`) reads the reason and copies only `kind` (and `reason` for hooks). The copy is what `turn/end` records; the live object may have gained extra properties (Node's fetch assigns `stack`) that the session would reject or log.

### D. Maintenance (`agent.ts:204-225`)

```
runMaintenance(job):
  require phase == idle
  m = {maintenance, abort: new AbortController, lastTurn, wakeRequested: false}
  setPhase(m)                         ; status stays 'idle', no event
  activityDone = done promise
  run job(m.abort.signal); in finally:
    setPhase({idle, lastTurn: m.lastTurn})
    cause = cancel cause of m.abort.signal
    if cause.kind != 'disposed' and m.wakeRequested and inbox.hasPending: wakeDriver()
    resolve done
```

The job's fulfillment or rejection is returned unchanged. Waking sends during maintenance stay queued and are replayed once. Users: the loop's own initialization, `compaction-basic`, `session-controller` commands, `subagent`.

### E. Driver (`agent.ts:274-287`)

```
kick():
  try:     while await turn(): pass
  catch:   nothing                    ; failures were reported; cancellation is silent
  finally: {turn, wakeRequested} = phase
           setPhase({idle, lastTurn: turn})        ; emits agent/status idle
           if wakeRequested and inbox.hasPending: wakeDriver()
```

`throwError(error)` emits `agent/error {turn, step, error}` (phase counters, or `lastTurn` and 0 outside `running`) and rethrows.

### F. Turn (`agent.ts:333-439`)

```
turn():
  signal = phase.abort.signal; throw signal.reason if aborted        ; no turn/start in that case
  turn = phase.turn + 1
  append turn/start {turn}                 ; on failure: throwError, no turn/end
  phase.turn = turn
  turnEnds = null; target = 'next-turn'
  try:
    loop:
      throw if aborted
      step = phase.step + 1
      decision = await preStep(target, {turn, step})
      if decision is reject: turnEnds = {blocked}; return false
      try:
        if turnEnds and decision.messages is empty: break
        if phase.step == 0 and decision.messages is empty: turnEnds = {completed}; return false
        throw if aborted
        append step/start {turn, step}; phase.step = step
        recovery = new ToolCallRecovery; observe this session's session/event through agent.ctx
        try:
          stepEnd = await step(decision)
          if turnEnds == null or turnEnds.kind != 'max-tokens': turnEnds = stepEnd
        catch error:
          for each event in recovery.results(): append tool/result (append, sourceEventSeqs when present)
              ; if that append fails: throw AggregateError([error, recoveryError], ..., cause error)
          rethrow error
        finally:
          stop observing
          append step/end {turn, step}
      finally:
        decision.toolSet.dispose()
      throw if aborted
      if turnEnds and inbox.nextStep is empty:
        await serial agent/turn-stopping {turn, signal}
        throw if aborted
      if turnEnds and inbox.nextStep is empty: break
      target = 'next-step'
  catch error:
    cause = abortedCancelCause(signal)
    if cause: turnEnds = {aborted, reason: cause}; rethrow           ; no agent/error
    turnEnds = {error, error: structured failure}; throwError(error)  ; agent/error before turn/end
  finally:
    append turn/end {turn, reason: turnEnds}     ; on failure: throwError
  if not inbox.hasPending: return false
  phase.abort = new AbortController; phase.wakeRequested = false; phase.step = 0
  return true
```

Invariants:

1. `turn/start` precedes the claim. Every opened turn gets exactly one `turn/end`, unless the `turn/end` append itself is rejected.
2. Every `step/start` is followed by exactly one `step/end` for the same coordinates, written in a `finally`. A rejected `step/start` append writes no `step/end`.
3. A turn can close with zero steps: `blocked` (rejected first step, or a later step rejected: the turn that already ran steps also ends `blocked`), `completed` (empty first batch), `aborted`, `error`.
4. Cancellation is decided by the signal state at the catch, not by the error type. Any failure observed after the turn signal aborted is recorded as `aborted`.
5. Continuation rule: after a step, the turn continues when the step returned `null` (tool results owe the model a request) or when `inbox.nextStep` is non-empty. `turnEnds` non-null with an empty `next-step` list triggers `agent/turn-stopping`, and the list is read again afterwards.
6. `max-tokens` is sticky for the turn: once set, later step results do not replace it. A side effect follows from the code: after a `max-tokens` step, a later step that returns `null` still leaves `turnEnds` set, so the turn stops unless `next-step` input exists.
7. A tool result with `concludesTurn` makes the step return `{completed}`, but already submitted next-step input (same-step `additionalContexts`, racing steering) still runs another step.
8. Another turn is started by the same driver only after a turn that closed through `break` (`completed` or `max-tokens`) with pending input in either list. `blocked`, the empty first batch, `aborted` and `error` return or throw before that check, so the driver goes idle and queued prompts stay parked.
9. The first claim of a turn takes all next-step input plus exactly one next-turn message. Each queued prompt therefore gets its own turn with strictly increasing numbers (`tests/properties.spec.ts`).
10. The step tool set is disposed after the step's tool batch settled, also on failure and when no step opens.

### G. Pre-step (`agent.ts:289-323`)

```
preStep(target, {turn, step}):
  signal = phase.abort.signal
  claimed = inbox.claim(target, turn)                       ; durable; emits agent/inbox/claimed
  selection = model.current() or throw "has no provider/model"
  toolSet = await ctx.tools.resolve({agent, modelSelection: selection, signal})
  try:
    assembly = await ctx.systemPrompt.assemble({agent, scope: agent, signal, modelSelection: selection, toolSet})
    throw if aborted
    decision = await waterfall agent/pre-step {messages: claimed, turn, step, signal, modelSelection: selection}
                 innermost next: sections = renderContextSections(assembly)
                                 context = runtimeContext.project(sections)
                                 return {enter, messages: context ? [...claimed, context] : claimed}
    throw if aborted
    if decision is reject: toolSet.dispose(); return decision
    return {...decision, assembly, selection, toolSet}
  catch: toolSet.dispose(); rethrow
```

The claim is not undone on rejection, failure or cancellation: claimed messages are gone from the inbox and are not appended as `user/message`. Input inserted after the claim stays pending. The model selection snapshot is taken once here and is reused for the request and every retry of the step; a `model.select()` made later applies to the next step, including a tool continuation in the same turn. The runtime-context candidate is computed inside the innermost `next`, so it reflects state after inner listeners ran.

`installModelSelection` (`agent/src/model-selection.ts:157-174`), registered with `{prepend: true}`: `decision = await next()`; return it unchanged when it is a reject or the signal is aborted; return it unchanged when `decision.messages` is empty and (`step === 1` or the offered `messages` were non-empty), because the loop will not issue a request then; let `previous = agent.session.requestHeader()?.config`; return unchanged when there is no previous header or provider and model both match; otherwise return `{...decision, messages: [...decision.messages, notice]}`. Effort-only changes add nothing. If the step fails before its header is logged, the next step repeats the notice.

### H. Step: the attempt loop (`agent.ts:441-616`)

```
step(decision):
  {turn, step, signal} = phase; throw if aborted
  rendered = renderPrompt(decision.assembly)        ; once per step; a strict-variable failure fails the turn
  firstAttempt = true
  loop:
    {config, preparedCall?} = await prepareRequest(turn, step, decision.selection, signal)     ; section I
    current = ctx.systemPrompt.refreshContext(assembly, {agent, scope: agent, signal, modelSelection: selection})
    context = runtimeContext.project(renderContextSections(current))
    throw if aborted
    ; ---- from here to the end of buildRequest there is no suspension point ----
    startsRequestSeries = firstAttempt and decision.startsRequestSeries == true
    commits = systemPrompt.project(rendered, {
        inHistory:    preparedCall?.systemPromptUpdate == 'in-history',
        startsSeries: startsRequestSeries
                      or requestSurfaceGeneration != session.surface.contentGeneration
                      or (preparedCall?.toolUpdate == undefined and toolsChanged(assembly.tools)) })
    for {message, intent} in commits: append system/message {turn, step, message} with intent
    contextAdmitted = false
    if firstAttempt:
      for m in decision.messages:
        if m.source.kind == 'runtime-context':
          if context and not contextAdmitted: append user/message context; contextAdmitted = true
        else: append user/message m
    if context and not contextAdmitted: append user/message context
    firstAttempt = false
    request = buildRequest(config, preparedCall, assembly.tools, {turn, step}, startsRequestSeries, signal)   ; section L
    live = new AssistantStreamAttempt(session.id, ++attemptCounter, nextRevision, turn, step, emit frame)
    ... streaming and settlement, section M
```

Rules:

1. The user batch is admitted once per step, on the first attempt. Retries do not repeat prompt assembly, `agent/pre-step` or user admission.
2. A message whose source kind is `runtime-context` in the decision is a placeholder: it is replaced in place by the fresh projection, at most once; when the fresh projection is `undefined` the placeholder is dropped. If no placeholder was admitted (a listener replaced the batch, or this is a retry) and a projection exists, it is appended after the batch.
3. `toolsChanged(tools)`: `false` without a logged header; otherwise `!headerEquals(baseline, canonicalHeader({...baseline, tools}))`.
4. Cancellation during `agent/request` or `prepareCall` commits no system prompt and no user message; the step closes empty and the turn ends `aborted`.

### I. Request config and the prepared call (`agent.ts:619-659`)

```
prepareRequest(turn, step, selection, signal):
  persisted = requestHeaderLogged ? requestProposal(session.requestHeader())
                                  : (options.maxTokens == undefined ? {} : {maxTokens: options.maxTokens})
  controls  = persisted without provider, model, reasoningEffort
  seed      = deep-frozen clone of {...controls, ...selection}
  proposed  = await waterfall agent/request {turn, step, signal}, innermost next returns seed
  throw if aborted
  require proposed.provider == selection.provider and proposed.model == selection.model
  require proposed.reasoningEffort == selection.reasoningEffort        ; absent must stay absent
  try:   preparedCall = await ctx.llm.prepareCall(proposed, signal); config = preparedCall.config
  catch LlmError with code 'NO_ADAPTER': config = proposed; no preparedCall
  throw if aborted
```

`requestProposal(header)` returns `header.config` minus `reasoningEffort` when `header.adapterDefaults.reasoningEffort === true` and minus `maxTokens` when `header.adapterDefaults.maxTokens === true`, so adapter defaults are resolved again by the current route while explicit values persist. `requestHeaderLogged` is per driver instance: a resumed instance seeds controls only from `options.maxTokens` until it has logged its own header. Without a prepared call the request goes to `ctx.llm.stream(request)`, which lets an `llm/stream` listener serve an unregistered route; otherwise the terminal adapter lookup fails with `NO_ADAPTER`.

`PreparedLlmCall` fields the loop reads: `config`, `retryPolicy`, `adapterDefaults`, `context?.contextWindow`, `systemPromptUpdate` (`'in-history'` or absent), `toolUpdate` (`'in-history' | 'addition-only'` or absent), `stream(request)` (one-shot; the request's config fields must equal `config`).

### J. System prompt reconciliation (`runtime-context.ts:74-122`)

Input: the rendered prompt (`''` when none) and `{inHistory, startsSeries}`. `nodes` are the surviving `system/message` surface nodes in order, each with `text` (`''` for empty content, the text for a single text block, `undefined` for anything else).

```
project(rendered, {inHistory, startsSeries}):
  if no node: return [append system(rendered)]            ; even when rendered is '', reserving node 0
  head = nodes[0]; latest = last node whose text != '' , else head
  if not inHistory or rendered == '' or (startsSeries and latest.text != rendered):
    updates = for each later node with text != '': replace(node.seq, '')
    if head.text != rendered: updates += replace(head.seq, rendered)
    return updates
  if latest.text == rendered: return []
  return [append system(rendered)]
```

`replace(seq, text)` is a `system/message` with intent `{surfaceOp: {op: 'replace', startSeq: seq, endSeq: seq}, sourceEventSeqs: [seq]}`. A replacement increments `session.surface.contentGeneration`, so the same attempt's `buildRequest` sees a changed generation and marks a series start. A node with non-text or multi-block content has `text: undefined`, which counts as active (it is emptied by consolidation) and never equals the rendering.

### K. Runtime-context projection (`runtime-context.ts:125-181`)

State `retained`: `undefined` (no owned snapshot ever existed), `null` (one existed, none is on the surface), or `{seq, sections}`.

- Restore at construction: scan events newest first; on the first owned `user/message` set `retained ??= null`; the first owned message whose seq is a surface node becomes `retained` and ends the scan. `sections` is `source.sections` when `source.form === 'snapshot'`, else `undefined` (legacy).
- Follow: on an owned `user/message` of this session set `retained = {seq, sections}`; on a replacement surface event whose `sourceEventSeqs` include `retained.seq` set `retained = null`.
- `project(sections)`: return nothing when `retained === undefined` and `sections` is empty; return nothing when `retained.sections` is defined and deep-equals `sections` (ordered names and texts); otherwise build the reminder. The intro is the first-snapshot line exactly when `retained === undefined`. Empty `sections` produce the cleared text. A proposal never changes `retained`; only the committed event does.

Effects: unchanged context emits nothing; a compaction that shadows the retained snapshot causes a fresh reminder (with the supersession wording) on the next admitted request; a legacy snapshot without recorded sections is refreshed once.

### L. Header, context, tool diff and freezing (`agent.ts:662-750`)

```
buildRequest(config, preparedCall, tools, {turn, step}, startsRequestSeries, signal):
  generation = session.surface.contentGeneration
  header = canonicalHeader({config, adapterDefaults: preparedCall?.adapterDefaults, tools: tools if non-empty})
  baseline = session.requestHeader()
  startsSeries = startsRequestSeries or requestSurfaceGeneration != generation
  if not requestHeaderLogged:
    headerSeq = append request/header {header, reason: baseline ? 'resume' : 'initial', startsSeries?: true}
    requestHeaderLogged = true
  else if baseline == undefined or not headerEquals(baseline, header):
    headerSeq = append request/header {header, reason: 'change', startsSeries?: true}
  else if startsSeries:
    append request/header {header, reason: 'series'}              ; headerSeq stays undefined
  if baseline and headerSeq:
    additions = tools whose name is not in baseline.tools; removals = baseline tools whose name is not in tools
    if any: append developer/message {turn, step, message(source tool-registry, [...additions, ...removals]), headerSeq?}
  requestSurfaceGeneration = generation
  ctxNow = {provider, model, contextWindow?, systemPromptUpdate?}
  if session.requestContext() differs in any of the four fields: append request/context ctxNow
  throw if aborted
  deep-freeze header; messages = session.deriveMessages(); deep-freeze each message not yet frozen by this agent; freeze the array
  return markAgentLoopRequest(freeze({...header.config, messages, toolHistory: session.toolHistory(), tools?, sessionId, signal}))
```

`canonicalHeader` keeps `adapterDefaults` only when `reasoningEffort` or `maxTokens` is `true` and keeps `tools` only when non-empty. `headerEquals` compares config field by field (`provider`, `model`, `reasoningEffort`, `temperature`, `maxTokens`, `stop` element-wise), the two adapter-default flags, and tool schemas pairwise in order by `JSON.stringify` equality, so property order inside a schema matters. Tool names are diffed by name only; a same-name schema change produces a `change` header without a `developer/message`. Unchanged steps, retries and later turns of the same series log no header. Resume and a provider or model change alone do not start a series. `requestSurfaceGeneration` starts at the generation observed at attachment, so a replacement during the first resumed pre-step still marks a series.

Invariant (the "theorem" test): every request can be rebuilt byte-equal from the session log alone, from the latest `request/header`, the surface fold and the tool-history fold.

### M. Streaming and settlement (`agent.ts:494-616`, `assistant-stream.ts`)

```
started = false
try:
  stream = preparedCall ? preparedCall.stream(request) : ctx.llm.stream(request)
  throw if aborted
  live.start(); started = true
  for each chunk: throw if aborted; live.push(chunk)       ; a chunk arriving after abort is not recorded
  throw if aborted
catch error:
  if not started: rethrow                                   ; no frame, no durable attempt
  if signal.aborted:
    content = live.interruptedBlocks()
    if content non-empty: settle assistant/message {turn, step, message(content), interrupted: true, usage?, stream}
    else:                 settle assistant/attempt {turn, step, stream}
  else:                   settle assistant/attempt {turn, step, stream}
  ; a failing settlement throws AggregateError([error, settlementError], ..., cause error)
  rethrow error
finish = live.finish                                        ; {kind: 'stop'} when the stream had no finish chunk
if finish.kind is 'error' or 'aborted':
  settle assistant/attempt
  action = await waterfall agent/request-error {turn, step, provider: request.provider, failure: finish.failure,
                                                retryPolicy: preparedCall?.retryPolicy, signal}, default undefined
  throw if aborted
  if action.kind != 'retry': throw LlmError.fromFailure(finish.failure)
  continue the attempt loop
message = createAssistantMessage({content: live.blocks(), source: {provider: request.provider, model: request.model, replayState?}})
settle assistant/message {turn, step, message, usage?, stream}
if finish.kind == 'max-tokens': return {max-tokens}
toolCalls = message.content blocks of type 'tool-call'
if none: return {completed}
... tool dispatch, section N
; any throw after start with the attempt not yet ended: live.abandon(), rethrow
```

`AssistantStreamAttempt`: `start()` emits the `start` frame; `push(chunk)` stamps `Date.now()`, snapshots and freezes the chunk through `AssistantStreamAccumulator.push` (which validates and packs delta runs), feeds the same frozen chunk to `BlockAssembler`, and emits a `chunk` frame; `settle(eventType, append)` runs the synchronous append, on failure emits an `abandoned` end and rethrows, otherwise emits the `committed` end with the returned seq; `abandon()` emits the `abandoned` end.

Rules:

1. Exactly one durable settlement per started attempt on every path except hard process loss and a failed append: `assistant/message` for success and for an interrupted non-empty prefix, `assistant/attempt` otherwise.
2. Exactly one `end` frame per started attempt. No `end` frame when dispatch threw before `start`.
3. Every successful provider call appends an `assistant/message`, also with empty content (derived history skips empty content) and also for `max-tokens`.
4. `interruptedBlocks()` keeps text and reasoning blocks with non-whitespace text, open or closed, in stream order; tool calls are dropped. `blocks()` drops tool calls when the finish is `max-tokens`, and prunes replay state in step.
5. `message.source` carries `replayState` only when the assembler has an aligned envelope. `usage` is the last `usage` chunk.
6. Tool dispatch depends on tool-call blocks in the assembled message, not on the finish kind.
7. Only terminal `finish` failures are offered to `agent/request-error`. A thrown failure (middleware, chunk validation, assembly) is terminal for the turn.
8. A retry builds a new attempt with a new `attemptId`; the failed attempt stays in the log as `assistant/attempt` and the final message embeds only its own stream.

### N. Tool dispatch (`agent.ts:592-610`)

```
max = ctx.agentLoop.config.maxParallelToolCalls.get()
try:
  result = await ctx.tools.execute({calls: toolCalls, signal, agent, log: {turn, step}, maxParallelToolCalls: max, toolSet: decision.toolSet})
  for c in result.additionalContexts: inbox.splice('next-step', inbox.nextStep.length, 0, [c])
  return result.concluded ? {completed} : null
catch ToolBatchExecutionError e:
  for c in e.partial.additionalContexts: inbox.splice('next-step', ...)
  throw e.cause
```

The loop passes the raw `ToolCallBlock` list in model order and never parses arguments. The selected executor owns `tool/call` and `tool/result` logging, ordering, concurrency and abort handling (`packages/core/tools/src/batch.ts`): results are committed in model order; each `tool/result` cites its `tool/call` seq in `sourceEventSeqs`; on abort, started calls drain and commit and every unstarted call receives a `tool/call` plus the `ABORTED_BEFORE_DISPATCH` result. After a batch that returned normally under an aborted signal, the turn loop's next `throw if aborted` ends the turn `aborted`. Deferred contexts are inserted as ordinary next-step messages (emitting `agent/inbox/inserted`), so they enter the next step after all tool results. A context accepted while the turn is being cancelled stays parked in the inbox unless the cancel cleared it before the splice.

### O. Failed-step recovery (`agent.ts:369-395`, `packages/core/session/src/repair.ts:105-198`)

`ToolCallRecovery.observe(event)`: `turn/start`, `turn/end`, `step/end` clear the pending map; `assistant/message` adds each tool-call block id with its turn and step; `tool/call` records its seq on the pending entry; an appended `tool/result` for the same call id, turn and step removes the entry. `results()` yields, in assistant order, one error result per pending call: `TOOL_OUTCOME_UNKNOWN` when a `tool/call` seq was recorded (citing it), else `TOOL_NOT_STARTED`. The loop appends them before `step/end`, keeps the original failure as the turn's failure, and does not retry anything. The observer is registered on the agent's scoped context and filters on session identity, so child agents and other sessions do not pollute it.

### P. Exact event sequence of a simple one-tool turn

Fresh session, native executor, route without `systemPromptUpdate`, one prompt, the model calls one tool and then answers. Durable events in log order (cross-checked against `snapshots/session/fs-read/session.v4.jsonl`), with live events at their positions:

| # | Kind | Event |
|---|---|---|
| 1 | durable | `agent/inbox/spliced {target: 'next-turn', start: 0, inserted: [prompt]}` |
| 2 | live | `agent/inbox/inserted {message}` |
| 3 | live | `agent/status {status: 'running'}` |
| 4 | durable | `turn/start {turn: 1}` |
| 5 | durable | `agent/inbox/spliced {target: 'next-turn', start: 0, removedCount: 1, inserted: []}` |
| 6 | live | `agent/inbox/claimed {message, turn: 1}` (`send` returns after this) |
| 7 | live | tool-set resolution, `system-prompt/assemble`, `agent/pre-step {messages: [prompt], turn: 1, step: 1, ...}` |
| 8 | durable | `step/start {turn: 1, step: 1}` |
| 9 | live | `agent/request`, then `ctx.llm.prepareCall` |
| 10 | durable | `system/message {turn: 1, step: 1, message}` (append; surface node 0, written even for an empty prompt) |
| 11 | durable | `user/message` (the prompt, append) |
| 12 | durable | `user/message` (runtime-context snapshot, append; only when context sections exist) |
| 13 | durable | `request/header {header: {config, adapterDefaults?, tools?}, reason: 'initial'}` |
| 14 | durable | `request/context {provider, model, contextWindow?, systemPromptUpdate?}` |
| 15 | live | `agent/assistant-stream` start, chunk frames |
| 16 | durable | `assistant/message {turn: 1, step: 1, message, usage?, stream}` (append) |
| 17 | live | `agent/assistant-stream` end `{kind: 'committed', eventType: 'assistant/message', seq}` |
| 18 | durable | `tool/call {turn: 1, step: 1, callId, name, arguments}` |
| 19 | live | `tools/pre-execute`, `tools/execute`, `tools/post-execute` |
| 20 | durable | `tool/result {turn: 1, step: 1, message, meta?}` (append, `sourceEventSeqs: [seq of 18]`) |
| 21 | durable | `step/end {turn: 1, step: 1}` |
| 22 | live | claim of an empty next-step list (no event), `agent/pre-step {messages: [], turn: 1, step: 2, ...}` |
| 23 | durable | `step/start {turn: 1, step: 2}` |
| 24 | live | `agent/request`, `prepareCall`; no system, user, header or context event because nothing changed |
| 25 | live | `agent/assistant-stream` start, chunk frames |
| 26 | durable | `assistant/message {turn: 1, step: 2, message, usage?, stream}` |
| 27 | live | `agent/assistant-stream` end (committed) |
| 28 | durable | `step/end {turn: 1, step: 2}` |
| 29 | live | `agent/turn-stopping {turn: 1, signal}` |
| 30 | durable | `turn/end {turn: 1, reason: {kind: 'completed'}}` |
| 31 | live | `agent/status {status: 'idle'}` |

Other plugins interleave their own events (in the recording: `permission/preset`, `sandbox/mode`, `approval/policy` before the first splice, and `session/title` after `request/context`).

### Q. Inbox mutation and fold (`inbox.ts:26-64, 186-231`)

`mutate(target, start, deleteCount, inserted, discardRemoved)` uses JavaScript `Array.prototype.splice` coordinate rules: truncate `start`, `NaN → 0`, a negative start counts from the end and clamps at 0, a large start clamps to the length; truncate `deleteCount`, `NaN → 0`, clamp to `[0, length - start]`. A mutation that removes nothing and inserts nothing appends no event and returns `[]`. Before appending, the candidate list plus the other list are checked for duplicate message ids; a duplicate throws and leaves state unchanged. Then: append `agent/inbox/spliced`; emit `agent/inbox/discarded` for each removed message when `discardRemoved`; emit `agent/inbox/inserted` for each message of the committed event's `inserted`; return the removed messages. The projection registry folds the event before `session/event` observers run, so the live lists already reflect the splice inside observers.

The fold validates every splice: `start` a safe integer in `[0, length]`, `removedCount ?? 0` a safe integer `>= 0`, `start + removedCount <= length`, and no duplicate id across both lists; a violation throws `invalid persisted inbox splice at session seq <seq>`. The same fold serves cold readers when no agent exists, and a forked session inherits the parent's pending inbox through its seed.

### R. Model-selection, turn-boundary and consumed-work folds

`modelSelection` (`agent/src/model-selection.ts:72-90`): on `model/selection`, set `pending` to the event data unless equal to the current `pending` (then return the same state reference). On `request/header`, compute `lastUsed = {provider, model, reasoningEffort?}` from `header.config`, omitting the effort when `header.adapterDefaults.reasoningEffort === true`; set `pending = null` when it equals `lastUsed`, else keep it; return the same reference when nothing changed. Other events return the same reference.

`turnBoundary` (`agent/src/projection.ts`): `turn/start` sets `openTurnStartSeq = seq` and `lastTurn = data.turn`; `turn/end` sets `openTurnStartSeq = null`; `step/start` sets `lastStepStartSeq = seq` and `lastStepBoundary = {kind: 'start', seq}`; `step/end` sets `lastStepBoundary = {kind: 'end', seq}`.

`foldConsumedWork(events)` (`agent/src/consumed-work.ts:69-109`), single pass with sets `stepped` and `claimed` and the open turn number: `turn/start` records the open turn; `step/start` adds its turn to `stepped`; an `agent/inbox/spliced` with `removedCount` defined either sets `droppedUnrun ||= inserted.length === 0` when `outcome === 'canceled'`, or adds the open turn to `claimed` when a turn is open; `turn/end` clears the open turn and, when the turn stepped, or claimed and its reason is anything but `completed`, records this event as `end` and resets `droppedUnrun = false`. Result `{end?, droppedUnrun}`. Used by `subagent` to report what a child's work became.

### S. Initialization transaction (`index.ts:464-658`)

Shared by `create`, `createAgent` and resume, given an unpublished `Session`, optional `StoredSession {handle, storedCount}`, options, source, setup and caller signal.

1. Create the lifetime `AbortController`. Forward the caller signal (a non-Error reason is wrapped in `agent "<id>" creation aborted` with the reason as `cause`) and the factory teardown signal into it.
2. Define the memoized `teardown` (section T) and `dispose = teardown, then release the owner effect and the scope effect`. Register `dispose` in the factory's live set.
3. Validate: `assertAgentOptions` (`maxTokens` must be a positive safe integer), `ownerCtx.fiber.assertActive()`, factory active, caller signal not aborted.
4. Read `lastTurn` and build projection readers `modelProjectionHandle.readerFor(session)` and `inboxProjectionHandle.readerFor(session)`.
5. Owner effect `agentLoop.lifecycle(<id>)` on the owner context: construct `ReactLoopAgent(loopCtx, id, agentOptions, session, projections, lastTurn, abort.signal)`. Construction creates the scope with `createScope(loopCtx, agent)`, the `AgentModel`, the inbox, the runtime-context projection (which installs its listener) and the system-prompt projection. If the loop fiber is still active, register effect `agentLoop.scope(<id>)` on the loop context that yields `scope.rawDispose` and then `teardown`. The owner effect yields a disposer that aborts with `agent "<id>" setup aborted: owner disposed during setup`, awaits `teardown`, then releases the scope effect. On a throw in steps 3 to 5: untrack, remove listeners, close the stored handle (close failure ignored), rethrow.
6. Run the rest inside `agent.runMaintenance(...)`, with an `assertLive()` check (throw the abort reason) between every two steps:
   1. `appendUnstoredSuffix(stored, session)`: store events the session holds beyond `storedCount` through the handle.
   2. `detachSession = agent.ctx.sessions.enter(session)`, then `agent.ctx.sessions.announce(session)` (synchronous `session/created`). Entering through the agent's scoped context makes this session's events scope-filtered to the agent.
   3. `setupCommit = await raceAbort(setup?.(agent.ctx, agent), abort.signal, id)`.
   4. `setupCommit?.commit()`.
   5. `detachAgent = loopCtx.agents.enter(agent)`, then `await loopCtx.agents.announce(agent, source, abort.signal)` (serial `agent/created`).
   6. `ready = true`; detach the caller signal; return `{agent, dispose}`.
   On any failure inside: `agent.cancel({kind: 'disposed'}, {keepInbox: true})` so queued input is neither released into a turn nor discarded; rethrow. A `publication` promise is resolved in `finally`; teardown waits for it so creation listeners keep the session and scope alive until they settle.
7. If the maintenance task rejects: `await dispose()` (its failure ignored) and rethrow the original failure.

Because step 6 runs as maintenance, input sent during setup or by `agent/created` listeners is queued, the wake is latched, and the driver starts only after the last creation listener finished and the maintenance phase ended.

`create(id, options, meta)` (`:670-679`): `sessions.prepare(id, {meta})` wrapped in a `SessionPreparation` that is disposed on exit; `createStoredSession` calls `persistence.create(session.header, {inheritedEventCount, signal?})` when persistence is mounted and returns `{handle, storedCount: 0}`. `createAgent` (`:719-747`) does the same with seed, meta and inherited count, races the backend create against the caller signal (a handle that arrives after cancellation is closed), and registers the whole promise with the factory so factory disposal awaits it.

### T. Teardown and shutdown ordering (`index.ts:494-546`, `54-109`)

Per-agent `teardown`, memoized so every racing owner (handle holder, owner fiber unload, loop unload) awaits the same quiescence:

1. Abort the lifetime signal with `agent "<id>" lifecycle disposed`, or `agent loop is not active` when the factory is shutting down. From here `wakeDriver` refuses to start a driver.
2. Remove the caller and factory abort listeners.
3. Await the `publication` promise if initialization is in progress.
4. `machine.cancel({kind: 'disposed'}, {keepInbox: !ready})`: a published agent's pending inbox is durably cancelled; an unpublished one keeps it. A failure here is collected, not thrown yet.
5. `await machine.whenIdle()`: the active turn records `turn/end {aborted, reason: {kind: 'disposed'}}` and the driver exits.
6. `await machine.scope.dispose()`: unwind every agent-scoped registration and quiesce the scope fiber.
7. `await stored?.handle.close()`: drain routed events and release write ownership.
8. `detachAgent()` (emits `agent/disposed`), then `detachSession()` (emits `session/disposed`), then untrack.
9. If one step failed, reject with that failure; if several, with `AggregateError(failures, 'agent "<id>" disposal failed')`.

Factory teardown (`FactoryOwnership.dispose`, run by the effect registered first in `init`): stop accepting, abort the factory signal with `agent loop is not active`, resolve the inactive latch, then `Promise.allSettled` over every live agent's `dispose` and every tracked startup or wrapper promise; one failure is rethrown as itself, several as `AggregateError(failures, 'agent loop disposal failed')`. Projection handles obtained earlier stay readable after their registrations are released, so teardown can still read the inbox and model selection.

Known limit stated by the README: shutting down the root context with an active agent can leave the final `turn/end` in memory but absent from the persisted log. `tests/shutdown-drain.spec.ts` pins that an idle agent's buffered events are persisted by root disposal in both mount orders without an explicit flush.

### U. Resume (`index.ts:764-835`)

1. Build a fused abort signal from the caller signal, an owner-unload signal (effect `agentLoop.resume-load(<id>)` on the owner context) and the factory signal.
2. `handle = await persistence.open(id, 'write', {signal})`, raced against the fused signal; a handle arriving after cancellation is closed. Taking write ownership first excludes a concurrent resume of the same id.
3. `coldRead = await handle.read(0, undefined, {signal})`; throw if aborted.
4. `closers = interruptedTurnClosers(coldRead.events)`: for a log ending inside an open turn, error results for unanswered tool calls, then `step/end` for an open step, then `turn/end {reason: {kind: 'interrupted'}}`, with seqs continuing the log and the last real event's time. If non-empty, `await handle.append(closers)`.
5. `sessions.prepare(id, {seed: [...events, ...closers], meta: structuredClone(handle.header), inheritedEventCount: handle.inheritedEventCount, eventState: coldRead.eventState})`; `stored = {handle, storedCount: events.length + closers.length}`; `appendUnstoredSuffix` stores whatever the session constructor added.
6. Release the owner-unload effect; require the owner fiber and the factory to be active.
7. Run the initialization transaction with source `'resume'`. On failure before it takes over, close the handle.

Resume preserves the pending inbox (it is folded from the log), continues turn numbering, and writes its first request header with reason `'resume'` when the log already has a header (`'initial'` otherwise). A failed setup keeps restored inbox messages and already stored events.

### V. Config-declared agents (`index.ts:339-454`)

For each entry `{id, sessionId, cwd, resumeSessionId, ...options}` with `meta = cwd ? {cwd} : {}`:

- No (or empty) `resumeSessionId`: `configuredId = sessionId ?? '<id>-session-<uuid>'`. Without an explicit `sessionId`, or without `sessionPersistence`, call `create(configuredId, options, meta)`. With both, `restoreOrCreateConfigured`: wait while the id still occupies either registry (listening to `agent/disposed` and `session/disposed`, abandoning the wait when the factory deactivates); resume it with a setup that applies the configured route; on `SessionPersistenceNotFoundError` only, fall back to `create`. Any other failure stays a failure.
- With `resumeSessionId`: effect `agentLoop.resume(<id>)` that waits for `sessionPersistence` through `ctx.inject` and then resumes with the same route-applying setup.

`applyConfiguredRoute(agent, options)`: nothing unless both `provider` and `model` are set; build the selection; when the configured effort is absent and the session's current selection has the same route with an explicit effort, keep that effort; `agent.model.select(selection)`. A programmatic resume does not do this: saved history wins over `agentOptions`.

Every start failure is contained: when the factory is still active, log the warning and emit `agent-loop/config-start-failed`. After teardown began, failures are suppressed. All startup work is tracked so loop disposal awaits it.

### W. Ordering rules from `docs/defensive-patterns` that bind this area

- Dispose must reach quiescence: teardown awaits the driver, the scope and the write handle, and resources stay available until admitted work settles, also when queue clearing fails.
- Contain callback exceptions in the dispatcher: all emit-mode agent notifications and `session/event` observers are contained; an observer cannot change a turn outcome.
- Async state is not synchronous state: `agent/status` and `whenIdle()` describe the whole agent, not one message. Per-message facts are the inbox notifications.
- Timing does not carry correctness: the driver's order is explicit call sequence; the only latch is `wakeRequested`.
- Honor public contracts on both sides: model-request failures reach the loop only as terminal finish chunks; thrown values are middleware or consumer defects.

## Tests worth porting

All paths under `packages/core/agent-loop/tests/` unless a longer path is given. `mock-adapter.ts` is the scripted adapter every spec uses (`textResponse`, `toolCallResponse`, `maxTokensResponse`, `'hang'`, `'hang-slow'`, `{hangAfter}`); port it first.

| File | Behaviors pinned |
|---|---|
| `loop.spec.ts` | Dense live frames and the embedded stream equal to the frames; abandoned settlement; retry attempts; simple turn boundary order; tool round trip; prompt variables `provider` and `model`; empty prompt handling; runtime-context materialization, re-emission after replacement, clearing, legacy refresh; steering between steps; synchronous turn opening on idle steer; `inject` while idle; `agent/turn-stopping` steering; `concludesTurn`; pre-step once per step; `max-tokens` rules; observer containment; reentrant send containment; one turn per queued prompt; HMR disposal; config agents; replay to identical derived history. |
| `cancel.spec.ts` | Cause table (`user`, `parent`, `hook`, `disposed`) recorded without transport-added properties; idle cancel; `keepInbox` variants; wake latching and suppression in the abort-to-idle window; no start after disposal begins; cancel in every window (status listener, pre-step, assembly, request, streaming, stopping, tool); streamed prefix finalization; reasoning-only prefix; dropped half tool call; first cause wins. |
| `interception.spec.ts` | Enter, rewrite, add, reject; frozen input identity; staged inject and steer during pre-step; blocked prompt keeps adjacent queued prompts; throwing listener; `agent/created` with source and injection before the first request; deferred contexts after all tool results; denial as an `isError` result; listener disposal. |
| `request-reconstruction.spec.ts` | Append-extension of requests across steps and turns; series start rules; adapter defaults logged and re-resolved; one adapter registration across resolve, log and dispatch; compaction replace; in-history prompt append versus consolidation; frozen request mutation throws; resume anchor; the byte-equality theorem; `request/context` deduplication. |
| `system-prompt-projection.spec.ts`, `system-prompt-admission.spec.ts` | The reconciliation table of section J on capable and plain routes, across retries, compaction and resume; cancellation during `agent/request` and `prepareCall` commits nothing. |
| `runtime-context.spec.ts` | Restore, supersession wording, deduplication by recorded sections, legacy refresh, tag escaping. |
| `tool-calls.spec.ts`, `tool-order.spec.ts`, `tool-updates.spec.ts`, `tool-executors.spec.ts` | Parallel groups and barriers, ordered commit, caps, abort handling, recovery results per failing phase, canonical tool order in the header, `developer/message` additions and removals, step tool set lifetime, executor selection by scope, raw calls and the resolved limit handed to the executor. |
| `request-error.spec.ts`, `coverage-edges.spec.ts`, `contract-regressions.spec.ts` | Retry action semantics, cancellation beating retry, finish `error` and `aborted` as turn errors, rejected boundary appends, balanced turns under observer failures, disposal and cancel during assembly and pre-step, fork and resume turn numbering. |
| `inbox.spec.ts`, `agent.spec.ts`, `properties.spec.ts` | Splice normalization, duplicate rejection, fold validation, projection updated before observers, exact inbox notifications, status transitions, `whenIdle`, turn-per-message properties. |
| `scope-lifecycle.spec.ts`, `input-lifecycle.spec.ts`, `resource-lifecycle.spec.ts`, `serial-listener-review.spec.ts`, `model.spec.ts` | Creation order (`session/created`, setup, commit, `agent/created`), rollback on every failure point, same-id collisions, owner and loop unload during setup, teardown order (`turn/end`, then `agent/disposed` with the agent unlisted and the session still stored), id reuse after quiescence, queue-clear failure does not skip the drain. |
| `resume.spec.ts`, `config-session-id.spec.ts`, `shutdown-drain.spec.ts` | Stored seed and live turn, interrupted-turn closers, torn tail, abort races around open and read, write-handle release on every failure, launcher identities, exact-id restore or create, contained config failures, root shutdown drain. |
| `settings.spec.ts` | Volatile `maxParallelToolCalls` updates and default restore without remount. |
| `agent-initiator.spec.ts` (both packages) | Initiator identity per driver chain, nesting, clearing, drain and disposal. |
| `packages/core/agent/tests/agent.spec.ts` | Registry enter, announce, detach, deferred detach, stale detach, fused dispatch, factory slot. |
| `packages/core/agent/tests/model-selection.spec.ts` | Selection precedence, fold retirement of a matching pending choice, adapter-defaulted effort, switch notices. |
| `packages/core/agent/tests/consumed-work.spec.ts`, `archive-admission.spec.ts` | The consumed-work truth table; the `turn` activity family and the user-cause stop. |
| `packages/core/agent-default-model/tests/agent-default-model.spec.ts` | Volatile reads, profile persistence, serialized saves. |
| `snapshots/session/fs-read/`, `bash-tool-turn/`, `error-finish/`, `empty-response-retry/`, `dynamic-tool-updates/`, `dynamic-tool-prompt-updates/` | Recorded JSONL logs: golden event order and payload key order for whole turns. |

## Porting notes

Essential product behavior: the `Agent` contract and its delivery semantics; the registry lifecycle with paired creation and disposal notices; the turn and step state machine with its exact durable event order; inbox durability and notifications; model-selection precedence; prompt and runtime-context admission; request header and series logging; stream settlement; failed-step recovery; cancellation causes; creation, resume and teardown ordering; the config schema and row names.

Node and TypeScript machinery that should not be copied: Cordis service tracing (`getTraceable`, `symbols.original`, the plain holder objects that stop re-tracing) used to find the caller's context; the port passes the owner context explicitly (ADR 0003). `AsyncLocalStorage` becomes a Racket parameter carried by task parameterizations, with the same run-count drain. `AbortController` becomes a small cancel-token struct holding the first reason and an event; breaks are not a substitute because the cause is a value that must reach `turn/end`. `deepFreeze` and the `frozenMessages` weak set disappear when messages are immutable values; keep the property that a consumer cannot mutate a request. `using` and `Symbol.dispose` become `dynamic-wind`. `Promise.withResolvers` latches become semaphores or channels. The v8 coverage comments and unreachable guards carry no behavior.

Suggested Racket decomposition:

- `dsh-agent`: `types.rkt` (structs and contracts for `agent`, options, causes, decisions, frames), `registry.rkt` (service: store, factory slot, enter, announce, detach), `initiator.rkt` (parameter plus drain), `dispatch.rkt` (`agent-emit`, `agent-serial`, `agent-waterfall` with the carrier), `model-selection.rkt` (fold, `agent-model`, switch notice listener), `turn-boundary.rkt`, `consumed-work.rkt`, `archive-admission.rkt`.
- `dsh-agent-loop`: `service.rkt` (config, init order, factory ownership, config agents), `lifecycle.rkt` (initialization transaction and memoized teardown), `driver.rkt` (phase machine, send, cancel, maintenance, kick, turn), `step.rkt` (attempt loop, prepare-request, build-request), `inbox.rkt` (fold and facade), `system-prompt-projection.rkt`, `runtime-context.rkt`, `assistant-stream.rkt`.
- `dsh-agent-default-model`: one module over volatile config references and the config editor.
- Generic interface for `Agent` (`define-generics`) so a custom driver can be registered through `register`.

Hard parts and risks:

1. The synchronous prefix of a waking `send`. With cooperative tasks, spawning a task does not run it. The port must run the driver inline until its first suspension (status flip, `turn/start`, claim) before `send` returns, then continue as a task. Tests assert the log state immediately after `steer()`.
2. Reentrancy. Listeners call `cancel`, `send`, `steer` and `dispose` from inside `agent/status`, `session/event`, `agent/turn-stopping` and creation dispatches. Phase changes are committed before the status emit, the wake classification is captured before the insertion, and detach during announcement is deferred. Reproduce these orders exactly.
3. The no-suspension window of section H. System prompt commits, user admission, header and context logging, and request derivation must run without yielding to other tasks.
4. One memoized teardown shared by three owners, with failure collection and the `publication` wait. A second teardown path would release resources under running work.
5. Exactly-once stream settlement on every path, including settlement failure, and the frame order relative to the durable append.
6. Byte-equal request reconstruction. Header equality depends on JSON text of tool schemas, so the port needs order-preserving JSON objects and the same key order for every payload listed under Formats, or recorded dsh sessions will not replay to identical logs.
7. The prompt reconciliation table and the interplay with `contentGeneration`, which makes a consolidation start a new request series in the same attempt.
8. Raised non-exception values. The turn signal's reason is the cause object and is thrown as is; the catch decides by signal state.
9. Projection handles must stay readable after their registration is released, because teardown reads them.

Nothing in `agent`, `agent-loop` or `agent-default-model` needs Node. In `tool-executor-ptc` the executor, scheduler, dispatch events and SDK text renderers are portable; executing TypeScript programs needs a JavaScript engine and is a wrap candidate (see `09-ptc-workflow.md`).

## Feature checklist

- agent: service key `agents`, required inject `sessionProjections`, optional `typert` lookup and host context named `agent`
- agent: `turnBoundary` projection registered before the service becomes visible; `turnBoundaryOf(session)`
- agent: `get(id)` and `list()` in registration order
- agent: `create` and `resume` delegate to the registered factory with the caller's context as owner
- agent: missing factory error `no agent factory registered (load an agent-loop plugin)`
- agent: `setFactory` single slot, duplicate rejected, slot cleared on dispose
- agent: `register(agent)` enters, announces with source `startup`, and detaches on owner disposal
- agent: `enter` rejects id and session id mismatch and duplicate ids
- agent: `announce` runs `agent/created` serially and rejects on a listener failure
- agent: detach bound to the exact entry; stale detach cannot remove a replacement
- agent: detach requested during announcement deferred until the dispatch settles
- agent: `agent/disposed` emitted only for announced entries, with contained listeners
- agent: all `agent/*` dispatch scope-filtered by `scopeTarget(agent, agent)`
- agent: `agentEvents` injects the subject so a payload cannot override `agent`
- agent: contained emit for agent notifications (throw and rejection logged, others still run)
- agent: `assembleContextFor(agent, signal?)` sets `agent` and `scope` together
- agent: initiator scope `withInitiator`, `withoutInitiator`, `currentInitiator`, `requireInitiator`
- agent: initiator boundaries return the exact value or Promise of the operation
- agent: initiator teardown refuses new boundaries, drains returned promises, excludes the initiating chain
- agent: `Model.current()` precedence pending, last used, live options
- agent: `Model.select()` no-op on equal recorded choice; options-only fallback is recorded
- agent: `model/selection` session event with optional effort
- agent: `modelSelection` fold retires a matching pending choice on `request/header`
- agent: adapter-defaulted effort omitted from `lastUsed`
- agent: `modelSelection` wire view `{lastUsed, next}`
- agent: `installModelSelection` appends the model-switch notice on a route change only
- agent: model-switch notice text and `{kind: 'model-selection', form: 'notice', summary}` source
- agent: `agent/inbox/spliced` session event format with optional `removedCount` and `outcome`
- agent: `foldConsumedWork` accounting turn and `droppedUnrun`
- agent: archive admission reports `{kind: 'turn'}` while running, ahead of later providers
- agent: archive stop cancels a running turn with cause `user` and clears the inbox
- agent: `PreStepDecision`, `RequestErrorAction`, `SessionStartSource`, `AssistantStreamFrame` types
- agent-loop: service key `agentLoop` with the six required injections
- agent-loop: config `maxParallelToolCalls` volatile integer `>= 1`, default 10
- agent-loop: config `agents[]` with `id`, `sessionId`, `resumeSessionId`, `provider`, `model`, `reasoningEffort`, `maxTokens`, `cwd`
- agent-loop: `sessionId` and `resumeSessionId` mutually exclusive; duplicate exact identities rejected at load
- agent-loop: launcher identities from `configuredAgentIdentities` replace both identity keys
- agent-loop: `modelSelection` and `inbox` projections registered before the factory is published
- agent-loop: prompt variables `provider` and `model` from the step selection, else agent options
- agent-loop: config agent without identity gets `<id>-session-<uuid>` per start
- agent-loop: config agent with `sessionId` and persistence resumes or creates on not-found only
- agent-loop: config agent with `resumeSessionId` waits for persistence, then resumes
- agent-loop: configured resume records the configured route as the session selection, keeping same-route effort
- agent-loop: contained config start failure with warning and `agent-loop/config-start-failed`
- agent-loop: `create(id, options, meta)` returns a published agent owned by the accessing context
- agent-loop: `createAgent` with seed, meta, inherited count, setup, creation-only signal
- agent-loop: `maxTokens` validated as a positive safe integer
- agent-loop: persistence create before publication; unstored suffix stored before store entry
- agent-loop: creation order session enter, `session/created`, setup, commit, agent enter, `agent/created`
- agent-loop: input sent during setup or creation listeners released after the last listener
- agent-loop: rollback on setup, commit, listener failure or abort; inbox preserved; stored events retained
- agent-loop: resume takes write ownership first, repairs an interrupted turn, appends closers durably
- agent-loop: resume refuses without persistence
- agent-loop: resume continues turn numbers and pending inbox
- agent-loop: agent scope via `createScope`; registrations die with the agent
- agent-loop: `agent.status` idle or running; maintenance reads idle
- agent-loop: `agent/status` emitted on every flip, running emitted inside the waking send
- agent-loop: `send(message, target, wakeup)` with `followup`, `steer`, `inject` presets
- agent-loop: waking send on idle opens `turn/start` and claims synchronously
- agent-loop: waking send after abort rerouted to next-turn and latched
- agent-loop: wake latched behind maintenance and replayed once at convergence
- agent-loop: latched replay suppressed when the queue is empty or the cause is `disposed`
- agent-loop: no driver start after the lifetime signal aborted
- agent-loop: `cancel(cause, {keepInbox})` clears the inbox unless kept, aborts the activity, first cause wins
- agent-loop: cancel aborts even when the inbox write fails, then propagates the failure
- agent-loop: `runMaintenance` exclusive, cancellable, preserves the task result
- agent-loop: `whenIdle` follows replacement work and never rejects
- agent-loop: inbox `append`, `prepend`, `replace`, `remove`, `clear`, `splice` with normalized coordinates
- agent-loop: duplicate pending message id rejected across both lists
- agent-loop: inbox notifications `inserted`, `claimed`, `discarded` after commit
- agent-loop: claim takes all next-step input plus one next-turn message at a turn boundary
- agent-loop: inbox fold validates coordinates and identities and names the offending seq
- agent-loop: one turn per queued prompt with increasing turn numbers
- agent-loop: `turn/start` before claim; exactly one `turn/end` per opened turn
- agent-loop: tool set resolved once per proposed step and disposed after the step
- agent-loop: model selection snapshot per step, reused across retries
- agent-loop: missing provider or model fails the step with the documented message
- agent-loop: prompt assembled once per step with `modelSelection` and `toolSet`
- agent-loop: `agent/pre-step` waterfall with authoritative decision
- agent-loop: reject closes the turn `blocked` without a step and parks queued prompts
- agent-loop: empty first batch closes the turn `completed` without a step
- agent-loop: `startsRequestSeries` honored on the first attempt of the step
- agent-loop: `step/start` and `step/end` balanced
- agent-loop: `agent/request` waterfall seeded from logged controls or `options.maxTokens`
- agent-loop: route and effort changes by `agent/request` rejected
- agent-loop: adapter-default fields removed before the next proposal
- agent-loop: `prepareCall` binding with `NO_ADAPTER` fallback to `ctx.llm.stream`
- agent-loop: cancellation during `agent/request` or `prepareCall` commits no system or user message
- agent-loop: system prompt node 0 reserved, also for an empty prompt
- agent-loop: in-history prompt append on a continuing capable series
- agent-loop: prompt consolidation at the head on incapable routes, empty prompts and differing series starts
- agent-loop: unchanged prompt at a series start emits nothing
- agent-loop: tool-schema change forces consolidation only without `toolUpdate`
- agent-loop: user batch admitted once per step; retries do not repeat it
- agent-loop: runtime-context reminder first, superseding and cleared forms
- agent-loop: runtime-context deduplication by recorded sections
- agent-loop: runtime-context restored after a replacement removed it, also on resume
- agent-loop: closing `system-reminder` tags escaped in the reminder body
- agent-loop: `request/header` reasons `initial`, `resume`, `change`, `series` and `startsSeries`
- agent-loop: header equality over config, adapter-default flags and ordered tool schemas
- agent-loop: `developer/message` for tool additions and removals with `headerSeq` for additions
- agent-loop: `request/context` logged only when one of its four fields changes
- agent-loop: request built from the log, frozen, marked as a loop request, with a live signal
- agent-loop: `agent/assistant-stream` start, dense chunks, single end, monotone revision
- agent-loop: `assistant/message` for every successful call, including empty and `max-tokens`
- agent-loop: `assistant/attempt` for failed, retried and stream-error attempts
- agent-loop: cancelled stream finalizes the text and reasoning prefix with `interrupted: true`
- agent-loop: abandoned end frame when settlement or assembly fails
- agent-loop: terminal finish failure offered to `agent/request-error`; retry in the same step
- agent-loop: cancellation beats a retry action
- agent-loop: thrown stream failures bypass request recovery
- agent-loop: `max-tokens` step ends the turn `max-tokens` and is sticky
- agent-loop: truncated tool calls are not dispatched
- agent-loop: raw tool calls passed to `ctx.tools.execute` with the live parallel limit and step tool set
- agent-loop: `additionalContexts` queued as next-step input after all results
- agent-loop: `concludesTurn` ends the turn unless next-step input is pending
- agent-loop: batch failure records partial contexts and rethrows the original cause
- agent-loop: recovery results `TOOL_OUTCOME_UNKNOWN` and `TOOL_NOT_STARTED` before `step/end`
- agent-loop: `agent/turn-stopping` serial checkpoint with re-read of next-step input
- agent-loop: turn ends `aborted` with a copied cause for `user`, `parent`, `hook`, `disposed`
- agent-loop: turn ends `error` with `LlmFailure` or `{message, code}` (`TOOL_ACTIVATION_FAILED`, `UNKNOWN`)
- agent-loop: `agent/error` emitted before `turn/end` for non-cancellation failures only
- agent-loop: failed or cancelled turn stops the driver; queued prompts wait for a wake
- agent-loop: session observers cannot change a turn outcome
- agent-loop: driver runs inside `withInitiator(agent)`
- agent-loop: handle `dispose` cancels with `disposed`, drains, unwinds scope, closes the handle, detaches agent then session
- agent-loop: one memoized teardown shared by handle, owner unload and loop unload
- agent-loop: teardown failures collected and reported after cleanup completes
- agent-loop: loop unload disposes every live agent and awaits startup work
- agent-loop: id reusable after the prior lifecycle finished quiescing
- agent-default-model: service key `agentDefaultModel`
- agent-default-model: config `provider` and `model` required, `reasoningEffort` optional, all volatile
- agent-default-model: `currentSelection()` reads live config and returns a detached value
- agent-default-model: `saveSelection()` writes the complete config through the config editor, removing an omitted effort
- agent-default-model: saves serialized in submission order; a failed save does not block later ones
- agent-default-model: save is a no-op without an entry or a config editor
- tool-executor-ptc: plugin `ptc-tool-executor` with required `tools`, `systemPrompt`, `ptcRuntime`
- tool-executor-ptc: config `maxSubCallsPerMinute` (1024) and `maxParallelSubCalls` (10)
- tool-executor-ptc: model receives only the `run_code` schema; other direct names fail `UNKNOWN_TOOL`
- tool-executor-ptc: prompt sections `tools:ptc-only` and `tools:sdk`
- tool-executor-ptc: nested calls through the guarded pipeline with `tool/ptc-dispatch-start` and `tool/ptc-dispatch`
- tool-executor-ptc: `tools/ptc-dispatch-log` waterfall for the logged copy
- tool-executor-ptc: host `reset(agent)` with the injected state-loss notice
- tool-executor-ptc: `createRunCodeTool` for private binding sets
- tool-executor-ptc: runs aborted on `sandbox/mode` change and on executor disposal
