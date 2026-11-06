/**
 * 集成测试：用假 ctx 装配真实插件入口 lib/index.js，模拟会话事件，
 * 验证「判定 → 提醒流 → 自动续跑」整条链路（不需要启动 DSH）。
 */
import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, writeFileSync, rmSync, readFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { apply } from '../lib/index.js'

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

function createHarness(overrides = {}) {
  const listeners = new Map()
  const routes = new Map()
  const disposers = []
  const prompted = []
  const stateDir = mkdtempSync(join(tmpdir(), 'watchdog-test-'))
  const services = {
    liveAgent: undefined,
    llm: undefined,
    webServer: {
      register({ path, handler }) {
        if (routes.has(path)) throw new Error('duplicate route: ' + path)
        routes.set(path, handler)
        return () => routes.delete(path)
      },
    },
    sessionController: {
      prompt: async (payload) => { prompted.push(payload) },
      resolveAgent: async () => ({ agent: { status: 'idle', followup() {} } }),
    },
    agents: {
      get: () => services.liveAgent,
      turnBoundaryOf: () => ({ openTurnStartSeq: null }),
    },
    sessions: { flush: async () => true },
    logger: { info() {}, warn() {}, error() {} },
  }
  const ctx = {
    logger: services.logger,
    get llm() { return services.llm },
    agents: services.agents,
    sessions: services.sessions,
    on(name, callback) {
      const list = listeners.get(name) || []
      list.push(callback)
      listeners.set(name, list)
      return () => listeners.set(name, (listeners.get(name) || []).filter((item) => item !== callback))
    },
    effect(setup) {
      const dispose = setup()
      if (typeof dispose === 'function') disposers.push(dispose)
      return dispose
    },
    inject(names, callback) {
      const scope = {
        webServer: names.includes('webServer') ? services.webServer : undefined,
        sessionController: names.includes('sessionController') ? services.sessionController : undefined,
        effect(setup) {
          const dispose = setup()
          if (typeof dispose === 'function') disposers.push(dispose)
        },
      }
      callback(scope)
    },
    sessionQuery: undefined,
  }
  const config = {
    enabled: true,
    autoResume: true,
    resumeDelayMs: 0,
    stateFile: join(stateDir, 'state.json'),
    ...overrides,
  }
  apply(ctx, config)
  return {
    ctx,
    prompted,
    stateDir,
    emit(name, ...args) {
      for (const callback of listeners.get(name) || []) callback(...args)
    },
    request(path, method = 'GET', body = null, headers = {}) {
      return new Promise((resolve) => {
        const pathname = path.split('?')[0]
        const handler = routes.get('/dsh-session-watchdog' + pathname)
        if (!handler) return resolve({ status: 404, body: null })
        const url = new URL('http://127.0.0.1:1' + path)
        const req = {
          method,
          url: '/dsh-session-watchdog/' + path + url.search,
          headers: { host: '127.0.0.1:1', ...headers },
          on(event, callback) {
            if (event === 'data' && body !== null) callback(Buffer.from(JSON.stringify(body)))
            if (event === 'end') callback()
          },
          destroy() {},
        }
        const res = {
          status: 0,
          headers: {},
          writeHead(status, headers2) { this.status = status; this.headers = headers2 || {} },
          end(payload) {
            let parsed = null
            try { parsed = payload ? JSON.parse(payload) : null } catch { parsed = payload }
            resolve({ status: this.status, body: parsed })
          },
        }
        Promise.resolve(handler(req, res)).catch(() => resolve({ status: 500, body: null }))
      })
    },
    async alerts(since = 0) {
      const response = await this.request('/alerts?since=' + since)
      return response.body
    },
    disposeRuntime() {
      for (const dispose of disposers.splice(0)) { try { dispose() } catch { /* noop */ } }
    },
    dispose() {
      this.disposeRuntime()
      try { rmSync(stateDir, { recursive: true, force: true }) } catch { /* noop */ }
    },
    setLiveAgent(agent) { services.liveAgent = agent },
    setLlm(llm) { services.llm = llm },
    session(origin = undefined) {
      return { id: 'session-test', header: { id: 'session-test', cwd: stateDir, origin } }
    },
  }
}

function turnEvent(type, data) {
  return { type, data, time: Date.now() }
}

