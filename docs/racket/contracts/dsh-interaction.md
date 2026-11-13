# Interface contract: `dsh-interaction`

This is the binding interface for `racket/dsh-interaction/`. It covers the approval seam (`approval`), permission presets (`permissionPresets`), the question seam (`userQuestions`) and the `ask_user_question` tool, slash commands (`commands`), the two tool guards, plan mode (`planMode`) with `exit_plan_mode`, the `todo_write` tool, and session and message feedback (`sessionFeedback`, `messageFeedback`). Sources: [recon 10](../recon/10-collab.md), `packages/{interaction,guard,plan,todo,feedback}/*/src` at commit `e8f7b93a3`, `packages/core/tools/src/pipeline.ts` for the approval caller. When this document and the TypeScript disagree about behaviour, the TypeScript is right and this document gets fixed. When they disagree about names and argument order of the Racket surface, this document is right. Read [dsh-session.md](dsh-session.md), [dsh-tools.md](dsh-tools.md) and [dsh-agent.md](dsh-agent.md) first; this contract uses their vocabulary (`absent`, `define-session-event`, `define-tool`, cancel events, `gen:agent`, the `agent/*` payloads, scoped dispatch).

Package: directory `racket/dsh-interaction/`, collection `dsh-interaction`, `(define deps '("base" "cordis" "cordis-data" "cordis-schema" "dsh-util" "dsh-session" "dsh-llm" "dsh-tools" "dsh-agent"))`, `(define build-deps '("rackunit-lib" "dsh-test-support"))`. It requires no other wave 4 package: every service of a sibling package is reached by service key at run time through `dsh-interaction/ports`.

Corrections to the brief, from recon 10: dsh has no `enter_plan_mode` tool, no rule lists in a permission preset, no persistent "always allow", and no terminal answerer. A preset is one sandbox mode and one approval policy. The approval policy is `ask` or `never`; an approval outcome is one of four words, and `allowed-once` is the only grant.

## Scope

| dsh package | npm name | Status |
|---|---|---|
| `packages/interaction/commands` | `@deepseek-ai/dsh-commands` | native. The typert Remote methods become the alist `commands-remote-methods`; `dsh-web` mounts them. |
| `packages/interaction/user-approval` | `@deepseek-ai/dsh-user-approval` | native. The service value implements `gen:tool-approval` of `dsh-tools/approval`. `AbortSignal` becomes a cancel event. |
| `packages/interaction/permission-presets` | `@deepseek-ai/dsh-permission-presets` | native. The confining shell (`dsh-exec`) is read through a port; `sandbox/mode` is appended as a literal event. |
| `packages/interaction/user-questions` | `@deepseek-ai/dsh-user-questions` | adapted: the Remote stream `attachWait` (an `AsyncIterable`) becomes a procedure that returns a claim with one remaining duration and a release event. Everything else is native. |
| `packages/interaction/tool-ask-user` | `@deepseek-ai/dsh-tool-ask-user` | native |
| `packages/guard/repeat-tool-reminder` | `@deepseek-ai/dsh-repeat-tool-reminder` | native |
| `packages/guard/timeout-policy` | `@deepseek-ai/dsh-tool-call-timeout-policy` | native, with a private deadline helper until `dsh-util` exports one |
| `packages/plan/plan-mode` | `@deepseek-ai/dsh-plan-mode` | native |
| `packages/todo/tool-todo` | `@deepseek-ai/dsh-tool-todo` | native |
| `packages/feedback/command-feedback` | `@deepseek-ai/dsh-command-feedback` | native |
| `packages/feedback/message-feedback` | `@deepseek-ai/dsh-message-feedback` | native. Session persistence (`dsh-session-store`) is read and written through a port. |

Not applicable in this port: the React packages `ui-approval`, `ui-user-questions`, `ui-plan`, `ui-commands`, `ui-message-feedback` and `ui-permission-presets` (replaced by the browser UI of `dsh-web`); the zod state schemas of projections (the fold functions keep states well formed); `packages/credentials/authorization`, which recon 10 describes but which belongs to `dsh-platform`. The answerers themselves are not in this package: the SDK answerers are in `dsh-sdk`, the browser answerers in `dsh-web`, and the headless profile has none.

## Modules

| Module | Provides |
|---|---|
| `dsh-interaction` (`main.rkt`) | re-exports `errors`, `approval`, `permission-presets`, `user-questions`, `commands`, `plan-mode`, `todo`, `feedback`, `message-feedback` |
| `dsh-interaction/ports` | the consumer-owned ports and their wrapper procedures (Services, "Ports") |
| `dsh-interaction/errors` | `exn:fail:user-question`, its constructor, codes and `restore-user-question-error` |
| `dsh-interaction/approval` | Service Definition `approval`, the event `approval/request`, the session events `approval/policy`, `approval/asked`, `approval/decided`, `set-approval-policy!`, `approval-state-projection`, the two policy sentences |
| `dsh-interaction/permission-presets` | Service Definition `permissionPresets`, the event `permission-presets/catalog-changed`, the session event `permission/preset`, `derive-preset`, `permissions-projection-apply`, `permission-presets-remote-methods` |
| `dsh-interaction/user-questions` | Service Definition `userQuestions`, the event `user-questions/request`, question, answer and request data, `user-questions-projection`, `user-questions-remote-methods` |
| `dsh-interaction/tool-ask-user` | `make-ask-user-tool`, the two description texts, `pending-notice` |
| `dsh-interaction/commands` | Service Definition `commands`, the event `commands/change`, the session events `command/run` and `command/done`, `parse-command`, result constructors, invocation accessors, the first-party table (`builtin-command-tokens`, `builtin-command-name`, `resolve-command`), `commands-remote-methods` |
| `dsh-interaction/guard/repeat-tool-reminder` | `canonical-arguments`, `preview-arguments`, `wildcard->regexp`, `validate-thresholds`, the two reminder texts |
| `dsh-interaction/guard/timeout-policy` | `tool-timeout-result`, `install-timeout-policy!` |
| `dsh-interaction/plan-mode` | Service Definition `planMode`, the session event `plan/mode`, `plan-projection`, `make-exit-plan-mode-tool`, the texts of Behaviour rules 62 to 70 |
| `dsh-interaction/todo` | the session event `todo/write`, `todos-projection`, `make-todo-write-tool`, `->todo-list` |
| `dsh-interaction/feedback` | Service Definition `sessionFeedback`, the session event `feedback/record`, `feedback-categories`, `record-feedback!`, `session-feedback-remote-methods` |
| `dsh-interaction/message-feedback` | Service Definition `messageFeedback`, the event `feedback/committed`, the session events `feedback/message-put` and `feedback/message-delete`, `current-feedback-items`, `message-feedback-remote-methods` |
| `dsh-interaction/plugin/<short-name>` | one module per row of Plugins, each providing `plugin` |
| `dsh-interaction/plugins` | `plugin-table` |

Private modules, suggested: `private/deadline.rkt` (rule 58), `private/timed-wait.rkt` (rules 33 to 35), `private/serial.rkt` (a FIFO of thunks run one at a time as tasks, used by message feedback), `private/contained.rkt` (the contained emit of rule 5). Other packages never require them.

## Data

Values that are logged, sent to a user interface or returned by a Remote method are jobjects with the dsh keys in the dsh order (ADR 0015). Process-local values are structs. `cancel` is a cancel event of `dsh-llm/cancel`.

### Session events

Declared with `define-session-event` of `dsh-session`, each in the module of its owner. Fields are in dsh write order. None is surface-eligible or ignorable; none enters the model transcript.

```racket
;; dsh-interaction/approval      source: packages/interaction/user-approval/src/{index,types}.ts
(define-session-event approval/policy #:type "approval/policy"
  #:fields ([policy approval-policy?] [source (lambda (v) (equal? v "delegation")) #:optional]))
(define-session-event approval/asked #:type "approval/asked"
  #:fields ([id string?] [tool-name "toolName" string?] [call-id "callId" string? #:optional] [reason string? #:optional]))
(define-session-event approval/decided #:type "approval/decided"
  #:fields ([id string?] [outcome approval-outcome-string?]))
;; dsh-interaction/permission-presets
(define-session-event permission/preset #:type "permission/preset" #:fields ([preset string?]))
;; dsh-interaction/commands      source: packages/interaction/commands/src/types.ts
(define-session-event command/run #:type "command/run"
  #:fields ([command-id "commandId" string?] [name string?] [args string? #:optional] [source jobject?]))
(define-session-event command/done #:type "command/done"
  #:fields ([command-id "commandId" string?] [kind command-result-kind?] [text string? #:optional]
            [source-event-seq "sourceEventSeq" session-seq? #:optional]))
;; dsh-interaction/plan-mode
(define-session-event plan/mode #:type "plan/mode" #:fields ([active boolean?]))
;; dsh-interaction/todo
(define-session-event todo/write #:type "todo/write" #:fields ([todos (listof todo-item?)]))
;; dsh-interaction/feedback and dsh-interaction/message-feedback
(define-session-event feedback/record #:type "feedback/record"
  #:fields ([text string? #:optional] [category feedback-category? #:optional]))
(define-session-event feedback/message-put #:type "feedback/message-put"
  #:fields ([session-id "sessionId" string?] [item message-feedback-item?]))
(define-session-event feedback/message-delete #:type "feedback/message-delete"
  #:fields ([session-id "sessionId" string?] [message-id "messageId" string?]))
```

`source` of `command/run` is always `{kind: "user"}`. The sandbox event `sandbox/mode {mode}` is owned by `dsh-exec`; this package appends it with `(make-session-event-input "sandbox/mode" (jobj [mode m]))` and reads it in a projection by its type tag. The plugin that owns a declaration registers it in the store's catalogue from a nested fiber, `(ctx-inject ctx '(sessions) (lambda (child) (sessions-register-event-type! child type)))`, so the plugin's own inject list stays the dsh list; without a `sessions` service the appends are accepted unchecked (dsh-session, open question 4).

### Approval

```racket
approval-policies                         ; '("ask" "never")
(approval-policy? v)                      ; one of the two strings
(approval-outcome? v)                     ; 'allowed-once 'rejected 'cancelled 'unavailable
(approval-outcome-string? v)              ; the same four words as strings, the logged form
(approval-request? v)                     ; the struct of dsh-tools/approval: (agent tool-name call-id reason display-reason cancel)
never-sentence ask-sentence               ; the two runtime-context sentences, rule 10
```

An approval request is the `approval-request` struct of `dsh-tools`. `call-id` and `reason` are strings or `#f`; `display-reason` is `#f` or a jobject `{en, <locale>…}` and is never logged; `cancel` is a cancel event, `never-cancelled` when the caller has none. Tool arguments are not part of a request. A request id is a fresh lowercase version 4 UUID.

### Permission presets

A preset spec is the jobject `{sandbox, approval, name?, description?}` with `sandbox` one of `"read-only"`, `"workspace-write"`, `"danger-full-access"` and `approval` an `approval-policy?`. A preset option is `{value, name, description?}`. The catalog is `{options, defaultOptions, defaultPreset}`. Constants: `custom-preset` `"custom"`, `auto-preset` `"auto"`, `auto-preset-spec` `{sandbox: "danger-full-access", approval: "ask"}`.

### Questions and answers

```racket
(question-item? v)        ; jobject {id, question, detail?, header?, options?: [{label, description?}], multiSelect?, intent?}
(question-answer? v)      ; jobject {answers: [{id, selected: [string…], custom?}]}
(struct question-request (questions agent cancel wait) #:transparent)
(make-question-request questions #:agent [agent #f] #:cancel [cancel #f] #:wait [wait #f]) -> question-request?
(struct wait-claim (remaining-ms released))        ; remaining-ms : exact-nonnegative-integer?; released : evt
```

`questions` is a list of `question-item?`. `agent` is an agent or `#f`. `cancel` is a cancel event or `#f`. `wait` is `#f` or the jobject `{callId}` or `{callId, timed: true}`. `intent` is `{kind: "plan-review", approve, callId?}` or `{kind: "approval", approve, reject, always?, subject?: {name, icon?}, display?: {question, detail?, approve?}}`; `display` values are localized maps `{en, <locale>…}`. A pending result is the jobject `{pending: true, callId}`.

### Commands

```racket
(command-result? v)                       ; jobject {kind: "success", text?, sourceEventSeq?} or {kind: "error", text}
(command-result-kind? v)                  ; "success" or "error"
(command-success [text absent] #:source-event-seq [seq absent]) -> command-result?
(command-error text) -> command-result?   ; text must contain a non-blank character
(command-descriptor? v)                   ; jobject {definitionId?, name, description, input?: {hint, attachments?}}
(struct command-invocation (command-id agent raw-input attachments cancel))   ; attachments : (listof jobject?) image and file blocks
(command-definition? v)                   ; opaque
(command-definition-descriptor d) (command-definition-handler d) (command-definition-record-input? d)
(struct parsed-command (name raw-input) #:transparent)
```

