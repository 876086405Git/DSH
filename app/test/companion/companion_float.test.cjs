// node --test app/test/companion/companion_float.test.cjs
// Actual stage control flow with fake device boundaries; no GPU/model claim.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assets = path.resolve(__dirname, '../../assets/companion');
const { FrameGate, opaqueBounds, BoundsFollower, stateEffect } = require(path.join(assets, 'float.js'));
const copy = value => JSON.parse(JSON.stringify(value));

for (const hz of [60, 90, 120]) test(`30 fps ceiling at ${hz} Hz, including long stalls`, () => {
  const gate = new FrameGate(), drawn = [];
  for (let i = 0; i < hz * 10; i++) {
    const time = i * 1000 / hz + (i > hz * 5 ? 10000 : 0);
    if (gate.take(time)) drawn.push(time);
  }
  for (let i = 1; i < drawn.length; i++) assert.ok(drawn[i] - drawn[i - 1] >= 1000 / 30 - 2);
  assert.ok(drawn.length <= 301);
  assert.equal(gate.take(NaN), false);
  assert.equal(gate.take(Infinity), false);
  assert.equal(gate.take(0), false);
});

for (const hz of [60, 90, 120]) test(`jittered ${hz} Hz timestamps still reach 30 fps, not 20`, () => {
  const gate = new FrameGate();
  let drawn = 0;
  // Five seconds of vsync timestamps that wobble by up to 0.4 ms either way.
  for (let i = 0; i < hz * 5; i++) if (gate.take(i * 1000 / hz + 0.4 * Math.sin(i * 12.9898))) drawn++;
  assert.ok(drawn >= 148 && drawn <= 151, `${drawn} frames in 5 s`);
});

test('alpha bounds use drawn pixels, top-left coordinates and exclusive edges', () => {
  const rgba = new Uint8Array(5 * 4 * 4);
  assert.equal(opaqueBounds(rgba, 5, 4), null);
  rgba[(0 * 5 + 1) * 4 + 3] = 1;
  rgba[(2 * 5 + 3) * 4 + 3] = 255;
  assert.deepEqual(opaqueBounds(rgba, 5, 4), { left: 1, top: 1, right: 4, bottom: 4 });
  rgba.fill(0); rgba[(3 * 5 + 4) * 4 + 3] = 255;
  assert.deepEqual(opaqueBounds(rgba, 5, 4), { left: 4, top: 0, right: 5, bottom: 1 });
});

test('every pet state without authored mappings stays idle', () => {
  for (const state of ['idle', 'thinking', 'working', 'juggling', 'sweeping', 'carrying',
    'attention', 'notification', 'error', 'sleeping', 'waking', 'future', 'constructor']) {
    assert.deepEqual(stateEffect(state, {}, {}), { emotion: 'calm', action: null, mood: 'idle' });
  }
  assert.deepEqual(stateEffect('attention', { happy: {} }, { nod: { ms: 100, tracks: {} } }),
    { emotion: 'happy', action: 'nod', mood: 'idle' });
  assert.deepEqual(stateEffect('sleeping', { sleepy: {} }, {}),
    { emotion: 'sleepy', action: null, mood: 'sleeping' });
  assert.deepEqual(stateEffect('attention', { happy: null }, { nod: {} }),
    { emotion: 'calm', action: null, mood: 'idle' });
});

test('float scene does not allocate a 2D context or seed particles', () => {
  const window = {};
  vm.runInNewContext(fs.readFileSync(path.join(assets, 'scene.js'), 'utf8'), {
    window, document: { documentElement: { dataset: { mode: 'float' } },
      getElementById() { throw new Error('float requested a scene canvas'); } },
  });
  assert.equal(window.companionScene, null);
});

