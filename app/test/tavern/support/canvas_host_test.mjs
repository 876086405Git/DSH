// Runs the canvas page's piece for ST's own page (tavern_canvas_host.dart:
// tavernCanvasHostJs; tavern_canvas_host_test.dart writes it to the file
// DSH_HOST_SCRIPT names) on a bare global with what the page around it
// gives (res, call, fire, post…), and checks what it does.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const code = JSON.parse(readFileSync(process.env.DSH_HOST_SCRIPT, 'utf8')).host;
const wait = (ms) => new Promise((ok) => setTimeout(ok, ms));

/** A preset in ST's shape: two prompts, one in the order on, one off. */
function preset(on = true) {
  return {
    temperature: 1,
    prompts: [
      { identifier: 'main', name: 'Main' },
      { identifier: 'extra', name: 'Extra', content: 'x' },
    ],
    prompt_order: [{ character_id: 100001, order: [{ identifier: 'main', enabled: true }, { identifier: 'extra', enabled: on }] }],
  };
}

function page({ loadedPresetId = 'p1', refuse = false, working = false, slow = 0 } = {}) {
  const fired = [];
  const calls = [];
  const posts = [];
  const errors = [];
  const observers = [];
  // The library's presets, by id; any not written yet as preset() at s1.
  const library = {};
  const stored = (id) => library[id] ?? { ref: { kind: 'stored', presetId: id }, raw: preset(), version: 's1' };
  const w = {
    console,
    setTimeout,
    clearTimeout,
    JSON,
    Object,
    SillyTavern: {},
    events: { MESSAGE_RECEIVED: 'MESSAGE_RECEIVED' },
    res: {
      preset: { ref: { kind: 'current' }, raw: preset(), version: 'v1', source: { loadedPresetId, working } },
    },
    clone: (v) => (v === undefined ? undefined : JSON.parse(JSON.stringify(v))),
    // Kept as plain values of this realm, to compare.
    fire: (name, args) => fired.push([name, [...args]]),
    eventOn() {},
    eventOnce() {},
    eventRemoveListener() {},
    eventEmit() {},
    eventMakeFirst() {},
    eventMakeLast() {},
    toastr: { error: (m) => errors.push(m) },
    post: (o) => posts.push(JSON.parse(JSON.stringify(o))),
    getLoadedPresetName: () => '小猫',
    call(method, params) {
      calls.push([method, params]);
      if (method === 'readPreset') return Promise.resolve(stored(params.ref.presetId));
      if (method === 'replacePreset') {
        // refuse: every write, or those to the library preset of that id.
        if (refuse === true || refuse === params.ref.presetId) {
          return wait(slow).then(() => Promise.reject(new Error('changed meanwhile')));
        }
        const saved = { ref: params.ref, raw: params.raw, version: 's2' };
        if (params.ref.kind === 'stored') library[params.ref.presetId] = saved;
        const done = params.ref.kind === 'current' ? { ...saved, version: 'v2' } : saved;
        return slow ? wait(slow).then(() => done) : Promise.resolve(done);
      }
      return Promise.reject(new Error('unexpected ' + method));
    },
    MutationObserver: class {
      constructor(fn) {
        this.fn = fn;
        observers.push(this);
      }
      observe(target, options) {
        this.target = target;
        this.options = options;
      }
    },
  };
  w.window = w;
  vm.createContext(w);
  vm.runInContext(code, w);
  return { w, fired, calls, posts, errors, observers };
}

const extra = (settings) => settings.prompt_order[0].order[1];

test('ST context: eventSource over the page events, eventTypes with what the page sends', () => {
  const { w } = page();
  const st = w.SillyTavern;
  assert.equal(st.eventSource.on, w.eventOn);
  assert.equal(st.eventSource.removeListener, w.eventRemoveListener);
  assert.equal(st.eventSource.emit, w.eventEmit);
  assert.equal(st.eventTypes, w.events);
  assert.equal(st.event_types, w.events);
  assert.equal(st.eventTypes.SETTINGS_UPDATED, 'SETTINGS_UPDATED');
  assert.equal(st.eventTypes.OAI_PRESET_CHANGED_AFTER, 'OAI_PRESET_CHANGED_AFTER');
  assert.equal(st.mainApi, 'openai');
});

