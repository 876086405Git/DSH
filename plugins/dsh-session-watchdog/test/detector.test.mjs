import test from 'node:test'
import assert from 'node:assert/strict'
import { createDetector, DEFAULT_STALL_TIMEOUT_MS, DEFAULT_TOOL_STALL_TIMEOUT_MS } from '../lib/detector.js'

function session(id = 'session-a', header = {}) {
  return { id, header: { id, ...header } }
}
function event(type, data, time) {
  return { type, data, time: time ?? Date.now() }
}

test('turn 生命周期：completed 只产生一条正常结束判定', () => {
  const d = createDetector()
  const s = session()
  assert.equal(d.observe(s, event('turn/start', { turn: 1 })).length, 0)
  const decisions = d.observe(s, event('turn/end', { turn: 1, reason: { kind: 'completed' } }))
  assert.equal(decisions.length, 1)
  assert.equal(decisions[0].kind, 'completed')
  assert.equal(decisions[0].sessionId, 'session-a')
  assert.equal(decisions[0].turn, 1)
  assert.equal(d.get('session-a').status, 'idle')
  assert.equal(d.get('session-a').openTurn, null)
})

test('error 判定携带已序列化的错误', () => {
  const d = createDetector()
  const s = session()
  d.observe(s, event('turn/start', { turn: 2 }))
  const [decision] = d.observe(s, event('turn/end', { turn: 2, reason: { kind: 'error', error: { message: 'quota exceeded', code: 'QUOTA', status: 429 } } }))
  assert.equal(decision.kind, 'error')
  assert.equal(decision.error.message, 'quota exceeded')
  assert.equal(decision.error.code, 'QUOTA')
  assert.equal(decision.error.status, 429)
})

test('aborted 判定记录取消原因', () => {
  const d = createDetector()
  const s = session()
  d.observe(s, event('turn/start', { turn: 1 }))
  const [decision] = d.observe(s, event('turn/end', { turn: 1, reason: { kind: 'aborted', reason: { kind: 'user' } } }))
  assert.equal(decision.kind, 'aborted')
  assert.equal(decision.cancelCause, 'user')
})

test('会话元数据：origin / title / cwd / 审批计数', () => {
  const d = createDetector()
  const s = session('session-b', { origin: 'subagent', cwd: 'F:\\work' })
  d.observe(s, event('session/title', { title: '重构支付' }))
  d.observe(s, event('approval/asked', { approvalId: 'a1' }))
  d.observe(s, event('turn/start', { turn: 1 }))
  const [decision] = d.observe(s, event('turn/end', { turn: 1, reason: { kind: 'error', error: { message: 'x', code: 'UNKNOWN' } } }))
  assert.equal(decision.title, '重构支付')
  assert.equal(decision.cwd, 'F:\\work')
  assert.equal(decision.origin, 'subagent')
  assert.equal(decision.awaitingUser, true)
})

test('假死判定：静默超时只报一次，打开工具后走宽限阈值', () => {
  let now = 0
  const d = createDetector({ clock: () => now })
  const s = session()
  d.observe(s, event('turn/start', { turn: 1 }))
  now = DEFAULT_STALL_TIMEOUT_MS + 1
  const first = d.tick()
  assert.equal(first.length, 1)
  assert.equal(first[0].kind, 'stalled')
  assert.equal(d.tick().length, 0)

  // 重新开一个会话：有未完成工具调用时，普通阈值到了也不报
  const d2 = createDetector({ clock: () => now })
  const s2 = session('session-c')
  d2.observe(s2, event('turn/start', { turn: 1 }))
  d2.observe(s2, event('tool/call', { turn: 1, step: 1, callId: 'c1', name: 'bash', arguments: '{}' }))
  now += DEFAULT_STALL_TIMEOUT_MS + 1
  assert.equal(d2.tick().length, 0)
  now += DEFAULT_TOOL_STALL_TIMEOUT_MS
  const late = d2.tick()
  assert.equal(late.length, 1)
  assert.equal(late[0].kind, 'stalled')
})

test('工具调用关闭后不再享受宽限', () => {
  let now = 0
  const d = createDetector({ clock: () => now })
  const s = session()
  d.observe(s, event('turn/start', { turn: 1 }))
  d.observe(s, event('tool/call', { turn: 1, step: 1, callId: 'c1', name: 'bash', arguments: '{}' }))
  d.observe(s, event('tool/result', { turn: 1, step: 1, message: { isError: false }, callId: 'c1' }))
  now = DEFAULT_STALL_TIMEOUT_MS + 1
  assert.equal(d.tick().length, 1)
})

test('工作区事件不推进 turn 判定，但会刷新心跳', () => {
  let now = 0
  const d = createDetector({ clock: () => now })
  const s = session()
  d.observe(s, event('turn/start', { turn: 1 }))
  now = DEFAULT_STALL_TIMEOUT_MS - 1000
  d.observe(s, event('tool/result', { turn: 1, step: 1, message: { isError: false } }))
  now += 500
  assert.equal(d.tick().length, 0)
})

test('持久化恢复：上次未闭合 turn → interrupted，并可从状态重建', () => {
  const d = createDetector()
  const decisions = d.restore([{ sessionId: 'session-x', title: 'T', cwd: 'C:\\w', origin: '', openTurn: 3, lastEventAt: 1, turnStartedAt: 1 }], { savedAt: 1000 })
  assert.equal(decisions.length, 1)
  assert.equal(decisions[0].kind, 'interrupted')
  assert.equal(decisions[0].turn, 3)
  assert.equal(decisions[0].savedAt, 1000)
  const kept = d.persistable()
  assert.equal(kept.length, 1)
  assert.equal(kept[0].openTurn, 3)
})

test('持久化恢复：已闭合会话不产生判定', () => {
  const d = createDetector()
  const decisions = d.restore([{ sessionId: 'session-y', openTurn: null, lastEventAt: 1 }], { savedAt: 1 })
  assert.equal(decisions.length, 0)
  assert.equal(d.get('session-y').status, 'idle')
})
