import assert from 'node:assert/strict';
import { Context } from '@deepseek-ai/cordis';
import { SystemPrompt } from '@deepseek-ai/dsh-system-prompt';
import { ToolRuntime } from '@deepseek-ai/dsh-tools';
import { mkdtemp, readFile, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomBytes, randomUUID } from 'node:crypto';
import * as phone from '../../../runtime/ios/phone/plugin.mjs';
import { iosToolDescription } from '../../../runtime/ios/phone/descriptions.mjs';
const directory = await mkdtemp(join(tmpdir(), 'ios-phone-registry-'));
const token = randomBytes(32).toString('hex'), runId = randomUUID();
const nativeTest = process._linkedBinding('dsh_ios_phone_test');
assert.equal(nativeTest.arm(runId, token), 0);
const ctx = new Context();
new SystemPrompt(ctx, {});
new ToolRuntime(ctx);
let fiber;
try {
  fiber = await ctx.plugin(phone, { directory, runId });
  const catalog = JSON.parse(await readFile(new URL('../../../runtime/ios/phone/catalog.json', import.meta.url)));
  const schemas = ctx.tools.schemas();
  for (const tool of catalog) {
    const schema = schemas.find(value => value.name === `mcp__phone__${tool.name}`);
    assert.ok(schema, tool.name);
    assert.equal(schema.description, iosToolDescription(tool.name));
    assert.deepEqual(schema.parameters, tool.inputSchema);
  }
  assert.equal(schemas.filter(value => value.name.startsWith('mcp__phone__')).length, 13);
  assert.deepEqual(await readdir(directory), ['endpoint.json']);
  const endpointBytes = await readFile(join(directory, 'endpoint.json'));
  assert.equal(endpointBytes.includes(token), false);
  const endpoint = JSON.parse(endpointBytes);
  assert.throws(() => process._linkedBinding('dsh_ios_phone').consume(runId), /consumed|retired/);
  const post = async (route, value = {}) => {
    const response = await fetch(endpoint.baseUrl + route, { method: 'POST', headers: { authorization: `Bearer ${token}` }, body: JSON.stringify({ runId, ...value }) });
    assert.equal(response.status, 200); return response.json();
  };
  const call = ctx.tools.get('mcp__phone__clipboard').execute({ set: '实际 registry + MCP adapter' }, {
    callId: 'fixture-call', agent: { session: { id: 'fixture-session' } }, signal: new AbortController().signal,
  });
  const { request } = await post('/claim');
  assert.equal(request.action.kind, 'clipboard-set');
  await post('/begin', { id: request.id });
  await post('/result', { id: request.id, text: '用户确认后已写入', isError: false });
  assert.equal((await call).content[0].text, '用户确认后已写入');
  console.log('13 actual ToolRuntime registrations + MCP adapter result PASS; native peer simulated; no full agent turn claimed');
} finally {
  await fiber?.dispose();
  nativeTest.clear(runId);
  assert.equal(ctx.tools.schemas().length, 0);
  await rm(directory, { recursive: true, force: true });
}
