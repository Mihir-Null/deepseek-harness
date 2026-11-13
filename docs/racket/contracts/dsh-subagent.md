# Interface contract: `dsh-subagent`

This is the binding interface for `racket/dsh-subagent/`. It covers delegation: the provider registry and activation manager behind `subagents`, the two in-process providers, the delegation and control tools, the four out-of-process providers, and Agent Teams (a per-tree mode and a shared task board). Sources: [recon 11](../recon/11-agents-context.md) (cited as R11 with its heading), the SDK and ACP wire formats of [recon 13](../recon/13-sdk-acp-python.md) (R13 Formats 1 to 5 and 12), and `packages/{subagent,team}/*/src` at commit `e8f7b93a3`. When this document and the TypeScript disagree about behaviour, the TypeScript is right and this document gets fixed. When they disagree about names and argument order of the Racket surface, this document is right. Read [dsh-session.md](dsh-session.md), [dsh-llm.md](dsh-llm.md), [dsh-tools.md](dsh-tools.md) and [dsh-agent.md](dsh-agent.md) first; this contract uses their vocabulary without repeating it (`absent`, jobjects, `define-session-event`, `session-append!`, `make-user-message`, cancel sources and cancel events, `define-tool`, `make-tool`, `gen:agent` and its procedures, `agents-create`, `agents-resume`, `agent-handle`, `fold-consumed-work`, `scoped-callbacks`, `projection-definition`).

Package: directory `racket/dsh-subagent/`, collection `dsh-subagent`, `(define deps '("base" "cordis" "cordis-data" "cordis-schema" "dsh-util" "dsh-session" "dsh-llm" "dsh-tools" "dsh-agent"))`, `(define build-deps '("rackunit-lib" "dsh-test-support"))`. The package requires no sibling wave 4 package at compile time: every service owned by a sibling, including `agentPresets` of `dsh-context`, is reached through `dsh-subagent/ports` (Services, "Ports").

## Scope

| dsh package | npm name | Status |
|---|---|---|
| `packages/subagent/subagent` | `@deepseek-ai/dsh-subagent` | native. The Remote methods `prompt` and `interruptByUser` are exported as a table for `dsh-web`. |
| `packages/subagent/subagent-spawn-in-process` | `@deepseek-ai/dsh-subagent-spawn-in-process` | native |
| `packages/subagent/subagent-fork-in-process` | `@deepseek-ai/dsh-subagent-fork-in-process` | native |
| `packages/subagent/tool-subagent` | `@deepseek-ai/dsh-tool-subagent` and its subpath `@deepseek-ai/dsh-tool-subagent/model-selection-settings` | native |
| `packages/subagent/tool-subagent-control` | `@deepseek-ai/dsh-tool-subagent-control` | native |
| `packages/subagent/subagent-acp` | `@deepseek-ai/dsh-subagent-acp` | native subprocess wrapper. dsh spawns the configured command and uses the ACP SDK only to frame newline-delimited JSON-RPC; the Racket provider spawns the same command and speaks that protocol itself. |
| `packages/subagent/subagent-codex` | `@deepseek-ai/dsh-subagent-codex` | adapted subprocess wrapper over `codex app-server --stdio`. dsh runs `node <bin of @openai/codex>`; the Racket provider runs the command named by `x-racket.command` (default `codex` on `PATH`) with the same two arguments and the same wire protocol. |
| `packages/subagent/subagent-claude-code` | `@deepseek-ai/dsh-subagent-claude-code` | wrapped by the sidecar `sidecar/claude-code.mjs`. dsh drives the product through the npm package `@anthropic-ai/claude-agent-sdk`, not through a command line, so the provider needs Node 22 or later and `npm install @anthropic-ai/claude-agent-sdk` in the sidecar's package directory (rule 86). Without them the provider registers and every start fails with the startup failure. |
| `packages/subagent/subagent-dsh-sdk` | `@deepseek-ai/dsh-subagent-dsh-sdk` | adapted subprocess wrapper over the `dsh` command line (`<dsh> --profile <profile> [--patch <file>]…`) speaking the SDK JSON-RPC protocol. `dshBin` names an executable, not a JavaScript module; without it the launcher of the running harness is used. |
| `packages/team/agent-team` | `@deepseek-ai/dsh-agent-team` | native. The Remote method `setEnabled` is exported as a table. |
| `packages/team/tool-agent-team` | `@deepseek-ai/dsh-tool-agent-team` | native |

Not applicable: Zod schemas (states and payloads are checked by the contracts and rules below), the `client.ts` halves, Windows process handling in the out-of-process providers.

## Modules

| Module | Provides |
|---|---|
| `dsh-subagent` (`main.rkt`) | re-exports `types`, `names`, `subagents`, `team` |
| `dsh-subagent/ports` | the late-bound ports to sibling services |
| `dsh-subagent/types` | `gen:subagent-provider`, capabilities, requests, `subagent-run`, `subagent-result`, `subagent-activation`, the error structs and constructors |
| `dsh-subagent/names` | `root-agent-name`, `agent-name?`, `join-agent-path`, `agent-address`, `parent-agent-path` |
| `dsh-subagent/session-events` | the declarations `subagent/descriptor`, `subagent/catalog`, `subagent/model-selection-policy`, `team/mode`, `team/task` and the three historical team types |
| `dsh-subagent/descriptor` | `snapshot-subagent-descriptor`, `parse-subagent-descriptor`, `fold-subagent-descriptor`, `subagent-descriptor-version` |
| `dsh-subagent/projections` | `subagent-catalog-projection`, `subagent-timing-projection`, `subagent-identity-projection`, `catalog-entries`, `catalog-names`, `model-selection-policy-projection`, `team-projection` |
| `dsh-subagent/messages` | `make-agent-message`, `with-result-delivery-guidance`, `make-settlement-message`, `subagent-delegation-context` |
| `dsh-subagent/child-agent` | `delegation-depth-of`, `assert-subagent-max-depth`, `resolve-child-depth`, `parent-agent-options-for-delegation`, `resolve-child-agent-options`, `child-session-meta`, `capture-delegated-policy`, `append-delegated-policy!`, `apply-child-composition!` |
| `dsh-subagent/structured` | `structured-output-tool-name`, `attach-structured-runtime!` |
| `dsh-subagent/subagents` | the `subagents` service definition and procedures, the four `subagent/*` events, `subagents-remote-methods` |
| `dsh-subagent/out-of-process` | `no-start-capabilities`, `limit-subagent-diagnostic`, `assert-usable-cwd`, `settle-run-result`, `make-subprocess-run`, `make-assistant-output-fold` and its operations, `final-assistant-output` |
| `dsh-subagent/team` | the `agentTeams` service definition and procedures, `assert-task-graph-candidate`, `task-ready?`, `project-task-view`, `normalize-write-scope`, `agent-teams-remote-methods` |
| `dsh-subagent/plugin/<name>` | one module per row of the plugin table; each provides `plugin` |
| `dsh-subagent/plugins` | `plugin-table` |

Private modules, suggested: `private/manager.rkt`, `private/activation.rkt` (records, capacity pool, child lock), `private/deferred.rkt`, `private/discovery.rkt`, `private/archive-admission.rkt`, `private/control.rkt` (prompt request validation and error mapping), `private/model-selection.rkt`, `private/wait.rkt`, `private/jsonrpc-lines.rkt`, `private/acp-run.rkt`, `private/codex-wire.rkt`, `private/codex-run.rkt`, `private/claude-run.rkt`, `private/sdk-run.rkt`, `private/task-board.rkt`. The sidecar is the plain file `racket/dsh-subagent/sidecar/claude-code.mjs` beside a `package.json` that names its one npm dependency; `info.rkt` lists `sidecar` under `compile-omit-paths`.

## Data

### Provider seam (`dsh-subagent/types`)

```racket
(struct subagent-capabilities (agent-options? agent-preset? output-schema? depth-limit?) #:transparent)
(define-generics subagent-provider
  (provider-name subagent-provider)                              ; -> string?
  (provider-capabilities subagent-provider)                      ; -> subagent-capabilities?
  (provider-inherits-parent-context? subagent-provider)          ; -> boolean?
  (provider-route-defaults subagent-provider)                    ; -> (or/c #f jobject?) {provider, model}; fallback #f
  (provider-prepare-continuable subagent-provider request)       ; -> (or/c #f (listof session-event?)), the seed; may wait
  (provider-start subagent-provider request)                     ; -> subagent-run?; waits
  #:defined-predicate provider-implements?)
(struct continuable-create-request (cwd session-id parent cancel) #:transparent)
(struct subagent-start-request (cwd agent-preset label prompt parent cancel agent-options output-schema max-depth) #:transparent)
(struct subagent-run (id result dispose))                         ; result : task? yielding subagent-result?; dispose : (-> void?), waits
(struct subagent-result (output structured diagnostic stop-reason) #:transparent)
(struct subagent-activation (child-id name message-id result-evt dispose))
(subagent-activation-result a) -> subagent-result?                ; waits; raises the capture failure
(subagent-activation-dispose! a) -> void?                         ; waits; raises the teardown failure
no-start-capabilities                                             ; all four #f
```

A provider that implements `provider-prepare-continuable` is *local*: the manager creates a child agent in this process and the provider contributes only the optional seed. A provider that implements only `provider-start` is *external*: it runs one execution and returns its run handle. `(provider-implements? p 'provider-prepare-continuable)` is the test. `cwd` of both requests is an absolute path chosen before the provider is called. `prompt` and `output` are lists of content blocks. `agent-preset`, `label`, `agent-options`, `output-schema` and `max-depth` are `#f` when not requested. `structured` is `absent` or a jvalue. `diagnostic` is `#f` or a string of at most 4096 UTF-8 bytes. `stop-reason` is a string; the known values are `completed`, `aborted`, `error`, `max-tokens`, `refusal`, and consumers treat any other as abnormal. `message-id` is `#f` for an external child. Obligations of a run: `result` never raises for a child-level failure (it yields stop reason `error`); `dispose` is idempotent, cancels remaining work and returns after the child is quiescent; a failed start cleans up before it raises.

### Run information

`subagent/start` carries the jobject `{runId, provider, parentSessionId, id, local}`; `subagent/end` carries the same keys followed by `stopReason` and, when the output is not empty, `lastAssistantMessage`. `runId` is a fresh UUID per activation and pairs the two events; a cold resume is a new run.

### Session events declared here (`dsh-subagent/session-events`)

Declared with `define-session-event`; none is surface-eligible or ignorable; every tag is in `known-session-event-types`.

| Racket id | Data fields in write order (JSON key: contract) |
|---|---|
| `subagent/descriptor` | `version`: `3`; `mode`: `"continuable"` or `"one-shot"`; `provider`: `string?`; `label?`: `string?`; `agentProvider?`; `agentModel?`; `agentReasoningEffort?`; `persona?`: `string?`; `toolFilter?`: `{allow?, deny?}`. New writes are always `continuable` with a `label` and without `persona` and `toolFilter`. |
| `subagent/catalog` | `version`: `3`; `childId`: `string?`; `childCreatedAt`: non-negative integer; `mode`: `"continuable"` or `"external"`; `label?`; `name`: `agent-name?` |
| `subagent/model-selection-policy` | `allowedModels`: list of `{provider, model}` |
| `team/mode` | `enabled`: `boolean?` |
| `team/task` | `version`: `2`; `teamId`: `string?`; `task`: a task snapshot |
| `team/member`, `team/message/queued`, `team/message/delivered` | `#:data jobject?`. Historical; never written; declared so that old logs keep a declaration. |

Readers accept more than writers produce: rule 5 (descriptor) and rule 7 (catalog versions 0 to 3).

Appended here but owned elsewhere, written with `make-session-event-input` and a literal data jobject: `agent-preset/selected {agentPreset}`, `sandbox/mode {mode, source: "delegation"}`, `approval/policy {policy: "never", source: "delegation"}`, `permission/preset {preset}`.

### Message sources

| Constructor (`dsh-subagent/messages`) | Source keys in order | Content |
|---|---|---|
| `(make-agent-message sender sender-name content)` | `kind: "agent-message"`, `form: "relay"`, `senderSessionId` | one text block `Agent <senderName> sent a message: ` (with the trailing space), then the sender's blocks |
| `(make-settlement-message child-id child-name result continuable? omit-closing-text?)` | `kind: "subagent-settled"`, `form: "notice"`, `summary` (`bound-context-summary` of the first line), `stopReason`, `senderSessionId` | rule 38 |
| browser prompt (rule 59) | `kind: "user"`, `rpcId`, `clientTimeZone?`, `principal?` | the admitted prompt content |

The first task of a child has the plain `(user-source)`.

### Projections (`dsh-subagent/projections`)

| Key | `stateVersion` | State | Wire view | Owner plugin |
|---|---|---|---|---|
| `subagentCatalog` | 6 | `{inheritedEventCount, head?}`; `head` is a chunked list `{values: [event data…], previous?}` with at most 64 values per chunk | the entries `{id, createdAt, mode, label?, name?}` in event order | `subagent` |
| `subagentTiming` | 3 | `{descriptorSeen, settledMs, active?: {since, through}, pendingTurnStart?, lastTurnCompleted?}`; initially `{descriptorSeen: false, settledMs: 0}` | `{settledMs, active?, lastTurnCompleted?}` | `subagent` |
| `subagent` | 2 | `{identity?}` with identity `{mode, label?, seq}` | the identity or `null` | `subagent` |
| `subagentModelSelectionPolicy` | 1 | `null` or the list of `{provider, model}` of the first policy event | none | `tool-subagent` and the settings plugin |
| `agentTeam` | 7 | `{inheritedEventCount, enabled?, id, tasks, nextTaskNumber, failure?}` | `{enabled, tasks: [task view…], failure?}` | `agent-team` |

### Teams (`dsh-subagent/team`)

A *task snapshot* is the durable jobject `{id, revision, subject, description, status, blockedBy, writeScopes}` with `ownerId` and, after it, `ownerName` appended behind `writeScopes` while the task has an owner; `status` is `pending`, `in_progress`, `completed` or `deleted`; `id` is `task-<n>`; the team id is the root session id. A *task view* is `{id, revision, subject, description, status, blockedBy, writeScopes, ownerId?, ownerName?, ready, writeScopeWarnings}`. The *tool view* is the task view without the two owner keys and, when the task has an owner, with `owner` (the owner name, else the owner id) as its last key.

### Errors

```racket
(struct exn:fail:subagent exn:fail:harness ())          ; dsh SubagentError; made by (make-subagent-error code message #:cause [c #f])
(struct exn:fail:subagent-depth exn:fail (attempted-depth max-depth))   ; dsh SubagentDepthError; not a harness error
(struct exn:fail:team exn:fail:harness ())              ; dsh TeamError; (make-team-error code message #:cause [c #f])
(struct exn:fail:agent-wait exn:fail:harness ())        ; dsh AgentWaitError; codes WAIT_INVALID_TIMEOUT, WAIT_UNAVAILABLE
(struct exn:fail:subagent-remote exn:fail:harness (details))   ; dsh RemoteError of the two Remote methods; details : jobject?
```

