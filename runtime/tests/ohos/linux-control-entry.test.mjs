import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Context } from '@deepseek-ai/cordis';
import OhSubprocessRuntime from '../../ohos/process/index.mjs';
import { LinuxCommandBackend } from '../../ohos/process/linux-backend.mjs';

test('the actual OH subprocess entry registers a read-only Linux control route', async t => {
  const before = globalThis[Symbol.for('dsh.go.ohos.sim')];
  globalThis[Symbol.for('dsh.go.ohos.sim')] = true;
  const directory = await mkdtemp(join(tmpdir(), 'dsh-linux-entry-')), ctx = new Context(), routes = new Map();
  t.after(async () => { await ctx.fiber.dispose();
    if (before === undefined) delete globalThis[Symbol.for('dsh.go.ohos.sim')]; else globalThis[Symbol.for('dsh.go.ohos.sim')] = before;
    await rm(directory, { recursive: true, force: true }); });
  ctx.provide('webServer', { register(route) { routes.set(route.path, route.handler); return () => routes.delete(route.path); } });
  ctx.provide('connection', { requestRejection() { return undefined; } });
  await ctx.plugin(OhSubprocessRuntime, { workspaceRoots: [directory] });
  assert.equal(typeof routes.get('/dsh-go/v1/linux'), 'function', '922 lacks the actual App-to-Node entry');
  let status, body; const req = { method: 'GET', url: '/dsh-go/v1/linux', headers: {} };
  await routes.get('/dsh-go/v1/linux')(req, { writeHead(code) { status = code; }, end(bytes) { body = JSON.parse(bytes); } });
  assert.equal(status, 200); assert.equal(body.state, 'disabled'); assert.equal(body.admission, false);
  assert.equal(body.ownerRetained, false); assert.equal(body.attemptId, null); assert.equal(body.workspaceLease, false);
  // 940: the owner installs the Linux command backend; it exports only this runtime's roots and installs nothing.
  const linux = ctx.subprocess.backend.linux, { realpath } = await import('node:fs/promises');
  assert.ok(linux instanceof LinuxCommandBackend);
  assert.equal(ctx.subprocess.capabilities.pluginProcesses.linux, true);
  assert.deepEqual(ctx.subprocess.linux.exports.map(item => item.path), [ctx.subprocess.temporaryRoot, await realpath(directory)]);
});
