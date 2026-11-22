// Companion state and persistence boundaries. Uses only synthetic data and built-ins.
//   node --test runtime/tests/companion-store.test.mjs
import assert from 'node:assert/strict';
import { test } from 'node:test';
import * as fs from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { randomUUID } from 'node:crypto';
import {
  advanceState, applyEvent, initialState, publicState,
} from '../bridge/dsh-go-bridge/lib/companion/state.js';
import { MAX_FILE_BYTES, validMemory } from '../bridge/dsh-go-bridge/lib/companion/schema.js';
import { createCompanionStore } from '../bridge/dsh-go-bridge/lib/companion/store.js';

const MINUTE = 60_000;
const HOUR = 60 * MINUTE;
const START = 1_700_000_000_000;
const TYPES = ['visit', 'pet', 'snack', 'play', 'rest'];
const idFor = (n) => `00000000-0000-4000-8000-${n.toString(16).padStart(12, '0')}`;
const versionOf = (value) => ({ storeId: value.storeId, expectedRevision: value.revision });
const memory = (overrides = {}) => ({
  id: randomUUID(), kind: 'fact', text: 'A synthetic saved fact.', keywords: [], pinned: false,
  source: { kind: 'manual' }, expiresAt: null, ...overrides,
});

function near(actual, expected, label) {
  assert.ok(Math.abs(actual - expected) <= 1e-12, `${label}: ${actual} != ${expected}`);
}

async function rejects(operation, status, code) {
  await assert.rejects(async () => operation(), (error) => {
    assert.equal(error.status, status);
    assert.equal(error.code, `companion/${code}`);
    return true;
  });
}

async function fixture(t, options = {}) {
  const root = await fs.mkdtemp(join(process.env.DSH_GO_TEST_TMP || tmpdir(), 'dsh-go-companion-'));
  const filePath = join(root, 'companion', 'state.json');
  let at = START;
  const now = () => at;
  const store = createCompanionStore({ filePath, now, ...options });
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  return { root, filePath, now, store, setTime(value) { at = value; } };
}

async function save(store, record, current) {
  const snapshot = current ?? await store.getSnapshot();
  return store.upsertMemory({ ...versionOf(snapshot), memory: record });
}

test('state half-lives and segmented time projection agree without mutating their input', () => {
  const state = { ...initialState(START), valence: 0.85, energy: 0.15, closeness: 0.6 };
  const original = structuredClone(state);
  const after40 = advanceState(state, START + 40 * MINUTE);
  near(after40.valence, 0.55, 'valence after one half-life');
  const after120 = advanceState(state, START + 2 * HOUR);
  near(after120.energy, 0.45, 'energy after one half-life');
  const segmented = advanceState(after40, START + 2 * HOUR);
  near(segmented.valence, after120.valence, 'segmented valence');
  near(segmented.energy, after120.energy, 'segmented energy');
  assert.equal(segmented.closeness, state.closeness);
  assert.equal(segmented.anchorAt, START + 2 * HOUR);
  assert.deepEqual(state, original);
  assert.notEqual(after40.lastEvents, state.lastEvents);
});

test('clock rollback cannot move an anchor backwards or accrue the same interval twice', () => {
  const visited = applyEvent(initialState(START), 'visit', START);
  const future = advanceState(visited, START + HOUR);
  const rollback = advanceState(future, START + MINUTE);
  assert.deepEqual(rollback, future);
  const resumed = advanceState(rollback, START + 2 * HOUR);
  const direct = advanceState(visited, START + 2 * HOUR);
  near(resumed.valence, direct.valence, 'rollback valence');
  near(resumed.energy, direct.energy, 'rollback energy');
  assert.equal(applyEvent(visited, 'visit', START - MINUTE), null);
  const differentEvent = applyEvent(visited, 'pet', START - MINUTE);
  assert.equal(differentEvent.lastInteractionAt, START);
  assert.equal(differentEvent.closeness, visited.closeness);
});

test('long absence relaxes to comfortable baselines without reducing closeness', () => {
  const state = { ...initialState(START), valence: 1, energy: 0, closeness: 0.73 };
  const later = advanceState(state, START + 365 * 24 * HOUR);
  assert.equal(later.valence, 0.25);
  assert.equal(later.energy, 0.75);
  assert.equal(later.closeness, 0.73);
});

