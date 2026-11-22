import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile, writeFile, readdir, unlink, rename, link} from 'node:fs/promises';
import {join} from 'node:path';
import {createHash} from 'node:crypto';
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {receiptFixture, completeReceipts, receiptReportOf, openReceipts, artifactPath, parseActualWorkbook,
  textReceipt, receiptOperation} from './fixtures/companion-receipts-runner-fixture.mjs';
import {ordinary, textLines, paintImage} from './fixtures/companion-receipt-pdf.mjs';
import {putDraft} from './fixtures/companion-find-runner-fixture.mjs';

test('J SOURCE_HTTP three readable originals plus one scan publish/reopen one real partial workbook with zero model', async t => {
  const f = await receiptFixture(t); await putDraft(f.root, 'unselected-fifth.txt', 'SECRET FIFTH FILE');
  const original = await Promise.all(f.fixtures.map(value => readFile(join(f.root, 'notes', value.name))));
  const {response, snapshot} = await completeReceipts(f), report = receiptReportOf(snapshot);
  assert.equal(snapshot.state, 'partial', JSON.stringify(snapshot)); assert.equal(snapshot.waitReason, 'receipts_incomplete');
  assert.deepEqual(snapshot.steps.map(value => value.stepKey), ['readInputs', 'writeSheet']);
  assert.equal(snapshot.steps[0].state, 'done'); assert.equal(snapshot.steps[1].state, 'partial');
  assert.equal(snapshot.artifacts.length, 1); assert.equal(snapshot.artifacts[0].sourceCount, 4);
  assert.equal(report.coverage.rowsWithVerifiedFields, 3); assert.equal(report.coverage.fullyVerifiedRows, 3);
  assert.deepEqual(report.rows.slice(0, 3).map(value => value.amount.value), ['CNY 128.50', 'USD 90.00', 'CNY 80.00']);
  assert.equal(report.sources[3].reason, 'pdf_empty_text'); assert.equal(report.rows[3].date.state, 'unverified');
  assert(report.sources.every(value => value.verifiedAtPublish)); assert.equal(f.counters.links, 1);
  assert.equal(f.originalCounters.lists, 0); assert(!f.counters.readNames.includes('unselected-fifth.txt'));
  assert.equal(snapshot.notes, undefined); assert.equal(snapshot.execution, undefined);
  const downloaded = await f.raw(artifactPath(f, snapshot)); assert.equal(downloaded.status, 200);
  assert.equal(downloaded.mediaType, 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
  assert.equal(Number(downloaded.length), downloaded.bytes.length); assert.equal(downloaded.cache, 'no-store');
  assert.equal(createHash('sha256').update(downloaded.bytes).digest('hex'), snapshot.artifacts[0].sha256);
  const readback = parseActualWorkbook(f, snapshot, downloaded.bytes);
  assert.equal(readback.cells, 20); assert.match(readback.rows[4][3], /未读到文字层/u);
  assert.deepEqual(await Promise.all(f.fixtures.map(value => readFile(join(f.root, 'notes', value.name)))), original);
  const cap = (await f.request('/capabilities')).body;
  assert.deepEqual(cap.receiptInputs, {formats: ['md', 'txt', 'pdf'], maxFiles: 4, maxBytes: 4194304, maxPdfPages: 5, workbookBytes: 262144});
  if (process.env.J_RECEIPT_WIRE_FIXTURE) {
    await writeFile(process.env.J_RECEIPT_WIRE_FIXTURE, JSON.stringify({scope: 'ACTUAL_PINNED_DOMAIN_FS_HTTP_PDF_WORKBOOK_CONTROLLED_FIXED_TURN_OWNER_NO_MODEL',
      capabilities: cap, folder: f.folder, inputs: f.inputs, create: f.body, createReply: response.body,
      complete: snapshot, workbookBase64: downloaded.bytes.toString('base64'), expectedCells: readback.rows}, null, 2) + '\n');
    await writeFile(process.env.J_RECEIPT_WIRE_FIXTURE + '.xlsx', downloaded.bytes);
  }
});
test('J SOURCE_HTTP mixed PDF keeps image date unverified while accepting only its actual text-layer amount', async t => {
  const fixtures = Array.from({length: 3}, (_, i) => ({name: `receipt-${i}.txt`, bytes: Buffer.from(textReceipt)}));
  fixtures.push({name: 'mixed.pdf', bytes: ordinary([textLines(['Amount: CNY 80.00']) + '\n' + paintImage])});
  const f = await receiptFixture(t, {fixtures}); const {snapshot} = await completeReceipts(f), report = receiptReportOf(snapshot);
  assert.equal(snapshot.state, 'partial'); assert.equal(report.rows[3].amount.value, 'CNY 80.00');
  assert.equal(report.rows[3].amount.evidence.page, 1); assert.equal(report.rows[3].date.state, 'unverified');
  assert.equal(report.rows[3].item.state, 'unverified'); assert(!JSON.stringify(report).includes('not_present'));
  assert.equal(report.coverage.rowsWithVerifiedFields, 4); assert.equal(report.coverage.fullyVerifiedRows, 3);
  if (process.env.J_RECEIPT_WIRE_FIXTURE) await writeFile(process.env.J_RECEIPT_WIRE_FIXTURE + '.mixed.json', JSON.stringify({
    create: f.body, inputs: f.inputs, complete: snapshot}, null, 2) + '\n');
});
test('J SOURCE_HTTP four verified text receipts produce done; formula-looking strings remain literal cells', async t => {
  const fixtures = Array.from({length: 4}, (_, i) => ({name: `receipt-${i}.txt`, bytes: Buffer.from(textReceipt)}));
  fixtures[0].bytes = Buffer.from(textReceipt.replace('交通', '=HYPERLINK("https://example.invalid","票")'));
  const f = await receiptFixture(t, {fixtures}); const {snapshot} = await completeReceipts(f);
  assert.equal(snapshot.state, 'done'); assert.equal(snapshot.steps.at(-1).state, 'done');
  const actual = await f.raw(artifactPath(f, snapshot));
  assert.equal(parseActualWorkbook(f, snapshot, actual.bytes).rows[1][1], '=HYPERLINK("https://example.invalid","票")');
});
test('J SOURCE_HTTP all four unread or unverified inputs keep a real report without an empty artifact or execution owner', async t => {
  const fixtures = Array.from({length: 4}, (_, i) => ({name: `scan-${i}.pdf`, bytes: ordinary([paintImage])}));
  const f = await receiptFixture(t, {fixtures}); await unlink(join(f.root, 'notes', fixtures[0].name));
  const {snapshot} = await completeReceipts(f), report = receiptReportOf(snapshot);
  assert.equal(snapshot.state, 'failed'); assert.equal(snapshot.waitReason, 'receipt_fields_unavailable');
  assert.equal(report.sources.length, 4); assert.equal(report.rows.length, 4); assert.equal(report.coverage.rowsWithVerifiedFields, 0);
  assert.equal(report.sources[0].readComplete, false); assert.deepEqual(snapshot.artifacts, []);
  assert.equal(f.counters.links, 0); assert.equal(f.counters.stages, 0); assert.equal(f.counters.executions, 0);
  assert(!((await readdir(join(f.root, 'notes'))).includes('差旅小表.xlsx')));
});
test('J SOURCE_HTTP duplicate bindings, fifth receipt, forged version and PDF authority in old I are rejected before content IO', async t => {
  const f = await receiptFixture(t);
  for (const inputs of [f.body.args.inputs.slice(0, 3), [...f.body.args.inputs, f.body.args.inputs[0]],
    [f.body.args.inputs[0], f.body.args.inputs[0], ...f.body.args.inputs.slice(2)],
    f.body.args.inputs.map((value, i) => i ? value : {...value, version: 'forged'})])
    assert.equal((await f.request('', {...f.body, args: {...f.body.args, inputs}})).status, 400);
  const duplicate = await f.request('/inputs', {v: 1, kind: f.body.kind, hostStoreId: f.store.hostStoreId,
    folderRef: f.folder.folderRef, name: f.fixtures[0].name});
  const inputs = [...f.body.args.inputs]; inputs[1] = {sourceRef: duplicate.body.sourceRef, version: duplicate.body.version};
  assert.equal((await f.request('', {...f.body, args: {...f.body.args, inputs}})).status, 400);
  await assert.rejects(f.store.create({...f.body, kind: 'host.compare_drafts', args: {
    a: f.body.args.inputs[2], b: f.body.args.inputs[0], maxHighlights: 3}}), error => error.status === 400);
  const oldBinding = {v: 1, hostStoreId: f.store.hostStoreId, folderRef: f.folder.folderRef, name: f.fixtures[2].name};
  assert.throws(() => f.store.bindInput(oldBinding), error => error.status === 400);
  assert.equal((await f.request('/inputs', oldBinding)).status, 503, 'this fixture only mounts J, so the old I binding service is unavailable');
  assert.equal(f.counters.readNames.length, 0); assert.equal(f.counters.links, 0);
});
test('J SOURCE_HTTP existing output and source replacement never overwrite or import new source facts', async t => {
  const f = await receiptFixture(t); await writeFile(join(f.root, 'notes', f.body.args.outputName), 'someone else');
  const {snapshot} = await completeReceipts(f); assert.equal(snapshot.state, 'failed');
  assert.equal(snapshot.waitReason, 'output_exists'); assert.equal(f.counters.links, 0);
  assert.equal(await readFile(join(f.root, 'notes', f.body.args.outputName), 'utf8'), 'someone else');
});
test('J SOURCE_HTTP a source changed before first reading remains missing while other originals make a partial sheet', async t => {
  const f = await receiptFixture(t); await rename(join(f.root, 'notes', f.fixtures[0].name), join(f.root, 'old-source'));
  await putDraft(f.root, f.fixtures[0].name, '日期：2027-01-01\n项目：另一个\n金额：CNY 999999');
  const {snapshot} = await completeReceipts(f), report = receiptReportOf(snapshot);
  assert.equal(snapshot.state, 'partial'); assert.equal(report.sources[0].readComplete, false);
  assert.equal(report.rows[0].amount.value, null); assert.equal(report.coverage.rowsWithVerifiedFields, 2);
});
test('J SOURCE_HTTP raw artifact route checks original identities, duplicate query keys and bytes without ordinary file fallback', async t => {
  const f = await receiptFixture(t); const {snapshot} = await completeReceipts(f), path = artifactPath(f, snapshot);
  const before = f.counters.artifactReads;
  for (const [url, status] of [[path.replace(snapshot.hostExecutionId, 'other-execution'), 409],
    [path.replace(snapshot.hostStoreId, 'other-store'), 409], [path + '&path=anything', 400],
    [path + '&hostStoreId=' + snapshot.hostStoreId, 400], [path.replace(snapshot.artifacts[0].artifactId, 'not-recorded'), 404]])
    assert.equal((await f.raw(url)).status, status);
  assert.equal(f.counters.artifactReads, before);
  assert.equal((await f.request(`/${snapshot.taskId}/artifacts/${snapshot.artifacts[0].artifactId}?hostStoreId=${snapshot.hostStoreId}`)).status, 400);
  await unlink(join(f.root, 'notes', snapshot.artifacts[0].relativePath));
  assert.equal((await f.raw(path)).status, 404); assert.equal(f.store.snapshot(snapshot.taskId).artifacts.length, 1);
});
test('J SOURCE_RESTART actual link then lost result is reconciled and two reopenings never link again', async t => {
  const f = await receiptFixture(t, {link: async (from, to) => { await link(from, to); throw Object.assign(new Error('Lost link result'), {code: 'EIO'}); }});
  const {snapshot} = await completeReceipts(f); assert.equal(snapshot.state, 'partial'); assert.equal(snapshot.artifacts.length, 1);
  assert.equal(f.counters.links, 1); const original = snapshot.artifacts[0]; await f.close();
  for (let i = 0; i < 2; i++) {
    const next = await openReceipts(f.root, {link() { assert.fail('Reopening cannot write another workbook'); }});
    try {
      next.start(); await next.settled(); const current = next.store.snapshot(snapshot.taskId);
      assert.equal(current.hostExecutionId, snapshot.hostExecutionId); assert.deepEqual(current.artifacts[0], original);
      assert.equal((await next.raw(artifactPath(next, current))).status, 200); assert.equal(next.counters.links, 0);
    } finally { await next.close(); }
  }
});
test('J SOURCE_HTTP cancelling after publication preserves historical artifact bytes and original execution', async t => {
  const f = await receiptFixture(t); const {snapshot} = await completeReceipts(f);
  const cancelled = await f.request(`/${snapshot.taskId}/cancel`, receiptOperation(f));
  assert.equal(cancelled.status, 200); assert.equal(cancelled.body.state, 'cancelled');
  assert.deepEqual(cancelled.body.artifacts, snapshot.artifacts); assert.equal((await f.raw(artifactPath(f, snapshot))).status, 200);
  assert.equal(f.counters.links, 1);
});

test('J SOURCE_RESTART owner stop at fifth original read resumes the unattempted write with original inputs and a new time claim', async t => {
  let enter, release, reads = 0;
  const entered = new Promise(resolve => { enter = resolve; }), gate = new Promise(resolve => { release = resolve; });
  const f = await receiptFixture(t, {read: async (_args, actual) => { if (++reads === 5) { enter(); await gate; } return actual(); }});
  await f.request('', f.body); await entered; const stopping = f.store.stop(); release(); await stopping;
  const before = f.store.read(f.body.taskId), beforePublic = f.store.snapshot(f.body.taskId);
  assert.equal(before.steps.at(-1).state, 'waiting'); assert.equal(before.steps.at(-1).reason, 'publication_not_started');
  assert.equal(before.steps.at(-1).result.completion.publicationNotAttempted, true);
  assert.equal(before.notes['1'].publishIntent, undefined); assert.equal(before.notes['1'].publicationAttempted, undefined);
  assert.equal(f.counters.links, 0); await f.close();
  const next = await openReceipts(f.root); t.after(() => next.close()); next.start(); await next.settled();
  const after = next.store.snapshot(f.body.taskId); assert.equal(after.state, 'partial', JSON.stringify(after));
  assert.equal(after.hostExecutionId, before.hostExecutionId); assert.equal(after.artifacts.length, 1);
  assert.equal(next.counters.links, 1); assert.equal(next.counters.readNames.length, 8, 'only two prepublication checks of four saved originals');
  assert.equal(after.steps.filter(value => value.stepKey === 'writeSheet').length, 2);
  assert.equal(after.budget.heldMs, 0); assert(after.budget.spentMs >= before.budget.spentMs);
  assert.deepEqual(after.steps[0].result, beforePublic.steps[0].result);
  if (process.env.J_RECEIPT_WIRE_FIXTURE) await writeFile(process.env.J_RECEIPT_WIRE_FIXTURE + '.owner-stop.json', JSON.stringify({create:f.body,inputs:f.inputs,before:beforePublic,complete:after},null,2)+'\n');
});

for (const scenario of ['before-candidate', 'saved-intent', 'before-link', 'after-link'])
test('J SOURCE_RESTART actual SIGKILL ' + scenario + ' preserves held budget and original publication identity', async t => {
  const f = await receiptFixture(t); f.store.runner.wake = () => undefined;
  const created = await f.request('', f.body); assert.equal(created.status, 201); await f.close();
  const child = spawn(process.execPath, ['--no-addons', fileURLToPath(new URL('./fixtures/companion-receipts-runner-crash.mjs', import.meta.url)), f.root, scenario],
    {stdio: ['ignore', 'pipe', 'pipe']});
  let stderr = ''; child.stderr.on('data', data => { stderr += data; });
  const died = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => { child.kill('SIGKILL'); reject(new Error('Child missed crash point: ' + stderr)); }, 10000);
    child.on('error', reject); child.on('exit', (code, signal) => { clearTimeout(timer); resolve({code, signal}); });
  });
  assert.deepEqual(died, {code: null, signal: 'SIGKILL'}, stderr);
  const attempted = ['before-link', 'after-link'].includes(scenario);
  const next = await openReceipts(f.root, {link: async (from, to) => {
    assert.equal(attempted, false, 'A possible-send marker can only reconcile, never relink'); return link(from, to);
  }}); t.after(() => next.close());
  const before = next.store.read(f.body.taskId); assert(before.budget.heldMs > 0);
  assert.equal(before.notes['1'].publicationAttempted === true, attempted);
  next.start(); await next.settled(); const after = next.store.snapshot(f.body.taskId);
  assert.equal(after.hostExecutionId, created.body.hostExecutionId);
  assert.equal(after.budget.heldMs, before.budget.heldMs, 'unknown prior elapsed time is never refunded');
  assert.equal(after.state, scenario === 'before-link' ? 'unknown' : 'partial', JSON.stringify(after));
  assert.equal(next.counters.links, attempted ? 0 : 1);
  if (scenario === 'before-link') { assert.equal(after.artifacts.length, 0); assert.equal(after.steps.at(-1).state, 'unknown'); }
  else {
    assert.equal(after.artifacts.length, 1); assert.equal((await next.raw(artifactPath(next, after))).status, 200);
    if (before.notes['1'].publishIntent)
      assert.equal(next.store.read(f.body.taskId).artifacts[0].identity, before.notes['1'].publishIntent.fileIdentity);
  }
  const artifact = after.artifacts[0]; await next.close();
  const again = await openReceipts(f.root, {link() { assert.fail('Second reconnect cannot relink'); }});
  try {
    again.start(); await again.settled(); const latest = again.store.snapshot(f.body.taskId);
    assert.equal(latest.hostExecutionId, after.hostExecutionId); assert.equal(again.counters.links, 0);
    assert.deepEqual(latest.artifacts[0], artifact); assert.equal(latest.budget.heldMs, before.budget.heldMs);
  } finally { await again.close(); }
});