A command id is the string `cmd-<8 hex digits>-<n>`: the first eight characters of a UUID drawn once per service value, and a counter that starts at 1. A submitted attachment is the jobject `{type: "image", mediaType, data, name?}` (base64 `data`) or `{type: "file", receiptId}`. A command execution is the jobject `{commandId, result}`. A handler is `(-> command-invocation? command-result?)` and may wait.

### Plan, todos, feedback

A todo item is the jobject `{content, status}` with `status` one of `"pending"`, `"in_progress"`, `"completed"`. `feedback-categories` is the list `"task-result"`, `"instruction-following"`, `"product-interaction"`, `"service-stability"`, `"resource-cost"`, `"security-privacy-permission"`, `"other"`, in that order (`packages/feedback/command-feedback/src`). A message feedback item is the jobject `{messageId, rating, note?, category?, version, createdAt, updatedAt}` in that key order, with `rating` `"positive"` or `"negative"`, `note` holding a non-blank character, `version` a UUID, the two times safe non-negative integers and `updatedAt >= createdAt`. A feedback result is `{ok: true, value}` or `{ok: false, error}`; the error objects are listed in rule 80.

### Projection states

Each is a `projection-definition` of `dsh-llm/ports`. States are jvalues; `null` is `'null`.

| Binding | Key | `stateVersion` | State, keys in order | Wire view | In summaries |
|---|---|---|---|---|---|
| `approval-state-projection` | `approvalState` | 1 | `{policy, turnOpen}`; initially `{null, false}` | none | no |
| made by the presets service | `permissions` | 2 | `{preset, sandbox, approval, seeded}`; initially three `null` and `false` | `{currentValue}` | yes |
| `user-questions-projection` | `userQuestions` | 2 | `{inheritedEventCount, timed, questions: {active, settled}}` | `{active: [{callId, questions, state}], settled: [{callId, answers}]}` | yes |
| `plan-projection` | `plan` | 4 | `{active, wanted, running, activeAtLastHeader, entered}`; initially `{false, null, null, null, false}` | `{active, pending}` | yes |
| `todos-projection` | `todos` | 2 | a list of todo items, or `null` | the state | no (`summary?` is `#f`) |

`state` of an active question is `"open"` or `"continued"`. `running` is `null` or `{commandId, wanted}`.

### Errors

```racket
(struct exn:fail:user-question exn:fail:harness ())     ; dsh UserQuestionError
(make-user-question-error message code #:cause [cause #f]) -> exn:fail:user-question?
user-question-error-codes
(restore-user-question-error v) -> any/c
```

`user-question-error-codes` lists `ASK_ABORTED`, `EMPTY_QUESTIONS`, `CALLER_NOT_LIVE`, `DELEGATED_CALLER`, `BAD_INTENT`, `NO_PROVIDER`, `BAD_TIMEOUT`, `DUPLICATE_WAIT`, `ASK_TIMED_OUT`, `REPLY_QUEUED`, `BAD_ANSWER`, plus `ASK_CANCELLED` (raised by an answerer when the human dismisses) and `PROVIDER_ERROR` (raised by the SDK bridge). The persisted identity is name `UserQuestionError` and the code. `restore-user-question-error` returns `v` when it is already an `exn:fail:user-question`; builds one from a jobject or hash `{name: "UserQuestionError", message, code}` whose `message` and `code` are strings, with `v` as cause; and returns `v` unchanged otherwise (`user-questions/src/index.ts:65`). Where dsh throws a plain `Error` this package raises `exn:fail` with the same message; where dsh throws `TypeError`, `exn:fail:contract`. The timeout result of rule 59 has identity `ToolTimeoutError` / `TOOL_TIMEOUT` and is built as a result, never raised.

## Services

`x` is a context or a handle for the service; "the caller's context" is `(use-context x)`. Each service value keeps the context of the plugin that created it and dispatches its events through that context.

### Ports (`dsh-interaction/ports`)

Services owned by sibling wave 4 packages are called only through this module, with the convention of [WAVE3.md](WAVE3.md) and of the sibling contracts: each port is a generic interface declared here (provider value first), and each has a wrapper that takes a context, reads the service with `ctx-get`, calls the method when the mounted value implements the interface (test doubles and providers that adopt it do), and otherwise calls the owner's procedure named in the third column, resolved once with `dynamic-require`. A missing module or binding raises `exn:fail` `dsh-interaction: port <name> cannot reach <module> <binding>`.

```racket
(define-generics confining-shell-port (confining-shell-mode confining-shell-port))            ; -> (or/c string? #f)
(define-generics command-attachment-port (command-attachments-admit command-attachment-port parts))   ; -> (listof jobject?), waits
(define-generics feedback-persistence-port
  (feedback-persistence-stat feedback-persistence-port id)                 ; -> any/c, #f when no stored session has the id; waits
  (feedback-persistence-open feedback-persistence-port id access))         ; access : 'read or 'write; -> a handle; waits
(define-generics feedback-handle
  (feedback-handle-header feedback-handle)                                 ; -> session-header?
  (feedback-handle-inherited-event-count feedback-handle)                  ; -> session-log-offset?
  (feedback-handle-read feedback-handle offset length)                     ; length : integer or #f; -> (listof session-event?), waits
  (feedback-handle-append! feedback-handle events)                         ; -> void?, waits
  (feedback-handle-flush! feedback-handle)                                 ; -> void?, waits
  (feedback-handle-close! feedback-handle))                                ; -> void?, waits
```

| Wrapper | Service key | Assumed owner procedure |
|---|---|---|
| `(port-shell-sandbox-mode ctx) -> (or/c string? #f)` | `shell` | `dsh-exec/shell` `shell-sandbox-mode` |
| `(port-attachments? ctx) -> boolean?`; `(port-admit-command-images ctx parts) -> (listof jobject?)`, `parts` the submitted image jobjects without `type` changes, result one image block `{type: "image", attachment: <ref>}` per part in order | `attachments` | `dsh-fs/attachment` `attachments-admit-prompt-content`; a failure is a harness error named `AttachmentError` |
| `(port-persistence-stat ctx id)`, `(port-persistence-open ctx id access)`, `(port-handle-header h)`, `(port-handle-inherited-event-count h)`, `(port-handle-read h [offset 0] [length #f])`, `(port-handle-append! h events)`, `(port-handle-flush! h)`, `(port-handle-close! h)` | `sessionPersistence` | `dsh-session-store/persistence`: `session-persistence-stat`, `session-persistence-open`, `session-handle-header`, `session-handle-inherited-event-count`, `session-handle-read` (its first value), `session-handle-append!`, `session-handle-flush!`, `session-handle-close!` |
| `(port-anonymous-user-id) -> string?` | none (a library) | `dsh-platform/anonymous-user-id` `get-or-create-anonymous-user-id` |

The projection registry and the settings opt-out use `gen:projection-port` and `gen:settings-port` of `dsh-llm/ports`. `agents`, `sessions`, `tools` and `systemPrompt` are used through their wave 3 definitions.

Stable surface for siblings. Other wave 4 and wave 5 packages reach this package by these names, which are part of the contract: `commands-register!` and the `command-invocation-…` accessors, `command-success`, `command-error`; `permission-presets-current`; `user-questions-ask`; `approval-request!` and the fact that the `approval` value implements `gen:tool-approval`; the event names `approval/request`, `user-questions/request`, `commands/change`, `permission-presets/catalog-changed` and `feedback/committed`.

### `approval` (key `'approval`)

`(define-service approval 'approval #:contract approval-service?)` in `dsh-interaction/approval` defines `approval-key`, `approval-ref`, `approval-get` and `provide-approval`. The value is an opaque `approval-service` struct that implements `gen:tool-approval`: `(tool-approval-request value request)` is rule 6 on that value.

```racket
(approval-request! x request) -> approval-outcome?            ; request : approval-request?; waits
(approval-set-policy! x agent policy) -> void?
(approval-override-of x session) -> (or/c approval-policy? #f)
(approval-config-policy x) -> approval-policy?                ; the configured default (dsh config.policy)
(set-approval-policy! session policy) -> session-event?       ; not a service procedure; needs only the session
```

| Procedure | Semantics and errors | Effects on the caller's context |
|---|---|---|
| `approval-request!` | Rules 6 to 8. Raises `exn:fail` outside an open turn, before anything is appended; raises when either audit append fails. | none |
| `approval-set-policy!` | Rule 9. | none; one `approval/policy` append and one injected message |
| `approval-override-of` | The `policy` of the `approvalState` projection, `#f` for `null`. | none |
| `set-approval-policy!` | Raises `exn:fail:contract` `approval policy must be one of "ask" or "never"` for any other value; appends `approval/policy {policy}`. The only durable write path of this package for the policy. | none |

Waiting and cancellation: `approval-request!` waits for the answerers and is cancelled by the `cancel` field of the request (rule 7). A break of the calling task propagates; the audit pair is then left open, as in dsh when the process dies.

Answerers. An answerer is a listener of `approval/request`, registered by the package that owns a human channel through `on-approval/request`, on the context of the agent it serves or on an unscoped context. It receives the request and `next`. It returns an `approval-outcome?` symbol, or calls `(next)` to pass the request on. It must stop waiting when the request's cancel event becomes ready. The innermost step returns `'unavailable`. Three compositions exist: headless (no listener; every ask resolves `'unavailable`, which the tool pipeline turns into an `APPROVAL_UNAVAILABLE` failure, so the headless profile fails closed), SDK and ACP (`dsh-sdk`; wire forms in recon 10 "Approval"), and the browser (`dsh-web`, through its forwarded waterfall). A translated plugin or a wire layer that holds the outcome as a string converts it to the symbol before returning.

### `permissionPresets` (key `'permissionPresets`)

`(define-service permission-presets 'permissionPresets #:contract permission-preset-service?)` in `dsh-interaction/permission-presets`.

```racket
(permission-presets-names x) -> (listof string?)
(permission-presets-catalog x) -> jobject?                    ; Remote "catalog"
(permission-presets-current x session) -> string?
(permission-presets-resolve x name) -> jobject?               ; a preset spec
(permission-presets-option-of x name) -> jobject?
(permission-presets-set! x session name) -> void?
(permission-presets-register-auto! x admit) -> disposer?      ; admit : (-> any), must not wait
(permission-presets-default-preset x) -> string?
(derive-preset state presets auto? default-sandbox default-approval) -> string?    ; pure, rule 14
permission-presets-remote-methods                             ; (list (cons "catalog" permission-presets-catalog))
```

| Procedure | Semantics and errors | Effects on the caller's context |
|---|---|---|
| `permission-presets-names` | Configured keys in declaration order, then `"auto"` while an Auto integration is registered. | none |
| `permission-presets-catalog` | `options` covers the names, `defaultOptions` the configured presets only. | none |
| `permission-presets-current` | Rule 14 on the session's `permissions` state. Raises `permission: presets are not ready; await plugin activation before creating or restoring a session` while the projection is still registering. | none |
| `permission-presets-resolve` | Raises `permission: unknown preset "<name>" (known: <names joined with ", ">)`. | none |
| `permission-presets-option-of` | `"custom"` gives `{value: "custom", name: "Custom", description: "Current sandbox and approval settings do not match a preset."}`; otherwise `{value: name, name: spec.name or name, description?}`. | none |
| `permission-presets-set!` | Rule 15 with the silent policy write. | none |
| `permission-presets-register-auto!` | Rule 17. A second registration raises `permission: preset "auto" is already registered`. | one effect `permissionPresets.registerAuto()`; its inverse withdraws the preset |
| `permission-presets-default-preset` | The volatile config field `defaultPreset` read at call time, else the preset inferred at load. | none |

None of these waits. The service enforces nothing: execution reads the sandbox and approval folds.

### `userQuestions` (key `'userQuestions`)

`(define-service user-questions 'userQuestions #:contract user-question-service?)` in `dsh-interaction/user-questions`.

```racket
(user-questions-ask x request) -> question-answer?                         ; waits
(user-questions-ask-timed x request call-id timeout-ms) -> jobject?        ; an answer or {pending: true, callId}; waits
(user-questions-answer! x agent call-id answer) -> boolean?                ; Remote "answer"
(user-questions-attach-wait x agent call-id cancel) -> (or/c wait-claim? #f)   ; Remote stream "attachWait"
user-questions-remote-methods                                              ; "answer" and "attachWait"
```

