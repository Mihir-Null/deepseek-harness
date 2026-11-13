#!/usr/bin/env node
// Generates the differential table that tests/js-yaml-table-test.rkt checks cordis-yaml against.
// Every expected result is computed by js-yaml 4.3.2 with the dsh schema (JSON schema plus the
// `!!js` scalar type of vendor/include/src/index.ts) or by Node evaluating an expression the
// way vendor/loader/src/config/utils.ts does (`with (ctx) { return eval(expr) }`).
//
//   mkdir /tmp/x && cd /tmp/x && npm install js-yaml@4.3.2
//   node tests/gen/gen-js-yaml-table.mjs --js-yaml /tmp/x
//       rewrites tests/data/js-yaml-table.rktd
//
// Options: --js-yaml DIR (a directory whose node_modules holds js-yaml; required),
// --repo DIR (the repository root; default: four levels above this file), --out FILE,
// --seed N, --cwd DIR (working directory of the real-process environments; default /tmp),
// --random-dumps N (random values in the dump section; default 400), --fuzz-load N (adds N
// mutated corpus files to the load-all section; default 0, for tests/gen/fuzz.rkt).
// The repository has no node_modules, so js-yaml is loaded from the directory given.
//
// The output is one Racket datum. A value is encoded so that Racket's reader rebuilds it
// without the code under test: an object is a list of (key . value) pairs in JavaScript's
// enumeration order, an array is a vector, null and undefined are the symbols of those names,
// an expression node is (js "source"), a URL is (url "href"), a function is (function).
// The same seed gives the same file on the same Node version and platform.

import { spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import { dirname, join, posix, relative, win32 } from 'node:path'
import { fileURLToPath } from 'node:url'

const BS = String.fromCharCode(92)
const cp = (...codes) => String.fromCodePoint(...codes)

// ---------------------------------------------------------------------------------------------
// Racket literals

function rktString(s) {
  if (!s.isWellFormed()) throw new Error('a Racket string cannot hold a lone surrogate')
  let out = '"'
  for (let i = 0; i < s.length; i++) {
    const unit = s.charCodeAt(i)
    if (unit >= 0x20 && unit < 0x7f && unit !== 0x22 && unit !== 0x5c) out += s[i]
    else out += BS + 'u' + unit.toString(16).padStart(4, '0')
  }
  return out + '"'
}

function rktNumber(n) {
  if (Number.isNaN(n)) return '+nan.0'
  if (n === Infinity) return '+inf.0'
  if (n === -Infinity) return '-inf.0'
  if (Object.is(n, -0)) return '-0.0'
  if (Number.isSafeInteger(n)) return String(n)
  const text = String(n)
  return /[.e]/.test(text) ? text : text + '.0'
}

// The Racket literal of a JavaScript value. An object member whose value is undefined is left
// out, because the Racket value model has no such member.
function rkt(value) {
  if (value === undefined) return 'undefined'
  if (value === null) return 'null'
  if (value === true) return '#t'
  if (value === false) return '#f'
  if (typeof value === 'number') return rktNumber(value)
  if (typeof value === 'string') return rktString(value)
  if (typeof value === 'function') return '(function)'
  if (Array.isArray(value)) return '#(' + value.map(rkt).join(' ') + ')'
  if (value instanceof URL) return '(url ' + rktString(value.href) + ')'
  const proto = Object.getPrototypeOf(value)
  if (proto !== Object.prototype && proto !== null) {
    return '(object ' + rktString(Object.prototype.toString.call(value)) + ')'
  }
  const keys = Object.keys(value)
  if (keys.length === 1 && keys[0] === '__jsExpr' && typeof value.__jsExpr === 'string') {
    return '(js ' + rktString(value.__jsExpr) + ')'
  }
  return '(' + keys.filter((k) => value[k] !== undefined)
    .map((k) => '(' + rktString(k) + ' . ' + rkt(value[k]) + ')').join(' ') + ')'
}

// ---------------------------------------------------------------------------------------------
// Expression evaluation, as dsh does it

// source: vendor/loader/src/config/utils.ts
const evaluate = new Function('ctx', 'expr', `
  with (ctx) {
    return eval(expr)
  }
`)

// The context object of an environment description. In 'shadow' mode it also binds `process`,
// which the `with` scope finds before the global.
function makeCtx(desc) {
  const ctx = Object.create(null)
  ctx.baseUrl = desc.baseUrl
  ctx.get = (name) => (name === 'profileContext' ? desc.profile ?? undefined : desc.services[name])
  for (const [name, service] of Object.entries(desc.services)) ctx[name] = service
  ctx.dshHomePath = (...parts) => posix.join(desc.dshHome, ...parts)
  ctx.scratch = 0
  if (desc.mode === 'shadow') {
    const realModule = process.getBuiltinModule('node:module')
    const pathModule = desc.platform === 'win32'
      ? win32
      : { ...posix, resolve: (...parts) => posix.resolve(desc.cwd, ...parts) }
    ctx.process = {
      env: { ...desc.env },
      platform: desc.platform,
      execPath: desc.execPath,
      cwd: () => desc.cwd,
      getBuiltinModule: (id) => {
        const name = id.startsWith('node:') ? id.slice(5) : id
        if (name === 'path') return pathModule
        if (name === 'module') {
          return {
            createRequire: (base) => {
              realModule.createRequire(base)
              return { resolve: (specifier) => desc.resolveRoot + '/' + specifier }
            },
          }
        }
        if (name === 'os') {
          // What Node answers when these variables are set.
          return {
            homedir: () => (desc.platform === 'win32' ? desc.env.USERPROFILE : desc.env.HOME),
            platform: () => desc.platform,
            EOL: desc.platform === 'win32' ? '\r\n' : '\n',
          }
        }
        return process.getBuiltinModule(id)
      },
    }
  }
  return ctx
}

function evaluateAll(desc, sources) {
  const ctx = makeCtx(desc)
  return sources.map((source) => {
    try {
      return '(ok ' + rkt(evaluate(ctx, source)) + ')'
    } catch (error) {
      const name = error instanceof Error ? error.name : 'thrown'
      return '(error ' + rktString(name) + ' ' + rktString(String(error?.message ?? error)) + ')'
    }
  })
}

// The child half of a real-process environment: reads {desc, sources} and prints the results.
if (process.argv[2] === '--child') {
  const { desc, sources } = JSON.parse(readFileSync(0, 'utf8'))
  process.stdout.write(JSON.stringify(evaluateAll(desc, sources)))
  process.exit(0)
}

// ---------------------------------------------------------------------------------------------
// Arguments

function parseArgs(argv) {
  const args = {}
  for (let i = 0; i < argv.length; i += 2) {
    if (!argv[i].startsWith('--') || argv[i + 1] === undefined) {
      throw new Error('usage: gen-js-yaml-table.mjs --js-yaml DIR [--repo DIR] [--out FILE] ' +
        '[--seed N] [--cwd DIR] [--random-dumps N] [--fuzz-load N]')
    }
    args[argv[i].slice(2)] = argv[i + 1]
  }
  return args
}

const args = parseArgs(process.argv.slice(2))
if (!args['js-yaml']) throw new Error('--js-yaml DIR is required')
const here = dirname(fileURLToPath(import.meta.url))
const repoRoot = args.repo ?? join(here, '..', '..', '..', '..')
const outPath = args.out ?? join(here, '..', 'data', 'js-yaml-table.rktd')
const seed = Number(args.seed ?? 20261113)
const realCwd = args.cwd ?? '/tmp'
const randomDumpCount = Number(args['random-dumps'] ?? 400)
const fuzzLoadCount = Number(args['fuzz-load'] ?? 0)

const require = createRequire(join(args['js-yaml'], 'package.json'))
const yaml = require('js-yaml')
const yamlVersion = require('js-yaml/package.json').version

// source: vendor/include/src/index.ts
const isJsExpr = (value) => value instanceof Object && '__jsExpr' in value
const JsExpr = new yaml.Type('tag:yaml.org,2002:js', {
  kind: 'scalar',
  resolve: (data) => typeof data === 'string',
  construct: (data) => ({ __jsExpr: data }),
  predicate: isJsExpr,
  represent: (data) => data['__jsExpr'],
})
const entryListSchema = yaml.JSON_SCHEMA.extend(JsExpr)

function mulberry32(state) {
  return () => {
    state = (state + 0x6d2b79f5) | 0
    let t = Math.imul(state ^ (state >>> 15), 1 | state)
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}
const rand = mulberry32(seed)
const int = (n) => Math.floor(rand() * n)
const pick = (xs) => xs[int(xs.length)]
const chance = (p) => rand() < p

const sha256 = (text) => createHash('sha256').update(text, 'utf8').digest('hex')

// ---------------------------------------------------------------------------------------------
// Section: corpus

function walk(dir, out) {
  for (const name of readdirSync(dir).sort()) {
    if (name === 'node_modules') continue
    const path = join(dir, name)
    if (statSync(path).isDirectory()) walk(path, out)
    else if (name.endsWith('.yml')) out.push(path)
  }
}

const corpusFiles = []
for (const top of ['packages', 'apps', 'snapshots']) walk(join(repoRoot, top), corpusFiles)

const corpusExpressions = new Map()
function collectExpressions(value) {
  if (!value || typeof value !== 'object') return
  if (isJsExpr(value)) {
    corpusExpressions.set(value.__jsExpr, (corpusExpressions.get(value.__jsExpr) ?? 0) + 1)
  } else if (Array.isArray(value)) value.forEach(collectExpressions)
  else Object.values(value).forEach(collectExpressions)
}

// (path content-sha256 json-sha256 dump-sha256): the JSON text of js-yaml's documents and the
// text js-yaml dumps for them, as digests.
const corpusRows = corpusFiles.map((path) => {
  const text = readFileSync(path, 'utf8')
  const documents = yaml.loadAll(text, { schema: entryListSchema })
  documents.forEach(collectExpressions)
  const dumped = documents
    .map((document) => yaml.dump(document, { schema: entryListSchema, noRefs: true }))
    .join('---\n')
  if (rkt(yaml.loadAll(dumped, { schema: entryListSchema })) !== rkt(documents)) {
    throw new Error('js-yaml does not read back its own dump of ' + path)
  }
  return '(' + [
    rktString(relative(repoRoot, path).split(/[\\/]/).join('/')),
    rktString(sha256(text)),
    rktString(sha256(JSON.stringify(documents))),
    rktString(sha256(dumped)),
  ].join(' ') + ')'
})

// ---------------------------------------------------------------------------------------------
// Section: load, load-all, load-json

const BOM = cp(0xfeff)
const NEL = cp(0x85)
const NBSP = cp(0xa0)
const LS = cp(0x2028)
const E_ACUTE = cp(0xe9)
const SMILE = cp(0x1f600)
const dq = (body) => '"' + body + '"'

const loadTexts = [
  // ---- null ----
  '~', 'null', 'Null', 'NULL', 'nUll', 'a:', 'a: ~', '- ', '-',
  'a: null\nb: Null\nc: NULL\nd: nuLL',
  '[~, null, , x]', '{a: , b: ~}', '',
  ' ', '\n', '# only a comment', '# c\n\n', '---', '--- ', '---\n', '--- # c', '...', '---\n...',
  // ---- booleans ----
  'true', 'True', 'TRUE', 'false', 'False', 'FALSE', 'tRue', 'yes', 'no', 'on', 'off', 'y', 'n',
  'Yes', 'NO', 'On', 'OFF', '[true, false, yes, no]',
  // ---- integers ----
  '0', '12', '+12', '-12', '012', '0012', '-012', '0x1F', '0x1f', '-0x1F', '+0x1f', '0X1F',
  '0o17', '-0o17', '+0o17', '0O17', '0b101', '-0b101', '+0b101', '0B101', '0o', '0x', '0b',
  '0o8', '0b2', '0xG', '1_000', '0x_1', '-0', '+0', '00', '-', '+', '--1', '1-', '1 2', '0o777',
  '9007199254740993', '-9007199254740993', '123456789012345678901234567890', '0x1FFFFFFFFFFFFFF',
  cp(0x663), '12abc', '0x1g', '1e', '0.', '0e0', '+', '0b', '-0b1', '0b12', '0o78',
  // ---- floats ----
  '1.5', '-1.5', '+1.5', '1.', '.5', '-.5', '+.5', '1e3', '1E3', '1e+3', '1e-3', '1.5e3', '.5e1',
  '1.e3', '-1e3', '+1e3', '1e', '1e+', 'e3', '1.5.5', '1_000.5', '.inf', '-.inf', '+.inf', '.Inf',
  '.INF', '-.Inf', '.iNf', '.nan', '.NaN', '.NAN', '-.nan', '+.nan', '.nAn', 'inf', 'nan',
  'Infinity',
  'NaN', '0.0', '-0.0', '+0.0', '1e400', '-1e400', '1e-400', '0.1', '4.35', '1e21', '1e-7',
  '123456789.123456789', '0.30000000000000004', '5e-324', '1.7976931348623157e308', '00.5', '01.5',
  '0x1.8', '1.0', '100.0', '-0e0', '.e3', '.', '..', '1..2',
  // ---- strings and plain scalars ----
  'a', 'a b', 'a  b', ' a ', 'a: b', 'a:b', 'a :b', 'a # c', 'a#c', 'a #', 'http://x/y', 'a: b: c',
  'a: http://x:80/y', '-a', '- -a', '-1a', '?a', ':a', 'a:', 'a?', 'a-', '@a', '`a', '%a', '!a',
  '&a', '*a', '|a', '>a', "'", '"', 'a\nb', 'a\n b', 'a\n\nb', 'a\n\n\nb', 'a\n  b\n c', 'a \nb',
  'a\t\nb', 'key: a\n  b\n  c', 'key: a\n\n  b', '- a\n  b', '- a\n b', 'a: b\n c', 'a:\n  b\n  c',
  'a, b', 'a [b] c', 'a {b} c', 'a ] b', '[a, b c, d]', '[a\n b]', '{a: b\n c}', 'x: a,b',
  'x: [a,b]',
  'x: a]b', 'x: [a]b]', E_ACUTE + ': ' + SMILE, SMILE, 'k: ' + NBSP + 'v', 'k: a' + NEL + 'b',
  'k: a' + LS + 'b', BOM + 'a: 1', BOM, BOM + '\n', 'a: 1' + BOM, 'null: 1', 'true: 1', '1: a',
  '1.5: a', '0x10: a', '~: a', 'Null: a\nnull: b', '? a\n: b', '? a', '? a\n? b', '?', '? \n: ',
  '? [a, b]\n: c', '? {a: b}\n: c', '[a, b]: c', '{a: b}: c', '? - a\n  - b\n: c', '[[a]]: c',
  '? |\n  lit\n: v', '? a\n  b\n: c', 'a: 1\n? b\n: 2\nc: 3', '? a\n: b\n: c',
  // ---- single-quoted ----
  "''", "'a'", "'a b'", "'it''s'", "''''", "'a\nb'", "'a\n\nb'", "'a\n  b'", "'a  \n  b'", "' a '",
  "'#'", "'a: b'", "'" + BS + "n'", "'true'", "'12'", "'~'", "'a", "'a\n---\nb'", "'a\n...\nb'",
  "k: 'v' # c", "k: 'v'x", "'a'b", "'a' 'b'", "'a':'b'", "'a': 'b'", "['a', 'b']",
  "'" + SMILE + "'",
  "'a\t\n\tb'", "'\n'", "'\n\n'", "'a\n'", "'\na'",
  // ---- double-quoted ----
  dq(''), dq('a'), dq('a b'), dq(BS + 'n'), dq(BS + 't'), dq(BS + BS), dq(BS + '"'), dq(BS + '/'),
  dq(BS + '0'), dq(BS + 'a'), dq(BS + 'b'), dq(BS + 'v'), dq(BS + 'f'), dq(BS + 'r'),
  dq(BS + 'e'), dq(BS + ' '), dq(BS + '\t'), dq(BS + 'N'), dq(BS + '_'), dq(BS + 'L'),
  dq(BS + 'P'), dq(BS + 'x41'), dq(BS + 'u0041'), dq(BS + 'U00000041'), dq(BS + 'u263A'),
  dq(BS + 'U0001F600'), dq(BS + 'xe9'), dq(BS + 'x4'), dq(BS + 'u004'), dq(BS + 'U0000004'),
  dq(BS + 'xZZ'), dq(BS + 'q'), dq(BS + "'"), dq(BS + 'U00110000'), dq('a' + BS + '\nb'),
  dq('a' + BS + '\n  b'), dq('a ' + BS + '\n  b'), dq('a\nb'), dq('a\n\nb'), dq('a\n  b'),
  dq('a  \n  b'), dq(' a '), dq('a\n---\nb'), dq('a\n...\nb'), '"a', dq('a') + 'b', dq('a') + ': 1',
  dq('a: b'), dq('#'), dq('true'), dq('12'), '[' + dq('a') + ', ' + dq('b') + ']', dq(SMILE),
  dq('a' + BS + 'tb' + BS + 'nc'), dq(BS), dq('\n'), dq('a\n'), dq('\na'), dq('a\t\n\tb'),
  dq(BS + 'x00'), dq('\x01'), dq(BS + 'u00e9' + BS + 'u00E9'), 'k: ' + dq('v') + ' # c',
  // ---- literal block scalars ----
  '|\n a\n b', '|\n a\n b\n', '|-\n a\n b\n', '|+\n a\n b\n', '|+\n a\n\n\n', '|-\n a\n\n\n',
  '|\n a\n\n\n', '|\n\n a', '|\n a\n\n b', '|\n  a\n   b\n  c', '|\n a\n  b\n c\n', '|2\n   a\n  b',
  '|1\n  a', '|1-\n  a\n', '|-1\n  a\n', '|+2\n   a\n\n', '|2+\n   a\n\n', '|0\n a', '|10\n a',
  '|--\n a', '|12\n a', '| # c\n a', '|  \n a', '| x\n a', '|\n', '|', '|-', '|+', '|\n\n',
  '|+\n\n',
  '|-\n\n', 'k: |\n  a\n  b\nj: 1', 'k: |\n  a\nj: 1', 'k: |\n\n  a\n\nj: 1', 'k: |+\n  a\n\nj: 1',
  'k: |-\n  a\n\nj: 1', '- |\n  a\n- b', '- |\n a\n- b', 'k: |\n a\n b\n', 'k: |\n   a\n  b\n',
  'k: |\n a\n\tb', 'k: |\n\ta', 'k: |\n a\t\n b', 'k: |\n a  \n b  ', 'k: |\n  # not a comment\n',
  'k: |\n a\n# comment\nj: 2', 'k: |\n  a\n ', 'k: |\n  a\n  \n  b', 'k: |\n  a\n   \n  b',
  'k: |\n  ' + SMILE + '\n', '|\n a\r\n b\r\n', '|\r a\r b', '--- |\n a\n', '--- |\na\n',
  'k: |\n  a\n...\n', 'a: |\n  x\n---\nb: 1', '- - |\n    a\n  - b', 'k: |2\n    a\n   b\n',
  // ---- folded block scalars ----
  '>\n a\n b', '>\n a\n b\n', '>-\n a\n b\n', '>+\n a\n b\n', '>\n a\n\n b\n', '>\n a\n\n\n b\n',
  '>\n a\n  b\n c\n', '>\n a\n\n  b\n\n c\n', '>\n  a\n b', '>\n a\n   b\n   c\n d\n',
  '>\n\n a\n b\n', '>\n a\n b\n\n\n', '>+\n a\n b\n\n\n', '>-\n a\n b\n\n\n', '>2\n   a\n  b\n',
  '>\n a \n b\n', '>\n a\n \n b\n', '>\n a\n\t\n b\n', '>\n a\n\tb\n', '>\n', '>', '>-', '>+\n\n',
  'k: >\n  a\n  b\nj: 1', 'k: >-\n  a\n\n  b\n\n', 'k: >\n  a\n\n\n   b\n  c\n\n  d\n   e\n',
  '- >\n  a\n  b\n- c', 'k: >\n  a b\n  c  d\n', 'k: >\n   a\n  b\n', '>\n a\r\n b\r\n',
  '>1\n  a\n b\n',
  // ---- block mappings ----
  'a: 1', 'a: 1\nb: 2', 'a: 1\nb:\n  c: 2\n  d: 3\ne: 4', 'a:\n  b:\n    c:\n      d: 1',
  'a:\n- 1\n- 2', 'a:\n  - 1\n  - 2', 'a:\n - 1\n - 2\nb: 3', 'a: 1\na: 2', 'a: 1\nb: 2\na: 3',
  'a:\n  b: 1\n  b: 2', '{a: 1, a: 2}', 'a: 1\n b: 2', 'a: 1\n  b: 2', ' a: 1\nb: 2',
  '  a: 1\n  b: 2',
  ' a: 1\n  b: 2', 'a:\n  b: 1\n c: 2', 'a:\n    b: 1\n  c: 2', 'a:\tb', 'a:\t1', 'a: \t1',
  '\ta: 1',
  'a: 1\n\tb: 2', 'a:\n\tb: 1', 'a:\n  b: 1\n\tc: 2', '- a\n\t- b', 'a : 1', 'a  :  1', 'a:1',
  'a: b:c', 'a:\n  b', 'a:\nb', 'a:\n\nb: 1', 'a: # c\n  1', 'a: 1 # c\nb: 2 # d', '# c\na: 1',
  'a: 1\n# c\nb: 2', 'a: 1\n  # c\nb: 2', 'a:\n  # c\n  b: 1', 'key with spaces: v', 'a.b: 1',
  'a/b: 1',
  '"a b": 1', "'a b': 1", 'a: b\nc', 'a\nb: c', 'a: b\n  c: d', 'a: [1\n]', 'a: {b: 1\n}',
  'a: - b', 'a: -b', '- a: 1\n  b: 2', '- a: 1\n- b: 2', '- a:\n    b: 1', '-  a: 1\n   b: 2',
  '- a: 1\n b: 2', '- a: 1\n   b: 2', 'a:\n  - b: 1\n    c: 2\n  - d: 3', 'x: 1\ny: 2\n\n\nz: 3',
  '<<: {a: 1}\nb: 2', 'a: &x {b: 1}\nc:\n  <<: *x\n  d: 2', '=: 1', '!: 1', 'a: =', 'a: <<',
  // ---- block sequences ----
  '- a', '- a\n- b', '- - a\n  - b\n- c', '- - - a', '-\n  a', '-\n  - a\n  - b', '- a\n  - b',
  '- a\n - b', ' - a\n - b', '  - a\n  - b', '- a\n-b', '- a\n-', '-\n-\n-', '- \n- \n',
  '- a\n\n- b',
  '- a # c\n- b', '# c\n- a', '- [a, b]\n- {c: d}', '- a\nb: c', '- a\n- b: c\n  d: e\n- f',
  '-\ta', '- \ta', '-a', '- - a\n- b\n  - c', 'a:\n- b\n- c\nd: e', 'a:\n-\n  b',
  '- |\n  x\n- >\n  y',
  '- ? a\n  : b', '- - - - - - a', '-   a\n-   b',
  // ---- flow collections ----
  '[]', '{}', '[a]', '[a, b]', '[a, b, ]', '[a,b]', '[ a , b ]', '[\n  a,\n  b\n]', '[a, [b, [c]]]',
  '[{a: 1}, {b: 2}]', '{a: [1, 2], b: {c: d}}', '{a: 1, b: 2}', '{a: 1, b: 2, }', '{ a : 1 }',
  '{a:1}', '{a: 1,b: 2}', '{a, b}', '{a: }', '{: a}', '{a: 1, : 2}', '{"a":1}', '{"a":1,"b":[1,2]}',
  "{'a':1}", '{a: b: c}', '[a: 1]', '[a: 1, b: 2]', '[a: 1, b]', '[? a : 1]', '[? a]', '{? a : 1}',
  '{? a}', '[a:]', '[: a]', '[a, , b]', '[, a]', '[,]', '{,}', '{a: 1,, b: 2}', '[a', '{a: 1',
  '[a}',
  '{a]', ']', '}', '[a] b', '[a]b', '{a: 1} b', '[a]: b', '[a, b]: c\nd: e', 'a: [b\nc: d]',
  '[a # c\n, b]', '[a, # c\n b]', '{a: 1 # c\n}', '[\n# c\n]', '[a,\n\n b]', '[ [], {} ]',
  '{a: [], b: {}}',
  'k: [a, b]\nj: {c: d}', 'k: []\nj: {}', '- []\n- {}', '[1, 2.5, true, null, ~, "s", \'t\']',
  '[a b, c d]', '{a b: c d}', '[http://x/y, a:b]', '{a: http://x/y}', '[a, b]\n', '[a, b] # c',
  '[!!js a, !!str 1]', '{x: !!js "a ? b : c"}', '[-]', '[- a]', '[-a]', '[a-]', '{a: -}', '{-: a}',
  '[?]', '[?a]', '[a?]', '{?: a}', '[|]', '[>]', '[%a]', '[@a]', '[`a]', '{a: |}', '[a,b,c,]',
  '[[[[[[[[[[a]]]]]]]]]]', '{a: {b: {c: {d: {e: 1}}}}}', '["a" : 1]', '["a":1]', '[a :1]',
  '{"a" :1}', '{"a":b}', '{a:b}', '{a:b, c:d}', '[\'a\':1]', '{a: [b, c]: d}', '[a, b]: [c, d]',
  // ---- anchors and aliases ----
  'a: &x 1\nb: *x', '- &x a\n- *x\n- *x', 'a: &x [1, 2]\nb: *x', 'a: &x {b: 1}\nc: *x',
  'a: &x\n  b: 1\nc: *x', '&x a: 1\nb: *x', 'a: *x', '- *x', 'a: &x 1\nb: &x 2\nc: *x', '&x',
  '&x a',
  '& a', '*', '* a', 'a: &x', 'a: &x\nb: *x', 'a: &x ~\nb: *x', '[&x a, *x]', '{a: &x 1, b: *x}',
  '&x [a, *x]', '- &x a\n- &y b\n- [*x, *y]', 'a: &x b\n*x : c', '*x', '&a &b c', 'a: &x &y 1',
  '&x\n- a\n- b', '&x\na: 1', 'a: &x |\n  lit\nb: *x', 'a: &x "q"\nb: *x', 'a: &x !!str 1\nb: *x',
  'a: !!str &x 1\nb: *x', 'a: &x-y.z 1\nb: *x-y.z', 'a: &' + E_ACUTE + ' 1\nb: *' + E_ACUTE,
  '- &x\n- *x', 'a: &x 1\nb: *x # c', 'a: *x b', '- *x b', '*x: 1', 'a: &x 1\n*x: 2',
  '&x a: &y b\n*x: *y', 'a: &x 1\nb: !!str *x', 'a: &x 1\nb: &y *x',
  // ---- tags ----
  '!!str 1', '!!str true', '!!str ~', '!!str', '!!str [a]', '!!str {a: 1}', '!!int 12',
  '!!int "12"',
  '!!int 0x1F', '!!int a', '!!int 1.5', '!!int', '!!float 1', '!!float "1.5"', '!!float .inf',
  '!!float a', '!!float 0x1F', '!!bool true', '!!bool "false"', '!!bool yes', '!!bool 1',
  '!!null ~',
  '!!null null', '!!null ""', '!!null', '!!null a', '!!seq [a]', '!!seq\n- a', '!!seq', '!!seq a',
  '!!seq {a: 1}', '!!map {a: 1}', '!!map\na: 1', '!!map', '!!map a', '!!map [a]', '!!js 1 + 2',
  '!!js "a ? b : c"', "!!js 'x'", '!!js |\n  a +\n  b\n', '!!js >\n  a +\n  b\n', '!!js', '!!js ~',
  '!!js ""', '!!js [a]', '!!js {a: 1}', 'a: !!js', 'a: !!js\nb: 1', '- !!js\n- a', '!!js\n  a',
  '!!js\n  a\n  b', 'a: !!js b c', 'a: !!js b: c', 'a: !!js true', 'a: !!js 12', 'a: !!js null',
  "a: !!js 'it''s'", 'a: !!js ' + dq('q' + BS + '"' + BS + 'n'), '[!!js a, !!js b]',
  '{a: !!js b}', '!!js a: 1', '? !!js a\n: 1', '!js a', '!local a', '! a', '! 1', '! true', '!\n a',
  '!!binary aGk=', '!!timestamp 2001-01-01', '!!set {a}', '!!omap [a: 1]', '!!pairs [a: 1]',
  '!!merge a', '!!foo a', '!<tag:yaml.org,2002:str> 1', '!<tag:yaml.org,2002:js> a + b',
  '!<tag:yaml.org,2002:int> 5', '!<!local> a', '!<> a', '!<tag:yaml.org,2002:str a', '!!str!x a',
  '!a!b c', '!!st%72 1', '!!st%7 1', '!!st%zz 1', '!!str,x a', '!!s{tr a', '!e!x a',
  '!!str !!int 1',
  'a: !!str\n  b', 'a: !!str |\n  1\n', 'a: !!int |\n  1\n', 'a: !!int |-\n  1\n', '- !!str\n- a',
  '!!str a: 1', 'a: !!str 1 # c', '!!str\na: 1', '!!map\n- a', '!!seq\na: 1', 'a: !!seq\n- b',
  'a: !!map\n  b: 1', '!!str &x a', '&x !!str a', '!!int -0', '!!int +5', '!!float -0',
  '!!float 1e3',
  '!!float .NaN', '!!int 0b11', '!!int 0o17', '!!int 1_000', '!!float 1_0.5', '!!bool True',
  '!!bool tRue', '!!null Null', '!!null NULL', '!!str "a\nb"', "!!js 'a\n  b'",
  // ---- directives and documents ----
  '%YAML 1.2\n---\na', '%YAML 1.1\n---\na', '%YAML 1.3\n---\na', '%YAML 2.0\n---\na',
  '%YAML 1\n---\na',
  '%YAML 1.2 x\n---\na', '%YAML\n---\na', '%YAML 1.2\n%YAML 1.2\n---\na', '%YAML 1.2\na',
  '%TAG !e! tag:example.com,2000:\n---\n!e!x a', '%TAG !e! tag:yaml.org,2002:\n---\n!e!str 1',
  '%TAG ! tag:yaml.org,2002:\n---\n!str 1', '%TAG !! tag:yaml.org,2002:s\n---\n!!tr 1',
  '%TAG !e! tag:yaml.org,2002:\n%TAG !e! x\n---\na', '%TAG !e!\n---\na', '%TAG e tag:x\n---\na',
  '%TAG !e! tag:yaml.org,2002:j\n---\n!e!s a + b', '%FOO bar\n---\na', '%FOO\n---\na', '% \n---\na',
  '%\n---\na', '%YAML 1.2 # c\n---\na', '# c\n%YAML 1.2\n---\na', '--- a', '--- a\n...',
  '---\na\n...\n',
  'a\n...', 'a\n...\n', 'a\n... # c', 'a\n...\nb', 'a\n---\nb', '--- a\n--- b', '---\n---',
  'a: 1\n---',
  '---a', '--- |\n a', '--- >\n a\n b', '--- [a]', '--- {a: 1}', '---\n- a', '--- - a', '--- a: 1',
  '--- !!str 1', '--- &x a', '...\na', '--- a\n... \n', '---\t\na', '----', '--', '- --- a',
  'a: ---',
  'a: ...', '- ...', '---x', '...x', '-- -', 'a\n--- b\n', ' ---', ' ...', 'a: 1\n ...',
  // ---- line ends, tabs, odd input ----
  'a: 1\r\nb: 2\r\n', 'a: 1\rb: 2\r', 'a: 1\r\n\r\nb: 2', '- a\r- b', 'a: |\r\n  x\r\n  y\r\n',
  'a: "x\r\n  y"', "a: 'x\r\n\r\n  y'", 'a: x\r\n  y', 'a: 1\n\n\n', '\n\na: 1', '\r\na: 1',
  'a: 1 ', 'a: 1\t', 'a: 1\t# c', 'a:\t# c\n  1', 'a: "b"\t', '- a\t', '[a,\tb]', '{a:\t1}',
  'a: b\tc',
  'a\tb: c', '\t', '\t\n', ' \t ', 'a: 1\n\t', 'a: 1\n \t \n', '\t# c', 'a: [\n\t1\n]',
  'a:\n  - b\n\t',
  'a: \x01', 'a: \x7f', 'a\x00b', '"\x7f"', "'\x01'", 'a: |\n  \x01', 'a: ' + cp(0xfffe),
  'a: "' + cp(0xfffe) + '"', NEL, 'a' + NEL + 'b: 1', 'a: ' + cp(0xd7ff) + cp(0xe000),
  // ---- depth ----
  '['.repeat(99) + 'a' + ']'.repeat(99), '['.repeat(100) + 'a' + ']'.repeat(100),
  '['.repeat(101) + 'a' + ']'.repeat(101), '- '.repeat(99) + 'a', '- '.repeat(100) + 'a',
  // ---- what the Racket writer emits where js-yaml's own dump does not read back ----
  "'...'\n", "'... a'\n", "'... a': ... a\n", dq(BS + 'n') + '\n', dq(BS + 'n' + BS + 'n') + '\n',
  dq(' a' + BS + 'nb') + '\n', dq(BS + 'n a') + '\n', dq('  a' + BS + 'n  b' + BS + 'n') + '\n',
  dq(' leading' + BS + 'nsecond') + '\n', '!!js ' + dq(BS + 'n') + '\n',
  '!!js ' + dq(' a' + BS + 'nb') + '\n',
  '!!js ...\n', '!!js ... a\n',
  // ---- error snippets ----
  'ok: 1\nline: 2\nmore: 3\nbad: [\nx: 1\ny: 2\nz: 3',
  'a: 1\nb: 2\nc: 3\nd: 4\n e: 5\nf: 6\ng: 7\nh: 8',
  'k: ' + 'x'.repeat(100) + ' "unterminated',
  'k: "' + 'y'.repeat(120) + '\n' + 'z'.repeat(100) + '\n\n---\n',
  'a:\n\tb: ' + 'w'.repeat(90),
  '- ok\n- ' + '[x, '.repeat(30) + '}',
  'a: 1\n' + E_ACUTE + ': [',
  'l1\n'.repeat(12) + 'a: [',
]

// A cyclic structure and a lone surrogate have no encoding here; such rows are left out.
function loadRow(text, options, name) {
  try {
    const value = name === 'load-all'
      ? yaml.loadAll(text, options)
      : yaml.load(text, options)
    let literal
    try {
      JSON.stringify(value)
      literal = rkt(value)
    } catch {
      return null
    }
    return '(' + rktString(text) + ' (ok ' + literal + '))'
  } catch (error) {
    if (error?.name !== 'YAMLException') throw error
    const mark = error.mark
    return '(' + rktString(text) + ' (error ' + [
      rktString(error.reason),
      mark ? mark.line + 1 : '#f',
      mark ? mark.column + 1 : '#f',
      mark ? mark.position : '#f',
      rktString(error.message),
    ].join(' ') + '))'
  }
}

const wellFormed = (text) => text.isWellFormed()
const loadRows = [...new Set(loadTexts)].filter(wellFormed)
  .map((text) => loadRow(text, { schema: entryListSchema }, 'load'))
  .filter((row) => row !== null)

const namedLoadRows = ['a: [', 'a: 1\na: 2', 'ok: 1\n\tbad', '"x', '- a\n -b: [']
  .map((text) => loadRow(text, { schema: entryListSchema, filename: 'conf/cordis.yml' }, 'load'))

const loadAllTexts = [
  '', ' ', '\n', '# c', 'a', '--- a', 'a\n---\nb', '--- a\n--- b\n--- c', '---\n---\n---',
  '---\n...\n---\n...',
  'a\n...\nb', 'a\n...\n---\nb', 'a: 1\n---\n- b\n---\n!!js c', '--- |\n x\n--- >\n y\n', '...',
  '...\n...',
  '%YAML 1.2\n---\na\n...\n%YAML 1.2\n---\nb',
  '%TAG !e! tag:yaml.org,2002:\n---\n!e!str 1\n---\n!e!str 2',
  'a: &x 1\n---\nb: *x', '--- a\n---', '---\na\n--- # c\nb', 'a\n--- [', '--- "a\n---\nb"',
  BOM + '--- a\n--- b',
  '--- a ...', 'a ---', '---\n- 1\n- 2\n---\nk: v\n...\n# trailing', '---\n\n---\n\n',
]
// Mutated corpus files: characters inserted and removed, lines re-indented, swapped, dropped
// and repeated. Most of them are errors, whose reason and position must agree too.
const fuzzInserts = [
  ' ', '  ', '\n', '\t', ':', ': ', '- ', '-', '#', ' #', '"', "'", '[', ']', '{', '}', ',', '&a ',
  '*a', '!', '!!str ', '!!js ', '|', '>', '|-', '>+', '|2', '?', '? ', '%', '@', '`', '---', '...',
  '\n---\n', '\n...\n', BS, BS + 'n', '~', 'null', 'true', '0x1F', '1e3', '.inf', '\r', '\r\n',
  'a: b', '\n  ', '\n- ', '<<', '=', '%YAML 1.2\n---\n', '\x00', '\x07']
function mutate(text) {
  const editLines = (edit) => {
    const lines = text.split('\n')
    edit(lines, int(lines.length))
    text = lines.join('\n')
  }
  for (let k = 1 + int(3); k > 0; k--) {
    const at = int(text.length + 1)
    switch (int(6)) {
      case 0: text = text.slice(0, at) + pick(fuzzInserts) + text.slice(at); break
      case 1: text = text.slice(0, at) + text.slice(at + 1 + int(3)); break
      case 2: editLines((lines, i) => {
        lines[i] = ' '.repeat(int(4)) + lines[i].trimStart()
      }); break
      case 3: editLines((lines, i) => {
        const j = int(lines.length)
        const line = lines[i]
        lines[i] = lines[j]
        lines[j] = line
      }); break
      case 4: editLines((lines, i) => { lines.splice(i, 1 + int(2)) }); break
      default: editLines((lines, i) => { lines.splice(i, 0, lines[int(lines.length)]) })
    }
  }
  return text
}
const fuzzSeeds = fuzzLoadCount > 0
  ? corpusFiles.map((path) => readFileSync(path, 'utf8')).filter((text) => text.length < 4000)
  : []
const fuzzTexts = []
while (fuzzTexts.length < fuzzLoadCount) {
  const text = mutate(pick(fuzzSeeds)).slice(0, 1500)
  // js-yaml counts UTF-16 units in positions and cordis-yaml characters: keep to the BMP.
  if (text.isWellFormed() && [...text].length === text.length) fuzzTexts.push(text)
}
const loadAllRows = [...loadAllTexts, ...fuzzTexts]
  .map((text) => loadRow(text, { schema: entryListSchema }, 'load-all'))
  .filter((row) => row !== null)

const loadJsonTexts = [
  'a: 1', '!!js a', 'a: !!js b', '[!!str 1, !!int "2"]', '!!binary aGk=', 'a: &x 1\nb: *x',
  '{a: yes, b: 0x10, c: .inf}', '!<tag:yaml.org,2002:js> a']
const loadJsonRows = loadJsonTexts.map(
  (text) => loadRow(text, { schema: yaml.JSON_SCHEMA }, 'load'))

// ---------------------------------------------------------------------------------------------
// Section: dump

const js = (source) => ({ __jsExpr: source })
const longWords = (n, word) => Array.from({ length: n }, (_, i) => word + i).join(' ')

const dumpStrings = [
  '', 'a', 'a b', ' a', 'a ', ' ', '  ', 'a  b', 'true', 'True', 'TRUE', 'false', 'null', 'Null',
  '~', 'yes',
  'Yes', 'YES', 'no', 'No', 'on', 'On', 'ON', 'off', 'OFF', 'y', 'Y', 'n', 'N', 'nul', 'tru', '12',
  '-12', '+12',
  '012', '0x1F', '0o17', '0b11', '1.5', '.5', '-.5', '1e3', '1.', '.inf', '-.inf', '.nan', '.NaN',
  '1_000',
  '0x', '1:2', '1:2:3', '12:30:45', '-1:30', '1:2.5', '190:20:30.15', '1_0:2_0', ':', '::', '1:',
  ':1', 'a:b',
  'a: b', 'a:', ':a', 'a :b', 'a #b', 'a#b', '#a', 'a #', '# ', '-', '- a', '-a', '--', '---',
  '--- a', '...',
  '... a', '?', '? a', '?a', ',', 'a,b', 'a, b', '[', ']', '{', '}', '[a]', '{a}', 'a[b]', 'a{b}',
  '&a', '*a',
  '!a', '|', '|a', '>', '>a', "'", "'a'", "a'b", "it's", '"', '"a"', 'a"b', '%a', '@a', '`a', '=',
  '=a',
  'a=b', '<<', 'a\nb', 'a\n', '\na', '\n', '\n\n', 'a\n\n', 'a\n\nb', 'a\nb\n', 'a\nb\n\n', ' a\nb',
  'a\n b',
  '\n a', 'a \nb', 'a\n\n\n', '  a\n  b\n', 'a\tb', '\ta', 'a\t', '\t', 'a\rb', 'a\r\nb', 'a\x00b',
  'a\x07b',
  'a\x1bb', 'a\x7fb', NEL, 'a' + NEL + 'b', NBSP, 'a' + NBSP + 'b', LS, 'a' + LS + 'b', cp(0x2029),
  BOM,
  BOM + 'a', 'a' + BOM, E_ACUTE, 'caf' + E_ACUTE, SMILE, 'a' + SMILE + 'b', SMILE + '\n' + SMILE,
  cp(0xfffe), cp(0xffff), cp(0xfffd), cp(0xd7ff), cp(0xe000), cp(0x10ffff), cp(0x9f), cp(0xa1),
  'a\x08b',
  'a\x0bb', 'a\x0cb', 'x: y: z', 'key: [1, 2]', 'http://example.com/a?b=c#d', 'C:\\Users\\x',
  'a\\b',
  'a\\nb', '${HOME}', '$HOME', 'a|b', 'a>b', 'a*b', 'a&b', 'a!b', 'a%b', 'a@b', 'a`b', '(a)', 'a;b',
  'process.env.X ?? "y"', "ctx.get('profileContext')?.name !== 'desktop'", '!ctx.get("x")',
  '[a, b].includes(c)',
  '{ a: 1 }', 'a ? b : c', '- x', 'x - y', 'x -', '0', '00', '-0', '0.0', '+.inf', 'NaN',
  'Infinity',
  'null ', ' null', 'true\n', '12\n', '~\n', '1e', 'e1', '0b', '0o8', '0xg', cp(0x967, 0x968),
  'a:\tb', 'a\t#b',
  longWords(30, 'word'), longWords(30, 'word') + '\n',
  longWords(12, 'word') + '\n' + longWords(14, 'more'),
  ' ' + longWords(30, 'word'), longWords(30, 'word') + ' ', 'x'.repeat(100), 'x'.repeat(81),
  'x'.repeat(80),
  'x'.repeat(79) + ' y', 'x'.repeat(40) + ' ' + 'y'.repeat(40),
  'x'.repeat(50) + ' ' + 'y'.repeat(50),
  longWords(30, 'word') + '\n\n' + longWords(30, 'next'),
  longWords(30, 'word') + '\n  indented ' + longWords(20, 'i'),
  longWords(30, 'w') + '\n' + ' lead', '\n' + longWords(30, 'word'), longWords(30, 'word') + '\n\n',
  longWords(40, 'a') + ': ' + longWords(5, 'b'), longWords(25, SMILE),
  longWords(30, 'word') + ' #c',
  'a  ' + longWords(30, 'word'), longWords(15, 'word') + '   ' + longWords(15, 'word'),
  longWords(30, "it's"), longWords(30, 'word').replaceAll(' ', '  '),
  'line one\nline two\nline three',
  '# heading\n\ntext\n', 'tab\there\nnext', 'trailing space \nnext', 'a\n\tb', 'first\n\n\n\nlast',
  ' leading\nsecond', '\n\nleading breaks', 'x'.repeat(1025), longWords(200, 'k'),
]

const dumpValues = [
  null, true, false, 0, 1, -1, 12, 1.5, -1.5, 0.1, 1e21, 1e-7, 1.5e300, 1e300, 5e-324, 5e-100,
  -5e-100, 123456789012345680000,
  Infinity, -Infinity, NaN, -0, 9007199254740991, 9007199254740992, 0.30000000000000004, 1e100,
  1.7976931348623157e308,
  [], {}, [[]], [{}], { a: [] }, { a: {} }, [[], {}], [[[]]], { a: { b: {} } },
  [1, 2, 3], [[1, 2], [3]], [[[1]]], { a: 1 }, { a: 1, b: 2 }, { a: { b: { c: 1 } } },
  { a: [1, 2] }, { a: [[1], [2]] },
  [{ a: 1 }], [{ a: 1, b: 2 }, { c: 3 }], [{ a: [1] }], [{ a: { b: 1 } }], [[{ a: 1 }]],
  [[{ a: 1, b: 2 }], 'x'],
  { a: [{ b: 1, c: 2 }, { d: [3, 4] }] }, [null, true, 'x', 1.5], { n: null, t: true, f: false },
  js('1 + 2'), [js('a')], { disabled: js("!ctx.get('profileContext')") },
  { config: { x: js('process.env.X ?? "y"') } },
  js(''), js('a\nb'), js('a: b'), js('true'), js('12'), js("'q'"), js('"q"'),
  js(longWords(30, 'expr')),
  js('a ? b : c'), js('[1, 2]'), js('{ a: 1 }'), js('# not a comment'), js('x #c'), js(' lead'),
  js('trail '),
  [js('a'), js('b')], { a: js('x'), b: [js('y')] }, { __jsExpr: 'a', other: 1 },
  { other: 1, __jsExpr: 'b' },
  { 'a b': 1 }, { '': 1 }, { 'true': 1 }, { '12': 1 }, { 'null': 1 }, { 'a: b': 1 }, { '- a': 1 },
  { '#a': 1 },
  { 'a\nb': 1 }, { "it's": 1 }, { '"q"': 1 }, { '?': 1 }, { ':': 1 }, { '[a]': 1 }, { '{a}': 1 },
  { yes: 1 },
  { ' a': 1 }, { 'a ': 1 }, { [SMILE]: 1 }, { [longWords(30, 'key')]: 1 },
  { ['k'.repeat(1024)]: 1 },
  { ['k'.repeat(1025)]: 1 }, { ['k'.repeat(1025)]: { a: 1 } }, { ['k'.repeat(1025)]: [1] },
  [{ ['k'.repeat(1025)]: 1 }],
  { ['k'.repeat(1100) + '\nx']: 1 }, { b: 1, a: 2 }, { 2: 'a', 1: 'b', x: 'c' }, { '1.5': 1 },
  { '0x10': 1 },
  { a: 'x\ny\n' }, { a: 'x\ny' }, { a: ' x\ny' }, { a: 'x\n\n' }, { a: [1, 'x\ny\n', 2] },
  ['x\ny\n'], [['x\ny\n']],
  [{ a: 'x\ny\n' }], { a: { b: { c: 'x\ny\n' } } }, { a: longWords(30, 'word') },
  [longWords(30, 'word')],
  { a: { b: { c: { d: { e: longWords(30, 'word') } } } } }, [[[[longWords(30, 'word')]]]],
  Array.from('abcdefghijklmnopqrstuv').reduceRight(
    (inner, key) => ({ [key]: inner }), longWords(30, 'w')),
  { a: '' }, { a: ' ' }, [''], ['', ''], { a: null, b: '~' }, { a: [null] }, [[null, null]],
  { a: [[], {}] },
  {
    id: 'x', name: '@deepseek-ai/dsh-tool-bash',
    config: { timeout: 120000, shell: ['pwsh', 'powershell'], env: {} },
  },
  [{
    insert: {
      id: 'timer', name: '@deepseek-ai/cordis-plugin-timer',
      disabled: js("!ctx.get('profileContext')"),
    },
  }],
  {
    list: ['- a', '# b', 'c: d', '[e]', '{f}', '*g', '&h', '!i', '|j', '>k', "'l", '"m', '%n', '@o',
      '`p'],
  },
  { nums: [0, -0, 1e21, 1e-7, 0.5, -0.5, 1 / 3, 100, 1e5, 123456.789] },
]

// What js-yaml reads back for a dumped value: an object with a `__jsExpr` member is written as
// the expression alone.
function asWritten(value) {
  if (Array.isArray(value)) return value.map(asWritten)
  if (value && typeof value === 'object') {
    if (isJsExpr(value)) return { __jsExpr: value.__jsExpr }
    return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, asWritten(item)]))
  }
  return value
}

