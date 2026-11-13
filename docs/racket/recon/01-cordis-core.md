# Recon 01: the vendored Cordis kernel

Pinned dsh commit `e8f7b93a3`. Source studied: every file in `vendor/cordis/src/`, every file in `vendor/cosmokit/src/`, `vendor/README.md` (local modifications V6, V15, V22, V25), `scripts/cordis-*.spec.ts`, `packages/extensions/tool-cordis/tests/cordis-lifecycle.spec.ts`, `docs/cordis-primer.md`, `docs/cordis-tutorial/`, `docs/cordis-api/`.

Upstream identity: `cordis` 4.0.0-rc.11 at upstream commit `0b96d9fd517b998e44e2209560c9e5f0671ce933` (published here as `@deepseek-ai/cordis` 4.1.0); `cosmokit` 1.8.1 (published here as `@deepseek-ai/cosmokit` 1.9.0).

Statements marked **(observed)** were confirmed by running the vendored source unchanged under Node in a scratch directory. Everything else is read from source with the cited lines. `docs/cordis-api/*.md` is generated from the source JSDoc and adds no behavior beyond it.

This kernel version differs from older Cordis releases that implementers may remember. It has **no** `start()`/`stop()` service hooks, no `immediate` flag, no `reusable` flag, no `ctx.scope`, no `ready`/`dispose` events, no `fork`, and no `{ required, optional }` inject form. The replacements are named in the sections below.

## Scope

| Package directory | Role | Source lines (no tests) |
|---|---|---|
| `vendor/cordis/` | The kernel: `Context`, `Fiber`, `EventsService`, `ReflectService`, `RegistryService`, `Service`, `LoggerService`, tracing helpers. `bin.js` is a 16-line launcher. | 2,811 |
| `vendor/cosmokit/` | Zero-dependency helpers the kernel and Loader import: `defineProperty`, `isNullable`, `hyphenate`, `deepEqual`, `remove`, volatile references, plus string, time, and binary helpers. | 591 |

Kernel files: `context.ts` 146, `events.ts` 371, `fiber.ts` 820, `reflect.ts` 436, `registry.ts` 337, `service.ts` 115, `utils.ts` 294, `logger.ts` 276, `index.ts` 16. The kernel's only third-party dependency is the type-only `@standard-schema/spec`.

Depth: all of `vendor/cordis/src` is covered in depth. In cosmokit, the helpers the kernel and Loader use are covered in depth; `Time`, `Binary`, `clone`, and the case converters other than `hyphenate` get catalog depth.

Adjacent vendored packages belong to other recon notes and are only referenced here where they reach into kernel internals: `vendor/loader` (1,224 lines), `vendor/include` (968), `vendor/group` (3), `vendor/timer` (153), `vendor/hmr` (464), `vendor/logger-console` (145), `vendor/schemastery` (962).

## Services

The kernel has four built-in services plus the fiber. They are **own properties of the root context object**, not entries in the service store, so `ctx.get('logger')` returns `undefined` while `ctx.logger` works everywhere without `inject` **(observed)**. They are never disposed: the `Context` constructor clears the root fiber's disposable list after installing them (`context.ts:71-84`).

### The context object

A context is a prototype chain of plain objects that ends in a JavaScript `Proxy` around the root `Context` instance (`context.ts:74`, handler at `reflect.ts:143-219`). Own properties are found by ordinary lookup; anything not found reaches the proxy traps with the accessing context as receiver.

Root construction order (`context.ts:71-84`): create empty `[symbols.isolate]` and `[symbols.intercept]` dictionaries with a null prototype; create the proxy `self`; `root = self`; `baseUrl = undefined`; `fiber = new Fiber(self, {}, {}, null, …)` (the root fiber); then `reflect`, `registry`, `events`, `logger` in that order; then `fiber._disposables.clear()`.

| Member | Semantics |
|---|---|
| `ctx.root` | The root context proxy. |
| `ctx.baseUrl` | `string` or `undefined`. Set by launchers; the Loader resolves relative specifiers against it. |
| `ctx.fiber` | The fiber that owns this context. Own property of each plugin context; inherited by contexts made with `extend`. |
| `ctx.extend(meta = {})` | Returns `Object.create(this)` with every own key of `meta` (string and symbol) copied by descriptor. The parent is not changed. If `this` is a shadow context (see "Use site and definition site"), the shadow is stripped, the extension is applied to the use site, and the same shadow is re-attached on top (`context.ts:99-107`). |
| `ctx.isolate(name, label?)` | Returns `extend({ [symbols.isolate]: child })` where `child = Object.create(this[symbols.isolate])` and `child[name] = label ?? Symbol(name)`. Passing an existing label joins that scope (`context.ts:121-125`). |
| `ctx.intercept(name, config)` | Returns `extend({ [symbols.intercept]: child })` where `child` inherits the current intercept dictionary and `child[name] = config` (`context.ts:141-145`). |
| `Context.is(value)` | Brand check: `!!value?.[Symbol.for('cordis.is')]`. The brand is set on `Context.prototype` (`context.ts:61-68`). |
| `Context.effect`, `Context.filter`, `Context.isolate`, `Context.intercept` | Aliases for the global symbols `cordis.effect`, `cordis.filter`, `cordis.isolate`, and `cordis.intercept`. |

Names mixed onto every context by `ReflectService` (`reflect.ts:233-236`): from `reflect`: `get`, `set`, `provide`, `accessor`, `mixin`; from `fiber`: `runtime`, `effect`; from `registry`: `inject`, `plugin`; from `events`: `on`, `once`, `parallel`, `emit`, `serial`, `bail`, `waterfall`. A mixin is an accessor that reads `ctx[source]` and returns the member, binding functions to the source.

Property read, write, and membership rules are an algorithm; see "Context property resolution" under Algorithms.

### `ctx.fiber` (class `Fiber`, `fiber.ts:184-820`)

One fiber exists per `ctx.plugin()` call, plus the root fiber. Public fields:

| Field | Meaning |
|---|---|
| `uid` | Positive integer from `registry.counter` at creation; `0` for the root fiber; `null` once disposal has started. |
| `ctx` | The plugin context: `parent.extend({ fiber: this })`. For the root fiber, the root context. |
| `parent` | The context `ctx.plugin()` was called on. Mutable; the Loader re-parents entries. |
| `inject` | Dictionary service name → intercept config or `null`. Mutable; `internal/plugin` observers add to it before dependencies are resolved. |
| `runtime` | The shared `Plugin.Runtime` record, or `null` for the root fiber. |
| `config` | Raw config kept for the next activation. |
| `state` | `FiberState` (numeric values under Formats). |
| `dispose` | For plugin fibers, the effect disposer registered on the parent fiber with label `ctx.plugin()`. For the root fiber, `() => this.restart()`. |
| `committed` | The dependency implementations captured at the start of the current activation; `undefined` while not loaded; an empty dictionary for the root fiber. |
| `provisions` | `Set<Impl>` of service implementations this fiber provides. |
| `inertia` | Promise of the in-flight load or unload transition, or `undefined`. Harness code polls it to join teardown (`packages/core/scope/src/index.ts:115-118`). |
| `_hooks` | Per-fiber listener lists; only `'internal/update'` is used. |
| `_disposables` | `DisposableList` of top-level effect disposers. |

Methods:

- `name` (getter): the nearest `runtime.name` walking this fiber and its ancestors; `'root'` if none (`fiber.ts:342-349`). An anonymous arrow plugin therefore reports its parent's name **(observed)**.
- `assertActive()`: throws `CordisError('INACTIVE_EFFECT')` when `uid === null`.
- `effect(execute, label = 'anonymous')`: registers a reversible effect; returns the disposer. Full algorithm below.
- `getEffects()`: `EffectMeta[]` (`{ label, children }`) for every top-level disposer that carries metadata.
- `await()`: loops `while (inertia) await inertia`, then throws the stored startup error if any, else returns the fiber. It returns at once for a `PENDING` fiber **(observed)**.
- `restart()`: `assertActive()`, increment the revision, `_refresh()`, then `await()`. On a failed fiber it rejects with the stored error without reloading **(observed)**.
- `update(config, noSave = false)`: see "Config update".
- `rawConfig` (get/set), `effectiveConfig` (get), `resolveConfig(candidate)`: DSH accessors (V15). All of them, and `restart`/`update`, act on `this.ctx.fiber`, the canonical fiber, so they work through the thenable wrapper that `ctx.plugin()` returns. Setting `rawConfig` stores the value, bumps the config revision, and triggers nothing.
- `_checkImpl(name)` and `_refresh()`: dependency bookkeeping, called by `ReflectService.notify` and by the Loader.

Ownership rule: every effect belongs to exactly one fiber, the fiber of the context it was registered through. A child plugin is an effect of its parent fiber. Disposing a fiber disposes everything registered through its context, including child plugins, listeners, provided services, accessors, and mixins.

### `ctx.registry` (class `RegistryService`, `registry.ts:195-337`)

A map from plugin callback (function identity) to `Plugin.Runtime` `{ name?, callback, fibers: DisposableList<Fiber>, Config? }`.

- `plugin(plugin, config?)`: also `ctx.plugin`. Resolves the callback; throws `Error('invalid plugin, expect function or object with an "apply" method, received ' + typeof plugin)` if none; `assertActive()` on the calling fiber; creates the runtime on first sight; constructs a `Fiber`; returns `Object.create(fiber)` with a `then` that delegates to `fiber.await()`. Awaiting the result yields the canonical fiber (`registry.ts:316-336`).
- `inject(deps, callback)`: also `ctx.inject`. Equivalent to `plugin({ inject: deps, apply: callback, name: callback.name })`.
- `resolve(plugin)`: a function resolves to itself; an object with a function `apply` resolves to `plugin.apply`; anything else to `undefined`.
- `get(plugin)`, `has(plugin)`, `size`, `keys()`, `values()`, `entries()`, `forEach(cb)`: map inspection keyed by callback. Iteration is in runtime registration order.
- `delete(plugin)`: removes the runtime and calls `dispose()` on each of its fibers without awaiting; returns the runtime or `undefined`.
- `counter` (getter): pre-increments and returns the fiber uid counter.

