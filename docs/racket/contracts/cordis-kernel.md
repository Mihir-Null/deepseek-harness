# Interface contract: the `cordis` kernel package

This is the binding interface for `racket/cordis/`. The implementation, its independent test suite and every harness package are written against this document. Rationale is in [cordis-analysis.md](../cordis-analysis.md) and ADRs 0002 to 0005. When this document and the vendored TypeScript disagree about *behaviour* of a Cordis concept, the TypeScript (`vendor/cordis/src`) is right and this document gets fixed; when they disagree about *surface* (names, argument order), this document is right.

Package: directory `racket/cordis/`, single collection `cordis`, `info.rkt` with `(define collection "cordis")`, `(define deps '("base"))`, `(define build-deps '("rackunit-lib"))`. Language: `racket/base` plus `racket/contract`, `racket/match`, `racket/generator`, `racket/list` as needed. No third-party packages.

## 1. Modules

| Module | Provides |
|---|---|
| `cordis` (`main.rkt`) | everything in sections 2 to 8 |
| `cordis/task` | section 2 only (usable without a context) |
| `cordis/plugin` | `define-plugin`, plugin struct API (also a module language, section 9) |
| `cordis/service` | `define-service` |
| `cordis/event` | `define-event` |
| `cordis/unit` | `unit->plugin` |
| `cordis/testing` | helpers for tests of code built on the kernel (section 10) |

Internal modules live under `private/`. Every public function has a contract through `contract-out` unless noted.

## 2. Tasks (`cordis/task`)

A *scheduler* owns one baton. A *task* is a Racket thread that runs only while it holds the baton.

```racket
(make-scheduler #:name [name 'cordis] #:custodian [cust (current-custodian)]) -> scheduler?
(scheduler? v) -> boolean?
(scheduler-shutdown! s) -> void?            ; kills the manager; pending tasks never run
(current-scheduler) -> (or/c scheduler? #f) ; parameter

(spawn-task thunk #:name [name #f] #:scheduler [s (current-scheduler)]) -> task?
(task? v) -> boolean?                        ; a task is an evt: ready when finished, sync value is the task
(task-done? t) -> boolean?
(task-result t) -> any                       ; values of the thunk, or re-raises its exception; awaits if unfinished
(task-thread t) -> thread?
(task-cancel! t) -> void?                    ; break-thread
(task-kill! t) -> void?                      ; kill-thread; task-result then raises exn:fail:cordis:task-killed
(in-task? [s (current-scheduler)]) -> boolean?

(await x) -> any
(await/timeout secs x [on-timeout (lambda () #f)]) -> any
(await-all xs) -> list?                      ; results in order; raises the first exception after all settle
(yield-task) -> void?                        ; go to the back of the queue
(task-sleep secs) -> void?
(blocking thunk) -> any                      ; run thunk on a plain thread outside the baton, await it
(call-in-kernel thunk #:scheduler [s (current-scheduler)]) -> any
```

Rules:

1. At most one task per scheduler runs at any time. A running task is never descheduled in favour of another task of the same scheduler except inside `await`, `await-all`, `yield-task`, `task-sleep`, `blocking`, `task-result` on an unfinished task, or by finishing.
2. Tasks start in spawn order: `spawn-task` enqueues the new task's baton request *before it returns*, in the spawner's thread. Tasks waiting to resume after an `await` queue behind tasks already waiting, in the order their events became ready.
3. `(await x)`: if `x` is a task, wait for it and return `(task-result x)`; if `x` is a fiber, behave as `fiber-await`; otherwise `x` must be an `evt` and the result is its synchronization result. While waiting the baton is released. `await` returns, or raises, only after the baton is reacquired.
4. A break delivered to a task while it waits in `await` is raised as `exn:break` from `await` after the baton is reacquired. A break delivered while the task runs is raised at the next point where breaks are enabled, as usual.
5. `await` outside a task (`(in-task?)` is `#f`) degrades to plain `sync` semantics with the same task and fiber cases; it never touches the baton.
6. `blocking` propagates the thunk's values or exception. If the awaiting task is broken, the helper thread is broken too and then killed if it has not finished within 1 second.
7. `call-in-kernel` from a non-task thread spawns a task for the thunk, waits with `sync`, and returns `task-result`; from inside a task of the same scheduler it just calls the thunk.
8. Kill safety: if the baton holder's thread dies, the baton is released. Dead waiters are skipped. Killing any task never prevents other tasks from running.
9. The manager thread runs under the scheduler's custodian. Task threads are created under the `current-custodian` of the spawner, and inherit its parameterization (so `current-scheduler`, `current-context`, `current-custodian` carry over).
10. An exception that escapes a task's thunk is stored in the task and re-raised by `task-result` / `await`. If nothing ever observes it, it is logged at `error` level on the `cordis` logger when the task is garbage collected or at scheduler shutdown; an implementation may log eagerly at `debug`.
11. Holding the baton longer than `(current-baton-warn-ms)` (parameter, default 2000, `#f` disables) between two release points logs a `warning` on the `cordis` logger naming the task.

