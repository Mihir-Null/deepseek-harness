# Interface contract: `dsh-session`

This is the binding interface for `racket/dsh-session/`. It covers the append-only session event log, the surface fold, derived model history, the request-header and tool-history folds, fork seeds and tail repair, the in-memory store service `sessions`, and the scope routing core that the store needs. Sources: [recon 04](../recon/04-core-data.md) and `packages/core/session/src` at commit `e8f7b93a3`. When this document and the TypeScript disagree about behaviour, the TypeScript is right and this document gets fixed. When they disagree about names and argument order of the Racket surface, this document is right.

Package: directory `racket/dsh-session/`, collection `dsh-session`, `(define deps '("base" "cordis" "cordis-data" "dsh-util"))`, `(define build-deps '("rackunit-lib"))`. The package must not depend on `dsh-llm` or `dsh-tools`; both depend on it.

## Scope

| dsh package | npm name | Status |
|---|---|---|
| `packages/core/session` | `@deepseek-ai/dsh-session` | native |
| `packages/core/scope` (part) | `@deepseek-ai/dsh-scope` | native, split. `core/session` imports `scopeOf` and `scopeTarget`, and this package sits below `dsh-tools`, which owns the rest of the scope library. The scope tag, the parent relation and scope-filtered dispatch are therefore implemented here in `dsh-session/scope-core` and re-exported by `dsh-tools/scope`. |
| `packages/util/values` (part) | `@deepseek-ai/dsh-util-values` | native. The lossless JSON check is provided here as `dsh-session/lossless` so that this contract does not depend on a name in `dsh-util`. If `dsh-util` exports the same two procedures, this module becomes a re-export. |

Parts of `core/session` that are not reproduced, and why:

- The typert lookup registration in the `SessionStore` constructor (`index.ts:1173-1182`) is adapted: the package that owns `typert` (wave 5) registers the `session` lookup itself with `sessions-find`. The lookup fields are `parameter: 'session'`, `wire: 'sessionId'`, `resource: 'session'`.
- `deepFreeze`, `structuredClone`, single-read-per-property snapshots and cross-realm prototype checks are not applicable: jvalues are immutable. The lossless JSON domain check stays.
- Branded numeric types are contracts.

The message vocabulary (roles, content blocks, sources, tool schemas, call config, stream records, token usage) is owned by `dsh-llm`. This package treats those values as jvalues and reads only the fields listed under Data.

## Modules

| Module | Provides |
|---|---|
| `dsh-session` (`main.rkt`) | everything exported by the modules below except `dsh-session/scope-core` and `dsh-session/plugin` |
| `dsh-session/lossless` | `lossless-json?`, `snapshot-json` |
| `dsh-session/scope-core` | scope keys, the scope tag, the parent relation, scope filters, scoped dispatch, contained observer invocation |
| `dsh-session/types` | `absent`, scalar contracts, `session-header`, `session-event`, `surface-replace`, `session-event-input`, `session-event-type`, `define-session-event`, `plugin-record`, `plugin-record-input`, message field predicates, `exn:fail:session`, `session-format-version` |
| `dsh-session/events` | the 14 core event declarations, `core-session-event-types`, `known-session-event-types`, `message-projection-event-types`, `surface-event-types` |
| `dsh-session/surface` | `surface-state` and its transitions, `fold-surface`, `derive-event-message`, `derive-messages`, `validate-session-event-data`, `validate-surface-metadata`, `check-event-shape`, `check-declared-fields`, `check-session-event`, the predicates `surface-eligible-type?`, `surface-event?`, `append-surface-event?`, `replacement-surface-event?`, `message-projection`, `projection-context` |
| `dsh-session/request-header` | `canonical-header`, `header-equal?`, `fold-request-header` |
| `dsh-session/tool-history` | `tool-history-state-empty`, `tool-history-apply`, `tool-history-snapshot` |
| `dsh-session/repair` | `open-turn-closers`, `interrupted-turn-closers`, `tool-call-recovery`, the two recovery codes |
| `dsh-session/fork` | `build-fork-seed` |
| `dsh-session/seq-ranges` | `encode-seq-ranges`, `decode-seq-ranges` |
| `dsh-session/session` | the `session` object and its operations, `append-plugin-record!`, `plugin-record-of`, `session-preparation`, `current-session-time` |
| `dsh-session/store` | the `sessions` service definition, its procedures, the four `session/*` events, `exn:fail:session:fork` |
| `dsh-session/plugin` | `plugin`, the `@deepseek-ai/dsh-session` plugin |
| `dsh-session/plugins` | `plugin-table` |

Private modules live under `private/`. `dsh-tools` requires `dsh-session/scope-core` and `dsh-session/lossless` by name; every other package gets the scope API through `dsh-tools/scope`.

## Data

### Scalars and the absent marker

```racket
max-safe-integer                 ; 9007199254740991
(safe-integer? v)                ; exact integer, or integral flonum other than -0.0, with |v| <= max-safe-integer
(session-seq? v)                 ; safe-integer?, >= 0, exact
(session-log-offset? v)          ; same set as session-seq?; names a gap or prefix length
(session-id? v)                  ; string?
(->session-seq v) -> session-seq?           ; raises exn:fail:contract "SessionSeq must be a non-negative safe integer, got <v>"
(->session-log-offset v) -> session-log-offset?   ; "SessionLogOffset must be a non-negative safe integer, got <v>"
session-format-version           ; 4
absent                           ; a unique value that stands for "key not present"
(absent? v) -> boolean?
```

`->session-seq` and `->session-log-offset` accept an integral flonum and return the exact integer. `absent` is the default of every optional keyword in the constructors below. Passing any other value, including `#f` and `'null`, writes the key. Accessors of optional fields return `#f` when the key is absent; for the one field whose values include `#f` (`meta` on `tool/result`) use `(jhas? (session-event-data e) 'meta)` to tell the cases apart.

### `session-header`

```racket
(session-header? v)
(make-session-header #:id id #:created-at ms #:seeded? [seeded? #f] #:cwd [cwd absent] #:parent-session [p absent]
                     #:origin [origin absent] #:delegation-depth [d absent] #:agent-preset [a absent]) -> session-header?
(jvalue->session-header id jv) -> session-header?      ; validates per Behaviour rule 3
(session-header->jvalue h) -> jobject?                 ; the header as written, unknown keys retained
(session-header-version h) (session-header-id h) (session-header-created-at h) (session-header-cwd h)
(session-header-parent-session h) (session-header-seeded? h) (session-header-origin h)
(session-header-delegation-depth h) (session-header-agent-preset h)
```

JSON form, keys in this order, optional keys omitted when absent: `version` (always `4`), `id`, `createdAt`, `cwd?`, `parentSession?`, `isSeeded`, `origin?` (only `"subagent"`), `delegationDepth?`, `agentPreset?`. Source: `types.ts:95-136`, `index.ts:1272-1282`. A header read from JSON keeps its original jobject, so unknown keys and the original key order survive `session-header->jvalue`. The header is not an event.

### `session-event`

```racket
(session-event? v)
(session-event-type e) -> string?
(session-event-seq e) -> session-seq?
(session-event-time e) -> exact-integer?               ; Unix epoch milliseconds, a safe integer
(session-event-data e) -> jvalue?
(session-event-surface-op e) -> (or/c #f 'append surface-replace?)
(session-event-source-seqs e) -> (or/c #f (listof session-seq?))
(session-event-ignorable? e) -> boolean?
(session-event->jvalue e) -> jobject?
(jvalue->session-event jv #:subject [subject "session event"]) -> session-event?
(make-session-event type seq time data #:sources [sources absent] #:surface-op [op absent] #:ignorable? [ig #f]
                    #:metadata-order [order 'sources-first]) -> session-event?
(struct surface-replace (start-seq end-seq) #:transparent)
```