function stage(float = true, fetcher, devices = {}) {
  const canvasEvents = new Map(), documentEvents = new Map(), windowEvents = new Map();
  const posts = [], frames = new Map();
  let nextFrame = 1, releases = 0, lost = 0, reads = 0, draws = 0, reloads = 0, initialized = 0, textures = 0;
  let now = 0;
  const scene = { clear() {}, resize() {}, configure() {}, busy: () => false, step() {}, marks: new Proxy({}, { get: () => () => {} }) };
  const element = () => ({ style: {}, classList: { add() {}, remove() {} },
    getBoundingClientRect: () => ({ left: 0, top: 0, width: 5, height: 4 }) });
  const canvas = { ...element(), clientWidth: 5, clientHeight: 4, width: 5, height: 4,
    addEventListener: (name, fn) => canvasEvents.set(name, fn) };
  const document = { hidden: false, documentElement: { dataset: {} },
    getElementById: id => id === 'stage' ? canvas : element(), querySelector: element,
    addEventListener: (name, fn) => documentEvents.set(name, fn) };
  const gl = { viewport() {}, clearColor() {}, clear() {}, enable() {}, blendFunc() {}, bindFramebuffer() {},
    getContextAttributes: () => ({ alpha: true }), getParameter: () => 1024,
    createTexture() { textures++; return {}; }, bindTexture() {}, texParameteri() {}, texImage2D() {}, generateMipmap() {},
    getExtension: () => ({ loseContext() { lost++; } }),
    readPixels(x, y, w, h, format, type, target) { reads++; target.fill(0); target[(w + 1) * 4 + 3] = 255; } };
  canvas.getContext = () => gl;
  const model = { release() { releases++; if (devices.releaseError) throw new Error('synthetic release failure'); }, stopMotions() {}, startExpression() {},
    tick() {}, draw() { draws++; }, setRenderTargetSize() {}, moving: false, masks: null,
    expressions: new Map(), motions: new Map(), hitZones: [], tailIds: [],
    getRenderer: () => ({ setModelColor() {} }),
    core: { getDrawableCount: () => 0 },
  };
  const Fw = { CubismUserModel: devices.UserModel ?? class {}, CubismModelSettingJson: devices.Setting,
    CubismMatrix44: class { setMatrix() {} },
    CubismFramework: { startUp() { initialized++; }, initialize() {} }, Option: class {} };
  const window = { CubismFw: Fw, CompanionFloat: { FrameGate, opaqueBounds, BoundsFollower, stateEffect },
    companionScene: float ? null : scene, devicePixelRatio: 3,
    DshCompanion: { postMessage: value => posts.push(JSON.parse(value)) },
    addEventListener: (name, fn) => windowEvents.set(name, fn) };
  const source = fs.readFileSync(path.join(assets, 'stage.js'), 'utf8');
  // Keep all production methods; replace only the automatic entry point with
  // controllable device boundaries. The boot cancellation test calls boot.
  const entry = '\n  boot();\n})();';
  assert.equal(source.split(entry).length, 2);
  const context = vm.createContext({ window, document, URL, URLSearchParams, AbortController,
    location: { href: 'http://127.0.0.1:1234/private/app/index.html', search: float ? '?mode=float' : '',
      reload() { reloads++; } },
    performance: { now: () => now },
    requestAnimationFrame: fn => { const id = nextFrame++; frames.set(id, fn); return id; },
    cancelAnimationFrame: id => frames.delete(id),
    fetch: fetcher ?? (() => { throw new Error('unexpected fetch'); }),
    createImageBitmap: devices.createImageBitmap ?? (() => { throw new Error('unexpected bitmap'); }),
    setTimeout() { throw new Error('unexpected timer'); }, clearTimeout() {},
    setInterval() { throw new Error('unexpected interval'); },
    TextDecoder, TextEncoder,
  });
  vm.runInContext(source.replace(entry, `
  globalThis.harness = { boot, render,
    texture(url) { return loadTexture(gl, url, []); },
    install(m, g) { model = m; gl = g; },
    mappings(e, a) { emotions = e; actions = a; authored = { emotions: e, actions: a }; },
    character(c) { character = c; adapter = null; applyCharacter(); },
    actionStart(name) { return life.actions.get(name)?.start; },
    relax(now) { relaxEmotion(now); },
    state() { return { mood: life.mood, emotion: life.emotion, actions: [...life.actions.keys()], disposed: floatDisposed }; }
  };
})();`), context, { timeout: 1000 });
  return { api: context.harness, command: value => window.stage.command(value), canvas,
    install: () => context.harness.install(model, gl), document, documentEvents, canvasEvents, windowEvents, posts, frames,
    at(time) { now = time; },
    render(time) { now = time; context.harness.render(time); },
    next(time) { const [id, fn] = frames.entries().next().value; frames.delete(id); now = time; fn(time); },
    counts: () => ({ releases, lost, reads, draws, reloads, initialized, textures }),
  };
}

