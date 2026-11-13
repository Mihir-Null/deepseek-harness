# Interface contract: `dsh-platform`

This is the binding interface for `racket/dsh-platform/`: credentials and the local credentials file, authorization flows, the DeepSeek account, settings forms, the storage hub with its JSON and SQLite backends and the domain layer, the workspace registry, the anonymous user id, the OTLP log channels, the Office document service and tools, and the two exclusive provider registries for computer use and browser use. Sources: [recon 12](../recon/12-integrations.md) (cited as R12 with its section title) and the TypeScript under `packages/{credentials,settings,storage,workspace,identity,telemetry,document,computer-use,browser-use}/*/src` at commit `e8f7b93a3`. When this document and the TypeScript disagree about behaviour, the TypeScript is right and this document gets fixed. When they disagree about Racket names and argument order, this document is right. Read [dsh-llm.md](dsh-llm.md) ("Ports"), [dsh-agent.md](dsh-agent.md) ("Ports") and [dsh-tools.md](dsh-tools.md) first; this contract uses their vocabulary (*jvalue*, `absent`, *cancel event*, `x` as "a context or a service handle").

Package: directory `racket/dsh-platform/`, collection `dsh-platform`, `(define deps '("base" "db-lib" "cordis" "cordis-data" "cordis-schema" "cordis-yaml" "dsh-util" "dsh-session" "dsh-llm" "dsh-tools" "dsh-agent"))`, `(define build-deps '("rackunit-lib" "dsh-test-support"))`. It uses `db/sqlite3`, `file/sha1`, `file/gzip`, `net/base64`, `racket/random` and `ffi/unsafe` (for `fsync`) from the main distribution. It must not require `dsh-boot`, `dsh-web`, `dsh-session-store`, `dsh-fs` or `dsh-connect`; what it needs from them comes through the ports of this contract.

## Scope

| dsh directory | npm name | Status | How |
|---|---|---|---|
| `packages/credentials/credentials` | `@deepseek-ai/dsh-credentials` | native | The abstract class becomes `gen:credential-provider`; the service value also implements `gen:credential-port` of `dsh-llm/ports`. |
| `packages/credentials/credentials-local` | `@deepseek-ai/dsh-credentials-local` | adapted | The npm `yaml` document tree is replaced by `cordis-yaml` for reading and a line editor for comment-preserving writes (rules C20 to C27); `chokidar` by `filesystem-change-evt`. The file format, its location, the lock file and the precedence are those of dsh. |
| `packages/credentials/authorization` | `@deepseek-ai/dsh-authorization` | native | |
| `packages/credentials/deepseek-account` | `@deepseek-ai/dsh-deepseek-account` | native | The browser callback is registered through the `webServer` port; without that service a sign-in fails with code `protocol`, as in dsh. The service value implements `gen:account-port` of `dsh-llm/ports`. |
| `packages/settings/settings` | `@deepseek-ai/dsh-settings` | native | Over the settings-source port that `configEditor` of `dsh-boot` implements. The service value implements `gen:settings-port` of `dsh-llm/ports`. |
| `packages/storage/storage` | `@deepseek-ai/dsh-storage` | native | |
| `packages/storage/storage-json` | `@deepseek-ai/dsh-storage-json` | native | Same files, byte for byte. |
| `packages/storage/storage-sqlite` | `@deepseek-ai/dsh-storage-sqlite` | adapted | The `db` library in place of `node:sqlite`; same schema, pragmas and statements. |
| `packages/storage/storage-domain` | `@deepseek-ai/dsh-storage-domain` | adapted | Record validators are procedures (a `cordis-schema` schema is one) in place of Zod schemas. |
| `packages/workspace/workspace` | `@deepseek-ai/dsh-workspace` | native | Windows path rules are not applicable in this port. |
| `packages/identity/anonymous-user-id` | `@deepseek-ai/dsh-anonymous-user-id` | native | A library, no plugin. `dsh-llm` keeps a private copy until the coordinator hoists this module. |
| `packages/telemetry/otel` | `@deepseek-ai/dsh-otel` | adapted | dsh exports OTLP/HTTP JSON through the OpenTelemetry SDK and `got`. This port writes the OTLP JSON itself and sends it with `dsh-llm/http`; the channel API, limits and batching rules are those of dsh. |
| `packages/document/office-kit` | `@deepseek-ai/dsh-office-kit` | wrapped | By the npm package `@deepseek-ai/libreoffice-kit` 0.2.3 (a LibreOffice engine, native or WebAssembly) through the Node sidecar `office-kit-host.mjs`. Queue, cache, output store and error taxonomy are native. Without `node` or the kit every conversion fails with code `unavailable`, as dsh does when the kit is absent. |
| `packages/document/tool-office` | `@deepseek-ai/dsh-tool-office` | adapted | Tool definitions, argument checks, activation and rendering are native; execution needs the wrapped service, an `attachments` store and a model route with image input. |
| `packages/computer-use/computer-use` | `@deepseek-ai/dsh-computer-use` | native | The registry only. Providers live in other packages (`dsh-experimental`, MCP servers); macOS-only providers are out of scope here. |
| `packages/browser-use/browser-use` | `@deepseek-ai/dsh-browser-use` | native | The registry only. |

Not applicable: the typert `@Remote` decorators (each remote surface is a table of `(cons dsh-name procedure)` for `dsh-web`); Windows ACL and rename-retry paths; the WebAssembly Office engine as a separate target (the sidecar picks what the kit offers).

## Modules

| Module | Provides |
|---|---|
| `dsh-platform` (`main.rkt`) | re-exports `credentials`, `authorization`, `settings`, `storage`, `storage/domain`, `workspace`, `otel`, `computer-use`, `browser-use` |
| `dsh-platform/ports` | re-exports every port module below |
| `dsh-platform/credentials` | references and keys, record predicates, `gen:credential-provider`, Service Definition `credentials`, its two events, `make-memory-credential-provider` |
| `dsh-platform/credentials/document` | `parse-credentials-document`, `render-flat-layout-migration`, `render-ref`, `render-record`, `mask-credential` |
| `dsh-platform/credentials/local` | `make-local-credential-provider`, `resolve-local-spec` |
| `dsh-platform/authorization` | Service Definition `authorization`, flow and session structs, `exn:fail:authorization`, the event `authorization/settled` |
| `dsh-platform/deepseek-account/ports` | `gen:web-server-port` |
| `dsh-platform/deepseek-account/protocol` | origin and URL checks, the platform requests, `exn:fail:platform-auth` |
| `dsh-platform/deepseek-account` | Service Definition `deepseekAccount`, its events, `account-remote-methods` |
| `dsh-platform/settings/ports` | `gen:settings-source-port`, `settings-entry`, `settings-row`, `gen:profile-context-port` |
| `dsh-platform/settings/schema` | `volatile-form`, `project-form`, `volatile-path?`, `plain-config` |
| `dsh-platform/settings/redact` | `redact-secrets` |
| `dsh-platform/settings` | Service Definition `settings`, `exn:fail:settings-conflict`, the event `settings/document-updated` |
| `dsh-platform/storage` | Service Definition `storage`, `gen:storage-backend`, `gen:kv-unit`, `kv-unit-descriptor`, `exn:fail:storage`, `storage-backend-service-key`, `unit-name-rx` |
| `dsh-platform/storage/json` | `make-json-storage-backend` |
| `dsh-platform/storage/sqlite` | `make-sqlite-storage-backend`, `storage-sqlite-schema-version` |
| `dsh-platform/storage/memory` | `make-memory-storage-backend` (tests) |
| `dsh-platform/storage/domain` | `make-domain-spec`, `domain-table-spec`, `domain-global-spec`, the facility, `domain`, `kv-table`, `exn:fail:domain`, the event `domain/changed`, Service Definition `storageDomain` |
| `dsh-platform/storage/contract-suite` | `run-backend-contract-suite` (a rackunit suite any backend can be run against) |
| `dsh-platform/workspace/ports` | `gen:session-catalog-port` |
| `dsh-platform/workspace` | Service Definition `workspaceRegistry`, `workspace` entity, the four `workspace/*` events, error structs, `workspace-domain-spec`, `realpath-normalize` |
| `dsh-platform/anonymous-user-id` | `get-or-create-anonymous-user-id`, `anonymous-user-id-file-name` |
| `dsh-platform/otel` | Service Definition `otel`, the two reporters |
| `dsh-platform/otel/otlp` | `logs-request->jvalue`, `any-value->jvalue` |
| `dsh-platform/office-kit` | Service Definition `officeKit`, `gen:office-engine`, `exn:fail:office-kit`, `office-kit-remote-methods` |
| `dsh-platform/tool-office` | the three Office tools, format tables |
| `dsh-platform/computer-use`, `dsh-platform/browser-use` | Service Definitions `computerUse`, `browserUse` |
| `dsh-platform/plugin/<short-name>` | one module per plugin, each providing `plugin` |
| `dsh-platform/plugins` | `plugin-table` |

Private modules: `private/serial.rkt` (a FIFO queue of thunks run one at a time, each as its own task; the same interface as in `dsh-connect`), `private/contained.rkt` (rule C3), `credentials/private/yaml-edit.rkt`, `storage/private/atomic.rkt`, `office-kit/private/office-kit-host.mjs`.

## Data

Durable and wire values are jvalues with the dsh field names in the key order given. JavaScript `undefined` is an absent key.

### Credentials

```racket
(credential-ref-name? v) -> boolean?         ; a string matching ^[A-Za-z_][A-Za-z0-9_]*$
(credential-ref value) -> string?            ; raises exn:fail:contract: credential ref "<value>" must match /^[A-Za-z_][A-Za-z0-9_]*$/
(credential-key-segment? v) -> boolean?      ; ^[a-z][a-z0-9-]*$
(credential-key scope id) -> string?         ; "<scope>/<id>"; raises: credential key segment "<segment>" must match /^[a-z][a-z0-9-]*$/
(parse-credential-key value) -> string?      ; raises: credential key "<value>" must be "<scope>/<id>"
(credential-key? v) -> boolean?
(credential-key-scope key) (credential-key-id key) -> string?
(credential-record? v) -> boolean?           ; api-key-record? or grant-record?
```

Records: `{kind: "api-key", key?, env?}` with `env` a jobject from reference name to string, or `{kind: "grant", payload}` with `payload` any JSON value. Resolved credential `{value, source}`. Reference info `{configured, source?, writable, masked?}`. Record info `{configured, kind?, writable}`. Record entry `{key, kind}`. `source` is `file`, `env`, `project-env` or `user-env`.

The credentials document, `<Harness home>/.credentials.yaml`, mode `0600`, parent directory `0700` (R12 "Credentials document"):

```yaml
version: 1
refs:
  DEEPSEEK_API_KEY: sk-...
records:
  llm-pi-ai/openai:
    kind: api-key
    key: sk-...
    env:
      AWS_PROFILE: default
  deepseek-account-platform/default:
    kind: grant
    payload: { version: 1, token: "...", issuer: "https://platform.deepseek.com" }
```

Parsed form: `(struct credentials-document (refs records ignored-keys))` with `refs` a jobject of strings, `records` a jobject of records, `ignored-keys` a list of strings. Lock file `<path>.lock` with content `<pid>\n`.

### Authorization

```racket
(struct authorization-method (id label) #:transparent)
(struct authorization-flow (key label methods run))             ; methods : non-empty list; run : (-> authorization-session? any), waits
(struct authorization-session (method cancel commit! notify! prompt))
;; commit! : (-> credential-record? void?), waits; notify! : (-> jobject? void?); prompt : (-> jobject? string?), waits
(struct authorization-interaction (notify! prompt))
(struct exn:fail:authorization exn:fail:harness ())             ; harness name "AuthorizationError"
(struct exn:fail:authorization:declined exn:fail:authorization ())   ; name "AuthorizationDeclinedError", code DECLINED, default message "the authorization prompt was declined"
```

Notice `{message, url?, code?}`. Prompt `{kind: "text" or "secret", message, placeholder?}` or `{kind: "select", message, options: [{id, label, description?}]}`; a prompt's cancel event is passed beside it, not inside. Entry `{key, label, methods: [{id, label}], inFlight}`. Outcome `{status: "authorized" or "cancelled"}`. Codes: `DUPLICATE_FLOW`, `NO_FLOW`, `UNKNOWN_METHOD`, `ALREADY_IN_FLIGHT`, `NOT_COMMITTED`, `CANCELLED`, `DECLINED`.

### DeepSeek account

`(struct exn:fail:platform-auth exn:fail (code))` with message `account: <code>`, code one of `no-response`, `network`, `protocol`, `expired`, `storage`; `exn:fail:platform-auth:unauthorized` is the substruct with code `expired`. Neither is a harness error.

