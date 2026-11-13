#!/usr/bin/env node
// Generates the differential table that tests/node-table-test.rkt checks cordis-data against.
// Every expected result is computed by Node: JSON.stringify, JSON.parse, String(n), str.length,
// Buffer.byteLength, str.slice, the string `<` operator and Buffer#toString('utf8').
//
//   node tests/gen/gen-node-table.mjs                 rewrite tests/data/node-table.rktd
//   node tests/gen/gen-node-table.mjs --scale 40 --number-scale 800 --seed 7 --out /tmp/fuzz.rktd
//
// --scale multiplies the number of random rows in every section; --number-scale (default: the
// scale) does so for the two number sections alone.
//
// The output is one Racket datum. A JSON value is encoded so that Racket's own reader rebuilds
// it without going through the code under test: an object is a list of (key . value) pairs in
// JavaScript's enumeration order, an array is a vector, null is the symbol `null`, and a double
// that is not a safe integer is a flonum literal. Uses Node built-ins only; the same seed and
// scale give the same file.

import { writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

// ---------------------------------------------------------------------------------------------
// Arguments and random numbers

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i += 2) {
    if (!argv[i].startsWith('--') || argv[i + 1] === undefined) {
      throw new Error('usage: gen-node-table.mjs [--seed N] [--scale N] [--number-scale N] [--out FILE]');
    }
    args[argv[i].slice(2)] = argv[i + 1];
  }
  return args;
}

const args = parseArgs(process.argv.slice(2));
const seed = Number(args.seed ?? 20261113);
const scale = Number(args.scale ?? 1);
const numberScale = Number(args['number-scale'] ?? scale);
const here = dirname(fileURLToPath(import.meta.url));
const outPath = args.out ?? join(here, '..', 'data', 'node-table.rktd');

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
const between = (lo, hi) => lo + int(hi - lo + 1);
const pick = (xs) => xs[int(xs.length)];
const chance = (p) => rand() < p;
const times = (n, f) => Array.from({ length: n }, (_, i) => f(i));

// ---------------------------------------------------------------------------------------------
// Racket literals

const BACKSLASH = String.fromCharCode(0x5c);
const QUOTE = String.fromCharCode(0x22);
const REPLACEMENT = String.fromCharCode(0xfffd);

// A Racket string literal in ASCII. Racket's reader joins two consecutive surrogate escapes.
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

const f64 = new Float64Array(1);
const u64 = new BigUint64Array(f64.buffer);

function doubleBits(x) {
  f64[0] = x;
  return u64[0];
}

function doubleFromBits(bits) {
  u64[0] = bits;
  return f64[0];
}

// The IEEE 754 bit pattern as a Racket exact integer literal.
function rktBits(x) {
  return '#x' + doubleBits(x).toString(16).padStart(16, '0');
}

function rktNumber(n, floatInts) {
  if (Number.isNaN(n)) return '+nan.0';
  if (n === Infinity) return '+inf.0';
  if (n === -Infinity) return '-inf.0';
  if (Object.is(n, -0)) return '-0.0';
  if (Number.isSafeInteger(n) && !floatInts) return String(n);
  const text = String(n);
  return /[.e]/.test(text) ? text : text + '.0';
}

// A value the table writes as the Racket literal `literal` and that JSON.stringify sees as `js`.
class Raw {
  constructor(literal, js) {
    this.literal = literal;
    this.js = js;
  }

  toJSON() {
    return this.js;
  }
}

const exactInteger = (big) => new Raw(big.toString(), Number(big));
const exactRational = (n, d) => new Raw(`${n}/${d}`, n / d);

function rktValue(v, floatInts = false) {
  if (v === null) return 'null';
  if (v === true) return '#t';
  if (v === false) return '#f';
  if (typeof v === 'number') return rktNumber(v, floatInts);
  if (typeof v === 'string') return rktString(v);
  if (v instanceof Raw) return v.literal;
  if (Array.isArray(v)) return '#(' + v.map((x) => rktValue(x, floatInts)).join(' ') + ')';
  const entries = Object.keys(v).map((k) => `(${rktString(k)} . ${rktValue(v[k], floatInts)})`);
  return '(' + entries.join(' ') + ')';
}

// JSON.parse results can hold lone surrogates; cordis-data replaces each with U+FFFD.
function wellFormed(v) {
  if (typeof v === 'string') return v.toWellFormed();
  if (Array.isArray(v)) return v.map(wellFormed);
  if (v !== null && typeof v === 'object') {
    return Object.fromEntries(Object.entries(v).map(([k, x]) => [k.toWellFormed(), wellFormed(x)]));
  }
  return v;
}

