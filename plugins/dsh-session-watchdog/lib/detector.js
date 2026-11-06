/**
 * 会话哨兵 —— 停止判定状态机。
 *
 * 纯逻辑：只吃 { session, event } 与时间，不依赖宿主服务，便于单测与替换。
 * 事件形状已对照 dsh-session / dsh-agent-loop / typert.host.js 核实：
 *   turn/start  { turn }
 *   turn/end    { turn, reason: { kind, reason?, error?: LlmFailure } }
 *   tool/call   { turn, step, callId, name, arguments }
 *   tool/result { turn, step, message: { isError, toolCallId? }, error?: { code } }
 *   assistant/message { turn, step, message, stream, interrupted? }
 *   user/message      UserMessage { id, role, content, source }
 *   todo/write  { todos: [{ content, status }] }
 *   goal/change GoalChangeMeta（形状随版本变化，读取时做防御）
 *   session/title { title, messageSeqs, source }
 *   approval/asked / approval/decided（等待用户审批 → 不算卡死）
 *
 * 异常停止 kind：error / interrupted / max-tokens / blocked / stalled（本地合成）。
 * 正常：completed；用户主动中止：aborted（默认不提醒）；fork：forked。
 */

export const TURN_END_KINDS = ['completed', 'error', 'blocked', 'aborted', 'interrupted', 'max-tokens', 'forked']
export const ABNORMAL_KINDS = ['error', 'interrupted', 'max-tokens', 'blocked']
export const DEFAULT_STALL_TIMEOUT_MS = 10 * 60 * 1000
export const DEFAULT_TOOL_STALL_TIMEOUT_MS = 15 * 60 * 1000
const SESSION_TTL_MS = 60 * 60 * 1000
const MAX_EVENTS = 400

const textOf = (value) => (typeof value === 'string' ? value : '')

function contentText(content) {
  if (typeof content === 'string') return content
  if (!Array.isArray(content)) return ''
  const parts = []
  for (const part of content) {
    if (part && part.type === 'text' && typeof part.text === 'string') parts.push(part.text)
  }
  return parts.join('\n').trim()
}

/** assistant/message 的正文在 data.message.content（不是 data.content）。 */
function assistantText(data) {
  const message = data && data.message && typeof data.message === 'object' ? data.message : data
  return contentText(message && message.content)
}

function userText(data) {
  return contentText(data && data.content)
}

/**
 * @param {{ clock?: () => number, stallTimeoutMs?: number, toolStallTimeoutMs?: number }} [options]
 */
