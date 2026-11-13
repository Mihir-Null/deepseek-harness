# 0004. A custodian per fiber as the cleanup backstop (Racket extension)

- Status: accepted
- Date: 2026-11-13

## Context and problem statement

A Cordis effect is reverted only if its author returned an inverse. The paper states that this is an unchecked obligation. A plugin that starts a timer, opens a socket or spawns a process and forgets the inverse leaks it across every reload. Racket has custodians, which reclaim managed resources without being told how.

## Considered options

1. Inverses only, as in Cordis.
2. Custodians only: skip inverses for anything a custodian manages.
3. Both: inverses first, then shut down the fiber's custodian.

## Decision

Option 3.

- Each fiber has a custodian that is a child of its parent fiber's custodian. A fresh one is created for every activation.
- Plugin bodies, their effects' setup thunks and their spawned tasks run with `current-custodian` set to the fiber's custodian.
- Unload runs the inverse list in LIFO order exactly as Cordis does, and then calls `custodian-shutdown-all` on the fiber's custodian.
- A tool handler or listener called on behalf of an agent runs under the caller's custodian, not the registering plugin's, following the use-site rule of ADR 0003. A subprocess started by a tool for a session belongs to the session.
- `#:custodian 'inherit` on a plugin opts out, for a plugin that hands long-lived resources to others by design.
- `custodian-limit-memory` can be set per plugin from configuration under the extension key `x-racket.memoryLimit`.

## Consequences

- Good: threads, ports, listeners, subprocesses and FFI resources registered with a custodian cannot outlive the plugin, whether or not the author wrote an inverse.
- Good: the custodian tree mirrors the fiber tree, so disposing a subtree is one shutdown.
- Good: per-plugin memory limits.
- Bad: custodian shutdown kills threads without unwinding, so it must come after the inverses, never instead of them.
- Bad: a resource created under a plugin's custodian and handed to a longer-lived owner dies with the plugin. The rule "resources belong to the use site" and the opt-out cover the known cases.
- Neutral: this is an extension. No dsh configuration depends on it, and a ported plugin that returns correct inverses behaves the same with or without it.
