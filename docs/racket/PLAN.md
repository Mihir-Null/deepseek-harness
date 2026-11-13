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
| 0 | Reconnaissance | `docs/racket/recon/*.md`, package inventory | done (20 notes) |
| 1 | Cordis analysis and ADRs | `docs/racket/cordis-analysis.md`, `docs/adr/` | done (kept current) |
| 2 | Racket Cordis kernel | `racket/cordis/` with its own test suite | in progress |
| 3 | Harness, layer by layer | `racket/dsh-*/` (waves 2 to 5 of `ARCHITECTURE.md`) | wave 2 building, wave 3 contracts in design |
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

The package list, dependency order and cross-package conventions are in [ARCHITECTURE.md](ARCHITECTURE.md); coding rules in [CONVENTIONS.md](CONVENTIONS.md); per-package interfaces in `contracts/`.

### How each wave runs

1. Architect agents write the wave's interface contracts from the reconnaissance notes and the code that already exists. A consistency reviewer cross-checks them (`contracts/WAVE<n>.md`).
2. One implementation agent per package (or per work unit of a large package) builds from its contract, with tests.
3. A reviewer who did not see the implementation checks each package against the TypeScript originals, differential-tests where possible, and fixes what it finds.
4. The coordinator runs `make -C racket test`, updates PLAN.md, PROGRESS.md and PARITY.md, commits and pushes.

### Wave status

| Wave | Packages | Contracts | Built | Reviewed |
|---|---|---|---|---|
| 1 | `cordis` | done | in progress | pending |
| 2 | `cordis-data`, `cordis-schema`, `cordis-yaml`, `dsh-util` | `cordis-data` done; others written by their implementers | in progress | pending |
| 2 | `cordis-loader` | pending (needs kernel) | pending | pending |
| 3 | `dsh-session`, `dsh-llm`, `dsh-tools`, `dsh-agent`, `dsh-test-support` | in progress | pending | pending |
| 4 | `dsh-session-store`, `dsh-exec`, `dsh-fs`, `dsh-interaction`, `dsh-automation`, `dsh-context`, `dsh-subagent`, `dsh-connect`, `dsh-platform`, `dsh-ptc` | pending | pending | pending |
| 5 | `dsh-boot`, `dsh-sdk`, `dsh-web`, `dsh-experimental` | pending | pending | pending |
| 6 | `dsh-js`, `dsh-porter` | pending | pending | pending |

### Things to remember across waves

- Workflow scripts are saved under the session's `workflows/scripts/` directory; a finished workflow's per-agent results are in its `journal.jsonl`.
- Third-party plugin tarballs fetched during reconnaissance are in the session scratchpad under `third-party/` (not committed): `@mem0/deepseek-plugin` 0.3.2, `@braintrust/deepseek-harness` 1.0.0, and others listed in `recon/17-plugin-authoring-surface.md`.
- The Stone library the brief mentions is the Racket package `Stone` (codeberg `Trevoke/stone`), a DAG-based agent harness; `recon/20-racket-mechanisms.md` lists the techniques worth borrowing (owning the HTTP socket for streaming, cooperative cancellation, scripted model mocks).
- Decisions still to record as ADRs when their wave starts: PTC hosting (native Racket evaluator plus Node runner), Typed Racket use, the porter's translation pipeline and the `dsh-js` language, sandboxed plugin loading, the session-event declaration form, the tool declaration form.
