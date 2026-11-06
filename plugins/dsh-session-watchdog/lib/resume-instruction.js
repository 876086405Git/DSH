/**
 * 会话哨兵 —— 续跑指令生成。
 *
 * 两种模式（settings 里的「续跑指令生成方式」）：
 *   llm     —— 把真实会话内容交给当前会话所用的模型，生成一条承接上下文的续跑指令（默认，失败自动回落）
 *   context —— 不上模型，直接用真实对话原文 + 未完成事项拼装成上下文交接说明
 *
 * 两者都以「对应会话的实际内容」为唯一事实来源：对话原文、未完成 todo、当前目标、
 * 最后工具动作、最后错误、工作目录；不再使用固定文案。
 */
import { buildResumePrompt, KIND_LABELS } from './context.js'

/** 续跑指令的系统提示：要求基于真实记录、不复述模板、不编造。 */
const SYSTEM_PROMPT = [
  '你是 DeepSeek Harness 的会话哨兵，负责在会话中断后帮用户续跑。',
  '你会收到一段真实会话交接记录：会话标题、工作目录、中断原因、当前目标、未完成待办、最近对话原文、最后工具动作与错误。',
  '请只依据这些真实内容，写一条可以直接发回该会话的续跑指令（中文，第一人称，像用户本人在说话）。',
  '要求：',
  '1. 明确指出上次进行到哪一步、下一步要做的具体动作（引用真实文件名/函数名/待办原文，不要泛泛而谈）；',
  '2. 说明哪些已完成的内容不要重做；',
  '3. 给出完成后的最小验证方式；',
  '4. 不要套用空泛模板，不要编造记录里没有的事实，不要输出标题或解释，只输出指令正文；',
  '5. 不超过 400 字。',
].join('\n')

/** 把真实记录整理成交接简报（两种模式共用的底稿）。 */
export function buildHandoffBrief(input) {
  const context = input.context || {}
  const conversation = input.conversation || { messages: [] }
  const decision = input.decision || {}
  const lines = []
  lines.push('【会话交接记录】')
  lines.push('会话：' + (context.title || '（无标题）') + (context.cwd ? '｜工作目录：' + context.cwd : ''))
  lines.push('中断原因：' + (KIND_LABELS[decision.kind] || decision.kind || '异常停止') + (decision.error && decision.error.message ? '｜' + decision.error.message : ''))
  if (context.goal) lines.push('当前目标：' + context.goal)
  if (context.todos && context.todos.pending && context.todos.pending.length > 0) {
    lines.push('未完成待办（共 ' + context.todos.total + ' 项，已完成 ' + context.todos.done + ' 项）：')
    context.todos.pending.forEach((item, index) => lines.push('  ' + (index + 1) + '. ' + item))
  }
  if (context.lastTool) lines.push('中断前最后动作：' + context.lastTool.name + ' ' + context.lastTool.arguments)
  if (context.lastError) lines.push('最近一次失败：' + (context.lastError.message || '') + (context.lastError.code ? '（' + context.lastError.code + '）' : ''))
  lines.push('最近对话原文（从旧到新）：')
  if (conversation.messages.length === 0) {
    lines.push('  （没有可用的对话记录）')
  } else {
    for (const message of conversation.messages) {
      const role = message.role === 'assistant' ? '助手' : '用户'
      lines.push('  [' + role + '] ' + String(message.text || '').replace(/\s+/g, ' ').trim())
    }
  }
  return lines.join('\n')
}

/** 上下文模式：真实记录 + 一句最小行动要求。 */
export function buildContextInstruction(brief) {
  return brief + '\n\n请基于以上真实记录继续未完成的工作：先确认已产生的改动，不要重做已完成部分；完成后做最小验证并汇报。'
}

