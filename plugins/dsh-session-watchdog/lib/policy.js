/**
 * 会话哨兵 —— 提醒 / 自动续跑策略（纯逻辑）。
 *
 * 输入一条停止判定，输出「要不要提醒、要不要续跑、何时续跑」。
 * 所有预算、熔断、去重状态都在这里，便于单测和持久化。
 */

/** 默认配置。字段含义见 docs/01-设计说明.md 配置项总表。 */
export const DEFAULT_CONFIG = {
  enabled: true,
  autoResume: true,
  resumeKinds: ['error', 'interrupted', 'max-tokens', 'blocked'],
  monitorSubagents: false,
  includeCwd: [],
  excludeCwd: [],
  excludeSessionIds: [],
  notifyOnCompletion: true,
  notifyOnStall: true,
  notifyOnAborted: false,
  resumeOnStall: false,
  resumeOnStartupScan: false,
  stallTimeoutMs: 10 * 60 * 1000,
  toolStallTimeoutMs: 15 * 60 * 1000,
  resumeDelayMs: 3000,
  dedupeWindowMs: 10 * 60 * 1000,
  maxResumesPerSession: 2,
  resumeWindowMs: 30 * 60 * 1000,
  globalBudget: 5,
  globalBudgetWindowMs: 10 * 60 * 1000,
  maxConsecutiveFailures: 3,
  skipWhenAwaitingUser: true,
  notifyOs: true,
  notifyGui: true,
  toastDurationMs: 8000,
  completionSound: 'dingdong',
  completionVolume: 70,
  resumePromptMode: 'llm',
  resumeLlmTimeoutMs: 20000,
  resumeLlmMaxOutputTokens: 500,
  resumeInstructionMaxChars: 1200,
  maxContextChars: 2000,
  resumePromptHeader: '[会话哨兵]',
}

/** 完成提示音候选（首项 none = 关闭）。 */
export const COMPLETION_SOUNDS = ['none', 'dingdong', 'double', 'tritone', 'drop', 'chime', 'pulse']

/** 续跑指令生成方式。 */
export const RESUME_PROMPT_MODES = ['llm', 'context']

const NUMBER_LIMITS = {
  stallTimeoutMs: [30 * 1000, 6 * 60 * 60 * 1000],
  toolStallTimeoutMs: [30 * 1000, 6 * 60 * 60 * 1000],
  resumeDelayMs: [0, 60 * 1000],
  dedupeWindowMs: [0, 24 * 60 * 60 * 1000],
  maxResumesPerSession: [0, 50],
  resumeWindowMs: [60 * 1000, 24 * 60 * 60 * 1000],
  globalBudget: [0, 200],
  globalBudgetWindowMs: [60 * 1000, 24 * 60 * 60 * 1000],
  maxConsecutiveFailures: [1, 20],
  toastDurationMs: [2000, 60000],
  maxContextChars: [400, 20000],
  completionVolume: [0, 100],
  resumeLlmTimeoutMs: [1000, 60000],
  resumeLlmMaxOutputTokens: [64, 2000],
  resumeInstructionMaxChars: [200, 4000],
}

function asBool(value, fallback) {
  return typeof value === 'boolean' ? value : fallback
}

function asNumber(value, fallback, [min, max]) {
  if (typeof value !== 'number' || !Number.isFinite(value)) return fallback
  return Math.min(max, Math.max(min, Math.round(value)))
}

function asString(value, fallback) {
  return typeof value === 'string' ? value : fallback
}

function asStringArray(value, fallback) {
  if (!Array.isArray(value)) return fallback
  return value.filter((item) => typeof item === 'string' && item !== '')
}

