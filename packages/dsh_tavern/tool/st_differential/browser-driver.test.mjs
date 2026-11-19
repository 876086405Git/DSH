// SPDX-License-Identifier: AGPL-3.0-only
// Executes the unmodified driver module with explicit browser/ST adapters.
// These are guard lifecycle tests, not real ST recordings or tokenizer evidence.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import vm from 'node:vm';

const source = await fs.readFile(new URL('./browser-driver.mjs', import.meta.url), 'utf8');
const copy = value => structuredClone(value);
const fixture = {
  id: 'one', generationType: 'normal', card: { data: { name: 'Synthetic' } }, preset: {}, books: [],
  settings: { userName: 'User', persona: '', personaInPrompt: false, stops: [], worldInfo: {} },
  chatHeader: { chat_metadata: { integrity: 'fixture-only', variables: { x: 0 } } },
  messages: [{ is_user: true, mes: 'Synthetic input' }], globalVariables: {},
};

function environment(options = {}) {
  const observers = new Set();
  let pendingMutation = false;
  function mutated() {
    if (pendingMutation) return;
    pendingMutation = true;
    queueMicrotask(() => {
      pendingMutation = false;
      for (const observer of observers) if (observer.active) observer.callback([]);
    });
  }
  class Element {
    constructor(value) { this.attributes = new Map([['data-token-counter', value]]); }
    getAttribute(name) { return this.attributes.get(name) ?? null; }
    setAttribute(name, value) { this.attributes.set(name, value); mutated(); }
    removeAttribute(name) { if (this.attributes.delete(name)) mutated(); }
  }
  const first = new Element('description'), second = new Element('personality'), empty = new Element('');
  const elements = [first, second, empty];
  const document = {
    documentElement: {},
    querySelectorAll() { return elements.filter(element => element.getAttribute('data-token-counter') !== null); },
  };
  class MutationObserver {
    constructor(callback) { this.callback = callback; this.active = false; observers.add(this); }
    observe() { this.active = true; }
    disconnect() { this.active = false; }
  }
  let tick = 100, elapsed = 0, nonce = 0, pauseCounter;
  let generating = false;
  const counterStarts = [], generationInputs = [], counts = {}, attempts = {}, logs = [];
  // Fixed welcome-screen.js sends this pair after its last initialization await;
  // system-messages.js supplies the welcome prompt's system flags. Bodies are
  // synthetic here and are never used as a generation fixture.
  const welcomePair = [
    { name: 'Assistant', mes: 'Welcome assistant', is_user: false, is_system: false,
      extra: { type: 'assistant_message', swipeable: false } },
    { name: 'System', mes: 'Welcome panel prompt', is_user: false, is_system: true,
      extra: { type: 'welcome_prompt', swipeable: false } },
  ];
  const script = {
    this_chid: undefined, chat: welcomePair, chat_metadata: { variables: { x: 0 } }, characters: [], extension_prompts: {},
    system_message_types: { ASSISTANT_MESSAGE: 'assistant_message', WELCOME_PROMPT: 'welcome_prompt' },
    getCurrentChatId: () => script.this_chid === undefined ? undefined : 'selected-chat',
    main_api: 'openai', online_status: 'connected', isGenerating: () => generating,
    getRequestHeaders: () => ({}), getCharacters: async () => {}, setUserName() {},
    updateChatMetadata(value) {
      for (const key of Object.keys(script.chat_metadata)) delete script.chat_metadata[key];
      Object.assign(script.chat_metadata, value);
    },
    async selectCharacterById(id) {
      setExport('script.js', 'this_chid', id);
      script.updateChatMetadata({ integrity: 'native-chat-integrity', variables: { x: 9 } });
    },
    async redisplayChat() { await openai.promptManager.tryGenerate(); },
    async Generate(type) {
      generating = true;
      generationInputs.push({ type, variables: copy(script.chat_metadata.variables) });
      try {
        await options.onGenerate?.(api);
        counts.one = (counts.one ?? 0) + 1; attempts.one = (attempts.one ?? 0) + 1;
      } finally { generating = false; }
    },
  };
  const nativeGenerate = script.Generate;
  const nativePreview = async () => { script.chat_metadata.variables.x++; };
  const settings = { chat_completion_source: 'deepseek', reverse_proxy: 'http://127.0.0.1:19091', proxy_password: '' };
  const manager = { serviceSettings: settings, activeCharacter: { id: 100001 }, tryGenerate: nativePreview };
  const openai = { promptManager: manager, oai_settings: settings, settingsToUpdate: {} };
  const groups = { selected_group: null };
  // Adapter for the native nonce protocol (RossAscends-mods.js:207–271):
  // static NodeList, side effect before async token count, nonce checked before
  // each field and after await. It does not implement a macro or tokenizer.
  async function nativeCounter() {
    nonce = tick;
    counterStarts.push(tick);
    const currentNonce = nonce;
    if (options.counterError) throw new Error('counter failed');
    const nodeList = document.querySelectorAll('[data-token-counter]');
    for (const element of nodeList) {
      if (currentNonce !== nonce) return;
      if (element === empty) continue;
      script.chat_metadata.variables.x++;
      await pauseCounter;
      if (currentNonce !== nonce) return;
    }
  }
  const ross = { RA_CountCharTokens: nativeCounter };
  const extensions = { extension_settings: {} };
  const states = {
    'script.js': script, 'scripts/openai.js': openai, 'scripts/group-chats.js': groups,
    'scripts/RossAscends-mods.js': ross,
    'scripts/power-user.js': { power_user: {}, persona_description_positions: { IN_PROMPT: 0, NONE: 9 } },
    'scripts/world-info.js': { worldInfoCache: new Map(), updateWorldInfoSettings() {} },
    'scripts/extensions.js': extensions, 'scripts/authors-note.js': { setFloatingPrompt() {} },
  };
  const modules = new Map();
  function setExport(modulePath, name, value) {
    states[modulePath][name] = value;
    modules.get(modulePath)?.setExport(name, value);
  }
  class NativeDate extends Date { static now() { return tick; } }
  const context = vm.createContext({
    URL, File, FormData, Blob, structuredClone, document, MutationObserver, Date: NativeDate,
    performance: { now: () => elapsed }, location: { origin: 'http://localhost:8000', hostname: 'localhost' },
    console: { info: (...args) => logs.push(args), error: (...args) => logs.push(args) },
    setTimeout(callback) {
      elapsed += options.stallClock ? 1000 : 1;
      if (!options.stallClock) tick++;
      options.onTimer?.(api);
      queueMicrotask(callback);
    },
    $: () => ({ val() {} }),
    async fetch(url, init) {
      const pathname = new URL(url, 'http://localhost:8000').pathname;
      await options.onFetch?.(pathname, api);
      let body;
      if (pathname === '/fixtures') {
        if (options.fixtureFailure) return { ok: false, status: 503 };
        body = [options.fixture ?? fixture];
      } else if (pathname === '/api/characters/import') {
        script.characters.push({ avatar: 'one.png' }); body = { file_name: 'one' };
      } else if (pathname === '/health') body = { counts, attempts };
      else if (pathname === '/active-case') body = { activeId: JSON.parse(init.body).id };
      else throw new Error(`Unexpected fetch ${url}`);
      return { ok: true, status: 200, json: async () => copy(body) };
    },
  });
  const api = {
    script, openai, groups, manager, document, elements, first, second, empty, observers, extensions,
    nativePreview, nativeGenerate, nativeCounter, counterStarts, generationInputs, logs, setExport,
    append(value) { const element = new Element(value); elements.push(element); mutated(); return element; },
    detach(element) { elements.splice(elements.indexOf(element), 1); mutated(); },
    suspendCounter() { let release; pauseCounter = new Promise(resolve => { release = resolve; }); return release; },
    setGenerating(value) { generating = value; },
    async load() {
      const driver = new vm.SourceTextModule(source, {
        context, identifier: 'http://127.0.0.1:19091/browser-driver.mjs',
        initializeImportMeta(meta) { meta.url = 'http://127.0.0.1:19091/browser-driver.mjs'; },
        async importModuleDynamically(specifier) {
          const key = new URL(specifier).pathname.slice(1);
          if (options.importFailure === key) throw new Error('native import failed');
          const state = states[key];
          if (!state) throw new Error(`Unexpected import ${key}`);
          const module = new vm.SyntheticModule(Object.keys(state), function () {
            for (const [name, value] of Object.entries(state)) this.setExport(name, value);
          }, { context });
          modules.set(key, module);
          await module.link(() => { throw new Error('Unexpected nested import'); });
          await module.evaluate();
          return module;
        },
      });
      await driver.link(() => { throw new Error('Unexpected static import'); });
      await driver.evaluate();
      api.driver = driver.namespace;
      return api.driver;
    },
  };
  return api;
}

