# Interface contract: `dsh-fs`

This is the binding interface for `racket/dsh-fs/`. It covers the filesystem Service Definition and its `fs/*` events, the local provider (realpath identity, atomic guarded writes, literal edits, patches, moves), the sandbox-aware provider, the read-before-write observation policy, the patch parser and applier, a line diff that reproduces the hunks dsh stores, every model-facing file tool (`read`, `read_image`, `write`, `edit`, `apply_patch`, `glob`, `grep`, `str_replace_editor`, `present`), the spill store and the token-budget spill policy, the content-addressed attachment store, and the deliverables plugins. Sources: [recon 08](../recon/08-exec-world.md) (cited as R8 with its section), [recon 20](../recon/20-racket-mechanisms.md) (R20), and `packages/{fs,spill,attachment,deliverables}/*/src` at commit `e8f7b93a3`. When this document and the TypeScript disagree about behaviour, the TypeScript is right and this document gets fixed. When they disagree about names and argument order of the Racket surface, this document is right. Read [dsh-session.md](dsh-session.md), [dsh-llm.md](dsh-llm.md), [dsh-tools.md](dsh-tools.md), [dsh-agent.md](dsh-agent.md) and [dsh-exec.md](dsh-exec.md) first; this contract uses their vocabulary without repeating it (`absent`, jobjects, `define-session-event`, cancel events, `make-tool`, `define-tool`, `tool-execution`, `execution-policy`, `approve-escalation`, `gen:working-directory-port`, `subprocess-spawn`).

Package: directory `racket/dsh-fs/`, collection `dsh-fs`, `(define deps '("base" "cordis" "cordis-data" "cordis-schema" "dsh-util" "dsh-session" "dsh-llm" "dsh-tools" "dsh-agent" "dsh-exec"))`, `(define build-deps '("rackunit-lib" "dsh-test-support"))`. It must not depend on any wave 4 package other than `dsh-exec`.

## Scope

| dsh package | npm name | Status |
|---|---|---|
| `packages/fs/fs` | `@deepseek-ai/dsh-fs` | native |
| `packages/fs/fs-local` | `@deepseek-ai/dsh-fs-local` | native. `link(2)`, `fsync(2)` and `realpath(3)` through the FFI. `watch` uses `filesystem-change-evt` in place of chokidar. Directory listings sort by code point where dsh uses `localeCompare`. The Windows path rules (`win32.ts`) are not applicable. |
| `packages/fs/fs-observation-policy` | `@deepseek-ai/dsh-fs-observation-policy` | native |
| `packages/fs/fs-patch` | `@deepseek-ai/dsh-fs-patch` | native |
| `packages/fs/fs-sandbox` | `@deepseek-ai/dsh-fs-sandbox` | native; a wrapper around a provider where dsh subclasses |
| `packages/fs/tool-fs` | `@deepseek-ai/dsh-tool-fs` | native. The hunk diff is reimplemented from npm `diff` 9.0.0 (rules 26 to 29). |
| `packages/fs/tool-fs-search` | `@deepseek-ai/dsh-tool-fs-search` | native. `rg` is an external program found on `PATH` or named by `x-racket.rgPath`; dsh ships it as an npm dependency. |
| `packages/fs/tool-str-replace-editor` | `@deepseek-ai/dsh-tool-str-replace-editor` | native |
| `packages/spill/spill` | `@deepseek-ai/dsh-spill` | native |
| `packages/spill/spill-local` | `@deepseek-ai/dsh-spill-local` | native |
| `packages/spill/spill-policy` | `@deepseek-ai/dsh-spill-policy` | native |
| `packages/attachment/attachment` | `@deepseek-ai/dsh-attachment` | native |
| `packages/attachment/attachment-local` | `@deepseek-ai/dsh-attachment-local` | adapted. Layout, identifiers, publication, verification, verbatim files and the request-image cache are native. Image metadata comes from a header reader written in Racket. An image that is already in normalised form is stored unchanged, byte for byte as dsh stores it. An image that needs re-encoding is handed to an optional external program (`vips`, else ImageMagick); dsh uses sharp. Rule 68 states what differs. |
| `packages/deliverables/tool-present` | `@deepseek-ai/dsh-tool-present` | native |
| `packages/deliverables/workspace-changes` | `@deepseek-ai/dsh-workspace-changes` | native; wraps the system `git`, as dsh does |
| `packages/deliverables/deliverable-file-references` | `@deepseek-ai/dsh-deliverable-file-references` | native |
| `packages/ssh/fs-ssh` | `@deepseek-ai/dsh-fs-ssh` | native client of the helper protocol, implemented here (`dsh-fs/ssh`) because it implements `gen:fs-provider`; listed in [dsh-exec.md](dsh-exec.md) with the SSH group |

Libraries of `packages/util` this package needs and `dsh-util` owns: `output-retention`, `ripgrep`, `workspace-path`, `atomic-write`, `code-language`, `home-paths`. Rules 84 and 85 state the behaviour this package relies on, so an implementer can supply a private copy where `dsh-util` lacks a name.

## Modules

| Module | Provides |
|---|---|
| `dsh-fs` (`main.rkt`) | re-exports `fs`, `errors`, `patch`, `diff`, `spill`, `attachment` |
| `dsh-fs/errors` | `exn:fail:fs` and the other error constructors, the code lists, `fs-error-from-errno` |
| `dsh-fs/fs` | the `fs` service definition, `gen:fs-provider`, targets, infos, intents, outcomes, observations, the four `fs/*` events |
| `dsh-fs/local` | `make-local-fs` |
| `dsh-fs/sandbox` | `make-sandboxed-fs`, `path-under?` |
| `dsh-fs/observation-policy` | `make-observation-gate` and its three decisions |
| `dsh-fs/patch` | `parse-patch`, `apply-hunks`, patch records, `exn:fail:patch-parse` |
| `dsh-fs/diff` | `diff-lines`, `structured-patch`, `compute-hunk-diffs`, `diff-hunk` |
| `dsh-fs/tool/common` | session cwd resolution, the per-call sandbox controller, `remediate-fs-error` |
| `dsh-fs/tool/read`, `…/read-image`, `…/write`, `…/edit`, `…/apply-patch` | the tool constructors and their pure renderers (`build-read-window`, `format-read-output`, `render-patch-report`) |
| `dsh-fs/tool/search` | `make-glob-tool`, `make-grep-tool`, the argv builders, `sample-across-top-level`, the renderers |
| `dsh-fs/tool/str-replace-editor` | `make-str-replace-editor-tool` |
| `dsh-fs/tool/present` | `make-present-tool`, the `deliverables/presented` session event |
| `dsh-fs/spill` | the `spillStore` service definition, `gen:spill-store`, `spill-ref` |
| `dsh-fs/spill/local` | `make-local-spill-store`, `encode-segment`, the cleanup sweep |
| `dsh-fs/spill/policy` | `retain-content`, `format-spill-notice`, `has-spill-notice?`, the policy listener |
| `dsh-fs/attachment` | the `attachments` service definition, `gen:attachment-store`, refs, limits, admission, `request-image-dimensions`, `long-edge-dimensions`, `request-image-variant-id` |
| `dsh-fs/attachment/probe` | `probe-image`, `detected-image` |
| `dsh-fs/attachment/local` | `make-local-attachment-store`, `can-pass-through?`, the image-tool adapters |
| `dsh-fs/workspace-changes` | the `workspaceChanges` service definition, the `workspace/changes` session event, `compare-text` |
| `dsh-fs/ssh` | `make-ssh-fs` |
| `dsh-fs/plugin/<short-name>` | one module per row of Plugins, each providing `plugin` |
| `dsh-fs/plugins` | `plugin-table` |

Private modules, suggested: `private/posix.rkt` (FFI `link`, `fsync`, `realpath`, `getuid`), `private/fsio.rkt` (probes, reads, atomic write), `private/keyed-lock.rkt`, `private/git.rkt`, `private/numstat.rkt`, `private/recorder.rkt`.

## Data

Process-local values are structs. Values that are logged, stored on disk, sent over the SSH wire or shown to user interfaces are jobjects with the dsh keys in the dsh order. `cancel` is a cancel event or `#f`.

### Filesystem values (`dsh-fs/fs`; `fs/src/types.ts`)

```racket
(struct fs-target (key display-path) #:transparent)             ; FsTarget; both strings
(fs-target->jvalue t) (jvalue->fs-target jv)                     ; {targetKey, displayPath}
(fs-version? v)                                                  ; a string; opaque to consumers
(struct fs-info (version type size) #:transparent)               ; type : 'file 'directory 'other; lstat adds 'symlink; size : integer or #f
(struct fs-dir-entry (name type target version size) #:transparent)   ; version, size : #f when unknown
(struct create-if-absent () #:transparent)
(struct replace-if-version (version) #:transparent)
(fs-write-intent? v)                                             ; create-if-absent? or replace-if-version?
(struct version-guard (version) #:transparent)                   ; the {version} of edit, patch, delete and move
(struct fs-edit-request (old-string new-string replace-all?) #:transparent)
(struct fs-write-outcome (operation version before after) #:transparent)   ; operation : 'create 'update; before : string or #f
(struct fs-edit-outcome (version before after) #:transparent)
(struct fs-delete-outcome (before) #:transparent)
(struct fs-move-outcome (source-before destination source-deleted? source-failure) #:transparent)
(struct fs-present (version) #:transparent)
(struct fs-absent () #:transparent)
(fs-observation? v)                                              ; fs-present? or fs-absent?
(struct text-stream (next close))                                ; next : (-> (or/c string? eof-object?)), may wait; close : (-> void?)
```

`destination` of a move outcome is an `fs-write-outcome`; `source-failure` is `#f` or `(cons code message)` and is present exactly when `source-deleted?` is false. `#f` stands for JavaScript `undefined` and `null` in these structs. Consumers must not parse a target key or a version.

### Errors (`dsh-fs/errors`)

All are substructs of `exn:fail:harness` made only by the constructors below.

| Constructor | dsh name | Codes |
|---|---|---|
| `(make-fs-error code message #:cause [c #f] #:hunk-line [n #f])` | `FsError` | `fs-error-codes`, in this order: `FS_NOT_FOUND`, `FS_NOT_DIRECTORY`, `FS_NOT_TEXT`, `FS_NOT_REGULAR_FILE`, `FS_TOO_LARGE`, `FS_PERMISSION_DENIED`, `FS_SANDBOX_DENIED`, `FS_IO_ERROR`, `FS_STALE_VERSION`, `FS_NOT_OBSERVED`, `FS_AMBIGUOUS_EDIT`, `FS_EDIT_NOT_FOUND`, `FS_ABORTED`, `FS_PATCH_MISMATCH`, `FS_SAME_TARGET`, `FS_ALREADY_EXISTS` |
| `(make-patch-tool-error code message)` | `PatchToolError` | `PATCH_SYNTAX`, `PATCH_SYMLINK_SOURCE` |
| `(make-image-input-error code message)` | `ImageInputError` | `IMAGE_UNSUPPORTED_MODEL`, `IMAGE_UNSUPPORTED_FORMAT` |
| `(make-search-error code message)` | `SearchError` | `SEARCH_INVALID_PATTERN`, `SEARCH_FAILED`, `SEARCH_RAW_OUTPUT_OVERFLOW`, `SEARCH_ABORTED` |
| `(make-attachment-error code message #:cause [c #f])` | `AttachmentError` | `attachment-error-codes`: `TOO_MANY_IMAGES`, `IMAGES_TOO_LARGE`, `UNSUPPORTED_IMAGE_TYPE`, `INVALID_IMAGE_BASE64`, `INVALID_IMAGE`, `IMAGE_TYPE_MISMATCH`, `IMAGE_TOO_LARGE`, `IMAGE_TOO_MANY_PIXELS`, `IMAGE_DIMENSION_TOO_LARGE` (these nine are the image admission codes), `INVALID_FILE_BASE64`, `INVALID_ATTACHMENT_REF`, `ATTACHMENT_CORRUPT`, `ATTACHMENT_WRITE_FAILED`, `ATTACHMENT_NOT_FOUND`, `ATTACHMENT_READ_FAILED`, `ATTACHMENT_PROJECTION_UNSUPPORTED`, `ATTACHMENT_FILES_UNSUPPORTED` |

```racket
(struct exn:fail:patch-parse exn:fail (line-number))              ; dsh PatchParseError; not a harness error
(struct exn:fail:errno exn:fail (code operation path))            ; a system-call failure with its errno name, e.g. "ENOENT"
(fs-error-from-errno operation display-path v) -> any/c
(attachment-error? v) -> boolean?                                 ; by code, as dsh isAttachmentError
```

`(fs-error-from-errno operation display-path v)` (`fs/src/errno.ts:18`) returns `v` unchanged when it is already an fs error or carries no errno name; `ENOENT` and `ENOTDIR` give `FS_NOT_FOUND` `cannot <operation> "<path>": not found`; `EACCES` and `EPERM` give `FS_PERMISSION_DENIED` `cannot <operation> "<path>": permission denied`; `EISDIR` gives `FS_NOT_REGULAR_FILE` `cannot <operation> "<path>": not a regular file`; any other gives `FS_IO_ERROR` `cannot <operation> "<path>": <message>`. Racket file procedures raise `exn:fail:filesystem:errno` with a numeric code; `private/fsio` converts it to `exn:fail:errno` with the platform's name for that number.

### Patch records (`dsh-fs/patch`; `fs-patch/src/types.ts`)

```racket
(struct patch-hunk (line-number context old-lines new-lines end-of-file?) #:transparent)   ; context : string or #f
(patch-hunk->jvalue h) -> jobject?                                ; {lineNumber, context?, oldLines, newLines, isEndOfFile}
(struct patch-add (path line-number content) #:transparent)
(struct patch-delete (path line-number) #:transparent)
(struct patch-update (path line-number move-to hunks) #:transparent)   ; move-to : string or #f
(struct hunk-mismatch (line-number stage pattern) #:transparent)       ; stage : 'context or 'old-lines
(struct diff-hunk (old-start old-lines new-start new-lines lines) #:transparent)   ; lines : strings starting with " ", "+", "-" or "\\"
```

### Tool values and persisted meta

Canonical values and meta are jobjects; the key orders below are the orders dsh writes.

| Tool | Value | Persisted meta |
|---|---|---|
| `read` | `{path, offset, lines: [{number, text}], totalLines}` | `{path, offset, lines, totalLines, lang?}` |
| `read_image` | `{path, image: <image ref>}` | `{path}` |
| `write` | `{path, operation, before, after}` with `before` a string or `null` | `{operation, path, diffs}` |
| `edit` | `{path, before, after}` | `{path, diffs}` |
| `apply_patch` | `{phase: "commit", cancelled, affectedPaths, operations: [{index, kind, path, destination?, patchLine, status, code?, message?, hunkLine?, changes?: [{path, before, after}]}]}` | `{diffs, stopped}` |
| `glob` | `{root, paths}` | `{shape: "paths", paths, truncated, total}` |
| `grep` | `{matches: [{path, lineNumber, line}]}` | `{shape: "matches", files: [{path, matches: [{lineNumber, line}]}], truncated, total}` |
| `str_replace_editor` | a string | none |
| `present` | `{turn, files: [{path, description?}]}` | none |

