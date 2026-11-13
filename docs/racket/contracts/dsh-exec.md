# Interface contract: `dsh-exec`

This is the binding interface for `racket/dsh-exec/`. It covers the subprocess Service Definition and its local provider (process groups, tree kill, bounded output collection with spill files, pseudo-terminals), the sandbox seam (mode vocabulary, escalation, runner argv for bubblewrap, Landlock and Seatbelt, the policy service), the shell seam (request and spec, the bash executors, the managed `DSH_*` environment), the two `bash` tools, the terminal registry with its bash backend, and the SSH connection with its subprocess and sandbox providers. Sources: [recon 08](../recon/08-exec-world.md) (cited as R8 with its section), [recon 20](../recon/20-racket-mechanisms.md) (cited as R20), and `packages/{subprocess,sandbox,shell,terminal,ssh}/*/src` at commit `e8f7b93a3`. When this document and the TypeScript disagree about behaviour, the TypeScript is right and this document gets fixed. When they disagree about names and argument order of the Racket surface, this document is right. Read [dsh-session.md](dsh-session.md), [dsh-llm.md](dsh-llm.md), [dsh-tools.md](dsh-tools.md) and [dsh-agent.md](dsh-agent.md) first; this contract uses their vocabulary without repeating it (`absent`, jobjects, `define-session-event`, cancel events of `dsh-llm/cancel`, `make-tool`, `tool-execution`, `gen:tool-approval`, `gen:agent`).

Package: directory `racket/dsh-exec/`, collection `dsh-exec`, `(define deps '("base" "cordis" "cordis-data" "cordis-schema" "dsh-util" "dsh-session" "dsh-llm" "dsh-tools" "dsh-agent"))`, `(define build-deps '("rackunit-lib" "dsh-test-support"))`. It must not depend on `dsh-fs` or on any other wave 4 package: services of those packages are reached through the generic interfaces of `dsh-exec/ports`.

## Scope

| dsh package | npm name | Status |
|---|---|---|
| `packages/subprocess/subprocess` | `@deepseek-ai/dsh-subprocess` | native |
| `packages/subprocess/subprocess-local` | `@deepseek-ai/dsh-subprocess-local` | adapted. Racket `subprocess` with one process group per spawn under a custodian, which is dsh's fallback owner. The Linux systemd-scope owner, the Windows Job owner and the private runner bootstrap are not ported. Terminals use `openpty(3)` through the FFI in place of node-pty. The control channel is a loopback socket handed to the child on descriptor 7 by a bash trampoline (rule 28). Shell-activity observation always reports `unknown`. |
| `packages/subprocess/win32-process` | `@deepseek-ai/dsh-win32-process` | not applicable: Win32 process and Job bindings |
| `packages/sandbox/sandbox` | `@deepseek-ai/dsh-sandbox` | native |
| `packages/sandbox/sandbox-local` | `@deepseek-ai/dsh-sandbox-local` | native for argv construction, runner selection and probes of bubblewrap, Landlock, Seatbelt and `runnerCommand`. The Windows ACL runner is not applicable. The Landlock launcher is the C program `native/system/packages/entry/src/main.c`, built with `cc` (rule 36). Seatbelt is specified and untested on this Linux machine; `bwrap` is absent here, so tests cover argv and the unavailable path. |
| `packages/sandbox/sandbox-policy` | `@deepseek-ai/dsh-sandbox-policy` | native |
| `packages/sandbox/sandbox-windows-acl` | `@deepseek-ai/dsh-sandbox-windows-acl` | not applicable: Win32 restricted tokens and ACLs |
| `packages/shell/shell` | `@deepseek-ai/dsh-shell` | native |
| `packages/shell/bash-local` | `@deepseek-ai/dsh-bash-local` | native |
| `packages/shell/bash-sandbox` | `@deepseek-ai/dsh-bash-sandbox` | native |
| `packages/shell/shell-env` | `@deepseek-ai/dsh-shell-env` | native. `DSH_NODE_EXECUTABLE` is set only when a `node` binary is found (rule 65). |
| `packages/shell/tool-bash` | `@deepseek-ai/dsh-tool-bash` | native |
| `packages/shell/tool-bash-persistent` | `@deepseek-ai/dsh-tool-bash-persistent` | native |
| `packages/shell/pwsh-local`, `pwsh-sandbox`, `tool-pwsh`, `tool-pwsh-persistent` | `@deepseek-ai/dsh-pwsh-local`, `…-pwsh-sandbox`, `…-tool-pwsh`, `…-tool-pwsh-persistent` | not applicable in this port (Windows). Kept for config parity only: each name resolves to a plugin that accepts the dsh config keys and whose body raises at load (Plugins). The shipped bundles disable these rows off Windows, so an unmodified dsh configuration never mounts them. |
| `packages/terminal/terminal` | `@deepseek-ai/dsh-terminal` | native |
| `packages/terminal/terminal-bash` | `@deepseek-ai/dsh-terminal-bash` | native for the `bash` dialect. The `pwsh` dialect is accepted by the schema and raises at load. The headless xterm emulator is replaced by a three-query responder (rule 93). |
| `packages/ssh/ssh` | `@deepseek-ai/dsh-ssh` | wrapped over the system `ssh` client, as in dsh. The Racket side is the client of helper protocol 3. The remote helper (`helper.ts`, `helper-entry.ts`, `helper-processes.ts`) is a dsh build product that already exists on the remote host and is not ported. `ssh` is absent on this machine: tests cover argv and the frame protocol against an in-process peer. |
| `packages/ssh/subprocess-ssh` | `@deepseek-ai/dsh-subprocess-ssh` | adapted. Requests are native; each byte stream is a forwarded Unix socket secured with TLS-PSK, which Racket's `openssl` binding does not offer, so a stream is one `openssl s_client` child (rule 113). |
| `packages/ssh/sandbox-ssh` | `@deepseek-ai/dsh-sandbox-ssh` | native |
| `packages/ssh/fs-ssh` | `@deepseek-ai/dsh-fs-ssh` | native, implemented in `dsh-fs` (module `dsh-fs/ssh`), because it implements `gen:fs-provider`, which is defined above this package. See [dsh-fs.md](dsh-fs.md). |
| `packages/ssh/ssh-helper-runtime` | `@deepseek-ai/dsh-ssh-helper-runtime` | not applicable: the entry dispatcher of the remote Node helper |

`packages/util/timeout` is provided here as `dsh-exec/timeout` because no lower contract names it; if `dsh-util` exports the same bindings this module becomes a re-export.

## Modules

| Module | Provides |
|---|---|
| `dsh-exec` (`main.rkt`) | re-exports `errors`, `timeout`, `ports`, `subprocess`, `sandbox`, `sandbox/policy`, `shell`, `shell/env`, `terminal` |
| `dsh-exec/ports` | `gen:working-directory-port`, `gen:job-registry-port` with its data, `gen:profile-context-port`. Requires only `racket/base` and `racket/generic`; it is the first module delivered. |
| `dsh-exec/timeout` | `timeout-reason`, `make-deadline`, `deadline-evt`, `deadline-dispose!`, `timeout-of`, `clamp-timeout`, `max-timer-delay-ms` |
| `dsh-exec/errors` | constructors and predicates of every error in Data, the code lists, `subprocess-spawn-failure`, `error->js-string` |
| `dsh-exec/subprocess` | the `subprocess` service definition, `gen:subprocess-runtime`, spawn and terminal specs, handles, output readers, `scrubbed-parent-env`, the control-channel constants |
| `dsh-exec/subprocess/collector` | `make-output-collector` and its operations |
| `dsh-exec/subprocess/local` | `make-local-subprocess-runtime` |
| `dsh-exec/sandbox` | the `sandbox` service definition, `gen:sandbox-provider`, modes, `execution-policy`, `confined-argv`, escalation, markers, writable roots, the three classifiers |
| `dsh-exec/sandbox/profiles` | `bwrap-profile-args`, `landlock-profile-args`, `seatbelt-profile-args` |
| `dsh-exec/sandbox/local` | `make-local-sandbox-provider`, `landlock-launcher-path` |
| `dsh-exec/sandbox/policy` | the `sandboxPolicy` service definition, the `sandbox/mode` session event, `set-sandbox-mode!`, `render-policy-context` |
| `dsh-exec/shell` | the `shell` service definition, `gen:shell-executor`, request, spec, execution and result data, `parse-exit-status` |
| `dsh-exec/shell/bash-local` | `make-local-bash-executor`, `bash-env-overrides` |
| `dsh-exec/shell/bash-sandbox` | `make-sandbox-bash-executor` |
| `dsh-exec/shell/env` | the `shellEnv` service definition |
| `dsh-exec/tool/bash` | `make-bash-tool`, `render-result`, `render-promoted`, `render-job-read`, `process-outcome`, `ring-delta` |
| `dsh-exec/tool/bash-persistent` | `make-persistent-bash-tool`, `wrap-command`, `quote-for-bash` |
| `dsh-exec/terminal` | the `terminals` service definition, backend and session interfaces, terminal data |
| `dsh-exec/terminal/sanitize` | `make-sanitizer`, `sanitizer-push!` |
| `dsh-exec/terminal/buffer` | the bounded scrollback and operation buffers |
| `dsh-exec/terminal/bash` | `make-bash-terminal-backend`, `resolve-terminal-config` |
| `dsh-exec/ssh` | the `ssh` service definition and its procedures |
| `dsh-exec/ssh/protocol` | `make-rpc-peer` and its operations, `ssh-protocol-version`, `exn:fail:remote-operation` |
| `dsh-exec/ssh/subprocess`, `dsh-exec/ssh/sandbox` | `make-ssh-subprocess-runtime`, `make-ssh-sandbox-provider` |
| `dsh-exec/plugin/<short-name>` | one module per row of Plugins, each providing `plugin` |
| `dsh-exec/plugins` | `plugin-table` |

Private modules, suggested: `private/posix.rkt` (the FFI bindings `killpg`, `kill`, `openpty`, `ioctl`, `mkfifo`-free; signal numbers per platform), `private/proc.rkt` (Linux `/proc` readers), `private/pty.rkt`, `private/range.rkt` (process-group liveness), `private/landlock.rkt`. Other packages never require them.

## Data

Process-local values are structs. Values that are logged, sent over the SSH wire or shown to user interfaces are jobjects with the dsh keys in the dsh order. `cancel` is a cancel event of `dsh-llm/cancel` or `#f`; `#f` stands for an omitted `signal`.

### Ports (`dsh-exec/ports`)

```racket
(define-generics working-directory-port
  (working-directory-ensure working-directory-port agent cancel))      ; -> string?, an absolute path; waits
(define-generics job-registry-port
  (job-start! job-registry-port spec)                                  ; spec : job-start-spec?; -> string? (the job id); may raise (admission)
  (job-wait job-registry-port id timeout-ms owner cancel)              ; -> job-view?; waits; raises the cancel reason
  (job-kill! job-registry-port id owner reason)                        ; -> void?
  (job-remove! job-registry-port id owner)                             ; -> void?
  (job-read! job-registry-port id owner))                              ; -> job-read?; a consuming read
(struct job-start-spec (kind label call-id root-call-id owner output run))
(struct job-output-source (channel read))        ; channel : "stdout" or "stderr"; read : (-> exact-nonnegative-integer? output-read?)
(struct job-hooks (done cancel))                 ; done : evt whose value is a job-outcome?; cancel : (-> string? void?)
(struct job-outcome (status detail))             ; status : "completed" "killed" "failed"; detail : string?
(struct job-view (status detail))                ; status : "running" "stopping" "completed" "killed" "failed"
(struct job-chunk (channel text))
(struct job-read (chunks lossy? spill-paths))    ; spill-paths : (listof string?)
(define-generics profile-context-port
  (profile-context-name profile-context-port)                          ; -> string?
  (profile-context-dir profile-context-port)                           ; -> string?
  (profile-context-install-anchor profile-context-port))               ; -> string?
```

`run` of a `job-start-spec` is `(-> job-hooks?)`, called by the registry after admission. `owner` is an agent id or `#f`. The service keys are `workingDirectory` (provider: `dsh-session-store`), `jobs` (provider: `dsh-automation`) and `profileContext` (provider: `dsh-boot`); each is read with `port-get` of `dsh-llm/ports`. The approval service is `gen:tool-approval` of `dsh-tools/approval`, and the projection registry is `gen:projection-port` of `dsh-llm/ports`.

### Timeouts (`dsh-exec/timeout`; `packages/util/timeout/src/index.ts`)

```racket
(struct timeout-reason (code timeout-ms) #:transparent)       ; dsh TimeoutReason; its text is "<code> after <timeout-ms>ms"
max-timer-delay-ms                                            ; 2147483647
(clamp-timeout requested default max [name "timeoutMs"]) -> real?
(make-deadline upstream timeout-ms code) -> deadline?         ; upstream : (or/c evt? #f)
(deadline-evt d) -> evt?                                      ; a cancel event
(deadline-dispose! d) -> void?
(timeout-of c [code #f]) -> (or/c timeout-reason? #f)         ; c : (or/c evt? #f)
```

### Errors (`dsh-exec/errors`)

All are substructs of `exn:fail:harness` made only by the constructors below; the dsh error name and code are the persisted identity (dsh-tools "Errors").

| Constructor | dsh name | Codes |
|---|---|---|
| `(make-subprocess-error code message #:cause [c #f])` | `SubprocessError` | `subprocess-error-codes`: `SUBPROCESS_INVALID_ARGV`, `SUBPROCESS_EXECUTABLE_NOT_FOUND`, `SUBPROCESS_SPAWN_NOT_FOUND`, `SUBPROCESS_SPAWN_FAILED`, `SUBPROCESS_RUNNER_FAILED`, `SUBPROCESS_RUNNER_IPC_FAILED`, `SUBPROCESS_PTY_UNAVAILABLE` |
| `(make-executable-not-found-error message #:cause [c #f])` | `SubprocessExecutableNotFoundError` | `SUBPROCESS_EXECUTABLE_NOT_FOUND` |
| `(make-sandbox-unavailable-error mode [detail #f])` | `SandboxUnavailableError` | `SANDBOX_UNAVAILABLE` |
| `(make-sandbox-preparation-error code message #:cause [c #f])` | `SandboxPreparationError` | `SANDBOX_PREPARATION_FAILED`, `SANDBOX_INVALID_TEMP_ROOT` |
| `(make-sandbox-invalid-root-error path detail [subject "additional writable directory"])` | `SandboxInvalidRootError` | `SANDBOX_INVALID_ROOT` |
| `(make-sandbox-escalation-error code message)` | `SandboxEscalationError` | `sandbox-escalation-error-codes`: `SANDBOX_ESCALATION_INVALID_ARGUMENT`, `SANDBOX_ESCALATION_UNAVAILABLE`, `SANDBOX_ESCALATION_REJECTED`, `SANDBOX_ESCALATION_CANCELLED` |
| `(make-shell-env-error message)` | `ShellEnvError` | `SHELL_ENV_CONTRIBUTION_INVALID` |
| `(make-terminal-error code message)` | `TerminalError` | `CLEANUP_FAILED`, `DUPLICATE_BACKEND`, `DUPLICATE_NAME`, `FOREIGN_SESSION`, `INIT_REJECTED`, `NO_BACKEND`, `NO_SANDBOX`, `NO_SESSION`, `OWNER_NOT_LIVE`, `SEND_ACTIVE`, `SERVICE_DISPOSING`, `SESSION_CLOSING`, `SESSION_EXITED`, `STARTUP_EXITED`, `STARTUP_TIMEOUT` |
| `(make-tool-aborted-error)` | `AbortError` | `ABORTED`, message `tool call aborted` |

