/** 会话哨兵设置面板 · 假环境自测（临时脚本，不属于仓库产物） */
import assert from 'node:assert/strict'
import { pathToFileURL, fileURLToPath } from 'node:url'

const PLUGIN_DIR = fileURLToPath(new URL('..', import.meta.url)).replace(/[\\/]$/, '')
const CLIENT_URL = pathToFileURL(PLUGIN_DIR + '/lib/client.js').href
const { EDITABLE_FIELDS } = await import(pathToFileURL(PLUGIN_DIR + '/lib/config-store.js').href)

// ---------------- 迷你 React（hooks + 同步重渲染） ----------------
function createReactRuntime() {
  const rt = { slots: [], index: 0, pendingEffects: [], dirty: false, component: null, renders: 0, tree: null }
  const sameDeps = (a, b) => {
    if (!Array.isArray(a) || !Array.isArray(b)) return false
    if (a.length !== b.length) return false
    for (let i = 0; i < a.length; i += 1) if (!Object.is(a[i], b[i])) return false
    return true
  }
  const React = {
    createElement(type, props) {
      const children = []
      for (let i = 2; i < arguments.length; i += 1) {
        const child = arguments[i]
        if (Array.isArray(child)) { for (const item of child) children.push(item) }
        else children.push(child)
      }
      return { type: type, props: props || {}, children: children }
    },
    useState(initial) {
      const idx = rt.index++
      if (!(idx in rt.slots)) rt.slots[idx] = { kind: 'state', value: typeof initial === 'function' ? initial() : initial }
      const slot = rt.slots[idx]
      const setter = (updater) => {
        const next = typeof updater === 'function' ? updater(slot.value) : updater
        if (Object.is(next, slot.value)) return
        slot.value = next
        rt.dirty = true
      }
      return [slot.value, setter]
    },
    useEffect(fn, deps) {
      const idx = rt.index++
      if (!(idx in rt.slots)) rt.slots[idx] = { kind: 'effect', deps: undefined, cleanup: undefined }
      rt.pendingEffects.push({ slot: rt.slots[idx], fn: fn, deps: deps })
    },
    useCallback(fn, deps) {
      const idx = rt.index++
      if (!(idx in rt.slots)) rt.slots[idx] = { kind: 'callback', fn: fn, deps: deps }
      const slot = rt.slots[idx]
      if (!sameDeps(slot.deps, deps)) { slot.fn = fn; slot.deps = deps }
      return slot.fn
    },
    useRef(value) {
      const idx = rt.index++
      if (!(idx in rt.slots)) rt.slots[idx] = { kind: 'ref', current: value }
      return rt.slots[idx]
    },
  }
  function renderOnce() {
    rt.dirty = false
    rt.index = 0
    rt.pendingEffects = []
    rt.renders += 1
    rt.tree = rt.component({})
    for (const pending of rt.pendingEffects) {
      if (sameDeps(pending.slot.deps, pending.deps)) continue
      if (typeof pending.slot.cleanup === 'function') { try { pending.slot.cleanup() } catch (error) {} }
      pending.slot.cleanup = pending.fn()
      pending.slot.deps = pending.deps
    }
    return rt.tree
  }
  async function settle(maxRounds = 40) {
    let quiet = 0
    for (let i = 0; i < maxRounds; i += 1) {
      await new Promise((resolve) => setTimeout(resolve, 0))
      if (rt.dirty) { renderOnce(); quiet = 0; continue }
      quiet += 1
      if (quiet >= 2) return rt.tree
    }
    return rt.tree
  }
  function unmountAll() {
    for (const slot of rt.slots) {
      if (slot && slot.kind === 'effect' && typeof slot.cleanup === 'function') {
        try { slot.cleanup() } catch (error) {}
        slot.cleanup = undefined
      }
    }
  }
  return { React, rt, renderOnce, settle, unmountAll }
}

// ---------------- 假宿主配置 + fetch ----------------
const BASE_CONFIG = {
  enabled: true,
  autoResume: true,
  monitorSubagents: false,
  resumeOnStall: false,
  resumeOnStartupScan: false,
  skipWhenAwaitingUser: true,
  resumeKinds: ['error', 'interrupted', 'max-tokens'],
  includeCwd: ['D:\work'],
  excludeCwd: [],
  excludeSessionIds: [],
  notifyOnCompletion: true,
  completionSound: 'dingdong',
  completionVolume: 70,
  resumePromptMode: 'llm',
  notifyOnAborted: false,
  notifyOnStall: true,
  notifyOs: true,
  notifyGui: true,
  toastDurationMs: 8000,
  stallTimeoutMs: 600000,
  toolStallTimeoutMs: 120000,
  resumeDelayMs: 3000,
  maxResumesPerSession: 3,
  globalBudget: 10,
  maxConsecutiveFailures: 3,
  maxContextChars: 2000,
}
const clone = (value) => JSON.parse(JSON.stringify(value))