// A dumped text must load back, with the dsh schema, to the value it was written from: the
// Racket writer produces these same texts, so this is the check that js-yaml reads its output.
// js-yaml fails that for a few root scalars (a plain "...", a block scalar of line breaks only
// or with an indentation indicator); those rows go to `dump-unstable`, where the Racket writer
// must differ, and the texts it writes instead are in `loadTexts` below.
const dumpRows = []
const unstableDumpRows = []
function dumpRow(value, lineWidth) {
  const options = { schema: entryListSchema, noRefs: true }
  if (lineWidth !== 80) options.lineWidth = lineWidth
  const text = yaml.dump(value, options)
  let reloaded
  try {
    reloaded = rkt(yaml.load(text, { schema: entryListSchema }))
  } catch (error) {
    reloaded = String(error.reason)
  }
  const width = lineWidth === -1 ? '#f' : lineWidth
  const row = '(' + rkt(value) + ' ' + width + ' ' + rktString(text) + ')'
  if (reloaded === rkt(asWritten(value))) dumpRows.push(row)
  else unstableDumpRows.push(row)
}

// Random values: strings assembled from pieces that exercise the scalar styles.
const pieces = [
  'a', 'b', 'word', 'x y', ' ', '  ', '\n', '\n\n', ': ', ' #', '- ', "'", '"', '\t', E_ACUTE,
  SMILE, 'true', '12', '~', ',', '[', '{', '!', '&', '*', '%', '@', '`', '|', '>', '=', '?', '.',
  '0x', NBSP, 'long' + 'g'.repeat(30)]
function randomString() {
  if (chance(0.15)) return pick(dumpStrings.filter((s) => s.isWellFormed()))
  let s = ''
  const n = chance(0.2) ? 20 + int(40) : int(6)
  for (let i = 0; i < n; i++) s += pick(pieces)
  return s
}
function randomScalar() {
  const r = rand()
  if (r < 0.5) return randomString()
  if (r < 0.6) return int(2000) - 1000
  if (r < 0.7) return (rand() - 0.5) * Math.pow(10, int(40) - 20)
  if (r < 0.75) return null
  if (r < 0.85) return chance(0.5)
  if (r < 0.95) return js(randomString())
  return pick([Infinity, -Infinity, NaN, -0, 1e21, 0])
}
function randomValue(depth) {
  const r = rand()
  if (depth <= 0 || r < 0.4) return randomScalar()
  const n = int(4)
  if (r < 0.7) return Array.from({ length: n }, () => randomValue(depth - 1))
  const object = {}
  for (let i = 0; i < n; i++) {
    object[chance(0.7) ? 'k' + int(50) : randomString()] = randomValue(depth - 1)
  }
  return object
}

for (const s of dumpStrings) {
  if (!s.isWellFormed()) continue
  dumpRow(s, 80)
  dumpRow({ key: s }, 80)
  dumpRow([s], 80)
  dumpRow({ [s]: s }, 80)
  dumpRow([[{ deep: [s] }]], 80)
  dumpRow(js(s), 80)
}
for (const value of dumpValues) {
  for (const width of [80, 20, 120, -1]) dumpRow(value, width)
}
for (const s of dumpStrings.filter((s) => s.isWellFormed() && s.length > 40)) {
  for (const width of [10, 30, 41, 60, 200, -1]) {
    dumpRow({ a: { b: [s] } }, width)
  }
}
const randomValues = Array.from({ length: randomDumpCount }, () => randomValue(4))
for (const value of randomValues) dumpRow(value, pick([80, 80, 80, 30, 120, -1]))

// Texts js-yaml writes in its other styles, to read back: flow collections, wider indentation,
// double quotes.
const styleOptions = [
  { flowLevel: 0 }, { flowLevel: 1 }, { flowLevel: 2 }, { indent: 4 },
  { indent: 3, noArrayIndent: true },
  { flowLevel: 1, condenseFlow: true }, { quotingType: '"' }, { forceQuotes: true },
  { quotingType: '"', forceQuotes: true },
  { lineWidth: 20 }, { lineWidth: -1 }, { noArrayIndent: true }, { sortKeys: true },
  { noCompatMode: true },
]
const styledRows = []
for (const value of [...dumpValues, ...randomValues.slice(0, 250)]) {
  const options = pick(styleOptions)
  let text
  try {
    text = yaml.dump(value, { schema: entryListSchema, noRefs: true, ...options })
  } catch {
    continue
  }
  const row = loadRow(text, { schema: entryListSchema }, 'load')
  // js-yaml counts UTF-16 units in error positions; cordis-yaml counts characters.
  const astralError = row !== null && row.includes(' (error ') && [...text].length !== text.length
  if (row !== null && !astralError) styledRows.push(row)
}

// ---------------------------------------------------------------------------------------------
// Section: environments and eval

const services = {
  headlessStartup: {
    task: 'summarize the repository', sessionId: 'session-0001', json: false,
    additionalWritableRoots: ['/data/out', '/data/tmp'],
  },
  webStartup: {
    host: undefined, port: 4100, openBrowser: false, publicUrl: 'https://dsh.example/app',
    tls: null, trustedHosts: ['dsh.example'],
  },
}

const environments = [
  {
    name: 'bare', mode: 'real', env: { HOME: '/home/dsh-user' }, cwd: realCwd, profile: null,
    baseUrl: 'file:///opt/dsh/packages/bundle/base/cordis.patch.yml',
    dshHome: '/home/dsh-user/.dsh', services,
    resolveRoot: null,
  },
  {
    name: 'snapshot', mode: 'real', cwd: realCwd, profile: { name: 'desktop' },
    env: {
      HOME: '/home/dsh-user', TMPDIR: '/var/tmp/', DSH_SNAPSHOT: 'replay',
      DSH_SNAPSHOT_FILE: '/opt/dsh/snapshots/cases/acp demo/snapshot.yml',
      DSH_PERMISSION_MODE: 'danger-full-access',
      DSH_CONTEXT_WINDOW: '64000', DSH_GITHUB_WEBHOOK_PORT: '4455',
      DSH_TEST_CHILD_PATCHES: '[{"insert":{"id":"child"}},{"b":1,"10":2,"2":3,"a":[1.0,-0,1e3]}]',
      DSH_MAX_TOKENS_AS_SUCCESS: 'false', LIVESHARE_ALLOWED_SUBJECTS: ' alice , bob,,carol ,',
      MEMORY_FILE_PATH: '  /data/memory.jsonl  ',
      DSH_PRIMARY_RUNTIME: 'runtimes/../runtimes/current',
      DSH_SNAPSHOT_SPILL_ROOT: '/var/spill', DSH_TEST_ACP_MODE: 'diagnostic',
      DSH_TELEMETRY_MODE: '',
      DSH_SNAPSHOT_SESSIONS_ROOT: '', DSH_MODEL: 'deepseek-test', DSH_TEST_CHILD_FAILURE: 'boom',
      DSH_MCP_RESOURCES_FIXTURE: '/fixtures/resources.mjs', DSH_SNAPSHOT_FEEDBACK: '1',
      DSH_SYSTEM_PROMPT: 'You are terse.', DSH_GITHUB_REVIEW_WORKSPACE: '/work/review',
    },
    baseUrl: 'file:///opt/dsh/packages/bundle/web-app/cordis.patch.yml',
    dshHome: '/home/dsh-user/.dsh', services,
    resolveRoot: null,
  },
  {
    name: 'headless-win32', mode: 'shadow', platform: 'win32', cwd: 'C:\\work\\project',
    execPath: 'C:\\Program Files\\nodejs\\node.exe',
    env: {
      USERPROFILE: 'C:\\Users\\dsh', DSH_SNAPSHOT: 'record', DSH_PERMISSION_MODE: 'workspace-write',
      DSH_MAX_TOKENS_AS_SUCCESS: 'true',
    },
    profile: null, baseUrl: 'file:///C:/dsh/packages/bundle/headless/cordis.patch.yml',
    dshHome: '/c/Users/dsh/.dsh', services,
    resolveRoot: 'C:/dsh/node_modules',
  },
  {
    name: 'desktop-darwin', mode: 'shadow', platform: 'darwin', cwd: '/Users/dsh/project',
    execPath: '/usr/local/bin/node',
    env: {
      HOME: '/Users/dsh', DSH_PRIMARY_RUNTIME: '/Applications/DSH.app/runtime',
      DSH_SNAPSHOT_FILE: '/Users/dsh/snapshots/a/snapshot.yml',
    },
    profile: { name: 'desktop' },
    baseUrl: 'file:///Users/dsh/dsh/packages/bundle/desktop/cordis.patch.yml',
    dshHome: '/Users/dsh/.dsh', services, resolveRoot: '/Users/dsh/dsh/node_modules',
  },
]

function runEnvironment(desc, sources) {
  if (desc.mode === 'shadow') return evaluateAll(desc, sources)
  const child = spawnSync(process.execPath, [fileURLToPath(import.meta.url), '--child'], {
    env: desc.env, cwd: desc.cwd, input: JSON.stringify({ desc, sources }), encoding: 'utf8',
    maxBuffer: 1 << 28,
  })
  if (child.status !== 0) throw new Error('child failed: ' + child.stderr)
  return JSON.parse(child.stdout)
}

const P = "process.getBuiltinModule('node:path')"
const OS = "process.getBuiltinModule('node:os')"
const sq = (body) => "'" + body + "'"
const tick = (body) => '`' + body + '`'
const H = sq('Hello, World')
const A = '[3, 1, 2]'
const E = sq('a' + SMILE + 'b')
const RFC = sq('http://a/b/c/d;p?q')