test('J SOURCE_RESTART stop during third original read preserves two observations and resumes only the two unread originals', async t => {
  let enter, release, reads = 0;
  const entered = new Promise(resolve => { enter = resolve; }), gate = new Promise(resolve => { release = resolve; });
  const f = await receiptFixture(t, {read: async (_args, actual) => { if (++reads === 3) { enter(); await gate; } return actual(); }});
  await f.request('', f.body); await entered; const stopping = f.store.stop(); release(); await stopping;
  const before = f.store.snapshot(f.body.taskId), report = receiptReportOf(before);
  assert.equal(before.steps[0].state, 'waiting'); assert.equal(before.steps[0].reason, 'receipt_read_interrupted');
  assert.equal(report.coverage.readCompleteCount, 2); assert.equal(report.coverage.rowsWithVerifiedFields, 2);
  await f.close(); const next = await openReceipts(f.root); t.after(() => next.close()); next.start(); await next.settled();
  const after = next.store.snapshot(f.body.taskId); assert.equal(after.state, 'partial', JSON.stringify(after));
  assert.equal(next.counters.readNames.length, 10);
  assert.deepEqual(next.counters.readNames.slice(0, 2), [f.fixtures[2].name, f.fixtures[3].name]);
  assert.deepEqual(after.steps[0], before.steps[0], 'the earlier completed partial read observation is immutable');
  assert.equal(after.steps.filter(step => step.stepKey === 'readInputs').length, 2);
  assert.equal(after.hostExecutionId, before.hostExecutionId);
  if (process.env.J_RECEIPT_WIRE_FIXTURE) await writeFile(process.env.J_RECEIPT_WIRE_FIXTURE + '.read-owner-stop.json', JSON.stringify({
    create: f.body, inputs: f.inputs, before, complete: after}, null, 2) + '\n');
});