A `session-event` is an immutable parsed view of one log entry that keeps its JSON form. `session-event->jvalue` returns the envelope with the keys in the order the event was created or read with, so writing an event back produces the bytes dsh would write. `equal?` on two events compares their JSON forms as jobjects.

JSON form. Exactly these keys are allowed: `type` (string), `seq` (non-negative safe integer, not `-0`), `time` (safe integer), `data` (any jvalue, must be present), `surfaceOp` (`"append"` or `{"op":"replace","startSeq":n,"endSeq":m}` with exactly those three keys), `sourceEventSeqs` (array of numbers), `ignorable` (only `true`). Key order written by this package:

- a live append writes `type, seq, time, data`, then `sourceEventSeqs` when given, then `surfaceOp` when given (`index.ts:531-542`);
- a plugin record writes `type, seq, time, data, ignorable` (`index.ts:936-942`);
- a synthetic recovery result writes `type, seq, time, data, surfaceOp`, then `sourceEventSeqs` when present (`repair.ts:176-192`); `make-session-event` selects this with `#:metadata-order 'op-first`;
- the fork marker and synthetic `step/end` and `turn/end` write `type, seq, time, data`.

`jvalue->session-event` checks only the envelope: an object, no key outside the seven, `type` a string, `seq` and `time` as above, `data` present, `ignorable` absent or `#t`. On failure it raises `exn:fail:session` with message `<subject> has an invalid event envelope`. It does not interpret `surfaceOp` or `sourceEventSeqs`. `session-event-surface-op` returns `'append` or a `surface-replace` only when the event type is surface-eligible and the stored value has the valid form, and `#f` otherwise; `session-event-source-seqs` returns the list only when it is a list of valid seqs. `validate-surface-metadata` is the procedure that reports malformed metadata.

### Event inputs and declarations

```racket
(session-event-input? v)
(make-session-event-input type data #:surface-op [op absent] #:sources [sources absent]) -> session-event-input?
(session-event-input-type i) (session-event-input-data i) (session-event-input-surface-op i) (session-event-input-sources i)

(session-event-type? v)                                   ; a declaration made by define-session-event
(session-event-type-tag t) -> string?
(session-event-type-ignorable? t) -> boolean?
(session-event-type-surface? t) -> boolean?
(session-event-type-fields t) -> (listof (list/c symbol? string? boolean?))   ; Racket name, JSON key, optional?
(session-event-type-violation t data) -> (or/c #f string?)                    ; first violation, see rule 6
```

```racket
(define-session-event id
  #:type type-string                                      ; the dsh type tag, a literal string
  (~optional #:ignorable)                                 ; declares a plugin record type
  (~or (~seq #:fields ([field-id (~optional json-key-string) contract-expr (~optional #:optional)] ...))
       (~seq #:data contract-expr)))
```

Two things carry the words "event type" and they are different. `(session-event-type e)` is the accessor of a `session-event` and returns the type tag, a string. A *declaration* is the opaque value that `define-session-event` creates; `session-event-type?` recognises it and `session-event-type-tag`, `session-event-type-ignorable?`, `session-event-type-surface?`, `session-event-type-fields` and `session-event-type-violation` read it. The declaration struct has no exported constructor, so the identifier `session-event-type` is bound only as the accessor.

`define-session-event` is the one place a session event type is declared. For `(define-session-event tool/call #:type "tool/call" #:fields (...))` it defines:

- `tool/call-type`, the `session-event-type` value;
- `tool/call` as a constructor: `(tool/call #:turn t #:step s #:call-id c #:name n #:arguments a)` returns a `session-event-input` whose data is a jobject with the fields in declared order under their JSON keys. Each value is checked against its field contract. An optional field's keyword defaults to `absent`. With `#:data`, the constructor takes the data value as one positional argument. For the five surface-eligible type tags the constructor also takes `#:surface-op` (required, `'append` or a `surface-replace`) and `#:sources` (optional list of `session-seq?`; not offered for `assistant/message`). For a declaration with `#:ignorable` the constructor returns a `plugin-record-input` (see "Plugin records"), which `append-plugin-record!` accepts and `session-append!` rejects with `exn:fail:contract`;
- `tool/call?`, true for a `session-event` or `session-event-input` with that type tag;
- one accessor per field, `tool/call-call-id` and so on, taking an event or an input and returning the field value or `#f` when absent;
- `tool/call` as a `match` pattern: `(tool/call #:call-id pat #:name pat)` matches a `session-event` of that type whose data is an object; each listed field is matched against its value, or against `#f` when the key is absent. Fields not listed are ignored. Combine with `(and e ...)` to reach the envelope.

The JSON key of a field defaults to the field identifier spelled as written. Syntax errors: a duplicate field or JSON key; `#:ignorable` with a type tag that does not match the plugin record grammar; a tag without `#:ignorable` that does match it; `#:optional` on a `#:data` declaration. The macro uses `syntax/parse` and names the clause at fault.

The JSON codec of a declared type is the pair formed by its constructor (fields to data jobject in declared order) and `session-event-type-violation` (data jobject checked against the field contracts); the envelope codec is `session-event->jvalue` and `jvalue->session-event`. Unknown keys in data are kept and ignored.

### Message fields this package reads

Messages are jobjects produced by `dsh-llm/messages`. This package never constructs one except in `dsh-session/repair`. It reads these fields and no others (`index.ts:336-386`, `surface.ts:120-220`, `repair.ts:112-150`, `tool-history.ts`):

| Value | Fields read |
|---|---|
| any message | `id` (non-empty string), `role` (`"system"`, `"developer"`, `"user"`, `"assistant"`, `"tool"`), `source` (object with non-empty string `kind`), `content` (array) |
| system message | `source.kind = "system-prompt"` |
| assistant message | `source.kind = "model"`, `source.provider` and `source.model` non-empty strings |
| tool result message | `source.kind = "tool"`, `source.callId` non-empty string, `toolCallId` equal to `source.callId`, `isError` |
| content block | `type`; on `tool-call`: `id`; on `tool-addition` and `tool-removal`: `toolName`; on `tool-addition` the key `tool` must not exist |
| tool schema (in `request/header`) | `name`, `description` (string), `parameters` (object), `deferLoading` (only `true`) |
| call config (in `request/header`) | `provider`, `model`, `reasoningEffort`, `temperature`, `maxTokens`, `stop` |

Predicates over these shapes, used as field contracts: `message-jvalue?`, `system-message-jvalue?`, `developer-message-jvalue?`, `user-message-jvalue?`, `assistant-message-jvalue?`, `tool-result-message-jvalue?`. Each holds exactly when the checks of rule 5 for the matching event type pass.

### Core event types

Declared in `dsh-session/events` with `define-session-event`. Fields are listed in the order dsh writes them. "S" marks the five surface-eligible types. None is ignorable.

| Racket id | dsh type | S | Data fields in write order (JSON key: contract) |
|---|---|---|---|
| `turn/start` | `turn/start` | | `turn`: `session-seq?` |
| `turn/end` | `turn/end` | | `turn`: `session-seq?`; `reason`: `turn-end-reason?` |
| `step/start` | `step/start` | | `turn`; `step`: `session-seq?` |
| `step/end` | `step/end` | | `turn`; `step` |
| `user/message` | `user/message` | S | `#:data user-message-jvalue?` (the message itself, no wrapper) |
| `developer/message` | `developer/message` | S | `turn`; `step`; `message`: `developer-message-jvalue?`; `headerSeq?`: `session-seq?` |
| `system/message` | `system/message` | S | `turn`; `step`; `message`: `system-message-jvalue?` |
| `assistant/message` | `assistant/message` | S | `turn`; `step`; `message`: `assistant-message-jvalue?`; `interrupted?`: `#t`; `usage?`: `jobject?`; `stream`: `(listof jvalue?)` |
| `assistant/attempt` | `assistant/attempt` | | `turn`; `step`; `stream`: `(listof jvalue?)` |
| `tool/call` | `tool/call` | | `turn`; `step`; `callId`: `string?`; `name`: `string?`; `arguments`: `string?` (the raw model text, unparsed) |
| `tool/result` | `tool/result` | S | `turn`; `step`; `message`: `tool-result-message-jvalue?`; `error?`: `tool-error-identity?`; `meta?`: `jvalue?` |
| `request/header` | `request/header` | | `header`: `epoch-header?`; `reason`: one of `"initial"`, `"resume"`, `"change"`, `"series"`; `startsSeries?`: `#t` |
| `request/context` | `request/context` | | `provider`: `string?`; `model`: `string?`; `contextWindow?`: `real?`; `systemPromptUpdate?`: `"in-history"` |
| `session/end-seed` | `session/end-seed` | | `inherited?`: `#t` |

