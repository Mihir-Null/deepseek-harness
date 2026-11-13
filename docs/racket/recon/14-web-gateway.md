# Recon 14: Web gateway (HTTP host, Typert RPC, Remote controllers)

Area: `packages/api/*`, `packages/typert/*`, `packages/host/*`, `packages/bundle/web-app/cordis.patch.yml`, `docs/api-gateway.md`, `docs/subsystems/typert.md`, `docs/cookbook/adding-a-remote-api.md`. Pinned commit `e8f7b93a3` (dsh 0.2.2-rc.2). All paths are relative to the repository root. Line numbers refer to that commit.

Three facts shape this port and are easy to get wrong:

1. The layering is `remotes → gateway → connection → webserver` (`docs/api-gateway.md:166`). `packages/host/webserver` is only a route table over `node:http`. Authentication, the Host/Origin fence, the `/api` route, the unary RPC envelope and the multipart binary framing live in `packages/client/connection` (Host half), which is outside the listed area. I read its Host half because the wire cannot be specified without it; it is cited as "Connection (adjacent)".
2. Unary Remote calls are plain HTTP `POST /api/<namespace>/<method>` with a JSON envelope. Every stream (session follow, terminal, jobs, forwarded events) is a logical stream multiplexed over one WebSocket at `/api/remote.mux`. There is no SSE in the Remote path. The only SSE endpoint is the client-plugin hot-reload feed `/plugins/events` (owned by `packages/client/hmr`).
3. The browser never validates JSON arguments or JSON results. The Host validates arguments with codecs generated at build time from TypeScript types (Zod schemas). A compatible server therefore has to honor endpoint names, wire argument names, result fields and error codes exactly; it does not have to reproduce the TypeScript type graph.

## Scope

| Package directory | npm name | Role | Source lines (no tests) |
|---|---|---|---|
| `packages/api/gateway` | `@deepseek-ai/dsh-api-gateway` | Host dispatcher `ctx.typertGateway` (endpoint claim, argument validation, access check, lookup/Context resolution, invocation, binary result projection, forwarded-event broker), WebSocket mux server, stream wire protocol; Client half `ctx.remote` (mount, unary caller, mux client, journal/snapshot stream supervisors) | Host ~3,040; Client ~2,650 |
| `packages/api/remotes` | `@deepseek-ai/dsh-api-remotes` | Host: registers the forwarded Cordis event source (allowlist of 31 events). Client: mounts the 30 selected `/remote` contributions | Host ~250; Client ~220 |
| `packages/api/remote-access` | `@deepseek-ai/dsh-api-remote-access` | `ctx.remoteAccess`: role/binding policy registry for non-owner Peers, `decide`, `allows`, per-Peer access snapshot stream `remoteAccess/follow`, index global `__DSH_REMOTE_ACCESS__` | Host ~570; Client ~500 |
| `packages/api/session-controller` | `@deepseek-ai/dsh-api-session-controller` | Remote namespaces `session`, `fileReferences`, `skills`; Agent/Session lookup policy (cold resume); list/search; history paging; follow stream with assistant-stream frames; state/wait; control stream; `/api/file` route; archived-session gate; two session projections | Host ~4,800; Client ~4,600 |
| `packages/api/job-controller` | `@deepseek-ai/dsh-api-job-controller` | Remote namespace `job`: roster stream, per-job output stream, human kill | Host ~465; Client ~530 |
| `packages/api/settings-controller` | `@deepseek-ai/dsh-api-settings-controller` | Remote namespaces `settings` and `credentials` over `ctx.settings` / `ctx.credentials` | ~460 (Host only) |
| `packages/api/terminal-controller` | `@deepseek-ai/dsh-api-terminal-controller` | Remote namespace `terminal`: Session-owned PTY terminals, headless screen emulator, bidirectional attach stream, retention/idle reclamation, Agent terminal handle | Host ~1,630; Client ~1,225 |
| `packages/api/workspace-controller` | `@deepseek-ai/dsh-api-workspace-controller` | Remote namespaces `workspace` and `directoryPicker`; Workspace follow feed; default Documents directory lookup | Host ~1,175; Client ~785 |
| `packages/api/workspace-files` | `@deepseek-ai/dsh-api-workspace-files` | Remote namespace `workspaceFiles`: paged text read, byte read (binary transfer), stat, list, ripgrep name search, watch stream; lookup `workspaceFileScope` | Host ~1,040; Client ~580 |
| `packages/typert/protocol` | `@deepseek-ai/dsh-typert-protocol` | Decorators `@Remote`/`@RemoteScope`, `TypertRemoteService`, `RemoteError`, descriptor and registry types, `PeerScope`, `RemoteInvocation`, lossless-JSON predicate, lazy `createTypertRemoteInfo` | ~1,800 |
| `packages/typert/registry` | `@deepseek-ai/dsh-typert-registry` | `ctx.typert`: schema store, package reflection, local/remote descriptor stores, lookup/Context/resource registries | ~980 |
| `packages/typert/loader` | `@deepseek-ai/dsh-typert-loader` | Function plugin: imports each mounted package's `./typert` artifact and registers its `TYPERT` manifest | ~510 |
| `packages/typert/generator` | `@deepseek-ai/dsh-typert-generator` | Build-time TypeScript analyzer and Zod/declaration emitter (`lib/typert.host.*`, `lib/typert.remote-client.*`), tsdown plugin, Cordis catalog projection | ~7,600 |
| `packages/host/webserver` | `@deepseek-ai/dsh-host-webserver` | `ctx.webServer`: exact/prefix route table, upgrade table, one fallback seat, optional gzip, optional TLS, index injection rows | ~860 |
| `packages/host/frontend-static` | `@deepseek-ai/dsh-host-frontend-static` | Fallback-seat owner: serves the built SPA dist, authenticates and renders `index.html` | ~170 |
| `packages/host/directory-picker` | `@deepseek-ai/dsh-host-directory-picker` | Abstract seam `ctx.directoryPicker` with `native` / `browse` capability union | ~155 |
| `packages/host/directory-picker-auto` | `@deepseek-ai/dsh-host-directory-picker-auto` | Boot-time resolver that mounts the native or browse backend plus its client surface as Loader entries | ~220 |
| `packages/host/directory-picker-browse` | `@deepseek-ai/dsh-host-directory-picker-browse` | Browse backend: bounded one-level directory listing, child directory creation | ~325 |
| `packages/host/directory-picker-native` | `@deepseek-ai/dsh-host-directory-picker-native` | Native backend: `osascript` AppKit panel, zenity/kdialog, Win32 `IFileOpenDialog` child process via koffi | ~780 |
| `packages/host/open-in-app` | `@deepseek-ai/dsh-host-open-in-app` | Three plain HTTP routes: installed-application catalog, icons, launch on a directory | ~1,670 |
| `packages/host/plugin-inventory` | `@deepseek-ai/dsh-host-plugin-inventory` | Remote namespace `pluginInventory`: read-only Loader entry and preset composition snapshot | ~200 |
| `packages/host/product-telemetry-otel` | `@deepseek-ai/dsh-host-product-telemetry-otel` | `ctx.productTelemetry`: OTLP log exporter policy adapter (desktop profile only) | ~120 |
| `packages/bundle/web-app` (patch only is in scope) | `@deepseek-ai/dsh-web-app` | `cordis.patch.yml` (620 lines) composing the browser surface; `src/` holds the `web-runtime` glue and `web-startup` CLI flag provider (~400 lines, read for flags and URL printing) | patch 620 |

Adjacent code read because the wire depends on it: `packages/client/connection/src/{index,browser-auth,api-request-trust,http-bridge,rpc-host,rpc,rpc-schema,peer}.ts` (~1,400 lines, Host half) and `src/client/rpc.ts` (browser unary caller).

Depth. In depth: `gateway` (Host), `webserver`, `frontend-static`, Connection Host half, `typert/protocol`, `typert/registry`, `typert/loader`, `remotes`, `remote-access`, `session-controller` (Host), `job-controller`, `settings-controller`, `terminal-controller` (Host), `workspace-controller` (Host), `workspace-files` (Host), `directory-picker*` except the Win32 dialog internals, `plugin-inventory`. Catalog depth: `typert/generator` (build-time only; the model and emitted artifact layout are described, the 3,471-line analyzer is not), every `src/client/*` half (browser code), `open-in-app` catalog/resolver/icons internals, `directory-picker-native` Win32 bindings, `product-telemetry-otel`. Skimmed rather than read line by line: `workspace-controller/src/commands.ts` (request/result types and error codes are covered; the registry call sequence is not), `workspace-files/src/{search,changes}.ts` (arguments and frame rules are covered), `terminal-controller/src/{screen,agent}.ts` (exported signatures only). Not covered: the method lists of the 23 Remote namespaces owned by other areas, the `__DSH_BOOT__` module graph format (`packages/client/modules`), and the `data` schema of each session event type (session area).

## Services

### `ctx.webServer` — `WebServer` (`packages/host/webserver/src/index.ts:357`)

Service class, default export, no `inject`. Listens in `[Service.init]` inside `ctx.effect`; a bind or TLS failure rejects initialization (`EADDRINUSE` fails the fiber).

- `port: number | undefined` — bound port (OS-assigned when config port is 0); `undefined` before bind.
- `host: string` — configured bind literal.
- `protocol: 'http:' | 'https:'` — follows config (`tls` present), never a request header.
- `getOrigin(): string` — `<protocol>//<bindUrlHost>:<port>`; throws before bind or when the bind address carries a non-loopback `%zone`.
- `register(route): () => void` — `route` is `{ kind: 'exact' | 'prefix', path, handler(req, res) }` or `{ kind, path, resource(request, peer?) }`. Duplicate `(kind, path)` throws `webserver: duplicate <kind> route "<path>"`. Returns the disposer.
- `registerUpgrade({ path, handler(req, socket, head) }): () => void` — exact path only; duplicate throws.
- `registerFallback(handler | { resource }): () => void` — one owner; a second throws `webserver: fallback already registered`.
- `readResource(request: Request, peer): Promise<Response>` — in-process read by the HTTP match order; only resources answer (handler routes and an unclaimed fallback give 404); non GET/HEAD gives 405 with `Allow: GET, HEAD`. No cookie, Host, or Origin check; the caller admits the reader.
- `tapIndex(transform: (html) => html): () => void` — raw HTML transform applied after row rendering, in registration order.
- `applyIndexTaps(html)`, `collectIndexInjections(peer): IndexInjection[]` (one `webserver/index-inject` emit, fresh per call), `renderIndex(html, peer): string` (rows, then taps).

Module exports: `isWildcardHost`, `isLoopbackHost`, `normalizeBindAddress`, `bindUrlHost`, `renderIndexInjections`.

### `ctx.connection` — `HostConnectionService` (Connection, adjacent; `packages/client/connection/src/rpc-host.ts:70`)

Function plugin `client-connection`, `inject = ['credentials']`. Members used by this area:

- `browserPeer: PeerScope` — one owner Peer shared by every authenticated browser request.
- `rpc.intercept('/api', matches(endpoint), handler(endpoint, payload, signal, peer))` — one interceptor per channel; the Gateway is the only one. `rpc.handle(channel, handler)` registers another prefix channel (not `/api`).
- `fetch.register({ path, methods, requestBody: 'buffered' | 'streaming', fetch(request) })` — exact route under `/api`; owner Peers only (others get 403 `forbidden`).
- `admit(request): { peer } | { rejection: 401 | 403 }`, `requestRejection(request): 401 | 403 | undefined`.
- `admitConnection(request): { peer, release() } | { rejection: 401 | 403 | 409 }` — claims the one physical socket of an API Peer; browser sockets share `browserPeer` and release is a no-op.
- `createPeer({ principal, interactions? }): PeerScope` — in-process Peer, disposed with the reading Context.
- `authorizeIndex(req, res): boolean`, `authorizeConnect(req, res)`, `authenticatedUrl(baseUrl): string`.
- `allowsRemoteAuthorities: boolean` — true when a `trustedHosts` entry names a non-loopback host.
- `createSharedFetchHandler('/api')` — composes exact Fetch routes with the interceptor; anything else is `404 not found`.

A `Peer` (`src/peer.ts`) has `id` (random UUID), `ctx` (its own Cordis scope), `principal`, `interactions` (`'answer'` default, or `'none'`), `signal` (aborted on dispose), `dispose()`.

### `ctx.typert` — `TypertRegistry` (`packages/typert/registry/src/service.ts:508`)

Service class, default export, no Config, no inject. The Client face (`./client`) installs the same class through a function plugin.

- `register(contribution: TypertContribution): TypertDisposer` — atomic per calling fiber. `TypertContribution = { package, face: 'host' | 'client', schemas: [{ name, create() }], model: { services, events, objects }, invocations: InvocationDescriptor[] }`. Duplicate package-face key (`<package>#<face>`), schema key (`<package>#<name>`), invocation id, or endpoint rejects the whole batch.
- `get(key)`, `resolve(key)` (throws with three distinct messages: malformed key, package registered without that schema, package unregistered), `list(filter?)`, `getPackage(name, face = 'host')`, `listPackages(filter?)`, `toJSONSchema(key, params?)`. Schemas materialize lazily and are cached on the record.
- `local: { get(endpoint), hasSeen(endpoint), list(), subscribe(listener) }` — strict Host descriptors. `hasSeen` stays true after withdrawal for the registry lifetime.
- `remotes: { register(contribution), get, list, subscribe }` — Client-selected descriptors; one registration per package name.
- `lookups: { register(key, provider), configure(key, resolver), get(key), definitions(), keys(), subscribe }` — `provider = { parameter, wire, resource?, hostTypeSymbol, wireTypeSymbol, resolve(id) }`. `configure` overrides the resolver for one key while the effect lives; `get` returns the provider's declaration with the configured resolver. `definitions()` retains declarations after the provider unloads; re-registering a key with a different declaration throws.
- `contexts: { registerHost(key, adapter), configureHost(key, resolver), registerClient(key, adapter), getHost, getClient, subscribe }` — Host adapter `{ wire, wireTypeSymbol, resource?, resolve(id): Context | undefined }`.
- `resources: { register(kind, { field } | { resolve(input) }), get, entries(), subscribe }` — default identity extraction per resource kind; `global` is reserved.

Every registration is a `ctx.effect` owned by the Context that read the sub-registry; disposers are awaitable. Change listeners receive `{ kind: 'local' | 'remote' | 'lookup' | 'host-context' | 'client-context' | 'resource', key }`; a throwing listener is logged and contained.

Name grammar: wire names, namespaces, methods match `/^[A-Za-z0-9_$.-]+$/` and are not `.` or `..`; keys must be non-empty and contain no `#` (`service.ts:801-815`).

Registered lookups and adapters in the shipped composition:

| Key | Kind | `parameter` | `wire` | `resource` | Owner |
|---|---|---|---|---|---|
| `agent` | lookup | `agent` | `agentId` | `session` | `packages/core/agent/src/index.ts:262` |
| `agent` | Host Context | — | `agentId` | `session` | `packages/core/agent/src/index.ts:270` |
| `session` | lookup | `session` | `sessionId` | `session` | `packages/core/session/src/index.ts:1174` |
| `workspaceFileScope` | lookup | `workspaceFileScope` | `workspaceFileScopeId` | `session` | `packages/api/workspace-files/src/index.ts:216` |

Resource kinds: `session` (resolver `resolveSessionResource`, `session-controller/src/index.ts:92`) and `workspace` (`{ field: 'workspaceId' }`, `workspace-controller/src/index.ts:73`).

### `ctx.typertGateway` — `TypertGatewayService` (`packages/api/gateway/src/index.ts:214`)

Service class, default export, `static inject = ['typert', 'remoteAccess']`. Optional: `connection` (installs the `/api` interceptor), `connection` + `webServer` (registers the WebSocket upgrade), `appReady` (delays the upgrade route until the launcher reports readiness).

