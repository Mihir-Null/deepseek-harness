# Interface contract: `dsh-agent`

This is the binding interface for `racket/dsh-agent/`. It covers the agent value and its vocabulary, the registry service `agents`, the initiator scope, every `agent/*` event, the model-selection, turn-boundary and inbox projections, the loop service `agentLoop` with its turn and step machine, the deployment default `agentDefaultModel`, and a wave 3 provider of `sessionProjections`. Sources: [recon 05](../recon/05-core-loop.md) (cited as R5 with its section letter), `packages/core/{agent,agent-loop,agent-default-model}/src` at commit `e8f7b93a3`, `docs/agent-lifecycle.md`. When this document and the TypeScript disagree about behaviour, the TypeScript is right and this document gets fixed. When they disagree about names and argument order of the Racket surface, this document is right. Read [dsh-session.md](dsh-session.md), [dsh-llm.md](dsh-llm.md) and [dsh-tools.md](dsh-tools.md) first; this contract uses their vocabulary without repeating it (`absent`, `session-append!`, the session event constructors, jobjects, `chunk-stream`, `prepared-call`, cancel sources and cancel events of `dsh-llm/cancel`, which `dsh-tools` re-exports, `create-scope`, `scoped-dispatch`).

Package: directory `racket/dsh-agent/`, collection `dsh-agent`, `(define deps '("base" "cordis" "cordis-data" "cordis-schema" "dsh-util" "dsh-session" "dsh-llm" "dsh-tools"))`, `(define build-deps '("rackunit-lib"))`. It must not depend on `dsh-test-support`; that package depends on this one.

## Scope

| dsh package | npm name | Status |
|---|---|---|
| `packages/core/agent` | `@deepseek-ai/dsh-agent` | native. The typert lookup and host context named `agent` (`index.ts:259-270`) are adapted: the package that owns `typert` (wave 5) registers them with `agents-find`. Cordis service tracing is replaced by the explicit owner context (ADR 0003). |
| `packages/core/agent-loop` | `@deepseek-ai/dsh-agent-loop` | native. Session persistence is reached through a generic interface defined here, because its provider is built in wave 4. |
| `packages/core/agent-default-model` | `@deepseek-ai/dsh-agent-default-model` | native. The settings service and the config editor are reached through generic interfaces defined here. |
| (none) | `racket:session-projections` | Racket-only. An in-memory provider of the service key `sessionProjections`, which two plugins of this package and two of `dsh-llm` inject and which dsh implements in `packages/session/session-projection` (wave 4). It implements `gen:projection-port` of `dsh-llm/ports` and nothing else of the dsh registry. |

`packages/core/tool-executor-ptc` is covered by `dsh-ptc`. None of the covered packages registers a model-facing tool.

## Modules

| Module | Provides |
|---|---|
| `dsh-agent` (`main.rkt`) | re-exports `types`, `events`, `agents`, `model-selection`, `consumed-work`: what a plugin that works with agents requires |
| `dsh-agent/types` | `gen:agent` and the procedures on an agent, cancel causes, inbox targets, model selections, pre-step decisions, stream frames, handles, creation options, `agent-payload?`, the error structs |
| `dsh-agent/session-events` | the session event declarations `agent/inbox/spliced` and `model/selection` |
| `dsh-agent/events` | the thirteen event declarations, `agent-emit`, `agent-serial`, `agent-waterfall`, `assemble-context-for` |
| `dsh-agent/agents` | the `agents` service definition and its procedures, `gen:agent-factory`, `turn-boundary-projection` |
| `dsh-agent/model-selection` | `model-selection-projection`, `model-selection-apply`, `model-selection-view`, `same-model-selection?`, `install-model-selection!`, `model-switch-notice` |
| `dsh-agent/consumed-work` | `fold-consumed-work` |
| `dsh-agent/ports` | `gen:session-persistence-port`, `gen:stored-session`, `exn:fail:persistence-not-found`, `gen:config-editor-port`; a re-export of `gen:settings-port` of `dsh-llm/ports` |
| `dsh-agent/loop` | the `agentLoop` service definition and its procedures, `inbox-projection`, `inbox-apply`, `default-max-parallel-tool-calls`, `configured-agent-identities-key` |
| `dsh-agent/default-model` | the `agentDefaultModel` service definition and its procedures |
| `dsh-agent/projections` | `make-memory-projections` |
| `dsh-agent/testing` | helpers for tests of code built on the loop: prerequisite mounting, the scripted model, a stub agent (Services, "Testing support") |
| `dsh-agent/plugin/agent`, `…/agent-loop`, `…/agent-default-model`, `…/session-projections` | each provides `plugin` |
| `dsh-agent/plugins` | `plugin-table` |

Private modules, suggested: `private/registry.rkt`, `private/initiator.rkt`, `private/archive-admission.rkt`, `private/inbox.rkt`, `private/driver.rkt` (phase machine, send, cancel, maintenance, turn, pre-step), `private/step.rkt` (attempt loop, request preparation, header and request construction), `private/system-prompt-projection.rkt`, `private/runtime-context.rkt`, `private/assistant-stream.rkt`, `private/lifecycle.rkt` (initialization and teardown), `private/configured.rkt`. Work units names the private modules that cross unit lines.

## Data

### Small values

All of these are jobjects or strings because they are written to the session log.

```racket
(inbox-target? v)                        ; "next-turn" or "next-step"
(model-selection? v)                     ; jobject {provider, model, reasoningEffort?}, strings, provider and model non-empty
(make-model-selection provider model [effort absent]) -> model-selection?
(same-model-selection? a b) -> boolean?  ; a, b : (or/c model-selection? #f); provider, model and effort equal, an absent effort equal only to an absent effort
(agent-cancel-cause? v)                  ; jobject {kind: "user"}, {kind: "parent"}, {kind: "hook", reason: string} or {kind: "disposed"}
cause-user cause-parent cause-disposed   ; the three constant causes
(cause-hook reason) -> agent-cancel-cause?
(agent-options? v)                       ; jobject; known keys provider, model, reasoningEffort (strings), maxTokens (positive safe integer); other keys are allowed and kept
```

### The agent interface (`dsh-agent/types`)

An agent is any value that implements `gen:agent`. The loop's own agent is an opaque struct; a custom driver or a test supplies its own struct. An agent is a scope key for `dsh-tools/scope`, so it must be a struct instance and is compared with `eq?`.

```racket
(define-generics agent
  (agent-id agent)                                        ; -> session-id?, equal to (session-id (agent-session agent))
  (agent-options agent)                                   ; -> agent-options?, the value given at creation
  (agent-session agent)                                   ; -> session?
  (agent-ctx agent)                                       ; -> context?, the agent-scoped context
  (agent-status agent)                                    ; -> (or/c 'idle 'running)
  (agent-cancel! agent cause #:keep-inbox? [keep? #f])    ; -> void?
  (agent-when-idle agent)                                 ; -> void?, waits
  (agent-run-maintenance agent job)                       ; job : (-> evt? any); -> the job's values
  (agent-send! agent message target wakeup?)              ; -> void?
  (agent-model-current agent)                             ; -> (or/c model-selection? #f)
  (agent-model-select! agent selection)                   ; -> void?
  (agent-inbox agent)                                     ; -> jobject {next-turn: [message…], next-step: [message…]}
  (agent-inbox-splice! agent target start delete-count inserted))   ; -> (listof jobject?), the removed messages
(agent? v) -> boolean?
```

Procedures derived from the generic operations, defined once in `dsh-agent/types` for every implementation:

```racket
(agent-followup! agent message) -> void?                  ; (agent-send! agent message "next-turn" #t)
(agent-steer! agent message) -> void?                     ; (agent-send! agent message "next-step" #t)
(agent-inject! agent message) -> void?                    ; (agent-send! agent message "next-step" #f)
(agent-inbox-next-turn agent) (agent-inbox-next-step agent) -> (listof jobject?)
(agent-inbox-append! agent target message) -> void?       ; splice at the length of the list
(agent-inbox-prepend! agent target message) -> void?      ; splice at 0
(agent-inbox-replace! agent message-id new-message) -> boolean?
(agent-inbox-remove! agent message-id) -> boolean?
(agent-inbox-clear! agent) -> void?
```

Fallbacks of `gen:agent`: `agent-inbox` and `agent-inbox-splice!` raise `exn:fail` `this test Agent does not support Inbox mutations`; `agent-model-current` and `agent-model-select!` raise `this test Agent does not support model selection`. The other operations have no fallback. dsh `Agent` has no `interrupt`, no `meta` and no `dispose` member; session metadata is `(session-header (agent-session agent))`.

`message` and `new-message` are user messages (`user-message?` of `dsh-llm`) with an `id`. `start` and `delete-count` are real numbers, including `+inf.0`, `-inf.0` and `+nan.0` (rule 21). No procedure on an agent registers an effect on a context. All of them must be called from a task. Only `agent-when-idle` and `agent-run-maintenance` wait; `agent-send!`, `agent-cancel!` and the inbox and model mutations return after their synchronous work, which includes session appends and their listeners.

### Decisions, frames, handles

```racket
(struct pre-step-reject () #:transparent)
(struct pre-step-enter (messages starts-request-series?) #:transparent)   ; messages : (listof user-message?)
(make-pre-step-enter messages #:starts-request-series? [s #f]) -> pre-step-enter?
(pre-step-decision? v)                              ; pre-step-reject? or pre-step-enter?
request-error-retry                                 ; the jobject {kind: "retry"}
(request-error-retry? v) -> boolean?                ; a jobject or hash whose kind is "retry"

(struct agent-handle (agent dispose))               ; dispose : (-> void?), waits; dsh AgentHandle
(agent-handle-dispose! h) -> void?
(struct create-agent-options (session-id meta inherited-event-count seed agent-options cancel setup))
(struct resume-agent-options (resume-session-id agent-options cancel setup))
```

`meta` is `#f` or a jobject with the optional keys `cwd`, `parentSession`, `isSeeded`, `origin` (`"subagent"`), `delegationDepth`, `agentPreset`. `seed` is `#f` or a list of session events. `cancel` is `#f` or a cancel event that governs creation only. `setup` is `#f` or `(-> context? agent? (or/c #f void? (-> any)))`: it receives the agent context and the agent, may wait, and returns nothing or a commit thunk (dsh `AgentSetupCommit.commit`).

An assistant stream frame is a jobject, because user interfaces receive it as JSON. Declared with `define-jrecord` of `dsh-llm/jrecord`, tagged on `type`, keys in this order (`agent/src/runtime-types.ts:126-155`):

| jrecord | `type` | Keys in order |
|---|---|---|
| `stream-frame-start` | `start` | `attemptId`, `revision`, `turn`, `step` |
| `stream-frame-chunk` | `chunk` | `attemptId`, `revision`, `index`, `time`, `chunk` |
| `stream-frame-end` | `end` | `attemptId`, `revision`, `index`, `outcome` |

`outcome` is `{kind: "committed", eventType, seq}` with `eventType` `"assistant/message"` or `"assistant/attempt"`, or `{kind: "abandoned"}`. `(define-junion assistant-stream-frame #:tag type (stream-frame-start stream-frame-chunk stream-frame-end))` gives the closed `assistant-stream-frame-case`. `attemptId` is the string `<sessionId>:<n>`.

### Event payloads

Every `agent/*` event carries one payload: an immutable `hasheq` whose keys are the dsh payload keys as symbols, spelled as in dsh (`'modelSelection`, `'retryPolicy`), with `'cancel` (a cancel event) in place of `signal`. The dispatch helpers add `'agent` and `'session` last, so a caller cannot override them. `(agent-payload? v)` holds for an immutable hash with an `'agent` key. `jref` of `cordis-data` reads such a hash, which is how `dsh-llm/retry` reads `agent/request-error`. The payload is process-local and is never logged.

### Session events declared here (`dsh-agent/session-events`)

Declared with `define-session-event`. Neither is surface-eligible or ignorable. Both names are in `known-session-event-types`.

| Racket id | dsh type | Data fields in write order (JSON key: contract) |
|---|---|---|
| `agent/inbox/spliced` | `agent/inbox/spliced` | `target`: `inbox-target?`; `start`: `session-seq?`; `removedCount?` (`removed-count`): positive `session-seq?`; `inserted`: `(listof user-message-jvalue?)`; `outcome?`: `"canceled"` |
| `model/selection` | `model/selection` | `provider`: `string?`; `model`: `string?`; `reasoningEffort?` (`reasoning-effort`): `string?` |

`removedCount` is omitted when 0. `inserted` is always written, possibly `[]`. `outcome` is written exactly when a public mutation removed at least one message.

