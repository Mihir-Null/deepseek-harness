# Recon 17: plugin authoring surface (input for the TypeScript-to-Racket plugin porter)

Pinned commit `e8f7b93a3` (`packages/`, `vendor/`, `scripts/` and `apps/` are byte-identical at the working HEAD `f7781527f`). Paths are relative to the repository root. Line numbers refer to that commit.

This note answers four questions for the porter: which declaration idioms occur in plugin source and how to recognise them mechanically, which constructs occur in handler bodies and how often, which TypeScript parsers exist on this machine without a network install, and which third-party plugins exist on npm. The kernel (`ctx.effect`, fibers, `Service`) is specified in `01-cordis-core.md`; the Loader, `cordis.yml`, `!!js` and Schemastery internals are specified in `02-cordis-loader.md`. This note only restates what a plugin author writes against them.

Method. Two passes. (1) Reading: the four cookbook pages, all ten `docs/user/develop/**` pages, the whole `dsh-doc` skill (SKILL.md, 16 references, both templates), `packages/AGENTS.md`, and the entry modules of 41 plugins by eye: 16 in full, 7 with their complete `apply` or class body, and 18 through their structural lines (imports, exports, `Config`, registration calls) plus selected bodies. (2) Counting: a syntax-only pass with the TypeScript compiler API (`ts.createSourceFile`, no type checker, no `node_modules`) over every `packages/*/*/src/**/*.{ts,tsx}` file of all 374 package directories. Every count in this note comes from that pass unless a file is cited. The scripts lived in the session scratchpad (`/tmp/claude-0/-home-user-deepseek-harness/9cf9e918-0d06-54f4-bb27-425975c383f7/scratchpad/scripts/{survey,survey2,report1,report2,report3,events}.cjs`) and are not part of the repository; the classification rules they used are restated under Porting notes so the counts can be reproduced.

Depth. `core/tools` (authoring files only: `schema.ts`, `contracts.ts`, `index.ts`, `events.ts`, `presentation.ts`), `core/system-prompt` (registration API), `interaction/commands` (registration API), `util/package-manifest`, the `dsh-doc` skill and its templates, and `scripts/verify-plugin-entry-exports.ts` are covered in depth. The 64 surveyed plugin packages are covered at catalog depth: export form, `name`, `inject`, `Config`, tool names, and excerpts where they show an idiom. Their behavior belongs to the recon note of their own area. `boot/plugin-market`, `test-support/loader-smoke` and the tool execution pipeline (`core/tools/src/pipeline.ts`, `batch.ts`, `executor.ts`) are catalog depth here.

## Scope

Corpus numbers: 374 package directories under `packages/*/*`; 90 are Client (browser) packages, 8 are `test-support`; the remaining 276 Host packages hold 259,018 source lines. 215 Host packages export a plugin (106 function plugins, 109 service plugins) with 214,875 lines; the other 61 are libraries or configuration-only bundles.

Authoring-surface owners:

| Package directory | npm name | Role | Lines |
|---|---|---|---|
| `packages/core/tools` | `@deepseek-ai/dsh-tools` | `ctx.tools`: tool registry, `defineTool`, value-schema DSL, enforced JSON Schema subset, presentation view types, policy events | 3794 |
| `packages/core/system-prompt` | `@deepseek-ai/dsh-system-prompt` | `ctx.systemPrompt`: ordered sections, runtime contexts, variables, tool providers, central order tables | 700 |
| `packages/interaction/commands` | `@deepseek-ai/dsh-commands` | `ctx.commands`: slash-command registry and executor, `command/run` and `command/done` session events | 745 |
| `packages/util/package-manifest` | `@deepseek-ai/dsh-package-manifest` | Types for `package.json` `dsh` fields and plugin display metadata; no runtime code | 117 |
| `packages/util/plugin-market-index` | `@deepseek-ai/dsh-plugin-market-index` | Parser and types for plugin market index format 1 | 447 |
| `packages/boot/plugin-market` | `@deepseek-ai/dsh-plugin-market` | `ctx.pluginMarket`: configured market indexes, fuzzy search, `plugin_market` tool (catalog depth) | 1869 |
| `packages/util/error` | `@deepseek-ai/dsh-error` | `HarnessError(message, code, options)` | 23 |
| `packages/preset/agent-preset` | `@deepseek-ai/dsh-agent-preset` | Preset declaration row (31 source lines) and the shipped `skills/dsh-doc` skill: `SKILL.md`, 16 reference files (1,009 lines), templates `decoration/` and `mcp/` | 31 |
| `packages/test-support/tool-testkit` | `@deepseek-ai/dsh-tool-testkit` | `defineContentToolFixture`, `executeToolFixture`, `executeModelToolFixture` | 93 |
| `packages/test-support/loader-smoke` | `@deepseek-ai/dsh-loader-smoke` | Boots a test `cordis.yml` through the real Loader (catalog depth) | 377 |

Non-package sources of this area: `docs/cookbook/{extension-cookbook,adding-a-package,adding-a-tool,adding-an-llm-adapter}.md` (449 lines), `docs/user/develop/{basic,framework,practice}/*.md` (10 pages, 1,280 lines), `packages/AGENTS.md`, `scripts/verify-plugin-entry-exports.ts` (485), `scripts/plugin-entry-existing-exports.ts` (259), `scripts/gen-plugin-packages.ts` (83), `scripts/gen-config-catalog.ts`, `scripts/gen-tool-catalog.ts`, `scripts/gen-cordis-catalog.ts` (1,480), `scripts/cordis-walk.ts` (102), and the generated artifacts `docs/tool-catalog.md` (2,862 lines), `docs/config-catalog.md` (253 KB), `packages/extensions/tool-cordis/src/api-catalog.ts` (10,946 lines), `packages/preset/agent-preset/skills/dsh-doc/references/packages.md` (282 loadable plugin packages).

Surveyed plugins. Form: `fn` is a function plugin (`async` when `apply` is async); `svc B ['key']` is a default-exported class extending `B` that calls `super(ctx, 'key')`. Read: E is read by eye (in full or structurally, as stated under Method), M is machine-extracted only.

| Package directory (`packages/…`) | npm name (`@deepseek-ai/…`) | Form | `name` export | Lines | Tools defined | Read |
|---|---|---|---|---|---|---|
| `todo/tool-todo` | `dsh-tool-todo` | fn async | `tool-todo` | 274 | `todo_write` | E |
| `shell/tool-bash` | `dsh-tool-bash` | fn | `tool-bash` | 857 | `bash` | E |
| `fs/tool-fs` | `dsh-tool-fs` | fn | `tool-fs` | 2463 | `read`, `read_image`, `write`, `edit`, `apply_patch` | E (entry) |
| `fs/tool-fs-search` | `dsh-tool-fs-search` | fn async | `tool-fs-search` | 1540 | `glob`, `grep` | E (entry) |
| `web/tool-web` | `dsh-tool-web` | fn | `tool-web` | 1046 | `web_search`, `web_fetch` | E (entry) |
| `skill/tool-skill` | `dsh-tool-skill` | fn | `tool-skill` | 452 | `skill` | E |
| `jobs/tool-jobs` | `dsh-tool-jobs` | fn | `tool-jobs` | 699 | `job_output`, `job_list`, `job_kill` | E |
| `schedule/tool-schedule` | `dsh-tool-schedule` | fn | `tool-schedule` | 490 | `schedule_create`, `schedule_list`, `schedule_view`, `schedule_edit` | E |
| `goal/tool-goal` | `dsh-tool-goal` | fn | `tool-goal` | 485 | `get_goal`, `create_goal`, `update_goal` | E |
| `interaction/tool-ask-user` | `dsh-tool-ask-user` | fn | `tool-ask-user` | 334 | `ask_user_question` (legacy and timed variants) | E |
| `plan/plan-mode` | `dsh-plan-mode` | svc `Service` `['planMode']` | none | 541 | `exit_plan_mode` | E |
| `preset/persona` | `dsh-persona` | fn | `persona` | 76 | none | E |
| `context/time-context` | `dsh-time-context` | fn async | `time-context` | 380 | none | E |
| `context/agent-instructions` | `dsh-agent-instructions` | fn | `agent-instructions` (re-exported from `./state.ts`) | 2120 | none | E |
| `guard/repeat-tool-reminder` | `dsh-repeat-tool-reminder` | fn | `repeat-tool-reminder` | 235 | none | E |
| `guard/timeout-policy` | `dsh-tool-call-timeout-policy` | fn | `timeout-policy` | 82 | none | E |
| `compaction/compaction-basic` | `dsh-compaction-basic` | svc `CompactionEngine` | none | 1750 | none | E |
| `compaction/command-compact` | `dsh-command-compact` | fn | `command-compact` | 109 | command `/compact` | E |
| `goal/command-goal` | `dsh-command-goal` | fn | `command-goal` | 199 | command `/goal` | E |
| `feedback/command-feedback` | `dsh-command-feedback` | fn | `command-feedback` | 198 | command `/feedback` | E |
| `spill/spill-policy` | `dsh-spill-policy` | fn | `spill-policy` | 350 | none | E |
| `interaction/permission-presets` | `dsh-permission-presets` | svc `TypertRemoteService` `['permissionPresets']` | none | 558 | none | E |
| `llm/llm-retry` | `dsh-llm-retry` | fn async | `llm-retry` | 321 | none | E |
| `llm/token-meter` | `dsh-token-meter` | svc `Service` `['tokenMeter']` | none | 1637 | none | E |
| `session/session-title-llm` | `dsh-session-title-llm` | library (shared Config fields) | none | 292 | none | M |
| `session/session-title-first-prompt-llm` | `dsh-session-title-first-prompt-llm` | fn | `session-title-first-prompt-llm` | 168 | none | M |
| `mcp/mcp-client` | `dsh-mcp-client` | fn async | `mcp-client` | 1999 | `mcp__<serverName>__<rawName>` (raw definitions) | E |
| `workflow/tool-workflow` | `dsh-tool-workflow` | fn | `tool-workflow` | 618 | `workflow` (config `toolName`) | E |
| `subagent/tool-subagent` | `dsh-tool-subagent` | fn async | `tool-subagent` | 955 | `subagent` (config `toolName`), `list_subagent_models` | E |
| `experimental/hooks-claude-code` | `dsh-hooks-claude-code` | fn | `hooks-claude-code` | 490 | none | E |
| `experimental/webhook-github` | `dsh-webhook-github` | fn | `webhook-github` | 287 | none | E |
| `experimental/tool-worktree` | `dsh-experimental-tool-worktree` | fn | `tool-worktree` | 44 | `create_worktree` | E |
| `experimental/tool-ralph` | `dsh-tool-ralph` | fn | `tool-ralph` | 478 | `ralph` | E |
| `experimental/translator` | `dsh-experimental-translator` | svc `Service` `['translator']` | none | 830 | none | E |
| `experimental/auto-review` | `dsh-experimental-auto-review` | fn | `experimental-auto-review` | 874 | none | E |
| `session/tool-working-directory` | `dsh-tool-working-directory` | fn | `tool-working-directory` | 44 | `working_directory` | E |
| `core/tool-executor-native` | `dsh-tool-executor-native` | fn | `native-tool-executor` | 36 | none | E |
| `deliverables/deliverable-file-references` | `dsh-deliverable-file-references` | fn | `deliverable-file-references` | 31 | none | E |
| `session/session-checkpoint-policy` | `dsh-session-checkpoint-policy` | fn | `session-checkpoint-policy` | 84 | none | E |
| `subagent/subagent-spawn-in-process` | `dsh-subagent-spawn-in-process` | fn | `subagent-spawn-in-process` | 60 | none | E |
| `experimental/skill-badge` | `dsh-skill-badge` | fn | `skill-badge` | 61 | none | E |
| `llm/llm-deepseek-api-key` | `dsh-llm-deepseek-api-key` | fn | `llm-deepseek-api-key` | 187 | none | E |
| `experimental/hooks-codex` | `dsh-hooks-codex` | fn | `hooks-codex` | 416 | none | M |
| `web/web-fetch-http` | `dsh-web-fetch-http` | fn | `web-fetch-http` | 481 | none | M |
| `subagent/subagent-fork-in-process` | `dsh-subagent-fork-in-process` | fn | `subagent-fork-in-process` | 84 | none | M |
| `subagent/tool-subagent-control` | `dsh-tool-subagent-control` | fn | `tool-subagent-control` | 376 | `send_message`, `interrupt_agent`, `list_agents`, `wait_agent` | M |
| `team/tool-agent-team` | `dsh-tool-agent-team` | fn | `tool-agent-team` | 236 | `team_task_create`, `team_task_list`, `team_task_get`, `team_task_update` | M |
| `lsp/tool-lsp` | `dsh-tool-lsp` | fn | `tool-lsp` | 440 | `lsp` | M |
| `deliverables/tool-present` | `dsh-tool-present` | fn | `tool-present` | 129 | `present` | M |
| `shell/shell-env` | `dsh-shell-env` | fn | `shell-env` | 257 | none | M |
| `fs/fs-observation-policy` | `dsh-fs-observation-policy` | fn | `fs-observation-policy` | 172 | none | M |
| `compaction/compaction-image-offload` | `dsh-compaction-image-offload` | fn | `compaction-image-offload` | 201 | none | M |
| `compaction/compaction-tool-result-pruner` | `dsh-compaction-tool-result-pruner` | svc `Service` `['toolResultPruner']` | none | 306 | none | M |
| `goal/goal-round-driver` | `dsh-goal-round-driver` | fn | `goal-round-driver` | 512 | none | M |
| `context/tmux-context` | `dsh-tmux-context` | fn async | `tmux-context` | 273 | none | M |
| `context/harness-dev-context` | `dsh-harness-dev-context` | fn async | `harness-dev-context` | 159 | none | M |
| `fs/tool-str-replace-editor` | `dsh-tool-str-replace-editor` | fn | `tool-str-replace-editor` | 538 | `str_replace_editor` | M |
| `session/session-stats` | `dsh-session-stats` | fn async | `session-stats` | 303 | none | M |
| `core/tool-executor-ptc` | `dsh-tool-executor-ptc` | fn | `ptc-tool-executor` | 2487 | `run_code` transport | M |
| `core/agent-default-model` | `dsh-agent-default-model` | svc `Service` `['agentDefaultModel']` | none | 98 | none | M |
| `computer-use/computer-use` | `dsh-computer-use` | svc `Service` `['computerUse']` | none | 65 | none | M |
| `mcp/mcp-resources` | `dsh-mcp-resources` | svc `Service` `['mcpResources']` | none | 226 | `list_mcp_resources`, `list_mcp_resource_templates`, `read_mcp_resource` | M |
| `experimental/tool-terminal` | `dsh-tool-terminal` | fn | `tool-terminal` | 620 | `terminal_open`, `terminal_send`, `terminal_read`, `terminal_signal`, `terminal_close`, `terminal_list` | M |
| `document/tool-office` | `dsh-tool-office` | fn | `tool-office` | 675 | `office_render`, `office_convert`, `office_recalculate` | M |

## Services

Only the methods a plugin author calls are listed. Full pipeline and assembly semantics are in the core recon note.

### `ctx.tools` (`ToolsService`, `packages/core/tools/src/index.ts:99-403`)

Class `ToolsService extends Service`, `static inject = ['systemPrompt']`, `super(ctx, 'tools')`. Default export of the package; also exported as `ToolRuntime`.

