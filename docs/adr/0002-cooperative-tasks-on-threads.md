# 0002. Cooperative tasks on Racket threads, scheduled by a kill-safe baton

- Status: accepted
- Date: 2026-11-13

## Context and problem statement

Cordis assumes a JavaScript event loop: code runs to completion between `await` points, lifecycle transitions are promises, and their order is microtask order. Three things depend on that assumption. Listener registration order is deterministic, and it is observable in every `waterfall`. Kernel and plugin state needs no locking. A handler body can be reasoned about, and translated by the plugin porter, without considering interleavings.

Racket threads are preemptive. The kernel needs a concurrency model that keeps those three properties and still feels like Racket.

## Considered options

1. **Preemptive threads with locks or manager threads.** One thread per transition and per agent; every shared table protected.
2. **A reactor with continuation-based `await`.** One thread runs all harness code inside a prompt; `await` captures a composable continuation, registers it against an event and returns to the loop.
3. **Cooperative tasks on threads.** Each task is a Racket thread. Only the holder of a per-root baton runs harness code. `(await evt)` releases the baton, waits on any Racket event, and reacquires the baton in FIFO order.

## Decision

Option 3.

- `spawn-task` creates a thread under the current custodian that inherits the current parameterization, waits for the baton, runs, and releases it on exit. The task value is an event whose result is the thunk's values or its exception.
- `await` accepts any `evt`, including tasks and fibers. With breaks disabled it reacquires the baton before returning or before re-raising a break, so handlers and `dynamic-wind` post thunks always run under the baton.
- `blocking` runs a thunk on a plain thread outside the baton and awaits it. The thunk must not touch harness state.
- `call-in-kernel` lets a foreign thread (a web-server handler, the main thread) run a thunk as a task and wait for it.
- The baton is owned by a manager thread created under the root's kernel custodian. It keeps a FIFO queue of requests, grants one at a time, and also syncs on the holder's `thread-dead-evt`, so a holder that is killed gives the baton up. Dead waiters are skipped.
- Fiber transitions run as tasks owned by the kernel custodian, not the fiber's custodian, so shutting down a fiber's custodian during unload cannot kill the transition that is performing the unload.

## Consequences

- Good: run-to-completion between awaits. Kernel tables need no locks; listener order is the order of registration; TypeScript bodies translate faithfully.
- Good: a task is a real thread. `break-thread` cancels it even in a CPU loop, a custodian can kill it, parameterizations and exception handlers need no special care, and any blocking Racket library can be used through `blocking`.
- Good: deterministic scheduling makes scripted sessions reproducible.
- Good: the paper's `create_task` and `fiber.inertia` map one to one.
- Bad: no parallelism inside the harness. The workload is dominated by waiting on models, subprocesses and sockets, all of which happen with the baton released.
- Bad: a task that blocks without `await` or `blocking` stalls every other task, exactly as a busy loop stalls Node. The kernel logs a warning when the baton is held longer than a configurable threshold.
- Bad: one thread per in-flight task. Racket threads cost a few kilobytes.
- Rejected option 2 would have shown off continuations more, but tasks would not be threads: no breaks, no per-task custodian kill, and every blocking call would need a continuation-aware wrapper. Continuations are used instead for effect iterators (generators), where they are local and synchronous.
- Rejected option 1 changes observable semantics (registration order) and makes every ported handler a potential data race.