test('session accepts the complete native welcome pair and PM dummy, preserving messages and exact UI attributes', async () => {
  const env = environment();
  const welcomeMessages = [...env.script.chat];
  const descriptor = Object.getOwnPropertyDescriptor(env.manager, 'tryGenerate');
  const driver = await env.load();
  assert.equal(driver.guardStatus().healthy, true);
  assert.equal(env.document.querySelectorAll().length, 0);
  assert.ok(env.counterStarts[0] > driver.guardStatus().counterCutoff);
  assert.equal(env.script.Generate, env.nativeGenerate);
  assert.equal(env.script.chat[0], welcomeMessages[0]);
  assert.equal(env.script.chat[1], welcomeMessages[1]);
  await env.manager.tryGenerate();
  const added = env.append('new-field');
  env.first.setAttribute('data-token-counter', 'temporary-ui-value');
  await Promise.resolve();
  assert.equal(added.getAttribute('data-token-counter'), null);
  env.detach(env.second);
  assert.equal(driver.guardStatus().suppressedPreviews, 1);
  assert.equal(driver.guardStatus().suppressedCounterElements, 4);
  assert.equal(driver.dispose().active, false);
  assert.deepEqual(Object.getOwnPropertyDescriptor(env.manager, 'tryGenerate'), descriptor);
  assert.equal(env.first.getAttribute('data-token-counter'), 'description');
  assert.equal(env.second.getAttribute('data-token-counter'), 'personality');
  assert.equal(env.empty.getAttribute('data-token-counter'), '');
  assert.equal(added.getAttribute('data-token-counter'), 'new-field');
  env.first.setAttribute('data-token-counter', 'after-dispose');
  assert.equal(driver.dispose().active, false);
  await Promise.resolve();
  assert.equal(env.first.getAttribute('data-token-counter'), 'after-dispose');
  await assert.rejects(driver.runFixture('one'), /disposed/);
});