### `ctx.reflect` (class `ReflectService`, `reflect.ts:141-436`)

State, shared by the whole application: `store` (isolation label symbol → `Impl`), `props` (name → `{ type: 'service' }` or `{ type: 'accessor', get, set? }`), and an implementation uid counter.

`Impl` fields (`reflect.ts:116-133`): `uid` (unique per `provide` call), `name`, `ctx` (the providing context), `value`, `check?`, `isolate` (the label it is stored under; the Loader may move it), `dependents: Set<Fiber>`, `release?`.

- `get(name, strict = true)`: also `ctx.get`. Looks up `store[ctx[symbols.isolate][name]]`. With `strict`, returns `undefined` unless the providing fiber's state is `ACTIVE`. Ignores `inject` entirely. The harness rule "optional services use `ctx.get(name)`" relies on this.
- `set(name, value)`: also `ctx.set`. Throws `cannot set property "<name>" without provide` if the scope has no implementation, `cannot set property "<name>" in multiple fibers` if the caller's fiber is not the provider's. Replaces `impl.value` and returns `true`. It does **not** notify dependents **(observed)**.
- `provide(name, value?, check?)`: also `ctx.provide`. An effect labelled `ctx.provide("<name>")`. Algorithm under "Providing and withdrawing a service".
- `notify(names, filter?)`: re-evaluates dependents and emits `internal/service`. Algorithm under "Dependency tracking".
- `accessor(name, { get, set? })`: also `ctx.accessor`. An effect labelled `ctx.accessor("<name>")`. Throws `property "<name>" is already declared as <type>` if `name` is in `props`. The disposer deletes the declaration.
- `mixin(source, mixins)`: also `ctx.mixin`. An effect labelled `ctx.mixin("<source>")` whose children are one accessor per key. `mixins` is an array of keys or a map source key → context key. Only a string `source` works; the object overload reads `ctx[object]` and is unusable.
- `trace(value)` and `bind(callback)`: tracing helpers, see "Use site and definition site".

### `ctx.events` (class `EventsService`, `events.ts:130-324`)

State: `_hooks`, a dictionary event name (string or symbol) → ordered array of `Hook` `{ ctx, callback, prepend?, global? }`.

- `on(name, listener, options?)`: `options` is `boolean` (shorthand for `prepend`) or `{ prepend?, global? }`. Returns the effect disposer. The disposer returns `undefined`, not the boolean the JSDoc promises **(observed)**.
- `once(name, listener, options?)`: wraps the listener so it disposes itself before its first call.
- `emit`, `parallel`, `serial`, `bail`, `waterfall`: dispatch methods; see Events.
- `dispatch(type, args)`: returns the matching callbacks bound to the dispatch receiver without calling them. Used for per-listener error containment at fiber teardown.

### `ctx.logger` (class `LoggerService`, `logger.ts:194-276`)

A callable object. `ctx.logger(name?)` returns a `Logger`; `ctx.logger.error|warn|info|debug(...)` are shortcuts for `ctx.logger()[type](...)`.

- Default name: intercept config `logger.name` read from the use site's intercept chain, else `hyphenate(fiber.name)` of the definition site's fiber, for example `MyPluginName` → `my-plugin-name`. A service that logs through `this.ctx.logger` inside a method called by another plugin therefore logs under its own plugin name, unless the caller's context carries a `logger` intercept name **(observed)**.
- `exporter(exporter)`: registers a sink as an effect labelled `ctx.logger.exporter()`; returns the disposer. `Exporter` fields: `colors?: number | false`, `maxLength?`, `levels?: Record<string, number>`, `formatters?`, `export(message)`.
- Fields: `bufferSize = 1000`, `buffer: Message[]`, `exporters: Map<number, Exporter>`, `_snMessage`, `_snExporter`.
- A built-in exporter (`colors: 3`) appends every message to `buffer` and drops the oldest beyond `bufferSize`. Without another exporter, plugin failures are visible only in this buffer.

### `Service` base class (`service.ts:11-115`)

`new SubService(ctx, name)` does, in order: `name ??= this.constructor.provide`; if the instance has a `[Service.invoke]` method, replace `this` with a callable function object whose prototype chain joins the class prototype with `Function.prototype`; set `self.ctx = ctx`, `self.name = name`; define the non-enumerable tracker `{ associate: name, property: 'ctx' }` under `Service.tracker`; call `ctx.reflect.provide(name, self, this[Service.check])`; return `self`.

A `Service` subclass is a class plugin. The instance claims `ctx.<name>` inside its constructor, so the claim is an effect of the fiber that runs the constructor, and it disappears when that fiber unloads.

Symbols and hooks:

| Member | Semantics |
|---|---|
| `[Service.init]()` | Optional. Called once after construction when the class is loaded as a plugin. Its return value is the plugin's effect: nothing, a disposer, a promise, or a sync/async iterable of disposers. The service becomes visible to dependents only after this settles, because visibility needs the fiber to be `ACTIVE` **(observed)**. This is the only start hook; cleanup is whatever it returns or yields plus the effects registered through `this.ctx`. |
| `[Service.check]()` | Optional availability predicate passed to `provide`. Called with `this` bound to the service as seen from each dependent's context; a falsy result or a throw hides the service from that dependent. |
| `[Service.invoke](...args)` | Makes the service callable. `ctx.name(...args)` calls it with `this` bound to the traced service. |
| `[Service.extend](props?)` | Returns a derived instance: `Object.create(this)` (or a new callable with `this` as prototype) with `props` assigned. |
| `[Service.resolveConfig](base?, head?)` | Merges `base`, then every intercept config for `this.name` found on `this.ctx[Context.intercept]` from the root-most ancestor to the nearest, then `head`. Uses `this.Config.merge(...configs)` if present, else `Object.assign({}, ...configs)` **(observed order)**. |
| `[Context.filter](ctx)` | Returns whether `ctx` resolves `this.name` to the same isolation label as the service. Lets a service dispatch `this.ctx.emit(this, name, …)` to listeners in its own scope only **(observed)**. |
| `static [Symbol.hasInstance]` | `instanceof` by walking constructor chains, so it works through proxies and duplicate module copies. |
| `Service.config` | Type-only marker for the intercept config type. |

### Use site and definition site

When code reads a service through a context, the kernel wraps the value so that the service acts on behalf of that context. JavaScript does this with nested proxies (`utils.ts:118-240`); the observable contract is:

1. A value is traced if it has a `[Service.tracker]` record `{ associate?, property?, noShadow? }`. `Service` instances use `{ associate: name, property: 'ctx' }`. Built-in services use `{ property: 'ctx', noShadow: true }`.
2. Reading `ctx.foo` returns a view of the service in which `foo.ctx` is the **use site**: the context used for the read **(observed: `c.foo.ctx === c`)**.
3. Inside a method or getter called through that view, `this.ctx` is a **shadow context**: an object whose prototype is the use site and which carries the service's own stored context as `[symbols.shadow]`, the **definition site**.
4. On a shadow context, effects, listeners, child plugins, `isolate`, `intercept`, and `fiber` come from the use site. So `this.ctx.effect(...)`, `this.ctx.on(...)`, and `this.ctx.plugin(...)` inside a service method are owned by the **caller's** fiber and are undone when the caller unloads **(observed)**.
5. On a shadow context, service resolution (`this.ctx.other`) starts from the definition site's fiber, so a service uses its own `inject` rights, not the caller's **(observed)**.
6. Values returned from a traced method, and nested traced values read from a traced service, are traced again to the same use site.
7. `ctx.foo.bar` reads the context property `"foo.bar"` if one is declared (service or accessor) and `foo` is a traced service with `associate: 'foo'`. The harness uses this for `remote.<name>` services: plugins `inject: ['remote', 'remote.job']` and read `ctx.remote.job`. For an accessor, the `receiver` argument of its `get`/`set` is the traced `foo` view **(observed)**.
8. `value[symbols.original]` returns the unwrapped object and `value[symbols.caller]` the definition site. Harness code uses `symbols.original` for identity comparisons, because each read creates a new view.
9. Listener callbacks are wrapped by `reflect.bind` (`reflect.ts:426-435`): on each call, `this` and every argument are re-traced to the **listener's** context. A service passed as an event argument acts for the listener, and a shadow context passed as an argument is reduced to its use site **(observed)**.
10. `ctx.extend()` on a shadow context preserves the shadow; `ctx.registry`, `ctx.reflect`, `ctx.events` strip it, which is why a plugin mounted with `this.ctx.plugin()` from a service method becomes an ordinary child of the caller **(observed)**.

## Events

All events are global to the application: a dispatch reaches every registered listener unless the dispatch carries a filter. There is no filtering by the listener owner's fiber state. A listener receives events from the moment it is registered (legal while its fiber is `PENDING`, `LOADING`, or `ACTIVE`) until its effect is disposed during unload.

### Dispatch algorithm

`_resolve(type, args)` (`events.ts:162-171`):

1. If `args[0]` is an object or function (this includes `null`), remove it and use it as `thisArg`; otherwise `thisArg = null`.
2. Remove the next argument as the event name (string or symbol).
3. If the name is not a string starting with `internal/` and at least one `internal/dispatch` listener exists, `emit('internal/dispatch', type, name, args, thisArg)`.
4. Take `filter = thisArg?.[Context.filter]`. Keep hooks where `hook.global || !filter || filter.call(thisArg, hook.ctx)`. The result is a snapshot array of callbacks in hook-list order.