test('J SOURCE_HTTP same-name same-byte foreign workbook is never adopted and is preserved across two reconnections', async t => {
  let foreign;
  const f = await receiptFixture(t, {stage: async (args, actual) => {
    const reference = await actual(); foreign = Buffer.from(args[2]);
    await writeFile(join(args[0].target.displayPath, args[1]), foreign);
    return reference;
  }});
  const {snapshot} = await completeReceipts(f);
  assert.equal(snapshot.state, 'unknown'); assert.equal(snapshot.artifacts.length, 0);
  assert.deepEqual(await readFile(join(f.root, 'notes', f.body.args.outputName)), foreign);
  await f.close();
  for (let i = 0; i < 2; i++) {
    const next = await openReceipts(f.root, {link() { assert.fail('Do not retry or adopt a foreign workbook'); }});
    try { next.start(); await next.settled(); const current = next.store.snapshot(f.body.taskId);
      assert.equal(current.state, 'unknown'); assert.equal(current.artifacts.length, 0); assert.equal(next.counters.links, 0);
      assert.deepEqual(await readFile(join(f.root, 'notes', f.body.args.outputName)), foreign);
    } finally { await next.close(); }
  }
});

test('J SOURCE_HTTP cancellation during staging prevents link and preserves all known original observations', async t => {
  let f;
  f = await receiptFixture(t, {stage: async (_args, actual) => {
    const reference = await actual();
    await f.store.cancel(f.body.taskId, receiptOperation(f)); return reference;
  }});
  const {snapshot} = await completeReceipts(f);
  assert.equal(snapshot.state, 'cancelled'); assert.equal(snapshot.artifacts.length, 0); assert.equal(f.counters.links, 0);
  assert.equal(receiptReportOf(snapshot).coverage.rowsWithVerifiedFields, 3);
  assert(!((await readdir(join(f.root, 'notes'))).includes(f.body.args.outputName)));
});

