# Recon 08: the execution world (filesystem, sandbox, subprocess, shell, terminal, spill, attachments, deliverables)

Pinned commit `e8f7b93a3` (the checkout is one docs-only commit ahead, `cdd689f55`). Paths are relative to the repository root. `file:line` references point at `packages/<group>/<pkg>/src/...` at that commit.

Corrections to the task brief, verified in source:

- The area has **no** `ls`, `multi_edit`, or `multi-edit` tool. The model-facing file tools are exactly `read`, `read_image`, `write`, `edit`, `apply_patch` (off by default), `glob`, `grep`, and `str_replace_editor` (an alternative editor family that no shipped bundle mounts; overlays add it). Directory listing reaches the model only through `str_replace_editor` `view` on a directory, or through `bash`.
- The bash tool's timeout parameter is `timeoutMs` (camelCase, milliseconds), not `timeout`.
- Two packages register a tool named `bash`: `dsh-tool-bash` (one-shot, default) and `dsh-tool-bash-persistent` (PTY-backed, used by the "minimal" compositions). A composition mounts one of them.
- The model-facing terminal tools (`terminal_open` and friends) live in `packages/experimental/tool-terminal`, outside this area. This note covers the `ctx.terminals` service and the `terminal-bash` backend they consume.
- "Spill" names two unrelated mechanisms: (a) per-stream spill files written by the subprocess output collector for truncated command output, and (b) the `ctx.spillStore` service plus `spill-policy`, which bounds any tool result by estimated tokens. Both are specified below.
- The read-before-edit policy (`dsh-fs-observation-policy`) is shipped **disabled** (`packages/bundle/base/cordis.patch.yml:292-294`). With it off, `write`/`edit` are unconditional.

Depth: `fs/*`, `sandbox/{sandbox,sandbox-local,sandbox-policy}`, `subprocess/{subprocess,subprocess-local}` (contract and common lifecycle in depth; Linux systemd-scope and Windows Job internals summarized), `shell/{shell,bash-local,bash-sandbox,shell-env,tool-bash,tool-bash-persistent}`, `terminal/*`, `spill/*`, `attachment/*`, `deliverables/*`, and the four `util` packages are covered in depth. **Catalog depth only**: `sandbox/sandbox-windows-acl`, `subprocess/win32-process`, `shell/{pwsh-local,pwsh-sandbox,tool-pwsh,tool-pwsh-persistent}`, and all of `ssh/*`.

## Scope

Line counts are non-test TypeScript under `src/`.

| Package dir | npm name | Role | Lines |
|---|---|---|---|
| `packages/fs/fs` | `@deepseek-ai/dsh-fs` | Service Definition `ctx.fs` (abstract `FileSystem`), `fs/*` events, `FsError` codes, errno classifier | 640 |
| `packages/fs/fs-local` | `dsh-fs-local` | Host-disk provider: realpath identity, UTF-8 reads, atomic staged writes, per-target locks, literal edit, patch/delete/move | 1399 |
| `packages/fs/fs-observation-policy` | `dsh-fs-observation-policy` | Event-only read-before-write/edit policy (no service) | 170 |
| `packages/fs/fs-patch` | `dsh-fs-patch` | Pure library: Codex-style patch parser and hunk applier | 350 |
| `packages/fs/fs-sandbox` | `dsh-fs-sandbox` | `ctx.fs` provider extending fs-local with a per-call write fence | 257 |
| `packages/fs/tool-fs` | `dsh-tool-fs` | Tools `read`, `read_image`, `write`, `edit`, `apply_patch` | 2442 |
| `packages/fs/tool-fs-search` | `dsh-tool-fs-search` | Tools `glob`, `grep` over packaged ripgrep | 1546 |
| `packages/fs/tool-str-replace-editor` | `dsh-tool-str-replace-editor` | Tool `str_replace_editor` (view/create/str_replace/insert) | 537 |
| `packages/sandbox/sandbox` | `dsh-sandbox` | Service Definition `ctx.sandbox`, mode vocabulary, escalation choreography, writable-root derivation, runner/denial classifiers | 759 |
| `packages/sandbox/sandbox-local` | `dsh-sandbox-local` | Local provider: bwrap / Landlock / Seatbelt / Windows ACL argv wrapping, probes | 686 |
| `packages/sandbox/sandbox-policy` | `dsh-sandbox-policy` | `ctx.sandboxPolicy`: default mode, per-session override (`sandbox/mode`), workspace root, extra writable roots, prompt context | 328 |
| `packages/sandbox/sandbox-windows-acl` | `dsh-sandbox-windows-acl` | Windows restricted-token + ACL runner (catalog) | 2194 |
| `packages/subprocess/subprocess` | `dsh-subprocess` | Service Definition `ctx.subprocess`, env scrub, error codes, fd-7 control channel | 576 |
| `packages/subprocess/subprocess-local` | `dsh-subprocess-local` | Local provider: managed process ranges, output collector with spill files, node-pty terminals, process inspection | 5104 |
| `packages/subprocess/win32-process` | `dsh-win32-process` | Koffi Win32 process/Job bindings (catalog) | 1195 |
| `packages/shell/shell` | `dsh-shell` | Service Definition `ctx.shell` (request/spec split), exit-marker parser | 377 |
| `packages/shell/bash-local` | `dsh-bash-local` | `bash -c` executor over `ctx.subprocess` | 404 |
| `packages/shell/bash-sandbox` | `dsh-bash-sandbox` | Executor that wraps `bash -c` through `ctx.sandbox` | 206 |
| `packages/shell/shell-env` | `dsh-shell-env` | `ctx.shellEnv`: managed `DSH_*` environment snapshot per shell call | 255 |
| `packages/shell/tool-bash` | `dsh-tool-bash` | Tool `bash` (one-shot, background jobs, timeout promotion, escalation) | 854 |
| `packages/shell/tool-bash-persistent` | `dsh-tool-bash-persistent` | Tool `bash` (persistent shell per agent over `ctx.terminals`) | 488 |
| `packages/shell/pwsh-local` | `dsh-pwsh-local` | PowerShell executor (catalog) | 528 |
| `packages/shell/pwsh-sandbox` | `dsh-pwsh-sandbox` | Sandboxed PowerShell executor (catalog) | 320 |
| `packages/shell/tool-pwsh` | `dsh-tool-pwsh` | Tool `pwsh`, mirror of tool-bash (catalog) | 929 |
| `packages/shell/tool-pwsh-persistent` | `dsh-tool-pwsh-persistent` | Persistent `pwsh` tool (catalog) | 500 |
| `packages/terminal/terminal` | `dsh-terminal` | `ctx.terminals`: owner-scoped PTY session registry | 693 |
| `packages/terminal/terminal-bash` | `dsh-terminal-bash` | PTY backend (bash or pwsh dialect): readiness detection, scrollback, sanitizer | 1369 |
| `packages/ssh/ssh` | `dsh-ssh` | `ctx.ssh`: OpenSSH connection + remote helper RPC (catalog) | 1509 |
| `packages/ssh/fs-ssh` | `dsh-fs-ssh` | `ctx.fs` over the helper (catalog) | 126 |
| `packages/ssh/subprocess-ssh` | `dsh-subprocess-ssh` | `ctx.subprocess` over the helper (catalog) | 345 |
| `packages/ssh/sandbox-ssh` | `dsh-sandbox-ssh` | `ctx.sandbox` resolved on the remote host (catalog) | 33 |
| `packages/ssh/ssh-helper-runtime` | `dsh-ssh-helper-runtime` | SEA entry dispatcher for the remote helper (catalog) | 39 |
| `packages/deliverables/tool-present` | `dsh-tool-present` | Tool `present`, event `deliverables/presented` | 127 |
| `packages/deliverables/workspace-changes` | `dsh-workspace-changes` | Per-turn changed-file summaries from git snapshots + captures; `ctx.workspaceChanges`; event `workspace/changes` | 1294 |
| `packages/deliverables/deliverable-file-references` | `dsh-deliverable-file-references` | One system-prompt section about file links | 30 |
| `packages/spill/spill` | `dsh-spill` | Service Definition `ctx.spillStore` | 138 |
| `packages/spill/spill-local` | `dsh-spill-local` | Local spill files + startup cleanup sweep | 726 |
| `packages/spill/spill-policy` | `dsh-spill-policy` | Token-budgeted tool results with head/tail retention and spill notice | 346 |
| `packages/attachment/attachment` | `dsh-attachment` | Service Definition `ctx.attachments`, admission, error codes, projection geometry | 710 |
| `packages/attachment/attachment-local` | `dsh-attachment-local` | Content-addressed store under `DSH_HOME`, image normalization, request-image cache | 1556 |
| `packages/util/ripgrep` | `dsh-util-ripgrep` | Resolve/spawn packaged `rg`, streaming line reader | 109 |
| `packages/util/output-retention` | `dsh-output-retention` | `ItemRetainer`, `TextRetainer`, omission wording, surrogate-safe truncation | 460 |
| `packages/util/workspace-path` | `dsh-util-workspace-path` | Browser-safe path helpers and `dsh-resource://file/...` addresses | 236 |
| `packages/util/atomic-write` | `dsh-atomic-write` | `writeFileAtomic`, `withFileLock` | 273 |

Subsystem docs that exist: `docs/subsystems/{filesystem,sandbox,shell,subprocess,terminal,spill,attachment,deliverables,ssh}.md`. Their non-generated prose matches source; the generated "Cordis API" blocks are signature dumps.

Outside the area but required by it (owned by other recon notes): `ctx.tools` / `defineTool` / `tools/pre-execute` / `tools/post-execute` / `tools/result` (core tools), `ctx.systemPrompt`, `ctx.workingDirectory.ensure(agent, signal)`, `ctx.jobs` (job registry), `ctx.approval`, `ctx.sessionProjections`, `ctx.agents`, `@deepseek-ai/dsh-timeout`, `@deepseek-ai/dsh-token-meter/estimate`, `@deepseek-ai/dsh-home-paths`, `@deepseek-ai/dsh-util-code-language`, and the native `landlock-run` launcher (`native/system`).

## Services

### `ctx.fs` — `FileSystem` (abstract; `fs/fs/src/index.ts:104`)

One provider per context. Providers: `LocalFileSystem` (fs-local), `SandboxedFileSystem` (fs-sandbox, extends local), `SshFileSystem` (fs-ssh). Vocabulary (`fs/fs/src/types.ts`):

- `FsTargetKey`, `FsVersion`: branded opaque strings. `FsTarget = { targetKey, displayPath }`.
- `FsInfo = { version, type: 'file'|'directory'|'other', size? }`; `FsPathInfo` adds type `'symlink'`.
- `FsDirEntry = { name, type, target, version?, size? }`.
- `FsWriteIntent = { kind: 'createIfAbsent' } | { kind: 'replaceIfVersion', version }`.
- `FsWriteOutcome = { operation: 'create'|'update', version, before: string|null, after: string }`.
- `FsEditRequest = { oldString, newString, replaceAll }`; `FsEditOutcome = { version, before, after }`.
- `FsDeleteOutcome = { before: string|null }`.
- `FsMoveOutcome = { sourceBefore: string|null, destination: FsWriteOutcome, sourceDeleted: true } | { ..., sourceDeleted: false, sourceFailure: { code: FsErrorCode, message } }`.
- `FsObservation = { kind: 'present', version } | { kind: 'absent' }`.
- `FS_ERROR_CODES` (exact, in order): `FS_NOT_FOUND`, `FS_NOT_DIRECTORY`, `FS_NOT_TEXT`, `FS_NOT_REGULAR_FILE`, `FS_TOO_LARGE`, `FS_PERMISSION_DENIED`, `FS_SANDBOX_DENIED`, `FS_IO_ERROR`, `FS_STALE_VERSION`, `FS_NOT_OBSERVED`, `FS_AMBIGUOUS_EDIT`, `FS_EDIT_NOT_FOUND`, `FS_ABORTED`, `FS_PATCH_MISMATCH`, `FS_SAME_TARGET`, `FS_ALREADY_EXISTS`. `FsError extends HarnessError` with `name = 'FsError'`.
- `fsErrorFromErrno(operation, displayPath, error)` (`fs/fs/src/errno.ts:18`): `ENOENT`/`ENOTDIR` → `FS_NOT_FOUND` (`cannot <op> "<path>": not found`); `EACCES`/`EPERM` → `FS_PERMISSION_DENIED` (`...: permission denied`); `EISDIR` → `FS_NOT_REGULAR_FILE` (`...: not a regular file`); other errno → `FS_IO_ERROR` (`...: <node message>`). Values that are already `FsError` or carry no string `code` are returned unchanged.

Methods:

| Method | Semantics |
|---|---|
| `get sandboxMode(): SandboxMode \| undefined` | Capability fact: default mode a confining backend enforces; `undefined` for non-confining backends. Tool layers read it once at plugin apply to decide whether to advertise escalation fields. |
| `resolve(path, { cwd?, signal? }) → FsTarget` | Stable identity; follows symlinks; relative paths use `opts.cwd` else provider default. May do I/O. |
| `processPath(target) → string` | Canonical absolute path a subprocess in the same world can open. Local: the target key. |
| `processPathFromHostPath(hostPath) → string \| undefined` | Map a harness-host absolute path into this world. Base: `undefined`. Local: `resolve(hostPath)` if absolute. |
| `fileUrl(target) → string` | `file:` URI. |
| `contains(parent, child) → boolean` | Identity or descendant containment. |
| `stat(target, signal?) → FsInfo \| undefined` | Metadata, never content; `undefined` = absent. |
| `lstat(path, { cwd? }, signal?) → FsPathInfo \| undefined` | Path-shaped, does not follow the final symlink. |
| `readText(target, signal?) → string` | Whole regular UTF-8 file; rejects binary/invalid UTF-8 with `FS_NOT_TEXT`. |
| `streamText(target, signal?) → AsyncIterable<string>` | Same semantics, chunked. |
| `readBytes(target, signal, maxBytes) → bytes` | Raw; `FS_TOO_LARGE` when content exceeds the inclusive cap (never truncates). |
| `readByteRange(target, { offset, length }, signal?) → bytes` | Window `[offset, offset+length)`; empty past EOF. |
| `listDir(target, signal?) → FsDirEntry[]` | Direct children, stable name order, no content reads. |
| `writeText(target, content, expected?, signal?, sandboxPolicy?) → FsWriteOutcome` | Atomic create/replace. `expected` omitted = unconditional. |
| `editText(target, edit, expected?, signal?, sandboxPolicy?) → FsEditOutcome` | Atomic literal replace; version guard checked before matching. |
| `patchText(target, hunks, expected?, signal?, sandboxPolicy?) → FsEditOutcome` | Apply parsed hunks to LF text, restore line endings. |
| `deleteFile(target, expected?, signal?, sandboxPolicy?) → FsDeleteOutcome` | Remove one regular file. |
| `moveFile(source, destination, { hunks?, expectedSource?, expectedDestination? }, signal?, sandboxPolicy?) → FsMoveOutcome` | Publish (optionally patched) source text at destination, then remove source; two separable effects. |
| `watch(target, changed, signal) → Promise<close>` | Base rejects `FS_IO_ERROR` "Filesystem watching is not supported by this provider."; local uses chokidar at depth 0. |

Ownership rules: providers record no observations and dispatch no events; consumers dispatch `fs/*-intent` before a mutation and emit `fs/observed` after. Consumers must not parse `targetKey` or `version`.

### `ctx.sandbox` — `SandboxProvider` (abstract; `sandbox/sandbox/src/index.ts:212`)

`confine(argv, policy: SandboxPolicy, signal?) → Promise<ConfinedArgv>`.

- `SandboxMode = 'read-only' | 'workspace-write' | 'danger-full-access'`. `SandboxPolicy` narrows `mode` to the two confined modes; a `danger-full-access` consumer never calls `confine`.
- `SandboxExecutionPolicy = { mode, workspaceRoot, additionalWritableRoots?, sessionId? }`.
- `ConfinedArgv = { argv: string[], enforcement: 'full'|'partial', denialSignatures: string[], runnerFailureRules: RunnerFailureRule[] }`; `RunnerFailureRule = { allowedExitCodes?: number[], fatalSignatures: string[], informationalLines?: string[] }`.
- Must return enforcing argv or throw: `SandboxUnavailableError` (code `SANDBOX_UNAVAILABLE`) or `SandboxPreparationError` (codes `SANDBOX_PREPARATION_FAILED`, `SANDBOX_INVALID_TEMP_ROOT`). Silent passthrough is forbidden.
- The package also exports the shared library pieces used by every enforcing tool: `ESCALATION_TARGETS`, `WIDER_MODES`, `validateEscalationArgs`, `approveEscalation`, `sandboxDenialMarker`, `escalationHintMarker`, `sandboxPermissionsDescription`, `SandboxEscalationError` + `SANDBOX_ESCALATION_ERROR_CODES`, `canonicalPath`, `workspaceWritableRoots`, `writableRoots`, `SandboxInvalidRootError` (code `SANDBOX_INVALID_ROOT`), `classifyRunnerFailure`, `isRunnerSpawnFailure`, `matchesSignature`.

### `ctx.sandboxPolicy` — `SandboxPolicyService` (`sandbox/sandbox-policy/src/index.ts:143`)

- `defaultMode: SandboxMode`, `workspaceRoot: string`, `additionalWritableRoots: readonly string[] | undefined` (frozen, deduplicated).
- `resolve(request: { session?, mode? } = {}) → SandboxExecutionPolicy` (`:208`): `mode = request.mode ?? overrideOf(session) ?? defaultMode`; `workspaceRoot = session.header.cwd ?? configured root` (throws `SandboxInvalidRootError` if the session cwd is relative or contains NUL); `additionalWritableRoots` = configured roots + this session's live registrations (deduplicated, omitted when empty); `sessionId = session.id` when a session is given.
- `registerWritableRoot(session, directory) → dispose` (`:244`): runtime-only, effect-scoped grant; not restored on resume/fork.
- `overrideOf(session) → SandboxMode | undefined`: state of the `sandboxMode` session projection.
- Exported functions: `setSandboxMode(session, mode)` appends one `sandbox/mode` event; `SANDBOX_MODES`.
- On init registers session projection `{ key: 'sandboxMode', stateVersion: 1, init: null, apply: event.type === 'sandbox/mode' ? event.data.mode : state }` and, when `systemPrompt` exists, a runtime-context contribution `{ name: 'sandbox:policy', order: SANDBOX_POLICY (110) }` whose text is `renderPolicyContext(resolve({ session }))` (empty without a session).

### `ctx.subprocess` — `SubprocessRuntime` (abstract; `subprocess/subprocess/src/index.ts:124`)

- `resolveExecutable(command, env?, signal?) → Promise<string>`: absolute path verified (regular file + X_OK), bare name searched on the scrubbed PATH plus overrides; a relative path containing a separator throws; a miss throws `SubprocessExecutableNotFoundError` (`SUBPROCESS_EXECUTABLE_NOT_FOUND`).
- `terminalEnvironment(signal?) → { platform: 'posix'|'windows', defaultShell? }`.
- `spawn(spec: SubprocessSpawnSpec) → SubprocessHandle` (synchronous; throws synchronously on invalid argv/grace or pre-aborted signal).
- `spawnTerminal(spec: SubprocessTerminalSpawnSpec) → Promise<SubprocessTerminalHandle>`.

`SubprocessSpawnSpec = { argv, cwd, stdio: { stdin: 'ignore'|'pipe'|{data}, stdout: 'pipe'|'inherit'|{maxBytes, spill?:{maxBytes}}, stderr: same, control?: 'pipe' }, graceMs, signal?, env? }`. No defaults at this seam. `env` values: string = explicit override (survives scrub), `undefined` = tombstone.

`SubprocessHandle = { stdin?, stdout?, stderr?, control?, collected: { stdout?, stderr? }, done: Promise<{ exitCode: number|null, signal: string|null }>, terminate(): void, waitForExit(signal?): Promise<boolean> }`. `collected.*.readFrom(fromByte) → { text, nextOffset, lossy, spillPath? }` is offset-based and non-consuming. `done` reports exit facts only (no timeout/abort classification). `terminate()` is idempotent and also fired by `spec.signal`. `waitForExit` resolves `true` when the provider-managed range (process group / systemd scope / Job) is empty, `false` if its own signal aborted first.

`SubprocessTerminalSpawnSpec = { argv, cwd, env?, rows, cols, terminalType, shellActivity?, graceMs, signal? }`. `SubprocessTerminalHandle = { pid, output: Readable, done, write(data), resize(cols, rows), inspectForeground() → { processGroupId, inputWaiting } | undefined, inspectActivity() → { state: 'idle'|'busy'|'unknown', revision }, signalForeground(sig) → pgid, terminate(): Promise<void> }` with signals `SIGINT|SIGTERM|SIGKILL|SIGTSTP|SIGHUP`.