| Procedure | Semantics and errors | Effects on the caller's context |
|---|---|---|
| `user-questions-ask` | Rules 27 to 31. Raises `exn:fail:user-question`. | none |
| `user-questions-ask-timed` | Rule 32. `request` must have an agent. | none |
| `user-questions-answer!` | Rule 37. `#f` when no continued question has that call id. Raises `REPLY_QUEUED` and `BAD_ANSWER`. | none |
| `user-questions-attach-wait` | Rule 35. `#f` when the agent has no live timed wait under that call id. | none |

Waiting and cancellation: `user-questions-ask` is cancelled by the request's cancel event and raises `ASK_ABORTED`; `user-questions-ask-timed` additionally by its deadline, which is a result and not an error. A claim returned by `user-questions-attach-wait` is held until `cancel` becomes ready or the wait ends; `(wait-claim-released c)` becomes ready then. Disposal of the service closes every live wait with `ASK_ABORTED`.

Answerers. An answerer is a listener of `user-questions/request`, registered through `on-user-questions/request` on the context of the agent it serves or on an unscoped context. It receives the `question-request` and `next`, returns a `question-answer?` that names each question id exactly once, or calls `(next)`. A dismissal by the human is `(raise (make-user-question-error "the user cancelled ask_user_question" "ASK_CANCELLED"))`. It must stop when the request's cancel event becomes ready. The innermost step raises `NO_PROVIDER`. Headless has no answerer, so a blocking question fails with `NO_PROVIDER` and a timed one ends as pending (rule 32); the SDK bridge (`dsh-sdk`) and the browser (`dsh-web`) are the two answerers.

### `commands` (key `'commands`)

`(define-service commands 'commands #:contract command-runtime?)` in `dsh-interaction/commands`. The dsh method `find(agent, name)` is `commands-find`.

```racket
(commands-register! x #:name name #:description description #:handler handler
                    #:definition-id [id absent] #:input [input absent] #:record-input? [record? absent]) -> disposer?
(commands-list x agent) -> (listof command-descriptor?)                    ; Remote "list"
(commands-find x agent name) -> (or/c command-definition? #f)
(commands-execute x agent line attachments cancel) -> (or/c jobject? #f)   ; Remote "execute"; waits
(commands-register-file-receipt-resolver! x resolver) -> disposer?        ; resolver : (-> agent? string? (or/c jobject? #f))
(parse-command line) -> (or/c parsed-command? #f)
builtin-command-tokens                                                     ; rule 49
(builtin-command-name descriptor) -> (or/c string? #f)
(resolve-command token descriptors) -> (or/c command-descriptor? #f)
commands-remote-methods                                                    ; "list" and "execute"
```

| Procedure | Semantics and errors | Effects on the caller's context |
|---|---|---|
| `commands-register!` | Rule 41. Registers in the scope layer of the caller's context: the global layer for an unscoped context, a per-agent shadow for a context under `(agent-ctx a)`. | one effect `commands.register()`; emits `commands/change` on registration and on disposal |
| `commands-list` | The effective descriptors (global entries overlaid by the scope chain of `agent`), sorted ascending with `js-string<?` on `name`. | none |
| `commands-find` | The effective definition, or `#f`. | none |
| `commands-execute` | Rules 43 to 48. `#f` when `line` is not command syntax or names no command; nothing is logged then. | none |
| `commands-register-file-receipt-resolver!` | One resolver per service; a second raises `commands: a file receipt resolver is already registered`. | one effect; its inverse clears the slot if it still holds that resolver |

Waiting and cancellation: `commands-execute` waits for attachment admission and for the handler; `cancel` (a cancel event, `never-cancelled` when the caller has none) ends the wait for the handler and reaches the handler as `(command-invocation-cancel i)`.

### `planMode` (key `'planMode`)

`(define-service plan-mode 'planMode #:contract plan-mode-controller?)` in `dsh-interaction/plan-mode`. The dsh method `get(agent)` is `plan-mode-state`.

```racket
(plan-mode-state x agent) -> jobject?                 ; {active} or {active, pending}
(plan-mode-set! x agent active?) -> (or/c 'committed 'queued 'cancelled 'noop)
```

Rules 62 to 64. Neither waits; neither registers an effect. Plan mode restricts nothing: the guidance section is its only effect on a request.

### `sessionFeedback` (key `'sessionFeedback`) and `messageFeedback` (key `'messageFeedback`)

```racket
(define-service session-feedback 'sessionFeedback #:contract session-feedback-service?)     ; dsh-interaction/feedback
(session-feedback-record! x request) -> jobject?      ; request : {sessionId, text?, category?}; Remote "record"
(record-feedback! session #:text [text absent] #:category [category absent]) -> session-event?
(define-service message-feedback 'messageFeedback #:contract message-feedback-service?)     ; dsh-interaction/message-feedback
(message-feedback-list x request) -> jobject?         ; request : {sessionId}; waits
(message-feedback-put! x request) -> jobject?         ; request : {sessionId, messageId, rating, note?, category?, ifVersion}; waits
(message-feedback-delete! x request) -> jobject?      ; request : {sessionId, messageId, ifVersion}; waits
(current-feedback-items session-id events) -> (listof jobject?)   ; pure, rule 79
```

Rules 76 to 83. `ifVersion` is a version string or `'null`. The three message procedures take no cancel event; an operation that has started its durable write completes it when the caller's wait is broken. Disposal of the service refuses new operations and waits for the queued ones.

## Events

Declared in the Service Definition module of their owner. The modules export the `on-…` and `…-name` bindings and not the generated dispatchers: each event is dispatched only by its owner, through `scoped-dispatch` or `scoped-callbacks` of `dsh-tools/scope`.

```racket
(define-event approval/request 'approval/request #:mode waterfall #:args (approval-request?) #:result any/c)
(define-event permission-presets/catalog-changed 'permission-presets/catalog-changed #:mode emit #:args ())
(define-event user-questions/request 'user-questions/request #:mode waterfall #:args (question-request?) #:result question-answer?)
(define-event commands/change 'commands/change #:mode emit #:args ())
(define-event feedback/committed 'feedback/committed #:mode parallel #:args (hash?))
```

| Event | Mode | Arguments and result | Dispatched by, when | Scope key | Guarantees |
|---|---|---|---|---|---|
| `approval/request` | waterfall | `(request next)`; an `approval-outcome?` | `approval-request!`, once per request, only under policy `ask` and only when the request was not already cancelled | the request's agent, no base filter | The innermost step returns `'unavailable`. A listener that raises, and a result outside the four symbols, become `'unavailable` (rule 7), which is why the result contract is `any/c`. Never dispatched under `never`. |
| `permission-presets/catalog-changed` | emit | none | `permission-presets-register-auto!` and the disposal of its effect, after the change | unfiltered | Each listener is contained (rule 5); the log line is `permission: catalog-changed listener failed: <message>` at `warning`. |
| `user-questions/request` | waterfall | `(request next)`; a `question-answer?` | `user-questions-ask`, once per accepted request | the request's agent when it has one, else unfiltered; no base filter | The innermost step raises `NO_PROVIDER`. A raise propagates to rule 30. |
| `commands/change` | emit | none | every `commands-register!` and every disposal of one, after the change | unfiltered | Each listener is contained; the log lines are `commands/change listener threw: <text>` and `commands/change listener rejected: <text>` at `warning`. A listener cannot veto a registration. |
| `feedback/committed` | parallel | one inspection: an immutable `hasheq` with `'meta` (a `session-header?`), `'inheritedEventCount` and `'events` (the complete list of `session-event?`, the feedback event last) | the cold path of message feedback, after the durable append and before the handle closes (rule 82) | unfiltered | A failure is logged at `warning` as `message-feedback: committed feedback observer failed` and does not fail the operation. A listener must not wait for another message-feedback operation on the same session and must not keep the inspection without copying it. Read with `jref`. |

`approval/request` and `user-questions/request` are the two waterfalls that `dsh-web` forwards to the browser; `commands/change` and `permission-presets/catalog-changed` are forwarded emits. The forwarding table is owned by `dsh-web`.

Consumed, declared elsewhere:

| Event | Listener | Registration |
|---|---|---|
| `tools/post-execute` (waterfall) | repeat-tool reminder, rule 55 | `on-tools/post-execute` |
| `tools/execute` (waterfall) | timeout policy, rule 57 | `on-tools/execute` |
| `agent/pre-step` (waterfall) | repeat-tool reminder (rule 56), plan mode (rule 64) | `on-agent/pre-step` |
| `agent/created` (serial) | permission presets, rule 16 | `on-agent/created` with `#:prepend? #t` |
| `agent/inbox/claimed`, `agent/inbox/discarded` (emit) | user questions, rule 36 | `ctx-on` with `#:global? #t` |
| `session/event` (emit) | user questions, rule 36 | `ctx-on` with `#:global? #t` |

## Tools

Three model-facing tools. Each is built by a procedure that closes over the plugin's context and uses `define-tool` in its body, so the declarations below are the bodies of those procedures. Every description and parameter description is copied verbatim; `—` is U+2014.

### `ask_user_question`, legacy mode

`(make-ask-user-tool ctx #:mode "legacy")`. Source: `packages/interaction/tool-ask-user/src/index.ts:39-119`.

```racket
(define question-option-spec
  (v-object #:additional? #t
    #:properties (parameters
      (param "label" (v-string #:description "Short user-facing option label.") #:required? #t)
      (param "description" (v-string #:description "One sentence explaining the tradeoff or impact.")))))
(define question-item-spec
  (v-object #:additional? #t
    #:properties (parameters
      (param "id" (v-string #:description "Stable id for this question; echoed in the answer.") #:required? #t)
      (param "question" (v-string #:description "The specific question to ask the user.") #:required? #t)
      (param "header" (v-string #:description "Optional short heading for the question, such as \"Confirm\" or \"Choose Mode\"."))
      (param "options" (v-array #:items question-option-spec
                                #:description "Optional choices to show the user. If you recommend one, put it first and append \"(Recommended)\" to that label."))
      (param "multi_select" (v-boolean #:description "Whether the user may select more than one option. Defaults to false.")))))
(define-tool ask-user-question
  #:name "ask_user_question"
  #:description "Ask the user a concise question when you need confirmation, a choice, or missing information before proceeding. An answer item with empty selected and no custom means the user skipped that question: continue without it, do not ask it again, and do not treat the skip as permission."
  #:parameters ([questions (v-array #:items question-item-spec #:description "Questions to ask the user before continuing.") #:required])
  #:output answer-value-spec
  (render (value) (list (text-block (jvalue->string value))))
  (execute (exec) (ask-legacy ctx questions exec)))
```

`answer-value-spec` is `{type: "object", additionalProperties: false, properties: {answers: {type: "array", required: true, items: {type: "object", additionalProperties: false, properties: {id: string required, selected: array of string required, custom: string}}}}}` (`index.ts:77-96`; copy the key order of the source). Result: one text block holding the JSON text of `{answers: [{id, selected, custom?}]}`. Errors: every `exn:fail:user-question` of rule 39 becomes a failed tool result with identity `UserQuestionError` and its code. No approval and no sandbox interaction. Not concurrency-safe.

### `ask_user_question`, timed mode

`(make-ask-user-tool ctx #:mode "timed" #:default-timeout seconds)`. Source: `packages/interaction/tool-ask-user/src/timed.ts:107-212`. Same name; the plugin registers exactly one of the two.

- Description: `Ask brief, direct, self-contained questions about missing information, preferences, or decisions. Use user-facing terms; assume no knowledge of background work or internal names. Use distinct stable question IDs. An answer item with empty selected and no custom means the user skipped that question: continue without it, do not ask it again, and do not treat the skip as permission. A pending result instead means no answer batch arrived before the timeout and the user can still answer.`
- Parameters, in order: `questions`, as in legacy mode but described `Questions to ask the user.`, required; `timeout`, `(v-integer #:description …)` with the text `Wait seconds for the entire batch (default <defaultTimeout>); omit unless the user specifies a duration. Use -1 only when an answer is required before proceeding.`, where `<defaultTimeout>` is the configured number in decimal.
- Output: `oneOf` the pending value `{pending: true, callId: string, message: string}` and the answer value, in the source's order and with its `additionalProperties` (`timed.ts:154-192`). Rendered as one text block with the JSON text of the value.
- `pending-notice`, the `message` of a pending value: `No answer batch arrived before the timeout. This is pending, not a skipped answer. Continue useful independent work. The user can still answer; their reply will be a user message identified as answer_to_pending_question with this callId and the original questions. Do not treat this as permission.`
- Errors: rule 40, plus every `exn:fail:user-question`.

The `timeout` property in the logged request header is how the `userQuestions` projection recognises timed calls (rule 23), so the property name is part of the durable interface.

### `exit_plan_mode`

`(make-exit-plan-mode-tool controller)`. Source: `packages/plan/plan-mode/src/index.ts:280-375`. Registered with `(tools-register! tools definition #:when admitted?)`, rule 68.

