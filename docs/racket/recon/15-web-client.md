# Recon 15: Web client (`packages/client/*`, `apps/web`)

Pinned commit `e8f7b93a3` (dsh 0.2.2-rc.2). All paths are relative to the repository root. Line numbers refer to that commit. The browser client is a second Cordis application that runs in the page; the Host process serves it and talks to it through `/api`, `/plugins` and one WebSocket.

## Scope

Depth statement. Covered in depth (source read): `web`, `modules`, `connection`, `hmr` (wire only), `ui-conversation` (contracts, input machine, assembly), `ui-chat` (every Conversation Definition), `ui-input-trigger`, `ui-commands`, `ui-approval`, `ui-user-questions` (wiring), `ui-tool` (card catalog), the settings family (what each page writes), `ui-session`/`ui-slots`/`ui-renderer` (plugin model only). Covered at feature level from the package README plus a source skim: `ui-sidebar`, `ui-workspace`, `ui-model-selection`, `ui-agent-preset`, `ui-permission-presets`, `ui-plan`, `ui-plugin-manager`, `ui-plugin-market`, `ui-reference`, `ui-skill`, `ui-attachment`, `file-upload`. Catalog depth only (README summary, manifest, grep of Remotes and events): every other package in the table, in particular `ui-primitives`, `ui-dockkit`, `ui-trajectory`, `ui-schedule`, `ui-sidebar-*`, `ui-settings-account`, `ui-settings-models`, `ui-theme`, `locale`, `shortcuts`.

Packages are named `@deepseek-ai/dsh-client-<dir>`. "Static" means the package is linked into the Vite shell and has no `dsh.client` row; every other package is a dynamic client plugin with a Host half (`src/index.ts`, usually an empty `apply`) and a browser half (`src/client/`, exported as `./client`, built to `lib/client.js`). Lines exclude tests. "Host inputs" lists `ctx.remote.<namespace>` methods and forwarded events (`ctx.remote.$on`).

### Kernel and shared services

| Directory | Lines | Role and user-visible feature | ctx keys | Host inputs |
|---|---|---|---|---|
| `web` (static shell) | 1128 | Boot kernel: static module table, client Cordis Loader, framework-free boot page ("HARNESS" wordmark, spinner, "Loading plugins…", failure list), mount handoff, Electron window-drag watcher. | none | `window.__DSH_BOOT__`, `__ModuleLoader__`, `__DSH_BOOT_READY__`, `__DSH_TRANSPORT__` |
| `modules` | 2835 | Dual face. Host: `ClientModuleRegistry` scans `dsh.client` rows, composes the boot graph, serves `/plugins`. Browser: lazy CommonJS module table used as `loader.internal`, live enable/disable of plugins, release-change gate. | Host `clientModules`; browser `modules` | `webServer`, `loader`, event `webserver/index-inject` |
| `connection` | 2751 | Dual face. Host: `/api` and `/connect` routes, browser cookie auth, Host/Origin trust, RPC and Fetch registries, Peers. Browser: unary RPC caller, connection generations, reconnect loop. | `connection` (both trees, different objects) | `credentials`, `webServer`; page globals |
| `hmr` | 345 | Host: stat-poll of client bundles, SSE `/plugins/events`. Browser: applies graph snapshots and rebuilt frames to `ctx.modules.entries`. | none | `clientModules`, `webServer` |
| `file-upload` | 975 | Raw Blob/stream upload from a Worker with progress; staged file receipts for prompts. | Host `fileUploads`; browser `fileUpload` | `fileUploads.upload`, exact Fetch route |
| `store` (static) | 393 | React-free observable and snapshot-store engine (Zustand + Immer), shallow equality, optional `localStorage` persistence. | none | none |
| `locale` | 1341 | Language preference (en, zh, ja, es, fr, de, ru, pt), dictionaries, Language row in General settings. | `locale` | settings namespace `locale` |
| `shortcuts` | 1245 | Keyboard command registry, physical-key routing, per-device overrides. | `shortcuts` | global `__DSH_SHORTCUTS_CONFIG__` |
| `resources` | 371 | `dsh-resource://<type>/…` address → live value; `useResource` hook. | `resources` | none (providers call Remotes) |
| `product-analytics` | 495 | Desktop-only product events through the Host OTel exporter. Disabled outside the `desktop` profile. | `productAnalytics` | `productAnalytics.report`, `.watchPolicy` |
| `ui-slots` (static) | 2051 | Slot registry core and the type algebra for component props. | none (`slots` is provided by `ui-renderer`) | none |
| `ui-renderer` | 2724 | Binds observables to React hooks, renders `root`, owns React contexts. | `slots`, `uiRenderer` | none |
| `ui-primitives` (static) | 18487 | Controls, icons, menus, Markdown with TeX, terminal/diff/read/search/web/JSON renderers. Drops raw HTML and restricts links in model output. | none | none |
| `ui-dockkit` (static) | 5498 | Split-tree docking layout with invertible operations; used by the right Sidebar. | none | none |
| `ui-theme` | 2986 | light/dark/system, font sizes and families, `--dsw-*` tokens, pre-boot palette script, Appearance and Font size rows. | `theme` | settings namespace `ui-theme` |
| `ui-layout` | 1450 | Three-column `AppFrame`, column widths, main-panel selection, overlays, document title. | `layout` | none |
| `ui-session` | 762 | Session scope adapter: `useSession`, `useSessions`, `useSessionStatus`, pending interactions, completion-unread state. | `uiSession` | `sessions`, `remoteAccess`, event `api-session/status` |
| `ui-context-menu` | 749 | Typed, plugin-extensible right-click menus and More buttons. | `contextMenus` | none |
| `ui-file-actions` | 424 | Save original file, copy image as PNG, reveal saved file (Desktop). | `fileActions` | `workspaceFiles.readBytes/stat`, `session.openWorkspacePath` |
| `ui-file-drag` | 274 | Drag images from chat or sidebar into the composer or other apps; failure toast. | `fileDrag` | none |

### Conversation, chat and composer

| Directory | Lines | Role and user-visible feature | ctx keys | Host inputs |
|---|---|---|---|---|
| `ui-conversation` | 19810 | Target-neutral assembly of the Session event window, conversation shell (header, View tabs, hero, composer, queue dock, todo dock, context meter, width handles), input machine, draft persistence, sent-user-text rules. | `conversation`, `uiConversation` | `sessions` (prompt, cancel, queue, page), `fileUpload`, settings namespace `ui-conversation` |
| `ui-chat` | 19003 | Chat target: node Definitions, process groups, whole-Turn folding, renderers, turn navigator, stats pills, scroll following, Work details settings rows. | none | settings namespace `ui-chat`, `remote.session` |
| `ui-tool` | 6256 | Tool call tree, generic card, built-in tool rows, todo history. | none | `remote.$host`, `sessions` |
| `ui-trajectory` | 13867 | Trajectory View (event ledger, timing overview, record inspector); Host half keeps live tool results. | Host `sessionToolResults` | `toolResults.watch` |
| `ui-approval` | 849 | Approval takeover of the composer. | none | forwarded waterfall `approval/request` |
| `ui-user-questions` | 3345 | `ask_user_question` card, plan-review card, answered bubble. | `userQuestionPanels` | waterfall `user-questions/request`, `userQuestions.answer`, `.attachWait` |
| `ui-attachment` | 1536 | Draft attachment rail, drop overlay, message images, lightbox. | none | none (uses injected loaders) |
| `ui-input-trigger` | 2123 | `/` and `@` detection, candidate menu, pick routing. | `inputTriggers` | none |
| `ui-commands` | 2015 | `/` source, command catalog cache, popupSelect shell, client-owned commands. | `commandUi` | `commands.list`, `.execute`; events `commands/change`, `agent-preset/selected` |
| `ui-reference` | 601 | `@file`, `@dir/`, `@session` reference source and chips. | none | `fileReferences.list`, `sessionReferenceResolver.candidates` |
| `ui-skill` | 834 | `/skill` candidates, skill tool row, SKILL.md preview. | none | `skills.list`; events `agent-preset/selected`, `plugin-manager/changed` |
| `ui-secret-mask` | 978 | Draws recognised credentials masked in sent user text (first eight characters kept). | none | none |
| `ui-model-selection` | 1988 | Composer model seat, reasoning effort, `/model` popup. | `modelDirectories` | `session.modelCatalog`, `session.selectModel`; events `llm/models-updated`, `llm/adapters-updated`, `credentials/*`, `settings/document-updated` |
| `ui-permission-presets` | 1445 | Composer access-mode control, `/permission` popup, default-permission row. | none | `permissionPresets.catalog`, `settings.mutate`; event `permission-presets/catalog-changed` |
| `ui-agent-preset` | 3264 | Preset picker on the blank home, header chip, Settings → presets page, Creator entry. | none | `agentPresets.list/read/select`, `settings.update` |
| `ui-plan` | 908 | Plan chip in the composer, submitted-plan cards, plan Markdown tab. | none | `commands.execute` (`/plan off`), `session` projections |
| `ui-goal` | 1040 | Goal bar above the composer; `/goal` command-input bubble. | none | `goals.get/edit/pause/resume/clear`; event `goal/activation-changed` |
| `ui-deliverables` | 2792 | Changed-files card, delivery cards, clickable file mentions, review tab. | `chatFileMentions` | `remote.session`; Host half injects `workspaceChanges`, `workspaceFiles` |
| `ui-message-feedback` | 1339 | Like/Dislike, feedback dialog, `/feedback`. | `feedbackUi` | `messageFeedback.list/put/delete`, `sessionFeedback.record` |
| `ui-workflow-run` | 1197 | Workflow run node with phases and members. | none | none (events only) |
| `ui-subagent` | 2268 | Subagent tree in the header, child transcripts, continuation, `@subagent` source. | none | `sessions` subagent catalog |
| `ui-agent-team` | 991 | Shared team task board under the subagent tree. | none | `agentTeams.setEnabled`, projections |
| `ui-jobs` | 1548 | Background-job list in the header with streaming output panels. | none | `jobs` service (`job.list`, `job.follow`) |
| `ui-schedule` | 10273 | Automation tasks page, task tab, header clock, row marks. | none | `schedule.catalog/create/edit/run/history/deleteInactive/deliveryLimits`; event `schedule/changed` |

### Navigation, sidebars and settings

| Directory | Lines | Role and user-visible feature | ctx keys | Host inputs |
|---|---|---|---|---|
| `ui-sidebar` | 2019 | Left column: brand, New Session, panel list, More, collapse rail, drawer below 768px. | none | none |
| `ui-workspace` | 7957 | Workspace and Session tree, search, ordering, pin, archive, rename, fork, directory flow, startup restoration. | `uiWorkspace` | `workspaces`, `sessions`, `remote.query`, `remote.directoryPicker` |
| `ui-brand-official` | 474 | Official brand mark and the click-triggered pixel whale on the blank home. | none | none |
| `ui-entry-customization` | 263 | More menus that pin or unpin panels, Views and guide cards; "create plugin" entry. | none | none |
| `ui-directory-picker-browse` | 1751 | In-app directory browser dialog. | none | `directoryPicker` |
| `ui-directory-picker-native` | 117 | Drives the OS directory chooser. | none | `directoryPicker` |
| `ui-open-in-app` | 1668 | "Open in" application submenu, open file in default application. | none | `session.workspacePathApplications`, `.openWorkspacePath`, `.canOpenWorkspacePath` |
| `ui-sidebar-right` | 5129 | Right Sidebar docking surface per Session, tab registry, guide page. | `sidebarRight`, `sidebarRightTabs` | none |
| `ui-sidebar-files` | 4697 | Workspace file tree and search. | none | `workspaceFiles.list/search/changes` |
| `ui-sidebar-documentpreview` | 7294 | File preview tab: Markdown, code, HTML, PDF, images, Office, spreadsheets, plain text. | `documentPreviews` | `workspaceFiles.read/readBytes/stat`, `officeKit.render/generation` |
| `ui-sidebar-terminal` | 1067 | Interactive shell tabs. | none | `webTerminals` |
| `ui-sidebar-browser` | 2063 | Sandboxed HTTP(S) browser tabs. Disabled outside `desktop`. | none | none |
| `ui-settings` | 1077 | `configForms` (settings mirror and write queue), settings slot types, Coding Tools preference. | `configForms`, `settingsSchema` | `settings.describe`, `.mutate`; event `settings/document-updated` |
| `ui-settings-general` | 2601 | Settings dialog shell, General section, connection pill, release-change dialog, onboarding ledger. | none | `settings.openSettingsDocument`, `remote.$host.isLoopback` |
| `ui-settings-models` | 7524 | Models page, API keys, custom providers, onboarding dialogs. | none | `llm.listProviders/listConfigurableProviders/discoverModels`, `credentials.describe/set/unset`, `session.modelCatalog`, `settings.mutate` |
| `ui-settings-account` | 3807 | Account section, sign-in, balance, account menu. | `accountUi` | `account.*`, `session.initializeDefaultModel` |
| `ui-account-notifications` | 589 | Account notification cards. | none | `account.getNotifications/getNotificationContent/reportNotificationEvent` |
| `ui-settings-plugins` | 415 | "Built-in plugins" settings section shell and tab row. | none | none |
| `ui-settings-plugin-inventory` | 1498 | Read-only Plugin list tab. | none | `pluginInventory.list` |
| `ui-settings-shell` | 352 | Shell page on the Plugins page. | none | settings namespaces `bash-sandbox`, `pwsh-sandbox` |
| `ui-settings-agent-loop` | 314 | Agent loop page. | none | settings namespace `agent-loop` |
| `ui-settings-subagent` | 1380 | Subagent page. | none | namespaces `subagent`, `subagent-model-selection-settings`; `session.modelCatalog` |
| `ui-settings-web-search` | 1606 | Web search and fetch page. | none | namespaces `web`, `web-deepseek-api`, `web-search-deepseek`; `web.listProviders`, `credentials.*` |
| `ui-settings-session-log` | 232 | Session-log upload switch in General. | none | one settings namespace, field `enabled` |
| `ui-shortcuts` | 1120 | Shortcut reference dialog and recorder. | none | none |
| `ui-plugin-manager` | 9888 | Sidebar Plugins page. Host half: registry probe Remote. | `pluginChanges`, `pluginNavigation`; Host `pluginRegistryProbe` | `pluginManager.*`, `pluginInventory.list`, `pluginRegistryProbe.fastest`; events `plugin-manager/*` |
| `ui-plugin-market` | 2488 | Discover tab. Mounted only by `packages/experimental/plugin-market-bundle`. | none | `pluginMarket.listIndexes/setIndexes/search/readEntryDetail`; event `plugin-market/changed` |

