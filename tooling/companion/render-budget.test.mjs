import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const stage = readFileSync(new URL('../../app/assets/companion/stage.js', import.meta.url), 'utf8');
const float = readFileSync(new URL('../../app/assets/companion/float.js', import.meta.url), 'utf8');
const scene = readFileSync(new URL('../../app/assets/companion/scene.js', import.meta.url), 'utf8');

async function canvasAllocation(search, pixelRatio = 3) {
  const options = [];
  const makeCanvas = () => ({
    clientWidth: 390, clientHeight: 844, width: 0, height: 0,
    addEventListener() {},
    getContext(type, attributes) {
      if (type === '2d') return { setTransform() {} };
      options.push(attributes);
      return { getContextAttributes: () => ({ alpha: true }) };
    },
  });
  const canvases = { stage: makeCanvas(), fx: makeCanvas() };
  const context = vm.createContext({
    URL, URLSearchParams, TextEncoder, AbortController, performance, Path2D: class {},
    location: { search, href: `http://127.0.0.1:1/fixture/app/index.html${search}` },
    document: {
      hidden: false, documentElement: { dataset: {} },
      getElementById: id => canvases[id] ?? {}, querySelector: () => ({}), addEventListener() {},
    },
    window: {
      devicePixelRatio: pixelRatio, addEventListener() {},
      CubismFw: { CubismUserModel: class {}, Option: class {}, CubismFramework: { startUp() {}, initialize() {} } },
    },
    // Stop at the external model boundary, after the real context and resize
    // paths run. This fixture does not claim to render Cubism or emulate a GPU.
    fetch: async () => ({ ok: true, json: async () => ({}) }),
  });
  vm.runInContext(float, context);
  vm.runInContext(scene, context);
  vm.runInContext(stage, context);
  await new Promise(resolve => setImmediate(resolve));
  return { canvases, options };
}

test('iPhone budget reaches both canvases before model allocation and disables MSAA', async () => {
  const { canvases, options } = await canvasAllocation('?dpr=1.5&antialias=0&maxTexture=2048');
  for (const canvas of Object.values(canvases)) {
    assert.equal(canvas.width, 585);
    assert.equal(canvas.height, 1266);
  }
  assert.equal(options[0].antialias, false);
  assert.equal(options[0].preserveDrawingBuffer, false);
});

test("other platforms retain main's two-times canvas and automatic antialiasing", async () => {
  const { canvases, options } = await canvasAllocation('');
  for (const canvas of Object.values(canvases)) {
    assert.equal(canvas.width, 780);
    assert.equal(canvas.height, 1688);
  }
  assert.equal(options[0].antialias, false);
  const lowDensity = await canvasAllocation('', 1);
  assert.equal(lowDensity.options[0].antialias, true);
});


test('floating models keep native screen density while an explicit device budget still wins', async () => {
  const native = await canvasAllocation('?mode=float', 3);
  assert.equal(native.canvases.stage.width, 1170);
  assert.equal(native.canvases.stage.height, 2532);
  const capped = await canvasAllocation('?mode=float', 5);
  assert.equal(capped.canvases.stage.width, 1560);
  const budget = await canvasAllocation('?mode=float&dpr=1.5&antialias=0', 3);
  assert.equal(budget.canvases.stage.width, 585);
  assert.equal(budget.options[0].antialias, false);
});
