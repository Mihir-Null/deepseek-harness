# 0014. Consumer-owned ports for dependencies that point upward

- Status: accepted
- Date: 2026-11-13

## Context and problem statement

Lower packages sometimes need a capability that a higher package provides: the model layer needs attachments and credentials, the agent loop needs session persistence and settings. TypeScript handles this with structural types: the consumer declares the few methods it needs and any object with those methods fits. Racket has no structural typing, and a `require` from the lower package to the higher one would be a cycle.

## Considered options

1. Move every such interface into `dsh-util`.
2. The consumer declares a small generic interface (a *port*) for what it needs; the provider's package implements it for its service value.
3. Duck typing with hashes of procedures.

## Decision

Option 2. Ports live in the consumer (`dsh-llm/ports`, `dsh-agent/ports`). A port is a `racket/generic` interface, so its methods take the provider's value first and the owning context second. This is the one stated exception to ADR 0003's "context first": the context is still explicit, and no port method reads `current-context`.

## Consequences

- Good: the package graph stays acyclic, and each consumer documents exactly what it needs from above.
- Good: a test can supply an in-memory port (`racket:session-projections` is one).
- Bad: a provider must implement each consumer's port. The ports are small (one to four methods).