The persisted identity of each harness error is its dsh name (`SubagentError`, `TeamError`, `AgentWaitError`) and code. `SubagentError` codes: `NO_PROVIDER`, `DUPLICATE_PROVIDER`, `UNSUPPORTED_CAPABILITY`, `PROVIDER_CHANGED`, `CONTINUATION_UNAVAILABLE`, `PERSISTENCE_UNAVAILABLE`, `UNAUTHORIZED`, `DUPLICATE_CHILD`, `INVALID_AGENT_NAME`, `DUPLICATE_AGENT_NAME`, `AGENT_NAME_NOT_FOUND`, `ACTIVATION_LIMIT_REACHED`, `ACTIVATION_CLOSING`, `ACTIVATION_TEARDOWN_FAILED`, `DRAINING`, `INPUT_CLOSED`, `NOT_CONTINUABLE`, `NOT_RESUMABLE`, `MODEL_DOES_NOT_SUPPORT_IMAGES`, `PRESET_UNAVAILABLE`, `CANCELLED`, `SUBAGENT_CONTROL_QUERY_UNAVAILABLE`, `SUBAGENT_CONTROL_PROJECTIONS_UNAVAILABLE`, `SUBAGENT_CONTROL_SESSION_STORE_UNAVAILABLE`. `TeamError` codes: the seventeen `TEAM_*` codes of R11 "Team formats". Every message is given in Behaviour. Where dsh throws a plain `Error` this package raises `exn:fail`; where it throws `TypeError` or `RangeError`, `exn:fail:contract`.

## Services

`x` is a context or a handle for the service; "the caller's context" is `(use-context x)`.

### Ports (`dsh-subagent/ports`)

Each port is a generic interface declared here, with the convention of [WAVE3.md](WAVE3.md): a method takes the provider's value first and, when it registers an effect, the owning context second. Each port also has a wrapper procedure, listed below, that takes a context, reads the service with `ctx-get` and calls the method when the mounted value implements the interface (test doubles and providers that adopt the interface do). Otherwise the wrapper calls the owner's own procedure named in the third column, resolved once with `dynamic-require`; a missing module or binding raises `exn:fail` `dsh-subagent: port <name> cannot reach <module> <binding>`. The fallback exists because the wave 4 packages are built at the same time and a provider cannot require every consumer's port module.

| Port procedure | Service key | Assumed owner procedure |
|---|---|---|
| `(port-working-directory-ensure ctx agent cancel) -> path-string?`; `(port-working-directory-set! ctx agent path cancel) -> void?`; `(port-working-directory? ctx)` | `workingDirectory` | `dsh-session-store/working-directory` `working-directory-ensure`, `working-directory-set!` |
| `(port-persistence? ctx)`; `(port-persistence-stat ctx id cancel) -> (or/c #f jobject?)` | `sessionPersistence` | `dsh-session-store` `session-persistence-stat` |
| `(port-observe-session ctx id cancel) -> observation`; `(observation-header o) -> session-header?`; `(observation-events o) -> (listof session-event?)`; `(observation-inherited-event-count o)`; `(observation-projection o key) -> (or/c jvalue? absent?)`; `(observation-release! o)`; `(port-session-query? ctx)` | `sessionQuery` | `dsh-session-store/query` `session-query-observe-session` and its accessors; error codes `SESSION_QUERY_CORRUPT_SESSION`, `SESSION_QUERY_SOURCE_CONFLICT` |
| `(port-presets? ctx)`; `(port-preset-mount! ctx agent-ctx id)`; `(port-preset-compose-from! ctx child-ctx parent-ctx)`; `(port-preset-composed-preset ctx agent-ctx) -> (or/c string? #f)` | `agentPresets` | `dsh-context/preset` `agent-presets-mount!`, `agent-presets-compose-from!`, `agent-presets-composed-preset` |
| `(port-permission-preset ctx session) -> (or/c string? #f)` | `permissionPresets` | `dsh-interaction` `permission-presets-current` |
| `(port-sandbox-override ctx session) -> (or/c string? #f)` | `sandboxPolicy` | `dsh-exec/sandbox/policy`: `sandbox-policy-override-of` |
| `(port-approval? ctx) -> boolean?` | `approval` | presence only |
| `(port-archived-session-ids ctx) -> (or/c #f (listof string?))` | `workspaceRegistry` | `dsh-platform/workspace`: `workspace-registry-archived-session-ids` |
| `(port-admit-prompt-content ctx parts) -> (listof jobject?)` | `attachments` | `dsh-fs/attachment`: `attachments-admit-prompt-content` |
| `(port-subprocess-spawn ctx #:argv argv #:cwd cwd #:env env #:grace-ms ms #:stderr mode) -> handle`; `(sp-stdin h)`, `(sp-stdout h)`, `(sp-stderr h)` ports; `(sp-done-evt h)` ready with `(cons exit-code signal)`, each `#f` when unknown; `(sp-terminate! h)`; `(sp-wait-for-exit h [cancel #f]) -> boolean?`; `(port-scrubbed-parent-env ctx) -> jobject?` | `subprocess` | `dsh-exec/subprocess`: `make-spawn-spec` (stdin and stdout `'pipe`, stderr `'pipe` or `'inherit`), `subprocess-spawn`, `subprocess-handle-stdin`, `-stdout`, `-stderr`, `-done` (a `subprocess-outcome`), `-terminate!`, `-wait-for-exit`, `scrubbed-parent-env` |
| `(port-dsh-launcher ctx) -> (or/c #f (listof string?))` | `racket:dshLauncher` | `dsh-boot` provides the argv prefix that starts the running `dsh` |

`mode` of `#:stderr` is `'inherit` or `'pipe`; stdin and stdout are always pipes. The spawned process is a managed range: `sp-terminate!` sends the terminate signal, escalates to kill after `grace-ms`, and covers the child's process group. The projection registry uses `gen:projection-port` of `dsh-llm/ports`.

### `subagents` (key `'subagents`)

`(define-service subagents 'subagents #:contract subagent-runtime?)` in `dsh-subagent/subagents` defines `subagents-key`, `subagents-ref`, `subagents-get`, `provide-subagents`. The dsh method `getProvider(name)` is therefore named `subagents-provider`.

```racket
(subagents-register-provider! x provider) -> disposer?
(subagents-provider x name) -> (or/c subagent-provider? #f)
(subagents-resolve-max-depth x [configured absent]) -> (or/c exact-nonnegative-integer? #f)   ; configured : integer, 'provider-managed or absent
(subagents-start-activation x #:provider provider-name #:label label #:prompt blocks #:parent agent
                            #:cancel evt #:delivery delivery           ; delivery : 'parent or 'caller
                            #:name [name #f] #:child-id [id #f] #:cwd [cwd #f] #:agent-preset [preset #f]
                            #:agent-options [options #f] #:output-schema [schema #f] #:max-depth [depth #f])
  -> subagent-activation?                                              ; waits until the child accepted its first message
(subagents-root-of x caller) -> agent?
(subagents-names-of x agent) -> (values string? (or/c string? #f))     ; own name, creator's name
(subagents-resolve-name x caller name cancel) -> session-id?           ; may wait
(subagents-send-message! x sender target-id content #:cancel evt) -> string?   ; the message id; waits until accepted
(subagents-interrupt! x target-id authority) -> void?                  ; authority : 'user or the exact live ancestor agent
(subagents-wait-for-tree-work x root) -> boolean?                      ; waits
(subagents-drain-descendants! x roots) -> void?                        ; waits
(subagents-list-descendants x root-session-id [cancel #f]) -> (listof jobject?)   ; waits
(subagents-prompt x request cancel #:principal [principal #f]) -> jobject?        ; {messageId}; waits
(subagents-interrupt-by-user x child-session-id) -> jobject?           ; {accepted: #t}
(subagents-delegation-tool! x definition) -> disposer?                 ; rule 63
(subagents-delegation-tools x) -> (listof tool-definition?)
subagents-remote-methods        ; (list (cons "prompt" …) (cons "interruptByUser" …))
```

| Procedure | Errors | Effects on the caller's context |
|---|---|---|
| `subagents-register-provider!` | rule 12 | one effect `subagents.registerProvider()`; emits `subagent/provider-added` after the insert and `subagent/provider-removed` at disposal |
| `subagents-delegation-tool!` | none | one effect `subagents.delegationTool()` |
| `subagents-start-activation` | rules 15 to 23 | none on the caller; the child agent is owned by the manager's own fiber |
| every other procedure | as stated in Behaviour; while `agents` is not mounted the manager is absent and manager-backed calls raise `CONTINUATION_UNAVAILABLE` `continuable subagents require the agents service`, except `subagents-interrupt!` and `subagents-drain-descendants!`, which do nothing, and `subagents-wait-for-tree-work`, which returns `#f` | none |

A descendant row is one of the jobjects `{id, mode, label?, name?, kind: "child", parentId, depth, path?, activity, hasChildren}` (`activity` `running` or `inactive`) and `{kind: "diagnostic", id, parentId, depth, path?, reason}` (`reason` `corrupt`, `unavailable` or `unsupported`).

### `subagentModelSelection` (key `'subagentModelSelection`)

Provided by the settings plugin. The value is opaque and has no public procedure; rule 67 is its behaviour.

### `agentTeams` (key `'agentTeams`)

`(define-service agent-teams 'agentTeams #:contract team-service?)` in `dsh-subagent/team`.

```racket
(agent-teams-enabled? x caller) -> boolean?
(agent-teams-set-enabled! x agent enabled? #:cancel [cancel #f]) -> void?        ; waits for the flush
(agent-teams-create-task! x caller #:subject subject #:description description
                          #:blocked-by [ids '()] #:write-scopes [scopes '()] #:cancel [cancel #f]) -> jobject?   ; a task view; waits
(agent-teams-task x caller id) -> jobject?
(agent-teams-list-tasks x caller) -> (listof jobject?)
(agent-teams-update-task! x caller #:task-id id #:expected-revision n #:action action
                          #:subject [s absent] #:description [d absent] #:blocked-by [b absent]
                          #:write-scopes [w absent] #:owner [owner-id absent] #:cancel [cancel #f]) -> jobject?   ; waits
agent-teams-remote-methods      ; (list (cons "setEnabled" …))
```

`action` is one of the strings `claim`, `release`, `edit`, `set_dependencies`, `complete`, `reopen`, `reassign`, `delete`. None of these registers an effect. All board state is in the root session's log; the service keeps only a per-root transaction queue.

### Waiting and cancellation

- `subagents-start-activation`: `#:cancel` governs the call only until the child's inbox accepted the first message (local) or the run was published (external); afterwards the holder stops the child with `subagent-activation-dispose!`.
- `subagents-send-message!`, `subagents-prompt`, `subagents-resolve-name`, `subagents-list-descendants`: the cancel event; an accepted message is never retracted. `subagents-list-descendants` raises `CANCELLED` `subagent listing was cancelled`; the others raise the cancel reason.
- `subagent-activation-result`, `subagent-activation-dispose!`, `subagents-wait-for-tree-work`, `subagents-drain-descendants!` take no cancel event. A break of the waiting task ends that task's wait only; settlement and teardown continue.
- A provider observes the `cancel` field of its request; after publication it stops through `subagent-run-dispose`.
- Team mutations: `#:cancel` is checked at the points of rules 91 and 92; once the `team/task` event is appended the task is visible whatever happens next.
- `wait_agent`: rule 71.

## Events

```racket
(define-event subagent/provider-added   'subagent/provider-added   #:mode emit #:args (subagent-provider?))
(define-event subagent/provider-removed 'subagent/provider-removed #:mode emit #:args (string?))
(define-event subagent/start            'subagent/start            #:mode emit #:args (jobject?))
(define-event subagent/end              'subagent/end              #:mode emit #:args (jobject?))
```

`dsh-subagent/subagents` exports the `on-…` and `…-name` bindings and no dispatcher.

| Event | Dispatched by, when | Guarantees |
|---|---|---|
| `subagent/provider-added` | `subagents-register-provider!`, after the provider is resolvable | Plain `emit`: a listener that raises unwinds the registration. |
| `subagent/provider-removed` | the provider's disposer, after removal | Contained: each listener is called on its own and a failure is logged at `warning` as `subagent: subagent/provider-removed listener threw: <name>: <message>` (or `rejected` for a failed returned task). Accepted runs stay with their holders. |
| `subagent/start` | the manager, once per activation, after the activation is resident and its inbox listeners are attached | Scope-filtered: resolved with `scoped-callbacks` using the tree root as scope key and `(service-realm-filter provider-ctx 'subagents)` as base, so a listener registered through the root agent's context hears every activation of its tree and an untagged listener hears all. Contained as above. For a local child `(agents-find … id)` is the child during the notification. |
| `subagent/end` | the manager, once per activation, after resource release and the parent notice and before the activation's result is delivered | Same audience and containment. With a teardown failure the payload has `stopReason: "error"` and no `lastAssistantMessage`. |

`<name>` in the log text is the dsh error name of a harness error and `Error` for any other exception; a non-exception value prints with `display`.

