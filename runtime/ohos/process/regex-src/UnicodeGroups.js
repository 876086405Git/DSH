// OHOS rg adapter for the Unicode 16 tables in re2js 1.3.3.
// Word follows Rust regex: Alphabetic + Mark + Nd + Pc + Join_Control.
import { UnicodeTables } from './UnicodeTables'
import { Unicode } from './Unicode'

const wordTables = ['L', 'Nl', 'M', 'Nd', 'Pc'].map(name => UnicodeTables.CATEGORIES.get(name))
// The Alphabetic supplement outside L/Nl/M consists of enclosed Latin letters.
const wordExtra = [[0x200c, 0x200d], [0x24b6, 0x24e9], [0x1f130, 0x1f149], [0x1f150, 0x1f169], [0x1f170, 0x1f189]]
const space = [9, 13, 32, 32, 0x85, 0x85, 0xa0, 0xa0, 0x1680, 0x1680, 0x2000, 0x200a, 0x2028, 0x2029, 0x202f, 0x202f, 0x205f, 0x205f, 0x3000, 0x3000]

function ranges(tables, extra = []) {
  const all = extra.map(pair => pair.slice())
  for (const table of tables) for (let i = 0; i < table.length; i++) {
    const lo = table.getLo(i), hi = table.getHi(i), stride = table.getStride(i)
    if (stride === 1) all.push([lo, hi])
    else for (let cp = lo; cp <= hi; cp += stride) all.push([cp, cp])
  }
  all.sort((a, b) => a[0] - b[0] || a[1] - b[1])
  const joined = []
  for (const pair of all) {
    const last = joined.at(-1)
    if (last && pair[0] <= last[1] + 1) last[1] = Math.max(last[1], pair[1])
    else joined.push(pair)
  }
  return joined.flat()
}

function isUnicodeWord(cp) {
  if (cp < 0) return false
  if (cp < 128) return (cp >= 48 && cp <= 57) || (cp >= 65 && cp <= 90) || (cp >= 97 && cp <= 122) || cp === 95
  return wordTables.some(table => Unicode.is(table, cp)) || wordExtra.some(([lo, hi]) => lo <= cp && cp <= hi)
}
const digit = ranges([UnicodeTables.CATEGORIES.get('Nd')])
const word = ranges(wordTables, wordExtra)
const PERL_GROUPS = new Map([
  ['\\d', { sign: 1, cls: digit }], ['\\D', { sign: -1, cls: digit }],
  ['\\s', { sign: 1, cls: space }], ['\\S', { sign: -1, cls: space }],
  ['\\w', { sign: 1, cls: word }], ['\\W', { sign: -1, cls: word }],
])
export { PERL_GROUPS, isUnicodeWord }