test('all five event types have independent 30-second cooldown boundaries', () => {
  for (const type of TYPES) {
    const first = applyEvent(initialState(START), type, START);
    assert.ok(first, `${type} first event`);
    assert.equal(applyEvent(first, type, START + 29_999), null, `${type} before boundary`);
    const next = applyEvent(first, type, START + 30_000);
    assert.ok(next, `${type} at boundary`);
    assert.equal(next.lastEvents[type], START + 30_000);
  }
  const visited = applyEvent(initialState(START), 'visit', START);
  assert.ok(applyEvent(visited, 'pet', START), 'a visit does not consume the pet cooldown');
});

test('closeness gains share a six-hour window and rest cannot consume or award a gain', () => {
  const first = applyEvent(initialState(START), 'visit', START);
  assert.equal(first.closeness, 0.01);
  const before = applyEvent(first, 'pet', START + 6 * HOUR - 1);
  assert.equal(before.closeness, 0.01);
  const boundary = applyEvent(before, 'snack', START + 6 * HOUR);
  assert.equal(boundary.closeness, 0.02);
  const sameWindow = applyEvent(boundary, 'play', START + 6 * HOUR);
  assert.equal(sameWindow.closeness, 0.02);
  const rested = applyEvent(sameWindow, 'rest', START + 12 * HOUR);
  assert.equal(rested.closeness, 0.02);
  assert.equal(rested.lastGainAt, START + 6 * HOUR);
  const nextGain = applyEvent(rested, 'visit', START + 12 * HOUR);
  assert.equal(nextGain.closeness, 0.03);
});

test('visit and pet preserve current activities, which end exactly at their deadline', () => {
  for (const [type, duration] of [['snack', 45_000], ['play', 90_000], ['rest', 15 * MINUTE]]) {
    const started = applyEvent(initialState(START), type, START);
    const visited = applyEvent(started, 'visit', START + 1);
    const touched = applyEvent(visited, 'pet', START + 2);
    assert.equal(touched.activity, type);
    assert.equal(touched.activityUntil, START + duration);
    assert.equal(advanceState(touched, START + duration - 1).activity, type);
    const ended = advanceState(touched, START + duration);
    assert.equal(ended.activity, 'idle');
    assert.equal(ended.activityUntil, null);
  }
});

test('rule values are clamped and public state omits persistence internals', () => {
  const high = { ...initialState(START), valence: 0.99, energy: 0.99, closeness: 0.995 };
  const snack = applyEvent(high, 'snack', START);
  assert.equal(snack.valence, 1);
  assert.equal(snack.energy, 1);
  assert.equal(snack.closeness, 1);
  const low = applyEvent({ ...initialState(START), energy: 0.01 }, 'play', START);
  assert.equal(low.energy, 0);
  const visible = publicState(snack, START);
  assert.equal(visible.thought, 'enjoy-snack');
  for (const key of ['anchorAt', 'lastEvents', 'lastGainAt']) assert.equal(Object.hasOwn(visible, key), false);
});

test('small state reads follow the file size and keep reading if it grows after stat', async t => {
  const f = await fixture(t);
  const initial = await f.store.getSnapshot();
  const size = (await fs.stat(f.filePath)).size;
  const buffers = new Set();
  let append = '';
  const store = createCompanionStore({filePath: f.filePath, now: f.now, io: {...fs, async open(...args) {
    const handle = await fs.open(...args);
    return {
      async stat() {
        const info = await handle.stat();
        if (append) await fs.appendFile(f.filePath, append);
        return info;
      },
      read(buffer, offset, length, position) {
        buffers.add(buffer.length);
        return handle.read(buffer, offset, Math.min(length, 64 * 1024), position);
      },
      close: () => handle.close(),
    };
  }}});
  assert.deepEqual(await store.getSnapshot(), initial);
  assert.deepEqual([...buffers], [size + 1]);
  append = '  ';
  assert.deepEqual(await store.getSnapshot(), initial);
  assert.deepEqual([...buffers], [size + 1, MAX_FILE_BYTES + 1]);
  append = ' '.repeat(MAX_FILE_BYTES);
  await rejects(() => store.getSnapshot(), 503, 'corrupt-store');
});

