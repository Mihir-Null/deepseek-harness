# Racket port: coding conventions

Every agent that writes code under `racket/` follows these rules. They are short on purpose; the interface contract of each package under `docs/racket/contracts/` is the detailed specification.

## Layout

- One Racket package per directory under `racket/`. Each has `info.rkt`, source modules, a `tests/` directory and a `README.md` that says what the package is, how to run its tests, and which dsh packages it corresponds to.
- Public modules sit at the top of the collection; internal modules under `private/`. Other packages never require a `private/` module unless a contract names it.
- A package edits only its own directory. A defect in another package is reported to the coordinator (in the agent's final report), not patched in place, unless the task says otherwise.
- Build products (`compiled/`) are ignored by git.

## Language and style

- `#lang racket/base` with explicit `require`s. Use `racket/match`, `racket/list`, `racket/string`, `racket/contract` and similar as needed; avoid `#lang racket` in library modules.
- Public modules export through `(provide (contract-out ...))`. Contracts state the real precondition; prefer specific predicates to `any/c`. Macros use `syntax/parse` and report errors that name the clause at fault.
- Kebab-case names, `?` for predicates, `!` for mutators, `->` in converters, `current-` for parameters, `exn:fail:...` for exception structs.
- Structs are opaque by default; add `#:transparent` only for plain data that tests compare.
- Lines are at most 100 columns. Files end with exactly one newline. ASCII only in code, except inside strings copied from dsh.
- Every module starts with a comment that states what it provides and its non-obvious contract. Every exported binding has a one- or two-line comment unless its contract and name say everything. Comments state behaviour, failure, ownership and timing; they do not narrate the code or its history.
- Do not write the word formed by joining "prove" and "nance" anywhere; the repository bans it.

## Kernel discipline

- Every registration is an effect: it goes through `ctx-effect`, `ctx-on`, `ctx-provide`, or a service procedure that does so on the caller's context, and it returns its disposer.
- Ownership follows the first argument (ADR 0003): a service procedure takes a context or a service handle, and registers on `(use-context x)`.
- Harness state is touched only from tasks. Anything that waits uses `await`; pure I/O that touches no harness state may run under `blocking`. Never call `sleep`, `sync`, `thread-wait`, blocking port reads or `subprocess-wait` directly from a task.
- Cancellation is a break. Code that must clean up uses `dynamic-wind` or `with-handlers` for `exn:break?` and re-raises.
- No module-level mutable state that outlives a context. State hangs off a service value created in a plugin body.
- Waterfall listeners call `next` to delegate; returning without calling it short-circuits on purpose.

## Compatibility with dsh

- Tool names, tool descriptions, JSON schemas, prompt text, event names, session-log field names, CLI flags, config keys and error strings that a model, a user or a file can observe are copied from the TypeScript source verbatim. Put a comment `; source: packages/<group>/<pkg>/src/<file>` next to each copied block.
- JSON values are jvalues from `cordis-data` (ADR 0006): `jobject`s that keep key order, lists, strings, numbers, booleans and `'null`. Read and write JSON text with `cordis-data`, never `racket/json`. Build objects with `jobject` or `jobj` in the key order dsh uses. Count lengths with the unit the dsh source uses (`utf16-length`, `utf8-length` or `code-point-length`).
- Anything model-visible must be reconstructable from the session log. A new model-visible input needs a session event.
- A Racket-only extension uses the config key namespace `x-racket` or a plugin name starting with `racket:` and is recorded in an ADR. It must not change behaviour of an unmodified dsh configuration.

## Errors

- Coded, expected failures raise `exn:fail:harness` (from `dsh-util`) with a stable `code`. Tool failures become tool results through the tool pipeline, never uncaught exceptions.
- Misconfiguration fails at load with a message that names the plugin and the field.
- A handler that swallows an exception names the exception type it expects and says why swallowing is right, in a comment on that line.

## Tests

- Tests use `rackunit` and live in `tests/` as `*-test.rkt`. `raco test <package-dir>` must pass with no network and no API key.
- Tests never depend on timing. Sequence tasks with events, channels or `wait-for` from `cordis/testing`. Every wait in a test has a timeout.
- A registration test disposes the fiber and observes the removal.
- Each test file leaves no files outside a temporary directory it created, no threads, and no listening ports.
- End-to-end behaviour is tested through the mock model provider with scripted sessions, not by calling private functions.