Hook-list order is registration order, except that `prepend` inserts at the front, so the most recently prepended listener runs first **(observed: `d-prepend, c-prepend, a, b`)**. Because dispatch uses a snapshot, a listener added during a dispatch does not run in it, and a listener removed during a dispatch still runs in it **(observed)**.

| Method | Algorithm | Errors |
|---|---|---|
| `emit` | Call each callback in order with `(…args)`; ignore return values; do not await. | The first throw propagates to the emitter and skips the remaining listeners **(observed)**. Rejected promises from async listeners are dropped. |
| `parallel` | Call every callback in order, each inside an async wrapper; await all with all-settled semantics. | If any rejected or threw, reject with `AggregateError(reasons)`; the other listeners still ran **(observed)**. |
| `serial` | Await each callback in order; return the first result where `isBailed(result)`. | A throw or rejection stops the chain and rejects. |
| `bail` | Call each callback in order synchronously; return the first bailed result. | A throw propagates. |
| `waterfall` | Remove the last argument as `inner`. `dispatch()`: take the next callback; if none, return `inner()`; else call it with `(…args, next)` where `next()` runs `dispatch()` for the remaining callbacks. Return the outermost listener's return value. | A second call to the same `next` throws `Error('next() called multiple times')`. A listener that returns without calling `next()` vetoes the rest, including `inner`. |

`isBailed(v)` is `v !== null && v !== false && v !== undefined`; `0` and `''` bail **(observed)**. With no listeners, `bail` and `serial` yield `undefined` and `waterfall` returns `inner()`.