test('store identity, state and memories survive reopening the file', async (t) => {
  const f = await fixture(t);
  const initial = await f.store.getSnapshot();
  const event = await f.store.event({ ...versionOf(initial), type: 'play' });
  const saved = await save(f.store, memory({ text: '喜欢无糖茶。', keywords: ['茶'] }), event);
  const reopened = createCompanionStore({ filePath: f.filePath, now: f.now });
  assert.deepEqual(await reopened.getSnapshot(), await f.store.getSnapshot());
  assert.equal((await reopened.getSnapshot()).storeId, initial.storeId);
  assert.deepEqual((await reopened.getMemories()).memories, [saved.memory]);
  assert.equal(saved.revision, 2);
  assert.equal(saved.memoryRevision, 1);
});

test('separate store objects serialize first initialization and compare-and-swap writes', async (t) => {
  const f = await fixture(t);
  const second = createCompanionStore({ filePath: f.filePath, now: f.now });
  const [a, b] = await Promise.all([f.store.getSnapshot(), second.getSnapshot()]);
  assert.equal(a.storeId, b.storeId);
  const results = await Promise.allSettled([
    f.store.event({ ...versionOf(a), type: 'visit' }),
    second.event({ ...versionOf(b), type: 'pet' }),
  ]);
  const fulfilled = results.filter((r) => r.status === 'fulfilled');
  const rejected = results.filter((r) => r.status === 'rejected');
  assert.equal(fulfilled.length, 1);
  assert.equal(rejected.length, 1);
  assert.equal(rejected[0].reason.status, 409);
  assert.equal(rejected[0].reason.code, 'companion/conflict');
  const current = await second.getSnapshot();
  assert.equal(current.revision, 1);
  assert.equal(current.memoryRevision, 0);
  const continued = await save(second, memory({ text: 'Queue remains usable after a conflict.' }), current);
  assert.equal(continued.revision, 2);
});

test('reads project time without writing, and the store schedules no background timers', async (t) => {
  const handles = [];
  const originalTimeout = globalThis.setTimeout;
  const originalInterval = globalThis.setInterval;
  t.mock.method(globalThis, 'setTimeout', (...args) => {
    const handle = originalTimeout(...args);
    handles.push(handle);
    return handle;
  });
  t.mock.method(globalThis, 'setInterval', (...args) => {
    const handle = originalInterval(...args);
    handles.push(handle);
    return handle;
  });
  t.after(() => { for (const handle of handles) clearTimeout(handle); });
  let renames = 0;
  const io = { ...fs, async rename(...args) { renames++; return fs.rename(...args); } };
  const f = await fixture(t, { io });
  const initial = await f.store.getSnapshot();
  await f.store.event({ ...versionOf(initial), type: 'play' });
  const bytes = await fs.readFile(f.filePath);
  const writes = renames;
  f.setTime(START + 24 * HOUR);
  const later = await f.store.getSnapshot();
  await f.store.getMemories();
  await f.store.getContext({ query: 'anything' });
  await f.store.exportData();
  assert.equal(later.revision, 1);
  assert.equal(later.memoryRevision, 0);
  assert.equal(later.state.activity, 'idle');
  assert.equal(renames, writes);
  assert.deepEqual(await fs.readFile(f.filePath), bytes);
  assert.equal(handles.length, 0);
});

test('a cooled-down event is a no-op and memory edits do not change state', async (t) => {
  const f = await fixture(t);
  const initial = await f.store.getSnapshot();
  const touched = await f.store.event({ ...versionOf(initial), type: 'pet' });
  f.setTime(START + 1);
  const repeated = await f.store.event({ ...versionOf(touched), type: 'pet' });
  assert.equal(repeated.eventApplied, false);
  assert.equal(repeated.revision, touched.revision);
  const before = JSON.parse(await fs.readFile(f.filePath, 'utf8')).state;
  const saved = await save(f.store, memory());
  const after = JSON.parse(await fs.readFile(f.filePath, 'utf8')).state;
  assert.deepEqual(after, before);
  assert.equal(saved.memoryRevision, 1);
});

