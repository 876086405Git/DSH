// Actual ETS handlers + real Linux FS/native opener. HMS panels and grants are fixtures.
import test from 'node:test';
import assert from 'node:assert/strict';
import fsp from 'node:fs/promises';
import { join } from 'node:path';
import { shareFixture, deferred, until } from './hms-share-fixture.mjs';

const UNAVAILABLE = 'dev.fluttercommunity.plus/share/unavailable';
const settle = async f => until(() => f.panels.some(p => p.visible), 'share show');
const success = name => ({ targetAbilityInfo: { name } });
const send = (f, args) => f.call(f.outgoing, 'share', args);
const ready = async f => assert.equal((await f.call(f.incoming, 'ready').done).value, true);
const waitEvents = async (f, n) => until(() => f.delivered.length >= n, 'incoming delivery');

test('missing Share module stays local to first use and can retry without breaking ordinary launch', async t => {
  const f = await shareFixture(t, { kitFailure: true });
  const entry = f.startEntry(); entry.onCreate({}, {}); entry.onNewWant({}, {});
  assert.equal(f.kitLoads, 0); assert.equal(f.dataCalls.length, 0);
  assert.equal((await send(f, { text: 'hello' }).done).error, 'unsupported');
  assert.equal(f.kitLoads, 1); assert.equal(f.panels.length, 0); assert.equal(f.opens.length, 0);
  await ready(f); f.receive([{ utd: 'general.plain-text', content: 'incoming' }]);
  await waitEvents(f, 1); assert.equal(f.delivered[0].value.skipped[0].reason, 'unreadable');
  assert.equal(f.dataCalls.length, 0); assert.equal(f.kitLoads, 2);
  f.change({ kitFailure: false });
  const next = send(f, { text: 'retry' }); await settle(f);
  assert.equal(f.kitLoads, 3); f.panels[0].emit('dismiss'); assert.equal((await next.done).value, UNAVAILABLE);
});

test('pending Share module keeps synchronous busy admission and a detached request cannot show later', async t => {
  const gate = deferred(); const f = await shareFixture(t, { beforeKitLoad: () => gate.promise });
  const first = send(f, { text: 'first' });
  assert.equal((await send(f, { text: 'second' }).done).error, 'busy');
  await until(() => f.kitLoads === 1, 'Share module loading');
  f.plugin.onDetachedFromEngine(f.engine);
  assert.equal((await first.done).value, UNAVAILABLE);
  gate.resolve(); await new Promise(resolve => setImmediate(resolve));
  assert.equal(f.panels.length, 0); assert.equal(f.opens.length, 0); assert.equal(first.replies.length, 1);
  const next = f.attach(); const retry = f.call(next.outgoing, 'share', { text: 'new owner' });
  await settle(f); assert.equal(f.kitLoads, 1); f.panels[0].emit('dismiss'); await retry.done;
});

test('outgoing share waits for real lazy facade and detach prevents a late native open', async t => {
  const gate=deferred();let loads=0;
  const f=await shareFixture(t,{beforeNativeLoad:()=>{loads++;return gate.promise;}});
  assert.equal(loads,0);
  const path=await f.local(),request=send(f,{paths:[path],mimeTypes:['text/plain']});
  await until(()=>loads===1,'native import');
  f.plugin.onDetachedFromEngine(f.engine);gate.resolve();
  assert.equal((await request.done).value,UNAVAILABLE);
  await until(()=>f.pendingIO===0,'late IO settled');
  assert.equal(f.opens.length,0);assert.equal(f.fds.size,0);assert.equal(f.panels.length,0);
});

test('actual channel names, missing method and unsupported/no-Ability are explicit', async t => {
  const f = await shareFixture(t);
  assert.deepEqual(f.channels.map(c => c.name), ['dev.fluttercommunity.plus/share', 'dsh/share']);
  assert.deepEqual(await f.call(f.outgoing, 'oldMethod').done, { missing: true });
  f.change({ supported: false }); assert.equal((await send(f, { text: 'hello' }).done).error, 'unsupported');
  f.change({ supported: true }); f.plugin.onDetachedFromAbility();
  assert.equal((await send(f, { text: 'hello' }).done).error, 'no_ability');
  assert.equal(f.panels.length, 0); assert.equal(f.opens.length, 0);
});

test('text and HTTP URI use content, subject/title, SINGLE; numeric origin becomes pixels', async t => {
  const f = await shareFixture(t);
  const request = send(f, { uri: 'https://example.test/path?a=1', subject: '主题', title: '标题',
    originX: 10, originY: 20, originWidth: 4, originHeight: 6 });
  await settle(f);
  const panel = f.panels[0];
  assert.equal(panel.data.records[0].content, 'https://example.test/path?a=1');
  assert.equal(panel.data.records[0].utd, 'general.hyperlink');
  assert.equal(panel.data.records[0].uri, undefined);
  assert.equal(panel.data.records[0].title, '标题');
  assert.equal(panel.context, f.ui); assert.equal(panel.options.selectionMode, 0);
  assert.deepEqual(JSON.parse(JSON.stringify(panel.options.anchor)), { windowOffset: { x: 25, y: 50 }, size: { width: 10, height: 15 } });
  assert.equal(request.replies.length, 0, 'show resolved does not describe user result');
  panel.emit('dismiss'); assert.equal((await request.done).value, UNAVAILABLE);
});