The `assistant/message` order is the order both producers write (`packages/core/agent-loop/src/agent.ts:511-525` and `:582-588`): `interrupted`, then `usage`, then `stream`. It differs from the order of the TypeScript type declaration, which recon 04 lists.

Racket field identifiers are the kebab-case form of the JSON key (`call-id` for `callId`, `header-seq` for `headerSeq`, `starts-series` for `startsSeries`, `context-window`, `system-prompt-update`).

Embedded shapes, all jobjects:

- `turn-end-reason?`: an object with a string `kind`. Core kinds and their fields: `completed`; `aborted` with `reason` (a cancel cause: `{kind:"user"}`, `{kind:"parent"}`, `{kind:"hook",reason}`, `{kind:"disposed"}`, `{kind:"legacy"}`); `blocked`; `error` with `error` (an `LlmFailure`: `message`, `code`, `status?`, `providerRetryAfterMs?`, `requestId?`, `offloadImages?`); `max-tokens`; `interrupted`; `forked`. The set is extensible, so an unknown `kind` is accepted.
- `epoch-header?`: `{config, adapterDefaults?, tools?}` in that order, where `config` passes the checks of rule 5 for `request/header`.
- `tool-error-identity?`: `{name, code, reason?}`, all strings.
- request context: the data of `request/context`.

`core-session-event-types` is the list of the 14 declarations. `surface-event-types` is the set `system/message`, `developer/message`, `user/message`, `assistant/message`, `tool/result`; it is closed. `known-session-event-types` is the set of 63 names in `packages/core/session/src/known-event-types.ts`, copied verbatim as strings; it is a constant of the build and never depends on which plugins are loaded. `message-projection-event-types` is the set containing `image/offload`.

### Plugin records

```racket
(plugin-record-type? s)           ; matches #px"^plugin:[a-z0-9][a-z0-9._-]*(?:/[a-z0-9][a-z0-9._-]*)*$"
(struct plugin-record (type seq time data) #:transparent)
(plugin-record-input? v)          ; opaque; made only by the constructor of a declaration with #:ignorable
(plugin-record-input-type i) -> string?
(plugin-record-input-data i) -> jvalue?
```

`plugin-record` is the read side (`plugin-record-of`). `plugin-record-input` is the write side for declared record types; it is defined in `dsh-session/types` beside `session-event-input`, and `session-event-input?` is false for it.

### Surface data

```racket
(surface-state? v)                                        ; immutable
(surface-state-nodes st) -> (listof session-seq?)         ; model-visible order
(surface-state-node-count st) -> exact-nonnegative-integer?
(surface-state-replace-generation st) -> exact-nonnegative-integer?
(surface-state-content-generation st) -> exact-nonnegative-integer?
(surface-state-projected-messages st) -> (hash/c session-seq? jobject? #:immutable #t)
(surface-state-next-seq st) -> session-log-offset?
(struct surface-replacement (seq start end shadowed-seqs) #:transparent)
(struct surface-fold-result (nodes replacements projected-messages) #:transparent)
(struct message-projection (type project))
(struct projection-context (nodes event-ref base-seq messages))
```

`message-projection-type` is a type tag string. `message-projection-project` is `(-> session-event? projection-context? (hash/c session-seq? jobject?))`: a pure function that returns the changed current messages keyed by their original event seq, or raises. `projection-context-event-ref` is `(-> exact-nonnegative-integer? (or/c session-event? #f))` and reads committed events and, during a batch, earlier members of the batch. Appending to a surface state is amortised O(1); a replacement may be O(nodes).

### Tool history

A tool history is the jobject `{tools: [tool schema…], updates: [{messageId, additions: [tool schema…]}…]}`, the form `dsh-llm` takes in a request. The fold state behind it is an opaque immutable `tool-history-state`.

### The session object, preparation, errors

```racket
(session? v)                                   ; opaque, mutable only through the operations in Services
(session-preparation? v)
(struct exn:fail:session exn:fail ())
(struct exn:fail:session:fork exn:fail:session (code))   ; code : "SESSION_NOT_FOUND" "SESSION_NOT_LIVE" "SESSION_ALREADY_EXISTS" "INVALID_BOUNDARY"
```

Where dsh throws `Error`, this package raises `exn:fail:session` with the same message. Where dsh throws `TypeError`, it raises `exn:fail:contract` with the same message. `exn:fail:session:fork` is the dsh `SessionForkError`; it is not an `exn:fail:harness`, because dsh's class does not extend `HarnessError` and a tool result must not gain an error identity from it.

## Services

### Procedures on a session (not a service)

A session is a plain object. These procedures take the session first.

```racket
(make-session id #:seed [seed #f] #:header [header #f] #:inherited-event-count [n #f]
              #:projections [projections '()] #:event-types [types '()]) -> session?
(restore-session id seed header inherited-event-count #:event-state [state 'detached]
                 #:projections [projections '()] #:event-types [types '()]) -> session?
(session-id s) (session-header s)
(session-inherited-event-count s) (session-first-live-seq s) (session-first-lifecycle-seq s) -> session-log-offset?
(session-seq s) -> session-log-offset?                     ; next seq, always the log length
(session-append! s input) -> session-event?                ; input : session-event-input?
(session-append-all! s inputs) -> (listof session-event?)  ; inputs : (listof session-event-input?)
(append-plugin-record! s type data) -> session-seq?        ; type : string? or a declaration made with #:ignorable (its tag is used)
(append-plugin-record! s input) -> session-seq?            ; input : plugin-record-input?; the same append with the input's type and data
(plugin-record-of e) -> (or/c plugin-record? #f)
(session-surface s) -> surface-state?
(session-derive-messages s) -> (listof jobject?)
(session-derive-event-message s e) -> (or/c jobject? #f)
(session-request-header s) -> (or/c jobject? #f)
(session-request-context s) -> (or/c jobject? #f)
(session-tool-history s) -> jobject?
(session-event-at s seq) -> (or/c session-event? #f)
(session-events s [from 0] [to (session-seq s)]) -> (listof session-event?)
(in-session-events s [from 0] [to (session-seq s)])        ; sequence, no allocation of the list
(session-own-events s) -> (listof session-event?)
(session-own-seq? s seq) -> boolean?
(session-current-batch-publication s) -> (or/c session-event? #f)
(current-session-time) -> (-> exact-integer?)              ; parameter; default reads the system clock in milliseconds

(make-session-preparation s #:release [release #f]) -> session-preparation?
(session-preparation-session p) -> session?
(session-preparation-release! p) -> void?                  ; calls release at most once
```

`seed` is a list whose members are `session-event?` values or jobjects in the JSON form. `header` is a `session-header?` or a jobject. `projections` is a list of `message-projection?` or a thunk returning the current list; a store passes a thunk over its live registry. `event-types` is a list of `session-event-type?` or a thunk; the 14 core declarations are always included. `state` is `'detached` or `'shared-frozen`; the two behave identically here. None of these procedures registers an effect. `session-append!` and `session-append-all!` do not wait; they are safe to call from a task and must not be called from outside one for a store-entered session.

### `sessions` — the store service