Consumed, owned elsewhere: `agent/disposed`, `agent/error`, `agent/inbox/inserted`, `agent/inbox/claimed`, `agent/inbox/discarded` and `session/event` (manager; the per-activation ones are registered through the child's `agent-ctx`); `agent/pre-step` (archive admission); `agent/created` (model-selection settings, team default); `tools/result` (structured output); `workspace/session-activity` (waterfall) and `workspace/session-stop`, registered by name with `ctx-on`.

## Tools

Result values are jvalues; "text" is the single text block the model sees. A raised failure becomes an error result with the message, through the pipeline of `dsh-tools`.

### `subagent` and `subagent_fork` (`tool-subagent/src/index.ts:207`)

One definition per `tool-subagent` row, built with `make-tool` at mount time because its name, description and parameter list depend on the row's config and provider. Name: `toolName`.

Description: the wording of the provider kind, then the suffixes, concatenated with no separator (`index.ts:74-97`, `148-158`; R11 "`subagent` / `subagent_fork`"), all copied verbatim: the fresh wording when `provider-inherits-parent-context?` is false, else the inheriting wording; then the sentence that starts ` This tool starts an independently managed subagent`; then `` Use `send_message` to steer it while running or continue its conversation after it finishes.`` for a local provider or ` This backend does not accept follow-up messages.` for an external one; with `modelSelection`, the selection sentence (`…falling back to this backend's route defaults.` when the provider has route defaults, else `…falling back to compatible parent values.`); with `modelSelection` and an inheriting provider, ` Changing the route can prevent provider-side reuse of the inherited conversation prefix.`

Parameters, in this order (descriptions verbatim from `index.ts:160-205` and `preset-selection.ts:44-49`):

| Name | Type | Required | Present when |
|---|---|---|---|
| `cwd` | string | no | always |
| `description` | string | yes | always |
| `name` | string | no | always |
| `prompt` | string | yes | always; its description is the fresh or the inheriting prompt wording |
| `agent_preset` | string with `enum` = `allowedAgentPresets` | no | `allowedAgentPresets` is configured; description `Agent preset for this child. Omit to inherit the parent agent's current preset.` or `Agent preset for this child. Omit to use <agentPreset>.` |
| `provider`, `model`, `reasoning_effort` | string | no | `modelSelection` is true |

Output spec: a closed object with `kind` (string, `const` `"activation"`, required) and `name` (string, required). Value `{kind: "activation", name}`; text `started subagent <name>`; presentation meta `{kind, name}`. Concurrency-safe: always. Execution: rule 61. Errors the model can see: the preset and model-selection messages of rules 61 and 62, `subagent depth <n> exceeds maxDepth <m>`, and the service errors of rules 15 to 22.

### `list_subagent_models` (`tool-subagent/src/list-models.ts:109`; only with `modelDiscovery: true`)

```racket
(define-tool list-subagent-models-tool
  #:name "list_subagent_models"
  #:description "Inspect the routes available for explicit subagent model selection. No arguments: authorized providers. `provider`: that provider's authorized models. `provider` + `model`: that model and its reasoning efforts. Query when choosing an explicit child route or reasoning effort. Omit optional fields rather than sending empty strings."
  #:parameters ([provider (v-string #:description "Registered LLM provider id.")]
                [model (v-string #:description "Exact model id; requires provider.")])
  #:output (v-string)
  (render (value) (list (text-block value)))
  (execute (exec) …)                                    ; rule 66
  (concurrency-safe? () #t))
```

### `send_message` (`tool-subagent-control/src/index.ts:43`)

```racket
(define-tool send-message-tool
  #:name "send_message"
  #:description "Send a message to an agent. A working agent receives it at its next step; an idle agent starts a new turn with it. Returns delivery confirmation."
  #:parameters ([agent (v-string #:description "The name of another agent in your subagent tree, as shown by list_agents.") #:required]
                [message (v-string #:description "The message to deliver to the agent.") #:required])
  #:output (v-object #:additional? #f #:properties (parameters (param "messageId" (v-string) #:required? #t)))
  (render (value) (list (text-block (string-append "message delivered to agent " agent))))
  (execute (exec) …))                                   ; rule 68
```

Value `{messageId}`. Not concurrency-safe. Errors: `send_message requires a calling agent (exec.agent was undefined)`; `UNAUTHORIZED` `send_message requires another agent in the subagent tree`; `AGENT_NAME_NOT_FOUND`; and the delivery errors of rules 41 to 45.

### `list_agents` (`tool-subagent-control/src/list-agents.ts:45`)

Name `list_agents`; description: the string at `list-agents.ts:48-56`, copied verbatim (R11 "`list_agents`"); no parameters. Output spec: an array of closed objects with `name` (string, required), `status` (string, required, `enum` `running inactive corrupt unsupported unavailable`), `description` (string). Text: one line per row, `<name> [<status>]` followed by ` — <description>` (U+2014 with a space on each side) when present, joined with `\n`. Concurrency-safe. Rule 69.

### `wait_agent` (`tool-subagent-control/src/wait-agent.ts:90`)

```racket
(define-tool wait-agent-tool
  #:name "wait_agent"
  #:description "Wait for input at your next step, including agent messages, completion notifications, and user steering. Returns immediately if new input is pending. `timedOut: false` means new input is pending. Pending input is delivered to the model after code execution finishes."
  #:parameters ([timeout_ms (v-integer #:description "Wait duration in milliseconds, from 10000 through 3600000. Defaults to 30000.") #:or 30000])
  #:output (v-object #:additional? #f #:properties (parameters (param "timedOut" (v-boolean) #:required? #t)))
  (render (value) (list (text-block (jvalue->string value))))
  (execute (exec) …))                                   ; rules 70 and 71
```

Value `{timedOut}`. Errors: `WAIT_INVALID_TIMEOUT` `timeout_ms must be an integer from 10000 through 3600000`; `WAIT_UNAVAILABLE` with `wait_agent requires a calling agent`, `wait_agent requires the exact live calling agent`, `wait_agent ended because the calling agent was disposed` or `wait_agent ended because its plugin was unloaded`. Cancellation raises the caller's cancel reason.

### `interrupt_agent` (`tool-subagent-control/src/index.ts:119`; only when `interrupt` is true)

```racket
(define-tool interrupt-agent-tool
  #:name "interrupt_agent"
  #:description "Ask a subagent to stop its current work. This call returns without waiting for it to stop. You can continue a local subagent's conversation later with send_message. External executions stop permanently and cannot receive follow-ups. Subagents it started will keep running."
  #:parameters ([agent (v-string #:description "The name of an agent created under you: your direct child or a deeper descendant.") #:required])
  #:output (v-object #:additional? #f #:properties (parameters (param "accepted" (v-boolean) #:required? #t)))
  (render (value) (list (text-block (string-append "interrupt requested for agent " agent))))
  (execute (exec) …))                                   ; rule 72
```

### `structured_output` (`subagent/src/structured.ts:75`; child-scoped)

Registered with `make-raw-tool` through the child's `agent-ctx` only when the activation has an output schema. Name `structured_output`; description `Report your final structured result. Call this exactly once, when your answer is complete; the arguments must match this tool's parameter schema exactly.`; parameters: the caller's object schema, unchanged; output schema `{type: "object", properties: {recorded: {type: "boolean", const: true}}, required: ["recorded"], additionalProperties: false}`; value `{recorded: true}`; text `Structured output recorded.` Rule 56.

### Team tools (`tool-agent-team/src/index.ts`)

All four are registered with `#:when` equal to "Team mode is enabled for the tree root of the activation's agent" (rule 96). Every text is `(jvalue->string value)`.

```racket
(define-tool team-task-create-tool
  #:name "team_task_create"
  #:description "Create one unowned pending task on the shared Team task board."
  #:parameters ([subject (v-string #:description "Concise task title.") #:required]
                [description (v-string #:description "Complete task details and acceptance criteria.") #:required]
                [blocked_by (v-array #:items (v-string) #:description "Task ids that must complete first.")]
                [write_scopes (v-array #:items (v-string) #:description "Advisory workspace-relative file or directory prefixes this task expects to modify.")])
  #:output task-view-spec …)
(define-tool team-task-list-tool
  #:name "team_task_list"
  #:description "List shared tasks, including readiness, owner, revision, blockers, and write-scope warnings."
  #:parameters ([status (v-string #:enum '("pending" "in_progress" "completed") #:description "Optional exact status filter.")]
                [owner (v-string #:description "Optional owner agent name filter; cannot be combined with unowned.")]
                [unowned (v-boolean #:description "Filter tasks by whether they have no owner; cannot be combined with owner.")]
                [ready (v-boolean #:description "Optional readiness filter.")]
                [cursor (v-integer #:description "Zero-based result offset. Defaults to 0.") #:or 0]
                [limit (v-integer #:description "Number of rows, 1 through 100. Defaults to 50.") #:or 50])
  #:output task-list-spec … (concurrency-safe? () #t))
(define-tool team-task-get-tool
  #:name "team_task_get"
  #:description "Read the complete latest value of one shared task before changing or executing it."
  #:parameters ([task_id (v-string #:description "Shared task id.") #:required])
  #:output task-view-spec … (concurrency-safe? () #t))
(define-tool team-task-update-tool
  #:name "team_task_update"
  #:description "Compare-and-set a shared task action using the latest revision from team_task_get or team_task_list."
  #:parameters ([task_id (v-string #:description "Shared task id.") #:required]
                [expected_revision (v-integer #:description "Current task revision used as the CAS precondition.") #:required]
                [action (v-string #:enum '("claim" "release" "edit" "set_dependencies" "complete" "reopen" "reassign" "delete") #:description "Task transition to apply.") #:required]
                [subject (v-string #:description "Replacement title for edit.")]
                [description (v-string #:description "Replacement details for edit.")]
                [blocked_by (v-array #:items (v-string) #:description "Complete blocker list for set_dependencies.")]
                [write_scopes (v-array #:items (v-string) #:description "Replacement advisory write scopes for edit.")]
                [owner (v-string #:description "Agent name of the root or any continuable descendant for root-only reassign; omit to unassign.")])
  #:output task-view-spec …)
```

`task-view-spec` is the closed object with properties in this order: `id` (string, required), `revision` (integer, required), `subject`, `description` (strings, required), `status` (string, required, `enum` `pending in_progress completed deleted`), `owner` (string), `blockedBy`, `writeScopes` (arrays of string, required), `ready` (boolean, required), `writeScopeWarnings` (array of string, required). `task-list-spec` is the closed object `{tasks: array of task-view-spec (required), nextCursor: integer}`. Values are tool views (Data). Rule 97.

## Plugins

Every `#:name` is the npm name; `#:meta` records the dsh plugin name under `'dsh-name`.

| dsh npm name | Module | Inject | Provides |
|---|---|---|---|
| `@deepseek-ai/dsh-subagent` | `plugin/subagent` | `workingDirectory`, `sessionProjections`, `sessions`; dynamic `agents`; optional `sessionPersistence`, `sessionQuery`, `llm`, `attachments`, `agentPresets`, `sandboxPolicy`, `approval`, `permissionPresets`, `workspaceRegistry` | `subagents` |
| `@deepseek-ai/dsh-subagent-spawn-in-process` | `plugin/subagent-spawn-in-process` | `subagents` | none |
| `@deepseek-ai/dsh-subagent-fork-in-process` | `plugin/subagent-fork-in-process` | `subagents` | none |
| `@deepseek-ai/dsh-tool-subagent` | `plugin/tool-subagent` | `tools`, `subagents`, `systemPrompt`, `sessionProjections`; optional `llm`, `agentPresets` | none |
| `@deepseek-ai/dsh-tool-subagent/model-selection-settings` | `plugin/model-selection-settings` | `sessionProjections`, `sessions` | `subagentModelSelection` |
| `@deepseek-ai/dsh-tool-subagent-control` | `plugin/tool-subagent-control` | `tools`, `subagents`, `agents`, `systemPrompt` | none |
| `@deepseek-ai/dsh-subagent-acp` | `plugin/subagent-acp` | `subagents`, `subprocess` | none |
| `@deepseek-ai/dsh-subagent-claude-code` | `plugin/subagent-claude-code` | `subagents`, `subprocess` | none |
| `@deepseek-ai/dsh-subagent-codex` | `plugin/subagent-codex` | `subagents`, `subprocess` | none |
| `@deepseek-ai/dsh-subagent-dsh-sdk` | `plugin/subagent-dsh-sdk` | `subagents`, `subprocess` | none |
| `@deepseek-ai/dsh-agent-team` | `plugin/agent-team` | `agents`, `sessions`, `sessionPersistence`, `sessionProjections`, `subagents` | `agentTeams` |
| `@deepseek-ai/dsh-tool-agent-team` | `plugin/tool-agent-team` | `agentTeams`, `subagents`, `tools`, `systemPrompt` | none |

`sessions` is added to the `subagent` row's inject list (the Racket body registers event types) and `subprocess` to the `dsh-sdk` row's (dsh spawns that child through its SDK client; here the provider spawns it). Both services are on the host plane of every dsh configuration that mounts these rows.

Config schemas (exactly the dsh keys, plus the `x-racket` keys named). A rejected config fails the mount with `exn:fail:cordis:validation`, whose message starts `invalid config:` (WAVE3.md, "Config validation text"):

| Plugin | Field | Type | Default |
|---|---|---|---|
| subagent | `maxDepth` | integer 0 to 9007199254740991, volatile | `1` |
| | `maxActiveSubagents` | integer ≥ 1, volatile | `8` |
| spawn-in-process | `providerName` | string | `"spawn"` |
| fork-in-process | `providerName` | string | `"fork"` |
| tool-subagent | `provider` | string, required | none |
| | `toolName` | string | `"subagent"` |
| | `modelSelection`, `modelDiscovery` | boolean | `false` |
| | `agentOptions` | object `{provider, model, reasoningEffort (at least 1 character), maxTokens (integer ≥ 1)}` | absent; no empty object is materialised |
| | `agentPreset` | string, at least 1 character | absent |
| | `allowedAgentPresets` | non-empty array of non-empty strings | absent |
| | `maxDepth` | natural number or the literal `"provider-managed"` | absent |
| model-selection-settings | `enabled` | boolean, volatile | `false` |
| | `allowedModels` | array of `{provider, model}`, both required and at least 1 character, volatile | `[]` |
| tool-subagent-control | `interrupt` | boolean | `true` |
| subagent-acp | `providerName` | string | `"acp"` |
| | `command` | string, required | none |
| | `args` | array of string | `[]` |
| | `permission` | `"allow"` or `"reject"` | `"reject"` |
| | `env` | dict of string | `{}` |
| | `disposeEofGraceMs` | number | `6000` |
| | `disposeGraceMs` | number | `3000` |
| subagent-claude-code | `providerName` | string, at least 1 character | `"claude-code"` |
| | `model` | string, at least 1 character | absent |
| | `env` | dict of string | `{}` |
| | `permissionMode` | `dontAsk`, `acceptEdits`, `auto`, `plan` or `bypassPermissions` | `"dontAsk"` |
| | `disposeGraceMs` | number | `3000` |
| | `x-racket.node` | string | `"node"` |
| | `x-racket.sdkDir` | string | `<Harness home>/sidecars/subagent-claude-code` |
| subagent-codex | `providerName` | string, at least 1 character | `"codex"` |
| | `model` | string, at least 1 character | absent |
| | `env` | dict of string | `{}` |
| | `permissionMode` | `never`, `approve-for-me` or `dangerously-bypass-approvals-and-sandbox` | `"never"` |
| | `disposeGraceMs` | number | `3000` |
| | `x-racket.command` | non-empty array of string | `["codex"]` |
| subagent-dsh-sdk | `providerName` | string | `"dsh-sdk"` |
| | `dshBin` | string | absent |
| | `profile` | string | `"sdk"` |
| | `patches` | array of string | `[]` |
| | `dshHome` | string, required | none |
| | `provider` | string | `"deepseek-official"` |
| | `model` | string | `"deepseek-v4-flash"` |
| | `maxTokens` | integer 1 to 9007199254740991 | absent |
| | `env` | dict of string | `{}` |
| | `shutdownTimeoutMs` | number | `1000` |
| | `disposeEofGraceMs` | number | `6000` |
| | `disposeGraceMs` | number | `3000` |
| agent-team | `maxTasks` | integer ≥ 1 | `256` |
| | `defaultEnabled` | boolean | `false` |
| tool-agent-team | none (an object schema with no declared key) | | |

Load-time checks beyond the schema, each raising with the exact message. tool-subagent: a `persona` or `toolFilter` key raises `tool-subagent: <field> is no longer supported; configure persona and tool plugins in an Agent Preset and select it with agentPreset (spawn only)`; `tool-subagent: allowedAgentPresets contains duplicate preset ids`; `tool-subagent: agentPreset must be included in allowedAgentPresets`; a configured preset selection without the `agentPresets` service raises `tool-subagent: agent preset selection requires the agent-presets service`; `maxDepth` other than `provider-managed` passes `assert-subagent-max-depth`. agent-team: a `maxMembers`, `maxMessageBytes` or `disposalTimeoutMs` key raises `TEAM_INVALID_CONFIG` `agent-team: <key> is no longer supported; teammates are subagents, so subagent limits and inbox delivery apply`; `maxTasks must be a positive safe integer` (`TEAM_INVALID_CONFIG`). tool-agent-team: an `interrupt`, `freshProvider` or `forkProvider` key raises `tool-agent-team: <key> is no longer supported; create teammates with a subagent tool`. The four external providers: the grace and timeout checks of rule 75; dsh-sdk also `subagent-dsh-sdk maxTokens must be a positive safe integer`, `subagent-dsh-sdk dshHome must be an absolute path` and, for `dshBin` and each `patches[<i>]`, `subagent-dsh-sdk <field> must name an existing file: <absolute path>` (all `exn:fail:contract`).

Plugin bodies, in order:

- `subagent`: register the session event types `subagent/descriptor` and `subagent/catalog` (the policy type is registered by its own owners); register the projections `subagentCatalog`, `subagentTiming`, `subagent`, in that order, and keep the catalog and identity handles; create and provide the service; `(ctx-inject ctx '(agents) …)` whose body builds the manager (rule 28) and registers the effect `subagents.managerBinding()` that clears the manager slot. Registering an event type means: call `sessions-register-event-type!` unless `sessions-event-type` already returns a declaration for the tag.
- `subagent-spawn-in-process`: register a provider with all four capabilities, `provider-inherits-parent-context?` false, and `provider-prepare-continuable` returning `#f`.
- `subagent-fork-in-process`: register a provider with capabilities agent options, output schema and depth limit (no agent preset), `provider-inherits-parent-context?` true, and `provider-prepare-continuable` returning the parent session's events from seq 0 through its last `turn/end`, or `#f` when the parent has no completed turn.
- `tool-subagent`: rule 60.
- `model-selection-settings`: register the policy event type and projection; the `agent/created` listener of rule 67; provide the service.
- `tool-subagent-control`: register `list_agents`, `wait_agent` (with its lifetime effect `subagent-control.waits()`), `send_message`, the identity context (rule 73), and `interrupt_agent` when `interrupt` is not false.
- the four external providers: validate; `subagents-register-provider!`.
- `agent-team`: validate; register the five team event types and the `agentTeam` projection; create and provide the service; when `defaultEnabled`, the `agent/created` listener of rule 90.
- `tool-agent-team`: validate; register the `team:policy` section (rule 96) and the four tools.

### `plugin-table`

`dsh-subagent/plugins` provides `plugin-table`, twelve rows.

```racket
(define plugin-table
  (list
   (cons "@deepseek-ai/dsh-subagent" 'dsh-subagent/plugin/subagent)
   (cons "@deepseek-ai/dsh-subagent-spawn-in-process" 'dsh-subagent/plugin/subagent-spawn-in-process)
   (cons "@deepseek-ai/dsh-subagent-fork-in-process" 'dsh-subagent/plugin/subagent-fork-in-process)
   (cons "@deepseek-ai/dsh-tool-subagent" 'dsh-subagent/plugin/tool-subagent)
   (cons "@deepseek-ai/dsh-tool-subagent/model-selection-settings" 'dsh-subagent/plugin/model-selection-settings)
   (cons "@deepseek-ai/dsh-tool-subagent-control" 'dsh-subagent/plugin/tool-subagent-control)
   (cons "@deepseek-ai/dsh-subagent-acp" 'dsh-subagent/plugin/subagent-acp)
   (cons "@deepseek-ai/dsh-subagent-claude-code" 'dsh-subagent/plugin/subagent-claude-code)
   (cons "@deepseek-ai/dsh-subagent-codex" 'dsh-subagent/plugin/subagent-codex)
   (cons "@deepseek-ai/dsh-subagent-dsh-sdk" 'dsh-subagent/plugin/subagent-dsh-sdk)
   (cons "@deepseek-ai/dsh-agent-team" 'dsh-subagent/plugin/agent-team)
   (cons "@deepseek-ai/dsh-tool-agent-team" 'dsh-subagent/plugin/tool-agent-team)))
```

## Behaviour

Numbering is for tests. "Raise CODE `message`" means `exn:fail:subagent` (or `exn:fail:team` in the team rules) with that code; "raise" without a code means `exn:fail` with the exact message. "Live" for an agent `a` means `(eq? (agents-find agents (agent-id a)) a)`.

**Names** (R11 "Subagent identifiers and names"; `names.ts`)

1. `root-agent-name` is `"lead"`. `(agent-name? s)` holds when `s` matches `^[a-z][a-z0-9-]{0,31}$` and is not `lead`. `(join-agent-path parent-path name)` is `#f` when either is `#f`, `name` when the parent path is `""`, else `<parent>/<name>`. `(agent-address path id)` is `lead` for `""`, the path when it is a string, else the id. `(parent-agent-path path)` is the text before the last `/`, or `""`.
2. Sibling name reservation, per creator agent, against the creator's committed catalog names plus reservations in flight: no requested name takes the first free `agent-<n>` counting from 1; an invalid requested name raises `INVALID_AGENT_NAME` `agent name <JSON string> is invalid; use 1-32 lower-case letters, digits, or hyphens starting with a letter, other than "lead"`; a taken one raises `DUPLICATE_AGENT_NAME` `agent name <JSON string> is already used by another subagent you created; choose another name`. A reservation is released when the start returns or raises; by then the catalog fact holds the name.
3. The child session id is the requested `child-id`, else a fresh lowercase UUID. An external provider mints its own id in the same namespace.

**Descriptor and catalog** (R11 "`subagent/descriptor`", "`subagent/catalog`"; `descriptor.ts`, `catalog.ts`)

4. `(snapshot-subagent-descriptor #:mode "continuable" #:provider p #:label l #:agent-provider [..] #:agent-model [..] #:agent-reasoning-effort [..])` returns the data jobject with `version: 3` first and the given keys in the declared order; a value that is not lossless JSON raises `subagent descriptor is not losslessly JSON-serializable`.
5. `(parse-subagent-descriptor data)`: not an object raises `persisted subagent descriptor payload must be an object`; a non-number `version` raises `… version must be a number`; a version other than 3 returns `#f`; `mode` must be `one-shot` or `continuable`; the key set is strict (`persisted subagent descriptor payload has unknown field "<k>"`; one-shot allows `version mode provider label`, continuable also `agentProvider agentModel agentReasoningEffort persona toolFilter`); `provider` and, for continuable, `label` must be strings; optional strings and `toolFilter` (`allow` and/or `deny` string arrays, strict keys) are checked with the messages of `descriptor.ts:85-125`. `(fold-subagent-descriptor events)` parses the first `subagent/descriptor` event of the list, or returns `#f`.
6. Catalog facts written: local child `{version: 3, childId, childCreatedAt: <child header createdAt>, mode: "continuable", label, name}`; external child `{version: 3, childId, childCreatedAt: <now in ms>, mode: "external", label, name}`.
7. Catalog fold: an event with seq below the session's inherited event count is ignored; every other `subagent/catalog` event is validated against the six accepted shapes of versions 0 to 3 (`catalog.ts:55-80`: strict keys; `childCreatedAt` a non-negative integer; versions 0 and 1 `one-shot` with optional label or `continuable` with label; version 1 also `unknown`; version 2 `external`; version 3 `continuable` or `external` with a valid `name`) and appended to the chunked list (a chunk holds 64 values; a full head becomes `previous` of a new head). An invalid own fact raises from the fold. `catalog-entries` yields `{id, createdAt, mode, label?, name?}` in event order; `catalog-names` the set of names.

**Projections** (`projection.ts`)

8. `subagentTiming` fold: `turn/start` drops `lastTurnCompleted` and sets `active: {since, through}` to the event time when a descriptor was seen, else `pendingTurnStart`; `subagent/descriptor` resets to `{descriptorSeen: true, settledMs: 0}` with `active` from the open interval's start (or the pending start) through the event time; `turn/end` before a descriptor clears `pendingTurnStart`, and after one adds `max(0, time − since)` to `settledMs`, drops `active` and sets `lastTurnCompleted` to whether the reason kind is `completed`; any other event moves `active.through` to its time.
9. `subagent` fold: each `subagent/descriptor` event sets the identity `{mode, label?, seq}` from a successful parse and clears it when the parse fails or returns `#f`. The fold never raises.
10. `subagentModelSelectionPolicy` fold: the first `subagent/model-selection-policy` event sets the state to its `allowedModels` after checking them (rule 67); later events are ignored; an empty list raises `subagent/model-selection-policy requires at least one route`.
11. `agentTeam` fold: rule 95.

**Provider registry** (`index.ts:522-600`)

12. `subagents-register-provider!`: a provider that implements neither start operation raises `UNSUPPORTED_CAPABILITY` `subagent provider "<name>" must implement start or prepareContinuable` before any effect. Inside the effect: a taken name raises `DUPLICATE_PROVIDER` `a subagent provider named "<name>" is already registered`; insert; collect the inverse (remove, then dispatch `subagent/provider-removed`); emit `subagent/provider-added`, whose failure runs the inverse. Removing a provider blocks new starts only.
13. `subagents-resolve-max-depth`: `'provider-managed` gives `#f`; a number gives itself; absent gives the current value of the volatile `maxDepth` after `assert-subagent-max-depth` (`exn:fail:contract` `subagent maxDepth must be a non-negative safe integer`).
14. Capability check for a start, first failure wins: a requested preset needs `agent-preset?` and a provider that does not inherit parent context, else `UNSUPPORTED_CAPABILITY` `subagent provider "<p>" does not support independent agent preset selection`; requested agent options, output schema and max depth need `agentOptions`, `outputSchema`, `depthLimit` in that order, else `… does not support the "<cap>" capability`.

**Starting an activation** (R11 "Activation start, local child"; `index.ts:267-292`, `manager.ts:308-492`, `801-925`)

15. Service checks, in order: unknown provider raises `NO_PROVIDER` `no subagent provider registered for "<name>"`; a `child-id` with an external provider raises `UNSUPPORTED_CAPABILITY` `reserved child ids require a local backend`; `assert-subagent-max-depth`; rule 14; the manager must exist; the parent must be live, else `UNAUTHORIZED` `subagent creation requires the exact live parent agent`; `assert-object-json-schema` on the output schema. Then the local or the external path, each of which re-checks, immediately before calling the provider, that the registered provider is still the one checked, else `PROVIDER_CHANGED` `subagent provider "<p>" changed during startup; retry the delegation`.
16. Local start, before the first `await` of the calling task: admission of the parent (rule 51); ancestry `root = (root-of parent)`, `ancestors` = the parent's own activation ancestors followed by the parent id; reserve the name (rule 2); `path` = `(join-agent-path <path of parent> name)`, where the root's path is `""` and a resident member's path is its activation's.
17. Startup tracking: register a *materialisation* `{root, settled-evt, cancel source}` so drains and host waits can join it; the working cancel event is `(cancel-evt-any caller-cancel source-evt)`. A raise that is an `exn:fail:abort` first re-runs admission of the root, so a drain surfaces as `DRAINING`. The materialisation is removed and its event made ready on every exit.
18. Still before the first `await`: persistence is required unless delivery is `'caller`, else `PERSISTENCE_UNAVAILABLE` `continuable subagents require session persistence (load a dsh-session-persistence backend)`; choose the child id; it must be free (not resident, no live agent, no live session), else `DUPLICATE_CHILD` `subagent "<id>" already exists`; `child-depth` (rule 24); child agent options (rule 25); the descriptor snapshot with the options' provider, model and effort; the delegated policy (rule 27).
19. Then, waiting: `cwd` is the requested directory when absolute, else the requested path (or `.`) resolved against `(port-working-directory-ensure ctx parent cancel)`; check cancellation; `(provider-prepare-continuable provider (continuable-create-request cwd child-id parent cancel))` after the provider re-check; check cancellation and admission. The inherited event count is the seed's length (0 without a seed).
20. Inside the child lock (rule 52): check cancellation, admission and that the id is free; for a requested `child-id` also `(port-persistence-stat …)` must be `#f` (same re-checks after the wait), else `DUPLICATE_CHILD`; materialise (rules 29 and 30) with meta from rule 26; then submit the first message (rule 21).
21. Submitting the first message: content is the prompt, with the return guidance block appended unless delivery is `'caller`; when the content has an image, the child's model must accept images (rule 45); build `(make-user-message #:content content #:source (user-source))`; check cancellation, admission of the parent; deliver with `agent-followup!` (rule 42, queue delivery); wake the watcher; append the parent's catalog fact (rule 6) to the parent's session, after re-checking admission; mark the activation accepted and start its settlement watcher. Any failure disposes the activation (a failure of that disposal is logged as `subagent continuation: disposal after admission or catalog append failure also failed: <error>`) and re-raises. The return guidance is the text of `continuation-messages.ts:88-92` (R11 "Return guidance"), copied verbatim, as its own text block.
22. The result is `(subagent-activation child-id (agent-address path child-id) message-id result-evt dispose)`.
23. External start: admission and ancestry as rule 16; a requested name with delivery `'caller` raises `UNSUPPORTED_CAPABILITY` `agent names require a cataloged child; caller-delivered external runs are not cataloged`; a name is reserved only for delivery `'parent`. Under startup tracking: resolve `cwd` as rule 19; materialise with a start procedure that calls `(provider-start provider (subagent-start-request cwd …))` after the provider re-check, under a cancel source that the working cancel event cancels with its reason; a run whose id is not free is disposed and raises `DUPLICATE_CHILD`; re-check admission and cancellation; for delivery `'parent` append the external catalog fact; accept (rule 31). A failure after the activation exists disposes it (a failed rollback is logged as `subagent "<id>" admission rollback failed: <message>`) and re-raises.

**Child options and policy** (R11 "Child options and policy inheritance"; `child-agent.ts`, `depth.ts`)

24. `(delegation-depth-of agent)` is the larger of the session header's `delegationDepth` (0 when absent) and the agent options' `subagentDepth` (0 when absent; a value that is not a non-negative safe integer raises `exn:fail:contract` `agent subagentDepth must be a non-negative safe integer`). `(resolve-child-depth parent max-depth)` is that plus 1; above `max-depth` it raises `exn:fail:subagent-depth` `subagent depth <n> exceeds maxDepth <m>`.
25. `(parent-agent-options-for-delegation parent)`: without a request header, the parent's options; with one, the options with `provider`, `model` and `reasoningEffort` taken from the header's config (the effort removed when the config has none). `(resolve-child-agent-options parent requested child-depth)`: the parent's `provider`, `model`, `reasoningEffort`, `maxTokens` (those present), overlaid with the requested options, then `subagentDepth`; when the resulting route differs from the parent's and the request named no effort, `reasoningEffort` is removed. A requested option whose value is `'null` counts as an explicit clear of that key.
26. `(child-session-meta parent child-depth seeded? selected-preset)` is the jobject, keys in this order: `cwd` (the parent header's, when present), `agentPreset` (the selected preset, else `(port-preset-composed-preset …)` of the parent, when either exists), `parentSession`, `isSeeded`, `origin: "subagent"`, `delegationDepth`.
27. Delegated policy, captured from the parent through the parent's `agent-ctx`: `permissionPreset` only when the parent's current preset is `auto` or `danger-full-access`; `sandboxMode` the parent session's explicit override only; `approvalPolicy` `"never"` whenever an `approval` service is mounted. `append-delegated-policy!` appends, in this order and each only when set, `sandbox/mode`, `approval/policy`, `permission/preset`.

**Materialising** (`manager.ts:714-925`)

28. The manager is built inside the `agents`-injected child context. It mounts an empty plugin under that context and uses its context as *owner* of every child agent; it installs archive admission (rule 58); it listens to `agent/disposed` (the disposed agent is removed from the closing roots, and a local activation holding that exact agent starts its close transaction with `stop?` false; a failure is logged as rule 37); and it registers one effect `subagents.manager()` whose inverses run "drain everything" (rule 50) and then the owner fiber's disposal.
29. Materialise: admission of the root; check cancellation; reserve a capacity slot in the root's pool (rule 53); on any failure release it. Local: call `agents-create` (with session id, meta, seed, inherited event count, agent options, the working cancel event and the setup below) or, for a cold resume, `agents-resume`, both through the owner context. Setup `(lambda (child-ctx child) …)`, in order: with an explicit preset, `(port-preset-mount! … child-ctx preset)` (no `agentPresets` service raises `PRESET_UNAVAILABLE` `selecting a child agent preset requires the agent-presets service`) and then the overrides; for a fresh creation only: append `agent-preset/selected` (explicit preset only), `subagent/descriptor`, the delegated policy events, then `(port-working-directory-set! … child cwd cancel)` (no service raises `local subagents require the working-directory service`); without an explicit preset, `(port-preset-compose-from! … child-ctx (agent-ctx parent))` when a creator is given and the service exists, and then the overrides; with an output schema, `attach-structured-runtime!` (rule 56). The *overrides* register through `child-ctx` the runtime context `subagent:delegation` at context order `SUBAGENT_DELEGATION` with the text `subagent-delegation-context` (`child-agent.ts:171-175`, copied verbatim; R11 "Child delegation statement"), and, only for a cold resume of a historical child, the descriptor's `persona` as section `deployment:persona-prefix` and its `toolFilter` with `tools-restrict!`.
30. Then build the activation record `{child-id, run-id, provider, root, ancestors, path, delivery, result, closing: #f, accepted?: #f}` plus, for a local one, the handle, `output-start` (the session's next seq), the structured attachment, `failure-at`, the poke and `omit-closing-text?`; for an external one, the run and its cancel source. Store it as resident. Then, protected by rollback: admission of the root, check cancellation, attach the listeners through the child's `agent-ctx` (`agent/error` sets `failure-at` to the session's next seq and wakes; a `turn/end` session event at or after `failure-at` clears it; `agent/inbox/inserted` and `agent/inbox/discarded` wake; `agent/inbox/claimed` clears `omit-closing-text?` and wakes; a `tool/call` session event clears `omit-closing-text?`), and dispatch `subagent/start`. Rollback disposes the handle or run, removes the resident entry, releases the slot and fails the result with the cause. Resulting order of a fresh local child's log: inherited seed, `agent-preset/selected` (explicit preset only), `subagent/descriptor`, delegated policy events, the working-directory event, then the first turn.

**Settlement** (R11 "Settlement of a local activation"; `manager.ts:939-1116`, `activation.ts`, `lifecycle.ts`)

31. Accept: mark accepted. A local activation starts its settlement watcher as a task under the manager's custodian. An external one waits for the run's result and then starts the close transaction with `stop?` false; a failure there is logged (rule 37).
32. Watcher loop: remember the current poke; `agent-when-idle`; stop when the activation is closing; under the child lock compute the state: `closed` (closing), `retry` (the poke was replaced), `wait` (no `failure-at` and the inbox holds a next-turn or next-step message), else `ready`. `closed` ends the watcher; `retry` loops; `wait` waits for the remembered poke and loops. `ready`: remember the session's next seq; flush the session with `sessions-flush` through the child's context (a failure is logged at `warning` as `subagent "<id>" best-effort final session flush failed; the persisted state may be unavailable or stale on resume: <error-chain>`); under the child lock compute the state again (not `ready` is handled as above), require the seq to be unchanged (else loop), and claim the agent's idle phase with `(agent-run-maintenance agent (lambda (_) <start the close transaction with stop? #f>))`; when that raises because the agent is not idle, loop. Then wait for the close transaction, log a failure (rule 37) and end.
33. Waking replaces the poke: the current one-shot event is made ready and a fresh one installed. External activations have no poke.
34. The close transaction of an activation is memoised: the first caller sets `closing` synchronously and every later caller waits for the same completion. `(finish activation stop?)`, in order: wake. Obtain the result: external with `stop?`: cancel the run's source with `{kind: "parent"}` and begin `subagent-run-dispose`; then wait for the run's result. Local with `stop?`: `(agent-cancel! agent cause-parent)`, `agent-when-idle`, flush as in rule 32; then capture (rule 35). A raise here is the *capture failure* and is recorded as a teardown failure `subagent "<id>" activation teardown failed: <detail>`. Dispose the handle (`agent-handle-dispose!`) or the run; a raise is recorded as `subagent "<id>" activation handle disposal failed: <detail>`. One recorded failure is the teardown failure; several become `subagent "<id>" activation teardown failed at <n> boundaries: <details joined with "; ">`; all have code `ACTIVATION_TEARDOWN_FAILED`. `<detail>` is `(error-chain e)` for a local activation and the message for an external one. With a teardown failure, a `completed` result of a local child whose inbox still holds input becomes `error`. Then, in this order: remove the resident entry; release the slot; deliver the parent notice with the captured result (rule 39); dispatch `subagent/end` (with `{output: [], stopReason: "error"}` in place of the result when teardown failed); resolve the activation's result, or fail it with the capture failure; raise the teardown failure to the caller of the transaction.
35. Capturing a local result: the events from `output-start`; `output` is `(final-assistant-output events)`, else `'()`; the stop reason is `error` when `failure-at` is set, else rule 36; with a structured attachment, a committed capture adds `structured`, and a `completed` run without one becomes `error`. `final-assistant-output`: the content of the last `assistant/message` whose content is not empty; else one text block holding the concatenation of `(join-assistant-stream-text stream)` over every `assistant/message` and `assistant/attempt`, when that is not empty; else `#f`.
36. `(epoch-stop-reason events)` from `(fold-consumed-work events)`: the accounting turn end's reason kind `max-tokens` gives `max-tokens`; `aborted` and `interrupted` give `aborted`; `error` gives `error`; `blocked` gives `refusal`; `completed`, and no accounting turn, give `aborted` when work was dropped unrun and `completed` otherwise; anything else gives `error`.
37. Teardown failures observed by the manager itself are logged at `warning` as `subagent "<id>" activation teardown failed: <message>`.

**Notices and messages** (R11 "Settlement notice", "Messaging"; `continuation-messages.ts`, `manager.ts:1119-1141`)

38. `make-settlement-message`: text blocks in order. (1) The summary line, with `S` = `Background subagent <childName>`: `completed` and continuable `S finished and will do no further work unless you send it more.`; `completed` and not continuable `S finished. It cannot receive follow-up messages.`; `aborted` `S was stopped before it finished.`; `max-tokens` `S ran out of room before it finished.`; `refusal` `S declined the task.`; `error` `S failed before it finished.`; any other `S ended abnormally (<reason>) before it finished.` (2) `It sent you a message just before finishing, so its closing message is omitted.` when `omit-closing-text?`; else `It left no closing message.` when the output has no non-empty text block; else `Its closing message:` followed by the output's non-empty text blocks (all other blocks are dropped). (3) `Structured result: <JSON text>` when a structured value is present. (4) The diagnostic as its own block when present.
39. Parent notice: only for an accepted activation with delivery `'parent`. The direct creator must be live, its `agent-ctx` fiber active, and its root the activation's root; otherwise nothing is sent. The message is rule 38 with `continuable?` and `omit-closing-text?` taken from a local activation (both false for an external one). When the parent's tree or the manager is draining, `agent-inject!`; otherwise deliver waking (rule 40) as a follow-up when the parent's status is `'idle` and as a steer when it is running. A failure is logged as `subagent "<id>" settlement notice was not delivered to its parent: <error-chain>` and never raised.
40. Delivering waking to an agent `p`: when `p` is itself a resident member, go through rule 42's admission for its activation and wake its watcher in every case; otherwise call `agent-steer!` or `agent-followup!` directly.
41. `subagents-send-message!`: check cancellation; `root = (root-of sender)`; a target equal to the sender raises `UNAUTHORIZED` `send_message requires another agent in the subagent tree`; admission of the sender; the message is `(make-agent-message sender <sender's name> content)`; deliver to the member (rule 43) as a steer with that source, re-checking the sender's admission at acceptance. When it is accepted and the sender is a local member whose direct creator is the target, set the sender's `omit-closing-text?`.
42. Admitting input to a resident activation: closing raises `ACTIVATION_CLOSING` `subagent activation is being disposed; the message was not accepted`; an external activation raises `NOT_CONTINUABLE` `subagent "<id>" does not accept follow-up input`; a structured attachment that no longer accepts input raises `INPUT_CLOSED` `subagent is submitting or has submitted its structured result; the message was not accepted`; then `agent-steer!` or `agent-followup!`.
43. Delivering to a member `(root, target-id, content, delivery, source, …)`: repeat, each pass under the target's child lock after admission of the root and a cancellation check. Target is the root: image check (rule 45), check cancellation, the caller's authorisation hook, admission, build the message, deliver waking, return its id. Target not resident: cold-resume it (rule 44) and submit as rule 21 without guidance or catalog fact; a failure disposes the restored activation. Target resident under another root: `UNAUTHORIZED` `target belongs to another subagent tree`. External target: `NOT_CONTINUABLE`. Target closing: leave the lock, wait for its close transaction, and repeat (the next pass cold-resumes). Otherwise the image check, then build the message, check cancellation, authorise, admission, rule 42, wake, return the id.
44. Cold resume of a target under a root (`manager.ts:1214-1262`), under startup tracking: observe the child with `port-observe-session` (no `sessionQuery` raises `CONTINUATION_UNAVAILABLE` `continuable subagents require session query (load @deepseek-ai/dsh-session-query)`; a read failure, unless cancelled, raises `NOT_RESUMABLE` `subagent "<id>" is unavailable`); fold the descriptor over the child's own events (those from its inherited event count); none or not `continuable` raises `NOT_RESUMABLE` `subagent "<id>" has no supported continuation state and cannot be resumed; choose a different target`; verify ancestry: walk `parentSession` upward while the session's `subagent` identity lies in its own suffix, observing each creator and requiring its `subagentCatalog` to contain the child (`UNAUTHORIZED` `subagent is absent from its creator catalog`; a repeated id raises `UNAUTHORIZED` `cyclic subagent creation ancestry`), collecting ancestors and names, until the live root is reached; a walk that ends elsewhere raises `UNAUTHORIZED` `agent "<id>" is not a member of this subagent tree`. The preset is the observation's `agentPreset` projection, else the header's `agentPreset`; an `agent-preset/selected` event without that projection raises `NOT_RESUMABLE` `subagent "<id>" has no agent preset projection for restoration`. Materialise with `agents-resume`, agent options `{provider, model, reasoningEffort}` from the descriptor, and composition `{preset, persona, toolFilter}`. A failure that is not an `exn:fail:subagent` and not a cancellation raises `NOT_RESUMABLE` `subagent "<id>" is unavailable` with it as cause. Every observation is released before the next read. A resume takes a capacity slot and dispatches a new `subagent/start`.
45. Image content: before delivery, when the content has an image block and the target's options name a provider and model and an `llm` service is mounted, `(llm-resolve-model-info …)`; `inputModalities` present without `image` raises `MODEL_DOES_NOT_SUPPORT_IMAGES` `Model "<model>" does not support image input.`

**Tree membership, interrupt, wait, drain** (R11 "Tree membership, interrupt, drain"; `manager.ts:194-298`, `509-557`, `693-798`)

46. `subagents-root-of`: a caller that is not live raises `UNAUTHORIZED` `subagent tree access requires the exact live caller`. When the caller's resident activation holds that exact agent and its root is live, the root. Otherwise a caller that is *delegated* (header `origin` is `subagent`, or its `subagent` identity's seq is one of its own seqs) or that has a stale activation raises `UNAUTHORIZED` `agent has no active runtime owner`. Any other live agent is its own root; a plain session fork is an independent root.
47. `subagents-names-of`: the root is `lead` with no creator name; a member's own name is `(agent-address path id)` and its creator's is the address of the creator (the parent path of the member's path, or, for an unnamed member, the creator's own path) with the creator's id as fallback.
48. `subagents-resolve-name`: `lead` gives the root id. Otherwise split the name on `/`; when every segment is a valid name, follow `name` matches through the catalogs from the root (a non-final segment must be `continuable` or `one-shot`); a match gives its id. No match and a name containing `/` raises `AGENT_NAME_NOT_FOUND` `agent name <JSON string> was not found in this subagent tree; use list_agents to see the names`; any other unmatched text is returned as a session id. Resolution grants no authority.
49. `subagents-interrupt!`: an ancestor authority must be live (`UNAUTHORIZED` `interrupting "<id>" requires the exact live ancestor agent`) and not the target (`agent "<id>" cannot interrupt itself`). No resident activation: nothing. An ancestor authority must share the target's root and appear in its ancestors, else `UNAUTHORIZED` `subagent "<id>" is not a live descendant of agent "<a>"`. A closing activation: nothing. Local: `(agent-cancel! agent cause #:keep-inbox? #t)` with `cause-user` for `'user` and `cause-parent` otherwise. External: cancel the run's source with `{kind}` and start its disposal. The call returns without waiting.
50. `subagents-wait-for-tree-work`: `#f` when the caller is not its own root. Otherwise repeat: gather the root's pending materialisations and resident members; note whether any local member is not idle; wait for every local member's `agent-when-idle`; then wait for all of: each materialisation's settled event, each external or closing member's result, each still-running member's idleness, and, for each idle member without parked input or with a recorded failure, its result or its poke. Idle members with parked inbox input and no failure are skipped. When there was anything to wait for, repeat; when a new materialisation or member appeared meanwhile, repeat; else return whether anything was observed. `subagents-drain-descendants!`: for each given agent that is live and its own root, mark the root closing (cleared on its `agent/disposed`), cancel its pending materialisations, dispose its resident members concurrently and wait for everything; failures raise one `ACTIVATION_TEARDOWN_FAILED` `subagent teardown failed for <n> scoped activation(s): <messages joined with "; ">`. Manager disposal sets a global draining flag, cancels and waits for every materialisation and disposes every member (`… for <n> activation(s): …`).
51. Admission of an agent: while the manager is draining raise `DRAINING` `subagents are draining; the operation was not admitted`; while the agent's root is closing, `DRAINING` `subagent tree "<root id>" is draining; the operation was not admitted`; while the agent's own activation is closing, `ACTIVATION_CLOSING` `subagent "<id>" is closing`.
52. The child lock runs critical sections for one child id one after another in arrival order; a section that raises does not affect later ones; the table entry is removed when its queue is empty.
53. Capacity: one pool per root (a weak table keyed by the root agent); a reservation with `maxActiveSubagents` slots already taken raises at once `ACTIVATION_LIMIT_REACHED` `subagent limit reached (active child limit: <n>); wait for an existing child to finish or complete this work with the current agents`; the limit is read at each reservation; release is idempotent.

**Discovery** (R11 "Discovery"; `list-children.ts`)

54. Reading one catalog: no `sessionQuery` raises `SUBAGENT_CONTROL_QUERY_UNAVAILABLE` `listing subagents requires the sessionQuery service (load @deepseek-ai/dsh-session-query)`; an observation without the `subagentCatalog` projection raises `SUBAGENT_CONTROL_PROJECTIONS_UNAVAILABLE` `listing subagents requires the registered subagentCatalog projection`. The observation is released before returning.
55. `subagents-list-descendants`: no `sessions` service raises `SUBAGENT_CONTROL_SESSION_STORE_UNAVAILABLE` `listing subagents requires the session store (load @deepseek-ai/dsh-session)`. Depth-first pre-order with an explicit stack; siblings in catalog order; a visited set skips repeats; `path` by `join-agent-path` from `""`. Per entry: an `external` entry has no children; a child whose catalog read fails with an `exn:fail:subagent` propagates; any other failure yields a diagnostic row with reason `corrupt` for the codes `SESSION_QUERY_CORRUPT_SESSION` and `SESSION_QUERY_SOURCE_CONFLICT` and `unavailable` otherwise, and that branch stops; mode `unknown` yields a diagnostic `unsupported` and is still traversed; other entries yield a child row with `activity` `running` when `(sessions-find … id)` is a session and `inactive` otherwise. Cancellation is checked around every read. A failure of the root's own read propagates.

**Structured output** (R11 "Structured output two-phase commit"; `structured.ts`)

56. `(attach-structured-runtime! child-ctx schema can-complete?)` registers through `child-ctx`: the tool (Tools); the section `tool:structured_output` at section order `STRUCTURED_OUTPUT` with the instruction of `structured.ts:20-23` (R11 "`structured_output`"), copied verbatim; a guard that returns ``structured output already recorded: the run is complete, so `<tool name>` is not executed`` once a value is pending or captured; and a `tools/result` listener. The tool body validates the arguments with `validate-json-schema-value` (violations raise the tool args error), raises `Process pending messages before submitting structured output.` while `(can-complete?)` is false (the child's inbox is not empty), stages the arguments under the execution's token, calls `tool-conclude-turn!` and returns `{recorded: true}`.
57. Commit in the `tools/result` listener: for a `structured_output` execution with a staged entry, remove it; an error result discards it; a top-level success sets *captured*; a nested success (the execution has a parent token) sets *pending* with that parent token. For any other execution whose token is the pending parent: clear pending; a success sets captured. The attachment accepts input only while nothing is staged, pending or captured.

**Archive admission and browser prompts**

58. Archive admission (`archive-admission.ts`): the ancestors of an agent are its resident activation's, else the header chain (`origin: "subagent"` and `parentSession`, followed through live agents, cycle-checked). `workspace/session-activity` (waterfall, payload `sessionId`): note the running agents whose ancestors include the id, call `(next)`, and when there are any put `{kind: "subagent", items: [{id, label?}…]}` in front of the result (the label is the identity's when its seq is the child's own). `workspace/session-stop`: `(agent-cancel! child cause-parent)` for each such agent; a failure is logged as `subagent: cancelling "<id>" for an archived Session failed: <error>`. `agent/pre-step`: when `(port-archived-session-ids ctx)` holds one of the agent's ancestors, return `(pre-step-reject)` without calling `next`.
59. `subagents-prompt` (`index.ts:450-492`, `control.ts`); every coded failure of this rule is an `exn:fail:subagent-remote` with the dsh message. The request is `{requestId, childSessionId, delivery: "queue" or "steer", content: [part…], clientTimeZone?}`; validation failures raise an `exn:fail:subagent-remote` with code `gateway/bad-request` and details `{issues}`; a time zone that is not canonical raises `subagent/invalid-time-zone` `clientTimeZone must be UTC or a valid IANA Area/Location name` with details `{value}`. The source is `{kind: "user", rpcId, clientTimeZone?, principal?}`. Text-only content is used as is; other content is admitted through `port-admit-prompt-content` (no service raises `subagent image prompt requires an attachment store`). Delivery: the root is the resident activation's, else the one found by observing the child and verifying ancestry without a given root (rule 44; a root that is not live raises `CONTINUATION_UNAVAILABLE` `subagent tree root is not live`); then rule 43 with the requested delivery. Failures are mapped as `control.ts` maps them: `NOT_RESUMABLE` to `subagent/not-resumable`; `UNAUTHORIZED` to `subagent/unauthorized`; `DRAINING`, `ACTIVATION_CLOSING`, `ACTIVATION_LIMIT_REACHED`, `CONTINUATION_UNAVAILABLE`, `PERSISTENCE_UNAVAILABLE` to `subagent/delivery-unavailable`; attachment failures and `MODEL_DOES_NOT_SUPPORT_IMAGES` to `subagent/attachment-invalid` with `{reason}`; cancellation to `gateway/cancelled`; anything else to `gateway/internal`. `subagents-interrupt-by-user` validates a non-empty id, calls rule 49 with `'user`, and returns `{accepted: #t}`; a failure raises `gateway/internal` `subagent interrupt failed`.

**`tool-subagent`** (`tool-subagent/src`)

60. Body, in order: the load-time checks; register the policy event type and `model-selection-policy-projection`, keeping the handle; listen to `subagent/provider-added` for the configured provider name and check its configuration (rule 64), which makes a mismatching provider's registration fail; check the provider if already registered; with `modelDiscovery`, register `list_subagent_models`; define mounting: check the configuration, build the definition and register it inside one effect together with `subagents-delegation-tool!`; listen to `subagent/provider-added` (mount when nothing is mounted) and `subagent/provider-removed` (unmount); mount now when the provider exists, else log at `info` `subagent provider "<p>" not registered yet; the "<toolName>" tool will register when it appears`; register the section and the context of rule 63.
61. Tool body: no calling agent raises `subagent tool requires a calling agent (exec.agent was undefined)`. Read the session's policy routes. Preset: an `agent_preset` argument without an allowlist raises `agent_preset selection is disabled for this tool instance`; one outside it raises `agent_preset must be one of: <choices joined with ", ">`; none gives the configured `agentPreset`. Model options: rule 62. When a route was requested or configured (any of provider, model, effort), an `llm` service is required (``cannot resolve the selected child LLM route because the `llm` service is unavailable``); resolve `provider` and `model` (requested, else the parent's; neither raises `cannot select child LLM values without an effective provider and model`) and the effort (requested, else the parent's only when the route is unchanged, the call named none of the three fields, and the provider has no route defaults); `(llm-resolve-call-config llm config #:cancel cancel)`; then the registered provider must still be the mounted one, else raise `subagent provider "<p>" changed while resolving the child LLM route; retry the delegation`. Check cancellation. Call `subagents-start-activation` with the configured provider, `#:label` the `description` argument, `#:name`, `#:cwd`, `#:prompt (list (text-block prompt))`, the parent, the preset, the options, `#:max-depth (subagents-resolve-max-depth subagents <configured>)`, the execution's cancel event and delivery `'parent`. Return `{kind: "activation", name}`.
62. Model option merge (`model-selection.ts`): with none of `provider`, `model`, `reasoning_effort` in the call, the configured `agentOptions` (overlaid on the provider's route defaults when a preflight is needed). Any present with `modelSelection` false raises `child model selection is disabled for this tool instance`. An empty string raises ``child LLM `<field>` must be non-empty``. `provider` and `model` must come together: ``child LLM `provider` and `model` must be supplied together``, or, when an effort was given, ``child LLM `reasoning_effort` requires both `provider` and `model`; supply both or omit all three fields``. Authorisation: with a recorded policy the pair must be in it; without one only the parent's current route is allowed; else raise `child LLM route "<p>/<m>" is not allowed for this Session`, followed without a policy by `; without a recorded model-selection policy, explicit selection is limited to the parent route`. The result is the configured options with `provider`, `model` and `reasoningEffort` set, the effort being an explicit clear (`'null`, rule 25) when the call named none.
63. Shared guidance. The `subagents` service value holds the set of mounted delegation tool definitions (`subagents-delegation-tool!`). Each row registers the section `tool:<toolName>` at section order `TOOL_SUBAGENT` whose text is `""` unless this row's tool is mounted and its name is the first, in `js-string<?` order, of the delegation tools visible to the assembling scope (`(eq? (tools-lookup … name scope) definition)`); then it is the two paragraphs of `index.ts:369-371` (R11 "Prompt contributions"), copied verbatim, with `<names>` the visible names, each in backticks, joined with ` or `. Each row also registers the context `tool:<toolName>:depth` at context order `SUBAGENT_DELEGATION`: `""` without an agent, when the tool is not this row's mounted definition for the scope, when the resolved max depth is `#f`, or when the agent's depth is below it; otherwise ``Delegation depth for `<toolName>`: current <d>, maximum <m>, remaining levels 0. Do not call `<toolName>` at this depth; carry out the work directly.``
64. Provider configuration check: preset selection configured with a provider that lacks `agent-preset?` or inherits context raises `tool-subagent: provider "<p>" does not support independent agent preset selection`; a resolved max depth with a provider lacking `depth-limit?` raises `tool-subagent: provider "<p>" cannot enforce maxDepth (no depthLimit capability) — set maxDepth: 'provider-managed' to leave the recursion budget to the provider`; `agentOptions` configured, or `modelSelection` true, with a provider lacking `agent-options?` raise `tool-subagent: provider "<p>" does not support child agentOptions` and `… does not support child model selection`.
65. The policy routes of a session are the `subagentModelSelectionPolicy` state, or none when it is `null`.
66. `list_subagent_models` body (`list-models.ts:30-106`): requires a calling agent (`list_subagent_models requires a calling agent`) and an `llm` service (``cannot discover child LLM routes because the `llm` service is unavailable``). Without a recorded policy the only route is the parent's (`cannot discover child LLM routes without a parent provider and model` when it has none). `model` without `provider` raises `` `model` requires `provider` ``. No arguments: one line `<id> — <name>` per registered provider that has an allowed route, or `(no LLM providers)`. `provider` (`` `provider` must be non-empty ``; `LLM provider "<p>" is not allowed for this Session`; `LLM provider "<p>" is not registered; available providers: <allowed registered ids joined with ", ", or (none)>`): one line `<provider>/<modelId> — <name>[: <description>]` per allowed model from `llm-list-models` (with a policy) or the resolved parent model (without), or `(no advertised models for <provider>)`. `provider` and `model` (`` `model` must be non-empty ``; `child LLM route "<p>/<m>" is not allowed for this Session`): the model line, `Reasoning efforts:`, and lines `<effortId>[ (default)] — <name>[: <description>]`, or `(no advertised reasoning efforts)`.
67. Model-selection settings: on `agent/created`, when the agent's session has no policy: a session whose header `origin` is `subagent` copies the policy of its live parent session, if that has one; a fresh top-level session (first live seq 0 and event 0 not `session/end-seed`) takes the current setting when `enabled`; then append `subagent/model-selection-policy {allowedModels}`. Checks on a route list: `subagent model selection requires an array of routes`; `subagent model selection requires non-empty provider and model ids`; `subagent model selection repeats route "<p>/<m>"`; enabled with an empty list raises `enabled subagent model selection requires at least one allowed model` at use.

**Control tools** (`tool-subagent-control/src`)

68. `send_message` body: resolve the name (rule 48), then `subagents-send-message!` with one text block; return `{messageId}`.
69. `list_agents` body: no calling agent raises `list_agents requires a calling agent (exec.agent was undefined)`; `root = (subagents-root-of …)`; the rows are `{name: "lead", status, description: "root agent"}` followed by each descendant row projected: a diagnostic row gives `{name: <path or id>, status: <reason>}`; a child row that is not `continuable` is omitted; otherwise `{name: <path or id>, status, description: <label>}`. `status` is `running` when the live agent of that id has status `'running` and `inactive` otherwise.
70. `wait_agent` body: the timeout must be a safe integer from 10000 through 3600000; a calling agent is required; then rule 71 with the execution's cancel event and root call id.
71. Waiting (`wait-agent.ts:26-88`): raise the plugin's lifetime reason when the plugin is unloading; the agent must be live. `seen` is the id set stored for this agent when its stored root call id equals this call's, else none. Subscribe first: an `agent/inbox/inserted` listener and an `agent/disposed` listener, both filtered to this agent. Then check once and after every insertion: when next-step holds a message whose id is not in `seen`, store `(root call id, ids of all next-step messages)` for the agent and finish with `{timedOut: #f}`. Otherwise wait for the first of: an insertion, the agent's disposal (`WAIT_UNAVAILABLE`), the caller's cancel event (raise its reason), the plugin's lifetime event (raise its reason), the timer (`{timedOut: #t}`). Nothing is consumed. Every exit removes both listeners. The stored sets live in a weak table keyed by agent, so repeated waits inside one `run_code` program do not return for input that cannot be delivered before the call ends.
72. `interrupt_agent` body: no calling agent raises `interrupt_agent requires a calling agent (exec.agent was undefined)`; resolve the name; `(subagents-interrupt! subagents target caller)`; return `{accepted: #t}`.
73. Identity context: name `subagent:identity`, context order `SUBAGENT_DELEGATION`, `#:required? #t`, `#:interpolate? #f`. Text for the assembling agent (`""` without one), names printed as JSON strings: the root: `You are the root agent. Your name is "lead".`; a member: `You are a subagent delegated by agent <parent>.\nYour name is <self>.\nThe root agent of your collaboration tree is "lead".`; then, when the tools are this plugin's visible definitions for the scope and tool set, a blank line and one line each: `To message other agents, use send_message({ agent: "<agent-name>", message: "..." }).` and `Use list_agents({}) to find your collaborator agents and their names.` When `subagents-names-of` raises an `exn:fail:subagent` with code `UNAUTHORIZED`: `Your agent id is <JSON id>. Your subagent tree root is unavailable. Continue independent work; subagent discovery and messaging require an active root.` Any other failure propagates.

**Out-of-process providers, common** (`out-of-process.ts`)

74. `(limit-subagent-diagnostic s)`: at most 4096 UTF-8 bytes; a longer text is cut at a character boundary to 4096 minus the bytes of the suffix and followed by `\n[diagnostic truncated]`. `(assert-usable-cwd prefix label cwd)`: `<prefix>: <label> must be an absolute path: <cwd>`; `<prefix>: <label> is not an accessible directory: <cwd>` unless it is an existing directory that can be entered. `(settle-run-result #:attempt thunk #:collect-output thunk #:collect-diagnostic [thunk] #:cancelled? thunk #:on-error [proc])` never raises: a result with `cancelled?` true becomes `{output, stopReason: "aborted"}`; a result otherwise passes with its diagnostic limited; a raise with `cancelled?` true is `aborted`; any other raise calls `on-error` (contained) and yields `{output, diagnostic?, stopReason: "error"}`. `(make-subprocess-run id result-task #:request-cancel proc #:teardown proc)`: `dispose` calls `request-cancel` and then `teardown` once and every caller waits for that one teardown. Every run id is a fresh UUID minted here, never the product's own session id.
75. Shared provider rules. All four have `provider-inherits-parent-context?` false. Capabilities: none for ACP, Claude Code and Codex; `agentOptions` only for DSH SDK, which also has route defaults `{provider, model}` from its config. A request whose cancel event is ready before the child starts raises the provider's "aborted before start" message. The child `cwd` passes `assert-usable-cwd` with the provider's prefix and label `child cwd`; a failure is wrapped as the provider's configuration or startup failure and logged at `warning`. Grace values must be positive, finite and at most 2147483647 (`<prefix>: <name> must be a positive finite number no greater than 2147483647` for ACP; `<prefix>: <name> must be a positive finite number` plus `<prefix>: disposeGraceMs must be no greater than 2147483647` for the others). Child stderr is never part of a result. The environment of a child is `(port-scrubbed-parent-env ctx)` with the config's `env` merged over it. A failure flattened into a result is reported to the log as `<prefix> "<providerName>": child run failed (<stopReason>): <message>`.
76. `private/jsonrpc-lines.rkt` is the client side of the SDK line transport (R13 Formats 1): one JSON object per line, written with `jvalue->string` and a newline and flushed; lines are trimmed, blank and non-JSON lines skipped; a frame with `id` and `method` is a request, with `id` only a response, with `method` only a notification; `params` that is not an object reads as `{}`; an error response raises with the wire `code` and `message`; end of input fails every pending request with `JSON-RPC input closed` and closing with `JSON-RPC transport closed`. Outbound request ids are `req_` followed by 32 hex digits, except for ACP, which counts from 0. A reader task dispatches inbound frames; `(rpc-request rpc method params #:cancel [cancel #f])` waits for the response or the cancel event.

**ACP** (`subagent-acp/src`; R11 "Catalog-depth notes")

77. Start: spawn `argv = (cons command args)` in `cwd` with stderr inherited and grace `disposeGraceMs`; a spawn failure raises `subagent-acp: Subagent failure (provider: ACP; stage: process; category: process-start)`. Then, raced against the process failing and against cancellation: request `initialize` with `{protocolVersion: 1, clientCapabilities: {}}`; request `session/new` with `{cwd, mcpServers: []}`, whose result must hold a string `sessionId`, else a failure with stage `new-session`, category `protocol`. A startup failure disposes the process and raises `subagent-acp: <failure diagnostic>` with stage `initialize` or `new-session` and category `process-exit` (with the observed exit code or signal) or `transport`; a cleanup failure is added as a second member of an aggregate whose message joins both with `; `. Cancellation during startup raises `subagent request was aborted before the ACP child started`.
78. Run: request `session/prompt` with `{sessionId, prompt: <the text blocks of the task as {type: "text", text}>}`. Notifications `session/update` whose `update.sessionUpdate` is `agent_message_chunk` add the text of a text content to the output fold; other updates are ignored. A server request `session/request_permission` is answered at once: with `permission: "allow"` and an option of kind `allow_once` or `allow_always`, `{outcome: {outcome: "selected", optionId}}`; otherwise `{outcome: {outcome: "cancelled"}}`; the latest decision is remembered as `{policy, request: <the tool call's kind when it is one of read edit delete move search execute think fetch switch_mode other, else unknown>, decision: allowed or denied}`. Cancellation settles the result as `aborted` at once and sends the notification `session/cancel {sessionId}` best effort. The stop reason maps `end_turn` to `completed`, `max_tokens` to `max-tokens`, `refusal` to `refusal`, `cancelled` to `aborted`, `max_turn_requests` and anything else to `error`. The output is one text block of the folded text, or empty.
79. Diagnostics, fixed texts built only from these facts: the failure line `Subagent failure (provider: ACP; stage: <stage>; category: <category>[; stop reason: <r>][; exit code: <n>][; signal: <s>])` and the permission line `ACP unattended decision (policy: <p>; request: <kind>; decision: <d>)`. A terminal `max_turn_requests` gives the failure line (stage `prompt`, category `remote-limit`, that stop reason) followed, when a decision exists, by a newline and the permission line; `max_tokens`, `refusal` and `cancelled` give only the permission line, when one exists; an unknown reason gives the failure line with category `unknown` and stop reason `unknown`; `end_turn` gives none. A prompt that fails without cancellation gives the failure line with stage `process`, category `process-exit` when the process outcome is observed within `disposeGraceMs`, else stage `prompt`, category `transport`. Teardown: close stdin; wait up to `disposeEofGraceMs` for the process range to exit; else terminate and wait; a failure raises `subagent-acp: <failure line with stage teardown>`.

**Codex** (`subagent-codex/src`)

80. Start: the task must be text blocks only and not all blank (`subagent-codex: the one-shot task must contain only text blocks`, `subagent-codex: the one-shot task must not be empty`); argv is `x-racket.command` followed by `app-server` and `--stdio`, with the first element resolved by `find-executable-path` when it is not a path; stdout and stderr are pipes and stderr bytes are copied to the harness's stderr in order. Request `initialize` with `{clientInfo: {name: "deepseek-harness", title: "DeepSeek Harness", version: "0.0.1"}, capabilities: {experimentalApi: false, requestAttestation: false}}`, send the notification `initialized`, then request `thread/start` with `{cwd, ephemeral: true, model?}` plus the permission fields: `never`: `{approvalPolicy: "never"}`; `approve-for-me`: `{approvalPolicy: "on-request", approvalsReviewer: "auto_review", sandbox: "workspace-write"}`; `dangerously-bypass-approvals-and-sandbox`: `{approvalPolicy: "never", sandbox: "danger-full-access"}`. The result's `thread` must have a non-empty `id` and `ephemeral: true`. A startup failure raises `subagent-codex: Product subagent failure (product: Codex; stage: <initialize or thread-start>; category: unknown[; exit code: <n>][; signal: <s>])`; cancellation raises `subagent-codex: request was aborted before run publication`.
81. Turn (`wire.ts`, to be ported function for function): request `turn/start` with `{threadId, input: [{type: "text", text, text_elements: []}…]}`; the result's `turn.id` is the turn id; notifications that arrive for the turn before that response are held and replayed in order. `item/completed` for this turn: an `agentMessage` item sets the last final, partial or unphased answer by its `phase` (`final_answer`, `partial_answer`, `null`; `commentary` is ignored; any other phase is a protocol failure); a `commandExecution` or `fileChange` item with status `declined` records a diagnostic. `turn/completed` for this turn with status `completed`, `interrupted` or `failed` ends it. The output is the last final answer, else the last partial, else the last unphased, as one text block when not blank. Status `completed` with an output gives `completed`; without one, a failure with category `invalid-result`. Any other status is classified from `turn.error.codexErrorInfo` by the table of `wire.ts:66-131` (`contextWindowExceeded` gives stop reason `max-tokens`; the others raise with a category among `limit`, `service`, `access-policy`, `transport`, `product-error`, `unknown`, and an HTTP status when reported). Server requests are answered without a human: the five methods and replies of `wire.ts:505-562` (`item/commandExecution/requestApproval` and `item/fileChange/requestApproval` with `{decision: "cancel"}` when offered, else `"decline"`; `item/permissions/requestApproval` with `{permissions: {}, scope: "turn"}`; `item/tool/requestUserInput` with `{answers: {}}`; `mcpServer/elicitation/request` with `{action: "decline", content: null, _meta: null}`); any other request is a protocol failure. Cancellation requests `turn/interrupt {threadId, turnId}` and settles as `aborted`.
82. Diagnostics: the failure line `Product subagent failure (product: Codex; stage: <stage>; category: <category>[; HTTP status: <n>][; exit code: <n>][; signal: <s>])` followed, when an unattended decision was recorded, by a newline and `Codex unattended decision (mode: <mode>; request: <request>; decision: <decision>): <reason>` with the request, decision and reason texts of `wire.ts` (the latest observation wins). Teardown: close the wire and stdin, terminate, wait for exit.

**Claude Code** (`subagent-claude-code/src`; wrapped)

83. The task must be text blocks only and not all blank (messages as rule 80 with prefix `subagent-claude-code`); the texts are concatenated. The provider spawns `<x-racket.node> <racket/dsh-subagent/sidecar/claude-code.mjs>` through the subprocess port in the child `cwd`, with stderr inherited, grace `disposeGraceMs`, the environment of rule 75 plus `DSH_CLAUDE_SDK_DIR=<x-racket.sdkDir>`. The sidecar resolves `@anthropic-ai/claude-agent-sdk` from that directory, calls its `query` with the options dsh builds in `claudeQueryOptions` (`run.ts:256-316`: `cwd`, `model?`, `env`, `persistSession: false`, `disallowedTools` `["AskUserQuestion"]` plus `"ExitPlanMode"` in `plan` mode, `permissionMode`, `allowDangerouslySkipPermissions` for `bypassPermissions` and otherwise a `canUseTool` that denies with `This unattended Claude Code subagent cannot request human approval.`, an `onElicitation` that declines, an `onUserDialog` that cancels, `supportedDialogKinds: ["refusal_fallback_prompt"]`), and lets the SDK start the Claude Code process itself; that process is in the sidecar's process group and is stopped with it.
84. Pipe protocol, one JSON object per line. Racket to sidecar: `{type: "start", prompt, cwd, model?, permissionMode, env}` once; `{type: "cancel"}` at most once. Sidecar to Racket: `{type: "ready"}` after the SDK loaded and the query was created, or `{type: "fatal", message}` when it could not; `{type: "decision", request, decision, reason}` for each unattended decision (`tool permission` denied, `MCP elicitation` declined, `user dialog` cancelled, with the reasons of `run.ts:273-303`); `{type: "permission-denied"}` for an SDK system message of that subtype; `{type: "result", subtype, isError, result, errors}` for each SDK result message; `{type: "end"}` when the query finished; `{type: "error", message}` when it raised. The sidecar exits when stdin closes.
85. Mapping (`run.ts:181-236`, `440-560`): `fatal`, or exit before `ready`, raises the startup failure `subagent-claude-code: Product subagent failure (product: Claude Code; stage: query-start; category: unknown[; exit code][; signal])`. A `result` with subtype `success`, `isError` false and a non-blank `result` sets the answer; with another subtype it is a failure with stage `query-run` and category `limit` (`error_max_turns`, `error_max_budget_usd`, `error_max_structured_output_retries`), `product-error` (`error_during_execution`) or `unknown`; a `success` that is an error or blank, and an `end` without an answer, are `invalid-result`. An answer gives `{output: one text block, stopReason: "completed"}`. A failure settles as `error` with the diagnostic `Product subagent failure (product: Claude Code; stage: <stage>; category: <category>[; exit code: <n>][; signal: <s>])` followed, when a decision was recorded, by a newline and `Claude Code unattended decision (mode: <mode>; request: <request>; decision: <decision>): <reason>`; `permission-denied` records the decision `tool permission`, `denied`, `Claude Code denied the request before an interactive prompt`. Cancellation sends `cancel` and settles as `aborted`. Teardown: close stdin, terminate, wait.
86. At mount the plugin checks that the node executable is found and that `<sdkDir>/node_modules/@anthropic-ai/claude-agent-sdk` exists; when either is missing it logs at `warning` `@deepseek-ai/dsh-subagent-claude-code: wrapped plugin; provider "<name>" needs Node 22 or later and "npm install @anthropic-ai/claude-agent-sdk" in <sdkDir>`. The provider is registered in both cases.

**DSH SDK** (`subagent-dsh-sdk/src`; R13 Formats 1 to 5)

87. Launch: argv is `dshBin` (an executable file) or, without it, `(port-dsh-launcher ctx)` (none raises the configuration failure with cause `subagent-dsh-sdk: no dsh launcher is available; set dshBin`), followed by `--profile <profile>` and one `--patch <absolute file>` per patch; process directory the child `cwd`; environment of rule 75 plus `DSH_HOME=<dshHome>`; stderr piped and drained (the last 400 lines are kept for the log, never for a result). Request `initialize` with `{cwd: <the parent header's cwd, else the child cwd>, provider, model, reasoningEffort?, maxTokens?}`, the route being the request's agent options over the config, within 10000 ms. A failure raises `subagent-dsh-sdk: Subagent failure (provider: DSH SDK; stage: initialize; category: <transport, protocol or unknown>)` (`configuration` for a bad `cwd` or launcher), after closing the child; cancellation raises `subagent request was aborted before the SDK child started`.
88. Run: the child session id is `session-` followed by 32 hex digits. Request `session/working-directory/set {sessionId, path: <cwd>}`, then `session/prompt {sessionId, contentBlocks: <the task>}`, then `session/wait {sessionId}`. Every `session.event` notification for that session id is validated as an event envelope and fed to the output fold (rule 35's `final-assistant-output` rule over `assistant/message` and `assistant/attempt`); the last `turn/end` reason is kept. Outcome from that reason: `completed` and `max-tokens` as themselves; `aborted` gives `aborted`, with the diagnostic `Subagent failure (provider: DSH SDK; stage: session-run; category: child-disposed)` when the cause kind is `disposed`; `blocked` gives `refusal`; `error` gives `error` with category `child-error`; `interrupted` gives `error`; none gives `error` with `missing-terminal`; any other kind gives `error` with `child-unknown`. A request failure gives `error` with stage `session-run` and category `transport` (the input closed), `protocol` (an error response or an invalid frame) or `unknown`. Cancellation settles as `aborted`.
89. Close: request `shutdown` bounded by `shutdownTimeoutMs`; close stdin; wait up to `disposeEofGraceMs` for exit; else terminate and wait up to `disposeGraceMs`, then kill. A failure raises `subagent-dsh-sdk: Subagent failure (provider: DSH SDK; stage: shutdown; category: unknown)`.

**Teams** (R11 "Team formats", "Team task state machine"; `agent-team/src`, `tool-agent-team/src`)

90. `agent-teams-enabled?` is whether the `agentTeam` state of the caller's root session has `enabled` true; it raises what `subagents-root-of` raises. `agent-teams-set-enabled!`: an agent that is not its own root raises `TEAM_LEAD_REQUIRED` `change Team mode from the root Session`; check cancellation; append `team/mode {enabled}` when the value changes; `sessions-flush` the root session. With `defaultEnabled`, an `agent/created` listener enables a session whose source is `'startup`, whose header `origin` is not `subagent`, and whose state has no `enabled` key, passing the payload's cancel event.
91. Every mutation runs in a per-root queue in arrival order (a failed transaction does not block later ones). Reading the state raises its `failure` text when the projection recorded one, and `TEAM_DISABLED` `enable Agent Teams for this Session before using the task board` unless enabled. Create: check cancellation; `TEAM_TASK_LIMIT` `Team task limit <n> reached` when the non-deleted tasks number `maxTasks`; id `task-<nextTaskNumber>` (`TEAM_TASK_LIMIT` `Team task id space exhausted` when taken); snapshot `{id, revision: 1, subject, description, status: "pending", blockedBy, writeScopes}`; validate the graph (rule 94); re-check that the caller is still a tree member (`subagents-root-of`); append and flush (rule 93); return the view.
92. Update: check cancellation; unknown id raises `TEAM_TASK_NOT_FOUND` `team task "<id>" not found`; a revision mismatch raises `TEAM_TASK_STALE_REVISION` `stale team task "<id>" revision <expected>; current revision is <current>`; a deleted task raises `TEAM_TASK_DELETED` `team task "<id>" is deleted`. *Lead* means the caller is the root; *owner* means the task's `ownerId` is the caller's id; *authorised* means lead or owner, else `TEAM_TASK_UNAUTHORIZED` `task mutation requires its owner or Team Lead`. Actions: `claim`: owned by another raises `TEAM_TASK_ALREADY_CLAIMED` `team task "<id>" is owned by another member`; not `pending` or not ready raises `TEAM_TASK_BLOCKED` `team task "<id>" is not ready to claim`; result: owner keys removed, `status: "in_progress"`, then `ownerId` and, when the caller's name differs from its id, `ownerName` appended. `release` (authorised; `in_progress`, else `TEAM_TASK_INVALID_TRANSITION` `only an in-progress task can be released`): `pending`, owner removed. `edit` (authorised; at least one of subject, description, write scopes, else `TEAM_INVALID_ARGUMENT` `task edit requires subject, description, or write_scopes`): the given fields replaced in place. `set_dependencies` (authorised; `blocked_by` given, else `TEAM_INVALID_ARGUMENT` `set_dependencies requires blocked_by`): blockers replaced. `complete` (authorised; `in_progress`, else `only an in-progress task can complete`): `completed`, owner kept. `reopen` (authorised; `completed`, else `only a completed task can reopen`): `pending`, owner removed. `reassign` (lead only, else `TEAM_LEAD_REQUIRED` `only the Team Lead can reassign tasks`; `pending` or `in_progress`, else `only a pending or in-progress task can be reassigned`): without an owner, `pending` with the owner removed; with one, the task must be ready (`TEAM_TASK_BLOCKED` `team task "<id>" is blocked`) and becomes `in_progress` owned by the root (name `lead`) or by a continuable descendant found with `subagents-list-descendants` (its path as name when it has one), else `TEAM_MEMBER_NOT_FOUND` `agent "<id>" is not a continuable descendant of this task board's root`. `delete` (authorised; no other non-deleted task lists it as blocker, else `TEAM_TASK_HAS_DEPENDENTS` `team task "<id>" still blocks "<other>"`): `deleted`. Then `revision + 1` in place; validate the graph; check cancellation; re-check membership; append and flush; return the view. Keys keep their positions through every transition; only the owner keys move, to the end, when they are added.
93. Text limits: `subject` and `description` are trimmed; empty raises `TEAM_INVALID_ARGUMENT` `<field> must be non-empty`; longer than 200 and 16384 units raises `<field> exceeds <n> characters`. Blockers: self raises `TEAM_TASK_DEPENDENCY_CYCLE` `a team task cannot block itself`; a repeat raises `TEAM_INVALID_ARGUMENT` `duplicate blocker "<id>"`; a missing or deleted one raises `TEAM_TASK_NOT_FOUND` `blocker task "<id>" not found`. `(normalize-write-scope s)`: `\` becomes `/`, one leading `./` and trailing slashes are removed; empty, absolute (`/…` or a drive letter) or with an empty, `.` or `..` segment raises `TEAM_INVALID_WRITE_SCOPE` `invalid workspace-relative write scope <JSON string>`; the list is deduplicated. Append and flush: append `team/task {version: 2, teamId, task}`; `sessions-flush`; a flush that raises, or returns `#f` because no durability listener took part, raises `TEAM_TASK_PERSISTENCE_UNCONFIRMED` `task "<id>" revision <n> is visible, but persistence was not confirmed; read the task before retrying`.
94. `(assert-task-graph-candidate tasks candidate)` over the tasks with the candidate replacing its id: for every non-deleted task, a self blocker (`team task "<id>" cannot block itself`, cycle), a repeated blocker (`team task "<id>" repeats blocker "<b>"`, duplicate), a missing or deleted blocker (`blocker task "<b>" for "<id>" is missing or deleted`, missing); then a depth-first search over blockers rejects a cycle (`task dependency cycle includes "<id>"`). The board maps the three kinds to `TEAM_TASK_DEPENDENCY_CYCLE`, `TEAM_INVALID_ARGUMENT`, `TEAM_TASK_NOT_FOUND`. `(task-ready? state task)`: every blocker is `completed`. `project-task-view`: `ready` is `pending` and ready; `writeScopeWarnings` holds `write scopes overlap with <id>` once for each other `in_progress` task with an equal scope or one that is a path prefix of the other.
95. `agentTeam` fold (`projection.ts`): the initial state is `{inheritedEventCount, id: <session id>, tasks: [], nextTaskNumber: 1}`. `team/mode` at or beyond the inherited count sets `enabled`. `team/task`, unless a failure is recorded: an event for another team id is ignored; a version other than 2 fails with `unsupported Agent Teams event version <v>`; the task must begin at revision 1 (`team task "<id>" must begin at revision 1`) and advance by exactly one (`team task "<id>" revision is not contiguous`) and keep the graph valid; then it replaces or appends the task, sets `enabled` to true when it has no value yet, and advances `nextTaskNumber` past a numeric id. A malformed payload fails with `persisted Agent Teams <type> payload is invalid`. A failure records the first message in `failure` and keeps the last valid tasks; the fold never raises. The three historical event types are ignored.
96. `tool-agent-team`: *enabled for an agent* is `(agent-teams-enabled? …)`, with `#f` for no agent and for an `UNAUTHORIZED` subagent error. The section `team:policy` at section order `TEAM_POLICY` has the text `TEAM_POLICY` (`tool-agent-team/src/index.ts:27-33`; R11 "Team tools"), copied verbatim, while enabled, and `""` otherwise.
97. Tool bodies: `team_task_create` and `team_task_update` pass their arguments through (an `owner` name goes through `subagents-resolve-name`) and return the tool view. `team_task_get` returns the tool view of `agent-teams-task`. `team_task_list`: `cursor` must be a non-negative safe integer (`cursor must be a non-negative safe integer`) and `limit` an integer from 1 through 100 (`limit must be an integer from 1 through 100`); `owner` with `unowned` raises `owner and unowned filters cannot be combined`; filter the listed tasks by exact status, owner id, ownedness and readiness; return `{tasks: <the page from cursor>, nextCursor: cursor + limit}` with `nextCursor` only when more rows remain. `agent-teams-task` includes deleted tombstones; `agent-teams-list-tasks` returns the non-deleted tasks in creation order.

## Racket design notes

- **A provider is a generic interface with two optional operations.** dsh selects local or external execution by which method an object has. `#:defined-predicate` of `racket/generic` states the same thing, and the two request structs replace the two option bags.
- **The manager is tasks, one-shot events and a FIFO lock.** A settlement watcher is one task per local activation. The promise chain keyed by child id becomes a small lock that runs thunks in order. The `Promise.withResolvers` poke becomes a one-shot event replaced on every wake. An activation's result is a private deferred value exposed as an event plus `subagent-activation-result`. No cancel source is shared between activations.
- **Synchronous admission is free.** dsh depends on name reservation, capability checks and policy capture happening before the first `await`. Tasks run to completion between awaits (ADR 0002), so the same straight-line code has the same guarantee; the rules say where the first wait is.
- **Children belong to the manager's fiber, not the caller's.** The owner context of every `agents-create` is the manager's empty plugin, so a delegation tool's unload never tears children down and manager unload drains them first.
- **The delegation tool set lives on the service value.** dsh keeps a module-level set of tool definitions for the shared guidance; here it is state of `subagents`, registered as an effect.
- **Out-of-process providers share one line-protocol client.** ACP, Codex and the DSH SDK child all speak newline-delimited JSON-RPC, so one private module frames all three, and each provider is a few hundred lines of protocol steps. When `dsh-sdk` (wave 5) defines its transport, this module can become a re-export.
- **Claude Code stays wrapped.** Its only supported programmatic surface in dsh is an npm SDK. The sidecar is one plain `.mjs` file that forwards SDK messages over a pipe; all classification, diagnostics and settlement stay in Racket.
- **Durable values are jobjects in dsh key order.** Descriptor, catalog facts, task snapshots, notices and run information are built with `jobj`, and task transitions are `jset` and `jremove`, which give the key positions JavaScript object spread gives.
- **Ports with late-bound defaults**, as in `dsh-context`: the package compiles and tests without its siblings, and test doubles implement the port interfaces.
- **No new macro.** `define-tool` covers every static tool; the delegation tool is built with `make-tool` because its parameter list is data.
- **Racket-only additions**, for the coordinator's ADR list: the ports module; the config keys `x-racket.command` (Codex), `x-racket.node` and `x-racket.sdkDir` (Claude Code); the service key `racket:dshLauncher` read by the DSH SDK provider; the sidecar pipe protocol of rule 84; `subagents-delegation-tool!`; `sessions` and `subprocess` added to two inject lists; the parameter `current-wait-timer` of `private/wait.rkt` (`(-> real? evt?)`, default an `alarm-evt` on the monotonic clock), which lets tests fire the `wait_agent` timeout without waiting.

## Work units

Three units. The interface between them is the set of public module exports listed under Modules.

| Unit | Modules | Depends on |
|---|---|---|
| A: runtime | `ports`, `types`, `names`, `session-events`, `descriptor`, `projections` (the three subagent projections), `messages`, `child-agent`, `structured`, `subagents`, the plugins `subagent`, `subagent-spawn-in-process`, `subagent-fork-in-process`, and their tests | wave 3 |
| B: tools and teams | the plugins `tool-subagent`, `model-selection-settings`, `tool-subagent-control`, `team`, the policy and team projections, the plugins `agent-team`, `tool-agent-team`, `plugins`, `main`, and their tests | unit A's public modules |
| C: out-of-process providers | `out-of-process`, `private/jsonrpc-lines.rkt`, the four provider plugins, the sidecar, and their tests | from unit A only `types`, `ports` |

Unit A delivers `types`, `ports`, `names` and `session-events` first. Unit C needs nothing else of A and can be built at the same time. Unit B is written against this document and a stub provider until A's manager exists.

## Tests

Tests live in `racket/dsh-subagent/tests/`. All manager and tool tests run through `call-with-loop-harness` of `dsh-test-support` with scripted models, an in-memory persistence port, and port doubles for the working directory and session query. Tests sequence on events (`subagent/start`, `subagent/end`, `agent/status`, gate tools), never on sleeps.

| Racket test file | Mirrors | Pins |
|---|---|---|
| `names-test.rkt`, `descriptor-test.rkt`, `catalog-test.rkt` | `subagent/tests/sibling-messages.spec.ts` (name cases), `catalog.spec.ts`, `timing-projection.spec.ts` | rules 1 to 11 |
| `service-test.rkt` | `service.spec.ts`, `activation-policy.spec.ts` | rules 12 to 15, 53; disposal of a provider's fiber removes it and emits `subagent/provider-removed` |
| `local-activation-test.rkt` | `continuation.spec.ts`, `continuation-inheritance.spec.ts`, `child-agent.spec.ts`, `working-directory.spec.ts`, `subagent-fork-in-process/tests/*.spec.ts` | rules 16 to 22, 24 to 30; the child log order of rule 30; the fork seed ends at the last `turn/end` |
| `settlement-test.rkt` | `run-settlement.spec.ts`, `factory-settlement.spec.ts`, `parent-result.spec.ts`, `assistant-output.spec.ts`, `parked-wait.spec.ts` | rules 31 to 37, 50: settlement order, failure without a committed `turn/end`, teardown failure reporting, parked inboxes |
| `messages-test.rkt` | `continuation-messages.spec.ts`, `continuation-messages-adapter.spec.ts` | rules 21, 38 to 40: every notice text, guidance, closing-text omission |
| `messaging-test.rkt` | `sibling-messages.spec.ts`, `continuation-presets.spec.ts`, `activation-presets.spec.ts` | rules 41 to 45: steer, cold resume of only the target, ancestry checks, preset restoration with a preset port double |
| `tree-test.rkt` | `list-children.spec.ts`, `archive-admission.spec.ts`, `control.spec.ts` | rules 46 to 49, 51, 52, 54, 55, 58, 59 |
| `external-activation-test.rkt` | `external-activation.spec.ts`, `external-lifecycle.spec.ts`, `out-of-process.spec.ts` | rules 23, 34 (external), 74, with a scripted provider |
| `structured-test.rkt` | `structured.spec.ts` | rules 56 and 57, including a nested execution |
| `tool-subagent-test.rkt` | `tool-subagent/tests/{tool-subagent,depth-context,model-selection*,list-models,preset-selection}.spec.ts` | rules 60 to 67: schema and wording per provider kind, mount and unmount on provider change, depth context text |
| `control-tools-test.rkt` | `tool-subagent-control/tests/{tool-subagent-control,list-agents,wait-agent}.spec.ts` | rules 68 to 73: subscribe before read, same-call dedupe, cleanup, timer through `current-wait-timer` |
| `acp-test.rkt`, `codex-test.rkt`, `sdk-test.rkt` | `subagent-acp/tests`, `subagent-codex/tests`, `subagent-dsh-sdk/tests` | rules 75 to 82 and 87 to 89, each against a fake child written in Racket (a script run with the `racket` executable) that speaks the protocol; no Node |
| `claude-code-test.rkt` | `subagent-claude-code/tests` | rules 83 to 86 against a Racket fake that speaks the sidecar protocol in place of `node`; one extra case runs the real sidecar with a stub SDK directory and is skipped with a visible message when `node` is absent |
| `team-test.rkt` | `agent-team/tests/{team,projection-events,persistence}.spec.ts`, `historical-records-fixture.ts` | rules 90 to 95: every action and error code, key positions of snapshots, failure retention, historical events |
| `tool-team-test.rkt` | `tool-agent-team/tests/tool-team.spec.ts` | rules 96 and 97 |
| `plugins-test.rkt` | none | every row of `plugin-table` loads; removed config keys fail as stated; one rejected config per plugin raises with the prefix `invalid config:` |

Key-order fixtures, compared as `jvalue->string` text after the normaliser of `dsh-test-support`: the `subagent/descriptor` line of `snapshots/session/subagent-spawn-in-process/session.1.v4.jsonl`; the `subagent/catalog` line and the settlement notice of `snapshots/session/subagent-multi/session.v4.jsonl`; the `agent-message` user message of `snapshots/sdk/subagent-send-message`; the `team/task` lines of `snapshots/session/team-task-inbox/session.v4.jsonl` and `snapshots/session/team-targets`.

Recorded sessions that exercise this package (replayed in wave 5; listed for the parity table): `snapshots/session/{subagent-spawn-in-process,subagent-multi,subagent-parallel,subagent-structured-parent,subagent-depth-two-rejection,subagent-depth-context-disabled,subagent-max-tokens-partial,subagent-agent-preset,subagent-tool-filter,subagent-archive-lineage,subagent-child-question-rejection,subagent-no-message-tool,subagent-published-run-failure,subagent-acp-diagnostic,product-subagent-both,product-subagent-codex,product-subagent-oar,product-subagent-result-diagnostic,team-direct-inbox,team-historical-records,team-session-mode,team-targets,team-task-inbox,team-tree-messages}`, `snapshots/sdk/{subagent-activation-limit,subagent-continuable,subagent-continuable-inheritance,subagent-dsh-sdk-diagnostic,subagent-dsh-sdk-dynamic-route,subagent-fork-in-process,subagent-list-agents,subagent-mixed,subagent-send-message,subagent-spawn-in-process,background-wait-steer,team-default-enabled,team-session-mode}`, `snapshots/web/{subagent-conversation,subagent-fork-schedule,subagent-interrupt,official-subagent-bundle}`.

Acceptance gate: `raco test racket/dsh-subagent` passes with no network and no Node; every numbered rule has a test that names it; the key-order fixtures pass; a scripted session in which the parent calls `subagent` twice in one assistant message and ends its turn writes, in the parent log, two `tool/call` and `tool/result` pairs with texts `started subagent agent-1` and `started subagent agent-2`, two `subagent/catalog` facts, and then two settlement notices that each start a new turn, while each child log holds `subagent/descriptor` before its first `turn/start`.

## Open questions

1. **Sibling names behind the ports.** The owner procedures of `subprocess`, `sandboxPolicy`, `attachments` and `workspaceRegistry` were taken from the drafts of `dsh-exec.md`, `dsh-fs.md` and `dsh-platform.md`, and those of `agentPresets` from `dsh-context.md`; those of `workingDirectory`, `sessionPersistence`, `sessionQuery` and `permissionPresets` are guesses at contracts not yet written. Sibling contracts declare their own consumer-owned port interfaces for the same services. Recommended default: keep the wrapper signatures of this document; when the coordinator gives each shared port one home, `dsh-subagent/ports` re-exports it and drops its own interface and the `dynamic-require` fallback.
2. **Session observation.** Cold resume and discovery need a read of a stored session that yields its header, its events, its inherited event count and current projection values without loading an agent, and that must be released. Recommended default: the observation accessors of the ports table; if `dsh-session-store` offers only a live read, the port builds the observation from it and makes the release a no-op.
3. **Projection state of `subagentCatalog`.** dsh stores the facts in a chunked list so that checkpoints stay small. If `dsh-session-store` persists projection checkpoints in the dsh format, this shape must match exactly; otherwise a plain list would do. Recommended default: keep the dsh shape (rule 7), with the chunk helper taken from `dsh-util` when it has one and written privately otherwise.
4. **Coded failures of the Remote methods.** `gateway/bad-request`, `gateway/cancelled`, `gateway/internal` and the `subagent/*` codes belong to the remote layer of `dsh-web`. Recommended default: raise `exn:fail:subagent-remote` with the code, the dsh message and the details jobject, as `dsh-llm` does with `exn:fail:llm-discovery-rejected`, and let `dsh-web` map it.
5. **Launcher for the DSH SDK provider.** Recommended default: `dsh-boot` provides `racket:dshLauncher` as the list of strings that starts the running harness (the executable and any leading arguments); without it `dshBin` is required.
6. **Codex executable.** dsh pins the product through an npm dependency; the port uses whatever `codex` the host has. Recommended default: `x-racket.command` with default `["codex"]`; a missing executable fails the start with the startup failure and logs the missing name once at mount.
7. **Explicit clear of the reasoning effort.** dsh passes `reasoningEffort: undefined` as an own property to clear the parent's effort in the merge. Recommended default: `'null` in the requested options means "clear" inside this package only and is removed before the options reach `agents-create`.
8. **`sessions-flush` taking part.** Rule 93 needs to know whether a durability listener took part; `sessions-flush` returns that boolean. No action needed unless `dsh-session-store` changes it.
9. **Agent error names in log text.** `<name>` in contained listener failures is `Error` for non-harness exceptions, where dsh prints the JavaScript class name. Recommended default: as written; log text is not a compatibility surface.
