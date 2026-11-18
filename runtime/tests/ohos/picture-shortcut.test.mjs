import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { shortcutFixture, deferred, settle, until } from './picture-shortcut-fixture.mjs';

const failed = { value: { supported: true, requested: false } };
const success = { value: { supported: true, requested: true } };
const unsupported = { value: { supported: false, requested: false } };
const png = () => new Uint8Array([137, 80, 78, 71]);
const checks = f => f.calls.filter(c => c[0] === 'check');
const requests = f => f.calls.filter(c => c[0] === 'request');
const iconRoot = f => f.context.filesDir + '/picture-shortcuts';
async function slots(f) { return fs.readdir(iconRoot(f)).catch(() => []); }
async function makeSlot(f, age, contents = 'icon.png') {
  const name = String(Date.now() - age) + '-' + randomUUID().replaceAll('-', '');
  await fs.mkdir(iconRoot(f), { recursive: true });
  const path = iconRoot(f) + '/' + name; await fs.mkdir(path);
  await fs.writeFile(path + '/' + contents, 'preserved icon');
  return { name, id: 'picture:' + name, path };
}

test('actual EntryAbility registers picture_shortcut without opening AppGallery', async t => {
  const f = await shortcutFixture(t);
  assert(f.methods, 'PICTURE_SHORTCUT_CHANNEL_MISSING');
  assert.equal(f.kitLoads, 0);
  assert.deepEqual(f.calls, []);
});

test('Android invalid and unknown-method contracts reject before SDK load', async t => {
  const f = await shortcutFixture(t);
  for (const bytes of [null, undefined, 'png', new Uint8Array(), new Uint8Array(2 * 1024 * 1024 + 1)]) {
    assert.deepEqual(await f.call('pin', { png: bytes }).done, { error: 'invalid', message: 'no picture' });
  }
  assert.deepEqual(await f.call('unsupportedMethod').done, { missing: true });
  assert.equal(f.kitLoads, 0);
});

for (const options of [{ capability: false }, { sdk: 13 }, { kitError: true }]) {
  test('missing capability/API/Kit is unsupported: ' + JSON.stringify(options), async t => {
    const f = await shortcutFixture(t, options);
    assert.deepEqual(await f.call().done, unsupported); assert.equal(requests(f).length, 0);
  });
}

test('system confirmation gates the reply/event; own app Want, Unicode label and durable file match contract', async t => {
  const request = deferred(); const f = await shortcutFixture(t, { request: () => request.promise, maxWrite: 17 });
  const call = f.call('pin', { label: ' \n' + '😀'.repeat(25) + '\t tail ', png: png() });
  await until(() => requests(f).length === 1);
  assert.equal(call.replies.length, 0); assert.equal(f.events.length, 0);
  const checked = checks(f)[0][1];
  assert.equal(checked.label, '😀'.repeat(24));
  assert.match(checked.id, /^picture:[0-9]{13}-[0-9a-f]{32}$/);
  assert(Buffer.byteLength(checked.id) <= 63);
  assert.deepEqual(JSON.parse(JSON.stringify(checked.want)), { bundleName: 'ccchimneyyy.dsh.go', moduleName: 'entry', abilityName: 'EntryAbility' });
  assert.equal(checked.background, ''); assert(checked.stored.byteLength <= 100000);
  assert(checked.foreground.startsWith(iconRoot(f) + '/'));
  assert(f.calls.filter(c => c[0] === 'write').length > 1);
  assert(f.objects.every(o => o.released)); assert.equal(f.fds.size, 0);
  request.resolve(); assert.deepEqual(await call.done, success);
  assert.equal(call.replies.length, 1); assert.equal(f.events.length, 1);
  assert.equal(f.events[0].method, 'pinned'); assert.equal(f.events[0].value, null);
  assert.equal((await slots(f)).length, 1); assert.equal((await fs.readFile(checked.foreground)).byteLength, 120);
});

test('label whitespace/default and fresh ID/tid apply to every explicit click', async t => {
  const f = await shortcutFixture(t);
  assert.deepEqual(await f.call('pin', { png: png(), label: ' \t \n ' }).done, success);
  assert.deepEqual(await f.call('pin', { png: png(), label: '  A\n\t B  ' }).done, success);
  assert.equal(checks(f)[0][1].label, 'DSH Go'); assert.equal(checks(f)[1][1].label, 'A B');
  assert.notEqual(checks(f)[0][1].id, checks(f)[1][1].id);
  assert.notEqual(requests(f)[0][1].tid, requests(f)[1][1].tid);
  assert.equal((await slots(f)).length, 2);
});

