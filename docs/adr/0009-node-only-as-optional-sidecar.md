# 0009. Node is an optional sidecar, never a build dependency

- Status: accepted
- Date: 2026-11-13

## Context and problem statement

Some dsh behaviour is JavaScript by definition: the `run_code` tool of PTC mode runs TypeScript programs written by the model; third-party plugins ship as built JavaScript; a few providers wrap npm SDKs. The repository at the pinned commit has no `node_modules`, and building dsh needs the full pnpm workspace.

## Considered options

1. Depend on a built dsh and reuse its bundled child bootstraps.
2. Port nothing that needs JavaScript.
3. Ship small plain `.mjs` files that use only Node built-ins, run them as child processes, and treat a missing `node` as a disabled feature.

## Decision

Option 3. Each package that needs JavaScript owns its `.mjs` files and the pipe protocol to them. Three sidecars are planned: the PTC program runner in `dsh-ptc`, the wrapped-plugin host in `dsh-porter`, and the TypeScript front end the porter uses to parse sources. All are optional at run time. Where a sidecar would need an npm package (for example a provider SDK), the plugin is reported as "wrapped, needs `npm install` in the plugin's directory" and the harness says so when it is mounted.

## Consequences

- Good: `raco test` for every package passes with no network and no Node; tests that exercise a sidecar skip with a visible message when `node` is absent.
- Good: the Racket harness starts and runs Standard and Minimal modes on a machine with no Node at all.
- Bad: PTC mode's JavaScript `run_code` and wrapped plugins need Node 22 or later.
- Bad: the sidecars reimplement, in small, what dsh's bundled bootstraps do; they are tested against the dsh wire format described in the reconnaissance notes.
- Rejected option 1 because it would make the Racket port depend on a successful TypeScript build, and option 2 because it would drop a mode the brief requires.
