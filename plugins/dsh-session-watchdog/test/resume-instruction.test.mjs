import test from 'node:test'
import assert from 'node:assert/strict'
import { buildHandoffBrief, buildInstructionSummary, buildContextInstruction, generateResumeInstruction } from '../lib/resume-instruction.js'
import { extractContext, extractConversation } from '../lib/context.js'

const ev = (type, data, at = 0) => ({ type, data, at })

function fixtureEvents() {
  return [
    ev('session/title', { title: '订单模块重构' }),
    ev('turn/start', { turn: 2 }),
    ev('user/message', { id: 'u1', role: 'user', content: [{ type: 'text', text: '把订单模块拆成 service 和 repo 两层，并补单测' }], source: { kind: 'user' } }),
    ev('assistant/message', { turn: 2, step: 1, message: { id: 'a1', role: 'assistant', content: [{ type: 'text', text: '已拆出 order.service.ts，正在改 order.repo.ts 和 orders.test.ts' }] } }),
    ev('todo/write', { todos: [{ content: '拆分 service', status: 'completed' }, { content: '补 orders.test.ts', status: 'pending' }] }),
    ev('tool/call', { turn: 2, step: 1, callId: 'c1', name: 'edit', arguments: '{\"file_path\":\"order.repo.ts\"}' }),
    ev('turn/end', { turn: 2, reason: { kind: 'error', error: { message: 'rate limited', code: 'QUOTA' } } }),
  ]
}

function buildInput(overrides = {}) {
  const events = fixtureEvents()
  return {
    decision: { kind: 'error', error: { message: 'rate limited', code: 'QUOTA' } },
    context: extractContext({ events, title: '', cwd: 'F:\\开发\\orders' }),
    conversation: extractConversation(events),
    config: { resumePromptMode: 'context' },
    ...overrides,
  }
}

test('对话摘录：拿到真实用户/助手原文且按时间排序', () => {
  const conversation = extractConversation(fixtureEvents())
  assert.equal(conversation.messages.length, 2)
  assert.equal(conversation.messages[0].role, 'user')
  assert.match(conversation.messages[0].text, /订单模块/)
  assert.equal(conversation.messages[1].role, 'assistant')
  assert.match(conversation.messages[1].text, /order.service.ts/)
})

test('交接简报包含会话实际内容（标题/目录/待办/对话原文/工具与错误）', () => {
  const input = buildInput()
  const brief = buildHandoffBrief(input)
  assert.match(brief, /订单模块重构/)
  assert.match(brief, /F:\\开发\\orders/)
  assert.match(brief, /补 orders.test.ts/)
  assert.match(brief, /把订单模块拆成 service 和 repo 两层/)
  assert.match(brief, /order.service.ts/)
  assert.match(brief, /edit/)
  assert.match(brief, /rate limited/)
})

test('上下文模式：指令来自真实记录，不是固定模板', () => {
  const input = buildInput()
  const text = buildContextInstruction(buildHandoffBrief(input))
  assert.match(text, /【会话交接记录】/)
  assert.match(text, /订单模块重构/)
  assert.match(text, /补 orders.test.ts/)
})

test('llm 模式：使用模型输出作为续跑指令，并清理围栏/引号', async () => {
  const llm = {
    async prepareCall(config) {
      return {
        config: { provider: config.provider, model: config.model },
        stream: async function* () {
          yield { type: 'text-delta', text: '```\n' }
          yield { type: 'text-delta', text: '继续把 orders.test.ts 补完，' }
          yield { type: 'text-delta', text: '然后跑 npm test 验证 order.repo.ts 的改动。' }
        },
      }
    },
  }
  const input = buildInput({ llm, provider: 'deepseek', model: 'deepseek-chat', config: { resumePromptMode: 'llm' } })
  const result = await generateResumeInstruction(input)
  assert.equal(result.source, 'llm')
  assert.equal(result.text, '继续把 orders.test.ts 补完，然后跑 npm test 验证 order.repo.ts 的改动。')
  assert.doesNotMatch(result.text, /```/)
})

test('llm 不可用 / 输出为空 / 抛错 → 回落真实上下文拼装', async () => {
  const base = buildInput({ config: { resumePromptMode: 'llm' } })
  const noProvider = await generateResumeInstruction(base)
  assert.equal(noProvider.source, 'context')
  assert.equal(noProvider.error, 'llm-unavailable')
  assert.match(noProvider.text, /【会话交接记录】/)

  const empty = await generateResumeInstruction({
    ...base,
    provider: 'p',
    model: 'm',
    llm: { prepareCall: async () => ({ config: {}, stream: async function* () { yield { type: 'text-delta', text: '' } } }) },
  })
  assert.equal(empty.source, 'context')
  assert.equal(empty.error, 'llm-empty-output')

  const failing = await generateResumeInstruction({
    ...base,
    provider: 'p',
    model: 'm',
    llm: { prepareCall: async () => { throw new Error('provider down') } },
  })
  assert.equal(failing.source, 'context')
  assert.match(failing.error, /provider down/)
  assert.match(failing.text, /订单模块重构/)
})

test('正常完成摘要不再携带历史工具错误码（避免 CODE_RUN_FAILED 误导）', () => {
  const input = buildInput()
  const summary = buildInstructionSummary(input.context, { kind: 'completed' })
  assert.equal(summary, '正常完成')
  assert.doesNotMatch(summary, /CODE_RUN_FAILED|QUOTA/)
})

test('摘要来自真实待办/错误，而不是固定文案', () => {
  const input = buildInput()
  const summary = buildInstructionSummary(input.context, input.decision)
  assert.match(summary, /执行失败/)
  assert.match(summary, /未完成 1 项/)
  assert.match(summary, /最近工具失败 QUOTA/)
})