`packages/client/tsdown.client.ts` is the shared build preset for dynamic bundles, not a package. `apps/web` (`@deepseek-ai/dsh-web-frontend`) is the Vite build of the shell: `index.html`, `src/main.ts` (38 lines), `src/preview.ts` (WebWorker preview bootstrap), `vite.config.ts` (264 lines), `public/` (PWA manifest and icons), and 283 files under `tests/` (Playwright scenarios, expected output, fixtures). Client plugins that live outside this area but appear in the roster: `@deepseek-ai/dsh-client-ui-cordis` (`packages/extensions/ui-cordis`), `@deepseek-ai/dsh-api-remotes`, `@deepseek-ai/dsh-api-session-controller`, `@deepseek-ai/dsh-api-workspace-controller`, `@deepseek-ai/dsh-api-job-controller`, `@deepseek-ai/dsh-api-terminal-controller`, `@deepseek-ai/dsh-api-workspace-files`, `@deepseek-ai/dsh-api-remote-access`, `@deepseek-ai/dsh-cordis-client-runner`, `@deepseek-ai/dsh-message-quotes`. The roster itself is `packages/bundle/web-app/cordis.patch.yml:232-492`.

## Services

Two Cordis trees exist. The Host tree is the ordinary `dsh` process. The browser tree is created by `AppWebEntry` (`packages/client/web/src/boot.ts:83`) with a fresh `new Context()`; its services are different objects even when the key is the same (`connection`).

### Host tree

**`ctx.clientModules` — `ClientModuleRegistry`** (`packages/client/modules/src/index.ts:646`, Service class, `static inject = ['loader']`). Methods: `graph(): WebBootGraph` (stable object between changes); `clientPath(id)`; `fetchBundle(request: Request): Promise<Response>` (same responses as the HTTP route; unknown → 404, other methods → 405, `HEAD` builds no body); `artifactBaseline(id)` → `{ path, mtimeMs, ctimeMs, size }`; `rebuilt(id)` → current rev, recomposes only when the stat triple changed; `onRebuilt(listener(id, rev))`; `onGraphChanged(listener())`. Construction runs the first scan synchronously and throws one aggregated `ClientPackageCompositionError` for malformed declarations or missing `lib/client.js` (lines 695-701). The `/plugins` prefix route is registered inside `ctx.inject(['webServer'], …)` so it follows the Web carrier's lifetime (lines 703-709).

**`ctx.connection` — `HostConnectionService`** (`packages/client/connection/src/rpc-host.ts`; plugin `client-connection`, function plugin, `inject = ['credentials']`). Interface `HostConnectionHandle` (`src/rpc.ts:211-283`): `rpc.handle(channel, handler)` and `rpc.intercept('/api', matches, handler)` (both return async disposers); `fetch.register({ path, methods, requestBody: 'buffered' | 'streaming', fetch })`; `browserPeer`; `allowsRemoteAuthorities`; `createSharedFetchHandler('/api')`; `requestRejection(request)` → `401 | 403 | undefined`; `admit(request)` → `{ peer } | { rejection }`; `admitConnection(request)` → `{ peer, release } | { rejection: 401 | 403 | 409 }`; `createPeer({ principal, interactions? })`; `authorizeIndex(request, response): boolean`; `authenticatedUrl(baseUrl)`. A `Peer` (`src/peer.ts`) has `id` (random UUID), `ctx` (own scope), `principal`, `interactions: 'answer' | 'none'`, `signal`, `dispose()`.

**`ctx.fileUploads`** (`packages/client/file-upload/src/index.ts`, Service class, `static inject = ['agents', 'attachments', 'commands', 'connection']`): Remote namespace `fileUploads` with `upload`, plus an exact streaming Fetch route; stages uploaded bytes and returns a receipt id that a prompt cites as `{ type: 'file', receiptId }`.

**`ctx.pluginRegistryProbe`** (`packages/client/ui-plugin-manager/src/index.ts:25`, `TypertRemoteService`): `@Remote fastest(): Promise<string | null>` pings `https://registry.npmjs.org/-/ping` and `https://registry.npmmirror.com/-/ping`, first 2xx wins, cached.

**`ctx.sessionToolResults`** (`packages/client/ui-trajectory/src/index.ts:31`, `TypertRemoteService`, `static inject = ['sessions', 'typert']`, Remote namespace `toolResults`): keeps at most `maxResultsPerSession` successful native tool result values per live Session (listens to `tools/result` and `session/event`), `watch` stream for the Trajectory inspector.

**`ctx.productAnalytics`** (Host, `TypertRemoteService`, `static inject = ['deepseekAccount', 'productTelemetry']`): `report`, `watchPolicy`.

Every other Host half is an empty or near-empty function plugin. Across the area, eight Host halves push page globals or boot rows through `webserver/index-inject` (listed under Events), and eight (`locale`, `ui-theme`, `ui-chat`, `ui-conversation`, `ui-settings`, `ui-settings-general`, `ui-settings-account`, `product-analytics`) declare a `Config` with `.volatile()` fields and call `ctx.settings.configure({ auto: false }, ctx.fiber)`, which makes the row's config a user-settings namespace (see Configuration).

### Browser tree

| Key | Owner | Members (browser) | Lifetime |
|---|---|---|---|
| `modules` | `modules` (`src/client/index.ts:62-69`) | `ClientModuleLoader`: `version: 'client'`, `manifest`, `entries` (`ClientEntries`: `start(loader, manifest)`, `sync(graph)`, `reload(id, rev)`, `state`, `releaseChange`, `dismissRelease()`), `loadCache`, `import(specifier, parentURL, attrs)`, `prefetch(id)`, `importError(id)`, `invalidate(id, rev?)` | Built by the shell before Cordis exists; the plugin only does `ctx.reflect.provide('modules', loader.internal)` |
| `connection` | `connection` (`src/client/index.ts:228`) | `interactions`, `isLoopback`, `generation` and `state` (observables), `rpc.call(channel, endpoint, payload, signal?)`, optional `rpc.open(...)`, `openWebSocket(path)`, `reconnect()`, `registerGenerationSource(source)`, `start(sinks, config?)` → `{ stop }` | One per Context. Exactly one generation source and one loop owner (second `start` throws) |
| `fileUpload` | `file-upload` | `upload(sessionId, body, name, signal, onProgress)`, `uploadImage(sessionId, blob, mediaType, name, signal, onProgress)` | `inject = ['remote']` |
| `locale` | `locale` | `register(namespace, { en, zh, … })`, `bind(namespace)` → `t(key, params?)`, `resolveText({ en, [locale]: … })`, current snapshot; emits `locale/change` | `inject = ['slots', 'remote', 'configForms']` |
| `shortcuts` | `shortcuts` | `register(command)` (per-profile defaults `desktop:macos|windows|linux`, `web:macos|windows|linux`), `registerFixed({ id, label, keys, bindings, group })`, `observeFixedInput()`, observable catalog | `static inject = ['locale']` |
| `resources` | `resources` | `register({ protocol, open(address, { signal }) })` (one provider per protocol; second throws), `pin(address, signal)`, `source(address)`; root standard hook `useResource<P>(address)` | `inject = ['slots']` |
| `slots` | `ui-renderer` (`super(ctx, 'slots')`) | `register(options, Component)`, `registerFactory(options, Component)`, `inject(key, callback)`, `provideRoot(...)`, `renderSlot('root', {})` | Registrations are effects of the calling fiber |
| `uiRenderer` | `ui-renderer` | `mount(container)` → disposer; emits `slots/changed` | `inject = []` |
| `uiSession` | `ui-session` | `provide(descriptor)` (adds standard hooks/props per Session binding), `registerPendingInteraction(precedence)` → `publish(interaction, delegate)` → `remove()`, `bindingSource(reference)`, `whenAccess(sessionId, action, callback)`, `sessionStatus`, `adapter` | `inject = ['sessions', 'slots', 'remote', 'remoteAccess']` |
| `layout` | `ui-layout` | `panelInfo`, `selectPanel(panelId \| null)`, `beginNavigation(): AbortSignal`, `toggleSidebar()`, `openRightbar(track, fullscreen)`, `closeRightbar()` | `inject = ['slots', 'theme', 'locale', 'shortcuts']` |
| `theme` | `ui-theme` | `ThemeSnapshot` observable, alias-token override registration; emits `theme/change` | |
| `contextMenus` | `ui-context-menu` | Register structured menu contributions per typed target (Session, Workspace, file, directory, URL, image, pane, `sessionHeader`); root hook `useContextMenu` | |
| `conversation` | `ui-conversation` (`ConversationController`, Service) | `IConversation`: `input` (`for(actx)`, `requestDraftInitialization(binding, options)`), `blocks` (`set`, `storeFor`, `forget`), `send(text)`, `updateQueue(itemId, action)`, `cancel()`, `loadOlder()`. The four verbs require a Session-scope context (`ctx.sessions.scope(id).conversation`) and throw on the root context (`src/client/service.ts:568-576`) | |
| `uiConversation` | `ui-conversation` (`UiConversation`, Service) | `events.register(definition)`, `events.registerFallback(definition)`, `views.register(viewDefinition)`, `groups.register(groupDefinition)`, `userText.register(rule)`, interaction registry, `binding(sessionBinding)` → `{ snapshot, openTurn, activate(target), target(target) }`, `seedImageUrl(sessionId, ref, url)` | One `BoundConversation` per `SessionBinding` |
| `inputTriggers` | `ui-input-trigger` | `register(source: InputTriggerSource)` (duplicate name per trigger throws); one `InputTriggerController` per Session scope | `static inject = ['sessions']` |
| `commandUi` | `ui-commands` | `register(contribution)`, `decorate(decoration)`, `dismiss(name)`, `popupFor(actx)` | `static inject = ['inputTriggers', 'sessions', 'remote', 'remote.commands']` |
| `modelDirectories` | `ui-model-selection` | Per-Session model catalog cache over `session.modelCatalog` | |
| `configForms` | `ui-settings` | `get(entryId)` → form with `getSnapshot()` (`value`, `base`, `user`, revision, writability), `subscribe`, `set(field, value)`, `unset(field)`, `mutate(ops, revision?)`; `whileServed(namespaces, register)`; `describe()`; `developerTools.enabled` / `.setEnabled()` | `inject = ['remote', 'remote.settings']` |
| `settingsSchema` | `ui-settings` | Serialized Config schemas used for browser-side validation | |
| `sidebarRight` | `ui-sidebar-right` | Navigation controller: open an address as a tab, focus, close; operations only, never layout snapshots | |
| `sidebarRightTabs` | `ui-sidebar-right` | Tab-type registry (id, address patterns, priority) | |
| `documentPreviews` | `ui-sidebar-documentpreview` | Preview renderer registry | |
| `uiWorkspace` | `ui-workspace` | `openSession(target)`, `openWorkspace(id, beforeOpen?, options?)`, `connectWorkspace`, `startSession`, `forkSession(id, onCreated?, options?)`, `whenAccess`, `workspaceDisplayTitle`; root hooks `useWorkspaces`, `useWorkspaceAccess` | |
| `fileActions`, `fileDrag`, `feedbackUi`, `userQuestionPanels`, `chatFileMentions`, `accountUi`, `pluginChanges`, `pluginNavigation` | named packages | Narrow capability objects other plugins read with `ctx.get(...)` | |