const semanticSources = [
  // ---- number literals ----
  '1', '1.5', '.5', '5.', '1e3', '1E3', '1e-3', '1e+3', '0x1F', '0X1f', '0o17', '0O17', '0b101',
  '0B11', '1_000_000',
  '0.1 + 0.2', '1e21', '1e21 + 1', '9007199254740992', '9007199254740993', '9007199254740992 + 1',
  '-0', '0 * -1',
  '1 / 0', '-1 / 0', '0 / 0', '1 / -0', '2e308', '5e-324', '5e-325', '0.000001', '1e-7',
  '123456789012345680000',
  '0.1 * 3', '1.0', '100 / 3', '1.5e3', '0.5e-2', '1_0.0_1', '0xFF_FF', '1e1_0', '0e0', '0.0',
  '1 .toFixed(1)',
  '1..toFixed(1)', '1.5.toFixed(0)', '.5.toFixed(0)', '0x10.toString()', '999999999999999999999',
  '0.1e-5', '1.e2',
  // ---- string literals ----
  "'a'", '"a"', "'it" + BS + "'s'", '"q' + BS + '"q"', sq('a' + BS + 'nb'), sq('a' + BS + 'tb'),
  sq(BS + 'x41'),
  sq(BS + 'u0041'), sq(BS + 'u{1F600}'), sq(BS + 'u{41}'), sq('a' + BS + '\nb'), sq(BS + '0'),
  sq(BS + 'q'),
  sq(BS + 'b' + BS + 'f' + BS + 'v' + BS + 'r'), "''", sq(SMILE) + '.length',
  sq(BS + 'uD83D' + BS + 'uDE00'),
  sq(BS + 'uD83D' + BS + 'uDE00') + '.length', sq(BS + BS), sq(BS + BS + 'n'), '"' + BS + "'" + '"',
  sq('a' + BS + '\r\nb'),
  sq(E_ACUTE), sq(BS + 'xe9') + ' === ' + sq(E_ACUTE), sq(LS), sq(BS + '$'),
  sq(BS + 'u{10FFFF}') + '.length',
  // ---- template literals ----
  tick('a'), tick('a${1}b'), tick('${1}${2}'), tick("${'x'}"), tick('a${`b${1}`}c'),
  tick('${null} ${undefined} ${true} ${[1,2]} ${{}}'), tick(BS + '${1}'), tick('a' + BS + 'nb'),
  tick('line1\nline2'),
  tick('line1\r\nline2') + '.length', tick('$'), tick('$ {1}'), tick('${1 + 1}'), tick(''),
  tick('${""}'),
  tick('${1}${"a"}${[]}${null}'), tick('a' + BS + '`b'), tick('${[1, [2, 3]]}'), tick('${1e21}'),
  tick('${-0}'),
  tick('${ 1 }'), tick('a${ /* c */ 1 }b'), tick('${{a: 1}.a}'), tick('}'), tick('{${1}}'),
  tick(BS + 'u0041' + BS + 'x42'),
  tick('a' + BS + '\nb'), tick('${`${`${1}`}`}'), tick('${(x => x * 2)(4)}'),
  // ---- keywords and globals ----
  'true', 'false', 'null', 'undefined', 'NaN', 'Infinity', '-Infinity', 'typeof undefined',
  'undefined === void 0',
  // ---- arrays ----
  '[]', '[1, 2, 3]', '[1, [2, [3]]]', '[1, 2,]', '[...[1, 2], 3]', "[...'ab']", '[...' + E + ']',
  '[undefined, null]',
  '[1, 2, 3].length', '[1, 2, 3][0]', '[1, 2, 3][5]', "[1, 2, 3]['1']", '[1, 2, 3][-1]',
  "[1, 2, 3]['length']",
  '[[1, 2], [3]][0][1]', '[...[], ...[1], ...[2, 3]]', '[1, 2, 3][1.5]', '[1, 2, 3][true]',
  "[1, 2, 3]['01']",
  '[1, 2, 3][1.0]', "['a', 'b'][[1]]", '[...[1, 2]].length', '[[]].length', '[[], []].length',
  '[1, 2, 3][NaN]',
  '[...[undefined]]', '[...null]', '[...5]', '[...{}]', '[...undefined]', "[...'']",
  '[1, 2, 3][1 + 1]',
  // ---- objects ----
  '({})', '({a: 1})', "({a: 1, b: 'x'})", "({'a b': 1})", "({1: 'a'})", '({b: 1, a: 2})',
  "({b: 1, 2: 'x', 1: 'y', a: 0})", '({a: 1, a: 2})', '({[`k${1}`]: 1})', "({['a' + 'b']: 1})",
  '({...{a: 1}, b: 2})', '({a: 1, ...{a: 2}})', '({...null})', '({...undefined})', '({...[1, 2]})',
  "({...'ab'})",
  '({...5})', '({a: undefined})', '({a: 1}).a', '({a: 1}).b', "({a: 1})['a']",
  '({a: {b: {c: 3}}}).a.b.c',
  '({default: 1, new: 2, typeof: 3})', '({a: 1,})', "({1.5: 'x'})", "({0x10: 'x'})", '({a: null})',
  '({true: 1})',
  '((x) => ({x}))(5)', '((a, b) => ({a, b}))(1, 2)', '({a: 1, ...{b: 2, a: 3}, c: 4})',
  '({...{b: 1}, ...{a: 2}, b: 3})',
  '({[1 + 1]: 2})', '({[null]: 1})', '({[undefined]: 1})', '({[[1, 2]]: 1})', '({[1.50]: 1})',
  "({'': 1})['']",
  "({'a-b': 1})['a-b']", '({a: [1, {b: 2}]}).a[1].b', '({a: 1})[`a`]', "({10: 'a', 9: 'b'})",
  "({'-1': 1, 1: 2, '01': 3})",
  '({a: () => 5}).a()', '({f: (x) => x + 1}).f(1)', "({a: 1})['b']", '({a: 0, b: false, c: null})',
  '({...{}, ...[], ...true})', '({x: 1, y: undefined, z: 3})', '({a: 1}).a.toFixed(1)',
  '({a: {}}).a.b',
  "({4294967294: 'a', 4294967295: 'b', 1: 'c'})", '({a: NaN, b: -0, c: 1e21})',
  '({b: {d: 1, c: 2}, a: [3]})',
  // ---- optional chaining ----
  'null?.a', 'undefined?.a', 'null?.a.b.c', 'undefined?.[0]', 'null?.()', '({a: null}).a?.b',
  '({a: {b: 1}}).a?.b',
  '({a: 1}).b?.c', '({a: 1}).b?.c.d.e', '(null?.a).b', "'abc'?.length", '({f: null}).f?.()',
  '({f: () => 1}).f?.()',
  '({a: {f: () => 2}}).a?.f()', 'undefined?.f()', 'null?.[1 / 0]', "''?.length", '0?.toFixed(1)',
  "undefined?.a ?? 'd'",
  '[1, 2]?.[1]', '({a: [1, 2]}).a?.[5]', '({a: [1, 2]}).b?.[5]', "({a: 'x'}).a?.toUpperCase()",
  '({}).a?.b()',
  '({}).a?.b().c', '({a: {}}).a?.b?.c', '({a: {}}).a?.b.c', 'null?.a?.b', '(undefined?.a)?.b',
  'null?.a ?? null?.b ?? 3',
  '({f: (x) => x}).f?.(4)', '({}).f?.(nope)', 'undefined?.[nope]', 'null?.a(nope)',
  '({a: null}).a?.[0].b',
  "({a: 'q'})?.a", 'false?.a', '({a: 1}).a?.b', "''?.a?.b", '(() => null)()?.x', '(() => 1)?.()',
  // ---- property errors ----
  'null.a', 'undefined.a', 'undefined.a.b', '(void 0).x', 'null[0]', '({}).a.b', '({}).f()',
  "'x'.nope()", '(1)()',
  "'s'()", 'null()', 'undefined()', '({a: 1}).a()', 'nope', 'nope.a', 'nope()', 'typeof nope',
  'typeof nope.a',
  'nope ?? 1', '[1].nope', "'x'.nope", '(5).nope', 'true.nope', '({}).nope', '[].nope()',
  '(5).nope()',
  'undefined[nope]', 'yield', 'await', 'let', 'async', 'of', 'get', 'static',
  // ---- unary ----
  '!0', '!1', "!''", "!'a'", '!null', '!undefined', '!NaN', '![]', '!{}', "!!'x'", '-1', "-'5'",
  "-''", "-'a'", '-null',
  '-undefined', '-true', '-[]', '-[5]', '-[1, 2]', '-{}', "+'5'", "+''", "+' 12 '", "+'1e3'",
  "+'0x1f'", "+'0b11'",
  "+'0o17'", "+'-0x1f'", "+'1_000'", "+'Infinity'", "+'-Infinity'", "+'+Infinity'", "+'infinity'",
  "+'.5'", "+'5.'",
  "+'+5'", "+'- 5'", '+' + sq(BS + 'n 7 ' + BS + 't'), '+null', '+undefined', '+true', '+false',
  '+[]', '+[7]', "+['7']",
  '+[1, 2]', '+{}', "+'12px'", "+'1e1000'", "+'-1e1000'", "+'1e-1000'", "+'0.0000001'", '- -1',
  '-(-0)', '+-1', '-+1',
  "+'-0'", "1 / +'-0'", "+'0X1F'", "+'0B11'", "+'0O17'", "+'.'", "+'e5'", "+'1e'", "+'1e+'",
  "+'++1'", "+'1 2'",
  "+'" + NBSP + '5' + cp(0x2003) + "'", "+'" + BOM + "5'", "+'" + NEL + "5'", "+'0x'", "+'00012'",
  "+'12.50'", "+'1.'",
  'typeof 1', "typeof 'a'", 'typeof true', 'typeof undefined', 'typeof null', 'typeof []',
  'typeof {}',
  'typeof (() => 1)', 'typeof NaN', 'typeof JSON', 'typeof Number', 'typeof URL',
  'typeof process.env',
  'typeof process.cwd', "typeof ''.trim", 'typeof [].map', 'typeof Math', 'typeof Math.max',
  'typeof JSON.parse',
  'typeof parseInt', 'void 0', "void 'x'", 'typeof void 0', 'typeof typeof 1', '!!-0', '-0 === 0',
  '!!NaN', "!!'0'",
  "!!' '", '!![]', '!!{}', '!!(() => 0)', '!!Infinity', '!!-1', '!!0.1', 'typeof Infinity',
  'typeof -1', "typeof ('a' + 1)",
  'typeof process', 'typeof process.platform', 'typeof ctx', 'typeof dshHomePath', 'typeof baseUrl',
  'typeof Array.isArray',
  // ---- addition and arithmetic ----
  '1 + 2', "'a' + 'b'", "'a' + 1", "1 + 'a'", "1 + 2 + 'a'", "'a' + 1 + 2", '1 + null',
  '1 + undefined', '1 + true',
  "'a' + null", "'a' + undefined", "'a' + true", '[] + []', '[] + {}', '[1, 2] + [3]', "({}) + 'x'",
  '1 + [2]', '1 + {}',
  'null + null', 'undefined + undefined', 'true + true', "'5' - 2", "'5' * '2'", "'a' - 1",
  '10 / 4', '10 % 3', '-10 % 3',
  '10 % -3', '5.5 % 2', '-5.5 % 2', '5 % 0', '0 % 5', '-0 % 5', '1 / (-0 % 5)', 'Infinity % 2',
  '2 % Infinity',
  '1e308 * 10', '-1e308 * 10', "5 - '2'", "'10' / '4'", '1 - null', '1 - undefined', 'null * 5',
  '[] * 2', '[3] * [4]',
  "'3' * true", '2 * 3 + 4', '2 + 3 * 4', '(2 + 3) * 4', '10 - 2 - 3', '2 * 3 % 4', '100 / 10 / 5',
  '1 + -1', '1 - -1',
  '1 - +1', '0.1 + 0.2 === 0.3', '9007199254740991 + 2', '4.35 * 100', '1.1 + 2.2', '3 * 1.1',
  '0.7 + 0.1', '1 / 3',
  '2 / 3', '7 % 2.5', '1e21 % 7', '1e300 * 1e10', '-7 % 7', '1 / (-7 % 7)', '5 % -5', "'1' + 1 - 1",
  "'3' + 4 * 5",
  '1 + 1e21', "'' + -0", "'' + 1e21", "'' + 1e-7", "'' + 0.000001", "'' + [1, [2, 3]]", "'' + null",
  "'' + undefined", "'' + {}", "1 + '2' + 3", '1 + +"2" + 3', '5 / 2 * 2', '7 - 7 === 0',
  '0.1 * 0.1', '1e16 + 1', '2 * 1.5', '9 / 3', '1.5 + 1.5', '3 - 1.5 - 1.5', '1 / (0 * -3)',
  '0 * Infinity',
  'Infinity - Infinity', 'Infinity + 1', "-Infinity + ''", "NaN + ''", '(0.1 + 0.7) * 10',
  '1.005 * 1000', '3 % 1.5',
  '-3.5 % 1', '1 / (-3 % 1)', '1e-320 * 1', '4 % 2.5',
  "'a' + ({toString: () => 'T'})", "1 + ({valueOf: () => 41})",
  "'' + ({valueOf: () => 1, toString: () => 'T'})",
  "`${({valueOf: () => 1, toString: () => 'T'})}`", "({valueOf: () => 2}) * 3",
  "({toString: () => '7'}) * 3",
  "'' + ({toString: () => ({})})", "({valueOf: () => ({}), toString: () => 9}) + 1",
  "'' + ({toString: 5})",
  // ---- comparison ----
  '1 < 2', '2 < 1', '1 <= 1', '1 >= 2', "'a' < 'b'", "'a' < 'B'", "'10' < '9'", "'10' < 9",
  "10 < '9'", "'a' < 1",
  'null < 1', 'undefined < 1', 'null >= 0', 'null > 0', 'NaN < 1', 'NaN >= NaN', '[2] > 1',
  "'abc' < 'abd'",
  "'abc' < 'ab'", "'' < 'a'", 'true > false', sq(SMILE) + ' < ' + sq(cp(0xff5e)), '[1, 2] < [1, 3]',
  '({}) < ({})',
  '1 < 2 < 3', '3 > 2 > 1', "'b' > 'a'", "'a' >= 'a'", "'a' <= 'A'", '-0 < 0', '0 <= -0',
  'Infinity > 1e308',
  '-Infinity < -1e308', "'2' > '12'", "2 > '12'", "'abc' > undefined", 'undefined >= undefined',
  'null <= null',
  "[10] < [9]", "['10'] < 9", "'a' < ['b']", '1 < 2 === true', "({valueOf: () => 1}) < 2",
  "'B' < 'a'",
  sq(E_ACUTE) + " > 'z'", "' ' < 1", "'' < 1", "'0x10' >= 16",
  // ---- equality ----
  '1 === 1', '1 === 1.0', "1 === '1'", "'a' === 'a'", 'null === null', 'undefined === undefined',
  'null === undefined',
  'NaN === NaN', '0 === -0', 'true === 1', '[1] === [1]', '({a: 1}) === ({a: 1})', '1 !== 2',
  "'a' !== 'a'", "1 == '1'",
  "1 == '1.0'", "0 == ''", "0 == ' '", "0 == '0'", "'' == '0'", 'null == undefined', 'null == 0',
  'null == false',
  'undefined == false', 'false == 0', 'true == 1', "true == '1'", "true == 'true'", "false == ''",
  "false == '0'",
  'NaN == NaN', "[] == ''", '[] == 0', '[1] == 1', "[1, 2] == '1,2'", "({}) == '[object Object]'",
  '[] == false',
  '[0] == false', '[1] == true', 'null != undefined', "1 != '1'", "'a' != 'b'", '[1] == [1]',
  'null == null',
  'undefined == null', "'1' == 1", '1 == true', '2 == true', "'abc' == 'abc'", '0 == null',
  "'' == null",
  "'null' == null", '0 == undefined', "Infinity == 'Infinity'", '1 == [1]', "'1,2' == [1, 2]",
  'true == [1]',
  'null == []', '((a) => a === a)([1])', '((a) => a === a)({b: 1})', '((a) => a == a)([1])',
  '((a, b) => a === b)([1], [1])',
  '((f) => f === f)(() => 1)', '(() => 1) === (() => 1)', '1e21 === 1e21', '0.1 + 0.2 !== 0.3',
  "'a' === `a`",
  "1 === 1.000", '9007199254740992 === 9007199254740993', "'" + E_ACUTE + "' === '" + E_ACUTE + "'",
  'undefined == 0', "undefined == ''", "null == ''", 'NaN != NaN', 'NaN !== NaN', '-0 == 0',
  "'-0' == 0", "' 1 ' == 1",
  "'1e3' == 1000", "'0x10' == 16", "true == 'TRUE'", "[[]] == ''", '[[1]] == 1', "[null] == ''",
  "[undefined] == ''",
  '({}) == ({})', "({toString: () => 'x'}) == 'x'", '({valueOf: () => 5}) == 5',
  'process.platform === process.platform',
  // ---- logical operators ----
  '1 && 2', '0 && 2', "'' && 'x'", 'null && nope', '0 && nope', '1 || nope', '1 ?? nope',
  "null ?? 'd'",
  "undefined ?? 'd'", "0 ?? 'd'", "'' ?? 'd'", "false ?? 'd'", "NaN ?? 'd'", "null || 'd'",
  "0 || 'd'", "'' || 'd'",
  "'a' || 'd'", "null ?? undefined ?? 'x'", "(null || undefined) ?? 'x'",
  "null || (undefined ?? 'x')", '1 && 2 || 3',
  '0 && 2 || 3', '1 || 2 && 3', '0 || 2 && 3', '(0 || 2) && 3', '1 && 0 || 0 && 1',
  'true && false || true',
  '!1 || !0', '1 && 2 && 3', '1 && 0 && 3', "0 || '' || null", '0 || null || undefined', 'NaN && 1',
  '[] && 1',
  '[] || 1', '({}) && 2', "'0' && 3", 'null ?? null', 'undefined ?? undefined', '(1 && null) ?? 5',
  '(0 || null) ?? 5',
  '1 && (null ?? 5)', '0 || (undefined ?? 6)', '(null ?? 0) || 7', '(null ?? 1) && 8', '!null ?? 1',
  'null ?? !1',
  '1 < 2 && 2 < 3', "1 === 1 || nope", '1 + 1 && 2 + 2', "typeof nope === 'undefined' || nope",
  '0 ?? nope',
  // ---- conditional ----
  "1 ? 'a' : 'b'", "0 ? 'a' : 'b'", "'' ? 1 : 2", '[] ? 1 : 2', 'null ? 1 : 2', '1 ? 2 ? 3 : 4 : 5',
  '0 ? 1 : 0 ? 2 : 3',
  '1 ? 2 : nope', '0 ? nope : 3', 'true ? 1 : 2 + 10', 'false ? 1 : 2 + 10', "1 > 2 ? 'gt' : 'le'",
  "null ?? 0 ? 'a' : 'b'",
  '(1 ? 2 : 3) + 1', '1 ? 2 : 3 + 1', '1 || 0 ? 2 : 3', '0 && 1 ? 2 : 3', "1 ? x => x : 2",
  '(0 ? 1 : (x) => x + 1)(1)',
  '1 ? [1] : {}', '0 ? [1] : {a: 2}', '1 ? 0 ? 1 : 2 : 3', '1 ?.5 : 1', 'null ?.5 : 1',
  "1 ? 'a' : 0 ? 'b' : 'c'",
  "undefined ? 1 : null ? 2 : NaN ? 3 : 4",
  // ---- arrow functions ----
  '(() => 1)()', '((x) => x * 2)(4)', '(x => x + 1)(1)', '((a, b) => a + b)(1, 2)',
  '((a, b) => b)(1)',
  '((a) => a)(1, 2, 3)', '(x => y => x + y)(1)(2)', '((f) => f(f(1)))((x) => x + 1)',
  '[1, 2, 3].map(x => x * 2)',
  '[1, 2, 3].map((x, i) => x * i)', '[1, 2, 3].map((x, i, a) => a.length)',
  '[1, 2, 3].filter(x => x % 2)',
  "((x) => x ? 'y' : 'n')(0)", '(x => ({a: x}))(1)', '(x => [x, x])(1)',
  '((x) => (y) => (z) => x + y + z)(1)(2)(3)',
  '((x) => typeof x)()', '(() => undefined)()', '((a, b,) => a)(1)', 'typeof (x => x)',
  '((x, y) => x ?? y)(null, 5)',
  '((x) => ((x) => x)(2) + x)(1)', '(process => process)(5)', '((JSON) => JSON)(1)',
  '((x) => x)(...[1, 2])',
  '((a, b, c) => [a, b, c])(...[1, 2])', "((a, b) => a + b)(...'xy')", '(x => x)(1, nope)',
  '(($, _) => $ + _)(1, 2)', '((' + cp(0xe9) + ') => ' + cp(0xe9) + ')(3)',
  '((a) => (b) => a)(1)(2)',
  '((f, x) => f(x))((v) => v * 3, 2)', '((x) => x === undefined)()',
  '((a, a2) => a2)(1, 2)', '(async => async)(1)', '(of => of)(2)', '((let) => let)(3)',
  '(x =>\n x)(1)',
  '((ctx) => ctx)(1)', '((dshHomePath) => dshHomePath)(1)', '[1, 2].map((x) => (y => x + y)(10))',
  // ---- string methods ----
  ...['.length', '[0]', '[20]', '.at(0)', '.at(-1)', '.at(99)', '.at()', '.at(-99)', '.at(1.9)',
    '.at(NaN)', ".at('2')",
    '.charAt(1)', '.charAt(99)', '.charAt(-1)', '.charAt()', '.charAt(1.9)',
    ".concat('!', 1, null)", '.concat()',
    ".endsWith('World')", ".endsWith('Hello', 5)", ".endsWith('')", ".endsWith('x')",
    ".endsWith('World', 99)",
    ".endsWith('H', 1)", ".endsWith('', 0)", ".endsWith('World', -1)", ".endsWith('lo', 5.9)",
    '.endsWith()',
    ".includes('lo, W')", ".includes('hello')", ".includes('H', 1)", ".includes('')", '.includes()',
    ".includes('d', 11)",
    ".includes('', 99)", ".includes('H', -5)", ".indexOf('o')", ".indexOf('o', 5)", ".indexOf('z')",
    ".indexOf('')",
    ".indexOf('', 99)", ".indexOf('o', -5)", ".indexOf('o', 4.9)", '.indexOf()',
    ".indexOf('World', 7)", ".indexOf('World', 8)",
    ".padEnd(15, '*')", '.padEnd(15)', '.padEnd(3)', ".padEnd(16, 'ab')", ".padStart(15, '*')",
    ".padEnd(15, '')",
    '.padEnd(14.9, 1)', ".padEnd('15', '-')", '.padEnd(NaN)', '.padEnd(-1)', ".padStart(14, 'abc')",
    '.slice(7)', '.slice(-5)', '.slice(0, 5)', '.slice(2, -2)', '.slice(5, 2)', '.slice()',
    '.slice(-100, 100)',
    '.slice(NaN)', '.slice(1.9, 3.1)', ".slice('2')", '.slice(undefined, 3)',
    '.slice(3, undefined)', '.slice(null, 2)',
    '.slice(-3, -1)', '.slice(Infinity)', '.slice(-Infinity, 2)', '.slice(0, Infinity)',
    ".split(', ')", ".split('')", '.split()', ".split('o')", ".split('o', 2)", ".split('o', 0)",
    ".split('', 3)",
    ".split('l')", ".split('ll')", ".split('Hello, World')", ".split('', 0)",
    '.split(undefined, 0)', ".split('o', -1)",
    ".split('o', 1.9)", ".split('o', NaN)", ".split('o', undefined)", ".split('o', null)",
    ".split('o', '2')",
    ".startsWith('Hello')", ".startsWith('World', 7)", ".startsWith('')", ".startsWith('hello')",
    ".startsWith('', 99)",
    ".startsWith('H', -1)", ".startsWith('ello', 1.5)", '.startsWith()',
    '.substring(7)', '.substring(5, 2)', '.substring(-3, 2)', '.substring(2, 100)',
    '.substring(NaN, 3)', '.substring()',
    '.substring(3, 3)', '.substring(1.9, 4.1)', '.substring(4, undefined)', '.substring(Infinity)',
    '.toLowerCase()', '.toUpperCase()', '.toString()', '.valueOf()', '.trim()',
    ".replace('o', '0')", ".replaceAll('o', '0')",
    ".replace('l', (m) => m.toUpperCase())", ".replaceAll('l', (m, i) => i)",
    ".replace('World', '$& $&')",
    ".replace(', ', '$`|$' + \"'\")", ".replaceAll('', '.')", ".replace('', '>')",
    ".replace('zzz', 'y')", ".replaceAll('zzz', 'y')",
  ].map((suffix) => H + suffix),
  "'undefined'.includes()", "'undefined'.indexOf()", "'undefined'.startsWith()",
  "'xundefined'.endsWith()",
  "'5'.padStart(3, '0')", "'5'.padStart(3, '')", "'abc'.padStart(6, '12345')", "'abc'.padStart(2)",
  "'x'.padEnd(5, 'ab')",
  "'ab'.repeat(3)", "'ab'.repeat(0)", "'ab'.repeat(2.9)", "'ab'.repeat(-1)",
  "'ab'.repeat(Infinity)", "''.repeat(5)",
  "'ab'.repeat()", "'ab'.repeat('2')", "'ab'.repeat(NaN)", "'ab'.repeat(-0.5)",
  "'a-b-c'.replace('-', '+')", "'a-b-c'.replaceAll('-', '+')", "'abc'.replace('b', '[$&]')",
  "'abc'.replace('b', '$$')",
  "'abc'.replace('b', '$`')", "'abc'.replace('b', \"$'\")", "'abc'.replace('b', '$1')",
  "'abc'.replace('b', '$0')",
  "'abc'.replace('b', '$<x>')", "'abc'.replace('b', '$')", "'abc'.replace('b', '$$$')",
  "'abc'.replace('b', 'x$')",
  "'abc'.replace('b', (m) => m.toUpperCase())", "'abc'.replace('b', (m, i, s) => i + s)",
  "'abc'.replace('x', 'y')",
  "'abc'.replace('', '-')", "'abc'.replaceAll('', '-')", "'aaa'.replaceAll('aa', 'b')",
  "'abc'.replace('b')",
  "'a.b'.replace('.', '/')", "'x'.replaceAll('x', '$&$&')", "'abc'.replace('b', () => undefined)",
  "'abc'.replace('b', () => 5)",
  "'abc'.replace('b', null)", "'a1b'.replace(1, 2)", "'anullb'.replace(null, 'x')",
  "'aXbXc'.replaceAll('X', '$`')",
  "'aXbXc'.replaceAll('X', \"$'\")", "'abcabc'.replaceAll('bc', (m, i, s) => `[${i}:${s.length}]`)",
  "''.replaceAll('', 'x')",
  "''.replace('', 'x')", "'aaa'.replaceAll('a', '')", "'$'.replace('$', '$$$$')",
  "''.split(',')", "''.split('')", "'a,b,,c'.split(',')", "',a,'.split(',')", "'abc'.split('abc')",
  "'a1b2c'.split(1)",
  "'a,b'.split(',', -1)", "'a,b,c'.split(',', 1.5)", "'a,b,c'.split(',', 2)", "'a, b'.split(', ')",
  "'abc'.split('b', 4294967297)",
  "'anullb'.split(null)", "'aundefinedb'.split(undefined)", "'aab'.split('a')",
  "'  a  b '.split(' ')", "'abc'.split('', -1)",
  "'  a b  '.trim()", "'  a b  '.trimStart()", "'  a b  '.trimEnd()",
  sq(BS + 't' + BS + 'n x ' + BS + 'r' + BS + 'n') + '.trim()',
  sq(NBSP + 'x' + cp(0x2003)) + '.trim().length', sq(BOM + 'x' + LS) + '.trim().length',
  sq(NEL + 'x') + '.trim().length',
  sq(cp(0x200b) + 'x') + '.trim().length',
  sq(cp(0x3000, 0x1680, 0x202f, 0x205f) + 'x') + '.trim().length',
  sq(cp(0xdf)) + '.toUpperCase()', sq('I' + cp(0x307)) + '.toLowerCase().length',
  sq(cp(0x391, 0x3a3)) + '.toLowerCase()',
  sq(cp(0x391, 0x3a3) + ' ' + cp(0x3a3, 0x391)) + '.toLowerCase()',
  sq(cp(0xfb01)) + '.toUpperCase()',
  sq(cp(0x149)) + '.toUpperCase().length', sq(cp(0x130)) + '.toLowerCase().length',
  "'aBc'.toUpperCase().toLowerCase()",
  sq(cp(0x10400)) + '.toLowerCase() === ' + sq(cp(0x10428)), sq(cp(0x1e9e)) + '.toLowerCase()',
  E + '.length', E + ".indexOf('b')", E + '.slice(1, 3)', E + '.slice(3)', E + '.at(-1)', E + '[3]',
  E + '.padEnd(6, ' + sq(SMILE) + ')',
  E + '.substring(0, 1)', E + '.includes(' + sq(SMILE) + ')', '[...' + E + '].length',
  E + '.replace(' + sq(SMILE) + ", 'x')",
  E + '.split(' + sq(SMILE) + ')', E + ".endsWith('b')", E + '.startsWith(' + sq(SMILE) + ', 1)',
  E + '.charAt(0)',
  E + '.toUpperCase()', E + '.concat(' + E + ').length', E + '.repeat(2).length',
  E + '.padStart(8).length', E + '.trim()',
  E + ".split('b')", E + ".replaceAll('a', '" + SMILE + "')", E + '.slice(-1)',
  E + '.slice(0, 1) + ' + E + '.slice(1)',
  "'abc'[1]", "'abc'['1']", "'abc'[3]", "'abc'[-1]", "'abc'['length']", "'abc'[1.0]", "''.length",
  "'abc'.length.toFixed(1)",
  "'a'.concat(['b', 'c'], {})", "'a'.at()", "''.at(0)", "''.charAt(0)", "'abc'.indexOf('c', 2)",
  "'abc'.indexOf('c', 3)",
  "'abc'.includes('c', 2)", "'abc'.includes('c', 3)", "'abc'.slice(1).slice(1)",
  "'a b c'.split(' ').join('-')",
  "'A-B'.toLowerCase().split('-').map(s => s.toUpperCase())", "' x '.trim().length",
  "'x'.trim === 'y'.trim",
  // ---- array methods ----
  ...['.at(0)', '.at(-1)', '.at(5)', '.at()', '.at(-4)', '.at(1.9)', '.concat([4], 5, [[6]])',
    '.concat()',
    '.every(x => x > 0)', '.every(x => x > 1)', '.some(x => x > 2)', '.some(x => x > 5)',
    '.filter(x => x > 1)',
    '.filter((x, i) => i !== 1)', '.find(x => x < 3)', '.find(x => x > 5)', '.includes(2)',
    ".includes('2')",
    '.includes(3, 1)', '.includes(2, -1)', '.includes(3, -3)', '.includes(3, -99)',
    '.includes(2, 99)', '.includes()',
    '.indexOf(2)', '.indexOf(9)', '.indexOf(3, 1)', '.indexOf(2, -1)', '.indexOf(3, -99)',
    '.indexOf(2, 2.5)', '.indexOf()',
    '.join()', ".join('-')", ".join('')", '.join(undefined)', '.join(null)', '.join(1)',
    '.map(String)', '.map(Number)',
    '.map(x => x)', '.map((x, i, a) => a[i] === x)', '.slice(1)', '.slice(-2)', '.slice(0, -1)',
    '.slice()', '.slice(2, 1)',
    '.slice(1, 2)', '.slice(-99, 99)', '.slice(NaN)', '.slice(undefined, 2)', '.slice(1.9)',
    '.toString()', '.length',
    '.map(x => x * 2).filter(x => x > 2).join()', '.filter(Boolean).length', '.every(Boolean)',
    '.some(x => x === 1)',
    '.find((x, i) => i === 2)', '.map(() => undefined)', '.filter(() => 0)', '.filter(() => 1)',
    '.map((x) => [x])',
    '.concat(' + A + ').length', '.concat(null, undefined)', ".concat('ab')", '.concat([[]])',
    '.concat({a: 1})',
  ].map((suffix) => A + suffix),
  '[].every(x => false)', '[].some(x => true)', '[0, false, \'\'].find(x => !x)',
  '[false].find(x => x === false)',
  '[undefined].find(x => true)', '[null].find(x => true)', '[NaN].includes(NaN)',
  '[NaN].indexOf(NaN)', '[-0].includes(0)',
  '[0].indexOf(-0)', "['1'].includes(1)", '[[1]].includes([1])', '[null].includes(undefined)',
  '[undefined].includes()',
  '[undefined].indexOf()', '[null, undefined, 1].join()', "[[1, 2], [3]].join(';')", '[].join()',
  '[[]].join()',
  '[[], []].join()', '[{}].join()', "['a'].join()", "[1, [2, [3, null]]].join('-')",
  "['1', '2', '3'].map(Number)",
  "['a', 'b'].map((x, i) => x + i)", "['1', '2', '10'].map(parseInt)", '[1, [2, 3]].toString()',
  '[].length',
  "['a', 'b'].map(x => x.toUpperCase()).join('')", '[1, 2, 3].filter(Boolean)',
  "[0, 1, '', 'a', null].filter(Boolean)",
  "[' a ', 'b '].map(s => s.trim())", "['x'].concat('y').includes('y')", 'Array.isArray([])',
  "Array.isArray('a')",
  'Array.isArray({length: 0})', 'Array.isArray()', 'Array.isArray([].map(x => x))', '[1].map()',
  '[1].map(1)',
  "[1].filter('x')", '[].map()', '[1].every(null)', '[1].some({})', '[1].find()',
  '[1, 2, 3].map(Math.abs)',
  '[1.5, 2.5].map(Math.round)', "['a', 'b'].map(encodeURIComponent)",
  "[1, 2].map(String).join('') === '12'",
  '[1, 2, 3].slice(1).concat([9]).map(x => x + 1)', '[[1, 2], [3]].map(a => a.length)',
  '[1, 2, 3].at(-1) + [1].at(0)',
  "['b', 'a'].includes('a') && ['b', 'a'].indexOf('a')", '[1, undefined, 3].map(x => x ?? 0)',
  '[undefined, null].join("|")',
  '[1, 2, 3].find(x => x > 1) + 1', '[3, 4].map((x, i, arr) => arr.length + i)',
  "[..." + A + ', ...' + A + '].length',
  // ---- number and boolean methods ----
  '(1.005).toFixed(2)', '(1.5).toFixed(0)', '(2.5).toFixed(0)', '(-1.5).toFixed(0)',
  '(0).toFixed(2)', '(-0.0001).toFixed(2)',
  '(1e21).toFixed(2)', '(123.456).toFixed(1)', '(0.000001).toFixed(7)', 'NaN.toFixed(2)',
  '(5).toFixed()', '(1.45).toFixed(1)',
  '(8.345).toFixed(2)', '(10).toFixed(101)', '(10).toFixed(-1)', '(255).toString(16)',
  '(255).toString(2)', '(-255).toString(36)',
  '(255).toString()', '(1.5).toString()', '(1e21).toString()', '(255).toString(1)',
  '(255).toString(37)', '(5).valueOf()',
  '(0.1).toFixed(20)', '(1234.5678).toFixed(2)', '(0.5).toFixed(0)', '(-2.5).toFixed(0)',
  '(-0).toFixed(1)', 'Infinity.toFixed(1)',
  '(-Infinity).toFixed(1)', '(1e-10).toFixed(3)', '(999.995).toFixed(2)', '(0.045).toFixed(2)',
  '(1.255).toFixed(2)',
  '(1e20).toFixed(2)', '(123456789).toFixed(0)', '(0.1 + 0.2).toFixed(10)', "(5).toFixed('2')",
  '(5).toFixed(2.9)',
  '(5).toFixed(100).length', '(255).toString(undefined)', "(255).toString('16')",
  '(255).toString(10)', '(-0).toString()',
  '(1e21).toString(16)', 'NaN.toString(2)', 'Infinity.toString(16)', '(-Infinity).toString(8)',
  '(9007199254740992).toString(2)',
  '(0).toString(2)', '(35).toString(36)', 'true.toString()', 'false.valueOf()',
  'true.toString().length', '(1 < 2).toString()',
  '(5).toFixed(1).length', '1.5.valueOf() + 1', '(12).toString().padStart(4, "0")',
  '(-7).toString(2)',
  // ---- Number, String, Boolean ----
  "Number('12')", "Number('')", "Number(' ')", "Number('12px')", 'Number(null)',
  'Number(undefined)', 'Number(true)',
  'Number([])', 'Number([5])', 'Number({})', 'Number()', "Number('0x10')", "Number('1e3')",
  "Number('-0')",
  "1 / Number('-0')", "Number('Infinity')", "Number('1,000')", 'Number.isInteger(5)',
  'Number.isInteger(5.5)',
  "Number.isInteger('5')", 'Number.isInteger(5.0)', 'Number.isInteger(Infinity)',
  'Number.isInteger()', 'Number.isFinite(1)',
  "Number.isFinite('1')", 'Number.isFinite(Infinity)', 'Number.isFinite(NaN)', 'Number.isNaN(NaN)',
  "Number.isNaN('x')",
  'Number.isNaN()', 'Number.isSafeInteger(9007199254740991)',
  'Number.isSafeInteger(9007199254740992)',
  'Number.isSafeInteger(1.5)', "Number.isSafeInteger('1')", "Number.parseFloat('1.5x')",
  "Number.parseInt('12px')",
  'Number.MAX_SAFE_INTEGER', 'Number.MIN_SAFE_INTEGER', 'Number.MAX_VALUE', 'Number.MIN_VALUE',
  'Number.EPSILON',
  'Number.POSITIVE_INFINITY', 'Number.NEGATIVE_INFINITY', 'Number.NaN', 'Number.isInteger(1e21)',
  'Number.isInteger(-0)',
  "Number('  42  ')", "Number('4 2')", "Number('.')", "Number('+.5')", "Number('5e-1')",
  'Number(false)', "Number('false')",
  'Number([1, 2])', "Number(['0x1f'])", 'Number(new URL("http://a/"))',
  "Number('9007199254740993')", 'Number(1, 2)',
  'Number(-0)', '1 / Number(-0)', 'Number("1e400")', 'Number("-1e400")',
  'String(1)', 'String(1.50)', 'String(null)', 'String(undefined)', 'String(true)',
  'String([1, [2, 3]])', 'String({})',
  'String()', 'String(-0)', 'String(1e21)', 'String(1e-7)', 'String(0.000001)',
  'String(123456789012345680000)', 'String(NaN)',
  'String([null])', 'String([undefined, 1])', "String(new URL('http://a/b'))", "String('x')",
  'String([])', 'String([[]])',
  'String(-Infinity)', 'String(0.1 + 0.2)', 'String(1e300)', 'String(-1e-300)', 'String(100)',
  'String(1.0)', 'String(0x10)',
  'String(123456789.125)', 'String(5e-324)', 'String(1.7976931348623157e308)', 'String(4.35)',
  'String(0.000001234)',
  'String(1e21 - 1)', 'String(999999999999999900000)', "String({toString: () => 'S'})",
  'String(1, 2)',
  'Boolean(0)', "Boolean('0')", "Boolean('')", 'Boolean([])', 'Boolean({})', 'Boolean(null)',
  'Boolean()', 'Boolean(NaN)',
  'Boolean(-0)', "Boolean('false')", 'Boolean(undefined)', 'Boolean(1)', 'Boolean(Infinity)',
  'Boolean(() => 0)',
  // ---- parseInt, parseFloat, isNaN, isFinite ----
  "parseInt('42')", "parseInt('42px')", "parseInt('  42')", "parseInt('-42')", "parseInt('+42')",
  "parseInt('0x1f')",
  "parseInt('0X1F')", "parseInt('1f', 16)", "parseInt('0x1f', 16)", "parseInt('z', 36)",
  "parseInt('101', 2)",
  "parseInt('102', 2)", "parseInt('2', 2)", "parseInt('')", "parseInt('abc')", "parseInt('12.9')",
  'parseInt(12.9)',
  "parseInt('1e3')", 'parseInt(null)', "parseInt('10', 1)", "parseInt('10', 37)",
  "parseInt('10', 0)", "parseInt('-0')",
  "1 / parseInt('-0')", "parseInt('0.00000001')", 'parseInt(0.0000001)',
  "parseInt('123456789012345678901234567890')",
  "parseInt('  -0x10')", "parseInt('0b11')", "parseInt('10', '8')", "parseInt('10', 8.9)",
  "parseInt('7', 4294967304)",
  'parseInt()', "parseInt('0x')", "parseInt('0x', 16)", "parseInt('-')", "parseInt('+')",
  "parseInt('- 1')",
  "parseInt('1 2')", "parseInt('" + NBSP + "12')", "parseInt('" + BOM + "12')",
  "parseInt('12" + cp(0x663) + "')",
  "parseInt('0x1f', 10)", "parseInt('0x1f', 0)", "parseInt('1f')", "parseInt('F', 16)",
  "parseInt('g', 16)",
  "parseInt('Z', 36)", "parseInt('10', -1)", "parseInt('10', NaN)", "parseInt('10', Infinity)",
  "parseInt('10', null)",
  "parseInt('10', undefined)", "parseInt('11', 2.9)", "parseInt('9007199254740993')",
  "parseInt('1'.repeat(30), 2)",
  'parseInt(1e21)', 'parseInt(-0)', 'parseInt([12, 3])', 'parseInt(true)', "parseInt('Infinity')",
  "parseInt('010')",
  "parseInt('0o17')", "parseInt('1_000')", "parseInt('-0x1F')", "parseInt('10', 36)",
  "parseInt('10', 2147483650)",
  "parseFloat('1.5')", "parseFloat('1.5px')", "parseFloat('.5')", "parseFloat('-.5')",
  "parseFloat('5.')", "parseFloat('1e3')",
  "parseFloat('1e')", "parseFloat('e3')", "parseFloat('')", "parseFloat('abc')",
  "parseFloat('  2.5  ')",
  "parseFloat('Infinity')", "parseFloat('-Infinityx')", "parseFloat('infinity')",
  "parseFloat('0x10')", "parseFloat('1_0')",
  "parseFloat('+1.5e+2')", "parseFloat('1.2.3')", "parseFloat('-0')", "1 / parseFloat('-0')",
  'parseFloat(null)',
  "parseFloat('1e1000')", 'parseFloat()', "parseFloat('.')", "parseFloat('+')",
  "parseFloat('1e-5x')", "parseFloat('1E5')",
  "parseFloat('1e+')", "parseFloat('1.5e')", "parseFloat('+.5e1')", "parseFloat('-1e-1000')",
  "1 / parseFloat('-1e-1000')",
  "parseFloat('" + NBSP + "1.5')", "parseFloat('..5')", "parseFloat('5..')", "parseFloat('0.1')",
  'parseFloat(1.5)',
  "parseFloat('+Infinity')", "parseFloat('Infinit')", "parseFloat('1e3.5')", "parseFloat('00.5')",
  'parseFloat([1.5, 2])',
  "isNaN('x')", "isNaN('1')", 'isNaN(undefined)', 'isNaN(null)', 'isNaN()', 'isNaN([])',
  'isNaN({})', "isFinite('1')",
  'isFinite(Infinity)', 'isFinite(null)', "isFinite('x')", 'isFinite()', "isFinite('1e1000')",
  // ---- JSON ----
  'JSON.parse(\'{"a":[1,2,{"b":null}]}\')', "JSON.parse('[]')", "JSON.parse('1')",
  "JSON.parse('\"x\"')", "JSON.parse('null')",
  "JSON.parse('true')", "JSON.parse(' [1 , 2] ')", 'JSON.parse(\'{"b":1,"a":2}\')',
  'JSON.parse(\'{"b":1,"2":2,"1":3}\')',
  "JSON.parse('1.0')", "JSON.parse('1e2')", "JSON.parse('-0')", "1 / JSON.parse('-0')",
  'JSON.parse(\'{"a":1,"a":2}\')',
  "JSON.parse('12345678901234567890')", "JSON.parse('')", "JSON.parse('{a:1}')",
  'JSON.parse(undefined)', 'JSON.parse(null)',
  'JSON.parse(1)', "JSON.parse('[1,]')", 'JSON.parse("\'x\'")', 'JSON.parse()',
  "JSON.parse('[1] x')", "JSON.parse('01')",
  "JSON.parse('1.')", "JSON.parse('.5')", "JSON.parse('+1')", "JSON.parse('NaN')",
  "JSON.parse('tru')", "JSON.parse('\"a')",
  'JSON.parse(\'{"a":{"c":1,"b":[true,false]}}\')', "JSON.parse('\\t[1]\\n')",
  "JSON.parse('[[], {}]')", 'JSON.parse(true)',
  "JSON.parse('1e400')", "JSON.parse('-1e-400')", "JSON.parse('[1.5, 2.0, 3e0]')",
  "JSON.parse('\"" + SMILE + "\"').length",
  "JSON.parse('\"" + BS + BS + 'u00e9' + "\"')",
  "JSON.parse('\"" + BS + BS + 'ud83d' + BS + BS + 'ude00' + "\"').length",
  "JSON.parse('\"a" + BS + BS + 'n' + "\"')", 'JSON.parse(\'{"__proto__": 1}\').__proto__',
  'JSON.parse(process.env.DSH_TEST_CHILD_PATCHES ?? "[]").length', 'JSON.parse([1])',
  'JSON.parse({})',
  'JSON.stringify({a: 1, b: [1, 2, null]})', 'JSON.stringify([undefined, () => 1])',
  'JSON.stringify({a: undefined, b: () => 1, c: 1})',
  'JSON.stringify(undefined)', 'JSON.stringify(() => 1)', 'JSON.stringify(null)',
  "JSON.stringify('a\"b" + BS + "n')",
  'JSON.stringify(NaN)', 'JSON.stringify(Infinity)', 'JSON.stringify(-0)', 'JSON.stringify(1e21)',
  'JSON.stringify(0.1)',
  'JSON.stringify({b: 1, 1: 2})', 'JSON.stringify([1, [2]], null, 2)',
  'JSON.stringify({a: 1}, null, 2)',
  'JSON.stringify({a: []}, null, 4)', 'JSON.stringify({a: {}}, undefined, 1)',
  'JSON.stringify({a: 1}, null, 0)',
  'JSON.stringify({a: 1}, null, 20)', "JSON.stringify({a: 1}, null, '')",
  "JSON.stringify(new URL('http://a/b?c#d'))",
  "JSON.stringify({u: new URL('http://a/')})", 'JSON.stringify({toJSON: () => 5})',
  'JSON.stringify(' + sq(SMILE) + ')',
  'JSON.stringify([NaN, Infinity])', 'JSON.stringify(true)', 'JSON.stringify({a: 1}, null, 2.9)',
  'JSON.stringify({a: 1}, null, true)',
  'JSON.stringify()', 'JSON.stringify([])', 'JSON.stringify({})', 'JSON.stringify([[]])',
  'JSON.stringify({a: [{}]}, null, 2)',
  'JSON.stringify("")', 'JSON.stringify(1.50)', 'JSON.stringify({a: 1}, null, -1)',
  'JSON.stringify({a: 1}, null, NaN)',
  'JSON.stringify([1, {a: [2, {b: 3}]}], null, 3)', 'JSON.stringify({a: 1}, undefined, 10)',
  'JSON.stringify({a: 1}, null, null)',
  'JSON.stringify({"a b": 1, "": 2})', 'JSON.stringify({a: {toJSON: (k) => k + "!"}})',
  'JSON.stringify([{toJSON: (k) => k}])',
  'JSON.stringify({toJSON: () => undefined})',
  'JSON.stringify({a: {toJSON: () => undefined}, b: 1})',
  'JSON.stringify(' + sq(BS + 'u0007' + BS + 'x1f' + LS + E_ACUTE) + ')',
  'JSON.stringify({a: 1e21, b: 1e-7, c: -0, d: 0.1 + 0.2})',
  'JSON.stringify(JSON.parse(\'{"z":1,"10":2,"9":3}\'))', 'JSON.stringify([null, undefined])',
  'JSON.stringify({a: null})',
  'JSON.stringify(process.platform)', 'JSON.stringify([1, 2]).length',
  'JSON.parse(JSON.stringify({a: [1, {b: 2}]})).a[1].b',
  'JSON.stringify({a: 9007199254740993})', 'JSON.stringify("\\"")',
  'JSON.stringify({ a: 1 }, null, 1)',
  // ---- Math ----
  'Math.abs(-5)', "Math.abs('-5')", 'Math.abs(null)', 'Math.abs()', 'Math.ceil(1.2)',
  'Math.ceil(-1.2)', 'Math.ceil(-0.5)',
  '1 / Math.ceil(-0.5)', 'Math.floor(1.8)', 'Math.floor(-1.2)', 'Math.round(2.5)',
  'Math.round(-2.5)', 'Math.round(0.5)',
  'Math.round(-0.5)', '1 / Math.round(-0.5)', 'Math.round(1.4)', 'Math.round(0.49999999999999994)',
  'Math.round(-0.2)',
  '1 / Math.round(-0.2)', 'Math.round(2.4999)', 'Math.round(9007199254740991)', 'Math.sign(-3)',
  'Math.sign(0)', 'Math.sign(-0)',
  '1 / Math.sign(-0)', "Math.sign('x')", 'Math.trunc(1.9)', 'Math.trunc(-1.9)', 'Math.trunc(-0.5)',
  '1 / Math.trunc(-0.5)',
  'Math.max(1, 3, 2)', 'Math.max()', 'Math.max(1, NaN)', 'Math.max(-0, 0)', 'Math.max(0, -0)',
  "Math.max('5', 2)",
  'Math.max(...[1, 2, 3])', 'Math.min(1, 3, 2)', 'Math.min()', 'Math.min(0, -0)', 'Math.min(-0, 0)',
  "Math.min(1, 'x')",
  'Math.PI', '1 / Math.max(-0, 0)', '1 / Math.min(0, -0)', 'Math.max(1, undefined)',
  'Math.min(null, 1)', '1 / Math.max(-0, -0)',
  '1 / Math.min(0, 0)', 'Math.round(1.5)', 'Math.round(-1.5)', 'Math.round(1e21)',
  'Math.round(NaN)', 'Math.round(Infinity)',
  'Math.round(-Infinity)', 'Math.round(4503599627370495.5)', 'Math.round(-4503599627370495.5)',
  'Math.round(0.5000000000000001)',
  'Math.round(-0.5000000000000001)', 'Math.floor(-0)', '1 / Math.floor(-0)', 'Math.ceil(0.1)',
  'Math.floor(5)', 'Math.abs(-0)',
  '1 / Math.abs(-0)', 'Math.abs(-Infinity)', 'Math.trunc(1e21)', 'Math.trunc(NaN)',
  "Math.floor('7.9')", 'Math.ceil([2.1])',
  'Math.max(1, [2])', 'Math.max(Infinity, 1)', 'Math.min(-Infinity, 1)', 'Math.sign(5)',
  'Math.sign(-Infinity)', 'Math.sign()',
  'Math.round("2.5")', 'Math.round(null)', 'Math.round()', 'Math.max(1, 2, "3")', 'Math.min(...[])',
  // ---- Object ----
  'Object.keys({b: 1, a: 2})', 'Object.keys({b: 1, 2: 0, 1: 0})', 'Object.keys([4, 5])',
  "Object.keys('ab')", 'Object.keys(5)',
  'Object.keys(null)', 'Object.keys(undefined)', 'Object.keys()', 'Object.values({a: 1, b: [2]})',
  'Object.entries({a: 1, b: 2})',
  "Object.entries(['x'])", 'Object.keys({})',
  "Object.entries({a: 1}).map(e => e[0] + '=' + e[1]).join('&')",
  'Object.keys(JSON.parse(\'{"z":1,"y":2}\'))', 'Object.values([1, 2])', "Object.values('ab')",
  'Object.entries({})',
  'Object.keys(true)', 'Object.values({b: 1, 1: 2})', 'Object.entries({b: 1, 1: 2})',
  'Object.keys({a: undefined, b: 1}).length < 3',
  "Object.entries('a')", 'Object.keys({...{x: 1}, y: 2})', 'Object.values({a: {b: 1}})[0].b',
  // ---- URI functions ----
  "encodeURIComponent('a b&c/d?e=f')", 'encodeURIComponent(' + sq(E_ACUTE) + ')',
  'encodeURIComponent(' + sq(SMILE) + ')',
  'encodeURIComponent("-_.!~*\'()")', 'encodeURIComponent(null)', 'encodeURIComponent()',
  "encodeURI('http://x/a b?q=1&r=" + E_ACUTE + "#h')",
  'encodeURI(";/?:@&=+$,#")', 'encodeURIComponent(";/?:@&=+$,#")', "encodeURIComponent('%')",
  "encodeURI('%41')", 'encodeURIComponent(12.5)',
  "encodeURIComponent('" + cp(0x7f, 0x80, 0x7ff, 0x800, 0xffff) + "')",
  "encodeURIComponent('[]{}|^`<>" + BS + BS + "\"')",
  "encodeURI('[]{}|^`<>" + BS + BS + "\"')", "encodeURIComponent('aZ09')",
  'encodeURIComponent([1, 2])', "encodeURI('" + SMILE + "')",
  "decodeURIComponent('a%20b%2Fc')", "decodeURIComponent('%E4%BD%A0')",
  "decodeURIComponent('%F0%9F%98%80').length",
  "decodeURIComponent('%')", "decodeURIComponent('%E4%BD')", "decodeURIComponent('%C0%80')",
  "decodeURIComponent('%zz')",
  "decodeURIComponent('%ED%A0%80')", "decodeURIComponent('a+b')", "decodeURI('%2F%20%23%41')",
  "decodeURI('a%3Fb%3fc')",
  "decodeURIComponent('%41%62')", 'decodeURIComponent()', "decodeURI('%E4%BD%A0%2f')",
  "decodeURIComponent('%e4%bd%a0')",
  "decodeURIComponent('%4')", "decodeURIComponent('%F8%80%80%80')", "decodeURIComponent('%80')",
  "decodeURIComponent('%E0%80%80')",
  "decodeURIComponent('%F4%90%80%80')", "decodeURIComponent('%C3%A9%C3')",
  "decodeURIComponent('%7E%7e%00').length",
  "decodeURI('%3B%2F%3F%3A%40%26%3D%2B%24%2C%23')", "decodeURI('%25%20')",
  "decodeURIComponent('100%25')", "decodeURIComponent('%E2%82%AC')",
  "decodeURIComponent('" + E_ACUTE + "%20')", 'decodeURIComponent(null)',
  "decodeURIComponent(encodeURIComponent('" + SMILE + E_ACUTE + " /?'))",
  "decodeURI(encodeURI('http://x/" + E_ACUTE + " y?z=1#h'))", "decodeURIComponent('%C3%28')",
  "decodeURIComponent('%F0%9F%98')",
  // ---- URL ----
  ...['href', 'protocol', 'username', 'password', 'host', 'hostname', 'port', 'pathname', 'search',
    'hash', 'origin']
    .flatMap((property) => [
      "new URL('http://example.com/a/b?x=1#frag')." + property,
      "new URL('https://user:pa%20ss@Example.COM:8443/p/a/t/h?query=string#hash')." + property,
      "new URL('file:///opt/dsh/snapshots/cases/demo/snapshot.yml')." + property,
      "new URL('ws://h:80')." + property,
    ]),
  ...['g', './g', 'g/', '/g', '//g', '?y', 'g?y', '#s', 'g#s', 'g?y#s', ';x', 'g;x', 'g;x?y#s', '',
    '.', './', '..', '../',
    '../g', '../..', '../../', '../../g', '../../../g', '../../../../g', '/./g', '/../g', 'g.',
    '.g', 'g..', '..g', './../g',
    './g/.', 'g/./h', 'g/../h', 'g;x=1/./y', 'g;x=1/../y', 'g?y/./x', 'g?y/../x', 'g#s/./x',
    'g#s/../x', 'http:g', 'http:/g',
    'http://g', 'https:g', '?', '#', '//g:81/h', '/', '//', '///', '////x', '\\\\g', '\\g', 'g\\h',
    '.\\g', ' g ', 'g\th',
    '%2e', '%2E/g', '.%2e/g', '%2e%2e/%2E./g', 'g/%2e%2e', '...', './.', '././g', 'a b', 'a"b',
    "a'b", 'a?b c', "a?b'c", 'a#b c',
    'a#b`c', 'a{b}', 'a|b', 'a^b', 'a~b', 'a[b]', 'a<b>', 'a%zz', 'a%', E_ACUTE, SMILE,
    '?' + E_ACUTE, '#' + E_ACUTE, ':g',
    '1g', '-g', '+g', 'g?h#i?j#k', '??', '##', '?#', '#?', 'g?', 'g#', 'g?#', '/g/../..', '/g//h',
    '/g/./', '/g/h/..'
  ].map((reference) => 'new URL(' + JSON.stringify(reference) + ', ' + RFC + ').href'),
  "new URL('http://example.com').href", "new URL('http://example.com').pathname",
  "new URL('HTTP://EXAMPLE.COM:80/A').href",
  "new URL('https://example.com:443/').port", "new URL('https://example.com:8443/').host",
  "new URL('http://user:pa ss@example.com/').href",
  "new URL('http://u@example.com').username", "new URL('file:///a/b/c.txt').pathname",
  "new URL('./runner.mjs', 'file:///opt/dsh/snapshots/x/snapshot.yml').pathname",
  "new URL('../../../packages/x.ts', 'file:///opt/dsh/snapshots/cases/demo/snapshot.yml').href",
  "new URL('file://' + '/opt/a b/c').pathname", "new URL('file:///C:/Users/x').pathname",
  "new URL('file://C:/x').href",
  "new URL('file:///c|/x').pathname", "new URL('/x', 'file:///C:/a/b').href",
  "new URL('..', 'file:///C:/a').href",
  "new URL('../..', 'file:///C:/a/b').href", "new URL('file://localhost/etc').href",
  "new URL('file://host/share/x').href",
  "new URL('file:/a').href", "new URL('file:a', 'file:///x/y').href",
  "new URL('file:///a/../b/./c').pathname",
  "new URL('file:///a/%2e%2E/b').pathname", "new URL('file:///a b').pathname",
  "new URL('file:///a?x y#z w').href",
  "new URL('//host/x', 'file:///a').href", "new URL('file:///" + E_ACUTE + "').pathname",
  "decodeURIComponent(new URL('file:///a%20b/" + E_ACUTE + "').pathname)", "new URL('file:').href",
  "new URL('file://').href",
  "new URL('file:///').href", "new URL('file:////a').href", "new URL('file://///a').href",
  "new URL('file:a').href",
  "new URL('file:a/b').href", "new URL('file:./a').href", "new URL('file:..').href",
  "new URL('file:?q').href",
  "new URL('file:#f').href", "new URL('a', 'file:').href", "new URL('a', 'file:///').href",
  "new URL('a', 'file:///d/').href",
  "new URL('', 'file:///d/e?q#f').href", "new URL('?x', 'file:///d/e?q#f').href",
  "new URL('#x', 'file:///d/e?q#f').href",
  "new URL('/', 'file:///d/e').href", "new URL('//', 'file:///d/e').href",
  "new URL('///', 'file:///d/e').href",
  "new URL('//h', 'file:///d/e').href", "new URL('//h/p', 'file://g/d/e').href",
  "new URL('p', 'file://g/d/e').href",
  "new URL('/p', 'file://g/d/e').href", "new URL('file:p', 'file://g/d/e').href",
  "new URL('file:/p', 'file://g/d/e').href",
  "new URL('file://LOCALHOST/p').href", "new URL('file://localhost').href",
  "new URL('file://Host.Example/p').host",
  "new URL('file:///C:').href", "new URL('file:///C:/').href", "new URL('file:///C|').href",
  "new URL('file:///C|/a/../..').href",
  "new URL('file:///c:/a/../../b').href", "new URL('file:C:/a').href", "new URL('file:/C:/a').href",
  "new URL('file://C:').href",
  "new URL('file://C|/a').href", "new URL('file:///CC:/a').href", "new URL('file:///1:/a').href",
  "new URL('file:///a/C:/b').href",
  "new URL('file:D:/x', 'file:///C:/a/b').href", "new URL('/D:/x', 'file:///C:/a/b').href",
  "new URL('//D:/x', 'file:///C:/a/b').href", "new URL('x', 'file:///C:/a/b').href",
  "new URL('/x/y', 'file:///C:/a/b').href",
  "new URL('../../../x', 'file:///C:/a/b').href", "new URL('/..', 'file:///C:/a/b').href",
  "new URL('file:x', 'file:///C:/a/b').href",
  "new URL('file:/x', 'file:///C:/a/b').href", "new URL('?q', 'file:///C:/a/b').href",
  "new URL('d|/x', 'file:///C:/a/b').href",
  "new URL('/d|/x', 'file:///C:/a/b').href", "new URL('d|', 'file:///C:/a/b').href",
  "new URL('d|x', 'file:///C:/a/b').href",
  "new URL('d|?q', 'file:///C:/a/b').href", "new URL('d|#f', 'file:///C:/a/b').href",
  "new URL('file:///a/b c/d" + BS + BS + "e').href",
  "new URL('file://' + process.env.DSH_SNAPSHOT_FILE).href",
  "new URL('./runner.mjs', 'file://' + process.env.DSH_SNAPSHOT_FILE).pathname",
  "new URL('file:///a/b?c d#e f').search", "new URL('file:///%41%zz%7e').pathname",
  "new URL('file:///a/./b/../c/').pathname",
  "new URL('http://a/b c?d e#f g').href",
  'new URL("http://a/\\"<>`{}^|?\\"<>`{}^|\'#\\"<>`{}^|").href',
  "new URL('http://a/%zz').pathname", 'new URL("http://a/?q=\'x\'").search',
  "new URL('http://a/" + SMILE + "').pathname",
  "new URL('http://a" + BS + BS + 'b' + BS + BS + "c').href",
  "new URL(' " + BS + "t http://a/b " + BS + "n').href",
  "new URL('ht" + BS + "ntp://a/b').href", "new URL('http://a/b" + BS + "tc').href",
  "new URL('http://EXAMPLE.com/').hostname",
  "new URL('http://192.168.0.1/').hostname", "new URL('http://0x7f.1/').hostname",
  "new URL('http://127.1/').hostname",
  "new URL('http://017700000001/').hostname", "new URL('http://1.2.3.4.5/')",
  "new URL('http://256.1.1.1/')",
  "new URL('http://1.2.3/').hostname", "new URL('http://example.com./').hostname",
  "new URL('http://a..b/').hostname",
  "new URL('http://a b/')", "new URL('http://a<b/')", "new URL('http:///x').href",
  "new URL('http://').href",
  "new URL('http:/a/b').href", "new URL('http:a/b').href",
  "new URL('http:a/b', 'http://x/y/z').href",
  "new URL('https:a/b', 'http://x/y/z').href", "new URL('http://a:b@c:8/').port",
  "new URL('http://a:65536/')",
  "new URL('http://a:x/')", "new URL('http://a:/').href", "new URL('http://a:0080/').port",
  "new URL('http://@a/').href",
  "new URL('http://:@a/').href", "new URL('http://u:@a/').href", "new URL('http://:p@a/').href",
  "new URL('http://u@v@a/').username",
  "new URL('http://u:p:q@a/').password", "new URL('ws://a/').origin",
  "new URL('wss://a:443/').href", "new URL('ftp://a:21/x').href",
  "new URL('file:///x').origin", "new URL('nope')", "new URL('')", "new URL('/a')",
  "new URL('/a', 'nope')", 'new URL()',
  "URL('http://a')", "new URL('http://a/b').toString()", "new URL('http://a/b').toJSON()",
  "'' + new URL('http://a/b')",
  "`${new URL('http://a/b')}`", "new URL(new URL('http://a/b')).href",
  "new URL('c', new URL('http://a/b')).href",
  "new URL('http://a/b') + '?x'", "typeof new URL('http://a')", "new URL('http://a/b').nope",
  "new URL('http://a/b?').search",
  "new URL('http://a/b#').hash", "new URL('http://a/b?#').href",
  "new URL('?', 'http://a/b?x').href", "new URL('#', 'http://a/b#x').href",
  "new URL('', 'http://a/b?x#y').href", "new URL('http://a/b/../../../c').pathname",
  "new URL('http://a/./b/.').pathname",
  "new URL('http://a/b/..').pathname", "new URL('http://a//b//c').pathname",
  "new URL('http://a/b/%2e%2e/c').pathname",
  "new URL('http://a/b/.%2E').pathname", "new URL('http://a/b/%2e').pathname",
  "new URL('1', 'http://a/b/').href",
  "new URL('http://a?x').href", "new URL('http://a#x').href", "new URL('http://A.B.C/').host",
  "new URL('http://a.b.c:80/').host",
  "new URL('https://a:80/').host", "new URL('http://a:443/').port", "new URL('ws://a:443/').port",
  "new URL('wss://a:80/').port",
  "new URL('ftp://a:80/').port", "new URL('http://a:00000/').port",
  "new URL('http://a:65535/').port", "new URL('http://a:1' + '0'.repeat(5))",
  "new URL('http://0/').hostname", "new URL('http://0x0/').hostname",
  "new URL('http://0xffffffff/').hostname",
  "new URL('http://0x100000000/')", "new URL('http://4294967295/').hostname",
  "new URL('http://4294967296/')",
  "new URL('http://1.0x10/').hostname", "new URL('http://1.2.65535/').hostname",
  "new URL('http://1.2.65536/')",
  "new URL('http://1.256.3/')", "new URL('http://1.2.3.4./').hostname",
  "new URL('http://1.2.3.4../')", "new URL('http://1..2/')",
  "new URL('http://a.1/')", "new URL('http://a.0x1/')", "new URL('http://1.a/').hostname",
  "new URL('http://09/')",
  "new URL('http://0x/').hostname", "new URL('http://1.2.3.08/')",
  "new URL('http://1.2.3.0x/').hostname", "new URL('http://./').hostname",
  "new URL('http://../').hostname", "new URL('http://a_b/').hostname",
  "new URL('http://a-b.c-/').hostname", "new URL('http://-a/').hostname",
  "new URL('http://a%/')", "new URL('http://a|b/')", "new URL('http://a^b/')",
  "new URL('http://a[b/')", "new URL('http://a]b/')",
  "new URL('http://a@/')", "new URL('http://@/')", "new URL('http://:80/')",
  "new URL('http://a:b:c/')", "new URL('http://a/:b').href",
  "new URL('http://u:p@/')", "new URL('http://u:p@h').href",
  "new URL('http://u%40:p%3A@h').username", "new URL('http://u s:p/q@h').href",
  "new URL('http://" + E_ACUTE + ":" + SMILE + "@h/').href", "new URL('http://u;=:[]|@h/').href",
  "new URL('http://a?b?c').search",
  "new URL('http://a#b#c').hash", "new URL('http://a/b?c#d?e').href",
  "new URL('http://a/?a=1&b=2').search", "new URL('http://a/#').href",
  "new URL('http://a/?').href", "new URL('http://a/ ').href", "new URL('http://a/ b ').pathname",
  "new URL('http://a/b/c/../../../../d').href",
  "new URL('http://a/..').href", "new URL('http://a/../').href", "new URL('http://a/.').href",
  "new URL('http://a/./').href",
  "new URL('http://a/b/.' + '.').href", "new URL('http://a/%2E%2E/b').href",
  "new URL('http://a/b/%2e%2E/').href",
  "new URL('http://a/b/..%2f').href", "new URL('http://a/b;c=d/e').pathname",
  "new URL('http://a/b%20c%2Fd').pathname",
  "new URL('http://a/" + E_ACUTE + "?" + E_ACUTE + "#" + E_ACUTE + "').href",
  "new URL('http://a/~!$&*()_+-=,.;:@').pathname",
  "new URL('http:" + BS + BS + BS + BS + "a/b').href", "new URL('http:/" + BS + BS + "a').href",
  "new URL('http:a').href",
  "new URL('http:').href", "new URL('http:/').href", "new URL('http:?q').href",
  "new URL('http:#f').href", "new URL('http::80/')",
  "new URL('HtTpS://a').protocol", "new URL('h ttp://a')", "new URL('http ://a')",
  "new URL('://a')", "new URL('//a')",
  "new URL('//a', 'https://b/c').href", "new URL('/a/../b', 'https://b/c').href",
  "new URL('a/b', 'https://x/c/d?q#f').href",
  "new URL('', 'http://a').href", "new URL('.', 'http://a/b/c').href",
  "new URL('..', 'http://a/b/c').href",
  "new URL('../../..', 'http://a/b/c').href", "new URL('?', 'http://a/b').href",
  "new URL('#', 'http://a/b').href",
  "new URL(' ', 'http://a/b?q').href", "new URL('http://c', 'http://a/b').href",
  "new URL('https://c', 'http://a/b').href",
  "new URL('http:c', 'http://a/b/').href", "new URL('http:/c', 'http://a/b/').href",
  "new URL('http:?c', 'http://a/b').href",
  "new URL('ws:c', 'http://a/b').href", "new URL('file:c', 'http://a/b').href",
  "new URL('http:c', 'file:///a/b').href",
  "new URL(null, 'http://a/b/').href", "new URL(undefined, 'http://a/b/').href",
  "new URL(1, 'http://a/b/').href",
  "new URL('x', undefined)", "new URL('http://a/b', undefined).href", "new URL('x', null)",
  "new URL('http://a/b', null)",
  "new URL(['http://a/b']).href", "new URL('http://a/b').href.length",
  "new URL('http://a/b').pathname.split('/')",
  "new URL('http://a/b') == 'http://a/b'", "new URL('http://a/b') === new URL('http://a/b')",
  "!!new URL('http://a')",
  "new URL('http://a/b', 'http://c/d').href", "new URL('HTTP://A/B', 'http://c/d').href",
  "new URL('http://a/b?x=%zz&y=%41').search",
  "new URL('http://a/b#%zz %41').hash", "new URL('http://a/" + BS + "u{1F600}').pathname.length",
  "new URL('http://a/" + cp(0x7f) + "').pathname", "new URL('http://a/?" + cp(0x7f) + "').search",
  "new URL('http://a/#" + cp(0x7f) + "').hash",
  "new URL('http://a/" + cp(0x1) + "b').pathname", "new URL('http://a/b?" + cp(0x1) + "').search",
  "new URL('http://a/#" + cp(0x1) + "').hash",
  "new URL('" + cp(0x1) + ' ' + "http://a/b" + cp(0x1f) + ' ' + "').href",
  "new URL('ht" + BS + "tt" + BS + "rp://a/" + BS + "nb').href",
  "new URL('http://a%41/').hostname", "new URL('http://%41%2e%42/').hostname",
  "new URL('http://a%2Fb/')", "new URL('http://%31%32%37.1/').hostname",
  "new URL('http://a%zzb/')", "new URL('http://a%25b/')", "new URL('http://A%20B/')",
  // ---- node:path ----
  ...["join('a', 'b', '../c')", 'join()', "join('')", "join('', '')", "join('/a/', '/b/')",
    "join('a', '', 'b')", "join('..', 'a')",
    "join('a', '../..')", "join('a', '../../..')", "join('/a', '../..')", "join('/', '..')",
    "join('./a', './b')", "join('a/', 'b/')",
    "join('a', {})", "join('a', undefined)", "join(1)", "join('a', null)", "join('/')",
    "join('//a')", "join('a', '/b')",
    "join('.', 'a')", "join('a', '.')", "join('a/b', '..', '..', '..')",
    "join('/a/b', '..', '..', '..')", "join('a//b///c')",
    "join(' ', 'a')", "join('a', '..', '..', 'b')", "join('./', './')", "join('...', '..')",
    "join('a', 'b/../../../c')",
    "normalize('')", "normalize('.')", "normalize('./')", "normalize('/')", "normalize('//')",
    "normalize('a//b/../c/.')",
    "normalize('/a/b/../../..')", "normalize('../a/..')", "normalize('a/..')", "normalize('a/../')",
    "normalize('./a/')",
    "normalize('/..')", "normalize('...')", "normalize('a/.../b')", "normalize('.a/..b/c..')",
    "normalize('../../a')",
    "normalize('a/../../b')", "normalize('/a/./b/')", "normalize('///a///')", "normalize('./.')",
    "normalize('./..')",
    "normalize('../.')", "normalize('a/b/c/../../../..')", "normalize('/a/b/c/../../../..')",
    "normalize('..')", "normalize('../')",
    "normalize('a/./')", "normalize(' ')", "normalize('a b/c d')", "normalize(1)", "normalize()",
    "normalize('C:" + BS + BS + "a')",
    'resolve()', "resolve('a')", "resolve('/a', 'b')", "resolve('/a', '/b')",
    "resolve('a', '..', '..', '..', '..')", "resolve('')",
    "resolve('/a/b', '../c', './d')", "resolve('a/b/', '../')", "resolve('/')",
    "resolve('/a/', '')", "resolve('', '')",
    "resolve('.', '.')", "resolve('..')", "resolve('/a', '..', '..')", "resolve('a', '/b', 'c')",
    "resolve('/a/b/')", "resolve('//a')",
    "resolve('/a//b/./c/..')", "resolve('x', '', 'y')", "resolve('/', 'a', '/')", "resolve(1)",
    "resolve('a', null)",
    "dirname('/a/b/c')", "dirname('/a/b/c/')", "dirname('/a')", "dirname('/')", "dirname('//')",
    "dirname('//a')", "dirname('a')",
    "dirname('')", "dirname('a/b')", "dirname('a//b')", "dirname('a/')", "dirname('./a')",
    "dirname('../a')", "dirname('/a//')",
    "dirname('///a')", "dirname('a/b/')", "dirname('a/b//')", "dirname('.')", "dirname('..')",
    "dirname('/a/b')", "dirname('//a/b')",
    "dirname('a//')", "dirname('/a/')", "dirname(' ')", "dirname()", "dirname(null)",
    "dirname('a/b/c.txt')",
    "basename('/a/b/c.txt')", "basename('/a/b/c.txt', '.txt')", "basename('/a/b/c.txt', 'c.txt')",
    "basename('/a/b/c.txt', 'xt')",
    "basename('c.txt', '.md')", "basename('/a/b/')", "basename('/')", "basename('')",
    "basename('a')", "basename('a//')",
    "basename('/a/b.txt//', '.txt')", "basename('abc', 'abc')", "basename('/abc', 'abc')",
    "basename('a/bc', 'x/bc')",
    "basename('.txt', '.txt')", "basename('a.txt', '')", "basename('//')", "basename('a/b')",
    "basename('a/b/')", "basename('a.b.c', '.c')",
    "basename('a.b.c', 'b.c')", "basename('a.b.c', 'a.b.c')", "basename('/a.b.c', 'a.b.c')",
    "basename('abc', 'bc')", "basename('abc', 'abcd')",
    "basename('a/', 'a')", "basename('aa/', 'a')", "basename('a', 'a/')", "basename('x/a', 'x/a')",
    "basename('x/a/', 'a/')",
    "basename('a.txt', 1)", "basename()", "basename('a', undefined)", "basename('a', null)",
    "basename('/a/b', 'b')", "basename('ab', 'b')",
    "basename('b', 'b')", "basename('/b/', 'b')", "basename('ab/', 'b')",
    "basename('a.txt/', 'xt')", "basename('.', '.')", "basename('..', '.')",
    "extname('a.txt')", "extname('a.b.c')", "extname('.bashrc')", "extname('a.')", "extname('a')",
    "extname('')", "extname('..')",
    "extname('.')", "extname('...')", "extname('/a.d/b')", "extname('/a/b.c/')", "extname('a..b')",
    "extname('.a.b')", "extname('..a')",
    "extname('a/.b')", "extname('a/b.')", "extname('a.b/')", "extname('a.b//')", "extname('/')",
    "extname('a/..')", "extname('a/...')",
    "extname('.a.')", "extname('a.b.')", "extname('....')", "extname('a/.')", "extname('/.a')",
    "extname('a.b/c')", "extname(1)", "extname()",
    "isAbsolute('/a')", "isAbsolute('a')", "isAbsolute('')", "isAbsolute('//')",
    "isAbsolute('./a')", "isAbsolute(1)", 'sep', 'delimiter',
  ].map((call) => P + '.' + call),
  P + '.join(process.cwd(), ' + sq('a') + ')', P + ".dirname(" + P + ".resolve('x/y'))",
  "typeof " + P, "typeof " + P + '.join',
  "process.getBuiltinModule('path').sep", "process.getBuiltinModule('path').join('a', 'b')",
  // ---- node:os and process ----
  OS + '.homedir()', OS + '.tmpdir()', OS + '.platform()', OS + '.EOL',
  "process.getBuiltinModule('os').homedir()", 'typeof ' + OS + '.homedir',
  'process.platform', 'process.cwd()', 'process.execPath === process.execPath',
  'typeof process.execPath', 'typeof process.env.HOME',
  'process.env.NOPE', "process.env.NOPE ?? 'd'", "process.env.HOME + '/x'",
  "process.env['DSH_SNAPSHOT']", 'process.env.DSH_SNAPSHOT?.toUpperCase()',
  'process.env.NOPE?.toUpperCase()', "process.env.HOME.split('/')", "process.env['HO' + 'ME']",
  'process.env[`HOME`].length',
  "process.env.DSH_TELEMETRY_MODE === ''", "process.env.DSH_TELEMETRY_MODE ?? 'unset'",
  "process.env.DSH_TELEMETRY_MODE || 'empty'",
  "process.getBuiltinModule('node:module').createRequire(baseUrl).resolve('nope-not-installed')",
  "process.getBuiltinModule('node:module').createRequire('relative/path')",
  "process.getBuiltinModule('node:module').createRequire(5)",
  "typeof process.getBuiltinModule('node:module').createRequire(baseUrl)",
  "typeof process.getBuiltinModule('node:module').createRequire(baseUrl).resolve",
  "typeof process.getBuiltinModule('node:module').createRequire(new URL(baseUrl))",
  "typeof process.getBuiltinModule('node:module').createRequire('/abs/path.js')",
  'process.getBuiltinModule(5)', 'process.getBuiltinModule()',
  // ---- context scope ----
  'baseUrl', 'typeof ctx.get', "ctx.get('profileContext')", "ctx.get('profileContext')?.name",
  "ctx.get('nope')", "ctx.get('headlessStartup').task",
  'ctx.headlessStartup', 'ctx.webStartup', 'headlessStartup.task', 'webStartup.port + 1',
  'ctx.webStartup.host', 'ctx.webStartup.tls',
  "ctx.webStartup.trustedHosts.includes('dsh.example')",
  'ctx.headlessStartup.additionalWritableRoots.map((p) => p + "/x")',
  "dshHomePath()", "dshHomePath('a', 'b', '..', 'c')",
  "dshHomePath('sessions').endsWith('/sessions')", 'ctx.nope', 'ctx.nope?.x',
  'ctx.baseUrl === baseUrl',
  "new URL('./local.yml', baseUrl).href", "new URL('.', baseUrl).pathname",
  "decodeURIComponent(new URL('../x y', baseUrl).pathname)",
  '[ctx.headlessStartup.task, ctx.headlessStartup.sessionId].join(":")',
  '({...ctx.headlessStartup}).json', 'Object.keys(ctx.webStartup)',
  'JSON.stringify(ctx.webStartup)', 'JSON.stringify(ctx.headlessStartup, null, 2)',
  "`${ctx.headlessStartup.sessionId}-${ctx.webStartup.port}`",
  // ---- comments and layout ----
  '1 // c', '1 /* c */ + /* d */ 2', '/* c */ 1', '// c\n1', '1\n// c', '1 +\n2', '1\n+ 2',
  "'a'\n.length", '(1\n)', '[1,\n2]', '({a:\n1})',
  '1 /* multi\nline */ + 2', "'/* not a comment */'", "'// not a comment'", '`// ${1} /* x */`',
  ' 1 ', '\t1\n', '\n\n1', '1' + NBSP,
  BOM + '1', '1' + LS, '(x =>\nx)(1)', "null\n?? 2", "1\n? 2\n: 3", "[1, 2]\n.map(x => x)\n.length",
  '(\n1 +\n2\n) *\n3', '1/*a*/+/*b*/1',
  '', ' ', '// only a comment', '/* only */',
]

