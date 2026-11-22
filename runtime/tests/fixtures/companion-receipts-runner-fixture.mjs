// Actual pinned Domain/JSON, raw anchored filesystem, PDF worker and loopback HTTP.
// The fixed-turn execution owner is controlled unless an explicit executionFactory is supplied.
import assert from 'node:assert/strict';
import {link, mkdir, mkdtemp, rm, writeFile} from 'node:fs/promises';
import {join} from 'node:path';
import {openFind, putDraft, load} from './companion-find-runner-fixture.mjs';
import {ordinary, textLines, paintImage} from './companion-receipt-pdf.mjs';
const {createReceiptsToSheetRunner, receiptInputFormats} = await load('companion/receipts-to-sheet.js');
const {verifyReceiptWorkbook} = await load('companion/receipt-workbook.js');
export const textReceipt = '日期：2026-11-20\n项目：交通\n金额：CNY 128.50\n';
export const receiptReportOf = snapshot => snapshot.steps.findLast(value => value.result?.completion?.report)?.result.completion.report;
export const receiptOperation = (f, expectedTaskRev = 1, operationId = 'receipt-operation') => ({v: 1,
  hostStoreId: f.store.hostStoreId, kind: 'host.receipts_to_sheet', operationId, expectedTaskRev, taskRev: expectedTaskRev + 1});

function receiptHost(f, options = {}) {
  const counters = {readNames: [], links: 0, artifactReads: 0, stages: 0, executions: 0, turns: 0, approvals: 0};
  const fs = f.fs; fs.internals.companionStatfs = async () => ({type: 0xef53n});
  const read = fs.dshGoReadReceipt.bind(fs), artifact = fs.dshGoReadTaskArtifactBytes.bind(fs), stage = fs.dshGoStageNotesFile.bind(fs);
  fs.dshGoReadReceipt = async (...args) => { counters.readNames.push(args[1].name);
    return options.read ? options.read(args, () => read(...args), f) : read(...args); };
  fs.dshGoReadTaskArtifactBytes = async (...args) => { counters.artifactReads++;
    return options.artifactRead ? options.artifactRead(args, () => artifact(...args), f) : artifact(...args); };
  fs.dshGoStageNotesFile = async (...args) => { counters.stages++;
    return options.stage ? options.stage(args, () => stage(...args), f) : stage(...args); };
  fs.internals.linkFile = async (from, to) => { counters.links++;
    return options.link ? options.link(from, to, f) : link(from, to); };
  const execution = options.executionFactory?.(f, counters) ?? {async openExecution(record, signal, config) {
    counters.executions++; assert.deepEqual(config, {requireModel: false}); assert.equal(record.kind, 'host.receipts_to_sheet');
    const policy = options.sandboxed ? {mode: 'read-only', workspaceRoot: join(f.root, 'notes')} : undefined;
    return {selected: null, fs, llm: new Proxy({}, {get() { assert.fail('J must never enter a model API'); }}),
      guard() { signal.throwIfAborted(); options.guard?.(f); }, standingPolicy: policy,
      async runTurn(job) { counters.turns++; return job(signal); },
      async approve(key, request) { counters.approvals++; assert.equal(key, 'writeSheet');
        assert.equal(f.store.read(record.taskId).budget.heldMs, 0, 'real approval waiting must have no active hold');
        if (options.approve) return options.approve(key, request, f, signal);
        assert.fail('A test may not auto-approve a sandbox write'); }};
  }};
  let work;
  const start = () => {
    assert.equal(f.store.runner, null);
    const runner = createReceiptsToSheetRunner({ctx: {get: key => key === 'fs' ? fs : undefined}, store: f.store, execution});
    f.store.attachRunner({...runner, kinds: ['host.receipts_to_sheet'], receiptFormats: receiptInputFormats(),
      wake(id) { work = runner.wake(id); return work; }});
    for (const id of f.store.runnable()) f.store.wake(id);
    return runner;
  };
  const raw = async path => {
    const response = await fetch(f.base + path, {headers: {authorization: 'owner'}, redirect: 'error'});
    return {status: response.status, mediaType: response.headers.get('content-type'),
      length: response.headers.get('content-length'), cache: response.headers.get('cache-control'),
      bytes: Buffer.from(await response.arrayBuffer())};
  };
  return {...f, counters, originalCounters: f.counters, start, raw, settled: () => work};
}
export async function openReceipts(root, options = {}) { return receiptHost(await openFind(root, options), options); }
export async function receiptFixture(t, options = {}) {
  const root = await mkdtemp(join(process.cwd(), 'receipts-source-'));
  await mkdir(join(root, 'notes')); await mkdir(join(root, 'storage'));
  const f = await openReceipts(root, options); f.start();
  t.after(async () => { await f.close(); await rm(root, {recursive: true, force: true}); });
  const folder = (await f.request('/folders', {v: 1, hostStoreId: f.store.hostStoreId, path: join(root, 'notes')})).body;
  const fixtures = options.fixtures ?? [
    {name: '01交通.txt', bytes: Buffer.from(textReceipt)},
    {name: '02hotel.md', bytes: Buffer.from('Date: 2026-11-21\nItem: Hotel\nAmount: USD 90.00\n')},
    {name: '03train.pdf', bytes: ordinary([textLines(['Date: 2026-11-20', 'Item: Train', 'Amount: CNY 80.00'])])},
    {name: '04scan.pdf', bytes: ordinary([paintImage])},
  ];
  const inputs = [];
  for (const fixture of fixtures) {
    await putDraft(root, fixture.name, fixture.bytes);
    const response = await f.request('/inputs', {v: 1, hostStoreId: f.store.hostStoreId,
      kind: 'host.receipts_to_sheet', folderRef: folder.folderRef, name: fixture.name});
    assert.equal(response.status, 201, JSON.stringify(response.body)); inputs.push(response.body);
  }
  const body = {v: 1, hostStoreId: f.store.hostStoreId, taskId: 'receipts-one', taskRev: 1, kind: 'host.receipts_to_sheet',
    origin: {sourceSessionId: 'light:original-room', messageId: 'receipt-message', itemNo: 0}, hostSessionId: null,
    args: {inputs: inputs.map(value => ({sourceRef: value.sourceRef, version: value.version})), outputDirRef: folder.folderRef,
      outputName: '差旅小表.xlsx', writeMode: 'createNew'}, deadlineAtMs: null, afterExit: 'continue', allowQueue: true};
  return {...f, folder, fixtures, inputs, body};
}
export async function completeReceipts(f, body = f.body) {
  const response = await f.request('', body); assert.equal(response.status, 201, JSON.stringify(response.body));
  await f.settled();
  return {response, snapshot: (await f.request(`/${body.taskId}?hostStoreId=${f.store.hostStoreId}`)).body};
}
export const artifactPath = (f, snapshot, artifact = snapshot.artifacts[0]) =>
  `/${snapshot.taskId}/artifacts/${artifact.artifactId}/content?hostStoreId=${snapshot.hostStoreId}&hostExecutionId=${snapshot.hostExecutionId}`;
export const parseActualWorkbook = (f, snapshot, bytes) => verifyReceiptWorkbook(bytes,
  f.store.read(snapshot.taskId).notes[String(snapshot.artifacts[0].taskRev)].candidate.grid);