- `invoke(request: InvokeRemoteRequest): Promise<unknown>` — unary; a stream method gives `gateway/signature-invalid`.
- `stream(request): Promise<AsyncIterable<unknown>>` — stream methods only; a unary method gives `gateway/signature-invalid`.
- `wireStream: { open(endpoint, payload, uplink, peer, signal), failure(error) }` — carrier adapter for the mux and in-process transports.
- `registerRemoteEvents(source, host: { home }): () => Promise<void>` — one source only; second registration throws.
- `hasLiveClient(): boolean` — an uncancelled owner `$events` stream exists.
- `getPendingRemoteEvents(): { event, agentId }[]` — unsettled forwarded waterfalls in arrival order.

`InvokeRemoteRequest = { namespace, method, args, peer, uplink?, uplinkWindow?, signal? }`. `peer` is required; the Gateway never defaults it.

The receiving method reads its call context as `this.ctx.invocation` (`RemoteInvocation = { request: { namespace, method, args }, service, peer, signal, uplinkWindow?, uplink<In>() }`). The Gateway derives the receiver with `receiverContext.extend({ invocation }).get(service)` (`index.ts:858`), so nothing enters the parameter list.

### `ctx.remoteAccess` — `RemoteAccessService` (`packages/api/remote-access/src/index.ts`)

Service class extending `TypertRemoteService` (namespace `remoteAccess`). The Gateway requires it.

- `registerPolicy(kind, policy): () => void` — one policy per non-owner principal kind; `policy = { bindings(principal): Binding[], explain?(request): string | undefined }`; `Binding = { role: { name, resource: kind, actions: string[] }, resource: { kind: 'global' } | { kind, id }, condition?(request) }`.
- `invalidate(principal?)` — re-pushes open snapshots and re-arms failure logging.
- `decide({ principal, action, resources, args? }): { kind: 'allow' } | { kind: 'deny', reason }`.
- `allows(resource): boolean` — list filter inside a Remote method; reads `this.ctx.invocation`; true for the owner and outside a Remote call.
- `snapshotFor(principal): { type: 'baseline', owner: true } | { type: 'baseline', owner: false, grants }`.
- `follow(signal)` — Remote stream (see Formats).

### `ctx.sessionController` — `SessionController` (`packages/api/session-controller/src/index.ts:135`)

Service class, `TypertRemoteService` with key `sessionController`, namespace `session`. `static inject = ['agentDefaultModel', 'agents', 'attachments', 'fileUploads', 'fs', 'llm', 'remoteAccess', 'sessions', 'sessionProjections', 'sessionQuery', 'typert', 'typertGateway', 'workspaceRegistry']`. Optional reads: `sessionPersistence`, `sessionProjectionCache`, `sessionTitle`, `agentPresets`, `settings`, `credentials`.

In-process API beyond the Remote methods: `resolveAgent(sessionId): Promise<{ agent } | { error }>` (resolve or cold-resume an ordinary Session) and `workspaceDesktop(): { name, available, fileManager: 'finder' | 'explorer' | 'directory' | null }`.

Init (`index.ts:189-247`) registers the `session` resource resolver, configures the `agent`/`session` lookups and the `agent` Host Context to the cold-resume resolver, registers a file-upload Agent resolver, registers projections `conversationContinuation`, `sessionListMetadata`, `imageLimits`, mounts child plugins `SessionFileReferences`, `SessionMediaReferences`, `SessionSkillCatalog`, `ArchivedSessionGate`, and bridges core events to the `api-session/*` events.

Child services: `ctx.sessionFileReferences` (namespace `fileReferences`, inject `['fileReferences', 'typert']`), `ctx.sessionSkillCatalog` (namespace `skills`, inject `['agents', 'sessionQuery', 'typert', 'workingDirectory']`).

### `ctx.jobController` — `JobController`

Namespace `job`, `static inject = ['jobs', 'typert']`. Remote methods only.

### `ctx.settingsController` and `ctx.credentialsController`

`SettingsController` (namespace `settings`, no inject; reads `ctx.get('settings')` per call) mounts `CredentialsController` (namespace `credentials`; reads `ctx.get('credentials')`). An absent provider gives `gateway/internal` with an actionable message.

### `ctx.terminalController` — `TerminalController` (`packages/api/terminal-controller/src/index.ts`)

Namespace `terminal`, `static inject = ['subprocess', 'sandboxPolicy', 'workingDirectory', 'typert']`. Execution providers are read from the Agent's Context (`agent.ctx.get('subprocess' | 'sandboxPolicy' | 'workingDirectory' | 'sandbox')`). In-process API for the Agent terminal tool:

- `openForAgent(agent, { title, cwd?, cols, rows, policy, preferredShells, env? }, signal): Promise<AgentTerminal>` — sandbox-confined shell (`sandbox.confine` unless mode `danger-full-access`), counted against `maxAgentTerminals`.
- `readScreen(agent, id, { offset, count, maxBytes }): Promise<TerminalScreenPage>`, `inspectActivity(agent, id): Promise<'idle' | 'busy' | 'unknown'>`.
- `AgentTerminal` handle: `id`, `pid`, `info`, `revision`, `changed(after, signal)`, write/signal/mark/close operations; failures are `AgentTerminalError` with code `'user-control' | 'not-running' | 'unavailable'`.

### `ctx.workspaceController`, `ctx.directoryPickerController`

`WorkspaceController` (namespace `workspace`, `static inject = ['remoteAccess', 'typert', 'workspaceRegistry']`) mounts `DirectoryPickerController` (namespace `directoryPicker`, `static inject = ['directoryPicker']`). The child stays pending until a picker backend is composed, so no picking namespace exists without one.

### `ctx.workspaceFiles` — `WorkspaceFiles`

Namespace `workspaceFiles`, `static inject = ['fs', 'sandboxPolicy', 'sessions', 'typert']`. Optional: `sessionPersistence`, `subprocess` (search).

### `ctx.directoryPicker` — abstract `DirectoryPicker` (`packages/host/directory-picker/src/index.ts`)

`capability(): { kind: 'native', pick(signal): Promise<string | null> } | { kind: 'browse', list(path?, signal?): Promise<DirectoryListing>, createDirectory(path, name): Promise<string> }`. The capability object is stable for the service lifetime. Browse failures are `DirectoryPickerError(code, path, message)` with code `'directory-unreadable' | 'directory-exists' | 'directory-create-failed'`.

### `ctx.pluginInventory`, `ctx.productTelemetry`, `ctx.webApp`, `ctx.webStartup`

- `PluginInventoryGateway` (namespace `pluginInventory`, `static inject = ['loader']`); helper `readPluginInventory(ctx)`.
- `ProductTelemetry` (`static inject = ['otel']`): `emit(record)` enqueues one OTLP log record; shutdown drains with a deadline.
- `webApp` (provided by `web-runtime`): `getAdvertisedUrl(): string`.
- `webStartup` (provided by `web-startup`): `{ openBrowser, host?, port?, publicUrl?, trustedHosts: string[], tls?: { certFile, keyFile } }`.

### Client `ctx.remote` — `ClientRemote` (catalog depth)

`$mount(contribution)`, `$on(event, listener)`, `$host: { home: string | undefined, isLoopback }`, `$stream()`, plus one object per mounted namespace with concrete functions. Each unary method resolves to `{ ok: true, value } | { ok: false, error: RemoteError }` and never rejects for a carrier problem; a caller abort folds to `gateway/cancelled`. Arguments whose value is `undefined` are omitted from `args` (`gateway/src/client/index.ts:538`).

## Events

| Event | Mode | Payload | Producer | Consumers |
|---|---|---|---|---|
| `webserver/index-inject` | emit | `(table: IndexInjection[], peer: PeerScope)` | `WebServer.collectIndexInjections` on every index render | Connection (`__DSH_CONNECTION_RECOVERY__`), remote-access (`__DSH_REMOTE_ACCESS__`), client-modules (`__ModuleLoader__` queue script, preload and bootstrap scripts, `__DSH_BOOT__`), ui-theme (prepended listener), shortcuts, document preview, notifications, settings-account, settings-models, inspector. Rows are appended in listener activation order |
| `connection/request` | waterfall | `(req, res, next: () => Promise<void>)` | Connection `/api` route after admission | Any plugin wrapping or refusing shared API requests; default `next` runs the HTTP bridge |
| `api-session/added` | emit | `(summary: SessionSummary)` | session-controller on `session/created`, `agent/created`, `agent/disposed` | Forwarded to Clients |
| `api-session/removed` | emit | `(sessionId)` | on `session/disposed` | Forwarded |
| `api-session/status` | emit | `(sessionId, running: boolean)` | on `agent/status` | Forwarded |
| `api-session/activity` | emit | `(sessionId, updatedAt: number)` | on `session/event` of type `user/message` with `source.kind === 'user'` | Forwarded |
| `api-session/error` | emit | `(sessionId, message: string)` | on `agent/error` and on failed background activation | Forwarded |

Core events this area consumes: `session/event`, `session/created`, `session/disposed` (follow listeners subscribe with `{ global: true }`), `agent/created`, `agent/disposed`, `agent/status`, `agent/error`, `agent/assistant-stream` (`{ agent, frame }`), `agent/pre-step` (waterfall; the archived-session gate returns `{ kind: 'reject' }`), `domain/changed` (Workspace feed), `fs/observed` (file watch feed), `internal/plugin` (typert-loader), `internal/service` (Gateway SRC-claim cache invalidation), and the `sessionProjections.onEventChanged` callback.

Forwarded-event allowlist (`packages/api/remotes/src/remote-events.ts`), the exact legal key set of `ctx.remote.$on` and of the `$events` stream:

- `emit`, global resource: `agent-preset/selected`, `commands/change`, `deepseek-account/session-expired`, `deepseek-account/model-sign-in-required`, `credentials/record-updated`, `credentials/reference-updated`, `goal/activation-changed`, `cordis/request-run`, `cordis/request-run-resolved`, `cordis/dynamic-package`, `cordis/dynamic-retract`, `cordis/inspect-query`, `cordis/inspect-query-resolved`, `llm/adapters-updated`, `llm/models-updated`, `permission-presets/catalog-changed`, `plugin-manager/changed`, `plugin-manager/install-log`, `plugin-manager/install-state`, `plugin-manager/update-state`, `plugin-market/changed`, `settings/document-updated`, `schedule/changed`, `web/providers-changed`.
- `emit`, resource `session` read from the first argument: `api-session/activity`, `api-session/added` (reader takes `summary.sessionId`), `api-session/error`, `api-session/removed`, `api-session/status`.
- `waterfall` (Agent-scoped, answered by an owner Client): `approval/request`, `user-questions/request`.

Ordering: one queue per registered source, then one queue per connected `$events` Client; frames are delivered in emit order. Emit frames are not replayed after reconnect. Pending waterfalls are redelivered to a newly connected owner stream under the same `eventId`.

## Tools

None. This area registers no model-facing tool. `TerminalController.openForAgent`, `readScreen`, and `inspectActivity` are the in-process seam that the Agent terminal tool (another area) consumes.

## Configuration

| Plugin (row id in bundles) | Form | Exported name / key | inject | Config |
|---|---|---|---|---|
| `webserver` | Service class | `webServer` | — | `host: string` (required; one concrete IPv4/IPv6 literal, `%zone` allowed; the unspecified address in any spelling is rejected at load), `port: natural ≤ 65535` (required; 0 = OS-assigned), `tls?: { certFile, keyFile }` (default absent; explicit `null` means no TLS), `compression: 'none' \| 'gzip'` (default `'none'`), `compressionLevel: 0..9` (default 1), `compressionThresholdBytes: natural` (default 1024). Web patch: `host: ctx.webStartup.host ?? '127.0.0.1'`, `port: ctx.webStartup.port ?? 3080`, `tls: ctx.webStartup.tls`, `compression: gzip`, level 1, threshold 1024 |
| `connection` (adjacent) | Function plugin `client-connection` | `connection` | `credentials` | `recovery: { backoffBaseMs 500, backoffFactor 2, backoffMaxMs 10000, generationReadyWarnMs 3000, generationReadyTimeoutMs 15000 }`, `trustedHosts: string[]` (default `[]`; each entry a canonical bare `host` or `host:port`), `cookieMaxAgeDays: natural ≥ 1` (default 30), `maxRequestBodyBytes` (default 300 MiB; must cover `ceil(maxMessageImageBytes × 4/3) + 1 MiB`) |
| `typert` | Service class | `typert` | — | none |
| `typert-loader` | Function plugin `typert-loader` | — | `typert`, `loader` | `packages: string[]` (default `[]`): extra package names that must resolve and export `./typert` |
| `typert-gateway` | Service class | `typertGateway` | `typert`, `remoteAccess` | `websocketHeartbeatIntervalMs: int 1..2147483647` (default 2000), `streamInboxBytes: int ≥ 1` (default 262144), `websocketCompression: 'none' \| 'deflate'` (default `'deflate'`) |
| `remote-access` | Service class | `remoteAccess` | — | none |
| `api-remotes` | Function plugin (`apply`, `inject`) | — | `typertGateway` | none |
| `session-controller` | Service class | `sessionController` | (13 services, see Services) | `nativeOpen?: boolean` (override desktop-opener detection), `listWorkSliceMs: natural ≥ 1` (default 16) |
| `job-controller` | Service class | `jobController` | `jobs`, `typert` | `observeFlushMs: natural ≥ 1` (default 100), `observeMaxFrameBytes: natural ≥ 1` (default 65536) |
| `settings-controller` | Service class | `settingsController` | — | none |
| `terminal-controller` | Service class | `terminalController` | `subprocess`, `sandboxPolicy`, `workingDirectory`, `typert` | `shell?: { path, name, args: string[] = [] }`, `shellCandidates: string[]` (default `['zsh','bash','fish','pwsh','powershell','cmd']`), `maxTerminals` 8, `maxAgentTerminals` 4, `maxCols` 500 (min 2), `maxRows` 200, `scrollback` 1000, `maxBufferedBytes` 2 MiB (min 1024), `maxInputBytes` 65536, `disposeGraceMs` 1000, `unattendedTimeoutMs` 7200000 (0 disables reclamation), `activityPollIntervalMs` 30000, `cleanupRetryMs` 60000 |
| `workspace-controller` | Service class | `workspaceController` | `remoteAccess`, `typert`, `workspaceRegistry` | `documentsDirectory?: string` (fully qualified), `documentsLookupTimeoutMs: natural ≥ 1` (default 10000) |
| `workspace-files` | Service class | `workspaceFiles` | `fs`, `sandboxPolicy`, `sessions`, `typert` | `maxBytes` 2 MiB, `maxFileBytes` 32 MiB, `maxLines` 5000, `maxEntries` 2000, `search: { maxResults 512, maxEntries 100000, graceMs 3000, timeoutMs 30000, stderrMaxBytes 65536 }` |
| (child of `web-runtime`) | Function plugin `frontend-static` | — | `webServer`, `connection` | `distIndex: string` (required; absolute path of `index.html`) |
| `directory-picker` | Function plugin `directory-picker-auto` | mounts a backend | `webServer`, `connection`, `loader` | none |
| (mounted by auto) | Service class `BrowseDirectoryPicker` | `directoryPicker` | — | `maxEntries: natural ≥ 1` (default 1000) |
| (mounted by auto) | Service class `NativeDirectoryPicker` | `directoryPicker` | — | none |
| `open-in-app` | Function plugin `open-in-app` | — | `webServer`, `connection`, `subprocess` | `probeTimeoutMs`, `iconTimeoutMs`, `launchWatchMs`: each int 1..600000, required. Web patch: 10000, 10000, 1000 |
| `plugin-inventory` | Service class | `pluginInventory` | `loader` | none |
| `desktop-product-telemetry` | Service class | `productTelemetry` | `otel` | `endpoint` (default `https://dsh-otel-collector.deepseeksvc.com/v1/logs`), `channel` (default `dsh_otel_report`; sent as header `x-channel`), `serviceName`, `serviceVersion` (required), `compression?: 'none' \| 'gzip'`, `maxExportBatchSize` 512, `maxQueueSize` 2048, `scheduledDelayMillis` 30000, `timeoutMillis` 15000, `exportTimeoutMillis` 20000, `shutdownTimeoutMillis` 21000. Row is disabled unless `profileContext.name === 'desktop'` |
| `web-startup` | Function plugin `web-startup` | provides `webStartup` | `cmdlineArgs` | none (parses CLI flags) |
| `web-runtime` | Function plugin `web-app` | provides `webApp` | `webServer` | `openBrowser: boolean` (default true), `printUrl` (default true), `surfaceContext` (default true), `publicUrl?: string` |

