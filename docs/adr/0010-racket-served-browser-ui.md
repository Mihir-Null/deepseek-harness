# 0010. A Racket-served browser UI in place of the dsh web client

- Status: accepted
- Date: 2026-11-13

## Context and problem statement

The dsh browser UI is about 180k lines of TypeScript: a second Cordis tree that runs in the browser, built with the Node toolchain, fed by a typed RPC gateway and a multiplexed WebSocket. The brief asks for the browser UI as one of the interfaces and says to port each part in the way most natural in Racket.

## Considered options

1. A wire-compatible Racket host that serves the existing built client. The reconnaissance estimates 15 to 20 thousand lines of Racket for the gateway and controllers, and it still needs the client bundles built by Node, and every remote namespace present before the client boots.
2. A Racket-native UI: the Racket `web-server` renders pages from x-expressions, session events reach the browser over server-sent events, and a small hand-written JavaScript file applies them. Feature parity is tracked by the user-visible checklist in `recon/15-web-client.md`.
3. No browser UI.

## Decision

Option 2. The server side reuses the same session-follow logic the SDK server uses. The UI is one page per concern (sessions and chat, approvals and questions, settings, plugins, files), rendered on the server, with progressive enhancement from one JavaScript file with no build step. Authentication follows dsh: a per-process launch token exchanged for an HMAC-signed cookie, with the same host and origin checks.

## Consequences

- Good: no Node toolchain; the whole UI is Racket data (x-expressions) and can be tested by rendering and by HTTP requests.
- Good: the UI is a plugin tree like everything else: a page or a tool card is a registration, reverted when its plugin unloads.
- Bad: this is not the dsh client. Its look differs, and client-side plugins written for dsh (the `ui-*` packages, third-party client bundles) do not load. The parity table lists each dsh client package against the feature that replaces it, or as not ported.
- Bad: rich client features (the terminal emulator, document previews, the dock layout) are reduced or absent; each gap is listed in the parity table.
- Rejected option 1 as the less natural port and the one with a hard dependency on a Node build; it remains possible later because the session and controller logic is shared.