```racket
(define-tool exit-plan-mode
  #:name "exit_plan_mode"
  #:description "Use only in plan mode. Present your plan for the user's review and, on approval, leave plan mode. The user may approve (carry out the plan from your next step) or keep planning — their feedback comes back in the tool result; revise and present again."
  #:parameters ([plan (v-string #:description "The complete plan, as markdown, starting with a # heading that names it.") #:required])
  #:output (v-object #:additional? #f #:properties (parameters (param "approved" (v-boolean) #:required? #t)))
  (render (value)
    (list (text-block (if (jref value 'approved)
                          "Plan approved — plan mode exited; carry out the plan starting with your next step."
                          "The user dismissed the plan review to reply in their own words; plan mode remains active."))))
  (execute (exec) (review-plan controller plan exec))
  (present-call () (jobj [card "generic"] [title (plan-title plan)] [kind "other"] [content (list (text-block plan))]))
  (present-result (result) (jobj [card "generic"] [title "Plan review"] [content (tool-result-content result)])))
```

`(plan-title plan)` is the text of the first markdown heading of `plan`, or `Plan` (`firstHeading`, `index.ts:86-95`, a heading of any level). Errors, raised in this order, each an `exn:fail` that the pipeline turns into `Error: <message>`: rule 68 and rule 69.

### `todo_write`

`(make-todo-write-tool #:allow-parallel-in-progress? boolean)`. Source: `packages/todo/tool-todo/src/index.ts:136-212`.

- Description, composed: `Record and update a task list to plan multi-step work and show progress; skip it for trivial single-step tasks. Add one todo per concrete step before you start. `, then for the parallel variant ``While work remains, keep the todos being worked on `in_progress`, several only when work runs in parallel. `` and for the single variant ``While work remains, keep exactly one todo `in_progress`. ``, then ``Mark each todo `completed` as soon as it is done.``
- Parameters: `todos`, required, `(v-array #:description "The COMPLETE task list, replacing any previous list." #:items item)` where `item` is `(v-object #:additional? #f #:properties …)` with `content` `(v-string #:description "What the task is — a short imperative line.")` required, then `status` `(v-string #:enum '("pending" "in_progress" "completed") #:description "pending (not started) | in_progress (now) | completed (done).")` required.
- Output value: `{todos: [{content, status}], counts: {pending, inProgress, completed}}` with the schema of `index.ts:159-187`. Rendered as one text block `Updated todo list: <p> pending, <i> in progress, <c> completed.`
- Presentation: `present-call` returns `{card: "generic", title: "Update todo list", kind: "other", rawInput: <the todos argument>}`.
- Errors: rule 71 and `todo_write requires an owning agent session`.

The compiled `parameters` of `todo_write` must equal, as `jvalue->string` text, the `parameters` recorded under `initial` in `snapshots/session/agent-instructions/tool-schemas.expected.json` when that recording matches current source; where the recording preserves an older description, current source wins (recon 10, corrections).

## Plugins

Each plugin's `#:name` is the npm name. `#:meta` records the dsh function-plugin name under `'dsh-name` where dsh exports one (`"commands"`, `"tool-ask-user"`, `"repeat-tool-reminder"`, `"timeout-policy"`, `"tool-todo"`, `"command-feedback"`). A rejected config fails the mount with `exn:fail:cordis:validation` (rule 1).

| dsh npm name | Module | Inject | Optional (read with `ctx-get` or a nested `ctx-inject`) | Provides |
|---|---|---|---|---|
| `@deepseek-ai/dsh-commands` | `dsh-interaction/plugin/commands` | none | `attachments` | `commands` |
| `@deepseek-ai/dsh-user-approval` | `dsh-interaction/plugin/user-approval` | `sessionProjections` | `systemPrompt`, `sessions` | `approval` |
| `@deepseek-ai/dsh-permission-presets` | `dsh-interaction/plugin/permission-presets` | `shell`, `approval`, `sessions`, `agents`, `sessionProjections` | `settings`, `commands` | `permissionPresets` |
| `@deepseek-ai/dsh-user-questions` | `dsh-interaction/plugin/user-questions` | none | `sessionProjections`, `agents` | `userQuestions` |
| `@deepseek-ai/dsh-tool-ask-user` | `dsh-interaction/plugin/tool-ask-user` | `tools`, `userQuestions` | none | none |
| `@deepseek-ai/dsh-repeat-tool-reminder` | `dsh-interaction/plugin/repeat-tool-reminder` | none | none | none |
| `@deepseek-ai/dsh-tool-call-timeout-policy` | `dsh-interaction/plugin/tool-call-timeout-policy` | `tools` | none | none |
| `@deepseek-ai/dsh-plan-mode` | `dsh-interaction/plugin/plan-mode` | `tools`, `systemPrompt`, `sessionProjections`, `agents` | `commands`, `userQuestions`, `sessions` | `planMode` |
| `@deepseek-ai/dsh-tool-todo` | `dsh-interaction/plugin/tool-todo` | `tools`, `sessionProjections` | `sessions` | none |
| `@deepseek-ai/dsh-command-feedback` | `dsh-interaction/plugin/command-feedback` | `commands` | `sessions` (a nested fiber) | `sessionFeedback` (from the nested fiber) |
| `@deepseek-ai/dsh-message-feedback` | `dsh-interaction/plugin/message-feedback` | `sessionPersistence`, `sessions` | none | `messageFeedback` |

Config schemas (`cordis-schema`), with exactly the dsh keys:

| Plugin | Field | Type | Default |
|---|---|---|---|
| `dsh-user-approval` | `policy` | `"ask"` or `"never"` | `"ask"` |
| `dsh-permission-presets` | `presets` | dict from name to `{sandbox (required), approval (required), name?: string, description?: string}` | the two-entry table of rule 13 |
| | `defaultPreset` | string, volatile | absent |
| `dsh-user-questions` | none (the empty object) | | |
| `dsh-tool-ask-user` | `mode` | `"legacy"` or `"timed"` | `"legacy"` |
| | `timeout` | `-1` or an integer from 1 to 2147483 (seconds) | `120` |
| `dsh-repeat-tool-reminder` | `thresholds` | array of number | `[3, 5, 8]` |
| | `include` | array of string | `[]` |
| | `exclude` | array of string | `[]` |
| | `argumentsPreviewChars` | number | `500` |
| `dsh-plan-mode` | `section` | string, required, not blank; any other key is an error (rule 60) | none |
| `dsh-tool-todo` | `allowParallelInProgress` | boolean, required | none |
| `dsh-message-feedback` | `maxNoteBytes` | integer of at least 1, required | none |

`dsh-commands`, `dsh-tool-call-timeout-policy` and `dsh-command-feedback` take no config.

Bodies, in order:

- **commands**: create the runtime (the instance token and the counter), `provide-commands`.
- **user-approval**: `(projection-register! port ctx approval-state-projection)` and keep the handle; `provide-approval` only after the registration returned; then `(ctx-inject ctx '(systemPrompt) …)` registers the context of rule 10; the nested `sessions` fiber registers the three declarations.
- **permission-presets**: rule 13; register `on-agent/created` with `#:prepend? #t`; register the `permissions` projection and keep the handle; `provide-permission-presets`; run rule 16 for every agent of `(agents-list agents)`; `(ctx-inject ctx '(settings) …)` for rule 19; `(ctx-inject ctx '(commands) …)` registers `/permission` (rule 20).
- **user-questions**: create the service; `(ctx-inject ctx '(sessionProjections) …)` registers `user-questions-projection`; register the three listeners of rule 36; `provide-user-questions`; one effect whose inverse closes every live wait with `ASK_ABORTED`.
- **tool-ask-user**: validate `timeout` (rule 40), then `(tools-register! tools (make-ask-user-tool ctx #:mode mode #:default-timeout timeout))`.
- **repeat-tool-reminder**: rule 51, then the two listeners of rules 55 and 56.
- **tool-call-timeout-policy**: `(install-timeout-policy! ctx tools)`.
- **plan-mode**: rule 60; register the section of rule 66; register `plan-projection`; register the `agent/pre-step` listener (rule 64); one effect whose inverse marks the service disposed; `(ctx-inject ctx '(commands) …)` registers `/plan` (rule 67); register `exit_plan_mode` (rule 68); `provide-plan-mode`.
- **tool-todo**: register `todos-projection`, then `(tools-register! tools (make-todo-write-tool …))`.
- **command-feedback**: `(ctx-inject ctx '(sessions) …)` creates and provides the `sessionFeedback` service; register `/feedback` (rule 75).
- **message-feedback**: create the service with `maxNoteBytes`, `provide-message-feedback`; one effect whose inverse closes admission and waits for the queued operations.

```racket
;; dsh-interaction/plugins
(define plugin-table
  '(("@deepseek-ai/dsh-commands" . dsh-interaction/plugin/commands)
    ("@deepseek-ai/dsh-user-approval" . dsh-interaction/plugin/user-approval)
    ("@deepseek-ai/dsh-permission-presets" . dsh-interaction/plugin/permission-presets)
    ("@deepseek-ai/dsh-user-questions" . dsh-interaction/plugin/user-questions)
    ("@deepseek-ai/dsh-tool-ask-user" . dsh-interaction/plugin/tool-ask-user)
    ("@deepseek-ai/dsh-repeat-tool-reminder" . dsh-interaction/plugin/repeat-tool-reminder)
    ("@deepseek-ai/dsh-tool-call-timeout-policy" . dsh-interaction/plugin/tool-call-timeout-policy)
    ("@deepseek-ai/dsh-plan-mode" . dsh-interaction/plugin/plan-mode)
    ("@deepseek-ai/dsh-tool-todo" . dsh-interaction/plugin/tool-todo)
    ("@deepseek-ai/dsh-command-feedback" . dsh-interaction/plugin/command-feedback)
    ("@deepseek-ai/dsh-message-feedback" . dsh-interaction/plugin/message-feedback)))
```

Shipped composition, for the bundles of `dsh-boot` (recon 10 "Configuration"): the base bundle mounts `user-questions`, `approval` with `policy` computed from `DSH_PERMISSION_MODE` (`never` only for `danger-full-access`), `permission` with the presets `read-only`, `workspace-write`, `danger-full-access`, `commands`, `command-feedback`, `plan-mode` with its `section` text, `timeout-policy`, `tool-todo` with `allowParallelInProgress: true` and `repeat-tool-reminder`; the Web bundle adds `message-feedback` with `maxNoteBytes: 8192` and mounts `plan-mode`, `tool-ask-user` and `tool-todo` per agent preset. The `section` text is configuration and is taken verbatim from each bundle's own file (`packages/bundle/base/cordis.patch.yml:336`, `packages/bundle/web-app/presets/*.patch.yml`); the two copies differ in one clause.

## Behaviour

"Raise" without a type means `exn:fail` with the exact message. No handler in this package catches `exn:break`. Section names refer to recon 10.

**Shared rules**

1. Config validation. Every plugin with a config follows the convention of [WAVE3.md](WAVE3.md): a rejected config fails the mount with `exn:fail:cordis:validation`, whose message starts `invalid config:`. Checks that dsh performs in the plugin body with its own message (rules 13, 40, 51, 60) raise `exn:fail` with that message from the body, after schema validation.
2. Projections. A service that owns a projection calls `(projection-register! port ctx definition)` with the port read by `(port-get ctx 'sessionProjections projection-port?)`, keeps the handle, and reads state with `(projection-state port handle session)`. A service is provided only after its projection registration returned, so no consumer sees it without its fold.
3. Open turn. Two definitions exist and are not interchangeable. Approval uses the `turnOpen` field of its own projection (rule 11). Plan mode and the goal tools use `(jref (agents-turn-boundary-of agents session) 'openTurnStartSeq)` not being `'null`. Neither reads `agent-status`.
4. Messages. Every user message this package creates is built with `make-user-message` of `dsh-llm` (keys `content`, `source`, `role`, `id`), except the question reply of rule 37, whose dsh literal writes `source` first and which is built with `make-message` over `(jobj [source s] [content blocks] [role "user"])`. Summaries of `notice` sources are bounded with `bound-context-summary`.
5. Contained emit. `permission-presets/catalog-changed` and `commands/change` are dispatched as: resolve the listeners with `(scoped-callbacks ctx 'emit name #f '())`, then `invoke-contained` them, logging a raise and a failed returned task at `warning` on the service's logger with the text of the Events table. A listener failure never reaches the registration that caused the emit.

**Approval** (recon 10 "Approval"; `interaction/user-approval/src/index.ts`)

6. `approval-request!` (`:242-261`), in order: read the session of the request's agent; if its `approvalState` has `turnOpen` false, raise `approval.request() outside an open turn: the approval/asked + approval/decided audit pair must be turn-enclosed (a bare event between turns is crash-tail garbage on reload). Ask from inside the turn that needs the decision.` before appending anything; mint the id; append `(approval/asked #:id id #:tool-name name #:call-id call-id #:reason reason)`, with `call-id` and `reason` omitted when `#f`; decide (rule 7); append `(approval/decided #:id id #:outcome <the outcome as a string>)`; return the outcome. A failure of either append propagates: an unlogged decision is never returned.
7. Decide (`:293-333`), in order. The request's cancel event is ready: `'cancelled`. The effective policy (rule 8) is `never`: `'rejected`, before any dispatch, so a listener registered with `#:prepend? #t` cannot bypass it. Otherwise start a task that runs `(scoped-dispatch ctx 'waterfall 'approval/request agent (list request) #:inner (lambda () 'unavailable))`, and await the choice of that task and the cancel event. The cancel event wins: `'cancelled`; the task is left to finish and its result is discarded. The task finished: its result when it is one of the four symbols, `'unavailable` for any other value, and `'unavailable` when it raised an `exn:fail` or any non-break value.
8. Effective policy of a session: the `policy` of its `approvalState` when not `null`, else the config `policy`, else `"ask"`. Grants are one-shot: nothing is cached, and every request produces a fresh dispatch and a fresh audit pair.
9. `approval-set-policy!` (`:211-230`): compute the effective policy `previous`; when it equals `policy` do nothing. Otherwise `(set-approval-policy! session policy)` and then `(agent-inject! agent message)` with source `{kind: "user-approval"}` and one text block `The user changed the approval policy from "<old>" to "<new>".`, where the names are `ask the user for approval` for `ask` and `never ask the user for approval` for `never`.
10. Runtime context (`:74-76`, `:183-196`). From a nested fiber that injects `systemPrompt`, register `(make-prompt-context #:name "approval:policy" #:order (system-prompt-context-order sp 'APPROVAL_POLICY) #:text text)`, where `text` returns `""` when the assemble context has no `'agent`, and otherwise the sentence for that agent's effective policy. `never-sentence`: ``Approval prompts are disabled in this session: actions that require approval are rejected automatically — do not request sandbox escalation (do not set `sandbox_permissions`).`` `ask-sentence`: `Approval prompts are enabled in this session: operations that require approval may ask through the configured answerers; without an available answerer, the request fails closed.` The registration is skipped when the plugin's fiber was disposed while the projection registered.
11. `approval-state-projection`: `init` returns `{policy: null, turnOpen: false}`; `apply` sets `policy` from `approval/policy`, sets `turnOpen` true on `turn/start` and false on `turn/end`, and returns the same state value when nothing changes.
12. The tool pipeline is the main caller: `dsh-tools` rule 32 calls `tool-approval-request` on this service value for a `pre-ask` decision and maps the outcome to the `ApprovalError` results. This package adds nothing to that mapping. Tool bodies of `dsh-exec` and `dsh-fs` call the same method for sandbox escalation.

