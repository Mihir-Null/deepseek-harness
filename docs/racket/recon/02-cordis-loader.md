# Recon 02: the Cordis loader stack

Pinned commit `e8f7b93a3`. This note covers the vendored loader stack (`vendor/loader`, `vendor/include`, `vendor/group`, `vendor/hmr`, `vendor/timer`, `vendor/logger-console`, `vendor/schemastery`), the DSH hot-reload package `packages/boot/hmr`, and the loader-related scripts under `scripts/`. Line references are `path:line` against the pinned tree. `vendor/README.md` lists every local divergence from upstream as V1 to V27; the ones that change behavior in this area are V9, V11, V14, V15, V22, V23, V25, V26 and V27.

## Scope

| Directory | npm name (version) | Role | Source lines | Depth in this note |
|---|---|---|---|---|
| `vendor/loader` | `@deepseek-ai/cordis-plugin-loader` (1.1.0, upstream 1.0.0-rc.8) | `ctx.loader` service: entry tree, entries, groups, module import, `!!js` interpolation, isolate/intercept realms, volatile config commits | 1,224 | full |
| `vendor/include` | `@deepseek-ai/cordis-plugin-include` (1.1.0, upstream 1.1.1) | File-backed entry tree: YAML/JSON read, patches, journal, three-way reconcile, atomic write-back | 968 | full |
| `vendor/group` | `@deepseek-ai/cordis-plugin-group` (1.1.0) | Three-line re-export of `Group` from the loader as a default plugin | 3 | full |
| `vendor/hmr` | `@deepseek-ai/cordis-plugin-hmr` (1.1.0, upstream 1.0.15) | Upstream hot module replacement service `ctx.hmr`; kept, but DSH profiles use `packages/boot/hmr` | 464 | full |
| `vendor/timer` | `@deepseek-ai/cordis-plugin-timer` (1.2.0) | `ctx.timer` service and `ctx.timeout/interval/throttle/debounce` mixins | 153 | full |
| `vendor/logger-console` | `@deepseek-ai/cordis-plugin-logger-console` (1.1.0) | Console exporter for the core logger service (node and browser entries) | 145 | full |
| `vendor/schemastery` | `@deepseek-ai/schemastery` (3.19.0, upstream 3.18.0) | Schema DSL used for every plugin `Config` | 962 | full |
| `packages/boot/hmr` | `@deepseek-ai/dsh-hmr` (0.2.2-rc.2) | DSH `ctx.hmr`: serialized module reload, Include refresh, exact config-path watches, profile reconciliation | 1,740 | `index.ts`, `watch-config.ts`, `module-files.ts` in depth; `package-manifest.ts` (330 lines of Node internals patching) at catalog depth |
| `scripts/` (23 files) | not a package | Specs and gates for the loader stack | 5,022 | behavior-pinning specs in depth; generators at catalog depth |

Scripts matched by `ls scripts | grep -i -E 'cordis|loader|volatile|include'`:

| File | Role |
|---|---|
| `cordis-entry-commit.spec.ts` | Tree mutation reports (`commit(change)`), self-disposal, adoption, `:` ids, `applyEntryPatches` cloning |
| `cordis-include-journal.spec.ts` | Include journal, file/runtime merge, conflicts, patch routing, cross-tree moves |
| `cordis-loader-resolve.spec.ts` | `resolve.ts` project-scoped resolution without Node internals |
| `cordis-timer.spec.ts` | Timer iterator ordering and cancellation |
| `cordis-vendor-hmr-include.spec.ts` | Vendor HMR logs a rejected `Include.refresh()` |
| `cordis-config-access.spec.ts` | `Fiber.rawConfig`, `resolveConfig`, `effectiveConfig` (core, used by the loader) |
| `cordis-core-lifecycle.spec.ts`, `cordis-core-api.spec.ts`, `cordis-core-api.ts` | Core lifecycle spec and core API page generator (core area; catalog depth) |
| `loader-config-diff.spec.ts` | `equalExceptVolatile` |
| `loader-volatile-update.spec.ts` | Volatile commits through Loader, Group, Include, real YAML |
| `volatile-config.spec.ts`, `volatile-config.fixture.ts` | Schemastery `.volatile()` and Cosmokit `deepEqual` semantics |
| `cordis-yaml.ts` | Repository-side YAML parser with the `!!js` tag; `isCordisGroupEntry`, `isAgentPresetEntry`, `presetDefinitions` |
| `cordis-config-files.ts`, `cordis-config-files.spec.ts` | Globs `**/*cordis*.yml` and `**/*cordis*.yaml` (excluding `.i18n.yaml`, `vendor/`, `node_modules/`, `.claude/`) |
| `verify-cordis-config.ts`, `verify-cordis-config.spec.ts` | Gate: `!!js` only in `config` and in the `disabled` field itself; named plugins resolve from the owning manifest |
| `cordis-walk.ts` | AST helper for `declare module '@deepseek-ai/cordis'` merges |
| `gen-cordis-catalog.ts`, `gen-cordis-catalog-partition.spec.ts`, `gen-cordis-inspect-catalog.ts`, `gen-cordis-api.ts` | Documentation and model-visible catalog generators (catalog depth; TypeScript tooling, no runtime behavior) |

Closely related code outside the area, referenced but not specified here: `vendor/cordis` (kernel hooks `internal/config`, `internal/commit`, `internal/update`, `internal/plugin`, logger service), `vendor/cosmokit` (`deepEqual`, `clone`, volatile references, `Time`), `packages/boot/app-boot` (bundle and profile patch composition, `mountRootInclude`, `recomposeProfile`).

## Services

### `ctx.loader` (class `Loader`, `vendor/loader/src/index.ts:77-217`)

`Loader extends EntryTree`. It is not a `Service` subclass: its constructor calls `ctx.reflect.provide('loader', this, this[Service.check])` and defines the tracker `{ associate: 'loader', property: 'ctx', noShadow: true }`. The service lives as long as the fiber that plugged `Loader`. Its constructor also installs four kernel hooks (see Events) and plugs the internal `isolate` plugin (`ctx.plugin(isolate)`).

Fields:

- `name = 'loader'`.
- `config: Loader.Config` (`{ baseUrl?: string }`); when set, `this.ctx.baseUrl = config.baseUrl`.
- `envData`: `JSON.parse(process.env.CORDIS_SHARED)` when that variable is set, else `{ startTime: Date.now() }`.
- `internal`: `ModuleLoader.fromInternal()`, the Node internal ESM loader or `undefined` (`internal.ts:131-143`). Tests set it to `undefined` to force the portable path.
- `builtins: Dict<any>` (null-prototype): the table behind `cordis:<key>` names. Empty by default. App-boot sets `builtins.include` and `builtins.group` (`packages/boot/app-boot/src/index.ts:765-783`).
- Inherited from `EntryTree`: `ctx`, `enableLogs?`, `root: EntryGroup`, `store: Dict<Entry>` (flat, one per tree, keyed by tree-local id).

Methods:

| Method | Semantics |
|---|---|
| `create(options, parent = null, position = Infinity): Promise<string>` | Resolve the target group (`null` is this tree's root; otherwise a nested id whose entry has a subgroup), assign an id if absent, splice `options` into `group.data` at `position`, call `group.tree.commit({ id, group, options })` synchronously, then `group.create(options)`. Resolves to the full nested id (`Entry.id`) once the entry's first update returned, that is after import and plug; the fiber may still be pending or loading, which `loader.await()` covers. |
| `update(id, options, parent?, position?): Promise<void>` | Merge `options` into the entry (null or undefined values delete keys), optionally move it (`parent === undefined` keeps the group; `null` moves to this tree's root), force a context patch, report through `commit`. See Algorithms 7. |
| `remove(id): void` | Unregister, dispose the fiber (not awaited), unlink from `group.data`, `commit({ id, group, legacy })`. |
| `resolve(id): Entry` | Split on `:`; every segment except the last selects `store[segment].subtree`; the last selects from the final tree's store. Throws `cannot resolve entry ${id}`. |
| `resolveGroup(id): EntryGroup` (id may be `null`) | `null` or empty returns `root`; else the entry's `subgroup`, or throws `entry ${id} is not a group`. |
| `entries(): Generator<Entry>` | Depth-first over `Object.values(store)`, descending into `entry.subtree`. |
| `getTasks(): Promise[]` | For every entry, `entry._initTask`, or else `entry.fiber?.inertia`; non-null values only. |
| `await(): Promise<void>` | Loop: `Promise.allSettled(getTasks())` until `getTasks()` is empty. |
| `ensureId(options): string` | Assign `Math.random().toString(16).slice(2, 10)` (8 hex characters) until unused in `store`. Explicit ids are accepted unchanged, including ids containing `:` (V27). |
| `import(name, getOuterStack?)` | Module import; see Algorithms 10. |
| `commit(change): void` | No-op in `Loader` (in-memory root tree). Abstract in `EntryTree`. |
| `locate(fiber = ctx.fiber)`: string or `undefined` | Walk `fiber.parent.fiber` upward until a fiber has `.entry`; return that entry's full id. |
| `exit(): void` | No-op hook; hosts override it to restart the process on a full reload request. |
| `unwrapExports(exports)` | Null passes through. `exports = exports.default ?? exports`; if `!exports.__esModule` return it; else return `exports.default ?? exports`. A namespace with a `default` export therefore loses its named exports (`name`, `inject`, `Config`, `apply`). |
| `showLog(entry, type)` | If the entry is not a group and `entry.parent.tree.enableLogs` is truthy: `ctx.root.logger?.('loader').info('%s plugin %C', type, entry.options.name)` with `type` one of `apply`, `reload`, `unload`. |
| `[Service.check]()` | Merge the dependent's intercept config for `loader` (`Loader.Intercept = { await?: boolean }`); return `false` when `await` is true and `getTasks()` is non-empty. A plugin with `inject: { loader: { await: true } }` stays pending until every entry finished importing and loading. `Entry.init()` calls `ctx.reflect.notify(['loader'])` when the task list drains (`entry.ts:219-222`). |

Context and fiber additions made by this package: `ctx.baseUrl` (declared in core, used here as the base for relative names and paths; every `EntryTree` owns its own `baseUrl` property through `ctx.extend({ baseUrl: ctx.baseUrl })`), `fiber.entry?: Entry`, the context key `Entry.key = Symbol.for('cordis.entry')`, and the plugin marker `EntryGroup.key = Symbol.for('cordis.group')`.

### `Entry`, `EntryGroup`, `EntryTree`, `Group`, `Include` (objects, not `ctx` keys)

- `Entry` (`config/entry.ts:43-239`): fields `loader`, `ctx` (created as `loader.ctx.extend({ [Entry.key]: this })`, re-parented to `parent.ctx` on every context patch), `fiber?` (the registry wrapper returned by `ctx.registry.plugin`; the canonical fiber is `entry.fiber.ctx.fiber`), `moduleNamespace` (raw import result, V23), `parent: EntryGroup`, `options: EntryOptions`, `subgroup?`, `subtree?`, `realm` (lazily created `LocalRealm`), `_initTask?`. Getters `id` and `disabled`. Methods `update(options, create = false, force = false)`, `init()`, `refresh()` (`init()` only when there is no fiber and the entry is not disabled), `evaluate(expr)`, `getOuterStack()`.
- `EntryGroup` (`config/group.ts:6-73`): fields `ctx`, `tree`, `data: EntryOptions[]`. Methods `create(options)`, `unlink(options)`, `remove(id, isDispose = false)`, `update(config)`, `stop()`. Its constructor sets `ctx.fiber.entry.subgroup = this` when the owning fiber has an entry.
- `EntryTree` (`config/tree.ts:44-205`): abstract; constructor sets `ctx.fiber.entry.subtree = this` when the owning fiber has an entry. `static sep = ':'`.
- `Group` (`config/group.ts:76-89`): class plugin, `static initial = []`, `static [EntryGroup.key] = true`. Its constructor takes the entry list as config, belongs to the tree of its own entry (`ctx.fiber.entry.parent.tree`), and registers a fiber-local `internal/update` listener `config => this.update(config)` that never calls `next()`, so a group fiber reconciles children instead of restarting. `[Service.init]` is an async generator: `yield () => this.stop()` then `await this.update(this.config)`.
- `Include` (`vendor/include/src/index.ts:86-463`): class plugin extending `EntryTree`, `static inject = ['loader']`, `static [EntryGroup.key] = true`. Public surface: `filename`, `config`, `flush()`, `refresh()`, `stop()`, `commit(change)`, plus everything from `EntryTree`. HMR providers find an Include by scanning `loader.entries()` for `entry.subtree.filename` (V14).

### `ctx.timer` (class `TimerService`, `vendor/timer/src/index.ts`)

`TimerService extends Service`, `super(ctx, 'timer')`, then `ctx.mixin('timer', ['timeout', 'interval', 'throttle', 'debounce', 'setTimeout', 'setInterval'])`, so the methods are callable as `ctx.timeout(...)` and so on. No config, no inject. Every timer is registered with `ctx.effect(...)` on the calling fiber, so disposing the fiber cancels it. Effect labels: `'ctx.timeout()'`, `'ctx.interval()'`, `'ctx.throttle()'`, `'ctx.debounce()'`.

| Method | Semantics |
|---|---|
| `timeout(callback, delay): () => void` | Run `callback` once after `delay` ms. The returned disposer cancels. When the timer fires it disposes its own effect first, then calls the callback. |
| `timeout(delay): Promise<void>` | Resolves after `delay`. If the owning fiber is disposed first it rejects with `new Error('Context has been disposed')`. The effect is disposed in `finally`. |
| `interval(callback, delay): () => void` | Repeating timer; returns the disposer. |
| `interval(delay): AsyncIterableIterator<void>` | Each tick resolves the oldest pending `next()` with `{ done: false, value: undefined }`; a tick with no pending reader is discarded. `return(value)` records `{kind:'return'}`, resolves every pending read with `{ done: true, value }`, disposes the timer. `throw(reason)` rejects every pending read with `reason`, disposes, and itself resolves `{ done: true, value: undefined }`. Fiber disposal rejects every pending read with `Error('Context has been disposed')`. After the iterator is done, `next()` returns the recorded outcome (resolved `{done: true, value}` or rejected reason). |
| `throttle(callback, delay, noTrailing?)` | Returns a wrapper with `.dispose()`. `lastCall` starts at `-Infinity`. On each call: clear any pending timer; `remaining = delay - now + lastCall`; if `remaining <= 0` run now and set `lastCall`; else unless `noTrailing` schedule the call with the latest arguments after `remaining`. The wrapper returns `void`. |
| `debounce(callback, delay)` | Wrapper with `.dispose()`; each call clears the pending timer and schedules `callback(...args)` after `delay`. |
| `setTimeout`, `setInterval` | Deprecated aliases of the callback forms. |

After `.dispose()` or fiber disposal, throttle and debounce wrappers are inert (calls do nothing, pending work is cancelled).

### `ctx.hmr`

Two providers register the same key; only one may be loaded.

Vendor `Hmr` (`vendor/hmr/src/index.ts:48-402`): `Service` subclass, `@Inject('loader') @Inject('timer')`, `super(ctx, 'hmr')`. Public: `baseDir` (absolute path of `new URL(config.base || '.', ctx.baseUrl)`), `config`, `getOuterStack()` (returns `[]`), `getLinked(url): Promise<string[]>`. The constructor throws `--expose-internals is required for HMR service` when `ctx.loader.internal` is absent.

DSH `Hmr` (`packages/boot/hmr/src/index.ts:211-991`): same key, same inject, same config schema, same events, plus:

| Method | Semantics |
|---|---|
| `runExclusive(operation): Promise<T>` | Serializes `operation` behind every queued reload. Rejects `HMR transactions cannot be nested` when called from inside a running transaction (tracked with `AsyncLocalStorage`), and `HMR is disposed` when the service is closing. A failed operation does not poison the queue. |
| `watchConfig(filename, refresh): Promise<() => Promise<void>>` | Register an exact-path watch (see Algorithms 21) whose `refresh` runs through the same queue after application readiness. Throws `config path already registered: ${filename}` for a duplicate. The returned disposer closes the watcher and waits for a running refresh. |
| `reconcileProfile(requiredIds = []): Promise<ProfileReconciliation>` | Must run inside `runExclusive`. Compares loaded module files with disk, stops entries running changed code, delegates to app-boot `recomposeProfile`, evicts modules of dropped package mappings. Returns `{ warnings: string[], pending: PendingModule[], restartReason? }` where `restartReason` is `'module-comparison'` or `'package-moved'`; a `PendingModule` is `{ url, reason }` with reason `'host-module'`, `'unmanaged-plugin'` or `'module-comparison'`. |
| `getLinked(url)`, `getOuterStack`, `baseDir`, `config` | As upstream. |

It reads optional services with `ctx.get(...)`: `profileContext` (launcher data: `dir`, `home`, `patchPath`, `startedBundles`), `appReady` (`onReady(cb)`), `pluginPackages` (`resolution`).

### `ctx.logger` (core service, documented here because `logger-console` is its exporter)

Owned by `vendor/cordis/src/logger.ts`. `ctx.logger(name?)` returns a `Logger`; `ctx.logger.info(...)` and the other three methods log under the default name, which is the intercept config `logger.name` if set, else `hyphenate(fiber.name)`. `ctx.logger.exporter(exporter)` registers an `Exporter` as an effect and returns its disposer.

- Levels (`LoggerLevel`): `ERROR = 0`, `WARN = 1`, `INFO = 2`, `DEBUG = 3`. Types: `'error' | 'info' | 'warn' | 'debug'`.
- `Message`: `{ sn, ts, name, type, level, args, fiber?: WeakRef<Fiber> }`. `sn` is a service-wide counter, `ts` is `Date.now()`.
- `Exporter`: `{ colors?: number | false, maxLength?: number, levels?: Record<string, number>, formatters?: Record<string, Formatter>, export(message) }`.
- Per-exporter threshold: `exporter.levels?.[name] ?? exporter.levels?.default ?? logger.level ?? 2`; a message is exported when `threshold >= message.level`.
- A call with exactly one `Error` argument first logs `error.cause` recursively when present; otherwise, for an aggregate error (`errors` array), logs each inner error and stops.
- The service always holds one buffer exporter (`colors: 3`, ring buffer `bufferSize = 1000` in `ctx.logger.buffer`).
- `Logger.format`, `Logger.color`, `Logger.code` are specified under Algorithms 17.

## Events

| Event | Mode | Payload | Producer | Consumer | Notes |
|---|---|---|---|---|---|
| `loader/entry-init` | emit | `(entry: Entry)` | `Entry` constructor (`entry.ts:60`) | `isolate` plugin: gives `entry.ctx` its own `Context.intercept` and `Context.isolate` maps via `Object.create(...)` | Fired before `options` are assigned. |
| `loader/patch-context` | waterfall | `(entry: Entry, next: () => Awaitable<void>)` | `Entry._patchContext` (`entry.ts:101-112`) | `isolate` plugin wraps `next()`; the innermost callback re-parents `entry.ctx` and may update the fiber | Awaited. Fired on first init (`diff = []`) and on every non-trivial or forced update. |
| `loader/partial-dispose` | emit | `(entry, legacy: Partial<EntryOptions>, active: boolean)` | `Entry.update` with `active = true` just before a context patch; `EntryGroup.remove` with `active = false` after disposal | `isolate` plugin: garbage-collects named realms | |
| `loader/volatile-update` | emit | `(paths: readonly (readonly string[])[])` | `Entry._commitVolatile` | Listeners registered on the owning fiber only (filter `owner.fiber === fiber`); in-repo consumers include `llm-deepseek`, `llm-pi-ai`, `plugin-market`, `speech-to-text`, `product-analytics` | All references are committed before the single dispatch. A throwing listener is logged with `warn` and does not fail the update. A root reference reports the empty path `[]`. |
| `loader/config-update` | emit | `()` | `Include.commit` | none in the repository | |
| `exit` | not tagged; declared as returning `Promise<void>` | `(signal: NodeJS.Signals)` | none in this area | none in this area | Declaration only (`loader/src/index.ts:25`). |
| `hmr/change` | emit | `(url: string)` | HMR, for a changed watched file that is neither a cached module nor an Include file (DSH: nor a registered config path nor a manifest) | none required | |
| `hmr/reload` | emit | `(reloads: Map<Plugin, Reload>)`; `Reload = { filename, runtime?, modules? }` (`modules` only in DSH) | HMR after a successful partial reload | none required | |
| `internal/config` | waterfall (core) | `(fiber, next: () => any)` | core `Fiber.resolveConfig` | Loader listener (`index.ts:104-110`) interpolates `!!js`; core listener validates | Core's listener is registered first and calls `next()` before validating, so the order is raw config, then Loader interpolation, then schema validation. |
| `internal/commit` | emit (core) | `(fiber, originalConfig)` | core `Fiber.update(config, noSave = false)` | Loader listener (`index.ts:112-120`) writes simplified config into `entry.options.config` and calls `tree.commit` | Not fired when `noSave` is true. Loader-driven updates always pass `noSave = true`. |
| `internal/update` | waterfall (core), `this` is the fiber | `(resolvedConfig, next)` | core `Fiber.update` on a loaded fiber | Loader global listener logs `reload`; `Group` and `Include` register fiber-local listeners that reconcile instead of restarting | The default tail restarts the fiber. |
| `internal/plugin` | emit (core) | `(fiber)` | core, at fiber creation and at disposal (`fiber.uid === null`) | Loader listener (`index.ts:128-174`): binds `fiber.entry`, merges entry-level inject, detects self-disposal | |

## Tools

None.

## Configuration

| Plugin (export) | Form | Inject | Config |
|---|---|---|---|
| `Loader` (default export of `vendor/loader`) | class extending `EntryTree`; provides `loader` manually | none | `Loader.Config { baseUrl?: string }`, no schema. Intercept config `Loader.Intercept { await?: boolean }`. |
| `Group` (default export of `vendor/group`; also `cordis:group` when the host registers it) | class plugin, `static [EntryGroup.key] = true` | none | `EntryOptions[]` (the child entry list), no schema, never interpolated at the group level. `static initial = []`. |
| `Include` (default export of `vendor/include`; `cordis:include` in DSH) | class plugin extending `EntryTree` | `['loader']` (required) | `Include.Config`, no schema, never interpolated: `path: string` (required; resolved with `new URL(path, ctx.baseUrl)`, extension must be `.json`, `.yaml` or `.yml`), `initial?: any[]` (entry list written when the file does not exist), `patches?: PatchOptions[]`, `enableLogs?: boolean` (default: the parent tree's `enableLogs`, else `false`). |
| `TimerService` (default export of `vendor/timer`) | `Service` class, name `timer` | none | none |
| `ConsoleExporter` (default export of `vendor/logger-console`) | class plugin, `static name = 'logger-console'`; not a service | none (uses the always-present `ctx.logger`) | `static Config = z.object({ colors: z.union([z.const(false), z.number()]), maxLength: z.number(), levels: z.dict(z.number()), showDiff: z.boolean().default(false), showTime: z.string().default('yyyy-MM-dd hh:mm:ss '), label: z.object({ width: z.number(), margin: z.number(), align: z.union(['left', 'right']) }) })`. Instance defaults from `getDefaults()`: `colors: false` (node entry: `supportsColor.stdout.level`, else `0`), `showTime: 'yyyy-MM-dd hh:mm:ss '`, `showDiff: false`. |
| vendor `Hmr` (default export of `vendor/hmr`) | `Service` class, name `hmr` | `loader`, `timer` (required) | `Hmr.Config = z.object({ base: z.string(), root: z.array(String).role('table').default(['.']), ignored: z.array(String).role('table').default(['**/node_modules', '**/.*', 'cache', 'data']), debounce: z.natural().role('ms').default(100) })`. The interface extends Chokidar options; unknown keys pass through validation and are spread into `chokidar.watch`. |
| DSH `Hmr` (default export of `packages/boot/hmr`) | `Service` class, name `hmr` | `loader`, `timer` (required); optional `profileContext`, `appReady`, `pluginPackages` through `ctx.get` | Same schema as the vendor one (`static Config`). Exact config watches default to `awaitWriteFinish: true`. The base bundle mounts it as `- id: hmr, name: '@deepseek-ai/dsh-hmr', disabled: !!js "!ctx.get('profileContext')", config: { root: [] }`. |

`Schemastery` has no plugin; its API is specified under Formats and Algorithms 18 and 19.

Package-level display metadata: `vendor/timer/locale/{en,zh}.json` (`{ "meta": { "title": "timer" } }`) and `packages/boot/hmr/locale/*.json` (`meta.title = "hmr"`); `vendor/hmr/package.json` declares `"@deepseek-ai/cordis": { "services": { "required": ["timer"] } }`.

## Formats

### Entry (`cordis.yml` row, `EntryOptions`)

A config file is a top-level array of entries. The keys the loader stack reads are exactly these (`entry.ts:10-23`, `isolate.ts:5-9`):

| Key | Type | Meaning |
|---|---|---|
| `id` | string | Tree-local stable identity. Must be unique within one tree across all its groups (the store is flat). Generated when absent: 8 lowercase hex characters from `Math.random().toString(16).slice(2, 10)`. May contain `:` when explicit, but then cannot be addressed by nested path. |
| `name` | string | Module specifier: `cordis:<builtin>`, a relative path (starts with `.`), or a bare package name or URL. |
| `config` | any | Passed to the plugin. For a group it is the child entry list. May contain `!!js` nodes at any depth. |
| `group` | boolean or null | Marks the entry as a carrier of child entries in `config`. A group entry is never considered disabled itself. It also gates patch indexing and insertion into the `config` list. It does not select the implementation; `name` does. |
| `disabled` | boolean, null, or a `!!js` node | Truthy keeps the entry in the tree without a fiber. Only the field itself may be an expression. |
| `inject` | string array, object (name to intercept config or null), or null | Extra required services for the entry's fibers, merged into `fiber.inject` at fiber creation. |
| `intercept` | object or null | Becomes the own properties of `entry.ctx[Context.intercept]` (per-service intercept config for everything under the entry). |
| `isolate` | object: service name to `true` or a string label; or null | `true` gives the entry a private realm for that service name; a string label shares a named realm among all entries using the same label and name. |

There is no `when`, `label` or `collapse` entry key at this commit. "Label" exists only as the string value inside `isolate`; `collapse` is Schemastery UI metadata. Unknown keys are kept in `entry.options`, sorted with the rest, and written back; nothing reads them. Key order on every `Entry.update` is normalized by `sortKeys` (`entry.ts:35-40`): `id`, `name`, then all other keys sorted with `localeCompare`, then `config` last.

Full entry ids: `Entry.id` is the tree-local id prefixed by the id of the entry that owns the tree, joined with `:` (`entry.ts:67-73`). Only tree carriers (Include) add a segment; a group in the same tree does not. Example: the DSH root include has id `include`, a row `plan-mode` inside a group `planning` of the included file has full id `include:plan-mode`.

### YAML dialect and JSON files

- YAML is parsed with `js-yaml` `JSON_SCHEMA` extended by one type (`include/src/index.ts:16-26`): tag `tag:yaml.org,2002:js` (written `!!js`), kind scalar, accepted when the scalar is a string, constructed as the object `{ __jsExpr: <string> }`, and represented back as the scalar expression string. JSON schema means: no timestamps, no merge keys, no binary; `yes`/`no`/`on`/`off` are strings.
- `entryListSchema` is the exported name of this dialect (V11). App-boot and the config editor use the same schema for patch files and dumps.
- A JSON config file is `JSON.parse`d; an object `{"__jsExpr": "..."}` is an expression node there too because `isJsExpr(value)` is `value instanceof Object && '__jsExpr' in value` (`utils.ts:25-27`).
- Dumps: YAML through `yaml.dump(data, { schema })` with js-yaml defaults (indent 2, line width 80, references allowed); JSON through `JSON.stringify(data, null, 2)` without a trailing newline.
- The file must parse to an array. Anything else (including an empty file, which parses to `undefined`) is `ConfigFileError('validate', path, TypeError('config file must be a top-level array'))`.
- `ConfigFileError` has `name = 'ConfigFileError'`, `stage: 'read' | 'parse' | 'validate'`, message `failed to ${stage} config file ${path}`, and the underlying error as `cause`.

### `!!js` expressions

- Evaluation function (`utils.ts:5-9`): `new Function('ctx', 'expr', 'with (ctx) { return eval(expr) }')`. The expression is a JavaScript expression (statements work only as far as `eval` returns their completion value).
- Scope: bare identifiers resolve first against the context (the `with` scope uses the context proxy's `has` trap: own or inherited context properties such as `baseUrl`, and every declared service, accessor or mixin name), then the function parameters `ctx` and `expr`, then JavaScript globals (`process`, `JSON`, `Number`, `URL`, ...). So `dshHomePath('sessions')`, `ctx.get('profileContext')`, `ctx.headlessStartup.task`, `baseUrl` and `process.env.X ?? 'y'` are all valid.
- `config`: interpolated by `interpolate(fiber.ctx, config)` (`utils.ts:12-22`), which walks arrays and plain objects recursively and replaces every expression node by its value. It runs inside `internal/config`, that is at every activation of the entry's root fiber (after its injections are satisfied), on every `fiber.resolveConfig(candidate)` (volatile candidates), and on every `fiber.update` of a loaded fiber. The context is the plugin fiber's own context, so injected services are readable as `ctx.<name>`. The raw config with expression nodes stays in `entry.options.config` and `fiber.rawConfig`; write-back keeps the expression form.
- Interpolation applies only when `fiber.entry` is set, the fiber is the entry's root fiber (`fiber.parent.fiber?.entry !== fiber.entry`), and the plugin callback does not carry `EntryGroup.key`. Group and Include configs are therefore passed raw, and each child evaluates its own expressions against its own context.
- `disabled`: when the field is an expression node it is evaluated with `evaluate(entry.ctx, expr)` and coerced with `Boolean` on every read of `Entry.disabled`, that is at every mount decision (`entry.ts:91-95`). The context is the entry context (child of the group context), not a plugin fiber context, so only services visible without injection are reachable; configs use `ctx.get('name')` for optional services. A throwing expression propagates out of `Entry.update`.
- All other metadata (`id`, `name`, `group`, `inject`, `intercept`, `isolate`, and anything nested below a non-expression `disabled`) is never interpolated; an expression node there is a truthy object. `scripts/verify-cordis-config.ts` rejects such placements with `!!js is not interpolated here`.

### Patch format (`PatchOptions`, `include/src/patch.ts:5-16`)

A patch list is an array of mappings. There are exactly two operations; there is no `before`, `after`, `replace`, `remove`, `when` or `preset` operation in this package. Agent presets are ordinary entries named `@deepseek-ai/dsh-agent-preset` whose `config.plugins` holds a nested entry list (`scripts/cordis-yaml.ts:60-66`); bundle and profile layering is done by app-boot, which concatenates the layers' patch lists and passes them as the root Include's `patches`, so one `applyPatches` call composes them (`packages/boot/app-boot/src/index.ts:789-800`).

| Shape | Operation |
|---|---|
| `{ insert: Entry[] }` | Append clones of the entries to the end of the root list. |
| `{ id: <group id>, insert: Entry[] }` | Append clones to the end of the `config` list of the group entry with that id. |
| `{ id: <entry id>, name?: <string>, ...overrides }` | For every key other than `id`, `insert`, `name`: `target[key] = value` (whole-value replacement, no deep merge; `config` is replaced wholesale). A truthy `name` is an assertion that must equal the target's name. |

Removal is expressed as `{ id, disabled: true }`. Positioned insertion is not expressible in a patch.

### `EntryChange` (argument of `EntryTree.commit`, `tree.ts:22-28`)

`{ id: string (tree-local), group: EntryGroup, from?: EntryGroup, options?: EntryOptions, legacy?: EntryOptions }`. No `options`: removal from `group`. No `legacy`: creation in `group`. Both: update; `from` is set only when the update moved the entry between groups of the same tree.

### Journal record (in memory, `include/src/journal.ts:5-32`)

`Journal = Map<id, JournalRecord>`. `JournalRecord` is `{ kind: 'remove' }` or `{ kind: 'upsert', created: boolean, parent: string | null | undefined, position: number, changes: Dict }`. `parent` is the tree-local id of the target group, `null` for the root, `undefined` when the entry was not relocated. In `changes`, an `undefined` value deletes the key.

### Files written

- Include write-back: temp file `.<basename>.<pid>.<seq>.tmp` beside the target, then `rename` over the target; up to 10 retries on `EACCES`, `EPERM`, `EBUSY` with back-off `20 ms * (attempt + 1)` (`index.ts:63-75`, `369-393`).
- Resolver helper (`loader/src/resolve.ts`): in the nearest ancestor directory of the config that has a `package.json`, a directory `.cordis/` containing `.gitignore` (`# created by cordis automatically\n*\n`) and `resolve.mjs` (`export default (specifier) => import.meta.resolve(specifier)\n`), each written as `<name>.<pid>` then renamed.
- DSH HMR clock marker: `mkdtemp(<tmpdir>/dsh-hmr-clock-)` with a file `now`, removed immediately.

### Environment variables and command line

- `CORDIS_SHARED`: JSON for `loader.envData`.
- Node flag `--expose-internals` (or the optional addon `node-addon-require-builtin`) gives `loader.internal`; both HMR providers need it.
- `vendor/cordis/bin.js`: sets `ctx.baseUrl` to the current directory URL with a trailing slash, plugs `Loader`, and creates one entry `{ name: '@deepseek-ai/cordis-plugin-include', config: { path: './cordis.yml' } }`. It takes no flags.

### Schemastery JSON serialization

`schema.toJSON()` (invoked by `JSON.stringify(schema)`) returns `{ "uid": <root uid>, "refs": { "<uid>": <node>, ... } }`. Every node is the schema's own enumerable properties: `type`, `meta`, and whichever of `inner`, `sKey`, `list`, `dict`, `bits`, `value`, `callback`, `constructor`, `preserve` it has. Child schemas are replaced by their numeric uid. `callback` is the function source text; a function `constructor` is its `name`; `builder` (lazy) is dropped; a lazy node serializes `"inner": <uid of the built schema>`. `uid` comes from a process-global counter (`globalThis.__schemastery_index__`), is non-enumerable and never appears inside a node; the concrete numbers depend on how many schemas the process created before. Output of `JSON.stringify(z.object({ root: z.array(String).role('table').default(['.']) }))` in a fresh process (run against the vendored source):

```json
{"uid":5,"refs":{"2":{"type":"string","meta":{"required":true}},"4":{"type":"array","meta":{"default":["."],"role":"table"},"inner":2},"5":{"type":"object","meta":{"default":{}},"dict":{"root":4}}}}
```

Hydration: `new Schema(json)`. When the argument has `refs`, every ref is constructed, then `sKey`, `inner`, `list`, `dict` uids are replaced by the constructed schemas and `refs[uid]` is returned. A string `callback` is revived with `new Function('return ' + callback)()` (errors ignored). A node without `meta` gets `meta = {}`. A hydrated schema gets new uids.

`Meta` fields: `default`, `required`, `volatile`, `disabled`, `collapse`, `badges: { text, type }[]`, `hidden`, `loose`, `role`, `extra`, `link`, `description: string | Dict<string>`, `comment`, `pattern: { source, flags? }`, `max`, `min`, `step`.

Standard Schema face: `schema['~standard'] = { version: 1, vendor: 'schemastery', validate(value) }` returning `{ value }` or `{ issues: [{ message, path }] }` for a `ValidationError`; other errors propagate. Core config validation calls this.

### Console log line (`logger-console/src/shared.ts:73-99`)

`<time><[E|W|I|D]> <name> <text>[ +<diff>]`, for example `2026-07-22 15:44:36 [I] hmr watching [ '.' ]`. Precisely: prefix is `[` + upper-cased first letter of the type + `]`; `space` is `label.margin ?? 1` spaces; time is `Time.template(showTime)` (tokens `yyyy`, `yy`, `MM`, `dd`, `hh`, `mm`, `ss`, `SSS`, each replaced once) colored with code 8; the name is colored with `Logger.code(name, colors)` and decoration `;1`; with `label.align === 'right'` the order is padded name, space, prefix, space, otherwise prefix, space, name padded to `label.width`, space. Continuation lines are indented by `3 + space.length + showTime.length` (plus `width + space.length` when right-aligned). With `showDiff`, ` +<Time.format(ms since previous message)>` is appended in the name color. The node entry prints with `console.log`; the browser entry calls `console.error|warn|log('[I] name', ...args)` without formatting.

## Algorithms and invariants

### 1. Entry lifecycle

1. Creation: `EntryGroup.create(options)` (`group.ts:20-29`) ensures an id, takes `tree.store[id]` or constructs `new Entry(loader)` (which emits `loader/entry-init`), sets `entry.parent = this`, and awaits `entry.update(options, true, true)`. An id that already exists in the tree's store is adopted, not duplicated: this is how a file edit that moves a row between groups keeps the running fiber.
2. `Entry.init()` (`entry.ts:213-238`): `_initTask ??= _init()` deduplicates concurrent calls. `_init` imports `options.name` through `parent.tree.import`; an import error is logged with `ctx.logger.error` and the entry is left without a fiber (no throw). Otherwise: unwrap exports, `_patchContext([])`, `showLog('apply')`, `this.fiber = this.ctx.registry.plugin(plugin, this.options.config, this.getOuterStack)`, then record `moduleNamespace`. After the task, when the loader has no remaining tasks, `ctx.reflect.notify(['loader'])` wakes `await: true` dependents.
3. Because the plugin is registered on `entry.ctx`, which carries `Entry.key`, the Loader's `internal/plugin` listener sets `fiber.entry` for the new fiber and for every descendant fiber created under it, and calls `Inject.resolve(entry.options.inject, fiber.inject)` for each (array form adds `name: null`; object form adds `name: config ?? null`). Core resolves dependencies after that notification, so entry-level `inject` gates activation. The intercept config carried by an object-form `inject` is not applied (source comment `FIXME merge config`); use `intercept` for that.
4. `getOuterStack()` yields one frame per ancestor entry: `    at ${tree.ctx.baseUrl}#${options.id}`.
5. Removal: `EntryGroup.remove(id, isDispose)` (`group.ts:37-47`) returns when the entry is unknown or belongs to another group; otherwise deletes it from the store first, calls `entry.fiber?.dispose()` without awaiting, unlinks the options from `data` unless `isDispose`, and emits `loader/partial-dispose(entry, entry.options, false)`. `EntryGroup.stop()` removes every row with `isDispose = true`.

### 2. Disabled state

`Entry.disabled` (`entry.ts:76-85`): `false` when `options.group` is truthy; otherwise true when the entry's own `disabled` or that of any owning entry (`entry.parent.ctx.fiber.entry`, repeatedly) resolves truthy. Consequences: a disabled group still mounts its group fiber and creates child entries, but every child is disabled; a disabled Include is disposed and its children with it.

### 3. `Entry.update(options, create, force)` (`entry.ts:121-160`)

1. `legacy = { ...this.options }`. With `create`, `this.options = options` (the same object that sits in `group.data`; identity matters for `indexOf`). Otherwise each key is assigned, and a null or undefined value deletes the key. Then `sortKeys`. This part is synchronous, so `commit()` callers see the new options before the first `await`.
2. If `this.disabled`: `await this.fiber?.dispose()` and return. No event, no log besides the Loader's `unload`.
3. If there is no live fiber (`!this.fiber?.uid`): `await this.init()`.
4. Otherwise compute `changes`: keys of `{ ...options, ...legacy }` whose values differ under `deepEqual(a, b, strict = key === 'config')`. Strict comparison distinguishes `null` from `undefined`, compares class instances by identity (except `Date`, `URL`, `RegExp`, array buffers) and treats two volatile references as equal.
5. Volatile-only test: exactly one change, `config`; `fiber.state === ACTIVE`; `Object.getPrototypeOf(this.ctx) === this.parent.ctx` (context unchanged); and `equalExceptVolatile(legacy.config, options.config, fiber.runtime?.Config)`. When true, `fiber.rawConfig = options.config` and `_commitVolatile()` runs; if it returns true the pending change list is empty.
6. If nothing is pending and `force` is false, return. Otherwise emit `loader/partial-dispose(this, legacy, true)` and `await _patchContext(pending)`.
7. `_patchContext(diff)` (`entry.ts:101-112`): inside the `loader/patch-context` waterfall, set the prototype of `entry.ctx` to `parent.ctx`; then, if the fiber is live and (`diff` contains `config` or the entry is a group), call `fiber._checkImpl(name)` for every injected name (V25: refresh bindings first) and `await fiber.update(options.config, true)`.

Invariants that follow: only a `config` change (or any change on a group entry) reaches the fiber's update waterfall, whose default is a restart. `isolate` and `intercept` changes take effect through the context patch and service notifications. A changed `name` or `inject` on a live entry has no effect until the entry is next initialized. A group update always re-runs `Group.update(config)`, which re-evaluates each child (this is how toggling a group's `disabled` reaches children). Loader-driven updates never emit `internal/commit`.

### 4. `equalExceptVolatile` (`config/diff.ts:17-45`)

For a non-Schemastery schema (`schema['~standard'].vendor !== 'schemastery'`) or no schema: strict `deepEqual`. Otherwise `equal(a, b, schema, ancestors)`: a node with `meta.volatile` is equal regardless of values; a node that is not an `object` schema with a `dict`, or one already on the ancestor stack (recursive schema), compares strictly; for an object node, a null or undefined side is replaced by `schema.meta.default`; if either side is then not a plain record (expression nodes are not records) compare strictly; else every key of either side must be equal under the child schema (`Object.hasOwn(dict, key)`, unknown keys strictly). It never evaluates expressions, validators or hooks and never mutates its inputs.

### 5. `_commitVolatile` (`entry.ts:167-200`)

1. `fiber = this.fiber.ctx.fiber`; `refs = volatileEntries(fiber.effectiveConfig)` (paths of references through plain objects and arrays; array indexes are string keys). No refs: return true.
2. `candidate = fiber.resolveConfig(options.config)`. On a throw: `warn('volatile config update failed for %C', id)`, `warn(error)`, return true; running references are unchanged and the raw config stays retained for the next activation.
3. If `!deepEqual(fiber.effectiveConfig, candidate, true)` (an ordinary effective value changed, for example through an expression): `debug('ordinary config values of %C changed with its volatile values; applying the ordinary update', id)` and return false, which makes the caller run the ordinary update.
4. For each ref, read the candidate reference at the same path; skip when `deepEqual(ref.get(), source.get(), true)`; else `updateVolatile(ref, source)` and collect the path.
5. If any path changed, emit `loader/volatile-update(paths)` once on a derived context whose filter admits only listeners whose owner fiber is this fiber. Return true.

Custom `internal/update` hooks are bypassed for volatile-only changes and run for mixed changes.

### 6. `EntryGroup.update(config)` (file-driven reconciliation, `group.ts:49-66`)

Replace `this.data` with the new list. Build `oldMap` and `newMap` by id (a new row without an id gets a unique anonymous key, so it is always created). For every key in `Reflect.ownKeys({ ...oldMap, ...newMap })`: present in the new list, `create(row)` with errors logged through `ctx.logger.error`; absent, `remove(id)`. All calls start synchronously in that key order and are awaited together. JavaScript key order puts integer-like ids first in ascending order, then other ids in insertion order (old rows, then new rows), then anonymous rows; row order carries no load semantics because activation is driven by service availability. This path never calls `commit`.

### 7. Tree mutations and reports (`tree.ts:126-179`)

- `create`: described under Services. `position` beyond the length appends.
- `remove`: `group.remove(legacy.id)` then `commit({ id, group, legacy })`.
- `update(id, options, parent, position)`: resolve the entry; if `parent !== undefined`, resolve the target group. For a target in another tree, compute `members(entry)` (the entry plus, recursively, the same-tree members of its group; an Include's children are not members because their tree differs) and throw `entry ${id} already exists in the target tree` before changing anything if the target store holds any of their ids. Then unlink from the source data, splice the same options object into `target.data` at `position ?? Infinity`, set `entry.parent = target`, and for a cross-tree move transfer every member's store registration and re-point same-tree subgroups to the target tree (V26). Start `entry.update(options, false, true)`; before awaiting it, report: cross-tree, `source.tree.commit({ id, group: source, legacy })` then `target.tree.commit({ id, group: entry.parent, options })`; same tree, `commit({ id, group: entry.parent, from: moved ? source : undefined, options, legacy })`. Return the update task.
- Explicit saves: `fiber.update(config)` without `noSave` on an entry's root fiber triggers the `internal/commit` listener: `entry.options.config = schema?.simplify ? schema.simplify.call(schema, config) : config`, then `commit({ id, group, options, legacy })`.

### 8. Self-disposal detection (`index.ts:128-174`)

On `internal/plugin` for a disposed fiber (`fiber.uid` is null) the Loader runs these checks in order and returns at the first that holds: (1) the fiber has no entry; (2) it is a child fiber under the entry, not the entry's root fiber; (3) the plugin runtime is no longer in the registry (HMR and `registry.delete` remove the runtime before disposing its fibers); (4) the fiber of the entry's tree is itself disposed. If none holds it logs `unload`, then continues: (5) the entry's parent fiber is `UNLOADING`; (6) the store no longer maps the id to this entry (`EntryGroup.remove` unregisters first); (7) `entry.disabled` is already true (config update, ancestor disable). If none of those holds either, it sets `entry.options.disabled = true` and calls `commit({ id, group, options, legacy })` with `legacy` lacking the flag. So a plugin calling `ctx.fiber.dispose()` on its own entry fiber persists as `disabled: true`, and no other teardown path does.

### 9. Isolation realms and intercept (`config/isolate.ts`)

- `Realm.access(key, create)`: returns `store[key]`, creating `Symbol(key + suffix)` when `create`; without `create` and without a stored symbol it returns a fresh unstored symbol. `LocalRealm` suffix `#<entry id>`; `GlobalRealm(label)` suffix `@<label>`.
- `access(entry, name, create)`: label `true` uses the entry's `LocalRealm` (created on demand); a string label uses the shared `realms[label]` (created only with `create`); a falsy label yields `undefined`.
- `loader/patch-context` handler (`isolate.ts:96-156`): (1) `newMap` inherits from the parent group's isolate map and gets one symbol per name in `options.isolate`. (2) For each name in the new map's own names and every name that ever had a delimiter, when the effective symbol changed: ensure a per-name delimiter symbol, stamp `entry.ctx[delim]` with a fresh symbol, and, for the old then the new symbol, if an implementation is stored under it record `diff[name] = [old, new, entryFlag, implementerFlag]` and stop at the first implementation whose provider lies outside this entry's subtree. A stored implementation without a provider fiber logs `expected service ${name} to be implemented`. (3) Re-parent the entry's isolate and intercept maps to the parent's, replace the isolate map's own properties with the new ones, and replace the intercept map's own properties with `options.intercept`. (4) `await next()`. (5) For each diff whose implementation is provided inside this entry and whose new symbol is free, move the implementation in `reflect.store` to the new symbol and set `impl.isolate`. (6) `ctx.reflect.notify(names, filter)`, where the filter admits contexts that see the old or the new symbol and that are on the other side of the entry boundary from the implementation. (7) Delete delimiter stamps for names not isolated by this entry.
- `loader/partial-dispose` handler: for each string-labelled name in the legacy isolate that the entry no longer uses, if no remaining loader entry uses that label for that name, delete the name from the realm and drop the realm when empty. The scan uses `return`, so finding a user for one name stops processing of the entry's remaining names.

### 10. Module import and name resolution (`tree.ts:182-201`, `resolve.ts`)

1. `cordis:<key>`: return `ctx.loader.builtins[key]` synchronously, no filesystem access. An unregistered key yields `undefined`, and plugging it fails with `invalid plugin, ...`.
2. Otherwise, inside `composeError` (splices `getOuterStack()` frames into the stack of an import failure): with `loader.internal`, `internal.import(name, baseUrl, {})`; without it, a name starting with `.` is `import(new URL(name, baseUrl).href)`; any other name goes through `createResolve(baseUrl)` and is imported from the resolved URL, or imported by bare name when no resolver is available.
3. `createResolve(baseUrl)`: no base, a non-file URL, or no ancestor `package.json` yields `undefined`. Otherwise create the `.cordis` helper (see Formats) in the package scope and import `resolve.mjs`; a write failure yields `undefined` (native import fallback). Results are cached per resolved scope directory for the module's lifetime, including failures, and shared by concurrent callers (the cache holds the promise).
4. DSH's root include overrides `import` to resolve bare names from an installed-host base URL and absolute paths as file URLs (`app-boot/src/index.ts:765-777`).

### 11. Include: read, apply, write (`include/src/index.ts`)

State: `cache?: { content, data }` (last file text read or written and its parsed, id-complete rows), `journal`, `anonymous` (ids this Include assigned), `dirtyRead`, `dirtyWrite`, `_draining`, `_pendingTree`, `_applyTask`, `_disposed`, `_seq`, `persistenceError`.

- Construction: compute `filename` and file type, throw `extension "${ext}" not supported` otherwise; set the tree's `baseUrl` to the directory of the file (trailing slash), so relative names inside the file resolve beside it; `ensureInsertIds(config.patches, ...)` assigns ids to inserted rows in place; register the fiber-local `internal/update` listener: a changed `path` delegates to `next()` (restart); otherwise adopt the new config, ensure insert ids, `_scheduleApply()`, and return the apply task.
- Init (`[Service.init]`): `_read()`. Only a missing file (`read` stage, `ENOENT`) falls back: without `initial` throw `config file not found: ${filename}`; with it, clone it, `ensureIds`, write the dump, read again. Parse and validate errors fail the plugin start. Then register `stop()` as the disposer and await the apply task.
- `_read()`: read text; unchanged text relative to the cache is a no-op; parse; require an array; `_assignIds`; if a cache exists, `reconcile(journal, flatten(cache.data), flatten(data), fileOwned)` and log each conflict with `error('config conflict in %C: entry %C %s; file wins', filename, id, reason)`; replace the cache; `_scheduleApply()`; if the journal is non-empty set `dirtyWrite`.
- `_scheduleApply()`: `tree = applyPatches(cache.data, config.patches, warn)`, then `applyJournal(tree, journal)`; store as `_pendingTree`; a single apply task loops `await root.update(tree)` on the latest pending tree only. The mounted tree is always file rows, then patches, then unsaved runtime changes.
- `commit(change)`: emit `loader/config-update`; `record(journal, change, parentId)`; set `dirtyWrite`; `_drain()`.
- `_drain()`/`_loop()`: one loop at a time; while either flag is set: a due read runs first; a read failure stores `persistenceError`, logs a warning, and stops the loop unless another read is due, leaving `dirtyWrite` set; then a due write runs, with failures stored and logged as errors.
- `_write()`: nothing to do without a cache or journal. Read the current file: missing, warn `config file %C is missing, %d pending change(s) kept in memory` and return (journal kept); different from the cached text, set both dirty flags and return (merge first). Swap the journal for an empty one (changes reported during the write belong to the next round; `restore()` merges them back on failure). Clone the cached data and the patches and `routeJournal(batch, data, patches, warn)`. If a patch changed: adopt the new patches into `this.config` and call `this.ctx.fiber.update(this.config)` without awaiting it (this reports to the parent tree through `internal/commit`; a parent Include persists it, the in-memory Loader does not), or warn `patches of %C changed at runtime but cannot be persisted` when the Include has no entry. If `data` equals the cached data, `_scheduleApply()` and return. Else dump; check write access (failure: restore, warn `config file %C is read-only, %d pending change(s) kept in memory`); `_writeText(text, expected = cache.content)`; on `StaleWriteError` restore and set both flags; on another error restore, warn `failed to write config file %C, %d pending change(s) kept in memory`, rethrow. On success the cache becomes `{ content: text, data }` and `_scheduleApply()` runs.
- `_writeText(text, expected?)`: write the temp file; before each rename attempt, when `expected` is given, re-read the target and throw `StaleWriteError` if it differs; rename with the bounded retry; remove the temp file on failure.
- `flush()`: if the journal is non-empty and no drain is running, start one; wait until neither a drain nor an apply task is running; if the journal is still non-empty throw the stored `persistenceError` or `Error('config file ${filename} has ${n} unsaved change(s)')`; otherwise clear the stored error.
- `refresh()`: set `dirtyRead`, drain, return `flush()`. It rejects for an unreadable or unparsable file and while changes remain unsaved; the running tree is kept.
- `stop()`: mark disposed, drop the pending tree, force a final write attempt when the journal is non-empty, `flush()`, and in `finally` `root.stop()`. It can reject, but children always stop.

### 12. Anonymous ids (`index.ts:407-445`)

Walk the parsed rows in document order, descending into `config` of rows with `group` truthy; rows with an id mark it used; rows without one are queued with their parent group id (`null` for the root or for children of a not-yet-named group). For each queued row: reuse the id of a previously assigned anonymous row with the same parent whose stored options are `deepEqual` to this row (each previous id is reused at most once), else draw a fresh random id unused in the file and in the store. Record a clone of the row (before the id is added), then rewrite the row in place so `id` is its first key. Assigned ids reach the file with the next write that changes it. Effect: editing a neighbor does not restart an unchanged anonymous row; editing an anonymous row itself restarts it under a new id.

### 13. `applyPatches(data, patches, warn)` (exported as `applyEntryPatches`, `patch.ts:47-109`)

1. `data = structuredClone(data)`, always, even with no patches.
2. Build `entryMap: id -> row` by walking rows and descending into `config` only for rows with `group` truthy and an array `config`.
3. For each patch in order, with `{ id, insert, name, ...overrides }`:
   - `insert` present: clone the list. With `id`: the target must be in the map (else warn `patch insert: entry %C not found`) and have `group` truthy (else warn `patch insert: entry %C is not a group`); a non-array `config` becomes `[]`; push the clones. Without `id`: push onto the root list. Index the clones (and their nested group children) into the map. Other keys of an insert patch are ignored.
   - no `insert`: `id` is required (else warn `patch: id is required for non-insert patches`); the target must exist (else warn `patch: entry %C not found`); a truthy `name` different from the target's skips the patch with `patch: name mismatch for %C (expected %C, got %C), skipping`; otherwise assign every override key except `id` by reference.
4. Return the cloned list. Every warning skips only that patch.

Invariants: later patches see rows inserted by earlier ones. Rows that arrive through a wholesale `config` override of a group are not indexed, so later patches cannot address them, and the group's previous children remain in the map but detached. A later insert with an existing id shadows the earlier row in the map. Override values are shared by reference with the patch object, so callers clone patches per application (app-boot does).

### 14. Ownership and journal routing (`patch.ts:116-261`)

`PatchIndex(patches)`: for insert patches, every inserted row (recursively through groups) maps to `{ type: 'insert', index, list, options, parent }`; for override patches, each overridden key maps to the index of the last patch that sets it. `entry(id)` is the insert owner or `file`; `key(id, key)` is the insert owner, else the last overriding patch, else `file`; `fileOwned(id, key | null)`.

`routeJournal(journal, data, patches, warn)` mutates clones of the file rows and patches and returns whether any patch changed. For each record:

- `remove`: an inserted row is spliced out of its insert list (patched); a file row is detached from `data`.
- upsert of a row unknown to both: build `{ id, ...changes }` and place it at `(parent ?? null, position)`; if the parent is an inserted group the row goes into that group's `config` inside the patch (patched), else into `data` (warn `cannot place entry %C: group %C not found` when the group is missing).
- upsert with a changed parent: remove the row from its owner, apply the changes to the full options, place at the new parent.
- upsert of an inserted row: apply the changes to the row inside the patch (patched).
- upsert of a file row: apply each changed key to the file row unless a patch owns that key, in which case apply it to that patch object (patched).

### 15. Journal functions (`journal.ts`)

- `diffOptions(legacy, options)`: for every key except `id` present on either side and not `deepEqual` (non-strict), `changes[key] = options[key]` (possibly `undefined`).
- `record(journal, change, parent)`: removal merges `{ kind: 'remove' }`; creation merges `{ upsert, created: true, parent, position: group.data.indexOf(options), changes: omit(options, ['id']) }`; update merges `{ upsert, created: false, parent: change.from ? parent : undefined, position, changes: diffOptions(legacy, options) }`.
- `mergeRecords(older, newer)`: no older, newer; newer is a removal, drop the record entirely when the older one was a creation, else keep the removal; older is a removal, the newer upsert with `created: false`; both upserts, keep the older `created`, take parent and position from the newer only if it relocated, shallow-merge `changes`.
- `flatten(data)`: `Map<id, { parent, position, options, list }>`, descending into group configs.
- `place(data, options, parent, position)`: insert at `min(position, length)` in the root or the group's `config` (created as `[]`); false when the parent is missing or not a group.
- `applyJournal(data, journal, filter, warn)`: removals detach; an unknown id is created and placed (warn `cannot place entry %C: group %C not found`); a known id gets its changes applied and, when relocated to a different parent, is detached and placed, falling back to its old place with `cannot move entry %C: group %C not found`.
- `reconcile(journal, base, theirs, fileOwned)`: three-way merge where the file wins. Records not file-owned are skipped. Removal: gone from the new file, drop the record; changed or newly added in the file, conflict (`modified in file, removed at runtime` or `added in file, removed at runtime`) and drop. Upsert: missing from the new file, conflict `removed in file, modified at runtime` and drop if it existed in the base, else keep (runtime creation); present, clear `created`, then for each file-owned changed key keep it only if the file did not change that key or changed it to the same value, else conflict `key "${key}" modified both in file and at runtime` and delete the key; a relocation conflicts (`moved both in file and at runtime`) when the file also moved the row elsewhere; drop the record when nothing remains.

### 16. Timer

Covered under Services. Ordering invariant: concurrent `next()` calls on one interval iterator complete in request order, one per tick.

### 17. Logger formatting (`vendor/cordis/src/logger.ts:84-134`)

- `Logger.code(name, level)`: `hash = ((hash << 3) - hash) + charCode + 13`, truncated to 32 bits, per character; palette is `c256` when `level >= 2`, `c16 = [6, 2, 3, 4, 5, 1]` when `level === 1`, empty otherwise; result `palette[abs(hash) % length]`.
- `Logger.color(exporter, code, value, decoration)`: without colors the plain string; else `ESC[3<code or '8;5;'+code><decoration when colors >= 2>m<value>ESC[0m`.
- `Logger.format(exporter, message)`: an `Error` first argument becomes `'%s'` with its stack or message; a non-string first argument is prefixed with `'%o'`. Placeholders `%s %d %i %f %o %O %c %C` consume one argument each (`%c` yields the empty string, `%C` colors the value with the logger name's color, `%%` is a literal percent); unknown placeholders stay. Remaining arguments are appended with a space, objects through the `o` formatter (JSON in core; `util.inspect` with `depth: Infinity, compact: true, breakLength: Infinity` in the node console exporter). Each line is cut at `maxLength` (default 10240) with `...` appended.

### 18. Schemastery: constructors, modifiers, resolution (`vendor/schemastery/src/index.ts`)

A schema is a callable object: `schema(data, options?)` and `new schema(data)` both return `Schema.resolve(data, schema, options)[0]`. Every modifier returns a shallow copy with a new uid and a replaced `meta`; exceptions: `deprecated()` and `experimental()` push onto the `badges` array of the meta object the copy shares with the original (verified: after `d = base.deprecated()`, `base.meta.badges` also holds the badge), and `set`/`push` mutate in place. A port may give copies their own meta; nothing in the repository depends on the aliasing.

Constructors (all on the default export, here `z`):

| Constructor | Type string | Default `meta.default` | Accepts |
|---|---|---|---|
| `z.any()` | `any` | none | anything |
| `z.never()` | `never` | none | only null or undefined |
| `z.const(value)` | `const` | none | values `deepEqual` to `value`; returns `value` |
| `z.string()` | `string` | none | strings; `pattern`, `min`/`max` on length |
| `z.number()` | `number` | none | numbers; `min`, `max`, `step` |
| `z.natural()` | `number` | none | `number().step(1).min(0)` |
| `z.percent()` | `number` | none | `number().step(0.01).min(0).max(1).role('slider')` |
| `z.boolean()` | `boolean` | none | booleans |
| `z.date()` | `union` | none | `union([is(Date), transform(string().role('datetime'), parse, true)])` |
| `z.regExp(flag = '')` | `union` | none | `union([is(RegExp), transform(string().role('regexp', { flag }), compile, true)])` |
| `z.arrayBuffer(encoding?)` | `union` | none | `ArrayBuffer`, `SharedArrayBuffer`, views; hex or base64 strings when `encoding` is given |
| `z.bitset(bits)` | `bitset` | `0` | a number, or an array of key strings OR-ed together |
| `z.function()` | `function` | none | functions |
| `z.is(constructor)` | `is` | none | `instanceof` for a function; prototype-chain constructor name for a string |
| `z.array(inner)` | `array` | `[]` | arrays of `inner` |
| `z.dict(inner, sKey = z.string())` | `dict` | `{}` | plain objects; keys through `sKey`, values through `inner` |
| `z.tuple(list)` | `tuple` | `[]` | arrays matched by index; extra elements kept |
| `z.object(dict)` | `object` | `{}` | plain objects; unknown keys kept |
| `z.union(list)` | `union` | none | first member that resolves |
| `z.intersect(list)` | `intersect` | none | all members; object results merged |
| `z.transform(inner, callback, preserve?)` | `transform` | none | `inner`, then `callback(result)` |
| `z.lazy(builder)` | `lazy` | none | deferred recursive schema; built on first resolve or serialization, merging the lazy node's meta under the built schema's meta |

There is no `computed` constructor in this version. Shorthand via `Schema.from(x)` wherever an inner schema is expected: null or undefined is `any()`; a string, number or boolean value is `const(x).required()`; an existing schema is itself; `String`, `Number`, `Boolean`, `Function` are the required primitive schemas; any other constructor is `is(x).required()`; anything else throws `TypeError('cannot infer schema from ...')`. `Schema.extend(type, resolver)` registers a resolver `(data, schema, options, strict) => [value, adapted?]`.

Modifiers: `.required(value = true)`, `.default(value)`, `.description(text)`, `.comment(text)`, `.link(url)`, `.role(text, extra?)` (sets `role` and `extra`), `.hidden(value = true)`, `.disabled(value = true)`, `.collapse(value = true)`, `.loose(value = true)`, `.deprecated()` (badge `{ text: 'deprecated', type: 'danger' }`), `.experimental()` (badge `{ text: 'experimental', type: 'warning' }`), `.pattern(regexp)` (stores `{ source, flags }`), `.min(n)`, `.max(n)`, `.step(n)`, `.volatile()` (throws `TypeError('volatile schema is already wrapped')` on repeat), `.extra(key, value)` (any meta key), `.set(key, schema)`, `.push(schema)`, `.i18n(messages)` (merges per-locale descriptions; `$description`/`$desc`, `$value`/`$inner`, `$key`), `.simplify(value)`, `.toString(inline?)`, `.toJSON()`.

`Schema.resolve(data, schema, options = {}, strict = false)` (`index.ts:515-554`):

1. No schema: `[data]`.
2. Once per top-level call, validate volatile placement (step 19).
3. A volatile node: resolve a non-volatile copy, wrap the value with `createVolatile` (an immutable deep-frozen snapshot behind `get()`); a wrap failure (functions, class instances, cycles) is a `ValidationError` with the path.
4. `options.ignore?.(data, schema)` true: `[data]`.
5. Null or undefined data, for every type except `lazy`: with `meta.required` throw `missing required value`; take `meta.default`, and while the schema is an `intersect` without a default look at its first member's default; no default returns `[data]` unchanged; otherwise continue with `clone(default)`.
6. Dispatch on `type`; an unregistered type throws `unsupported type "${type}"`.
7. If the resolver throws and `meta.loose` is set, return `[meta.default]`.

Resolver rules and exact messages (all thrown as `ValidationError`):

- `never`: `expected nullable but got ${data}`. `const`: `expected ${value} but got ${data}`.
- `string`: `expected string but got ${data}`; `expect string to match regexp ${regexp}`; length bounds `expected string length <= ${max} but got ${n}` and `>= ${min}`.
- `number`: `expected number but got ${data}`; `expected number <= ${max} but got ${data}` and `>= ${min}`; with `step`, `(data - (min ?? 0))` must be a multiple (decimal-safe comparison by shifting digits), else `expected number multiple of ${step} but got ${data}`.
- `boolean`: `expected boolean but got ${data}`. `function`: `expected function but got ${data}`. `is`: `expected ${name} but got ${data}`.
- `bitset`: `expected number or array but got ${data}`; array members must be strings (`expected string but got ${key}`).
- `array`: `expected array but got ${data}`; `expected array length <= ${max}`/`>= ${min}` (the minimum is skipped when the inner schema has a default); each element through `property`.
- `dict`: `expected object but got ${data}`; each key resolved through `sKey` (a rejected key is skipped in strict mode, else rethrown); values through `property`; a transformed key renames the key in the input object too.
- `tuple`: `expected array but got ${data}`; listed positions through `property`; extra elements appended unless strict.
- `object`: `expected object but got ${data}`; for each declared key, `value = property(...)`, stored when non-null or when the key is present in the input; unless strict, unknown input keys are copied.
- `union`: try members in order with the same options; the first success wins; else `expected ${toString()} but got ${JSON.stringify(data)}`.
- `intersect`: empty list returns the data; each member resolves in strict mode; null results are skipped; the first non-null result is the base; a different `typeof`, or unequal primitives, throws the same message as union; object results add only keys not already present; unless strict and when the input is a plain object, unknown input keys are copied.
- `transform`: resolve the inner schema in strict mode; return `[callback(result)]` with `preserve`, else `[callback(result), callback(adapted ?? data)]`. The callback receives one argument at run time.
- `property(data, key, schema, options)`: resolves `data[key]` with `path` extended by `key`; a returned adapted value is written back into the input object; with `options.autofix`, a failing property is deleted from the input and replaced by the schema default (wrapped in a reference for a volatile field).

`ValidationError extends TypeError`, `name = 'ValidationError'`, carries `options`; its message is prefixed with the path as `$` followed by `.key` for strings and `[n]` for numbers, then a space; an empty path has no prefix. Examples: `$.root[0] expected string but got 1`, `$.a missing required value`, `expected object but got str`. `ValidationError.is(error)` checks the global symbol `Symbol.for('ValidationError')`.

`toString()` formats: primitives by name; `const` as JSON for strings; `array` as `inner[]` (inner printed inline, unions parenthesized); `dict` as `{ [key: K]: V }`; `tuple` as `[A, B]`; `object` as `{ key?: T, ... }` with `?` unless `required`, `{}` when empty; `union` joined with ` | `; `intersect` joined with ` & `; `transform` prints its inner; `is` prints the constructor name; unknown types `Schema<type>`.

### 19. Schemastery: simplify and volatile placement

`simplify(value)` (`index.ts:422-458`), used for write-back: unwrap a reference; return `null` when the value equals `meta.default` (strict comparison for `dict`); pass null through; `object` keeps only keys whose simplified value is non-null and returns `null` if the result equals the default, which also drops keys the schema does not declare (`z.object({ a: z.number().default(1), b: z.string() }).simplify({ a: 1, b: 'x', c: 2 })` is `{ b: 'x' }`); `dict` keeps every key; `array` and `tuple` map elements; `intersect` merges member results; `union` uses the first member that resolves the value; other types return the value.

Defaulting example: with `S = z.object({ root: z.array(String).default(['.']) })`, `S({})`, `S(null)` and `S(undefined)` all return `{ root: ['.'] }`, because container constructors carry a default. A plugin whose `Config` is an object schema therefore receives a filled object when its entry has no `config` key.

Volatile placement (`validateVolatileSchema`, `index.ts:488-509`): a volatile node is legal only on a path of fixed object keys with no enclosing volatile node. Anything below `inner` (array, dict, transform, built lazy), `list` (union, tuple, intersect), `sKey`, or another volatile node is blocked and throws `volatile fields require a fixed object path without an enclosing volatile field` with the schema path (`*` for inner, `<key>` for sKey, the index for list members). A whole array, union or object may itself be volatile. The check runs even when the input omits the field. A lazy inner is checked once, when built.

### 20. Vendor HMR (`vendor/hmr/src/index.ts`)

- Watch: Chokidar on `config.root` with `cwd = realpath(baseDir)`, `ignored` matched by picomatch against the path relative to that directory, `ignoreInitial: true`, plus pass-through options. Only `change` events are handled. Before the watcher opens, `externals` is the static dependency graph of the process entry module (`process.argv[1]`), excluding `node:` and `/node_modules/` URLs. Init resolves on Chokidar `ready` (immediately for an empty root list); a pre-ready watcher error rejects init, later ones are logged.
- On change of `path`: (1) the URL is an external: `loader.exit()`; (2) the URL is in Node's ESM load cache: stash it and call the debounced `partialReload` (`ctx.debounce`, `config.debounce` ms); (3) the file is the `filename` of some entry's `subtree` (an Include), in canonical or configured spelling: `await include.refresh()`, logging a rejection with `warn` (V9); (4) otherwise emit `hmr/change(url)`.
- `analyzeChanges`: `accepted` starts as the stashed URLs, `declined` as the externals. Dependencies of changed files are examined transitively: a dependency becomes accepted if it imports an accepted file, declined if all its imports are declined or excluded; the rest are declined at the end.
- `partialReload`: resolve every loader entry name against its tree's base URL to a cached module job; for each plugin entry module, collect its dependency closure excluding declined files; if it contains an accepted file, accept the whole closure and schedule the plugin with its registry runtime. Evict every accepted file from the ESM and CommonJS caches (with backups). Re-import every scheduled entry file; an import failure is reported through `handleError` (esbuild-style failures get a code frame) and rolls the caches back. Then, per plugin with a runtime: `ctx.registry.delete(oldPlugin)` (disposes all its fibers; the Loader does not mark entries disabled because the runtime left the registry first), and for each old fiber `oldFiber.parent.registry.plugin(newPlugin, oldFiber.rawConfig, getOuterStack)`, copying `entry` to the new fiber and pointing `entry.fiber` at it; log `reload plugin at %C`. Any failure rolls back caches, deletes the new plugins and re-plugs the old ones. Finally emit `hmr/reload(reloads)` and clear the stash.

### 21. DSH HMR (`packages/boot/hmr`)

Same reload core, with these differences:

- One queue. Module batches, Include refreshes, config-path refreshes and caller mutations all run through `runExclusive`; reloads additionally wait for `applicationReady` (resolved by `appReady.onReady`, or `false` when the service is disposed first, which cancels queued reloads).
- Batching (`index.ts:436-482`): change paths accumulate in a set; the debounced dispatcher takes the batch inside the queue. Per path: skip registered config paths; a `package.json` outside `node_modules` invalidates that package's cached configuration; an external sets a full-reload flag; a cached module (or JSON module) is stashed; a manifest alone triggers nothing more; an Include file is collected; anything else emits `hmr/change`. Then: full reload calls `loader.exit()` and stops; else each collected Include is refreshed (rejections logged), the stash is partially reloaded, and `loader.await()` completes the transaction.
- Entry identity: plugins are located by matching `entry.moduleNamespace` to cached module namespaces instead of re-resolving names (so a moved `exports` or `main` keeps reloading the loaded file); names without a namespace and `cordis:` builtins fall back to name resolution. Entries sharing one runtime are replaced together, each with the implementation of its own module; an instance without an entry whose runtime splits into distinct callbacks fails with `HMR replacement is ambiguous for a plugin instance without a Loader entry` and rolls back.
- Re-plug uses `entry.options.config` for entry-owned fibers (the latest Loader config) and `fiber.rawConfig` for others, awaits every replaced fiber, and on success updates `entry.moduleNamespace` for all matching entries (disabled ones included), emits `hmr/reload`, and re-records file identities. Failures restore caches and old plugins and reject the transaction.
- `watchConfig` (`watch-config.ts`): find the nearest existing ancestor directory, canonicalize it, and watch it with `depth` equal to the number of missing levels and an `ignored` predicate that admits only the target path and its ancestors (siblings are never subscribed). `awaitWriteFinish: true` by default, `ignoreInitial: false`. `add`, `change` and `unlink` of the exact path set a dirty flag; a single runner loops `refresh()` while dirty; failures log `config reload at %C failed` and the error. Registration throws `config path already registered` for duplicates and `config watch parent is not a directory` for a file in the parent chain.
- Profile watches (only with `profileContext`): the profile patch file, the home patch file (`PROFILE_PATCH_FILENAME`), and the profile `package.json`. A manifest event recomposes only when the ordered `dsh.profile.bundles` list changed; identical inputs (bundle list plus both patch texts) are skipped. Each recomposition calls `reconcileProfile()` and logs `restart required: %s`, `changed modules keep running their previous code until a restart: %o`, and each warning.
- `reconcileProfile`: read patches; compare loaded `file:` modules below the profile roots (profile directory plus real targets of linked packages) against recorded identities `ino:size:mtimeMs` (`module-files.ts`; an unrecorded module is stale when modified at or after the last observation minus 2000 ms); plan replacement (take each changed module with all its transitive importers; if that set touches the static graph of the process entry module, `node_modules` included, the change is pending `host-module`; if a plugin exported by the set runs in a fiber that no Loader entry owns, it is pending `unmanaged-plugin`); evict the rest with their importers and stop the affected plugins with `registry.delete` (entries are not marked disabled); evict modules whose import failed earlier; call `recomposeProfile(root, patches, 'dsh', { requiredIds, running })`, which applies the new entry list through ordinary Loader updates and restarts stopped entries; finally evict modules of dropped package mappings and record identities again.
- `package-manifest.ts` (catalog depth): `PackageManifests.invalidate(manifestPath)` makes Node re-read a package's `package.json` by replacing methods of `internalBinding('modules')`, the package reader, the ESM `ResolveCache` and the CommonJS `_pathCache`/`_resolveFilename`/`_load`; `dispose()` restores them. It has no meaning outside Node.

## Tests worth porting

| Path | Behaviors pinned |
|---|---|
| `scripts/cordis-entry-commit.spec.ts` | `commit` payloads for create, update, same-tree move (`from`), remove; explicit `fiber.update` save; self-disposal reports `disabled: true`, child disposal does not; adopted entries survive `remove` on the old group; file-driven reconcile and teardown report nothing; id `a:b` mounts but `resolve('a:b')` throws; `applyEntryPatches` never aliases its inputs; later patches address rows of an inserted group |
| `scripts/cordis-include-journal.spec.ts` | Independent file and runtime edits merge in both orders; file wins conflicts with a `config conflict` error log; missing or invalid file keeps edits (`flush` rejects `unsaved change`, `refresh` rejects `failed to parse`) and recovery merges; patch-owned keys and inserted rows are routed into the parent's `patches` and the included file stays byte-identical; read-only retry; file text preserved on file-driven removal; `stop()` drains; anonymous rows keep ids and fibers across config updates; cross-tree move persists as a complete creation, rejects duplicates, transfers group members |
| `scripts/loader-config-diff.spec.ts` | Every rule of `equalExceptVolatile`, including defaults for absent objects, expression nodes, recursive schemas, sparse arrays, prototype-named keys, metadata-free hydrated schemas |
| `scripts/loader-volatile-update.spec.ts` | Volatile commit without remount; single event with all paths; invalid candidate keeps references; mixed changes remount with fresh references; hook bypass; real YAML round trip with plain persisted values; Group and Include children; expressions; `noSave`; listener failure isolation |
| `scripts/volatile-config.spec.ts`, `scripts/volatile-config.fixture.ts` | `.volatile()` parsing, defaults, freezing, placement rejections (array, dict, union, tuple, intersect, transform, nested), serialization round trip, lazy recursion, `deepEqual` strict semantics, `volatileEntries` |
| `scripts/cordis-loader-resolve.spec.ts` | Project-scoped resolution of bare names, subpaths, `#imports`, self-reference; `.cordis` helper placement; shared resolver per scope; relative, URL and builtin specifiers; fallbacks |
| `scripts/cordis-timer.spec.ts` | Interval read ordering; settle-all on return, throw, dispose; throttle with and without trailing; debounce; inert wrappers |
| `scripts/cordis-vendor-hmr-include.spec.ts` | Rejected `Include.refresh()` is logged, not unhandled |
| `scripts/cordis-config-access.spec.ts` | `rawConfig`, `resolveConfig`, `effectiveConfig` contract that `_commitVolatile` relies on; expression evaluation in candidates |
| `scripts/verify-cordis-config.spec.ts` | Where `!!js` is legal |
| `packages/boot/hmr/tests/coordination.spec.ts` | Queue serialization, nesting rejection, Include refresh through the queue, full-reload hook, self-disposal inside a transaction |
| `packages/boot/hmr/tests/watch-config.spec.ts` | Exact-path watching: siblings excluded, missing parents, add/change/unlink, serialized refresh, disposal draining |
| `packages/boot/hmr/tests/profile.spec.ts`, `reconciliation.spec.ts` | Readiness gating, bundle-list-only manifest reloads, recovery from unreadable inputs |
| `packages/boot/hmr/tests/modules.spec.ts`, `package-reload.spec.ts`, `package-manifest*.spec.ts`, `module-files.spec.ts` | Node module-cache replacement, rollback, file identity; port the outcomes (which fibers restart, what is reported), not the Node mechanics |
| `packages/bundle/base/cordis.patch.yml`, `packages/bundle/headless/cordis.patch.yml`, `packages/bundle/web-app/presets/*.patch.yml` | Real patch files: inserts, overrides, `!!js` in `disabled` and `config`, `inject`, `isolate` on `cordis:group` rows. Use as golden inputs for the patch algorithm and YAML dialect |
| `vendor/schemastery/README.md` | Worked examples for every basic constructor |

## Porting notes

Essential product behavior:

- The entry format, id rules, nested ids, patch semantics and the YAML dialect are configuration compatibility and must match exactly, including every warning that skips a patch.
- The mounted tree equals file rows, then patches, then unsaved runtime changes; the journal, ownership routing and file-wins reconcile define what reaches disk.
- Reconciliation by id with adoption, the disabled rules, the update classification (no-op, volatile commit, context patch, fiber update) and the self-disposal rule define which plugins restart.
- Schemastery validation, defaulting, error text, `simplify` and the JSON form are observable through config errors, saved files and the settings UI schema dump.
- Timer and console exporter behavior are small and fully specified above.

Node or TypeScript machinery that should not be copied:

- `internal.ts`, `resolve.ts` and the `.cordis/resolve.mjs` helper exist to drive Node's ESM loader. A Racket loader needs a name resolver from dsh package names and relative paths to Racket modules (for example a registry table plus `dynamic-require`), keeping `cordis:<key>` builtins and the per-tree `baseUrl`.
- `composeError` stack splicing; keep only the idea of attaching the entry chain (`baseUrl#id` frames) to import errors.
- `unwrapExports` ESM/CJS interop; define one plugin export convention for Racket modules instead.
- `packages/boot/hmr/src/package-manifest.ts` and the module-cache eviction code. In Racket, code reload maps to re-instantiating modules (`dynamic-rerequire` or a fresh namespace) and then performing the same fiber replacement: delete the runtime, re-plug each instance with its entry's current config, restore the entry link, roll back on failure.
- Prototype tricks: `Object.setPrototypeOf(entry.ctx, parent.ctx)` and `Object.create` chains for isolate and intercept maps. The Racket context needs a mutable parent link and layered lookup tables with the same shadowing rules.

Suggested Racket decomposition:

- `cordis/schema`: schema struct (`type`, `meta`, `inner`, `skey`, `list`, `dict`, `bits`, `value`, `callback`, `constructor`, `preserve`, `builder`), resolver registry, a `current path` carried in an options struct, `exn:fail:schema` with the exact messages, `simplify`, `->jsexpr`/`jsexpr->schema`, volatile references as a struct with a private setter. Contracts fit the constructor signatures; a small macro can provide the shorthand forms.
- `cordis/loader`: `entry`, `entry-group`, `entry-tree` (generic with a `commit` method; `loader` and `include` implement it), `loader` service, `isolate` hooks, `diff.rkt` for `equalExceptVolatile`.
- `cordis/include`: `journal.rkt` and `patch.rkt` as pure functions over mutable ordered maps (port the specs one to one), `include.rkt` for file state with the dirty-flag drain loop on one thread or a mailbox.
- `cordis/timer`: effects built on threads or alarm events, cancelled by the owning fiber (a custodian per fiber is a natural fit).
- `cordis/logger-console`: an exporter struct and the render function.
- `dsh/hmr`: the exclusive queue (a semaphore plus a parameter that marks "inside a transaction" to reject nesting), exact-path watches (`filesystem-change-evt` on the nearest existing ancestor, or polling), profile reconciliation calling the boot package.

Hard parts and risks:

- `!!js` values are JavaScript. Existing configs use member access, optional chaining, calls, `new URL(...)`, `!`, `===`/`!==`, `??`, `||`, `&&`, the conditional operator, `+`, string, number and array literals, `undefined`, and the names `ctx`, `baseUrl`, `process.env`, `process.cwd()`, `process.platform`, `process.execPath`, `process.getBuiltinModule('node:path'|'node:module')`, `JSON.parse`, `Number`, `decodeURIComponent`, and services such as `dshHomePath(...)` and `ctx.headlessStartup.*`. The port needs an embedded evaluator for this subset with a `process`-compatible environment object, or a Node sidecar; an ADR should fix the supported subset and fail loudly outside it. Evaluation timing (config at each activation and candidate resolution; `disabled` at each mount decision) must be kept.
- Object identity and key order. The algorithms rely on the same options object being shared by `group.data`, `entry.options` and the journal (`indexOf`), and on insertion-ordered keys (`sortKeys`, `id` first after `_assignIds`, YAML dump order). Use mutable, insertion-ordered maps with `eq?` identity; plain Racket hashes are unordered.
- YAML. The parser must implement the JSON schema subset plus the `!!js` scalar tag, and a dumper must emit that tag. Write-back does not need to match js-yaml byte for byte, because Include compares against the text it last read or wrote, but the output must stay loadable by dsh.
- Asynchrony. Reconciliation starts all child creations before awaiting any, deduplicates concurrent `init`, and reports `commit` synchronously after options change. A threaded Racket implementation must keep "options visible before commit returns", "one apply loop, latest tree wins" and "one drain loop".
- Isolation realms depend on kernel internals (`reflect.store` keyed by symbol, `impl.isolate`, `notify` with a filter). Port them together with the kernel's service store design; uninterned symbols or fresh structs replace JS symbols.
- Strict `deepEqual` semantics (null versus undefined, opaque objects by identity, sparse arrays) have no direct Racket analogue; decide the value model for JSON null versus absent early.
- Random ids must not collide with ids already in the file or store; anonymous-row id reuse is observable as "unchanged row does not restart".

What can only be wrapped: plugins that remain JavaScript need Node, so their import, their `Config` schema objects and HMR of their code must stay in a Node sidecar; the Racket loader would then treat such an entry as a proxy plugin. Nothing in the entry tree, patch, journal, schema or timer logic itself needs Node.

## Feature checklist

- loader: `ctx.loader` service provided with a `check` that honors intercept `{ await: true }`
- loader: `create(options, parent, position)` returns the full nested id and reports a creation
- loader: `update(id, options, parent, position)` merges options, deletes null keys, reports update with `legacy` and optional `from`
- loader: `remove(id)` unregisters before disposal and reports a removal
- loader: `resolve` and `resolveGroup` with `:` nested ids and their error messages
- loader: generated ids are 8 hex characters unique within the tree
- loader: explicit ids containing `:` mount but are not path-addressable
- loader: flat per-tree store; adoption of an existing id by another group keeps the fiber
- loader: `entries()`, `getTasks()`, `await()`
- loader: `locate(fiber)` returns the owning entry's full id
- loader: `Entry.id` prefixes only tree carriers
- loader: `sortKeys` order (`id`, `name`, sorted rest, `config`)
- loader: `disabled` literal and `!!js` expression evaluated at each mount decision against the entry context
- loader: group entries are never disabled themselves; children inherit ancestor disabled state
- loader: update classification: no-op, volatile commit, context patch only, fiber update for `config` or group
- loader: `name` and `inject` changes do not affect a live fiber
- loader: file-driven `EntryGroup.update` creates, adopts and removes by id without reports
- loader: `Group` plugin reconciles children on update instead of restarting, stops children on disposal
- loader: `cordis:<key>` builtins table
- loader: relative names resolve against the tree `baseUrl`; bare names resolve in the config project scope
- loader: import failure is logged and leaves the entry without a fiber
- loader: `unwrapExports` default-export preference
- loader: `fiber.entry` binding for root and descendant fibers
- loader: entry-level `inject` (array and object forms) gates activation
- loader: entry-level `intercept` becomes the entry context's intercept layer
- loader: `isolate: { name: true }` private realm per entry
- loader: `isolate: { name: 'label' }` shared named realm with garbage collection
- loader: isolate change moves an in-entry implementation and notifies the other side of the boundary
- loader: `!!js` interpolation of `config` at activation against the plugin context, raw form retained
- loader: Group and Include configs are not interpolated at the carrier level
- loader: `internal/commit` saves simplified config and reports to the tree
- loader: self-disposal marks the entry `disabled: true`; HMR, removal, parent unload and tree disposal do not
- loader: `apply`/`reload`/`unload` logs gated by `enableLogs`, never for groups
- loader: `equalExceptVolatile` rules
- loader: `_commitVolatile` commits references, emits one `loader/volatile-update` with paths to the owning fiber
- loader: invalid volatile candidate is logged and keeps running references
- loader: changed ordinary effective value falls back to the ordinary update
- loader: cross-tree move transfers store registrations of the entry and its group members and rejects duplicate ids
- loader: `envData` from `CORDIS_SHARED`; `exit()` hook
- loader: events `loader/entry-init`, `loader/patch-context`, `loader/partial-dispose`
- include: YAML (`.yml`, `.yaml`) and JSON (`.json`) files; other extensions rejected
- include: `!!js` YAML tag parsed to and dumped from expression nodes
- include: top-level array requirement and `ConfigFileError` stages
- include: missing file falls back to `initial` (written with ids) or fails with `config file not found`
- include: tree `baseUrl` is the file's directory
- include: anonymous rows get ids, reuse them for unchanged rows, and persist them on the next write
- include: `applyEntryPatches` root insert, group insert, field override, name assertion, all five warnings
- include: patches clone inputs; later patches see inserted rows
- include: `ensureInsertIds` assigns ids to inserted rows in the config
- include: mounted tree is file, then patches, then journal
- include: same-path config update reconciles in place; changed path restarts
- include: `commit` journals create, update, move, remove and emits `loader/config-update`
- include: journal record merging (create then remove leaves nothing, remove then upsert becomes update)
- include: `routeJournal` sends file-owned changes to the file and patch-owned changes to `patches`
- include: patch changes propagate to the parent tree through `fiber.update`
- include: three-way `reconcile` with file-wins conflicts and the five conflict reasons
- include: atomic write through temp file and rename with stale-content check and bounded retry
- include: missing, read-only or failed writes keep changes in memory with warnings
- include: `flush()` retries and rejects while changes are unsaved; `refresh()`; `stop()` final write then child stop
- include: exports `applyEntryPatches`, `entryListSchema`, `PatchOptions`
- group: default export is the loader's `Group`
- timer: `ctx.timeout` callback and promise forms with disposal rejection
- timer: `ctx.interval` callback form and async iterator with ordered reads, return, throw, disposal
- timer: `ctx.throttle` with `noTrailing`, `.dispose()`, inert after disposal
- timer: `ctx.debounce`, `.dispose()`, inert after disposal
- timer: deprecated `setTimeout`/`setInterval` aliases
- logger-console: config schema and defaults
- logger-console: per-logger `levels` thresholds with `default`
- logger-console: line rendering with time, level letter, colored name, alignment, continuation indent, `showDiff`
- logger-console: node object formatting through inspect; browser entry maps to console methods
- schemastery: constructors `any`, `never`, `const`, `string`, `number`, `natural`, `percent`, `boolean`, `date`, `regExp`, `arrayBuffer`, `bitset`, `function`, `is`, `array`, `dict`, `tuple`, `object`, `union`, `intersect`, `transform`, `lazy`
- schemastery: shorthand inference (`String`, `Number`, `Boolean`, literals, constructors)
- schemastery: modifiers `required`, `default`, `description`, `comment`, `link`, `role`, `hidden`, `disabled`, `collapse`, `loose`, `deprecated`, `experimental`, `pattern`, `min`, `max`, `step`, `volatile`, `extra`, `set`, `push`, `i18n`
- schemastery: nullable handling, defaults (container defaults `{}`, `[]`, `0`), `required` error
- schemastery: exact validation messages with `$.path[index]` prefixes
- schemastery: unknown object keys preserved; strict mode inside intersect and transform
- schemastery: `autofix`, `ignore`, `path` options
- schemastery: `loose` returns the default on failure
- schemastery: `simplify` removes defaults and unwraps references
- schemastery: `toString` type strings
- schemastery: JSON serialization with `uid`/`refs` and hydration
- schemastery: `Schema.extend` custom types
- schemastery: Standard Schema `~standard` face with vendor `schemastery`
- schemastery: `.volatile()` references, placement validation, frozen snapshots
- hmr (vendor): watch roots with ignore patterns; change classification into full reload, partial reload, Include refresh, `hmr/change`
- hmr (vendor): partial reload replaces plugin runtimes, re-plugs fibers with raw config, keeps entry links, rolls back on failure, emits `hmr/reload`
- dsh-hmr: `runExclusive` queue with nesting rejection
- dsh-hmr: batched, debounced change dispatch behind application readiness
- dsh-hmr: `watchConfig` exact-path watches with missing parents and serialized refresh
- dsh-hmr: profile patch, home patch and manifest watches; manifest reloads only on bundle-list change
- dsh-hmr: `reconcileProfile` result (`warnings`, `pending`, `restartReason`)
- dsh-hmr: module file identity comparison (`ino:size:mtimeMs`, 2-second tolerance)
- dsh-hmr: entry-namespace-based plugin location and shared-runtime replacement
- dsh-hmr: package manifest cache invalidation (Node only)
- scripts: `verify-cordis-config` rule that `!!js` is legal only in `config` and the `disabled` field
- scripts: `cordisConfigFiles` discovery of `*cordis*.yml|yaml`
