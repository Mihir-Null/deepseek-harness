# Wave 3: build order, integration points, extensions and open questions

This file is the coordinator's and the integrator's view of wave 3. It covers the five packages `dsh-session`, `dsh-llm`, `dsh-tools`, `dsh-agent` and `dsh-test-support`, whose interfaces are in [dsh-session.md](dsh-session.md), [dsh-llm.md](dsh-llm.md), [dsh-tools.md](dsh-tools.md), [dsh-agent.md](dsh-agent.md) and [dsh-test-support.md](dsh-test-support.md). It records the result of the cross-contract review, the order in which the work units can be built, what an integrator must test where two packages meet, every Racket-only extension and macro (for ADRs), and every open question with the default that implementers use. When this file and a package contract disagree about an interface, the package contract is right and this file gets fixed.

## Package graph

The packages form a chain; no package requires a module of a package to its right.

```text
cordis, cordis-data, cordis-schema, cordis-yaml, dsh-util   (waves 1 and 2)
  dsh-session  <-  dsh-llm  <-  dsh-tools  <-  dsh-agent  <-  dsh-test-support
```

Definitions that were placed lower than their dsh home so that the graph has no cycle:

| Definition | dsh home | Racket home | Re-exported by |
|---|---|---|---|
| scope tag, parent relation, scope-filtered dispatch | `core/scope` | `dsh-session/scope-core` (the store needs it) | `dsh-tools/scope`, which every other package requires |
| lossless JSON check | `util/values` | `dsh-session/lossless` | none; `dsh-tools` requires it by name |
| the marker `absent`, `safe-integer?`, `define-session-event` | (TypeScript types) | `dsh-session/types` | `dsh-session` |
| call config equality | `llm/llm` (`callConfigEquals`) | a private copy in `dsh-session/request-header`; `dsh-llm` exports its own `call-config-equal?` | none |
| cancel sources, cancel events, `exn:fail:abort` | `AbortController` (platform) | `dsh-llm/cancel` (the lowest package that takes a cancel event) | `dsh-llm`, `dsh-tools/cancel`, `dsh-tools` |
| `gen:settings-port`, `gen:projection-port`, `projection-definition` | `settings`, `session/session-projection` | `dsh-llm/ports` (the lowest consumer) | `dsh-agent/ports` (settings port) |
| wave 3 provider of `sessionProjections` | `session/session-projection` (wave 4) | `dsh-agent/projections`, plugin `racket:session-projections` | none |
| mounting helpers, scripted model, stub agent | `test-support/agent-loop-testkit` | `dsh-agent/testing` (its own tests need them) | `dsh-test-support/loop` |
| mock server, replay provider | `test-support/llm-mock-server`, `test-support/llm-replay` | `dsh-llm/testing/mock-server`, `dsh-llm/replay` | none |

Services that a lower package consumes from a higher one are reached by service key at run time, never by `require`: `agents` and `sessionProjections` (injected by `llm-retry`, `token-meter` and the inventory plugin of `dsh-llm`), `approval` (read by the pipeline of `dsh-tools`), and the event `agent/request-error` (registered by name with `ctx-on` in `dsh-llm/retry`).

## Scope coverage

Every package of the three covered dsh groups, with the Racket package that covers it.

| dsh group | Packages | Covered by |
|---|---|---|
| `core` | `session` | `dsh-session` |
| `core` | `scope` | `dsh-session/scope-core` and `dsh-tools/scope` |
| `core` | `system-prompt`, `tools`, `tool-executor-native`, `agent-tool-presentation` | `dsh-tools` |
| `core` | `agent`, `agent-loop`, `agent-default-model` | `dsh-agent` |
| `core` | `tool-executor-ptc` | `dsh-ptc` (wave 4) |
| `llm` | `llm`, `llm-deepseek`, `llm-deepseek-api-key`, `llm-deepseek-account`, `llm-retry`, `token-meter`, `deepseek-llm-api-extensions` | `dsh-llm`, native |
| `llm` | `llm-pi-ai`, `plugin-package-inventory-deepseek` | `dsh-llm`, adapted |
| `test-support` | `agent-loop-testkit`, `tool-testkit` | `dsh-test-support` (helpers implemented in `dsh-agent/testing`) |
| `test-support` | `session-snapshot`, `loader-smoke` | `dsh-test-support`, adapted: the parts that launch a profile arrive in wave 5 |
| `test-support` | `llm-mock-server`, `llm-replay` | `dsh-llm` |
| `test-support` | `remote-mock`, `client-runtime` | not applicable (`dsh-web` owns the remote layer; the React client is replaced) |

