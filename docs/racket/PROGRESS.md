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