test('wrong store identity and stale revision never overwrite accepted changes', async (t) => {
  const f = await fixture(t);
  const initial = await f.store.getSnapshot();
  const saved = await save(f.store, memory({ text: 'Keep this exact fact.' }), initial);
  const bytes = await fs.readFile(f.filePath);
  await rejects(() => f.store.clearMemories({ storeId: randomUUID(), expectedRevision: saved.revision }), 409, 'store-changed');
  await rejects(() => f.store.clearMemories(versionOf(initial)), 409, 'conflict');
  assert.deepEqual(await fs.readFile(f.filePath), bytes);
});

test('corrupt, oversized and invalid-UTF-8 stores are preserved instead of reset', async (t) => {
  const cases = [
    ['invalid JSON', Buffer.from('{"unfinished":')],
    ['invalid UTF-8', Buffer.from([0xff, 0xfe, 0x7b, 0x7d])],
    ['oversized', Buffer.alloc(MAX_FILE_BYTES + 1, 0x20)],
    ['wrong schema', Buffer.from('{"v":99}')],
  ];
  for (const [name, content] of cases) {
    await t.test(name, async (sub) => {
      const f = await fixture(sub);
      await fs.mkdir(dirname(f.filePath), { recursive: true });
      await fs.writeFile(f.filePath, content);
      await rejects(() => f.store.getSnapshot(), 503, 'corrupt-store');
      await rejects(() => f.store.clearMemories({ storeId: idFor(1), expectedRevision: 0 }), 503, 'corrupt-store');
      assert.deepEqual(await fs.readFile(f.filePath), content);
    });
  }
});

test('duplicate persisted memory IDs differing only by case are rejected without repair', async (t) => {
  const f = await fixture(t);
  await save(f.store, memory({ id: 'abcdefab-cdef-4abc-8def-abcdefabcdef' }));
  const doc = JSON.parse(await fs.readFile(f.filePath, 'utf8'));
  doc.memories.push({ ...doc.memories[0], id: doc.memories[0].id.toUpperCase() });
  const corruptBytes = Buffer.from(JSON.stringify(doc));
  await fs.writeFile(f.filePath, corruptBytes);
  await rejects(() => f.store.getMemories(), 503, 'corrupt-store');
  assert.deepEqual(await fs.readFile(f.filePath), corruptBytes);
});

test('rename failure preserves the old file and revision, removes temporary data and permits retry', async (t) => {
  const f = await fixture(t);
  const saved = await save(f.store, memory({ text: 'Persisted before simulated disk failure.' }));
  const bytes = await fs.readFile(f.filePath);
  const failing = createCompanionStore({ filePath: f.filePath, now: f.now, io: {
    ...fs, async rename() { throw Object.assign(new Error('synthetic EIO'), { code: 'EIO' }); },
  } });
  await rejects(() => failing.deleteMemory({ ...versionOf(saved), id: saved.memory.id }), 500, 'io-error');
  assert.deepEqual(await fs.readFile(f.filePath), bytes);
  assert.deepEqual(await fs.readdir(dirname(f.filePath)), ['state.json']);
  const current = await f.store.getMemories();
  assert.equal(current.revision, saved.revision);
  assert.deepEqual(current.memories, [saved.memory]);
  const retried = await f.store.deleteMemory({ ...versionOf(current), id: saved.memory.id });
  assert.equal(retried.deleted, true);
  assert.equal(retried.revision, saved.revision + 1);
});

test('published state skips unlink while a rejected rename cleans the temporary file', async t => {
  let unlinks = 0, failRename = false;
  const io = {...fs,
    async rename(...args) {
      if (failRename) throw new Error('synthetic rename failure');
      return fs.rename(...args);
    },
    async unlink(path) { unlinks++; return fs.unlink(path); },
  };
  const f = await fixture(t, {io});
  const saved = await f.store.getSnapshot();
  assert.equal(unlinks, 0);
  failRename = true;
  await rejects(() => f.store.event({...versionOf(saved), type: 'play'}), 500, 'io-error');
  assert.equal(unlinks, 1);
  assert.deepEqual(await fs.readdir(dirname(f.filePath)), ['state.json']);
});

test('malformed writes fail before initializing a file', async (t) => {
  const f = await fixture(t);
  for (const operation of [
    () => f.store.event({ storeId: idFor(1), expectedRevision: 0, type: 'unknown' }),
    () => f.store.clearMemories({ storeId: idFor(1), expectedRevision: -1 }),
    () => f.store.upsertMemory({ storeId: idFor(1), expectedRevision: 0, memory: memory({ extra: true }) }),
    () => f.store.getContext({ query: 'x'.repeat(257) }),
    () => f.store.getContext({ limit: 13 }),
  ]) await rejects(operation, 400, 'invalid-request');
  await assert.rejects(fs.stat(f.filePath), { code: 'ENOENT' });
});