A file diff is `{path, oldText, newText}` with `oldText` a string or `null`. `kind` is `add`, `update`, `delete` or `move`; `status` is `completed`, `failed`, `unknown` or `skipped`.

### Spill (`dsh-fs/spill`)

```racket
(struct spill-ref (locator bytes retrieval-hint) #:transparent)   ; locator : string (a path for the local store)
(spill-source? v)                                                 ; jobject {kind: "tool", toolName, callId, label} or {kind: "session-reference", sessionId, label}
```

### Attachments (`dsh-fs/attachment`; `attachment/src/types.ts`)

An image ref is the jobject `{attachmentId, mediaType, bytes, width, height, name?, originalDimensions?: {width, height}}` in that key order; a file ref is `{attachmentId, name, bytes}`. `attachmentId` is `sha256:` followed by 64 lowercase hex digits. `mediaType` is one of `image/png`, `image/jpeg`, `image/webp`, `image/gif`. These are the values `dsh-llm` reads inside image and file blocks.

```racket
(image-ref? v) (file-ref? v) (attachment-id? v)
(struct image-limits (max-image-bytes max-images-per-message max-message-image-bytes max-image-pixels max-image-dimension media-types) #:transparent)
(struct image-input (data media-type name) #:transparent)          ; data : bytes?; name : string or #f
(struct detected-image (media-type width height animated? carries-metadata? depth space has-alpha?) #:transparent)
(request-image-dimensions width height max-pixels) -> (values exact-positive-integer? exact-positive-integer?)
(long-edge-dimensions width height long-edge) -> (values exact-positive-integer? exact-positive-integer?)
(request-image-variant-id image-ref width height max-bytes) -> string?
```

`depth` is `"uchar"`, `"ushort"` or another libvips band-format name; `space` is `"srgb"`, `"b-w"`, `"rgb16"`, `"grey16"`, `"cmyk"` (the names sharp reports). `request-image` is the struct of `dsh-llm/ports`.

### Workspace changes (`dsh-fs/workspace-changes`; `workspace-changes/src/types.ts`)

Summary: `{turn, cwd, files: [{path, display, added, deleted, binary?, oversized?}], total, added, deleted, snapshot?: {before, after}}`. File diff: `{kind: "text", path, display, before, after, hunks: [{oldStart, oldLines, newStart, newLines, lines}], coarse}`, `{kind: "binary", path, display}` or `{kind: "oversized", path, display}`. Both are jobjects because clients receive them as JSON.

### Session events declared here

```racket
(define-session-event deliverables/presented #:type "deliverables/presented"
  #:fields ([turn session-seq?] [call-id "callId" string?] [files (listof jobject?)]))    ; files : [{path, description?}]
(define-session-event workspace/changes #:type "workspace/changes"
  #:fields ([turn session-seq?]))
```

Neither is a surface event or ignorable; neither is model-visible.

## Services

`x` is a context or a handle for the service; "the caller's context" is `(use-context x)`.

### `fs`

`(define-service fs 'fs #:contract fs-provider?)` in `dsh-fs/fs`. One provider per context. The service value also implements `gen:host-path-port` of `dsh-llm/ports`.

```racket
(define-generics fs-provider
  (fs-provider-sandbox-mode fs-provider)                               ; -> (or/c sandbox-mode? #f); default #f
  (fs-provider-resolve fs-provider path cwd cancel)                    ; -> fs-target?
  (fs-provider-process-path fs-provider target)                        ; -> string?
  (fs-provider-process-path-from-host-path fs-provider host-path)      ; -> (or/c string? #f); default #f
  (fs-provider-file-url fs-provider target)                            ; -> string?
  (fs-provider-contains? fs-provider parent child)                     ; -> boolean?
  (fs-provider-stat fs-provider target cancel)                         ; -> (or/c fs-info? #f)
  (fs-provider-lstat fs-provider path cwd cancel)                      ; -> (or/c fs-info? #f)
  (fs-provider-read-text fs-provider target cancel)                    ; -> string?
  (fs-provider-stream-text fs-provider target cancel)                  ; -> text-stream?
  (fs-provider-read-bytes fs-provider target cancel max-bytes)         ; -> bytes?
  (fs-provider-read-byte-range fs-provider target offset length cancel)   ; -> bytes?
  (fs-provider-list-dir fs-provider target cancel)                     ; -> (listof fs-dir-entry?)
  (fs-provider-write-text fs-provider target content expected cancel policy)   ; -> fs-write-outcome?
  (fs-provider-edit-text fs-provider target edit expected cancel policy)       ; -> fs-edit-outcome?
  (fs-provider-patch-text fs-provider target hunks expected cancel policy)     ; -> fs-edit-outcome?
  (fs-provider-delete-file fs-provider target expected cancel policy)          ; -> fs-delete-outcome?
  (fs-provider-move-file fs-provider source destination hunks expected-source expected-destination cancel policy)   ; -> fs-move-outcome?
  (fs-provider-watch fs-provider target changed cancel))               ; -> (-> void?), the close procedure
```

Public procedures, each reading the service value through `x` and calling the operation of the same name:

```racket
(fs-sandbox-mode x) -> (or/c sandbox-mode? #f)
(fs-resolve x path #:cwd [cwd #f] #:cancel [cancel #f]) -> fs-target?
(fs-process-path x target) -> string?
(fs-process-path-from-host-path x host-path) -> (or/c string? #f)
(fs-file-url x target) -> string?
(fs-contains? x parent child) -> boolean?
(fs-stat x target #:cancel [cancel #f]) -> (or/c fs-info? #f)
(fs-lstat x path #:cwd [cwd #f] #:cancel [cancel #f]) -> (or/c fs-info? #f)
(fs-read-text x target #:cancel [cancel #f]) -> string?
(fs-stream-text x target #:cancel [cancel #f]) -> text-stream?
(fs-read-bytes x target max-bytes #:cancel [cancel #f]) -> bytes?
(fs-read-byte-range x target offset length #:cancel [cancel #f]) -> bytes?
(fs-list-dir x target #:cancel [cancel #f]) -> (listof fs-dir-entry?)
(fs-write-text x target content #:expected [expected #f] #:cancel [cancel #f] #:sandbox-policy [policy #f]) -> fs-write-outcome?
(fs-edit-text x target edit #:expected [guard #f] #:cancel [cancel #f] #:sandbox-policy [policy #f]) -> fs-edit-outcome?
(fs-patch-text x target hunks #:expected [guard #f] #:cancel [cancel #f] #:sandbox-policy [policy #f]) -> fs-edit-outcome?
(fs-delete-file x target #:expected [guard #f] #:cancel [cancel #f] #:sandbox-policy [policy #f]) -> fs-delete-outcome?
(fs-move-file x source destination #:hunks [hunks #f] #:expected-source [guard #f] #:expected-destination [intent #f]
              #:cancel [cancel #f] #:sandbox-policy [policy #f]) -> fs-move-outcome?
(fs-watch x target changed #:cancel cancel) -> disposer?
```

Semantics are those of R8 "`ctx.fs`" and rules 1 to 18. `expected` of a write is an `fs-write-intent` or `#f` (unconditional); a guard is a `version-guard` or `#f`. Every operation may wait and raises `exn:fail:fs`; a cancelled operation raises `FS_ABORTED`. `fs-sandbox-mode` is the capability fact a tool layer reads once at mount. `fs-watch` is the only operation that registers anything: one effect `fs.watch()` on the caller's context whose inverse closes the watcher; `changed` is `(-> (or/c exn? #f) any)`. Ownership rules: providers record no observation and dispatch no event; consumers dispatch an intent before a mutation and emit `fs/observed` after (rule 21).

### `spillStore`

`(define-service spill-store 'spillStore #:contract spill-store?)` in `dsh-fs/spill`.

```racket
(define-generics spill-store
  (spill-store-save-text spill-store session-id source suggested-name content))   ; -> spill-ref?, waits
(spill-save-text x #:session-id session-id #:source source #:suggested-name name #:content content) -> spill-ref?
```

It stores the full content verbatim and privately under a collision-free name derived from the suggestion, and raises on a real storage failure; callers treat a save as best effort. It registers nothing.

### `attachments`

`(define-service attachments 'attachments #:contract attachment-store?)` in `dsh-fs/attachment`. The service value also implements `gen:attachment-port` of `dsh-llm/ports` (rule 74).

```racket
(define-generics attachment-store
  (store-image-limits attachment-store)                                ; -> image-limits?
  (store-validate-image attachment-store input)                        ; -> void?
  (store-save-images attachment-store inputs)                          ; -> (listof image-ref?), waits
  (store-read-image attachment-store ref cancel)                       ; -> bytes?, waits
  (store-image-host-path attachment-store ref)                         ; -> (or/c string? #f)
  (store-save-file attachment-store data name cancel)                  ; data : (or/c bytes? input-port?); -> file-ref?, waits
  (store-read-file attachment-store ref cancel)                        ; -> input-port?
  (store-file-host-path attachment-store ref)                          ; -> (or/c string? #f)
  (store-read-image-request attachment-store ref width height max-bytes cancel))   ; -> request-image?
(attachments-image-limits x) -> image-limits?
(attachments-validate-image x input) -> void?
(attachments-save-image x input) -> image-ref?
(attachments-save-images x inputs) -> (listof image-ref?)              ; the whole batch is validated and prepared before any is committed
(attachments-read-image x ref #:cancel [cancel #f]) -> bytes?
(attachments-image-host-path x ref) -> (or/c string? #f)
(attachments-admit-prompt-content x parts) -> (listof jobject?)
(attachments-admit-encoded-file x base64 [name #f]) -> file-ref?
(attachments-save-file x data #:name [name #f] #:cancel [cancel #f]) -> file-ref?
(attachments-read-file x ref #:cancel [cancel #f]) -> input-port?
(attachments-file-host-path x ref) -> (or/c string? #f)
(attachments-read-image-request x ref #:width w #:height h #:max-bytes n #:cancel [cancel #f]) -> request-image?
```

The file and request-image operations have defaults that raise `ATTACHMENT_FILES_UNSUPPORTED` and `ATTACHMENT_PROJECTION_UNSUPPORTED`. None registers an effect.

### `workspaceChanges`

`(define-service workspace-changes 'workspaceChanges #:contract workspace-changes?)` in `dsh-fs/workspace-changes`.

```racket
(workspace-changes-summary x session-id seq) -> (or/c jobject? #f)
(workspace-changes-diff x session-id seq index #:cancel cancel) -> (or/c jobject? #f)     ; waits
```

State is in memory per live session and is gone after the session is disposed or the host restarts.

### Waiting and cancellation

- Every `fs-…` operation that touches the disk takes `#:cancel` and raises `FS_ABORTED` (`<operation> aborted`). A move past its last checkpoint completes both effects regardless (rule 13).
- Tools: the execution's cancel event. `glob` and `grep` also carry `timeout-ms` on their definitions.
- `spill-save-text` and the attachment writes take no cancel event; a durable publication must complete. `attachments-read-image`, `attachments-read-file`, `attachments-read-image-request` and `workspace-changes-diff` take `#:cancel`.
- No procedure of this package catches a break.

## Events

Declared in `dsh-fs/fs`. The module exports the `on-…`, `…-name` and `dispatch-…` bindings of all four, because tools of other packages produce them. They are plain dispatches on the producer's plugin context, not scope-filtered.

```racket
(define-event fs/write-intent  'fs/write-intent  #:mode waterfall #:args (fs-target? any/c) #:result (or/c fs-write-intent? #f))
(define-event fs/edit-intent   'fs/edit-intent   #:mode waterfall #:args (fs-target? any/c) #:result (or/c version-guard? #f))
(define-event fs/delete-intent 'fs/delete-intent #:mode waterfall #:args (fs-target? any/c) #:result (or/c version-guard? #f))
(define-event fs/observed      'fs/observed      #:mode emit      #:args (fs-target? fs-observation? any/c))
```

| Event | Dispatched by, when | Guarantees |
|---|---|---|
| `fs/write-intent` | `write`, `apply_patch` (add, move destination), `str_replace_editor create`, before the mutation | A single-slot decision. The innermost step returns `#f` (unconditional), except for `str_replace_editor create`, whose innermost step returns `(create-if-absent)`. The first listener that returns without calling `next` owns the answer. A listener may raise to refuse. |
| `fs/edit-intent` | `edit`, `apply_patch` (update, move source), `str_replace_editor str_replace` and `insert` | as above; innermost `#f` |
| `fs/delete-intent` | `apply_patch` delete | as above |
| `fs/observed` | every file tool after a successful read or mutation, and on a metadata miss | Listeners must not wait and must not raise: a raise becomes the tool's error although the mutation already committed. |

The second argument, the *actor*, is the tool execution or `#f`. Listeners treat it as opaque except through `tool-execution-agent`.

Consumed, registered by name with `ctx-on`:

| Event | Listener | What it does |
|---|---|---|
| the three intents and `fs/observed` | `dsh-fs/plugin/fs-observation-policy` | rule 19; its intent listeners never call `next` |
| the three intents, with `#:prepend? #t` | `dsh-fs/plugin/workspace-changes` | calls `next` first, then captures the target file before the mutation runs (rule 79) |
| `tools/post-execute` | `dsh-fs/plugin/tool-fs-search` | rule 49 |
| `tools/post-execute`, `#:prepend? #t` | `dsh-fs/plugin/spill-policy` | rules 60 to 63; outermost, so it sees content the search tools already replaced |
| `tools/ptc-dispatch-log` (waterfall of `dsh-ptc`), `#:prepend? #t` | `dsh-fs/plugin/spill-policy` | bounds the dispatch-log copy with label `dispatch` (rule 63) |
| `tools/result` | `dsh-fs/plugin/tool-present` | rule 76 |
| `tools/pre-execute` | `dsh-fs/plugin/workspace-changes` | binds the execution to its session's recorder and waits for the recorder's queue |
| `session/event`, `session/disposed`, `agent/turn-stopping` | `dsh-fs/plugin/workspace-changes` | rules 77 to 80 |

Session events: `deliverables/presented` and `workspace/changes` (Data).

## Tools

Argument failures raise the tool args error of `dsh-tools` (`invalid arguments: <violations>`, code `INVALID_ARGS`). Each tool renders its canonical value into one text block unless stated. Relative paths of `read`, `read_image`, `write`, `edit`, `apply_patch` and `present` resolve against the session working directory, `(working-directory-ensure port agent cancel)`; without an agent the provider's default applies. Definitions whose parameter list or description depends on config are built with `make-tool`; the others with `define-tool`. The compiled schemas of `read`, `read_image`, `write`, `edit`, `apply_patch`, `glob` and `grep` must equal, as `jvalue->string` text, the entries of those names under `initial` in `snapshots/session/agent-instructions/tool-schemas.expected.json` (a composition with a confining `fs`, `globMaxResults` 100, `grepMaxMatches` 250, head paging).

### Escalation parameters

`write`, `edit` and `apply_patch` append these two parameters, in this order, only when `(fs-sandbox-mode fs)` is not `#f` at mount:

```racket
(param "sandbox_permissions" (v-string #:enum escalation-targets #:description (sandbox-permissions-description "operation")))
(param "justification" (v-string #:description "Required with sandbox_permissions: one sentence for the user explaining why this exact file operation needs the wider access. Use the language of the user’s current request."))
```

### `read` (`tool-fs/src/read.ts:77`)