const syntaxErrorSources = [
  '1 +', '(1', '1)', '[1, 2', "'abc", '"abc', '`abc', 'a b', '1 2', 'a.', 'a?.', '.a', 'a..b',
  '1.toString()', 'a ? b', 'a ? b :',
  '? a : b', 'a ?? b || c', 'a || b ?? c', 'a && b ?? c', 'a ?? b && c', 'x =>', '=> 1',
  '(a b) => 1', '(1) => 1', '(a.b) => 1',
  'a => => 1', '()', '(,)', '[1 2]', '({a 1})', '({a: })', '({,})', '({a: 1,,})', 'String(,)',
  'String(1,,2)', '!', 'typeof', 'new',
  'a.#b', '@', '#', "'a' 'b'", '1_', '1__0', '0x', '0b2', '1e', '1.5.5', sq(BS + 'u00'),
  sq(BS + 'x4'), sq(BS + 'u{110000}'),
  sq(BS + 'u{}'), '`${', '`${}`', '`${1', 'a ? : b', '1 +* 2', '* 2', 'a[', 'a[]', 'a[1', 'String(',
  'String(1', 'new URL(', 'a.1',
  'a?.1', '...a', '[...]', '({...})', 'String(...)', 'a ??', '&& a', 'a ||', 'a ===', '!== a',
  'a <', '(a, )', "'a\nb'", '"a\nb"',
  '1 ?? 2 || 3', '1 || 2 ?? 3', '(1 ?? 2) || 3 ?? 4', '1 && 2 ?? 3', 'a || x => x', '1 + x => x',
  '!x => x', 'x => x || y => y',
  '(a, a) => 1', '((a)) => 1', '(a,, b) => 1', 'a => 1 => 2', '({a}', '({a = 1})', '({1})',
  "({'a'})", '({a b})', '({a:1 b:2})',
  'new', 'new ()', 'new .x', 'a?.`x`', '1 ? 2 : ', 'x ? y, z : w', '`${1}', '`${1 2}`', '0_1',
  '1._5', '1e_5', '0x_1', '1_.5',
  '3in [1]', '1 2 3', 'a.b c', "a 'b'", ')', ']', '}', ',', ':', '=>', '?.a', '?? a', '1 +', '1 -',
  '1 *', '1 /', '1 %',
  '1 <', '1 >=', '1 ==', '1 !=', '(', '[', 'a ? (b : c)', '(a ? b) : c', '[a ? b] : c',
  '`' + BS + '1`', '`' + BS + '08`', '`' + BS + 'u{110000}`',
  "'" + BS + "u{1F60'", 'a ?. ', 'a . ', '. 5 5', '1.e', '0b', '0o', '0o8', '0B2', '0X', '.e1',
  '1e+', '1e-',
  'x => x x', '(x) => ', '() => ,', 'f(a b)', 'f(a,, b)', 'a[, 1]', '({a: 1, b})c', '({[a] 1})',
  '({[a]})', '({[]: 1})',
]