// ---------------------------------------------------------------------------------------------
// Random strings and values

const controlChars = times(32, (i) => String.fromCharCode(i));
const lineSeparators = [String.fromCharCode(0x2028), String.fromCharCode(0x2029)];
const astralChars = [0x1f600, 0x10000, 0x10ffff, 0x1f468, 0x20bb7, 0x1d11e].map((c) =>
  String.fromCodePoint(c),
);
const bmpChars = [0xe9, 0x4e2d, 0x6587, 0x7f, 0x80, 0xa0, 0xd7ff, 0xe000, 0xfffd, 0xffff, 0xfeff, 0x3b1]
  .map((c) => String.fromCharCode(c));
const asciiWords = ['a', 'b', 'key', 'value', 'type', 'name', 'id', 'x', 'Z', '0', '1', '42', '-1', '01',
  '1.5', ' ', '  ', '/', '</script>', 'true', 'null', '__proto__', 'constructor', 'toString', '$ref', '',
  '{', '}', '[', ']', ':', ',', '#', ';', '(', ')', "'", '`', '~', '%', 'e', 'E', '+', '-', '.'];

function randomChar() {
  const kind = int(10);
  if (kind < 5) return String.fromCharCode(between(0x20, 0x7e));
  if (kind === 5) return pick(controlChars);
  if (kind === 6) return pick([QUOTE, BACKSLASH, '/', BACKSLASH + QUOTE, BACKSLASH + BACKSLASH]);
  if (kind === 7) return pick(bmpChars.concat(lineSeparators));
  if (kind === 8) return pick(astralChars);
  return String.fromCodePoint(pick([between(0xa0, 0xd7ff), between(0xe000, 0xffff), between(0x10000, 0x10ffff)]));
}

function randomString() {
  if (chance(0.25)) return pick(asciiWords);
  return times(int(chance(0.9) ? 12 : 80), randomChar).join('');
}

function randomKey() {
  if (chance(0.6)) return pick(asciiWords);
  if (chance(0.1)) return String(int(1000));
  return randomString();
}

function randomDouble() {
  const kind = int(12);
  if (kind === 0) return int(10);
  if (kind === 1) return between(-1000000, 1000000);
  if (kind === 2) return between(-1000, 1000) / pick([2, 4, 8, 10, 100, 1000, 3, 7]);
  if (kind === 3) return Number(`${between(1, 9999)}e${between(-30, 30)}`);
  if (kind === 4) return Number(`${between(1, 999999999)}e${between(-330, 300)}`);
  if (kind === 5) return (chance(0.5) ? -1 : 1) * 2 ** between(-1074, 1023);
  if (kind === 6) return pick([0, -0, 1e21, 1e-7, 1e-6, 0.000001, 1e20, 999999999999999900000, 1.5e-7,
    2 ** 53, 2 ** 53 + 2, -(2 ** 53), Number.MAX_VALUE, Number.MIN_VALUE, Number.EPSILON, 0.1, 0.2, 0.3,
    0.1 + 0.2, 4.35, 1 / 3, 123456789012345680000, 1e100, 1.7976931348623157e308, 2.2250738585072014e-308,
    5e-324, 9007199254740993, 0.1e-5, 123456.789e3, 1e23, 8.41e21, 5e-7, 123e-20, 4.9e-324]);
  if (kind === 7) return Math.round(rand() * 1e17) / 10 ** between(0, 25);
  if (kind === 8) return Math.fround(rand() * 100);
  if (kind === 9) return (rand() - 0.5) * 10 ** between(-10, 25);
  // Uniform over bit patterns, so every exponent and the subnormals are as likely as any other.
  for (;;) {
    const x = doubleFromBits((BigInt(int(2 ** 32)) << 32n) | BigInt(int(2 ** 32)));
    if (Number.isFinite(x)) return x;
  }
}

function randomValue(depth) {
  const kind = int(depth <= 0 ? 6 : 9);
  if (kind === 0) return null;
  if (kind === 1) return chance(0.5);
  if (kind === 2 || kind === 3) return randomDouble();
  if (kind === 4 || kind === 5) return randomString();
  if (kind === 6 || kind === 7) return times(int(chance(0.8) ? 5 : 20), () => randomValue(depth - 1));
  // Object.fromEntries defines "__proto__" as an own property.
  return Object.fromEntries(
    times(int(chance(0.8) ? 5 : 20), () => [randomKey(), randomValue(depth - 1)]),
  );
}

const randomIndent = () => (chance(0.5) ? null : between(1, 10));
const rktIndent = (indent) => (indent === null ? '#f' : String(indent));

