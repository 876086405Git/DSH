// Actual product ETS after TypeScript erasure; OS and Flutter are explicit test doubles.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { resolve } from 'node:path';
import test from 'node:test';
import vm from 'node:vm';

const prefix = process.env.OHOS_TYPESCRIPT_PREFIX;
assert(prefix, 'Set OHOS_TYPESCRIPT_PREFIX to the locked process npm-ci directory');
const ts = createRequire(resolve(prefix, 'package.json'))('typescript');
const text = readFileSync(new URL('../../../app/ohos/entry/src/main/ets/plugins/LaunchPlugin.ets', import.meta.url), 'utf8');
const compiled = ts.transpileModule(text, { compilerOptions: {
  target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS,
} });
const plain = value => value instanceof Map || Object.prototype.toString.call(value) === '[object Map]'
  ? Object.fromEntries(value) : value;
const never = () => new Promise(() => {});

function fixture({ side = 2, width = side, height = side, bytes, media, decode, dark = false, phase = 'idle', colour = 0xFFEBF1FE, wait = 40 } = {}) {
  const channels = [], asked = [], released = [], logged = [];
  class Channel {
    constructor(_messenger, name) { this.name = name; channels.push(this); }
    setMethodCallHandler(handler) { this.handler = handler; }
  }
  const pixels = bytes ?? Array.from({ length: width * height * 4 }, (_, i) => i % 251);
  const encoded = new Uint8Array([9, 8, 7, 6]);
  const map = {
    getImageInfo: async () => ({ size: { width, height } }),
    getPixelBytesNumber: () => pixels.length,
    readPixelsToBuffer: async buffer => { new Uint8Array(buffer).set(pixels); },
    release: async () => { released.push('map'); },
  };
  const source = {
    createPixelMap: decode ?? (async options => { asked.push(options); return map; }),
    release: async () => { released.push('source'); },
  };
  const imageApi = {
    PixelMapFormat: { RGBA_8888: 3 },
    createImageSource(buffer) {
      assert.deepEqual([...new Uint8Array(buffer)], [...encoded], 'only the media bytes, not the view\'s whole buffer');
      return source;
    },
  };
  // A view into a larger buffer, as a resource read may hand back.
  const backing = new Uint8Array(32); backing.set(encoded, 8);
  const resourceManager = {
    getMediaByName: media ?? (async name => { asked.push(name); return backing.subarray(8, 12); }),
    getColorByNameSync: name => { asked.push(name); return colour; },
    getConfigurationSync: () => ({ colorMode: dark ? 0 : 1 }),
  };
  const module = { exports: {} };
  vm.runInNewContext(compiled.outputText, {
    module, exports: module.exports, setTimeout, Uint8Array, ArrayBuffer,
    require(name) {
      if (name === '@ohos/flutter_ohos') return { MethodChannel: Channel };
      if (name === '@ohos.multimedia.image') return { default: imageApi };
      if (name === '@ohos.resourceManager') return { default: { ColorMode: { DARK: 0, LIGHT: 1 } } };
      if (name === '@ohos.deviceInfo') return { default: { sdkApiVersion: 26 } };
      if (name === '@ohos.hilog') return { default: { info: (...line) => logged.push(line) } };
      if (name === '../runtime/NativeHost') return { nativeHostState: () => ({ phase }) };
      throw new Error(`Unexpected runtime import ${name}`);
    },
  });
  const engine = { getBinaryMessenger: () => ({}), getApplicationContext: () => ({ resourceManager }) };
  const plugin = new module.exports.default(wait);
  plugin.onAttachedToEngine(engine);
  function call(method, args = {}) {
    return new Promise(resolve => channels.at(-1).handler.onMethodCall({ method, argument: name => args[name] }, {
      success: value => resolve({ value: plain(value) }),
      error: (code, message) => resolve({ error: code, message }),
      notImplemented: () => resolve({ missing: true }),
    }));
  }
  return { plugin, engine, channels, asked, released, pixels, call };
}

test('the exact channel name, and methods it does not have stay missing', async () => {
  const f = fixture();
  assert.deepEqual(f.channels.map(c => c.name), ['dsh/launch']);
  assert.deepEqual(await f.call('unknown'), { missing: true });
});

test('begin says what the start window shows, in the shape LaunchSnapshot.fromMap reads', async () => {
  const f = fixture({ side: 3 });
  const { value } = await f.call('begin');
  const { icon, ...rest } = value;
  assert.deepEqual(rest, {
    active: true, sdk: 26, systemSplash: false, systemIcon: true, iconPx: 3,
    background: 0xFFEBF1FE, backgroundBottom: 0xFFEBF1FE, dark: false, coldEngine: true,
    motionAfterReady: true,
  });
  assert.equal(Object.prototype.toString.call(icon), '[object Uint8Array]');
  assert.deepEqual([...icon], f.pixels);
  assert.deepEqual(f.asked.filter(v => typeof v === 'string').sort(), ['start_icon', 'start_window_background']);
  assert.equal(f.asked.find(v => typeof v === 'object').desiredPixelFormat, 3);
});

test('the decoder and pixels are given back', async () => {
  const f = fixture();
  await f.call('begin');
  assert.deepEqual(f.released, ['map', 'source']);
  const failing = fixture({ decode: () => Promise.reject(new Error('corrupt')) });
  await failing.call('begin');
  assert.deepEqual(failing.released, ['source']);
});

test('dark mode comes from the same configuration the start window follows', async () => {
  assert.equal((await fixture({ dark: true }).call('begin')).value.dark, true);
});

test('a colour without alpha is opaque all the same: it is a page, not a tint', async () => {
  assert.equal((await fixture({ colour: 0x00EBF1FE }).call('begin')).value.background, 0xFFEBF1FE);
});

test('the engine already up is not a cold start, so the motion does not hold for it', async () => {
  assert.equal((await fixture({ phase: 'running' }).call('begin')).value.coldEngine, false);
  for (const phase of ['idle', 'starting', 'exited']) {
    assert.equal((await fixture({ phase }).call('begin')).value.coldEngine, true, phase);
  }
});

test('anything wrong with the icon means no launch screen, as before, never a stuck start', async () => {
  const cases = [
    { media: () => Promise.reject(new Error('missing')) },
    { media: () => { throw new Error('sync'); } },
    { decode: () => Promise.reject(new Error('corrupt')) },
    { width: 2, height: 3 },
    { side: 2, bytes: [1, 2, 3] },
  ];
  for (const options of cases) {
    assert.deepEqual(await fixture(options).call('begin'), { value: { active: false } });
  }
});

test('an icon that never comes does not hold up main(): begin answers within its wait', async () => {
  for (const options of [{ media: never }, { decode: never }]) {
    assert.deepEqual(await fixture({ ...options, wait: 20 }).call('begin'), { value: { active: false } });
  }
});

test('snapshot answers as begin does', async () => {
  const f = fixture();
  assert.deepEqual(await f.call('snapshot'), await f.call('begin'));
});

test('the system fades its own start window: reveal has nothing to take away; mark and done just answer', async () => {
  const f = fixture();
  assert.deepEqual(await f.call('reveal'), { value: false });
  assert.deepEqual(await f.call('mark', { name: 'firstFrame' }), { value: null });
  assert.deepEqual(await f.call('done'), { value: null });
});

test('detaching clears the handler', () => {
  const f = fixture();
  f.plugin.onDetachedFromEngine(f.engine);
  assert.equal(f.channels[0].handler, null);
});