```racket
(make-tool #:name "read"
  #:description "Read a UTF-8 text file and return line-numbered content."
  #:parameters (parameters
    (param "file_path" (v-string #:description "Path to read, resolved by the filesystem backend.") #:required? #t)
    (param "offset" (v-number #:description "1-based first line to return. Defaults to 1."))
    (param "limit" (v-number #:description (format "Maximum number of lines to return. Defaults to ~a." readLimit))))
  #:output READ-OUTPUT-SPEC                      ; read.ts:100-121
  #:concurrency-safe? (lambda (args) #t) …)
```

Validation, in order: `file_path must be a non-empty string` (blank after trimming); `offset must be a positive integer`; `limit must be a positive integer`; `limit must be less than or equal to <readLimit>`. Rendered text (`format-read-output`, rule 34):

```
<path>{path}</path>
<type>file</type>
<content>
{n}: {text}
…

{footer}
</content>
```

Errors: `cannot read "<displayPath>": not found` (`FS_NOT_FOUND`); `cannot read "<displayPath>": not a regular file` (`FS_NOT_REGULAR_FILE`); `cannot read "<displayPath>": binary file` and `…: invalid UTF-8 text` (`FS_NOT_TEXT`); `offset <n> is out of range for "<displayPath>" (<total> lines)` (`FS_NOT_FOUND`). No sandbox or approval interaction.

### `read_image` (`tool-fs/src/read-image.ts:287`)

```racket
(define-tool read-image
  #:name "read_image"
  #:description "Read a PNG/JPEG/WebP/GIF file and return the image itself. Large images are downscaled automatically; do not install image libraries or create thumbnails to inspect an image."
  #:parameters ([file_path (v-string #:description "Path to the image file, resolved by the filesystem backend.") #:required])
  #:output READ-IMAGE-OUTPUT-SPEC
  (render (value) …) (execute (exec) …) (presentation-meta (value) (jobj [path (jref value 'path)])) (concurrency-safe? () #t))
```

Registered only while an `attachments` service exists and `readImage` is true. Content: a text block followed by `{type: "image", attachment: <image ref>}`. The text:

```
<path>{path}</path>
<type>image</type>
<content>
{mediaType} image, {width}x{height} px, {bytes} bytes{scaled}
</content>
```

`{scaled}` is present only with `originalDimensions` `{ow, oh}`: ` (downscaled from {ow}x{oh} px; {advice} to locate features in the original file)`, where `x` is `ow/width` and `y` is `oh/height`, each printed with two decimals as JavaScript `toFixed(2)` prints them, and the advice is `multiply coordinates by {x}` when the two printed-from numbers are equal and `multiply x coordinates by {x} and y coordinates by {y}` otherwise. Errors are rule 35.

### `write` (`tool-fs/src/write.ts:73`)

```racket
(make-tool #:name "write"
  #:description "Create or fully replace a UTF-8 text file."
  #:parameters (parameters
    (param "file_path" (v-string #:description "Path to write, resolved by the filesystem backend. Provide `file_path` before `content` in the arguments.") #:required? #t)
    (param "content" (v-string #:description "Full UTF-8 text content to write.") #:required? #t)
    escalation-parameters …) …)
```

Validation: `file_path must be a non-empty string`; empty `content` is valid. Rendered text:

```
<path>{path}</path>
<type>file</type>
<content>
{Created|Updated} file
</content>
```

Meta `diffs` is `[]` when `before` is `null`, else `(compute-hunk-diffs path before after)`.

### `edit` (`tool-fs/src/edit.ts:85`)

```racket
(make-tool #:name "edit"
  #:description "Edit an existing UTF-8 text file by replacing literal text."
  #:parameters (parameters
    (param "file_path" (v-string #:description "Path to edit, resolved by the filesystem backend. Provide `file_path` before `old_string` and `new_string` in the arguments.") #:required? #t)
    (param "old_string" (v-string #:description "Literal text to replace.") #:required? #t)
    (param "new_string" (v-string #:description "Literal replacement text. Use an empty string to delete the match.") #:required? #t)
    (param "replace_all" (v-boolean #:description "Replace all matches. Defaults to false; when false, old_string must appear exactly once."))
    escalation-parameters …) …)
```

Validation: `file_path must be a non-empty string`; `old_string must be a non-empty string`; `old_string and new_string must differ`. Rendered text: `The file {path} has been updated successfully.`, or with `replace_all` `The file {path} has been updated. All occurrences were successfully replaced.` Provider errors are rule 10; remediation is rule 31.

### `apply_patch` (`tool-fs/src/apply-patch.ts:26`; registered only with `applyPatch: true`)

```racket
(make-tool #:name "apply_patch"
  #:description "Create, update, delete, or move UTF-8 text files with one patch; prefer it over multiple edit calls when a change spans several files or separated regions."
  #:parameters (parameters
    (param "input" (v-string #:description "Patch text: start with *** Begin Patch and end with *** End Patch. Use *** Add File: path with + lines; *** Update File: path, optionally followed by *** Move to: path, with @@ or @@ context and space-prefixed context, + added, or - removed lines; *** End of File anchors the last hunk to the file end. Use *** Delete File: path to delete. Paths are relative to the Session working directory.") #:required? #t)
    escalation-parameters …) …)
```

Rendered text and thrown reports are rule 42.

### `glob` (`tool-fs-search/src/glob.ts:321`)

```racket
(make-tool #:name "glob"
  #:description (format "Find files, not directories, whose paths match a glob pattern, including hidden and ignored files. Returns up to ~a paths in modification-time order; a larger result ~a and reports where the complete list was saved."
                        globMaxResults (if sampleOverCapGlobResults "is sampled across top-level entries" "keeps the first paths"))
  #:parameters (parameters
    (param "pattern" (v-string #:description "Glob pattern to match file paths against (e.g. \"**/*.ts\", \"src/**/*.test.js\"). A pattern with no \"/\" matches the basename at any depth, so \"*\" and \"*.ts\" both search the whole tree; include a separator to anchor the depth.") #:required? #t)
    (param "path" (v-string #:description "Directory to search in. Defaults to the session workspace; a relative path resolves against it.")))
  #:timeout-ms timeoutMs #:concurrency-safe? (lambda (args) #t) …)
```

Validation: `pattern must be a non-empty string` (blank after trimming); `path must be a non-empty string when given`. Rendered text is rule 46.

### `grep` (`tool-fs-search/src/grep.ts:286`)

```racket
(make-tool #:name "grep"
  #:description (format "Search file contents with a ripgrep regular expression. Returns matching lines with line numbers, grouped by file. Returns up to ~a matches; a larger result reports where the complete match list was saved." grepMaxMatches)
  #:parameters (parameters
    (param "pattern" (v-string #:description "Regular expression to search for (ripgrep syntax).") #:required? #t)
    (param "path" (v-string #:description "File or directory to search. Defaults to the session workspace; a relative path resolves against it."))
    (param "include" (v-string #:description "One glob filter for which files to search (e.g. \"*.ts\", \"*.{js,jsx}\"). Not a list; negation is not supported.")))
  #:timeout-ms timeoutMs #:concurrency-safe? (lambda (args) #t) …)
```

Validation, in order: `pattern must be a non-empty string` (the empty string only; whitespace is a valid pattern); `path must be a non-empty string when given`; an `include` that is exactly `""` is treated as omitted; `include must be a non-empty glob when given` (blank); `include must be a positive glob filter; negated patterns ("!…") are not supported`; `include must be one glob, not a comma-separated list (use {a,b} alternation instead)` (a comma outside braces). Rendered text is rule 48. Neither search tool goes through `fs`, the sandbox or approval.

Search errors (`SearchError`; `<tool>` is `glob` or `grep`): `<tool> was aborted before completion (tool timeout or caller cancellation)` (`SEARCH_ABORTED`); `<tool> could not start its search command (ripgrep launch failed)`, `<tool> subprocess failed before reporting an outcome (ripgrep provider failure)`, `<tool> search command was killed by signal <sig>`, `<tool> search failed (exit <n>)` optionally followed by `: <stderr>`, `grep received malformed ripgrep --json output (<detail>)` (`SEARCH_FAILED`); `<tool> pattern rejected by ripgrep: <stderr>` (`SEARCH_INVALID_PATTERN`); `<tool> produced <n> bytes of raw output, over the <cap>-byte cap; narrow pattern, path, or include and retry` (`SEARCH_RAW_OUTPUT_OVERFLOW`).

### `str_replace_editor` (`tool-str-replace-editor/src/index.ts:434`)

```racket
(make-tool #:name "str_replace_editor"
  #:description description                     ; config; the default is DEFAULT_DESCRIPTION at index.ts:20-32, verbatim, trimmed
  #:parameters (parameters
    (param "command" (v-string #:enum '("view" "create" "str_replace" "insert") #:description "The commands to run. Allowed options are: `view`, `create`, `str_replace`, `insert`.") #:required? #t)
    (param "path" (v-string #:description "Absolute path to file or directory, e.g. `/repo/file.py` or `/repo`.") #:required? #t)
    (param "file_text" (v-one-of (v-string) (v-null) #:description FILE-TEXT))
    (param "insert_line" (v-one-of (v-integer) (v-null) #:description INSERT-LINE))
    (param "new_str" (v-one-of (v-string) (v-null) #:description NEW-STR))
    (param "old_str" (v-one-of (v-string) (v-null) #:description OLD-STR))
    (param "view_range" (v-one-of (v-array #:items (v-integer)) (v-null) #:description VIEW-RANGE)))
  #:output (v-string) …)
```

`FILE-TEXT`, `INSERT-LINE`, `NEW-STR`, `OLD-STR` and `VIEW-RANGE` are the five description strings at `index.ts:449-470`, copied verbatim. The value is a string and the whole model-visible text; there is no meta, no session-cwd resolution, no escalation parameter and no remediation. Texts are rules 51 to 57.

### `present` (`deliverables/tool-present/src/index.ts:38`)

```racket
(define-tool present
  #:name "present"
  #:description "Declare existing files as final deliverables for the user. Hosts may show presented files only after your turn ends, so call it once the files are final. If the user needs to review files earlier, such as before a tool call that waits for their answer, link them in your message instead. Use it when the user needs a separate file, especially Office documents, spreadsheets, and slide decks; prefer your final response when that suffices. The user opens the current files; their contents are not copied."
  #:parameters ([files (v-array #:description "Usually the 1-2 most important deliverables; at most 4 per call."
                         #:items (v-object #:additional? #f #:properties (parameters
                           (param "path" (v-string #:description "Path of an existing regular file. Relative paths use the Session working directory.") #:required? #t)
                           (param "description" (v-string #:description "Brief description for the user.")))))
                       #:required])
  #:output PRESENT-OUTPUT-SPEC …)
```

Rendered text: one line `Presented <path>` per file. Errors are rule 75.

### System prompt sections

Registered by the tool plugins in the global layer with `system-prompt-section!`; each text procedure returns `""` unless its tool is visible in the assembling scope (`(tools-lookup tools name scope)`).

| Section | Order name (value) | Text |
|---|---|---|
| `tool:read` | `TOOL_READ` (1100) | `Use the read tool — not shell commands like cat, sed, head, or tail — to inspect text files. Use offset and limit to read a line range or continue a large file.` |
| `tool:write` | `TOOL_WRITE` (1200) | `Read an existing file before overwriting it with write`, then ` and prefer edit for targeted changes` when `edit` is visible, then `.` |
| `tool:edit` | `TOOL_EDIT` (1300) | `Read a file before editing it unless you just created or edited it in this session.` |
| `tool:apply_patch` | `TOOL_APPLY_PATCH` (1350) | the text at `tool-fs/src/apply-patch.ts`, verbatim: `Prefer apply_patch over separate edit calls for changes across files or separated regions. Give every hunk enough surrounding context lines to match one place in the current file. The whole patch is checked first (syntax, hunk matching, missing files) and a rejected patch changes nothing; once applying starts, operations run in order, stop at the first failure, and are not rolled back, so re-read affected files before retrying when needed.` |
| `tool:glob` | `TOOL_GLOB` (1400) | `Use the glob tool — not shell find — to discover files by path pattern.` |
| `tool:grep` | `TOOL_GREP` (1500) | `Use the grep tool — not shell grep or rg — to search file contents.`, then ` Use read on a matched file when you need surrounding context.` when `read` is visible |
| `ui:deliverable-file-references` | `DELIVERABLE_FILE_REFERENCES` | `FILE_REFERENCE_PROMPT` at `deliverables/deliverable-file-references/src/index.ts:8-14`, verbatim; unconditional |

## Plugins

