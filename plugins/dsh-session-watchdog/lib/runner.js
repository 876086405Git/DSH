/**
 * 会话哨兵 —— 续跑执行器。
 *
 * 优先走宿主自己的 Remote 控制器（与 GUI 发消息同一条路径，自带冷会话唤醒）：
 *   sessionController.prompt({ requestId, sessionId, mode:'queue', content }, signal)
 * 不可用时退回 agent.followup(手搓 UserMessage) —— 第三方插件不能 import
 * @deepseek-ai/dsh-llm，只能按落盘校验要求构造最小消息。
 */

/** 手搓合法 UserMessage（落盘校验：id/role/source.kind/content 形状）。 */
export function buildUserMessage(text, id) {
  return {
    id: typeof id === 'string' && id ? id : 'msg-' + Math.random().toString(36).slice(2) + Date.now().toString(36),
    role: 'user',
    content: [{ type: 'text', text: String(text) }],
    source: { kind: 'user' },
  }
}

/**
 * @param {{ctx:any, logger?:any}} options
 */
export function createRunner(options) {
  const ctx = options.ctx
  const logger = options.logger
  let sessionController = null
  try {
    if (typeof ctx.inject === 'function') {
      ctx.inject(['sessionController'], (scope) => {
        sessionController = scope && scope.sessionController ? scope.sessionController : null
        try {
          scope.effect(() => () => { sessionController = null }, 'session-watchdog: controller')
        } catch { /* noop */ }
      })
    }
  } catch { /* 没有该服务时走 followup 兜底 */ }

  function liveAgent(sessionId) {
    try { return ctx.agents && typeof ctx.agents.get === 'function' ? ctx.agents.get(sessionId) : undefined } catch { return undefined }
  }

  async function resolveAgent(sessionId) {
    const live = liveAgent(sessionId)
    if (live !== undefined && live !== null) return { agent: live }
    if (sessionController && typeof sessionController.resolveAgent === 'function') {
      const found = await sessionController.resolveAgent(sessionId)
      if (found && found.agent) return { agent: found.agent }
      return { error: found && found.error ? found.error : new Error('agent-not-found') }
    }
    return { error: new Error('session-controller-unavailable') }
  }

  /** 投递一条用户消息；返回 { ok, via, error }。 */
  async function deliver(sessionId, text) {
    const requestId = 'session-watchdog-' + Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 8)
    // 路径 1：宿主 Remote 控制器（与 GUI 完全一致，自动唤醒冷会话）
    if (sessionController && typeof sessionController.prompt === 'function') {
      try {
        const controller = new AbortController()
        const timer = setTimeout(() => controller.abort(), 30000)
        try {
          await sessionController.prompt({ requestId, sessionId, mode: 'queue', content: [{ type: 'text', text }] }, controller.signal)
        } finally {
          clearTimeout(timer)
        }
        return { ok: true, via: 'sessionController.prompt' }
      } catch (error) {
        try { logger?.warn?.('session-watchdog: prompt 路径失败，改用 followup：' + String(error && error.message ? error.message : error)) } catch { /* noop */ }
      }
    }
    // 路径 2：直接投递到 Agent 的 inbox
    const resolved = await resolveAgent(sessionId)
    if (resolved.error) return { ok: false, via: 'none', error: String(resolved.error && resolved.error.message ? resolved.error.message : resolved.error) }
    const agent = resolved.agent
    try {
      if (agent && typeof agent.followup === 'function') {
        agent.followup(buildUserMessage(text, requestId))
      } else if (agent && typeof agent.send === 'function') {
        agent.send(buildUserMessage(text, requestId), 'next-turn', true)
      } else {
        return { ok: false, via: 'agent', error: 'agent has no followup/send' }
      }
      if (ctx.sessions && typeof ctx.sessions.flush === 'function' && agent.session) {
        try { await ctx.sessions.flush(agent.session) } catch { /* 无持久化时 flush 可能抛错，不影响已入队消息 */ }
      }
      return { ok: true, via: 'agent.followup' }
    } catch (error) {
      return { ok: false, via: 'agent.followup', error: String(error && error.message ? error.message : error) }
    }
  }

  return { deliver, resolveAgent, liveAgent }
}
