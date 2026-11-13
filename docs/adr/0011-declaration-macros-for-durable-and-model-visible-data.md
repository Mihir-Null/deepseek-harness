# 0011. Declaration macros for durable and model-visible data

- Status: accepted
- Date: 2026-11-13

## Context and problem statement

The brief says to use a macro only when it removes a whole class of bugs or boilerplate. The wave 3 architects proposed several declaration forms. Each needs a stated reason, and the ones without one should be plain functions.

In dsh three kinds of data are written by hand in many places and must match exactly: session events (a type tag and fields in a fixed order), tool definitions (a JSON Schema for the model and a handler that reads the same arguments), and JSON records on the wire. TypeScript checks the field names; nothing checks key order, and nothing ties a tool's schema to the arguments its handler reads.

## Considered options

1. Plain constructor functions and hand-written schemas, as in dsh.
2. One declaration form per kind of data, which generates constructor, predicate, accessors, match pattern and, for tools, the schema and the argument bindings.

## Decision

Option 2 for these forms, and no others without a new record:

| Form | Package | Class of error removed |
|---|---|---|
| `define-session-event` | `dsh-session` | keys written in a different order from dsh; misspelled type tags and field names; readers assuming a field the type lacks |
| `define-tool` | `dsh-tools` | a handler reading an argument the schema does not declare; schema and handler drifting apart after a rename; a default applied in one callback and not another |
| `define-jrecord` | `dsh-llm` | wire and log records with keys in the wrong order, or an optional field written as `null` instead of omitted |
| `define-junion` | `dsh-llm` | a consumer of a closed union (stream chunks, messages) that forgets a variant; the generated case form does not compile without all variants or an explicit `#:else` |
| `session-script` | `dsh-test-support` | a scripted model reply and its expected log row drifting apart; hand-numbered sequence ids |
| `define-plugin`, `define-service`, `define-event` | `cordis` | undeclared service use; misspelled event names; dispatch in the wrong mode (ADR 0005) |

Every form has a functional counterpart (`make-tool`, the event constructors) for code that builds these values at run time, such as the plugin porter.

## Consequences

- Good: the three places where dsh relies on convention are checked at compile time.
- Good: the declarations are data that tools can read: the tool catalog, the event catalog and the porter's translation tables are generated from them.
- Bad: six forms to learn. The guide documents each with its expansion.
- Bad: a macro error is harder to read than a function error; each form uses `syntax/parse` and names the clause at fault.
