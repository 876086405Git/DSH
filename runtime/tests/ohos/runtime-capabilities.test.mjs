import test from 'node:test';
import assert from 'node:assert/strict';
import { runtimeCapabilities } from '../../ohos/capabilities/snapshot.mjs';
import { capabilities, shellCommands } from '../../ohos/process/commands.mjs';

test('未装服务不能把包内命令表当已装shell，未知原生模块不冒报loaded', () => {
  const result = runtimeCapabilities({ get: () => undefined }, 'test-boot');
  assert.deepEqual(result.shell, { kind: 'none', commands: [], pty: 'unsupported' });
  assert.equal(result.processSpawn, 'unknown');
  assert.equal(result.nodeScripts, 'unknown');
  assert.equal(result.python, 'unknown');
  assert.equal(result.plugins.bundled, 'unknown');
  assert.equal(result.nativeModules, null);
  assert.equal(result.storage.sessionLock, 'unknown');
  assert.equal(result.background.computePermission, 'unknown');
  assert.equal(result.background.resume, 'none');
});

test('实际安装服务的同源命令表、锁范围与卸载状态逐次读取，响应不修改服务', () => {
  const services = new Map([
    ['shell', {}], ['subprocess', { capabilities }],
    ['sessionPersistence', { dshGoRuntimeCapabilities: { sessionLock: 'main-thread' } }],
    ['profileContext', { startedBundles: ['@deepseek-ai/dsh-base'] }],
    ['loader', { entries: () => [{ options: { name: '@deepseek-ai/dsh-tool-bash' }, fiber: { state: 2 } }] }],
  ]);
  const ctx = { get: key => services.get(key) };
  const first = runtimeCapabilities(ctx, 'test-boot');
  assert.equal(first.shell.kind, 'virtual');
  assert.deepEqual(first.shell.commands, shellCommands);
  assert.equal(first.shell.pty, 'unsupported');
  assert.equal(first.processSpawn, 'unsupported');
  assert.equal(first.nodeScripts, capabilities.nodeScripts);
  assert.equal(first.python, 'unsupported');
  assert.equal(first.storage.sessionLock, 'main-thread');
  assert.equal(first.plugins.bundled, 'supported');
  first.shell.commands.push('not-in-backend');
  assert.equal(capabilities.commands.includes('not-in-backend'), false);
  services.delete('subprocess'); services.delete('shell'); services.delete('sessionPersistence');
  const after = runtimeCapabilities(ctx, 'test-boot');
  assert.equal(after.bootId, first.bootId);
  assert.equal(after.shell.kind, 'none');
  assert.equal(after.storage.sessionLock, 'unknown');
});

test('Node Worker协议值逐次读取，未知或未装配入口不冒报可用', () => {
  let nodeScripts = 'worker-rebased';
  const ctx = { get: name => name === 'subprocess' ? { capabilities: { nodeScripts } } : undefined };
  assert.equal(runtimeCapabilities(ctx, 'test-boot').nodeScripts, 'worker-rebased');
  nodeScripts = 'none';
  assert.equal(runtimeCapabilities(ctx, 'test-boot').nodeScripts, 'none');
  nodeScripts = 'workerRebased';
  assert.equal(runtimeCapabilities(ctx, 'test-boot').nodeScripts, 'unknown');
});

test('publication.atomic实时读取，读接口不调用publish或猜测死亡原因', t => {
  const symbol = Symbol.for('dsh.go.ohos.publication');
  const previous = Object.getOwnPropertyDescriptor(globalThis, symbol);
  let atomic = 'untried', publishes = 0;
  Object.defineProperty(globalThis, symbol, { configurable: true, value: {
    protocolVersion: 1, get atomic() { return atomic; }, systemVersion: 'fixture-system-build',
    publish() { publishes++; },
  } });
  t.after(() => { if (previous) Object.defineProperty(globalThis, symbol, previous); else delete globalThis[symbol]; });
  const ctx = { get: () => undefined };
  const first = runtimeCapabilities(ctx, 'test-boot');
  for (const next of ['trying', 'available', 'unsupported', 'disabled-after-crash']) {
    atomic = next;
    assert.deepEqual(runtimeCapabilities(ctx, 'test-boot').publication, { atomic: next, systemVersion: 'fixture-system-build' });
  }
  assert.equal(first.publication.atomic, 'untried');
  assert.equal(publishes, 0);
});

test('生命周期能力每次读取已安装owner，缺失、关闭、持久化故障和异常立即熔断且不执行控制', () => {
  let owner, calls = 0, controls = 0;
  const ctx = { get: name => name === 'ohosLifecycle' ? owner : undefined };
  const read = () => runtimeCapabilities(ctx, 'test-boot').background;
  assert.equal(read().resume, 'none');
  let state = { v: 1, closed: false, blocked: false, state: 'result-unknown' };
  owner = { protocolVersion: 1, status() { calls++; return state; },
    pause() { controls++; }, resume() { controls++; }, acknowledgeUnknown() { controls++; } };
  assert.deepEqual(read(), { policy: 'may-freeze', computePermission: 'unknown', resume: 'reconcile' });
  for (const next of [
    { v: 1, closed: true, blocked: false }, { v: 1, closed: false, blocked: true },
    { v: 2, closed: false, blocked: false }, { v: 1, closed: false }, null,
  ]) { state = next; assert.equal(read().resume, 'none'); }
  state = { v: 1, closed: false, blocked: false }; assert.equal(read().resume, 'reconcile');
  owner = { protocolVersion: 2, status() { throw new Error('unsupported owner should not be called'); } };
  assert.equal(read().resume, 'none');
  owner = { protocolVersion: 1, status() { throw new Error('broken service'); } };
  assert.equal(read().resume, 'none');
  owner = undefined; assert.equal(read().resume, 'none');
  assert.equal(calls, 7); assert.equal(controls, 0);
});