for (const code of [1006620007, 1006620006, 1006620004, 1006620001, 401]) {
  test('SDK user-cancel/expiry/limit/service/parameter rejection is never successful: ' + code, async t => {
    const f = await shortcutFixture(t, { request() { throw Object.assign(Error('SDK rejection'), { code }); } });
    assert.deepEqual(await f.call().done, failed); assert.equal(f.events.length, 0);
    assert.equal((await slots(f)).length, 0); assert.equal(f.fds.size, 0);
  });
}

for (const checkResult of [{ code: 1006620005, tid: 'rejected' }, { code: 0 },
  { code: 0, tid: '' }, { code: 0, tid: 'expired', expired: 0 }, { code: 0, tid: 'invalid', expired: NaN }]) {
  test('invalid check result never opens a system prompt: ' + JSON.stringify(checkResult), async t => {
    const f = await shortcutFixture(t, { checkResult });
    assert.deepEqual(await f.call().done, failed); assert.equal(requests(f).length, 0);
    assert.equal((await slots(f)).length, 0); assert.equal(f.events.length, 0);
  });
}

test('oversize pictures use at most three aspect-preserving lossless PNG scales', async t => {
  const f = await shortcutFixture(t, { size: { width: 432, height: 216 },
    packSize: size => size.width > 128 ? 100001 : 90000 });
  assert.deepEqual(await f.call().done, success);
  const packed = f.calls.filter(c => c[0] === 'pack');
  assert.deepEqual(packed.map(c => [c[1].width, c[1].height]), [[432, 216], [256, 128], [128, 64]]);
  assert(packed.every(c => c[2].format === 'image/png' && c[2].quality === 100));
  assert.equal(checks(f)[0][1].stored.byteLength, 90000); assert(f.objects.every(o => o.released));
});

test('an encoder still above 100 KB is refused after the third attempt', async t => {
  const f = await shortcutFixture(t, { packSize: () => 100001 });
  assert.deepEqual(await f.call().done, failed);
  assert.equal(f.calls.filter(c => c[0] === 'pack').length, 3); assert.equal(checks(f).length, 0);
  assert(f.objects.every(o => o.released)); assert.equal((await slots(f)).length, 0);
});

for (const options of [{ sourceError: true }, { size: { width: 999999, height: 999999 } },
  { decodedSize: { width: 433, height: 433 } }, { zeroWrite: true }]) {
  test('invalid codec/size/no-progress write cleans up without a prompt: ' + JSON.stringify(options), async t => {
    const f = await shortcutFixture(t, options);
    assert.deepEqual(await f.call().done, failed); assert.equal(checks(f).length, 0);
    assert(f.objects.every(o => o.released)); assert.equal(f.fds.size, 0); assert.equal((await slots(f)).length, 0);
  });
}

test('pre-submission background invalidates late check even after returning foreground', async t => {
  const checked = deferred(); const f = await shortcutFixture(t, { check: () => checked.promise });
  const call = f.call(); await until(() => checks(f).length === 1);
  f.background(); assert.deepEqual(await call.done, failed); f.foreground();
  checked.resolve(); await until(() => f.calls.some(c => c[0] === 'rmdir'));
  assert.equal(requests(f).length, 0); assert.equal(call.replies.length, 1); assert.equal(f.events.length, 0);
});

test('background caused by the submitted system dialog does not fake cancellation', async t => {
  const confirmed = deferred(); const f = await shortcutFixture(t, { request: () => confirmed.promise });
  const call = f.call(); await until(() => requests(f).length === 1); f.background();
  assert.equal(call.replies.length, 0); confirmed.resolve(); assert.deepEqual(await call.done, success);
  assert.equal(f.events.length, 1);
});

test('detach settles the old reply once; pending physical request blocks replacement and late event cannot reach it', async t => {
  const confirmed = deferred(); const f = await shortcutFixture(t, { request: () => confirmed.promise });
  const old = f.call(); await until(() => requests(f).length === 1); f.detach();
  assert.deepEqual(await old.done, failed);
  const next = f.attach(); assert.deepEqual(await f.call('pin', { png: png() }, next).done, failed);
  assert.equal(requests(f).length, 1); confirmed.resolve(); await settle();
  assert.equal(old.replies.length, 1); assert.equal(f.events.length, 0);
  f.change({ request: undefined });
  assert.deepEqual(await f.call('pin', { png: png() }, next).done, success);
  assert.equal(requests(f).length, 2); assert.equal(f.events.length, 1); assert.equal(f.events[0].channel, next.methods);
  assert.equal((await slots(f)).length, 2);
});

test('concurrent clicks are refused instead of queued for a later unsolicited dialog', async t => {
  const confirmed = deferred(); const f = await shortcutFixture(t, { request: () => confirmed.promise });
  const first = f.call(); await until(() => requests(f).length === 1);
  assert.deepEqual(await f.call().done, failed); confirmed.resolve(); assert.deepEqual(await first.done, success);
  await settle(); assert.equal(requests(f).length, 1);
});

