import test from 'node:test'
import assert from 'node:assert/strict'
import { createFeed, publicConfig } from '../lib/notify.js'
import { normalizeConfig } from '../lib/policy.js'

test('提醒流：游标单调递增，since 只返回增量', () => {
  const feed = createFeed()
  const a = feed.push({ id: 'a', stage: 'detected' })
  const b = feed.push({ id: 'b', stage: 'detected' })
  assert.equal(a.cursor, 1)
  assert.equal(b.cursor, 2)
  const first = feed.since(0)
  assert.equal(first.cursor, 2)
  assert.equal(first.alerts.length, 2)
  const next = feed.since(2)
  assert.equal(next.alerts.length, 0)
  feed.update('a', { stage: 'resumed' })
  const changed = feed.since(2)
  assert.equal(changed.alerts.length, 1)
  assert.equal(changed.alerts[0].stage, 'resumed')
  assert.equal(changed.cursor, 3)
})

test('提醒流：超过上限淘汰最旧的', () => {
  const feed = createFeed({ max: 2 })
  feed.push({ id: 'a' })
  feed.push({ id: 'b' })
  feed.push({ id: 'c' })
  assert.equal(feed.get('a'), null)
  assert.ok(feed.get('c'))
})

test('公开配置只暴露浏览器需要的字段', () => {
  const config = normalizeConfig({ notifyOs: false, toastDurationMs: 999999 })
  const pub = publicConfig(config)
  assert.deepEqual(Object.keys(pub).sort(), ['notifyGui', 'notifyOs', 'toastDurationMs'])
  assert.equal(pub.notifyOs, false)
  assert.equal(pub.toastDurationMs, 60000)
})
