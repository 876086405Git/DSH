/**
 * 会话哨兵 · 任务完成提醒 + 提示音 · 假环境自测
 *
 * 覆盖：
 *   1. alert.kind === 'completed' → 卡片「任务完成」+ 标题 + 摘要，按钮只有「忽略」（无续跑）；
 *   2. 完成提醒按配置播放一次提示音（同一条 alert id 只响一次，stage 推进不重播）；
 *   3. completionSound === 'none' / notifyOnCompletion === false / 音量 0 不播；
 *   4. AudioContext 缺失 / 被自动播放策略挂起时静默失败，卡片照常显示、进程不抛错；
 *   5. 首次用户交互（pointerdown/keydown 各一次）解锁 AudioContext 且只解锁一次；
 *   6. 侧栏徽标用绿色完成态（沿用 30s 自清逻辑，这里只验等级与文案）。
 *
 * 说明：这是假环境（迷你 DOM + 假 AudioContext + 假宿主路由），真机行为仍需重启桌面版验证。
 */
import assert from 'node:assert/strict'
import { pathToFileURL, fileURLToPath } from 'node:url'

const PLUGIN_DIR = fileURLToPath(new URL('..', import.meta.url)).replace(/[\\/]$/, '')
const CLIENT_URL = pathToFileURL(PLUGIN_DIR + '/lib/client.js').href

// ---------------- 迷你假 DOM（只实现 client.js 用到的部分） ----------------
function createNode(tagName) {
  const node = {
    tagName: String(tagName || 'div').toUpperCase(),
    style: {},
    attributes: {},
    children: [],
    parentNode: null,
    textContent: '',
    listeners: {},
    setAttribute(name, value) {
      node.attributes[String(name)] = String(value)
    },
    getAttribute(name) {
      return Object.prototype.hasOwnProperty.call(node.attributes, name) ? node.attributes[name] : null
    },
    appendChild(child) {
      child.parentNode = node
      node.children.push(child)
      return child
    },
    removeChild(child) {
      const index = node.children.indexOf(child)
      if (index >= 0) node.children.splice(index, 1)
      child.parentNode = null
      return child
    },
    addEventListener(type, fn) {
      const key = String(type)
      if (!node.listeners[key]) node.listeners[key] = []
      node.listeners[key].push(fn)
    },
    removeEventListener(type, fn) {
      const list = node.listeners[String(type)]
      if (!list) return
      const index = list.indexOf(fn)
      if (index >= 0) list.splice(index, 1)
    },
  }
  return node
}

function createFakeDocument() {
  const body = createNode('body')
  const doc = {
    hidden: false,
    body: body,
    documentElement: body,
    listeners: {},
    createElement(tag) {
      return createNode(tag)
    },
    addEventListener(type, fn) {
      const key = String(type)
      if (!doc.listeners[key]) doc.listeners[key] = []
      doc.listeners[key].push(fn)
    },
    removeEventListener(type, fn) {
      const list = doc.listeners[String(type)]
      if (!list) return
      const index = list.indexOf(fn)
      if (index >= 0) list.splice(index, 1)
    },
  }
  return doc
}

function textOf(node) {
  if (!node || typeof node !== 'object') return ''
  const own = typeof node.textContent === 'string' ? node.textContent : ''
  if (own !== '') return own
  return (node.children || []).map(textOf).join('')
}

function walk(node, visit) {
  if (!node || typeof node !== 'object') return
  visit(node)
  for (const child of node.children || []) walk(child, visit)
}

function collectButtons(node) {
  const out = []
  walk(node, (item) => {
    if (item && item.tagName === 'BUTTON') out.push(item)
  })
  return out
}

function findCards(doc) {
  const overlay = (doc.body.children || []).find(
    (child) => child.attributes && child.attributes['data-dsh-watchdog-overlay'] === '1',
  )
  if (!overlay) return []
  return (overlay.children || []).filter(
    (child) => child.attributes && child.attributes['data-dsh-watchdog-card'] === '1',
  )
}

// ---------------- 假 AudioContext（统计振荡器与上下文状态） ----------------
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
      start() {
        env.starts += 1
      },
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
  try {
    delete globalThis.window.AudioContext
  } catch (error) {}
  try {
    delete globalThis.window.webkitAudioContext
  } catch (error) {}
}