Listener `this` is `thisArg` (traced to the listener's context); it is `null` when the dispatch has no receiver **(observed)**.

### Registration algorithm

`on(name, listener, options)` (`events.ts:294-307`): normalize a non-object `options` to `{ prepend: options }`; `assertActive()` on the calling fiber; wrap the listener with `reflect.bind`; run `bail(ctx, 'internal/listener', name, listener, options)` and return its result if truthy; otherwise register an effect on the calling fiber labelled `ctx.on(<JSON string of name>)` or `ctx.on(Symbol(desc))` that inserts `{ ctx, callback, …options }` and whose disposer removes the hook by callback identity, deleting the list when it empties.

### Built-in events

| Event | Mode | Payload | Produced by | Consumed by | Notes |
|---|---|---|---|---|---|
| `internal/plugin` | emit | `(fiber)` | `Fiber` constructor after the parent owns the child's disposer (state `PENDING`, `uid` set); again at disposal with `uid === null` and `state` still holding the pre-disposal value. | Loader (adds entry `inject`), harness observers (`mcp-manager`, `lsp-stdio`, `typert/loader`, `client/modules`, inspector). | Creation emit is uncontained: a throwing observer makes `ctx.plugin()` throw after disposing the child and removing the runtime. Disposal emit is contained per observer: each throw or rejection is logged and the rest still run (`fiber.ts:120-137`). |
| `internal/status` | emit | `(fiber, oldState)` | `Fiber._updateState` on every change of `fiber.state` (`fiber.ts:587-601`). | `core/agent`, web boot, inspector. | Uncontained; a throwing observer breaks the transition in progress. |
| `internal/service` | emit with filter | `this`: a context derived from the notifier; `(name, value)` where `value` is the current non-strict value or `undefined`. | `ReflectService.notify`. | `api/gateway`, `client-ui-forge`. | Delivered only to listeners whose context resolves `name` to the same isolation label, plus `global` listeners **(observed)**. |
| `internal/update` | waterfall, `this` = fiber | `(resolvedConfig, next)`; `next()` restarts the fiber and returns the restart promise. | `Fiber.update` on a loaded fiber. | Loader, Include, Group, plugins that keep their instance across config changes. | See "Config update". |
| `internal/commit` | emit | `(fiber, rawConfig)` | `Fiber.update` unless `noSave`. | Loader (persists the entry). | Emitted before the lifecycle transition, after candidate validation. |
| `internal/config` | waterfall | `(fiber, next)`; `next()` returns the raw candidate from inner listeners. | `Fiber.resolveConfig`. | Kernel validator (first registered, therefore outermost), Loader (`!!js` evaluation). | Unfiltered: every listener sees every fiber and must test `fiber`. |
| `internal/get` | waterfall | `(ctx, name, error, next)` | Property read of a service name from a plugin context. | No consumer at the pinned commit. | `next()` runs the default resolution. |
| `internal/set` | waterfall | `(ctx, name, value, error, next)` | Property write of a declared service name. | No consumer. | `next()` runs `reflect.set`. |
| `internal/listener` | bail, `this` = calling context | `(name, listener, options)` (the JSDoc says `prepend: boolean`; the real third argument is the options object) | `EventsService.on`. | Kernel only. | A truthy result replaces registration and is returned from `on`. |
| `internal/dispatch` | emit | `(mode, name, args, thisArg)` | Every dispatch of a non-`internal/` event when a listener exists. | `terminal-bash`. | `args` is the live argument array, including a waterfall's `inner` **(observed)**. |

Kernel listeners installed at construction (`events.ts:139-159`), in this order:

1. `internal/listener`: when `name === 'internal/update'` and not `options.global`, store the listener in the calling fiber's own list `fiber._hooks['internal/update']` through an effect labelled `ctx.on("internal/update")` and return that effect's disposer. With `prepend: true` this path throws `TypeError` because `DisposableList` has no `unshift` **(observed)**.
2. `internal/update` (`global`, `prepend`): runs the receiver fiber's local hooks in registration order as a nested waterfall, then calls the outer `next`.
3. `internal/config`: `const config = next(); return fiber.runtime ? resolveConfig(fiber.runtime, config) : config`.

Resulting `internal/update` order for one update **(observed)**: global listeners prepended after startup, the kernel's local-hook runner (local hooks in order), remaining global listeners in registration order, then the restart.

Resulting `internal/config` order **(observed)**: later-registered listeners are inner and see the raw value first; schema validation runs on their result; a prepended listener sees the validated value.

## Tools

None.

## Configuration

The kernel contains no plugin with a `Config` schema, and none of its services is mounted through `ctx.plugin`. What it defines is the plugin declaration format and two intercept formats.

### Plugin declaration (`registry.ts:92-146`)

| Form | Detection | Call |
|---|---|---|
| Function plugin | `typeof plugin === 'function'` | If the function is constructible (it has a `prototype` and is not a generator or async generator), `new plugin(ctx, config)`; otherwise `plugin(ctx, config)`. Arrow functions, async functions, and method-shorthand functions are called directly. |
| Object plugin | object with function `apply` | The registry key is `plugin.apply`; `apply` is then treated as a function plugin (`this` is not the object). |
| Class plugin / `Service` subclass | a constructible function | `instance = new C(ctx, config)`; run each function in `instance[symbols.initHooks]`; the effect is `instance[Service.init]?.()`. |

Metadata read from the value passed to `ctx.plugin()`:

| Field | Type | Meaning |
|---|---|---|
| `name` | string | Runtime display name. The literal `'apply'` is discarded. Captured only when the runtime is first created. |
| `Config` | Standard Schema v1 object | `Config['~standard'].validate(raw)` must return synchronously `{ value }` or `{ issues }`. A thenable result throws `TypeError('Async config validation is not supported')`. Captured only when the runtime is first created. |
| `inject` | see below | Required services. Read on every `ctx.plugin()` call. |
| `provide` | string or string[] | Read by `Service` as the default name, and by loaders. |
| `intercept` | `Dict<boolean>` | Declarative only; the kernel does not read it. |

Module namespaces are passed as object plugins, which is why the harness rule says function plugins named-export `name` / `inject` / `Config` / `apply`.

Identity and reuse: the runtime record is deduplicated by callback identity. Fibers are **not** deduplicated; each `ctx.plugin()` call creates a new fiber under the same runtime, with its own config and `inject` **(observed: two objects sharing one `apply` share a runtime and its first-registered name)**.

### `inject` forms (`Inject.resolve`, `registry.ts:71-88`)

- `null` / `undefined`: no dependencies.
- Array of names: each name maps to `null`.
- Object: each own enumerable key is a service name; its value (or `null`) is intercept config for that service in the plugin's context. A fiber with a non-null entry gets its own intercept dictionary inheriting the parent's, with `intercept[name] = config` (`fiber.ts:242-249`) **(observed)**.
- Object built by the `@Inject(name, config?)` class decorator: carries `symbols.checkProto`; resolution merges the prototype chain first, so a subclass inherits its base class's declarations **(observed)**.

There is no `required`/`optional` form: `inject: { required: [...] }` declares a dependency on a service named `required`. Every declared name is required. Optional use goes through `ctx.get(name)`.

`@Inject` on a method registers an init hook that runs the method as a sub-plugin, `this.ctx.inject(deps, …)`, with `this.ctx` replaced by the sub-plugin context.

### Intercept config

- `logger`: `{ name?: string, level?: number }`, merged by `Object.assign` from the root-most ancestor to the nearest. `name` replaces the default logger name; `level` is the default threshold.
- Any `Service`: free-form per service, merged by `[Service.resolveConfig]`.

## Formats

The kernel writes no files and reads no environment variables.

**Global symbols** (`utils.ts:50-74`), all created with `Symbol.for`: `cordis.shadow`, `cordis.caller`, `cordis.receiver`, `cordis.original`, `cordis.metadata`, `cordis.initHooks`, `cordis.checkProto`, `cordis.effect`, `cordis.filter`, `cordis.isolate`, `cordis.intercept`, `cordis.init`, `cordis.check`, `cordis.config`, `cordis.invoke`, `cordis.extend`, `cordis.tracker`, `cordis.resolveConfig`, `cordis.is`, `ValidationError`, and in cosmokit `cosmokit.volatile.write`.

**`FiberState` numeric values** (`fiber.ts:147-154`): `PENDING = 0`, `LOADING = 1`, `ACTIVE = 2`, `FAILED = 3`, `DISPOSED = 4`, `UNLOADING = 5`. It is a `const enum`; consumers compare numbers.

**`LoggerLevel`**: `ERROR = 0`, `WARN = 1`, `INFO = 2`, `DEBUG = 3`.

**Errors**

| Error | Exact text |
|---|---|
| `CordisError` (`code: 'INACTIVE_EFFECT'`) | `cannot create effect on inactive context` |
| `ValidationError` (extends `TypeError`, `name = 'ValidationError'`) | `invalid config:\n` followed by one line per issue: `  - <message> (at <path joined by .>)`, or `  - <message>` without a path |
| `TypeError` | `Invalid effect`; `Async config validation is not supported` |
| `Error` | `invalid plugin, expect function or object with an "apply" method, received <typeof>` |
| `Error` | `cannot get property "<name>" without inject` |
| `Error` | `cannot get required service "<name>" in inactive context` |
| `Error` | `cannot set property "<name>" without provide` |
| `Error` | `cannot set property "<name>" in multiple fibers` |
| `Error` | `service "<name>" has been registered at <<fiber name>>` |
| `Error` | `property "<name>" is already declared as <type>` where `<type>` is `service` or `accessor` |
| `Error` | `next() called multiple times` |
| `Error` | `@Inject() can only be used on class or class methods` |

**Effect labels** seen in `getEffects()`: `anonymous`, `ctx.plugin()`, `ctx.on("<name>")`, `ctx.on(Symbol(<desc>))`, `ctx.on("internal/update")`, `ctx.provide("<name>")`, `ctx.accessor("<name>")`, `ctx.mixin("<source>")`, `ctx.logger.exporter()`.

**Dependency epoch string** (`fiber.ts:617-628`): `'__INACTIVE__'` when any declared dependency is unavailable; otherwise `"<revision>"` followed by `":<impl.uid>"` for each `inject` key in key order. Two epochs are equal exactly when the revision and every bound implementation are the same.

**Log message record** (`logger.ts:30-38`): `{ sn, ts, name, type, level, args, fiber }`. `sn` is a per-service counter incremented once per log call even when no exporter accepts it; `ts` is `Date.now()`; `type` is `'error' | 'warn' | 'info' | 'debug'`; `fiber` is a weak reference to the calling fiber.

**`Logger.format(exporter, message)`** (`logger.ts:99-131`): if `args[0]` is an `Error`, replace it with `stack || message` and use format `%s`; else if it is not a string, use format `%o`. Replace `%X` placeholders: `%%` → `%`; `s` → `String`; `d`, `i` → `Math.trunc(Number)`; `f` → `Number`; `o`, `O` → `JSON.stringify`; `c` → consumes an argument and prints nothing; `C` → the value colored by a hash of the logger name; unknown letters are left as written. Remaining arguments are appended with a space, objects through the `o` formatter. Each output line is cut at `exporter.maxLength` (default 10240) with `...` appended **(observed: `'hello %s %d %o extra', 'w', 4.7, {a:1}, {b:2}, 'tail'` → `hello w 4 {"a":1} extra {"b":2} tail`)**.

**`Logger.color(exporter, code, value, decoration = '')`**: without `exporter.colors`, `'' + value`; else `ESC[3<code>m` for `code < 8` or `ESC[38;5;<code>m` otherwise, with `decoration` inserted before `m` when `colors >= 2`, then the value and `ESC[0m`. **`Logger.code(name, level)`**: `hash = ((hash << 3) - hash) + charCode + 13` truncated to 32 bits per character; index `abs(hash) % length` into `c256` for `level >= 2`, `c16 = [6, 2, 3, 4, 5, 1]` for other truthy levels. The 75-entry `c256` table is at `logger.ts:167-173`.

**CLI**: `vendor/cordis/bin.js` takes no flags. It creates a root context, sets `ctx.baseUrl` to the working directory URL with a trailing slash, mounts the Loader, and calls `ctx.loader.create({ name: '@deepseek-ai/cordis-plugin-include', config: { path: './cordis.yml' } })`. dsh forbids it as a product launcher; the tutorial uses it.

## Algorithms and invariants

### Scheduling model

The kernel assumes one thread, run-to-completion code, and a FIFO queue of deferred continuations (JavaScript microtasks). Exact microtask counts are not a contract; these orderings are:

- G1. `ctx.plugin(p)` synchronously creates the fiber, emits `internal/plugin`, resolves dependencies, and, if they are available, sets state `LOADING`. It returns before the plugin body runs. The body runs on a later turn (`fiber.ts:689`) **(observed)**.
- G2. Bodies of plugins started in the same turn run in start order **(observed)**.
- G3. If the fiber's epoch changes before its body starts, the body never runs. Disposing a fiber right after `ctx.plugin()` returns skips `apply` **(observed)**.
- G4. A load that has started is never interrupted. A newer target is applied after the load settles.
- G5. A provider becomes visible when its fiber becomes `ACTIVE`. Dependents are re-evaluated synchronously inside that state change; their bodies run on a later turn.
- G6. Unload runs dependents to completion first, then the fiber's own disposers.

### Fiber state machine (`fiber.ts:580-746`)

Private variables: `_runner.epoch` (the target; `'__INACTIVE__'` or a dependency epoch), `_error`, `_revision`, `_configRevision`, `_store` (currently available dependency implementations), `committed`, `inertia`.

Stable state, `_getState()`: `uid === null` → `DISPOSED`; else `_error` set → `FAILED`; else `epoch !== INACTIVE` → `ACTIVE`; else `PENDING`.

`_updateState(callback)`: `state = callback() ?? _getState()`; if it changed, `emit('internal/status', fiber, oldState)`; if the old or new state is `ACTIVE`, for every `Impl` in the store owned by this fiber call `ctx.isolate(impl.name, impl.isolate).reflect.notify([impl.name])`.

`_setEpoch(epoch)`: return if unchanged; return if `_error` is set (a failed fiber recovers only through `update()`); store the epoch; return if `inertia` is set (the running transition will pick it up); otherwise, if the old epoch was inactive and the new one is active, start `_reload()` with state `LOADING`; in every other case start `_unload()` with state `UNLOADING`.

`_reload()` (async): `committed = { ..._store }`; add this fiber to `impl.dependents` for every committed implementation not owned by this fiber; remember the epoch; yield one turn; if the epoch is unchanged, run the plugin (`_execute`). On a throw or rejection: `ctx.logger.error(reason)`, and if the epoch is still the remembered one, set `_error = reason` and `epoch = INACTIVE`. Then: if the epoch equals the remembered one, clear `inertia` and take the stable state (`ACTIVE`); else start `_unload()` with state `UNLOADING`.

`_unload()` (async):

1. While any of this fiber's `provisions` has dependents, wait to be woken through `_release`.
2. Take `_disposables.clear()` (all top-level disposers, reverse registration order) and start each one after one yield; await all. A failing disposer is logged with `ctx.logger.error` and does not stop the others.
3. For each committed implementation: remove this fiber from `dependents`; if that emptied the set, call `impl.release?.()` and `impl.ctx.fiber._release?.()`.
4. `committed = undefined`.
5. If the epoch is inactive, clear `inertia` and take the stable state (`PENDING`, `FAILED`, or `DISPOSED`); else start `_reload()` with state `LOADING`.

Transitions that occur: `PENDING→LOADING`, `LOADING→ACTIVE`, `LOADING→UNLOADING` (failure or superseded), `ACTIVE→UNLOADING`, `UNLOADING→LOADING` (restart, dependency replaced, pending update), `UNLOADING→PENDING` (dependency lost), `UNLOADING→FAILED`, `UNLOADING→DISPOSED`, `PENDING→UNLOADING` and `FAILED→UNLOADING` (disposal), `FAILED→LOADING` (`update`).

Observed sequences: normal start `0→1`, `1→2`; restart `2→5`, `5→1`, `1→2`; dispose `2→5`, `5→4`; failing body `0→1`, `1→5`, `5→3`; update of a failed fiber `3→1` then `1→2` or back to `3`.

A failed activation therefore still unloads: effects the body registered before throwing are disposed **(observed)**. `await fiber` rejects with the error. The error is always an `Error` object: a thrown non-error value is wrapped as `new Error(value)` (`utils.ts:247-257`) **(observed)**.

### Fiber construction and disposal (`fiber.ts:226-339`)

Plugin fiber, in order:

1. `uid = registry.counter`; `ctx = parent.extend({ fiber: this })`; install per-dependency intercept config.
2. Register an effect on the **parent's fiber** labelled `ctx.plugin()`. Setup adds this fiber to `runtime.fibers`. The effect's disposer is `fiber.dispose`.
3. `emit('internal/plugin', this)`. On a throw: dispose the fiber and rethrow.
4. If the fiber was not disposed during step 3 and the parent is not `UNLOADING`: `_checkImpl(name)` for every key of `inject` (including keys added in step 3), then `_refresh()`.

`ctx.plugin()` on a disposed context or under an `UNLOADING` parent throws `INACTIVE_EFFECT` **(observed)**. It is legal on a `PENDING` parent; the child then activates on its own dependencies **(observed)**.

Disposer body (`fiber.ts:273-302`): set `uid = null`; emit the contained `internal/plugin`; if the registry still has the runtime, remove the fiber from `runtime.fibers` and delete the runtime when the list is empty; `_setEpoch(INACTIVE)`; if no transition is running (a `PENDING` or `FAILED` fiber may still own effects), start `_unload()` with state `UNLOADING`; then `while (inertia) await inertia`.

`fiber.dispose()` returns a promise on the first call and `undefined` on later calls, even while the first is still running **(observed)**. To join teardown, await `fiber.dispose()` and then loop on `fiber.inertia`.

Root fiber: `uid = 0`, state `ACTIVE`, epoch `'0'`, empty `committed`, a no-op body. `dispose()` is `restart()`: it unloads every effect registered through the root context (plugins, listeners, services), runs the no-op body, and returns to `ACTIVE`. The root is never `DISPOSED`, and the built-in services and mixins survive **(observed)**.

### Plugin body result (`_execute`, `fiber.ts:362-406`)

The body is `resolveConfig(this.config)`, store the result as the effective config, then call the plugin. The returned value is interpreted as an `Effect`:

- function → collected as a disposer;
- `null` / `undefined` → nothing;
- thenable → awaited; its value must be a function or nullish;
- sync iterable → every yielded value **and** the return value must be a function or nullish; each function is collected **(observed for generators)**;
- async iterable → same, checked one step at a time; iteration stops silently if the runner's epoch changed (the iterator's `return` is not called);
- anything else, including numbers, booleans, strings, and plain objects → `TypeError('Invalid effect')`, which fails the fiber **(observed)**.

