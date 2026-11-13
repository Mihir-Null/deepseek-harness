# Interface contract: `dsh-tools`

This is the binding interface for `racket/dsh-tools/`. It covers the scope library, the tool definition forms and the JSON Schema subset behind them, the scoped tool registry `tools`, the guarded execution pipeline and batch scheduler, the system prompt service `systemPrompt`, the native executor and the deprecated presentation selector. Sources: [recon 04](../recon/04-core-data.md), `packages/core/{system-prompt,tools,scope,tool-executor-native,agent-tool-presentation}/src` at commit `e8f7b93a3`, `docs/tool-execution-pipeline.md`, `docs/cookbook/adding-a-tool.md`. When this document and the TypeScript disagree about behaviour, the TypeScript is right and this document gets fixed. When they disagree about names and argument order of the Racket surface, this document is right. Read [dsh-session.md](dsh-session.md) first; this contract uses its vocabulary (`absent`, `session-event` constructors, `scope-core`, `lossless-json?`). Cancel sources and cancel events are those of `dsh-llm/cancel` ([dsh-llm.md](dsh-llm.md), "Cancellation").

Package: directory `racket/dsh-tools/`, collection `dsh-tools`, `(define deps '("base" "cordis" "cordis-data" "cordis-schema" "dsh-util" "dsh-session" "dsh-llm"))`, `(define build-deps '("rackunit-lib"))`. It must not depend on `dsh-agent`: an agent is an opaque scope key here.

## Scope

| dsh package | npm name | Status |
|---|---|---|
| `packages/core/scope` | `@deepseek-ai/dsh-scope` | native. The tag, the parent relation and scope-filtered dispatch are implemented in `dsh-session/scope-core` (that package sits below this one and needs them) and re-exported from `dsh-tools/scope`, which adds `create-scope` and the registry storage. Every other package requires `dsh-tools/scope`. |
| `packages/core/system-prompt` | `@deepseek-ai/dsh-system-prompt` | native |
| `packages/core/tools` | `@deepseek-ai/dsh-tools` | native. `AbortSignal` becomes a cancel event (ADR 0002). The batch log record carries the session because this package cannot read `agent.session`. The approval service is reached through a generic interface defined here. |
| `packages/core/tool-executor-native` | `@deepseek-ai/dsh-tool-executor-native` | native |
| `packages/core/agent-tool-presentation` | `@deepseek-ai/dsh-agent-tool-presentation` | native. The `ptc` child plugin is resolved by its dsh name at run time because its package is built in a later wave. |

The `core` group has ten packages. The five above are covered here; `packages/core/session` is covered by `dsh-session`; `packages/core/agent`, `core/agent-loop` and `core/agent-default-model` by `dsh-agent`; `packages/core/tool-executor-ptc` (`@deepseek-ai/dsh-tool-executor-ptc`) by `dsh-ptc` in wave 4, the second provider of `gen:tool-executor`.

Not applicable: the TypeScript type inference of the schema DSL (`InferArgs`, `InferValue`); `define-tool` binds parameters instead. None of these packages registers a model-facing tool; `run_code` is only a reserved name here.

## Modules

| Module | Provides |
|---|---|
| `dsh-tools` (`main.rkt`) | re-exports `tool`, `schema`, `json-schema`, `tools`, `errors`, `presentation`, `cancel` |
| `dsh-tools/scope` | everything in `dsh-session/scope-core`, plus `create-scope`, `scope`, `named-entries`, `anonymous-entries`, `scoped-layers` |
| `dsh-tools/cancel` | a re-export of every binding of `dsh-llm/cancel`, so that a tool author requires one package |
| `dsh-tools/errors` | error constructors, predicates, codes |
| `dsh-tools/json-schema` | the enforced JSON Schema subset: `assert-supported-json-schema`, `assert-object-json-schema`, `validate-json-schema-value` |
| `dsh-tools/schema` | the author schema DSL (`v-string` and the other node constructors), `parameter-spec->json-schema`, `value-spec->json-schema`, `validate-args`, `project-tool-schema` |
| `dsh-tools/tool` | `tool-definition`, `make-tool`, `make-raw-tool`, `define-tool`, execution, result and decision data |
| `dsh-tools/presentation` | predicates and constructors for call and result views |
| `dsh-tools/approval` | `gen:tool-approval`, `approval-request` |
| `dsh-tools/system-prompt` | the `systemPrompt` service definition, its events, the render procedures, order tables and constants |
| `dsh-tools/tools` | the `tools` service definition, its events, `gen:tool-executor`, batch data |
| `dsh-tools/pipeline` | `make-tool-execution-pipeline`, the three stage procedures, `execute-tool-batch`, `tool-error-message` |
| `dsh-tools/executor-native` | `make-native-tool-executor` |
| `dsh-tools/plugin/system-prompt`, `…/tools`, `…/tool-executor-native`, `…/agent-tool-presentation` | each provides `plugin` |
| `dsh-tools/plugins` | `plugin-table` |

## Data

### Scope

```racket
(struct scope (ctx raw-dispose dispose))            ; opaque; accessors scope-ctx, scope-raw-dispose, scope-dispose
(create-scope ctx key #:parent [parent #f]) -> scope?
(make-named-entries duplicate-error) -> named-entries?          ; duplicate-error : (-> string? exn?)
(named-entries-insert! t name value) -> (-> void?)
(named-entries-ref t name [default #f]) (named-entries-has? t name) (named-entries-empty? t)
(named-entries-keys t) (named-entries-values t) (named-entries->alist t)   ; insertion order, snapshots
(make-anonymous-entries) -> anonymous-entries?
(anonymous-entries-append! t value) -> (-> void?)
(anonymous-entries-values t) (anonymous-entries-empty? t)
(make-scoped-layers create-layer layer-empty? on-change) -> scoped-layers?   ; create-layer : (-> (or/c scope-key? #f) layer)
(scoped-layers-global sl) -> layer
(scoped-layers-peek sl key) -> (or/c layer #f)
(scoped-layers-chain sl key) -> (listof layer)                  ; existing layers, farthest ancestor first, exact scope last
(scoped-layers-merge sl key pick) -> (listof (cons/c string? any/c))   ; pick : (-> layer named-entries?)
(scoped-layers-effect! sl ctx action #:label label #:notify? [notify? #t]) -> disposer?   ; action : (-> layer (-> void?))
```

### Cancellation

A *cancel event* is the Racket form of `AbortSignal`: any `evt` that, once ready, stays ready and whose synchronization result is the abort reason. The values are defined in `dsh-llm/cancel`, the lowest package that takes a cancel event, and are specified there; `dsh-tools/cancel` and `dsh-tools` re-export them unchanged: `make-cancel-source`, `cancel-source?`, `cancel-source-evt`, `cancel!`, `cancelled?`, `cancel-reason`, `check-cancelled!`, `cancel-evt-any`, `never-cancelled`, `exn:fail:abort`, `make-abort-error`. The `cancel` of `make-tool-execution-input`, `make-tool-batch-input`, `tools-resolve`, `tool-activation-context` and `approval-request` is such an event and never `#f`; a caller with nothing to cancel passes `never-cancelled`. Only the `'cancel` entry of an assemble context may be absent.

### Schemas

An *author spec* is a jobject in the dsh author form (`tools/src/schema.ts:12-103`). The node constructors are conveniences that build it:

```racket
(v-string  #:enum [e absent] #:const [c absent] annotation ...) -> jobject?     ; {type: "string", ...}
(v-number …) (v-integer …) (v-boolean …) (v-null …)                             ; same keywords
(v-array #:items [items absent] annotation ...)                                 ; {type: "array", items?}
(v-object #:additional? additional? #:properties [properties absent] annotation ...)   ; #:additional? is required; properties is a parameter spec
(v-json annotation ...)                                                         ; {type: "json"}
(v-one-of branch branch branch ... annotation ...)                              ; {oneOf: [...]}, at least two branches
;; annotation keywords on every constructor: #:description #:title #:default #:examples, each defaulting to absent
(param name spec #:required? [required? #f]) -> pair?                           ; name : string?
(parameters p ...) -> jobject?                                                  ; p : a result of param; builds a parameter spec in argument order
```

A *parameter spec* is a jobject from parameter name to author node, where a node may carry `required: true`. The constructors produce the same jobjects a translated plugin would pass literally; either form is accepted wherever a spec is expected. A *JSON Schema* is a jobject in the enforced subset (`tools/src/json-schema.ts`). A *tool schema* is the jobject `{name, description, parameters, deferLoading?}` in that key order, `deferLoading` present only when `true`; it is the only part of a tool that reaches a model.

### Tool definition