Each plugin's `#:name` is the npm name; `#:meta` records the dsh function-plugin name under `'dsh-name` where dsh has one.

| dsh npm name | Module | Inject | Optional | Provides |
|---|---|---|---|---|
| `@deepseek-ai/dsh-fs-local` | `dsh-fs/plugin/fs-local` | none | none | `fs` |
| `@deepseek-ai/dsh-fs-sandbox` | `dsh-fs/plugin/fs-sandbox` | `sandboxPolicy` | none | `fs` |
| `@deepseek-ai/dsh-fs-observation-policy` | `dsh-fs/plugin/fs-observation-policy` | none | none | none |
| `@deepseek-ai/dsh-tool-fs` | `dsh-fs/plugin/tool-fs` | `tools`, `fs`, `systemPrompt`, `workingDirectory` | `attachments`, `llm`, `sandboxPolicy`, `approval` | none |
| `@deepseek-ai/dsh-tool-fs-search` | `dsh-fs/plugin/tool-fs-search` | `tools`, `systemPrompt`, `subprocess`, `workingDirectory` | `spillStore` | none |
| `@deepseek-ai/dsh-tool-str-replace-editor` | `dsh-fs/plugin/tool-str-replace-editor` | `tools`, `fs` | `sandboxPolicy` | none |
| `@deepseek-ai/dsh-spill-local` | `dsh-fs/plugin/spill-local` | none | none | `spillStore` |
| `@deepseek-ai/dsh-spill-policy` | `dsh-fs/plugin/spill-policy` | `tools` | `llm`, `attachments`, `fs`, `spillStore` | none |
| `@deepseek-ai/dsh-attachment-local` | `dsh-fs/plugin/attachment-local` | none | none | `attachments` |
| `@deepseek-ai/dsh-tool-present` | `dsh-fs/plugin/tool-present` | `tools`, `fs`, `agents`, `workingDirectory` | none | none |
| `@deepseek-ai/dsh-workspace-changes` | `dsh-fs/plugin/workspace-changes` | `subprocess`, `fs` | none | `workspaceChanges` |
| `@deepseek-ai/dsh-deliverable-file-references` | `dsh-fs/plugin/deliverable-file-references` | `systemPrompt` | none | none |
| `@deepseek-ai/dsh-fs-ssh` | `dsh-fs/plugin/fs-ssh` | `ssh`, `sandboxPolicy` | none | `fs` |

Config schemas (field, type, default) and load errors:

- `dsh-fs-local`, `dsh-fs-sandbox`: `cwd` string, the harness working directory (a resolution base, not a containment boundary); `diffBasisMaxBytes` number, `10485760`. Load error: `fs-local: diffBasisMaxBytes must be a positive safe integer no greater than <max>`, where `<max>` is 536870888, the Node limit dsh checks against.
- `dsh-fs-observation-policy`: none.
- `dsh-tool-fs`: `read` boolean `true`; `readImage` boolean `true`; `write` boolean `true`; `edit` boolean `true`; `applyPatch` boolean `false`; `readLimit` number `2000`; `readMaxLineLength` number `2000`; `readMaxBytes` number `51200`; `readStreamMinSize` number `10485760`. Load errors, in that field order: `tool-fs: <name> must be a positive integer`. A confining `fs` without a `sandboxPolicy` service raises `tool-fs: the mounted filesystem confines but ctx.sandboxPolicy is missing` (`tool-fs/src/sandbox.ts:49`).
- `dsh-tool-fs-search`: `sampleOverCapGlobResults` boolean, required, no default; `globMaxResults` `100`; `grepMaxMatches` `250`; `grepMaxLineBytes` `2000`; `searchMetaMaxBytes` `65536`; `rawOutputMaxBytes` `20000000`; `graceMs` `3000` (at most 2147483647); `stderrMaxBytes` `65536`; `timeoutMs` `30000`; `x-racket.rgPath` string, absent. Load errors: `tool-fs-search: <name> must be a positive integer` for each number in that order, then `tool-fs-search: graceMs must be no greater than 2147483647`. A missing `rg` raises at load `tool-fs-search: ripgrep (rg) was not found on PATH; install it or set x-racket.rgPath`.
- `dsh-tool-str-replace-editor`: `maxOutputChars` number `16000` (a positive safe integer); `description` string, the default text. Load errors: `tool-str-replace-editor: maxOutputChars must be a positive safe integer`; `tool-str-replace-editor: description must be non-empty` (blank after trimming); with a confining `fs` and no `sandboxPolicy` service, `tool-str-replace-editor: the mounted filesystem confines but ctx.sandboxPolicy is missing`.
- `dsh-spill-local`: `root` string, absent (a private `dsh-spill-XXXXXX` directory under the system temporary directory, created at first save); `cleanupPeriodDays` integer at least 0, `30` (0 disables the sweep).
- `dsh-spill-policy`: `maxInlineTokens` number, absent. Absent disables the plugin. Load error: `spill-policy: maxInlineTokens must be a non-negative integer (got <n>)`.
- `dsh-attachment-local`: `dshHome` string, absent; `maxImageBytes` `52428800`; `maxImagesPerMessage` `20`; `maxMessageImageBytes` `209715200`; `maxImagePixels` `64000000`; `maxImageDimension` `65535`; `normalizedImageMaxPixels` `4194304`; `normalizedImageMaxDimension` `8192`; `normalizedImageMaxBytes` `4194304`; `imageCompressionConcurrency` `2` (1 to 8); all integers at least 1; `x-racket.imageTool` one of `"auto"`, `"vips"`, `"magick"`, `"none"`, default `"auto"`.
- `dsh-tool-present`: `maxFiles` number `8`. Load error: `present requires a positive integer maxFiles`.
- `dsh-workspace-changes`: `timeoutMs` `30000`; `outputMaxBytes` `8388608`; `maxFiles` `500`; `maxFileBytes` `2097152`; `diffTimeoutMs` `100`; all positive safe integers.
- `dsh-deliverable-file-references`, `dsh-fs-ssh`: none.

Plugin bodies:

- `fs-local`: validate, `(provide-fs ctx (make-local-fs …))`.
- `fs-sandbox`: validate, `(provide-fs ctx (make-sandboxed-fs (make-local-fs …) sandbox-policy-handle))`.
- `fs-observation-policy`: make the gate; register the three intent listeners and the `fs/observed` listener; one effect whose inverse replaces the state table.
- `tool-fs`: validate; `read` when enabled; `read_image` inside `(ctx-inject ctx '(attachments) …)` when enabled; when any of `write`, `edit`, `applyPatch` is enabled build the sandbox controller (rule 30) and register the enabled ones; register each tool's prompt section with its tool.
- `tool-fs-search`: validate, resolve `rg` (rule 85), register `glob` and `grep`, their sections, and the `tools/post-execute` listener of rule 49.
- `tool-str-replace-editor`: validate, register the tool.
- `spill-local`: make the store, start the sweep as a task when `cleanupPeriodDays` is positive, provide; the inverse waits for the sweep.
- `spill-policy`: return at once when `maxInlineTokens` is absent; validate; register the two prepended listeners.
- `attachment-local`: validate, make the store, provide.
- `tool-present`: validate, register the tool and the `tools/result` listener.
- `workspace-changes`: validate, make the recorder table, register the listeners, `(ctx-provide ctx 'workspaceChanges value)`.
- `deliverable-file-references`: register the section.
- `fs-ssh`: `(provide-fs ctx (make-ssh-fs ssh-handle sandbox-policy-handle))`.

```racket
;; dsh-fs/plugins
(define plugin-table
  (list (cons "@deepseek-ai/dsh-fs-local"                      'dsh-fs/plugin/fs-local)
        (cons "@deepseek-ai/dsh-fs-sandbox"                    'dsh-fs/plugin/fs-sandbox)
        (cons "@deepseek-ai/dsh-fs-observation-policy"         'dsh-fs/plugin/fs-observation-policy)
        (cons "@deepseek-ai/dsh-tool-fs"                       'dsh-fs/plugin/tool-fs)
        (cons "@deepseek-ai/dsh-tool-fs-search"                'dsh-fs/plugin/tool-fs-search)
        (cons "@deepseek-ai/dsh-tool-str-replace-editor"       'dsh-fs/plugin/tool-str-replace-editor)
        (cons "@deepseek-ai/dsh-spill-local"                   'dsh-fs/plugin/spill-local)
        (cons "@deepseek-ai/dsh-spill-policy"                  'dsh-fs/plugin/spill-policy)
        (cons "@deepseek-ai/dsh-attachment-local"              'dsh-fs/plugin/attachment-local)
        (cons "@deepseek-ai/dsh-tool-present"                  'dsh-fs/plugin/tool-present)
        (cons "@deepseek-ai/dsh-workspace-changes"             'dsh-fs/plugin/workspace-changes)
        (cons "@deepseek-ai/dsh-deliverable-file-references"   'dsh-fs/plugin/deliverable-file-references)
        (cons "@deepseek-ai/dsh-fs-ssh"                        'dsh-fs/plugin/fs-ssh)))
```

The abstract Service Definition packages (`dsh-fs`, `dsh-spill`, `dsh-attachment`) and the library `dsh-fs-patch` have no row.

## Behaviour

Numbering is for tests. "Raise" without a type means `exn:fail` with the exact message; "raise `CODE` text" means the fs error (or the named error) with that code and message. `<p>` is the target's display path. Handlers that turn a raised value into a result never catch `exn:break`. Counts say their unit: UTF-16 units (`utf16-length`), UTF-8 bytes (`utf8-length`) or code points.

**Local provider** (R8 A, "Local filesystem identities", "Atomic write staging layout"; `fs-local/src/index.ts`, `fsio.ts`)

1. `fs-provider-resolve`: expand a leading `~` or `~/` to the user's home; a path blank after trimming raises `FS_NOT_FOUND` `file_path must be a non-empty string`. The display path is the absolute spelling without symlink resolution: a path with a `..` segment keeps its raw spelling (`<cwd>/<path>` for a relative path) so that traversal resolves physically; any other path is joined to `cwd` and normalised lexically. `cwd` is the argument, else the config `cwd`. The target key is `realpath(3)` of the display path; on `ENOTDIR` raise `FS_NOT_FOUND` `cannot resolve "<p>": a parent path segment is not a directory`; on `ENOENT` walk up to the nearest existing ancestor, take its realpath and append the missing segments. Cancellation before or after raises `FS_ABORTED` `resolve aborted`; the other operations use `stat aborted`, `lstat aborted`, `read aborted`, `write aborted`, `edit aborted`, `delete aborted`, `move aborted`, `list aborted`.
2. Probe: `file-or-directory-stat` following links; `ENOENT` and `ENOTDIR` mean absent. The version is `<device>:<inode>:<size>:<mtime ns>:<ctime ns>` in decimal. `fs-provider-stat` returns `(fs-info version type size)` with `size` only for a file, or `#f`. `fs-provider-lstat` resolves the path's spelling as rule 1 does, does not follow the final link, and reports `'symlink` for a link. After a write whose probe finds nothing the version is `missing:<target key>`.
3. Text reads require a regular file (`cannot read "<p>": not found`, `…: not a regular file`). A NUL byte within the first 8192 bytes raises `FS_NOT_TEXT` `cannot read "<p>": binary file`; bytes that are not valid UTF-8 raise `FS_NOT_TEXT` `cannot read "<p>": invalid UTF-8 text`. Newlines are not normalised. `fs-provider-stream-text` yields chunks with the same two rules applied across chunk boundaries (a chunk never ends inside a character); its `close` releases the file.
4. `fs-provider-read-bytes`: a size above the inclusive cap raises `FS_TOO_LARGE` `cannot read "<p>": <size> bytes exceeds the <cap>-byte limit`; the read takes at most one byte past the cap and raises the growth message of `fsio.ts:416-450` if the file grew. It never truncates. `fs-provider-read-byte-range` returns the bytes of `[offset, offset + length)` and the empty byte string past the end.
5. `fs-provider-list-dir`: a missing target raises `FS_NOT_FOUND` `cannot list "<p>": not found`; a non-directory raises `FS_NOT_DIRECTORY` (message at `fsio.ts:304`). Entries are sorted by name with `string<?` (dsh uses `localeCompare`; Racket design notes). Each child's display path is the parent's display path joined with the name; its target key is its realpath; it is probed following links; a vanished or broken child has type `'other` and no version; `size` only for files.
6. Mutations of one target key run one at a time in arrival order (a keyed lock on the provider value). A move takes its two distinct keys in `string<?` order and releases them in reverse. All file system calls of an operation run under `blocking`; the lock table is touched only from tasks.
7. `fs-provider-write-text`, inside the lock: probe; an existing non-file raises `FS_NOT_REGULAR_FILE` `cannot write "<p>": not a regular file`. Guards: `replace-if-version` on an absent file raises `FS_STALE_VERSION` `cannot write "<p>": file no longer exists`, and on a different version `FS_STALE_VERSION` `cannot write "<p>": file changed since it was read`; `create-if-absent` on an existing file raises `FS_NOT_OBSERVED` `cannot overwrite existing "<p>" without reading it first`. The diff basis `before` is read only when the file exists and the new content's UTF-8 size is below `diffBasisMaxBytes`; it is `#f` for a non-regular file, a size at or above the cap, a size that changed while reading, any NUL byte, invalid UTF-8 or any system error. Then rule 8 with the existing file's permission bits, or none for a new file. The outcome's `after` is the new content with `\r\n` replaced by `\n`; `operation` is `'update` exactly when the file existed.
8. Atomic write (`fsio.ts:604`) for `<dir>/<base>`: create missing parents; create the staging directory `<dir>/.<base>.<harness pid>.<random UUID>.tmpdir` with mode `0700` and in it the file `<base>.tmp` exclusively with mode `0600`; (both modes are set again with `chmod`, so the umask does not widen or narrow them); write; `fsync`; when the target existed, set the file to the target's permission bits (a new file keeps `0600`); close; check cancellation; publish with `link(staged, target)` for `create-if-absent` and with rename otherwise; remove the staging directory (a failure after the commit is ignored). On failure remove the staging directory and raise `FS_PERMISSION_DENIED` for `EACCES` and `EPERM`, else `FS_IO_ERROR`. A failed `link` is classified by an `lstat` of the target: an existing non-file is `FS_NOT_REGULAR_FILE`; an existing file, or `EEXIST`, is `FS_NOT_OBSERVED` with the overwrite message of rule 7; anything else `FS_IO_ERROR`. Writing through a symlink updates its target and never replaces the link. Parent directories are not synced.
9. Edit read (`fsio.ts:759`): any NUL byte in the file raises `FS_NOT_TEXT` `cannot edit "<p>": binary file`; invalid UTF-8 raises `…: invalid UTF-8 text`. `\r\n` becomes `\n`; a lone `\r` is kept. The line-ending style is `CRLF` when, in the first 4096 UTF-16 units of the original, `\r\n` occurs more often than a bare `\n`, else `LF`. Writing back in `CRLF` style replaces every `\n` of the normalised result by `\r\n`.
10. `fs-provider-edit-text`, inside the lock, in this order: a missing file raises `FS_STALE_VERSION` `cannot edit "<p>": file changed since it was read`, with or without a guard; a non-file raises `FS_NOT_REGULAR_FILE` `cannot edit "<p>": not a regular file`; a guard whose version differs raises the same `FS_STALE_VERSION`. Then the literal edit (`fsio.ts:848`): normalise `\r\n` in both strings; an empty old string raises `FS_EDIT_NOT_FOUND` `old_string must be a non-empty string`; count non-overlapping occurrences left to right; none raises `FS_EDIT_NOT_FOUND` `old_string was not found in "<p>"`; more than one without `replace-all?` raises `FS_AMBIGUOUS_EDIT` `old_string matched <n> times in "<p>"; provide a more specific old_string or set replace_all to true`; replace every occurrence. `before` and `after` are the normalised texts. The stale check always precedes matching.
11. `fs-provider-patch-text`: the same existence, type and version checks with the verb `patch`; read as rule 9; `(apply-hunks text hunks)`; a mismatch raises `FS_PATCH_MISMATCH` `cannot patch "<p>": hunk at patch line <n> (<context|oldLines>) does not match` with the hunk line recorded; write back with the original line-ending style.
12. `fs-provider-delete-file`: the same checks with the verb `delete`; capture the bounded `before` basis of rule 7; check cancellation; remove the file (never a directory). A failure raises `cannot delete "<p>": <detail>` with `FS_PERMISSION_DENIED` or `FS_IO_ERROR`.
13. `fs-provider-move-file`: equal keys raise `FS_SAME_TARGET` `cannot move "<p>" to itself`; lock both; check the source as rule 11 with the verb `move` and the destination as rule 7; read the source as rule 9; apply the hunks when given; restore the source's line endings; write the destination atomically with the source's mode; remove the source. After the checkpoint that precedes the destination write both effects run regardless of cancellation. A failed source removal is not raised: the outcome has `source-deleted?` false and `source-failure` `(cons code message)`.
14. `fs-provider-watch`: for a file, `changed` is called when the file changes; for a directory, when a direct entry is added, removed or changed (depth 0). It is built on `filesystem-change-evt`, re-armed after every firing, with a watcher task that calls `changed` with `#f`, or with the exception when the watch fails. A provider without watching raises `FS_IO_ERROR` `Filesystem watching is not supported by this provider.`
15. Pure operations: `process-path` is the target key; `process-path-from-host-path` is `(fs-target-key (resolve host-path))` for an absolute host path and `#f` otherwise; `file-url` is the `file:` URL of the process path with each segment percent-encoded as Node's `pathToFileURL` does; `contains?` is true when the child's key equals the parent's or lies below it, compared by path segments; `sandbox-mode` is `#f`.
16. Any system error that reaches a caller is first passed through `fs-error-from-errno` with the operation's verb.

**Sandbox-aware provider** (R8 B; `fs-sandbox/src/index.ts:156`, `containment.ts`)

17. `(make-sandboxed-fs inner policy-handle)` delegates every operation to `inner`. Its `sandbox-mode` is `(sandbox-policy-default-mode policy-handle)`. Before each mutation: `policy` is the argument, else `(sandbox-policy-resolve policy-handle)` with no session. `danger-full-access` delegates with the caller's target. `read-only` raises `FS_SANDBOX_DENIED` `cannot write "<p>": file access denied under read-only mode`. `workspace-write` resolves the target's display path again (a fresh realpath) and requires the fresh key to be under one of `(writable-roots policy)` by rule 18, else `FS_SANDBOX_DENIED` `cannot write "<p>": file access denied under workspace-write mode`; it then delegates with the fresh target. A move checks the source and the destination. The verb in both messages is always `write`. Reads are never fenced.
18. `(path-under? path root)`: true when `path` equals `root` or starts with `root` followed by a separator; otherwise, if `root` exists, walk from `path` up through its ancestors and return true when one of them exists and has the device and inode of `root`; false at the file system root. A system error other than a missing path raises through rule 16 with the verb `stat`.

**Observation policy** (R8 C; `fs-observation-policy/src/index.ts`)

19. State: a weak table from session object to a table from target key to observation. The owner of an actor is `(agent-session (tool-execution-agent actor))` when the actor is a tool execution with an agent; without an owner nothing is recorded and every target is unseen. `fs/observed` replaces the entry. Decisions:

| Prior state | `fs/write-intent` | `fs/edit-intent`, `fs/delete-intent` |
|---|---|---|
| unseen, or no owner | `(create-if-absent)` | raise `FS_NOT_OBSERVED` `<verb> requires reading "<p>" first`, the verb being `edit` or `delete` |
| absent | `(create-if-absent)` | raise `FS_NOT_FOUND` `cannot <verb> "<p>": not found` |
| present with version `v` | `(replace-if-version v)` | `(version-guard v)` |

20. Authorisation is by freshness: any read, windowed or whole, authorises a later mutation while the version is unchanged, and a successful write or edit records the new version. Disposing the plugin replaces the table. The policy is shipped disabled in the base bundle.

**Intent protocol for producers** (R8 "Cordis events declared in this area")

21. A producer dispatches the intent on its plugin's context with the resolved target and the execution, passes the result as the operation's guard, and after success emits `fs/observed` with `(fs-present new-version)`; a metadata miss emits `(fs-absent)`. A refusal raised by a listener leaves the file untouched.

**Patch parser and applier** (R8 E, "Patch grammar"; `fs-patch/src/parse.ts`, `apply.ts`)

22. `(parse-patch text) -> (listof (or/c patch-add? patch-delete? patch-update?))`. Trim outer Unicode white space (`char-whitespace?`; U+FEFF is not trimmed); split on `\r?\n`; line numbers are 1-based in the original text and count leading blank lines. If the first line is `<<EOF`, `<<'EOF'` or `<<"EOF"`, the last line ends with `EOF` and there are at least four lines, drop both. The first line, trimmed, must be `*** Begin Patch` (`Expected '*** Begin Patch'`) and the last `*** End Patch`. A trailing `\r` is removed from every line but the last. Every failure raises `exn:fail:patch-parse` with the 1-based line; the messages are those of `parse.ts`, verbatim.
23. Body lines: inside an update the header candidate is trimmed on the right only, elsewhere on both sides. `*** End Patch` ends the patch (`Unexpected content after '*** End Patch'` for later non-blank content). `*** Add File: <path>`, `*** Delete File: <path>` and `*** Update File: <path>` start operations; the path is everything after the marker. `*** Environment ID:` before the first operation raises `Environment ID headers are unsupported; the caller selects the filesystem provider`. In an add, a line starting with `+` appends the rest and `\n` to the content. In an update: `*** Move to: <path>` only before the first hunk; `@@` or `@@ <context>` starts a hunk (an empty previous hunk raises `Update hunk must contain context, added, or removed lines`); `*** End of File` marks the previous hunk, after which only blank lines or a new `@@` may follow (`Expected '@@' after '*** End of File'`); a line starting with a space is context (old and new), `+` new, `-` old, and an empty line is an empty context line; any other first character raises `Expected a context (' '), added ('+'), removed ('-') line, or '@@'`; a first body line without `@@` opens an implicit hunk. Anything else raises `Expected an Add File, Delete File, or Update File header; added content must start with +`. An update needs at least one hunk (`Update for '<path>' requires at least one hunk`) and a non-empty last hunk. An empty patch yields `'()`.
24. `(apply-hunks before hunks) -> (or/c string? hunk-mismatch?)` (`apply.ts:65`). Split `before` on `\n` and drop one trailing empty element. Cursor 0. For each hunk: with a context, seek `(list context)` from the cursor (not at end of file); a miss is a mismatch of stage `'context`; a hit moves the cursor past it. With no old lines, insert the new lines at the end of the original (before a final empty line if one remains) and leave the cursor. Otherwise seek the old lines from the cursor with the hunk's end-of-file flag; on a miss, when the pattern ends with an empty line, retry without it (dropping a trailing empty new line as well); a miss is a mismatch of stage `'old-lines` that reports the original pattern; record the replacement and move the cursor past the match. All searches run against the original lines. Apply the replacements sorted by start, stably, from last to first; ensure a final empty element; join with `\n`. Non-empty output always ends with `\n`.
25. Seeking (`apply.ts:37`): an empty pattern matches at the cursor. With the end-of-file flag only the tail position `length - pattern length` is tried, even before the cursor; otherwise positions from the cursor upward. Four passes, each over all candidate positions before the next: exact; trailing white space trimmed; both ends trimmed; both ends trimmed with punctuation folded (U+2010 to U+2015 and U+2212 to `-`; U+2018 to U+201B to `'`; U+201C to U+201F to `"`; U+00A0, U+2002 to U+200A, U+202F, U+205F and U+3000 to a space).

**Line diff** (npm `diff` 9.0.0, `libesm/diff/base.js`, `libesm/diff/line.js`, `libesm/patch/create.js`; R8 D4)

26. Tokens: a text is cut after every `\n`; each token is one line with its terminator (`\n` or `\r\n`), and a final fragment without a terminator is a token without one. The empty text has no tokens. Tokens are equal when they are the same string, so `a` and `a\n` differ.
27. `(diff-lines before after #:timeout-ms [t #f])` returns a list of components `(kind count)` with kind `'common`, `'added` or `'removed`, or `#f` on timeout. It is the greedy forward Myers search as jsdiff runs it. Let `N` and `M` be the token counts. A path is an old position (the index of the last consumed old token, initially -1) and its components; on diagonal `k` the new position is the old position minus `k`. "Follow" means: while the next old and new tokens exist and are equal, consume both, adding the run as one common component. Start with the path at -1 on diagonal 0 and follow; if both texts are consumed, finish. Keep `min-diagonal` at negative infinity and `max-diagonal` at positive infinity. For edit length `d` from 1 to `N + M`, checking the clock once per `d`: for `k` from `max(min-diagonal, -d)` to `min(max-diagonal, d)` in steps of 2: let `remove-path` be the path stored at `k - 1` (clear that slot) and `add-path` the one at `k + 1`; `can-add` holds when `add-path` exists and its old position minus `k` is in `[0, M)`; `can-remove` holds when `remove-path` exists and its old position plus 1 is below `N`; with neither, clear slot `k` and continue; if not `can-remove`, or `can-add` and `remove-path`'s old position is less than `add-path`'s, extend `add-path` by one added token (old position unchanged), else extend `remove-path` by one removed token (old position plus 1); an extension joins a preceding component of the same kind; follow on diagonal `k`; if both texts are consumed, finish with this path; otherwise store it at `k`, lower `max-diagonal` to `k - 1` when the old text is consumed, and raise `min-diagonal` to `k + 1` when the new text is consumed. Components are reported in path order; adjacent added and removed components are not reordered.
28. `(structured-patch before after #:context [context 3] #:timeout-ms [t #f]) -> (or/c (listof diff-hunk?) #f)`. Take the components of rule 27 with their lines (each still carrying its terminator) and append one empty common component. Counters `old-line` and `new-line` start at 1; no range is open. For component `i` of `n`: a changed component, when no range is open, opens one at the two counters and, if a previous component exists, starts its lines with that component's last `context` lines as context lines, moving both starts back by their number; it then appends each of its lines with `+` or `-` and advances `new-line` or `old-line` by its line count. A common component, when a range is open: if it has at most `2 * context` lines and `i < n - 2`, append all its lines as context (the neighbouring changes share one hunk); otherwise append its first `min(lines, context)` lines as context, emit the hunk `(old-start, old-line - old-start + taken, new-start, new-line - new-start + taken, lines)` and close the range. A common component then advances both counters by its line count. Last, in every hunk, a line that ends in `\n` loses it, and a line that does not is followed by the extra line `\ No newline at end of file`. Context lines start with a space.
29. `(compute-hunk-diffs path before after)` (`tool-fs/src/diff.ts:36`): one file diff per hunk of `(structured-patch before after)`. Skip lines starting with `\`; a `-` line goes to the old lines, a `+` line to the new lines, any other to both, each without its first character. The diff is `{path, oldText, newText}` with `oldText` the old lines joined by `\n`, or `null` when there are none, and `newText` the new lines joined by `\n`.

**File tools: shared** (R8 D3, "Model-facing remediation"; `tool-fs/src/sandbox.ts`, `error.ts`, `session-cwd.ts`)

30. Per-call policy of `write`, `edit` and `apply_patch`. At mount: `escalation-modes` is `escalation-targets` when `(fs-sandbox-mode fs)` is not `#f`. Per call: `standing` is `(sandbox-policy-resolve … #:session session)` (no session without an agent), or `#f` on a non-confining backend. If `sandbox_permissions` is given and equals the standing mode, return `standing`. Otherwise treat a blank `justification` without `sandbox_permissions` as omitted and run `validate-escalation-args`. If either field is absent, return `standing`. With no escalation modes raise the tool args error `sandbox_permissions is not available in this composition (no sandboxing filesystem to escalate)`. Otherwise `approve-escalation` with subject `operation`, the tool's name, `(ctx-get ctx 'approval)`, the execution's agent, call id and cancel event, and return `standing` with the approved mode.
31. Remediation applied by the three tools to a provider or intent failure: `FS_SANDBOX_DENIED` becomes the same code with message `(sandbox-denial-marker mode)`, a newline, and `(escalation-hint-marker "operation")`, where `mode` is the call's policy mode; `FS_NOT_OBSERVED` becomes the same code with message `cannot modify "<p>": file has not been read — read the file, then retry`; `FS_STALE_VERSION` keeps its message followed by ` — re-read the file, then retry`. The original is kept as the cause. Other failures pass unchanged.

**`read` and `read_image`** (R8 "`read`", "`read_image`", D1, D2; `tool-fs/src/read.ts`, `read-render.ts`, `read-image.ts`)

32. `read` execution: parse the arguments; resolve; one `fs-stat`; absent: emit `(fs-absent)` and raise not found; a non-file: raise; read through `fs-stream-text` when the size is unknown or at least `readStreamMinSize`, else `fs-read-text`; build the window (rule 33); emit `(fs-present version)` with the version of that one stat; return the value with `path` the process path.
33. `(build-read-window chunks offset limit max-line-length max-bytes display-path)`: scan the chunks splitting on `\n`, removing one trailing `\r` per line, keeping at most `max-line-length + 1` UTF-16 units of the current line in memory, and counting every line; `totalLines` is exact even after a cap. A line is selected when its number is at least `offset`, fewer than `limit` lines are held and the byte cap has not tripped. Selected text longer than `max-line-length` UTF-16 units becomes its first `max-line-length` units followed by `... (line truncated to <max-line-length> chars)`. Its cost is its UTF-8 size plus 1 when it is not the first selected line; if the cost would pass `max-bytes`, mark the window as byte-capped and select nothing further. A final fragment without a newline is a line; a trailing newline adds none. After the scan, `offset > totalLines` raises the out-of-range error unless the byte cap tripped or the file is empty and `offset` is 1.
34. `(format-read-output path offset lines total-lines byte-capped?)`: the envelope under Tools; the body is the lines as `<number>: <text>` joined by `\n`, a blank line, and the footer, or the footer alone with no lines. With `end` the last returned line number, or `offset - 1` with none: `(Output capped. Showing lines <offset>-<end>. Use offset=<end+1> to continue.)` when byte-capped; `(Showing lines <offset>-<end> of <total>. Use offset=<end+1> to continue.)` when more lines exist; `(End of file - total <total> lines)` otherwise. The renderer derives `byte-capped?` from the value alone as "fewer lines than the effective limit and `end` below the total". The meta adds `lang` from `dsh-util`'s extension table when the path has a known extension.
35. `read_image` gates, in order, the first five before any file access: a blank path: tool args error; an extension other than `.png`, `.jpg`, `.jpeg`, `.webp`, `.gif`: `IMAGE_UNSUPPORTED_FORMAT` `cannot read "<path>": the <ext> extension does not declare a supported image format; read_image accepts PNG/JPEG/WebP/GIF files, including extension-less files in those formats`; no attachment store: the tool context unavailable error `cannot read "<path>" as an image: no attachment service is mounted`; a declared media type outside the store's limits: `IMAGE_UNSUPPORTED_FORMAT` `cannot read "<path>": <type> images are not accepted by this deployment`; the route (provider and model from the session's request header config, else the agent options, resolved with `llm-resolve-model-info`): unresolved gives the context unavailable error `cannot read "<path>" as an image: the current model route could not be resolved`, and modalities without `image` give `IMAGE_UNSUPPORTED_MODEL` `cannot read "<path>" as an image: model "<model>" does not declare image input; switch to an image-capable model to read images`. Then resolve and stat as rule 32, and `fs-read-bytes` capped at `min(maxImageBytes, maxMessageImageBytes)`. A file without an extension is identified by signature (the 8-byte PNG magic; `FF D8 FF`; `GIF87a` or `GIF89a`; `RIFF` then four bytes then `WEBP`); unknown raises `IMAGE_UNSUPPORTED_FORMAT` `cannot read "<displayPath>": the file content is not a supported image format; read_image accepts PNG/JPEG/WebP/GIF`.
36. Then `(attachments-save-image … (image-input data media-type (basename display-path)))`. An attachment error keeps its code and gets the message `cannot read "<displayPath>": <detail>` for the codes and details of `saveFailureDetail` (`read-image.ts:224-262`), verbatim; other codes pass unchanged. Emit `(fs-present version)`. The value is `{path, image}`.

