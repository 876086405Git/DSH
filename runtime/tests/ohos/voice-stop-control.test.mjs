// The stop control's own logic, with its ArkUI overlay replaced. This can't show that a device
// drew it; it holds the contract NativeMediaPlugin relies on.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { resolve } from 'node:path';
import vm from 'node:vm';
import test from 'node:test';
const prefix = process.env.OHOS_TYPESCRIPT_PREFIX;
assert(prefix, 'OHOS_TYPESCRIPT_PREFIX must point at the locked TypeScript prefix');
const ts = createRequire(resolve(prefix, 'package.json'))('typescript');
const source = new URL('../../../app/ohos/entry/src/main/ets/plugins/NativeVoiceStopControl.ets', import.meta.url);
const compiled = ts.transpileModule(readFileSync(source, 'utf8'), { compilerOptions: {
  target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS,
} });
function fixture(mount) {
  const mounts = [];
  const module = { exports: {} };
  vm.runInNewContext(compiled.outputText, { module, exports: module.exports, require(name) {
    if (name === './VoiceStopOverlay') return { mountVoiceStop: mount ?? (async (_context, stop, lost) => {
      const row = { stop, lost, unmounted: 0, unmount() { row.unmounted++; row.lost(); } };
      mounts.push(row);
      return () => row.unmount();
    }) };
    throw Error('unmapped ' + name);
  } });
  return { control: new module.exports.NativeVoiceStopControl('context'), mounts };
}
const key = (owner, generation = 1, lease = 'l') => ({ owner, generation, lease });

test('the control shows once mounted, and its press is the stop', async () => {
  const f = fixture();
  let stops = 0;
  await f.control.show(key('a'), () => stops++);
  assert.equal(f.mounts.length, 1);
  f.mounts[0].stop();
  assert.equal(stops, 1);
});

test('a control lost without a hide stops listening; a hide does not', async () => {
  const f = fixture();
  let stops = 0;
  await f.control.show(key('a'), () => stops++);
  f.mounts[0].lost();
  assert.equal(stops, 1, 'nothing visible, so nothing may keep listening');
  await f.control.hide(key('a'));
  assert.equal(f.mounts[0].unmounted, 1);
  assert.equal(stops, 1, 'taking it down on purpose stops nothing');
});

test('hide is idempotent, and only for this exact key', async () => {
  const f = fixture();
  await f.control.show(key('a'), () => {});
  for (const other of [key('b'), key('a', 2), key('a', 1, 'other')]) await f.control.hide(other);
  assert.equal(f.mounts[0].unmounted, 0);
  await f.control.hide(key('a'));
  await f.control.hide(key('a'));
  assert.equal(f.mounts[0].unmounted, 1);
});

test('a newer control replaces an older one, whose late hide leaves it alone', async () => {
  const f = fixture();
  let stops = 0;
  await f.control.show(key('a'), () => stops++);
  await f.control.show(key('b'), () => {});
  assert.equal(f.mounts[0].unmounted, 1);
  assert.equal(stops, 0);
  await f.control.hide(key('a'));
  assert.equal(f.mounts[1].unmounted, 0);
});

test('nothing to draw in: show fails, so listening never starts, and hide is still safe', async () => {
  const f = fixture(async () => { throw Error('no window'); });
  await assert.rejects(f.control.show(key('a'), () => {}), /no window/);
  await f.control.hide(key('a'));
});