| Method | Semantics |
|---|---|
| `register(definition: ToolDefinition, options: ToolRegistrationOptions = {}): () => void` (`index.ts:128-153`) | Registers in the calling context's scope: global when the context is unscoped, the agent or preset scope otherwise. A scoped tool shadows a global one of the same name. Throws `TypeError('tool "<name>" must declare output { schema, render, presentationMeta? }')` when `output` is missing or malformed; runs `assertSupportedJsonSchema(output.schema)`; throws `TypeError('tool "<name>" timeoutMs must be a positive finite number')`; throws for the reserved name `run_code`; a duplicate in one layer throws `tool "<name>" is already registered (for a per-agent variant, register through that agent's \`agent.ctx\` instead)` (global) or `tool "<name>" is already registered in this scope`. Returns the effect disposer; the effect label is `tools.register()`. `options.when(context)` is a per-step activation condition: `({ agent, modelSelection, signal }) => boolean | Promise<boolean>`; false removes the tool from both declaration and dispatch for that step; rejection fails step preparation with `ToolActivationError` (`TOOL_ACTIVATION_FAILED`). |
| `restrict(filter: { allow?: string[]; deny?: string[] }): () => void` (`index.ts:162-189`) | Scoped contexts only. Masks global tools for that scope. Empty filter, unknown names, and `run_code` throw. Restrictions intersect; the scope's own registrations stay visible. |
| `guard(guard: ToolGuard): () => void` (`index.ts:384-386`) | Synchronous monotonic denial evaluated after all `tools/pre-execute` listeners. `guard(exec)` returns `undefined`, a reason string, or `{ reason, info? }`. |
| `get(name, scope?, toolSet?)`, `executable(name, scope?, toolSet?)`, `definitions(scope?, toolSet?)`, `schemas(scope?, toolSet?)` | Read the view one scope sees. `schemas()` returns only `name`, `description`, `parameters`, `deferLoading`, deep-copied. |
| `setExecutor(executor: ToolExecutor): () => void` (`index.ts:325-350`) | One executor per scope (native or PTC). Used by `tool-executor-native` and `tool-executor-ptc` only. |
| `execute(input: ToolBatchInput)`, `resolve(context)`, `checkGuards(exec)` | Called by the agent loop and executors, not by ordinary plugins. |

Ownership rule: every method that registers returns the disposer and is also bound to the calling fiber, so plugin unload removes the registration. A plugin never needs to store the disposer unless it swaps registrations at run time (see tool-bash under Algorithms).

### `ctx.systemPrompt` (`SystemPrompt`, `packages/core/system-prompt/src/index.ts:436-699`)

`super(ctx, 'systemPrompt')`. Author-facing methods, each returning a disposer and emitting `system-prompt/change` on registration and disposal:

- `section({ name, order, text, interpolate?, complete? })` (`:485`). `text` is a string or `(context: AssembleContext) => string`. Sections sort by ascending `order`, then by code-unit `name`. Empty text drops the section at render. A scoped section shadows the global one with the same name; a duplicate in one layer throws; a non-finite `order` throws `TypeError('prompt section "<name>" order must be a finite number')`. `complete: true` makes this section the whole system prompt.
- `context({ name, order, text, interpolate?, required? })` (`:520`). Dynamic runtime context materialized as a user-role snapshot, not system-prompt text. `required: true` survives `includeRuntimeContext: false`.
- `variable(name, provider)` (`:568`). `name` must match `/^[a-z][a-z0-9_]*$/`. Referenced in section text as `{{name}}`; interpolation is strict (unknown or undefined reference throws at render).
- `getSectionOrder(name)` and `getContextOrder(name)`. Resolve the central order tables (`:136-186`). Section orders: `HARNESS_IDENTITY -1000`, `DEPLOYMENT_PERSONA_PREFIX 0`, `PLAN_POLICY 500`, `TEAM_POLICY 600`, `PTC_ONLY 800`, `FILE_REFERENCE 900`, `TOOL_BASH 1000`, `TOOL_PWSH 1010`, `TOOL_READ 1100`, `TOOL_WRITE 1200`, `TOOL_EDIT 1300`, `TOOL_APPLY_PATCH 1350`, `TOOL_GLOB 1400`, `TOOL_GREP 1500`, `TOOL_JOBS 1600`, `TOOL_PTY 1700`, `TOOL_PTY_PANEL 1710`, `TOOL_WEB_SEARCH 2000`, `TOOL_WEB_FETCH 2100`, `TOOL_LSP 2200`, `TOOL_SESSION_QUERY 2300`, `TOOL_GOAL 2400`, `TOOL_SCHEDULE 2500`, `TOOL_WORKFLOW 2600`, `TOOL_RALPH 2700`, `TOOL_SUBAGENT 2800`, `TOOL_REPORT 2900`, `TOOL_COMPUTER_USE 3000`, `MCP_SERVERS 3100`, `TOOLS_SDK 5000`, `DELIVERABLE_FILE_REFERENCES 9000`, `STRUCTURED_OUTPUT 9900`, `HARNESS_SOURCE 10000`, `WEB_SURFACE 10100`, `DEPLOYMENT_PERSONA_SUFFIX 10200`. Context orders: `WORKING_DIRECTORY 100`, `SANDBOX_POLICY 110`, `APPROVAL_POLICY 115`, `SUBAGENT_DELEGATION 120`, `HARNESS_SOURCE 200`, `WEB_SURFACE 210`.
- `suppressRuntimeContext()`. Used by `dsh-persona` when `includeRuntimeContext` is false.

`AssembleContext` is merge-extensible: base fields `scope?`, `signal?` (`:42-50`); `dsh-tools` adds `toolSet?` (`core/tools/src/index.ts:18-23`); `dsh-agent` adds `agent?` (`core/agent/src/runtime-types.ts:19`; plan-mode reads `context.agent`, `plan/plan-mode/src/index.ts:200-203`).

### `ctx.commands` (`CommandRuntime`, `packages/interaction/commands/src/index.ts:263-533`)

`super(ctx, 'commands')`, extends `TypertRemoteService`. `register(definition: CommandDefinition): () => void` (`:285-292`), effect label `commands.register()`. `CommandDefinition` (`:61-79`): `definitionId?: CommandDefinitionId` (branded string, by convention the package name), `name` (must match `/^[a-z][a-z0-9_-]*$/u`, no leading slash), `description`, `input?: { hint: string; attachments?: boolean }`, `recordInput?: boolean` (default true; false omits `args` from `command/run`), `handler(invocation) => CommandResult | Promise<CommandResult>`. `CommandInvocation` (`:41-58`): `commandId`, `agent`, `rawInput` (exact text after the name, separator whitespace included), `attachments` (frozen empty array unless `input.attachments`), `signal`. `CommandResult` (`types.ts:34-41`): `{ kind: 'success', text?, sourceEventSeq? } | { kind: 'error', text }`. `parseCommand(line)` (`:125-133`) uses `/^\/([a-z][a-z0-9_-]*)(?=$|[\t\n\r ])/u`. Duplicate names fail like tools; scoped definitions shadow global ones.

### Kernel context members as plugins use them

Counts are call sites in the 276 Host packages, then the number of packages containing at least one.

| Member | Calls / packages | Form seen |
|---|---|---|
| `ctx.get('<key>')` | 252 / 69 | Optional service lookup; the key is a string literal in all but a few dynamic uses. The result is used with `?.` or compared with `undefined`. |
| `ctx.logger.warn/error/info/debug` | 228 / 82, 21 / 10, 15 / 7, 4 / 4 | printf-style: `ctx.logger.warn('msg: %o', error)`. |
| `ctx.on(event, listener, options?)` | 227 / 80 | No third argument in 190 calls; otherwise `{ global: true }` (21), `{ prepend: true }` (15), `{ global: true, prepend: true }` (1). No bare boolean third argument occurs in Host code. The returned listener disposer is used in 43 calls: stored in a variable, returned, pushed into a disposer list, or yielded inside a generator effect. |
| `ctx.effect(callback, label?)` | 177 / 110 | Of the 159 calls with an inline callback: 22 are generators (`function* () { yield disposer; … }`), 49 are arrows returning an async disposer (`() => async () => {…}`), the rest return a synchronous disposer or another registration's disposer. The other 18 calls pass a named function. Label is a string literal or template. |
| `ctx.inject(['a', 'b'], (child) => {…})` | 41 / 33 | First argument is always an array literal of string literals. The returned handle is kept in 8 calls. |
| `ctx.plugin(PluginOrClass, config?)` | 27 / 19 | Child plugin; used to mount an internal Service class from a function plugin. |
| `ctx.emit / waterfall / parallel / serial / bail` | 45, 24, 6, 1, 1 | Producers; the event name is a string literal except in a few generic dispatch helpers. |
| `ctx.provide('<key>', value)` | 13 / 10 | Plain value service without a class (`cmdlineArgs`, `webApp`, startup services). |
| `ctx.fiber.entry / assertActive() / uid / state / dispose() / inject / await` | 12, 9, 8, 6, 5, 3, 2 | `ctx.fiber.uid === null` means disposed; `ctx.fiber.entry?.options.id` reads the Loader row id. |
| `ctx.extend(...)` | 3 / 3 | Rare. |

Service keys by number of Host packages that call `ctx.<key>.*`: `logger` 103, `fs` 59, `tools` 54, `systemPrompt` 53, `agents` 47, `sessionProjections` 32, `sessions` 30, `workingDirectory` 29, `subagents` 25, `subprocess` 20, `terminals` 17, `goals` 17, `llm` 15, `sessionQuery` 14, `workspaceRegistry` 14, `loader` 13, `sandboxPolicy` 9, `skills` 9, `web` 8, `pluginManager` 7, `credentials` 6, `sandbox` 6, `webServer` 5, `schedule` 5, `agentTeams` 5, then 30 more keys with at most 4 packages each. The generated `packages/extensions/tool-cordis/src/api-catalog.ts` lists every service key with its public methods; use it as the service inventory.

Agent-object members used from plugins (call sites): `agent.id` 121, `agent.whenIdle` 20, `agent.status` 17, `agent.steer` 13, `agent.followup` 13, `agent.cancel` 12, `agent.inbox.nextStep` 11, `agent.inject` 10, `agent.session.append` 9, `agent.inbox.remove` 9, `agent.inbox.nextTurn` 6, `agent.ctx.effect` 6, `agent.ctx.get` 5, `agent.ctx.on` 4.

## Events

127 events are declared through `interface Events` merges in `packages/` and `vendor/`: 73 `emit`, 25 `waterfall`, 10 `parallel`, 4 `bail`, 2 `serial`, 13 kernel-internal without a `@mode` tag. A plugin author sees events only as `ctx.on(name, listener)`. The table lists every event with at least two inline listener functions in Host code (listeners passed as named functions are not counted), with the mode from the `@mode` JSDoc tag on the declaration.

| Event | Mode | Inline Host listeners | Listener signature | Declared in |
|---|---|---|---|---|
| `session/event` | emit | 32 | `(session, event)`; `event.type` discriminates durable session events (`turn/start`, `user/message`, `assistant/message`, `tool/result`, `turn/end`, …) | `core/session/src/index.ts` |
| `agent/pre-step` | waterfall | 17 | `({ agent, messages, turn, step, signal, modelSelection }, next) => Promise<PreStepDecision>` | `core/agent/src/runtime-types.ts` |
| `agent/created` | serial | 12 | `({ agent, source, signal? })` | same |
| `agent/disposed` | emit | 11 | `({ agent })` | same |
| `agent/error` | emit | 8 | `({ agent, turn, step, error })` | same |
| `session/disposed`, `session/created` | emit | 8, 7 | `(session)` | `core/session` |
| `agent/status` | emit | 7 | `({ agent, status })` | `core/agent` |
| `tools/execute` | waterfall | 7 | `(exec: ToolDispatchExecution, next) => Promise<ToolExecutionResult>`; only `exec.signal` is replaceable | `core/tools/src/events.ts:29` |
| `tools/post-execute` | waterfall | 7 | `(exec, result, next) => Promise<PostToolDecision>` | `events.ts:41` |
| `loader/volatile-update` | emit | 6 | `(paths)` | `vendor/loader` |
| `tools/pre-execute` | waterfall | 5 | `(exec, next) => Promise<PreToolDecision>` | `events.ts:18` |
| `tools/result` | emit | 5 | `(exec, result)`; frozen final outcome; listener failures are contained | `events.ts:49` |
| `agent/inbox/claimed`, `agent/inbox/inserted`, `agent/inbox/discarded` | emit | 5, 3, 2 | `({ agent, message, turn? })` | `core/agent` |
| `internal/plugin` | kernel | 5 | `(fiber)`; used with `{ global: true }` to observe own unload | `vendor/cordis/src/events.ts` |
| `agent/request-error` | waterfall | 3 | `({ agent, turn, step, provider, failure, retryPolicy, signal }, next) => Promise<RequestErrorAction>` | `core/agent` |
| `agent/turn-stopping` | serial | 3 | `({ agent, turn, signal })` | `core/agent` |
| `agent/assistant-stream` | emit | 3 | `({ agent, frame })` | `core/agent` |
| `fs/observed` | emit | 3 | `(target, observation, actor)` | `fs/fs/src/index.ts` |
| `fs/write-intent`, `fs/edit-intent`, `fs/delete-intent` | waterfall | 2 each | `(target, actor, next)` | `fs/fs` |
| `llm/stream` | waterfall | 2 | `(options: GenerateOptions, next: () => AsyncIterable<StreamChunk>) => AsyncIterable<StreamChunk>` (synchronous return of an async iterable) | `llm/llm/src/index.ts` |
| `system-prompt/assemble` | waterfall | 2 | `(assembly, context, next) => Promise<PromptPresentation>` | `core/system-prompt` |
| `session/flush` | parallel | 2 | `(session) => Promise<void> \| void` | `core/session` |
| `subagent/end`, `subagent/provider-added` | emit | 2 each | `(info)`, `(provider)` | `subagent/subagent` |
| `approval/request` | waterfall | 2 | `(req, next) => Promise<ApprovalOutcome>` | `interaction/user-approval` |
| `workflow/agent-start`, `workflow/agent-end` | emit | 2 each | `(info, agent)` | `workflow/workflow` |
| `workspace/session-activity` | waterfall | 4 | `(request, next) => Promise<readonly SessionActivity[]>` | `workspace/workspace/src/index.ts` |
| `workspace/session-stop` | parallel | 4 | `(request) => Promise<void> \| void` | same |
| `internal/status` | kernel | 3 | `(fiber, oldValue)` | `vendor/cordis/src/events.ts` |
| `internal/config` | waterfall | 2 | `(fiber, next)` | same |
| `credentials/record-updated` | emit | 2 | `(key)` | `credentials/credentials/src/types.ts` |

Events of this area's own packages: `tools/pre-execute`, `tools/execute`, `tools/post-execute` (waterfall), `tools/result`, `tools/change` (emit) in `core/tools/src/events.ts:6-58`; `system-prompt/assemble` (waterfall), `system-prompt/change` (emit); `commands/change` (emit, `interaction/commands/src/types.ts:82-91`). The first four are scope-filtered: a listener registered on `agent.ctx` receives only that agent's calls. `tools/change`, `system-prompt/change` and `commands/change` are unfiltered registry notifications.