test('J SOURCE_HTTP replacement after staging stops publication instead of using a known-stale candidate', async t => {
  let f;
  f = await receiptFixture(t, {stage: async (_args, actual) => {
    const reference = await actual(); await rename(join(f.root, 'notes', f.fixtures[0].name), join(f.root, 'original-before-stage'));
    await putDraft(f.root, f.fixtures[0].name, textReceipt.replace('128.50', '999.99')); return reference;
  }});
  const {snapshot} = await completeReceipts(f);
  assert.equal(snapshot.state, 'failed'); assert.equal(snapshot.artifacts.length, 0); assert.equal(f.counters.links, 0);
  assert.equal(snapshot.steps.at(-1).reason, 'input_changed');
});

test('J SOURCE_HTTP one hundred later paused tasks retain the original task, workbook and store identity', async t => {
  const f = await receiptFixture(t); const {snapshot} = await completeReceipts(f);
  for (let i = 0; i < 100; i++) {
    const body = {...f.body, taskId: `future-${String(i).padStart(3, '0')}`, afterExit: 'pause',
      origin: {...f.body.origin, messageId: `later-message-${i}`}};
    assert.equal((await f.request('', body)).status, 201);
  }
  await f.settled(); let cursor = null, tasks = [];
  do {
    const page = (await f.request(`?hostStoreId=${f.store.hostStoreId}${cursor ? '&cursor=' + encodeURIComponent(cursor) : ''}`)).body;
    tasks.push(...page.tasks); cursor = page.nextCursor;
  } while (cursor);
  assert.equal(tasks.length, 101); assert.equal(tasks.filter(task => task.taskId === snapshot.taskId).length, 1);
  assert.deepEqual(f.store.snapshot(snapshot.taskId), snapshot);
  assert.equal((await f.raw(artifactPath(f, snapshot))).status, 200); assert.equal(f.counters.links, 1);
});