// ---------------- 假宿主（config / alerts / action 三条路由） ----------------
function createHost(options = {}) {
  const host = {
    config: Object.assign(
      {
        enabled: true,
        notifyGui: true,
        notifyOs: true,
        toastDurationMs: 8000,
        notifyOnCompletion: true,
        completionSound: 'dingdong',
        completionVolume: 70,
        resumePromptMode: 'llm',
      },
      options.config || {},
    ),
    queue: [],
    cursor: 0,
    configCalls: 0,
    alertCalls: 0,
    actionCalls: [],
  }
  host.push = (alert) => {
    host.queue.push(alert)
    return alert
  }
  host.fetch = (url, init) => {
    const target = String(url)
    if (target.indexOf('/config') >= 0) {
      host.configCalls += 1
      const body = {
        ok: true,
        version: 1,
        editable: Object.keys(host.config),
        config: Object.assign({}, host.config),
        defaults: Object.assign({}, host.config),
        updatedAt: 0,
      }
      return Promise.resolve({ ok: true, status: 200, json: () => Promise.resolve(body) })
    }
    if (target.indexOf('/alerts') >= 0) {
      host.alertCalls += 1
      const alerts = host.queue.splice(0, host.queue.length)
      if (alerts.length > 0) host.cursor += alerts.length
      return Promise.resolve({
        ok: true,
        status: 200,
        json: () => Promise.resolve({ ok: true, cursor: host.cursor, alerts: alerts }),
      })
    }
    if (target.indexOf('/action') >= 0) {
      let body = null
      try {
        body = init && init.body ? JSON.parse(init.body) : null
      } catch (error) {
        body = null
      }
      host.actionCalls.push(body)
      return Promise.resolve({ ok: true, status: 200, json: () => Promise.resolve({ ok: true }) })
    }
    return Promise.resolve({ ok: false, status: 404, json: () => Promise.resolve({ ok: false }) })
  }
  return host
}

// ---------------- 加载 client.js（模块体只注册工厂） ----------------
let declaration = null
const windowListeners = {}
globalThis.window = {
  __ModuleLoader__: {
    load(decl) {
      declaration = decl
    },
  },
  addEventListener(type, fn) {
    const key = String(type)
    if (!windowListeners[key]) windowListeners[key] = []
    windowListeners[key].push(fn)
  },
  removeEventListener(type, fn) {
    const list = windowListeners[String(type)]
    if (!list) return
    const index = list.indexOf(fn)
    if (index >= 0) list.splice(index, 1)
  },
  focus() {},
}
function dispatchWindow(type) {
  const list = windowListeners[String(type)] || []
  for (const fn of list.slice()) {
    try {
      fn({ type: type })
    } catch (error) {
      /* 事件处理器不应抛错，抛了也算失败由断言兜底 */
    }
  }
}
if (typeof globalThis.Notification !== 'undefined') {
  try {
    Object.defineProperty(globalThis, 'Notification', { value: undefined, configurable: true })
  } catch (error) {}
}
await import(CLIENT_URL)
assert.ok(declaration, '未调用 __ModuleLoader__.load')
assert.equal(declaration.id, 'dsh-session-watchdog')

// ---------------- 启动一份运行时（无 slots / 无 React：只测提醒卡片与音频） ----------------
function boot(options = {}) {
  const doc = createFakeDocument()
  const host = createHost(options)
  globalThis.document = doc
  globalThis.fetch = host.fetch
  const exportsObj = declaration.factory((name) => {
    throw new Error('module unavailable: ' + name)
  })
  const effects = []
  const ctx = {
    uiSession: {},
    get(name) {
      if (name === 'uiSession') return ctx.uiSession
      if (name === 'sessions') return options.sessions || null
      return undefined
    },
    inject() {},
    effect(fn) {
      const cleanup = fn()
      if (typeof cleanup === 'function') effects.push(cleanup)
    },
  }
  exportsObj.apply(ctx)
  return {
    doc: doc,
    host: host,
    exportsObj: exportsObj,
    diagnostics: () => globalThis.window.__dshSessionWatchdog,
    dispose() {
      for (const cleanup of effects.splice(0)) {
        try {
          cleanup()
        } catch (error) {}
      }
    },
  }
}