Records (`deepseek-account/src/types.ts`), keys in order: client metadata `{version, locale, timezoneOffsetSeconds}`; attempt view `{id, phase, authorizeUrl?, expiresAt?, errorCode?}` with `phase` one of `initializing`, `waiting-browser`, `exchanging`, `committing`, `succeeded`, `cancelled`, `expired`, `failed`; account view `{status: "signed-out" or "credential-stored", attempt, links: {usageUrl, topUpUrl}}`; update `{type: "snapshot" or "credentials-changed", state}`; profile `{id, name, contact, avatarUrl?}`; wallet `{currency, balance}`; detail results `{status: "ready", value}` (balance also `bonusWallets`) or `{status: "failed"}`; notification `{id, createdAt, displayUntil, title, body, actions, data?}`; batch `{nextPollAfterSeconds, notifications}`; platform session `{origin, token, userId, embeddedPageDist?, requestHeaders}`.

Stored records: key `deepseek-account-platform/default`, grant payload `{version: 1, token, issuer}`; key `deepseek-account-platform/device`, grant payload `{id: <uuid>}`.

### Settings

```racket
(struct settings-entry (id name fiber schema raw-config))       ; id : entry id string; schema : (or/c schema? #f); raw-config : (or/c jobject? #f)
(struct settings-row (entry inherited override))                 ; inherited, override : jobject?
(struct exn:fail:settings-conflict exn:fail (code expected actual))   ; code "SETTINGS_CONFLICT"; dsh SettingsConflictError
```

Descriptor, keys in order: `autoGenerate`, `ns`, `schema` (the form in Schemastery JSON), `revision`, `applies` (`"live"`), `value`, `base`, `user`, `secrets?` (`[{path: [string…], set}]`, present only with redaction). Path operation `{op: "set", path, value}` or `{op: "unset", path}`. Wire views are those of `settings/src/types.ts`.

### Storage

```racket
(struct kv-unit-descriptor (name version tables has-global? layout compatible-versions) #:transparent)
;; tables : (listof string?); layout : (or/c 'single 'per-record #f); compatible-versions : (listof exact-nonnegative-integer?)
(struct exn:fail:storage exn:fail (code cause))                 ; dsh StorageError; not a harness error
(struct exn:fail:domain exn:fail (code detail cause))           ; dsh DomainError; detail : (or/c #f jobject?) {table, key}
unit-name-rx                                                    ; #px"^[a-z][a-z0-9_]*$"
```

Storage codes (symbols): `backend-not-found`, `form-not-mounted`, `duplicate-backend`, `duplicate-mount`, `version-mismatch`, `malformed-medium`, `unknown-state`, `closed`. Domain codes: `already-open`, `facet-unsupported`, `invalid-record`, `missing-key`, `closed`.

JSON backend, single layout, file `<root>/<unit>.json`, written with `(jvalue->string v #:indent 2)` and a final newline (R12 "Storage JSON backend files"):

```json
{
  "unit": { "name": "workspace", "version": 2 },
  "global": null,
  "tables": { "workspaces": { "<key>": { … } } }
}
```