```racket
(tool-definition? v)                                 ; opaque
(tool-definition-name t) (tool-definition-description t) (tool-definition-parameters t) -> jobject?
(tool-definition-defer-loading? t) -> boolean?
(tool-definition-output-schema t) -> jobject?
(tool-definition-render t)            ; (-> jvalue? jvalue? (listof jobject?))            args value -> content blocks
(tool-definition-presentation-meta t) ; (or/c #f (-> jvalue? jvalue? jvalue?))
(tool-definition-execute t)           ; (-> jvalue? tool-execution? any/c)                may await
(tool-definition-project-content t)   ; (or/c #f (-> tool-execution? tool-execution-result? (or/c #f (listof jobject?))))
(tool-definition-finalize-content t)  ; same signature; must not wait and must not raise
(tool-definition-timeout-ms t)        ; (or/c #f (and/c real? positive?))
(tool-definition-concurrency-safe? t) ; (or/c #f (-> jvalue? any/c))
(tool-definition-present-call t)      ; (or/c #f (-> jvalue? (or/c #f tool-call-view?)))
(tool-definition-present-result t)    ; (or/c #f (-> jvalue? tool-result? (or/c #f tool-result-view?)))
(struct tool-result (content error? meta) #:transparent)   ; dsh ToolResult; meta is absent or a jvalue
```

```racket
(make-tool #:name name #:description description #:parameters parameter-spec
           #:output output-spec #:render render #:execute execute
           #:presentation-meta [pm #f] #:defer-loading? [dl #f] #:timeout-ms [ms #f]
           #:concurrency-safe? [cs #f] #:project-content [pc #f] #:finalize-content [fc #f]
           #:present-call [pcall #f] #:present-result [pres #f]) -> tool-definition?
(make-raw-tool #:name name #:description description #:parameters json-schema
               #:output-schema json-schema #:render render #:execute execute
               … the same optional keywords …) -> tool-definition?

(define-tool id
  #:name name-expr
  #:description description-expr
  #:parameters ([param-id (~optional json-key-string) spec-expr (~alt (~optional #:required) (~optional (~seq #:or default-expr))) ...] ...)
  #:output output-spec-expr
  (~alt (~optional (~seq #:args args-id))
        (~optional (~seq #:defer-loading? expr)) (~optional (~seq #:timeout-ms expr))
        (~optional (~seq #:project-content expr)) (~optional (~seq #:finalize-content expr))) ...
  (render (value-id) body ...+)
  (execute (exec-id) body ...+)
  (~alt (~optional (presentation-meta (value-id) body ...+))
        (~optional (concurrency-safe? () body ...+))
        (~optional (present-call () body ...+))
        (~optional (present-result (result-id) body ...+))) ...)
```

`make-tool` is dsh `defineTool`: it compiles both specs, and the definition it returns validates arguments before the body runs. `make-raw-tool` is a raw `ToolDefinition`: it takes JSON Schemas as given and performs no argument validation. `define-tool` expands to `make-tool`; rule 16 states what it binds.

### Execution data

```racket
(make-tool-execution-input #:call-id id #:name name #:arguments args #:cancel evt
                           #:root-call-id [root #f] #:schema [schema #f] #:agent [agent #f]
                           #:tool-set [ts #f] #:parent [parent #f]) -> tool-execution-input?
(tool-execution? v)                                   ; opaque, one per call
(tool-execution-token e) -> tool-execution-token?     ; a fresh value compared with eq?
(tool-execution-call-id e) (tool-execution-root-call-id e) (tool-execution-name e)
(tool-execution-arguments e) -> (or/c jvalue? absent?)
(tool-execution-agent e) (tool-execution-tool-set e) (tool-execution-parent e) (tool-execution-schema e)   ; #f when not given
(tool-execution-cancel e) -> evt?
(set-tool-execution-cancel! e evt) -> void?
(call-with-tool-cancel e evt thunk) -> any            ; sets the cancel event, runs thunk, restores the previous one
(tool-defer-context! e user-message) -> void?         ; dsh deferContext
(tool-conclude-turn! e) -> void?                      ; dsh concludeTurn

(tool-execution-result? v)                            ; tool-success? or tool-failure?, opaque
(make-tool-success value content #:meta [meta absent] #:additional-contexts [ctxs '()] #:concludes-turn? [c #f])
(make-tool-failure message content #:info [info #f] #:meta [meta absent] #:additional-contexts [ctxs '()])
(tool-execution-result-error? r) (tool-execution-result-content r) (tool-execution-result-meta r)   ; absent or a jvalue
(tool-execution-result-additional-contexts r) -> (listof jobject?)
(tool-success-value r) (tool-success-concludes-turn? r)
(tool-failure-message r) (tool-failure-info r) -> (or/c #f tool-error-info?)
(tool-execution-result-with-content r content) -> tool-execution-result?
(tool-execution-result->jvalue r) -> jobject?
(struct tool-error-info (name code reason) #:transparent)     ; reason : (or/c #f string?)
(tool-error-info->jvalue i) -> jobject?                        ; {name, code, reason?}
```

JSON form of a result (`pipeline.ts:599-614`): a failure is `{isError: true, error: {message, info?}, content, meta?, additionalContexts?}`; a success is `{isError: false, content, meta?, additionalContexts?, concludesTurn?, value}`. Only `content`, `isError`, `error.info` and `meta` reach the session log, through the `tool/result` event.

```racket
(struct pre-allow () #:transparent)
(struct pre-deny (reason info) #:transparent)                  ; info : (or/c #f tool-error-info?)
(struct pre-cancel () #:transparent)
(struct pre-ask (reason display-reason) #:transparent)         ; reason : (or/c #f string?); display-reason : (or/c #f jobject?) with key en
(make-post-accept #:content [content absent] #:value [value absent] #:additional-contexts [ctxs '()]) -> post-accept?
(struct post-block (feedback info additional-contexts) #:transparent)
(struct tool-guard-denial (reason info) #:transparent)
(pre-tool-decision? v)                                         ; pre-allow?, pre-deny?, pre-cancel? or pre-ask?
(post-tool-decision? v)                                        ; post-accept? or post-block?
(post-accept-content d) (post-accept-value d)                  ; absent when not given
(post-accept-additional-contexts d)
(struct tool-activation-context (agent model-selection cancel) #:transparent)
(resolved-tool-set? v)
(tool-set-definitions ts scope) -> (listof tool-definition?)
(tool-set-ref ts scope name) -> (or/c tool-definition? #f)
(tool-set-dispose! ts) -> void?

(struct tool-batch-log (session turn step) #:transparent)
(make-tool-batch-input #:calls calls #:cancel evt #:max-parallel-tool-calls [n #f]
                       #:agent [agent #f] #:tool-set [ts #f] #:log [log #f]) -> tool-batch-input?
(struct tool-call-result (call-id result) #:transparent)
(struct tool-batch-result (results additional-contexts concluded?) #:transparent)
(struct tool-prompt-section (name order text interpolate?) #:transparent)   ; text : string or (-> (listof tool-definition?) string?)
(struct tool-model-input (schemas known-names) #:transparent)               ; known-names : (or/c #f (listof string?))
(struct tool-preparation (kind exec result) #:transparent)     ; kind : 'dispatch 'post-result 'final-result; result #f for 'dispatch
(struct tool-dispatch-outcome (kind result) #:transparent)     ; kind : 'post-result 'final-result
(struct approval-request (agent tool-name call-id reason display-reason cancel) #:transparent)
```

Exporting modules. `dsh-tools/tool` exports the execution input and execution, the result values, `tool-error-info` and the decision structs (`pre-allow` to `tool-guard-denial`). `dsh-tools/tools` exports `tool-activation-context`, `resolved-tool-set?` with `tool-set-definitions`, `tool-set-ref` and `tool-set-dispose!`, the batch data (`tool-batch-log`, `make-tool-batch-input`, `tool-call-result`, `tool-batch-result`) and the executor data (`tool-prompt-section`, `tool-model-input`). `dsh-tools/pipeline` exports `tool-preparation` and `tool-dispatch-outcome`. `dsh-tools/approval` exports `approval-request`. Where a value of a later module appears in an earlier one (`tool-execution-tool-set` returns a resolved tool set), the earlier module's contract is `any/c`.

`calls` is a list of `tool-call` content blocks (jobjects with `id`, `name`, `arguments`, the raw model text). `make-post-accept` raises `exn:fail:contract` with message `tools/post-execute accept decision cannot replace both value and content` when both are given.

### Presentation views

Views are jobjects, as they cross to user interfaces as JSON (`tools/src/presentation.ts`). `tool-call-view?` and `tool-result-view?` check the `card` tag and the required keys.

- `ToolCallView`: `{card: "generic", title, kind?, rawInput?, content?, locations?}`, `{card: "terminal", title, description?, cwd?}`, `{card: "diff", title, diffs, locations?}`. `kind` is one of `read edit delete move search execute fetch other`. A location is `{path, line?}`; a diff is `{path, oldText: string or null, newText}`.
- `ToolResultView`: `{card: "generic", title?, content?}`, `{card: "terminal", title?, output?, exitCode?, signal?}`, `{card: "diff", title?, diffs}`, `{card: "search", shape: "matches", title?, files: [{path, matches: [{lineNumber, line}]}], truncated, total}`, `{card: "search", shape: "paths", title?, paths, truncated, total}`, `{card: "read", title?, path, offset, lines: [{number, text}], totalLines, lang?, content?}`, `{card: "web", kind: "search", title?, sources: [{url, title?, snippet?, publishedAt?}], answer?, truncated}`, `{card: "web", kind: "fetch", title?, url, statusCode, truncated}`.

