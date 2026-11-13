#!/usr/bin/env node
// Generates the differential table that tests/node-table-test.rkt checks cordis-schema against.
// Every expected result is computed by the vendored Schemastery (vendor/schemastery/src/index.ts)
// and, for the raw-config comparison, the vendored loader (vendor/loader/src/config/diff.ts),
// which Node loads as TypeScript. `@deepseek-ai/cosmokit` resolves to vendor/cosmokit through a
// resolve hook, so nothing is installed.
//
//   node --experimental-transform-types tests/gen/gen-node-table.mjs
//       rewrites tests/data/node-table.rktd
//   node --experimental-transform-types tests/gen/gen-node-table.mjs \
//       --seed 7 --random 2000 --out /tmp/fuzz.rktd
//
// --random sets the number of random schemas (default 120); the same seed and count give the
// same file. Uses Node built-ins only.
//
// The output is one Racket datum. A schema is written as a specification that
// tests/support/node-table.rkt builds with the public constructors and modifiers. A JavaScript
// value is encoded so that Racket's reader rebuilds it: an object is a list of (key . value)
// pairs in enumeration order, an array is a vector, null and undefined are the symbols `null`
// and `undefined`, a double that is not a safe integer is a flonum literal, and a volatile
// reference is the prefab #s(volatile SNAPSHOT).

import { writeFileSync } from 'node:fs';
import { register } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

// ---------------------------------------------------------------------------------------------
// Arguments and the vendored sources

const usage = 'usage: gen-node-table.mjs [--seed N] [--random N] [--out FILE]';

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i += 2) {
    if (!argv[i].startsWith('--') || argv[i + 1] === undefined) throw new Error(usage);
    args[argv[i].slice(2)] = argv[i + 1];
  }
  return args;
}

const args = parseArgs(process.argv.slice(2));
const seed = Number(args.seed ?? 20261113);
const randomCount = Number(args.random ?? 120);
const here = dirname(fileURLToPath(import.meta.url));
const outPath = args.out ?? join(here, '..', 'data', 'node-table.rktd');
const vendor = join(here, '..', '..', '..', '..', 'vendor');
const vendorUrl = (...parts) => pathToFileURL(join(vendor, ...parts)).href;

const hook = `
const cosmokit = ${JSON.stringify(vendorUrl('cosmokit', 'src', 'index.ts'))};
export async function resolve(specifier, context, next) {
  if (specifier === '@deepseek-ai/cosmokit') return { url: cosmokit, shortCircuit: true };
  return next(specifier, context);
}
`;
register('data:text/javascript,' + encodeURIComponent(hook));

let z, equalExceptVolatile;
try {
  ({ default: z } = await import(vendorUrl('schemastery', 'src', 'index.ts')));
  ({ equalExceptVolatile } = await import(vendorUrl('loader', 'src', 'config', 'diff.ts')));
} catch (cause) {
  throw new Error('cannot load the vendored sources; run node with --experimental-transform-types', {
    cause,
  });
}

// ---------------------------------------------------------------------------------------------
// Random numbers

