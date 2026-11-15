import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { widgetFixture, deferred, until, settle, running } from './companion-widget-fixture.mjs';
const fields = value => new Map(Object.entries(value));
const noon = new Date(2026, 10, 15, 12).getTime();
const childFile = fileURLToPath(new URL('./companion-widget-child.mjs', import.meta.url));
const child = (mode, root, time = noon) => {
  const result = spawnSync(process.execPath, [childFile, mode, root, String(time)], { encoding: 'utf8', timeout: 10000 });
  assert.equal(result.status, 0, result.stderr); return JSON.parse(result.stdout);
};

test('actual EntryAbility registers the companion widget data channel', async t => {
  const f = await widgetFixture(t); assert(f.methods, 'COMPANION_WIDGET_CHANNEL_MISSING');
});

test('all nine Android fields persist in application scope, null deletes and absent survives', async t => {
  const f = await widgetFixture(t, { now: noon });
  const values = { name: '鲸鱼娘', status: '吃点心', activity: 'snack', untilMs: noon + 1,
    statusAsleep: '睡着了', statusWaiting: '在小屋里等你', bond: 2.9, line: '你好', saidAt: noon };
  assert.deepEqual(await f.call(fields(values)).done, { value: null });
  assert.deepEqual(await f.snapshot(), { ...values, bond: 2 });
  assert.equal(fs.existsSync(f.context.filesDir), false, 'must use application, not module-level filesDir');
  assert.equal(f.updates[0].data.status, '吃点心'); assert.equal(f.updates[0].data.pearls, '●●●○');
  assert.deepEqual(await f.call(fields({ name: '', line: null, untilMs: null })).done, { value: null });
  const after = await f.snapshot(); assert.equal(after.name, ''); assert(!Object.hasOwn(after, 'line'));
  assert(!Object.hasOwn(after, 'untilMs')); assert.equal(after.saidAt, noon); assert.equal(after.status, '吃点心');
  assert.equal(f.updates.at(-1).data.nameDefault, false);
});

test('actual MethodCall args Map, non-Map no-op, ignored Android values and unknown method', async t => {
  const f = await widgetFixture(t);
  for (const raw of [null, 'string', {}, 2]) assert.deepEqual(await f.call(raw).done, { value: null });
  assert.equal(f.calls.length, 0);
  assert.deepEqual(await f.call(fields({ ignored: 'x', name: true, line: { x: 'y' } })).done, { value: null });
  assert.deepEqual(await f.snapshot(), {});
  assert.deepEqual(await f.call(null, 'unknown').done, { missing: true });
});

test('wrong known types, nonfinite numbers and oversized text are honest native errors', async t => {
  const f = await widgetFixture(t);
  for (const value of [{ name: 3 }, { untilMs: 'tomorrow' }, { bond: Infinity }, { saidAt: NaN }, { line: 'a'.repeat(4097) }]) {
    assert.equal((await f.call(fields(value)).done).error, 'ohos_widget_invalid');
  }
  assert.equal(f.calls.length, 0);
});

test('no installed own form persists without claiming a displayed card', async t => {
  const f = await widgetFixture(t, { forms: [] });
  assert.deepEqual(await f.call().done, { value: null });
  assert.equal((await f.snapshot()).name, '鲸鱼娘'); assert.equal(f.updates.length, 0);
});

test('only own bundle/module/ability/form updates, one failure does not skip another instance', async t => {
  const f = await widgetFixture(t, { forms: [running('one'), running('foreign', { bundleName: 'other' }),
    running('module', { moduleName: 'other' }), running('ability', { abilityName: 'other' }),
    running('form', { formName: 'other' }), running('two')],
    update: async update => { if (update.id === 'one') throw Error('removed'); } });
  assert.equal((await f.call().done).error, 'ohos_widget_update');
  assert.deepEqual(f.updates.map(u => u.id), ['one', 'two']); assert.equal(f.updates[1].completed, true);
  assert.equal((await f.snapshot()).name, '鲸鱼娘'); assert.equal(f.fds.size, 0);
});

test('system list failure is not a false successful display and the next update retries', async t => {
  const f = await widgetFixture(t, { list: async () => { throw Error('IPC'); } });
  assert.equal((await f.call().done).error, 'ohos_widget_update');
  assert.equal(f.updates.length, 0); f.change({ list: undefined });
  assert.deepEqual(await f.call(fields({ name: 'retry' })).done, { value: null });
  assert.equal(f.updates[0].data.name, 'retry');
});