// ---------------------------------------------------------------------------------------------
// Section: stringify, (value indent expected-text)

const stringifyRows = [];

function addStringify(value, indent = null) {
  const expected = JSON.stringify(value, null, indent ?? undefined);
  const plain = rktValue(value, false);
  const floats = rktValue(value, true);
  stringifyRows.push(`(${plain} ${rktIndent(indent)} ${rktString(expected)})`);
  // The same value with its safe integers held as flonums must print identically.
  if (floats !== plain) stringifyRows.push(`(${floats} ${rktIndent(indent)} ${rktString(expected)})`);
}

const curatedScalars = [
  null, true, false, 0, -0, 1, -1, 7, 100, 1.5, -2.25, 0.1, 0.1 + 0.2, 4.35, 1 / 3, 25, 1e5, 1e20, 1e21, -1e21,
  1.5e21, 999999999999999900000, 123456789012345680000, 1e-6, 1e-7, 1.5e-7, 0.000001234, 0.00000123, 1e300,
  1e-300, 5e-324, Number.MAX_VALUE, Number.MIN_VALUE, Number.EPSILON, Number.MAX_SAFE_INTEGER,
  Number.MIN_SAFE_INTEGER, 2 ** 53, 2 ** 53 + 2, 2 ** 63, 2 ** 64, 2 ** 31, -(2 ** 31), 4294967295, 1e15, 1e16,
  1e17, 123456789.123456789, 2.2250738585072014e-308, 1.7976931348623157e308, 0.5, 0.25, 1e-5, 12345.678e-10,
  new Raw('+nan.0', NaN), new Raw('+inf.0', Infinity), new Raw('-inf.0', -Infinity),
  exactInteger(2n ** 53n + 1n), exactInteger(2n ** 64n), exactInteger(-(2n ** 63n)), exactInteger(10n ** 21n),
  exactInteger(10n ** 22n), exactInteger(10n ** 21n - 1n), exactInteger(123456789012345678901234567890n),
  exactInteger(10n ** 400n), exactInteger(-(10n ** 400n)), exactInteger(9007199254740993n),
  exactRational(1, 3), exactRational(-22, 7), exactRational(1, 1000000), exactRational(1, 10000000),
  exactRational(3, 2), exactRational(1, 8),
  '', 'a', 'hello world', QUOTE, BACKSLASH, '/', '</script>', QUOTE + BACKSLASH + QUOTE,
  controlChars.join(''), 'tab\there', 'line\nbreak\r\n', String.fromCharCode(0x7f), lineSeparators.join(''),
  bmpChars.join(''), astralChars.join(''), 'caf' + String.fromCharCode(0xe9),
  String.fromCharCode(0x4e2d, 0x6587), String.fromCodePoint(0x1f600) + 'x' + String.fromCodePoint(0x1f600),
];

const curatedStructures = [
  [], {}, [[]], [{}], { a: [] }, { a: {} }, [1, 2, 3], [null], [[], {}], [[[[]]]], { a: 1 }, { z: 1, a: 2, m: 3 },
  { b: { d: 1, c: 2 }, a: [3, { y: 4, x: 5 }] }, { '': 1 }, { ' ': 1, '  ': 2 },
  { [QUOTE]: 1, [BACKSLASH]: 2, ['\n']: 3, [String.fromCharCode(0)]: 4, [String.fromCharCode(0x1f)]: 5 },
  { [String.fromCharCode(0xe9)]: 1, [String.fromCodePoint(0x1f600)]: 2, [lineSeparators[0]]: 3 },
  { b: 1, 2: 2, a: 3, 1: 4, '01': 5, '-1': 6, 1.5: 7, 4294967294: 8, 4294967295: 9 },
  Object.fromEntries([['__proto__', 1], ['constructor', 2], ['toString', 3]]),
  { type: 'object', properties: { path: { type: 'string', description: 'The file to read' },
    limit: { type: 'integer', minimum: 1 } }, required: ['path'], additionalProperties: false },
  { role: 'assistant', content: null, tool_calls: [{ id: 'call_1', type: 'function',
    function: { name: 'bash', arguments: '{"command":"ls -la"}' } }] },
  { jsonrpc: '2.0', id: 1, result: { ok: true, items: [1.5, 2, -0, 1e21, 1e-7, 'x', null, false] } },
  [1, 'two', 3.5, true, false, null, [], {}, [4], { five: 5 }],
  { a: [new Raw('+nan.0', NaN), new Raw('-inf.0', -Infinity), exactInteger(2n ** 64n), exactRational(1, 3)] },
  times(12, (i) => ({ index: i, half: i / 2, label: 'item ' + i })),
  { deep: { deeper: { deepest: { list: [[1, [2, [3, [4]]]]], empty: {}, none: [] } } } },
];

