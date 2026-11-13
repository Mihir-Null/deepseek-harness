# Racket port: architecture

This is the frame every package contract fits into: which Racket packages exist, what each covers, the order they are built in, and the conventions that cross package boundaries. Per-package interfaces are in `docs/racket/contracts/`. Coding rules are in [CONVENTIONS.md](CONVENTIONS.md). The kernel design is in [cordis-analysis.md](cordis-analysis.md).

## Packages

Each row is one Racket package under `racket/<name>/` with a top-level collection of the same name (so `(require dsh-tools)`), its own `info.rkt`, `README.md` and `tests/`. "Covers" lists dsh package groups under `packages/` unless a path says otherwise.

| Wave | Package | Covers | Depends on |
|---|---|---|---|
| 1 | `cordis` | `vendor/cordis`, the parts of `vendor/cosmokit` the kernel uses | `base` |
| 2 | `cordis-data` | the shared value model: ordered JSON objects, JavaScript-compatible JSON text, cosmokit `deepEqual`, UTF-16 and UTF-8 length helpers (ADR 0006) | `base` |
| 2 | `cordis-schema` | `vendor/schemastery`; volatile references from `vendor/cosmokit` | `cordis-data` |
| 2 | `cordis-yaml` | the YAML dialect of `cordis.yml` (read and write), the `!!js` expression evaluator | `cordis-data` |
| 2 | `cordis-loader` | `vendor/loader`, `vendor/include`, `vendor/group`, `vendor/timer`, `vendor/logger-console`, `vendor/hmr`, `boot/hmr` | `cordis`, `cordis-schema`, `cordis-yaml` |
| 2 | `dsh-util` | `util/*`; `exn:fail:harness`; HTTP and SSE client helpers | `cordis`, `cordis-data` |
| 3 | `dsh-session` | `core/session` | `cordis`, `dsh-util` |
| 3 | `dsh-llm` | `llm/*`; the mock and replay providers from `test-support/llm-*` | `cordis`, `cordis-schema`, `dsh-util`, `dsh-session` |
| 3 | `dsh-tools` | `core/system-prompt`, `core/tools`, `core/scope`, `core/tool-executor-native`, `core/agent-tool-presentation` | above |
| 3 | `dsh-agent` | `core/agent`, `core/agent-loop`, `core/agent-default-model` | above |
| 3 | `dsh-test-support` | `test-support/*`: agent-loop testkit, tool testkit, scripted-session runner, snapshot replay | above |
| 4 | `dsh-session-store` | `session/*`, `session-query/*` | wave 3 |
| 4 | `dsh-exec` | `subprocess/*`, `sandbox/*`, `shell/*`, `terminal/*`, `ssh/*` | wave 3 |
| 4 | `dsh-fs` | `fs/*`, `spill/*`, `attachment/*`, `deliverables/*` | wave 3, `dsh-exec` |
| 4 | `dsh-interaction` | `interaction/*`, `guard/*`, `plan/*`, `todo/*`, `feedback/*` | wave 3 |
| 4 | `dsh-automation` | `goal/*`, `schedule/*`, `jobs/*` | wave 3 |
| 4 | `dsh-context` | `context/*`, `skill/*`, `compaction/*`, `preset/*` | wave 3 |
| 4 | `dsh-subagent` | `subagent/*`, `team/*` | wave 3 |
| 4 | `dsh-connect` | `mcp/*`, `web/*`, `lsp/*` | wave 3 |
| 4 | `dsh-platform` | `credentials/*`, `settings/*`, `storage/*`, `workspace/*`, `identity/*`, `telemetry/*`, `document/*`, `computer-use`, `browser-use` | wave 3 |
| 4 | `dsh-ptc` | `ptc-runtime/*`, `core/tool-executor-ptc`, `workflow/*`, `experimental/ptc-runtime-python` | wave 3, `dsh-exec` |
| 5 | `dsh-boot` | `boot/*`, `bundle/*`, `apps/cli`: profiles, bundles, patch layering, the plugin resolver, the `dsh` command | everything above |
| 5 | `dsh-sdk` | `sdk/*`, `acp/*`, and the glue that lets `python/sdk` drive the Racket runtime | `dsh-boot` |
| 5 | `dsh-web` | `api/*`, `typert/*`, `host/*`, and a Racket-served browser UI in place of `client/*` | `dsh-boot` |
| 5 | `dsh-experimental` | `experimental/*`, `extensions/*` | `dsh-boot` |
| 6 | `dsh-js` | JavaScript value model and semantics as a Racket language, the target of the porter | `cordis`, `dsh-util` |
| 6 | `dsh-porter` | the plugin porter, its Node front end and the Node sidecar | `dsh-js`, `dsh-boot` |