const unsupportedSources = [
  // ---- statements and assignment ----
  'scratch = 1', 'scratch += 1', 'scratch++', '++scratch', 'scratch--', '--scratch',
  'scratch ||= 1', 'scratch ??= 1', 'scratch &&= 1',
  '1, 2', '(1, 2)', '1; 2', '1;', ';', '{ a: 1 }', '{}', 'var v = 1', 'let v = 1', 'const v = 1',
  'if (1) 2', 'for (;;) break',
  'while (0) 1', 'do 1; while (0)', 'function f() {}', '(function () {})',
  '(function () { return 1 })()', 'class A {}', '(class {})',
  '() => { return 1 }', '() => {}', 'async () => 1', 'async x => x', 'async function f() {}',
  '(async function () {})', 'function* g() {}',
  '({ f() { return 1 } })', '({ get a() { return 1 } })', '({ set a(v) {} })', '({ async f() {} })',
  '({ *g() {} })', '({ __proto__: null })',
  '/a/', "/a/g.test('a')", "'a'.replace(/a/, 'b')", 'String.raw`a`', '(x => x)`a`', 'this',
  'this.process', 'delete ({}).a',
  "'a' in ({a: 1})", '[] instanceof Array', '2 ** 3', '1 | 2', '1 & 2', '1 ^ 2', '~1', '1 << 2',
  '8 >> 1', '8 >>> 1', '1n', '1n + 2n',
  '017', '08', '08.5', sq(BS + '07'), sq(BS + '1'), '[1, , 2]', '[,]', '(...a) => 1',
  '(a = 1) => a', '({a}) => a', '([a]) => a', 'x => { }',
  'label: 1', 'try { 1 } catch { 2 }', 'switch (1) {}', '1\n2', 'a\nb', '1 ? 2 : 3; 4',
  'scratch, scratch',
  // ---- globals ----
  'Date.now()', 'new Date()', 'globalThis', 'globalThis.process', "Buffer.from('a')", "Symbol('x')",
  'new Map()', 'Promise.resolve(1)',
  'new Error("x")', 'RegExp("a")', 'typeof Date', 'typeof Symbol', 'structuredClone({})',
  'console.log', 'new Set([1])', 'BigInt(1)',
  'Reflect.ownKeys({})', 'new URLSearchParams("a=1")', 'Intl.NumberFormat', 'setTimeout',
  'queueMicrotask', 'Function("return 1")', 'eval("1")',
  // ---- members ----
  'Math.random()', 'Math.pow(2, 3)', 'Math.sqrt(4)', "'abc'.charCodeAt(0)",
  "'abc'.lastIndexOf('c')", "'abc'.match('b')",
  "'a'.localeCompare('b')", "'a'.normalize()", "'abc'.substr(1)", "'a'.codePointAt(0)",
  "'abc'.search('b')", "'a'.toLocaleUpperCase()",
  '[3, 1].sort()', '[1].push(2)', '[1, 2].reverse()', '[1].reduce((a, b) => a + b, 0)',
  '[1].forEach(x => x)', '[[1]].flat()',
  '[1].flatMap(x => [x])', '[1].findIndex(x => x)', '[1, 2].lastIndexOf(2)', '[1].keys()',
  '[1].entries()', '[1].toSorted()', '[1].pop()',
  '(1.5).toPrecision(2)', '(1.5).toExponential()', '(1).toLocaleString()', '({}).toString()',
  "({}).hasOwnProperty('a')", '({}).constructor',
  '({}).valueOf()', '({}).__proto__', '[].constructor', "''.constructor", '(1).constructor',
  '(() => 1).call(null)', '(() => 1).name',
  '(() => 1).length', '((a) => a).bind(null)', '(() => 1).apply(null, [])',
  'Object.assign({}, {a: 1})', 'Object.fromEntries([])',
  'Object.freeze({})', 'Object.getOwnPropertyNames({})', "Array.from('ab')", 'Array.of(1)',
  'Array(3)', 'new Array(3)', 'new Object()',
  'Object()', 'new Number(1)', "new String('a')", 'new Boolean(false)', 'String.fromCharCode(65)',
  'Number.prototype', 'String.prototype',
  "JSON.stringify({a: 1}, ['a'])", 'JSON.stringify({a: 1}, (k, v) => v)',
  "JSON.stringify({a: 1}, null, '--')", "JSON.parse('1', (k, v) => v)",
  'JSON[Symbol.toStringTag]', 'Math.E', 'Math.hypot(3, 4)', '(1.5).toString(2)',
  '(0.1).toString(16)', 'Number.parseInt.length',
  // ---- URL ----
  "new URL('http://a/?x=1').searchParams.get('x')", "new URL('mailto:a@b').href",
  "new URL('data:text/plain,hi').pathname",
  "new URL('http://[::1]/').hostname", "new URL('http://xn--bcher-kva.example/').hostname",
  "new URL('http://b%C3%BCcher.example/').hostname",
  "new URL('http://b" + cp(0xfc) + "cher.example/').hostname", "URL.canParse('http://a')",
  "new URL('x:y', 'http://a/b').href",
  "new URL('C:/d', 'file:///a/b').href", "new URL('about:blank').href",
  "new URL('blob:http://a/b').href", "new URL('a', 'mailto:x@y').href",
  "new URL('http://[1::2]:80/').port", "new URL('git+ssh://a/b').href",
  "new URL('g:', 'http://a/b').href", "new URL('D:/x', 'file:///C:/a/b').href",
  // ---- process and node modules ----
  'process.argv', 'process.version', 'process.pid', 'process.arch', 'process.versions.node',
  'process.exit', "process.getBuiltinModule('node:fs')",
  "process.getBuiltinModule('node:url').fileURLToPath('file:///a')",
  "process.getBuiltinModule('node:child_process')", P + ".relative('/a', '/b')",
  P + ".parse('/a/b')", P + '.posix.sep', P + '.win32.sep', P + ".format({dir: '/a', base: 'b'})",
  OS + '.hostname()', OS + '.cpus()', OS + '.userInfo()',
  "process.getBuiltinModule('node:module').createRequire('/x/y')('fs')",
  "process.getBuiltinModule('node:module').createRequire('/x/y').resolve('fs', {})",
  "process.getBuiltinModule('node:module').builtinModules", "'a' + process",
  'JSON.stringify(process.env)', '({...process.env})', 'Object.keys(process.env)',
  '[...process.env]', 'String(process)', '`${process}`', 'process + 1',
  // ---- values this model cannot represent ----
  '[] === []', '[] == []', '[] !== []', "'a" + SMILE + "'.split('')", sq(SMILE) + '[0]',
  sq(SMILE) + '.at(0)', sq(SMILE) + '.slice(0, 1)',
  sq(SMILE) + '.charAt(1)', sq(SMILE) + '.substring(1)', sq(BS + 'uD83D'),
  sq(BS + 'uDE00' + BS + 'uD83D'), '`' + BS + 'uD83D`', sq(SMILE) + ".padEnd(3, '" + SMILE + "')",
  "({...'" + SMILE + "'})", "Object.keys('" + SMILE + "').map(i => '" + SMILE + "'[i])",
  "Object.values('" + SMILE + "')", sq(SMILE) + ".replaceAll('', '-')",
  '(() => 1) + 1', 'String(() => 1)', '`${x => x}`', "'' + String", 'Number + 1', '(() => 1) == 1',
  'a' + BS + 'u0062',
  '00', '2 ** 0 || 1', 'String(2 ** 0)', "'' + (() => 1 === 1)", '((a) => a === a)([])',
  '[[1, 2], [3, 4]].map(([a]) => a)',
  'Number(() => 1)', 'Number(Number)', '((a, ...b) => b)(1, 2)',
]