Library exports: `scrubbedParentEnv()`, `SENSITIVE_ENV_PATTERN = /KEY|PASSWORD|SECRET|TOKEN/i`, `DSH_ENV_PREFIX = 'DSH_'`, `SubprocessError` + `SUBPROCESS_ERROR_CODES` (`SUBPROCESS_INVALID_ARGV`, `SUBPROCESS_EXECUTABLE_NOT_FOUND`, `SUBPROCESS_SPAWN_NOT_FOUND`, `SUBPROCESS_SPAWN_FAILED`, `SUBPROCESS_RUNNER_FAILED`, `SUBPROCESS_RUNNER_IPC_FAILED`, `SUBPROCESS_PTY_UNAVAILABLE`), `subprocessSpawnFailure(error, program)`, and `./control` (`SUBPROCESS_CONTROL_FD = 7`, `SUBPROCESS_CONTROL_ENV = 'DSH_SUBPROCESS_CONTROL'`, `openInheritedControlChannel()`).

Lifecycle: service disposal terminates every live handle and terminal and awaits managed-range quiescence; a synchronous `process.on('exit')` hook force-kills whatever is still owned.

### `ctx.shell` — `ShellExecutor` (abstract; `shell/shell/src/index.ts:63`)

- `get sandboxMode(): SandboxMode | undefined` — default mode of a sandboxing executor, else `undefined`.
- `resolve(request: ShellExecRequest) → ShellExecSpec` — the explicit defaulting/capping step.
- `execute(spec: ShellExecSpec) → Promise<ShellExecution>`.

`ShellExecRequest = { command, workdir?, timeoutMs?, onExpiry?: 'kill'|'none', stdoutMaxBytes?, signal?, stdin?, env?, dshEnv?, sandboxPolicy? }`. `ShellExecSpec` makes `workdir`, `timeoutMs`, `onExpiry`, `stdoutMaxBytes` required and `sandboxPolicy: SandboxExecutionPolicy | undefined` explicit.

`ShellExecution` (extends `ShellProcess`): `status: 'running'|'completed'|'killed'`, `exitCode`, `signal`, `done: Promise<void>` (never rejects), `sandbox?: ShellSandboxInfo`, `readOutput() → { delta, lossy, stdoutSpillPath?, stderrSpillPath? }` (consuming cursor), `observed: { stdout, stderr }` (non-consuming offset readers), `kill() → boolean`, `result() → Promise<ShellRunResult>` (memoized foreground projection).

`ShellRunResult = { exitCode, signal, timedOut, aborted, timeoutMs, stdout: CollectedOutput, stderr: CollectedOutput, sandbox? }`, `CollectedOutput = { text, truncated, spillPath? }`, `ShellSandboxInfo = { mode, denied, enforcement?, runnerFailed? }`. `timedOut` and `aborted` are mutually exclusive (first cause wins). `result()` rejects only for infrastructure failures.

Also exported: `parseExitStatus(text)` (`shell/shell/src/render.ts:37`).

### `ctx.shellEnv` — `ShellEnvRegistry` (`shell/shell-env/src/index.ts:104`)

- `register(contributor: { name, variables: Record<DSH_KEY, { description }>, resolve(execution) → Partial<Record<DSH_KEY, string>> }) → dispose`. Validates: non-empty unique name; each key starts with `DSH_` and its suffix matches `^[A-Z][A-Z0-9_]*$`; reserved built-in keys rejected; non-empty description; key not owned by another contributor.
- `collect(execution: ToolExecution) → DshEnvironment` (frozen, keys sorted): built-ins then contributors in name order. A contributor returning an undeclared key or a non-string throws `ShellEnvError` (`SHELL_ENV_CONTRIBUTION_INVALID`) and the shell command does not run.
- `list() → [{ contributor, key, description }]` sorted by key (plugin contributions only; built-ins not listed).

### `ctx.terminals` — `TerminalSessionService` (`terminal/terminal/src/index.ts:87`)

Owner = the exact live `Agent` object. Methods:

- `registerBackend(backend: { type, spawn(spec) }) → dispose` (duplicate type → `TerminalError` `DUPLICATE_BACKEND`); `listBackends() → string[]`.
- `spawn(owner, { type, name?, cwd? }, signal?) → { sessionId, name?, type, pid?, status, motd }`. Ids are `pty-<n>` (process-wide counter from 1).
- `hasOwnerActivity(owner) → boolean` (published session or unpublished spawn).
- `startSend(owner, id, { text, submit, signal? }) → TerminalSendOperation { done, readOutput(), cancel() }`; one active send per session.
- `read(owner, id, { offset?, count? }) → { text, totalLines, lineBegin, lineEnd, truncated }`.
- `signal(owner, id, signal) → { delivered: true, targetPgid }`.
- `kill(owner, id, reason = 'model request') → boolean` (false when the same close was already in flight).
- `list(owner) → TerminalSessionSnapshot[]`.

Error codes (`TerminalErrorCode`): `CLEANUP_FAILED`, `DUPLICATE_BACKEND`, `DUPLICATE_NAME`, `FOREIGN_SESSION`, `INIT_REJECTED`, `NO_BACKEND`, `NO_SANDBOX`, `NO_SESSION`, `OWNER_NOT_LIVE`, `SEND_ACTIVE`, `SERVICE_DISPOSING`, `SESSION_CLOSING`, `SESSION_EXITED`, `STARTUP_EXITED`, `STARTUP_TIMEOUT`. Sessions are in-process only and do not survive a restart. Owner disposal (an effect on `owner.ctx`) aborts pending spawns and closes that owner's sessions; service disposal does the same for all.

### `ctx.spillStore` — `SpillStore` (abstract; `spill/spill/src/index.ts:46`)

`saveText({ owner: { sessionId }, source, suggestedName, content }) → Promise<{ locator: SpillLocator, bytes, retrievalHint }>`. `source = { kind: 'tool', toolName, callId, label } | { kind: 'session-reference', sessionId, label }`. Persists the full content verbatim, privately, under a collision-free name derived from the hint. Rejects on real storage failure; callers treat it as best-effort.

### `ctx.attachments` — `AttachmentStore` (abstract; `attachment/attachment/src/index.ts:77`)

- `imageLimits: { maxImageBytes, maxImagesPerMessage, maxMessageImageBytes, maxImagePixels, maxImageDimension, mediaTypes }`.
- `validateImage(input)`, `saveImage({ data, mediaType, name? }) → ImageAttachmentRef`, `saveImages(inputs) → refs` (validate whole batch before committing any), `readImage(ref, signal?) → { ref, data }`, `imageHostPath(ref) → string | undefined`.
- `admitPromptContent(parts) → admitted parts` (replaces encoded images with durable refs; enforces count/aggregate-byte limits across encoded + already-stored images), `admitEncodedFile({ data(base64), name? }) → FileAttachmentRef`.
- `saveFile({ data, name? })`, `saveFileStream({ data: AsyncIterable, signal?, name? })`, `readFileStream(ref, signal?)`, `fileHostPath(ref)` — default implementations reject with `ATTACHMENT_FILES_UNSUPPORTED`.
- `readImageRequest(ref, { width, height, maxBytes }, signal?) → RequestImageAttachment` — default rejects `ATTACHMENT_PROJECTION_UNSUPPORTED`.
- `isAttachmentError(error)` (matches by code, not prototype).
- `ImageAttachmentRef = { attachmentId, mediaType: 'image/png'|'image/jpeg'|'image/webp'|'image/gif', bytes, width, height, name?, originalDimensions?: { width, height } }`; `FileAttachmentRef = { attachmentId, name, bytes }`.
- `AttachmentErrorCode`: `TOO_MANY_IMAGES`, `IMAGES_TOO_LARGE`, `UNSUPPORTED_IMAGE_TYPE`, `INVALID_IMAGE_BASE64`, `INVALID_IMAGE`, `IMAGE_TYPE_MISMATCH`, `IMAGE_TOO_LARGE`, `IMAGE_TOO_MANY_PIXELS`, `IMAGE_DIMENSION_TOO_LARGE` (these nine are "image admission" codes), plus `INVALID_FILE_BASE64`, `INVALID_ATTACHMENT_REF`, `ATTACHMENT_CORRUPT`, `ATTACHMENT_WRITE_FAILED`, `ATTACHMENT_NOT_FOUND`, `ATTACHMENT_READ_FAILED`, `ATTACHMENT_PROJECTION_UNSUPPORTED`, `ATTACHMENT_FILES_UNSUPPORTED`.

### `ctx.workspaceChanges` — `WorkspaceChanges` (provided with `ctx.provide`; `deliverables/workspace-changes/src/index.ts:116`)

`summary(sessionId, seq) → WorkspaceChangesSummary | undefined`; `diff(sessionId, seq, index, signal) → Promise<WorkspaceFileDiff | undefined>`. In-memory per live Session; gone after Session disposal or host restart.

### `ctx.ssh` — `SshConnection` (catalog)

`ready: Promise<Hello>`, `ptcLaunch`, `request(method, params, zodSchema, signal?, wait?)`, `connectStream(endpoint, signal?)`, `dispose()`. One non-reconnecting OpenSSH master (`ssh -T -M -S <ctl> -o ControlPersist=no -o BatchMode=yes -o StrictHostKeyChecking=yes -o ForwardAgent=no -o ClearAllForwardings=yes -o ServerAliveInterval=10 -o ServerAliveCountMax=3 <host> <helper cmd>`), a length-bounded JSON frame RPC (`request`/`result`/`error`/`cancel` frames, protocol version 3), and per-stream forwarded Unix sockets authenticated by a 64-hex capability. `fs-ssh`, `subprocess-ssh`, `sandbox-ssh` implement the three seams by calling helper methods (`fs.resolve`, `fs.stat`, `fs.lstat`, `fs.readText`, `fs.stream`/`fs.next`/`fs.streamClose`, `fs.readBytes`, `fs.readRange`, `fs.list`, `fs.write`, `fs.edit`, `fs.patch`, `fs.delete`, `fs.move`, `sandbox`, `process.*`).

### Libraries without a ctx key

`dsh-fs-patch` (`parsePatch`, `applyHunks`, `PatchParseError`), `dsh-output-retention`, `dsh-util-ripgrep` (`resolveRgPath`, `spawnRipgrep`, `readRipgrepLines`), `dsh-util-workspace-path`, `dsh-atomic-write`, `dsh-win32-process`, `dsh-sandbox-windows-acl` (`AclSandbox`, `AclWriteGrant`, `workspaceWriteSid`, `tempWriteSid`, runner entry).

## Events

### Cordis events declared in this area (`fs/fs/src/index.ts:58-94`)

| Event | Mode | Arguments | Producers | Consumers |
|---|---|---|---|---|
| `fs/write-intent` | waterfall | `(target: FsTarget, actor: object \| undefined, next) → Promise<FsWriteIntent \| undefined>` | `write`, `apply_patch` (add, move destination), `str_replace_editor create` | `fs-observation-policy` (decides, never calls `next`); `workspace-changes` (prepended, calls `next` then captures) |
| `fs/edit-intent` | waterfall | `(target, actor, next) → Promise<{ version } \| undefined>` | `edit`, `apply_patch` (update, move source), `str_replace_editor str_replace/insert` | same two |
| `fs/delete-intent` | waterfall | `(target, actor, next) → Promise<{ version } \| undefined>` | `apply_patch` delete | same two |
| `fs/observed` | emit | `(target, observation: FsObservation, actor)` | every file tool after a successful read or mutation, and on a metadata miss | `fs-observation-policy` |

Rules:

- The three intents are single-slot decisions. Each producer dispatches with a default thunk (`() => undefined`, except `str_replace_editor create` which uses `() => ({ kind: 'createIfAbsent' })`). The first listener that returns without calling `next()` owns the answer. Without a policy listener the result is `undefined` = unconditional mutation.
- `actor` is the tool's `ToolExecution` object passed through opaquely. The policy narrows it structurally to `{ agent?: { session?: object } }` and keys state by `actor.agent.session` identity.
- `fs/observed` is a plain `ctx.emit`. Listeners must be synchronous and must not throw: a throw surfaces as the tool's error even though the mutation already committed; returned promises are not awaited.
- The policy listeners return `Promise.resolve().then(() => gate.xIntent(...))` so a refusal rejects asynchronously (`fs-observation-policy/src/index.ts:128-132`).
- `workspace-changes` registers its three intent listeners with `{ prepend: true }`; each awaits `next()` first, then snapshots the target file before the mutation runs (`workspace-changes/src/index.ts:166-180`).

### Session events declared in this area (declaration-merged into `SessionEventMap`)

| Event | Payload | Appended by | Model-visible | Read by |
|---|---|---|---|---|
| `sandbox/mode` | `{ mode: SandboxMode, source?: 'delegation' }` | `setSandboxMode(session, mode)`; delegation seeding (subagent area) | No (log-only) | `sandboxMode` projection; `terminal-bash` fence |
| `deliverables/presented` | `{ turn: number, callId: ToolCallId, files: { path, description? }[] }` | `tool-present`, once per successful `present` result | No | clients |
| `workspace/changes` | `{ turn: number }` | `workspace-changes` when a top-level turn stops/ends and something changed | No | clients (then `ctx.workspaceChanges.summary(sessionId, event.seq)`) |

### Events from other areas that this area listens to

| Event | Mode | Listener | What it does |
|---|---|---|---|
| `tools/post-execute` | waterfall `(exec, result, next) → PostToolDecision` | `tool-fs-search` (glob, grep; default position) | After `next()`: if this is a direct top-level successful call still owned by the registered definition and no downstream policy replaced content/value, and the result is over the inline cap, save the complete formatted result via `ctx.spillStore` and return `{ kind: 'accept', content: [text with footer] }`. |
| `tools/post-execute` | waterfall, `{ prepend: true }` | `spill-policy` | After `next()`: token-bound the accepted content (see Algorithms). Skips `exec.name === 'read'`, decisions carrying `value`, and text-only nested (PTC) calls. |
| `tools/ptc-dispatch-log` | waterfall, `{ prepend: true }` | `spill-policy` | Bound the PTC dispatch log copy with label `dispatch`. |
| `tools/result` | emit `(exec, result)` | `tool-present` | Appends `deliverables/presented` for a non-error `present` result. |
| `tools/pre-execute` | waterfall | `workspace-changes` | Binds `exec` to the session's recorder and awaits the recorder's queue before the tool runs. |
| `session/event` | emit `(session, event)` | `workspace-changes` | `turn/start` → snapshot; `tool/result` → remember seq; `turn/end` → record. |
| `session/disposed` | emit | `workspace-changes` | Drop recorder and temp directory. |
| `agent/turn-stopping` | serial `({ agent, turn, signal })` | `workspace-changes` | Record before the turn finishes stopping. |
| `internal/dispatch` | cordis internal, `{ global: true }` on `owner.ctx` | `terminal-bash` | Throws when a `sandbox/mode` session event would change the effective mode while the owner has open or pending PTY sessions. |

Ordering note for `tools/post-execute`: because `spill-policy` is prepended it is the outermost wrapper; it sees the content glob/grep already replaced (including their own spill footer) and may bound it again by tokens.

## Tools

All tools are registered with `ctx.tools.register(defineTool({...}))`. The parameter schema is the dsh `ParameterSchemaSpec` DSL: an object of properties, each `{ type, required?: true, description?, enum?, items?, oneOf?, const? }`; "required" is per property. Undeclared argument keys are not rejected by schema validation, which is why tools re-check unadvertised escalation fields in `execute`. Argument-value failures throw `ToolArgsError(violations)` → message `invalid arguments: <violations joined by "; ">`, code `INVALID_ARGS`. Each tool declares `output: { schema, render(args, value) → ContentBlock[], presentationMeta?(args, value) → JSON }`; `render` produces the model-facing text, `presentationMeta` becomes the persisted `tool/result` `meta`. `presentCall` / `presentResult` are pure UI projections.

`exec` (the `ToolExecution`) fields used here: `agent?` (`.id`, `.session`, `.options.provider/model`, `.ctx`), `signal`, `callId`, `rootCallId`, `name`, `parent?`.

Shared conventions for `read`, `read_image`, `write`, `edit`, `apply_patch`, `present`: relative paths resolve against the session working directory (`ctx.workingDirectory.ensure(exec.agent, exec.signal)`); without an agent the provider default cwd applies (`tool-fs/src/session-cwd.ts:16`). A leading `~` or `~/` expands to the host home in fs-local.

### Escalation fields (shared by `write`, `edit`, `apply_patch`, `bash`, `pwsh`)

Advertised only when the mounted capability confines (`ctx.fs.sandboxMode !== undefined` for file tools, `ctx.shell.sandboxMode !== undefined` for shell tools):

| Property | Schema | Description text |
|---|---|---|
| `sandbox_permissions` | `{ type: 'string', enum: ['workspace-write', 'danger-full-access'] }` | `The narrowest wider sandbox mode for a one-shot retry of the exact <subject> the sandbox just denied; the retry asks the user for approval.` (`<subject>` = `operation` for file tools, `command` for shell tools) |
| `justification` | `{ type: 'string' }` | File tools: `Required with sandbox_permissions: one sentence for the user explaining why this exact file operation needs the wider access. Use the language of the user’s current request.` Bash: same with `this exact command`. |

### `read` (`tool-fs/src/read.ts:77`)

- Description: `Read a UTF-8 text file and return line-numbered content.`
- Parameters: `file_path` string, required — `Path to read, resolved by the filesystem backend.`; `offset` number — `1-based first line to return. Defaults to 1.`; `limit` number — `Maximum number of lines to return. Defaults to <readLimit>.` (default 2000).
- Validation (`parseReadArgs`, `:55`): `file_path must be a non-empty string`; `offset must be a positive integer`; `limit must be a positive integer`; `limit must be less than or equal to <readLimit>`.
- `isConcurrencySafe: true`.
- Canonical value: `{ path: <processPath>, offset, lines: [{ number, text }], totalLines }`.
- Rendered text (`formatReadOutput`, `read-render.ts:152`):

```
<path>{path}</path>
<type>file</type>
<content>
{n}: {text}
...

{footer}
</content>
```

  Lines are `<number>: <text>` joined by `\n`; one blank line precedes the footer; with zero lines the body is the footer alone. Footers: `(Output capped. Showing lines {offset}-{end}. Use offset={end+1} to continue.)` when the byte cap stopped output; `(Showing lines {offset}-{end} of {total}. Use offset={end+1} to continue.)` when more lines exist; `(End of file - total {total} lines)` otherwise. `end` is the last returned line number, or `offset - 1` when no line was returned.