**Permission presets** (recon 10 "Permission presets"; `interaction/permission-presets/src/index.ts`)

13. Load (`:200-228`). When `presets` is omitted the table is `workspace-write` `{sandbox: "workspace-write", approval: "ask", name: "workspace-write", description: "Write inside the workspace and permitted temporary directories; wider retries require approval."}` and `danger-full-access` `{sandbox: "danger-full-access", approval: "never", name: "danger-full-access", description: "Full file access without approval prompts."}`. Then, in order: a preset named `custom` raises `permission: "custom" is reserved for the derived not-a-preset state and cannot name a table entry`; one named `auto` raises `permission: "auto" is reserved and cannot name a configured preset`; `(port-shell-sandbox-mode ctx)` being `#f` raises `permission: the mounted bash executor does not confine (no sandboxMode) — presets bundle a sandbox mode, so composing this plugin over an unconfined executor is a misconfiguration`; the default is the config `defaultPreset` when given, else the preset derived (rule 14) from the empty state; when that is `custom`, raise `permission: composed sandbox and approval defaults match no preset; configure defaultPreset explicitly`; resolve the default (unknown: the message of `permission-presets-resolve`). A later read of the volatile `defaultPreset` that names no configured preset raises `permission: unknown default preset "<name>"`.
14. `derive-preset` (`:348-361`). `sandbox` is the state's `sandbox` or the shell's sandbox mode; `approval` is the state's `approval`, else the approval config policy, else `"ask"`. If the state's `preset` names a spec that matches both, return it (a still-matching last selection wins a tie between presets with the same bundle). If the state's `preset` is `"auto"`, Auto is registered, the sandbox matches the Auto spec and `approval` is `"never"`, return `"auto"` (a delegated child pins `never`). Else the first configured preset, in declaration order, that matches both. Else `"custom"`.
15. Apply (`:403-418`), used by `permission-presets-set!` and by `/permission`: resolve the name (raises when unknown); for `"auto"` call the registered `admit`; compute `current`; if it differs from the name append `(permission/preset #:preset name)`; then append `sandbox/mode {mode}` only when the spec's sandbox differs from the effective sandbox, and write the approval policy only when it differs from the effective one. `permission-presets-set!` writes the policy with `set-approval-policy!` (no model notice); `/permission` writes it with `approval-set-policy!` (rule 9).
16. Initial pinning (`:429-457`), run for every `agent/created` (the listener is registered with `#:prepend? #t`) and once for each agent that exists when the plugin loads. A stored preset `"auto"` without a registered integration raises `permission: cannot restore preset "auto" without its active integration`; with one, `admit` runs. A fresh session (no preset, no sandbox, no approval, not seeded) gets, in this order, `permission/preset {<default preset>}`, `sandbox/mode`, `approval/policy` from that preset's spec. Otherwise only missing facts are written: `permission/preset` with the derived value when the state has none and the derived value is not `custom`; `sandbox/mode` with the shell's mode when the state has none; `approval/policy` with the approval config policy (or `"ask"`) when the state has none.
17. `permission-presets-register-auto!` (`:306-315`): inside one effect, store `admit`, emit `permission-presets/catalog-changed`; the inverse clears it and emits again. While registered, `"auto"` is a name and resolves to `auto-preset-spec`. `admit` is called synchronously before a live Auto selection and before a restore, and may raise to refuse.
18. The `permissions` projection: `init` returns `{preset: null, sandbox: null, approval: null, seeded: false}`; `apply` sets `preset` from `permission/preset`, `sandbox` from the `mode` of `sandbox/mode`, `approval` from the `policy` of `approval/policy`, and `seeded` true on `session/end-seed`; the view is `{currentValue: <rule 14 on the state>}`. The definition closes over the service, so it is built in the plugin body.
19. Settings. When `settings` is composed the service opts its loader entry out of automatic management: `(settings-configure! (port-get child 'settings settings-port?) ctx (jobj [auto #f]))` inside an effect of a nested fiber, as `dsh-llm` does for its providers.
20. `/permission` (`:254-274`): registered with definition id `@deepseek-ai/dsh-permission-presets`, name `permission`, description `Switch the permission preset (sandbox mode + approval policy)`, input `{hint: "<preset>"}`. The handler trims the raw input. Empty: success `current preset <current> (available: <names joined with ", ">)`. Not a name: error `unknown preset "<name>" (available: …)`. Otherwise rule 15 with the notifying policy write, then success `preset <name>`.
21. Nothing in this service enforces a sandbox or an approval. `permission-presets-current` is read by `dsh-subagent` to seed a child.

**User questions** (recon 10 "User questions"; `interaction/user-questions/src`)

