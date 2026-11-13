# Recon 09: programmatic tool calling (PTC) and workflows

Pinned commit `e8f7b93a3`; the package sources in the working tree are identical to it. Paths are relative to the repository root. Line numbers refer to `src/` files of the named package at that commit.

Depth: `ptc-runtime`, `tool-executor-ptc`, the host half, wire protocol and child loop of `ptc-runtime-node`, `workflow`, `workflow-ptc` and `tool-workflow` are covered in depth. Catalog depth only: the internals of the four Node evaluators (`evaluators/scoped-repl.ts`, `evaluators/vm-script-await.ts`), the Node import loaders (`imports/*`), the Unicode edge cases of `py-types.ts`, and the internals of the experimental `ptc-runtime-python` frame pump and `py/bootstrap.py`.

Three facts that correct or sharpen the task brief:

- Type stripping (TypeScript to JavaScript) happens in the HOST process with `node:module.stripTypeScriptTypes`, not in the child (`ptc-runtime-node/src/worker.ts:208`, `execution.ts:131-158`). The wire field `ProgramBootData.code` is already JavaScript.
- The transport between harness and Node child is `birpc` over newline-delimited JSON on an inherited pipe at file descriptor 7 (`packages/subprocess/subprocess/src/control.ts`), not stdio. Stdout and stderr are raw program output.
- TypeScript `run_code` discards the program's completion value (`discardCompletion: true`, `ptc.ts:749`). Only `inspect(...)` output and raw stdout/stderr reach the model. The Python variant returns the completion value.

## Scope

| Package dir | npm name | Role | Src lines |
|---|---|---|---|
| `packages/ptc-runtime/ptc-runtime` | `@deepseek-ai/dsh-ptc-runtime` | Service Definition for `ctx.ptcRuntime`: request, spec, result and failure types, `PtcImage`, portable reserved-name sets, abstract `PtcRuntime` | 395 |
| `packages/ptc-runtime/ptc-runtime-node` | `@deepseek-ai/dsh-ptc-runtime-node` | Released provider: runs type-stripped TypeScript in a confined Node child process; four evaluators (async function body, Node REPL, VM Script, scoped REPL); NDJSON RPC; output ledger | 4084 |
| `packages/core/tool-executor-ptc` | `@deepseek-ai/dsh-tool-executor-ptc` | The PTC tool executor: reserved `run_code` transport, generated TypeScript and Python SDK prompt text, nested-call scheduler, dispatch events, `createRunCodeTool` factory, host reset | 2476 |
| `packages/workflow/workflow` | `@deepseek-ai/dsh-workflow` | Service Definition for `ctx.workflowEngine`: start request, run handle, result, `WorkflowError`, six `workflow/*` events | 383 |
| `packages/workflow/workflow-ptc` | `@deepseek-ai/dsh-workflow-ptc` | Workflow engine that runs the script inside the Node PTC process; host child ownership (`host.ts`), guest VM helpers (`runtime.ts`, `guest.ts`), generated guest bundle (`guest-source.ts`) | 1339 |
| `packages/workflow/tool-workflow` | `@deepseek-ai/dsh-tool-workflow` | Model-facing `workflow` tool, foreground and background runs, durable `tool-workflow/*` session records, job-ring mirror | 615 |
| `packages/experimental/ptc-runtime-python` | `@deepseek-ai/dsh-experimental-ptc-runtime-python` | Experimental provider: fresh CPython 3.10+ process per run, fd-3 JSON-lines protocol, POSIX resource limits | 3120 TS + 2714 Python |

Related non-package files: `packages/bundle/web-app/presets/ptc.patch.yml` (138 lines, the Web `ptc` agent preset), `apps/cli/config/examples/ptc.yml` (10 lines, the headless PTC patch), `scripts/demo-ptc.mjs` (the `pnpm run demo:ptc` launcher), `scripts/gen-workflow-guest.ts` (bundles the workflow guest into `guest-source.ts`). Docs read: `docs/subsystems/ptc-runtime.md`, `docs/subsystems/workflow.md`, `docs/tool-catalog.md`, `docs/tool-execution-pipeline.md`, `docs/event-producer-consumer.md`, `docs/persistence-catalog.md`, the package READMEs, and the PTC upgrade guides under `docs/upgrade-guide/`.

### What PTC mode is

In PTC mode the model sees exactly one callable tool, `run_code`. Every other visible tool is declared in the system prompt as a typed function on a `tools` object (the generated SDK). The model writes a program; the program calls `await tools.<name>(args)`; each call is routed back into the same guarded tool pipeline a native call uses (pre-execute policy, approval, guards, around-dispatch, post-execute, result observers). Sub-call arguments and results are logged as `tool/ptc-dispatch-start` and `tool/ptc-dispatch` session events but never enter model history. Only what the program displays (TypeScript: `inspect(...)` and raw stdout/stderr; Python: `print` and the return value) becomes the `run_code` tool result.

PTC is one of two tool executors. `ctx.tools.setExecutor(...)` selects one per scope; `dsh-tool-executor-native` is the other. A withdrawn PTC executor never falls back to native execution.

## Services

### `ctx.ptcRuntime` (abstract `PtcRuntime`, `ptc-runtime/src/index.ts:109`)

A Cordis `Service` registered under the key `ptcRuntime`. One provider per context. It knows nothing about tools or sessions.

| Member | Kind | Semantics |
|---|---|---|
| `language` | abstract readonly string | Lowercase source-language id. Well-known: `'typescript'`, `'python'`. Consumers switch on it and fail loud on an unknown value. |
| `isolation` | abstract readonly string | Substrate descriptor only (`'worker-thread'`, `'process'`, `'container'`). Not a security claim. Both shipped providers report `'process'`. |
| `programFormat` | getter, default `'function-body'` | One of `'function-body'`, `'repl'`, `'script'`, `'scoped-repl'` (`types.ts:16`). |
| `retainsState` | getter, default `false` | Whether memory survives across runs for the same `stateOwner`. |
| `release(owner)` | method, default no-op | Releases the owner's retained environment and awaits its resources. Rejects when cleanup fails. |
| `registerEnvironmentInitializer(program)` | method, default throws `'PTC runtime: environment initialization is unsupported'` | Registers source evaluated once per new environment. At most one; must precede the first run admission. Returns an idempotent async disposer that stops admission, cancels and drains admitted runs and releases environments. |
| `executionInstructions` | getter, default `''` | Provider-owned model guidance appended to the `run_code` description. |
| `sandboxMode` | getter, default `undefined` | Deployment default file-policy mode, or `undefined` when the provider cannot confine. |
| `timeout` | getter, default `undefined` | `{ defaultMs, maxMs }` when per-call timeouts are supported. |
| `resolve(request)` | abstract | `PtcRunRequest -> PtcRunSpec`. Validates explicit choices and fills provider defaults (absolute `cwd`, numeric or `null` `timeoutMs`, sandbox policy). Throws on unsupported choices. |
| `run(spec)` | abstract | `PtcRunSpec -> Promise<PtcRunResult>`. Program, budget, abort and substrate failures RESOLVE with `result.error`; only caller misuse rejects. |

Request and result types (`types.ts`):

- `PtcRunRequest`: `program: string`; `discardCompletion?: boolean`; `stateOwner?: object` (object identity; omission requests a fresh environment); `bindings: PtcBindingNamespace[]`; `cwd?: string`; `timeoutMs?: number | null` (omitted: provider default; `null`: no deadline); `sandboxPolicy?: SandboxExecutionPolicy`; `signal?: AbortSignal`.
- `PtcRunSpec`: the request with `cwd: string` (absolute) and `timeoutMs: number | null` required.
- `PtcBindingNamespace`: `global: string`; `functions: Record<string, PtcBindingFunction>`; `errorClass?: { name: string; memberNameProperty: string }`.
- `PtcBindingFunction`: `(args: unknown) => Promise<PtcJsonValue>`. A rejection surfaces in the program as a rejection of the call.
- `PtcJsonValue`: `null | boolean | number | string | PtcJsonValue[] | { [key: string]: PtcJsonValue }`.
- `PtcOutput`: `{ type: 'text'; text: string } | { type: 'image'; attachment: ImageAttachmentRef }`, in emission order. Adjacent text is concatenated without separators.
- `PtcRunResult`: `sandbox?: { mode: SandboxMode; denied: boolean; enforcement?: SandboxEnforcement }`; `value?: PtcJsonValue`; `output: PtcOutput[]`; `error?: PtcRunFailure`.
- `PtcRunFailure`: `kind` is one of `'exception'`, `'timeout'`, `'abort'`, `'worker-exit'`, `'invalid-output'`, `'output-limit'`, `'protocol'`, `'sandbox-unavailable'`; plus `message: string`. The kinds are independent outcomes: a timeout is not an exception, an abort is not a timeout.
- `PtcImage` (`image.ts`): frozen object `{ path: string; attachment: ImageAttachmentRef }`. A binding may resolve to a `PtcImage`; the program receives an `Image` value.

Portable reserved sets, enforced identically by every provider so a namespace list valid on one backend is valid on all (`index.ts:47-93`):

- Binding globals and error-class names must match `^[A-Za-z_][A-Za-z0-9_]*$` and not be in `PORTABLE_RESERVED_WORDS` (ECMAScript reserved and strict-reserved words including `arguments`, `eval`, `let`, `static`, plus Python keywords and the soft keywords `match`, `type`, `_`).
- `RESERVED_BINDING_GLOBALS`: `console`, `inspect`, `Image`, `__dsh_main__`, `__builtins__`, `__name__`, `__debug__`.
- `RESERVED_ERROR_MEMBERS` for `memberNameProperty`: `name`, `message`, `stack`, `args`, `with_traceback`, `add_note`; also any name matching `DUNDER_MEMBER = /^__.+__$/`; also the empty string.
- Function names inside a namespace are arbitrary strings and must behave as own properties (`__proto__`, `constructor` are ordinary keys).

Lifecycle: a provider terminates and awaits in-flight runs when its plugin is disposed. Distinct state owners are isolated. Retained state is never durable.

### `NodePtcRuntime` (`ptc-runtime-node/src/index.ts:24`)

Service class, default export, `static inject = ['fs', 'subprocess', 'sandbox', 'sandboxPolicy']`. `language = 'typescript'`, `isolation = 'process'`. `sandboxMode` returns `ctx.sandboxPolicy.defaultMode`. `timeout` returns `{ defaultMs: min(timeoutMs, maxTimeoutMs), maxMs: maxTimeoutMs }`. `programFormat`, `retainsState` and `executionInstructions` come from the configured execution mode (see Configuration). `registerEnvironmentInitializer` works only with `executionMode: persistent-in-memory`; it strips types at registration and throws on: disposal, another mode, a second registration, or a registration after the first run.

### `PythonPtcRuntime` (`experimental/ptc-runtime-python/src/index.ts:744`)

Service class, default export, `static inject = ['sandbox', 'sandboxPolicy']`. `language = 'python'`, `isolation = 'process'`, `programFormat` `'function-body'`, `retainsState` false, `timeout` undefined, `sandboxMode` is the policy default. `resolve` rejects any `timeoutMs` (`'dsh-ptc-runtime-python: per-call timeout is unsupported'`) and `discardCompletion: true`, and returns `timeoutMs: config.maxWallMs`. Initializer registration is unsupported. Rejects construction on Windows.

### `ctx.workflowEngine` (abstract `WorkflowEngine`, `workflow/src/index.ts:157`)

A Cordis `Service` under the key `workflowEngine`. One engine per context.

- `start(request: WorkflowStartRequest): WorkflowRun`. Throws `WorkflowError` synchronously for a request that cannot begin. After a run is returned, every failure resolves through `run.result`.
- `protected emitWorkflowEvent(name, ...args)` (`index.ts:175-186`): gets the listener list from `ctx.events.dispatch('emit', [name, ...args])`, calls each listener in a `try`, and attaches a rejection handler to a returned thenable. A throwing or rejecting listener is logged with `ctx.logger.warn` (`workflow: <name> listener threw: ...` or `... listener rejected: ...`) and never stops later listeners. The same argument objects are passed to every listener; the source does not clone them (the subsystem doc says it does).

`WorkflowStartRequest` (`runtime-types.ts`): `script: string`; `meta: WorkflowMeta`; `args?: unknown`; `subagentProvider?: string`; `maxTotalAgents?: number`; `parent: Agent` (required); `signal?: AbortSignal`.

`WorkflowRun`: `id: WorkflowRunId`; `meta: WorkflowMeta`; `result: Promise<WorkflowResult>` (never rejects); `cancel(reason?)`; `dispose(): Promise<void>` (idempotent; cancels if needed and awaits script and child cleanup). The holder owns the run; engine unload does not invalidate it.

`WorkflowMeta`: `name: string`; `description: string`; `whenToUse?: string`; `phases?: { title: string; detail?: string; provider?: string; model?: string }[]`.

`WorkflowResult`: `value: unknown` (JSON; `null` when the script returned nothing); `stopReason: 'completed' | 'cancelled' | 'error'`; `error?: string`; `agentsStarted: number`.

`WorkflowError extends HarnessError` with `fatal: boolean` (default true). Codes: `SCRIPT_PARSE`, `META_INVALID`, `INVALID_ARGUMENT`, `UNSUPPORTED_OPTION`, `UNSUPPORTED_SCHEMA`, `AGENT_CAP`, `ITEM_CAP`, `AGENT_START`, `AGENT_RESULT`, `RESULT_UNSERIALIZABLE`, `CANCELLED`. `isFatalWorkflowError(error)` is `error instanceof WorkflowError && error.fatal`.

### `PtcWorkflowEngine` (`workflow-ptc/src/index.ts:103`)

Service class, default export, `static inject = ['subagents', 'ptcRuntime', 'sandboxPolicy', 'workingDirectory']`. The constructor throws `'workflow-ptc requires the Node TypeScript PTC runtime'` unless `ctx.ptcRuntime.language === 'typescript'`.

### Objects that are not services

- `PtcExecutor` (`tool-executor-ptc/src/index.ts:24`) implements the `ToolExecutor` interface of `dsh-tools` and is installed with `ctx.tools.setExecutor(new PtcExecutor(ctx, config))`. Members: `sections` (two prompt sections), `describe(tools)`, `execute(batch)`, `reset(agent)`. No service exposes the instance; a host that needs `reset` must construct and keep it.
- `createRunCodeTool(ctx, options)` (`run-code.ts:36`, package entry `./run-code`) returns an unregistered `ToolDefinition`: a named program tool with a caller-supplied runtime and a private list of tool definitions.
- `PtcCalls` (`ptc-calls.ts`): per-executor admission, cancellation and reset bookkeeping keyed by session id.

Services this area consumes: `tools`, `systemPrompt`, `ptcRuntime`, `workingDirectory`, `sandboxPolicy`, `sandbox`, `subprocess`, `fs`, `approval`, `attachments`, `sessions`, `subagents`, `jobs`, `logger`. Optional ones are read with `ctx.get(name)`.

## Events

