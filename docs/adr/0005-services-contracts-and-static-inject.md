# 0005. Services: contracts at provision, generics for seams, static `inject` in `define-plugin`

- Status: accepted
- Date: 2026-11-13

## Context and problem statement

Cordis services are values stored under string keys, typed by TypeScript declaration merging and reached through a `Proxy` that enforces the plugin's `inject` declaration at run time. The Racket kernel needs a way to declare a service, to describe what a valid value is, to express that a seam has several interchangeable providers, and to enforce `inject`.

The brief names units, contracts and Typed Racket as candidates.

## Considered options

1. **Units.** Signatures as Service Definitions, units as plugins, linking as injection.
2. **Classes and interfaces** (`racket/class`).
3. **Typed Racket** types for service values.
4. **Untyped values with contracts, `racket/generic` for multi-provider seams, and macros that make `inject` static.**

## Decision

Option 4.

- `define-service` declares a key and a contract. `ctx-provide` applies the contract with the providing module as the positive party.
- A Service Definition with several providers is a generic interface (`define-generics`); a provider is a struct that implements it.
- `define-plugin` takes `#:inject (name ... [name #:optional] ...)`. Each name is bound lexically in the body to a service handle on the plugin's context (ADR 0003). Using an undeclared service through such a binding is an unbound-identifier error at compile time; using it through `ctx-ref` is the run-time error Cordis raises.
- The reflective, string-keyed API remains for configuration, translated plugins and code written at run time.
- `unit->plugin` adapts a unit whose imports are service signatures into a plugin, for code that wants signature-checked linking.
- Typed Racket is not used in the kernel.

## Consequences

- Good: a wrong service value is reported at the provision site with blame on the provider, and misuse of a higher-order service blames the consumer; these are the roles of a dsh capability seam.
- Good: the dependency check the paper says is "in principle detectable at compile time" is done at compile time for the common case.
- Bad: contracts on large service values cost time on every call that crosses the boundary. Service contracts are first-order checks of the value's kind by default; full higher-order contracts are opt-in.
- Bad: units would have given whole-program link checking. The loader recovers part of it by reading `plugin-info` submodules before mounting anything.
- Rejected Typed Racket here because services are provided by code loaded at run time, so each typed boundary would be a generated contract with less control over blame and cost.
