/**
 * 浏览器半侧冒烟：确认 client.js 能在 ModuleLoader 契约下注册、apply 不抛错。
 * 不做 DOM 渲染（真机行为需重启桌面版验证）。
 */
import test from 'node:test'
import assert from 'node:assert/strict'

test('client.js：ModuleLoader 注册 + 缺少 uiSession 时不抛错', async () => {
  let declaration = null
  globalThis.window = { __ModuleLoader__: { load(decl) { declaration = decl } } }
  await import('../lib/client.js')
  assert.ok(declaration, '未调用 __ModuleLoader__.load')
  assert.equal(declaration.id, 'dsh-session-watchdog')
  assert.equal(typeof declaration.factory, 'function')
  const exported = declaration.factory(() => { throw new Error('base module unavailable') })
  assert.deepEqual(exported.inject, ['uiSession'])
  assert.equal(typeof exported.apply, 'function')
  // 没有 uiSession、没有 ctx.inject：必须静默降级，不抛错
  assert.doesNotThrow(() => exported.apply({}))
  // ctx.inject 存在但服务晚到：也不能抛错
  assert.doesNotThrow(() => exported.apply({ inject() {} }))
  delete globalThis.window
})
