// Full engine integration, intentionally outside the default source-test glob.
// Owner execution only. No model account, network, fake Factory or statfs override.
import assert from 'node:assert/strict';
import test from 'node:test';
import { createHash } from 'node:crypto';
import { mkdtemp, readFile, rm, stat } from 'node:fs/promises';
import { join } from 'node:path';
import { ownerPrerequisites, openReceiptHost, createReceiptTask, until } from '../fixtures/companion-receipts-engine.mjs';

async function setup(t) {
  const prerequisite = await ownerPrerequisites();
  if (prerequisite.blocked) {
    if (process.env.COMPANION_J_OWNER_REQUIRED === '1') assert.fail(`BLOCKED: ${prerequisite.blocked}`);
    t.skip(`BLOCKED/NOT_RUN: ${prerequisite.blocked}`); return null;
  }
  const fixtureHome = await mkdtemp(join(prerequisite.parent, 'j-owner-engine-'));
  const hosts = [];
  t.after(async () => {
    try { for (const host of hosts) await host.close(); }
    finally {
      if (process.env.COMPANION_J_OWNER_KEEP === '1') t.diagnostic(`Kept fixture home: ${fixtureHome}`);
      else await rm(fixtureHome, { recursive: true, force: true });
    }
  });
  t.diagnostic(JSON.stringify({ scope: 'OWNER_ENGINE_TEXT_INPUTS', ...prerequisite, fixtureHome }));
  return { fixtureHome, async open(options = {}) {
    const host = await openReceiptHost({ prerequisite, fixtureHome, ...options }); hosts.push(host); return host;
  } };
}
async function approval(host, body) {
  const frame = await until(() => {
    host.checkEvents();
    return host.frames.find(value => value.event === 'approval/request');
  }, 'actual Gateway approval card');
  const snapshot = host.store.snapshot(body.taskId), binding = snapshot.approval;
  assert.equal(snapshot.state, 'waiting'); assert.equal(snapshot.waitReason, 'approval');
  assert.equal(binding.taskRev, 1); assert.equal(binding.stepKey, 'writeSheet');
  assert.equal(binding.eventId, frame.eventId); assert.equal(binding.agentId, frame.agentId);
  assert.notEqual(binding.approvalId, frame.eventId);
  assert.equal(binding.callId, null); assert.equal(frame.request.toolName, 'companion.receipts.writeSheet');
  assert.equal(host.counters.links, 0);
  await assert.rejects(stat(join(host.fixtureHome, 'documents', body.args.outputName)), { code: 'ENOENT' });
  const durable = await host.persisted(binding.agentId);
  assert(durable.events.some(event => event.type === 'turn/start'));
  assert(durable.events.some(event => event.type === 'approval/asked' && event.data.id === binding.approvalId));
  assert(!durable.events.some(event => event.type === 'approval/decided'));
  assert.equal(host.ctx.agents.get(binding.agentId).model.current(), undefined);
  return { frame, binding };
}
function noModel(host) {
  assert.deepEqual(host.ctx.llm.listProviders(), []);
  assert.deepEqual(host.counters.modelCalls, []);
  assert.deepEqual(host.counters.networkCalls, []);
  for (const call of [...host.counters.creates, ...host.counters.resumes]) assert.deepEqual(call.agentOptions, {});
}
async function completed(host, body) {
  const snapshot = await until(() => {
    host.checkEvents(); const value = host.store.snapshot(body.taskId);
    return ['done', 'partial', 'failed', 'unknown'].includes(value.state) && value;
  }, 'J task settled');
  assert.equal(snapshot.state, 'done', JSON.stringify(snapshot));
  assert.equal(snapshot.artifacts.length, 1);
  const record = host.store.read(body.taskId), agent = host.ctx.agents.get(record.execution.agentId);
  await agent.whenIdle();
  assert.equal(record.execution.provider, undefined); assert.equal(record.execution.model, undefined);
  assert(!snapshot.steps.some(step => step.stepKey === 'model'));
  const artifact = snapshot.artifacts[0]; assert.equal(artifact.stepKey, 'writeSheet');
  const result = await host.store.artifactBytes(body.taskId, artifact.artifactId, snapshot.hostExecutionId);
  assert.equal(result.mediaType, 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
  assert.equal(result.bytes.length, artifact.size);
  assert.equal(createHash('sha256').update(result.bytes).digest('hex'), artifact.sha256);
  assert.deepEqual(await readFile(join(host.fixtureHome, 'documents', body.args.outputName)), result.bytes);
  const expected = Array.from({ length: 4 }, (_, i) => [`2026-11-${20 + i}`, `Travel ${i + 1}`, `CNY ${80 + i}.00`,
    `receipt-${i + 1}.txt（第1行；第2行；第3行；完整纯文本；发布前核过原版）`]);
  const { verifyReceiptWorkbook } = await host.loadBridge('receipt-workbook.js');
  assert.equal(verifyReceiptWorkbook(result.bytes, expected).cells, 20);
  const durable = await host.persisted(record.execution.agentId);
  assert.equal(durable.events.filter(event => event.type === 'approval/asked').length, 1);
  assert.equal(durable.events.filter(event => event.type === 'approval/decided' && event.data.outcome === 'allowed-once').length, 1);
  assert.equal(durable.events.filter(event => event.type === 'turn/start').length,
    durable.events.filter(event => event.type === 'turn/end').length);
  assert(!durable.events.some(event => ['model/selection', 'user/message', 'assistant/message'].includes(event.type)));
  noModel(host); return { snapshot, durable, record };
}

test('J owner engine: real Factory, JSONL, original Remote approval and verified XLSX without a model',
  { timeout: 90000, concurrency: false }, async t => {
    const fixture = await setup(t); if (!fixture) return;
    const host = await fixture.open(), body = await createReceiptTask(host, 'engine-allowed');
    const asked = await approval(host, body); await host.answer(asked.frame, 'allowed-once');
    const result = await completed(host, body);
    assert.equal(host.counters.creates.length, 1); assert.equal(host.counters.resumes.length, 0);
    assert.equal(host.counters.links, 1);
    t.diagnostic(JSON.stringify({ taskId: body.taskId, approval: asked.binding, snapshot: result.snapshot }));
  });

test('J owner engine: closed Host and JSONL writer resume the same task Agent without another approval',
  { timeout: 90000, concurrency: false }, async t => {
    const fixture = await setup(t); if (!fixture) return;
    const stageEntered = Promise.withResolvers();
    const first = await fixture.open({ beforeTasks(fs) {
      fs.dshGoStageNotesFile = async (_directory, _name, _bytes, signal) => {
        stageEntered.resolve();
        await new Promise((_, reject) => {
          if (signal.aborted) reject(signal.reason);
          else signal.addEventListener('abort', () => reject(signal.reason), { once: true });
        });
      };
    } });
    const body = await createReceiptTask(first, 'engine-resume');
    const asked = await approval(first, body); await first.answer(asked.frame, 'allowed-once');
    await stageEntered.promise;
    const firstRegistry = first.ctx.agents, firstAgent = first.ctx.agents.get(asked.binding.agentId);
    await first.store.stop(); // Real runner stop drains the turn and disposes its actual Agent handle.
    assert.equal(first.ctx.agents.get(asked.binding.agentId), undefined);
    const oldSnapshot = first.store.snapshot(body.taskId), oldLog = await first.persisted(asked.binding.agentId);
    const oldWrite = oldSnapshot.steps.findLast(step => step.stepKey === 'writeSheet');
    assert.equal(oldWrite.state, 'waiting'); assert.equal(oldWrite.reason, 'publication_not_started');
    assert.equal(oldWrite.result.completion.publicationNotAttempted, true);
    assert.equal(first.counters.links, 0); assert.equal(oldSnapshot.artifacts.length, 0);
    assert.equal(oldLog.events.filter(event => event.type === 'turn/start').length,
      oldLog.events.filter(event => event.type === 'turn/end').length);
    noModel(first);
    await first.close(); // Release Domain/backend ownership before booting another Host.
    const second = await fixture.open();
    assert.notEqual(second.ctx.agents, firstRegistry);
    const result = await completed(second, body);
    assert.equal(second.counters.creates.length, 0); assert.equal(second.counters.resumes.length, 1);
    assert.equal(second.counters.resumes[0].resumeSessionId, asked.binding.agentId);
    assert.notEqual(second.ctx.agents.get(asked.binding.agentId), firstAgent);
    assert.equal(result.record.execution.agentId, asked.binding.agentId);
    assert.equal(result.snapshot.hostStoreId, oldSnapshot.hostStoreId);
    assert.equal(result.snapshot.hostExecutionId, oldSnapshot.hostExecutionId);
    assert.deepEqual(result.snapshot.steps.find(step => step.attemptId === oldWrite.attemptId), oldWrite);
    assert.deepEqual(result.durable.events.slice(0, oldLog.events.length), oldLog.events);
    assert.equal(second.frames.filter(frame => frame.event === 'approval/request').length, 0);
    assert.equal(second.counters.links, 1);
    t.diagnostic(JSON.stringify({ before: oldSnapshot, complete: result.snapshot, resumedAgentId: asked.binding.agentId }));
  });

test('J owner engine: original approval rejection is durable and publishes no workbook',
  { timeout: 90000, concurrency: false }, async t => {
    const fixture = await setup(t); if (!fixture) return;
    const host = await fixture.open(), body = await createReceiptTask(host, 'engine-rejected');
    const asked = await approval(host, body); await host.answer(asked.frame, 'rejected');
    await until(() => host.store.snapshot(body.taskId).waitReason === 'approval_rejected', 'original rejection persisted');
    await host.ctx.agents.get(asked.binding.agentId).whenIdle();
    const snapshot = host.store.snapshot(body.taskId), durable = await host.persisted(asked.binding.agentId);
    assert.equal(snapshot.artifacts.length, 0); assert.equal(host.counters.links, 0);
    assert(!snapshot.steps.some(step => step.stepKey === 'writeSheet'));
    assert.equal(durable.events.filter(event => event.type === 'approval/asked').length, 1);
    assert.equal(durable.events.filter(event => event.type === 'approval/decided' && event.data.outcome === 'rejected').length, 1);
    await assert.rejects(stat(join(host.fixtureHome, 'documents', body.args.outputName)), { code: 'ENOENT' });
    noModel(host);
    t.diagnostic(JSON.stringify({ snapshot, approval: asked.binding }));
  });