- Limits: `readLimit` 2000 lines; `readMaxLineLength` 2000 UTF-16 code units, overflow replaced by `<first 2000>... (line truncated to 2000 chars)`; `readMaxBytes` 51200 bytes of selected output (each line's UTF-8 bytes plus 1 separator byte for every line after the first); files `>= readStreamMinSize` (10 MiB) or of unknown size are streamed.
- Errors: `cannot read "<displayPath>": not found` (`FS_NOT_FOUND`, after emitting an `absent` observation); `cannot read "<displayPath>": not a regular file` (`FS_NOT_REGULAR_FILE`); `cannot read "<displayPath>": binary file` / `...: invalid UTF-8 text` (`FS_NOT_TEXT`); `offset <n> is out of range for "<displayPath>" (<total> lines)` (`FS_NOT_FOUND`; not raised for an empty file with offset 1, nor when the byte cap hit first).
- Persisted meta: `{ path, offset, lines, totalLines, lang? }` (`lang` from the file extension table in `dsh-util-code-language`).
- System prompt section `tool:read` (order `TOOL_READ` = 1100, only while the tool is visible in scope): `Use the read tool — not shell commands like cat, sed, head, or tail — to inspect text files. Use offset and limit to read a line range or continue a large file.`
- No sandbox/approval interaction (every mode permits reads). Emits `fs/observed` `present` with the stat version taken before reading.

### `read_image` (`tool-fs/src/read-image.ts:287`)

Registered only while `ctx.attachments` exists (inside `ctx.inject(['attachments'], ...)`) and `readImage` config is true.

- Description: `Read a PNG/JPEG/WebP/GIF file and return the image itself. Large images are downscaled automatically; do not install image libraries or create thumbnails to inspect an image.`
- Parameters: `file_path` string, required — `Path to the image file, resolved by the filesystem backend.`
- `isConcurrencySafe: true`.
- Canonical value: `{ path, image: { attachmentId, mediaType, bytes, width, height, name?, originalDimensions?: { width, height } } }`. Persisted meta: `{ path }` only.
- Rendered content: two blocks — a text envelope and `{ type: 'image', attachment: <ImageAttachmentRef> }`:

```
<path>{path}</path>
<type>image</type>
<content>
{mediaType} image, {width}x{height} px, {bytes} bytes{scaled}
</content>
```

  `{scaled}` (only when `originalDimensions` is present) = ` (downscaled from {ow}x{oh} px; {advice} to locate features in the original file)`, where `x = (ow/width).toFixed(2)`, `y = (oh/height).toFixed(2)`, and advice is `multiply coordinates by {x}` when `x === y`, else `multiply x coordinates by {x} and y coordinates by {y}`.
- Gate order (all before any file I/O except the last two): blank path → `ToolArgsError`; extension present but not `.png/.jpg/.jpeg/.webp/.gif` → `ImageInputError` `IMAGE_UNSUPPORTED_FORMAT` (`cannot read "<path>": the <ext> extension does not declare a supported image format; read_image accepts PNG/JPEG/WebP/GIF files, including extension-less files in those formats`); no attachment store → `ToolContextUnavailableError` (`cannot read "<path>" as an image: no attachment service is mounted`); declared media type not in `imageLimits.mediaTypes` → `IMAGE_UNSUPPORTED_FORMAT` (`cannot read "<path>": <type> images are not accepted by this deployment`); route gate — provider/model from `session.requestHeader().config` else `agent.options`, resolved via `ctx.llm.resolveModelInfo`; unresolved → `ToolContextUnavailableError` (`...: the current model route could not be resolved`); `inputModalities` missing `image` → `IMAGE_UNSUPPORTED_MODEL` (`cannot read "<path>" as an image: model "<model>" does not declare image input; switch to an image-capable model to read images`). Then resolve + stat (same not-found/regular-file errors as `read`), `readBytes` with cap `min(maxImageBytes, maxMessageImageBytes)`; an extension-less file is sniffed by signature (PNG 8-byte magic, JPEG `FF D8 FF`, `GIF87a`/`GIF89a`, `RIFF....WEBP`), unknown → `IMAGE_UNSUPPORTED_FORMAT` (`...: the file content is not a supported image format; read_image accepts PNG/JPEG/WebP/GIF`).
- `attachments.saveImage({ data, mediaType, name: basename(displayPath) })` failures keep their `AttachmentError` code but get a message `cannot read "<displayPath>": <detail>` for the codes listed in `saveFailureDetail` (`read-image.ts:234`), for example `at least one image side exceeds the <N>px limit; downscale the image and read the smaller copy`.
- Emits `fs/observed` `present`.

### `write` (`tool-fs/src/write.ts:73`)

- Description: `Create or fully replace a UTF-8 text file.`
- Parameters: `file_path` string, required — ``Path to write, resolved by the filesystem backend. Provide `file_path` before `content` in the arguments.``; `content` string, required — `Full UTF-8 text content to write.`; plus escalation fields under a confining `ctx.fs`.
- Validation: `file_path must be a non-empty string`. Empty `content` is valid.
- Canonical value: `{ path, operation: 'create'|'update', before: string|null, after: string }`.
- Rendered text:

```
<path>{path}</path>
<type>file</type>
<content>
{Created|Updated} file
</content>
```

- Persisted meta: `{ operation, path, diffs }` where `diffs = []` when `before === null`, else `computeHunkDiffs(path, before, after)` mapped to `{ path, oldText, newText }`.
- Execution order (`:112`): resolve sandbox policy (may ask approval) → `fs.resolve` → `fs/write-intent` waterfall → `fs.writeText(target, content, intent, signal, policy)` → on error `remediateFsError(sandbox.mapError(error, policy), displayPath)` → emit `fs/observed` present with the new version.
- System prompt `tool:write` (order 1200): `Read an existing file before overwriting it with write` + (` and prefer edit for targeted changes` when `edit` is visible) + `.`

### `edit` (`tool-fs/src/edit.ts:85`)

- Description: `Edit an existing UTF-8 text file by replacing literal text.`
- Parameters: `file_path` string, required — ``Path to edit, resolved by the filesystem backend. Provide `file_path` before `old_string` and `new_string` in the arguments.``; `old_string` string, required — `Literal text to replace.`; `new_string` string, required — `Literal replacement text. Use an empty string to delete the match.`; `replace_all` boolean — `Replace all matches. Defaults to false; when false, old_string must appear exactly once.`; plus escalation fields.
- Validation: `file_path must be a non-empty string`; `old_string must be a non-empty string`; `old_string and new_string must differ`.
- Canonical value `{ path, before, after }`. Rendered text: `The file {path} has been updated successfully.` or, with `replace_all`, `The file {path} has been updated. All occurrences were successfully replaced.` Meta: `{ path, diffs }`.
- Provider errors: `old_string was not found in "<displayPath>"` (`FS_EDIT_NOT_FOUND`); `old_string matched <n> times in "<displayPath>"; provide a more specific old_string or set replace_all to true` (`FS_AMBIGUOUS_EDIT`); `cannot edit "<displayPath>": file changed since it was read` (`FS_STALE_VERSION`, also for a missing file); `cannot edit "<displayPath>": not a regular file`; `cannot edit "<displayPath>": binary file` / `invalid UTF-8 text` (`FS_NOT_TEXT`).
- The intent waterfall runs inside the same `try` as `editText`, so a policy refusal is remediated too.
- System prompt `tool:edit` (order 1300): `Read a file before editing it unless you just created or edited it in this session.`

Model-facing remediation applied by `write`, `edit`, `apply_patch` (`tool-fs/src/error.ts:29`):

- `FS_NOT_OBSERVED` → message replaced by `cannot modify "<displayPath>": file has not been read — read the file, then retry` (same code, original as `cause`).
- `FS_STALE_VERSION` → `<provider message> — re-read the file, then retry`.
- `FS_SANDBOX_DENIED` (`sandbox.mapError`, `tool-fs/src/sandbox.ts:138`) → `[sandbox: file access denied under <mode> mode]\n[sandbox: escalation available — retry this exact operation once with sandbox_permissions (the narrowest wider mode that suffices) + justification; the approval prompt asks the user]`.

### `apply_patch` (`tool-fs/src/apply-patch.ts:26`; config `applyPatch`, default false)

- Description: `Create, update, delete, or move UTF-8 text files with one patch; prefer it over multiple edit calls when a change spans several files or separated regions.`
- Parameters: `input` string, required — `Patch text: start with *** Begin Patch and end with *** End Patch. Use *** Add File: path with + lines; *** Update File: path, optionally followed by *** Move to: path, with @@ or @@ context and space-prefixed context, + added, or - removed lines; *** End of File anchors the last hunk to the file end. Use *** Delete File: path to delete. Paths are relative to the Session working directory.`; plus escalation fields.
- Canonical value (strict): `{ phase: 'commit', cancelled: boolean, affectedPaths: string[], operations: [{ index, kind: 'add'|'update'|'delete'|'move', path, destination?, patchLine, status: 'completed'|'failed'|'unknown'|'skipped', code?, message?, hunkLine?, changes?: [{ path, before: string|null, after: string|null }] }] }`.
- Rendered text (`renderPatch`, `apply-patch-output.ts:105`):
  - All completed: `Success. No operations in patch.` for zero operations, else `Success. Updated the following files:` followed by one line per completed operation grouped adds, then updates (moves count as updates at their destination path), then deletes: `A <path>`, `M <path>`, `D <path>`.
  - Otherwise: `Patch stopped after <completed> of <total> operations.`; if any completed, `Completed:` plus the same A/M/D lines; then sections `Failed:`, `Outcome unknown:`, `Not executed:`. Failed/unknown rows: `- operation <i+1> (<kind> <path>[ -> <destination>], patch line <n>): <message>`; a failed move that wrote its destination adds `  destination <dest> was written; source <path> remains`. Skipped rows: `- operation <i+1> (<kind> <path>)`.
- Errors thrown as `isError` results (nothing changed on disk): syntax → `PatchToolError` code `PATCH_SYNTAX`, message `Invalid patch at line <n>: <reason>`; preflight refusals → `Patch rejected before any change (<k> problems):\n- operation <i+1> (<kind> <path>, patch line <n>): <message>` per refusal, with the first refusal's code (`FsError` code, or `PatchToolError` for `PATCH_SYMLINK_SOURCE`); a commit whose first operation failed with no change and every later one skipped is thrown the same way.
- Persisted meta: `{ diffs: [{ path, oldText, newText }], stopped: boolean }`. Diffs come only from completed/failed operations' `changes`: `before === null` → none (creation); `after === null` → `{ oldText: before, newText: '' }`; else `computeHunkDiffs`.
- System prompt `tool:apply_patch` (order 1350): `Prefer apply_patch over separate edit calls for changes across files or separated regions. Give every hunk enough surrounding context lines to match one place in the current file. The whole patch is checked first (syntax, hunk matching, missing files) and a rejected patch changes nothing; once applying starts, operations run in order, stop at the first failure, and are not rolled back, so re-read affected files before retrying when needed.`

### `glob` (`tool-fs-search/src/glob.ts:321`)

- Description: `Find files, not directories, whose paths match a glob pattern, including hidden and ignored files. Returns up to <globMaxResults> paths in modification-time order; a larger result <keeps the first paths | is sampled across top-level entries> and reports where the complete list was saved.`
- Parameters: `pattern` string, required — `Glob pattern to match file paths against (e.g. "**/*.ts", "src/**/*.test.js"). A pattern with no "/" matches the basename at any depth, so "*" and "*.ts" both search the whole tree; include a separator to anchor the depth.`; `path` string — `Directory to search in. Defaults to the session workspace; a relative path resolves against it.`
- Validation: `pattern must be a non-empty string` (blank after trim); `path must be a non-empty string when given`.
- `timeoutMs: <config timeoutMs>` (30000) on the definition, enforced by the tool-call timeout policy through `exec.signal`. `isConcurrencySafe: true`.
- Canonical value: `{ root, paths: string[] }` (all paths, workdir-relative when inside the workdir; `root` is `.` or the relativized `path` argument).
- Rendered text: `No files found`; or all paths joined by `\n` when `paths.length <= globMaxResults` (100); else `<page joined by \n>\n\n(Showing <k> of <seen> paths<basis> <recovery>)` where `basis` is `.` for head retention (or a flat sample) or `, sampled across <shown> of the <total> top-level entries this pattern matched instead of taken in modification-time order.` plus ` Narrow path to inspect a specific subtree.` when `shown < total`; `recovery` is `Full sorted result stored at: <locator>. <retrievalHint>` or `The complete result could not be saved; narrow pattern or path to see more.`
- The spill save (name hint `glob-results.txt`, content = all paths joined by `\n`) happens in the `tools/post-execute` listener; the plain `render` path (nested calls, replaced decisions) shows the no-save wording.
- Meta: `{ shape: 'paths', paths, truncated, total }`, byte-capped to `searchMetaMaxBytes`.
- System prompt `tool:glob` (order 1400): `Use the glob tool — not shell find — to discover files by path pattern.`

### `grep` (`tool-fs-search/src/grep.ts:286`)

- Description: `Search file contents with a ripgrep regular expression. Returns matching lines with line numbers, grouped by file. Returns up to <grepMaxMatches> matches; a larger result reports where the complete match list was saved.`
- Parameters: `pattern` string, required — `Regular expression to search for (ripgrep syntax).`; `path` string — `File or directory to search. Defaults to the session workspace; a relative path resolves against it.`; `include` string — `One glob filter for which files to search (e.g. "*.ts", "*.{js,jsx}"). Not a list; negation is not supported.`
- Validation: `pattern must be a non-empty string` (empty only; whitespace is a valid regex); `path must be a non-empty string when given`; `include` exactly `''` is treated as omitted; `include must be a non-empty glob when given`; `include must be a positive glob filter; negated patterns ("!…") are not supported`; `include must be one glob, not a comma-separated list (use {a,b} alternation instead)` (a comma at brace depth 0).
- `timeoutMs` and `isConcurrencySafe` as for `glob`.
- Canonical value: `{ matches: [{ path, lineNumber, line }] }`.
- Rendered text: `No matches found`; else header `Found <n> match|matches` (or `Found <kept> of <seen> matches` when capped), blank line, then per file (first-seen order) `<path>\nLine <n>: <text>` rows, files separated by a blank line; when capped a final `\n\n(<recovery>)` with `Full grep result stored at: <locator>. <retrievalHint>` or `The complete result could not be saved; narrow pattern, path, or include to see more.` Each line preview is capped at `grepMaxLineBytes` (2000 bytes, UTF-8 safe) with suffix ` (line truncated)`. A match whose line is not valid UTF-8 shows `(line is not valid UTF-8)`.
- Spill content (hint `grep-results.txt`): `Found <n> match|matches\n\n<all matches grouped, each line previewed>`.
- Meta: `{ shape: 'matches', files: [{ path, matches: [{ lineNumber, line }] }], truncated, total }`, byte-capped.
- Errors (`SearchError`, codes `SEARCH_INVALID_PATTERN`, `SEARCH_FAILED`, `SEARCH_RAW_OUTPUT_OVERFLOW`, `SEARCH_ABORTED`): `<tool> was aborted before completion (tool timeout or caller cancellation)`; `<tool> could not start its search command (ripgrep launch failed)`; `<tool> subprocess failed before reporting an outcome (ripgrep provider failure)`; `<tool> search command was killed by signal <sig>`; `<tool> pattern rejected by ripgrep: <stderr>` (stderr matches `/regex parse error|error parsing glob/i`); `<tool> search failed (exit <n>)[: <stderr>]`; `<tool> produced <n> bytes of raw output, over the <cap>-byte cap; narrow pattern, path, or include and retry`; `grep received malformed ripgrep --json output (<detail>)`.
- System prompt `tool:grep` (order 1500): `Use the grep tool — not shell grep or rg — to search file contents.` + (` Use read on a matched file when you need surrounding context.` when `read` is visible).
- Neither search tool goes through `ctx.fs`, the sandbox, or approval; they spawn `rg` unconfined through `ctx.subprocess` in the session working directory (or `process.cwd()` without an agent).

### `str_replace_editor` (`tool-str-replace-editor/src/index.ts:434`)

- Description: configurable; default is the multi-line text at `:20-32` (starts `Custom editing tool for viewing, creating and editing files`).
- Parameters: `command` string, required, enum `['view','create','str_replace','insert']`; `path` string, required (must be absolute); `file_text` string|null; `insert_line` integer|null; `new_str` string|null; `old_str` string|null; `view_range` array of integer|null. Descriptions are verbatim at `:438-471`. A `null` placeholder is treated as omitted, except `new_str: null` on `str_replace`, which is rejected.
- Output is a plain string. No `presentationMeta`. No session-cwd resolution (`ctx.fs.resolve(path, { signal })`), no escalation fields, no error remediation.
- Path errors: `path must be a non-empty string`; ``The path <p> is not an absolute path, it should start with `/`. Maybe you meant /<p>?``; `The path <displayPath> does not exist. Please provide a valid path.` (`FS_NOT_FOUND`, after an `absent` observation); ``The path <displayPath> is a directory and only the `view` command can be used on directories`` (`FS_NOT_REGULAR_FILE`).
- `view` file: reads the whole file with `readText`, emits `present`, returns `Here's the content of <displayPath> with line numbers (which has a total of <N> lines)[ with view_range=[a, b]]:\n` + lines formatted `<line number right-aligned to width 6><two spaces><text>` joined by `\n` + `\n`. `N = content.split('\n').length` (a trailing newline yields a final empty line). `view_range` errors: ``Invalid `view_range`. It should be a list of two integers.``; first element outside `[1, N]`; second element greater than `N`; second element smaller than the first unless it is `-1` (to end of file). Exact strings at `:157-174`.
- `view` directory: lists up to 2 levels, excluding names starting with `.`, `node_modules`, `__pycache__`; rows `d\t<displayPath>`, `f\t<displayPath>`, `?\t<displayPath>` including the root row, sorted by code-point comparison of the path; returns `Here're the files and directories up to 2 levels deep in <displayPath>, excluding hidden items, node_modules, and Python cache directories:\n<rows joined by \n>\n\n`. `view_range` on a directory → ``The `view_range` parameter is not allowed when `path` points to a directory.``
- `create`: requires `file_text` (``Parameter `file_text` is required for command: create``); refuses an existing path with ``File already exists at: <displayPath>. Cannot overwrite files using command `create`.`` (`FS_ALREADY_EXISTS`, also when the guarded write reports `FS_NOT_OBSERVED`); writes with the intent from `fs/write-intent` (default `createIfAbsent`); returns `New file created successfully at: <displayPath>`.
- `str_replace`: dispatches `fs/edit-intent` first, requires non-empty `old_str`, stats and reads raw text (no line-ending normalization), requires exactly one verbatim occurrence — ``No replacement was performed, old_str `<old>` did not appear verbatim in <displayPath>.`` (`FS_EDIT_NOT_FOUND`) or ``No replacement was performed. Multiple occurrences of old_str `<old>` in lines [<l1>, <l2>, ...]. Please ensure it is unique`` (`FS_AMBIGUOUS_EDIT`) — then `writeText` with `{ kind: 'replaceIfVersion', version: intent?.version ?? stat.version }`. Returns `The file <displayPath> has been edited successfully.`
- `insert`: requires `insert_line` and `new_str`; ``Invalid `insert_line` parameter: <n>. It should be within the range of lines of the file: [0, <N>]``; inserts `new_str.split('\n')` after line `insert_line`; same guarded write and success string.
- All long outputs are clipped at `maxOutputChars` (16000 UTF-16 units, surrogate-safe) and suffixed with `<response clipped><NOTE>To save on context only part of this file has been shown to you. You should retry this tool after you have searched inside the file with `grep -n` in order to find the line numbers of what you are looking for.</NOTE>`.
- Sandbox denial maps to the bare marker `[sandbox: file access denied under <mode> mode]` (no escalation hint). The mode is the session's standing policy.

### `bash` — one-shot (`tool-bash/src/index.ts:392`)

- Description (`bashDescription`, `:93`): ``Execute a bash command (`bash -c`) and return its stdout/stderr. Each call runs in a fresh shell; pass `workdir` instead of using `cd`. Managed `$DSH_*` variables expose current harness environment facts. Long output is truncated to its tail; the full output is saved to a file whose path is reported when available. Provide `description` before `command` in the arguments. Before any delete or move, verify that the resolved absolute target path is the intended one; never run it against a computed path you have not checked. An unset variable expands to an empty string, so guard variables in such paths with `${VAR:?}`. Commands may run under a file sandbox; a blocked file operation is reported as `[sandbox: file access denied under <mode> mode]`, a policy denial: do not retry another way.``
- Parameters (declared in this order):

| Property | Type | Required | Description |
|---|---|---|---|
| `description` | string | yes | `Clear, concise description of what this command does in active voice, 5-10 words (shown in the UI). Examples: "ls" → "List files in current directory"; "git status" → "Show working tree status"; "npm install" → "Install package dependencies".` |
| `command` | string | yes | `The bash command to execute.` |
| `timeoutMs` | number | no | With promotion: `Timeout in milliseconds. The executor applies its configured default and cap; on expiry the command moves to the background as a job instead of being killed.` Without: `Timeout in milliseconds. The executor applies its configured default and cap, and kills the command on expiry.` |
| `workdir` | string | no | `Working directory for this command. Defaults to the session workspace; a relative path is resolved against it.` |
| `run_in_background` | boolean | no (only present while a job registry is composed and `enableRunInBackground`) | `Run in the background and return a job id immediately (collect with job_output, stop with job_kill). No timeout applies.` |
| `sandbox_permissions`, `justification` | see above | no (only under a sandboxing executor) | |

- Validation (`validateBashArgs`, `:76`): `invalid command: expected a non-empty string`; `invalid description: expected a non-empty string`; `invalid timeoutMs: expected a positive number, got <json>`; escalation pairing (see Algorithms).
- Canonical value: one of
  - `{ kind: 'background', jobId, cwd }` → text `started background job <jobId>`;
  - `{ kind: 'promoted', cwd, jobId, timeoutMs, output }` → text `<output with trailing newline if non-empty>[still running after <timeoutMs>ms; moved to background job <jobId>]`;
  - `{ kind: 'foreground', cwd, exitCode, signal, timedOut, aborted, stopped?, timeoutMs, stdout: { text, truncated, spillPath? }, stderr: {...}, sandbox?: { mode, denied, enforcement?, runnerFailed? } }` → `renderResult`.
- Foreground text (`renderResult`, `tool-bash/src/render.ts:28`): stdout text; each truncated stream gets `\n[output truncated; full output: <spillPath or "(unavailable)">]` appended; a non-empty stderr is appended as `[stderr]\n<stderr>` after ensuring one newline separator; empty body becomes `(no output)`. Then markers, each on its own line, in this order: `[sandbox: file access denied under <mode> mode]` (+ escalation hint line with subject `command` when escalation is advertised) if `sandbox.denied`; `[timed out after <timeoutMs>ms]` if `timedOut`; `[stopped: <reason>]` if a kill came from outside the call; then `[killed by signal: <SIG>]` if `signal !== null`, else `[exit code: <n>]` if `exitCode !== 0` (a preparation timeout renders `[exit code: null]`). Exit code 0 adds no marker.
- Meta: `{ cwd }`.
- Errors: `tool call aborted` (`HarnessError` code `ABORTED`, name `AbortError`) on caller cancellation; `SubprocessError` `SUBPROCESS_SPAWN_NOT_FOUND` (`cannot start "bash": the program or the working directory does not exist (<detail>)`) or `SUBPROCESS_SPAWN_FAILED`; `SandboxUnavailableError` (`SANDBOX_UNAVAILABLE`) when the runner failed; `JobError` `JOB_BACKGROUND_DISABLED` (`run_in_background is disabled for this deployment (enableRunInBackground: false)`); `ToolContextUnavailableError` (`background jobs unavailable: load @deepseek-ai/dsh-jobs and @deepseek-ai/dsh-tool-jobs`); `SandboxEscalationError` codes. A nonzero exit is **not** an error result.
- System prompt `tool:bash` (order 1000): `Check the [exit code: N] marker on every bash result; investigate failures before moving on.`
- Registration follows the job registry: without `ctx.jobs` the foreground-only definition is registered; when `jobs` appears it is swapped for the job-backed definition, and swapped back when `jobs` unloads (`:570-583`).

### `bash` — persistent (`tool-bash-persistent/src/index.ts:417`)

- Description: configurable; default `Run commands in a persistent bash shell. State, including the current directory and exported environment variables, persists across calls for this agent.` (the minimal bundles override it).
- Parameters: `command` string, required — `The bash command to run. Relative path is preferred in the command.`
- Output: plain string. Requires an owning agent (`bash requires an owning agent session`); blank command → `command must be a non-empty string`.
- Result forms: command output followed by `[Command finished with exit code <n>]` (marker alone when output is empty); clipped output gets the `<response clipped>` note (same text as `str_replace_editor`), and a lost-prefix note `<response clipped><NOTE>The beginning of this command output was dropped by the terminal scrollback limit. The following text is the earliest retained output.</NOTE>\n` is prepended when the start marker scrolled out; on timeout: `Your command timed out after <seconds> seconds or experienced an OOM error. Below is partial output:\n<partial>\n[Command timed out or OOM]\nThe persistent bash shell was reset; the next bash call starts from the workspace with a fresh current directory and environment.`; on shell exit: `<partial>\n[shell exited: code <n>]` or `[shell killed by signal: <SIG>]` or `[shell exited]`, then the reset sentence.
- No sandbox escalation fields; confinement is whatever `terminal-bash` applied when it spawned the shell under the session's standing policy.

### `pwsh` and persistent `pwsh` (catalog)

`dsh-tool-pwsh` mirrors `dsh-tool-bash` field for field (`description`, `command`, `timeoutMs`, `workdir`, `run_in_background`, escalation fields; same three output kinds and markers) with PowerShell wording; the executor argv is `[pwsh, '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', ENCODING_PREAMBLE + command]`. `dsh-tool-pwsh-persistent` mirrors the persistent bash tool over the `pwsh` dialect of `terminal-bash`. On Windows `dsh-base` mounts the pwsh pair instead of the bash pair.

### `present` (`deliverables/tool-present/src/index.ts:38`)

- Description: `Declare existing files as final deliverables for the user. Hosts may show presented files only after your turn ends, so call it once the files are final. If the user needs to review files earlier, such as before a tool call that waits for their answer, link them in your message instead. Use it when the user needs a separate file, especially Office documents, spreadsheets, and slide decks; prefer your final response when that suffices. The user opens the current files; their contents are not copied.`
- Parameters: `files` array, required — `Usually the 1-2 most important deliverables; at most 4 per call.`; items `{ path: string (required) — "Path of an existing regular file. Relative paths use the Session working directory.", description?: string — "Brief description for the user." }`, `additionalProperties: false`.
- Canonical value: `{ turn, files: [{ path: <processPath>, description? }] }`. Rendered: one line per file `Presented <path>`.
- Errors: `present requires an agent Session`; `present requires an open turn` (both `ToolContextUnavailableError`); `present accepts 1 to <maxFiles> files`; `present requires a non-empty file path`; `Cannot present <path>: not a regular file` (`FS_NOT_REGULAR_FILE`, including a symlink, checked with `lstat` first); `Cannot present <path>: file not found. Check the path, create the file if needed, and retry.` (`FS_NOT_FOUND`).
- Side effect: on the `tools/result` event for a non-error result, appends `deliverables/presented { turn, callId, files }`.

## Configuration

"Service class" = the package default-exports a `Service` subclass with `static Config` / `static inject`. "Function plugin" = named exports `name`, `inject`, `Config`, `apply`. Optional services are read with `ctx.get(name)` or a nested `ctx.inject([...])`.

| Package | Form / exported name | inject (required) | Optional services | Config fields (type, default) |
|---|---|---|---|---|
| `dsh-fs` | abstract Service `FileSystem` (key `fs`) | — | — | none |
| `dsh-fs-local` | Service class `LocalFileSystem` | — | — | `cwd: string = process.cwd()` (resolution base, not a containment boundary); `diffBasisMaxBytes: number = 10485760` (exclusive cap on each side of an overwrite diff basis; must be a positive safe integer no greater than the runtime max string/buffer length, else construction throws `fs-local: diffBasisMaxBytes must be a positive safe integer no greater than <max>`) |
| `dsh-fs-sandbox` | Service class `SandboxedFileSystem` | `sandboxPolicy` | — | same as fs-local |
| `dsh-fs-observation-policy` | function plugin, `name = 'fs-observation-policy'` | none (no `inject` export) | — | none |
| `dsh-tool-fs` | function plugin `tool-fs` | `tools`, `fs`, `systemPrompt`, `workingDirectory` | `attachments` (gates `read_image`), `llm`, `sandboxPolicy` (required when `fs.sandboxMode` is defined), `approval` | `read: boolean = true`; `readImage: boolean = true`; `write: boolean = true`; `edit: boolean = true`; `applyPatch: boolean = false`; `readLimit: number = 2000`; `readMaxLineLength: number = 2000`; `readMaxBytes: number = 51200`; `readStreamMinSize: number = 10485760`. The four numbers must be positive integers (`tool-fs: <name> must be a positive integer`). |
| `dsh-tool-fs-search` | function plugin `tool-fs-search` (async `apply`) | `tools`, `systemPrompt`, `subprocess`, `workingDirectory` | `spillStore` | `sampleOverCapGlobResults: boolean` (**required**, no default); `globMaxResults = 100`; `grepMaxMatches = 250`; `grepMaxLineBytes = 2000`; `searchMetaMaxBytes = 65536`; `rawOutputMaxBytes = 20000000`; `graceMs = 3000` (≤ 2147483647); `stderrMaxBytes = 65536`; `timeoutMs = 30000`. All positive integers. |
| `dsh-tool-str-replace-editor` | function plugin `tool-str-replace-editor` | `tools`, `fs` | `sandboxPolicy` | `maxOutputChars: number = 16000` (positive safe integer); `description: string = <default text>` (non-blank) |
| `dsh-sandbox` | abstract Service `SandboxProvider` (key `sandbox`) | — | — | none |
| `dsh-sandbox-local` | Service class `LocalSandboxProvider` | — | `skills` (Windows only, registers an ACL diagnosis skill) | `runnerCommand: string[] = []` (non-empty overrides the platform chain; bwrap-style profile args are appended; asserts full enforcement, no probe); `runnerFailureSignatures: string[] = []` (required non-empty with `runnerCommand`, rejected without it; entries non-empty single-line); `probeTimeoutMs: natural = 5000` (must be positive finite) |
| `dsh-sandbox-policy` | Service class `SandboxPolicyService` (key `sandboxPolicy`) | `sessionProjections` | `systemPrompt` | `mode: 'read-only'\|'workspace-write'\|'danger-full-access' = 'read-only'`; `workspaceRoot: string` (no schema default; falls back to `process.cwd()`; must be absolute, no NUL); `additionalWritableRoots: string[] = []` (each absolute, no NUL; deduplicated) |
| `dsh-subprocess` | abstract Service `SubprocessRuntime` (key `subprocess`) | — | — | none |
| `dsh-subprocess-local` | Service class `LocalSubprocessRuntime` | — | — | none (every limit arrives on the spawn spec) |
| `dsh-shell` | abstract Service `ShellExecutor` (key `shell`) | — | — | none |
| `dsh-bash-local` | Service class `LocalBashExecutor` | `subprocess` | — | All fields are volatile (live-reloadable, read with `.get()` at each `resolve`): `cwd: string` (optional; else `process.cwd()`); `timeoutMs = 120000`; `maxTimeoutMs = 600000`; `maxOutputBytes = 64000`; `maxSpillBytes = 67108864`; `graceMs = 3000` (≤ 2147483647). Each must be positive finite at use (`bash-local: <field> must be a positive finite number`). |
| `dsh-bash-sandbox` | Service class `SandboxBashExecutor` (extends local) | `subprocess`, `sandbox`, `sandboxPolicy` | — | same as bash-local |
| `dsh-shell-env` | function plugin `shell-env` constructing `ShellEnvRegistry` (key `shellEnv`) | `[]` | `profileContext` | `dshHome: string` (optional; else `$DSH_HOME`, else `~/.dsh`) |
| `dsh-tool-bash` | function plugin `tool-bash` | `tools`, `shell`, `systemPrompt`, `shellEnv`, `workingDirectory` | `jobs`, `sandboxPolicy` (required when `shell.sandboxMode` is defined), `approval` | `enableRunInBackground: boolean = true`; `promoteOnTimeout: boolean = true` (effective only with background enabled and a job registry) |
| `dsh-tool-bash-persistent` | function plugin `tool-bash-persistent` | `tools`, `terminals`, `workingDirectory` | — | `backendType: string = 'shell'`; `timeoutMs: number = 300000`; `maxOutputChars: number = 16000`; `description: string = <default>` |
| `dsh-terminal` | Service class `TerminalSessionService` (key `terminals`) | — | `agents` (liveness check) | none |
| `dsh-terminal-bash` | function plugin `terminal-bash` | `terminals`, `sandboxPolicy`, `subprocess`, `workingDirectory` | `sandbox` (required for confined modes) | `backendType = 'shell'`; `shellDialect: 'bash'\|'pwsh' = 'bash'`; `shellPath` (default `/bin/bash`, or resolved pwsh); `shellArgs` (default `['--noprofile','--norc','-i']`, pwsh `['-NoLogo','-NoProfile']`; an empty array means default); `rows = 40`; `cols = 160`; `scrollbackLines = 10000`; `scrollbackMaxBytes = 4194304`; `maxReadBytes = 262144`; `pollIntervalMs = 50`; `exactProbeAfterMs = 150`; `idleSilenceMs = 3000`; `handoffGraceMs = 500`; `promptTailGraceMs = 0`; `timeoutMs = 30000`; `disposeGraceMs = 3000`. Constraints: numbers are positive safe integers (`promptTailGraceMs` may be 0); `maxReadBytes <= scrollbackMaxBytes`; `handoffGraceMs >= pollIntervalMs`; non-zero `promptTailGraceMs >= pollIntervalMs`. |
| `dsh-spill` | abstract Service `SpillStore` (key `spillStore`) | — | — | none |
| `dsh-spill-local` | Service class `LocalSpillStore` | — | — | `root: string` (optional; default a lazily created private `dsh-spill-XXXXXX` directory under the OS temp dir); `cleanupPeriodDays: integer >= 0 = 30` (0 disables the startup sweep) |
| `dsh-spill-policy` | function plugin `spill-policy` | `tools` | `llm`, `attachments`, `fs`, `spillStore` | `maxInlineTokens: number` (optional; omitted disables the plugin; must be a non-negative safe integer) |
| `dsh-attachment` | abstract Service `AttachmentStore` (key `attachments`) | — | — | none |
| `dsh-attachment-local` | Service class `LocalAttachmentStore` | — | — | `dshHome: string` (optional); `maxImageBytes = 52428800`; `maxImagesPerMessage = 20`; `maxMessageImageBytes = 209715200`; `maxImagePixels = 64000000`; `maxImageDimension = 65535`; `normalizedImageMaxPixels = 4194304`; `normalizedImageMaxDimension = 8192`; `normalizedImageMaxBytes = 4194304`; `imageCompressionConcurrency = 2` (1..8). All integers ≥ 1. |
| `dsh-tool-present` | function plugin `tool-present` | `tools`, `fs`, `agents`, `workingDirectory` | — | `maxFiles: number = 8` (positive safe integer) |
| `dsh-workspace-changes` | function plugin `workspace-changes` (provides `workspaceChanges`) | `subprocess`, `fs` | — | `timeoutMs = 30000`; `outputMaxBytes = 8388608`; `maxFiles = 500`; `maxFileBytes = 2097152`; `diffTimeoutMs = 100`. All positive safe integers. |
| `dsh-deliverable-file-references` | function plugin `deliverable-file-references` | `systemPrompt` | — | none |
| `dsh-ssh` (catalog) | Service class `SshConnection` (key `ssh`) | — | — | `host` (required, `^[a-zA-Z0-9][a-zA-Z0-9_.@-]*$`); `launch` (`{ kind: 'node-script', node, bootstrapPath?, bootstrapHash? }` or `{ kind: 'executable' }`); `helper` (absolute); `helperHash` (64 hex); `workspace` (absolute); `requestTimeoutMs = 30000`; `maxFrameBytes = 67108864`; `maxPending = 128`; `leaseMs = 30000` (3000..600000) |
| pwsh packages (catalog) | `LocalPwshExecutor` / `SandboxPwshExecutor` Service classes; `tool-pwsh`, `tool-pwsh-persistent` function plugins | as the bash twins | | bash-local fields plus an optional explicit pwsh executable path |

### Shipped composition values (`packages/bundle/*`)

- `dsh-base` (`packages/bundle/base/cordis.patch.yml`): `subprocess-local`; `sandbox-local`; `sandbox-policy { mode: !!js process.env.DSH_PERMISSION_MODE ?? 'workspace-write', workspaceRoot: !!js process.cwd() }`; `bash-sandbox { timeoutMs: 60000 }` (disabled on win32, where `pwsh-sandbox` is enabled); `shell-env`; `tool-bash` / `tool-pwsh` by platform; `fs-observation-policy` with `disabled: true`; `tool-fs { applyPatch: false }`; `tool-fs-search { sampleOverCapGlobResults: false }`; `spill-local`; `spill-policy { maxInlineTokens: 12500 }`; `fs-sandbox`; `attachment-local`. The approval plugin's policy is `never` when the mode is `danger-full-access`, else `ask`.
- `sdk-minimal` (`packages/bundle/sdk-minimal/cordis.patch.yml`; the web `minimal` preset carries the same tool rows): `fs-local` (unsandboxed), `tool-fs { read: false, readImage: true, write: false, edit: false }`, `terminal`, `terminal-bash { timeoutMs: 300000 }` (a second row with `shellDialect: pwsh` on Windows), `tool-bash-persistent { timeoutMs: 300000, description: <custom multi-line text> }`.
- `tool-str-replace-editor` is in no shipped bundle; it is mounted by overlays (`snapshots/sdk/persistent-tools/cordis.yml` inserts it with `maxOutputChars: 16000`; `apps/web/tests/standalone-string-editor.overlay.yml`).
- `web-app`: adds `workspace-changes`, `deliverable-file-references`, and (presets) `tool-present`; `sdk-app` also mounts `tool-present` and `deliverable-file-references`.

## Formats

### Local filesystem identities

- `FsTargetKey` (fs-local): the realpath of the path; for a missing path, `join(realpath(nearest existing ancestor), ...missing segments)` (`fs-local/src/fsio.ts:178-227`).
- `displayPath` (fs-local): absolute spelling without symlink resolution. On POSIX a path containing a `..` segment keeps its raw spelling (`cwd + sep + path`) so traversal resolves physically; otherwise `path.resolve(cwd, path)`.
- `FsVersion` (fs-local): `"<dev>:<ino>:<size>:<mtimeNs>:<ctimeNs>"` from a bigint `stat` (`fsio.ts:75`). Sentinel after a write whose post-probe finds nothing: `missing:<targetKey>`.

### Atomic write staging layout (fs-local)

For a write to `<dir>/<base>`: staging directory `<dir>/.<base>.<pid>.<uuid>.tmpdir` (mode 0700), temp file `<base>.tmp` inside it (opened `wx`, mode 0600). Publication: `link(temp, target)` for `createIfAbsent`, else `rename(temp, target)`; then the staging directory is removed recursively.

### Patch grammar (`fs-patch/src/parse.ts`)

```
*** Begin Patch
*** Add File: <path>
+<line>
*** Delete File: <path>
*** Update File: <path>
*** Move to: <path>          (optional, only directly after Update File)
@@                            (optional before the first hunk; "@@ <context>" carries an anchor)
 <context line>
-<removed line>
+<added line>
*** End of File               (optional; marks the preceding hunk as EOF-anchored)
*** End Patch
```

Markers: `*** Begin Patch`, `*** End Patch`, `*** End of File`, `*** Move to: `, `*** Add File: `, `*** Delete File: `, `*** Update File: `. Parsed records: `PatchOperation = { kind: 'add', path, lineNumber, content } | { kind: 'delete', path, lineNumber } | { kind: 'update', path, lineNumber, moveTo?, hunks }`; `PatchHunk = { lineNumber, context?, oldLines, newLines, isEndOfFile }`. Full rules are in Algorithms.

### Model-facing text formats

- `read` envelope, `write` envelope, `read_image` envelope, `edit` sentences, `apply_patch` report, `glob`/`grep` text: see Tools.
- Shell result markers (parsed back by `parseExitStatus`): `\n[exit code: <digits>]` and `\n[killed by signal: <name>]` anchored at end of text. Other markers: `[stderr]`, `[output truncated; full output: <path>]`, `[timed out after <n>ms]`, `[stopped: <reason>]`, `[still running after <n>ms; moved to background job <id>]`, `[some output was dropped from memory; full output: <paths joined by ", " or "(unavailable)">]`.
- Sandbox markers: `[sandbox: file access denied under <mode> mode]`; `[sandbox: escalation available — retry this exact <subject> once with sandbox_permissions (the narrowest wider mode that suffices) + justification; the approval prompt asks the user]`; `[sandbox: the sandbox runner itself failed under <mode> mode — the command did not run; this is a sandbox problem, not a command failure]`.
- Approval audit reason for an escalation: `escalate sandbox to <mode>: <justification>`; display reason (en): `Allow this operation with <mode> permissions: <justification>` (also zh, ja, es, fr, de, ru, pt in `sandbox/src/locales.ts`).
- Sandbox policy runtime context (one of three strings, `sandbox-policy/src/index.ts:61-79`): `Current DSH file policy: read-only. Any available operation enforced by the DSH file sandbox cannot modify files in the standing mode. Do not refuse a required modification from this policy alone: try an available tool normally and follow any denial and escalation guidance it returns.`; `Current DSH file policy: workspace-write. Any available operation enforced by the DSH file sandbox may modify files under the session workspace: <JSON string of root>.[ Additional writable directories: <JSON array>. On Windows, these additional grants apply to file tools only, not sandboxed processes.] Some platform temporary areas may also be writable.`; `Current DSH file policy: danger-full-access. The DSH file sandbox does not restrict file modifications by available operations.`
- Spill-policy notice: `(Omitted <n> bytes.[ Omitted <k> images.] Full formatted result stored at: <locator>. <retrievalHint>)`; the gap marker between retained head and tail is `\n\n[...]\n\n`; the notice is appended as `\n\n<notice>`. Spill-local's `retrievalHint` is `Use read with offset/limit, or grep this path to search within it.` An image inside spilled text is written as `\n[Image: <JSON path>; <mediaType>; <w>x<h>. Use read_image to view it.]\n`.

### Sandbox runner argv (`sandbox-local/src/profiles.ts`)

- bwrap: `bwrap --ro-bind / / --dev /dev --unshare-pid --proc /proc --die-with-parent [--tmpfs /tmp --bind <root> <root> ...] -- <argv...>`. The bracketed part is present only for `workspace-write`; roots = `workspaceWritableRoots(policy)`.
- Landlock: `<launcher> --ro / --rw /dev/null [--rw /tmp --rw <root> ...] -- <argv...>`.
- Seatbelt: `sandbox-exec -p "<profile>" -- <argv...>` with profile forms joined by single spaces: `(version 1) (allow default) (deny file-write*) (allow file-write* (literal "/dev/null"))` and, when `writableRoots(policy)` is non-empty, `(allow file-write* (subpath "<r1>") (subpath "<r2>") ...)`. SBPL strings escape `\` and `"`.
- Operator override: `[...runnerCommand, ...bwrapProfileArgs(policy), '--', ...argv]`.
- Windows ACL (catalog): `[node, runner.js, '--workspace', <dir>, '--temp', <dir>, '--mode', <read-only|workspace-write>, ['--write-sid', <sid>, '--temp-write-sid', <sid>], '--', <argv...>]`.
- None of the profiles restricts network access; `--unshare-pid` is the only non-file isolation.

`landlock-run` CLI contract (`native/system/docs/cli-contract.md`): `landlock-run [--ro <path>]... [--rw <path>]... -- <argv>...` and `landlock-run --probe`; exit 125 for every launcher failure with one stderr line prefixed `landlock-run: `; probe prints `landlock: fully enforced` or `landlock: partially enforced (older ABI)`; a partial-ABI run prints `landlock-run: partial enforcement (older Landlock ABI)` on stderr and continues.

Per-runner classification tables (`sandbox-local/src/index.ts:225-260`):

| Runner | `denialSignatures` (case-insensitive stderr substrings) | `runnerFailureRules` |
|---|---|---|
| bwrap | `read-only file system` | `fatalSignatures: ['bwrap: ']` |
| landlock | `permission denied` | `allowedExitCodes: [125]`, `fatalSignatures: ['landlock-run: ']`, `informationalLines: ['landlock-run: partial enforcement (older Landlock ABI)']` |
| seatbelt | `operation not permitted` | `fatalSignatures: ['sandbox-exec: ']` |
| windows-acl | `access is denied`, `access to the path`, `permission denied`, `operation not permitted` | `allowedExitCodes: [127]`, `fatalSignatures: ['windows-acl-run: ']` |
| runnerCommand | `read-only file system`, `permission denied` | `fatalSignatures: <configured>` |

### Subprocess formats

- Environment: child env = `scrubbedParentEnv()` (drop names matching `/KEY|PASSWORD|SECRET|TOKEN/i` and names starting with `DSH_` case-insensitively; overlay proxy variables from `dsh-http-proxy`) merged with the spec's explicit `env` (`undefined` values are tombstones; on Windows keys merge case-insensitively).
- Collector spill file: `<spillDir>/dsh-subprocess-<pid>-<counter>-<12 hex>-<stdout|stderr>.log`, opened `wx` mode 0600; default `spillDir` is a per-process `mkdtemp(<tmpdir>/dsh-subprocess-)` directory, removed at process exit only if empty.
- Control channel: fd 7 in the child, announced by `DSH_SUBPROCESS_CONTROL=pipe` (consumed and deleted by `openInheritedControlChannel`).
- Linux scope launch: `systemd-run --user --scope --quiet --collect [--expand-environment=no] --unit=<unitBase> -- <runner invocation> -- <argv...>`; signalling `systemctl --user kill --kill-who=all --signal=<SIG> <unit>` (the older spelling, which newer systemctl accepts as a prefix of `--kill-whom`); state `systemctl --user show --property=LoadState --property=ActiveState --property=TasksCurrent <unit>`. Private launch files: `<dir>/launch-request.json` (consumed by the bootstrap) and `<dir>/startup-error.json`. Runner selection env: `DSH_SUBPROCESS_RUNNER`.
- Windows fallback tree kill: `taskkill /PID <pid> /T /F`.

### Shell environment

- bash-local `ENV_OVERRIDES`: `NO_COLOR=1`, `TERM=dumb`, `PAGER=cat`, `GIT_PAGER=cat`. Final explicit env = `{ ...ENV_OVERRIDES, ...spec.env, ...spec.dshEnv }`.
- Built-in managed variables from `ctx.shellEnv.collect` (`shell-env/src/index.ts:164`): `DSH_HOME` (resolved home), `DSH_SHELL=1`, `DSH_NODE_EXECUTABLE` (`process.execPath`, omitted in a single-executable build), `DSH_SESSION_ID` (session header id, when an agent exists), and with a `profileContext`: `DSH_PROFILE`, `DSH_PROFILE_DIR`, `DSH_INSTALL_DIR` (`dirname(profile.installAnchor)`). These seven keys are reserved.
- terminal-bash child env: `TERM=dumb`, `PAGER=cat`, `GIT_PAGER=cat`, `DSH_SHELL=1`, `DSH_SESSION_ID=<owner agent id>`, `DSH_PTY_SESSION_ID=<pty-N>`; bash dialect adds `PS1` with the value `dsh> ` (five characters including the trailing space), `PROMPT_COMMAND` with the value `printf "\033]133;D;%s\007" "$?"; PS1='dsh> '` (prints the OSC marker carrying the last exit status, then re-asserts PS1), and `BASH_SILENCE_DEPRECATION_WARNING=1`. Note the terminal's `DSH_SESSION_ID` is the owner **agent** id, while the one-shot shell tools set it to the session header id; pwsh dialect adds `NO_COLOR=1` and installs `function prompt { [Console]::Write([char]27 + ']133;D;' + [int]$LASTEXITCODE + [char]7); 'dsh> ' }` at startup.
- Deployment env read by the base bundle: `DSH_PERMISSION_MODE` (initial sandbox mode and approval policy).