const allCorpusExpressions = [...corpusExpressions.keys()].sort()

const evalRows = []
for (const desc of environments) {
  desc.platform ??= process.platform
  desc.execPath ??= process.execPath
  const corpusResults = runEnvironment(desc, allCorpusExpressions)
  allCorpusExpressions.forEach((source, i) => {
    evalRows.push('(' + rktString(source) + ' ' + desc.name + ' corpus ' + corpusResults[i] + ')')
  })
}
const snapshotEnv = environments.find((desc) => desc.name === 'snapshot')
const semanticUnique = [...new Set(semanticSources)].filter(wellFormed)
const semanticResults = runEnvironment(snapshotEnv, semanticUnique)
semanticUnique.forEach((source, i) => {
  evalRows.push('(' + rktString(source) + ' snapshot semantic ' + semanticResults[i] + ')')
})

// Every row of this section must be a SyntaxError in Node.
const syntaxUnique = [...new Set(syntaxErrorSources)].filter(wellFormed)
const syntaxResults = runEnvironment(snapshotEnv, syntaxUnique)
const misplaced = []
const syntaxRows = syntaxUnique.map((source, i) => {
  if (!syntaxResults[i].startsWith('(error "SyntaxError"')) {
    misplaced.push(
      'expected a SyntaxError from ' + JSON.stringify(source) + ', got ' + syntaxResults[i])
  }
  return rktString(source)
})

