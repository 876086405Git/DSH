// Actual product ETS after TypeScript erasure; the window and hilog are test doubles.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { resolve } from 'node:path';
import test from 'node:test';
import vm from 'node:vm';

const prefix = process.env.OHOS_TYPESCRIPT_PREFIX;
assert(prefix, 'Set OHOS_TYPESCRIPT_PREFIX to the locked process npm-ci directory');
const ts = createRequire(resolve(prefix, 'package.json'))('typescript');
const source = ts.transpileModule(
  readFileSync(new URL('../../../app/ohos/entry/src/main/ets/plugins/OhosKeyboardLog.ets', import.meta.url), 'utf8'),
  { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS } },
).outputText;
const EVENTS = ['keyboardWillShow', 'keyboardWillHide', 'keyboardDidShow', 'keyboardDidHide', 'keyboardHeightChange', 'avoidAreaChange'];

function fixture({ refuse = [], refuseOff = false, noWindow = false } = {}) {
  const lines = [], warnings = [];
  const module = { exports: {} };
  vm.runInNewContext(source, { module, exports: module.exports, JSON, String, require(name) {
    if (name === '@ohos.hilog') return { default: {
      info: (...args) => lines.push(args), warn: (...args) => warnings.push(args),
    } };
    if (name === '@ohos.window') return { default: { AvoidAreaType: { TYPE_SYSTEM: 0, TYPE_KEYBOARD: 3 } } };
    throw new Error(`Unexpected runtime import ${name}`);
  } });
  const listeners = new Map();
  const target = {
    on(type, callback) { if (refuse.includes(type)) throw new Error('801'); listeners.set(type, callback); },
    off(type, callback) {
      if (refuseOff) throw new Error('1300002');
      assert.equal(listeners.get(type), callback, `off ${type} with the callback it was given`);
      listeners.delete(type);
    },
  };
  const stage = { getMainWindowSync() { if (noWindow) throw new Error('1300002'); return target; } };
  return { log: new module.exports.OhosKeyboardLog(), stage, listeners, lines, warnings };
}

const info = { beginRect: { left: 0, top: 2400, width: 1080, height: 0 }, endRect: { left: 0, top: 1500, width: 1080, height: 900 },
  animated: true, config: { curve: 2, duration: 250, param: [0.2, 0, 0.2, 1] } };

test('every will and did event leaves one public line with the rects, animated and config', () => {
  const f = fixture();
  f.log.setForeground(true);
  f.log.attach(f.stage);
  assert.deepEqual([...f.listeners.keys()], EVENTS);
  for (const event of EVENTS.slice(0, 4)) f.listeners.get(event)(info);
  assert.equal(f.lines.length, 4);
  for (const [i, name] of ['willShow', 'willHide', 'didShow', 'didHide'].entries()) {
    const [domain, tag, format, event, detail] = f.lines[i];
    assert.equal(domain, 0x3F00, 'hilog drops a domain above 0xFFFF');
    assert.equal(tag, 'DshKeyboard');
    assert.equal(format, '%{public}s %{public}s', 'without public hilog prints <private>');
    assert.equal(event, name);
    assert.deepEqual(JSON.parse(detail), info);
  }
});

test('height and the keyboard\'s avoid area are logged, other avoid areas are not', () => {
  const f = fixture();
  f.log.setForeground(true);
  f.log.attach(f.stage);
  f.listeners.get('keyboardHeightChange')(900);
  f.listeners.get('avoidAreaChange')({ type: 0, area: { bottomRect: { height: 1 } } });
  f.listeners.get('avoidAreaChange')({ type: 3, area: { leftRect: {left:0,top:0,width:0,height:0}, topRect: {left:0,top:0,width:0,height:0}, rightRect: {left:0,top:0,width:0,height:0}, bottomRect: {left:0,top:1500,width:1080,height:900} } });
  assert.deepEqual(f.lines.map(l => [l[3], l[4]]), [['height', '900'], ['avoidArea', '{"leftRect":{"left":0,"top":0,"width":0,"height":0},"topRect":{"left":0,"top":0,"width":0,"height":0},"rightRect":{"left":0,"top":0,"width":0,"height":0},"bottomRect":{"left":0,"top":1500,"width":1080,"height":900}}']]);
});

test('detach takes off exactly what it put on, and twice is harmless', () => {
  const f = fixture();
  f.log.setForeground(true);
  f.log.attach(f.stage);
  f.log.detach();
  assert.equal(f.listeners.size, 0);
  f.log.detach();
  assert.equal(f.warnings.length, 0);
});

test('attaching again replaces the old listeners rather than doubling them', () => {
  const f = fixture();
  f.log.setForeground(true);
  f.log.attach(f.stage);
  const first = f.listeners.get('keyboardWillShow');
  f.log.setForeground(true);
  f.log.attach(f.stage);
  assert.equal(f.listeners.size, EVENTS.length);
  assert.notEqual(f.listeners.get('keyboardWillShow'), first);
  first(info);
  assert.equal(f.lines.length, 0, 'retired callback must be inert after same-window reattach');
});

test('an event the device refuses costs a warning, not the other events', () => {
  const f = fixture({ refuse: ['keyboardWillShow'] });
  f.log.setForeground(true);
  f.log.attach(f.stage);
  assert.deepEqual([...f.listeners.keys()], EVENTS.slice(1));
  assert.deepEqual(f.warnings.map(w => w[3]), ['keyboardWillShow']);
});

test('no window and a failing off never reach the ability', () => {
  const none = fixture({ noWindow: true });
  none.log.attach(none.stage);
  none.log.detach();
  assert.deepEqual(none.warnings.map(w => w[3]), ['getMainWindow']);
  const off = fixture({ refuseOff: true });
  off.log.attach(off.stage);
  off.log.detach();
  assert.equal(off.warnings.length, EVENTS.length);
});