Messages. `SandboxUnavailableError`: the text of `packages/sandbox/sandbox/src/index.ts:147-155`, which is ``sandbox mode "<mode>" is requested but no sandbox backend is usable on this host; refusing to run the command unconfined. Install bubblewrap or run a Landlock-enforcing kernel (Linux), ensure sandbox-exec is usable (macOS), or ensure the ACL restricted-token runner can start (Windows) — otherwise switch the consumer to danger-full-access.`` followed by `` Runner failure: <detail>`` when a detail is given. `SandboxInvalidRootError`: `Invalid <subject> <path as JSON string>: <detail>`.

```racket
(struct exn:fail:spawn exn:fail (errno syscall path) #:transparent)   ; the counterpart of Node's spawn errno error
(struct exn:fail:remote-operation exn:fail (code))                     ; dsh RemoteOperationError; code : (or/c string? #f)
(struct exn:fail:terminal-cleanup exn:fail (failures))                 ; dsh TerminalBackendCleanupError and the aggregate of disposal
(subprocess-spawn-failure v program) -> any/c
(error->js-string v) -> string?
```

`exn:fail:spawn` has `errno` `"ENOENT"` or `"EACCES"`, `syscall` `"spawn <program>"`, `path` the program, and the message `spawn <program> <errno>`. It is not a harness error. `(error->js-string v)` is JavaScript `String(v)`: `<dsh name>: <message>` for a harness error, `AbortError: <message>` for an `exn:fail:abort`, `Error: <message>` for any other exception, the `timeout-reason` text prefixed with `TimeoutReason: ` for a `timeout-reason`, a string unchanged, and the `display` form otherwise.

### Subprocess data (`dsh-exec/subprocess`)

```racket
(struct stdin-data (text) #:transparent)
(stdin-mode? v)                                   ; 'ignore, 'pipe or a stdin-data
(struct collect-mode (max-bytes spill-max-bytes) #:transparent)   ; spill-max-bytes : positive integer, or #f for tail-only collection
(output-mode? v)                                  ; 'pipe, 'inherit or a collect-mode
(struct spawn-spec (argv cwd stdin stdout stderr control? grace-ms cancel env) #:transparent)
(make-spawn-spec #:argv argv #:cwd cwd #:stdin stdin #:stdout stdout #:stderr stderr #:grace-ms grace-ms
                 #:control? [control? #f] #:cancel [cancel #f] #:env [env #f]) -> spawn-spec?
(struct subprocess-outcome (exit-code signal) #:transparent)      ; exit-code : (or/c exact-integer? #f); signal : (or/c string? #f), e.g. "SIGTERM"
(struct output-read (text next-offset lossy? spill-path) #:transparent)
(struct collected-output (text truncated? spill-path) #:transparent)
(collected-output->jvalue o) -> jobject?          ; {text, truncated, spillPath?}
(output-reader? v)
(output-reader-read-from r from-byte) -> output-read?
(make-output-reader proc) -> output-reader?       ; proc : (-> exact-nonnegative-integer? output-read?)

(subprocess-handle? v)                            ; opaque
(subprocess-handle-stdin h) -> (or/c output-port? #f)      ; only with stdin 'pipe
(subprocess-handle-stdout h) -> (or/c input-port? #f)      ; only with stdout 'pipe
(subprocess-handle-stderr h) -> (or/c input-port? #f)
(subprocess-handle-control h) -> (or/c (cons/c input-port? output-port?) #f)
(subprocess-handle-collected h stream) -> (or/c output-reader? #f)   ; stream : 'stdout or 'stderr
(subprocess-handle-done h) -> evt?                ; ready once settled; (await ...) returns a subprocess-outcome or raises the launch failure
(subprocess-handle-terminate! h) -> void?
(subprocess-handle-wait-for-exit h #:cancel [cancel #f]) -> boolean?  ; waits
```

`argv` is a non-empty list of strings. `env` is `#f` or a hash from name to a string (an explicit entry that survives the scrub) or `#f` (a tombstone that removes an ambient entry). No field of a `spawn-spec` has a default except the three optional ones: this seam applies no defaults (`subprocess/src/types.ts:66-100`).

```racket
(struct terminal-spawn-spec (argv cwd env rows cols terminal-type shell-activity? grace-ms cancel) #:transparent)
(terminal-signal? v)                              ; "SIGINT" "SIGTERM" "SIGKILL" "SIGTSTP" "SIGHUP"
(struct terminal-foreground (process-group-id input-waiting?) #:transparent)
(struct terminal-activity (state revision) #:transparent)         ; state : 'idle 'busy 'unknown
(struct terminal-environment (platform default-shell) #:transparent)   ; platform : 'posix or 'windows; default-shell : (or/c string? #f)
(terminal-handle? v)                              ; opaque
(terminal-handle-pid h) -> exact-positive-integer?
(terminal-handle-output h) -> input-port?         ; terminal bytes in delivery order; eof after the terminal exits
(terminal-handle-done h) -> evt?                  ; as subprocess-handle-done
(terminal-handle-write! h text) -> void?
(terminal-handle-resize! h cols rows) -> void?
(terminal-handle-inspect-foreground h) -> (or/c terminal-foreground? #f)
(terminal-handle-inspect-activity h) -> terminal-activity?
(terminal-handle-signal-foreground! h signal) -> exact-positive-integer?   ; the group that received it
(terminal-handle-terminate! h) -> void?           ; waits for quiescence
```

Control channel constants: `subprocess-control-fd` is `7`, `subprocess-control-env` is `"DSH_SUBPROCESS_CONTROL"`, `dsh-env-prefix` is `"DSH_"`, `sensitive-env-pattern` is `#px"(?i:KEY|PASSWORD|SECRET|TOKEN)"`.

### Sandbox data (`dsh-exec/sandbox`)

```racket
sandbox-modes                                     ; '("read-only" "workspace-write" "danger-full-access")
(sandbox-mode? v) (confined-sandbox-mode? v)      ; strings; the second excludes "danger-full-access"
(struct execution-policy (mode workspace-root additional-writable-roots session-id) #:transparent)
(make-execution-policy #:mode mode #:workspace-root root #:additional-writable-roots [roots #f] #:session-id [id #f]) -> execution-policy?
(execution-policy->jvalue p) -> jobject?          ; {mode, workspaceRoot, additionalWritableRoots?, sessionId?}
(jvalue->execution-policy jv) -> execution-policy?
(struct runner-failure-rule (allowed-exit-codes fatal-signatures informational-lines) #:transparent)
(struct confined-argv (argv enforcement denial-signatures runner-failure-rules) #:transparent)   ; enforcement : 'full or 'partial
escalation-targets                                ; '("workspace-write" "danger-full-access")
(wider-modes mode) -> (listof sandbox-mode?)      ; "read-only" -> both targets; "workspace-write" -> '("danger-full-access"); else '()
```

`execution-policy` is dsh `SandboxExecutionPolicy`; `additional-writable-roots` is a non-empty list or `#f`, `session-id` a string or `#f`. `allowed-exit-codes` and `informational-lines` are lists or `#f`. Modes are strings because they are config values, tool arguments and session data.

### Shell data (`dsh-exec/shell`)

```racket
(struct shell-request (command workdir timeout-ms on-expiry stdout-max-bytes cancel stdin env dsh-env sandbox-policy) #:transparent)
(make-shell-request #:command command #:workdir [#f] #:timeout-ms [#f] #:on-expiry [#f] #:stdout-max-bytes [#f]
                    #:cancel [#f] #:stdin [#f] #:env [#f] #:dsh-env [#f] #:sandbox-policy [#f]) -> shell-request?
(struct shell-spec (command workdir timeout-ms on-expiry stdout-max-bytes cancel stdin env dsh-env sandbox-policy) #:transparent)
(shell-spec-set spec #:cancel … #:on-expiry …) -> shell-spec?          ; functional update of any field
(struct shell-sandbox-info (mode denied? enforcement runner-failed?) #:transparent)   ; enforcement : 'full 'partial or #f; runner-failed? : #t #f or absent
(shell-sandbox-info->jvalue i) -> jobject?        ; {mode, denied, enforcement?, runnerFailed?}
(struct shell-run-result (exit-code signal timed-out? aborted? timeout-ms stdout stderr sandbox) #:transparent)
(struct shell-read (delta lossy? stdout-spill-path stderr-spill-path) #:transparent)
(shell-execution? v)                              ; opaque
(shell-execution-status e) -> (or/c 'running 'completed 'killed)
(shell-execution-exit-code e) (shell-execution-signal e)
(shell-execution-done e) -> evt?                  ; ready once settled; never raises
(shell-execution-sandbox e) -> (or/c shell-sandbox-info? #f)
(shell-execution-read-output! e) -> shell-read?   ; a consuming cursor
(shell-execution-observed e stream) -> output-reader?
(shell-execution-kill! e) -> boolean?
(shell-execution-result e) -> shell-run-result?   ; waits; memoised; raises only for infrastructure failures
```

`on-expiry` is `'kill` or `'none`. `env` is a hash from string to string. `dsh-env` is a *dsh environment*: a list of `(cons key value)` pairs sorted by key (rule 66). In a `shell-spec` the fields `workdir`, `timeout-ms`, `on-expiry` and `stdout-max-bytes` are never `#f`; `sandbox-policy` is an `execution-policy` or `#f`. `stdout` and `stderr` of a result are `collected-output` values; `timed-out?` and `aborted?` are never both true.

### Terminal data (`dsh-exec/terminal`)

```racket
(terminal-session-id? v)                          ; a string "pty-<n>"
(struct terminal-running () #:transparent)
(struct terminal-exited (exit-code signal) #:transparent)
(terminal-status->jvalue s) -> jobject?           ; {kind: "running"} or {kind: "exited", exitCode, signal}
(struct backend-spawn-spec (type name cwd session-id owner cancel) #:transparent)
(struct send-result (viewport wait-reason session-status truncated?) #:transparent)   ; wait-reason : "stdin_read" "inferred_idle" "timeout" "session_exit"
(send-operation? v)
(send-operation-done op) -> evt?                  ; (await ...) returns a send-result or raises
(send-operation-read-output! op) -> (values string? boolean?)        ; delta, truncated?
(send-operation-cancel! op) -> boolean?
(make-send-operation #:done evt #:read-output proc #:cancel proc) -> send-operation?
(struct terminal-read-result (text total-lines line-begin line-end truncated?) #:transparent)
(struct terminal-snapshot (session-id name type pid status) #:transparent)
(struct terminal-spawn-result (session-id name type pid status motd) #:transparent)
(struct terminal-backend (type spawn))            ; spawn : (-> backend-spawn-spec? terminal-backend-session?), waits
(define-generics terminal-backend-session
  (backend-session-motd terminal-backend-session)                      ; -> string?
  (backend-session-pid terminal-backend-session)                       ; -> (or/c exact-positive-integer? #f)
  (backend-session-start-send terminal-backend-session text submit? cancel)   ; -> send-operation?
  (backend-session-read terminal-backend-session offset count)         ; -> terminal-read-result?; offset, count : integer or #f
  (backend-session-signal! terminal-backend-session signal)            ; -> exact-positive-integer?, the target group; waits
  (backend-session-status terminal-backend-session)                    ; -> terminal-running? or terminal-exited?
  (backend-session-close! terminal-backend-session reason))            ; -> void?, waits
```

### Session event declared here (`dsh-exec/sandbox/policy`)

```racket
(define-session-event sandbox/mode #:type "sandbox/mode"
  #:fields ([mode sandbox-mode?] [source (lambda (v) (equal? v "delegation")) #:optional]))
```

Data keys in write order: `mode`, `source?`. It is log-only: not a surface event, not ignorable. `source: "delegation"` is written by the subagent package when it seeds a child session.

### Projection state

| Key | `stateVersion` | State | Wire view |
|---|---|---|---|
| `sandboxMode` | 1 | a mode string, or `'null` initially | none; not part of summaries |

### SSH records (`dsh-exec/ssh`)

All are jobjects with the dsh keys (`packages/ssh/ssh/src/schemas.ts`). Frame: `{type: "request", id, method, params}`, `{type: "result", id, value}`, `{type: "error", id, error: {name, message, code?}}`, `{type: "cancel", id}`, each with exactly those keys in that order. Hello: `{protocol: 3, hash, kind, platform, nodeVersion, executable, root, workspace, bootstrapHash?}`. Stream endpoint: `{path, capability}` with `capability` 64 lowercase hex digits. Prepared process: `{id, streams}` where `streams` maps some of `stdin`, `stdout`, `stderr`, `control`, `terminal` to endpoints. Done: `{outcome: {exitCode, signal}, spills: {stdout?, stderr?}, collected: {stdout?: {tail, totalBytes}, stderr?: …}}` with `tail` base64 text. `(check-ssh-record kind jv) -> jvalue?` validates a value against the schema of that name (`'hello`, `'stream-endpoint`, `'prepared`, `'done`, `'outcome`, `'foreground`, `'terminal-activity`, `'confined`) and raises `exn:fail:contract` naming the first offending key.

## Services

`x` is a context or a handle for the service; "the caller's context" is `(use-context x)`. A seam with interchangeable providers is a generic interface; the public procedures read the service value and call it.

### `subprocess`

`(define-service subprocess 'subprocess #:contract subprocess-runtime?)` in `dsh-exec/subprocess`.

