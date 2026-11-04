/**
 * 反向插桩：逐个破坏上下文抽取逻辑，确认对应测试会失败。
 * 目的：证明测试断言真的在保护行为，而不是恒真。
 */
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { readFileSync, writeFileSync, copyFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
import { tmpdir } from 'node:os'

const here = dirname(fileURLToPath(import.meta.url))
const target = join(here, '..', 'lib', 'context.js')
/* 备份写到系统临时目录，避免污染仓库（曾把 .bak 误提交）。 */
const backup = join(tmpdir(), 'dpe-context-mutation-' + process.pid + '.bak')
copyFileSync(target, backup)
const original = readFileSync(backup, 'utf8')

const runTests = () => {
  try {
    execFileSync(process.execPath, ['--test', join(here, 'context.test.mjs')], { stdio: 'pipe' })
    return true
  } catch {
    return false
  }
}

const mutations = [
  {
    name: '不再过滤系统注入消息',
    from: "  return !NON_HUMAN_SOURCE_KINDS.has(kind)",
    to: "  return true",
  },
  {
    name: 'extractText 混入 reasoning 块',
    from: "    if (block.type !== 'text') continue",
    to: "    if (block.type !== 'text' && block.type !== 'reasoning') continue",
  },
  {
    name: 'pickPreviousMessage 取第一条而非最后一条',
    from: "  return messages[messages.length - 1]",
    to: "  return messages[0]",
  },
  {
    name: 'clampMessage 不做截断',
    from: "  if (text.length <= limit) return text",
    to: "  if (text.length <= limit) return text\n  return text",
  },
  {
    name: 'collectContextMessages 不按 seq 排序',
    from: "    .sort((a, b) => a.seq - b.seq)",
    to: "    .sort((a, b) => 0)",
  },
  {
    name: '上一条消息不再单独标重点',
    from: "    lines.push(isLast ? '[上一条消息·' + who + '（重点）]' : '[' + who + ']')",
    to: "    lines.push('[' + who + ']')",
  },
  {
    name: '上一条消息不再享有更大篇幅',
    from: "    lines.push(clampMessage(message.text, isLast ? MAX_LAST_MESSAGE_CHARS : MAX_CONTEXT_MESSAGE_CHARS))",
    to: "    lines.push(clampMessage(message.text, MAX_CONTEXT_MESSAGE_CHARS))",
  },
]

let ok = true
try {
  for (const m of mutations) {
    if (!original.includes(m.from)) {
      console.log('ANCHOR_MISSING: ' + m.name)
      ok = false
      continue
    }
    writeFileSync(target, original.replace(m.from, m.to), 'utf8')
    const passed = runTests()
    writeFileSync(target, original, 'utf8')
    if (passed) {
      console.log('FALSE_GREEN: ' + m.name)
      ok = false
    } else {
      console.log('caught: ' + m.name)
    }
  }
} finally {
  writeFileSync(target, original, 'utf8')
}
console.log(ok ? 'ALL_MUTATIONS_CAUGHT' : 'MUTATION_CHECK_FAILED')
process.exit(ok ? 0 : 1)
