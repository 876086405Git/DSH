import test from 'node:test'
import assert from 'node:assert/strict'
import { createPolicy, normalizeConfig, DEFAULT_CONFIG } from '../lib/policy.js'

function decision(overrides = {}) {
  return {
    id: 'session-a#1#error',
    sessionId: 'session-a',
    turn: 1,
    kind: 'error',
    source: 'turn-end',
    cwd: 'F:\\开发\\demo',
    error: { message: 'boom', code: 'QUOTA' },
    at: Date.now(),
    ...overrides,
  }
}

test('配置归一化：类型错误回落默认，数值夹到区间内', () => {
  const config = normalizeConfig({ autoResume: 'yes', maxResumesPerSession: 999, resumeWindowMs: 1, unknownField: 42 })
  assert.equal(config.autoResume, DEFAULT_CONFIG.autoResume)
  assert.equal(config.maxResumesPerSession, 50)
  assert.equal(config.resumeWindowMs, 60 * 1000)
  assert.equal(config.unknownField, 42)
})

test('completed 默认提醒但不续跑；aborted 默认不提醒；aborted 可配置提醒', () => {
  const config = normalizeConfig({})
  const p = createPolicy(config)
  const done = p.decide(decision({ id: 'a#1#completed', kind: 'completed' }))
  assert.equal(done.notify, true)
  assert.equal(done.resume, false)
  const muted = createPolicy(normalizeConfig({ notifyOnCompletion: false })).decide(decision({ id: 'a#1#completed', kind: 'completed' }))
  assert.equal(muted.notify, false)
  assert.equal(muted.reason, 'completion-muted')
  assert.equal(p.decide(decision({ id: 'a#2#aborted', kind: 'aborted' })).notify, false)
  const p2 = createPolicy(normalizeConfig({ notifyOnAborted: true }))
  assert.equal(p2.decide(decision({ id: 'a#2#aborted', kind: 'aborted' })).notify, true)
})

test('子代理会话默认不监控，纳入后可监控', () => {
  const d = decision()
  assert.equal(createPolicy(normalizeConfig({})).decide(d, { origin: 'subagent' }).notify, false)
  assert.equal(createPolicy(normalizeConfig({ monitorSubagents: true })).decide(d, { origin: 'subagent' }).notify, true)
})

test('cwd 包含/排除与指定会话排除', () => {
  const excluded = createPolicy(normalizeConfig({ excludeCwd: ['F:\\开发\\demo'] }))
  assert.equal(excluded.decide(decision()).notify, false)
  const included = createPolicy(normalizeConfig({ includeCwd: ['F:\\其它'] }))
  assert.equal(included.decide(decision()).notify, false)
  const inScope = createPolicy(normalizeConfig({ includeCwd: ['F:\\开发'] }))
  assert.equal(inScope.decide(decision()).notify, true)
  const byId = createPolicy(normalizeConfig({ excludeSessionIds: ['session-a'] }))
  assert.equal(byId.decide(decision()).notify, false)
})

test('幂等：同一判定重复到来只处理一次', () => {
  const p = createPolicy(normalizeConfig({}))
  const d = decision()
  const first = p.decide(d)
  assert.equal(first.notify, true)
  assert.equal(first.resume, true)
  const second = p.decide(d)
  assert.equal(second.notify, false)
  assert.equal(second.reason, 'duplicate')
})

test('自动续跑：awaitingUser / cwd 不存在时只提醒', () => {
  const p = createPolicy(normalizeConfig({}))
  const waiting = p.decide(decision({ id: 'a#1#error' }), { awaitingUser: true })
  assert.equal(waiting.notify, true)
  assert.equal(waiting.resume, false)
  assert.equal(waiting.reason, 'awaiting-user')
  const missing = p.decide(decision({ id: 'a#2#error' }), { cwdOk: false })
  assert.equal(missing.resume, false)
  assert.equal(missing.reason, 'cwd-missing')
})

test('每会话续跑预算：2 次/窗口后只提醒', () => {
  const p = createPolicy(normalizeConfig({ maxResumesPerSession: 2 }))
  assert.equal(p.decide(decision({ id: 'a#1#error' })).resume, true)
  assert.equal(p.decide(decision({ id: 'a#2#error' })).resume, true)
  const third = p.decide(decision({ id: 'a#3#error' }))
  assert.equal(third.notify, true)
  assert.equal(third.resume, false)
  assert.equal(third.reason, 'session-budget')
})

test('全局预算：跨会话共享 2 次续跑', () => {
  const p = createPolicy(normalizeConfig({ globalBudget: 2 }))
  assert.equal(p.decide(decision({ id: 'a#1#error', sessionId: 'a' })).resume, true)
  assert.equal(p.decide(decision({ id: 'b#1#error', sessionId: 'b' })).resume, true)
  const blocked = p.decide(decision({ id: 'c#1#error', sessionId: 'c' }))
  assert.equal(blocked.resume, false)
  assert.equal(blocked.reason, 'global-budget')
})

test('熔断：连续失败达到阈值后不再自动续跑', () => {
  const p = createPolicy(normalizeConfig({ maxConsecutiveFailures: 2 }))
  p.recordResult('session-a', false)
  p.recordResult('session-a', false)
  const result = p.decide(decision({ id: 'a#9#error' }))
  assert.equal(result.notify, true)
  assert.equal(result.resume, false)
  assert.equal(result.reason, 'circuit-open')
  p.clearSession('session-a')
  assert.equal(p.decide(decision({ id: 'a#10#error' })).resume, true)
})

test('turn/end 判定即使读到 agent 仍 running 也允许续跑（真实时序）', () => {
  const p = createPolicy(normalizeConfig({}))
  const result = p.decide(decision(), { agentStatus: 'running' })
  assert.equal(result.notify, true)
  assert.equal(result.resume, true)
})

test('启动扫描（历史遗留）默认只提醒，不惊动旧会话', () => {
  const d = decision({ id: 'old#1#interrupted', kind: 'interrupted', source: 'startup-scan' })
  const p = createPolicy(normalizeConfig({}))
  const result = p.decide(d)
  assert.equal(result.notify, true)
  assert.equal(result.resume, false)
  assert.equal(result.reason, 'startup-scan')
  const allowed = createPolicy(normalizeConfig({ resumeOnStartupScan: true }))
  assert.equal(allowed.decide(d).resume, true)
})

test('stalled 默认只提醒，开启 resumeOnStall 后能续跑', () => {
  const stall = decision({ id: 'a#1#stalled', kind: 'stalled' })
  const base = createPolicy(normalizeConfig({}))
  const only = base.decide(stall)
  assert.equal(only.notify, true)
  assert.equal(only.resume, false)
  assert.equal(only.reason, 'kind-not-resumable')
  const resuming = createPolicy(normalizeConfig({ resumeOnStall: true, resumeKinds: [] }))
  assert.equal(resuming.decide(stall).resume, true)
})

test('策略状态可序列化并恢复（重启后不重复续跑）', () => {
  const p = createPolicy(normalizeConfig({}))
  p.decide(decision({ id: 'a#1#error' }))
  const snapshot = p.snapshot()
  const restored = createPolicy(normalizeConfig({}))
  restored.restore(snapshot)
  const again = restored.decide(decision({ id: 'a#1#error' }))
  assert.equal(again.notify, false)
  assert.equal(again.reason, 'duplicate')
})

test('禁用开关关闭一切', () => {
  const p = createPolicy(normalizeConfig({ enabled: false }))
  const result = p.decide(decision())
  assert.equal(result.notify, false)
  assert.equal(result.reason, 'disabled')
})