test('异常结束 → 提醒流出现 error 并自动续跑（sessionController.prompt）', async () => {
  const h = createHarness()
  try {
    h.emit('session/event', h.session(), turnEvent('turn/start', { turn: 1 }))
    h.emit('session/event', h.session(), turnEvent('user/message', { id: 'u1', role: 'user', content: [{ type: 'text', text: '补完单测' }], source: { kind: 'user' } }))
    h.emit('session/event', h.session(), turnEvent('todo/write', { todos: [{ content: '补单测', status: 'pending' }] }))
    h.emit('session/event', h.session(), turnEvent('turn/end', { turn: 1, reason: { kind: 'error', error: { message: 'quota exceeded', code: 'QUOTA' } } }))
    await sleep(80)

    const feed = await h.alerts(0)
    assert.equal(feed.ok, true)
    assert.equal(feed.alerts.length, 1)
    const alert = feed.alerts[0]
    assert.equal(alert.kind, 'error')
    assert.equal(alert.stage, 'resumed')
    assert.equal(alert.title, '未命名会话')
    assert.match(alert.reason, /执行失败/)
    assert.equal(alert.instructionSource, 'context')
    assert.equal(alert.instructionError, 'llm-unavailable')

    assert.equal(h.prompted.length, 1)
    const text = h.prompted[0].content[0].text
    assert.match(text, /【会话交接记录】/)
    assert.match(text, /quota exceeded/)
    assert.match(text, /补单测/)
    assert.match(text, /补完单测/)
    assert.equal(h.prompted[0].mode, 'queue')
    assert.equal(h.prompted[0].sessionId, 'session-test')
  } finally { h.dispose() }
})

test('任务完成：默认也提醒，但绝不自动续跑', async () => {
  const h = createHarness()
  try {
    h.emit('session/event', h.session(), turnEvent('turn/start', { turn: 1 }))
    h.emit('session/event', h.session(), turnEvent('turn/end', { turn: 1, reason: { kind: 'completed' } }))
    await sleep(60)
    assert.equal(h.prompted.length, 0, '完成提醒不能触发续跑')
    const feed = await h.alerts(0)
    assert.equal(feed.alerts.length, 1)
    assert.equal(feed.alerts[0].kind, 'completed')
    assert.match(feed.alerts[0].reason, /正常完成/)
    assert.equal(feed.alerts[0].resumeAt, null)
  } finally { h.dispose() }
})

test('任务完成提醒可关闭（notifyOnCompletion=false）', async () => {
  const h = createHarness({ notifyOnCompletion: false })
  try {
    h.emit('session/event', h.session(), turnEvent('turn/start', { turn: 1 }))
    h.emit('session/event', h.session(), turnEvent('turn/end', { turn: 1, reason: { kind: 'completed' } }))
    await sleep(50)
    assert.equal(h.prompted.length, 0)
    assert.equal((await h.alerts(0)).alerts.length, 0)
  } finally { h.dispose() }
})

test('回归：turn/end 时 agent.status 仍为 running 也必须能自动续跑', async () => {
  const h = createHarness()
  try {
    // 模拟真实时序：turn/end 在 ReactLoopAgent.turn 的 finally 里同步 append，phase 尚未切回 idle
    h.setLiveAgent({ status: 'running', session: { id: 'session-test' }, followup() {} })
    const s = h.session()
    h.emit('session/event', s, turnEvent('turn/start', { turn: 1 }))
    h.emit('session/event', s, turnEvent('turn/end', { turn: 1, reason: { kind: 'error', error: { message: 'boom', code: 'UNKNOWN' } } }))
    await sleep(80)
    assert.equal(h.prompted.length, 1, 'agent.status=running 不应拦掉 turn/end 续跑')
    assert.equal((await h.alerts(0)).alerts[0].stage, 'resumed')
  } finally { h.dispose() }
})

test('幂等：同一 turn/end 重复送达只提醒+续跑一次', async () => {
  const h = createHarness()
  try {
    const s = h.session()
    const end = turnEvent('turn/end', { turn: 1, reason: { kind: 'error', error: { message: 'boom', code: 'UNKNOWN' } } })
    h.emit('session/event', s, turnEvent('turn/start', { turn: 1 }))
    h.emit('session/event', s, end)
    h.emit('session/event', s, end)
    await sleep(80)
    assert.equal(h.prompted.length, 1)
    const feed = await h.alerts(0)
    assert.equal(feed.alerts.length, 1)
  } finally { h.dispose() }
})