// ---------------- 假 AudioContext（验证「试听」真的排了音频） ----------------
function installFakeAudio(initialState = 'running') {
  const env = { contexts: [], starts: 0, gains: 0 }
  function FakeAudioContext() {
    env.contexts.push(this)
    this.state = initialState
    this.currentTime = 0
    this.destination = { connect() {} }
    this.resumeCalls = 0
    this.closeCalls = 0
    this.createOscillator = () => ({
      type: 'sine',
      frequency: {
        setValueAtTime() {},
        exponentialRampToValueAtTime() {},
      },
      connect() {},
      start() { env.starts += 1 },
      stop() {},
    })
    this.createGain = () => {
      env.gains += 1
      return {
        gain: {
          setValueAtTime() {},
          linearRampToValueAtTime() {},
          exponentialRampToValueAtTime() {},
        },
        connect() {},
      }
    }
    this.resume = () => {
      this.resumeCalls += 1
      this.state = 'running'
      return Promise.resolve()
    }
    this.close = () => {
      this.closeCalls += 1
      return Promise.resolve()
    }
  }
  globalThis.window.AudioContext = FakeAudioContext
  return env
}
function removeFakeAudio() {
  try { delete globalThis.window.AudioContext } catch (error) {}
  try { delete globalThis.window.webkitAudioContext } catch (error) {}
}

function createFetchSim(options = {}) {
  const sim = {
    config: clone(BASE_CONFIG),
    defaults: Object.assign(clone(BASE_CONFIG), { toastDurationMs: 5000, stallTimeoutMs: 900000 }),
    calls: [],
    getMode: options.getMode || 'ok',
    postMode: options.postMode || 'ok',
    postGate: false,
    gate: null,
  }
  const payload = () => ({
    ok: true,
    version: 1,
    editable: EDITABLE_FIELDS.slice(),
    config: clone(sim.config),
    defaults: clone(sim.defaults),
    updatedAt: Date.now(),
  })
  const okResponse = () => ({ ok: true, status: 200, json: () => Promise.resolve(payload()) })
  function handlePost(body) {
    if (sim.postMode === 'reject') return Promise.reject(new Error('network down'))
    if (sim.postMode === 'http') return Promise.resolve({ ok: false, status: 400, json: () => Promise.resolve({ ok: false, error: 'bad-request' }) })
    if (sim.postMode === 'badjson') return Promise.resolve({ ok: true, status: 200, json: () => Promise.reject(new Error('not json')) })
    if (body && body.reset === true) sim.config = clone(sim.defaults)
    else if (body && body.patch && typeof body.patch === 'object') Object.assign(sim.config, body.patch)
    return Promise.resolve(okResponse())
  }
  sim.handlePost = handlePost
  sim.payload = payload
  sim.releasePost = () => {
    const gate = sim.gate
    sim.gate = null
    sim.postGate = false
    if (gate) gate.resolve(okResponse())
  }
  sim.fetch = (url, init) => {
    const target = String(url)
    const method = (init && init.method) || 'GET'
    let body = null
    try { body = init && init.body ? JSON.parse(init.body) : null } catch (error) { body = null }
    sim.calls.push({ url: target, method: method, body: body })
    if (target.indexOf('/alerts') >= 0) {
      return Promise.resolve({ ok: true, status: 200, json: () => Promise.resolve({ ok: true, cursor: 0, alerts: [] }) })
    }
    if (method === 'GET') {
      if (sim.getMode === 'reject') return Promise.reject(new Error('network down'))
      if (sim.getMode === 'http') return Promise.resolve({ ok: false, status: 500, json: () => Promise.resolve({ ok: false, error: 'host-down' }) })
      return Promise.resolve(okResponse())
    }
    if (sim.postGate) {
      return new Promise((resolve, reject) => { sim.gate = { resolve: resolve, reject: reject } })
    }
    return handlePost(body)
  }
  return sim
}