test('J SOURCE_RESTART three real lost write claims retain all time holds; exhausted original task performs no further work', async t => {
  const fixtures = Array.from({length: 4}, (_, i) => ({name: `receipt-${i}.txt`, bytes: Buffer.from(textReceipt)}));
  const f = await receiptFixture(t, {fixtures}); f.store.runner.wake = () => undefined;
  await f.request('', f.body); await f.close();
  for (let i = 0; i < 3; i++) {
    const child = spawn(process.execPath, ['--no-addons', fileURLToPath(new URL('./fixtures/companion-receipts-runner-crash.mjs', import.meta.url)), f.root, 'after-write-claim'],
      {stdio: ['ignore', 'pipe', 'pipe']});
    let stderr = ''; child.stderr.on('data', data => { stderr += data; });
    const died = await new Promise((resolve, reject) => {
      const timer = setTimeout(() => { child.kill('SIGKILL'); reject(new Error('Child missed claim: ' + stderr)); }, 10000);
      child.on('error', reject); child.on('exit', (code, signal) => { clearTimeout(timer); resolve({code, signal}); });
    });
    assert.deepEqual(died, {code: null, signal: 'SIGKILL'}, stderr);
  }
  const next = await openReceipts(f.root); t.after(() => next.close());
  const before = next.store.read(f.body.taskId);
  assert.equal(before.budget.spentMs + before.budget.heldMs, 300000);
  assert(before.steps.at(-1).reserveMs < 120000, 'the third claim receives only the actual remaining budget');
  next.start(); await next.settled(); const after = next.store.snapshot(f.body.taskId);
  assert.equal(after.state, 'failed'); assert.equal(after.waitReason, 'execution_budget_exhausted');
  assert.equal(after.budget.heldMs, before.budget.heldMs); assert.equal(next.counters.executions, 0);
  assert.equal(next.counters.readNames.length, 0); assert.equal(next.counters.links, 0); assert.equal(next.counters.stages, 0);
  assert.deepEqual(after.artifacts, []);
});