test('completed first replies once but still owns physical panel until dismiss', async t => {
  const f = await shareFixture(t); const request = send(f, { text: '分享' }); await settle(f);
  const panel = f.panels[0]; const completed = [...panel.listeners.get('shareCompleted')][0];
  panel.emit('shareCompleted', success('target#module#ability'));
  assert.equal((await request.done).value, 'target#module#ability');
  assert.equal((await send(f, { text: 'second' }).done).error, 'busy');
  assert.equal(panel.listeners.get('dismiss').size, 1);
  panel.emit('dismiss'); completed(success('late')); panel.emit('dismiss');
  assert.equal(request.replies.length, 1); assert.equal(panel.listeners.get('dismiss').size, 0);
  const next = send(f, { text: 'next' }); await until(() => f.panels.length === 2); f.panels[1].emit('dismiss');
  assert.equal((await next.done).value, UNAVAILABLE);
});

test('dismiss first never guesses cancelled and ignores later completion, no timing heuristic', async t => {
  const f = await shareFixture(t); const request = send(f, { text: '分享' }); await settle(f);
  const panel = f.panels[0], late = [...panel.listeners.get('shareCompleted')][0];
  panel.emit('dismiss'); assert.equal((await request.done).value, UNAVAILABLE);
  late(success('SystemShare_CopyToPasteboard')); assert.equal(request.replies.length, 1);
});

test('detached engine receives unavailable while real panel continues to block the new engine', async t => {
  const f = await shareFixture(t); const first = send(f, { text: 'old' }); await settle(f);
  const stale = f.outgoing.handler;
  f.plugin.onDetachedFromEngine(f.engine);
  assert.equal((await first.done).value, UNAVAILABLE);
  const next = f.attach(f.plugin, false);
  assert.equal((await f.call(next.outgoing, 'share', { text: 'no stale ability' }).done).error, 'no_ability');
  f.plugin.onAttachedToAbility(next.ability);
  assert.equal((await f.call(next.outgoing, 'share', { text: 'new' }).done).error, 'busy');
  f.plugin.onDetachedFromEngine(f.engine); // late old detach must not retire next engine
  const oldCalls = []; stale.onMethodCall({ method: 'share' }, { success: value => oldCalls.push(value) });
  assert.deepEqual(oldCalls, [UNAVAILABLE]);
  f.panels[0].emit('shareCompleted', success('late')); f.panels[0].emit('dismiss');
  assert.equal(first.replies.length, 1);
  const second = f.call(next.outgoing, 'share', { text: 'new' }); await until(() => f.panels.length === 2);
  f.panels[1].emit('dismiss'); assert.equal((await second.done).value, UNAVAILABLE);
});

test('new plugin attachment invalidates previous logical owner without releasing its physical panel', async t => {
  const f = await shareFixture(t); const first = send(f, { text: 'old' }); await settle(f);
  const next = f.attach();
  assert.equal(first.replies.length, 1, 'new engine owner must retire old callback immediately');
  assert.equal((await first.done).value, UNAVAILABLE);
  assert.equal((await f.call(next.outgoing, 'share', { text: 'new' }).done).error, 'busy');
  f.panels[0].emit('shareCompleted', success('late')); f.panels[0].emit('dismiss');
  assert.equal(first.replies.length, 1);
});

test('synchronous construction/listener/show and asynchronous show failures settle once and release', async t => {
  for (const setting of [ { throwConstruct: true }, { throwOn: 'shareCompleted' }, { throwShow: true },
    { show: () => Promise.reject(new Error('rejected')) } ]) {
    await t.test(JSON.stringify(setting), async t => {
      const f = await shareFixture(t, setting); const first = send(f, { text: 'one' });
      assert.equal((await first.done).error, 'share_failed');
      await new Promise(resolve => setImmediate(resolve));
      assert.equal(first.replies.length, 1);
      for (const panel of f.panels) assert.equal([...panel.listeners.values()].reduce((s, x) => s + x.size, 0), 0);
      f.change({ throwConstruct: false, throwOn: null, throwShow: false, show: undefined });
      const previous = f.panels.length;
      const next = send(f, { text: 'two' }); await until(() => f.panels.length > previous && f.panels.at(-1)?.visible);
      f.panels.at(-1).emit('dismiss'); assert.equal((await next.done).value, UNAVAILABLE);
    });
  }
});