### Persistent bash wire text (`tool-bash-persistent/src/index.ts:67-88`)

Per command a UUID nonce defines `start = __DSH_PERSISTENT_BASH_START_<uuid>__` and `end = __DSH_PERSISTENT_BASH_END_<uuid>:`. The single physical line sent is:

```
printf '%s\n' $'<start>'; eval -- $'<command>'; __dsh_persistent_bash_status=$?; printf '%s%s\n' $'<end>' "$__dsh_persistent_bash_status"
```

with ANSI-C quoting that escapes `\`, `'`, CR and LF. Shell setup line sent once after spawn: `stty -echo; set +H`.

### Spill store layout (spill-local)

`<root>/session-<first 12 hex of sha256(sessionId)>/<12 random hex>-<encodeSegment(suggestedName)>`; directories 0700, files 0600 created with `wx`. `encodeSegment`: keep `[A-Za-z0-9._-]`, escape every other UTF-16 unit (and `~`) as `~XXXX` (uppercase hex, 4 digits); `''` → `~`, `.` → `~002E`, `..` → `~002E~002E`. Default root name pattern `dsh-spill-[A-Za-z0-9]{6}`; session directory pattern `session-[0-9a-f]{12}` (the cleanup sweep only touches entries of exactly these forms).

### Attachment store layout (attachment-local)