test('J SOURCE_HTTP all four originals replaced at write verification keep old read facts and the new failed empty-field report', async t => {
  let f, reads = 0;
  const fixtures = Array.from({length: 4}, (_, i) => ({name: `receipt-${i}.txt`, bytes: Buffer.from(textReceipt)}));
  f = await receiptFixture(t, {fixtures, read: async (_args, actual) => {
    if (++reads === 5) for (const value of fixtures) {
      await rename(join(f.root, 'notes', value.name), join(f.root, 'original-' + value.name));
      await putDraft(f.root, value.name, textReceipt.replace('128.50', '999.99'));
    }
    return actual();
  }});
  const {snapshot} = await completeReceipts(f), original = snapshot.steps[0].result.completion.report;
  const failed = snapshot.steps[1].result.completion.report;
  assert.equal(snapshot.state, 'failed'); assert.equal(snapshot.waitReason, 'receipt_fields_unavailable');
  assert.equal(snapshot.steps[1].state, 'failed'); assert.equal(snapshot.steps[1].reason, 'receipt_fields_unavailable');
  assert.equal(original.coverage.rowsWithVerifiedFields, 4); assert.equal(failed.coverage.rowsWithVerifiedFields, 0);
  assert(failed.sources.every(value => !value.verifiedAtPublish && value.reason === 'input_changed_at_publish'));
  assert.deepEqual(snapshot.artifacts, []); assert.equal(f.counters.links, 0); assert.equal(f.counters.stages, 0);
  if (process.env.J_RECEIPT_WIRE_FIXTURE) await writeFile(process.env.J_RECEIPT_WIRE_FIXTURE + '.all-changed.json', JSON.stringify({
    create: f.body, inputs: f.inputs, complete: snapshot}, null, 2) + '\n');
});

