# cordis

The Cordis kernel in Racket: contexts, revertible effects, services with dependency injection, plugin fibers, events, and the cooperative task scheduler they run on. It reimplements the behaviour of `vendor/cordis` (the dsh package `@deepseek-ai/cordis`, with the helpers it takes from `@deepseek-ai/cosmokit`) on Racket threads. The interface is specified in [docs/racket/contracts/cordis-kernel.md](../../docs/racket/contracts/cordis-kernel.md); the reasons for its design are in [docs/racket/cordis-analysis.md](../../docs/racket/cordis-analysis.md) and ADRs 0002 to 0005 under `docs/adr/`.

This package holds contract sections 1 to 8 and 10. The declaration macros of section 9 (`define-plugin`, `define-service`, `define-event`, `#lang cordis/plugin`, `unit->plugin`) are not part of it yet.

## Modules

| Module | Provides |
|---|---|
| `cordis` | tasks, contexts, effects, services, plugins and fibers, events, errors and logging |
| `cordis/task` | the scheduler and tasks alone, usable without a context |
| `cordis/plugin` | the plugin struct API: `make-plugin`, `plugin?`, the accessors, `prop:config-schema` |
| `cordis/testing` | `with-root-context`, `kernel-snapshot`, `check-kernel-restored`, `capture-log`, `wait-for` |
| `cordis/private/loader-support` | rebindable contexts and fiber internals for the loader; no other package requires it |

`cordis/plugin` re-exports `private/plugin-api.rkt`, and `cordis` does not depend on `cordis/plugin`, so the macro layer can be added to `plugin.rkt` and may require `cordis`.

## Example

```racket
#lang racket/base
(require cordis)

(define root (make-root-context))

(define database
  (make-plugin (lambda (ctx config)
                 (ctx-provide ctx 'db (make-hash)))
               #:name "database"))

(define counter
  (make-plugin (lambda (ctx config)
                 (define db (ctx-ref ctx 'db))
                 (ctx-on ctx 'hit (lambda (key) (hash-update! db key add1 0)))
                 (lambda () (hash-clear! db)))
               #:name "counter"
               #:inject '(db)))

(define c (ctx-plugin root counter))    ; pending: nothing provides db yet
(define d (ctx-plugin root database))
(fiber-await d)                         ; the provider is active, the counter is loading
(fiber-await c)
(ctx-emit root 'hit 'home)
(fiber-dispose! d)                      ; counter unloads first, then the database
(context-shutdown! root)
```

## What to know before using it

- Kernel state is touched only by tasks. Every operation that changes it may be called from any thread; outside a task it runs as a task of the root's scheduler and returns that task's result. Inside a task, wait with `await`, never with `sync` or `sleep`: those block the thread while it holds the baton.
- `fiber-dispose!`, `fiber-restart!`, `fiber-update!`, `context-dispose!` and calling a disposer wait until the work is done. A caller that is part of what is being torn down, such as a plugin body that disposes an ancestor, runs the call in its own task with `spawn-task`. A plugin body may dispose or restart its own fiber directly; that call returns without waiting.
- `(await f)` and `(fiber-await f)` return at once for a pending fiber, because it has no transition in flight. Wait for the provider first, or use `wait-for`.
- Withdrawing a service waits until its dependents have unloaded. Call the disposer from another task when the caller holds one of those dependents back.
- A plugin body's value is an effect result. `(void)`, `#f`, a disposer and a fiber are accepted, so a body may end with a registration call. A task or another evt is awaited, and the fiber stays `'loading` until it settles: a body must not end with the `spawn-task` of a loop that never returns. Any other value fails the fiber with `invalid effect`.
- A break is delivered to user code and to waits, never inside kernel bookkeeping. A task that is broken while it waits for a cleanup gets the break at once; the cleanup continues in a kernel task.
- Each plugin fiber has a custodian per activation, shut down after its inverses have run. Threads, ports and tasks that plugin code leaves behind end there. A task that waits for the unload of its own fiber, or of an ancestor, is handed to the parent custodian first, so that it can see the outcome. The root fiber uses the kernel custodian, which lives until `context-shutdown!`.
- Errors that the kernel contains are logged at `error` on the `cordis` logger with the raised value as the event data. They also reach standard error under Racket's default log level; set `PLTSTDERR=none` to silence them in test output.

## Tests

```sh
make -C racket link                    # once: raco link -n cordis racket/cordis
raco test racket/cordis/tests          # the whole suite, including tests/spec
raco test racket/cordis/tests/*-test.rkt   # the package's own tests only
```

`tests/*-test.rkt` cover every numbered rule of contract sections 2 and 4 to 7, the fifteen laws of the analysis, and ports of the kernel-level TypeScript specs listed in [docs/racket/recon/01-cordis-core.md](../../docs/racket/recon/01-cordis-core.md). `tests/spec/` is an independent black-box suite written against the contract. No test depends on timing: tasks are sequenced with gates, and every wait is bounded.

## Layout

| File | Contents |
|---|---|
| `private/scheduler.rkt` | baton manager, tasks, `await`, latches |
| `private/breaks.rkt` | `critical` and `call-user`: where breaks may be delivered |
| `private/core.rkt` | data definitions; context derivation and lookup; fiber accessors |
| `private/effect.rkt` | `ctx-effect`, effect results, the disposer state machine |
| `private/events.rkt` | listener table and the five dispatch modes |
| `private/lifecycle.rkt` | fiber creation, reload and unload, notification, restart, update |
| `private/service.rkt` | provide, get, set, checked read, accessors, mixins, handles |
| `private/root.rkt` | root context, disposal and shutdown, loggers |