function mulberry32(state) {
  return () => {
    state = (state + 0x6d2b79f5) | 0;
    let t = Math.imul(state ^ (state >>> 15), 1 | state);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const rand = mulberry32(seed);
const int = (n) => Math.floor(rand() * n);
const pick = (xs) => xs[int(xs.length)];
const chance = (p) => rand() < p;

// ---------------------------------------------------------------------------------------------
// Callbacks and ignore predicates, by name. tests/support/node-table.rkt has the Racket twin of
// each; the table carries the source text so that the JSON form can be compared.

const callbacks = {
  trim: (v) => v.trim(),
  upper: (v) => v.toUpperCase(),
  length: (v) => v.length,
  double: (v) => v * 2,
  wrap: (v) => ({ value: v }),
  keys: (v) => Object.keys(v),
  same: () => 'same',
  undef: () => undefined,
  prefix: (v) => 'x-' + v,
  boom: () => { throw new Error('boom') },
};

const ignores = {
  strings: (data, schema) => schema.type === 'string',
  nulls: (data) => data === null,
  objects: (data, schema) => schema.type === 'object' && Array.isArray(data),
};

// ---------------------------------------------------------------------------------------------
// Schema specifications
//
// A specification is an array: [constructor, ...arguments]. ['with', spec, [[modifier, ...]]]
// applies modifiers in order. ['from', value] and ['prim', 'String'] stand for the shorthand a
// parent constructor accepts. U stands for undefined inside values.

const U = Symbol('undefined');

function materialize(v) {
  if (v === U) return undefined;
  if (Array.isArray(v)) return v.map(materialize);
  if (v && typeof v === 'object') {
    // Object.fromEntries defines "__proto__" as an own property, as JSON.parse does.
    return Object.fromEntries(
      Object.entries(v).filter(([, item]) => item !== U).map(([k, item]) => [k, materialize(item)]),
    );
  }
  return v;
}

const prims = { String, Number, Boolean, Function };

function applyModifier(schema, [name, ...rest]) {
  const values = rest.map(materialize);
  switch (name) {
    case 'pattern': return schema.pattern(new RegExp(values[0], values[1] ?? ''));
    case 'role': return values.length > 1 ? schema.role(values[0], values[1]) : schema.role(values[0]);
    default: return schema[name](...values);
  }
}

function build(spec) {
  const [type, ...rest] = spec;
  switch (type) {
    case 'from': return materialize(rest[0]);
    case 'prim': return prims[rest[0]];
    case 'with': return rest[1].reduce(applyModifier, build(rest[0]));
    case 'const': return z.const(materialize(rest[0]));
    case 'bitset': return z.bitset(materialize(rest[0]));
    case 'is': return z.is(rest[0]);
    case 'array': return z.array(build(rest[0]));
    case 'dict': return rest.length > 1 ? z.dict(build(rest[0]), build(rest[1])) : z.dict(build(rest[0]));
    case 'tuple': return z.tuple(rest[0].map(build));
    case 'union': return z.union(rest[0].map(build));
    case 'intersect': return z.intersect(rest[0].map(build));
    case 'object':
      return z.object(Object.fromEntries(Object.entries(rest[0]).map(([k, v]) => [k, build(v)])));
    case 'transform':
      return rest.length > 2
        ? z.transform(build(rest[0]), callbacks[rest[1]], rest[2])
        : z.transform(build(rest[0]), callbacks[rest[1]]);
    case 'lazy': return z.lazy(() => build(rest[0]));
    case 'custom': return new z({ type: rest[0] });
    default: return z[type]();
  }
}

// ---------------------------------------------------------------------------------------------
// Racket literals

const BACKSLASH = String.fromCharCode(0x5c);
const QUOTE = String.fromCharCode(0x22);

// A Racket string literal in ASCII.
function rktString(s) {
  if (!s.isWellFormed()) throw new Error('a Racket string cannot hold a lone surrogate');
  let out = QUOTE;
  for (let i = 0; i < s.length; i++) {
    const unit = s.charCodeAt(i);
    if (unit >= 0x20 && unit < 0x7f && unit !== 0x22 && unit !== 0x5c) out += s[i];
    else out += BACKSLASH + 'u' + unit.toString(16).padStart(4, '0');
  }
  return out + QUOTE;
}

function rktNumber(n) {
  if (Number.isNaN(n)) return '+nan.0';
  if (n === Infinity) return '+inf.0';
  if (n === -Infinity) return '-inf.0';
  if (Number.isSafeInteger(n)) return String(n === 0 ? 0 : n);
  const text = String(n);
  return /[.e]/.test(text) ? text : text + '.0';
}

const volatileWrite = Symbol.for('cosmokit.volatile.write');

// A JavaScript value as a Racket datum.
function enc(v) {
  if (v === undefined || v === U) return 'undefined';
  if (v === null) return 'null';
  if (v === true) return '#t';
  if (v === false) return '#f';
  if (typeof v === 'number') return rktNumber(v);
  if (typeof v === 'string') return rktString(v);
  if (typeof v === 'function') return '#s(function)';
  if (Array.isArray(v)) {
    const items = [];
    for (let i = 0; i < v.length; i++) items.push(i in v ? enc(v[i]) : 'undefined');
    return `#(${items.join(' ')})`;
  }
  if (volatileWrite in v) return `#s(volatile ${enc(v.get())})`;
  const prototype = Object.getPrototypeOf(v);
  if (prototype !== Object.prototype && prototype !== null) {
    return `#s(opaque ${rktString(v.constructor?.name ?? '')})`;
  }
  const members = Object.entries(v)
    .filter(([, item]) => item !== undefined && item !== U)
    .map(([k, item]) => `(${rktString(k)} . ${enc(item)})`);
  return `(${members.join(' ')})`;
}

function encSpec(spec) {
  const [type, ...rest] = spec;
  const list = (specs) => `(${specs.map(encSpec).join(' ')})`;
  switch (type) {
    case 'from': return `(from ${enc(rest[0])})`;
    case 'prim': return `(prim ${rktString(rest[0])})`;
    case 'with':
      return `(with ${encSpec(rest[0])} (${rest[1]
        .map(([name, ...values]) => `(${name}${values.map((v) => ' ' + enc(v)).join('')})`)
        .join(' ')}))`;
    case 'const': return `(const ${enc(rest[0])})`;
    case 'bitset': return `(bitset ${enc(rest[0])})`;
    case 'is': return `(is ${rktString(rest[0])})`;
    case 'array': return `(array ${encSpec(rest[0])})`;
    case 'dict': return `(dict ${rest.map(encSpec).join(' ')})`;
    case 'tuple': case 'union': case 'intersect': return `(${type} ${list(rest[0])})`;
    case 'object':
      return `(object (${Object.entries(rest[0])
        .map(([k, v]) => `(${rktString(k)} . ${encSpec(v)})`)
        .join(' ')}))`;
    case 'transform':
      return `(transform ${encSpec(rest[0])} ${rktString(rest[1])}${rest.length > 2 ? ' ' + enc(rest[2]) : ''})`;
    case 'lazy': return `(lazy ${encSpec(rest[0])})`;
    case 'custom': return `(custom ${rktString(rest[0])})`;
    default: return `(${type})`;
  }
}

// ---------------------------------------------------------------------------------------------
// The JSON form with uids renumbered as cordis-schema numbers them: depth-first post-order over
// inner, sKey, list, dict.

function canonicalJson(schema) {
  const json = JSON.parse(JSON.stringify(schema));
  const numbers = new Map();
  const order = [];
  const visit = (uid) => {
    if (numbers.has(uid)) return;
    numbers.set(uid, -1);
    const node = json.refs[uid];
    for (const child of [node.inner, node.sKey, ...(node.list ?? []), ...Object.values(node.dict ?? {})]) {
      if (child !== undefined && child !== null) visit(child);
    }
    numbers.set(uid, order.length);
    order.push(uid);
  };
  visit(json.uid);
  const renumber = (uid) => numbers.get(uid);
  const refs = {};
  for (const uid of order) {
    const node = { ...json.refs[uid] };
    if ('inner' in node) node.inner = renumber(node.inner);
    if ('sKey' in node) node.sKey = renumber(node.sKey);
    if ('list' in node) node.list = node.list.map(renumber);
    if ('dict' in node) {
      node.dict = Object.fromEntries(Object.entries(node.dict).map(([k, v]) => [k, renumber(v)]));
    }
    refs[renumber(uid)] = node;
  }
  return JSON.stringify({ uid: renumber(json.uid), refs });
}

// ---------------------------------------------------------------------------------------------
// Running one case

function attempt(thunk) {
  try {
    return thunk();
  } catch (error) {
    if (z.ValidationError.is(error)) {
      return `(error ${rktString(error.message)} ${enc(error.options.path ?? [])})`;
    }
    return `(throw ${rktString(error?.name ?? 'Error')} ${rktString(String(error?.message ?? error))})`;
  }
}

// A copy of a resolved value whose objects have no member that is undefined. A jobject cannot
// hold such a member, so this is the value cordis-schema hands to `schema-simplify`.
function withoutUndefinedMembers(v) {
  if (Array.isArray(v)) return v.map(withoutUndefinedMembers);
  if (!v || typeof v !== 'object' || volatileWrite in v) return v;
  const prototype = Object.getPrototypeOf(v);
  if (prototype !== Object.prototype && prototype !== null) return v;
  return Object.fromEntries(
    Object.entries(v).filter(([, item]) => item !== undefined).map(([k, item]) => [k, withoutUndefinedMembers(item)]),
  );
}

function runCase(spec, input, options = {}) {
  const { strict = false, ignore, ...rest } = options;
  const resolveOptions = { ...rest };
  if (ignore) resolveOptions.ignore = ignores[ignore];
  const optionDatum = [
    rest.autofix ? '(autofix . #t)' : null,
    strict ? '(strict . #t)' : null,
    ignore ? `(ignore . ${rktString(ignore)})` : null,
    rest.path ? `(path . ${enc(rest.path)})` : null,
  ].filter(Boolean).join(' ');
  const result = attempt(() => {
    const schema = build(spec);
    const data = materialize(input);
    const [value, adapted] = z.resolve(data, schema, resolveOptions, strict);
    const valueDatum = enc(value);
    const adaptedDatum = enc(adapted !== undefined ? adapted : data);
    const simplified = attempt(() => `(ok ${enc(schema.simplify(withoutUndefinedMembers(value)))})`);
    return `(ok ${valueDatum} ${adaptedDatum} ${simplified})`;
  });
  return `((input ${enc(input)}) (options ${optionDatum}) (result ${result}))`;
}

const o = (input, options) => ({ $case: true, input, options });

function row(name, spec, cases) {
  const head = attempt(() => {
    const schema = build(spec);
    // String(): the formatter of a const returns its value, which a template literal coerces.
    const text = (inline) => rktString(String(schema.toString(inline)));
    return `(ok ${text(false)} ${text(true)} ${rktString(canonicalJson(schema))})`;
  });
  const lines = cases.map((item) => {
    const { input, options } = item && item.$case ? item : { input: item, options: undefined };
    return '    ' + runCase(spec, input, options);
  });
  return `  ((name ${rktString(name)})\n   (spec ${encSpec(spec)})\n   (describe ${head})\n   (cases\n${lines.join('\n')}))`;
}

// ---------------------------------------------------------------------------------------------
// Hand-written rows: every type, modifier, option and message

const w = (spec, ...mods) => ['with', spec, mods];
const str = ['string'];
const num = ['number'];
const bool = ['boolean'];
const obj = (fields) => ['object', fields];
const arr = (inner) => ['array', inner];
const from = (value) => ['from', value];
const String_ = ['prim', 'String'];
const Number_ = ['prim', 'Number'];
const bits = { read: 1, write: 2, exec: 4, admin: 8 };

const scalars = [U, null, true, false, 0, 1, -1, 1.5, 'x', '', [], {}];

const fixed = [
  ['any', ['any'], [...scalars, { a: [1, { b: null }] }]],
  ['any required', w(['any'], ['required']), [U, null, 0, 'x']],
  ['any default', w(['any'], ['default', { a: 1 }]), [U, null, 5]],
  ['never', ['never'], [U, null, 0, false, 'x', [], {}]],
  ['never described', w(['never'], ['description', 'Removed.']), [U, 1]],
  ['const string', ['const', 'on'], [U, 'on', 'off', 1, ['on'], { a: 1 }]],
  ['const number', ['const', 1], [1, '1', 2, true, null]],
  ['const false', ['const', false], [false, true, 0, U]],
  ['const null', ['const', null], [U, null, 0]],
  ['const object', ['const', { a: [1, 2], b: null }], [{ a: [1, 2] }, { a: [1, 2], b: null }, { a: [1] }, { b: null, a: [1, 2] }]],
  ['const array', ['const', [1, 'a']], [[1, 'a'], [1], 'x']],
  ['const default', w(['const', 'on'], ['default', 'on']), [U, null, 'off']],
  ['string', str, [...scalars, 'hello', [1, [2, null], 'x'], { a: 1 }, 1e21, 1e-7, -0]],
  ['string required', w(str, ['required']), [U, null, '', 'a']],
  ['string default', w(str, ['default', 'fallback']), [U, null, '', 'a', 5]],
  ['string length', w(str, ['min', 2], ['max', 4]), ['', 'a', 'ab', 'abcd', 'abcde', '\u{1f600}', '\u{1f600}\u{1f600}\u{1f600}']],
  ['string max null', w(str, ['max', null]), ['', 'a']],
  ['string pattern', w(str, ['pattern', '^[A-Za-z0-9_-]{1,32}$']), ['ok_name-1', '', 'bad name', 'x'.repeat(33)]],
  ['string pattern flags', w(str, ['pattern', '^a.c$', 'is']), ['abc', 'A\nC', 'abd']],
  ['string pattern slash', w(str, ['pattern', 'a/b[/]', 'g']), ['xa/b/', 'a-b']],
  ['string pattern kebab', w(str, ['pattern', '^[a-z0-9]+(?:-[a-z0-9]+)*$']), ['a', 'a-b-c9', 'a--b', '-a', 'A']],
  ['string pattern classes', w(str, ['pattern', '^\\d{2,}\\s\\w+\\.\\S*$']), ['12 ab.', '123\tx_y.z!', '1 a.', '12 a']],
  ['string pattern alternation', w(str, ['pattern', '^(?:legacy|timed)$|^x(?=y)', 'm']), ['legacy', 'timed', 'xy', 'xz', 'a\nlegacy']],
  ['string pattern empty', w(str, ['pattern', '']), ['', 'a']],
  ['string pattern unicode', w(str, ['pattern', '^[\\u4e00-\\u9fff]+\\u{1F600}?$', 'u']), ['中文', '中\u{1f600}', 'abc']],
  ['string pattern backreference', w(str, ['pattern', '^(?<q>[\'"])(.*)\\k<q>\\1?$']), ['"a"', "'a'", '"a\'', 'a']],
  ['string role', w(str, ['role', 'secret']), ['s']],
  ['string role extra', w(str, ['role', 'credential-ref', { kind: 'env' }]), ['s']],
  ['number', num, [...scalars, 1e21, 1e-7, -0, 0.1, 123456789012345680000, '5']],
  ['number range', w(num, ['min', 0], ['max', 10]), [-1, 0, 10, 10.5, -0.5, 5]],
  ['number min null', w(num, ['min', null]), [-1, 0, 1]],
  ['number step 1', w(num, ['step', 1], ['min', 1]), [1, 2, 1.5, 0, 3]],
  ['number step 3 min 1', w(num, ['step', 3], ['min', 1]), [1, 4, 7, 8, 2.5]],
  ['number step 0.1', w(num, ['step', 0.1]), [0.3, 0.7, 1.1, 0.35, 5, 0.30000000000000004, 1e-7]],
  ['number step 0.01', w(num, ['step', 0.01]), [1.005, 0.29, 0.57, 1.15, 100.01]],
  ['number step 0.1 min 0.05', w(num, ['step', 0.1], ['min', 0.05]), [0.35, 0.3, 0.05, 0.15]],
  ['number step negative', w(num, ['step', -2]), [4, 3, -6]],
  ['number step 0', w(num, ['step', 0]), [4, 3.3]],
  ['number step 1e-7', w(num, ['step', 1e-7]), [3e-7, 2.5e-7, 1]],
  ['number step 2.5', w(num, ['step', 2.5], ['min', -5]), [0, 2.5, 3, -2.5, 1e21]],
  ['number default', w(num, ['default', 3]), [U, null, 0, 'x']],
  ['natural', ['natural'], [0, 1, 2.5, -1, 1e21, 'x', U]],
  ['natural bounded', w(['natural'], ['min', 1], ['max', 9007199254740991], ['default', 50000]), [U, 0, 1, 9007199254740991, 9007199254740992, 1.5]],
  ['percent', ['percent'], [0, 0.5, 1, 1.01, -0.01, 0.123, 0.07, 0.57]],
  ['boolean', bool, scalars],
  ['boolean default', w(bool, ['default', true]), [U, null, false]],
  ['boolean required', w(bool, ['required']), [U, false]],
  ['function', ['function'], [U, 1, 'x', {}]],
  ['is Array', ['is', 'Array'], [[], [1], {}, 'x', 1, U]],
  ['is Object', ['is', 'Object'], [{}, [], 'x', 1, true, U, null]],
  ['is String', ['is', 'String'], ['x', 1, {}]],
  ['is Number', ['is', 'Number'], [1, 'x']],
  ['is Boolean', ['is', 'Boolean'], [false, 0]],
  ['is Foo', ['is', 'Foo'], [{}, 'x', U]],
  ['bitset', ['bitset', bits], [U, null, 0, 3, 5, 15, 16, -1, 4294967297, 1.5, [], ['read'], ['read', 'exec'], ['exec', 'read', 'read'], ['nope'], ['toString'], ['read', 1], 'read', {}, true]],
  ['bitset default number', w(['bitset', bits], ['default', 3]), [U, 3, ['read', 'write'], ['read']]],
  ['bitset default keys', w(['bitset', bits], ['default', ['read']]), [U, null, 1, ['read']]],
  ['bitset mixed bits', ['bitset', { a: 1, b: 'x', c: 2147483648, d: 3 }], [3, ['a', 'c'], ['b'], 2147483648, ['d']]],
  ['array', arr(str), [U, null, [], ['a'], ['a', 1], ['a', null], ['a', U, 'b'], 'a', {}, 5]],
  ['array of String', arr(String_), [[], ['a'], [null], ['a', U]]],
  ['array of default', arr(w(num, ['default', 7])), [[1, null, 3], [U]]],
  ['array bounds', w(arr(num), ['min', 2], ['max', 3]), [[], [1], [1, 2], [1, 2, 3], [1, 2, 3, 4]]],
  ['array min with inner default', w(arr(w(num, ['default', 1])), ['min', 2], ['max', 3]), [[], [1], [1, 2, 3, 4]]],
  ['array default', w(arr(str), ['default', ['.']], ['role', 'table']), [U, null, [], ['a']]],
  ['array required', w(arr(str), ['required']), [U, []]],
  ['array undefined default', w(arr(str), ['default', U]), [U, null, ['a']]],
  ['array autofix', arr(num), [o([1, 'x', 3], { autofix: true }), o(['x'], { autofix: true }), o('x', { autofix: true })]],
  ['array of arrays', arr(arr(num)), [[[1], [2, 3]], [[1], 2], [[1, 'x']], o([[1, 'x'], 'y'], { autofix: true })]],
  ['dict', ['dict', num], [U, null, {}, { a: 1 }, { a: 1, b: 'x' }, { a: null }, [], 'x', 5]],
  ['dict of String', ['dict', String_], [{ a: 'x' }, { a: null }, { a: 1 }]],
  ['dict default', w(['dict', String_], ['default', { k: 'v' }]), [U, null, {}, { a: 'b' }]],
  ['dict key pattern', ['dict', num, w(str, ['pattern', '^[a-z]+$'])], [{ ab: 1 }, { ab: 1, AB: 2 }, o({ ab: 1, AB: 2 }, { strict: true })]],
  ['dict key transform', ['dict', num, ['transform', str, 'upper']], [{ a: 1, b: 2 }, { a: 1, A: 2 }, { A: 1, a: 2 }, {}]],
  ['dict key prefix', ['dict', str, ['transform', str, 'prefix']], [{ a: 'p', b: 'q' }, { a: 1 }, o({ a: 1, b: 'q' }, { autofix: true })]],
  ['dict key const', ['dict', bool, ['union', [from('on'), from('off')]]], [{ on: true }, { on: true, other: false }, o({ on: true, other: false }, { strict: true })]],
  ['dict autofix', ['dict', num], [o({ a: 1, b: 'x', c: 3 }, { autofix: true })]],
  ['dict of objects', ['dict', obj({ sandbox: w(['union', [from('read-only'), from('workspace-write')]], ['required']), name: str })], [{ p: { sandbox: 'read-only' } }, { p: {} }, { p: { sandbox: 'x' } }, { p: { sandbox: 'read-only', extra: 1 }, q: { sandbox: 'workspace-write', name: 'n' } }]],
  ['tuple', ['tuple', [num, str]], [U, [], [1], [1, 'a'], [1, 'a', true, null], ['a'], [1, 2], 'x', {}, o([1, 'a', true], { strict: true }), o(['a', 1], { autofix: true })]],
  ['tuple defaults', ['tuple', [w(num, ['default', 1]), w(str, ['required'])]], [[], [U, 'a'], [2, 'a'], [null, 'b', 'c']]],
  ['tuple shorthand', ['tuple', [String_, arr(Number_)]], [['a', [1]], ['a'], ['a', ['x']]]],
  ['tuple empty', ['tuple', []], [[], [1, 2], o([1, 2], { strict: true })]],
  ['object', obj({ a: num, b: str }), [U, null, {}, { a: 1 }, { b: 'x', a: 1 }, { a: 'x' }, { a: 1, c: true }, { c: 1, a: 2 }, { a: null, b: null }, [], 'x', 5, true, o({ a: 1, c: true }, { strict: true })]],
  ['object empty', obj({}), [U, {}, { a: 1 }, [], o({ a: 1 }, { strict: true })]],
  ['object defaults', obj({ a: w(num, ['default', 1]), b: w(str, ['default', 'x']), c: bool }), [U, {}, { a: 2 }, { c: null }, { a: null, b: null }, { z: 1, b: 'y' }]],
  ['object required', obj({ a: w(str, ['required']), b: w(num, ['required'], ['default', 1]) }), [U, {}, { a: 'x' }, { a: 'x', b: null }, { b: 2 }]],
  ['object default object', w(obj({ a: w(num, ['default', 1]), b: str }), ['default', { b: 'd' }]), [U, null, {}, { b: 'e' }]],
  ['object undefined default', w(obj({ a: num }), ['default', U]), [U, null, {}]],
  ['object nested', obj({ nested: obj({ count: w(num, ['min', 0], ['default', 1]) }), list: arr(obj({ id: w(str, ['required']) })) }), [U, {}, { nested: {} }, { nested: { count: -1 } }, { list: [{ id: 'a' }, {}] }, { list: [{ id: 'a' }, { id: 1 }] }, o({ nested: { count: -1 }, list: [{ id: 'a' }, {}] }, { autofix: true })]],
  ['object path option', obj({ a: w(str, ['required']), b: arr(num) }), [o({}, { path: ['root', 3, 'x'] }), o({ a: 'x', b: [1, 'y'] }, { path: ['cfg'] }), o('x', { path: ['cfg', 0] })]],
  ['object inherited keys', obj({ a: str }), [{ toString: 'x', constructor: 1, valueOf: 2, hasOwnProperty: 3, __proto__: 'y', b: 2 }, { isPrototypeOf: 1, propertyIsEnumerable: 2, toLocaleString: 3, __defineGetter__: 4, a: 'z' }]],
  ['object autofix', obj({ a: num, b: w(str, ['default', 'd']), c: w(bool, ['required']) }), [o({ a: 'x', b: 1 }, { autofix: true }), o({ a: 1, b: 'x', c: true }, { autofix: true }), o([], { autofix: true })]],
  ['object ignore strings', obj({ a: str, b: num }), [o({ a: 1, b: 2 }, { ignore: 'strings' }), o({ a: 1, b: 'x' }, { ignore: 'strings' })]],
  ['object ignore nulls', obj({ a: w(str, ['required']), b: w(num, ['default', 1]) }), [o({ a: null, b: null }, { ignore: 'nulls' }), o(null, { ignore: 'nulls' })]],
  ['object shorthand consts', obj({ transport: from('stdio'), n: from(1), flag: from(true), free: from(null) }), [{ transport: 'stdio', n: 1, flag: true }, { transport: 'http', n: 1, flag: true }, {}, { transport: 'stdio', n: 1, flag: true, free: [1] }]],
  ['object shorthand prims', obj({ s: String_, n: Number_, b: ['prim', 'Boolean'] }), [{ s: 'a', n: 1, b: false }, { s: 'a', n: 1 }, { s: 1, n: 1, b: true }]],
  ['object hidden', obj({ a: w(str, ['hidden']), b: w(str, ['hidden', false], ['disabled'], ['collapse'], ['comment', 'c'], ['link', 'https://example.com/doc']) }), [{ a: 'x' }]],
  ['object badges', obj({ old: w(str, ['deprecated']), next: w(str, ['experimental'], ['deprecated']) }), [{ old: 'x' }]],
  ['object descriptions', w(obj({ a: w(str, ['description', 'Field a.']), b: w(num, ['description', { '': 'B', 'zh-CN': '乙' }]) }), ['description', 'Root.']), [{}]],
  ['object extra', obj({ a: w(str, ['extra', 'custom', { x: [1, null] }], ['extra', 'default', 'q'], ['extra', 'default', U]) }), [{}, { a: null }]],
  ['union consts', ['union', [from('legacy'), from('timed')]], [U, null, 'legacy', 'timed', 'other', 1, ['legacy'], { a: 1 }]],
  ['union consts default', w(['union', [from('quiet'), from('wakeup')]], ['default', 'wakeup']), [U, null, 'quiet', 'loud']],
  ['union number or const', w(['union', [from(-1), w(num, ['step', 1], ['min', 1], ['max', 2147483])]], ['default', 120]), [U, -1, 1, 0, 1.5, 2147483, 2147484, 'x']],
  ['union required', w(['union', [str, num]], ['required']), [U, 'a', 1, true]],
  ['union objects', ['union', [obj({ transport: from('stdio'), command: w(str, ['required']) }), obj({ transport: from('streamable-http'), url: w(str, ['required']) })]], [{ transport: 'stdio', command: 'x' }, { transport: 'streamable-http', url: 'u', extra: 1 }, { transport: 'stdio' }, { transport: 'ws' }, {}, 'x']],
  ['union empty', ['union', []], [U, 1, 'x']],
  ['union nested', ['union', [['union', [str, num]], arr(['union', [bool, from('x')]])]], ['a', 1, [true, 'x'], [1], {}]],
  ['union strict', ['union', [obj({ a: num }), str]], [o({ a: 1, b: 2 }, { strict: true }), { a: 1, b: 2 }]],
  ['union with never', ['union', [['never'], str]], [U, 'a', 1]],
  ['intersect empty', ['intersect', []], [U, null, 1, { a: 1 }]],
  ['intersect objects', ['intersect', [obj({ a: w(num, ['default', 1]) }), obj({ b: w(str, ['default', 'x']) })]], [U, null, {}, { a: 2 }, { c: true }, { b: 1 }, 'x', o({ c: true, a: 3 }, { strict: true })]],
  ['intersect default first', ['intersect', [w(obj({ a: w(num, ['default', 1]) }), ['default', { a: 5 }]), obj({ b: w(str, ['default', 'x']) })]], [U, null, {}]],
  ['intersect own default', w(['intersect', [obj({ a: num }), obj({ b: str })]], ['default', { a: 9 }]), [U, { b: 'q' }]],
  ['intersect undefined defaults', ['intersect', [w(obj({ a: num }), ['default', U]), obj({ b: str })]], [U, null, {}]],
  ['intersect nested default', ['intersect', [['intersect', [w(obj({ a: w(num, ['default', 2]) }), ['default', { a: 7 }])]], obj({ b: str })]], [U, {}]],
  ['intersect scalars', ['intersect', [str, w(str, ['pattern', '^a'])]], ['abc', 'xbc', 1]],
  ['intersect mismatch', ['intersect', [str, num]], ['a', 1, U]],
  ['intersect unequal', ['intersect', [['transform', str, 'upper', true], str]], ['A', 'a']],
  ['intersect any', ['intersect', [['any'], ['any']]], [{ a: 1 }, 5, 'x', [1]]],
  ['intersect loose never', ['intersect', [w(['never'], ['loose'])]], [{}, { a: 1 }, 5]],
  ['intersect arrays', ['intersect', [['tuple', [num]], ['tuple', [num, str]]]], [[1, 'a'], [1], [1, 'a', true]]],
  ['intersect object and array', ['intersect', [['any'], arr(['any'])]], [[1], { a: 1 }]],
  ['intersect with bitset', ['intersect', [obj({ f: ['bitset', bits] }), obj({ g: num })]], [{ f: 3, g: 1 }, { f: ['read'], g: 1, h: 2 }, { f: 3, g: 'x' }]],
  ['transform', ['transform', str, 'trim'], [U, null, ' a ', 'b', 1]],
  ['transform preserve', ['transform', str, 'trim', true], [' a ', 1]],
  ['transform preserve false', ['transform', str, 'upper', false], ['a']],
  ['transform default', w(['transform', str, 'upper'], ['default', 'q']), [U, null, 'z']],
  ['transform in object', obj({ endpoint: w(['transform', str, 'trim'], ['default', ' https://example.com ']), size: ['transform', arr(num), 'length'] }), [U, {}, { endpoint: ' u ', size: [1, 2] }, { size: 'x' }]],
  ['transform object strict', ['transform', obj({ a: num }), 'keys'], [{ a: 1, b: 2 }, {}, U]],
  ['transform wrap', ['transform', num, 'wrap'], [1, 'x']],
  ['transform undefined', obj({ a: ['transform', str, 'undef'], b: ['transform', str, 'undef', true] }), [{ a: 'x', b: 'y' }, {}]],
  ['transform throws', obj({ a: ['transform', str, 'boom'] }), [{ a: 'x' }, {}, o({ a: 'x' }, { autofix: true })]],
  ['transform throws loose', w(['transform', str, 'boom'], ['loose'], ['default', 'safe']), ['x', U]],
  ['transform of union', arr(['transform', ['union', [from(1), from(2)]], 'double']), [[1, 2], [3]]],
  ['lazy', ['lazy', str], [U, null, 'a', 1]],
  ['lazy required', ['lazy', w(str, ['required'])], [U, 'a']],
  ['lazy default', ['lazy', w(num, ['default', 4])], [U, null, 1]],
  ['lazy in object', obj({ a: ['lazy', obj({ b: w(num, ['default', 1]) })] }), [U, {}, { a: {} }, { a: { b: 'x' } }]],
  ['lazy in array', arr(['lazy', w(num, ['default', 2])]), [[1, null], [U], ['x']]],
  ['custom type', ['custom', 'mystery'], [U, null, 1]],
  ['custom type default', w(['custom', 'mystery'], ['default', 1]), [U, 2]],
  ['custom type loose', w(['custom', 'mystery'], ['loose']), [U, 2]],
  ['loose', w(str, ['loose'], ['default', 'd']), [5, 'a', U, null]],
  ['loose no default', w(num, ['loose']), ['x', 1]],
  ['loose required', w(num, ['loose'], ['required']), [U, 'x']],
  ['loose false', w(num, ['loose', false], ['default', 1]), ['x']],
  ['loose in object', obj({ a: w(arr(num), ['loose']), b: w(obj({ c: w(num, ['required']) }), ['loose'], ['default', { c: 0 }]) }), [{ a: 'x', b: {} }, { a: [1], b: { c: 2 } }, { a: ['x'], b: 'y' }]],
  ['required false', w(str, ['required'], ['required', false]), [U, 'a']],
  ['volatile string', w(str, ['default', 'hello'], ['volatile']), [U, null, 'a', 1]],
  ['volatile required', w(str, ['volatile'], ['required']), [U, 'present']],
  ['volatile array', w(arr(str), ['volatile']), [U, ['a'], [1]]],
  ['volatile union', w(['union', [str, num]], ['volatile']), [1, 'a', true]],
  ['volatile fixture', obj({
    fixed: w(str, ['default', 'fixed']),
    title: w(str, ['default', 'hello'], ['volatile']),
    optional: w(str, ['volatile']),
    nested: w(obj({ count: w(num, ['min', 0], ['volatile'], ['default', 1]) }), ['default', {}]),
    group: w(obj({ list: arr(str) }), ['default', { list: [] }], ['volatile']),
  }), [U, {}, { title: 'changed' }, { nested: { count: -1 } }, o({ nested: { count: -1 } }, { autofix: true }), { group: { list: ['a'] } }, { fixed: 'f', optional: 'o', nested: { count: 3 }, group: { list: ['x', 'y'], more: 1 } }, { group: { list: [1] } }, o({ group: { list: [1] }, title: 5 }, { autofix: true })]],
  ['volatile in array', obj({ items: arr(w(str, ['volatile'])) }), [{}, { items: ['a'] }, U]],
  ['volatile in dict', obj({ items: ['dict', w(str, ['volatile'])] }), [{}]],
  ['volatile in dict key', obj({ items: ['dict', str, w(str, ['volatile'])] }), [{}]],
  ['volatile in union', ['union', [obj({ title: w(str, ['volatile']) }), str]], [{}, 'x']],
  ['volatile in tuple', obj({ items: ['tuple', [w(str, ['volatile'])]] }), [{}]],
  ['volatile in intersect', ['intersect', [obj({ title: w(str, ['volatile']) })]], [{}]],
  ['volatile in transform', ['transform', obj({ title: w(str, ['volatile']) }), 'keys'], [{}]],
  ['volatile nested', obj({ block: w(obj({ title: w(str, ['volatile']) }), ['volatile']) }), [{}, o({}, { path: ['root', 1] })]],
  ['volatile in lazy', obj({ lazy: ['lazy', obj({ live: w(str, ['volatile']) })] }), [{ lazy: { live: 'value' } }, {}, U]],
  ['volatile lazy itself', obj({ lazy: ['lazy', w(str, ['volatile'])] }), [{ lazy: 'x' }, {}]],
  ['volatile ignore', obj({ a: w(str, ['volatile']) }), [o({ a: 5 }, { ignore: 'strings' })]],
  ['volatile loose', obj({ a: w(num, ['loose'], ['default', 3], ['volatile']) }), [{ a: 'x' }, {}]],
  // Real plugin configs (docs/racket/recon/17-plugin-authoring-surface.md).
  ['plugin tool-jobs', obj({
    waitTimeoutMs: w(num, ['min', 1], ['default', 30000]),
    maxWaitTimeoutMs: w(num, ['min', 1], ['default', 600000]),
    completionDelivery: w(['union', [from('quiet'), from('wakeup')]], ['default', 'wakeup']),
    maxConsecutiveWakes: w(num, ['min', 1]),
    inlineOutputBytes: w(['natural'], ['default', 2048]),
  }), [U, {}, { waitTimeoutMs: 0 }, { completionDelivery: 'loud' }, { maxConsecutiveWakes: 3, inlineOutputBytes: 1.5 }, { inlineOutputBytes: 0, extra: true }]],
  ['plugin tool-ask-user', obj({
    mode: w(['union', [from('legacy'), from('timed')]], ['default', 'legacy']),
    timeout: w(['union', [from(-1), w(num, ['step', 1], ['min', 1], ['max', 2147483])]], ['default', 120]),
  }), [U, { mode: 'timed', timeout: -1 }, { timeout: 0 }, { timeout: 30.5 }, { mode: 'x' }]],
  ['plugin agent-preset', obj({ id: w(str, ['required']), name: str, description: str, order: num, plugins: w(arr(['any']), ['required']) }), [{ id: 'a', plugins: [] }, { id: 'a' }, { plugins: [1, { x: 1 }] }, { id: 'a', plugins: [null, 'p'], order: 2 }]],
  ['plugin tools', obj({ mode: w(['never'], ['description', 'Removed. Mount a native or PTC tool executor instead.']), maxParallelSubCalls: w(['never'], ['description', 'Moved to the PTC tool executor configuration.']) }), [{}, { mode: 'ptc' }, { maxParallelSubCalls: 4 }, { mode: null }]],
  ['plugin system-prompt', obj({ includeHarnessIdentity: w(bool, ['default', true]), includeRuntimeContext: w(bool, ['default', true]), personaPrefix: w(str, ['default', '']), personaSuffix: w(str, ['default', '']), toolOrder: w(arr(str), ['default', U]) }), [U, {}, { toolOrder: ['a', '<unlisted-tools>'] }, { includeHarnessIdentity: 'yes' }]],
  ['plugin permission-presets', obj({
    presets: w(['dict', obj({ sandbox: w(['union', [from('read-only'), from('workspace-write'), from('danger-full-access')]], ['required']), approval: w(['union', [from('never'), from('on-request')]], ['required']), name: str, description: str })], ['default', { 'workspace-write': { sandbox: 'workspace-write', approval: 'on-request' } }]),
    defaultPreset: w(str, ['volatile']),
  }), [U, {}, { defaultPreset: 'x' }, { presets: { a: { sandbox: 'read-only', approval: 'never', name: 'A' } } }, { presets: { a: { sandbox: 'read-only' } } }, { presets: { a: { sandbox: 'nope', approval: 'never' } } }]],
  ['plugin mcp-client', ['union', [
    obj({ transport: from('stdio'), serverName: w(str, ['pattern', '^[A-Za-z0-9_-]{1,32}$'], ['required']), command: w(str, ['required']), args: w(arr(String_), ['default', []]), env: w(['dict', String_], ['default', {}]), cwd: str }),
    obj({ transport: from('streamable-http'), serverName: w(str, ['pattern', '^[A-Za-z0-9_-]{1,32}$'], ['required']), url: w(str, ['required']), headers: w(['dict', String_], ['default', {}]) }),
  ]], [{ transport: 'stdio', serverName: 'fs', command: 'npx' }, { transport: 'stdio', serverName: 'bad name', command: 'npx' }, { transport: 'streamable-http', serverName: 'web', url: 'https://example.com', headers: { a: 'b' } }, { transport: 'streamable-http', serverName: 'web' }, { transport: 'stdio', serverName: 'fs', command: 'npx', args: ['-y', 1] }, {}]],
  ['plugin tool-subagent', obj({
    provider: w(str, ['required']),
    toolName: w(str, ['default', 'subagent']),
    modelSelection: w(bool, ['default', false]),
    agentOptions: w(obj({ provider: str, model: str, reasoningEffort: str, maxTokens: num }), ['default', U]),
    agentPreset: w(str, ['min', 1]),
    maxDepth: ['union', [w(['natural'], ['max', 9007199254740991]), ['const', 'provider-managed']]],
  }), [{ provider: 'spawn' }, {}, { provider: 'spawn', agentPreset: '' }, { provider: 'spawn', maxDepth: 'provider-managed', agentOptions: { model: 'm' } }, { provider: 'spawn', maxDepth: -1 }, { provider: 'spawn', maxDepth: 3, agentOptions: {} }]],
  ['plugin webhook-github', obj({ source: w(str, ['required']), path: w(str, ['required']), secretEnv: w(str, ['role', 'credential-ref'], ['required']), maxBodyBytes: w(num, ['step', 1], ['min', 1], ['max', 9007199254740991], ['required']) }), [{ source: 's', path: '/p', secretEnv: 'E', maxBodyBytes: 1024 }, { source: 's', path: '/p', secretEnv: 'E', maxBodyBytes: 0 }, { source: 's', path: '/p', secretEnv: 'E' }]],
  ['plugin llm-deepseek-api-key', obj({ baseUrl: str, apiKeyEnv: w(str, ['role', 'credential-ref'], ['default', 'DEEPSEEK_API_KEY'], ['volatile']) }), [U, {}, { apiKeyEnv: 'OTHER' }, { apiKeyEnv: 1 }]],
  ['plugin agent-default-model', obj({ provider: w(str, ['required'], ['volatile']), model: w(str, ['required'], ['volatile']), reasoningEffort: w(str, ['volatile']) }), [{ provider: 'p', model: 'm' }, { provider: 'p' }, { provider: 'p', model: 'm', reasoningEffort: 'high' }]],
  ['plugin tool-office', obj({ activationSkills: w(arr(w(str, ['pattern', '^[a-z0-9]+(?:-[a-z0-9]+)*$'])), ['min', 1], ['default', ['docx', 'pptx']]), maxImages: w(['natural'], ['min', 1], ['max', 64], ['default', 8]) }), [U, { activationSkills: [] }, { activationSkills: ['Bad'] }, { activationSkills: ['ok-skill'], maxImages: 65 }]],
  ['plugin repeat-tool-reminder', obj({ thresholds: w(arr(num), ['default', [3, 5, 8]]), include: w(arr(str), ['default', []]), exclude: w(arr(str), ['default', []]), argumentsPreviewChars: w(num, ['default', 500]) }), [U, { thresholds: [1] }, { include: 'x' }]],
  ['plugin translator', obj({ provider: w(['union', [from('google'), from('bing')]], ['default', 'bing']), googleEndpoint: w(['transform', str, 'trim'], ['default', 'https://translate.example/api ']), timeoutMs: w(['natural'], ['min', 1], ['max', 600000], ['default', 30000]) }), [U, { googleEndpoint: '  https://x  ' }, { timeoutMs: 0 }, { provider: 'x' }]],
];

// ---------------------------------------------------------------------------------------------
// Random rows

const keyPool = ['a', 'b', 'c', 'name', 'size', 'mode', 'tags', 'opts'];
const wordPool = ['', 'a', 'ab', 'abc', 'on', 'off', 'x-1', 'Hello', ' pad '];
const numberPool = [0, 1, 2, 3, -1, 0.5, 0.1, 0.25, 10, 100, 1.5, 7];

// A specification no deeper than `depth`. `mutating` allows the constructs whose in-place
// rewriting of the input is visible to later union members (documented as a difference).
function genSpec(depth, mutating) {
  const leaf = depth <= 0 || chance(0.35);
  const kinds = leaf
    ? ['string', 'string', 'number', 'number', 'natural', 'percent', 'boolean', 'const', 'any', 'never', 'consts', 'bitset']
    : ['array', 'dict', 'tuple', 'object', 'object', 'object', 'union', 'intersect', 'transform', 'lazy'];
  const kind = pick(kinds);
  let spec;
  switch (kind) {
    case 'string': {
      spec = str;
      const mods = [];
      if (chance(0.2)) mods.push(['min', int(3)]);
      if (chance(0.2)) mods.push(['max', 2 + int(3)]);
      if (chance(0.15)) mods.push(['pattern', pick(['^[a-z]*$', 'o', '^\\w+-\\d$', '^.{2,}$'])]);
      if (mods.length) spec = w(spec, ...mods);
      break;
    }
    case 'number': {
      spec = num;
      const mods = [];
      if (chance(0.25)) mods.push(['min', pick([0, 1, -1, 0.5])]);
      if (chance(0.25)) mods.push(['max', pick([2, 3, 10, 100])]);
      if (chance(0.25)) mods.push(['step', pick([1, 2, 0.5, 0.1, 0.25])]);
      if (mods.length) spec = w(spec, ...mods);
      break;
    }
    case 'const': spec = ['const', pick(['on', 1, true, null, { k: 1 }, [1]])]; break;
    case 'consts': spec = ['union', [from(pick(['on', 'x'])), from(pick(['off', 1, false]))]]; break;
    case 'bitset': spec = mutating ? ['bitset', { a: 1, b: 2, c: 4 }] : bool; break;
    case 'array': spec = arr(genSpec(depth - 1, mutating)); if (chance(0.2)) spec = w(spec, ['min', int(2)], ['max', 1 + int(3)]); break;
    case 'dict':
      spec = mutating && chance(0.25)
        ? ['dict', genSpec(depth - 1, mutating), ['transform', str, pick(['upper', 'prefix'])]]
        : chance(0.2)
          ? ['dict', genSpec(depth - 1, mutating), w(str, ['pattern', '^[a-c]'])]
          : ['dict', genSpec(depth - 1, mutating)];
      break;
    case 'tuple': spec = ['tuple', Array.from({ length: int(3) }, () => genSpec(depth - 1, mutating))]; break;
    case 'object': {
      const fields = {};
      const count = int(4);
      for (let i = 0; i < count; i++) fields[pick(keyPool)] = genSpec(depth - 1, mutating);
      spec = obj(fields);
      break;
    }
    case 'union': spec = ['union', Array.from({ length: 1 + int(3) }, () => genSpec(depth - 1, false))]; break;
    case 'intersect':
      spec = ['intersect', Array.from({ length: 1 + int(2) }, () => (chance(0.8) ? genSpec(depth - 1, mutating) : obj({ [pick(keyPool)]: genSpec(0, mutating) })))];
      break;
    case 'transform': {
      const name = pick(['trim', 'upper', 'double', 'wrap', 'keys', 'length']);
      const inner = { trim: str, upper: str, double: num, wrap: genSpec(depth - 1, mutating), keys: obj({ [pick(keyPool)]: genSpec(0, mutating) }), length: arr(num) }[name];
      spec = mutating && chance(0.5) ? ['transform', inner, name] : ['transform', inner, name, true];
      break;
    }
    case 'lazy': spec = ['lazy', genSpec(depth - 1, mutating)]; break;
    default: spec = [kind];
  }
  if (kind === 'lazy') return spec;
  const mods = [];
  if (chance(0.12)) mods.push(['required']);
  if (chance(0.25)) mods.push(['default', withoutUndefinedItems(genValue(spec, 0.15))]);
  if (chance(0.05) && !mutating) mods.push(['loose']);
  return mods.length ? w(spec, ...mods) : spec;
}

// The JSON form writes an undefined array element as null, so a default that holds one would
// not survive the round trip the checker makes.
function withoutUndefinedItems(v) {
  if (Array.isArray(v)) return v.map((item) => (item === U ? null : withoutUndefinedItems(item)));
  if (v && typeof v === 'object') {
    return Object.fromEntries(Object.entries(v).map(([k, item]) => [k, withoutUndefinedItems(item)]));
  }
  return v;
}

function wrongValue() {
  return pick([null, U, true, 0, 3, -2, 0.3, 'zz', '', [], ['a'], [1, 'b'], {}, { a: 1 }, { name: 'n', zz: [1] }]);
}

// A value for `spec`: valid as far as the generator can tell, except that each node is
// replaced by an arbitrary value with probability `noise`.
function genValue(spec, noise) {
  if (chance(noise)) return wrongValue();
  const [type, ...rest] = spec;
  switch (type) {
    case 'with': {
      if (chance(0.3)) return pick([U, null]);
      return genValue(rest[0], noise);
    }
    case 'from': return rest[0] === null ? pick([1, 'x', U]) : rest[0];
    case 'prim': return { String: 's', Number: 1, Boolean: true, Function: U }[rest[0]];
    case 'string': return pick(wordPool);
    case 'number': return pick(numberPool);
    case 'natural': return pick([0, 1, 2, 5, 1.5, -1]);
    case 'percent': return pick([0, 0.5, 1, 0.25, 0.33, 2]);
    case 'boolean': return chance(0.5);
    case 'const': return rest[0];
    case 'any': return wrongValue();
    case 'never': return pick([U, null, 1]);
    case 'bitset': return pick([0, 1, 3, 6, 7, ['a'], ['a', 'c'], ['zz'], []]);
    case 'array': return Array.from({ length: int(4) }, () => genValue(rest[0], noise));
    case 'dict': {
      const result = {};
      const count = int(3);
      for (let i = 0; i < count; i++) result[pick(['a', 'b', 'c', 'Dd', 'e-f'])] = genValue(rest[0], noise);
      return result;
    }
    case 'tuple': {
      const items = rest[0].map((item) => genValue(item, noise));
      if (chance(0.2)) items.push(wrongValue());
      if (chance(0.2)) items.pop();
      return items;
    }
    case 'object': {
      const result = {};
      for (const [key, child] of Object.entries(rest[0])) {
        if (chance(0.25)) continue;
        result[key] = genValue(child, noise);
      }
      if (chance(0.25)) result[pick(['extra', 'zz', 'a', 'more'])] = wrongValue();
      return result;
    }
    case 'union': return rest[0].length ? genValue(pick(rest[0]), noise) : wrongValue();
    case 'intersect': {
      const values = rest[0].map((item) => genValue(item, noise));
      if (values.every((v) => v && typeof v === 'object' && !Array.isArray(v) && v !== U)) return Object.assign({}, ...values);
      return values.length ? pick(values) : wrongValue();
    }
    case 'transform': return genValue(rest[0], noise);
    case 'lazy': return genValue(rest[0], noise);
    default: return wrongValue();
  }
}

// Whether `spec` holds a union with a member that is more than a constant. With autofix, a
// member of such a union can delete keys of the input before it fails, which later members
// then see in Schemastery (documented as a difference).
function hasCompositeUnion(spec) {
  if (!Array.isArray(spec)) return spec && typeof spec === 'object' && Object.values(spec).some(hasCompositeUnion);
  if (spec[0] === 'union' && spec[1].some((member) => member[0] !== 'from')) return true;
  return spec.slice(1).some((part) => typeof part === 'object' && part !== null && hasCompositeUnion(part));
}

function randomRows(count) {
  const rows = [];
  for (let i = 0; i < count; i++) {
    const spec = genSpec(1 + int(3), chance(0.5));
    const cases = [];
    for (let j = 0; j < 4; j++) {
      const input = genValue(spec, pick([0, 0.1, 0.3]));
      const picked = pick([undefined, undefined, undefined, { autofix: true }, { strict: true }, { path: ['cfg', 2] }]);
      const options = picked?.autofix && hasCompositeUnion(spec) ? undefined : picked;
      cases.push(o(input, options));
    }
    rows.push(row(`random ${i}`, spec, cases));
  }
  return rows;
}

// ---------------------------------------------------------------------------------------------
// Sections: simplify, i18n, raw-config comparison

const simplifyCases = [
  [obj({ a: w(num, ['default', 1]), b: str }), [{ a: 1, b: 'x', c: 2 }, { a: 2 }, { a: 1 }, {}, U, null, 'abc', 5, [1, 2], { b: null }]],
  [str, [U, null, 'a', 1]],
  [w(str, ['default', 'd']), [U, null, 'd', 'e']],
  [w(num, ['default', 1]), [1, 1.0, 2, U, null]],
  [['dict', w(num, ['default', 1])], [{ a: 1, b: 2 }, {}, U, null, 'ab', [5, 6]]],
  [w(['dict', str], ['default', { k: 'v' }]), [{ k: 'v' }, { k: 'w' }, {}, { k: 'v', extra: null }]],
  [arr(w(num, ['default', 1])), [[1, 2, 1], [], U, [null]]],
  [w(arr(str), ['default', ['.']]), [['.'], ['a'], []]],
  [['tuple', [w(num, ['default', 1]), str]], [[1, 'a', true], [2], []]],
  [['intersect', [obj({ a: w(num, ['default', 1]) }), obj({ b: w(str, ['default', 'x']) })]], [{ a: 1, b: 'y' }, { a: 2, b: 'x' }, { a: 1, b: 'x' }]],
  [['intersect', [str, arr(num)]], ['ab', [1, 2]]],
  [['union', [obj({ kind: from('a'), n: w(num, ['default', 1]) }), obj({ kind: from('b'), s: w(str, ['default', 'x']) })]], [{ kind: 'a', n: 1 }, { kind: 'b', s: 'y' }, { kind: 'c' }, 'zz']],
  [['union', [from('legacy'), from('timed')]], ['legacy', 'other']],
  [w(['union', [from('quiet'), from('wakeup')]], ['default', 'wakeup']), ['wakeup', 'quiet']],
  [['transform', str, 'trim'], [' a ']],
  [['lazy', w(str, ['default', 'd'])], ['d', 'e']],
  [obj({ nested: obj({ count: w(num, ['default', 1]), label: str }), list: arr(obj({ id: str, n: w(num, ['default', 0]) })) }), [{ nested: { count: 1 }, list: [{ id: 'a', n: 0 }, { id: 'b', n: 2 }] }, { nested: { count: 2, label: 'l' }, list: [] }, { nested: {}, list: [{}] }]],
  [w(obj({ a: w(num, ['default', 1]) }), ['default', { a: 2 }]), [{ a: 2 }, { a: 1 }, { a: 3 }, {}]],
  [['bitset', bits], [0, 3, ['read']]],
  [['any'], [U, null, { a: 1 }]],
];

const i18nCases = [
  [str, { en: 'Text', 'zh-CN': '文本' }],
  [w(str, ['description', 'Original.']), { en: 'Text' }],
  [w(str, ['description', { '': 'Base', en: 'Old' }]), { en: 'New', fr: { $description: 'Texte' } }],
  [str, { en: { $desc: 'Short' }, fr: { $description: '', $desc: 'Fallback' }, de: { other: 1 }, it: 5 }],
  [obj({ a: str, b: obj({ c: num }) }), { en: { $description: 'Root', a: 'Field a', b: { $desc: 'Field b', c: 'Field c' } }, zh: { a: { $description: '甲' }, b: { c: '丙' } } }],
  [obj({ a: str }), { en: { $value: { a: 'From value' }, a: 'Direct' }, fr: { $inner: { a: 'Inner' } } }],
  [arr(obj({ id: str })), { en: { $description: 'List', id: 'Element id' }, fr: { $value: { $description: 'Element', id: 'Ident' } }, de: 'Liste' }],
  [['dict', num, str], { en: { $description: 'Map', $key: 'Key', $value: 'Value' }, fr: { $key: { $desc: 'Cle' }, $inner: { $desc: 'Valeur' } } }],
  [['tuple', [str, num]], { en: ['First', 'Second'], fr: { $value: ['Premier'], $description: 'Paire' }, de: { $description: 'Paar' } }],
  [['union', [obj({ a: str }), obj({ b: num })]], { en: { a: 'A', b: 'B', $description: 'Either' } }],
  [['intersect', [obj({ a: str }), obj({ b: num })]], { en: { a: 'A', b: 'B' } }],
  [['transform', str, 'trim'], { en: { $description: 'Outer', $value: 'Inner' } }],
  [obj({ a: w(str, ['description', 'Keep']) }), {}],
  [obj({ a: str, b: num }), { en: { a: null } }],
];

const jsExpr = (source) => ({ __jsExpr: source });
const diffNested = obj({ nested: w(obj({ live: w(str, ['volatile']), fixed: str }), ['default', { fixed: 'default' }]) });
const diffDefaults = obj({ nested: w(obj({ fixed: str }), ['default', { fixed: 'default' }]) });
const diffWide = obj({
  nested: obj({ value: w(str, ['volatile']) }),
  block: w(obj({ title: str }), ['volatile']),
  list: w(arr(str), ['volatile']),
  choice: w(['union', [str, num]], ['volatile']),
});
const diffCases = [
  [obj({ title: w(['transform', str, 'trim'], ['volatile']), fixed: str }), { title: 'old', fixed: 'same' }, { title: jsExpr('throw new Error("must not run")'), fixed: 'same' }],
  [diffWide, {}, { nested: { value: 'new' }, block: { title: 'new' }, list: ['new'], choice: 1 }],
  [diffWide, { nested: { value: 'new' }, block: { title: 'new' }, list: ['new'], choice: 1 }, {}],
  [w(str, ['volatile']), 'old', 'new'],
  [diffNested, {}, { nested: { live: 'new', fixed: 'default' } }],
  [diffNested, {}, { nested: { live: 'new' } }],
  [diffNested, {}, { unknown: 'new' }],
  [diffNested, { nested: jsExpr('source.a') }, { nested: jsExpr('source.b') }],
  [diffNested, { nested: jsExpr('source.a') }, { nested: jsExpr('source.a') }],
  [diffNested, { nested: 'invalid' }, { nested: { live: 'new' } }],
  [diffNested, { nested: [] }, { nested: ['new'] }],
  [obj({ fixed: ['transform', str, 'same'], live: w(str, ['volatile']) }), { fixed: 'first' }, { fixed: 'second' }],
  [str, 'first', 'second'],
  [str, [U], [null]],
  [str, U, null],
  [obj({ a: str }), { fixed: 'same' }, { fixed: 'same' }],
  [diffDefaults, U, {}],
  [diffDefaults, {}, null],
  [diffDefaults, { nested: U }, { nested: { fixed: 'default' } }],
  [diffDefaults, { nested: null }, { nested: { fixed: 'default' } }],
  [diffDefaults, {}, { nested: { fixed: 'changed' } }],
  [diffDefaults, {}, { nested: {} }],
  [obj({ __jsExpr: w(str, ['volatile']) }), { __jsExpr: 'first' }, { __jsExpr: 'second' }],
  [obj({ list: arr(str), live: w(str, ['volatile']) }), { list: [U], live: 'before' }, { list: ['new'], live: 'after' }],
  [obj({ list: arr(str), live: w(str, ['volatile']) }), { list: ['a'], live: 'before' }, { list: ['a'], live: 'after' }],
  [obj({ live: w(str, ['volatile']) }), { constructor: 'first', live: 'old' }, { constructor: 'second', live: 'new' }],
  [obj({ live: w(str, ['volatile']) }), { toString: 'first', live: 'old' }, { toString: 'first', live: 'new' }],
  [obj({ first: obj({ value: w(str, ['volatile']) }), second: obj({ value: w(str, ['volatile']) }) }), {}, { first: { value: 'one' }, second: { value: 'two' } }],
  [obj({ a: obj({ b: obj({ c: w(num, ['volatile']), d: num }) }) }), { a: { b: { c: 1, d: 2 } } }, { a: { b: { c: 9, d: 2 } } }],
  [obj({ a: obj({ b: obj({ c: w(num, ['volatile']), d: num }) }) }), { a: { b: { c: 1, d: 2 } } }, { a: { b: { c: 1, d: 3 } } }],
  [obj({ a: w(obj({ c: w(num, ['volatile']) }), ['default', U]) }), {}, { a: { c: 1 } }],
  [obj({ a: w(obj({ c: w(num, ['volatile']) }), ['default', U]) }), { a: null }, {}],
  [obj({ a: num }), { a: 1 }, { a: 1.0 }],
  [obj({ a: num }), { a: null }, {}],
  [obj({ a: arr(obj({ v: w(str, ['volatile']) })) }), { a: [{ v: 'x' }] }, { a: [{ v: 'y' }] }],
  [['union', [obj({ v: str })]], { v: 'x' }, { v: 'y' }],
];

// ---------------------------------------------------------------------------------------------
// Output

const header = [
  ';; Generated by tests/gen/gen-node-table.mjs from the vendored Schemastery; do not edit.',
  `;; node ${process.version}, seed ${seed}, ${randomCount} random schemas.`,
];

const callbackLines = Object.entries(callbacks)
  .map(([name, fn]) => `  (${rktString(name)} . ${rktString(fn.toString())})`);

const rowTexts = [
  ...fixed.map(([name, spec, cases]) => row(name, spec, cases)),
  ...randomRows(randomCount),
];

const simplifyLines = simplifyCases.flatMap(([spec, values]) => values.map((value) => {
  const result = attempt(() => `(ok ${enc(build(spec).simplify(materialize(value)))})`);
  return `  (${encSpec(spec)} ${enc(value)} ${result})`;
}));

const i18nLines = i18nCases.map(([spec, messages]) => {
  const result = attempt(() => `(ok ${rktString(canonicalJson(build(spec).i18n(materialize(messages))))})`);
  return `  (${encSpec(spec)} ${enc(messages)} ${result})`;
});

const diffLines = diffCases.map(([spec, a, b]) => {
  const result = attempt(() => `(ok ${enc(equalExceptVolatile(materialize(a), materialize(b), build(spec)))})`);
  const without = enc(equalExceptVolatile(materialize(a), materialize(b), undefined));
  return `  (${encSpec(spec)} ${enc(a)} ${enc(b)} ${result} ${without})`;
});

const text = [
  ...header,
  '(',
  ` (callbacks\n${callbackLines.join('\n')})`,
  ` (rows\n${rowTexts.join('\n')})`,
  ` (simplify\n${simplifyLines.join('\n')})`,
  ` (i18n\n${i18nLines.join('\n')})`,
  ` (diff\n${diffLines.join('\n')})`,
  ')',
  '',
].join('\n');

writeFileSync(outPath, text);
const caseCount = (text.match(/\(\(input /g) ?? []).length;
console.log(`${outPath}: ${rowTexts.length} schemas, ${caseCount} resolve cases, ` +
  `${simplifyLines.length} simplify, ${i18nLines.length} i18n, ${diffLines.length} diff rows`);
