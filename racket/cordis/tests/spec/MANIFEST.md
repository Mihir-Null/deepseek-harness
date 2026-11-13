# Kernel specification suite: manifest

This directory holds an independent black-box test suite for the `cordis` kernel package. It was written from the interface contract ([docs/racket/contracts/cordis-kernel.md](../../../../docs/racket/contracts/cordis-kernel.md)), the vendored TypeScript kernel (`vendor/cordis/src`), the kernel reconnaissance note ([docs/racket/recon/01-cordis-core.md](../../../../docs/racket/recon/01-cordis-core.md)) and the paper digest ([docs/racket/recon/19-paper-digest.md](../../../../docs/racket/recon/19-paper-digest.md)), without reading the implementation. It uses only the public modules `cordis`, `cordis/task`, `cordis/plugin` and `cordis/testing`.

Run it with `raco make racket/cordis/tests/spec/*.rkt` followed by `raco test racket/cordis/tests/spec`. The suite has 215 test cases in nine files; `support.rkt` holds shared helpers and has no test case.

The suite was written without running it against the implementation. Each file was checked to read as well-formed syntax and to compile without unbound identifiers against a compile-only stand-in that exports the names of contract sections 2 to 8 and 10 and nothing else.

The suite follows the contract as of its section 12 addenda: cooperative breaks and `task-check-break` (addendum 1), `ctx-dispatch-callbacks` (addendum 2), inheritance through fibers (addendum 3) and `call-contained` (addendum 4).

## How the suite sequences and bounds its tests

- No test outcome depends on how long anything takes. Tasks are sequenced with gates (semaphores), `await`, `yield-task` and task results.
- Every wait is bounded. Kernel tests run inside `with-root`, which is `call-with-root-context` with `#:timeout 30`; task tests wait with `sync/timeout`. A timeout is a failure bound only.
- A check that runs inside a plugin body, a listener or an inverse would be swallowed by kernel containment, so those places record observations and the test body checks the record.
- A TypeScript call that returns a promise (`update`, `restart`, `dispose`, a disposer with an asynchronous inverse) blocks its caller in the Racket contract. A test that needs such a call in flight runs it in its own task.
- Names that the contract mentions only in prose (`current-baton-warn-ms`, `current-mixin-resolver`, `default-merge`, `raise-validation-error`, `plugin-info`) and names that section 12 added after the first implementation started (`task-check-break`, `ctx-dispatch-callbacks`, `call-contained`) are looked up with `dynamic-require`, so that a missing export fails one test case instead of one file.
- A task that a test starts from a plugin body, an effect thunk or a listener, and that must outlive the unload it waits for, is spawned through `make-spawner` under the custodian of the test body. Contract section 2 rule 9 and ADR 0004 put such a task under the activation custodian of the fiber whose code is running, and the unload shuts that custodian down.

## Property tests and the seed

`schedules-spec-test.rkt` runs 200 schedules for each of laws 18 to 21 and 36 to 39. Each schedule draws from its own `make-pseudo-random-generator`, seeded from the base seed, the law number and the schedule index. The base seed is the environment variable `CORDIS_TEST_SEED`, or `20261113` when it is unset. A failure message names the law, the schedule index and the base seed, for example `law 37, schedule 12 of 200: ... (rerun with CORDIS_TEST_SEED=20261113)`.

Laws 21 and 36 to 39 run over random acyclic graphs of four to six plugin specs and three or four service keys. Specs are ranked; a spec injects only keys whose provider has a lower rank (or, rarely, a key nobody provides), a child spec is mounted by the body of a lower-ranked top-level spec, and a key has at most one provider. The schedule applies random inserts, disposals, dispose-and-reinsert replacements, config updates and restarts to top-level specs, with random yields in the driver and inside plugin bodies and inverses. Every plugin body also checks law 22 (each injected key has an active provider when the body starts), and every inverse checks law 23 (no provider of an injected key has started its own inverse) and law 24 (each injected key is still readable), when the inverse begins and when it ends.

## Where each requirement is covered

| Requirement | File |
|---|---|
| Contract section 2, rules 1 to 11, and section 12 addendum 1 | `task-spec-test.rkt` |
| Contract section 4, effect results and rules 1 to 10 | `effect-spec-test.rkt` |
| Contract section 5, every bullet and `ctx-ref` steps 1 to 4 | `service-spec-test.rkt` |
| Contract section 6, rules 1 to 9 and config schemas | `fiber-spec-test.rkt` |
| Contract section 7, every bullet, and section 12 addenda 2 and 4 | `events-spec-test.rkt` |
| Contract section 3, root context and thread rules, and section 12 addendum 3 (not required) | `fiber-spec-test.rkt` |
| TypeScript spec cases 1 to 23 | `lifecycle-spec-test.rkt` (1 to 3, 5 to 7, 14 to 19, 21 to 23), `service-spec-test.rkt` (4), `events-spec-test.rkt` (8), `effect-spec-test.rkt` (9 to 13) |
| Supplementary cases S1 to S30 | named in the test case titles and sources below |
| Laws 1 to 17 and 22 to 35 | `laws-spec-test.rkt`, except laws 2, 3, 6 and 9 in `effect-spec-test.rkt` |
| Laws 18 to 21 and 36 to 39 | `schedules-spec-test.rkt` |
| Contract section 9, `define-plugin` (not required) | `plugin-spec-test.rkt` |

In the tables below, "contract N" is a section of the kernel contract, "recon 01" is the kernel reconnaissance note, "recon case N" and "SN" are its numbered and supplementary cases under "Tests worth porting", "digest law N" is a law of the paper digest, and "analysis law N" is a law of section 7 of the Cordis analysis.

## Test cases and their sources