test('real float render path has a hard ceiling, reports buffer bounds and no room calls', () => {
  const s = stage(); s.install(); s.render(0);
  for (let i = 1; i <= 120; i++) s.next(i * 1000 / 120);
  assert.ok(s.counts().draws <= 31);
  assert.equal(s.counts().reads, s.counts().draws);
  assert.equal(s.posts.length, 1, 'unchanged bounds need no new native geometry');
  // The 5×4 CSS canvas on a 3× screen: the buffer is drawn at device density.
  // The one drawn pixel (1, 10)–(2, 11), with the window's room to spare (two
  // pixels at the least, see float.js BoundsFollower) inside the buffer.
  assert.deepEqual(s.posts[0], { type: 'floatBounds', width: 15, height: 12,
    bounds: { left: 0, top: 8, right: 4, bottom: 12 } });
  assert.equal(s.canvasEvents.has('pointerdown'), false);
  s.command({ type: 'pause' });
  assert.equal(s.frames.size, 0);
  assert.equal(s.counts().releases, 1);
  assert.equal(s.counts().lost, 1);
  s.command({ type: 'resume' }); s.command({ type: 'dispose' }); s.render(5000);
  assert.equal(s.frames.size, 0);
  assert.equal(s.counts().releases, 1);
});

test('float native state accepts only its own command and does not replay an unchanged action', () => {
  const s = stage(); s.install();
  s.api.mappings({ calm: {}, happy: {} }, { nod: { ms: 100, tracks: {} } });
  s.command({ type: 'petState', state: 'attention' });
  assert.deepEqual(copy(s.api.state()), { mood: 'idle', emotion: 'happy', actions: ['nod'], disposed: false });
  const start = s.api.actionStart('nod');
  s.render(200);
  s.command({ type: 'petState', state: 'attention' });
  assert.equal(s.api.actionStart('nod'), start);
  s.command({ type: 'mood', mood: 'speaking' });
  s.command({ type: 'activity', name: 'rest' });
  assert.equal(s.api.state().mood, 'idle');
  s.command({ type: 'petState', state: 'thinking' });
  assert.deepEqual(copy(s.api.state()), { mood: 'idle', emotion: 'calm', actions: [], disposed: false });
});

test('a native tap plays the room reaction, then gives her face back to the pet state', () => {
  const s = stage(); s.install();
  s.api.mappings({ calm: {}, happy: {}, shy: {}, surprised: {}, confused: {} },
    { nod: { ms: 100, tracks: {} }, nodSmall: { ms: 100, tracks: {} }, recoil: { ms: 100, tracks: {} },
      duck: { ms: 100, tracks: {} }, tilt: { ms: 100, tracks: {} } });
  s.command({ type: 'petState', state: 'attention' });
  s.command({ type: 'tap', x: NaN, y: 0.5 });
  assert.deepEqual(copy(s.api.state()), { mood: 'idle', emotion: 'happy', actions: ['nod'], disposed: false });
  // Dead centre of the viewport is her body: surprised, and she ducks.
  s.command({ type: 'tap', x: 0.5, y: 0.5 });
  assert.equal(s.api.state().emotion, 'surprised');
  assert.ok(s.api.state().actions.includes('duck'));
  assert.deepEqual(s.posts.at(-1), { type: 'touch', zone: 'body', kind: 'tap' });
  s.api.relax(1499);
  assert.equal(s.api.state().emotion, 'surprised');
  s.api.relax(1501);
  assert.equal(s.api.state().emotion, 'happy', 'back to the attention face, not calm');
  s.api.relax(1e9);
  assert.equal(s.api.state().emotion, 'happy', 'the state face has no deadline');
});