Services consumed but owned outside the area: `remote` and `remote.<namespace>` (`dsh-api-remotes`), `sessions` (`ClientSessions`: `list`, `binding(id)`, `scope(id)`, `scopeOf(ctx)`, `retainInfo`, `fork`, `refreshProjections`, `subagentAddress`), `workspaces`, `remoteAccess`, `jobs`, `webTerminals`.

### Plugin model rules an implementation must keep

- A client plugin is a function plugin exporting `inject` and `apply` (plus `Config` where present); no default export. `dsh.client.inject` in `package.json` is informational; activation order is decided only by Cordis service injection (`packages/client/AGENTS.md`, checklist item 3).
- UI crosses packages only through Slots. `ctx.slots.register({ name, id?, key?, order?, priority?, children?, store?, inject?, locale?, select? }, Component)`. A slot is live only while the entry that declared it in `children` is registered; `ctx.slots.inject(name, callback)` waits for the declaration and reruns per declaration lifetime. Slot kinds: `single`, `list`, `keyed`, `chain`, `hoc`. Scopes: `root`, `session-maybe`, `session`. `root` is the only slot the service renders itself (`docs/subsystems/slots.md`).
- Components never receive `ctx`. Their props are derived: owner props, standard hooks (`useSession`, `useSessions`, `useSessionStatus`, `useWorkspaces`, `usePanelInfo`, `useProjection`, `useAccess`, `useConversation`, `useInput`, `inputActions`, `useChat`, `useTrajectory`, `useResource`, `useContextMenu`), `renderSlot`, `useStore`/`actions`, `t`, and the registration's `inject` face.
- Required browser entries (boot fails if one is present in the manifest and inactive, `packages/client/web/src/boot-client.ts:25-33`): `@deepseek-ai/dsh-client-modules`, `@deepseek-ai/dsh-api-session-controller`, `@deepseek-ai/dsh-client-ui-renderer`, `@deepseek-ai/dsh-client-ui-layout`, `@deepseek-ai/dsh-client-ui-session`, `@deepseek-ai/dsh-client-ui-chat`, `@deepseek-ai/dsh-client-ui-sidebar`.

## Events

### Host tree events owned or consumed here

| Event | Mode | Payload | Producer | Consumer |
|---|---|---|---|---|
| `connection/request` | waterfall | `(request: IncomingMessage, response: ServerResponse, next)` | `connection` Host half, once per authenticated `/api` request before body transfer (`src/index.ts:157`) | Desktop install lock; default `next` is the HTTP bridge |
| `webserver/index-inject` | collection event owned by `dsh-host-webserver` (listeners push rows into the table; `ui-theme` registers with `prepend: true`) | `(table: IndexInjection[])` | `dsh-host-webserver` per index render | `modules` (boot rows), `connection` (`__DSH_CONNECTION_RECOVERY__`), `ui-theme` (prepended palette bootstrap), `shortcuts`, `ui-settings-account`, `ui-settings-models`, `ui-sidebar-documentpreview`, `ui-account-notifications` |
| `internal/plugin` | emit | `(fiber)` | Cordis | `modules` marks the fiber's Loader entry name dirty and queues one microtask flush (`src/index.ts:680-690`) |
| `tools/result`, `session/event` | emit | Host events | agent loop, session | `ui-trajectory` Host half; `product-analytics` (`compaction/start` → `context_compression`) |
| `loader/volatile-update` | emit | none | Loader | `product-analytics` policy watchers |

### Browser tree events

| Event | Mode | Payload | Producer | Consumer |
|---|---|---|---|---|
| `connection/reset` | emit | none | API Gateway client when a connection generation is established (declared in `packages/client/connection/src/client/index.ts:21-29`) | 16 listener sites in this area: command, skill, model, settings, plugin, schedule caches drop and repull |
| `internal/status` | emit | `(fiber)` | Cordis | `web` boot page progress (`boot-client.ts:63-67`) |
| `locale/change` | emit | `(snapshot: LocaleSnapshot)` | `locale` | plugins with locale-dependent caches |
| `theme/change` | emit | `(snapshot: ThemeSnapshot)` | `ui-theme` | `ui-layout` presenter, terminal, previews |
| `slots/changed` | emit | `(key: string)` | `ui-renderer` | inspect tooling |
| `command/executed` | emit | `(sessionId, name, result: CommandResult)` | `ui-commands` after a matched Host execution in this browser | plugins that react to their own commands |
| `slash/input-begin-command` | bail | `({ claim: CommandClaim, span: TokenSpan })` → `true \| undefined` | input-trigger pipeline, emitted on the Session scope | `ui-conversation` input hub; `true` means the editor applied it |
| `slash/input-insert-reference` | bail | `({ reference: ReferenceInsert, span })` | same | same |
| `slash/input-consume-token` | bail | `({ guard: { kind: 'span', span } \| { kind: 'bare-token', token } })` | same | same |
| `slash/input-insert-text` | bail | `({ text, span, continue? })` | same | same |
| `account-ui/change` | parallel | `(state: AccountUiState, reset: boolean)` | `ui-settings-account` | account-dependent plugins |
| `account-ui/refresh` | parallel | none → `Promise<void>` | Settings or returned Platform page | `ui-settings-account` |
| `workspace/archive-notice` | waterfall | `(sessionId, next)` → `ArchiveNotice \| undefined` | `ui-workspace` | plugins that add to the archive notice |
| `workspace/archive-followup-failed` / `-settled` | emit | `(sessionId, text)` / `(sessionId)` | plugins | `ui-workspace` notice |

### Host events forwarded to the browser (`ctx.remote.$on`)

The allowlist is owned by `dsh-api-remotes`; these are the names the client packages listen to. Ordinary events arrive on the root client Context. Scoped waterfalls arrive on the Session-scope Context (`this` in the listener) and the listener returns a result, calls `next()`, or rejects.

