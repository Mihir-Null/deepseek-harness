# 0003. Ownership follows an explicit context; injected services are handles

- Status: accepted (revised the same day after the kernel reconnaissance; the first version let service procedures default to a `current-context` parameter)
- Date: 2026-11-13

## Context and problem statement

In Cordis a service method called as `ctx.tools.register(x)` runs with `this.ctx` rebound to the context the service was read through, so the registration belongs to that context's fiber, while service lookups inside the method resolve against the provider's own injections. The TypeScript kernel implements this with nested `Proxy` objects (`getTraceable`, the `tracker`, `shadow` and `receiver` symbols). The two roles are called the use site and the definition site.

The use site is not always the running plugin's own context. Harness code reads services through other contexts on purpose, for example a per-agent scope context from `packages/core/scope`, and the registration must then belong to that scope. The Racket kernel needs the same rule without proxies.

## Considered options

1. **Parameter only.** `(current-context)` is the context everywhere; no function takes one.
2. **Explicit argument for kernel operations; service procedures default to `(current-context)`.**
3. **Explicit first argument everywhere, plus service handles.** Every kernel operation and every service procedure takes, as its first argument, either a context or a *service handle*, which is the pair of a context and a service key. `define-plugin` binds each injected service to a handle on the plugin's own context.
4. **Impersonators.** Wrap service values in impersonators that rebind a context field per access, imitating the proxies.

## Decision

Option 3.

- Kernel operations are `(ctx-effect ctx ...)`, `(ctx-on ctx ...)`, `(ctx-provide ctx ...)` and so on.
- A service procedure is written `(define (tools-register! x tool) ...)` where `x` is a context or a handle. `(use-context x)` yields the context to own effects; `(tools-ref x)` yields the service value through the checked read. Passing a context is the Racket spelling of `thatCtx.tools.register(tool)`.
- In a `define-plugin` body, `#:inject (tools)` binds `tools` to `(service-handle ctx 'tools)`. `(tools-register! tools my-tool)` is the common case and reads as "use my `tools` capability". A body that mentions a service it did not declare has an unbound identifier.
- A handle resolves its value at each use, through `ctx-ref`, so it is never stale and it enforces the `inject` declaration exactly as the proxy does.
- The definition site is lexical scope: a provider's procedures close over the provider's own context and handles.
- `current-context` still exists. The kernel sets it around plugin bodies, listeners, disposers and tasks. It is for diagnostics, logging and the JavaScript compatibility runtime. No kernel or harness procedure uses it to decide ownership.

## Consequences

- Good: which fiber owns an effect is visible at the call: it is the fiber of the first argument.
- Good: the two roles are the two binding disciplines Scheme already has. Lexical scope is the definition site; the use site is passed, as a capability.
- Good: undeclared use of a service is a compile-time error in the common case and the Cordis run-time error otherwise.
- Good: no wrapping of service values, so no identity surprises and no per-access cost beyond one checked read.
- Bad: two spellings of the first argument (context or handle). The convention is: handles inside plugin bodies, contexts everywhere else.
- Bad: translated plugins that write `ctx.foo.bar(x)` need the porter to produce `(foo-bar ctx x)` or a compatibility call; see the porter ADRs.
- Rejected option 1 and option 2 because a stored closure runs under its caller's parameterization, and because code that deliberately uses another scope's context would silently register on the wrong fiber. Rejected option 4 because it hides the same information the proxies hide.