// ---------------- 宿主 ctx 假实现 ----------------
function bootApp(options = {}) {
  const reactRuntime = createReactRuntime()
  const sim = createFetchSim(options)
  globalThis.fetch = sim.fetch
  let requireCalls = []
  const exportsObj = declaration.factory((name) => {
    requireCalls.push(name)
    if (name === 'react') return reactRuntime.React
    throw new Error('module unavailable: ' + name)
  })
  const slotEntries = []
  const effects = []
  const slots = {
    inject(name, cb) {
      const dispose = cb()
      return typeof dispose === 'function' ? dispose : () => {}
    },
    register(config, Component) {
      const entry = { config: config, Component: Component, disposed: false }
      slotEntries.push(entry)
      return () => { entry.disposed = true }
    },
  }
  const slotsViaInject = options.slotsVia === 'inject'
  const ctx = {
    uiSession: {},
    slots: slotsViaInject ? undefined : slots,
    get(name) {
      if (slotsViaInject) return name === 'uiSession' ? ctx.uiSession : undefined
      if (name === 'slots') return slots
      if (name === 'uiSession') return ctx.uiSession
      return undefined
    },
    inject(deps, cb) {
      if (!slotsViaInject || !Array.isArray(deps) || deps.indexOf('slots') < 0) return
      const scoped = {
        uiSession: {},
        slots: slots,
        get(name) { return name === 'slots' ? slots : undefined },
      }
      cb(scoped)
    },
    effect(fn) {
      const cleanup = fn()
      if (typeof cleanup === 'function') effects.push(cleanup)
    },
  }
  exportsObj.apply(ctx)
  const settingsEntry = slotEntries.find((entry) => entry.config && entry.config.name === 'settings.section')
  const badgeEntry = slotEntries.find((entry) => entry.config && entry.config.id === 'dsh-session-watchdog-badge')
  const app = {
    exportsObj: exportsObj,
    reactRuntime: reactRuntime,
    sim: sim,
    slotEntries: slotEntries,
    settingsEntry: settingsEntry,
    badgeEntry: badgeEntry,
    ctx: ctx,
    requireCalls: requireCalls,
    async mount() {
      reactRuntime.rt.component = settingsEntry.Component
      reactRuntime.renderOnce()
      await reactRuntime.settle()
      return reactRuntime.rt.tree
    },
    render() { return reactRuntime.rt.tree },
    async settle() { return reactRuntime.settle() },
    dispose() {
      for (const cleanup of effects) { try { cleanup() } catch (error) {} }
    },
  }
  return app
}

// ---------------- DOM 树工具 ----------------
function walk(node, visit) {
  if (node === null || node === undefined) return
  if (Array.isArray(node)) { for (const item of node) walk(item, visit); return }
  if (typeof node !== 'object') return
  if (node.type !== undefined) visit(node)
  for (const child of node.children || []) walk(child, visit)
}
function findAll(tree, predicate) {
  const out = []
  walk(tree, (node) => { if (predicate(node)) out.push(node) })
  return out
}
function findOne(tree, predicate) { return findAll(tree, predicate)[0] || null }
function textOf(node) {
  if (node === null || node === undefined) return ''
  if (typeof node === 'string' || typeof node === 'number') return String(node)
  if (Array.isArray(node)) return node.map(textOf).join('')
  if (typeof node === 'object') return (node.children || []).map(textOf).join('')
  return ''
}
const byField = (key) => (node) => node.props && node.props['data-dsh-watchdog-field'] === key
const byKind = (kind) => (node) => node.props && node.props['data-dsh-watchdog-kind'] === kind
const byData = (name) => (node) => node.props && node.props[name] !== undefined
async function click(app, predicate) {
  const node = findOne(app.render(), predicate)
  assert.ok(node, '找不到要点击的控件')
  node.props.onClick()
  await app.settle()
  return node
}
async function change(app, predicate, value) {
  const node = findOne(app.render(), predicate)
  assert.ok(node, '找不到要修改的控件')
  node.props.onChange({ target: value })
  await app.settle()
  return node
}
const lastPost = (app) => app.sim.calls.filter((call) => call.method === 'POST').pop() || null
const noticeText = (app) => {
  const node = findOne(app.render(), byData('data-dsh-watchdog-notice'))
  return node ? textOf(node) : ''
}