### Projection states

States are jvalues; `null` is `'null`. Each is a `projection-definition` of `dsh-llm/ports`.

| Binding | Key | `stateVersion` | State, keys in order | Wire view |
|---|---|---|---|---|
| `turn-boundary-projection` | `turnBoundary` | 2 | `{openTurnStartSeq, lastStepStartSeq, lastStepBoundary, lastTurn}`; the first three are a seq or `null` (`lastStepBoundary` is `{kind: "start" or "end", seq}` or `null`); initially all `null` and `lastTurn: 0` | none |
| `model-selection-projection` | `modelSelection` | 3 | `{lastUsed, pending}`, each a model selection or `null`; initially both `null` | `{lastUsed, next}` with `next` the pending selection, else `lastUsed` |
| `inbox-projection` | `inbox` | 1 | `{next-turn: [message…], next-step: [message…]}`; initially both empty | the state itself |

### Errors

```racket
(struct exn:fail:agent exn:fail (cause))                  ; cause : any/c or #f; a failure that wraps another value
(struct exn:fail:agent:aggregate exn:fail:agent (errors)) ; errors : list; the counterpart of AggregateError
(struct exn:fail:persistence-not-found exn:fail (session-id))   ; dsh SessionPersistenceNotFoundError, raised by providers of the persistence port
```

Where dsh throws a plain `Error` this package raises `exn:fail` with the same message; where dsh throws `TypeError` it raises `exn:fail:contract`. None of these is an `exn:fail:harness`. All messages are listed in Behaviour.

## Services

`x` is a context or a handle for the service; "the caller's context" is `(use-context x)`.

### `agents` (key `'agents`)

`(define-service agents 'agents #:contract agent-registry?)` in `dsh-agent/agents` defines `agents-key`, `agents-ref`, `agents-get` (the optional read of the service value) and `provide-agents`. The dsh method `get(id)` is therefore named `agents-find`. The value is an opaque `agent-registry`: an insertion-ordered table from session id to entry, one factory slot, the initiator scope, and the handle of the `turnBoundary` projection.

```racket
(agents-find x id) -> (or/c agent? #f)
(agents-list x) -> (listof agent?)
(agents-create x #:session-id id #:meta [meta #f] #:inherited-event-count [n #f] #:seed [seed #f]
               #:agent-options [options #f] #:cancel [cancel #f] #:setup [setup #f]) -> agent-handle?
(agents-resume x #:resume-session-id id #:agent-options [options #f] #:cancel [cancel #f] #:setup [setup #f]) -> agent-handle?
(agents-set-factory! x factory) -> disposer?
(agents-register! x agent) -> disposer?
(agents-enter! x agent) -> (-> void?)
(agents-announce x agent source #:cancel [cancel #f]) -> void?      ; source : (or/c 'startup 'resume 'clear 'compact)
(agents-turn-boundary-of x session) -> jobject?
(agents-with-initiator x agent thunk) -> any
(agents-without-initiator x thunk) -> any
(agents-current-initiator x) -> (or/c agent? #f)
(agents-require-initiator x) -> agent?

(define-generics agent-factory
  (agent-factory-create agent-factory owner-ctx options)     ; options : create-agent-options?; -> agent-handle?, waits
  (agent-factory-resume agent-factory owner-ctx options))    ; options : resume-agent-options?; -> agent-handle?, waits
```

| Procedure | Semantics | Effects on the caller's context |
|---|---|---|
| `agents-find`, `agents-list` | Live agents; the list is fresh and in registration order. | none |
| `agents-create`, `agents-resume` | Rule 3. Wait. The caller's context is the owner of the creation and of the live agent. | those the factory registers on the owner (rule 59) |
| `agents-set-factory!` | Rule 4. | one effect `agents.setFactory()`; the result is that effect's disposer, so an outer effect can adopt it as a child |
| `agents-register!` | Rule 9. For agents constructed outside the factory. | one effect `agents.register()` with asynchronous setup; `(await disposer)` before using the agent |
| `agents-enter!` | Rule 5. Returns the single-shot detach procedure. | none; the caller owns the returned procedure |
| `agents-announce` | Rule 6. Waits for the `agent/created` listeners. | none |
| `agents-turn-boundary-of` | The `turnBoundary` state of any session, live agent or not. | none |
| the four initiator procedures | Rules 10 and 11. | none |

There is no `dispose(id)` on the registry, in dsh or here. An agent leaves through its handle, through the detach procedure of `agents-enter!`, or through the disposer of `agents-register!`.

### `agentLoop` (key `'agentLoop`)

`(define-service agent-loop 'agentLoop #:contract agent-loop?)` in `dsh-agent/loop` defines `agent-loop-key`, `agent-loop-ref`, `agent-loop-get`, `provide-agent-loop`. The value is an opaque `agent-loop` that implements `gen:agent-factory`.

```racket
(agent-loop-create x id [options #f] [meta #f]) -> agent?            ; waits; the caller's context is the owner
(agent-loop-max-parallel-tool-calls x) -> exact-positive-integer?    ; the current value of the volatile config field
(agent-loop-config x) -> jobject?                                    ; the validated config after launcher identities were applied
default-max-parallel-tool-calls                                      ; 10
configured-agent-identities-key                                      ; 'configuredAgentIdentities
```

`agent-loop-create` is the config and test path (rule 59): a fresh session with `meta` (a jobject with optional `cwd`), source `'startup`, and the bare agent as result. Disposing the owner's fiber tears the agent down. Factory use goes through `agents-create` and `agents-resume`.

### `agentDefaultModel` (key `'agentDefaultModel`)

`(define-service agent-default-model 'agentDefaultModel #:contract agent-default-model?)` in `dsh-agent/default-model`.

```racket
(agent-default-model-current-selection x) -> model-selection?        ; reads the config at call time
(agent-default-model-save-selection! x selection) -> void?           ; waits; rule 67
```

### `sessionProjections` (key `'sessionProjections`), wave 3 provider

`(make-memory-projections) -> projection-port?` in `dsh-agent/projections` returns a value that implements `gen:projection-port` of `dsh-llm/ports`: `(projection-register! port ctx definition)` and `(projection-state port handle session)`. Rules 68 and 69. This package reads the service only through that interface, so it works unchanged with the provider of `dsh-session-store`.

### `configuredAgentIdentities` (a provided value)

A launcher may `(ctx-provide ctx 'configuredAgentIdentities identities)` before the loop mounts. `identities` is a jobject or hash from a configured agent `id` to `{id: <session id>, resume: <boolean>}`. The loop reads it once in its plugin body with `ctx-get`.

### Ports (`dsh-agent/ports`)

```racket
(define-generics session-persistence-port
  (persistence-create session-persistence-port header #:inherited-event-count [n 0] #:cancel [cancel #f])   ; header : session-header?; -> stored-session?, waits
  (persistence-open session-persistence-port id mode #:cancel [cancel #f]))                                 ; mode : 'write; -> stored-session?, waits
(define-generics stored-session
  (stored-session-header stored-session)                         ; -> session-header?
  (stored-session-inherited-event-count stored-session)          ; -> session-log-offset?
  (stored-session-read stored-session from to #:cancel [cancel #f])   ; to : offset or #f; -> (values (listof session-event?) (or/c 'detached 'shared-frozen))
  (stored-session-append! stored-session events)                 ; -> void?, waits until stored
  (stored-session-close! stored-session))                        ; -> void?, waits; drains events already routed to the handle and releases write ownership
(define-generics config-editor-port
  (config-editor-edit! config-editor-port ctx update))           ; update : (-> jobject? jobject?); rewrites the profile row of ctx's loader entry; waits
settings-port? settings-configure! gen:settings-port            ; re-exports of dsh-llm/ports: (settings-configure! port ctx options) -> an effect result
```

The service keys are `sessionPersistence`, `configEditor` and `settings`, all read with `port-get` of `dsh-llm/ports`. `persistence-open` raises `exn:fail:persistence-not-found` when no stored session has the id. A persistence provider stores live events itself by listening to `session/event`; the loop hands it only the events that exist before the session enters the store.

### Waiting and cancellation

Every procedure that can wait says how it is cancelled:

- `agents-create`, `agents-resume` and the two operations of `gen:agent-factory`: `#:cancel` (the `cancel` field of the options). It governs creation only: when it becomes ready before the handle is returned, creation is rolled back and the call raises as rule 58 step 1 states. Afterwards it has no effect.
- `agent-loop-create` takes no cancel event, as dsh `create(id, options, meta)` takes no signal. Disposing the owner's fiber or unloading the loop cancels the creation's lifetime source (rule 58 steps 1 and 5).
- `agents-announce`: `#:cancel` is handed to the listeners as `'cancel`. The dispatch waits for every listener and is not interrupted by it.
- `agents-register!`: its setup is the asynchronous setup of an effect; calling the disposer waits for the setup to settle and then detaches (cordis-kernel section 4 rule 5).
- A running turn: `agent-cancel!` with a cause. Every wait of the driver takes the turn's cancel event (`tools-resolve`, the assemble context, `llm-prepare-call`, the request, the tool batch, every payload).
- `agent-run-maintenance`: the job is called with the maintenance phase's cancel event, which `agent-cancel!` makes ready.
- `agent-serial` and `agent-waterfall`: the `'cancel` entry of the payload, which listeners observe; the helpers do not interrupt a listener.
- `agent-when-idle` and `agent-handle-dispose!` take no cancel event. A break delivered to a task waiting in either one ends that task's wait only; the driver and the memoised teardown continue.
- `agent-default-model-save-selection!` takes no cancel event. Each save runs as its own task in the queue and the caller waits for it; a break ends the caller's wait and the save still runs in its turn.
- Port operations: `persistence-create`, `persistence-open` and `stored-session-read` take `#:cancel`. `stored-session-append!`, `stored-session-close!` and `config-editor-edit!` take none, because a durable write must complete; a provider keeps the write going when the caller's wait is broken.

### Library procedures

```racket
;; dsh-agent/events
(agent-emit ctx agent name fields) -> void?                    ; name : symbol; fields : hash of payload keys; contained (rule 13)
(agent-serial ctx agent name fields) -> any/c                  ; waits; failures propagate
(agent-waterfall ctx agent name fields inner) -> any           ; inner : (-> any); waits; failures propagate
(assemble-context-for agent [cancel #f]) -> assemble-context?  ; scope and 'agent both the agent; cancel when given
;; dsh-agent/model-selection
(model-selection-apply state event) -> jobject?                ; rule 16
(model-selection-view state) -> jobject?
(install-model-selection! agent-ctx agent) -> disposer?        ; rule 17
(model-switch-notice from to) -> jobject?                      ; the notice user message
;; dsh-agent/consumed-work
(fold-consumed-work events) -> (values (or/c session-event? #f) boolean?)   ; the accounting turn/end, dropped-unrun?
;; dsh-agent/loop
(inbox-apply state event) -> jobject?                          ; rule 24
```

### Testing support (`dsh-agent/testing`)

Used by this package's own tests and re-exported by `dsh-test-support`. Rules 70 to 72. The module also exports the two plugin values its defaults name: `native-executor-plugin` is the `plugin` of `dsh-tools/plugin/tool-executor-native` and `memory-projections-plugin` is the `plugin` of `dsh-agent/plugin/session-projections`.

```racket
(mount-agent-loop-test-dependencies ctx #:system-prompt [config (jobj)] #:projections [plugin memory-projections-plugin]
                                    #:executor [executor native-executor-plugin]) -> void?
(mount-agent-loop-test-harness ctx #:config [config (jobj [agents '()])]) -> void?
(make-scripted-model script #:reasoning [reasoning #f] #:default-max-tokens [n #f]
                     #:system-prompt-update [spu #f] #:tool-update [tu #f]) -> scripted-model?   ; implements gen:llm-adapter
(scripted-model-requests m) -> (listof llm-request?)
(scripted-model-remaining m) -> exact-nonnegative-integer?
(text-response text) (max-tokens-response text) -> (listof jobject?)
(tool-call-response call-id name arguments [text #f]) -> (listof jobject?)      ; arguments : jvalue?
(hang-after chunks) -> scripted-entry?
(hang-slow release-evt) -> scripted-entry?
(make-stub-agent #:id id #:session session #:ctx ctx #:options [options (jobj)] #:inbox? [inbox? #t]) -> agent?
(loop-agent-claim! agent target turn) -> (listof jobject?)     ; the loop's private claim, for tests of inbox notifications
```

## Events