Root `<DSH_HOME>/attachments/v1`:

- normalized images: `objects/<first 2 hex>/<sha256 hex>` (mode 0400);
- verbatim files: canonical object `file-objects/<2 hex>/<sha256>` plus a hard-link alias `files/<2 hex>/<sha256>/<leaf name>`;
- staging: `tmp/<uuid>` (0600, `O_CREAT|O_EXCL`).

Request-image cache: `<DSH_HOME>/cache/attachments/request-images/<2 hex>/<variant hash>`.

Identifiers: `AttachmentId = "sha256:<64 lowercase hex>"` (digest of the stored bytes: the normalized image, or the verbatim file); `ImageVariantId = "sha256:" + sha256(JSON descriptor)` where the descriptor is `{"transformVersion":"request-image-v6","attachmentId":...,"targetWidth":...,"targetHeight":...,"encodedByteBudget":...,"encoding":{"webpQualities":[85,75,60],"webpEffort":0,"jpegQualities":[85,75,60],"order":["alpha:webp","opaque:jpeg"],"colourspace":"srgb"}}` with keys in exactly that order (`attachment-local/src/request-image.ts:56-72`).

### Workspace-changes git commands

All run with env `GIT_CONFIG_COUNT=0 GIT_TERMINAL_PROMPT=0 GIT_OPTIONAL_LOCKS=0 LC_ALL=C` plus per-command additions: `rev-parse --show-toplevel --absolute-git-dir --git-path objects`; `add --all --ignore-errors [-- . :(exclude)<path>...]` with `GIT_INDEX_FILE=<scratch>/index`, `GIT_OBJECT_DIRECTORY=<scratch>/objects`, `GIT_ALTERNATE_OBJECT_DIRECTORIES=<repo objects>`; `write-tree`; `diff-tree -r -M -z --numstat <before> <after>`; `ls-tree -z -l <tree> -- <path>` with `GIT_LITERAL_PATHSPECS=1`; `cat-file blob <oid>`; `ls-files -z --stage`; `check-ignore -z --stdin`. Scratch directory: `mkdtemp(<tmpdir>/dsh-workspace-changes-)` with `objects/`, `index-*/index`, and `captures/<sha1 of content>`.

### Other formats

- `dsh-resource://file/session/<sessionId>/<path>` and `dsh-resource://file/absolute/<path>` (`util/workspace-path/src/file-address.ts`): segments are `encodeURIComponent`-encoded with `:` kept literal; UNC absolute paths keep one empty leading segment; parsing ignores `?`/`#` suffixes.
- File media URL: `new URL('api/file?path=' + encodeURIComponent(path), base)` for an `http(s)` or `dsh-app://app/` base and an absolute non-UNC path without control characters.
- Lock file (`dsh-atomic-write`): `<file>.lock` containing `<pid>\n` (mode 0600, `wx`); takeover claim `<file>.lock.takeover-<16 hex of sha256(record)>`; atomic temp `<file>.<12 hex>.tmp`.
- ripgrep argv: glob = `rg --no-config --files [--glob=!** --glob={d1,d2,...}/] --glob=<pattern> --sort=modified --no-ignore --hidden` + for each of `.git .svn .hg .bzr .jj .sl`: `--glob=!**/<name> --glob=!**/<name>/**` + `[-- <path>]`; grep = `rg --no-config --json --regexp=<pattern> [--glob=<include>] [-- <path>]`. grep uses ripgrep's default ignore/hidden rules; glob does not.
- `rg --json` records consumed by grep: only `{"type":"match","data":{"path":{"text":...},"line_number":N,"lines":{"text":...}|{"bytes":...}}}`.

## Algorithms and invariants

### A. Local filesystem provider (`fs-local/src/index.ts`, `fsio.ts`)

1. **Resolve** (`fsio.ts:150-227`). Expand a leading `~` / `~/` to the host home. Reject blank paths with `FS_NOT_FOUND` `file_path must be a non-empty string`. Compute `displayPath`; try `realpath(displayPath)`; on `ENOTDIR` throw `FS_NOT_FOUND` `cannot resolve "<p>": a parent path segment is not a directory`; on `ENOENT` walk up to the nearest existing ancestor, realpath it, and re-append the missing segments. A pre- or post-aborted signal throws `FS_ABORTED` `resolve aborted` (same pattern for `stat aborted`, `lstat aborted`, `read aborted`, `write aborted`, `edit aborted`, `delete aborted`, `move aborted`, `list aborted`).
2. **Probe** (`fsio.ts:262`). `stat` with bigint fields; `ENOENT` and `ENOTDIR` mean absent (`null`). Mode is `mode & 0o777`.
3. **Text reads** (`fsio.ts:395`, `:495`). Require a regular file. Binary rule for reads: a NUL byte within the first 8192 bytes → `FS_NOT_TEXT` `binary file`. Decode with fatal UTF-8; invalid → `FS_NOT_TEXT` `invalid UTF-8 text`. No newline normalization on read. The streaming reader applies the same sample rule across chunk boundaries and a streaming decoder.
4. **Edit read** (`readForEdit`, `fsio.ts:759`). Reject **any** NUL byte in the whole file. Normalize `\r\n` → `\n` (lone `\r` untouched). Detect style from the first 4096 characters: `CRLF` when the CRLF count exceeds the bare-LF count, else `LF`. Write-back restores `CRLF` by re-normalizing then replacing every `\n` with `\r\n`.
5. **Per-target mutex** (`index.ts:124-145`). A map from target key to a tail promise serializes mutations per key. Multi-key operations (move) take distinct keys in sorted order and release in reverse. Two concurrent guarded writes therefore resolve deterministically: one wins, the other fails `FS_STALE_VERSION`.
6. **writeText** (`index.ts:216`). Inside the lock: probe; existing non-file → `FS_NOT_REGULAR_FILE` (`cannot write "<p>": not a regular file`). Guards (`writeTarget`, `:348`): `replaceIfVersion` requires existence (`...: file no longer exists`) and equal version (`...: file changed since it was read`), both `FS_STALE_VERSION`; `createIfAbsent` on an existing file → `FS_NOT_OBSERVED` `cannot overwrite existing "<p>" without reading it first`. Diff basis: read `before` only when the file exists and the new content's UTF-8 size is `< diffBasisMaxBytes`; `readTextForDiff` (`fsio.ts:784`) returns `null` for non-regular, size `>= max`, size changed while reading, any NUL, invalid UTF-8, or any errno. Then atomic write preserving the existing mode. Outcome `after` is the LF-normalized new content; `operation` is `update` iff the file existed.
7. **Atomic write** (`writeFileAtomic`, `fsio.ts:604`). `mkdir -p` the parent; create the private staging dir (0700) and temp file (`wx`, 0600); write; `fsync` the file; `chmod` to the preserved mode; close; check abort; publish (`link` for `createIfAbsent`, `rename` otherwise); remove the staging dir (failure after commit is ignored). On failure remove staging and rethrow as `FsError` (`FS_PERMISSION_DENIED` for `EACCES`/`EPERM`, else `FS_IO_ERROR`). A failed `link` is classified by `lstat`-ing the target: existing non-file → `FS_NOT_REGULAR_FILE`; existing file or `EEXIST` → `FS_NOT_OBSERVED` (same overwrite message); else `FS_IO_ERROR`. Writing through a symlink updates its target (the target key is the realpath) and never replaces the link. Parent directory entries are not fsynced.
8. **editText** (`index.ts:250`). Inside the lock: missing → `FS_STALE_VERSION` (`cannot edit "<p>": file changed since it was read`) on both guarded and unguarded paths; non-file → `FS_NOT_REGULAR_FILE`; version mismatch → `FS_STALE_VERSION`. Then `applyLiteralEdit` (`fsio.ts:848`): normalize CRLF in `oldString` and `newString`; empty old → `FS_EDIT_NOT_FOUND` `old_string must be a non-empty string`; count non-overlapping occurrences left to right; 0 → `FS_EDIT_NOT_FOUND`; more than 1 without `replaceAll` → `FS_AMBIGUOUS_EDIT`; replace by split/join (all occurrences). The stale check runs before matching so a stale edit never reports a match failure.
9. **patchText / deleteFile / moveFile** (`index.ts:286-346`). All require an existing regular file at the expected version (`cannot <patch|delete|move> "<p>": file changed since it was read` / `not a regular file`). Patch mismatch → `FS_PATCH_MISMATCH` `cannot patch "<p>": hunk at patch line <n> (<context|oldLines>) does not match`. Delete captures a bounded `before` basis, checks abort, then removes non-recursively (`cannot delete "<p>": <detail>`, `FS_PERMISSION_DENIED` or `FS_IO_ERROR`). Move: identical keys → `FS_SAME_TARGET` `cannot move "<p>" to itself`; lock both keys; check source and destination guards; read source; apply hunks if any; restore the source's line endings; write the destination atomically with the **source's** mode; then remove the source. After the pre-write abort checkpoint both effects complete regardless of cancellation. A source-removal failure is returned as `sourceDeleted: false` with `sourceFailure`, not thrown.
10. **listDir** (`fsio.ts:304`). Missing → `FS_NOT_FOUND` `cannot list "<p>": not found`; non-directory → `FS_NOT_DIRECTORY`. Entries are sorted with JavaScript `localeCompare` on the name. Each child is resolved (realpath identity, display path under the parent's display path) and stat-ed following symlinks; a vanished/broken child is type `other` without version; `size` only for files.
11. **readBytes** (`fsio.ts:416`): stat size over the cap → `FS_TOO_LARGE` `cannot read "<p>": <size> bytes exceeds the <cap>-byte limit`; the stream reads at most one byte past the cap and fails `content exceeds the <cap>-byte limit` if the file grew.

### B. Filesystem sandbox fence (`fs-sandbox/src/index.ts:156`)

Per mutation: `policy = sandboxPolicy ?? ctx.sandboxPolicy.resolve()`. `danger-full-access` → delegate with the caller's target. `read-only` → `FS_SANDBOX_DENIED` `cannot write "<displayPath>": file access denied under read-only mode`. `workspace-write` → re-resolve `target.displayPath` now (fresh realpath), require the fresh key to be under one of `writableRoots(policy)` (`isPathUnder`: lexical prefix test, case-insensitive on Windows, then a device/inode walk up the target's ancestors against the root), else `FS_SANDBOX_DENIED` `...: file access denied under workspace-write mode`; delegate with the **fresh** target. Move checks source and destination. Reads are never fenced.

### C. Observation policy state machine (`fs-observation-policy/src/index.ts`)

State: `WeakMap<session object, Map<targetKey, FsObservation>>`. Owner = `actor?.agent?.session`; no owner means nothing is recorded.

| Prior state | `fs/write-intent` | `fs/edit-intent` / `fs/delete-intent` |
|---|---|---|
| unseen (or no owner) | `{ kind: 'createIfAbsent' }` | throw `FS_NOT_OBSERVED` `<edit|delete> requires reading "<displayPath>" first` |
| `absent` | `{ kind: 'createIfAbsent' }` | throw `FS_NOT_FOUND` `cannot <edit|delete> "<displayPath>": not found` |
| `present(v)` | `{ kind: 'replaceIfVersion', version: v }` | `{ version: v }` |

`fs/observed` overwrites the entry. Authorization is freshness-based: any windowed read authorizes a later mutation while the version is unchanged; there is no partial/full distinction. A successful write/edit records the new version, so consecutive edits need no re-read. Disposal replaces the WeakMap.

### D. File tools (`tool-fs`)

1. **Read window** (`read-render.ts:77-143`). Scan chunks splitting on `\n`; strip one trailing `\r` per line; keep at most `maxLineLength + 1` code units of the current line in memory; count every line (`totalLines` is exact even after caps). A line is selected when `totalLines >= offset`, fewer than `limit` lines are held, and the byte cap has not tripped. Selected text is truncated to `maxLineLength` with the suffix; its cost is its UTF-8 bytes plus 1 if it is not the first selected line; if adding it would exceed `maxBytes`, set `truncatedByBytes` and select nothing further. A final unterminated fragment counts as a line; a trailing newline adds none. After the scan, `offset > totalLines` throws unless the byte cap tripped or the file is empty with offset 1. The renderer re-derives `truncatedByBytes` as `lines.length < limit && lastLine < totalLines`.
2. **Read execution** (`read.ts:137`): parse args → resolve → one `stat` → absent: emit `absent`, throw; non-file: throw → stream or whole read → window → emit `present(stat.version)` → return.
3. **Per-call policy for mutating tools** (`sandbox.ts:89`). `standing = sandboxPolicy?.resolve({ session })` (undefined on a non-confining backend). If `sandbox_permissions` equals the standing mode, return standing with no approval and no justification requirement. Otherwise treat a blank `justification` without `sandbox_permissions` as omitted, then `validateEscalationArgs`. If either field is absent return standing. If no confining backend is mounted throw `ToolArgsError` `sandbox_permissions is not available in this composition (no sandboxing filesystem to escalate)`. Else `approveEscalation` and return `{ ...standing, mode: approved }` for this one call.
4. **Result diffs** (`diff.ts:36`). `structuredPatch('', '', before, after, { context: 3 })` from the npm `diff` package; per hunk collect old lines (context + `-`) and new lines (context + `+`), skipping `\ No newline` markers; emit `{ path, oldText: oldLines.join('\n') or null when there are no old lines, newText: newLines.join('\n') }`.
5. **apply_patch pipeline** (`patch/index.ts:23`).
   - *Plan* (`plan.ts:22`): `parsePatch`; resolve each operation path (and `moveTo`) against the session cwd, sharing one `FsTarget` object per target key; an update with `moveTo` becomes kind `move`. A resolution `FsError` becomes a refusal for that operation; a `PatchParseError` becomes the syntax report.
   - *Preflight* (`preflight.ts:22-157`): a read-only simulation over a map `targetKey → { exists, info, content?, touched }` seeded by one `stat` per target. For each operation in order: a move onto itself → `FS_SAME_TARGET`; for delete and move, `lstat` the raw source path and refuse a symlink with `PATCH_SYMLINK_SOURCE` (`cannot <delete|move> "<p>": path is a symbolic link — operate on its target path instead`). Intents are dispatched only on the **first** use of a target (an earlier operation in the same patch that touched it makes later ones unguarded in simulation). Source check: missing → `FS_NOT_FOUND` `cannot <kind> "<p>": not found`; non-file → `FS_NOT_REGULAR_FILE` `cannot modify "<p>": not a regular file`; intent version differs from the stat version → `FS_STALE_VERSION`. Destination check: `createIfAbsent` with an existing file → `FS_NOT_OBSERVED`; `replaceIfVersion` with absence or version mismatch → `FS_STALE_VERSION`. Content is read with `readText`, rejected if it contains any NUL (`cannot patch "<p>": binary file`), CRLF-normalized, and hunks are applied with `applyHunks`; a mismatch yields `FS_PATCH_MISMATCH` with message `cannot patch "<p>": hunk at patch line <n> (<stage>) does not match — <first pattern line, at most 80 code points then "…">` and `hunkLine`. Each admitted operation publishes its simulated result so later operations see it. Every refusal is collected (not just the first); any refusal blocks the commit. Preflight emits no observations. Sandbox containment is not simulated.
   - *Commit* (`execute.ts:40`): operations start as `skipped`. For each in order: stop with `cancelled = true` if the signal is aborted; stat the mutation targets (for the uncertainty check); dispatch the intent(s) fresh; call the provider (`writeText` for add, `patchText` for update, `deleteFile`, `moveFile`); emit observations (`present` for written targets, `absent` for removed sources); record `changes` with process paths. A move whose source was not removed is `failed` but keeps its destination change. On `FsError`: if the provider call had started and the code is `FS_ABORTED`, or it is `FS_IO_ERROR` and any target's version changed, the outcome is `unknown` with ` — re-read the affected files before retrying` appended; otherwise `failed` with no changes. The first non-completed outcome stops the loop; later operations stay `skipped`. No rollback. `affectedPaths` = distinct change paths.
   - *Projection* (`apply-patch-output.ts:66`): see Tools for which reports throw.