test('Android exact hour boundaries, busy expiry and pose/bond defaults', async t => {
  const f = await widgetFixture(t); const { widgetView, WidgetValues } = f.data();
  const values = Object.assign(new WidgetValues(), { statusAsleep: 'sleep', statusWaiting: 'wait', bond: 2 });
  for (const [hour, expected] of [[0, 'sleeping'], [5, 'sleeping'], [6, 'happy'], [22, 'happy'], [23, 'sleeping']]) {
    assert.equal(widgetView(values, new Date(2026, 0, 1, hour)).pose, expected);
  }
  const night = new Date(2026, 0, 1, 23);
  Object.assign(values, { activity: 'play', status: 'busy', untilMs: night.getTime() + 1 });
  assert.equal(widgetView(values, night).status, 'busy'); assert.equal(widgetView(values, night).pose, 'happy');
  values.untilMs = night.getTime(); assert.equal(widgetView(values, night).status, 'sleep');
  values.untilMs++; values.activity = 'idle'; assert.equal(widgetView(values, night).status, 'sleep');
  values.activity = 'play'; values.status = undefined; assert.equal(widgetView(values, night).status, '');
  assert.equal(widgetView(values, night).statusDefault, '');
  for (const [bond, pearls] of [[-5, ''], [-1, ''], [0, '●○○○'], [1, '●●○○'], [2, '●●●○'], [3, '●●●●'], [8, '●●●●']]) {
    values.bond = bond; assert.equal(widgetView(values, night).pearls, pearls);
  }
  const initial = widgetView(new WidgetValues(), new Date(noon));
  assert.equal(initial.nameDefault, true); assert.equal(initial.statusDefault, 'waiting');
  assert.equal(initial.openUri, 'dshgo://open/companion');
});

test('Android line TTL is strictly less than 12 hours and preserves future timestamps/clock rollback', async t => {
  const f = await widgetFixture(t); const { widgetView } = f.data();
  for (const [age, line] of [[0, 'hello'], [43200000 - 1, 'hello'], [43200000, ''], [43200001, ''], [-1000, 'hello']]) {
    assert.equal(widgetView({ line: 'hello', saidAt: noon - age }, new Date(noon)).line, line);
  }
  assert.equal(widgetView({ line: 'hello' }, new Date(noon)).line, '');
});

test('local timezone is sampled on every render, including a DST boundary', async t => {
  const f = await widgetFixture(t); const { widgetView } = f.data(); const old = process.env.TZ;
  try {
    process.env.TZ = 'UTC'; const instant = new Date('2026-11-15T15:00:00Z');
    assert.equal(widgetView({}, instant).pose, 'idle');
    process.env.TZ = 'Asia/Shanghai'; assert.equal(widgetView({}, instant).pose, 'sleeping');
    process.env.TZ = 'America/New_York';
    for (const iso of ['2026-11-01T05:30:00Z', '2026-11-01T06:30:00Z']) {
      assert.equal(new Date(iso).getHours(), 1); assert.equal(widgetView({}, new Date(iso)).pose, 'sleeping');
    }
  } finally { if (old === undefined) delete process.env.TZ; else process.env.TZ = old; }
});

test('independent OS Form process reads durable source and re-evaluates TTL without UI process state', async t => {
  const f = await widgetFixture(t, { now: noon, forms: [] });
  assert.deepEqual(await f.call(fields({ name: 'disk', line: 'hello', saidAt: noon, activity: 'play',
    untilMs: noon + 1, status: 'busy', statusWaiting: 'wait' })).done, { value: null });
  const result = child('read', f.root, noon + 43200000);
  assert.equal(result.initial.data.ready, false); assert.equal(result.snapshotReads, 1);
  assert.equal(result.updates[0].data.name, 'disk'); assert.equal(result.updates[0].data.line, '');
  assert.equal(result.errors.length, 0);
});

test('extension refresh reads again after each UI write; no static snapshot cache', async t => {
  const f = await widgetFixture(t, { now: noon, forms: [] }); const form = f.form();
  assert.deepEqual(await f.call(fields({ name: 'one' })).done, { value: null });
  form.onUpdateForm('form'); await until(() => f.updates.length === 1 && f.fds.size === 0);
  assert.deepEqual(await f.call(fields({ name: 'two' })).done, { value: null });
  form.onUpdateForm('form'); await until(() => f.updates.length === 2 && f.fds.size === 0);
  assert.deepEqual(f.updates.map(u => u.data.name), ['one', 'two']);
});

test('UI pending SDK + background/detach gives other process immediate failure; physical completion enables retry', async t => {
  const gate = deferred(); const f = await widgetFixture(t, { now: noon, update: () => gate.promise });
  const first = f.call(fields({ name: 'older' })); await until(() => f.updates.length === 1);
  f.ui.onBackground(); f.detach(); assert.equal((await first.done).error, 'ohos_widget_detached');
  const blocked = child('read', f.root); assert.equal(blocked.updates.length, 0);
  assert.equal(blocked.errors.length, 1); assert.equal(blocked.snapshotReads, 0, 'no reads while another process is publishing');
  gate.resolve(); await until(() => f.fds.size === 0);
  assert.equal(first.replies.length, 1);
  const next = f.attach(); f.change({ update: undefined });
  assert.deepEqual(await f.call(fields({ name: 'newer' }), 'update', next).done, { value: null });
  const retried = child('read', f.root); assert.equal(retried.errors.length, 0);
  assert.equal(retried.updates[0].data.name, 'newer');
});