test('chatCompletionSettings: the preset in use in ST shape, one copy that keeps what a script changed', () => {
  const { w } = page();
  const s = w.SillyTavern.chatCompletionSettings;
  assert.equal(s.preset_settings_openai, '小猫');
  assert.equal(s.temperature, 1);
  extra(s).enabled = false;
  assert.equal(w.SillyTavern.chatCompletionSettings, s);
  assert.equal(extra(w.SillyTavern.chatCompletionSettings).enabled, false);
  // The page's own copy of the preset is not touched.
  assert.equal(extra(w.res.preset.raw).enabled, true);
  // A delivery that is the same preset keeps it; a changed one is taken afresh.
  w.res.preset = { ...w.res.preset };
  assert.equal(w.SillyTavern.chatCompletionSettings, s);
  w.res.preset = { ...w.res.preset, raw: preset(false), version: 'v2' };
  assert.notEqual(w.SillyTavern.chatCompletionSettings, s);
  // No preset read yet: none.
  w.res.preset = undefined;
  assert.equal(w.SillyTavern.chatCompletionSettings, undefined);
});

test('saveSettingsDebounced writes what changed into the library preset the chat uses, at its version', async () => {
  const { w, calls } = page();
  const s = w.SillyTavern.chatCompletionSettings;
  extra(s).enabled = false;
  w.SillyTavern.saveSettingsDebounced();
  w.SillyTavern.saveSettingsDebounced();
  // While it waits and writes, the copy stays, even with a new delivery.
  w.res.preset = { ...w.res.preset, version: 'v1b' };
  assert.equal(w.SillyTavern.chatCompletionSettings, s);
  await wait(400);
  assert.deepEqual(
    calls.map((c) => c[0]),
    ['readPreset', 'replacePreset'],
  );
  const [, write] = calls[1];
  assert.deepEqual(write.ref, { kind: 'stored', presetId: 'p1' });
  assert.equal(write.expectedVersion, 's1');
  assert.equal(extra(write.raw).enabled, false);
  // Only what changed: not our own name for it.
  assert.equal(write.raw.preset_settings_openai, undefined);
  assert.equal(write.raw.temperature, 1);
  // Nothing more changed: nothing written again.
  w.SillyTavern.saveSettingsDebounced();
  await wait(400);
  assert.equal(calls.length, 2);
});

test('with no library preset, the chat’s own (in use) is written, and read back as written', async () => {
  const { w, calls } = page({ loadedPresetId: null });
  extra(w.SillyTavern.chatCompletionSettings).enabled = false;
  w.SillyTavern.saveSettingsDebounced();
  await wait(400);
  assert.deepEqual(
    calls.map((c) => c[0]),
    ['replacePreset'],
  );
  assert.deepEqual(calls[0][1].ref, { kind: 'current' });
  assert.equal(calls[0][1].expectedVersion, 'v1');
  assert.equal(w.res.preset.version, 'v2');
  assert.equal(extra(w.SillyTavern.chatCompletionSettings).enabled, false);
});

test('a write refused: said so, and the preset as it is read again by whoever listens', async () => {
  const { w, fired, errors } = page({ refuse: true });
  const s = w.SillyTavern.chatCompletionSettings;
  extra(s).enabled = false;
  w.SillyTavern.saveSettingsDebounced();
  await wait(400);
  assert.deepEqual(errors, ['changed meanwhile']);
  assert.deepEqual(fired, [['SETTINGS_UPDATED', []]]);
  assert.equal(extra(w.SillyTavern.chatCompletionSettings).enabled, true);
});

test('a write refused: a listener reading the settings then gets the preset as it is', async () => {
  const { w } = page({ refuse: true });
  extra(w.SillyTavern.chatCompletionSettings).enabled = false;
  const seen = [];
  w.fire = () => seen.push(extra(w.SillyTavern.chatCompletionSettings).enabled);
  w.SillyTavern.saveSettingsDebounced();
  await wait(400);
  assert.deepEqual(seen, [true]);
});

