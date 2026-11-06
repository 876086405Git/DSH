/**
 * 会话哨兵 —— 断点上下文提取与续跑指令生成。
 *
 * 设计原则：确定性提取、零 token、可单测。只从会话事件流里读事实，
 * 不调用模型；超出长度预算时按优先级裁剪。
 *
 * 提取优先级（高 → 低）：
 *   1. 未完成 todo（todo/write 最后一张表）
 *   2. 活动 goal（goal/change 最后一个目标）
 *   3. 中断前最后动作（tool/call）与最后错误（tool/result 失败 / turn/end.error）
 *   4. 最近用户要求（最后一条 user/message）
 *   5. 最近 assistant 进度（最后一条非空 assistant/message）
 *   6. 会话标题 + cwd
 */

export const KIND_LABELS = {
  error: '执行失败',
  interrupted: '进程中断',
  'max-tokens': '超出长度上限',
  blocked: '被策略阻断',
  stalled: '长时间无响应（疑似卡死）',
  aborted: '已被中止',
  completed: '正常完成',
  forked: '分支继承',
}

export const CANCEL_CAUSE_LABELS = {
  user: '用户主动停止',
  parent: '父代理取消',
  hook: '插件取消',
  disposed: '宿主退出',
  legacy: '历史原因',
}

const textOf = (value) => (typeof value === 'string' ? value : '')

/** 读取 assistant/message 的文本（正文在 data.message.content）。 */
function messageText(message) {
  if (!message || typeof message !== 'object') return ''
  const content = message.content
  if (typeof content === 'string') return content
  if (!Array.isArray(content)) return ''
  const parts = []
  for (const block of content) {
    if (block && block.type === 'text' && typeof block.text === 'string') parts.push(block.text)
  }
  return parts.join('\n').trim()
}

/** todo 状态判定：兼容 completed / done / pending 等写法。 */
function isTodoDone(status) {
  const value = String(status || '').toLowerCase()
  return value === 'completed' || value === 'done' || value === 'complete'
}

/**
 * 从事件流提取断点上下文。
 * @param {{events?: Array<{type:string,data:any,at:number}>, title?:string, cwd?:string}} input
 */
export function extractContext(input = {}) {
  const events = Array.isArray(input.events) ? input.events : []
  const context = {
    title: typeof input.title === 'string' ? input.title : '',
    cwd: typeof input.cwd === 'string' ? input.cwd : '',
    goal: '',
    todos: { total: 0, done: 0, pending: [] },
    lastUser: '',
    lastAssistant: '',
    lastTool: null,
    lastError: null,
    lastEventType: events.length > 0 ? events[events.length - 1].type : '',
  }
  // 反向扫描：越靠后越新，命中即停。
  let todoFound = false
  let goalFound = false
  for (let index = events.length - 1; index >= 0; index -= 1) {
    const event = events[index]
    if (!event || typeof event.type !== 'string') continue
    const data = event.data && typeof event.data === 'object' ? event.data : {}
    switch (event.type) {
      case 'todo/write': {
        if (todoFound) break
        todoFound = true
        const todos = Array.isArray(data.todos) ? data.todos : []
        const pending = []
        let done = 0
        for (const todo of todos) {
          if (!todo || typeof todo.content !== 'string') continue
          if (isTodoDone(todo.status)) done += 1
          else pending.push(todo.content)
        }
        context.todos = { total: todos.length, done, pending: pending.slice(0, 12) }
        break
      }
      case 'session/title': {
        if (!context.title) context.title = textOf(data.title)
        break
      }
      case 'goal/change': {
        if (goalFound) break
        goalFound = true
        const goal = data.goal && typeof data.goal === 'object' ? data.goal : data
        const objective = typeof goal.objective === 'string' ? goal.objective : typeof goal.text === 'string' ? goal.text : ''
        const phase = typeof goal.phase === 'string' ? goal.phase : ''
        context.goal = objective ? (phase && phase !== 'active' ? '[目标·' + phase + '] ' + objective : objective) : ''
        break
      }
      case 'assistant/message': {
        if (!context.lastAssistant) {
          const text = messageText(data.message) || messageText(data)
          if (text) context.lastAssistant = text
        }
        break
      }
      case 'user/message': {
        if (!context.lastUser) {
          const text = messageText(data)
          if (text) context.lastUser = text
        }
        break
      }
      case 'tool/call': {
        if (!context.lastTool) {
          const args = typeof data.arguments === 'string' ? data.arguments : JSON.stringify(data.arguments || '')
          context.lastTool = {
            name: typeof data.name === 'string' ? data.name : 'tool',
            arguments: (args || '').replace(/\s+/g, ' ').slice(0, 160),
          }
        }
        break
      }
      case 'tool/result': {
        if (!context.lastError && data.message && data.message.isError === true) {
          context.lastError = {
            message: messageText(data.message).slice(0, 300) || '工具调用失败',
            code: typeof data.error?.code === 'string' ? data.error.code : 'TOOL_ERROR',
            tool: context.lastTool ? context.lastTool.name : '',
          }
        }
        break
      }
      case 'turn/end': {
        const reason = data.reason && typeof data.reason === 'object' ? data.reason : {}
        if (!context.lastError && reason.kind === 'error' && reason.error) {
          context.lastError = {
            message: typeof reason.error.message === 'string' ? reason.error.message.slice(0, 300) : '未知错误',
            code: typeof reason.error.code === 'string' ? reason.error.code : 'UNKNOWN',
            tool: '',
          }
        }
        break
      }
      default:
        break
    }
  }
  return context
}

