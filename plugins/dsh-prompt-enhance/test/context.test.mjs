import assert from 'node:assert/strict'
import test from 'node:test'
import {
  buildContext,
  clampMessage,
  collectContextMessages,
  extractAssistantText,
  extractText,
  isHumanUserMessage,
  pickPreviousMessage,
  pickRecentMessages,
  renderContext,
} from '../lib/context.js'

const humanUser = (seq, text) => ({
  type: 'user/message',
  seq,
  data: { content: [{ type: 'text', text }], source: { kind: 'user' }, role: 'user' },
})

const injectedUser = (seq, text, kind) => ({
  type: 'user/message',
  seq,
  data: { content: [{ type: 'text', text }], source: { kind }, role: 'user' },
})

const assistant = (seq, text, reasoning) => ({
  type: 'assistant/message',
  seq,
  data: {
    message: {
      role: 'assistant',
      content: [
        ...(reasoning ? [{ type: 'reasoning', text: reasoning }] : []),
        { type: 'text', text },
      ],
    },
  },
})

test('isHumanUserMessage 只认真人输入，排除系统注入', () => {
  assert.equal(isHumanUserMessage(humanUser(1, '你好')), true)
  assert.equal(isHumanUserMessage(injectedUser(1, '快照', 'runtime-context')), false)
  assert.equal(isHumanUserMessage(injectedUser(1, '快照', 'time-context')), false)
  assert.equal(isHumanUserMessage(injectedUser(1, '指令', 'agent-instructions')), false)
  assert.equal(isHumanUserMessage({ type: 'user/message', seq: 1, data: {} }), false)
  assert.equal(isHumanUserMessage(assistant(1, '回复')), false)
})

test('extractText 只拼 text 块，忽略 reasoning', () => {
  assert.equal(extractText([{ type: 'text', text: 'A' }, { type: 'text', text: 'B' }]), 'A\nB')
  assert.equal(extractText([{ type: 'reasoning', text: '思考' }]), '')
  assert.equal(extractText('纯字符串'), '纯字符串')
  assert.equal(extractText(null), '')
})

test('extractAssistantText 取可见正文并丢弃思考过程', () => {
  const event = assistant(1, '最终答案', '内心戏')
  assert.equal(extractAssistantText(event), '最终答案')
  assert.equal(extractAssistantText(humanUser(1, 'x')), '')
})

test('collectContextMessages 按 seq 排序且过滤系统注入', () => {
  const events = [
    injectedUser(1, 'runtime 快照', 'runtime-context'),
    humanUser(2, '第一个问题'),
    assistant(3, '第一个回答'),
    injectedUser(4, 'time 快照', 'time-context'),
    humanUser(5, '第二个问题'),
  ]
  const messages = collectContextMessages(events)
  assert.deepEqual(messages.map((m) => m.role), ['user', 'assistant', 'user'])
  assert.equal(messages[0].text, '第一个问题')
  assert.equal(messages[2].text, '第二个问题')
})

test('collectContextMessages 在事件乱序时仍按 seq 排序', () => {
  const shuffled = [
    humanUser(9, '第三问'),
    assistant(8, '第二答'),
    humanUser(7, '第二问'),
    assistant(6, '第一答'),
    humanUser(5, '第一问'),
  ]
  const messages = collectContextMessages(shuffled)
  assert.deepEqual(messages.map((m) => m.text), ['第一问', '第一答', '第二问', '第二答', '第三问'])
  assert.equal(pickPreviousMessage(messages).text, '第三问')
})

test('pickPreviousMessage 取时间最靠后的一条', () => {
  const messages = collectContextMessages([
    humanUser(1, '问1'),
    assistant(2, '答1'),
    humanUser(3, '问2'),
  ])
  assert.equal(pickPreviousMessage(messages).text, '问2')
  assert.equal(pickPreviousMessage([]), null)
})

test('pickRecentMessages 取末尾 limit 条', () => {
  const messages = collectContextMessages([
    humanUser(1, 'a'), assistant(2, 'b'), humanUser(3, 'c'), assistant(4, 'd'),
  ])
  assert.deepEqual(pickRecentMessages(messages, 2).map((m) => m.text), ['c', 'd'])
  assert.deepEqual(pickRecentMessages(messages, 0), [])
})

test('clampMessage 超长时保留首尾并标记省略', () => {
  const long = 'A'.repeat(500)
  const out = clampMessage(long, 100)
  assert.equal(out.length <= 100, true)
  assert.ok(out.includes('中间已省略'))
  assert.ok(out.startsWith('AAA'))
  assert.ok(out.endsWith('AAA'))
  assert.equal(clampMessage('短', 100), '短')
})

test('renderContext 渲染角色标签', () => {
  const block = renderContext([{ role: 'user', text: '问题' }, { role: 'assistant', text: '回答' }])
  assert.ok(block.includes('[用户]'))
  assert.ok(block.includes('[上一条消息·助手（重点）]'), '最后一条要标重点')
  assert.ok(block.includes('问题'))
  assert.equal(renderContext([]), '')
})

test('renderContext 只把最后一条标成重点', () => {
  const block = renderContext([
    { role: 'user', text: '早先的需求' },
    { role: 'user', text: '中间的需求' },
    { role: 'assistant', text: '这是上一条回复' },
  ])
  const marks = block.split('[上一条消息·').length - 1
  assert.equal(marks, 1, '重点标记只能出现一次')
  assert.ok(block.includes('[上一条消息·助手（重点）]'))
})

test('上一条消息的篇幅上限远大于较早消息', () => {
  const long = 'X'.repeat(5000)
  const block = renderContext([{ role: 'user', text: long }, { role: 'assistant', text: long }])
  const parts = block.split('[上一条消息·助手（重点）]')
  const earlier = parts[0] || ''
  const last = parts[1] || ''
  assert.ok(earlier.length < 1400, '较早消息压缩到 1200 字以内，实际 ' + earlier.length)
  assert.ok(last.length > 3900, '上一条消息保留约 4000 字，实际 ' + last.length)
})

test('buildContext 回报上一条消息文本', () => {
  const events = [humanUser(1, '先做登录页'), assistant(2, '好的，方案是 A/B/C 三步')]
  const { previousText, block } = buildContext(events)
  assert.ok(previousText.includes('A/B/C'))
  assert.ok(block.includes('[上一条消息·助手（重点）]'))
})

test('buildContext 输出 used / previous / block', () => {
  const { previous, block, used } = buildContext([
    humanUser(1, '帮我写个登录页'),
    assistant(2, '好的，登录页如下'),
  ])
  assert.equal(used, true)
  assert.equal(previous.role, 'assistant')
  assert.ok(block.includes('登录页'))
})

test('buildContext 在没有真人对话时 used 为 false', () => {
  const { used, block } = buildContext([injectedUser(1, 'runtime', 'runtime-context')])
  assert.equal(used, false)
  assert.equal(block, '')
})

test('buildContext 对非法输入安全', () => {
  assert.equal(buildContext(null).used, false)
  assert.equal(buildContext([]).used, false)
  assert.equal(buildContext(undefined).used, false)
})