/** 归一化配置：类型不对或越界一律回落默认值，绝不抛错。 */
export function normalizeConfig(raw) {
  const input = raw && typeof raw === 'object' ? raw : {}
  const config = { ...DEFAULT_CONFIG }
  config.enabled = asBool(input.enabled, DEFAULT_CONFIG.enabled)
  config.autoResume = asBool(input.autoResume, DEFAULT_CONFIG.autoResume)
  config.resumeKinds = asStringArray(input.resumeKinds, DEFAULT_CONFIG.resumeKinds)
  config.monitorSubagents = asBool(input.monitorSubagents, DEFAULT_CONFIG.monitorSubagents)
  config.includeCwd = asStringArray(input.includeCwd, DEFAULT_CONFIG.includeCwd)
  config.excludeCwd = asStringArray(input.excludeCwd, DEFAULT_CONFIG.excludeCwd)
  config.excludeSessionIds = asStringArray(input.excludeSessionIds, DEFAULT_CONFIG.excludeSessionIds)
  config.notifyOnCompletion = asBool(input.notifyOnCompletion, DEFAULT_CONFIG.notifyOnCompletion)
  config.notifyOnStall = asBool(input.notifyOnStall, DEFAULT_CONFIG.notifyOnStall)
  config.completionSound = asString(input.completionSound, DEFAULT_CONFIG.completionSound)
  if (!COMPLETION_SOUNDS.includes(config.completionSound)) config.completionSound = DEFAULT_CONFIG.completionSound
  config.resumePromptMode = asString(input.resumePromptMode, DEFAULT_CONFIG.resumePromptMode)
  if (!RESUME_PROMPT_MODES.includes(config.resumePromptMode)) config.resumePromptMode = DEFAULT_CONFIG.resumePromptMode
  config.notifyOnAborted = asBool(input.notifyOnAborted, DEFAULT_CONFIG.notifyOnAborted)
  config.resumeOnStall = asBool(input.resumeOnStall, DEFAULT_CONFIG.resumeOnStall)
  config.resumeOnStartupScan = asBool(input.resumeOnStartupScan, DEFAULT_CONFIG.resumeOnStartupScan)
  config.skipWhenAwaitingUser = asBool(input.skipWhenAwaitingUser, DEFAULT_CONFIG.skipWhenAwaitingUser)
  config.notifyOs = asBool(input.notifyOs, DEFAULT_CONFIG.notifyOs)
  config.notifyGui = asBool(input.notifyGui, DEFAULT_CONFIG.notifyGui)
  config.resumePromptHeader = asString(input.resumePromptHeader, DEFAULT_CONFIG.resumePromptHeader)
  for (const key of Object.keys(NUMBER_LIMITS)) config[key] = asNumber(input[key], DEFAULT_CONFIG[key], NUMBER_LIMITS[key])
  // 允许未列出的字段透传（例如未来版本的私有开关），但不参与决策
  for (const [key, value] of Object.entries(input)) {
    if (!(key in config)) config[key] = value
  }
  return config
}

/** 把配置里可能出现的 Windows 路径/大小写差异拍到可比形态。 */
function samePath(a, b) {
  const norm = (p) => String(p).replace(/[\\/]+/g, '/').replace(/\/$/, '').toLowerCase()
  return norm(a) === norm(b) || norm(a).startsWith(norm(b) + '/')
}

function matchPath(list, cwd) {
  if (list.length === 0) return false
  if (!cwd) return false
  return list.some((entry) => samePath(cwd, entry))
}

/**
 * 创建策略器。
 * @param {ReturnType<typeof normalizeConfig>} config
 * @param {{ now?: () => number }} [options]
 */
