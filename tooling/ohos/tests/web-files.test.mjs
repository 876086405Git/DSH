import assert from 'node:assert/strict';
import { test, beforeEach, afterEach, after } from 'node:test';
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { setImmediate as nextTurn } from 'node:timers/promises';
import { state } from './web-files-fixture.mjs';

const root = fileURLToPath(new URL('../../../', import.meta.url));
const temporary = await mkdtemp(join(tmpdir(), 'dsh-web-files-'));
const fixture = new URL('./web-files-fixture.mjs', import.meta.url).href;
const directory = join(root, 'app/ohos/entry/src/main/ets/plugins');
for (const name of ['WebFilePolicy', 'WebFilesPlugin']) {
  let source = await readFile(join(directory, name + '.ets'), 'utf8');
  source = source.replace("import uri from '@ohos.uri';", `import { uri } from '${fixture}';`)
    .replace("import picker from '@ohos.file.picker';", `import { picker } from '${fixture}';`)
    .replace("import uniformTypeDescriptor from '@ohos.data.uniformTypeDescriptor';", `import { uniformTypeDescriptor } from '${fixture}';`)
    .replace("from './WebFilePolicy';", "from './WebFilePolicy.mts';")
    .replace("from '@ohos/flutter_ohos';", `from '${fixture}';`)
    .replace('AbilityAware, AbilityPluginBinding, FlutterPlugin, FlutterPluginBinding,',
      'type AbilityAware, type AbilityPluginBinding, type FlutterPlugin, type FlutterPluginBinding,')
    .replace('MethodCall, MethodChannel, MethodResult', 'type MethodCall, MethodChannel, type MethodResult');
  await writeFile(join(temporary, name + '.mts'), source);
}
const { default: WebFilesPlugin } = await import(pathToFileURL(join(temporary, 'WebFilesPlugin.mts')));
const { WebPickRequest, webFileSelection, webFileSuffixFilters } = await import(pathToFileURL(join(temporary, 'WebFilePolicy.mts')));
after(() => rm(temporary, { recursive: true }));
beforeEach(() => state.reset());
afterEach(async () => {
  // Also release the explicit platform fixture if a failed assertion aborted
  // a test. Cleanup is not credited as successful product cancellation.
  for (const call of state.calls) if (!call.settled) call.resolve([]);
  await nextTurn(); assert.equal(state.active, 0);
});

const docs = 'file://docs/storage/Users/currentUser/Download/%E4%B8%AD%E6%96%87%20a.pdf';
const media = 'file://media/Photo/12/IMG_1/a.jpg';
const fields = (changes = {}) => new Map(Object.entries({ owner: '7:0', webViewId: 7,
  url: 'http://127.0.0.1:3080/?token=fixture-only', acceptTypes: [], multiple: false, ...changes }));
function setup(plugin = new WebFilesPlugin(), id = 'fixture') {
  const messenger = { id };
  const engine = { getBinaryMessenger() { return messenger; } };
  const context = { id: id + '-ability' };
  const ability = { getAbility() { return { context }; } };
  plugin.onAttachedToEngine(engine); plugin.onAttachedToAbility(ability);
  const channel = state.channels.findLast(row => row.messenger === messenger);
  assert.equal(channel.name, 'dsh/web-files');
  return { plugin, engine, ability, context, channel };
}
function invoke(channel, method = 'pick', args = fields()) {
  const result = Promise.withResolvers(); const calls = [];
  channel.handler.onMethodCall({ method, args, argument(key) { return args?.get(key); } }, {
    success(value) { calls.push({ success: value }); result.resolve(value); },
    error(code, message) { calls.push({ code, message }); result.reject(new Error(code)); },
    notImplemented() { calls.push({ unimplemented: true }); result.resolve('unimplemented'); },
  });
  return { promise: result.promise, calls };
}
async function choose(channel, values, changes = {}) {
  const request = invoke(channel, 'pick', fields(changes));
  state.calls.at(-1).resolve(values);
  return request.promise;
}

test('EntryAbility registers the actual web-files plugin after the Flutter engine is configured', async () => {
  const entry = await readFile(join(root, 'app/ohos/entry/src/main/ets/entryability/EntryAbility.ets'), 'utf8');
  assert.match(entry, /import WebFilesPlugin from '\.\.\/plugins\/WebFilesPlugin'/);
  assert(entry.indexOf('super.configureFlutterEngine') < entry.indexOf('add(new WebFilesPlugin())'));
});

test('actual ETS handler dispatch uses the current UIAbility and exact file-select options', async () => {
  const { channel, context, plugin } = setup();
  assert.equal(plugin.getUniqueClassName(), 'DshWebFilesPlugin');
  const pending = invoke(channel, 'pick', fields({ acceptTypes: [' .PNG,application/pdf ', 'text/plain'] }));
  assert.equal(state.calls[0].context, context);
  assert.deepEqual({ ...state.calls[0].options }, { maxSelectNumber: 1, selectMode: 0,
    fileSuffixFilters: ['.png,.pdf,.txt,.text'] });
  state.calls[0].resolve([docs]);
  assert.deepEqual(await pending.promise, [docs]);
  assert.equal(pending.calls.length, 1);
  assert.deepEqual(state.mimeCalls, ['application/pdf', 'text/plain']);
});

