import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import vm from 'node:vm'

const here = dirname(fileURLToPath(import.meta.url))

/* ── 极简 hooks 运行时：够跑按钮组件，不需要真 React DOM ───────────────── */
let hookStates = []
let hookRefs = []
let hookEffects = []
let hookIndex = 0
const effectRecords = []

function beginRender() {
  hookIndex = 0
  hookEffects = []
}
function useState(initial) {
  const index = hookIndex++
  if (!(index in hookStates)) hookStates[index] = typeof initial === 'function' ? initial() : initial
  const set = (next) => {
    hookStates[index] = typeof next === 'function' ? next(hookStates[index]) : next
  }
  return [hookStates[index], set]
}
function useRef(initial) {
  const index = hookIndex++
  if (!(index in hookRefs)) hookRefs[index] = { current: initial }
  return hookRefs[index]
}
function useEffect(effect, deps) {
  hookEffects.push({ index: hookIndex++, effect, deps })
}
function sameDeps(left, right) {
  if (left === undefined || right === undefined) return false
  if (left.length !== right.length) return false
  for (let i = 0; i < left.length; i += 1) if (left[i] !== right[i]) return false
  return true
}
function runEffects() {
  for (const call of hookEffects) {
    const previous = effectRecords[call.index]
    if (previous && sameDeps(previous.deps, call.deps)) continue
    if (previous && typeof previous.cleanup === 'function') previous.cleanup()
    effectRecords[call.index] = { deps: call.deps, cleanup: call.effect() }
  }
}
function createElement(type, props) {
  return { type, props: props || {}, children: Array.prototype.slice.call(arguments, 2) }
}

/* ── 加载浏览器 bundle（同一份源码）────────────────────────────────────── */
let fetchHandler = async () => { throw new Error('fetch not arranged') }
let styleNode = null
const sandbox = {
  window: { __ModuleLoader__: { load(entry) { sandbox.factory = entry.factory } } },
  document: {
    querySelector() { return null },
    createElement(tag) {
      const element = { dataset: {}, textContent: '', setAttribute() {}, appendChild() {} }
      if (tag === 'style') styleNode = element
      return element
    },
    head: { appendChild() {} },
    body: { appendChild() {} },
  },
  setTimeout: () => 1,
  clearTimeout: () => {},
  AbortController,
  console,
  navigator: {},
  fetch: (...args) => fetchHandler(...args),
}
vm.createContext(sandbox)
vm.runInContext(readFileSync(join(here, '..', 'lib', 'client.js'), 'utf8'), sandbox, { filename: 'client.js' })
const bundle = sandbox.factory((id) => (id === 'react'
  ? { createElement, Fragment: 'Fragment', useState, useEffect, useRef }
  : { createPortal() {} }))

assert.ok(styleNode, 'plugin stylesheet injected')
assert.ok(styleNode.textContent.includes('@keyframes __dpe_flicker'), 'flicker keyframes shipped')
assert.ok(styleNode.textContent.includes('.__dpe_sparkle'), 'sparkle animation class shipped')
assert.ok(!styleNode.textContent.includes('__dpe_dots'), 'three-dot styles removed')
assert.ok(styleNode.textContent.includes('.__dpe_btn[data-state="busy"]{background:transparent;border-color:transparent;box-shadow:none}'), 'busy state is borderless and transparent')
assert.ok(styleNode.textContent.includes('.__dpe_btn[data-state="busy"]:hover:not(:disabled),.__dpe_btn[data-state="busy"]:active:not(:disabled){background:transparent}'), 'busy hover/active keep a transparent background')

const registered = []
bundle.apply({
  slots: {
    inject(name, factory) { return factory() },
    register(definition, component) { registered.push({ definition, component }); return () => {} },
  },
})
assert.equal(registered.length, 1, 'button registered into conversation.input.right')
assert.equal(registered[0].definition.name, 'conversation.input.right')
const Component = registered[0].component

/* ── 引用芯片夹具 ─────────────────────────────────────────────────────── */
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
    if (typeof part === 'string') { text += part; continue }
    occurrences.push({ ...part, offset: text.length, length: part.clipboardText.length })
    text += part.clipboardText
  }
  return { text, occurrences }
}
function findButton(node) {
  if (!node || typeof node !== 'object') return null
  if (node.type === 'button') return node
  for (const child of node.children || []) {
    const found = findButton(child)
    if (found) return found
  }
  return null
}
function render(props) {
  beginRender()
  const tree = Component(props)
  runEffects()
  return tree
}
async function flush() {
  for (let i = 0; i < 6; i += 1) await Promise.resolve()
  await new Promise((resolve) => setImmediate(resolve))
}

