# Interface contract: `dsh-llm`

This is the binding interface for `racket/dsh-llm/`: the model-provider layer of the Racket harness. It covers the provider-neutral vocabulary, the `llm` service and its adapter seam, the DeepSeek Messages adapter with its two credential plugins, the retry executor, the token meter, the request-extension registry, the plugin-package inventory, the pi-ai route plugin, and the mock and replay providers used by tests. Sources: [recon 06](../recon/06-llm.md) (cited below as R6 with its section letter or number), [recon 18](../recon/18-testing-snapshots.md) (R18), and the TypeScript under `packages/llm/*/src` and `packages/test-support/{llm-mock-server,llm-replay}/src` at the pinned commit. When this document and the TypeScript disagree about behaviour, the TypeScript is right and this document gets fixed; when they disagree about Racket names and argument order, this document is right.

Package: directory `racket/dsh-llm/`, collection `dsh-llm`, `info.rkt` with `(define collection "dsh-llm")`, `(define deps '("base" "cordis" "cordis-data" "cordis-schema" "dsh-util" "dsh-session"))`, `(define build-deps '("rackunit-lib"))`. It uses `racket/tcp`, `openssl`, `racket/generic`, `racket/generator`, `racket/match`, `file/sha1` and `net/base64` from the base distribution and no third-party package.

Terms used throughout: *jvalue*, *jobject*, `jobj`, `jref`, `jset` come from [cordis-data](cordis-data.md); *task*, `await`, `blocking`, *effect*, *service handle*, `define-plugin`, `define-service`, `define-event` come from [cordis-kernel](cordis-kernel.md). `x` as a first argument always means "a context or a service handle" (ADR 0003). A *cancel evt* is a Racket `evt` that becomes ready when the caller gives up and then stays ready; it replaces `AbortSignal` (ADR 0002). `#f` for a cancel evt means "never cancelled". Cancel evts, cancel sources and `exn:fail:abort` are defined once, in `dsh-llm/cancel` (Services, "Cancellation"), because this is the lowest package that takes a cancel evt; `dsh-tools/cancel` re-exports that module unchanged.

## Scope

Every package of `packages/llm/*` and the two LLM packages of `packages/test-support` at the pinned commit:

| dsh directory | npm name | Status | How |
|---|---|---|---|
| `packages/llm/llm` | `@deepseek-ai/dsh-llm` | native | Modules `dsh-llm/messages`, `errors`, `content`, `stream`, `llm`, `retry-policy`, `attribution`; plugin `dsh-llm/plugin/llm`. The typert `@Remote` decorators are not ported; the three remote methods are listed in a table that `dsh-web` exposes. |
| `packages/llm/llm-deepseek` | `@deepseek-ai/dsh-llm-deepseek` | native | Library `dsh-llm/deepseek` over this package's own HTTP and SSE modules. The Files API and image request path are specified here but need the `attachments` provider of `dsh-fs` (wave 4) to be exercised; see Work units. |
| `packages/llm/llm-deepseek-api-key` | `@deepseek-ai/dsh-llm-deepseek-api-key` | native | Plugin `dsh-llm/plugin/llm-deepseek-api-key`. |
| `packages/llm/llm-deepseek-account` | `@deepseek-ai/dsh-llm-deepseek-account` | native | Plugin `dsh-llm/plugin/llm-deepseek-account`. Authenticates only through the `deepseekAccount` service of `dsh-platform`; without it every request fails with `ACCOUNT_SIGN_IN_REQUIRED`, as in dsh. |
| `packages/llm/llm-pi-ai` | `@deepseek-ai/dsh-llm-pi-ai` | adapted | The config schema, profile resolution, route and directory registration, discovery and two wire protocols (`openai-completions`, `anthropic-messages`) are native. dsh delegates the wire to the Node library `@earendil-works/pi-ai`; routes that need its other protocols, its model catalog, OAuth logins or cloud credential discovery are reported as unservable in wave 3 and become wrapped by the Node sidecar of `dsh-porter` in a later wave. The exact native set is in Behaviour P2. |
| `packages/llm/llm-retry` | `@deepseek-ai/dsh-llm-retry` | native | Module `dsh-llm/retry`, plugin `dsh-llm/plugin/llm-retry`. |
| `packages/llm/token-meter` | `@deepseek-ai/dsh-token-meter` | native | Module `dsh-llm/token-meter`, plugin `dsh-llm/plugin/token-meter`. |
| `packages/llm/deepseek-llm-api-extensions` | `@deepseek-ai/dsh-deepseek-llm-api-extensions` | native | Module `dsh-llm/extensions`, plugin `dsh-llm/plugin/deepseek-llm-api-extensions`. |
| `packages/llm/plugin-package-inventory-deepseek` | `@deepseek-ai/dsh-plugin-package-inventory-deepseek` | adapted | Same request field and ordering; package identity comes from the loader port (the npm name a row was written with, and the version the resolver reports) because Racket plugins have no `package.json`. |
| `packages/test-support/llm-mock-server` | `@deepseek-ai/dsh-llm-mock-server` | native | Module `dsh-llm/testing/mock-server`: a Racket TCP server speaking the same HTTP and SSE. The CLI is `racket -l dsh-llm/testing/mock-server-cli` in place of `pnpm run mock:llm`. |
| `packages/test-support/llm-replay` | `@deepseek-ai/dsh-llm-replay` | native | Module `dsh-llm/replay`, plugin `dsh-llm/plugin/llm-replay`. Decoding of fixture generations older than the current Session format is delegated to a decoder that `dsh-session-store` supplies in wave 4. |
| (none) | `racket:llm-mock` | Racket-only | Module `dsh-llm/testing/mock`, plugin `dsh-llm/plugin/llm-mock`: an in-process scripted adapter for tests. |

Not applicable: nothing in these groups is dropped.

## Modules

Public modules. Each exports through `contract-out`.

| Module | Provides |
|---|---|
| `dsh-llm` (`main.rkt`) | Re-exports `dsh-llm/cancel`, `dsh-llm/messages`, `dsh-llm/errors`, `dsh-llm/stream`, `dsh-llm/llm`, `dsh-llm/content`, `dsh-llm/retry-policy`, `dsh-llm/attribution`. This is what a consumer of the `llm` service requires. |
| `dsh-llm/cancel` | Cancel sources, cancel evts and `exn:fail:abort` (Services, "Cancellation"). It requires only `racket/base`, so it is the first module of this package to be delivered. |
| `dsh-llm/jrecord` | `define-jrecord`, `define-junion` (Data, "Record declarations"). |
| `dsh-llm/messages` | Content blocks, message sources, messages, request-only user input, tool schemas, stream chunks, finish reasons, token usage, replay envelope; the compact timed stream (accumulator, expansion, readers); the assembler. |
| `dsh-llm/errors` | `exn:fail:llm`, failure records, the code table, `normalize-llm-failure`, the context-overflow and quota classifiers, `error-chain`. |
| `dsh-llm/stream` | `chunk-stream`: the pull-based stream type. |
| `dsh-llm/llm` | Service Definition for `llm`: `gen:llm-adapter`, `llm-request`, call config, prepared calls, every `llm-…` service procedure, the events `llm/stream`, `llm/adapters-updated`, `llm/models-updated`. |
| `dsh-llm/content` | Model-visible handle texts; the request projections (files, text-only images, offloaded images, tool updates); `required-image-offload`. |
| `dsh-llm/retry-policy` | `retry-policy` struct, `retry-policy-schema`, `resolve-retry-policy`, `retry-policy-key`, `retry-code-choices`. |
| `dsh-llm/attribution` | `app-identity`, `user-agent`, `attribution-headers`, `normalize-api-key`, `assert-usable-api-key`. |
| `dsh-llm/ports` | Generic interfaces for the services of later packages that this package consumes (Services, "Ports"). |
| `dsh-llm/adapter-kit` | Helpers shared by wire adapters: the idle watchdog, `check-cancel!`, config reads through volatile references. It re-exports `cancelled?` of `dsh-llm/cancel` and defines no predicate of its own. |
| `dsh-llm/http` | The HTTP/1.1 client: streaming requests, proxy routing, TLS, redirect refusal, truncated-body detection. |
| `dsh-llm/sse` | The incremental server-sent-events parser. |
| `dsh-llm/deepseek` | Re-exports the submodules `deepseek/config` (shared config fields, `resolve-deepseek-options`), `deepseek/serialize`, `deepseek/translate`, `deepseek/transport` (error classifier), `deepseek/adapter` (`make-deepseek-adapter`), `deepseek/host` (`register-deepseek-provider!`, `make-model-listing-cache`), `deepseek/listing`, `deepseek/listed-catalog`, `deepseek/files`, `deepseek/image-tokens`. |
| `dsh-llm/extensions` | Service Definition for `deepseekLlmApiExtensions`. |
| `dsh-llm/retry` | The retry executor, the `llm/retry` and `llm/retry-started` session event declarations, the `llmRetry` projection definition. |
| `dsh-llm/token-meter` | Service Definition for `tokenMeter`; the estimator; the four projection definitions; `derive-turn-token-usage`. |
| `dsh-llm/pi-ai` | Re-exports `pi-ai/config` (schema, profile resolution), `pi-ai/provider-data`, `pi-ai/adapter`, `pi-ai/openai-completions`, `pi-ai/anthropic-messages`, `pi-ai/discovery`. |
| `dsh-llm/replay` | Fixture parsing, script derivation, override documents, placeholders, `install-llm-replay!`. |
| `dsh-llm/testing/mock` | `make-mock-llm` and script helpers. |
| `dsh-llm/testing/mock-server` | `start-mock-llm-server`. `dsh-llm/testing/mock-server-cli` is its command line (a `main` submodule). |
| `dsh-llm/plugin/<short-name>` | One module per plugin, each providing `plugin` (Plugins). |
| `dsh-llm/plugins` | `plugin-table`: the list of `(cons npm-name module-path)` for every row of Plugins. |

Private modules live under `private/` and under each directory's own `private/`; no other package requires them. Suggested private split: `private/vocab.rkt`, `private/assembler.rkt`, `private/assistant-stream.rkt` (re-exported by `messages`), `private/registry.rkt`, `private/boundary.rkt` (the adapter boundary), `private/anonymous-user-id.rkt`, `deepseek/private/*`, `pi-ai/private/*`.

## Data

### Representation: jvalues with the dsh field names

**Every value in this vocabulary that dsh writes to a session log, sends over a wire, or compares as JSON is a jvalue: a `jobject` with exactly the dsh field names, in the key order dsh writes.** That covers messages, message sources, content blocks, tool schemas, tool history, stream chunks, finish reasons, token usage, failures, replay envelopes, compact stream records, provider and model metadata, call configs, retry and replay entries. There is no struct layer over them and no codec: the value a consumer holds is the value that is logged. `dsh-session` and `dsh-tools` may read and build these values directly with `jref` and `jobj`; the constructors, predicates, accessors and `match` patterns below are conveniences that fix key order and spelling.

Reasons. (1) The session log is the durable form and its key order is compared byte for byte; a struct layer would need an order-preserving codec for every type and would still have to carry unknown keys. (2) Four of the unions are open in dsh (`ContentBlockMap`, `MessageSourceMap`, `FinishReasonMap`, `ModelModalityMap`): other packages add variants, and recorded fixtures carry spellings from older generations. A jobject passes an unknown variant through unchanged; a closed struct cannot. (3) Replay state and the raw `chunk` records are opaque JSON that must survive untouched. (4) jobjects are immutable, so the dsh rule "requests are deep-frozen" holds by construction and `structuredClone` has no counterpart.

Values that hold something JSON cannot (an evt, a procedure, an adapter) or that never leave the process are structs: `llm-request`, `prepared-call`, `prepared-adapter-call`, `chunk-stream`, `retry-policy`, the registration handles, adapter option records. They are listed under "Process-local structs".

Absent optional fields are absent keys. No field ever holds `(void)`; `'null` appears only where dsh writes `null` (projection states).

### Record declarations (`dsh-llm/jrecord`)

```racket
(define-jrecord id
  (~optional (~seq #:tag [tag-key tag-string]))
  [field-id json-key contract-expr (~optional #:optional)] ...+)
```

Defines, for a jobject-shaped record:

- `id`: a constructor and a `match` expander. As a procedure it takes the required fields positionally in declaration order and each optional field as a keyword argument named after `field-id` whose default is `absent`, the marker exported by `dsh-session` (omitted or `absent` means the key is not written; any other value, including `#f`, is written). It returns a `jobject` whose keys are the tag (if any) first, then the present fields in declaration order. Each argument is checked against its contract; a failure raises `exn:fail:contract` naming `id` and the field.
- `id?`: true for a jobject or hash whose `tag-key` equals `tag-string`; for an untagged record, true when every required key is present.
- `id-field-id` for each field: `(id-field-id v)` for a required field (raises `exn:fail:contract` when the key is absent); `(id-field-id v [default #f])` for an optional field.
- As a pattern, `(id pat ...)` matches the required fields positionally and accepts trailing `#:field-id pat` clauses for optional fields (matched against `#f` when absent). It matches any jobject or hash that satisfies `id?`.

```racket
(define-junion union-id #:tag tag-key (~optional #:open) (variant ...+))   ; variant = jrecord-id | tag-string
```

Defines `union-id?` (a jobject whose tag is one of the variants; with `#:open`, any jobject that has the tag key with a string value) and the form

```racket
(union-id-case expr
  [(jrecord-id pat ...) body ...+] ...        ; or [tag-string body ...+]
  (~optional [#:else body ...+]))
```

A closed union's `-case` without `#:else` is a syntax error unless every variant has a clause; the message lists the missing variants. At run time a value whose tag matches no clause raises `exn:fail:contract` `union-id-case: unknown <tag-key> "<value>"`. An open union's `-case` requires `#:else`. Both macros use `syntax/parse`; a duplicate field, a duplicate variant or an unknown keyword is a syntax error naming the clause.

### Identifiers