Decision types a listener returns (`core/tools/src/contracts.ts:375-389`): `PreToolDecision = { kind: 'allow' } | { kind: 'deny'; reason; info? } | { kind: 'cancel' } | { kind: 'ask'; reason?; displayReason?: { en: string; [locale]: string } }`; `PostToolDecision = { kind: 'accept'; content?; additionalContexts? } | { kind: 'accept'; value; additionalContexts? } | { kind: 'block'; feedback; info?; additionalContexts? }`.

Ordering guarantees an author relies on: a waterfall listener must call `next()` to delegate, and returning without it short-circuits; `{ prepend: true }` puts the listener outermost; a rewriting listener must spread the downstream decision (`{ ...decision, messages }`) so fields such as `startsRequestSeries` survive (`dsh-doc/references/practices.md`). Session event types (`turn/*`, `step/*`, `tool/call`, `tool/result`, `compaction/*`) are not Cordis events; they arrive through `session/event`.

## Tools

### `defineTool` (`packages/core/tools/src/schema.ts:484-633`)

`defineTool(options): ToolDefinition`. Fields of the options object literal, with their frequency over the 73 `defineTool` call sites in the corpus:

| Field | Uses | Type and rule |
|---|---|---|
| `name` | 72 literal or constant, 1 spread | String. In 6 sites it is an identifier or config value (`EXIT_PLAN_MODE`, `config.toolName`), not a literal. |
| `description` | 72 | String expression. Often a constant, a concatenation, or a function call (`describe(allowParallel)`, `bashDescription()`). |
| `parameters` | 72 | `ParameterSchemaSpec`: a map from property name to a value-schema node plus optional `required: true`. The map is an implicit open object root. 64 sites use an inline object literal; 8 pass an identifier; conditional spreads inside the literal occur (`...background ? { run_in_background: {…} } : {}`). |
| `output` | 73 | `{ schema: ValueSchemaSpec, render(args, value): ContentBlock[], presentationMeta?(args, value): JsonValue }`. Mandatory. |
| `execute(args, exec)` | 73 | Returns a promise of the canonical value declared by `output.schema`. Written as an `async` method in most sites, as a plain method returning `Promise.resolve(...)` in some. |
| `presentCall(args)` | 54 | Pure; returns a `ToolCallView` or `undefined`. |
| `isConcurrencySafe(args)` | 26 | Pure; only `true` opts into parallel dispatch. |
| `presentResult(args, result)` | 14 | Pure; returns a `ToolResultView` or `undefined`. |
| `finalizeContent(exec, result)` | 8 | Synchronous last content transform; must not throw. |
| `timeoutMs` | 7 | Positive finite number; enforced by `dsh-tool-call-timeout-policy`, never sent to the model. `defineTool` throws `defineTool(<name>): timeoutMs must be a positive finite number`. |
| `projectContent(exec, result)` | 1 | Content prepared at execution, installed before post-execute policy. |
| `deferLoading` | 0 literal uses | `true` only. |

There is no zod or TypeBox in tool definitions. The parameter DSL is the repository's own value-schema DSL. Node kinds (`schema.ts:24-95`): `{ type: 'string' | 'number' | 'integer' | 'boolean' | 'null', enum?, const? }`, `{ type: 'array', items? }`, `{ type: 'object', properties?, additionalProperties: boolean }` (`additionalProperties` is mandatory on explicit object nodes), `{ type: 'json' }` (author-only: any lossless JSON), `{ oneOf: [a, b, …] }` (at least two branches, exactly one must match, no `type` beside it). Annotations on every node: `description`, `title`, `default`, `examples`. `required: true` is allowed only on a property of a property map (the implicit root or an object's `properties`), and only with the value `true`. Observed frequencies of per-property keys: `description` 187, `type` 182, `required` 94, `enum` 14, `items` 13, `oneOf` 5, `additionalProperties` 3; types: `string` 125, `number` 17, `array` 13, `integer` 12, `boolean` 11, `object` 3, `json` 1.

Compiled model-facing schema: `parameterSchemaSpecToJsonSchema` (`schema.ts:450-459`) produces `{ type: 'object', properties: {…}, required?: [...] }` with no `additionalProperties` key on the root. Per-node key insertion order, which decides the serialized bytes the model receives: object nodes `type`, annotations in the order `description`, `title`, `default`, `examples`, then `additionalProperties`, `properties`, `required`; array nodes `type`, annotations, `items`; scalar nodes `type`, annotations, `enum`, `const`; union nodes `oneOf`, annotations; `json` nodes annotations only (`schema.ts:336-413`). `required` lists property names in declaration order and is omitted when empty.

Raw `ToolDefinition` objects are accepted by `ctx.tools.register` without `defineTool` (`mcp/mcp-client/src/tools.ts:251-273`, `subagent/subagent/src/structured.ts:83`). They own their argument validation and must still satisfy the `output` requirement. `parameters` is then a raw JSON Schema record.

Execution context `exec: ToolRunContext` (`contracts.ts:175-262`): readonly `callId`, `rootCallId`, `name`, `arguments` (frozen lossless JSON), `agent?`, `toolSet?`, `parent?` (token of an enclosing `run_code`), `signal: AbortSignal`, `token`; methods `deferContext(userMessage)` and `concludeTurn()`. Author obligations (`docs/cookbook/adding-a-tool.md:41-50`): honor `exec.signal`; return one canonical JSON value; throw a `HarnessError` subclass with a stable `code` for expected failures (only a `HarnessError` keeps `error.name` and `error.code` on the result); `ToolArgsError(violations)` (`code: 'INVALID_ARGS'`, message `invalid arguments: <violations joined with '; '>`) for constraints the DSL cannot express; `ToolContextUnavailableError(message)` when the call lacks an agent or service.

Result format: success is `{ isError: false, value, content, meta?, additionalContexts?, concludesTurn? }`; failure is `{ isError: true, error: { message, info?: { name, code, reason? } }, content, … }` (`contracts.ts:339-364`). Model-facing failure text is `Error: <message>`. Cancellation codes: `ABORTED` after the body started, `ABORTED_BEFORE_DISPATCH` before. Unknown tool: `ToolNotFoundError`, code `UNKNOWN_TOOL`. Output violating the schema: `ToolOutputError`, code `INVALID_TOOL_OUTPUT`.

Presentation view types (`core/tools/src/presentation.ts`): `ToolCallView = { card: 'generic', title, kind?, rawInput?, content?, locations? } | { card: 'terminal', title, description?, cwd? } | { card: 'diff', title, diffs, locations? }`; `ToolResultView` adds `search` (`shape: 'matches' | 'paths'`), `read`, and `web` (`kind: 'search' | 'fetch'`) cards. `ToolCallKind = 'read' | 'edit' | 'delete' | 'move' | 'search' | 'execute' | 'fetch' | 'other'`. `defineTool` wraps `presentCall`, `presentResult` and `isConcurrencySafe` with soft validation: invalid logged arguments return `undefined` (or `false`) instead of throwing (`schema.ts:610-631`).

Approval and sandbox interaction is not part of a tool definition. A tool that needs approval for an escalation calls its own service helper (tool-bash resolves `ctx.get('approval')` and `ctx.get('sandboxPolicy')`, `shell/tool-bash/src/index.ts:223-262`); generic policy sits on `tools/pre-execute` (`ask`), `ctx.tools.guard()`, and `ctx.tools.restrict()`.

### Exact schemas of the small surveyed tools

`greet` (tutorial, `docs/user/develop/basic/tool.md`): description `Greet someone by name.`; parameters `name: { type: 'string', required: true, description: 'The name to greet' }`; output `{ type: 'string' }`; render `[{ type: 'text', text: value }]`; execute returns `` `Hello, ${args.name}!` ``.

`working_directory` (`session/tool-working-directory/src/index.ts:20-42`): description `Read the current working directory, or change it with cd. Relative paths use the current directory. Existing shells and running processes keep their own directories.`; parameters `cd: { type: 'string', description: 'Existing directory to enter. Omit to read the current directory.' }`; output `{ type: 'object', additionalProperties: false, properties: { cwd: { type: 'string', required: true, description: 'Current absolute working directory.' } } }`; render is the `cwd` text. Errors: `ToolContextUnavailableError('working_directory requires an agent Session')`; `ToolArgsError(['cd must not be empty; omit it to read the current directory'])`. Calls `ctx.workingDirectory.ensure(agent, signal)` or `.set(agent, cd, signal)`.

`create_worktree` (`experimental/tool-worktree/src/index.ts:17-42`): description `Create a new Git branch and worktree from a local commit, branch, or tag, then change this session's working directory to it. Uncommitted files stay in the source checkout. Existing names fail. Use working_directory with cd to leave; the checkout and branch remain.`; parameters `name` (string, optional, description `New branch name, also used as the checkout directory: a few lowercase words joined by hyphens that describe the task, such as fix-login-retry. Omit to generate a unique name.`) and `from` (string, optional, description `Local commit, branch, or tag to start from. Defaults to HEAD; no fetch is performed.`); output object, closed, required string fields `path`, `branch`, `baseCommit`, `repositoryRoot`; render `JSON.stringify(value)`; `presentCall` returns `{ card: 'generic', title: 'create_worktree', rawInput: args }`.

`todo_write` (`todo/tool-todo/src/index.ts:136-212`): description is `Record and update a task list to plan multi-step work and show progress; skip it for trivial single-step tasks. Add one todo per concrete step before you start. ` followed by `While work remains, keep exactly one todo \`in_progress\`. ` (when `allowParallelInProgress` is false) or `While work remains, keep the todos being worked on \`in_progress\`, several only when work runs in parallel. ` (true), followed by `Mark each todo \`completed\` as soon as it is done.`. Parameters: `todos` required array, description `The COMPLETE task list, replacing any previous list.`, items closed object with `content` (string, required, `What the task is — a short imperative line.`) and `status` (string, required, enum `pending`, `in_progress`, `completed`, description `pending (not started) | in_progress (now) | completed (done).`). Output: closed object `{ todos: [{ content, status }], counts: { pending, inProgress, completed } }` with integer counts. Render: `Updated todo list: <p> pending, <i> in progress, <c> completed.` Errors (plain `Error`): ``invalid todo: `content` must be a non-empty string``, `invalid todos: duplicate content <JSON string>`, `invalid todos: at most one task may be in_progress (got <n>)`, `todo_write requires an owning agent session`. Effect: `exec.agent.session.append('todo/write', { todos })`. `presentCall`: `{ card: 'generic', title: 'Update todo list', kind: 'other', rawInput: args.todos }`.

`ask_user_question`, legacy mode (`interaction/tool-ask-user/src/index.ts:39-119`): description `Ask the user a concise question when you need confirmation, a choice, or missing information before proceeding. An answer item with empty selected and no custom means the user skipped that question: continue without it, do not ask it again, and do not treat the skip as permission.`; parameters `questions` required array of open objects (`additionalProperties: true`) with `id` (string, required), `question` (string, required), `header` (string), `options` (array of open objects with `label` required string and `description` string), `multi_select` (boolean); output closed object `{ answers: [{ id, selected: string[], custom? }] }`; render `JSON.stringify(value)`; calls `ctx.userQuestions.ask({ questions, agent?, signal })`, mapping `multi_select` to `multiSelect`.

`exit_plan_mode` (`plan/plan-mode/src/index.ts:280-375`): description `Use only in plan mode. Present your plan for the user's review and, on approval, leave plan mode. The user may approve (carry out the plan from your next step) or keep planning — their feedback comes back in the tool result; revise and present again.`; parameters `plan` (string, required, `The complete plan, as markdown, starting with a # heading that names it.`); output `{ approved: boolean }`; registered with `{ when: ({ agent }) => this.selectedActive(agent.session) || this.planState(agent.session).entered }`.

All other tool schemas: `docs/tool-catalog.md` is generated by booting each tool plugin and reading `ctx.tools.schemas()`, because definitions are built at run time. Use it as golden data; the owning recon notes specify behavior.

## Configuration

### Config of the authoring-surface plugins

- `ToolsService` (`core/tools/src/index.ts:101-104`): `static Config = z.object({ mode: z.never().description('Removed. Mount a native or PTC tool executor instead.'), maxParallelSubCalls: z.never().description('Moved to the PTC tool executor configuration.') })`. Both keys exist only to reject old configuration.
- `SystemPrompt` (`core/system-prompt/src/index.ts:437-445`): `includeHarnessIdentity: z.boolean().default(true)`, `includeRuntimeContext: z.boolean().default(true)`, `personaPrefix: z.string().default('')`, `personaSuffix: z.string().default('')`, `toolOrder: z.array(z.string())` with an `undefined` default (omission means lexicographic tool order; a given list must contain `<unlisted-tools>` exactly once and no duplicates).
- `CommandRuntime`: no Config.
- `AgentPreset` (`preset/agent-preset/src/index.ts:12-29`): default-exported class that does not extend `Service`; `static inject = ['agentPresets']`; `static readonly [EntryGroup.key] = true`; `static Config = z.object({ id: z.string().required(), name: z.string(), description: z.string(), order: z.number(), plugins: z.array(z.any()).required() })`; `async* [Service.init]() { yield await this.ctx.agentPresets.register(this.config) }`.

### Config declaration idioms (all packages)

| Idiom | Count |
|---|---|
| `export const Config: z<Config> = z.object({ … })` beside `export interface Config { … }` of the same name | 75 |
| `static Config = z.object({ … })` or `static Config: z<T> = …` on the plugin class | 60 |
| `export const Config = z.object({ … })` without annotation | 16 |
| `export const Config: Schema<Config> = Schema.object({ … })` and untyped `Schema.object` | 9 |
| `export const Config = <identifier or call>` (shared schema, e.g. `Config: typeof BrowserMcpConfig = BrowserMcpConfig`) | 7 |
| `export const Config = z.union([z.object({ transport: z.const('stdio'), … }), z.object({ transport: z.const('streamable-http'), … })])` (`mcp/mcp-client/src/index.ts:161-190`) | 1 |

Further facts the porter must handle: `z<Partial<Config>, Config>` two-parameter annotations (13); the empty schema `z.object({}) as unknown as z<Config>`; spreads inside the object literal (`...deepSeekConfigFields`); fields that are identifiers or member accesses of shared schema constants (`SessionTitleLlmConfigFields.maxInputBytes`, `thresholdRatioSchema`); defaults that are imported constants (`z.number().default(READ_LIMIT)`) or arithmetic (`32 * 1024 * 1024`); `Config` re-exported from a sibling module (`export { Config, name }` in `context/agent-instructions/src/index.ts:33`). Field descriptions are not in the schema: `.description()` appears twice in the whole corpus. The human text lives in the JSDoc of the `interface Config` fields, and `docs/config-catalog.md` is generated from those declarations.

Schemastery is imported as `import z from '@deepseek-ai/schemastery'` (170 files) or `import Schema from …` (13). zod is a different library imported as `import { z as zod } from 'zod'` or `import { z } from 'zod'` (110 files in 62 packages) and is used for session-projection state schemas, Typert schemas and wire validation, not for plugin `Config`. The porter must resolve the dialect from the import, not from the identifier `z`.