for (const value of curatedScalars) addStringify(value);
for (const value of curatedStructures) {
  for (const indent of [null, 1, 2, 4, 10]) addStringify(value, indent);
}
for (const indent of [1, 2, 3, 5, 6, 7, 8, 9]) addStringify({ a: [1, { b: [] }], c: 'x' }, indent);
for (const value of ['x', 1.5, null, true, [], {}]) addStringify(value, 2);
times(Math.round(70 * scale), () => addStringify(randomValue(between(0, 4)), randomIndent()));

// ---------------------------------------------------------------------------------------------
// Sections: parse, (text value), and parse-error, text

const parseRows = new Map();
const parseErrorRows = new Set();

// Records what JSON.parse does with `text`. Returns true when it parsed.
function addParse(text) {
  if (!text.isWellFormed()) return false;
  let value;
  try {
    value = JSON.parse(text);
  } catch {
    parseErrorRows.add(rktString(text));
    return false;
  }
  parseRows.set(rktString(text), rktValue(wellFormed(value)));
  return true;
}

const whitespace = () => (chance(0.6) ? '' : times(between(1, 3), () => pick([' ', '\n', '\t', '\r'])).join(''));
const hex4 = (unit) => {
  const digits = unit.toString(16).padStart(4, '0');
  return chance(0.5) ? digits.toUpperCase() : digits;
};
const unicodeEscape = (unit) => BACKSLASH + 'u' + hex4(unit);

// JSON text for a string, with escapes chosen at random among the spellings JSON allows.
function spellString(s) {
  let out = QUOTE;
  for (const ch of s) {
    const code = ch.codePointAt(0);
    const short = { 8: 'b', 9: 't', 10: 'n', 12: 'f', 13: 'r', 0x22: QUOTE, 0x5c: BACKSLASH, 0x2f: '/' }[code];
    if (code < 0x20 || code === 0x22 || code === 0x5c) {
      out += short !== undefined && chance(0.7) ? BACKSLASH + short : unicodeEscape(code);
    } else if (chance(0.15)) {
      if (short !== undefined) out += BACKSLASH + short;
      else if (code > 0xffff) out += unicodeEscape(ch.charCodeAt(0)) + unicodeEscape(ch.charCodeAt(1));
      else out += unicodeEscape(code);
    } else {
      out += ch;
    }
  }
  // Now and then an escaped lone surrogate, which JSON.parse accepts.
  if (chance(0.05)) out += unicodeEscape(between(0xd800, 0xdfff));
  if (chance(0.03)) out += unicodeEscape(between(0xd800, 0xdbff)) + pick(['x', unicodeEscape(0x41), '']);
  return out + QUOTE;
}

// JSON text for a number, in one of the spellings that denote the same or a nearby value.
function spellNumber(n) {
  const kind = int(8);
  if (kind === 0 && Number.isInteger(n) && Math.abs(n) < 1e15) return n + '.' + '0'.repeat(between(1, 3));
  if (kind === 1) return n.toExponential().replace('e', pick(['e', 'E']));
  if (kind === 2) return n.toExponential(between(0, 20)).replace('e+', pick(['e', 'E', 'e+']));
  if (kind === 3 && Math.abs(n) < 1e21 && Math.abs(n) >= 1e-6) return n.toFixed(between(0, 30));
  if (kind === 4 && n !== 0) return n.toPrecision(between(1, 40));
  if (kind === 5 && Number.isInteger(n) && Math.abs(n) < 1e21) {
    return String(n) + 'e' + pick(['0', '+0', '-0', '00']);
  }
  return Object.is(n, -0) ? '-0' : String(n);
}

function spellValue(v) {
  const w = whitespace;
  if (typeof v === 'string') return spellString(v);
  if (typeof v === 'number') return spellNumber(v);
  if (v === null || typeof v === 'boolean') return String(v);
  if (Array.isArray(v)) return '[' + w() + v.map((x) => spellValue(x) + w()).join(',' + w()) + ']';
  const members = Object.entries(v).map(([k, x]) => spellString(k) + w() + ':' + w() + spellValue(x) + w());
  // A repeated key: the last value wins and the first position is kept.
  if (members.length > 0 && chance(0.15)) members.push(pick(members));
  return '{' + w() + members.join(',' + w()) + '}';
}