// ---------------- 测试框架 ----------------
let passed = 0
const failures = []
async function test(name, fn) {
  try {
    await fn()
    passed += 1
    console.log('PASS  ' + name)
  } catch (error) {
    failures.push({ name: name, error: error })
    console.log('FAIL  ' + name + ' :: ' + (error && error.stack ? error.stack : String(error)))
  }
}

// 加载 client.js（模块体只注册工厂）
let declaration = null
globalThis.window = {
  __ModuleLoader__: { load(decl) { declaration = decl } },
  matchMedia(query) { return { matches: false, media: query, addEventListener() {}, removeEventListener() {} } },
  focus() {},
}
if (typeof globalThis.Notification !== 'undefined') {
  try { Object.defineProperty(globalThis, 'Notification', { value: undefined, configurable: true }) } catch (error) {}
}
await import(CLIENT_URL)
assert.ok(declaration, '未调用 __ModuleLoader__.load')
assert.equal(declaration.id, 'dsh-session-watchdog')

// ---------------- 用例 ----------------
await test('导出形状不变 + settings.section 注册参数正确 + 徽标仍注册', async () => {
  const app = bootApp()
  assert.deepEqual(app.exportsObj.inject, ['uiSession'])
  assert.equal(typeof app.exportsObj.apply, 'function')
  assert.ok(app.settingsEntry, '未注册 settings.section')
  assert.equal(app.settingsEntry.config.id, 'dsh-session-watchdog-settings')
  assert.equal(app.settingsEntry.config.order, 510)
  assert.equal(typeof app.settingsEntry.config.label, 'function')
  assert.equal(app.settingsEntry.config.label(), '会话哨兵')
  assert.equal(typeof app.settingsEntry.Component, 'function')
  assert.ok(app.badgeEntry, '侧栏徽标注册丢失（回归）')
  app.dispose()
})

await test('重复 apply 幂等：只注册一次设置页', async () => {
  const app = bootApp()
  const before = app.slotEntries.length
  app.exportsObj.apply(app.ctx)
  assert.equal(app.slotEntries.length, before)
  app.dispose()
})

await test('进入面板 GET 配置并正确填表（秒/数组/kinds）', async () => {
  const app = bootApp()
  const tree = await app.mount()
  const all = textOf(tree)
  assert.ok(all.indexOf('A. 提醒开关') >= 0)
  assert.ok(all.indexOf('B. 监控内容规则') >= 0)
  assert.ok(all.indexOf('C. 监控范围') >= 0)
  assert.ok(all.indexOf('D. 阈值与预算') >= 0)
  assert.equal(findOne(tree, byField('stallTimeoutMs')).props.value, '600')
  assert.equal(findOne(tree, byField('toolStallTimeoutMs')).props.value, '120')
  assert.equal(findOne(tree, byField('resumeDelayMs')).props.value, '3')
  assert.equal(findOne(tree, byField('toastDurationMs')).props.value, '8')
  assert.equal(findOne(tree, byField('maxResumesPerSession')).props.value, '3')
  assert.equal(findOne(tree, byField('notifyGui')).props.checked, true)
  assert.equal(findOne(tree, byField('monitorSubagents')).props.checked, false)
  assert.equal(findOne(tree, byKind('error')).props.checked, true)
  assert.equal(findOne(tree, byKind('blocked')).props.checked, false)
  assert.ok(all.indexOf('D:\work') >= 0, '包含目录 chip 丢失')
  assert.ok(all.indexOf('上次保存') >= 0, '未显示上次保存时间')
  app.dispose()
})

await test('改动后出现保存按钮，POST body 只含改动字段', async () => {
  const app = bootApp()
  await app.mount()
  await change(app, byField('notifyGui'), { checked: false })
  const saveButton = findOne(app.render(), byData('data-dsh-watchdog-save'))
  assert.ok(saveButton, '改动后未出现保存按钮')
  saveButton.props.onClick()
  await app.settle()
  const post = lastPost(app)
  assert.ok(post, '没有发出 POST')
  assert.deepEqual(post.body, { patch: { notifyGui: false } })
  assert.ok(noticeText(app).indexOf('已保存并即时生效') >= 0, '成功提示缺失：' + noticeText(app))
  assert.equal(findOne(app.render(), byField('notifyGui')).props.checked, false)
  app.dispose()
})

