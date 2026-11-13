# 0015. Messages, chunks and events are jobjects with dsh field names, not a struct hierarchy

- Status: accepted
- Date: 2026-11-13

## Context and problem statement

The message, content-block, stream-chunk and session-event vocabulary is shared by every package, written to disk, sent to models and replayed from dsh fixtures. In TypeScript it is a set of plain object types.

## Considered options

1. Racket structs for every record, with codecs to and from JSON at each boundary.
2. Plain `jobject`s with the dsh field names in dsh write order, plus generated constructors, predicates, accessors and match patterns (ADR 0011). Structs only for process-local values that never reach a file or a wire (a request holding a cancel event, a prepared call, a chunk stream).

## Decision

Option 2. A session event keeps the JSON envelope it was read from, so re-writing a restored log reproduces it, including fields a newer dsh added that this port does not know.

## Consequences

- Good: no translation layer and no chance for a codec to drop or reorder a field; unknown fields survive a round trip.
- Good: dsh fixtures are usable as test data unchanged.
- Bad: field access is checked by the generated accessors and contracts, not by struct types; code that bypasses them with `jref` loses that check.