/**
 * 从事件流里截取真实对话（用户/助手原文），用于生成承接上下文的续跑指令。
 * @param {Array<{type:string,data:any,at:number}>} events
 * @param {{maxMessages?:number, maxChars?:number}} [options]
 */
export function extractConversation(events, options = {}) {
  const list = Array.isArray(events) ? events : []
  const maxMessages = Number.isFinite(options.maxMessages) ? options.maxMessages : 10
  const maxChars = Number.isFinite(options.maxChars) ? options.maxChars : 2400
  const picked = []
  let used = 0
  for (let index = list.length - 1; index >= 0 && picked.length < maxMessages; index -= 1) {
    const event = list[index]
    if (!event || (event.type !== 'user/message' && event.type !== 'assistant/message')) continue
    const data = event.data && typeof event.data === 'object' ? event.data : {}
    const text = event.type === 'user/message'
      ? messageText(data)
      : (messageText(data.message) || messageText(data))
    if (!text) continue
    if (used + text.length > maxChars && picked.length > 0) break
    used += text.length
    picked.push({
      role: event.type === 'user/message' ? 'user' : 'assistant',
      text: text.length > 1200 ? text.slice(0, 1199) + '…' : text,
      at: Number.isFinite(event.at) ? event.at : 0,
      pluginSource: event.type === 'user/message' && data.source && typeof data.source.kind === 'string' && data.source.kind !== 'user',
    })
  }
  picked.reverse()
  return { messages: picked, chars: used }
}

/** 把多行文本压成单行并截断。 */
function oneLine(text, limit) {
  const value = String(text || '').replace(/\s+/g, ' ').trim()
  if (value.length <= limit) return value
  return value.slice(0, Math.max(0, limit - 1)) + '…'
}

/**
 * 生成结构化续跑指令（中文模板）。超出 maxChars 时按优先级裁剪低价值段落。
 * @param {{context: ReturnType<typeof extractContext>, decision: any, config: any}} input
 * @returns {{text:string, summary:string, chars:number}}
 */
export function buildResumePrompt(input) {
  const context = input.context || {}
  const decision = input.decision || {}
  const config = input.config || {}
  const maxChars = Number.isFinite(config.maxContextChars) && config.maxContextChars > 0 ? config.maxContextChars : 2000
  const header = typeof config.resumePromptHeader === 'string' && config.resumePromptHeader ? config.resumePromptHeader : '[会话哨兵]'
  const kindLabel = KIND_LABELS[decision.kind] || decision.kind || '异常停止'
  const cancelLabel = decision.cancelCause ? '（' + (CANCEL_CAUSE_LABELS[decision.cancelCause] || decision.cancelCause) + '）' : ''
  const lines = []
  lines.push(header + ' 上一轮执行异常中断，请从断点继续完成原任务。')
  lines.push('中断原因：' + kindLabel + cancelLabel + (decision.error && decision.error.message ? '；' + oneLine(decision.error.message, 200) : ''))
  lines.push('会话：' + (oneLine(context.title, 60) || '（无标题）') + (context.cwd ? '（' + context.cwd + '）' : ''))
  if (context.goal) lines.push('当前目标：' + oneLine(context.goal, 200))
  if (context.todos && context.todos.pending && context.todos.pending.length > 0) {
    lines.push('未完成待办（共 ' + context.todos.total + ' 项，已完成 ' + context.todos.done + ' 项）：')
    context.todos.pending.forEach((item, index) => lines.push('  ' + (index + 1) + '. ' + oneLine(item, 120)))
  }
  if (context.lastTool) lines.push('中断前最后动作：' + context.lastTool.name + ' ' + oneLine(context.lastTool.arguments, 120))
  if (context.lastError && !(decision.error && decision.error.message === context.lastError.message)) {
    lines.push('最近一次失败：' + oneLine(context.lastError.message, 160) + (context.lastError.code ? '（' + context.lastError.code + '）' : ''))
  }
  if (context.lastUser) lines.push('最近用户要求：' + oneLine(context.lastUser, 240))
  if (context.lastAssistant) lines.push('中断前进度：' + oneLine(context.lastAssistant, 260))
  lines.push('执行要求：')
  lines.push('1. 先检查工作区里已产生的改动与产物，不要重做已完成的步骤；')
  lines.push('2. 按未完成待办的顺序继续推进，每完成一步做最小验证（测试/构建/关键输出）；')
  lines.push('3. 若再次遇到相同错误，先说明原因再换方案，不要反复重试同一动作；')
  lines.push('4. 完成后简要汇报：改了什么、验证结果、遗留风险。')

  let text = lines.join('\n')
  // 超预算：先砍「中断前进度」，再砍「最近用户要求」，最后硬截断。
  if (text.length > maxChars && context.lastAssistant) {
    text = text.replace('\n中断前进度：' + oneLine(context.lastAssistant, 260), '')
  }
  if (text.length > maxChars && context.lastUser) {
    text = text.replace('\n最近用户要求：' + oneLine(context.lastUser, 240), '')
  }
  if (text.length > maxChars) text = text.slice(0, maxChars - 1) + '…'
  const summaryParts = [kindLabel]
  if (context.todos && context.todos.pending.length > 0) summaryParts.push('待办 ' + context.todos.pending.length + ' 项')
  if (context.lastError && context.lastError.code) summaryParts.push(context.lastError.code)
  return { text, summary: summaryParts.join(' · '), chars: text.length }
}