22. Live-root check (`index.ts:137-150`), applied when a request has an agent, and always by `user-questions-answer!` and `user-questions-attach-wait`: when an `agents` service is composed and `(agents-find agents (agent-id agent))` is not `eq?` to the agent, raise `CALLER_NOT_LIVE` `human interaction requires the exact live calling agent when an agent is supplied`; when the session header's origin is `"subagent"`, raise `DELEGATED_CALLER` `human interaction is unavailable while the calling agent is owned by another live agent; include the unresolved question or decision in the child agent's final result`.
23. Projection, header (`projection.ts:235-304`). `init` records the inherited event count and returns `{inheritedEventCount, timed: false, questions: {active: [], settled: []}}`. Events with a seq below `inheritedEventCount` are ignored. A `request/header` sets `timed` to whether the header's `tools` contain a tool named `ask_user_question` whose `parameters.properties` has the key `timeout`.
24. Projection, calls and results. A `tool/call` named `ask_user_question` while `timed` is true adds `{callId, questions, state: "open"}`, replacing an active entry with the same call id; `questions` are read from the JSON text of `arguments`, and unreadable arguments are ignored. A `tool/result` for a tracked call: when its text content parses to an object with `pending` exactly `true`, or its error code is `TOOL_OUTCOME_UNKNOWN` (the resume repair of `dsh-session`), the entry's state becomes `"continued"`; a result that is not an error and whose text parses to an object with an `answers` list moves the entry to `settled` as `{callId, answers}`; any other result removes the entry. Calls made while `timed` is false are never tracked.
25. Projection, other inputs. A `tool/ptc-dispatch` of `ask_user_question` with a pending result that is not an error adds a `"continued"` entry keyed by its `subCallId`. A `user/message` whose source kind is `user-question-reply` settles the call named by `source.callId` with the `answers` parsed from its text block, or with an empty list when the text is unreadable.
26. The wire view is `{active: [{callId, questions, state}], settled: [{callId, answers}]}` in fold order. The service's "continued questions of an agent" are the active entries with state `"continued"`; without a projection registry the list is empty.
27. `user-questions-ask`, validation in order (`index.ts:291-339`): the cancel event is ready: `ASK_ABORTED` `ask_user_question was aborted before the user answered`; no question: `EMPTY_QUESTIONS` `ask_user_question requires at least one question`; rule 22 when the request has an agent; rule 28 for each question that has an `intent`.
28. Intent rules, each `BAD_INTENT`. The action labels of an intent are `approve` for `plan-review`, and `approve`, `reject` and, when present, `always` for `approval`. An `approve` label that is not the `label` of one of the question's options: `question <id> declares intent <kind> whose approve label <label as JSON> names none of its options`. Another action label that is not offered: `question <id> declares intent <kind> whose action label <label as JSON> names none of its options`. A question without a `detail`: `question <id> declares intent <kind> without the <words>`, where `<words>` is `scope detail it requires` for `approval` and `detail it reviews` for `plan-review` (`index.ts:319`). For `approval`, further: more than one question in the request: `approval presentation requires one question; received <n>`; `multiSelect` true: `approval question <id> does not support multiSelect`; a `wait`: `approval question <id> requires a blocking request without wait`; repeated labels: `approval question <id> requires distinct action labels; received <labels as a JSON array>`; a number of options different from the number of labels: `approval question <id> requires <n> options matching its actions; received <m>`.
29. Dispatch: `(scoped-dispatch ctx 'waterfall 'user-questions/request key (list request) #:inner no-answerer)`, where `key` is the agent or `#f` and `no-answerer` raises `NO_PROVIDER` `no user-questions answerer accepted the request`. The dispatch runs in the calling task.
30. Error mapping after the dispatch (`:344-360`): a raised value `v` for which `(restore-user-question-error v)` is an `exn:fail:user-question` is raised in that form; otherwise, when the request's cancel event is ready, raise `ASK_ABORTED` (message of rule 27) with `v` as cause; otherwise re-raise `v`.
31. The answer is returned as the answerer gave it. The service does not check that it names every question; `user-questions-answer!` (rule 37) and the SDK bridge do that for their own inputs.
32. `user-questions-ask-timed` (`:239-274`), in order: `timeout-ms` not an exact integer from 1 to 2147483647: `BAD_TIMEOUT` `timeout must fit a positive platform timer`; rule 22; a wait already registered for `(agent, call-id)`: `DUPLICATE_WAIT` `the question call already has a foreground wait`. Create a timed wait (rule 33) with deadline now plus `timeout-ms`, the request's cancel event as parent and the reason `ASK_TIMED_OUT` `ask_user_question timed out before the user answered`; register it. Call `user-questions-ask` with the request changed to carry the wait's event as `cancel` and `wait` `{callId, timed: true}`. If that raises `NO_PROVIDER`, wait until the wait ends and continue with the wait's reason, so an unattended question still ends as pending. Outcomes: an answer is returned; a failure whose identity is `ASK_TIMED_OUT`, or any failure while the wait ended with its timeout reason, gives `{pending: true, callId}`; any other failure while the wait's event is ready gives `ASK_ABORTED`; any other failure is re-raised. In every case the wait is closed and unregistered before the procedure returns or raises.
33. Timed wait (`timed-wait.ts`). A wait has a deadline in wall-clock milliseconds, a cancel source whose event is `(timed-wait-evt w)`, a claim count, and at most one timer task. The timer runs only while the claim count is 0: it awaits an alarm at the deadline and then cancels the source with the timeout reason. A parent cancel event that becomes ready closes the wait with the parent's reason. `(timed-wait-close! w reason)` stops the timer, cancels the source with `reason` when it is not yet cancelled, and releases every claim; it is idempotent.
34. Claims. Taking a claim increments the count and stops the Host timer; releasing the last claim starts the timer again for the remaining time, and when the deadline has already passed the wait ends with the timeout reason at once. The client that holds a claim owns the visible countdown and ends the question itself with `ASK_TIMED_OUT`.
35. `user-questions-attach-wait` (`index.ts:221-226`): rule 22; look up the wait of `(agent, call-id)`; none gives `#f`. Otherwise take a claim and return `(wait-claim (max 0 (- deadline now)) released)`. A task owned by the service awaits the choice of `cancel` and the wait's event, then releases the claim and makes `released` ready. `dsh-web` turns the claim into the Remote stream: one item `{remainingMs}`, then open until `released`.
36. Reply queue (`index.ts:93-127`). The service keeps, per session (a weak `eq?` table), a table from call id to `{messageId, claimedTurn?}`. Three listeners, all registered with `#:global? #t`: `agent/inbox/claimed` of a message whose source kind is `user-question-reply` records `{messageId, claimedTurn: turn}` when the call has no entry, or sets `claimedTurn` when the entry's message id matches; `agent/inbox/discarded` of such a message removes the entry when the message id matches; `session/event` removes the entry when a `user/message` with that source and id is logged, and at a `turn/end` removes every entry whose `claimedTurn` is that turn.
37. `user-questions-answer!` (`:170-219`), in order: rule 22; find the continued question with that call id, none returns `#f`; when the queue has an entry for the call, or either inbox list of the agent holds a message whose source is a `user-question-reply` for the call, raise `REPLY_QUEUED` `a reply is already queued for this question`; unless the answer names each question id of the stored question exactly once, raise `BAD_ANSWER` `the answer batch for <callId> must name each of its <n> questions exactly once`; build the reply message with source `{kind: "user-question-reply", callId, outcome: "answered"}` and one text block holding the JSON text of `{kind: "answer_to_pending_question", tool: "ask_user_question", callId, questions, answers}`; record `{messageId}` in the queue; `(agent-steer! agent message)`, removing the entry again if that raises; return `#t`. Steering starts a turn on an idle agent.
38. `user-questions-remote-methods` is `(list (cons "answer" user-questions-answer!) (cons "attachWait" user-questions-attach-wait))`. The Remote layer decodes the agent from the session id of the call.
39. Legacy tool body (`tool-ask-user/src/index.ts:100-118`): map each question's `multi_select` to `multiSelect`, keeping `id`, `question`, `header` and `options`; call `(user-questions-ask uq (make-question-request questions #:agent (tool-execution-agent exec) #:cancel (tool-execution-cancel exec)))` with no `wait`; return the answer as the value.
40. Timed tool body (`timed.ts:8-24`, `:195-210`). `timeout` is the argument or the configured default. Unless it is `-1` or an integer from 1 to 2147483, raise `timeout must be -1 or a positive integer up to 2147483 seconds`; the plugin applies the same check to its config at load. A repeated question id raises `question id <id as JSON> must be unique within this call`. With `-1`: `user-questions-ask` with `wait` `{callId}`, the call id of the execution. Otherwise: no agent raises `timed questions require a live agent`; call `(user-questions-ask-timed uq request (tool-execution-call-id exec) (* timeout 1000))`; a pending result is returned with `message` set to `pending-notice`, in the key order `pending`, `callId`, `message`; an answer is returned as the value.

**Commands** (recon 10 "Commands"; `interaction/commands/src/index.ts`, `builtin.ts`)

41. `commands-register!` (`:179-225`, `:285-292`), checks in order, each `exn:fail:contract`: a name not matching `^[a-z][a-z0-9_-]*$`: `command name "<name>" must match /^[a-z][a-z0-9_-]*$/u`; `command "<name>" description must be a string`; a blank description: `command "<name>" description must not be empty`; `command "<name>" handler must be a function`; an `input` without a string `hint`: `command "<name>" input hint must be a string`; a blank hint: `command "<name>" input hint must not be empty`; `command "<name>" input attachments flag must be a boolean`. The stored input is `{hint}` or `{hint, attachments: true}`; the descriptor is `{definitionId?, name, description, input?}`. Registration uses `scoped-layers-effect!` with label `commands.register()`; a duplicate name raises ``command "<name>" is already registered (for a per-agent variant, mount a command-injected plugin under that agent's `agent.ctx`)`` in the global layer and `command "<name>" is already registered in this scope` in a scoped one.
42. `parse-command` (`:125-132`): match `#px"^/([a-z][a-z0-9_-]*)(?=$|[\t\n\r ])"` at the start of the line. No match gives `#f`. `raw-input` is everything after the name, including the separating whitespace, unchanged.
43. `commands-execute`, opening (`:361-381`): parse; `#f` gives `#f`. Look the name up in the effective view of the agent; none gives `#f`. If `cancel` is ready, raise its reason when that is an exception, else `exn:fail` with the reason when it is a string, else `command aborted`; nothing is logged. Mint the command id. Append `(command/run #:command-id id #:name name #:args raw-input #:source (jobj [kind "user"]))`, with `args` omitted when the definition was registered with `#:record-input? #f`.
44. Attachments (`:389-420`, `:493-531`), only when at least one was submitted. The definition's input lacks `attachments: true`: settle (rule 47) the error `/<name> does not accept attachments`. No `attachments` service: settle `/<name>: attachments are unavailable because no attachment store is composed`. Otherwise: resolve each distinct file receipt with the registered resolver, in submission order; an unknown receipt, or no resolver, settles the error `File upload receipt is unknown for this session.`; admit every image in one call of `port-admit-command-images`; build the blocks in submission order, an image block per image and `{type: "file", attachment: <ref>}` per file. A harness error named `AttachmentError` settles as an error result with its message; any other failure appends the thrown settlement and is re-raised. If `cancel` became ready during admission, append the thrown settlement for the cancel error of rule 43 and raise it; the handler does not run.
45. Handler (`:421-431`): call the handler with `(command-invocation id agent raw-input attachments cancel)` in a task and await the choice of that task and `cancel`. `cancel` first: the cancel error of rule 43. A raised value that is not an exception becomes `exn:fail` `command handler rejected with a non-Error value: <display form>`. A failure appends the thrown settlement and is re-raised.
46. Result check (`:228-256`), each `exn:fail:contract`: not an object with `kind`: `command "<name>" handler must return a CommandResult`; a success whose `text` is not a string: `command "<name>" success text must be a string when supplied`; a success whose `sourceEventSeq` is not a `session-seq?`: `command "<name>" success sourceEventSeq must be a non-negative safe integer when supplied`; an error whose text is not a string with a non-blank character: `command "<name>" error text must be a non-empty string`; another kind: `command "<name>" returned unknown result kind "<kind>"`. The normalised result keeps only `kind`, `text` and, for a success, `sourceEventSeq`.
47. Settlement. A result is settled by appending `(command/done #:command-id id #:kind kind #:text text #:source-event-seq seq)`, absent fields omitted, and returning `{commandId, result}`. The thrown settlement appends `command/done` with kind `error` and the exception message (the display form for another value); if that append raises, log `command "<name>": command/done append failed: <text>` at `warning` and continue.
48. Both lifecycle events are plain appends with no turn around them and no flush. The effective view is `(scoped-layers-merge layers agent …)`: scoped shadows over global definitions.
49. First-party table (`builtin.ts`). Identities: `goal` is `@deepseek-ai/dsh-command-goal`, `plan` is `@deepseek-ai/dsh-plan-mode`, `feedback` is `@deepseek-ai/dsh-command-feedback`, `compact` is `@deepseek-ai/dsh-command-compact`, `permission` is `@deepseek-ai/dsh-permission-presets`, `export` is `@deepseek-ai/dsh-session-log-export`. `builtin-command-tokens` holds the typed aliases: English `goal plan feedback compact permission export` and Simplified Chinese `目标 计划 反馈 压缩 权限 导出`, each mapped to its built-in name. `(builtin-command-name descriptor)` returns the built-in name whose identity equals the descriptor's `definitionId`, else `#f`. `(resolve-command token descriptors)`: a descriptor whose `name` equals the token wins; otherwise, when the token is an alias, the descriptor whose `definitionId` is that built-in's identity; else `#f`.
50. `commands/change` is emitted by the `on-change` procedure of the scoped layers, after a registration and after a disposal, by rule 5.

**Repeat-tool reminder** (recon 10 "Repeat-tool reminder", "Guard texts"; `guard/repeat-tool-reminder/src/index.ts`)

51. Load checks, each `exn:fail` (`validateThresholds`, `:135-148`, and `apply`, `:160-170`): ``repeat-tool-reminder: `thresholds` must not be empty``; a threshold that is not an integer of at least 2: `repeat-tool-reminder: invalid threshold <value> — every threshold must be an integer >= 2`; ``repeat-tool-reminder: `thresholds` must not contain duplicates``; `argumentsPreviewChars` not an integer of at least 1: `repeat-tool-reminder: invalid argumentsPreviewChars <value> — must be an integer >= 1`. The thresholds are then sorted ascending. Numbers print as JavaScript prints them.
52. `(canonical-arguments v)` is the JSON text (`jvalue->string`) of `v` with every object rebuilt recursively, arrays kept in order, and keys in the order JavaScript gives an object built from `Object.keys(o).sort()`: first the keys that are canonical array indexes (decimal integers from 0 to 4294967294 without a leading zero) in ascending numeric order, then all other keys in `js-string<?` order. `v` is the parsed argument value of the execution. An execution whose arguments are `absent` never reaches `tools/post-execute` (dsh-tools rule 30), so `v` is always a jvalue.
53. `(wildcard->regexp pattern)`: escape each of ``| \ { } ( ) [ ] ^ $ + ? .`` so that it is literal, replace each `*` by `.*`, and anchor at both ends. A tool is tracked when `include` is empty or one of its patterns matches the tool name, and no `exclude` pattern matches.
54. Observation (`:196-214`). State is a weak `eq?` table from agent to `(key . count)`, held by the plugin body. For an execution: no agent, or an untracked tool: no reminder and no change to the chain (an untracked call neither counts nor resets). Otherwise `key` is the JSON text of the two-element array `[<tool name>, <canonical arguments>]`; the same key as the stored one gives `count + 1`, another key gives 1. When the count is one of the thresholds: the smallest threshold gives the gentle text, any other the detailed text.
55. The `tools/post-execute` listener `(lambda (exec result next) …)` observes first, then always calls `(next)`. With a reminder it returns the decision that came back with the reminder message placed first in its additional contexts: a `post-accept` rebuilt with the same content, value and `(cons reminder contexts)`; a `post-block` with the same feedback and info and `(cons reminder contexts)`. It never vetoes and never changes content. Denied calls pass through `tools/post-execute` and therefore count. The reminder is a user message with one text block and source `{kind: "repeat-tool-reminder", form: "notice", summary: "<tool name> × <count>"}` (`×` is U+00D7). Gentle text: `You are repeating the exact same tool call with identical arguments. Carefully analyze the previous result before calling again: if the task is not complete, try a different approach or different arguments instead of repeating the call.` Detailed text, four lines and a closing sentence joined with `\n`: `Repeated tool call detected:`, `- tool: <name>`, `- consecutive_calls: <count>`, `- arguments: <preview>`, `The repeated calls are not making progress. Do not call this tool with these exact arguments again. Inspect the latest result and choose a different action, different arguments, or finish the task if enough evidence has been gathered.` `(preview-arguments canonical cap)` is `canonical` when `(utf16-length canonical)` is at most `cap`, else `(utf16-substring canonical 0 cap)` followed by `… (+<n> more chars)` with `n` the remaining UTF-16 units and `…` U+2026.
56. Reset: the `agent/pre-step` listener removes the agent's chain when one of the payload's `messages` has source kind `user`, and always returns `(next)`.

**Timeout policy** (recon 10 "Timeout policy"; `guard/timeout-policy/src/index.ts:55-81`)

57. `(install-timeout-policy! ctx tools)` registers one `tools/execute` listener `(lambda (exec next) …)`: read `(tools-lookup tools (tool-execution-name exec) (tool-execution-agent exec))`; no tool or no `timeout-ms`: return `(next)`. Otherwise make a deadline (rule 58) over `(tool-execution-cancel exec)` with code `TOOL_TIMEOUT`, and run `(call-with-tool-cancel exec (deadline-evt d) next)`, which restores the upstream event afterwards, also when `next` raises. The body is never abandoned: the listener waits for `next` to return, so a tool must honour its cancel event. When `next` returned and this listener's own timer fired (rule 58), the result is replaced by rule 59; otherwise it is returned unchanged, so an outer deadline or a caller's cancel is not misread as this timeout. The deadline is disposed in every case.
58. Deadline (`packages/util/timeout/src/index.ts`, private here). `(make-deadline upstream timeout-ms code)` raises `deadline timeoutMs must be a positive finite number no greater than 2147483647` for a value above 2147483647 or not finite; it starts a timer task that, after `timeout-ms` milliseconds on the monotonic clock, cancels a private source with the reason `(timeout-reason code timeout-ms)`, a transparent struct whose text form is `<code> after <timeout-ms>ms`. `(deadline-evt d)` is `(cancel-evt-any upstream timer-evt)`: the first cause fixes the reason. `(deadline-fired? d)` is true when the reason of `(deadline-evt d)` is `eq?` to this deadline's own reason value. `(deadline-dispose! d)` stops the timer task and is idempotent.
59. `(tool-timeout-result timeout-ms)` is `(make-tool-failure message (list (text-block (string-append "Error: " message))) #:info (tool-error-info "ToolTimeoutError" "TOOL_TIMEOUT" #f))` with `message` `tool call timed out after <timeoutMs>ms`, the number printed as JavaScript prints it.

**Plan mode** (recon 10 "Plan mode", "Plan mode texts"; `plan/plan-mode/src/index.ts`)

60. Config (`resolveConfig`, `:100-115`). The plugin's `#:config` accepts any object and the body checks: `section` not a string: ``PlanModeConfig needs a string `section` ``; blank after trimming: ``PlanModeConfig needs a non-empty `section` ``; any other key: `PlanModeConfig has unknown key(s) <keys joined with ", "> — config is { section }`. These are `exn:fail` raised at load.
61. `plan-projection` (`:135-166`). `init`: `{active: false, wanted: null, running: null, activeAtLastHeader: null, entered: false}`. `apply`: a `command/run` whose `name` is `plan` and that has `args` sets `running` to `{commandId, wanted}` with `wanted` true unless the trimmed `args` equal `off`; a `command/done` whose `commandId` equals the running one sets `wanted` to the running target when the kind is `success` and the target differs from `active`, else to `null`, and clears `running`; `plan/mode` sets `active`, sets `wanted` to `null`, and sets `entered` to `entered or active`; `request/header` sets `activeAtLastHeader` to `active`. View: `{active, pending}` with `pending` true when `w` is not `null` and differs from `active`, where `w` is the running target when a command is running, else `wanted`.
62. State. The logged state is the `active` of the projection. Pending intents live in a weak `eq?` table from session to `(active . narrate?)`, process-local and never persisted. The selected state is the pending intent's `active` when there is one, else the logged state. `plan-mode-state` returns `{active: <logged>}` or `{active: <logged>, pending: <the intent's active>}`. Reading state before the projection registered raises `plan mode is not ready; await plugin activation before running an agent`.
63. `plan-mode-set!` (`:431-451`). If `active?` equals the pending intent's target, or the logged state when nothing is pending: `'noop`. With an open turn (rule 3): store the intent `(active? . #t)`; return `'cancelled` when the logged state already equals `active?` (an opposite pending selection was undone), else `'queued`. Without an open turn: when `active?` equals the logged state, delete the intent and return `'cancelled`; otherwise append `(plan/mode #:active active?)`, delete the intent only after the append succeeded, inject the narration of rule 65 with `agent-inject!` when there is one, and return `'committed`.
64. `agent/pre-step` listener (`:211-228`): call `(next)` first. When the decision is a `pre-step-reject`, the payload's cancel event is ready, or the session has no pending intent, return the decision. Otherwise compute the narration for the intent's target (rule 65), then commit: append `(plan/mode #:active target)` unless the logged state already equals the target, and delete the intent after the append succeeded. If the append raises, log `dsh-plan-mode: failed to append selected plan mode at step start: <error>` at `warning`, keep the intent, and return the decision unchanged. Then, when the intent's `narrate?` is true and a narration exists, return the decision with the narration appended to its messages, keeping `starts-request-series?`.
65. Narration (`:469-480`) for a target exists only when the projection's `activeAtLastHeader` is a boolean different from the target; before the first request header nothing is narrated, because the section states the mode. It is a user message with one text block and source `{kind: "plan-mode", form: "notice", summary: <the same text>}`: `The user switched this session to plan mode.` for target true, `The user switched this session back to the default mode.` for false.
66. Section (`:189-196`): `(make-prompt-section #:name "plan:policy" #:order (system-prompt-section-order sp 'PLAN_POLICY) #:text text)`, where `text` returns `""` when the assemble context has no `'agent`, the configured `section` when the selected state of that agent's session is active, and `""` otherwise.
67. `/plan` (`:238-276`): definition id `@deepseek-ai/dsh-plan-mode`, name `plan`, description `Enter or leave plan mode`, input `{hint: "[off|message]", attachments: true}`. The handler trims the raw input to `message`. `off` with attachments: error `Attachments cannot accompany /plan off.` `off`: `(plan-mode-set! … #f)` and success text by outcome: `'committed` gives `Plan mode off.`; `'queued` gives `Leaving plan mode (applies from the next step).`; `'cancelled` gives `Plan mode entry cancelled.`; `'noop` gives `Leaving plan mode (applies from the next step).` when the logged state is still active, else `Plan mode is already inactive.` Any other input: `(plan-mode-set! … #t)`; then, when `message` is not empty or attachments exist, `(agent-steer! agent m)` with a user message of source `{kind: "user"}` whose content is the attachment blocks followed by one text block for a non-empty `message`; success `Plan mode on. Use /plan off to leave.` for `'committed`, else `Entering plan mode (applies from the next step). Use /plan off to leave.`
68. `exit_plan_mode`, admission and opening checks (`:280-312`). The `when` condition of the registration is true for an activation context whose agent's session has `entered` true or a selected state that is active; native declarations, PTC bindings and execution share it. The body raises, in order: no agent, or the logged state not active: `exit_plan_mode is only available in plan mode`; the trimmed plan not matching `#px"^#\\s+\\S"`: `exit_plan_mode requires a non-empty markdown plan starting with a # heading`; no `userQuestions` service (`ctx-get`): `no user-questions channel is available to review the plan; ask the user to switch the session mode instead`.
69. Review (`:313-363`). Ask `(user-questions-ask uq (make-question-request (list item) #:agent agent #:cancel (tool-execution-cancel exec)))` with `item` `{id: "plan-review", header: "Plan review", question: "Approve this plan and leave plan mode?", detail: <plan>, options: [{label: "Approve", description: "Leave plan mode; the plan is carried out from the next step."}, {label: "Keep planning", description: "Stay in plan mode; feedback goes back to the model."}], intent: {kind: "plan-review", approve: "Approve", callId: <the execution's call id>}}`, keys in the order of the source literal. An `exn:fail:user-question` with code `ASK_CANCELLED`: call `(tool-conclude-turn! exec)` and return `{approved: false}`; the turn ends without another model request. Any other `exn:fail:user-question` propagates. After the answer, when the service was disposed meanwhile, raise `the plan-mode service was reloaded while the plan was under review; present the plan again`. The answer approves when exactly one answer item has id `plan-review`, its `selected` is exactly `["Approve"]`, and it has no `custom`. Anything else is keep-planning: with `feedback` the trimmed `custom` of the review item (empty when there is none or more than one item), raise `The user chose to keep planning; revise the plan and present it again.` for empty feedback, else `The user chose to keep planning; their feedback: <feedback>`.
70. On approval the body stores the intent `(#f . #f)` and returns `{approved: true}`. The `plan/mode` event is appended by rule 64 at the next accepted pre-step, without narration, so the guidance section stays for the rest of the current tool batch.

**Todos** (recon 10 "Todos"; `todo/tool-todo/src/index.ts`)

71. `(->todo-list raw allow-parallel?)` (`:80-101`), over the items in order: trim `content` (JavaScript `trim`); empty: ``invalid todo: `content` must be a non-empty string``; a trimmed content already seen: `invalid todos: duplicate content <content as a JSON string>`; count the items with status `in_progress`. Afterwards, when `allow-parallel?` is false and the count exceeds 1: `invalid todos: at most one task may be in_progress (got <n>)`. The result is the list of `{content, status}` with trimmed contents. An empty list is valid.
72. Tool body (`:194-209`): rule 71 first, then no agent raises `todo_write requires an owning agent session`; append `(todo/write #:todos todos)` to the agent's session; return `{todos, counts: {pending, inProgress, completed}}`.
73. `todos-projection`: `init` `null`; a `todo/write` gives its `todos`; a `turn/start` gives `null`; any other event keeps the state. The list is replaced whole, the last write wins, and a finished list stays visible through `turn/end` until the next turn starts.
74. The description variant is chosen once, when the tool is built, from `allowParallelInProgress`.

**Feedback** (recon 10 "Feedback"; `feedback/command-feedback/src/index.ts`, `feedback/message-feedback/src/index.ts`)

75. `/feedback` (`:73-84`, `:117-128`): definition id `@deepseek-ai/dsh-command-feedback`, name `feedback`, description `Record feedback about this session`, input `{hint: "<text>"}`, `#:record-input? #f` (so `command/run` carries no `args`). A blank raw input: error `Feedback text is required. Usage: /feedback <text>`. Otherwise `(record-feedback! session #:text raw-input)` and success `Feedback recorded for session <sessionId>\nAnonymous user: <id>.` with `<id>` from `(port-anonymous-user-id)`.
76. `record-feedback!` (`:58-64`): trim the text; append `(feedback/record #:text text #:category category)` with `text` omitted when blank or absent and `category` omitted when absent. An entry with neither is still recorded. The append is not flushed: the acknowledgement means logged, not stored.
77. `session-feedback-record!`: `(sessions-find sessions sessionId)`; none returns `{ok: false, error: {code: "session-not-found", sessionId}}`; otherwise rule 76 with the request's `text` and `category` and `{ok: true, value: {recorded: true}}`. Only live sessions are served.
78. Message feedback, admission (`withSession`, `:221-232`, and `enqueue`, `:301`). Operations on one session id run one at a time in arrival order (a serial queue per id, dropped when empty); operations on different ids overlap. After disposal began, a new operation raises `message-feedback: service is disposing`. A session is known when it is live, or `(port-persistence-stat ctx id)` is not `#f`, or it became live during that wait; otherwise the result is `{ok: false, error: {code: "session-not-found", sessionId}}`.
79. `(current-feedback-items session-id events)` (`:97-113`): fold the events in order; a `feedback/message-put` whose `sessionId` equals `session-id` sets the item for its `messageId`; a `feedback/message-delete` with that `sessionId` removes it; events with another `sessionId` are ignored (a fork does not own its parent's feedback). The result is in first-insertion order of the remaining message ids.
80. Operations. `message-feedback-list`: `{ok: true, value: {items}}` from rule 79. `message-feedback-put!`, in order: rule 83 on the note, before queueing; the target must be an `assistant/message` event with surface op `'append` whose derived message (`session-derive-event-message`, or the event's `message` on the cold path) has id `messageId`, else `{code: "target-not-found", sessionId, messageId}`; `ifVersion` must equal the current item's `version`, or be `'null` when there is none, else `{code: "version-conflict", current}` with `current` the item or `null`; an item with the same rating, note and category appends nothing, runs the durability step of rule 81 or 82 with no event, and returns the existing item; otherwise build the item with keys `messageId`, `rating`, `note?`, `category?`, `version` (a fresh UUID), `createdAt` (kept from the existing item, else now), `updatedAt` (now, or the larger of now and the existing `updatedAt`), append `(feedback/message-put #:session-id id #:item item)` and return `{ok: true, value: item}`. `message-feedback-delete!`: an existing item requires `ifVersion` equal to its version (else the conflict error) and appends `(feedback/message-delete #:session-id id #:message-id messageId)`; an absent item appends nothing; both return `{ok: true, value: {absent: true}}`.
81. Live path (`:233-260`): the events are those of the live session; an append is `session-append!`; then `(sessions-flush sessions session)` must return true, else raise `message-feedback: no durability listener participated for live session '<id>'`; then open the stored session for `'read`, read one event at the seq of the live session's last event, and require that the stored header's `id`, `createdAt` and `cwd` equal the live header's and that the stored event equals the live one (`equal?` on events), else raise `message-feedback: feedback prefix is not durable for live session '<id>'`; close the handle in every case.
82. Cold path (`:261-284`): open the stored session for `'write` (`'read` for a list); read all events; an append builds the event with `seq` equal to the number of events read and `time` now, in the key order `type`, `data`, `seq`, `time`, appends it with `port-handle-append!` and flushes; a durability step with no event only flushes; after an append, dispatch `feedback/committed` with the inspection of the Events table and wait for the listeners, logging a failure; close the handle in every case. No session or agent is constructed.
83. Notes (`resolveNote`, `:286-295`): an absent note is accepted; a note without a non-blank character gives `{ok: false, error: {code: "note-blank"}}`; a note longer than `maxNoteBytes` UTF-8 bytes gives `{code: "note-too-large", maxBytes, actualBytes}`. Byte counts use `utf8-length`.

## Racket design notes

- **The approval service is a generic-interface provider.** `dsh-tools` declares `gen:tool-approval`; the `approval` service value implements it, so the pipeline and the escalation code of `dsh-exec` and `dsh-fs` call one method and no package below this one requires it.
- **Outcomes are symbols in the process and strings in the log.** This follows the wave 3 decision for process-local vocabulary ([WAVE3.md](WAVE3.md), review 4). The conversion happens in exactly two places: the `approval/decided` append and the wire layers.
- **Racing an answer against cancellation is one `await`.** dsh builds a promise that listens for `abort`; here the dispatch runs in a task and the service awaits `(choice-evt task cancel)`. The containment of a raising answerer is the task boundary.
- **The timed wait is a struct with a timer task**, not a class with `setTimeout`. A claim is a count; the remaining time is recomputed from the wall-clock deadline when the last claim leaves, as in dsh.
- **`attachWait` is a procedure that returns a claim.** An `AsyncIterable` that yields once and then stays open is a value plus an event; `dsh-web` owns the stream encoding.
- **Commands are registered with keywords.** dsh passes an object literal with optional members; `commands-register!` takes the same members as keyword arguments, which is the shape the port wrappers of `dsh-context` and `dsh-session-store` already assume. The registry is the scoped-layers storage of `dsh-tools/scope`, the same structure `tools` and `systemPrompt` use.
- **Pending plan intents and question reply queues are weak `eq?` tables keyed by session**, the counterpart of `WeakMap`.
- **Projections are plain fold functions over jvalues.** The zod state schemas of dsh have no counterpart: a state is produced only by `init` and `apply`.
- **`sandbox/mode` is appended as a literal event.** dsh calls `setSandboxMode` of the sandbox package; that procedure only validates and appends, the preset table is already validated at load, and a literal append keeps this package free of a require on `dsh-exec`. The mode fence of `dsh-exec` observes the append like any other.
- **Remote methods are alists.** Each service that dsh exposes through typert exports `<service>-remote-methods`, a list of `(cons method-name procedure)`; `dsh-web` builds its method table from them. This is the convention `dsh-subagent` uses.
- **No macro is introduced.** The session events use `define-session-event`, the tools `define-tool`, the plugins `define-plugin`.
- **Racket-only additions**, for the coordinator's ADR list: `dsh-interaction/ports` with its four generic interfaces and the `dynamic-require` fallback; the `wait-claim` struct in place of the stream; `approval-config-policy` and `permission-presets-default-preset` as procedures where dsh has properties; `derive-preset`, `current-feedback-items`, `canonical-arguments`, `preview-arguments`, `wildcard->regexp` and `->todo-list` exported as pure procedures for tests; the private deadline helper; the registration of session event declarations through a nested `sessions` fiber; the `<service>-remote-methods` alists. No `x-racket` config key and no `racket:` name is added.

## Work units

The package is about 3,500 lines of Racket with tests and is split into two units that can be built at the same time. The interface between them is the set of public exports of this document; unit B uses from unit A only `dsh-interaction/commands` (`commands-register!`, the result constructors, the invocation accessors), `dsh-interaction/user-questions` (`user-questions-ask`, `make-question-request`) and `dsh-interaction/errors`.

| Unit | Modules | Depends on |
|---|---|---|
| A: human channels | `ports`, `errors`, `approval`, `permission-presets`, `user-questions`, `tool-ask-user`, `commands`, their plugins, `private/timed-wait`, `private/contained` and their tests | wave 3 |
| B: policy and records | `guard/*`, `plan-mode`, `todo`, `feedback`, `message-feedback`, their plugins, `private/deadline`, `private/serial`, `plugins`, `main` and their tests | wave 3; the three modules of unit A named above, by their signatures |

`dsh-interaction/errors` and the signatures of `dsh-interaction/commands` are delivered first. Unit B can test plan mode and feedback against a stub `commands` service and a scripted answerer before unit A is finished.

## Tests

Tests live in `racket/dsh-interaction/tests/`. Each row names the TypeScript suite to mirror and what it pins. End-to-end cases run through `call-with-loop-harness` of `dsh-test-support` with the mock model; answerers are scripted listeners.

| Racket test file | Mirrors | Pins |
|---|---|---|
| `approval-test.rkt` | `packages/interaction/user-approval/tests/approval.spec.ts`, `projection.spec.ts`; the approval cases of `packages/core/tools/tests/tools.spec.ts:879-1022` | rules 6 to 12: the audit pair and its order, the open-turn requirement, `never` before a prepended answerer, a raising and a rogue answerer give `'unavailable`, the cancel race and the discarded late answer, the policy notice text, the projection fold, the two sentences in a rendered context snapshot |
| `permission-presets-test.rkt` | `packages/interaction/permission-presets/tests/permission-presets.spec.ts`, `initialization.spec.ts`, `projection.spec.ts` | rules 13 to 21: load errors, derive and its tie-break, `custom`, Auto registration and restore, pinning of fresh, seeded and partial sessions, `/permission` texts, contained catalog listeners |
| `user-questions-test.rkt` | `packages/interaction/user-questions/tests/user-questions.spec.ts`, `timed-wait.spec.ts` | rules 22 and 27 to 38: every validation code and message, the scoped waterfall, error restoration, pending results, duplicate waits, the Host timer with and without a claim, the reply queue and `REPLY_QUEUED` |
| `user-questions-projection-test.rkt` | `packages/interaction/user-questions/tests/projection.spec.ts` | rules 23 to 26, including the resume repair code and PTC sub-calls |
| `tool-ask-user-test.rkt` | `packages/interaction/tool-ask-user/tests/tool-ask-user.spec.ts` | both schemas as JSON text, rules 39 and 40, the pending notice |
| `commands-test.rkt` | `packages/interaction/commands/tests/commands.spec.ts`, `builtin.spec.ts` | rules 41 to 50: grammar, scoped shadowing, the lifecycle pair and the id format, `recordInput`, attachment admission errors and order, cancellation before and during admission, thrown handlers, alias resolution |
| `repeat-tool-reminder-test.rkt` | `packages/guard/repeat-tool-reminder/tests/repeat-tool-reminder.spec.ts` | rules 51 to 56: thresholds, transparent excluded tools, key-order-insensitive arguments including index-like keys, reset on user input, the preview cap at exact UTF-16 lengths, reminders on blocked calls |
| `timeout-policy-test.rkt` | `packages/guard/timeout-policy/tests/timeout-policy.spec.ts` | rules 57 to 59: own-deadline classification, the restored cancel event, nested deadlines; the tool's gate is an event, the timeout a real 20 ms deadline with a bounded wait |
| `plan-mode-test.rkt` | `packages/plan/plan-mode/tests/plan-mode.spec.ts`, `projection.spec.ts`, `integration.spec.ts`, `initialization.spec.ts` | rules 60 to 70: the four outcomes of `plan-mode-set!`, commit and narration at pre-step, admission of the exit tool, the review outcomes (approve, keep planning, custom text, duplicate items, dismissal that concludes the turn), command texts |
| `todo-test.rkt` | `packages/todo/tool-todo/tests/tool-todo.spec.ts`, `projection.spec.ts`, `integration.spec.ts`, `loader-composition.spec.ts` | rules 71 to 74 and the schema key order |
| `feedback-test.rkt` | `packages/feedback/command-feedback/tests/command-feedback.spec.ts` | rules 75 to 77 |
| `message-feedback-test.rkt` | `packages/feedback/message-feedback/tests/message-feedback.spec.ts` with `helpers.ts` | rules 78 to 83 against an in-memory `feedback-persistence-port`: version compare-and-set, identical puts, the live durability check, the cold path and `feedback/committed` |
| `plugins-test.rkt` | the loader-composition suites of the packages above | every row of `plugin-table` mounts by its dsh name with the listed inject list; one rejected config per plugin gives `invalid config:`; `check-kernel-restored` after mounting and disposing all of them |

Fixtures: a scripted approval answerer and a scripted question answerer (listeners that take their replies from a list and record the requests); a stub confining shell implementing `confining-shell-port`; an in-memory attachment port; an in-memory persistence port whose handles record appends; the stub agent of `dsh-agent/testing`. Tests sequence tasks with events and semaphores, never with sleeps, except the one bounded deadline of `timeout-policy-test.rkt`.

Recorded sessions under `/home/user/deepseek-harness/snapshots` that exercise this package: `snapshots/session/repeat-tool-reminder`, `todo-write`, `hook-cc-pretool-ask`, `subagent-child-question-rejection`; `snapshots/sdk/approval`, `permission-switch`, `plan-review`, `command-identity`, `command-attachments`; `snapshots/acp/escalation-approved`, `fs-escalation-approved`; `snapshots/web/approval-composer`, `permission-policy-context`, `question-composer`, `question-composer-recommended`, `plan-review`, `feedback-command`, `message-feedback-protocol`. `snapshots/session/todo-write` is already in the wave 3 gate with its `todo/write` rows removed by the loop projection; this package adds `todo/write`, `permission/preset`, `approval/policy`, `approval/asked`, `approval/decided`, `plan/mode`, `command/run`, `command/done` and `feedback/record` to the `#:keep` list of `replay-session-fixture` for the fixtures it can replay. The `sdk`, `acp` and `web` scenarios become replayable in wave 5.

Acceptance gate: `raco test racket/dsh-interaction` passes with no network and no Node; every numbered rule has a test that names it; `check-replays-fixture` reports a match for `snapshots/session/todo-write` and `snapshots/session/repeat-tool-reminder` with this package's event types kept; a scripted session in which a `tools/pre-execute` listener returns `pre-ask` writes `approval/asked` and `approval/decided` between `tool/call` and `tool/result`, once with a scripted answerer (`allowed-once`) and once with none (`unavailable`, and a failed result with code `APPROVAL_UNAVAILABLE`).

## Open questions

1. **Sibling names behind the ports.** The owner procedures of `shell`, `attachments` and `sessionPersistence` were taken from `dsh-exec.md`, `dsh-fs.md` and `dsh-session-store.md` as they stand. Recommended default: keep the wrapper signatures of this document; when the coordinator gives each shared port one home, `dsh-interaction/ports` re-exports it.
2. **Admission of command images.** dsh calls `admitEncodedImages(store, images)`. This contract assumes `attachments-admit-prompt-content` of `dsh-fs` accepts the image parts `{type: "image", mediaType, data, name?}` and returns image blocks in order. Recommended default: if that procedure wants another part form, the wrapper converts; the observable result (durable refs, `AttachmentError` texts) is the same.
3. **Identity of `AttachmentError`.** Rule 44 recognises it by the dsh error name through `harness-error-info`. Recommended default: that test; switch to `attachment-error?` of `dsh-fs` if the coordinator hoists it.
4. **Home of the deadline helper.** `dsh-exec/timeout` and `dsh-session-store` each define one, and `packages/util/timeout` belongs to `dsh-util`. Recommended default: the private helper of rule 58; when `dsh-util` exports `make-deadline` and `timeout-of`, use them and keep the `eq?` test of the own reason. A tool body that asks `timeout-of` for its own code is unaffected either way.
5. **Strings as approval outcomes.** A translated plugin may return `"allowed-once"`. Recommended default: rule 7 as written (symbols only; anything else is `'unavailable`), with the conversion in `dsh-js`, `dsh-sdk` and `dsh-web`. This fails closed.
6. **Lone surrogates in the arguments preview.** JavaScript `slice` can cut a surrogate pair; `utf16-substring` drops the half pair. The preview can therefore differ from dsh by one escaped code unit when the cut falls inside a pair. Recommended default: accept the difference; it is the documented behaviour of `cordis-data`.
7. **`sessionFeedback` without `sessions`.** dsh mounts the service as a child plugin that injects `sessions`; without that service the child stays pending and `/feedback` still works. Recommended default: the nested fiber of the Plugins section.
8. **Projection handles of a registry that is replaced.** `user-questions` registers its projection from a nested fiber and clears its handle when that fiber unloads. Recommended default: read the handle at call time and treat a missing handle as "no continued questions", as dsh does.