Service key `'sessions`. Declared with `(define-service sessions 'sessions #:contract session-store?)`, which defines `sessions-key`, `sessions-ref`, `sessions-get` (the optional read of the service value) and `provide-sessions`. The dsh method `get(id)` is therefore named `sessions-find` here. The value is an opaque `session-store` holding: an insertion-ordered table from id to entry, the id counter, the live list of message projections, and the live list of registered event types. `x` below is a context or a `sessions` handle; "the caller's context" is `(use-context x)`.

```racket
(sessions-create x [id #f] #:seed [seed #f] #:inherited-event-count [n #f] #:meta [meta #f]) -> session?
(sessions-prepare x [id #f] #:seed [seed #f] #:inherited-event-count [n #f] #:meta [meta #f]
                  #:event-state [state #f]) -> session?
(sessions-enter x s) -> (-> void?)
(sessions-announce x s) -> void?
(sessions-flush x s) -> boolean?
(sessions-find x id) -> (or/c session? #f)
(sessions-list x) -> (listof session?)
(sessions-fork x source [boundary #f] [child-id #f]) -> session?
(sessions-register-message-projection! x projection) -> disposer?
(sessions-message-projections x) -> (-> (listof message-projection?))
(sessions-register-event-type! x type) -> disposer?
(sessions-event-type x tag) -> (or/c session-event-type? #f)
(sessions-event-types x) -> (listof session-event-type?)
```

| Procedure | Semantics and errors | Effects on the caller's context |
|---|---|---|
| `sessions-create` | `sessions-prepare`, then enter and announce. If the announcement raises, the session is detached (which emits `session/disposed`) before the exception leaves `sessions-create`, and no effect remains. Disposing the caller's fiber detaches the session. | one effect labelled `sessions.create()` whose inverse is the detach |
| `sessions-prepare` | Rule 12. `meta` is a hash or jobject with optional keys `cwd`, `parentSession`, `createdAt`, `isSeeded`, `origin`, `delegationDepth`, `agentPreset`; with `#:event-state` it is the complete header (a `session-header?` or jobject) and `seed` and `inherited-event-count` are required. The result is store-owned and unentered: appends raise. | none |
| `sessions-enter` | Rule 13. Returns the single-shot detach procedure. Emits nothing. | none; the caller owns the returned procedure |
| `sessions-announce` | Rule 14. | none |
| `sessions-flush` | Rule 16. Waits. | none |
| `sessions-find`, `sessions-list` | Live sessions only; `sessions-list` is a fresh list in creation order. | none |
| `sessions-fork` | Rule 26. `source` is a session or an id. Raises `exn:fail:session:fork`. | as `sessions-create` |
| `sessions-register-message-projection!` | One definition per type tag; a duplicate raises `session message projection "<type>" is already registered` before any effect is made. | one effect labelled `sessions.registerMessageProjection()`; the inverse removes that exact definition |
| `sessions-message-projections` | A thunk over the live list, for sessions built outside the store. | none |
| `sessions-register-event-type!` | Adds a declaration to the store's catalogue. A tag that is already registered, or that is a core type, raises `session event type "<tag>" is already registered`. | one effect labelled `sessions.registerEventType()`; the inverse removes that exact declaration |
| `sessions-event-type`, `sessions-event-types` | Catalogue reads; core declarations first, then registered ones in registration order. | none |

Waiting and cancellation. `sessions-flush` is the only procedure of this package that waits. It takes no cancel event, as dsh `flush` takes no signal. A break delivered to the calling task while it waits cancels the listener tasks it started (`task-cancel!`) and propagates, which is what the kernel's own `parallel` dispatch does. Every other procedure returns without waiting: `sessions-create`, `sessions-fork`, `sessions-announce`, the detach procedure and the append procedures call their listeners synchronously and only observe a task that a listener returns.

## Events

Declared in `dsh-session/store`. The module exports the `on-…` and `…-name` bindings and does not export the generated dispatchers: only the store dispatches these events, through `scoped-callbacks` on the caller's context and with the scope key that `sessions-enter` captured (rule 13), and with no base filter (dsh passes the session, which carries no Cordis filter, as the base), so that listener resolution happens before a commit and each listener is contained.

```racket
(define-event session/created  'session/created  #:mode emit     #:args (session?))
(define-event session/disposed 'session/disposed #:mode emit     #:args (session?))
(define-event session/event    'session/event    #:mode emit     #:args (session? session-event?))
(define-event session/flush    'session/flush    #:mode parallel #:args (session?))
```

| Event | Dispatched by, when | Guarantees |
|---|---|---|
| `session/created` | `sessions-announce`, once per entered session | Listeners run synchronously in registration order while appends are still refused. A listener that raises vetoes creation. A listener that returns a task has that task observed; its failure is logged at `warning` as `session "<id>": session/created listener rejected: <text>`. |
| `session/disposed` | the detach procedure | Exactly once for every session whose announcement began, including a failed one; never for a session detached while still pending. Each listener is contained; failures are logged at `warning`. |
| `session/event` | `session-append!`, `session-append-all!`, `append-plugin-record!` on a store-entered session | The listener list is resolved before the event enters the log; a failure there rejects the append and leaves the log unchanged. Listeners run after the commit, in order, each contained. `session-seq` and `session-surface` already include the event. For a batch every member is in the log and the surface before the first listener runs, and `session-current-batch-publication` names the member being delivered. Seed events and constructor markers are never published. |
| `session/flush` | `sessions-flush` | Every listener runs; the caller waits for all; the first failure in listener order is re-raised unchanged. Declared `parallel` as in dsh, dispatched by the store itself. A listener may wait; a break of the waiting caller cancels the listener tasks. |

All four are scope-filtered: a listener registered through an untagged context receives every dispatch; a listener registered through a scoped context receives a dispatch only when its tag is the dispatch key or an ancestor of it. Listener obligations: a `session/created`, `session/event` or `session/disposed` listener must not wait. Work that waits is started with `spawn-task` and the task is returned.

## Plugins

| dsh npm name | Module | Inject | Provides | Config |
|---|---|---|---|---|
| `@deepseek-ai/dsh-session` | `dsh-session/plugin` | none | `sessions` | none (`#:config #f`) |

The body creates one `session-store` and calls `(provide-sessions ctx store)`. It registers nothing else. `dsh-session/plugins` provides `plugin-table` as `(list (cons "@deepseek-ai/dsh-session" 'dsh-session/plugin))`.

## Behaviour

Numbering is for tests. "Raise" means `exn:fail:session` unless stated.

**Lossless JSON** (recon 04 "Lossless JSON"; `packages/util/values/src/index.ts:66-168`)

1. `(lossless-json? v)` holds when `v` is a jvalue and no number in it is `-0.0`. `(snapshot-json v)` returns `#f` when `v` is not lossless JSON, and otherwise an equal value in which every plain `hash` is replaced by a `jobject`, every mutable string by an immutable copy, and every exact non-integer rational by its flonum. A value that is already normal is returned unchanged (`eq?`).

**Envelope and header**

2. Envelope rules are those of `jvalue->session-event` under Data (`index.ts:206-234`).
3. Header validation (`index.ts:98-140`), in this order, each with the exact message: not an object: `session header is not a plain JSON record`; a key `seedLength`: `session header has invalid field "seedLength"`; `version` not `4`: `session header version must be 4, got <v>`; `id` different from the session id: `session header id "<id>" does not match session id "<sid>"`; `createdAt` not a non-negative safe integer: `session header createdAt must be a non-negative safe integer`; `cwd` not a string: `session header cwd must be a string`; `cwd` not a complete path on the host platform (`complete-path?`): `session header cwd must be an absolute path, got "<cwd>"`; `parentSession` not a string: `session header parentSession must be a string`; `isSeeded` not a boolean: `session header isSeeded must be a boolean`; `origin` not `"subagent"`: `session header origin must be "subagent"`; `delegationDepth` not a non-negative safe integer: `session header delegationDepth must be a non-negative safe integer`; `agentPreset` not a string: `session header agentPreset must be a string`. A header that is not lossless JSON raises `session header is not losslessly JSON-serializable`. A session built without a header gets `{version: 4, id, createdAt: now, isSeeded: false}`.