test('a character with nothing authored still reacts to a tap, and wears no state it was not given', () => {
  const s = stage(); s.install();
  s.api.character({});
  s.command({ type: 'petState', state: 'attention' });
  assert.deepEqual(copy(s.api.state()), { mood: 'idle', emotion: 'calm', actions: [], disposed: false });
  s.command({ type: 'tap', x: 0.5, y: 0.5 });
  assert.equal(s.api.state().emotion, 'surprised');
  assert.deepEqual(copy(s.api.state().actions), ['duck']);
  s.api.relax(1e6);
  assert.equal(s.api.state().emotion, 'calm');
});

test('native reduced-motion updates stop gestures without replacing the page or replaying a state', () => {
  const s = stage();
  s.install();
  s.api.mappings({ calm: {}, happy: {} }, { nod: { ms: 100, tracks: {} } });
  s.command({ type: 'petState', state: 'attention', reduceMotion: false });
  assert.notEqual(s.api.actionStart('nod'), undefined);
  s.command({ type: 'petState', state: 'attention', reduceMotion: true });
  assert.equal(s.api.actionStart('nod'), undefined);
  s.command({ type: 'petState', state: 'attention', reduceMotion: false });
  assert.equal(s.api.actionStart('nod'), undefined);
  assert.equal(s.counts().reloads, 0);
});

test('hidden float releases once, asks native for a fresh page on visibility, and never reloads itself', () => {
  const s = stage(); s.install(); s.render(0);
  s.document.hidden = true; s.documentEvents.get('visibilitychange')();
  s.document.hidden = false; s.documentEvents.get('visibilitychange')();
  assert.equal(s.frames.size, 0);
  assert.equal(s.counts().lost, 1);
  assert.equal(s.posts.at(-1).type, 'floatResume');
  s.canvasEvents.get('webglcontextrestored')();
  assert.equal(s.counts().reloads, 0);
});

test('unexpected context loss reports one fixed code, without the private local URL', () => {
  const s = stage(); s.install(); s.render(0);
  s.canvasEvents.get('webglcontextlost')({ preventDefault() {} });
  s.canvasEvents.get('webglcontextlost')({ preventDefault() {} });
  assert.deepEqual(s.posts.filter(p => p.type === 'floatError'),
    [{ type: 'floatError', code: 'companion_context_lost' }]);
  assert.equal(s.frames.size, 0);
  assert.equal(s.counts().releases, 1);
});

test('dispose during character loading fences even a fetch that resolves after abort', async () => {
  let resolve;
  const s = stage(true, () => new Promise(r => { resolve = r; }));
  const boot = s.api.boot();
  s.command({ type: 'dispose' });
  resolve({ ok: true, json: async () => ({}) });
  await new Promise(r => setImmediate(r));
  resolve({ ok: true, json: async () => ({}) });
  await boot;
  assert.equal(s.counts().initialized, 0);
  assert.equal(s.frames.size, 0);
  assert.equal(s.posts.length, 0);
});

test('room mode keeps its pointer handlers, pause/resume and context restore behavior', () => {
  const s = stage(false); s.install(); s.render(100);
  assert.equal(s.canvasEvents.has('pointerdown'), true);
  assert.equal(s.counts().reads, 0);
  s.command({ type: 'pause' }); assert.equal(s.frames.size, 0);
  assert.equal(s.counts().releases, 0);
  s.command({ type: 'resume' }); assert.equal(s.frames.size, 1);
  s.canvasEvents.get('webglcontextrestored')(); assert.equal(s.counts().reloads, 1);
});