For the plugin runner, collected disposers are appended to the fiber's top-level list, so they run first at unload **(observed)**.

Quirk to decide on in the port: a constructible function plugin is called with `new`, and the kernel then reads `instance[Service.init]`. A disposer returned from a `function` declaration is therefore dropped, while the same code as an arrow function or `apply() {}` method has it collected **(observed)**.

### `ctx.effect` (`fiber.ts:424-567`, V6)

Preconditions: `uid !== null` and `state !== UNLOADING`, else `CordisError('INACTIVE_EFFECT')`. Registration during `PENDING` and `LOADING` is legal.

Each effect has a list of collected inner disposers, a `released` flag, and metadata `{ label, children }`.

1. Create the public disposer `D` (it carries the metadata under `Context.effect`) and append it to the owner's top-level list **before** running `execute`.
2. Run `execute()` and interpret the result with the same rules as a plugin body. Collecting a disposer `d` appends it to this effect's list, removes `d` from the owner's top-level list, and, if `d` is itself an effect disposer, adds its metadata to `children`. A nested effect that is returned or yielded thus becomes a child; a nested effect that is merely created inside `execute` stays a separate top-level effect.
3. Synchronous setup failure: mark released; run the collected disposers (rollback) and remove `D` from the owner; rethrow to the caller. If the rollback is asynchronous, `D` stays in the owner's list until it settles and its failure is logged.
4. Asynchronous setup failure: run the collected disposers, remove `D`, log only a rollback failure. The setup error itself is **not** logged; it reaches only a caller that awaits the effect **(observed)**.

Cleanup of one effect: single-shot; runs collected disposers in reverse collection order, strictly one after another, waiting for each asynchronous one before starting the next **(observed)**. If one throws, the rest of that effect's inner disposers are skipped.

Calling `D()`:

- already released → `undefined` (or the in-flight rollback promise if setup failed synchronously and an owner unload is joining it);
- called during synchronous setup (re-entrant) → a promise that waits for setup to finish, including its asynchronous part, then cleans up;
- setup was asynchronous → a promise that waits for setup, then cleans up; if setup failed, cleanup runs and the promise rejects with the setup error;
- otherwise → cleanup runs now; the result is `undefined` when every inner disposer was synchronous, else a promise **(observed)**.

While a cleanup promise is pending, `D` stays in the owner's top-level list and an internal table maps `D` to that promise. When the owner unloads, or an outer effect disposes `D` as a child, the kernel calls `D()` and also awaits the recorded promise. This is how an unload joins a cleanup that another caller started.

`await D` waits for asynchronous setup and yields a plain, non-thenable function that disposes the effect; calling that function after the effect was released returns `undefined` **(observed)**. Every effect disposer is thenable, including those of synchronous effects.

### Disposal order summary

At fiber unload: top-level disposers start in reverse registration order, one turn apart; synchronous ones therefore complete in reverse order; asynchronous ones overlap **(observed: `returned-disposer, g3, g2-start, e3, e2-start, e1, child-e, g2-end, g1, e2-end`)**. Inside one effect the order is strict. Code that needs sequential teardown keeps the steps in one effect or one disposer.

`DisposableList` (`utils.ts:5-40`): insertion-ordered map from a serial number to a value; `push(v)` returns a remover; `delete(v)` removes by the value's latest serial; `clear()` empties the list and returns the values in reverse order; iteration is in insertion order.

### Providing and withdrawing a service (`reflect.ts:291-327`)

`provide(name, value, check)` inside its effect:

1. Declare `props[name] = { type: 'service' }`; throw if `name` is declared as an accessor.
2. `root[symbols.isolate][name] ??= Symbol(name)`: the default scope label is created on first provide.
3. `key = ctx[symbols.isolate][name]`. Throw `service "<name>" has been registered at <…>` if `store[key]` exists.
4. Create the `Impl` with a fresh `uid`, store it, add it to the calling fiber's `provisions`.
5. If the calling fiber is `ACTIVE`, `notify([name])` now. Otherwise the notification happens when the fiber becomes `ACTIVE`.

Disposer: delete the store entry if it is still this implementation; notify the implementation's scope; wait until `impl.dependents` is empty (always yielding at least once); then remove it from `provisions`. The provider can still read its own service until its last dependent has finished teardown.

The service declaration in `props` is never removed, so `name in ctx` stays `true` after withdrawal **(observed)**.

### Dependency tracking

