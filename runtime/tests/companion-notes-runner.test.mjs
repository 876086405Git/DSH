import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFile, readdir, writeFile, rename, mkdir, link, stat, unlink} from 'node:fs/promises';
import {join} from 'node:path';
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {fixture, openFixture, until, writeNote, proposal} from './fixtures/companion-notes-runner-fixture.mjs';

const snapshot = f => f.store.snapshot(f.body.taskId);
const terminal = f => ['done', 'partial', 'failed', 'unknown', 'cancelled', 'waiting'].includes(snapshot(f).state);
const output = f => join(f.root, 'notes', f.body.args.outputName);
const launch = async f => {f.start(); await f.store.create(f.body);};

test('SOURCE_INTEGRATION actual ledger, selected files, one model candidate, one no-overwrite artifact', async t => {
  const f = await fixture(t); await launch(f); await until(() => snapshot(f).state === 'done', 'actual artifact');
  await f.store.stop();
  const s = snapshot(f);
  assert.equal(s.artifacts.length, 1); assert.equal(s.artifacts[0].sourceCount, 1);
  assert.equal(f.counters.modelCalls, 1); assert.equal(f.counters.links, 1);
  assert.deepEqual(s.steps.map(value => value.stepKey), ['selectInputs', 'readInputs', 'model', 'writePage']);
  assert(s.steps.every(value => value.state === 'done'));
  const page = await f.store.artifact(f.body.taskId, s.artifacts[0].artifactId);
  assert.equal(page.status, 'available'); assert.match(page.content, /周五配镜/);
  assert.match(page.content, /完整读回 1 份，列出 1 项/);
  const receipt = s.steps[2].result.completion.usage;
  assert.equal(receipt.output_tokens, 13); assert.equal(receipt.input_uncached, null);
  assert.equal(receipt.start_usage.input_tokens, 17);
  assert.equal(JSON.stringify(s).includes('随手记录'), false);
  const disk = await readFile(join(f.root, 'storage', 'companion_tasks.json'), 'utf8');
  assert(disk.includes(s.artifacts[0].sha256));
  await unlink(output(f));
  assert.equal((await f.store.artifact(f.body.taskId, s.artifacts[0].artifactId)).status, 'missing');
  assert.equal(f.counters.links, 1); assert.equal(f.counters.modelCalls, 1);
});
test('SOURCE_INTEGRATION zero confirmed todos still requires a real page and verified artifact', async t => {
  const f = await fixture(t, {proposal: {todos: []}}); await launch(f);
  await until(() => snapshot(f).state === 'done', 'empty valid page');
  assert.match(await readFile(output(f), 'utf8'), /这些已读笔记中未见明确待办/);
  assert.equal(snapshot(f).steps.find(s => s.stepKey === 'model').result.completion.itemCount, 0);
});
test('SOURCE_INTEGRATION unreadable selected input yields a real partial page with a named gap', async t => {
  const f = await fixture(t); await writeNote(f.root, 'bad.md', Buffer.from([0xff, 0xfe])); await launch(f);
  await until(() => snapshot(f).state === 'partial', 'partial page');
  assert.equal(snapshot(f).artifacts[0].sourceCount, 1);
  assert.match(await readFile(output(f), 'utf8'), /bad\.md：不是可读的 UTF-8 纯文本/);
  assert.equal(f.counters.modelCalls, 1);
});
test('SOURCE_INTEGRATION no matching sources creates no model request or file', async t => {
  const f = await fixture(t); await unlink(join(f.root, 'notes', 'one.md')); await launch(f);
  await until(() => snapshot(f).state === 'failed', 'no matching result');
  assert.equal(snapshot(f).waitReason, 'no_matching_inputs');
  assert.equal(f.counters.modelCalls, 0); assert.equal(f.counters.links, 0);
  assert.deepEqual(await readdir(join(f.root, 'notes')), []);
});
test('SOURCE_INTEGRATION an existing same-name file is retained without model cost', async t => {
  const f = await fixture(t); await writeFile(output(f), 'original existing file'); await launch(f);
  await until(() => snapshot(f).waitReason === 'output_exists', 'existing output wait');
  assert.equal(await readFile(output(f), 'utf8'), 'original existing file');
  assert.equal(f.counters.modelCalls, 0); assert.equal(f.counters.links, 0);
});
test('SOURCE_INTEGRATION a replaced chosen directory never becomes a new input selection', async t => {
  const f = await fixture(t); await rename(join(f.root, 'notes'), join(f.root, 'old-notes'));
  await mkdir(join(f.root, 'notes')); await writeNote(f.root, 'one.md', 'replacement'); await launch(f);
  await until(() => terminal(f), 'stale selected directory');
  assert.equal(f.counters.modelCalls, 0); assert.equal(f.counters.links, 0);
  assert.equal(snapshot(f).artifacts.length, 0);
});
test('SOURCE_INTEGRATION twenty-one actual matching files stop before reading or model dispatch', async t => {
  const f = await fixture(t);
  for (let i = 0; i < 20; i++) await writeNote(f.root, i + '.md', 'TODO: other');
  await launch(f); await until(() => snapshot(f).waitReason === 'input_file_count_limit', 'bounded selection');
  assert.equal(f.counters.reads, 0); assert.equal(f.counters.modelCalls, 0); assert.equal(f.counters.links, 0);
});
test('SOURCE_INTEGRATION changing a source after the model never publishes the stale candidate', async t => {
  let root;
  const f = await fixture(t, {beforeFinish: async () => writeNote(root, 'one.md', 'changed during model')}); root = f.root;
  await launch(f); await until(() => snapshot(f).state === 'failed', 'source version fence');
  await assert.rejects(stat(output(f)), {code: 'ENOENT'});
  assert.equal(f.counters.modelCalls, 1); assert.equal(f.counters.links, 0);
});
test('SOURCE_INTEGRATION unverified model citations retain actual usage without creating a candidate', async t => {
  const f = await fixture(t, {proposal: {todos: [{...proposal.todos[0], source: 'unread.md'}]}});
  await launch(f); await until(() => snapshot(f).state === 'failed', 'invalid source proposal');
  assert.equal(snapshot(f).waitReason, 'unverified_model_source');
  const observations = snapshot(f).steps.find(value => value.stepKey === 'model').result.observations;
  assert.equal(observations.findLast(value => value.type === 'model-finish').usage.output_tokens, 13);
  assert.equal(f.counters.links, 0);
});
test('SOURCE_INTEGRATION pause remains durably waiting and performs no selection or model work', async t => {
  const f = await fixture(t); f.body.afterExit = 'pause'; await launch(f);
  await until(() => snapshot(f).waitReason === 'foreground_required', 'explicit foreground request required');
  await f.store.stop();
  assert.equal(f.counters.lists, 0); assert.equal(f.counters.reads, 0); assert.equal(f.counters.modelCalls, 0);
});
test('SOURCE_INTEGRATION model loss stays unknown across a real database reopen without another call', async t => {
  const f = await fixture(t, {async *stream() {throw new Error('lost model stream');}});
  await launch(f); await until(() => snapshot(f).state === 'unknown', 'unknown model');
  const oldId = snapshot(f).hostExecutionId;
  await f.close();
  const next = await openFixture(f.root, {async *stream() {assert.fail('no replacement model call');}});
  t.after(() => next.close());
  await next.start().wake(f.body.taskId); await next.store.stop();
  assert.equal(next.store.snapshot(f.body.taskId).hostExecutionId, oldId);
  assert.equal(next.store.snapshot(f.body.taskId).state, 'unknown'); assert.equal(next.counters.modelCalls, 0);
});
test('SOURCE_INTEGRATION a saved candidate survives reopen and is published without regenerating it', async t => {
  const f = await fixture(t), claim = f.store.claimStep.bind(f.store);
  f.store.claimStep = (id, rev, key, opts) => key === 'writePage' ? Promise.reject(new Error('lost before write claim')) : claim(id, rev, key, opts);
  await launch(f); await until(() => snapshot(f).waitReason === 'execution_unavailable', 'saved candidate checkpoint');
  assert.equal(f.counters.modelCalls, 1); assert(f.store.read(f.body.taskId).notes['1'].candidate);
  await f.close();
  const next = await openFixture(f.root, {async *stream() {assert.fail('saved candidate cannot be regenerated');}});
  t.after(() => next.close()); next.start();
  await until(() => next.store.snapshot(f.body.taskId).state === 'done', 'saved candidate publication');
  assert.equal(next.counters.modelCalls, 0); assert.equal(next.counters.links, 1);
});
test('SOURCE_INTEGRATION actual hardlink followed by lost result is reconciled without a second write', async t => {
  const f = await fixture(t, {link: async (a, b) => {await link(a, b); throw Object.assign(new Error('lost link result'), {code: 'EIO'});}});
  await launch(f); await until(() => snapshot(f).state === 'done', 'retained inode reconciliation');
  assert.equal(f.counters.links, 1); assert.equal(snapshot(f).artifacts.length, 1);
  const claim = snapshot(f).steps.find(value => value.stepKey === 'writePage');
  assert.equal(claim.state, 'done'); assert(snapshot(f).budget.heldMs > 0);
  assert.equal((await f.store.artifact(f.body.taskId, snapshot(f).artifacts[0].artifactId)).status, 'available');
});
test('SOURCE_INTEGRATION failed publication projects unknown and never silently retries the link', async t => {
  const f = await fixture(t, {link: async () => {throw Object.assign(new Error('unsupported'), {code: 'ENOTSUP'});}});
  await launch(f); await until(() => snapshot(f).state === 'unknown', 'unknown publication');
  await f.store.create(f.body); // exact original replay may reconcile, never issue another link
  await f.store.stop();
  assert.equal(f.counters.links, 1); assert.equal(snapshot(f).steps.at(-1).state, 'unknown');
  assert(f.store.read(f.body.taskId).notes['1'].publicationAttempted);
  const before = snapshot(f).budget.heldMs; assert(before > 0); await f.close();
  const next = await openFixture(f.root, {link: () => assert.fail('unknown publication cannot be retried')});
  t.after(() => next.close());
  await next.start().wake(f.body.taskId); await next.store.stop();
  assert.equal(next.store.snapshot(f.body.taskId).state, 'unknown');
  assert.equal(next.store.snapshot(f.body.taskId).budget.heldMs, before); assert.equal(next.counters.links, 0);
});
test('SOURCE_INTEGRATION unknown context resolves through exact original create replay without a new revision', async t => {
  const options = {window: null}, f = await fixture(t, options);
  await launch(f); await until(() => snapshot(f).waitReason === 'model_context_window_unknown', 'preflight waiting');
  const before = snapshot(f), first = before.steps.findLast(value => value.stepKey === 'model');
  assert.equal(first.state, 'waiting'); assert.equal(first.result.completion.preflightDispatched, false);
  assert.equal(first.result.completion.streamEntered, false); assert.equal(f.counters.modelCalls, 0);
  options.window = 64000;
  const retry = await f.store.create(f.body);
  assert.equal(retry.snapshot.runnerReceiptSeq, before.runnerReceiptSeq);
  await until(() => snapshot(f).state === 'done', 'same agreement resumed');
  const current = snapshot(f), attempts = current.steps.filter(value => value.stepKey === 'model');
  assert.equal(current.taskRev, 1); assert.equal(current.hostExecutionId, before.hostExecutionId);
  assert.equal(attempts.length, 2); assert.notEqual(attempts[0].attemptId, attempts[1].attemptId);
  assert.equal(attempts[0].state, 'waiting'); assert.equal(attempts[1].state, 'done');
  assert.equal(f.counters.modelCalls, 1); assert.equal(f.counters.links, 1);
});
test('SOURCE_INTEGRATION read-only retry uses the saved original selection after access recovers', async t => {
  const f = await fixture(t), actualRead = f.fs.dshGoReadNote.bind(f.fs); let blocked = true;
  f.fs.dshGoReadNote = (...args) => blocked ? Promise.reject(Object.assign(new Error('controlled unavailable read'), {code: 'EACCES'})) : actualRead(...args);
  await launch(f); await until(() => snapshot(f).waitReason === 'matching_inputs_unavailable', 'original read waiting');
  await writeNote(f.root, 'later.md', 'TODO: must not join this saved selection');
  blocked = false; await f.store.create(f.body);
  await until(() => snapshot(f).state === 'done', 'saved selection read again');
  assert.equal(f.counters.lists, 1); assert.equal(snapshot(f).artifacts[0].sourceCount, 1);
  assert.equal(JSON.stringify(f.counters.requests).includes('must not join'), false);
  const reads = snapshot(f).steps.filter(value => value.stepKey === 'readInputs');
  assert.equal(reads.length, 2); assert.equal(reads[0].state, 'waiting'); assert.equal(reads[1].state, 'done');
});
test('SOURCE_INTEGRATION a drained unknown model receipt does not prevent stopping all remaining work', async t => {
  const f = await fixture(t, {async *stream() {throw new Error('provider stream lost');}});
  await launch(f); await until(() => snapshot(f).state === 'unknown', 'drained model result unknown');
  await f.store.cancel(f.body.taskId, {v: 1, hostStoreId: f.store.hostStoreId, operationId: 'later-cancel', expectedTaskRev: 1, taskRev: 2});
  await until(() => snapshot(f).state === 'cancelled', 'stopped remaining work');
  assert.equal(snapshot(f).steps.find(value => value.stepKey === 'model').state, 'unknown');
  assert.equal(f.counters.links, 0);
});
test('SOURCE_INTEGRATION original absolute deadline stops preparation without a physical model request', async t => {
  const f = await fixture(t, {prepare: async ({signal}) => {
    await new Promise(resolve => signal.addEventListener('abort', resolve, {once: true}));
  }});
  f.body.deadlineAtMs = Date.now() + 400;
  await launch(f); await until(() => snapshot(f).state === 'failed', 'original deadline terminal');
  assert.equal(snapshot(f).waitReason, 'deadline_expired'); assert.equal(f.counters.modelCalls, 0); assert.equal(f.counters.links, 0);
});
for (const complete of [false, true]) test('SOURCE_INTEGRATION cancel during model retains old ' + (complete ? 'complete' : 'unconfirmed') + ' outcome without publishing', async t => {
  let ready;
  const dispatched = new Promise(resolve => {ready = resolve;});
  const f = await fixture(t, {async *stream({signal, observer}) {
    ready(); await new Promise(resolve => signal.addEventListener('abort', resolve, {once: true}));
    observer.observe({type: 'usage', event: 'message_delta', raw: {output_tokens: 70}});
    if (complete) observer.observe({type: 'complete'});
    yield {type: 'finish', reason: {kind: complete ? 'stop' : 'aborted'}};
  }});
  await launch(f); await dispatched;
  await f.store.cancel(f.body.taskId, {v: 1, hostStoreId: f.store.hostStoreId, operationId: 'cancel-command', expectedTaskRev: 1, taskRev: 2});
  await until(() => snapshot(f).state === 'cancelled', 'cancelled old model drain');
  const old = snapshot(f).steps.find(value => value.stepKey === 'model');
  assert.equal(old.state, complete ? 'cancelled' : 'unknown'); assert.notEqual(old.finishedAtMs, null);
  assert.equal(old.taskRev, 1); assert.equal(old.result.observations.findLast(value => value.type === 'model-finish').usage.output_tokens, 70);
  assert.equal(old.result.observations.findLast(value => value.type === 'model-finish').usage.complete, complete);
  assert.equal(snapshot(f).taskRev, 2); assert.equal(f.counters.links, 0);
});
test('SOURCE_INTEGRATION original deadline after dispatch retains unknown original model result', async t => {
  const f = await fixture(t, {async *stream({signal, observer}) {
    await new Promise(resolve => signal.addEventListener('abort', resolve, {once: true}));
    observer.observe({type: 'usage', event: 'message_delta', raw: {output_tokens: 29}});
    throw signal.reason;
  }});
  f.body.deadlineAtMs = Date.now() + 400;
  const runner = f.start(); await f.store.create(f.body); await runner.wake(f.body.taskId);
  const old = snapshot(f).steps.find(value => value.stepKey === 'model');
  assert.equal(snapshot(f).state, 'unknown'); assert.equal(old.state, 'unknown');
  assert.equal(old.reason, 'deadline_expired'); assert.notEqual(old.finishedAtMs, null);
  const finish = old.result.observations.findLast(value => value.type === 'model-finish');
  assert.equal(finish.dispatched, true); assert.equal(finish.usage.complete, false);
  assert.equal(finish.usage.output_tokens, 29); assert.equal(f.counters.links, 0);
  await f.store.create(f.body); await runner.wake(f.body.taskId);
  assert.equal(f.counters.modelCalls, 1); assert.equal(snapshot(f).state, 'unknown');
});
test('SOURCE_INTEGRATION direct deadline guard after a wall-clock jump retains dispatched unknown without a timer abort', async t => {
  const originalNow = Date.now;
  let offset = 0;
  Date.now = () => originalNow() + offset;
  try {
    const f = await fixture(t, {async *stream({signal, observer}) {
      offset = 20_000;
      assert.equal(signal.aborted, false);
      observer.observe({type: 'usage', event: 'message_delta', raw: {output_tokens: 29}});
      yield {type: 'text-delta', text: '{'};
    }});
    f.body.deadlineAtMs = Date.now() + 10_000;
    const runner = f.start(); await f.store.create(f.body); await runner.wake(f.body.taskId);
    const old = snapshot(f).steps.find(value => value.stepKey === 'model');
    assert.equal(snapshot(f).state, 'unknown'); assert.equal(old.state, 'unknown');
    assert.equal(old.reason, 'deadline_expired'); assert.notEqual(old.finishedAtMs, null);
    const finish = old.result.observations.findLast(value => value.type === 'model-finish');
    assert.equal(finish.dispatched, true); assert.equal(finish.httpStatus, 200);
    assert.equal(finish.usage.complete, false); assert.equal(finish.usage.output_tokens, 29);
    assert.equal(f.counters.links, 0);
    offset = 0;
    await f.store.create(f.body); await runner.wake(f.body.taskId);
    assert.equal(f.counters.modelCalls, 1); assert.equal(snapshot(f).state, 'unknown');
  } finally {Date.now = originalNow;}
});
for (const scenario of ['before-link', 'after-link']) {
  test('SOURCE_INTEGRATION actual process SIGKILL ' + scenario + ' reopens the original ledger without another physical attempt', async t => {
    const f = await fixture(t);
    await f.store.create(f.body); const executionId = snapshot(f).hostExecutionId;
    await f.close();
    const child = spawn(process.execPath, [fileURLToPath(new URL('./fixtures/companion-notes-runner-crash.mjs', import.meta.url)), f.root, scenario],
      {stdio: ['ignore', 'pipe', 'pipe']});
    let error = ''; child.stderr.on('data', chunk => {error += chunk;});
    const killed = await new Promise((resolve, reject) => {
      const timer = setTimeout(() => {child.kill('SIGKILL'); reject(new Error('child did not reach publication: ' + error));}, 10000);
      child.on('error', reject); child.on('exit', (code, signal) => {clearTimeout(timer); resolve({code, signal});});
    });
    assert.deepEqual(killed, {code: null, signal: 'SIGKILL'}, error);
    const next = await openFixture(f.root, {async *stream() {assert.fail('recovery cannot regenerate the candidate');},
      link: () => assert.fail('recovery cannot issue another link')});
    t.after(() => next.close());
    const original = next.store.read(f.body.taskId);
    assert.equal(original.hostExecutionId, executionId); assert.equal(original.state, 'running');
    assert.equal(original.notes['1'].publicationAttempted, true);
    assert(original.budget.heldMs > 0);
    next.start();
    const state = scenario === 'after-link' ? 'done' : 'unknown';
    await until(() => next.store.snapshot(f.body.taskId).state === state, 'original crash reconciliation');
    const recovered = next.store.snapshot(f.body.taskId);
    assert.equal(recovered.hostExecutionId, executionId); assert.equal(recovered.budget.heldMs, original.budget.heldMs);
    assert.equal(next.counters.modelCalls, 0); assert.equal(next.counters.links, 0);
    if (scenario === 'after-link') {
      assert.equal(recovered.artifacts.length, 1);
      assert.equal((await next.store.artifact(f.body.taskId, recovered.artifacts[0].artifactId)).status, 'available');
    } else {
      assert.equal(recovered.artifacts.length, 0); assert.equal(recovered.steps.at(-1).state, 'unknown');
      await assert.rejects(stat(output(f)), {code: 'ENOENT'});
    }
  });
}
test('SOURCE_INTEGRATION saved intent before attempted marker resumes its first publication with additional reserved time', async t => {
  const f = await fixture(t); await f.store.create(f.body); const executionId = snapshot(f).hostExecutionId;
  await f.close();
  const child = spawn(process.execPath, [fileURLToPath(new URL('./fixtures/companion-notes-runner-crash.mjs', import.meta.url)), f.root, 'saved-intent'],
    {stdio: ['ignore', 'pipe', 'pipe']});
  let error = ''; child.stderr.on('data', data => {error += data;});
  const died = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => {child.kill('SIGKILL'); reject(new Error('child missed saved intent: ' + error));}, 10000);
    child.on('error', reject); child.on('exit', (code, signal) => {clearTimeout(timer); resolve({code, signal});});
  });
  assert.deepEqual(died, {code: null, signal: 'SIGKILL'}, error);
  const next = await openFixture(f.root, {async *stream() {assert.fail('saved candidate cannot be regenerated');}});
  t.after(() => next.close());
  const before = next.store.read(f.body.taskId), intent = before.notes['1'].publishIntent;
  assert.notEqual(before.notes['1'].publicationAttempted, true); assert(intent);
  assert.equal(before.steps.at(-1).state, 'running'); assert(before.budget.heldMs > 0);
  next.start(); await until(() => next.store.snapshot(f.body.taskId).state === 'done', 'first original publication');
  const after = next.store.read(f.body.taskId), writes = after.steps.filter(value => value.stepKey === 'writePage');
  assert.equal(after.hostExecutionId, executionId); assert.equal(after.taskRev, 1);
  assert.equal(writes.length, 2); assert.equal(writes[0].state, 'waiting'); assert.equal(writes[1].state, 'done');
  assert.equal(writes[0].result.completion.publicationNotAttempted, true);
  assert.equal(after.notes['1'].publicationAttemptId, writes[1].attemptId);
  assert.equal(after.budget.heldMs, before.budget.heldMs); assert(after.budget.spentMs > before.budget.spentMs);
  assert.deepEqual(after.notes['1'].publishIntent, intent);
  assert.equal(after.artifacts[0].identity, intent.fileIdentity);
  assert.equal(next.counters.modelCalls, 0); assert.equal(next.counters.links, 1);
});