### E. Patch parser and applier (`fs-patch`)

Parser (`parse.ts`): trim outer Unicode White_Space (not BOM); split on `\r?\n`; line numbers count leading blank lines; if the first line is `<<EOF`, `<<'EOF'` or `<<"EOF"`, the last line ends with `EOF`, and there are at least 4 lines, drop both wrapper lines. First line trimmed must be `*** Begin Patch` (`Expected '*** Begin Patch'`), last must be `*** End Patch`. Strip a trailing `\r` from every line but the last. For each following line: inside an update the header candidate is right-trimmed only (so indented markers stay context), elsewhere fully trimmed. `*** End Patch` ends the patch (content after it other than whitespace → `Unexpected content after '*** End Patch'`); Add/Delete/Update headers push operations (the path is everything after the marker, unresolved); an `*** Environment ID:` header before the first operation → `Environment ID headers are unsupported; the caller selects the filesystem provider`; in an add, a line starting with `+` appends `line[1:] + "\n"` to `content`; in an update `readUpdate` (`:89`) handles `*** Move to: ` (only before the first hunk), `@@` / `@@ <context>` (new hunk; an empty previous hunk → `Update hunk must contain context, added, or removed lines`), `*** End of File` (marks the previous hunk; after it only blank lines or a new `@@` are allowed, else `Expected '@@' after '*** End of File'`), and body lines whose first character is space, `+`, `-`, or which are empty (empty = empty context line); any other first character → `Expected a context (' '), added ('+'), removed ('-') line, or '@@'`. A first body line without `@@` opens an implicit hunk. Anything else → `Expected an Add File, Delete File, or Update File header; added content must start with +`. Before each new header and at the end, an update must have at least one hunk (`Update for '<path>' requires at least one hunk`) and its last hunk must be non-empty. An empty patch yields `[]`.

Applier (`apply.ts:65`): split `before` on `\n`, drop one trailing empty element. Keep a cursor `lineIndex = 0`. For each hunk: if it has `context`, `seekSequence([context], cursor, eof=false)`; miss → failure stage `context`; hit → cursor = hit + 1. If `oldLines` is empty, insert `newLines` at the end of the original (before a final empty line if one remains) and do not move the cursor. Otherwise `seekSequence(oldLines, cursor, isEndOfFile)`; on a miss where the pattern ends with an empty line, retry without that line (and drop a trailing empty new line); miss → failure stage `oldLines` reporting the original pattern. Record `{ start, oldLength, newLines }`, cursor = hit + pattern length. All searches run against the original lines. `seekSequence` (`:37`): empty pattern matches at the cursor; with `eof` only the single tail position `lines.length - pattern.length` is tried (even before the cursor); otherwise positions from the cursor upward. Four passes, each over all candidates before the next: exact; right-trimmed White_Space; fully trimmed; fully trimmed plus punctuation folding (U+2010–2015 and U+2212 → `-`; U+2018–201B → `'`; U+201C–201F → `"`; U+00A0, U+2002–200A, U+202F, U+205F, U+3000 → space). Apply replacements sorted by start (stable) from last to first; ensure a terminal empty element; join with `\n`. Non-empty output always ends with LF; zero hunks still normalizes the trailing newline.

### F. Search tools (`tool-fs-search`)

1. **Run** (`search-core.ts:194`): abort check; workdir = session cwd or `process.cwd()`; spawn `rg` with `stdin: 'ignore'`, `stdout: { maxBytes: rawOutputMaxBytes }`, `stderr: { maxBytes: stderrMaxBytes }` (no spill files), `graceMs`, `signal: exec.signal`. Exit 0 = results, exit 1 = zero results, signal or other exit = error. A lossy stdout read or more bytes than the cap → `SEARCH_RAW_OUTPUT_OVERFLOW`. Abort is re-checked after spawn and after settlement.
2. **Glob pruning** (`glob.ts:93`): when no `path` is given and every directory segment of the pattern (all but the last `/`-separated part) matches `^[\w .-]+$`, is not `.`/`..`, and is not a VCS name, prepend `--glob=!**` and `--glob={<unique dirs joined by ,>}/` (skipped if that would add more than 8 KiB).
3. **Glob paging**: at most `globMaxResults` inline. Head mode takes the first N. Sampling mode (`sampleAcrossTopLevel`, `glob.ts:185`): group paths by their first segment relative to the search root, in first-seen order; round-robin one path per group per round until N are taken; output grouped by top-level entry.
4. **Grep parse** (`grep.ts:136`): each non-empty stdout line must be JSON; non-`match` types are skipped; a malformed `match` fails the whole search; line text loses one trailing `\r?\n`.
5. **Retention**: `ItemRetainer` head N over matches whose lines were previewed with `TextRetainer` head `grepMaxLineBytes`.
6. **Spill handoff** (`glob.ts:372`, `grep.ts:346`, `direct-call.ts:19`): only when `decision.kind === 'accept'`, no `content`/`value` override, `exec.parent === undefined`, `exec.name === tool.name`, not an error, and `ctx.tools.get(exec.name, exec.agent) === tool`. Save failure (no session, no backend, rejection) logs a warning and keeps the inline page with the could-not-save footer.
7. **Meta cap** (`presentation.ts:107`): drop trailing file groups / paths until `JSON.stringify(meta)` fits `searchMetaMaxBytes`, always keeping at least one item, marking `truncated: true`; `total` is unchanged.

### G. Sandbox seam

1. **Writable roots** (`sandbox/src/roots.ts`). `workspaceWritableRoots(policy)`: empty unless `workspace-write`; else dedup `[canonicalPath(workspaceRoot), ...additionalRoots]`, where each additional root must exist, be a directory, and equal its own realpath (else `SandboxInvalidRootError`: `Invalid additional writable directory "<p>": ...`). `writableRoots(policy)` adds `canonicalPath('/tmp')` and `canonicalPath(os.tmpdir())`. `canonicalPath` is native realpath, falling back to the spelling when resolution fails. Seatbelt and the fs fence use `writableRoots`; bwrap grants a fresh tmpfs on `/tmp` plus workspace roots; Landlock grants `/tmp` plus workspace roots (the per-user temp dir is not granted by those two unless it is under `/tmp`).
2. **Runner selection** (`sandbox-local/src/index.ts:546-594`). Chains by platform: linux `[bwrap, landlock]`, darwin `[seatbelt]`, win32 `[windows-acl]`, anything else none. A sole candidate is selected without a probe (bwrap/seatbelt/landlock claim `full`, windows-acl `partial`). With several candidates, probe in order and take the first usable: bwrap probe = `bwrap <read-only profile for />  -- true` exits 0 within `probeTimeoutMs`; landlock probe = `landlock-run --probe` → `full`/`partial`/`unusable`. The verdict is cached for the provider lifetime. No usable runner → `SandboxUnavailableError` at `confine` time. `confine` canonicalizes `workspaceRoot` first.
3. **Escalation** (`sandbox/src/escalation.ts`). `validateEscalationArgs`: `sandbox_permissions` without `justification` → `invalid escalation: sandbox_permissions requires a justification`; `justification` alone → `invalid escalation: justification is only valid together with sandbox_permissions`; blank justification → `invalid justification: expected a non-empty sentence` (all `SANDBOX_ESCALATION_INVALID_ARGUMENT`). `approveEscalation` (`:209`): requested == effective → return it. Requested must be in `WIDER_MODES[effective]` (`read-only → [workspace-write, danger-full-access]`, `workspace-write → [danger-full-access]`), else `sandbox escalation to "<m>" is not strictly wider than this call's current "<e>" mode`. No approval service → `SANDBOX_ESCALATION_UNAVAILABLE` (`...requires approval, but no approval service is composed`); no agent → same code (`...but the call has no agent to route it through`). Then `approver.request({ agent, toolName, callId, reason, displayReason, signal })`: `allowed-once` → the mode, for this call only; `rejected` → `SANDBOX_ESCALATION_REJECTED` `the user rejected escalating this <subject> to "<m>"; it stays denied, so stop and explain instead of working around it`; `cancelled` → rethrow the call's abort reason if its signal is aborted, else `SANDBOX_ESCALATION_CANCELLED` `approval for escalating to "<m>" was cancelled`; `unavailable` → `SANDBOX_ESCALATION_UNAVAILABLE` `...but no approval channel is available`. Nothing executes before the grant.
4. **Classification** (`sandbox/src/diagnostics.ts`). `classifyRunnerFailure(exitCode, stderr, rules)`: only for a nonzero numeric exit; per rule, apply the exit-code gate, drop stderr lines equal (case-insensitive) to an informational line, then return the first line containing a fatal signature (case-insensitive). `matchesSignature(exitCode, stderr, signatures)`: nonzero exit and any signature substring (case-insensitive) anywhere in stderr. `isRunnerSpawnFailure(error, runnerProgram, workdir)`: the workdir must be an enterable directory; error code `ENOENT` or `EACCES`; and either `error.path === runnerProgram` with `syscall` `spawn` or `spawn <runner>`, or no `path` with `syscall === 'spawn <runner>'`.
5. **Policy precedence** (`sandbox-policy/src/index.ts:208`): approved per-call mode > session's last `sandbox/mode` event > deployment default. Workspace root is the session's immutable header cwd.
6. **PTY mode fence** (`terminal-bash/src/index.ts:37`): while an owner has an open or pending PTY session, appending a `sandbox/mode` event that changes the effective mode throws `cannot change sandbox mode from "<a>" to "<b>" while persistent terminal sessions are open or being created; wait for creation to settle and close them first`.

### H. Subprocess provider (`subprocess-local`)

1. **Validation** (`spawn.ts:164`): `graceMs` must be positive finite and ≤ 2147483647 (`subprocess graceMs must be a positive finite number no greater than 2147483647`); a pre-aborted signal throws an `Error` named `AbortError` with message `aborted before spawn: <reason>`; empty `argv[0]` → `SUBPROCESS_INVALID_ARGV` `invalid argv: expected a non-empty program name at argv[0]`. argv, cwd, and env entries must not contain NUL.
2. **Containment selection** (`index.ts:250`): Linux with a usable user systemd manager → transient scope per spawn; Windows ordinary spawns → kill-on-close Job through a private runner; otherwise the fallback (POSIX: detached child = new process group; Windows: `taskkill /T /F`), logging one warning per provider lifetime. A selected native path is never replayed through the fallback after it may have started the command.
3. **Common lifecycle** (`bindManagedProcess`, `spawn.ts:275`):
   - `{ data }` stdin is written and closed immediately; write errors are ignored.
   - Collect-mode streams feed an `OutputCollector`; pipe-mode streams go to the caller raw.
   - `terminate()` (or the abort signal): once only — signal `SIGTERM` to the managed range, start a `graceMs` timer, then `SIGKILL`. The grace timer is **not** cancelled when the direct child exits, so survivors in the range are still killed; it is cancelled when the range is observed empty.
   - `done`: when the direct child exits, wait for collected/piped stdout and stderr to close, but at most `graceMs` (an inherited pipe held by a survivor cannot hold the outcome open); then destroy and seal the collectors and resolve `{ exitCode, signal }`. A spawn error rejects `done` with the original error.
   - `waitForExit(signal?)`: shared observation of the managed range; resolves `true` when empty.
   - Fallback owner (`spawn.ts:205`): liveness = `kill(-pgid, 0)` (plus, on Linux after the direct child settled, a `/proc` scan for a live group member); polled every 15 ms with a ref'd timer.
4. **Output collector** (`output.ts:128-312`): in-memory tail of at most `maxBytes` bytes (byte-exact; head chunks dropped or trimmed); `total` counts all bytes; with spill options, the first overflow opens the spill file, writes all retained chunks, then appends every later chunk; if `total` exceeds the spill cap the spill file is closed, unlinked, and spilling is disabled; any spill I/O failure discards the spill, reports once, and never interrupts collection. `readFrom(fromByte)`: `windowStart = total - retained`; `lossy = fromByte < windowStart`; returns the whole tail when lossy, else the slice from `fromByte`; `nextOffset = total`; `spillPath` when a spill file exists. Text is decoded as UTF-8 per read (a cut can split a code point).
5. **Disposal** (`index.ts:135`): terminate every live handle and await both `done` and `waitForExit`; terminate terminals; destroy control channels; on any failure run the synchronous host-exit kill and rethrow (aggregate when several).
6. **resolveExecutable** (`index.ts:168`): empty → `subprocess-local: executable must be non-empty`; relative with a separator → `subprocess-local: command "<c>" is a relative path; use an absolute path or a bare PATH name`; candidates = the absolute path, or each PATH entry (relative entries resolve from the host cwd) × `PATHEXT` on Windows; first regular file with execute permission wins; miss → `subprocess-local: command "<c>" is not an executable file` / `...was not found on PATH`.
7. **Terminals** (`index.ts:303`, `terminal.ts`): node-pty with `name = terminalType`, env `{ ...scrubbed+explicit, TERM: terminalType }`; output is a `PassThrough` with backpressure (pause the PTY while the consumer is slow). `inspectForeground`: Linux reads `tpgid` from `/proc/<pid>/stat` and decides `inputWaiting` by checking whether a foreground-group thread is blocked in a read-like syscall on the controlling terminal (`/proc/<pid>/task/<tid>/syscall`); macOS uses `/bin/ps -o tpgid= -p <pid>` and always reports `inputWaiting: false`. `signalForeground`: resolves the foreground group, refuses `SIGKILL` when that group is the shell itself (`refusing to SIGKILL the terminal shell; terminate the terminal session instead`), then signals the group. `terminate()`: with a native range, TERM the range, wait up to `graceMs`, KILL, wait; without one, TERM tracked descendants (process-tree and session members identified by pid+start time), wait, KILL survivors, then TERM/KILL the shell, then sweep descendants again; any survivor rejects with `terminal cleanup failed; surviving pid(s): ...`. Exit code mapping: a nonzero PTY exit signal number becomes `signal` with `exitCode: null`.

### I. Shell executors and the bash tool