**Event-local validation**

4. `(validate-session-event-data type data subject)` implements `validateSessionEventData` (`surface.ts:166-220`). On a surface-eligible type whose message is an object: type `developer/message` and role `developer` must occur together (`<subject> developer/message and developer role must occur together`); `tool-addition` and `tool-removal` blocks need role `developer` (`<subject> tool-change blocks require developer role`); in a developer message each such block needs a non-empty `toolName` (`<subject> <blockType> requires a nonempty toolName`), a `tool-addition` must not have a key `tool` (`<subject> tool-addition must omit inline tool definitions`), and `headerSeq` must be a valid seq exactly when at least one addition exists and must be absent otherwise (`<subject> requires headerSeq exactly when tool additions are present`). On `request/header`: `<subject> data must be an object`, `<subject> header must be an object`, a key `system` on the header (`<subject> must omit header.system; use system/message`), `tools` an empty array (`<subject> must omit empty tools`), `adapterDefaults` an empty object (`<subject> must omit empty adapterDefaults`). On `tool/result`: `<subject> data must be an object`, and `error` present without `message.isError` being `#t` (`<subject> error requires message.isError === true`).
5. Shape checks (`index.ts:250-386`). For the five message types: `<subject> lacks an identified message`, `<subject> message must have role "<role>"`, `<subject> message has invalid source`, `<subject> message has invalid content`, `<subject> message must have system-prompt source`, `<subject> message must have model source`, `<subject> message must have tool source`, `<subject> message has mismatched tool call ids`, checked in that order. For `assistant/message` and `assistant/attempt`: `turn` and `step` non-negative safe integers and `stream` an array, else `seed <type> at index <i> has invalid settlement fields`. For `request/header`: `seed request/header at index <i> lacks provider/model`, `… has an invalid reasoningEffort` (present but not a non-empty string), `… has invalid adapterDefaults` (not an object, a key outside `reasoningEffort` and `maxTokens`, a value other than `true`, or a marker whose config field is absent), `… has an invalid reason`, `… has an invalid startsSeries marker`. On the seed path the subject is `seed <type> at index <i>`.
6. Live appends apply rule 4 with subject `session event "<type>" at seq <n>`, then rule 5 with the same subject in place of `seed <type> at index <i>` (TypeScript skips rule 5 on live appends because its types guarantee the shape), then the declared-field check: when the session's catalogue has a declaration for the type, `session-event-type-violation` must return `#f`; otherwise raise `<subject> <violation>`, where the violation is `data must be an object`, `lacks field "<jsonKey>"` or `field "<jsonKey>" is invalid`, the first in declared order. A type with no declaration is accepted unchecked, as in dsh. The declared-field check never runs on seed events.
7. `(check-session-event e)` implements `adoptSessionEvent` (`index.ts:172-194`): rule 4 with subject `session event at seq <n>`, `validate-surface-metadata`, then the message checks of rule 5 with that subject. It returns `e`. `snapshotSessionEvent` is the same procedure here.
8. `(validate-surface-metadata e)` implements `surfaceOpOf` and `validateSurfaceMetadata` (`surface.ts:302-411`). A type that is not surface-eligible: if it is not in `known-session-event-types` and the event is ignorable, accept any metadata and return `#f`; otherwise a `surfaceOp` raises `session event "<type>" is not surface-eligible and cannot carry surfaceOp` and a `sourceEventSeqs` raises `session event "<type>" is not surface-eligible and cannot carry sourceEventSeqs`. A surface-eligible type: no `surfaceOp` raises `session event "<type>" is surface-eligible and requires a surfaceOp marker`; a value that is neither `"append"` nor an object raises `session event "<type>" carries an invalid surfaceOp`; an object that is not exactly `{op: "replace", startSeq, endSeq}` with valid seqs raises `session event "<type>" carries an invalid replace surfaceOp`; a replace endpoint not earlier than the event raises `surface replace at seq <n>: startSeq and endSeq must reference earlier events`. Then the source rules: on `assistant/message` any `sourceEventSeqs` raises `assistant/message embeds its source stream and cannot carry sourceEventSeqs`; not an array: `sourceEventSeqs on event at seq <n> must be an array when present`; empty: `sourceEventSeqs must not be empty`; an invalid member: `session event "<type>" sourceEventSeqs must densely contain non-negative safe integers`; duplicates: `sourceEventSeqs must not contain duplicates`; a member not earlier than the event: `sourceEventSeqs must reference earlier events: <m> >= current seq <n>`. Returns `'append`, a `surface-replace`, or `#f`.

**Appending** (recon 04 "Append, single event" and "Append, array form"; `index.ts:853-992`)

9. Membership check, run first by every append: a store-owned unentered session raises `session "<id>" cannot append outside a SessionStore`; an entered session whose announcement is not complete raises `session "<id>" cannot append before session/created completes`; an entered session that is publishing another append raises `session append cannot reenter while another append is being published`. A session built outside a store appends freely and publishes nothing.
10. Single append, in order: rule 9; `data` must be lossless JSON, else `session event "<type>" carries non-JSON-serializable data`; build the event with `seq` equal to the log length and `time` from `(current-session-time)`; rule 6; plan the surface transition (rule 18) without changing state; mark the entry as appending; resolve the `session/event` callbacks (a raise here leaves the log unchanged); push the event and drop the cached full event list; invoke the callbacks with containment (rule 15); clear the appending mark; if a detach was requested and the announcement is not in progress, detach. The result is the logged event.
11. Batch append: rule 9; an empty list returns `'()`; each member's data must be lossless JSON, else `session batch member <i> ("<type>") carries non-JSON-serializable data`; assign consecutive seqs from the log length; rule 6 for each; plan all members against the current surface state, each later member seeing the earlier ones in the state and through `event-ref`; mark appending; resolve the callbacks of every member in order; push all events; adopt the planned surface state; then for each member in order set the current batch publication and invoke its callbacks with containment; finally clear the batch publication and the appending mark and run a requested detach. Any failure before the push leaves the log and surface unchanged.
12. `sessions-prepare` (`index.ts:1238-1286`): with no id, mint `session-<n>` from a counter that is incremented first and skips ids present in the store; a live duplicate raises `session "<id>" already exists`. With `#:event-state`, call `restore-session` with the store's live projections and catalogue. Otherwise build the header with `createdAt` from `meta.createdAt` or the clock and `isSeeded` from `meta.isSeeded` or `#f`, and call `make-session`. Mark the session store-owned and unentered.
13. `sessions-enter` (`index.ts:1311-1344`): raise `session "<id>" already exists` when the id is live and `session "<id>" is already attached to a store` when the session has an entry. Capture `(scope-of ctx)` and `ctx` of the caller. Add an entry with announcement `pending`. The returned procedure runs once; if the announcement is in progress or an append is publishing, it only records the request, and the removal runs when that unwinds. Removal deletes the entry only if the store still maps the id to that exact entry, marks the session store-owned and unentered again (so writes stay disabled for good), and emits `session/disposed` unless the announcement is still `pending`.
14. `sessions-announce` (`index.ts:1367-1396`): the session must be the store's live entry (`session "<id>" is not live in this store`) with announcement `pending` (`session "<id>" was already announced`). Set `dispatching`; resolve the `session/created` callbacks and call each in order without containment. A raise sets `failed` and propagates. Success sets `complete`. In both cases a requested detach then runs.
15. Contained invocation (`index.ts:404-421`): for each callback in order, call it; a raise other than a break is logged at `warning` on the caller's context logger as `session "<id>": <event> listener threw: <text>`; a returned task is observed and its failure logged as `session "<id>": <event> listener rejected: <text>`. `<text>` is the exception message, or the `display` form of a non-exception value. A failure to resolve the `session/disposed` callbacks is logged as `session "<id>": session/disposed dispatch threw: <text>`.
16. `sessions-flush` (`index.ts:1422-1439`): the session must be live (`session "<id>" is not live in this store`). Resolve the `session/flush` callbacks; run each in its own task spawned in listener order; wait for all; re-raise the first failure in listener order with the raised value unchanged; otherwise return whether at least one callback ran. A break delivered to the caller during the wait cancels the spawned tasks with `task-cancel!` and propagates without waiting for them.