Schemastery vocabulary actually used (call sites / packages): `default` 635/137, `number` 356/99, `min` 356/91, `string` 259/101, `object` 215/170, `step` 170/53, `max` 154/53, `natural` 116/32, `required` 98/52, `boolean` 83/41, `union` 82/46, `volatile` 77/24, `array` 55/38, `const` 42/20, `dict` 29/17, `pattern` 18/13, `role` 13/8, `transform` 5/4, `any` 5/3, `never` 4/2, `description` 2/1, `extra` 2/1, `hidden` 2/1, `loose` 1/1. Shorthands seen: `z.array(String)` (7), `z.dict(String)` (6), `z.union(['legacy', 'timed'])`, `z.union([-1, z.number().step(1).min(1).max(2_147_483)])`, `z.union(SANDBOX_MODES as SandboxMode[])`, `z.transform(z.string(), fn)`. `role` values: `credential-ref` (6), `secret` (4), `table` (2), `ms` (1). `.volatile()` marks fields edited in place and read through `config.field.get()` semantics (see `02-cordis-loader.md`).

zod vocabulary for reference (call sites): `string` 472, `object` 443, `number` 190, `strict` 174, `int` 148, `min` 142, `optional` 138, `literal` 125, `nullable` 118, `array` 104, `nonnegative` 98, `boolean` 93, `enum` 63, `transform` 53, `max` 46, `positive` 43, `parse` 37, `record` 32, `union` 29, `refine` 26, `regex` 22, `unknown` 22, `discriminatedUnion` 20, plus about 25 rarer methods.

### Config of the surveyed plugins

`inject` is the entry module's `inject` array. Defaults written as identifiers are constants in the same package.

| Plugin | `inject` | Config fields |
|---|---|---|
| `tool-todo` | `tools`, `sessionProjections` | `allowParallelInProgress: z.boolean().required()` |
| `tool-bash` | `tools`, `shell`, `systemPrompt`, `shellEnv`, `workingDirectory` | `enableRunInBackground: z.boolean().default(true)`; `promoteOnTimeout: z.boolean().default(true)` |
| `tool-fs` | `tools`, `fs`, `systemPrompt`, `workingDirectory` | `read`, `readImage`, `write`, `edit`: `z.boolean().default(true)`; `applyPatch: z.boolean().default(false)`; `readLimit`, `readMaxLineLength`, `readMaxBytes`, `readStreamMinSize`: `z.number().default(<constant>)` |
| `tool-fs-search` | `tools`, `systemPrompt`, `subprocess`, `workingDirectory` | `sampleOverCapGlobResults: z.boolean().required()`; `globMaxResults`, `grepMaxMatches`, `grepMaxLineBytes`, `searchMetaMaxBytes`, `rawOutputMaxBytes`, `graceMs`, `stderrMaxBytes`, `timeoutMs`: `z.number().default(<constant>)` |
| `tool-web` | `tools`, `web`, `systemPrompt` | `search`, `fetch`: boolean default true; `searchMaxResults`, `searchMaxQueries`, `searchSummaryMaxChars`: number defaults from constants; `fetchTimeoutMs`, `searchTimeoutMs`: default `30_000`; `fetchMaxOutputChars`: default `200_000` |
| `tool-skill` | `agents`, `tools`, `skills`, `workingDirectory` | `catalogDescriptionMaxLength: z.number().default(<constant>)` |
| `tool-jobs` | `tools`, `jobs`, `systemPrompt` | `waitTimeoutMs: z.number().min(1).default(30_000)`; `maxWaitTimeoutMs: z.number().min(1).default(600_000)`; `completionDelivery: z.union(['quiet', 'wakeup']).default('wakeup')`; `maxConsecutiveWakes: z.number().min(1)`; `inlineOutputBytes: z.natural().default(2048)` |
| `tool-schedule` | `tools`, `systemPrompt` (plus `ctx.inject(['schedule'], …)`) | none |
| `tool-goal` | `agents`, `goals`, `tools`, `systemPrompt` | `blockedAfterConsecutiveRounds: z.number().step(1).min(1).default(3)` |
| `tool-ask-user` | `tools`, `userQuestions` | `mode: z.union(['legacy', 'timed']).default('legacy')`; `timeout: z.union([-1, z.number().step(1).min(1).max(2_147_483)]).default(120)` |
| `plan-mode` | static `tools`, `systemPrompt`, `sessionProjections`, `agents` | constructor parameter `config: PlanModeConfig = { section: '' }`; no `static Config` |
| `persona` | `systemPrompt` | `prefix: z.string().required()`; `suffix: z.string().default('')`; `complete: z.boolean().default(false)`; `includeRuntimeContext: z.boolean().default(true)` |
| `time-context` | `agents`, `sessionProjections` | `timeZone: z.string()`; `refreshIntervalMs: z.number()` (code default `600_000`, validated as a non-negative safe integer in `apply`) |
| `agent-instructions` | `agents`, `workingDirectory` | schema in `./config.ts` |
| `repeat-tool-reminder` | none (no `inject` export) | `thresholds: z.array(z.number()).default([3, 5, 8])`; `include`, `exclude`: `z.array(z.string()).default([])`; `argumentsPreviewChars: z.number().default(500)` |
| `timeout-policy` | `tools` | none |
| `compaction-basic` | static `llm`, `tokenMeter`, `sessions` | `thresholdRatio`, `headroomTokens`, `retainRatio`, `retainTokens`, `summarizationProvider`, `summarizationModel`, `maxTokens`, `compactionRetries`, `maxOverflowRetries` (shared schema constants); `modelPolicies: z.array(modelPolicy)`; `auto: z.boolean()` |
| `command-compact` | `commands`, `compaction` | none |
| `command-goal` | `commands`, `goals` | none |
| `command-feedback` | `commands` | none |
| `spill-policy` | `tools` | `maxInlineTokens: z.number()` |
| `permission-presets` | static `shell`, `approval`, `sessions`, `agents`, `sessionProjections` | `presets: z.dict(z.object({ sandbox: z.union(SANDBOX_MODES).required(), approval: z.union(APPROVAL_POLICIES).required(), name: z.string(), description: z.string() })).default({ 'workspace-write': …, 'danger-full-access': … })`; `defaultPreset: z.string().volatile()` |
| `llm-retry` | `agents`, `sessionProjections` | `z.object({})`; `apply` rejects any key (`llm-retry: retryPolicy belongs under each provider configuration`, `llm-retry: unknown key "<key>"`) |
| `token-meter` | static `sessionProjections` | `z.object({})` |
| `session-title-first-prompt-llm` | `sessionTitle`, `llm`, `sessions` | `targetWords`, `targetCjkCharacters`: `z.number().step(1).min(1).required()`; `maxInputBytes`, `maxOutputTokens`, `timeoutMs`, `provider`, `model` from `SessionTitleLlmConfigFields` |
| `mcp-client` | `tools` | union on `transport` (`stdio`: `serverName` required with pattern `/^[A-Za-z0-9_-]{1,32}$/`, `command` required, `args: z.array(String).default([])`, `env: z.dict(String).default({})`, `cwd`, timeouts, `expandTemplates`, `failOnStartupError`, `maxInstructionBytes`; `streamable-http`: `url` required, `headers: z.dict(String).default({})`, same tail); full detail in `12-integrations.md` |
| `tool-workflow` | `tools`, `workflowEngine`, `systemPrompt` | `toolName: z.string().default('workflow')`; `maxResultChars: z.natural().min(1).default(50_000)`; `enableRunInBackground: z.boolean().default(true)` |
| `tool-subagent` | `tools`, `subagents`, `systemPrompt`, `sessionProjections` | `provider: z.string().required()`; `toolName: z.string().default('subagent')`; `modelSelection`, `modelDiscovery`: boolean default false; `agentOptions: z.object({ provider, model, reasoningEffort, maxTokens })` with `undefined` default; `agentPreset: z.string().min(1)`; `allowedAgentPresets`; `maxDepth: z.union([z.natural().max(Number.MAX_SAFE_INTEGER), z.const('provider-managed')])` |
| `hooks-claude-code` | `shell`, `agents`, `workingDirectory` | `configPath: z.string().required()`; `pluginRoot`, `projectDir`: `z.string()`; `defaultTimeoutMs`, `stderrSummaryMaxChars`: number defaults from constants |
| `hooks-codex` | `shell`, `agents`, `workingDirectory` | `configPath` required; `model: z.string().default('')`; `defaultTimeoutMs`, `stderrSummaryMaxChars` |
| `webhook-github` | `webServer`, `webhookRuntime`, `credentials` | `source`, `path`: required strings; `secretEnv: z.string().role('credential-ref').required()`; `maxBodyBytes: z.number().step(1).min(1).max(Number.MAX_SAFE_INTEGER).required()` |
| `tool-worktree` | `tools`, `worktrees` | none |
| `tool-ralph` | `tools`, `workflowEngine`, `subagents`, `systemPrompt` | `subagentProvider: z.string().default('spawn')`; `maxRounds` default 256; `maxHandoffChars`, `maxResultChars` default `16_384`; all three `z.number().step(1).min(1).max(Number.MAX_SAFE_INTEGER)` |
| `translator` | none | `provider: z.union(['google', 'bing', 'deepseek-account', 'deepseek-official']).default('bing')`; `googleEndpoint`, `bingEndpoint`: `z.transform(z.string(), endpoint).default(<url>)`; `timeoutMs`, `maxTextChars`, `maxResponseBytes`, `deepseekTimeoutMs`, `deepseekMaxOutputTokens`: `z.natural()` with bounds and defaults |
| `auto-review` | `approval`, `llm`, `permissionPresets`, `sessions`, `tools`, `workingDirectory` | none |
| `tool-working-directory` | `tools`, `workingDirectory` | none |
| `native-tool-executor` | `tools` | none |
| `deliverable-file-references` | `systemPrompt` | none |
| `session-checkpoint-policy` | `llm`, `sessionPersistence`, `sessions`, `tools` | none |
| `subagent-spawn-in-process` / `subagent-fork-in-process` | `subagents` | `providerName: z.string().default('spawn')` / `default('fork')` |
| `skill-badge` | `skills` | none |
| `llm-deepseek-api-key` | `llm` | `...deepSeekConfigFields`, `...modelListingConfigFields`, `apiKeyEnv: z.string().role('credential-ref').default('DEEPSEEK_API_KEY').volatile()` |
| `web-fetch-http` | `web` | `maxResponseBytes` 5,000,000; `maxBodyChars` 100,000; `timeoutMs` 30,000; `maxRedirects` 5; `userAgent` |
| `tool-subagent-control` | `tools`, `subagents`, `agents`, `systemPrompt` | `interrupt: z.boolean().default(true)` |
| `tool-agent-team` | `agentTeams`, `subagents`, `tools`, `systemPrompt` | `z.object({})` |
| `tool-lsp` | `tools`, `lsp`, `systemPrompt`, `workingDirectory` | `maxLocations`, `maxResultChars`, `timeoutMs` (max `MAX_TIMER_DELAY_MS`) |
| `tool-present` | `tools`, `fs`, `agents`, `workingDirectory` | `maxFiles: z.number().default(8)` |
| `shell-env` | `[]` (empty array) | `dshHome: z.string()` |
| `compaction-tool-result-pruner` | static `tokenMeter` | `thresholdChars`, `headChars`, `tailChars`: `z.number().step(1).min(…).default(DEFAULTS.…)` |
| `tmux-context` | `agents`, `sessionProjections` | `refreshIntervalMs: z.number()` |
| `tool-str-replace-editor` | `tools`, `fs` | `maxOutputChars: z.number().default(16_000)`; `description: z.string().default(DEFAULT_DESCRIPTION)` |
| `ptc-tool-executor` | `tools`, `systemPrompt`, `ptcRuntime` | `maxSubCallsPerMinute: z.natural().min(1).default(1024)`; `maxParallelSubCalls: z.natural().min(1).default(10)` |
| `agent-default-model` | none | `provider`, `model`: `z.string().required().volatile()`; `reasoningEffort: z.string().volatile()` |
| `tool-terminal` | `terminals`, `tools`, `systemPrompt`, `workingDirectory` | `enableRunInBackground` default true; `maxResultBytes` bounded number |
| `tool-office` | `tools`, `fs`, `workingDirectory`, `agents` | `activationSkills: z.array(z.string().pattern(/^[a-z0-9]+(?:-[a-z0-9]+)*$/)).min(1).default([...])`; `maxImages`, `maxImagePixels`, `maxImageDimension`, `maxImageBytes`: bounded `z.natural()` |
| `fs-observation-policy`, `compaction-image-offload`, `goal-round-driver`, `harness-dev-context`, `session-stats`, `computer-use`, `mcp-resources` | see Scope | none |

Common pattern: schema validation is followed by hand validation at the top of `apply` for constraints Schemastery does not express (integer, non-empty, trimmed), throwing a plain `Error` or `TypeError` with the plugin name as prefix (`repeat-tool-reminder/src/index.ts:135-178`, `webhook-github/src/index.ts:36-44`, `time-context/src/index.ts:116-122`).

## Formats

### F1. Plugin entry module: declaration idioms the porter must recognise

The corpus is every `packages/<group>/<package>/src/index.ts`, plus exported subpaths named in patches (`@deepseek-ai/dsh-plugin-manager/tools`, `@deepseek-ai/dsh-plugin-market/tools`, `@deepseek-ai/dsh-tool-subagent/model-selection-settings`, `@deepseek-ai/dsh-web-app/startup`, `@deepseek-ai/dsh-headless/startup`, `@deepseek-ai/dsh-tool-cordis/host`). The rule and its gate are `docs/defensive-patterns/package-surface.md` and `scripts/verify-plugin-entry-exports.ts:1-33`: the Loader reads only `name`, `inject`, `Config`, `apply` from a function plugin's module namespace (`LOADER_FIELDS`, `:54`), or the default-exported class of a service plugin.

D1. Function plugin (106 Host packages). Named exports, no default export. Combinations: `name` + `inject` + `Config` + `apply` 80; `name` + `inject` + `apply` 22; `name` + `Config` + `apply` 2; `inject` + `apply` 1; `name` + `apply` 1. `apply` arity over those 106 plus `test-support/llm-replay`: one parameter 25, two 81, three 1 (`llm-retry`, a test seam). `async apply` in 21 packages; an async `apply` delays activation until it resolves. No generator `apply`. Real example, complete (`preset/persona/src/index.ts:24-75`, comments removed):

```ts
export const name = 'persona'
export const inject = ['systemPrompt']
export interface Config { prefix: string; suffix?: string; complete?: boolean; includeRuntimeContext?: boolean }
export const Config: z<Config> = z.object({
  prefix: z.string().required(),
  suffix: z.string().default(''),
  complete: z.boolean().default(false),
  includeRuntimeContext: z.boolean().default(true),
})
export function apply(ctx: Context, config: Config): void {
  ctx.effect(() => ctx.systemPrompt.section({
    name: PERSONA_PREFIX_SECTION,
    order: ctx.systemPrompt.getSectionOrder('DEPLOYMENT_PERSONA_PREFIX'),
    text: config.prefix,
    ...(config.complete ? { complete: true } : {}),
  }), 'persona.section()')
  ctx.effect(() => ctx.systemPrompt.section({
    name: PERSONA_SUFFIX_SECTION,
    order: ctx.systemPrompt.getSectionOrder('DEPLOYMENT_PERSONA_SUFFIX'),
    text: config.suffix ?? '',
  }), 'persona.suffix()')
  if (!(config.includeRuntimeContext ?? true)) ctx.systemPrompt.suppressRuntimeContext()
}
```