### `task-spec-test.rkt` (29 cases)

| Test case | Source |
|---|---|
| task/surface: scheduler values and the current-scheduler parameter | contract 2, surface of make-scheduler / scheduler? / current-scheduler |
| task/surface: a task is an evt whose sync value is the task | contract 2, comments on task?, task-done?, task-result, task-thread |
| task rule 1: at most one task runs; no descheduling between release points | contract 2 rule 1 |
| task rule 2: tasks start in spawn order and never inside spawn-task | contract 2 rule 2, first sentence |
| task rule 2: spawn order holds when a non-task thread spawns behind a holder | contract 2 rule 2, first sentence (spawner is a plain thread) |
| task rule 2: a task resuming from await queues behind tasks already waiting | contract 2 rule 2, second sentence |
| task rule 3: await returns task results and evt sync results | contract 2 rule 3 (task and evt cases; the fiber case is in fiber-spec-test.rkt) |
| task rule 3: await releases the baton and returns holding it | contract 2 rule 3, "while waiting the baton is released" and "returns only after the baton is reacquired" |
| task rule 4: a break during await is raised from await under the baton | contract 2 rule 4, first sentence |
| task rule 4: a break while the task runs stays pending until the next release point | contract 2 rule 4, "Breaks are disabled while a task holds the baton" and "stays pending and is raised at its next release point"; contract 12 addendum 1 |
| task rule 4: task-check-break raises a pending break and never releases the baton | contract 2, signature of task-check-break; rule 4, last sentence; rule 1 (not a release point); contract 12 addendum 1 |
| task rule 4: a task without a release point is stopped by task-kill! only | contract 2 rule 4, "A task that never reaches a release point can only be stopped with task-kill!" |
| task rule 5: await outside a task is plain sync | contract 2 rule 5 |
| task rule 5: await outside a task does not wait for the baton | contract 2 rule 5, "it never touches the baton" |
| task rule 6: blocking runs outside the baton and propagates values and exceptions | contract 2 rule 6, first sentence |
| task rule 6: breaking the awaiting task breaks the helper thread | contract 2 rule 6, second sentence |
| task rule 6: a helper that ignores the break is killed | contract 2 rule 6, "killed if it has not finished within 1 second" |
| task rule 7: call-in-kernel spawns from a plain thread and calls directly in a task | contract 2 rule 7 |
| task rule 8: killing the baton holder or a waiter never blocks other tasks | contract 2 rule 8; analysis law 15 (kill safety) |
| task rule 8: a task killed during await does not hold the queue | contract 2 rule 8 (a task killed while it waits in await) |
| task rule 9: task threads inherit the spawner's parameterization and custodian | contract 2 rule 9, parameterization and custodian of task threads |
| task rule 9: after scheduler-shutdown! pending tasks never run | contract 2 rule 9, "the manager thread runs under the scheduler's custodian"; contract 2, comment on scheduler-shutdown! |
| task rule 10: an escaped exception is stored and re-raised on each observation | contract 2 rule 10, first sentence; comment on await-all |
| task/await-all: results in order; the exception is raised after all settle | contract 2, comment on await-all |
| task rule 10: an unobserved failure is logged at scheduler shutdown | contract 2 rule 10, "logged at error level ... at scheduler shutdown" |
| task rule 11: holding the baton past current-baton-warn-ms logs a warning | contract 2 rule 11 |
| task/yield-task and task-sleep: both go to the back of the queue | contract 2, comments on yield-task and task-sleep |
| task/await-timeout: returns the result or the on-timeout value | contract 2, signature of await/timeout |
| task/in-task?: true only in a task of the given scheduler | contract 2, signature of in-task? |

### `effect-spec-test.rkt` (34 cases)