// ---------------- 等待工具 ----------------
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))
async function until(predicate, timeoutMs = 1500) {
  const started = Date.now()
  while (Date.now() - started < timeoutMs) {
    let ok = false
    try {
      ok = predicate() === true
    } catch (error) {
      ok = false
    }
    if (ok) return true
    await sleep(5)
  }
  return false
}
async function waitForCard(app) {
  const ok = await until(() => findCards(app.doc).length > 0)
  assert.ok(ok, '提醒卡片没有出现')
  return findCards(app.doc)
}

let completedSeq = 0
function completionAlert(overrides = {}) {
  completedSeq += 1
  return Object.assign(
    {
      id: 'session-a#' + completedSeq + '#completed',
      sessionId: 'session-a',
      title: '订单模块重构',
      kind: 'completed',
      stage: 'detected',
      reason: '正常完成',
      turn: 6,
      at: Date.now(),
      summary: '已拆分 service 与 repo 并补齐单测',
    },
    overrides,
  )
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

// ---------------- 用例 ----------------

await test('完成提醒卡片：文案「任务完成」+ 标题 + 摘要，按钮只有「忽略」', async () => {
  const env = installFakeAudio()
  const app = boot()
  try {
    app.host.push(completionAlert())
    const cards = await waitForCard(app)
    assert.equal(cards.length, 1, '应只弹 1 张卡片')
    const text = textOf(cards[0])
    assert.ok(text.indexOf('任务完成') >= 0, '卡片缺少「任务完成」文案：' + text)
    assert.ok(text.indexOf('订单模块重构') >= 0, '卡片缺少会话标题')
    assert.ok(text.indexOf('已拆分 service 与 repo 并补齐单测') >= 0, '卡片缺少摘要')
    const buttons = collectButtons(cards[0])
    assert.equal(buttons.length, 1, '完成提醒只应有 1 个按钮，实际：' + buttons.map((b) => b.textContent).join('/'))
    assert.equal(buttons[0].textContent, '忽略')
    assert.ok(text.indexOf('续跑') < 0, '完成提醒不应出现「续跑」按钮')
    assert.equal(cards[0].attributes['data-dsh-watchdog-card-kind'], 'completed')
    assert.ok(env.starts >= 2, '叮咚音应至少创建 2 个振荡器')
  } finally {
    app.dispose()
    removeFakeAudio()
  }
})

await test('完成提醒播放一次提示音：plays=1 / 音色与音量来自配置 / 徽标绿色完成态', async () => {
  const env = installFakeAudio()
  const app = boot({ config: { completionVolume: 35 } })
  try {
    app.host.push(completionAlert())
    await waitForCard(app)
    const diag = app.diagnostics()
    assert.ok(diag && typeof diag.sound === 'function', '排障入口 sound() 缺失')
    const snap = diag.sound()
    assert.equal(snap.plays, 1, '完成提醒应播放 1 次')
    assert.equal(snap.lastSound, 'dingdong')
    assert.equal(snap.lastVolume, 35, '音量应来自配置')
    assert.ok(env.starts >= 2)
    const badges = diag.badges()
    assert.equal(badges.length, 1, '应只有 1 个会话徽标')
    assert.equal(badges[0][1].level, 'resumed', '完成提醒应使用绿色完成态')
    assert.ok(String(badges[0][1].label).indexOf('任务已完成') >= 0, '徽标文案不对：' + badges[0][1].label)
  } finally {
    app.dispose()
    removeFakeAudio()
  }
})

await test('同一条 alert id 只响一次：stage 推进不重播、不重复弹卡片', async () => {
  const env = installFakeAudio()
  const app = boot()
  try {
    const alert = completionAlert()
    app.host.push(alert)
    await waitForCard(app)
    const diag = app.diagnostics()
    assert.equal(diag.sound().plays, 1)
    const startsAfterFirst = env.starts
    // 宿主推进同一条 alert 的 stage：再拉一次
    app.host.push(Object.assign({}, alert, { stage: 'resumed' }))
    diag.poll()
    const fetched = await until(() => app.host.alertCalls >= 2)
    assert.ok(fetched, '第二次拉取没有发生')
    await sleep(40)
    assert.equal(diag.sound().plays, 1, '同一 alert id 不应重播')
    assert.equal(env.starts, startsAfterFirst, '不应再创建振荡器')
    assert.equal(findCards(app.doc).length, 1, '同一 alert 不应重复弹卡片')
  } finally {
    app.dispose()
    removeFakeAudio()
  }
})

await test('completionSound=none：完成提醒照常弹卡片但不播放', async () => {
  const env = installFakeAudio()
  const app = boot({ config: { completionSound: 'none' } })
  try {
    app.host.push(completionAlert())
    await waitForCard(app)
    const snap = app.diagnostics().sound()
    assert.equal(snap.plays, 0, '关闭提示音后不应播放')
    assert.equal(env.starts, 0, '不应创建振荡器')
    assert.equal(findCards(app.doc).length, 1)
  } finally {
    app.dispose()
    removeFakeAudio()
  }
})

await test('notifyOnCompletion=false：完成提醒不播放提示音', async () => {
  const env = installFakeAudio()
  const app = boot({ config: { notifyOnCompletion: false } })
  try {
    app.host.push(completionAlert())
    await waitForCard(app)
    assert.equal(app.diagnostics().sound().plays, 0)
    assert.equal(env.starts, 0)
  } finally {
    app.dispose()
    removeFakeAudio()
  }
})

await test('completionVolume=0：静音不播放（也不抛错）', async () => {
  const env = installFakeAudio()
  const app = boot({ config: { completionVolume: 0 } })
  try {
    app.host.push(completionAlert())
    await waitForCard(app)
    const snap = app.diagnostics().sound()
    assert.equal(snap.plays, 0, '音量 0 不应播放')
    assert.equal(env.starts, 0)
    assert.equal(snap.lastVolume, 0)
  } finally {
    app.dispose()
    removeFakeAudio()
  }
})

await test('AudioContext 缺失：完成提醒照常弹卡片，播放静默失败且不抛错', async () => {
  removeFakeAudio()
  const app = boot()
  try {
    app.host.push(completionAlert())
    const cards = await waitForCard(app)
    assert.equal(cards.length, 1, '卡片应照常显示')
    assert.equal(collectButtons(cards[0]).length, 1)
    const snap = app.diagnostics().sound()
    assert.equal(snap.available, false, '环境应报告无音频能力')
    assert.equal(snap.plays, 0, '缺少 AudioContext 不应计入播放')
  } finally {
    app.dispose()
  }
})

await test('自动播放策略挂起：静默返回 false，卡片不受影响', async () => {
  const env = installFakeAudio('suspended')
  const app = boot()
  try {
    app.host.push(completionAlert())
    await waitForCard(app)
    const snap = app.diagnostics().sound()
    assert.equal(snap.plays, 0, '挂起的上下文不应计入播放')
    assert.equal(env.starts, 0, '挂起时不应排振荡器')
    assert.ok(String(snap.lastError).indexOf('未就绪') >= 0, '应记录挂起原因：' + snap.lastError)
  } finally {
    app.dispose()
    removeFakeAudio()
  }
})

await test('首次用户交互解锁音频：pointerdown/keydown 只解锁一次', async () => {
  const env = installFakeAudio('suspended')
  const app = boot()
  try {
    assert.equal(env.contexts.length, 0, '未交互前不应创建 AudioContext')
    dispatchWindow('pointerdown')
    assert.equal(env.contexts.length, 1, 'pointerdown 应创建并解锁 AudioContext')
    assert.ok(env.contexts[0].resumeCalls >= 1, '挂起状态应调用 resume')
    dispatchWindow('keydown')
    assert.equal(env.contexts.length, 1, '监听应已摘除，不应重复创建')
    app.diagnostics().poll()
    await sleep(20)
  } finally {
    app.dispose()
    removeFakeAudio()
  }
})

await test('回归：异常提醒仍有「续跑」+「忽略」，且不播完成提示音', async () => {
  const env = installFakeAudio()
  const app = boot()
  try {
    app.host.push({
      id: 'session-b#9#error',
      sessionId: 'session-b',
      title: '构建修复',
      kind: 'error',
      stage: 'detected',
      reason: '运行出错',
      error: 'TypeError: x is undefined',
      turn: 9,
      at: Date.now(),
      summary: '修复 vite 构建报错',
    })
    const cards = await waitForCard(app)
    const buttons = collectButtons(cards[0])
    assert.deepEqual(buttons.map((button) => button.textContent), ['续跑', '忽略'])
    assert.equal(app.diagnostics().sound().plays, 0, '异常提醒不应播完成提示音')
    assert.equal(env.starts, 0)
    const badges = app.diagnostics().badges()
    assert.equal(badges.length, 1)
    assert.equal(badges[0][1].level, 'error')
  } finally {
    app.dispose()
    removeFakeAudio()
  }
})

await test('完成提醒「忽略」：POST action=dismiss 后卡片移除、徽标清除', async () => {
  const env = installFakeAudio()
  const app = boot()
  try {
    app.host.push(completionAlert())
    const cards = await waitForCard(app)
    const dismiss = collectButtons(cards[0])[0]
    dismiss.listeners.click[0]({ preventDefault() {}, stopPropagation() {} })
    const gone = await until(() => findCards(app.doc).length === 0)
    assert.ok(gone, '点「忽略」后卡片应移除')
    assert.equal(app.host.actionCalls.length, 1, '应发出 1 次 action 请求')
    assert.equal(app.host.actionCalls[0].action, 'dismiss')
    assert.equal(app.diagnostics().badges().length, 0, '忽略后徽标应清除')
    assert.equal(env.starts >= 2, true)
  } finally {
    app.dispose()
    removeFakeAudio()
  }
})

await test('完成卡片固定在右下角（bottom:12px，且不再用 top 定位）', async () => {
  const env = installFakeAudio()
  const app = boot()
  try {
    app.host.push(completionAlert())
    const cards = await waitForCard(app)
    const overlay = (app.doc.body.children || []).find(
      (child) => child.attributes && child.attributes['data-dsh-watchdog-overlay'] === '1',
    )
    assert.ok(overlay, '浮层应存在')
    assert.equal(overlay.style.bottom, '12px', '浮层应贴右下角')
    assert.ok(!overlay.style.top, '不应再用 top 定位')
    assert.equal(overlay.style.right, '12px')
    assert.equal(overlay.style.flexDirection, 'column-reverse', '卡片应从右下角向上堆叠')
    assert.equal(overlay.style.zIndex, '2147483647', '卡片应置于最顶层，避免被其他插件浮层遮挡')
    assert.equal(cards.length, 1)
  } finally {
    app.dispose()
    removeFakeAudio()
  }
})

await test('完成卡片标题与会话列表一致（宿主 title 为空或旧占位时取列表 displayTitle）', async () => {
  const env = installFakeAudio()
  const app = boot({
    sessions: {
      list: {
        getSnapshot: () => ({ byId: { 'session-a': { displayTitle: '订单模块重构-真实列表名' } } }),
      },
    },
  })
  try {
    app.host.push(completionAlert({ title: '' }))
    let cards = await waitForCard(app)
    assert.match(textOf(cards[0]), /订单模块重构-真实列表名/, '空标题应回落到列表 displayTitle')
    app.host.push(completionAlert({ title: '未命名会话' }))
    const ok = await until(() => findCards(app.doc).length >= 1)
    assert.ok(ok)
    cards = findCards(app.doc)
    assert.match(textOf(cards[cards.length - 1]), /订单模块重构-真实列表名/, '旧占位「未命名会话」也必须被列表名替换')
    assert.doesNotMatch(textOf(cards[cards.length - 1]), /未命名/)
  } finally {
    app.dispose()
    removeFakeAudio()
  }
})

// ---------------- 汇总 ----------------
if (failures.length > 0) {
  console.log('\n失败 ' + failures.length + ' 项：')
  for (const failure of failures) console.log('- ' + failure.name + ' :: ' + String(failure.error && failure.error.message))
  process.exitCode = 1
} else {
  console.log('\n全部通过：' + passed + ' / ' + passed)
}