test('real multi-file snapshot handles partial reads/writes, generic UTD and text in first description', async t => {
  const f = await shareFixture(t, { maxRead: 101, maxWrite: 17 });
  const bytes = Buffer.from('多字节\n'.repeat(200));
  const one = await f.local('同名.pdf', bytes), two = await f.local('子目录/同名.unknown', 'other', f.app.tempDir);
  const request = send(f, { paths: [one, two], mimeTypes: ['application/pdf', 'application/x-unknown'], text: '说明' });
  await settle(f); const panel = f.panels[0];
  assert.equal(panel.options.selectionMode, 1); assert.equal(panel.data.records.length, 2);
  assert.equal(panel.data.records[0].utd, 'com.adobe.pdf'); assert.equal(panel.data.records[1].utd, 'general.file');
  assert.equal(panel.data.records[0].description, '说明'); assert.equal(panel.data.records[1].content, undefined);
  const copies = panel.data.records.map(record => decodeURIComponent(record.uri.slice('file://io.dsh.app'.length)));
  assert.deepEqual(await fsp.readFile(copies[0]), bytes); assert.equal(await fsp.readFile(copies[1], 'utf8'), 'other');
  assert(copies.every(path => path.startsWith(f.app.filesDir + '/dsh-share-out/')));
  await fsp.writeFile(one, 'changed'); assert.deepEqual(await fsp.readFile(copies[0]), bytes);
  panel.emit('shareCompleted', success('SystemShare_SaveAsFile')); panel.emit('dismiss');
  assert.equal((await request.done).value, 'SystemShare_SaveAsFile');
  assert.deepEqual(await fsp.readFile(copies[0]), bytes, 'dismiss must not immediately erase target-readable bytes');
  assert.equal(f.fds.size, 0);
});

test('DSH_HOME, traversal, final and parent symlinks cannot become outgoing share sources', async t => {
  const f = await shareFixture(t);
  const secret = await f.local('secret', 'private', f.app.filesDir + '/runtime/rootfs/root/.dsh');
  await fsp.symlink(secret, join(f.workspace, 'link'));
  await fsp.symlink(f.app.filesDir + '/runtime/rootfs/root/.dsh', join(f.workspace, 'parent'));
  for (const path of [secret, f.workspace + '/../.dsh/secret', f.workspace + '/link', f.workspace + '/parent/secret']) {
    assert((await send(f, { paths: [path], mimeTypes: ['text/plain'] }).done).error);
    await until(() => f.fds.size === 0);
    await new Promise(resolve => setImmediate(resolve));
  }
  assert.equal(f.panels.length, 0);
});

test('different Ability cache and temp directories remain shareable with application cache and workspace', async t => {
  const f = await shareFixture(t, { separateContexts: true });
  assert.notEqual(f.ui.cacheDir, f.app.cacheDir);
  assert.notEqual(f.ui.tempDir, f.app.tempDir);
  const roots = [f.ui.cacheDir, f.ui.tempDir, f.app.cacheDir, f.app.tempDir, f.workspace];
  const paths = [];
  for (let i = 0; i < roots.length; i++) paths.push(await f.local('中文 导出/' + i + '.txt', 'payload-' + i, roots[i]));
  const request = send(f, { paths, mimeTypes: paths.map(() => 'text/plain') });
  await until(() => f.panels.some(panel => panel.visible) || request.replies.length > 0, 'share accepted or rejected');
  assert.equal(request.replies.length, 0, JSON.stringify(request.replies));
  const panel = f.panels[0];
  assert.equal(panel.data.records.length, roots.length);
  for (let i = 0; i < roots.length; i++) {
    const copy = decodeURIComponent(panel.data.records[i].uri.slice('file://io.dsh.app'.length));
    assert(copy.startsWith(f.app.filesDir + '/dsh-share-out/'));
    assert.equal(await fsp.readFile(copy, 'utf8'), 'payload-' + i);
  }
  panel.emit('dismiss');
  assert.equal((await request.done).value, UNAVAILABLE);
  assert.equal(f.fds.size, 0);
});

test('Ability cache admission still rejects sibling directories, private files, traversal and symlinks', async t => {
  const f = await shareFixture(t, { separateContexts: true });
  const privateFile = await f.local('secret', 'private', f.ui.filesDir);
  const sibling = await f.local('secret', 'private', f.ui.cacheDir + '-other');
  await fsp.symlink(privateFile, join(f.ui.cacheDir, 'link'));
  await fsp.symlink(f.ui.filesDir, join(f.ui.tempDir, 'parent'));
  for (const path of [privateFile, sibling, f.ui.cacheDir + '/../files/secret',
    join(f.ui.cacheDir, 'link'), join(f.ui.tempDir, 'parent/secret')]) {
    assert((await send(f, { paths: [path], mimeTypes: ['text/plain'] }).done).error, path);
    await until(() => f.fds.size === 0 && f.pendingIO === 0);
    await new Promise(resolve => setImmediate(resolve));
  }
  assert.equal(f.panels.length, 0);
});

test('cancellation during real IO settles immediately but retains lease until descriptors close', async t => {
  const entered = deferred(), release = deferred(); let blocked = false;
  const f = await shareFixture(t, { beforeRead: async () => { if (!blocked) { blocked = true; entered.resolve(); await release.promise; } } });
  const path = await f.local('payload.bin', Buffer.alloc(1024 * 1024, 123));
  const request = send(f, { paths: [path], mimeTypes: ['application/octet-stream'] });
  await entered.promise;
  try {
    f.plugin.onDetachedFromAbility(); assert.equal((await request.done).value, UNAVAILABLE);
    f.plugin.onAttachedToAbility(f.ability);
    assert.equal((await send(f, { text: 'too early' }).done).error, 'busy');
  } finally { release.resolve(); }
  await until(() => f.fds.size === 0 && f.pendingIO === 0); await new Promise(resolve => setImmediate(resolve));
  assert.equal(f.panels.length, 0);
  const next = send(f, { text: 'after IO' }); await settle(f); f.panels[0].emit('dismiss'); await next.done;
});