## Cross-package conventions

**Plugins.** A dsh plugin is a Racket module that provides `plugin`, a `cordis` plugin value. Its `#:name` is the dsh npm name (`"@deepseek-ai/dsh-tool-bash"`), and its config schema accepts exactly the dsh config keys. Each package has a module `<package>/plugins` that provides `plugin-table`, a list of `(cons npm-name module-path)`. `dsh-boot` builds the resolver from these tables, so a `cordis.yml` row resolves by the name dsh uses. A name with no Racket module resolves to a ported plugin in the Harness home, then to the Node sidecar, and fails loudly if neither exists.

**Services.** A Service Definition module (`dsh-tools/tools`, `dsh-llm/llm`, ...) owns the service key, declared with `define-service`, and the public procedures. Every procedure takes a context or service handle first (ADR 0003). A seam with interchangeable providers is a `racket/generic` interface in the definition module. Service keys are the dsh `ctx` keys as symbols (`'tools`, `'llm`, `'sessions`, `'agents`, `'agentLoop`, ...), spelled exactly as in dsh, because `inject` lists in configuration and ported plugins use those names.

**Events.** Declared once with `define-event` in the Service Definition that owns them, with the dsh name (`'tools/pre-execute`) and the dsh dispatch mode. Session events are declared with the session package's own form, which records the field order used when the event is written.

**Tools.** Defined with the tool form from `dsh-tools`, which takes the name, the description, the parameter schema and the handler, and derives the JSON Schema sent to the model. Names, descriptions and schemas are copied from dsh verbatim.

**JSON.** All JSON-like data is a jvalue from `cordis-data` (ADR 0006): objects are immutable `jobject`s that keep insertion order, arrays are lists, `null` is `'null`. Text is read and written with that package, never with `racket/json`, so output matches `JSON.stringify`. JavaScript `undefined` and absent keys are both "key not present".

**Asynchrony.** Everything runs in tasks (ADR 0002). An operation that takes time returns normally after awaiting, or returns a task when the caller should not wait. Cancellation is a break or a cancellation event passed in the request; a dsh `AbortSignal` parameter becomes a `#:cancel evt` argument.

**Config.** Plugin config schemas come from `cordis-schema` and serialise to the Schemastery JSON form. Racket-only options live under the `x-racket` key of a plugin's config.

**Node.** No package depends on a built dsh or on `node_modules`. Where JavaScript must run (the `run_code` tool's TypeScript programs, wrapped plugins that cannot be translated), the package ships plain `.mjs` files that use only Node built-ins and talks to them over a pipe. A missing `node` binary disables those features with a clear error; everything else works without it.

**Durable formats.** Session logs, settings, storage files and credentials use the dsh on-disk formats and locations under the Harness home, so the two implementations can open each other's data. The Racket port never writes a format generation that dsh at the pinned commit cannot read.

## Build order and gates

A wave starts only when the previous wave's `raco test` is green. Inside a wave, an architect agent first writes the wave's contracts from the reconnaissance notes and the code that already exists; implementers then work in parallel, one per package; a reviewer who has not seen the implementation checks the wave against the brief and the parity table. The first end-to-end gate is at the end of wave 3: a scripted session with one tool call runs through the agent loop against the mock provider and writes the same sequence of session events that dsh writes.