```racket
(define-generics subprocess-runtime
  (runtime-resolve-executable subprocess-runtime command env cancel)   ; -> string?, waits
  (runtime-terminal-environment subprocess-runtime cancel)             ; -> terminal-environment?, waits
  (runtime-spawn subprocess-runtime spec)                              ; -> subprocess-handle?, does not wait
  (runtime-spawn-terminal subprocess-runtime spec))                    ; -> terminal-handle?, waits
(subprocess-resolve-executable x command #:env [env #f] #:cancel [cancel #f]) -> string?
(subprocess-terminal-environment x #:cancel [cancel #f]) -> terminal-environment?
(subprocess-spawn x spec) -> subprocess-handle?
(subprocess-spawn-terminal x spec) -> terminal-handle?
(scrubbed-parent-env) -> (hash/c string? string?)
```

| Procedure | Semantics and errors | Effects on the caller's context |
|---|---|---|
| `subprocess-resolve-executable` | Rule 18. `env` is a hash of string overrides. Raises `SUBPROCESS_EXECUTABLE_NOT_FOUND`. | none |
| `subprocess-terminal-environment` | Rule 19. | none |
| `subprocess-spawn` | Rules 4 to 17. Returns at once. Raises synchronously for an invalid grace, an already cancelled spec and an empty program; every later failure is delivered through `subprocess-handle-done`. | none. The provider tracks the handle and terminates it when the provider unloads. The child also belongs to a custodian made under `(current-custodian)` of the calling task, so the caller's fiber reclaims it (ADR 0004). |
| `subprocess-spawn-terminal` | Rules 20 to 26. Raises `SUBPROCESS_PTY_UNAVAILABLE` when the FFI bindings or `setsid` are missing. | none; tracked and reclaimed as above |

### `sandbox`

`(define-service sandbox 'sandbox #:contract sandbox-provider?)` in `dsh-exec/sandbox`.

```racket
(define-generics sandbox-provider
  (sandbox-provider-confine sandbox-provider argv policy cancel))      ; -> confined-argv?, may wait
(sandbox-confine x argv policy #:cancel [cancel #f]) -> confined-argv?
```

`policy` is an `execution-policy` whose mode is confined; a consumer in `danger-full-access` never calls `sandbox-confine`. The result is enforcing argv or a raise of `SANDBOX_UNAVAILABLE`, `SANDBOX_PREPARATION_FAILED` or `SANDBOX_INVALID_ROOT`; returning the input argv unchanged is forbidden. It registers nothing.

Library procedures of the same module, used by every enforcing tool:

```racket
(validate-escalation-args sandbox-permissions justification) -> void?         ; each a string or #f
(approve-escalation #:requested-mode mode #:justification text #:effective-mode effective #:subject subject
                    #:approver approver #:agent agent #:call-id call-id #:tool-name name #:cancel cancel) -> sandbox-mode?   ; waits
(sandbox-denial-marker mode) (escalation-hint-marker subject) (sandbox-permissions-description subject) -> string?
(escalation-display-reason mode justification) -> jobject?                    ; keys en zh ja es fr de ru pt
(canonical-path path) -> string?
(workspace-writable-roots policy) (writable-roots policy) -> (listof string?)
(classify-runner-failure exit-code stderr rules) -> (or/c string? #f)        ; the matched stderr line
(matches-signature? exit-code stderr signatures) -> boolean?
(runner-spawn-failure? v runner-program workdir) -> boolean?
```

`approver` is a value implementing `gen:tool-approval` or `#f`; `agent` is an agent or `#f`; `cancel` is the call's cancel event.

### `sandboxPolicy`

`(define-service sandbox-policy 'sandboxPolicy #:contract sandbox-policy-service?)` in `dsh-exec/sandbox/policy`.

```racket
(sandbox-policy-default-mode x) -> sandbox-mode?
(sandbox-policy-workspace-root x) -> string?
(sandbox-policy-additional-writable-roots x) -> (or/c (listof string?) #f)
(sandbox-policy-resolve x #:session [session #f] #:mode [mode #f]) -> execution-policy?
(sandbox-policy-register-writable-root! x session directory) -> disposer?
(sandbox-policy-override-of x session) -> (or/c sandbox-mode? #f)
(set-sandbox-mode! session mode #:source [source absent]) -> session-event?
(render-policy-context policy) -> string?
```

| Procedure | Semantics and errors | Effects on the caller's context |
|---|---|---|
| `sandbox-policy-resolve` | Rule 45. Raises `SANDBOX_INVALID_ROOT` for a session whose cwd is not absolute. | none |
| `sandbox-policy-register-writable-root!` | Rule 46. Raises `exn:fail` for a path that is not absolute or holds NUL, before any effect is made. | one effect `sandboxPolicy.registerWritableRoot()` whose inverse withdraws exactly this grant |
| `sandbox-policy-override-of` | The `sandboxMode` projection state of the session, `#f` for `'null`. | none |
| `set-sandbox-mode!` | Appends one `sandbox/mode` event. Not a service procedure: it needs only the session. | none |

### `shell`

`(define-service shell 'shell #:contract shell-executor?)` in `dsh-exec/shell`.

```racket
(define-generics shell-executor
  (shell-executor-sandbox-mode shell-executor)       ; -> (or/c sandbox-mode? #f); default #f
  (shell-executor-resolve shell-executor request)    ; -> shell-spec?; the explicit defaulting and capping step
  (shell-executor-execute shell-executor spec))      ; -> shell-execution?; may wait (preparation)
(shell-sandbox-mode x) -> (or/c sandbox-mode? #f)
(shell-resolve x request) -> shell-spec?
(shell-execute x spec) -> shell-execution?
(parse-exit-status text) -> (values string? (or/c exact-integer? #f) (or/c string? #f))   ; body, exit code, signal
```

`shell-sandbox-mode` is the capability fact a tool layer reads once at mount to decide whether to advertise escalation fields. None of the three registers an effect. The executor reads the `subprocess` service once at construction and keeps it.

### `shellEnv`

`(define-service shell-env 'shellEnv #:contract shell-env-registry?)` in `dsh-exec/shell/env`.

```racket
(struct env-contributor (name variables resolve))
(shell-env-register! x contributor) -> disposer?
(shell-env-collect x exec) -> (listof (cons/c string? string?))       ; exec : tool-execution?
(shell-env-list x) -> (listof jobject?)                               ; {contributor, description, key}, sorted by key
(dsh-env-key<? a b) -> boolean?
```

`variables` is a list of `(cons key description)`; `resolve` is `(-> tool-execution? (listof (cons/c string? any/c)))`. `shell-env-register!` makes one effect `bashEnv.register()` on the caller's context (rule 63). `shell-env-collect` raises `SHELL_ENV_CONTRIBUTION_INVALID`, in which case the shell command must not run.

### `terminals`

`(define-service terminals 'terminals #:contract terminal-service?)` in `dsh-exec/terminal`. The owner of a session is the exact live agent value.

```racket
(terminals-register-backend! x backend) -> disposer?
(terminals-list-backends x) -> (listof string?)
(terminals-spawn x owner #:type type #:name [name #f] #:cwd [cwd #f] #:cancel [cancel #f]) -> terminal-spawn-result?   ; waits
(terminals-has-owner-activity? x owner) -> boolean?
(terminals-start-send x owner id #:text text #:submit? submit? #:cancel [cancel #f]) -> send-operation?
(terminals-read x owner id #:offset [offset #f] #:count [count #f]) -> terminal-read-result?
(terminals-signal! x owner id signal) -> exact-positive-integer?      ; waits; the target group
(terminals-kill! x owner id [reason "model request"]) -> boolean?     ; waits
(terminals-list x owner) -> (listof terminal-snapshot?)
```

| Procedure | Errors | Effects |
|---|---|---|
| `terminals-register-backend!` | `DUPLICATE_BACKEND` `a PTY backend named "<type>" is already registered` | one effect on the caller's context whose inverse removes the backend |
| `terminals-spawn` | rule 80 | on first use for an owner, one effect on `(agent-ctx owner)` that closes that owner's sessions and aborts its pending spawns |
| the per-session procedures | `NO_SESSION` `unknown PTY session <id>`; `FOREIGN_SESSION` `PTY session <id> belongs to another agent`; rule 81 | none |

### `ssh`

`(define-service ssh 'ssh #:contract ssh-connection?)` in `dsh-exec/ssh`.

```racket
(ssh-ready x) -> jobject?                                              ; the hello record; waits
(ssh-ptc-launch x) -> jobject?                                         ; {kind: "embedded", executable} or {kind: "node-script", executable, bootstrapPath}
(ssh-request x method params #:check [check #f] #:cancel [cancel #f] #:wait? [wait? #f]) -> jvalue?   ; waits
(ssh-connect-stream x endpoint #:cancel [cancel #f]) -> (values input-port? output-port?)             ; waits
(ssh-dispose! x) -> void?                                              ; waits; memoised
```

`check` is `(-> jvalue? jvalue?)`, applied to the result (the place of the zod schema). None registers an effect; the connection's own plugin owns its teardown.

### Waiting and cancellation

- `subprocess-spawn` does not wait. `subprocess-handle-wait-for-exit` takes `#:cancel` and returns `#f` when it fires first. `(await (subprocess-handle-done h))` is cancelled only by a break of the waiting task; the process is stopped through the spec's cancel event or `subprocess-handle-terminate!`.
- `subprocess-spawn-terminal`: the spec's `cancel` governs allocation only; a published handle owns its later lifetime.
- `sandbox-confine`, `subprocess-resolve-executable`, `subprocess-terminal-environment`: `#:cancel`; they raise the cancel reason.
- `approve-escalation`: `#:cancel`, handed to the approver; rule 40 says what a cancelled approval raises.
- `shell-execute`: the spec's `cancel`, fused with the timeout when `on-expiry` is `'kill`. `shell-execution-result` and `(await (shell-execution-done e))` take no cancel event.
- `terminals-spawn`: `#:cancel`. A send: the `#:cancel` of `terminals-start-send` and `send-operation-cancel!`; both interrupt the foreground program and do not settle the operation (rule 91). `terminals-kill!` and `terminals-signal!` take none.
- `ssh-request`: `#:cancel`, fused with `requestTimeoutMs` unless `wait?`. `ssh-dispose!` takes none.
- No procedure of this package catches a break. A break of a task that waits inside one of them propagates; the process, terminal or request it was waiting for keeps running until its cancel event, its owner's disposal or its custodian stops it.

## Events

This package declares no Cordis event. It declares one session event, `sandbox/mode` (Data), appended by `set-sandbox-mode!` and by the delegation seeding of the subagent package, read by the `sandboxMode` projection and by the terminal mode fence.

Consumed, registered by name with `ctx-on`:

| Event | Listener | What it does |
|---|---|---|
| `internal/dispatch` (kernel, emit `(mode name args)`), registered with `#:global? #t` on `(agent-ctx owner)` | `dsh-exec/terminal/bash`, once per owner | rule 88: refuses a `sandbox/mode` append that would change the effective mode while that owner has open or pending terminal sessions |

Dispatched indirectly: the `session/event` of the `sandbox/mode` append.

## Tools

Both tools are named `bash`; a composition mounts one of them. Argument failures raise the tool args error of `dsh-tools` (`invalid arguments: <violations>`, code `INVALID_ARGS`). Undeclared argument keys pass schema validation, which is why the one-shot tool checks unadvertised escalation fields itself (rule 70).

### `bash`, one-shot (`dsh-exec/tool/bash`; `tool-bash/src/index.ts:392`)

The parameter list depends on the composition, so the definition is built with `make-tool`:

```racket
(make-bash-tool ctx #:jobs jobs #:promote? promote? #:escalation-modes modes …) -> tool-definition?
;; expands to
(make-tool
  #:name "bash"
  #:description bash-description
  #:parameters
  (parameters
    (param "description" (v-string #:description DESCRIPTION-TEXT) #:required? #t)
    (param "command" (v-string #:description "The bash command to execute.") #:required? #t)
    (param "timeoutMs" (v-number #:description (if promote? TIMEOUT-PROMOTE-TEXT TIMEOUT-KILL-TEXT)))
    (param "workdir" (v-string #:description "Working directory for this command. Defaults to the session workspace; a relative path is resolved against it."))
    ;; only when jobs is not #f:
    (param "run_in_background" (v-boolean #:description "Run in the background and return a job id immediately (collect with job_output, stop with job_kill). No timeout applies."))
    ;; only when modes is not empty:
    (param "sandbox_permissions" (v-string #:enum escalation-targets #:description (sandbox-permissions-description "command")))
    (param "justification" (v-string #:description JUSTIFICATION-TEXT)))
  #:output BASH-OUTPUT-SPEC #:render render-bash-value #:presentation-meta (lambda (args value) (jobj [cwd (jref value 'cwd)]))
  #:execute execute-bash #:present-call present-bash-call #:present-result present-bash-result)
```

Texts, verbatim:

- `bash-description` (`index.ts:93-102`): ``Execute a bash command (`bash -c`) and return its stdout/stderr. Each call runs in a fresh shell; pass `workdir` instead of using `cd`. Managed `$DSH_*` variables expose current harness environment facts. Long output is truncated to its tail; the full output is saved to a file whose path is reported when available. Provide `description` before `command` in the arguments. Before any delete or move, verify that the resolved absolute target path is the intended one; never run it against a computed path you have not checked. An unset variable expands to an empty string, so guard variables in such paths with `${VAR:?}`. Commands may run under a file sandbox; a blocked file operation is reported as `[sandbox: file access denied under <mode> mode]`, a policy denial: do not retry another way.``
- `DESCRIPTION-TEXT`: `Clear, concise description of what this command does in active voice, 5-10 words (shown in the UI). Examples: "ls" → "List files in current directory"; "git status" → "Show working tree status"; "npm install" → "Install package dependencies".`
- `TIMEOUT-PROMOTE-TEXT`: `Timeout in milliseconds. The executor applies its configured default and cap; on expiry the command moves to the background as a job instead of being killed.`
- `TIMEOUT-KILL-TEXT`: `Timeout in milliseconds. The executor applies its configured default and cap, and kills the command on expiry.`
- `JUSTIFICATION-TEXT`: `Required with sandbox_permissions: one sentence for the user explaining why this exact command needs the wider access. Use the language of the user’s current request.` (the apostrophe is U+2019)
- `(sandbox-permissions-description subject)`: `The narrowest wider sandbox mode for a one-shot retry of the exact <subject> the sandbox just denied; the retry asks the user for approval.`

The compiled schema with every optional parameter present must equal, as `jvalue->string` text, the `bash` entry under `initial` in `snapshots/session/agent-instructions/tool-schemas.expected.json`.

Value (`BASH-OUTPUT-SPEC` is the author spec at `index.ts:426-490`, a `oneOf` of three closed objects), keys in this order:

- `{kind: "background", jobId, cwd}`, rendered `started background job <jobId>`;
- `{kind: "promoted", cwd, jobId, timeoutMs, output}`, rendered by `render-promoted` (rule 77);
- `{kind: "foreground", cwd, exitCode, signal, timedOut, aborted, timeoutMs, stdout: {text, truncated, spillPath?}, stderr: {…}, sandbox?: {mode, denied, enforcement?, runnerFailed?}, stopped?}`, rendered by `render-result` (rule 76). `stopped` is written last although the schema lists it earlier.

The result content is one text block. The persisted meta is `{cwd}`. A non-zero exit is not an error result.

Error results (each a raise from `execute`): `tool call aborted` (`AbortError` / `ABORTED`) on caller cancellation; `SUBPROCESS_SPAWN_NOT_FOUND` `cannot start "bash": the program or the working directory does not exist (<detail>)` and `SUBPROCESS_SPAWN_FAILED` `cannot start "bash": <detail>`; `SANDBOX_UNAVAILABLE` when the runner failed; `JobError` / `JOB_BACKGROUND_DISABLED` `run_in_background is disabled for this deployment (enableRunInBackground: false)`; the tool context unavailable error `background jobs unavailable: load @deepseek-ai/dsh-jobs and @deepseek-ai/dsh-tool-jobs`; the escalation errors of rules 38 to 40; `SHELL_ENV_CONTRIBUTION_INVALID`.

Presentation (pure, for user interfaces): `present-bash-call` returns `{card: "generic", title: command, kind: "execute", rawInput: command, content: [text block of description]}` when `run_in_background` is `#t`, else `{card: "terminal", title: command, description, cwd?}` with `cwd` the `workdir` argument. `present-bash-result` returns `#f` unless the content is exactly one text block; for a background call, a promoted value or an error it returns `{card: "generic", content: [text block]}` whose text is the raw text with trailing newlines removed inside a fenced `console` block; otherwise `{card: "terminal", output: body, exitCode or signal}` from `parse-exit-status` (`index.ts:104-135`).

System prompt section `tool:bash`, order `(system-prompt-section-order x 'TOOL_BASH)` (1000), text `Check the [exit code: N] marker on every bash result; investigate failures before moving on.` It is registered unconditionally in the global layer by the plugin.

### `bash`, persistent (`dsh-exec/tool/bash-persistent`; `tool-bash-persistent/src/index.ts:417`)

```racket
(define-tool persistent-bash
  #:name "bash"
  #:description (config 'description)
  #:parameters ([command (v-string #:description "The bash command to run. Relative path is preferred in the command.") #:required])
  #:output (v-string)
  (render (value) (list (text-block value)))
  (execute (exec) …)                      ; rules 94 to 100
  (present-call () (jobj [card "terminal"] [title command])))
```

Default description: `Run commands in a persistent bash shell. State, including the current directory and exported environment variables, persists across calls for this agent.` The value is a string and is the whole model-visible text. There is no persisted meta and there are no escalation fields; confinement is what the terminal backend applied when it spawned the shell. Errors: `command must be a non-empty string` (tool args error, for a command that is blank after trimming); `bash requires an owning agent session` (tool context unavailable error); `INIT_REJECTED` `persistent bash shell did not accept initialization`; any `TerminalError` of the registry. Result texts are in rules 97 to 100.

### `pwsh`

Not provided. The names `pwsh` and the persistent `pwsh` tool are registered by no plugin of this port.

## Plugins

Each plugin's `#:name` is the npm name. Config keys are exactly the dsh keys; `x-racket` holds the Racket-only ones.

| dsh npm name | Module | Inject | Optional | Provides |
|---|---|---|---|---|
| `@deepseek-ai/dsh-subprocess-local` | `dsh-exec/plugin/subprocess-local` | none | none | `subprocess` |
| `@deepseek-ai/dsh-sandbox-local` | `dsh-exec/plugin/sandbox-local` | none | none | `sandbox` |
| `@deepseek-ai/dsh-sandbox-policy` | `dsh-exec/plugin/sandbox-policy` | `sessionProjections` | `systemPrompt`, `sessions` | `sandboxPolicy` |
| `@deepseek-ai/dsh-bash-local` | `dsh-exec/plugin/bash-local` | `subprocess` | none | `shell` |
| `@deepseek-ai/dsh-bash-sandbox` | `dsh-exec/plugin/bash-sandbox` | `subprocess`, `sandbox`, `sandboxPolicy` | none | `shell` |
| `@deepseek-ai/dsh-shell-env` | `dsh-exec/plugin/shell-env` | none | `profileContext` | `shellEnv` |
| `@deepseek-ai/dsh-tool-bash` | `dsh-exec/plugin/tool-bash` | `tools`, `shell`, `systemPrompt`, `shellEnv`, `workingDirectory` | `jobs`, `sandboxPolicy`, `approval` | none |
| `@deepseek-ai/dsh-tool-bash-persistent` | `dsh-exec/plugin/tool-bash-persistent` | `tools`, `terminals`, `workingDirectory` | none | none |
| `@deepseek-ai/dsh-terminal` | `dsh-exec/plugin/terminal` | none | `agents` | `terminals` |
| `@deepseek-ai/dsh-terminal-bash` | `dsh-exec/plugin/terminal-bash` | `terminals`, `sandboxPolicy`, `subprocess`, `workingDirectory` | `sandbox` | none |
| `@deepseek-ai/dsh-ssh` | `dsh-exec/plugin/ssh` | none | none | `ssh` |
| `@deepseek-ai/dsh-subprocess-ssh` | `dsh-exec/plugin/subprocess-ssh` | `ssh` | none | `subprocess` |
| `@deepseek-ai/dsh-sandbox-ssh` | `dsh-exec/plugin/sandbox-ssh` | `ssh` | none | `sandbox` |
| `@deepseek-ai/dsh-pwsh-local`, `…-pwsh-sandbox`, `…-tool-pwsh`, `…-tool-pwsh-persistent` | `dsh-exec/plugin/pwsh-local`, `…/pwsh-sandbox`, `…/tool-pwsh`, `…/tool-pwsh-persistent` | none | none | none |

`#:meta` records the dsh function-plugin name under `'dsh-name` where dsh has one: `"shell-env"`, `"tool-bash"`, `"tool-bash-persistent"`, `"terminal-bash"`. The abstract Service Definition packages (`dsh-subprocess`, `dsh-sandbox`, `dsh-shell`) are libraries and have no row.

Config schemas (field, type, default):

- `dsh-subprocess-local`: none. Every limit arrives on the spawn spec.
- `dsh-sandbox-local`: `runnerCommand` array of string, `[]`; `runnerFailureSignatures` array of string, `[]`; `probeTimeoutMs` natural, `5000`; `x-racket.landlockLauncher` string, absent (an explicit launcher path). Load errors, in order: `sandbox-local: runnerFailureSignatures requires runnerCommand`; `sandbox-local: runnerCommand requires at least one runnerFailureSignatures entry`; `sandbox-local: runnerFailureSignatures entries must be non-empty single-line strings`; `sandbox-local: probeTimeoutMs must be a positive finite number`.
- `dsh-sandbox-policy`: `mode` one of the three modes, `"read-only"`; `workspaceRoot` string, no schema default (the process working directory when absent); `additionalWritableRoots` array of string, `[]`. Load errors: `sandbox-policy: workspace root must be an absolute execution-world path without NUL bytes`; `sandbox-policy: writable directories must be absolute execution-world paths without NUL bytes`.
- `dsh-bash-local` and `dsh-bash-sandbox`, every field volatile and read at each `resolve`: `cwd` string, absent; `timeoutMs` number, `120000`; `maxTimeoutMs` number, `600000`; `maxOutputBytes` number, `64000`; `maxSpillBytes` number, `67108864`; `graceMs` number, `3000`.
- `dsh-shell-env`: `dshHome` string, absent (then `$DSH_HOME`, then `~/.dsh`, through the Harness home helper of `dsh-util`).
- `dsh-tool-bash`: `enableRunInBackground` boolean, `true`; `promoteOnTimeout` boolean, `true`.
- `dsh-tool-bash-persistent`: `backendType` string, `"shell"`; `timeoutMs` number, `300000`; `maxOutputChars` number, `16000`; `description` string, the default above. Load errors: `tool-bash-persistent: backendType must be non-empty`; `tool-bash-persistent: timeoutMs must be a positive safe integer`; `tool-bash-persistent: maxOutputChars must be a positive safe integer`; `tool-bash-persistent: description must be non-empty` (blank after trimming).
- `dsh-terminal`: none.
- `dsh-terminal-bash`: `backendType` string, `"shell"`; `shellDialect` `"bash"` or `"pwsh"`, `"bash"`; `shellPath` string, absent (`/bin/bash`); `shellArgs` array of string, absent (`["--noprofile", "--norc", "-i"]`; an empty array means the default); `rows` `40`; `cols` `160`; `scrollbackLines` `10000`; `scrollbackMaxBytes` `4194304`; `maxReadBytes` `262144`; `pollIntervalMs` `50`; `exactProbeAfterMs` `150`; `idleSilenceMs` `3000`; `handoffGraceMs` `500`; `promptTailGraceMs` `0`; `timeoutMs` `30000`; `disposeGraceMs` `3000` (all numbers). Load errors are those of `validateConfig` (`terminal-bash/src/config.ts:112-136`), in that order and verbatim, for example `terminal-bash: maxReadBytes must not exceed scrollbackMaxBytes`; plus, in this port, `terminal-bash: shellDialect "pwsh" is not supported by the Racket port`.
- `dsh-ssh`: `host` string, required; `helper` string, required; `launch`, required, one of `{kind: "node-script", node, bootstrapPath?, bootstrapHash?}` and `{kind: "executable"}`; `helperHash` string, required; `workspace` string, required; `requestTimeoutMs` number, `30000`; `maxFrameBytes` number, `67108864`; `maxPending` number, `128`; `leaseMs` number, `30000`; `x-racket.sshProgram` string, `"ssh"`; `x-racket.opensslProgram` string, `"openssl"`. Rule 103 lists the second validation.
- `dsh-subprocess-ssh`, `dsh-sandbox-ssh`: none.
- The four pwsh plugins accept the keys of their bash twins (`dsh-pwsh-local` and `dsh-pwsh-sandbox` also accept `pwshPath`, a volatile string) and nothing else.

Plugin bodies:

- `subprocess-local`: make the runtime, `provide-subprocess`, and register one effect whose inverse is rule 27.
- `sandbox-local`: validate, make the provider, `provide-sandbox`.
- `sandbox-policy`: validate (rule 44); `(projection-register! port ctx sandbox-mode-projection)` and keep the handle; `provide-sandbox-policy` only after the registration returned; `(ctx-inject ctx '(systemPrompt) …)` registers the runtime context of rule 48; `(ctx-inject ctx '(sessions) …)` calls `sessions-register-event-type!` with `sandbox/mode-type`.
- `bash-local`, `bash-sandbox`: make the executor over the injected services, `provide-shell`.
- `shell-env`: make the registry with the resolved Harness home, `provide-shell-env`.
- `tool-bash`: rules 67 and 68.
- `tool-bash-persistent`: validate, create the shell table with its cleanup effect (rule 101), register the tool.
- `terminal`: make the registry, `provide-terminals`, register one effect whose inverse is rule 82.
- `terminal-bash`: validate (rule 83), `(terminals-register-backend! terminals (make-bash-terminal-backend …))`.
- `ssh`: validate (rule 103), start the connection as the asynchronous setup of one effect whose inverse is `ssh-dispose!`, and `provide-ssh` once the hello arrived.
- `subprocess-ssh`, `sandbox-ssh`: make the provider over the `ssh` handle and provide it; `subprocess-ssh` registers the disposal effect of rule 115.
- Each pwsh plugin body raises `exn:fail` `<npm name>: PowerShell is not supported by the Racket port; mount the bash counterpart or disable this entry`.

```racket
;; dsh-exec/plugins
(define plugin-table
  (list (cons "@deepseek-ai/dsh-subprocess-local"      'dsh-exec/plugin/subprocess-local)
        (cons "@deepseek-ai/dsh-sandbox-local"         'dsh-exec/plugin/sandbox-local)
        (cons "@deepseek-ai/dsh-sandbox-policy"        'dsh-exec/plugin/sandbox-policy)
        (cons "@deepseek-ai/dsh-bash-local"            'dsh-exec/plugin/bash-local)
        (cons "@deepseek-ai/dsh-bash-sandbox"          'dsh-exec/plugin/bash-sandbox)
        (cons "@deepseek-ai/dsh-shell-env"             'dsh-exec/plugin/shell-env)
        (cons "@deepseek-ai/dsh-tool-bash"             'dsh-exec/plugin/tool-bash)
        (cons "@deepseek-ai/dsh-tool-bash-persistent"  'dsh-exec/plugin/tool-bash-persistent)
        (cons "@deepseek-ai/dsh-terminal"              'dsh-exec/plugin/terminal)
        (cons "@deepseek-ai/dsh-terminal-bash"         'dsh-exec/plugin/terminal-bash)
        (cons "@deepseek-ai/dsh-ssh"                   'dsh-exec/plugin/ssh)
        (cons "@deepseek-ai/dsh-subprocess-ssh"        'dsh-exec/plugin/subprocess-ssh)
        (cons "@deepseek-ai/dsh-sandbox-ssh"           'dsh-exec/plugin/sandbox-ssh)
        (cons "@deepseek-ai/dsh-pwsh-local"            'dsh-exec/plugin/pwsh-local)
        (cons "@deepseek-ai/dsh-pwsh-sandbox"          'dsh-exec/plugin/pwsh-sandbox)
        (cons "@deepseek-ai/dsh-tool-pwsh"             'dsh-exec/plugin/tool-pwsh)
        (cons "@deepseek-ai/dsh-tool-pwsh-persistent"  'dsh-exec/plugin/tool-pwsh-persistent)))
```

`@deepseek-ai/dsh-fs-ssh` is in the table of `dsh-fs`.

## Behaviour

Numbering is for tests. "Raise" without a type means `exn:fail` with the exact message. Handlers that turn a raised value into a result never catch `exn:break`. Lengths are UTF-8 bytes unless a rule says UTF-16 units.

**Timeouts and environment** (`packages/util/timeout/src/index.ts`; R8 "Subprocess formats")