test('outgoing 300 MiB aggregate cap rejects a sparse oversized file before copy', async t => {
  const f = await shareFixture(t); const path = await f.local('large.bin', ''); await fsp.truncate(path, 300 * 1024 * 1024 + 1);
  assert.equal((await send(f, { paths: [path], mimeTypes: ['application/octet-stream'] }).done).error, 'too_large');
  assert.equal(f.writes, 0); assert.equal(f.panels.length, 0);
});

test('malformed args, huge metadata, unsafe URI/path and incomplete origin fail before IO', async t => {
  const f = await shareFixture(t);
  const values = [ {}, { text: 'x', uri: 'https://example.test/' }, { uri: 'file:///private' }, { text: '\uD800' },
    { text: '中'.repeat(70000) }, { paths: ['/x'], mimeTypes: [] }, { paths: ['file://other/x'], mimeTypes: ['text/plain'] },
    { text: 'x', originX: 2 }, { text: 'x', originX: 0, originY: 0, originWidth: NaN, originHeight: 1 } ];
  for (const args of values) assert((await send(f, args).done).error);
  assert.equal(f.opens.length, 0); assert.equal(f.panels.length, 0);
});

test('ordinary cold/warm launch never calls getSharedData; both real EntryAbility paths retain super', async t => {
  const f = await shareFixture(t); const ability = f.startEntry();
  ability.onCreate({}, {}); ability.onNewWant({}, {});
  assert.equal(f.dataCalls.length, 0); assert.deepEqual(f.history, ['superCreate', 'superNewWant']);
  ability.onNewWant({ records: [{ utd: 'general.plain-text', content: 'shared' }] }, { launchReasonMessage: 'ReasonMessage_SystemShare' });
  assert.equal(f.dataCalls.length, 0); assert.equal(f.history.at(-1), 'superNewWant');
  await until(() => f.dataCalls.length === 1, 'lazy Share Kit import');
  assert(f.history.indexOf('getSharedData') > f.history.lastIndexOf('superNewWant'));
  await ready(f); await waitEvents(f, 1); assert.equal(f.delivered[0].value.text, 'shared');
});

test('cold incoming queue preserves accepted arrival order across out-of-order reads and engine replacement', async t => {
  const first = deferred(); const f = await shareFixture(t, {
    getSharedData: want => want.slow ? first.promise : Promise.resolve({ getRecords: () => want.records }),
  });
  const one = await f.external('one.txt', 'one'), two = await f.external('two.txt', 'two');
  f.receive([], { slow: true }); f.receive([{ utd: 'general.file', uri: two.uri, title: 'two.txt' }]);
  await until(() => f.fds.size === 0 && f.opens.length >= 2);
  assert.equal(f.delivered.length, 0);
  f.plugin.onDetachedFromEngine(f.engine); const next = f.attach(f.plugin);
  assert.equal((await f.call(next.incoming, 'ready').done).value, true); assert.equal(f.delivered.length, 0);
  first.resolve({ getRecords: () => [{ utd: 'general.file', uri: one.uri, title: 'one.txt' }] });
  await waitEvents(f, 2);
  assert.deepEqual(f.delivered.map(x => x.value.files[0].name), ['one.txt', 'two.txt']);
  for (const [index, event] of f.delivered.entries()) {
    assert.equal(event.channel, next.incoming); assert.equal(await fsp.readFile(event.value.files[0].path, 'utf8'), index ? 'two' : 'one');
  }
  await f.call(next.incoming, 'ready').done; assert.equal(f.delivered.length, 2);
});

test('all accepted URIs are requested before the first copy finishes; contents are real owned files', async t => {
  const blocked = deferred(), release = deferred(); let first = true;
  const f = await shareFixture(t, { beforeRead: async () => { if (first) { first = false; blocked.resolve(); await release.promise; } } });
  const sources = await Promise.all([f.external('a', 'A'), f.external('b', 'B'), f.external('c', 'C')]);
  f.receive(sources.map((source, i) => ({ uri: source.uri, title: String(i), utd: 'general.file' })));
  await blocked.promise;
  try { assert.equal(f.opens.filter(x => x.path?.startsWith('file://')).length, 3); }
  finally { release.resolve(); }
  await ready(f); await waitEvents(f, 1);
  assert.deepEqual(await Promise.all(f.delivered[0].value.files.map(file => fsp.readFile(file.path, 'utf8'))), ['A', 'B', 'C']);
});