test('codec release failure preserves one owner and retries it before another prompt', async t => {
  const f = await shortcutFixture(t, { pixelsRelease() { throw Error('temporary release failure'); } });
  assert.deepEqual(await f.call().done, failed); const count = f.objects.length;
  assert.deepEqual(await f.call().done, failed); assert.equal(f.objects.length, count); assert.equal(requests(f).length, 0);
  f.change({ pixelsRelease: undefined }); assert.deepEqual(await f.call().done, success);
  assert(f.objects.every(o => o.released)); assert.equal((await slots(f)).length, 1);
});

test('FD close failure keeps its actual FD until a successful explicit retry', async t => {
  const f = await shortcutFixture(t, { close() { throw Error('temporary close failure'); } });
  assert.deepEqual(await f.call().done, failed); assert.equal(f.fds.size, 1);
  assert.deepEqual(await f.call().done, failed); assert.equal(f.fds.size, 1); assert.equal(requests(f).length, 0);
  f.change({ close: undefined }); assert.deepEqual(await f.call().done, success);
  assert.equal(f.fds.size, 0); assert.equal((await slots(f)).length, 1);
});

test('cleanup consults the real installed IDs and preserves recent/foreign/symlink entries', async t => {
  const f = await shortcutFixture(t);
  const old = await makeSlot(f, 2 * 86400000), installed = await makeSlot(f, 2 * 86400000),
    recent = await makeSlot(f, 0), foreign = await makeSlot(f, 2 * 86400000, 'foreign.txt');
  const linkName = String(Date.now() - 2 * 86400000) + '-' + randomUUID().replaceAll('-', '');
  await fs.symlink(f.context.cacheDir, iconRoot(f) + '/' + linkName);
  f.change({ pinned: [{ shortcutId: installed.id }] });
  assert.deepEqual(await f.call().done, success);
  const names = await slots(f);
  assert(!names.includes(old.name));
  for (const name of [installed.name, recent.name, foreign.name, linkName]) assert(names.includes(name));
  assert.equal(await fs.readFile(foreign.path + '/foreign.txt', 'utf8'), 'preserved icon');
  assert.equal((await fs.lstat(iconRoot(f) + '/' + linkName)).isSymbolicLink(), true);
});

test('list failure cannot erase retained files; fixed 16-slot budget recovers after a proven removal', async t => {
  const f = await shortcutFixture(t, { list() { throw Error('list service failed'); } });
  for (let i = 0; i < 16; i++) await makeSlot(f, 2 * 86400000);
  assert.deepEqual(await f.call().done, failed); assert.equal((await slots(f)).length, 16);
  assert.equal(requests(f).length, 0); assert.equal(f.objects.length, 0);
  f.change({ list: undefined, pinned: [] }); assert.deepEqual(await f.call().done, success);
  assert.equal((await slots(f)).length, 1);
});

test('a symbolic-link storage root is not followed or changed', async t => {
  const f = await shortcutFixture(t);
  await fs.symlink(f.context.cacheDir, iconRoot(f));
  assert.deepEqual(await f.call().done, failed); assert.equal(requests(f).length, 0);
  assert.deepEqual(await fs.readdir(f.context.cacheDir), []);
});

test('API 14 can add but does not call the API 24 listing method', async t => {
  const f = await shortcutFixture(t, { sdk: 14 });
  assert.deepEqual(await f.call().done, success);
  assert.equal(f.calls.filter(c => c[0] === 'list').length, 0);
});

test('a partially malformed shortcut list provides no deletion authority', async t => {
  const f = await shortcutFixture(t);
  const first = await makeSlot(f, 2 * 86400000), second = await makeSlot(f, 2 * 86400000);
  f.change({ pinned: [{ shortcutId: first.id }, {}] });
  assert.deepEqual(await f.call().done, success);
  const names = await slots(f); assert(names.includes(first.name)); assert(names.includes(second.name));
});

test('Ability detach during decode retires the late PixelMap and cannot display a dialog', async t => {
  const decoded = deferred(); const f = await shortcutFixture(t, { decode: () => decoded.promise });
  const call = f.call(); await until(() => f.calls.some(c => c[0] === 'pixels.create'));
  f.detachAbility(); assert.deepEqual(await call.done, failed); decoded.resolve();
  await until(() => f.calls.some(c => c[0] === 'rmdir')); await settle();
  assert(f.objects.every(o => o.released)); assert.equal((await slots(f)).length, 0);
  assert.equal(requests(f).length, 0); assert.equal(call.replies.length, 1); assert.equal(f.events.length, 0);
});

test('messenger failure after true system success does not repeat the request or delete its icon', async t => {
  const f = await shortcutFixture(t, { eventError: true });
  assert.deepEqual(await f.call().done, success); await settle();
  assert.equal(requests(f).length, 1); assert.equal((await slots(f)).length, 1);
});