await test('秒 → 毫秒换算：stallTimeoutMs 900 秒提交 900000', async () => {
  const app = bootApp()
  await app.mount()
  await change(app, byField('stallTimeoutMs'), { value: '900' })
  await click(app, byData('data-dsh-watchdog-save'))
  const post = lastPost(app)
  assert.deepEqual(post.body, { patch: { stallTimeoutMs: 900000 } })
  app.dispose()
})

await test('监控范围：输入 + 添加 → chip，保存只提交 excludeCwd', async () => {
  const app = bootApp()
  await app.mount()
  await change(app, byData('data-dsh-watchdog-input') && ((node) => node.props && node.props['data-dsh-watchdog-input'] === 'excludeCwd'), { value: 'D:\tmp' })
  await click(app, (node) => node.props && node.props['data-dsh-watchdog-add'] === 'excludeCwd')
  assert.ok(textOf(app.render()).indexOf('D:\tmp') >= 0, 'chip 未出现')
  await click(app, byData('data-dsh-watchdog-save'))
  assert.deepEqual(lastPost(app).body, { patch: { excludeCwd: ['D:\tmp'] } })
  app.dispose()
})

await test('监控范围：删除 chip 后保存提交空数组', async () => {
  const app = bootApp()
  await app.mount()
  const before = findOne(app.render(), (node) => node.props && node.props['data-dsh-watchdog-chip-remove'] === 'includeCwd')
  assert.ok(before, '初始 chip 不存在')
  await click(app, (node) => node.props && node.props['data-dsh-watchdog-chip-remove'] === 'includeCwd')
  await click(app, byData('data-dsh-watchdog-save'))
  assert.deepEqual(lastPost(app).body, { patch: { includeCwd: [] } })
  app.dispose()
})

await test('续跑原因多选：取消 max-tokens 只提交 resumeKinds', async () => {
  const app = bootApp()
  await app.mount()
  await change(app, byKind('max-tokens'), { checked: false })
  await click(app, byData('data-dsh-watchdog-save'))
  assert.deepEqual(lastPost(app).body, { patch: { resumeKinds: ['error', 'interrupted'] } })
  app.dispose()
})

await test('恢复默认：第一次点击只变文案，第二次才 POST reset', async () => {
  const app = bootApp()
  await app.mount()
  await change(app, byField('notifyOs'), { checked: false })
  const postCountBefore = app.sim.calls.filter((call) => call.method === 'POST').length
  await click(app, byData('data-dsh-watchdog-reset'))
  const resetButton = findOne(app.render(), byData('data-dsh-watchdog-reset'))
  assert.equal(textOf(resetButton), '再点一次确认')
  assert.equal(app.sim.calls.filter((call) => call.method === 'POST').length, postCountBefore, '第一次点击不应发请求')
  await click(app, byData('data-dsh-watchdog-reset'))
  assert.deepEqual(lastPost(app).body, { reset: true })
  assert.ok(noticeText(app).indexOf('已恢复默认并即时生效') >= 0, 'reset 成功提示缺失：' + noticeText(app))
  assert.equal(findOne(app.render(), byField('toastDurationMs')).props.value, '5', 'reset 后表单未刷新')
  app.dispose()
})

await test('非法数字：提示可读错误且不发 POST', async () => {
  const app = bootApp()
  await app.mount()
  await change(app, byField('globalBudget'), { value: '' })
  const before = app.sim.calls.filter((call) => call.method === 'POST').length
  await click(app, byData('data-dsh-watchdog-save'))
  assert.equal(app.sim.calls.filter((call) => call.method === 'POST').length, before)
  assert.ok(noticeText(app).indexOf('不小于 0 的数字') >= 0, '非法数字提示缺失：' + noticeText(app))
  app.dispose()
})

await test('异常：HTTP 400 / 网络失败 / 坏 JSON 都显示可读错误且不抛', async () => {
  const app = bootApp()
  await app.mount()
  app.sim.postMode = 'http'
  await change(app, byField('notifyGui'), { checked: false })
  await click(app, byData('data-dsh-watchdog-save'))
  assert.ok(noticeText(app).indexOf('保存失败') >= 0, 'HTTP 400 未提示：' + noticeText(app))
  app.sim.postMode = 'reject'
  await click(app, byData('data-dsh-watchdog-save'))
  assert.ok(noticeText(app).indexOf('网络请求异常') >= 0, '网络异常未提示：' + noticeText(app))
  app.sim.postMode = 'badjson'
  await click(app, byData('data-dsh-watchdog-save'))
  assert.ok(noticeText(app).indexOf('保存失败') >= 0, '坏 JSON 未提示：' + noticeText(app))
  app.dispose()
})