test('incoming exact file/count/total caps, too-many and too-large map to actual Dart strings', async t => {
  const f = await shareFixture(t); const sources = [];
  for (let i = 0; i < 10; i++) sources.push(await f.external(String(i), 'item'));
  f.receive(sources.map(source => ({ uri: source.uri, title: 'file', utd: 'general.file' })));
  await ready(f); await waitEvents(f, 1);
  assert.equal(f.delivered[0].value.files.length, 9); assert.equal(f.delivered[0].value.skipped[0].reason, 'too_many');
  const huge = await f.external('huge', ''); await fsp.truncate(huge.path, 200 * 1024 * 1024 + 1);
  f.receive([{ uri: huge.uri, utd: 'general.file' }]); await waitEvents(f, 2);
  assert.equal(f.delivered[1].value.files.length, 0); assert.equal(f.delivered[1].value.skipped[0].reason, 'too_large');
  const large = [];
  for (let i = 0; i < 3; i++) { const value = await f.external('total-' + i, ''); await fsp.truncate(value.path, i < 2 ? 200 * 1024 * 1024 : 1); large.push(value); }
  f.receive(large.map(x => ({ uri: x.uri, title: 'large', utd: 'general.file' }))); await waitEvents(f, 3);
  assert.deepEqual(f.delivered[2].value.files.map(x => x.size), [200 * 1024 * 1024, 200 * 1024 * 1024]);
  assert.equal(f.delivered[2].value.skipped[0].reason, 'too_large');
});

test('incoming policy matches Android and Dart while outgoing and count limits stay fixed', async t => {
  const f = await shareFixture(t);
  assert.equal(f.policy.SHARE_MAX_FILE, 200 * 1024 * 1024);
  assert.equal(f.policy.SHARE_MAX_TOTAL, 400 * 1024 * 1024);
  assert.equal(f.policy.SHARE_MAX_ITEMS, 9);
  assert.equal(f.policy.SHARE_OUT_MAX_BYTES, 300 * 1024 * 1024);
});

test('a real 31 MiB incoming file is copied with bounded requests and closed descriptors', async t => {
  let maxRead = 0, maxWrite = 0;
  const f = await shareFixture(t, {
    beforeRead: ({ buffer }) => { maxRead = Math.max(maxRead, buffer.byteLength); },
    beforeWrite: ({ buffer }) => { maxWrite = Math.max(maxWrite, buffer.byteLength); },
  });
  const payload = Buffer.alloc(31 * 1024 * 1024, 0x5a);
  const source = await f.external('中文 大文件.bin', payload);
  f.receive([{ uri: source.uri, title: '中文 大文件.bin', utd: 'general.file' }]);
  await ready(f); await waitEvents(f, 1);
  const event = f.delivered[0].value;
  assert.deepEqual(event.skipped, []);
  assert.equal(event.files.length, 1);
  assert.equal(event.files[0].size, payload.byteLength);
  assert.deepEqual(await fsp.readFile(event.files[0].path), payload);
  assert(maxRead > 0 && maxRead <= 256 * 1024);
  assert(maxWrite > 0 && maxWrite <= 256 * 1024);
  await until(() => f.fds.size === 0 && f.pendingIO === 0);
});

test('external authority policy refuses private/self/HTTP/traversal before open and missing grant is unreadable', async t => {
  const f = await shareFixture(t);
  const bad = ['file:///private', 'file://io.dsh.app/private', 'file://IO.DSH.APP.provider/private', 'http://other/a',
    'file://other/../private', 'file://other/%2e%2e/private', 'file://other/a%00b', 'file://other/%ZZ'];
  f.receive(bad.map(uri => ({ uri, utd: 'general.file' }))); await ready(f); await waitEvents(f, 1);
  assert.equal(f.opens.length, 0); assert.equal(f.delivered[0].value.files.length, 0);
  assert(f.delivered[0].value.skipped.every(x => x.reason === 'unreadable'));
  f.receive([{ uri: 'file://external/no-grant', utd: 'general.file' }]); await waitEvents(f, 2);
  assert.equal(f.delivered[1].value.skipped[0].reason, 'unreadable');
});

test('URI-derived filename is preserved when title is absent, including .dshgo routing extension', async t => {
  const f = await shareFixture(t); const source = await f.external('中文 配置.dshgo', '{}');
  f.receive([{ uri: source.uri, utd: 'general.file' }]); await ready(f); await waitEvents(f, 1);
  assert.equal(f.delivered[0].value.files[0].name, '中文 配置.dshgo');
});

test('text is bounded without splitting a surrogate and names cannot escape staging directory', async t => {
  const f = await shareFixture(t); const source = await f.external('file', 'data');
  f.receive([{ content: 'x'.repeat(199999) + '🙂', title: 'subject', utd: 'general.plain-text' },
    { uri: source.uri, title: '../../' + '汉'.repeat(200) + '.dshgo', utd: 'general.file' }]);
  await ready(f); await waitEvents(f, 1); const event = f.delivered[0].value;
  assert.equal(event.text.length, 199999); assert(event.files[0].name.endsWith('.dshgo'));
  assert(Buffer.byteLength(event.files[0].name) <= 240); assert(!event.files[0].name.includes('/'));
  assert(event.files[0].path.startsWith(f.app.cacheDir + '/dsh-share-in/'));
});

test('failed getSharedData remains a readable error event and never terminates main Ability', async t => {
  const f = await shareFixture(t, { getSharedData: () => Promise.reject(new Error('1003703001')) });
  f.receive([]); await ready(f); await waitEvents(f, 1);
  assert.equal(f.delivered[0].value.skipped[0].reason, 'unreadable');
  assert.equal(f.panels.length, 0); assert.equal(f.opens.length, 0);
});