test('J SOURCE_HTTP controlled wall deadline after staging stops any new publication', async t => {
  const realNow = Date.now; let offset = 0, f;
  t.mock.method(Date, 'now', () => realNow() + offset);
  f = await receiptFixture(t, {stage: async (_args, actual) => {
    const reference = await actual(); offset = 120000; return reference;
  }});
  const body = {...f.body, deadlineAtMs: realNow() + 60000}; const {snapshot} = await completeReceipts(f, body);
  assert.equal(snapshot.state, 'failed'); assert.equal(snapshot.waitReason, 'deadline_expired');
  assert.equal(snapshot.artifacts.length, 0); assert.equal(f.counters.links, 0);
});

test('J SOURCE_HTTP a later same-byte different-object replacement fails original workbook identity on open', async t => {
  const f = await receiptFixture(t); const {snapshot} = await completeReceipts(f), path = artifactPath(f, snapshot);
  const original = await f.raw(path), name = join(f.root, 'notes', f.body.args.outputName);
  await rename(name, join(f.root, 'original-published-workbook')); await writeFile(name, original.bytes);
  assert.equal((await f.raw(path)).status, 409); assert.deepEqual(f.store.snapshot(snapshot.taskId).artifacts, snapshot.artifacts);
  assert.equal(f.counters.links, 1);
});