test('the room tells the app the resolution that held: a step down at once, a step up after a minute', () => {
  const s = stage(false); s.install();
  const reported = () => s.posts.filter(p => p.type === 'quality').map(p => p.value);
  let t = 0;
  const frames = (ms, every) => { for (const end = t + ms; t < end;) { t += every; s.render(t); } };
  // Every frame 60 ms apart while 30 were asked: late, three seconds running.
  frames(4500, 60);
  assert.deepEqual(reported(), [0.85]);
  // Under the log she's asked for twelve, which any resolution keeps: that earns nothing.
  s.command({ type: 'covered', on: true });
  frames(90000, 1000 / 12);
  assert.deepEqual(reported(), [0.85]);
  assert.equal(s.canvas.width, 13, 'still at 0.85 of 5 CSS px on a 3x screen');
  s.command({ type: 'covered', on: false });
  // On time at thirty: ten quiet seconds step up, told only once it has held a minute.
  frames(15000, 1000 / 30);
  assert.equal(s.canvas.width, 15);
  assert.deepEqual(reported(), [0.85], 'the step up has not held yet');
  frames(60000, 1000 / 30);
  assert.deepEqual(reported(), [0.85, 1]);
  // That one held, so falling later costs no longer wait: back up after ten.
  frames(4500, 60);
  assert.deepEqual(reported(), [0.85, 1, 0.85]);
  frames(11500, 1000 / 30);
  assert.equal(s.canvas.width, 15);
  // This one falls before it has held: the next try waits twenty.
  frames(4500, 60);
  assert.equal(s.canvas.width, 13);
  frames(12000, 1000 / 30);
  assert.equal(s.canvas.width, 13, 'twice as long this time');
  frames(10000, 1000 / 30);
  assert.equal(s.canvas.width, 15);
});

test('shaking the phone makes her dizzy once; a bump, a still hand and the float window do not', () => {
  const s = stage(false); s.install(); s.render(100);
  s.api.mappings({ calm: {}, dizzy: {} }, { shake: { ms: 100, tracks: {} } });
  const move = (time, x) => { s.at(time); s.windowEvents.get('devicemotion')({ acceleration: { x, y: 0, z: 0 } }); };
  move(1000, 16); move(1040, -16); // The second is the same jolt still ringing.
  move(1200, 3); move(1300, -16);
  assert.equal(s.api.state().emotion, 'calm', 'two jolts are a bump');
  move(1500, 16);
  assert.equal(s.api.state().emotion, 'dizzy');
  assert.ok(s.api.state().actions.includes('shake'));
  assert.deepEqual(s.posts.at(-1), { type: 'touch', zone: 'body', kind: 'shake' });
  const told = s.posts.length;
  move(1700, -16); move(1900, 16); move(2100, -16);
  assert.equal(s.posts.length, told, 'still dizzy: no second round straight away');
  move(6000, 16); move(8000, -16); move(10000, 16);
  assert.equal(s.posts.length, told, 'jolts far apart are not a shake');
  s.windowEvents.get('devicemotion')({ acceleration: null });
  assert.equal(stage().windowEvents.has('devicemotion'), false);
});

test('dimmed float freezes without disposing; actual hidden state still releases the GL context', () => {
  const s = stage(); s.install(); s.render(0);
  s.command({ type: 'freeze' });
  assert.equal(s.frames.size, 0);
  assert.equal(s.counts().releases, 0);
  s.command({ type: 'thaw' });
  assert.equal(s.frames.size, 1);
  s.command({ type: 'thaw' });
  assert.equal(s.frames.size, 1);
  s.document.hidden = true; s.documentEvents.get('visibilitychange')();
  assert.equal(s.frames.size, 0);
  assert.equal(s.counts().releases, 1);
});

for (const phase of ['metadata', 'resize']) test(`dispose during texture ${phase} closes the late bitmap without allocating a texture`, async () => {
  let enter, finish;
  const entered = new Promise(resolve => { enter = resolve; });
  const delayed = new Promise(resolve => { finish = resolve; });
  let calls = 0, closed = 0;
  // Over the stage's 1024 limit, so a second, scaled decode follows.
  const bitmap = () => ({ width: 2000, height: 30, close() { closed++; } });
  const s = stage(true, async () => ({ blob: async () => ({}) }), {
    createImageBitmap() {
      calls++;
      if (calls === (phase === 'metadata' ? 1 : 2)) { enter(); return delayed; }
      return Promise.resolve(bitmap());
    },
  });
  s.install();
  const loading = s.api.texture('http://127.0.0.1/synthetic.png');
  await entered;
  s.command({ type: 'dispose' });
  finish(bitmap());
  await assert.rejects(loading, /float_disposed/);
  assert.equal(closed, phase === 'metadata' ? 1 : 2);
  assert.equal(s.counts().textures, 0);
  assert.equal(s.counts().lost, 1);
});