| Test case | Source |
|---|---|
| effect/result: void and #f have no inverse | contract 4, effect results "(void) or #f: no inverse"; digest law 5 |
| effect/result: a procedure is one inverse | contract 4, effect results "a procedure of arity 0" |
| effect/result: a list is collected in order, nested lists included | contract 4, effect results "a list of effect results: collected in order" |
| effect/result: a generator's yields and return value are collected | contract 4, effect results "a generator ... each yielded value and the final return value are effect results" |
| effect/result: a task makes setup asynchronous | contract 4, effect results "a task or other evt: awaited ... ctx-effect returns the disposer immediately without waiting" |
| effect/result: a plain evt is awaited and its value is an effect result | contract 4, effect results "a task or other evt" (plain evt case) |
| effect/result: anything else raises exn:fail:contract | contract 4, "Anything else raises exn:fail:contract (invalid effect)"; recon 01 Formats: TypeError "Invalid effect" |
| effect/thunk: runs with current-context and the fiber's custodian | contract 4, "thunk is called ... with current-context set to ctx and current-custodian set to the owning fiber's custodian" |
| effect/surface: labels, dispose! and registration order | contract 4, signatures of dispose!, disposer-label, fiber-effects |
| effect/macro: the effect form wraps its body and labels it by source location | contract 4, "(effect ctx maybe-label body ...+) ; label defaults to file:line:col" |
| effect rule 1: ctx-effect on a disposed fiber raises exn:fail:cordis:inactive | contract 4 rule 1 (disposed fiber); recon 01 S19 |
| effect rule 1: ctx-effect on an unloading fiber raises | contract 4 rule 1 ('unloading fiber); analysis law 5 |
| effect rule 2: the disposer is registered before the thunk runs | contract 4 rule 2 |
| effect rule 3: inverses run in reverse order, one after another, and may await | contract 4 rule 3, first two sentences; digest law 1; analysis law 2 |
| effect rule 3: a raising inverse is logged, the rest run, the first error is re-raised | contract 4 rule 3, last sentence |
| effect rule 4 / case 12: the disposer is single-shot | contract 4 rule 4; digest law 7; analysis law 3; cordis-lifecycle.spec.ts "keeps ordinary teardown synchronous and the public disposer single-shot" (recon case 12) |
| effect rule 4: a concurrent second call waits for the first and runs nothing | contract 4 rule 4, "a concurrent one from another task waits for the first" |
| effect rule 5: disposing during asynchronous setup waits for setup, then reverts | contract 4 rule 5 |
| effect rule 6 / case 10: a synchronous setup failure rolls back | contract 4 rule 6, first sentence; analysis law 4; cordis-lifecycle.spec.ts "rolls back collected cleanup and its owner-list entry when setup throws synchronously" (recon case 10) |
| effect rule 6: an invalid result rolls back what was collected before it | contract 4 rule 6, first sentence (an invalid result after valid ones) |
| effect rule 6: an asynchronous setup failure rolls back, is logged, and fails await | contract 4 rule 6, second sentence; recon 01 S18 |
| effect rule 7: a returned nested effect becomes a child of the outer effect | contract 4 rule 7; digest law 10; recon 01 "ctx.effect" step 2 |
| effect rule 7: nested effects yielded by a generator become children | contract 4 rule 7 (yielded form) |
| effect rule 7: a nested effect that is not returned stays top-level | recon 01 "ctx.effect" step 2, "a nested effect that is merely created inside execute stays a separate top-level effect" |
| effect rule 8: a disposer is an evt that is ready when setup has settled | contract 4 rule 8 |
| effect rule 9: a called disposer stops a generator at the next step boundary | contract 4 rule 9; digest law 8 (ctx-effect guard: the disposer was called) |
| effect rule 10: after a fiber unloads it owns no effects | contract 4 rule 10; digest law 28 |
| case 9: a re-entrant owner restart sees the effect and awaits setup and cleanup | cordis-lifecycle.spec.ts "makes an effect visible to a reentrant owner restart and awaits setup plus cleanup" (recon case 9) |
| case 11: a re-entrant owner restart awaits the rollback of a failed setup | cordis-lifecycle.spec.ts "makes a reentrant owner restart await asynchronous rollback after synchronous setup failure" (recon case 11) |
| case 13: registration inside a cleanup during restart raises INACTIVE_EFFECT | cordis-lifecycle.spec.ts "rejects cleanup-time registration while a restart is unloading" (recon case 13) |
| law 2: an action has the same forward result with and without effect tracking | digest law 2 (tracking does not change forward behaviour) |
| law 3: two sub-effects in one effect equal two nested effect calls | digest law 3 (composition) |
| law 6: an early dispose reverts one effect and the unload does not run it again | digest law 6 (early dispose) |
| law 9: a returned disposer and a generator yielding it behave the same | digest law 9 (a plain effect equals a one-step iterator) |

### `service-spec-test.rkt` (31 cases)

| Test case | Source |
|---|---|
| service/provide: is a labelled effect that installs and withdraws the value | contract 5, "ctx-provide is an effect labelled ctx.provide(\"key\")"; recon 01 Formats, effect labels |
| service/provide: the value defaults to void and still counts as a provider | contract 5, signature "(ctx-provide ctx key [value (void)])" |
| service/provide: the first provide assigns the root realm | contract 5, "assigns key a root realm on first use"; contract 3, context-realm |
| service/provide: a second provider in the same realm raises and keeps the first | contract 5, error bullet `service "key" has been registered at <fiber-name>`; reflect.ts provide; digest law 11; recon 01 S14 |
| service/notify: provide and withdraw re-check dependents and emit internal/service | contract 5, "If the providing fiber is 'active it notifies" and the Notify bullet; digest law 12; recon 01 S26 (late provide notifies at once) |
| service/get: returns the default when absent or, strictly, when not active | contract 5, ctx-get bullet; digest law 13 (absent get); recon 01 S26 |
| service/set: replaces the value in place without notifying | contract 5, ctx-set! bullet (in-place, no notification); digest law 17 second half; recon 01 quirk 8 |
| service/set: raises without a provider and from another fiber | contract 5, error bullets `cannot set property "key" without provide` and `cannot set property "key" in multiple fibers`; recon 01 S14 |
| service/ref step 1: an accessor's getter is called with the reading context | contract 5, ctx-ref step 1; recon 01 S15 (accessor get runs with the reading context) |
| service/ref step 2: a root-fiber context reads unchecked and non-strictly | contract 5, ctx-ref step 2 (root fiber: unchecked, non-strict) and step 4 message |
| service/ref step 3: visibility follows injections and provisions up the fiber chain | contract 5, ctx-ref step 3; reflect.ts handler.get; recon 01 S6 |
| service/ref step 3: a declared but uncommitted injection raises its own error | contract 5, ctx-ref step 3 error `cannot get required service "key" in inactive context`; digest law 13; recon 01 S5 |
| service/ref step 3: the walk stops at an isolation boundary | contract 5, ctx-ref step 3, "f's parent context maps key to a different realm than ctx does"; reflect.ts handler.get |
| service/ref step 3: internal/get wraps reads from plugin contexts only | contract 5, ctx-ref step 3, "run the 'internal/get waterfall (ctx key next)"; contract 7, internal events |
| service/check: a false result hides the service from that dependent | contract 5, #:check bullet; fiber.ts _checkImpl |
| service/check: a raising check is logged and counts as absent | contract 5, #:check bullet, "an exception (logged)" |
| service/check: sees intercept config from the inject map and from context-intercept | recon 01 S22, "check with intercept config from object inject and from ctx.intercept"; contract 6 make-plugin #:inject hash form |
| service/accessor: a name is a service or an accessor, not both | contract 5, accessor bullet `property "name" is already declared as service\|accessor`; recon 01 S15 |
| service/accessor: the accessor disappears with its owning fiber | contract 5, "ctx-accessor and ctx-mixin are effects" |
| service/mixin: list and map forms expose members of a hash-valued service | contract 5, mixin bullet (hash-valued service); recon 01 S16 |
| service/mixin: a non-hash service is resolved through current-mixin-resolver | contract 5, mixin bullet, "otherwise the result of ((current-mixin-resolver) service-value name)" |
| service/resolve-config: merges base, intercept layers outermost first, then head | contract 5, service-resolve-config bullet; service.ts resolveConfig; recon 01 S22 (merge order) |
| service/resolve-config: default-merge is exported and right-biased | contract 5, "default-merge merges hashes right-biased and otherwise takes the last non-#f value" |
| service/intercept: a plugin's inject config is the innermost layer | analysis 3.1 (inject config is the innermost intercept layer); fiber.ts constructor; digest law 16 |
| service/handle: a handle pairs a context with a key | contract 5, service-handle / use-context / service-value; ADR 0003 |
| service/keys: a string key names the same service as its symbol | contract 3, "Functions that take a key also accept a string" |
| service/isolate: realms hold independent bindings and can be joined | contract 3, context-isolate / make-realm; digest law 15; analysis law 11; recon 01 S25 |
| service/isolate: notifications and internal/service stay inside the realm | contract 5, Notify bullet (same realm only); digest law 15; recon 01 S25 (scoped internal/service) and S11 (global listeners) |
| service/visibility: a provision through a pending fiber is hidden until it activates | recon 01 S26, "provide through a PENDING fiber is hidden until it activates"; recon 01 G5 |
| case 4: own isolated provision versus committed injection | scripts/cordis-core-lifecycle.spec.ts "separates own isolated provisions from the committed injection" (recon case 4) |
| S21: an effect registered through a caller's handle belongs to the caller | recon 01 S21 and "Use site and definition site" items 4 and 5, in the form of ADR 0003 |

### `fiber-spec-test.rkt` (39 cases)

| Test case | Source |
|---|---|
| context/root: the root fiber is active, has uid 0, no plugin and no injections | contract 3, root context bullet; recon 01 "Root fiber" |
| plugin/surface: make-plugin records its declaration | contract 6, signatures of make-plugin and the plugin accessors |
| fiber rule 1 / S1: ctx-plugin returns before the body runs; bodies run in start order | contract 6 rule 1; recon 01 G1, G2, S1 |
| fiber rule 1: internal/plugin sees the new fiber pending, owned and unresolved | contract 6 rule 1, "emits 'internal/plugin with the fiber (state 'pending), then checks each injected name and refreshes" |
| fiber/surface: uid, name, plugin, parent, context, config and ctx-fibers | contract 6, fiber accessors; recon 01 S23 (uids, names) |
| fiber rule 1 / S19: a disposed context rejects plugin, effect and listener | contract 6 rule 1 (inactive parent); recon 01 S19 |
| fiber rule 1: a child of a pending parent activates on its own dependencies | recon 01 "Fiber construction", "legal on a PENDING parent; the child then activates on its own dependencies" |
| fiber rule 2: the target follows the providers; pending until all are active | contract 6 rule 2; analysis law 6; recon 01 S5 |
| fiber rule 3: the committed view holds the injected values while loaded | contract 6 rule 3, "commit the resolved providers"; rule 4, "clear the committed view" |
| fiber/body: runs with its context, validated config and the fiber's custodian | contract 6, "Plugin body": arguments, current-context, custodian |
| fiber/body: stays loading until asynchronous effect results settle | contract 6, "Plugin body": "the fiber stays 'loading until it returns and every asynchronous effect result it returned has settled" |
| fiber rule 3 / S4: a failing body is logged, unloads its effects and ends failed | contract 6 rule 3, body failure; rule 9; recon 01 S4 |
| fiber rule 3: a body that raises a non-exception value fails the fiber | contract 6, fiber-error "(or/c exn? any/c #f)"; recon 01 "a thrown non-error value" (the contract keeps the raised value instead of wrapping it) |
| fiber rule 9: a failed fiber is not retried by dependency notifications | contract 6 rule 9; digest law 32 (not retried by notifications) |
| fiber rule 3 / S2: disposing right after ctx-plugin skips the body | contract 6 rule 3, "yield once; if the target is unchanged"; recon 01 G3, S2 |
| fiber rule 3/4: each activation has its own custodian, shut down at unload | contract 6 rule 3, fresh custodian per activation; rule 4, custodian shutdown; ADR 0004; analysis law 14 (custodian backstop) |
| fiber rule 3: custodian mode 'inherit creates no activation custodian | contract 6, make-plugin "#:custodian 'inherit"; rule 3; ADR 0004 |
| fiber rule 4 / S17: unload starts top-level disposers in reverse registration order | contract 6 rule 4, effect disposal order; recon 01 "Disposal order summary" and S17 |
| fiber rule 4: a failing disposer is logged and does not stop the others | contract 6 rule 4, "logging failures"; fiber.ts _unload |
| fiber rule 5 / S3: every state change emits internal/status with the old state | contract 6 rule 5; fiber.ts _updateState; recon 01 "Observed sequences" and S3 |
| fiber rule 5: entering and leaving active notifies for the names the fiber provides | contract 6 rule 5, second sentence; recon 01 G5 |
| fiber rule 6: dispose clears the uid, publishes, detaches and waits | contract 6 rule 6; fiber.ts disposer; recon 01 S3 (uid null in the disposal internal/plugin, state still the pre-disposal value) |
| fiber rule 6: disposing a parent disposes its children and grandchildren | contract 6 rule 6, last sentence; analysis law 10; digest law 29 |
| fiber rule 7: restart unloads, reloads with the same raw config and waits | contract 6 rule 7, fiber-restart! |
| fiber rule 7: update commits, stores the raw config and restarts | contract 6 rule 7, fiber-update!; recon 01 "Config update" and S24 |
| fiber rule 7/8 / S12: a fiber-local internal/update listener can keep the instance | contract 6 rule 7, "A listener that returns without calling next keeps the instance"; rule 8; recon 01 S12 |
| fiber rule 8: local update listeners see their own fiber only; order of the chain | contract 6 rule 8; events.ts kernel listeners; recon 01 "Resulting internal/update order" |
| fiber/config: a schema procedure validates; defaults reach the body, raw stays raw | contract 6, "Config schemas" (procedure form); recon 01 S24 |
| fiber/config: an invalid initial config fails the fiber with the validation error | contract 6, "Config schemas", exn:fail:cordis:validation and its message format; fiber.ts ValidationError; recon 01 S24 |
| fiber/config: an invalid update of a loaded fiber raises and changes nothing | contract 6 rule 7, "validates the candidate ... when the fiber is loaded"; fiber.ts update step 2; recon 01 S24 |
| fiber/config: a struct with prop:procedure is a schema | contract 6, "Config schemas", "any value applicable to one argument (a procedure, or a struct with prop:procedure ...)" |
| fiber/config: what a schema raises is recorded and propagated unchanged | contract 6, "Config schemas", "Whatever it raises propagates unchanged and is what the fiber records as its error" |
| fiber/config: raise-validation-error builds the Cordis ValidationError text | contract 6, "Config schemas", message format and `(raise-validation-error issues)`; fiber.ts ValidationError; recon 01 Formats |
| fiber/config: internal/config listeners wrap validation for every fiber | contract 6 rule 3, "validate the config through the 'internal/config waterfall"; events.ts kernel listener; recon 01 S13 |
| S20: a provider restart unloads dependents first and reloads them after | recon 01 S20; "Dependency tracking" consequences (provider restart) |
| S28: disposing the root unloads everything and leaves a working root | recon 01 S28, "Root fiber" (dispose is restart); contract 3, context-dispose! |
| S13: an update resolves the config for the candidate and again for the activation | recon 01 S13, "double resolution during an update"; fiber.ts update (candidate resolution) and _execute (activation resolution) |
| fiber/context: a fiber's context inherits meta, realms and intercept layers | contract 12 addendum 3 |
| context/threads: kernel operations may be called from a plain thread | contract 3, "Every public kernel operation that mutates state may be called from any thread"; contract 2 rule 5 (await of a fiber outside a task) and rule 7 |

### `lifecycle-spec-test.rkt` (18 cases)

| Test case | Source |
|---|---|
| case 1: the latest update wins while loading (without inject) | cordis-core-lifecycle.spec.ts "awaits the latest update while loading (inject: false)" |
| case 1: the latest update wins while loading (with inject) | cordis-core-lifecycle.spec.ts "awaits the latest update while loading (inject: true)" |
| case 2: a superseded activation failure is cleaned up and the update wins | cordis-core-lifecycle.spec.ts "cleans up a superseded activation failure and accepts the latest update" (recon case 2) |
| case 3: providers outlive dependent teardown on dispose | cordis-core-lifecycle.spec.ts "retains isolated providers through dependent teardown on dispose" |
| case 3: providers outlive dependent teardown on restart | cordis-core-lifecycle.spec.ts "retains isolated providers through dependent teardown on restart" |
| case 5: retained-instance updates publish; stale and rejected ones do not | cordis-core-lifecycle.spec.ts "publishes successful retained-instance updates and ignores stale or rejected completions" (recon case 5) |
| case 6: an old update does not publish after restart | cordis-core-lifecycle.spec.ts "does not publish an old update after restart" |
| case 6: an old update does not publish after dispose | cordis-core-lifecycle.spec.ts "does not publish an old update after dispose" |
| case 7: a delegating listener keeps the identity the new activation received | cordis-core-lifecycle.spec.ts "keeps the restarted config identity when a listener delegates" (recon case 7) |
| case 14: effects may be registered while a fiber is pending and loading | cordis-lifecycle.spec.ts "keeps effect registration legal while child fibers are PENDING and LOADING" (recon case 14) |
| case 15: dependencies added by an internal/plugin observer are honoured | cordis-lifecycle.spec.ts "resolves dependencies that internal/plugin adds before child activation" (recon case 15) |
| case 16: a publication failure rolls back parent and registry ownership | cordis-lifecycle.spec.ts "rolls back parent and runtime ownership when internal/plugin publication throws" (recon case 16) |
| case 17: a failing teardown observer is contained and logged once | cordis-lifecycle.spec.ts "contains teardown notification failures so ownership cleanup and peers complete" (recon case 17) |
| case 18: a loading parent joins a child cleanup that started earlier | cordis-lifecycle.spec.ts "makes a LOADING parent join child cleanup started before its unload snapshot" (recon case 18) |
| case 19: disposing the parent during publication drains the unpublished child | cordis-lifecycle.spec.ts "lets parent disposal during internal/plugin await the unpublished child to quiescence" (recon case 19) |
| case 21 (reduced): internal/config receives the fiber; restart resolves again | scripts/cordis-config-access.spec.ts "uses the canonical fiber through registry wrappers and retains raw input without updating" (recon case 21), reduced |
| case 22: an update reaches the body and publishes raw and effective config | scripts/cordis-config-access.spec.ts "publishes updates through registry wrappers to the canonical fiber" (recon case 22) |
| case 23: a pending fiber retains a raw update until its injection arrives | scripts/cordis-config-access.spec.ts "retains a pending raw update until its injection is available" (recon case 23) |

### `events-spec-test.rkt` (25 cases)

| Test case | Source |
|---|---|
| events/on: registration is a labelled effect; the disposer removes the listener | contract 7, "ctx-on is an effect labelled ctx.on(\"name\")" |
| events/on / S7: registration order, with prepended listeners in front | contract 7, "Listeners are kept in registration order, prepend? ones in front"; recon 01 S7 (observed: d-prepend, c-prepend, a, b) |
| events/listener: receives the arguments and its registering context | contract 7, "A listener is called with the dispatch arguments, with current-context set to the registering context" |
| events/keys: a string event name is the same event as its symbol | contract 3, "Functions that take a key also accept a string" |
| events/on: a listener disappears when its fiber is disposed | packages/AGENTS.md "Registry contributions prove disposal"; CONVENTIONS "A registration test disposes the fiber and observes the removal" |
| events/on: a listener registered through a pending fiber still receives events | recon 01 Events, "There is no filtering by the listener owner's fiber state. A listener receives events from the moment it is registered" |
| events/emit / S8: runs in the calling task; the first exception stops delivery | contract 7, emit bullet; events.ts emit; recon 01 S8 |
| events/parallel: listeners run as separate tasks and all are awaited | contract 7, parallel bullet, "run every listener as its own task" |
| events/parallel / S8: failures are collected after every listener ran | contract 7, parallel bullet, exn:fail:cordis:aggregate; events.ts parallel; recon 01 S8 |
| events/bail / S8: returns the first bailed result, else void | contract 7, serial and bail bullet (bail); events.ts bail; recon 01 S8 |
| events/serial / S8: returns the first bailed result, else void | contract 7, serial and bail bullet (serial); events.ts serial; recon 01 S8 |
| events/bailed?: everything except #f, void and 'null bails | contract 7, signature of bailed?; events.ts isBailed ("0 and '' bail") |
| events/waterfall / S9: listeners wrap the rest of the chain ending in inner | contract 7, waterfall bullet; events.ts waterfall; recon 01 S9 |
| events/waterfall: a listener that does not call next short-circuits the chain | contract 7, waterfall bullet; events.ts waterfall ("A listener that returns without calling next() vetoes the rest, including inner") |
| case 8: uninterned-symbol events and the waterfall next() guard | contract 7, error bullet `next() called multiple times`; cordis-core-lifecycle.spec.ts "supports symbol events and rejects repeated waterfall delegation" (recon case 8) |
| events/filter / S11: a filtered dispatch reaches matching and global listeners only | contract 7, "#:filter ... listeners registered with #:global? #t bypass it"; events.ts _resolve; recon 01 S11 |
| events/filter / S11: a realm filter delivers to listeners of one scope | recon 01 S11, "a Service dispatching with itself as receiver reaches only its own scope"; service.ts [symbols.filter] |
| events/internal-dispatch / S10: observes non-internal dispatches only | contract 7, "Before a non-internal dispatch, if 'internal/dispatch has listeners, emit (mode name args)"; recon 01 S10 |
| events/snapshot / S7: listeners added or removed during a dispatch | contract 7, "The listener list used by a dispatch is the list at the time the dispatch starts"; recon 01 S7 |
| events/once / S7: the listener runs for one dispatch and is then removed | contract 7, signature of ctx-once; events.ts once; recon 01 S7 |
| events/internal-listener: a bailed result replaces the registration | contract 7, "It first offers (ctx name listener options) to 'internal/listener through bail ... a bailed result is returned instead of registering"; events.ts on |
| events/dispatch: ctx-dispatch runs any mode by name | contract 7, signature of ctx-dispatch |
| events/serial: listeners may await and still run one after another | contract 7, serial bullet, "In Racket both may await" |
| events/dispatch-callbacks: resolves the listeners of a dispatch without calling them | contract 12 addendum 2, ctx-dispatch-callbacks; events.ts dispatch |
| events/call-contained: an exn:fail is logged and contained; other raises propagate | contract 12 addendum 4, call-contained |

### `laws-spec-test.rkt` (28 cases)

| Test case | Source |
|---|---|
| law 1: an effect runs its collected disposers in reverse order | digest law 1 (Definitions 1, 3; Theorem 16) |
| law 4: unloading a fiber restores the observation it started from | digest law 4 (Theorem 7); analysis law 1 (reversal) |
| law 4: check-kernel-restored accepts a mount followed by a dispose | digest law 4, through the cordis/testing helper (contract 10) |
| law 5: an empty effect and a no-op disposer are accepted and dispose cleanly | digest law 5 (Theorem 10) |
| law 7: calling a disposer twice has the effect of calling it once | digest law 7 |
| law 8: a target change stops an effect iterator after k of n yields | digest law 8 (Definition 18; Algorithm 1); contract 4 rule 9 (plugin body guard: the fiber's target is unchanged) |
| law 10: a parent effect and a fiber dispose what was registered inside them | digest law 10 (Definitions 12, 28) |
| law 11: a double provision raises and leaves the first binding intact | digest law 11 (Definition 19) |
| law 12: provide then dispose leaves the key absent and notifies at both changes | digest law 12 (Definition 20; Algorithm 2) |
| law 13: absent get is silent; undeclared and uncommitted reads raise differently | digest law 13 (Algorithm 6) |
| law 14: apply and unload run exactly at changes of satisfaction | digest law 14 (Definition 22) |
| law 15: realms are independent and notifications stay inside a realm | digest law 15 (Definitions 24, 25; Algorithm 3); analysis law 11 |
| law 16: interception merges metadata and triggers no lifecycle transition | digest law 16 (Definition 27; section 6.3) |
| law 17: a new provider of an equal value reloads dependents; an overwrite does not | digest law 17 (paper:6477-6483); analysis law 7 |
| law 22: apply never starts while a declared key lacks an active provider | digest law 22 (Theorem 70) |
| law 23: no provider disposer runs before every committed consumer has unloaded | digest law 23 (Theorem 70(2)); analysis law 8 |
| law 24: a consumer's disposer can still read the provider that is being disposed | digest law 24 (Theorem 70(3); Algorithm 6) |
| law 25: a leaving provider is out of service before its own disposers run | digest law 25 (L-Leave; paper:6322-6327) |
| law 26: a consumer caught mid-apply never turns active against the old provider | digest law 26 (Theorem 71) |
| law 27: toggling a dependency during a slow load never overlaps transitions | digest law 27 (section 4.4; Algorithm 5); analysis law 9 |
| law 28: after a fiber unloads it provides no keys and holds no effects | digest law 28 (Corollary 69) |
| law 29: children created during apply are gone after the parent unloads | digest law 29 (Definition 52); analysis law 10 |
| law 30: a disposed fiber stays retired when its dependencies reappear | digest law 30 (Lemma 59(5); section 4.4 Configuration) |
| law 31: a removed fiber holds nothing and its children finish before it | digest law 31 (O-Remove) |
| law 32: a failing apply is contained to its own fiber | digest law 32 (section 4.4 Failure) |
| law 33: a dependency cycle stays inactive without error or blocking | digest law 33 (section 6.5) |
| law 34: observations do not depend on the uid allocation | digest law 34 (Lemma 61) |
| law 35: a disposed fiber that is still referenced does not affect resolution | digest law 35 (Lemma 62) |

### `schedules-spec-test.rkt` (8 cases)

| Test case | Source |
|---|---|
| law 18: effects on table-valued services revert in any order | digest law 18 (Theorem 43; Definition 46) |
| law 19: registrations on different services commute | digest law 19 (Theorem 45) |
| law 20: unloading one component leaves an unrelated one unchanged | digest law 20 (Theorem 68) |
| law 21: every step of a random schedule keeps the system well formed | digest law 21 (Definition 63; Theorem 64) |
| law 36: every random schedule over an acyclic graph reaches quiescence | digest law 36 (Theorem 73); the schedule also carries the probes of laws 22, 23 and 24 in every plugin body and inverse |
| law 37: at quiescence the active fibers are the least supported set | digest law 37 (Lemma 77) |
| law 38: the quiescent observation does not depend on the schedule | digest law 38 (Theorem 80(2)): same plugins and configs, different insertion orders and interleavings of asynchronous steps |
| law 39: the quiescent observation does not depend on the history | digest law 39 (Theorem 80(1)): add, remove, add again, replace a provider, update a config, then arrive at the final configuration |

### `plugin-spec-test.rkt` (3 cases)

| Test case | Source |
|---|---|
| plugin/define-plugin: defines a plugin value with its declaration | contract 9, "Defines id as a plugin?"; ADR 0005 |
| plugin/define-plugin: plugin-info lists required and optional injections | contract 9, plugin-info bullet |
| plugin/define-plugin: required keys are handles, optional keys read through ctx-get | contract 9, define-plugin bullet on required and `#:optional` keys; ADR 0003 |

## Skipped cases

Each entry names what was not ported and why.

| Case | Reason |
|---|---|
| Recon case 6, variant "raw retention" | The TypeScript test assigns `fiber.rawConfig`. The contract has a reader for the raw config (`fiber-config`) and no writer other than `fiber-update!`. The same publication guard is exercised by case 5, where a newer update intervenes. |
| Recon case 20, "Candidate resolution is pure" | It needs the Loader, Schemastery volatile fields and `!!js` evaluation, which belong to the loader package, and `fiber.resolveConfig`, which the kernel contract does not have. |
| Recon case 21, wrapper parts | The thenable wrapper that `ctx.plugin()` returns (`Object.create(fiber)` with `then`), the `rawConfig` setter and `resolveConfig` are JavaScript machinery or absent from the contract. The remaining assertions are ported as "case 21 (reduced)". |
| S6, "root context reading an unknown name (`undefined`)" | Contract section 5, `ctx-ref` step 2, raises `cannot get property "key" without inject` instead. The suite follows the contract; see "Where the suite follows the contract over the TypeScript". |
| S14, "undeclared write", "root plain write", "withdrawal keeps `in` true" | These are `Proxy` property-write and `in`-operator rules. The contract has `ctx-set!` and `ctx-has?`, and `ctx-has?` is defined on providers. |
| S16, "writes through a mixin reach the source" | `Proxy` property writes; the contract gives `ctx-mixin` no setter. |
| S18, "await effect yields a non-thenable function" | Thenable machinery. Contract section 4 rule 8 replaces it and is tested. |
| S21, "getter sees the caller", `instanceof` | Tracing proxies and `Symbol.hasInstance`. The ownership and definition-site parts are ported in the form of ADR 0003. |
| S23, runtime record identity (`registry.has`, `registry.delete`, one runtime for a shared `apply`, the `apply2` name rule) | The registry service is not in the contract. One fiber per `ctx-plugin` call, uid order and name inheritance are tested in "fiber/surface". |
| S27, Logger service | `LoggerService` (hyphenated default names, level thresholds, `cause` and `AggregateError` expansion, buffer, `sn`) is replaced by Racket loggers; contract section 8 has `ctx-logger` only. The rule tests assert error logging through `capture-log`. |
| S29, class plugins | Classes, decorator-inherited `inject` and `[Service.init]` are JavaScript machinery. Generator bodies, visibility after activation and reverse cleanup are tested elsewhere. |
| S30, callable service, `[Service.extend]`, associated `"call.extra"` accessor | Callable objects built by prototype surgery and dotted proxy access. |
| Loader-level and tooling specs (`cordis-timer`, `cordis-entry-commit`, `cordis-include-journal`, `cordis-loader-resolve`, `cordis-vendor-hmr-include`, `cordis-core-api`, `cordis-config-files`, `gen-cordis-catalog-partition`, `verify-cordis-config`) | The recon note lists them at catalog depth as belonging to other packages; none tests kernel behaviour. |
| Contract section 2 rule 10, "logged ... when the task is garbage collected" | Garbage-collection timing is not deterministic. The shutdown path of the same rule is tested. |
| Contract section 2 rule 2, resume order of two tasks whose events become ready independently | The order in which two unrelated events become ready cannot be fixed without wall-clock timing. The deterministic part (a resuming task queues behind tasks already waiting) is tested. |
| Digest law 14, "a repeated notification causes neither" | The public API has no notify operation (`ctx-notify!` is in `cordis/private/loader-support`). The test uses an in-place `ctx-set!` and changes at undeclared keys. |
| Recon quirk 12, mixin members need the access rights of their source | The contract does not say through which read a mixed-in name resolves. |
| Contract section 7, `'internal/set` waterfall | The contract lists the event and names no operation that dispatches it. In TypeScript only a `Proxy` property write does; `ctx.set()` calls `reflect.set` directly. |
| Contract section 3, loader support (`context-derive/rebindable`, `context-rebind!`, `ctx-notify!`) | These live in `cordis/private/loader-support`, which is not one of the public modules this suite may use. |

## Where the suite follows the contract over the TypeScript

The contract states these behaviours explicitly and differs from the vendored source, which the recon note lists as quirks that need a decision. The suite tests what the contract states.

- Section 4 rule 3: after an inverse raises, the remaining inverses of the same effect still run and the disposer call re-raises the first exception (TypeScript skips the rest, quirk 14).
- Section 4 rule 4: a second, concurrent disposer call waits for the first (TypeScript returns at once, quirk 6).
- Section 4 rule 6: an asynchronous setup failure is logged (TypeScript is silent, quirk 5).
- Section 5, `ctx-ref` step 2: a root-fiber read of an absent key raises (TypeScript returns `undefined`).
- Section 6, `fiber-error`: a raised value that is not an exception is kept as raised (TypeScript wraps it in `Error`).
- Digest law 16 says context-carried interception metadata wins; the vendored code and the analysis give the plugin's own `inject` value the last word. The suite follows the code.

## Assumptions the contract does not settle

A failure in one of these places may be a difference of reading, not a kernel defect.

1. Recon case 15 adds an injection from an `'internal/plugin` observer. The contract names no mutator for a fiber's inject table, so the port writes to the table that `fiber-inject` returns and fails with a message that says so when that table is immutable.
2. The grammar of `maybe-label` in the `effect` form is not given; only the default label (`file:line:col`) is tested.
3. The signature of an accessor's setter is not given, so no test passes one. `default-merge` is passed as `#:merge`; no test passes a merge procedure of its own, because the contract does not give its arity.
4. `kernel-snapshot` is assumed to contain no uid, and to be `equal?` before and after a mount followed by a dispose on one root. Two roots are compared through `comparable` (in `support.rkt`), which sorts hash entries and lists and replaces symbols by their names, because creation order differs between schedules and realm symbols are uninterned.
5. A schema raises `exn:fail:cordis:validation` itself, either through the struct constructor with a message already in the contract's format or through `raise-validation-error`. A path is a list of symbols. The line of an issue with an empty path is checked only up to its message, because the contract does not say whether `(at ...)` is omitted.
6. The contract does not say that `current-scheduler` is set in kernel-created tasks. Code of the suite that runs in a plugin body or a listener passes `#:scheduler (context-scheduler ctx)` to `spawn-task`.
7. `fiber-committed` of an active fiber without injections is expected to be an empty hash, as `committed = {}` is in TypeScript.
8. `ctx-dispatch` is called with the mode as a symbol (`'emit`, `'parallel`, `'serial`, `'bail`, `'waterfall`). The mode in an `'internal/dispatch` payload is compared after `(format "~a" mode)`, so a symbol and a string both pass.
9. An event name that is an uninterned symbol stands for a JavaScript symbol event name (recon case 8).
10. An `'unloading` parent rejects `ctx-plugin` through section 4 rule 1, because the fiber is an effect of its parent; cases 18 and 19 rely on `ctx-plugin` skipping dependency resolution when the new fiber was disposed, or its parent began unloading, during publication (`fiber.ts` constructor).
11. A record returned by `capture-log` is assumed to be the vector a Racket log receiver produces: level, message, data, topic. Kernel error logs are captured with `#:topic 'cordis`; the `call-contained` test uses its own receiver for every topic under `cordis-logger`, because addendum 4 says "on `ctx`'s logger" and leaves the topic open.
12. `ctx-dispatch-callbacks` takes the mode as a symbol, like `ctx-dispatch`, and a returned procedure returns the listener's result, as a bound callback does in `events.ts`.
13. `call-with-root-context` is assumed to run its procedure in a task whose custodian outlives a restart of the root fiber, and to re-raise what the procedure raises. Cases 9, 11 and 13 and S28 restart or dispose the root from that task.
14. The rule 11 test holds the baton with `sleep` for 50 ms against a 1 ms threshold. The rule is about elapsed time between two release points, so this one outcome rests on a clock by definition; the test waits on events and has no other dependence on timing.