test('short read/write errors are bounded and close actual descriptors', async t => {
  const f = await shareFixture(t, { zeroRead: true }); const source = await f.external('data', 'payload');
  f.receive([{ uri: source.uri, utd: 'general.file' }]); await ready(f); await waitEvents(f, 1);
  assert.equal(f.delivered[0].value.files.length, 0); assert.equal(f.delivered[0].value.skipped[0].reason, 'unreadable');
  await until(() => f.fds.size === 0);
  f.change({ zeroRead: false, zeroWrite: true });
  f.receive([{ uri: source.uri, utd: 'general.file' }]); await waitEvents(f, 2);
  assert.equal(f.delivered[1].value.files.length, 0); await until(() => f.fds.size === 0);
});

test('copying, queue and overflow remain bounded before Dart readiness', async t => {
  const gates = []; const f = await shareFixture(t, { getSharedData: () => { const gate = deferred(); gates.push(gate); return gate.promise; } });
  for (let i = 0; i < 1000; i++) f.receive([]);
  await until(() => f.dataCalls.length === 4, 'four admitted reads after lazy load');
  assert.equal(f.dataCalls.length, 4, 'only four platform reads may be in flight');
  assert.equal(f.kitLoads, 1, 'concurrent admitted reads share one Kit load');
  for (const gate of gates) gate.resolve({ getRecords: () => [{ utd: 'general.plain-text', content: 'queued' }] });
  await ready(f); await waitEvents(f, 9);
  assert.equal(f.delivered.length, 9, 'eight accepted slots plus one coalesced overflow indication');
  assert(f.delivered.slice(4).every(x => x.value.skipped[0].reason === 'too_many'));
});

test('ready acknowledgement precedes flushing cached share calls, matching existing native inbox contract', async t => {
  const f = await shareFixture(t); f.receive([{ utd: 'general.plain-text', content: 'queued' }]);
  await new Promise(resolve => setImmediate(resolve)); await ready(f); await waitEvents(f, 1);
  assert(f.history.indexOf('reply:ready') < f.history.indexOf('invoke:share'));
});

test('retired result transport cannot throw out of dismiss or leave its physical lease stuck', async t => {
  const f = await shareFixture(t); const first = send(f, { text: 'payload' }); await settle(f);
  f.change({ throwReply: true });
  assert.doesNotThrow(() => f.panels[0].emit('dismiss'));
  assert.equal(first.replies.length, 1); f.change({ throwReply: false });
  const next = send(f, { text: 'next' }); await until(() => f.panels.length === 2);
  f.panels[1].emit('dismiss'); assert.equal((await next.done).value, UNAVAILABLE);
});

test('delivered staging survives result events and old completed batches are bounded on later shares', async t => {
  const f = await shareFixture(t); const file = await f.local('file.txt', 'immutable'); const copies = [];
  for (let i = 0; i < 7; i++) {
    const call = send(f, { paths: [file], mimeTypes: ['text/plain'] });
    await until(() => f.panels.length === i + 1 && f.panels[i].visible);
    const panel = f.panels[i], copy = decodeURIComponent(panel.data.records[0].uri.slice('file://io.dsh.app'.length));
    copies.push(copy); panel.emit('shareCompleted', success('SystemShare_SaveAsFile')); panel.emit('dismiss'); await call.done;
    assert.equal(await fsp.readFile(copy, 'utf8'), 'immutable');
    await fsp.utimes(join(copy, '..'), i + 1, i + 1); // deterministic old-slot order, no sleep
  }
  assert.equal((await fsp.readdir(f.app.filesDir + '/dsh-share-out')).length, 5);
  await assert.rejects(fsp.stat(copies[0]), { code: 'ENOENT' });
  assert.equal(await fsp.readFile(copies.at(-1), 'utf8'), 'immutable');
});

test('pending cold share batches remain protected when more than four arrive before ready', async t => {
  const f = await shareFixture(t);
  for (let i = 0; i < 8; i++) {
    const source = await f.external(String(i), String(i));
    f.receive([{ uri: source.uri, title: String(i), utd: 'general.file' }]);
    await until(() => f.writes >= i + 1 && f.fds.size === 0 && f.pendingIO === 0);
  }
  assert.equal(f.delivered.length, 0); assert.equal((await fsp.readdir(f.app.cacheDir + '/dsh-share-in')).length, 8);
  await ready(f); await waitEvents(f, 8);
  assert.deepEqual(await Promise.all(f.delivered.map(x => fsp.readFile(x.value.files[0].path, 'utf8'))), ['0', '1', '2', '3', '4', '5', '6', '7']);
});

test('output allocation failure closes all immediately acquired external descriptors', async t => {
  const f = await shareFixture(t, { mkdtempFail: true });
  const one = await f.external('one', '1'), two = await f.external('two', '2');
  f.receive([{ uri: one.uri, utd: 'general.file' }, { uri: two.uri, utd: 'general.file' }]); await ready(f); await waitEvents(f, 1);
  assert.equal(f.opens.filter(x => x.path?.startsWith('file://')).length, 2);
  assert.equal(f.delivered[0].value.files.length, 0); await until(() => f.fds.size === 0 && f.pendingIO === 0);
});