test('等待用户审批时只提醒不续跑', async () => {
  const h = createHarness()
  try {
    const s = h.session()
    h.emit('session/event', s, turnEvent('turn/start', { turn: 1 }))
    h.emit('session/event', s, turnEvent('approval/asked', { approvalId: 'ap1' }))
    h.emit('session/event', s, turnEvent('turn/end', { turn: 1, reason: { kind: 'error', error: { message: 'x', code: 'UNKNOWN' } } }))
    await sleep(60)
    assert.equal(h.prompted.length, 0)
    const feed = await h.alerts(0)
    assert.equal(feed.alerts.length, 1)
    assert.equal(feed.alerts[0].stage, 'detected')
  } finally { h.dispose() }
})

test('子代理会话默认不提醒（monitorSubagents=false）', async () => {
  const h = createHarness()
  try {
    const s = h.session('subagent')
    h.emit('session/event', s, turnEvent('turn/start', { turn: 1 }))
    h.emit('session/event', s, turnEvent('turn/end', { turn: 1, reason: { kind: 'error', error: { message: 'x', code: 'UNKNOWN' } } }))
    await sleep(50)
    assert.equal(h.prompted.length, 0)
    assert.equal((await h.alerts(0)).alerts.length, 0)
  } finally { h.dispose() }
})

test('路由：同源 dismiss 生效，跨源操作被拒', async () => {
  const h = createHarness({ autoResume: false })
  try {
    const s = h.session()
    h.emit('session/event', s, turnEvent('turn/start', { turn: 1 }))
    h.emit('session/event', s, turnEvent('turn/end', { turn: 1, reason: { kind: 'error', error: { message: 'x', code: 'UNKNOWN' } } }))
    await sleep(50)
    const feed = await h.alerts(0)
    const alert = feed.alerts[0]
    assert.equal(alert.stage, 'detected')
    assert.equal(h.prompted.length, 0)

    const cross = await h.request('/action', 'POST', { id: alert.id, action: 'dismiss' }, { origin: 'https://evil.example' })
    assert.equal(cross.status, 403)
    assert.equal((await h.alerts(0)).alerts[0].stage, 'detected')

    const ok = await h.request('/action', 'POST', { id: alert.id, action: 'dismiss' }, { origin: 'http://127.0.0.1:1' })
    assert.equal(ok.status, 200)
    assert.equal((await h.alerts(0)).alerts[0].stage, 'dismissed')
  } finally { h.dispose() }
})

test('路由：手动 resume 立即投递', async () => {
  const h = createHarness({ autoResume: false })
  try {
    const s = h.session()
    h.emit('session/event', s, turnEvent('turn/start', { turn: 1 }))
    h.emit('session/event', s, turnEvent('turn/end', { turn: 1, reason: { kind: 'interrupted' } }))
    await sleep(50)
    const alert = (await h.alerts(0)).alerts[0]
    assert.equal(alert.kind, 'interrupted')
    const response = await h.request('/action', 'POST', { id: alert.id, action: 'resume' })
    assert.equal(response.status, 200)
    await sleep(60)
    assert.equal(h.prompted.length, 1)
    assert.match(h.prompted[0].content[0].text, /进程中断/)
    const after = (await h.alerts(0)).alerts[0]
    assert.equal(after.stage, 'resumed')
    assert.equal(after.resumeCount, 1)
  } finally { h.dispose() }
})

test('用户手动继续（新 turn/start）会撤销待续跑', async () => {
  const h = createHarness({ resumeDelayMs: 200 })
  try {
    const s = h.session()
    h.emit('session/event', s, turnEvent('turn/start', { turn: 1 }))
    h.emit('session/event', s, turnEvent('turn/end', { turn: 1, reason: { kind: 'error', error: { message: 'x', code: 'UNKNOWN' } } }))
    await sleep(40)
    h.emit('session/event', s, turnEvent('turn/start', { turn: 2 }))
    await sleep(260)
    assert.equal(h.prompted.length, 0)
    const alert = (await h.alerts(0)).alerts[0]
    assert.equal(alert.stage, 'superseded')
  } finally { h.dispose() }
})

