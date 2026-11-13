# Interface contract: `dsh-test-support`

This is the binding interface for `racket/dsh-test-support/`: the test infrastructure every package from wave 4 on builds its tests with, and the home of the wave 3 end-to-end gate. It covers the loop harness (boot a root context with the wave 3 plugins and a scripted model, drive an agent, return the event log), the tool testkit, the fixture turn, a scripted-session format with its runner, the normaliser that makes two session logs comparable, and the replay runner that feeds a recorded dsh session through the Racket loop and reports the difference. Sources: [recon 18](../recon/18-testing-snapshots.md) (cited as R18 with its section), `packages/test-support/*/src` at commit `e8f7b93a3`, `docs/testing.md`. When this document and the TypeScript disagree about the behaviour of something both have (the testkit helpers, the normaliser, the fixture grammar), the TypeScript is right. The scripted-session format, the loop projection and the wave 3 replay runner exist only in the Racket port; for them this document is the specification. Read [dsh-agent.md](dsh-agent.md) first; its "Testing support" section defines the mounting helpers and the scripted model that this package re-exports.

Package: directory `racket/dsh-test-support/`, collection `dsh-test-support`, `(define deps '("base" "rackunit-lib" "cordis" "cordis-data" "cordis-yaml" "dsh-util" "dsh-session" "dsh-llm" "dsh-tools" "dsh-agent"))`. `rackunit-lib` is a run-time dependency because the package exports checks. No package below `dsh-agent` may depend on this one.

## Scope

Every package of `packages/test-support/*`:

| dsh package | npm name | Status |
|---|---|---|
| `agent-loop-testkit` | `@deepseek-ai/dsh-agent-loop-testkit` | native. The mounting helpers, the scripted model and the stub agent are implemented in `dsh-agent/testing` (that package's own tests need them and cannot depend on this one) and re-exported from `dsh-test-support/loop`, which adds the harness. `provideWorkingDirectoryFixture` and the `workingDirectory` mount option are added by the wave that defines the `workingDirectory` service (Open question 3). The `ptc` tool mode is the `#:executor` argument. |
| `tool-testkit` | `@deepseek-ai/dsh-tool-testkit` | native: `dsh-test-support/tools`. |
| `session-snapshot` | `@deepseek-ai/dsh-session-snapshot` | adapted. Wave 3 delivers the parts that work on session logs: the fixture file grammar and selection (`session-files.ts`), identity redaction (`identity.ts`), the log normaliser (`normalize.ts` without `normalizeStdout`) and the manifest reader (`manifest.ts`). The ACP launcher, the scenario harness, the suite factory, workspace capture and `normalizeStdout` launch a `dsh` profile or speak ACP; they are added to this package in wave 5, when `dsh-boot` and `dsh-sdk` exist. |
| `loader-smoke` | `@deepseek-ai/dsh-loader-smoke` | adapted. `runFixtureTurn` is native (`run-fixture-turn`). `runLoaderSmoke` starts the `dsh` command as a subprocess and is added in wave 5 with the launcher of `dsh-boot`; its `src`/`lib` launch modes have no counterpart. |
| `remote-mock` | `@deepseek-ai/dsh-remote-mock` | not applicable in this package. It mocks Typert Remote traffic for browser client tests; `dsh-web` owns the remote layer and any double for it. |
| `client-runtime` | `@deepseek-ai/dsh-client-test-runtime` | not applicable. It is a jsdom test bench for the React client, which the Racket port replaces with a Racket-served browser UI (ADR 0010). |
| `llm-mock-server` | `@deepseek-ai/dsh-llm-mock-server` | native, in `dsh-llm` (`dsh-llm/testing/mock-server`). |
| `llm-replay` | `@deepseek-ai/dsh-llm-replay` | native, in `dsh-llm` (`dsh-llm/replay`). This package calls `install-llm-replay!`. |

## Modules

| Module | Provides |
|---|---|
| `dsh-test-support` (`main.rkt`) | re-exports `loop`, `tools`, `script`, `normalize`, `check` |
| `dsh-test-support/loop` | everything of `dsh-agent/testing`; `call-with-loop-harness`, the `loop-harness` accessors, `run-turn`, `run-simple-session`, `run-fixture-turn` |
| `dsh-test-support/tools` | `make-content-tool`, the four stock tools, `execute-tool-fixture`, `execute-model-tool-fixture` |
| `dsh-test-support/script` | the scripted-session format: `session-script` (unrelated to `recorded-session-script` of `dsh-llm/replay`), `read-session-script`, `parse-session-script`, `run-session-script`, `expected-log`, `session-run`, `datum->jvalue` |
| `dsh-test-support/normalize` | `session->raw-log`, `read-raw-log`, `normalize-session-snapshots` and its five steps, `loop-projection`, `wave-3-event-types` |
| `dsh-test-support/fixtures` | `parse-session-fixture-name`, `session-fixture-names`, `check-session-fixture-version`, `read-snapshot-manifest` |
| `dsh-test-support/replay` | `replay-session-fixture`, `fixture-support`, `replay-result`, `default-replay-providers` |
| `dsh-test-support/check` | `line-diff`, `check-lines-equal`, `check-session-script`, `check-replays-fixture` |
| `dsh-test-support/plugins` | `plugin-table`, the empty list |

Private modules, suggested: `private/identity.rkt`, `private/scrub.rkt`, `private/expected.rkt` (expansion of `expect` clauses), `private/standins.rkt` (replay stand-ins).

## Data

A *raw log* is a list of jobjects: first the header row `{type: "session", …header fields}`, then one row per event in log order. Event rows are either *complete* (with `seq` and `time`) or *projected* (without both); a log is all one or all the other. A *line* is the compact JSON text of one row.

```racket
(loop-harness? v)                                  ; opaque
(harness-ctx h) -> context?                        ; the root context
(harness-model h) -> llm-adapter?                  ; the adapter registered for the harness providers
(harness-requests h) -> (listof llm-request?)      ; model requests so far, when the adapter is a scripted model
(harness-live h) -> (listof (cons/c symbol? hash?))   ; every agent/* event so far as (name . payload), dispatch order

(struct session-run (agent session events raw-log lines expected-lines live requests) #:transparent)
(struct normalize-context (cwd aliases) #:transparent)       ; cwd : (or/c string? #f); aliases : (listof string?)
(struct replay-result (status actual expected diff reasons) #:transparent)
;; status : 'match 'mismatch 'unsupported; actual, expected : (listof string?); diff : (or/c string? #f); reasons : (listof string?)
(session-script? v)                                ; a parsed script, opaque
(struct exn:fail:session-script exn:fail (srcloc)) ; a malformed script; srcloc may be #f
```

`session-run-events` is the session's complete event list. `session-run-lines` is the actual log after rule 16's normalisation; `session-run-expected-lines` is the expanded `expect` clause, or `#f` when the script has none. A snapshot manifest is the jobject read from `snapshot.yml`, validated; its keys are those of R18 Formats 2.

A *jvalue datum* is the notation scripts use for JSON values: a string, a number, `#t`, `#f`, the symbol `null`, a vector of datums (an array), or a list of two-element lists `(key datum)` whose key is a symbol or string (an object, keys in the order written; `()` is the empty object). `(datum->jvalue d)` converts and raises `exn:fail:session-script` for anything else.

## Services

This package defines no service key. Its procedures take a context where one is needed and register effects only as stated.

### Loop harness (`dsh-test-support/loop`)

```racket
(call-with-loop-harness proc
                        #:script [script '()] #:adapter [adapter #f] #:providers [providers '("mock")]
                        #:system-prompt [prompt-config (jobj)] #:loop-config [loop-config (jobj [agents '()])]
                        #:tools [tools '()] #:plugins [plugins '()] #:executor [executor native-executor-plugin]
                        #:clock [clock 'zero] #:timeout [secs 10]) -> any
(harness-create-agent h [id "s1"] #:options [options (jobj [provider "mock"] [model "mock-model"])] #:meta [meta #f]) -> agent?
(run-turn h agent text) -> (listof session-event?)           ; one followup, wait until idle; the events appended meanwhile
(run-simple-session #:script script #:inputs inputs #:tools [tools '()] …the keywords of call-with-loop-harness…) -> session-run?
(run-fixture-turn ctx #:task task #:on-event [on-event #f]) -> jobject?
```

`proc` is `(-> loop-harness? any)` and runs as a task; its values are the result. `script` is a list of scripted-model entries (dsh-agent rule 71); `adapter`, when given, is used instead and `script` must be empty. `tools` are tool definitions registered globally on the root. `plugins` is a list of `(cons plugin config)` mounted after the loop. `clock` is `'zero` (every event and chunk time is 0), `'counter` (0, 1, 2, …), `'system`, or a thunk. `inputs` is a list of strings, each sent as one followup after the previous turn went idle. `on-event` is `(-> string? session-event? any)`. `native-executor-plugin` is the binding of that name exported by `dsh-agent/testing`.

Waiting and cancellation. `call-with-loop-harness`, `run-simple-session`, `run-session-script` and `replay-session-fixture` take `#:timeout`; when it expires `call-with-root-context` raises and shuts the root down, which ends every task and port of the run. `harness-create-agent`, `run-turn` and `run-fixture-turn` take no cancel event and are bounded by the timeout of the enclosing call; `run-fixture-turn` on a caller's own context is ended by a break of the calling task, after which its `session/event` listener is removed. `execute-tool-fixture` and `execute-model-tool-fixture` are cancelled through the cancel event of their input.

### Tool testkit (`dsh-test-support/tools`)

```racket
(make-content-tool #:name name #:description description #:parameters parameter-spec #:execute execute
                   #:timeout-ms [ms #f] #:concurrency-safe? [cs #f] #:defer-loading? [dl #f]
                   #:present-call [pc #f] #:present-result [pr #f]) -> tool-definition?
(make-echo-tool [name "echo"]) -> tool-definition?
(make-failing-tool [name "fail"] #:message [message "boom"]) -> tool-definition?
(make-gated-tool name gate-evt #:started [started-semaphore #f] #:concurrency-safe? [safe? #f]) -> tool-definition?
(make-safe-echo-tool [name "safe_echo"]) -> tool-definition?
(execute-tool-fixture ctx input) -> tool-execution-result?        ; input : tool-execution-input?; waits
(execute-model-tool-fixture ctx #:call-id call-id #:name name #:arguments arguments #:cancel cancel
                            #:agent [agent #f] #:tool-set [tool-set #f]) -> tool-execution-result?   ; arguments : jvalue?; waits
```

`execute` is `(-> jvalue? tool-execution? (listof jobject?))`: it returns content blocks and may wait.

### Scripted sessions (`dsh-test-support/script`)

```racket
(session-script clause ...)                                   ; macro; -> session-script?
(read-session-script path) -> session-script?                 ; reads one (session clause ...) datum from a file
(parse-session-script datum #:srcloc [srcloc #f]) -> session-script?
(run-session-script script #:tools [tool-table (hash)] #:plugins [plugins '()] #:timeout [secs 10]) -> session-run?
(expected-log script) -> (or/c #f (listof string?))           ; the expect clause expanded and passed through rule 16's steps, without running anything
```

`tool-table` maps the names of the script's `tools` clause to tool definitions. The stock tools are available under their default names without a table entry.

### Normalisation and fixtures

```racket
(session->raw-log session) -> raw-log                          ; complete rows
(read-raw-log path) -> raw-log                                 ; JSONL; blank lines skipped
(normalize-session-snapshots logs ctx #:native-writer-output? [nwo #f] #:scrub-prompts? [scrub? #t]) -> (listof (listof string?))
(redact-session-snapshot-ids logs) -> (listof raw-log)         ; step 2
(normalize-session-log log ctx) -> raw-log                     ; step 3
(scrub-string str ctx) -> string?
(scrub-session-snapshot log #:scrub-prompts? [scrub? #t]) -> raw-log   ; step 4
(project-session-snapshot log) -> (listof string?)             ; step 5
(loop-projection log #:keep [types wave-3-event-types]) -> raw-log
wave-3-event-types                                             ; (listof string?)

(parse-session-fixture-name name) -> (or/c #f (cons/c exact-nonnegative-integer? exact-nonnegative-integer?))   ; (role . version); role 0 is the parent
(session-fixture-names names) -> (listof string?)              ; the selected file per role, parent first
(check-session-fixture-version path) -> void?
(read-snapshot-manifest path) -> jobject?
```

`logs` is the parent-first list of the raw logs of one scenario; `ctx` is a `normalize-context` or a list of them, one per log.

### Replay (`dsh-test-support/replay`)

```racket
(replay-session-fixture path #:providers [providers 'derive] #:override [override 'auto]
                        #:keep [types wave-3-event-types] #:timeout [secs 30]) -> replay-result?
(fixture-support path) -> (listof string?)                     ; why the fixture cannot be replayed in wave 3; '() when it can
default-replay-providers                                       ; jvalue, the providers of snapshots/session/text-turn/cordis.snapshot.yml
```

`path` is a scenario directory or one fixture file. `providers` is the `providers` config of `dsh-llm/replay`, or `'derive` (rule 30).

### Checks (`dsh-test-support/check`)

```racket
(line-diff expected actual) -> (or/c #f string?)               ; #f when equal; else a report of the first differing line with two lines of context
(check-lines-equal actual expected [message])                  ; rackunit check; fails with the line-diff as info
(check-session-script script #:tools [tool-table (hash)] …)    ; runs the script; fails unless actual and expected lines are equal
(check-replays-fixture path …)                                 ; fails on 'mismatch and on 'unsupported, printing the diff or the reasons
```

## Events

This package declares no event. It consumes, by registration on the harness root: every `agent/*` event (recorded in `harness-live`, and the `on` and `on-frame` triggers of scripts), `session/event` and `agent/created` (`run-fixture-turn`), and `tools/execute` with `#:prepend? #t` (the replay stand-in of rule 31). Recording listeners are registered before the loop is mounted and never wait, raise or call `next` out of order; a waterfall listener of the harness always returns `(next)`.

## Plugins

None. `dsh-test-support/plugins` provides `plugin-table` as `'()`. The harness mounts the plugins of the lower packages by their module values.

## Behaviour

Numbering is for tests.

**Loop harness** (R18 J; `agent-loop-testkit/src/index.ts`)

1. `call-with-loop-harness` runs inside `call-with-root-context` of `cordis/testing` with the given timeout. In order: set `current-session-time` from `clock` for the whole run; register the recording listeners for the thirteen events of `dsh-agent/events`; `mount-agent-loop-test-dependencies` with the system prompt config and the executor; build the adapter (`(make-scripted-model script)` unless one was given) and `llm-register-adapter!` it for `providers` on the root; register each tool with `tools-register!` on the root; `mount-agent-loop-test-harness` with the loop config; mount each of `plugins` and wait for it; call `proc`. Afterwards the root is shut down whatever `proc` did. Nothing outlives the call: no thread, port or file.
2. `harness-create-agent` is `(agent-loop-create (harness-ctx h) id options meta)`.
3. `run-turn` notes `(session-seq session)`, creates a user message with one text block, calls `agent-followup!` and `agent-when-idle`, and returns the events from the noted seq on.
4. `run-simple-session` boots a harness, creates agent `"s1"` with the default options, calls `run-turn` for each input, and returns a `session-run` whose `expected-lines` is `#f`.
5. `run-fixture-turn` (`loader-smoke/src/agent-turn.ts`). The top-level agents are those of `agents-list` whose session header has no `origin` `"subagent"`. Without the `agents` service raise `exn:fail` `fixture turn requires exactly one top-level agent, found 0`. When there is none, wait for one `agent/created`. Then, unless there is exactly one, raise `fixture turn requires exactly one top-level agent, found <n>`. Wait until it is idle; create the user message; listen to `session/event` for its session, ignoring everything before the `agent/inbox/spliced` whose `inserted` has the message's id; from then on call `on-event` with the session id and the event, remember the joined text blocks of each `assistant/message` that has text, and remember per `<turn>/<step>` the `usage` of an `assistant/message` or the last usage chunk of an `assistant/attempt` stream. Call `agent-followup!`, wait until idle, remove the listener also on a raise, then `sessions-flush`. The result is `{type: "result", sessionId, output, usage?}`; `usage` is the sum over the remembered steps of `inputTokens` and `outputTokens`, and of `cacheReadTokens`, `cacheWriteTokens` and `reasoningTokens` each only when some step has it.

**Tool testkit** (R18 J; `tool-testkit/src/index.ts`)

6. `make-content-tool` is `make-tool` with `#:output (v-array #:items (v-json))`, `#:render (lambda (args value) value)` and the given `execute`, whose result is the tool's value.
7. Stock tools. `echo`: description `Echo text.`, one required string parameter `text`, result `(list (text-block text))`. `fail`: description `Always fails.`, no parameters, raises `exn:fail` with the message. A gated tool: description `Waits for the gate.`, no parameters; it posts `started` when given, waits for `gate-evt` or the execution's cancel event, and returns `(list (text-block "done"))`; with `safe?` its classifier returns `#t`. `safe_echo`: `echo` with a classifier that returns `#t`.
8. `execute-tool-fixture`: `(make-tool-execution-pipeline ctx)`, `pipeline-prepare`, `pipeline-dispatch` when the preparation's kind is `'dispatch`, then `pipeline-complete` with the dispatch outcome or the preparation.
9. `execute-model-tool-fixture`: encode `arguments` with `jvalue->string`; a value that is not a jvalue raises `exn:fail:contract` `Model tool fixture arguments must encode as JSON`. Call `tools-execute` with one call `(tool-call-block call-id name text)`, the cancel event, and the agent and tool set when given. The result is the first result's `tool-execution-result`; an empty result list raises `exn:fail` `Executor omitted the model tool fixture result`.

**Scripted sessions**

10. Grammar. A script is `(session clause ...)`; the macro `session-script` takes the clauses directly and quasi-quotes them, so `,expr` inserts a computed datum. Clauses, in any order except that `reply` clauses are in call order and at most one `input` and one `expect` exist:

| Clause | Meaning |
|---|---|
| `(provider string)`, `(model string)` | the route; defaults `"mock"` and `"mock-model"` |
| `(options (key datum) ...)` | further agent options (`reasoningEffort`, `maxTokens`) |
| `(system-prompt (key datum) ...)` | config of `@deepseek-ai/dsh-system-prompt`; default `()` |
| `(model-info (key datum) ...)` | keywords of the scripted model: `reasoning`, `defaultMaxTokens`, `systemPromptUpdate`, `toolUpdate` |
| `(tools name ...)` | tools registered globally, by name |
| `(reply part ...)` | one model call. Parts: `(text string)`, `(reasoning string)`, `(tool-call call-id name arguments)` with `arguments` a string or a jvalue datum (encoded with `jvalue->string`), `(usage input output)`, `(finish kind)`, `(fail code message)`, `(hang)`, `(chunks datum ...)` |
| `(input step ...)` | what the test does. Steps: `(user text)`, `(steer text)`, `(inject text)`, `(idle)`, `(cancel kind [reason] [#:keep-inbox])`, `(on event-name step ...)`, `(on-frame index step ...)` |
| `(expect form ...)` | the complete expected durable log (rule 13) |

11. Replies. A reply without `fail`, `hang` and `chunks` is `(mock-reply block ... #:usage … #:finish …)` of `dsh-llm/testing/mock` over its text, reasoning and tool-call parts in order; `(finish kind)` gives the reason `{kind}`. `(chunks datum ...)` is the chunk list as written and excludes other parts. With `(fail code message)` the entry emits the block chunks of the other parts (no usage, no finish) and then raises `(llm-failure->exn {message, code})`; its *recorded chunks* are those chunks followed by `finish` with reason `{kind: "error", failure: {message, code}}`, which is what the adapter boundary delivers. With `(hang)` the entry is `(hang-after <the block chunks of the other parts>)`, or `'hang` when there are none; its recorded chunks are the emitted chunks. For every other reply the recorded chunks are the emitted chunks. The parser raises `exn:fail:session-script` for an unknown clause or part, a reply that mixes `chunks` with other parts, and `fail` together with `hang`.
12. Input. The steps run in order in the harness task; an `(idle)` is added at the end. `user`, `steer` and `inject` create a user message with one text block and call `agent-followup!`, `agent-steer!` or `agent-inject!`; the messages are named `u1`, `u2`, … in the order their steps appear in the script text. `(idle)` is `agent-when-idle`. `(cancel kind [reason])` is `agent-cancel!` with `{kind}` or `{kind: "hook", reason}`. `(on event-name step ...)` arms a one-shot trigger on one of the twelve `agent/*` events, named by its dsh name as a string: at the next dispatch of that event for the script's agent, its steps run inside the harness's listener, for a waterfall event before the listener calls `next`. `(on-frame index step ...)` runs its steps when the chunk frame with that index of the next started attempt is emitted. Triggers are armed when the input sequence reaches them and are on live events, never on `session/event`, because a session refuses an append made from inside one of its own `session/event` listeners (dsh-session rule 9). Steps inside a trigger may not be `idle` or another trigger; that is a parse error.
13. Expected log. `(expect form ...)` expands to projected rows, one or more per form, in order:

| Form | Rows |
|---|---|
| `(spliced target start [#:removed n] [#:inserted (ref ...)] [#:canceled])` | `agent/inbox/spliced {target, start, removedCount?, inserted, outcome?}`; `ref` names an input message |
| `(turn n form ... (end reason))` | `turn/start {turn: n}`, the rows of the forms, `turn/end {turn: n, reason}`. `reason` is `completed`, `max-tokens`, `blocked`, `(aborted kind [reason])` or `(error code message)` |
| `(step n form ...)`, inside `turn` | `step/start {turn, step: n}`, the rows of the forms, `step/end {turn, step: n}` |
| `(system [text])`, inside `step` | `system/message {turn, step, message}` with surface op append; without `text` the text is the token `{{system}}` |
| `(user ref)` | `user/message` with that input message, surface op append |
| `(header reason [#:starts-series] [#:config datum] [#:adapter-defaults datum] [#:tools list])` | `request/header {header, reason, startsSeries?}`. The default config is `{maxTokens?, provider, model, reasoningEffort?}` from the route and the options. `tools` is the token `{{tools}}` when the script has a `tools` clause and is omitted otherwise; `#:tools` gives it explicitly, as a list of names or, through unquote, as a list of tool schema jobjects that must match exactly |
| `(request-context [#:context-window n] [#:system-prompt-update string])` | `request/context {provider, model, …}` |
| `(assistant k [#:interrupted])`, inside `step` | `assistant/message` settled from the recorded chunks of reply `k` (1-based): the message from `assembly-blocks` (from `assembly-interrupted-blocks`, with `interrupted: true`, when flagged), `usage` when a usage chunk exists, `stream` from pushing each chunk with time 0 into an accumulator |
| `(attempt k)`, inside `step` | `assistant/attempt {turn, step, stream}` from the recorded chunks of reply `k` |
| `(call call-id)`, inside `step` | `tool/call {turn, step, callId, name, arguments}` with name and arguments from the reply that contains the call |
| `(result call-id block ... [#:failed] [#:error name code])`, inside `step` | `tool/result {turn, step, message, error?}` with `sourceEventSeqs` the index of the `(call call-id)` row and surface op append; blocks are `(text string)` or a jvalue datum; `isError` is true with `#:failed` or `#:error`, and `#:error` adds the identity `{name, code}` |
| `(event type datum [#:surface-op append] [#:sources (index ...)])` | one row as written |

14. Expansion details. Rows are written with the event constructors of the lower packages, so key order is theirs: `data`, then `sourceEventSeqs`, then `surfaceOp`. Input and derived messages get fresh UUID ids; the same message value is used everywhere a `ref` or a reply names it. `(assistant k)` builds its message with `make-assistant-message` for the script's route, with the assembly's replay state when present. A reference to an unknown message, reply or call is `exn:fail:session-script`. The expanded log starts at seq 0, so a row's index is its seq.
15. `run-session-script` boots a harness with the script's route, model info, system prompt config, tools and replies (clock `'zero`), creates agent `"s1"` with options `{provider, model, …options}`, runs the input steps, and returns the `session-run`.
16. Comparison. The actual lines are `(session->raw-log session)` without its header row, through steps 2 to 5 of the normaliser with context cwd `#f` and `scrub-prompts?` false. The expected lines are the expanded rows through the same steps. Before the comparison, token-aware matching is applied per line pair: where the expected system text is `{{system}}`, the actual first text block is replaced by it; where the expected header `tools` is `{{tools}}`, the actual `tools` is; where it is a list of names, the actual tools are replaced by their names. `check-session-script` fails with `line-diff` and reports the script's source location.

**Normalisation** (R18 D; `session-snapshot/src/normalize.ts`, `identity.ts`)

`normalize-session-snapshots` applies steps 1 to 5 to the parent-first logs of one scenario and returns the lines of each. It is applied identically to actual and expected logs.

17. Step 1, format metadata. Delete `version` from the header row. With `native-writer-output?`, in `session-log-deepseek/delivery-accepted` rows replace `data.sessionFormatVersion` by `{{sourceSessionFormatVersion}}` when it equals the log's original version. Migration of older generations (`prepareSessionSnapshotFixtureForComparison`) is not done here; a header version other than `session-format-version` raises `exn:fail` naming the version (wave 4 supplies the decoder).
18. Step 2, identity redaction over the whole set (`identity.ts:48-135`). Claims are made in this order: every header `id` as kind `session`; then a depth-first walk of each row in log order. A string can be claimed only if it contains a UUID, ends in `-` and 16 hexadecimal digits, or already is a canonical token; a canonical token maps to itself and raises its kind's counter to at least its number. The kind follows the key and place: `id` inside `approval/asked` and `approval/decided` data is `approval`; `commandId` is `command` and `rpcId` is `rpc` (both claimed whatever the string looks like); `retryId` is `retry`; `runId` is `workflow`; an object that has a string `id`, a string `role`, an array `content` and an object `source` claims its `id` as `message`; any other key matching `#px"^id$|Id$|Ids$"` is `id`; the text `as message <36 characters>` claims a `message`; the text `Anonymous user: <36 characters>` claims an `id`; `feedback/message-put` `data.item.version` is `id`. Each kind numbers its claims from 1 in claim order; the token is `{{<kind>:<n>}}`. Replacement is by exact string first, otherwise by substring with the longest source first.
19. Step 3, clocks and paths (`normalize.ts:350-437`). Header `createdAt` becomes 0; every event `time` becomes 0; inside `assistant/message` and `assistant/attempt` `data.stream` every `time` and `time0` becomes 0 and every `dt` member 0; `hook/result` `data.durationMs`, `feedback/message-put` `data.item.createdAt` and `updatedAt`, `job/registered` and `job/settled` `data.startedAt` and `finishedAt`, `goal/change` `data.createdAt` and `updatedAt`, and `subagent/catalog` `data.childCreatedAt` become 0; `sourceEventSeqs` is expanded with `decode-seq-ranges`. Then every string goes through `scrub-string`.
20. `scrub-string` (`normalize.ts:171-209`). With a cwd: each known spelling (the cwd, its aliases, and their `/private`-prefixed forms, longest first) becomes `{{cwd}}` when it is delimited as a path or text boundary; `/private{{cwd}}` becomes `{{cwd}}`. Backslashes become `/` only inside `{{cwd}}`-rooted paths, `<path>…</path>` tags, lines starting `Additional instructions from: `, and values under a key named `path`. Spill paths `{{cwd}}/.spill/session-<12 hex>/<12 hex>-<name>` and `(/tmp|/t)/(dsh-acp-snap-<9 hex>|dsh-acp-snapshot-spill)/session-<12 hex>/<12 hex>-<name>` become `{{spillLocator:<name>}}`. Inside a `session_event_read` result envelope the top-level `"time": N` becomes `{{eventTime}}` and `(Omitted N bytes.)` becomes `{{eventOmittedBytes}}`. The exact boundary rules are those of the TypeScript function; `normalize.spec.ts` is the oracle.
21. Step 4, scrub. With `scrub-prompts?`: the first text block of every `system/message` becomes `{{system}}`, and `request/header` `data.header.tools`, when present, becomes `{{tools}}`, or the list of tool names when the log has a `developer/message`. Always: remove the top-level `seq`, `time`, `seq0` and `time0` of every row.
22. Step 5, projection: one compact JSON text per row, written with `jvalue->string`.
23. What is not normalised and must match exactly: event types and order, turn and step numbers, all message content, tool-call ids and arguments, the chunk texts and boundaries inside `stream`, `request/header` config and reason, `request/context`, `surfaceOp`, `sourceEventSeqs` values, error codes and messages, and the relations between identities.
24. `loop-projection` (Racket only) reduces a raw log to the events the wave 3 packages write. `wave-3-event-types` is `agent/inbox/spliced`, `model/selection`, `turn/start`, `turn/end`, `step/start`, `step/end`, `system/message`, `developer/message`, `user/message`, `assistant/message`, `assistant/attempt`, `tool/call`, `tool/result`, `request/header`, `request/context`, `llm/retry`, `llm/retry-started`, `session/end-seed`. In order: give projected rows their index as seq; keep the header row and the rows whose type is kept; remove `meta` from `tool/result` data; rewrite every seq reference (`sourceEventSeqs`, the `startSeq` and `endSeq` of a replace `surfaceOp`, `developer/message` `data.headerSeq`) to the index of the referenced row among the kept rows, raising `exn:fail` `loop projection: event <i> (<type>) refers to dropped event <j> (<type>)` when it was dropped; renumber the canonical identity tokens of each kind densely in order of first appearance in the kept rows. It is applied to both logs before step 1.

**Fixture files** (R18 Formats 1 to 3; `session-snapshot/src/session-files.ts`, `manifest.ts`)

25. `parse-session-fixture-name`: `session.jsonl` is `(0 . 0)`; `session.v<N>.jsonl` with `N` at least 1 and no leading zero is `(0 . N)`; `session.<k>.jsonl` and `session.<k>.v<N>.jsonl` with `k` at least 1 are `(k . 0)` and `(k . N)`; anything else, including `.v0`, is `#f`. `session-fixture-names` returns for each role the name with the highest version, parent first, and raises when the roles are not contiguous from 0 or the parent is missing, with the messages of `session-files.ts:89-110`. `check-session-fixture-version` raises unless the header row's `version` (0 when absent) equals the version in the file name.
26. `read-snapshot-manifest` parses `snapshot.yml` with `cordis-yaml` in its JSON schema (no tags) and validates the closed key set of R18 Formats 2 with the messages of `manifest.ts:201-432`: `version` must be 1; names match `#px"^[a-z0-9]+(?:-[a-z0-9]+)*$"`; unknown keys at any level raise `… has unknown field(s): …`; `sessionFormat` and `session` are mutually exclusive.
27. A committed fixture is a projected raw log with tokens (R18 Formats 3). `read-raw-log` returns it unchanged; a file that mixes complete and projected rows raises `exn:fail`.

**Replay runner** (R18 A to C for what dsh does; the wave 3 reduction is this document's)

28. `replay-session-fixture`, in order: resolve the parent fixture (for a directory: `session-fixture-names` of its entries, first name; then `check-session-fixture-version`) and read the manifest when the directory has one; compute `(fixture-support path)` and return status `'unsupported` with the reasons when it is not empty; derive the inputs (rule 30); run (rule 31); compare (rule 32).
29. `fixture-support` scans the manifest, the directory and the parent fixture and returns one reason per failed condition. Wave 3 replays a fixture only when all of these hold:

| Condition | Otherwise needed |
|---|---|
| the selected parent generation is `session-format-version` (4), with projected rows | the format catalog of `dsh-session-store` (wave 4) for v0 to v3 and packed rows |
| no child fixture (`session.<k>`), no `parentSession` in the header | `dsh-subagent` (wave 4) |
| the manifest, when present, has `profile: headless` and neither `sessionFormat` nor `session` | `dsh-boot` profiles and `dsh-sdk` (wave 5); the format catalog |
| exactly one `agent/inbox/spliced` inserts messages, and it inserts one message with source kind `user` and a single text block | the plugin that inserts the other input (reminders, job notices, subagent settlement), or a scripted driver (ACP `input.json`, SDK actions, wave 5) |
| every `user/message` has source kind `user` or `runtime-context`, and every content block of a user message is text | the owning context plugin (wave 4); attachments (`dsh-fs`) |
| all `runtime-context` messages have `form: "snapshot"` and the same `sections` | the real context providers (wave 4 and 5) |
| exactly one `system/message`, exactly one `request/header`, its reason `initial`, no `developer/message`, no `model/selection`, no event with a replace `surfaceOp`, no `compaction/summary` | dynamic tools, model switching, compaction, prompt changes (waves 4 and 5) |
| the header config has only `provider`, `model`, `reasoningEffort`, `maxTokens` | a way to set other controls (wave 4) |
| every `turn/end` reason is `completed`, `max-tokens` or `error` | cancellation drivers and hooks (waves 4 and 5) |
| no `tool/call` is named `run_code`; within a step no second `tool/call` precedes the first `tool/result` | `dsh-ptc`; the real tools' parallel-safety classifiers |
| an override sidecar, when present, has no `hang` entry and no `{{session:N}}` with `N` above 1 | a cancelling driver; child sessions |
| every `llm/retry` row has a `policyKey` whose jitter ratio is 0 | a recorded random sequence |

Not checked and not reproduced in wave 3, whatever the fixture: the system prompt text and the tool schemas (both are tokens in committed fixtures; the sidecars `system-prompt.expected.md` and `tool-schemas.expected.json` and the header-class pins are verified in wave 5); events of plugins outside wave 3 (`permission/preset`, `sandbox/mode`, `approval/policy`, `session/title`, `job/*`, `todo/write` and the rest), which the loop projection removes from both logs; `tool/result` `meta`; standard output, standard error and the exit code; the workspace before and after; the scenario's Cordis patches, environment, permission and platform keys.

30. Derived inputs (`snapshots/session/headless.snapshot.ts:330-357`, `:472-483`). The task is the text of the inserted user message. The route is `provider` and `model` of the request header's config. Agent options: `reasoningEffort` and `maxTokens` from that config when the header's `adapterDefaults` does not mark them. With `providers` `'derive`, the replay provider config is one provider with the route's id and one model with the route's model id, plus: `contextWindow` and `systemPromptUpdate` from the `request/context` row; `defaultMaxTokens` equal to the config's `maxTokens` when marked as an adapter default; `reasoningEfforts` holding the config's `reasoningEffort` and the same value as `defaultReasoningEffort` when marked; `retryPolicy` rebuilt from the `policyKey` of the first `llm/retry` row (`["normal", maxRetries, codes, initialDelayMs, maxDelayMs, jitterRatio]` or `["always", initialDelayMs, maxDelayMs, jitterRatio]`) as `{mode, maxRetries?, retryableCodes?, backoff: {initialDelayMs, maxDelayMs, jitterRatio}}`. The override file is `replay.override.json` beside the fixture when it exists, unless `#:override` names another path or is `#f`.
31. The run, inside `call-with-root-context`. In order: `mount-agent-loop-test-dependencies` with the default system prompt config; `(install-llm-replay! ctx {file, overrideFile?, providers})` on the root; when the fixture has `llm/retry` rows, mount `(make-llm-retry-plugin #:delay-evt (lambda (ms) always-evt))` of `dsh-llm/plugin/llm-retry`; register the stand-ins; mount the loop with `{agents: []}`; `(agents-create ctx #:session-id <a fresh id> #:meta {cwd, delegationDepth?, …} #:agent-options options)` with the header fields of the fixture's header row other than `type`, `id`, `createdAt` and `version`, the `{{cwd}}` token replaced by a fixed absolute path that is never created; `agent-followup!` with the task; `agent-when-idle`; `replay-assert-consumed!`; take `(session->raw-log session)`; dispose the handle. Stand-ins: (a) for each distinct `tool/call` name, a tool made with `make-raw-tool` (parameters `{type: "object"}`, output schema `{type: "array"}`, `render` returning the value) whose body returns the recorded content of the `tool/result` with the execution's call id; when no tool is called but the recorded header has `tools`, one such tool named `replay_placeholder`; (b) a `tools/execute` listener registered with `#:prepend? #t` that, for a call whose recorded result has `isError` true, returns `(make-tool-failure text content #:info <the recorded error identity>)` without calling `next`, where `text` is the joined text blocks, and otherwise returns `(next)`; (c) for each section `{name, text}` of the recorded runtime-context snapshot, in order, `(system-prompt-context! ctx (make-prompt-context #:name name #:order <its index> #:text text #:interpolate? #f))`. Tokens inside recorded texts stay as written.
32. The comparison. Expected is the fixture's raw log; actual is the run's. Both go through `loop-projection` with `types`, then `normalize-session-snapshots` with `scrub-prompts?` true (the actual log with the fixed cwd as context), then `line-diff`. Status is `'match` when there is no difference. A failure of the run itself (a replay error such as an exhausted script, a timeout) is status `'mismatch` with the failure message as `diff` and whatever log exists as `actual`.
33. What a match establishes: for that fixture the Racket loop writes the same loop-owned events, in the same order, with the same field values and key order as dsh did, including inbox splices, turn and step boundaries, message admission, the request header reason and config, the request context, every assistant settlement with its embedded stream, retries, tool calls and tool results with their source references, and the turn-end reason. It does not establish prompt text, tool schemas or tool behaviour.

## Racket design notes

- **The scripted-session format.** Writing a loop test by hand means building every expected event, including the compact stream records inside each `assistant/message`, the message ids, the seq references of tool results and the balanced turn and step boundaries. The format removes four kinds of mistake. (1) Script and expectation cannot disagree: a `reply` clause is the single source for the chunks the model emits and for the `assistant/message` or `assistant/attempt` row expected from them, derived with the same accumulator and assembler the loop uses. (2) Nothing has to be renumbered when an event is inserted: the format has no seqs, times or ids; references are by name (`u1`, a call id, a reply index) and resolved by the expander. (3) Boundaries cannot be left unbalanced: `(turn n …)` and `(step n …)` generate the start and end rows and supply the coordinates to the rows inside. (4) Key order is not restated per test: rows are written by the event constructors of the lower packages. It is a datum format so that it can live in a file and be read without evaluating code. The `session-script` macro adds three things to the datum reader: clause heads are checked at compile time with `syntax/parse` (a misspelled clause is a syntax error that names it), unquote inserts computed values, and the source location of the script is reported with a failing check.
- **One normaliser for both sides.** dsh normalises the actual and the expected log with the same function and compares the results. The port keeps that shape: the five steps are pure functions over raw logs, usable on in-memory sessions and on committed files alike.
- **The loop projection is a stated reduction.** Wave 3 has no real tools, no persistence and no profile, so it cannot reproduce a recorded log in full. Instead of loosening the normaliser, the reduction is a separate, named step that removes exactly the events and the one field that later waves own and re-bases the references that would otherwise dangle. When those waves land, the same runner is called with a longer `#:keep` list and the stand-ins are dropped one by one.
- **Stand-ins replay recorded effects.** A recorded tool result is data; replaying it through a registered tool and the real pipeline exercises the loop, the batch scheduler and the session appends without the tool's world. Failures are authored at `tools/execute`, the one place where the pipeline accepts a listener-authored failure with its content and identity unchanged.
- **Harness state is a value, not globals.** `call-with-loop-harness` owns one root context and shuts it down; recorded live events and requests hang off the harness value.
- **Racket-only additions**, for the coordinator's ADR list: the scripted-session format and the `session-script` macro; `loop-projection` and `wave-3-event-types`; the replay stand-ins and `fixture-support`; the stock tools; `run-simple-session` and `run-turn`; the `#:clock` option. None is reachable from a dsh configuration.

## Work units

Two units, buildable in this order; unit 1 needs no kernel context.

| Unit | Modules | Depends on |
|---|---|---|
| 1: logs and files | `normalize`, `fixtures`, `check` (`line-diff`, `check-lines-equal`) and their tests | `cordis-data`, `cordis-yaml`, `dsh-session` |
| 2: harness, scripts, replay | `loop`, `tools`, `script`, `replay`, the remaining checks, `main` and their tests | unit 1, `dsh-agent/testing`, `dsh-llm/replay`, `dsh-llm/testing/mock` |

The interface between them is the set of exports of `dsh-test-support/normalize`, `…/fixtures` and `…/check` listed under Services. Unit 2 can be written against this document while `dsh-agent` is being built; its tests run once `dsh-agent/testing` exists.

## Tests

Tests live in `racket/dsh-test-support/tests/`. Rows name the TypeScript suites to mirror, under `packages/test-support/`.

| Racket test file | Mirrors | Pins |
|---|---|---|
| `normalize-test.rkt` | `session-snapshot/tests/normalize.spec.ts` (the session-log cases) | rules 17, 19 to 23: every clock field, cwd spellings and boundaries, `/private`, separators, spill paths, the event-read region, the prompt and tool scrub, idempotence on every `snapshots/session/*/session.v4.jsonl` |
| `identity-test.rkt` | `session-snapshot/tests/identity.spec.ts` | rule 18: claim order, kinds, canonical tokens as fixed points, substring replacement; every committed v4 fixture is a fixed point |
| `fixtures-test.rkt` | `session-snapshot/tests/storage-policy.spec.ts`, `manifest.spec.ts` | rules 25 to 27; every `snapshots/*/*/snapshot.yml` validates |
| `projection-test.rkt` | (none) | rule 24: reference re-basing, the dropped-reference error, token renumbering |
| `loop-test.rkt` | `agent-loop-testkit/tests/agent-loop-testkit.spec.ts`, `loader-smoke/tests/` (the `runFixtureTurn` cases) | rules 1 to 5: mount order, nothing left after the call, the fixture turn result and its usage sum over a retried step |
| `tools-test.rkt` | `tool-testkit/tests/model-call.spec.ts` | rules 6 to 9 |
| `script-test.rkt` | (none) | rules 10 to 16: every clause, every parse error with its source location, `fail` and `hang` replies, triggers, token-aware matching; `expected-log` of the two gate scripts equals the lines of dsh-agent rule 73 and, with the header's tools given as schemas, of rule 74 |
| `replay-test.rkt` | (none) | rules 28 to 33: `fixture-support` reasons on one fixture per unsupported condition; matches listed below |
| `gate-test.rkt` | (none) | the wave 3 gate |

Fixtures: the committed corpus under `snapshots/`, read in place and never written. The two gate scripts, kept as `tests/scripts/text-turn.rktd` and `tests/scripts/one-tool-turn.rktd`; the second is:

```racket
(session
  (tools echo)
  (reply (tool-call "call-1" "echo" "{\"text\":\"hi\"}"))
  (reply (text "DONE"))
  (input (user "Say hi"))
  (expect
    (spliced "next-turn" 0 #:inserted (u1))
    (turn 1
      (spliced "next-turn" 0 #:removed 1)
      (step 1
        (system "You are an AI agent powered by DeepSeek Harness.")
        (user u1)
        (header "initial")
        (request-context)
        (assistant 1)
        (call "call-1")
        (result "call-1" (text "hi")))
      (step 2 (assistant 2))
      (end completed))))
```

Acceptance gate, which is also the end-to-end gate of wave 3: `raco test racket/dsh-test-support` passes with no network and no API key; every numbered rule has a test that names it; `check-session-script` passes for both gate scripts; and `check-replays-fixture` reports `'match` for `snapshots/session/pi-ai-replay-metadata` (text turn with replay state), `snapshots/session/fs-read` and `snapshots/session/tool-call-turn` (one tool call, two steps), `snapshots/session/todo-write`, and `snapshots/session/empty-response-retry-current` (a failed attempt, `llm/retry`, `llm/retry-started`, then a message). `fixture-support` must report `snapshots/session/parallel-tool-calls` (overlapping calls), `snapshots/session/error-finish` (retained v0) and `snapshots/session/subagent-multi` (children) as unsupported, each with the reason of rule 29.

## Open questions

1. **Where the mounting helpers live.** dsh keeps them in the testkit package and lets `agent-loop` depend on it for tests only. A Racket package cycle is avoided by implementing them in `dsh-agent/testing` and re-exporting them here. Recommended default: as written.
2. **`cordis-yaml` interface.** Rule 26 needs a YAML reader restricted to the JSON schema that returns jvalues. Recommended default: use the reader `cordis-yaml` exports for untagged documents; if it is not ready, `fixture-support` treats a directory as if it had no manifest and reports that in a reason of its own, and `read-snapshot-manifest` is delivered with unit 1's remaining work.
3. **`workingDirectory` fixture.** dsh's `provideWorkingDirectoryFixture` provides a three-member service value whose definition belongs to a wave 4 package. Recommended default: that package's contract adds `(provide-working-directory-fixture ctx [default-directory])` to `dsh-test-support/loop` with a value that satisfies its own service contract.
4. **Message of a stand-in failure.** A recorded failed result stores content and identity, not the original message. Rule 31 uses the joined text blocks; nothing logged depends on it.
5. **Parallel tool calls in replay.** Rule 29 refuses a step with overlapping calls because stand-ins have no classifier. Recommended default for the wave that adds real tools: drop the stand-in for each tool that exists and keep the rule only for the remaining stand-ins.
6. **Header rows of in-memory sessions.** `session->raw-log` writes `{type: "session"}` followed by the fields of `session-header->jvalue`, the layout of a persisted header line. Recommended default: `dsh-session-store` confirms the layout in wave 4; if it differs, only this procedure changes.
7. **Fixtures that become replayable later.** Recommended default: each later wave extends the `#:keep` list and the conditions of rule 29 in this document as its package lands, and adds the fixtures it unlocks to `replay-test.rkt`; the coordinator tracks the count of matching fixtures in the progress file.