`packages/bundle/web-app/cordis.patch.yml` structure (applied after the `dsh-base` bundle, which already holds the `typert`, `typert-loader`, `typert-gateway`, `remote-access` rows at `packages/bundle/base/cordis.patch.yml:46-58`):

1. Row overrides by id: `system-prompt` (`personaPrefix: You are a coding agent powered by the {{model}} model.`) and `session-query-sqlite` (`path: ':memory:'`, `openAt: never`).
2. One `insert:` list of about 110 rows: Host rows (`open-in-app`, `workspace`, `session-reference`, `file-reference-local`, `session-stats`, `session-turn-outline`, `directory-picker`, `plugin-inventory`, `session-controller`, `job-controller`, `terminal-controller`, `workspace-files`, `schedule`, `settings-controller`, `mcp-manager` with `inject: [credentials]`, `workspace-controller`, `cordis-host-runner`, `cordis-inspect-providers`, `web-startup`, `webserver`, `web-runtime`, `harness-dev-context`, `client-hmr`, `message-feedback` with `maxNoteBytes: 8192`, and others) followed by the browser roster (`modules`, `connection`, `file-upload`, `api-remotes`, and the `ui-*` rows). Rows whose package declares `dsh.client` are the roster that the `modules` node half scans into `window.__DSH_BOOT__`.
3. Disable-by-id rows moving the agent plane behind presets: `tool-plugin-manager`, `tool-bash`, `tool-pwsh`, `tool-jobs`, `tool-fs`, `tool-fs-search`, `skill-filesystem`, `tool-skill`, `command-goal`, `tool-goal`, `plan-mode`, `compaction-basic`, `command-compact`, `tool-result-pruner`, `tool-subagent-control`, `tool-subagent`, `tool-subagent-fork`, `workflow-ptc`, `tool-workflow`, `agent-instructions`, `tool-todo`, `tool-web` — each `disabled: true`.
4. A final `insert:` of `agent-preset-registry` with `config: { default: standard }`.

Patch syntax used: `!!js <expression>` values under `config` and `disabled` (expressions read `ctx.webStartup.*`, `ctx.get('profileContext')?.name`, `process.env.*`, `dshHomePath(...)`); a row-level `inject: [webStartup]` so the Loader resolves the expression only after that service exists. A patch replaces the targeted row's whole `config`.

## Formats

### HTTP listener and route table

One listener on `host:port` (default `127.0.0.1:3080`), plain HTTP or HTTPS (`--tls-cert`/`--tls-key`). Match order for a request path: exact table, then the longest matching prefix (`path === prefix` or starts with `prefix + '/'`), then the fallback seat, else `404` with an empty body (`webserver/src/index.ts:655-664`). A rejected handler promise is logged and answered `400` (or the socket is destroyed when headers were already sent). Upgrade requests use a separate exact table; an unmatched upgrade destroys the socket.

| Method and path | Owner | Auth | Behavior |
|---|---|---|---|
| `GET /` and `GET /index.html` | frontend-static (fallback resource) | launch token or browser cookie | Rendered `index.html`, `content-type: text/html; charset=utf-8`, no cache headers |
| `GET <any other path>` | frontend-static (fallback resource) | none (public assets) | Dist file with `cache-control: no-cache` and weak ETag `W/"<base64url sha1>"`; `304` on matching `If-None-Match`; `404` for missing or non-file; `403` for traversal outside the dist root; unknown extension is `application/octet-stream`; non GET/HEAD is `405` |
| `GET /connect?token=…[&interactions=answer\|none]` | Connection (exact) | launch token | Mints an API credential, `302` to `./api/remote.mux` |
| `POST /api/<namespace>/<method>` | Connection prefix `/api` → Gateway interceptor | cookie + fence | Unary Remote call |
| `POST /api/$events/result` | Gateway | cookie + fence, owner, `interactions=answer` | Client answer to one forwarded waterfall |
| `GET` (Upgrade) `/api/remote.mux` | Gateway (upgrade route) | cookie + fence | WebSocket mux; rejection is a raw `HTTP/1.1 401 Unauthorized`, `403 Forbidden`, or `409 Conflict` with a text body and `Connection: close` |
| `GET, HEAD /api/file?path=<abs>&v=<version>` | session-controller (exact Fetch route) | owner only | File bytes for media references; `302` to `?path=…&v=<current>` when `v` differs; headers `X-Content-Type-Options: nosniff`, `Content-Security-Policy: sandbox; default-src 'none'`, `Cache-Control: private, max-age=31536000, immutable` (errors `private, no-store`); cap is `attachments.imageLimits.maxImageBytes`; status map `FS_NOT_FOUND` 404, `FS_NOT_REGULAR_FILE`/`FS_PERMISSION_DENIED`/`FS_SANDBOX_DENIED` 403, `FS_TOO_LARGE` 413, `FS_ABORTED` 499 |
| `POST /api/session/uploadFileBinary` | client/file-upload (exact Fetch route, streaming body) | owner only | Raw upload returning a receipt (other area) |
| `GET /api/plugin-market/detail-file`, `GET /api/plugin-manager/detail-file` | boot packages | owner only | Other area |
| `GET /api/present.host`, `GET, POST /api/present.open`, `GET /api/changes.summary`, `GET, POST /api/changes.open`, `GET /api/changes.diff` | client/ui-deliverables | owner only | Other area; `present.host` returns `sessionController.workspaceDesktop()` |
| `GET /plugins/<id>/client.js` and package assets | client/modules (prefix resource `/plugins`) | none | Client plugin bundles (other area) |
| `GET /plugins/events` | client/hmr (exact) | — | SSE hot-reload feed (other area) |
| `GET /open-in-app/apps` | open-in-app (exact) | `requestRejection` | `{ "apps": ["vscode", …] }`, `cache-control: no-store` |
| `GET /open-in-app/icon/<id>` | open-in-app (prefix) | `requestRejection` | Icon bytes, `cache-control: public, max-age=3600`; `404 {code:'not-found',message}` |
| `POST /open-in-app/open` | open-in-app (exact) | `requestRejection` | Body `{ "app": string, "path": string }` (`application/json`, ≤ 64 KiB). `200 {ok:true}`; `400 bad-request`; `404 not-found` (not a directory); `413 payload-too-large`; `415 unsupported-media-type`; `502 launch-failed` |
| `GET /oauth/callback` | credentials/deepseek-account (exact, only during a login attempt) | state parameter | Other area |

Every `/api` request passes, in order: (1) the trust fence, `403 forbidden` on failure; (2) authentication, `401 unauthorized`; (3) the `connection/request` waterfall; (4) the bridge. The bridge buffers the body up to `maxRequestBodyBytes` (over-limit: `413` with `connection: close`) except for streaming exact routes, converts to a Fetch `Request`, aborts on client disconnect, and writes the response with backpressure (`http-bridge.ts:37-127`).

gzip (when `compression: gzip`): negotiated between `gzip` and `identity` only; never for `text/event-stream` or responses with `content-range`; always eligible for `multipart/form-data`; otherwise the standard compressible-type filter with the byte threshold.

### Trust fence (`api-request-trust.ts:121-151`)

A request is trusted when all hold:

1. `Host` header parses and its hostname is loopback (`localhost`, `[::1]`, any `127.x.y.z`), or matches a `trustedHosts` entry (entry with explicit port matches exact `host:port`; port-less entry matches any port; comparison after WHATWG URL normalization under the listener protocol), or equals the listener's bind IP literal (any port, `%zone` ignored).
2. `Sec-Fetch-Site` is not `cross-site`.
3. `Origin`, when present, is `http(s)` and its host equals the `Host` header normalized under the Origin's scheme. The literal `null` and other schemes are refused.

### Authentication model (`browser-auth.ts`)

- Signing secret: 32 random bytes, stored once in the credential provider under `credentialKey('client-connection', 'browser-session')` as record `{ kind: 'grant', payload: { version: 1, secret: <base64url, 43 chars> } }`. Created on first activation with `modifyRecord`; an unsupported record format throws.
- Launch token: 32 random bytes, base64url, minted once per process (keyed by the root Context, so a Connection reload keeps it). `authenticatedUrl(base)` sets query parameter `token`. The startup line is `dsh web: <url>?token=<launch token>`.
- Cookie name: `dsh-auth-` + base64url(SHA-256(audience)). Audience: for HTTP the normalized `Host` authority (`host[:port]`); for HTTPS the origin (`https://host[:port]`).
- Cookie value: `v<version>.<body>.<sig>` where `body = base64url(JSON payload)` and `sig = base64url(HMAC-SHA256(secret, body))` (signature over the base64url text). Browser payload: `{ "version": 1, "authority", "issuedAt", "expiresAt" }` (ms). API payload: `{ "version": 2, "authority", "id": <PeerId>, "issuedAt", "expiresAt" }`.
- Cookie attributes: `<name>=<value>; Max-Age=<seconds>; Path=/; Expires=<UTC string>; HttpOnly; SameSite=Strict` plus `; Secure` when the listener itself serves TLS.
- Verification: signature compared in constant time; `payload.authority` equals the request audience; `issuedAt ≤ now < expiresAt`; `expiresAt - issuedAt ≤ maxAge`. base64url must be canonical (re-encoding round-trips).
- Index flow (`authorizeIndex`, `:263`): a request with any `token` parameter is served only as an exchange. `GET /` with exactly one valid token → `303`, `location: ./`, `cache-control: no-store`, `referrer-policy: no-referrer`, `set-cookie`. `GET /` with a wrong token but a valid cookie → the same `303` without a cookie. Anything else with a token → `401`. Without a token: valid v1 cookie → serve; else `401` with body `dsh web authentication required; reopen the URL printed by dsh web.\n` (`content-type: text/plain; charset=utf-8`, `cache-control: no-store`; empty body for HEAD).
- API client flow (`authorizeConnect`, `:314`): `GET /connect?token=<t>&interactions=<answer|none>` (default `none`; declared more than once or another value → `400` `interactions must be declared once as answer or none\n`). Success creates a new owner Peer with that `interactions`, signs a v2 cookie carrying its id, and answers `302` with `location: ./api/remote.mux`. The Peer exists until its one WebSocket closes (a second socket for the same Peer gets `409`); HTTP calls with the cookie work while the Peer is alive.
- Admission (`rpc-host.ts:129`): v1 cookie → `browserPeer`; v2 cookie with a live Peer id → that Peer; otherwise `401`.

### Index rendering and boot injections

`frontend-static` reads `dist/index.html`, calls `webServer.renderIndex(html, peer)`, then inserts `<base href="./">` immediately after the opening `<head …>` tag, ahead of every injected reference. `renderIndexInjections` (`webserver/src/injections.ts:96`) renders rows in table order: head rows directly after `<head …>` (prepended to the document when there is no head), body rows directly after `<body …>` (appended when there is no body), then the tail script `<script>(globalThis.__DSH_BOOT_READY__ ??= Promise.withResolvers()).resolve()</script>` after the last body row.

Row kinds and markup:

| Row | Markup |
|---|---|
| `{ kind: 'global', name, value }` | head: `<script>globalThis[<JSON name>] = <JSON value>\|undefined</script>` with every `<` written as `<` |
| `{ kind: 'script', placement, text }` | `<script>text</script>` |
| `{ kind: 'script-src', placement, src }` | `<script src="…"></script>` (attribute-escaped) |
| `{ kind: 'script-preload', src }` | head: `<link rel="preload" as="script" href="…">` |
| `{ kind: 'style', text }` | head: `<style>text</style>` |
| `{ kind: 'html', placement, html }` | raw fragment |

Globals a page receives in the web profile: `__DSH_CONNECTION_RECOVERY__` (resolved recovery config), `__DSH_REMOTE_ACCESS__` (`{type:'baseline',owner:true}` for the browser Peer), `__DSH_BOOT__` (client module graph), `window.__ModuleLoader__` (queue script), `__DSH_SHORTCUTS_CONFIG__`, `__DSH_DOCUMENT_PREVIEW_CONFIG__`, notification, contact and onboarding config globals, theme rows, and `__DSH_BOOT_READY__`.

### Unary RPC wire (Connection + Gateway)

Request: `POST /api/<namespace>/<method>`; header `content-type: application/json` (media type compared case-insensitively, parameters ignored); body

```json
{ "type": "client-request", "rpcId": "<uuid>", "method": "<namespace>/<method>", "payload": { "args": { "<wire field>": <value>, … } } }
```

Endpoint segments match `/^[A-Za-z0-9_$.-]+$/`, never empty, `.` or `..`. The Gateway claims only two-segment endpoints (plus `$events/result`). `payload` must be a plain object with exactly one key `args`, itself a plain object.

Responses (HTTP status 200 for every decoded envelope):

```json
{ "type": "server-response", "rpcId": "<same>", "result": { "ok": true, "value": <json> } }
{ "type": "server-response", "rpcId": "<same>", "result": { "ok": false, "error": { "code": "<domain>/<reason>", "message": "…", "details": { … } } } }
```

A void result has no `value` key. Transport-level answers outside the envelope: `404 not found` (unclaimed endpoint, non-POST), `415 content type must be application/json`, `400 body is not JSON`, `500 handler failure: <text>` (the handler itself threw), `401 unauthorized`, `403 forbidden`, `413`. An envelope that fails validation gets a 200 envelope with `code: 'gateway/bad-request'`, `message: 'invalid client-request message'`, `details: { issues }` and `rpcId` echoed when it was a string, else `invalid-request`. `method` not equal to the URL endpoint gives `gateway/bad-request` with `details: { issues: [] }`.

Binary results (`Uint8Array` anywhere in a unary result): the response is `multipart/form-data` with one part per byte value named `bytes-<index>` (raw bytes) and a final text part `metadata` holding the JSON envelope plus `"attachments": [{ "path": [<result-relative keys/indices>], "codec": "bytes", "part": "bytes-<index>" }]`. In `result.value` each byte value is replaced by `null` at that path. The Host builds the body with `FormData` and `Blob` (`rpc-host.ts:376-393`), so each byte part carries a `filename` in its `Content-Disposition` and the `metadata` part does not; the Client parses with `Response.formData()` and requires byte parts to be `Blob` values and `metadata` to be a string. The Client rejects duplicate part names, leftover parts, a non-`null` placeholder, and an empty `attachments` array (`client/rpc.ts`). `workspaceFiles/readBytes` is the shipped user (`path: ["data"]`).

### Stream mux wire (`/api/remote.mux`, `stream-protocol.ts`, `stream-server.ts`)

WebSocket text frames only (a binary frame closes with `1003 text messages required`). Each frame is one JSON object with exactly the listed keys.

Client → Host:

```json
{ "type": "open",   "streamId": "<non-empty>", "endpoint": "<namespace>/<method> | $events", "payload": { "args": { … } } }
{ "type": "item",   "streamId": "…", "value": <lossless json> }      // "value" omitted for a top-level undefined
{ "type": "end",    "streamId": "…" }                                // uplink half-close
{ "type": "cancel", "streamId": "…" }
```

Host → Client:

```json
{ "type": "item",  "streamId": "…", "value": <json> }               // "value" may be absent
{ "type": "error", "streamId": "…", "error": { "code": "…", "message": "…", "details": { } } }   // terminal
{ "type": "end",   "streamId": "…" }                                // terminal
```

Rules:

- An unparsable frame or a duplicate `open` for a live `streamId` closes the socket with `1008 invalid Remote stream request`. `item`, `end`, `cancel` for an unknown or finished stream are dropped.
- The Host sends Ping every `websocketHeartbeatIntervalMs`; a Pong, any received frame, or a downlink write that was queued counts as activity; after two intervals without activity the socket is terminated.
- With `websocketCompression: 'deflate'` the Host negotiates `permessage-deflate` (zlib level 1) and compresses only frames whose JSON text length is ≥ 1024 characters. `'none'` accepts the same upgrade without the extension.
- Close codes used by the Host: `1001 peer left` (Peer scope disposed), `1011 Remote stream failure could not be delivered`. The Client uses `4000 reconnect requested`, `4002 invalid Remote stream frame`, `1000 disposed`.
- Per logical stream the Host buffers at most `streamInboxBytes` of uplink frame bytes (UTF-8 length of the whole frame text). Overflow fails that stream with `gateway/uplink-overflow`; an `item` after `end` fails it with `gateway/protocol`; neither closes the socket.
- `invocation.uplinkWindow = { maxBytes: streamInboxBytes, frameOverheadBytes }` where `frameOverheadBytes = utf8len('{"type":"item","streamId":"<id>","value":null}') - 4`.
- On socket close every active stream is stopped (signal aborted, uplink failed) and the server waits for all iterators to return.
- A stream cancelled by the Client receives no terminal frame. A stream aborted with a `RemoteError` as the reason (uplink violation or rejected uplink item) receives that error frame.

### Forwarded events (`$events`)

Open: `{ "type": "open", "streamId", "endpoint": "$events", "payload": { "args": {} } }`. Requires `peer.interactions === 'answer'` (`gateway/interactions-forbidden` otherwise) and a registered source (`gateway/service-unavailable`). Items:

```json
{ "type": "ready", "clientId": "<uuid>", "host": { "home": "<os home directory>" } }      // always first
{ "type": "emit", "event": "<name>", "args": [ … ] }
{ "type": "waterfall", "event": "<name>", "eventId": "<uuid>", "agentId": "<session id>", "request": { … } }
{ "type": "cancel", "eventId": "<uuid>" }
```

`request` is the waterfall's request object without its `agent` and `signal` properties. The answer is a unary call `POST /api/$events/result` with `payload.args = { "clientId", "eventId", "outcome" }` where `outcome` is `{ "kind": "next" }`, `{ "kind": "result", "value"?: <json> }`, or `{ "kind": "rejected", "error": { "name", "message", "code"?, "details"? } }`. Keys are exact; extra keys are refused.

### Error vocabulary

`RemoteError(code, message, details)` is the only failure class; identification is structural (`isDSHRemoteError === true` and a string `code`). Codes:

- Carrier (protocol): `gateway/bad-request { issues? }`, `gateway/cancelled {}`, `gateway/internal {}`.
- Gateway infrastructure, details `{ endpoint, field? }`: `gateway/ambiguous-endpoint`, `gateway/arguments-invalid`, `gateway/binding-invalid`, `gateway/context-failed`, `gateway/context-not-found`, `gateway/context-unavailable`, `gateway/definition-unavailable`, `gateway/input-invalid`, `gateway/interactions-forbidden`, `gateway/invocation-unavailable`, `gateway/lookup-failed`, `gateway/lookup-not-found`, `gateway/lookup-unavailable`, `gateway/method-unavailable`, `gateway/peer-disposed`, `gateway/protocol`, `gateway/provider-mismatch`, `gateway/result-invalid`, `gateway/service-unavailable`, `gateway/signature-invalid`, `gateway/uplink-overflow`. Message format: `typert gateway: <endpoint>: <text>`.
- Access: `remote-access/denied { action, reason }` with reason `no-allow`, `policy-failed`, `resource-invalid`, or a policy-supplied string.
- Session: `session/not-found { sessionId }`, `session/observation-ended`, `session/wait-timeout`, `session/provider-credentials-unavailable`, `session/provider-models-unavailable { provider }`, `session/model-unavailable { provider, model }`, `session/conflict { sessionId, requestedCwd, existingCwd? }`, `session/projections-unavailable`, `session/writer-held { sessionId }`, `session/agent-busy { reason }`, `session/invalid-time-zone { value }`, `session/workspace-attach-failed { sessionId, workspaceId }`, `agent-preset/conflict { sessionId, requestedPreset }`, `session/attachment-invalid { reason }`, `session/queue-item-not-found { itemId }`, `session/steer-unavailable { itemId }`, `session/title-invalid { sessionId }`, `session/fork-unavailable { sessionId }`, `session/migration-required { sessionId }`, `subagent/not-found { parentSessionId, childSessionId }`, `subagent/catalog-diagnostic { parentSessionId, childSessionId, reason: 'corrupt' | 'unsupported' | 'unavailable' }`, `subagent/unauthorized { childSessionId }`.
- Job: `job/not-found { sessionId, jobId }`.
- Settings: `settings/rejected { ns }`, `settings/conflict { ns, expected, actual }`, `credential/rejected { ref }`.
- Terminal: `terminal/unavailable {}`, `terminal/control-unavailable { reason: 'read-only' | 'not-running' }`, `terminal/limit-reached { limit }`.
- Workspace: `workspace/not-found { workspaceId }`, `workspace/invalid-path { path }`, `workspace/name-conflict { name }`, `workspace/session-active { sessionId, activity }`, `workspace/move-invalid { workspaceId, sessionId, beforeSessionId? }`, `directory-picker/unavailable { capability }`, `directory-picker/unreadable { path }`, `directory-picker/exists { path }`, `directory-picker/create-failed { path }`.
- Workspace files: `workspace-file/search-failed`, `workspace-file/watch-unsupported { path }`, `workspace-file/not-found { path }`, `workspace-file/outside-workspace { path }`, `workspace-file/too-large { path, limit }`, `workspace-file/not-text { path }`, `workspace-file/not-regular-file { path, kind }`, `workspace-file/not-directory { path, kind }`.

An unclassified exception from a method becomes `gateway/internal` with the exception message and empty details.

### Remote API catalog

"Remote" means one public instance method of a Host Cordis service, marked `@Remote` (direct receiver) or `@RemoteScope(key)` (receiver resolved from a scoped Context), exported as endpoint `<namespace>/<method>`. The wire `args` object has one key per business parameter in declaration order: the parameter name, or the lookup's wire field when the parameter type is a lookup Host type (`Agent` → `agentId`, `Session` → `sessionId`, `WorkspaceFileScope` → `workspaceFileScopeId`). A trailing `signal: AbortSignal` never appears on the wire. A parameter typed `T | undefined` may be omitted. In the tables, "→" is the unary result and "⇒" is the stream item type; `?` marks optional fields.

Namespace `session` (service `sessionController`):

| Endpoint | `args` | Result |
|---|---|---|
| `session/list` | `{ _request: { cursor? } }` (the field is literally `_request`) | → `{ items: SessionSummary[] }` sorted by `updatedAt` descending, filtered by `allows({kind:'session',id})` |
| `session/search` | `{ request: { query } }` | → `{ items: [{ sessionId, snippet }], hasMore }`; at most 20 items, snippet ≤ 240 code points |
| `session/create` | `{ request: { workspaceId?, cwd?, sessionId?, agentPreset? } }` | → `{ sessionId, agentPreset? }` |
| `session/selectModel` | `{ request: { sessionId, provider, model, reasoningEffort? } }` | → `{ selected: { provider, model, reasoningEffort? } }` |
| `session/initializeDefaultModel` | `{}` | → void |
| `session/modelCatalog` | `{}` | → `{ default, routableProviders, groups: [{ id, name, models: [{ id, name, description?, reasoning?: { efforts: [{ id, name, description? }], defaultEffort? }, badge? }] }], failures: [{ id, name, message }] }` |
| `session/canOpenWorkspacePath` | `{}` | → boolean |
| `session/openWorkspacePath` | `{ request: { path, action?: 'reveal', application? } }` | → `{ opened: true }` |
| `session/workspacePathApplications` | `{ request: { path } }` | → `NativeFileApplication[]` (empty when desktop opening is unavailable) |
| `session/rename` | `{ request: { sessionId, title } }` | → `{ title, seq }` |
| `session/fork` | `{ request: { sessionId, atSeq?, allowMigration? } }` | → `{ sessionId }` (new id `session-<uuid>`) |
| `session/prompt` | `{ request: { requestId, sessionId, mode: 'queue' \| 'steer', content: PromptContentPart[], clientTimeZone? } }` | → `{ accepted: true }` |
| `session/attachment` | `{ request: { sessionId, attachment: ImageAttachmentRef } }` | → `{ attachment, data: <base64> }` |
| `session/updateQueue` | `{ request: { sessionId, itemId, action: { kind: 'edit', content: TextBlock[] } \| { kind: 'remove' } \| { kind: 'steer' } } }` | → `{ accepted: true }` |
| `session/cancel` | `{ request: { sessionId } }` | → `{ accepted: true }` |
| `session/events` and `session/page` (deprecated alias) | `{ request: { address, throughSeq?, beforeSeq?, maxMessages?, turnWindow?: { minMessages, minTurns } } }` | → `{ cursor, records: [{ type: 'event', event }], hasMore }` |
| `session/observeEvent` | `{ request: { address } }` | ⇒ `{ type: 'ready' }` then `{ type: 'event', event }` |
| `session/observeProjections` | `{ request: { sessionId } }` | ⇒ `{ type: 'ready' }` then `{ type: 'projection', seq, changes: [{ key, val }] }` |
| `session/state` | `{ request: { sessionId } }` | → `SessionState` |
| `session/observeState` | `{ request: { sessionId } }` | ⇒ complete `SessionState` replacements, current state first |
| `session/wait` | `{ request: { sessionId, timeoutMs?, afterSeq?, maxMessages? } }` | → `{ reason: 'idle' \| 'input-required' \| 'timeout', state, output: { records, truncated } }` |
| `session/follow` | `{ request: { address, activate?, assistantStream?: true, maxMessages?, turnWindow? } }` | ⇒ `SessionFollowFrame` (below) |
| `session/projections` | `{ request: { sessionId } }` | → `{ kind: 'sequenced', asOfSeq, values }` \| `{ kind: 'migration-required', values }` \| `null` |
| `session/control` | `{}` | ⇒ `{ type: 'baseline', value: { projections: { <sessionId>: { asOfSeq, values } } } }` then `{ type: 'projection', sessionId, seq, changes }` |

Shared shapes:

- `SessionAddress = { kind: 'session', sessionId } | { kind: 'subagent', parentSessionId, childSessionId, mode: 'one-shot' | 'continuable' | 'unknown' }`.
- `SessionSummary = { agentAvailable, formatStatus?: 'current' | 'migration-required', sessionId, updatedAt, running, blank, parentSessionId?, origin?: 'subagent', cwd?, projections?: { kind: 'cached' | 'sequenced', asOfSeq, values } }`.
- `PromptContentPart = { type: 'text', text } | { type: 'image', mediaType, data, name? } | { type: 'file', receiptId }`.
- `SessionWireEvent = { type, seq, time, data, ignorable?: true, sourceEventSeqs?, surfaceOp? }` — the committed session event object as stored; this couples the browser to the session event vocabulary.
- `SessionWireHeader = { version, id, createdAt, cwd?, parentSession?, isSeeded, origin?, delegationDepth?, agentPreset? }` (the observation header spread as-is).
- `SessionState = { cursor, active, running, queue: SessionQueuedItem[] | null, pendingInput: ('approval' | 'question' | 'other')[] }`; `SessionQueuedItem = { id, placement: 'queued' | 'steering' | 'context', rpcId?, content }`.
- `SessionFollowFrame`:
  - `{ type: 'snapshot', header, cursor, records, hasMore, projections: { asOfSeq, values }, assistantStream?: { revision, activeAttempt?: { attemptId, startedAfterSeq, turn, step, nextIndex, stream: JsonValue[] } } }` — exactly once, first.
  - `{ type: 'event', event: SessionWireEvent }` — gap-free, starting at `cursor + 1`.
  - `{ type: 'assistant-stream', frame }` with `frame` one of `{ type: 'start', attemptId, revision, startedAfterSeq, turn, step }`, `{ type: 'chunk', attemptId, revision, index, time, chunk }`, `{ type: 'end', attemptId, revision, index, outcome: { kind: 'committed', eventType: 'assistant/message' | 'assistant/attempt', seq } | { kind: 'abandoned' } }`.

Namespace `fileReferences`: `fileReferences/list` `{ agentId, query }` → `FileReferenceCandidate[]` (resumes a cold Session through the `agent` lookup). Namespace `skills`: `skills/list` `{ request: { sessionId } }` → `{ skills: [{ name, path?, description, whenToUse?, modelInvocable }] }` (non-activating).

Namespace `job`:

| Endpoint | `args` | Result |
|---|---|---|
| `job/list` | `{ request: { sessionId } }` | ⇒ `{ type: 'rows', jobs: JobView[] }` whole-set frames |
| `job/follow` | `{ request: { sessionId?, jobId, from? } }` | ⇒ `{ type: 'opened', job, from }`, then `{ type: 'output', chunks: [{ at, text, channel?, gapBefore? }], next, lossy?: true }`, then one `{ type: 'status', job }` and normal end |
| `job/kill` | `{ request: { sessionId, jobId } }` | → `{ outcome: 'requested' \| 'already-finished' }` |

`JobView = { id, kind, label, owner?, outputLimitBytes?, status: 'running' | 'stopping' | 'completed' | 'killed' | 'failed', progress?, detail?, startedAt, finishedAt?, output: { total, earliest, spillPaths? } }`.

Namespaces `settings` and `credentials`:

| Endpoint | `args` | Result |
|---|---|---|
| `settings/describe` | `{}` | → `{ writable, hasDocument: true, namespaces: SettingsNamespaceView[] }` |
| `settings/update` | `{ ns, patch: Record<string, JsonValue>, expectedRevision? }` | → `SettingsNamespaceView` |
| `settings/replace` | `{ ns, section, expectedRevision? }` | → `SettingsNamespaceView` |
| `settings/mutate` | `{ ns, ops: ({ op: 'set', path: string[], value } \| { op: 'unset', path: string[] })[], expectedRevision? }` | → `SettingsNamespaceView` |
| `settings/openSettingsDocument` | `{}` | → `{ opened: true }` |
| `credentials/describe` | `{ refs: string[] }` (≤ 64, each `/^[A-Za-z_][A-Za-z0-9_]*$/`) | → `Record<ref, { configured, source?, writable, masked? }>` |
| `credentials/set` | `{ ref, value }` (non-empty) | → void |
| `credentials/unset` | `{ ref }` | → void |

`SettingsNamespaceView = { ns, autoGenerate, schema, value, base?, user?, applies: 'live', secrets: [{ path: string[], set: boolean }], revision }`; every read uses `redactSecrets: true`; `schema` is the serialized schemastery schema.

Namespace `terminal`:

| Endpoint | `args` | Result |
|---|---|---|
| `terminal/environment` | `{ agentId }` | → `{ cwd, maxInputBytes, maxBufferedBytes, maxCols, maxRows, scrollback }` |
| `terminal/shells` | `{ agentId }` | → `[{ path, args, name }]`, default first, one per executable name |
| `terminal/list` | `{ sessionId }` | → `WebTerminalInfo[]` (no Agent activation) |
| `terminal/create` | `{ agentId, request: { shellPath?, id, cols, rows } }` | → `WebTerminalInfo` (idempotent per `id`; `id` matches `/^[\w-]{1,128}$/`) |
| `terminal/watch` | `{ sessionId }` | ⇒ `WebTerminalInfo[]` whole sets |
| `terminal/retain` | `{ sessionId, id }` | ⇒ `{ type: 'retained' }` then stays open as a hold |
| `terminal/attach` | `{ agentId, id }` | ⇒ `TerminalFrame`; uplink `TerminalInput` |
| `terminal/rename` | `{ agentId, id, title }` (1–120 chars after trim) | → void |
| `terminal/close` | `{ agentId, id }` | → void (idempotent) |

`WebTerminalInfo = { id, title, shell, cwd, cols, rows, state: 'running' | 'exited' | 'failed', exitCode: number | null, error?, origin: 'user' | 'agent', control: 'user' | 'agent', sandboxMode?: 'read-only' | 'workspace-write' | 'danger-full-access' }`. `TerminalFrame = { type: 'snapshot', sequence, screen, info, writable, inputWindow? } | { type: 'output', sequence, data } | { type: 'state', info, writable } | { type: 'ack', sequence, refusal?: 'read-only' | 'not-running' }`. `TerminalInput = { type: 'write', sequence, data, typed? } | { type: 'resize', sequence, cols, rows }`.

Namespaces `workspace` and `directoryPicker`:

| Endpoint | `args` | Result |
|---|---|---|
| `workspace/create` | `{ request: { path } }` | → `{ workspace: WorkspaceView, created }` |
| `workspace/initializeDefault` | `{}` | → `{ workspace }` or void |
| `workspace/rename` | `{ request: { workspaceId, title } }` | → `{ workspace }` |
| `workspace/delete` | `{ request: { workspaceId } }` | → `{ deleted: true }` |
| `workspace/insertBefore` | `{ request: { workspaceId, beforeWorkspaceId? } }` | → `{ workspaceIds }` |
| `workspace/insertSessionBefore` | `{ request: { workspaceId, sessionId, beforeSessionId? } }` | → `{ workspace }` |
| `workspace/archiveSession` | `{ request: { sessionId, stopActivity? } }` | → `{ archivedSessionIds }` |
| `workspace/unarchiveSession` | `{ request: { sessionId } }` | → `{ archivedSessionIds }` |
| `workspace/pinSession`, `workspace/unpinSession` | `{ request: { sessionId } }` | → `{ pinnedSessionIds }` (most recently pinned first) |
| `workspace/follow` | `{}` | ⇒ `{ type: 'baseline', value: { items, archivedSessionIds, pinnedSessionIds } }` then `replace { value }`, `upsert { workspace }`, `remove { workspaceId }`, `order { workspaceIds }`, `archived { archivedSessionIds }`, `pinned { pinnedSessionIds }` |
| `directoryPicker/pick` | `{}` | → string or `null` (cancelled) |
| `directoryPicker/list` | `{ path? }` | → `{ path, home, crumbs: [{ name, path, hidden }], entries: [{ name, path, hidden }], truncated }` |
| `directoryPicker/createDirectory` | `{ path, name }` | → created absolute path |

`WorkspaceView = { workspaceId, path, title, sessionIds, createdAt, updatedAt }` (ISO-8601 strings).

Namespace `workspaceFiles` (lookup field `workspaceFileScopeId` is a Session id):

| Endpoint | `args` | Result |
|---|---|---|
| `workspaceFiles/read` | `{ workspaceFileScopeId, path, range: { offset?, limit? } }` | → `{ absolutePath, version, bytes?, offset, text, lines, eof }` |
| `workspaceFiles/readBytes` | `{ workspaceFileScopeId, path, options: { range?: { offset?, length? }, baseFile? } }` | → `{ absolutePath, version, bytes?, offset, data: <binary attachment>, eof }` |
| `workspaceFiles/stat` | `{ workspaceFileScopeId, path }` | → `{ absolutePath, version, bytes? }` |
| `workspaceFiles/list` | `{ workspaceFileScopeId, path }` | → `{ path, entries: [{ name, type: 'file' \| 'directory' \| 'other', size? }], truncated }` |
| `workspaceFiles/search` | `{ workspaceFileScopeId, request: { query, excludedPaths, includeHidden, respectGitignore } }` | → `{ matches: [{ path, type }], truncated, incomplete }` |
| `workspaceFiles/changes` | `{ workspaceFileScopeId, path }` | ⇒ `{ kind: 'ready' }` then `{ kind: 'change', change: { absolutePath, version } \| { absolutePath, absent: true } }` |

Other namespaces in this area: `remoteAccess/follow` `{}` ⇒ `{ type: 'baseline', owner: true }` (owner: only frame, stream stays open) or `{ type: 'baseline', owner: false, grants: [{ resource, actions: string[] }] }` then `{ type: 'upsert', grant }` / `{ type: 'remove', resource }`; `pluginInventory/list` `{}` → `{ managementAvailable?, entries: [{ entryId, moduleName, meta?, enabled, fiberPhase: 'pending' | 'loading' | 'active' | 'failed' | 'unloading' | null, diagnostic? }], agentPresets?: [{ id, name?, isDefault, broken?, rows: [{ entryId, moduleName, meta?, enabled: boolean | 'conditional', condition?, fiberPhase }] }] }`.

Namespaces mounted by the Client assembly but owned by other areas (the React client calls them; a compatible host must at least answer them): `productAnalytics`, `agentPresets`, `commands`, `agentTeams`, `account`, `goals`, `llm`, `dynamicCordisRunner`, `schedule`, `pluginManager`, `mcpManager`, `pluginMarket`, `pluginRegistryProbe`, `toolResults`, `messageFeedback`, `sessionFeedback`, `fileUploads`, `sessionReferenceResolver`, `permissionPresets`, `subagents`, `officeKit`, `userQuestions`, `web`.

### Typert artifacts

Per contributing package, written to `lib/` at build time:

| File | package.json export | Contents |
|---|---|---|
| `typert.host.js` / `.d.ts` | `./typert` | `export const TYPERT = { package, face: 'host', schemas: [{ name, create }], model: { services, events, objects }, invocations }` plus one named Zod schema factory per exported data type |
| `typert.remote-client.js` / `.d.ts` / `.d.ts.map` | `./remote` | `export const TYPERT_REMOTE = createTypertRemoteInfo({ package, methods: { '<ns>/<method>': { service, description?, implementation?, mode?, invocation, scope?, parameters: [{ name, wire?, description?, source: 'json' \| 'lookup', lookup?, acceptsUndefined?, codec, strictCodec }], uplink?, cancellation?, result } } }, z)` and `export default TYPERT_REMOTE`; declarations merge `TypertRemoteNamespaceMap` / `TypertRemoteScopeMap` |
| `typert.client.js` / `.d.ts` | `./client/typert` | Client-face schemas and reflection |

A strict codec is `{ mode: 'strict', typeSymbol: '<package>#<TypeName>', create: () => ZodType, description?, jsonSchema?, jsonSchemaError?, decode?, encode? }`. `encode(value, writeBytes)` and `decode(value)` exist only for results containing `Uint8Array`. Descriptor ids: `<package>#<namespace>/<method>` (strict) or `src:<serviceKey>#<endpoint>` (source fallback). `codec` accepts and strips undeclared object fields; `strictCodec` rejects them and is selected only by consumers that ask `method.input({ strict: true })` (tool projections). `NamedInput` is `z.strictObject` over the wire fields, optional where `acceptsUndefined`.

Decorator markers are stored on the class prototype under the string property `@deepseek-ai/dsh-typert-protocol/remote-methods` as `{ version: 1, methods: [{ method, exportName?, mode?, invocation: { kind: 'direct' } | { kind: 'context', context }, resources? }] }`. The service binding is the instance field `typertRemote = { service, serviceKey, namespace }` (frozen).

### CLI flags and environment

`dsh --profile web` (`packages/bundle/web-app/src/startup.ts`): `--host <host>` (one concrete IP literal; wildcard rejected), `--port <port>` (digits; 0 lets the OS pick), `--no-open`, `--public-url <url>` (absolute `http(s)://host[/prefix]`, no query, fragment, credentials, whitespace; normalized to end in `/`; grants no trust), `--trusted-host <authority...>` (repeatable), `--tls-cert <file>` with `--tls-key <file>` (both or neither), `-h, --help`. `--help` or a usage error provides no `webStartup`, so no server binds.

Startup output: `dsh web: <advertised url>?token=<launch token>` after the Loader tree settles and the startup-entry audit passes; then `dsh web: opening the default browser; pass --no-open to disable` unless suppressed (flag or SSH launch). A non-loopback plain-HTTP bind prints `dsh web: listening on <host> over plain HTTP; restrict this port to a trusted proxy or network`.

Environment: `DSH_WEB_URL` (registered into the shell environment for agent shells; value is the advertised URL), `DSH_SESSION_ID` (set in every terminal the controller spawns), `HISTFILE` (confined POSIX agent terminals: `/tmp/dsh-agent-history-<id>` under `workspace-write`, empty under `read-only`), `DSH_CLIENT_VERSION`, `DSH_PRODUCT_ANALYTICS_OTLP_URL`, `DSH_PRIMARY_RUNTIME` (read by desktop-only rows), `DISPLAY` / `WAYLAND_DISPLAY` / `PATH` (picker resolution).

## Algorithms and invariants

### Gateway dispatch (`packages/api/gateway/src/index.ts:793-876`)

For every unary call and stream open, in this order:

1. Peer live check: `peer.signal.aborted` → `gateway/peer-disposed` (wire paths check before reading the payload, `:1261`).
2. Payload shape: plain object with exactly `args` (plain object); endpoint has exactly two non-empty segments. Both failures are plain exceptions (`Remote payload must contain exactly one plain-object args field`, `invalid Remote endpoint "<endpoint>"`), so the wire shows `gateway/internal`, not a `gateway/arguments-invalid` code.
3. Descriptor: strict from `typert.local.get(endpoint)`; if absent but `hasSeen(endpoint)` → `gateway/definition-unavailable` (no silent weakening); else source fallback (`:891-917`): scan every registered service, read `typertRemote`, match namespace and decorator marker; zero candidates → `gateway/invocation-unavailable`; more than one → `gateway/ambiguous-endpoint`.
4. Exact fields (`assertExactArguments`, `:1630`): expected = parameter wire names plus the Context wire. Extra keys, or a missing key that is not an omissible JSON parameter (`acceptsUndefined`, or any JSON parameter under the source fallback), → `gateway/arguments-invalid` with message `args fields do not match the descriptor: missing "a"; unexpected "b"`. Lookup identities are never omissible.
5. Validate (`validateArguments`, `:1665`): each present JSON argument through its codec once (`codec.create().parse(value)` then a JSON-safety walk); failure → `gateway/input-invalid` with `details.field`. Lookup and Context identities keep their wire values at this point.
6. Access (non-owner only): resolve resources, then `remoteAccess.decide({ principal, action: '<ns>/<method>', resources, args })`; deny or invalid resources → `remote-access/denied { action, reason }`. This happens before any lookup, so a refused call resumes no Session.
7. Receiver Context: direct → the Gateway's own Context; `context` → `typert.contexts.getHost(key)`; missing → `gateway/context-unavailable`; declaration mismatch → `gateway/provider-mismatch`; resolver throw → `gateway/context-failed` (a `RemoteError` passes through); `undefined` → `gateway/context-not-found`.
8. Receiver: `receiverContext.get(descriptor.service)`; absent → `gateway/service-unavailable`; `typertRemote` binding must name this original instance, service key and namespace, else `gateway/binding-invalid`.
9. Parameters in parallel (`resolveParameter`, `:1062`): JSON → validated value; lookup → decode identity, `typert.lookups.get(key)` (`gateway/lookup-unavailable`, `gateway/provider-mismatch`), `resolve(id)` (`gateway/lookup-failed` unless the throw is a `RemoteError`; `undefined` → `gateway/lookup-not-found`).
10. Signal (`methodSignal`, `:1291`): unary without uplink → the carrier signal; streams → `any(carrier, control, peer.signal)`. Appended as the last argument only when the descriptor has `cancellation`.
11. Invoke the method on a service view bound to a Context extended with `{ invocation }`. Missing function → `gateway/method-unavailable`.
12. Unary: await; if the signal is aborted when the method throws → `gateway/cancelled` (message `Remote invocation "<endpoint>" was aborted`); always close the invocation uplink. Result encoding: strict codec `encode` when present, else the value unchanged; source fallback walks the value, applies `toJSON`, extracts `Uint8Array` leaves to attachments, throws on cycles (`:1135-1182`).
13. Stream: the return value must be `Iterable` or `AsyncIterable` (`gateway/result-invalid`). `cancellableStream` (`:1318`) races each `next()` against the abort signal; on exit it closes the uplink first, then calls `iterator.return()`. Downlink items are not validated.

Source-fallback descriptor derivation (`:919-1012`): parameter names are parsed from `Function.prototype.toString` of the prototype method (text between the first `(` and the next `)` split on commas; each must match `/^[$A-Z_a-z][$\w]*$/` and be unique, else `gateway/signature-invalid`). A final parameter named `signal` is cancellation; `signal` elsewhere is an error. A name equal to a registered lookup `parameter` becomes a lookup parameter with that wire; others are JSON with codec `src-json` (JSON-safety only). The claim cache for source endpoints is invalidated on every `internal/service` event.

JSON-safety (`assertJsonValue`, `:1704`): null, string, boolean, finite number; arrays dense without extra or symbol properties; plain objects (prototype `Object.prototype` or null) with only enumerable data properties and no symbols; no cycles. The stricter wire predicate `isRemoteJsonValue` (`protocol/src/json-value.ts`) also rejects `-0`.

### Resource resolution for access control (`packages/api/gateway/src/access.ts`)

Sources per resource kind, later replacing earlier while keeping the kind's first position: (1) every `typert.resources` entry — `resolve({ args, parameters })` or `field` (a top-level argument of that name, else that field of the first object-valued argument); (2) lookup parameters and the Context identity whose provider declares `resource` (Context identity first, then parameters in order; an omitted optional lookup contributes nothing); (3) the method's own `resources` readers, called with the positional wire arguments (lookup positions hold wire ids, the cancellation position holds the signal). Invalid resolution (→ reason `resource-invalid`): a resolver or reader throws, a default returns an array, a reader returns an empty array, or an id is not a non-empty string. No ids at all → `[{ kind: 'global' }]`. For forwarded events a reader returning `undefined` is invalid; an entry without readers touches `global`.

The `session` resolver (`session-controller/src/index.ts:92`): a parameter named or wired `sessionId` wins; otherwise the first object argument's `sessionId`, or its `address` (`sessionId` for kind `session`, `childSessionId` for kind `subagent`); an object carrying both throws.

### Access decision (`packages/api/remote-access/src/index.ts:199-375`)

`decide`: owner → allow; action `remoteAccess/follow` → allow; no policy for the principal kind → deny `no-allow`; `bindings()` throws → deny `policy-failed`. For each listed resource, some binding must match the resource (`kind` and `id` equal), list the action in its role, and have no condition or an allowing condition. First resource with no allowing binding: the first refusing condition's reason, else `explain()`'s reason, else `no-allow`. A throwing condition or `explain` → `policy-failed`, logged once per policy until the next `invalidate()`.

`grantsFor` (snapshot): one grant per bound resource in first-binding order; actions are the non-`event:` actions of that resource's bindings that evaluate to allow without arguments, sorted; resources with no action are omitted. `follow` diffs successive grant lists into `upsert` (new resource or changed action list) and `remove` frames; changes coalesce through a dirty flag.

### WebSocket mux server (`stream-server.ts`)

- Upgrade handler (`gateway/src/index.ts:273-308`): `connection.admitConnection(req)`; on rejection write the raw HTTP response; otherwise register `release` on socket `error` and `close` before handing the socket to the WebSocket library. The upgrade route is registered only after `appReady.onReady` fires when that service exists.
- `bindPeer`: an effect on `peer.ctx` whose disposer closes the socket with `1001`; if the Peer scope is already disposed the socket closes at once.
- Per stream: `ActiveStream = { abort, inbox, stop, done }`, created before the opener resolves so items sent right after `open` wait in the inbox. `pump` (`:263-302`): open, forward items as `item` frames (writes serialized through one promise chain), then fail the inbox with "Remote stream ended"; if the stream signal is aborted send an `error` frame only when the reason is a `RemoteError`, else nothing; on failure send `error`; on success send `end`. A terminal frame that cannot be written closes the socket with `1011`.
- `UplinkInbox` (`:362`): single consumer, byte-accounted FIFO; `push` after `end` → `gateway/protocol`; overflow → `gateway/uplink-overflow`; both call `onViolation` which aborts the stream with that error. `return()` drops later items.
- `UplinkDecoder` (`gateway/src/index.ts:1378`): `uplink()` may be taken once; every item passes the descriptor uplink codec (or JSON-safety); a rejected item aborts the whole stream with `gateway/input-invalid` field `uplink`; a top-level `undefined` passes when there is no codec. Gateway-owned `$events` releases its uplink at open so its items are dropped.

### Forwarded-event broker (`gateway/src/index.ts:544-769`, `remotes/src/index.ts`)