1. `(clamp-timeout requested default max name)`: a `requested` that is not `#f` and is not a positive finite number raises `<name> must be a positive finite number`; the result is `(min (or requested default) max)`.
2. `(make-deadline upstream timeout-ms code)`: with `timeout-ms` at most 0 the event is `upstream` (or `never-cancelled`) and disposal does nothing. Otherwise `timeout-ms` above `max-timer-delay-ms` or not finite raises `deadline timeoutMs must be a positive finite number no greater than 2147483647`; the event is `(cancel-evt-any upstream timer)` where the timer's reason is `(timeout-reason code timeout-ms)`, so the first cause fixes the reason. `deadline-dispose!` stops the timer and is idempotent. `(timeout-of c code)` returns the reason when `c` is cancelled with a `timeout-reason` whose code equals `code` (any code when `#f`).
3. `(scrubbed-parent-env)`: every variable of the harness process except names that match `sensitive-env-pattern` and names that start with `DSH_` compared case-insensitively; then the proxy overlay of `dsh-util` (`proxyEnvironmentForChild`: a name mapped to `#f` is removed, any other is set). A child's environment is that hash with the spec's `env` applied on top: a string sets the name, `#f` removes it. Explicit entries are not scrubbed.

**Local provider: launch** (R8 H1 to H3; `subprocess-local/src/spawn.ts`; R20 "Subprocess management")