test('a write refused while another edit waits: that goes too, and listeners read the preset as it is', async () => {
  // The first write is out from 300 ms and refused at 400; the second edit would be due at 650.
  const { w, calls } = page({ refuse: true, slow: 100 });
  const s = w.SillyTavern.chatCompletionSettings;
  extra(s).enabled = false;
  w.SillyTavern.saveSettingsDebounced();
  await wait(350);
  s.temperature = 2;
  w.SillyTavern.saveSettingsDebounced();
  const seen = [];
  w.fire = () => seen.push(w.SillyTavern.chatCompletionSettings.temperature);
  await wait(600);
  assert.deepEqual(seen, [1]);
  assert.equal(calls.filter((c) => c[0] === 'replacePreset').length, 1);
});

test('another preset chosen while an edit waits: the edit is not written into it', async () => {
  const { w, calls, fired } = page();
  extra(w.SillyTavern.chatCompletionSettings).enabled = false;
  w.SillyTavern.saveSettingsDebounced();
  w.res.preset = { ref: { kind: 'current' }, raw: preset(), version: 'b1', source: { loadedPresetId: 'p2' } };
  await wait(400);
  assert.deepEqual(calls, []);
  assert.deepEqual(fired, [['SETTINGS_UPDATED', []]]);
  assert.equal(extra(w.SillyTavern.chatCompletionSettings).enabled, true);
});

test('an edit undone, and another preset chosen while it waited: listeners told to read again', async () => {
  const { w, calls, fired } = page();
  const s = w.SillyTavern.chatCompletionSettings;
  extra(s).enabled = false;
  w.SillyTavern.saveSettingsDebounced();
  extra(s).enabled = true;
  w.res.preset = { ref: { kind: 'current' }, raw: preset(false), version: 'b1', source: { loadedPresetId: 'p2' } };
  await wait(400);
  assert.deepEqual(calls, []);
  assert.deepEqual(fired, [['SETTINGS_UPDATED', []]]);
  assert.equal(extra(w.SillyTavern.chatCompletionSettings).enabled, false);
});

test('a working copy in use: written there, as generation reads it, not to the library one', async () => {
  const { w, calls } = page({ working: true });
  extra(w.SillyTavern.chatCompletionSettings).enabled = false;
  w.SillyTavern.saveSettingsDebounced();
  await wait(400);
  assert.deepEqual(
    calls.map((c) => c[0]),
    ['replacePreset'],
  );
  assert.deepEqual(calls[0][1].ref, { kind: 'current' });
  assert.equal(calls[0][1].expectedVersion, 'v1');
});

test('an edit due while a write is out: written after it, against what it wrote', async () => {
  // The first write is out from 300 ms to 900; the second edit is due at 650.
  const { w, calls } = page({ slow: 600 });
  const s = w.SillyTavern.chatCompletionSettings;
  extra(s).enabled = false;
  w.SillyTavern.saveSettingsDebounced();
  await wait(350);
  extra(s).enabled = true;
  w.SillyTavern.saveSettingsDebounced();
  await wait(400);
  assert.equal(calls.filter((c) => c[0] === 'replacePreset').length, 1);
  await wait(1000);
  const writes = calls.filter((c) => c[0] === 'replacePreset');
  assert.equal(writes.length, 2);
  assert.equal(extra(writes[1][1].raw).enabled, true);
});

test('another preset chosen while a write is out: its settings at once, and an edit of it its own', async () => {
  const { w, calls } = page({ slow: 300 });
  extra(w.SillyTavern.chatCompletionSettings).enabled = false;
  w.SillyTavern.saveSettingsDebounced();
  await wait(350);
  const b = preset(false);
  b.temperature = 2;
  w.res.preset = { ref: { kind: 'current' }, raw: b, version: 'b1', source: { loadedPresetId: 'p2' } };
  const s = w.SillyTavern.chatCompletionSettings;
  assert.equal(s.temperature, 2);
  s.temperature = 3;
  w.SillyTavern.saveSettingsDebounced();
  await wait(900);
  const writes = calls.filter((c) => c[0] === 'replacePreset');
  assert.equal(writes.length, 2);
  assert.equal(writes[1][1].raw.temperature, 3);
  // Written into B, the one the copy is.
  assert.deepEqual({ ...writes[1][1].ref }, { kind: 'stored', presetId: 'p2' });
});

/** A's toggle written (refused, slow ms on), and at 350 ms B chosen and its temperature set to 3. */
async function editAThenB(w) {
  extra(w.SillyTavern.chatCompletionSettings).enabled = false;
  w.SillyTavern.saveSettingsDebounced();
  await wait(350);
  w.res.preset = { ref: { kind: 'current' }, raw: preset(), version: 'b1', source: { loadedPresetId: 'p2' } };
  w.SillyTavern.chatCompletionSettings.temperature = 3;
  w.SillyTavern.saveSettingsDebounced();
}

