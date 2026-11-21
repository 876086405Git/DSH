// These are actual patched-engine tests, with synthetic provider responses.
// No prefix means NOT_RUN; a zero Node exit status after skips is not a pass.
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { createFixture, assertNoRealNetwork } from './fixtures/companion-recall-engine.mjs';
import { golden, phoneHttp, phoneEnvelope, sendPhone, assertPhoneWire } from './fixtures/companion-phone-replay.mjs';

const integration = (name, run) => test(name, { concurrency: false, timeout: 30000,
  skip: !process.env.DSH_PREFIX && 'Set DSH_PREFIX to the actual patched runtime; otherwise NOT_RUN',
}, run);

integration('fixture 7 shared golden reaches actual engine bytes and same HTTP entry rejects a replaced actual Agent', async t => {
  const entered = Promise.withResolvers(), release = Promise.withResolvers();
  let hold = false, captured;
  t.after(() => release.resolve());
  const f = await createFixture({ async resolveAgent(id, { agent }) {
    if (hold) { hold = false; captured = agent; entered.resolve(); await release.promise; }
    return { agent };
  } });
  t.after(() => f.dispose());
  assert.equal(f.ctx.llm.dshGoPhoneMemory, true);
  const http = await phoneHttp(f); t.after(() => http.close());
  const endpoint = http.url;
  await f.saveMemory('R07_LEGACY_NOT_SELECTED', { pinned: true, keywords: ['长笛'] });
  const old = await f.createAgent('R07_SAME_ENTRY');
  const capability = await http.request(old.agent.id);
  assert.equal(capability.status, 200);
  assert.equal((await http.request(phoneEnvelope(capability.body, 'selected'))).status, 200);
  await sendPhone(f, old.agent, 'selected');
  assert.equal(f.requests.length, 1); assertPhoneWire(f.requests[0].body, true, golden.query);
  // Leave a real unclaimed lease, then block the actual resolver for another POST.
  assert.equal((await http.request(phoneEnvelope(capability.body, 'unclaimed'))).status, 200);
  hold = true;
  const posting = http.request(phoneEnvelope(capability.body, 'late-old-resolver'));
  await entered.promise; assert.equal(captured, old.agent);
  await old.dispose();
  assert.equal(f.ctx.agents.get(old.agent.id), undefined);
  const replacement = await f.createAgent(old.agent.id);
  assert.notEqual(replacement.agent, old.agent);
  assert.notEqual(replacement.agent.session, old.agent.session);
  release.resolve();
  const rejected = await posting;
  assert.equal(rejected.status, 409); assert.equal(rejected.body.error.code, 'companion/session-unavailable');
  assert.equal(f.requests.length, 1);
  const fresh = await http.request(replacement.agent.id);
  assert.equal(fresh.status, 200); assert.equal(http.url, endpoint);
  assert.equal(fresh.body.instanceId, capability.body.instanceId, 'The Host did not restart');
  assert.equal(fresh.body.memoryMode, 'query', 'The replacement did not inherit phone ownership or its lease');
  assert.throws(() => f.promptContext.prepare(old.agent, phoneEnvelope(capability.body, 'retired')),
    error => error.code === 'companion/session-unavailable');
  const empty = phoneEnvelope(fresh.body, 'unclaimed', true);
  assert.equal((await http.request(empty)).status, 200);
  await sendPhone(f, replacement.agent, empty.requestId, golden.empty_query);
  assert.equal(f.requests.length, 2); assertPhoneWire(f.requests[1].body, false, golden.empty_query);
  assertNoRealNetwork(f);
});

integration('fixture 7 actual process restart rejects old instance and never restores phone data into final requests', async t => {
  const home = await mkdtemp(join(tmpdir(), 'dsh-go-phone-restart-'));
  t.after(() => rm(home, { recursive: true, force: true }));
  const checkpoint = join(home, 'synthetic-phone-checkpoint.json');
  const firstPath = join(home, 'first-result.json'), secondPath = join(home, 'second-result.json');
  const worker = fileURLToPath(new URL('./fixtures/companion-phone-restart.mjs', import.meta.url));
  const execute = promisify(execFile);
  await execute(process.execPath, [worker, 'first', home, checkpoint, firstPath], { timeout: 14000, maxBuffer: 256 * 1024 });
  await execute(process.execPath, [worker, 'second', home, checkpoint, secondPath], { timeout: 14000, maxBuffer: 256 * 1024 });
  const first = JSON.parse(await readFile(firstPath, 'utf8'));
  const second = JSON.parse(await readFile(secondPath, 'utf8'));
  assert.notEqual(first.pid, second.pid); assert.notEqual(first.instanceId, second.instanceId);
  assert.equal(first.sessionId, second.sessionId);
  assert.equal(second.oldInstanceStatus, 409); assert.equal(second.oldInstanceCode, 'companion/context-restarted');
  assert.equal(second.seededUpgradeCode, 'companion/memory-context-stale');
  assert.equal(first.requests.length, 1); assert.equal(second.requests.length, 2);
  assertPhoneWire(first.requests[0], true, golden.query);
  for (const body of second.requests) assertPhoneWire(body, false, golden.empty_query);
});