const mutationAlphabet = ['{', '}', '[', ']', ':', ',', QUOTE, BACKSLASH, '0', '1', '9', '-', '+', '.', 'e',
  'E', 't', 'r', 'u', 'n', 'l', 'f', 'a', 's', ' ', '\n', '\t', '\r', String.fromCharCode(0), '/', 'x',
  String.fromCharCode(0xb), String.fromCharCode(0xc), String.fromCharCode(0xa0), String.fromCharCode(0xfeff),
  String.fromCharCode(0x2028), 'true', 'null', 'false', '00', BACKSLASH + 'u', BACKSLASH + 'u12', 'Infinity',
  'NaN', "'", '//', '/*', 'undefined', '0x1', BACKSLASH + 'x41', BACKSLASH + QUOTE];

// A copy of `text` with one random edit; most are no longer JSON.
function mutate(text) {
  const points = [...text];
  const at = int(points.length + 1);
  const kind = int(5);
  if (kind === 0) points.splice(at, 1);
  else if (kind === 1) points.splice(at, 0, pick(mutationAlphabet));
  else if (kind === 2) points.splice(at, 1, pick(mutationAlphabet));
  else if (kind === 3) points.length = at;
  else points.splice(at, 0, points[int(points.length)] ?? '');
  return points.join('');
}

const curatedTexts = [
  // Valid.
  'null', 'true', 'false', '0', '-0', '1', '-1', '1.0', '1e3', '1E3', '1e+3', '1e-3', '0.5', '-0.0', '0e0',
  '123456789012345678901234567890', '9007199254740993', '-9007199254740993', '1e400', '-1e400', '1e-400',
  '0.1e1', '10e-1', '1.5e300', '2.5e-324', '2.4703282292062328e-324', '4.9e-324', '1.7976931348623159e308',
  '0.30000000000000004', '0.1000000000000000055511151231257827021181583404541015625',
  '9007199254740992.5', '9007199254740993.5', '1e22', '1e23', '8.5', '100000000000000000000000',
  '1e0000000000000000000000001', '0.0000000000000000000000000000001e31', '1' + '0'.repeat(400) + 'e-400',
  ' 1 ', '\t\n\r 1 \t\n\r', '""', '"a"', '[]', '{}', '[ ]', '{ }', '[1,2]', '[1, 2 ,3]', '{"a":1}',
  '{"a":1,"b":2,"a":3}', '{"b":1,"a":2}', '{"a":{"b":{"c":[]}}}', '[[[[[[]]]]]]', '{"":0}',
  '{"a" : 1 , "b" : [ ] }', '"' + BACKSLASH + 'n' + BACKSLASH + 't' + BACKSLASH + 'r' + BACKSLASH + 'b' +
    BACKSLASH + 'f' + BACKSLASH + '/' + BACKSLASH + BACKSLASH + BACKSLASH + QUOTE + '"',
  '"' + unicodeEscape(0x41) + '"', '"' + BACKSLASH + 'u00e9"', '"' + BACKSLASH + 'u00E9"',
  '"' + BACKSLASH + 'ud83d' + BACKSLASH + 'ude00"', '"' + BACKSLASH + 'uD83D' + BACKSLASH + 'uDE00"',
  '"' + BACKSLASH + 'ud800"', '"' + BACKSLASH + 'udc00"', '"' + BACKSLASH + 'ud800x"',
  '"' + BACKSLASH + 'ud800' + BACKSLASH + 'ud800' + BACKSLASH + 'udc00"',
  '"' + BACKSLASH + 'udc00' + BACKSLASH + 'ud800"', '"' + BACKSLASH + 'ud83d' + BACKSLASH + 'n"',
  '"' + BACKSLASH + 'ud83d' + BACKSLASH + 'u0041"', '"' + BACKSLASH + 'u0000"',
  '"' + String.fromCharCode(0x7f) + '"', '"' + lineSeparators.join('') + '"', '"' + astralChars.join('') + '"',
  '{"__proto__":1,"a":2}', '{"a":null,"b":true,"c":false}', '[null,true,false]', '"/"',
  '{"2":1,"1":2,"b":3,"a":4}', '[1e5,1E5,1e+5,1.0e5,100000]', '[-0,-0.0,0,0.0,-0e0]',
  // Invalid.
  '', ' ', 'nul', 'nulll', 'True', 'tru', 'falsee', 'undefined', 'NaN', 'Infinity', '-Infinity', '+1', '01',
  '-01', '1.', '.5', '-.5', '1e', '1e+', '1E-', '1.e5', '0x10', '1_000', '--1', '-', '- 1', '1 2', '1,',
  '00', '0.', '1.2.3', '1e1.5', '1ee1', '2e', 'e5', "'a'", '"a', 'a"', '"', '"' + BACKSLASH + '"',
  '"' + BACKSLASH + 'x41"', '"' + BACKSLASH + 'a"', '"' + BACKSLASH + 'u12"', '"' + BACKSLASH + 'u12g4"',
  '"' + BACKSLASH + 'U0041"', '"' + BACKSLASH + 'u 041"', '"a\nb"', '"a\tb"',
  '"' + String.fromCharCode(0) + '"', '"' + String.fromCharCode(0x1f) + '"', '[', ']', '{', '}', '[1', '[1,',
  '[1,]', '[,1]', '[,]', '[1 2]', '[1,,2]', '{"a"}', '{"a":}', '{"a":1,}', '{,"a":1}', '{"a":1 "b":2}',
  '{a:1}', "{'a':1}", '{1:1}', '{"a":1}}', '[[]', '[]]', '{"a":[}', '[{]}', '{"a":1]', '[1}', '[] []',
  '{} {}', 'null null', '"a" "b"', '//comment\n1', '/* c */ 1', '1 // c', '[1] x', String.fromCharCode(0xfeff) + '1',
  '1' + String.fromCharCode(0xa0), String.fromCharCode(0xb) + '1', String.fromCharCode(0xc) + '1',
  '1' + String.fromCharCode(0x2028), '[1' + String.fromCharCode(0x2029) + ']', '{"a":1,"a"}', 'nan', 'null,',
  '":"', ':', ',', 'tr ue', '[tru]', '[nul]', '1e5e', '"' + BACKSLASH + 'ud83d' + BACKSLASH + 'u"',
];