### System prompt data

```racket
(struct prompt-section (name order text interpolate? complete?) #:transparent)   ; text : string or (-> assemble-context? string?)
(make-prompt-section #:name n #:order o #:text t #:interpolate? [i #t] #:complete? [c #f])
(struct prompt-context (name order text interpolate? required?) #:transparent)
(make-prompt-context #:name n #:order o #:text t #:interpolate? [i #t] #:required? [r #f])
(struct assembled-section (name text interpolate?) #:transparent)
(struct assembled-context (name text interpolate?) #:transparent)
(struct tool-provider-result (schemas known-names) #:transparent)                ; known-names : (or/c #f (listof string?))
(struct prompt-presentation (sections contexts variables) #:transparent)
(struct prompt-assembly (sections contexts variables tools) #:transparent)
(assemble-context? v)                                 ; immutable hasheq with symbol keys
(make-assemble-context #:scope [scope #f] #:cancel [cancel #f] #:extra [extra (hasheq)]) -> assemble-context?
(assemble-context-set actx key value) -> assemble-context?
persona-prefix-section    ; "deployment:persona-prefix"
persona-suffix-section    ; "deployment:persona-suffix"
tool-order-rest           ; "<unlisted-tools>"
section-orders context-orders   ; immutable hasheq, name symbol -> number
```

`variables` is a jobject from variable name to a string, or `#f` when the provider gave no value; its key order is registration order. An assemble context is the merge-extensible `AssembleContext`: keys `'scope` and `'cancel` are defined here, `'tool-set` is used by the `tools` service, and `dsh-agent` adds `'agent` and `'model-selection`. A context snapshot section is the jobject `{name, text}`.

### Errors

All are substructs of `exn:fail:harness` declared in `dsh-tools/errors` and made by its constructors; the dsh error name and code are the persisted identity.

| Constructor | dsh name | Code | Message |
|---|---|---|---|
| `(make-tool-not-found-error name [reachable-from #f])` | `ToolNotFoundError` | `UNKNOWN_TOOL` | `unknown tool "<name>"`, or `unknown tool "<name>": <hint>` |
| `(make-tool-args-error violations)` | `ToolArgsError` | `INVALID_ARGS` | `invalid arguments: <v1>; <v2>…` |
| `(make-tool-output-error tool-name violations)` | `ToolOutputError` | `INVALID_TOOL_OUTPUT` | `tool "<name>" returned invalid output: <v1>; <v2>…` |
| `(make-tool-context-unavailable-error message #:cause [c #f])` | `ToolContextUnavailableError` | `TOOL_CONTEXT_UNAVAILABLE` | as given |
| `(make-tool-activation-error name cause)` | `ToolActivationError` | `TOOL_ACTIVATION_FAILED` | `cannot resolve availability of tool "<name>"` |
| `(make-tool-executor-unavailable-error)` | `ToolExecutorUnavailableError` | `TOOL_EXECUTOR_UNAVAILABLE` | `The selected tool executor is unavailable. Load an executor in this composition before running the agent.` |
| `(make-json-schema-error violations)` | `JsonSchemaError` | `UNSUPPORTED_SCHEMA` | `unsupported JSON schema: <v1>; <v2>…` |

The three with violations expose them through `(harness-error-violations e)`. `(struct exn:fail:tool-batch exn:fail (cause partial))` is `ToolBatchExecutionError` with message `Tool batch execution failed`; `cause` is the raised value and `partial` a `tool-batch-result?` holding only the committed calls. It is not a harness error. Constants: `run-code-name` `"run_code"`, `tool-aborted` `"ABORTED"`, `tool-aborted-before-dispatch` `"ABORTED_BEFORE_DISPATCH"`, `approval-error-name` `"ApprovalError"`, `approval-rejected`, `approval-cancelled`, `approval-unavailable` (the code strings of the same spelling in upper case with underscores). `(harness-error-info v) -> (or/c #f tool-error-info?)` returns `(tool-error-info name code #f)` for an `exn:fail:harness` and `#f` for anything else; it is the only place that reads the `dsh-util` struct.

## Services

`x` is a context or a handle for the service; "the caller's context" is `(use-context x)` and "the caller's scope" is `(scope-of (use-context x))`.

### `systemPrompt`

Declared with `(define-service system-prompt 'systemPrompt #:contract system-prompt?)`.

```racket
(system-prompt-section! x section) -> disposer?
(system-prompt-context! x context) -> disposer?
(system-prompt-variable! x name provider) -> disposer?          ; provider : (-> assemble-context? (or/c string? #f))
(system-prompt-tools! x provider) -> disposer?                  ; provider : (-> assemble-context? tool-provider-result?)
(system-prompt-suppress-runtime-context! x) -> disposer?
(system-prompt-section-order x name) -> real?                   ; name : symbol, e.g. 'TOOL_BASH
(system-prompt-context-order x name) -> real?
(system-prompt-assemble x [actx (make-assemble-context)]) -> prompt-assembly?      ; may wait
(system-prompt-refresh-context x assembly [actx (make-assemble-context)]) -> prompt-assembly?
(render-prompt assembly) -> string?
(render-context-sections assembly) -> (listof jobject?)
(join-context-sections sections) -> string?
(render-context-snapshot assembly) -> string?
```