| Event | Kind | Listener |
|---|---|---|
| `approval/request` | scoped waterfall; request fields used: `toolName`, `callId?`, `reason?`, `displayReason?: { en, [locale] }`, `signal?`; answer `'allowed-once' \| 'rejected'` | `ui-approval` |
| `user-questions/request` | scoped waterfall | `ui-user-questions` |
| `api-session/status` | ordinary | `ui-session` (running status) |
| `settings/document-updated` | ordinary | `ui-settings`, `ui-agent-preset`, `ui-model-selection`, `ui-settings-models`, `ui-settings-subagent` |
| `llm/models-updated`, `llm/adapters-updated`, `credentials/record-updated`, `credentials/reference-updated` | ordinary | model selection, models page, account, web-search page |
| `commands/change`, `agent-preset/selected` | ordinary | `ui-commands`, `ui-skill` (drop one Session's catalog) |
| `plugin-manager/changed`, `plugin-manager/install-state`, `plugin-manager/install-log`, `plugin-manager/update-state`, `plugin-market/changed` | ordinary | plugin pages, `ui-skill` |
| `permission-presets/catalog-changed`, `goal/activation-changed`, `schedule/changed`, `web/providers-changed`, `deepseek-account/session-expired`, `deepseek-account/model-sign-in-required` | ordinary | named feature packages |

Ordering guarantee: forwarded ordinary events are not replayed after a reconnect. Stateful domains take a baseline from a stream's first frame or repull on `connection/reset` (`docs/subsystems/web-client.md`, Reconnection).

### Session events consumed by Conversation Definitions

Session events are not Cordis events in the browser; they reach Definitions as `SessionEventLikeEntry` values (`{ type: 'event', event }` for a durable event, `{ type: 'transient', event }` for the client-only `assistant/live-chunk`). The full mapping is under "Algorithms and invariants → Chat node kinds".

## Tools

None. No package in this area registers a model-facing tool, prompt section or command. The only model-visible effects are indirect: the composer sends `session.prompt`, `/command` lines call `commands.execute`, answers call `userQuestions.answer`, and the empty "Continue generating" prompt records a `user/message` with `source.kind: 'retry'` (`packages/client/ui-conversation/README.md`, "Model Experience").

The area does own how tool calls are drawn. A Racket-served UI needs the same catalog, so it is recorded here.

### Tool card dispatch

`ui-tool` registers the Chat node renderer key `tool-call` (`packages/client/ui-tool/src/client/apply.ts:39`) as `ToolCallTree`. Each call, root or nested, is dispatched by wire tool name through the keyed slot `tool.call.toolview`; an unregistered name uses `GenericToolCard`. Owner props (`ToolCallOwnerProps`): `callId`, `toolName`, `phase` (`'preparing' | 'start' | 'result'`) with the stage-specific `block`, optional `cwd` and `home`, `loadImage`, `openFile`, `inspect`. Every wrapper keeps the DOM attributes `data-chat-anchor-key="call:<id>"` and `data-chat-call-id`. Cards derive only from raw `tool/call` arguments, `tool/result` content and persisted result `meta`; Host `presentCall`/`presentResult` values never reach the browser. Malformed or unsupported input falls back to flattened text.

| Tool name (slot key) | Owner | What the row and expanded card show |
|---|---|---|
| any unregistered name | `ui-tool` `GenericToolCard` | Row `Tool call · <tool name>` plus argument summary (first non-empty `description`, else variant fallback); expanded: arguments and result blocks in order, image attachments as name/ID with dimensions and bytes |
| `bash` (keyed row); `pwsh` and `terminal_send` have no keyed registration and reach the same terminal card model through the generic path (`models/terminal-card-model.ts:201, 274`) | `ui-tool` `bash-sample.tsx` | Streamed `description`; terminal card with command, cwd, ANSI output; exit-code capsule with a red dot for nonzero exit, signal or missing code; background launch shows a command-only card; persistent-shell settled results stay generic |
| `read` | `ui-tool` `read-row.tsx` | Openable path once `file_path` is complete; read card with line-numbered content |
| `read_image` | `ui-tool` `read-image-row.tsx` | Gallery through child slot `tool.call.images`, full recorded path, pixel size (original size when downscaled), byte count |
| `write`, `edit`, `apply_patch` | `ui-tool` `file-mutation-row.tsx` | Edit title; path link; `NKB` size while arguments stream (UTF-16 length rounded up in 1024 units, old plus new for edit); after success, diff card from `meta.diffs` with added/removed counts (nine rows before folding); `apply_patch` lists files parsed from the patch, moves as `source → destination` |
| `grep`, `glob` | `ui-tool` `search-row.tsx` | Search card (pattern, include, matches); exact empty `include` treated as omitted |
| `web_search`, `web_fetch` | `ui-tool` `web-row.tsx` | Web card; collapsed `web_fetch` links its http(s) URL in a new tab |
| `todo_write` | `ui-tool` `todo-row.tsx` | Todo diff against the previous list (uses the `tool-todo-history` view built from `todo/write` events) |
| `ask_user_question` | `ui-tool` `ask-question-row.tsx` | Questions paired with answers by id; button reopens the panel through `userQuestionPanels.reveal(sessionId, callId)`; "View answers" transcript |
| `office_render`, `office_convert`, `office_recalculate` | `ui-tool` `office-row.tsx` | Input path link; expanded shows only text blocks of the result |
| 40 control tools | `ui-tool` `details-row.tsx:95-134` (`DetailsRow`) | Structured receipt rows: `create_goal`, `get_goal`, `update_goal`, `schedule_create`, `schedule_list`, `schedule_view`, `schedule_edit`, `schedule_delete`, `schedule_update`, `cordis_inspect_list`, `cordis_inspect_query`, `cordis_inspect_self`, `workflow`, `ralph`, `session_event_read`, `session_event_search`, `session_event_trace`, `session_search`, `session_trace`, `list_subagent_models`, `subagent`, `subagent_fork`, `list_agents`, `send_message`, `interrupt_agent`, `job_list`, `job_output`, `job_kill`, `terminal_open`, `terminal_read`, `terminal_list`, `terminal_signal`, `terminal_close`, `lsp`, `spawn_teammate`, `team_task_create`, `team_task_get`, `team_task_update`, `team_task_list`, `wait_agent` |
| `skill` | `ui-skill` | Skill glyph, `Skill` title, requested name; expanded "Instructions" card with the exact tool output |
| `present` | `ui-deliverables` (`PresentRow`) | Delivery row for explicitly presented files |
| `cordis_define`, `cordis_run`, `cordis_stop`, `cordis_undefine` | `packages/extensions/ui-cordis` (outside area) | Cordis authoring rows |
| `propose_action` | `packages/experimental/client-ui-action-cards` (outside area) | Action card |

Auto-review denial takes precedence over any keyed view: a generic row that keeps call identity, omits raw arguments and shows the normalized reason (`ui-tool/src/client/tool/models/auto-review-denial.ts`). PTC (`run_code`) children are nested `subCalls` of the root tool node and dispatch through the same keyed slot.

## Configuration

Each row below is a cordis.yml entry of the Host tree. "Function plugin" exports `name`/`inject`/`Config`/`apply`; "Service class" default-exports a class. Where the Host half has no `Config`, the package "accepts no plugin config". Fields marked volatile are user-settings fields: the Host half calls `ctx.settings.configure({ auto: false }, ctx.fiber)`, the browser reads and writes them through `ctx.configForms.get(<row id>)`, and the local provider persists them in `$DSH_HOME/cordis.patch.yml`.

| Package (shipped row id) | Kind, exported name, inject | Config fields |
|---|---|---|
| `connection` (`connection`) | function plugin `client-connection`; `inject = ['credentials']`; optional `webServer`, `attachments` | `recovery` object: `backoffBaseMs` natural 1..2147483647 default 500; `backoffFactor` number ≥ 1, finite, default 2; `backoffMaxMs` default 10000; `generationReadyWarnMs` default 3000; `generationReadyTimeoutMs` default 15000. `trustedHosts: string[]` default `[]` (exact `host:port` or port-less `host`; malformed entry fails load; shipped row sets `!!js ctx.webStartup.trustedHosts`). `cookieMaxAgeDays` natural ≥ 1 default 30. `maxRequestBodyBytes` natural ≥ 1 default 300 MiB; load fails when it is below `ceil(attachments.imageLimits.maxMessageImageBytes * 4 / 3) + 1 MiB` (`src/index.ts:78-91`) |
| `hmr` (`client-hmr`) | function plugin `client-hmr`; `inject = ['clientModules', 'webServer']` | `pollIntervalMs` integer ≥ 1 default 500 |
| `modules` (`modules`) | Service class; `static inject = ['loader']`; optional `webServer` | none |
| `file-upload` (`file-upload`) | Service class `FileUploads`; inject `agents`, `attachments`, `commands`, `connection` | none |
| `shortcuts` (`shortcuts`) | function plugin | `stopSequenceMs` natural 1..2147483646 default 500 (maximum gap of the Esc-Esc stop sequence); pushed to the page as `__DSH_SHORTCUTS_CONFIG__` |
| `locale` (`locale`) | function plugin | `preference` volatile string matching `/^[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*$/`, optional (absent follows the browser) |
| `ui-theme` (`ui-theme`) | function plugin | all volatile: `preference` `'light' \| 'dark' \| 'system'` default `system`; `fontSize` integer 10..22 default 14; `codeFontSize` 10..16 default 11; `terminalFontSize` 10..20 default 13; `textFontFamily`, `codeFontFamily`, `terminalFontFamily` strings default `''` |
| `ui-chat` (`ui-chat`) | function plugin | all volatile: `transcriptView` one of `compact`, `standard`, `detailed`, `verbose`, legacy `normal`, `expanded` (loose; missing or invalid defers to the client default: Desktop `standard`, Web `detailed`); `collapseTiming` `completion` (default) or `next-input`; `foldedReplies` `all` (default) or `final`; `performanceUsage` `compact` or `detailed` (default); `linkOpening` `sidebar` (default) or `new-tab` |
| `ui-conversation` (`ui-conversation`) | function plugin; browser `inject = ['slots', 'sessions', 'fileUpload', 'uiSession', 'uiWorkspace', 'locale', 'configForms']` | Host: `busyEnter` volatile `queue` (default) or `steer`. Browser `Config`: `maxConcurrentFileUploads` natural ≥ 1 default 2 |
| `ui-settings` (`ui-settings`) | function plugin | `enabled` volatile boolean default `true` (the Coding Tools switch) |
| `ui-settings-general` (`ui-settings-general`) | function plugin | `welcomeNoticeVersion` volatile string |
| `ui-settings-account` (`ui-settings-account`) | function plugin | `contactFormUrl`, `contactSource` (pushed as `__DSH_CONTACT_CONFIG__`); volatile onboarding fields `version` (1), `step`, `purpose`, `process`, `completion` (`completed`, `skipped`, `api-key`), `usage` (`compact`, `detailed`), `developerTools` boolean |
| `ui-settings-models` (`ui-settings-models`) | function plugin | `credentialOnboarding` boolean default `true` (pushed as `__DSH_MODELS_ONBOARDING__`) |
| `ui-account-notifications` | function plugin | `notificationPollIntervalMs` natural default 600000 (pushed as `__DSH_ACCOUNT_NOTIFICATIONS_CONFIG__`) |
| `ui-sidebar-documentpreview` | function plugin | `office.maxCachedEntries` 8, `office.maxCachedBytes` 64 MiB, `office.maxPending` 8, `office.maxReaders` 32; `excel.maxBytes` 16 MiB, `excel.maxCells` 250000, `excel.timeoutMs` 15000 (pushed as `__DSH_DOCUMENT_PREVIEW_CONFIG__`) |
| `ui-plugin-manager` (`ui-plugin-manager`) | Service class `PluginRegistryProbe` | `registryProbeEnabled` boolean default `true`; `registryProbeTimeoutMs` natural default 1500; `registryProbeCacheTtlMs` natural default 300000 |
| `ui-trajectory` (`ui-trajectory`) | Service class `SessionToolResults`; inject `sessions`, `typert` | `maxResultsPerSession` natural ≥ 1 default 1000 |
| `product-analytics` (`product-analytics`) | Service class; inject `deepseekAccount`, `productTelemetry` | `enabled` volatile boolean default `true`; `appVersion` string; `environmentQueryTimeoutMillis` default 5000; `environmentQueryMaxOutputBytes` default 16384. Shipped row is `disabled` unless `profileContext.name === 'desktop'` |
| `ui-deliverables` | function plugin; Host inject `connection`, `sessionQuery`, `sessionController`, `workspaceFiles`, `fs`, `sandboxPolicy`, `workspaceChanges` | none |
| all other `ui-*` rows | function plugin, empty Host `apply` | none |

Shipped rows with conditions (`packages/bundle/web-app/cordis.patch.yml`): `ui-sidebar-browser` and `product-analytics` are disabled unless the profile is `desktop`. `webserver` takes `host` (default `127.0.0.1`), `port` (default 3080) and `tls` from the `webStartup` service, which parses `--host`, `--port`, `--public-url`, `--trusted-host` (repeatable), `--no-open` and TLS flags (`packages/bundle/web-app/src/startup.ts`). Wildcard binds are rejected.

### What each settings surface configures

Settings dialog sections (`settings.section` list, ascending `order`): `account` (-10, `ui-settings-account`), `general` (0, `ui-settings-general`), `models` (10, `ui-settings-models`), `plugins` (15, "Built-in plugins", `ui-settings-plugins`), `agent-presets` (20, `ui-agent-preset`).

General rows (`settings.general.item`, ascending `order`):

| Order | id | Owner | Writes |
|---|---|---|---|
| -20 | `permission` | `ui-permission-presets` | Default permission preset for later Sessions (Host dynamic `defaultPreset` enum), one `settings.mutate` |
| 0 | `language` | `locale` | `locale.preference` |
| 10 | `appearance` | `ui-theme` | `ui-theme.preference` |
| 11 | `font-size` | `ui-theme` | `fontSize`, `codeFontSize`, `terminalFontSize`, font families |
| 12 | `transcript-view` | `ui-chat` | Work details `ui-chat.transcriptView`, Collapse work details `collapseTiming`, Replies after collapse `foldedReplies` |
| 15 | `developer-tools` | `ui-settings-general` | Coding Tools `ui-settings.enabled` (hides Trajectory, PTC and Minimal presets, changed-file cards, HTML preview permission) |
| 16 | `shortcuts` | `ui-shortcuts` | Opens the shortcut reference; overrides are device-local, not settings |
| 17 | `link-opening` | `ui-chat` | `ui-chat.linkOpening` |
| 20 | `composer-enter` | `ui-conversation` | `ui-conversation.busyEnter` |
| 30 | `performance-usage` | `ui-chat` | `ui-chat.performanceUsage` |
| 90 | session-log namespace id | `ui-settings-session-log` | field `enabled` (upload Session log with official API requests); shown only while the Host serves the namespace |
| 95 | `desktop-update-channel` | `ui-settings-general` | Desktop only, Electron preload |
| 100 | `current-version` | `ui-settings-general` | read-only `DSH_CLIENT_VERSION` |

Models section: provider rows, API keys (write-only, through `credentials.set`/`unset`), per-provider model lists, custom OpenAI-compatible routes, model discovery (`llm.discoverModels`). Account section: DeepSeek sign-in (`account.startSignIn`, `cancelSignIn`, `signOut`, `getProfile`, `getBalance`, `watch`). Agent presets section: built-in and custom preset cards, default preset (`agentPresets.select`, `settings.update`), read-only YAML viewer (`agentPresets.read`), Creator entry. Built-in plugins section: tab row `settings.plugins.tab`; shipped tab `all` ("Plugin list", read-only Loader inventory plus per-preset rosters and page-local sync failures with retry).

Sidebar Plugins page, "Built-in plugin settings" (`plugins.item` list, registered only while the Host serves the namespace, through `configForms.whileServed`): Subagent (namespaces `subagent`, `subagent-model-selection-settings`: recursion depth, parallel capacity, models agents may pick), Web search and fetch (`web`, `web-deepseek-api`, `web-search-deepseek`: Search and Fetch providers, result count, billing choice, legacy key field `legacyApiKey`), Agent loop (order 30, `agent-loop`: parallel tool-call cap), Shell (order 40, `bash-sandbox` or `pwsh-sandbox`: command timeout, per-stream output cap). Bundles add their own detail configuration through the keyed slot `plugins.bundle.config` (key = npm package name).

## Formats

### `dsh.client` package declaration

`package.json` → `"dsh": { "client": { "platform": "web", "inject"?: string[], "external"?: string[], "immediately"?: boolean } }`, and `exports["./client"]` as a string or `{ default: string }` (`packages/client/modules/src/client/manifest.ts:173-193`, `src/index.ts:204-214`). `platform` must be a string. `external` lists exact non-baseline module specifiers; a trailing `/client` aliases the package row.

### Boot graph `window.__DSH_BOOT__`

```
WebBootGraph  { rev: string, release?: { version: string, commit?: string }, entries: WebBootEntry[], batches: WebBootBatch[] }
WebBootEntry  { id: string /* package name */, url: string, rev: string, inject?: string[], immediately?: true, external?: string[] }
WebBootBatch  { phase: 'bootstrap' | 'application', url: string, rev: string, entries: string[] }
```

Parser rules (`parseBootManifest`, `manifest.ts:229-322`): `rev` string; `entries` and `batches` arrays; entry ids unique; batch URLs unique; batch `entries` non-empty and naming known ids; every entry in exactly one batch. Any violation throws and the page does not boot. `release` is the modules package version plus `process.env.DSH_CLIENT_COMMIT_HASH` when set.

Revisions: entry `rev` = first 12 hex of SHA-1 over the framed fields `'plugin-artifact'`, `mtimeMs`, `ctimeMs`, `size` of `lib/client.js` (`src/index.ts:222-231`; framing is `domain` + NUL, then `<byteLength>:` + part for each part). Combo `rev` = same framed hash with domain `'combo'` over `[id, rev]` pairs in order.

### `/plugins` routes (GET and HEAD only; other methods 405; unknown or stale 404)

| URL | Body |
|---|---|
| `/plugins/??<pkgA>/client.js,<pkgB>/client.js&rev=<rev>` | Concatenated bundles, each followed by `;\n`, with one trailing `//# sourceMappingURL=??<pkgA>/client.js.map,…&rev=<rev>`; built on first GET; `cache-control: public, max-age=31536000, immutable` |
| same with `.map` | Indexed Source Map v3 `{ version: 3, file: 'client.js', sections: [{ offset: { line, column: 0 }, map }] }` |
| `/plugins/<pkg>/client.<name>.js?rev=<rev>` | One package-local chunk (name must match `/^client\.[A-Za-z0-9][A-Za-z0-9._-]*\.js$/`) |
| `/plugins/<pkg>/assets/<path>` | Package image (`.svg`, `.png`, `.webp`, `.jpg`, `.jpeg`), streamed, `etag: "<requested path>"`, `x-content-type-options: nosniff`, SVG adds `content-security-policy: script-src 'none'`; `If-None-Match` → 304 |
| `/plugins/events` | SSE (`client-hmr`): first line `: connected`, then `data: {"type":"graph","graph":<WebBootGraph>}` on connect and on every graph change, and `data: {"type":"rebuilt","id":"<pkg>","rev":"<rev>"}` |

Browser-facing references are document-relative (leading slash stripped, for example `plugins/??…`). A combo URL in map form may not exceed 3 KiB UTF-8 (`MAX_COMBO_URL_BYTES`); rows are greedily partitioned in graph order.

### Index injection rows

`IndexInjection` kinds interpreted by `applyIndexInjections` (`packages/client/web/src/apply-injections.ts`): `{ kind: 'global', name, value }`, `{ kind: 'script', placement: 'head' | 'body', text }`, `{ kind: 'script-src', placement, src }`, `{ kind: 'script-preload', src }`, `{ kind: 'style', text }`, `{ kind: 'html', placement, html }`. Boot rows in order (`bootInjections`, `modules/src/index.ts:602-637`): inline `window.__ModuleLoader__` queue facade; one `script-preload` per application batch; one head `script-src` per bootstrap batch; `global __DSH_BOOT__`. In a served page `<` in the global is escaped.

`window.__ModuleLoader__` facade: `{ mode: 'queue' | 'live', pendingQueue, load(registration), create(options) }`. A bundle is `window.__ModuleLoader__.load({ id, chunk?, factory })` where `factory(require)` returns the exports; `require(specifier)`, `require.async('./client.<name>.js')`, `require.asset('plugins/<package>/assets/<path>')`. `create({ boot, staticModules, loadBundle?, resolveAsset? })` removes the modules bundle from the queue, runs its factory with a throwing `require`, checks that it exports `createClientModuleSystem` and `apply`, and returns the system.

Other page globals: `__DSH_BOOT_READY__` (`{ promise }`, awaited before boot), `__DSH_TRANSPORT__` (`ClientTransportHooks`: `rpc?`, `fetch?`, `openStream?`, `loadBundle?`, `resolveAsset?`, `ownsHost?`, `createWebSocket?`, `streamBaseUrl?`), `__DSH_CONNECTION_RECOVERY__`, `__DSH_SHORTCUTS_CONFIG__`, `__DSH_DOCUMENT_PREVIEW_CONFIG__`, `__DSH_ACCOUNT_NOTIFICATIONS_CONFIG__`, `__DSH_MODELS_ONBOARDING__`, `__DSH_CONTACT_CONFIG__`, `__DSH_LOCALE__`, `__DSH_HOST_PATHS__` (Desktop: `pathFor(file)`), `__DSH_DIRECTORY_PICKER__`, `__DSH_FILE_UPLOAD__`, `__DSH_PDFJS_ASSETS__`. Desktop boot uses `globalThis.dshDesktopBoot` with `ready()` → `{ injections, streamBaseUrl }` and `failed(message)` (`apps/web/src/main.ts`).

### Unary RPC over HTTP

`POST api/<endpoint>` (document-relative; endpoint segments match `/^[A-Za-z0-9_$.-]+$/`, channel `/^\/[A-Za-z0-9._~-]+$/`), `content-type: application/json`:

```
request  { "type": "client-request", "rpcId": "<uuid minted by the caller>", "method": "<endpoint>", "payload": <any> }
response { "type": "server-response", "rpcId": "<echo>", "result": { "ok": true, "value": <any> } | { "ok": false, "error": { "code": string, "message": string, "details": object } } }
```

The caller throws on a non-2xx status, on a malformed envelope and on an `rpcId` mismatch (`packages/client/connection/src/client/rpc.ts:33-82`). A transport failure is mapped by helpers to `{ ok: false, error: { code: 'gateway/internal', message, details: {} } }`. Binary results use `multipart/form-data`: part `metadata` is the JSON envelope with `null` placeholders plus `attachments: [{ path: (string | number)[], codec: 'bytes', part: string }]`; each named part is a Blob restored as `Uint8Array` at `result.value` + `path`. Unknown or duplicate parts, a non-null placeholder or a bad path reject the response (`rpc.ts:83-139`). Binary parameters and streamed binary results are not supported. HTTP status before dispatch: 403 for a failed Host/Origin check, 401 for a missing or invalid cookie, 413 for an oversized buffered body, 404 for an unclaimed route.

Streams: API Gateway owns one WebSocket at `api/remote.mux` (resolved against `document.baseURI`, `ws:`/`wss:`), carrying logical Remote streams. The internal `$events` stream is the generation source; its first item is `{ type: 'ready', clientId, host: { home } }`. The mux framing belongs to `packages/api/gateway` (outside this area).

### Browser authentication

- Launch token: random per process, added as `?token=<token>` to the printed URL. `GET /?token=…` with exactly one token and a matching value sets the cookie and redirects (303) to `./`; any other tokenized request gets 401.
- Cookie name: `dsh-auth-` + base64url(SHA-256(audience)). Audience is `host[:port]` for HTTP and the origin (`https://host[:port]`) for TLS listeners.
- Cookie value: `v<version>.<base64url(JSON payload)>.<base64url(HMAC-SHA256(secret, body))>`. Browser payload `{ version: 1, authority, issuedAt, expiresAt }`; API payload `{ version: 2, authority, id: <PeerId>, issuedAt, expiresAt }` (`packages/client/connection/src/browser-auth.ts:29-39, 146-149`).
- Attributes: `Max-Age=<seconds>; Path=/; Expires=<UTC>; HttpOnly; SameSite=Strict` plus `; Secure` only when the receiving listener serves TLS.
- Secret: 32 random bytes, stored base64url as credential record key (`client-connection`, `browser-session`), `kind: 'grant'`, payload `{ version: 1, secret }`.
- API clients: `GET /connect?token=…&interactions=answer|none` (default `none`; repeated or invalid → 400 with `interactions must be declared once as answer or none`) → 302 with `location: ./api/remote.mux`, `cache-control: no-store`, `referrer-policy: no-referrer`, and the v2 cookie.

### Browser storage keys

`localStorage`: `dsh.workspace.view.v5` (grouping, expansion, order mode, Session order), `dsh.sessions.current`, `dsh.conversation` (per-Session draft and View preference), `dsh.conversation.contentWidth`, `dsh.sidebar-right.v1`, `dsh.sidebar-browser.v1`, `dsh.sidebar-files.workspace-search.v1`, `dsh.user-questions.drafts.v1`, `dsh.keybindings.v1` (Web shortcut overrides; `null` clears a binding; missing inherits), `dsh.plugin-manager.install-registry`, `dsh.open-in-app.choice`, `dsh.schedule.recent-time-zones.v1`, `dsh.schedule.task-tab.v1.<id>`, `dsh.trajectory.duration`, `dsh.trajectory.jsonStringWrapping`. Panel pins (left sidebar, View tabs, guide cards) are in memory only.

### Addresses

Resource addresses: `dsh-resource://file/session/<sessionId>/<path>`, `dsh-resource://file/absolute/<path>`, `dsh-resource://subagentchat/session/<childId>?parent=<parentId>&mode=continuable`, `dsh-resource://plan/**`, `dsh-resource://plan-review/**`, `dsh-resource://changes-review/…`. Navigation-only addresses (not resources): `sidebar://guide`, `sidebar://files`, `sidebar://terminal`, `sidebar://schedule`, `sidebar://browser`. Reference text in drafts: `@path`, `@"path with spaces"`, `@dir/`, `@[label](dsh-session:…)`.

### Build-time and run-time environment

`DSH_CLIENT_VERSION`, `DSH_CLIENT_COMMIT_HASH` (7 characters shown), `DSH_CLIENT_GIT_DIRTY`, `DSH_CLIENT_TITLE` (default document title `DSH Local Build`), any `process.env.DSH_CLIENT_*` read statically by client code. Tests: `DSH_SNAPSHOT=replay|refresh|record`. `apps/web/index.html` provides `<div id="root">`, the PWA manifest link and light/dark favicons; Vite `base: './'` so the app works under any mount.

### Plugin market index

`format: 1` JSON, at most 128 MiB by default, fetched without redirects; `LocalizedText` is a string or an object keyed by lowercase language ids that must contain `en`. The complete field reference is `docs/user/guide/plugin-market.md` ("Index format reference"); validation is Host-side (`packages/boot/plugin-market`, outside this area).

## Algorithms and invariants

### Browser boot sequence (`packages/client/web/src/boot.ts:51-108`, `boot-client.ts:57-78`)

1. `new AppWebEntry(#root)` draws the boot page immediately.
2. `run()` awaits `globalThis.__DSH_BOOT_READY__?.promise`.
3. Requires `window.__ModuleLoader__`; calls `create({ boot: window.__DSH_BOOT__, staticModules, …transport seams })`. Static table keys (`platform.ts:8-14`): `react`, `react/jsx-runtime`, `react-dom`, `react-dom/client`, `@deepseek-ai/cordis`, `zod`, `@tanstack/react-virtual`, `@deepseek-ai/dsh-client-store`, `@deepseek-ai/dsh-client-ui-slots`, `@deepseek-ai/dsh-client-ui-primitives`, `@deepseek-ai/dsh-client-ui-dockkit`.
4. Starts `prefetch(id)` for every row with `immediately`, ignoring prefetch failures; creates `new Context()`; sets the boot page total; awaits the prefetches.
5. `bootClient`: `await ctx.plugin(Loader)`; `loader.internal = modules`; subscribe `internal/status` to project entry states; mark every row `loading`; `modules.entries.start(loader, manifest)` creates one Loader entry per row (entry name = package name); entries without a fiber are marked `failed`; `await loader.await()`.
6. Audit (`assertEntriesActive`, `boot-client.ts:96-134`): for each Loader entry, no fiber → `import failed: <recorded message>` (or `import failed (see console for the import error)`); `pending` → `pending (waiting for service(s): a, b)` computed from `Object.keys(fiber.inject)` whose `ctx.get` is undefined; `failed` → `failed: <error>`. If any required entry is in the list, throw `web boot: <n> required entry|entries did not activate\n<name>[ (required)]: <reason>…`; otherwise one `console.warn` `web boot: warning: <n> entry|entries did not activate\n…`.
7. Install the window-drag watcher, then `mountClient`: `ctx.inject(['uiRenderer'], scope => scope.effect(() => scope.uiRenderer.mount(container)))`, so replacing the renderer remounts the app.
8. Any thrown error: `console.error`, then the carrier's `onFailure` or the boot page's failure list ("Failed to load plugins" plus failed ids and the message). Boot page progress arc angle is `round(72 + activeRatio * 216)` degrees.

### Module table (`packages/client/modules/src/client/system.ts`)

- Executing a bundle only registers a factory. Materialization (`factory(require)`) happens on first import and is memoized in `loadCache`. A require cycle throws; factory-form CommonJS cannot hand out partial exports.
- Resolution order for `import`: static seed → memoized record → graph row (load declared dependencies, then its own script) → registered factory → throw. `<id>/client` and the bare id are the same module.
- Batch failure handling: a combo script that fails to load is requested once more; a combo that loaded but did not register a row is never re-executed; each still-missing row then loads its own one-resource URL. Worst case three requests per missing row.
- Styles injected during materialization are tagged `data-plugin=<id>` so disabling a plugin can remove them after its fiber's asynchronous cleanup settles.
- Host graph order: `orderByModuleGraph` (`src/index.ts:551-583`) is a depth-first topological sort over `external` edges with scan order as the tie-break; a self-request or a cycle throws with the path.
- Live composition: `ClientEntries.sync(graph)` serializes full-graph updates in one promise queue; new rows load through single-resource URLs; removed rows are disposed (`tearDownEntryFiber` deletes the runtime from the registry, awaits `fiber.inertia`, then deletes `entry.fiber`), then unused modules and styles are pruned. A local generation counter drops stale downloads.
- Release gate (`release-change.ts`): the page applies graphs and rebuilt frames only while the Host's `release` equals the boot release (both `version` and `commit`). Otherwise it publishes `releaseChange = { page, previous, host }` and logs one warning; `dismissRelease()` silences that Host release until a different one appears.
- Host reconciliation is incremental by Loader entry name; a microtask flush enumerates all entries once. Unchanged manifest and stat triple publish nothing and read no bytes.

### Connection generations (`packages/client/connection/src/client/connection.ts:77-275`)

- State values: `connected`, `disconnected`, `connecting`; emission is deduplicated.
- One generation = one invocation of the registered source `(signal, ready) => Promise<void>`. `connected` and `onConnected(host)` fire only after `ready(host)`; `ready` after abort or from an older generation is ignored.
- Readiness wait: warn at `generationReadyWarnMs`; at `generationReadyTimeoutMs` reject and abort the generation.
- When the source promise settles (either way) the generation is over; the loop waits for that settlement before starting the next attempt.
- Retry delay for attempt `n ≥ 1`: `cap = min(backoffMaxMs, backoffBaseMs * backoffFactor^(n-1))`, delay uniform in `[cap/2, cap]`. With defaults the caps are 500, 1000, 2000, 4000, 8000, 10000 ms. `attempt` resets to 0 on `connected`.
- Before each retry attempt the loop calls `onReconnectRequested` (Gateway replaces the physical WebSocket once).
- `reconnect()`: attempt = 0, publish `connecting`, abort the current generation or the pending delay, next attempt starts with no delay.
- `window` `offline`: abort, publish `disconnected`, suspend until `online`; `online` resets the sequence and starts at the first tier. Initial `navigator.onLine` is adopted at loop start.
- `interactions` defaults to `answer` when a page `location` exists and `none` otherwise. `isLoopback` is true when the transport declares `ownsHost`, when there is no location, or when the hostname is `localhost`, `[::1]` or in `127.0.0.0/8`.

### Conversation assembly (`packages/client/ui-conversation/src/client/conversation/assembler.ts`, `assembly.ts:112-186`)

- Input is the Session's event window `{ entries, revision, hasMore, change }`. `change.kind` is `replace`, `prepend`, `append` or `settle-assistant`. A revision that is not exactly previous + 1, or a `replace`, rebuilds from the whole window.
- A Definition has `kind`, optional `target`, `match(event)` → `{ id, role: 'start' | 'update', exclusive? } | null`, `start`, `update`, optional `publication`, `buildLocationData`, `buildViewNode`. Context key is `` `${kind.length}:${kind}${id}` ``.
- The earliest loaded start match initializes State; every later match (including another start) calls `update` in ascending `seq`. Update-only evidence stays pending with no State until an older page supplies the start.
- `exclusive: true` claims an event for the Definition's target: other Definitions of that target and the target fallback do not get it. Two claims on one target throw.
- `reader.previous(kind)` in `start` returns the nearest started Context of that kind before the current start `seq`; the assembler records the dependency and reruns the dependent Context when a prepend changes the predecessor.
- Publication: per append the strongest request wins (`immediate` over `animation-frame` over `none`). `animation-frame` waits three nested `requestAnimationFrame` callbacks and coalesces; `immediate` cancels a pending frame and flushes at once.
- An incremental failure rebuilds every Context from the loaded window, replaces every active View and throws `ConversationUpdateError` with `rebuilt: true`.
- Targets are activated lazily and never deactivated. View choice: persisted registered View, else `chat`, else nothing. Shell phase: `active` when any target is active, or the Session is not blank and not awaiting its first turn, or it is running; else `engaging` when a prompt was attempted; else `blank` (`contract/snapshot.ts:26-34`).
- Locations: Turn and Step boundaries come from `turn/start`, `turn/end`, `step/start`, `step/end`; status `open`, `closed` or `unknown`.

### Chat node kinds (`packages/client/ui-chat/src/client/conversation-nodes/`)

Registration order is `register.ts:22-38`. Renderer keys are registered in `chat/register-node-renderers.ts`.

| Definition `kind` | Session events (role, id) | Chat renderer key and `groupTree` |
|---|---|---|
| `inbox-next-step`, `inbox-next-turn` (state only, publication `none`) | `agent/inbox/spliced` with `data.target` (start, `seq`). Folds splices `{ start, removedCount?, inserted: [{ id, source: { kind } }], outcome?: 'canceled' }`; a removal that is not canceled is a claim: records claimed ids, `claimSeq`, `firstClaimedHuman` (`inbox.ts:84-118`) | none |
| `input-message` | `user/message` that is an append-surface event and not a compaction checkpoint replacement (start, `data.id`) | `user` (human, not in the current next-step claim); `steering` (human in the current next-step claim; `batchStart` when first human of the claim after process evidence); `turn-trigger` (non-human in the current next-turn claim, or idle steer in Step 1, or `source.kind: 'retry'` with empty content); `context` (other non-human). `groupTree`: `exchange` for human input in Step 1, `input` for other human input and triggers, absent for context (`message.ts:82-160`) |
| `developer-message` | `developer/message` (start, `data.message.id`) | `context` |
| `system-message` | `system/message` (start, `seq`) | `system-prompt` |
| `request-prompt` | `request/header` (start, `seq`); compares with the previous request prompt | `system-prompt` with `{ text, update? }` |
| `assistant-step` | `step/start` (start, `turn:step`); `assistant/live-chunk` transient, `assistant/message` with `surfaceOp === 'append'`, `llm/retry` (update). Chunks handled: `block-start`, `text-delta`, `reasoning-delta`, `tool-call-delta`, `block-end`, `usage`. `llm/retry` resets blocks but keeps `firstTokenTime`. Publication: `none` for `step/start`, `usage`, `finish`; `animation-frame` for other chunks; `immediate` otherwise (`assistant.ts:304-371`) | `assistant-step` with `status` `running`, `settled` or `interrupted`; reasoning rows join the step run, reply rows stand outside. Also Step data key `assistant-step` |
| `process-evidence` (state only) | first visible assistant chunk or message, `tool/call`, appended `tool/result`, `llm/retry` (start, `turn:step`) | none |
| `turn-process` | `turn/start` (start, `turn`); `assistant/live-chunk`, `assistant/message`, `tool/call`, `tool/result`, `llm/retry`, `step/start`, `step/end`, `turn/end` (update) | `turn-process` (`turn`): whole-Turn control with duration or status; Turn data key `turn-process` |
| `tool-call` | `assistant/live-chunk` with `tool-call-delta` (id `chunk.id`) or `block-end` of a `tool-call` block (id `block.id`), and `tool/call` (id `callId`): all start candidates; appended `tool/result` (update, `message.source.callId`); `tool/ptc-dispatch-start` and `tool/ptc-dispatch` (update, `rootCallId`) | `tool-call`. Root block phases `preparing` → `start` → `tool-result`; nested PTC children under `subCalls`; depth and cycle guarded (`tool.ts:173-222`) |
| `command` | `command/run` (start, `commandId`); `command/done` (update); checkpoint replacement `user/message` and `compaction/start|summary|end` carrying `sourceCommandId` (update) | `command` (child keyed slot `conversation.chat.commandview`) or `manual-compaction` when a compaction is correlated |
| `compaction` | `compaction/start` (start, `compactionId`), `compaction/summary`, `compaction/end`, checkpoint replacement `user/message` (update) | `compaction` marker at the checkpoint position with summary, shadowed item and token counts |
| `model-retry` | `llm/retry` (id `retryId`; start when `data.retry === 1`, else update); `llm/retry-started` (update) | `model-retry` (`process`): one row per retry chain; `retryState` `scheduled`, `started` or `cancelled` |
| `turn-error` | `turn/start` (start, `turn`); `turn/end` whose reason is `error`, `aborted` by hook `deepseek-account/signed-out` (code `ACCOUNT_SIGNED_OUT`) or `interrupted` (code `INTERRUPTED`) (update) | `turn-error` (`turn`) |
| `turn-max-tokens` | `turn/end` with `reason.kind === 'max-tokens'` (start, `turn`) | `turn-max-tokens` (`turn`) |
| `turn-tail` | `turn/start` (start); `turn/end`, `tool/call`, `tool/result`, `assistant/message`, `assistant/attempt`, `assistant/live-chunk`, `step/start`, `step/end`, `llm/retry`, `llm/retry-started` (update). Publishes only on `turn/end` | `turn-tail` (`turn`): actions row, token usage, child lists `conversation.chat.turnTail` and `conversation.chat.assistant-actions`; Turn data key `turn-tail` |
| `unknown-surface` (target fallback) | any append-surface event no Chat Definition matched, except `assistant/live-chunk` (start, `seq`) | `unknown`: raw `type` and `data` |
| `goal-command-input` (`ui-goal`) | `command/run` with `data.name === 'goal'` (start, `commandId`) | `command-input` bubble |
| `workflow-run` (`ui-workflow-run`) | `tool-workflow/run-start` (start, `runId`); `tool-workflow/agent-start`, `tool-workflow/agent-end`, `tool-workflow/run-end` (update) | `workflow-run` |
| `answered-user-question` (`ui-user-questions`) | `tool/call` named `ask_user_question` (start, `callId`); `tool/ptc-dispatch-start` (start, `subCallId`); `tool/ptc-dispatch`, appended `tool/result` (update) | `question-reply` bubble after the answer is recorded |
| `user-question-reply` (`ui-user-questions`) | `user/message` whose `source.kind === 'user-question-reply'` (start, `data.id`, `exclusive: true`) | `question-reply`; `groupTree` `exchange` in Step 1, else `input` |
| `submitted-plan` (`ui-plan`) | `tool/call`, `tool/ptc-dispatch-start` (start) and `tool/ptc-dispatch` (update) named `exit_plan_mode` | node is `hidden`; its data feeds the plan card in the turn tail |
| `deliverables` (`ui-deliverables`, no node) | `turn/start` (start, `turn`); `tool/call`, `deliverables/presented`, `workspace/changes`, appended `tool/result` (update) | Turn data read by the changed-files and delivery cards in `conversation.chat.turnTail` |
| `schedule-created` (`ui-schedule`, no node) | `turn/start` (start); `tool/call`, appended `tool/result` (update) | Turn data for schedule cards |
| `tool-todo-write`, `tool-todo-call` (`ui-tool`, target `tool-todo-history`) | `todo/write` (start, `seq`); `tool/call` or `tool/ptc-dispatch-start` named `todo_write` (start) | separate View target used by the todo row |

Synthetic ordering offsets added to a neighbouring event `seq` (`common.ts:15-21`): interrupted Assistant −0.9, interrupted follow-up −0.8, process control −0.1, max-tokens notice +0.05, finalized follow-up (turn tail) +0.1.

Interruption projection: when the owning Step or Turn is closed and a call has no result, the tool node becomes a `tool-result` with `isError: true`, `error: { name: 'Interrupted', code: 'interrupted' }`, at `end.seq − 0.8`; a call still `preparing` is hidden. An Assistant with visible streamed blocks and no `assistant/message` becomes an `interrupted` node at `end.seq − 0.9`.

Process grouping, folding, titles, counts and live detail: `packages/client/ui-chat/src/client/conversation-nodes/README.md` is the normative text. The load-bearing rules: groups collect adjacent process content in one Turn; a reply, a node at `process` or outer, or a node of another Turn ends a group; the same grouping is used by all four display modes; whole-Turn folding applies only to closed, not failed, not stopped Turns without an input after the first process evidence; Verbose never folds. Tool-name categories, first match wins: `read`; `read_image`; `grep`, `glob`, suffix `_inspect` → search; `write`; `edit`, `apply_patch`; `bash`, `pwsh`, `exec_command`, `write_stdin`, prefix `terminal_` → commands; `run_code`, `cua_run_code` → code; `web_search`; `web_fetch`; `subagent`, prefix `subagent_`; `todo_write`, `create_goal`, `update_goal`, `get_goal` → plan; `ask_user_question`, `request_user_input` → questions; everything else → tools. Live detail takes the first non-empty argument among `title`, `description`, `objective`, `task`, `task_name`, `name`, `question`, `questions`, `prompt`, `message`, `command`, `cmd`, `queries`, `query`, `pattern`, `url`, `uri`, `file_path`, `path`, `target`, `action`, `status`, whitespace-collapsed and cut to 160 grapheme clusters with a final `…`. Running titles stay at least 150 ms.

### Composer submit machine (`packages/client/ui-conversation/src/client/input/machine.ts`)

Phases: `plain`, `claimed`, `adjudicating`, `submitting`, `sending`. Editor and attachments are read-only in the last three.

| Event | From | Effect |
|---|---|---|
| `draft-changed` / `claim` | `plain`, `claimed` | The claim follows the leading command chip; busy phases ignore it |
| `enter` | `claimed` | new attempt → `submitting`, effect `begin-submit` with `args` = draft after the claim token |
| `enter` | `plain`, draft blank and no attachments and not `allowEmpty` | nothing |
| `enter` | `plain`, trimmed draft starts with `/` | → `adjudicating`, effect `adjudicate` |
| `enter` | `plain`, otherwise | → `sending`, effect `default-sink` |
| `adjudicated` with a claim | `adjudicating` | → `submitting`, `begin-submit` |
| `adjudicated` with `undefined` | `adjudicating` | → `sending` (ordinary message) |
| `adjudicated` with `'handled'`, text or insert | `adjudicating` | → `plain`, attempt dropped |
| `adjudication-failed` | `adjudicating` | → `plain`, error notice |
| `submit-settled` ok | `submitting` | → `plain`, `commit-draft` keeping a pure suffix typed since the snapshot, optional notice |
| `submit-settled` not ok | `submitting` | back to `claimed` or `plain` following the chip, error notice |
| `sink-settled` ok | `sending` | → `plain`, `commit-draft` clearing unconditionally |
| `sink-settled` not ok | `sending` | → `plain`, draft unchanged, error notice |
| `release` | any | abort the in-flight attempt, → `plain` |

Stale settlements (attempt `seq` mismatch) are ignored. Only one attempt is in flight.

Delivery mode (`submission-policy.ts:30-40`): not running or steering unavailable → `queue`; plain Enter and the Send button → the `busyEnter` preference; Ctrl+Enter or Cmd+Enter → the other mode. Shift+Enter inserts a line break. Enter with Alt, AltGraph, both Ctrl and Cmd, or Shift plus Ctrl/Cmd does nothing in the composer.

Prompt serialization (`input/prompt.ts`): reference chips are replaced by their source codec's `serialize(ref)` (failure blocks the send); quotes become Markdown blockquotes separated from neighbouring text by exactly one blank line; leading and trailing whitespace is trimmed. Attachments: images `image/png`, `image/jpeg`, `image/webp`, `image/gif` are sent as `{ type: 'image', mediaType, data: <base64>, name? }` or uploaded; other files upload first and are cited as `{ type: 'file', receiptId }`. Attachment-carrying command lines are refused unless the Host command declares `input.attachments`.

Stop: the Stop button, or two independent Escape presses within `stopSequenceMs` (500 ms) in the focused Chat or composer, call the scoped cancel and keep the queue.

"Continue generating": an empty idle composer offers it after the latest turn ended with `RATE_LIMIT`, `SERVER`, `TIMEOUT`, `TRANSPORT`, `EMPTY_RESPONSE` or `STREAM_CLOSED`; it submits `content: []`.

### Trigger detection (`packages/client/ui-input-trigger/src/core/detect.ts:20-73`)

- Guard tiers from the input phase: `plain` (both triggers live), `claimed` (`/` suppressed, `@` live), `frozen` (none).
- `@` uses the shared file-reference grammar `activeAtToken(draft, caret)` (supports an open quoted token that spans whitespace).
- `/`: scan left from the caret to the first whitespace; a `/` opens a token at start of draft, after whitespace, or after punctuation. It does not open after a word character (`[\p{L}\p{N}_]`), after another `/`, or after a `:` that itself follows a non-whitespace character (URL scheme).
- `position` is `leading` when the token is the first non-whitespace of the draft, else `inline`. `span = { start, end: caret, draftRev }`; every application of a pick compares `draftRev` (compare-and-swap) so a stale pick cannot edit a changed draft.
- Menu reducer (`core/menu.ts`): one group per source, `pending` or `ready`; a monotonic generation drops stale settlements; a failed source is removed silently; empty ready groups close the menu. Keys: Up/Down move, Enter and Tab pick the highlight (Tab on a `drill` candidate drills), Escape and Shift+Tab close without changing the draft. A dismissed menu stays dismissed for the same token and query.
- Adjudication: Space polls `matchSpace` synchronously, Enter polls `matchEnter` (may await the source's warm-up); first non-undefined answer in registration order wins. Outcomes (`PickOutcome`): `{ claim }`, `{ insert }`, `{ text, continue? }`, `'handled'`, `undefined`.
- Slash menu sections (`ui-commands/src/client/presentation.ts`): Add = `file`, `goal`, `plan`, `feedback`; Commands = `compact`, `permission`, `model`, `export`, then unlisted rows. A non-empty query fuzzy-matches ordered case-insensitive subsequences of names and titles, prefixes first, without section headings. A client contribution whose name collides with a Host command fails loudly.

### Approvals and questions

- `approval/request` (`packages/client/ui-approval/src/client/index.ts:38-70, 79-110`): the listener finds the Session id of the scope it was called on (`ctx.sessions.scopeOf(this)`); no Session → `next()`. It creates a `PendingApproval` (key `approval:<n>`), publishes it as the Session's pending interaction, and awaits `pending.result`. Outcomes are `'allowed-once'` or `'rejected'`; the request `signal` aborts it. Delegation (another presenter takes over, or the plugin unloads) calls `next()`.
- The composer is the chain slot `conversation.composer`: entries `select(owner)` on `pendingInteraction`; election by ascending `priority`: read-only subagent −10, CUA application approval −1, user questions (no explicit priority), tool approval 1; no match renders the normal input bar. One pending interaction is shown per Session; across domains the larger precedence wins and a later equal one replaces an earlier one (`ui-session/src/client/index.ts:413, 489-497`): approvals 0, questions 1, plan review 2.
- Keys: Enter in the approval detail region allows (once for a tool, current session for CUA); Escape rejects; "Always allow" must be activated explicitly. Fixed shortcut rows `approval.allow` (Enter) and `approval.reject` (Esc).
- Sidebar row labels while pending: Approval, Plan review, Answer.
- Questions: timed requests open `userQuestions.attachWait(sessionId, callId)` and count down locally; at zero the client rejects with `ASK_TIMED_OUT`; closing an unnamed request rejects with `ASK_CANCELLED`; late answers use `userQuestions.answer`; a second answer while one is queued reports `REPLY_QUEUED`. Plan review (`intent.kind === 'plan-review'`, set for `exit_plan_mode`) shows Approve and Request changes; Request changes rejects with `ASK_CANCELLED`.

### Sessions sidebar model (`packages/client/ui-workspace`)

- A Workspace shows its first non-blank Sessions up to a watermark, initially 5; Show more adds 5; the watermark rises to cover the last Session within the first 50 that is running, has a running child, awaits the user, has an unread completion or is open.
- Sort modes: Last updated (latest user prompt or steer time, newest first, ties by Session id) and Manual (one complete saved sequence including hidden archives). Pinned Sessions lead in both. Dragging selects Manual.
- Group by: WorkSpace (flat sibling sections), Workspace Tree (nest under the nearest registered ancestor path), or a single flat list. Archive filter: Hide archived (default), All conversations, Archived only.
- Search: immediate case-insensitive substring match on title, Workspace and Session id; a 250 ms debounced Host content search adds ranked matches and snippets; list capped at 20; each new query aborts the previous request.
- Row menu order: Pin (100), Rename (200), Fork (300), Copy session ID (450), Open in (500, `ui-open-in-app`), Archive (600).
- Archive of a Session with running work is refused by the Host and opens a stop-and-archive dialog listing the turn, subagents, jobs and reminders.
- Startup: restore the saved main Session; an empty installation calls `workspaces.initializeDefault` once and opens its blank Session.
- Subagent Sessions (`origin: 'subagent'`) are hidden from the sidebar and reached from the parent header.

## Tests worth porting

Unit and component suites (`pnpm run test:gui` runs `vitest run packages/client packages/host`; no browser). Each package keeps its specs under `tests/`.

| Path | Behavior pinned |
|---|---|
| `packages/client/web/tests/boot-client.client.spec.ts`, `boot.client.spec.ts`, `boot-page.client.spec.ts`, `mount.client.spec.ts` | Boot order, required-entry audit text, optional-entry warning text, failure page, remount when `uiRenderer` is replaced |
| `packages/client/modules/tests/node-half.client.spec.ts` (1460 lines) | `dsh.client` scan, graph composition, revisions, combo URL partition at 3 KiB, route status codes, source-map composition, incremental reconciliation, duplicate package rejection |
| `packages/client/modules/tests/loader.client.spec.ts`, `entries.client.spec.ts` | Lazy factory materialization, resolution order, cycle error, batch fallback request counts, live enable/disable, style cleanup, release gate |
| `packages/client/modules/tests/package-assets.client.spec.ts`, `assets.client.spec.ts` | Asset route headers, ETag/304, extension allowlist, percent-encoding form |
| `packages/client/connection/tests/generation.client.spec.ts`, `connection.client.spec.ts`, `recovery-config.client.spec.ts`, `fake-generation.client.ts` | Generation readiness, warning and timeout, backoff tiers and jitter bounds, manual reconnect, offline/online, config validation |
| `packages/client/connection/tests/browser-auth.host.spec.ts`, `api-request-trust.host.spec.ts`, `http-bridge.host.spec.ts`, `binary-rpc.host.spec.ts`, `fetch-routes.host.spec.ts`, `rpc-schema.host.spec.ts`, `node-half.host.spec.ts` | Token exchange, cookie format and expiry, Host/Origin rules, 401/403/409/413 cases, multipart attachment framing, exact route ownership |
| `packages/client/ui-chat/tests/conversation-node-definitions.client.spec.ts`, `conversation.client.spec.ts`, `event-projection.client.spec.ts` | Every Chat Definition: replace vs prepend vs append equivalence, pending update-only tails, interruption projection, steering vs user vs trigger classification |
| `packages/client/ui-chat/tests/process-groups.client.spec.ts`, `group-tree-segments.client.spec.ts`, `turn-process-tail.client.spec.ts`, `tool-call-tree.client.spec.ts`, `tool-preparation.client.spec.ts`, `transcript-view-policy.client.spec.ts`, `turn-metrics.client.spec.ts` | Grouping examples from the node README, category counting and ranking, live detail selection, display modes, token usage aggregation |
| `packages/client/ui-conversation/tests/` (60 files; start with `conversation-assembler.client.spec.ts`, `conversation-group-store.client.spec.ts`, `conversation-groups.client.spec.ts`, `submit-machine.client.spec.ts`, `submission-policy.client.spec.ts`, `queue-dock.client.spec.tsx`) | Assembler replace/prepend/append/rebuild, Location index, Group store validation, submit machine transitions, prompt serialization with quotes and references, draft persistence, queue dock, submission policy |
| `packages/client/ui-input-trigger/tests/core-detect.client.spec.ts`, `core-menu.client.spec.ts`, `service.client.spec.ts` | Trigger boundaries (URL carve-outs, `user@host`), guard tiers, menu reducer generations, adjudication order |
| `packages/client/ui-commands/tests/directory.client.spec.ts`, `popup.client.spec.ts`, `service.client.spec.ts` | Catalog cache and invalidation, popup grouping and search modes, contribution/decoration collisions |
| `packages/client/ui-approval/tests`, `ui-user-questions/tests` | Waterfall answer, delegation, abort by signal, single pending lock, countdown and draft restore |
| `packages/client/ui-tool/tests` | Card models per tool (terminal, read, diff, search, web, office, todo diff), fallback to generic output, auto-review denial |
| `packages/client/ui-workspace/tests` | Watermark, ordering and pin rules, tree grouping, archive filter, search merge |

Browser scenarios (`apps/web/tests/*.e2e.ts`, Playwright, 283 files including support): run against the built `dist` and a real Host with a recorded model (`DSH_SNAPSHOT=replay`). Expected text and images live in `apps/web/tests/expected/<scenario>/`; overlays `*.overlay.yml` and `fixtures/*.patch.yml` are cordis patches applied with `--patch`, so they double as tests of patch compatibility. Useful as a parity checklist: `approval-composer`, `question-composer*`, `plan-review`, `plan-control-row`, `steering`, `queue-actions`, `queue-image`, `reference-composer`, `composer-shortcuts`, `composer-paste-routing`, `submission-echo`, `interrupted-turn`, `connection-recovery`, `server-restart`, `session-replay-reload`, `seeded-history`, `stats-paged-history`, `chat-scroll-contract`, `collapse-timing`, `tool-details`, `todo-row.expected`, `search-card.expected`, `web-search-round`, `ptc-round`, `skill-tool-row`, `subagent-conversation`, `workflow-run`, `background-job-list`, `goal-bar`, `schedule-*`, `workspace-management`, `workspace-recency`, `session-archive-active`, `session-unarchive`, `sidebar-right`, `sidebar-terminal`, `file-browser`, `document-preview`, `models-settings`, `settings-appearance`, `remote-settings`, `plugin-manager`, `plugin-install-*`, `plugin-hmr-lifecycle`, `client-plugin-live`, `shortcuts*`, `additional-locales`, `public-mount` (app under a path prefix), `pwa-manifest`, `startup-rpc-budget`.

Other reusable corpora: `snapshots/web/` (74 recorded Session scenarios replayed through the shipped `web` profile), `apps/web/tests/assembled-boot.ts` and `assembled-remote.ts` (whole-client jsdom boot against `packages/test-support/remote-mock`), `packages/test-support/client-runtime` (fixture runtime for component specs: `sessions.ts`, `remote.ts`, `config-form.ts`, `workspaces.ts`, `access.ts`). Every scenario treats a `web boot: warning` console line as a failure.

## Porting notes

### What is essential product behavior

1. The Host-side contracts: the `dsh.client` scan and `/plugins` routes, index injection rows, `/api` RPC envelope and multipart framing, `/connect` and cookie authentication, Host/Origin trust, `/plugins/events`, and the `connection`, `hmr`, `modules` row configs. A Racket Host must implement these to serve the existing browser bundles unchanged. They are plain HTTP and JSON and port directly.
2. The settings namespaces written by the UI (`ui-chat`, `ui-theme`, `locale`, `ui-conversation`, `ui-settings`, `ui-settings-general`, `ui-settings-account`, `product-analytics`) and their value domains. Existing `cordis.patch.yml` files in a user's `$DSH_HOME` contain these keys; the Racket loader must accept the rows and the settings service must validate them.
3. The conversation projection: which Session events produce which transcript rows, in what order, with what folding. This is pure and deterministic, and it is the specification for any UI over the Session log.
4. The composer semantics: submit machine, queue versus steer, command claims, reference serialization, attachments, approvals and questions as composer takeovers.
5. The Remote methods and forwarded events each feature consumes (tables in Scope and Events). They define what the Host BFF must offer.

### What is Node, TypeScript or React machinery

- The dynamic client plugin system (lazy CommonJS table, combo scripts, HMR of bundles, platform module identities, `tsdown.client.ts`). A Racket-served UI needs it only if it serves the existing JavaScript bundles.
- Slots, the five props shares, `useSyncExternalStore` binding, CSS Modules, `--dsw-*` tokens, Lexical editor internals, virtualized lists, scroll-anchor compensation, animation timing. These are presentation.
- Declaration merging (`SlotMap`, `ChatNodeDataMap`, `ConversationTurnDataMap`, `SessionEventMap`). In Racket these are runtime registries.
- Electron specifics: window drag regions, `dshDesktopBoot`, `__DSH_HOST_PATHS__`, update channel, product analytics.

### Two viable strategies

**A. Serve the existing browser client from a Racket Host.** The Racket side implements: the Web carrier with the index fallback and injection table; a `client-modules` service that scans loader entries for `dsh.client` and serves prebuilt `lib/client.js` files; `client-connection`; `client-hmr` (optional: it is not on the required-entry list; without it an open page receives no live graph updates); API Gateway with the mux WebSocket; every Remote namespace and stream the roster uses. The browser code stays JavaScript and is shipped as built artifacts (it cannot be compiled by Racket; it needs the Node toolchain at build time only). The Host halves of client packages are tiny and must be re-expressed as Racket plugins with the same row names and `Config` schemas so shipped patches keep loading. This is the lowest-risk way to claim feature parity for the Web UI. Risk: the boot audit rejects startup when a required client entry cannot activate, and most entries wait on `remote.<namespace>` services, so missing Host Remotes leave entries `pending`. Build the Remote surface before expecting a visible UI.

**B. A Racket-native UI.** Reimplement the projection and composer logic in Racket and render server-side or with a thin client. Suggested modules:

- `web/boot-graph.rkt`: `dsh.client` parser, graph composition, revision hashing, combo partition (pure functions; contract `web-boot-graph/c`).
- `web/connection.rkt`: RPC envelope codec, multipart attachment codec, cookie sign/verify (HMAC-SHA256, base64url), trust predicate, Peer struct with a custodian per Peer (disposing the custodian is `Peer.dispose`; the Peer's `signal` maps to a custodian-shutdown event).
- `web/generation.rkt`: the reconnect loop as a thread plus `sync` over alarm events; backoff parameters as a contract-checked struct; jitter through an injectable random source (a parameter) so tests are deterministic.
- `conversation/definition.rkt`: a `definition` struct (`kind`, `target`, `match`, `start`, `update`, `publication`, `build-location-data`, `build-view-node`); `conversation/assembler.rkt`: Contexts keyed by `(kind . id)`, replace/prepend/append, predecessor index, Location index. State is immutable; use persistent hashes so replay equality is checkable with `equal?`.
- `conversation/chat/*.rkt`: one module per Definition in the table above, plus `process-groups.rkt` and `process-activity.rkt`. A small macro (`define-chat-definition`) can generate the `match` table keyed by event type, which is what the TypeScript registration does by hand for the hot path.
- `composer/submit-machine.rkt`: a pure `(step state event) → (values state effects)` function; `composer/trigger-detect.rkt`: pure string function; `composer/prompt.rkt`: draft serialization.
- `settings/forms.rkt`: namespace mirror with revisioned writes.
- Dictionaries: one hash per namespace per locale; `locale` parameter per request or connection.

Registrations map to Cordis effects exactly as on the Host; a plugin's slot or Definition registration is disposed with its fiber.

### Hard parts and risks

- Replay equivalence. The same final snapshot must result from a full replace, from tail-first paging (updates before their start), and from live append. The pending-Context rule and the predecessor rerun rule are easy to get subtly wrong; port the `ui-chat` and `ui-conversation` specs first.
- Assistant streaming. Live deltas are client-only `assistant/live-chunk` events; durable history carries compact streams inside `assistant/message` and `assistant/attempt`. The tool node may be opened by a delta before `tool/call` exists, under the same call id.
- Inbox classification. Steering versus user versus trigger depends on the `agent/inbox/spliced` claim chain and on durable event order written by the agent loop; it breaks if the Racket agent loop logs claims and messages in a different order.
- Whole-Turn folding and collapse timing interact with paging and reader scroll position; most of that text in the node README is presentation, but the eligibility rules are data rules.
- Lazy tool arguments (`PartialArguments`): rows read streaming JSON argument prefixes; a server-rendered UI can skip this and show arguments at `tool/call`.
- Authentication details: cookie name depends on the request authority and scheme; TLS and plain HTTP cookies must not cross-authenticate; the launch token is accepted only on `GET /` and `/connect`.
- Access control: Send, Stop, file intake and row actions are hidden by `remote-access` answers but the Host remains the authority. Do not move authorization into the UI.
- Scale: about 180k lines, most of it presentation. Strategy B is a multi-month effort if every surface (document preview, terminal, schedule editor, plugin manager, trajectory) is rebuilt.

### What can only be wrapped

- The built client bundles (`lib/client.js` of each package, `apps/web/dist`) require Node, Vite and tsdown to build. A Racket distribution can ship them as static artifacts.
- Document preview renderers (pdf.js, Office conversion through `officeKit`, spreadsheet parsing in a Worker), the xterm-based terminal, Lexical, KaTeX and the Markdown pipeline are third-party JavaScript. Under strategy A they come for free; under strategy B they need replacement or omission.
- Desktop (Electron) integration is outside a Racket-served browser UI.

## Feature checklist

One line per feature, prefixed with the owning package. Group labels are plain lines so the bullets stay flat.

Sessions and workspaces
- `ui-workspace`: add a workspace by picking a directory (native chooser or in-app browser), rename and delete workspace, default workspace on first use
- `ui-workspace`: session tree grouped by workspace, workspace tree nesting by path, or one flat list; expansion state remembered in the browser
- `ui-workspace`: per-workspace row watermark of 5 with Show more and Show less
- `ui-workspace`: sort by Last updated or Manual; drag to reorder sessions and workspaces
- `ui-workspace`: pin and unpin a session
- `ui-workspace`: rename (dialog, double-click), fork from last completed turn, copy session ID
- `ui-workspace`: archive with undo, stop-and-archive dialog for running work, unarchive, archive filter with three values
- `ui-workspace`: search by title, workspace, id immediately and by content after 250 ms; 20 results
- `ui-workspace`: row status (running, awaiting approval, plan review, awaiting answer, unread completion) and hover details
- `ui-workspace`: restore the last open session on reload; reuse a blank session for New Session
- `ui-sidebar`: New Session button and shortcut, collapsible rail, drawer below 768px, brand and version badge
- `ui-sidebar`: global panel list (Plugins, Automation tasks, plugin panels) with More menu and pin/unpin
- `ui-subagent`: subagent tree in the session header, open child transcript, continue or stop a continuable child
- `ui-agent-team`: shared team task list and team switch
- `ui-session`: session-scoped UI state survives switching between sessions

Chat transcript
- `ui-chat`: user message, steering message, context injection row, turn-trigger notice (schedule, job, goal, subagent, webhook, retry)
- `ui-chat`: streaming assistant text and reasoning, reasoning preview and expansion, interrupted marker
- `ui-chat`: system prompt row and prompt-update row (Coding Tools)
- `ui-chat`: process groups with category titles and live detail; four Work details modes
- `ui-chat`: whole-Turn fold with duration or status; collapse on completion or on next message; replies-after-collapse choice
- `ui-chat`: model retry row, turn error row, max-tokens notice, compaction marker, manual `/compact` row, command row, unknown-event fallback row
- `ui-chat`: turn tail with copy, branch (fork), token usage panel, performance statistics pills
- `ui-chat`: turn navigator rail, load older history, follow tail while streaming, back-to-bottom
- `ui-chat`: Markdown with code highlighting, tables, TeX, file links, images; link opening in sidebar or new tab
- `ui-chat`: text-selection actions; quote selected text into the composer (with `@deepseek-ai/dsh-message-quotes`, outside this area)
- `ui-attachment`: message images with lightbox, file cards, drag image out
- `ui-secret-mask`: masked credentials in sent user text
- `ui-message-feedback`: Like, Dislike, feedback dialog
- `ui-deliverables`: changed-files card with per-file counts and review tab; delivery cards; clickable file mentions
- `ui-workflow-run`: workflow run node with phases and members
- `ui-goal`: `/goal` command-input bubble
- `ui-user-questions`: answered-question bubble
- `ui-plan`: submitted-plan card with Open
- `ui-trajectory`: Trajectory view tab with record inspector (Coding Tools)
- `ui-conversation`: View tabs, More conversation views, resizable content width

Composer
- `ui-conversation`: rich draft with reference chips, command chip, quotes; drafts persist per session across reload
- `ui-conversation`: Enter sends, Shift+Enter newline, Ctrl/Cmd+Enter uses the other delivery mode
- `ui-conversation`: queue or steer while running; queue dock with edit, remove, steer; steer-all chord on an empty draft
- `ui-conversation`: Stop button and Esc-Esc stop
- `ui-conversation`: Continue generating after a retryable failure
- `ui-conversation`: attach images and files by picker, paste, drop; upload progress, retry, remove
- `ui-conversation`: context meter with token breakdown; todo dock
- `ui-conversation`: blank-home hero with workspace picker and preset picker
- `ui-input-trigger`: `/` and `@` menus with keyboard navigation, drill-down and breadcrumbs
- `ui-commands`: slash commands File, Goal, Plan, Feedback, Compact, Permission, Model, Export plus Host and skill commands; localized aliases; `+` launcher
- `ui-reference`: `@file`, `@folder/`, `@session` references with preview on click
- `ui-skill`: `/skill-name` invocation and skill file preview
- `ui-subagent`: `@subagent` reference

Modes (model, permission, preset, plan, goal)
- `ui-model-selection`: model seat grouped by provider, search, reasoning effort, `/model`
- `ui-permission-presets`: access-mode control (Read Only, Workspace Write, Full access, Auto review) and `/permission`
- `ui-agent-preset`: preset choice for a new session (Standard, Creator, PTC, Minimal, custom)
- `ui-plan`: Plan chip, `/plan`, exit plan mode
- `ui-goal`: goal bar with edit, pause, resume, clear

Approvals and questions
- `ui-approval`: approval card replaces the composer; Reject, Allow, optional Always allow; Enter and Escape; localized reason and warning
- `ui-approval`: optional tool detail in the approval card
- `ui-user-questions`: multi-question card with single-select, multi-select, custom answer, Skip, pager, recommended preselection
- `ui-user-questions`: countdown for timed questions, Take time, draft restore after reload
- `ui-user-questions`: plan review card with Approve and Request changes
- `ui-user-questions`: late answer through the tool row after the wait ended

Tool cards
- `ui-tool`: generic tool row with arguments and result for any tool
- `ui-tool`: terminal card for shell commands with exit status
- `ui-tool`: read card, image card, diff card for write/edit/apply_patch, search card, web card
- `ui-tool`: todo diff row, question row, Office rows, 40 structured control rows
- `ui-tool`: nested PTC sub-calls under `run_code`
- `ui-tool`: open file in sidebar, Inspect in Trajectory, context menus on paths and URLs
- `ui-skill`: skill row with instructions
- `ui-deliverables`: present row

Settings
- `ui-settings-general`: settings dialog with sections and shortcut; connection status pill with retry; release-change dialog
- `ui-settings-general`: Coding Tools switch, current version, open configuration file on loopback
- `locale`: language (8 locales)
- `ui-theme`: appearance light/dark/system, font sizes and families for text, code, terminal
- `ui-chat`: Work details, Collapse work details, Replies after collapse, link opening, usage detail
- `ui-conversation`: busy-Enter behavior
- `ui-permission-presets`: default permission for new sessions
- `ui-settings-session-log`: session-log upload switch
- `ui-settings-models`: providers, API keys, model lists, custom endpoints, first-run onboarding
- `ui-settings-account`: DeepSeek sign-in, balance, sign-out, account notifications
- `ui-agent-preset`: preset roster, default preset, configuration viewer, Creator entry
- `ui-shortcuts` and `shortcuts`: shortcut reference, record, clear, restore

Plugins
- `ui-plugin-manager`: Plugins page with built-in plugin settings, experimental bundles, installed bundles
- `ui-plugin-manager`: install from package name, Git address, tarball or local path; registry choice and probe; progress, cancel, script approval
- `ui-plugin-manager`: enable, disable, remove, update with version list; bundle detail document; per-plugin rows
- `ui-plugin-manager`: live effect without page reload; page-local sync failure and retry
- `ui-plugin-market`: Discover tab with index sources, search, labels, categories, sort, install confirmation
- `ui-settings-plugin-inventory`: read-only plugin list with status
- `ui-settings-shell`, `ui-settings-agent-loop`, `ui-settings-subagent`, `ui-settings-web-search`: official plugin pages
- `ui-entry-customization`: pin or unpin plugin entries; start a plugin draft
- `modules` and `hmr`: client plugin bundles load, unload and hot-replace in an open page

Files, terminal and right sidebar
- `ui-sidebar-right`: docked tabs with splits per session; guide page; expand button in the header
- `ui-sidebar-files`: workspace file tree, search, open in tab
- `ui-sidebar-documentpreview`: preview Markdown, code, images, PDF, HTML, Office, spreadsheets, text; reload and wrap
- `ui-sidebar-terminal`: interactive shell tabs that survive reload
- `ui-sidebar-browser`: browser tabs (Desktop profile)
- `ui-open-in-app`: open directory or file in an installed application
- `ui-file-actions`: save original file, copy image
- `ui-jobs`: background job list with live output
- `ui-schedule`: automation tasks page, create/edit/run/pause/delete, session clock and row mark
- `ui-plan`: plan Markdown tab

Misc
- `web`: boot page with progress and plugin failure list
- `connection`: token login link, cookie session, reconnect with backoff, offline handling
- `connection`: API client login through `/connect`
- `ui-context-menu`: right-click menus on sessions, workspaces, files, URLs, images
- `ui-layout`: three-column frame with resizable columns; document title
- `ui-file-drag`: drag images into the composer
- `apps/web`: installable PWA manifest; works under a path prefix
- `ui-brand-official`: brand artwork and home whale animation
- `product-analytics`: Desktop-only event reporting
