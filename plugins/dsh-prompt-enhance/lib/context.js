/**
 * dsh-prompt-enhance — 会话上下文抽取（Host 半侧纯函数模块）
 * ----------------------------------------------------------------------------
 * 从会话事件流里挑出「上一条消息」与最近若干轮对话，供提示词增强时保持语义连贯。
 *
 * 关键取舍：
 *   - 只认真实的人机对话（用户输入 + 助手回复），排除系统注入的快照类消息
 *     （runtime-context / time-context / agent-instructions / mnemon 等）；
 *   - 助手消息只取可见正文（text），丢弃 reasoning 思考过程；
 *   - 全部为纯函数（零构建、可直接 node 运行），便于单测与反向插桩。
 */

/**
 * 一条参与上下文的消息。
 * @typedef {{ role: 'user' | 'assistant', text: string }} ContextMessage
 */

/** 抽取上下文时允许的最大消息条数。 */
export const MAX_CONTEXT_MESSAGES = 6
/** 较早消息进入上下文的最大字符数，超出部分从中间省略。 */
export const MAX_CONTEXT_MESSAGE_CHARS = 1200
/** 「上一条消息」是重点分析对象，给更大的篇幅，尽量保留完整细节。 */
export const MAX_LAST_MESSAGE_CHARS = 4000
/** 整个上下文字符上限。 */
export const MAX_CONTEXT_CHARS = 9000

/** 系统注入类 user/message 的 source.kind：这些不是真人输入。 */
const NON_HUMAN_SOURCE_KINDS = new Set([
  'runtime-context',
  'time-context',
  'agent-instructions',
  'developer',
  'system',
  'skill',
  'memory',
  'mnemon',
  'agent-instructions-snapshot',
])

/**
 * 判断一条 user/message 是否来自真人输入。
 * @param {any} event - 会话事件。
 * @returns {boolean} true 表示是用户亲手写的内容。
 */
export function isHumanUserMessage(event) {
  if (!event || event.type !== 'user/message') return false
  const source = event.data && event.data.source
  const kind = source && typeof source.kind === 'string' ? source.kind : ''
  if (kind === '') return false
  return !NON_HUMAN_SOURCE_KINDS.has(kind)
}

/**
 * 把 content 数组里的 text 块拼成纯文本。
 * @param {any} content - 事件里的 content 字段。
 * @returns {string} 拼接后的文本；无文本块时返回空串。
 */
export function extractText(content) {
  if (typeof content === 'string') return content
  if (!Array.isArray(content)) return ''
  const parts = []
  for (const block of content) {
    if (!block || typeof block !== 'object') continue
    if (block.type !== 'text') continue
    if (typeof block.text !== 'string') continue
    parts.push(block.text)
  }
  return parts.join('\n')
}

/**
 * 从 assistant/message 里取可见正文（丢弃 reasoning 与工具调用）。
 * @param {any} event - 会话事件。
 * @returns {string} 正文文本。
 */
export function extractAssistantText(event) {
  if (!event || event.type !== 'assistant/message') return ''
  const message = event.data && event.data.message
  if (!message) return ''
  return extractText(message.content)
}

/**
 * 单条消息超长时，从中间省略，保留首尾。
 * @param {string} text - 原始文本。
 * @param {number} limit - 允许的最大字符数。
 * @returns {string} 截断后的文本。
 */
export function clampMessage(text, limit) {
  if (typeof text !== 'string') return ''
  if (limit <= 0) return ''
  if (text.length <= limit) return text
  const head = Math.floor((limit - 20) / 2)
  const tail = limit - 20 - head
  if (head <= 0 || tail <= 0) return text.slice(0, limit)
  return text.slice(0, head) + '\n…（中间已省略）…\n' + text.slice(text.length - tail)
}

/**
 * 从事件流里抽出用于增强的上下文消息。
 * @param {any[]} events - 会话事件数组（按 seq 排序后取用）。
 * @returns {ContextMessage[]} 按时间先后排列的上下文消息。
 */
export function collectContextMessages(events) {
  if (!Array.isArray(events)) return []
  const ordered = events
    .filter((e) => e && typeof e.seq === 'number')
    .slice()
    .sort((a, b) => a.seq - b.seq)

  const messages = []
  for (const event of ordered) {
    if (event.type === 'user/message') {
      if (!isHumanUserMessage(event)) continue
      const text = extractText(event.data && event.data.content)
      if (text.trim() === '') continue
      messages.push({ role: 'user', text })
    } else if (event.type === 'assistant/message') {
      const text = extractAssistantText(event)
      if (text.trim() === '') continue
      messages.push({ role: 'assistant', text })
    }
  }
  return messages
}

/**
 * 选出「上一条消息」：时间上最靠后的那一条对话消息。
 * @param {ContextMessage[]} messages - collectContextMessages 的结果。
 * @returns {ContextMessage | null} 上一条消息；没有时返回 null。
 */
export function pickPreviousMessage(messages) {
  if (!Array.isArray(messages) || messages.length === 0) return null
  return messages[messages.length - 1]
}

/**
 * 选出最近的若干轮对话用于连贯性参考。
 * @param {ContextMessage[]} messages - collectContextMessages 的结果。
 * @param {number} limit - 最多取几条。
 * @returns {ContextMessage[]} 末尾的若干条消息。
 */
export function pickRecentMessages(messages, limit) {
  if (!Array.isArray(messages) || messages.length === 0) return []
  const max = Number.isFinite(limit) && limit > 0 ? Math.floor(limit) : 0
  if (max === 0) return []
  return messages.slice(-max)
}

/**
 * 把上下文消息渲染成给模型看的文本块。
 *
 * 最后一条（上一条消息）是重点分析对象：用更大的篇幅上限，并单独打标签，
 * 让模型知道要先把它的具体内容读懂，再判断当前输入承接了它的哪一部分。
 * @param {ContextMessage[]} messages - 上下文消息。
 * @returns {string} 文本块；无消息时返回空串。
 */
export function renderContext(messages) {
  if (!Array.isArray(messages) || messages.length === 0) return ''
  const lines = []
  const lastIndex = messages.length - 1
  for (let i = 0; i < messages.length; i += 1) {
    const message = messages[i]
    const who = message.role === 'assistant' ? '助手' : '用户'
    const isLast = i === lastIndex
    lines.push(isLast ? '[上一条消息·' + who + '（重点）]' : '[' + who + ']')
    lines.push(clampMessage(message.text, isLast ? MAX_LAST_MESSAGE_CHARS : MAX_CONTEXT_MESSAGE_CHARS))
    lines.push('')
  }
  return lines.join('\n').trim()
}

/**
 * 生成增强请求里的上下文部分。
 * @param {any[]} events - 会话事件数组。
 * @returns {{ previous: ContextMessage | null, previousText: string, block: string, used: boolean }}
 *   previous：上一条消息；previousText：用于诊断的上一条消息文本；
 *   block：上下文文本块；used：是否真的用上了上下文。
 */
export function buildContext(events) {
  const messages = collectContextMessages(events)
  const previous = pickPreviousMessage(messages)
  const recent = pickRecentMessages(messages, MAX_CONTEXT_MESSAGES)
  const block = renderContext(recent)
  const used = previous !== null && block !== ''
  return {
    previous,
    previousText: previous === null ? '' : clampMessage(previous.text, MAX_LAST_MESSAGE_CHARS),
    block: block.slice(0, MAX_CONTEXT_CHARS),
    used,
  }
}