### Cordis events

| Event | Mode | Payload | Producer | Consumers |
|---|---|---|---|---|
| `tools/ptc-dispatch-log` | waterfall | `(dispatch: PtcDispatchLog, next: () => Promise<ContentBlock[]>) => Promise<ContentBlock[]>` | `tool-executor-ptc` (`ptc.ts:326-336`), scope-filtered with `scopeTarget(tools, agent)` | `spill-policy` (replaces oversized content with a preview and locator) |
| `workflow/start` | emit | `(info: WorkflowRunInfo)` | workflow engine | none shipped |
| `workflow/phase` | emit | `(info, title: string)` | workflow engine | `tool-workflow` mirror |
| `workflow/log` | emit | `(info, message: string)` | workflow engine | `tool-workflow` mirror |
| `workflow/agent-start` | emit | `(info, agent: WorkflowAgentInfo)` | workflow engine | `tool-workflow` recorder and mirror |
| `workflow/agent-end` | emit | `(info, agent: WorkflowAgentEndInfo)` | workflow engine | `tool-workflow` recorder and mirror |
| `workflow/end` | emit | `(info, result: WorkflowResultInfo)` | workflow engine | none shipped |

`PtcDispatchLog` (`runtime-types.ts:16`): `exec: ToolExecution` (the outer `run_code` execution); `agent?: Agent`; `subCallId: ToolCallId`; `name: string`; `isError: boolean`; `content: ContentBlock[]`. A listener may return replacement blocks. Only the logged copy changes; the program already has its value. A throwing listener is contained: the original content is logged and a warning is written.

`WorkflowRunInfo`: `{ id, meta }`. `WorkflowAgentInfo`: `{ seq: number (1-based); label: string; phase?: string; childId: SessionId }`. `WorkflowAgentEndInfo` adds `outcome: 'completed' | 'failed' | 'cancelled'`. `WorkflowResultInfo`: `{ stopReason; error?; agentsStarted }`, deliberately without the value.

Ordering guarantees for `workflow/*`: `workflow/start` fires synchronously inside `start()` after validation and before the body runs. `workflow/agent-start` and `workflow/agent-end` pair by `seq`, exactly one end per observed start on every stop path (the host synthesizes `outcome: 'cancelled'` ends for still-open members at settlement, `host.ts:319`). `workflow/end` fires exactly once when `run.result` settles. No progress event is delivered after cancellation (`host.ts:257`).

Events consumed from other areas: `session/event` filtered to `type === 'sandbox/mode'`, registered with `{ global: true }`, by `PtcCalls` (`ptc-calls.ts:31-36`) and by the Node provider's `PolicyProcesses` (`policy-processes.ts:24-31`). Through the shared pipeline every sub-call also passes `tools/pre-execute`, `tools/execute`, `tools/post-execute` and `tools/result`.

### Session events (durable, log-only)

`tool/ptc-dispatch-start`, data `PtcDispatchStartEventData` (`tool-executor-ptc/src/types.ts:12`): `rootCallId`, `parentCallId`, `subCallId`, `name`, `arguments` (the JSON-normalized arguments). Appended when the scheduler actually starts the call, before pre-execute policy. A call abandoned in the queue logs nothing.

`tool/ptc-dispatch`, data `PtcDispatchEventData`: the start fields plus `isError: boolean`, `content: ContentBlock[]`, optional `meta: JsonValue` (tool presentation metadata), optional `error: { name; code; reason? }`. Every started sub-call settles with exactly one, abort included. Field order as written by the producer (`ptc.ts:611-624`): `rootCallId, parentCallId, subCallId, name, arguments, isError, error?, content, meta?`.

Both are appended inside the open `run_code` execution, between its `tool/call` and `tool/result`. `deriveMessages()` ignores them. Nothing is appended when the outer call has no agent.

Golden example from `snapshots/session/ptc-turn/session.v4.jsonl`:

```json
{"type":"tool/ptc-dispatch-start","data":{"rootCallId":"call_00_X","parentCallId":"call_00_X","subCallId":"call_00_X:ptc:1","name":"bash","arguments":{"command":"echo CODE_ONE","description":"Print CODE_ONE"}}}
{"type":"tool/ptc-dispatch","data":{"rootCallId":"call_00_X","parentCallId":"call_00_X","subCallId":"call_00_X:ptc:1","name":"bash","arguments":{"command":"echo CODE_ONE","description":"Print CODE_ONE"},"isError":false,"content":[{"type":"text","text":"CODE_ONE\n"}],"meta":{"cwd":"{{cwd}}"}}}
```

`tool-workflow/run-start` `{ runId, name }`; `tool-workflow/agent-start` `{ runId, seq, label, phase?, childId }`; `tool-workflow/agent-end` `{ runId, seq, outcome }`; `tool-workflow/run-end` `{ runId, stopReason }` (`tool-workflow/src/types.ts`). Written by the `workflow` tool into the calling parent session, only for top-level calls (`exec.parent === undefined`). `run-end` is written after `run.dispose()` reaches quiescence. The first append failure disables later writes for that run, so the log holds nothing or a legal prefix. A missing end at the log tail is valid interruption evidence.

Message source: `'ptc-mode': { kind: 'ptc-mode' }` (merged into `MessageSourceMap`). Used for deferred sub-call image messages and the reset notice.

Job kind: `workflow: 'workflow'` (merged into `JobKindMap` of `dsh-jobs`).

## Tools

### `run_code` (reserved transport, `tool-executor-ptc/src/ptc.ts`)

Name: `run_code` (`RUN_CODE_NAME`, defined in `packages/core/tools/src/contracts.ts:13`). It is not a registered capability: the executor's pipeline source returns it for the name `run_code` (`index.ts:40`), so scoped allow and deny lists, shadows and restrictions cannot remove or replace it, and it never appears as a binding inside programs.

Description: a getter evaluated at every schema projection (`ptc.ts:840-850`), concatenating

1. the flavor description,
2. a space and `runtime.executionInstructions` when non-empty,
3. the literal ` Each program starts in the Session's current directory. Running programs keep their initial directory.`,
4. the escalation guidance when `runtime.sandboxMode !== undefined`: ` A sandbox escalation approves this complete program for one execution only. Nested tools retain their own policies and approvals. Request wider access only after evidence of a denial. Earlier effects may already have completed: inspect them before explicitly retrying. Programs are never replayed automatically.`

Flavor description template (`ptc.ts:48-59`): ``Execute a <Language> program against the available tools. Takes two required arguments: `code`, <programDescription>, and `description`, a short summary of what the program does. Call tools as `await tools.name(args)` per the declarations in the system prompt. <outputInstruction>``

| Runtime | `<programDescription>` | `<outputInstruction>` | `code` parameter description |
|---|---|---|---|
| typescript, `function-body` | ``the BODY of an async function (erasable syntax only; top-level `await` and `return` work)`` | `Show selected text and images with inspect(...values).` | `The program: the body of an async TypeScript function.` |
| typescript, other formats | `the program to execute` | same | `The TypeScript program to execute, following this tool's execution instructions.` |
| python | `the program to execute` | `Curate the program output. Image-bearing subtool results are attached after the run.` | `The Python program to execute, following this tool's execution instructions.` |

The complete description for the default composition (Node, `per-call`) is pinned in `snapshots/session/ptc-turn/tool-schemas.expected.json` and `docs/tool-catalog.md`.

Parameters as emitted for the default Node runtime (golden):

```json
{
  "type": "object",
  "properties": {
    "code": { "type": "string", "description": "The program: the body of an async TypeScript function." },
    "description": { "type": "string", "description": "Clear, concise description of what this program does in active voice, 5-10 words (shown in the UI). Examples: \"Count TODO markers across packages\"; \"Read failing test and its fixture\"; \"Rename config key in every cordis.yml\"." },
    "timeoutMs": { "type": "number", "description": "Positive elapsed-time budget in milliseconds, including nested tool and approval waits. Default 120000; capped at 600000. Zero does not disable the deadline." },
    "sandbox_permissions": { "type": "string", "description": "Wider sandbox mode for this complete program execution; requires justification and approval.", "enum": ["workspace-write", "danger-full-access"] },
    "justification": { "type": "string", "description": "Reason this complete program needs wider access, shown to the user for approval. Use the language of the user’s current request." }
  },
  "required": ["code", "description"]
}
```

`timeoutMs` is emitted only when `runtime.timeout !== undefined`, with the provider's `defaultMs` and `maxMs` interpolated. `sandbox_permissions` and `justification` are emitted only when `runtime.sandboxMode !== undefined`. The enum is `ESCALATION_TARGETS` from `dsh-sandbox`. Property order is `code`, `description`, `timeoutMs`, `sandbox_permissions`, `justification`. Argument validation uses a static spec that always accepts all five (`ptc.ts:362-370`); unsupported controls are rejected in `execute`.

Canonical output value (tool output schema, `ptc.ts:371-388`): object, `additionalProperties: false`, with `logs: string[]` (required), `result?: json`, `sandbox?: { mode: 'read-only' | 'workspace-write' | 'danger-full-access' (required); denied: boolean (required); enforcement?: 'full' | 'partial' }`.

Model-facing result content (`renderRunOutput`, `ptc.ts:261-285`):

