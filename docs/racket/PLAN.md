# Racket port: stage plan

This file is the stage plan and status for rebuilding DeepSeek Harness (dsh) as a Racket system. It is the first file to re-read after a context reset, followed by [PROGRESS.md](PROGRESS.md).

- **Pinned dsh commit:** `e8f7b93a344964de3dca1ace9e72b6e4d6de87cb` (dsh 0.2.2-rc.2). Every parity claim refers to this commit.
- **Branch:** `racket-port`.
- **Racket:** 9.3 [cs], found preinstalled at `/usr/local/bin/racket` (see [ADR 0001](../adr/0001-racket-toolchain-and-repository-layout.md)).
- **Vendored Cordis:** 4.0.0-rc.11 under `vendor/` with local modifications V1 to V27 listed in `vendor/README.md`.
- **Paper:** Shi, Zhang, Cui. *A Programming Paradigm for Spatiotemporal Composability*. arXiv:2608.25512.

## Standing rules

1. Research first, decide, record the decision as an ADR in `docs/adr/NNNN-title.md` (MADR), keep going. Do not ask the user.
2. Compatibility with dsh configuration formats (profiles, bundles, `cordis.yml` patches) comes first. Racket-only extensions live under their own namespaces or config keys, each with an ADR.
3. Stop only for a permission request. A problem that survives two different approaches goes into [BLOCKERS.md](BLOCKERS.md) with the fallback taken.
4. Commit and push at the end of every stage. Update this file and PROGRESS.md at every stage boundary.
5. Subagents: parallel research agents; one implementation agent per package with an explicit interface contract; one review agent per stage that has not seen the implementation.
6. Do not use the word that `AGENTS.md` bans (`prove` + `nance`).

## Stages

| # | Stage | Output | Status |
|---|---|---|---|
| 0 | Reconnaissance | `docs/racket/recon/*.md`, package inventory | in progress |
| 1 | Cordis analysis and ADRs | `docs/racket/cordis-analysis.md`, `docs/adr/` | pending |
| 2 | Racket Cordis kernel | `racket/cordis/` with its own test suite | pending |
| 3 | Harness, layer by layer | `racket/dsh-*/` | pending |
| 4 | Interfaces | CLI, browser UI, Python SDK | pending |
| 5 | Plugin porter | `SKILL.md`, porter tools, porter report | pending |
| 6 | Independent verification | review reports, `PARITY.md`, final report | pending |

## Deliverables checklist

- [ ] `docs/racket/cordis-analysis.md` (written before any code, kept current)
- [ ] Racket Cordis kernel as a standalone package with tests
- [ ] The harness: model adapters, agent loop, tools, skills, sessions, logs, sandbox, filesystem, scheduling, four modes (Standard, PTC, Minimal, Creator), CLI, browser UI, Python SDK
- [ ] Plugin porter: skill, tools, fallback Node sidecar, per-plugin report (automatic, wrapped, manual)
- [ ] `docs/racket/GUIDE.md` learning guide
- [ ] `docs/racket/PARITY.md` listing every dsh package and feature with status and tests
- [ ] `raco test` passes for every package
- [ ] Mock model provider replays scripted sessions; live smoke test if an API key is present
- [ ] Porter run on built-in plugins and at least three third-party plugins
- [ ] An existing dsh `cordis.yml` patch and profile load unchanged

## Stage detail

Stage detail is filled in as each stage starts; see PROGRESS.md for the running log.

### Stage 0: reconnaissance

Parallel research agents write one note per area under `docs/racket/recon/`. `docs/racket/recon/packages.json` is the generated inventory of the 379 dsh packages at the pinned commit.