D2. Service plugin (109 Host packages). The default export is a class. Three syntactic forms: `class X extends B { … }` followed later by `export default X` (98 packages, usually with `export class X` on the declaration too); `export default class X extends B { … }` (10); `export { default } from './x.ts'` (1, `typert/registry`). Base classes: `Service` 54, `TypertRemoteService` 29, a seam's class in 24 packages (`CompactionEngine`, `FileSystem`, `ShellExecutor`, `SubprocessRuntime`, `SandboxProvider`, `PtcRuntime`, `DirectoryPicker`, `JobRegistry`, `SpillStore`, `AttachmentStore`, `CredentialProvider`, `SessionQueryEngine`, `SessionTelemetryBackend`, `WorkflowEngine`, `FileReferenceService`, and concrete parents `LocalFileSystem`, `LocalBashExecutor`, `PwshLocalExecutor`); one class has no base (`AgentPreset`). Class members the Loader and kernel read: `static inject = [ … ]` (an array literal of string literals in 62 Host packages, a reference to a module-level `inject` constant in 2), `static Config` (68 default-exported classes across all packages), the constructor `(ctx, config?)` calling `super(ctx, '<serviceKey>')` (a seam subclass calls `super(ctx)` and the abstract parent supplies the key), and `protected async [Service.init](): Promise<void>` (35 uses; an `async*` generator form exists in `AgentPreset`). Skeleton from `plan/plan-mode/src/index.ts:176-232, 483`:

```ts
export class PlanModeController extends Service {
  static inject = ['tools', 'systemPrompt', 'sessionProjections', 'agents']
  constructor(ctx: Context, config: PlanModeConfig = { section: '' }) {
    super(ctx, 'planMode')
    this.section = resolveConfig(config).section
  }
  protected async [Service.init](): Promise<void> {
    const ctx = this.ctx
    ctx.systemPrompt.section({ name: 'plan:policy', order: ctx.systemPrompt.getSectionOrder('PLAN_POLICY'), text: (context) => … })
    this.planProjectionHandle = await ctx.sessionProjections.register(planProjectionDefinition)
    ctx.on('agent/pre-step', async ({ agent, signal }, next) => { … })
    ctx.inject(['commands'], (commandCtx) => { commandCtx.commands.register({ … }) })
    ctx.tools.register(defineTool({ … }), { when: ({ agent }) => … })
  }
}
export default PlanModeController
```

D3. Forbidden mix. A default export beside `apply` makes the Loader take the default and drop `inject` (`Loader.unwrapExports`: `exports = exports.default ?? exports`; `docs/postmortem/0001-acp-default-export-drops-inject.md`). The gate reports it. The object form `export default { name, inject, apply }` is documented (`docs/user/develop/basic/index.md`) and valid for Cordis, but no shipped Host plugin uses it.

D4. `inject`. Always an array literal of string literals, in both `export const inject = [...]` and `static inject = [...]`; the empty array occurs (`shell-env`). There is no `{ required, optional }` object form anywhere. Optional services are read with `ctx.get('key')` at the use site or through `ctx.inject(['key'], child => …)`. 61 distinct keys are injected by entry modules; the most frequent are `tools` 51, `agents` 38, `systemPrompt` 30, `workingDirectory` 27, `sessionProjections` 26, `sessions` 24, `subprocess` 18, `subagents` 15, `sandboxPolicy` 11, `llm` 10, `fs` 10.

D5. Type-only imports that exist for declaration merging: `import type {} from '@deepseek-ai/dsh-working-directory'` makes `ctx.workingDirectory` type-check and emits nothing. A side-effect import (`import '@deepseek-ai/dsh-user-questions'`) is the run-time variant. The porter can drop the first and must treat the second as a module dependency.

D6. Declaration merging blocks (`declare module '<specifier>' { interface <Name> { … } }`). Targets and counts across all packages: `@deepseek-ai/cordis#Context` 153 (one member per service key), `@deepseek-ai/cordis#Events` 53, `@deepseek-ai/dsh-session/types#SessionEventMap` 31 (durable session event types and their payloads), `@deepseek-ai/dsh-llm#MessageSourceMap` 29 (message source kinds), `@deepseek-ai/dsh-session-projection/types#SessionProjectionMap` 21, `@deepseek-ai/dsh-typert-protocol#RemoteErrorDetailsMap` 24, `@deepseek-ai/dsh-session/types#PluginRecordMap` 5, `@deepseek-ai/dsh-jobs#JobKindMap` 3, `@deepseek-ai/dsh-llm/types#LlmRequestPurposeMap` 3, `@deepseek-ai/dsh-system-prompt#AssembleContext` 2, `@deepseek-ai/dsh-agent#AgentOptions` 1, and the Client-side maps (`SlotMap`, `LocaleNamespaceMap`, …). Examples:

```ts
declare module '@deepseek-ai/dsh-llm' {
  interface MessageSourceMap { 'repeat-tool-reminder': { kind: 'repeat-tool-reminder' } & ContextFormed }
}
declare module '@deepseek-ai/dsh-session/types' {
  interface SessionEventMap { 'plan/mode': { active: boolean } }
}
declare module '@deepseek-ai/cordis' {
  interface Context { planMode: PlanModeController }
}
```

These blocks emit no JavaScript. They are the only static record of a plugin's service key type, event signatures and modes (in JSDoc `@mode`), session event payloads, and message source kinds. `scripts/cordis-walk.ts` and `scripts/gen-cordis-catalog.ts` already read them to generate the service and event reference.

D7. Tool registration: `ctx.tools.register(defineTool({ … }))` (78 call sites in 37 Host packages), sometimes through a local constant or a factory function (`bashTool(jobs)`), sometimes with a second argument `{ when }` (11). Fields are listed under Tools.

D8. Listener registration: `ctx.on('<event>', (…) => …)` with the option forms listed under Services. Waterfall listeners are `async` arrows with `next` as the last parameter and an explicit return type annotation.

D9. Effects: `ctx.effect(() => disposer, 'label')`; `ctx.effect(() => async () => { … }, 'label')` for asynchronous teardown; generator form with ordered yields, for example `compaction/command-compact/src/index.ts:97-107`:

```ts
ctx.effect(function* () {
  yield async () => { await Promise.allSettled(active) }
  yield ctx.commands.register({ definitionId: CommandDefinitionId('@deepseek-ai/dsh-command-compact'), name: 'compact', description: 'Compact older conversation history', handler })
}, 'command-compact lifecycle')
```

D10. Prompt registration: `ctx.systemPrompt.section({ name, order: ctx.systemPrompt.getSectionOrder('<NAME>'), text })` (28 call sites in 21 packages; `text` is a function in 19 handlers), `ctx.systemPrompt.context({ name, order, text, interpolate?, required? })` (5).

D11. Command registration: `ctx.commands.register({ definitionId, name, description, input?, recordInput?, handler })` (4 direct call sites; two more inside `ctx.inject(['commands'], …)`).

D12. Session projection registration: `await ctx.sessionProjections.register({ key, stateVersion, stateSchema, init, apply, wire? })` (35 call sites in 25 packages); `stateSchema` is a zod schema; `apply(state, event)` is a pure fold that returns the same reference for ignored events (`todo/tool-todo/src/index.ts:124-135`).

D13. Provider registration into another seam: `ctx.subagents.registerProvider(obj)`, `ctx.skills.registerProvider(() => provider)`, `ctx.llm.registerAdapter([routes], adapter)`, `ctx.web.registerSearchProvider(p)`, `ctx.webServer.register(route)`, `ctx.tools.setExecutor(executor)`.

D14. Child plugins and conditional sub-scopes: `ctx.plugin(SessionFeedbackService)` inside `apply` (`feedback/command-feedback/src/index.ts:117-118`); `ctx.inject(['attachments'], (imageCtx) => { applyReadImageTool(imageCtx) })` (`fs/tool-fs/src/index.ts:90-92`).

D15. Decorators: `@Remote('record')` on methods of `TypertRemoteService` subclasses (163 uses) and `@Inject` (2 uses), in 32 Host packages. `@Remote` registers a Typert remote method; the porter needs a declarative equivalent.

D16. Built third-party JavaScript. Bundlers emit `var name = "mem0"; var inject = [...]; function apply(ctx, config) {…}` and one trailing `export { apply, inject, name }`. The porter must accept the export-specifier list form and `var` declarations in addition to `export const` and `export function`.

### F2. `package.json` fields

Types: `packages/util/package-manifest/src/types.ts`. `dsh.manifestVersion?: 1`; `dsh.bundle: { patch: string | string[]; platforms?: string[]; listedByDefault?: boolean }`; `dsh.profile: { bundles?: string[] }`; `dsh.client: { platform: string; inject?: string[]; immediately?: boolean; external?: string[] }`; `engines.dsh` (SemVer range checked at install and profile start; without it the `@deepseek-ai/dsh*` peer ranges are checked); top-level `icon` (path relative to the manifest, SVG/PNG/JPEG/WebP, at most 256 KiB). In the workspace: 90 packages declare only `dsh.client`, 22 only `dsh.bundle`, 1 both, and 4 declare `dsh.sessionFormatMigration` (`from`, `to`, `export`, `migration`, `sourceCodec`, `targetCodec`), which the manifest type does not list. Bundle values seen: `{"patch":"./cordis.patch.yml"}` (18), a five-file ordered list (`bundle/web-app`), `platforms: ["darwin","win32"]` (1), `listedByDefault: false` (3).

Workspace package invariants (`docs/cookbook/adding-a-package.md:27`): `type: module`, `main: lib/index.js`, `types: lib/types/index.d.ts`, `exports["."]` with `types` and `default`, `@deepseek-ai/cordis` in both `peerDependencies` and `devDependencies`, `@deepseek-ai/schemastery` in `dependencies`. Display resources: `exports["./locale/*.json"]`, `exports["./icon"]`, `exports["./package.json"]`; a subpath plugin uses `./<sub>/locale/*.json` and `./<sub>/icon`.

Minimal Host-only bundle manifest from the skill (`dsh-doc/references/host-plugin.md`): `{ "name": "@local/my-plugin", "version": "1.0.0", "private": true, "type": "module", "exports": { ".": "./index.js" }, "dsh": { "bundle": { "patch": "./cordis.patch.yml" } } }`. The UI template (`templates/decoration/package.json`) adds `"./client": "./client.js"`, `"./locale/*.json"`, `"./icon": "./icon.svg"`, `files`, and `"client": { "platform": "web", "immediately": true, "inject": ["@deepseek-ai/dsh-client-ui-conversation"] }`. The MCP template has no code entry at all: exports only locale and icon.

### F3. Bundle patch (`cordis.patch.yml`)

A YAML array of patches. `- insert: [rows]` appends rows; a patch with `id` and no `insert` overrides the row with that id and replaces its whole `config`. Row keys used in the 49 `*.patch.yml` files under `packages/` (shipped bundles, presets and test fixtures): `id` (574), `name` (474), `config` (202), `disabled` (105), `insert` (51), `inject` (21), `isolate` (14), `group` (14); `intercept` is accepted and unused there. `name` is a package specifier, a package subpath, or a `cordis:` alias (`cordis:group`). A relative path in an inserted row is anchored beside its patch file. Templates:

```yaml
- insert:
    - id: my-decoration
      name: '@local/my-decoration'
```

```yaml
- insert:
    - id: demo-mcp
      name: '@deepseek-ai/dsh-mcp-client'
      config:
        serverName: demo
        transport: streamable-http
        url: http://127.0.0.1:3000/mcp
        failOnStartupError: true
```

Preset declaration row (`dsh-doc/references/compositions.md`): `name: '@deepseek-ai/dsh-agent-preset'`, row id `preset-<id>`, `config: { id, name?, description?, order?, plugins: [rows] }`. Layer order: bundle patches in `dsh.profile.bundles` order, then the profile's `cordis.patch.yml`, then `$DSH_HOME/cordis.patch.yml`, then each `--patch` in argv order (`docs/user/develop/basic/publish.md`).

### F4. `!!js` expression corpus

`!!js` scalars are JavaScript expressions evaluated by the Loader in `config` values and in `disabled`. The 112 `*.patch.yml`, `cordis.yml` and `*.overlay.yml` files under `packages/` and `apps/` contain 69 distinct expressions. The Racket Loader needs an evaluator for this expression subset regardless of the porter. Grammar that covers all 69: identifiers `process`, `ctx`, `dshHomePath`, `baseUrl`, `Number`, `String`, `JSON`; member access and optional chaining (`ctx.get('profileContext')?.name`, `ctx.webStartup.port`, `process.env.X`, `process.platform`, `process.execPath`); calls (`process.cwd()`, `dshHomePath('sessions')`, `Number(x)`, `String(x)`, `JSON.parse(x)`, `ctx.get('k')`, `process.getBuiltinModule('node:path').join(...)`, `.resolve(...)`, `.dirname(...)`, `createRequire(baseUrl).resolve(...)`); operators `??`, `||`, `&&`, `!`, `===`, `!==`, `? :`; string, number, boolean, `null`, `undefined` literals; array and object literals; one method chain with arrow functions (`(process.env.X ?? '').split(',').map((value) => value.trim()).filter((value) => value !== '')`); `['darwin', 'win32'].includes(process.platform)`. Most frequent: `process.cwd()` 45, `process.env.DSH_PERMISSION_MODE ?? 'workspace-write'` 26, `process.platform !== 'win32'` 10, `process.platform === 'win32'` 9, `"!ctx.get('profileContext')"` 8.

### F5. Display metadata and detail document

`locale/<lang>.json`: `{ "meta": { "title": "...", "description": "...", "detail": "docs/DETAIL.md" } }`; `en.json` is the discovery entry; first-party packages also ship `zh`, `ja`, `es`, `fr`, `de`, `ru`, `pt`. Title fallback: locale `meta.title`, then `package.json.name` for a package-root plugin, then the Cordis plugin name. Description fallback: locale, then `package.json.description`. `meta.detail` is a Markdown path inside the package ending in `.md` or `.markdown`; limits `pluginManager.detailMaxBytes` (1 MiB) and `pluginManager.detailImageMaxBytes` (5 MiB). Reads never activate the plugin.

### F6. Client module format (for completeness; not a porter target)

`client.js` calls `window.__ModuleLoader__.load({ id: '<package name>', factory(require) { const React = require('react'); return { inject: ['slots'], apply(ctx) { ctx.slots.inject('<slot>', () => ctx.slots.register({ name, id, order }, Component)) } } } })`. Client plugins are React components in the browser and stay JavaScript in any port (`15-web-client.md`).

### F7. Plugin market index format 1

`packages/util/plugin-market-index/src/types.ts`: `{ format: 1, title: LocalizedText, description?, metadata: { categories, labels, sortKeys }, plugins: [{ name, title?, description?, icon?, author?, homepage?, repository?: { url, directory? }, metadata: { category?, keywords: string[], labels: string[], sortKeys: Record<string, number> }, versions: [{ version, publishTimestamp, source: { type: 'npm', registry? } | { type: 'git', url, commit, path? }, engines: { dsh? } }] }] }`. `keywords` are free-form strings, by convention the package keywords. The market search (`boot/plugin-market/src/search.ts:97-102`) indexes `name`, `title`, `keywords`, `description`, `author`, `taxonomy` with boosts `name 3`, `title 3`, `keywords 2`. No in-repo code filters npm by a keyword; `PUBLIC_REGISTRIES` is `registry.npmjs.org` and `registry.npmmirror.com` (`boot/plugin-market/src/index.ts:89`).