/* ── 增强 → 芯片保留 → 撤回还原芯片 ───────────────────────────────────── */
{
  const original = fixture(['请参考 ', chip('@src/a.ts', { appearance: 'file' }), ' 修复登录页'])
  const enhanced = '请先阅读背景，然后参考 @src/a.ts 修复登录页，并补充复现步骤与验收标准。'
  const inputState = { draft: original.text, phase: 'plain', occurrences: original.occurrences }
  const calls = []
  const props = {
    sessionId: 'session-1',
    useInput: () => inputState,
    inputActions: {
      setDraft(value) {
        calls.push(value)
        inputState.draft = typeof value === 'string' ? value : value.text
        inputState.occurrences = value && typeof value === 'object' && Array.isArray(value.references) ? value.references : []
      },
    },
  }
  fetchHandler = async () => ({
    ok: true,
    status: 200,
    text: async () => JSON.stringify({ ok: true, text: enhanced, unchanged: false }),
  })

  const firstTree = render(props)
  const firstButton = findButton(firstTree)
  assert.ok(firstButton, 'idle button rendered')
  assert.equal(firstButton.props['data-state'], 'idle')
  firstButton.props.onClick()
  await flush()

  assert.equal(calls.length, 1, 'enhanced draft written once')
  const filled = calls[0]
  assert.equal(typeof filled, 'object', 'semantic draft passed to setDraft')
  assert.equal(filled.text, enhanced)
  assert.equal(filled.references.length, 1, 'reference chip kept')
  const ref = filled.references[0]
  assert.equal(ref.clipboardText, '@src/a.ts')
  assert.equal(ref.appearance, 'file')
  assert.equal(filled.text.slice(ref.offset, ref.offset + ref.length), '@src/a.ts')
  assert.ok(ref.offset > original.occurrences[0].offset, 'chip moved with the rewritten text')

  const filledTree = render(props)
  const undoButton = findButton(filledTree)
  assert.equal(undoButton.props['data-state'], 'undo', 'button switched to undo')
  undoButton.props.onClick()

  assert.equal(calls.length, 2, 'undo writes the original draft')
  const restored = calls[1]
  assert.equal(typeof restored, 'object', 'original semantic draft restored')
  assert.equal(restored.text, original.text)
  assert.equal(restored.references.length, 1)
  assert.equal(restored.references[0].offset, original.occurrences[0].offset)
  assert.equal(restored.text.slice(restored.references[0].offset, restored.references[0].offset + restored.references[0].length), '@src/a.ts')

  const restoredTree = render(props)
  assert.equal(findButton(restoredTree).props['data-state'], 'idle', 'button back to sparkles')
}

/* ── 生成中渲染 ✨ 闪烁类，不再渲染三点波纹 ───────────────────────────── */
{
  hookStates = []
  hookRefs = []
  hookIndex = 0
  effectRecords.length = 0
  const inputState = { draft: '帮我改一下', phase: 'plain', occurrences: [] }
  let pending = null
  fetchHandler = () => new Promise((resolve) => { pending = resolve })
  const props = {
    sessionId: 'session-busy',
    useInput: () => inputState,
    inputActions: { setDraft() {} },
  }
  const tree = render(props)
  findButton(tree).props.onClick()
  const busyTree = render(props)
  const busy = findButton(busyTree)
  assert.equal(busy.props['data-state'], 'busy')
  assert.equal(busy.props['aria-busy'], 'true')

  function collect(node, className, found = []) {
    if (!node || typeof node !== 'object') return found
    if (node.props && node.props.className === className) found.push(node)
    for (const child of node.children || []) collect(child, className, found)
    return found
  }
  const sparkles = collect(busyTree, '__dpe_sparkle')
  assert.equal(sparkles.length, 1, 'busy state renders exactly one flickering sparkle')
  assert.equal(sparkles[0].type, 'svg')
  assert.equal(collect(busyTree, '__dpe_dots').length, 0, 'three-dot loader is gone')
  assert.ok(pending, 'request stayed in flight for the busy assertion')
}

/* ── 宿主拒绝结构化草稿时退回纯文本，不影响填入 ─────────────────────────── */
{
  hookStates = []
  hookRefs = []
  hookIndex = 0
  effectRecords.length = 0
  const original = fixture(['看 ', chip('@src/a.ts')])
  const enhanced = '请先看 @src/a.ts 再给出结论。'
  const inputState = { draft: original.text, phase: 'plain', occurrences: original.occurrences }
  const calls = []
  const props = {
    sessionId: 'session-3',
    useInput: () => inputState,
    inputActions: {
      setDraft(value) {
        calls.push(value)
        if (value !== null && typeof value === 'object') throw new Error('semantic draft unsupported')
        inputState.draft = value
        inputState.occurrences = []
      },
    },
  }
  fetchHandler = async () => ({
    ok: true,
    status: 200,
    text: async () => JSON.stringify({ ok: true, text: enhanced, unchanged: false }),
  })
  const tree = render(props)
  findButton(tree).props.onClick()
  await flush()
  assert.equal(calls.length, 2, 'semantic attempt then plain fallback')
  assert.equal(typeof calls[0], 'object')
  assert.equal(calls[1], enhanced, 'plain enhanced text still written')
}

/* ── 没有引用时仍然只传字符串，不改变原有写入形状 ───────────────────────── */
{
  hookStates = []
  hookRefs = []
  hookIndex = 0
  effectRecords.length = 0
  const inputState = { draft: '帮我改一下这句话', phase: 'plain', occurrences: [] }
  const calls = []
  const props = {
    sessionId: 'session-2',
    useInput: () => inputState,
    inputActions: { setDraft(value) { calls.push(value); inputState.draft = typeof value === 'string' ? value : value.text } },
  }
  fetchHandler = async () => ({
    ok: true,
    status: 200,
    text: async () => JSON.stringify({ ok: true, text: '请帮我改写这句话，使其更清晰具体。', unchanged: false }),
  })
  const tree = render(props)
  findButton(tree).props.onClick()
  await flush()
  assert.equal(calls.length, 1)
  assert.equal(typeof calls[0], 'string', 'plain string when there is no reference')
}

console.log('client ui: ok')