test('memory text validation avoids code point arrays inside UTF-16 bounds', () => {
  const text = '喜欢无糖茶。', keyword = '茶', sourceId = 'message-1';
  const counted = new Set([text, keyword, sourceId]);
  const iterator = String.prototype[Symbol.iterator];
  let arrays = 0;
  const input = memory({text, keywords: [keyword], source: {kind: 'manual', messageId: sourceId}});
  String.prototype[Symbol.iterator] = function () {
    if (counted.has(this.valueOf())) arrays++;
    return iterator.call(this);
  };
  try {
    assert.equal(validMemory(input), true);
    assert.equal(arrays, 0);
  } finally { String.prototype[Symbol.iterator] = iterator; }
  for (const [value, expected] of [
    ['😀'.repeat(512), true], ['😀'.repeat(513), false],
    ['a'.repeat(512), true], ['a'.repeat(513), false],
    ['\ud800', false], ['\udc00', false], ['😀\ud800', false], ['a\n😀', true],
  ]) assert.equal(validMemory({...input, text: value}), expected);
});

test('Unicode scalar and documented source-ID limits are enforced without truncation', async (t) => {
  const f = await fixture(t);
  const validText = '🐋'.repeat(512);
  const saved = await save(f.store, memory({
    text: validText, keywords: ['🐋'.repeat(24)],
    source: { kind: 'user-confirmed', sessionId: '🐋'.repeat(64), messageId: 'message-1' },
  }));
  assert.equal(saved.memory.text, validText);
  assert.equal(saved.memory.text.length, 1024, 'the text limit counts code points, not UTF-16 code units');
  const invalidMemories = [
    memory({ text: '🐋'.repeat(513) }),
    memory({ text: '\ud800' }),
    memory({ text: '\udfff' }),
    memory({ text: 'hidden\u0000control' }),
    memory({ text: '   \n  ' }),
    memory({ keywords: ['🐋'.repeat(25)] }),
    memory({ keywords: ['line\nbreak'] }),
    memory({ keywords: Array.from({ length: 9 }, (_, n) => `word${n}`) }),
    memory({ source: { kind: 'manual', sessionId: '🐋'.repeat(65) } }),
    memory({ source: { kind: 'manual', messageId: 'bad\nID' } }),
  ];
  for (const invalidMemory of invalidMemories) {
    await rejects(() => f.store.upsertMemory({ ...versionOf(saved), memory: invalidMemory }), 400, 'invalid-request');
  }
  assert.deepEqual((await f.store.getMemories()).memories, [saved.memory]);
  const multiline = await save(f.store, memory({ text: '工作日不喝咖啡。\n周末偶尔喝。' }));
  assert.equal(multiline.memory.text, '工作日不喝咖啡。\n周末偶尔喝。');
});

test('a full 256-record store rejects only new records and preserves existing data', async (t) => {
  const f = await fixture(t);
  let current = await f.store.getSnapshot();
  for (let n = 1; n <= 256; n++) current = await save(f.store, memory({ id: idFor(n), text: `Fact ${n}` }), current);
  await rejects(() => save(f.store, memory({ id: idFor(257) }), current), 409, 'limit-reached');
  assert.equal((await f.store.getMemories()).memories.length, 256);
  const updated = await save(f.store, memory({ id: idFor(1), text: 'The existing record can be corrected.' }), current);
  assert.equal(updated.memory.id, idFor(1));
  assert.equal((await f.store.getMemories()).memories.length, 256);
});