test('an actual source size change is rejected and does not publish a partially copied file', async t => {
  let source, changed = false;
  const f = await shareFixture(t, { beforeRead: async () => { if (!changed) { changed = true; await fsp.appendFile(source.path, 'growth'); } } });
  source = await f.external('mutating', 'old');
  f.receive([{ uri: source.uri, utd: 'general.file' }]); await ready(f); await waitEvents(f, 1);
  assert.equal(f.delivered[0].value.files.length, 0); assert.equal(f.delivered[0].value.skipped[0].reason, 'unreadable');
  await until(() => f.fds.size === 0 && f.pendingIO === 0);
});

test('real FIFO is rejected as non-regular without blocking for a writer', async t => {
  assert(process.env.OHOS_SHARE_FIFO, 'Create a FIFO with mkfifo in the evidence directory and set OHOS_SHARE_FIFO');
  const f = await shareFixture(t); const uri = f.externalTarget('pipe', process.env.OHOS_SHARE_FIFO);
  assert((await fsp.lstat(process.env.OHOS_SHARE_FIFO)).isFIFO());
  f.receive([{ uri, utd: 'general.file' }]); await ready(f); await waitEvents(f, 1);
  assert.equal(f.delivered[0].value.files.length, 0); assert.equal(f.reads, 0);
  assert.equal(f.delivered[0].value.skipped[0].reason, 'unreadable');
  await until(() => f.fds.size === 0 && f.pendingIO === 0);
});

const consume = (f, event, channel = f.incoming) => f.call(channel, 'consumed', { shareId: event.shareId });
async function incomingFile(f, index) {
  const source = await f.external('consumed-' + index + '.txt', 'bytes-' + index);
  const before = f.delivered.length;
  f.receive([{ uri: source.uri, title: 'file-' + index, utd: 'general.file' }]);
  await waitEvents(f, before + 1);
  return f.delivered.at(-1).value;
}

test('delivered unconsumed files retain all eight slots; ninth is rejected until consumed', async t => {
  const f = await shareFixture(t); await ready(f); const events = [];
  for (let i = 0; i < 8; i++) events.push(await incomingFile(f, i));
  assert.equal(new Set(events.map(x => x.shareId)).size, 8);
  for (const event of events) assert.match(event.shareId, /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i);
  assert.deepEqual(await Promise.all(events.map(x => fsp.readFile(x.files[0].path, 'utf8'))),
    Array.from({ length: 8 }, (_, i) => 'bytes-' + i));
  const calls = f.dataCalls.length;
  const overflow = await incomingFile(f, 8);
  assert.equal(overflow.skipped[0].reason, 'too_many'); assert.equal(overflow.files.length, 0);
  assert.equal(overflow.shareId, undefined); assert.equal(f.dataCalls.length, calls);
  assert.equal((await consume(f, events[0]).done).value, true);
  await assert.rejects(fsp.stat(events[0].files[0].path), { code: 'ENOENT' });
  const replacement = await incomingFile(f, 9);
  assert.equal(await fsp.readFile(replacement.files[0].path, 'utf8'), 'bytes-9');
  for (const event of events.slice(1)) assert.equal((await fsp.stat(event.files[0].path)).isFile(), true);
});

test('text and unreadable events carry no file token and do not accumulate consumed capacity', async t => {
  const f = await shareFixture(t); await ready(f);
  for (let i = 0; i < 12; i++) {
    const before = f.delivered.length;
    f.receive(i % 2 ? [{ uri: 'file://external/no-grant', utd: 'general.file' }] : [{ content: 'text-' + i }]);
    await waitEvents(f, before + 1);
    assert.equal(f.delivered.at(-1).value.shareId, undefined);
    assert.equal(f.delivered.at(-1).value.files.length, 0);
  }
  const event = await incomingFile(f, 'after-text');
  assert.equal(await fsp.readFile(event.files[0].path, 'utf8'), 'bytes-after-text');
});

test('invalid unknown duplicate and old-owner consumed cannot delete another batch', async t => {
  const f = await shareFixture(t); await ready(f);
  const old = await incomingFile(f, 'old'); const oldHandler = f.incoming.handler;
  for (const shareId of [undefined, null, 12, '', 'unknown', old.files[0].path]) {
    assert.equal((await f.call(f.incoming, 'consumed', { shareId }).done).value, false);
  }
  const next = f.attach(); await f.call(next.incoming, 'ready').done;
  const fresh = await incomingFile(f, 'new');
  assert.equal((await consume(f, old, next.incoming).done).value, false);
  const late = deferred();
  oldHandler.onMethodCall({ method: 'consumed', argument: key => key === 'shareId' ? old.shareId : undefined },
    { success: late.resolve, error: late.reject, notImplemented: () => late.reject(new Error('missing consumed')) });
  assert.equal(await late.promise, false);
  assert.equal(await fsp.readFile(old.files[0].path, 'utf8'), 'bytes-old');
  f.plugin.onDetachedFromEngine(f.engine);
  await until(() => f.pendingIO === 0);
  await assert.rejects(fsp.stat(old.files[0].path), { code: 'ENOENT' });
  assert.equal(await fsp.readFile(fresh.files[0].path, 'utf8'), 'bytes-new');
  assert.equal((await consume(f, old, next.incoming).done).value, false);
  assert.equal((await consume(f, fresh, next.incoming).done).value, true);
  assert.equal((await consume(f, fresh, next.incoming).done).value, false);
});