Declared in `dsh-agent/events`. The module exports the `on-…` and `…-name` bindings and not the generated dispatchers: agent events are dispatched only through `agent-emit`, `agent-serial` and `agent-waterfall`, which use `scoped-dispatch` and `scoped-callbacks` of `dsh-tools/scope` with the agent as scope key and no base filter. A listener registered through an untagged context hears every agent; a listener registered through some `(agent-ctx a)` hears `a` and agents whose scope has `a` as an ancestor.

```racket
(define-event agent/created           'agent/created           #:mode serial    #:args (agent-payload?))
(define-event agent/disposed          'agent/disposed          #:mode emit      #:args (agent-payload?))
(define-event agent/status            'agent/status            #:mode emit      #:args (agent-payload?))
(define-event agent/inbox/inserted    'agent/inbox/inserted    #:mode emit      #:args (agent-payload?))
(define-event agent/inbox/claimed     'agent/inbox/claimed     #:mode emit      #:args (agent-payload?))
(define-event agent/inbox/discarded   'agent/inbox/discarded   #:mode emit      #:args (agent-payload?))
(define-event agent/pre-step          'agent/pre-step          #:mode waterfall #:args (agent-payload?) #:result pre-step-decision?)
(define-event agent/request           'agent/request           #:mode waterfall #:args (agent-payload?) #:result jobject?)
(define-event agent/request-error     'agent/request-error     #:mode waterfall #:args (agent-payload?) #:result any/c)
(define-event agent/assistant-stream  'agent/assistant-stream  #:mode emit      #:args (agent-payload?))
(define-event agent/turn-stopping     'agent/turn-stopping     #:mode serial    #:args (agent-payload?))
(define-event agent/error             'agent/error             #:mode emit      #:args (agent-payload?))
(define-event agent-loop/config-start-failed 'agent-loop/config-start-failed #:mode emit #:args (hash?))
```

Payload keys are listed without `'agent` and `'session`, which every `agent/*` payload has. A waterfall listener is `(lambda (payload next) …)`; `(next)` takes no argument.

| Event | Mode | Payload keys | Dispatched by, when | Guarantees |
|---|---|---|---|---|
| `agent/created` | serial | `source` (symbol), `cancel` (only when `agents-announce` was given one; the loop always gives the lifetime event) | `agents-announce` | Listeners run in order, each waited for. A raise fails the creation and skips later listeners. Fires after setup and its commit, with the agent already in the registry. Input sent during the listeners is queued and released after the last one (rule 58). A listener must not wait for `agent-when-idle` or for its own owner's disposal. Listeners return `(void)`: a result for which `bailed?` holds stops the chain. |
| `agent/disposed` | emit, contained | none | the detach procedure (rule 7) | Only for an entry whose announcement began. In the loop's teardown it fires after the driver finished, the scope unwound and the stored handle closed, and before `session/disposed`. Inside a listener `(agents-find x id)` is `#f` and `(sessions-find x id)` is still the session. |
| `agent/status` | emit, contained | `status` (`'idle` or `'running`) | the driver on every change of `agent-status`, after the phase is committed | `'running` is emitted inside the waking `agent-send!`, before `turn/start`. Entering or leaving maintenance emits nothing. One running interval may span several turns. |
| `agent/inbox/inserted` | emit, contained | `message` | the inbox, after the `agent/inbox/spliced` event is committed | One per inserted message, in order, after the `discarded` emits of the same splice. |
| `agent/inbox/claimed` | emit, contained | `message`, `turn` | the claim (rule 23), after both of its splices | Order: the next-step messages, then the one next-turn message. A claimed message of a rejected step gets no further notification. |
| `agent/inbox/discarded` | emit, contained | `message` | the inbox, for each message removed by a public mutation, after the commit | Not emitted for claims. |
| `agent/pre-step` | waterfall | `messages`, `turn`, `step`, `cancel`, `modelSelection` | the driver, once per proposed step, after the claim, tool-set resolution and prompt assembly, before `step/start` | The innermost step returns the enter decision of rule 38. The returned decision is authoritative. Not repeated for retries. A raise fails the turn. |
| `agent/request` | waterfall | `turn`, `step`, `cancel` | the driver, once per request attempt, after `step/start`, before `llm-prepare-call` and before any system or user commit | The innermost step returns the seed call config. The result must keep provider, model and reasoning effort (rule 40). Deprecated in dsh but still dispatched and consumed; kept. |
| `agent/request-error` | waterfall | `turn`, `step`, `provider`, `failure`, `retryPolicy` (a `retry-policy`; absent without a prepared call), `cancel` | the driver, only for a stream that ended with a `finish` of kind `error` or `aborted`, after `assistant/attempt` is committed, inside the open step | The innermost step returns `#f`, which is terminal. `request-error-retry` repeats the attempt in the same step. Cancellation during the waterfall wins over a retry. Raised stream failures never enter it. |
| `agent/assistant-stream` | emit, contained | `frame` | the driver (rule 53) | Per attempt one `start`, chunk frames with dense indexes from 0, exactly one `end`. `revision` increases by one per frame across the whole life of one loop agent, from 1. A `committed` end follows the durable append whose `seq` it names. |
| `agent/turn-stopping` | serial | `turn`, `cancel` | the driver, when a step left the turn ending and the next-step list is empty | Listeners run in order, each waited for. Afterwards the driver reads the next-step list again. A raise ends the turn with `error`. |
| `agent/error` | emit, contained | `turn`, `step`, `error` (the raised value) | the driver, for every turn failure that is not a cancellation, before `turn/end` is appended; also for a failed `turn/start` or `turn/end` append | Not emitted for cancellation. `step` is 0 before the first step. |
| `agent-loop/config-start-failed` | emit, contained | `sessionId`, `error`; no `agent`, no scope key | the loop, when a config-declared agent fails to start while the loop is active | Preceded by a `warning` log (rule 63). No consumer exists in dsh. |

Consumed, registered by name with `ctx-on`: `session/event` on the agent context (the runtime-context projection, the per-step tool-call recovery observer); `agent/disposed` and `session/disposed` (the wait of rule 63); `internal/status` (the registry closes the initiator scope); `workspace/session-activity` (waterfall) and `workspace/session-stop` (parallel), owned by `dsh-platform` (rule 12); `agent/pre-step` with `#:prepend? #t` (`install-model-selection!`).

Dispatched indirectly through services the loop calls: `system-prompt/assemble`, `llm/stream`, `tools/pre-execute`, `tools/execute`, `tools/post-execute`, `tools/result`, and the `session/*` events of every append.

## Plugins

| dsh npm name | Module | Inject | Provides | Config |
|---|---|---|---|---|
| `@deepseek-ai/dsh-agent` | `dsh-agent/plugin/agent` | `sessionProjections` | `agents` | none |
| `@deepseek-ai/dsh-agent-loop` | `dsh-agent/plugin/agent-loop` | `agents`, `sessions`, `llm`, `tools`, `systemPrompt`, `sessionProjections`; optional reads `sessionPersistence`, `configuredAgentIdentities` | `agentLoop` | below |
| `@deepseek-ai/dsh-agent-default-model` | `dsh-agent/plugin/agent-default-model` | none; optional reads `settings`, `configEditor` | `agentDefaultModel` | below |
| `racket:session-projections` | `dsh-agent/plugin/session-projections` | none | `sessionProjections` | none |

`@deepseek-ai/dsh-agent-loop` config (`agent-loop/src/index.ts:294-306`):

| Field | Type | Default |
|---|---|---|
| `maxParallelToolCalls` | number, step 1, at least 1, volatile | `10` |
| `agents` | array of objects | `[]` |
| `agents[].id` | string, required | none |
| `agents[].sessionId` | string, at least 1 character | absent |
| `agents[].resumeSessionId` | string; the empty string counts as absent | absent |
| `agents[].provider` | string | absent |
| `agents[].model` | string | absent |
| `agents[].reasoningEffort` | string, at least 1 character | absent |
| `agents[].maxTokens` | number, step 1, at least 1, at most 9007199254740991 | absent |
| `agents[].cwd` | string | absent |

`@deepseek-ai/dsh-agent-default-model` config: `provider` string, required, volatile; `model` string, required, volatile; `reasoningEffort` string, volatile, absent by default.

Plugin bodies:

- `dsh-agent/plugin/agent`, in order: create the registry; listen to `internal/status` and close the initiator scope when the registry's own fiber or one of its ancestors enters `'unloading`; register one effect whose inverses are, in the order they run, "close the initiator scope" and then "dispose the initiator scope" (rule 11); install the two archive admission listeners (rule 12); `(projection-register! port ctx turn-boundary-projection)` and keep the handle; then `provide-agents`. The service is visible only after the projection is registered.
- `dsh-agent/plugin/agent-loop`: rule 64.
- `dsh-agent/plugin/agent-default-model`: create and provide the service; when `settings` is mounted, register `(settings-configure! settings ctx (jobj [auto #f]))` as an effect on a child context that injects `settings`.
- `dsh-agent/plugin/session-projections`: `(ctx-provide ctx 'sessionProjections (make-memory-projections))`.

`dsh-agent/plugins` provides `plugin-table` with those four rows.

## Behaviour

Numbering is for tests. "Raise" without a type means `exn:fail` with the exact message. `<id>` is the agent id. "The driver" is the loop's own agent implementation. A check written "cancelled?" reads the cancel event of the current turn; "check cancellation" is `(check-cancelled! evt)`, which raises the cancel reason: the cause value given to `agent-cancel!`, not an exception.

**Registry** (R5 "ctx.agents"; `agent/src/index.ts`)

1. An entry is `{id, agent, announced?, announcing?, detach-requested?}`. `agents-find` and `agents-list` see an entry from `agents-enter!` until its removal, announced or not.
2. `agents-turn-boundary-of` returns `(projection-state port handle session)` for the `turnBoundary` handle. The result is immutable.
3. `agents-create` and `agents-resume` raise `no agent factory registered (load an agent-loop plugin)` when the slot is empty. Otherwise they build the options struct and call `agent-factory-create` or `agent-factory-resume` with `(use-context x)` as owner.
4. `agents-set-factory!` raises `an agent factory is already registered` when the slot is taken, before any effect is made. The effect's inverse clears the slot if it still holds this factory.
5. `agents-enter!` raises `agent id "<id>" does not match session id "<sid>"` when the two differ and `agent "<id>" is already registered` on a duplicate id. It adds the entry and emits nothing.
6. `agents-announce` raises `agent "<id>" is not live in this registry` unless `agent` is `eq?` to the live entry's agent, and `agent "<id>" was already announced` when `announced?` is set. It sets `announcing?` and `announced?`, then dispatches `agent/created` with `agent-serial` on the registry's context. When the dispatch returns or raises, it clears `announcing?` and performs a requested detach. A listener failure propagates.
7. The detach procedure runs once. Called while `announcing?` is set it only sets `detach-requested?`. Removal deletes the table entry only if the table still maps the id to this exact entry, then emits `agent/disposed` when `announced?` is set. Because `announced?` is set before the dispatch, a creation whose listeners partly ran is still paired with `agent/disposed`.
8. `agent/disposed` is emitted with `agent-emit`. Its containment messages, logged at `warning` on the registry's context, are `agent "<id>": agent/disposed listener threw: <text>` and `agent "<id>": agent/disposed listener rejected: <text>`.
9. `agents-register!` runs, inside one effect with asynchronous setup, `agents-enter!` and then `(agents-announce x agent 'startup)`. The effect's inverse is the detach procedure. A failed announcement rolls the effect back, which detaches and emits `agent/disposed`.
10. Initiator scope (`index.ts:593-676`). The state is `'active`, `'closing` or `'disposed`. `agents-with-initiator` raises `agent initiator scope is disposed` unless the state is `'active`. It records a run `{agent, parent run, released?}`, increments the count of active runs, and calls `thunk` with the run installed in a module-private parameter; the result is the thunk's values. The run is released when the thunk raises; when it returns anything other than a single task, on return; when it returns a single task, when that task finishes (observed by a kernel task that waits for it and calls no user code). `agents-without-initiator` is the same with agent `#f`. `agents-current-initiator` raises `agent initiator scope is disposed` in state `'disposed` and otherwise returns the agent of the innermost run in the current parameterization, or `#f`. `agents-require-initiator` raises `no initiating agent is active` in place of `#f`. A task inherits the parameterization of its spawner (cordis-kernel section 2 rule 9), so work started inside a boundary keeps its initiator.
11. Closing moves `'active` to `'closing`. Disposing, which is memoised, closes, releases every run on the caller's own boundary chain so that a boundary that triggers teardown does not wait for itself, waits until the count is zero, and sets `'disposed`.
12. Archive admission (`archive-admission.ts`). The `workspace/session-activity` listener reads `sessionId` from its payload, notes whether `(agents-find … id)` is `'running` before calling `(next)`, and returns the downstream list with `(jobj [kind "turn"])` in front when it was. The `workspace/session-stop` listener calls `(agent-cancel! agent cause-user)` when the agent of `sessionId` is running. Both payloads are read with `jref`.
13. Fused dispatch (`dispatch.ts`). The payload is `fields` with `'agent` and `'session` set last. `agent-emit` resolves the callbacks with `scoped-callbacks` and calls them through `invoke-contained`; a raise is logged at `warning` on `ctx` as `agent event "<name>" listener threw: <text>` and a failed returned task as `agent event "<name>" listener rejected: <text>`; later listeners still run and nothing propagates. `agent-serial` and `agent-waterfall` are `scoped-dispatch` in those modes and propagate failures. `<text>` is the exception message, or the `display` form of another value.

**Model selection** (R5 "Model", R; `agent/src/model-selection.ts`)

14. `agent-model-current`: let `recorded` be the state's `pending`, else its `lastUsed`. A recorded selection is returned. Otherwise, when the options have non-empty `provider` and `model`, the result is `{provider, model, reasoningEffort?}` built from the options at call time. Otherwise `#f`.
15. `agent-model-select!` does nothing when `(same-model-selection? recorded selection)`; otherwise it appends `model/selection {provider, model, reasoningEffort?}`. A selection equal only to the options fallback is still recorded. No availability check.
16. `model-selection-apply`: on `model/selection`, set `pending` to the event data unless it equals the current `pending`. On `request/header`, let `used` be `{provider, model, reasoningEffort?}` from `header.config`, without the effort when `header.adapterDefaults.reasoningEffort` is `true`; set `lastUsed` to `used` and set `pending` to `null` when it equals `used`. Every other event, and every case in which nothing changed, returns the same state value (`eq?`).
17. `install-model-selection!` registers an `agent/pre-step` listener on `agent-ctx` with `#:prepend? #t`. It calls `(next)` and returns the decision unchanged when it is a reject, when the turn is cancelled, when the decision's messages are empty and (`step` is 1 or the offered `messages` were non-empty), when the session has no request header, or when the header's provider and model equal the payload's `modelSelection`. Otherwise it returns the decision with the notice appended to its messages. The notice is `(make-user-message #:content (list (text-block text)) #:source source)` with `text` `[model changed: assistant turns above this point were generated by <from>; the session continues with <to>]` and `source` `{kind: "model-selection", form: "notice", summary: (bound-context-summary "<from> → <to>")}` (the arrow is U+2192). A label is `<model>` when both routes have the same provider, else `<provider>/<model>`. An effort-only change adds nothing.

**Turn boundary and consumed work** (R5 R; `agent/src/projection.ts`, `consumed-work.ts`)

18. `turnBoundary` fold: `turn/start` sets `openTurnStartSeq` to the event seq and `lastTurn` to its `turn`; `turn/end` sets `openTurnStartSeq` to `null`; `step/start` sets `lastStepStartSeq` and `lastStepBoundary` `{kind: "start", seq}`; `step/end` sets `lastStepBoundary` `{kind: "end", seq}`.
19. `fold-consumed-work`: one pass with the sets `stepped` and `claimed` and the open turn number. `turn/start` records the open turn. `step/start` adds its turn to `stepped`. An `agent/inbox/spliced` that has `removedCount`: when its `outcome` is `"canceled"`, `dropped-unrun?` becomes true if `inserted` is empty (and stays true otherwise); else, when a turn is open, that turn is added to `claimed`. `turn/end` clears the open turn and, when the turn stepped, or was claimed and its reason kind is not `completed`, becomes the accounting end and resets `dropped-unrun?` to false.

**Inbox** (R5 "Inbox", Q; `agent-loop/src/inbox.ts`)

20. The inbox has no state of its own: every read is the `inbox` projection state of the agent's session.
21. Mutation `(mutate target start delete-count inserted discard?)`. Coordinates follow JavaScript `Array.prototype.splice`: truncate `start` toward zero, NaN becomes 0, a negative value counts from the end and stops at 0, a larger value stops at the length; truncate `delete-count`, NaN becomes 0, then limit it to between 0 and `length - start`. A mutation that removes nothing and inserts nothing appends nothing and returns `'()`. Otherwise: the candidate list together with the other list must not contain two messages with one `id`, else raise `message "<id>" is already pending` with the state unchanged; append `agent/inbox/spliced` (Data) with the normalised `start`; when `discard?`, emit `agent/inbox/discarded` for each removed message in order; emit `agent/inbox/inserted` for each message of the committed event's `inserted`; return the removed messages.
22. `agent-inbox-splice!` is the mutation with `discard?` true. `agent-inbox-replace!` and `agent-inbox-remove!` look the id up in next-turn first, then next-step, return `#f` when absent, and otherwise splice one element at that index. `agent-inbox-clear!` splices all of next-step, then all of next-turn.
23. The claim `(claim target turn)`, private to the driver: remove all of next-step, then, when `target` is `"next-turn"`, the first next-turn message, both with `discard?` false; then emit `agent/inbox/claimed {message, turn}` for each removed message in that order. The result is the removed messages in that order.
24. `inbox-apply` validates every `agent/inbox/spliced`: `start` a safe integer between 0 and the list length, `removedCount` (0 when absent) a safe integer at least 0, `start + removedCount` at most the length, and no repeated id across both lists afterwards. A violation raises `exn:fail:agent` `invalid persisted inbox splice at session seq <seq>` whose cause is an `exn:fail` with message `invalid inbox splice` or the duplicate message of rule 21. Other events return the same state.

**Phases, sending, cancelling** (R5 A to E; `agent-loop/src/agent.ts:53-287`)

25. The driver's phase is one of idle `{last-turn}`, maintenance `{source, last-turn, wake-requested?}` and running `{source, turn, step, wake-requested?}`, where `source` is a cancel source. `agent-status` is `'running` only in the running phase. Setting a phase stores it and then emits `agent/status` when the status changed. The initial phase is idle with `last-turn` from `agents-turn-boundary-of`, so turn numbers continue across resume and fork. The driver keeps an *activity event*, ready when the current driver run or maintenance job has finished; it is ready initially.
26. `agent-send!`: let `waking-after-abort?` be true when `wakeup?`, the phase is not idle and its source is cancelled; this is decided before the insertion. Insert with `(mutate (if waking-after-abort? "next-turn" target) +inf.0 0 (list message) #t)`; a raise leaves everything else undone. Then, when `wakeup?`, wake the driver (rule 27) with that flag.
27. Waking. When the lifetime event is ready: nothing. When the phase is not idle: if its recorded cause is not of kind `disposed` and (the phase is maintenance or the flag is set), set `wake-requested?`; nothing else. When idle: install a fresh activity event; set the running phase `{new source, turn: last-turn, step: 0, wake-requested?: #f}`, which emits `agent/status`; then, inside `(agents-with-initiator agents agent …)`, perform the *opening* of the first turn in the calling task (rule 33 steps 1 to 4, the cancellation check of step 5, and steps 1 and 2 of rule 38) and spawn the *driver task* for the remainder with `current-custodian` set to the agent's custodian (rule 57). The boundary returns the driver task, so the initiator run lasts as long as the driver. A value raised during the opening is not raised from `agent-send!`: it is handed to the driver task, which continues as if the raise had happened at that point of rule 33. When `agent-send!` returns on an idle agent the log therefore holds the insert splice, `turn/start` and the claim splice, and `agent-status` is `'running`. Nothing else of the turn runs in the caller's task; tool-set resolution is the first thing the driver task does.
28. `agent-cancel!`: unless `keep-inbox?`, `agent-inbox-clear!`. Then, also when that raised: if the phase is not idle, clear `wake-requested?` unless `keep-inbox?`, and `(cancel! source cause)`. A failure of the clear propagates after the cancel. The first cause of a turn wins. Each turn has its own source, so a cancel never reaches a later turn. Cancelling an idle agent still clears the inbox.
29. The *recorded cause* of a source is `#f` when it is not cancelled and otherwise a fresh jobject copied from its reason: `{kind}` for `user`, `parent` and `disposed`, `{kind: "hook", reason}` for `hook`. This copy is what `turn/end` records.
30. `agent-run-maintenance` raises `agent "<id>" already has active work` unless the phase is idle. It sets the maintenance phase (status stays `'idle`, no event), installs a fresh activity event, and calls `(job cancel-evt)` in the calling task. When the job returns or raises: set the idle phase with the same `last-turn`; if the recorded cause is not of kind `disposed`, `wake-requested?` is set and the inbox is not empty, wake the driver; make the activity event ready. The job's values or raised value pass through unchanged.
31. `agent-when-idle` waits for the activity event, then repeats while the driver's activity event is a different one than it waited for. It returns at once when nothing is active and never raises for a turn failure or a cancellation.
32. The driver task runs turns (rules 33 to 37) while a turn returns true. It catches every raised value, including a break (rule 37); failures were already reported and cancellation is silent. Then, in every case: read `turn` and `wake-requested?` from the running phase, set the idle phase `{last-turn: turn}` (which emits `agent/status`), and wake the driver again when `wake-requested?` was set and the inbox is not empty. Finally it makes its activity event ready.

**Turn** (R5 F; `agent.ts:333-439`)

33. Opening and step loop. In order: (1) outside the running phase raise `agent "<id>": turn without driver reservation` through rule 56's report; (2) check cancellation, which ends the turn before `turn/start`; (3) `turn` is the phase's turn plus 1; append `turn/start {turn}`; if the append raises, emit `agent/error` and re-raise, with no `turn/end`; (4) store `turn` in the phase; `ends` is unset and `target` is `"next-turn"`; (5) loop: check cancellation; `step` is the phase's step plus 1; run the pre-step (rule 38), whose claim and model-selection read are the last parts of the opening; (6) a reject decision sets `ends` to `{kind: "blocked"}` and ends the turn with result false; (7) with the step's tool set held until the end of this iteration: if `ends` is set and the decision has no messages, leave the loop; if the phase's step is 0 and the decision has no messages, set `ends` to `{kind: "completed"}` and end the turn with result false; check cancellation; append `step/start {turn, step}` and store `step` in the phase; run the step under the recovery observer (rules 39 to 55); (8) dispose the tool set; check cancellation; when `ends` is set and the next-step list is empty, dispatch `agent/turn-stopping {turn, cancel}` and check cancellation; when `ends` is set and the next-step list is (still) empty, leave the loop; otherwise set `target` to `"next-step"` and continue at (5).
34. Step result. A step returns `#f` (tool results owe the model another request), `{kind: "completed"}` or `{kind: "max-tokens"}`. After a step that returned normally, `ends` becomes the step's result unless `ends` is already `{kind: "max-tokens"}`, which is kept for the rest of the turn.
35. Closing. Any value raised between step (4) and the end of the loop is handled as follows: if the turn's recorded cause is set, `ends` becomes `{kind: "aborted", reason: <recorded cause>}` and the value is re-raised without `agent/error`; otherwise `ends` becomes `{kind: "error", error: <failure of rule 56>}`, `agent/error` is emitted and the value is re-raised. In every case, including the two early ends of rule 33, `turn/end {turn, reason: ends}` is appended last; if that append raises, emit `agent/error` and raise that failure. The decision is made by the state of the cancel event, not by the kind of raised value: any failure observed after the turn was cancelled is recorded as `aborted`.
36. Another turn. After a turn that left the loop normally: when the inbox is empty the turn's result is false; otherwise the phase gets a new cancel source, `wake-requested?` false and step 0, and the result is true. The turns that end early (`blocked`, the empty first batch) or by a raise (`aborted`, `error`) end the driver run even when prompts are queued; they stay in the inbox until the next waking send.
37. A break delivered to the driver task is a cancellation: the handler first does `(cancel! source cause-disposed)`, which has no effect when a cause is already recorded, and then applies rules 55 and 35 as for any raised value. The closing appends (recovery results, `step/end`, `turn/end`) run with breaks disabled. The break is not re-raised out of the driver task.

Invariants that follow and that tests pin: `turn/start` precedes the claim; every opened turn has exactly one `turn/end` unless that append itself fails; every `step/start` has exactly one `step/end` with the same coordinates; a turn can close with zero steps; the first claim of a turn takes all next-step input plus exactly one next-turn message, so each queued prompt gets its own turn with strictly increasing numbers; the step's tool set is disposed after its tool batch settled, also on failure and when no step opens.

**Pre-step** (R5 G; `agent.ts:289-323`)

38. In order: (1) `claimed` is `(claim target turn)`; it is not undone by a later rejection, failure or cancellation, and claimed messages of a step that does not run are not logged as `user/message`; (2) `selection` is `agent-model-current`, or raise `agent "<id>" has no provider/model: set AgentOptions.provider and AgentOptions.model or record a model selection`; (3) `(tools-resolve tools #:agent agent #:model-selection selection #:cancel cancel)`; (4) `(system-prompt-assemble system-prompt actx)` where `actx` is `(assemble-context-for agent cancel)` extended with `'model-selection` and `'tool-set`; check cancellation; (5) dispatch `agent/pre-step {messages: claimed, turn, step, cancel, modelSelection: selection}`, whose innermost step computes `sections` with `render-context-sections` of the assembly, asks the runtime-context projection for a candidate (rule 44) and returns `(make-pre-step-enter (append claimed (list candidate)))`, or the claimed list alone when there is no candidate; check cancellation; (6) a reject decision disposes the tool set. A raise in steps 4 to 6 disposes the tool set and propagates. The selection of step 2 is used for the request and every retry of this step; a later `agent-model-select!` applies to the next step.

**Step: the attempt loop** (R5 H to N; `agent.ts:441-750`, `runtime-context.ts`, `assistant-stream.ts`)

39. Entering a step: check cancellation; `rendered` is `(render-prompt assembly)`, computed once per step; `first-attempt?` is true. Then repeat rules 40 to 52 until one of them returns or raises.
40. Request config (`agent.ts:619-659`). `persisted` is, when this loop agent has logged a request header, the config of `(session-request-header session)` without `reasoningEffort` if `adapterDefaults.reasoningEffort` is `true` and without `maxTokens` if `adapterDefaults.maxTokens` is `true`; otherwise `{maxTokens}` from the agent options when they have one, else `{}`. The seed is `persisted` without `provider`, `model` and `reasoningEffort`, in its key order, followed by the keys of the step's selection (`provider`, `model`, `reasoningEffort?`). Dispatch `agent/request {turn, step, cancel}` with the seed as innermost result; check cancellation. A proposal whose provider or model differs from the selection raises `agent "<id>": agent/request proposed "<p>/<m>" after step preparation fixed "<p0>/<m0>"; use agent.model.select() before step preparation`; one whose `reasoningEffort` differs (absent must stay absent) raises `agent "<id>": agent/request proposed reasoning effort "<e>" after step preparation fixed "<e0>"; use agent.model.select() before step preparation`, where an absent effort prints as `adapter default`. Then `(llm-prepare-call llm proposal #:cancel cancel)`: on success `config` is the prepared call's config; on an `exn:fail:llm` with code `NO_ADAPTER` there is no prepared call and `config` is the proposal; any other failure propagates. Check cancellation.
41. Fresh context: `current` is `(system-prompt-refresh-context system-prompt assembly actx)` with `actx` `(assemble-context-for agent cancel)` plus `'model-selection`; `context` is the runtime-context candidate for `(render-context-sections current)` (rule 44). Check cancellation. **From here to the end of rule 48 the driver performs no `await`, `yield-task`, `task-sleep` or `blocking`**, so no other task runs between the first commit of an attempt and the construction of its request. A cancellation during rule 40 therefore commits no system prompt and no user message: the step closes empty and the turn ends `aborted`.
42. System prompt reconciliation (`runtime-context.ts:74-122`). `starts-request-series?` is true on the first attempt when the decision has `starts-request-series?`. `in-history?` is true when the prepared call's `system-prompt-update` is `"in-history"`. `starts-series?` is true when `starts-request-series?`, or the driver's remembered surface generation differs from `(surface-state-content-generation (session-surface session))`, or both of these hold: the tools changed, and there is no prepared call or its `tool-update` is `#f`. "The tools changed" is false without a logged request header and otherwise `(not (header-equal? baseline (canonical-header <baseline with tools replaced by the assembly's tools>)))`. The `nodes` are the surface nodes of type `system/message`, in order, each with `text`: `""` for empty content, the text of a single text block, and no text for anything else. With no node: one append of `(make-system-message rendered)`, also when `rendered` is `""`. Otherwise `head` is the first node and `latest` the last node whose text is not `""`, else `head`. If not `in-history?`, or `rendered` is `""`, or (`starts-series?` and `latest`'s text differs from `rendered`): for each node after `head` whose text is not `""`, one replacement with `""`; then, if `head`'s text differs from `rendered`, one replacement of `head` with `rendered`. Else if `latest`'s text equals `rendered`: nothing. Else one append. A node without text counts as non-empty and never equals `rendered`. Each commit is `system/message {turn, step, message}`; an append has surface op `'append`; a replacement of node `seq` has surface op `(surface-replace seq seq)` and sources `(list seq)`, and its message is `(make-system-message text)`.
43. User admission. On the first attempt, for each message of the decision in order: a message whose source kind is `runtime-context` is a placeholder, replaced by `context` at most once and dropped when there is no `context`; any other message is appended as `user/message` with surface op `'append`. Then, on every attempt, if `context` exists and was not admitted, append it. `first-attempt?` becomes false. Retries repeat neither prompt assembly, `agent/pre-step` nor the user batch.
44. Runtime-context projection (`runtime-context.ts:125-181`). State `retained`: *never* (no owned snapshot ever existed), *none* (one existed, none is on the surface), or `{seq, sections}`. An owned message is a `user/message` whose source kind is `runtime-context`; its `sections` are `source.sections` when `source.form` is `"snapshot"` and unknown otherwise. Restore at construction: scan the events newest first; the first owned message makes *never* into *none*; the first owned message whose seq is a surface node becomes `retained` and ends the scan. Follow, through a `session/event` listener on the agent context that ignores other sessions: an owned `user/message` sets `retained` to `{seq, sections}`; a replacement surface event whose sources include the retained seq sets *none*. Candidate for `sections`: nothing when `retained` is *never* and `sections` is empty; nothing when the retained sections are known and equal `sections` (same names and texts in the same order); otherwise `(make-user-message #:content (list (text-block text)) #:source (jobj [kind "runtime-context"] [form "snapshot"] [sections sections]))`. With empty `sections`, `text` is `<system-reminder>\nCurrent runtime context: none. Earlier runtime-context snapshots no longer apply.\n</system-reminder>`. Otherwise it is `<system-reminder>\n<intro>\n\n<body>\n</system-reminder>`, where `<intro>` is `The following information describes your current session:` when `retained` is *never* and otherwise `The following information describes your current session. It replaces earlier versions of this context, including any retained in conversation summaries.`, and `<body>` is the section texts joined with a blank line, with every match of `#px"(?i:</system-reminder\\s*>)"` rewritten to `<\` followed by the match without its first character. The recorded `sections` are not escaped. A candidate never changes `retained`; only the committed event does.
45. Header (`agent.ts:662-700`). `generation` is the current content generation, read after the commits of rules 42 and 43. `header` is `(canonical-header {config, adapterDefaults: <the prepared call's, when there is one>, tools: <the assembly's tools, when not empty>})`. `baseline` is `(session-request-header session)`. `starts-series?` is `starts-request-series?` or (remembered generation differs from `generation`). If this loop agent has not logged a header: append `request/header {header, reason, startsSeries?}` with `reason` `"resume"` when `baseline` exists and `"initial"` otherwise, `startsSeries: true` only when `starts-series?`; remember its seq as `header-seq` and mark the header as logged. Else if there is no `baseline` or `(header-equal? baseline header)` is false: append the same with `reason` `"change"` and remember its seq. Else if `starts-series?`: append `request/header {header, reason: "series"}`, with no `header-seq`. Else nothing. "Has logged a header" is per loop agent instance, so a resumed agent seeds its controls from the options until it logs its own header.
46. Tool changes. When `baseline` and `header-seq` both exist: `additions` are `(tool-addition-block name)` for each tool of the assembly whose name is not in the baseline, `removals` are `(tool-removal-block name)` for each baseline tool whose name is not in the assembly, both in list order. When either is non-empty, append `developer/message {turn, step, message, headerSeq?}` with surface op `'append`, `message` `(make-message (jobj [source (jobj [kind "tool-registry"])] [content (append additions removals)] [role "developer"]))`, and `headerSeq` only when there is an addition. The message keys are therefore `source`, `content`, `role`, `id`, the order dsh writes here (`agent.ts:708` passes `source` before `content`; see `snapshots/session/dynamic-tool-updates/session.v4.jsonl`); `make-developer-message` would write `content` first. A schema change under an unchanged name gives a `change` header and no `developer/message`. Then remember `generation` as the surface generation.
47. Context. `now` is `{provider, model, contextWindow?, systemPromptUpdate?}` from the config and the prepared call. When `(session-request-context session)` is absent or differs in one of the four fields, append `request/context now`. Check cancellation.
48. The request is `(mark-agent-loop-request (llm-request-with-call-config base header-config))` where `base` is `(make-llm-request #:provider … #:model … #:messages (session-derive-messages session) #:tool-history (session-tool-history session) #:tools <the header's tools, or #f when it has none> #:session-id id #:cancel cancel)`. It has no system field: the prompt travels as system messages. Every request can be rebuilt from the session log alone, from the latest `request/header`, the surface fold and the tool-history fold.
49. Streaming. Create the attempt: its number is the next value of a per-agent counter from 1, its id `<sessionId>:<number>`, with an empty accumulator and an empty assembly. Obtain the stream with `(prepared-call-stream prepared request)`, or `(llm-stream llm request)` without a prepared call; check cancellation; emit the `start` frame; from now the attempt is *started*. Pull chunks until `eof`; for each: check cancellation first (a chunk that arrives after the cancellation is not recorded), then `time` is `((current-session-time))`, push `(time, chunk)` into the accumulator and the chunk into the assembly, and emit a `chunk` frame. After `eof` check cancellation. The stream is closed on every exit (`call-with-chunk-stream`).
50. A value raised in rule 49. Not started: it propagates; there is no frame and no durable attempt. Started and the turn is cancelled: when `(assembly-interrupted-blocks a)` is not empty, settle `assistant/message {turn, step, message, interrupted: true, usage?, stream}` with surface op `'append`, the message made from those blocks with the request's provider and model and the assembly's replay state; otherwise settle `assistant/attempt {turn, step, stream}`. Started and not cancelled: settle `assistant/attempt`. Then the original value is re-raised. If the settlement raises, raise `exn:fail:agent:aggregate` `Assistant stream failed and its durable settlement was rejected` with both values as `errors` and the original as `cause`.
51. Terminal failure. `finish` is `(assembly-finish a)`, which is `{kind: "stop"}` for a stream without a finish chunk. When its kind is `error` or `aborted`: settle `assistant/attempt`; dispatch `agent/request-error {turn, step, provider, failure, retryPolicy?, cancel}` with `#f` as innermost result; check cancellation; when the action is not a retry (`request-error-retry?`), raise `(llm-failure->exn failure)`; otherwise go back to rule 40 with a new attempt in the same step. The failed attempt stays in the log; the final message embeds only its own stream.
52. Success. The message is `(make-assistant-message #:content (assembly-blocks a) #:provider <request provider> #:model <request model> #:replay-state <the assembly's, when it has one>)`. Settle `assistant/message {turn, step, message, usage?, stream}` with surface op `'append`; `usage` is the last usage chunk's. Every successful provider call appends an `assistant/message`, also with empty content and also for `max-tokens`. Then: finish kind `max-tokens` returns `{kind: "max-tokens"}`; a message without `tool-call` blocks returns `{kind: "completed"}`; otherwise rule 54. Tool dispatch depends on the tool-call blocks of the message, not on the finish kind.
53. Settlement and frames. To settle is to run the append and then emit the `end` frame with `{kind: "committed", eventType, seq}`; if the append raises, emit the `end` frame with `{kind: "abandoned"}` and re-raise. `stream` is `(accumulator-snapshot acc)`. Any value raised after the start of an attempt that has not ended emits the `abandoned` end and propagates. Each frame takes the next revision. The `index` of a chunk frame counts chunk frames of the attempt from 0; the `index` of the end frame is their number. There is exactly one `end` frame per started attempt and exactly one durable settlement per started attempt, except when the settling append itself fails.
54. Tool dispatch (`agent.ts:592-610`). `(tools-execute tools (make-tool-batch-input #:calls <the tool-call blocks in model order> #:cancel cancel #:agent agent #:tool-set <the step's> #:log (tool-batch-log session turn step) #:max-parallel-tool-calls (agent-loop-max-parallel-tool-calls loop)))`. The limit is read before every batch. On return, each additional context is appended to next-step with a public splice at the end of the list, and the step returns `{kind: "completed"}` when the batch concluded and `#f` otherwise. On `exn:fail:tool-batch`, the partial result's additional contexts are appended the same way and the batch's `cause` is raised. The executor owns `tool/call` and `tool/result` logging. A batch that returned under a cancelled turn is followed by the cancellation check of rule 33 (8).
55. Failed-step recovery (`agent.ts:369-395`). For each step the driver makes a `tool-call-recovery` of `dsh-session/repair` and registers a `session/event` listener on the agent context that feeds it the events of the agent's own session. When the step raises: append each of `(tool-call-recovery-results r)` as a `tool/result` input with surface op `'append` and the result's sources when it has them, then re-raise the step's value; if such an append raises, raise `exn:fail:agent:aggregate` `Step failed and its pending tool results could not be recorded` with both values as `errors` and the step's value as `cause`. In every case the listener is removed and `step/end {turn, step}` is appended, after the recovery results. A failed `step/start` append writes no `step/end`.
56. Failures. `agent/error` carries `turn` and `step` from the running phase (`last-turn` and 0 outside it) and the raised value. The `error` of a `turn/end` is: for an `exn:fail:llm`, its failure unchanged; otherwise `{message, code}` where `code` is the code of a tool activation error (`TOOL_ACTIVATION_FAILED`, recognised through `harness-error-info` by the name `ToolActivationError`) and `UNKNOWN` for everything else, and `message` is `(error-chain v)`; for an `exn:fail:agent:aggregate` the message is `<message> [<chain of each member, joined with "; ">]: <chain of the cause>`. The reasons the loop writes are `{kind: "completed"}`, `{kind: "max-tokens"}`, `{kind: "blocked"}`, `{kind: "aborted", reason}` and `{kind: "error", error}`.

**Lifecycle** (R5 S to V; `agent-loop/src/index.ts`)

57. Agent context and custodian. Constructing a loop agent calls `(create-scope loop-ctx agent)` with the loop plugin's own context; `agent-ctx` is the scope's context. No service realm is isolated: the agent context reads every service as the loop plugin does, and what one agent sees differently from another comes only from scope filtering and scoped registry layers. A registration through `agent-ctx` belongs to the scope's fiber, is visible only to this agent and its descendants, and is removed when the scope is disposed; afterwards a registration raises `exn:fail:cordis:inactive`. The *agent's custodian* is `(context-custodian (agent-ctx agent))`, read each time it is needed. The driver task is spawned with it as `current-custodian`, so the tasks of the tool batch, the model call's stream custodian and anything a tool starts for this agent belong to the agent and not to whichever plugin sent the message. Teardown reaches the scope's disposal, which shuts that custodian down, only after the driver has finished (rule 60). Construction also creates the model reader, the inbox, the runtime-context projection (which registers its listener) and remembers the current surface generation.
58. Initialization, shared by every creation path, given an unpublished session, an optional stored session with its stored count, the agent options, the source, the setup and the caller's cancel event. In order: (1) create the lifetime cancel source; while creation is in progress it is cancelled when the caller's event becomes ready, with the caller's reason when that is an exception and otherwise an `exn:fail:agent` `agent "<id>" creation aborted` with the reason as cause; it is cancelled with `agent loop is not active` when the factory deactivates; (2) define the memoised teardown of rule 60 and `dispose`, which is the teardown followed by the release of the two effects of step 5, and track `dispose` in the factory; (3) validate: `maxTokens`, when present, must be a positive safe integer, else `exn:fail:contract` `agent maxTokens must be a positive safe integer`; the owner's fiber must be active; the factory must be active, else `agent loop is not active`; the caller's event must not be ready; (4) read `last-turn` and make the two projection readers; (5) on the owner's context register the effect `agentLoop.lifecycle(<id>)`: construct the agent (rule 57) and, when the loop's fiber is active, register on the loop's context the effect `agentLoop.scope(<id>)` whose inverses are collected as the scope's raw disposal and then the teardown, so that on the loop's unload the teardown runs first; the owner effect's inverse cancels the lifetime source with `agent "<id>" setup aborted: owner disposed during setup`, waits for the teardown and releases the scope effect; a raise in steps 3 to 5 untracks, closes the stored session ignoring a close failure, and propagates; (6) run the rest as `(agent-run-maintenance agent …)`, raising the lifetime reason between any two of these steps once the lifetime event is ready: store the events the session holds beyond the stored count; `(sessions-enter (agent-ctx agent) session)` then `(sessions-announce … session)`; call `setup` with the agent context and the agent and wait for it or for the lifetime event; call the commit thunk when one was returned; `(agents-enter! agents agent)` then `(agents-announce agents agent source #:cancel lifetime-evt)`; mark the agent ready, stop following the caller's event, and return the handle `(agent-handle agent dispose)`. A raise inside the maintenance job first does `(agent-cancel! agent cause-disposed #:keep-inbox? #t)`, so queued input is neither released into a turn nor discarded. A *publication event* becomes ready when the job ends either way. (7) If the job raised: wait for `dispose`, ignoring its failure, and re-raise the original value. Because step 6 is a maintenance job, input sent during setup or by `agent/created` listeners is queued, the wake is latched, and the driver starts only after the last listener.
59. Creation paths. `agent-loop-create`: `(sessions-prepare sessions id #:meta meta)`; when `sessionPersistence` is mounted, `persistence-create` with the session header gives the stored session with stored count 0; then rule 58 with source `'startup`; the result is the agent. `agent-factory-create`: the same with `seed`, `meta` and `inherited-event-count` from the options, `persistence-create` raced against the caller's event (a stored session that arrives after cancellation is closed), the whole creation tracked by the factory so that its teardown waits for it; the result is the handle. The prepared session is released when the creation ends.
60. Teardown of one agent, memoised so that the handle holder, the owner's unload and the loop's unload all wait for the same completion. In order: (1) cancel the lifetime source with `agent "<id>" lifecycle disposed`, or `agent loop is not active` when the factory is deactivating; from here rule 27 starts no driver; (2) stop following the caller's and the factory's events; (3) wait for the publication event when initialization is in progress; (4) `(agent-cancel! agent cause-disposed #:keep-inbox? <not ready>)`: a published agent's pending inbox is cancelled durably, an unpublished one keeps it; a failure here is collected; (5) `agent-when-idle`: the active turn records `turn/end` with `{kind: "aborted", reason: {kind: "disposed"}}` and the driver ends; (6) dispose the scope and wait until its fiber has no transition in flight; (7) `stored-session-close!` when there is a stored session; (8) the agent detach (emits `agent/disposed`), then the session detach (emits `session/disposed`), then untrack; (9) one collected failure is re-raised as itself, several as `exn:fail:agent:aggregate` `agent "<id>" disposal failed`. Steps 5 to 8 run even when step 4 failed.
61. Factory teardown, run by the effect that the plugin body registers first: stop accepting creations, cancel the factory source with `agent loop is not active`, then wait for every live agent's `dispose` and every tracked creation, all of them even when some fail; one failure is re-raised as itself, several as `exn:fail:agent:aggregate` `agent loop disposal failed`. The two projection handles stay readable after their registrations are released, because teardown reads the inbox and the model selection.
62. Resume (`index.ts:764-835`). Without `sessionPersistence` raise `cannot resume: session persistence is not configured (load a dsh-session-persistence backend)`. Otherwise, with a cancel event that is ready when the caller's event is, when the owner's fiber starts unloading (an effect `agentLoop.resume-load(<id>)` on the owner's context) or when the factory deactivates: `persistence-open` in mode `'write`, which excludes a concurrent resume of the same id (a stored session that arrives after cancellation is closed); `(stored-session-read stored 0 #f)`; `closers` is `(interrupted-turn-closers events)` and is appended to the stored session when not empty; `(sessions-prepare sessions id #:seed (append events closers) #:meta (stored-session-header stored) #:inherited-event-count (stored-session-inherited-event-count stored) #:event-state <the read's state>)`; the *stored count* handed to rule 58, the number of events the stored session already holds, is the length of events plus closers; store whatever the session constructor added beyond that count; release the owner-unload effect; require the owner's fiber and the factory to be active; then rule 58 with source `'resume`. A failure before rule 58 takes over closes the stored session. Resume keeps the pending inbox and the turn numbering, and its first request header has reason `"resume"` when the log already has a header.
63. Config-declared agents (`index.ts:339-454`), started by the plugin body without waiting, each tracked by the factory. For an entry `{id, sessionId, cwd, resumeSessionId, …options}` with meta `{cwd}` when `cwd` is given. Without a non-empty `resumeSessionId`: the session id is `sessionId`, else `<id>-session-<uuid>` with a fresh lowercase version 4 UUID; without an explicit `sessionId`, or without `sessionPersistence`, call `agent-loop-create`; with both, wait while the id is still in either registry (listening to `agent/disposed` and `session/disposed`, and giving up when the factory deactivates), then resume it with a setup that applies the configured route, and on `exn:fail:persistence-not-found` only, fall back to `agent-loop-create`. With `resumeSessionId`: an effect `agentLoop.resume(<id>)` that waits for `sessionPersistence` through `ctx-inject` and then resumes with the same setup. Applying the configured route does nothing unless both `provider` and `model` are configured; it builds the selection, keeps the session's current effort when the configured effort is absent and the current selection has the same route with an explicit effort, and calls `agent-model-select!`. A start failure while the factory is active is logged at `warning` as `agent "<configId>": config-driven <restore|resume> of "<sessionId>" failed: <error-chain>` and emitted as `agent-loop/config-start-failed`; after teardown began it is dropped.
64. The loop plugin body, in order: read `configuredAgentIdentities`; apply launcher identities (for every configured agent whose `id` has an identity, remove both identity keys and set `resumeSessionId` to the identity's id when `resume` is true, else `sessionId`); validate, raising `agent "<id>": sessionId and resumeSessionId are mutually exclusive` when `sessionId` is set and `resumeSessionId` is non-empty, and `agents "<first>" and "<id>" use duplicate exact session identity "<x>"` for a repeated `sessionId` or `resumeSessionId` value; register the effect `agentLoop.transactions()` whose inverse is rule 61; register `agent/inbox/spliced-type` and `model/selection-type` with `sessions-register-event-type!`; register `model-selection-projection` and wait; register `inbox-projection` and wait; register the effect `agentLoop.setFactory()` that calls `agents-set-factory!`; register the prompt variables `provider` and `model` with `system-prompt-variable!`, each returning the assemble context's `'model-selection` field of that name, else the field of that name in the options of its `'agent`, else `#f`; `provide-agent-loop`; start the configured agents. The factory is published only after both projections exist.
65. `maxParallelToolCalls` is validated at load and on every live update: `0` and `1.5` are rejected with the validation error of the schema; a config without the key reads as `10`. A config edit changes the value the next batch reads without remounting the loop.

**Default model** (`agent-default-model/src/index.ts`)

66. `agent-default-model-current-selection` reads the three config fields at call time and returns a new `{provider, model, reasoningEffort?}`, the effort omitted when unset.
67. `agent-default-model-save-selection!` does nothing when the plugin's context has no loader entry or `configEditor` is not mounted. Otherwise it calls `(config-editor-edit! editor ctx (lambda (_) config))` with `config` `{provider, model, reasoningEffort?}`, so that omitting the effort removes it from the profile row. Saves run one after another in submission order; a failed save raises for its own caller and does not block later saves. The service does not check catalog membership.

**In-memory projections** (`session-projection/src/index.ts:403-441`, the parts this provider keeps)

68. `projection-register!`: a `state-version` that is not an exact non-negative integer raises `session projection "<key>" stateVersion must be a non-negative integer, got <v>`. Registrants of one key share a unit with a reference count; a second registrant with another version raises `session projection key "<key>" is already registered at stateVersion <a>; refusing to share it with stateVersion <b>`, and one whose `summary?` differs raises `session projection key "<key>" is already registered with summary=<a>; refusing to share it with summary=<b>` (keys printed as JSON strings, booleans as `true` and `false`). The registration is one effect on `ctx` labelled `sessionProjections.register()`; its inverse decrements the count. The handle keeps its unit, so it stays readable after release.
69. `projection-state`: each unit has a weak `eq?` table from session to a cell `(state, next seq)`. A missing cell starts from `((projection-definition-init d) <header jobject> <inherited event count>)` at seq 0. A read folds `apply` over the session's events from the cell's seq to `(session-seq session)`, stores the cell and returns the state. A fold that raises leaves the cell where it was and propagates. Folding on read gives the states dsh's eager drive gives, because `apply` is pure and every read sees the whole log. The provider has no change feed, snapshot, checkpoint or wire notification.

**Testing support**

70. `mount-agent-loop-test-dependencies` mounts with `ctx-plugin` and waits (`fiber-await`) for each, in this order: `@deepseek-ai/dsh-llm`, `@deepseek-ai/dsh-session`, the projections plugin, `@deepseek-ai/dsh-system-prompt` with `config`, `@deepseek-ai/dsh-tools`, the executor plugin, `@deepseek-ai/dsh-agent`. It mounts neither the loop nor an adapter. `mount-agent-loop-test-harness` mounts `@deepseek-ai/dsh-agent-loop` with `config` and waits.
71. The scripted model (`packages/core/agent-loop/tests/mock-adapter.ts`). A script is a list of entries: a list of chunks, a procedure from the `llm-request` to a list of chunks, `'hang`, `(hang-after chunks)` or `(hang-slow evt)`. Each `adapter-stream` call records the request and takes the next entry at call time; an empty script raises `exn:fail` `MockAdapter: script exhausted` from the first pull. A chunk list is emitted in order, raising `exn:fail` `aborted` before a chunk when the request's cancel event is ready. `'hang` is `(hang-after (list (block-start-chunk 0 "text") (text-delta-chunk 0 "partial")))`. `hang-after` emits its chunks, waits for the cancel event and raises `aborted`. `(hang-slow evt)` emits the two chunks of `'hang`, waits for the cancel event, then waits for `evt`, then raises `aborted`; it replaces the 50 ms timer of the TypeScript `'hang-slow`. `adapter-resolve-model` returns `{provider, id, name}` with `reasoning`, `defaultMaxTokens`, `systemPromptUpdate` and `toolUpdate` when given. `text-response`: `block-start {0, "text"}`, one `text-delta` per character, `block-end` with the whole text, `usage {inputTokens: 10, outputTokens: <UTF-16 length>}`, `finish {kind: "stop"}`. `max-tokens-response`: the same with `finish {kind: "max-tokens"}`. `tool-call-response`: when `text` is non-empty a text block at index 0 with one delta; then at the next index `block-start` of type `tool-call`, a `tool-call-delta` with `id`, `name` and the first 5 UTF-16 units of the JSON text of `arguments`, a second without `name` carrying the rest, `block-end` with the complete block, `usage {inputTokens: 10, outputTokens: 5}`, `finish {kind: "tool-calls"}`.
72. `make-stub-agent` returns an agent whose status is `'idle`, whose send, cancel and maintenance operations raise `exn:fail:unsupported`, and whose inbox, when `inbox?`, is two in-memory lists with the coordinate rules of rule 21 and no events; without `inbox?` the generic fallbacks apply. `loop-agent-claim!` calls rule 23 on a loop agent.

**Acceptance sequences**

Both run on a root context with rule 70's plugins, the loop with `{agents: []}`, and an adapter registered for provider `mock`. The agent is `(agent-loop-create loop "s1" (jobj [provider "mock"] [model "mock-model"]))`. The system prompt config is the default, so the rendered prompt is `You are an AI agent powered by DeepSeek Harness.`. No prompt context is registered, so there is no runtime-context message. The adapter resolves every model to `{provider, id, name}`, so the request has no adapter defaults and no context window. Lines are the events as written with `session-event->jvalue`, without `seq` and `time`, with every embedded time 0 and with message ids replaced by `{{message:N}}` in order of first appearance. A test compares the JSON text of each line.

73. Text-only turn. Script: one reply `(mock-text "PONG")` of `dsh-llm/testing/mock`. Input: `(agent-followup! agent (make-user-message #:content (list (text-block "Reply PONG"))))`, then `agent-when-idle`.

```text
{"type":"agent/inbox/spliced","data":{"target":"next-turn","start":0,"inserted":[{"content":[{"type":"text","text":"Reply PONG"}],"source":{"kind":"user"},"role":"user","id":"{{message:1}}"}]}}
{"type":"turn/start","data":{"turn":1}}
{"type":"agent/inbox/spliced","data":{"target":"next-turn","start":0,"removedCount":1,"inserted":[]}}
{"type":"step/start","data":{"turn":1,"step":1}}
{"type":"system/message","data":{"turn":1,"step":1,"message":{"role":"system","content":[{"type":"text","text":"You are an AI agent powered by DeepSeek Harness."}],"source":{"kind":"system-prompt"},"id":"{{message:2}}"}},"surfaceOp":"append"}
{"type":"user/message","data":{"content":[{"type":"text","text":"Reply PONG"}],"source":{"kind":"user"},"role":"user","id":"{{message:1}}"},"surfaceOp":"append"}
{"type":"request/header","data":{"header":{"config":{"provider":"mock","model":"mock-model"}},"reason":"initial"}}
{"type":"request/context","data":{"provider":"mock","model":"mock-model"}}
{"type":"assistant/message","data":{"turn":1,"step":1,"message":{"role":"assistant","content":[{"type":"text","text":"PONG"}],"source":{"kind":"model","provider":"mock","model":"mock-model"},"id":"{{message:3}}"},"usage":{"inputTokens":0,"outputTokens":0},"stream":[{"type":"chunk","time":0,"chunk":{"type":"block-start","index":0,"blockType":"text"}},{"type":"text-chunks","time0":0,"index":0,"dt":[],"texts":["PONG"]},{"type":"chunk","time":0,"chunk":{"type":"block-end","index":0,"block":{"type":"text","text":"PONG"}}},{"type":"chunk","time":0,"chunk":{"type":"usage","usage":{"inputTokens":0,"outputTokens":0}}},{"type":"chunk","time":0,"chunk":{"type":"finish","reason":{"kind":"stop"}}}]},"surfaceOp":"append"}
{"type":"step/end","data":{"turn":1,"step":1}}
{"type":"turn/end","data":{"turn":1,"reason":{"kind":"completed"}}}
```

Live events at their positions: `agent/inbox/inserted` after line 1; `agent/status` running before line 2; `agent/inbox/claimed {turn: 1}` after line 3, at which point `agent-followup!` returns; `agent/pre-step {messages: [the prompt], turn: 1, step: 1}` before line 4; `agent/request` between lines 4 and 5; the `start` frame (revision 1), five `chunk` frames (indexes 0 to 4, revisions 2 to 6) between lines 8 and 9; the `end` frame (revision 7, index 5, committed, `assistant/message`, seq 8) after line 9; `agent/turn-stopping {turn: 1}` between lines 10 and 11; `agent/status` idle after line 11.

74. One-tool turn. One global tool `echo`, a content tool of the tool testkit: description `Echo text.`, one required string parameter `text`, result one text block with that text. Script: `(mock-reply (tool-call-block "call-1" "echo" "{\"text\":\"hi\"}"))`, then `(mock-text "DONE")`. Input: a followup with the text `Say hi`. The first three lines are those of rule 73 with the other text; then:

```text
{"type":"step/start","data":{"turn":1,"step":1}}
{"type":"system/message","data":{"turn":1,"step":1,"message":{"role":"system","content":[{"type":"text","text":"You are an AI agent powered by DeepSeek Harness."}],"source":{"kind":"system-prompt"},"id":"{{message:2}}"}},"surfaceOp":"append"}
{"type":"user/message","data":{"content":[{"type":"text","text":"Say hi"}],"source":{"kind":"user"},"role":"user","id":"{{message:1}}"},"surfaceOp":"append"}
{"type":"request/header","data":{"header":{"config":{"provider":"mock","model":"mock-model"},"tools":[{"name":"echo","description":"Echo text.","parameters":{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}}]},"reason":"initial"}}
{"type":"request/context","data":{"provider":"mock","model":"mock-model"}}
{"type":"assistant/message","data":{"turn":1,"step":1,"message":{"role":"assistant","content":[{"type":"tool-call","id":"call-1","name":"echo","arguments":"{\"text\":\"hi\"}"}],"source":{"kind":"model","provider":"mock","model":"mock-model"},"id":"{{message:3}}"},"usage":{"inputTokens":0,"outputTokens":0},"stream":[{"type":"chunk","time":0,"chunk":{"type":"block-start","index":0,"blockType":"tool-call"}},{"type":"tool-call-chunks","time0":0,"index":0,"dt":[],"id":"call-1","name":"echo","args":["{\"text\":\"hi\"}"]},{"type":"chunk","time":0,"chunk":{"type":"block-end","index":0,"block":{"type":"tool-call","id":"call-1","name":"echo","arguments":"{\"text\":\"hi\"}"}}},{"type":"chunk","time":0,"chunk":{"type":"usage","usage":{"inputTokens":0,"outputTokens":0}}},{"type":"chunk","time":0,"chunk":{"type":"finish","reason":{"kind":"tool-calls"}}}]},"surfaceOp":"append"}
{"type":"tool/call","data":{"turn":1,"step":1,"callId":"call-1","name":"echo","arguments":"{\"text\":\"hi\"}"}}
{"type":"tool/result","data":{"turn":1,"step":1,"message":{"role":"tool","source":{"kind":"tool","callId":"call-1"},"toolCallId":"call-1","content":[{"type":"text","text":"hi"}],"isError":false,"id":"{{message:4}}"}},"sourceEventSeqs":[9],"surfaceOp":"append"}
{"type":"step/end","data":{"turn":1,"step":1}}
{"type":"step/start","data":{"turn":1,"step":2}}
{"type":"assistant/message","data":{"turn":1,"step":2,"message":{"role":"assistant","content":[{"type":"text","text":"DONE"}],"source":{"kind":"model","provider":"mock","model":"mock-model"},"id":"{{message:5}}"},"usage":{"inputTokens":0,"outputTokens":0},"stream":[{"type":"chunk","time":0,"chunk":{"type":"block-start","index":0,"blockType":"text"}},{"type":"text-chunks","time0":0,"index":0,"dt":[],"texts":["DONE"]},{"type":"chunk","time":0,"chunk":{"type":"block-end","index":0,"block":{"type":"text","text":"DONE"}}},{"type":"chunk","time":0,"chunk":{"type":"usage","usage":{"inputTokens":0,"outputTokens":0}}},{"type":"chunk","time":0,"chunk":{"type":"finish","reason":{"kind":"stop"}}}]},"surfaceOp":"append"}
{"type":"step/end","data":{"turn":1,"step":2}}
{"type":"turn/end","data":{"turn":1,"reason":{"kind":"completed"}}}
```

The log has 16 events, seqs 0 to 15; `tool/call` is seq 9. The second step logs no system, user, header or context event because nothing changed. Its request's messages are the system message, the prompt, the first assistant message and the tool result, in that order. Live events: as in rule 73 for the first step, with `tools/pre-execute`, `tools/execute`, `tools/post-execute` and `tools/result` between the `tool/call` and `tool/result` lines; then a claim of an empty next-step list (no event), `agent/pre-step {messages: [], turn: 1, step: 2}`, `agent/request`, a second attempt with id `s1:2` whose frames continue the revision count, `agent/turn-stopping`, and `agent/status` idle.

## Racket design notes

- **A generic interface for the agent, flat procedures for its parts.** dsh has an `Agent` interface with two nested objects (`model`, `inbox`), one class and several test doubles. Here `gen:agent` has thirteen operations and everything else (`followup`, `steer`, `inject`, append, prepend, replace, remove, clear) is derived once from them, so a custom driver or a stub implements only primitives and cannot disagree with the loop about what `steer` means. The fallbacks carry the messages of dsh's `unsupportedInbox` and `unsupportedModel`.
- **The inbox is a durable projection, not an asynchronous channel.** The coordinator's brief suggested an asynchronous queue. `agent-send!` never waits, which is the asynchronous property that matters, but the inbox itself must be a pair of lists folded from `agent/inbox/spliced` events: its content has to survive resume and fork, be visible to cold readers, support replace and remove by message id, and be claimed synchronously at a step boundary before `agent-send!` returns. A channel has none of these properties. The driver is woken by a phase check and a latch (`wake-requested?`), as in dsh.
- **Cancellation is a cancel source with a recorded cause; a break is a backstop.** The brief suggested cancellation by break. Three dsh rules rule that out as the primary mechanism: the cause is a value that must reach `turn/end` and that the first caller fixes; a cancelled tool batch must let started calls finish and commit and must write an aborted-before-dispatch result for every other call (dsh-tools rule 46), which a break through `tools-execute` would cut short; and the loop observes cancellation only at stated points, with a window (rule 41) in which commits must not be interrupted. So `agent-cancel!` records the cause in the turn's cancel source (`dsh-llm/cancel`, re-exported by `dsh-tools/cancel`), every wait of the loop passes that event on (`tools-resolve`, the assemble context, `llm-prepare-call`, the request, the tool batch, every payload), and the loop checks it where dsh calls `throwIfAborted`. A break that does reach the driver task is turned into the same path with cause `disposed` (rule 37), so the log stays balanced.
- **The driver is a task with an inline opening.** A dsh `async` function runs synchronously up to its first `await`, and tests assert the log immediately after `steer()`. A spawned task does not run until the spawner waits. Rule 27 therefore names the part that runs in the caller (status, `turn/start`, the claim, the selection read) and spawns the rest. The split is stated as a rule so that two implementers agree on what the caller observes.
- **The agent's custodian is the scope fiber's custodian.** dsh has no counterpart. Spawning the driver under it (ADR 0004) keeps a turn alive when the plugin that sent the message unloads, and makes the agent's disposal the one place where its threads, ports and subprocesses are reclaimed.
- **The initiator is a parameter.** ADR 0003 forbids deciding ownership from ambient state. The initiator is not ownership: it is attribution ("which agent caused this work"), which dsh keeps in `AsyncLocalStorage`. A parameter carried by task parameterizations has the same propagation. The count of active runs replaces the promise bookkeeping of dsh; a run that returns a task is released when the task ends.
- **The owner context is an argument.** `agents-create` and `agent-loop-create` take the caller's context or handle first; `(use-context x)` is the owner. The Cordis tracing that recovers the caller's context from a service access, and the holder objects that stop re-tracing, have no counterpart.
- **Immutable requests.** `deepFreeze`, the weak set of frozen messages and the frozen seed config disappear: jobjects and `llm-request` values are immutable. The property "a consumer cannot mutate a request" holds by construction.
- **Structs and `match` for decisions; jobjects for what is logged or shown.** `PreStepDecision` is two structs. Cancel causes, model selections, turn-end reasons and stream frames stay jobjects because they are written to the log or sent to user interfaces in dsh key order.
- **A live attempt is a fold.** `AssistantStreamAttempt` wraps two mutable classes; here an attempt is an accumulator value, an assembly value and three counters, advanced per chunk.
- **Ports for later-wave services.** `sessionPersistence` and `configEditor` are generic interfaces owned here and implemented by their providers, the pattern of `dsh-llm/ports`. The `settings` port is the one of `dsh-llm/ports`, because the provider plugins of `dsh-llm` make the same call.
- **No macro is introduced.** The declarations use `define-session-event`, `define-event`, `define-service`, `define-jrecord` and `define-plugin` from the lower packages.
- **Racket-only additions**, for the coordinator's ADR list: the plugin `racket:session-projections` and `dsh-agent/projections`; the `'session` key in every `agent/*` payload (packages below this one, such as `dsh-llm/retry`, cannot call `agent-session`); `dsh-agent/testing`; the two ports defined here; the break rule 37; registration of the two session event declarations in the store's catalogue. No `x-racket` config key is introduced, and none changes what an unmodified dsh configuration writes.

## Work units

The package is too large for one implementer. Three units; units 1 and 2 can be built at the same time.

| Unit | Modules | Depends on |
|---|---|---|
| 1: vocabulary and registry | `types`, `session-events`, `events`, `agents` (with `private/registry`, `private/initiator`, `private/archive-admission`), `model-selection`, `consumed-work`, `ports`, `projections`, `default-model`; plugins `agent`, `agent-default-model`, `session-projections`; `private/testing-stub` (the stub agent) | lower packages |
| 2: driver | `private/inbox` (with `inbox-projection` and `inbox-apply`), `private/driver`, `private/step`, `private/system-prompt-projection`, `private/runtime-context`, `private/assistant-stream`; `private/testing-model` (the scripted model and its response builders) | the public modules of unit 1 as specified here (it can start against stubs) |
| 3: lifecycle and service | `loop`, `private/lifecycle`, `private/configured`, plugin `agent-loop`, `plugins`, `main`, `testing` (the mounting helpers, plus re-exports of the two private testing modules) | units 1 and 2 |

Two public modules are assembled from the work of more than one unit, so each unit owns a private module and unit 3 owns the public one. `dsh-agent/loop` re-exports `inbox-projection` and `inbox-apply` from `dsh-agent/private/inbox` (unit 2). `dsh-agent/testing` re-exports `make-stub-agent` from `dsh-agent/private/testing-stub` (unit 1) and `make-scripted-model`, `scripted-model-requests`, `scripted-model-remaining`, `text-response`, `max-tokens-response`, `tool-call-response`, `hang-after` and `hang-slow` from `dsh-agent/private/testing-model` (unit 2), and `loop-agent-claim!` from `dsh-agent/private/driver`; the tests of units 1 and 2 require the private modules.

Interface between units 2 and 3, exported from `dsh-agent/private/driver` and `dsh-agent/private/inbox`:

```racket
(make-loop-agent loop-ctx id options session
                 #:model-state model-reader #:inbox-state inbox-reader   ; (-> jobject?) each
                 #:last-turn n #:lifetime lifetime-evt
                 #:max-parallel-tool-calls limit-thunk) -> agent?        ; rule 57; uses the injected handles of loop-ctx for agents, llm, tools, systemPrompt
(loop-agent? v) -> boolean?
(loop-agent-scope a) -> scope?                                            ; of dsh-tools/scope; only unit 3 may use it
(loop-agent-claim! a target turn) -> (listof jobject?)
;; dsh-agent/private/inbox
inbox-projection                                                          ; projection-definition?, key "inbox"
(inbox-apply state event) -> jobject?                                     ; rule 24
```

Unit 2 tests its driver by mounting the prerequisites, registering the two projections itself and calling `make-loop-agent` with `sessions-enter` and `sessions-announce` done by hand; it needs nothing of unit 3. Unit 3 owns rules 58 to 65 and 70.

## Tests

Tests live in `racket/dsh-agent/tests/`. Rows name the TypeScript suites to mirror; paths without a directory are under `packages/core/agent-loop/tests/`.

| Racket test file | Mirrors | Pins |
|---|---|---|
| `registry-test.rkt` | `packages/core/agent/tests/agent.spec.ts` | rules 1 to 9 and 13: enter, announce, detach, deferred detach, stale detach, the factory slot, containment messages, scope filtering of agent events |
| `initiator-test.rkt` | `agent-initiator.spec.ts` of both packages | rules 10, 11: identity per driver, nesting, clearing, drain, disposal |
| `model-selection-test.rkt` | `packages/core/agent/tests/model-selection.spec.ts`, `model.spec.ts` | rules 14 to 17 |
| `folds-test.rkt` | `packages/core/agent/tests/consumed-work.spec.ts`, `archive-admission.spec.ts` | rules 12, 18, 19 |
| `inbox-test.rkt` | `inbox.spec.ts`, `properties.spec.ts` | rules 20 to 24: coordinate table, duplicate rejection, fold validation, the state already updated inside `session/event` listeners, exact notifications |
| `driver-test.rkt` | `agent.spec.ts`, `loop.spec.ts`, `input-lifecycle.spec.ts` | rules 25 to 36: status changes, the log right after a waking send, steer and followup during a turn, `inject` while idle, wake latching, maintenance, one turn per queued prompt |
| `cancel-test.rkt` | `cancel.spec.ts`, `coverage-edges.spec.ts` | rules 28, 29, 35, 37, 50: the cause table, idle cancel, `keep-inbox?`, cancel in every window, prefix finalisation, first cause wins, a break delivered to the driver |
| `interception-test.rkt` | `interception.spec.ts`, `serial-listener-review.spec.ts` | rules 33, 38: enter, rewrite, add, reject, blocked prompts stay parked, a raising listener, `agent/turn-stopping` |
| `request-test.rkt` | `request-reconstruction.spec.ts`, `system-prompt-projection.spec.ts`, `system-prompt-admission.spec.ts`, `runtime-context.spec.ts`, `tool-updates.spec.ts` | rules 40 to 48: the reconciliation table on capable and plain routes, series rules, adapter defaults, the header reasons, `developer/message`, `request/context` deduplication, rebuilding every request from the log |
| `stream-test.rkt` | the frame cases of `loop.spec.ts`, `request-error.spec.ts`, `contract-regressions.spec.ts` | rules 49 to 53: dense frames, the embedded stream equal to the frames, abandoned settlement, retry in the same step, cancellation beating a retry, `max-tokens` |
| `tools-test.rkt` | `tool-calls.spec.ts` (loop side), `tool-order.spec.ts`, `tool-executors.spec.ts` | rules 54, 55: raw calls and the live limit handed to the executor, deferred contexts after all results, `concludesTurn`, recovery results per failing phase |
| `lifecycle-test.rkt` | `scope-lifecycle.spec.ts`, `resource-lifecycle.spec.ts`, `shutdown-drain.spec.ts` | rules 57 to 61: creation order, rollback at every failure point, same-id collisions, unload of owner and loop during setup, teardown order, id reuse, the driver's custodian |
| `resume-test.rkt` | `resume.spec.ts`, `config-session-id.spec.ts`, `settings.spec.ts` | rules 62 to 65, with an in-memory persistence port |
| `default-model-test.rkt` | `packages/core/agent-default-model/tests/agent-default-model.spec.ts` | rules 66, 67, with a scripted config editor port |
| `projections-test.rkt` | the registration cases of `packages/session/session-projection/tests/registry.spec.ts` | rules 68, 69; a registration test disposes the fiber and reads the retained handle |
| `acceptance-test.rkt` | `snapshots/session/fs-read/session.v4.jsonl` (event order and key order) | rules 73, 74 as JSON text; the live event order |

Fixtures: `dsh-agent/testing`; `make-mock-llm` of `dsh-llm`; an in-memory persistence port (a hash from id to header and event list, with a write-ownership flag); a gate event per test to hold a tool or a listener. Tests set `current-session-time` to a constant. Every wait has a timeout; no test sleeps.

Acceptance gate: `raco test racket/dsh-agent` passes with no network; every numbered rule has a test that names it; the two acceptance sequences match as JSON text; `check-kernel-restored` holds after mounting the four plugins, creating an agent, running rule 74 and disposing the root's children.

## Open questions

1. **Provider of `sessionProjections` in wave 3.** Recommended default: this package ships `racket:session-projections` (rules 68, 69) and consumes the registry only through `gen:projection-port`. When `dsh-session-store` ships `@deepseek-ai/dsh-session-projection`, compositions mount that one; the in-memory plugin stays as a test fixture. The coordinator should record this in an ADR.
2. **Cancellation by break.** The brief asked for it; this contract uses a cancel source and keeps the break as a backstop, for the reasons under Racket design notes. Recommended default: as written; the coordinator records the decision.
3. **`cordis-schema` features.** The loop config needs numeric `min`, `max` and `step`, string minimum length, and volatile fields. Recommended default: use the modifiers `cordis-schema` provides; where a volatile reference is missing, read the field from `(fiber-effective-config (context-fiber ctx))` at each use through `config-get` of `dsh-llm/adapter-kit`, and validate updates in an `internal/config` listener.
4. **Loader entry of a plugin.** Rule 67 needs to know whether the plugin was mounted from a loader entry. Recommended default: `(context-meta ctx 'loader/entry-id #f)`, the name `dsh-llm.md` assumes; `config-editor-edit!` takes the context so the editor can find the entry itself.
5. **Payloads of `workspace/session-activity` and `workspace/session-stop`.** Their owner is not specified yet. Recommended default: one payload readable with `jref` under `sessionId`, and a list result for the waterfall; rule 12 is written against that.
6. **`error-chain` on wrapped failures.** Rule 56 renders an aggregate itself and calls `error-chain` of `dsh-llm` for the members. If `dsh-util` gains a common cause property that `error-chain` follows, `exn:fail:agent` should implement it and the special case goes away.
7. **Where the session event declarations are registered.** dsh declares `model/selection` in the agent package, whose plugin does not inject `sessions`. Recommended default: the loop plugin, which does inject `sessions`, registers both (rule 64); a type without a declaration is accepted unchecked, so nothing breaks when only the registry is mounted.
8. **Custodian of the scope fiber.** Rule 57 assumes `(context-custodian (agent-ctx agent))` is the custodian of the scope's current activation once the fiber is active, and that the kernel shuts it down only after the fiber's effects were reverted. A driver cannot start before the initialization job ends, by which time the fiber is active. If the kernel creates the activation custodian lazily, the driver spawn waits for the fiber first.
9. **Typert lookups.** Recommended default: `dsh-web` registers the lookup `agent` (`parameter: 'agent'`, `wire: 'agentId'`, `resource: 'session'`) and the host context `agent` with `agents-find`; nothing here.
10. **Known limit kept from dsh.** Shutting the root context down with an active agent can leave the final `turn/end` in memory and absent from a persisted log. Recommended default: keep the behaviour; `lifecycle-test.rkt` pins only that an idle agent's events are stored by root disposal.