**`write`, `edit`, `apply_patch`** (R8 "`write`", "`edit`", "`apply_patch`", D5; `tool-fs/src/{write,edit,apply-patch,apply-patch-output}.ts`, `patch/*`)

37. `write` execution order: rule 30; `fs-resolve`; dispatch `fs/write-intent`; `fs-write-text` with the intent and the policy; a failure of the write goes through rule 31; emit `(fs-present version)`. The value is `{path, operation, before, after}` with `path` the process path.
38. `edit` execution order: rule 30; `fs-resolve`; then, with both steps under rule 31: dispatch `fs/edit-intent` and `fs-edit-text` with `(fs-edit-request old_string new_string replace_all)`; emit `(fs-present version)`. The value is `{path, before, after}`.
39. `apply_patch` plan (`patch/plan.ts`): `parse-patch`; a parse failure raises `PATCH_SYNTAX` `Invalid patch at line <n>: <reason>`. Resolve each operation's path, and `move-to`, against the session cwd, sharing one target value per key; an update with `move-to` is kind `move`. A resolution failure is a refusal of that operation.
40. Preflight (`patch/preflight.ts`), a read-only simulation over a table from target key to `{exists, info, content, touched}` seeded by one stat per target. For each operation in order: a move onto itself: `FS_SAME_TARGET`; for delete and move, `fs-lstat` of the raw source path refuses a symlink with `PATCH_SYMLINK_SOURCE` `cannot <delete|move> "<p>": path is a symbolic link — operate on its target path instead`; intents are dispatched only on the first use of a target in the patch; source: missing is `FS_NOT_FOUND` `cannot <kind> "<p>": not found`, a non-file `FS_NOT_REGULAR_FILE` `cannot modify "<p>": not a regular file`, an intent version unlike the stat version `FS_STALE_VERSION`; destination: `create-if-absent` over an existing file is `FS_NOT_OBSERVED`, `replace-if-version` over an absent file or another version `FS_STALE_VERSION`; content is read with `fs-read-text`, refused with `cannot patch "<p>": binary file` if it holds a NUL, normalised, and patched with `apply-hunks`; a mismatch is `FS_PATCH_MISMATCH` `cannot patch "<p>": hunk at patch line <n> (<stage>) does not match — <first pattern line, at most 80 code points, then … if cut>` with the hunk line. Each admitted operation publishes its simulated result for later ones. Every refusal is collected. Preflight emits no observation and does not simulate sandbox containment.
41. Commit (`patch/execute.ts`): every operation starts `skipped`. For each in order: a ready cancel event sets `cancelled` and stops; stat the targets; dispatch the intents afresh; call `fs-write-text` (add), `fs-patch-text` (update), `fs-delete-file` or `fs-move-file`; emit `(fs-present …)` for written targets and `(fs-absent)` for removed sources; record `changes` with process paths. A move whose source was not removed is `failed` and keeps its destination change. On an fs error: when the provider call had started and the code is `FS_ABORTED`, or the code is `FS_IO_ERROR` and some target's version changed, the status is `unknown` and the message gains ` — re-read the affected files before retrying`; otherwise `failed` without changes. The first operation that is not `completed` stops the loop. Nothing is rolled back. `affectedPaths` are the distinct change paths.
42. Projection (`apply-patch-output.ts`). Raised as error results, nothing having changed: the syntax report of rule 39; refusals as `Patch rejected before any change (<k> problems):` followed by one line `- operation <i+1> (<kind> <path>, patch line <n>): <message>` per refusal (the word is `problems` for any count; `apply-patch-output.ts:55`), with the first refusal's code; and a commit whose first operation failed without a change while every later one was skipped, in the same form. Otherwise the value is returned and rendered: all completed: `Success. No operations in patch.` for none, else `Success. Updated the following files:` and one line per completed operation, adds first, then updates (a move counts as an update at its destination), then deletes, as `A <path>`, `M <path>`, `D <path>`; otherwise `Patch stopped after <completed> of <total> operations.`, then, if any completed, `Completed:` and the same lines, then the sections `Failed:`, `Outcome unknown:` and `Not executed:` with rows `- operation <i+1> (<kind> <path>[ -> <destination>], patch line <n>): <message>` (a failed move that wrote its destination adds a line `  destination <dest> was written; source <path> remains`) and, for skipped ones, `- operation <i+1> (<kind> <path>)`. Meta: `diffs` from the changes of completed and failed operations (`before` null: none; `after` null: `{path, oldText: before, newText: ""}`; else rule 29), and `stopped` true when not all completed.
43. Prompt sections are under Tools; each is registered with its tool and returns `""` when the tool is not visible in the assembling scope.