/** 简短摘要（提醒卡片用），来自真实记录而不是固定文案。 */
export function buildInstructionSummary(context, decision) {
  const kind = decision.kind || 'unknown'
  // 正常完成的卡片只写「正常完成」：不要把历史工具错误码（如 CODE_RUN_FAILED）当成完成状态，
  // 那会让用户误以为这一轮失败了。错误码只在异常停止时展示，并显式标注是「最近工具失败」。
  if (kind === 'completed') return '正常完成'
  const parts = [KIND_LABELS[kind] || kind || '异常停止']
  if (context.todos && context.todos.pending && context.todos.pending.length > 0) parts.push('未完成 ' + context.todos.pending.length + ' 项')
  if (context.lastError && context.lastError.code) parts.push('最近工具失败 ' + context.lastError.code)
  if (decision.error && decision.error.message && !(context.lastError && context.lastError.message === decision.error.message)) {
    parts.push(String(decision.error.message).slice(0, 60))
  }
  return parts.join(' · ')
}

function abortable(promiseFactory, timeoutMs) {
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), timeoutMs)
  if (typeof timer.unref === 'function') timer.unref()
  return { signal: controller.signal, done: () => clearTimeout(timer) }
}

/** 去掉模型输出里的代码围栏/前后多余引号。 */
function cleanOutput(text) {
  let value = String(text || '').trim()
  value = value.replace(/^\s*```[a-zA-Z]*\s*/g, '').replace(/\s*```\s*$/g, '')
  value = value.replace(/^["'「『]+/, '').replace(/["'」』]+$/, '')
  return value.trim()
}

/**
 * 生成续跑指令。
 * @param {{llm?:any, provider?:string, model?:string, decision:any, context:any, conversation:any, config:any, logger?:any}} input
 * @returns {Promise<{text:string, source:'llm'|'context', error?:string}>}
 */
export async function generateResumeInstruction(input) {
  const config = input.config || {}
  const context = input.context || {}
  const conversation = input.conversation || { messages: [] }
  const decision = input.decision || {}
  const brief = buildHandoffBrief({ context, conversation, decision })
  const fallback = () => ({ text: buildContextInstruction(brief), source: 'context' })

  if (config.resumePromptMode === 'context') return fallback()
  const llm = input.llm
  const provider = typeof input.provider === 'string' ? input.provider : ''
  const model = typeof input.model === 'string' ? input.model : ''
  if (!llm || typeof llm.prepareCall !== 'function' || !provider || !model) {
    return { ...fallback(), error: 'llm-unavailable' }
  }
  const timeoutMs = Number.isFinite(config.resumeLlmTimeoutMs) ? config.resumeLlmTimeoutMs : 20000
  const { signal, done } = abortable(null, timeoutMs)
  try {
    const call = await llm.prepareCall({ provider, model, maxTokens: Number.isFinite(config.resumeLlmMaxOutputTokens) ? config.resumeLlmMaxOutputTokens : 500 }, signal, (controls) => controls)
    if (!call || typeof call.stream !== 'function') return { ...fallback(), error: 'llm-stream-unavailable' }
    const messages = [{ role: 'user', content: [{ type: 'text', text: brief + '\n\n请按系统提示写续跑指令。' }] }]
    const parts = []
    for await (const chunk of call.stream({ ...call.config, messages, system: SYSTEM_PROMPT, signal })) {
      if (chunk && chunk.type === 'text-delta' && typeof chunk.text === 'string') parts.push(chunk.text)
    }
    const text = cleanOutput(parts.join(''))
    if (text.length < 20) return { ...fallback(), error: 'llm-empty-output' }
    const limit = Number.isFinite(config.resumeInstructionMaxChars) ? config.resumeInstructionMaxChars : 1200
    return { text: text.length > limit ? text.slice(0, limit - 1) + '…' : text, source: 'llm' }
  } catch (error) {
    const message = String(error && error.message ? error.message : error)
    try { input.logger?.warn?.('session-watchdog: 续跑指令生成失败，回落上下文拼装：' + message) } catch { /* noop */ }
    return { ...fallback(), error: message }
  } finally {
    done()
  }
}

/** 兼容旧调用：没有模型时用真实内容拼装（等价 context 模式）。 */
export function buildResumeInstructionFallback(input) {
  const context = input && input.context ? input.context : {}
  const conversation = input && input.conversation ? input.conversation : { messages: [] }
  const decision = input && input.decision ? input.decision : {}
  return buildContextInstruction(buildHandoffBrief({ context, conversation, decision }))
}

export { buildResumePrompt }
