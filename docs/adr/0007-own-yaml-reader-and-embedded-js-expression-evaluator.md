# 0007. Own YAML reader and an embedded evaluator for `!!js` expressions

- Status: accepted
- Date: 2026-11-13

## Context and problem statement

A dsh `cordis.yml` patch must load unchanged. These files are YAML with one custom tag, `!!js`, whose scalar is a JavaScript expression (`process.platform === 'win32'`, `process.getBuiltinModule('node:path').join(...)`, `ctx.headlessStartup.x`). The TypeScript loader parses them with js-yaml and evaluates the expressions in Node. The Racket loader has neither.

## Considered options

1. Depend on the third-party Racket `yaml` package and shell out to Node for every `!!js` expression.
2. Depend on the `yaml` package and write a JavaScript-subset evaluator.
3. Write a reader and writer for the dialect in the package `cordis-yaml`, with an embedded evaluator for the expression subset the shipped files use, and a hook that lets a host delegate unsupported expressions to Node.

## Decision

Option 3.

- `cordis-yaml` reads the YAML constructs the corpus uses into the `cordis-data` value model, keeps `!!js` scalars as unevaluated `js-expr` values, and writes block-style YAML that js-yaml can load.
- `cordis-yaml/js-expr` is a tokenizer and precedence-climbing parser that produces an S-expression AST, and an evaluator over that AST with JavaScript semantics for truthiness, equality, `+`, `??`, `?.` and the conditional operator. Host objects (`process`, `ctx`, `JSON`, `URL`, the `node:path` and `node:module` builtins) are supplied by the embedder through a small generic interface.
- An expression outside the subset raises an error that names the construct. A parameter, `current-js-fallback`, is consulted first, so the harness can send such an expression to a Node process when one is available.
- The test corpus is every YAML file and every distinct `!!js` expression in the repository at the pinned commit.

## Consequences

- Good: the loader has no third-party dependency and no need for Node in the common case; `raco test` is hermetic.
- Good: the evaluator's AST is plain data, which the guide uses to show a parser, an evaluator and code-as-data in one small place, and which the plugin porter can reuse for declarative fragments.
- Good: unsupported input fails loudly instead of being guessed.
- Bad: the subset is defined by a corpus. A user-written patch may use JavaScript the evaluator does not know; it then needs Node through the fallback, or a rewrite.
- Bad: a YAML reader is code to maintain. It is limited to the constructs js-yaml's default schema and the dsh files exercise.
- Rejected option 1 because a profile could then not load without Node, and option 2 because the `yaml` package would be the only third-party dependency of the configuration path and does not preserve what the writer needs.