## 3. Contexts

```racket
(make-root-context #:name [name 'root]
                   #:scheduler [s #f]             ; created if #f
                   #:custodian [c (current-custodian)]) -> context?
(context? v) -> boolean?
(context-root ctx) -> context?
(context-parent ctx) -> (or/c context? #f)        ; the context this one was derived from
(context-fiber ctx) -> fiber?
(context-scheduler ctx) -> scheduler?
(context-custodian ctx) -> custodian?             ; the owning fiber's current custodian
(root-context? ctx) -> boolean?
(context-isolate ctx key [realm (make-realm key)]) -> context?
(context-intercept ctx key config) -> context?
(context-realm ctx key) -> (or/c symbol? #f)
(context-intercepts ctx key) -> list?             ; outermost first
(context-extend ctx meta) -> context?             ; meta : (hash/c symbol? any/c); shadows earlier meta
(context-meta ctx key [default #f]) -> any/c
(make-realm key) -> symbol?                       ; uninterned
(current-context) -> (or/c context? #f)           ; parameter
(call-with-context ctx thunk) -> any
(context-dispose! root) -> void?                  ; unload every child fiber and root effect, wait for quiescence
(context-shutdown! root) -> void?                 ; context-dispose!, then shut down scheduler and kernel custodian
```

- Contexts are immutable values. Derivation shares structure. Two contexts are the same scope when `eq?`.
- Loader support (module `cordis/private/loader-support`, not re-exported from `cordis`): `(context-derive/rebindable ctx) -> context?` returns a child whose parent link, realm table and intercept table live in a mutable cell, with `(context-rebind! c #:parent [p] #:realms [r] #:intercepts [i]) -> void?` and `(context-own-realms c)`, `(context-own-intercepts c)`. Lookups on such a context and on every context derived from it read through the cell, so the loader can re-parent an entry or change its isolation without recreating its fiber, which is what `Object.setPrototypeOf(entry.ctx, parent.ctx)` does in the TypeScript loader. After a rebind the loader is responsible for calling `(ctx-notify! ctx keys)` (also exported there) for the affected names.
- The root context owns: the service store, the property table, the listener table, the runtime registry, counters, the scheduler, a kernel custodian (child of `#:custodian`) and the root fiber. The root fiber is `'active`, has uid `0`, no plugin, and an empty inject list.
- Every public kernel operation that mutates state may be called from any thread. When called outside a task it runs through `call-in-kernel` on the root's scheduler. Read-only accessors do not need the baton.
- Keys (service names, event names, meta keys) are symbols. Functions that take a key also accept a string and convert with `string->symbol`.

## 4. Effects

```racket
(ctx-effect ctx thunk #:label [label "anonymous"]) -> disposer?
(effect ctx maybe-label body ...+)                 ; macro; label defaults to "file:line:col"
(disposer? v) -> boolean?                          ; applicable: (d) -> void?
(dispose! d) -> void?                              ; same as (d)
(disposer-label d) -> string?
(disposer-children d) -> (listof disposer?)
(fiber-effects f) -> (listof disposer?)            ; currently owned top-level effects, registration order
```