test('multiple selection keeps docs/media order, deduplicates and applies the public bounded maximum', async () => {
  const { channel } = setup();
  assert.deepEqual(await choose(channel, [docs, media, docs], { multiple: true }), [docs, media]);
  assert.equal(state.calls[0].options.maxSelectNumber, 500);
  assert.equal(state.calls[0].options.fileSuffixFilters, undefined);
  assert.deepEqual(await choose(channel, [docs, docs]), []);
  assert.deepEqual(await choose(channel, new Array(501).fill(docs), { multiple: true }), []);
});

test('untrusted/private/ambiguous URIs reject the whole batch, including the valid first file', async () => {
  const { channel } = setup();
  for (const value of [
    'file:///data/storage/el2/base/files/secret', 'file://com.example.app/private', '/data/storage/private',
    'content://docs/document/2', 'https://docs/a', 'file://docs.evil/a', 'file://docs@evil/a',
    'file://docs:12/a', 'file://do%63s/a', 'file://media/', 'file://docs/a%XX', 'file://docs/a\nsecret',
  ]) assert.deepEqual(await choose(channel, [docs, value], { multiple: true }), [], value);
  assert.deepEqual(webFileSelection([docs, media], true), [docs, media]);
});

test('malformed or excessive request fields never start the picker', async () => {
  const { channel } = setup();
  for (const value of [
    null, [], {}, fields({ owner: '' }), fields({ owner: 'x'.repeat(201) }), fields({ webViewId: -1 }),
    fields({ webViewId: 0.5 }), fields({ webViewId: Number.MAX_SAFE_INTEGER + 1 }), fields({ url: 'file:///private' }),
    fields({ url: 'https:relative' }), fields({ url: 'http:///missing-host' }), fields({ url: 'https://example/\n' }),
    fields({ url: 'https://example/' + 'a'.repeat(16384) }), fields({ acceptTypes: [42] }),
    fields({ acceptTypes: new Array(101).fill('.txt') }), fields({ acceptTypes: ['a'.repeat(16385)] }),
  ]) {
    const pending = invoke(channel, 'pick', value);
    const opened = state.calls.length;
    if (opened > 0) state.calls.at(-1).resolve([]);
    assert.equal(opened, 0, JSON.stringify(value instanceof Map ? Object.fromEntries(value) : value));
    assert.deepEqual(await pending.promise, []);
  }
  assert.equal(state.calls.length, 0);
});

test('accept hints preserve unions and broaden unresolved MIME/wildcard requests without hiding files', () => {
  const resolve = mime => ({ 'application/pdf': ['.pdf', '.PDF'], 'text/plain': ['.txt'] })[mime] ?? [];
  assert.deepEqual(webFileSuffixFilters(['.PDF,.tar.gz', 'application/pdf'], resolve), ['.pdf,.tar.gz']);
  for (const hints of [[], ['*/*'], ['image/*', '.pdf'], ['.pdf', 'application/unknown'], ['garbage|.exe']]) {
    assert.deepEqual(webFileSuffixFilters(hints, resolve), []);
  }
  assert.deepEqual(webFileSuffixFilters(['application/pdf'], () => { throw new Error('unavailable'); }), []);
  assert.deepEqual(webFileSuffixFilters(['application/pdf'], () => ['.pdf', 'Injected|.exe']), []);
  assert.deepEqual(webFileSuffixFilters(new Array(101).fill(0).map((_, i) => '.x' + i), resolve), []);
});

test('missing MIME service still opens a picker with no misleading narrowed filter', async () => {
  const { channel } = setup(); state.throwMime = true;
  assert.deepEqual(await choose(channel, [docs], { acceptTypes: ['application/pdf'] }), [docs]);
  assert.equal(state.calls[0].options.fileSuffixFilters, undefined);
});

test('a second callback cannot open another picker or steal the outstanding result', async () => {
  const { channel } = setup(); const first = invoke(channel);
  assert.deepEqual(await invoke(channel).promise, []);
  assert.equal(state.calls.length, 1);
  state.calls[0].resolve([docs]); assert.deepEqual(await first.promise, [docs]);
});

test('exact owner cancellation replies once and retains the physical lease until the picker settles', async () => {
  const { channel } = setup(); const first = invoke(channel);
  assert.equal(await invoke(channel, 'cancel', new Map([['owner', 'wrong']])).promise, null);
  assert.equal(first.calls.length, 0);
  assert.equal(await invoke(channel, 'cancel', new Map([['owner', '7:0']])).promise, null);
  assert.deepEqual(await first.promise, []);
  assert.deepEqual(await invoke(channel, 'pick', fields({ owner: '7:1' })).promise, []);
  assert.equal(state.calls.length, 1);
  state.calls[0].resolve([docs]); await nextTurn();
  assert.equal(first.calls.length, 1);
  assert.deepEqual(await choose(channel, [media], { owner: '7:1' }), [media]);
});