- Source (`remoteEventSource`): for each `emit` entry a Cordis listener asserts every argument is lossless JSON and pushes `{ event, args, resources? }`. For each `waterfall` entry the listener reads the scope carrier Agent from `this` (`carrierKeyOf(this)`); without one it calls `next()`; the request's `agent` must be that Agent; it then pushes an invocation with `resolve`/`reject` callbacks and returns a promise. If the queue is already closed it falls through to `next()`.
- `openRemoteEvents`: lifetime = `any(stream signal, source lifetime, peer.signal)`; assigns a unique `clientId`; an owner Client immediately receives every pending waterfall; yields `ready` then the per-Client queue.
- Broadcast: owners always receive; for non-owners resources are resolved once per frame, then `decide({ principal, action: 'event:<name>', resources })`; a denied or invalid frame is dropped for that Client only. Non-owners never receive waterfalls.
- Waterfall start (`startRemoteEvent`): requires a non-empty `agentId`; projects the request (must be a plain object carrying `agent === subject`; `agent` and `signal` removed; the remainder must be lossless JSON); registers an effect on the Agent Context that cancels the event when that Context is released; listens to the request's own `signal`. If registering the effect throws, the event resolves `{ kind: 'next' }`.
- Result (`receiveRemoteEventResult`, `:708`): results for a finished event or a superseded delivery are ignored. `result` settles with the value; `rejected` rejects with an Error rebuilt from `{ name, message, code?, details? }`; `next` settles `{ kind: 'next' }` only when no other Client still holds the delivery. Finishing an event sends `{ type: 'cancel', eventId }` to every Client that still held it.
- A Client stream ending removes its deliveries without settling the event; the event stays pending for the next owner Client. Withdrawing the source rejects all pending events and ends all Client queues.
- `$events/result` checks, in order: Peer live, `interactions === 'answer'`, owner principal (`gateway/invocation-unavailable` otherwise), a live `clientId` (plain Error → `gateway/internal`), and that the stream belongs to the same Peer (`gateway/interactions-forbidden`).

### Session follow (`session-controller/src/web/controller.ts:32-77`, `history/listener.ts`)

1. Validate the window: `throughSeq` integer ≥ -1, `beforeSeq` ≥ 0, `maxMessages` > 0 (default 50), `turnWindow.minMessages` in 1..maxMessages, `minTurns` > 0; failures are `gateway/bad-request`.
2. Create one `ListenerBuffer` and attach an `EventListener` to it before any read: subscribes `session/event` (append) and `session/created` (prepend) for this Session id. With `assistantStream: true`, also bind an assistant listener that appends `agent/assistant-stream` frames with a connection-local ordinal.
3. Acquire `sessionQuery.observeSession(sessionId, { signal, projectionMode: 'all' })`. `SESSION_QUERY_SESSION_NOT_FOUND` → `session/not-found` (or `subagent/not-found` for a subagent address); `SESSION_QUERY_ABORTED` → `gateway/cancelled`.
4. Validate the address (`history.ts:66`): a header without `cwd` is not found; a `session` address on a subagent Session → `session/agent-busy`; a `subagent` address must match `origin === 'subagent'` and `parentSession`, have a projected `subagent` identity (`null` → `corrupt`, missing or inherited → `unsupported`), and match `mode` unless `'unknown'`.
5. Build the snapshot: `header`, `projections` (`session/projections-unavailable` when absent), and `history(observation, spec)`.
6. `listener.setCursor(snapshot.cursor)`: buffered events with `seq ≤ cursor` are dropped at dequeue; the next event must be exactly `cursor + 1`, else `gateway/internal` `session event stream skipped seq <n>` (`eventItem`, `listener.ts:106`). A `session/created` notification expands to `session.snapshotEvents(start, end)` for events not yet covered.
7. Assistant baseline and ordinal cut are captured synchronously together; frames with `ordinal ≤ cut` are dropped at dequeue.
8. Activation: when `activate === true`, the signal is not aborted, the Session is not a subagent, and `observation.source === 'prepared'` (cold), retain the observation and start a background resume (`promote`); failure emits `api-session/error`. The opening lease is disposed in every branch before the snapshot is yielded.
9. Yield the snapshot, then every queued item in arrival order (durable events and assistant frames share one queue).

Paging (`paginate`, `history.ts:132`): walk backwards from `end = min(throughSeq + 1, beforeSeq ?? throughSeq + 1)`; count events of type `user/message` or `assistant/message` whose surface op is append; a message's group start is the minimum of its seq and its `sourceEventSeqs`; stop when the count reaches `maxMessages` (cut at the group start) or, with `turnWindow`, at a `turn/start` once `count ≥ minMessages` and `turns ≥ minTurns`. Return `events[cut, end)` chronologically and `hasMore = cut > 0`. `cursor` in the result is the supplied `throughSeq` or the observed log end; a cut beyond the observed end is `gateway/bad-request`.

Assistant accumulator (`assistant-stream.ts:38`): one per live Session, fed by every `agent/assistant-stream` frame; `revision` must be previous + 1; a `start` with revision 1 resets; any gap drops the active attempt and adopts the revision; `chunk` must match the active `attemptId` and `nextIndex`, else the active attempt is dropped; `end` clears it. `startedAfterSeq` is `session.seq - 1` (or -1 for an empty log) when the frame is observed. The accumulator is deleted on `agent/disposed`.

### Session state and wait (`state/controller.ts`, `state/listener.ts`)

`readState`: live Agent → `{ cursor: session.seq - 1, active: true, running: status === 'running', queue, pendingInput }` where queue is `inbox.nextTurn` (placement `queued`) then `inbox.nextStep` (`steering` when the source kind is `user`, else `context`). No Agent → a non-projecting observation `{ cursor, active: false, running: false, queue: null, pendingInput }`; if the observation source is `live` (the Session attached during the read) the read is retried once. `pendingInput` classifies `typertGateway.getPendingRemoteEvents()` entries whose `agentId` equals the Session: `approval/request` → `approval`, `user-questions/request` → `question`, else `other`.

`StateListener.observeStates(refreshMs?)`: revision counter bumped by `session/event`, `session/created`, `session/disposed`, `agent/status`, `agent/created`, `agent/disposed` for the target id; emits a state only when no invalidation occurred during the read; with `refreshMs` an idle timer forces a re-read.

`wait` (`state/controller.ts:56`): defaults `timeoutMs` 30000 (max `MAX_TIMER_DELAY_MS`), `afterSeq` -1, `maxMessages` 50; refresh interval 1000 ms. Loop: `pendingInput` non-empty → `input-required`; `running` → continue; not active → `idle`; active and idle → race `agent.whenIdle()` against the next state, re-check identity, then `idle`. Deadline → `timeout` with the last complete state; no state before the deadline → `session/wait-timeout`. Caller cancellation rethrows the caller's reason. Output: `assistant/message` append events with seq in `(afterSeq, state.cursor]`, newest first, at most `maxMessages`, `truncated` when more exist.

### Session commands (`commands.ts`, `agent.ts`)

- Lookup policy (`agent.ts:164`): a live Agent is returned unless its Session `origin === 'subagent'` (→ `session/agent-busy`, reason `use subagent delivery for this child session`). Otherwise one resume per Session id is shared by concurrent callers: observe the Session (missing or no `cwd` → `session/not-found`), compose the preset recorded in its projections, `agents.resume({ resumeSessionId, agentOptions, setup })`. `SessionAlreadyOwnedError` → `session/writer-held`; other failures → `gateway/internal` `resume failed for session "<id>": …`. Agent options are getters over `agentDefaultModel.currentSelection()` so an unselected Session follows default changes.
- `create` (`commands.ts:120`, `agent.ts:229-382`): `workspaceId` and `cwd` together → `gateway/bad-request`; unknown workspace → `workspace/not-found`; cwd = workspace path, else request cwd, else `process.cwd()` at controller init. Without `sessionId`: mint `session-<uuid>`, `mkdir -p cwd`, create. With `sessionId`: requests for one id run in arrival order; a live or stored Session under another cwd → `session/conflict`; it is reused only when the placement rule passes (not archived, member of the workspace when one is named) and no `turn/start` exists; otherwise a new id is minted. Reuse re-checks blankness under the acquired writer and appends `agent-preset/selected { agentPreset }` when the preset changes. The Session is then attached to the workspace (`session/workspace-attach-failed` on error).
- `prompt` (`index.ts:467`, `commands.ts:321`): non-empty content must contain non-whitespace text or an attachment; `clientTimeZone` must canonicalize (`session/invalid-time-zone`). Message source `{ kind: 'user' | 'retry', rpcId: requestId, clientTimeZone?, principal? }` (`principal` only for non-owners; `retry` when content is empty). Idempotency: `hasPromptRequest` scans `user/message` and `agent/inbox/spliced` events after a cached offset, ignoring inherited (forked) events, and answers `{ accepted: true }` for a known `requestId`, including after a late failure. Empty content: requires `mode: 'queue'`, a non-null `conversationContinuation` projection, an empty `nextTurn`, and no user message in `nextStep`, else `session/agent-busy` reason `NO_CONTINUABLE_FAILURE_OR_PENDING_INPUT`; runs inside `agent.runMaintenance`. File parts are replaced by staged uploads (`FILE_NOT_STAGED`); images require a model whose `inputModalities` includes `image` (`MODEL_DOES_NOT_SUPPORT_IMAGES`) and are serialized per Agent with model selection; `attachments.admitPromptContent` promotes bytes; then `agent.steer(message)` or `agent.followup(message)`.
- `conversationContinuation` projection (`continuation.ts`, `stateVersion: 4`): state `{ admitted, failedAttempt, ending }`; `turn/start` resets; an appended `user/message` (user with content, or retry with none) sets `admitted`; `assistant/attempt` sets `failedAttempt`; `step/start` and `assistant/message` clear it; `turn/end` with `reason.kind === 'error'` and code in `RATE_LIMIT, SERVER, TIMEOUT, TRANSPORT, EMPTY_RESPONSE, STREAM_CLOSED`, with both flags set, records `ending = seq`. Wire view: the `ending` seq or `null`.
- `fork`: boundary = `atSeq` or the last `turn/end` extended over following events until a `turn/start`, an appended `user/message`, or `agent/inbox/spliced`; missing → `session/fork-unavailable`. Seed from `buildForkSeed(events, boundary)`; new Session with `inheritedEventCount = boundary + 1`, `meta { cwd, isSeeded: true, agentPreset? }`; attached to the source's workspace (or an ancestor's for a subagent source). `allowMigration: false` on a cold `migration-required` source → `session/migration-required`.
- `updateQueue`: `edit` accepts text blocks only (`QUEUE_EDIT_NON_TEXT`) with non-whitespace text; a cold Session is resumed, and `session/not-found` there maps to `session/queue-item-not-found`; `steer` requires the item in `nextTurn` and a running Agent (`session/steer-unavailable`); `remove` also retires the prompt's file uploads.
- `cancel`: live Agent only (`session/not-found` "not attached"); `agent.cancel({ kind: 'user' }, { keepInbox: true })`.
- `list` (`list.ts:145`): live Sessions are summarized from live projections (`kind: 'sequenced'`); cold records with a `cwd` use the projection cache (`kind: 'cached'`, falling back to a predecessor title); `updatedAt = max(header.createdAt, lastPromptAt ?? 0)`; the loop yields to the scheduler whenever `listWorkSliceMs` elapses; sort descending.
- `search` (`list.ts:202`): query trimmed, 1..500 UTF-16 units, no NUL; provider pages filtered to `user/message` and `assistant/message` on the current surface; one hit per Session; up to 100 provider calls; `SESSION_QUERY_INVALID_LIMIT` on the first page halves the limit; `SESSION_QUERY_STALE_CURSOR` restarts.
- Archived gate: an `agent/pre-step` waterfall listener returns `{ kind: 'reject' }` when the Agent's Session or a subagent ancestor is in `workspaceRegistry.archivedSessionIds`.

### Jobs (`observe.ts`, `rows.ts`, `wake.ts`)

Both streams subscribe to `jobs.events` with `{ owners: 'all' }` before the first read. `list`: a frame on open, then after each non-output event for a job that is unowned or owned by the Session, coalesced by sleeping `observeFlushMs`. `follow`: `from` must be a non-negative safe integer; cursor starts at `from ?? job.output.earliest`; loop: a `removed` event → final `status` with the removed projection; `readAt(id, cursor, sessionId)`; split chunks into frames whenever the accumulated UTF-8 byte count reaches `observeMaxFrameBytes` (a larger single chunk ships whole; `lossy` rides the first frame only; an intermediate frame's `next` is the last chunk's `at` plus its byte length); a terminal status with `cursor ≥ output.total` → `status` and end; else wait for a wake, then sleep `observeFlushMs`. `OutputWaiter` keeps a dirty flag so a wake between waits is never lost.

### Terminals (`terminal.ts`, `stream.ts`, `retention.ts`, `index.ts`)

- One `BrowserTerminal` per PTY: a headless terminal emulator (`@xterm/headless` with `SerializeAddon`) sized `cols × rows` with `scrollback` rows; one promise chain orders output application, input writes, resizes and snapshots.
- Output: each decoded UTF-8 chunk is written to the emulator, then broadcast as `{ type: 'output', sequence: ++n, data }`. On process end, `info.state` becomes `exited` (with `exitCode`) or `failed` (with `error`) and a `state` frame is broadcast.
- `attach`: the new follower becomes the single input controller (older attachments keep receiving output and see `writable: false`); the first frame is `snapshot` with `screen = serializer.serialize()`, the current output `sequence`, and `inputWindow` when the carrier has one. Uplink commands must carry `sequence` 1, 2, 3 … per attachment; a gap fails the attachment. `write`: UTF-8 length ≤ `maxInputBytes`; `typed: true` on an Agent-controlled terminal flips `control` to `user` before the write, permanently. `resize`: bounds checked, PTY and emulator resized, `state` broadcast. Each accepted command is answered `{ type: 'ack', sequence }`; a refusal is `ack` with `refusal: 'read-only'` (another attachment controls) or `'not-running'`.
- `TerminalFollower`: bounded queue counted as UTF-8 bytes of each frame's JSON; exceeding `maxBufferedBytes` fails that attachment with `Terminal output consumer exceeded its buffer; reconnect to recover the current screen`; the process is unaffected.
- Quotas: distinct ids across terminals, pending and failed allocations ≥ `maxTerminals` → `terminal/limit-reached`; Agent-controlled running terminals plus pending Agent allocations ≥ `maxAgentTerminals` likewise. A closed id cannot be recreated (`terminal/unavailable`).
- Spawn: `subprocess.spawnTerminal({ argv, cwd, cols, rows, terminalType: 'xterm-256color', env, shellActivity: true, graceMs, signal })`. Default shell profile args: none for `cmd`, `-NoLogo` for `pwsh`/`powershell`, `-i` otherwise; default shell from `subprocess.terminalEnvironment()` or `cmd.exe` / `/bin/sh`.
- Retention (`retention.ts`): `retain` holds add to a set and cancel the idle timer. With no holds and `unattendedTimeoutMs > 0`, poll `inspectActivity()` every `activityPollIntervalMs`; a continuous `idle` observation with an unchanged activity `revision` (and poll gaps ≤ 2 intervals) lasting `unattendedTimeoutMs` closes the terminal. Input and holds bump an epoch that discards in-flight observations. A failed cleanup retries after `cleanupRetryMs`.
- Owner lifetime: terminals belong to a Session owner created on first use and disposed by an effect on `agent.ctx`; `list`, `watch`, `retain` take a bare `sessionId` and never resume an Agent.

### Workspace feed and files

