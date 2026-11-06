/**
 * 会话哨兵（dsh-session-watchdog）—— 宿主半侧入口。
 *
 * 职责：
 *   1. 订阅 ctx.on('session/event')，用 detector 判定每个 turn 是否异常停止；
 *   2. 用 policy 决定「提醒 / 自动续跑」，并把提醒推进 notify 的事件流；
 *   3. 用 context 从事件流里提取断点上下文，生成模板化续跑指令；
 *   4. 用 runner 调 sessionController.prompt / agent.followup 真正续跑；
 *   5. 状态落盘（store），宿主重启后恢复未完成的 turn 并补发中断提醒；
 *   6. 通过 webServer 路由给浏览器半侧提供提醒流。
 *
 * 设计约束：第三方插件不能 import @deepseek-ai/* 核心包，全部能力从 ctx 取；
 * 所有监听器整体 try/catch（Cordis emit 抛错会饿死后续监听器）。
 */
import { existsSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'
import { createDetector } from './detector.js'
import { createPolicy, normalizeConfig } from './policy.js'
import { createConfigStore } from './config-store.js'
import { extractContext, extractConversation, KIND_LABELS } from './context.js'
import { generateResumeInstruction, buildInstructionSummary } from './resume-instruction.js'
import { createFeed, registerRoutes, publicConfig } from './notify.js'
import { createRunner } from './runner.js'
import { createStore } from './store.js'

export const name = 'session-watchdog'
export const inject = []

const STALL_CHECK_INTERVAL_MS = 15000
const STARTUP_DELAY_MS = 3000
const STARTUP_SCAN_DELAY_MS = 8000
const STARTUP_SCAN_WINDOW_MS = 24 * 60 * 60 * 1000
const STARTUP_MIN_AGE_MS = 10 * 1000

/** 安全读取可选宿主服务：Cordis 的 ctx.get(name) 不需要 inject；直接读 ctx.xxx 会抛 "cannot get property ... without inject"。 */
function readService(ctx, name) {
  try {
    if (!ctx) return undefined
    if (typeof ctx.get === 'function') {
      const viaGet = ctx.get(name)
      if (viaGet !== undefined && viaGet !== null) return viaGet
    }
    return ctx[name]
  } catch {
    return undefined
  }
}

function makeLogger(ctx) {
  const fallback = { info() {}, warn() {}, error() {} }
  try {
    const rawLogger = readService(ctx, 'logger')
    const candidate = typeof rawLogger === 'function' ? rawLogger('session-watchdog') : rawLogger
    if (!candidate || typeof candidate !== 'object') return fallback
    return {
      info: (message) => { try { candidate.info?.(String(message)) } catch { /* noop */ } },
      warn: (message) => { try { candidate.warn?.(String(message)) } catch { /* noop */ } },
      error: (message) => { try { candidate.error?.(String(message)) } catch { /* noop */ } },
    }
  } catch {
    return fallback
  }
}

/** 把「某会话有新事件」同步给待续跑队列：用户已经手动继续，就撤销自动续跑。 */
function supersedePending(pending, feed, sessionId, afterAt) {
  for (const [alertId, entry] of pending) {
    if (entry.decision.sessionId !== sessionId) continue
    if (entry.decision.at >= afterAt) continue
    try { clearTimeout(entry.timer) } catch { /* noop */ }
    pending.delete(alertId)
    feed.update(alertId, { stage: 'superseded' })
  }
}

export function apply(ctx, rawConfig) {
  if (!ctx || typeof ctx.on !== 'function') return
  const logger = makeLogger(ctx)
  const stateFile = typeof rawConfig?.stateFile === 'string' && rawConfig.stateFile
    ? rawConfig.stateFile
    : join(homedir(), '.dsh', 'session-watchdog', 'state.json')
  // 运行时配置：settings 面板写 config.json，优先级高于 cordis.patch.yml 的静态 config
  const configStore = createConfigStore({
    filePath: join(dirname(stateFile), 'config.json'),
    base: rawConfig && typeof rawConfig === 'object' ? rawConfig : {},
    logger,
  })
  const config = configStore.get()
  if (!config.enabled) return

  const detector = createDetector({ stallTimeoutMs: config.stallTimeoutMs, toolStallTimeoutMs: config.toolStallTimeoutMs })
  const policy = createPolicy(config)
  const feed = createFeed()
  const store = createStore(stateFile, { logger })
  const runner = createRunner({ ctx, logger })
  /** alertId → { timer, decision, text } */
  const pending = new Map()
  let disposed = false

  function persist(immediate) {
    if (disposed) return
    const state = { version: 1, savedAt: Date.now(), detector: detector.persistable(), policy: policy.snapshot() }
    if (immediate) store.flush(state)
    else store.schedule(state)
  }

  /** 设置面板保存后：原地更新配置对象（policy 持同一引用）、换心跳阈值、落盘。 */
  function applyLiveConfig(next) {
    try {
      if (next && typeof next === 'object') Object.assign(config, next)
      detector.setOptions({ stallTimeoutMs: config.stallTimeoutMs, toolStallTimeoutMs: config.toolStallTimeoutMs })
      persist(true)
      logger.info('session-watchdog: 配置已更新（autoResume=' + config.autoResume + ', notifyOs=' + config.notifyOs + '）')
    } catch (error) {
      logger.warn('session-watchdog: 应用配置失败 ' + String(error && error.message ? error.message : error))
    }
  }

  function cwdUsable(cwd) {
    if (typeof cwd !== 'string' || cwd === '') return true
    try { return existsSync(cwd) } catch { return false }
  }

  /** 对一条判定执行策略：提醒 +（可选）排期续跑。 */
  function handleDecision(decision) {
    if (disposed || !decision || typeof decision.sessionId !== 'string') return
    const sessionId = decision.sessionId
    const state = detector.get(sessionId)
    const liveAgent = runner.liveAgent(sessionId)

    // 启动恢复的二次校验：会话其实还活着/仍有未闭合 turn 时不误判为中断
    if (decision.source === 'startup' || decision.source === 'startup-scan') {
      const bornAt = Number.isFinite(decision.savedAt) ? decision.savedAt : decision.at
      if (Date.now() - bornAt < STARTUP_MIN_AGE_MS) return
      if (liveAgent !== undefined && liveAgent !== null) {
        if (liveAgent.status === 'running') return
        try {
          const agents = readService(ctx, 'agents')
          const boundary = agents?.turnBoundaryOf?.(liveAgent.session)
          if (boundary && boundary.openTurnStartSeq !== null) return
        } catch { /* 读不到投影就保守跳过 */ }
      }
    }

    const verdict = policy.decide(decision, {
      origin: decision.origin || state?.origin,
      awaitingUser: decision.awaitingUser === true || (state?.pendingApprovals || 0) > 0,
      cwdOk: cwdUsable(decision.cwd || state?.cwd),
      agentStatus: liveAgent && liveAgent.status ? liveAgent.status : undefined,
    })
    if (!verdict.notify) {
      if (verdict.resume) scheduleResume(decision)
      persist()
      return
    }

    const events = state ? state.events : []
    const context = extractContext({ events, title: decision.title, cwd: decision.cwd })
    const conversation = extractConversation(events, { maxMessages: 10, maxChars: 2400 })
    const summary = buildInstructionSummary(context, decision)
    const alert = feed.push({
      id: decision.id,
      sessionId,
      title: decision.title || context.title || '',
      kind: decision.kind,
      stage: 'detected',
      reason: KIND_LABELS[decision.kind] || decision.kind || '异常停止',
      error: decision.error && decision.error.message ? decision.error.message : null,
      turn: decision.turn,
      at: decision.at,
      resumeAt: verdict.resume ? verdict.resumeAt : null,
      resumeCount: 0,
      summary,
    })
    if (alert) {
      logger.info('session-watchdog: 检出 ' + decision.kind + ' @ ' + sessionId + ' → ' + (verdict.resume ? '提醒+续跑' : '仅提醒(' + verdict.reason + ')'))
      if (verdict.resume) scheduleResume(decision, alert.id)
    }
    persist()
  }

  /**
   * 崩溃恢复补上下文：宿主重启后 detector 只有状态快照（没有事件流），
   * 导致续跑指令出现"（没有可用的对话记录）"。这里用 sessionQuery 读回真实会话日志，
   * 补进 detector 的事件缓存 / provider / model / 标题，让续跑指令仍然承接上下文。
   */
  async function hydrateStartupDecision(decision) {
    if (!decision || typeof decision.sessionId !== 'string') return
    const state = detector.get(decision.sessionId)
    if (!state) return
    const query = readService(ctx, 'sessionQuery')
    if (!query || typeof query.readSession !== 'function') return
    try {
      const read = await query.readSession(decision.sessionId)
      const events = read && Array.isArray(read.events) ? read.events : []
      if (events.length === 0) return
      const tail = []
      // 标题只认最新一次 session/title，且可能在 400 条窗口之外 —— 先全量扫一遍
      for (const event of events) {
        if (!event || event.type !== 'session/title') continue
        const data = event.data && typeof event.data === 'object' ? event.data : {}
        if (typeof data.title === 'string' && data.title) state.title = data.title
      }
      for (const event of events.slice(-400)) {
        if (!event || typeof event.type !== 'string') continue
        tail.push({ type: event.type, data: event.data, at: Number.isFinite(event.time) ? event.time : 0 })
        const data = event.data && typeof event.data === 'object' ? event.data : {}
        if (event.type === 'request/context' || event.type === 'model/selection') {
          if (typeof data.provider === 'string' && data.provider) state.provider = data.provider
          if (typeof data.model === 'string' && data.model) state.model = data.model
        }
        if (event.type === 'session/title' && typeof data.title === 'string' && data.title) state.title = data.title
        if (event.type === 'working-directory/change' && typeof data.cwd === 'string' && data.cwd) state.cwd = data.cwd
      }
      if (tail.length > 0) state.events = tail
      logger.info('session-watchdog: 崩溃恢复已补读会话日志 ' + decision.sessionId + '（' + tail.length + ' 条事件）')
    } catch (error) {
      try { logger.warn('session-watchdog: 崩溃恢复补读会话日志失败（继续用状态快照） ' + String(error && error.message ? error.message : error)) } catch { /* noop */ }
    }
  }

  /** fire-and-forget 调用续跑：再包一层 catch，杜绝未捕获 rejection 冒到宿主进程。 */
  function fireResume(alertId, decision) {
    try {
      Promise.resolve(executeResume(alertId, decision)).catch((error) => {
        try { logger.warn('session-watchdog: 续跑 promise 异常（已隔离） ' + String(error && error.message ? error.message : error)) } catch { /* noop */ }
      })
    } catch (error) {
      try { logger.warn('session-watchdog: 续跑调用异常（已隔离） ' + String(error && error.message ? error.message : error)) } catch { /* noop */ }
    }
  }

  /** 延时续跑：默认 3 秒后执行，期间用户手动继续则撤销；指令在真正投递前再按最新上下文生成。 */
  function scheduleResume(decision, alertId) {
    const id = alertId || decision.id
    const delay = Math.max(0, Number.isFinite(config.resumeDelayMs) ? config.resumeDelayMs : 3000)
    const timer = setTimeout(() => {
      pending.delete(id)
      fireResume(id, decision)
    }, delay)
    if (typeof timer.unref === 'function') timer.unref()
    pending.set(id, { timer, decision })
  }

  async function executeResume(alertId, decision) {
    // 整个续跑流程必须自己吞掉所有异常：它是从 HTTP 路由 / 定时器里 fire-and-forget 调用的，
    // 任何未捕获 rejection 都会冒到宿主进程，触发 "fatal load failure" 把桌面端打崩（v0.3.0 实测）。
    try {
      const sessionId = decision.sessionId
      const state = detector.get(sessionId)
      if (state && state.status === 'running' && state.lastEventAt > decision.at) {
        feed.update(alertId, { stage: 'superseded' })
        return
      }
      feed.update(alertId, { stage: 'resuming' })
      const events = state ? state.events : []
      const context = extractContext({ events, title: decision.title, cwd: decision.cwd })
      const conversation = extractConversation(events, { maxMessages: 10, maxChars: 2400 })
      // 注意：不能写 ctx.llm —— 插件未声明 inject 时读未注入服务会抛 CordisError。
      const instruction = await generateResumeInstruction({
        llm: readService(ctx, 'llm'),
        provider: state ? state.provider : '',
        model: state ? state.model : '',
        decision,
        context,
        conversation,
        config,
        logger,
      })
      const message = instruction.text
      feed.update(alertId, { instructionSource: instruction.source, instructionError: instruction.error || null })
      let result
      try {
        result = await runner.deliver(sessionId, message)
      } catch (error) {
        result = { ok: false, via: 'none', error: String(error && error.message ? error.message : error) }
      }
      policy.recordResult(sessionId, result.ok === true)
      const alert = feed.get(alertId)
      feed.update(alertId, {
        stage: result.ok ? 'resumed' : 'resume-failed',
        error: result.ok ? (alert ? alert.error : null) : (result.error || '续跑失败'),
        resumeCount: alert ? (alert.resumeCount || 0) + 1 : 1,
        via: result.via,
      })
      logger.info('session-watchdog: 续跑 ' + (result.ok ? '成功' : '失败') + '（' + result.via + '）@ ' + sessionId + (result.ok ? '' : ' ' + result.error))
      persist(true)
    } catch (error) {
      try { logger.warn('session-watchdog: 续跑流程异常（已隔离） ' + String(error && error.message ? error.message : error)) } catch { /* noop */ }
      try { feed.update(alertId, { stage: 'resume-failed', error: '续跑流程异常: ' + String(error && error.message ? error.message : error) }) } catch { /* noop */ }
    }
  }

  // ---------- 1) 会话事件订阅 ----------
  ctx.on('session/event', (session, event) => {
    try {
      // 标题以宿主 sessionTitle 服务为准（与会话列表一致）；detector 的事件缓存只做兜底
      try {
        const state = detector.get(session && session.id ? session.id : '')
        if (state && !state.title && session) {
          const titleService = readService(ctx, 'sessionTitle')
          const title = titleService && typeof titleService.get === 'function' ? titleService.get(session) : ''
          if (typeof title === 'string' && title) state.title = title
        }
      } catch { /* 标题取不到不影响判定 */ }
      const decisions = detector.observe(session, event)
      const sessionId = session && session.id ? session.id : ''
      if (event && event.type === 'turn/start' && sessionId) supersedePending(pending, feed, sessionId, event.time || Date.now())
      for (const decision of decisions) handleDecision(decision)
      if (event && event.type === 'turn/end') persist(true)
      else persist(false)
    } catch (error) {
      logger.warn('session-watchdog: 事件处理异常 ' + String(error && error.message ? error.message : error))
    }
  })

  // ---------- 2) 会话销毁：清掉内存状态 ----------
  try {
    ctx.on('session/disposed', (session) => {
      try { if (session && session.id) detector.forget(session.id) } catch { /* noop */ }
    })
  } catch { /* noop */ }

  // ---------- 3) 假死心跳 ----------
  try {
    const timer = setInterval(() => {
      try {
        for (const decision of detector.tick()) handleDecision(decision)
      } catch (error) {
        logger.warn('session-watchdog: 心跳异常 ' + String(error && error.message ? error.message : error))
      }
    }, STALL_CHECK_INTERVAL_MS)
    if (typeof timer.unref === 'function') timer.unref()
    ctx.effect(() => () => clearInterval(timer))
  } catch { /* noop */ }

  // ---------- 4) 路由（浏览器半侧提醒流） ----------
  try {
    registerRoutes({
      ctx,
      feed,
      config,
      logger,
      getConfig: () => configStore.payload(),
      updateConfig: (patch) => {
        const result = configStore.update(patch)
        if (result.ok) applyLiveConfig(result.config)
        return result
      },
      resetConfig: () => {
        const result = configStore.reset()
        if (result.ok) applyLiveConfig(result.config)
        return result
      },
      onAction: async (id, action) => {
        const alert = feed.get(id)
        if (!alert) return { ok: false, reason: 'alert-not-found' }
        if (action === 'dismiss') {
          const entry = pending.get(id)
          if (entry) { try { clearTimeout(entry.timer) } catch { /* noop */ } pending.delete(id) }
          feed.update(id, { stage: 'dismissed' })
          return { ok: true }
        }
        if (action === 'resume') {
          const entry = pending.get(id)
          if (entry) {
            try { clearTimeout(entry.timer) } catch { /* noop */ }
            pending.delete(id)
          }
          const decision = entry ? entry.decision : reconstructDecision(alert)
          fireResume(id, decision)
          return { ok: true }
        }
        return { ok: false, reason: 'unknown-action' }
      },
    })
  } catch (error) {
    logger.warn('session-watchdog: 路由注册异常 ' + String(error && error.message ? error.message : error))
  }

  function reconstructDecision(alert) {
    return {
      id: alert.id,
      sessionId: alert.sessionId,
      turn: alert.turn,
      kind: alert.kind,
      source: 'manual',
      error: alert.error ? { message: alert.error, code: 'UNKNOWN' } : null,
      title: alert.title,
      at: Date.now(),
    }
  }

  // ---------- 5) 启动恢复：上次退出时未闭合的 turn ----------
  let saved = null
  try { saved = store.load() } catch { saved = null }
  if (saved) {
    try { policy.restore(saved.policy) } catch { /* noop */ }
    let decisions = []
    try { decisions = detector.restore(saved.detector, { savedAt: saved.savedAt }) } catch { decisions = [] }
    if (decisions.length > 0) {
      const timer = setTimeout(() => {
        void (async () => {
          for (const decision of decisions) {
            try {
              await hydrateStartupDecision(decision)
              handleDecision(decision)
            } catch (error) { logger.warn('session-watchdog: 恢复判定异常 ' + String(error && error.message ? error.message : error)) }
          }
        })()
      }, STARTUP_DELAY_MS)
      if (typeof timer.unref === 'function') timer.unref()
      try { ctx.effect(() => () => clearTimeout(timer)) } catch { /* noop */ }
    }
  }

  // ---------- 6) 启动扫描：历史遗留的未闭合 turn（插件首次安装时兜底） ----------
  const scanTimer = setTimeout(() => { void startupScan() }, STARTUP_SCAN_DELAY_MS)
  if (typeof scanTimer.unref === 'function') scanTimer.unref()
  try { ctx.effect(() => () => clearTimeout(scanTimer)) } catch { /* noop */ }

  async function startupScan() {
    try {
      const query = readService(ctx, 'sessionQuery')
      if (!query || typeof query.listSessions !== 'function' || typeof query.readSession !== 'function') return
      const records = await query.listSessions()
      if (!Array.isArray(records)) return
      const cutoff = Date.now() - STARTUP_SCAN_WINDOW_MS
      const candidates = records.filter((record) => record && record.header && record.header.id && record.persisted === true && record.live !== true).slice(0, 30)
      for (const record of candidates) {
        try {
          const read = await query.readSession(record.header.id)
          const events = read && Array.isArray(read.events) ? read.events : []
          const scanState = detector.get(record.header.id)
          if (scanState && events.length > 0) {
            scanState.events = events.slice(-400).map((event) => ({ type: event.type, data: event.data, at: Number.isFinite(event.time) ? event.time : 0 }))
          }
          let open = false
          let openTurn = null
          let lastTime = 0
          for (const event of events) {
            if (!event || typeof event.type !== 'string') continue
            if (event.type === 'turn/start') { open = true; openTurn = event.data && event.data.turn ? event.data.turn : null }
            if (event.type === 'turn/end') { open = false; openTurn = null }
            if (Number.isFinite(event.time)) lastTime = event.time
          }
          if (!open || lastTime === 0 || lastTime < cutoff) continue
          const header = record.header || {}
          handleDecision({
            id: header.id + '#' + String(openTurn ?? '?') + '#interrupted',
            sessionId: header.id,
            turn: openTurn,
            kind: 'interrupted',
            source: 'startup-scan',
            reasonKind: 'interrupted',
            error: { message: '会话日志显示上次运行在 turn 未结束时终止', code: 'CRASH_LEFTOVER' },
            title: '',
            cwd: typeof header.cwd === 'string' ? header.cwd : '',
            origin: header.origin,
            awaitingUser: false,
            savedAt: lastTime,
            at: Date.now(),
          })
        } catch { /* 单个会话读取失败不影响其它 */ }
      }
      persist(false)
    } catch (error) {
      logger.warn('session-watchdog: 启动扫描异常 ' + String(error && error.message ? error.message : error))
    }
  }

  // ---------- 7) 卸载清理 ----------
  try {
    ctx.effect(() => () => {
      try {
        disposed = true
        for (const [, entry] of pending) {
          try { clearTimeout(entry.timer) } catch { /* noop */ }
        }
        pending.clear()
        persist(true)
        store.dispose()
      } catch (error) {
        logger.warn('session-watchdog: 卸载清理异常 ' + String(error && error.message ? error.message : error))
      }
    }, 'session-watchdog: teardown')
  } catch { /* noop */ }
}

export { normalizeConfig } from './policy.js'
export { publicConfig }