**Search tools** (R8 F, "`glob`", "`grep`", "Other formats"; `tool-fs-search/src/{search-core,glob,grep,direct-call,presentation}.ts`)

44. Running a search (`search-core.ts:194`): raise the aborted error when the cancel event is ready; the working directory is the session cwd, or the harness working directory without an agent; spawn `(<rg> "--no-config" <args…>)` through `subprocess-spawn` with stdin `'ignore`, stdout `(collect-mode rawOutputMaxBytes #f)`, stderr `(collect-mode stderrMaxBytes #f)`, `graceMs` and the execution's cancel event; check cancellation again after the spawn and after settlement. Exit 0 means results, exit 1 means none; a launch failure, a signal or another exit code is the matching search error, where stderr matching `(?i:regex parse error|error parsing glob)` selects `SEARCH_INVALID_PATTERN`. A lossy stdout read, or more bytes than the cap, is `SEARCH_RAW_OUTPUT_OVERFLOW`.
45. `glob` arguments: `--files`, then the pruning globs, then `--glob=<pattern>`, `--sort=modified`, `--no-ignore`, `--hidden`, then for each of `.git`, `.svn`, `.hg`, `.bzr`, `.jj`, `.sl` the pair `--glob=!**/<name>` and `--glob=!**/<name>/**`, then `--` and the path when one was given. Pruning (`glob.ts:93`): when no path was given and every directory segment of the pattern (all `/`-separated parts but the last) matches `^[\w .-]+$`, is neither `.` nor `..` and is not one of the six names, add `--glob=!**` and `--glob={<unique segments joined by ,>}/`, unless that adds more than 8192 bytes. The value's `paths` are the output lines, relative to the working directory when inside it; `root` is `.` or the path argument made relative.
46. `glob` rendering: `No files found` for none; all paths joined by `\n` when there are at most `globMaxResults`; otherwise the page joined by `\n`, a blank line, and `(Showing <k> of <seen> paths<basis> <recovery>)`. The page is the first `globMaxResults` paths, or with `sampleOverCapGlobResults` the sample of `(sample-across-top-level paths n)`: group the paths by their first segment below the search root in first-seen order, take one path per group per round until `n` are taken, and list them grouped by top-level entry. `<basis>` is `.` for the head page or a sample with a single group, else `, sampled across <shown> of the <total> top-level entries this pattern matched instead of taken in modification-time order.` followed by ` Narrow path to inspect a specific subtree.` when `shown < total`. `<recovery>` is `Full sorted result stored at: <locator>. <retrievalHint>` after a save, else `The complete result could not be saved; narrow pattern or path to see more.` The tool's own `render` (nested calls, replaced decisions) always uses the second form.
47. `grep` arguments: `--json`, `--regexp=<pattern>`, `--glob=<include>` when given, then `--` and the path when given. ripgrep's default ignore and hidden rules apply. Each non-empty stdout line must be a JSON object; records whose `type` is not `match` are skipped; a `match` record must be `{type: "match", data: {path: {text}, line_number, lines: {text} or {bytes}}}`, else the whole search fails with the malformed-output error; the line text loses one trailing `\r?\n`; a `bytes` line is shown as `(line is not valid UTF-8)`.
48. `grep` rendering: `No matches found` for none. Otherwise `Found <n> match` or `Found <n> matches`, or `Found <kept> of <seen> matches` when capped at `grepMaxMatches`; a blank line; then per file in first-seen order the path and one row `Line <n>: <text>` per match, files separated by a blank line; when capped, a blank line and `(<recovery>)` with `Full grep result stored at: <locator>. <retrievalHint>` or `The complete result could not be saved; narrow pattern, path, or include to see more.` Each line preview is cut to `grepMaxLineBytes` UTF-8 bytes on a character boundary and then followed by ` (line truncated)`. The spill content is `Found <n> match|matches`, a blank line and all matches grouped the same way.
49. Spill handoff, in the `tools/post-execute` listener after `(next)` (`direct-call.ts:19`, `glob.ts:372`, `grep.ts:346`): only when the decision is an accept without content or value, the execution has no parent, its name is the tool's name, the result is not an error, `(tools-lookup tools name agent)` is `eq?` to the registered definition, and the result is over its inline cap. Save through `spill-save-text` with source `{kind: "tool", toolName, callId, label: "result"}` and suggested name `glob-results.txt` (all paths joined by `\n`) or `grep-results.txt`; return `(make-post-accept #:content (list (text-block text-with-footer)))`. No session, no backend or a failed save logs a warning and keeps the page with the could-not-save footer.
50. Meta cap (`presentation.ts:107`): drop trailing paths, or trailing file groups, until `(utf8-length (jvalue->string meta))` is at most `searchMetaMaxBytes`, keeping at least one item and setting `truncated` true; `total` is unchanged.

**`str_replace_editor`** (R8 "`str_replace_editor`"; `tool-str-replace-editor/src/index.ts`)

51. A `null` argument is treated as omitted, except `new_str: null` with `str_replace`, which is rejected (message at `index.ts`, verbatim). Path checks, in order: `path must be a non-empty string`; a relative path: ``The path <p> is not an absolute path, it should start with `/`. Maybe you meant /<p>?``; resolution uses `(fs-resolve fs path #:cancel cancel)` with no session cwd; a missing path, after emitting `(fs-absent)`: `FS_NOT_FOUND` `The path <displayPath> does not exist. Please provide a valid path.` (not for `create`); a directory with a command other than `view`: `FS_NOT_REGULAR_FILE` ``The path <displayPath> is a directory and only the `view` command can be used on directories``.
52. `view` of a file: `fs-read-text`, emit `(fs-present version)`, and return `Here's the content of <displayPath> with line numbers (which has a total of <N> lines)`, then ` with view_range=[a, b]` when a range was given, then `:\n`, the lines as the line number right-aligned in six columns, two spaces and the text, joined by `\n`, and a final `\n`. `N` is the number of elements of the content split on `\n`, so a trailing newline yields a last empty line. Range errors are the four strings at `index.ts:157-174`, verbatim: not a list of two integers; first outside `[1, N]`; second above `N`; second below the first unless it is `-1` (to the end).
53. `view` of a directory: list two levels, leaving out names that start with `.`, `node_modules` and `__pycache__`; one row per entry and for the root, `d\t<displayPath>`, `f\t<displayPath>` or `?\t<displayPath>`, sorted by code point of the path; return `Here're the files and directories up to 2 levels deep in <displayPath>, excluding hidden items, node_modules, and Python cache directories:\n`, the rows joined by `\n`, and `\n\n`. A range on a directory raises ``The `view_range` parameter is not allowed when `path` points to a directory.``
54. `create`: `file_text` is required (``Parameter `file_text` is required for command: create``); an existing path raises `FS_ALREADY_EXISTS` ``File already exists at: <displayPath>. Cannot overwrite files using command `create`.``, also when the guarded write reports `FS_NOT_OBSERVED`; write with the intent of `fs/write-intent`, whose innermost step is `(create-if-absent)`; emit the observation; return `New file created successfully at: <displayPath>`.
55. `str_replace`: dispatch `fs/edit-intent` first; require a non-empty `old_str`; stat and read the raw text without line-ending normalisation; no verbatim occurrence raises `FS_EDIT_NOT_FOUND` ``No replacement was performed, old_str `<old>` did not appear verbatim in <displayPath>.``; several raise `FS_AMBIGUOUS_EDIT` ``No replacement was performed. Multiple occurrences of old_str `<old>` in lines [<l1>, <l2>, …]. Please ensure it is unique``; write with `(replace-if-version v)` where `v` is the intent's version, else the stat version; return `The file <displayPath> has been edited successfully.`
56. `insert`: `insert_line` and `new_str` are required; a line outside `[0, N]` raises ``Invalid `insert_line` parameter: <n>. It should be within the range of lines of the file: [0, <N>]``; insert the elements of `new_str` split on `\n` after that line; the same guarded write and success string.
57. Every output longer than `maxOutputChars` UTF-16 units is cut there without splitting a surrogate pair and followed by the clipped note (``<response clipped><NOTE>To save on context only part of this file has been shown to you. You should retry this tool after you have searched inside the file with `grep -n` in order to find the line numbers of what you are looking for.</NOTE>``). A sandbox denial becomes `(sandbox-denial-marker mode)` alone, with the session's standing mode.

**Spill store and spill policy** (R8 L, M, "Spill store layout"; `spill-local/src/{store,cleanup}.ts`, `spill-policy/src/{index,retention,notice}.ts`)

58. `spill-store-save-text` of the local store writes `<root>/session-<first 12 hex digits of sha256(sessionId)>/<12 random hex digits>-<(encode-segment suggestedName)>`: directories `0700`, the file created exclusively with mode `0600`, retrying when the session directory vanished between the two steps. The result is `(spill-ref path (utf8-length content) "Use read with offset/limit, or grep this path to search within it.")`. `(encode-segment s)` keeps `[A-Za-z0-9._-]` and writes every other UTF-16 unit, and `~`, as `~XXXX` (four upper-case hex digits); `""` gives `~`, `.` gives `~002E`, `..` gives `~002E~002E`.
59. Start-up sweep (`cleanup.ts`), once per activation, never raising: the roots are every directory named `dsh-spill-[A-Za-z0-9]{6}` under the system temporary directory (removed when emptied) and the active root (never removed). In each root that is owned by the current user, not writable by group or others and has protected ancestors, and in each of its directories named `session-[0-9a-f]{12}`, delete regular files whose modification time is strictly older than `cleanupPeriodDays` days; skip symlinks and other entries; remove session directories that became empty.
60. Policy eligibility, in the prepended `tools/post-execute` listener after `(next)`: return the decision unchanged unless it is an accept without a value and the tool is not `read`. The content is the decision's content, else the result's. A nested call (the execution has a parent) whose content has no image is left alone. Only content made solely of text and image blocks is eligible. Prices: a text block costs `(estimate-content (list block))`; images are priced together by `(llm-image-request-pricing llm provider model)` applied to the image blocks, each costing `visualTokens` plus the estimate of its `text`; the route is the session's request-header config, else the agent options. A missing calculator, or a result count that differs from the image count, is a failure in the sense of rule 63. A total at most `maxInlineTokens` keeps the content.
61. Saving: a missing session or a missing `spillStore` is a failure. Save the full text (text blocks verbatim; each image as `\n[Image: <path as JSON string>; <mediaType>; <w>x<h>. Use read_image to view it.]\n`, the path from `(resolve-image-access attachments (lambda (p) (fs-process-path-from-host-path fs p)) ref)`, a failure when there is none) with suggested name `<toolName>.txt` and source `{kind: "tool", toolName, callId, label}`, `label` being `result` for a top-level call and `dispatch` for a nested one. The reserve is the price of the gap block `\n\n[...]\n\n` plus the price of `\n\n` followed by the worst-case notice (all text bytes and all images omitted); a worst-case notice that alone costs more than the cap is a failure.
62. `(retain-content blocks budget price)` (`retention.ts:48`), with `budget` `max(0, cap - reserve)`: the head takes `ceil(budget / 2)` and the tail `floor(budget / 2)`. Head: take whole blocks from the front while each fits; a text block that does not fit contributes its longest fitting prefix; an image that does not fit ends the head. Tail: the same from the back with the longest fitting suffix; when it reaches the block the head stopped in and that block is text, it works on the part after the head's prefix. The longest fitting prefix or suffix is found by binary search on the UTF-16 length and never splits a surrogate pair. The result has the head, the tail, the omitted UTF-8 byte count of text and the omitted image count.
63. Result: the notice is `(Omitted <n> bytes.` then ` Omitted <k> images.` when `k > 0`, then ` Full formatted result stored at: <locator>. <retrievalHint>)`. With nothing retained the content is the notice alone; otherwise head, the gap block, tail, and `\n\n` plus the notice, adjacent text blocks merged. Return `(make-post-accept #:content retained #:additional-contexts …)` keeping the decision's contexts; for a nested, non-error call that had images and retains none, add `(make-user-message #:content retained #:source (jobj [kind "ptc-mode"]))`. Any failure logs at `warning` `spill-policy: <(error->js-string failure)>; keeping the inline content` and leaves the decision unchanged. The `tools/ptc-dispatch-log` listener applies the same bounding with label `dispatch` to the content `(next)` returns, using the dispatch's execution, tool name and sub-call id. `(has-spill-notice? text)` implements `hasSpillNotice` (`notice.ts:44-59`).

