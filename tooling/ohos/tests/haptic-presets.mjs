// What the HAR's own PlatformPlugin asks the motor for. The vibrator is the boundary.
//
//   OHOS_TYPESCRIPT_PREFIX=<dir> node haptic-presets.mjs <extracted HAR package>
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { createRequire } from 'node:module';
import vm from 'node:vm';

const embedding = resolve(process.argv[2]);
const ts = createRequire(resolve(process.env.OHOS_TYPESCRIPT_PREFIX, 'package.json'))('typescript');
const transpile = source => ts.transpileModule(source, {
  compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS, esModuleInterop: true },
}).outputText;
const run = (code, require) => {
  const module = { exports: {} };
  vm.runInNewContext(code, { module, exports: module.exports, require, Map, Promise, Error, JSON });
  return module.exports;
};
const source = path => readFileSync(resolve(embedding, 'src/main/ets', path), 'utf8');

const channel = source('embedding/engine/systemchannels/PlatformChannel.ets');
const haptics = run(transpile(channel.match(/export enum HapticFeedbackType \{[^}]*\}/)[0])).HapticFeedbackType;
const plugin = transpile(source('plugin/PlatformPlugin.ets'));

function fixture(supported) {
  const asked = [], started = [];
  const vibrator = {
    isSupportEffect(effectId) { asked.push(effectId); return supported(effectId); },
    async startVibration(effect, attribute) { started.push({ effect, attribute }); },
  };
  const log = { w() {}, e() {}, i() {}, d() {} };
  const exports = run(plugin, name => {
    if (name === '@ohos.vibrator') return { __esModule: true, default: vibrator };
    if (name.endsWith('/Log')) return { __esModule: true, default: log };
    if (name.endsWith('/PlatformChannel')) return { __esModule: true, default: {}, HapticFeedbackType: haptics };
    // Nothing else is reached by a haptic. Fail if one is used.
    return new Proxy({}, { get(_target, key) {
      if (key === '__esModule') return true;
      throw Error('unadapted boundary ' + name + ':' + String(key));
    } });
  });
  return { callback: new exports.PlatformPluginCallback(), asked, started };
}

const touch = { id: 0, usage: 'touch' };
const table = [
  ['SELECTION_CLICK', 'haptic.clock.timer', 100, 10],
  ['LIGHT_IMPACT', 'haptic.effect.soft', 100, 15],
  ['MEDIUM_IMPACT', 'haptic.effect.hard', 60, 25],
  ['HEAVY_IMPACT', 'haptic.effect.hard', 100, 40],
  ['STANDARD', 'haptic.effect.hard', 100, 40],
];
const plain = value => JSON.parse(JSON.stringify(value));

test('every haptic of the channel has a row', () => {
  assert.deepEqual(table.map(row => row[0]).sort(), Object.keys(haptics).sort());
});

for (const [type, effectId, intensity, fallback] of table) {
  test(`${type} plays ${effectId} on the touch switch`, async () => {
    const f = fixture(async () => true);
    await f.callback.vibrateHapticFeedback(haptics[type]);
    assert.deepEqual(plain(f.started), [{ effect: { type: 'preset', effectId, intensity }, attribute: touch }]);
  });

  test(`${type} on a device without ${effectId} is ${fallback} ms`, async () => {
    const f = fixture(async () => false);
    await f.callback.vibrateHapticFeedback(haptics[type]);
    assert.deepEqual(plain(f.started), [{ effect: { type: 'time', duration: fallback }, attribute: touch }]);
  });
}

for (const [name, supported] of [
  ['rejects', async () => { throw Error('fixture query rejected'); }],
  ['throws', () => { throw Error('fixture query threw'); }],
]) {
  test(`a query that ${name} counts as no preset, and the tap still vibrates`, async () => {
    const f = fixture(supported);
    await f.callback.vibrateHapticFeedback(haptics.SELECTION_CLICK);
    assert.deepEqual(plain(f.started), [{ effect: { type: 'time', duration: 10 }, attribute: touch }]);
  });
}

test('the device is asked once per preset, a tap only waits on the first', async () => {
  const f = fixture(async () => true);
  for (const type of ['SELECTION_CLICK', 'SELECTION_CLICK', 'LIGHT_IMPACT', 'MEDIUM_IMPACT', 'HEAVY_IMPACT']) {
    await f.callback.vibrateHapticFeedback(haptics[type]);
  }
  assert.deepEqual(f.asked, ['haptic.clock.timer', 'haptic.effect.soft', 'haptic.effect.hard']);
  assert.equal(f.started.length, 5);
});

test('a refused vibration reaches the channel, which logs it', async () => {
  const f = fixture(async () => true);
  f.started.push = () => { throw Error('fixture motor refused'); };
  await assert.rejects(f.callback.vibrateHapticFeedback(haptics.LIGHT_IMPACT), /fixture motor refused/);
});