`thunk` is called with no arguments, with `current-context` set to `ctx` and `current-custodian` set to the owning fiber's custodian. Its result, the *effect result*, is one of:

- `(void)` or `#f`: no inverse;
- a procedure of arity 0 (including a disposer): one inverse;
- a list of effect results: collected in order;
- a generator (from `racket/generator`): resumed until done; each yielded value and the final return value are effect results;
- a task or other `evt`: awaited; its result is an effect result. Setup is then *asynchronous*: `ctx-effect` returns the disposer immediately without waiting.

Anything else raises `exn:fail:contract` ("invalid effect").

Semantics, all from `vendor/cordis/src/fiber.ts`:

1. `ctx-effect` raises `exn:fail:cordis:inactive` if the owning fiber is disposed or in state `'unloading`. Message: `cannot create effect on inactive context`.
2. The disposer is registered with the owning fiber before `thunk` runs.
3. Calling the disposer runs the collected inverses in reverse order, one after another, waiting for each to return. Inverses may `await`. An inverse that raises is logged at `error` on the `cordis` logger (with the effect label) and the remaining inverses still run; the disposer call then re-raises the first such exception.
4. The disposer is single-shot. A second call, including a concurrent one from another task, waits for the first to finish and returns `(void)` without running anything again.
5. Disposing while asynchronous setup is in flight waits for setup to settle, then reverts.
6. If `thunk` raises synchronously, inverses collected so far are run, the disposer is removed from the fiber, and the exception propagates from `ctx-effect`. If asynchronous setup raises, the same rollback happens and the error is logged; awaiting the disposer (rule 8) raises it.
7. An effect created while another effect's thunk is running on the same fiber, and whose disposer is returned or yielded to that outer effect, becomes a child of the outer effect: it is removed from the fiber's top-level list and disposed as part of the outer effect.
8. A disposer is an `evt`, ready when setup has settled. `(await d)` returns the disposer or raises the setup error.
9. Generators are resumed step by step. Before each resume the kernel checks the guard: for `ctx-effect`, that the disposer has not been called; for a plugin body (section 6), that the fiber's target is unchanged. A tripped guard stops iteration; inverses collected so far remain.
10. After a fiber unloads there are no owned effects left.

## 5. Services

```racket
(ctx-provide ctx key [value (void)] #:check [check #f]) -> disposer?
(ctx-get ctx key #:strict? [strict? #t] #:default [default #f]) -> any/c
(ctx-set! ctx key value) -> void?
(ctx-ref ctx key) -> any/c
(ctx-has? ctx key) -> boolean?                      ; a provider exists in ctx's realm, any state
(ctx-accessor ctx name #:get getter #:set [setter #f]) -> disposer?
(ctx-mixin ctx source names) -> disposer?           ; names : (listof symbol?) or (hash/c symbol? symbol?)
(service-resolve-config ctx key #:base [base #f] #:head [head #f] #:merge [merge default-merge]) -> any/c

(struct service-handle (ctx key))                   ; a capability: a service as seen from one context
(use-context x) -> context?                         ; x : context? or service-handle?
(service-value x key) -> any/c                      ; (ctx-ref (use-context x) key); if x is a handle its key must equal key
```

**Ownership convention (ADR 0003).** Every service procedure in the harness takes a context or a service handle as its first argument, obtains the context with `use-context`, the service value with `service-value` (or the accessor generated by `define-service`), and registers effects on that context. No kernel or harness procedure consults `current-context` to decide ownership.