### F8. Third-party plugins on npm (checked 2026-11-13, registry `https://registry.npmjs.org/`)

Both named packages exist and were fetched. Nothing from them was executed.

| Check | Result |
|---|---|
| `npm view @mem0/deepseek-plugin name version dist.tarball` | `0.3.2`, `https://registry.npmjs.org/@mem0/deepseek-plugin/-/deepseek-plugin-0.3.2.tgz` |
| `npm view @braintrust/deepseek-harness name version dist.tarball` | `1.0.0`, `https://registry.npmjs.org/@braintrust/deepseek-harness/-/deepseek-harness-1.0.0.tgz` |
| `npm pack` of both (with `--ignore-scripts`) | succeeded: `mem0-deepseek-plugin-0.3.2.tgz` (28.4 kB, 6 files), `braintrust-deepseek-harness-1.0.0.tgz` (11.8 kB, 8 files) |
| `npm search` for `deepseek-harness`, `dsh-plugin`, `deepseek harness plugin`, `keywords:dsh-plugin`, `keywords:deepseek-harness`, `cordis deepseek`, `dsh-bundle` | each returned the cap of 40 results; 165 distinct non-`@deepseek-ai` package names in total, 160 result lines mention `dsh-plugin`. One result, `dsh-plugin-catalog@2026.1113.20393`, describes itself as a catalog of 10,778 entries (not verified). |
| Anomaly | `npm view dsh-codebuddy-sdk version` reports `0.1.10` and `npm view dsh-all-search version` reports `0.2.22` (both `dist-tags.latest`), but `npm pack` of the bare names delivered `dsh-codebuddy-sdk-0.1.3.tgz` and `dsh-all-search-0.2.17.tgz`, whose inner `package.json` versions are `0.1.3` and `0.2.17`. Cause not determined; pin exact versions when fetching. |
| Failures | None of the registry calls failed. The only error seen in this investigation was local: `require('acorn')` by bare name throws `Error: Cannot find module 'acorn'` (see Porting notes). |

Unpacked under the session scratchpad, one directory per package (`/tmp/claude-0/-home-user-deepseek-harness/9cf9e918-0d06-54f4-bb27-425975c383f7/scratchpad/third-party/unpacked-<key>/package`); the scratchpad is not durable, so re-fetch by the versions above.

`@mem0/deepseek-plugin@0.3.2` (key `mem0`). Files: `dist/index.js` (653 lines, ESM, tsup output), `dist/index.d.ts`, `dist/index.js.map`, `README.md`, `LICENSE`, `package.json`. No `dsh.bundle`, no `cordis.patch.yml`, no locale or icon: it installs as a plain dependency and the user writes the row by hand. Keywords `deepseek-harness`, `dsh`, `dsh-plugin`, `cordis`, `mem0`, `memory`, `agent`. Peer dependencies `@deepseek-ai/cordis`, `dsh-agent`, `dsh-session`, `dsh-system-prompt`, `dsh-tools` (all `*`); dependency `mem0ai ^3.0.7`. Exports `name = "mem0"`, `inject = ["tools", "systemPrompt"]`, `apply(ctx, config)`; `Config` is a TypeScript interface only, with no run-time schema (`apiKey?`, `userId`, `allowUserOverride?`, `host?`, `autoRecall?`, `autoCapture?`). Behavior: a `system-prompt/assemble` waterfall listener that calls `next()` and appends `{ name: 'mem0:recall', text }` to `assembly.contexts`; a `session/event` listener that collects `user/message` and `assistant/message` between `turn/start` and `turn/end` and stores completed turns; two `defineTool` tools `search_memory` (`query` required string, `limit` integer, `userId`, `agentId`, `runId` strings; string output) and `add_memory` (`text` required string plus the same scope fields). It also uses `process.env.MEM0_API_KEY`, `process.env.MEM0_TELEMETRY`, `node:crypto`, `node:fs`, `node:os`, `node:path`, `process.on('beforeExit')`, a `WeakMap` keyed by session, and sends usage telemetry to a PostHog endpoint.

`@braintrust/deepseek-harness@1.0.0` (key `braintrust`). Files: `dist/index.mjs` (595 lines, ESM), `dist/index.js` (CommonJS), `dist/index.d.ts`, `dist/index.d.mts`, `cordis.patch.yml`, `README.md`, `LICENSE`, `package.json`. Declares `dsh.bundle.patch: "./cordis.patch.yml"`; the patch inserts `- id: braintrust, name: "@braintrust/deepseek-harness"`. Dependencies `@deepseek-ai/schemastery ^3.18.1`, `zod`, `braintrust ^3.29.0`; optional peers `@deepseek-ai/cordis >=4.0.1`, `dsh-llm`, `dsh-session`, `dsh-tools` (`>=0.1.0-rc.6 <0.2.0`). Its `publishConfig` enables npm's signed publish attestation. Exports `name = "braintrust"`, `inject = ["sessions", "llm", "tools"]`, `Config = z.object({ apiKey: z.string().role("secret"), projectName: z.string().default("DeepSeek Harness"), metadata: z.dict(z.any()), orgName: z.string(), appUrl: z.string() })`, `apply(ctx, config = {})`. Behavior: listeners on `session/created`, `session/disposed`, `session/event`, `session/flush` (async), `llm/stream` (wraps the async iterable), `tools/execute` (async wrapper around `next()`), and one `ctx.effect(() => async () => {…}, 'braintrust: flush Harness traces')`. Uses `AsyncLocalStorage` from `async_hooks`, `randomUUID`, `ctx.logger.warn`, and reads `ctx.attachments` without injecting it.

Five more packages were fetched to sample the ecosystem: `@dsh-enhanced/hello@0.1.68` (minimal bundle: `export const name = 'dsh-enhanced-hello'`, `export function apply(ctx) { ctx.logger.info(helloMessage) }`, patch row `dsh-enhanced-hello`); `dsh-all-search` (delivered 0.2.17: `inject = ['web']`, Schemastery `Config` with `.description()` on every field, provider classes calling `fetch`, `ctx.web.registerSearchProvider(wrapper)`); `dsh-codebuddy-sdk` (delivered 0.1.3: `inject = ['llm']`, `class CodeBuddyAdapter extends LlmAdapter`, `ctx.llm.registerAdapter([provider], adapter)`, wraps `@tencent-ai/agent-sdk`); `@chengze/dsh-plugins-market@2026.1113.30309` (an `index.json` in market format 1 with 3 plugins, git sources pinned by commit, `engines.dsh: ">=0.2.1-rc.5 <0.3.0"`); `dsh-plugin-start@0.2.4` (a scaffolder whose generated skeleton is `export const name`, `export const inject = []`, `export function apply(ctx) { ctx.effect(() => {…}) }`, `engines: { node: '>=20', dsh: '>=0.2.0 <0.3.0' }`, `peerDependencies: { '@deepseek-ai/dsh': '>=0.2.0 <0.3.0' }`).

Observations: third-party plugins ship built JavaScript, not TypeScript; all sampled Host plugins use the function-plugin form; they declare DSH compatibility ranges that predate or straddle the pinned 0.2.2-rc.2; they depend on npm SDKs or `fetch`.

## Algorithms and invariants

1. Entry classification (`scripts/verify-plugin-entry-exports.ts:1-33`, Loader `unwrapExports` in `02-cordis-loader.md`). An entry that exports a value named `apply` is a function plugin. Otherwise, an entry whose default export is a constructible class is a service plugin. An abstract default class is a capability definition, not a plugin. Everything else is a library. A default export beside `apply` is an error. `name`, `inject` and `Config` on a service entry are read from the class statics, not from the module.

2. Porter recognition order for one entry module. (a) Collect imports and classify each specifier: `node:*`, relative, `@deepseek-ai/*`, other npm; record type-only imports and drop them. (b) Resolve schema dialect per imported identifier (Schemastery default import, zod named import). (c) Find plugin exports in all three syntactic forms: `export const|function`, `export { a, b }` lists (also `var` declarations in built JavaScript), and re-exports from a sibling module, following relative `export … from` one hop at a time. (d) For a class default export, read `static inject`, `static Config`, the `super(ctx, '<key>')` argument, and `[Service.init]`. (e) Collect `declare module` blocks and map each merged interface to a registration kind (service key, event signature, session event type, message source kind, projection key, job kind). (f) Walk `apply` or the constructor and `[Service.init]` for registration calls (D7 to D14). The receiver is not always the identifier `ctx`: it can be `this.ctx`, a callback parameter (`commandCtx`, `jobCtx`, `imageCtx`, `child`), or `agent.ctx`.

3. Tool definitions are values built at run time. Names, descriptions and parameter maps depend on Config and on which optional services are mounted (`shell/tool-bash/src/index.ts:392-420`: `run_in_background` exists only when a job registry is present; `sandbox_permissions` and `justification` only when escalation modes exist; the `timeoutMs` description has two texts). `docs/tool-catalog.md` states that its generator boots each tool plugin for this reason. A porter cannot extract schemas statically; it must translate the constructing code and compare the booted result with the catalog.

4. `defineTool` wrapper (`schema.ts:555-633`). At definition time: validate `timeoutMs`; compile `parameters` and `output.schema` to the raw subset and run `assertSupportedJsonSchema` on both. At call time: `execute(args, exec)` validates `args` with `validateJsonSchemaValue(parameters, args, '')` and throws `ToolArgsError(violations)` before the body runs. Author-schema compile errors are `JsonSchemaError` (`code: 'UNSUPPORTED_SCHEMA'`, message `unsupported JSON schema: …`) with messages such as `<path>.additionalProperties must be explicitly true or false`, `<path>.required must be true when present`, `<path> cannot declare both type and oneOf`, `<path>.type must be string/number/integer/boolean/null/array/object/json, or use oneOf`, `<path>.<key> is not supported by the value schema DSL`, `<path> is circular` (`schema.ts:292-412`). Value violations read `missing required property "<path>"`, `"<path>" is not a declared property (additionalProperties: false)`, `"<path>" must be one of [...]`, `"<path>" must be an object` (`json-schema.ts:440-580`). Type inference is bounded to 16 container levels; that matters only for a typed target.

5. Scoped registries. `tools`, `systemPrompt` and `commands` keep one layer per scope plus a global layer; a registration lands in the layer of the calling context; lookup merges the scope chain with nearer layers shadowing farther ones; duplicates in one layer throw. Registration and disposal emit the registry's `…/change` event.

6. Optional-service swap (`shell/tool-bash/src/index.ts:570-583`). State machine: if `enableRunInBackground` is false, register the foreground tool once. Otherwise register the foreground-only tool unless `ctx.get('jobs')` already exists; inside `ctx.inject(['jobs'], jobCtx => …)` dispose the foreground-only registration, register the job-backed variant, and install `jobCtx.effect(() => () => { unregister(); if (ctx.fiber.state === FiberState.ACTIVE) foregroundOnly = ctx.tools.register(bashTool(undefined)) })`. The same tool name is therefore owned by one registration at a time and survives the registry unloading.

7. Drain-before-unregister (`command-compact/src/index.ts:86-107`, `llm-retry/src/index.ts:136-255`). Plugins that start asynchronous operations track them in a `Set<Promise>` and register a teardown that awaits `Promise.allSettled(active)`. With a generator effect, the drain is yielded before the registration because teardown is LIFO: the registration is removed first, then in-flight handlers settle. `llm-retry` additionally owns an `AbortController` (`lifetime`) fused with the caller signal through `AbortSignal.any([signal, lifetime.signal])`.

8. Signal replacement in `tools/execute` (`guard/timeout-policy/src/index.ts:56-80`). `using d = deadline(exec.signal, timeoutMs, TOOL_TIMEOUT)`; save `exec.signal`; set `exec.signal = d.signal`; `await next()`; if `timeoutOf(d.signal, TOOL_TIMEOUT) !== undefined` return `{ content: [{ type: 'text', text: 'Error: tool call timed out after <n>ms' }], isError: true, error: { message, info: { name: 'ToolTimeoutError', code: 'TOOL_TIMEOUT' } } }`; restore the signal in `finally`. The `using` declaration disposes the timer on scope exit.

9. Observe-then-delegate in `tools/post-execute` (`guard/repeat-tool-reminder/src/index.ts:220-225`): update own state first, `await next()`, then return `{ ...downstream, additionalContexts: [ours, ...(downstream.additionalContexts ?? [])] }`. Per-agent state lives in a `WeakMap<Agent, …>`.

10. Projection-ready pattern (`time-context/src/index.ts:158-243`, `llm-retry/src/index.ts:122-256`). `const ready = ctx.sessionProjections.register({…})` is started without `await`, listeners that need the handle `await ready` and then call `ctx.fiber.assertActive()` or check `ctx.fiber.uid === null`, and `apply` ends with `await ready` so activation waits for the registration.

11. Own-unload observation (`mcp/mcp-client/src/index.ts:247-251`): `ctx.on('internal/plugin', (fiber) => { if (fiber !== ctx.fiber || fiber.uid !== null) return; return dispose() }, { global: true })` closes resources while an unfinished async `apply` is still awaited; the same `dispose` is also registered as an effect.

12. Model-visible input needs a log record. A message a plugin injects carries a `source.kind` declared in `MessageSourceMap`; session format V4 rejects the old `{ kind: 'plugin', plugin: '<name>' }` wrapper (`docs/cookbook/adding-a-tool.md:50`). A plugin must not append a session event with a new `type` unless it declares it in `SessionEventMap` inside a first-party package; third-party plugins derive state from existing events (`dsh-doc/references/practices.md`).

13. Presentation purity. `presentCall`, `presentResult`, `output.render` and `output.presentationMeta` run on live calls and on session-log replay; they must be pure functions of their arguments. `projectContent` and `finalizeContent` are synchronous and must not throw.

14. Config timing. The schema validates and fills defaults before `apply` or the constructor runs; a plugin then treats defaulted fields as present (the TypeScript source casts: `config.thresholds as number[]`). A patch replaces a row's whole `config`. An edit to a non-volatile field restarts the plugin; a `.volatile()` field updates in place. A plugin persists its own configuration only through `ctx.get('configEditor').edit(ctx.fiber.entry, current => ({ ...current, field: value }))` (`dsh-doc/references/configuration.md`).

## Tests worth porting