`_checkImpl(name)` (`fiber.ts:603-615`): look up the strict implementation from the fiber's context (provider must be `ACTIVE`, isolation label must match). Remove `name` from `_store` if there is none, if `impl.check` returns falsy when called with `this` = the service traced to the fiber's context, or if it throws (logged on the provider's logger). Otherwise `_store[name] = impl`.

`_refresh()`: compute the epoch string and call `_setEpoch`.

`notify(names, filter)` (`reflect.ts:335-354`): the default `filter(ctx, name)` is "same isolation label as the notifier". For each runtime in registration order and each fiber in creation order: for every name the fiber injects and the filter accepts, `_checkImpl(name)`; if any matched, `_refresh()`. Then for each name, emit `internal/service` with a receiver whose `Context.filter` applies the same test.

Consequences:

- A plugin waits in `PENDING` until every injected name has an `ACTIVE` provider in its scope whose `check` accepts it.
- Losing a dependency unloads the plugin to `PENDING`; a replacement implementation (different `impl.uid`) unloads and reloads it **(observed)**.
- A provider restart produces: provider `ACTIVE→UNLOADING`; dependents unload completely, still able to read the service in their disposers; provider disposers run; provider reloads; dependents reload **(observed: `cons cleanup, svc alive=true | prov cleanup | prov apply | cons apply`)**.
- A service provided through a `PENDING` fiber's context is invisible to strict reads and dependents until that fiber activates **(observed)**.
- The root fiber is not in the registry and is never notified.

### Context property resolution (`reflect.ts:143-219`)

A property is **special** if it is a symbol, `prototype`, `then`, a canonical integer string, or starts with `_`. Special properties bypass every rule and behave as plain inherited properties.

Read `ctx.name`:

1. Own or inherited plain property → that value.
2. Property of the root object or `Context.prototype` → the value, traced to `ctx`.
3. Declared accessor → `get.call(ctx, receiver, error)`.
4. Let `defSite = ctx[symbols.shadow] ?? ctx`. If `defSite.fiber` is the root fiber → `ctx.reflect.get(name, false)`: unchecked, non-strict, `undefined` when absent.
5. Otherwise run waterfall `internal/get(ctx, name, error, next)` whose default walks fibers starting at `defSite.fiber` with `key = defSite[symbols.isolate][name]`:
   - candidate = `fiber.committed?.[name]`; a provision of this fiber with the same name whose providing context has label `key` overrides it;
   - a candidate → return its value traced to `ctx`;
   - `name in fiber.inject` → throw `cannot get required service "<name>" in inactive context`;
   - the root fiber, or a parent context whose label for `name` differs from `key` → throw `cannot get property "<name>" without inject`;
   - else continue with the parent's fiber.

So a plugin can read: services it injects (while loaded), services it provides in the matching scope, and the same for every ancestor up to the first isolation boundary for that name. Services provided through the root context are visible to every non-isolated plugin without `inject`; a sibling's service is not **(observed)**.

Write `ctx.name = v`: special → plain write. Undeclared name → plain write on a root-fiber context, otherwise throw `cannot set property "<name>" without provide`. Accessor → its `set` (a missing setter makes the assignment fail). Service → waterfall `internal/set`, default `reflect.set`.

`name in ctx`: special → plain; else a plain property of the root or a declared name.

### Config resolution and update (`fiber.ts:649-819`, V15)

`resolveConfig(candidate)` = waterfall `internal/config(fiber, () => candidate)`. It is pure: it does not store the result. The kernel listener validates with the runtime's schema and returns the schema's result object; the root fiber has no schema.

Activation calls `resolveConfig(fiber.config)` and stores the result as `effectiveConfig`. Validation failure at activation fails the fiber like a thrown body **(observed)**.

`update(config, noSave)`:

1. `assertActive()`. `loaded = epoch !== INACTIVE`.
2. If loaded, `resolved = resolveConfig(config)`; a `ValidationError` propagates synchronously and nothing else changes **(observed)**.
3. Unless `noSave`, `emit('internal/commit', fiber, config)`.
4. `fiber.config = config`; clear `_error`; bump the config revision; remember the epoch and `committed`.
5. If loaded, `result = waterfall(fiber, 'internal/update', resolved, restart)`; else `result = restart()`.
6. `publish()` sets `effectiveConfig = resolved` only if no restart happened, the fiber is not disposed, and the config revision, epoch, and `committed` are all unchanged since step 4.
7. If `result === undefined` (a listener kept the instance synchronously), publish and return `undefined`. Otherwise return `Promise.resolve(result).then(publish)`; its rejection is marked handled, and still reaches a caller that awaits it.

Rules that follow, each pinned by a spec: a listener that returns without `next()` keeps the running instance and the candidate becomes the effective config; a listener that calls `next()` restarts and the effective config is the object the new activation received; a stale, rejected, or superseded completion never publishes; an update on a `PENDING` fiber only retains the raw config; several updates during one load coalesce to the last one.

### Volatile config (V22, kernel part)

The kernel only re-exports the `Volatile` and `VolatileSnapshot` types. Volatile fields are produced by the schema library and committed by the Loader; the fiber lifecycle is unchanged. The kernel's contribution is that `resolveConfig` is pure, so the Loader can parse a candidate, compare it, and write new values into the running references without a restart.

### cosmokit algorithms the kernel and Loader depend on

- `defineProperty(obj, key, value)`: writable, non-enumerable, non-configurable data property.
- `isNullable(v)`: `v === null || v === undefined`.
- `remove(list, item)`: removes the first occurrence; returns whether it was found.
- `hyphenate` = `paramCase`: a three-state tokenizer (`DELIM`, `UPPER`, `LOWER`) over ASCII (`string.ts:22-54`). An uppercase letter is lowercased and gets a `-` before it when it follows a lowercase letter, or when it follows an uppercase letter and precedes a lowercase one. `-` and `_` become one `-`, never doubled or leading. Other characters pass through without changing state. `MyPluginName` → `my-plugin-name`, `HTTPServer` → `http-server`, `abc1Def` → `abc1-def`, `foo_bar-Baz` → `foo-bar-baz`, `_lead` → `lead`, `a__b` → `a-b` **(observed)**.
- `deepEqual(a, b, strict?)` (`types.ts:127-168`): identical values are equal; if either side is a volatile reference, equal exactly when both are; non-strict treats `null` and `undefined` as equal; arrays compare by length and every slot (holes as `undefined`); `Date` by time value; `URL` by `href`; `RegExp` by source and flags; array buffers bytewise; other objects by the union of own enumerable keys, so a key that is missing on one side equals an `undefined` value on the other in both modes; in strict mode this key comparison applies only when both are plain objects, and other objects compare by identity (two empty `Map`s are equal non-strict and unequal strict); a structure revisited on the left side during recursion compares unequal **(observed)**.
- Volatile references (`volatile.ts`): `createVolatile(value)` returns a frozen `{ get() }` holding a recursively frozen copy of plain data; functions, cycles, and non-plain objects throw `TypeError` (`volatile config cannot contain functions`, `volatile config cannot contain cycles`, `volatile config objects must be plain objects or arrays`). `isVolatile(v)` tests for the `cosmokit.volatile.write` symbol. `volatileEntries(value)` lists `{ path, ref }` through plain objects and arrays without entering references. `updateVolatile(target, source)` copies the source snapshot into the target.
- Catalog depth: `noop`, `isNonNullable`, `isPlainObject`, `filterKeys`, `mapValues` (alias `valueMap`), `pick`, `omit`, `contain`, `intersection`, `difference`, `union`, `deduplicate`, `makeArray`, `is`, `Binary` (base64 and hex conversion), `clone`, `capitalize`, `uncapitalize`, `camelCase` (alias `camelize`), `snakeCase`, `formatProperty`, `trimSlash`, `sanitize`, `Time` (unit constants, `parseTime`, `parseDate`, `format`, `template`, date numbers).

### Kernel internals the Loader mutates

The Racket kernel must expose equivalents, because `vendor/loader` reaches into them: `fiber.inject` (extended inside `internal/plugin`); `fiber._checkImpl` and `fiber._refresh` (`loader/src/config/entry.ts:108`); `ctx[Context.isolate]` and `ctx[Context.intercept]` replaced, re-parented with `Object.setPrototypeOf`, and rewritten in place on a live context (`loader/src/config/isolate.ts:92-127`); `reflect.store` entries moved between labels with `impl.isolate` updated (`isolate.ts:133-139`); `reflect.notify(names, customFilter)`; arbitrary symbol-keyed properties set on a context and inherited by descendants; dispatch receivers that are ad hoc objects carrying `Context.filter` (`entry.ts:191-194`, `packages/core/scope/src/index.ts:170-185`); extra fields attached to fibers (`fiber.entry`).

### Quirks at the pinned commit

Each needs a decision in the port: reproduce it or fix it and record the difference.

1. A constructible function plugin loses its returned disposer (above).
2. `ctx.on()` disposers return `undefined`.
3. `prepend: true` on a fiber-local `internal/update` listener throws `TypeError`.
4. `emit` has no error containment; throwing `internal/status` or creation-time `internal/plugin` observers break kernel operations.
5. An unawaited asynchronous effect that fails is silent.
6. A second call to a disposer does not join the running cleanup.
7. `await ctx.plugin(p)` resolves at once for a `PENDING` fiber.
8. `ctx.set` does not notify dependents.
9. `registry.delete` does not await the disposals it starts.
10. `ctx.mixin(object, …)` does not work.
11. The first dispatch argument is taken as the receiver whenever it is an object or function.
12. Mixin members need the same access rights as their source: `ctx.setTimeout` fails with `cannot get property "timer" without inject` in a plugin that cannot read `timer`.
13. `ctx.plugin()` under an `UNLOADING` parent whose `uid` is still set (a restart) throws after the runtime record was created, leaving a runtime with zero fibers in the registry **(observed)**.
14. Inside one effect, a throwing inner disposer skips the remaining inner disposers of that effect.
15. Stack-trace splicing (`composeError`, `buildOuterStack`, `enhanceError`) is V8-specific diagnostics with no behavioral contract beyond wrapping thrown non-errors.

## Tests worth porting

No upstream Cordis test suite is vendored. The files below are the complete set of kernel-level specs in the repository.

### `scripts/cordis-core-lifecycle.spec.ts` (kernel, port one-to-one)

1. **Latest update wins while loading** (run with and without an `inject`). Given an active plugin with config `{value: 0}` whose body blocks for `value === 1` and registers a cleanup recording its value. When `update({value:1})` starts, then `update({value:2})` and `update({value:3})` are issued while it is loading, then the block is released. Then bodies ran for `[0, 1, 3]`, cleanups ran for `[0, 1]`, state is `ACTIVE`, `effectiveConfig` equals `{value: 3}`, and disposal adds `3` to the cleanups.
2. **Superseded activation failure**. Given a plugin whose activation with config `1` registers a cleanup, blocks, then throws. When `update(2)` is issued during the block and the block is released. Then the cleanup ran once, state is `ACTIVE`, `effectiveConfig` is `2`.
3. **Providers outlive dependent teardown** (for `dispose` and `restart`). Given a provider that provides a service into an isolated scope and registers a cleanup that marks it dead, and a consumer in that scope whose disposer blocks, then asserts the service is alive. When the provider is disposed or restarted. Then nothing is cleaned until the consumer's disposer is released, and the order is `['consumer', 'provider']`.
4. **Own isolated provision versus committed injection**. Given a root service `'outer'` and a plugin injecting it that provides `'inner'` under an isolated child context. Then the plugin context reads `'outer'`, the isolated context and a child plugin mounted on it read `'inner'`, and after the provision is withdrawn both read `'outer'`. And a plugin that provides a name only under an isolated context cannot read that name from its own context (`without inject`).
5. **Retained-instance updates publish; stale and rejected ones do not**. Given a plugin with a local `internal/update` listener that returns a pending promise for config `1`, a rejecting promise for `3`, and nothing for `2`. Then after `update(1)` `effectiveConfig` is still `0`; after `await update(2)` and then resolving the first promise it is `2`; `update(3)` rejects with the listener's error while `rawConfig` is `3` and `effectiveConfig` stays `2`; the body ran once.
6. **No publication after raw retention, restart, or dispose**. Given a pending retained-instance update. When `rawConfig` is set, or `restart()` completes, or `dispose()` completes, and the update then resolves. Then `effectiveConfig` is the object the most recent activation received.
7. **Delegating listener keeps restart identity**. Given a local `internal/update` listener that calls `next()` and an `internal/config` listener that copies the config. When `update({value:1})` completes. Then `effectiveConfig` is the same object the new activation received.
8. **Symbol events and waterfall guard**. A listener on a symbol event receives an emit on that symbol. A waterfall listener that calls `next()` twice makes the dispatch throw `next() called multiple times`.

### `packages/extensions/tool-cordis/tests/cordis-lifecycle.spec.ts` (kernel V6 hardening, port one-to-one)

9. **Re-entrant restart sees the effect**. Given an async effect on the root whose setup calls `ctx.fiber.restart()` and then blocks, and whose cleanup blocks. Then the restart does not settle until setup has finished and cleanup has finished; afterwards `getEffects()` is empty.
10. **Synchronous setup failure rolls back**. Given a generator effect that yields one cleanup and then throws. Then `ctx.effect` throws the error, the cleanup ran once, `getEffects()` is empty.
11. **Re-entrant restart awaits asynchronous rollback**. Given a generator effect that yields an async cleanup, calls `restart()`, then throws. Then the effect call throws, and the restart settles only after the cleanup finishes.
12. **Synchronous teardown, single-shot disposer**. Given a synchronous effect. Then the first `dispose()` returns `undefined` and runs the cleanup; the second returns `undefined` and does nothing.
13. **No registration during unload**. Given an effect whose cleanup calls `ctx.effect`. When the fiber restarts. Then that call throws `CordisError` with code `INACTIVE_EFFECT`, the fiber ends `ACTIVE`, and no effect remains.
14. **Registration is legal in `PENDING` and `LOADING`**. Given an `internal/plugin` observer that registers an effect on a new fiber (state `PENDING`) and a body that registers one (state `LOADING`). When the fiber is disposed. Then both cleanups ran.
15. **Dependencies added by `internal/plugin` are honored**. Given an observer that adds an available service to `fiber.inject`. Then the body runs once and the fiber is `ACTIVE`.
16. **Publication failure rolls back ownership**. Given an `internal/plugin` observer that throws for a plugin. Then `ctx.plugin()` throws and `registry.has(plugin)` is `false`.
17. **Teardown notification is contained**. Given two disposal-time `internal/plugin` observers, the first throwing. Then `dispose()` resolves, the second observer ran, exactly one error was logged, and `uid` is `null`.
18. **Loading parent joins child cleanup**. Given a parent whose body mounts a child, and an observer that gives the child an async cleanup and then disposes the parent and the child. Then the parent's disposal settles only after the child's cleanup; both end with `uid === null`.
19. **Parent disposal during publication**. Given an observer that gives a new child an async cleanup and a second observer that disposes the child's parent. Then the parent's disposal waits for the cleanup, the child's body never runs, and the child ends `DISPOSED`.

### `scripts/cordis-config-access.spec.ts` (kernel accessors; case 20 needs Loader and Schemastery)

20. **Candidate resolution is pure**. Given a Loader entry with a volatile numeric field configured by a `!!js` expression. Then `rawConfig` is the entry's raw object and `effectiveConfig` is the object the body received; `resolveConfig` of another expression returns a fresh object with a different reference; an invalid candidate throws; raw, effective, the running reference's value, and the body call count are unchanged.
21. **Wrapper reaches the canonical fiber; raw retention does not update**. Given the wrapper returned by `ctx.plugin(apply, initial)`. When `wrapper.rawConfig = raw`. Then the canonical fiber's `rawConfig` is `raw`, `effectiveConfig` is still `initial`, `resolveConfig(raw)` returns `raw` and calls the `internal/config` listener once with the canonical fiber, the body ran once; after `restart()` `effectiveConfig` is `raw` and the body ran twice.
22. **Update through the wrapper**. After `await wrapper.update(raw)`, the body was last called with `(wrapper.ctx, raw)`, and raw and effective config are `raw` on both wrapper and canonical fiber.
23. **Pending raw update**. Given a plugin whose injection is missing. When `update(raw)` is awaited. Then `rawConfig` is `raw` and `effectiveConfig` is `undefined`; after the service is provided, the body runs once with `raw`.

### Loader-level and tooling specs (other recon areas; catalog depth)

- `scripts/cordis-timer.spec.ts`: Timer plugin; interval iterators settle in order and on `return`/`throw`/dispose (`Context has been disposed`), throttle and debounce become inert after disposal.
- `scripts/cordis-entry-commit.spec.ts`: Loader tree change reports, ids containing `:`, Include patch data is detached.
- `scripts/cordis-include-journal.spec.ts`: Include file and runtime edit merging, conflicts, cross-tree moves (V14, V26).
- `scripts/cordis-loader-resolve.spec.ts`: module resolution from the config's package scope.
- `scripts/cordis-vendor-hmr-include.spec.ts`: HMR logs a rejected Include refresh.
- `scripts/cordis-core-api.spec.ts`, `scripts/cordis-config-files.spec.ts`, `scripts/gen-cordis-catalog-partition.spec.ts`, `scripts/verify-cordis-config.spec.ts`: documentation generators and config gates; no kernel behavior.

### Supplementary cases (each observed on the vendored source; add them to the Racket kernel suite)

- S1. `ctx.plugin()` returns with state `LOADING`; the body runs later; `sync-after, A, B` ordering for two plugins.
- S2. Disposing right after `ctx.plugin()` returns: body never runs; state `DISPOSED`.
- S3. Status sequences listed under "Fiber state machine", including the failure path and `uid=null` in the disposal `internal/plugin`.
- S4. Failed fiber: `await` rejects, effects registered before the throw are cleaned, `restart()` rejects with the same error, `update()` retries.
- S5. `inject` wait: `PENDING` until the provider is `ACTIVE`; reading the name early throws `cannot get required service … in inactive context`.
- S6. Visibility: own injection, own provision, ancestor's injection (child inherits), root-provided service, sibling's service (`without inject`), `ctx.get` from anywhere, root context reading an unknown name (`undefined`).
- S7. Listener order with `prepend`; snapshot semantics for add and remove during dispatch; `once`.
- S8. `emit` propagates the first throw; `parallel` rejects with `AggregateError` after all ran; `bail`/`serial` return `0` past `null` and `false`.
- S9. Waterfall order `w1, w2, inner` and value composition.
- S10. `internal/dispatch` sees `['emit', 'e', 0, null]`, not `internal/*` events.
- S11. Filtered dispatch reaches matching-scope and `global` listeners only; a `Service` dispatching with itself as receiver reaches only its own scope.
- S12. Fiber-local `internal/update`: label, `this` is the fiber, veto returns `undefined` and publishes; global and local hook order.
- S13. `internal/config` order relative to validation, and double resolution during an update.
- S14. `provide` twice → registered-at error; `set` from another fiber, undeclared write, `ctx.set` unprovided → the three error texts; root plain write; withdrawal keeps `in` true.
- S15. `accessor` on a service name and `provide` on an accessor name → already-declared errors; accessor `get` runs with the reading context as `this`.
- S16. `mixin` with array and map forms; effect tree `ctx.mixin("src")` with accessor children; writes through a mixin reach the source.
- S17. Unload order string from "Disposal order summary".
- S18. `await effect` yields a non-thenable function; async setup failure rejects the await and leaves no effect; invalid results and non-error throws.
- S19. Disposed context: `effect`, `on`, `plugin` throw `INACTIVE_EFFECT`; invalid plugin texts.
- S20. Provider restart and provider replacement sequences.
- S21. Service tracing: caller-owned effect removed with the caller, definition-site resolution, getter sees the caller, `instanceof`.
- S22. `check` with intercept config from object `inject` and from `ctx.intercept`; `resolveConfig(base, head)` merge order.
- S23. Registry identity: shared `apply` → one runtime, three fibers, uids `1, 2, 3`; `delete` disposes all; name rules (`apply2`, anonymous object → parent's name, `ctx.inject` uses the callback name).
- S24. Schema validation: defaults reach the body, raw stays raw; invalid initial config → `FAILED` with the exact message; invalid `update` throws synchronously; `noSave` suppresses `internal/commit`.
- S25. Isolation: two scopes, two store entries, `isolate(name, label)` joins a scope, scoped `internal/service`.
- S26. Late provide through an active fiber notifies at once; provide through a `PENDING` fiber is hidden until it activates; strict versus non-strict `get` during an asynchronous load.
- S27. Logger: default and intercept names, level thresholds, `cause` logged before the error, `AggregateError` members logged individually, buffer and `sn`.
- S28. Root `dispose()`: root stays `ACTIVE` with `uid 0`, all root effects and plugins gone, built-in methods still work.
- S29. Class plugins: decorator-style inherited `inject`, async-generator `[Service.init]`, visibility only after init, cleanup in reverse.
- S30. Callable service, `[Service.extend]`, and associated `"call.extra"` accessor with and without a receiver.

## Porting notes

### Essential behavior versus JavaScript machinery

Essential: the fiber state machine and its supersession rules; effect ownership, rollback, and join semantics; reverse-order disposal; dependents-first teardown; isolation labels and the visibility walk; the five dispatch modes with snapshot ordering, `prepend`, `global`, and receiver filters; `internal/*` events and their emit points; config resolution, update, and publication rules; the use-site and definition-site contract; exact error texts and effect labels (tests and harness code match on them); numeric `FiberState` values where they cross a wire or a log.

Machinery to replace, not copy: `Proxy` traps, prototype chains, thenable objects, `new`-versus-call detection, `Symbol.hasInstance`, callable objects built by prototype surgery, decorators, V8 stack splicing, `WeakRef`.

### Suggested Racket decomposition

- `cordis/private/scheduler.rkt`: a single kernel execution context with a FIFO job queue and a small task type (pending, fulfilled, rejected, waiters). Every kernel entry point runs to completion between explicit wait points. Racket threads are preemptive, so either run all kernel and plugin code under one baton (a semaphore released only at `await` points and re-acquired in FIFO order) or run a dedicated kernel thread that plugin threads post jobs to. Orderings G1 to G6 and the spec cases define what must hold; microtask counts do not.
- `cordis/private/disposable.rkt`: `DisposableList` and the effect record with its `released` flag, collected list, setup task, and in-flight cleanup task.
- `cordis/fiber.rkt`: a mutable struct with the fields listed under Services; `prop:evt` so that `(sync fiber)` behaves like `fiber.await()`; an extension property table for Loader-attached data.
- `cordis/context.rkt`: a context struct with a parent link, a mutable property table (symbol-keyed and string-keyed, inherited through the parent link), mutable and re-parentable isolate and intercept tables, the owning fiber, and an optional definition-site context. Expose the read/write/has algorithm as `ctx-ref`, `ctx-set!`, `ctx-has?`; add a reader form or macro for `ctx.name` access if wanted.
- `cordis/reflect.rkt`, `cordis/registry.rkt`, `cordis/events.rkt`, `cordis/logger.rkt`, `cordis/service.rkt`: one module per service, same state as the TypeScript classes.
- `cordis/cosmokit.rkt`: `hyphenate`, `deep-equal?`, volatile references, and the small list helpers.

Idioms: a `define-plugin` form producing a plugin struct `(name inject config apply)` whose `apply` procedure is the registry key (`eq?`); a `define-service` form that generates the provide call, the tracker, and method wrappers; a `define-events` form that records each event's dispatch mode and generates typed dispatch wrappers plus the catalog entry; contracts for plugin declarations, effect results, and the schema interface `validate : any -> (or/c value issues)`; exception structs `exn:fail:cordis` (with `code`) and `exn:fail:cordis:validation` (with `issues`).

Use site and definition site: return a bound-service value `(service, use-ctx)` from `ctx-ref`, and have generated service methods receive a shadow context built from the bound use site and the service's stored context. Do not replace this with an ambient parameter such as `current-context`: harness code reads services through contexts other than the running plugin's own (scope contexts from `packages/core/scope`), and ownership must follow the context used for the read. Parameters fit only as an implementation detail of listener wrapping (`reflect.bind`). Provide `service-original` for identity comparison in place of `symbols.original`.

Custodians: give each fiber a custodian under its parent's as a leak backstop for threads, ports, and subprocesses, and shut it down only after the ordered disposers have finished (`DISPOSED`, or the end of each unload). Custodian shutdown is immediate and unordered, so it cannot implement disposal itself: dependents must be able to use a provider during their own teardown.

### Hard parts and risks

1. The asynchronous state machine: supersession during `LOADING`, the dependents wait in `_unload`, and joining cleanups started elsewhere. Port specs 1 to 3, 9 to 11, 18, and 19 first.
2. The effect disposer's three behaviors in one value: synchronous single-shot call, awaitable setup, and owner-visible in-flight cleanup.
3. Use-site semantics without proxies, including re-tracing of event arguments and the dotted `foo.bar` association.
4. The Loader's in-place mutation of isolation and intercept tables and of the store; design the context tables as mutable cells from the start.
5. Global event delivery with opt-in filters: a per-fiber or per-scope event bus would be wrong.
6. Error containment is uneven by design (contained at unload and disposal notification, uncontained in `emit`). Reproduce the boundaries before improving them, because harness plugins are written against them.
7. Decide and record each quirk in the list above; quirk 1 changes which disposers run for function-declared plugins and needs a check of ported plugins.

### What can only be wrapped

Nothing in the kernel needs Node. `composeError`/`buildOuterStack` are V8 stack diagnostics and can be dropped or replaced with continuation marks. `LoggerService` color codes are plain ANSI. `bin.js` is a launcher that dsh does not ship as a product entry.

## Feature checklist

- cordis: root context construction with built-in `reflect`, `registry`, `events`, `logger`, root fiber (`uid 0`, `ACTIVE`).
- cordis: built-in services survive root restart; `ctx.get('logger')` is `undefined`.
- cordis: `ctx.extend(meta)` with string and symbol keys, parent unchanged.
- cordis: `ctx.isolate(name, label?)` creates or joins a scope.
- cordis: `ctx.intercept(name, config)` layered per-service config.
- cordis: `Context.is` brand check.
- cordis: special property rule (symbol, `prototype`, `then`, integer string, `_` prefix).
- cordis: property read algorithm with `without inject` and `in inactive context` errors.
- cordis: root-fiber contexts read services unchecked and non-strict.
- cordis: property write algorithm with `without provide` and `in multiple fibers` errors.
- cordis: `in` operator semantics; service declarations persist after withdrawal.
- cordis: ancestor visibility walk bounded by isolation labels.
- cordis: `internal/get` and `internal/set` waterfalls around property access.
- cordis: `ctx.get(name, strict)` strict and non-strict reads.
- cordis: `ctx.set(name, value)` owner-only, no notification.
- cordis: `ctx.provide(name, value, check?)` as an effect; duplicate-in-scope error.
- cordis: provide disposer waits for dependents before leaving `provisions`.
- cordis: late provide by an `ACTIVE` fiber notifies immediately.
- cordis: provider visibility tied to `ACTIVE` state.
- cordis: `ctx.accessor(name, {get, set?})` with conflict errors.
- cordis: `ctx.mixin(name, keys | map)` as an effect tree of accessors.
- cordis: mixed-in names `get set provide accessor mixin runtime effect inject plugin on once parallel emit serial bail waterfall`.
- cordis: `reflect.notify(names, filter?)` dependent re-evaluation in runtime then fiber order.
- cordis: `reflect.bind` re-traces `this` and arguments to the listener's context.
- cordis: tracker-based service tracing; `service.ctx` is the use site.
- cordis: shadow context: caller-owned effects, definition-site resolution.
- cordis: nested traced values and method results re-traced.
- cordis: dotted associated properties `ctx.foo.bar` → `"foo.bar"`.
- cordis: `symbols.original` and `symbols.caller` on traced values.
- cordis: plugin forms: function, `{apply}` object, class, `Service` subclass.
- cordis: registry keyed by callback identity; runtime `name`/`Config` from first registration.
- cordis: one fiber per `ctx.plugin()` call; no deduplication.
- cordis: `ctx.plugin` returns a thenable resolving to the canonical fiber.
- cordis: invalid plugin error; `INACTIVE_EFFECT` on disposed or unloading parent.
- cordis: `ctx.inject(deps, callback)` shorthand.
- cordis: `registry.get/has/delete/keys/values/entries/forEach/size/resolve/counter`.
- cordis: `inject` array form, object form with intercept config, decorator form with inheritance.
- cordis: `@Inject` on methods runs them as sub-plugins.
- cordis: fiber creation order: parent effect, `internal/plugin`, dependency resolution.
- cordis: `fiber.inject` additions during `internal/plugin` are honored.
- cordis: publication failure rolls back child and runtime.
- cordis: deferred activation; body skipped when superseded before start.
- cordis: state machine `PENDING/LOADING/ACTIVE/FAILED/DISPOSED/UNLOADING` with numeric values.
- cordis: `internal/status` on every state change.
- cordis: notification of provided services when a fiber enters or leaves `ACTIVE`.
- cordis: failed activation logs, unloads collected effects, ends `FAILED`.
- cordis: failed fiber recovers only through `update()`.
- cordis: thrown non-errors wrapped as `Error`.
- cordis: plugin result shapes: disposer, promise, sync iterable, async iterable; `Invalid effect`.
- cordis: class plugin `initHooks` then `[Service.init]`.
- cordis: dependency epoch and reload on replacement.
- cordis: `Service.check` gating per dependent.
- cordis: dependents-first unload; providers readable during dependent teardown.
- cordis: unload runs top-level disposers in reverse start order, errors logged and contained.
- cordis: `fiber.dispose()` semantics, disposal `internal/plugin` with `uid null`, contained observers.
- cordis: disposal of `PENDING` and `FAILED` fibers drains their effects.
- cordis: root `dispose()` equals restart.
- cordis: `fiber.await()`, `fiber.restart()`, `fiber.inertia`.
- cordis: `fiber.name` inheritance and `'root'` default.
- cordis: `ctx.effect(execute, label)` registration before setup, label metadata, `getEffects()`.
- cordis: effect collection adopts returned or yielded nested effects as children.
- cordis: effect rollback on synchronous and asynchronous setup failure.
- cordis: effect disposer single-shot; synchronous result for synchronous cleanup.
- cordis: re-entrant disposal during setup waits for setup.
- cordis: in-flight cleanup stays owner-visible and is joined by owner unload.
- cordis: `await effect` yields a plain disposer.
- cordis: effect creation rejected while `UNLOADING`, allowed while `PENDING` and `LOADING`.
- cordis: `ctx.on` with `prepend` and `global`; label format; symbol names.
- cordis: `ctx.once`.
- cordis: `internal/listener` bail hook; fiber-local `internal/update` listeners.
- cordis: dispatch receiver detection and `Context.filter` filtering.
- cordis: `internal/dispatch` for non-internal events.
- cordis: `emit`, `parallel` (`AggregateError`), `serial`, `bail`, `waterfall` (`next()` guard).
- cordis: snapshot dispatch semantics.
- cordis: `events.dispatch(type, args)` callback enumeration.
- cordis: `internal/service` scoped emission.
- cordis: `internal/config` waterfall with kernel schema validation outermost.
- cordis: Standard Schema synchronous validation; `ValidationError` message format.
- cordis: `fiber.resolveConfig` purity; `rawConfig`; `effectiveConfig`.
- cordis: `fiber.update(config, noSave)` with `internal/commit`, `internal/update`, publication guard.
- cordis: update coalescing during load; pending-fiber raw retention.
- cordis: `Service` constructor: default name from static `provide`, tracker, provide with `check`.
- cordis: `Service.invoke` callable services.
- cordis: `Service.extend` derived instances.
- cordis: `Service.resolveConfig(base, head)` intercept merge order and `Config.merge`.
- cordis: `Service` scope filter and cross-copy `instanceof`.
- cordis: `ctx.logger(name?)` and level shortcuts; default name from `hyphenate(fiber.name)`.
- cordis: logger intercept `{name, level}`.
- cordis: logger exporters as effects; per-exporter `levels` thresholds.
- cordis: logger buffer of 1000 messages; `sn`/`ts` fields.
- cordis: logger `cause` and aggregate error expansion.
- cordis: `Logger.format` placeholders and line truncation; `Logger.color`; `Logger.code`.
- cordis: `DisposableList` push, delete, clear-reversed, ordered iteration.
- cordis: error texts and effect labels exactly as listed under Formats.
- cordis: `bin.js` launcher behavior (tutorial only).
- cosmokit: `defineProperty`, `isNullable`, `isNonNullable`, `noop`, `isPlainObject`.
- cosmokit: `remove`, `makeArray`, `deduplicate`, `union`, `intersection`, `difference`, `contain`.
- cosmokit: `pick`, `omit`, `mapValues`/`valueMap`, `filterKeys`.
- cosmokit: `hyphenate`/`paramCase`, `camelCase`/`camelize`, `snakeCase`, `capitalize`, `uncapitalize`.
- cosmokit: `formatProperty`, `trimSlash`, `sanitize`.
- cosmokit: `deepEqual(a, b, strict?)` with volatile, URL, hole, cycle, and strict-identity rules.
- cosmokit: `clone` with prototypes and cycles.
- cosmokit: `createVolatile`, `isVolatile`, `volatileEntries`, `updateVolatile` and their rejection errors.
- cosmokit: `is`, `Binary` base64 and hex helpers.
- cosmokit: `Time` constants, `parseTime`, `parseDate`, `format`, `template`, date numbers.
