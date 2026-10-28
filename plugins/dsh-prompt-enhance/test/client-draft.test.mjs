import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import vm from 'node:vm'

const here = dirname(fileURLToPath(import.meta.url))

/* 在 Node 里执行浏览器 bundle：只提供它加载期真正用到的最小桩。 */
function loadBundle() {
  let factory = null
  const documentStub = {
    querySelector() { return null },
    createElement() { return { dataset: {}, setAttribute() {}, appendChild() {} } },
    head: { appendChild() {} },
    body: { appendChild() {} },
  }
  const React = {
    createElement() { return null },
    Fragment: 'Fragment',
    useState() {},
    useEffect() {},
    useRef() {},
  }
  const ReactDOM = { createPortal() {} }
  const sandbox = {
    window: { __ModuleLoader__: { load(entry) { factory = entry.factory } } },
    document: documentStub,
    setTimeout,
    clearTimeout,
    AbortController,
    console,
    fetch: async () => { throw new Error('network not expected in this test') },
    navigator: {},
  }
  vm.createContext(sandbox)
  vm.runInContext(readFileSync(join(here, '..', 'lib', 'client.js'), 'utf8'), sandbox, { filename: 'client.js' })
  assert.equal(typeof factory, 'function', 'bundle registered a factory')
  return factory((id) => (id === 'react' ? React : ReactDOM))
}

const bundle = loadBundle()
assert.equal(typeof bundle.apply, 'function')
assert.equal(typeof bundle.inject, 'object')
const draftRefs = bundle.__draftReferences
assert.ok(draftRefs, 'reference helpers are exposed for tests')
const { buildOriginalDraft, buildEnhancedDraft, collectReferences, mapReferencesToText, copyReference } = draftRefs

const chip = (clipboardText, extra = {}) => ({
  occurrenceId: Math.random(),
  source: 'file',
  ref: clipboardText.replace(/^@/u, ''),
  label: clipboardText.replace(/^@/u, ''),
  clipboardText,
  ...extra,
})

function fixture(parts) {
  let text = ''
  const occurrences = []
  for (const part of parts) {
    if (typeof part === 'string') {
      text += part
      continue
    }
    occurrences.push({ ...part, offset: text.length, length: part.clipboardText.length })
    text += part.clipboardText
  }
  return { text, occurrences }
}

// ── 无引用：保持纯字符串 ─────────────────────────────────────────────────
{
  assert.equal(buildOriginalDraft('没有引用的草稿', []), '没有引用的草稿')
  assert.equal(buildEnhancedDraft('增强结果', undefined), '增强结果')
}

// ── 原草稿：引用按原位置结构化，内部字段不泄漏 ───────────────────────────
{
  const f = fixture(['请参考 ', chip('@src/a.ts', { appearance: 'file' }), ' 并检查 ', chip('@lib/b.ts', { appearance: 'folder' }), '。'])
  const draft = buildOriginalDraft(f.text, f.occurrences)
  assert.equal(typeof draft, 'object')
  assert.equal(draft.text, f.text)
  assert.equal(draft.references.length, 2)
  assert.equal(draft.references[0].offset, f.text.indexOf('@src/a.ts'))
  assert.equal(draft.references[1].offset, f.text.indexOf('@lib/b.ts'))
  assert.equal(draft.references[0].appearance, 'file')
  assert.equal(draft.references[1].appearance, 'folder')
  assert.equal(draft.references[0].occurrenceId, undefined)
  for (const ref of draft.references) {
    assert.equal(ref.length, ref.clipboardText.length)
    assert.equal(draft.text.slice(ref.offset, ref.offset + ref.length), ref.clipboardText)
  }
}

// ── 位置对不上的旧投影不参与结构化（退回纯文本）──────────────────────────
{
  const f = fixture([chip('@src/a.ts')])
  const stale = [{ ...f.occurrences[0], offset: f.text.length + 3 }]
  assert.equal(buildOriginalDraft(f.text, stale), f.text)
  assert.equal(collectReferences(f.text, stale).length, 0)
}

// ── 增强结果：模型加了前言后，芯片落到新位置 ─────────────────────────────
{
  const f = fixture(['比较 ', chip('@src/a.ts'), ' 和 ', chip('@lib/b.ts'), ' 的实现差异'])
  const enhanced = '请先阅读以下背景：\n\n' + f.text + '，并列出改动点。'
  const draft = buildEnhancedDraft(enhanced, f.occurrences)
  assert.equal(typeof draft, 'object')
  assert.equal(draft.text, enhanced)
  assert.equal(draft.references.length, 2)
  assert.ok(draft.references[0].offset > f.occurrences[0].offset)
  for (const ref of draft.references) {
    assert.equal(draft.text.slice(ref.offset, ref.offset + ref.length), ref.clipboardText)
  }
  assert.ok(draft.references[0].offset < draft.references[1].offset)
}

// ── 引用词被模型改写掉：该引用降级为纯文本，其余仍然保留 ─────────────────
{
  const f = fixture(['看 ', chip('@src/a.ts'), ' 和 ', chip('@lib/b.ts')])
  const enhanced = '看 ' + f.text.slice(f.text.indexOf('@src/a.ts'), f.text.indexOf('@src/a.ts') + 9) + ' 和 lib/b.ts'
  const draft = buildEnhancedDraft(enhanced, f.occurrences)
  assert.equal(draft.references.length, 1)
  assert.equal(draft.references[0].clipboardText, '@src/a.ts')
  assert.equal(draft.text.slice(draft.references[0].offset, draft.references[0].offset + draft.references[0].length), '@src/a.ts')
}

// ── 同一个引用在增强结果里出现两次：按顺序各占一个，互不重叠 ─────────────
{
  const f = fixture(['看 ', chip('@src/a.ts'), ' 再对照 ', chip('@src/a.ts')])
  const draft = buildEnhancedDraft(f.text, f.occurrences)
  assert.equal(draft.references.length, 2)
  const [a, b] = draft.references
  assert.ok(a.offset < b.offset)
  assert.ok(a.offset + a.length <= b.offset)
}

// ── 引用一个都不剩：直接返回字符串，绝不编造芯片 ─────────────────────────
{
  const f = fixture([chip('@src/a.ts')])
  const draft = buildEnhancedDraft('完全换了说法的结果', f.occurrences)
  assert.equal(typeof draft, 'string')
  assert.equal(draft, '完全换了说法的结果')
  assert.equal(mapReferencesToText('没有引用', f.occurrences).length, 0)
}

// ── 未知 appearance / 非法字段被丢掉，合法字段保留 ───────────────────────
{
  const ref = copyReference({
    source: 'file',
    ref: 'x',
    label: 'x',
    clipboardText: '@x',
    offset: 0,
    length: 2,
    appearance: 'weird',
    invalid: true,
    occurrenceId: 9,
  })
  assert.equal(ref.appearance, undefined)
  assert.equal(ref.invalid, true)
  assert.equal(ref.occurrenceId, undefined)
  assert.equal(copyReference(null), null)
  assert.equal(copyReference({ source: 'file' }), null)
  assert.equal(copyReference({ ...ref, length: 3 }), null)
}

console.log('client draft refs: ok')
