# Interface contract: `dsh-context`

This is the binding interface for `racket/dsh-context/`. It covers what an agent is told beyond its tools: workspace instruction files, clock and tmux readings, harness checkout facts, `@file` and `@session` references, skills, context compaction, and the agent presets that compose all of these into the four Web modes. Sources: [recon 11](../recon/11-agents-context.md) (cited as R11 with its heading), the preset and mode sections of [recon 03](../recon/03-boot-profiles.md) (R3, Algorithms 18 and 19), and `packages/{context,skill,compaction,preset}/*/src` at commit `e8f7b93a3`. When this document and the TypeScript disagree about behaviour, the TypeScript is right and this document gets fixed. When they disagree about names and argument order of the Racket surface, this document is right. Read [dsh-session.md](dsh-session.md), [dsh-llm.md](dsh-llm.md), [dsh-tools.md](dsh-tools.md) and [dsh-agent.md](dsh-agent.md) first; this contract uses their vocabulary without repeating it (`absent`, jobjects, `define-session-event`, `session-append!`, `surface-replace`, `make-user-message`, `text-block`, cancel events, `define-tool`, `system-prompt-section!`, `agent-payload?`, `pre-step-enter`, `projection-definition`).

Package: directory `racket/dsh-context/`, collection `dsh-context`, `(define deps '("base" "cordis" "cordis-data" "cordis-schema" "cordis-yaml" "cordis-loader" "dsh-util" "dsh-session" "dsh-llm" "dsh-tools" "dsh-agent"))`, `(define build-deps '("rackunit-lib" "dsh-test-support"))`. The package requires no sibling wave 4 package at compile time: every service owned by a sibling is reached through `dsh-context/ports` (Services, "Ports").

## Scope