test('actual holder process death releases kernel lock and a fresh Form process reads committed state', async t => {
  const f = await widgetFixture(t, { now: noon, forms: [] });
  const holder = spawn(process.execPath, [childFile, 'hold', f.root, String(noon)], { stdio: ['ignore', 'pipe', 'pipe'] });
  let stdout = '', stderr = ''; holder.stdout.on('data', data => { stdout += data; }); holder.stderr.on('data', data => { stderr += data; });
  t.after(() => holder.kill('SIGKILL'));
  await until(() => { if (holder.exitCode !== null) assert.fail(stderr); return stdout.includes('LOCKED'); });
  const blocked = child('read', f.root); assert.equal(blocked.errors.length, 1);
  const exited = new Promise(resolve => holder.once('exit', resolve)); holder.kill('SIGKILL'); await exited;
  const retried = child('read', f.root); assert.equal(retried.errors.length, 0);
  assert.equal(retried.updates[0].data.name, 'written-by-child'); assert.equal(retried.updates[0].data.line, 'durable');
});

test('late extension completion holds lock, UI cannot overwrite until it completes and retries', async t => {
  const f = await widgetFixture(t, { now: noon, forms: [] }); await f.call(fields({ name: 'old' })).done;
  const gate = deferred(); f.change({ update: () => gate.promise }); const form = f.form(); form.onUpdateForm('form');
  await until(() => f.updates.length === 1);
  assert.equal((await f.call(fields({ name: 'new' })).done).error, 'ohos_widget_update');
  assert.equal((await f.snapshot()).name, 'old');
  gate.resolve(); await until(() => f.fds.size === 0); f.change({ update: undefined, forms: [running()] });
  assert.deepEqual(await f.call(fields({ name: 'new' })).done, { value: null });
  assert.deepEqual(f.updates.map(u => u.data.name), ['old', 'new']);
});

test('removed/stopped Form cancels queued publication without releasing another physical update', async t => {
  const f = await widgetFixture(t, { now: noon, forms: [] }); await f.call().done;
  const gate = deferred(); let reads = 0;
  f.change({ read: async () => { if (++reads === 1) await gate.promise; } });
  const form = f.form(); form.onUpdateForm('gone'); await until(() => reads === 1); form.onRemoveForm('gone');
  gate.resolve(); await until(() => f.fds.size === 0); assert.equal(f.updates.length, 0);
  form.onStop(); form.onUpdateForm('stopped'); await settle(); assert.equal(f.updates.length, 0);
});

test('short file IO is complete and atomic rename exposes whole JSON to an independent reader', async t => {
  const f = await widgetFixture(t, { now: noon, forms: [], maxWrite: 31, maxRead: 13 });
  await f.call(fields({ name: 'initial', line: 'a'.repeat(2048), saidAt: noon })).done;
  const script = 'import json,sys,time\np=sys.argv[1]; end=time.monotonic()+2; n=0\nwhile time.monotonic()<end:\n d=json.load(open(p)); assert len(d["line"])==2048; n+=1\nprint(n)';
  const reader = spawn('python3', ['-c', script, f.application.filesDir + '/companion-widget/snapshot.json']);
  let stdout = '', stderr = ''; reader.stdout.on('data', data => { stdout += data; }); reader.stderr.on('data', data => { stderr += data; });
  const ended = new Promise(resolve => reader.once('exit', resolve)); t.after(() => reader.kill());
  for (let i = 0; i < 12; i++) assert.deepEqual(await f.call(fields({ name: 'v' + i, line: String(i % 10).repeat(2048) })).done, { value: null });
  assert.equal(await ended, 0, stderr); assert(Number(stdout) > 0);
  assert.equal((await f.snapshot()).name, 'v11'); assert.equal(f.fds.size, 0);
  assert.deepEqual((await fsp.readdir(f.application.filesDir + '/companion-widget')).sort(), ['lock', 'snapshot.json']);
});

test('zero write and rename failure leave previous valid snapshot; retry replaces the bounded pending file', async t => {
  const f = await widgetFixture(t, { forms: [] }); await f.call(fields({ name: 'old' })).done;
  f.change({ zeroWrite: true }); assert.equal((await f.call(fields({ name: 'lost' })).done).error, 'ohos_widget_update');
  assert.equal((await f.snapshot()).name, 'old');
  f.change({ zeroWrite: false, rename: async () => { throw Error('rename denied'); } });
  assert.equal((await f.call(fields({ name: 'lost-again' })).done).error, 'ohos_widget_update');
  assert.equal((await f.snapshot()).name, 'old');
  f.change({ rename: undefined }); assert.deepEqual(await f.call(fields({ name: 'new' })).done, { value: null });
  assert.equal((await f.snapshot()).name, 'new'); assert.equal(f.fds.size, 0);
});