- `WorkspaceFeed` (`feed.ts:101`): listens to `domain/changed` for domain `workspace`. Root-table `put` → `upsert` for each newly known id, `order` when the id sequence changed, `archived` and `pinned` when those lists changed. Table `workspaces`: `deleted` → `remove`; `put` for a known id → `upsert` parsed from the stored record.
- Follow filtering (`index.ts:206`): keeps a `delivered` set per generation; an `upsert` for a no-longer-visible delivered Workspace, or an `order` naming one, sends `replace` with the complete filtered baseline instead of `remove`; `remove` reaches only Clients that received the Workspace; session id lists are filtered through `allows`.
- Default workspace: `<Documents>/deepseek-harness/default-workspace`; Documents from config or `osascript` (darwin), PowerShell `GetFolderPath(MyDocuments, DoNotVerify)` (win32), `xdg-user-dir DOCUMENTS` (linux; a result equal to the home directory is "unavailable").
- `workspaceFileScope` resolution: live Session header, else `sessionPersistence.stat(sessionId)`; `workspaceRoot = header.cwd ?? sandboxPolicy.workspaceRoot`; no header → `gateway/lookup-not-found`.
- `read` (`cutPage`, `workspace-files/src/index.ts:119`): `offset` default 1, `limit` default and maximum `maxLines` (larger → `gateway/bad-request`); streams decoded text and stops at the first character past the page; the page's UTF-8 bytes (plus one per joining newline) above `maxBytes` → `workspace-file/too-large`; a NUL in the page or a non-UTF-8 stream → `workspace-file/not-text`. File gate (`locateFile`): `lstat` of the path itself must be a regular file (symlinks refused), then resolve and `stat` again.
- `readBytes`: with `range`, `length` default `maxBytes` and above it is refused; without, the whole file up to `maxFileBytes`. `baseFile` resolves a relative `path` against that file's directory (the path must be relative, without scheme or NUL).
- `list`: target must resolve inside the workspace root (`workspace-file/outside-workspace`); a final symlink is followed only when it resolves to a directory; entries cut at `maxEntries` with `truncated`.
- `search`: packaged ripgrep `--files --sort=path --null --path-separator=/` plus `--hidden` / `--no-ignore` and escaped exclusion globs; query without `/` matches names, with `/` matches relative paths, case-insensitively; results include inferred ancestor directories, sorted by depth then path, cut at `maxResults`; listing more than `maxEntries` files terminates rg and sets `incomplete`.
- `changes`: `ready` after the watcher initializes; each matching `fs/observed` invalidation produces the current stat (`version`) or `absent: true`.

### Typert loader (`packages/typert/loader/src/index.ts:330-502`)

Dirty set of Loader entry names; every `internal/plugin` emission adds the fiber's entry name and schedules a microtask flush. A name qualifies when it is in config `packages` or a live, enabled Loader entry has that name. Qualifying and unregistered → resolve the package (`pluginPackages.packageOf` when present, else `require.resolve('<name>/package.json')` from `ctx.baseUrl`), read `exports['./typert']` (string, or object with string `default`), import the artifact once per package, validate `TYPERT` (`validateTypertManifest`, `:90`), `ctx.typert.register`. No longer qualifying → dispose. Negative verdicts are cached for the process. The activation pass aggregates failures into one `AggregateError`; steady-state failures are logged per package.

### Directory picker resolution (`directory-picker-auto/src/resolve.ts:55`)

`browse` when Connection allows remote authorities or the bind host is not loopback; `browse` when launched through SSH; `native` on darwin and win32; on linux `native` only with a chooser binary (`zenity` or `kdialog` executable on `PATH`) and a non-empty `DISPLAY` or `WAYLAND_DISPLAY`; otherwise `browse`. The decision is sampled once at boot and both the backend and the matching client surface package are created as Loader entries.

Browse listing: fully qualified paths only; streams `opendir` into a name-sorted window of `maxEntries + 1` using `localeCompare`; only directories and symlinks that `stat` as directories are rows; `hidden` is the dot-prefix rule; every filesystem await races the caller's signal. `createDirectory` validates one non-blank segment without `/` or `\`, not `.` or `..`.

### Webserver invariants

- Bind address parsing (`webserver/src/index.ts:144-237`): IPv4-mapped IPv6 normalizes to IPv4; a dotted-quad IPv6 tail is rewritten to hex groups before parsing so `::0.0.0.1` reads as `::1`; wildcard means every address byte is zero; the zone is kept for `listen` and dropped from URLs.
- TLS files are read once before bind; unreadable, empty, or mismatched material fails activation with a message naming the field and the resolved path.
- Disposal closes the listener, all keep-alive connections, tracked upgraded sockets and raw TLS connections, and waits for all of them.
- Resource routes: only GET and HEAD; HEAD writes headers without a body; the response body is cancelled when the client disconnects.

## Tests worth porting

Wire and protocol (highest value for a compatible host):

- `packages/api/gateway/tests/stream-protocol.host.spec.ts` — exact-key frame validation for both directions.
- `packages/api/gateway/tests/stream-server.host.spec.ts` — heartbeat termination, inbox overflow, item-after-end, duplicate open, binary frame close codes, Peer disposal closing the socket, compression threshold.
- `packages/api/gateway/tests/gateway.host.spec.ts` — the dispatch order and every `gateway/*` code; source fallback parsing; binary result projection.
- `packages/api/gateway/tests/gateway-stream.host.spec.ts`, `echo-stream.host.spec.ts` — stream cancellation, uplink decode, half-close, uplink release at downlink end.
- `packages/api/gateway/tests/gateway-access.host.spec.ts` — resource resolution precedence, `resource-invalid`, access before lookup.
- `packages/api/gateway/tests/remote-event-protocol.host.spec.ts` — `$events` ready frame, waterfall delivery, result outcomes, redelivery after reconnect, non-owner filtering.
- `packages/api/gateway/tests/operator-connect.host.spec.ts` with `operator-connect-fixture.ts` — `/connect` exchange, one socket per API Peer (409), interactions enforcement.
- `packages/api/gateway/tests/strict-source.host.spec.ts` — a withdrawn strict definition never falls back.
- `packages/client/connection/tests/{browser-auth,api-request-trust,http-bridge,binary-rpc,fetch-routes,rpc-schema,node-half}.host.spec.ts` — cookie format and expiry, the trust fence truth table, 413/415/400 answers, multipart layout, exact-route 403 for non-owners.
- `packages/host/webserver/tests/webserver.spec.ts` — bind literal classification, gzip eligibility, match order, `readResource`, injection rendering per Peer, TLS failures, teardown quiescence. Fixture `tests/tls-fixture.ts`.
- `packages/host/frontend-static/tests/frontend-static.spec.ts` — token redirect, 401 body, traversal 403, ETag/304, `<base href>` placement.

Typert runtime:

- `packages/typert/protocol/tests/{protocol,remote-info,remote-access,owned-value}.spec.ts` — decorator option validation, marker storage, lazy info index, lossless-JSON predicate.
- `packages/typert/registry/tests/typert.spec.ts` — atomic registration, duplicate rejection, `hasSeen`, lookup `configure` precedence and restoration, name grammar.
- `packages/typert/loader/tests/loader.spec.ts` — manifest validation messages, mount/unmount reconciliation, aggregated activation failure.
- `packages/typert/generator/tests/{remote-model,remote-metadata,schema-emitter,type-model}.spec.ts` and `tests/__snapshots__/type-model.spec.ts.snap` — useful only as a reference for descriptor contents (wire names, `acceptsUndefined`, uplink codec); the fixtures under `tests/fixtures/remote-model` are the smallest end-to-end example of a Remote service and its artifact.

Controllers:

- Session: `tests/session-history-journal.host.spec.ts` (paging and follow continuity), `session-cold.host.spec.ts` (cold reads, activation on follow), `transport.host.spec.ts`, `listeners.host.spec.ts` (cursor cut, gap error), `assistant-stream.host.spec.ts`, `state-controller.host.spec.ts` (wait reasons), `commands-create-fork.host.spec.ts`, `session-fork.host.spec.ts`, `commands-queue-attachment.host.spec.ts`, `control-queue.host.spec.ts`, `empty-prompt.host.spec.ts` and `continuation.host.spec.ts` (continuation eligibility), `session-search.host.spec.ts`, `list-scheduling.host.spec.ts`, `summary-list.host.spec.ts`, `session-models.host.spec.ts`, `session-presets.host.spec.ts`, `subagent-access.host.spec.ts`, `remote-access.host.spec.ts` (wire field `_request`, list filtering), `media-references.host.spec.ts` (`/api/file` statuses and headers), `archived-session-gate.host.spec.ts`.
- Remote access: `packages/api/remote-access/tests/remote-access.host.spec.ts` (decide truth table, snapshot diff frames).
- Jobs: `tests/observe.host.spec.ts`, `rows.host.spec.ts`, `kill.host.spec.ts`.
- Settings: `tests/settings-controller.host.spec.ts`, `credentials-controller.host.spec.ts`.
- Terminal: `tests/controller.spec.ts`, `terminal.spec.ts`, `stream.spec.ts`, `retention.spec.ts`, `screen.spec.ts`.
- Workspace: `tests/workspace-controller.host.spec.ts`, `directory-picker.host.spec.ts`, `default-directory.host.spec.ts`.
- Workspace files: `tests/{read,read-all,read-bytes,binary-rpc,stat,list,scope,search,search-rg,changes}.spec.ts`.
- Host packages: `directory-picker-auto/tests/resolve.spec.ts` (decision table), `directory-picker-browse/tests/service.spec.ts`, `directory-picker-native/tests/native-picker.spec.ts`, `open-in-app/tests/{host-routes,resolver,icons}.spec.ts`, `plugin-inventory/tests/inventory.spec.ts`, `product-telemetry-otel/tests/telemetry.spec.ts`.

Client-side specs (`*.client.spec.ts`) pin browser behavior and matter only when the React client is kept: `gateway.client.spec.ts`, `journal-stream.client.spec.ts`, `control-retry.client.spec.ts`, session `transport.client.spec.ts`, `manager.client.spec.ts`.

## Porting notes

### Essential behavior versus Node machinery

Essential product behavior: the route table and auth model; the unary envelope, multipart binary framing and mux frames; the dispatch order with its error codes; access control semantics; the forwarded-event broker; every controller method's validation, limits and result fields; the follow stream's snapshot/cursor/ordinal rules; terminal sequencing and quotas.

Node/TypeScript machinery that should not be ported literally:

- The Typert generator (TypeScript `ts.Program` analysis, Zod emission, declaration maps, tsdown plugin). Its purpose is to derive validators from TypeScript types. In Racket the method declaration can carry its own argument contracts.
- The strict/SRC split. SRC exists because source launches skip the compiler; a Racket host has one descriptor source.
- Declaration merging (`TypertLookupMap`, `RemoteErrorDetailsMap`, `TypertRemoteEventSelection`). These are type-level only; the runtime registries already hold everything needed.
- `Symbol.dispose` leases, `AbortSignal.any`, promise-chain serialization. Map to custodians, events, and per-object worker threads or semaphores.
- `Function.prototype.toString` parameter parsing, `symbols.original`, prototype marker descriptors.
- Fetch `Request`/`Response` bridging, `ws` library specifics (`bufferedAmount`, context takeover).

### Suggested Racket decomposition

| Racket module | Replaces | Notes |
|---|---|---|
| `dsh/host/webserver` | `host/webserver` | Route structs (`exact`/`prefix` hashes, upgrade hash, fallback box), longest-prefix match, `index-injection` structs with `render-index-injections`. Build on `web-server` dispatchers; one dispatcher consults the tables. TLS through the web server's SSL support. gzip as a response wrapper using `file/gzip` |
| `dsh/host/bind-address` | bind literal helpers | Pure functions with the classification tests |
| `dsh/connection/auth` | `browser-auth.ts` | HMAC-SHA256 cookie (needs an HMAC over `sha256-bytes`), constant-time compare, launch token, credential record |
| `dsh/connection/trust` | `api-request-trust.ts` | Needs WHATWG-like authority normalization (lowercase host, default-port stripping per scheme, IPv6 brackets); write it explicitly and port the truth-table spec |
| `dsh/connection/rpc` | `rpc-host.ts`, `http-bridge.ts` | Envelope parse, multipart writer, exact Fetch routes, body cap |
| `dsh/typert/protocol` | protocol + registry | `remote-error` struct (`code`, `message`, `details`), descriptor structs, registries with effect-scoped registration, parameter `current-remote-invocation` |
| `dsh/typert/remote` (macro) | decorators + generator | `(define-remote-service name #:key … #:namespace … (define/remote (method [arg contract] …) #:mode stream #:cancellable #:resources …))` expanding to a method table and descriptors; lookup parameters declared as `[agent #:lookup agent]` |
| `dsh/gateway/dispatch` | `gateway/src/index.ts` | `prepare-invocation` following the 13-step order; codecs are contracts plus a "strip unknown keys" projector for hash arguments |
| `dsh/gateway/mux` | `stream-server.ts` | One thread per socket reader, one writer thread with a channel, one thread per logical stream; bounded uplink inbox as a byte-counted async channel; heartbeat timer |
| `dsh/gateway/events` | forwarded-event broker + `api/remotes` | Allowlist table, per-client queue, pending waterfall table |
| `dsh/remote-access` | `api/remote-access` | Direct port; policies are procedures |
| `dsh/api/session`, `…/job`, `…/settings`, `…/terminal`, `…/workspace`, `…/workspace-files` | controllers | Stream methods return a sequence backed by an async channel plus a stop procedure |
| `dsh/host/frontend-static`, `…/directory-picker`, `…/open-in-app`, `…/plugin-inventory` | host packages | Mostly data tables and subprocess calls |

Idiom mapping: a Peer is a struct owning a custodian and a cancellation event; `invocation.signal` is an event (`evt`) combined with `choice-evt`; `ctx.effect` is a custodian-managed registration; an async iterable is a struct `(next!, return!)` over a channel; `this.ctx.invocation` is a `parameterize`d value (it survives into the thread that runs the stream generator when the thread is created inside the parameterization).

### Hard parts and risks

1. Terminal emulator. `snapshot.screen` is the serialized state of a headless xterm (escape sequences that recreate the screen and scrollback), and `readScreen`/marks need rendered logical lines. There is no Racket equivalent. Options: write a VT100/xterm state machine (large; reflow on resize is the difficult part), keep a bounded raw-output ring and replay it as the snapshot (cheap, but resize and alternate-screen fidelity differ and Agent `readScreen` degrades), or run `@xterm/headless` in a Node sidecar. PTY allocation itself needs FFI (`forkpty`/`openpty`) or a helper process and belongs to the subprocess area.
2. Descriptor drift. With the React client kept, the client's descriptors come from the TypeScript build while the Racket host declares its own. A conformance check is needed: extract `{ endpoint, mode, parameter wires, acceptsUndefined, cancellation, uplink present }` from every `lib/typert.remote-client.js` (a short Node script can dump them as JSON) and compare with the Racket registry in CI.
3. Session event schema coupling. `SessionWireEvent` is the stored event object. Option (a) below forces the Racket session log to use the same event types, field names, `surfaceOp`, `sourceEventSeqs`, and compact assistant-stream chunk encoding that the React client folds.
4. WebSocket library. Racket's `rfc6455` package supports server sockets and ping/pong but not `permessage-deflate`. That is acceptable: `websocketCompression: 'none'` is a supported mode and browsers accept a response without the extension. The heartbeat's "queued write counts as activity" rule depends on `bufferedAmount`; approximate it by counting any completed write that blocked.
5. Authority normalization and cookie compatibility. Cookie names and audiences depend on WHATWG URL normalization of the `Host` header; a mismatch logs users out or, worse, accepts a wrong audience. Port `browser-auth.host.spec.ts` and `api-request-trust.host.spec.ts` verbatim.
6. Multipart writer. The Client parses with `Response.formData()`; boundaries, `Content-Disposition: form-data; name="…"; filename="blob"` for byte parts and a plain text `metadata` part must be standard.
7. Native integrations: Win32 `IFileOpenDialog` (COM), macOS JXA panel, application catalog probing (registry, `.app` bundles, desktop entries), icon extraction. These can only be wrapped (shell out to `osascript`, `zenity`, `kdialog`, PowerShell) or deferred; behavior is OS-defined.
8. Client plugin bundles. The browser roster (`__DSH_BOOT__`, `/plugins/<id>/client.js`) is produced by the Node build (tsdown, Vite) from `dsh.client` package metadata. A Racket host can serve prebuilt bundles but must reimplement the roster scan in `packages/client/modules` (another area) or freeze a prebuilt graph.
9. ripgrep is an external binary; search can only wrap it.

### Option (a): wire-compatible Racket host for the existing React client

What must exist: everything under Formats, all nine controllers in this area, the 23 other Remote namespaces the client mounts (their owners are other areas, but the UI calls them at boot: `llm`, `account`, `commands`, `agentPresets`, `permissionPresets`, `pluginManager`, `pluginMarket`, `schedule`, `goals`, `subagents`, `userQuestions`, and so on), the non-Remote routes used by UI packages (`/api/file`, `/api/session/uploadFileBinary`, `/api/present.*`, `/api/changes.*`, `/open-in-app/*`, detail-file routes), the client-modules roster, and index injection of every config global the client plugins read.

