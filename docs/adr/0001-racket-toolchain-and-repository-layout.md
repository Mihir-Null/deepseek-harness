# 0001. Racket toolchain and repository layout

- Status: accepted
- Date: 2026-11-13
- Deciders: port coordinator (Claude Code session)

## Context and problem statement

The Racket rebuild of dsh lives in the same repository as the TypeScript harness it mirrors. It needs a toolchain that is reproducible in this environment, a place in the tree that does not disturb the pnpm workspace, and a package split that lets one agent own one package behind an explicit interface.

The brief said to install Racket and to record what worked.

## Considered options

Toolchain:

1. Use the Racket already present in the environment.
2. Install a pinned release from `download.racket-lang.org` into the session.
3. Install through the system package manager.

Layout:

1. One Racket package per dsh npm package (379 packages).
2. One monolithic Racket package for everything.
3. A small number of Racket packages under a top-level `racket/` directory, one per dependency layer, each with its own `info.rkt` and test suite; dsh npm package names map to modules inside them.

Documentation:

1. Put the Racket documents under the dsh documentation gates (bilingual pairs, word budgets, front matter).
2. Keep them in `docs/racket/` and `docs/adr/` as exploration documents outside those gates.

## Decision

**Toolchain: option 1.** `racket --version` reports `Welcome to Racket v9.3 [cs]` at `/usr/local/bin/racket`, with `raco` beside it. No install step was needed, so no download method was exercised. The pinned requirement for this port is Racket 9.x CS; the code avoids features removed or changed between 8.x and 9.x where that is cheap.

**Layout: option 3.** All Racket code lives under `racket/`. Each direct child is a Racket package. The kernel package `cordis` depends only on `base`. Packages are linked for development with `raco pkg install --link` (scripted in `racket/Makefile`), and `raco test` runs per package. A resolver table maps each dsh plugin name (for example `@deepseek-ai/dsh-tool-bash`) to a Racket module path, which is what keeps `cordis.yml` files loadable unchanged.

**Documentation: option 2.** `docs/racket/` holds the analysis, plan, progress log, parity table, guide and reconnaissance notes. `docs/adr/` holds these records in MADR format. They follow the repository's plain-language and one-line-per-paragraph rules but are not translated and are not registered with the dsh documentation gates.

## Consequences

- Good: nothing in the pnpm workspace, the TypeScript build, or the dsh gates changes; the port can be deleted by removing `racket/`, `docs/racket/` and `docs/adr/`.
- Good: a dozen or so packages is a workable unit for parallel implementation and for `raco test` per package.
- Bad: one Racket package covers many dsh packages, so the parity table (`docs/racket/PARITY.md`) has to carry the fine-grained mapping instead of the directory tree.
- Bad: the dsh CI gates that scan `docs/` may flag the untranslated documents if this branch is ever proposed upstream. That would need an exemption entry or translations at that time.
- Neutral: because Racket was preinstalled, the "try another install method" fallback was never needed. If a future environment lacks Racket, the release installer from `download.racket-lang.org` (`racket-9.3-x86_64-linux-cs.sh --unix-style --dest /usr/local`) is the first method to try.
