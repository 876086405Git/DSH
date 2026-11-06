import test from 'node:test'
import assert from 'node:assert/strict'
import { extractContext, buildResumePrompt, KIND_LABELS } from '../lib/context.js'

const ev = (type, data, at = 0) => ({ type, data, at })

function sampleEvents() {
  return [
    ev('session/title', { title: '重构订单模块' }),
    ev('turn/start', { turn: 1 }),
    ev('user/message', { id: 'u1', role: 'user', content: [{ type: 'text', text: '把订单模块拆成三个文件并补测试' }], source: { kind: 'user' } }),
    ev('todo/write', { todos: [{ content: '拆分 service', status: 'completed' }, { content: '补单测', status: 'pending' }, { content: '跑构建', status: 'pending' }] }),
    ev('goal/change', { goal: { objective: '完成订单模块重构', phase: 'active' } }),
    ev('assistant/message', { turn: 1, step: 1, message: { id: 'a1', role: 'assistant', content: [{ type: 'text', text: '已拆分 service，正在补单测' }] } }),
    ev('tool/call', { turn: 1, step: 1, callId: 'c1', name: 'write', arguments: '{"file_path":"orders.test.ts"}' }),
    ev('tool/result', { turn: 1, step: 1, message: { isError: true, content: [{ type: 'text', text: 'ENOENT: no such file' }] }, error: { code: 'TOOL_ERROR' } }),
    ev('turn/end', { turn: 1, reason: { kind: 'error', error: { message: '模型请求失败', code: 'QUOTA' } } }),
  ]
}

test('提取：标题 / 目标 / 未完成待办 / 最后用户与助手文本 / 最后工具与错误', () => {
  const context = extractContext({ events: sampleEvents(), title: '', cwd: 'F:\\demo' })
  assert.equal(context.goal, '完成订单模块重构')
  assert.deepEqual(context.todos.pending, ['补单测', '跑构建'])
  assert.equal(context.todos.total, 3)
  assert.equal(context.todos.done, 1)
  assert.equal(context.lastUser, '把订单模块拆成三个文件并补测试')
  assert.equal(context.lastAssistant, '已拆分 service，正在补单测')
  assert.equal(context.lastTool.name, 'write')
  assert.match(context.lastTool.arguments, /orders\.test\.ts/)
  // 终止性错误（turn/end.error）优先于中间的工具失败
  assert.equal(context.lastError.code, 'QUOTA')
  assert.match(context.lastError.message, /模型请求失败/)
})

test('提取：没有 turn/end 错误时回落到最后一次工具失败', () => {
  const events = [
    ev('turn/start', { turn: 1 }),
    ev('tool/call', { turn: 1, step: 1, callId: 'c1', name: 'write', arguments: '{}' }),
    ev('tool/result', { turn: 1, step: 1, message: { isError: true, content: [{ type: 'text', text: 'ENOENT: no such file' }] }, error: { code: 'TOOL_ERROR' } }),
  ]
  const context = extractContext({ events, cwd: 'C:\\w' })
  assert.equal(context.lastError.code, 'TOOL_ERROR')
  assert.match(context.lastError.message, /ENOENT/)
  assert.equal(context.lastTool.name, 'write')
})

test('提取：没有 todo/goal 时给出空结构', () => {
  const context = extractContext({ events: [ev('turn/start', { turn: 1 })], title: 'T', cwd: 'C:\\w' })
  assert.deepEqual(context.todos, { total: 0, done: 0, pending: [] })
  assert.equal(context.goal, '')
  assert.equal(context.title, 'T')
})

test('续跑指令包含原因、待办、要求，并标注错误码', () => {
  const context = extractContext({ events: sampleEvents(), title: '', cwd: 'F:\\demo' })
  const decision = { kind: 'error', error: { message: '模型请求失败', code: 'QUOTA' } }
  const prompt = buildResumePrompt({ context, decision, config: { maxContextChars: 2000 } })
  assert.match(prompt.text, /会话哨兵/)
  assert.match(prompt.text, /执行失败/)
  assert.match(prompt.text, /未完成待办（共 3 项，已完成 1 项）/)
  assert.match(prompt.text, /补单测/)
  assert.match(prompt.text, /不要重做已完成的步骤/)
  assert.match(prompt.summary, /QUOTA/)
})

test('超出预算时裁剪低优先级段落，长度不越界', () => {
  const context = extractContext({ events: sampleEvents(), title: '', cwd: 'F:\\demo' })
  const decision = { kind: 'error', error: { message: 'x', code: 'QUOTA' } }
  const prompt = buildResumePrompt({ context, decision, config: { maxContextChars: 300 } })
  assert.ok(prompt.text.length <= 300, '实际长度 ' + prompt.text.length)
  assert.match(prompt.text, /会话哨兵/)
})

test('未知 kind 使用原值而不是编造标签', () => {
  const prompt = buildResumePrompt({ context: extractContext({}), decision: { kind: 'weird-new-kind' }, config: {} })
  assert.match(prompt.text, /weird-new-kind/)
  assert.equal(KIND_LABELS['weird-new-kind'], undefined)
})