1. **resolve** (`bash-local/src/index.ts:120`): `timeoutMs = min(request.timeoutMs ?? config.timeoutMs, config.maxTimeoutMs)` (a supplied non-positive or non-finite value throws `bash-local: request.timeoutMs must be a positive finite number`); `stdoutMaxBytes = request ?? maxOutputBytes`; `workdir = request ?? config.cwd ?? process.cwd()`; `onExpiry = request ?? 'kill'`; `stdin`, `env`, `dshEnv`, `signal`, `sandboxPolicy` pass through. The sandbox executor's `resolve` additionally defaults `sandboxPolicy` to `ctx.sandboxPolicy.resolve()`.
2. **execute** (`executeArgv`, `:201`): argv `['bash', '-c', command]`. With `onExpiry: 'kill'` build one fused deadline `deadline(spec.signal, timeoutMs, 'BASH_TIMEOUT')` (`AbortSignal.any` semantics: the first abort's reason wins); `timedOut` iff the fused signal's reason is this executor's `TimeoutReason`; `aborted` iff aborted and not timed out. With `'none'` no timer exists; `aborted` iff `spec.signal` aborted. Spawn with stdout collect `{ maxBytes: stdoutMaxBytes, spill: { maxBytes: maxSpillBytes } }`, stderr collect `{ maxBytes: maxOutputBytes, spill: ... }`, `graceMs`, the fused signal, and env `{ ...ENV_OVERRIDES, ...env, ...dshEnv }`.
   - Status at settlement: `killed` if the spawn signal is aborted or the process died from a signal, else `completed`.
   - A synchronous spawn throw or a rejected `done` (not following this execution's own termination) settles the handle as `killed`, exposes the note `subprocess failed before reporting an outcome: <detail>` as the whole stderr stream for every reader, and makes `result()` reject with the original error.
   - A preparation step (argv produced asynchronously, used by the sandbox executor) races the deadline; a timeout during preparation yields an already-settled handle with `exitCode: null`, `signal: null`, `timedOut: true`, empty output; any other preparation failure throws from `execute`.
   - `readOutput()` (consuming): `delta = stdoutDelta + (stderrDelta non-empty ? [newline if stdout delta lacks one] + "[stderr]\n" + stderrDelta : "")`; `lossy` if either stream lost data; spill paths when present.
   - `result()`: `{ exitCode, signal, timedOut, aborted, timeoutMs: spec.timeoutMs, stdout, stderr }` where each stream is `readFrom(0)` → `{ text, truncated: lossy, spillPath? }` (the tail when truncated).
3. **Sandboxed execute** (`bash-sandbox/src/index.ts:89`): `danger-full-access` → local execute, result stamped `sandbox: { mode, denied: false }`. Otherwise preparation calls `ctx.sandbox.confine(['bash','-c',command], policy, signal)` and spawns the returned argv. Result decoration: if `classifyRunnerFailure(exitCode, stderr.text, rules)` matches, **throw** `SandboxUnavailableError(mode, <matched line>)`; else `sandbox: { mode, denied: matchesSignature(exitCode, stderr.text, denialSignatures), enforcement }`. A `result()` rejection: rethrow the caller's abort if aborted; if the spawn error names the runner executable (`isRunnerSpawnFailure`) throw `SandboxUnavailableError`; else rethrow. For background handles `onProcessDone` stamps `proc.sandbox = { mode, denied, enforcement, runnerFailed? }` before `done` resolves (runner failure outranks denial). Facts are kept per process, not per executor.
4. **Tool flow** (`tool-bash/src/index.ts:502`):
   1. `standing = sandboxPolicy?.resolve({ session })`; validate args; if `sandbox_permissions` and `justification` are both present run `approveEscalation` (throwing `SANDBOX_ESCALATION_UNAVAILABLE` `sandbox_permissions is not available in this composition (no sandboxing executor to escalate)` when the executor does not confine); `policy = standing` with the approved mode substituted.
   2. `cwd = workingDirectory.ensure(agent)`; `workdir = args.workdir` absolute as is, relative joined as `<cwd><sep><workdir>`, absent → `cwd`.
   3. `dshEnv = ctx.shellEnv.collect(exec)`; request = `{ command, workdir?, timeoutMs?, dshEnv, sandboxPolicy? }`.
   4. `run_in_background: true`: reject if disabled or no registry; if already aborted throw the abort; `spec = shell.resolve({ ...request, onExpiry: 'none' })`; register a job `{ kind: 'bash', label: command, toolCall: { callId, rootCallId }, owner: agent.id, output: [stdout source, stderr source], run }` and return `{ kind: 'background', jobId, cwd: spec.workdir }`. The process is spawned inside the job's `run` (after admission) with the job's own abort signal.
   5. Foreground with a registry and `promoteOnTimeout`: resolve with `onExpiry: 'none'`, register the same job, then `registry.wait(id, timeoutMs, owner, exec.signal)`. Outcomes: wait rejected (caller abort) → kill the job with reason `tool call aborted`, wait for settlement, remove the record, throw the abort; still running but no process published yet → kill with `timed out during preparation`, return a synthetic foreground value (`exitCode: null`, `timedOut: true`, empty output, `sandbox: { mode, denied: false }` when a policy exists); still running → one consuming `registry.read` seeds `output` (rendered with `ringDelta` + `renderJobRead`) and the value is `promoted`; settled → remove the job record and return the process's `result()` as `foreground`, adding `stopped: <reason>` when an outside kill ended it. If registration is refused (admission), log a warning and fall through to 6.
   6. Plain foreground: `spec = shell.resolve({ ...request, signal: exec.signal })`; `result = (await shell.execute(spec)).result()`; `aborted` → throw the abort; else `foreground`.
   - Job outcome mapping (`background.ts:54`): `killed` → `{ status: 'killed', detail: 'signal: <SIG>' | 'killed before exit' }`; else `{ status: 'completed', detail: 'exit code: <n>' }`; sandbox notes are appended to `detail` after `; `. A preparation failure is `failed` (or `killed` if the job was cancelled first).
5. **Exit-marker parser** (`shell/src/render.ts:37`): `/\n\[killed by signal: ([^\]\n]+)\]$/` → `{ body, signal }`; else `/\n\[exit code: (\d+)\]$/` → `{ body, exitCode }`; else `{ body: text, exitCode: 0 }`.

### J. Terminal registry and backend

1. **Registry spawn** (`terminal/src/index.ts:135`): refuse while disposing; owner must be the live registered agent (`ctx.agents.get(owner.id) === owner`) else `OWNER_NOT_LIVE`; install one owner-cleanup effect on `owner.ctx`; unknown backend → `NO_BACKEND`; reserve the optional name (unique per owner among published and in-flight spawns, else `DUPLICATE_NAME`); reserve a pending-spawn record with its own abort controller; mint the id; call `backend.spawn`; after it returns re-check caller abort, service disposing, and owner liveness before publishing; on any failure close the unpublished session (`PTY spawn rolled back`) and prefer the cancellation reason as the thrown error.
2. **Send exclusivity**: `startSend` on a closing session → `SESSION_CLOSING`; with an active send → `SEND_ACTIVE`; the record's `active` clears when the operation's `done` settles.
3. **Backend spawn** (`terminal-bash/src/index.ts:201`): install the mode fence; `policy = sandboxPolicy.resolve({ session: owner.session })`; argv = `[shellPath, ...shellArgs]`, wrapped by `ctx.sandbox.confine` unless `danger-full-access` (no provider → `NO_SANDBOX`); `spawnTerminal({ argv, cwd: spec.cwd ?? session cwd, env, rows, cols, terminalType: 'dumb', graceMs: disposeGraceMs, signal })`; then startup: bash = one empty non-submitting send that must settle by readiness (exit → `STARTUP_EXITED`, timeout → `STARTUP_TIMEOUT`), its viewport becomes `motd`; pwsh = send `ENCODING_PREAMBLE + PWSH_PROMPT_SETUP` and keep sending empty follow-ups until a `stdin_read` settlement, bounded by one absolute `timeoutMs`. Startup failure cleans up first; a cleanup failure throws `TerminalBackendCleanupError`.
4. **Send lifecycle** (`session.ts:328-432`): refuse when closing/exited/active; a pre-aborted signal throws `AbortError` `PTY send aborted before write`; arm an absolute `timeoutMs` deadline (settles `timeout`); inspect the foreground group before writing; write `text + (submit ? '\r' : '')`; reset readiness evidence; poll every `pollIntervalMs`.
5. **Readiness poll** (`session.ts:554`), in order:
   - session exited → `session_exit`;
   - prompt path: a prompt marker was seen since the write, the printable text after the latest marker is exactly `dsh> `, output has been silent for `>= pollIntervalMs`, and the foreground group equals the shell's group (learned the first time a prompt is seen) → `stdin_read`;
   - exact path: `elapsed >= exactProbeAfterMs` and the foreground group is waiting on terminal input; if that group is the same one that was already waiting before the write, it must first have been observed not waiting → `stdin_read`; during initialization this also requires some output;
   - silence path: no output for `idleSilenceMs` (+ `handoffGraceMs` if a marker was seen, + `promptTailGraceMs` if the marker's tail is still a strict prefix of `dsh> `) → `inferred_idle`.
   The result is `{ viewport, waitReason, sessionStatus, truncated }` where `viewport` is the operation's bounded output buffer (tail of `maxReadBytes` bytes).
6. **Cancel**: `operation.cancel()` or the request signal sends `SIGINT` to the foreground group once any in-flight write finished, then resumes polling immediately; it does not settle the operation by itself.
7. **Output handling**: bytes → streaming UTF-8 decode → (a) a headless xterm emulator used only to answer terminal queries (its replies are written back to the PTY, and a send waits for pending replies before sampling the foreground), (b) the sanitizer. Sanitizer (`sanitize.ts`): removes OSC (`ESC ]` … BEL or `ESC \`), CSI (`ESC [` … final byte 0x40–0x7E), and two-byte escapes, carrying incomplete sequences across chunks (bounded by `maxReadBytes`, after which the rest of that sequence is discarded); an OSC whose content starts with `133;D;` sets the prompt flag and starts tracking the printable tail; text is normalized `\r\n` → `\n`, lone `\r` → `\n` (a chunk-final `\r` is held to pair with a following `\n`), BEL removed. Sanitized text is appended to the session scrollback (bounded by `scrollbackMaxBytes` bytes and `scrollbackLines` newlines, evicting from the head one code point at a time) and to the active operation's buffer.
8. **Scrollback read** (`session.ts:434`): `lines = text.split('\n')`; `totalLines = 0` for empty text; `offset` (default 0) counts from the newest line; `count` default 500; page = `lines[max(0, total-offset-count) .. total-offset)`; the page is cut to the last `maxReadBytes` bytes; `lineBegin = offset`, `lineEnd = offset + returned line count`; `truncated` if scrollback ever evicted or the page was cut. Errors: `PTY read offset must be a non-negative safe integer`, `PTY read count must be a positive safe integer`.
9. **Close**: stop polling, dispose the emulator, `terminal.terminate()` (failure → `PTY cleanup failed (<reason>)`), settle the active send as `session_exit`, await exit.

### K. Persistent bash tool (`tool-bash-persistent/src/index.ts`)

- One shell per owner agent, created lazily: `terminals.spawn(owner, { type: backendType, cwd: session cwd })`, then the setup send `stty -echo; set +H` (an exit or timeout → `TerminalError` `INIT_REJECTED` `persistent bash shell did not accept initialization`, after resetting). Creation is shared through a per-owner pending promise. Plugin disposal aborts in-flight creations and kills every live shell; owner disposal clears the caches.
- Calls for one owner are serialized through a per-owner promise queue.
- Command loop (`executeCommand`, `:301`): one deadline `deadline(exec.signal, timeoutMs, 'PERSISTENT_BASH_TIMEOUT')`; send the wrapped line with `submit: true`, then repeated empty non-submitting sends. After each send settles: accumulate the operation's incremental output as a fallback; read the newest scrollback page (1000 lines); if the deadline timed out → render partial output, reset the shell, return the timeout text; if aborted → reset, return `''` (the tool runtime reports the abort); if the newest page contains the end marker → assemble the full scrollback (paging by 1000 lines) and extract the text between the last start marker and the end marker, exit status = the digits after the end marker; if the session exited → partial output + shell-exit marker + reset; if the wait reason was `stdin_read` without an end marker (for example `exec`, an interactive child) → return the partial output without a status marker; otherwise sleep 25 ms and loop.
- Extraction: output = text after the start marker's line up to the end marker, with trailing newlines trimmed; if the start marker scrolled out, take from the beginning of retained text and mark `incomplete` (adds the lost-prefix note and forces the clipped note).
- A send failure resets the shell and rethrows.

### L. Spill policy (`spill-policy/src/index.ts`)

For an accepted result (content = `decision.content ?? result.content`): skip `read`, decisions with `value`, and nested text-only calls. Only content made solely of text and image blocks is eligible. Price each block: text by `estimateContent([block])`; images by the route's `imageRequestPricing(provider, model).priceImages(images)` (`visualTokens + estimate of the descriptor text`); a missing calculator keeps the content. If the total is `<= maxInlineTokens` keep it. Otherwise: require a session owner and a spill backend; save the full text (text blocks verbatim; each image replaced by the `[Image: ...]` line using a host path mapped through `fs.processPathFromHostPath`) with `suggestedName = '<toolName>.txt'`, `source = { kind: 'tool', toolName, callId, label: 'result' | 'dispatch' }`. Reserve the price of the gap marker and of the worst-case notice (all text bytes, all images omitted); if the notice alone exceeds the cap keep the content. `retainContent(content, max(0, cap - reserved), price)` (`retention.ts:48`): the head takes `ceil(budget/2)`, the tail `floor(budget/2)`; whole blocks while they fit; a text block that does not fit is cut by binary search on UTF-16 length to the longest fitting prefix (head) or suffix (tail) without splitting a surrogate pair; an image that does not fit ends that side (never moved or split); when head and tail meet in the same text block the tail works on the remainder. Result = `head + GAP + tail + "\n\n" + notice(omittedBytes, omittedImages)`, or the notice alone when nothing was retained; adjacent text blocks are merged. Any failure logs `spill-policy: <error>; keeping the inline content` and leaves the content unchanged. For a nested (PTC) call whose images were all dropped, the retained text is also added as an `additionalContexts` user message with `source: { kind: 'ptc-mode' }`.

### M. Spill-local

`saveText`: path as in Formats; create the session dir (0700) then open `wx` 0600, retrying if the directory vanished between the two; write; return `{ locator: path, bytes: UTF-8 length, retrievalHint }`. Startup sweep (`cleanup.ts`, once per activation, awaited at disposal, never rejects): roots = every `dsh-spill-XXXXXX` directory under the OS temp dir (pruned when emptied) plus the active root (never pruned); for each trusted root (owned by the current user, not group/world-writable, protected ancestors) and each `session-<12 hex>` directory in it, delete regular files whose mtime is strictly older than `now - cleanupPeriodDays`, skip symlinks and unrelated entries, and remove emptied session directories.

### N. Attachments (`attachment-local`)

1. **Batch admission** (`attachment/src/index.ts:93`, `attachment-local/src/index.ts:211`): count `> maxImagesPerMessage` → `TOO_MANY_IMAGES`; total bytes `> maxMessageImageBytes` → `IMAGES_TOO_LARGE`; media type not accepted → `UNSUPPORTED_IMAGE_TYPE`. Then prepare every member (through a FIFO concurrency limiter) before committing any.
2. **Prepare** (`store.ts:99`): bytes `> maxImageBytes` → `IMAGE_TOO_LARGE`; empty → `INVALID_IMAGE` `Image is empty.`; decode metadata with sharp (EXIF orientations 5–8 swap width/height); format not png/jpeg/webp/gif or decode failure → `INVALID_IMAGE` `Unsupported or malformed image data.`; pixels `> maxImagePixels` → `IMAGE_TOO_MANY_PIXELS`; a side `> maxImageDimension` → `IMAGE_DIMENSION_TOO_LARGE`; full raster decode; detected type ≠ declared → `IMAGE_TYPE_MISMATCH` `Declared image type does not match its bytes.`
3. **Normalize** (`normalization.ts:109`): pass the bytes through unchanged iff not GIF, single frame, no metadata/profile/orientation, 8-bit (`uchar`), sRGB, bytes `<= maxBytes`, pixels `<= maxPixels`, long edge `<= maxDimension`. Otherwise: target size = `requestImageDimensions(w, h, maxPixels)` (scale `sqrt(maxPixels/(w*h))`, floor the long edge, round the short edge, shrink until the product fits) then scale again if the long edge exceeds `maxDimension`; pipeline = auto-rotate, convert to sRGB, resize `fit: inside` without enlargement; encode with the quality ladder `[85, 75, 60]` as WebP (effort 0) when the source has alpha, else JPEG; take the first output within `maxBytes`, else the smallest. Verify the output (type, size, single frame, no metadata, 8-bit sRGB, compatible alpha) or fail `ATTACHMENT_WRITE_FAILED`. GIF input is never passed through: it is always re-encoded to WebP or JPEG, and the sharp pipeline is opened without its animation option, so only the first frame survives (the stored `mediaType` is therefore never `image/gif`; the `read-image-gif` snapshot pins the result).
4. **Reference**: `attachmentId = sha256 of the normalized bytes`; `name` = caller name stripped to its leaf (both separators), control characters removed, trimmed, at most 255 UTF-16 units, omitted if empty; `originalDimensions` only when normalization changed the dimensions.
5. **Publish** (`store.ts:214-388`): ensure `DSH_HOME` and its ancestors are durable once per process (mkdir 0700 + fsync each parent directory); stage to `tmp/<uuid>` with `O_EXCL`, write, fsync, close; verify digest; `link(staged, target)`; on `EEXIST` verify the existing object's digest (mismatch → `ATTACHMENT_CORRUPT`); unlink the staging name; `chmod 0400`; fsync each directory from the target's parent up to the root. Other failures → `ATTACHMENT_WRITE_FAILED` `Unable to persist attachment.`
6. **Read** (`store.ts:431`): invalid id → `INVALID_ATTACHMENT_REF`; missing → `ATTACHMENT_NOT_FOUND`; other I/O → `ATTACHMENT_READ_FAILED`; digest mismatch → `ATTACHMENT_CORRUPT`; header probe (no raster decode) must match the ref's media type, byte length, width, height, else `ATTACHMENT_CORRUPT`.
7. **Files** (`file-store.ts`): no limits and no normalization. Leaf name = strip to leaf, remove control characters, replace `<>:"|?*` with `_`, trim, strip trailing dots/spaces, prefix `_` to Windows device names (`con`, `prn`, `aux`, `nul`, `com1-9`, `lpt1-9`), cut to 255 UTF-8 bytes, fallback `file`. A ref whose `name` is not already in this form is invalid. Reads stream in 64 KiB chunks and verify byte count and digest after the final chunk.
8. **Request images** (`request-image.ts:196`, `index.ts:260`): identity = `requestImageVariantId`; concurrent requests for one variant share one computation (cancelled only when every waiter cancelled); cache hit must be 8-bit sRGB, within the target size, with compatible alpha; otherwise if the target is at least the source size and the source fits `maxBytes` return the stored bytes unchanged; else resize by the source's long edge (width when `w >= h`, else height) without enlargement, sRGB, same quality ladder; verify; write to the cache via temp + rename.
9. **Base64 admission** (`attachment/src/admission.ts:16`): the payload must round-trip exactly through base64 decode/encode; an empty image payload is rejected (`INVALID_IMAGE_BASE64`), an empty file payload is accepted.

### O. Deliverables

1. **present** (`tool-present/src/index.ts:78`): needs an agent and an open turn (`ctx.agents.turnBoundaryOf(session)`); for each file: `lstat` (a present non-file, including a symlink, is refused) → `resolve` → `stat`; the stored path is the process path. The pending delivery is keyed by the execution object and appended on `tools/result` only if the result is not an error.
2. **workspace-changes** (`recorder.ts`): eligible sessions have a cwd and are not subagent sessions (`origin !== 'subagent'` and `delegationDepth` 0). Per session a serialized task queue. `turn/start` → locate the repository once (`rev-parse`; not a repository → no snapshots) and snapshot the work tree as a git tree through a private index copy and a private object directory with the repository's objects as an alternate (the repository's index, objects, and refs are untouched). Each `fs/*-intent` for a tool call of that session captures the target file's current bytes once per turn (content-addressed copy by SHA-1; `absent`; or `oversized` above `maxFileBytes`), and `tools/pre-execute` waits for the queue. On `agent/turn-stopping` (and on `turn/end` if a later tool result arrived) → if at least one tool result happened this turn: snapshot again, `diff-tree --numstat -M` between the trees, and add captured paths the snapshots do not cover (ignored files inside the repository; files outside it unless under a temp root; everything when there is no repository; never paths inside gitlinks) whose content changed, with counts from a line diff. Sort by `display`; if non-empty (or a previous record exists for the turn) append `workspace/changes { turn }` and store the summary (capped at `maxFiles`, totals uncapped) keyed by the event's `seq`. `diff(seq, index)` reads both sides (git blob via `ls-tree` + `cat-file`, or the capture file) and returns unified hunks with 3 context lines; a comparison that exceeds `diffTimeoutMs` degrades to one whole-file replacement hunk (`coarse: true`). Any failure only logs a warning.
3. On macOS `/usr/bin/git` counts as absent unless `xcode-select -p` exits 0.

### P. Utilities

- `ItemRetainer` (head N; exact omitted count) and `TextRetainer` (`output-retention/src/index.ts:247`): byte budgets for head / tail / head+tail; when bytes were omitted, the prefix is trimmed back to a complete UTF-8 sequence and the suffix forward past continuation bytes; the reported omitted count is computed from the bytes actually returned. `describeOmitted`: `Omitted <n> <unit>.` / `More <unit> were omitted.` / empty. `truncateWithoutSplittingSurrogatePair(text, maxChars)`: cut at `maxChars` UTF-16 units, dropping a trailing lone high surrogate.
- `writeFileAtomic(filename, content, { mode, dirMode? })` (`atomic-write/src/index.ts:80`): mkdir parents, write a `wx` sibling `<file>.<12 hex>.tmp` with the mode, rename over the target (Windows retries `EACCES`/`EBUSY`/`EPERM` up to 8 times, 20 ms doubling to 200 ms), remove the temp on failure. No fsync. `withFileLock(filename, operation, { signal?, waitMs? })` (`:238`): `wx`-create `<file>.lock` with `<pid>\n`; on contention, if the recorded pid is provably gone (`kill(pid, 0)` → `ESRCH`), take over under a claim file after re-reading the same record; else back off 20 ms doubling to 200 ms until `waitMs` (default 2000) and throw `atomic-write: timed out waiting for the writer lock at <path>`; always remove the lock afterwards.
- `resolveWorkspacePath`, `abbreviateHomePath`, `workspaceTitleOf`, `pathPartsOf`, `relativizeToCwd`, `fileAddressFor`, `parseFileAddress` are pure string functions (`workspace-path/src/index.ts`).

## Tests worth porting

| Path | Behaviors pinned |
|---|---|
| `packages/fs/fs-patch/tests/parse.spec.ts`, `apply.spec.ts` | Full patch grammar (heredoc wrappers, CRLF, indented markers, EOF marker, move, empty hunks, line-numbered diagnostics) and the four-pass matcher, EOF tail search, trailing-empty-line retry, same-position insertion order. Adapted from Codex `rust-v0.158.0`; highest-value pure fixtures. |
| `packages/fs/fs-local/tests/fsio.spec.ts`, `filesystem.spec.ts`, `patch-mutations.spec.ts` | Realpath identity across symlinks and missing suffixes, version tokens, binary/UTF-8 rejection, CRLF round trip, atomic staging names, guarded create via link, stale/not-observed errors, lock ordering, diff-basis bounds, delete/move partial outcomes. |
| `packages/fs/fs-observation-policy/tests/policy.spec.ts` | The unseen/absent/present table, per-session isolation, disposal reset. |
| `packages/fs/fs-sandbox/tests/fs-sandbox.spec.ts`, `containment.spec.ts` | Mode fence, fresh re-resolution against swapped symlinks, temp roots, alias containment. |
| `packages/fs/tool-fs/tests/read-render.spec.ts`, `tools.spec.ts`, `integration.spec.ts`, `error.spec.ts`, `diff.spec.ts` | Window/footers, line and byte caps, offset errors, envelopes, remediation messages, escalation flow, hunk diffs. |
| `packages/fs/tool-fs/tests/apply-patch.spec.ts`, `tests/patch/*`, `apply-patch-presentation.spec.ts` | Plan/preflight/commit, refusal aggregation, partial commit rendering, unknown outcomes, symlink refusal. |
| `packages/fs/tool-fs/tests/read-image.spec.ts` | Gate order, sniffing, downscale advice text, error remediation. |
| `packages/fs/tool-fs-search/tests/tools.spec.ts`, `integration.spec.ts`, `presentation.spec.ts` | argv builders, include validation, sampling, footers, spill handoff conditions, meta cap, error classification. |
| `packages/fs/tool-str-replace-editor/tests/tools.spec.ts` | Every command's exact strings and range errors. |
| `packages/sandbox/sandbox/tests/{escalation,roots,diagnostics,vocabulary}.spec.ts` | Escalation outcomes and texts, root derivation, runner/denial classification. |
| `packages/sandbox/sandbox-local/tests/local.spec.ts` (+ `bwrap.e2e.ts`, `landlock.e2e.ts`, `seatbelt.e2e.ts`) | Exact argv per runner and mode, chain walk with injected probes, fail-closed, config validation; e2e files prove real enforcement. |
| `packages/sandbox/sandbox-policy/tests/policy.spec.ts` | Precedence, session cwd root, registrations, prompt context strings, projection fold. |
| `packages/subprocess/subprocess/tests/service.spec.ts`, `egress.spec.ts` | Env scrub rules, proxy overlay. |
| `packages/subprocess/subprocess-local/tests/spawn.spec.ts`, `local.spec.ts`, `process-exit.spec.ts`, `terminal.spec.ts` | Collector tail/spill/lossy reads, terminate ladder, pipe-drain bound, survivors and `waitForExit`, disposal, host-exit kill, terminal handle. (`linux-scope*.spec.ts`, `windows-*.spec.ts` only if those owners are ported.) |
| `packages/shell/bash-local/tests/executor.spec.ts`, `packages/shell/shell/tests/render.spec.ts` | Resolve defaults/caps, first-cause classification, readOutput merge, provider-failure note, marker parser. |
| `packages/shell/bash-sandbox/tests/sandbox.spec.ts`, `partial-landlock.spec.ts`, `foreground-timeout.spec.ts` | Denial vs runner failure, partial enforcement fact, preparation timeout. |
| `packages/shell/tool-bash/tests/tools.spec.ts`, `background.spec.ts`, `background-start.spec.ts`, `integration.spec.ts` | Schema variants, render markers, background/promoted flows, job outcome mapping, escalation. |
| `packages/shell/shell-env/tests/shell-env.spec.ts` | Built-ins, contributor validation, ordering. |
| `packages/shell/tool-bash-persistent/tests/tools.spec.ts` | Marker protocol, timeout/exit/reset texts, serialization. |
| `packages/terminal/terminal/tests/service.spec.ts`; `packages/terminal/terminal-bash/tests/{session,session-buffer,sanitize,config,local}.spec.ts` | Ownership fencing, spawn rollback, readiness tiers, bounded buffers, sanitizer split sequences, config constraints. |
| `packages/spill/spill-local/tests/spill-local.spec.ts`; `packages/spill/spill-policy/tests/{retention,notice,spill-policy,multimodal}.spec.ts` | Segment encoding, private layout, sweep rules; head/tail retention, notice format/recognition, image handling. |
| `packages/attachment/attachment/tests/*`; `packages/attachment/attachment-local/tests/{store,file-store,normalization,request-image,image}.spec.ts` | Admission limits and codes, canonical base64, layout, dedup, integrity, normalization policy, variant identity. |
| `packages/deliverables/tool-present/tests/present.spec.ts`; `packages/deliverables/workspace-changes/tests/{git,numstat,capture,compare,paths,plugin}.spec.ts` | present validation and event; snapshot isolation, numstat parsing (renames, binary), capture rules, coarse diff. |
| `packages/util/output-retention/tests/output-retention.spec.ts`, `packages/util/atomic-write/tests/atomic-write.spec.ts`, `packages/util/workspace-path/tests/*.spec.ts`, `packages/util/ripgrep/tests/*.spec.ts` | Retainer boundaries, lock takeover, address grammar, line reader. |
| Recorded sessions under `snapshots/session/`: `fs-read`, `fs-read-window`, `fs-write`, `fs-write-overwrite`, `fs-write-overwrite-bounded`, `fs-edit`, `fs-delete-recreate`, `fs-policy-reject`, `fs-same-mode-empty-justification`, `fs-glob-sampling`, `apply-patch-update`, `apply-patch-partial`, `apply-patch-rejected`, `bash-tool-turn`, `bash-spill`, `bash-startup-timeout`, `bash-same-mode-empty-justification`, `background-job-notice`, `background-confinement-failure`, `foreground-confinement-timeout`, `missing-sandbox-runner`, `partial-landlock-child-failure`, `session-sandbox-root`, `read-image*`, `multimodal-spill-ends`, `multimodal-spill-middle`, `pty-tools-sandbox-backend`, `workspace-edit`; and `snapshots/sdk/persistent-tools` | End-to-end model-visible text for each tool through shipped profiles; the `session.v4.jsonl` files give byte-exact expected tool results. |

## Porting notes

**Essential product behavior** (must match for parity): every tool name, schema, description, rendered text, error message and code listed above; the `fs/*` event protocol and the observation table; patch grammar and matcher; atomicity and guard semantics of file mutations; the mode vocabulary, escalation rules and markers; the three runner argv forms; env scrub and `DSH_*` snapshot; bash result markers and truncation-to-tail with spill path; job-backed foreground/promotion flow; PTY readiness tiers and the persistent-bash marker protocol; spill notice format and layouts; attachment ids and on-disk layout (a Racket host should be able to read an existing `DSH_HOME/attachments/v1`); the session events `sandbox/mode`, `deliverables/presented`, `workspace/changes`.

**Node/TypeScript machinery that need not be reproduced as is**: chokidar watch (any directory watcher), `AbortSignal` plumbing (map to custodians, `thread`/`sync` events, and break-enabled waits), promise-chain mutexes (use semaphores or a per-key serial worker), `WeakMap` keyed by session (use `make-weak-hasheq`), schemastery `volatile()` config (a box updated by the loader), UI projections `presentCall`/`presentResult` (needed only for the web client; the persisted `meta` they read must still be produced), the tsx/SEA runner entry selection, Koffi bindings, and the Windows ACL sandbox.

**Suggested Racket decomposition**:

- `dsh/fs` (generic interface `gen:file-system` or a struct of procedures; error struct `exn:fail:dsh:fs` with a `code` symbol; event declarations), `dsh/fs-local` (`fsio.rkt` for mechanics, provider struct), `dsh/fs-sandbox` (wrapper provider), `dsh/fs-observation-policy` (plugin with a weak hash), `dsh/fs-patch` (pure `parse-patch`, `apply-hunks`; a `match`-based line parser).
- `dsh/tool-fs` (`read.rkt`, `read-render.rkt`, `write.rkt`, `edit.rkt`, `apply-patch/{plan,preflight,commit,output}.rkt`, `read-image.rkt`, `sandbox-controller.rkt`), `dsh/tool-fs-search`, `dsh/tool-str-replace-editor`.
- `dsh/sandbox` (modes as symbols with contracts, `approve-escalation`, markers, roots, diagnostics), `dsh/sandbox-local` (pure argv builders + probes via `subprocess`), `dsh/sandbox-policy`.
- `dsh/subprocess` (spec structs with contracts; `scrubbed-parent-env`), `dsh/subprocess-local` (Racket `subprocess` with `subprocess-group-enabled` set, a pump thread per collected stream feeding an output-collector struct, a terminate ladder thread, a custodian per handle so provider disposal can shut everything down).
- `dsh/shell`, `dsh/bash-local`, `dsh/bash-sandbox`, `dsh/shell-env`, `dsh/tool-bash`, `dsh/tool-bash-persistent`.
- `dsh/terminal`, `dsh/terminal-bash` (sanitizer and bounded buffer are pure and port directly).
- `dsh/spill`, `dsh/spill-local`, `dsh/spill-policy`; `dsh/attachment`, `dsh/attachment-local`; `dsh/tool-present`, `dsh/workspace-changes`, `dsh/deliverable-file-references`; `dsh/util/{output-retention,atomic-write,workspace-path,ripgrep}`.
- Parameters fit per-call ambient facts poorly here: dsh passes policy, cwd, and signal explicitly per call; keep them explicit arguments. Use contracts at service boundaries (spec structs) and plain structs inside.

**Hard parts and risks**:

1. **String length units.** Several caps count UTF-16 code units (`readMaxLineLength`, `maxOutputChars`, 255-unit display names, spill-policy text slicing) and others count UTF-8 bytes. Racket strings count code points. Byte-exact parity on non-BMP text needs UTF-16-aware helpers; decide once and document it.
2. **Diff output.** `write`/`edit`/`apply_patch` meta and workspace-changes counts come from npm `diff`'s `structuredPatch` (Myers, 3 context lines, hunk merging). A Racket diff must produce the same hunks or snapshot metas will differ. Model-facing text does not depend on it.
3. **Atomic no-replace publish and fsync.** Racket has no built-in hard link or fsync; `createIfAbsent` and attachment publication need `link(2)` and `fsync(2)` through `ffi/unsafe` (or `renameat2(RENAME_NOREPLACE)` on Linux). `file-or-directory-stat` supplies device, inode, size, and nanosecond times for the version token.
4. **Process-range ownership.** Racket can create and kill a process group, which equals the dsh fallback owner. The Linux systemd-scope owner (range survives `setsid`/reparenting, `TasksCurrent` quiescence) is extra work: spawn `systemd-run --user --scope --collect --unit=... -- argv` directly and drive `systemctl --user kill/show`; the Node bootstrap that restores cwd/env and `execve`s is unnecessary when the scope command inherits them. Start with the fallback owner and its documented limits.
5. **PTY.** Racket has no PTY API. Options: FFI to `forkpty`/`openpty` (fork inside a Racket CS process is unsafe; prefer `posix_openpt` + a tiny C helper or `script(1)`/`socat` as the session leader), or keep a small Node/C sidecar exposing the `SubprocessTerminalHandle` operations (write, resize, foreground pgid, input-wait probe, signal group, terminate). The readiness logic above then ports unchanged. The headless xterm emulator only answers terminal queries; with `TERM=dumb` a minimal responder (or none) is likely enough, but that is unverified.
6. **Image work.** Normalization, probing, and request-image encoding use sharp/libvips (EXIF rotation, sRGB conversion, WebP/JPEG ladders, metadata stripping). Racket's `racket/draw` cannot write WebP or guarantee identical bytes. Because `attachmentId` is the digest of the normalized bytes, a different encoder yields different ids for re-encoded images (pass-through images keep identical ids). Realistic choices: shell out to the `vips` CLI, or keep a Node sidecar for `prepareImageFile`/`readRequestImageFile`. Verbatim file storage and digest verification port directly.
7. **Sandbox runners** are external programs; the Racket port only builds argv. `landlock-run` is a ~300-line C program (`native/system/packages/entry/src/main.c`) that can be built and shipped unchanged. The Windows ACL backend and Job runner can only be wrapped (they are Win32 API code) or dropped with Windows support.
8. **ripgrep** is an external binary; the port must ship or locate one and always pass `--no-config`.
9. **Locale-sensitive ordering.** `listDir` and shell-env ordering use `localeCompare`; pick a defined collation (code-point order is the safe documented deviation) and note it.
10. **Unicode White_Space** in the patch parser equals Racket's `char-whitespace?`; BOM (U+FEFF) must not be trimmed.
11. **Token pricing** in spill-policy depends on the token estimator and the provider image calculator (other areas); the retention arithmetic itself is pure.
12. **SSH family**: a full remote helper protocol; treat as a later, separate milestone. The three seams it implements are the same interfaces specified here.

## Feature checklist

- fs: `FileSystem` service interface with all 18 operations and the `sandboxMode` capability fact
- fs: `FsError` with the 16 stable codes
- fs: `fsErrorFromErrno` errno classification
- fs: `fs/write-intent`, `fs/edit-intent`, `fs/delete-intent` waterfalls with default-thunk semantics
- fs: `fs/observed` emit with present/absent observations
- fs-local: home-prefix expansion and display-path spelling (physical `..` traversal)
- fs-local: realpath target identity including missing-suffix resolution
- fs-local: version token `dev:ino:size:mtimeNs:ctimeNs`
- fs-local: stat / lstat (symlink type) / absent-as-undefined
- fs-local: whole and streamed UTF-8 reads with 8192-byte NUL sample and fatal decoding
- fs-local: `readBytes` inclusive cap with `FS_TOO_LARGE`; `readByteRange` window
- fs-local: `listDir` sorted, resolved children, broken child as `other`
- fs-local: per-target mutation lock with sorted multi-key acquisition
- fs-local: atomic staged write (private dir, `wx` temp, fsync, mode preservation, rename)
- fs-local: `createIfAbsent` no-replace publish and collision classification
- fs-local: `replaceIfVersion` stale detection
- fs-local: bounded overwrite diff basis (`diffBasisMaxBytes`, null on binary/oversize)
- fs-local: literal edit with CRLF normalization, uniqueness, `replaceAll`
- fs-local: line-ending detection and restoration
- fs-local: `patchText` with `FS_PATCH_MISMATCH`
- fs-local: `deleteFile` with bounded basis
- fs-local: `moveFile` two-effect outcome, `FS_SAME_TARGET`, source mode carried over
- fs-local: `watch` for a file or a directory's direct entries
- fs-local: config `cwd`, `diffBasisMaxBytes` with validation
- fs-sandbox: read-only denial, workspace-write containment with fresh re-resolution, full-access passthrough
- fs-sandbox: alias-aware `isPathUnder`
- fs-observation-policy: unseen/absent/present decision table per session
- fs-observation-policy: state reset on disposal
- fs-patch: parser for Begin/End/Add/Delete/Update/Move/`@@`/End of File with line-numbered errors
- fs-patch: heredoc wrapper acceptance and Environment ID rejection
- fs-patch: `applyHunks` four-pass matching, EOF tail search, trailing-empty retry, pure insertion
- tool-fs: `read` schema, window, line/byte caps, footers, envelope
- tool-fs: `read` absent observation and typed errors
- tool-fs: `read` persisted meta with `lang`
- tool-fs: `read_image` gates (extension, store, deployment types, model route), sniffing, envelope with downscale advice
- tool-fs: `write` schema, envelope, meta diffs, intent + observation
- tool-fs: `edit` schema, messages, meta diffs
- tool-fs: remediation of `FS_NOT_OBSERVED` / `FS_STALE_VERSION`
- tool-fs: sandbox denial marker + escalation hint mapping
- tool-fs: escalation fields advertised only under a confining fs; per-call policy resolution and approval
- tool-fs: `apply_patch` plan, preflight (all refusals), sequential commit, unknown-outcome detection
- tool-fs: `apply_patch` rendering (success, stopped, rejected) and meta
- tool-fs: system-prompt sections for read/write/edit/apply_patch, scope-aware
- tool-fs: config toggles and read caps with validation
- tool-fs-search: `glob` argv (hidden, no-ignore, VCS excludes, directory pruning, `--sort=modified`)
- tool-fs-search: `glob` head paging and optional top-level sampling with footers
- tool-fs-search: `grep` argv, `--json` parsing, grouping, line previews
- tool-fs-search: over-cap spill through `ctx.spillStore` in `tools/post-execute` with fallback footer
- tool-fs-search: search error codes and classification
- tool-fs-search: raw-output cap, stderr tail, cooperative timeout
- tool-fs-search: byte-capped presentation meta
- tool-str-replace-editor: `view` file with range rules and clipping
- tool-str-replace-editor: `view` directory two-level listing
- tool-str-replace-editor: `create` with existing-file refusal
- tool-str-replace-editor: `str_replace` unique verbatim match with line-number diagnostics
- tool-str-replace-editor: `insert` with range validation
- tool-str-replace-editor: null-placeholder handling and config
- sandbox: mode vocabulary and per-call policy record
- sandbox: `confine` contract and fail-closed errors
- sandbox: escalation validation, strict widening, approval outcomes and messages
- sandbox: denial and hint markers, permissions description
- sandbox: writable-root derivation and invalid-root errors
- sandbox: runner-failure and denial classifiers, runner spawn-failure attribution
- sandbox-local: bwrap argv for read-only and workspace-write
- sandbox-local: Landlock launcher argv and probe
- sandbox-local: Seatbelt SBPL profile argv
- sandbox-local: platform chain selection with cached probes
- sandbox-local: `runnerCommand` override with required failure signatures
- sandbox-local: per-runner denial signatures and failure rules
- sandbox-policy: config default mode, workspace root, additional roots
- sandbox-policy: `resolve` precedence and session-cwd root
- sandbox-policy: `sandbox/mode` event, projection, `setSandboxMode`
- sandbox-policy: session-scoped writable-root registrations
- sandbox-policy: runtime-context policy text
- subprocess: spawn spec with explicit stdio dispositions
- subprocess: env scrub (credential pattern, `DSH_*`, tombstones)
- subprocess: handle with `done`, `terminate`, `waitForExit`, offset readers
- subprocess: error codes and `subprocessSpawnFailure`
- subprocess: fd-7 control channel
- subprocess-local: `resolveExecutable` rules
- subprocess-local: bounded tail collector with optional spill file and lossy reads
- subprocess-local: TERM → grace → KILL ladder on the managed range
- subprocess-local: outcome settles after stdio drain bounded by grace
- subprocess-local: process-group fallback owner with liveness polling
- subprocess-local: Linux systemd-scope owner
- subprocess-local: Windows Job owner
- subprocess-local: disposal joins all ranges; synchronous host-exit kill
- subprocess-local: terminal primitive (spawn, write, resize, foreground inspect, signal, terminate)
- subprocess-local: shell activity observation (`idle`/`busy`/`unknown`)
- shell: request/spec split with `resolve`
- shell: execution handle (status, consuming read, observed readers, kill, result)
- shell: exit-marker parser
- bash-local: defaults and caps (timeouts, output, spill, grace), volatile config
- bash-local: fused deadline with first-cause `timedOut`/`aborted`
- bash-local: `onExpiry: 'none'`
- bash-local: terminal env overrides and env layering
- bash-local: provider-failure note and result rejection
- bash-local: stdin data and stdout budget override
- bash-sandbox: confine `bash -c` per call; full-access bypass
- bash-sandbox: denial fact, enforcement fact, runner failure → `SANDBOX_UNAVAILABLE`
- bash-sandbox: background `proc.sandbox` stamping
- shell-env: built-in `DSH_*` variables
- shell-env: contributor registration with key validation and disposal
- shell-env: frozen sorted snapshot; invalid contribution error
- tool-bash: schema variants (background field, escalation fields, timeout wording)
- tool-bash: argument validation
- tool-bash: workdir resolution against session cwd
- tool-bash: foreground render with stderr section, truncation notices, markers
- tool-bash: `run_in_background` job start
- tool-bash: foreground-as-job with promotion on timeout
- tool-bash: preparation-timeout and outside-kill (`stopped`) results
- tool-bash: job outcome mapping and sandbox notes
- tool-bash: escalation approval flow
- tool-bash: registration swap following `ctx.jobs`
- tool-bash: system-prompt section
- tool-bash-persistent: per-agent persistent shell with lazy creation and setup
- tool-bash-persistent: marker-wrapped single-line command and exit-code extraction
- tool-bash-persistent: timeout, abort, shell-exit, stdin-read handling with reset
- tool-bash-persistent: output clipping and lost-prefix note
- tool-bash-persistent: per-owner serialization
- tool-pwsh: one-shot PowerShell tool (catalog)
- tool-pwsh-persistent: persistent PowerShell tool (catalog)
- pwsh-local / pwsh-sandbox: PowerShell executors (catalog)
- terminal: backend registry
- terminal: owner-scoped spawn with name reservation, rollback, id minting
- terminal: exclusive sends, reads, signals, awaited kill, list
- terminal: owner and service disposal cleanup
- terminal-bash: sandbox-wrapped shell argv and child env with controlled prompt
- terminal-bash: startup readiness (bash and pwsh dialects)
- terminal-bash: send lifecycle with absolute timeout and cancel-by-SIGINT
- terminal-bash: readiness tiers (prompt marker, exact stdin wait, silence)
- terminal-bash: control-sequence sanitizer and prompt-marker detection
- terminal-bash: bounded scrollback and newest-relative paging
- terminal-bash: sandbox-mode change fence
- terminal-bash: config with constraints
- spill: `saveText` contract and source vocabulary
- spill-local: private session-scoped file layout and injective name encoding
- spill-local: startup age sweep with trust checks
- spill-policy: token pricing of text and images
- spill-policy: head/tail retention with indivisible images
- spill-policy: notice format and recognition
- spill-policy: PTC dispatch-log bounding and additional context
- spill-policy: fail-open on missing backend/pricing
- attachment: batch limits and media-type admission
- attachment: canonical base64 admission for images and files
- attachment: prompt-content admission
- attachment: error codes and code-based recognition
- attachment: projection geometry helpers
- attachment-local: content-addressed image store with durable publication and dedup
- attachment-local: image normalization policy (pass-through, downscale, ladder)
- attachment-local: verified image reads
- attachment-local: verbatim file store with sanitized leaf names and streamed IO
- attachment-local: request-image variants with cache and shared in-flight work
- attachment-local: compression concurrency limit
- tool-present: `present` tool validation and result
- tool-present: `deliverables/presented` event on success
- workspace-changes: eligibility (top-level sessions with cwd)
- workspace-changes: isolated git tree snapshots at turn start/end
- workspace-changes: file-tool captures for uncovered paths
- workspace-changes: summary with counts, cap, and `workspace/changes` event
- workspace-changes: on-demand per-file diff with coarse fallback
- deliverable-file-references: system-prompt section
- ssh: remote fs / subprocess / sandbox providers over a verified helper (catalog)
- sandbox-windows-acl: Windows restricted-token runner (catalog)
- win32-process: Win32 process/Job bindings (catalog)
- util/ripgrep: packaged binary resolution, `--no-config` spawn, streaming line reader
- util/output-retention: `ItemRetainer`, `TextRetainer`, omission wording, surrogate-safe cap
- util/atomic-write: atomic replace and cross-process writer lock with dead-holder takeover
- util/workspace-path: path helpers, `dsh-resource://file/` addresses, file media URL
