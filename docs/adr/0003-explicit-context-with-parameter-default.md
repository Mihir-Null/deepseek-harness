# 0003. Explicit context argument, with a parameter for the use site

- Status: accepted
- Date: 2026-11-13

## Context and problem statement

In Cordis a service method called as `ctx.tools.register(x)` runs with `this.ctx` rebound to the caller's context, so the registration belongs to the caller's fiber, while service lookups inside the method resolve against the provider's own injections. The TypeScript kernel implements this with nested `Proxy` objects (`getTraceable`, the `tracker`, `shadow` and `receiver` symbols). The Racket kernel needs the same two roles, called the use site and the definition site, without proxies.

## Considered options

1. **Parameter only.** `(current-context)` is the context everywhere; no function takes one.
2. **Explicit argument only.** Every kernel and service function takes `ctx`.
3. **Explicit argument for kernel operations and plugin bodies; a `current-context` parameter that service procedures use as the default for their caller's context.**
4. **Impersonators.** Wrap service values in impersonators that rebind a context field per access, imitating the proxies.

## Decision

Option 3.

- Kernel operations are `(ctx-effect ctx ...)`, `(ctx-on ctx ...)`, `(ctx-provide ctx ...)` and so on.
- A plugin body receives `ctx` and closes over it and over its injected services. That closure is the definition site.
- The kernel parameterizes `current-context` when it runs a plugin body, a listener, a disposer or a task. A service procedure that registers something for its caller is written `(define (tools-register! tool #:ctx [ctx (current-context)]) ...)`. That default is the use site.
- When the kernel stores a callback (a listener, a tool handler) it records the registering context and re-establishes it as `current-context` around the call, unless the dispatcher supplies a more specific one (for example the per-agent context of a tool call).

## Consequences

- Good: the two roles are the two binding disciplines Scheme already has, lexical and dynamic, so nothing has to be reconstructed at run time.
- Good: which fiber owns an effect is visible in the code.
- Good: no cost on service access; no surprising identity changes from wrapping.
- Bad: service authors must remember the `#:ctx` convention for procedures that register on behalf of a caller. A `define-service-procedure` form supplies it.
- Bad: translated plugins that write `ctx.foo.bar()` need the porter to turn property access into `ctx-ref`; the compatibility runtime does this (see the porter ADRs).
- Rejected option 1 because a stored closure runs under its caller's parameterization, which would attribute effects to the wrong fiber. Rejected option 4 because it hides the same information the proxies hide.