test('cleanup in flight retains its slot and duplicate ACK or detach never runs discard twice', async t => {
  const f = await shareFixture(t); await ready(f); const events = [];
  for (let i = 0; i < 8; i++) events.push(await incomingFile(f, i));
  const entered = deferred(), release = deferred(); let unlinks = 0;
  f.change({ beforeUnlink: async path => {
    if (path === events[0].files[0].path) { unlinks++; entered.resolve(); await release.promise; }
  } });
  const first = consume(f, events[0]); await entered.promise;
  try {
    assert.equal((await consume(f, events[0]).done).value, false);
    const overflow = await incomingFile(f, 'in-flight');
    assert.equal(overflow.skipped[0].reason, 'too_many');
    f.plugin.onDetachedFromEngine(f.engine);
    assert.equal(unlinks, 1);
  } finally { release.resolve(); }
  assert.equal((await first.done).value, true);
  await until(() => f.pendingIO === 0);
  assert.equal(unlinks, 1);
  for (const event of events) await assert.rejects(fsp.stat(event.files[0].path), { code: 'ENOENT' });
});

test('engine cancellation retires delivered files but an in-flight unsubmitted share crosses engines', async t => {
  const f = await shareFixture(t); await ready(f); const delivered = await incomingFile(f, 'delivered');
  const entered = deferred(), release = deferred();
  f.change({ beforeRead: async () => { entered.resolve(); await release.promise; } });
  const source = await f.external('pending.txt', 'pending-data');
  f.receive([{ uri: source.uri, utd: 'general.file' }]); await entered.promise;
  f.plugin.onDetachedFromEngine(f.engine); const next = f.attach(f.plugin);
  await f.call(next.incoming, 'ready').done;
  release.resolve(); await waitEvents(f, 2);
  await until(() => f.pendingIO === 0);
  await assert.rejects(fsp.stat(delivered.files[0].path), { code: 'ENOENT' });
  const resumed = f.delivered[1]; assert.equal(resumed.channel, next.incoming);
  assert.equal(await fsp.readFile(resumed.value.files[0].path, 'utf8'), 'pending-data');
  assert.equal((await consume(f, resumed.value, next.incoming).done).value, true);
});

test('transport throw retains protected pending files and ready retry delivers each only once', async t => {
  const f = await shareFixture(t, { throwDelivery: true }); await ready(f);
  for (let i = 0; i < 8; i++) {
    const source = await f.external('retry-' + i, 'retry-' + i);
    f.receive([{ uri: source.uri, utd: 'general.file' }]);
    await until(() => f.writes >= i + 1 && f.fds.size === 0 && f.pendingIO === 0);
  }
  assert.equal(f.delivered.length, 0);
  assert.equal((await fsp.readdir(f.app.cacheDir + '/dsh-share-in')).length, 8);
  f.change({ throwDelivery: false }); await ready(f); await waitEvents(f, 8);
  await ready(f); assert.equal(f.delivered.length, 8);
  assert.deepEqual(await Promise.all(f.delivered.map(x => fsp.readFile(x.value.files[0].path, 'utf8'))),
    Array.from({ length: 8 }, (_, i) => 'retry-' + i));
});

test('consumed acknowledges completion despite original best-effort unlink failure, not physical deletion', async t => {
  const f = await shareFixture(t); await ready(f); const event = await incomingFile(f, 'residue');
  f.change({ beforeUnlink: async path => { if (path === event.files[0].path) throw new Error('controlled OS unlink rejection'); } });
  assert.equal((await consume(f, event).done).value, true);
  assert.equal(await fsp.readFile(event.files[0].path, 'utf8'), 'bytes-residue');
  assert.equal((await consume(f, event).done).value, false);
  f.change({ beforeUnlink: undefined });
  await fsp.utimes(join(event.files[0].path, '..'), 1, 1);
  // Four further consumed residues plus a new allocation exercise the original
  // storage prune. No new cleanup API or production deletion rule is introduced.
  for (let i = 0; i < 5; i++) {
    const other = await incomingFile(f, 'residue-' + i);
    f.change({ beforeUnlink: async path => { if (path === other.files[0].path) throw new Error('controlled residue'); } });
    assert.equal((await consume(f, other).done).value, true);
    f.change({ beforeUnlink: undefined });
  }
  await assert.rejects(fsp.stat(event.files[0].path), { code: 'ENOENT' });
});

test('Ability detach does not consume the engine-owned incoming file', async t => {
  const f = await shareFixture(t); await ready(f); const event = await incomingFile(f, 'background');
  f.plugin.onDetachedFromAbility(); await new Promise(resolve => setImmediate(resolve));
  assert.equal(await fsp.readFile(event.files[0].path, 'utf8'), 'bytes-background');
  assert.equal((await consume(f, event).done).value, true);
  await assert.rejects(fsp.stat(event.files[0].path), { code: 'ENOENT' });
});
