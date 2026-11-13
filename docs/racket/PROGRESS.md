# Racket port: progress log

Newest entries last. Each entry says what was done and what comes next. Re-read this file with [PLAN.md](PLAN.md) after any context reset.

## Stage 0: reconnaissance

- Checked out branch `racket-port` from pinned commit `e8f7b93a3`.
- Racket 9.3 [cs] was already installed at `/usr/local/bin/racket`; no install step was needed.
- Read `docs/architecture.md`, `docs/cordis-primer.md`, `packages/README.md`, `vendor/README.md`.
- Facts established:
  - 379 packages under `packages/` and `apps/` (inventory in `recon/packages.json`); about 600k lines of TypeScript, of which `packages/client` is about 183k and `packages/experimental` about 116k.
  - Vendored Cordis is 4.0.0-rc.11 (fiber-based), about 7.3k lines across `vendor/*/src`.
  - The four modes are agent presets in `packages/bundle/web-app/presets/{standard,ptc,minimal,cordis}.patch.yml`; Creator mode is the `cordis` preset.
  - The paper is arXiv:2608.25512; a text copy is in the session scratchpad (not committed).
- Next: run the parallel reconnaissance workflow, then read the vendored Cordis kernel and write `cordis-analysis.md`.
- Opened draft PR #1 (`racket-port` into `master`) and subscribed to its activity. The fork runs no CI on it.
- Ran the reconnaissance workflow: 20 research agents in three batches, one note each under `docs/racket/recon/`. Sixteen notes were complete at the time of this entry; `04-core-data`, `05-core-loop`, `18-testing-snapshots` and `20-racket-mechanisms` were still being written.
- Findings that changed the plan:
  - The named third-party plugins exist on npm and were fetched into the scratchpad: `@mem0/deepseek-plugin` 0.3.2 and `@braintrust/deepseek-harness` 1.0.0. They ship built JavaScript in function-plugin form.
  - TypeScript 6.0.2 is resolvable globally, so the porter can use the TypeScript compiler for parsing.
  - The browser client is a second Cordis tree of about 180k lines that needs the Node toolchain to build. The Racket port will serve its own browser UI instead (ADR to follow).
  - `!!js` values in `cordis.yml` are JavaScript expressions; the loader needs an embedded evaluator for the subset the shipped configs use.
  - The SDK wire protocol is NDJSON JSON-RPC 2.0 over stdio; the Python client only needs an executable that accepts `--profile <p> [--patch <abs>]...` and `DSH_HOME`.

## Stage 1: Cordis analysis and ADRs

- Read the vendored kernel source (`context`, `fiber`, `events`, `registry`, `reflect`, `service`, `utils`) and the paper's sections 5 to 7 directly; the rest of the paper through the digest in `recon/19-paper-digest.md`.
- Wrote `docs/racket/cordis-analysis.md`, the kernel interface contract `docs/racket/contracts/cordis-kernel.md`, `docs/racket/CONVENTIONS.md`, and ADRs 0001 to 0005.
- Revised ADR 0003 after the kernel reconnaissance: ownership follows an explicit context or service handle; `current-context` is diagnostic only.
- Prototyped the kill-safe baton scheduler in the scratchpad to confirm ADR 0002 before committing to it.

## Stage 2: kernel

- Launched the kernel build workflow: implementation and an independent black-box spec suite in parallel, integration, declaration macros and `#lang cordis/plugin`, three adversarial reviewers, fix pass.
- Next: while it runs, fix the harness package layout and write the cross-package architecture document; then the loader stack.

## Stage 0 closed