test('replacement preserves creation time, normalizes UUID case and treats identical content as a no-op', async (t) => {
  const f = await fixture(t);
  const record = memory({ id: 'abcdefab-cdef-4abc-8def-abcdefabcdef', text: 'Old preference.',
    source: { kind: 'user-confirmed', sessionId: 'session-1', messageId: 'message-1' } });
  const first = await save(f.store, record);
  f.setTime(START + MINUTE);
  const updated = await save(f.store, { ...record, id: record.id.toUpperCase(), text: 'New preference.' }, first);
  assert.equal(updated.memory.id, record.id);
  assert.equal(updated.memory.createdAt, START);
  assert.equal(updated.memory.updatedAt, START + MINUTE);
  f.setTime(START + 2 * MINUTE);
  const unchanged = await save(f.store, { ...record, text: 'New preference.',
    source: { messageId: 'message-1', sessionId: 'session-1', kind: 'user-confirmed' } }, updated);
  assert.deepEqual(unchanged, updated);
  f.setTime(START - MINUTE);
  const correctedDuringRollback = await save(f.store, { ...record, text: 'Correction during rollback.' }, updated);
  assert.equal(correctedDuringRollback.memory.createdAt, START);
  assert.equal(correctedDuringRollback.memory.updatedAt, START + MINUTE);
  assert.equal((await f.store.getMemories()).memories.length, 1);
});

test('read results are detached from durable memory and queued upserts capture their input', async (t) => {
  const f = await fixture(t);
  const initial = await f.store.getSnapshot();
  const input = { ...versionOf(initial), memory: memory({ text: 'Original confirmed text.', keywords: ['confirmed'], pinned: true }) };
  const pending = f.store.upsertMemory(input);
  input.memory.text = 'Mutated after validation.';
  input.memory.keywords.push('mutated');
  input.expectedRevision = 999;
  const saved = await pending;
  assert.equal(saved.memory.text, 'Original confirmed text.');
  const clone = t.mock.method(globalThis, 'structuredClone');
  const list = await f.store.getMemories();
  const context = await f.store.getContext({ query: 'confirmed' });
  const exported = await f.store.exportData();
  assert.equal(clone.mock.callCount(), 0);
  list.memories[0].text = 'Changed list response.';
  context.memories[0].keywords.push('changed');
  exported.memories[0].source.kind = 'user-confirmed';
  assert.deepEqual((await f.store.getMemories()).memories, [saved.memory]);
});

test('delete and clear remove plaintext from list, retrieval, export and the store file', async (t) => {
  const f = await fixture(t);
  const deletedText = 'Synthetic secret to remove: private-island-083.';
  const first = await save(f.store, memory({ text: deletedText, keywords: ['private-island'], pinned: true }));
  const second = await save(f.store, memory({ text: 'Keep a separate synthetic fact.' }), first);
  const beforeState = JSON.parse(await fs.readFile(f.filePath, 'utf8')).state;
  const deleted = await f.store.deleteMemory({ ...versionOf(second), id: first.memory.id });
  assert.equal(deleted.deleted, true);
  assert.equal(deleted.memoryRevision, second.memoryRevision + 1);
  for (const result of [await f.store.getMemories(), await f.store.getContext({ query: 'private-island' }), await f.store.exportData()]) {
    assert.equal(JSON.stringify(result).includes(deletedText), false);
    assert.equal(JSON.stringify(result).includes(first.memory.id), false);
  }
  assert.equal((await fs.readFile(f.filePath, 'utf8')).includes(deletedText), false);
  assert.deepEqual(await fs.readdir(dirname(f.filePath)), ['state.json']);
  const again = await f.store.deleteMemory({ ...versionOf(deleted), id: first.memory.id });
  assert.equal(again.deleted, false);
  assert.equal(again.revision, deleted.revision);
  const cleared = await f.store.clearMemories(versionOf(again));
  assert.equal(cleared.deletedCount, 1);
  assert.deepEqual((await f.store.getMemories()).memories, []);
  assert.deepEqual((await f.store.exportData()).memories, []);
  assert.deepEqual(JSON.parse(await fs.readFile(f.filePath, 'utf8')).state, beforeState);
  const emptyClear = await f.store.clearMemories(versionOf(cleared));
  assert.equal(emptyClear.deletedCount, 0);
  assert.equal(emptyClear.revision, cleared.revision);
});