await test('异常：GET 失败显示错误页，重试可恢复', async () => {
  const app = bootApp({ getMode: 'reject' })
  await app.mount()
  const errorTree = textOf(app.render())
  assert.ok(errorTree.indexOf('读取失败') >= 0, 'GET 失败未显示错误：' + errorTree)
  const retry = findOne(app.render(), byData('data-dsh-watchdog-retry'))
  assert.ok(retry, '重试按钮缺失')
  app.sim.getMode = 'ok'
  retry.props.onClick()
  await app.settle()
  assert.equal(findOne(app.render(), byField('stallTimeoutMs')).props.value, '600', '重试后未填表')
  app.dispose()
})

await test('卸载后 pending 请求回来不再 setState', async () => {
  const app = bootApp()
  await app.mount()
  app.sim.postGate = true
  await change(app, byField('notifyGui'), { checked: false })
  const saveButton = findOne(app.render(), byData('data-dsh-watchdog-save'))
  saveButton.props.onClick()
  await app.settle()
  const rendersBefore = app.reactRuntime.rt.renders
  app.reactRuntime.unmountAll()
  app.sim.releasePost()
  await new Promise((resolve) => setTimeout(resolve, 20))
  await app.settle()
  assert.equal(app.reactRuntime.rt.renders, rendersBefore, '卸载后仍发生了重渲染')
  app.dispose()
})

await test('ctx.get 读不到 slots 时靠 ctx.inject 兜底注册设置页', async () => {
  const app = bootApp({ slotsVia: 'inject' })
  assert.ok(app.settingsEntry, 'ctx.inject 兜底未注册 settings.section')
  assert.equal(app.settingsEntry.config.name, 'settings.section')
  const tree = await app.mount()
  assert.equal(findOne(tree, byField('stallTimeoutMs')).props.value, '600')
  app.dispose()
})

await test('无 slots / 无 React 时不抛错且不影响 apply', async () => {
  const reactRuntime = createReactRuntime()
  const sim = createFetchSim()
  globalThis.fetch = sim.fetch
  const exportsObj = declaration.factory((name) => { throw new Error('unavailable: ' + name) })
  let threw = false
  const cleanups = []
  const ctx = {
    uiSession: {},
    get() { return undefined },
    inject() {},
    effect(fn) {
      const cleanup = fn()
      if (typeof cleanup === 'function') cleanups.push(cleanup)
    },
  }
  try {
    const returned = exportsObj.apply(ctx)
    if (returned !== undefined && typeof returned !== 'function') threw = true
  } catch (error) {
    threw = true
  }
  for (const cleanup of cleanups) {
    try { cleanup() } catch (error) {}
  }
  assert.equal(threw, false, '缺少 slots/react 时 apply 抛错')
})

// ---------------- 任务完成 / 提示音 / 续跑指令模式（新增字段） ----------------

await test('新字段填表：完成提醒 / 提示音 7 项 / 音量 / 续跑指令模式', async () => {
  const app = bootApp()
  const tree = await app.mount()
  assert.equal(findOne(tree, byField('notifyOnCompletion')).props.checked, true)
  const soundSelect = findOne(tree, byField('completionSound'))
  assert.equal(soundSelect.props.value, 'dingdong')
  assert.equal(soundSelect.children.length, 7, '提示音下拉应为 7 项（关闭 + 6 种）')
  assert.equal(textOf(soundSelect.children[0]), '关闭')
  assert.equal(textOf(soundSelect.children[1]), '叮咚（双音）')
  const modeSelect = findOne(tree, byField('resumePromptMode'))
  assert.equal(modeSelect.props.value, 'llm')
  assert.equal(modeSelect.children.length, 2, '续跑指令模式应为 2 项')
  assert.ok(textOf(modeSelect).indexOf('上下文摘录拼装') >= 0, '模式文案缺失')
  assert.equal(findOne(tree, byField('completionVolume')).props.value, '70')
  const all = textOf(tree)
  assert.ok(all.indexOf('消耗少量 token') >= 0, '续跑指令模式 hint 缺失')
  assert.ok(all.indexOf('自动回落') >= 0, '失败回落说明缺失')
  assert.ok(
    findOne(tree, (node) => node.props && node.props['data-dsh-watchdog-preview'] === 'completionSound'),
    '试听按钮缺失',
  )
  app.dispose()
})