test('a strictly newer native nonce stops an old static NodeList after declared variables reset', async () => {
  const env = environment();
  const release = env.suspendCounter();
  const oldScan = env.nativeCounter();
  assert.equal(env.script.chat_metadata.variables.x, 1);
  const driver = await env.load();
  assert.ok(env.counterStarts[1] > env.counterStarts[0]);
  env.script.chat_metadata.variables.x = 0;
  release();
  await oldScan;
  assert.equal(env.script.chat_metadata.variables.x, 0);
  driver.dispose();

  const control = environment();
  const releaseControl = control.suspendCounter();
  const controlScan = control.nativeCounter();
  for (const element of control.elements) element.removeAttribute('data-token-counter');
  control.script.chat_metadata.variables.x = 0;
  releaseControl();
  await controlScan;
  assert.equal(control.script.chat_metadata.variables.x, 1, 'removal without nonce cancellation is insufficient');
});

test('selected state, incomplete welcome initialization, other messages, and uninitialized PM reject before changing UI', async () => {
  const cases = [
    env => { env.script.this_chid = 0; }, env => { env.script.chat.push({ mes: 'old chat' }); },
    env => { env.groups.selected_group = 'group'; }, env => env.setGenerating(true),
    env => { env.manager.serviceSettings = null; },
    env => { env.script.getCurrentChatId = () => 'selected-chat'; },
    env => { env.script.chat.length = 0; }, env => { env.script.chat.pop(); },
    env => { env.script.chat[0].extra.type = 'narrator'; },
    env => { env.script.chat[1].is_system = false; },
    env => { env.script.chat[0].extra.swipeable = true; },
  ];
  for (const alter of cases) {
    const env = environment(); alter(env);
    await assert.rejects(env.load(), /fresh ST page|initialize/);
    assert.equal(env.manager.tryGenerate, env.nativePreview);
    assert.equal(env.first.getAttribute('data-token-counter'), 'description');
    assert.equal(env.counterStarts.length, 0);
  }
});