test('file fsync failure prevents rename; directory fsync failure reports failure after complete atomic file', async t => {
  const f = await widgetFixture(t, { forms: [] }); await f.call(fields({ name: 'old' })).done;
  f.change({ fsync: async fd => { if (f.fds.get(fd).endsWith('pending.json')) throw Error('disk'); } });
  assert.equal((await f.call(fields({ name: 'new' })).done).error, 'ohos_widget_update'); assert.equal((await f.snapshot()).name, 'old');
  f.change({ fsync: async fd => { if (f.fds.get(fd).endsWith('companion-widget')) throw Error('directory'); } });
  assert.equal((await f.call(fields({ name: 'committed' })).done).error, 'ohos_widget_update');
  assert.equal((await f.snapshot()).name, 'committed'); assert.equal(f.updates.length, 0);
});

test('failed physical close is retained and retried before opening another lock', async t => {
  const f = await widgetFixture(t, { forms: [] }); let failed = false;
  f.change({ close: async (_fd, path) => { if (!failed && path.endsWith('/lock')) { failed = true; throw Error('close refused'); } } });
  assert.equal((await f.call(fields({ name: 'one' })).done).error, 'ohos_widget_update'); assert.equal(f.fds.size, 1);
  const retained = [...f.fds.keys()][0], start = f.calls.length;
  assert.deepEqual(await f.call(fields({ name: 'two' })).done, { value: null });
  assert.deepEqual(f.calls[start].slice(0, 2), ['close', retained]); assert.equal(f.fds.size, 0);
});

test('invalid/oversized/shortened disk state is not silently overwritten', async t => {
  const f = await widgetFixture(t, { forms: [] }); await f.call().done;
  const path = f.application.filesDir + '/companion-widget/snapshot.json';
  for (const text of ['{broken', '[]', '{"name":false}', ' '.repeat(32769)]) {
    await fsp.writeFile(path, text); assert.equal((await f.call().done).error, 'ohos_widget_update');
    assert.equal(await fsp.readFile(path, 'utf8'), text);
  }
  await fsp.writeFile(path, '{}'); f.change({ zeroRead: true });
  assert.equal((await f.call().done).error, 'ohos_widget_update'); assert.equal(f.fds.size, 0);
});

test('NOFOLLOW rejects snapshot symlink without modifying its target', async t => {
  const f = await widgetFixture(t, { forms: [] }); await f.call().done;
  const directory = f.application.filesDir + '/companion-widget', target = f.root + '/sentinel';
  await fsp.writeFile(target, '{"name":"private"}'); await fsp.unlink(directory + '/snapshot.json');
  await fsp.symlink(target, directory + '/snapshot.json');
  assert.equal((await f.call().done).error, 'ohos_widget_update');
  assert.equal(await fsp.readFile(target, 'utf8'), '{"name":"private"}'); assert.equal(f.fds.size, 0);
});

test('stalled system publisher retains a bounded channel queue and detach settles each old reply once', async t => {
  const gate = deferred(); const f = await widgetFixture(t, { update: () => gate.promise });
  const requests = Array.from({ length: 20 }, (_, i) => f.call(fields({ name: 'item' + i })));
  await until(() => f.updates.length === 1);
  for (const request of requests.slice(16)) assert.equal((await request.done).error, 'ohos_widget_update');
  f.detach(); for (const request of requests.slice(0, 16)) assert.equal((await request.done).error, 'ohos_widget_detached');
  gate.resolve(); await until(() => f.updates.length === 16 && f.fds.size === 0);
  for (const request of requests) assert.equal(request.replies.length, 1);
  assert.equal((await f.snapshot()).name, 'item15');
});

test('later installed form recomputes local time and TTL after an earlier SDK update waits', async t => {
  const gate = deferred(); const f = await widgetFixture(t, { now: noon,
    forms: [running('first'), running('second')], update: update => update.id === 'first' ? gate.promise : undefined });
  const call = f.call(fields({ line: 'expires', saidAt: noon, statusWaiting: 'wait', statusAsleep: 'sleep' }));
  await until(() => f.updates.length === 1); assert.equal(f.updates[0].data.line, 'expires');
  f.change({ now: noon + 43200000 }); gate.resolve(); assert.deepEqual(await call.done, { value: null });
  assert.equal(f.updates[1].data.line, '', 'second form must use the later render time');
  assert.equal(f.updates[1].data.pose, 'sleeping');
});