**Attachments** (R8 N, "Attachment store layout"; `attachment/src/*`, `attachment-local/src/*`)

64. Batch admission (`attachment/src/index.ts:60-110`): more images than `maxImagesPerMessage` raises `TOO_MANY_IMAGES` `Image batch exceeds the configured image-count limit.`; more total bytes than `maxMessageImageBytes` raises `IMAGES_TOO_LARGE` `Image batch exceeds the configured aggregate image-byte limit.`; a media type outside the limits raises `UNSUPPORTED_IMAGE_TYPE` `Image type <type> is not accepted by this deployment.` Every member is then prepared (rules 66 to 69), at most `imageCompressionConcurrency` at a time in arrival order, before any is published.
65. Base64 admission (`admission.ts:16`): a payload must decode and re-encode to exactly itself; an empty image payload raises `INVALID_IMAGE_BASE64`, a malformed file payload `INVALID_FILE_BASE64`, and an empty file payload is accepted. `attachments-admit-prompt-content` replaces each encoded image part by an image block with a durable ref, enforcing the count and aggregate-byte limits over encoded and already stored images together (`attachment/src/index.ts`, `admitPromptContent`).
66. `(probe-image bytes) -> detected-image?` reads headers only and raises `INVALID_IMAGE` `Unsupported or malformed image data.` for anything else. PNG: the signature and `IHDR`; depth `ushort` for bit depth 16, else `uchar`; space `b-w` (8-bit) or `grey16` for colour types 0 and 4, `srgb` or `rgb16` otherwise; alpha for colour types 4 and 6 or a `tRNS` chunk; metadata when a chunk `iCCP`, `eXIf`, `tEXt`, `zTXt` or `iTXt` exists; never animated. JPEG: the first start-of-frame segment gives the size and the component count (1 `b-w`, 3 `srgb`, 4 `cmyk`); metadata when an `APP1` Exif or XMP segment, an `APP2` ICC segment, an `APP13` Photoshop segment or a comment segment exists; an Exif orientation of 5 to 8 swaps width and height. WebP: `VP8 `, `VP8L` or `VP8X` gives the size; alpha from the `VP8X` flag or the `VP8L` header bit; metadata from the `VP8X` flags or `ICCP`, `EXIF`, `XMP ` chunks; animated with more than one `ANMF` chunk. GIF: the logical screen size; animated with more than one image descriptor. It also checks structure: PNG chunk CRCs, a final `IEND` and an `IDAT` stream that inflates to the expected length; a JPEG end-of-image marker; a WebP `RIFF` size that matches the data; a GIF trailer.
67. Prepare (`store.ts:99`): more bytes than `maxImageBytes` raises `IMAGE_TOO_LARGE` `Image exceeds the configured byte limit.`; no bytes raises `INVALID_IMAGE` `Image is empty.`; probe; more pixels than `maxImagePixels` raises `IMAGE_TOO_MANY_PIXELS` `Image exceeds the configured decoded-pixel limit.`; a side above `maxImageDimension` raises `IMAGE_DIMENSION_TOO_LARGE` `Image exceeds the configured per-side pixel limit.`; a detected type unlike the declared one raises `IMAGE_TYPE_MISMATCH` `Declared image type does not match its bytes.`
68. Normalisation (`normalization.ts`). *Pass-through*: the bytes are stored unchanged exactly when the image is not a GIF, is not animated, carries no metadata, has depth `uchar` and space `srgb`, has at most `normalizedImageMaxBytes` bytes and `normalizedImageMaxPixels` pixels, and its long edge is at most `normalizedImageMaxDimension`. This is dsh's rule, so such an image has the same attachment id in both implementations. *Re-encoding* needs the image tool selected by `x-racket.imageTool` (`auto`: the first of `vips`, `magick`, `convert` found on `PATH`). The target size is `(request-image-dimensions w h maxPixels)`, scaled again by `maxDimension / long edge` with each side floored and at least 1 when the long edge still exceeds `maxDimension`. The tool is asked, through `subprocess-spawn` with the input on a private temporary file, to apply the Exif orientation, convert to sRGB, resize to fit inside the target without enlarging, drop all metadata, keep only the first frame, and encode as WebP (effort 0) when the source has alpha, else JPEG, at qualities 85, 75 and 60 in turn; the first output within `maxBytes` wins, else the smallest. Reference command lines: `vips thumbnail <in> <out>[Q=<q>,strip] <width> --height <height> --size down --export-profile srgb`, and `magick <in>[0] -auto-orient -colorspace sRGB -resize <w>x<h>> -strip -quality <q> <out>` (with `-define webp:method=0` for WebP). The output is probed and must have the expected type and size, one frame, no metadata, depth `uchar`, space `srgb` and compatible alpha (equal, or a WebP that lost an all-opaque alpha channel; not checked for a GIF source), else `ATTACHMENT_WRITE_FAILED` `Image normalization did not produce a single-frame 8-bit sRGB image with matching metadata.` A missing tool or a failing run raises `ATTACHMENT_WRITE_FAILED` `The <source> could not be converted to the normalized 8-bit sRGB form.`, where `<source>` is `16-bit PNG` (or `<depth> PNG`) for a PNG whose depth is not `uchar` and `<depth> <FORMAT>` otherwise, as in dsh; the cause is logged once at `warning` with the tool that was looked for. Differences from sharp: re-encoded bytes, and therefore the attachment ids of images that needed re-encoding, differ from dsh's; without a tool such images are refused where dsh converts them; admission does not decode the full raster, so a file with sound structure and corrupt compressed data passes on the pass-through path; resampling and encoder settings are the tool's.
69. Reference (`store.ts`): `attachmentId` is `sha256:` and the hex digest of the stored bytes; `name` is the caller's name cut to its leaf (after the last `/` or `\`), with control characters removed, trimmed, cut to 255 UTF-16 units and omitted when empty; `originalDimensions` is present only when normalisation changed the size. The ref's `mediaType`, `bytes`, `width` and `height` describe the stored bytes.
70. Publication (`store.ts:214-388`) under `<Harness home>/attachments/v1`: images at `objects/<first 2 hex>/<64 hex>`; staging at `tmp/<random UUID>` created exclusively with mode `0600`. Once per process make the Harness home and its ancestors durable (create with mode `0700`, `fsync` each parent). Write the staged file, `fsync`, close, verify its digest (`ATTACHMENT_CORRUPT` `Attachment bytes do not match their publication digest.`), `link(staged, target)`; on `EEXIST` verify the existing object's digest (`ATTACHMENT_CORRUPT` `Stored attachment failed integrity verification.`); remove the staging name; set mode `0400`; `fsync` each directory from the target's parent up to the root. Any other failure raises `ATTACHMENT_WRITE_FAILED` `Unable to persist attachment.`
71. `store-read-image`: an invalid id raises `INVALID_ATTACHMENT_REF` `Attachment reference is invalid.`; a missing object `ATTACHMENT_NOT_FOUND` `Attachment object is missing.`; another I/O failure `ATTACHMENT_READ_FAILED` `Unable to read image attachment.`; a digest mismatch `ATTACHMENT_CORRUPT` `Stored attachment failed integrity verification.`; a probe whose media type, byte length, width or height differs from the ref `ATTACHMENT_CORRUPT` `Stored attachment metadata does not match its reference.` `store-image-host-path` is the object's path, or `#f` for an invalid ref.
72. Files (`file-store.ts`): no limits and no normalisation. The canonical object is `file-objects/<2 hex>/<64 hex>` and each name gets a hard-link alias `files/<2 hex>/<64 hex>/<leaf>`. The leaf is the name cut to its leaf, with control characters removed, each of `<>:"|?*` replaced by `_`, trimmed, trailing dots and spaces removed, `_` prefixed to the Windows device names (`con`, `prn`, `aux`, `nul`, `com1` to `com9`, `lpt1` to `lpt9`, any case), cut to 255 UTF-8 bytes on a character boundary, and `file` when empty. A ref whose `name` is not already in this form is invalid (`File attachment reference is invalid.`). Reads stream in 64 KiB chunks and verify the byte count and digest after the last chunk (`Stored file attachment failed integrity verification.`).
73. Request images (`request-image.ts`, `index.ts:260`): the variant id is `sha256:` and the digest of the JSON text `{"transformVersion":"request-image-v6","attachmentId":…,"targetWidth":…,"targetHeight":…,"encodedByteBudget":…,"encoding":{"webpQualities":[85,75,60],"webpEffort":0,"jpegQualities":[85,75,60],"order":["alpha:webp","opaque:jpeg"],"colourspace":"srgb"}}` with exactly that key order; non-positive or non-integer targets raise `INVALID_ATTACHMENT_REF` `<name> must be a positive integer.` Concurrent requests for one variant share one computation, cancelled only when every waiter cancelled. A cached file at `<Harness home>/cache/attachments/request-images/<2 hex>/<variant hex>` is used when it is 8-bit sRGB, within the target size and of compatible alpha. Otherwise, when the target is at least the stored size and the stored bytes fit `maxBytes`, the stored bytes are returned unchanged. Otherwise the image tool resizes by the long edge (`long-edge-dimensions`, never enlarging) with the same quality ladder and verification, and the result is written to the cache through a temporary file and a rename. Without a tool that last case raises `ATTACHMENT_PROJECTION_UNSUPPORTED`.
74. Ports: for `gen:attachment-port`, `attachment-image-host-path` is `store-image-host-path`, `attachment-file-host-path` is `store-file-host-path`, and `attachment-read-image-request` is `store-read-image-request` with the target's `width`, `height` and `maxBytes`.

**Deliverables** (R8 O, "Workspace-changes git commands"; `tool-present/src/index.ts`, `workspace-changes/src/*`)

75. `present` execution, in order: no agent raises the context unavailable error `present requires an agent Session`; `(agents-turn-boundary-of agents session)` with `openTurnStartSeq` null raises `present requires an open turn`; no file or more than `maxFiles` raises the tool args error `present accepts 1 to <maxFiles> files`; for each file: a blank path raises `present requires a non-empty file path`; `fs-lstat` in the session cwd, and a present entry that is not a file (a symlink included) raises `FS_NOT_REGULAR_FILE` `Cannot present <path>: not a regular file`; resolve and stat; absent raises `FS_NOT_FOUND` `Cannot present <path>: file not found. Check the path, create the file if needed, and retry.`; a non-file raises the not-a-regular-file error; the stored file is the argument object with `path` replaced in place by the process path (`jset`). Check cancellation; remember the delivery under the execution; return `{turn: lastTurn, files}`.
76. On `tools/result` for that execution, when the result is not an error, append `(deliverables/presented #:turn turn #:call-id call-id #:files files)` to the session; in every case forget the delivery. Pending deliveries are kept in a weak table keyed by the execution.
77. Workspace changes, eligibility and order (`recorder.ts`): a session is recorded when its header has a `cwd`, its `origin` is not `subagent` and its `delegationDepth` is absent or 0. Each session has one task queue; every step below runs on it in arrival order, and `tools/pre-execute` waits for the queue before the tool runs. Any failure only logs a warning.
78. Snapshots: on `turn/start`, locate the repository once with `git rev-parse --show-toplevel --absolute-git-dir --git-path objects` (not a repository: no snapshots), then snapshot the work tree as a tree object through a private index and object directory: `git add --all --ignore-errors` (with the exclusions of `git.ts`) and `git write-tree`, with `GIT_INDEX_FILE=<scratch>/index`, `GIT_OBJECT_DIRECTORY=<scratch>/objects` and `GIT_ALTERNATE_OBJECT_DIRECTORIES=<repository objects>`. Every git command runs through `subprocess-spawn` with `GIT_CONFIG_COUNT=0`, `GIT_TERMINAL_PROMPT=0`, `GIT_OPTIONAL_LOCKS=0`, `LC_ALL=C`, the timeout `timeoutMs` and the output cap `outputMaxBytes`. The scratch directory is `dsh-workspace-changes-XXXXXX` under the system temporary directory. The repository's own index, objects and refs are never written.
79. Captures: each `fs/*-intent` of a tool call of a recorded session, after `(next)`, copies the target file's current bytes once per turn into `captures/<sha1 of content>`, or records `absent`, or `oversized` above `maxFileBytes`.
80. Recording: on `agent/turn-stopping`, and on `turn/end` when a tool result arrived after the last record, if the turn had at least one tool result: snapshot again; `git diff-tree -r -M -z --numstat <before> <after>`, parsed by `numstat.ts` (renames, binary files); add captured paths the snapshots do not cover (ignored files, files outside the repository unless under a temporary root, everything without a repository, never paths inside gitlinks) whose content changed, with counts from `compare-text`; sort by `display`; when the list is not empty, or a record already exists for the turn, append `(workspace/changes #:turn turn)` and store the summary, capped at `maxFiles` entries with uncapped totals, under the event's seq. `session/disposed` drops the recorder and its scratch directory.
81. `workspace-changes-diff` reads both sides (a git blob through `git ls-tree -z -l <tree> -- <path>` with `GIT_LITERAL_PATHSPECS=1` and `git cat-file blob <oid>`, or the capture file) and returns `(compare-text before after diffTimeoutMs)`: each side gets a final `\n` when it is not empty and lacks one; the hunks are `(structured-patch … #:context 3 #:timeout-ms t)`; on timeout the result is one hunk that removes every old line and adds every new line, with `coarse` true. `added` and `deleted` count the `+` and `-` lines.
82. `deliverable-file-references` registers its one section (Tools).

**Filesystem over SSH** (`ssh/fs-ssh/src/index.ts`)

83. `(make-ssh-fs ssh policy-handle)`: `sandbox-mode` is the policy service's default mode; `process-path` is the target key; `file-url` and `contains?` as rule 15 with POSIX paths; `process-path-from-host-path` is `#f`. Each other operation is one `ssh-request`: `fs.resolve {path, cwd}`, `fs.stat {target}`, `fs.lstat {path, cwd}`, `fs.readText {target}`, `fs.stream {target}` then `fs.next {id}` until `done` (and `fs.streamClose {id}` when the stream is closed early), `fs.readBytes {target, maxBytes}` and `fs.readRange {target, offset, length}` (base64 replies), `fs.list {target}`, `fs.write {target, content, expected, policy}`, `fs.edit {target, edit, expected, policy}`, `fs.patch {target, hunks, expected, policy}`, `fs.delete {target, expected, policy}`, `fs.move {source, destination, options, policy}`, where `policy` is the argument or `(sandbox-policy-resolve policy-handle)` and absent optional members are omitted. A remote failure whose code is an fs error code becomes that fs error with the remote message; any other failure becomes `FS_ABORTED` when the caller's cancel event is ready and `FS_IO_ERROR` otherwise.

