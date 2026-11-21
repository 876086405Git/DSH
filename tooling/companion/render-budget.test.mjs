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

test('without a budget the model draws at the screen density up to 3x, its marks at 2x', async () => {
  const { canvases, options } = await canvasAllocation('');
  assert.equal(canvases.stage.width, 1170);
  assert.equal(canvases.stage.height, 2532);
  assert.equal(canvases.fx.width, 780);
  assert.equal(canvases.fx.height, 1688);
  assert.equal(options[0].antialias, false);
  const dense = await canvasAllocation('', 4);
  assert.equal(dense.canvases.stage.width, 1170);
  const lowDensity = await canvasAllocation('', 1);
  assert.equal(lowDensity.options[0].antialias, true);
});

test('she starts at the resolution her last visit settled on, never below half', async () => {
  for (const [given, width] of [['0.7', 819], ['0.1', 585], ['2', 1170], ['nope', 1170]]) {
    const { canvases } = await canvasAllocation(`?quality=${given}`);
    assert.equal(canvases.stage.width, width, `quality=${given}`);
    // Her marks keep their own density.
    assert.equal(canvases.fx.width, 780);
  }
});

test('a low GPU budget takes the blur and blend layers away before the first paint', () => {
  const css = readFileSync(new URL('../../app/assets/companion/stage.css', import.meta.url), 'utf8');
  const low = [...css.matchAll(/html\[data-gpu-budget='low'\][^{]*\{[^}]*\}/g)].map((m) => m[0]).join('\n');
  assert.match(low, /\.shafts\s*\{\s*mix-blend-mode:\s*normal;/);
  for (const part of ['.shafts i', '.whale', '.reef']) assert.ok(low.includes(part), part);
  assert.equal((low.match(/filter:\s*none/g) ?? []).length, 2);
});

test('nothing in the room animates on a clock of its own', () => {
  // A CSS animation keeps the page compositing at the screen's full rate, and
  // Flutter re-blurring its glass over it, while she idles at 30 (stage.js `water`).
  const css = readFileSync(new URL('../../app/assets/companion/stage.css', import.meta.url), 'utf8');
  assert.doesNotMatch(css, /@keyframes|\banimation\s*:/);
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