test('native import and fixture failures happen before UI isolation', async () => {
  for (const options of [{ importFailure: 'scripts/RossAscends-mods.js' }, { fixtureFailure: true }]) {
    const env = environment(options);
    await assert.rejects(env.load(), /import failed|Fixture load failed/);
    assert.equal(env.manager.tryGenerate, env.nativePreview);
    assert.equal(env.first.getAttribute('data-token-counter'), 'description');
    assert.equal(env.observers.size, 0);
  }
});

test('counter rejection rolls back preview guard, observer, and every saved attribute', async () => {
  const env = environment({ counterError: true });
  await assert.rejects(env.load(), /counter failed/);
  assert.equal(env.manager.tryGenerate, env.nativePreview);
  assert.equal(env.first.getAttribute('data-token-counter'), 'description');
  assert.equal(env.empty.getAttribute('data-token-counter'), '');
  assert.ok([...env.observers].every(observer => !observer.active));
  const added = env.append('later');
  await Promise.resolve();
  assert.equal(added.getAttribute('data-token-counter'), 'later');
});

test('a nonadvancing wall clock fails with bounded rollback and never calls the counter', async () => {
  const env = environment({ stallClock: true });
  await assert.rejects(env.load(), /clock did not advance/);
  assert.equal(env.counterStarts.length, 0);
  assert.equal(env.manager.tryGenerate, env.nativePreview);
  assert.equal(env.second.getAttribute('data-token-counter'), 'personality');
});

test('an automatic selection during installation fails and restores the original UI', async () => {
  const env = environment({ onTimer: api => api.setExport('scripts/group-chats.js', 'selected_group', 'late-group') });
  await assert.rejects(env.load(), /fresh ST page/);
  assert.equal(env.manager.tryGenerate, env.nativePreview);
  assert.equal(env.first.getAttribute('data-token-counter'), 'description');
});

test('queued UI previews and editor scans cannot mutate final fixture inputs across repeated runs', async () => {
  const env = environment({ onFetch: async (pathname, api) => {
    if (pathname === '/health' || pathname === '/active-case') {
      await api.manager.tryGenerate();
      await api.nativeCounter();
    }
  } });
  const driver = await env.load();
  for (let attempt = 1; attempt <= 2; attempt++) {
    const result = await driver.runFixture('one');
    assert.equal(result.status, 'recorded');
    assert.equal(result.attempt, attempt);
    assert.equal(result.newCaptures, 1);
    assert.deepEqual(result.variablesBefore, { x: 0 });
    assert.equal(Object.hasOwn(result, 'globalVariableStateMatches'), false);
    assert.deepEqual(env.generationInputs[attempt - 1].variables, { x: 0 });
    assert.equal(driver.report[attempt - 1].uiGuardAfter.healthy, true);
    assert.equal(driver.guardStatus().active, true);
  }
  assert.equal(env.script.chat_metadata.integrity, 'native-chat-integrity');
  assert.ok(driver.guardStatus().suppressedPreviews >= 8);
  driver.dispose();
});

test('dispose refuses an active fixture and failed generation retains the guard until explicit cleanup', async () => {
  let release, entered;
  const started = new Promise(resolve => { entered = resolve; });
  const suspended = new Promise(resolve => { release = resolve; });
  const env = environment({ onGenerate: async () => { entered(); await suspended; throw new Error('generation failed'); } });
  const driver = await env.load();
  const run = driver.runFixture('one');
  await started;
  assert.throws(() => driver.dispose(), /active fixture/);
  assert.equal(driver.guardStatus().healthy, true);
  release();
  await assert.rejects(run, /generation failed/);
  assert.equal(driver.report[0].status, 'failed');
  assert.equal(driver.report[0].uiGuardAfter.healthy, true);
  assert.equal(driver.dispose().active, false);
});