- `ctx-provide` is an effect labelled `ctx.provide("key")`. It assigns `key` a root realm on first use, creates an impl `(uid key value ctx check realm dependents)` with a fresh increasing uid in the realm `key` has in `ctx`, and raises `exn:fail:cordis:service` `service "key" has been registered at <fiber-name>` if that realm is occupied. If the providing fiber is `'active` it notifies. Its inverse removes the impl from the store (if still the current one), notifies, waits until the impl has no dependents, and then removes it from the fiber's provisions.
- **Notify** for names `ks` from context `c`: for every live plugin fiber that injects one of `ks` and whose context maps that name to the same realm as `c`, re-check the name and refresh the fiber (section 6); then emit `'internal/service` with `(name value)` to listeners whose registering context maps the name to the same realm (value read non-strictly, `#f` if absent).
- `ctx-get`: realm lookup then store lookup. Returns `default` when there is no impl, or when `strict?` and the provider's fiber is not `'active`. Never raises.
- `ctx-set!`: replaces the impl's value in place. Raises `exn:fail:cordis:service` `cannot set property "key" without provide` when there is no impl, and `cannot set property "key" in multiple fibers` when called from a different fiber than the provider's. No notification.
- `ctx-ref` is the checked read (paper Algorithm 6):
  1. If `key` has an accessor, call its getter with `ctx`.
  2. If `ctx`'s fiber is the root fiber: return `(ctx-get ctx key #:strict? #f)`; if absent raise as in step 4.
  3. Otherwise run the `'internal/get` waterfall `(ctx key next)` whose innermost step walks from `ctx`'s fiber upward. At each fiber `f`: if `f`'s committed view has `key`, or `f` itself has a provision named `key` in the realm that `key` has in `ctx`, return that value. If `key` is in `f`'s inject list (and was not committed) raise `exn:fail:cordis:inject` `cannot get required service "key" in inactive context`. If `f` is the root, or `f`'s parent context maps `key` to a different realm than `ctx` does, raise as in step 4. Otherwise continue with the parent's fiber.
  4. `exn:fail:cordis:inject` `cannot get property "key" without inject`.
- `#:check` is `(-> context? any/c)`, called with the *dependent's* context when a dependent's target is computed; a false result or an exception (logged) makes the service count as absent for that dependent.
- `ctx-accessor` and `ctx-mixin` are effects. A name can be a service or an accessor, not both: `property "name" is already declared as service|accessor`. `ctx-mixin` with source `'timer` and names `'(set-timeout)` makes `(ctx-ref ctx 'set-timeout)` return the member of the service: for a hash-valued service the value at that key; otherwise the result of `((current-mixin-resolver) service-value name)`.
- `service-resolve-config` merges, in order: `base`, the interception layers for `key` from outermost to innermost, `head`. `default-merge` merges hashes right-biased and otherwise takes the last non-`#f` value.

## 6. Plugins and fibers

```racket
(struct plugin (name inject config-schema provides apply meta))   ; opaque; use the accessors
(make-plugin apply
             #:name [name #f]
             #:inject [inject '()]        ; (listof key) or (hash/c key intercept-config)
             #:config [schema #f]         ; see "config schemas"
             #:provides [provides '()]
             #:custodian [mode 'own]      ; 'own or 'inherit
             #:meta [meta (hasheq)]) -> plugin?
(plugin? v) (plugin-name p) (plugin-inject p) (plugin-config-schema p) (plugin-provides p) (plugin-meta p)

(ctx-plugin ctx p [config #f]) -> fiber?      ; p : plugin? or (-> context? any/c any)
(ctx-inject ctx keys proc) -> fiber?          ; proc : (-> context? any); a nameless plugin with that inject list

(fiber? v)
(fiber-state f) -> (or/c 'pending 'loading 'active 'unloading 'failed 'disposed)
(fiber-uid f) -> (or/c exact-nonnegative-integer? #f)    ; #f once disposed
(fiber-name f) -> string?                     ; nearest named plugin up the chain, else "root"
(fiber-plugin f) -> (or/c plugin? #f)
(fiber-context f) -> context?                 ; the fiber's own context
(fiber-parent f) -> (or/c context? #f)        ; the context it was created on
(fiber-inject f) -> (hash/c symbol? any/c)    ; name -> intercept config or #f
(fiber-committed f) -> (or/c (hash/c symbol? any/c) #f)  ; name -> service value while loaded
(fiber-provisions f) -> (listof symbol?)
(fiber-config f) -> any/c                     ; raw config
(fiber-effective-config f) -> any/c           ; validated config of the current activation
(fiber-error f) -> (or/c exn? any/c #f)
(fiber-custodian f) -> custodian?
(fiber-await f) -> fiber?                     ; waits until no transition is in flight; raises the recorded error if 'failed
(fiber-dispose! f) -> void?                   ; waits for unload
(fiber-restart! f) -> void?
(fiber-update! f config #:save? [save? #t]) -> void?
(ctx-fibers ctx) -> (listof fiber?)           ; every live plugin fiber under the root, creation order
```

A fiber is an `evt`, ready when it has no transition in flight; its synchronization result is the fiber.

**Plugin body.** `apply` is called as `(apply ctx config)` with `ctx` the fiber's context, `config` the validated config, `current-context` set to `ctx`, and `current-custodian` set to the fiber's custodian. Its result is an effect result (section 4) owned by the fiber. It runs in the fiber's reload task, so it may `await`; the fiber stays `'loading` until it returns and every asynchronous effect result it returned has settled.

**Lifecycle.** Implement `vendor/cordis/src/fiber.ts` (`_refresh`, `_setEpoch`, `_reload`, `_unload`, `_checkImpl`, `_updateState`, `update`, `restart`, the disposer in the constructor) on tasks. In particular:

1. `ctx-plugin` raises `exn:fail:cordis:inactive` if `ctx`'s fiber is disposed. It creates the fiber as an effect of the parent fiber labelled `ctx.plugin()`, emits `'internal/plugin` with the fiber (state `'pending`), then checks each injected name and refreshes. It returns without waiting for activation. The plugin body never runs inside the `ctx-plugin` call: reload is a separate task, so code after `ctx-plugin` in the same task runs first.
2. The target is `#f` (inactive) or `(list revision provider-uid ...)` in inject order. `refresh` recomputes it; if it changed, the fiber has no recorded error, and no transition is in flight, start a reload task (state `'loading`) when the old target was `#f`, otherwise an unload task (state `'unloading`).
3. Reload: commit the resolved providers; register as a dependent of each provider not owned by this fiber; create a fresh custodian for this activation unless the plugin's custodian mode is `'inherit`; yield once; if the target is unchanged, validate the config through the `'internal/config` waterfall and run the body. On an exception: log it, and if the target is unchanged record it as the fiber's error and set the target to `#f`. Afterwards, if the target is unchanged the transition ends (state `'active`, or `'failed` when an error is recorded), otherwise chain into unload.
4. Unload: wait until none of this fiber's provisions has dependents; dispose every owned effect, started in reverse registration order, each in its own task, and wait for all, logging failures; shut down the activation's custodian (mode `'own`); remove this fiber from the dependents of its committed providers and wake any provider waiting on that; clear the committed view. Then, if the target is `#f` the transition ends (state `'pending`, or `'disposed` when the fiber was disposed), otherwise chain into reload.
5. Any state change emits `'internal/status` `(fiber old-state)`. A change into or out of `'active` notifies for every name the fiber provides.
6. `fiber-dispose!`: clear the uid, emit `'internal/plugin` (each listener's failure is logged and does not stop the others), detach from the registry, set the target to `#f`, unload effects registered while still pending, wait for quiescence. Disposing a parent disposes its children because each child is an effect of the parent.
7. `fiber-restart!` increments the revision, refreshes and waits. `fiber-update!` validates the candidate through `'internal/config` when the fiber is loaded, emits `'internal/commit` `(fiber raw-config)` unless `save?` is `#f`, stores the raw config, clears a recorded error, and runs the `'internal/update` waterfall `(fiber resolved-config next)` whose innermost step restarts; when the fiber is not loaded it restarts directly. A listener that returns without calling `next` keeps the instance; the effective config is then updated only if no restart or newer update intervened.
8. `(ctx-on ctx 'internal/update listener)` without `#:global? #t` registers on `ctx`'s fiber only: it sees updates of that fiber alone.
9. A failed fiber recovers only through `fiber-update!`.

**Config schemas.** `config-schema` is `#f`, or a procedure `(-> any/c any/c)` that returns the validated value or raises, or a value with the struct property `prop:config-schema` whose value is such a procedure taking `(schema raw)`. Validation failures raise `exn:fail:cordis:validation` with an `issues` field, a list of `(cons path-list message)`; its message is `invalid config:` followed by one line per issue, `  - message (at a.b.c)`.

## 7. Events

```racket
(ctx-on ctx name listener #:prepend? [prepend? #f] #:global? [global? #f]) -> disposer?
(ctx-once ctx name listener #:prepend? [prepend? #f] #:global? [global? #f]) -> disposer?
(ctx-emit ctx name arg ...) -> void?
(ctx-parallel ctx name arg ...) -> void?
(ctx-serial ctx name arg ...) -> any/c
(ctx-bail ctx name arg ...) -> any/c
(ctx-waterfall ctx name arg ... inner) -> any       ; inner : (-> any)
(ctx-dispatch ctx mode name args #:filter [filter #f] #:inner [inner #f]) -> any
(ctx-listeners ctx name) -> (listof procedure?)
(bailed? v) -> boolean?                              ; not #f, (void) or 'null
```

- `ctx-on` is an effect labelled `ctx.on("name")`. It first offers `(ctx name listener options)` to `'internal/listener` through `bail`, where `options` is a hash with `'prepend` and `'global`; a bailed result is returned instead of registering. Listeners are kept in registration order, `prepend?` ones in front.
- A listener is called with the dispatch arguments, with `current-context` set to the registering context (for diagnostics only).
- `emit`: call each listener in order in the calling task. A listener's exception propagates to the dispatcher and stops delivery, as in Cordis.
- `parallel`: run every listener as its own task, wait for all, and if any raised, raise `exn:fail:cordis:aggregate` whose `errors` field lists them.
- `serial` and `bail`: call in order, return the first result for which `bailed?` holds, else `(void)`. In Racket both may `await`; they differ only in name, kept for fidelity with declared event modes.
- `waterfall`: listener `i` is called with `arg ... next`; `(next)` runs the rest of the chain ending in `(inner)` and returns its result. A second call to the same `next` raises `exn:fail:cordis` `next() called multiple times`.
- `#:filter` is `(-> context? any/c)`, applied to each listener's registering context; listeners registered with `#:global? #t` bypass it.
- Before a non-internal dispatch, if `'internal/dispatch` has listeners, emit `(mode name args)` to them.
- The listener list used by a dispatch is the list at the time the dispatch starts.

Internal events and their modes: `'internal/plugin` emit `(fiber)`; `'internal/status` emit `(fiber old-state)`; `'internal/service` emit `(name value)`; `'internal/commit` emit `(fiber raw-config)`; `'internal/config` waterfall `(fiber next)`; `'internal/update` waterfall `(fiber resolved-config next)`; `'internal/get` waterfall `(ctx name next)`; `'internal/set` waterfall `(ctx name value next)`; `'internal/listener` bail `(ctx name listener options)`; `'internal/dispatch` emit `(mode name args)`.

## 8. Errors and logging

```racket
(struct exn:fail:cordis exn:fail ())
(struct exn:fail:cordis:inactive exn:fail:cordis ())
(struct exn:fail:cordis:inject exn:fail:cordis (key))
(struct exn:fail:cordis:service exn:fail:cordis (key))
(struct exn:fail:cordis:validation exn:fail:cordis (issues))
(struct exn:fail:cordis:aggregate exn:fail:cordis (errors))
(struct exn:fail:cordis:task-killed exn:fail:cordis ())
(ctx-logger ctx [topic #f]) -> logger?          ; child of the 'cordis logger, named after the fiber
(log-ctx level ctx fmt arg ...)                 ; macro; level is debug|info|warning|error|fatal
cordis-logger                                   ; the root logger, topic 'cordis
```

Errors that Cordis reports through `ctx.logger.error` are logged at `error` on the `cordis` logger with the exception as the log event's data.

## 9. Declaration macros and the plugin language

All use `syntax/parse` with messages that name the offending clause.

```racket
(define-plugin id
  (~alt (~optional (~seq #:name name-expr))          ; string; defaults to the symbol name of id
        (~optional (~seq #:inject (inject-clause ...)))
        (~optional (~seq #:config schema-expr))
        (~optional (~seq #:provides (key-id ...)))
        (~optional (~seq #:custodian mode))
        (~optional (~seq #:meta meta-expr))) ...
  body)
;; inject-clause = key-id | [key-id #:optional] | [key-id #:as local-id] | [key-id #:intercept expr]
;; body = (lambda (ctx-id config-id) e ...+)  |  #:apply apply-expr  |  (ctx-id config-id) e ...+
```

- Defines `id` as a `plugin?`.
- In the `lambda` and `(ctx-id config-id) e ...` body forms, each required injected key is bound as a variable holding `(service-handle ctx 'key)`. An `#:optional` key is not part of the inject list; its identifier is a macro that expands to `(ctx-get ctx 'key)` at each use (the raw value or `#f`).
- Duplicate keys, unknown keywords and a non-lambda body without `#:apply` are syntax errors with specific messages.
- `(plugin-info p)` returns a hash with `'name`, `'inject`, `'optional`, `'provides`, `'config-schema`.

```racket
(define-service id maybe-key
  (~optional (~seq #:contract contract-expr))
  (~optional (~seq #:doc string)))
```

Defines: `id-key` (the symbol), `(id-ref x)` checked read where `x` is a context or a handle for this key, `(id-get ctx)` optional read, and `(provide-id ctx value #:check [check #f])`, which applies the contract with the calling module as the positive party.

```racket
(define-event id name-expr
  #:mode (~or emit parallel serial bail waterfall)
  (~optional (~seq #:args (arg-contract ...)))
  (~optional (~seq #:result result-contract)))
```

Defines: `id-name` (the symbol), `(on-id ctx listener #:prepend? [p #f])`, and exactly one dispatcher `(dispatch-id ctx arg ...)` (for waterfall, `(dispatch-id ctx arg ... inner)`), which applies the argument contracts. There is no way to dispatch `id` in another mode through these bindings.

**`#lang cordis/plugin`.** A module in this language is a plugin. Its body starts with the same keyword options as `define-plugin`, followed by definitions and expressions that form the plugin body; `ctx` and `config` are bound in the body. The module provides `plugin` (the `plugin?` value) and has a submodule `plugin-info` providing `info`, a hash with `'name`, `'inject`, `'optional`, `'provides` and `'source`, which can be required without instantiating the enclosing module's body. The body language is `racket/base` plus the `cordis` API.

`(unit->plugin unit-expr #:imports (key ...) #:exports (key ...))` adapts a unit whose imported and exported signatures each have one value named after a service key.

## 10. `cordis/testing`

```racket
(call-with-root-context proc #:timeout [secs 10]) -> any   ; makes a root, runs (proc ctx) as a task, shuts down; raises on timeout
(with-root-context (ctx) body ...)                          ; macro over the above
(kernel-snapshot root) -> hash?                             ; stable summary: services by realm name, listener counts by event, accessor names, live fiber names
(check-kernel-restored thunk root)                          ; snapshot, run thunk, wait for quiescence, check snapshot unchanged
(capture-log proc #:level [level 'error] #:topic [topic 'cordis]) -> (values any/c (listof vector?))
(wait-for pred #:timeout [secs 5]) -> any/c                 ; polls with task-sleep/yield until pred returns true
```

## 11. Required tests

The package's own suite (`racket/cordis/tests/`) must cover every numbered rule in sections 2 and 4 to 7 and the fifteen laws in section 7 of the analysis, and must pass under `raco test racket/cordis`. Tests must not depend on wall-clock ordering; use events, not sleeps, to sequence tasks.