| Path | Pins |
|---|---|
| `packages/core/tools/tests/schema.spec.ts` | Value-schema DSL compilation, `InferArgs`, `ToolArgsError` texts, `defineTool` soft validation of presenters |
| `packages/core/tools/tests/json-schema.spec.ts`, `properties.spec.ts` | The enforced JSON Schema subset and value validation messages |
| `packages/core/tools/tests/tools.spec.ts`, `scoped.spec.ts`, `activation.spec.ts`, `execution-mode.spec.ts` | Registration errors, scoped shadowing, `restrict`, `guard`, `when` conditions, parallel versus exclusive classification |
| `packages/core/tools/tests/gen-tool-catalog.spec.ts` with `docs/tool-catalog.md` | Booted schemas of every shipped tool; byte-level golden data for ported tool plugins |
| `scripts/gen-config-catalog.spec.ts` with `docs/config-catalog.md` | Every plugin's config declaration and `inject` list; golden data for ported Config schemas |
| `scripts/verify-plugin-entry-exports.spec.ts`, `scripts/plugin-entry-existing-exports.ts` | The two plugin forms and what an entry may export |
| `scripts/verify-cordis-config.spec.ts`, `scripts/cordis-config-files.spec.ts` | Where `!!js` is legal; every shipped patch names resolvable plugins |
| `packages/interaction/commands/tests/commands.spec.ts`, `builtin.spec.ts` | Command name rules, `parseCommand`, scoped shadowing, `command/run` and `command/done` pairing |
| `packages/preset/persona/tests/persona.spec.ts` | Scoped persona sections, `complete`, runtime-context suppression |
| `packages/guard/timeout-policy/tests/timeout-policy.spec.ts` | Signal swap and `TOOL_TIMEOUT` result |
| `packages/guard/repeat-tool-reminder/tests/repeat-tool-reminder.spec.ts` | Threshold counting, wildcard include and exclude, reminder texts |
| `packages/todo/tool-todo/tests/{tool-todo,projection,integration,loader-composition}.spec.ts` | A complete small tool plugin: validation errors, session event, projection fold, real Loader composition |
| `packages/compaction/command-compact/tests/{command-compact,loader-composition}.spec.ts` | Command plugin with drain on unload |
| `packages/preset/agent-preset/tests/skills.spec.ts` | The `dsh-doc` skill ships with its references and templates |
| `packages/test-support/tool-testkit/src/index.ts`, `packages/test-support/loader-smoke/src/index.ts` | Fixture helpers to mirror: run one tool through the pipeline; boot a `cordis.yml` through the Loader |
| `docs/user/develop/**` and `docs/cookbook/*.md` code fences | Fences without `ignore-check` are type-checked by the doc gates; they are the smallest valid plugins (`hello-plugin`, `greet-tool`, `tool-logger`, `permission-gate`) |
| `packages/preset/agent-preset/skills/dsh-doc/templates/{decoration,mcp}` | Two installable bundles used by models that write plugins; the MCP one is configuration-only and must load unchanged |

The HMR-safety rule from `packages/AGENTS.md` applies to every ported registration: dispose the fiber and observe that the tool, section, command or listener is gone.

## Porting notes

### Handler-body construct frequency

Definitions. A handler is the lexical body, nested functions included, of: an exported `apply`; a function passed to `ctx.on`; a function passed to `ctx.effect`; the `execute` member of a `defineTool` literal; a function-valued `text` of a prompt section or context; a command `handler` written inline. The Host corpus has 589 handlers: 120 `apply`, 219 listeners, 159 effects, 70 tool `execute`, 19 prompt text providers, 2 inline command handlers. Median handler length is 7 lines, 90th percentile 57, maximum 423. The measure is lexical: helper functions called by a handler are not followed, so the handler columns understate what a whole plugin needs; the package column covers whole packages.

| Construct | Handlers containing it (of 589) | Host packages containing it (of 276) | Occurrences | Tier |
|---|---|---|---|---|
| arrow function | 516 (88%) | 235 (85%) | 6771 | A |
| conditional expression `? :` | 149 (25%) | 229 (83%) | 4682 | A |
| template literal with substitutions | 109 (19%) | 225 (82%) | 5453 | A |
| array method (`map`, `filter`, `some`, `find`, `push`, `join`, `sort`, `slice`, `includes`, `flatMap`, `reduce`, …) | 131 (22%) | 220 (80%) | 6153 | A |
| `throw` / `new …Error(...)` | 120 (20%) / 133 (23%) | 217 (79%) | 4942 / 4386 | A |
| spread (object, array, call) | 154 (26%) | 212 (77%) | 3719 | A |
| `as` cast | 72 (12%) | 210 (76%) | 2291 | A (erased) |
| `async` function / `await` | 252 (43%) / 242 (41%) | 203 (74%) / 199 (72%) | 2349 / 4063 | A |
| `let` | 68 (12%) | 197 (71%) | 2018 | A |
| `try`/`catch` / `finally` | 69 (12%) / 23 (4%) | 190 (69%) / 104 (38%) | 1666 / 346 | A |
| optional chaining `?.` / `??` / `??=` | 98 (17%) / 82 (14%) / 12 (2%) | 189 (68%) / 189 (68%) / 69 (25%) | 2492 / 1626 / 139 | A |
| `for … of` / classic `for` / `while` | 69 (12%) / 1 / 3 | 180 (65%) / 72 (26%) / 89 (32%) | 1684 / 208 / 259 | A |
| class declaration or expression | 0 | 179 (65%) | 564 | C1 |
| `this` | 161 (27%) | 170 (62%) | 15089 | C1 |
| string method (`trim`, `split`, `startsWith`, `replace`, `replaceAll`, …) | 42 (7%) | 167 (61%) | 1388 | A |
| object destructuring / array destructuring | 146 (25%) / 18 (3%) | 151 (55%) / 125 (45%) | 783 / 471 | A |
| `new Set` / `new Map` | 24 (4%) / 20 (3%) | 142 (51%) / 131 (47%) | 710 / 613 | A |
| `Promise.all/allSettled/race/resolve/…` | 81 (14%) | 138 (50%) | 733 | B |
| `.then/.catch/.finally` | 55 (9%) | 131 (47%) | 729 | B |
| `typeof` / `instanceof` / `in` | 11 / 17 / 11 | 137 (50%) / 124 (45%) / 68 (25%) | 1369 / 542 / 215 | A |
| regular expression literal / `new RegExp` | 10 (2%) / 0 | 129 (47%) / 11 (4%) | 590 / 16 | A / B |
| `JSON.parse` / `JSON.stringify` | 27 (5%) | 125 (45%) | 645 | A |
| `new <project or library class>` (not an error, not a builtin) | 44 (7%) | 122 (44%) | 621 | C1 |
| `.signal` access / `.aborted` / `.throwIfAborted()` | 98 (17%) / 41 (7%) / 25 (4%) | 118 (43%) / 107 (39%) / 85 (31%) | 1083 / 373 / 602 | A |
| `Object.keys/entries/freeze/hasOwn/…` / `Array.from/isArray` | 13 / 0 | 114 (41%) / 83 (30%) | 927 / 367 | A |
| `switch` | 11 (2%) | 103 (37%) | 270 | A |
| `AbortController` / `AbortSignal.any/timeout/abort` | 14 (2%) / 16 (3%) | 74 (27%) / 54 (20%) | 140 / 119 | B |
| `Math.*` / `Number.*` | 6 / 21 | 74 (27%) / 135 (49%) | 292 / 487 | A |
| `addEventListener` / `removeEventListener` | 7 (1%) | 71 (26%) | 291 | B |
| `Buffer` | 2 | 66 (24%) | 441 | C3 |
| `new Promise` | 2 | 63 (23%) | 144 | B |
| `satisfies` | 3 | 59 (21%) | 126 | A (erased) |
| `yield` / generator function / async generator / `for await` | 31 (5%) / 31 (5%) / 0 / 0 | 58 (21%) / 39 (14%) / 30 (11%) / 32 (12%) | 205 / 60 / 64 / 55 | C2 |
| `process.platform`, `process.pid`, `process.execPath` and other property reads except `env` | 11 (2%) | 56 (20%) | 227 | C3 |
| `process.cwd()`, `process.on(...)` and other `process.*` calls | 6 (1%) | 32 (12%) | 95 | C3 |
| getter or setter | 0 | 50 (18%) | 147 | C1 |
| `URL` / `URLSearchParams` | 8 (1%) | 49 (18%) | 124 | B |
| timers (`setTimeout`, `setInterval`, `clearTimeout`, …) | 5 (1%) | 49 (18%) | 201 | B |
| `new WeakMap` / `new WeakSet` | 7 / 2 | 39 (14%) / 12 (4%) | 64 / 12 | B |
| `Date` | 7 (1%) | 34 (12%) | 146 | B |
| decorator (`@Remote` 163, `@Inject` 2) | 0 | 32 (12%) | 165 | C3 |
| `process.env` | 2 | 26 (9%) | 69 | B |
| `Reflect.*` | 1 | 25 (9%) | 147 | C3 |
| `using` declaration | 2 | 20 (7%) | 49 | C3 |
| `structuredClone` / `delete` | 3 / 1 | 19 (7%) / 19 (7%) | 49 / 46 | B / A |
| `TextEncoder` / `TextDecoder` | 0 | 17 (6%) | 29 | B |
| `Symbol(...)` / `Symbol.for` | 1 | 15 (5%) | 19 | C3 |
| dynamic `import()` | 2 | 13 (5%) | 20 | C3 |
| `fetch` | 0 | 12 (4%) | 16 | B |
| `console.*` | 4 | 11 (4%) | 39 | B |
| typed arrays, `ArrayBuffer`, `DataView` | 0 | 11 (4%) | 17 | B |
| `queueMicrotask` | 3 | 9 (3%) | 10 | B |
| tagged template (`String.raw`) | 0 | 8 (3%) | 21 | C3 |
| web streams / `AsyncLocalStorage` / `Proxy` | 1 / 0 / 0 | 4 / 4 / 2 | 7 / 6 / 4 | C3 |
| `for … in` / `enum` / labeled statement | 0 | 3 / 1 / 1 | 5 / 1 / 1 | B / C3 / C3 |

Run-time imports of Node modules by Host package count: `node:path` 82, `node:crypto` 57, `node:fs/promises` 46, `node:fs` 36, `node:url` 26, `node:os` 23, `node:util` 14, `node:buffer` 13, `node:module` 13, `node:stream` 10, `node:child_process` 9, `node:events` 7, `node:timers/promises` 6, `node:worker_threads` 5, `node:net` 5, `node:http` 4, `node:async_hooks` 4, `node:vm` 3, then `perf_hooks`, `assert/strict`, `stream/promises`, `zlib`, `sea` (2 each) and `util/types`, `v8`, `https`, `repl`, `string_decoder`, `tls`, `sqlite` (1 each).

Run-time third-party npm imports by Host package count: `zod` 49, `yaml` 8, `semver` 5, `chokidar` 4, `commander` 4, `js-yaml` 3, `execa` 3, `@agentclientprotocol/sdk` 2, `resolve.exports` 2, `hosted-git-info` 2, `diff` 2, `@opentelemetry/otlp-exporter-base` 2, `@opentelemetry/api-logs` 2, `@js-temporal/polyfill` 2, and one package each for `ws`, `mime-types`, `@babel/code-frame`, `picomatch`, `minisearch`, `@browserbasehq/stagehand`, `@puppeteer/browsers`, `shell-quote`, `@botiverse/oar`, `@octokit/webhooks`, `compression`, `ipaddr.js`, `negotiator`, `eventsource-parser`, `@earendil-works/pi-ai`, `@modelcontextprotocol/client`, `acorn`, `acorn-walk`, `birpc`, `p-limit`, `@anthropic-ai/claude-agent-sdk`, four more `@opentelemetry/*` packages, `got`, `@jridgewell/gen-mapping`, `typescript`, `mime`, `rrule`, `turndown`, `@joplin/turndown-plugin-gfm`.

### The TypeScript subset worth compiling

Tier A, the core language: `const` and `let`; arrow and named functions with default, rest and destructured parameters; closures; `if`, `switch`, `for … of`, `for`, `while`, `return`, `throw`, `try`/`catch`/`finally`; `async`/`await`; object and array literals with spread and computed keys; object and array destructuring; template literals; `?.`, `??`, `??=`, `? :`, `typeof`, `instanceof`, `in`, `delete`; `Map` and `Set`; array and string methods; `JSON`, `Math`, `Number`, `Object.*`, `Array.*`; regular expression literals; error construction and subclass-by-name checks; reading `signal.aborted` and calling `signal.throwIfAborted()`. All type syntax is erased first: annotations, interfaces, type aliases, `as`, `satisfies`, `!`, type-only imports and exports, and `declare module` blocks (which the porter reads as data before erasing).

Tier B, the same code plus a small Racket runtime prelude: promises as values (`Promise.all`, `allSettled`, `race`, `.then`, `new Promise`), timers, `AbortController` and `AbortSignal.any/timeout`, `Date.now()`, `URL`, `WeakMap` and `WeakSet`, `structuredClone`, `queueMicrotask`, `TextEncoder`, `fetch`, `process.env`, `console`, `Intl.DateTimeFormat` (`time-context`), event-target listeners on signals.

Tier C1, classes: single inheritance, constructor with `super`, methods, `static` members, private and readonly fields, getters and setters, `this`. Needed for every service plugin and for provider objects inside function plugins.

Tier C2, generators: `function*` effects with `yield disposer`, `async function*` stream wrappers with `yield*` and `for await`.

Tier C3, constructs that need a specific mapping each: `Buffer.byteLength` and `Buffer.from` (byte strings), `process.platform`, `process.cwd()`, `using` (scope-exit disposal), decorators (`@Remote`), `Symbol.dispose` and `Symbol.asyncDispose`, `Reflect`, `String.raw`, dynamic `import()`, web streams, `AsyncLocalStorage`, `Proxy`.

Fractions inside the subset (lexical handler bodies, Host):

| Population | Handlers | Tier A only | A or B |
|---|---|---|---|
| All handlers | 589 | 46% | 59% |
| All handlers, with class support (`this` allowed) | 589 | 66% | 85% |
| Handlers in function-plugin packages | 354 | 58% | 77% |
| of those: tool `execute` | 63 | 68% | 98% |
| of those: `ctx.on` listeners | 114 | 69% | 84% |
| of those: `ctx.effect` callbacks | 49 | 55% | 73% |
| of those: prompt text providers and command handlers | 18 | 100% | 100% |
| of those: `apply` bodies (which contain all nested handlers) | 110 | 35% | 55% |
| Handlers in service-plugin packages | 235 | 27% | 31% (the rest use `this`: 141 of 235) |

What pushes function-plugin handlers out of A or B (handlers containing the construct; an `apply` body counts for everything nested in it): constructing a project class 34, a generator function 19, `this` inside a nested class or method 20, `process.platform` and other `process` members 16, `using` 2, dynamic import 2, web streams 1, `Buffer` 1.

Whole-package buckets over the 215 Host plugin packages (214,875 lines):

| Bucket | Rule | Packages | Lines | Share of lines |
|---|---|---|---|---|
| 1. Translatable against the Racket services | No run-time import of a Node module other than `path`, `crypto`, `os`, `url`, `util`, `events`, `buffer`, `assert`, `timers/promises`; no third-party npm import other than `zod`; no dynamic import, web streams, `AsyncLocalStorage` or `Proxy` | 132 (65 function plugins) | 93,753 | 43.6% |
| 2. Node standard library heavy | Imports `fs`, `fs/promises`, `child_process`, `net`, `http`, `stream`, `worker_threads`, `module`, `vm`, `sqlite`, … but no third-party npm | 35 (16 function plugins) | 41,309 | 19.2% |
| 3. Third-party npm or a hard construct | Everything else | 48 (25 function plugins) | 79,813 | 37.1% |

Of the 35 packages that call `defineTool`, 30 have the bucket 1 import profile. Bucket 1 still needs classes (37 of its packages are class-based with no heavy imports) and generators (10). Plugin package sizes: minimum 31 lines, quartiles 257, 541, 1,056; 90th percentile 2,120; maximum 11,307; 60 packages have at most 300 lines and 154 at most 1,000.