1. Walk the ordered output. Join consecutive text entries with `''` into one text block (skipped when empty). Emit each image as a `{ type: 'image', attachment }` block at its position.
2. Build detail lines: the rendered `result` when present (a string is emitted raw; any other JSON value is pretty-printed with two-space indentation, and subtrees whose indentation would exceed 10 characters are emitted compact, `ptc.ts:183-255`); `File sandbox enforcement is partial on this host.` when `sandbox.enforcement === 'partial'`; `The <mode> file sandbox denied an operation.<escalation guidance>` when `sandbox.denied`. Non-empty lines joined with `\n` form one more text block.
3. When nothing was produced the content is one text block `(run_code completed with no output)` (with the tool's own name for registered program tools).

Golden: the two-`bash` program in `ptc-turn` yields `content: [{"type":"text","text":"captured output\nCODE_ONE+CODE_TWO\n"}]`.

When the run produced images, the ordered output is stored per execution and installed by `projectContent` before post-execute policy, but only if the pipeline's result still deep-equals the value or failure the tool produced (`ptc.ts:815-826`). Policy replacements stay authoritative.

Error cases (all become `isError` tool results through the pipeline, content `Error: <message>`):

- Blank `description`: `invalid description: expected a non-empty string`.
- `sandbox_permissions` without `justification`, the reverse, or a blank justification: `SandboxEscalationError` code `SANDBOX_ESCALATION_INVALID_ARGUMENT` (`validateEscalationArgs`).
- `timeoutMs` with a runtime that has no `timeout`: `timeoutMs is not available for this PTC runtime`. Non-finite or `<= 0`: `invalid timeoutMs: expected a positive finite number`.
- Escalation with a runtime that cannot confine: `sandbox_permissions is not available for this PTC runtime`.
- Missing runtime: `dsh-tools: mode "ptc" requires a PTC runtime — load a ctx.ptcRuntime implementation (e.g. @deepseek-ai/dsh-ptc-runtime-node) or load @deepseek-ai/dsh-tool-executor-native`. Unknown language: `dsh-tools: no SDK renderer registered for runtime language "<x>" (known: "typescript", "python")`. Both also fail prompt assembly.
- Agent-owned call without `workingDirectory`: `dsh-tools: run_code with an Agent requires workingDirectory`. Confining runtime without `sandboxPolicy`: `dsh-tools: confined PTC runtime requires sandboxPolicy`.
- Program failure: `CodeRunFailedError`, code `CODE_RUN_FAILED`, message `code run failed (<kind>): <failureText><logsText><sandboxText><guidance>` (`ptc.ts:783-789`). `<logsText>` is `\nCaptured output:\n` + all text output joined, only when there is text and no image. `<sandboxText>` is a newline (omitted when `<logsText>` already ends with one) plus `File sandbox: <mode>[; enforcement: <e>][; operation denied].` when the result has a `sandbox`. `<guidance>` is the escalation guidance when `sandbox.denied`. With images, the content is `Error: <message>` followed by the ordered output blocks.
- Caller cancellation (`result.error.kind === 'abort'`, the outer signal is aborted, and no call-limit error): `HarnessError` code `ABORTED`, name `AbortError`, message `tool call aborted`, or `tool call aborted: <runtime message>` when the runtime retains state.
- Tool-call allowance exhausted: `code run failed (abort): run_code exceeded its limit of <limit> tool calls (<perMinute> per minute of its timeout); call <n> was not dispatched. The run_code program may contain an infinite loop. Check loop termination or split the work into smaller run_code calls.` When the runtime's own abort message differs, it follows on a new line.
- Reset pending or failed: `Program environment unavailable: <cause>. Ask the host to reset it before running more code.`
- A model-direct call naming any other tool: `ToolNotFoundError`, code `UNKNOWN_TOOL`, message ``unknown tool "<name>": only `run_code` is callable directly — call `<name>` from inside a `run_code` program instead`` (`index.ts:41-43`), decided before any policy runs.

Approval and sandbox interaction: `run_code` itself passes the normal pre-execute pipeline as a root call. A wider `sandbox_permissions` calls `approveEscalation({ requestedMode, justification, effectiveMode: standingPolicy.mode, subject: 'program' }, { approver: ctx.get('approval'), agent, callId, toolName, signal })`. Repeating the current mode needs no approval. A granted mode applies to this one execution, omits the state owner (a temporary environment), and does not change the session's standing policy. Nested tools keep their own policies and approvals. Programs are never replayed automatically.

Presentation: `presentCall` returns `{ card: 'generic', title: args.description, kind: 'execute', rawInput: args.code }`. There is no `presentResult`.

Root `run_code` calls declare no `isConcurrencySafe`, so the batch scheduler treats them as exclusive and runs them serially.

### The generated SDK (how tools appear as a code API)

Two executor-owned prompt sections, both with `interpolate: false` (`index.ts:35-38`):

- `tools:ptc-only`, order `PTC_ONLY` = 800, text: `` `run_code` is the only tool you can call directly — a tool call naming any other tool fails. Reach every tool the SDK declares below from inside the program. ``
- `tools:sdk`, order `TOOLS_SDK` = 5000, text generated from the step's visible tool definitions: `SDK_RENDERERS[runtime.language](tools.map(d => ({ ...projectToolSchema(d, false), output: d.output.schema })), runtime.programFormat)`.

`describe(tools)` returns `{ schemas: [projectToolSchema(run_code, false)], knownNames: ['run_code'] }`: the model request carries one tool schema.

TypeScript SDK text (`renderToolsSdk`, `ts-types.ts:308-335`). The section is the concatenation of: `<instructions>`, `<bashExample>` (possibly empty, no separator before it), a blank line, `<programInstructions>`, a blank line, and a fenced `ts` code block (opening fence line, the `JsonValue` type line, a blank line, the declarations, closing fence line, no trailing newline).

`<instructions>` (`ts-types.ts:251-258`) is a level-2 Markdown heading line with the text `Writing code for run_code`, a blank line, and this paragraph:

```text
`run_code` takes two required arguments: `code`, <P>, and `description`, a short summary of what the program does. The declarations below are SDK bindings for this program. A declaration does not make its name a directly callable tool; only names supplied as separate tool schemas may be called directly.
```

`<P>` is ``the body of an async TypeScript function (erasable syntax only — no `enum` or namespaces; type annotations are advisory, the code runs type-stripped)`` for `function-body`, otherwise `the program to execute`.

`<bashExample>` is appended directly (no newline) only when a tool named `bash` exists, its parameters are an object whose `required` list contains nothing but `command` and `description`, and its `command` (and `description`, when required) string schemas accept the example literals (`ts-types.ts:280-293`):

```text
 When no separate `bash` schema is supplied, invoke a declared `bash` binding inside `run_code`:

`run_code({ code: "inspect(await tools.bash({ description: 'Show current directory', command: 'pwd' }))", description: "Show current directory" })`
```

The `description: 'Show current directory', ` part is present only when `description` is required.

`<programInstructions>` (`ts-types.ts:261-270`), verbatim:

```text
Inside the program:

- Call tools as `await tools.name(args)` — quoted access for exotic names: `tools["my-tool"](args)`. Every call resolves to its declared value, which may be an Image. Tool arguments must be lossless JSON.
- A FAILED tool call rejects with `ToolCallError`, whose `toolName` identifies the failed tool and whose `message` is human-readable — `try/catch` it to handle and continue.
- Independent read-only calls MAY overlap under `Promise.all` (safe calls run concurrently; mutating calls run alone, in submission order). Sequence dependent work with `await`.
- Show selected values and images with `inspect(...values)`; every other intermediate result stays out of the conversation, so extract just what you need.

Program-only SDK bindings:
```

The fenced `ts` block, with pieces joined by one blank line:

```ts
type JsonValue = null | boolean | number | string | JsonValue[] | { [key: string]: JsonValue }

declare class Image { private constructor(); readonly attachmentId: string; readonly path: string; readonly width: number; readonly height: number; }

declare function inspect(...values: unknown[]): void;

interface ToolArgsMap {
  /** <tool description, whitespace collapsed> */
  <key>: <parameters type>;
  ...
}

interface ToolOutputMap {
  <key>: <output type>;
  ...
}

type ToolName = keyof ToolOutputMap

declare class ToolCallError extends Error {
  readonly name: "ToolCallError";
  readonly toolName: ToolName;
}

declare const tools: {
  [K in ToolName]: (args: ToolArgsMap[K]) => Promise<ToolOutputMap[K]>;
}
```

Rendering rules:

- Tools are sorted by name with JavaScript `<` on strings (UTF-16 code unit order). With no tools the maps render as `interface ToolArgsMap {}` and `interface ToolOutputMap {}`.
- A key is bare when it matches `^[A-Za-z_$][A-Za-z0-9_$]*$`, otherwise `JSON.stringify(name)`.
- A description becomes one JSDoc line `/** <text> */`: runs of whitespace collapse to one space, the text is trimmed, and `*/` is replaced by `*\/`. Empty or missing descriptions emit no line. Output map members get no top-level doc line; nested properties in both maps do.
- Output type special cases (hardcoded, marked FIXME in source): `read_image` renders `Image`; `cua` renders `Image | <output type>`.
- `jsonSchemaToTs(schema, indent)` (`ts-types.ts:113-248`), two spaces per indent level: `oneOf` renders members joined by ` | `; a node without `type` renders `JsonValue`; `string`, `number`, `boolean`, `null` render their name and `integer` renders `number`, unless `const` (rendered with `JSON.stringify`) or `enum` (members joined by ` | `) is present, with `const` taking precedence; `array` without `items` renders `JsonValue[]`, with items `T[]`, or `(T)[]` when the item text contains `|` or `&`; `object` with no properties renders `Record<string, JsonValue>` (open) or `Record<string, never>` (`additionalProperties: false`); `object` with properties renders `{`, then per property in declaration order its doc line and `<key><?>: <type>;` (`?` when not in `required`), then `}`, followed by ` & Record<string, JsonValue>` unless `additionalProperties === false`. An unsupported or malformed schema renders `unknown`.
- The render is deterministic: an unchanged tool set yields byte-identical text.

A full golden instance is `snapshots/session/ptc-turn/system-prompt.expected.md` from the line `## Writing code for run_code` to the end.

Python SDK text (`renderToolsSdkPy`, `py-types.ts:762-817`): the fixed `SDK_INSTRUCTIONS` block (`py-types.ts:733-742`, starting `## Writing code for run_code` and ending `The available tools:`), then a fenced `python` block: `from typing import <used symbols in the order Any, Literal, NotRequired, Protocol, TypedDict>`, blank line, `class ToolCallError(Exception):\n    toolName: str`, blank line, the `TypedDict` classes (nested classes before their parents, tools in name order) separated by blank lines, then `class Tools(Protocol):` with one `    async def <name>(self, args: <ArgType>) -> <OutputType>:` per tool followed by a `"""docstring"""` line at eight spaces (or ` ...` on the same line when there is no description), then a blank line and `tools: Tools`. A tool whose name is not a bare NFKC-stable identifier, is a Python hard keyword or `__debug__`, or starts with `_` is listed as a comment `    # tools["<name>"](args: <ArgType>) -> <OutputType>` plus `    #   <description>`; when no method was emitted the class body starts with `    pass`. Type mapping: `string` `str`, `number` `float`, `integer` `int`, `boolean` `bool`, `null` `None`, `const` and `enum` `Literal[...]`, `oneOf` `A | B`, `array` `list[T]` (`list[Any]` without items; `Any` past 180 nested lists), objects as named `TypedDict` classes (`<CamelToolName>Args`, `<CamelToolName>Output`, children `<Parent><CamelField>`, name bases capped at 120 UTF-16 units, collisions suffixed `2`, `3`, ...), optional fields as `NotRequired[T]`, field descriptions as `    # <text>` comments, open objects marked with `    # Additional keys beyond those declared are allowed.`, a closed empty object as a class with the body `    pass`, and open empty objects, objects with inexpressible field names (non-identifier, keyword, or `__x` without trailing `__`) and objects without a naming context degraded to `dict[str, Any]`. The instructions state that only `tools` and `ToolCallError` exist at run time. `SDK_INSTRUCTIONS` after its heading line (a level-2 heading with the text `Writing code for run_code`) and a blank line, verbatim:

```text
`run_code` takes two required arguments: `code`, the program to execute, and `description`, a short summary of what the program does. At run time exactly two of the names declared below are bound: `tools` and `ToolCallError`. Everything else is a STATIC STUB describing argument and return types — in particular the `TypedDict` classes do NOT exist at run time, so build arguments as plain `dict`/`list` JSON values: `await tools.name({"field": 1})`, never `FooArgs(field=1)`, which raises `NameError`. Inside the program:

- Call tools as `await tools.name(args)` — subscript access for exotic, reserved, or underscore-leading names: `await tools["my-tool"](args)`. Every call resolves to the tool's typed canonical JSON value (each method's return type below). Tool arguments must be lossless JSON.
- A FAILED tool call raises `ToolCallError`, whose `toolName` identifies the failed tool and whose message is human-readable — wrap in `try/except` to handle and continue.
- Independent read-only calls MAY overlap under `asyncio.gather` (safe calls run concurrently; mutating calls run alone, in submission order). Sequence dependent work with `await`.
- Only values emitted as program output enter the conversation. A successful tool result containing an image is attached after the run so you can inspect it on the next step; every other intermediate result stays out of the conversation, so extract just what you need.

The available tools:
```

### Registered program tools (`createRunCodeTool`)

`createRunCodeTool(ctx, { name, description, runtime, tools, limits? })` builds the same transport under another name with: the caller's description in place of the flavor description (runtime instructions, the directory sentence and escalation guidance are still appended); the given runtime instead of `ctx.ptcRuntime`; bindings only for the given private definitions (which need not be registered; duplicate names throw `Program tool <name> has duplicate binding <binding>`); its own `ToolExecutionPipeline` whose source resolves only those definitions; its own `PtcCalls`. It produces no SDK prompt section. Used by experimental CUA packages (`snapshots/session/cua-run-code`).

### `workflow` (`tool-workflow/src/index.ts`)

Name: `config.toolName`, default `workflow`.

Description (`DESCRIPTION`, `index.ts:158-166`), verbatim:

```text
Run a JavaScript workflow script that orchestrates subagents at scale. Use this for work that fans out across many independent pieces — an audit over many files, a migration, multi-angle research, adversarial verification of findings — where you write the orchestration as a script instead of delegating turn by turn.

Script-body hooks:
- `agent(prompt, opts?): Promise<any>` — run one subagent to completion. Without `opts.schema` it resolves to the child's final text; with `opts.schema` (an object-rooted JSON Schema using ONLY type/properties/required/additionalProperties/items/enum/const/oneOf) it resolves to the validated object. Resolves `null` when the child fails (filter with `.filter(Boolean)`). Other opts: `label` (display), `phase` (progress group), and independent `provider`/`model` LLM target overrides.
- `pipeline(items, ...stages): Promise<any[]>` — run each item through the stages independently with NO barrier between stages (prefer this for multi-stage work). Each stage receives `(prev, item, index)`. A stage throw drops that ITEM to `null` and skips its remaining stages.
- `parallel(thunks): Promise<any[]>` — run zero-argument functions concurrently and await ALL of them (a barrier; use only when a stage genuinely needs every prior result together). A throwing thunk resolves to `null`.
- `phase(title)` — start a progress phase; `log(message)` — narrate progress; `args` — the tool call's `args` input, verbatim.

Misused hooks (bad arguments, unknown options, unsupported schemas, tripped caps) end the whole script instead of producing `null`. The script has no filesystem, network, timer, or Node.js APIs; the agents do the work.
```

Parameters (JSON Schema as emitted; property order as listed):

| Property | Type | Required | Description text |
|---|---|---|---|
| `script` | string | yes | ``The plain JavaScript body, not TypeScript and without an `export const meta` statement; top-level await is allowed. End with `return <value>`; the JSON-serializable value is this tool's result.`` |
| `meta` | object, `additionalProperties: true` | yes | `The workflow identity as plain JSON, not code.` |
| `meta.name` | string | yes | `Short kebab-case workflow name.` |
| `meta.description` | string | yes | `One-line description of what the workflow does.` |
| `meta.whenToUse` | string | no | `Optional guidance on when this workflow applies.` |
| `meta.phases` | array of object (`additionalProperties: true`) | no | `Optional phase declarations matched by phase() calls.` |
| `meta.phases[].title` | string | yes | `The phase title phase() calls match by exact string.` |
| `meta.phases[].detail` | string | no | `Optional one-line description of the phase.` |
| `meta.phases[].provider` | string | no | `Optional provider override this phase is expected to use.` |
| `meta.phases[].model` | string | no | `Optional model override this phase is expected to use.` |
| `args` | object, `additionalProperties: true` | no | ``Optional JSON input exposed to the script as the `args` global (wrap a bare list as a field, e.g. {"files": [...]}).`` |
| `run_in_background` | boolean | no | `Run as a background job: return a job id immediately instead of waiting; the return value arrives with the completion notice.` Present only when `enableRunInBackground`. |

The tool schema accepts extra `meta` keys, but the engine's `validateMeta` rejects them by name.

Output value: `oneOf` `{ kind: 'background', jobId: string, runId: string }` or `{ kind: 'foreground', runId: string, agentsStarted: integer, result: json }`, both `additionalProperties: false`.

Rendered result: foreground `workflow "<name>" completed (<n> agent|agents).\nReturn value:\n<JSON.stringify(value, null, 2)>`; when the JSON text exceeds `maxResultChars` it is cut to that many characters and followed by `\n… [truncated: <k> more characters]`. Background: `workflow "<name>" started in the background as job <jobId>. Its return value arrives with the completion notice; check on it with job_output, stop it with job_kill.`

Errors: no calling agent `workflow tool requires a calling agent (exec.agent was undefined)`; background disabled `run_in_background is disabled for this tool`; no job registry `background jobs unavailable: load @deepseek-ai/dsh-jobs and @deepseek-ai/dsh-tool-jobs`; synchronous engine rejections (`invalid meta: <violations joined by '; '>`, `workflow script does not parse: ...`) surface as ordinary tool errors; stop reason `cancelled` gives `workflow run was cancelled[ (<error>)]`; stop reason `error` gives `workflow run failed: <error or 'unknown error'>`.

Prompt section: name `tool:<toolName>`, order `TOOL_WORKFLOW` = 2600, text `Use the <toolName> tool ONLY when the user explicitly asks for a workflow or for large multi-agent orchestration: you write a JavaScript script (the tool description documents the exact format) that fans work out across many subagents with phases and structured results. For one or two delegations, prefer plain subagent calls.`

Presentation: call `{ card: 'generic', title: 'workflow: <meta.name>', rawInput: script }`; result `{ card: 'generic' }`.

The tool declares no sandbox parameters. The script process runs under the calling session's standing file policy; children are subagents with their own policies and approvals.

## Configuration

### `@deepseek-ai/dsh-tool-executor-ptc`

Function plugin: `name = 'ptc-tool-executor'`, `inject = ['tools', 'systemPrompt', 'ptcRuntime']`, `apply(ctx, config)` calls `ctx.tools.setExecutor(new PtcExecutor(ctx, config))`. Because `ptcRuntime` is a required injection, the executor activates only while a runtime is mounted and withdraws when it unloads.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `maxSubCallsPerMinute` | natural, min 1 | `1024` | Nested tool-call attempts per minute of resolved timeout, failed and rejected attempts included |
| `maxParallelSubCalls` | natural, min 1 | `10` | Overlap limit for concurrency-safe sub-calls inside one program; `1` is serial |

Root-batch parallelism is a constructor argument defaulting to `() => 10`, not config.

### `@deepseek-ai/dsh-ptc-runtime-node`

Service class `NodePtcRuntime`, default export. `static Config = NodeConfig` (`config.ts:41-57`).

| Field | Type | Default | Meaning |
|---|---|---|---|
| `executionMode` | `'per-call' \| 'persistent-in-memory' \| 'vm-script'` | `'per-call'` | Evaluator and process lifetime |
| `scriptPersistence` | boolean | `false` | With `vm-script`, retain a process and context per owner. `true` with another mode rejects at load |
| `replScoped` | boolean | omitted: `true` with `persistent-in-memory`, else `false` | Scoped REPL instead of Node's REPL. `true` with another mode rejects at load |
| `timeoutMs` | number | `120000` | Default elapsed deadline, nested tool and approval waits included |
| `maxTimeoutMs` | number | `600000` | Cap applied by `resolve` |
| `maxOutputBytes` | number | `67108864` | Combined serialized output, completion and diagnostic budget. Integer, at least 4 |
| `maxOldGenerationSizeMb` | number | `512` | V8 old-generation heap limit |
| `maxMessageBytes` | number | `134217728` | Limit for one control message, outstanding binding-argument bytes, and queued control writes |
| `maxPendingCalls` | number | `128` | Simultaneous host binding calls |
| `stopGraceMs` | number | `3000` | Wait for cooperative stop acknowledgment |
| `graceMs` | number | `3000` | Managed termination and output-drain grace |
| `launch` | `{ kind: 'node-script', executable, bootstrapPath? }` or `{ kind: 'embedded', executable }` | omitted: local carrier | Child invocation in the subprocess execution world |

Validation (`validateConfig`): every numeric field positive and finite; the four time fields at most `2147483647`; the four size and count fields safe integers; `launch.executable` non-empty; `launch.bootstrapPath` absolute. Omitted `launch` resolves to `{ kind: 'pkg' in process ? 'embedded' : 'node-script', executable: process.execPath }`.

Mode table (`execution.ts:148-188`):

| `executionMode` | Extra | `programFormat` | `retainsState` | Evaluator |
|---|---|---|---|---|
| `per-call` | | `function-body` | false | `AsyncFunction` body, strict |
| `persistent-in-memory` | `replScoped` true (default) | `scoped-repl` | true | one strict VM Script per call in a retained context, bindings copied forward |
| `persistent-in-memory` | `replScoped: false` | `repl` | true | `node:repl` |
| `vm-script` | `scriptPersistence: false` | `script` | false | `node:vm` Script with top-level-await lowering |
| `vm-script` | `scriptPersistence: true` | `script` | true | same, retained |

`executionInstructions` for `per-call`, verbatim: `The program is the body of an async TypeScript function; only erasable syntax is accepted, with no enum or namespaces. Type annotations are advisory. Top-level await and return are supported. Use inspect(...values) to display output. Do not use console. Each call runs in a fresh Node process. Node APIs are available through await import(...). Relative paths use the supplied working directory; process.env starts empty. Direct filesystem access follows this execution's sandbox policy.` The other modes' texts are long literals in `execution.ts:137-181` and must be copied from source.

`resolvePersistentExecution(programFormat)` (`configuration.ts`, entry `./configuration`) returns the three settings a profile editor merges to switch to retained execution: `script` gives `{ executionMode: 'vm-script', scriptPersistence: true, replScoped: false }`; `function-body`, `repl` and `scoped-repl` give `{ executionMode: 'persistent-in-memory', scriptPersistence: false, replScoped: true }`.

### `@deepseek-ai/dsh-experimental-ptc-runtime-python`

Service class `PythonPtcRuntime`, default export.

| Field | Default | Meaning |
|---|---|---|
| `cpuSeconds` | `60` | `RLIMIT_CPU` soft limit (hard is +1); positive integer |
| `maxWallMs` | `600000` | Wall deadline including sandbox setup; the only deadline |
| `addressSpaceMb` | `512` | `RLIMIT_AS`; not applied on Darwin |
| `maxLogBytes` | `65536` | Captured-output budget; at least 64 |
| `maxValueBytes` | `32768` | Completion-value budget |
| `graceMs` | `3000` | Termination grace |
| `pythonBin` | `'python3'` | Resolved, executable-checked and version-probed at load (CPython 3.10 or newer) |

### `@deepseek-ai/dsh-workflow-ptc`

Service class `PtcWorkflowEngine`, default export.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `provider` | string | `'spawn'` | `ctx.subagents` provider children run on |
| `maxConcurrentAgents` | natural | `0` | Concurrent `agent()` ceiling; `0` resolves at each start to `min(16, max(1, availableParallelism() - 2))` |
| `maxTotalAgents` | natural, min 1 | `1000` | Total `agent()` calls per run |
| `maxItemsPerCall` | natural, min 1 | `4096` | Items accepted by one `parallel()` or `pipeline()` |
| `syncTimeoutMs` | natural, min 1 | `5000` | VM timeout for the script's first synchronous slice |

### `@deepseek-ai/dsh-tool-workflow`

Function plugin: `name = 'tool-workflow'`, `inject = ['tools', 'workflowEngine', 'systemPrompt']`.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `toolName` | string | `'workflow'` | Registered tool name |
| `maxResultChars` | natural, min 1 | `50000` | Rendered JSON ceiling |
| `enableRunInBackground` | boolean | `true` | Expose and accept `run_in_background` |

### Shipped compositions

- Base bundle (`packages/bundle/base/cordis.patch.yml`): `id: ptc-runtime`, name `@deepseek-ai/dsh-ptc-runtime-node` (no config, so `per-call`); `id: workflow-ptc` with `provider: spawn`; `id: tool-workflow`; `id: tool-executor-native` enabled; `id: tool-executor-ptc` with `disabled: true`.
- Headless PTC patch (`apps/cli/config/examples/ptc.yml`): `- id: tool-executor-native` `disabled: true`; `- id: tool-executor-ptc` `disabled: false`; `- id: tool-fs` `config: { applyPatch: false }`.
- `pnpm run demo:ptc -- "task"` runs `node scripts/demo-ptc.mjs`, which spawns `node --import tsx/esm apps/cli/src/bin.ts --profile headless --patch apps/cli/config/examples/ptc.yml <task>` with inherited stdio. Default task: `Inspect this repository with PTC mode and report its top-level architecture.` Exit code is the child's code, or 1 on a signal. Needs a model credential.
- Web bundle (`packages/bundle/web-app/cordis.patch.yml`) disables `workflow-ptc` and `tool-workflow` at deployment scope; the `standard` and `cordis` presets re-declare them inside their `delegation` group.
- Web `ptc` preset (`packages/bundle/web-app/presets/ptc.patch.yml`): one inserted row `id: preset-ptc`, name `@deepseek-ai/dsh-agent-preset`, config `id: ptc`, `order: 2`, and this `plugins` list in order: `persona` (prefix `You are a coding agent powered by the {{model}} model.`), `agent-instructions` (`maxBytes: 65536`), `time-context`, `tool-bash` (disabled on `win32` through `!!js`), `tool-pwsh` (disabled off `win32`), `tool-fs` (`applyPatch: false`), `tool-fs-search` (`sampleOverCapGlobResults: false`), `tool-jobs`, `tool-schedule`, `skill-filesystem`, `tool-skill`, `command-goal`, `tool-goal`, group `planning` (`isolate: { planMode: true }`, containing `plan-mode` with its long `section` text), group `compaction` (`isolate: { compaction: true, toolResultPruner: true }`, containing `compaction-basic`, `command-compact`, `tool-result-pruner` with `thresholdChars: 8192`, `headChars: 4096`, `tailChars: 1024`), group `delegation` (`isolate: { workflowEngine: true }`, containing `tool-subagent-control` with `interrupt: false`, `tool-subagent` with `provider: spawn`, `toolName: subagent`, `modelSelection: true`, `modelDiscovery: true`, `tool-subagent-fork` with `provider: fork`, `toolName: subagent_fork`, `workflow-ptc` with `disabled: true`, `tool-workflow` with `disabled: true`), `tool-ask-user`, `tool-todo` (`allowParallelInProgress: true`), `tool-web` (`fetch: true`, `searchTimeoutMs: 60000`), `tool-executor-ptc` (no config), `present` (`@deepseek-ai/dsh-tool-present`), `tool-office`, `tool-plugin-manager` (`@deepseek-ai/dsh-plugin-manager/tools`, disabled), `tool-plugin-market` (disabled). The preset does not mount a runtime; it uses the deployment's `ptc-runtime`.

## Formats

### Node PTC control protocol, revision 3

Launch (`worker.ts:311-329`, `launch.ts`):

- `node-script` argv: `[<executable>, --max-old-space-size=<maxOldGenerationSizeMb>, --experimental-vm-modules, <bootstrap>, <maxMessageBytes>]`. `<bootstrap>` is `launch.bootstrapPath`, or the package's built `lib/process.js` mapped through `ctx.fs.processPathFromHostPath`. Under source launch the last two arguments are replaced by `--input-type=module --eval <source>`, where the source imports `openInheritedControlChannel` and `runNodeMain` by file URL and calls `runNodeMain(openInheritedControlChannel(), <maxMessageBytes>, process)`.
- `embedded` argv: `[<executable>, <maxMessageBytes>]` with env `DSH_PTC_RUNTIME_NODE=1` and `NODE_OPTIONS=--max-old-space-size=<n> --experimental-vm-modules`.
- When the policy mode is not `danger-full-access`, the argv is wrapped by `ctx.sandbox.confine(argv, policy, signal)`.
- Environment: every host variable is removed except `PATH`, `PATHEXT`, `SYSTEMROOT`, `WINDIR`, `TEMP`, `TMP` (compared upper-cased) and `ELECTRON_RUN_AS_NODE`. The child then deletes everything but the six startup names from the OS environment and replaces the program-visible `process.env` with an empty null-prototype object (`environment.ts:52-58`).
- Stdio: stdin ignored; stdout and stderr piped (raw program output); `control: 'pipe'`. The subprocess provider passes a duplex byte channel at fd 7 and sets `DSH_SUBPROCESS_CONTROL=pipe`; the child consumes and deletes that marker before any program code runs.
- `cwd` is the resolved working directory.

Framing (`rpc.ts`): UTF-8 JSON objects, one per line, terminated by `\n` (byte 10). The first byte of every message must be `{`, otherwise the endpoint fails with `control message is not a JSON object; the Node bootstrap may be from another release`. An incoming line longer than `maxMessageBytes` fails with `RPC message exceeds <n> bytes`. An outgoing write that would raise the queued byte count above `maxMessageBytes` fails with `control output exceeds <n> queued bytes`. Stream end with a partial line: `incomplete RPC message`; clean end: `control channel ended before the program settled`; close: `control channel closed`. The failure callback receives a kind: `'io'`, `'closed'` or `'protocol'`. After closure no method runs, including calls that arrived in the same chunk.

Envelope (birpc 4.2.0, verified against `tests/fake-child.ts`, `tests/rpc.spec.ts`, `tests/host-failures.spec.ts`):

- Request: `{"t":"q","i":"<id string>","m":"<method>","a":[...args]}`.
- Notification (no reply expected): the same without `i`.
- Success reply: `{"t":"s","i":"<id>","r":<result>}`.
- Error reply: `{"t":"s","i":"<id>","e":{"message":"<text>"}}`. Only the message crosses. A call to a method that is not an own property of the local function table gets `[birpc] function "<name>" not found`.
- No RPC-level timeout.

Methods the child calls on the host (`HostMethods`, `protocol.ts:37-69`):

| Method | Form | Arguments | Meaning |
|---|---|---|---|
| `ready` | notification | `[version: number]` | Sent once after the child adopts the channel. The host requires `3`. |
| `initialized` | request | `[]` | Environment initialization succeeded; the child awaits the reply before running user code. |
| `invoke` | request | `[global: string, name: string, args: PtcJsonWire]` | Call a host binding. The reply value is a `PtcJsonWire`. |
| `log` | notification | `[text: string]` | One captured text fragment. |
| `image` | notification | `[id: string]` | Emit a registered image at the current output position. |
| `outputLimit` | notification | `[]` | The child's output budget is exhausted. |

Methods the host calls on the child (`ProgramMethods`, `protocol.ts:72-83`):

| Method | Form | Arguments | Meaning |
|---|---|---|---|
| `run` | request | `[cwd: string, data: ProgramBootData]` | Evaluate one program. Replies with `ProgramResult` after captured output is sent. |
| `revoke` | notification | `[]` | Stop accepting binding calls and output for the current evaluation and reject its pending calls. `run` still owns completion. |

`ProgramBootData` (`protocol.ts:9-28`): `code: string` (type-stripped JavaScript); `initialization?: string`; `programFormat?: PtcProgramFormat`; `retainsState: boolean`; `discardCompletion?: boolean`; `namespaces: { global: string; names: string[]; errorClass?: { name: string; memberNameProperty: string } }[]`; `maxOutputBytes: number`.

`ProgramResult`: `{ value?: PtcJsonWire; error?: { kind: 'exception' | 'invalid-output' | 'output-limit'; message: string } }`. The host validates it (`readProgramResult`, `protocol.ts:91-104`): a non-object, a malformed `error`, or an unknown kind is a protocol failure; a `value` that fails wire decoding becomes `invalid-output` with `program completion must be lossless JSON`.

`PtcJsonWire` (`json-wire.ts:240-309`): a flat, non-empty array holding a pre-order token stream for one JSON value, so serialization depth is independent of value depth. Tokens: `null`, booleans, finite numbers other than `-0`, strings, `{"kind":"array","length":N}` followed by N values, `{"kind":"object","keys":["k1",...]}` followed by one value per key in order, and `{"kind":"image","id":S,"attachmentId":S,"path":S,"width":N,"height":N}`. Examples: `5` is `[5]`; `{"a":[1,2]}` is `[{"kind":"object","keys":["a"]},{"kind":"array","length":2},1,2]`. Decoding rejects: an empty or sparse array; marker objects with extra or missing fields; duplicate or non-string keys; a negative or non-safe-integer `length`; counts larger than the remaining tokens; an image token when the decoder was given no image handler; image fields that are empty strings or non-positive or non-integer sizes; leftover tokens; unfinished containers.

Lossless JSON (`snapshotPtcJsonValue`, `json-wire.ts:151-238`): accepts `null`, booleans, strings, finite numbers except `-0`, dense plain arrays without extra own keys, and plain or null-prototype objects whose own keys are all enumerable strings. Rejects `undefined`, functions, symbols, bigints, cycles (a value repeated as a sibling is fine), sparse arrays, class instances, accessor failures. The traversal is iterative.

### Python fd-3 protocol

One JSON object per line on the child's file descriptor 3 (`py/protocol.py`, `src/protocol.ts`). Host to child: `{"type":"boot","cpuSeconds":N,"addressSpaceBytes":N,"maxLogBytes":N,"maxValueBytes":N,"namespaces":[{"global":S,"names":[S],"errorClass"?:{"name":S,"memberNameProperty":S}}]}`, then after the ack `{"type":"run","program":S}`, then one reply per call: `{"type":"reply","id":N,"ok":true,"value":V}` or `{"type":"reply","id":N,"ok":false,"message":S}`. Child to host: `{"type":"boot-ack"}`; `{"type":"call","id":N,"global":S,"name":S,"args":V}`; `{"type":"log","text":S,"truncated"?:B,"open"?:B}`; `{"type":"done","value"?:V,"error"?:{"kind":"exception"|"invalid-output"|"output-limit"|"timeout","message":S}}`. When both `value` and `error` are present the host uses `error`. The bootstrap and protocol sources are sent to the interpreter as UTF-8 JSON on stdin. The child environment holds only `TMPDIR`. Truncation marker text: `[dsh-ptc-runtime-python] log capture truncated at <N> bytes`.

### Workflow guest binding protocol

The workflow engine runs this program through `ctx.ptcRuntime` (`workflow-ptc/src/host.ts:26-27`):

```js
const { runWorkflowGuest } = await import("data:text/javascript,<encodeURIComponent(WORKFLOW_GUEST_SOURCE)>"); return await runWorkflowGuest(workflowHost);
```

For `repl` and `scoped-repl` it is wrapped as `await (async () => {\n<PROGRAM>\n})()`; for `script` as `(async () => {\n<PROGRAM>\n})()`. Request fields: one binding namespace `{ global: 'workflowHost', functions }` without an error class; `cwd`; `sandboxPolicy` when the runtime confines; `timeoutMs: null`; `signal`; no state owner; completion kept.

`workflowHost` functions, all taking one JSON argument (`guest-types.ts`):

| Function | Argument | Result |
|---|---|---|
| `begin` | `{}` | `WorkerInit`: `{ meta, body, args?, limits: { maxConcurrentAgents, maxTotalAgents, maxItemsPerCall, syncTimeoutMs } }` |
| `startChild` | `{ prompt: string, schema?: object, provider?: string, model?: string }` | `{ callId: number, childId: string }` |
| `childResult` | `{ callId }` | `{ output: ContentBlock[], stopReason: string, structured?: json }`; rejects on infrastructure failure or cancellation |
| `disposeChild` | `{ callId }` | `null` |
| `progress` | array of `{ type: 'phase', title }`, `{ type: 'log', message }`, `{ type: 'agent-start', info }`, `{ type: 'agent-end', info }` | `null` |

The program's completion value is the `WorkflowResult` object, which the host re-validates (`host.ts:95-106`). `WORKFLOW_GUEST_SOURCE` is a generated, self-contained ESM module (imports only `node:vm`) ending in `//# sourceURL=dsh-workflow-guest.js`; `scripts/gen-workflow-guest.ts --check` rejects a stale copy.

### Other formats

- Sub-call id: `<outer callId>:ptc:<n>`, `n` counted from 1 per `run_code` execution in submission order, counting rejected attempts. Consumers treat ids as opaque.
- Workflow run id: `randomUUID()`.
- Subpath entries: `dsh-tool-executor-ptc/run-code`, `/types`, `/client`; `dsh-ptc-runtime-node/configuration`; `dsh-workflow/types`.
- Environment variables: `DSH_SUBPROCESS_CONTROL=pipe`, `DSH_PTC_RUNTIME_NODE=1`, `NODE_OPTIONS` (embedded launch only), `ELECTRON_RUN_AS_NODE` (preserved for startup).

## Algorithms and invariants

### A. `run_code` execution (`tool-executor-ptc/src/ptc.ts:392-814`)

1. Reject a blank `description`. Read the runtime.
2. Admission. If the call has no agent, or the runtime neither confines nor retains state, run directly with the outer signal. Otherwise go through `PtcCalls.run(sessionId, signal, currentMode, run)` (`ptc-calls.ts:54-83`): loop, awaiting any pending reset for the session (a failed reset throws the `Program environment unavailable` error) and awaiting every call of the session whose signal is already aborted; then check the caller signal and disposal; record `{ mode, controller, signal: any(caller, controller), done }`; run; always remove the record and resolve `done`. A committed `sandbox/mode` event whose mode differs from a call's recorded mode aborts that call with `Error('sandbox mode changed')`. Executor disposal aborts every call with `Error('PTC tool executor disposed')` and waits for all calls and resets.
3. Inside `run(callSignal)`: validate the escalation pairing and `timeoutMs`; resolve the standing policy (`sandboxPolicy.resolve({ session })`, or `{}` without an agent) when the runtime confines; if escalation was requested, await approval and set `policy = { ...standingPolicy, mode: approvedMode }`; resolve the working directory with `workingDirectory.ensure(agent, signal)`; re-check the signal.
4. Create a run-scoped abort controller that follows the outer signal and is also aborted with the reason `<toolName> settled` when the runtime returns, for any reason.
5. Enumerate bindings: `ctx.tools.schemas(agent, toolSet)` (step-admitted visible tools; `run_code` is not among them), deep-freeze each schema, and define one binding per name on a null-prototype object with `Object.defineProperty`.
6. For an agent-owned call, register once per (agent, underlying provider) an effect on the agent's context that calls `runtime.release(agent)` when the agent is disposed. The underlying provider is found by following `symbols.original` on the service proxy.
7. `spec = runtime.resolve({ program: args.code, discardCompletion: true (typescript only), stateOwner: agent (only with an agent and only when the effective mode equals the standing mode), bindings: [{ global: 'tools', functions, errorClass: { name: 'ToolCallError', memberNameProperty: 'toolName' } }], signal: runController.signal, cwd?, sandboxPolicy?, timeoutMs? })`.
8. `maxSubCalls = spec.timeoutMs === null ? Infinity : floor(spec.timeoutMs / 60000 * maxSubCallsPerMinute)`. Default Node: `floor(120000 / 60000 * 1024) = 2048`.
9. `result = await runtime.run(spec)`. In a `finally`: abort the run controller, then drain dispatches (step C). Queued but unstarted sub-calls are abandoned without events; started ones settle and are logged before `run_code` returns, even when the runtime itself rejected.
10. Map the result as described under Tools. `result` is included in the value only for non-TypeScript runtimes.

### B. One binding call (`ptc.ts:554-712`)

1. If the run is over: reject `<toolName> run is over (<reason>); <name> not dispatched`.
2. `n = ++attempts`, counted before validation so failed attempts also consume the allowance. If `n > maxSubCalls`: create `ToolCallLimitExceededError`, abort the run controller with it, and reject. The runtime then stops the program through its abort path; catching the rejection inside the program cannot keep it alive.
3. Normalize arguments to lossless JSON twice: one copy is dispatched, a sibling copy is logged, so a tool that mutates its arguments cannot desynchronize the log. Non-JSON arguments reject with ``tool arguments must be lossless JSON (call the tool with an arguments object, e.g. `{}`)`` (or `tool arguments must be lossless JSON: <detail>`) and nothing is dispatched.
4. Build the pipeline input: `{ callId: '<outer>:ptc:<n>', rootCallId: exec.rootCallId, name, schema, arguments, agent?, toolSet?, parent: exec.token, signal: runController.signal }`. `parent` is the outer execution's opaque token. It marks the call as nested (so the PTC-only denial does not apply) and lets result observers correlate with the outer call without receiving its mutable execution.
5. Enqueue a pending dispatch and wake the driver. The returned promise resolves when the scheduler commits the result.
6. After the result arrives: if the run ended meanwhile, reject `...; <name> result discarded`. If the sub-call failed, reject with `Error(result.error.message)`; the child wraps it as `ToolCallError` and adds only the tool name, so native content and error metadata do not reach the program. Otherwise resolve with the tool's canonical `value` (the structured output, not the rendered content).

Denials: a `tools/pre-execute` deny, a failed guard, an approval rejection or a cancelled approval produce an error result in `prepare`; the program sees a `ToolCallError` whose message is the denial reason, and the `tool/ptc-dispatch` event keeps the original error identity in `error`. A tool that was unregistered between enumeration and dispatch fails as unknown tool.

Images (`ptc.ts:557`, `:663-710`): for a TypeScript runtime and the tools named `read_image` and `cua`, a result with exactly one image block resolves to a `PtcImage` built from the attachment's host path mapped into the program's filesystem (missing mapping: `Image storage must expose a readable path in the program filesystem`). If a post-execute policy removed the image the call rejects with `Image output was removed by a tool output policy.\n<remaining text>`. `read_image` without exactly one image, or more than one image, rejects with `Image-producing tools must return exactly one image`. For every other tool and for Python, a successful result containing an image is deferred as a user message `{ content: result.content, source: { kind: 'ptc-mode' } }` on the outer result, so the model sees it on the next step.

Forwarding: each nested result's `additionalContexts` are deferred onto the outer execution in commit order; a nested success with `concludesTurn` calls `exec.concludeTurn()`.

### C. The sub-dispatch scheduler (`ptc.ts:448-547`)

State per run: `pendingQueue` (submission order), `commitQueue` (start order), `inFlight` (running bodies), `logWork` (event-append tasks), `exclusiveActive`. One driver loop processes all ordered stages, so ordered policy stages never overlap; only tool bodies overlap.

Each driver pass:

1. If the head of `commitQueue` is settled: remove it and await `commit()`: `executor.complete(exec, parked)` (post-execute, content finalization, result observers), image deferral, context forwarding, `concludeTurn`, then `settle` (resolve the program's promise immediately and start the log task), then, while `logWork.size > maxParallel`, wait for one log task (backpressure). After `commit()` returns, clear `exclusiveActive` if the entry started as exclusive, so the barrier covers post-execute. Continue.
2. Else if `pendingQueue` has a head: if the run is aborted, remove it and reject it as abandoned (`...; <name> tool call abandoned`), continue. Otherwise classify it now with `executor.executionMode(input).kind` (only a tool whose `isConcurrencySafe(args)` returns exactly `true` is `parallel`; unknown, hidden, throwing or undeclared is `exclusive`). Capacity is `!exclusiveActive && (exclusive ? inFlight.size === 0 : inFlight.size < maxParallel)`. With capacity: set `exclusiveActive` for an exclusive call, move the entry to `commitQueue`, and await `start()`: append `tool/ptc-dispatch-start`, await `executor.prepare(input)` (input snapshot, token, pre-execute waterfall, approval, guards); if it returns `dispatch`, launch `executor.dispatch(exec)` as the flight (around-dispatch and tool body) and mark the entry settled when it finishes; otherwise park the immediate result and mark settled. Track the flight; continue.
3. If all three collections are empty, return (quiescence). Otherwise sleep until a body settles or a submission arrives. The wake promise is created before inspecting state so a wake cannot be lost.

Guarantees to reproduce: starts are strictly in submission order; results commit in submission order through the head-of-line cursor even when bodies finish out of order; consecutive parallel-safe calls overlap up to `maxParallelSubCalls`; an exclusive call waits for the pool to drain, runs alone, and blocks later starts until its commit completes; classification is re-read immediately before each start; the program receives its value before the log listener and append run; every `tool/ptc-dispatch` append happens before `run_code` returns (`drainDispatches` runs the driver to quiescence and then awaits `logWork` until empty).

The settle log task: await `shapeDispatchLog` (the contained `tools/ptc-dispatch-log` waterfall), then `agent.session.append('tool/ptc-dispatch', ...)`.

### D. Host reset (`index.ts:73-86`, `ptc-calls.ts:93-114`)

`PtcExecutor.reset(agent)`: requires `runtime.retainsState` (else `CodeResetFailedError('The PTC runtime does not retain an environment')`, code `CODE_RESET_FAILED`). `PtcCalls.reset(sessionId, release, notify)`: concurrent resets share one promise; abort every call of the session with `Error('PTC environment reset')`; in parallel run `runtime.release(agent)` and await every call's `done`; on any failure the reset stays registered and rejected, which blocks new programs until a later reset succeeds; on success call `notify`, which injects a user message `Program environment reset; retained variables cleared. Completed tool effects remain.` with source `{ kind: 'ptc-mode' }`, then clear the reset. Failures surface as `Program environment reset failed: <cause>. State may not be cleared; retry the host reset before running more code.`

### E. Node provider: admission and process ownership

`NodePtcRuntime.run` (`index.ts:119-144`): reject after disposal or while an initializer removal is incomplete; mark admitted; when the spec carries a policy with a session id, register with `PolicyProcesses` so a `sandbox/mode` change to another mode aborts this run with `Error('sandbox mode changed')` and waits for it; await cleanup of earlier invalidated processes of the same session; combine the caller signal with the internal controller; delegate to `NodeExecution.run`.

`NodeExecution.resolve` (`execution.ts:73-78`): `sandboxPolicy = request.sandboxPolicy ?? ctx.sandboxPolicy.resolve()`; `cwd = request.cwd ?? sandboxPolicy.workspaceRoot` (must be absolute); `timeoutMs = null` when requested `null`, else `min(requested ?? config.timeoutMs, config.maxTimeoutMs)` with a throw for a non-finite or non-positive request.

`NodeExecution.run` (`execution.ts:86-114`): validate the spec and bindings; `owner = retainsState ? spec.stateOwner : undefined`; reuse the owner's `ProgramWorker` when it exists, is open and idle, and its policy has the same `mode`, `workspaceRoot` and `sessionId` (a different policy throws `persistent PTC: release the retained environment before changing its sandbox policy`; a busy worker throws `persistent PTC does not accept concurrent runs for one state owner`); otherwise create a worker with a snapshot of the policy. Owners are held in a `WeakMap`. Without an owner the worker is temporary and is terminated when its evaluation ends.

`PolicyProcesses` (`policy-processes.ts`): on a `sandbox/mode` event for a session, every registered entry of that session with a different mode is marked invalidated and its release starts immediately (without delaying the permission setter); `wait(sessionId)` awaits invalidated entries before a new program is admitted; a failed release stays retryable.

Binding validation (`bindings.ts:11-52`) throws before any process starts: `dsh-ptc-runtime-node: binding global "<g>" is not a usable identifier`, `reserved binding global "<g>"`, `duplicate binding global "<g>"`, `binding error class "<n>" is not a usable identifier`, `duplicate injected global "<n>"`, `binding error member property "<m>" is not usable`.

### F. Node provider: one evaluation (`worker.ts:116-221`)

1. If the process already exited: terminate and return `abort` (`execution canceled`) when the signal is aborted, else `worker-exit` with the exit message. A retained worker appends `; retained variables were cleared` to either message.
2. Create an `OutputLedger(maxOutputBytes)`. Arm a timer when `timeoutMs !== null`. On expiry: message `execution timed out <phase> (<timeoutMs>ms)` with `<phase>` `before code started` (the program was not yet submitted to a ready process) or `during execution`; kind `timeout`.
3. Abort listener: kind `abort`, message `execution canceled` for a retained worker, otherwise the string form of the signal reason.
4. If the signal is already aborted, finish as abort. Otherwise strip types in the host. For `function-body` the program is wrapped as `async function __dsh_program__() {\n<program>\n}` for stripping and the wrapper is cut off again (`execution.ts:135-158`). A stripping error finishes the run with kind `exception` and the parser message; no process is started for it.
5. If the worker's process is ready, send `run`. Otherwise start the process; the `ready` notification triggers `run`. Startup failures finish as `sandbox-unavailable` (confinement or runner spawn failure) or `worker-exit`.
6. Output: every chunk the host reads from the child's stdout and stderr pipes (UTF-8) and every `log` notification is admitted to the ledger as a text entry; `image` notifications append image entries. Stderr is also kept as a tail of at most `maxOutputBytes` characters for exit diagnostics.
7. `invoke` handling (`worker.ts:376-406`): refuse (protocol failure) without an active evaluation; reject with `PTC evaluation ended before the binding completed` when the evaluation has settled; look the function up as an own property; for a non-retained worker an undeclared name is a protocol failure `program requested an undeclared binding`, for a retained one the call rejects with `binding is unavailable in this evaluation; reacquire the current tool`; decode arguments (`binding arguments must be lossless JSON` is a protocol failure); refuse when `pending >= maxPendingCalls` or outstanding argument bytes plus this call exceed `maxMessageBytes` (`pending binding calls exceed configured limits`); call the binding in the async context captured when the evaluation was created; snapshot the result (`binding resolution must be lossless JSON`), registering any `PtcImage` under a fresh UUID in the worker's image table and encoding it as an image token; discard a result that arrives after settlement.
8. The `run` reply: ignored when already settled; a success while initialization is still pending is a protocol failure `environment initialization completed without Host acceptance`; otherwise the result is applied on the next event-loop turn so raw stdio queued beside it is admitted first.
9. Protocol violations finish the run with kind `protocol` (plus `; retained variables were cleared` for a retained worker) and terminate the process: wrong version (`bootstrap protocol mismatch; upgrade launch.bootstrapPath with the host`), `duplicate program readiness`, `unexpected environment initialization acknowledgement`, `invalid program log`, `invalid program image`, `idle PTC output limit`, plus the RPC framing failures.
10. Process exit before settlement: `worker-exit` with `Node process exited (<code>, signal <signal>)[: <stderr tail>][; control channel failed: <io error>]`, or `sandbox-unavailable` when the sandbox runner's failure rules match the exit code and stderr.

Settlement (`finish`, `worker.ts:170-201`), executed at most once per evaluation:

1. Clear the timer and the abort listener. The deadline covers setup and execution but not cleanup.
2. Compute the outcome: `ledger.limit(output)` on overflow or an `output-limit` error; `ledger.failure(output, error)` on error; `ledger.success(output, value)` otherwise.
3. `preserved = retainsState && initialization complete && !discard && outcome is not output-limit`. For a timeout or abort with `preserved`, call `revoke()` and wait at most `stopGraceMs` for the original `run` reply; only a validated reply keeps the process. If not preserved, terminate: close the channel, `handle.terminate()`, await exit, drain stdout and stderr for at most `graceMs`, destroy the streams.
4. For a retained worker and a timeout or abort, append `; retained variables were preserved` or `; retained variables were cleared` to the message.
5. If output did not drain cleanly: `worker-exit` `managed process exited but its output did not drain cleanly`. If cleanup threw: `worker-exit` `managed process cleanup failed: <cause>`, and the worker stays blocked until `release` succeeds.

A non-retained worker is therefore terminated after every evaluation, successful or not.

Sandbox facts (`worker.ts:93-105`): `sandbox = { mode: policy.mode, denied: false }`; with confinement, `enforcement` comes from the confined argv and `denied` is true when the error kind is not `sandbox-unavailable` and the error message contains, case-insensitively, one of the backend's `denialSignatures`.

Provider disposal aborts every live run with the reason `runtime disposed`, disposes every worker (active evaluations finish as `abort` `PTC environment disposed`), and awaits all of it.

### G. Output accounting

The budget counts the bytes of the JSON serialization of the output array plus the completion value or failure message.

- String cost (`output-json.ts:65-90`): 2 for the quotes; `"` and `\` cost 2; code units below 0x20 cost 2 for `\b \t \n \f \r` and 6 otherwise; a lone surrogate costs 6; an astral code point costs 4; everything else costs its UTF-8 length.
- Value cost (`jsonValueBytesUpTo`): `null` 4, `true` 4, `false` 5, a number the UTF-8 length of JavaScript `String(n)`, containers 2 plus 1 per separator, object keys their string cost plus 1 for the colon.
- Host `OutputLedger` (`output-ledger.ts`): starts at 2 bytes (`[]`); each entry costs its bytes plus 1 separator after the first; an image entry costs the JSON bytes of `{ type, attachment }`. On the first entry that does not fit, the host records overflow and finishes the run as `output-limit`. `limit(output)` rebuilds the result: reserve the bytes of the diagnostic (`outer output exceeded <max> bytes`, or `retained variables were cleared; outer output exceeded <max> bytes` for a retained worker), keep entries in order while they fit, cut the first text entry that does not fit to its longest code-point-aligned prefix, stop at the first image that does not fit, and truncate the message itself if even it does not fit. `success` fails with the limit result when the value does not fit the remaining bytes; `failure` does the same for an oversized message.
- Child `LogBuffer` (`bootstrap.ts:51-103`): the same arithmetic over `maxOutputBytes`; on overflow it sends the fitting prefix, then `outputLimit()` once, then drops further text. `prepareCompletion` and `prepareException` replace a value or message that does not fit the remaining budget with `{ error: { kind: 'output-limit', message: 'outer output exceeded <max> bytes' } }`.
- Binding arguments and results never enter this ledger.

### H. The Node child (`process.ts`, `bootstrap.ts`)

`runNodeMain(stream, maxMessageBytes, process, defaultFormat, importHandler?)`: clear the environment; suppress the two experimental-feature warnings the runtime itself triggers; patch `process.stdout.write` and `process.stderr.write` to push into the active evaluation's log (the callback is invoked asynchronously with `null`); create the RPC endpoint; send `ready(3)`; serve until the channel closes. On channel failure during an active evaluation or on a protocol failure, set `process.exitCode = 1`.

`run(cwd, data)` (`process.ts:118-217`): reject an overlapping evaluation (`overlapping PTC evaluation`); create the log buffer; `process.chdir(cwd)` (every evaluation resets the directory); create the evaluator once per process for `data.programFormat`; install globals; evaluate `initialization` when present (its failure is reported as the run's exception; log overflow is `output-limit`), then `await initialized()`; evaluate `code`; finish with `{}` when `discardCompletion`, else the wire-encoded completion, else the rendered exception.

Globals the program sees:

- `tools` (and any other namespace): a null-prototype object with one enumerable async function per declared name (`makeNamespaces`, `bootstrap.ts:308-342`). Each takes one argument, snapshots it as lossless JSON (failure: `binding arguments must be lossless JSON`), calls `invoke`, decodes the reply (failure: `binding resolution must be lossless JSON`) and returns it. Any failure is rethrown as the namespace's error class.
- `ToolCallError` (the declared error class): a real `Error` subclass constructed as `new C(memberName, message)`, with enumerable own data properties `name` (the class name) and `<memberNameProperty>` (the member name).
- `inspect(...values)` (`makeInspect`, `bootstrap.ts:113-163`): strings are rendered as-is, other values with `util.inspect(value, { depth: null, maxArrayLength: null, maxStringLength: null })`. Rendered arguments are joined with one space and flushed as one text entry ending in `\n`. An argument that is a registered `Image` flushes pending text and emits the image. Images reached during formatting of a nested value are emitted after that argument's text. A call with no arguments emits `\n`. If formatting throws, text rendered so far is flushed and the error propagates.
- `Image`: a class whose constructor throws `Images are created by image-producing tools`. Instances are frozen objects with enumerable `attachmentId`, `path`, `width`, `height`, created only by decoding image tokens; a `WeakMap` maps them to host image ids, so a forged look-alike object is formatted as plain data.
- `process`: the real process object with an empty `env`.
- `console`: installed explicitly for the non-function-body formats; in `function-body` the realm's native console is reachable anyway. Console output reaches the result through the patched stream writes.
- In `function-body`, the globals above are parameters of `new AsyncFunction(...names, "'use strict';\n" + code)` called in the main realm, so all Node globals (`fetch`, `Buffer`, timers, `globalThis`) are visible and modules load with `await import(...)`; there is no `require`.

Evaluation ownership: an `AsyncLocalStorage` store identifies the evaluation a callback belongs to. After an evaluation ends, its callbacks cannot log, emit images or start bindings. For a temporary process a late or unfinished binding call never settles (the process is about to be killed). For a retained process pending calls are rejected with `PTC evaluation ended`; after `revoke` they reject with `PTC evaluation canceled`, which lets the program's `catch` and `finally` run before `run` replies.

Evaluators (catalog depth):

- `function-body` (`evaluators/async-function.ts`): described above; completion is the function's return value.
- `repl` (`evaluators/repl.ts`): `node:repl` with `useGlobal: false`, `terminal: false`, `ignoreUndefined: true`; a program starting with `{` is prefixed with `;`; `_` and `_error` are plain globals; REPL diagnostics written to its output are reported as the active evaluation's exception.
- `script` (`evaluators/vm-script.ts`, `vm-script-await.ts`): a `vm` context populated with the main realm's globals; source containing `await` is lowered with an adaptation of Node's REPL await transform (acorn and acorn-walk), which hoists top-level declarations; the final expression is awaited; filename `<cwd>/ptc-program.js`.
- `scoped-repl` (`evaluators/scoped-repl.ts`, `scoped-repl-evaluator.ts`): each program is parsed with acorn as a script with top-level await; its top-level declarations and hoisted `var`s are listed; source is generated as `"use strict";(function (__$binding_vals, __$binding_getters) { return async function () { <var|let copies of earlier bindings> <push one getter per binding>\n<program with the last expression statement rewritten to return { value: (<expr>) }>\n} })` and compiled with `lineOffset: -1` in one retained context created with `codeGeneration: { strings: false, wasm: false }`. After a program's body has started, its getters supply the values copied into the next program. A redeclared `let`, `const` or `class` that never finished initializing falls back to the value it replaced. Programs starting with `#!`, containing `__$binding_`, or using top-level `return` are syntax errors. A final Promise is not awaited. Uncaught asynchronous errors are routed through a `node:domain` to the active evaluation as `Uncaught <description>`. Filenames are `<first cwd>/.ptc-repl-<n>.js`.
- Import interception (`imports/*`) is a runner-side extension point with no shipped configuration: the default entries pass no handler, so programs use Node's loader.

### I. Python provider (catalog depth)

One fresh CPython process per run, spawned under the sandbox runner in its own process group with the working directory as cwd. The host sends `boot`; the child applies `RLIMIT_CPU` and `RLIMIT_AS` and answers `boot-ack`; the host sends `run`. The program body is spliced by AST into `async def __dsh_main__()` and executed as `__main__`, so top-level `await` and `return` work. Each namespace is a `_Namespace` proxy: `tools.name(args)` and `tools["name"](args)` return a coroutine that posts a `call` frame and awaits its `reply`; an undeclared name raises `AttributeError` or `KeyError`. A failed call raises the declared error class (minted with `type(name, (Exception,), ...)`, carrying `<memberNameProperty>`), or `RuntimeError` without one. `print` and stream writes become `log` frames metered against `maxLogBytes`; the return value is metered against `maxValueBytes` and must be lossless JSON. Host limits: 1024 in-flight calls, 1024 queued replies, 1024 pending line fragments, a 64 MiB frame cap (lower on a small host heap); exceeding any is `worker-exit`. The wall deadline message is `wall-clock ceiling reached (<maxWallMs>ms)`. Teardown signals the process group. The host rebuilds every inbound frame field by field and ignores malformed frames. Execution instructions, verbatim: `The program is the body of an async Python function. Top-level await and return are supported. Emit output with print(...) or return a lossless JSON value. Only printed values and the returned value become program output. Each call runs in a fresh Python process; variables and imported modules do not persist across calls. Relative paths use the supplied working directory; only TMPDIR is set in the environment. Direct filesystem access follows this execution's sandbox policy.`

### J. Workflow engine (`workflow-ptc`)

`start(request)` (`index.ts:134-189`), all synchronous:

1. `validateMeta` (`meta.ts`): collect every violation and throw `META_INVALID` `invalid meta: <v1>; <v2>; ...`. Violation texts: `meta must be an object`; `meta.<key> is not a recognized field (name/description/whenToUse/phases)`; `meta.name must be a non-empty string`; `meta.description must be a non-empty string`; `meta.whenToUse must be a string`; `meta.phases must be an array`; `meta.phases[i] must be an object`; `meta.phases[i].<key> is not a recognized field`; `meta.phases[i].title must be a non-empty string`; `meta.phases[i].detail|provider|model must be a string`. The result is a normalized copy.
2. Body pre-check: a body matching `/^\s*export\s+const\s+meta\b/` throws `SCRIPT_PARSE` (``workflow meta rides the `meta` request field, not the script: remove the `export const meta = {...}` statement from the body``). Otherwise compile, without running, `(async () => {\n<body>\n})()`; failure throws `SCRIPT_PARSE` `workflow script does not parse: <error>`. TypeScript-only syntax fails here.
3. Provider: `request.subagentProvider ?? config.provider`; empty or untrimmed throws `INVALID_ARGUMENT`; unregistered throws `AGENT_START` `no subagent provider registered for "<p>"`.
4. `maxTotalAgents`: the request value must be a positive safe integer not above the configured ceiling (`INVALID_ARGUMENT`), else the ceiling.
5. Mint the run id, copy `args` with a structured clone, resolve the calling session's sandbox policy, construct `PtcWorkflowRun`, emit `workflow/start`, and arrange `workflow/end` on settlement.

`PtcWorkflowRun` (`host.ts:113-323`):

- The constructor wires the external signal to `cancel('workflow signal aborted')`, starts resolving the working directory once (later children reuse it even when the parent session moves), and schedules `drive()` on a microtask so the caller can attach recording first.
- `cancel(reason = 'workflow cancelled')`: the first call wins; aborts the run controller (which aborts the PTC program) and starts disposing every published child. `dispose()` cancels with `workflow disposed` and returns the shared `result.then(() => {})`.
- `drive()`: await the directory; if the runtime cannot confine and the policy mode is not `danger-full-access`, fail with `workflow runtime cannot enforce the <mode> file policy`; run the guest program. Result mapping: a recorded cancel reason gives `{ value: null, stopReason: 'cancelled', error: 'workflow run cancelled: <reason>', agentsStarted }` even when completion raced it; a runtime error gives `stopReason: 'error'`, `error: 'workflow execution failed (<kind>): <message>'`; otherwise the validated guest result. In `finally`: abort the controller with `workflow settled`, dispose every child, await every tracked binding promise until none remain (a late provider publication is disposed too), and synthesize `agent-end` with `outcome: 'cancelled'` for members still open.
- `startChild`: `callId = ++started`; `subagents.startActivation({ provider, label: '<meta.name> child <callId>', delivery: 'caller', signal, cwd, prompt: [{ type: 'text', text }], parent, outputSchema?, agentOptions?: { provider?, model? } })`; a child published after cancellation is disposed and the call rejects with `workflow child started after cancellation`.
- `childResult`: race the child's result against the abort signal; reply `{ output, stopReason, structured? }`.
- `disposeChild`: once per child; a throwing dispose is logged (`workflow-ptc: child dispose failed: ...`) and still acknowledged.
- `progress`: validates each event, rejects after cancellation, forwards to the engine's emitters; an `agent-end` for an unknown or already ended `seq` is dropped.

Guest (`guest.ts`): `begin`, then run the script; progress events are batched with one `progress` call in flight (events produced meanwhile go into the next batch); a rejected batch is remembered, later events are dropped, and the final result becomes `stopReason: 'error'` with that message; child disposal waits for the progress queue to drain so observers see the start before the registration disappears.

Script execution (`runtime.ts`): compile `(async () => {\n<body>\n})()` with filename `workflow:<meta.name>` and `lineOffset: -1`; run it in a fresh `vm` context whose only globals are the six script globals (`agent`, `parallel`, `pipeline`, `phase`, `log` as frozen functions, and `args`), with `timeout: syncTimeoutMs` applied to the first synchronous slice. An `undefined` return becomes `null`; any other return is materialized as plain JSON (`realm.ts`: rejects non-finite numbers, bigints, functions, symbols, nested `undefined`, cycles, sparse arrays, arrays with extra properties, symbol keys, and objects whose prototype is neither `null` nor a prototype with a `null` prototype; messages carry a path such as `workflow result.items[2]`), failing as `RESULT_UNSERIALIZABLE`. A throw becomes `stopReason: 'error'` with the rendered stack, message or string. Promises returned by the hooks get a no-op rejection handler so a dropped promise cannot crash the process.

`agent(prompt, opts)` (`runtime.ts:163-229`): the prompt must be a non-empty string (`INVALID_ARGUMENT`); options are materialized and validated (non-object `INVALID_ARGUMENT`; `effort`, `isolation`, `agentType` give `UNSUPPORTED_OPTION` "deferred"; other unknown keys `UNSUPPORTED_OPTION`; non-string `label`, `phase`, `provider`, `model` `INVALID_ARGUMENT`; a schema outside the object-rooted subset `UNSUPPORTED_SCHEMA`); at the total cap throw `AGENT_CAP`; `seq = ++started`; `label = opts.label ?? first line of the prompt, cut to 47 characters plus '…' when longer than 48`; `phase = opts.phase ?? current phase`; acquire a concurrency slot (FIFO); start the child (failure `AGENT_START`); report `agent-start`; await the result. Outcomes: a rejected result reports `failed` and throws fatal `AGENT_RESULT`; `stopReason === 'completed'` with a schema returns `structured`, or reports `failed` and returns `null` when it is missing; `completed` without a schema returns the concatenated text blocks; any other stop reason reports `failed` and returns `null`. Always dispose the child and release the slot.

`parallel(thunks)`: requires an array of functions within the item cap; runs all with `Promise.all`; a thunk that throws a non-fatal error resolves to `null`; a fatal `WorkflowError` propagates and ends the script. `pipeline(items, ...stages)`: requires an array within the cap and at least one stage; each item runs its stages sequentially as `stage(prev, item, index)` independently of other items; a non-fatal throw makes that item `null` and skips its remaining stages. `phase(title)` requires a non-empty string, sets the current phase and reports it. `log(message)` requires a string.

### K. `workflow` tool lifecycle (`tool-workflow/src/index.ts:409-483`)

Foreground: start the run with `{ script, meta, args?, parent, signal }`; record `run-start` when top-level; bridge the tool signal to `run.cancel('parent step aborted')`; await `run.result`; throw for a non-completed stop reason; in `finally` remove the bridge, await `run.dispose()`, then record `run-end`.

Background (`startBackgroundRun`, `index.ts:263-316`): `jobs.start({ kind: 'workflow', label: meta.name, owner: parent.id, toolCall: { callId, rootCallId }, run })`. The starter starts the engine run without the tool signal (the job owns it), attaches the mirror and recorder, and returns `{ cancel: reason => run.cancel(reason ?? 'background workflow job killed'), done }`. `done` awaits the result, disposes the run (a dispose failure is logged), stops the mirror, records `run-end`, and maps the outcome: completed gives `{ status: 'completed', detail: '<n> agent(s)', result: <rendered text> }`; cancelled gives `{ status: 'killed' }`; error gives `{ status: 'failed', detail: <error> }`. A synchronous engine rejection registers no job.

Mirror (`record.ts`): `workflow/phase` calls `job.updateProgress(title)` and appends `▸ <title>\n`; `workflow/log` appends `<message>\n`; `workflow/agent-start` appends `agent #<seq> <label> started\n`; `workflow/agent-end` appends `agent #<seq> <outcome>\n`; all on channel `log`.

## Tests worth porting

- `snapshots/session/ptc-turn/` (`tool-schemas.expected.json`, `system-prompt.expected.md`, `session.v4.jsonl`): the exact `run_code` schema, the full generated TypeScript SDK for the headless tool set, the dispatch event bytes and the rendered result. Highest-value golden data.
- Other recorded sessions: `ptc-inspect-output`, `ptc-read-image`, `ptc-read-image-attachment-path`, `ptc-inspect-image-error`, `ptc-timeout`, `ptc-timeout-fallback`, `ptc-tool-call-limit`, `ptc-persistent`, `ptc-persistent-scoped`, `ptc-scoped-repl`, `ptc-script-fresh`, `ptc-script-retained`, `ptc-script-imports`, `ptc-policy-change`, `ptc-reset`, `ptc-node-read-only`, `ptc-node-workspace`, `ptc-workspace-context`, `ptc-console-enabled`, `ptc-python-turn`, `ptc-python-read-only`, `cua-ptc`, `cua-run-code`, `cua-run-code-scoped`, `mcp-empty-ptc`, `mcp-resources-ptc`, `office-progressive-ptc`, `office-render-tools-ptc`, `workflow-run`, `workflow-confinement`; `snapshots/sdk/ptc-turn`, `snapshots/sdk/ptc-cancel`, `snapshots/sdk/desktop-ptc-context`; `snapshots/web/ptc-round`, `snapshots/web/ptc-escalation-approved`, `snapshots/web/workflow-run`.
- `packages/core/tool-executor-ptc/tests/ts-types.spec.ts` and `py-types.spec.ts`: tables mapping schema to type text; pure functions, portable one to one.
- `packages/core/tool-executor-ptc/tests/ptc.spec.ts` (3076 lines): mode-aware schema and prompt contribution; `run_code` reserved against scoped filters; byte-identical SDK across assemblies; the call allowance (2048 by default, failed attempts counted, reset per program, no finite limit without a deadline); scheduler behavior (overlap, exclusive barrier through post-execute, `maxParallelSubCalls`, ordered pre-execute, ordered commit under out-of-order completion, abandoned calls log nothing, settle events appended inside the turn, log backpressure); bridge behavior (opaque parent token, denials as binding rejections, contained log listener, lossless argument checks, `__proto__` as an own binding, deferred contexts and images, turn conclusion forwarding, quiescence when the runtime rejects, agentless runs skip events); Python value rendering; `UNKNOWN_TOOL` for model-direct calls; per-agent presentation; host reset; standing policy and escalation; state ownership.
- `tests/ptc-calls.spec.ts`: policy-change cancellation and admission ordering, reset blocking and retry, disposal.
- `tests/run-code.spec.ts`: registered program tools (private bindings, own name in limits and escalation, owner disposal).
- `packages/ptc-runtime/ptc-runtime/tests/reserved.spec.ts`, `service.spec.ts`: reserved sets and base-class defaults.
- `packages/ptc-runtime/ptc-runtime-node/tests/`: `json-wire.spec.ts` (wire codec and hostile tokens), `output-json.spec.ts`, `output-ledger.spec.ts` (byte accounting at tiny and exact limits, multibyte), `rpc.spec.ts` (framing, limits, unknown methods, split multibyte chunks), `host-failures.spec.ts` (forged child traffic through `fake-child.ts`: readiness, undeclared bindings, pending limits, exit classification, denial signatures), `timeout.spec.ts`, `persistent-host.spec.ts`, `persistent.spec.ts`, `persistent-sandbox.spec.ts`, `initialization.spec.ts`, `policy-processes.spec.ts`, `output.spec.ts` (`inspect` and images), `launch.spec.ts`, `execution-mode.spec.ts`. `tests/fake-child.ts` and `tests/raw-peer.ts` show how to drive the host with scripted NDJSON and are a template for Racket host tests that need no Node.
- `packages/workflow/workflow/tests/workflow.spec.ts`: listener containment. `workflow-ptc/tests/meta.spec.ts`, `realm.spec.ts` (pure), `guest.spec.ts` (script API, progress batching, FIFO slots, caps), `host.spec.ts`, `workflow-ptc.spec.ts` (lifecycle, cancellation, stray children, pairing of member events). `tool-workflow/tests/tool-workflow.spec.ts`: rendering, truncation, records, background jobs.
- `packages/experimental/ptc-runtime-python/tests/protocol.spec.ts`, `protocol-mirror.e2e.ts`, `runtime.spec.ts`.

## Porting notes

### Essential product behavior

- The model-visible bytes: the `run_code` name, description assembly and parameter schema; the two prompt sections and the SDK renderers; the `workflow` tool description, schema and section; every diagnostic string quoted in this note. They feed prompt caches and recorded-session snapshots.
- Durable bytes: `tool/ptc-dispatch-start`, `tool/ptc-dispatch`, `tool-workflow/*`, the `ptc-mode` source, the `<parent>:ptc:<n>` id form.
- The dispatch contract: every sub-call goes through the shared pipeline with `parent` set; ordered stages never overlap; results commit in submission order; every started call is logged before the outer call returns; a model-direct native call is `UNKNOWN_TOOL`.
- The runtime seam: results, the eight failure kinds, output ordering, timeout and cancellation wording, retained-state reporting, the output budget.
- Config compatibility: plugin names and config keys of the five plugins, and the ids used by profile patches (`ptc-runtime`, `tool-executor-ptc`, `tool-executor-native`, `workflow-ptc`, `tool-workflow`, `preset-ptc`).

### Node and TypeScript specific machinery

- Captured-intrinsic code in `json-wire.ts` and `output-json.ts` protects against a program that mutated `Array.prototype` in the same realm. The Racket host never shares a realm with the program, so plain code is enough on the host side.
- `birpc` is a library choice; the wire format in Formats is what matters.
- `AsyncLocalStorage` binding in the host (`worker.ts:153`) keeps binding calls in the caller's async context. Racket equivalent: capture `(current-parameterization)` when the evaluation is created and invoke bindings with `call-with-parameterization`.
- Explicit-stack traversals exist because of JavaScript call-stack limits; Racket recursion is deep, but keep iteration where depth is attacker-controlled (wire decoding, schema rendering).
- `WeakMap` state owners map to `make-weak-hasheq`; `AbortSignal` and `AbortSignal.any` map to events combined with `choice-evt` or to nested custodians; `Promise.withResolvers` maps to a channel or a semaphore plus box; `ctx.effect` disposers map to plugin disposal hooks backed by custodians.

### Suggested Racket decomposition

- `ptc/runtime.rkt`: structs for request, spec, result, failure (kind as a symbol); the reserved sets; a generic interface or struct of procedures for providers; contracts on `resolve` and `run`.
- `ptc/json.rkt`: lossless JSON validation and snapshot over an ORDER-PRESERVING object representation, the byte meters, and a JavaScript-compatible number printer.
- `ptc/wire.rkt`: `PtcJsonWire` encode and decode.
- `ptc/rpc.rkt`: the NDJSON endpoint (pending table keyed by id string, notification list, message and queue limits, three failure kinds).
- `ptc/node/{config,launch,worker,execution,policy-processes}.rkt`: the host side of the Node provider. One worker owns one custodian holding the subprocess, its ports and its reader threads; the settlement state machine of section F runs in a single owner thread fed by a mailbox, which removes most of the "settled" flag checks.
- `ptc/executor/{run-code,scheduler,calls,sdk-ts,sdk-py}.rkt`: the tool executor. The driver of section C is naturally one thread reading a mailbox of `submitted`, `body-settled` and `log-done` messages.
- `workflow/{service,ptc-engine,host-run,meta,tool,record}.rkt`.
- `ptc/python/{host,protocol}.rkt` if the experimental provider is ported.

### What can only be wrapped, and how to stay compatible with the JavaScript-facing contract

The `run_code` contract is language-specific: the description says TypeScript, the SDK is TypeScript declarations, recorded sessions contain TypeScript programs, and the semantics of `inspect` are those of `util.inspect`. Matching it requires a JavaScript engine. Recommended approach: a Node sidecar that is the UNMODIFIED dsh child bootstrap, with the Racket host implementing the host half of protocol revision 3.

- Reuse `ptc-runtime-node`'s built `lib/process.js` (it bundles acorn, acorn-walk and birpc). Everything in section H then comes for free, including the four evaluators and `util.inspect` formatting. The `workflow` guest (`WORKFLOW_GUEST_SOURCE`) is likewise reused as data; only `host.ts` is ported.
- Type stripping is a host duty in dsh and has no Racket equivalent. Options: (a) a long-lived or per-run Node helper that runs `stripTypeScriptTypes` and returns the JavaScript or the error message; (b) a Racket-owned bootstrap shim that imports `runNodeMain` and strips inside the child before evaluation. Option (a) keeps the upstream bootstrap unmodified and keeps the rule that a syntax error starts no program process. Either way the function-body wrapper trick (`async function __dsh_program__() {\n...\n}`) must be reproduced so `return` and `await` parse, and error messages must be passed through unchanged.
- The control channel is fd 7. Racket's `subprocess` passes only three ports. The Racket subprocess service needs a way to give a child an extra duplex descriptor (FFI `socketpair` plus `posix_spawn` file actions on Unix; a named pipe on Windows), and the sandbox runner must pass it through. If that is not available, the fallback is a shim bootstrap that connects to a Unix-domain socket named in argv and hands the stream to `runNodeMain`, which accepts any duplex stream. Stdout and stderr cannot carry control traffic because child processes started by the program write to them directly.
- The V8 heap flag, `--experimental-vm-modules`, the environment scrub and `ELECTRON_RUN_AS_NODE` handling are argv and env details to copy.
- The Python provider wraps CPython with `py/bootstrap.py` and `py/protocol.py` unchanged; only the frame pump is ported.

### Hosting PTC natively in Racket

The seam already supports more than one language: `language` is a free identifier, and the consumer selects the description flavor and SDK renderer by it and fails loud on an unknown one. A native provider is therefore an addition, not a replacement: `language = 'racket'`, a third flavor, and a third SDK renderer. Profiles that name `@deepseek-ai/dsh-ptc-runtime-node` keep getting the TypeScript contract; a profile patch selects the Racket provider by its own plugin name. Sessions recorded under one language replay without running programs, so mixing is safe at the log level.

Evaluator design:

- Program form: an S-expression program read with a restricted reader (no `#lang`, no `#reader`, no `read-eval`), evaluated in a `racket/sandbox` evaluator built from a small module language that exports only the allowed bindings. The capability set is then the export list of that language plus the injected bindings, instead of an ambient runtime that is fenced afterwards.
- Bindings: each tool becomes a procedure. Because Racket identifiers may contain dots, `(tools.bash (hash 'command "pwd" 'description "Show current directory"))` mirrors `tools.bash({...})`; exotic names go through `(tools-ref "my-tool")`. Arguments and results are JSON values; define the mapping once (ordered objects, lists, strings, booleans, a null marker, exact integers within the safe range and finite non-negative-zero flonums) and reject everything else with the same messages. `ToolCallError` becomes an `exn:fail` subtype with a `tool-name` field, shared with the sandbox through `sandbox-namespace-specs` so `with-handlers` predicates work.
- Concurrency: a binding call blocks the calling Racket thread on a channel to the scheduler thread. `Promise.all` becomes a small `parallel` form or plain threads. The scheduler of section C is unchanged, because it only sees submissions.
- Output: `inspect` writes pretty-printed values and emits image markers in order; `current-output-port` and `current-error-port` are custom ports that charge the output ledger. The ledger arithmetic stays identical so limits mean the same thing in both languages.
- Deadlines and cancellation: `break-thread` gives the cooperative stop that Node needs `revoke` for (handlers and `dynamic-wind` post thunks run), and `kill-evaluator` or `custodian-shutdown-all` gives the hard stop. Unlike Node, a synchronous loop can be interrupted without killing the environment, so retained state survives more timeouts. `custodian-limit-memory` replaces the V8 heap flag. `sandbox-eval-limits` alone is not enough because the deadline must include nested tool and approval waits.
- Retained state: one evaluator per state owner is the `repl` format directly; top-level redefinition is legal in a Racket namespace, so the scoped-REPL machinery (which exists to let JavaScript programs redeclare `const` names) is unnecessary.
- Environment initialization maps to evaluating the initializer forms once in a new evaluator.

Where code-as-data helps beyond parity:

- Static inspection before execution. After `read` and `expand`, the host can list which tool bindings a program references. That supports rejecting undeclared tools before any effect, showing the user the affected tools in an escalation prompt, and pre-classifying a program as read-only when every referenced tool is concurrency-safe. None of this is possible for the JavaScript path without a full parser and without guarantees against `tools[name]` with computed names; a restricted Racket language can simply not export a computed lookup, or export only an audited one.
- Workflow as a language. `agent`, `pipeline`, `parallel`, `phase` and `log` are a natural macro-level DSL, and `meta` can be a declaration form validated at expansion time instead of a separate JSON parameter. A Racket-native workflow engine can implement the same `ctx.workflowEngine` seam and the same events and records. It needs its own tool description, because the shipped description promises plain JavaScript; the JavaScript engine must stay available for compatibility.
- Record and replay. In a language whose only effects are the injected bindings, a program can be re-run against the logged `tool/ptc-dispatch` results. That gives deterministic tests for programs without a model or live tools.

Limits of the native path:

- `racket/sandbox` is in-process isolation built on security guards, inspectors and custodians. dsh treats the program as a hostile peer and enforces file policy with the OS sandbox on a separate process, which also covers subprocesses the program starts. To keep `read-only` and `workspace-write` meaning the same thing, run the Racket evaluator in its own OS process under `ctx.sandbox.confine`, as a Racket sidecar that speaks the same protocol revision 3 (`ready`, `run`, `revoke`, `invoke`, `log`, `image`, `outputLimit`, `initialized`). Then one host implementation serves both the Node and the Racket child, and the in-language limits are a second layer. An in-process evaluator is defensible only for `danger-full-access` sessions or for trusted, effect-free scripts such as a workflow DSL whose only capabilities are the five hooks.
- Models are trained far more on TypeScript and Python than on Racket. A native mode needs its own evaluation before it becomes a default.

### Hard parts and risks

- JSON object key order is load-bearing: SDK property order, pretty-printed results, logged arguments and the wire codec all depend on insertion order. Racket hash tables are unordered. Use an ordered representation everywhere JSON flows through this area.
- Number text: byte accounting and Python-result rendering use JavaScript `String(number)`. A compatible printer is needed (shortest round-trip digits, `1e+21` exponent form).
- String comparison and length: tool sorting is by UTF-16 code units and several limits count UTF-16 units (`maxResultChars`, label truncation at 48, class-name cap 120). Racket strings are code points and cannot hold lone surrogates, which JSON from a hostile child can contain; the decoder and the byte meter need a defined behavior for them (treat as protocol-invalid or carry as escapes).
- The settlement state machine of section F has many interleavings (timeout during startup, abort during confinement, exit racing the `run` reply, revoke grace, drain failure). Port the tests in `host-failures.spec.ts`, `timeout.spec.ts` and `persistent-host.spec.ts` with a scripted peer before trusting it.
- Exactly-once and drain guarantees in the scheduler: every started sub-call gets one settle event inside the outer call; nothing is appended after `run_code` returns; the outer call returns only after bodies have reached quiescence.
- Python SDK renderer: Unicode identifier classification (`XID_Start`, `XID_Continue`, NFKC stability) depends on the engine's Unicode version; Racket's tables will differ from Node's on recently added characters.
- Extra-descriptor inheritance through the sandbox runner on every platform.
- `executionInstructions` and other long literals are easy to corrupt; load them from fixtures and compare against the golden schema snapshot.

## Feature checklist

- ptc-runtime: `ctx.ptcRuntime` service slot with one provider per context
- ptc-runtime: `resolve(request)` fills cwd, timeout and policy; `run(spec)` never fills defaults
- ptc-runtime: program failures resolve as `result.error`; only misuse rejects
- ptc-runtime: eight failure kinds reported independently
- ptc-runtime: ordered `output` of text and image entries
- ptc-runtime: `PtcImage` binding results
- ptc-runtime: portable identifier rule for namespace globals and error-class names
- ptc-runtime: `RESERVED_BINDING_GLOBALS`, `RESERVED_ERROR_MEMBERS`, dunder rule, `PORTABLE_RESERVED_WORDS`
- ptc-runtime: binding function names are own properties (`__proto__` safe)
- ptc-runtime: `stateOwner` object identity and `release(owner)`
- ptc-runtime: `registerEnvironmentInitializer` contract and disposer
- ptc-runtime: informational `language`, `isolation`, `programFormat`, `retainsState`, `executionInstructions`, `sandboxMode`, `timeout`
- ptc-runtime-node: config schema with defaults and load-time validation
- ptc-runtime-node: `per-call` mode (fresh process, async function body, strict)
- ptc-runtime-node: `vm-script` mode with top-level-await lowering and awaited final expression
- ptc-runtime-node: `scriptPersistence` retained Script context per owner
- ptc-runtime-node: `persistent-in-memory` scoped REPL (default) with copied bindings and redeclaration
- ptc-runtime-node: `persistent-in-memory` with `replScoped: false` (Node REPL)
- ptc-runtime-node: mode-specific `executionInstructions` text
- ptc-runtime-node: host-side erasable TypeScript stripping; strip errors are `exception`
- ptc-runtime-node: launch argv for `node-script` and `embedded`, heap flag, `--experimental-vm-modules`
- ptc-runtime-node: explicit `launch.bootstrapPath` and source-launch eval bootstrap
- ptc-runtime-node: environment scrub (six startup names, empty `process.env`)
- ptc-runtime-node: confinement through `ctx.sandbox.confine` unless `danger-full-access`
- ptc-runtime-node: control channel on fd 7 with NDJSON request, notification and reply envelopes
- ptc-runtime-node: protocol revision check on `ready` (requires 3)
- ptc-runtime-node: `run` and `revoke` program methods
- ptc-runtime-node: `invoke`, `log`, `image`, `outputLimit`, `initialized` host methods
- ptc-runtime-node: message size, queued-write and first-byte checks on the control channel
- ptc-runtime-node: flat `PtcJsonWire` token codec with image tokens
- ptc-runtime-node: lossless JSON validation of arguments, results and completions
- ptc-runtime-node: `maxPendingCalls` and outstanding argument byte limit
- ptc-runtime-node: undeclared binding is a protocol failure (temporary) or a rejection (retained)
- ptc-runtime-node: program globals `tools`, error class, `inspect`, `Image`, `process`, `console`
- ptc-runtime-node: `inspect` rendering rules and in-order image emission
- ptc-runtime-node: raw stdout and stderr captured into output
- ptc-runtime-node: `discardCompletion`
- ptc-runtime-node: output ledger byte accounting and `output-limit` with retained prefix
- ptc-runtime-node: timeout messages `before code started` and `during execution`
- ptc-runtime-node: timeout default and cap (`resolve`), explicit `null` deadline
- ptc-runtime-node: abort handling and message forms
- ptc-runtime-node: cooperative revoke with `stopGraceMs`, fallback termination with `graceMs`
- ptc-runtime-node: `retained variables were preserved|cleared` reporting
- ptc-runtime-node: process exit classification (`worker-exit` and `sandbox-unavailable`) with stderr tail
- ptc-runtime-node: `sandbox` result facts (mode, denial signature match, enforcement)
- ptc-runtime-node: one retained process per owner; concurrent runs for one owner rejected
- ptc-runtime-node: retained owner cannot change policy without release
- ptc-runtime-node: session `sandbox/mode` change invalidates processes and cancels admitted runs
- ptc-runtime-node: environment initializer evaluated once per new environment with `initialized()` handshake
- ptc-runtime-node: per-evaluation cwd reset
- ptc-runtime-node: ended evaluations cannot log or call bindings
- ptc-runtime-node: provider disposal aborts and drains runs and processes
- ptc-runtime-node: `resolvePersistentExecution` helper for profile editors
- ptc-runtime-node: runner-side import handler extension point (not configured by default)
- tool-executor-ptc: plugin `ptc-tool-executor` with required `tools`, `systemPrompt`, `ptcRuntime`
- tool-executor-ptc: config `maxSubCallsPerMinute` and `maxParallelSubCalls`
- tool-executor-ptc: model request carries only the `run_code` schema
- tool-executor-ptc: `run_code` reserved outside registry filters and absent from program bindings
- tool-executor-ptc: `run_code` description assembled from flavor, runtime instructions, directory sentence, escalation guidance
- tool-executor-ptc: runtime-dependent parameters (`timeoutMs`, `sandbox_permissions`, `justification`)
- tool-executor-ptc: `tools:ptc-only` section at order 800
- tool-executor-ptc: `tools:sdk` section at order 5000, not interpolated
- tool-executor-ptc: TypeScript SDK renderer with deterministic ordering and the bash example rule
- tool-executor-ptc: `jsonSchemaToTs` type mapping
- tool-executor-ptc: `Image` return types for `read_image` and `cua`
- tool-executor-ptc: Python SDK renderer with `TypedDict` classes and subscript comments
- tool-executor-ptc: model-direct native call denied as `UNKNOWN_TOOL` before policy
- tool-executor-ptc: sub-calls run through the shared pipeline with the parent token
- tool-executor-ptc: sub-call ids `<parent>:ptc:<n>`
- tool-executor-ptc: `tool/ptc-dispatch-start` at start, `tool/ptc-dispatch` at settle, both inside the outer call
- tool-executor-ptc: `tools/ptc-dispatch-log` waterfall with contained listener failures
- tool-executor-ptc: scheduler ordering (ordered starts and commits, overlap limit, exclusive barrier, late reclassification)
- tool-executor-ptc: log-append backpressure
- tool-executor-ptc: abandoned queued calls log nothing; started calls drain before return
- tool-executor-ptc: tool-call allowance from resolved timeout; exhaustion aborts the program
- tool-executor-ptc: binding arguments normalized twice (dispatch copy and log copy)
- tool-executor-ptc: tool failure and policy denial surface as `ToolCallError` with the message only
- tool-executor-ptc: program receives canonical tool values, not rendered content
- tool-executor-ptc: deferred image messages with source `ptc-mode`
- tool-executor-ptc: forwarding of nested additional contexts and turn conclusion
- tool-executor-ptc: result rendering (ordered text and images, result value, sandbox lines, empty-output placeholder)
- tool-executor-ptc: `CODE_RUN_FAILED` message format with captured output and sandbox summary
- tool-executor-ptc: caller cancellation reported as `ABORTED`
- tool-executor-ptc: per-call `timeoutMs` validation and forwarding
- tool-executor-ptc: one-execution sandbox escalation with approval, without state owner
- tool-executor-ptc: state owner is the Agent; release on Agent disposal
- tool-executor-ptc: session mode change cancels active programs; successors wait for cleanup
- tool-executor-ptc: `reset(agent)` with notice and blocking on failure
- tool-executor-ptc: `createRunCodeTool` registered program tools with private bindings
- tool-executor-ptc: execute card presentation (title from description, raw input is the code)
- ptc-runtime-python: config schema and load-time interpreter probe
- ptc-runtime-python: fresh confined CPython process per run with only `TMPDIR`
- ptc-runtime-python: fd-3 frames `boot`, `run`, `reply`, `boot-ack`, `call`, `log`, `done`
- ptc-runtime-python: async function body with top-level `await` and `return`
- ptc-runtime-python: namespace proxy with attribute and subscript access and declared error class
- ptc-runtime-python: log and value budgets, truncation marker, lossless completion
- ptc-runtime-python: CPU, address-space and wall limits; process-group teardown
- ptc-runtime-python: backlog and frame caps reported as `worker-exit`
- ptc-runtime-python: rejects per-call timeout, `discardCompletion` and initializer registration
- workflow: `ctx.workflowEngine` service slot
- workflow: start request, run handle, result and meta vocabulary
- workflow: `WorkflowError` codes and fatal flag
- workflow: six `workflow/*` emit events with per-listener containment
- workflow-ptc: config schema with auto-resolved concurrency
- workflow-ptc: requires a TypeScript runtime at load
- workflow-ptc: synchronous meta validation naming every violation
- workflow-ptc: synchronous body parse check and `export const meta` rejection
- workflow-ptc: provider and `maxTotalAgents` overrides validated before publication
- workflow-ptc: script runs in the PTC process under the session file policy with no deadline
- workflow-ptc: guest loaded from a data URL; `workflowHost` binding protocol
- workflow-ptc: six script globals in an otherwise empty VM context
- workflow-ptc: `agent()` option validation, labels, phases, schema results, null on child failure
- workflow-ptc: FIFO concurrency slots and total agent cap
- workflow-ptc: `parallel()` and `pipeline()` null-on-failure with fatal propagation and item cap
- workflow-ptc: result materialization to plain JSON with path-qualified errors
- workflow-ptc: progress batching with one call in flight
- workflow-ptc: children started through `subagents.startActivation` with caller delivery
- workflow-ptc: cancel and dispose semantics; stray children disposed at settlement
- workflow-ptc: exactly one `agent-end` per observed start, synthesized `cancelled` on termination
- workflow-ptc: `workflow/start` and single `workflow/end`
- tool-workflow: `workflow` tool schema, description and prompt section
- tool-workflow: config `toolName`, `maxResultChars`, `enableRunInBackground`
- tool-workflow: foreground run with abort bridge and guaranteed disposal
- tool-workflow: result rendering and truncation notice
- tool-workflow: stop-reason error mapping
- tool-workflow: background run as an owned `workflow` job with outcome mapping
- tool-workflow: job-ring mirror of phase, log and member events
- tool-workflow: durable `tool-workflow/*` records for top-level calls only, with failure containment
- bundle: base composition mounts `ptc-runtime`, `workflow-ptc`, `tool-workflow`, with `tool-executor-ptc` disabled
- bundle: `apps/cli/config/examples/ptc.yml` switches executors
- bundle: Web `ptc` preset row and plugin list
- scripts: `pnpm run demo:ptc` launcher
