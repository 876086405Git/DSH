/**
 * 反向插桩：破坏字数控制逻辑，确认 smoke-host.mjs 会失败。
 * 目的：证明「严格字数」相关断言真的在保护行为。
 */
import { execFileSync } from 'node:child_process'
import { readFileSync, writeFileSync, copyFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
import { tmpdir } from 'node:os'

const here = dirname(fileURLToPath(import.meta.url))
const target = join(here, '..', 'lib', 'index.js')
/* 备份写到系统临时目录，避免污染仓库（曾把 .bak 误提交）。 */
const backup = join(tmpdir(), 'dpe-limit-mutation-' + process.pid + '.bak')
copyFileSync(target, backup)
const original = readFileSync(backup, 'utf8')

const runTests = () => {
  try {
    execFileSync(process.execPath, [join(here, 'smoke-host.mjs')], { stdio: 'pipe' })
    return true
  } catch {
    return false
  }
}

const mutations = [
  {
    name: '字数上限不再封顶（随输入无限增长）',
    from: '  const limit = Math.max(150, Math.min(800, raw))',
    to: '  const limit = Math.max(150, raw)',
  },
  {
    name: '字数上限最低值失效（短输入不保底）',
    from: '  const limit = Math.max(150, Math.min(800, raw))',
    to: '  const limit = Math.min(800, raw)',
  },
  {
    name: '超限不再压缩重写',
    from: '          if ([...cleaned.text].length > limit) {',
    to: '          if (false) {',
  },
  {
    name: '最终不再硬截断',
    from: '          const fitted = hardTrimToLimit(cleaned.text, limit)',
    to: '          const fitted = { text: cleaned.text, trimmed: false }',
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
console.log(ok ? 'ALL_LIMIT_MUTATIONS_CAUGHT' : 'LIMIT_MUTATION_CHECK_FAILED')
process.exit(ok ? 0 : 1)
