# 0006. One JSON value model with ordered objects and JavaScript-compatible text

- Status: accepted
- Date: 2026-11-13

## Context and problem statement

dsh is written in JavaScript, where an object keeps its keys in insertion order and `JSON.stringify` output is a de facto format. The reconnaissance found that this order and text are observable in many places: tool parameter schemas sent to the model, tool-call arguments in the session log, the code API text generated for PTC mode, `cordis.yml` files written back by the loader, and hashes and byte limits computed over `JSON.stringify` output. Racket's `json` library reads objects into `hasheq`, which has no order, and its writer does not format numbers the way JavaScript does.

Several dsh limits also count UTF-16 code units, others UTF-8 bytes, others code points.

## Considered options

1. Use `racket/json` jsexprs everywhere and accept different key order and number text.
2. Use jsexprs in memory and give each writer a declared field order.
3. Use mutable, insertion-ordered maps everywhere, as JavaScript does.
4. One immutable value model whose objects remember insertion order, with its own reader and writer that match `JSON.parse` and `JSON.stringify`.

## Decision

Option 4, in a base package `cordis-data` that every other package may depend on.

- `jobject` is an immutable struct with O(1) lookup and an ordered key list. Arrays are lists. `null` is `'null`. `equal?` on jobjects ignores order, as cosmokit's `deepEqual` does.
- The reader preserves key order. The writer reproduces `JSON.stringify`, including number formatting and escaping.
- Functions that read a jvalue also accept a plain `hash`, so literals in code and tests stay convenient; anything that builds an object returns a `jobject`.
- The package also provides `deep-equal?` with cosmokit's loose and strict modes and the UTF-16, UTF-8 and code-point length helpers.

## Consequences

- Good: model-visible and durable text can match dsh byte for byte where it has to.
- Good: one representation across YAML configuration, session logs, wire protocols and tool schemas; no conversion layer between packages.
- Good: immutable values fit the task model; sharing a value between tasks is safe.
- Bad: code uses `jref` and `jset` instead of `hash-ref` and `hash-set`, and `match` needs the package's expander. Accepting plain hashes on input softens this.
- Bad: functional update of the key list is linear in the number of keys. JSON objects in this system are small.
- Rejected option 3 because mutable shared maps are the thing the task model is trying to avoid, and it would make the port read like JavaScript. The loader, whose TypeScript relies on object identity, keeps its own mutable entry records instead.
- Rejected options 1 and 2 because free-form objects from outside (MCP tool schemas, model-written arguments) have no declared order to fall back on.