**Utilities this package relies on** (`packages/util/{output-retention,ripgrep}/src/index.ts`)

84. Output retention: an item retainer keeps the first `n` items and reports the exact omitted count; a text retainer keeps a head, a tail, or both within byte budgets, trims a cut head back to a whole UTF-8 sequence and a cut tail forward past continuation bytes, and reports the omitted bytes from what it returned. `(describe-omitted omitted unit)` is `Omitted <n> <unit>.` for an exact count, `More <unit> were omitted.` for an unknown one and `""` for none.
85. ripgrep: the program is `x-racket.rgPath` when set, else `(subprocess-resolve-executable subprocess "rg")`, resolved once at mount; every invocation starts with `--no-config`.

## Racket design notes

- **`gen:fs-provider` with three providers.** Local, sandbox-aware and SSH. The sandbox-aware provider wraps any provider instead of subclassing the local one: the fence is one function applied before each mutation (rule 17), and the wrapper also works over a future provider.
- **Structs inside, jobjects at the edges.** Targets, intents and outcomes never leave the process except over SSH, so they are transparent structs that `match` can take apart; tool values, meta, refs and summaries are logged or sent to clients, so they are jobjects in dsh key order. JavaScript `undefined` and `null` in the structs are both `#f`.
- **Text streams are pull procedures.** `streamText` returns an async iterable; `text-stream` is a `next` thunk and a `close` thunk, which a `for` loop over `in-producer` consumes and which the read window drives without buffering the file.
- **A keyed lock in place of promise chains.** The per-target mutex is a table of FIFO waiters touched only from tasks; file system calls run under `blocking`, so a large write does not hold the baton.
- **FFI only where Racket has no primitive.** `link(2)` for publication that never replaces (`create-if-absent`, attachments), `fsync(2)` for durability, `realpath(3)` for identity. Everything else uses `racket/file` and `file-or-directory-stat`, which supplies device, inode and nanosecond times for the version.
- **Listing order.** `fs-provider-list-dir` sorts with `string<?`; dsh's `localeCompare` order depends on the ICU locale of the Node build. The model sees directory listings only through `str_replace_editor`, which sorts by code point in dsh as well.
- **The diff is a port, not a new algorithm.** Rules 26 to 29 transcribe jsdiff 9.0.0, including its diagonal pruning and its tie-break (a removal before an insertion when both reach equally far), because the hunks are persisted in `tool/result` meta and compared by recorded snapshots. The implementation should be an imperative loop over a mutable vector of paths; clarity matters less here than equality with the original.
- **Pure renderers are exported.** `build-read-window`, `format-read-output`, `render-patch-report`, the search renderers, `retain-content` and `format-spill-notice` are pure functions with their own tests, separate from the tool bodies that do I/O.
- **Observation state is a weak table on the plugin's gate value**, keyed by the session object, as dsh's `WeakMap`. A policy refusal is a plain raise from the listener; dsh wraps it in a promise so that it rejects asynchronously, which has no counterpart under tasks.
- **Images.** sharp is a native Node module and cannot be a dependency (ADR 0009). The split of rule 68 keeps everything that can be byte-identical (pass-through, ids, layout, verification) native and isolates the one lossy step behind an optional program, checked by the same output verification dsh applies.
- **No new macro.** The package uses `define-service`, `define-event`, `define-session-event`, `define-plugin`, `define-tool` and `make-tool`. Tools whose parameter list or description is computed from config use `make-tool`.
- **Racket-only additions**, for the coordinator's ADR list: the config keys `x-racket.rgPath` (tool-fs-search) and `x-racket.imageTool` (attachment-local); `exn:fail:errno`; `text-stream`; the structural checks of `probe-image`; `dsh-fs/ssh` living in this package. Deviations from dsh: listing order (rule 5), image re-encoding (rule 68), request images without a tool (rule 73).

## Work units

The package is split into three units. The interface between them is the set of public module exports in this document.

| Unit | Modules | Depends on |
|---|---|---|
| 1: filesystem core | `errors`, `fs`, `local` with `private/{posix,fsio,keyed-lock}`, `sandbox`, `observation-policy`, `patch`, `diff`, `ssh`, the plugins `fs-local`, `fs-sandbox`, `fs-observation-policy`, `fs-ssh`, and their tests | wave 3; `dsh-exec/sandbox`, `dsh-exec/sandbox/policy`, `dsh-exec/ssh` |
| 2: file tools | `tool/common`, `tool/read`, `tool/read-image`, `tool/write`, `tool/edit`, `tool/apply-patch`, `tool/search`, `tool/str-replace-editor`, the plugins `tool-fs`, `tool-fs-search`, `tool-str-replace-editor`, and their tests | unit 1; `dsh-fs/spill` and `dsh-fs/attachment` (interfaces only); `dsh-exec/subprocess`, `dsh-exec/ports` |
| 3: spill, attachments, deliverables | `spill`, `spill/local`, `spill/policy`, `attachment`, `attachment/probe`, `attachment/local`, `tool/present`, `workspace-changes`, their plugins, `plugins`, `main`, and their tests | unit 1 (`fs`, `diff`); `dsh-exec/subprocess` |

Build order: unit 1 first delivers `errors`, `fs` (data, generics, events), `patch` and `diff`, which have no dependency on a provider; unit 3 first delivers the interface halves of `spill` and `attachment` (the service definitions, generics and data under Data). Units 2 and 3 then proceed in parallel against those. `dsh-fs/ssh` is built last in unit 1 because it waits for `dsh-exec/ssh`.

## Tests

Tests live in `racket/dsh-fs/tests/`. Rows name the TypeScript suite to mirror and what it pins. Every test works in a temporary directory it creates and removes. A test that relies on a permission refusal is skipped with a printed reason when the user id is 0.

| Racket test file | Mirrors | Pins |
|---|---|---|
| `errno-test.rkt`, `fs-service-test.rkt` | `packages/fs/fs/tests/errno.spec.ts`, `service.spec.ts` | the errno table; the waterfall defaults and single-slot rule of rule 21 |
| `local-test.rkt` | `packages/fs/fs-local/tests/fsio.spec.ts`, `filesystem.spec.ts`, `patch-mutations.spec.ts`, `watch.spec.ts` | rules 1 to 16: identity across symlinks and missing suffixes, versions, binary and UTF-8 refusal, CRLF round trip, staging names, guarded create through `link`, stale and not-observed errors, lock order with two concurrent guarded writes, diff-basis bounds, delete and move outcomes |
| `sandbox-fs-test.rkt` | `packages/fs/fs-sandbox/tests/fs-sandbox.spec.ts`, `containment.spec.ts` | rules 17, 18: the mode fence, fresh resolution against a swapped symlink, temporary roots, alias containment |
| `observation-policy-test.rkt` | `packages/fs/fs-observation-policy/tests/policy.spec.ts` | rules 19, 20; disposal resets the state |
| `patch-test.rkt` | `packages/fs/fs-patch/tests/parse.spec.ts`, `apply.spec.ts` | rules 22 to 25, every diagnostic with its line number |
| `diff-test.rkt` | `packages/fs/tool-fs/tests/diff.spec.ts`, `packages/deliverables/workspace-changes/tests/compare.spec.ts` | rules 26 to 29 and 81 against a checked-in table of at least 40 `(before, after, hunks)` cases produced once with npm `diff` 9.0.0, stored with the script that produced them |
| `read-test.rkt` | `packages/fs/tool-fs/tests/read-render.spec.ts`, the read cases of `tools.spec.ts` | rules 32 to 34: windows, footers, line and byte caps with astral characters, offset errors |
| `read-image-test.rkt` | `packages/fs/tool-fs/tests/read-image.spec.ts` | rules 35, 36: gate order, sniffing, the downscale advice text |
| `write-edit-test.rkt` | `packages/fs/tool-fs/tests/tools.spec.ts`, `integration.spec.ts`, `error.spec.ts` | rules 30, 31, 37, 38, 43: envelopes, meta diffs, remediation texts, escalation with a scripted approver, schema variants |
| `apply-patch-test.rkt` | `packages/fs/tool-fs/tests/apply-patch.spec.ts`, `tests/patch/{resolution,preflight,commit,success}.spec.ts` | rules 39 to 42: refusal aggregation, partial commit rendering, unknown outcomes, symlink refusal |
| `search-test.rkt` | `packages/fs/tool-fs-search/tests/tools.spec.ts`, `integration.spec.ts`, `presentation.spec.ts`, `packages/util/ripgrep/tests/*.spec.ts` | rules 44 to 50 and 85: argv builders, include validation, sampling, footers, the handoff conditions, the meta cap, error classification; runs `rg`, which this machine has |
| `str-replace-editor-test.rkt` | `packages/fs/tool-str-replace-editor/tests/tools.spec.ts` | rules 51 to 57, every string |
| `spill-test.rkt` | `packages/spill/spill-local/tests/spill-local.spec.ts`, `packages/spill/spill-policy/tests/{retention,notice,spill-policy,multimodal,multimodal-recovery}.spec.ts`, `packages/util/output-retention/tests/output-retention.spec.ts` | rules 58 to 63 and 84 with a scripted price function |
| `attachment-test.rkt` | `packages/attachment/attachment/tests/*.spec.ts`, `packages/attachment/attachment-local/tests/{store,file-store,index}.spec.ts` | rules 64, 65, 69 to 72, 74: limits and codes, canonical base64, layout, deduplication, integrity |
| `image-test.rkt` | `packages/attachment/attachment-local/tests/{image,normalization,request-image}.spec.ts` | rules 66 to 68 and 73: the probe on small fixtures of each format and variant; pass-through identity; the variant id against the values in `request-image.spec.ts`; re-encoding with `convert` when present, else a skip with a printed reason |
| `present-test.rkt`, `workspace-changes-test.rkt` | `packages/deliverables/tool-present/tests/present.spec.ts`, `packages/deliverables/workspace-changes/tests/{git,numstat,capture,compare,paths,plugin}.spec.ts`, `packages/deliverables/deliverable-file-references/tests/prompt.spec.ts` | rules 75 to 82; uses the system `git` in a temporary repository |
| `fs-ssh-test.rkt` | `packages/ssh/fs-ssh/tests/provider.spec.ts` | rule 83 against an in-process `rpc-peer` |
| `plugins-test.rkt` | config cases across the suites above | every load error under Plugins; each registration test disposes the fiber and observes the removal |

Fixtures: image files of a few hundred bytes for each case of rule 66 (8-bit RGB PNG, RGBA PNG, 16-bit PNG, grey PNG, PNG with a text chunk, baseline JPEG, JPEG with Exif orientation 6, lossy, lossless and extended WebP, animated GIF), checked in as bytes. Key-order fixtures: the seven schemas named under Tools. Recorded sessions under `snapshots/session/` whose `tool/result` text and meta this package produces: `fs-read`, `fs-read-window`, `fs-write`, `fs-write-overwrite`, `fs-write-overwrite-bounded`, `fs-edit`, `fs-delete-recreate`, `fs-policy-reject`, `fs-same-mode-empty-justification`, `fs-glob-sampling`, `apply-patch-update`, `apply-patch-partial`, `apply-patch-rejected`, `read-image`, `read-image-attachment-path`, `read-image-dimension`, `read-image-gif`, `read-image-reencode`, `read-image-text-route`, `multimodal-spill-ends`, `multimodal-spill-middle`, `bash-spill`, `session-reference-spill`, `workspace-edit`. Their full replay needs the profiles of `dsh-boot`. In this wave a *tool-result parity test* runs for `fs-read`, `fs-read-window`, `fs-write`, `fs-write-overwrite`, `fs-edit`, `fs-delete-recreate`, `apply-patch-update`, `apply-patch-partial` and `apply-patch-rejected`: copy the scenario's `workspace` directory, when it has one, to a temporary directory that a scripted working-directory port returns; apply the workspace setup its `snapshot.yml` names (`apply-patch-partial` uses `readonly-patch-directory`: a directory `locked` with mode `0555`; the scenario is skipped when the tests run as root, as `snapshots/session/headless.snapshot.ts:1356` skips it, and this machine runs as root); take each `tool/call` of these tools from `session.v4.jsonl`, run it through `execute-model-tool-fixture`, replace the temporary directory by `{{cwd}}`, and require the content text and the `meta` (hunk diffs included) to equal the recorded `tool/result`, and the directory to equal `workspace.expected` at the end. The `read-image-gif` and `read-image-reencode` scenarios record ids of sharp output and are expected to differ (rule 68); they are listed in the parity table as deviations.

Acceptance gate: `raco test racket/dsh-fs` passes with no network and no `node`; every numbered rule has a test that names it or a stated skip reason; the key-order fixtures and the parity test pass; the diff table passes; one scripted session through the mock provider writes a file with `write`, edits it with `edit`, and logs two `tool/result` events whose meta `diffs` are `[]` and one hunk.

## Open questions

1. **`dsh-util` names.** Assumed: `exn:fail:harness` with name and code; the Harness home resolver; `lang-from-path` (the extension table of `code-language`); `text-retainer`, `item-retainer`, `describe-omitted` (`output-retention`); `relativize-to-cwd` (`workspace-path`). Recommended default: use them when they exist; otherwise implement privately from rules 84 and 85 and the TypeScript, and report it.
2. **Ports of sibling packages.** `workingDirectory` is read through `gen:working-directory-port` of `dsh-exec/ports`; `approval` through `gen:tool-approval`; `agents` and `llm` directly from wave 3. Recommended default: as in [dsh-exec.md](dsh-exec.md), open question 1.
3. **The `tools/ptc-dispatch-log` payload.** The listener of rule 63 needs the execution, the tool name and the sub-call id of a dispatch that `dsh-ptc` owns. Recommended default: the payload is readable with `jref` under the keys `exec`, `name` and `subCallId`, as every `agent/*` payload is; the listener is registered by name so this package does not require `dsh-ptc`.
4. **Image tool.** The two reference command lines of rule 68 were not run here (`vips` is absent; ImageMagick 6 `convert` is present). Recommended default: implement both adapters, rely on the output verification to catch a wrong option, and prefer `vips` because sharp is built on the same library.
5. **Sharing the request-image cache with dsh.** A cache file written by one implementation is accepted by the other when it passes verification, although the bytes differ. Recommended default: share it; the alternative is a Racket-specific `transformVersion`, which would make the two disagree on variant ids.
6. **Full decode on admission.** Rule 66 checks structure where sharp decodes the raster. Recommended default: as specified; when an image tool is configured an implementer may add a decode pass behind it later.
7. **`watch`.** `filesystem-change-evt` on Linux reports a change of the watched path itself; whether it reports changes of entries below a directory exactly as chokidar at depth 0 is unverified. Recommended default: for a directory, also compare a listing snapshot after each firing, and poll every second where the platform lacks change events.
8. **Listing order** (rule 5). Recommended default: code point order, recorded as a deviation.
9. **Home expansion** (rule 1) uses the home directory of the harness user (`find-system-path 'home-dir`). Recommended default: as specified; the SSH provider leaves `~` to the helper.
10. **`fsync` cost.** Publication of an attachment syncs each directory up to the store root. Recommended default: keep it, under `blocking`.
