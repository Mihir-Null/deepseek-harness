# 0012. Agent cancellation uses a cancel source with a recorded cause; a break is the backstop

- Status: accepted (refines ADR 0002)
- Date: 2026-11-13

## Context and problem statement

ADR 0002 says cancellation is a break delivered at an `await`. The agent loop needs more than that. dsh records *why* a turn ended (`turn/end` carries the cause: user cancel, disposal, a newer steer), a cancelled tool batch must still drain and log a result for every call that started, and several waits must end together (the model stream, running tools, a retry delay). dsh does this with `AbortController`, `AbortSignal.any` and a reason value.

## Considered options

1. Break the agent's task and infer the cause afterwards.
2. A cancel source: an event that becomes ready once, carrying a reason. Waits use `choice-evt` with it; `check-cancelled!` raises the reason at safe points; sources combine with `cancel-evt-any`.
3. Both: option 2 for cooperative cancellation, with a break of the driver task treated as cancellation with cause `disposed`.

## Decision

Option 3. Cancellation values live in one module (`dsh-llm/cancel`, the lowest package that needs them) and every procedure that waits names its `#:cancel` event. A break still works everywhere, as ADR 0002 says, and is what a custodian shutdown or `task-cancel!` delivers; the loop maps it to cause `disposed` and performs its closing appends with breaks disabled.

## Consequences

- Good: the cause reaches the log exactly as in dsh; a cancelled batch drains.
- Good: a cancel source is a Racket event, so it composes with timeouts and other events in one `sync`.
- Bad: two mechanisms. The rule is: request-level cancellation is a cancel event passed as an argument; task-level abandonment is a break.