**Surface fold** (recon 04 "Surface fold"; `surface.ts:413-615`)

17. `(surface-state-empty #:base-seq [base 0])` is the state before event `base`. `(surface-plan st e event-ref projections)` validates one event and returns a plan without changing anything; `(surface-apply st plan)` returns the next state; `(surface-step st e event-ref projections)` is both. `(fold-surface events #:projections [ps '()])` steps over a whole log from seq 0 and returns a `surface-fold-result`.
18. Planning one event, in order: `e`'s seq must equal `(surface-state-next-seq st)`, else `session event seq <n> is not contiguous; expected <m>`; rule 8; for `developer/message` re-run rule 4 with subject `developer/message at seq <n>` and, when `headerSeq` is present, require the referenced event to be an earlier `request/header` (`developer/message headerSeq must reference an earlier request/header`), each `tool-addition` name to match exactly one tool of that header (`developer/message tool-addition "<name>" must name exactly one tool in headerSeq <h>`) with a string `description` and an object `parameters` (`developer/message tool-addition "<name>" requires a complete tool definition in headerSeq <h>`) and `deferLoading`, when present, to be `true` (`developer/message referenced tool deferLoading must be true when present`); if a projection is registered for the type, call it and plan `project`; else if the type is in `message-projection-event-types`, raise `session event "<type>" requires a message projection; load its owning plugin or supply its projection definition`; no surface op: no change; `'append`: plan to add the seq at the end; replace: rule 19.
19. Replace: find both endpoints among the nodes (`surface replace: start seq <n> not found in surface`, `surface replace: end seq <n> not found in surface`, `surface replace: start seq <a> (index <i>) is after end seq <b> (index <j>)`). The shadowed nodes are the inclusive range. `sourceEventSeqs` must include every shadowed seq (`surface replace: sourceEventSeqs must include every shadowed surface node; missing <a>, <b>`). A replacing `tool/result` must shadow exactly one node (`tool/result surface replacement must rewrite exactly one current node`), that node must be a `tool/result` (`tool/result surface replacement must target a current tool/result`), and the two `data` values must be equal after `message.content` is set to `null` in both (`tool/result surface replacement may change only content`). If the range starts at node 0 and node 0 is a `system/message`, the replacing event must be a `system/message` over exactly that node (`surface replace: node 0 holds the system prompt and may be rewritten only by a system/message over exactly that node`).
20. Applying: append adds the seq; replace puts the new seq where the range was and increments both generations; `project` merges the returned messages into the projected messages, records the definition as used, and increments the content generation.
21. Before any read of a session's surface or derived history, every projection definition the session has used must still be in its projection list, else raise `session message projection "<type>" was removed or replaced; restore the session with its owning plugin`.

**Derived history** (recon 04 "Derived history"; `surface.ts:120-152`, `index.ts:1079-1100`)

22. `(derive-event-message e [projected-messages])`: a projected message for `e`'s seq wins; `user/message` gives the data; `system/message`, `developer/message`, `assistant/message` give `data.message`, or `#f` when its `content` is empty; `tool/result` gives `data.message`; every other type gives `#f`.
23. `(derive-messages events #:projections [ps '()])` is a pure function: fold the surface, then apply rule 22 to each node in surface order and drop `#f`. `(session-derive-messages s)` returns the same list for the session's log, from a cache that extends by the new nodes only and is rebuilt when the content generation changes. Each call returns a fresh list. The messages are the logged jobjects themselves (`eq?` to the values inside the events) except where a projection supplied a replacement. Events that are not surface nodes never contribute.

**Header, context and tool-history folds** (`request-header.ts`, `tool-history.ts`)

24. `(canonical-header h)` returns `{config, adapterDefaults?, tools?}`, keeping `adapterDefaults` only when a marker is `true` and `tools` only when non-empty. `(fold-request-header events [from #f])` is the canonical form of the latest `request/header` in `events`, or `from`. Config equality compares `provider`, `model`, `reasoningEffort`, `temperature`, `maxTokens` (absent equals only absent; numbers by `=`) and `stop` element-wise, an absent `stop` differing from any list; it is the rule of `callConfigEquals` (`packages/llm/llm/src/call-config.ts:67-77`), kept as a private procedure here because `dsh-llm`, which exports `call-config-equal?`, sits above this package. `(header-equal? a b)` requires config equality, equal `reasoningEffort` and `maxTokens` markers, the same number of tools, and for each pair of tools in order equality of `(jvalue->string tool)`, which is sensitive to key order. `session-request-header` folds unseen events once; `session-request-context` returns the data of the latest `request/context`.
25. Tool history (`tool-history.ts:22-74`). `(tool-history-state-empty)`, `(tool-history-apply st e)` and `(tool-history-snapshot st)`. On `request/header`: remember the tool list under the event seq; start a new series (baseline this seq, declared and available names from this list, history `{tools, updates: []}`) when this is the first header, or `reason` is `"series"`, or `startsSeries` is present, or a name already declared in the current series now has a different `jvalue->string`; always set the active list. On `developer/message`: resolve each `tool-addition` in the tool list of its `headerSeq` (`tool history: missing definition for <name>`), add them to the declared set, apply additions and removals to the available names in block order, append `{messageId, additions}` to the updates. Snapshot: when the active names and the available names differ as sets, return `{tools: <active>, updates: []}`; otherwise the history.

**Fork, seeds and repair** (recon 04 "Seed construction and markers", "Fork", "Tail repair")