for (const [when, slow] of [
  ['still waiting', 300],
  ['queued behind it', 600],
]) {
  test(`A's write refused with an edit of B ${when}: B's is written all the same`, async () => {
    const { w, calls, errors } = page({ refuse: 'p1', slow });
    await editAThenB(w);
    await wait(1500);
    const writes = calls.filter((c) => c[0] === 'replacePreset');
    assert.deepEqual(
      writes.map((c) => c[1].ref.presetId),
      ['p1', 'p2'],
    );
    assert.equal(writes[1][1].raw.temperature, 3);
    assert.deepEqual(errors, ['changed meanwhile']);
    assert.equal(w.SillyTavern.chatCompletionSettings.temperature, 3);
  });
}

test('presetDelivered: SETTINGS_UPDATED when the preset changed, OAI_PRESET_CHANGED_AFTER when it is another', () => {
  const { w, fired } = page();
  const a = { version: 'v1', source: { loadedPresetId: 'p1' } };
  w.presetDelivered(undefined, a);
  w.presetDelivered(a, { ...a });
  assert.deepEqual(fired, []);
  w.presetDelivered(a, { version: 'v2', source: { loadedPresetId: 'p1' } });
  assert.deepEqual(fired, [['SETTINGS_UPDATED', []]]);
  fired.length = 0;
  w.presetDelivered(a, { version: 'v3', source: { loadedPresetId: 'p2' } });
  assert.deepEqual(fired, [
    ['OAI_PRESET_CHANGED_AFTER', []],
    ['SETTINGS_UPDATED', []],
  ]);
});

/** Just enough of a page for ST's places for buttons. */
function dom(w) {
  const made = [];
  w.document = {
    createElement(tag) {
      const el = { tag, style: { setProperty: (k, v, p) => (el.css = [k, v, p]) }, found: [] };
      el.querySelectorAll = () => el.found;
      el.querySelector = (sel) => el.found.find((x) => sel === `[data-dsh-press="${x.dataset.dshPress}"]`) || null;
      made.push(el);
      return el;
    },
    body: { appendChild: (el) => (w.document.body.child = el) },
  };
  return made;
}

function button(text, { title = '', inside = false } = {}) {
  return {
    textContent: text,
    title,
    dataset: {},
    clicks: 0,
    getAttribute: () => null,
    parentElement: { closest: () => (inside ? {} : null) },
    click() {
      this.clicks++;
    },
  };
}

test('ST places for buttons: made once, out of sight; what lands there told to the app; a press clicks it', () => {
  const { w, posts, observers } = page();
  const made = dom(w);
  w.hostAnchors();
  w.hostAnchors();
  assert.equal(made.length, 1);
  const host = made[0];
  assert.equal(w.document.body.child, host);
  assert.equal(host.id, 'dsh-st-host');
  assert.deepEqual(host.css, ['display', 'none', 'important']);
  for (const id of ['send_form', 'qr--bar', 'qr--buttons', 'extensionsMenu']) assert.match(host.innerHTML, new RegExp(id));
  assert.equal(observers.length, 1);
  assert.equal(observers[0].target, host);
  assert.deepEqual({ ...observers[0].options }, { childList: true, subtree: true, characterData: true });

  const menu = button('  猫神\n  剧场 ');
  const icon = button('', { title: '设置' });
  const bare = button('');
  const nested = button('里面', { inside: true });
  host.found = [menu, icon, bare, nested];
  observers[0].fn();
  assert.deepEqual(posts, [
    {
      type: 'hostButtons',
      buttons: [
        { id: '1', label: '猫神 剧场' },
        { id: '2', label: '设置' },
      ],
    },
  ]);
  // The same again: not told twice; ids stay with their buttons.
  observers[0].fn();
  assert.equal(posts.length, 1);
  host.found = [icon];
  observers[0].fn();
  assert.deepEqual(posts[1].buttons, [{ id: '2', label: '设置' }]);

  w.press('2');
  w.press('9');
  assert.equal(icon.clicks, 1);
  assert.equal(menu.clicks, 0);
});