| dsh package | npm name | Status |
|---|---|---|
| `packages/context/agent-instructions` | `@deepseek-ai/dsh-agent-instructions` | native |
| `packages/context/time-context` | `@deepseek-ai/dsh-time-context` | adapted. Zone offsets come from the system tz database (TZif files) in place of ICU; rule 24 lists every difference. |
| `packages/context/tmux-context` | `@deepseek-ai/dsh-tmux-context` | native. The query runs through the `shell` port; tested with a scripted shell, untested against a real tmux on this machine. |
| `packages/context/harness-dev-context` | `@deepseek-ai/dsh-harness-dev-context` | adapted. The checkout root is the root of the repository that holds `racket/dsh-context`; the URL comes from the `webApp` port. Texts are unchanged, including the sentences about `pnpm run dev:web`, because they are recorded prompt text. |
| `packages/context/file-reference` | `@deepseek-ai/dsh-file-reference` | native. A library (service definition, grammar, guidance text); no plugin row. |
| `packages/context/file-reference-local` | `@deepseek-ai/dsh-file-reference-local` | native |
| `packages/context/session-reference` | `@deepseek-ai/dsh-session-reference` | native. The Remote method `candidates` is exported as a table for `dsh-web`. |
| `packages/skill/skill` | `@deepseek-ai/dsh-skill` | native |
| `packages/skill/skill-filesystem` | `@deepseek-ai/dsh-skill-filesystem` | adapted. chokidar is replaced by a polling watcher built on `filesystem-change-evt` where available and on a poll timer otherwise; `watchUsePolling`, `watchStabilityThresholdMs`, `watchPollIntervalMs` and `watchFollowSymlinks` keep their keys and meaning. |
| `packages/skill/tool-skill` | `@deepseek-ai/dsh-tool-skill` | native |
| `packages/skill/skill-office` | `@deepseek-ai/dsh-skill-office` | native provider; the four `SKILL.md` files ship as data. What the skills need at run time is outside this package: a Python with `python-docx`, `python-pptx`, `openpyxl` and the other libraries the bodies name (from `load_workspace_dependencies` or the user's Python), and the Office render tools of `@deepseek-ai/dsh-tool-office` for the verification steps. Without them the skills load and their instructions tell the model what is missing. |
| `packages/skill/tool-workspace-dependencies` | `@deepseek-ai/dsh-tool-workspace-dependencies` | native tool. The payload (a packaged Python and optional Node and pnpm tree with `runtime.json`) is a packaging product that this port does not build; `source` is a required config key, so the row mounts only where a payload exists. |
| `packages/compaction/compaction` | `@deepseek-ai/dsh-compaction` | native. A library (service definition, events, checkpoint source, tool-pairing balance); no plugin row. |
| `packages/compaction/compaction-basic` | `@deepseek-ai/dsh-compaction-basic` | native |
| `packages/compaction/compaction-tool-result-pruner` | `@deepseek-ai/dsh-compaction-tool-result-pruner` | native |
| `packages/compaction/compaction-image-offload` | `@deepseek-ai/dsh-compaction-image-offload` | native |
| `packages/compaction/command-compact` | `@deepseek-ai/dsh-command-compact` | native |
| `packages/preset/agent-preset-registry` | `@deepseek-ai/dsh-agent-preset-registry` | adapted. The preset subtree is mounted through the entry tree of `cordis-loader`; the leak audit reads the kernel's fiber and realm accessors in place of the Cordis service store; Remote methods are exported as a table. |
| `packages/preset/agent-preset` | `@deepseek-ai/dsh-agent-preset` | native; `skills/dsh-doc` ships as data |
| `packages/preset/persona` | `@deepseek-ai/dsh-persona` | native |

Not applicable: Zod state schemas (projection states are checked by the contracts in Data), `TypertRemoteService` decorators, and the client halves of these packages.

## Modules

| Module | Provides |
|---|---|
| `dsh-context` (`main.rkt`) | re-exports `skills`, `compaction`, `preset`, `file-reference`, `sources` |
| `dsh-context/ports` | the late-bound ports to sibling services (Services, "Ports") |
| `dsh-context/data` | `agent-preset-package-root`, `office-asset-root`, `npm-package-roots`, `harness-checkout-root` |
| `dsh-context/sources` | constructors and predicates for the message sources of Data; `system-reminder-frame`; `ensure-event-type!` |
| `dsh-context/agent-instructions` | `resolve-instruction-config`, `find-project-root`, `discover-baseline-instruction-files`, `load-baseline-instructions`, `render-agent-instructions`, `render-instruction-changes`, `instruction-content-sha1`, `workspace-baseline-identity`, the `instruction-file` structs |
| `dsh-context/time-context` | `format-timestamp`, `format-duration`, `canonicalize-time-zone`, `zone-offset-seconds`, `process-time-zone`, `derive-browser-time-zone-context`, `time-context-projection` |
| `dsh-context/file-reference` | the `fileReferences` service definition, `gen:file-reference-provider`, `active-at-token`, `format-file-mention`, `file-reference-prompt` |
| `dsh-context/file-search` | `make-workspace-file-search`, `workspace-file-search-list`, `-invalidate!`, `-dispose!` |
| `dsh-context/session-reference` | the `sessionReferenceResolver` service definition and procedures, `encode-session-reference-uri`, `decode-session-reference-uri`, `parse-session-references`, `format-session-mention`, `session-reference-remote-methods`, `exn:fail:session-reference` |
| `dsh-context/skills` | the `skills` service definition and procedures, `gen:skill-provider`, the skill structs, `skill-name?`, `model-invocable?`, `user-invocable?`, `render-skill-content`, `escape-skill-text`, `bundled-skill-rank`, the `skills/change` event |
| `dsh-context/skill-filesystem` | `parse-skill-frontmatter`, `parse-skill-text`, `make-filesystem-skill-provider` |
| `dsh-context/compaction` | the `compaction` service definition and procedures, `gen:compaction-engine`, `compaction-result`, `exn:fail:compaction:manual`, the four `compaction/*` session event declarations, `compact-checkpoint-source`, `compact-checkpoint-source?`, `tool-pairing-balanced-before?`, `tool-pairing-balanced-after?`, the `compaction/summary-error` event |
| `dsh-context/compaction-basic` | `resolve-compaction-config`, `resolve-target-policy`, `resolve-compact-spec`, `select-compactable-range`, `frame-summary`, `compaction-instruction`, `make-basic-compaction-engine`, `exn:fail:compaction:target-config` |
| `dsh-context/tool-result-pruner` | the `toolResultPruner` service definition and procedures, `prune-marker`, `resolve-pruner-config` |
| `dsh-context/image-offload` | the `image/offload` declaration, `image-offload-projection`, `offload-oldest-images!`, `offload-message-images` |
| `dsh-context/preset` | the `agentPresets` service definition and procedures, `entry-list-problem`, `agent-preset-projection`, the `agent-preset/selected` session event and Cordis event, `agent-presets-remote-methods` |
| `dsh-context/plugin/<name>` | one module per row of the plugin table; each provides `plugin` |
| `dsh-context/plugins` | `plugin-table` |

Private modules, suggested: `private/collate.rkt` (`locale-string<?`), `private/tzif.rkt`, `private/instructions-{files,render,state}.rkt`, `private/skill-registry.rkt`, `private/skill-watch.rkt`, `private/compaction-{config,region,summarizer}.rkt`, `private/preset-{mount,tree,inventory}.rkt`, `private/session-reference-{projection,spill}.rkt`. `private/preset-tree.rkt` is the only module that requires `cordis-loader`.

Data files, copied byte for byte from the TypeScript tree and never edited: `racket/dsh-context/data/agent-preset/skills/dsh-doc/**` from `packages/preset/agent-preset/skills/dsh-doc/**`, a file `racket/dsh-context/data/agent-preset/package.json` holding `{"name":"@deepseek-ai/dsh-agent-preset"}`, and `racket/dsh-context/data/skill-office/assets/{office,office-docx,office-pptx,office-xlsx}/SKILL.md` from `packages/skill/skill-office/assets/`. `info.rkt` lists `data` under `compile-omit-paths`.

## Data

### Message sources

Every context message is a user message built with `(make-user-message #:content blocks #:source source)`, so its keys are `content`, `source`, `role`, `id`. Sources are jobjects with keys in this order; they are durable.

| Constructor in `dsh-context/sources` | Keys in write order |
|---|---|
| `(agent-instructions-source changes #:baseline-identity [identity absent])` | `kind: "agent-instructions"`, `form: "instructions"`, `baseline?: true`, `baselineIdentity?`, `changes`. `baseline` and `baselineIdentity` are written together, exactly when an identity is given. A change is `{action, scope, path, digest?}` with `action` one of `set`, `replace`, `remove`. |
| `(snapshot-source kind text)` | `kind` (`"time-context"` or `"tmux-context"`), `form: "snapshot"`, `sections: [{name: <kind>, text}]` |
| `(session-reference-source references)` | `kind: "session-reference"`, `form: "recall"`, `version: 1`, `references`. An item is `{sessionId, label, capturedFormatVersion, capturedThroughSeq, compacted, originalMessages, retainedMessages, omittedMessages, omittedBytes, truncated, inputIndex}`. |
| `(skill-catalog-source entries #:update? [u #f] #:incomplete? [i #f])` | `kind: "skill-catalog"`, `form: "catalog"`, `update?: true`, `entries: [{name, description}…]`, `incomplete?: true` |
| `(skill-invocation-source name)` | `kind: "skill-invocation"`, `name`, `form: "instructions"` |
| `(compact-checkpoint-source compaction-id [source-command-id absent])` | `kind: "compact-checkpoint"`, `compactionId`, `sourceCommandId?` |

### Session events declared here

Declared with `define-session-event`; none is surface-eligible or ignorable; every tag is in `known-session-event-types`. Each owning plugin body calls `(ensure-event-type! ctx <id>-type)` (rule 3).

| Racket id | Module | Data fields in write order (JSON key: contract) |
|---|---|---|
| `compaction/start` | `compaction` | `compactionId`: `string?`; `sourceCommandId?`: `string?`; `turn`: `(or/c session-seq? 'null)` |
| `compaction/summary` | `compaction` | `compactionId`; `sourceCommandId?`; `summary`: list of text blocks; `rawOutput?`: list of blocks; `llmStreamCall?`: `#t` (requires `rawOutput`); `shadowedRange`: `{start, end}`; `shadowedSeqs`: `(listof session-seq?)`; `shadowedTokenCount`: `exact-nonnegative-integer?`; `provider`: `string?`; `model`: `string?`; `maxTokens?`; `usage?`: token usage |
| `compaction/end` | `compaction` | `compactionId`; `sourceCommandId?`; `turn`; `error?`: `string?` |
| `compaction/prune` | `compaction` | `shadowedRange`; `shadowedSeqs`; `shadowedTokenCount` |
| `image/offload` | `image-offload` | `targets`: non-empty list of `{seq, imageIndexes}` |
| `agent-preset/selected` | `preset` | `agentPreset`: `string?` |

`shadowedRange` is a pair of surface positions named by seq; `start` may be numerically greater than `end` after earlier replacements. `shadowedSeqs` is authoritative.

### Projections

Each is a `projection-definition` of `dsh-llm/ports`. `null` is `'null`.

| Key | `stateVersion` | State, keys in order | Wire view | Owner plugin |
|---|---|---|---|---|
| `agentPreset` | 1 | a string or `null`; initially the header's `agentPreset`, else `null` | the state; in summaries | `agent-preset-registry` |
| `timeContext` | 3 | `{lastMessageTime, lastInjectionTime, lastTurnInjectionTime, browserTurn, browserTimeZones}`; the first four a number or `null`, the last a list of strings; initially all `null` and `[]` | none | `time-context` |
| `tmuxContext` | 1 | `null` or `{state, time}` | none | `tmux-context` |
| `harnessDevLegacyPrompt` | 1 | `{source, web}`, each a string or `null` | none | `harness-dev-context` |

Message projection (registered with `sessions-register-message-projection!`): `image-offload-projection`, type `image/offload`.

### Skills (`dsh-context/skills`)

Skill records are process-local structs; only `resource-base` and catalog entries reach JSON.

```racket
(struct skill-invocation (model-invocable? user-invocable?) #:transparent)
(struct skill-summary (name description when-to-use invocation source provider resource-base path) #:transparent)
(struct skill-candidate skill-summary (rank locator metadata) #:transparent)    ; rank : real?; locator : any/c; metadata : (or/c jobject? #f)
(struct skill-definition skill-summary (content metadata) #:transparent)       ; content : string?
(struct skill-observation (candidates complete?) #:transparent)
(struct skill-snapshot (skills complete?) #:transparent)                        ; skills : (listof skill-summary?)
(struct skill-provider-control (cancel invalidate))                             ; cancel : evt?; invalidate : (-> void?)
(define-generics skill-provider
  (skill-provider-name skill-provider)                                 ; -> string?
  (skill-provider-list skill-provider cwd cancel)                      ; -> (or/c (listof skill-candidate?) skill-observation?), may wait
  (skill-provider-load skill-provider candidate cwd cancel))           ; -> (or/c skill-definition? #f), may wait
(skill-name? s) -> boolean?                      ; #px"^[a-z0-9]+(?:-[a-z0-9]+)*$"
(model-invocable? skill) (user-invocable? skill) -> boolean?
bundled-skill-rank                               ; 600
```

`when-to-use`, `resource-base` and `path` are `#f` when absent. `source` is a string (`project-dsh`, `project-agents`, `runtime`, `custom`, `user-dsh`, `user-agents`, `bundled`, or any other). `resource-base` is `#f` or one of the jobjects `{kind: "directory", path}`, `{kind: "url", url}`, `{kind: "opaque", description}`. `cwd` is a path string or `#f`; `cancel` a cancel event or `#f`.

### Compaction (`dsh-context/compaction`)

```racket
(struct compaction-result (compaction-id source-command-id start-seq summary-seq end-seq
                           summary shadowed-range shadowed-seqs shadowed-token-count) #:transparent)
(struct exn:fail:compaction:manual exn:fail (code cause))    ; code : 'busy 'cancelled 'changed 'summary 'commit 'persistence
(struct exn:fail:compaction:target-config exn:fail (target-key))
(define-generics compaction-engine
  (engine-compact-if-needed compaction-engine agent trigger cancel)        ; trigger : 'pressure 'context-overflow; -> (or/c compaction-result? #f), waits
  (engine-compact-now compaction-engine agent cancel source-command-id)    ; -> (or/c compaction-result? #f), waits
  (engine-compact-region compaction-engine start end agent cancel))        ; -> compaction-result?, waits
(struct summarization-input (tools messages) #:transparent)                ; tools : (or/c #f (listof jobject?))
(struct summary-result (summary provider model max-tokens usage raw-output llm-stream-call?) #:transparent)
```

`exn:fail:compaction:manual` is dsh `ManualCompactionError`; it is not an `exn:fail:harness`. `source-command-id` is a string or `#f`. `shadowed-range` is a pair `(cons start end)`.

### Presets (`dsh-context/preset`)

A *preset definition* is the validated config of one `@deepseek-ai/dsh-agent-preset` row: `(struct preset-definition (id name description order plugins))`, with `plugins` the list of entry rows exactly as the loader handed them over (jobjects that may hold `js-expr` values). Values that cross to user interfaces are jobjects: a roster row `{id, name?, description?, order?, broken?}`; a Remote roster `{presets: [{…row, isDefault}…]}`; a document `{agentPreset, content, name?, description?}`; an inspection `{id, modules: [{moduleName, baseUrl?, useHostBase}…], leakedServices}`; an inventory entry `{id, name?, description?, isDefault, broken?, rows: [{entryId, moduleName, enabled, condition?, fiberState?}…]}` with `enabled` `#t`, `#f` or `"conditional"`. A *generation* is the private record `{scope, key, mount, users, retired?}` of one mounted revision; its `key` is a fresh instance of the opaque struct `preset-scope-key` and is the scope key that bound agents get as scope parent. Coded failures are `(struct exn:fail:agent-preset exn:fail:harness (details))` (Services, `agentPresets`).

### Agent instructions, references

```racket
(struct instruction-file (absolute-path display-path) #:transparent)
(struct loaded-instruction-file instruction-file (content version) #:transparent)       ; version : any/c or #f, the fs freshness token
(struct truncated-instruction (display-path original-bytes included-bytes) #:transparent)
(struct rendered-instructions (text omitted truncated) #:transparent)
(struct at-token (prefix query quoted?) #:transparent)
(struct exn:fail:session-reference exn:fail (code cause))    ; code : one of the seven SESSION_REFERENCE_* strings
```

A file reference candidate is the jobject `{path, kind}` with `kind` `"file"` or `"directory"`. A session reference input is `{sessionId, label?}`.

## Services

`x` is a context or a handle for the service; "the caller's context" is `(use-context x)`.

### Ports (`dsh-context/ports`)

Services owned by sibling wave 4 packages and by wave 5 are called only through this module. Each port is a generic interface declared here, with the convention of [WAVE3.md](WAVE3.md): a method takes the provider's value first and, when it registers an effect, the owning context second. Each port also has a wrapper procedure, listed below, that takes a context, reads the service with `ctx-get` and calls the method when the mounted value implements the interface (test doubles and providers that adopt the interface do). Otherwise the wrapper calls the owner's own procedure named in the third column, resolved once with `dynamic-require`; a missing module or binding raises `exn:fail` `dsh-context: port <name> cannot reach <module> <binding>`. `port-…?` predicates report whether the service is mounted. The fallback exists because the wave 4 packages are built at the same time and a provider cannot require every consumer's port module.

| Port procedure | Service key | Assumed owner procedure |
|---|---|---|
| `(port-working-directory-ensure ctx agent cancel) -> path-string?` | `workingDirectory` | `dsh-session-store/working-directory` `(working-directory-ensure ctx agent #:cancel cancel)` |
| `(port-fs ctx) -> (or/c fs-port? #f)`; `(port-fs-resolve fs path) -> target`; `(port-fs-stat fs target cancel) -> (or/c #f fs-stat?)` with `(struct fs-stat (type size version))`, `type` one of `'file`, `'directory`, `'other`; `(port-fs-read-text fs target cancel #:max-bytes [n #f]) -> (or/c string? #f)` (`#f` when the text exceeds `n` bytes); `(port-fs-list-dir fs target) -> (listof fs-entry?)` with `(struct fs-entry (name type display-path))`; `(port-fs-process-path fs target) -> string?`; `(port-fs-display-path target) -> string?` | `fs` | `dsh-fs/fs`: `fs-resolve`, `fs-stat` (an `fs-info`), `fs-read-text`, `fs-stream-text` for the bounded read, `fs-list-dir` (`fs-dir-entry` values), `fs-process-path`, `fs-target->jvalue` for the display path; failures are harness errors named `FsError` with codes `FS_NOT_FOUND`, `FS_NOT_DIRECTORY`, `FS_NOT_TEXT` |
| `(port-shell-run ctx command cancel) -> (or/c #f (cons/c exact-integer? string?))` (exit code, stdout text) | `shell` | `dsh-exec/shell`: `make-shell-request`, `shell-resolve`, `shell-execute`, `shell-execution-result`, `shell-run-result-exit-code` and the `text` of its `stdout` |
| `(port-commands-register! ctx #:definition-id id #:name n #:description d #:handler h) -> disposer?`; `(invocation-raw-input i)`, `(invocation-agent i)`, `(invocation-cancel i)`, `(invocation-command-id i)` | `commands` | `dsh-interaction/commands` `commands-register!` and the invocation accessors; a handler returns the jobject `{kind, text, sourceEventSeq?}` |
| `(port-session-query-list ctx cancel) -> (listof jobject?)`; `(port-session-query-read-surface ctx id) -> jobject?` | `sessionQuery` | `dsh-session-store/query` `session-query-list-sessions`, `session-query-read-surface` |
| `(port-spill-save ctx #:session-id id #:name suggested #:source source #:text text) -> jobject?` (the spill reference as JSON) | `spillStore` | `dsh-fs/spill`: `spill-save-text` |
| `(port-web-app-url ctx) -> string?` | `webApp` | `dsh-web` `web-app-advertised-url` |
| `(port-profile-preflight ctx rows base-url) -> list?` | `profileContext` | `dsh-boot` `prepare-profile-entries`; without the service the rows are returned unchanged |

The projection registry (`sessionProjections`) and the settings opt-out (`settings`) use `gen:projection-port` and `gen:settings-port` of `dsh-llm/ports`. The entry tree of the loader is reached through `private/preset-tree.rkt` (rule 93).

### `skills` (key `'skills`)

`(define-service skills 'skills #:contract skill-registry?)` in `dsh-context/skills` defines `skills-key`, `skills-ref`, `skills-get`, `provide-skills`. The dsh method `get(name)` is therefore named `skills-load`.

```racket
(skills-register-provider! x create) -> disposer?     ; create : (-> skill-provider-control? skill-provider?), called synchronously
(skills-register! x skill) -> disposer?               ; skill : skill-definition? whose invocation and provider may be #f
(skills-list x #:cwd [cwd #f] #:cancel [cancel #f] #:scope [scope #f]) -> (listof skill-summary?)        ; waits
(skills-snapshot x #:cwd [cwd #f] #:cancel [cancel #f] #:scope [scope #f]) -> skill-snapshot?           ; waits
(skills-load x name #:cwd [cwd #f] #:cancel [cancel #f] #:scope [scope #f]) -> (or/c skill-definition? #f)   ; waits
(render-skill-content skill) -> string?               ; skill : skill-definition? or a jobject {name, provider, resourceBase?, content}
```

| Procedure | Errors | Effect on the caller's context |
|---|---|---|
| `skills-register-provider!` | provider name `runtime`: `"runtime" is reserved for runtime skill registrations`; duplicate in the layer: `a skill provider named "<name>" is already registered` (global) or `… is already registered in this scope` | one effect `skills.registerProvider()` in the caller's scope layer; the control's cancel event becomes ready, with the failure or `skill provider "<name>" disposed`, when registration fails or the effect is reverted |
| `skills-register!` | `invalid skill name "<name>"`; `skill "<name>" requires a description`; the invocation messages of rule 41 | one effect `skills.register()`; a same-name runtime skill in the layer logs `runtime skill "<name>" ignored because it is already registered` at `warning` and returns a disposer that does nothing |
| the three readers | rule 42 to 45; cancellation raises the cancel reason | none |

### `compaction` (key `'compaction`)

`(define-service compaction 'compaction #:contract compaction-engine?)` in `dsh-context/compaction`.

```racket
(compaction-compact-if-needed x agent trigger cancel) -> (or/c compaction-result? #f)
(compaction-compact-now x agent cancel [source-command-id #f]) -> (or/c compaction-result? #f)
(compaction-compact-region x start end agent [cancel #f]) -> compaction-result?
(tool-pairing-balanced-before? session seq) (tool-pairing-balanced-after? session seq) -> boolean?
(make-basic-compaction-engine ctx config #:summarize [summarize #f]) -> compaction-engine?
```

The three service procedures call the generic method on the mounted engine. `summarize` is `(-> summarization-input? agent? (or/c evt? #f) summary-result?)` and replaces the model call (dsh's protected `summarize` hook); the default is rule 75. None registers an effect on the caller.

### `toolResultPruner` (key `'toolResultPruner`)

```racket
(pruner-measure-content x blocks) -> exact-nonnegative-integer?        ; code points over text blocks
(pruner-prune-content x blocks) -> (or/c (listof jobject?) #f)
(pruner-prune-session! x session) -> (values (listof jobject?) exact-nonnegative-integer?)   ; pruned entries, chars removed
```

A pruned entry is `{originalSeq, replacementSeq, callId, charsBefore, charsAfter}`. All three return without waiting.

### `fileReferences` (key `'fileReferences`)

```racket
(define-generics file-reference-provider
  (file-reference-provider-list file-reference-provider agent query cancel))   ; -> (listof jobject?), waits
(file-references-list x agent query cancel) -> (listof jobject?)
(active-at-token line cursor-col) -> (or/c at-token? #f)       ; cursor-col in UTF-16 units
(format-file-mention candidate preserve-quote?) -> (or/c string? #f)
file-reference-prompt                                           ; rule 29
```

### `sessionReferenceResolver` (key `'sessionReferenceResolver`)

```racket
(session-reference-list-candidates x agent [query ""] [limit #f] #:cancel [cancel #f]) -> (listof jobject?)   ; waits
(session-reference-prepare x agent content references route #:cancel [cancel #f]) -> (values (listof jobject?) (or/c jobject? #f))
(encode-session-reference-uri session-id) -> string?
(decode-session-reference-uri uri) -> string?
(parse-session-references text) -> (values string? (listof jobject?))    ; readable text, references in order
(format-session-mention session-id label) -> string?
session-reference-remote-methods                                          ; (list (cons "candidates" procedure))
```

`route` is `{provider, model}` or `#f`. `session-reference-prepare` returns the content and the context message. A candidate is `{sessionId, cwd?, label, displayTitle?}` and, from the Remote method, also `mention`.

### `agentPresets` (key `'agentPresets`)

`(define-service agent-presets 'agentPresets #:contract agent-preset-registry?)` in `dsh-context/preset`.

```racket
(agent-presets-default-id x) -> string?
(agent-presets-register! x definition) -> disposer?                 ; waits until activation or its failure has settled
(agent-presets-list x) -> (listof jobject?)                         ; waits
(agent-presets-resolve x [id #f]) -> jobject?                       ; {id, broken?}; waits
(agent-presets-read-document x id) -> jobject?
(agent-presets-mount! x agent-ctx [id #f]) -> jobject?              ; {id}; waits
(agent-presets-compose-from! x child-ctx parent-ctx) -> (or/c string? #f)
(agent-presets-composed-preset x agent-ctx) -> (or/c string? #f)
(agent-presets-preset-for-session x session) -> (or/c string? 'null)
(agent-presets-service-for x agent key) -> any/c                    ; the service value or #f
(agent-presets-recompose! x agent-ctx id) -> jobject?               ; waits
(agent-presets-select! x agent id) -> string?                       ; waits
(agent-presets-acquire-scope x [id #f]) -> (values scope-key? (-> void?))   ; a lease and its release; waits
(agent-presets-inspect-compositions x [agent-ctx #f]) -> (listof jobject?)
(agent-presets-composition-inventory x) -> (listof jobject?)        ; waits
agent-presets-remote-methods    ; (list (cons "list" …) (cons "read" …) (cons "select" …))
```

| Procedure | Errors | Effects |
|---|---|---|
| `agent-presets-register!` | `Preset id must not be empty`; `Duplicate agent preset: <id>` | one effect `agentPresets.register()` on the caller's context whose asynchronous setup is the activation (rule 92) and whose inverse removes the definition and retires its generation (rule 95). The caller is the preset row's fiber. |
| `agent-presets-mount!`, `-recompose!` | `agent-preset/not-found`, `agent-preset/invalid` (rule 96); `Agent preset binding requires a scoped context` | on the first binding of an agent scope, one effect `agent-preset.binding` on `agent-ctx` whose inverse removes the binding and releases the generation |
| `agent-presets-compose-from!` | `Parent preset revision is unavailable`; `Child preset binding requires a scope`; `Child already joined a preset` | the same binding effect on `child-ctx` |
| `agent-presets-select!` | `agent-preset/locked`; those of `recompose!` | those of `recompose!`; appends `agent-preset/selected` |
| the readers | `agent-preset/not-found` from `resolve` and `read-document` | none |

The three coded failures are values of `(struct exn:fail:agent-preset exn:fail:harness (details))`, made by `(make-agent-preset-error code message details)`, with dsh error name `RemoteError`, the code as given, and details `{agentPreset, available}`, `{agentPreset, reason}` or `{sessionId, agentPreset}`; their messages are `Unknown agent preset: <id>`, the reason itself, and `This session has already started`. The substruct carries the details, as `exn:fail:llm-discovery-rejected` does in `dsh-llm`, so nothing depends on a details field of `exn:fail:harness`; `dsh-web` maps them to its remote error type. Other failures are `exn:fail` with the exact message.

### Waiting and cancellation

- `skills-list`, `skills-snapshot`, `skills-load`, `file-references-list`, `session-reference-list-candidates`, `session-reference-prepare`, the three `compaction-…` procedures: the `cancel` argument; cancellation raises the cancel reason, except `session-reference-prepare`, which raises `exn:fail:session-reference` with code `SESSION_REFERENCE_CANCELLED` and message `session reference preparation was cancelled`.
- `compaction-compact-now`: rule 79 states the precedence between the caller's event and the agent's maintenance event.
- `agent-presets-register!`, `-mount!`, `-recompose!`, `-select!`, `-list`, `-resolve`, `-acquire-scope`, `-composition-inventory` take no cancel event, as in dsh; they wait for fibers of the preset tree and for `loader` quiescence. A break delivered to the waiting task propagates; a retained generation is released in a `dynamic-wind` post thunk.
- Every `agent/pre-step`, `agent/request` and `agent/request-error` listener of this package observes the `'cancel` entry of its payload at the points the rules state.

## Events

```racket
(define-event skills/change 'skills/change #:mode emit #:args ())
(define-event compaction/summary-error 'compaction/summary-error #:mode waterfall
  #:args (hash?) #:result boolean?)
(define-event agent-preset/selected 'agent-preset/selected #:mode emit #:args (string? string?))
```

| Event | Dispatched by, when | Guarantees |
|---|---|---|
| `skills/change` | the skill registry on every cache invalidation (a registration, its disposal, a provider's `invalidate`) | Unfiltered. Listeners are resolved with `ctx-dispatch-callbacks` and each is contained; failures are logged at `warning` as `skills/change listener threw: <message>` or `skills/change listener rejected: <message>`. |
| `compaction/summary-error` | `compaction-basic`, when summarisation raises and the cancel event is not ready (rule 74) | Payload: an immutable `hasheq` with `'session`, `'sourceEventSeqs`, `'error` and, when given, `'cancel`. A listener is `(lambda (payload next) …)`. The innermost step returns `#f`. Return `#t` only after recording a durable change to the selected input. |
| `agent-preset/selected` | the preset registry, from its `session/event` listener, once per `agent-preset/selected` session event, with the session id and the preset id | Unfiltered `emit`; a listener failure propagates to the append's contained invocation and is logged there. |

`dsh-context/skills` exports `on-skills/change`; `dsh-context/compaction` exports `on-compaction/summary-error` and `dispatch-compaction/summary-error` (a replacement engine needs the dispatcher); `dsh-context/preset` exports `on-agent-preset/selected`. The preset registry also dispatches `tools/change` through `dispatch-tools/change` of `dsh-tools/tools`.

Consumed, owned elsewhere: `agent/pre-step` (compaction-basic before `next`; agent-instructions, tool-skill twice, and with `#:prepend? #t` time-context, tmux-context, session-reference, all after `next`); `agent/request` with `#:prepend? #t`, `agent/request-error`, `agent/status` (compaction-basic); `agent/request-error` (image offload); `agent/created`, `agent/disposed` (file-reference-local); `session/event` (compaction-basic, agent-instructions, file-reference-local, the preset registry); `tools/result` (agent-instructions); `fs/observed`, registered by name with `ctx-on` (skill-filesystem; arguments `(target observation actor)`, read with `port-fs-display-path` and, when the actor is a tool definition or a jobject, its name).

## Tools

Both are declared with `define-tool` inside their plugin body, so the handlers close over the plugin's handles.

### `skill` (`tool-skill/src/index.ts:84`)

```racket
(define-tool skill-tool
  #:name "skill"
  #:description "Load the full instructions for a skill. Call it before acting on a task that names or clearly matches a skill in the session skill catalog."
  #:parameters ([name (v-string #:description "The exact skill name from the available skills list.") #:required])
  #:output skill-output-spec
  (render (value) (list (text-block (render-skill-content value))))
  (execute (exec) …)                                   ; rule 53
  (present-call () (jobj [card "generic"] [title (string-append "Load skill " name)] [kind "read"] [rawInput name])))
```

`skill-output-spec` is the closed object (`#:additional? #f`) with properties in this order: `name` (string, required), `provider` (string, required), `resourceBase` (a `v-one-of` of three closed objects: `{kind: string const "directory" required, path: string required}`, `{kind: const "url", url}`, `{kind: const "opaque", description}`), `content` (string, required). The value is the jobject `{name, provider, resourceBase?, content}`. Errors, each an `exn:fail` that the pipeline turns into an error result: `invalid skill name "<name>"`; `skill "<name>" is unknown or no longer available`; `skill "<name>" is not available for model invocation`. No approval, not concurrency-safe.

### `load_workspace_dependencies` (`tool-workspace-dependencies/src/index.ts:294`)

Name `load_workspace_dependencies`; description: the string at `index.ts:296-303`, copied verbatim (R11 "`load_workspace_dependencies`"). No parameters. Output: the jobject `{python, node?, pnpm?, pythonPackages, nodePackages?, pythonDistributions}`, rendered as `(jvalue->string value #:indent 2)`. The first call validates the payload in place or installs it (rule 61); the result is memoised per plugin instance and the memo is cleared when the attempt fails. Errors are the `primary runtime: …` messages of the source file.

### Human command `/compact`

Not a model tool. Registered through `port-commands-register!` with definition id `@deepseek-ai/dsh-command-compact`, name `compact`, description `Compact older conversation history`. Rule 89.

## Plugins

Every `#:name` is the npm name; `#:meta` records the dsh plugin name under `'dsh-name`.

| dsh npm name | Module | Inject | Provides |
|---|---|---|---|
| `@deepseek-ai/dsh-agent-instructions` | `plugin/agent-instructions` | `agents`, `workingDirectory`; optional `fs` | none |
| `@deepseek-ai/dsh-time-context` | `plugin/time-context` | `agents`, `sessionProjections` | none |
| `@deepseek-ai/dsh-tmux-context` | `plugin/tmux-context` | `agents`, `sessionProjections`; optional `shell` | none |
| `@deepseek-ai/dsh-harness-dev-context` | `plugin/harness-dev-context` | `systemPrompt`, `sessionProjections`, `webApp` | none |
| `@deepseek-ai/dsh-file-reference-local` | `plugin/file-reference-local` | `agents`, `workingDirectory` | `fileReferences` |
| `@deepseek-ai/dsh-session-reference` | `plugin/session-reference` | `sessionQuery`; optional `llm`, `spillStore`, `sessions`, `sessionProjections`, `sessionProjectionCache` | `sessionReferenceResolver` |
| `@deepseek-ai/dsh-skill` | `plugin/skill` | none | `skills` |
| `@deepseek-ai/dsh-skill-filesystem` | `plugin/skill-filesystem` | `skills`; optional `fs` | none |
| `@deepseek-ai/dsh-tool-skill` | `plugin/tool-skill` | `agents`, `tools`, `skills`, `workingDirectory` | none |
| `@deepseek-ai/dsh-skill-office` | `plugin/skill-office` | `skills` | none |
| `@deepseek-ai/dsh-tool-workspace-dependencies` | `plugin/tool-workspace-dependencies` | `tools` | none |
| `@deepseek-ai/dsh-compaction-basic` | `plugin/compaction-basic` | `llm`, `tokenMeter`, `sessions`; optional `toolResultPruner` | `compaction` |
| `@deepseek-ai/dsh-compaction-tool-result-pruner` | `plugin/compaction-tool-result-pruner` | `tokenMeter`, `sessions` | `toolResultPruner` |
| `@deepseek-ai/dsh-compaction-image-offload` | `plugin/compaction-image-offload` | `agents`, `sessions` | none |
| `@deepseek-ai/dsh-command-compact` | `plugin/command-compact` | `commands`, `compaction` | none |
| `@deepseek-ai/dsh-agent-preset-registry` | `plugin/agent-preset-registry` | `loader`, `sessionProjections`, `agents`; optional `settings` | `agentPresets` |
| `@deepseek-ai/dsh-agent-preset` | `plugin/agent-preset` | `agentPresets` | none |
| `@deepseek-ai/dsh-persona` | `plugin/persona` | `systemPrompt` | none |

`sessions` is added to the pruner's inject list because the Racket body registers event types (rule 3); it changes nothing for a dsh configuration, which always mounts `sessions` on the host plane.

Config schemas (exactly the dsh keys; "unknown keys fail" means the schema is closed). A rejected config fails the mount with `exn:fail:cordis:validation`, whose message starts `invalid config:` (WAVE3.md, "Config validation text"):

| Plugin | Field | Type | Default |
|---|---|---|---|
| agent-instructions | `maxBytes` | number, required | none |
| | `maxSourceBytes` | integer ≥ 1 | `1048576` |
| | `projectRootMarkers` | array of string | `[".git"]` |
| | `instructionFileCandidates` | array of string | `["AGENTS.md", "CLAUDE.md"]` |
| | `localInstructionFileCandidates` | array of string | `["AGENTS.local.md", "CLAUDE.local.md"]` |
| time-context | `timeZone` | string | absent |
| | `refreshIntervalMs` | number | absent (reads as `600000`) |
| tmux-context | `refreshIntervalMs` | number | absent |
| harness-dev-context | none | | |
| file-reference-local | `maxResults` | integer ≥ 1 | `20` |
| | `maxEntries` | integer ≥ 1 | `50000` |
| | `excludedDirectories` | array of string | `.git node_modules dist build out coverage target .next .nuxt .turbo .venv __pycache__ .pytest_cache .mypy_cache .gradle` |
| session-reference | `maxReferences` | integer 1 to 3 | `3` |
| | `candidateLimit` | integer ≥ 1 | `50` |
| | `maxReferenceBytes` | integer ≥ 1 | absent |
| | `referenceContextFraction` | number 0 to 1 | `0.2` |
| skill | `collectCacheMaxEntries` | number | `128` |
| skill-filesystem | `providerName` | string, at least 1 character | `"filesystem"` |
| | `includeDefaultRoots` | boolean | `true` |
| | `dshHome`, `agentsHome` | string | absent |
| | `customSkillDirs` | array of string | `[]` |
| | `watch` | boolean | `true` |
| | `watchUsePolling` | boolean | `false` |
| | `watchStabilityThresholdMs` | number | `200` |
| | `watchPollIntervalMs` | number | `100` |
| | `watchMaxProjects` | number | `128` |
| | `watchFollowSymlinks` | boolean | `true` |
| | `bundledSkillDir` | string | absent |
| tool-skill | `catalogDescriptionMaxLength` | number | `500` |
| skill-office | `assetRoot` | string, at least 1 character | absent (reads as `office-asset-root`) |
| | `pythonEnvironment` | `"workspace-dependencies"` or `"user"` | `"workspace-dependencies"` |
| tool-workspace-dependencies | `source` | string, at least 1 character, required | none |
| | `root` | string, at least 1 character | absent |
| compaction-basic | rule 65 | | unknown keys fail |
| tool-result-pruner | `thresholdChars` | integer ≥ 1 | `8192` |
| | `headChars` | integer ≥ 0 | `4096` |
| | `tailChars` | integer ≥ 0 | `1024`; unknown keys fail |
| image-offload, command-compact | none (`#:config #f`) | | |
| agent-preset-registry | `default` | string, required | none |
| | `selectedDefault` | string, volatile | absent |
| agent-preset | `id` | string, required | none |
| | `name`, `description` | string | absent |
| | `order` | number | absent |
| | `plugins` | array of any, required | none |
| persona | `prefix` | string, required | none |
| | `suffix` | string | `""` |
| | `complete` | boolean | `false` |
| | `includeRuntimeContext` | boolean | `true` |

Load-time checks beyond the schema, each raising `exn:fail` with the exact message: skill `skill: collectCacheMaxEntries must be an integer greater than or equal to 1`; tool-skill `tool-skill: catalogDescriptionMaxLength must be an integer greater than or equal to 3`; skill-filesystem `skill-filesystem: <field> must be a positive integer` for the three numeric watch fields; skill-office `skill-office: assetRoot must be an absolute directory`; file-reference-local the three messages of `file-reference-local/src/index.ts:124-134`; session-reference the three `SESSION_REFERENCE_INVALID_CONFIG` messages of `session-reference/src/index.ts:110-126`; time-context and tmux-context `<plugin>: refreshIntervalMs must be a non-negative safe integer, got <v>` (`exn:fail:contract`), and time-context `time-context: invalid IANA timeZone <JSON string>` or `time-context: failed to resolve the system time zone`; the pruner the messages of rule 84; workspace-dependencies `workspace dependencies: source and root must be absolute paths`.

Plugin bodies, in order:

- `agent-instructions`: resolve the config (rule 4); register the lifecycle effect `agent-instructions.projectionLifecycle`; listen to `session/event`, `agent/pre-step`, `tools/result` (rules 16 to 19).
- `time-context`: validate; resolve the fallback zone; `projection-register!` of `time-context-projection`; register the prepended `agent/pre-step` listener (rule 22). The body returns after the projection is registered.
- `tmux-context`: validate; register `tmuxContext`; register the prepended listener (rule 26).
- `harness-dev-context`: register `harnessDevLegacyPrompt`; two sections and two contexts (rule 27).
- `file-reference-local`: create and provide the service; rule 30.
- `session-reference`: validate; create and provide the service; register the prepended listener (rule 33).
- `skill`: create and provide the registry.
- `skill-filesystem`: `skills-register-provider!` with `make-filesystem-skill-provider`; an effect `skill-filesystem watcher` whose inverse disposes the provider's watchers and waits; a `fs/observed` listener (rule 52).
- `tool-skill`: validate; register the tool; register the invocation listener, then the catalog listener, in that order (rules 54 and 55).
- `skill-office`: rule 59.
- `tool-workspace-dependencies`: check the two paths; register the tool.
- `compaction-basic`: `ensure-event-type!` for the four `compaction/*` types; `(provide-compaction ctx (make-basic-compaction-engine ctx config))`; when `auto`, the five listeners of rules 67 to 70.
- `compaction-tool-result-pruner`: `ensure-event-type!` for `compaction/prune`; create and provide the service.
- `compaction-image-offload`: `ensure-event-type!` for `image/offload`; register the message projection; the two listeners of rule 87.
- `command-compact`: one effect `command-compact lifecycle` that yields, first, an inverse waiting for every handler task in flight and, second, the command registration, so that on unload the command is removed before the wait (rule 89).
- `agent-preset-registry`: `ensure-event-type!` for `agent-preset/selected`; register `agent-preset-projection` and keep the handle; the settings opt-out `(ctx-inject ctx '(settings) (lambda (child) (ctx-effect child (lambda () (settings-configure! (port-get child 'settings settings-port?) ctx (jobj [auto #f]))))))`; the `session/event` listener that re-emits `agent-preset/selected`; `provide-agent-presets`.
- `agent-preset`: `(agent-presets-register! agent-presets (preset-definition id name description order plugins))`, returned as the body's effect result so the row's fiber owns the definition and stays `'loading` until activation settled. `#:meta` carries `'entry-group #t`, which tells the loader not to evaluate `!!js` values inside this row's `config`.
- `persona`: rule 101.

### What each Web mode needs from this package

The four modes are the preset rows of `packages/bundle/web-app/presets/{standard,ptc,minimal,cordis}.patch.yml`, loaded unchanged (R3 appendix G to J and Algorithms 19). The host plane must hold `@deepseek-ai/dsh-agent-preset-registry` (config `default: standard`), `@deepseek-ai/dsh-skill` and `@deepseek-ai/dsh-compaction-image-offload`. Per preset this package supplies:

| Preset (`id`, order) | Rows from this package | What must hold for the mount to succeed |
|---|---|---|
| Standard (`standard`, 1) and Creator (`cordis`, 4) | `persona` (`prefix` with `{{model}}`), `agent-instructions` (`maxBytes: 65536`), `time-context`, `skill-filesystem` with `customSkillDirs` given by a `!!js` expression, `tool-skill`, group `compaction` (isolate `compaction` and `toolResultPruner`) holding `compaction-basic`, `command-compact`, `tool-result-pruner` (8192, 4096, 1024) | The expression calls `createRequire(baseUrl).resolve('@deepseek-ai/dsh-agent-preset/package.json')`; `npm-package-roots` maps that name to `agent-preset-package-root` so the embedder's `node:module` host object can answer, and the result is `<agent-preset-package-root>/skills`, which holds `dsh-doc`. `compaction` and `toolResultPruner` are provided only inside the isolating group, so the leak audit passes. |
| PTC (`ptc`, 2) | the same rows, `skill-filesystem` without config | as above without the expression |
| Minimal (`minimal`, 3) | `persona` with `complete: true` and `includeRuntimeContext: false`; group `compaction` (isolate `compaction`) holding `compaction-basic` and `command-compact` | no pruner: `compaction-basic` reads `toolResultPruner` optionally and finds none in its realm |

A row of another package that is missing makes the mount fail with its row line (rule 93); that is the loader's resolution error, not this package's.

### `plugin-table`

`dsh-context/plugins` provides `plugin-table`, eighteen rows. `@deepseek-ai/dsh-file-reference` and `@deepseek-ai/dsh-compaction` are libraries and have no row.

```racket
(define plugin-table
  (list
   (cons "@deepseek-ai/dsh-agent-instructions" 'dsh-context/plugin/agent-instructions)
   (cons "@deepseek-ai/dsh-time-context" 'dsh-context/plugin/time-context)
   (cons "@deepseek-ai/dsh-tmux-context" 'dsh-context/plugin/tmux-context)
   (cons "@deepseek-ai/dsh-harness-dev-context" 'dsh-context/plugin/harness-dev-context)
   (cons "@deepseek-ai/dsh-file-reference-local" 'dsh-context/plugin/file-reference-local)
   (cons "@deepseek-ai/dsh-session-reference" 'dsh-context/plugin/session-reference)
   (cons "@deepseek-ai/dsh-skill" 'dsh-context/plugin/skill)
   (cons "@deepseek-ai/dsh-skill-filesystem" 'dsh-context/plugin/skill-filesystem)
   (cons "@deepseek-ai/dsh-tool-skill" 'dsh-context/plugin/tool-skill)
   (cons "@deepseek-ai/dsh-skill-office" 'dsh-context/plugin/skill-office)
   (cons "@deepseek-ai/dsh-tool-workspace-dependencies" 'dsh-context/plugin/tool-workspace-dependencies)
   (cons "@deepseek-ai/dsh-compaction-basic" 'dsh-context/plugin/compaction-basic)
   (cons "@deepseek-ai/dsh-compaction-tool-result-pruner" 'dsh-context/plugin/compaction-tool-result-pruner)
   (cons "@deepseek-ai/dsh-compaction-image-offload" 'dsh-context/plugin/compaction-image-offload)
   (cons "@deepseek-ai/dsh-command-compact" 'dsh-context/plugin/command-compact)
   (cons "@deepseek-ai/dsh-agent-preset-registry" 'dsh-context/plugin/agent-preset-registry)
   (cons "@deepseek-ai/dsh-agent-preset" 'dsh-context/plugin/agent-preset)
   (cons "@deepseek-ai/dsh-persona" 'dsh-context/plugin/persona)))
```

## Behaviour

Numbering is for tests. "Raise" without a type means `exn:fail` with the exact message. Byte counts are UTF-8 (`utf8-length`), "units" are UTF-16 code units (`utf16-length`), "code points" are `code-point-length`. A `pre-step` listener written "after `next`" calls `(next)` first and returns the decision unchanged when it is a `pre-step-reject`; "replace the messages" is `(struct-copy pre-step-enter decision [messages …])`.

**Shared helpers**

1. `(system-reminder-frame body)` is `<system-reminder>\n` + `body` + `\n</system-reminder>`. Each producer states its own escaping of `body`.
2. `(locale-string<? a b)` stands in for `String.prototype.localeCompare` in the three places dsh uses it (skill root entries, preset roster ties, leaked service names). Compare character by character with the key `(class, folded, case)`: class 0 for ASCII punctuation in the order ``_ - , ; : ! ? . ' " ( ) [ ] { } @ * / \ & # % ` ^ + < = > | ~ $``, class 1 for digits, class 2 for letters and everything else; `folded` is the character's `char-foldcase` code point (the index in the list for class 0); `case` puts lower case before upper case and is consulted only when two strings are otherwise equal. A proper prefix sorts first.
3. `(ensure-event-type! ctx type)` does nothing when `(sessions-event-type ctx tag)` already returns a declaration for the tag, and otherwise calls `sessions-register-event-type!`. Several rows of one tree (one per preset) declare the same types; the first to mount owns the registration.

**Agent instructions** (R11 "Agent instructions formats" and "Agent instructions"; `agent-instructions/src`)

4. Config resolution (`config.ts`). Candidate lists drop every entry that is `""`, `.`, `..` or contains `/` or `\`. `dshHome` is `$DSH_HOME` or `~/.dsh`; `agentsHome` is `$DSH_AGENTS_HOME` or `~/.agents`; blank values count as unset (`dsh-util` home paths). A `maxBytes` that is not finite or is `≤ 0` disables the plugin: nothing is ever composed.
5. Display paths. `<dshHome>/AGENTS.md` displays as `~/.dsh/AGENTS.md`, or `$DSH_HOME/AGENTS.md` when the home is not the default; `<agentsHome>/AGENTS.md` as `~/.agents/AGENTS.md` or `$DSH_AGENTS_HOME/AGENTS.md`. A project file displays as its path relative to the project root; when that path's first component is `user-global` or `agents-global` it is prefixed with `./`. The scope directory of a display path is `user-global` or `agents-global` for the two home files and `dirname` of the path otherwise. The scope key is `<directory>\u0000<basename>`. The candidate group of a directory is the directory, with `agents-global` mapped to `user-global`.
6. `(find-project-root cwd markers fs cancel)`: walk up from `cwd`; the first directory that contains any marker entry is the root; none gives `cwd`.
7. Baseline discovery order, broadest first, which is also precedence from weakest to strongest: `<dshHome>/AGENTS.md`, `<agentsHome>/AGENTS.md`, then for each directory from the project root down to `cwd` every `instructionFileCandidates` name in order, then every `localInstructionFileCandidates` name in order. Every existing regular file loads; a final-component symlink is followed.
8. Reading goes through the `fs` port. A file whose stat size or whose streamed byte count exceeds `maxSourceBytes` is ignored; an unreadable file is skipped. Without an `fs` service the plugin composes nothing.
9. Dedup: within one candidate group a later file whose trimmed content has the same SHA-1 as an earlier file of the group is dropped. The change digest is the lower-case hex SHA-1 of the exact text; the dedup digest is the SHA-1 of the trimmed text.
10. Rendering one text (`render.ts:buildInstructionText`). `marker` is `""` when nothing was omitted or truncated, else `Workspace instruction budget <maxBytes> bytes: ` followed by the parts joined with `; `: `omitted <display paths joined with ", ">` and `truncated <path> from <N> to <M> bytes` (several joined with `, `). The body is the non-empty blocks `marker`, intro, sections, joined with a blank line; every literal `</system-reminder>` in the body becomes `<\/system-reminder>`; the text is rule 1's frame. A baseline section is `Instructions from: <displayPath>\n\n<content>`. Intros are the four constants of `render.ts:19-27` (R11 "Intros"), copied verbatim.
11. Budget for one chain (`renderInstructionContext`), with `maxBytes` applying to the complete text including frame, marker and intro: (a) everything fits: render all; (b) else drop files from the front, listing them as omitted, until the rest fits; (c) else keep only the last file, truncated at a UTF-8 character boundary to the largest content that fits (binary search over the byte length), first with the given intro, then with the compact intro; (d) else the escaped marker, a blank line and that file's section with empty content, with no frame and no intro; (e) else the escaped marker alone, cut to `maxBytes` at a character boundary. A file counts as *represented* when its section carries at least one byte of content or the file is empty.
12. Two chains (`renderInstructionChains`). When the single rendering omitted or truncated something and both user-global and project files exist, render each group alone under `maxBytes`, then build one text from the union: omitted, sections and represented in loaded order; truncated records with the chain whose last file comes first in loaded order first; the intro is the given intro when either chain used it, else the first chain intro, else none. If that text exceeds `2 × maxBytes`, use the single rendering.
13. Change sections (`render.ts:changedSectionText`), rendered with rules 10 to 12 and no intro: `set`, `replace` and `remove` have the three texts of R11 "Change batch sections", copied verbatim; applicability is `These user-global instructions apply to all work.` for the two home scopes and ``These instructions apply to work under `<scope dir>`.`` otherwise. Only changes whose file is represented in the rendered text are recorded.
14. The baseline identity is `(jvalue->string (jobj [projectRoot <cwd-relative path of the root>] [projectRootMarkers …] [maxBytes …] [maxSourceBytes …] [instructionFileCandidates …] [localInstructionFileCandidates …]))`. The relative path is computed as Node's `path.relative(cwd, projectRoot)` does (`""` when equal, `..` segments otherwise).
15. Composing the desired message (`index.ts:86-215`), for an agent, the claimed messages, the pending instruction messages of next-step and an optional list of touched paths. Nothing when the budget is disabled or `fs` is absent. Compute `cwd` (working-directory port), the project root and the identity. With no touched path, a pending message and a remembered preparation of the same identity, the result is the first pending message. The *visible baseline* is the latest claimed message, else the latest surface node, whose source is `agent-instructions` with `baseline: true`. It is *kept* when its `baselineIdentity` equals the identity. When there is no visible baseline, or it is not kept, or no preparation of this identity is remembered: load the baseline set (rules 7 to 12) with the replacement intro when a visible baseline exists and is not kept (the empty-replacement intro when no file loads); remember per session the identity and the *excluded scopes* (observed but not included, minus deduplicated files whose digest an included file of the same group carries); and, unless the baseline is kept or the rendered text is empty, start the message with one text block holding that text and with changes: for a replacement, a `remove` for every scope of the old baseline's non-`remove` changes that the new baseline lacks, then one `set` per included file with its digest. Then run reconciliation (rule 18) and append its content block and changes. No content gives nothing. The source is `agent-instructions-source` (Data), with the identity exactly when a baseline text was added.
16. The `agent/pre-step` listener, after `next` (`index.ts:300-320`): wait for queued touch projections of this agent; compose with the payload's `messages` as claimed; check cancellation. If the decision is a reject, or `step` is 1 and the decision has no messages, synchronise the inbox (rule 17) and return the decision. Otherwise remove every pending instruction message from next-step; if nothing is desired or the decision already holds a message with equal content and source, return it; else insert the desired message immediately after the last decision message that is one of the claimed messages (at the front when none is).
17. Inbox synchronisation: with nothing desired, or with the desired payload already among the claimed messages or on the surface, remove all pending instruction messages. Else keep a pending message with equal payload and remove the others. Else replace the first pending message with the desired one (or prepend it to next-step when none is pending) and remove the rest.
18. Reconciliation (`state.ts:251-456`, to be ported function for function; its observable rules): the effective state is the last change per scope over the visible surface messages and then the claimed ones. Scopes checked: the baseline's scopes when the visible baseline is kept (minus the excluded scopes), scopes named by pending messages, every candidate in the directories of already-effective scopes, and every candidate in the directories between `cwd` and each touched file's parent. Per candidate group in candidate order: probe; `unavailable` rolls the whole group back to its last good state; absent gives `remove` when the scope was set; present with unchanged `(path, version)` and previously rendered is kept, or removed when it now duplicates an earlier member of the group; otherwise read, hash and emit `set` (new) or `replace` (changed) unless it duplicates an earlier member. The batch is rendered through rule 13 and only surviving changes update the per-session version cache.
19. File touches: on `tools/result` for a successful result whose execution has an agent and whose cancel event is not ready, when the tool name is `read`, `write` or `edit` and the arguments are an object with a non-blank string `file_path`, record `(agent, trimmed path)`. Touches collected under a nested execution move to its parent's token; a top-level execution projects its touches. A touch during an open step (`turnBoundary` has an open turn and its last step boundary is a `start` after the turn start) waits for that session's `step/end`; otherwise it queues a projection. Projections of one agent run one after another as tasks; each composes with no claimed messages and that one touched path, then synchronises the inbox; a failure is logged at `warning` as `workspace instruction refresh failed: <error>` unless the plugin is unloading.

**Time context** (R11 "Time context text" and "Time context"; `time-context/src`)

20. Projection fold (`index.ts:147-183`): `turn/start` sets `lastTurnInjectionTime` to `null`, `browserTurn` to the turn and `browserTimeZones` to `[]`; `turn/end` clears `lastTurnInjectionTime`; `user/message` sets `lastMessageTime` to the event time, appends the reported zone when `browserTurn` is set and the zone is new, and, when the source kind is `time-context`, sets both injection times to the event time; `assistant/message` and `tool/result` set `lastMessageTime`. A reported zone is the `clientTimeZone` string of a source with kind `user` and a string `rpcId`. An event that changes nothing returns the same state.
21. Text: `Time sampled while preparing turn <T>, step <S>: <timestamp>\n<browser line>\nElapsed since the preceding <baseline>: <elapsed>.` with `<baseline>` `model-visible message` at step 1 and `step context` otherwise, `<elapsed>` `unavailable` or the duration `[<d>d ][<h>h ][<m>m ]<s>s` of the non-negative whole seconds (zero units other than seconds omitted). The browser line is one of the three texts of `request-zone.ts:74-87`; the mixed form prints the sorted zones as a JSON array.
22. The listener is registered with `#:prepend? #t` and acts after `next`. Skip when cancelled. `now` is the wall clock in milliseconds. Skip when `refreshIntervalMs > 0`, a last injection exists and `0 ≤ now − last < refreshIntervalMs`. `previous` is `lastMessageTime` at step 1 and `lastTurnInjectionTime` otherwise. The browser context comes from the decision's messages plus the state's zones when `browserTurn` equals the turn, else from the `user/message` events since that turn's `turn/start` plus the decision's messages: each reported zone must be canonical (rule 23), distinct zones are sorted with `js-string<?`, one gives `resolved`, several `mixed`, none `missing`. The display zone is the resolved browser zone, else the fallback zone. Append `(make-user-message #:content (list (text-block text)) #:source (snapshot-source "time-context" text))` at the end of the decision's messages.
23. `(canonicalize-time-zone value)` returns the canonical name or a rejection symbol: `'blank` for `""`; `'padded` when trimming changes it; `'not-area-location` unless it is `UTC` or matches `^[A-Za-z][A-Za-z0-9_+.-]*(?:/[A-Za-z0-9_+.-]+)+$`; `'unsupported` when rule 24 has no data for it. A browser zone that is not accepted, or whose canonical name differs from the reported text, raises `exn:fail:contract` with the matching message of `request-zone.ts:27-49`, which fails the step.
24. Zone formatting in Racket. Racket itself knows only UTC and the process-local zone, so `private/tzif.rkt` reads the system tz database: the file `<root>/<zone>` under `$TZDIR`, else `/usr/share/zoneinfo`, in TZif format (the 64-bit data block of version 2 and later, and the footer's POSIX TZ rule for instants after the last transition). `(zone-offset-seconds zone epoch-seconds)` returns the UTC offset. `(format-timestamp ms zone)` is `<YYYY>-<MM>-<DD>T<HH>:<mm>:<ss><offset>[<zone>]` from the wall fields at that offset, with `<offset>` `+HH:MM` or `-HH:MM`, a further `:SS` when the offset has seconds, and `+00:00` for zero. Differences from dsh, which formats with ICU through `Intl.DateTimeFormat` (`longOffset`): (a) the offsets come from the operating system's tzdata, so a rule change newer or older than Node's bundled ICU data gives a different offset; (b) canonical names: ICU maps aliases and letter case to its canonical spelling; here a name is canonical when its file exists under exactly that spelling and `tzdata.zi` in the same root, when present, does not list it as a link (`L <target> <link>` lines), and a link's canonical name is its target; (c) the process zone, which dsh reads from ICU, is the first of: `$TZ` (a leading `:` removed) when it names a zone file, the first line of `/etc/timezone`, the target of the `/etc/localtime` symlink relative to the root, `UTC`; the names `Etc/UTC`, `Etc/GMT` and `GMT` become `UTC`, as ECMA-402 requires; (d) on a host without a zoneinfo directory only `UTC` is supported: a configured `timeZone` fails the load, and a reported browser zone fails the step as `unsupported`. `UTC` never needs a file.

**tmux context** (`tmux-context/src/index.ts`)

25. Query: run through `port-shell-run` the six-line script of `index.ts:67-74`, copied verbatim, with the Racket process id from `(getpid)` of `ffi/unsafe` (or the `dsh-util` helper) in place of `process.pid` and the eight format fields joined with the two-character separator backslash, `t`. A failure of the port logs `tmux location query failed: <message>; injecting no location this turn` at `warning`. A non-zero exit, a first output line that does not split into eight fields, or an empty pane id give no location.
26. Listener (prepended, after `next`): only at step 1, not cancelled, with a `shell` service. Skip when `refreshIntervalMs > 0`, a previous state exists and `0 ≤ now − previous.time < refreshIntervalMs`. The state block is `session <name>, window <index> <JSON string of window name>, pane <index> <paneId>\nwindow active=<0|1>, pane active=<0|1>, layout <layout>`. Skip when it equals the previous state. Otherwise put `(make-user-message … #:source (snapshot-source "tmux-context" text))` with text `tmux location (turn <T>):\n<state block>` in front of the decision's messages. The projection fold stores, for each `user/message` with source kind `tmux-context` whose first block is text, everything after the first newline as `state` and the event time as `time`.

**Harness dev context** (`harness-dev-context/src/index.ts`)

27. Register two prompt sections and two contexts, all with `#:interpolate? #f`: section `harness:source` at section order `HARNESS_SOURCE` and section `app:web-surface` at `WEB_SURFACE`, contexts of the same two names at the context orders of the same names. The context texts are `Current DeepSeek Harness implementation checkout: <JSON string of harness-checkout-root>.` and `Current DeepSeek Harness Web GUI URL: <JSON string of (port-web-app-url ctx)>.`, the second resolved at each assembly. The section texts are `HARNESS_SOURCE_PROMPT` and `WEB_SURFACE_PROMPT` (`index.ts:31-48`), copied verbatim, unless the assembling agent's session has admitted a legacy paragraph: the `harnessDevLegacyPrompt` state, folded from every `system/message` whose content is one non-empty text block, holds for each of the two legacy shapes (`LEGACY_SOURCE`, `LEGACY_WEB_SURFACE`: a prefix and a suffix, `index.ts:50-67`) the single-line paragraph from prefix to suffix, or `null`; a non-null value replaces the section text, so a resumed session's system prompt does not change.

**File references** (R11 "File references" and "File reference search")

28. `active-at-token` applies, to the text before the cursor, `(?:^|\s)(@"([^"]*))$` and then `(?:^|\s)(@([^\s]*))$`. `format-file-mention`: a directory path gets a trailing `/`; a path with a control character (U+0000 to U+001F, U+007F to U+009F) or `"` gives `#f`; quoted when `preserve-quote?` or the path has whitespace: `@"<path>"` for a file and `@"<path>` for a directory; otherwise `@<path>`.
29. `file-reference-prompt` is the string of `file-reference/src/index.ts:13` (R11 "File references"), copied verbatim.
30. The local service keeps one search per agent, rebuilt when the agent's working directory changes, invalidated on every `tool/result` session event of that agent's session, disposed on `agent/disposed`. For every live agent and on every `agent/created` it mounts through the agent context a child that injects `systemPrompt` and `tools` and registers the section `context:file-reference` at order `FILE_REFERENCE` whose text is `file-reference-prompt` when `(tools-lookup … "read" agent)` finds a tool and `""` otherwise; the child is disposed on `agent/disposed` (a failure logs `file-reference-local: prompt cleanup failed: <message>`), and all are disposed and awaited on unload.
31. Search (`file-reference-local/src/search.ts`, ported function for function): R11 "File reference search" states the directory-listing rule, the bounded breadth-first index with stale-while-rebuild, hidden-path rules, the score table (1000, 900, 700, 500, `300 + max(0, 100 − gap)`, directories +25, case-insensitive) and the sort (score descending, directories first, shorter path for a non-empty query, then `js-string<?`), cut to `maxResults`. The index scan runs under `blocking` and touches no harness state.

**Session references** (R11 "Session references" and "Session reference"; `session-reference/src`)

32. URI: `dsh-session:` followed by unpadded base64url of the UTF-8 JSON text of the session id. Decoding requires the payload to match `[A-Za-z0-9_-]+`, to parse to a string, and to re-encode to the same URI; otherwise raise code `SESSION_REFERENCE_INVALID_REFERENCE` with `invalid session reference URI <JSON string>`. A mention is `@[<label>](<uri>)` with `\` and `]` in the label preceded by a backslash. `parse-session-references` replaces every match of ``@\[((?:\\.|[^\\\]])*)\]\((dsh-session:[^\s)]*)\)|(dsh-session:[A-Za-z0-9_-]+)`` by `@<label>` (the session id for a bare URI).
33. Listener (prepended, after `next`): for each decision message whose source kind is `user`, parse every text block; when it holds references, replace the message by a copy with the readable text and insert the prepared context message directly after it.
34. `session-reference-prepare`: deduplicate by session id in first-appearance order; a self reference raises `SESSION_REFERENCE_SELF_REFERENCE` `session <JSON id> cannot reference itself`; more than `maxReferences` raises `SESSION_REFERENCE_TOO_MANY` `a message may reference at most <n> sessions`. The byte budget per source is `maxReferenceBytes` when configured, else `max(65536, floor(contextWindow × 4 × referenceContextFraction))`, and `65536` without an `llm` service, on `NO_ADAPTER`, or without capacity metadata. Each source is read with `port-session-query-read-surface`; a failure raises `SESSION_REFERENCE_READ_FAILED` `failed to read referenced session: <message>`.
35. Projection of a source: from its current surface keep `user/message` events whose source kind is `user` or `compact-checkpoint`, and `assistant/message` events; the text is the text blocks joined with `\n`; empty items are dropped.
36. Retention to fit the serialised JSON object in the budget: repeatedly drop the oldest message that is neither a checkpoint nor the newest; then repeatedly shorten the longest remaining text by the overflow, keeping `ceil(n/2)` head bytes and `floor(n/2)` tail bytes around the notice `\n[… omitted <N> UTF-8 bytes …]`; when nothing can shrink raise `SESSION_REFERENCE_BUDGET_EXCEEDED` `referenced session snapshot cannot fit the configured byte budget`. A truncated source is saved in full through `port-spill-save`, under the requesting agent's session id, when a spill store is mounted (suggested name `session-reference-<n>.txt`, source `{kind: "session-reference", sessionId, label}`, body as `spill.ts` writes it).
37. The context message text is the two templates of R11 "Session references" (`## Referenced sessions …` and, when any preview was truncated, `## Reference omissions …`), copied verbatim from `session-reference/src/index.ts`; JSON inside the tags is `jvalue->string` text with every `<` replaced by `<`. Its source is `session-reference-source`.
38. `session-reference-list-candidates`: other sessions from `port-session-query-list`, filtered by case-insensitive substring over id, cwd, label and display title, ranked same-cwd first, then no cwd, then other, stable by listing order, cut to `limit` (default `candidateLimit`; a limit that is not a positive safe integer raises `SESSION_REFERENCE_INVALID_REFERENCE` `candidate limit must be a positive safe integer`).

**Skill registry** (R11 "Skill registry merge"; `skill/src/index.ts`)

39. Storage is `make-scoped-layers` of `dsh-tools/scope`: per layer an insertion-ordered named table of providers `(provider, order)` and a table of runtime skills. `order` is a registry-wide counter taken at registration. Every layer change invalidates (rule 44).
40. Collecting for `(cwd, scope)`: the layers read are the global one and then the scope chain from the farthest ancestor to the exact scope; an entry of a later layer replaces an earlier layer's entry of the same name. Inside one layer the candidates are the runtime skills (sorted by name with `js-string<?`, rank 250, provider order −1, local order by position) and then each provider's candidates in registration order with local order by position; sort by `(rank, provider order, local order)`; the first occurrence of a name wins and each loser logs `skill "<name>" from <source> ignored because a higher-priority skill already exists` at `warning`.
41. Provider output: a list is a complete observation; a `skill-observation` is taken as given; anything else raises `exn:fail:contract` `skill provider "<p>" list() must return an array or { candidates, complete } observation`. A provider whose `skill-provider-list` raises is skipped, logged as `skill provider "<p>" skipped: <message>`, and makes the result non-cacheable, unless the cancel event is ready, in which case the cancel reason is raised. An incomplete observation is also non-cacheable. Each candidate is validated with the messages of `validateCandidate` (`index.ts:677-711`); a runtime skill's and a loaded definition's invocation with those of `validateInvocation`.
42. Cache: key `(jvalue->string (jobj [cwd …] [scopes <ids of the chain>] [revision n]))` with `cwd` omitted when `#f`; scope ids come from a weak `eq?` table on the registry. A cacheable result is stored; the table is FIFO-bounded by `collectCacheMaxEntries`. A collect that finds the revision changed after its providers answered retries once; after the second attempt it returns the result as non-cacheable.
43. `skills-snapshot` returns the summaries sorted by name with `js-string<?` and `complete?` equal to cacheable. `skills-list` is its `skills`.
44. Invalidation increments the revision, clears the cache and dispatches `skills/change`. A provider's `invalidate` does this only while its exact registration is still in its layer.
45. `skills-load`: `#f` for a name that fails `skill-name?`; collect; check cancellation; no entry gives `#f`; call the winning provider's `skill-provider-load`, raced against the cancel event; `#f` passes through; validate the definition; when its name differs from the candidate's, invalidate (if that registration is still live) and return `#f`. There is no body cache. `render-skill-content` and `escape-skill-text` produce the block and the hint lines of R11 "Model-visible skill body" (`index.ts:170-218`), copied verbatim: the name attribute escapes `&`, `"`, `<`; hint text escapes `&`, `<`, `>`; the body is verbatim.

**Filesystem provider** (R11 "Skill formats", "Skill discovery roots", "Filesystem skill watching"; `skill-filesystem/src/index.ts`)

46. Roots for a lookup, in this order, lower rank winning inside the registry layer: when `includeDefaultRoots` and a `cwd` is given, `<projectRoot>/.dsh/skills` (`project-dsh`, 100) and `<projectRoot>/.agents/skills` (`project-agents`, 200), where the project root is the nearest ancestor of `cwd` that contains `.git`, else `cwd`; each `customSkillDirs` entry made absolute (`custom`, 300); when `includeDefaultRoots`, `<dshHome>/skills` (`user-dsh`, 400, its `.system` child skipped) and `<agentsHome>/skills` (`user-agents`, 500); the bundled root (`bundled`, 600, read from the host filesystem even when an `fs` service is mounted), which is `bundledSkillDir`, else `$DSH_BUNDLED_SKILL_DIR` only when `includeDefaultRoots`.
47. Discovery of one root: list its entries (through the `fs` port except for the bundled root; an absent root is empty), visit them in `locale-string<?` name order; a directory gives `<dir>/SKILL.md` with the directory as resource base; a file whose name ends in `.md` gives itself with the root as resource base; symlinked entries are followed (a failure logs `skill entry <path> ignored: failed to follow symbolic link: <message>`); nothing deeper is read. A root that fails to list makes the observation incomplete and logs the warning of `index.ts:204`.
48. `(parse-skill-frontmatter text)`: the first line must be exactly `---` (a trailing `\r` tolerated); the YAML runs to the next line that is exactly `---`; it is read with `(yaml-read yaml #:schema 'core)` (Open question 3) and must be a mapping; the body is the rest. A file without frontmatter logs `skill file <path> ignored: missing YAML frontmatter`; a YAML failure logs `… ignored: invalid YAML frontmatter: <message>`.
49. Fields: `name` and `description` must be non-empty strings (`… ignored: frontmatter requires name and description`); `name` must satisfy `skill-name?` (`… ignored: invalid skill name "<name>"`); `whenToUse` is kept when a non-empty string; `metadata` when a mapping. The body is trimmed. The skill's identity is the `name` field, never the file or directory name.
50. Invocation: the legacy keys `disableModelInvocation`, `modelInvocable`, `userInvocable` reject the file with a message naming the canonical key; `disable-model-invocation` and `user-invocable` accept `#t`, `#f`, `1`, `0`, `"1"`, `"0"` and, case-insensitively, `true yes on false no off`; anything else rejects the file (`… ignored: invalid invocation frontmatter: <message>`, messages from `index.ts:960-1010`). The policy is `model-invocable?` unless disabled is true and `user-invocable?` unless it is false.
51. `skill-provider-load` parses the locator's file again and returns the definition with source from the candidate, the provider name, the directory resource base and the processed path. A candidate carries the same fields plus rank and locator `{path, directory}`.
52. Watching (adapted): for every root of a lookup the provider keeps one watch while `watch` is true. An existing root is watched at depth 1; a missing root is watched at the first missing path segment under the nearest existing ancestor and re-resolved when that changes. A relevant change (the root appearing or disappearing, a direct child directory added or removed, a direct `*.md` file changed, a `<child>/SKILL.md` added, changed or removed; nothing under `.system` of the user root) schedules one coalesced `invalidate` after the path was stable for `watchStabilityThresholdMs`. Project roots are grouped by project and evicted least recently observed beyond `watchMaxProjects`. A watch that cannot be opened marks the observation incomplete; candidates still load. A `fs/observed` event whose actor name is `write` or `edit` on a path that could be a skill file of a current root invalidates at once. Disposal closes every watch and waits.

**`tool-skill`** (R11 "Skill catalog publication"; `tool-skill/src/index.ts`)

53. Tool body: reject a name that fails `skill-name?`; `cwd` is the working directory of the calling agent (none without an agent); look the name up in `(skills-list … #:cwd cwd #:cancel cancel #:scope agent)`; unknown and not model-invocable are the two errors; `skills-load`; check both conditions again on the definition; return the value.
54. Invocation listener (registered first, after `next`): scan only payload messages whose source kind is `user`; over each text block match `(^|\s)/([a-z0-9]+(?:-[a-z0-9]+)*)(?=\s|$)`; names in first-seen order without repeats; for each, `skills-load` and check cancellation; skip unknown or not user-invocable skills; append one message per skill, `(make-user-message #:content (list (text-block (render-skill-content skill))) #:source (skill-invocation-source name))`, after everything else in the decision.
55. Catalog listener (registered second, after `next`): (1) the tool is visible when `(tools-lookup tools "skill" agent)` is `eq?` to this plugin's definition; otherwise the snapshot is empty and complete; (2) entries are the model-invocable skills as `{name, description}` with the description normalised (rule 56); (3) the digest is the SHA-256 hex of `incomplete\n` (only when incomplete) followed by the entries as `(jvalue->string (list name description))` joined with `\n`; (4) history: scan the log backward for `user/message` events with source kind `skill-catalog` and readable entries; `published?` is whether one exists; the visible digest is that of the newest one whose seq is a surface node; (5) a visible digest equal to the digest: publish nothing and remove a catalog message already in the decision; (6) a catalog in the decision with the same digest stays; (7) never published, no skills and complete: publish nothing and remove a proposed catalog; (8) otherwise build the initial form (never published) or the replacement form (published before) and append it, or put it in place of the proposed one.
56. Description normalisation: collapse runs of whitespace to one space, trim, and when longer than `catalogDescriptionMaxLength` units keep the first `max − 3` units followed by `...`. Rendered lines are ``- `<name>`: <description with &, <, > escaped>``; the stored entries are not escaped.
57. The initial and replacement catalog texts, including the empty and incomplete variants and the incomplete notice, are those of `index.ts:258-335` (R11 "Initial catalog message", "Variants", "Replacement catalog"), copied verbatim. The initial source is `(skill-catalog-source entries #:incomplete? i)`; the replacement adds `#:update? #t`.
58. Consequence to test: after a compaction shadows the catalog message, the next step republishes the current catalog in replacement form.

**`skill-office` and workspace dependencies**

59. Provider `dsh-office`: for each of `office`, `office-docx`, `office-pptx`, `office-xlsx` read `<assetRoot>/<name>/SKILL.md` from the host filesystem; the frontmatter is the text matched by `^---\r?\n([\s\S]*?)\r?\n---(?:\r?\n|$)` and must hold a non-empty string `description` (`skill-office: <path> has no YAML frontmatter`, `skill-office: <path> has no description`). A candidate has both invocation flags true, source `bundled`, rank 600, resource base the directory with `/` separators, locator the file path. The observation is complete when every read loaded or failed persistently (the file or a parent is missing, or the parse failed); other read failures make it incomplete. Each distinct failure text is logged once per skill as `skill-office: skill "<name>" is unavailable: <failure>`.
60. Loading: a persistent failure invalidates and returns `#f`; a transient one raises. The three format skills get `\n\n## Python environment\n\n` and the paragraph of `PYTHON_ENVIRONMENT_SECTIONS` for the configured `pythonEnvironment` (`index.ts:16-19`), copied verbatim, appended to the trimmed body.
61. `load_workspace_dependencies` (`tool-workspace-dependencies/src/index.ts`, ported function for function): validate `runtime.json` and `dependencies/{python,node,pnpm}` under `source` (R11 "Workspace dependency payload"); use them in place, or with `root` install by copying into a staging directory beside `root`, keeping the old tree as `.previous` until the new one validates, and rolling back on failure. File work runs under `blocking`.

**Compaction seam** (`compaction/src`)

62. `tool-pairing-balanced-before?` and `-after?` fold the session's surface events in order with a counter: an `assistant/message` adds its number of `tool-call` blocks, a `tool/result` subtracts one; the cut before node `i` is balanced when the counter after node `i − 1` is 0 (the cut before node 0 is balanced). A missing event raises `tool-pairing balance: surface seq <n> has no matching session event (corrupt surface)`; a negative counter raises `tool-pairing balance: tool/result at surface seq <n> has no matching tool-call (corrupt surface)`; a seq that is not a current node raises `tool-pairing balance: surface seq <n> not found`. The fold is cached per session in a weak table of the module's own cache value and rebuilt when `surface-state-replace-generation` changes.
63. `compact-checkpoint-source?` holds for a source whose kind is `compact-checkpoint`.
64. A checkpoint message is `(make-user-message #:content (frame-summary summary) #:source (compact-checkpoint-source id command-id))`. `frame-summary` returns one text block holding `CHECKPOINT_PREAMBLE`, a blank line and `<compacted-summary>`, then the summary blocks, then one text block `</compacted-summary>` (`summarizer.ts:61-62`, `188-194`; preamble copied verbatim).

**`compaction-basic`** (R11 "Compaction triggers and thresholds", "Range selection", "Compaction transaction"; `compaction-basic/src`)

65. Config (`config.ts`, every message copied verbatim; violations raise `exn:fail` at load). Top-level keys and each `modelPolicies[]` entry (which also requires non-empty `provider` and `model`): `thresholdRatio` (number in (0, 1], default `0.8`), `headroomTokens` (integer ≥ 0, default `65536`), `retainRatio` (number in (0, 1], default `0.16`), `retainTokens` (integer ≥ 0, no default; exclusive with `retainRatio` in one scope), `summarizationProvider` and `summarizationModel` (strings, default `""`, set together as an empty or non-empty pair), `maxTokens` (integer ≥ 1, default the resolved `headroomTokens`), `compactionRetries` (integer ≥ 0, default `1`), `maxOverflowRetries` (integer ≥ 0, default `1`); top level only: `modelPolicies` (array, default `[]`, duplicate targets fail) and `auto` (boolean, default `true`). Unknown keys fail with `<name>: unknown key "<key>"`. The schema itself declares no defaults, so a written-back config keeps only the user's keys; `resolve-compaction-config` applies them. A model policy that sets `headroomTokens` without `maxTokens` takes its own headroom as `maxTokens` when the top level set no `maxTokens`. The resolved `retainRatio` must be less than the resolved `thresholdRatio` in every scope.
66. `(resolve-compact-spec policy context-window reserved)` (`config.ts:153-211`): `messageBudget = W − R` and `pressureBudget = messageBudget − headroomTokens` must both be positive; `thresholdTokens = floor(min(W × thresholdRatio, pressureBudget))`; `retainTokens` is the policy's, else `floor(messageBudget × retainRatio)`, and must be less than `thresholdTokens`. Each violation raises `exn:fail:compaction:target-config` with target key `<provider>/<model>` and the message of the source. `R` is the request header's `config.maxTokens`, else the model info's `defaultMaxTokens`, else 0.
67. Pre-step trigger (ordinary listener, acts before `next`): unless cancelled, call the pressure path (rule 71) with the session's request header; log a result at `info` as `compaction (step pressure): shadowed <n> surface nodes (seqs <start>-<end>, ~<tokens> tokens)`. Any raise is logged at `warning` as `step compaction failed: <message>; continuing the turn`, except that a target-config error is logged only once per target key for the life of the engine. Then return `(next)` in every case.
68. Request trigger (registered with `#:prepend? #t`): take `config` from `(next)`; when not cancelled, a previous request header exists, `config` has non-empty provider and model, and they differ from the previous header's: run the pressure path against `(jset previous 'config config)` with `require-below-threshold?` true (log trigger `model switch`). A raise, unless the turn is cancelled (then the cancel reason is raised), becomes `(make-llm-error 'MODEL_SWITCH_COMPACTION_FAILED "Cannot switch to <p>/<m>: context compaction failed: <message>. The previous request model is preserved; retry or select a model with a larger context window." #:cause e)`. Return `config`.
69. Overflow trigger (`agent/request-error`): pass on with `(next)` unless the failure code is `CONTEXT_WINDOW_EXCEEDED` and the turn is not cancelled. Remember the agent for its session. With a routed target and a retry count below the policy's `maxOverflowRetries`: note the replace generation, run `(compaction-compact-if-needed … 'context-overflow cancel)`; if it raised and the generation advanced and the turn is not cancelled, log `context-overflow compaction failed after durable surface progress: <message>; retrying from the replacement surface`, count the retry and return `request-error-retry`; if it raised otherwise, log `context-overflow compaction failed: <message>; cancellation prevents retry` or `…; preserving the original request error` and return `(next)`; if it returned and the generation advanced and the turn is not cancelled, count the retry and return `request-error-retry`; otherwise `(next)`.
70. The retry count is per agent, in a weak table of the engine. It is reset on `agent/status` with status `'idle` and on every `assistant/message` session event of a session whose agent was remembered by rule 69.
71. Pressure path `(compact-pressure agent header cancel require-below-threshold?)`: resolve the target policy for `header.config`; measure with `(token-meter-measure token-meter session header)`; `(llm-resolve-model-info llm provider model #:cancel cancel)`; raise the `busy` manual error when a compaction is active (rule 73, stage `automatic pressure compaction`); no context capacity raises the target-config error `compaction-basic: no context capacity for <p>/<m>; configure contextWindow on that adapter model`; compute the spec; below threshold gives `#f`. With a pruner in the engine's realm, `pruner-prune-session!` and measure again; below threshold gives `#f`. Then for `attempt` from 0 through `compactionRetries`: select a range with the spec's `retainTokens` (rule 72); none gives `#f` when nothing was compacted and `require-below-threshold?` is false, else raises `no safe compaction range can reduce context below threshold (<total> estimated tokens >= threshold <t>)`; compact it (rule 73, owner current turn, whole-surface stability); measure; below threshold returns the result. Afterwards raise `compaction still above threshold after <retries + 1> compaction attempts (<total> estimated tokens >= threshold <t>)`.
72. `(select-compactable-range session measurement retain-tokens)`: the measurement's nodes must match the surface nodes one for one, else raise `compaction: token-meter surface does not match the current session surface`; no nodes gives `#f`. `first` is 1 when node 0 is a `system/message`, else 0. Walk from the tail adding each node's `tokens` until the sum is at least `retain-tokens`; that index is `keep-from` (with 0 the last node alone is retained). `keep-from ≤ first` gives `#f`. Move `keep-from` toward the head until the cut before it is balanced (rule 62); `keep-from ≤ first` gives `#f`. The range is `(nodes[first], nodes[keep-from − 1])`.
73. Transaction `(compact-surface-region session start end agent owner stability …)` (`region.ts:173-276`). (1) Manual only: check cancellation. (2) Validate the span: both seqs on the surface (`compactRegion: start seq <n> not found in surface`, `… end seq …`), start position not after end position, balanced before start and after end (messages of `region.ts:333-341`). (3) Entry state, one backward scan of the log: the latest of `compaction/start` and `compaction/end`, the latest of `turn/start` and `turn/end`, the latest `session/end-seed`. An unmatched `compaction/start` with no later `session/end-seed` raises the manual error `busy` `<stage>: compaction already in progress; the session compaction lock is already active`. (4) Owner: automatic needs an open turn (`compactRegion: no open turn — automatic compaction events must be enclosed in a turn`) and records its number; manual needs none (`busy`, `manual compaction: the session already has an open turn`) and records `null`. (5) Append `compaction/start {compactionId: <fresh UUID>, sourceCommandId?, turn}`. Steps 2 to 5 contain no `await`, so the append is the lock. (6) Prepare: measure; the measured nodes of the span must be the selected seqs; `shadowedTokenCount` is the sum of their `heuristicTokens` and the route total the sum of their `tokens`; the input is `(summarization-input <tools of the last request header, or #f> <the derived system head message when node 0 is a system message, then each shadowed node's derived message>)`. (7) Summarise (rule 74), then build the checkpoint and require `(token-meter-estimate-message token-meter checkpoint)` to be less than the route total, else raise `summary is not smaller than the shadowed content (<a> estimated framed tokens >= <b>)`. (8) Manual only: check cancellation. (9) Stability: whole-surface requires the measured nodes of the whole surface to equal the prepared snapshot; selected-span requires the span to validate again, to hold the same seqs and to price identically; a difference is a *surface changed* failure with the messages of `region.ts:407-436`. (10) Commit without waiting: `compaction/summary` (Data), then `(user/message checkpoint #:surface-op (surface-replace start end) #:sources (list* start-event-seq summary-event-seq shadowed-seqs))`, then `compaction/end {compactionId, sourceCommandId?, turn}`. (11) Any failure after step 5 appends `compaction/end` with `error: (error-chain e)` exactly once, unless the failure happened while appending the closing event; if that closing append fails the start stays unmatched on purpose and the failure is recorded as a commit failure. (12) With a `flush` procedure and a closed bracket, call it and remember a failure. (13) Manual only: check cancellation again. A recorded failure is raised: automatic as itself; manual as `commit` (`manual compaction did not commit cleanly`) when it happened at or after step 10, `changed` (`the compacted history changed during manual compaction`) for a surface-changed failure, `summary` (`manual compaction could not produce a smaller summary`) otherwise, each with the original as `cause`. A flush failure raises `persistence` (`manual compaction durability checkpoint failed`).
74. Summarise loop: check cancellation; call the summariser; on a raise, re-raise when the cancel event is ready; else apply the stability check, dispatch `compaction/summary-error` with `{session, sourceEventSeqs: <shadowed seqs>, error, cancel?}`; a false result re-raises; a true result validates and prepares the same span again and repeats.
75. Default summariser (`summarizer.ts:95-160`). Target: the configured pair when `summarizationProvider` is not empty, else the last request header's `{provider, model}`, else the agent options' pair, else raise `no provider/model available for summarization: set both BasicCompactionConfig summarization fields, route one request, or set both AgentOptions fields`. The policy used is that of the conversation target (request header route, else agent options). Request: `(make-llm-request #:provider p #:model m #:messages (append <input messages> (list (make-request-user-input (list (text-block compaction-instruction))))) #:tool-history (session-tool-history session) #:tools <input tools, or #f> #:max-tokens <policy maxTokens> #:session-id <id> #:purpose "compaction" #:cancel cancel)`, sent with `(llm-stream llm request)` and folded with `assembly-push` inside `call-with-chunk-stream`. `compaction-instruction` is `COMPACTION_INSTRUCTION` (`summarizer.ts:22-55`; R11 "Compaction formats"), copied verbatim, lines joined with `\n`. Finish kind `error` or `aborted` raises `(llm-failure->exn failure)`; `max-tokens` raises an `exn:fail:harness` with code `MAX_TOKENS` and message `summarization truncated at the token cap (incomplete checkpoint)`; an image block in the output raises `(make-llm-error 'UNSUPPORTED_CONTENT "compaction summary cannot contain image output")`; the summary is the text blocks of the output and must hold some non-blank text, else raise `summarization produced no text summary content`. The result records `rawOutput` (all blocks), `llmStreamCall` true, provider, model, `maxTokens` and the usage when one arrived.
76. `engine-compact-if-needed`: `#f` without a request header whose config has non-empty provider and model. `'pressure` is rule 71 with `require-below-threshold?` false. `'context-overflow`: prune when a pruner is mounted, measure, select with `retain-tokens` 0, `#f` without a range, else `engine-compact-region`.
77. `engine-compact-region` is rule 73 with owner current turn and whole-surface stability.
78. `engine-compact-now` (`index.ts:407-449`): raise the caller's cancel reason when already cancelled. Call `(agent-run-maintenance agent job)`; when it raises before `job` started, raise the manual error `busy` `manual compaction requires an idle agent with no waking queued work` with that failure as cause.
79. The job, given the maintenance cancel event `m`: `c` is `(cancel-evt-any m cancel)`; check `c`; select with the plain measurement and `retain-tokens` 0; no range returns `#f` and writes nothing; otherwise rule 73 with owner `null`, selected-span stability, the source command id, cancel event `c`, and a flush that calls `(sessions-flush sessions session)`. On a raise: when `m` is ready and the reason of `c` is `m`'s reason, raise the manual error `cancelled` `manual compaction was cancelled`; else when `c` is ready raise its reason; else re-raise.
80. Order to pin: `compaction/start`, then possibly `image/offload` events during recovery, then `compaction/summary`, the replacement `user/message` directly after it, then `compaction/end`. After a compaction the derived history is the system head, the checkpoint message, then the retained tail; a later compaction may shadow an earlier checkpoint.

**Tool-result pruner** (`compaction-tool-result-pruner/src`)

81. `prune-marker` is `"\n\n[... tool result middle pruned ...]\n\n"` (39 code points).
82. `pruner-prune-content`: `total` is the code points over the text blocks; at most `thresholdChars` gives `#f`. The removed span is the code-point range `[headChars, total − tailChars)` over the concatenated text. Each text block keeps its part before the span and its part after it; the marker is inserted once, in the first block that intersects the span; a text block that becomes empty is dropped; other blocks keep their position.
83. `pruner-prune-session!`: take the current surface nodes; for each `tool/result` node whose derived message is over the threshold append `compaction/prune {shadowedRange: {start: seq, end: seq}, shadowedSeqs: [seq], shadowedTokenCount: (token-meter-estimate-message … original)}` and then the replacement `tool/result` whose data is the original data with only `message.content` changed, surface op `(surface-replace seq seq)` and sources `(list seq)`. The two appends are adjacent. One pass converges.
84. Config errors (`config.ts`): `ToolResultPruneConfig: unknown key "<key>" (allowed: thresholdChars, headChars, tailChars)`; `ToolResultPruneConfig: <name> (<v>) must be a positive integer` and `… a non-negative integer`; `ToolResultPruneConfig: headChars + marker + tailChars (<n>) must be at most thresholdChars (<t>)`.

**Image offload** (`compaction-image-offload/src`)

85. `(offload-oldest-images! session seqs count)`: for each seq in order whose event is a `user/message` or `tool/result`, walk the image blocks of its derived message, numbering every image block from 0 (offloaded ones included) and selecting those not yet offloaded until `count` are chosen; append one `image/offload {targets}` with the non-empty selections and return `#t`; nothing selected returns `#f` and appends nothing.
86. The projection validates and applies (`projection.ts`, messages copied verbatim): data with exactly a non-empty `targets`; each target exactly `{seq, imageIndexes}` with a non-empty list; unique seqs that are current surface nodes of type `user/message` or `tool/result`; indexes strictly increasing non-negative safe integers; each index exists and is not already offloaded. It returns, per target seq, the current message with the chosen image blocks given `offloaded: true` appended as their last key.
87. Listeners: on `agent/request-error` with code `IMAGE_OFFLOAD_REQUIRED`, a numeric `offloadImages` and a turn that is not cancelled, offload over the surface nodes and return `request-error-retry`, or `(next)` when nothing was selected. On `compaction/summary-error` whose error is an `exn:fail:llm` with that code and count, check cancellation, offload over the payload's seqs and return `#t`, or `(next)`.

**`/compact`**

88. Handler tasks in flight are tracked; unload waits for them after the command is unregistered.
89. Handler (`command-compact/src/index.ts`): non-blank raw input returns `{kind: "error", text: "Usage: /compact (no arguments)"}`. Otherwise call `(compaction-compact-now compaction agent cancel command-id)`: `#f` gives `{kind: "success", text: "No compactable history yet."}`; a result gives `{kind: "success", text: "Compacted <n> history items (~<tokens> tokens).", sourceEventSeq: <summary seq>}` with `n` the number of shadowed seqs; a raise with the invocation's cancel event ready gives `{kind: "error", text: "Compaction cancelled."}`; a manual error gives the error text of its code from the table in R11 "Human command `/compact`" (six texts, copied verbatim from `index.ts:29-58`); anything else propagates.

**Presets** (R3 Algorithms 18; `agent-preset-registry/src`)

90. `(entry-list-problem rows)` returns `#f` or the first of: `the composition must be a top-level list of plugin rows`; `row <n> is not a plugin row (expected a map with a "name")`; `row <n> names no plugin (a "name" string is required)`; for a row with `group: true`, the same checks over its `config` with labels `<label> row <n>` and `group <label> must hold a list of plugin rows`. Rows count from 1.
91. `agent-presets-default-id` is the current value of the volatile `selectedDefault`, else `default`.
92. Activation of a definition (`index.ts:113-138`): make a fresh `preset-scope-key`; `(create-scope registry-ctx key)`; check rule 90; extend the scope context with `'baseUrl` set to the declaring row context's `(context-meta row-ctx 'baseUrl)`; mount (rule 93); on success record the generation `{scope, key, mount, users: 0, retired?: #f}` in the registry's generation table through an effect `agent-preset.mount` on the extended context. On any failure set the definition's `broken` to the message, log `agent preset <id>: <message>` at `warning` and dispose the scope. The definition stays in the roster either way. Mounting is eager and happens once per definition: every agent that selects the preset shares that one revision.
93. Mounting (`mount.ts:204-216`): wait for the scope fiber; create an in-memory entry tree under the extended context whose `commit` does nothing, so nothing is written back to any file; register an effect `agent-preset.tree` whose inverse stops the tree's root; update the root group with `(port-profile-preflight ctx plugins base-url)`; audit (rule 94); compute the leaked services. Failed rows raise the audit lines joined with `\n`; otherwise leaked services raise `Preset services require isolate realms: <names joined with ", ">`. Rows nest: a `cordis:group` row with `isolate: {<service>: true}` gives its subtree a private realm for that key, which is the loader's own isolate rule; this package adds nothing to it.
94. Audit: wait for the tree; for each enabled entry, in tree order: no fiber gives `<id> (<name>): never started`; a fiber whose `fiber-await` raises gives `<id> (<name>): <detail>`, where the detail is the message, followed for an aggregate failure by one line `- <detail of the member>` per member with inner newlines indented by two spaces; a fiber with injected keys that `ctx-get` cannot read gives the pending line `<id> (<name>): waiting for <keys joined with ", ">`. A *leaked service* is a key provided by a fiber inside the mount's subtree (walk `fiber-parent` up to the mount fiber) whose realm in that fiber's context is the root realm of the key (`(eq? (context-realm (fiber-context f) key) (context-realm (context-root ctx) key))`); the names are sorted with `locale-string<?`.
95. Diagnostic on read (`index.ts:151-162`), used by `list`, `resolve`, the retain of rule 96 and the inventory: wait for the definition's activation; a failed mount returns its `broken` text for good; a mounted tree is audited again, and when rows are pending, once more after `loader` quiescence; any failed or pending line makes the result those lines joined with `\n`. Unregistering a definition deletes it and marks its generation retired; a retired generation with no users is removed from the table and its scope is disposed. Agents keep the revision they joined; new agents get the new one.
96. Retain and bind (`index.ts:248-306`). Retain: resolve the id or the default; unknown raises `agent-preset/not-found` with `available` the definition ids in registration order; a diagnostic raises `agent-preset/invalid` with it as reason; otherwise count one user. `agent-presets-mount!` retains, binds and releases the retain in every case. Bind: the agent context must carry a scope key. No binding yet: `(bind-scope-parent! agent-key generation-key)`, count a user, remember the binding in a weak table and register the effect. A binding to another generation: `scope-parent-binding-rebind!` to the new key, count a user there, drop one on the old generation and collect it. A binding to the same generation does nothing. What the link does is the scope rule of `dsh-tools/scope`: scope-layered registries (tools, prompt sections, skills, commands) resolve along the chain agent key, generation key, global; scoped dispatch admits listeners tagged with the agent key or the generation key; so an agent sees its preset's registrations and the host's and not another preset's.
97. `agent-presets-compose-from!`: the parent's generation is the one whose key is `(scope-parent-of (scope-of parent-ctx))`. None: raise `Parent preset revision is unavailable` when the parent context reads an `agentPresets` service that reports a composed preset for it, else return `#f`. Otherwise join the child (first-binding path of rule 96) and return the preset id. `agent-presets-composed-preset` is the preset id of that generation or `#f`. `agent-presets-service-for` returns the value of the first provision named `key` made by a fiber inside the agent's generation subtree, in any realm, or `#f`; this is how a caller outside an isolating group reaches a preset-private service.
98. `agent-presets-select!` (`index.ts:365-383`): calls for one agent id run one after another. Read `(agents-turn-boundary-of agents session)`; an open turn or `lastTurn > 0` raises `agent-preset/locked`. When the agent is already bound to the definition's current generation and the projection already reads that id, return the id without logging. Otherwise recompose (mount, then `dispatch-tools/change`, whose listener failure is logged as `Preset tools observer: <error>` and not raised), append `(agent-preset/selected #:agent-preset id)` and return the id.
99. How a session selects a preset. At creation the caller (the session controller of `dsh-web`, the SDK server) resolves the requested id or the default, passes `#:meta` with `agentPreset: <id>` to `agents-create`, and a `#:setup` that calls `(agent-presets-mount! agent-presets agent-ctx id)`. A blank session changes preset with `agent-presets-select!`. On resume the caller reads `agent-presets-preset-for-session` (the header value advanced by selection events) and mounts the current definition of that id; a missing definition raises `agent-preset/not-found`. A child agent joins its parent's generation with `agent-presets-compose-from!` or mounts a named preset. Without the registry no preset is recorded and agents use the host-plane rows.
100. `agent-presets-list`: one row per definition with its diagnostic as `broken`, sorted by `order` ascending (a missing order last) and then by `id` with `locale-string<?`. `agent-presets-read-document`: `content` is `(yaml->string plugins #:line-width #f)` (Open question 6) with `js-expr` values written back as `!!js`. `agent-presets-acquire-scope` retains and returns the generation key with a single-shot release. The inspection and inventory procedures follow `composition-inventory.ts`, ported function for function.

**Persona** (R3 Algorithms 18.6; `persona/src/index.ts`)

101. Two effects on the plugin's context: `persona.section()` registers the section `persona-prefix-section` at order `DEPLOYMENT_PERSONA_PREFIX` with text `prefix` and `#:complete? #t` when `complete`; `persona.suffix()` registers `persona-suffix-section` at `DEPLOYMENT_PERSONA_SUFFIX` with text `suffix`. When `includeRuntimeContext` is false, call `system-prompt-suppress-runtime-context!`. Mounted in a preset the registrations are scoped and shadow the deployment sections of the same names for agents bound to that preset; mounted in an unscoped context they collide with the `systemPrompt` plugin's own sections and the load fails with its duplicate error. Both texts are interpolated against prompt variables at render time; an empty text still shadows.

## Racket design notes

- **Ports with late-bound defaults.** Sibling wave 4 packages are built at the same time as this one. `dsh-context/ports` gives every sibling operation one procedure with a signature fixed here; test doubles implement its generic interface, and the real provider is reached by name at first use. The package therefore compiles and passes its tests alone, and a sibling contract that settles on a different name changes one line of one module.
- **Generics for the three provider seams.** `gen:skill-provider`, `gen:compaction-engine` and `gen:file-reference-provider` replace an object interface, an abstract class with one subclass hook, and an abstract service. The compaction hook dsh exposes as a protected method is the `#:summarize` argument of the engine constructor.
- **Structs for skills, jobjects for what is logged.** Skill records never leave the process, so they are structs with inheritance (`skill-candidate` and `skill-definition` extend `skill-summary`). Message sources, catalog entries, tool values and projection states are jobjects built in the dsh key order by the constructors of `dsh-context/sources`.
- **Listeners are plain procedures over `struct-copy`.** A `pre-step` decision is an immutable struct; every listener here is "call `next`, return a copy with other messages".
- **No locks.** The compaction transaction, the prune pair and the catalog history scan rely on dsh's run-to-completion between awaits. Tasks give the same guarantee (ADR 0002), so "no `await` between the lock check and the `compaction/start` append" is a property of straight-line code and needs no mutex.
- **Weak tables on service values** replace the module-level `WeakMap`s (tool-pairing cache, overflow retry counts, instruction version cache, per-session preparation).
- **Preset generations own a scope, not a context copy.** The mounted subtree is ordinary loader entries under a scope created with `create-scope`; binding an agent is one parent link. The isolate realms come from the loader. Nothing in this package copies registrations.
- **No new macro.** The package uses `define-tool`, `define-session-event`, `define-service` and `define-event` of the lower packages. A local form for "prepended pre-step listener that acts after `next`" was considered and rejected: it would hide four lines and save no class of error.
- **Racket-only additions**, for the coordinator's ADR list: the ports module and its generic interfaces; `ensure-event-type!`; `locale-string<?`; the TZif reader and the process-zone lookup of rule 24; `npm-package-roots`; the `'entry-group` plugin meta key; `sessions` in the pruner's inject list. No `x-racket` config key is added.

## Work units

Three units. The interface between them is the set of public module exports listed under Modules.

| Unit | Modules | Depends on |
|---|---|---|
| A: context and references | `ports`, `data`, `sources`, `agent-instructions`, `time-context`, `file-reference`, `file-search`, `session-reference`, the plugins `agent-instructions`, `time-context`, `tmux-context`, `harness-dev-context`, `file-reference-local`, `session-reference`, and their tests | wave 3 |
| B: skills and compaction | `skills`, `skill-filesystem`, `compaction`, `compaction-basic`, `tool-result-pruner`, `image-offload`, the plugins `skill`, `skill-filesystem`, `tool-skill`, `skill-office`, `tool-workspace-dependencies`, the four compaction plugins and `command-compact`, and their tests | wave 3; from unit A only `ports`, `data`, `sources` |
| C: presets | `preset`, the plugins `agent-preset-registry`, `agent-preset`, `persona`, `plugins`, `main`, and their tests | wave 3, `cordis-loader`; from unit A only `ports`, `data` |

Unit A delivers `ports`, `data` and `sources` first; B and C are written against this document meanwhile. `private/collate.rkt` belongs to unit B and is required by unit C.

## Tests

Tests live in `racket/dsh-context/tests/`. Rows name the TypeScript suite to mirror and what it pins. All run through `call-with-loop-harness` of `dsh-test-support` with a scripted model unless they test a pure function.

| Racket test file | Mirrors | Pins |
|---|---|---|
| `instructions-render-test.rkt` | `agent-instructions/tests/agent-instructions.spec.ts` (render cases) | rules 10 to 14: every budget fallback at tiny and exact limits, multibyte truncation, the two-chain merge and the `2 × maxBytes` fallback |
| `instructions-test.rkt` | the same suite (discovery, dedup, nested and changed files, replacement baseline) | rules 4 to 9, 15 to 19, with an in-memory `fs` port double |
| `time-context-test.rkt` | `time-context/tests/{time-context,request-zone,initialization}.spec.ts` | rules 20 to 24, with fixed clock and `TZDIR` pointing at fixture TZif files (`UTC`, `Asia/Shanghai`, `America/New_York` across a DST change) |
| `tmux-context-test.rkt` | `tmux-context/tests/tmux-context.spec.ts` | rules 25 and 26 with a scripted shell port |
| `harness-dev-context-test.rkt` | `harness-dev-context/tests/harness-dev-context.spec.ts` | rule 27, legacy paragraph retention |
| `file-reference-test.rkt` | `file-reference/tests/service.spec.ts`, `file-reference-local/tests/{search,service}.spec.ts` | rules 28 to 31 |
| `session-reference-test.rkt` | `session-reference/tests/session-reference.spec.ts` | rules 32 to 38 |
| `skill-test.rkt` | `skill/tests/skill.spec.ts` | rules 39 to 45; disposal of a provider's fiber removes its skills and emits `skills/change` |
| `skill-filesystem-test.rkt` | `skill-filesystem/tests/skill-filesystem.spec.ts`, `skill-filesystem-watcher.spec.ts` | rules 46 to 52; watcher cases sequence on the `skills/change` event, never on sleeps |
| `tool-skill-test.rkt` | `tool-skill/tests/tool-skill.spec.ts` | rules 53 to 58, every catalog text |
| `skill-office-test.rkt` | `skill-office/tests/{skill-office,progressive-loading,render-context}.spec.ts`, `tool-workspace-dependencies/tests/*.spec.ts` | rules 59 to 61; the four shipped files parse |
| `tool-pairing-test.rkt` | `compaction/tests/tool-pairing.spec.ts` | rule 62 |
| `compaction-basic-test.rkt` | `compaction-basic/tests/compaction-basic.spec.ts`, `compaction-loop-repro.spec.ts`, `runtime-context-admission.spec.ts` | rules 65 to 77 and 80 |
| `manual-compaction-test.rkt` | `compaction-basic/tests/manual-compaction.spec.ts`, `command-compact/tests/command-compact.spec.ts` | rules 73, 78, 79, 88, 89: every failure class, orphan handling, cancellation precedence |
| `pruner-test.rkt` | `compaction-tool-result-pruner/tests/tool-result-pruner.spec.ts` | rules 81 to 84 |
| `image-offload-test.rkt` | `compaction-image-offload/tests/{image-offload,projection}.spec.ts` | rules 85 to 87 |
| `preset-test.rkt` | `agent-preset-registry/tests/*.spec.ts`, `agent-preset/tests/*.spec.ts` | rules 90 to 100: broken definitions stay in the roster, leak audit, revision retention across a definition update, select lock, compose-from |
| `persona-test.rkt` | `preset/persona/tests/persona.spec.ts` | rule 101 |
| `plugins-test.rkt` | none | every row of `plugin-table` loads; config schemas accept the shipped preset configs and reject unknown keys where stated; one rejected config per plugin raises with the prefix `invalid config:` |

Fixtures: an in-memory `fs` port and a working-directory port double; a token-meter double with scripted node prices for range selection; the entry rows of the four preset files with rows of other packages replaced by empty stand-in plugins of the same names. Key-order fixtures, compared as `jvalue->string` text after the normaliser of `dsh-test-support`: the `compaction/start`, `compaction/summary`, replacement `user/message` and `compaction/end` lines of `snapshots/sdk/manual-compact/session.v4.jsonl`; the catalog and invocation messages of `snapshots/session/skill-load/session.v4.jsonl`; the instruction messages of `snapshots/session/agent-instructions/session.v4.jsonl`.

Recorded sessions that exercise this package (replayed in wave 5 when profiles launch; listed so the parity table can track them): `snapshots/session/{agent-instructions,agent-instructions-budget,agent-instructions-budget-chains,agent-instructions-group-failure,skill-load,skill-root-isolation,dsh-doc-load,office-skills,office-skills-no-renderer,workspace-dependencies,compaction-recovery,compaction-output-reserve,compaction-summary-headroom,model-switch-compaction,session-reference-spill}`, `snapshots/sdk/{manual-compact,minimal-image-compaction}`, `snapshots/acp/image-compaction`, `snapshots/web/{minimal-compact,minimal-preset,creator-persona,preset-migration,standard-dsh-doc,skill-tool-row}`.

Acceptance gate: `raco test racket/dsh-context` passes with no network, no Node and no tmux; every numbered rule has a test that names it; the three key-order fixtures pass; a scripted session under a preset stand-in that mounts `persona`, `agent-instructions`, `tool-skill` and the `compaction` group runs one turn whose first request holds, in order, the claimed prompt, the instruction baseline and the skill catalog, and after a forced pressure compaction the next request holds the checkpoint message followed by a replacement catalog.

## Open questions

1. **Sibling names behind the ports.** The owner procedures of `fs`, `spillStore` and `shell` were taken from the drafts of `dsh-fs.md` and `dsh-exec.md`; those of `workingDirectory`, `sessionQuery`, `commands`, `webApp` and `profileContext` are guesses at contracts not yet written. Sibling contracts declare their own consumer-owned port interfaces for the same services (`gen:working-directory-port` exists in `dsh-exec/ports` and `dsh-connect/ports`). Recommended default: keep the wrapper signatures of this document; when the coordinator gives each shared port one home, `dsh-context/ports` re-exports it and drops its own interface and the `dynamic-require` fallback.
2. **Home of the zone reader.** `dsh-util` covers `packages/util/time`, which owns `canonicalizeTimeZone`, and `dsh-automation` needs zone offsets for schedules. Recommended default: if `dsh-util` exports `canonicalize-time-zone` and a zone offset procedure, `dsh-context/time-context` re-exports them and `private/tzif.rkt` is not written; otherwise implement rule 24 here and offer the module to `dsh-util`.
3. **YAML scalar typing of frontmatter.** dsh parses SKILL.md frontmatter with the `yaml` package (YAML 1.2 core schema); `cordis-yaml` follows js-yaml. They agree on the scalars skill files use; they can differ on rare forms such as `0o17` or `~`. Recommended default: read with `cordis-yaml` using a schema argument that omits the `!!js` tag, treat any value that is not a string for `name` or `description` as a missing field, and add a test table of the boolean-like spellings.
4. **Collation.** `locale-string<?` approximates ICU root collation for ASCII. It decides only which of two same-named skills inside one root wins and the order of roster ties and of names in one error message. Recommended default: rule 2 as written.
5. **Entry tree interface.** `private/preset-tree.rkt` assumes `cordis-loader` exports a tree constructor that takes a context and a commit procedure, a root group with an update and a stop operation, a wait for quiescence, the list of entries with their options, disabled flag and fiber, and a `loader` service with a wait. Recommended default: write that module against the `cordis-loader` contract when it exists; until then against the names `make-entry-tree`, `entry-tree-root`, `entry-group-update!`, `entry-group-stop!`, `entry-tree-await`, `entry-tree-entries`, `entry-options`, `entry-disabled?`, `entry-fiber`, `loader-await`.
6. **YAML dump options of `read-document`.** dsh dumps with `noRefs` and unlimited line width. Recommended default: `yaml->string` with the line width disabled; if `cordis-yaml` accepts only a number, pass a number larger than any row.
7. **`maxTokens` failure identity in rule 75.** dsh throws a plain `Error` with an ad hoc `code` property. Recommended default: an `exn:fail:harness` with code `MAX_TOKENS` and dsh name `Error`, so `error-chain` text is unchanged.
8. **Checkout root of `harness-dev-context`.** In dsh it is the installation root of the TypeScript tree. Recommended default: `harness-checkout-root` is the directory four levels above `racket/dsh-context/data.rkt` resolved at run time, which is the repository root in a source checkout; a packaged install mounts this plugin only on request.
9. **Polling cost of skill watches.** Recommended default: use `filesystem-change-evt` where `(vector-ref (system-type 'fs-change) 0)` is `'supported`, else poll at `watchPollIntervalMs`; always poll when `watchUsePolling` is true.