Reading: a compiler for Tier A plus B plus classes plus the generator effect idiom, with the C3 mappings listed above, covers bucket 1, roughly 44% of plugin source lines and 61% of plugin packages, provided the Racket harness offers the same service methods. Bucket 2 is hand porting against Racket's own file, process and network libraries. Bucket 3 is wrapping or manual work.

### TypeScript parser options available without a network install

| Option | Fact on this machine |
|---|---|
| Repository `node_modules` | Absent (`ls: cannot access 'node_modules': No such file or directory`); `pnpm install` was not run. The repository pins `packageManager: pnpm@11.28.5`, `node >=24.9.0`, and dev dependencies `typescript ^6.0.3`, `tsx ^4.23.13`, `tsdown`, `oxlint`. The pnpm store directory exists and is empty. |
| `typescript` (compiler API) | Resolvable by bare name: `node -e "require('typescript')"` succeeds; `require.resolve` gives `/opt/node-tools/node_modules/typescript/lib/typescript.js`; version 6.0.2. Resolution works because `NODE_PATH=/usr/local/lib/node_modules_global`, a symlink to `/opt/node22/lib/node_modules`, where `typescript` is linked. `npm ls -g` lists `typescript@6.0.2`. `tsc` is at `/opt/node22/bin/tsc`. |
| What works without a project | `ts.createSourceFile(file, text, ScriptTarget.Latest, true)` parses `.ts`, `.tsx` and built `.js`/`.mjs` with no `tsconfig` and no dependencies; the survey for this note parsed all 374 packages this way. `ts.transpileModule` strips types to ES2022 text (`export const x: number = 1 as const` becomes `export const x = 1;`). A type checker run is not possible without `node_modules`, so cross-package type facts (for example whether an imported base class extends `Service`) must come from syntax plus the generated catalogs. |
| `ts-node` | 10.9.2, global. |
| Node type stripping | Node 22.23.4 (`/opt/node22/bin/node`) runs TypeScript with `--experimental-strip-types`; Node 24.22.1 (`/opt/node24/bin/node`) strips types by default. This erases types but gives no AST. |
| `acorn` 8.18.0, `acorn-walk`, `acorn-jsx`, `espree` 11.2.0, `esprima`, `escodegen` | Present under `/opt/node-tools/node_modules` as transitive dependencies. Not resolvable by bare name (`Error: Cannot find module 'acorn'`); load by absolute path. JavaScript only: usable on type-stripped output and on third-party built code. |
| `prettier` 3.8.1 | Global; ships `plugins/typescript.js`, `babel.js`, `acorn.js`, `meriyah.js` parsers. Usable as a second TypeScript-ESTree parser, with an API meant for formatting. |
| `eslint` 10.1.0 | Global; no `@typescript-eslint` parser installed. |
| `bun` 1.4.4 | `/root/.bun/bin/bun`; transpiles TypeScript; no AST API used here. |
| Racket 9.3 | `/usr/local/bin/racket`. Installed packages include `parser-tools`, `megaparsack` and `yaml`; `json` is in the base library; `brag` is not installed; there is no JavaScript or TypeScript parser package. |

Recommendation: a Node front end using the global `typescript` package emits a JSON syntax tree (after resolving imports, export forms and `declare module` blocks), and Racket consumes that JSON. Writing a TypeScript parser in Racket is not justified by the corpus. The front end must load `typescript` by bare name with the machine's `NODE_PATH`, or by the absolute path above.

### Suggested Racket decomposition

- `dsh-tools` authoring module: `define-tool` as a function over a hash (not a macro that requires literal fields, because definitions are built at run time), the value-schema compiler with the exact key order, `validate-args`, the error structs (`tool-args-error`, `tool-context-unavailable-error`, `harness-error` with `code`), and view constructors.
- Plugin module convention replacing F1 D1 to D3: one Racket module per plugin providing `plugin-name`, `plugin-inject`, `plugin-config` and `apply`, or a service struct with the same four facts. Define one convention; do not reproduce the ESM default-versus-namespace rule, but keep the Loader's row keys and specifier resolution so existing patches load.
- Registration calls return thunks and are owned by the calling fiber's custodian-like scope (see `01-cordis-core.md`). Generator effects map to a list of disposers pushed in order and undone in reverse.
- Waterfall listeners map to procedures taking the payload and a `next` thunk. Racket parameters do not replace `exec.signal`; keep an explicit signal object because wrappers replace and restore it.
- Schemastery expressions map to a combinator library with the 24 used methods; zod state schemas map to contracts or a small validator used by the projection service.
- `declare module` merges map to run-time declarations: a service key table (name to provider), an event table (name, mode, arity), a session event type registry, a message source kind registry, and a projection key registry. Mode and signature come from the JSDoc and the member type.
- Prelude for Tier B and C3: promise, timer, abort signal, `Date.now`, URL, weak tables, byte-length, platform, environment.
- Porter pipeline: Node front end (parse, classify, emit JSON) then Racket back end (emit module), then verification by booting the result and comparing `schemas()` against `docs/tool-catalog.md` and the Config against `docs/config-catalog.md`.

### Hard parts and risks

- Promise semantics. Handlers rely on JavaScript ordering details: `void operation.then(retire, retire)` to avoid unhandled rejections, `Promise.allSettled` drains, async teardown order, synchronous return of an async iterable from `llm/stream`. A thread-based Racket runtime must keep single-threaded turn ordering inside one context or state such as `WeakMap<Agent, Chain>` races.
- Object identity and freezing. `exec.arguments` is frozen JSON; `WeakMap` keys are agents, sessions and executions; projection folds must return the same reference for ignored events.
- Key order of emitted JSON (tool schemas, session events) affects model-visible bytes and cache reuse. Use ordered hashes.
- Dynamic tool definitions and conditional registration (Algorithms 3 and 6) defeat static extraction.
- Type erasure hides facts: service key types, event modes and payloads exist only in declarations and JSDoc. The generated catalogs (`api-catalog.ts`, `docs/subsystems/*`, `docs/config-catalog.md`, `docs/tool-catalog.md`) are the cross-check.
- Service availability. Bucket 1 assumes the Racket harness offers every service method the plugin calls (`ctx.fs`, `ctx.workingDirectory`, `ctx.sessionProjections`, `ctx.agents`, …) with the same names and results.
- `!!js` in patches needs a JavaScript expression evaluator in the Racket Loader (F4) for configuration compatibility, independent of the porter.
- Third-party plugins target several DSH versions and built JavaScript; their `engines.dsh` and peer ranges must be evaluated against the port's declared compatibility version.
- The lexical statistics do not follow helper calls and do not measure semantics; treat the bucket shares as upper bounds for automatic translation.

### What can only be wrapped

- Plugins that import third-party npm SDKs: `mcp-client` (`@modelcontextprotocol/client`), `llm-pi-ai`, `subagent-claude-code`, `subagent-acp` and `acp` (`@agentclientprotocol/sdk`), `browser-use-stagehand-native`, `webhook-github` (`@octokit/webhooks`), `otel` packages, `tool-web` HTML conversion (`turndown`), and both named third-party plugins (`mem0ai`, `braintrust`). Either run them in a Node sidecar that speaks to the Racket kernel, or re-implement the wire protocol natively where it is small (MCP stdio and streamable HTTP, OTLP/HTTP JSON, the Mem0 HTTP API).
- Client plugins (90 packages, React in the browser) stay JavaScript and are served unchanged.
- `ptc-runtime-node` and `workflow-ptc` execute model-written JavaScript and need a JavaScript engine by definition.
- Plugins whose value is the Node addon or a platform API (`cua-macos`, `cua-windows`, `sandbox-windows-acl`, `speech-to-text-sensevoice`).

For a sidecar, the smallest protocol follows the registration list of F1: the sidecar announces `name`, `inject`, the JSON form of `Config`, then issues register and dispose messages for tools, listeners, sections, commands and effects; the Racket side forwards `execute`, listener calls with a `next` handle, and abort signals. Per-plugin report categories: automatic (bucket 1, verified against the catalogs), wrapped (sidecar), manual (bucket 2 and anything failing verification).

## Feature checklist

- dsh-tools: `ctx.tools.register(definition, options)` returns a disposer and unregisters on fiber disposal
- dsh-tools: registration rejects a missing or malformed `output` with the exact `TypeError` text
- dsh-tools: registration rejects non-positive or non-finite `timeoutMs`
- dsh-tools: registration rejects the reserved name `run_code`
- dsh-tools: duplicate tool name in one layer fails with the global or scoped message
- dsh-tools: scoped registration shadows a global tool of the same name
- dsh-tools: `when` condition excludes a tool from declaration and dispatch for one step
- dsh-tools: rejected `when` condition fails step preparation with `TOOL_ACTIVATION_FAILED`
- dsh-tools: `restrict({ allow, deny })` works only on a scoped context and validates names
- dsh-tools: `guard()` denial cannot be undone by listener order
- dsh-tools: `schemas()` returns only `name`, `description`, `parameters`, `deferLoading`
- dsh-tools: `defineTool` compiles the parameter map to an open object root without `additionalProperties`
- dsh-tools: compiled schema key order per node kind matches the TypeScript output
- dsh-tools: `required: true` per property becomes a `required` list in declaration order
- dsh-tools: explicit object nodes require a boolean `additionalProperties`
- dsh-tools: `oneOf` needs at least two branches and matches exactly one
- dsh-tools: author-only `json` node accepts any lossless JSON value
- dsh-tools: unsupported author keys fail with `UNSUPPORTED_SCHEMA` and the path-qualified message
- dsh-tools: `execute` validates arguments first and throws `ToolArgsError` (`INVALID_ARGS`) with all violations
- dsh-tools: `presentCall`, `presentResult` return `undefined` and `isConcurrencySafe` returns false for invalid arguments
- dsh-tools: `output.render` and `presentationMeta` receive the validated canonical value
- dsh-tools: a thrown `HarnessError` keeps `name` and `code` on the failed result
- dsh-tools: `ToolContextUnavailableError` carries the `TOOL_CONTEXT_UNAVAILABLE` code
- dsh-tools: `tools/pre-execute` waterfall supports `allow`, `deny`, `cancel`, `ask`
- dsh-tools: `tools/execute` wrapper may replace and must restore `exec.signal`
- dsh-tools: `tools/post-execute` supports `accept` with content or value replacement, `block`, and `additionalContexts`
- dsh-tools: `tools/result` delivers a frozen outcome and contains listener failures
- dsh-tools: `tools/change` fires on registration, disposal and restriction changes
- dsh-tools: raw `ToolDefinition` objects register without `defineTool`
- dsh-tools: presentation view constructors for `generic`, `terminal`, `diff`, `search`, `read`, `web` cards
- dsh-system-prompt: `section()` orders by `order` then by name and drops empty text
- dsh-system-prompt: scoped section shadows the global section of the same name
- dsh-system-prompt: duplicate section name in one layer and non-finite order throw
- dsh-system-prompt: `section({ complete: true })` becomes the whole system prompt
- dsh-system-prompt: `context()` contributions with `required` survive runtime-context suppression
- dsh-system-prompt: `variable()` enforces the name pattern and strict `{{name}}` interpolation
- dsh-system-prompt: `getSectionOrder` and `getContextOrder` return the central table values
- dsh-system-prompt: `suppressRuntimeContext()` is scoped and independently disposable
- dsh-system-prompt: `system-prompt/change` fires on every registration and disposal
- dsh-system-prompt: Config `includeHarnessIdentity`, `includeRuntimeContext`, `personaPrefix`, `personaSuffix`, `toolOrder` with the `<unlisted-tools>` rule
- dsh-commands: `register()` validates the command name pattern and returns a disposer
- dsh-commands: scoped command shadows a global command; duplicates in one layer fail
- dsh-commands: `parseCommand` keeps `rawInput` verbatim including separator whitespace
- dsh-commands: handler receives `commandId`, `agent`, `rawInput`, `attachments`, `signal`
- dsh-commands: attachments are rejected unless the definition declares `input.attachments`
- dsh-commands: `recordInput: false` omits `args` from `command/run`
- dsh-commands: `command/run` and `command/done` pair by `commandId`
- dsh-commands: `commands/change` fires on registration and disposal
- dsh-package-manifest: `dsh.bundle.patch` accepts one path or an ordered list
- dsh-package-manifest: `dsh.bundle.platforms` and `listedByDefault` are honored
- dsh-package-manifest: `dsh.client` fields `platform`, `inject`, `immediately`, `external`
- dsh-package-manifest: `engines.dsh` range check with peer-range fallback
- dsh-package-manifest: locale `meta.title`, `meta.description`, `meta.detail` with per-field fallback
- dsh-package-manifest: icon from manifest `icon` or exported `./icon`, size and containment limits
- dsh-plugin-market-index: parse and validate market index format 1
- dsh-plugin-market-index: npm and pinned-git version sources map to install targets
- dsh-agent-preset: preset declaration row with `id`, `name`, `description`, `order`, `plugins`
- dsh-agent-preset: `dsh-doc` skill ships SKILL.md, 16 references and two templates
- dsh-agent-preset: `templates/mcp` configuration-only bundle loads unchanged
- dsh-agent-preset: `templates/decoration` Host half (`export function apply() {}`) loads unchanged
- dsh-persona: scoped prefix and suffix sections, `complete`, `includeRuntimeContext`
- dsh-tool-call-timeout-policy: deadline per declared `timeoutMs`, `TOOL_TIMEOUT` result, signal restored
- dsh-repeat-tool-reminder: consecutive identical-call counting with thresholds and wildcard filters
- dsh-tool-todo: `todo_write` validation, `todo/write` event, `todos` projection, description variants
- dsh-tool-working-directory: `working_directory` read and `cd` with the two error cases
- dsh-command-compact: `/compact` with drain of in-flight handlers on unload
- dsh-tool-bash: foreground-only and job-backed registrations swap with `ctx.jobs` availability
- porter: classify an entry as function plugin, service plugin, capability definition, or library
- porter: reject a default export beside `apply`
- porter: read `name`, `inject`, `Config`, `apply` in declaration, export-list and re-export forms
- porter: read `static inject`, `static Config`, `super(ctx, key)` and `[Service.init]` from a class
- porter: distinguish Schemastery from zod by import source
- porter: translate the 24 used Schemastery methods and the shorthand forms
- porter: map `declare module` merges to service, event, session-event, source-kind and projection declarations
- porter: translate `ctx.on` with `{ prepend: true }` and `{ global: true }` options and a used return value
- porter: translate arrow, async-disposer and generator forms of `ctx.effect`
- porter: translate `ctx.inject([...], callback)` and `ctx.get('key')` optional access
- porter: translate `defineTool` literals with conditional spreads and computed names
- porter: translate `ctx.systemPrompt.section/context`, `ctx.commands.register`, `ctx.sessionProjections.register`
- porter: parse built third-party JavaScript (`var` plus trailing `export { … }`)
- porter: Node front end runs with the global `typescript` 6.0.2 and no `node_modules`
- porter: verify a ported tool plugin against `docs/tool-catalog.md`
- porter: verify a ported Config against `docs/config-catalog.md`
- porter: per-plugin report with automatic, wrapped, manual categories and the reason
- porter: sidecar protocol for plugins that import npm SDKs
- porter: evaluate the 69 shipped `!!js` expressions in the Racket Loader
