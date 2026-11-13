# 0013. The agent inbox is a projection of the session log, not a channel

- Status: accepted
- Date: 2026-11-13

## Context and problem statement

The natural Racket shape for "messages waiting for an agent" is an asynchronous channel. The reconnaissance of the dsh loop shows the inbox is durable: queued input is logged (`agent/inbox/spliced`), survives a restart, is visible to other components without a live agent, and `send` on an idle agent runs the opening of a turn inline so the log already shows the turn when `send` returns.

## Considered options

1. An `async-channel` per agent, with the log written when the loop takes a message.
2. The dsh design: the inbox is a fold over session events; `agent-send!` appends and wakes the driver; nothing waits.

## Decision

Option 2. The driver is a task that sleeps on a wake event; the queue itself is derived from the log. A waking `agent-send!` runs the turn opening (status, `turn/start`, claim) before it returns, as dsh does.

## Consequences

- Good: resume, fork and external observers see the same pending input as dsh, and recorded sessions replay to the same log.
- Good: no message can be lost between "accepted" and "logged".
- Bad: less idiomatic than a channel; the guide explains why the durable form wins here.
