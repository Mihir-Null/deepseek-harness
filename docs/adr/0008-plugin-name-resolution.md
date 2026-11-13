# 0008. Resolving dsh plugin names to Racket modules

- Status: accepted
- Date: 2026-11-13

## Context and problem statement

A `cordis.yml` row names its plugin by npm package name, for example `@deepseek-ai/dsh-tool-bash`, or by a builtin such as `cordis:group`. The TypeScript loader resolves the name through Node's module resolution relative to the file that mentions it. The Racket harness must accept the same rows, and "a ported plugin always runs" is a requirement of the porter.

## Considered options

1. Rewrite configuration files to Racket module paths.
2. Derive a module path from the npm name by a naming rule.
3. A resolver chain keyed by the npm name.

## Decision

Option 3. The resolver tries, in order:

1. Loader builtins (`cordis:group`, `cordis:include`, and the rest of the vendored set).
2. The native table: every Racket package provides `<package>/plugins` with `plugin-table`, a list of `(cons npm-name module-path)`. `dsh-boot` joins the tables. A module in the table provides `plugin`.
3. Ported plugins installed in the profile: output of the plugin porter under the Harness home, recorded in the profile's plugin list with the npm name they stand for.
4. A relative path in the row (`./my-plugin.rkt`, or a `.mjs`/`.ts` path), resolved against the file's `baseUrl`; a Racket file loads natively, a JavaScript file goes to step 5.
5. The Node sidecar: the original JavaScript package is loaded in a Node process that talks to the Racket kernel over a pipe, if `node` and the package are available.
6. Otherwise mounting fails with an error that names the row, the name, and which of the steps above were tried.

`dsh --dump-config` prints, for each row, which step resolved it. A Racket-only plugin uses a name starting with `racket:`.

## Consequences

- Good: configuration is untouched; the same file works in dsh and in the Racket harness.
- Good: the fallback order is the porter's promise: native, then translated, then wrapped, and never silently skipped.
- Good: the table is data, so the parity document and a test can check that every plugin name used by the shipped bundles resolves.
- Bad: the native table must be kept in step with the modules. A test in each package loads every entry of its table.
- Rejected option 1 because it breaks the compatibility requirement, and option 2 because one Racket package covers many npm packages, so no rule fits.
