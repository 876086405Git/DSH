// Invoked only by the offline test in two separate OS processes. The checkpoint
// contains synthetic Session events and an old envelope, never provider secrets.
import assert from 'node:assert/strict';
import { readFile, writeFile } from 'node:fs/promises';
import { createFixture, assertNoRealNetwork } from './companion-recall-engine.mjs';
import { golden, phoneHttp, phoneEnvelope, sendPhone, assertPhoneWire } from './companion-phone-replay.mjs';

const [stage, home, checkpoint, result] = process.argv.slice(2);
assert(['first', 'second'].includes(stage));
const f = await createFixture({ home, keepHome: true });
let http;
try {
  assert.equal(f.ctx.llm.dshGoPhoneMemory, true);
  http = await phoneHttp(f);
  if (stage === 'first') {
    await f.saveMemory('R07_LEGACY_NOT_SELECTED', { pinned: true, keywords: ['长笛'] });
    const { agent } = await f.createAgent('R07_RESTART');
    const capability = await http.request(agent.id);
    assert.equal(capability.status, 200);
    const envelope = phoneEnvelope(capability.body, 'before-process-exit');
    assert.equal((await http.request(envelope)).status, 200);
    await sendPhone(f, agent, envelope.requestId);
    assert.equal(f.requests.length, 1);
    assertPhoneWire(f.requests[0].body, true, golden.query);
    const seed = agent.session.snapshotEvents(f.engine.session.SessionLogOffset(0));
    for (const card of golden.cards) assert(!JSON.stringify(seed).includes(card.text));
    await writeFile(checkpoint, JSON.stringify({ envelope, seed }));
    await writeFile(result, JSON.stringify({ pid: process.pid, instanceId: envelope.instanceId,
      sessionId: agent.id, requests: f.requests.map(request => request.body) }));
  } else {
    const saved = JSON.parse(await readFile(checkpoint, 'utf8'));
    const { agent } = await f.createAgent(saved.envelope.sessionId, { seed: saved.seed });
    assert.equal(f.ctx.agents.get(agent.id), agent, 'Restore the actual target before checking an old instance');
    const capability = await http.request(agent.id);
    assert.equal(capability.status, 200);
    assert.notEqual(capability.body.instanceId, saved.envelope.instanceId);
    const old = await http.request(saved.envelope);
    assert.equal(old.status, 409); assert.equal(old.body.error.code, 'companion/context-restarted');
    const upgraded = await http.request(phoneEnvelope(capability.body, 'attempt-seeded-upgrade'));
    assert.equal(upgraded.status, 409); assert.equal(upgraded.body.error.code, 'companion/memory-context-stale');
    assert.equal(f.requests.length, 0);
    await sendPhone(f, agent, 'plain-replayed-history', golden.empty_query);
    assert.equal(f.requests.length, 1);
    assertPhoneWire(f.requests[0].body, false, golden.empty_query);
    const { agent: clean } = await f.createAgent('R07_AFTER_RESTART_CLEAN');
    const fresh = await http.request(clean.id);
    assert.equal(fresh.status, 200);
    const envelope = phoneEnvelope(fresh.body, 'explicit-empty-after-restart', true);
    assert.equal((await http.request(envelope)).status, 200);
    await sendPhone(f, clean, envelope.requestId, golden.empty_query);
    assert.equal(f.requests.length, 2);
    assertPhoneWire(f.requests[1].body, false, golden.empty_query);
    await writeFile(result, JSON.stringify({ pid: process.pid, instanceId: capability.body.instanceId,
      sessionId: agent.id, oldInstanceStatus: old.status, oldInstanceCode: old.body.error.code,
      seededUpgradeCode: upgraded.body.error.code, requests: f.requests.map(request => request.body) }));
  }
  assertNoRealNetwork(f);
} finally {
  await http?.close();
  await f.dispose();
}