test('owner cancellation followed by picker rejection cannot double reply or poison a retry', async () => {
  const { channel } = setup(); const first = invoke(channel);
  await invoke(channel, 'cancel', new Map([['owner', '7:0']])).promise;
  state.calls[0].reject(new Error('system picker cancelled')); await nextTurn();
  assert.deepEqual(await first.promise, []); assert.equal(first.calls.length, 1);
  assert.deepEqual(await choose(channel, [docs]), [docs]);
});

test('system cancellation/rejection and both synchronous launch failures release the lease', async () => {
  const { channel } = setup();
  assert.deepEqual(await choose(channel, []), []);
  const rejected = invoke(channel); state.calls.at(-1).reject(new Error('system failure'));
  assert.deepEqual(await rejected.promise, []);
  state.throwConstructor = true; assert.deepEqual(await invoke(channel).promise, []); state.throwConstructor = false;
  state.throwSelect = true; assert.deepEqual(await invoke(channel).promise, []); state.throwSelect = false;
  assert.deepEqual(await choose(channel, [docs]), [docs]);
});

test('ability detach/replacement cancels delivery but not the outstanding physical picker', async () => {
  const { plugin, channel, ability } = setup(); const first = invoke(channel);
  plugin.onDetachedFromAbility(); assert.deepEqual(await first.promise, []);
  assert.deepEqual(await invoke(channel).promise, []);
  plugin.onAttachedToAbility(ability);
  assert.deepEqual(await invoke(channel).promise, []);
  state.calls[0].resolve([docs]); await nextTurn();
  const second = invoke(channel);
  plugin.onAttachedToAbility({ getAbility() { return { context: { id: 'replacement' } }; } });
  assert.deepEqual(await second.promise, []);
  state.calls[1].resolve([docs]); await nextTurn();
  assert.deepEqual(await choose(channel, [media]), [media]);
  assert.equal(state.calls[2].context.id, 'replacement');
});

test('new engine ownership survives old detach and queued old handler calls with the same owner text', async () => {
  const first = setup(); const oldHandler = first.channel.handler;
  const oldRequest = invoke(first.channel);
  const next = setup(first.plugin, 'next');
  assert.deepEqual(await oldRequest.promise, []);
  first.plugin.onDetachedFromEngine(first.engine);
  assert.notEqual(next.channel.handler, null);
  assert.deepEqual(await invoke(next.channel).promise, []);
  state.calls[0].resolve([docs]); await nextTurn();
  const current = invoke(next.channel);
  const stale = { handler: oldHandler };
  assert.equal(await invoke(stale, 'cancel', new Map([['owner', '7:0']])).promise, null);
  assert.deepEqual(await invoke(stale).promise, []); assert.equal(current.calls.length, 0);
  state.calls[1].resolve([media]); assert.deepEqual(await current.promise, [media]);
  assert.equal(oldRequest.calls.length, 1);
});

test('a newly attached engine cannot borrow the prior engine ability before its own ability attaches', async () => {
  const { plugin } = setup();
  const messenger = { id: 'new-engine-before-ability' };
  plugin.onAttachedToEngine({ getBinaryMessenger() { return messenger; } });
  const channel = state.channels.findLast(row => row.messenger === messenger);
  const pending = invoke(channel);
  const opened = state.calls.length;
  if (opened > 0) state.calls.at(-1).resolve([]);
  assert.deepEqual(await pending.promise, []);
  assert.equal(opened, 0, 'old UIAbility must not be used during new-engine attachment');
});

test('different plugin instances share the physical picker lease in the same Ark module', async () => {
  const first = setup(); const next = setup(new WebFilesPlugin(), 'next');
  const pending = invoke(first.channel); first.plugin.onDetachedFromEngine(first.engine);
  assert.deepEqual(await pending.promise, []);
  assert.deepEqual(await invoke(next.channel).promise, []); assert.equal(state.calls.length, 1);
  state.calls[0].resolve([docs]); await nextTurn();
  assert.deepEqual(await choose(next.channel, [media]), [media]);
});

test('unsupported methods, malformed cancel and absent ability do not launch or cancel an unrelated request', async () => {
  const { plugin, channel } = setup();
  assert.equal(await invoke(channel, 'save').promise, 'unimplemented');
  const pending = invoke(channel);
  assert.equal(await invoke(channel, 'cancel', null).promise, null);
  assert.equal(await invoke(channel, 'cancel', new Map()).promise, null);
  assert.equal(pending.calls.length, 0);
  state.calls[0].resolve([docs]); assert.deepEqual(await pending.promise, [docs]);
  plugin.onDetachedFromAbility(); assert.deepEqual(await invoke(channel).promise, []);
  assert.equal(state.calls.length, 1);
  assert.equal(WebPickRequest.parse(fields({ webViewId: 0 })).owner, '7:0');
});