- All 20 reconnaissance notes are written (about 290k words). Their summaries, risks and gaps are in the workflow journals; the load-bearing findings are folded into `ARCHITECTURE.md`, the ADRs and the contracts.
- Late findings from `recon/20-racket-mechanisms.md` that changed contracts: breaks are safe only at `await` points (kernel contract rule 2.4 now says breaks are disabled while a task runs); stale `.zo` files give false test passes (`raco make` before `raco test`); `net/http-client` streaming cannot be cancelled and does not verify TLS by default, so model adapters own their socket; `libzstd.so.1` is present for the FFI; a PTY needs about 30 lines of FFI over `openpty`.
- Wrote `ARCHITECTURE.md` (26 Racket packages in 6 waves), ADRs 0006 to 0010, and the `cordis-data` contract.
- Running at the time of this entry: the kernel build workflow, the wave 2 foundations workflow (`cordis-data`, then `cordis-schema`, `cordis-yaml`, `dsh-util`), and the wave 3 contract design workflow.
- Next: when the kernel is green, write the `cordis-loader` contract and build it; when wave 3 contracts pass their consistency review, build wave 3 and run the first end-to-end scripted session.

## Recovery note (container restart during waves 1 to 3)

- The container restarted while three workflows were running. Files on disk and the workflow journals survived; the running agents did not.
- State found: kernel spec suite complete (207 black-box cases), kernel implementation partly written; `cordis-data` complete; `cordis-schema` and `cordis-yaml` partly written; `dsh-util` not started; wave 3 contracts drafted, consistency review not finished.
- Recovery procedure that worked: commit the tree, then re-invoke each workflow with `Workflow({scriptPath, resumeFromRunId})`. Finished agents replay from the journal; interrupted agents run again, with a "resumed run" preface added to their prompts telling them to assess existing files first. Scripts are in the session directory under `workflows/scripts/`; run ids: kernel `wf_afe8c425-d67`, wave 2 foundations `wf_d0262d6b-a3c`, wave 3 contracts `wf_71b5a3a1-fac`.
- A self-scheduled check-in now commits and pushes work in progress every 20 minutes while workflows run, so a restart loses at most that much.
- Started wave 4 contract design in two workflows that share one script (`racket-wave4-contracts-wf_c0e230b9-ee1.js`): run `wf_c0e230b9-ee1` with args `{"areas":["session-store","exec-fs","collab"]}` and run `wf_90c81c39-9c9` with args `{"areas":["context-subagent","connect-platform","ptc"]}`. A consistency review across the wave 4 contracts follows when both finish.
- Wave 3 architects raised points that need action after their consistency review: a kernel addendum for listener resolution (now section 12 of the kernel contract), one home for cancellation values (candidates: `dsh-util/cancel`), a `name` field on `exn:fail:harness`, and ADRs for: agent cancellation by cancel source with a recorded cause, the inbox as a durable projection, consumer-owned generic ports, and the declaration macros (`define-session-event`, `define-tool`, `define-jrecord`, `define-junion`, `session-script`).

## Wave 3 design closed, build started

- Wave 3 contracts are written and cross-checked: `contracts/dsh-session.md`, `dsh-tools.md`, `dsh-llm.md`, `dsh-agent.md`, `dsh-test-support.md`, and `contracts/WAVE3.md` (13 work units in 5 steps, prerequisites, 24 integration points, the wave gate). ADRs 0011 to 0015 record the design decisions the architects raised.
- Wave gate (from `WAVE3.md`): both gate scripts of `dsh-test-support` pass, and five recorded dsh sessions (`pi-ai-replay-metadata`, `fs-read`, `tool-call-turn`, `todo-write`, `empty-response-retry-current`) replay to a matching loop projection.
- Build script for wave 3 units: `racket-wave3-build-wf_a9bcedde-10d.js` (args `{"units":[...]}`, one implementer per unit). Started: `S-A` (run `wf_a9bcedde-10d`).
- Wave 3 prerequisites still open: kernel section 12 addenda (`ctx-dispatch-callbacks`, meta inheritance, `call-contained`, cooperative breaks) and non-exception raised values passing through `await`; `dsh-util` with a `name` on `exn:fail:harness`, a UUID v4 generator, `launch-environment-ref`, `proxy-for-url`, atomic replace, and one home for the "invalid config:" wrapper.
- Next units to start when the kernel is green: `S-B`, `L-1`, `T-1`, `T-2`, `X-1`; then `T-3`, `L-2`, `L-3`, `A-1`; then `A-2`, `A-3`; then `X-2`.