await test('新字段保存：只提交改动项（提示音 / 续跑指令模式 / 完成提醒）', async () => {
  const app = bootApp()
  await app.mount()
  await change(app, byField('completionSound'), { value: 'pulse' })
  await click(app, byData('data-dsh-watchdog-save'))
  assert.deepEqual(lastPost(app).body, { patch: { completionSound: 'pulse' } })
  await change(app, byField('resumePromptMode'), { value: 'context' })
  await click(app, byData('data-dsh-watchdog-save'))
  assert.deepEqual(lastPost(app).body, { patch: { resumePromptMode: 'context' } })
  await change(app, byField('notifyOnCompletion'), { checked: false })
  await click(app, byData('data-dsh-watchdog-save'))
  assert.deepEqual(lastPost(app).body, { patch: { notifyOnCompletion: false } })
  app.dispose()
})

await test('音量钳制 0-100：150 提交 100、-20 提交 0、GET 越界显示 100', async () => {
  const high = bootApp()
  await high.mount()
  await change(high, byField('completionVolume'), { value: '150' })
  await click(high, byData('data-dsh-watchdog-save'))
  assert.deepEqual(lastPost(high).body, { patch: { completionVolume: 100 } })
  high.dispose()

  const low = bootApp()
  await low.mount()
  await change(low, byField('completionVolume'), { value: '-20' })
  await click(low, byData('data-dsh-watchdog-save'))
  assert.deepEqual(lastPost(low).body, { patch: { completionVolume: 0 } })
  low.dispose()

  const outOfRange = bootApp()
  outOfRange.sim.config.completionVolume = 150
  outOfRange.sim.config.completionSound = 'bogus'
  const tree = await outOfRange.mount()
  assert.equal(findOne(tree, byField('completionVolume')).props.value, '100', '越界音量未钳制显示')
  assert.equal(findOne(tree, byField('completionSound')).props.value, 'dingdong', '非法音色应回落默认')
  outOfRange.dispose()
})

await test('试听按钮：按当前表单音色与音量真实播放；关闭时不播；AudioContext 缺失静默', async () => {
  const app = bootApp()
  await app.mount()
  const preview = (node) => node.props && node.props['data-dsh-watchdog-preview'] === 'completionSound'
  const env = installFakeAudio()
  await click(app, preview)
  const diag = globalThis.window.__dshSessionWatchdog
  assert.ok(diag && typeof diag.sound === 'function', '排障入口 sound() 缺失')
  let snap = diag.sound()
  assert.equal(snap.plays, 1, '试听没有播放')
  assert.equal(snap.lastSound, 'dingdong')
  assert.equal(snap.lastVolume, 70)
  assert.ok(env.starts >= 2, '叮咚应至少创建 2 个振荡器')

  // 换音色 + 音量后再试听：必须用当前表单值
  await change(app, byField('completionSound'), { value: 'chime' })
  await change(app, byField('completionVolume'), { value: '35' })
  await click(app, preview)
  snap = diag.sound()
  assert.equal(snap.plays, 2)
  assert.equal(snap.lastSound, 'chime')
  assert.equal(snap.lastVolume, 35)

  // 关闭提示音后点试听：不播也不抛
  await change(app, byField('completionSound'), { value: 'none' })
  const playsBeforeNone = diag.sound().plays
  await click(app, preview)
  assert.equal(diag.sound().plays, playsBeforeNone, '关闭状态不应播放')

  app.dispose()

  // AudioContext 缺失：全新运行时静默失败、不抛错
  removeFakeAudio()
  const bare = bootApp()
  await bare.mount()
  const bareDiag = globalThis.window.__dshSessionWatchdog
  await assert.doesNotReject(async () => {
    await click(bare, preview)
  })
  assert.equal(bareDiag.sound().plays, 0, '缺少 AudioContext 不应计入播放')
  assert.equal(bareDiag.sound().available, false)
  bare.dispose()
})

// ---------------- 汇总 ----------------
if (failures.length > 0) {
  console.log('\n失败 ' + failures.length + ' 项：')
  for (const failure of failures) console.log('- ' + failure.name + ' :: ' + String(failure.error && failure.error.message))
  process.exitCode = 1
} else {
  console.log('\n全部通过：' + passed + ' / ' + passed)
}
await new Promise((resolve) => setTimeout(resolve, 30))
