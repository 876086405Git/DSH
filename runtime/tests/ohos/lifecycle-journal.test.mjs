import test from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { openBoundaryJournal, snapshot } from '../../ohos/lifecycle/journal.mjs';

const binding = process._linkedBinding('dsh_ohos_publication');
const body = (kind, extra = {}) => ({ kind, bootId: 'boot-A', sessionId: 'session-A', callSeq: 3, callId: 'same', turn: 1, step: 1, ...extra });
async function fixture(t, options = {}) {
  const root = await fs.mkdtemp(join(tmpdir(), 'dsh-lifecycle-log-'));
  const directory = join(root, 'private');
  const journals = [];
  t.after(async () => {
    for (const journal of journals) await journal.close();
    await fs.rm(root, { recursive: true, force: true });
  });
  const open = async overrides => {
    const journal = await openBoundaryJournal({ directory, lockExclusive: binding.lockExclusive, ...options, ...overrides });
    journals.push(journal); return journal;
  };
  return { root, directory, open, journal: await open() };
}

test('real file sync precedes resolved records; one native flock rejects another writer', async t => {
  const observed = [];
  const f = await fixture(t, { onStage(stage, row) { observed.push([stage, row.body?.kind]); } });
  await f.journal.append(body('prepared'));
  await f.journal.append(body('dispatch'));
  assert.deepEqual(observed.filter(row => row[0] === 'record-durable').map(row => row[1]), ['prepared', 'dispatch']);
  assert.deepEqual(f.journal.records.map(row => row.seq), [0, 1, 2]);
  assert.equal((await fs.stat(join(f.directory, 'boundary.jsonl'))).mode & 0o777, 0o600);
  await assert.rejects(f.open(), error => ['EAGAIN', 'EWOULDBLOCK'].includes(error.code));
  await f.journal.close();
  const again = await f.open();
  assert.equal(again.corruption, null);
  assert.equal(again.records.at(-1).body.kind, 'dispatch');
});

test('outcomes reference synced exact JSON bytes; identical concurrent results share verified content', async t => {
  const f = await fixture(t);
  const result = { content: [{ type: 'text', text: '中文\u0000完整结果' }], isError: false };
  const [a, b] = await Promise.all([
    f.journal.appendResult(body('returned'), result),
    f.journal.appendResult(body('outcome'), result),
  ]);
  assert.deepEqual(a.body.result, b.body.result);
  assert.deepEqual(await f.journal.readResult(b.body.result), result);
  assert.deepEqual(await fs.readdir(join(f.directory, 'results')), [b.body.result.sha256 + '.json']);
  assert.equal((await fs.stat(join(f.directory, b.body.result.path))).mode & 0o777, 0o600);
});

for (const damage of ['tail', 'checksum', 'sequence', 'empty']) test(`real ${damage} corruption preserves prefix and refuses new dispatch`, async t => {
  const f = await fixture(t);
  await f.journal.append(body('prepared')); await f.journal.append(body('dispatch'));
  await f.journal.close();
  const path = join(f.directory, 'boundary.jsonl');
  const bytes = await fs.readFile(path);
  if (damage === 'tail') await fs.writeFile(path, bytes.subarray(0, -7));
  if (damage === 'empty') await fs.writeFile(path, '');
  if (damage === 'checksum') await fs.writeFile(path, bytes.toString().replace('session-A', 'session-X'));
  if (damage === 'sequence') {
    const rows = bytes.toString().trimEnd().split('\n'); rows.splice(1, 1); await fs.writeFile(path, rows.join('\n') + '\n');
  }
  const damaged = await fs.readFile(path);
  const again = await f.open();
  assert(again.corruption);
  await assert.rejects(again.append(body('dispatch')), { code: 'ERR_OHOS_LIFECYCLE_CORRUPT' });
  assert.deepEqual(await fs.readFile(path), damaged, 'no truncation or silent repair');
});

test('missing or changed result is explicit unknown evidence, never an empty success', async t => {
  const f = await fixture(t);
  const row = await f.journal.appendResult(body('outcome'), { content: [{ type: 'text', text: 'saved' }] });
  const path = join(f.directory, row.body.result.path);
  await fs.writeFile(path, 'changed');
  await assert.rejects(f.journal.readResult(row.body.result), { code: 'ERR_OHOS_LIFECYCLE_CORRUPT' });
  await fs.unlink(path);
  await assert.rejects(f.journal.readResult(row.body.result), { code: 'ERR_OHOS_LIFECYCLE_CORRUPT' });
});

test('a real partial append failure poisons later requests and leaves a nonempty corrupt tail', async t => {
  let armed = false;
  const f = await fixture(t, { fs: { ...fs, async open(path, ...args) {
    const handle = await fs.open(path, ...args);
    if (!String(path).endsWith('boundary.jsonl')) return handle;
    return new Proxy(handle, { get(target, key) {
      if (key === 'write') return async (bytes, offset, length, position) => {
        if (!armed) return target.write(bytes, offset, length, position);
        await target.write(bytes, offset, Math.min(9, length), position);
        throw Object.assign(new Error('real short append then EIO'), { code: 'EIO' });
      };
      const value = target[key]; return typeof value === 'function' ? value.bind(target) : value;
    } });
  } } });
  await f.journal.append(body('prepared')); armed = true;
  await assert.rejects(f.journal.append(body('dispatch')), { code: 'EIO' });
  await assert.rejects(f.journal.append(body('dispatch')), { code: 'ERR_OHOS_LIFECYCLE_POISONED' });
  await f.journal.close();
  const again = await f.open({ fs });
  assert.equal(again.corruption.reason, 'incomplete-tail');
  assert.equal(again.records.at(-1).body.kind, 'prepared');
});

test('closing seals admission before waiting; late append cannot race a closed fd', async t => {
  const reached = Promise.withResolvers(), release = Promise.withResolvers();
  const f = await fixture(t, { async onStage(stage) {
    if (stage === 'before-record') { reached.resolve(); await release.promise; }
  } });
  const pending = f.journal.append(body('prepared'));
  await reached.promise;
  const closing = f.journal.close();
  await assert.rejects(f.journal.append(body('dispatch')), { code: 'ERR_OHOS_LIFECYCLE_CLOSED' });
  release.resolve(); await pending; await closing;
  const again = await f.open({ onStage() {} });
  assert.equal(again.records.at(-1).body.kind, 'prepared');
});

test('snapshot rejects getter/cycle/exotic/sparse data and copies exact JSON without mutation', () => {
  const value = { ['__proto__']: { preserved: true }, list: ['中文', null, 2, false] };
  const copy = snapshot(value);
  assert.deepEqual(copy, value); assert.notEqual(copy.list, value.list);
  let reads = 0; const getter = { get secret() { reads++; return 'must not read'; } };
  const cycle = {}; cycle.self = cycle;
  for (const bad of [getter, cycle, new Date(), { missing: undefined }, [,,], -0, NaN]) assert.throws(() => snapshot(bad));
  assert.equal(reads, 0);
});