export function createPolicy(config, options = {}) {
  const now = typeof options.now === 'function' ? options.now : () => Date.now()
  /** 幂等键 → 上次处理时间 */
  const processed = new Map()
  /** sessionId → { resumes:number[], failures:number, blocked:boolean } */
  const sessions = new Map()
  /** 全局续跑时间戳 */
  let globalResumes = []

  function sessionState(sessionId) {
    let state = sessions.get(sessionId)
    if (!state) {
      state = { resumes: [], failures: 0, blocked: false }
      sessions.set(sessionId, state)
    }
    return state
  }

  function prune(ts) {
    for (const [key, at] of processed) {
      if (ts - at > config.dedupeWindowMs) processed.delete(key)
    }
    for (const state of sessions.values()) {
      state.resumes = state.resumes.filter((at) => ts - at <= config.resumeWindowMs)
    }
    globalResumes = globalResumes.filter((at) => ts - at <= config.globalBudgetWindowMs)
  }

  /**
   * 对一条停止判定做决策。
   * @param {{id:string,sessionId:string,kind:string,source:string,turn:number|null,cwd?:string,title?:string,error?:any}} decision
   * @param {{origin?:string, awaitingUser?:boolean, cwdOk?:boolean, agentStatus?:string}} [info]
   * @returns {{notify:boolean,resume:boolean,resumeAt:number|null,reason:string,kindLabel:string}}
   */
  function decide(decision, info = {}) {
    const ts = now()
    prune(ts)
    const kind = decision && decision.kind ? decision.kind : 'unknown'
    const sessionId = decision && decision.sessionId ? decision.sessionId : ''

    if (!config.enabled) return deny('disabled')
    if (processed.has(decision.id)) return deny('duplicate')
    processed.set(decision.id, ts)

    if (kind === 'forked') return deny('normal-end')
    // 任务正常完成：默认也要提醒（可关），但永不自动续跑
    if (kind === 'completed' && !config.notifyOnCompletion) return deny('completion-muted')
    if (kind === 'aborted' && !config.notifyOnAborted) return deny('user-cancelled')
    if (kind === 'stalled' && !config.notifyOnStall) return deny('stall-muted')
    if (info.origin === 'subagent' && !config.monitorSubagents) return deny('subagent')
    if (sessionId !== '' && config.excludeSessionIds.includes(sessionId)) return deny('excluded-session')
    if (matchPath(config.excludeCwd, decision.cwd)) return deny('excluded-cwd')
    if (config.includeCwd.length > 0 && !matchPath(config.includeCwd, decision.cwd)) return deny('not-included')

    const state = sessionState(sessionId)
    let resumeBlocked = ''
    const isStall = kind === 'stalled'
    const resumeKindAllowed = isStall ? config.resumeOnStall : config.resumeKinds.includes(kind)
    if (info.awaitingUser && config.skipWhenAwaitingUser) resumeBlocked = 'awaiting-user'
    else if (info.cwdOk === false) resumeBlocked = 'cwd-missing'
    else if (state.blocked || state.failures >= config.maxConsecutiveFailures) resumeBlocked = 'circuit-open'
    else if (state.resumes.length >= config.maxResumesPerSession) resumeBlocked = 'session-budget'
    else if (globalResumes.length >= config.globalBudget) resumeBlocked = 'global-budget'
    else if (!resumeKindAllowed) resumeBlocked = 'kind-not-resumable'
    else if (!config.autoResume) resumeBlocked = 'auto-resume-off'
    else if (decision.source === 'startup-scan' && !config.resumeOnStartupScan) resumeBlocked = 'startup-scan'
    // 注意：不能用 agent.status==='running' 拦截 turn/end 的续跑。turn/end 是在
    // ReactLoopAgent.turn() 的 finally 里同步 append 的，此刻 phase 还没切回 idle，
    // status 仍是 'running'。真正的“用户已手动继续”由 index.js 的 supersedePending
    // 依据新的 turn/start 撤销，投递通道本身也支持排队（sessionController.prompt mode=queue）。

    const resume = resumeBlocked === ''
    if (resume) {
      state.resumes.push(ts)
      globalResumes.push(ts)
    }
    return {
      notify: true,
      resume,
      resumeAt: resume ? ts + config.resumeDelayMs : null,
      reason: resume ? 'ok' : resumeBlocked,
      kindLabel: kind,
    }

    function deny(reason) {
      return { notify: false, resume: false, resumeAt: null, reason, kindLabel: '' }
    }
  }

  /** 续跑执行结果回写：成功清零连续失败，失败累加并可能熔断。 */
  function recordResult(sessionId, ok) {
    const state = sessionState(sessionId)
    if (ok) {
      state.failures = 0
      return
    }
    state.failures += 1
    if (state.failures >= config.maxConsecutiveFailures) state.blocked = true
  }

  /** 手动解除某个会话的熔断（客户端「忽略」或用户手动续跑后调用）。 */
  function clearSession(sessionId) {
    sessions.delete(sessionId)
  }

  function snapshot() {
    return {
      processed: Array.from(processed.entries()),
      sessions: Array.from(sessions.entries()).map(([id, state]) => [id, { resumes: state.resumes, failures: state.failures, blocked: state.blocked }]),
      globalResumes,
    }
  }

  function restore(data) {
    if (!data || typeof data !== 'object') return
    if (Array.isArray(data.processed)) {
      for (const entry of data.processed) {
        if (Array.isArray(entry) && typeof entry[0] === 'string' && Number.isFinite(entry[1])) processed.set(entry[0], entry[1])
      }
    }
    if (Array.isArray(data.sessions)) {
      for (const entry of data.sessions) {
        if (!Array.isArray(entry) || typeof entry[0] !== 'string' || !entry[1]) continue
        sessions.set(entry[0], {
          resumes: Array.isArray(entry[1].resumes) ? entry[1].resumes.filter((at) => Number.isFinite(at)) : [],
          failures: Number.isFinite(entry[1].failures) ? entry[1].failures : 0,
          blocked: entry[1].blocked === true,
        })
      }
    }
    if (Array.isArray(data.globalResumes)) globalResumes = data.globalResumes.filter((at) => Number.isFinite(at))
  }

  return { decide, recordResult, clearSession, snapshot, restore }
}