for (const text of curatedTexts) addParse(text);
times(Math.round(50 * scale), () => {
  const value = randomValue(between(0, 4));
  addParse(JSON.stringify(value, null, randomIndent() ?? undefined));
  const spelled = whitespace() + spellValue(value) + whitespace();
  if (!addParse(spelled)) throw new Error('the random speller produced invalid JSON: ' + spelled);
  times(2, () => addParse(mutate(chance(0.5) ? spelled : JSON.stringify(value))));
});

// ---------------------------------------------------------------------------------------------
// Section: numbers, (bits text): the double with that bit pattern prints as `text`

const numberRows = new Map();

function addNumber(x) {
  numberRows.set(rktBits(x), rktString(String(x)));
}

for (const x of curatedScalars) if (typeof x === 'number') addNumber(x);
for (const x of [NaN, Infinity, -Infinity, 0, -0]) addNumber(x);
for (let e = -330; e <= 310; e += numberScale > 1 ? 1 : 7) addNumber(Number('1e' + e));
for (let e = -1074; e <= 1023; e += numberScale > 1 ? 1 : 23) addNumber(2 ** e);
for (const base of [1e21, 1e-7, 1e-6, 2 ** 53, 1, 1e16, 1e15, 0.1, 123456789012345680000]) {
  // The doubles just below and just above each layout boundary.
  addNumber(doubleFromBits(doubleBits(base) - 1n));
  addNumber(doubleFromBits(doubleBits(base) + 1n));
  addNumber(-base);
}
times(Math.round(120 * numberScale), () => addNumber(randomDouble()));
times(Math.round(120 * numberScale), () => {
  addNumber(doubleFromBits((BigInt(int(2 ** 32)) << 32n) | BigInt(int(2 ** 32))));
});

// ---------------------------------------------------------------------------------------------
// Section: number-texts, (text bits): JSON.parse(text) is the double with that bit pattern

const numberTextRows = new Map();

function addNumberText(text) {
  numberTextRows.set(rktString(text), rktBits(JSON.parse(text)));
}

const digits = (n) => times(n, () => int(10)).join('');

function randomNumberText() {
  const sign = chance(0.3) ? '-' : '';
  const integer = chance(0.3) ? '0' : between(1, 9) + digits(chance(0.8) ? int(18) : int(45));
  const fraction = chance(0.6) ? '.' + (chance(0.3) ? '0'.repeat(int(30)) : '') + digits(between(1, chance(0.8) ? 18 : 45)) : '';
  const exponent = chance(0.5)
    ? pick(['e', 'E']) + pick(['', '+', '-']) + (chance(0.8) ? between(0, 30) : between(0, 400))
    : '';
  return sign + integer + fraction + exponent;
}

// The exact decimal expansion of numerator / 2^shift, for BigInt numerator and shift >= 0.
function exactDecimal(numerator, shift) {
  const scaled = (numerator * 5n ** BigInt(shift)).toString().padStart(shift + 1, '0');
  const cut = scaled.length - shift;
  return shift === 0 ? scaled : scaled.slice(0, cut) + '.' + scaled.slice(cut);
}

