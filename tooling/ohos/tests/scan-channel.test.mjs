// dsh/app.scanQrCode: the actual AppLinksPlugin.ets and HmsKits.ets after TypeScript
// erasure. Scan Kit, canIUse and Flutter's channel are doubles: this pins the
// options, the cancel code and the error codes, not the system scan page or HMS.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { resolve } from 'node:path';
import test from 'node:test';
import vm from 'node:vm';

const prefix = process.env.OHOS_TYPESCRIPT_PREFIX;
assert(prefix, 'Set OHOS_TYPESCRIPT_PREFIX to the locked process npm-ci directory');
const ts = createRequire(resolve(prefix, 'package.json'))('typescript');
const plugins = new URL('../../../app/ohos/entry/src/main/ets/plugins/', import.meta.url);
const compile = name => ts.transpileModule(readFileSync(new URL(name + '.ets', plugins), 'utf8'), {
  compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS },
}).outputText;
const appLinks = compile('AppLinksPlugin');
const hmsKits = compile('HmsKits');
const CANCELED = 1000500002;

function fixture({ syscap = true, kit = 'present', start = () => Promise.resolve({ originalValue: 'code' }), foreground = true } = {}) {
  const channels = [], scans = [], capabilities = [];
  class Channel {
    constructor(_messenger, name) { this.name = name; channels.push(this); }
    setMethodCallHandler(handler) { this.handler = handler; }
    invokeMethod() {}
  }
  const scanKit = {
    scanBarcode: { startScanForResult: (context, options) => { scans.push({ context, options }); return start(); } },
    scanCore: { ScanType: { QR_CODE: 11 } },
  };
  const kits = { exports: {} };
  vm.runInNewContext(hmsKits, { module: kits, exports: kits.exports, Promise, require(name) {
    // Only the scan module may load: the other Kits stay untouched by a scan.
    if (name !== './HmsScanKit') throw new Error(`Unexpected Kit import ${name}`);
    if (kit === 'missing') throw new Error('Cannot find module @hms:core.scan.scanBarcode');
    return kit === 'empty' ? {} : scanKit;
  } });
  const module = { exports: {} };
  vm.runInNewContext(appLinks, {
    module, exports: module.exports, Promise,
    canIUse: capability => { capabilities.push(capability); return syscap; },
    require(name) {
      if (name === '@ohos/flutter_ohos') return { MethodChannel: Channel };
      if (name === './OhosFrameRate') return { OhosFrameRateKeeper: class { close() {} setVisible() {} } };
      if (name === './HmsKits') return kits.exports;
      return { default: {} };
    },
  });
  const Plugin = module.exports.default;
  const plugin = new Plugin();
  plugin.onAttachedToEngine({ getBinaryMessenger: () => ({}) });
  const ability = { launchWant: {}, context: { name: 'ui-ability-context' } };
  plugin.onAttachedToAbility({ getAbility: () => ability, addOnNewWantListener() {}, removeOnNewWantListener() {} });
  if (foreground) Plugin.onForeground(ability);
  const call = () => new Promise(done => channels.filter(c => c.name === 'dsh/app').at(-1).handler.onMethodCall(
    { method: 'scanQrCode', argument: () => undefined },
    { success: value => done({ value }), error: (code, message) => done({ error: code, message }), notImplemented: () => done({ missing: true }) },
  ));
  return { call, scans, capabilities, Plugin, plugin, ability };
}

test('a scan opens the QR-only system page with its album on the foreground ability and returns the text', async () => {
  const f = fixture({ start: () => Promise.resolve({ scanType: 11, originalValue: 'https://dsh.r2049.cn/pair#v1.abc' }) });
  assert.deepEqual(await f.call(), { value: 'https://dsh.r2049.cn/pair#v1.abc' });
  assert.equal(f.scans.length, 1);
  assert.equal(f.scans[0].context, f.ability.context);
  assert.deepEqual({ ...f.scans[0].options, scanTypes: [...f.scans[0].options.scanTypes] },
    { scanTypes: [11], enableMultiMode: false, enableAlbum: true });
  assert.deepEqual(f.capabilities, ['SystemCapability.Multimedia.Scan.ScanBarcode']);
});

test('closing the scan page answers null, not an error', async () => {
  const f = fixture({ start: () => Promise.reject({ code: CANCELED, message: 'The user canceled the barcode scanning.' }) });
  assert.deepEqual(await f.call(), { value: null });
});

test('Scan Kit errors, a thrown parameter error and an empty result are failed; the next scan still runs', async () => {
  let attempt = 0;
  const f = fixture({ start: () => [
    () => Promise.reject({ code: 1000500001, message: 'Internal error.' }),
    () => { const error = new Error('Parameter error.'); error.code = 401; throw error; },
    () => Promise.resolve({ originalValue: '' }),
    () => Promise.reject(undefined),
    () => Promise.resolve({ originalValue: 'again' }),
  ][attempt++]() });
  for (let i = 0; i < 4; i++) assert.equal((await f.call()).error, 'failed');
  assert.deepEqual(await f.call(), { value: 'again' });
});

test('no Scan Kit is unavailable: missing capability, a module that fails to load or lacks the API', async () => {
  const none = fixture({ syscap: false });
  assert.equal((await none.call()).error, 'unavailable');
  assert.equal(none.scans.length, 0);
  assert.equal((await fixture({ kit: 'missing' }).call()).error, 'unavailable');
  assert.equal((await fixture({ kit: 'empty' }).call()).error, 'unavailable');
});

test('only a foreground, attached ability scans, and one scan at a time', async () => {
  const background = fixture({ foreground: false });
  assert.equal((await background.call()).error, 'no_ability');
  assert.equal(background.scans.length, 0);
  const detached = fixture();
  detached.plugin.onDetachedFromAbility();
  assert.equal((await detached.call()).error, 'no_ability');

  let release;
  const f = fixture({ start: () => release === undefined
    ? new Promise(done => { release = done; }) : Promise.resolve({ originalValue: 'next' }) });
  const first = f.call();
  await new Promise(done => setImmediate(done));
  assert.equal((await f.call()).error, 'busy');
  release({ originalValue: 'late' });
  assert.deepEqual(await first, { value: 'late' });
  assert.deepEqual(await f.call(), { value: 'next' });
  assert.equal(f.scans.length, 2);
});

test('a reply into a retired engine does not escape or keep the scan busy', async () => {
  const f = fixture();
  const thrown = await new Promise(done => f.plugin.onMethodCall({ method: 'scanQrCode', argument: () => undefined }, {
    success() { done('success'); throw new Error('engine gone'); },
    error() { done('error'); throw new Error('engine gone'); },
  }));
  assert.equal(thrown, 'success');
  await new Promise(done => setImmediate(done));
  assert.deepEqual(await f.call(), { value: 'code' });
});