export function createDetector(options = {}) {
  const clock = typeof options.clock === 'function' ? options.clock : () => Date.now()
  let stallTimeoutMs = Number.isFinite(options.stallTimeoutMs) && options.stallTimeoutMs > 0 ? options.stallTimeoutMs : DEFAULT_STALL_TIMEOUT_MS
  let toolStallTimeoutMs = Number.isFinite(options.toolStallTimeoutMs) && options.toolStallTimeoutMs > 0 ? options.toolStallTimeoutMs : DEFAULT_TOOL_STALL_TIMEOUT_MS
  const sessions = new Map()

  function ensure(sessionId) {
    let state = sessions.get(sessionId)
    if (!state) {
      state = {
        sessionId,
        title: '',
        cwd: '',
        origin: '',
        provider: '',
        model: '',
        status: 'unknown', // unknown | running | idle
        openTurn: null,
        turnStartedAt: 0,
        lastEventAt: 0,
        openTools: new Map(),
        pendingApprovals: 0,
        stallReported: false,
        lastError: null,
        lastAssistantText: '',
        lastUserText: '',
        events: [],
        seenAt: 0
      }
      sessions.set(sessionId, state)
    }
    return state
  }

  /** 折入一条会话事件；返回本次产生的判定（0 或 1 条）。 */
  function observe(session, event) {
    if (!event || typeof event.type !== 'string') return []
    const sessionId = typeof session === 'string' ? session : textOf(session && session.id)
    if (!sessionId) return []
    const now = clock()
    const state = ensure(sessionId)
    state.seenAt = now
    state.lastEventAt = now
    if (session && typeof session === 'object') {
      const header = session.header && typeof session.header === 'object' ? session.header : null
      if (header) {
        if (!state.cwd && typeof header.cwd === 'string') state.cwd = header.cwd
        if (!state.origin && typeof header.origin === 'string') state.origin = header.origin
      }
      if (!state.cwd && typeof session.meta?.cwd === 'string') state.cwd = session.meta.cwd
    }
    const data = event.data && typeof event.data === 'object' ? event.data : {}
    const decisions = []

    switch (event.type) {
      case 'turn/start': {
        state.status = 'running'
        state.openTurn = Number.isFinite(data.turn) ? data.turn : state.openTurn === null ? 1 : state.openTurn + 1
        state.turnStartedAt = now
        state.stallReported = false
        state.openTools.clear()
        break
      }
      case 'turn/end': {
        const reason = data.reason && typeof data.reason === 'object' ? data.reason : {}
        const kind = typeof reason.kind === 'string' && reason.kind ? reason.kind : 'unknown'
        const turn = Number.isFinite(data.turn) ? data.turn : state.openTurn
        state.status = 'idle'
        state.openTurn = null
        state.stallReported = false
        state.openTools.clear()
        const awaitingUser = state.pendingApprovals > 0
        state.pendingApprovals = 0
        state.lastError = reason.error && typeof reason.error === 'object'
          ? { message: textOf(reason.error.message), code: textOf(reason.error.code), status: Number.isFinite(reason.error.status) ? reason.error.status : undefined }
          : kind === 'error'
            ? { message: '未知错误', code: 'UNKNOWN' }
            : null
        decisions.push({
          id: sessionId + '#' + String(turn ?? '?') + '#' + kind,
          sessionId,
          turn: Number.isFinite(turn) ? turn : null,
          kind,
          source: 'turn-end',
          reasonKind: kind,
          cancelCause: kind === 'aborted' && reason.reason && typeof reason.reason.kind === 'string' ? reason.reason.kind : null,
          error: state.lastError,
          title: state.title,
          cwd: state.cwd,
          origin: state.origin,
          awaitingUser,
          at: now
        })
        break
      }
      case 'tool/call': {
        const callId = textOf(data.callId)
        if (callId) state.openTools.set(callId, { name: textOf(data.name) || 'tool', startedAt: now })
        break
      }
      case 'tool/result': {
        const callId = textOf(data.callId) || textOf(data.message && data.message.toolCallId)
        if (callId) state.openTools.delete(callId)
        if (data.message && data.message.isError === true) {
          state.lastError = {
            message: contentText(data.message.content).slice(0, 400) || '工具调用失败',
            code: textOf(data.error && data.error.code) || 'TOOL_ERROR'
          }
        }
        break
      }
      case 'assistant/message': {
        const text = assistantText(data)
        if (text) state.lastAssistantText = text
        break
      }
      case 'user/message': {
        const text = userText(data)
        if (text) state.lastUserText = text
        break
      }
      case 'session/title': {
        const title = textOf(data.title)
        if (title) state.title = title
        break
      }
      case 'working-directory/change': {
        const cwd = textOf(data.cwd)
        if (cwd) state.cwd = cwd
        break
      }
      case 'request/context':
      case 'model/selection': {
        const provider = textOf(data.provider)
        const model = textOf(data.model)
        if (provider) state.provider = provider
        if (model) state.model = model
        break
      }
      case 'approval/asked': {
        state.pendingApprovals += 1
        break
      }
      case 'approval/decided': {
        state.pendingApprovals = Math.max(0, state.pendingApprovals - 1)
        break
      }
      default:
        break
    }

    state.events.push({ type: event.type, data, at: now })
    if (state.events.length > MAX_EVENTS) state.events.splice(0, state.events.length - MAX_EVENTS)
    return decisions
  }

  /** 心跳检查：运行中但长期静默 → 假死判定（每个 turn 只报一次）。 */
  function tick() {
    const now = clock()
    const decisions = []
    for (const state of sessions.values()) {
      if (state.status !== 'running' || state.openTurn === null) continue
      const tools = Array.from(state.openTools.values())
      const newestTool = tools.reduce((acc, tool) => (tool.startedAt > acc ? tool.startedAt : acc), 0)
      const anchor = Math.max(state.turnStartedAt, state.lastEventAt, newestTool)
      const threshold = tools.length > 0 ? toolStallTimeoutMs : stallTimeoutMs
      if (now - anchor <= threshold || state.stallReported) continue
      state.stallReported = true
      decisions.push({
        id: state.sessionId + '#' + String(state.openTurn) + '#stalled',
        sessionId: state.sessionId,
        turn: state.openTurn,
        kind: 'stalled',
        source: 'stall',
        reasonKind: 'stalled',
        cancelCause: null,
        error: { message: '连续 ' + Math.round((now - anchor) / 1000) + ' 秒没有任何会话事件', code: 'STALLED' },
        stalledMs: now - anchor,
        title: state.title,
        cwd: state.cwd,
        origin: state.origin,
        awaitingUser: state.pendingApprovals > 0,
        at: now
      })
    }
    for (const [id, state] of sessions) {
      if (state.status !== 'running' && now - state.seenAt > SESSION_TTL_MS) sessions.delete(id)
    }
    return decisions
  }

  /** 宿主启动时用持久化状态播种：上次退出时仍处于 turn 中的会话 → interrupted。 */
  function restore(entries, options = {}) {
    if (!Array.isArray(entries)) return []
    const decisions = []
    const now = clock()
    const savedAt = Number.isFinite(options.savedAt) ? options.savedAt : 0
    for (const entry of entries) {
      if (!entry || typeof entry.sessionId !== 'string' || !entry.sessionId) continue
      const state = ensure(entry.sessionId)
      state.title = textOf(entry.title) || state.title
      state.cwd = textOf(entry.cwd) || state.cwd
      state.origin = textOf(entry.origin) || state.origin
      state.provider = textOf(entry.provider) || state.provider
      state.model = textOf(entry.model) || state.model
      state.lastEventAt = Number.isFinite(entry.lastEventAt) ? entry.lastEventAt : state.lastEventAt
      state.turnStartedAt = Number.isFinite(entry.turnStartedAt) ? entry.turnStartedAt : state.turnStartedAt
      state.lastUserText = textOf(entry.lastUserText) || state.lastUserText
      state.lastAssistantText = textOf(entry.lastAssistantText) || state.lastAssistantText
      if (Number.isFinite(entry.openTurn)) {
        state.status = 'running'
        state.openTurn = entry.openTurn
        decisions.push({
          id: entry.sessionId + '#' + String(entry.openTurn) + '#interrupted',
          sessionId: entry.sessionId,
          turn: entry.openTurn,
          kind: 'interrupted',
          source: 'startup',
          reasonKind: 'interrupted',
          cancelCause: null,
          error: { message: '宿主进程在 turn 未结束时退出', code: 'HOST_EXIT' },
          title: state.title,
          cwd: state.cwd,
          origin: state.origin,
          awaitingUser: false,
          savedAt,
          at: now
        })
      } else {
        state.status = 'idle'
        state.openTurn = null
      }
    }
    return decisions
  }

  function persistable() {
    const out = []
    for (const state of sessions.values()) {
      out.push({
        sessionId: state.sessionId,
        title: state.title,
        cwd: state.cwd,
        origin: state.origin,
        provider: state.provider,
        model: state.model,
        openTurn: state.openTurn,
        turnStartedAt: state.turnStartedAt,
        lastEventAt: state.lastEventAt,
        lastUserText: state.lastUserText.slice(0, 500),
        lastAssistantText: state.lastAssistantText.slice(0, 500),
        pendingApprovals: state.pendingApprovals
      })
    }
    return out
  }

  /** 设置面板改了假死阈值：无需重建状态机，直接换参数。 */
  function setOptions(next = {}) {
    if (Number.isFinite(next.stallTimeoutMs) && next.stallTimeoutMs > 0) stallTimeoutMs = next.stallTimeoutMs
    if (Number.isFinite(next.toolStallTimeoutMs) && next.toolStallTimeoutMs > 0) toolStallTimeoutMs = next.toolStallTimeoutMs
    for (const state of sessions.values()) state.stallReported = false
  }

  function forget(sessionId) { sessions.delete(sessionId) }
  function get(sessionId) { return sessions.get(sessionId) || null }
  function list() { return Array.from(sessions.values()) }

  return { observe, tick, restore, persistable, forget, get, list, setOptions }
}