4. `subprocess-spawn` validates in this order and raises synchronously: `grace-ms` not finite, not positive or above `max-timer-delay-ms`: `subprocess graceMs must be a positive finite number no greater than 2147483647`; a cancel event that is already ready: an `exn:fail:abort` with message `aborted before spawn: <reason>`, where `<reason>` is `(error->js-string reason)` or `aborted` when that fails; an empty `argv` or empty first element: `SUBPROCESS_INVALID_ARGV` `invalid argv: expected a non-empty program name at argv[0]`. A NUL character in any argv element, the cwd or an env entry raises `exn:fail:contract`.
5. Racket's `subprocess` neither searches `PATH` nor reports a failed `exec` (the child exits with status 1), so the provider resolves and checks first. A program with a `/` is used as written, relative to the spec's cwd. A bare name is searched in the entries of the child's `PATH` (split on `:`, an empty entry meaning the cwd; `/usr/bin:/bin` when unset); the first regular file the user may execute wins. If the cwd is not an existing directory, or no candidate exists, the launch failure is `(exn:fail:spawn "ENOENT" "spawn <argv[0]>" <argv[0]>)`; if a candidate exists and none is executable it is the same with `"EACCES"`. A launch failure does not raise from `subprocess-spawn`: the handle is returned settled and `(await (subprocess-handle-done h))` raises the failure, as a rejected `done` does in dsh.
6. Launch: `subprocess` is called with `subprocess-group-enabled` true, `current-subprocess-custodian-mode` `'kill`, `current-custodian` a fresh custodian made under the caller's `(current-custodian)`, `current-directory` the cwd and `current-environment-variables` the child environment of rule 3. The child's pid is then its process-group id, and that group is the *managed range*. Stdio: stdin `'ignore` is a file-stream port on `/dev/null`, otherwise a pipe; stdout and stderr `'inherit` are the harness's own output and error ports when they are file-stream ports (else a pipe copied to them), otherwise pipes.
7. A `stdin-data` is written as UTF-8 and the pipe closed at once, on a helper thread; write errors are ignored.
8. Each collect-mode stream is drained by its own plain thread (outside the baton, under the handle's custodian) that reads available bytes and pushes them to that stream's collector. Pipe-mode ports go to the caller unread. The handle's threads touch only the handle's state, which is guarded by a lock, and never call a kernel procedure.

**Output collector** (R8 H4; `subprocess-local/src/output.ts:128-312`)

9. `(make-output-collector max-bytes label spill)` with `spill` `#f` or `(spill-options max-bytes dir on-failure)`. `(collector-push! c bytes)`: add the length to `total`; `overflows` is `retained + length > max-bytes`, computed before the chunk is stored; when spilling is enabled and (`overflows` or a spill file is open), run rule 10 with this chunk; append the chunk; then drop whole chunks from the head, or trim the head chunk, until at most `max-bytes` bytes are retained, and mark the collector as having dropped data. The retained window is always exactly the last `max-bytes` bytes of the stream.
10. Spilling: if `total` exceeds the spill cap, close and delete the spill file and disable spilling for good. Otherwise, on first use, create `<dir>/dsh-subprocess-<harness pid>-<counter>-<12 random hex digits>-<label>.log` exclusively with mode `0600` (the counter is per provider and starts at 1) and write every chunk retained so far, then write the new chunk. The path is published only after the file was opened. Any I/O failure discards the spill (close, delete, disable), calls `on-failure` once with the exception and the label, and never interrupts collection; a failing `on-failure` is reported on the error port.
11. `(collector-read-from c from-byte)`: `window-start` is `total - retained`; `lossy?` is `from-byte < window-start`; the text is the whole retained tail when lossy, else the bytes from `from-byte - window-start`, decoded as UTF-8 with U+FFFD for invalid sequences (a cut may split a character); `next-offset` is `total`; `spill-path` is the file's path while one exists. `(collector-seal! c)` closes the spill file and is idempotent; a failed close stops advertising the path. `(collector-finalize! c)` seals and returns a `collected-output` whose `truncated?` is the dropped mark. The default spill directory is a private directory `dsh-subprocess-XXXXXX` (mode `0700`) under the system temporary directory, created at first use and removed at provider disposal only if empty.

**Local provider: lifecycle** (R8 H3; `spawn.ts:275-470`)

12. Termination, by `subprocess-handle-terminate!` or by the spec's cancel event, runs at most once and never after the range was observed empty: send `SIGTERM` to the group (`killpg` through the FFI), start a `grace-ms` timer, then send `SIGKILL`. The timer is not stopped when the direct child exits, so survivors in the group are still killed; it is stopped when the range is observed empty.
13. Settlement: when the direct child exits (the `subprocess` value becomes ready), wait until every collected or piped output stream reached end of file, but at most `grace-ms`; then close the collected ports, seal both collectors and make `subprocess-handle-done` ready with the outcome. Collected output stays readable afterwards.
14. Exit facts. Racket reports one integer `status` and encodes a death by signal `n` as `128 + n`. The outcome is `(subprocess-outcome #f "<SIGNAME>")` when `status > 128` and `status - 128` is the number of a signal this handle sent to the range (`SIGTERM`, `SIGKILL`; for a terminal also the signals of rule 25); otherwise `(subprocess-outcome status #f)`. A process killed by a signal the handle did not send therefore reports exit code `128 + n` (Racket design notes).
15. `subprocess-handle-wait-for-exit`: one shared observation per handle polls every 15 ms. The range is empty when `killpg(pgid, 0)` fails with `ESRCH`, or, on Linux once the direct child settled, when a scan of `/proc/*/stat` finds at least one process of the group and every one found is in state `Z`, `X` or `x`. `EPERM` counts as alive. The result is `#t` when the range is empty and `#f` when `#:cancel` fired first. Observing the empty range stops the grace timer and releases the handle's custodian.
16. Reads through `subprocess-handle-collected` are valid at any time, before and after settlement. `subprocess-handle-terminate!` after the range is gone does nothing.
17. The provider keeps every handle until its `done` settled and its range was observed empty.

**Local provider: lookups** (R8 H6; `subprocess-local/src/index.ts:168-205`)

18. `runtime-resolve-executable`: an empty command raises `subprocess-local: executable must be non-empty`; a relative command that contains `/` raises `subprocess-local: command <command as JSON string> is a relative path; use an absolute path or a bare PATH name`; candidates are the absolute path itself, or each entry of `PATH` in the scrubbed environment with `env` applied (a relative entry resolves from the harness working directory) joined with the command; the first regular file with execute permission is returned; otherwise the executable not found error `subprocess-local: command <JSON> is not an executable file` (absolute) or `subprocess-local: command <JSON> was not found on PATH`. The cancel event is checked before each candidate and before the final raise.
19. `runtime-terminal-environment` returns `(terminal-environment 'posix shell)` where `shell` is `$SHELL` of the harness when it names an executable file, else `#f`.

**Local provider: terminals** (R8 H7; `subprocess-local/src/terminal.ts`, `process-inspector.ts`; R20 "Pseudo-terminals")

20. Allocation: `openpty(3)` through the FFI gives a master and a slave descriptor; set the window size with `ioctl(master, TIOCSWINSZ, {rows, cols, 0, 0})` (`#x5414` on Linux, `#x80087467` on macOS); wrap both in ports with `unsafe-file-descriptor->port`; start `setsid -c <argv…>` with the slave as stdin, stdout and stderr, `subprocess-group-enabled` false, custodian mode `'kill`, the spec's cwd and environment; close the parent's slave ports. Because the child is not a group leader, `setsid(1)` calls `setsid(2)` in place and then `exec`s, so `terminal-handle-pid` is the pid of the shell, which is the leader of its own session with the slave as controlling terminal. The program is resolved and checked as in rule 5. An empty argv raises `SUBPROCESS_INVALID_ARGV` `subprocess-local: terminal argv must contain a program`. A missing `openpty` binding or `setsid` program raises `SUBPROCESS_PTY_UNAVAILABLE` `subprocess-local: terminals are unavailable because the pseudo-terminal bindings cannot be loaded: <detail>` (dsh names node-pty at that place). The spec's cancel event governs allocation only. macOS has no `setsid(1)`; there the wrapper is `/usr/bin/script -q /dev/null <argv…>` and the handle's pid is the wrapper's (untested).
21. The child environment is rule 3 with the spec's `env` applied and then `TERM` set to `terminal-type`.
22. `terminal-handle-output` is the master's input port; a read error `EIO` after the slave closed is end of file. Exit is detected by polling `subprocess-status` every 15 ms, because a child that changed its session is not reported to `sync` (R20). `terminal-handle-done` becomes ready with the outcome of rule 14 after the exit was observed.
23. `terminal-handle-write!` writes the text as UTF-8 to the master and flushes, with no newline conversion. `terminal-handle-resize!` repeats the `ioctl`. Both raise `terminal process has exited` once the terminal exited.
24. `terminal-handle-inspect-foreground` (Linux): read `tpgid` from `/proc/<pid>/stat` (the eighth field after the parenthesised command); none or not positive gives `#f`. `input-waiting?` is true when some thread of some process of that group is blocked in a system call that waits on descriptor 0: read `/proc/<p>/task/<t>/syscall` (ignore `running` and lines starting `-1 `), parse the call number and up to six hexadecimal arguments, and apply `syscallWaitsOnStdin` with the tables of `process-inspector.ts:321-357` (`read` on descriptor 0; `select` and `pselect` whose read set, read from `/proc/<p>/mem`, has bit 0; `poll` and `ppoll` whose array holds descriptor 0 with `POLLIN`; `epoll_wait` and `epoll_pwait` whose `fdinfo` lists `tfd: 0`). Any unreadable file means not waiting. macOS: `/bin/ps -o tpgid= -p <pid>`, and `input-waiting?` is always `#f`.
25. `terminal-handle-signal-foreground!` resolves the foreground group; none raises `cannot resolve foreground process group for terminal <pid>`; `SIGKILL` aimed at the shell's own group raises `refusing to SIGKILL the terminal shell; terminate the terminal session instead`; otherwise `killpg` and return the group id.
26. `terminal-handle-terminate!` is memoised: collect the descendants of the shell and the members of its session from `/proc` (each identified by pid and start time), send them `SIGTERM`, wait up to `grace-ms`, send `SIGKILL` to the survivors, then `SIGTERM` and after the same grace `SIGKILL` to the shell, then sweep once more; close the master ports. If the shell is still alive raise `terminal cleanup failed; surviving pid: <pid>`; if other tracked processes are, raise `terminal cleanup failed; surviving pids: <pids joined by ", ">`. `terminal-handle-inspect-activity` returns `(terminal-activity 'unknown n)` where `n` increases by one with every write, in this port.

**Local provider: disposal and control channel**

27. Provider disposal (`index.ts:135-166`): terminate every live handle and wait for its `done` and its `wait-for-exit`; terminate every terminal; close every control channel; on any failure shut down every handle custodian (the counterpart of the synchronous host-exit kill) and re-raise, as one `exn:fail:terminal-cleanup` with message `local subprocess teardown failed` when several failed. The handle custodians are the backstop: a provider or caller fiber that is shut down without running this inverse still kills each direct child's group.
28. Control channel (`subprocess/src/control.ts`): with `control?` the child receives a duplex byte channel on descriptor 7 and the variable `DSH_SUBPROCESS_CONTROL=pipe`, as in dsh. Racket cannot pass a fourth descriptor, so the provider listens on `127.0.0.1` port 0, creates a random 32-hex-digit token and starts `bash -c 'exec 7<>"/dev/tcp/127.0.0.1/$1" || exit 126; printf "%s\n" "$2" >&7; shift 2; exec "$@"' bash <port> <token> <argv…>` in place of the argv. It accepts connections until one sends the token line within `grace-ms`, closes the listener, and exposes that connection as `subprocess-handle-control`. No valid connection in time is a launch failure `SUBPROCESS_SPAWN_FAILED` `cannot open the control channel for <argv[0] as JSON string>`. The trampoline is argv element 0 to 5 of the real launch; consumers see the argv they asked for.

**Sandbox: writable roots and runner argv** (R8 G1, "Sandbox runner argv"; `sandbox/src/roots.ts`, `sandbox-local/src/profiles.ts`)

29. `(canonical-path p)` is `realpath(3)` of `p`, or `p` itself when resolution fails. `(workspace-writable-roots policy)` is `'()` unless the mode is `workspace-write`; otherwise the canonical workspace root followed by each additional root, without duplicates, order kept. Each additional root must resolve (`cannot read the directory: <error text>`), be a directory (`expected an existing directory`) and equal its own physical path (`use the physical directory path <JSON string>; symlinked grants are not supported`); each failure is the invalid root error with that detail.
30. `(writable-roots policy)` is `'()` unless `workspace-write`; otherwise rule 29's list followed by `(canonical-path "/tmp")` and the canonical system temporary directory, without duplicates.
31. `(bwrap-profile-args policy)`: `--ro-bind / / --dev /dev --unshare-pid --proc /proc --die-with-parent`, and for `workspace-write` also `--tmpfs /tmp` and `--bind <root> <root>` for each root of rule 29.
32. `(landlock-profile-args policy)`: `--ro /`, `--rw /dev/null`, and for `workspace-write` also `--rw /tmp` and `--rw <root>` for each root of rule 29.
33. `(seatbelt-profile-args policy)`: `-p <profile>` where the profile is these forms joined by one space: `(version 1)`, `(allow default)`, `(deny file-write*)`, `(allow file-write* (literal "/dev/null"))`, and, when rule 30's list is not empty, `(allow file-write* (subpath "<r1>") (subpath "<r2>") …)`. Inside an SBPL string `\` and `"` are escaped with a backslash.
34. Runner argv and classification tables (`sandbox-local/src/index.ts:225-260`). The confined argv is the runner prefix, then `--`, then the caller's argv.

| Runner | Prefix | Enforcement | Denial signatures | Runner failure rules |
|---|---|---|---|---|
| bwrap | `bwrap` + rule 31 | full | `read-only file system` | fatal `bwrap: ` |
| landlock | launcher path + rule 32 | probe result | `permission denied` | allowed exit codes `(125)`, fatal `landlock-run: `, informational `landlock-run: partial enforcement (older Landlock ABI)` |
| seatbelt | `sandbox-exec` + rule 33 | full | `operation not permitted` | fatal `sandbox-exec: ` |
| `runnerCommand` | the configured list + rule 31 | full | `read-only file system`, `permission denied` | fatal: the configured `runnerFailureSignatures` |

None of the profiles restricts network access.

**Sandbox: selection and `confine`** (R8 G2; `sandbox-local/src/index.ts:262-300`, `:546-594`)

35. Chains by platform (`(system-type 'os*)`): `linux` is bwrap then landlock, `macosx` is seatbelt, anything else is empty. An empty chain is unavailable. A chain of one is selected without a probe with its static enforcement. Otherwise probe in order and take the first usable: the bwrap probe runs `bwrap <rule 31 for read-only on /> -- true` with stdio ignored and succeeds on exit 0 within `probeTimeoutMs`; a missing `bwrap` is unusable. The verdict, including "unavailable", is computed once per provider and cached. Probes run under `blocking`.
36. The Landlock launcher is located in this order: `x-racket.landlockLauncher`; the file `racket/dsh-exec/native/bin/landlock-run` (a `define-runtime-path`), which `make -C racket/dsh-exec/native` builds from `native/system/packages/entry/src/main.c` with `cc`; `landlock-run` on `PATH`. No launcher is unusable. The probe runs `<launcher> --probe` and maps exit 0 to `'partial` when stdout contains `partially enforced` and to `'full` otherwise, and any other exit or a timeout to unusable (`native/system/docs/cli-contract.md`). The build is never run implicitly.
37. `sandbox-provider-confine` of the local provider: raise the cancel reason when cancelled; replace the workspace root by its canonical path; with `runnerCommand`, return its row of rule 34 without any probe; otherwise select (rule 35), raise the sandbox unavailable error for the policy's mode when nothing is usable, and return the selected row. It never returns the caller's argv unprefixed.

**Sandbox: escalation** (R8 G3; `sandbox/src/escalation.ts`, `locales.ts`)

38. `validate-escalation-args`, all with code `SANDBOX_ESCALATION_INVALID_ARGUMENT`: permissions without justification: `invalid escalation: sandbox_permissions requires a justification`; justification alone: `invalid escalation: justification is only valid together with sandbox_permissions`; a justification that is blank after trimming: `invalid justification: expected a non-empty sentence`.
39. `approve-escalation`, in order: requested equal to effective returns it with no approval; a requested mode outside `(wider-modes effective)`: `INVALID_ARGUMENT` `sandbox escalation to "<m>" is not strictly wider than this call's current "<e>" mode`; no approver: `SANDBOX_ESCALATION_UNAVAILABLE` `sandbox escalation to "<m>" requires approval, but no approval service is composed`; no agent: the same code, `sandbox escalation to "<m>" requires approval, but the call has no agent to route it through`. Then `(tool-approval-request approver (approval-request agent tool-name call-id reason display-reason cancel))` with reason `escalate sandbox to <m>: <justification>` and display reason `(escalation-display-reason m justification)`, whose eight texts are those of `locales.ts` verbatim (English: `Allow this operation with <m> permissions: <justification>`). Nothing runs before the grant.
40. Outcomes: `'allowed-once` returns the mode, valid for this call only; `'rejected`: `SANDBOX_ESCALATION_REJECTED` `the user rejected escalating this <subject> to "<m>"; it stays denied, so stop and explain instead of working around it`; `'cancelled`: raise the cancel reason when the call's cancel event is ready, else `SANDBOX_ESCALATION_CANCELLED` `approval for escalating to "<m>" was cancelled`; `'unavailable`: `SANDBOX_ESCALATION_UNAVAILABLE` `sandbox escalation to "<m>" requires approval, but no approval channel is available`. Markers: `(sandbox-denial-marker mode)` is `[sandbox: file access denied under <mode> mode]`; `(escalation-hint-marker subject)` is `[sandbox: escalation available — retry this exact <subject> once with sandbox_permissions (the narrowest wider mode that suffices) + justification; the approval prompt asks the user]`.

**Sandbox: diagnostics** (R8 G4; `sandbox/src/diagnostics.ts`)

41. `classify-runner-failure` returns `#f` for an exit code that is `#f` or 0. Otherwise split stderr on `\r?\n`; for each rule in order skip it when it has allowed exit codes that do not include the code; for each line in order skip a line equal, ignoring case, to an informational line; return the first line that contains, ignoring case, a fatal signature that is not blank.
42. `matches-signature?` is false for an exit code that is `#f` or 0, else true when stderr contains, ignoring case, any signature.
43. `(runner-spawn-failure? v runner-program workdir)`: `runner-program` not `#f`, `workdir` an existing directory the user may enter, `v` an `exn:fail:spawn` whose errno is `ENOENT` or `EACCES`, and either its path equals `runner-program` with syscall `spawn` or `spawn <runner-program>`, or it has no path and its syscall is `spawn <runner-program>`.

**Sandbox policy service** (R8 "`ctx.sandboxPolicy`", G5; `sandbox-policy/src/index.ts`)

44. Construction: the workspace root is the config value or the harness working directory (without a trailing separator); it must be absolute and free of NUL. Additional roots must each be absolute and free of NUL; they are deduplicated in order and stored as `#f` when empty.
45. `sandbox-policy-resolve`: the mode is `#:mode`, else the session's override (rule 47), else the default mode; the workspace root is the session header's `cwd` when the session has one (not absolute or holding NUL raises the invalid root error with subject `sandbox workspace root` and detail `the Session working directory must be an absolute execution-world path without NUL bytes`), else the configured root; the additional roots are the configured ones followed by this session's live registrations, validated and deduplicated as in rule 44, `#f` when empty; the session id is the session's id when a session is given.
46. `sandbox-policy-register-writable-root!` validates the directory as in rule 44 and, inside one effect on the caller's context, adds a registration for that session; the inverse removes exactly that registration. Registrations are kept in a weak table keyed by the session object, are runtime-only and are not restored on resume or fork.
47. The projection `sandbox-mode-projection` is `(projection-definition "sandboxMode" 1 (lambda (header n) 'null) apply #f #f)` whose `apply` returns `data.mode` for a `sandbox/mode` event and the state otherwise. `set-sandbox-mode!` appends `(sandbox/mode #:mode mode #:source source)`. Precedence of modes is therefore: approved per-call mode, then the session's last `sandbox/mode`, then the deployment default.
48. Runtime context: `(system-prompt-context! c (make-prompt-context #:name "sandbox:policy" #:order (system-prompt-context-order c 'SANDBOX_POLICY) #:text …))`, order 110. The text is `""` when the assemble context has no agent, else `(render-policy-context (sandbox-policy-resolve … #:session (agent-session agent)))`, one of the three strings of `sandbox-policy/src/index.ts:61-79`: `Current DSH file policy: read-only. Any available operation enforced by the DSH file sandbox cannot modify files in the standing mode. Do not refuse a required modification from this policy alone: try an available tool normally and follow any denial and escalation guidance it returns.`; `Current DSH file policy: workspace-write. Any available operation enforced by the DSH file sandbox may modify files under the session workspace: <root as JSON string>.` then, with additional roots, ` Additional writable directories: <JSON array>. On Windows, these additional grants apply to file tools only, not sandboxed processes.` and always ` Some platform temporary areas may also be writable.`; `Current DSH file policy: danger-full-access. The DSH file sandbox does not restrict file modifications by available operations.`

**Shell executors** (R8 I1 to I3, I5; `bash-local/src/index.ts`, `bash-sandbox/src/index.ts`, `shell/src/render.ts`)

49. `shell-executor-resolve` of the local executor reads the volatile config at call time. First each of `timeoutMs`, `maxTimeoutMs`, `maxOutputBytes`, `maxSpillBytes`, `graceMs` must be positive and finite (`bash-local: <field> must be a positive finite number`) and `graceMs` at most `max-timer-delay-ms` (`bash-local: graceMs must be no greater than 2147483647`). Then: `timeout-ms` is `(clamp-timeout request.timeout-ms timeoutMs maxTimeoutMs "bash-local: request.timeoutMs")`; `stdout-max-bytes` is the request's or `maxOutputBytes`, and must be positive and finite (`bash-local: request.stdoutMaxBytes must be a positive finite number`); `workdir` is the request's, else config `cwd`, else the harness working directory; `on-expiry` is the request's or `'kill`; `cancel`, `stdin`, `env`, `dsh-env` and `sandbox-policy` pass through.
50. The sandbox executor's `resolve` is rule 49 with `sandbox-policy` defaulted to `(sandbox-policy-resolve …)` with no session. Its `shell-executor-sandbox-mode` is the policy service's default mode read once at construction; the local executor's is `#f`.
51. `shell-executor-execute` of the local executor runs `("bash" "-c" command)`. With `on-expiry` `'kill` it makes one deadline `(make-deadline spec.cancel timeout-ms "BASH_TIMEOUT")` and spawns with its event; `timed-out?` is true exactly when that event's reason is this deadline's `timeout-reason`, and `aborted?` when the event is ready and not timed out. With `'none` there is no timer, the spawn event is `spec.cancel`, `timed-out?` is always false and `aborted?` is whether `spec.cancel` is ready. The deadline is disposed at settlement.
52. Preparation (used by the sandbox executor): when the argv is produced by a procedure `(-> evt? (listof string?))`, it runs raced against the spawn event. If the event fires first, or the procedure raises, and the cause is this execution's timeout, the execution is returned already settled with exit code `#f`, signal `#f`, empty output and `timed-out?` true; any other failure is raised from `shell-executor-execute` after disposing the deadline.
53. The spawn spec: the argv; cwd `workdir`; stdin `(stdin-data spec.stdin)` or `'ignore`; stdout `(collect-mode stdout-max-bytes maxSpillBytes)`; stderr `(collect-mode maxOutputBytes maxSpillBytes)`; `grace-ms` `graceMs`; the spawn event; env `bash-env-overrides` (`NO_COLOR=1`, `TERM=dumb`, `PAGER=cat`, `GIT_PAGER=cat`), then `spec.env`, then `spec.dsh-env`, later entries winning.
54. Settlement: when the handle's `done` yields an outcome, the status becomes `'killed` if the spawn event is ready or the outcome has a signal, else `'completed`, unless `shell-execution-kill!` already set `'killed`; exit code and signal are copied; the `on-process-done` hook of rule 61 runs; then `shell-execution-done` becomes ready. `shell-execution-kill!` returns `#f` unless the status is `'running`; otherwise it sets `'killed`, terminates the handle and returns `#t`.
55. Provider failure: a synchronous raise of `subprocess-spawn`, or a `done` that raises when this execution was not already killed or cancelled, settles the execution as `'killed` and records the note `subprocess failed before reporting an outcome: <(error->js-string failure)>` (`unprintable provider failure` when that raises). From then on `(shell-execution-observed e 'stderr)` serves the note as the whole stderr stream (`next-offset` its byte length, never lossy), and `shell-execution-result` raises the original failure. A `done` that raises after the execution was killed or its event fired settles it as `'killed` without a note.
56. `shell-execution-read-output!` reads both collectors from its private offsets and advances them. `err` is the stderr delta followed, once, by the provider-failure note (preceded by a newline when the delta is not empty and does not end in one). The delta is the stdout text followed, when `err` is not empty, by a newline if the stdout text is not empty and does not end in one, then `[stderr]\n` and `err`. `lossy?` is true when either read was lossy; the spill paths are those of the two reads.
57. `shell-execution-result` waits for settlement and returns `(shell-run-result exit-code signal timed-out? aborted? spec.timeout-ms stdout stderr #f)` where each stream is `(collector-read-from … 0)` as a `collected-output` with `truncated?` the lossy flag (the text is then the tail). It is computed once.
58. Sandbox executor, `danger-full-access`: run rule 51 unchanged and add `(shell-sandbox-info mode #f #f absent)` to the result.
59. Sandbox executor, confined modes: preparation calls `(sandbox-confine … '("bash" "-c" command) policy #:cancel evt)` and checks the event again; the returned argv is spawned. The result is decorated: if no argv was confined (a preparation timeout) the sandbox info is `(mode, denied? #f)`; if `(classify-runner-failure exit-code stderr-text rules)` matches, raise the sandbox unavailable error with that line as detail; otherwise the info is `(shell-sandbox-info mode (matches-signature? exit-code stderr-text denial-signatures) enforcement absent)`.
60. Sandbox executor, a failing result: when the spec's cancel event is ready raise its reason; when an argv was confined and `(runner-spawn-failure? failure (car argv) workdir)` holds, raise the sandbox unavailable error with detail `(error->js-string failure)`; otherwise re-raise.
61. Background facts: when a confined process settles, before `shell-execution-done` becomes ready, the executor sets `shell-execution-sandbox` to `(shell-sandbox-info mode denied? enforcement runner-failed?)` where `runner-failed?` is rule 43 on the failure for a provider failure and rule 41 on the collected stderr otherwise, `denied?` is rule 42 and is false when the runner failed, and `runner-failed?` is `#t` or absent. Facts are kept per execution, never per executor.
62. `(parse-exit-status text)`: text matching `\n\[killed by signal: ([^\]\n]+)\]$` gives the body before the match and that signal; else text matching `\n\[exit code: (\d+)\]$` gives the body and that number; else the whole text and exit code 0.

**Shell environment** (R8 "`ctx.shellEnv`", "Shell environment"; `shell-env/src/index.ts`)

63. `shell-env-register!` validates inside its effect and raises, in order: a name that is blank after trimming: `bash env contributor name must be non-empty`; a registered name: `bash env contributor "<name>" is already registered`; for each variable in order: a key that does not start with `DSH_` or whose rest does not match `^[A-Z][A-Z0-9_]*$`: `bash env contributor "<name>" declared invalid key "<key>"`; a reserved key: `bash env contributor "<name>" cannot own reserved key "<key>"`; a blank description: `bash env contributor "<name>" must describe "<key>"`; a key owned by another contributor: `bash env key "<key>" is already owned by contributor "<owner>"; contributor "<name>" cannot also own it`. The inverse removes the contributor and its keys. Reserved keys: `DSH_HOME`, `DSH_SHELL`, `DSH_SESSION_ID`, `DSH_PROFILE`, `DSH_PROFILE_DIR`, `DSH_INSTALL_DIR`, `DSH_NODE_EXECUTABLE`.
64. `shell-env-collect` starts with `DSH_HOME` (the resolved Harness home) and `DSH_SHELL=1`; adds `DSH_SESSION_ID`, the session header's id, when the execution has an agent; and, when a `profileContext` service is mounted, `DSH_PROFILE` (its name), `DSH_PROFILE_DIR` (its directory) and `DSH_INSTALL_DIR` (the directory of its install anchor).
65. `DSH_NODE_EXECUTABLE` is set to the absolute path of `node` when `dsh-util`'s Node locator finds one, and omitted otherwise, as dsh omits it in a single-executable build. dsh sets it to the runtime that runs the harness; this port has no such runtime.
66. Then each contributor, in `string<?` order of name, is asked to resolve: a returned key it did not declare raises the shell env error `bash env contributor "<name>" returned undeclared key "<key>"`; a value that is not a string raises `bash env contributor "<name>" returned a non-string value for "<key>"`. The result is sorted with `dsh-env-key<?`, which compares character by character with `_` before digits before letters (the order `localeCompare` gives this alphabet). `shell-env-list` returns one `{contributor, description, key}` per contributed variable in the same order; built-ins are not listed.

**The one-shot `bash` tool** (R8 "`bash` — one-shot", I4; `tool-bash/src/index.ts`, `render.ts`, `background.ts`)

67. Mount: `default-mode` is `(shell-sandbox-mode shell)`, read once. `escalation-modes` is `escalation-targets` when it is not `#f`, else `'()`. When it is not `#f` and no `sandboxPolicy` service exists, raise `tool-bash: the mounted bash executor confines but ctx.sandboxPolicy is missing`. `promote?` is `promoteOnTimeout` and `enableRunInBackground`. Register the system prompt section.
68. Registration follows the job registry (`index.ts:565-583`). With `enableRunInBackground` false: register the foreground-only definition (`jobs` `#f`) and stop. Otherwise register the foreground-only definition now when no `jobs` service exists, and `(ctx-inject ctx '(jobs) …)`: when the registry appears, unregister the foreground-only definition and register the job-backed one; when it unloads, unregister that and, if this plugin's fiber is still `'active`, register the foreground-only definition again.
69. `execute` first computes `standing`: `(sandbox-policy-resolve … #:session (agent-session agent))` (no session without an agent), or `#f` under a non-confining executor. Validation, in order: a command blank after trimming: `invalid command: expected a non-empty string`; a blank description: `invalid description: expected a non-empty string`; a `timeoutMs` that is not a positive finite number: `invalid timeoutMs: expected a positive number, got <JSON text>`; then, unless `sandbox_permissions` is given and equals the standing mode, `validate-escalation-args` with the justification treated as omitted when `sandbox_permissions` is absent and the justification is blank.
70. Escalation: when both fields are present, a non-confining executor raises `SANDBOX_ESCALATION_UNAVAILABLE` `sandbox_permissions is not available in this composition (no sandboxing executor to escalate)`; otherwise `approve-escalation` with subject `command`, tool name `bash`, the standing mode as effective mode, `(ctx-get ctx 'approval)` as approver, the execution's agent, call id and cancel event. The call's policy is the standing policy with the approved mode substituted.
71. Working directory: `cwd` is `(working-directory-ensure port agent cancel)` with an agent, else none. `workdir` is `cwd` when the argument is absent; the argument as is when it is absolute or there is no `cwd`; otherwise `<cwd>/<argument>` joined with one separator and not normalised.
72. The request: `command`, `workdir` when known, `timeoutMs` when given, `dsh-env` `(shell-env-collect shellEnv exec)`, `sandbox-policy` when a policy exists.
73. `run_in_background: true`: disabled raises the `JOB_BACKGROUND_DISABLED` error; no registry raises the context unavailable error; a ready cancel event raises the abort error; otherwise `spec` is `(shell-resolve shell request)` with `on-expiry` `'none`, the job of rule 78 is started, and the value is `{kind: "background", jobId, cwd: spec.workdir}`. The process is spawned inside the job's `run`, after admission, with the job's own cancel source.
74. Foreground with a registry and `promote?`: resolve with `on-expiry` `'none` and start the same job; if `job-start!` raises, log at `warning` `bash: job registration refused, running in the foreground with the timeout kill instead: <text>` and continue with rule 75. Otherwise `(job-wait registry id spec.timeout-ms owner cancel)`. If the wait raises: kill the job with reason `tool call aborted`, wait again (same timeout, no cancel), remove the record when it settled, and raise the abort error. If the view is `running` or `stopping` and no process was published yet: kill with `timed out during preparation`, wait, remove when settled, and return the foreground value with `exitCode` null, `signal` null, `timedOut` true, `aborted` false, empty streams and `sandbox: {mode, denied: false}` when a policy exists. If still `running` or `stopping`: one `job-read!`, and the value is `{kind: "promoted", cwd, jobId, timeoutMs, output}` with `output` `(render-job-read (ring-delta chunks) lossy? spill-paths (shell-execution-sandbox process) escalation-modes)`. Otherwise remove the record; with no published process raise the recorded launch failure through rule 78's mapping, or `exn:fail` with the view's detail; else the value is the foreground value of the process's result (failures through the same mapping), with `stopped` set to the reason when a kill from outside this call ended the job.
75. Plain foreground: `spec` is `(shell-resolve shell request)` with the execution's cancel event; `(shell-execution-result (shell-execute shell spec))`; a failure goes through rule 78's mapping; `aborted?` raises the abort error; else the foreground value.
76. `(render-result value escalation-modes)` (`render.ts:28-63`): each stream's text is its text, plus `\n[output truncated; full output: <spillPath or "(unavailable)">]` when truncated. The body is the stdout text; a non-empty stderr text is appended as `[stderr]\n<stderr>` after one newline separator when the body is not empty and does not end in one; an empty body becomes `(no output)`. Markers, in this order, one per line: the denial marker, then the escalation hint with subject `command` when escalation modes exist, if `sandbox.denied`; `[timed out after <timeoutMs>ms]` if `timedOut`; `[stopped: <reason>]` if `stopped` is present; `[killed by signal: <signal>]` if `signal` is not null, else `[exit code: <exitCode>]` if `exitCode` is not 0 (a null exit code prints `null`). With no marker the result is the body; otherwise the body, a newline unless it ends in one, and the markers joined by newlines.
77. `(render-promoted value)`: the output, with a newline added when it is not empty and does not end in one, then `[still running after <timeoutMs>ms; moved to background job <jobId>]`. `(render-job-read delta lossy? spill-paths sandbox modes)`: notices are `[some output was dropped from memory; full output: <paths joined by ", " or "(unavailable)">]` when lossy; then `[sandbox: the sandbox runner itself failed under <mode> mode — the command did not run; this is a sandbox problem, not a command failure]` when the runner failed, else the denial marker and hint when denied; the result is the delta, a newline when it is not empty and does not end in one, and the notices joined by newlines, or the delta alone without notices. `(ring-delta chunks)`: the texts of the chunks whose channel is not `stderr`, concatenated, then, when the stderr texts are not empty, a newline separator as in rule 56, `[stderr]\n` and the stderr texts.
78. The job (`background.ts`): `(job-start-spec "bash" command call-id root-call-id owner sources run)` where `owner` is the agent's id or `#f`, `sources` are two `job-output-source`s reading `shell-execution-observed` of the published process (an empty read at the requested offset before it exists), and `run` starts a task that calls `(shell-execute shell spec-with-job-cancel)`, kills the process if the job was cancelled meanwhile, waits for `shell-execution-done`, and yields `(process-outcome process escalation-modes)`: status `killed` with detail `signal: <SIG>` or `killed before exit`, else `completed` with `exit code: <n>` (0 for null); the sandbox notes of rule 77 are appended to the detail after `; `, joined by a space. A failure before a process exists yields `killed` when the job was cancelled, else `failed`, with the exception message as detail, and is remembered as the launch failure. `cancel` records the reason as `stopped`, fires the job's cancel source once and kills the process. Launch-failure mapping: the cancel reason itself is re-raised unchanged when the call was cancelled with it; otherwise `(subprocess-spawn-failure failure "bash")`: an `exn:fail:spawn` with errno `ENOENT` becomes `SUBPROCESS_SPAWN_NOT_FOUND` `cannot start "bash": the program or the working directory does not exist (<message>)`, any other `exn:fail:spawn` becomes `SUBPROCESS_SPAWN_FAILED` `cannot start "bash": <message>`, and every other value is returned unchanged.

**Terminal registry** (R8 "`ctx.terminals`", J1, J2; `terminal/src/index.ts`)

79. Backends are kept by type. Session ids are `pty-<n>` from one counter per service value starting at 1.
80. `terminals-spawn`, in order: disposing raises `SERVICE_DISPOSING` `PTY service is disposing`; when an `agents` service exists, the owner must be the registered agent of its id, else `OWNER_NOT_LIVE` `agent "<id>" is not the registered PTY owner`; install the owner cleanup effect once per owner; an unknown type raises `NO_BACKEND` `no PTY backend registered for "<type>"`; a name already used by a published session of this owner raises `DUPLICATE_NAME` `PTY session name "<name>" already exists for this owner`, and one reserved by a spawn in flight raises `PTY session name "<name>" is already being created`; reserve the name and a pending-spawn record with its own cancel source fused with `#:cancel`; mint the id; call the backend's `spawn`. After it returns, re-check the caller's cancellation, disposal (`SERVICE_DISPOSING`) and owner liveness (`OWNER_NOT_LIVE` `PTY owner is no longer live`) before publishing. On any failure close the unpublished session with reason `PTY spawn rolled back` and raise the cancellation reason in preference to the failure. The result is the snapshot plus `motd`.
81. Per-session operations check `NO_SESSION` and `FOREIGN_SESSION` first. `terminals-start-send`: a closing session raises `SESSION_CLOSING` `PTY session <id> is closing`; an active send raises `SEND_ACTIVE` `PTY session <id> already has an active send`; the record's active mark clears when the operation's `done` settles. `terminals-read` and `terminals-signal!` delegate to the session. `terminals-kill!` closes the session with the reason, waits, removes the record, and returns `#f` when the same close was already in flight. `terminals-list` returns the owner's snapshots in creation order. `terminals-has-owner-activity?` is true for a published session or a spawn in flight.
82. Owner disposal (the effect on `(agent-ctx owner)`) aborts that owner's pending spawns with `OWNER_NOT_LIVE` and closes its sessions. Service disposal sets disposing, aborts every pending spawn with `SERVICE_DISPOSING`, closes every session and waits; failures are collected into one `exn:fail:terminal-cleanup`. Sessions are in-process only and do not survive a restart.

**Terminal bash backend** (R8 J3 to J9, G6, "Shell environment"; `terminal-bash/src/{index,session,sanitize,config}.ts`)

83. Config resolution: `shellPath` empty or absent is `/bin/bash`; `shellArgs` empty or absent is the default list; then `validateConfig`'s checks.
84. Backend spawn: install the mode fence for the owner (rule 88); `policy` is `(sandbox-policy-resolve … #:session (agent-session owner))`; argv is the shell path and arguments, passed through `sandbox-confine` unless the mode is `danger-full-access` (no `sandbox` service then raises `NO_SANDBOX` `terminal-bash: sandbox mode "<mode>" requires a ctx.sandbox provider in the execution world`); spawn a terminal with that argv, cwd the spec's or `(working-directory-ensure port owner cancel)`, rows, cols, terminal type `dumb`, grace `disposeGraceMs` and the environment `TERM=dumb`, `PAGER=cat`, `GIT_PAGER=cat`, `DSH_SHELL=1`, `DSH_SESSION_ID=<owner agent id>`, `DSH_PTY_SESSION_ID=<pty-N>`, `PS1` equal to `dsh> ` (five characters), `PROMPT_COMMAND` equal to `printf "\033]133;D;%s\007" "$?"; PS1='dsh> '`, and `BASH_SILENCE_DEPRECATION_WARNING=1`.
85. Startup: one empty send without submit must settle by readiness; a session exit raises `STARTUP_EXITED` and a timeout raises `STARTUP_TIMEOUT` (messages at `terminal-bash/src/index.ts`, verbatim); its viewport is the `motd`. A startup failure closes the terminal first; a failed cleanup raises `exn:fail:terminal-cleanup` carrying both failures.
86. Send (`session.ts:328-432`): a closing session raises `SESSION_CLOSING`, an exited one `SESSION_EXITED`, an active one `SEND_ACTIVE`; a ready cancel event raises an `exn:fail:abort` `PTY send aborted before write`; arm an absolute deadline of `timeoutMs` that settles the operation with wait reason `timeout`; inspect the foreground group; write the text followed by `\r` when `submit?`; reset the readiness evidence; poll every `pollIntervalMs`.
87. Readiness poll (`session.ts:554`), first match wins: (a) the session exited: `session_exit`; (b) prompt path: a prompt marker was seen since the write, the printable text after the latest marker is exactly `dsh> `, no output arrived for at least `pollIntervalMs`, and the foreground group is the shell's group (learned the first time a prompt is seen): `stdin_read`; (c) exact path: at least `exactProbeAfterMs` elapsed and the foreground group is waiting on terminal input, and, if it is the group that was already waiting before the write, it was observed not waiting in between, and, during startup, some output arrived: `stdin_read`; (d) silence path: no output for `idleSilenceMs`, plus `handoffGraceMs` if a marker was seen, plus `promptTailGraceMs` if the text after the marker is a strict prefix of `dsh> `: `inferred_idle`. The result is `(send-result viewport reason status truncated?)` where the viewport is the operation's buffer, the last `maxReadBytes` bytes of its output.
88. Mode fence (`index.ts:37-60`): one `internal/dispatch` listener per owner, registered with `#:global? #t` on the owner's context. For a `session/event` dispatch whose session is the owner's and whose event is `sandbox/mode`, while the owner has an open or pending terminal session and the event's mode differs from the current effective mode, raise `cannot change sandbox mode from "<a>" to "<b>" while persistent terminal sessions are open or being created; wait for creation to settle and close them first`. The store resolves listeners before it commits (dsh-session rule 10), so the raise rejects the append and the log is unchanged.
89. Output path: bytes are decoded as streaming UTF-8 and fed to the responder of rule 93 and to the sanitizer (`sanitize.ts`). The sanitizer removes OSC sequences (`ESC ]` to BEL or `ESC \`), CSI sequences (`ESC [` to a final byte `0x40` to `0x7E`) and two-byte escapes; an incomplete sequence is carried to the next chunk, up to `maxReadBytes` bytes, after which the rest of that sequence is discarded; an OSC whose content starts with `133;D;` sets the prompt flag and starts tracking the printable text after it; `\r\n` becomes `\n`, a lone `\r` becomes `\n` (a `\r` that ends a chunk is held to pair with a following `\n`), BEL is removed.
90. Buffers: sanitised text is appended to the session scrollback, bounded by `scrollbackMaxBytes` bytes and `scrollbackLines` newlines and evicted from the head one code point at a time, and to the active operation's buffer. `backend-session-read` (`session.ts:434`): the lines are the scrollback split on `\n` (no lines for empty text); `offset` (default 0) counts from the newest line and must be a non-negative safe integer (`PTY read offset must be a non-negative safe integer`); `count` (default 500) must be a positive safe integer (`PTY read count must be a positive safe integer`); the page is lines `max(0, total - offset - count)` up to `total - offset`, cut to its last `maxReadBytes` bytes; `line-begin` is `offset`, `line-end` is `offset` plus the number of lines returned; `truncated?` is true when the scrollback ever evicted or the page was cut.
91. Cancel: `send-operation-cancel!` or the send's cancel event sends `SIGINT` to the foreground group once any write in flight finished, then polls again at once. It does not settle the operation.
92. Close: stop polling, terminate the terminal (a failure raises `CLEANUP_FAILED` `PTY cleanup failed (<reason>)`), settle an active send with `session_exit`, and wait for the exit. `backend-session-signal!` delegates to `terminal-handle-signal-foreground!`.
93. Terminal queries: dsh answers them with a headless xterm emulator. This port answers three, writing the reply to the terminal before the next foreground inspection: `ESC [ 6 n` with `ESC [ 1 ; 1 R`, `ESC [ 5 n` with `ESC [ 0 n`, and `ESC [ c` or `ESC [ 0 c` with `ESC [ ? 1 ; 2 c`. Other queries get no reply.

**Persistent `bash` tool** (R8 K, "Persistent bash wire text"; `tool-bash-persistent/src/index.ts`)

94. One shell per owner agent, created on first use and shared through a per-owner pending creation: `(working-directory-ensure port owner cancel)`, `(terminals-spawn terminals owner #:type backendType #:cwd cwd #:cancel cancel)`, one owner cleanup effect on `(agent-ctx owner)` that clears the caches, then the setup send `stty -echo; set +H` with submit; a session exit or a `timeout` wait reason raises `INIT_REJECTED`. Any creation failure resets the owner's shell with reason `persistent bash initialization failed` and re-raises. The cancel event is the command's deadline fused with the plugin's lifetime source. Reset removes the caches and kills the session, if it is still listed, with the given reason.
95. Calls of one owner run one at a time in arrival order (a per-owner queue). A call whose cancel event is ready when its turn comes returns `""`.
96. Markers: with a fresh random UUID, `start` is `__DSH_PERSISTENT_BASH_START_<uuid>__` and `end` is `__DSH_PERSISTENT_BASH_END_<uuid>:`. `(quote-for-bash s)` is `$'…'` with `\` doubled and `'`, CR and LF written as `\'`, `\r`, `\n`. `(wrap-command command markers)` is the single line `printf '%s\n' <q start>; eval -- <q command>; __dsh_persistent_bash_status=$?; printf '%s%s\n' <q end> "$__dsh_persistent_bash_status"`.
97. Command loop (`index.ts:301-384`): one deadline `(make-deadline cancel timeoutMs "PERSISTENT_BASH_TIMEOUT")`. Get the shell; a failure that is the caller's own cancel reason returns `""`. Then repeat: if the session is listed as exited, answer as rule 100; send the wrapped line with submit the first time and an empty text without submit afterwards, and wait for the operation (a failure resets the shell with `persistent bash send failed` and re-raises); the fallback text grows by the operation's incremental output, or is replaced by its viewport when that is empty; read the newest scrollback page of 1000 lines; then, in order: the deadline timed out: rule 100's timeout text after a reset with `persistent bash command timed out`; the event is ready otherwise: reset with `persistent bash command aborted` and return `""`; the newest page contains `end` and rule 98 extracts a complete output: return it rendered by rule 99; the send reported an exited session: rule 100; the wait reason is `stdin_read`: return the partial output of rule 98 rendered without a status marker; otherwise wait 25 ms and repeat.
98. Retained scrollback is assembled by reading pages of 1000 lines from the newest backwards and joining them with `\n`. Complete output: find the last `end`; the text after it must start with digits and a newline, which is the exit status; the output is the text between the last `start` before it (after that marker and one newline) and `end`, with trailing newlines removed; if `start` scrolled out, take from the beginning and mark the output incomplete. Partial output: the text after the last `start` when it is retained; otherwise the fallback text after its last `start` and before its last `end`, marked incomplete when the fallback was truncated or has no `start`.
99. Rendering: the text is clipped to `maxOutputChars` UTF-16 units without splitting a surrogate pair and followed by `<response clipped><NOTE>To save on context only part of this file has been shown to you. You should retry this tool after you have searched inside the file with `grep -n` in order to find the line numbers of what you are looking for.</NOTE>` when it is longer than the limit or incomplete; an incomplete, non-empty output is preceded by `<response clipped><NOTE>The beginning of this command output was dropped by the terminal scrollback limit. The following text is the earliest retained output.</NOTE>` and a newline; a known exit status adds `[Command finished with exit code <n>]` on its own line (alone when the text is empty).
100. Timeout: `Your command timed out after <timeoutMs / 1000 rounded> seconds or experienced an OOM error. Below is partial output:`, then the rendered partial output with `[Command timed out or OOM]` on its own line, then `The persistent bash shell was reset; the next bash call starts from the workspace with a fresh current directory and environment.`, joined by newlines. Shell exit: the rendered partial output with `[shell killed by signal: <SIG>]`, `[shell exited: code <n>]` or `[shell exited]` on its own line, then the same reset sentence, after a reset with `persistent bash shell exited`; empty parts are left out.
101. Plugin disposal fires the lifetime source with `tool-bash-persistent disposed during shell creation`, waits for creations in flight, and kills every live shell with reason `tool-bash-persistent disposed`.

**PowerShell**

102. No rule. The four pwsh plugins validate their config and raise at load (Plugins).

**SSH** (R8 "`ctx.ssh`"; `ssh/src/{index,protocol,schemas,stream-security}.ts`, `subprocess-ssh/src/index.ts`, `sandbox-ssh/src/index.ts`)

103. Config, second validation (`ssh/src/index.ts:88-103`); any violation raises at load naming the field: the platform must be POSIX (`SSH runtime requires a POSIX client`); `host` matches `^[a-zA-Z0-9][a-zA-Z0-9_.@-]*$`; `helper`, `workspace`, `launch.node` and `launch.bootstrapPath` start with `/`; `helperHash` and `launch.bootstrapHash` are 64 lowercase hex digits; `bootstrapPath` and `bootstrapHash` occur together; `requestTimeoutMs` is a positive integer at most 2147483647; `maxFrameBytes` a positive integer at most 67108864; `maxPending` a positive integer at most 128; `leaseMs` an integer from 3000 to 600000; no key outside the schema.
104. Start: create a private directory `/tmp/dsh-ssh-XXXXXX`; the control socket is `<dir>/master`. The remote command is, with each word in single quotes (`'` written as `'\''`): `<node> --disable-sigusr1 <helper>` for `node-script`, and `NODE_OPTIONS='--disable-sigusr1' <helper>` for `executable`. Spawn, through `subprocess` semantics of rule 6 with all three streams piped, `ssh -T -M -S <control> -o ControlPersist=no -o BatchMode=yes -o StrictHostKeyChecking=yes -o ForwardAgent=no -o ClearAllForwardings=yes -o ServerAliveInterval=10 -o ServerAliveCountMax=3 <host> <command>`; stderr is drained and discarded. The child's exit or a peer failure fails the connection with `SSH helper disconnected; remote outcomes and cleanup are unknown`.
105. Hello: request `hello` with `{protocol: 3, workspace, leaseMs, bootstrapPath?}` bounded by `requestTimeoutMs`; the reply must be a hello record whose `hash` equals `helperHash` (`SSH helper digest differs from the configured artifact`), whose `kind` equals the launch kind (`SSH helper runtime differs from the configured launch kind`) and whose `bootstrapHash` equals the configured one (`SSH PTC bootstrap digest differs from the configured artifact`). Then every `floor(leaseMs / 3)` ms send `heartbeat` with `{}` bounded by `leaseMs / 2`, one at a time; a failed heartbeat fails the connection.
106. Frames: a 4-byte big-endian length followed by that many bytes of UTF-8 JSON written with `jvalue->bytes`. A length of 0 or above `maxFrameBytes` raises `SSH helper sent an invalid frame length`. End of input raises `SSH helper disconnected during a frame; outcome is unknown` inside a frame and `SSH helper disconnected; outcome is unknown` between frames. A frame larger than `maxFrameBytes`, or a write queue above twice that, raises `SSH helper frame or write queue limit exceeded`.
107. `(make-rpc-peer in out max-frame-bytes max-pending [handler #f])` and `(rpc-request peer method params #:check check #:cancel cancel)`: raise the cancel reason when cancelled and the recorded failure when closed; requests are classed as `heartbeat` (limit 1), `close` (1), `process.terminate` (128), `fs.streamClose` (128) or ordinary (`max-pending`), and a full class raises `SSH helper pending request limit reached`; the id is a random UUID; on cancellation the caller gets `SSH operation cancelled; a completed remote mutation is not rolled back` and a `cancel` frame is sent. A `result` resolves its request; an `error` raises `(exn:fail:remote-operation message code)`; replies for unknown ids are ignored.
108. Incoming requests are served only when a handler was given (the output-snapshot peers of rule 114): the handler runs in its own task with a cancel source that an incoming `cancel` frame fires; its value, or `null`, is sent as `result`, a raise as `error` with `{name, message, code?}`. An unexpected, duplicate or excessive request closes the peer with `SSH helper received an unexpected or excessive request`. `(rpc-close! peer [failure])` records the failure (default `SSH connection lost; remote operation outcome and cleanup are unknown`), fails every pending request, cancels every active handler and closes both ports; it runs once.
109. `ssh-request`: raise `SSH connection is closed` after disposal and the recorded failure after a failure; wait for the hello; without `wait?` fuse the caller's cancel event with a `requestTimeoutMs` timer.
110. `ssh-connect-stream`: the endpoint path must start with the hello's `root` followed by `/` and hold none of `:`, CR, LF, NUL (`SSH helper returned an invalid stream path`); the local path is `<dir>/s<n>` with a counter from 0; run the control command `ssh -S <control> -O forward -o ExitOnForwardFailure=yes -L <local>:<remote> <host>` (bounded by `requestTimeoutMs`, the connection's lifetime and the caller); connect to the local Unix socket and authenticate it (rule 113). When the stream closes, or on any failure, run `ssh -S <control> -O cancel -L <local>:<remote> <host>` and delete the local socket.
111. `ssh-dispose!`, once: mark closed, cancel the lifetime source with `SSH connection is closing`, stop the heartbeat, send `close` when the connection has not failed, close the peer and every stream, send `SIGTERM` to the `ssh` child and `SIGKILL` after `requestTimeoutMs`, wait for it and for operations in flight, and delete the directory.
112. `runtime-spawn` over SSH (`subprocess-ssh/src/index.ts:24-196`): raise the cancel reason when cancelled; `process.prepare` with the spec as JSON (`argv`, `cwd`, `env` with tombstones as `null`, `graceMs`, `stdio`) returns a prepared record; connect every listed stream; for a piped stdout or stderr copy the stream to the handle's port; for stdin and control copy the handle's port to the stream; then `process.start {id}`. A failure before the start is acknowledged terminates the remote process and is the launch failure. `done` is `process.done {id}` (unbounded), after which piped output is drained for at most `grace-ms` and the spill paths are taken from the reply.
113. Stream security: each forwarded socket carries TLS 1.2 with the cipher `PSK-AES256-GCM-SHA384`, identity `dsh-stream` and the endpoint's capability as the key. Racket's `openssl` binding has no pre-shared-key support, so a stream is one child `openssl s_client -quiet -tls1_2 -cipher PSK-AES256-GCM-SHA384 -psk_identity dsh-stream -psk <capability> -unix <local socket>` whose stdin and stdout are the stream's ports; the handshake must complete within `requestTimeoutMs` (`SSH stream authentication timed out`, `SSH stream closed during authentication`). The capability is on that child's command line for its lifetime; the socket directory is private and the capability is single-use.
114. Collected output over SSH: for a collect-mode stream the helper sends `snapshot` requests `{tail, totalBytes}` on that stream, served by a peer with frame limit `min(67108864, 2 * maxBytes + 1024)`. A snapshot whose tail is longer than `maxBytes` or longer than `totalBytes` raises `SSH helper returned invalid collected output coordinates`; one whose `totalBytes` decreased raises `SSH helper rewound collected output`. The reader serves the latest snapshot through a tail-only collector whose offsets are shifted by `totalBytes - tail length`, and adds the spill path once known. `subprocess-handle-terminate!` sends `process.terminate {id}` once (before the start was acknowledged it also cancels the launch); a failed terminate disposes the connection. `wait-for-exit` is `process.wait {id}` unbounded, or the terminate request when one is in flight.
115. Also over SSH: `runtime-resolve-executable` is `executable {command, env}` (a remote error with code `SUBPROCESS_EXECUTABLE_NOT_FOUND` becomes the executable not found error); `runtime-terminal-environment` is `terminal.environment {}`; `runtime-spawn-terminal` prepares with `terminal: {rows, cols, terminalType, shellActivity}`, connects the `terminal` stream as the output port, starts (the reply carries `pid`), and maps the handle operations to `terminal.write {id, value}`, `terminal.resize {id, cols, rows}`, `terminal.inspect {id}`, `terminal.activity {id}`, `terminal.signal {id, value}` and `process.terminate {id}`. Provider disposal terminates every live process and terminal and waits; failures raise `SSH process cleanup could not be confirmed`.
116. `sandbox-provider-confine` over SSH: raise the cancel reason when cancelled; `sandbox {argv, policy}` returns `{argv, enforcement, denialSignatures, runnerFailureRules}`; any failure other than the caller's cancellation raises the sandbox unavailable error for the policy's mode with the failure's message as detail.