// Decimal texts at and beside the midpoint between a positive double and its successor, where
// correct rounding (ties to even) is hardest.
function midpointTexts(x) {
  const bits = doubleBits(x);
  const biased = Number((bits >> 52n) & 0x7ffn);
  const fraction = bits & 0xfffffffffffffn;
  const mantissa = biased === 0 ? fraction : fraction | (1n << 52n);
  const exponent = (biased === 0 ? 1 : biased) - 1075;
  // The midpoint is (2 * mantissa + 1) * 2^(exponent - 1).
  const numerator = 2n * mantissa + 1n;
  const power = exponent - 1;
  const exact = power >= 0 ? (numerator << BigInt(power)).toString() : exactDecimal(numerator, -power);
  const above = exact.includes('.') ? [exact + '1', exact + '0'.repeat(5) + '1'] : [exact + '.5', exact + '.0001'];
  const last = Number(exact.at(-1));
  const below = last > 0 ? [exact.slice(0, -1) + String(last - 1) + '9'.repeat(3)] : [];
  return [exact, ...above, ...below];
}

for (const text of curatedTexts) if (/^-?[0-9]/.test(text) && /^[-+.0-9eE]+$/.test(text)) {
  try {
    addNumberText(text);
  } catch {
    // Not JSON; the parse-error section holds it.
  }
}
times(Math.round(120 * numberScale), () => addNumberText(randomNumberText()));
times(Math.round(15 * numberScale), () => {
  for (const text of midpointTexts(Math.abs(randomDouble()) || 1)) addNumberText(text);
});
for (const x of [Number.MAX_VALUE, Number.MIN_VALUE, 2.2250738585072014e-308, 2.225073858507201e-308, 1, 2 ** 53,
  9007199254740991, 0.1, 1e23, 5e-324, 1e22]) {
  for (const text of midpointTexts(x)) addNumberText(text);
}

// ---------------------------------------------------------------------------------------------
// Sections on string length units

function stripLoneSurrogates(s) {
  let out = '';
  for (let i = 0; i < s.length; i++) {
    const unit = s.charCodeAt(i);
    const next = s.charCodeAt(i + 1);
    if (unit >= 0xd800 && unit <= 0xdbff && next >= 0xdc00 && next <= 0xdfff) {
      out += s[i] + s[i + 1];
      i++;
    } else if (unit < 0xd800 || unit > 0xdfff) {
      out += s[i];
    }
  }
  return out;
}

// The longest prefix of at most `max` UTF-8 bytes that ends on a character boundary.
function utf8Prefix(s, max) {
  const bytes = Buffer.from(s, 'utf8');
  let end = Math.min(max, bytes.length);
  while (end > 0 && end < bytes.length && (bytes[end] & 0xc0) === 0x80) end--;
  return bytes.subarray(0, end).toString('utf8');
}

const lengthStrings = ['', 'a', 'hello', astralChars[0], 'a' + astralChars[0] + 'b', astralChars.join(''),
  bmpChars.join(''), String.fromCharCode(0xe9) + String.fromCharCode(0x4e2d) + astralChars[1],
  astralChars[0].repeat(3), 'x'.repeat(40), lineSeparators.join('') + 'z',
  String.fromCharCode(0x65, 0x301) + astralChars[3] + String.fromCharCode(0x200d) + astralChars[3]]
  .concat(times(Math.round(50 * scale), randomString));

const lengthRows = lengthStrings.map((s) =>
  `(${rktString(s)} ${s.length} ${Buffer.byteLength(s, 'utf8')} ${[...s].length})`);

const sliceRows = [];
const truncateRows = [];
for (const s of lengthStrings) {
  times(4, () => {
    const start = int(s.length + 3);
    const end = chance(0.3) ? null : int(s.length + 3);
    const expected = stripLoneSurrogates(end === null ? s.slice(start) : s.slice(start, end));
    sliceRows.push(`(${rktString(s)} ${start} ${end === null ? '#f' : end} ${rktString(expected)})`);
  });
  times(3, () => {
    const max = int(Buffer.byteLength(s, 'utf8') + 3);
    truncateRows.push(`(${rktString(s)} ${max} ${rktString(stripLoneSurrogates(s.slice(0, max)))} ` +
      `${rktString(utf8Prefix(s, max))})`);
  });
}