test('losing method ownership rejects capture and disposal restores DOM without overwriting a later method', async () => {
  const foreign = async () => {};
  const env = environment({ onFetch: (pathname, api) => {
    if (pathname === '/active-case') api.manager.tryGenerate = foreign;
  } });
  const driver = await env.load();
  await assert.rejects(driver.runFixture('one'), /session guard changed/);
  assert.equal(env.generationInputs.length, 0);
  assert.equal(driver.report[0].status, 'failed');
  assert.equal(driver.report[0].uiGuardAfter.healthy, false);
  assert.throws(() => driver.dispose(), /restoration failed/);
  assert.equal(env.manager.tryGenerate, foreign);
  assert.equal(env.first.getAttribute('data-token-counter'), 'description');
  assert.ok([...env.observers].every(observer => !observer.active));
  assert.equal(driver.dispose().active, false);
});

test('a different live PM is rejected while cleanup still targets the original instance', async () => {
  const env = environment();
  const driver = await env.load();
  const other = { serviceSettings: {}, tryGenerate: async () => {} };
  env.setExport('scripts/openai.js', 'promptManager', other);
  await assert.rejects(driver.runFixture('one'), /session guard changed/);
  driver.dispose();
  assert.equal(env.manager.tryGenerate, env.nativePreview);
  assert.equal(env.openai.promptManager, other);
});

const stateFixture = {
  ...fixture, presetEntry: 'library', expectedVariablesAfter: { x: 1 },
  globalVariables: { deskFlag: 'initial', untouched: { enabled: false, values: [null, 'kept'] } },
  expectedGlobalVariablesAfter: { deskFlag: 'active', untouched: { enabled: false, values: [null, 'kept'] } },
};

test('declared local/global states are checked and their before snapshots survive generation', async () => {
  const env = environment({ fixture: stateFixture, onGenerate: api => {
    api.script.chat_metadata.variables.x = 1;
    // Different object key order is the same state, but scalar types are not.
    api.extensions.extension_settings.variables.global = {
      untouched: { values: [null, 'kept'], enabled: false }, deskFlag: 'active',
    };
  } });
  const driver = await env.load();
  const result = await driver.runFixture('one');
  assert.equal(result.status, 'recorded');
  assert.equal(result.presetApplication, 'declared-settings');
  assert.equal(result.variableStateMatches, true);
  assert.equal(result.globalVariableStateMatches, true);
  assert.deepEqual(result.variablesBefore, { x: 0 });
  assert.deepEqual(result.globalVariablesBefore, stateFixture.globalVariables);
  assert.deepEqual(result.globalVariablesAfter, stateFixture.expectedGlobalVariablesAfter);
  driver.dispose();
});

test('one captured request with a wrong local or global state remains a failed attempt', async () => {
  for (const scope of ['local', 'global']) {
    const env = environment({ fixture: stateFixture, onGenerate: api => {
      api.script.chat_metadata.variables.x = scope === 'local' ? '1' : 1;
      api.extensions.extension_settings.variables.global = copy(stateFixture.expectedGlobalVariablesAfter);
      if (scope === 'global') api.extensions.extension_settings.variables.global.untouched.values[0] = 'null';
    } });
    const driver = await env.load();
    await assert.rejects(driver.runFixture('one'), /variables after generation differ/);
    const result = driver.report[0];
    assert.equal(result.status, 'failed');
    assert.equal(result.newCaptures, 1);
    assert.equal(result.attempt, 1);
    assert.equal(Object.hasOwn(result, 'globalVariableStateMatches'), false);
    assert.equal(result.uiGuardAfter.healthy, true);
    assert.ok(result.globalVariablesAfter);
    driver.dispose();
  }
});

test('unknown preset entry and missing declared global state reject before changing the UI', async () => {
  for (const input of [{ ...fixture, presetEntry: 'libary' }, { ...fixture, presetEntry: 'library' }]) {
    const env = environment({ fixture: input });
    await assert.rejects(env.load(), /presetEntry|expectedGlobalVariablesAfter/);
    assert.equal(env.manager.tryGenerate, env.nativePreview);
    assert.equal(env.first.getAttribute('data-token-counter'), 'description');
    assert.equal(env.observers.size, 0);
  }
});