| Procedure | Errors | Effect on the caller's context |
|---|---|---|
| `system-prompt-section!` | order not finite: `exn:fail:contract` `prompt section "<name>" order must be a finite number`; duplicate name in the layer: ``prompt section "<name>" is already registered (for a per-agent override, register through that agent's `agent.ctx` instead)`` in the global layer, `prompt section "<name>" is already registered in this scope` in a scoped one | one effect `systemPrompt.section()` in the caller's scope layer |
| `system-prompt-context!` | the same two rules with `prompt context` | `systemPrompt.context()` |
| `system-prompt-variable!` | name not matching `^[a-z][a-z0-9_]*$`: `invalid prompt variable name "<name>" (must match /^[a-z][a-z0-9_]*$/)`; duplicates: ``prompt variable "<name>" is already registered (for a per-agent value, register through that agent's `agent.ctx` instead)`` or `prompt variable "<name>" is already registered in this scope` | `systemPrompt.variable()` |
| `system-prompt-tools!` | none | `systemPrompt.tools()` |
| `system-prompt-suppress-runtime-context!` | none | `systemPrompt.suppressRuntimeContext()` |

Each registration and each disposal emits `system-prompt/change` after the change. A scoped section, context or variable shadows a global or ancestor entry of the same name. Tool providers never shadow.

### `tools`

Declared with `(define-service tools 'tools #:contract tools-service?)`, which defines `tools-key`, `tools-ref`, `tools-get` (the optional read of the service value) and `provide-tools`. The dsh method `get(name, scope, toolSet)` is therefore named `tools-lookup` here.

```racket
(tools-register! x definition #:when [when #f]) -> disposer?    ; when : (-> tool-activation-context? any/c), may wait
(tools-restrict! x #:allow [allow #f] #:deny [deny #f]) -> disposer?
(tools-lookup x name [scope #f] [tool-set #f]) -> (or/c tool-definition? #f)       ; dsh get
(tools-executable x name [scope #f] [tool-set #f]) -> (or/c tool-definition? #f)
(tools-resolve x #:agent agent #:model-selection selection #:cancel evt) -> resolved-tool-set?   ; may wait
(tools-definitions x [scope #f] [tool-set #f]) -> (listof tool-definition?)
(tools-schemas x [scope #f] [tool-set #f]) -> (listof jobject?)
(tools-set-executor! x executor) -> disposer?                   ; executor : tool-executor?
(tools-execute x batch-input) -> tool-batch-result?             ; waits
(tools-guard! x guard) -> disposer?                             ; guard : (-> tool-execution? (or/c #f string? tool-guard-denial?))
(tools-check-guards x exec) -> (or/c #f tool-guard-denial?)
```

| Procedure | Errors | Effect on the caller's context |
|---|---|---|
| `tools-register!` | rule 21 | one effect `tools.register()`; emits `tools/change` on registration and disposal |
| `tools-restrict!` | rule 22 | one effect `tools.restrict()`; emits `tools/change` on registration and disposal |
| `tools-set-executor!` | rule 26 | one effect `tools.setExecutor()` whose children are the executor's prompt sections; no change event |
| `tools-guard!` | none | one effect `tools.guard()`; no change event |
| the others | as stated in Behaviour | none |

```racket
(define-generics tool-executor
  (tool-executor-sections tool-executor)                 ; -> (listof tool-prompt-section?); default '()
  (tool-executor-describe tool-executor definitions)     ; -> tool-model-input?
  (tool-executor-execute tool-executor batch-input))     ; -> tool-batch-result?, waits
(define-generics tool-approval
  (tool-approval-request tool-approval request))         ; -> 'allowed-once 'rejected 'cancelled 'unavailable, waits
```

### The pipeline (a library, used by executors)

```racket
(make-tool-execution-pipeline ctx #:get [get #f] #:reject [reject #f]) -> tool-execution-pipeline?
;; get : (-> string? (or/c scope-key? #f) (or/c resolved-tool-set? #f) (or/c tool-definition? #f))
;; reject : (-> string? boolean? (or/c #f any/c))        name nested? -> a value to report as the refusal
(pipeline-execution-mode p input) -> (or/c 'parallel 'exclusive)
(pipeline-prepare p input) -> tool-preparation?          ; may wait
(pipeline-dispatch p exec) -> tool-dispatch-outcome?     ; waits
(pipeline-complete p exec outcome) -> tool-execution-result?   ; may wait; outcome : tool-preparation? or tool-dispatch-outcome?
(execute-tool-batch input pipeline max-parallel) -> tool-batch-result?   ; max-parallel : (-> exact-positive-integer?)
(tool-error-message v) -> string?
(make-native-tool-executor ctx [max-parallel (lambda () 10)]) -> tool-executor?
```

The pipeline reads the `tools` service value once at construction and keeps it, so accepted calls settle after the service is withdrawn.

### Waiting and cancellation

Every procedure that can wait says how it is cancelled:

- `tools-resolve`: `#:cancel`; it raises the cancel reason (rule 19).
- `tools-execute`, `tool-executor-execute` and `execute-tool-batch`: the batch input's cancel event; a cancelled batch returns normally with aborted results (rule 46).
- `pipeline-prepare`, `pipeline-dispatch` and `pipeline-complete`: the execution input's cancel event, observed at the points of rules 31, 33, 34 and 37; cancellation becomes a result (rule 40) and a started tool body is never abandoned.
- A tool body and a `when` condition: the event they are given (`tool-execution-cancel`, `tool-activation-context-cancel`).
- `tool-approval-request`: the `cancel` field of the request.
- `system-prompt-assemble` and `system-prompt-refresh-context`: the `'cancel` entry of the assemble context. The service hands it to the providers and does not check it itself, as in dsh; the caller checks after the call returns.
- `scope-dispose` takes no cancel event: it waits for the scope fiber's unload, which must complete.

None of these catches a break. A break delivered to a task that waits inside one of them propagates (cordis-kernel section 2 rule 4) and is never turned into a tool result; dispatch tasks already started by `execute-tool-batch` keep running until their cancel event or their custodian stops them, and the caller that was broken is responsible for cancelling the batch's event and recording what is still pending (dsh-agent rules 37 and 55).

## Events

Declared in the service definition modules. The modules export the `on-…` and `…-name` bindings. Of the generated dispatchers only `dispatch-tools/change` is exported: dsh's `@deepseek-ai/dsh-agent-preset-registry` (wave 4) also emits `tools/change` when a preset changes an agent's tools (`packages/preset/agent-preset-registry/src/index.ts:352`). `system-prompt/change` is emitted only by the `systemPrompt` service, and the other five events are dispatched only by this package through `scoped-dispatch` or `scoped-callbacks`.

```racket
(define-event system-prompt/assemble 'system-prompt/assemble #:mode waterfall
  #:args (prompt-presentation? assemble-context?) #:result prompt-presentation?)
(define-event system-prompt/change 'system-prompt/change #:mode emit #:args ())
(define-event tools/pre-execute  'tools/pre-execute  #:mode waterfall #:args (tool-execution?) #:result pre-tool-decision?)
(define-event tools/execute      'tools/execute      #:mode waterfall #:args (tool-execution?) #:result tool-execution-result?)
(define-event tools/post-execute 'tools/post-execute #:mode waterfall #:args (tool-execution? tool-execution-result?) #:result post-tool-decision?)
(define-event tools/result       'tools/result       #:mode emit #:args (tool-execution? tool-execution-result?))
(define-event tools/change       'tools/change       #:mode emit #:args ())
```

| Event | Dispatched by, when | Scope key and base filter | Guarantees |
|---|---|---|---|
| `system-prompt/assemble` | `system-prompt-assemble`, once per assembly | `(hash-ref actx 'scope #f)`; realm of `systemPrompt` | The innermost step returns the assembly unchanged. The returned value replaces sections, contexts and variables. Tools are not part of the payload. |
| `system-prompt/change` | every `systemPrompt` registration and disposal, after the change | unfiltered | A listener that raises during a registration rolls it back. |
| `tools/pre-execute` | `pipeline-prepare`, once per call | `(tool-execution-agent exec)`; realm of `tools` | The innermost step returns `(pre-allow)`. Runs in model order across a batch. |
| `tools/execute` | `pipeline-dispatch` | same | The innermost step runs the tool body. A listener may change only the cancel event of `exec`. May overlap with sibling calls. |
| `tools/post-execute` | `pipeline-complete` for `'post-result` outcomes | same | The innermost step returns `(make-post-accept)`. Runs in model order. Not run for `'final-result` outcomes. |
| `tools/result` | the end of `pipeline-complete`, exactly once per call, before the `tool/result` session event is appended | same | `exec` no longer accepts changes. Each listener is contained; a failure is logged at `warning` as `tool "<name>" (<callId>): tools/result observer failed: <message>`. |
| `tools/change` | `tools-register!`, `tools-restrict!` and their disposals; the preset registry of wave 4 through `dispatch-tools/change` | unfiltered | Not emitted by `tools-guard!` or `tools-set-executor!`. A listener that raises during a registration rolls it back. |

## Plugins

| dsh npm name | Module | Inject | Provides | Config |
|---|---|---|---|---|
| `@deepseek-ai/dsh-system-prompt` | `dsh-tools/plugin/system-prompt` | none | `systemPrompt` | below |
| `@deepseek-ai/dsh-tools` | `dsh-tools/plugin/tools` | `systemPrompt` | `tools` | below |
| `@deepseek-ai/dsh-tool-executor-native` | `dsh-tools/plugin/tool-executor-native` | `tools` | none | none |
| `@deepseek-ai/dsh-agent-tool-presentation` | `dsh-tools/plugin/agent-tool-presentation` | `tools` | none | below |

Each plugin's `#:name` is the npm name; `#:meta` records the dsh function-plugin name under `'dsh-name` (`"native-tool-executor"`, `"tool-presentation"`). `@deepseek-ai/dsh-scope` is a library and has no row in `plugin-table`.

`@deepseek-ai/dsh-system-prompt` config (`system-prompt/src/index.ts:437-444`):

| Field | Type | Default |
|---|---|---|
| `includeHarnessIdentity` | boolean | `true` |
| `includeRuntimeContext` | boolean | `true` |
| `personaPrefix` | string | `""` |
| `personaSuffix` | string | `""` |
| `toolOrder` | array of string | absent (an explicit `[]` is an error because it lacks the rest entry) |

Body, in order: validate `toolOrder` (a repeated name raises `toolOrder lists "<name>" more than once`; a list without `<unlisted-tools>` raises `toolOrder must contain the "<unlisted-tools>" rest entry (where unlisted tools are inserted)`); create and provide the service; when `includeHarnessIdentity`, register section `harness:identity`, order `-1000`, text `You are an AI agent powered by DeepSeek Harness.`; register section `deployment:persona-prefix`, order `0`, text `personaPrefix`, even when empty; register section `deployment:persona-suffix`, order `10200`, text `personaSuffix`; when `includeRuntimeContext` is false, call `system-prompt-suppress-runtime-context!`. All of these go to the global layer.

`@deepseek-ai/dsh-tools` config: two fields that accept no value, `mode` (description `Removed. Mount a native or PTC tool executor instead.`) and `maxParallelSubCalls` (description `Moved to the PTC tool executor configuration.`). Supplying either fails the mount with a validation error whose message starts `invalid config`. Body: create and provide the service; register one global tool-schema provider with `system-prompt-tools!` (rule 27).

`@deepseek-ai/dsh-tool-executor-native`: no config. Body: `(tools-set-executor! tools (make-native-tool-executor ctx))`.

`@deepseek-ai/dsh-agent-tool-presentation` config: `mode`, one of `"native"` or `"ptc"`, required, no default. Body: `(ctx-plugin ctx p)` where `p` is the native executor plugin for `"native"`, and for `"ptc"` the plugin named `@deepseek-ai/dsh-tool-executor-ptc`, found by `dynamic-require` of `plugin-table` from `dsh-ptc/plugins`. A missing module raises at load: `@deepseek-ai/dsh-agent-tool-presentation: mode "ptc" requires plugin "@deepseek-ai/dsh-tool-executor-ptc", which is not installed`. With `ptc` the child waits for its runtime; until then the inherited executor stays selected.

## Behaviour

"Raise" without a type means `exn:fail` with the exact message. Handlers that turn a raised value into a result never catch `exn:break`.

**Scope storage** (recon 04 "Scope"; `scope/src/index.ts:138-150`, `scope/src/store.ts`)

1. `create-scope` binds the parent first when given (so the errors of `bind-scope-parent!` apply), mounts a plugin with an empty body under `ctx`, and tags that fiber's context with `context-with-scope`. The tagged context is usable at once. The two disposal accessors return the stored procedures, they do not dispose: `(scope-raw-dispose s)` is a zero-argument procedure that disposes the fiber, suitable as an effect inverse; `(scope-dispose s)` is a zero-argument procedure that disposes it and waits until the fiber has no transition in flight, so a caller writes `((scope-dispose s))`; concurrent callers wait for the same completion.
2. `named-entries-insert!` raises `(duplicate-error name)` for an existing name and otherwise returns an undo that removes exactly that entry and does nothing on a second call. `anonymous-entries-append!` makes every append a separate registration, including equal values. Both keep insertion order.
3. `scoped-layers-merge` copies the global named entries and overlays each chain layer, farthest first; the nearest scope wins a name and the name keeps the position of its first insertion.
4. `scoped-layers-effect!` runs inside one `ctx-effect` on `ctx` with the given label: take the global layer when `(scope-of ctx)` is `#f`, else the scope's layer, creating it when missing; call `(action layer)` to get the undo; if that raises, drop a layer that was created and is empty, and re-raise. The effect's inverse runs the undo, deletes the scoped layer when `(layer-empty? layer)`, and calls `on-change` when `notify?`. After the inverse is in place, call `on-change` when `notify?`; if it raises, the inverse runs and the exception leaves `scoped-layers-effect!`.

**Schema DSL** (recon 04 "Schema DSL and the enforced JSON Schema subset"; `tools/src/schema.ts:181-420`)

5. `(value-spec->json-schema spec)` compiles an author node with root path `schema`; `(parameter-spec->json-schema spec)` compiles a parameter spec with root path `parameters`. Both then run rule 8 on the output. Violations raise the JSON Schema error with one violation.
6. Key order of the compiled output, which is what a model receives. Scalar node: `type`, `description`, `title`, `default`, `examples`, `enum`, `const`. Array: `type`, the four annotations in that order, `items`. Object: `type`, the annotations, `additionalProperties`, `properties`, `required`. `json`: the annotations only. `oneOf`: `oneOf`, then the annotations. Parameter root: `type: "object"`, `properties`, `required`; there is no `additionalProperties` key at the root. Properties keep the author's order. `required` lists the names marked `required: true` in property order and is omitted when empty; the `required` mark is removed from each property.
7. Author errors, each with its path (`parameters.<name>`, `<path>.properties.<name>`, `<path>.items`, `<path>.oneOf[<i>]`): `<path> must be an object of value schemas`; `<path> must be a value schema object`; `<path>.required must be true when present`; `<path>.<key> is not supported by the value schema DSL` (allowed keys per node kind: the annotations, `required` on a property, plus `type` and `oneOf` on a union, `type` on `json`, `type properties additionalProperties` on an object, `type items` on an array, `type enum const` on a scalar); `<path> cannot declare both type and oneOf`; `<path>.oneOf must be an array of at least two value schemas`; `<path>.additionalProperties must be explicitly true or false`; `<path>.enum must be a non-empty array of scalar values`; `<path>.type must be string/number/integer/boolean/null/array/object/json, or use oneOf`.
8. `(assert-supported-json-schema schema)` collects every violation of the subset and raises one JSON Schema error (`json-schema.ts:209-372`). Keywords: constraints `type oneOf properties required additionalProperties items enum const`; annotations `description title default examples`. Per node, in this order: not an object: `<path> must be a schema object`; for each key in order, an annotation that is not lossless JSON: `<path>.<key> annotation must be lossless JSON data`, any other unknown key: `<path>.<key> is not a supported keyword (subset: type/oneOf/properties/required/additionalProperties/items/enum/const + annotations)`; `<path>.description must be a string`; `<path>.title must be a string`; both `type` and `oneOf`: `<path> cannot declare both type and oneOf`; neither, with one of `properties required additionalProperties items enum const` present: `<path>.<key> requires type or oneOf`; `oneOf` not an array of at least two: `<path>.oneOf must be an array of at least two schemas`; `type` an array: `<path>.type must be a single type string (type arrays are not supported)`; `type` otherwise invalid: `<path>.type must be one of object/array/string/number/integer/boolean/null`; a keyword on the wrong type, checked in the order `properties required additionalProperties items enum const`: `<path>.<key> is not supported on type "<type>"`; `<path>.properties must be an object of schemas`; `<path>.enum must be a non-empty array of <type> values`; `<path>.const must be a <type> value`; `<path>.const must be one of <path>.enum when both are declared`. Children are visited depth-first in order after the node's own checks (`<path>.properties.<name>`, `<path>.items`, `<path>.oneOf[<i>]`). After an object's children: `<path>.required must be an array of strings`, `<path>.required names "<key>" which is not in properties`, `<path>.additionalProperties must be a boolean`. After a union's branches, for each of the six sibling keywords present: `<path>.<key> is not supported beside oneOf`. The root path is `schema`. `(assert-object-json-schema schema)` adds, when nothing else is wrong and the root type is not `object`: `schema.type must be "object" (structured output is object-rooted)`.
9. `(validate-json-schema-value schema value [path "value"])` returns violation strings in walk order and never raises (`json-schema.ts:487-656`). A path prints as written; the empty path prints as `arguments` and property paths below it have no leading dot. Array items are `<path>[<i>]`. Templates: `"<path>" must be an object`; `missing required property "<path.key>"`; `"<path.key>" is not a declared property (additionalProperties: false)`; `"<path>" must be an array`; `"<path>" must be a string`; `"<path>" must be a number` (not a number); `"<path>" must be a finite JSON number` (`-0.0`, infinite or NaN); `"<path>" must be an integer`; `"<path>" must be a boolean`; `"<path>" must be null`; `"<path>" must be one of <array as JSON text>`; `"<path>" must be <const as JSON text>`; `"<path>" must match exactly one oneOf branch (matched <n>)`; `"<path>" must be a lossless JSON value`; `"<path>" must be a lossless JSON object`; `"<path>" must be a dense lossless JSON array`. For an object: missing required properties first in `required` order, then property violations in schema property order, then undeclared keys in value key order; only when there are none is the object itself checked for losslessness. A union counts the branches with no violation. A node with neither `type` nor `oneOf` accepts any lossless JSON value. Numbers compare with `=` in `enum` and `const`; an integer is an exact integer or an integral flonum.
10. `(validate-args parameter-spec args)` is rule 9 with the compiled parameter schema and the empty path.

**Tool definitions** (recon 04 "`defineTool`"; `tools/src/schema.ts:555-646`)

11. `make-tool` compiles the parameters (rule 5) and the output spec, and checks `timeout-ms` (`defineTool(<name>): timeoutMs must be a positive finite number`). The definition's `execute` validates the arguments with the empty path and raises the tool args error before the user body runs.
12. The definition's `present-call` and `present-result` return `#f`, and its `concurrency-safe?` returns `#f`, when the arguments do not validate; they run on replayed arguments and must not raise for that reason. `project-content` and `finalize-content` pass through unchanged. `render` and `presentation-meta` receive the arguments unvalidated.
13. `(project-tool-schema definition)` returns the tool schema (`name`, `description`, `parameters`, `deferLoading` only when true). It raises `tool "<name>" parameters must be lossless JSON before schema projection` when the parameters are not lossless JSON.
14. `make-raw-tool` performs no compilation and no argument validation.
15. `define-tool` builds the parameter spec from its clauses in clause order, with the JSON key defaulting to the parameter identifier as written and `required: true` added for `#:required`, and expands to `make-tool`.
16. In each body form of `define-tool` (`render`, `execute`, `presentation-meta`, `concurrency-safe?`, `present-call`, `present-result`) every parameter identifier is bound: to the argument's value when the arguments are an object that has the key, otherwise to the value of the parameter's `#:or` expression, or `#f` when it has none. `#:args id` also binds the whole argument value. `#:required` and `#:or` on one parameter is a syntax error, as are a duplicate parameter identifier or JSON key, and a missing `render` or `execute` form.

**Registry** (recon 04 "Tool registry view, restriction and admission"; `tools/src/index.ts:123-297`)

17. View of a scope: `inherited` is the global tools overlaid in order by every chain layer except the scope's own, the nearest ancestor winning a name. Each inherited name is a known name and a restrictable name; it is visible only if every layer on the chain, including the scope's own, admits it. A layer admits a name when each of its restrictions has `allow` containing it (when `allow` exists) and `deny` not containing it. Then the scope's own registrations are added, visible unconditionally, shadowing inherited names, and known. The global view is the global layer. Views are computed from the live registry on every read.
18. `tools-lookup`: with a tool set, `(tool-set-ref ts scope name)`; otherwise the visible definition. `tools-executable`: with a tool set, the same; otherwise the visible definition unless its registration has a `when` condition. `tools-definitions` lists the visible definitions in view order, or the tool set's. `tools-schemas` maps `project-tool-schema` over them.
19. `tools-resolve`: raise the cancel reason if already cancelled; take the agent's view once; for each visible tool in view order evaluate `when` (absent means enabled), one after another; a raise becomes the tool activation error unless the cancel event is ready by then, in which case the cancel reason is raised; check cancellation after each. The result's `tool-set-definitions` for another scope, or after `tool-set-dispose!`, is empty; for the agent it lists each admitted name whose current visible definition and current registration are still `eq?` to the admitted ones.
20. `tools-check-guards` runs the global guards, then each chain layer of `(tool-execution-agent exec)` from the farthest ancestor to the agent, each layer in insertion order. The first result that is not `#f` wins; a string becomes `(tool-guard-denial reason #f)`.
21. `tools-register!`, in order (the dsh check that a definition declares `output` with a `render` procedure is enforced by the constructors' contracts): `assert-supported-json-schema` on the output schema; `timeout-ms` not positive and finite raises `exn:fail:contract` `tool "<name>" timeoutMs must be a positive finite number`; the name `run_code` raises `tool name "run_code" is reserved for the PTC mode presentation transport and cannot be registered or shadowed`; a duplicate in the layer raises ``tool "<name>" is already registered (for a per-agent variant, register through that agent's `agent.ctx` instead)`` in the global layer and `tool "<name>" is already registered in this scope` in a scoped one.
22. `tools-restrict!`, in order: no scope: `tools.restrict() requires a scoped context (agent.ctx): a context-global restriction would mask every agent — deny the tool for the intended agent instead`; neither list: ``tools.restrict({}) is a no-op: pass `allow` and/or `deny` (an empty filter is almost always a materialized-empty-config bug)``; `run_code` named: `tools.restrict() cannot name reserved PTC mode presentation transport "run_code"; restrict end-capability tools instead`; a name that is not restrictable in the scope's current view: `tools.restrict() names unknown global tool "<a>"; known global tools: <names>` (plural `tools "<a>", "<b>"` for more than one; the known names sorted with `js-string<?` and joined with `, `, or `(none)`).
23. Executor selection for a scope: walk `(scope-chain-of scope)` nearest first and take the first key that has an executor record, else the root record; a missing record or a record whose executor was removed raises the tool executor unavailable error. A removed selection never falls through to an outer scope.
24. `tools-execute` selects the executor for the batch's agent and calls `tool-executor-execute`.
25. Records are kept per scope key in a weak `eq?` table on the service value, plus one root record.
26. `tools-set-executor!`: a scope that has a record with an executor raises `Only one tool executor may be registered in each scope`. Inside one effect: register each executor section with `system-prompt-section!` on the caller's context, with a text procedure that returns `""` unless this executor is the one selected for the assembling scope, and otherwise the section's string or its procedure applied to `(tools-definitions … scope tool-set)`; then store the record. The inverse removes the sections and sets the record's executor to `#f`, leaving the record in place.
27. The provider registered by the `tools` plugin: for an assemble context with `'scope` and `'tool-set`, select the scope's executor, call `(tool-executor-describe executor (tools-definitions … scope tool-set))`, and return its schemas with known names defaulting to the scope view's known names.

**Pipeline** (recon 04 "Guarded execution pipeline"; `tools/src/pipeline.ts`)

28. Lookup for execution: `get` when supplied, else `tools-executable` with the call's name, agent and tool set. A found tool for which `(reject name nested?)` returns a value is treated as not found by later stages; `nested?` is true when the input has a parent token.
29. `pipeline-execution-mode`: `'parallel` only when the tool resolves, has a classifier, and the classifier returns exactly `#t` without raising; otherwise `'exclusive`.
30. Creating the execution (`pipeline.ts:117-183`): make the token; the root call id defaults to the call id; look the tool up and, when found, ask `reject`; capture the definition's `finalize-content` and `project-content` now. The arguments must be lossless JSON. If they are not, the outcome is `'final-result` with the error result (rule 41) for `tool execution arguments must be losslessly JSON-serializable`, the execution's arguments are `absent`, and this wins over an already cancelled call. If the executor rejected: `'final-result` with the aborted-before-dispatch result when already cancelled, else with the error result of the rejection value; the finalizer is kept only in the cancelled case and the projector is dropped.
31. `pipeline-prepare`: rule 30; then if the caller's cancel event is ready, `'final-result` aborted-before-dispatch. Dispatch `tools/pre-execute`. A `pre-ask` goes through rule 32. Then, in this order: caller cancelled and the approval reported `cancelled`: `'post-result` aborted-before-dispatch; decision `pre-cancel`: `'post-result` aborted-before-dispatch; decision `pre-allow`: `tools-check-guards`; a `pre-deny` or a guard denial: `'post-result` with a failure whose content is one text block `Error: <reason>`, message `<reason>` and the denial's info; caller cancelled: `'post-result` aborted-before-dispatch; otherwise `'dispatch`. Any raise in this stage gives `'final-result` with its error result.
32. Approval (`pipeline.ts:440-481`): read the service with `(ctx-get ctx 'approval)`. None: deny with reason `tool "<name>" requires approval (not yet supported)`, or the ask's own reason when it has one, code `APPROVAL_UNAVAILABLE`. No agent: `tool "<name>" requires approval, but the call has no agent to route it through`, `APPROVAL_UNAVAILABLE`. Otherwise call `tool-approval-request` with the agent, tool name, call id, the ask's reason and display reason, and the execution's cancel event, and map: `'allowed-once` to allow; `'rejected` to `the user rejected tool "<name>"`, `APPROVAL_REJECTED`; `'cancelled` to `approval for tool "<name>" was cancelled`, `APPROVAL_CANCELLED`, and remember that the approval was cancelled; `'unavailable` to `tool "<name>" requires approval, but no approval channel is available`, `APPROVAL_UNAVAILABLE`. Every denial has info name `ApprovalError`.
33. `pipeline-dispatch` dispatches `tools/execute` with the body step of rule 34 innermost, then: normalise the result (rule 36); prepend the contexts deferred by the body to the result's additional contexts; if the caller's cancel event is ready and the result is a success, replace it with the cancellation result (rule 40), keeping the contexts. Return `'post-result`. A raise from a listener gives `'final-result` with its error result.
34. The body step (`pipeline.ts:263-293`): fuse the caller's cancel event with the one currently on the execution, which a listener may have replaced (`cancel-evt-any` with the listener's event first; when they are the same event use it as is). If the fused event is ready, return aborted-before-dispatch. Set the fused event on the execution. Look the tool up again (rule 28); none raises the tool not found error. Mark the body as invoked. Call the definition's `execute` with the arguments and the execution and wait for it; the pipeline never abandons a started body. Build the success result (rule 35); if the fused event became ready meanwhile, return the `ABORTED` result instead. On a raise: if the fused event is ready, the raised value has no harness identity, and it is `eq?` to the cancel reason or is an `exn:fail:abort`, the result is the error result of that value with info `AbortError` / `ABORTED`; otherwise its ordinary error result. Finally restore the listener's event on the execution.
35. Success result (`pipeline.ts:545-575`): the body value must be lossless JSON (`value is not lossless JSON`); validate it against the output schema with path `value`; call `render` with the arguments and the value (`output.render failed: <message>` on a raise, `output.render returned non-lossless JSON`); call `presentation-meta` when declared (the same two messages with `output.presentationMeta`). Each failure raises the tool output error with that single violation, or with the schema violations. Mark the result as concluding the turn when the body called `tool-conclude-turn!`. `presentation-meta` runs for nested calls as well.
36. Normalising a `tools/execute` result (`pipeline.ts:578-596`): a result this pipeline built for this execution is kept; a failure authored by a listener is rebuilt from its error, content, meta and contexts; a success authored by a listener is rebuilt through rule 35 from its value (the tool is looked up again; none raises tool not found), keeping its contexts. The pipeline recognises its own results by identity in a weak table that the pipeline value holds, keyed by the result and holding the token.
37. `pipeline-complete`: a `'final-result` outcome goes to rule 39. A `'post-result` outcome: call the captured `project-content` once (a result other than `#f` replaces the content); apply rule 38; if the caller's cancel event is ready and the result is a success, replace it with the cancellation result; rule 39. Any raise goes to rule 39 with its error result.
38. Post-execute (`pipeline.ts:494-533`): dispatch `tools/post-execute`. `post-block`: a failure whose content is the feedback, whose message is the feedback's text blocks joined by a newline, other blocks rendered as `[<type> content]`, or `tool result blocked by post-execute policy` when that is empty, with the decision's info and only the decision's contexts. `post-accept` with a value: on a failed result raise `exn:fail:contract` `tools/post-execute cannot replace the value of a failed result`; otherwise rebuild through rule 35 (tool looked up again). `post-accept` with content: replace the content only. Additional contexts are the result's followed by the decision's.
39. Finish (`pipeline.ts:381-426`): materialise the candidate, which means its content, meta, contexts and error must be lossless JSON; if that fails, materialise the error result of `tool result must be losslessly JSON-serializable`. Call the captured `finalize-content` exactly once; a result other than `#f` replaces the content; materialise again; if the finalizer or the second materialisation raises, the result is the error result of that raise and the finalizer is not called again. Close the execution to further changes, resolve the `tools/result` callbacks with `scoped-callbacks`, invoke them with containment, and return the result.
40. Cancellation results. After the body was invoked: content `Error: tool call aborted`, message `tool call aborted`, info `AbortError` / `ABORTED`. Before: content `Error: tool call aborted before dispatch`, message `tool call aborted before dispatch`, info `AbortError` / `ABORTED_BEFORE_DISPATCH`. Both keep the additional contexts of the result they replace. Cancellation replaces only successes; a denial or a tool failure that settles after cancellation is kept.
41. Error result of a raised value `v`: content one text block `Error: <message>`, message `(tool-error-message v)`, info `(harness-error-info v)`. `tool-error-message`: the exception message for an exception; the `message` of an object that has a string `message`; otherwise the `display` form; `<unprintable thrown value>` if producing that raises. A text block is the jobject `{type: "text", text}`.

**Batch scheduling** (recon 04 "Batch scheduling"; `tools/src/batch.ts`)

42. `execute-tool-batch`: an explicit `max-parallel-tool-calls` that is not a positive integer raises `exn:fail:contract` `maxParallelToolCalls must be a positive integer`. Parse each call's arguments: the empty string gives `{}`; valid JSON gives the parsed value; anything else gives the raw string.
43. Loop over the unscheduled calls: classify the first; `'parallel` makes the group all remaining calls, `'exclusive` makes it that one call. Run the group with limit `max-parallel-tool-calls`, or `(max-parallel)` read per group.
44. Running a group. Fill: while not aborted, calls remain, and fewer dispatches are in flight than the limit, take the next call; in a parallel group, for every call after the first, classify it again and stop filling when it is no longer parallel. Start it: when the batch has a log, append `tool/call {turn, step, callId, name, arguments}` with the raw text and remember its seq; call `pipeline-prepare`; a `'dispatch` outcome starts `pipeline-dispatch` in a new task without waiting for it, and that task, when it finishes, fills the call's slot itself and then adds the call's index to a completion queue; any other outcome fills the call's slot at once. After each start: commit ready slots, then note cancellation. Then repeat while dispatches are in flight: wait until the completion queue is not empty, remove exactly one index from it and from the in-flight set, commit ready slots (which may include slots of dispatches still counted as in flight), note cancellation, fill again.
45. Committing ready slots: advance over contiguous filled slots in model order; for each, call `pipeline-complete`, then, when the batch has a log, append `tool/result {turn, step, message, error?, meta?}` with surface op `'append` and sources the call's seq, where `message` is made by `dsh-llm` from the call id, the result content and the error flag, `error` is the result's info when it has one, and `meta` the result's meta when present; record the result and collect its additional contexts.
46. Cancellation: stop starting; started calls finish and commit; then every unstarted call of the group and every later call of the batch gets a `tool/call` event and the aborted-before-dispatch result, in order. The batch returns normally. A batch whose cancel event is already ready starts nothing.
47. Scheduler failure (a raise from classification, prepare, dispatch or complete, or from a session append): stop starting, wait for every dispatch in flight, then raise `exn:fail:tool-batch` with the cause and the committed results and contexts as `partial`.
48. `concluded?` is true when any committed result concludes the turn. Without a log no session events are written.
49. Ordering: `tools/pre-execute`, guards, `tools/post-execute`, `finalize-content`, `tools/result`, the `tool/result` append and context collection happen in model call order, one call at a time, on the task that called `execute-tool-batch`. Only `tools/execute` listeners and tool bodies overlap. `tool/call` events are appended in model order at start time and may interleave with earlier calls' `tool/result` events. With limit 1 execution is serial.

**System prompt** (recon 04 "System prompt assembly, refresh and rendering"; `system-prompt/src/index.ts`)

50. `system-prompt-assemble`, in order: `suppressed` is true when the global layer or any chain layer of the scope has a suppressor. Variables: every global provider in registration order, then each chain layer's, farthest first, the nearest value replacing an earlier one in place. Sections and contexts: `scoped-layers-merge`. Tool providers: the global ones, then each chain layer's, each called once; each schema is rebuilt as `{name, description, parameters, deferLoading?}`; known names accumulate the provider's known names or else its schema names. Sort the sections by `order`, ties by `js-string<?` on `name`. More than one section with `complete?` raises `multiple complete prompt sections are active: "<a>", "<b>"` (names as JSON strings). Resolve each section's text. Order the tools (rule 51). Contexts: drop those not `required?` when suppressed, sort stably by `order` only, resolve text. Dispatch `system-prompt/assemble`. The result is the returned presentation plus the tools; when a complete section exists the sections become that one section as resolved before the dispatch; when suppressed the contexts are filtered to the names of registered `required?` contexts.
51. Tool order (`index.ts:233-247`): a schema named `<unlisted-tools>` raises `tool provider returned reserved tool name "<unlisted-tools>" (reserved for toolOrder's rest entry)`. Without `toolOrder`: stable sort by `js-string<?` on name. With it: a listed name other than the rest entry that is not a known name raises `toolOrder lists unregistered tool "<x>"; known tools: <sorted names or (none)>` (plural `tools "<x>", "<y>"`); the result follows the configured list, with the unlisted tools sorted by name at the rest entry and listed names that are not visible left out.
52. `system-prompt-refresh-context` (`index.ts:589-609`): for each context of the accepted assembly in order, re-resolve it from the registered provider of that name when one exists, else keep the accepted value; when suppressed keep only those whose provider is `required?`. Then insert every registered `required?` context that was missing before the first entry whose registered order is greater, else at the end. Sections, tools and variables are unchanged.
53. `render-prompt`: for each section use the text as is when `interpolate?` is false, else interpolate (rule 54) with kind `section`; drop empty strings; join with a blank line. `render-context-sections` does the same per context with kind `context` and returns `{name, text}` for the non-empty ones. `join-context-sections`: the texts joined with a blank line; `""` when that is empty; otherwise `Current runtime context. This snapshot supersedes earlier runtime-context snapshots.`, a blank line, and the body. `render-context-snapshot` composes the two.
54. Interpolation (`index.ts:347-384`): scan for `{{`. When the text at that position is `{{`, characters other than braces, `}}`: the name must match `^[a-z][a-z0-9_]*$` (`malformed prompt variable reference "{{<name>}}" in <kind> "<owner>" (variable names match /^[a-z][a-z0-9_]*$/)`), must be a key of the variables (`unknown prompt variable "{{<name>}}" in <kind> "<owner>"; registered variables: <names joined with ", " or (none)>`), and must have a string value (`prompt variable "{{<name>}}" has no value for this assembly (<kind> "<owner>")`). When it is not such a group but `}}` occurs anywhere later: `malformed prompt variable reference at "<the 16 UTF-16 units from that position>…" in <kind> "<owner>" (references are complete simple {{name}} groups)`. When no `}}` follows, the `{{` is literal. Substituted values are not scanned again.
55. Order tables: `section-orders` and `context-orders` hold the names and numbers of `SECTION_ORDERS` and `CONTEXT_ORDERS` (`index.ts:136-186`; recon 04 "System prompt order tables and strings") with the dsh names as symbols. `system-prompt-section-order` and `system-prompt-context-order` read them and raise `exn:fail:contract` for an unknown name.

**Native executor**

56. `make-native-tool-executor`: no sections; `tool-executor-describe` returns `(tool-model-input (map project-tool-schema definitions) #f)`; `tool-executor-execute` is `(execute-tool-batch input pipeline max-parallel)` with a pipeline made from `ctx` and no `get` or `reject`. The default limit 10 applies only when the batch gives none.

## Racket design notes

- **One parameter list, two uses.** In dsh the schema is an object literal and the handler reads `args.name`; TypeScript inference ties them together. `define-tool` takes the parameters once and derives the JSON Schema, the validation and the handler's variable bindings from that list. The classes of error it removes: a handler reading an argument the schema does not declare (an unbound identifier at compile time instead of a silent `#f`); a schema property and its handler name drifting apart after a rename; a default applied in one callback and forgotten in another (`#:or` is stated once and used by every body form). `make-tool` is the same thing as a procedure, for definitions built at run time and for translated plugins.
- **Author specs stay jvalues.** The node constructors return jobjects in the dsh author form, so a translated plugin can pass its literal object unchanged, the compiler has one input representation, and the error paths and messages are those of dsh.
- **Structs and `match` for decisions and outcomes.** The tagged unions `PreToolDecision`, `PostToolDecision` and the stage results become structs. The invalid accept decision that dsh reports when it processes the decision is rejected by the constructor with the same message, which reaches the model through the same error-result path.
- **Private execution state in the execution value.** The five `WeakMap` side tables keyed by execution become private fields of `tool-execution`. The table of results the pipeline built stays a weak table, held by the pipeline value, because a listener can copy a result value.
- **Cancel events for `AbortSignal`.** A cancel event is an `evt`, so "wait for the work or for cancellation" is one `await` over a `choice-evt`. Signal fusion is `cancel-evt-any`. A tool body is never killed or broken by the pipeline; it observes the event and returns.
- **Generics for seams.** `gen:tool-executor` has two providers in dsh (native and PTC). `gen:tool-approval` lets this package call a service whose definition lives in a later package.
- **Batch pool on tasks.** Dispatches run as tasks; each fills its slot when it finishes and then adds its index to a completion queue. The scheduler removes one index per iteration, which reproduces the `Promise.race` loop of dsh, including when a slot of a finished dispatch is committed relative to the next `tool/call` append. A `choice-evt` over several finished tasks would pick at random.
- **Registry storage returns snapshots.** `named-entries` and `anonymous-entries` return lists; the JavaScript versions hand out live iterators. No reader in the covered packages adds entries while it iterates.
- **The batch log names the session.** dsh reads `agent.session`; this package cannot see the agent's fields, so `tool-batch-log` carries the session.
- **Racket-only additions**, for the coordinator's ADR list: the macro `define-tool` with its `#:or` and `#:args` options; the node constructors `v-string` to `v-one-of`, `param` and `parameters`; `gen:tool-approval` defined here; `call-with-tool-cancel`; the session field of `tool-batch-log`; the module `dsh-tools/cancel` (a re-export of `dsh-llm/cancel`); the exported dispatcher `dispatch-tools/change`. No configuration key is added.

## Work units

The package is split into three units. The interface between them is the set of public module exports listed in this document.

| Unit | Modules | Depends on |
|---|---|---|
| 1: scope, system prompt | `scope`, `cancel` (the re-export), `system-prompt`, `plugin/system-prompt` and their tests | `dsh-session/scope-core`, `dsh-llm/cancel`, `cordis`, `cordis-schema` |
| 2: schemas and tool data | `errors`, `json-schema`, `schema`, `tool` (data, `make-tool`, `make-raw-tool`, `define-tool`), `presentation`, `approval` and their tests | `dsh-session/lossless`, `dsh-session/types` (for `absent`), `dsh-util` |
| 3: registry and execution | `tools`, `pipeline`, `executor-native`, `plugin/tools`, `plugin/tool-executor-native`, `plugin/agent-tool-presentation`, `plugins`, `main` and their tests | units 1 and 2, `dsh-session`, `dsh-llm` |

Units 1 and 2 have no dependency on each other and can be built at the same time. Unit 3 starts when both export their modules; it can be written against this document before they are finished. Unit 2 owns `tool-execution` and the result structs, including the private fields and the constructor that unit 3 uses: `dsh-tools/private/execution` exports `(make-tool-execution input token arguments)`, `(tool-execution-state e)` (a mutable record with fields `deferred-contexts`, `concluded?`, `body-invoked?`, `caller-cancel`, `finalizer`, `projector`, `closed?`) and `(close-tool-execution! e)`.

## Tests

Tests live in `racket/dsh-tools/tests/`. Rows name the TypeScript suite to mirror and what it pins.

| Racket test file | Mirrors | Pins |
|---|---|---|
| `scope-test.rkt` | `packages/core/scope/tests/scope.spec.ts`, `store.spec.ts` | rules 1 to 4; disposal of a scope removes registrations made through it |
| `cancel-test.rkt` | the signal cases of `packages/core/tools/tests/execution-signal-types.spec.ts` | `dsh-tools/cancel` exports the bindings of `dsh-llm/cancel` (`eq?` procedures); reason identity and `cancel-evt-any` order as the pipeline uses them. The cancel API itself is tested in `dsh-llm` |
| `json-schema-test.rkt` | `packages/core/tools/tests/json-schema.spec.ts`, `properties.spec.ts` | rules 8 and 9, every message; validation is total on generated values |
| `schema-test.rkt` | `packages/core/tools/tests/schema.spec.ts` | rules 5 to 7 and 10 to 16, including output key order and `define-tool` syntax errors |
| `system-prompt-test.rkt` | `packages/core/system-prompt/tests/system-prompt.spec.ts`, `scoped.spec.ts`, `tool-order.spec.ts` | rules 50 to 55, every interpolation message, config validation at load, rollback on a raising change listener |
| `tools-test.rkt` | `packages/core/tools/tests/tools.spec.ts` (registration parts), `scoped.spec.ts`, `activation.spec.ts` | rules 17 to 27 |
| `pipeline-test.rkt` | `packages/core/tools/tests/tools.spec.ts` (output failures, post-execute, context order, the cancellation cases at `:1262-1870`, approval at `:879-1022`), `execution-mode.spec.ts` | rules 28 to 41 |
| `batch-test.rkt` | `packages/core/agent-loop/tests/tool-calls.spec.ts`, `tool-executors.spec.ts` | rules 42 to 49 and 23, with a session from `dsh-session` and the event sequence checked |
| `plugins-test.rkt` | `packages/core/agent-tool-presentation/tests/agent-tool-presentation.spec.ts`, the config case at `tools.spec.ts:55` | plugin mounting, removed config keys, `mode` required, executor per scope |

Fixtures: a set of small tools equal to `packages/test-support/tool-testkit` (echo, failing, slow with a gate event, concurrency-safe); a scripted approval provider implementing `gen:tool-approval`; a cancel source per test; an agent stand-in that is a struct used only as a scope key. A key-order fixture: the author specs of the tools `read` and `todo_write`, written with the node constructors, whose compiled `parameters` must equal, as `jvalue->string` text, the `parameters` of those tools under `initial` in `snapshots/session/agent-instructions/tool-schemas.expected.json` (read with `cordis-data`, which keeps key order). `todo_write` covers an array of closed objects with an `enum` and nested `required`. Tests sequence tasks with events, never with sleeps; every registration test disposes the fiber and observes the removal.

Acceptance gate: `raco test racket/dsh-tools` passes with no network; every numbered rule has a test that names it; the key-order fixture passes; a batch of two parallel calls and one exclusive call against a store-entered session writes `tool/call` and `tool/result` events in the order stated by rule 49.

## Open questions

1. **Kernel support for resolving listeners.** Settled: rule 39 uses `scoped-callbacks` of `dsh-session/scope-core`, which is built on `ctx-dispatch-callbacks` (cordis-kernel section 12, addendum 2). See [dsh-session.md](dsh-session.md), open question 1.
2. **Home of cancellation values.** Settled in the wave 3 review: the values live in `dsh-llm/cancel` and `dsh-tools/cancel` re-exports them, so there is one `exn:fail:abort` and one `cancelled?` (which also accepts `#f`). `dsh-llm/adapter-kit` keeps `check-cancel!`, which raises an `exn:fail:llm` with code `ABORTED`; rule 34 leaves that failure unchanged because it has a harness identity, and recognises as an unclassified cancellation only the cancel reason itself and `exn:fail:abort`. If `dsh-util` later wants these values lower, `dsh-llm/cancel` becomes the re-export.
3. **Fields of `exn:fail:harness`.** A failed tool result persists `{name, code}`, where `name` is the dsh error class name (`ToolArgsError`, `LlmError`, …). This contract therefore assumes that `exn:fail:harness` carries that name as well as the code, with accessors for both, and allows substructs. `dsh-llm.md` assumes only the code accessor. Recommended default: `dsh-util` gives the struct a `name` field that each substruct's constructor sets; this package builds every error through `dsh-tools/errors` and reads identity only through `harness-error-info`, so a different field layout changes one module. If the struct has no name, `harness-error-info` maps this package's own substructs to their names and reports any other harness error under the name `HarnessError`.
4. **The config schema for removed keys.** Settled for the schema: `cordis-schema` has `(schema-never)` (cordis-schema section 4), so the two fields are `(schema-never #:description …)`. Open for the error text: Cordis wraps schema issues in its `ValidationError` (`invalid config:` and one line per issue, `vendor/cordis/src/fiber.ts:19-35`), while a `cordis-schema` schema applied directly raises `exn:fail:schema` with the Schemastery text. Every wave 3 plugin with a config therefore follows the convention of [WAVE3.md](WAVE3.md) ("Config validation text"): a rejected config must fail the mount with `exn:fail:cordis:validation`. `plugins-test.rkt` pins that for `mode` and `maxParallelSubCalls`.
5. **Parameter names that are integer strings.** JavaScript would order a parameter named `"0"` before the others; a jobject keeps the written order. No dsh tool has such a parameter. Recommended default: `define-tool` and `parameters` reject a name that is a canonical non-negative integer string, with an error that states this reason.
6. **Module path of the PTC executor plugin.** Recommended default: `dsh-ptc/plugins` exports `plugin-table` as every package does, and the selector looks the name up there.
7. **Approval provider.** Recommended default: the `approval` service value of `dsh-interaction` implements `gen:tool-approval`; a value that does not is treated as "no approval service" and logged once at `warning`.
8. **Obtaining the exact effect disposer of a mounted fiber.** `scope-raw-dispose` is specified as a procedure that disposes the fiber. If the kernel exposes the disposer of the `ctx.plugin()` effect, return that instead so an outer effect can adopt it as a child.
