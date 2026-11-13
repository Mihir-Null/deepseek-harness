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