// Every row of this section must be JavaScript: Node must not report a SyntaxError.
const unsupportedUnique = [...new Set(unsupportedSources)].filter(wellFormed)
const unsupportedResults = runEnvironment(snapshotEnv, unsupportedUnique)
const unsupportedRows = unsupportedUnique.map((source, i) => {
  if (unsupportedResults[i].startsWith('(error "SyntaxError"')) {
    misplaced.push('not JavaScript: ' + JSON.stringify(source) + ': ' + unsupportedResults[i])
  }
  return rktString(source)
})
if (misplaced.length > 0) throw new Error(misplaced.join('\n'))

function environmentRow(desc) {
  const fields = [
    '(mode ' + desc.mode + ')',
    '(env ' + rkt(desc.env) + ')',
    '(cwd ' + rktString(desc.cwd) + ')',
    '(platform ' + rktString(desc.platform) + ')',
    '(exec-path ' + rktString(desc.execPath) + ')',
    '(base-url ' + rktString(desc.baseUrl) + ')',
    '(dsh-home ' + rktString(desc.dshHome) + ')',
    '(profile ' + rkt(desc.profile) + ')',
    '(resolve-root ' + (desc.resolveRoot === null ? '#f' : rktString(desc.resolveRoot)) + ')',
    '(services ' + rkt(desc.services) + ')',
  ]
  return '(' + desc.name + '\n   ' + fields.join('\n   ') + ')'
}

// ---------------------------------------------------------------------------------------------
// Output

const section = (name, rows) => ' (' + name + '\n  ' + rows.join('\n  ') + ')'
const output = [
  ';; Generated by tests/gen/gen-js-yaml-table.mjs; do not edit.',
  ';; js-yaml ' + yamlVersion + ', node ' + process.version + ', ' + process.platform +
    ', seed ' + seed,
  ';; Sections: (corpus (path content-sha256 json-sha256 dump-sha256) ...)',
  ';; (corpus-expressions (source count) ...) (load (text result) ...)',
  ';; (load-named (text result) ...)',
  ';; (load-styled (text result) ...) (load-all (text result) ...) (load-json (text result) ...)',
  ';; (dump (value line-width text) ...) (dump-unstable (value line-width text) ...)',
  ';; (environments (name field ...) ...)',
  ';; (eval (source environment kind result) ...) (syntax-error source ...)',
  ';; (unsupported source ...)',
  ';; A load result is (ok value) or (error reason line column position message);',
  ';; an eval result is (ok value) or (error name message).',
  '(',
  section('meta', [
    '(js-yaml ' + rktString(yamlVersion) + ')', '(node ' + rktString(process.version) + ')',
    '(platform ' + rktString(process.platform) + ')', '(seed ' + seed + ')']),
  section('corpus', corpusRows),
  section('corpus-expressions', allCorpusExpressions.map((source) =>
    '(' + rktString(source) + ' ' + corpusExpressions.get(source) + ')')),
  section('load', loadRows),
  section('load-named', namedLoadRows),
  section('load-styled', styledRows),
  section('load-all', loadAllRows),
  section('load-json', loadJsonRows),
  section('dump', dumpRows),
  section('dump-unstable', unstableDumpRows),
  section('environments', environments.map(environmentRow)),
  section('eval', evalRows),
  section('syntax-error', syntaxRows),
  section('unsupported', unsupportedRows),
  ')',
  '',
].join('\n')

writeFileSync(outPath, output)
console.log(
  `${outPath}: ${corpusRows.length} corpus files, ` +
  `${allCorpusExpressions.length} corpus expressions, ` +
  `${loadRows.length + namedLoadRows.length + styledRows.length + loadAllRows.length +
    loadJsonRows.length} load rows, ` +
  `${dumpRows.length} dump rows (${unstableDumpRows.length} more unstable), ` +
  `${evalRows.length} eval rows, ${syntaxRows.length} syntax rows, ` +
  `${unsupportedRows.length} unsupported rows`)