test('a texture within the limit is decoded once; a larger one again, scaled from the source', async () => {
  const upload = { premultiplyAlpha: 'premultiply', colorSpaceConversion: 'none' };
  for (const [width, decodes] of [
    [1024, [upload]],
    [2048, [upload, { ...upload, resizeWidth: 1024, resizeHeight: 256, resizeQuality: 'high' }]],
  ]) {
    const calls = [];
    const s = stage(true, async () => ({ blob: async () => ({}) }), {
      createImageBitmap(_, options) {
        calls.push({ ...options });
        return Promise.resolve({ width: options.resizeWidth ?? width, height: options.resizeHeight ?? 512, close() {} });
      },
    });
    s.install();
    await s.api.texture('http://127.0.0.1/synthetic.png');
    assert.deepEqual(calls, decodes);
  }
});

test('real boot cancels a late optional motion and releases its unfinished Core owner once', async () => {
  let enter, finish;
  const entered = new Promise(resolve => { enter = resolve; });
  const lateMotion = new Promise(resolve => { finish = resolve; });
  const core = { allocated: 0, motions: 0, released: 0 };
  class UserModel {
    loadModel() { this._model = {}; core.allocated++; }
    loadMotion() { core.motions++; throw new Error('late motion must not allocate'); }
    release() { core.released++; this._model = null; }
    createRenderer() { throw new Error('cancelled model must not create a renderer'); }
  }
  class Setting {
    getModelFileName() { return 'test.moc3'; }
    getExpressionCount() { return 0; }
    getMotionGroupCount() { return 1; }
    getMotionGroupName() { return 'work'; }
    getMotionCount() { return 1; }
    getMotionFileName() { return 'work.motion3.json'; }
    getEyeBlinkParameterCount() { return 0; }
    getLipSyncParameterCount() { return 0; }
  }
  const s = stage(true, async url => {
    if (url.endsWith('character.json')) return { ok: true, json: async () => ({ model: 'test.model3.json' }) };
    if (url.endsWith('adapter.json')) return { ok: false };
    if (url.endsWith('index.json')) return { ok: true, json: async () => [] };
    if (url.endsWith('test.model3.json')) return { ok: true, arrayBuffer: async () => new TextEncoder().encode('{}').buffer };
    if (url.endsWith('test.moc3')) return { ok: true, arrayBuffer: async () => new Uint8Array([77, 79, 67, 51, 1]).buffer };
    if (url.endsWith('work.motion3.json')) return { ok: true, arrayBuffer: () => { enter(); return lateMotion; } };
    throw new Error(`unexpected synthetic fetch: ${url}`);
  }, { UserModel, Setting });
  const booting = s.api.boot();
  await entered;
  assert.equal(core.allocated, 1);
  s.command({ type: 'dispose' });
  finish(new ArrayBuffer(0)); // Boundary intentionally ignores AbortSignal.
  await booting;
  assert.deepEqual(core, { allocated: 1, motions: 0, released: 1 });
  assert.equal(s.counts().lost, 1);
  assert.equal(s.frames.size, 0);
  assert.equal(s.posts.length, 0);
});

test('a release exception cannot suppress context loss or the native fallback notification', () => {
  const s = stage(true, undefined, { releaseError: true });
  s.install(); s.render(0);
  s.canvasEvents.get('webglcontextlost')({ preventDefault() {} });
  assert.equal(s.counts().releases, 1);
  assert.equal(s.counts().lost, 1);
  assert.equal(s.frames.size, 0);
  assert.deepEqual(s.posts.filter(p => p.type === 'floatError'),
    [{ type: 'floatError', code: 'companion_context_lost' }]);
});