test('启动恢复：状态文件里未闭合 turn → 3 秒后补发 interrupted 提醒并续跑', async () => {
  const stateDir = mkdtempSync(join(tmpdir(), 'watchdog-restore-'))
  const stateFile = join(stateDir, 'state.json')
  writeFileSync(stateFile, JSON.stringify({
    version: 1,
    savedAt: Date.now() - 60000,
    detector: [{ sessionId: 'session-restore', title: '恢复测试', cwd: stateDir, openTurn: 2, lastEventAt: Date.now() - 60000, turnStartedAt: Date.now() - 60000 }],
    policy: { processed: [], sessions: [], globalResumes: [] },
  }), 'utf8')
  const h = createHarness({ stateFile })
  try {
    await sleep(3500)
    const feed = await h.alerts(0)
    assert.equal(feed.alerts.length, 1)
    assert.equal(feed.alerts[0].kind, 'interrupted')
    assert.equal(feed.alerts[0].sessionId, 'session-restore')
    assert.equal(h.prompted.length, 1)
  } finally {
    h.dispose()
    try { rmSync(stateDir, { recursive: true, force: true }) } catch { /* noop */ }
  }
})


test('设置接口：GET 返回全量配置与可编辑字段', async () => {
  const h = createHarness()
  try {
    const response = await h.request('/config')
    assert.equal(response.status, 200)
    assert.equal(response.body.ok, true)
    assert.equal(response.body.config.enabled, true)
    assert.equal(response.body.config.notifyOs, true)
    assert.ok(Array.isArray(response.body.editable))
    assert.ok(response.body.editable.includes('monitorSubagents'))
    assert.ok(Array.isArray(response.body.editable) && response.body.editable.length >= 20)
  } finally { h.dispose() }
})

test('设置接口：完成提醒与铃声/续跑指令模式可读写', async () => {
  const h = createHarness()
  try {
    const initial = await h.request('/config')
    assert.equal(initial.body.config.notifyOnCompletion, true)
    assert.equal(initial.body.config.completionSound, 'dingdong')
    assert.equal(initial.body.config.completionVolume, 70)
    assert.equal(initial.body.config.resumePromptMode, 'llm')
    assert.ok(initial.body.editable.includes('completionSound'))
    assert.ok(initial.body.editable.includes('resumePromptMode'))

    const saved = await h.request('/config', 'POST', { patch: { completionSound: 'tritone', completionVolume: 40, resumePromptMode: 'context', notifyOnCompletion: false } })
    assert.equal(saved.status, 200)
    assert.equal(saved.body.config.completionSound, 'tritone')
    assert.equal(saved.body.config.completionVolume, 40)
    assert.equal(saved.body.config.resumePromptMode, 'context')
    assert.equal(saved.body.config.notifyOnCompletion, false)

    const badSound = await h.request('/config', 'POST', { patch: { completionSound: 'not-a-sound' } })
    assert.equal(badSound.status, 200)
    assert.equal(badSound.body.config.completionSound, 'dingdong', '非法音色回落默认')

    const clamped = await h.request('/config', 'POST', { patch: { completionVolume: 999 } })
    assert.equal(clamped.body.config.completionVolume, 100)
  } finally { h.dispose() }
})

test('设置接口：保存后规则即时生效（子代理从忽略变监控）', async () => {
  const h = createHarness()
  try {
    const saved = await h.request('/config', 'POST', { patch: { monitorSubagents: true, notifyOs: false } })
    assert.equal(saved.status, 200)
    assert.equal(saved.body.config.monitorSubagents, true)
    assert.equal(saved.body.config.notifyOs, false)

    const s = h.session('subagent')
    h.emit('session/event', s, turnEvent('turn/start', { turn: 1 }))
    h.emit('session/event', s, turnEvent('turn/end', { turn: 1, reason: { kind: 'error', error: { message: 'x', code: 'UNKNOWN' } } }))
    await sleep(60)
    const feed = await h.alerts(0)
    assert.equal(feed.alerts.length, 1, '开启 monitorSubagents 后应产生提醒')
    // 配置文件确实落盘
    const configFile = join(h.stateDir, 'config.json')
    const raw = JSON.parse(readFileSync(configFile, 'utf8'))
    assert.equal(raw.overrides.monitorSubagents, true)
    assert.equal(raw.overrides.notifyOs, false)
  } finally { h.dispose() }
})