`MessageId`, `ToolCallId`, `ProviderRequestId`, `LlmAttemptId`, `ReasoningEffortId`, `RetryId` and `SessionId` are strings. Contracts use `non-empty-string?` where dsh requires non-empty. `(new-message-id) -> string?` returns a random version-4 UUID in lowercase (`dsh-util`'s UUID helper).

### Content blocks (`dsh-llm/messages`)

Tagged on `type`. Keys in the order shown.

| jrecord | `type` | Fields (json key: contract) |
|---|---|---|
| `text-block` | `text` | `text`: `string?` |
| `reasoning-block` | `reasoning` | `text`: `string?` |
| `image-block` | `image` | `attachment`: image ref jobject; `offloaded` (optional): `#t` |
| `file-block` | `file` | `attachment`: file ref jobject |
| `tool-call-block` | `tool-call` | `id`: `string?`; `name`: `string?`; `arguments`: `string?` (raw JSON text exactly as the model produced it) |
| `tool-addition-block` | `tool-addition` | `toolName`: `string?` (accessor `tool-addition-block-tool-name`; a key `tool` must be absent) |
| `tool-removal-block` | `tool-removal` | `toolName`: `string?` |

`(define-junion content-block #:tag type #:open (text-block reasoning-block image-block file-block tool-call-block tool-addition-block tool-removal-block))`. An image ref is `{attachmentId, mediaType, bytes, width, height, name?, originalDimensions?}` and a file ref is `{attachmentId, name, bytes}`, both owned by the attachment package (`packages/attachment/attachment/src/types.ts`); this package reads those keys and never builds refs. `(content-has-image? blocks)` and `(content-has-file? blocks)` are provided.

### Message sources

Tagged on `kind`, open. Built-ins: `user-source` `{kind: "user"}`; `model-source` `{kind: "model", provider, model, replayState?}` (constructor `(model-source provider model #:replay-state rs)`); `tool-source` `{kind: "tool", callId}`; `system-prompt-source` `{kind: "system-prompt"}`. Any source may also carry `form` (`"instructions" | "catalog" | "snapshot" | "notice" | "relay" | "recall"`), with `sections: [{name, text}]` required for `snapshot` and `summary` required for `notice`. `context-summary-max-chars` is `120`; `(bound-context-summary s)` returns `s` when `(utf16-length s)` is at most 120, else `(utf16-substring s 0 119)` followed by `…` (U+2026).

### Messages

A message is a jobject with `id`, `role`, `content` (list of blocks), `source`; a tool message also has `toolCallId` and `isError`. The key order is the order the dsh constructors produce (`packages/llm/llm/src/message.ts`), which recorded fixtures confirm:

| Constructor | Result keys, in order |
|---|---|
| `(make-system-message text #:id [id (new-message-id)])` | `role: "system"`, `content` (`'()` when `text` is `""`, else one text block), `source: {kind: "system-prompt"}`, `id` |
| `(make-developer-message #:content blocks #:source source #:id [id])` | `content`, `source`, `role: "developer"`, `id` |
| `(make-user-message #:content blocks #:source [source (user-source)] #:id [id])` | `content`, `source`, `role: "user"`, `id` |
| `(make-assistant-message #:content blocks #:provider p #:model m #:replay-state [rs absent] #:id [id])` | `role: "assistant"`, `content`, `source: {kind: "model", provider, model, replayState?}`, `id` |
| `(make-tool-result-message #:call-id call-id #:content blocks #:error? boolean #:id [id])` | `role: "tool"`, `source: {kind: "tool", callId}`, `toolCallId`, `content`, `isError`, `id` |
| `(make-message partial #:id [id])` | `partial` (a jobject with `role`, `content`, `source` and no `id`) with `id` appended last |
| `(make-request-user-input blocks)` | `role: "user"`, `content` (request-only: no `id`, no `source`) |

Key order of developer and user messages. dsh `createDeveloperMessage` and `createUserMessage` spread their input first and add `role` and `id` after it (`message.ts:235-253`), so the logged order of `content` and `source` is the order of the caller's object literal. `make-developer-message` and `make-user-message` always write `content` before `source`, which is the order of every user message the loop and the testkits write. A producer whose dsh call site writes `source` first builds the message with `make-message` over a partial in that order, `(make-message (jobj [source s] [content blocks] [role "developer"]))`, which gives `source`, `content`, `role`, `id`. The one such producer in wave 3 is the loop's tool-registry `developer/message` (`packages/core/agent-loop/src/agent.ts:708`; recorded in `snapshots/session/dynamic-tool-updates/session.v4.jsonl`). A package that ports another producer checks the order of that producer's literal.

Accessors: `(message-id m)`, `(message-role m)` (a string), `(message-content m)`, `(message-source m)`, `(message-tool-call-id m)`, `(message-error m [default #f])`. Predicates: `message?` (has string `id`, a known `role`, list `content`, jobject `source`), `request-message?` (a message or a request-only user input), `system-message?`, `developer-message?`, `user-message?`, `assistant-message?`, `tool-message?`. `(define-junion message #:tag role ("system" "developer" "user" "assistant" "tool"))` gives the closed `message-case`; the predicate that declaration generates is not exported, so the exported `message?` is the stricter one described here. Content rules per role are R6 Formats 1; constructors check only that `content` is a list of jobjects with a string `type`.

### Tool schemas and tool history

`tool-schema` (untagged): `name`, `description`, `parameters` (jobject), `deferLoading` (optional, `#t`). Marking a tool deferred is `(jset tool 'deferLoading #t)` (the key goes last); clearing it is `(jremove tool 'deferLoading)`. Tool history is `{tools: [tool-schema…], updates: [{messageId, additions: [tool-schema…]}…]}`.

### Stream chunks

Tagged on `type`; closed union `(define-junion stream-chunk #:tag type (block-start-chunk text-delta-chunk reasoning-delta-chunk tool-call-delta-chunk block-end-chunk usage-chunk finish-chunk))`.

| jrecord | `type` | Fields in key order |
|---|---|---|
| `block-start-chunk` | `block-start` | `index`: `exact-nonnegative-integer?`; `blockType`: `string?` |
| `text-delta-chunk` | `text-delta` | `index`; `text`: `string?` |
| `reasoning-delta-chunk` | `reasoning-delta` | `index`; `text` |
| `tool-call-delta-chunk` | `tool-call-delta` | `index`; `id`: `string?`; `name` (optional): `string?`; `argumentsDelta`: `string?` |
| `block-end-chunk` | `block-end` | `index`; `block`: the complete content block |
| `usage-chunk` | `usage` | `usage`: token usage |
| `finish-chunk` | `finish` | `reason`: finish reason; `replayState` (optional): replay envelope |

Finish reasons are tagged on `kind`, open: `finish-stop` `{kind: "stop"}`, `finish-tool-calls` `{kind: "tool-calls"}`, `finish-max-tokens` `{kind: "max-tokens"}`, `finish-aborted` `{kind: "aborted", failure}`, `finish-error` `{kind: "error", failure}`. `(finish-reason-kind r) -> string?`.

`token-usage` (untagged): `inputTokens`, `outputTokens`, `totalTokens?`, `cacheReadTokens?`, `cacheWriteTokens?`, `reasoningTokens?`, all exact non-negative integers. Buckets are disjoint: `inputTokens` is uncached input; billed input is the sum of the three input buckets; `reasoningTokens` is inside `outputTokens`. Usage passes through this package as data: recorded fixtures carry key orders and fields from earlier adapters and must not be normalised. An adapter that builds usage states its own key order (Behaviour D10, P8).

A replay envelope is `{response: jvalue, blocks?: [jvalue…]}`; both halves are opaque outside the adapter that wrote them.

### Failures and errors (`dsh-llm/errors`)

`llm-failure` (untagged), keys in order: `message` (non-empty string), `code` (non-empty string), `status?` (integer 100 to 599), `providerRetryAfterMs?` (positive real), `requestId?` (non-empty string), `offloadImages?` (positive exact integer).

```racket
(struct exn:fail:llm exn:fail:harness (failure))          ; failure : llm-failure; (exn:fail:harness-code e) equals its code
(make-llm-error code message #:status [s] #:retry-after-ms [ms] #:request-id [id] #:offload-images [n] #:cause [cause #f]) -> exn:fail:llm?
(raise-llm-error code message #:status … #:cause …) -> none/c
(llm-failure->exn failure #:cause [cause #f]) -> exn:fail:llm?       ; LlmError.fromFailure
(normalize-llm-failure v) -> llm-failure?
(llm-failure-codes) -> (listof symbol?)                              ; the table of R6 Formats 3, in that order
(context-window-exceeded? detail) -> boolean?
(quota-exceeded? detail) -> boolean?
(error-chain v) -> string?
```

`code` is a symbol or string on input and always a string in the failure. `make-llm-error` validates the bounds above and raises `exn:fail:contract` with the dsh messages (`LlmError message must be a non-empty string`, `LlmError code must be a non-empty string`, `LlmError status must be an integer from 100 through 599`, `LlmError providerRetryAfterMs must be a positive finite number`, `LlmError requestId must be a non-empty string`). `exn:fail:llm` is constructed only through these procedures, so no call site depends on the field list of `exn:fail:harness`. Its dsh error name, where `exn:fail:harness` records one (the tool pipeline persists `{name, code}`), is `LlmError`. Any code string is legal (`HTTP_<status>`, codes of other providers); the table is documentation and the source of `retry-code-choices` (`EMPTY_RESPONSE`, `MALFORMED_RESPONSE`, `QUOTA`, `RATE_LIMIT`, `SERVER`, `STREAM_CLOSED`, `TIMEOUT`, `TRANSPORT`, in that order).

### Compact timed stream records

The value of `stream` inside the session events `assistant/message` and `assistant/attempt` is a list of records, tagged on `type`, closed union `stream-record`:

| jrecord | `type` | Keys in order (exact key set) |
|---|---|---|
| `text-chunks-record` | `text-chunks` | `time0`, `index`, `dt`, `texts` |
| `reasoning-chunks-record` | `reasoning-chunks` | `time0`, `index`, `dt`, `texts` |
| `tool-call-chunks-record` | `tool-call-chunks` | `time0`, `index`, `dt`, `id`, `name?`, `args` |
| `raw-chunk-record` | `chunk` | `time`, `chunk` |

`time0` and `time` are safe integers (session clock milliseconds); `dt` is a list of safe integers, one fewer than the members; `texts` and `args` hold one string per original delta. A *timed chunk* is `{time, chunk}`. "Safe integer" is `safe-integer?` of `dsh-session` (magnitude at most 2^53 - 1); this package does not define its own.

### Provider and model metadata

All jobjects, keys in the order listed, optional keys present only when defined.

- Provider info: `{id, name}`.
- Model info: `{provider, id, name, description?, inputModalities?, badge?}`; `badge` is `{text, tone}` with `text` a string or a jobject of language to string that includes `en`, and `tone` one of `neutral`, `info`, `success`, `warning`.
- Resolved model info: `{provider, id, name, description?, inputModalities?, context?: {contextWindow}, defaultMaxTokens?, systemPromptUpdate?, toolUpdate?, reasoning?: {efforts: [{id, name, description?}…], defaultEffort?}}`. `systemPromptUpdate` is `"in-history"`; `toolUpdate` is `"in-history"` or `"addition-only"`.
- Configurable provider (directory entry): `{provider, displayName, settingsNs, settingsPath: [string…], declared?, defaultBaseURL?, baseURLEnv?: [string…], nativeAuth?: {env: [string…], oauth}, error?}`.
- Discovery request: `{provider?, baseURL?, api?, apiKey?}`. Discovered model: `{id, name?, contextWindow?, maxTokens?, inputModalities?}`.
- Image request target: `{width, height, maxBytes}`. Image request price: `{visualTokens, text}`. Image request budget: `{representation: "raw" | "base64", maxBytes?, maxImages?, byteQuantum?, countQuantum?}`.
- Call config: `{provider, model, reasoningEffort?, temperature?, maxTokens?, stop?}`. A default that the runtime materialises is added with `jset`, so it goes after the keys the caller supplied. `(call-config-equal? a b)` compares the six fields; `stop` compares element by element and an absent `stop` equals only an absent `stop`.

### Process-local structs

```racket
(struct llm-request (provider model reasoning-effort messages system tools tool-history
                     temperature max-tokens stop cancel session-id purpose))        ; plus a private loop mark
(make-llm-request #:provider string? #:model string? #:messages (listof request-message?)
                  #:reasoning-effort [#f] #:system [#f] #:tools [#f] #:tool-history [#f]
                  #:temperature [#f] #:max-tokens [#f] #:stop [#f]
                  #:cancel [#f] #:session-id [#f] #:purpose [#f]) -> llm-request?
(llm-request-set req #:messages … #:tools … …) -> llm-request?      ; functional update of any field; the result is never loop-marked
(llm-request-call-config req) -> jobject?                            ; keys provider, model, then the defined controls in the order above
(llm-request-with-call-config req config) -> llm-request?
(mark-agent-loop-request req) -> llm-request?                        ; a copy carrying the loop mark
(agent-loop-request? req) -> boolean?
```

`#f` is "undefined" for every optional field (`tools` distinguishes `#f` from `'()`: an empty list is sent as an empty tool array). `cancel` is the cancel evt in place of `signal`. `purpose` is a string; `"compaction"` is the only value this package branches on. The loop mark replaces dsh's weak set of object identities: the loop calls `mark-agent-loop-request` on the request it built, listeners of `llm/stream` see that value, and any derived request (made with `llm-request-set` by a listener or by the adapter boundary) is unmarked, as a spread copy is in dsh.

```racket
(struct prepared-adapter-call (model stream))     ; model : resolved model info; stream : (-> llm-request? chunk-stream?)
(struct prepared-call (config retry-policy context input-modalities system-prompt-update tool-update adapter-defaults))  ; opaque
(prepared-call-stream pc request) -> chunk-stream?
```

`prepared-call` accessors return: `config` a call config with defaults materialised; `retry-policy` a `retry-policy`; `context` `{contextWindow}` or `#f`; `input-modalities` a list of strings or `#f`; `system-prompt-update` and `tool-update` a string or `#f`; `adapter-defaults` a jobject with `reasoningEffort: #t` and `maxTokens: #t`, in that key order, each present only when the adapter, not the caller, supplied the value. The loop writes this jobject into `request/header` unchanged, so the order is durable (`{"reasoningEffort":true,"maxTokens":true}` in recorded fixtures). A prepared call also keeps the context `llm-prepare-call` was called through; `prepared-call-stream` dispatches `llm/stream` on that context.

```racket
(struct retry-policy (mode max-retries retryable-codes initial-delay-ms max-delay-ms jitter-ratio) #:transparent)
```

`mode` is `'normal` or `'always`; `max-retries` and `retryable-codes` are `#f` in always mode. Two policies are the same policy when `equal?`.

`chunk-stream` is under Services ("Streams"). The registration handles `adapter-registration` and `directory-registration` are applicable disposers with a `replace!` operation (Services).

### Session events declared here (`dsh-llm/retry`)

Declared with `define-session-event` of `dsh-session` as `llm/retry` (fields `retry-id "retryId"`, `turn`, `step`, `provider`, `mode`, `policy-key "policyKey"`, `retry`, `max-retries "maxRetries"` optional, `delay-ms "delayMs"`, `failure`) and `llm/retry-started` (fields `retry-id "retryId"`, `turn`, `step`, `retry`); neither is a surface event or a plugin record. The constructors return the `session-event-input` passed to `session-append!`. `data` keys in write order:

- `llm/retry`, normal mode: `retryId`, `turn`, `step`, `provider`, `mode: "normal"`, `policyKey`, `retry`, `maxRetries`, `delayMs`, `failure`. Always mode: the same without `maxRetries` and with `mode: "always"`.
- `llm/retry-started`: `retryId`, `turn`, `step`, `retry`.

`retryId` is one random UUID shared by every retry of one step's chain. `policyKey` is the exact string of Behaviour E2. `delayMs` is written as the number computed in E5 (a flonum prints through `jvalue->string` exactly as JavaScript prints it).

### Projection states

States are jvalues with these keys; `null` is `'null`. The fold rules are Behaviour E7 and F3.

| Key | `stateVersion` | State | Wire view |
|---|---|---|---|
| `llmRetry` | 1 | `{<stateKey>: {retry, retryId}}`, initially `{}`; `stateKey` is `(jvalue->string (list provider policyKey))` | none |
| `tokenMeasurement` | 2 | `{headerSeq, stepStart: {turn, step} or null, anchor: {headerSeq, assistantTokens, usage or null} or null, invalidSeq}` with `null` for unset sequence numbers | none |
| `tokenUsage` | 2 | `{totals: {uncachedInputTokens, outputTokens, cacheReadTokens, cacheWriteTokens}, last: {turn, step, buckets} or null}` | `totals` |
| `contextPressure` | 5 | `{contextWindow?, pressureTokens?, surfaceTokens, sampledSurfaceTokens?, claim?: {start, end, tokens}}`, initially `{surfaceTokens: 0}` | `{contextWindow?, pressureTokens?, projectedTokens?}`; excluded from summaries |
| `contextBreakdown` | 6 | `{systems: [{seq, tokens}…], surfaceTokens, claim?: {start, end, tokens, systemSeqs}, breakdown: {systemTokens, toolsTokens, messageTokens}}` | `breakdown`; excluded from summaries |

### Token meter results

A token measurement is the jobject `{logRevision, baseline, surfaceDeltaTokens, totalTokens, surfaceTokens, nodes: [{seq, tokens, heuristicTokens}…]}` where `baseline` is `{kind: "none", tokens: 0}`, `{kind: "estimated", tokens}` or `{kind: "usage", tokens, usage}`.

### Replay entries and override documents (`dsh-llm/replay`)

A replay entry is one of `{kind: "chunks", chunks}`, `{kind: "throw", chunks, message, code, accepted?}`, `{kind: "hang", readyFile?}`, each with that exact key set. An override document is a list of entries, or `{patches: [{at, entry}…]}`. A recorded session script is `(struct recorded-session-script (recorded-id created-at entries primary?))`; the name `session-script` belongs to the scripted-session format of `dsh-test-support/script`, which a test may require beside this module. A parsed fixture is `(struct session-fixture (id created-at inherited-event-count events))` with `events` a list of `session-event?` values of `dsh-session`.

### DeepSeek wire records

The request body and SSE events are specified in Behaviour D with key orders. The upload index file and Files API objects are R6 Formats 8 unchanged. The replay envelope of this adapter is `{response: {kind: "deepseek-messages", version: 1, model}, blocks: [{type: "text"} | {type: "reasoning", signature?} | {type: "tool-call"}…]}`.

## Services

### Cancellation (`dsh-llm/cancel`)

```racket
(make-cancel-source) -> cancel-source?              ; AbortController
(cancel-source? v) -> boolean?
(cancel-source-evt src) -> evt?                     ; AbortSignal
(cancel! src [reason (make-abort-error)]) -> void?  ; the first call fixes the reason; later calls do nothing
(cancelled? c) -> boolean?                          ; c : (or/c evt? #f); polls, never blocks; #f is never cancelled
(cancel-reason c) -> any/c                          ; the reason, or #f when not cancelled
(check-cancelled! c) -> void?                       ; raises the reason when cancelled (throwIfAborted)
(cancel-evt-any c ...) -> evt?                      ; ready when any argument is; #f arguments are ignored; the reason is that of the first ready argument in argument order
never-cancelled                                     ; never-evt
(struct exn:fail:abort exn:fail ())                 ; the counterpart of an Error named AbortError
(make-abort-error [message "This operation was aborted"]) -> exn:fail:abort?
```

A cancel evt is any Racket `evt` that, once ready, stays ready; its synchronization result is the abort reason. The reason is any value: an exception, or plain data such as the cancel cause jobject of `dsh-agent`. `check-cancelled!` raises the reason itself with `raise`. These procedures touch no harness state and may be called from any thread. The module has no dsh counterpart as a package; it is the Racket form of `AbortController`, `AbortSignal`, `AbortSignal.any` and `throwIfAborted`.

Two checks exist on purpose and must not be confused. `check-cancelled!` (this module) raises the caller's reason and is what the loop and the tool pipeline use. `check-cancel!` (`dsh-llm/adapter-kit`) raises an `exn:fail:llm` with code `ABORTED` and is what the runtime and the adapters use, because a model call reports cancellation as a coded failure.

### Waiting and cancellation in this package

Every procedure that can wait says how it is cancelled:

- `llm-discover-models`, `llm-remote-discover-models`, `llm-resolve-model-info`, `llm-resolve-call-config`, `llm-prepare-call`: the `#:cancel` evt; they raise code `ABORTED`.
- `llm-stream`, `prepared-call-stream` and every `chunk-stream-next!` on their results: `(llm-request-cancel request)`, and closing the stream, which shuts down the producer's custodian.
- `deepseek-extensions-prepare`: the `cancel` field of the `extension-request`.
- `http-request`: `#:cancel`; body reads: the `await-evt` argument.
- The retry recovery of `make-retry-recovery`: the `cancel` of the payload and the plugin's disposal.
- Replay and mock playback: the request's cancel evt.
- `attachment-read-image-request`: its `cancel` argument.
- `llm-list-models`, `projection-register!`, `credential-resolve`, `account-resolve-token`, `install-llm-replay!` and `load-session-scripts` take no cancel evt, as their dsh counterparts take no signal. They are cancelled only by a break delivered to the calling task, which propagates from the wait (cordis-kernel section 2 rule 4); they hold nothing across the wait that the caller's custodian does not reclaim.

### Streams (`dsh-llm/stream`)

A model call's output is a `chunk-stream`: a single-consumer, pull-based stream of stream-chunk jobjects. It replaces `AsyncIterable<StreamChunk>`.

```racket
(chunk-stream? v) -> boolean?
(make-chunk-stream next #:close [close void]) -> chunk-stream?        ; next : (-> (or/c jobject? eof-object?)); close : (-> any)
(make-producer-stream producer #:on-close [on-close void]) -> chunk-stream?   ; producer : (-> (-> jobject? void?) any)
(chunk-stream-next! s) -> (or/c jobject? eof-object?)
(chunk-stream-close! s) -> void?
(chunk-stream-closed? s) -> boolean?
(in-chunk-stream s) -> sequence?
(call-with-chunk-stream s proc) -> any                                 ; (proc s); closes s on every exit, including a break
(list->chunk-stream chunks) -> chunk-stream?
(chunk-stream->list s) -> (listof jobject?)                            ; pulls to the end and closes
(chunk-stream-map proc s) -> chunk-stream?                             ; closing the result closes s
```

1. `chunk-stream-next!` runs the producer in the calling task until it has the next chunk and returns it, or returns `eof` at the end. It may `await`; the baton is released while it waits. It is the only way chunks move: a producer never runs ahead of its consumer.
2. Pulls are sequential. A pull while another pull on the same stream is outstanding raises `exn:fail:contract` `chunk-stream-next!: a pull is already outstanding`.
3. An exception raised by the producer propagates from `chunk-stream-next!`; the stream is then closed. After `eof`, after an exception and after `chunk-stream-close!`, every pull returns `eof`.
4. `chunk-stream-close!` is idempotent and runs `close` at most once. It is called automatically at `eof` and after an exception. A consumer that stops before `eof` must close the stream (`call-with-chunk-stream` does it); `in-chunk-stream` cannot detect an early exit from a `for` loop.
5. `make-producer-stream`: `producer` is called with one argument `emit` on the first pull, in the pulling task. `(emit chunk)` hands the chunk to the pull in progress and suspends the producer until the next pull. A normal return ends the stream. The producer body runs with `current-custodian` set to a fresh custodian created at the first pull as a child of the then-current custodian; closing the stream calls `on-close` and then shuts that custodian down. A producer suspended at `emit` when the stream is closed is abandoned: its `dynamic-wind` post thunks do not run, so every resource it holds must be owned by that custodian or released in `on-close`. Implementation: `racket/generator`; no extra thread.
6. A break delivered to the pulling task propagates out of `chunk-stream-next!` like any break (after the producer's own handlers ran) and closes the stream.

### The adapter seam (`dsh-llm/llm`)

```racket
(define-generics llm-adapter
  (adapter-provider-info llm-adapter provider)                          ; -> provider info
  (adapter-retry-policy llm-adapter provider)                           ; -> (or/c retry-policy? #f)
  (adapter-image-request-pricing llm-adapter provider model)            ; -> (or/c #f (-> (listof jobject?) (listof jobject?)))
  (adapter-image-request-target llm-adapter provider model image-ref)   ; -> image request target
  (adapter-list-models llm-adapter provider)                            ; -> (listof model info)
  (adapter-resolve-model llm-adapter provider model cancel)             ; -> resolved model info (the capability query)
  (adapter-prepare-call llm-adapter provider model cancel)              ; -> prepared-adapter-call?
  (adapter-stream llm-adapter request))                                 ; -> chunk-stream?
(llm-adapter? v) -> boolean?
(make-llm-adapter #:stream stream-proc #:provider-info [f] #:retry-policy [f] #:image-request-pricing [f]
                  #:image-request-target [f] #:list-models [f] #:resolve-model [f] #:prepare-call [f]) -> llm-adapter?
```

Only `adapter-stream` is required. The fallbacks are: provider info `{id: provider, name: provider}`; retry policy `#f` (normal defaults); pricing `#f`; target `{width, height, maxBytes}` from the ref's `width`, `height`, `bytes`; models `'()`; resolved model `{provider, id: model, name: model}`; prepare-call `(prepared-adapter-call (adapter-resolve-model a provider model cancel) (lambda (request) (adapter-stream a request)))`. `make-llm-adapter` builds an adapter from procedures with the same fallbacks; each procedure takes the same arguments without the adapter.

Obligations of every adapter (R6 "Adapter contract"; `docs/subsystems/llm-streaming.md`):

1. The stream emits `usage` before `finish` and nothing after `finish`.
2. Tool-call `arguments` are raw JSON strings end to end; fragments stream as `argumentsDelta`.
3. Block `index` values are dense, allocated in first-seen order, and reused for every delta of that block.
4. A failure is either raised from the stream (an `exn:fail:llm` with a stable code) or delivered as a final `finish` chunk with kind `error` or `aborted`.
5. One call to `adapter-stream` is one provider attempt. Adapters never retry.
6. The adapter honours `(llm-request-cancel request)`: after it fires the stream raises code `ABORTED` promptly. Idle stalls are bounded by the idle watchdog; expiry raises code `TIMEOUT`.
7. Context overflow surfaces as `CONTEXT_WINDOW_EXCEEDED`; a normal stop with zero content blocks as `EMPTY_RESPONSE`.
8. Every provider HTTP request carries `(attribution-headers)`.
9. A request option the provider cannot honour raises `UNSUPPORTED_OPTION`.
10. Replay state is private to the adapter that wrote it; only the `{response, blocks?}` split is shared.
11. `adapter-image-request-pricing` and its result perform no I/O and never `await`.

### `llm` (key `'llm`)

`(define-service llm 'llm)` in `dsh-llm/llm` gives `llm-ref`, `llm-get`, `provide-llm`. The value is an opaque `llm-runtime` created by the plugin `dsh-llm/plugin/llm`. State: `adapters` (route to registration `(adapter provider-info retry-policy)`, in registration order), `directory` (provider to entry, in declaration order), `discoveries` (settings namespace to procedure). No config.

| Procedure | Contract and semantics |
|---|---|
| `(llm-register-adapter! x providers adapter) -> adapter-registration?` | `providers : (listof string?)`, `adapter : llm-adapter?`. Registers an effect labelled `llm.registerAdapter()` on `(use-context x)`; the routes are released when that fiber unloads or when the result is applied. All or nothing (Behaviour A2). Errors: `INVALID_ADAPTER`, `DUPLICATE_ADAPTER`. Emits `llm/adapters-updated` once after the commit and once at release. |
| `(adapter-registration-replace! reg providers) -> void?` | Atomic swap of this registration's routes (A3). `'()` is legal. Errors: the two above; `REGISTRATION_DISPOSED` after release. One `llm/adapters-updated`. |
| `(llm-list-providers x) -> (listof jobject?)` | Provider infos in registration order. |
| `(llm-register-configurable-providers! x entries) -> directory-registration?` | Effect labelled `llm.registerConfigurableProviders()` on `(use-context x)` (A4). Errors: `INVALID_DIRECTORY`, `DUPLICATE_DIRECTORY`. Emits `llm/adapters-updated` on commit and on release. |
| `(directory-registration-replace! reg entries) -> void?` | Validate-then-swap; `'()` legal; `REGISTRATION_DISPOSED` after release. |
| `(llm-list-configurable-providers x) -> (listof jobject?)` | Entries in declaration order. |
| `(llm-register-model-discovery! x settings-ns discover) -> disposer?` | `discover : (-> jobject? (or/c evt? #f) (listof jobject?))` (request, cancel). Effect labelled `llm.registerModelDiscovery()`. Errors: `INVALID_DISCOVERY` (empty namespace), `DUPLICATE_DISCOVERY`. |
| `(llm-discover-models x settings-ns request #:cancel [cancel #f]) -> (listof jobject?)` | A5. Errors: `NO_DISCOVERY`, `INVALID_DISCOVERY`, whatever `discover` raises. |
| `(llm-remote-discover-models x settings-ns request #:cancel [cancel #f])` | As above, but any failure is re-raised as `exn:fail:harness` with code `llm/model-discovery-rejected`, the original message, and details `{settingsNs, baseURL?}`. This is the form `dsh-web` exposes. |
| `(llm-provider-retry-policy x provider) -> retry-policy?` | The policy captured at registration or replace. `NO_ADAPTER` for an unknown route. |
| `(llm-image-request-pricing x provider model) -> (or/c procedure? #f)` | The adapter's pricing; `#f` for an unknown route (never raises). No await. |
| `(llm-image-request-target x provider model image-ref) -> jobject?` | Delegates to the adapter. `NO_ADAPTER`. |
| `(llm-file-request-text x file-ref) -> string?` | `(file-handle-text file-ref path)` with `path` from A10 step 4. Never raises for a missing service or a malformed ref. |
| `(llm-list-models x provider) -> (listof jobject?)` | A6. `NO_ADAPTER`, `INVALID_CATALOG`. |
| `(llm-resolve-model-info x provider model #:cancel [cancel #f]) -> jobject?` | `adapter-resolve-model`, then A7. Never includes `badge`. `NO_ADAPTER` and the four `INVALID_MODEL_*` codes. |
| `(llm-resolve-call-config x config #:cancel [cancel #f]) -> jobject?` | Resolve model info, then A8. Returns the config with defaults materialised; binds no dispatch. `UNSUPPORTED_REASONING_EFFORT`. |
| `(llm-prepare-call x config #:cancel [cancel #f] #:configure [configure #f]) -> prepared-call?` | A9. `configure : (-> jobject? jobject? jobject?)` (controls, resolved model info) returns controls; synchronous and pure. |
| `(prepared-call-stream pc request) -> chunk-stream?` | Once only. Raises `INVALID_PREPARED_CALL` at call time on reuse or when `(call-config-equal? (llm-request-call-config request) config)` is false. Otherwise as `llm-stream` with the captured registration. |
| `(llm-stream x request) -> chunk-stream?` | Dispatches the `llm/stream` waterfall on `(use-context x)` with the adapter boundary as the innermost step (A10). Listeners run during this call; adapter work starts at the first pull. |

`llm-remote-methods` is a list of `(cons dsh-name procedure)` for `listProviders`, `listConfigurableProviders`, `discoverModels` (the last bound to `llm-remote-discover-models`), for the remote layer of `dsh-web`.

Model selection. `(llm-request-provider request)` selects the adapter and nothing else; `model` is passed through, so any model id is routable on a registered provider. The catalog from `llm-list-models` is advisory. Which provider and model an agent uses is session state owned by `dsh-agent`. Reasoning effort is an opaque per-model id: each adapter lists its efforts in increasing order with an optional default, and the runtime checks membership without clamping or aliasing.

### `deepseekLlmApiExtensions` (key `'deepseekLlmApiExtensions`)

`(define-service deepseek-extensions 'deepseekLlmApiExtensions)` in `dsh-llm/extensions`.

```racket
(struct extension-request (body session-id purpose cancel))     ; body : jobject?; session-id, purpose : (or/c string? #f); cancel : (or/c evt? #f)
(struct extension-value (value accept))                          ; value : jvalue?; accept : (or/c #f (-> any))
(struct prepared-extensions (fields accept))                     ; fields : jobject?; accept : (-> void?)
(deepseek-extensions-register! x field provider) -> disposer?    ; provider : (-> extension-request? (or/c extension-value? #f)), may await
(deepseek-extensions-prepare x request) -> prepared-extensions?
```

- `register!`: `field` must be a non-empty string equal to its trimmed form, else `exn:fail:contract` `deepseek-llm-api-extensions: field must be a non-blank trimmed string`. Effect labelled `deepseekLlmApiExtensions.register("<field>")` on `(use-context x)`; a second registration of a field raises `deepseek-llm-api-extensions: field "<field>" is already registered`.
- `prepare`: Behaviour X1 to X4.

### `tokenMeter` (key `'tokenMeter`)

`(define-service token-meter 'tokenMeter)` in `dsh-llm/token-meter`.

```racket
(token-meter-context-pressure x session) -> jobject?                    ; {pressureTokens?, contextWindow?}
(token-meter-measure x session [request-header #f]) -> jobject?         ; a token measurement
(token-meter-estimate-message x message) -> exact-nonnegative-integer?
(estimate-message message) (estimate-content blocks) (estimate-system-message message)
(estimate-structural-block block) (estimate-tools-tokens header) -> exact-nonnegative-integer?
(derive-turn-token-usage events) -> (or/c jobject? #f)
```

Semantics are Behaviour F. The service registers nothing on the caller's context.

### `racket:llmMock` (key `'racket:llmMock`)

Provided by the plugin `racket:llm-mock`; the value is the `mock-llm` it registered, so a test mounted from configuration can read the recorded requests. See "Library interfaces".

### Ports: services of other packages consumed here (`dsh-llm/ports`)

This package is built before the packages that provide `attachments`, `fs`, `credentials`, `deepseekAccount` and the loader's entry tree, and must not require them. Each need is a generic interface owned here; the provider's service value implements it.

```racket
(define-generics attachment-port
  (attachment-image-host-path attachment-port image-ref)                  ; -> (or/c string? #f)
  (attachment-file-host-path attachment-port file-ref)                    ; -> (or/c string? #f); may raise on a malformed ref
  (attachment-read-image-request attachment-port image-ref target cancel)) ; -> request-image?
(struct request-image (variant-id attachment data media-type bytes width height))   ; data : bytes?
(define-generics host-path-port (process-path-from-host-path host-path-port host-path))   ; -> (or/c string? #f)
(define-generics credential-port
  (credential-resolve credential-port ref)                                ; -> (or/c string? #f)
  (credential-configured? credential-port ref))                           ; -> boolean?
(define-generics account-port
  (account-resolve-token account-port endpoint)                           ; -> (or/c string? #f)
  (account-reject-token! account-port token))                             ; -> void?
(define-generics inventory-port
  (active-plugin-packages inventory-port session-id))                     ; -> (listof (cons/c string? (or/c string? #f)))
(define-generics settings-port
  (settings-configure! settings-port ctx options))                        ; options : jobject?; -> an effect result (cordis-kernel section 4)
(struct projection-definition (key state-version init apply view summary?))
(define-generics projection-port
  (projection-register! projection-port ctx definition)                   ; -> a handle; an effect on ctx; returns once registered
  (projection-state projection-port handle session))                      ; -> jvalue?
(port-get ctx key pred) -> any/c
```

`(port-get ctx key pred)` is `(ctx-get ctx key)`; it returns `#f` when the service is absent and raises `exn:fail:contract` naming the key and the interface when a value is mounted that does not satisfy `pred`. Keys: `attachments` (`attachment-port?`), `fs` (`host-path-port?`), `credentials` (`credential-port?`), `deepseekAccount` (`account-port?`), `loader` (`inventory-port?`), `sessionProjections` (`projection-port?`), `settings` (`settings-port?`). All are optional reads except where a plugin injects them.

Settings opt-out. dsh's DeepSeek host and its pi-ai plugin tell the settings service not to manage their loader entry automatically: `ctx.inject(['settings'], child => child.effect(() => child.settings.configure({ auto: false }, ctx.fiber)))` (`llm-deepseek/src/host.ts:47`, `llm-pi-ai/src/index.ts:175`). `register-deepseek-provider!` and the body of the `llm-pi-ai` plugin do the same: `(ctx-inject ctx '(settings) (lambda (child) (ctx-effect child (lambda () (settings-configure! (port-get child 'settings settings-port?) ctx (jobj [auto #f]))))))`. Without a `settings` service the child fiber stays pending and nothing else changes. `settings-configure!` takes the plugin's context where dsh passes its fiber; the provider reads the loader entry from it. `gen:settings-port` is defined here because this is the lowest package that calls it; `dsh-agent/ports` re-exports it for the default-model plugin, which makes the same call.

A `projection-definition` has `key` (string), `state-version` (exact non-negative integer), `init : (-> jobject? exact-nonnegative-integer? jvalue?)` (session header, inherited event count), `apply : (-> jvalue? session-event? jvalue?)`, `view : (or/c #f (-> jvalue? jvalue?))` (the wire view) and `summary?` (whether the view is part of session summaries). The projection registry is dsh's `packages/session/session-projection` (wave 4). This package consumes it only through the port. In wave 3 the provider of `sessionProjections` is the plugin `racket:session-projections` of `dsh-agent` (`dsh-agent/projections`, [dsh-agent.md](dsh-agent.md) rules 68 and 69), whose service value implements `gen:projection-port`; `dsh-session-store` replaces it in wave 4 with a value that implements the same interface. `projection-register!` waits until the registration is usable and returns an opaque handle. The registration is an effect on `ctx` and is released when that fiber unloads; the port has no separate release operation, and a handle stays readable with `projection-state` after its registration was released. dsh's `handle.dispose()` and `handle.readerFor(session)` have no counterpart: no wave 3 consumer releases a projection before its fiber unloads, and a reader is `(lambda () (projection-state port handle session))`. Session access (`session-append!`, `session-event` accessors, `derive-event-message`, `canonical-header`, `header-equal?`, `surface-event-types`) comes from `dsh-session` directly; the launch environment and the Harness home come from `dsh-util` (Open question 6).

### Library interfaces (no service key)

`dsh-llm/content`:

```racket
(text-only-image-text image-ref) -> string?
(request-image-handle-text image-ref version [access #f]) -> string?     ; version : anything with width and height keys; access : (or/c string? #f) read-only path
(offloaded-image-text image-ref [access #f]) -> string?
(file-handle-text file-ref readonly-path) -> string?                     ; readonly-path : (or/c string? #f)
(resolve-image-access attachments map-host-path image-ref) -> (or/c string? #f)
(project-files-to-text messages resolve-path) -> (listof jobject?)
(project-images-for-text-model messages) -> (listof jobject?)
(project-offloaded-images messages placeholder) -> (listof jobject?)
(project-tool-updates messages tools tool-update [history #f]) -> (values (listof jobject?) (or/c (listof jobject?) #f))
(required-image-offload messages budget version-bytes) -> exact-nonnegative-integer?
```

Every projection returns its input list `eq?` when nothing changed.

`dsh-llm/messages`, assembler and compact stream:

```racket
empty-assembly                                                        ; assembly?
(assembly-push a chunk) -> assembly?
(assemble-chunks chunks [a empty-assembly]) -> assembly?
(assembly-blocks a) -> (listof jobject?)
(assembly-interrupted-blocks a) -> (listof jobject?)
(assembly-usage a) -> (or/c jobject? #f)
(assembly-finish a) -> jobject?                                       ; {kind: "stop"} when no finish chunk arrived
(assembly-replay-state a) -> (or/c jobject? #f)
(assembly->message a #:provider p #:model m #:id [id (new-message-id)]) -> jobject?

empty-accumulator                                                     ; accumulator?
(accumulator-push acc time chunk) -> accumulator?
(accumulator-snapshot acc) -> (listof jobject?)                       ; compact stream records
(expand-assistant-stream records) -> (listof jobject?)                ; timed chunks {time, chunk}
(token-delta? chunk) (visible-chunk? chunk) (chunk-has-visible-text? chunk) -> boolean?
(run-first-token-time run) (run-first-visible-time run) -> (or/c exact-integer? #f)
(assistant-stream-first-token-time records) -> (or/c exact-integer? #f)
(assistant-stream-has-visible-content? records) (assistant-stream-has-visible-text? records) -> boolean?
(last-assistant-stream-chunk records type) -> (or/c jobject? #f)       ; type : one of "block-start" "block-end" "usage" "finish"
(assistant-stream-chunks records type) -> (listof jobject?)
(join-assistant-stream-text records) -> string?
(assemble-assistant-stream records [a empty-assembly]) -> assembly?
```

`assembly` and `accumulator` are immutable values; `push` returns a new one. Validation failures in the compact stream raise `exn:fail:contract` with the dsh `TypeError` messages.

`dsh-llm/retry-policy` and `dsh-llm/attribution`:

```racket
retry-policy-schema                                                    ; cordis-schema value for RetryPolicySchema
(resolve-retry-policy config path) -> retry-policy?                    ; config : (or/c jobject? #f)
(retry-policy-key policy) -> string?
retry-code-choices                                                     ; (listof string?)
(app-identity) -> jobject?                                             ; {product, version, url, suffix?}
(user-agent [identity (app-identity)]) -> string?
(attribution-headers [identity (app-identity)]) -> (listof (cons/c string? string?))   ; (("user-agent" . …))
(normalize-api-key raw) -> (or/c string? 'empty 'illegal-characters)
(assert-usable-api-key raw pkg ref) -> string?                         ; raises INVALID_CREDENTIAL
```

`dsh-llm/adapter-kit`:

```racket
cancelled?                                                             ; re-export of dsh-llm/cancel: (cancelled? c), c an evt or #f
(check-cancel! cancel) -> void?                                        ; raises exn:fail:llm ABORTED "This operation was aborted"
(make-idle-watchdog timeout-ms cancel) -> idle-watchdog?
(watchdog-arm! w) (watchdog-pulse! w) (watchdog-disarm! w) -> void?
(watchdog-await w evt) -> any                                          ; result of evt; raises exn:idle-timeout or exn:cancelled
(watchdog-expired? w) -> boolean?
(struct exn:idle-timeout exn:fail (timeout-ms))
(struct exn:cancelled exn:fail ())
(config-get config key [default #f]) -> any/c                          ; reads through a volatile reference when the value is one
```

`dsh-llm/http` and `dsh-llm/sse` (Behaviour H):

```racket
(struct http-response (status reason headers))                         ; headers : (listof (cons/c string? string?)), names lowercase
(http-request method url #:headers [headers '()] #:body [body #f] #:cancel [cancel #f] #:proxy [proxy 'policy]) -> http-response?
(http-response-header r name) -> (or/c string? #f)
(http-response-read! r #:await [await-evt await]) -> (or/c bytes? eof-object?)      ; next decoded body bytes
(http-response-read-all r #:await [await-evt await] #:max-bytes [max #f]) -> bytes?
(http-response-close! r) -> void?
(merge-headers headers ...) -> (listof (cons/c string? string?))       ; later wins; a name keeps its first position
(struct exn:fail:http exn:fail ())
(struct exn:fail:http:redirect exn:fail:http (status))
(struct exn:fail:http:truncated exn:fail:http ())

(struct sse-frame (event data))                                        ; event : (or/c string? #f); data : string?
(make-sse-reader read-bytes) -> sse-reader?                            ; read-bytes : (-> (or/c bytes? eof-object?))
(sse-read! reader #:on-comment [on-comment void]) -> (or/c sse-frame? eof-object?)
```

`dsh-llm/deepseek`:

```racket
deepseek-config-fields                                                 ; alist field -> schema, the 18 shared fields
model-listing-config-fields                                            ; modelsTimeoutMs, modelsMaxAgeMs
(resolve-deepseek-options config #:environment [env-ref #f]) -> deepseek-options?   ; env-ref : (-> string? (or/c string? #f))
(struct deepseek-options (base-url defaults max-tokens default-context-window models stream-idle-timeout-ms
                          max-request-files-bytes max-inline-request-image-bytes max-images-per-request
                          image-offload-byte-quantum inline-image-offload-byte-quantum image-offload-count-quantum
                          files-api-timeout-ms file-policy retry-policy extra) #:transparent)
(struct request-auth (headers on-request-error))                       ; headers : header alist; on-request-error : (or/c #f (-> any/c any/c))
(make-deepseek-adapter #:options options-thunk #:resolve-auth resolve-auth #:resolve-user-id user-id-thunk
                       #:prepare-extensions prepare #:provider-name [name "DeepSeek"] #:connect [connect #f]
                       #:admit [admit #f] #:discover-models [discover #f] #:attachments [attachments-thunk #f]
                       #:image-access [image-access #f] #:file-store [store #f]
                       #:on-replay-degrade [f void] #:on-extensions-omitted [f void] #:on-extensions-unaccepted [f void]
                       #:http-request [http-request http-request]) -> llm-adapter?
(register-deepseek-provider! ctx provider #:options … #:resolve-auth … #:provider-name … #:discover-models … #:connect … #:admit …) -> void?
(messages-api-root base-url) -> string?
(serialize-messages-request request options history images access #:on-replay-degrade [f void] #:file-ids [ids #f]) -> jobject?
(make-messages-translator model #:label [label "DeepSeek Messages"] #:replay-state [make-replay deepseek-replay-state]) -> translator?
(translator-push! t event) -> (listof jobject?)                        ; chunks for one SSE event, in order; raises exn:fail:llm
(translator-finish! t) -> void?                                        ; raises STREAM_CLOSED unless message_stop was seen
(translator-done? t) -> boolean?
(provider-error raw status headers #:label [label "DeepSeek Messages"]) -> exn:fail:llm?
(provider-error-detail raw) -> string?
(model-info options provider model) -> jobject?                        ; resolved model info
(catalog-model-info provider catalog-model [badge #f]) -> jobject?
default-deepseek-models                                                ; the built-in catalog
```

`options-thunk` returns the current `deepseek-options` (it is called once per operation). `extra` carries plugin-specific additions (listing settings, refusals, badges) as a hash. `#:http-request` exists so tests can substitute the transport. The listing, listed-catalog, files, upload-index and image-token modules export the functions named in R6 D9 to D12 with kebab-case names (`request-model-listing`, `parse-model-listing`, `model-listing-url`, `make-model-listing-cache`, `resolve-listed-catalog`, `refuse-listed-model`, `make-file-store`, `file-store-ensure-uploaded!`, `deepseek-file-scope`, `deepseek-image-tokens`, `deepseek-request-image-dimensions`, `resolve-request-image-target`, `deepseek-image-request-pricing`); their argument lists follow the TypeScript functions one for one with `signal` replaced by a trailing `cancel` argument.

`dsh-llm/retry`:

```racket
(make-retry-recovery #:append! append! #:retry-state retry-state #:random [random random]
                     #:delay-evt [delay-evt default-delay-evt] #:disposed-evt [disposed #f]
                     #:log-warning [warn void]) -> (-> jobject? (-> any) any)
llm-retry-projection                                                   ; the llmRetry projection definition
```

`append! : (-> session? session-event-input? any)` (normally `session-append!`), `retry-state : (-> session? jobject?)` (the `llmRetry` projection state), `random : (-> real?)` in [0, 1], `delay-evt : (-> real evt)` (milliseconds to an evt that becomes ready after that long). The result is the `agent/request-error` listener body of Behaviour E: it takes the payload and `next` and returns `{kind: "retry"}` or `#f`.

`dsh-llm/replay`:

```racket
(parse-session-fixture text #:decode [decode decode-current-session-fixture]) -> session-fixture?
(derive-replay-script events) -> (listof jobject?)
(read-override-doc jvalue file) -> (or/c (listof jobject?) (listof (cons/c exact-nonnegative-integer? jobject?)))
(load-session-scripts config #:decode [decode …]) -> (listof recorded-session-script?)
(resolve-scripted-entry entry messages) -> jobject?
(install-llm-replay! x config #:decode [decode …]) -> replay-handle?
(replay-handle-dispose! h) -> void?
(replay-assert-consumed! h) -> void?
```

`config` is the plugin config jobject with `file` required. `decode : (-> jobject? (listof jobject?) (values jobject? (listof session-event?) exact-nonnegative-integer?))` takes the normalised header row and the completed body rows and returns the header, the events at the current Session format, and the inherited event count (Behaviour I2).

`dsh-llm/testing/mock`:

```racket
(make-mock-llm script #:models [models '()] #:retry-policy [policy #f] #:provider-name [name #f]) -> mock-llm?   ; implements gen:llm-adapter
(struct mock-failure (chunks code message))
(mock-llm-requests m) -> (listof llm-request?)                         ; in call order
(mock-llm-remaining m) -> exact-nonnegative-integer?
(mock-llm-assert-consumed! m) -> void?
(mock-reply block ... #:usage [usage #f] #:finish [finish #f]) -> (listof jobject?)
(mock-text text #:usage [usage #f]) -> (listof jobject?)
(mock-tool-call name arguments #:id [id "mock-call-1"] #:usage [usage #f]) -> (listof jobject?)
```

`dsh-llm/testing/mock-server`:

```racket
(start-mock-llm-server #:sequence sequence #:host ["127.0.0.1"] #:port [0] #:api-key [#f] #:repeat-last? [#f]
                       #:random-seed [#f] #:random-weights [#f] #:success-text [..] #:partial-text [..] #:reasoning-text [..]
                       #:chunk-size [8] #:chunk-delay-ms [25] #:disconnect-delay-ms [10] #:retry-after-ms [1000]
                       #:request-id [#f] #:tool-name ["mock_tool"] #:tool-arguments ["{\"value\":\"mock\"}"]
                       #:on-event [#f]) -> mock-llm-server?
(mock-llm-server-base-url s) (mock-llm-server-port s) (mock-llm-server-random-seed s) (mock-llm-server-requests s)
(mock-llm-server-close! s) -> void?
```

## Events

Declared with `define-event` in the module that owns them. As in the other wave 3 contracts, the Racket identifier of an event is its dsh name, so the generated bindings are `on-llm/stream`, `llm/stream-name`, `dispatch-llm/stream` and so on. The identifier `llm/stream` itself is not bound; `llm-stream` is the service procedure.

```racket
;; dsh-llm/llm
(define-event llm/stream 'llm/stream
  #:mode waterfall #:args (llm-request?) #:result chunk-stream?)
(define-event llm/adapters-updated 'llm/adapters-updated
  #:mode emit #:args ())
(define-event llm/models-updated 'llm/models-updated
  #:mode emit #:args (string?))

;; dsh-llm/pi-ai
(define-event llm-pi-ai/request-headers 'llm-pi-ai/request-headers
  #:mode waterfall #:args (jobject? list?) #:result list?)
```

`dsh-llm/llm` exports the `on-…` and `…-name` bindings of its three events and `dispatch-llm/models-updated`, which a model listing cache in another module calls. It does not export the dispatchers of `llm/stream` and `llm/adapters-updated`: only the runtime dispatches those.

| dsh name | Mode | Arguments | Dispatched by, when | Guarantees |
|---|---|---|---|---|
| `llm/stream` | waterfall | `(request next)`; `next : (-> chunk-stream?)`; result a `chunk-stream` | `llm-stream` and `prepared-call-stream`, once per call, during that call | A listener calls `(next)` to delegate or returns its own stream to short-circuit. Adapter lookup happens only in the innermost step, so a listener can serve a request for an unregistered provider. A loop-built request satisfies `agent-loop-request?`; listeners read it and never rebuild it for the same call. Exceptions from listeners propagate to the caller of `llm-stream`. |
| `llm/adapters-updated` | emit | none | The runtime after every route or directory commit and at every registration release | Fired after the registry holds the new state; exactly one per `replace!`. The runtime does not use `dispatch-llm/adapters-updated`: it calls each of `(ctx-listeners ctx 'llm/adapters-updated)` in order inside its own handler, logging `llm: an llm/adapters-updated listener failed` and the exception at `warning`, so a failing listener neither vetoes the commit nor starves later listeners. |
| `llm/models-updated` | emit | `(provider)` | A model listing cache, only after its view changed: a loaded listing differs from the previous one, the route stopped following a listing, or it lost authentication | Listeners reload `(llm-list-models x provider)`. |
| `llm-pi-ai/request-headers` | waterfall | `(request headers next)`; `request` is `{provider, model, baseURL, sessionId?, purpose?}`; `headers` a header alist; result a header alist | `llm-pi-ai`, once per inference call, not for discovery | Synchronous: listeners must not await. An exception fails the call with `REQUEST_HEADERS`. Afterwards the adapter overwrites the attribution header. |

Consumed, registered by name with `ctx-on` because their owners are built later or elsewhere: `agent/request-error` (waterfall; owner `dsh-agent`; Behaviour E), `loader/volatile-update` (emit, no arguments; owner `cordis-loader`), `internal/config` (waterfall; kernel), `session/event` (owner `dsh-session`; first argument the session).

Session-log events declared here are `llm/retry` and `llm/retry-started` (Data). Ordering guarantees: `llm/retry` is appended before the backoff wait starts; `llm/retry-started` is appended after the wait and before the listener returns the retry decision; the loop appends `assistant/attempt` for the failed attempt before it dispatches `agent/request-error` (`packages/core/agent-loop/src/agent.ts:547-570`).

## Plugins

Each row is a module `dsh-llm/plugin/<short-name>` providing `plugin`. `#:name` is the npm name; the short name is kept in `#:meta` under `'short-name` and is what diagnostics and the settings namespace fallback use. "Volatile" marks a field whose current value is read with `config-get` once per operation, so a settings change reaches the next request without re-registration. The settings namespace a plugin declares to the provider directory is the `id` of its loader entry, else its short name.

| npm name | Short name | Inject | Provides | Config | Body |
|---|---|---|---|---|---|
| `@deepseek-ai/dsh-llm` | `llm` | none (optional reads: `attachments`, `fs`) | `llm` | none | Creates the runtime and provides it. |
| `@deepseek-ai/dsh-llm-deepseek-api-key` | `llm-deepseek-api-key` | `llm` | none | shared DeepSeek fields + listing fields + `apiKeyEnv` (below) | D15. |
| `@deepseek-ai/dsh-llm-deepseek-account` | `llm-deepseek-account` | `llm` | none | shared DeepSeek fields without `models` + listing fields + `modelOverrides` | D16. |
| `@deepseek-ai/dsh-llm-pi-ai` | `llm-pi-ai` | `llm` | none | `providers` (below) | P1 to P12. |
| `@deepseek-ai/dsh-llm-retry` | `llm-retry` | `agents`, `sessionProjections` | none | empty object; a key `retryPolicy` raises `llm-retry: retryPolicy belongs under each provider configuration`, any other key `llm-retry: unknown key "<k>"` | Registers the `llmRetry` projection, awaits it, registers the `agent/request-error` listener and the drain effect (E). `(make-llm-retry-plugin #:random [r random] #:delay-evt [f default-delay-evt]) -> plugin?`, exported by `dsh-llm/plugin/llm-retry` beside `plugin`, builds a variant for tests; `plugin` is `(make-llm-retry-plugin)`. |
| `@deepseek-ai/dsh-token-meter` | `token-meter` | `sessionProjections` | `tokenMeter` | empty object; any key raises `TokenMeterConfig: unknown key "<k>" (no settings are supported)` | Registers the four projections in the order `tokenMeasurement`, `tokenUsage`, `contextPressure`, `contextBreakdown`, awaiting each; listens to `session/event`; provides the service. |
| `@deepseek-ai/dsh-deepseek-llm-api-extensions` | `deepseek-llm-api-extensions` | none | `deepseekLlmApiExtensions` | none | Creates the registry and provides it. |
| `@deepseek-ai/dsh-plugin-package-inventory-deepseek` | `plugin-package-inventory-deepseek` | `agents`, `deepseekLlmApiExtensions`, `loader` | none | `enabled`: boolean, default `true` | `enabled: false` registers nothing; otherwise registers the field `dsh_plugin_packages` (G). |
| `@deepseek-ai/dsh-llm-replay` | `llm-replay` | `llm` | none | `file`, `overrideFile`, `childFiles`, `providers`, `paceMs` (below) | I1; calls `install-llm-replay!`. |
| `racket:llm-mock` | `llm-mock` | `llm` | `racket:llmMock` | `providers`: list of strings, default `["mock"]`; `script`: list of turns, each a list of stream-chunk jobjects, default `[]`; `models`: list of resolved-model-info jobjects without `provider`, default `[]` | Builds `(make-mock-llm script #:models models)`, registers it for `providers`, provides it. |

Shared DeepSeek protocol fields (`deepseek-config-fields`; all volatile; `packages/llm/llm-deepseek/src/config.ts:92-111`):

| Field | Type | Default |
|---|---|---|
| `baseURL` | string | none; resolves to `DEEPSEEK_BASE_URL` from the launch environment, then `https://api.deepseek.com/anthropic` |
| `thinking` | `"enabled"` or `"disabled"` | unset |
| `reasoningEffort` | `"off"`, `"low"`, `"high"`, `"max"` | unset |
| `maxTokens` | integer at least 1 | `256000` |
| `defaultContextWindow` | integer at least 1 | `1000000` |
| `models` | list of catalog models | the built-in catalog |
| `streamIdleTimeoutMs` | number in (0, 2147483647] | `300000` |
| `maxRequestFilesBytes` | integer at least 1 | `134217728` |
| `maxInlineRequestImageBytes` | integer at least 1 | `20971520` |
| `maxImagesPerRequest` | integer at least 1 | `600` |
| `imageOffloadByteQuantum` | integer at least 1, at most `maxRequestFilesBytes` | `67108864` |
| `inlineImageOffloadByteQuantum` | integer at least 1, at most `maxInlineRequestImageBytes` | `10485760` |
| `imageOffloadCountQuantum` | integer at least 1, at most `maxImagesPerRequest` | `20` |
| `filesApiTimeoutMs` | number in (0, 2147483647] | `60000` |
| `fileExpiresAfterSeconds` | integer 3600 to 2592000 | `604800` |
| `fileRefreshMarginSeconds` | integer at least 0 and below `fileExpiresAfterSeconds` | `3600` |
| `fileQuotaCleanupBatch` | integer 1 to 1000 | `100` |
| `retryPolicy` | `retry-policy-schema` | unset |

Catalog model: `id` (required), `name`, `description`, `contextWindow`, `maxTokens`, `inputModalities` (default `["text"]`), `imagePixelBudget` (positive integer or `"low"`), `imageMaxBytes`, `systemPromptUpdate` (`"in-history"`), `toolUpdate` (`"in-history"` or `"addition-only"`). Built-in catalog, in order: `{id: "deepseek-flash", name: "DeepSeek-V4.1-Flash", contextWindow: 1048576, inputModalities: ["text", "image"], systemPromptUpdate: "in-history", toolUpdate: "addition-only"}` and `{id: "deepseek-v4-pro", name: "DeepSeek-V4-Pro", description: "Stronger agentic coding, knowledge, and difficult reasoning; suited to complex or quality-critical tasks at higher cost.", contextWindow: 1048576}`. Listing fields (volatile): `modelsTimeoutMs` number in (0, 2147483647], default `5000`; `modelsMaxAgeMs` non-negative integer, default `600000`. `apiKeyEnv` (api-key plugin; volatile; role `credential-ref`): string, default `"DEEPSEEK_API_KEY"`. `modelOverrides` (account plugin; volatile): dict from model id to the catalog model fields without `id`, default `{}`.

`retry-policy-schema` is a union: `{mode: "normal" (required), maxRetries?: integer at least 0 (default 5), retryableCodes?: non-empty list of non-empty strings without duplicates (default ["EMPTY_RESPONSE", "RATE_LIMIT", "SERVER", "TIMEOUT", "TRANSPORT"]), backoff?}` or `{mode: "always" (required), backoff?}`, with `backoff: {initialDelayMs?: (0, 2147483647], default 500; maxDelayMs?: same range, default 10000; jitterRatio?: [0, 1], default 0.1}`.

`llm-pi-ai` config: `providers`: dict from route to profile, default `{}`, volatile. Profile fields are exactly those of R6 Configuration, "`@deepseek-ai/dsh-llm-pi-ai`" (`apiKeyEnv`, `displayName`, `api`, `baseURL`, `models`, `modelOverrides`, `compat`, `defaultContextWindow`, `defaultMaxTokens`, `defaultInput`, `headers`, `reasoning`, `thinkingBudgets`, `cacheRetention`, `transport`, `timeoutMs`, `websocketConnectTimeoutMs`, `streamIdleTimeoutMs`, `maxRequestImageBytes`, `maxRequestImages`, `imageOffloadCountQuantum`, `requestImagePixelBudget`, `requestImageMaxBytes`, `retryPolicy`) with the types and defaults given there; a model entry is `{id, name?, contextWindow?, maxTokens?, input?, reasoningEfforts?, compat?}`. `compat` accepts the 26 switches of `PiAiCompatProfile` (`packages/llm/llm-pi-ai/src/catalog.ts:385-460`): `supportsStore`, `supportsDeveloperRole`, `supportsReasoningEffort`, `supportsUsageInStreaming`, `supportsFinishReason`, `maxTokensField`, `requiresToolResultName`, `requiresAssistantAfterToolResult`, `requiresThinkingAsText`, `requiresReasoningContentOnAssistantMessages`, `thinkingFormat`, `chatTemplateKwargs`, `chatTemplateArgs`, `supportsThinkingTokenBudget`, `thinkingTokenBudgetField`, `vllmPriority`, `supportsMaxOutputTokens`, `supportsStrictMode`, `cacheControlFormat`, `supportsLongCacheRetention`, `supportsEagerToolInputStreaming`, `supportsCacheControlOnTools`, `supportsTemperature`, `forceAdaptiveThinking`, `allowEmptySignature`, `supportsStrictTools`. The whole schema must parse an unmodified dsh configuration, including fields the native adapters ignore.

`llm-replay` config: `file` string (default `DSH_SNAPSHOT_FILE`; one of the two is required, else `llm-replay: a fixture path is required (Config.file or $DSH_SNAPSHOT_FILE)`), `overrideFile` string (default `DSH_SNAPSHOT_OVERRIDE`), `childFiles` list of strings (default `DSH_SNAPSHOT_CHILD_FILES` split on the platform path-list separator), `providers` list of `{id, name?, models?, retryPolicy?}`, `paceMs` non-negative integer. A replay model is `{id, name?, description?, contextWindow?, inputModalities?, defaultMaxTokens?, imageRequestTokens?, reasoningEfforts?, defaultReasoningEffort?, systemPromptUpdate?, toolUpdate?, badge?}`.

Every resolver re-checks every bound at load and raises `exn:fail:contract` with the dsh message, prefix included (`llm-deepseek: …`, `llm-deepseek-account: …`, `llm-pi-ai: …`), because settings-driven construction can bypass schema validation (`packages/llm/llm-deepseek/src/config.ts:150-340` lists the messages for the shared fields).

## Behaviour

Rules are numbered per area. Error rows give the code and the exact message; `<p>`, `<m>` and similar stand for interpolated values. Unless a rule says otherwise an error is an `exn:fail:llm` raised with `raise-llm-error`.

### A. The `llm` runtime (`packages/llm/llm/src/index.ts`; R6 A)

A1. **Registry state.** The three tables keep insertion order. Every mutation of the route table or the directory happens in one section with no `await`, so no reader sees a partial state. A registration keeps the set of routes (or entries) it currently holds and a `released?` flag; the flag, not an empty set, decides whether `replace!` is legal.

A2. **`llm-register-adapter!`.** Inside the effect: (1) `providers` empty raises `INVALID_ADAPTER` `an adapter must register at least one provider`. (2) Validate the whole candidate list, in order, without mutating: an empty name raises `INVALID_ADAPTER` `adapter provider names must be non-empty`; a name repeated in the list, or held by another registration, raises `DUPLICATE_ADAPTER` `an adapter for provider "<p>" is already registered`; `(adapter-provider-info adapter p)` must have `id` equal to `p` and a non-empty `name`, else `INVALID_ADAPTER` `adapter metadata for provider "<p>" must preserve its id and have a non-empty name`; capture `(or (adapter-retry-policy adapter p) (resolve-retry-policy #f "llm: provider \"<p>\" retryPolicy"))`. (3) Commit: remove the routes this registration holds, insert the new registrations in list order, emit `llm/adapters-updated` once. The effect's inverse sets `released?`, removes the held routes and emits once. A failure in (1) or (2) leaves the registry untouched and propagates from `llm-register-adapter!`.

A3. **`adapter-registration-replace!`.** When `released?`: `REGISTRATION_DISPOSED` `a disposed adapter registration cannot replace its routes`. Otherwise run A2 steps 2 and 3 on the new list, treating the routes this registration holds as free. The retry policy is captured again.

A4. **Directory.** An empty initial list raises `INVALID_DIRECTORY` `a configurable-provider registration must declare at least one provider`. For each candidate, in order: an empty `provider`, `displayName` or `settingsNs` raises `INVALID_DIRECTORY` `configurable providers need a non-empty provider, displayName, and settingsNs`; an empty `settingsPath` segment raises `INVALID_DIRECTORY` `configurable provider "<p>" has an empty settingsPath segment`; a provider declared by another registration or twice in the set raises `DUPLICATE_DIRECTORY` `configurable provider "<p>" is already declared`. Then remove the held entries, insert the new ones, emit once. `directory-registration-replace!` after release raises `REGISTRATION_DISPOSED` `this configurable-provider registration was disposed`; an empty list is legal there.

A5. **Discovery.** Registration: empty namespace raises `INVALID_DISCOVERY` `model discovery needs a non-empty settings namespace`; a second registration raises `DUPLICATE_DISCOVERY` `model discovery for "<ns>" is already registered`. `llm-discover-models`: no registration raises `NO_DISCOVERY` `no model discovery is registered for "<ns>"`; a request whose `provider` and `baseURL` are both absent or empty raises `INVALID_DISCOVERY` `model discovery needs a provider route or a baseURL`. Call the procedure; drop entries without a non-empty string `id`; deduplicate by `id` keeping the first; return for each `{id, name?, contextWindow?, maxTokens?, inputModalities?}` in that key order.

A6. **`llm-list-models`.** Each entry must have `provider` equal to the route, non-empty string `id` and `name`, a string `description` when present, and an `id` not seen before; otherwise `INVALID_CATALOG` `adapter returned invalid or duplicate model metadata for provider "<p>"`. Result entries are `{provider, id, name, description?, inputModalities?, badge?: {text, tone}}`.

A7. **Normalising resolved model info.** With `<r>` standing for `provider "<p>" model "<m>"`: `provider` or `id` different from the request, empty `name`, or a non-string `description` raises `INVALID_MODEL_INFO` `adapter returned invalid exact model metadata for <r>`; a `context.contextWindow` that is not a positive integer raises `INVALID_MODEL_CONTEXT` `adapter returned invalid context metadata for <r>`; `systemPromptUpdate` other than `"in-history"` raises `INVALID_MODEL_INFO` `adapter returned invalid system prompt update mode for <r>`; `toolUpdate` other than the two modes raises `INVALID_MODEL_INFO` `adapter returned invalid tool update mode for <r>`; `defaultMaxTokens` that is not a positive safe integer raises `INVALID_MODEL_MAX_TOKENS` `adapter returned invalid default maxTokens for <r>`; an empty `reasoning.efforts` raises `INVALID_MODEL_REASONING` `adapter returned invalid reasoning metadata for <r>`; an effort with an empty or repeated `id`, an empty `name` or a non-string `description` raises `INVALID_MODEL_REASONING` `adapter returned invalid or duplicate reasoning effort metadata for <r>`; a `defaultEffort` not among the efforts raises `INVALID_MODEL_REASONING` `adapter returned an unknown default reasoning effort for <r>`. The result is rebuilt with the key order of Data and without `badge`.

A8. **Resolving a call config against model info.** (1) When the config has no `maxTokens` and the info has `defaultMaxTokens`, add it. (2) When the info has no `reasoning` and the config names an effort: `UNSUPPORTED_REASONING_EFFORT` `provider "<p>" model "<m>" does not support reasoning effort "<e>"`. (3) Otherwise `effective` is the requested effort, else `reasoning.defaultEffort`; when defined it must be the `id` of one of the efforts (same error, with `<e>` the effective effort); when the caller left it unset, add it. No clamping, no aliasing.

A9. **`llm-prepare-call`.** In order: `check-cancel!`; look up the registration (`NO_ADAPTER` `no adapter registered for provider "<p>"`); `(adapter-prepare-call adapter provider model cancel)`; `check-cancel!`; normalise its model info (A7); when `configure` is given, call it once with the controls (the config without `provider` and `model`) and the model info, and take its result plus the fixed `provider` and `model` as the proposal, otherwise the proposal is the config; `check-cancel!`; A8 on the proposal; compute `adapter-defaults` (`reasoningEffort: #t` when the proposal had none and the result has one; likewise `maxTokens`). `prepared-call-stream` raises `INVALID_PREPARED_CALL` `a prepared LLM call can only be dispatched once` on a second call and `INVALID_PREPARED_CALL` `prepared LLM call config changed before adapter dispatch` on a config mismatch, both at call time; otherwise it marks the call dispatched and dispatches `llm/stream` with an innermost step bound to the captured registration, model info, config and adapter call.

A10. **The adapter boundary** (the innermost step of `llm/stream`; `index.ts:1083-1172`). It returns a `chunk-stream` whose first pull runs the setup below and whose every pull is guarded: any raised value that is not an `exn:break` (an `exn:fail`, or a non-exception value) during setup or while pulling the adapter's stream is converted into one final chunk (A11), after which the stream ends. Setup steps:

1. Take the prepared registration, or look it up by `(llm-request-provider request)` (`NO_ADAPTER`).
2. Unprepared: `adapter-prepare-call` with the request's cancel evt, A7, then A8 on `(llm-request-call-config request)`. Prepared: reuse the captured values and re-check config equality (`INVALID_PREPARED_CALL`, second message of A9).
3. When the resolved config differs from the request's, overlay it with `llm-request-with-call-config`.
4. When any message contains a `file` block, replace every file block with a text block `(file-handle-text ref path)` (`project-files-to-text`). `path` is `(attachment-file-host-path attachments ref)` mapped through `(process-path-from-host-path fs host-path)`; a missing `attachments` or `fs` service, a `#f` at either step, or an exception from the attachment port yields `#f`.
5. When the model info declares `inputModalities` without `"image"` and any message contains an image, replace every image block with `(text-only-image-text ref)` (`project-images-for-text-model`). Undeclared modalities are not projected.
6. `(project-tool-updates messages tools (model info toolUpdate) tool-history)` (T5).
7. For each assistant message whose source has `replayState`: keep it only when the adapter currently registered for `source.provider` is `eq?` to this adapter; otherwise send a copy whose source is `{kind: "model", provider, model}`.
8. Call the dispatch (`prepared-adapter-call-stream`) with the projected request and keep its stream.

Then each pull of the boundary stream pulls the adapter's stream once and returns that chunk unchanged; `eof` ends it. Closing the boundary stream closes the adapter's stream. The boundary never adds a `finish` chunk to a stream that ended without one and never retries.

A11. **Failure chunk.** `(finish-chunk reason)` with `reason` `(finish-aborted failure)` when the request's cancel evt is ready or the failure code is `ABORTED`, else `(finish-error failure)`; `failure` is `(normalize-llm-failure v)`: an `exn:fail:llm` gives its failure; another `exn:fail:harness` gives `{message, code}` from the exception; any other `exn` gives `{message, code: "UNKNOWN"}`; a non-exception value gives `{message: (format "~a" v), code: "UNKNOWN"}`. An empty message becomes `LLM adapter failed`.

A12. **What stays raised.** Exceptions from `llm/stream` listeners, from streams that listeners return, from the consumer's own code, and every `exn:break` are never converted. `prepared-call-stream` errors of A9 are raised at call time. This is the dsh rule "middleware and consumer failures remain thrown".

### T. Model-visible texts and request projections (`packages/llm/llm/src/content.ts`; R6 Formats 5, A7, A8)

T1. Notation: `Q(s)` is `(jvalue->string s)`. `ID` is the ref's `attachmentId` when it has no `name`, else `Q(name) (attachmentId)`. `D8` is characters 7 to 14 of `attachmentId` (the eight after `sha256:`). `EXT` maps `image/png` to `.png`, `image/jpeg` to `.jpg`, `image/webp` to `.webp`, `image/gif` to `.gif`. `ACCESS(ref, path)` is, with its leading space:

```text
 Normalized copy (read-only; may be resized or re-encoded): Q(path) (WxHpx, mediaType). Source dimensions, format, and byte size may differ. Copy to a writable path ending in EXT before editing.
```

T2. Exact texts (`W`, `H`, `mediaType` from the ref; `Wv`, `Hv` from the request version; `N` is the ref's `bytes`):

| Function | Text |
|---|---|
| `text-only-image-text` | `[image omitted because this model accepts text only; attachment sha256:D8]` |
| `request-image-handle-text`, no access | `Image ID; request preview WvxHvpx. It may be resized or re-encoded; source dimensions, format, and byte size may differ.` |
| same, with access | `Image ID; request preview WvxHvpx.` followed by `ACCESS` |
| `offloaded-image-text`, no access | `[image omitted to fit request image limits; ID. No local normalized image path is available; ask the user to attach it again if needed.]` |
| same, with access | `[image omitted to fit request image limits; ID.` followed by `ACCESS` and `]` |
| `file-handle-text`, path `#f` | `[File Q(name) (N bytes, sha256:D8) was uploaded, but the current execution environment cannot access a readable path. Report that limitation if its contents are needed; do not claim to have read it.]` |
| `file-handle-text`, with path | `[File Q(name) (N bytes, sha256:D8): verbatim read-only copy saved at Q(path). Read that path with your file tools when its contents are needed; copy it to a writable location before modifying it. When delegating file work, include this saved path in the delegation prompt; only subagents sharing this execution environment can read it.]` |

T3. File, text-only-image and offloaded-image projection replace each matching block by `(text-block <text>)` in place and leave every other block and message untouched (`eq?`).

T4. `required-image-offload` is R6 A8 exactly: lengths are taken for every image block not marked `offloaded`, in message order, as `(version-bytes block)` or `4 * ceil(bytes / 3)` for the `base64` representation; the result is the count of oldest images to remove. The route itself never offloads: it raises `IMAGE_OFFLOAD_REQUIRED` with `offloadImages` set to that count.

T5. `project-tool-updates` is R6 A7 rules 1 to 6 exactly (`content.ts:439-510`, rebase at `:397-423`). Racket notes: deferral is set with `jset` and cleared with `jremove`; "the original message array is returned" means the input list `eq?`; the declarations are returned in first-insertion order; with mode `#f` the result tools are `#f` when the input tools were `#f`.

### B. Assembler (`packages/llm/llm/src/assembler.ts`; R6 B)

B1. State: partial blocks by `index`, the first-seen order of indexes, the last `usage`, the last finish reason and replay envelope. `assembly-push` by chunk type: `block-start` creates the partial unless the index exists (a duplicate is ignored); a text or reasoning delta creates the partial with its block type when the index is new, and appends its text unless the block is closed; a tool-call delta does the same, sets the id (last wins), sets the name when the chunk has a non-empty `name`, and appends `argumentsDelta`; `block-end` records the complete block unless one is already recorded (first wins; it creates the partial when the index is new); `usage` and `finish` replace the stored values. Any other `type` raises `exn:fail:contract`.

B2. Assembling an open block: text and reasoning use the accumulated text; a tool call is `(tool-call-block (or id "call-<index>") (or name "") arguments)`; any other open type raises `exn:fail` `cannot assemble incomplete block of type "<type>"`.

B3. `assembly-blocks`: all blocks in first-seen order; when the finish kind is `max-tokens`, every `tool-call` block is dropped. `assembly-replay-state`: no envelope gives `#f`; an envelope without `blocks` passes through; `blocks` whose length differs from the count of all blocks (before dropping) gives `#f`; otherwise the entries at dropped positions are removed and `response` is kept.

B4. `assembly-interrupted-blocks`: text and reasoning blocks (open or closed), in order, whose text contains a non-whitespace character (JavaScript `trim` whitespace); nothing else.

B5. `assembly->message` is `make-assistant-message` over `assembly-blocks` (it does not attach the replay state; the caller does, as the loop does in `agent.ts:572-579`).

### C. Compact timed stream (`packages/llm/llm/src/assistant-stream.ts`; R6 C)

C1. `accumulator-push`: `time` must be a safe integer (`exn:fail:contract` `Assistant stream time must be a safe integer, got <v>`) and `chunk` a jobject. A text or reasoning delta joins the last record only when that record has the matching type and the same `index`, and the gap `time - last-time` is a safe integer (negative allowed); otherwise it starts a record with `dt` `'()`. A tool-call delta whose `id` is `""`, or which has a `name` equal to `""`, is stored as a raw `chunk` record; otherwise it joins the last record only when that is a `tool-call-chunks` record with the same `index`, the same `id`, the same presence of `name` and the same `name`, and the gap is safe. Every other chunk is a raw record. Index must be a non-negative safe integer (`<type> index must be a non-negative safe integer`).

C2. `expand-assistant-stream` validates each record, then yields `{time, chunk}` for every member in order; member `k` of a run has time `time0 + dt[0] + … + dt[k-1]`; a `tool-call-delta` rebuilt from a run has keys `type, index, id, name?, argumentsDelta`. Validation (`:456-534`): the exact key sets of Data; non-empty `texts` or `args` of strings; `dt` of safe integers with one fewer element than the members; every member time a safe integer; a non-empty string `id`; a non-empty `name` when present; a raw `chunk` that is a jobject; an unknown record type raises `Unsupported Assistant stream record <json of type>`. Messages are those of the TypeScript, raised as `exn:fail:contract`.

C3. Predicates and readers are R6 C last paragraph, one for one. `assemble-assistant-stream` pushes one joined delta per run and each raw chunk, and yields the same blocks, usage, finish and replay state as assembling the full expansion. "Non-whitespace" here is JavaScript `/\S/`.

### H. HTTP and SSE (`dsh-llm/http`, `dsh-llm/sse`)

H1. **Request.** `http-request` speaks HTTP/1.1 over `racket/tcp` (and `openssl` for `https`). It sends `Host`, the caller's headers in order with their given spelling, `Connection: close`, and `Content-Length` when `body` is bytes. It adds no `Accept-Encoding`. `url` must be `http` or `https`, else `exn:fail:contract`. Connecting, the TLS handshake, writing the request and reading the status line and headers run under `blocking`; everything is created under `current-custodian`, so closing the owning stream reclaims the socket.

H2. **Proxy.** With `#:proxy 'policy` the route comes from the proxy policy of `dsh-util` (`packages/util/http-proxy/src/policy.ts`: `http_proxy`, `https_proxy`, `all_proxy`, `no_proxy` from the launch environment, lowercase first; loopback always direct). `#f` forces a direct connection; a string is an explicit `http://` proxy URL. An `http` target through a proxy sends the absolute URL in the request line; an `https` target sends `CONNECT host:port`, requires a `2xx` reply and then starts TLS inside the tunnel. A proxy that refuses raises `exn:fail:http`.

H3. **TLS.** Certificates are verified against the default sources of `openssl` (which honour `SSL_CERT_FILE` and `SSL_CERT_DIR`) plus the PEM file named by `NODE_EXTRA_CA_CERTS` when the launch environment sets it; the host name is checked; SNI is sent. Verification is never disabled.

H4. **Response head.** `status` is an exact integer, header names are lowercased, repeated headers are kept in order (`http-response-header` returns the first). Any `3xx` status closes the connection and raises `exn:fail:http:redirect`; redirects are never followed (dsh passes `redirect: 'error'`). A connection that closes before a complete head, a malformed status line, a refused connection or a TLS failure raises `exn:fail:http` whose message names the stage.

H5. **Body.** `http-response-read!` returns the next non-empty piece of the decoded body or `eof`. It decodes `Transfer-Encoding: chunked`, a `Content-Length` body, or a body delimited by connection close, in that priority. A chunked body that ends before its terminating zero chunk, or a `Content-Length` body that ends short, raises `exn:fail:http:truncated`. A `HEAD` response and a `204` or `304` status have no body. Every wait on the socket goes through the `await-evt` argument, a procedure from an evt to its result, so an adapter can pass `(lambda (evt) (watchdog-await w evt))`.

H6. **Cancellation.** When `cancel` becomes ready during H1, the helper thread is broken and `http-request` raises `exn:cancelled` (the struct of `dsh-llm/adapter-kit`, which `dsh-llm/http` requires). During the body, cancellation is the business of `await-evt`.

H7. **SSE.** `sse-read!` pulls bytes from `read-bytes`, decodes UTF-8 across piece boundaries (an invalid sequence becomes U+FFFD), strips one leading byte-order mark, and splits lines at CRLF, LF or CR. A line starting with `:` is a comment: `on-comment` is called and nothing is delivered. `event:` sets the frame's event name; each `data:` line appends to the data, joined with `\n`; one space after the colon is dropped; `id:`, `retry:` and unknown fields are ignored. An empty line delivers the frame when at least one `data` line was seen and resets the state. At end of input an unterminated frame is discarded and `eof` is returned.

H8. **Idle watchdog.** `(watchdog-arm! w)` sets the deadline to now plus `timeout-ms`; `watchdog-pulse!` does the same when armed; `watchdog-disarm!` clears it. `(watchdog-await w evt)` awaits the choice of `evt`, the cancel evt and, when armed, an alarm at the current deadline; a pulse during the wait takes effect because the wait loops while the deadline moved. It raises `exn:idle-timeout` when the deadline passes and `exn:cancelled` when the cancel evt wins. An adapter arms the watchdog at the start of each pull of its stream and disarms it before returning the chunk, which is the dsh rule "armed only while a read is outstanding".

### D. DeepSeek Messages adapter (`packages/llm/llm-deepseek/src`; R6 Formats 7 to 9, D)

The shipped DeepSeek adapter speaks the Anthropic Messages protocol at `{root}/messages`, not OpenAI Chat Completions. There is no `tool_choice`, `stream_options`, `reasoning_content` or prefix-completion field.

D1. **Model metadata** (`model-info.ts`). `context.contextWindow` is the catalog entry's, else `default-context-window`. `defaultMaxTokens` is the entry's `maxTokens`, else the route's `max-tokens` (always present). An uncatalogued model is `{provider, id, name: id, inputModalities: ["text"]}`. Reasoning: with `thinking: "disabled"` the only effort is `off` (default `off`); otherwise the efforts are `off`, `low`, `high`, `max` in that order with `defaultEffort` the configured `reasoningEffort`, else `high`. Effort names and descriptions: `Off` `Use for simple tasks that do not need reasoning.`; `Low` `Prefer for routine or latency-sensitive tasks.`; `High` `The default balance for most tasks.`; `Max` `Reserve for the hardest quality-first tasks.`. Result key order: `provider, id, name, description?, inputModalities, badge?, context, defaultMaxTokens, systemPromptUpdate?, toolUpdate?, reasoning`.

D2. **Call lifecycle** (`adapter.ts:65-89`). `adapter-prepare-call` resolves the connection (`connect`, else the options thunk), calls `admit`, and returns the model info plus a stream bound to that connection. `adapter-stream` uses the options thunk and `admit` directly. The stream is a producer stream with one idle watchdog over the request's cancel evt and `stream-idle-timeout-ms`; the watchdog is pulsed by every SSE event, every SSE comment and every resolved file. Failures raised while producing are mapped in this order: watchdog expired gives `TIMEOUT` `DeepSeek Messages stream idle timeout`; the request's cancel evt is ready gives `ABORTED` `DeepSeek Messages request aborted`; an `exn:fail:llm` is re-raised unchanged; anything else (`exn:fail:http`, port errors) gives `TRANSPORT` `DeepSeek Messages transport failed`. The original exception is the cause. Closing the stream shuts the call's custodian down, which closes the connection.

D3. **Request loop** (`adapter.ts:91-181`).

1. `check-cancel!`. Prepare images (D13). Resolve auth with `resolve-auth` (a missing credential fails here, before the anonymous user id is created).
2. Loop. Files mode first: resolve every image occurrence to a file id, each under its own `files-api-timeout-ms` deadline; any failure that is not caller cancellation switches the whole request to inline mode (never mixed), which re-checks the base64 budget.
3. Serialise (D5, D6), prepare extensions (D11), `check-cancel!`, compute beta headers, send (D4).
4. Status outside 200 to 299: read the whole body as text; parse JSON when possible; when file ids were used and the error names a missing, expired, deleted or invalid file, invalidate those index entries and go to 2 (once per request); otherwise raise the classified provider error (D9), with the message replaced by the normalised-image diagnostic of `request-files.ts` when the status is 400, file ids were used and the detail says the image is unsupported, invalid or cannot be decoded.
5. Status 2xx: call the prepared extensions' `accept`, then translate the SSE body (D7, D8) and emit its chunks; stop at the terminal `finish`.
6. Any failure after auth resolved passes through `request-auth-on-request-error` when present: its result is raised instead; if that procedure itself raises, the original failure is raised.

D4. **Endpoint and headers.** `POST <root>/messages` where `(messages-api-root base-url)` strips trailing slashes and appends `/v1` unless the URL path already ends in `/v1`. Default: `https://api.deepseek.com/anthropic/v1/messages`. Headers, merged in this order with later entries winning:

| Header | Value |
|---|---|
| `user-agent` | `(user-agent)` |
| `content-type` | `application/json` |
| `accept` | `text/event-stream` |
| auth | the `request-auth` headers: `x-api-key: <key>` or `x-dsh-auth-token: <token>`, no `Bearer` prefix |
| `anthropic-version` | `2023-06-01` |
| `anthropic-beta` | only when needed: `files-api-2025-04-14` when the body references file ids, `mid-conversation-tool-changes-2026-07-01` when any wire message has a `tool_addition` or `tool_removal` block; joined with `,` in that order |
| `x-deepseek-harness-user-id` | the anonymous user id (D15) |
| `x-deepseek-harness-session-id` | the request's session id, when present |
| `x-deepseek-harness-compact` | `1` when the purpose is `"compaction"` |

D5. **Request body.** A jobject with keys in this order: `model`, `stream: true`, `messages`, `max_tokens`, `thinking: {type}`, `output_config: {effort}` (only when the effort is not `off`), `system` (only when non-empty), `temperature` (only when set), `stop_sequences` (only when `stop` is set), `tools` (only when `tools` is not `#f`; an empty list is sent as `[]`), then the extension fields in the order the registry returned them. `max_tokens` is the request's, else the catalog model's `maxTokens`, else the route's. The effort `e` is the request's, else the configured `reasoningEffort`, else `off` when thinking is disabled, else `high`; `thinking.type` is `disabled` when `e` is `off`, else `enabled`. An effort outside `off`, `low`, `high`, `max`, or any effort but `off` when thinking is disabled, raises `UNSUPPORTED_REASONING_EFFORT` `DeepSeek Messages does not support reasoning effort <e>`. A tool is `{name, description, input_schema, defer_loading?}` with `defer_loading: true` only for a tool whose `deferLoading` is `#t`. Wire messages are `{role, content}` with role `user`, `assistant` or `system`. Wire blocks, keys in order: `{type: "text", text}`; `{type: "image", source: {type: "base64", media_type, data}}`; `{type: "image", source: {type: "file", file_id}}`; `{type: "thinking", thinking, signature?}`; `{type: "tool_use", id, name, input}`; `{type: "tool_result", tool_use_id, content, is_error?}`; `{type: "tool_addition" | "tool_removal", tool: {type: "tool_reference", name}}`. The body text is `(jvalue->string body)`.

D6. **Serialiser** (`serialize.ts:57-169`). `U(<what>)` below is `UNSUPPORTED_CONTENT` `DeepSeek Messages cannot represent <what>`.

1. User and tool-result content: a non-empty `text` gives a text block; `reasoning` and `tool-call` are skipped; an `image` gives a text block with `request-image-handle-text` followed by the image block (file reference in Files mode, else base64 of the request version's bytes); a missing request version raises `INVALID_REQUEST` `DeepSeek Messages request image is missing`, a missing file id in Files mode `INVALID_REQUEST` `DeepSeek Messages request file id is missing`; any other block type raises `U(user/tool-result content <type>)`.
2. Assistant content: a non-empty `text` gives text; `reasoning` gives `thinking` with the `signature` from validated replay state at the same position (D12); `tool-call` gives `tool_use` whose `input` is the parsed arguments when they parse to a JSON object (key order kept), else `{}`; other types raise `U(assistant content <type>)`.
3. A tool-change block outside a developer message raises `U(tool-change blocks outside developer messages)`.
4. System messages must be text only (`U(non-text system message)`); their text is the concatenation of their text blocks. For a catalog model with `systemPromptUpdate: "in-history"`, a system message that appears after at least one wire message is queued as a system update `{role: "system", content: [text]}` (empty text raises `U(empty in-history system update)`); every other system message replaces the top-level prompt (the latest wins). The body's `system` is the request's `system` and that prompt, without empty parts, joined with a blank line.
5. A developer message becomes a queued `system` wire message of `text` (non-empty), `tool_addition` and `tool_removal` blocks when at least one block results; another block type raises `U(developer content <type>)`.
6. Queued system updates are flushed immediately before the next non-empty assistant message and at the end; a flush requires the last wire message to have role `user`, else `U(system update without a preceding user or tool-result turn)`.
7. A tool message becomes a `user` wire message holding one `tool_result` (`is_error` present exactly when the message has `isError`; an empty result is kept). User and assistant messages with no resulting blocks are skipped. A wire message with the same role as the previous one is merged into it.
8. Validation pass over the wire messages: an assistant message sets the pending set to its `tool_use` ids (a repeated id raises `INVALID_REQUEST` `DeepSeek Messages duplicate tool call id`); a user message may answer only pending ids (`DeepSeek Messages tool result has no matching call`) and must answer all of them (`DeepSeek Messages tool calls need immediate results`), and its content is reordered with `tool_result` blocks first; pending calls at the end raise `DeepSeek Messages history ends with unresolved tools`. All three are `INVALID_REQUEST`.

D7. **Reading events** (`sse.ts`). Each SSE frame's data must be JSON (`MALFORMED_RESPONSE` `DeepSeek Messages SSE contains invalid JSON`) and a JSON object (`MALFORMED_RESPONSE` `DeepSeek Messages expected a JSON object`) with a string `type` equal to the frame's event name when the frame has one (`MALFORMED_RESPONSE` `DeepSeek Messages SSE event type mismatch`). A frame of type `error` raises the provider error of D9 with no status. Every frame and every comment pulses the watchdog.

D8. **Translation** (`translate.ts:104-166`). `M(<detail>)` is `MALFORMED_RESPONSE` `DeepSeek Messages stream: <detail>`; a field that must be a string and is not raises `MALFORMED_RESPONSE` `DeepSeek Messages expected a string field`. State: blocks by wire index (each gets the next dense local index), cumulative usage, `started?`, the stop reason.

1. `message_start`: a second one is `M(duplicate message_start)`; read `message.usage` (D10); set `started?`.
2. Event types other than `content_block_start`, `content_block_delta`, `content_block_stop`, `message_delta`, `message_stop` are skipped, before the next check. Any of those five before `message_start` is `M(event precedes message_start)`. An `index` that is not a non-negative safe integer is `M(invalid block index)`.
3. `content_block_start`: a repeated wire index, or a start after a stop reason was seen, is `M(block starts after settlement or repeats an index)`. `content_block` types: `text` (`text`), `thinking` (`thinking`, optional string `signature`), `tool_use` (`id`, `name`, object `input`; an empty id or name is `M(empty tool identity)`); another type raises `UNSUPPORTED_CONTENT` `DeepSeek Messages does not support response block <type>`. Emit `block-start`; then for text or thinking with non-empty initial text one delta with it; for a tool call `tool-call-delta {index, id, name, argumentsDelta: ""}`. The initial tool arguments are `(jvalue->string input)`.
4. `content_block_delta`: needs an open block, else `M(delta/stop without an open block)`. `text_delta` on a text block and `thinking_delta` on a reasoning block emit deltas and extend the block text; `signature_delta` on a reasoning block appends to the block's replay signature and emits nothing; `input_json_delta` on a tool call appends `partial_json` to the block's JSON buffer and emits `tool-call-delta {index, id, argumentsDelta}` with no `name`; any other pairing is `M(unsupported delta <delta type> for <block type>)`.
5. `content_block_stop`: needs an open block (same error); close it; a tool call whose JSON buffer is non-empty takes the buffer as its `arguments`; emit `block-end` with the complete block.
6. `message_delta`: when `delta.stop_reason` is not null map it (`end_turn` and `stop_sequence` to `stop`, `tool_use` to `tool-calls`, `max_tokens` to `max-tokens`, anything else `M(unsupported stop reason <value>)`); merge `usage` when present.
7. `message_stop`: without a stop reason, or with an open block, `M(message_stop without settled blocks and stop reason)`; zero blocks with reason `stop` raises `EMPTY_RESPONSE` `DeepSeek Messages returned no content`; unless the reason is `max-tokens`, every tool call's `arguments` must parse to a JSON object, else `M(tool input is invalid JSON)` or `MALFORMED_RESPONSE` `DeepSeek Messages expected a JSON object`; then emit `usage`, then `finish` with the replay envelope (one entry per block in local index order), and stop reading.
8. Input ending without `message_stop` raises `STREAM_CLOSED` `DeepSeek Messages stream ended before message_stop`. A 2xx response with no body raises `EMPTY_RESPONSE` `DeepSeek Messages returned no response body`.

D9. **Provider errors** (`transport.ts`). The error object is `raw.error` when it is an object. Message: its string `message`, else `DeepSeek Messages request failed (<status>)`, with `stream error` in place of a missing status. `detail` is `<type> <code> <message>` (empty strings for missing `type` and `code`). First match wins: status 401 or 403, or type `authentication_error` or `permission_error`, gives `AUTH`; `(quota-exceeded? detail)` or status 402 gives `QUOTA`; status 429 or type `rate_limit_error` gives `RATE_LIMIT`; `(context-window-exceeded? detail)` gives `CONTEXT_WINDOW_EXCEEDED`; status 400 or 413 or type `invalid_request_error` gives `INVALID_REQUEST`; status 500 or above, or type `api_error` or `overloaded_error`, gives `SERVER`; no status gives `SERVER`; else `HTTP_<status>`. `status` is set when known. `requestId` is the first present of the headers `request-id`, `x-request-id`, `x-deepseek-request-id`. `providerRetryAfterMs`: a `retry-after` value matching `^\d+(?:\.\d+)?$` is seconds times 1000; otherwise an HTTP date (IMF-fixdate, RFC 850 or asctime form) minus the current time; kept only when positive. The classifiers are the regular expressions of R6 A9, applied case-insensitively; port them to `pregexp` one for one and test each alternative.

D10. **Usage.** The cumulative usage starts as `{inputTokens: 0, outputTokens: 0}`. Each usage object is scanned in the order `input_tokens`, `output_tokens`, `cache_read_input_tokens`, `cache_creation_input_tokens`; a present value must be a non-negative safe integer (`M(invalid <wire key>)`) and is stored with `jset` under `inputTokens`, `outputTokens`, `cacheReadTokens`, `cacheWriteTokens`; the last value per counter wins. At `message_stop`, `totalTokens` is added last as the sum of the input, output and both cache counters (absent cache counters count as zero). `reasoningTokens` is never set. `input_tokens` is already uncached input; nothing is subtracted.

D11. **Extensions** (`request-extensions.ts`). `prepare-extensions` is called with `(extension-request body session-id purpose cancel)`; without the registry service the result is no fields and a no-op accept. A failure raises `REQUEST_EXTENSION` `DeepSeek request extension preparation failed: <error-chain>`. A field already present in the body raises `REQUEST_EXTENSION` `DeepSeek request extension field "<f>" collides with the base request`. The payload is the JSON text of the body with the fields appended. If rendering that text raises (a custom `prepare-extensions` returned a field that is not a jvalue), the payload is the base body, the field names are reported through `on-extensions-omitted`, and `accept` is a no-op. An `accept` failure is reported through `on-extensions-unaccepted` and swallowed.

D12. **Replay state** (`replay.ts`). Used only for an assistant message whose source has `replayState`. Structural mismatch (`response` or the envelope not an object; `kind` not `deepseek-messages` or `version` not 1: `unsupported kind or version`; `response.model` different from the source model: `model does not match assistant source model`; `blocks` not a list of the content's length: `block count mismatch`; an entry whose `type` differs from the content block's or is not `text`, `reasoning`, `tool-call`: `block type mismatch`; a `signature` on a non-reasoning entry or not a string: `invalid signature`) degrades that message to content without signatures and calls `on-replay-degrade` with the reason `DeepSeek Messages replay: <detail>`. Valid state for a different target model is dropped silently.

D13. **Images and files** (`images.ts`, `request-pricing.ts`, `image-tokens.ts`, `request-files.ts`, `file-store.ts`, `upload-index.ts`, `files-api.ts`). Offloaded images are replaced by `offloaded-image-text`. If images remain: the model must be a catalog model with the `image` modality, an `attachments` port must be mounted, and images may appear only in user and tool messages, else `UNSUPPORTED_CONTENT`; one request version is read per distinct `attachmentId` with `attachment-read-image-request` at `(resolve-request-image-target model ref)`; exceeding the raw budget raises `IMAGE_OFFLOAD_REQUIRED`. The request target, the vision token calculator, the Files API wire, the upload index file `llm-deepseek/files-v3.json` under the Harness home, single-flight uploads, quota cleanup and stale-id recovery are R6 Formats 8 and D9, D10; port them from the named files line by line. Multipart upload bodies and the index file lock are implemented in this package (`dsh-util` supplies atomic write).

D14. **Model listing** (`listing.ts`, `listing-cache.ts`, `listed-catalog.ts`). The `/models` request, entry decoding, cache behaviour (scope by credential digest, first-use wait, background refresh, single flight, generation counter, timer, last known good) and catalog gating (`CLIENT_UPGRADE_REQUIRED` `DeepSeek model "<m>" requires DeepSeek Harness <V> or later; current version is <C>`, `MODEL_UNSUPPORTED`) are R6 Formats 9 and D11, D12. The cache's timer and in-flight loads are tasks owned by the plugin fiber; disposal cancels and awaits them. Log lines go to the plugin's logger with the tag `[<short-name>]`. Badge validation needs explicit code-point sets for the Unicode property classes named in R6 "Hard parts"; grapheme counting uses `string-grapheme-count`.

D15. **Provider registration and the api-key plugin** (`host.ts`, `llm-deepseek-api-key/src`). `register-deepseek-provider!` builds the adapter, registers `(list provider)` on `ctx`, and listens to `loader/volatile-update`: when the resolved retry policy is no longer `equal?` to the registered one it calls `adapter-registration-replace!` with the same route (an exception from the options thunk is logged at `warning` and ignored). Warnings logged once per key: replay degradation (`llm-deepseek: unusable Messages replay state on assistant history for route "<provider>/<model>"; sending provider-neutral content (<reason>)`, key route plus reason), omitted extensions (`llm-deepseek: sending route "<route>" without request extension fields <names joined with ", "> because they failed to serialize`, key route), unaccepted extensions (`llm-deepseek: route "<route>" request extension acceptance failed; contributors resend on a later request`, key route); the last two log the exception with the message. The anonymous user id is the content of `<Harness home>/.anonymous-user-id` (a UUID, created with exclusive create on first use; `packages/identity/anonymous-user-id/src/index.ts`), resolved lazily and cached per adapter. The api-key plugin: route `deepseek-official`, provider name `DeepSeek`, directory entry `{provider: "deepseek-official", displayName: "DeepSeek", settingsNs, settingsPath: []}`. Key resolution: with a `credentials` port mounted, `(credential-resolve port ref)` is authoritative (absence there is absence); only without the port is the launch environment read (an empty value is absence); the value passes `assert-usable-api-key` with package `llm-deepseek`. A missing key raises `MISSING_CREDENTIAL` `llm-deepseek: no API key for provider route "deepseek-official"; store <REF> through the credentials service (the web Models page writes it), or export <REF> in the launching environment`. The route follows the official listing only when the origin of the resolved `baseURL` is `https://api.deepseek.com` and `models` equals the built-in catalog; on `loader/volatile-update` the listing cache is invalidated when that condition flips. `adapter-list-models` returns `'()` when no key is configured or the listing view is unauthenticated. Config is resolved once in the plugin body so a bad config fails at load.

D16. **Account plugin** (`llm-deepseek-account/src`). Route `deepseek-account`, provider name `DeepSeek Account`, directory entry likewise with `displayName: "DeepSeek Account"`. A config key `models` raises `llm-deepseek-account: models is no longer configurable; the account /models listing supplies the catalog. Remove models from this entry and adjust single models with modelOverrides.<model id>`. Auth: `(account-resolve-token port base-url)`; no port or no token raises `ACCOUNT_SIGN_IN_REQUIRED` `Sign in to DeepSeek to use the account provider. The request destination must allow account authentication.`; the header is `x-dsh-auth-token`. `on-request-error`: an `exn:fail:llm` with code `QUOTA` becomes code `ACCOUNT_QUOTA` with the same message and facts; one with status 401 becomes `ACCOUNT_TOKEN_INVALID` and `(account-reject-token! port token)` is called (its failure ignored); anything else is returned unchanged. `modelOverrides` problems are published by replacing the directory entry with one carrying `error` (the problems joined with `; `), and cleared the same way.

D17. **API key and attribution** (`api-key.ts`, `attribution.ts`). `normalize-api-key` trims, then returns `'empty` for `""` and `'illegal-characters` for anything not matching `^[\x21-\x7E]+$`. `assert-usable-api-key` raises `INVALID_CREDENTIAL` `<pkg>: the API key resolved from <ref> is blank; set <ref> to the raw key (the web Models page writes it) or export it in the launching environment`, or `<pkg>: the API key resolved from <ref> contains characters no HTTP header can carry; set <ref> to the raw key alone (the web Models page writes it)`; the key never enters a message. `(user-agent)` is `deepseek-harness/<version> (+https://github.com/deepseek-ai/deepseek-harness)` plus a space and the suffix when `DSH_USER_AGENT_SUFFIX` is set and non-empty; the variable is read on every call; a value not matching the RFC 9110 product pattern of R6 Formats 6 raises `exn:fail` `DSH_USER_AGENT_SUFFIX must be an RFC 9110 product token; got <json string>`. `<version>` is the dsh version this port tracks, `0.2.2-rc.2`, held in one constant.

### X. Extension registry (`packages/llm/deepseek-llm-api-extensions/src/index.ts`)

X1. `deepseek-extensions-prepare` raises `ABORTED` at once when the request's cancel evt is ready. It runs every registered provider, in registration order, each in its own task, and waits for all of them or for the cancel evt, whichever comes first; on cancel it raises `ABORTED` and leaves the provider tasks to finish unobserved.

X2. A provider that raises, or returns a value that is not a jvalue, is omitted from this request. The first such failure per field is logged at `warning` (`deepseek-llm-api-extensions: omitting field "<f>" from this request because its preparation failed`), later ones are silent, and nothing is logged when the request was cancelled.

X3. `fields` holds the values of the providers that returned one, in registration order.

X4. `accept` is memoised: the first call runs every `accept` procedure, each in its own task, waits for all to settle, then re-raises a single failure or raises `exn:fail:cordis:aggregate` with message `DeepSeek LLM API extension acceptance failed`; later calls wait for and return the same outcome.

### E. Retry executor (`packages/llm/llm-retry/src/index.ts:120-257`; R6 E)

The payload of `agent/request-error` is read with `jref`, so a jobject and a hash both work: `session`, `turn`, `step`, `provider`, `failure` (an `llm-failure`), `retryPolicy` (a `retry-policy` or absent), `cancel` (the turn's cancel evt). The listener returns `(jobj [kind "retry"])` to retry and `#f` for no decision.

E1. If the plugin is disposed, return `#f` without calling `next`. If the payload has no retry policy, return `(next)`. Otherwise make sure the projection registration has settled; then if the cancel evt is ready or the plugin is disposed, return `#f` without calling `next`.

E2. `(retry-policy-key policy)` is the JSON text of `["always", initialDelayMs, maxDelayMs, jitterRatio]` in always mode and of `["normal", maxRetries, <codes sorted with js-string<?>, initialDelayMs, maxDelayMs, jitterRatio]` in normal mode. For the default policy it is exactly `["normal",5,["EMPTY_RESPONSE","RATE_LIMIT","SERVER","TIMEOUT","TRANSPORT"],500,10000,0.1]`. The state key is the JSON text of `[provider, policyKey]`.

E3. Always mode: call `(next)` first; if it raises, log `llm-retry: provider "<p>" always policy ignored a downstream recovery failure` with the exception at `warning` and continue; if the cancel evt is ready or the plugin was disposed meanwhile, return `#f`; if the downstream result has `kind` `"retry"`, return it; otherwise continue. Normal mode: when the failure code is not in `retryable-codes`, return `(next)`.

E4. Read `(retry-state session)`; `previous` is the entry's `retry` under the state key, else 0. Normal mode with `previous >= max-retries` returns `(next)`. `retry` is `previous + 1`. `retryId` is the entry's, else a new UUID.

E5. Delay in milliseconds. When the failure has a positive `providerRetryAfterMs`: at most `max-delay-ms` it is used unchanged, without jitter; above it, normal mode returns `(next)` and always mode uses the local delay. The local delay is computed in flonum arithmetic as `min(min(initial * 2^min(retry - 1, 1024), max) * ((1 - j) + (2 * j) * r), max)` where `r` is one call of `random` and `j` the jitter ratio.

E6. Append `llm/retry` (Data). Wait for the first of `(delay-evt delay)`, the cancel evt, and the plugin's disposal. If the wait was cancelled return `#f`. Otherwise append `llm/retry-started` and return `{kind: "retry"}`. If the cancel evt is already ready when the wait starts, the wait is cancelled.

E7. The `llmRetry` fold: `step/start` and `turn/end` reset the state to `{}`; `llm/retry` stores `{retry, retryId}` under its state key (returning the same state when the entry is unchanged); every other event leaves the state alone. The budget is therefore per step and per provider with its exact policy.

E8. Disposal: one effect labelled `llm-retry: abort and drain active recovery` whose inverse removes the listener, marks the plugin disposed (which cancels every wait), and waits for every recovery in flight to return. The default `delay-evt` is an alarm on the monotonic clock.

### F. Token meter (`packages/llm/token-meter/src`; R6 F)

F1. **Estimator** (`estimate.ts`). Lengths are `utf16-length`; `J(v)` is `(utf16-length (jvalue->string v))`; `q(n)` is `ceil(n / 4)`. `text` and `reasoning` blocks: `q(len text) + 4`. `tool-call`: `q(len name) + q(len arguments) + 4`. Any other block: `4 + q(J(block))`, where an image block is rendered without its `offloaded` key. A non-system message: the sum over its blocks plus 4. A system message: 0 for empty content, else `q(chars) + 4` where a text block counts its text length and any other block `J(block)`. Tools: 0 when the header has no tools or an empty list, else `q(J(header.tools)) + 4`.

F2. **`token-meter-measure`** (`index.ts:151-296`, `surface-fold.ts`, `route-pricing.ts`). Per session the service keeps a rebuildable cache: surface nodes `{seq, heuristicTokens, imageStructuralTokens, fileStructuralTokens, images, files}` folded from surface events (`append` adds a node; a replace over `{startSeq, endSeq}` swaps the inclusive range for one node; a missing range raises `token surface: replace at seq <n> has invalid current range <a>-<b>`), the latest canonical request header, and a copy of nodes and header taken at each `assistant/message` before that message's node is added (the anchor). An `image/offload` event marks `targets[].imageIndexes` of the node at `targets[].seq` as offloaded. Pricing: a node's price is its heuristic price; minus the structural price of its files plus the estimate of a text block holding each file's handle text when an `llm` service is mounted; minus the structural price of its images plus `visualTokens + estimate of a text block holding price.text` per image when the routed adapter declares image pricing (one pricing call for the whole surface; a result of the wrong length raises `token meter: route image pricing answered <a> prices for <b> occurrences`). Result: with an anchor whose header equals the effective header, `anchorTokens = tools + price(anchor nodes) + assistantTokens`, the baseline is the provider usage (`input + cacheRead + cacheWrite + output`) when that is at least `anchorTokens`, else the estimate, and the surface delta is `current surface - (price(anchor nodes) + assistantTokens)`; otherwise the baseline is `none` (no header and an empty surface) or `estimated` (`tools + surface`) with delta 0. `totalTokens` is `max(0, baseline + delta)`. The cache is keyed weakly by session (`make-weak-hasheq` inside the service value) and resynchronised on each call and on `session/event` for sessions already read.

F3. **Projections.** `tokenMeasurement`: `measurement-projection.ts`, including the rule that the first event that fails to fold records `invalidSeq` and freezes the state. `tokenUsage` and `contextPressure`: `usage-projection.ts` and `surface-projection.ts` (a usage sample is the event's `usage`, else the last `usage` chunk of its stream; a second sample for the same turn and step replaces the first; `llm/retry-started` for that turn and step closes the slot; `pressureTokens = input + cacheRead + cacheWrite`; the shadow-price claim armed by `compaction/summary` or `compaction/prune` applies to the next replacement only, and a replacement over a different range raises `token surface: replace at seq <n> over range <a>-<b> has no adjacent shadow price (armed claim covers <c>-<d>)`). `contextBreakdown`: `breakdown-projection.ts`. Port each `apply` one for one; states have the keys of Data.

F4. **`derive-turn-token-usage`** (`turn-usage.ts:178`) is the strict state machine of R6 F4; every violation yields `#f`.

### G. Plugin package inventory (`packages/llm/plugin-package-inventory-deepseek/src/index.ts`; R6 G, Formats 10)

G1. The field value is `{version: 1, packages: [{name, version?}…]}`. Per request: `(active-plugin-packages loader session-id)` supplies name and version pairs for the active, non-group, enabled loader entries and for the modules of the requesting session's preset compositions. Entries are deduplicated by name and version (an absent version counts as `""`) and sorted by name, then version, with `js-string<?`. `version` is present only for a non-blank string. The field is present on every extended request, including with an empty list. Identities may be cached for the life of the plugin.

### P. pi-ai routes (`packages/llm/llm-pi-ai/src`; R6 H)

dsh implements this plugin over a Node library that owns the wire protocols and a catalog of models for 42 providers. The Racket port keeps the plugin's own behaviour and implements two protocols natively.

P1. **Profiles** (`config.ts`). The config is validated by the schema and then resolved to profiles with the dsh rules: `providers` given as a list, and the removed fields `provider`, `maxRetries`, `maxRetryDelayMs`, raise the dsh messages; bounds of R6 Configuration are re-checked; `imageOffloadCountQuantum` defaults to `min(10, maxRequestImages)`. Resolution is memoised on the identity of the raw `providers` value, and every operation captures one resolved snapshot before its first await.

P2. **What is served natively.** A route is *served* when one of these holds: (a) its profile sets `api` to `openai-completions` or `anthropic-messages` and gives `baseURL` and a non-empty `models`; (b) its profile sets no `api`, its key is in the native table below, and it gives a non-empty `models` (`baseURL` defaults from the table). Native table, `openai-completions`: `deepseek` (`https://api.deepseek.com`, `DEEPSEEK_API_KEY`), `openrouter` (`https://openrouter.ai/api/v1`, `OPENROUTER_API_KEY`), `groq` (`https://api.groq.com/openai/v1`, `GROQ_API_KEY`), `cerebras` (`https://api.cerebras.ai/v1`, `CEREBRAS_API_KEY`), `together` (`https://api.together.ai/v1`, `TOGETHER_API_KEY`), `xai` (`https://api.x.ai/v1`, `XAI_API_KEY`), `moonshotai` (`https://api.moonshot.ai/v1`, `MOONSHOT_API_KEY`), `moonshotai-cn` (`https://api.moonshot.cn/v1`, `MOONSHOT_API_KEY`), `nvidia` (`https://integrate.api.nvidia.com/v1`, `NVIDIA_API_KEY`), `huggingface` (`https://router.huggingface.co/v1`, `HF_TOKEN`), `baseten` (`https://inference.baseten.co/v1`, `BASETEN_API_KEY`), `zai` (`https://api.z.ai/api/coding/paas/v4`, `ZAI_API_KEY`), `zai-coding-cn` (`https://open.bigmodel.cn/api/coding/paas/v4`, `ZAI_CODING_CN_API_KEY`). Native table, `anthropic-messages`: `anthropic` (`https://api.anthropic.com`, `ANTHROPIC_API_KEY`), `minimax` (`https://api.minimax.io/anthropic`, `MINIMAX_API_KEY`), `minimax-cn` (`https://api.minimaxi.com/anthropic`, `MINIMAX_CN_API_KEY`). Every other route is *unserved* in wave 3: the other 26 provider ids of `provider-data.generated.ts`, any route with `api` `openai-responses` or `google-generative-ai`, any route whose `compat.thinkingFormat` is neither `openai` nor `deepseek`, and any route with `transport` other than `sse`. An unserved route registers no adapter and its directory entry carries `error`: `llm-pi-ai: provider "<route>" is not served natively by the Racket harness; declare api ("openai-completions" or "anthropic-messages"), baseURL and models, or use the Node sidecar when it is available`. A served native-table route without `models` carries `error`: `llm-pi-ai: provider "<route>" has no model catalog in the Racket harness; declare models`. A route outside the provider data with no `api`, `baseURL` or `models` is the dsh configuration error (strict validation refuses it; deferred validation records it as `error`).

P3. **Registration** (`index.ts`). Directory entries: one per provider id of the provider data, in that file's order, `{provider, displayName: provider, settingsNs, settingsPath: ["providers", provider], declared: false, defaultBaseURL?, baseURLEnv?, nativeAuth: {env, oauth: false}}`; then each configured profile replaces or adds its entry with its `displayName`, `declared: true` when its key is not in the provider data, and `error` when it has one. The adapter registers the served routes; a bare mount registers none. On `loader/volatile-update` the route set is replaced when the list of `{provider, displayName, retryPolicy}` sorted by provider changed, and the directory when its entries changed; a conflict is logged at `error` (`llm-pi-ai: configuration conflicts with an existing provider route`) and the previous registration stays. An `internal/config` listener validates a candidate config for this plugin's own fiber with the strict rules before it is accepted. `llm-register-model-discovery!` is called with the settings namespace (P12). Login flows and the credential-record bridge are not provided in wave 3; `oauth` is always `false`.

P4. **Model metadata.** `context.contextWindow` is the model's `contextWindow`, else `defaultContextWindow`. `defaultMaxTokens` is present only when the profile set `maxTokens` for that model. `inputModalities` is the model's `input`, else `defaultInput`. `reasoning` is present only when the model has a `reasoningEfforts` dict: the efforts are its keys in the canonical order `off`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`, each `{id, name}` with the name capitalised, and `defaultEffort` is the profile's `reasoning` when it is one of them. Native routes declare neither `systemPromptUpdate` nor `toolUpdate`, so the runtime drops developer messages and strips deferral (T5 rule 1). `adapter-list-models` returns `'()` while the route's named credential is missing.

P5. **Request checks** (`adapter.ts:407-514`), in order: `stop` set raises `UNSUPPORTED_OPTION` `llm-pi-ai does not support GenerateOptions.stop`; a route this adapter does not serve raises `NO_ADAPTER` `pi-ai adapter does not own provider "<p>"`; an unknown model raises `UNKNOWN_MODEL` `pi-ai provider "<p>" has no configured model "<m>"`; an effort (request, else profile `reasoning`) the model does not list raises `UNSUPPORTED_REASONING_EFFORT` `pi-ai provider "<p>" model "<m>" does not support reasoning effort "<e>"`. Credential: a profile naming `apiKeyEnv` resolves it (credentials port, else launch environment), passes `assert-usable-api-key` with package `llm-pi-ai`, and on a miss raises `MISSING_CREDENTIAL` `llm-pi-ai: no credential for provider route "<p>"; its profile resolves <REF>, which is not set — store <REF> through the credentials service (the web Models page writes it) or export it, and remove apiKeyEnv only if this provider should authenticate from pi-ai's own environment discovery`; a native-table route without `apiKeyEnv` uses the table's variable the same way and sends no credential when it is unset. Images need the model's `image` input (`UNSUPPORTED_CONTENT` `pi-ai model "<m>" does not support image input`) and the attachments port (`UNSUPPORTED_CONTENT` `pi-ai image input requires the durable attachment service`); the base64 budget uses `maxRequestImageBytes`, `maxRequestImages`, `imageOffloadCountQuantum` and raises `IMAGE_OFFLOAD_REQUIRED` `pi-ai request images exceed the route image budget; <n> more oldest occurrence(s) must be offloaded.` with `offloadImages`. Headers: the profile's `headers`, then the protocol headers, then the result of the `llm-pi-ai/request-headers` waterfall (a failure raises `REQUEST_HEADERS` `pi-ai request header preparation failed for provider "<p>": <message>`), then `user-agent` overwritten with `(user-agent)`. Idle watchdog over `streamIdleTimeoutMs`: expiry raises `TIMEOUT` `pi-ai stream idle timeout after <N>ms`; caller cancellation raises `ABORTED` `pi-ai request aborted by caller`; other transport failures raise `TRANSPORT`.

P6. **Context conversion** (`context.ts`), shared by both protocols. The system prompt is the request's `system` and the text of every leading system message, non-empty parts joined with a blank line. A later system message becomes a user message whose text is `<system-reminder>`, a newline, the text with every `</system-reminder>` replaced by `<\/system-reminder>`, a newline, `</system-reminder>`. A non-text system message raises `UNSUPPORTED_CONTENT` `pi-ai cannot represent non-text system messages`; a tool-change block outside a developer message raises `UNSUPPORTED_CONTENT` `Tool-change blocks require developer role`; an image in an assistant or system message raises `UNSUPPORTED_CONTENT` `pi-ai cannot represent an image in an in-history <role> message`. User text blocks are concatenated with no separator; with images, the content is a list of parts in which each image is preceded by its `request-image-handle-text`. A tool result carries the call id, the tool name of the matching earlier call (else `unknown`), the same content rules, and `(no output)` when its text is empty. Unparseable tool arguments in history become `{}`.

P7. **`openai-completions` wire** (native design; public Chat Completions protocol). `POST <baseURL>/chat/completions` with `content-type: application/json`, `accept: text/event-stream`, and `authorization: Bearer <key>` when a key was resolved. Body keys in order: `model`, `messages`, `stream: true`, `stream_options: {include_usage: true}` (omitted when `compat.supportsUsageInStreaming` is `false`), the output cap under `compat.maxTokensField` (default `max_completion_tokens`) when the request has `maxTokens`, `temperature` when set, `tools` (`[{type: "function", function: {name, description, parameters}}…]`) when the request has at least one tool, and the effort: with `thinkingFormat` absent or `openai`, `reasoning_effort: <wire spelling>` when the effort is not `off` and `compat.supportsReasoningEffort` is not `false`; with `thinkingFormat: deepseek`, `thinking: {type: "enabled" | "disabled"}`. Messages: the system prompt as `{role: "system", content}` (`developer` when `compat.supportsDeveloperRole` is `true`); user as `{role: "user", content}` with a string, or parts `{type: "text", text}` and `{type: "image_url", image_url: {url: "data:<mediaType>;base64,<data>"}}`; assistant as `{role: "assistant", content: <text or null>, tool_calls?: [{id, type: "function", function: {name, arguments}}…]}`; tool as `{role: "tool", tool_call_id, content}` plus `name` when `compat.requiresToolResultName` is `true`. Historical reasoning is not sent, except as `<thinking>…</thinking>` text when `compat.requiresThinkingAsText` is `true`, and as `reasoning_content` (the concatenated reasoning, possibly empty) when `compat.requiresReasoningContentOnAssistantMessages` is `true` and the effort is not `off`. With `compat.requiresAssistantAfterToolResult`, a user message that follows tool results is preceded by `{role: "assistant", content: "I have processed the tool results."}`. Other compat switches are accepted and not applied; each one set on a served route is logged once at `warning` at load.

P8. **`openai-completions` stream.** SSE frames whose data is JSON; the frame `[DONE]` ends the stream. From `choices[0].delta`: `reasoning_content` or `reasoning` text feeds a reasoning block; `content` feeds a text block; each `tool_calls` item (keyed by its `index`) feeds a tool-call block whose first delta carries `id` (else `call-<block index>`) and `name` and whose later deltas carry the same id without `name`. Blocks get dense indexes in first-seen order; a block's `block-end` is emitted when a different block starts receiving deltas or at the end, and every open block is closed before `usage`. `finish_reason`: `stop` gives `stop`, `length` gives `max-tokens`, `tool_calls` or `function_call` gives `tool-calls`, anything else raises `PI_AI_ERROR`. A `stop` with no blocks raises `EMPTY_RESPONSE` `model "<m>" returned a completed response with no content`. Unless the reason is `max-tokens`, every tool call's arguments must parse to a JSON object, else `MALFORMED_RESPONSE`. Usage, keys in order: `inputTokens` (`prompt_tokens` minus `prompt_tokens_details.cached_tokens`), `outputTokens` (`completion_tokens`), `totalTokens` (`total_tokens`), `cacheReadTokens` only when the cached count is positive. Without a usage frame the usage is `{inputTokens: 0, outputTokens: 0, totalTokens: 0}`. Then `finish` with the replay envelope (P11). A body that ends without `finish_reason` raises `TRANSPORT` `pi-ai openai-completions stream ended without finish_reason`.

P9. **`anthropic-messages` wire** (native design; public Messages protocol). `POST <root>/messages` with `(messages-api-root baseURL)`, `x-api-key`, `anthropic-version: 2023-06-01`. Body keys in order: `model`, `max_tokens` (the request's, else the model's `maxTokens`, else `defaultMaxTokens`), `messages`, `stream: true`, `system` when non-empty, `temperature` when set, thinking is off and `compat.supportsTemperature` is not `false`, `thinking: {type: "enabled", budget_tokens}` when the effort is not `off`, `tools` (`[{name, description, input_schema}…]`) when the request has tools. The budget is the profile's `thinkingBudgets` entry for the effort's wire spelling (defaults `minimal` 1024, `low` 2048, `medium` 8192, `high` 16384), capped at `max_tokens - 1`; a wire spelling that names no budget is refused at load with `INVALID_CONFIG`. Messages follow D6 rules 1, 2, 7 and 8 with the label `pi-ai Anthropic Messages`; a reasoning block is sent only with a signature that passed P11, otherwise it is omitted. The response is translated with `make-messages-translator` under that label, with the usage of D10 re-keyed as `inputTokens`, `outputTokens`, `totalTokens`, then `cacheReadTokens` and `cacheWriteTokens` only when positive. When every projected tool is deferred this protocol adds the declaration `{name: "DeferredToolPlaceholder", description: "Reserved placeholder that keeps deferred tool loading active; never call this tool.", input_schema: {type: "object", properties: {}}}` (unreachable while native routes declare no tool update mode; kept for parity).

P10. **Provider errors on native routes.** A non-2xx response or an in-band error object is classified as D9 with the fallback message `pi-ai request failed (<status>)`; a code that D9 would spell `HTTP_<status>` is `PI_AI_ERROR`. Context overflow is `CONTEXT_WINDOW_EXCEEDED`.

P11. **Replay envelope** (`replay.ts`, `prefix-binding.ts`). `response` is `{kind: "pi-ai", version: 2, api, provider, model, responseModel?, responseId?, stopReason, prefixDigest?}` with `stopReason` one of `stop`, `length`, `toolUse`; `blocks` has one entry per block: `{type: "text"}`, `{type: "reasoning", thinkingSignature?, redacted?}`, `{type: "tool-call"}`. An assistant message whose replay state is absent, of another kind, version, api or model, or structurally wrong is sent as plain content (the "foreign" case) and the reason is logged at `warning`: `llm-pi-ai: unusable replay state on assistant history for route "<provider>/<model>"; sending that message as provider-neutral content (<reason>)`. On `anthropic-messages` the digest chain of R6 H6 binds signed thinking: `d0 = sha256hex(seed + NUL + JSON of {systemPrompt, tools})` with seed `dsh-llm-pi-ai/prefix-binding/v1`, each message extends it, a historical message keeps its signed thinking only when its recorded `prefixDigest` equals the chain value at its position, and the final digest is stored in the new envelope. Digests only need to be self-consistent within the Racket harness.

P12. **Discovery** (`discovery.ts`). For an `openai-completions` draft: `GET <baseURL>/models` with `authorization: Bearer <key>`; for `anthropic-messages`: `GET <root>/models?limit=1000` with `x-api-key` and `anthropic-version: 2023-06-01`, where the listing URL accepts the root with or without `/v1`. A named configured route supplies its stored credential and profile `headers`; a key in the request wins. Replies over 4 MiB are refused. The parser accepts a `data` array or a `models` map and normalises `id`, display name, context window and output cap as R6 H7 and the package README describe; fixtures are `packages/llm/llm-pi-ai/tests/fixtures/model-listings/*.json`. Failures raise `DISCOVERY_FAILED`; a draft with another `api` raises `DISCOVERY_UNSUPPORTED`. A request naming a native-table provider and no `baseURL` uses the table's endpoint.

### I. Replay (`packages/test-support/llm-replay/src/index.ts`; R6 Formats 14, I; R18 B, C)

I1. **Plugin.** `file` is the config's, else `DSH_SNAPSHOT_FILE`; missing or empty raises the error of Plugins. `overrideFile` and `childFiles` default from the environment as stated there. Model config is checked at load with the dsh messages (`index.ts:1142-1192`): `inputModalities` only `text` and `image`; `imageRequestTokens` a positive safe integer and only with `image`; `systemPromptUpdate` only `in-history`; `toolUpdate` only the two modes; `badge` with non-blank text (or translations including `en`) and a known tone. `paceMs` other than a non-negative integer raises `llm-replay: paceMs must be a non-negative integer, got <v>`. The plugin passes `(ctx-get ctx 'racket:sessionFixtureDecoder)` as `#:decode` when that optional service is mounted, else the default decoder.

I2. **Fixture parsing.** Lines are split at LF or CRLF; blank lines are skipped; each must be a JSON object (`session snapshot line <n> contains invalid JSON`, `session snapshot line <n> must be a JSON object`). The first is the header: a version 0 header without `delegationDepth` gets `0`; a `cwd` starting with `{{cwd}}` (followed by `/` or the end) has that token replaced by `/dsh-snapshot-cwd`. Each body row: for `request/header`, `data.header.tools` equal to `"{{tools}}"` is removed, and a non-empty list of names becomes `[{name, description: "", parameters: {}}…]`. Rows either all carry `seq` and `time` (`seq0` and `time0` for the packed historical row types `text-chunks`, `reasoning-chunks`, `tool-call-chunks`) or all omit them (`session snapshot line <n> must contain both <seq key> and <time key>, or neither`; `session snapshot line <n> cannot mix projected and complete body rows`); when omitted, rows get dense sequence numbers from 0 and time 0, a packed row advancing the sequence by its member count. The header and rows then go through `decode`. `decode-current-session-fixture` accepts only a header whose `version` equals `session-format-version` of `dsh-session`, converts each row with `jvalue->session-event`, and takes the inherited count from the header's `inheritedEventCount` (0 when absent); another version raises `exn:fail` naming the version and saying that older generations need the format catalog of `dsh-session-store`. No header raises `session snapshot must start with a session header`. Errors from `decode` are re-raised as `session snapshot line <n>: <detail>`.

I3. **Script derivation.** Walk the events in order. Each `assistant/message` and `assistant/attempt` yields `{kind: "chunks", chunks}` with the chunks of `(expand-assistant-stream data.stream)`; an empty expansion yields nothing; a last chunk that is not `finish` raises `llm-replay: model call <turn>/<step> ended without a finish chunk (a thrown stream); this scenario needs a replay.override.json sidecar`. Each `compaction/summary` with `llmStreamCall` true yields a synthetic entry from `rawOutput`: per block `block-start {index, blockType}` then `block-end {index, block}`, then `usage` when recorded, then `finish {reason: {kind: "stop"}}`; a marked summary without `rawOutput` raises `llm-replay: compaction/summary marks an LLM stream call without rawOutput`. Child fixtures derive only from the events at index `inherited-event-count` onward.

I4. **Override documents.** Read only when the file exists. A list replaces the whole primary script (the fixture file may then be absent; its recorded id is `""` and time 0). `{patches}` is applied over the derived script: `at` equal to the derived length appends; greater raises `llm-replay: override patch index <at> out of range (derived script has <n> call(s); == length appends): <file>`; a repeated `at` raises `llm-replay: duplicate override patch index <at>: <file>`. Validation is by exact key set with the messages `llm-replay: invalid override <file>: <location> <detail>` of `index.ts:516-600`. A missing primary fixture with no replacing override raises ``llm-replay: fixture not found: <file> — run `pnpm run test:snapshot:record` first``; a missing child file raises `llm-replay: child fixture not found: <file> — re-record the scenario`.

I5. **Placeholders**, resolved at call time in every string of the entry. `{{session:N}}` (N at least 1) becomes the live session id bound to script N, else `llm-replay: session token {{session:<N>}} was used before that recorded session bound`. `{{fromRequest:<regex>}}`: the corpus is every string leaf of the live request's messages joined with newlines; the pattern is compiled with `pregexp`; the last match wins and contributes its first group when it has one, else the whole match. The placeholder ends at the last two braces of a run of `}`. Errors: `llm-replay: fromRequest has an invalid pattern <json>: <detail>`, `llm-replay: fromRequest pattern <json> matched nothing in the request`, `llm-replay: fromRequest placeholder is unterminated in <json>`.

I6. **Binding.** Scripts are ordered primary first, then children by `created-at` and recorded id. A call's key is the request's session id, or one shared anonymous key. A key seen for the first time claims the next unclaimed script. The cursor for the key advances at call time, before any chunk is pulled. Two errors are deferred into the returned stream's first pull: `llm-replay: a model call arrived from an unrecorded session (#<n>); the scenario recorded only <m> session(s) — re-record it` and `llm-replay: script exhausted — session requested model call #<k> but its script has only <n>; re-record the scenario`. Both are plain `exn:fail`.

I7. **Playback.** Before the first chunk, when the request's provider is `deepseek-official`, the extension registry is mounted, and the entry counts as accepted (`chunks` and `hang` always; `throw` when `accepted` is true, or absent with a non-empty `chunks`), call `deepseek-extensions-prepare` with body `{messages: []}` and the request's identity, then its `accept`. `chunks`: before each chunk raise `exn:fail` `aborted` when the cancel evt is ready, wait `paceMs` when positive (cancellable, same error), then emit. `throw`: emit the prefix the same way, then raise `(llm-failure->exn {message, code})`. `hang`: emit `block-start {index: 0, blockType: "text"}` and `text-delta {index: 0, text: "partial"}`, write an empty `readyFile` when named, then wait for the cancel evt and raise `exn:fail` `aborted`.

I8. **Two mounting modes.** With a non-empty `providers`, replay registers one adapter for those routes (model metadata from the config as in R18 Configuration), so a raised entry passes the adapter boundary and reaches the loop as a terminal error finish with the scripted code. Without `providers`, replay is an `llm/stream` listener that never calls `next`, so a raised entry stays raised. `replay-handle-dispose!` removes whichever was registered.

I9. `replay-assert-consumed!` raises `llm-replay: fixture not fully consumed — <problems>; the scenario drove fewer model calls than recorded` where the problems, joined with `; `, are `<n> recorded script(s) never bound to a live session` and, per bound key with calls left, `the anonymous session consumed <a>/<b> recorded call(s)` or `session <id> consumed <a>/<b> recorded call(s)`.

### M. The mock adapter (`racket:llm-mock`)

M1. A script is a list of turns. A turn is a list of stream-chunk jobjects, a `mock-failure`, or a procedure from the `llm-request` to one of those. One call to `adapter-stream` records the request, takes the next turn (the cursor advances at call time) and returns a stream that emits the turn's chunks in order; a `mock-failure` emits its chunks and then raises `(llm-failure->exn {message, code})`. A turn procedure runs at the first pull.

M2. A call past the end of the script returns a stream whose first pull raises code `MOCK_SCRIPT_EXHAUSTED` with message `racket:llm-mock: script exhausted — model call #<k> but the script has only <n> turn(s)`. Through `llm-stream` this reaches the consumer as a terminal error finish.

M3. Before each chunk the stream raises code `ABORTED` `racket:llm-mock: request aborted` when the request's cancel evt is ready.

M4. `mock-reply` builds one complete response from content blocks. For each block in order, with its position as the index, it emits `block-start`, then one delta carrying the whole text (text or reasoning) or one `tool-call-delta` with id, name and the whole arguments, then `block-end`. After the last block it emits `usage` (default `{inputTokens: 0, outputTokens: 0}`), then `finish` with `tool-calls` when any block is a tool call, else `stop`, unless `#:finish` gives a reason. `mock-text` and `mock-tool-call` are `mock-reply` of one block.

M5. Model metadata: `#:models` entries are resolved model infos without `provider`; an unlisted model resolves to the fallback. `mock-llm-assert-consumed!` raises when turns remain.

### V. The mock server (`packages/test-support/llm-mock-server/src`; R6 Formats 13, J)

V1. `start-mock-llm-server` listens with `tcp-listen` on the host and port given (port 0 lets the system choose) and serves each connection in its own thread under a custodian that `mock-llm-server-close!` shuts down. Option validation, routing (405, 404, 401, 400 replies that do not consume the script), script consumption with `repeat-last?`, the SSE building blocks, the 23 concrete behaviours and `random`, the request records and telemetry events are R6 Formats 13 exactly; the random generator and weighted choice are R6 J. Text is cut into deltas of `chunk-size` code points; `output_tokens` counts code points; the tool arguments are split at `max(1, floor(utf16-length / 2))` UTF-16 units.

V2. Wire details that Node supplied implicitly: SSE responses use `Transfer-Encoding: chunked` with one HTTP chunk per SSE frame and are flushed per frame; error replies use `Content-Length`. "Destroy the socket" is closing both ports without the terminating chunk. `stall` keeps the connection open and idle until either side closes.

V3. The command line accepts the flags, checks and JSONL output of R6 Formats 13 last paragraph, with exit codes 130 on interrupt, 143 on terminate and 1 on an argument error.

### Invariants

1. Model-visible implies logged: every projection applied at the adapter boundary (file handles, text-only placeholders, tool updates, offload placeholders) is a pure function of the logged request plus the current execution-world path mapping.
2. A stream delivered through the adapter boundary carries at most one `finish`, `usage` precedes it, and nothing follows it.
3. Replay state never reaches an adapter instance other than the one registered for the route that wrote it.
4. The retry policy offered with a failure is the one captured when the call was prepared.
5. A scheduled retry is in the log before its wait begins.
6. Registry notifications fire after the commit and cannot veto it.
7. No procedure in this package mutates a request, a message or a chunk; every "change" is a new value.

## Racket design notes

1. **Data instead of classes.** The vocabulary is plain jobjects (see Data for the reasons). `BlockAssembler` and `AssistantStreamAccumulator`, mutable classes in dsh, are immutable values with a `push` that returns the next value; a live attempt in the loop is a fold. Text is accumulated as a reversed list of fragments and joined on read.

2. **`define-jrecord` and `define-junion`.** One declaration yields the constructor, predicate, accessors and `match` pattern of a JSON record. The bug classes it removes: a key written in the wrong order or with the wrong spelling in durable data (the constructor is the only place the order exists; a misspelled accessor is an unbound identifier); an optional field written as a null instead of being omitted; a constructor, a predicate and a pattern that drift apart. `union-case` gives the closed unions (`stream-chunk`, `stream-record`, `message`) the compile-time counterpart of dsh's `assertNever`: a consumer that forgets a variant does not compile, and adding a variant breaks every incomplete consumer at expansion time. Open unions must spell out their `#:else`, which is the documented fall-through dsh requires.

3. **Pull-based streams.** An `AsyncIterable` becomes a `chunk-stream` whose producer runs inside the consumer's pull (a generator, not a thread). Three consequences. The dsh adapter boundary needs two nested `try` blocks so that an exception thrown into the generator by its consumer is not mistaken for an adapter failure; with a pull there is no such path, so the rule "adapter failures become a finish chunk, consumer failures propagate" holds by construction and the boundary is one handler around one pull. A break delivered to the consuming task unwinds through the producer naturally. And the idle watchdog's "armed only while a read is outstanding" is simply "armed for the duration of a pull".

4. **A custodian per call.** dsh fuses an `AbortController` with the caller's signal and closes the inner iterator in `finally`. Here a producer stream runs under its own custodian and closing the stream shuts it down, which reclaims the socket, the TLS state and any helper thread without the adapter listing them. Explicit `on-close` remains for state that is not a custodian-managed resource.

5. **Events for cancellation and time.** `AbortSignal`, `AbortSignal.any`, `setTimeout` and the watchdog class become one `choice-evt` over the I/O evt, the cancel evt and an alarm. Retry waits, replay pacing, listing timeouts and file deadlines are the same shape.

6. **A generic interface for the seam.** `LlmAdapter` is an abstract class with seven overridable methods; `gen:llm-adapter` with fallbacks says the same thing, and an adapter is a struct. `make-llm-adapter` covers the common case of "a stream procedure and some metadata" without a struct definition.

7. **Ports instead of structural types.** dsh reads `attachments`, `fs`, `credentials`, `deepseekAccount` and the loader through structural TypeScript types so that `dsh-llm` need not depend on their packages. The Racket form is a generic interface owned by the consumer and implemented by the provider's service struct; a mounted value that does not implement it fails loudly at the first read.

8. **The loop mark is a field.** dsh marks loop-built requests in a module-level `WeakSet`. Requests here are immutable structs, so the mark is a private field that only `mark-agent-loop-request` sets and every functional update clears. No module-level state exists.

9. **Failure normalisation is short.** dsh guards against hostile property getters on thrown JavaScript values. A Racket exception has no such surface: only `exn:fail:llm` carries a trusted failure, other harness errors contribute their code, and everything else is `UNKNOWN`.

10. **Registration handles** are applicable structs (`prop:procedure` disposes) with a separate `replace!` procedure, in place of a function object with a method attached.

11. **Volatile config** is read through `config-get` once per operation; `Volatile<T>` references are not spread through the code.

12. **Own HTTP client.** `net/http-client` decodes chunked bodies on a helper thread and reports a truncated body as a clean end of file. The recovery behaviour of this package depends on telling `STREAM_CLOSED` (the server finished without `message_stop`) from `TRANSPORT` (the connection dropped), so `dsh-llm/http` reads the raw ports itself. Blocking phases run under `blocking`; body reads are evts awaited in the task.

13. **Not ported.** `structuredClone` and deep freezing (values are immutable); zod state schemas (projection states are checked by the provider of the projection registry, if at all); the typert `@Remote` decorators; `using` disposal; the fallback for extension values that fail to serialise is kept only as a guard around `jvalue->string`.

Racket-only extensions introduced here, for the coordinator to record in an ADR:

- Module `dsh-llm/cancel`: cancel sources, cancel evts and `exn:fail:abort`, the Racket form of `AbortController` and `AbortSignal` for every package (ADR 0002).
- Plugin `racket:llm-mock` and its service key `racket:llmMock`; failure code `MOCK_SCRIPT_EXHAUSTED`.
- Optional service key `racket:sessionFixtureDecoder`: a fixture decoder (the `decode` procedure of I2) that the `llm-replay` plugin uses when mounted, so `dsh-session-store` can supply older Session format generations without `dsh-llm` depending on it.
- The mock server's command line is a Racket module (`dsh-llm/testing/mock-server-cli`).
- Test seams with no dsh counterpart in configuration: `#:id` on message constructors, `#:http-request` on the DeepSeek adapter, `#:delay-evt` on the retry executor.
- The `llm-pi-ai` native protocol rules P7 to P10 and the two directory `error` texts of P2.

No `x-racket` config key is introduced by this package.

## Work units

The package is too large for one implementer. Three units, each with its own tests:

| Unit | Modules | Depends on |
|---|---|---|
| 1. Vocabulary and runtime | `cancel`, `jrecord`, `messages`, `errors`, `stream`, `content`, `retry-policy`, `attribution`, `ports`, `adapter-kit`, `llm`, `extensions`, `retry`, `testing/mock`; plugins `llm`, `deepseek-llm-api-extensions`, `llm-retry`, `llm-mock`; `plugins` (the full table, all rows) | `cordis`, `cordis-data`, `cordis-schema`, `dsh-util`, `dsh-session` |
| 2. DeepSeek route | `http`, `sse`, `deepseek/*`, `testing/mock-server`, `testing/mock-server-cli`; plugins `llm-deepseek-api-key`, `llm-deepseek-account`, `plugin-package-inventory-deepseek` | unit 1 |
| 3. Meter, replay, pi-ai | `token-meter`, `replay`, `pi-ai/*`; plugins `token-meter`, `llm-replay`, `llm-pi-ai` | unit 1; from unit 2 only the items below |

Order: unit 1 first, and inside it `cancel` and `jrecord` before anything else: `dsh-tools` re-exports `cancel` and `dsh-agent` declares its stream frames with `define-jrecord`, and both are built in the same wave. Units 2 and 3 start as soon as unit 1's public modules exist with the signatures of this document (bodies may still be stubs for a day), and run in parallel. Inside unit 2 the text path comes first (`http`, `sse`, `deepseek/config`, `serialize`, `translate`, `transport`, `adapter`, `host`, the api-key plugin, the mock server); listing, listed catalog, the account plugin, images, image tokens and files follow. The image and Files paths cannot be exercised end to end until `dsh-fs` provides `attachments`, so they may land after the wave 3 gate with unit tests against the mock Files server of `packages/llm/llm-deepseek/tests/mock-server.ts`. Inside unit 3, token meter and replay come first, then `pi-ai/config` and `openai-completions`, then `anthropic-messages`.

The internal interface unit 3 takes from unit 2, beyond the public signatures already listed (`http-request`, `http-response-read!`, `make-sse-reader`, `sse-read!`, `make-messages-translator`, `translator-push!`, `translator-finish!`, `provider-error`, `messages-api-root`):

```racket
;; dsh-llm/deepseek/serialize
(messages-wire-history history
                       #:label label                       ; error-message prefix, e.g. "pi-ai Anthropic Messages"
                       #:image->blocks image->blocks       ; (-> image-block (listof wire-block))
                       #:thinking-signature signature-of   ; (-> assistant-message block-position (or/c string? #f 'omit))
                       #:in-history-system? in-history?)   ; boolean
  -> (values (listof jobject?) (or/c string? #f))          ; wire messages after merging and validation; the history system prompt
```

`serialize-messages-request` is built on it. `'omit` drops the reasoning block (P9); `#f` sends it without a signature (D6).

## Tests

Tests are `rackunit` files under `racket/dsh-llm/tests/`, run with `raco test racket/dsh-llm`, with no network and no API key. JSON and JSONL fixtures of the TypeScript suites are read in place from `packages/` and `snapshots/`. Each row names the TypeScript suite to mirror and what it pins.

| Racket test file | Mirrors (under `packages/`) | Pins |
|---|---|---|
| `jrecord-test.rkt` | (none) | Key order of constructors, optional omission, patterns, the compile-time error of an incomplete closed `-case` (checked with `convert-compile-time-error`). |
| `messages-test.rkt` | `llm/llm/tests/message.spec.ts` | Constructor key orders against the rows of `snapshots/session/bash-tool-turn/session.v4.jsonl`; empty system prompt; `bound-context-summary` at 120 and 121 UTF-16 units, with an astral character at the cut. |
| `assembler-test.rkt` | `llm/llm/tests/assembler.spec.ts`, `properties.spec.ts` | B1 to B5: stragglers, first close wins, id fallback, `max-tokens` pruning with replay alignment, interrupted prefix. Property tests with random chunk interleavings. |
| `assistant-stream-test.rkt` | `llm/llm/tests/assistant-stream.spec.ts` | C1 to C3: run packing, exact expansion, every validation error, readers, `assemble-assistant-stream` equals assembling the expansion. Round trip over every `stream` in `snapshots/session/*/session.v4.jsonl`. |
| `content-test.rkt` | `llm/llm/tests/content.spec.ts` | T2 texts byte for byte; projections return `eq?` input when unchanged; tool updates in the three modes including rebase; offload counts at exact and quantised budgets. |
| `errors-test.rkt` | `llm/llm/tests/adapter-failure.spec.ts`, `retry-policy.spec.ts`, `api-key.spec.ts`, `attribution.spec.ts` | Failure bounds, normalisation, each classifier alternative, `error-chain`, policy defaults and bounds, unknown keys, key check, `user-agent` with and without suffix. |
| `stream-test.rkt` | (none) | Streams rules 1 to 6, including close of a suspended producer shutting its custodian (a thread created by the producer is dead afterwards) and a break during a pull. |
| `llm-service-test.rkt` | `llm/llm/tests/service.spec.ts`, `topology.spec.ts`, `call-config.spec.ts` | A1 to A12: all-or-nothing registration, atomic replace, `REGISTRATION_DISPOSED`, listener containment and one event per commit, `prepare-call` one shot and config equality, default materialisation, effort validation, failure chunks versus raised listener errors, replay-state filtering by adapter identity, waterfall short-circuit for an unregistered provider, removal on fiber disposal (`check-kernel-restored`). |
| `extensions-test.rkt` | `llm/deepseek-llm-api-extensions/tests/registry.spec.ts` | X1 to X4. |
| `retry-test.rkt` | `llm/llm-retry/tests/retry.spec.ts`, `persistence.spec.ts`, `initialization.spec.ts` | E1 to E8 with injected `random` and `delay-evt`: backoff numbers, `Retry-After` within and above the cap, budget per step and provider, always mode, cancellation during the wait, drain on disposal, the two events and their order, the default `policyKey` string. |
| `mock-test.rkt` | (none) | M1 to M5; a scripted turn through `llm-stream` yields the scripted chunks and one finish; exhaustion yields an error finish with `MOCK_SCRIPT_EXHAUSTED`. |
| `http-test.rkt`, `sse-test.rkt` | `llm/llm-deepseek/tests/stream.spec.ts` (framing part), `egress.spec.ts` | H1 to H8 against local `tcp-listen` servers: chunked and length bodies, truncation, redirect refusal, proxy `CONNECT` and absolute-URI routing through a fake proxy, loopback bypass, SSE framing at every byte split, comments as activity, unterminated tail dropped. |
| `deepseek-serialize-test.rkt` | `llm/llm-deepseek/tests/serialize.spec.ts`, `tests/expected/degraded-replay.json` | D5, D6, D12: body key order as exact JSON text, every serialiser rule and error. |
| `deepseek-translate-test.rkt` | `llm/llm-deepseek/tests/stream.spec.ts` | D7 to D10: the event state machine, usage, every malformed input, in-band errors, `Retry-After`. |
| `deepseek-adapter-test.rkt` | `llm/llm-deepseek/tests/adapter.spec.ts`, `runtime.spec.ts`, `credential.spec.ts`, `dynamic-config.spec.ts`; `llm/llm-retry/tests/transport-recovery.spec.ts`; `llm-deepseek-api-key/tests/*`, `llm-deepseek-account/tests/*` | The whole route against `start-mock-llm-server`: headers and betas, each behaviour's outcome (table below), idle timeout, cancellation, credential precedence, account quota and token rejection, retry-policy re-registration. |
| `deepseek-listing-test.rkt`, `deepseek-files-test.rkt`, `deepseek-image-tokens-test.rkt` | `listing.spec.ts`, `listing-cache.spec.ts`, `listed-catalog.spec.ts`, `files-api.spec.ts`, `file-store.spec.ts`, `files.spec.ts`, `upload-index.spec.ts`, `image-tokens.spec.ts`, `request-pricing.spec.ts` | D13, D14 with the golden values of the TypeScript suites. |
| `mock-server-test.rkt` | `test-support/llm-mock-server/tests/server.spec.ts`, `cli.spec.ts` | Every behaviour's wire output, script exhaustion, seeded randomness (same seed, same sequence as the TypeScript generator), CLI validation. |
| `token-meter-test.rkt` | `llm/token-meter/tests/*.spec.ts` | F1 numbers including non-BMP text, anchor selection, route pricing, the four projections including shadow-price claims, `derive-turn-token-usage` fail-closed cases. |
| `replay-test.rkt` | `test-support/llm-replay/tests/llm-replay.spec.ts` | I1 to I9; derivation over `snapshots/session/bash-tool-turn/session.v4.jsonl` gives two entries equal to the expanded streams; every `snapshots/**/replay.override.json` validates. |
| `pi-ai-test.rkt` | `llm/llm-pi-ai/tests/config.spec.ts`, `context.spec.ts`, `discovery.spec.ts`, `request-headers.spec.ts`, `prefix-binding.spec.ts` | P1 to P12 against local scripted servers for the two protocols; the dsh example configuration of the package README parses; unserved routes carry the directory `error`. |
| `plugins-test.rkt` | `llm/llm-deepseek/tests/loader-composition.spec.ts`, `llm/llm-retry/tests/loader-composition.spec.ts`, `llm/plugin-package-inventory-deepseek/tests/inventory.spec.ts` | Every `plugin-table` entry loads and provides a plugin with the listed name, inject list and provided services; mounting and disposing each plugin restores the kernel snapshot. |

Expected outcome of each mock-server behaviour through the DeepSeek adapter and `llm-stream` (verify against `transport-recovery.spec.ts` and `adapter.spec.ts`; the TypeScript expectation wins on any difference): `success`, `slow_success`, `wrong_content_type`, `reasoning_success` finish `stop`; `tool_call_success` finishes `tool-calls`; `max_tokens` finishes `max-tokens`; `connection_reset`, `stream_disconnect`, `partial_disconnect` give `TRANSPORT`; `stream_eof`, `empty_body`, `partial_eof` give `STREAM_CLOSED`; `empty` gives `EMPTY_RESPONSE`; `stall` gives `TIMEOUT`; `malformed_json`, `malformed_event` give `MALFORMED_RESPONSE`; `rate_limit` gives `RATE_LIMIT` with `providerRetryAfterMs`; `server_error`, `service_unavailable` give `SERVER`; `auth_error` gives `AUTH`; `invalid_request` gives `INVALID_REQUEST`; `context_overflow` gives `CONTEXT_WINDOW_EXCEEDED`; `quota_exceeded` gives `QUOTA`; script exhaustion gives `SERVER`.

Services of later packages. `llm-retry` injects `agents` and `sessionProjections`, `token-meter` injects `sessionProjections`, and the inventory plugin injects `agents`, `deepseekLlmApiExtensions` and `loader`; `agents`, `sessionProjections` and `loader` are provided by packages built after this one. The tests of this package provide stand-ins with `ctx-provide`: any value for `agents` (neither plugin of this package reads it: `llm-retry` injects it so that it mounts after the owner of `agent/request-error`, and what dsh's inventory plugin reads from it, the agent of a session id, is inside the provider's `inventory-port` implementation here), the in-memory projection port of Open question 1 for `sessionProjections`, and a struct that implements `inventory-port` for `loader`. `retry-test.rkt` dispatches `agent/request-error` itself with `ctx-waterfall`, a payload `hasheq` with the keys of Behaviour E and an innermost step that returns `#f`.

Rules for all tests: no wall-clock assertions (waits are sequenced with evts and injected delay procedures; the one real timer, the idle timeout, uses a small configured value under a generous outer timeout); every listener, temporary directory and thread is released; a registration test disposes the fiber and observes the removal.

Acceptance gate for the package: `raco test racket/dsh-llm` passes; and the wave 3 gate holds for this package's part: a `racket:llm-mock` script with one tool call, driven through `llm-prepare-call` and `prepared-call-stream`, accumulated with `accumulator-push` and assembled, produces an `assistant/message` payload (`message`, `usage`, `stream`) whose JSON text equals the corresponding recorded row once ids and times are substituted. An optional live smoke test (skipped without `DEEPSEEK_API_KEY`) sends one text request through the api-key plugin.

## Open questions

Each has a default so no implementer is blocked.

1. **Projection registry.** Settled by [dsh-agent.md](dsh-agent.md): its plugin `racket:session-projections` provides `sessionProjections` in wave 3 with a value that implements `gen:projection-port`, and it uses `projection-definition` of `dsh-llm/ports` unchanged. `dsh-agent` is built after this package, so the tests of this package cannot mount that plugin; they use a 40-line in-memory port (fold on read) kept under `tests/`, with the behaviour of dsh-agent rules 68 and 69.

2. **`agent/request-error` payload.** Settled by [dsh-agent.md](dsh-agent.md): every `agent/*` payload is an immutable `hasheq` with symbol keys that `jref` reads, and it carries `'session` and `'cancel` beside the dsh keys. The `llm-retry` plugin therefore stays in this package.

3. **Loader entry id.** The settings namespace needs the `id` of the plugin's loader entry (`ctx.fiber.entry?.options.id`). Default: `(context-meta ctx 'loader/entry-id #f)`, falling back to the short name.

4. **Schema features.** This contract assumes `cordis-schema` offers, beyond the constructors named in the brief, modifiers for numeric bounds (`min`, `max`, `step`), `role`, and volatile references with a reader. Default when volatile references are missing: the plugin reads `(fiber-effective-config (context-fiber ctx))` through `config-get` on each operation, which is behaviourally the same for a settings change that updates the fiber's config without a restart.

5. **`settings.configure({auto: false}, fiber)`.** Settled in the wave 3 review: `gen:settings-port` in `dsh-llm/ports` (Services, "Ports"), shared with `dsh-agent`. The provider of the `settings` service (`dsh-platform`, wave 4) implements it; until then the injected child stays pending.

6. **`dsh-util` names.** Assumed: `exn:fail:harness` with accessor `exn:fail:harness-code` and a way to construct substructs; a UUID generator; `(launch-environment-ref ctx name)` returning a string or `#f`; the Harness home path; the proxy policy `(proxy-for-url url)` returning a proxy URL or `#f`; atomic file replacement. Default: use whatever the `dsh-util` contract names; where one is missing, implement it privately here and report it.

7. **HTTP client ownership.** The architecture table lists HTTP and SSE helpers under `dsh-util`; this contract owns them in `dsh-llm/http` and `dsh-llm/sse` as its task requires. Default: keep them here in wave 3; the coordinator may hoist them unchanged, in which case these modules re-export.

8. **Anonymous user id.** Its file protocol belongs to `packages/identity` (`dsh-platform`, wave 4) but the DeepSeek adapter needs it in wave 3. Default: a private 30-line copy here; hoisting it into `dsh-util` would remove the duplication.

9. **Native pi-ai set.** The protocol of each catalog provider cannot be read from the repository because the Node library is not installed. The native table of P2 lists only providers whose public endpoint is known to speak the protocol named; `fireworks`, `mistral`, `openai`, `google` and the rest stay unserved. Default: ship the table as written; a user can serve any OpenAI-compatible endpoint today by declaring `api`, `baseURL` and `models`. The thinking-budget defaults of P9 and the wording of P7 to P10 are this port's design and should be reviewed against the library when the sidecar lands.

10. **Unserved routes.** Default: report them through the directory entry's `error` and log one `warning` per route at load, as deferred validation does in dsh. The alternative, failing the plugin at load, would make a settings document written for dsh stop every other provider.

11. **Inventory port.** Someone must implement `inventory-port` on the `loader` service value (names of active entries, versions from the resolver). Default: `dsh-boot`, which owns the resolver; until then the inventory plugin logs one warning and contributes `{version: 1, packages: []}`.

12. **Remote error.** `llm-remote-discover-models` raises a plain `exn:fail:harness` with code `llm/model-discovery-rejected`; `dsh-web` decides how that maps to its remote error type.

13. **Version string.** `user-agent` reports `0.2.2-rc.2`, the dsh version of the pinned commit, so the provider sees the same product token. The coordinator may prefer a distinct suffix for the Racket harness; the `DSH_USER_AGENT_SUFFIX` mechanism already allows it without a code change.