test('expiry changes retrieval without a write and unselected records also bound cache lifetime', async (t) => {
  const f = await fixture(t);
  const a = await save(f.store, memory({ id: idFor(1), text: 'First expiry.', keywords: ['expiry'], expiresAt: START + 1_000, pinned: true }));
  const b = await save(f.store, memory({ id: idFor(2), text: 'Second expiry.', keywords: ['expiry'], expiresAt: START + 2_000 }), a);
  const c = await save(f.store, memory({ id: idFor(3), text: 'Permanent.', keywords: ['expiry'] }), b);
  const d = await save(f.store, memory({ id: idFor(4), text: 'Unrelated short-lived record.', expiresAt: START + 500 }), c);
  const before = await f.store.getContext({ query: 'expiry' });
  assert.equal(before.memories.length, 3);
  assert.equal(before.nextExpiryAt, START + 500);
  f.setTime(START + 500);
  const afterUnselected = await f.store.getContext({ query: 'expiry' });
  assert.deepEqual(afterUnselected.memories, before.memories);
  assert.equal(afterUnselected.nextExpiryAt, START + 1_000);
  f.setTime(START + 1_000);
  const atFirst = await f.store.getContext({ query: 'expiry' });
  assert.deepEqual(atFirst.memories.map((m) => m.id), [idFor(2), idFor(3)]);
  assert.equal(atFirst.nextExpiryAt, START + 2_000);
  assert.equal(atFirst.memoryRevision, d.memoryRevision);
  f.setTime(START + 2_000);
  const atSecond = await f.store.getContext({ query: 'expiry' });
  assert.deepEqual(atSecond.memories.map((m) => m.id), [idFor(3)]);
  assert.equal(atSecond.nextExpiryAt, null);
  assert.equal(atSecond.memoryRevision, d.memoryRevision);
  assert.equal((await f.store.getMemories()).memories.length, 4, 'expiry is not deletion');
  assert.equal((await f.store.exportData()).memories.length, 4);
});

test('Chinese keywords and normalized text match while only two unmatched pinned facts are included', async (t) => {
  const f = await fixture(t);
  let current = await f.store.getSnapshot();
  for (let n = 1; n <= 3; n++) {
    f.setTime(START + n);
    current = await save(f.store, memory({ id: idFor(n), text: `Background ${n}.`, pinned: true }), current);
  }
  current = await save(f.store, memory({ id: idFor(4), text: '工作日不喝咖啡，周末偶尔喝。', keywords: ['咖啡'] }), current);
  await save(f.store, memory({ id: idFor(5), text: 'Prefer ＴＥＡ.' }), current);
  const empty = await f.store.getContext({});
  assert.deepEqual(empty.memories.map((m) => m.id), [idFor(3), idFor(2)]);
  const chinese = await f.store.getContext({ query: '想喝咖啡吗', limit: 1 });
  assert.equal(chinese.memories[0].id, idFor(4));
  assert.equal(chinese.memories[0].text, '工作日不喝咖啡，周末偶尔喝。');
  assert.equal(chinese.truncated, true);
  const normalized = await f.store.getContext({ query: 'tea', limit: 1 });
  assert.equal(normalized.memories[0].id, idFor(5));
});

test('context budgets keep whole Unicode records and report count or text truncation', async (t) => {
  const f = await fixture(t);
  let current = await f.store.getSnapshot();
  for (let n = 1; n <= 5; n++) {
    current = await save(f.store, memory({ id: idFor(n), text: '🐋'.repeat(512), keywords: ['whole'] }), current);
  }
  const full = await f.store.getContext({ query: 'whole', limit: 12 });
  assert.equal(full.memories.length, 4);
  assert.equal(full.textCodePoints, 2048);
  assert.equal(full.truncated, true);
  for (const record of full.memories) assert.equal(record.text, '🐋'.repeat(512));
  assert.deepEqual(full.memories.map((m) => m.id), [idFor(1), idFor(2), idFor(3), idFor(4)]);
  const counted = await f.store.getContext({ query: 'whole', limit: 2 });
  assert.equal(counted.memories.length, 2);
  assert.equal(counted.textCodePoints, 1024);
  assert.equal(counted.truncated, true);
  assert.deepEqual(await f.store.getContext({ query: 'whole', limit: 2 }), counted);
});

test('invalid clocks fail before opening or initializing storage', async (t) => {
  const f = await fixture(t);
  for (const value of [-1, 0.5, NaN, Infinity, Number.MAX_SAFE_INTEGER]) {
    f.setTime(value);
    await rejects(() => f.store.getSnapshot(), 503, 'unavailable');
  }
  await assert.rejects(fs.stat(f.filePath), { code: 'ENOENT' });
});