26. `sessions-fork` (`index.ts:1483-1550`), in order: a live `child-id` raises code `SESSION_ALREADY_EXISTS` (`session "<id>" already exists`); an unknown source id raises `SESSION_NOT_FOUND` (`session "<id>" not found`); a session object that is not the store's live instance for its id raises `SESSION_NOT_FOUND` when no session has that id and `SESSION_NOT_LIVE` (`session "<id>" is not the live store instance`) otherwise; the boundary is the argument or the last event's seq, and an empty source with no boundary forks an empty child; a boundary that is not a non-negative safe integer raises `INVALID_BOUNDARY` (`fork boundary for session "<id>" must be a non-negative safe integer, got <b>`); one at or beyond the event count raises `INVALID_BOUNDARY` (`fork boundary <b> does not exist in session "<id>" (last seq: <n or none>)`); one whose event does not carry that seq raises `INVALID_BOUNDARY` (`fork boundary <b> does not match a contiguous event seq in session "<id>"`). Then `sessions-create` with the seed from rule 27, `inherited-event-count` `boundary + 1` (or 0), and meta `{cwd: source cwd when present, isSeeded: true}`. No other header field is copied.
27. `(build-fork-seed events boundary)`: the events `0..boundary`, then `session/end-seed {inherited: true}` at seq `boundary + 1` with `time` copied from the boundary event, then `(open-turn-closers prefix-with-marker 'forked)`.
28. Constructing a session with a seed (`index.ts:660-733`). For each member at index `i`: in snapshot mode (`make-session`) a jobject member must be lossless JSON (`seed event at index <i> is not losslessly JSON-serializable`); parse the envelope with subject `seed event at index <i>`; rule 4 with subject `seed <type> at index <i>`; rule 5 for `request/header`, the five message types and `assistant/attempt`; `seq` must equal `i` (`seed event at index <i> has seq <s> (expected <i>); seed must be contiguous from 0`); plan the surface transition, re-raising a failure as `invalid seed event at index <i>: <message>`; accept. Then `first-live-seq` is the log length. Header rules: a seeded header without a seed raises `seeded session requires an explicit constructor seed`; without a count, `seeded session requires an inherited event count`; an unseeded header with a non-zero count, `unseeded session inherited event count must be 0`; a count beyond the log, `session inherited event count exceeds its event log`. Let `marked` be true when the event at index `count` is `session/end-seed` with `inherited: true`. In snapshot mode a seeded session whose count differs from the log length and that is not `marked` raises `seeded session constructor seed must equal its inherited prefix or mark its inherited cut`. If `marked` and a later event is another inherited marker, raise `session inherited event count must identify the final inherited marker`. `first-lifecycle-seq` is the count for a seeded session in snapshot mode and `first-live-seq` otherwise.
29. Markers appended by the constructor, unpublished: a seeded session in snapshot mode that is not `marked` appends `session/end-seed {inherited: true}`. Any other construction with a seed, including an empty list, appends `session/end-seed {}` unless the log already ends in a `session/end-seed`. A session without a seed appends nothing.
30. `(open-turn-closers events cause)` with `cause` `'interrupted` or `'forked` (`repair.ts:53-104`): scan once; `turn/start` opens a turn and clears the open step; `turn/end` closes both; `step/start` and `step/end` open and close a step. With no open turn return `'()`. Otherwise return, with seqs continuing the log and `time` equal to the last event's: one result per pending call from rule 31, then `step/end {turn, step}` if a step is open, then `turn/end {turn, reason: {kind: <cause>}}`. `(interrupted-turn-closers events)` uses `'interrupted`.
31. `(make-tool-call-recovery [cause 'interrupted])`, `(tool-call-recovery-observe! r e)`, `(tool-call-recovery-results r)` (`repair.ts:111-197`). Observe: `turn/start`, `turn/end`, `step/end` clear the pending calls; `assistant/message` adds each `tool-call` block id with the event's turn and step, in block order; `tool/call` records its seq on the matching pending entry; a `tool/result` whose surface op is `'append` and whose turn and step match removes the entry for `message.source.callId`. Results, a list of `session-event?` values built without changing state (the empty list when nothing was observed), one per pending call in insertion order, with seqs following the last observed event and its time: a `tool/result` with surface op `'append`, written with `#:metadata-order 'op-first`, data `{turn, step, message, error}`, message `{id, role: "tool", toolCallId, isError: true, source: {kind: "tool", callId}, content: [{type: "text", text}]}` in that key order, id `<cause>-tool-result-<callId>-<seq>`. When a `tool/call` was recorded: `error` is `{name: "ToolOutcomeUnknownError", code: "TOOL_OUTCOME_UNKNOWN"}` and `sourceEventSeqs` is the call seq. Otherwise `error` is `{name: "ToolNotStartedError", code: "TOOL_NOT_STARTED"}` and there are no sources. The four texts are `CLOSER_TEXT` in `repair.ts:32-41`, copied verbatim. Constants `tool-not-started` and `tool-outcome-unknown` hold the two codes. `open-turn-closers` uses the events as they are, in a seed. A caller that commits the results to a live session (the loop, dsh-agent rule 55) appends `(make-session-event-input "tool/result" (session-event-data e) #:surface-op 'append #:sources <(session-event-source-seqs e) when not #f>)` for each, so the session assigns seq and time and writes the live key order.

**Plugin records, seq ranges, catalogue**

32. `append-plugin-record!` (`index.ts:929-946`): rule 9; data must be lossless JSON (`plugin record "<type>" carries non-JSON-serializable data`); the type must match the plugin record grammar (`plugin record type "<type>" must be "plugin:" followed by lowercase slash-separated segments`); commit as in rule 10 with `ignorable: true`. When the type is a declaration, or the argument is a `plugin-record-input`, the data is also checked with `session-event-type-violation` of that declaration, with the subject and messages of rule 6. `plugin-record-of` returns a record only for an ignorable event whose type matches the grammar.
33. `(encode-seq-ranges seqs)` and `(decode-seq-ranges v [max-entries max-safe-integer])` implement `seq-ranges.ts`: a list that is not strictly increasing is returned unchanged; otherwise each run of three or more consecutive integers becomes the pair `(list first last)` and shorter runs stay numbers. Decoding raises `exn:fail:contract` with the messages in `seq-ranges.ts:38-72`. Events in memory always hold the expanded list.
34. A unit test checks that every type tag declared with `define-session-event` in this package is in `known-session-event-types`, and that the set has 63 members.

**Scope core** (recon 04 "Scope"; `packages/core/scope/src/index.ts`)

```racket
(scope-key? v) -> boolean?                         ; any value with identity: not a boolean, number, symbol, string, char, keyword, null or void
(scope-of ctx) -> (or/c scope-key? #f)
(context-with-scope ctx key) -> context?           ; ctx extended with the scope tag
(bind-scope-parent! key parent) -> scope-parent-binding?
(scope-parent-binding-rebind! binding parent) -> void?
(scope-parent-of key) -> (or/c scope-key? #f)
(scope-chain-of key) -> (listof scope-key?)        ; nearest first; '() for #f
(scope-filter key #:base [base #f]) -> (-> context? boolean?)
(service-realm-filter provider-ctx service-key) -> (-> context? boolean?)
(current-dispatch-scope) -> (or/c scope-key? #f)   ; parameter, set while a scoped dispatch calls listeners
(scoped-dispatch ctx mode name key args #:base [base #f] #:inner [inner #f]) -> any
(scoped-callbacks ctx mode name key args #:base [base #f]) -> (listof procedure?)
(invoke-contained callbacks args #:on-raise on-raise #:on-reject on-reject) -> void?
```

35. The tag is stored with `context-extend` under an uninterned symbol private to this module. `scope-of` reads it with `context-meta`; a context derived from a tagged context, including the context of a plugin mounted through it, reads the same tag.
36. `bind-scope-parent!` raises `exn:fail` with `dsh-scope: scope key is already bound to a parent; re-linking requires the binding returned by the original bind` when `key` has a parent, and `dsh-scope: scope parent link would form a cycle` when `key` is `parent` or an ancestor of it. `scope-parent-binding-rebind!` applies the same cycle check. The relation is an ephemeron `eq?` table at module level.
37. `(scope-filter key #:base base)` returns a predicate on a listener's registering context: false when `base` is given and rejects it; true when the context has no tag; otherwise true exactly when the tag is `key` or an ancestor of `key`. With `key` `#f` only untagged listeners pass. `(service-realm-filter provider-ctx service-key)` is true for a context in which `service-key` has the same realm as in `provider-ctx`; it is the `base` of dispatches made on behalf of a service.
38. `scoped-dispatch` is `ctx-dispatch` with that filter, run with `current-dispatch-scope` set to `key`. `scoped-callbacks` is `(ctx-dispatch-callbacks ctx mode name args #:filter <that filter>)` of the kernel (cordis-kernel section 12, addendum 2): it resolves the listeners the same dispatch would call, in order, without calling them, after notifying `'internal/dispatch` listeners; each returned procedure takes the event arguments and runs its listener with `current-dispatch-scope` set to `key`. `invoke-contained` calls each callback in order with `args`; a raise other than a break is passed to `on-raise`; a returned task is observed by a spawned task and its failure passed to `on-reject`.

## Racket design notes

- **One declaration form for events.** TypeScript spreads an event type over an interface member, the producers' object literals and the readers' casts. `define-session-event` states the tag, the fields in write order and their contracts once and derives the constructor, predicate, accessors and `match` pattern. The classes of error it removes: a producer writing keys in an order that differs from dsh (the order is fixed by the declaration, not by each call site); a misspelled type tag or field name (an unbound identifier or unknown keyword at compile time); a reader assuming a field that the declaration does not have.
- **Events are parsed views that keep their JSON.** Two producers in dsh write the two metadata keys in different orders, and restored events carry whatever order the file has. Keeping the original jobject makes the writer byte-faithful without a per-producer flag in every consumer.
- **The surface fold is a pure function over an immutable state.** The TypeScript `SurfaceManager` keeps a pending plan, an isolated copy for batches and a processed cursor so that a failed validation cannot leave partial state. With a persistent `surface-state`, validating is `surface-plan`, a batch is a fold over the candidates, and committing is storing the new state. Windowed consumers start from `(surface-state-empty #:base-seq n)`.
- **No copy modes.** `Session.create` copies and freezes, `Session.fromRestore` adopts. Immutable jvalues make both the identity. The remaining differences between the two constructors are the lossless check on seed members and the marker rules of rules 28 and 29.
- **Store attachment is a private field** of the session object in place of a module-level `WeakMap`.
- **Scoped dispatch replaces carrier objects.** A Cordis dispatch receiver that carries a filter becomes a filter procedure plus the parameter `current-dispatch-scope`, which is the counterpart of `carrierKeyOf(this)` in a listener.
- **The scope parent relation is module-level state**, as in dsh. It is an ephemeron table keyed by the scope key, so it holds nothing once a key is unreachable. This is the one exception in this package to the rule that state hangs off a service value.
- **Racket-only additions**, for the coordinator's ADR list: the parameter `current-session-time` (a test seam for the clock); the event-type catalogue (`sessions-register-event-type!`, `#:event-types`) and the declared-field check of rule 6, which stands in for TypeScript's compile-time check of `session.append` arguments and never applies to stored data; `plugin-record-input` and the one-argument form of `append-plugin-record!`; the `#:metadata-order` option of `make-session-event`; `in-session-events`; the modules `dsh-session/scope-core` and `dsh-session/lossless` (homes chosen to keep the package graph acyclic) with the parameter `current-dispatch-scope`; the marker `absent`. None changes what an unmodified dsh configuration writes.

## Work units

The package is split into two units. Unit A can be built and tested without a kernel context.

| Unit | Modules | Depends on |
|---|---|---|
| A: data plane | `lossless`, `types`, `events`, `surface`, `request-header`, `tool-history`, `repair`, `fork`, `seq-ranges` and their tests | `cordis-data` |
| B: object and store | `scope-core`, `session`, `store`, `plugin`, `plugins`, `main` and their tests | unit A, `cordis` |

The interface between the units is the set of exports of the unit A modules as listed under Modules and Data; unit B uses in particular `surface-plan`, `surface-apply`, `surface-state-empty`, `validate-session-event-data`, the rule 5 and rule 6 checks (exported from `dsh-session/surface` as `(check-event-shape type data subject)` and `(check-declared-fields types type data subject)`), `fold-request-header`, `tool-history-apply`, `build-fork-seed` and `make-session-event`. Three modules are delivered before the rest, because other packages are built against them in the same wave: `scope-core` (unit B; it has no dependency on unit A; `dsh-tools/scope` re-exports it), `lossless` (unit A; `dsh-tools/json-schema` and the pipeline use it) and `types` (unit A; `dsh-llm/jrecord` and `dsh-tools` use `absent`, `dsh-llm` uses `safe-integer?` and `define-session-event`). `events` follows, because the tool batch of `dsh-tools` and the loop write events with its constructors.

## Tests

Tests live in `racket/dsh-session/tests/`. Each row names the TypeScript suite to mirror under `packages/core/session/tests/` and what it pins.

| Racket test file | Mirrors | Pins |
|---|---|---|
| `lossless-test.rkt` | `json.spec.ts` (skip the JavaScript realm cases) | rule 1 |
| `types-test.rkt` | `sequence-types.spec.ts`, `canonical-envelopes.spec.ts` | scalar contracts, envelope rules, key order of written events, `define-session-event` expansion and syntax errors |
| `surface-test.rkt` | `surface.spec.ts`, `developer-header.spec.ts`, `message-projections.spec.ts` | rules 8 and 17 to 21, including windowed folds with a non-zero base seq and equality of `fold-surface` with stepwise folding |
| `derived-test.rkt` | `derived-cache.spec.ts`, `properties.spec.ts` | rules 22 and 23; the cache equals `derive-messages` over the same log for generated logs; non-message events never change history |
| `request-header-test.rkt`, `tool-history-test.rkt` | `request-header.spec.ts`, `tool-history.spec.ts` | rules 24 and 25 |
| `repair-test.rkt`, `fork-test.rkt` | `repair.spec.ts`, `fork.spec.ts` | rules 26, 27, 30, 31; the four texts; ids; key order of synthetic events |
| `seq-ranges-test.rkt` | `seq-ranges.spec.ts` | rule 33 |
| `session-test.rkt` | `session.spec.ts`, `append.spec.ts`, `plugin-records.spec.ts`, `preparation.spec.ts` | rules 3 to 7, 9 to 11, 28, 29, 32; every seed rejection message |
| `store-test.rkt` | `store-membership.spec.ts`, `scoped.spec.ts`, the store parts of `session.spec.ts` | rules 12 to 16; disposal of the creating fiber detaches and emits `session/disposed`; a registration test disposes the fiber and observes removal of a projection and of an event type |
| `scope-core-test.rkt` | the tagging, routing and parent parts of `packages/core/scope/tests/scope.spec.ts` | rules 35 to 38 |
| `catalog-test.rkt` | `gen-persistence-catalog.spec.ts` (the name list only) | rule 34 |

Fixtures: a helper that builds a small valid log (turn, step, system, user, assistant with one tool call, tool call, tool result, closers) through the constructors. A key-order fixture from `snapshots/session/fs-read/session.v4.jsonl`, a normalised recording whose event lines have no `seq` and `time` and whose first line is the header: for every event line, parse it with `cordis-data`, build a new event with `make-session-event` from its type, data, `sourceEventSeqs` and `surfaceOp` (seq the line's event index, a fixed time), write it with `session-event->jvalue`, remove `seq` and `time`, and require the text to equal the line; for the lines of core types also rebuild `data` through the generated constructor from the parsed fields and require the same text (this pins `usage` before `stream` on `assistant/message` and `sourceEventSeqs` before `surfaceOp` on `tool/result`). Tests set `current-session-time` to a counter.

Acceptance gate: `raco test racket/dsh-session` passes with no network; every numbered rule has at least one test that names it; the key-order fixture passes.

## Open questions

1. **Kernel support for resolving listeners without calling them.** Settled: the kernel contract now has `(ctx-dispatch-callbacks ctx mode name args #:filter [filter #f]) -> (listof procedure?)` (cordis-kernel section 12, addendum 2), the counterpart of `ctx.events.dispatch(type, args)` (`vendor/cordis/src/events.ts:161-183`), and rule 38 is written against it. `scope-core` isolates the call in one private procedure. The kernel implementation must export it before unit B, the tool pipeline and every `agent/*` emit can be tested; [WAVE3.md](WAVE3.md) lists it as a prerequisite. The kernel's `call-contained` (addendum 4) is not a substitute for `invoke-contained`: it logs at `error` with its own text and does not observe a returned task.
2. **Inheritance of context meta.** Settled: cordis-kernel section 12, addendum 3 guarantees that `context-meta` on a fiber's context sees meta set with `context-extend` on any ancestor context, which is what rule 35 needs. `scope-core-test.rkt` keeps a test that fails loudly if an implementation does not.
3. **Home of the lossless check and of `absent`.** Recommended default: keep them here; if `dsh-util` later exports equal bindings, re-export those.
4. **Events of undeclared types on live appends.** dsh accepts any type string at run time. Recommended default: keep accepting, and log nothing; the catalogue test of wave 6 compares all declarations with the 63 names.
5. **Listeners that wait.** A `session/event` listener that calls `await` suspends the append while the appending mark is set. Recommended default: document the obligation (Events) and do not enforce it; a test shows that such a listener makes concurrent appends to the same session raise the reentry error.
6. **Parameter keys that look like array indexes.** JavaScript orders integer-like object keys before others; `cordis-data` keeps textual order. No session data in the recorded snapshots depends on this. Recommended default: no special handling.
