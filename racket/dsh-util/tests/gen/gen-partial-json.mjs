// Generates tests/data/partial-json-table.json: scripted reads of dsh PartialArguments over
// chunked argument text, with the answers the TypeScript implementation gives.
//
// Run from a directory where Node can strip TypeScript types:
//   node --experimental-transform-types tests/gen/gen-partial-json.mjs <repo>/packages/util > tests/data/partial-json-table.json
// The Racket suite reads the checked-in table and needs no Node.
import { pathToFileURL } from 'node:url'
import { resolve } from 'node:path'

const root = resolve(process.argv[2] ?? '../../../../packages/util')
const { PartialArguments } = await import(pathToFileURL(resolve(root, 'values/src/index.ts')).href)

function mulberry32(seed) {
  let a = seed >>> 0
  return () => {
    a |= 0; a = (a + 0x6d2b79f5) | 0
    let t = Math.imul(a ^ (a >>> 15), 1 | a)
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

const UNDEF = '__undefined__'
const enc = value => (value === undefined ? UNDEF : value)

// Texts without surrogate pairs: every streamed state has the same answer in Racket.
const TEXTS = [
  '{}',
  ' { } ',
  '{"path":"src/a.ts","content":"line one\\nline two\\n","count":3,"flag":true,"none":null}',
  '{"a":"x","b":[1,{"c":"]}\\"","d":[]}],"e":{"f":"{"},"g":-1.5e3,"h":false}',
  '{ "k" : "v" , "n" : 12 , "o" : { "p" : [ ] } }',
  '{"text":"quote \\" backslash \\\\ slash \\/ b\\b f\\f n\\n r\\r t\\t done"}',
  '{"u":"\\u0041\\u00e9\\u4E2d\\u00DF","plain":"é中ß"}',
  '{"esc\\u0061ped":"1","a\\"b":"2","":"empty key"}',
  '{"dup":"first","other":1,"dup":"second value"}',
  '{"dup":[1,2],"dup":"now a string"}',
  '{"long":"' + 'abcdefghij'.repeat(12) + '","tail":1}',
  '{"bad":"a\\qb","after":"ok"}',
  '{"bad":"a\\u12G4b","after":2}',
  '{"bad":"ctrl\u0001char","after":[1]}',
  '{"v":tru,"w":1}',
  '{"v":[1,2,"x"}',
  '{"v":{"a":[1,2}}',
  '{"v":01,"w":"ok"}',
  '{"v":"unterminated',
  '{"v":123',
  '{"v":[1,[2,[3',
  '{"a":1,}',
  '{"a" 1}',
  '{,"a":1}',
  '["not","an","object"]',
  '{"a":1} trailing',
  '{"a":1}  \n ',
  '{"a":"x"} {"b":"y"}',
  '{"key\u0001":"control in key"}',
  '{"bad\\qkey":"invalid key escape","b":1}',
  '{"n":{"s":"brace } bracket ] quote \\" end"},"m":["]","\\\\"],"z":"\\\\"}',
  '{"e":"","f":"\\\\\\\\","g":"\\\\\\"","h":"x\\\\"}',
  '{"content":"# Title\\n\\nSome *markdown* with \\"quotes\\" and a tab\\there.\\n","path":"README.md"}',
  '   ',
  '',
  'x',
  '{"a":nul',
  '{"a":null',
  '{"a":"\\',
  '{"a":"\\u00',
  '{"a":"x\\u004',
]

// Texts with astral characters: read only after all text arrived.
const FINAL_TEXTS = [
  '{"emoji":"a\\ud83d\\ude00b","raw":"a\u{1F600}b","lone":"x\\ud83dy","low":"\\ude00z"}',
  '{"pair":"\\uD83D\\uDE00\\uD83D\\uDE01","k":1}',
]

const KEY_POOL = ['path', 'content', 'count', 'flag', 'none', 'a', 'b', 'e', 'g', 'h', 'k', 'n', 'o', 'text', 'u',
  'plain', 'escaped', 'a"b', '', 'dup', 'other', 'long', 'tail', 'bad', 'after', 'v', 'w', 'm', 'z', 'f', 'missing',
  'emoji', 'raw', 'lone', 'low', 'pair']

function keysOf(text) {
  const present = KEY_POOL.filter(key => text.includes(JSON.stringify(key).slice(1, -1)) || key === 'escaped')
  return [...new Set([...present.slice(0, 6), 'missing'])]
}

function read(view, op) {
  const [kind, key, a, b] = op
  switch (kind) {
    case 'closed': return view.closed()
    case 'keys': return [...view.keys()]
    case 'has': return view.has(key)
    case 'complete': return view.complete(key)
    case 'length': return view.stringLength(key, { step: a, offset: b })
    case 'exceeds': return view.stringExceeds(key, a)
    case 'text': return view.text(key)
    case 'prefix': return view.textPrefix(key, a)
    case 'value': return view.value(key)
    case 'invalid': return view.invalid
    case 'sealed': return view.isSealed
    case 'refresh': return view.refresh()
    default: throw new Error(kind)
  }
}

function randomRead(random, keys) {
  const key = keys[Math.floor(random() * keys.length)]
  const kinds = ['closed', 'keys', 'has', 'complete', 'length', 'exceeds', 'text', 'prefix', 'value', 'invalid', 'refresh']
  const kind = kinds[Math.floor(random() * kinds.length)]
  switch (kind) {
    case 'length': return [kind, key, [1, 1, 4, 16][Math.floor(random() * 4)], [0, 0, 3][Math.floor(random() * 3)]]
    case 'exceeds': return [kind, key, [0, 1, 3, 8, 40][Math.floor(random() * 5)]]
    case 'prefix': return [kind, key, [1, 2, 5, 20][Math.floor(random() * 4)]]
    case 'closed': case 'keys': case 'invalid': case 'refresh': return [kind]
    default: return [kind, key]
  }
}

function allReads(keys) {
  const ops = [['closed'], ['keys'], ['invalid'], ['sealed']]
  for (const key of keys) {
    ops.push(['has', key], ['complete', key], ['length', key, 1, 0], ['exceeds', key, 3], ['text', key],
      ['prefix', key, 4], ['value', key])
  }
  ops.push(['invalid'], ['refresh'])
  for (const key of keys) ops.push(['complete', key])
  return ops
}

const scenarios = []

function streamed(text, seed, settleWith) {
  const random = mulberry32(seed)
  const keys = keysOf(text)
  const view = new PartialArguments()
  const steps = []
  let offset = 0
  while (offset < text.length) {
    const size = 1 + Math.floor(random() * (seed % 3 === 0 ? 1 : 7))
    const fragment = text.slice(offset, offset + size)
    offset += size
    view.append(fragment)
    steps.push({ op: ['append', fragment] })
    const reads = Math.floor(random() * 3)
    for (let i = 0; i < reads; i += 1) {
      const op = randomRead(random, keys)
      steps.push({ op, result: enc(read(view, op)) })
    }
  }
  let final = view
  if (settleWith !== undefined) {
    final = view.settle(settleWith)
    steps.push({ op: ['settle', settleWith], result: final === view })
  }
  for (const op of allReads(keys)) steps.push({ op, result: enc(read(final, op)) })
  scenarios.push({ name: `stream seed ${seed}: ${text.slice(0, 40)}`, steps })
}

let seed = 1
for (const text of TEXTS) {
  for (let round = 0; round < 3; round += 1) {
    streamed(text, seed, round === 1 ? text : round === 2 && text.length > 3 ? text.slice(0, -1) + ' ' : undefined)
    seed += 1
  }
}

function whole(text, kind) {
  const keys = keysOf(text)
  const view = kind === 'text' ? PartialArguments.fromText(text) : new PartialArguments()
  const steps = []
  if (kind === 'text') steps.push({ op: ['from-text', text] })
  else { view.append(text); steps.push({ op: ['append', text] }) }
  for (const op of allReads(keys)) steps.push({ op, result: enc(read(view, op)) })
  scenarios.push({ name: `${kind}: ${text.slice(0, 40)}`, steps })
}
for (const text of [...TEXTS, ...FINAL_TEXTS]) { whole(text, 'text'); whole(text, 'stream') }

for (const value of [{ path: 'a.ts', n: 1, nested: { x: [1, 2] }, flag: false, none: null, long: 'abcdefghij' }, {}, [1, 2], 'text', 5, null]) {
  const keys = ['path', 'n', 'nested', 'flag', 'none', 'long', 'missing']
  const view = PartialArguments.fromObject(value)
  const steps = [{ op: ['from-object', value] }]
  for (const op of allReads(keys)) steps.push({ op, result: enc(read(view, op)) })
  scenarios.push({ name: `object: ${JSON.stringify(value)}`, steps })
}

process.stdout.write(JSON.stringify({ undefined: UNDEF, scenarios }) + '\n')