test('设置接口：数值夹取、拒绝空 patch、跨源拒绝、恢复默认', async () => {
  const h = createHarness()
  try {
    const clamped = await h.request('/config', 'POST', { patch: { stallTimeoutMs: 1 } })
    assert.equal(clamped.status, 200)
    assert.equal(clamped.body.config.stallTimeoutMs, 30000)

    const empty = await h.request('/config', 'POST', { patch: { unknownField: 1 } })
    assert.equal(empty.status, 400)

    const cross = await h.request('/config', 'POST', { patch: { notifyOs: false } }, { origin: 'https://evil.example' })
    assert.equal(cross.status, 403)

    const changed = await h.request('/config', 'POST', { patch: { notifyOs: false, autoResume: false } })
    assert.equal(changed.body.config.notifyOs, false)
    const reset = await h.request('/config', 'POST', { reset: true })
    assert.equal(reset.status, 200)
    assert.equal(reset.body.config.notifyOs, true)
    assert.equal(reset.body.config.autoResume, true)
  } finally { h.dispose() }
})

test('设置接口：配置持久化，重启后仍生效', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'watchdog-config-'))
  const file = join(dir, 'state.json')
  const first = createHarness({ stateFile: file })
  try {
    await first.request('/config', 'POST', { patch: { monitorSubagents: true, excludeCwd: ['F:\\tmp'] } })
  } finally {
    first.disposeRuntime()
  }
  const second = createHarness({ stateFile: file })
  try {
    const response = await second.request('/config')
    assert.equal(response.body.config.monitorSubagents, true, '重启后应加载持久化覆盖')
    assert.deepEqual(response.body.config.excludeCwd, ['F:\\tmp'])
  } finally {
    second.dispose()
    try { rmSync(dir, { recursive: true, force: true }) } catch { /* noop */ }
  }
})


test('续跑指令由对应会话的真实内容经模型生成（llm 模式）', async () => {
  const h = createHarness()
  try {
    const seen = []
    h.setLlm({
      async prepareCall(config) {
        return {
          config: { provider: config.provider, model: config.model },
          stream: async function* () {
            yield { type: 'text-delta', text: '刚才在改 orders.test.ts 时被限流中断，' }
            yield { type: 'text-delta', text: '继续把剩余两个用例补完并跑 npm test 验证。' }
          },
        }
      },
    })
    const s = h.session()
    h.emit('session/event', s, turnEvent('turn/start', { turn: 1 }))
    h.emit('session/event', s, turnEvent('request/context', { provider: 'deepseek', model: 'deepseek-chat' }))
    h.emit('session/event', s, turnEvent('user/message', { id: 'u1', role: 'user', content: [{ type: 'text', text: '把订单模块补完测试' }], source: { kind: 'user' } }))
    h.emit('session/event', s, turnEvent('assistant/message', { turn: 1, step: 1, message: { id: 'a1', role: 'assistant', content: [{ type: 'text', text: '已改完 orders.ts，正在补 orders.test.ts' }] } }))
    h.emit('session/event', s, turnEvent('turn/end', { turn: 1, reason: { kind: 'error', error: { message: 'rate limited', code: 'QUOTA' } } }))
    await sleep(120)
    assert.equal(h.prompted.length, 1)
    const text = h.prompted[0].content[0].text
    assert.equal(text, '刚才在改 orders.test.ts 时被限流中断，继续把剩余两个用例补完并跑 npm test 验证。')
    assert.doesNotMatch(text, /【会话交接记录】/, 'llm 模式不应使用固定模板')
    const alert = (await h.alerts(0)).alerts[0]
    assert.equal(alert.instructionSource, 'llm')
    assert.equal(alert.stage, 'resumed')
  } finally { h.dispose() }
})

test('续跑指令：模型失败时回落到真实上下文拼装（不丢内容）', async () => {
  const h = createHarness()
  try {
    h.setLlm({
      async prepareCall() {
        throw new Error('provider down')
      },
    })
    const s = h.session()
    h.emit('session/event', s, turnEvent('turn/start', { turn: 1 }))
    h.emit('session/event', s, turnEvent('request/context', { provider: 'deepseek', model: 'deepseek-chat' }))
    h.emit('session/event', s, turnEvent('user/message', { id: 'u1', role: 'user', content: [{ type: 'text', text: '重构支付回调' }], source: { kind: 'user' } }))
    h.emit('session/event', s, turnEvent('turn/end', { turn: 1, reason: { kind: 'error', error: { message: 'boom', code: 'UNKNOWN' } } }))
    await sleep(120)
    assert.equal(h.prompted.length, 1)
    const text = h.prompted[0].content[0].text
    assert.match(text, /【会话交接记录】/)
    assert.match(text, /重构支付回调/)
    const alert = (await h.alerts(0)).alerts[0]
    assert.equal(alert.instructionSource, 'context')
    assert.match(alert.instructionError, /provider down/)
  } finally { h.dispose() }
})