Estimated size of the host side in this area (Racket lines, excluding tests):

| Piece | Estimate |
|---|---|
| Webserver, bind helpers, index injection, static dist | 600–800 |
| Connection: auth, trust fence, envelope, multipart, bridge | 800–1,000 |
| Typert protocol, registries, `define/remote` macro | 900–1,200 |
| Gateway dispatch, access resources, binary projection | 900–1,100 |
| Mux server and uplink inbox | 500–700 |
| Forwarded events (broker + allowlist source) | 500–600 |
| Remote access | 350–450 |
| Session controller (lookup policy, commands, list/search, history, follow, state/wait, control, projections, `/api/file`) | 2,800–3,500 |
| Job, settings/credentials controllers | 600–750 |
| Terminal controller without the emulator | 1,000–1,300 |
| Terminal emulator (if written in Racket) | 2,500–4,000 |
| Workspace controller, feed, directory picker controller | 800–1,000 |
| Workspace files | 800–1,000 |
| Directory picker seam, auto, browse, native wrappers | 500–700 |
| Open-in-app (routes, catalog data, resolver, icons) | 1,200–1,600 |
| Plugin inventory, telemetry adapter | 200–300 |
| Total for this area | about 15,000–20,000 |

Outside this area but required by option (a): the roster composer for client bundles (~1,000 lines), the conformance dumper, and the other namespaces' Remote adapters (each is a thin layer once its service exists). The React client itself (about 183,000 lines of TypeScript across 76 `packages/client/*` packages plus 11,000 lines of `packages/api/*/src/client`) stays as a Node-built artifact; the Node toolchain remains a build dependency.

Benefits: full UI parity immediately; the same wire also serves API clients that use `/connect` and the mux (the Node client in `gateway/tests/authenticated-node.client.spec.ts`, native desktop callers through `./stream-protocol`). Costs: the Racket session log and every Remote result are frozen to the TypeScript client's expectations; two descriptor sources must be kept in agreement; the generator is not replaced, only bypassed on the host.

### Option (b): Racket-native web UI

A `web-server` application rendering x-expressions on the server, with a small JS shim that opens one WebSocket (or SSE plus POST) and applies HTML or JSON patches. The server calls services in-process, so the Typert descriptor layer, the mux protocol, the `$events` broker, and the client-side journal supervisors are not needed for the UI itself. The auth model, trust fence, and webserver are still needed unchanged.

Feature surface to rebuild, from the web patch roster: session sidebar with workspaces, pin/archive, search; chat transcript with streaming assistant output, tool call cards, turn tail (changed files, deliverables); composer with attachments, `/` commands, `@` file and session references, queue and steer controls, model and reasoning selection, permission presets, goal bar, plan seat; approval and user-question dialogs; subagent and agent-team views; background jobs panel; right sidebar tabs (terminal, file tree, document preview with Markdown/code/PDF/Office renderers); settings (schema-driven forms from serialized schemastery schemas, credentials, models, plugins); plugin manager and market; schedule; feedback; theme, locale (eight languages), shortcuts.

Estimated size:

| Scope | Racket | JS + CSS |
|---|---|---|
| Core loop only: sessions, transcript with streaming, prompt, cancel, approvals, questions, model selection | 4,000–6,000 | 800–1,200 |
| Plus workspaces, queue/steer, jobs, file tree and preview, settings forms, credentials | 8,000–12,000 | 1,500–3,000 |
| Plus terminal (still needs xterm.js in the browser and the attach protocol), plugin manager/market, schedule, subagents, references, feedback, i18n | 15,000–25,000 | 3,000–6,000 |
| Parity with all 76 client packages including Office/PDF preview and trajectory views | 30,000–50,000 | 8,000+ (third-party viewers) |

Benefits: no Node build dependency for the UI, no descriptor drift, freedom in the session wire. Costs: a second product UI to design and keep at parity; rich-client behaviors (optimistic prompt echo, virtualized long transcripts, reconnect with gap repair, drag and drop, IME-safe terminal input) must be re-solved in the shim; API clients that speak the Typert wire would not be served unless the wire host is also built.

### Assessment

The two options share the bottom third (webserver, auth, trust, controllers' business logic). Building the controllers as plain Racket services first, then adding the Typert wire as an adapter layer, keeps both open. For feature-for-feature parity with the least new design work, option (a) is the shorter path: roughly 15–20 thousand lines of host code against a fixed, test-pinned protocol, with the terminal emulator as the one piece that may need a Node sidecar. Option (b) at the "core loop" tier is cheaper than option (a), but it reaches parity only at several times that size, and it does not remove the need for the wire if SDK or desktop callers must keep working. A reasonable plan is option (a) as the compatibility baseline and an option (b) core-loop UI as an independent, optional surface over the same in-process services.

## Feature checklist

- webserver: binds one concrete IPv4/IPv6 literal and rejects every wildcard spelling at load
- webserver: port 0 requests an OS-assigned port and `port` reports it
- webserver: exact route, longest-prefix route, fallback seat match order; 404 when nothing matches
- webserver: duplicate route, upgrade route, or fallback registration throws
- webserver: resource routes answer GET/HEAD and 405 otherwise; HEAD has no body
- webserver: `readResource` answers in process for a given Peer
- webserver: exact-path upgrade dispatch; unmatched upgrade destroys the socket
- webserver: handler rejection answers 400 without killing the process
- webserver: optional gzip with level and threshold; excludes SSE and ranged responses; includes multipart
- webserver: optional TLS from PEM files, fail-loud on unusable material
- webserver: disposal closes listener, idle, upgraded and handshaking sockets
- webserver: `webserver/index-inject` rows of six kinds rendered into head/body in table order
- webserver: `__DSH_BOOT_READY__` tail script after the last body row
- webserver: `tapIndex` raw transforms applied after rows
- webserver: `getOrigin`, `bindUrlHost`, `isLoopbackHost`, `normalizeBindAddress` semantics
- frontend-static: serves dist files with weak ETag, `no-cache`, and 304
- frontend-static: index requires launch token exchange or browser cookie; 401 text body otherwise
- frontend-static: traversal outside dist is 403; missing file is 404
- frontend-static: inserts `<base href="./">` first in head
- connection (adjacent): launch token minted once per process and appended as `?token=`
- connection (adjacent): signed cookie `dsh-auth-<hash>` with v1 browser and v2 API payloads
- connection (adjacent): cookie bound to request authority, expiry, and max age
- connection (adjacent): `GET /?token=` answers 303 to `./` with the cookie
- connection (adjacent): `GET /connect` mints an API Peer and redirects 302 to `./api/remote.mux`
- connection (adjacent): Host / Sec-Fetch-Site / Origin trust fence with `trustedHosts` and bind-address acceptance
- connection (adjacent): `/api` prefix with 403/401 admission and `connection/request` waterfall
- connection (adjacent): unary envelope `client-request` / `server-response`
- connection (adjacent): 404, 415, 400, 413, 500 transport answers
- connection (adjacent): multipart binary result framing with `metadata` and `bytes-<i>` parts
- connection (adjacent): exact Fetch routes, owner-only, buffered or streaming body
- connection (adjacent): request body cap with image-limit consistency check at load
- connection (adjacent): one socket per API Peer; duplicate gets 409; release disposes the Peer
- typert-protocol: `@Remote` and `@RemoteScope` markers with name, stream mode, resource readers
- typert-protocol: `TypertRemoteService` / `bindTypertRemote` service-to-namespace binding
- typert-protocol: `RemoteError` with structural identification
- typert-protocol: lossless JSON predicate rejecting cycles, sparse arrays, non-plain objects, non-finite numbers, `-0`
- typert-protocol: `ctx.invocation` readable inside a Remote method, undefined elsewhere
- typert-protocol: lazy Remote info with named input parsers and optional JSON Schema projection
- typert-registry: atomic contribution registration with duplicate rejection
- typert-registry: schema lookup by `<package>#<name>` with three distinct resolve errors
- typert-registry: local descriptor store with `hasSeen` history
- typert-registry: lookup providers, `configure` override, retained definitions
- typert-registry: Host and Client Context adapters, `configureHost`
- typert-registry: resource kind defaults by field or resolver; `global` reserved
- typert-registry: change subscriptions with contained listener failures
- typert-loader: registers `./typert` artifacts of mounted entries and configured packages
- typert-loader: withdraws a registration when its entry unmounts
- typert-loader: manifest validation with package-naming errors; aggregated activation failure
- typert-generator: Host and Client artifact emission (`typert.host.*`, `typert.remote-client.*`, `typert.client.*`)
- typert-generator: strict and input-strict codecs per parameter; binary result encode/decode
- typert-generator: uplink codec from `RemoteStream<Out, In>`
- typert-generator: package export and files-list validation
- gateway: claims two-segment endpoints with a strict or source descriptor
- gateway: refuses a disposed Peer with `gateway/peer-disposed`
- gateway: exact argument field check with omissible optional JSON parameters
- gateway: argument validation once, before access and lookups
- gateway: non-owner access decision before lookup resolution; `remote-access/denied`
- gateway: lookup and Context resolution with unavailable / mismatch / failed / not-found codes
- gateway: cancellation signal injected as final argument for cancellable methods
- gateway: unary cancellation reported as `gateway/cancelled`
- gateway: unclassified exceptions folded to `gateway/internal`; `RemoteError` passes through
- gateway: withdrawn strict endpoint yields `gateway/definition-unavailable`
- gateway: source-fallback descriptors from live method signatures
- gateway: binary result projection to attachments
- gateway: WebSocket mux at `/api/remote.mux` with open/item/end/cancel and item/error/end frames
- gateway: Ping heartbeat and two-interval inactivity termination
- gateway: optional permessage-deflate with 1024-character threshold
- gateway: per-stream uplink inbox bound, overflow and item-after-end failures
- gateway: uplink items validated per item; rejection fails the stream
- gateway: `invocation.uplink()` single use; `uplinkWindow` exposed
- gateway: stream ends with its Peer; socket closes when the Peer scope is disposed
- gateway: upgrade route registered only after application readiness
- gateway: `$events` stream with `ready`, `emit`, `waterfall`, `cancel` frames
- gateway: `$events/result` with `next` / `result` / `rejected` outcomes
- gateway: pending waterfalls redelivered to a reconnecting owner under the same id
- gateway: non-owner `$events` filtered by `event:<name>` access decisions
- gateway: `hasLiveClient` and `getPendingRemoteEvents`
- api-remotes: forwards the 31 allowlisted events with their modes and resource readers
- api-remotes: scoped waterfall forwarding with fall-through to `next()` when unscoped or closed
- remote-access: policy registration per principal kind
- remote-access: `decide` across all touched resources with condition and explain reasons
- remote-access: `allows` list filtering from the current invocation
- remote-access: `remoteAccess/follow` baseline, upsert, remove frames
- remote-access: index global `__DSH_REMOTE_ACCESS__`
- remote-access: policy failures contained and logged once until invalidated
- session-controller: `session/list` with live and cached projection hints, sorted by activity
- session-controller: `session/search` bounded, deduplicated per Session
- session-controller: `session/create` with blank-Session reuse, cwd conflict, preset selection, workspace attach
- session-controller: cold resume through `agent` / `session` lookups with deduplication and subagent fence
- session-controller: `session/selectModel`, `modelCatalog`, `initializeDefaultModel`
- session-controller: `session/rename`
- session-controller: `session/fork` at exact seq or latest completed turn
- session-controller: `session/prompt` queue and steer modes with request-id idempotency
- session-controller: empty-prompt continuation gated by the `conversationContinuation` projection
- session-controller: image and file-receipt prompt parts with model modality check
- session-controller: `session/attachment` image read
- session-controller: `session/updateQueue` edit, remove, steer
- session-controller: `session/cancel` keeping the inbox
- session-controller: `session/events` message-aligned backwards paging with turn window
- session-controller: `session/follow` snapshot, gap-free events, optional assistant-stream frames, optional activation
- session-controller: assistant-stream reconnect baseline with revision and nextIndex
- session-controller: `session/observeEvent` and `session/observeProjections` passive streams
- session-controller: `session/state`, `observeState`, `wait` with idle / input-required / timeout
- session-controller: `session/projections` sequenced, migration-required, or null
- session-controller: `session/control` host-wide projection baseline and updates
- session-controller: subagent addresses validated against parent and projected identity
- session-controller: `openWorkspacePath`, `workspacePathApplications`, `canOpenWorkspacePath`
- session-controller: `/api/file` versioned media route with sandboxing headers
- session-controller: `fileReferences/list` and `skills/list`
- session-controller: `api-session/*` events
- session-controller: archived-session pre-step gate across subagent lineage
- session-controller: `sessionListMetadata` and `imageLimits` projections
- job-controller: `job/list` whole-set roster stream with coalescing
- job-controller: `job/follow` anchor, byte-budgeted output frames, lossy flag, terminal status
- job-controller: `job/kill` with owner fence and `job/not-found`
- settings-controller: `settings/describe` redacted namespaces
- settings-controller: `settings/update`, `replace`, `mutate` with revision conflict
- settings-controller: `settings/openSettingsDocument`
- settings-controller: `credentials/describe` batch, `set`, `unset` with reference grammar
- terminal-controller: `terminal/environment` and `terminal/shells`
- terminal-controller: `terminal/create` idempotent per id with quotas
- terminal-controller: `terminal/list` and `terminal/watch` without Agent activation
- terminal-controller: `terminal/attach` snapshot, ordered output, state, acks
- terminal-controller: single input controller; read-only and not-running refusals
- terminal-controller: input sequence gap detection and input byte limit
- terminal-controller: resize bounds and emulator resize
- terminal-controller: slow follower failure without stopping the process
- terminal-controller: `terminal/retain` holds and unattended idle reclamation
- terminal-controller: `terminal/rename` and idempotent `terminal/close`
- terminal-controller: Agent terminals with sandbox confinement, control handoff on typed input, quota
- terminal-controller: screen paging and marks for the Agent
- workspace-controller: workspace create, rename, delete, reorder
- workspace-controller: session reorder, archive with activity check or stop, unarchive, pin, unpin
- workspace-controller: `workspace/initializeDefault` under the Documents directory
- workspace-controller: `workspace/follow` baseline and increments with access-filtered `replace`
- workspace-controller: `directoryPicker/pick`, `list`, `createDirectory` with capability gating
- workspace-files: `workspaceFileScope` lookup from live or stored Session header
- workspace-files: paged text read with line and byte caps and non-text detection
- workspace-files: byte-range and whole-file binary read
- workspace-files: stat and workspace-confined directory listing
- workspace-files: ripgrep name and path search with bounds and incomplete flag
- workspace-files: watch stream with ready and change frames
- directory-picker: capability union seam `native` / `browse`
- directory-picker-auto: boot-time backend choice from bind, trust, SSH, platform, display facts
- directory-picker-auto: mounts backend and client surface as Loader entries and unmounts both
- directory-picker-browse: bounded name-sorted listing with crumbs, hidden flag, truncation
- directory-picker-browse: child directory creation with exists and failure codes
- directory-picker-native: macOS panel, zenity then kdialog, Win32 dialog; cancel returns null
- open-in-app: `GET /open-in-app/apps`, `GET /open-in-app/icon/<id>`, `POST /open-in-app/open`
- open-in-app: lazy catalog resolution and one refresh on a missing executable
- plugin-inventory: `pluginInventory/list` entries with fiber phase, diagnostics, preset compositions
- product-telemetry-otel: batched OTLP log export with shutdown deadline
- web-app bundle: `dsh --profile web` flags `--host`, `--port`, `--no-open`, `--public-url`, `--trusted-host`, `--tls-cert`, `--tls-key`
- web-app bundle: prints `dsh web: <url>?token=…` after the tree settles; opens the browser unless suppressed
- web-app bundle: `DSH_WEB_URL` shell variable
- web-app bundle: cordis.patch.yml row overrides, inserts, disables, and `!!js` config expressions