for (const operation of ['amend', 'cancel'])
test('J SOURCE_RESTART actual old publication discovered after accepted ' + operation + ' keeps its original workbook and history', async t => {
  const fixtures = Array.from({length: 4}, (_, i) => ({name: `receipt-${i}.txt`, bytes: Buffer.from(textReceipt)}));
  const f = await receiptFixture(t, {fixtures}); f.store.runner.wake = () => undefined;
  await f.request('', f.body); await f.close();
  const child = spawn(process.execPath, ['--no-addons', fileURLToPath(new URL('./fixtures/companion-receipts-runner-crash.mjs', import.meta.url)), f.root, 'after-link'],
    {stdio: ['ignore', 'pipe', 'pipe']});
  let stderr = ''; child.stderr.on('data', data => { stderr += data; });
  const died = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => { child.kill('SIGKILL'); reject(new Error('Child missed old publication: ' + stderr)); }, 10000);
    child.on('error', reject); child.on('exit', (code, signal) => { clearTimeout(timer); resolve({code, signal}); });
  });
  assert.deepEqual(died, {code: null, signal: 'SIGKILL'}, stderr);
  const next = await openReceipts(f.root, {link() { assert.fail('The historical possible-send step cannot relink'); }});
  t.after(() => next.close());
  const original = next.store.snapshot(f.body.taskId); assert.equal(original.artifacts.length, 0);
  const command = {v:1,hostStoreId:f.body.hostStoreId,kind:f.body.kind,operationId:'late-'+operation,expectedTaskRev:1,taskRev:2, ...(operation === 'amend' ? {changes: {
    args: {...f.body.args, outputName: '新的约定.xlsx'}, deadlineAtMs: null, afterExit: 'continue', allowQueue: true}} : {})};
  // The original store really accepts this command before its supervised read-only reconciliation.
  const response = await next.request(`/${f.body.taskId}/${operation}`, command);
  assert.equal(response.status, 200, JSON.stringify(response.body)); assert.equal(response.body.taskRev, 2);
  next.start(); await next.settled(); const after = next.store.snapshot(f.body.taskId);
  assert.equal(after.taskRev, 2); assert.equal(after.artifacts.length, 1); assert.equal(after.artifacts[0].taskRev, 1);
  assert.equal(after.artifacts[0].relativePath, f.body.args.outputName); assert.equal(next.counters.links, 0);
  assert.equal(after.state, operation === 'amend' ? 'partial' : 'cancelled');
  if (operation === 'amend') assert.equal(after.waitReason, 'prior_revision_effect');
  const opened = await next.raw(artifactPath(next, after)); assert.equal(opened.status, 200);
  const workbook = parseActualWorkbook(next, after, opened.bytes);
  assert.equal(after.steps.some(value => value.taskRev === 2), false, 'no new agreement is falsely reported executed');
  assert(!((await readdir(join(f.root, 'notes'))).includes('新的约定.xlsx')));
  if (process.env.J_RECEIPT_WIRE_FIXTURE) await writeFile(process.env.J_RECEIPT_WIRE_FIXTURE + `.late-${operation}.json`, JSON.stringify({
    create: f.body, inputs: f.inputs, original, operation: command, accepted: response.body, complete: after,
    workbookBase64: opened.bytes.toString('base64'), expectedCells: workbook.rows}, null, 2) + '\n');
  if (process.env.J_RECEIPT_WIRE_FIXTURE) await writeFile(process.env.J_RECEIPT_WIRE_FIXTURE + `.late-${operation}.xlsx`, opened.bytes);
});