## Prerequisites from waves 1 and 2

Wave 3 starts when these hold. Each is a fact the five contracts rely on; the integrator checks them before launching implementers.

1. **Kernel addenda** (cordis-kernel section 12). `ctx-dispatch-callbacks` must be exported: `dsh-session/scope-core` builds `scoped-callbacks` on it, and the session store, the `tools/result` emit and every contained `agent/*` emit depend on that. Meta set with `context-extend` must be visible on the context of a fiber mounted through that context: the scope tag depends on it. The loader records `'loader/entry-id` in context meta: `dsh-llm` and `dsh-agent` read it.
2. **Raised values that are not exceptions.** The reason of a cancel event may be a jobject (the agent's cancel cause), and `check-cancelled!` raises it with `raise`. `await`, `task-result` and effect rollback must pass such a value through unchanged.
3. **`cordis-schema`**: `schema-never`, `min`, `max` and `step` on numbers, `min` on string length, `schema-role`, volatile fields with `volatile?` and `volatile-ref`, and the JSON form. All are in its contract.
4. **`cordis-yaml`**: `(yaml-read in #:schema 'json)`, which returns jvalues and rejects `!!js`. Only `dsh-test-support/fixtures` needs it.
5. **`dsh-util`**. It has no contract file. The wave 3 contracts assume exactly this of it, and isolate each use in one module so that a different name changes one place:

| Assumed | Used by |
|---|---|
| `exn:fail:harness`, a substructable `exn:fail` with a string `code` (accessor `exn:fail:harness-code`), a recorded dsh error name (the class name: `LlmError`, `ToolArgsError`, …) and, optionally, a cause | `dsh-llm/errors`, `dsh-tools/errors` (`harness-error-info` is the only reader of the name), `dsh-agent` through `harness-error-info` |
| a lowercase version 4 UUID generator | `dsh-llm` (`new-message-id`, `retryId`), `dsh-agent` rule 63, `dsh-test-support` |
| `(launch-environment-ref ctx name)`, the Harness home path, `(proxy-for-url url)`, atomic file replacement | `dsh-llm` only |

If `exn:fail:harness` has no name field, `harness-error-info` falls back as dsh-tools open question 3 says, and the persisted error identity of a failed tool result differs from dsh for errors of other packages. That is a parity defect, so the name field is the recommended resolution.

## Conventions settled by the review

These apply to all five packages. Where a package contract is silent, this section decides.

- **Config validation text.** In dsh a rejected plugin config fails the mount with Cordis's `ValidationError`: `invalid config:` and one line per issue, `  - <message> (at <path>)` (`vendor/cordis/src/fiber.ts:19-58`). The Racket kernel raises whatever the config schema raises, and a `cordis-schema` schema applied directly raises `exn:fail:schema` with the Schemastery text only. Rule: the value a wave 3 plugin gives to `#:config` must make a rejected config raise `exn:fail:cordis:validation`. If a `cordis-schema` schema already does that when used as a plugin config, pass the schema. Otherwise wrap it: call `(schema-validate schema raw)` and, when it returns issues, `(raise-validation-error issues)`. Each package's `plugins-test.rkt` asserts the prefix `invalid config:` for one rejected config. The coordinator should give this wrapper one home in wave 2.
- **Generic seam operations take the provider value first and the owning context second.** `projection-register!`, `settings-configure!`, `config-editor-edit!`, `agent-factory-create` and `agent-factory-resume` are generic methods on a provider's value, so `racket/generic` fixes the first argument. Each takes the owner as an explicit second argument and none reads `current-context`. Every other service procedure of wave 3 takes a context or a service handle first (ADR 0003). The review found no use of `current-context` for ownership. The parameters that exist are `current-session-time` (clock seam), `current-dispatch-scope` (which scope a listener is being called for) and the private initiator parameter of `dsh-agent` (attribution, not ownership).
- **Cancel events.** One definition, `dsh-llm/cancel`. `#f` means "never cancelled" wherever `dsh-llm` and `dsh-agent` take an optional cancel event; `dsh-tools` requires an event and offers `never-cancelled`. `check-cancelled!` raises the caller's reason; `check-cancel!` of `dsh-llm/adapter-kit` raises a coded `ABORTED` failure. Every procedure that waits names its cancel event in the "Waiting and cancellation" section of its contract; procedures without one are cancelled only by a break of the calling task and say so.
- **Event identifiers.** The Racket identifier of a Cordis event is its dsh name (`on-tools/execute`, `agent/created-name`). A module exports a generated dispatcher only when code outside it dispatches the event: `dispatch-tools/change` (the preset registry of wave 4) and `dispatch-llm/models-updated` (the model listing caches of `dsh-llm`).
- **Service accessors.** `define-service` generates `<id>-get`, so the dsh method `get` is `sessions-find`, `tools-lookup` and `agents-find`.
- **Names with `/` and names with `-`.** `tool/result` (session event of `dsh-session`), `tool-result` (struct of `dsh-tools`), `model/selection` (session event) and `model-selection?` (jobject predicate) are different bindings on purpose. A module may require the main modules of all four lower packages without a prefix; the integrator keeps one test module that does so.

## Build order

Thirteen work units. A unit can start when the units and modules in its "Needs" column export the signatures of their contract; bodies may still be incomplete.

| Unit | Content | Needs |
|---|---|---|
| S-A | `dsh-session` data plane: `lossless`, `types`, `events`, `surface`, `request-header`, `tool-history`, `repair`, `fork`, `seq-ranges` | `cordis-data` |
| S-B | `dsh-session` object and store: `scope-core`, `session`, `store`, plugin | S-A, `cordis` with `ctx-dispatch-callbacks` |
| L-1 | `dsh-llm` vocabulary and runtime: `cancel`, `jrecord`, `messages`, `errors`, `stream`, `content`, `retry-policy`, `attribution`, `ports`, `adapter-kit`, `llm`, `extensions`, `retry`, `testing/mock`, four plugins, `plugins` | `dsh-session/types` to start; all of `dsh-session` for its tests |
| L-2 | `dsh-llm` DeepSeek route: `http`, `sse`, `deepseek/*`, mock server, three plugins | L-1 |
| L-3 | `dsh-llm` meter, replay, pi-ai | L-1; for pi-ai only, the listed items of L-2 |
| T-1 | `dsh-tools` scope and system prompt | `dsh-session/scope-core`, `dsh-llm/cancel`, `cordis-schema` |
| T-2 | `dsh-tools` schemas and tool data | `dsh-session/lossless`, `dsh-session/types`, `dsh-util` |
| T-3 | `dsh-tools` registry, pipeline, batch, executor, plugins | T-1, T-2, all of `dsh-session`, `dsh-llm/messages` |
| A-1 | `dsh-agent` vocabulary and registry | all of `dsh-session`, L-1, T-1 |
| A-2 | `dsh-agent` driver | A-1 (public modules), L-1, T-3 |
| A-3 | `dsh-agent` lifecycle, loop service, `testing` | A-1, A-2 |
| X-1 | `dsh-test-support` logs and files | `cordis-data`, `cordis-yaml`, all of `dsh-session` |
| X-2 | `dsh-test-support` harness, scripts, replay, gate | X-1, A-3, `dsh-llm/testing/mock`, `dsh-llm/plugin/llm-retry`, `dsh-llm/replay` |

Order, with the units of one step running in parallel:

1. **Early modules.** Three modules are delivered before the rest of their units because other packages are built against them in the same wave: `dsh-session/types` with `dsh-session/lossless` (S-A), `dsh-session/scope-core` (S-B, no dependency on S-A), and `dsh-llm/cancel` (L-1, requires only `racket/base`). `dsh-llm/jrecord` follows as soon as `types` exports `absent`.
2. **S-A, S-B, L-1, T-1, T-2, X-1.**
3. **T-3, L-2, L-3, A-1.** Inside L-3 the replay module comes first: X-2 needs it. L-2 and the pi-ai part of L-3 are not on the path to the gate; the image and Files paths of L-2 may land after the gate (dsh-llm, Work units).
4. **A-2**, then **A-3**.
5. **X-2**, which holds the wave gate.

Each package's own acceptance gate is in its contract. The wave gate is the one of `dsh-test-support`: both gate scripts pass `check-session-script`, and `check-replays-fixture` reports a match for `pi-ai-replay-metadata`, `fs-read`, `tool-call-turn`, `todo-write` and `empty-response-retry-current` under `snapshots/session/`.

## What the review verified

- **Names across contracts.** Every binding that one contract uses from another exists there with the same signature and module path. The contracts were corrected where they did not agree (next section).
- **Cycles.** None; see "Package graph".
- **Service keys, event names and modes.** Checked against `docs/event-producer-consumer.md` and the TypeScript declarations: all 30 Cordis events the contracts declare or consume (`session/*` four, `system-prompt/*` two, `tools/*` five, `llm/*` three, `llm-pi-ai/request-headers`, `agent/*` twelve, `agent-loop/config-start-failed`, `workspace/session-activity`, `workspace/session-stop`) have the dsh name and mode; the argument lists of the `session/*`, `tools/*`, `system-prompt/*`, `llm/*` and `agent/*` declarations match; the inject lists of all twelve plugins that have one match the TypeScript `inject` exports; the service keys `sessions`, `tools`, `systemPrompt`, `llm`, `tokenMeter`, `deepseekLlmApiExtensions`, `agents`, `agentLoop`, `agentDefaultModel`, `sessionProjections`, `sessionPersistence`, `configEditor`, `approval` and `configuredAgentIdentities` are spelled as in dsh. `known-session-event-types` has 63 names and contains the four types that `dsh-llm` and `dsh-agent` declare.
- **Acceptance sequences.** dsh-agent rules 73 and 74 were compared with `snapshots/session/pi-ai-replay-metadata/session.v4.jsonl` (text turn) and `snapshots/session/tool-call-turn/session.v4.jsonl` (one tool call, two steps). Event order, type tags, field names and key order agree for every loop-owned event: the insert splice, `turn/start`, the claim splice, `step/start`, `system/message`, `user/message`, `request/header`, `request/context`, `assistant/message` (`turn, step, message, usage, stream`), `tool/call`, `tool/result` (`sourceEventSeqs` naming the `tool/call` seq, written before `surfaceOp`), `step/end`, `turn/end`; and for the four message key orders and the compact stream records. The recorded logs also hold what wave 3 does not write: `permission/preset`, `sandbox/mode`, `approval/policy`, `session/title`, `job/*`, the runtime-context `user/message` and `meta` on `tool/result`. The loop projection of `dsh-test-support` removes exactly those.
- **Gate fixtures.** The five fixtures of the wave gate satisfy every condition of dsh-test-support rule 29 (headless profile, one inserting splice, one header with reason `initial`, completed turns, a retry policy with jitter 0).
- **Work units.** Each split names its internal interface. One gap was closed (`plugin-record-input`, below).

## Corrections made by the review

| Contract | Change |
|---|---|
| `dsh-session` | `scoped-callbacks` is defined on `ctx-dispatch-callbacks` of the kernel addenda; open questions 1 and 2 are settled. The store dispatches on the context captured by `sessions-enter`, with no base filter. `tool-call-recovery-results` returns `session-event?` values, and the rule says how a live caller appends them. The constructor of an `#:ignorable` declaration returns a `plugin-record-input`, which `append-plugin-record!` accepts in a one-argument form; before, the constructor's result had no stated type and the appending procedure had no way to take it. The list of Racket-only additions is complete. |
| `dsh-tools` | `scope-raw-dispose` and `scope-dispose` are accessors that return procedures, as `dsh-agent` uses them. The scope table says where the other five `core` packages are covered. Open question 1 is settled; open question 4 uses `schema-never` and points to the config validation convention. The list of Racket-only additions is complete. |
| `dsh-llm` | `llm-remote-discover-models` raises `exn:fail:llm-discovery-rejected`, a substruct that carries the details, so nothing depends on a details field of `exn:fail:harness`. The calling convention of ports is stated once. Open questions 3 and 4 are settled by the kernel addenda and by `cordis-schema`; open question 6 points to the `dsh-util` list above. The list of Racket-only extensions includes the macros, the ports and the HTTP modules. |
| `dsh-agent` | Rule 55 builds the recovery inputs with `make-session-event-input`. The ports section names the calling convention. Open questions 3 and 4 are settled. |
| `dsh-test-support` | Open question 2 names the reader, `(yaml-read in #:schema 'json)`. Nothing else needed a change. |

Points that the contracts already carried as settled between them when this pass began, and that this pass confirmed: the cancellation values live in `dsh-llm/cancel` and `dsh-tools/cancel` re-exports them; `gen:settings-port` lives in `dsh-llm/ports`; the recorded script struct of `dsh-llm/replay` is `recorded-session-script`, so that `session-script` belongs to `dsh-test-support/script`; every `agent/*` payload carries `'session` and `'cancel`; the `assistant/message` field order is `interrupted`, `usage`, `stream`.

## Integration points to test

Each item is a place where two or more packages meet. An integrator writes at least one test per item, outside any single package's suite, once the packages exist.

1. **Scope routing end to end.** A listener registered through `(agent-ctx a)` receives `session/event`, `tools/pre-execute`, `tools/result` and `agent/status` for `a` and for agents whose scope has `a` as an ancestor, and nothing for a sibling. A listener registered through the root receives all. (`dsh-session/scope-core`, `dsh-tools/scope`, `dsh-agent/events`.)
2. **Resolution before commit.** A raising `'internal/dispatch` listener makes `session-append!` fail with the log unchanged, and makes the `tools/result` emit fail before the `tool/result` append. (`ctx-dispatch-callbacks`, dsh-session rule 10, dsh-tools rule 39.)
3. **Tool events written by the batch scheduler.** `tool/call` and `tool/result` rows produced by `execute-tool-batch` through the constructors of `dsh-session/events` and `make-tool-result-message` of `dsh-llm` equal the recorded rows of `tool-call-turn` as JSON text, apart from `meta`.
4. **Assistant settlement.** `accumulator-snapshot` and `assembly-blocks` of `dsh-llm`, written by the loop through the `assistant/message` constructor, give the recorded row; `usage` is omitted when no usage chunk arrived.
5. **Request header round trip.** The loop writes `request/header` from `prepared-call-config`, `prepared-call-adapter-defaults` and the tools of `system-prompt-assemble`. `session-request-header`, `canonical-header` and `header-equal?` then decide whether the next step writes another. `header-equal?` compares `jvalue->string` of each tool, so the key order of `project-tool-schema` is part of the interface: a second identical step must write no header.
6. **Tool history.** `session-tool-history` feeds `make-llm-request #:tool-history`, and `project-tool-updates` in the adapter boundary consumes it, in the three tool update modes.
7. **Cancellation across four packages.** `agent-cancel!` with a cause while a tool is running: the tool sees `tool-execution-cancel` ready, started calls commit, unstarted calls get the aborted-before-dispatch result, `turn/end` records `{kind: "aborted", reason: <cause>}`. The same during `llm-prepare-call` (coded `ABORTED` failure, turn still `aborted`), during a stream (interrupted `assistant/message` or `assistant/attempt`), and during `tools-resolve` (the cause value itself is raised).
8. **A break of the driver task.** With a tool batch in flight, the batch's cancel event becomes ready with cause `disposed`, recovery results are written for pending calls, and `step/end` and `turn/end` close the log. (dsh-agent rules 37 and 55, dsh-tools "Waiting and cancellation".)
9. **Retry.** The `llm-retry` plugin of `dsh-llm`, mounted after `dsh-agent`, reads the `agent/request-error` payload with `jref` (`'session`, `'retryPolicy`, `'cancel`), appends `llm/retry` and `llm/retry-started` to that session between the failed `assistant/attempt` and the next attempt, and reads its budget through the projection port. The listener is registered by name; the test also mounts `llm-retry` when no `agent/request-error` is ever dispatched.
10. **The projection port.** `racket:session-projections` serves `llmRetry`, `tokenMeasurement`, `tokenUsage`, `contextPressure`, `contextBreakdown`, `turnBoundary`, `modelSelection` and `inbox` at once; a handle stays readable after its fiber unloaded; the version and summary conflict errors appear when two plugins register one key differently.
11. **Session event catalogue.** After the loop mounts, `agent/inbox/spliced` and `model/selection` appends are checked against their declarations; `llm/retry`, which no plugin registers, is accepted unchecked; disposing the loop removes its two declarations.
12. **Publication order.** Creation: `sessions-prepare`, `sessions-enter` on the agent context, `sessions-announce`, setup, `agents-enter!`, `agents-announce`. Teardown: `agent/disposed` before `session/disposed`, and inside an `agent/disposed` listener `sessions-find` still returns the session. Input sent from an `agent/created` listener starts a turn only after the last listener.
13. **Append reentry.** No wave 3 listener appends to a session from inside that session's `session/event` delivery: inbox notifications, `tools/result`, the runtime-context projection, the recovery observer, the token meter and the test harness triggers are all outside the publishing window.
14. **Prompt assembly inputs.** The assemble context built by the loop carries `'scope`, `'agent`, `'cancel`, `'model-selection` and `'tool-set`; the tool provider of the `tools` plugin and the `provider` and `model` variables of the loop read them; executor sections appear only for the scope's selected executor.
15. **Executor selection by agent.** `tools-execute` with an agent that has its own executor in scope, one that inherits the root's, and one whose executor was removed: `tools-execute` raises the tool executor unavailable error, and the turn ends with `{kind: "error"}` whose error has code `UNKNOWN` and the error chain as message (dsh-agent rule 56).
16. **Approval without a provider.** A `pre-ask` decision with no `approval` service yields a failed `tool/result` whose `error` is `{name: "ApprovalError", code: "APPROVAL_UNAVAILABLE"}`.
17. **Error identity.** `harness-error-info` returns `LlmError` for `exn:fail:llm` and the dsh class names for the errors of `dsh-tools`; the `turn/end` error of a failed tool activation has code `TOOL_ACTIVATION_FAILED`; an `exn:fail:llm` reaches `turn/end` as its failure unchanged; every other failure has code `UNKNOWN`.
18. **Config.** Every plugin with a config rejects a bad one with `invalid config:`; a live update of `maxParallelToolCalls` changes the limit of the next batch without a remount; a volatile DeepSeek field changes the next request.
19. **Replay through the loop.** `install-llm-replay!` with providers, `llm-prepare-call` and `prepared-call-stream` (config equality holds for the request the loop builds), the retry policy taken from the replay provider config, and tool stand-ins at `tools/execute`.
20. **Mount and dispose.** Every plugin of the four `plugin-table`s mounts by its dsh name with the listed inject list; `check-kernel-restored` holds after mounting them, creating an agent, running the one-tool turn and disposing; the names of the four tables are distinct.
21. **Custodians.** The driver task, the batch's dispatch tasks and a model stream's producer custodian belong to the agent's custodian; unloading the plugin that sent a message does not stop the turn; disposing the agent leaves no thread or port.
22. **One clock.** `current-session-time` supplies event `time` in `dsh-session`, chunk times in the loop and `time0` in the compact stream; with the clock at 0 the acceptance lines hold.
23. **The four main modules together.** One module requires `dsh-session`, `dsh-llm`, `dsh-tools` and `dsh-agent` without prefixes and compiles.
24. **PTC selector.** `@deepseek-ai/dsh-agent-tool-presentation` with `mode: "ptc"` fails at load with the stated message while `dsh-ptc` is absent.

## Macros introduced

Each removes the class of error named. All use `syntax/parse` and report the clause at fault.

| Macro | Package | Class of error or boilerplate removed |
|---|---|---|
| `define-session-event` | `dsh-session/types` | A producer writing data keys in an order that differs from dsh; a misspelled type tag or field (unbound identifier or unknown keyword at compile time); constructor, predicate, accessors and `match` pattern drifting apart. |
| `define-jrecord` | `dsh-llm/jrecord` | Wrong key order or spelling in logged and wire records; an optional field written as null where dsh omits it. |
| `define-junion` with `<union>-case` | `dsh-llm/jrecord` | A consumer that forgets a variant of a closed union (a compile-time error listing the missing variants, the counterpart of `assertNever`); an open union handled without a fall-through. |
| `define-tool` | `dsh-tools/tool` | A handler reading an argument the schema does not declare; schema and handler names drifting apart; a default applied in one callback and forgotten in another. |
| `session-script` | `dsh-test-support/script` | A test whose scripted replies and expected events disagree; hand-numbered seqs, ids and source references; unbalanced turn and step boundaries; a misspelled clause. |

`dsh-agent` introduces no macro. The kernel's `define-plugin`, `define-service` and `define-event` are used throughout.

## Racket-only extensions

For the coordinator's ADRs. None adds an `x-racket` config key, and none changes what an unmodified dsh configuration writes to a session log.

Names in the `racket:` namespace:

| Name | Kind | Package | Purpose |
|---|---|---|---|
| `racket:llm-mock` | plugin | `dsh-llm` | in-process scripted adapter for tests |
| `racket:llmMock` | service key | `dsh-llm` | the mock adapter, so a test mounted from configuration can read recorded requests |
| `racket:sessionFixtureDecoder` | optional service key | `dsh-llm` | lets `dsh-session-store` supply decoders for older fixture generations to `llm-replay` |
| `racket:session-projections` | plugin | `dsh-agent` | in-memory provider of `sessionProjections` until `dsh-session-store` ships the dsh registry |

Decisions that depart from the coordinator's brief or from dsh structure and need a recorded decision:

1. **Agent cancellation is a cancel source with a recorded cause; a break is a backstop** (dsh-agent rule 37 and design notes). The brief asked for cancellation by break.
2. **The inbox is a durable projection over `agent/inbox/spliced` events**, not an asynchronous channel.
3. **Consumer-owned generic ports** (`dsh-llm/ports`, `dsh-agent/ports`, `gen:tool-approval`) for services of later packages, with the calling convention "provider value first, owning context second".
4. **One home for cancellation values**: `dsh-llm/cancel`. The coordinator may hoist it into `dsh-util`; the module then becomes a re-export.
5. **Own HTTP and SSE client** in `dsh-llm/http` and `dsh-llm/sse`. ARCHITECTURE.md lists these helpers under `dsh-util`.
6. **Pull-based `chunk-stream`** with a custodian per call, in place of `AsyncIterable`.
7. **The driver has an inline opening** (dsh-agent rule 27): the part of a turn that dsh runs before its first `await` runs in the caller's task.
8. **The agent's custodian is its scope fiber's custodian**, and the driver task runs under it.
9. **The initiator is a parameter** carried by task parameterizations (attribution, not ownership).
10. **Native `llm-pi-ai` protocols** (`openai-completions`, `anthropic-messages`) and the report of unserved routes through the directory entry's `error`.

Further additions, by package:

- `dsh-session`: `current-session-time`; the event-type catalogue (`sessions-register-event-type!`, `#:event-types`) with the declared-field check and the shape check on live appends; `plugin-record-input`; `#:metadata-order` of `make-session-event`; `in-session-events`; `current-dispatch-scope`; the marker `absent`; the modules `scope-core` and `lossless`.
- `dsh-llm`: the loop mark as a field of `llm-request`; `exn:fail:llm-discovery-rejected`; failure code `MOCK_SCRIPT_EXHAUSTED`; the mock server command line as a Racket module; `make-llm-retry-plugin` and the seams `#:id`, `#:http-request`, `#:delay-evt`, `#:random`; a private copy of the anonymous user id file protocol.
- `dsh-tools`: the node constructors `v-string` to `v-one-of`, `param`, `parameters`; `#:or` and `#:args` of `define-tool`; `call-with-tool-cancel`; the session field of `tool-batch-log`; `dsh-tools/cancel`; the exported `dispatch-tools/change`.
- `dsh-agent`: `'session` in every `agent/*` payload and `'cancel` in place of `signal`; `gen:agent` with derived procedures; `dsh-agent/testing` including `hang-slow` with an event in place of a timer; registration of the two session event declarations by the loop plugin.
- `dsh-test-support`: the scripted-session format; `loop-projection` and `wave-3-event-types`; the replay stand-ins and `fixture-support`; the stock tools; `run-simple-session`, `run-turn`; the `#:clock` option.

## Open questions and the defaults in force

"Settled" means the contracts no longer depend on an answer. Numbers are those of the package contract.

| Id | Question | Default in force | State |
|---|---|---|---|
| session 1 | kernel support for resolving listeners | `ctx-dispatch-callbacks` (kernel section 12) | settled; the kernel implementation must export it |
| session 2 | meta inherited through fibers | guaranteed by kernel section 12 | settled |
| session 3 | home of the lossless check and `absent` | `dsh-session`; re-export if `dsh-util` gains equal bindings | open |
| session 4 | live appends of undeclared types | accept, log nothing | open |
| session 5 | `session/event` listeners that wait | documented obligation, not enforced | open |
| session 6 | object keys that look like array indexes | no special handling | open |
| tools 2 | home of cancellation values | `dsh-llm/cancel` | settled |
| tools 3 | fields of `exn:fail:harness` | a name field set by each substruct's constructor; fallback name `HarnessError` | open, needs `dsh-util` |
| tools 4 | schema for removed config keys | `schema-never`; config validation convention above | settled for the schema, open for the error text |
| tools 5 | parameter names that are integer strings | rejected by `define-tool` and `parameters` | open |
| tools 6 | module path of the PTC executor plugin | looked up in `plugin-table` of `dsh-ptc/plugins` | open until wave 4 |
| tools 7 | approval provider | the `approval` value of `dsh-interaction` implements `gen:tool-approval`; another value counts as absent, with one warning | open until wave 4 |
| tools 8 | disposer of a mounted fiber | `scope-raw-dispose` disposes the fiber; return the kernel's effect disposer if it is exposed | open |
| llm 1, 2, 5 | projection registry, `agent/request-error` payload, settings opt-out | as written in the contracts | settled |
| llm 3 | loader entry id | context meta `'loader/entry-id`, else the short name | settled |
| llm 4 | schema features | provided by `cordis-schema` | settled |
| llm 6 | `dsh-util` names | the list under "Prerequisites"; private fallback where one is missing, reported to the coordinator | open |
| llm 7 | HTTP client ownership | `dsh-llm/http`, `dsh-llm/sse` | open, coordinator decides |
| llm 8 | anonymous user id | private copy in `dsh-llm` | open |
| llm 9 | native pi-ai provider table | as written in P2 | open, review when the sidecar lands |
| llm 10 | unserved routes | directory `error` and one warning per route | open |
| llm 11 | inventory port | implemented by `dsh-boot`; until then one warning and an empty list | open until wave 5 |
| llm 12 | remote discovery error | `exn:fail:llm-discovery-rejected`; `dsh-web` maps it | open until wave 5 |
| llm 13 | version in `user-agent` | `0.2.2-rc.2` | open, coordinator may add a suffix |
| agent 1 | provider of `sessionProjections` | `racket:session-projections` | open until wave 4 |
| agent 2 | cancellation by break | cancel source, break as backstop | open, needs an ADR |
| agent 3, 4 | schema features, loader entry | provided | settled |
| agent 5 | payloads of the two `workspace/*` events | readable with `jref` under `sessionId`; a list result for the waterfall | open until wave 4 |
| agent 6 | `error-chain` on wrapped failures | rule 56 renders the aggregate | open |
| agent 7 | where the session event declarations are registered | the loop plugin | open |
| agent 8 | custodian of the scope fiber | `(context-custodian (agent-ctx agent))`; wait for the fiber if the kernel creates it lazily | open, kernel must confirm |
| agent 9 | typert lookups | `dsh-web` | open until wave 5 |
| agent 10 | final `turn/end` at root shutdown | keep dsh behaviour | open |
| test-support 1 | home of the mounting helpers | `dsh-agent/testing` | settled |
| test-support 2 | YAML reader | `(yaml-read in #:schema 'json)` of `cordis-yaml`; a directory counts as having no manifest if the implementation is not ready | settled in the contract |
| test-support 3 | `workingDirectory` fixture | added by the wave 4 package that defines the service | open until wave 4 |
| test-support 4 | message of a stand-in failure | joined text blocks | open |
| test-support 5 | parallel tool calls in replay | unsupported while stand-ins have no classifier | open until wave 4 |
| test-support 6 | header row of an in-memory session | `{type: "session"}` and the header fields | open until wave 4 |
| test-support 7 | fixtures that become replayable | each wave extends `#:keep` and rule 29 | open |

Questions raised by the review itself:

| Id | Question | Default in force |
|---|---|---|
| review 1 | Who turns a schema failure into `invalid config:`? | Each wave 3 plugin, by the convention above, until wave 2 offers one wrapper. |
| review 2 | `dsh-util` has no contract. | The list under "Prerequisites" is what wave 3 assumes; the `dsh-util` implementer confirms it or reports the differing names before wave 3 starts. |
| review 3 | Two scripted adapters exist: `make-mock-llm` (`dsh-llm/testing/mock`, coded failures, mounted from configuration) and `make-scripted-model` (`dsh-agent/testing`, a port of the loop's `mock-adapter.ts`, hang entries). | Keep both; they accept the same chunk lists. `dsh-test-support` uses the scripted model in its harness and `mock-reply` to build replies. |
| review 4 | Process-local payload values are Racket symbols where dsh has strings: `source` of `agent/created`, `status` of `agent/status`, the result of `agent-status`. | Keep symbols inside Racket. The layers that expose them as JSON or to translated plugins (`dsh-sdk`, `dsh-web`, `dsh-js`) convert with `symbol->string`. |
| review 5 | The kernel offers `call-contained` (logs at `error`); the packages use `invoke-contained` of `dsh-session/scope-core` (caller-supplied reporting at `warning`, observes a returned task). | Keep `invoke-contained`: the dsh log texts and levels are part of the observable surface. |

## Remaining risks

- The kernel implementation does not yet export `ctx-dispatch-callbacks`. Nothing above `dsh-session` unit S-A can be tested end to end without it.
- The error identity persisted in failed `tool/result` events depends on a `dsh-util` detail that no contract fixes.
- The acceptance lines of dsh-agent rules 73 and 74 were checked by reading, not by running code. The first run of `acceptance-test.rkt` is the real check of the key orders the constructors produce.
- Wave 4 contracts are being written against these files. `sessionProjections`, `sessionPersistence`, `approval`, `settings`, `configEditor`, `attachments`, `fs`, `credentials`, `deepseekAccount` and `loader` must each be provided there by a value that implements the generic interface named here, with the same method names.
- `llm-pi-ai` is the one adapted package whose wire rules are this port's design; parity with dsh for those routes is unverified until the Node sidecar exists.