(The example compresses lines; the writer's layout is that of `JSON.stringify(document, null, 2)`.) Key order: `unit` (`name`, `version`), `global`, `tables` in descriptor order, records in map order. Per-record layout, directory `<root>/<unit>/`: `<table>/<key>.json` and `global.json`, each `{"version": n, "record": value}` with the same indentation and a final newline. Residue names: `<key>.json.deleting`, `<key>.json.bak.<YYYYMMDDHHmm>` (local time), `.<uuid>.tmp`. Files `0600`, directories `0700`. Per-record keys match `^[a-zA-Z0-9_-]+$`.

SQLite backend (R12 "Storage SQLite backend schema"): `PRAGMA user_version = 1`; tables `units (name TEXT PRIMARY KEY, version INTEGER NOT NULL) STRICT`, `unit_globals (unit TEXT PRIMARY KEY REFERENCES units(name), value TEXT NOT NULL) STRICT`, and per unit table `"u_<unit>_<table>" (key TEXT PRIMARY KEY, value TEXT NOT NULL) STRICT`; `value` is `jvalue->string` of the record.

A `domain/changed` payload is `{domain, table, key, operation: "put", value}` or `{domain, table, key, operation: "deleted"}`; `table` and `key` are `""` for the global.

### Workspace

Domain `workspace`, version 2, single layout (`workspace/src/spec.ts`). Table `workspaces`, keyed by workspace id (a random UUID), record `{path, title, sessionIds, createdAt, updatedAt}` (ISO-8601 instants as strings). Global `{initialized, defaultWorkspaceId?, workspaceIds, archivedSessionIds, pinnedSessionIds, pendingMutation?}` with `pendingMutation` `{operation: "create" or "delete", workspaceId}`; initial `{initialized: false, workspaceIds: [], archivedSessionIds: [], pinnedSessionIds: []}`; a stored global without `archivedSessionIds` or `pinnedSessionIds` reads them as `[]`.

```racket
(workspace? v)                                         ; opaque entity
(workspace-id w) (workspace-path w) (workspace-title w) (workspace-created-at w) (workspace-updated-at w) -> string?
(workspace-session-ids w) -> (listof string?)          ; the membership-filtered list (rule W6)
(struct exn:fail:workspace exn:fail ())
(struct exn:fail:workspace:unknown-session exn:fail:workspace (session-id))
(struct exn:fail:workspace:active-session exn:fail:workspace (session-id activity))
(struct exn:fail:workspace:archived-session-pin exn:fail:workspace (session-id))
(struct exn:fail:workspace:order-invalid exn:fail:workspace (workspace-id))
(struct exn:fail:workspace:move-invalid exn:fail:workspace ())
(struct exn:fail:workspace:aggregate exn:fail:workspace (errors))      ; the counterpart of AggregateError; errors : list
```

A session activity is `{kind, items?: [{id, label?}]}`; kinds are added by other packages (`turn`, `job`, `subagent`, `schedule`).

### Telemetry

Event record `{eventName, body, timestamp, severityNumber?, attributes?}`; session-log record `{sessionId, event, attributes?, severityNumber?}` where `event` is a session event in its JSON form. Channel options are hashes or jobjects with the dsh keys: `exporter` (`{url, headers?, timeoutMillis?, compression?, userAgent?}`; `headers` a jobject or a thunk), `resourceAttributes`, `scope` (`{name, version?}`), `processor` (`{maxQueueSize?, maxExportBatchSize?, scheduledDelayMillis?, exportTimeoutMillis?}`), `maxRequestBytes?`, `onFailure` (a procedure `(-> string? (or/c exn? #f) any)`).

### Office

`(struct exn:fail:office-kit exn:fail (code))`, name `OfficeKitError`, codes `input-too-large`, `output-too-large`, `invalid-document`, `unsupported-format`, `invalid-output`, `timeout`, `unavailable`, `failed`, `busy`, `source-changed`, `invalid-request`. Request and result records are those of `office-kit/src/types.ts` with the dsh keys.

## Services

`x` is a context or a handle for the service.

### Ports

```racket
;; dsh-platform/deepseek-account/ports — key 'webServer (dsh-web)
(define-generics web-server-port
  (web-server-register-exact! web-server-port ctx path handler))   ; -> disposer?; an effect on ctx
;; handler : (-> jobject? jobject?) from {method, path, query: [[name, value]…]} to {status, headers: {name: value}, body?: string}; it may wait; the response is sent when it returns

;; dsh-platform/settings/ports — keys 'configEditor and 'profileContext (dsh-boot)
(define-generics settings-source-port
  (settings-source-document-path settings-source-port)             ; -> path-string?; the profile patch path
  (settings-source-entries settings-source-port)                   ; -> (listof settings-entry?); uniquely addressed profile entries
  (settings-source-rows settings-source-port)                      ; -> (listof settings-row?); dsh configEditor.configuration()
  (settings-source-resolve-inherited settings-source-port entry inherited)   ; -> jvalue?; interpolated and, when the plugin config accepts it, resolved
  (settings-source-edit! settings-source-port entry change)        ; change : (-> jobject? jobject? jobject?) raw inherited -> next raw; waits until the patch is written
  (settings-source-loaded-evt settings-source-port))               ; evt ready once the loader finished its first load
(define-generics profile-context-port
  (profile-context-home profile-context-port)                      ; -> path-string?
  (profile-context-name profile-context-port))                     ; -> string?

;; dsh-platform/workspace/ports — key 'sessionPersistence (dsh-session-store)
(define-generics session-catalog-port
  (session-catalog-list session-catalog-port))                     ; -> (listof session-header?); every stored session; waits
```

The `sessions` service is read through `dsh-session/store` directly (`sessions-list`, `sessions-find`). The launch environment, the Harness home, `with-file-lock` and `write-file-atomic` come from `dsh-util` (Open question 1).

### `credentials`

`(define-service credentials 'credentials #:contract credentials-service?)`.

```racket
(define-generics credential-provider
  (provider-resolve credential-provider ref)                 ; -> (or/c jobject? #f)
  (provider-describe credential-provider ref)                ; -> jobject?
  (provider-set! credential-provider ref value)              ; waits
  (provider-unset! credential-provider ref)                  ; waits
  (provider-read-record credential-provider key)             ; -> (or/c jobject? #f)
  (provider-describe-record credential-provider key)         ; -> jobject?
  (provider-list-records credential-provider)                ; -> (listof jobject?)
  (provider-modify-record! credential-provider key mutate)   ; mutate : (-> (or/c jobject? #f) (or/c jobject? #f)), may wait; -> (or/c jobject? #f); waits
  (provider-delete-record! credential-provider key))         ; waits
(make-credentials-service ctx provider) -> credentials-service?     ; the value to provide; implements gen:credential-port
(credentials-resolve x ref) (credentials-describe x ref) (credentials-set! x ref value) (credentials-unset! x ref)
(credentials-read-record x key) (credentials-describe-record x key) (credentials-list-records x)
(credentials-modify-record! x key mutate) (credentials-delete-record! x key)
(credentials-notify-reference-updated! service ref) -> void?        ; for providers
(credentials-notify-record-updated! service key) -> void?
(make-memory-credential-provider [environment (hash)]) -> credential-provider?   ; tests; dsh tests/memory.ts
```

The nine `credentials-…` procedures apply the provider operation of the same name; `ref` and `key` are checked with `credential-ref-name?` and `credential-key?`. None registers an effect. Through `gen:credential-port`, `credential-resolve` returns the `value` of `provider-resolve` or `#f`, and `credential-configured?` returns the `configured` of `provider-describe`. Consumers resolve per operation and never cache across operations. `provider-modify-record!` is the only write path for records: one serialized read-modify-write in which `mutate` returning `#f` leaves the entry.

### `authorization`

`(define-service authorization 'authorization #:contract authorization-service?)`.

```racket
(authorization-register-flow! x flow) -> disposer?
(authorization-list x) -> (listof jobject?)
(authorization-describe x key) -> (or/c jobject? #f)
(authorization-begin x #:key key #:interaction interaction #:method [method #f] #:cancel [cancel #f]) -> jobject?   ; waits
(authorization-cancel! x key) -> void?
```

`authorization-register-flow!` is one effect `authorization.registerFlow()` on the caller's context; a duplicate key raises `DUPLICATE_FLOW` `an authorization flow for "<key>" is already registered`; its inverse removes the flow and cancels a running attempt for the key. `authorization-begin` errors: rule A1.

### `deepseekAccount`

`(define-service deepseek-account 'deepseekAccount #:contract deepseek-account?)`. The value implements `gen:account-port`: `account-resolve-token` is rule D6 and `account-reject-token!` is rule D7.

```racket
(account-state x) -> jobject?                                        ; dsh getState; waits
(account-profile x client) (account-balance x client) -> (or/c jobject? #f)
(account-notifications x client) -> (or/c jobject? #f)
(account-notification-content x id client) -> (or/c jobject? #f)
(account-report-notification-event! x id event client) -> boolean?   ; event : "displayed" "cta_clicked" "dismissed"
(account-start-sign-in! x client callback-origin login-source) -> jobject?   ; login-source : "web" or "desktop"
(account-cancel-sign-in! x attempt-id) -> jobject?
(account-sign-out! x client) -> jobject?
(account-has-running-tasks? x) -> boolean?
(account-watch-expiry x #:cancel cancel) -> (-> (or/c "session-expired" eof-object?))      ; pull thunk
(account-watch x #:cancel cancel #:identity-changes? [i? #f]) -> (-> (or/c jobject? eof-object?))
(account-platform-session x) -> (or/c jobject? #f)                   ; host only
(account-device-identity x) -> jobject?                              ; host only: {deviceId?, userId?, osVersion}
account-remote-methods   ; namespace "account": getState, getProfile, getBalance, getNotifications, getNotificationContent, reportNotificationEvent, startSignIn, cancelSignIn, signOut, hasRunningAccountTasks, watchExpiry (stream), watch (stream)
```

### `settings`

`(define-service settings 'settings #:contract settings-forms?)`. The value implements `gen:settings-port`: `(settings-configure! port ctx options)` is `settings-configure!` below with the fiber of `ctx`.

```racket
(settings-describe x #:redact-secrets? [redact? #f]) -> (listof jobject?)
(settings-update! x ns patch [expected-revision #f]) -> void?        ; waits
(settings-replace! x ns section [expected-revision #f]) -> void?
(settings-mutate! x ns ops [expected-revision #f]) -> void?
(settings-configure! x options [owner-ctx (use-context x)]) -> disposer?   ; options : jobject with optional auto
(settings-writable? x) -> #t
(settings-document-path x) -> path-string?
(settings-prepare-document x) -> path-string?
```

### `storage`, `storageDomain`

`(define-service storage 'storage #:contract storage-hub?)`; `(define-service storage-domain 'storageDomain #:contract domain-facility?)`.

```racket
(define-generics storage-backend
  (backend-kv-open storage-backend descriptor)               ; -> kv-unit?; waits; a backend without the kv facet does not implement it
  (backend-close! storage-backend))                          ; waits
(storage-backend-kv? backend) -> boolean?
(define-generics kv-unit
  (kv-load-all kv-unit)                                      ; -> (values jobject? jvalue?) tables (name -> jobject key -> value) and global ('null when never written)
  (kv-put-record! kv-unit table key value)
  (kv-delete-record! kv-unit table key)
  (kv-delete-records! kv-unit table keys)                    ; one batch, idempotent
  (kv-backup-record! kv-unit table key)                      ; -> string?, where the document went; optional
  (kv-set-global! kv-unit value)
  (kv-close! kv-unit))
(kv-unit-can-backup? unit) -> boolean?

(storage-register-backend! x name backend) -> (-> void?)    ; raises duplicate-backend
(storage-backend x name) -> storage-backend?                ; raises backend-not-found
(storage-backend-names x) -> (listof string?)
(storage-mount! x form facility) -> (-> void?)              ; form : symbol; raises duplicate-mount
(storage-form x form) -> any/c                              ; raises form-not-mounted
(storage-domain-form x) -> domain-facility?                 ; (storage-form x 'domain); dsh ctx.storage.domain
(storage-backend-service-key name) -> symbol?               ; 'storage.backend.<name>

(make-domain-spec #:name name #:version version #:tables tables #:global [global #f] #:layout [layout #f]
                  #:compatible-versions [versions '()] #:invalid-records [policy #f]) -> domain-spec?
;; tables : (listof (cons/c string? domain-table-spec?)); policy : (or/c #f 'backup-and-skip)
(domain-table-spec validator) -> domain-table-spec?          ; validator : (-> jvalue? jvalue?), returns the stored form or raises
(domain-global-spec validator initial) -> domain-global-spec?
(domain-open x spec) -> domain?                              ; waits
(domain-find x name) -> (or/c domain? #f)                    ; dsh get
(domain-close-all! x) -> void?
(domain-name d) -> string?
(domain-global-ref d) -> jvalue?                             ; no wait
(domain-global-set! d value) -> void?                        ; waits for durability
(domain-table d name) -> kv-table?
(domain-close! d) -> void?
(kv-table-ref t key [default #f]) (kv-table-entries t) (kv-table-keys t) (kv-table-count t)   ; no wait; snapshots
(kv-table-put! t key value) -> void?
(kv-table-delete! t key) -> boolean?
(kv-table-delete-many! t keys) -> exact-nonnegative-integer?
(kv-table-update! t key proc) -> jvalue?                     ; proc : (-> jvalue? jvalue?)
```

`storage-register-backend!` and `storage-mount!` return plain undo procedures, as in dsh; the backend plugins wrap them in effects. The caller of `domain-open` owns `domain-close!`; the facility closes leftovers when it unmounts.

### `workspaceRegistry`

`(define-service workspace-registry 'workspaceRegistry #:contract workspace-registry?)`.

```racket
(workspace-registry-create! x path [title #f]) -> workspace?
(workspace-registry-initialize-default! x resolve-directory) -> (or/c workspace? #f)   ; resolve-directory : (-> path-string?), may wait
(workspace-registry-ref x id) -> (or/c workspace? #f)
(workspace-registry-list x) -> (listof workspace?)
(workspace-registry-delete! x id) -> boolean?
(workspace-registry-insert-before! x id [before-id #f]) -> (listof string?)
(workspace-registry-resolve-by-path x path) -> (or/c workspace? #f)
(workspace-registry-archived-session-ids x) (workspace-registry-pinned-session-ids x) -> (listof string?)
(workspace-registry-archive-session! x session-id #:stop-activity? [stop? #f]) -> void?
(workspace-registry-unarchive-session! x session-id) -> void?
(workspace-registry-pin-session! x session-id) (workspace-registry-unpin-session! x session-id) -> void?
(workspace-set-title! w title) (workspace-attach-session! w session-id) (workspace-detach-session! w session-id) -> void?
(workspace-insert-session-before! w session-id [before-session-id #f]) -> void?
(workspace-status w) -> (or/c 'ok 'missing-dir)
(realpath-normalize path) -> string?
```

Every mutating procedure waits for durability and runs on the registry's one serial queue. None registers an effect on the caller's context.

### `otel`

`(define-service otel 'otel #:contract otel?)`.

```racket
(otel-create-event-reporter x options) -> event-reporter?
(event-reporter-emit! r record) -> void?
(event-reporter-shutdown! r #:cancel [cancel #f]) -> void?           ; waits
(otel-create-session-log-reporter x options) -> session-log-reporter?
(session-log-report! r record) -> void?
(session-log-stop-pending! r) -> void?
(session-log-shutdown! r) -> void?                                    ; waits
```

Mounting creates no queue and no connection. Each channel is owned and drained by the consumer that created it; its tasks run under the custodian current at creation.

### `officeKit`, `computerUse`, `browserUse`

```racket
(define-generics office-engine                               ; one conversion engine instance
  (office-engine-render office-engine input-path output-path cancel)                   ; to PDF; -> jobject?
  (office-engine-render-images office-engine request cancel)                           ; -> jobject?
  (office-engine-convert office-engine input-path output-path sheet cancel)            ; sheet : (or/c string? #f)
  (office-engine-recalculate office-engine input-path output-path cancel)
  (office-engine-close! office-engine))
(office-kit-render-images x request cancel) (office-kit-convert-to x request cancel) (office-kit-recalculate x request cancel) -> jobject?   ; wait
(office-kit-convert x request cancel) -> jobject?           ; Office to PDF for previews
(office-kit-output-directory x) -> path-string?
office-kit-remote-methods                                   ; (list (cons "render" …))

(computer-use-register! x name) -> disposer?                ; one effect computerUse.register()
(computer-use-provider-name x) -> (or/c string? #f)
(browser-use-register! x name) -> disposer?                 ; one effect browserUse.register()
(browser-use-provider-name x) -> (or/c string? #f)
```

### Waiting and cancellation

- Credential, storage, domain, workspace and settings writes take no cancel event: a durable write must complete. A break delivered to a waiting caller ends that caller's wait only; the queued job still runs.
- `authorization-begin` takes `#:cancel`; a flow observes `authorization-session-cancel`.
- Account detail reads are bound to a credential lifetime (rule D8), not to the caller; the two watch thunks take `#:cancel`.
- Office operations and `event-reporter-shutdown!` take a cancel event.
- File I/O runs under `blocking`. SQLite calls are made directly from the task: they are short synchronous calls into the library.

## Events

```racket
(define-event credentials/reference-updated 'credentials/reference-updated #:mode emit #:args (credential-ref-name?))
(define-event credentials/record-updated 'credentials/record-updated #:mode emit #:args (credential-key?))
(define-event authorization/settled 'authorization/settled #:mode emit #:args (credential-key? (or/c "authorized" "cancelled" "failed")))
(define-event deepseek-account/session-expired 'deepseek-account/session-expired #:mode emit #:args ())
(define-event deepseek-account/signed-out 'deepseek-account/signed-out #:mode emit #:args ())
(define-event deepseek-account/model-sign-in-required 'deepseek-account/model-sign-in-required #:mode emit #:args ())
(define-event settings/document-updated 'settings/document-updated #:mode emit #:args (string? exact-nonnegative-integer?))
(define-event domain/changed 'domain/changed #:mode emit #:args (jobject?))
(define-event workspace/session-activity 'workspace/session-activity #:mode waterfall #:args (jobject?) #:result (listof jobject?))
(define-event workspace/session-stop 'workspace/session-stop #:mode parallel #:args (jobject?))
(define-event workspace/session-archived 'workspace/session-archived #:mode parallel #:args (jobject?))
(define-event workspace/session-unarchiving 'workspace/session-unarchiving #:mode parallel #:args (jobject?))
```

| Event | Dispatched by, when | Guarantees |
|---|---|---|
| `credentials/reference-updated` | a provider through `credentials-notify-reference-updated!`, after a committed `set` or `unset`, or an observed external edit | Contained (rule C3); a failure is logged at `warning` as `credentials: a credentials/reference-updated listener for "<ref>" failed`. Ambient environment changes never emit. |
| `credentials/record-updated` | likewise after a `modify` that wrote, a `delete` that removed, or an external edit | Contained; the same log line with the event name and the key. |
| `authorization/settled` | `authorization-begin`, after the key is released, for every terminal outcome | Contained; `authorization: an authorization/settled listener for "<key>" failed`. |
| `deepseek-account/session-expired` | the account, when a server rejection removed the stored grant | Not replayed. Followed by `signed-out`. |
| `deepseek-account/signed-out` | the account, after local grant removal | Rule D10 cancels running account-route agents. |
| `deepseek-account/model-sign-in-required` | the account, on `agent/error` whose error is an `exn:fail:llm` with code `ACCOUNT_SIGN_IN_REQUIRED` | |
| `settings/document-updated` | `settings-describe` (rule S3), with the namespace and the new revision | A plain emit: a raising listener propagates to the describe call. |
| `domain/changed` | the domain layer, after backend durability and after memory was updated | One event per write, in write order per domain. A raising listener is logged at `warning` as `domain '<name>': domain/changed listener failed: <error>` and does not fail the write. |
| `workspace/session-activity` | `workspace-registry-archive-session!` without `stop-activity?`; the innermost step returns `'()` | Providers prepend their entries to `(next)`. Any non-empty result refuses the archive. |
| `workspace/session-stop` | archive with `stop-activity?`, after the archive set is durable | Failures are logged per failure (rule W12) and do not undo the archive. |
| `workspace/session-archived` | archive, after the durable write and any stops, inside the queue | A failure is logged at `warning` `Session archived, but archive follow-up admission failed: <error>`. Not dispatched for an already archived id. |
| `workspace/session-unarchiving` | unarchive, before the write | A failure keeps the archived state and propagates. |

The payload of the three parallel workspace events and the request of the waterfall is `{sessionId}`. Consumed: `'app-boot/config-reload` (settings), `tools/result`, `session/event`, `agent/disposed` (tool-office), `agent/error` (account).

## Tools

Only `tool-office` registers model-facing tools. Their compiled parameter schemas equal `snapshots/session/office-progressive-native/tool-schemas.expected.json`.

```racket
(define-tool office-render
  #:name "office_render"
  #:description "Render document pages, slides, or worksheet areas as images you can view."
  #:parameters ([input (v-string #:description "Path to doc, docx, odt, xls, xlsx, ods, ppt, pptx, odp, or pdf; not modified.") #:required]
                [pages (v-array #:items (v-integer) #:description "Distinct one-based pages or slides; omit for all. Spreadsheets use sheet and range instead.")]
                [sheet (v-string #:description "Exact worksheet name; omit to render every visible sheet.")]
                [range (v-string #:description "A1 range, such as A1:H40; requires sheet. Omit for the used area.")]
                [dpi (v-integer #:description "Resolution from 24 to 600; default 144.")])
  #:output office-render-output-spec
  (render (value) …) (execute (exec) …) (concurrency-safe? () #t))
(define-tool office-convert
  #:name "office_convert"
  #:description "Convert a document to another format. Return a temporary file to copy to its destination with the shell."
  #:parameters ([input (v-string #:description "Path to doc, docx, odt, xls, xlsx, ods, ppt, pptx, or odp; not modified.") #:required]
                [format (v-string #:enum '("pdf" "docx" "odt" "txt" "xlsx" "ods" "csv" "pptx" "odp")
                                  #:description "Word: pdf, docx, odt, txt. Excel: pdf, xlsx, ods, csv. PowerPoint: pdf, pptx, odp.") #:required]
                [sheet (v-string #:description "Exact worksheet name for CSV only; required when the workbook has several sheets.")])
  #:output office-file-output-spec
  (render (value) …) (execute (exec) …) (concurrency-safe? () #f))
(define-tool office-recalculate
  #:name "office_recalculate"
  #:description "Recalculate spreadsheet formulas. Return a temporary workbook to copy to its destination with the shell."
  #:parameters ([input (v-string #:description "Path to an xls, xlsx, or ods workbook; not modified.") #:required]
                [format (v-string #:enum '("xlsx" "ods") #:description "Output workbook format.") #:required])
  #:output office-file-output-spec
  (render (value) …) (execute (exec) …) (concurrency-safe? () #f))
```

Output specs, result text, runtime argument checks and error strings are those of `tool-office/src/index.ts:113-215`, `content.ts` and `formats.ts`, copied verbatim (rule F6). Failure text: `cannot <operation> "<path>": <message><hint>`.

## Plugins

| dsh npm name | Module | Inject | Optional reads | Provides |
|---|---|---|---|---|
| `@deepseek-ai/dsh-credentials-local` | `dsh-platform/plugin/credentials-local` | none | | `credentials` |
| `@deepseek-ai/dsh-authorization` | `dsh-platform/plugin/authorization` | `credentials` | | `authorization` |
| `@deepseek-ai/dsh-deepseek-account` | `dsh-platform/plugin/deepseek-account` | `credentials`, `authorization` | `webServer`, `agents` | `deepseekAccount` |
| `@deepseek-ai/dsh-settings` | `dsh-platform/plugin/settings` | `configEditor`, `profileContext` | | `settings` |
| `@deepseek-ai/dsh-storage` | `dsh-platform/plugin/storage` | none | | `storage` |
| `@deepseek-ai/dsh-storage-json` | `dsh-platform/plugin/storage-json` | `storage` | | `storage.backend.json` |
| `@deepseek-ai/dsh-storage-sqlite` | `dsh-platform/plugin/storage-sqlite` | `storage` | | `storage.backend.sqlite` |
| `@deepseek-ai/dsh-storage-domain` | `dsh-platform/plugin/storage-domain` | `storage` | | `storageDomain` (from a nested fiber) |
| `@deepseek-ai/dsh-workspace` | `dsh-platform/plugin/workspace` | `storageDomain`, `sessionPersistence` | `sessions` | `workspaceRegistry` |
| `@deepseek-ai/dsh-otel` | `dsh-platform/plugin/otel` | none | | `otel` |
| `@deepseek-ai/dsh-office-kit` | `dsh-platform/plugin/office-kit` | none | `fs`, `workspaceFiles` | `officeKit` |
| `@deepseek-ai/dsh-tool-office` | `dsh-platform/plugin/tool-office` | `tools`, `fs`, `workingDirectory`, `agents` | `officeKit`, `llm`, `attachments`, `subagents` | none |
| `@deepseek-ai/dsh-computer-use` | `dsh-platform/plugin/computer-use` | none | | `computerUse` |
| `@deepseek-ai/dsh-browser-use` | `dsh-platform/plugin/browser-use` | none | | `browserUse` |

`@deepseek-ai/dsh-credentials` is the abstract seam and `@deepseek-ai/dsh-anonymous-user-id` a library; neither has a row in `plugin-table`. `#:meta` records the dsh function-plugin name under `'dsh-name` for `storage-json`, `storage-sqlite`, `storage-domain` and `tool-office`.

**`@deepseek-ai/dsh-credentials-local`** config (`credentials-local/src/index.ts:319-324`): `path` string, no default (the file is `<dshHome>/.credentials.yaml`); `dshHome` string, no default (the Harness home of `dsh-util`: `$DSH_HOME`, else `~/.dsh`); `watch` boolean `true`; `debounceMs` number at least 0, `100`. Body: rules C10 and C18.

**`@deepseek-ai/dsh-authorization`**, **`@deepseek-ai/dsh-storage`**, **`@deepseek-ai/dsh-otel`**, **`@deepseek-ai/dsh-computer-use`**, **`@deepseek-ai/dsh-browser-use`**, **`@deepseek-ai/dsh-settings`**, **`@deepseek-ai/dsh-workspace`**: no config. Each body creates and provides its service; settings also does rule S9; workspace runs rule W1 before it provides.

**`@deepseek-ai/dsh-deepseek-account`** config (`deepseek-account/src/index.ts:58-73`):

| Field | Type | Default |
|---|---|---|
| `platformOrigin` | string | `https://platform.deepseek.com` |
| `harnessOrigin` | string | `https://harness.deepseek.com` |
| `desktopPlatform` | `"darwin"`, `"win32"` or `null` | `null` |
| `embeddedPageDist` | string | `""` |
| `inferenceOrigin` | string | `https://api.deepseek.com` |
| `allowLoopbackHttp` | boolean | `false` |
| `rewriteBrowserOrigin` | boolean | `false` |
| `requestHeaders` | dict of string with role `secret` | `{}` |
| `accountRequestHeaders` | dict of string with role `secret` | `{}` |
| `requestTimeoutMs` | number 1 to 120000 | `30000` |
| `balanceTimeoutMs` | number 1 to 120000 | `30000` |
| `logoutMaxRetries` | integer 0 to 5 | `5` |
| `logoutRetryDelayMs` | number 1 to 60000 | `1000` |
| `attemptTimeoutMs` | number 1 to 3600000 | `600000` |

Body: rules D1 and D2.

**`@deepseek-ai/dsh-storage-json`** config: `root` string, required. Body: one effect that registers the backend under the name `json` and whose inverse unregisters it and closes it; then `(ctx-provide ctx (storage-backend-service-key "json") backend)`.

**`@deepseek-ai/dsh-storage-sqlite`** config: `path` string, required (`:memory:` allowed); `journalMode` one of `wal`, `delete`, `truncate`, `persist`, default `wal`. Body: the same with the name `sqlite` and the effect label `storage-sqlite.registerBackend`.

**`@deepseek-ai/dsh-storage-domain`** config: `backend` string, required; `routes` dict of string, default `{}`. Body: `(ctx-inject ctx keys proc)` where `keys` are `storage-backend-service-key` of the default backend and of every routed backend, without repeats; `proc` creates the facility on the nested context, registers one effect that mounts it as form `domain` and whose inverse closes all domains and unmounts, and provides `storageDomain`.

**`@deepseek-ai/dsh-office-kit`** config: the 22 fields of R12 "`@deepseek-ai/dsh-office-kit`" with those defaults (`office-kit/src/index.ts` schema), `outputDirectory` defaulting to `<Harness home>/office-kit/outputs`.

**`@deepseek-ai/dsh-tool-office`** config (`tool-office/src/index.ts:52-59`): `activationSkills` array of strings matching `^[a-z0-9]+(?:-[a-z0-9]+)*$`, at least one, default `["office", "office-docx", "office-xlsx", "office-pptx"]`; `maxImages` natural 1 to 10000, `20`; `maxImagePixels` natural 1 to 16777216, `8388608`; `maxImageDimension` natural 1 to 16777216, `8192`; `maxImageBytes` natural at least 1, `33554432`.

```racket
(define plugin-table
  '(("@deepseek-ai/dsh-credentials-local" . dsh-platform/plugin/credentials-local)
    ("@deepseek-ai/dsh-authorization" . dsh-platform/plugin/authorization)
    ("@deepseek-ai/dsh-deepseek-account" . dsh-platform/plugin/deepseek-account)
    ("@deepseek-ai/dsh-settings" . dsh-platform/plugin/settings)
    ("@deepseek-ai/dsh-storage" . dsh-platform/plugin/storage)
    ("@deepseek-ai/dsh-storage-json" . dsh-platform/plugin/storage-json)
    ("@deepseek-ai/dsh-storage-sqlite" . dsh-platform/plugin/storage-sqlite)
    ("@deepseek-ai/dsh-storage-domain" . dsh-platform/plugin/storage-domain)
    ("@deepseek-ai/dsh-workspace" . dsh-platform/plugin/workspace)
    ("@deepseek-ai/dsh-otel" . dsh-platform/plugin/otel)
    ("@deepseek-ai/dsh-office-kit" . dsh-platform/plugin/office-kit)
    ("@deepseek-ai/dsh-tool-office" . dsh-platform/plugin/tool-office)
    ("@deepseek-ai/dsh-computer-use" . dsh-platform/plugin/computer-use)
    ("@deepseek-ai/dsh-browser-use" . dsh-platform/plugin/browser-use)))
```

## Behaviour

"Raise" without a type means `exn:fail` with the exact message; where dsh throws `TypeError` this package raises `exn:fail:contract` with the same message.

### C. Credentials (R12 "Credentials local provider"; `packages/credentials/{credentials,credentials-local}/src`)

C1. Reference grammar `^[A-Za-z_][A-Za-z0-9_]*$`; key grammar `<scope>/<id>` with both segments `^[a-z][a-z0-9-]*$`; exactly one `/`.
C2. Precedence of `provider-resolve` in the local provider: the document's `refs` (`source` `file`); else the launch environment's `process` layer (`env`); else its `project-env` layer, then its `user-env` layer (`source` the layer name). An empty value counts as absent in every layer. `provider-describe` returns `{configured: true, source: "file", writable: true, masked}` for a stored value, `{configured: true, source, writable: true}` for the other layers, and `{configured: false, writable: true}` otherwise.
C3. Contained fan-out (`credentials/src/index.ts:177`, shared by rules A6 and the events table): resolve the listeners with `ctx-dispatch-callbacks`, call each in order; a raise, or the failure of a task a listener returns, is logged and does not reach the writer or later listeners.
C4. `mask-credential` (`index.ts:522`): over code points; the provider prefix ends at the first `-` or `_`, inclusive (no such character: no prefix); `hidden` is the length minus the prefix minus 9; when `hidden` is below 8 the result is `•` repeated for the whole length; otherwise the prefix plus 5 code points, `•` repeated `hidden` times, and the last 4 code points.
C10. Boot (`loadInitial`, `index.ts:800`). Mode check: when the file exists and any group or other permission bit is set, raise `credentials-local: <file> is readable beyond its owner (mode <octal of the low 9 bits>); run "chmod 600 <file>" before starting again`. An absent file is an empty store. When the text is a flat layout (C12) migrate it (C13). Parse (C11); log ignored keys (C16); keep the text as the cached text.
C11. `parse-credentials-document` (`index.ts:192`). Read with `yaml-read` of `cordis-yaml`, `#:schema 'json`. A syntax error raises `credentials-local: invalid document at <file>: <code> at line <L>, column <C>` (several errors joined by `; `), where the code is `DUPLICATE_KEY` for the reason `duplicated mapping key`, `BAD_INDENT` for a reason starting `bad indentation`, `MULTIPLE_DOCS` for more than one document, and `UNEXPECTED_TOKEN` otherwise; the message never quotes a value. No document or a null document is an empty store. A root that is not a mapping raises `exn:fail:contract` `credentials-local: <file> must be a mapping`. An empty mapping is an empty store. A mapping without `version` raises `credentials-local: <file> uses the pre-release flat layout. Add \`version: 1\` and nest the existing <n> <entry or entries> under \`refs:\`. No values need to change.` A `version` other than 1 raises `credentials-local: <file> declares version <JSON of the value>; this build reads version 1`. `refs` and `records`, when present and not null, must be mappings (`credentials-local: "<name>" in <file> must be a mapping`). Every other top-level key is listed in `ignored-keys`.
C11a. `refs` entries: the key must be a reference (the error of `credential-ref`); a value that is not a string raises `credentials-local: the value for "<key>" in <file> must be a string`; an empty string raises `credentials-local: the value for "<key>" in <file> is empty; remove the key instead`. `records` entries: the key must parse as a key; the value must be a mapping (`credentials-local: record "<key>" in <file> must be a mapping`); `kind` `api-key` allows the fields `kind`, `key`, `env` (`… has unknown field "<field>"`), `key` a non-empty string (`… has a non-string or empty key`), `env` a mapping (`… has a non-mapping env`) of reference names to non-empty strings (`credentials-local: record "<key>" env "<name>" in <file> must be a non-empty string`); `kind` `grant` allows `kind`, `payload`, requires `payload` (`… has no payload`) and a payload of finite-number JSON (`credentials-local: record "<key>" payload in <file> holds a non-finite number`); no kind raises `… has no kind`; any other raises `… has unknown kind <JSON>`. Messages are those of `index.ts:260-345`.
C12. Flat layout (`renderFlatLayoutMigration`, `index.ts:245`): the text parses; its root is a non-empty mapping; no line starts with `%`, `---` or `...`; every key is a string other than `version` that is a valid reference; every value is a non-empty string scalar. The migrated text is `version: 1\nrefs:\n`, then every line of the original with two spaces in front (empty lines unchanged), then a newline when the original did not end with one.
C13. Migration runs under the file lock (30000 ms): read again, recompute, and when it still applies write atomically with mode `0600` and log at `info` `credentials-local: migrated <file> to the version 1 layout; values are unchanged`.
C14. All mutations and reloads run on one serial queue. A write (`index.ts:759`, `:692`): raise `credentials-local is disposed: cannot <set or unset> "<ref>"` (`cannot modify "<key>"`, `cannot delete "<key>"`) when closed, and `credentials-local was disposed before the queued "<ref>" <set or unset> ran` (`… "<key>" modify ran`, `… "<key>" delete ran`) when closed by the time the job runs; create the parent directory with mode `0700`; take the file lock, waiting up to 30000 ms; reconcile from disk (C15); compute; render (C20); write atomically with mode `0600`; update the cached text and snapshot; notify. `set` with an empty value raises `credentials-local: an empty value cannot be stored for "<ref>"; use unset` before queueing. `unset` of an absent reference and `delete` of an absent record write nothing. In `modify`, `mutate` runs while the lock is held and sees the on-disk record; `#f` returns the current record and writes nothing; a grant payload is checked as in C11a (without the file name); an API-key record with an empty `key` raises `exn:fail:contract` `credentials-local: record "<key>" has an empty key; omit the field instead`, and an empty `env` value `credentials-local: record "<key>" env "<name>" must be a non-empty string`.
C15. Reconcile from disk (`index.ts:871`): repeat the mode check; read the file (absent is "no text"); when the text equals the cached text, or the provider is closed, stop; otherwise parse, log ignored keys, replace both snapshots wholesale, and notify once per reference whose value changed (string inequality, including added and removed) and once per record that changed (`deep-equal?`, so key order is ignored). A provider's own writes are no-ops here because the cached text equals the file.
C16. Ignored keys are logged at `warning`: ``credentials-local: ignoring unknown top-level keys <names as JSON strings joined by ", "> in <file>; only `refs` and `records` entries resolve``. They stay on disk and resolve nothing.
C17. Lock and atomic write are `with-file-lock` and `write-file-atomic` of `dsh-util` (`packages/util/atomic-write/src/index.ts`): the lock file is created exclusively with `<pid>\n`; retries start at 20 ms and double to 200 ms; a lock whose recorded process no longer exists is taken over through the claim file `<lock>.takeover-<first 16 hex of SHA-256 of the record>`; on timeout `atomic-write: timed out waiting for the writer lock at <lock>`. The atomic write creates `<file>.<12 hex>.tmp` exclusively and renames it.
C18. Watcher, when `watch`: wait on `filesystem-change-evt` of the file's directory; after a change, poll the file's size and modification time every `max(1, min(debounceMs, 10))` ms until they are unchanged for `debounceMs`, then enqueue a refresh; enqueue one refresh when the watcher starts. A refresh is C15 with failures logged at `warning` `credentials-local: reload failed at <file>; keeping the last good document` and the last good snapshot kept. Disposal: refuse new writes, stop the watcher, drain the queue.
C20. Rendering an edit. The editor works on the cached text as lines and changes only the lines of the entry it edits; everything else, comments included, is kept byte for byte. A section is a top-level line `refs:` or `records:` (optionally followed by a comment) and the more-indented lines after it; its indentation is that of its first entry (2 spaces for a new section). An entry is a line `<indent><key>:` and its span: the following lines that are more indented, with the blank and comment lines between them.
C21. No text: the result is `version: 1\n`, then the section with the one entry.
C22. `version`: when the document has no top-level `version` line, append `version: 1` after the existing text (adding a newline first when it does not end with one).
C23. Set a reference that exists: replace the scalar on the entry's line, keeping the key text, the quoting style of the old value (single-quoted values stay single-quoted with `'` doubled; double-quoted stay double-quoted) and any trailing comment. Set a new reference: append `<indent><name>: <scalar>` after the last line of the section's last entry; when the section does not exist, append `refs:` and the entry at the end of the document.
C24. Scalar text for a new value: what `yaml->string` of `cordis-yaml` writes for that string with `#:line-width #f` when that is one line (plain, single-quoted or double-quoted by its rules); otherwise the JSON string of the value (`jvalue->string`), which is a valid double-quoted scalar.
C25. Unset or delete: remove the entry's span and the comment lines directly above it (up to a blank line or the section line). A section left without entries keeps its header line.
C26. Records are written in block style under the key: `kind`, then `key` and `env` or `payload`, nested mappings and lists indented by two more spaces per level, an empty mapping as `{}`, an empty list as `[]`, numbers, booleans and null plain, strings by C24. Replacing a record replaces its whole span below the key line; the key line and the comments above it stay.
C27. Fallback. When the cached text is not in the editable layout (a section written as a flow mapping, the target entry's value a block scalar or spanning several lines for a reference, anchors or aliases in a section, tab indentation), the editor re-renders the whole document from the parsed data with `yaml->string` (`version`, `refs`, `records`, then the ignored keys with their values), applies the edit to the data, and logs at `warning` `credentials-local: <file> uses a layout the editor cannot preserve; comments were dropped`. After every edit the result must parse (C11) to the intended data; if it does not, the write is abandoned with `exn:fail` `credentials-local: refusing to write an invalid document for <file>` and nothing changes.
C28. Differences from dsh in this group: the reader resolves plain scalars by js-yaml's JSON schema where dsh uses the YAML 1.2 core schema of the `yaml` package (they differ for `0b…` integers and a few float spellings; such a value under `refs` is "not a string" here); error codes other than the four of C11 are folded into `UNEXPECTED_TOKEN`; the editor never reflows untouched lines, where the `yaml` package may normalise whitespace; C25's comment rule is fixed here.

### A. Authorization (`packages/credentials/authorization/src/index.ts`)

A1. `authorization-begin` (`:283`), in order: no flow raises `NO_FLOW` `no authorization flow is registered for "<key>"`; the method defaults to the flow's first, and one the flow does not offer raises `UNKNOWN_METHOD` `authorization flow for "<key>" offers no method "<method>"`; a running attempt raises `ALREADY_IN_FLIGHT` `an authorization attempt for "<key>" is already running`; a cancel event already ready returns `{status: "cancelled"}` without running or settling. Otherwise claim the key with a fresh cancel source, run the attempt (A2), and in every case release the key and then dispatch `authorization/settled` with the outcome's status, or `failed` when the attempt raised.
A2. Attempt (`:361`). The caller's cancel event, `authorization-cancel!` and flow disposal fire the attempt's source unless the attempt is committing. Listen to `credentials/record-updated` for the key for the duration. Run the flow's `run` in a task with a session whose `cancel` is the source's event. Wait for the first of the task and the source: when the source wins, return `cancelled` at once and let the task finish on its own (a later failure is logged at `debug`). When the task raised: `cancelled` if the source fired or a prompt was declined (A4); otherwise the exception propagates.
A3. `commit!`: raise the cancel reason when the source fired; when this attempt is no longer the running one for the key raise code `CANCELLED` `authorization attempt is no longer active`; set `committing`; write with `(credentials-modify-record! credentials key (lambda (_) record))`.
A4. `notify!` calls the interaction's and logs a failure at `warning` `authorization: the interaction surface failed to render a notice`. `prompt` calls the interaction's; an `exn:fail:authorization:declined` marks the attempt declined and is re-raised.
A5. After a normal return of the flow: no `credentials/record-updated` for the key seen during the attempt raises `NOT_COMMITTED` `authorization flow for "<key>" resolved without committing a credential record in this attempt`; a record that is no longer configured raises `NOT_COMMITTED` `authorization flow for "<key>" deleted its credential record instead of committing one`; otherwise `{status: "authorized"}`.
A6. The settled dispatch is contained (C3).

### D. DeepSeek account (R12 "DeepSeek account", "DeepSeek account platform protocol"; `packages/credentials/deepseek-account/src`)

D1. Construction: `platformOrigin` and `harnessOrigin` must be HTTPS origins with no credentials, path, query or fragment, or loopback HTTP (`localhost`, `127.0.0.1`, `[::1]`) with `allowLoopbackHttp` (`account: <field> must be an HTTPS origin or explicitly enabled loopback HTTP origin`); `inferenceOrigin` an HTTP(S) origin of the same form (`account: inferenceOrigin must be an HTTP(S) origin without credentials, path, query or fragment`); header dicts must not name `authorization`, `x-dsh-auth-token`, `host`, `content-length`, `transfer-encoding`, `connection` or `content-type`, nor repeat a name ignoring case (`account: requestHeaders contains a reserved or duplicate header`), and must be valid header names and values (`account: requestHeaders contains an invalid header`). Account requests send `requestHeaders` overlaid by `accountRequestHeaders`, with `cookie` values merged by name (`client-metadata.ts:9`).
D2. Body: register the authorization flow `{key: "deepseek-account-platform/default", label: "DeepSeek", methods: [{id: "browser", label: "DeepSeek"}]}` whose `run` is D4; listen to `credentials/record-updated` for that key (invalidate details, publish `credentials-changed`); install D10; register the closing effect (mark closed, cancel the logout lifetime, invalidate details, cancel an attempt that is not committing and wait for it, wait for a removal in flight and for revocations, publish `snapshot`). Then read the stored grant: a record that is not a grant or whose payload is not `{version: 1, token: non-empty string, issuer: URL}` raises `exn:fail:platform-auth` `storage`; a grant whose `issuer` differs from the platform origin is deleted.
D3. `account-start-sign-in!` (`:480`): wait for a removal in flight; the callback origin must be `http://localhost:<port>`, `http://127.0.0.1:<port>` or `http://[::1]:<port>` with an explicit non-zero port and nothing else (`protocol` otherwise); a running attempt (phases `initializing` to `committing`) returns the current state; otherwise wait for the previous attempt, create the attempt with a random UUID id and phase `initializing`, and start `authorization-begin` for the key with an interaction whose prompt raises `protocol`. Settlement: `authorized` sets phase `succeeded` and answers the held callback with `302` to the completion URL; `cancelled` sets `cancelled` and answers `204`; a failure sets `expired` or `failed` with the error code (`protocol` for a foreign exception), logs `[deepseek-account] sign-in failed` with the code, and answers by `index.ts:797-812` (an HTML page for `web`, `204` for `desktop`). All callback answers carry `cache-control: no-store`.
D4. The flow (`run`, `:683`): no `webServer` service raises `protocol`. The verifier and the state are 32 random bytes each in unpadded base64url; the challenge is the unpadded base64url SHA-256 of the verifier text. Register the exact route `/oauth/callback` (D5). `POST <platformOrigin>/auth-api/v0/dsh/auth_init` with `{code_challenge, code_challenge_method: "S256", state, redirect_uri: "<callback origin>/oauth/callback", locale, login_source}`; the result must be `{authorize_url, authorize_id, expires_in}`; the authorize URL must be on the platform origin (or any HTTPS origin with `rewriteBrowserOrigin`, then rewritten onto it), with path `/dsh/authorize`, no credentials and no fragment. The deadline is the smaller of `attemptTimeoutMs` and `expires_in` seconds. Phase `waiting-browser` with `authorizeUrl` and `expiresAt`. On the code: phase `exchanging`; create the device record once (`{kind: "grant", payload: {id: <uuid>}}` under `deepseek-account-platform/device`, reused when present); `POST …/auth_exchange` with `{code, code_verifier, redirect_uri, device_id, device_model: "<os>-<arch>", os_version: "<os> <release>"}`; the result must be `{token, authorized_url, user?}` with the authorized URL checked like the authorize URL against path `/dsh/authorized`, and `login_source` appended to its query; phase `committing`; `commit!` `{kind: "grant", payload: {version: 1, token, issuer: <platformOrigin>}}` (a failure is `storage`). The deadline firing at any point is `expired`. When the attempt ends cancelled or expired after `auth_init`, send `…/auth_cancel` `{authorize_id, code_verifier}` in the background.
D5. Callback handler: a request that is not `GET /oauth/callback` with exactly one `code` and one `state`, or whose state does not equal the expected one (compared in constant time over the UTF-8 bytes), answers `400`; a second or late callback (the attempt is not `waiting-browser`, already has a callback, or is cancelled) answers `410`; otherwise the handler holds the request and returns the response that D3 chooses when the attempt settles.
D6. `account-resolve-token` (`:454`): `#f` when closed or a removal is in flight; `#f` unless the destination's origin equals `inferenceOrigin` and it has no credentials; `#f` without a stored record; a malformed record raises `storage`; a token starting `dsh_mock_` is never released; with the production inference origin `https://api.deepseek.com` a loopback issuer is refused; with any other inference origin the issuer must equal the platform origin.
D7. Rejection (`rejectToken`, `expireCredential`): only when the token still equals the stored grant's and the issuer is the platform origin: cancel a running attempt, delete the record, emit `deepseek-account/session-expired`, clear the attempt, emit `deepseek-account/signed-out`, publish `snapshot`. A 401, or envelope code `40003`, on an authenticated detail request does the same.
D8. Detail reads (`getProfile`, `getBalance`, the notification procedures) capture the current credential lifetime; any credential change replaces it and makes reads in flight return `#f` (the report procedure also answers `#f`). Requests: `GET <platformOrigin>/auth-api/v0/users/current` and `/api/v0/users/get_user_summary`; on `harnessOrigin` `GET /api/v0/users/notifications/list`, `GET /api/v0/users/notifications/content?id=`, `POST /api/v0/users/notifications/events` `{notification_id, type}`; header `x-dsh-auth-token`, the client headers `x-client-bundle-id: ""`, `x-client-platform` (`web`, or `desktop-win` / `desktop-mac` by `desktopPlatform`), `x-client-version`, `x-client-locale` (`zh_CN` when the locale's language is `zh`, else `en_US`), `x-client-timezone-offset`. The envelope is `{code: 0, data: {biz_code: 0, biz_data}}`; the response body is capped at 65536 bytes; redirects are refused. Failures map to codes by `protocol.ts:185-256`: no response `no-response`; 401 on an authenticated request `expired`; another non-2xx `network`; a bad envelope `protocol`. A failed profile read falls back to the last profile cached for the same token.
D9. `account-sign-out!` (`:551`): single-flight; cancel a running attempt; delete the grant locally first; then revoke in the background: `POST /auth-api/v0/users/logout`, up to `logoutMaxRetries` retries with delays `logoutRetryDelayMs × 2^(attempt − 1)`, each request bounded by `requestTimeoutMs`; a remote failure never restores the grant. Emit `signed-out`, publish `snapshot`.
D10. Account tasks (`account-tasks.ts`), under `(ctx-inject ctx '(agents) …)`: on `agent/error` with an `exn:fail:llm` of code `ACCOUNT_SIGN_IN_REQUIRED` emit `deepseek-account/model-sign-in-required`; on `deepseek-account/signed-out`, for every agent of `agents-list` with status `'running` whose session's request context has provider `deepseek-account`, call `(agent-cancel! agent (cause-hook "deepseek-account/signed-out") #:keep-inbox? #t)`.
D11. `account-state`: `{status, attempt, links}` with `status` `credential-stored` exactly when a valid grant record exists (a malformed one raises `storage`), `attempt` the current view or `'null` (also `'null` when signed out and the attempt had succeeded), `links` `{usageUrl: <platformOrigin>/usage, topUpUrl: <platformOrigin>/top_up}`. `account-watch` yields a `snapshot` first, then one update per change with `credentials-changed` taking precedence over a pending `snapshot`; identity changes count only with `#:identity-changes? #t`. `account-watch-expiry` yields once per `session-expired` event.

### S. Settings (R12 "Settings"; `packages/settings/settings/src`)

S1. `volatile-form` (`schema.ts:37`): a node marked volatile gives the plain copy of S2; an object gives an object of the children that yield a form, or `#f` when there is none; anything else gives `#f`. `volatile-path?`: true when the node is volatile, else when the first path element names a field whose rest of the path is volatile.
S2. Plain copy: remove every volatile mark; on a node with role `secret` remove `default` and `required`; on any other node with a default replace it by its secret-redacted value (S4); recurse into fields, inner and members.
S3. `settings-describe` (`index.ts:302`): for each row of `settings-source-rows` whose entry has a schema and an `'active` fiber and whose schema has a form: the revision key is the JSON text of `[fiber uid, schema JSON, raw config or {}]`; `autoGenerate` is the `auto` configured for the entry's fiber, default true; the revision starts at 0 and increases by 1 when the key changed; when the key or `autoGenerate` changed since the last describe, emit `settings/document-updated` with the entry id and the revision. `value` is the form projection (S5) of the fiber's effective config with volatile references replaced by their contents; `base` the projection of `settings-source-resolve-inherited`; `user` the projection of the row's override. With redaction, the three are redacted and `secrets` is that of `value`. Afterwards every known entry that is no longer active and still has a key gets its revision increased by 1, its key cleared, and one event.
S4. `redact-secrets` (`redact.ts:106`): a node with role `secret` records `{path, set: <value present>}` and yields nothing; `object`: keep input keys the schema does not declare, then walk the declared fields in order; `dict`: walk present members with the inner schema; `array`: walk members with index strings; `union` and `intersect`: fold the value through every member; `transform`: walk the inner schema. Positions with the same path merge with `set` the disjunction.
S5. `project-form`: for an object schema and an object value that is not an expression node (`{__jsExpr: string}` alone), the fields of the schema in order whose key is present, each projected; otherwise the value.
S6. Write (`index.ts:378`): the entry is the one of `settings-source-entries` with that id and a schema, else `No configurable plugin entry "<ns>"`; no form raises `Plugin entry "<ns>" has no volatile fields`; for `mutate`, each non-empty path must be volatile, else `Config field "<path joined by ".">" is not volatile`. Inside `settings-source-edit!`: describe again; no descriptor raises `Plugin entry "<ns>" is no longer configurable`; a given expected revision that differs raises `exn:fail:settings-conflict` `settings namespace "<ns>" changed since it was read (expected revision <e>, now <a>)`. `current` is the projection of the raw config, `base` of the inherited config; the next section is `change` of them; every key of it that is not under a volatile path raises the `is not volatile` message; the result is the raw config with every volatile field removed, merged under the next section. After the edit, describe once more.
S7. `settings-update!` merges the patch onto `current`; `settings-replace!` merges the section onto `base`; `settings-mutate!` applies the operations in order: `set` applies S8; `unset` under a list parent applies S8; another `unset` restores the inherited value when `base` has an own value at that path and removes the key otherwise. Merge: jobjects merge recursively, lists and scalars replace. Inputs must be plain JSON: `exn:fail:contract` `Config <path> contains <what>` for a non-finite number, a cycle or a non-JSON value, with paths `$`, `$.key`, `$[i]`.
S8. Path operation on lists (`index.ts:74`): an index must be a canonical non-negative integer at most the length, and equal to the length only for a final `set`, else `exn:fail:contract` `Config array index "<head>" is out of range`; `set` at the length appends; `unset` removes the element. A missing intermediate value starts from the schema node's default, else an empty object. A root that is not an object raises `Config root must be a plain object`.
S9. Lifecycle: `settings-configure!` for a fiber that already has a policy raises `Settings presentation is already configured for this plugin instance`; setting or removing a policy schedules one describe on the next task turn (coalesced), as does `'app-boot/config-reload`; a describe failure there is logged at `error`. Once `settings-source-loaded-evt` is ready, import the legacy document: when `<profile home>/settings.yaml` exists, rename it to `settings.yaml.imported`, read it as a mapping of section name to object, and for each section call `settings-update!` on the entry named by the section, with the renames `ui-developer-tools` to `ui-settings`, `ui-onboarding` to `ui-settings-general`, `shell` to `bash-sandbox`; a failed section is logged at `warning` `settings: section <section> of <file> was not imported into entry <ns>`; then log at `info` `settings: imported <file> into profile <name>`.

### T. Storage (R12 "Storage hub, backends, and domains"; `packages/storage/*/src`)

T1. Hub: `storage-register-backend!` raises `duplicate-backend` `storage backend '<name>' is already registered`; its undo removes the entry only while it still holds that backend. `storage-backend` raises `backend-not-found` `storage backend '<name>' is not registered (registered: <names joined by ", " or none>)`. `storage-mount!` raises `duplicate-mount` `storage form '<form>' is already mounted`; `storage-form` raises `form-not-mounted` `storage form '<form>' is not mounted`.
T2. Backend contract (`storage/src/backend.ts`): one live handle per unit name; values are opaque JSON; the unit does not order writes; a write that returned is durable; calls after `kv-close!` raise `closed`; `kv-delete-records!` is idempotent and one batch; `unknown-state` poisons the unit until it is closed. `run-backend-contract-suite` checks these for any backend.
T3. JSON backend open: a closed backend raises `closed` `json backend is closed`; a unit or table name that does not match `unit-name-rx` raises `malformed-medium` `invalid unit name '<name>'` or `invalid table name '<table>' in unit '<name>'`; a unit that is open or opening raises `unit '<name>' is already open; a unit has exactly one live handle`; create the root with mode `0700`.
T4. Single layout (`single-unit.ts`, `format.ts`): a missing file is the empty unit (every table empty, global `'null`) and is created on the first write. Parsing: not JSON: `malformed-medium` `unit '<name>': file is not valid JSON`; not an object: `… file is not a JSON object`; `unit.name` not the descriptor's or `unit.version` not a number: `… missing or foreign unit header`; a version that is neither the descriptor's nor a compatible one: `version-mismatch` `unit '<name>': stored version <v> is not accepted by version <d>`; `tables` not an object: `… tables is not an object`; a declared table that is present but not an object: `… table '<t>' is not an object`. Memory is authoritative: each write changes memory, publishes the whole file with the descriptor's version, and restores memory if the publish fails. Undeclared tables are dropped at the next publish. Errors for an undeclared table or a missing global slot: `unit '<name>' does not declare table '<t>'`, `unit '<name>' does not declare a global slot`; after close: `closed` `unit '<name>' is closed`.
T5. Atomic publish (`atomic.ts`): create `.<uuid>.tmp` in the same directory exclusively with mode `0600`, write, `fsync` the file (through the FFI, recon 20 "SQLite and other library checks"), rename over the target, `fsync` the directory; on failure remove the temporary file and re-raise.
T6. Per-record layout (`per-record-unit.ts`): no in-memory state; `kv-load-all` reads the tree each time; a document that is missing, malformed or stamped with a version outside the accepted set reads as absent; files not ending in `.json` and keys outside `^[a-zA-Z0-9_-]+$` are ignored. Writes use T5 on `<table>/<key>.json` or `global.json`. A key that is not path-safe raises `unit '<unit>': per-record key '<key>' is not path-safe (must match /^[a-zA-Z0-9_-]+$/)`. Batch delete: rename each present document to `.deleting`, `fsync` the directory, then unlink them; a failure before the unlinks restores the renames and re-raises, and a failed restore sets and raises `unknown-state` `unit '<unit>' could not restore a failed batch delete; its state is unknown`. `kv-backup-record!` renames the document to `<key>.json.bak.<YYYYMMDDHHmm>` in local time and returns that path.
T7. Legacy bootstrap: when the unit directory has neither a declared table directory nor `global.json`, and `<root>/<unit>.json` exists, parses, names this unit and carries an accepted version, each record of its declared tables is written as a per-record document; the legacy file is left unchanged and its global is not migrated.
T8. SQLite open (`schema.ts`): for a file path create the directory `0700` and the file exclusively with `0600` when absent; connect; `PRAGMA foreign_keys = ON`; `PRAGMA journal_mode = <upper-case mode>`; a `user_version` other than 0 or 1 raises `version-mismatch` `storage database at "<path>" has schema version <v>, incompatible with this build (1)`; create the two fixed tables; stamp `user_version = 1` when it was 0.
T9. SQLite unit (`index.ts`, `unit.ts`): errors `closed` `sqlite storage backend is closed`; `kv unit name '<name>' violates /^[a-z][a-z0-9_]*$/`; `kv table name '<t>' in unit '<name>' violates …`; `kv unit '<name>' is already open (double-open is a caller bug)`. A new unit is inserted into `units`; a stored version that is neither current nor compatible raises `version-mismatch` `kv unit '<name>' is stamped version <v> on the medium, incompatible with descriptor version <d>`. Statements: `INSERT INTO "<t>" (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value`, `DELETE FROM "<t>" WHERE key = ?`, `SELECT key, value FROM "<t>"`, and the same two forms on `unit_globals`. Single statements run alone; a batch delete, and every write while the unit still carries an older compatible version, runs in `BEGIN IMMEDIATE … COMMIT` and, when rows changed and the version is old, stamps `units.version`. A failed rollback raises `unknown-state` `kv unit '<name>' write and rollback failed; the backend is unusable and must be closed and reopened` and poisons the whole backend. Unparsable stored JSON raises `malformed-medium` `kv unit '<name>' holds unparsable JSON at <table '<t>' key '<k>' or global slot>`. After close: `closed` `kv unit '<name>' is closed`.
T10. `make-domain-spec` (`spec.ts:107`) rejects, in order: `domain name '<name>' must match /^[a-z][a-z0-9_]*$/`; `domain '<name>' version must be a non-negative integer, got <v>`; `domain '<name>' compatibleVersions entries must be non-negative integers below version <v>, got <c>`; `domain '<name>' layout must be 'single' or 'per-record', got <l>`; `domain '<name>' invalidRecords must be 'backup-and-skip' when present, got <p>`; `domain '<name>' table name '<t>' must match /^[a-z][a-z0-9_]*$/`; a global validator that accepts `'null`: `domain '<name>' global schema must not accept null: null is the medium's "never written" sentinel, so a stored null could not round-trip`.
T11. `domain-open` (`storage-domain/src/index.ts:103`): a reserved name raises `already-open` `domain '<name>' is already open`; the backend is `routes[name]` or the default; a backend without the kv facet raises `facet-unsupported` `backend '<b>' routed for domain '<name>' has no kv facet`; open the unit; load; validate every record of every declared table with its validator, a failure raising `invalid-record` `domain '<name>': stored record '<key>' in table '<table>' does not match its schema` with detail `{table, key}`, unless the spec says `backup-and-skip` and the unit can back up, in which case move the document aside, log at `error` `domain '<name>': stored record '<key>' in table '<table>' failed schema validation; moved to '<path>' and treated as absent. Cause: <cause>`, and skip it; a stored global of `'null` serves `initial`, any other is validated (`domain '<name>': stored global does not match its schema`, detail `{table: "", key: ""}`). Any failure closes the unit and frees the name.
T12. Write chain (`domain.ts:283`): one serial queue per domain. Each job waits for backend durability first, then updates memory, then emits `domain/changed`. A failed backend write leaves memory unchanged. An `unknown-state` failure quarantines the domain: later jobs, already queued ones included, and reads raise it. `kv-table-delete!` decides existence at its slot in the queue; `kv-table-delete-many!` removes repeats, deletes the present keys in one backend batch, updates memory for the whole batch and then emits one event per key; `kv-table-update!` raises `missing-key` `domain '<d>' table '<t>' has no record '<key>' to update` for an absent key and otherwise stores `(proc current)`. `domain-close!` is single-flight: new writes raise `closed` `domain '<name>' is closed` at once; queued ones drain and still emit; the unit is closed; then reads raise `closed` and the name is free. `domain-table` and `domain-global-ref` on an undeclared table or global raise `domain '<name>' declares no table '<t>'` and `domain '<name>' declares no global`.

### W. Workspace registry (R12 "Workspace registry"; `packages/workspace/workspace/src`)

W1. Init (`index.ts:215`): open the domain; complete a pending mutation (W9); validate (W10); when not initialized, list the stored session headers, index them (W5) and bootstrap (W7); otherwise, when there are workspaces, index the stored headers; index the headers of live sessions; validate again; build the entities; log filtered candidates at `warning`. Procedures called before init finished raise `workspace registry is not started yet`.
W2. `realpath-normalize`: a path that is not absolute raises `exn:fail:contract` `Workspace path is not fully qualified: '<path>'`; otherwise the result is the resolved path with symbolic links followed (`resolve-path` and `normalize-path` until a fixed point, as `fs.realpath`); a missing path raises the file system's error.
W3. `workspace-registry-create!` (`:254`, `:532`): canonicalise; not a directory raises `cannot create a workspace at '<canonical>': path is not a directory`; an existing workspace for that path is returned unchanged; otherwise three writes: the state with `pendingMutation {operation: "create", workspaceId}`; the record `{path, title, sessionIds: [], createdAt, updatedAt}` with the title given or the final path segment (the root spelling for a root) and both instants now; the state with the id prepended to `workspaceIds`, `initialized: true` and the marker cleared. A failure rolls the earlier writes back; a failed rollback raises `exn:fail:workspace:aggregate`, holding both failures, with the messages of `index.ts:566-600` (`workspace '<id>' record write and pending-marker rollback both failed`, `workspace '<id>' order write and record rollback both failed; the pending marker remains recoverable`, `workspace '<id>' order write and pending-marker rollback both failed`). The delete path raises the same struct with `workspace '<id>' record deletion and registry-order rollback both failed` (`index.ts:633`).
W4. `workspace-registry-delete!` (`:607`): an unknown id returns `#f`; write the order without the id together with `pendingMutation {operation: "delete", workspaceId}`; delete the record; clear the marker (a failure here is logged at `warning` `workspace '<id>' was deleted but its pending marker could not be cleared: <error>`); return `#t`. `workspace-registry-insert-before!`: an unknown id or anchor raises the order error `cannot reorder unknown workspace '<id>'`; the id moves before the anchor, or to the end without one; the new order is written and returned.
W5. Header index (`:838`): for each header with a `cwd`, canonicalise it and require a directory; success records the canonical path for the session; a missing path on an absolute `cwd` marks the session as missing-path; any other failure marks it invalid.
W6. Membership: a session id in a record counts when its canonical cwd equals the workspace path or it is in the missing-path set. `workspace-session-ids` is that filter over the stored list. Every accepted entity mutation also removes non-matching candidates durably, never missing-path ones.
W7. Bootstrap (`:672`): group headers by canonical cwd; in a group order newest `createdAt` first, ties by id; order groups by their newest session, ties by path. A new workspace takes its group's unaccounted sessions, title the final path segment, `createdAt` and `updatedAt` the newest session's instant. An existing workspace gets historical ids first, then its remaining ids. Final order: by group rank or own `createdAt`, descending; ties by prior order, then id. Then write `initialized: true`.
W8. Entity mutation (`entity.ts:203`) runs inside `kv-table-update!`; a function that returns the same record while pruning removes nothing aborts the slot without a write or an event; otherwise `updatedAt` is stamped. `workspace-attach-session!` for a new id validates the stored header first: no `cwd`, a `cwd` that does not resolve, is not a directory, or resolves elsewhere raise the four messages of `entity.ts:118-143`; then prepends the id. `workspace-insert-session-before!` raises the move error with the messages of `entity.ts:155-162` for an unaccounted session or anchor. `workspace-status` is `'missing-dir` when the path is no longer a directory.
W9. Recovery (`:658`), also at the start of every queued operation: a pending id still in the order raises `workspace domain is inconsistent: pending <operation> workspace '<id>' is still present in registry order`; otherwise delete that record and clear the marker.
W10. `validate-stored-state` (`:766`) fails loud with the messages of `index.ts:771-800`: an id repeated in the order, an order entry without a record, an orphan record when initialized, two records with one path, a session in two records.
W11. `workspace-registry-initialize-default!` (`:274`): returns the remembered default workspace when `defaultWorkspaceId` is set (`#f` when it was deleted); requires the `sessions` service (`default Workspace initialization requires the Session store`); eligible only with no workspaces, no archived sessions, no live sessions and no stored sessions, else `#f`; the resolved directory must be absolute, is created recursively and canonicalised; history is checked again; create with the title the final segment of the requested path; record `defaultWorkspaceId`.
W12. Archive (`:381`): nothing when already archived; a session known neither live nor stored raises the unknown-session error `cannot archive session '<id>': live sessions and session persistence hold no such session`; without `stop-activity?`, a non-empty activity result raises the active-session error `cannot archive session '<id>': the session is active (<kinds joined by ", ">)`; one write appends the id to `archivedSessionIds` and removes it from `pinnedSessionIds`; with `stop-activity?` dispatch `workspace/session-stop`, logging each failure at `warning` `workspace: stopping session '<id>' for archive failed: <failure>`; then `workspace/session-archived`. Unarchive: dispatch `workspace/session-unarchiving`, then remove the id. Pin (`:450`): an archived session raises `cannot pin session '<id>': the session is archived`; an unknown one the unknown-session error with `pin`; the id is prepended once. Unpin removes it.

### I. Anonymous user id (`packages/identity/anonymous-user-id/src/index.ts`)

I1. `(get-or-create-anonymous-user-id #:home [home #f] #:random-uuid [gen #f]) -> string?`. The file is `<Harness home>/.anonymous-user-id`. Memoised per resolved file path in a table held by the module. Read the file, trim, and accept a value matching the 8-4-4-4-12 hex pattern in either case. Otherwise generate a version-4 UUID, create the directory, and write `<uuid>\n` with exclusive create; on any write failure read again and adopt a valid value (a concurrent winner); if still invalid, overwrite best-effort and use the generated id for this run.

### O. Telemetry (R12 "OTLP", "OTel session-log processor"; `packages/telemetry/otel/src`)

O1. OTLP/HTTP JSON request body, keys in this order: `{resourceLogs: [{resource: {attributes, droppedAttributesCount: 0}, scopeLogs: [{scope: {name, version?}, logRecords}]}]}`. A log record: `{timeUnixNano, observedTimeUnixNano, severityNumber, severityText, body: {stringValue}, eventName, attributes, droppedAttributesCount: 0}`. Times are the millisecond value times 1000000 as a decimal string. Attributes are a list of `{key, value}` in input order; a value is `{stringValue}`, `{boolValue}`, `{intValue}` for an integer, `{doubleValue}` for another number, `{arrayValue: {values}}` for a list, `{kvlistValue: {values: [{key, value}…]}}` for an object, `{}` for null. The severity default is 9 with text `INFO`; the text of another number is its OpenTelemetry name.
O2. Shared exporter settings: `timeoutMillis` from the options, else `OTEL_EXPORTER_OTLP_LOGS_TIMEOUT`, else `OTEL_EXPORTER_OTLP_TIMEOUT`, else 10000; `compression` from the options, else `OTEL_EXPORTER_OTLP_LOGS_COMPRESSION`, else `OTEL_EXPORTER_OTLP_COMPRESSION` (`gzip` or `none`), else `none`. The URL and headers come from the options only. Requests are `POST <url>` with `Content-Type: application/json`, the option headers, `Content-Encoding: gzip` and a gzip body when compressing, `User-Agent` when given; redirects are refused; a status of 300 or more is a failure.
O3. Session-log reporter (`session-log.ts`). Limits at creation: `maxRequestBytes` an integer from 1 to 4000000, default 4000000 (`session log maxRequestBytes must be an integer between 1 and 4000000`); each processor setting a positive integer at most 2147483647 (`session log processor.<key> must be a positive integer no greater than 2147483647`); `maxExportBatchSize` at most `maxQueueSize` (`session log maxExportBatchSize must not exceed maxQueueSize`). Defaults: queue 2048, batch 512, delay 1000 ms, export timeout 30000 ms.
O4. `session-log-report!`: the record is `eventName` and body `session-log`, both times the event's `time`, attributes the record's attributes followed by `sessionId` and `content` (the event as JSON text). Drop when stopped. A full queue reports `Session log queue is full; record rejected`. Measure the UTF-8 size of the request that would carry this record alone; a serialization failure reports `Session log serialization failed; record rejected`; a size above the limit reports `Session log record rejected; content was not truncated` with the error `Session log record exceeds maxRequestBytes: <bytes> > <limit>`. Enqueue. With no export active: flush at once when the queue holds `maxExportBatchSize` records or the queued bytes reach the limit; otherwise arm one delay timer.
O5. Drain: one request in flight; take records from the head while the count is below the batch size and the bytes fit the limit; export; a watchdog at `exportTimeoutMillis` only reports `Session log request exceeded exportTimeoutMillis; waiting for transport settlement`; a failure reports `Session log export failed` with the error; repeat until the queue is empty or the channel is stopped. `session-log-stop-pending!` marks stopped and clears the queue and the timer. `session-log-shutdown!` flushes and waits. The transport retries a 429, 502, 503 or 504 up to 5 attempts, with delays starting at 1000 ms, multiplied by 1.5, capped at 5000 ms, jittered by 20 percent, honouring `Retry-After`, all within `timeoutMillis`.
O6. Event reporter (`event-log.ts`, `event-transport.ts`): a batch processor with the consumer's `processor` settings (defaults: queue 2048, batch 512, delay 5000 ms, export timeout 30000 ms; a full queue drops the record); `event-reporter-emit!` adds `observedTimestamp` now and the severity defaults; an export failure reports `Product telemetry export failed`. Its transport refuses redirects, retries a 429, 502, 503 or 504 up to 5 times with delays `min(5000, 1000 × 2^(n − 1))` ms honouring `Retry-After`, caps the response at 4 MiB, raises `OTLP collector returned HTTP <status>` for a status of 300 or more, and is cancelled by the shutdown's cancel event. `event-reporter-shutdown!` flushes, then closes.

### F. Office documents (R12 `ctx.officeKit`, tools catalog; `packages/document/*/src`)

F1. The service is provided even when no engine can be created. An operation that needs a new engine then raises code `unavailable`, and each distinct failure is logged once (`office-kit/src/index.ts:335-360`).
F2. Engine: `office-kit-host.mjs` is started with `node` as a child process; its working directory must contain `node_modules/@deepseek-ai/libreoffice-kit` (the directory is `<Harness home>/office-kit/engine` unless the kit is found beside the harness). Protocol: one JSON object per line on stdin and stdout. Requests `{id, op, args}` with `op` one of `create` (`args` the converter options of `index.ts:379`), `render`, `convert`, `recalculate`, `renderImages` (`args` the kit's request objects with `inputPath` and `outputPath`), `cancel` (`args: {id}`), `close`; replies `{id, ok: true, result}` or `{id, ok: false, error: {name, code?, message}}`. The sidecar imports the kit, calls `createConverter`, and maps each `op` onto the converter method of the same name with an `AbortSignal` that `cancel` fires. Missing `node`: `unavailable` `LibreOffice Kit is not installed.` with the cause `node is not available`.
F3. Queue, cache, output store and limits follow `office-kit/src/{queue,outputs,output,identity}.ts` with the config defaults of Plugins: at most `maxConcurrentConversions` engines; queued calls stay cancellable; `timeoutMs` per conversion after an engine is acquired; outputs under `outputDirectory` kept for `outputRetentionMs` within `maxOutputStoreBytes`; a changed source version raises `source-changed`.
F4. Activation of the tools (`tool-office/src/index.ts:143-160`): an agent is marked once a skill named in `activationSkills` loaded successfully for it (seen through `tools/result`), or when its session's latest request header already lists one of the three tools (seen through `session/event`); `agent/disposed` forgets the mark. The three tools are registered with `#:when` over that mark.
F5. `office_render` needs an `attachments` store and a model route that declares image input; the request limits are the smaller of the config and the model's limits; an image above the model's byte limit raises `cannot render "<path>": an image exceeds the <n>-byte image limit; select a smaller range or a lower dpi`. `office_convert` and `office_recalculate` return the path of a temporary output file.
F6. Every argument check, result text and hint is copied from `tool-office/src/formats.ts`, `content.ts` and `index.ts:216-400` with a `; source:` comment; this contract does not restate them.

### R. Provider registries (`packages/{computer-use,browser-use}/*/src/index.ts`)

R1. `computer-use-register!`: when a provider is registered, raise `computer use provider "<current>" is already registered`, even for the same name; otherwise one effect sets the name and its inverse clears it. `browser-use-register!` is the same with `browser use provider "<current>" is already registered`.

## Racket design notes

- **Seams are generics; the service value adapts.** `gen:credential-provider`, `gen:storage-backend`, `gen:kv-unit` and `gen:office-engine` are the provider sides. `make-credentials-service` wraps any provider so that the mounted value also satisfies the narrower `gen:credential-port` that `dsh-llm` owns; the account and settings values implement `gen:account-port` and `gen:settings-port` directly.
- **Consumer-owned ports** for `webServer`, `configEditor`, `profileContext` and `sessionPersistence`, each in the module of the unit that needs it, because their providers are built in the same or a later wave.
- **A line editor for the credentials file.** A parse-and-dump would lose comments; a comment-preserving YAML tree is a library this port does not have. The editor touches only the edited entry and falls back, loudly, to a full re-render for layouts it cannot edit (C27). It also re-parses every result before writing.
- **Validators are procedures.** A domain record validator is any one-argument procedure that returns the stored form or raises; a `cordis-schema` schema is such a procedure, which removes the need for a second schema library.
- **Serial queues.** The credential queue, each domain's write chain and the registry queue are one private queue type whose jobs are tasks; "durability, then memory, then event" is the body of one job.
- **OTLP written directly.** The payload is a jobject built by `logs-request->jvalue`; batching is a queue and one drain task per channel. Byte counts are those of this serializer, so a record close to the limit may be admitted or rejected differently from dsh by a few bytes.
- **SQLite calls are not wrapped in `blocking`.** They are short synchronous library calls; wrapping each would cost a thread hand-off per statement.
- **The anonymous user id memo is module-level**, as in dsh, keyed by file path; it holds strings only.
- **No macro is introduced.** Declarations use `define-tool`, `define-event`, `define-service`, `define-plugin`, `define-jrecord` and `define-config`.
- **Racket-only additions**, for the coordinator's ADR list: `make-memory-credential-provider`, `make-memory-storage-backend` and `run-backend-contract-suite` (test support shipped with the package); the ports named above; the sidecar `office-kit-host.mjs` and its line protocol; the fallback and the re-parse check of rule C27. No configuration key is added.

## Work units

| Unit | Modules | Depends on |
|---|---|---|
| A: credentials and account | `credentials`, `credentials/document`, `credentials/local`, `credentials/private/yaml-edit`, `authorization`, `deepseek-account/*`, `anonymous-user-id`, `private/serial`, `private/contained`, plugins `credentials-local`, `authorization`, `deepseek-account`, their tests | `cordis-yaml`, `dsh-util`, `dsh-llm/ports`, `dsh-llm/http`, `dsh-agent` |
| B: storage and workspace | `storage`, `storage/json`, `storage/sqlite`, `storage/memory`, `storage/domain`, `storage/contract-suite`, `storage/private/atomic`, `workspace/*`, plugins `storage`, `storage-json`, `storage-sqlite`, `storage-domain`, `workspace`, their tests | `db-lib`, `dsh-session`, `private/serial` |
| C: settings, telemetry, documents, registries | `settings/*`, `otel`, `otel/otlp`, `office-kit`, `tool-office`, `computer-use`, `browser-use`, `ports`, the remaining plugins, `plugins`, `main`, their tests | `cordis-schema`, `dsh-llm/ports`, `dsh-llm/http`, `dsh-tools`, `dsh-agent` |

The units do not call each other. The only shared code is `private/serial.rkt` and `private/contained.rkt`, which unit A delivers first: `(make-serial-queue) -> serial-queue?`, `(serial-enqueue! q thunk) -> task?` (jobs run one at a time in order, each as its own task; a failed job does not stop the queue), `(serial-idle-evt q) -> evt?`, and `(fan-out-contained ctx event-name args on-failure) -> void?` implementing rule C3. Unit C assembles `plugin-table` and `main` when A and B export their modules. Inside unit C the Office modules are last and may be delivered after the gate if the sidecar cannot be exercised on the build machine.

## Tests

Tests live in `racket/dsh-platform/tests/`. Each test file works in a temporary directory it creates and removes, with the Harness home pointed there; no test touches the real home.

| Racket test file | Mirrors | Pins |
|---|---|---|
| `credentials-test.rkt` | `credentials/tests/credentials.spec.ts`, `memory.ts` | grammars, the seam procedures against the memory provider, contained events, the `gen:credential-port` view |
| `credentials-document-test.rkt` | `credentials-local/tests/records.spec.ts`, `migration.spec.ts`, `review-fixes.spec.ts` | C4, C11 to C13, every parse message, masking |
| `credentials-edit-test.rkt` | `credentials-local/tests/local.spec.ts` (comment preservation) | C20 to C27: comments and untouched lines kept byte for byte, quoting, record blocks, the fallback and its warning |
| `credentials-local-test.rkt` | `local.spec.ts`, `watcher.spec.ts`, `drain.spec.ts` | C2, C10, C14 to C18: precedence, mode check, lock against a second Racket process, external-edit events, drain on dispose |
| `authorization-test.rkt` | `authorization/tests/authorization.spec.ts` | A1 to A6 |
| `deepseek-account-test.rkt` | `deepseek-account/tests/*.spec.ts`, `expected/web-exchange-failure.txt` | D1 to D11 against a local platform server and a stub web-server port: PKCE values, callback statuses, expiry, token release rules, sign-out retries |
| `settings-test.rkt` | `settings/tests/schema.spec.ts`, `redact.spec.ts`, `configuration.spec.ts`, `configuration-inheritance.spec.ts`, `editor-failures.spec.ts` | S1 to S9 with an in-memory settings source |
| `storage-test.rkt` | `storage/tests/contract.ts` | T1, T2; the contract suite against the memory backend |
| `storage-json-test.rkt` | `storage-json/tests/json-backend.spec.ts`, `per-record-batch.spec.ts` | T3 to T7; the single-layout file compared byte for byte with a fixture written by dsh; rollback on a failed publish; batch-delete restore |
| `storage-sqlite-test.rkt` | `storage-sqlite/tests/sqlite-backend.spec.ts` | T8, T9; the schema read back from `sqlite_master`; `user_version`; version stamping |
| `storage-domain-test.rkt` | `storage-domain/tests/domain.spec.ts` | T10 to T12: event order, quarantine, close draining |
| `workspace-test.rkt` | `workspace/tests/workspace.spec.ts` | W1 to W12: bootstrap ordering, create and delete recovery, membership filtering, archive and pin rules |
| `anonymous-user-id-test.rkt` | `identity/anonymous-user-id/tests/anonymous-user-id.spec.ts` | I1 |
| `otel-test.rkt` | `telemetry/otel/tests/session-log.spec.ts`, `event-log.spec.ts` | O1 to O6 against a local collector: payload layout, byte and count batching, record rejection, retry statuses |
| `office-test.rkt` | `document/tool-office/tests/*.spec.ts` (argument and activation cases) | F1, F4, F6 with a scripted `gen:office-engine`; the sidecar test runs only when `node` and the kit are present |
| `registries-test.rkt` | `computer-use/tests`, `browser-use/tests` | R1 |
| `plugins-test.rkt` | config cases of each package | every config default and load-time message; each registration disappears when its fiber is disposed |

Fixtures: a credentials file with comments, blank lines and quoted values; a single-layout `workspace.json` and a per-record unit directory written by dsh at the pinned commit (copied under `tests/data/`); a stub `sessions` and session catalog. Recorded sessions under `snapshots/session/` that exercise this package: `headless-credentials`, `web-search-account-billing` and `web-search-api-key-billing` (credentials and account through the web providers), `mcp-template-error` (credential references), `office-render-tools`, `office-render-tools-ptc`, `office-progressive-native`, `office-progressive-ptc`, `office-skills`, `office-skills-no-renderer`, `office-authoring-checker`, `computer-use-cua-driver-mcp`, `browser-use-playwright-mcp`, `browser-use-chrome-devtools-mcp`. Whole-fixture replay belongs to `dsh-boot`'s gate.

Acceptance gate: `raco test racket/dsh-platform` passes with no network and no Node; every numbered rule has a test that names it; `run-backend-contract-suite` passes for the JSON backend in both layouts, the SQLite backend on a file and in memory, and the memory backend; a `.credentials.yaml` written by this package is accepted by dsh's parser rules (C11 applied to the output) and a JSON storage file written by dsh loads unchanged and is rewritten byte for byte when nothing changed.

## Open questions

1. **`dsh-util` names.** Assumed: `(harness-home) -> path?`; `(launch-environment-entry ctx name #:sources [sources '(process project-env user-env)]) -> (or/c #f launch-entry?)` with `launch-entry-value` and `launch-entry-source`; `(with-file-lock path thunk #:wait-ms [ms 2000] #:cancel [cancel #f])`; `(write-file-atomic path content #:mode mode #:dir-mode [dir-mode #f])`; a UUID generator; `exn:fail:harness` with a name and a code and a way to make substructs. Default: use whatever `dsh-util` exports under those meanings; if layered lookup is missing, this package reads the three layers itself from the launch environment snapshot.
2. **The settings source.** `dsh-boot` owns `configEditor`. Default: its service value implements `gen:settings-source-port` and `gen:config-editor-port` of `dsh-agent/ports`; until it exists, settings is tested against the in-memory source of `settings-test.rkt` and the plugin stays unmounted (the base bundle disables it without a profile context, as in dsh).
3. **The session catalog.** Default: the `sessionPersistence` value of `dsh-session-store` implements `gen:session-catalog-port`.
4. **The web-server port.** Default: `dsh-web` implements `gen:web-server-port` and runs each handler through `call-in-kernel`, so a handler may wait for the attempt to settle before it returns its response, which is how D5 holds the browser's request open.
5. **Zod-specific validation.** dsh validates grants and domain records with Zod. Default: hand-written validators that accept exactly the fields listed under Data and keep unknown keys out, as `z.object` strips them.
6. **Where the Office engine is installed.** Default: `<Harness home>/office-kit/engine`, populated by the user with `npm install @deepseek-ai/libreoffice-kit@0.2.3`; the harness never runs `npm`.
7. **OTLP byte counts.** Default: this port's serializer defines the measured size (design note); if exact parity with the SDK is wanted, capture requests from dsh and adjust key order in `logs-request->jvalue`.
8. **Hoisting the anonymous user id.** Default: `dsh-llm` keeps its private copy in wave 3; in wave 5 the coordinator points it at `dsh-platform/anonymous-user-id` or moves the module into `dsh-util`.