const orderStrings = ['', 'a', 'b', 'ab', 'B', 'a' + astralChars[0], 'a' + String.fromCharCode(0xe000),
  'a' + String.fromCharCode(0xffff), 'a' + String.fromCharCode(0xd7ff), astralChars[0], astralChars[1],
  astralChars[2], String.fromCharCode(0xfffd), String.fromCharCode(0xe9), astralChars[0] + 'a',
  String.fromCharCode(0xff5e) + 'x', astralChars[4] + astralChars[5]]
  .concat(times(Math.min(Math.round(6 * scale), 80), randomString));
const orderRows = [];
for (const a of orderStrings) {
  for (const b of orderStrings) orderRows.push(`(${rktString(a)} ${rktString(b)} ${a < b ? '#t' : '#f'})`);
}

// ---------------------------------------------------------------------------------------------
// Section: utf8, ((byte ...) text): the bytes between quotes decode to `text`

function randomBytes() {
  const out = [];
  const count = int(12);
  for (let i = 0; i < count; i++) {
    const kind = int(6);
    if (kind === 0) out.push(between(0x23, 0x5b));
    else if (kind === 1) out.push(...Buffer.from(randomChar().replace(/[\x00-\x1f"\\]/g, 'q'), 'utf8'));
    else if (kind === 2) out.push(between(0x80, 0xff));
    else if (kind === 3) out.push(pick([0xc0, 0xc1, 0xc2, 0xdf, 0xe0, 0xed, 0xef, 0xf0, 0xf4, 0xf5, 0xff]));
    else if (kind === 4) out.push(pick([0xe0, 0xed, 0xf0, 0xf4, 0xe2, 0xf1]), pick([0x80, 0x8f, 0x90, 0x9f, 0xa0, 0xbf]));
    else out.push(pick([0xf0, 0xf4, 0xf1]), between(0x80, 0xbf), between(0x80, 0xbf));
  }
  return out;
}

const utf8Cases = [[], [0x41], [0xc3, 0xa9], [0xe2, 0x82, 0xac], [0xf0, 0x9f, 0x98, 0x80], [0xff], [0xc3], [0xe2, 0x82],
  [0xe2, 0x82, 0x41], [0xf0, 0x9f, 0x98], [0xf0, 0x9f, 0x41], [0xc0, 0x80], [0xe0, 0x80, 0x80], [0xed, 0xa0, 0x80],
  [0xf4, 0x90, 0x80, 0x80], [0xf8, 0x88, 0x80, 0x80, 0x80], [0x80], [0xbf, 0x41], [0xef, 0xbb, 0xbf, 0x41],
  [0xe2, 0xe2, 0x82, 0xac], [0xf0, 0xc3, 0xa9]].concat(times(Math.round(60 * scale), randomBytes));
const utf8Rows = utf8Cases.map((bytes) => {
  const text = JSON.parse(Buffer.from([0x22, ...bytes, 0x22]).toString('utf8'));
  return `((${bytes.join(' ')}) ${rktString(text)})`;
});

// ---------------------------------------------------------------------------------------------
// Output

function section(name, rows) {
  return ` (${name}\n` + rows.map((row) => '  ' + row).join('\n') + ')';
}

const sections = [
  ['stringify', stringifyRows],
  ['parse', [...parseRows].map(([text, value]) => `(${text} ${value})`)],
  ['parse-error', [...parseErrorRows]],
  ['numbers', [...numberRows].map(([bits, text]) => `(${bits} ${text})`)],
  ['number-texts', [...numberTextRows].map(([text, bits]) => `(${text} ${bits})`)],
  ['lengths', lengthRows],
  ['slices', sliceRows],
  ['truncations', truncateRows],
  ['order', orderRows],
  ['utf8', utf8Rows],
];

const header = [
  ';; Generated by tests/gen/gen-node-table.mjs; do not edit.',
  `;; node ${process.version}, seed ${seed}, scale ${scale}, number scale ${numberScale}`,
  ';; Sections: (stringify (value indent text) ...) (parse (text value) ...) (parse-error text ...)',
  ';; (numbers (double-bits text) ...) (number-texts (text double-bits) ...)',
  ';; (lengths (string utf16 utf8 code-points) ...) (slices (string start end slice) ...)',
  ';; (truncations (string max utf16-prefix utf8-prefix) ...) (order (a b a<b) ...)',
  ';; (utf8 ((byte ...) decoded) ...)',
];

writeFileSync(outPath, header.join('\n') + '\n(\n' + sections.map(([n, rows]) => section(n, rows)).join('\n') + '\n)\n');
console.log(sections.map(([name, rows]) => `${name}: ${rows.length}`).join(', '));
console.log('wrote ' + outPath);
