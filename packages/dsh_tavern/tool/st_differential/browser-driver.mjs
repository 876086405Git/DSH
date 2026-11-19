// SPDX-License-Identifier: AGPL-3.0-only
// Synthetic-input driver for the real SillyTavern browser application.
// Public exports and request shapes checked against SillyTavern 1.19.0:
// 7e8663cd9c184a550b37238218bdd32c6efc68e9, public/script.js,
// public/scripts/{openai,power-user,world-info,authors-note,variables,
// group-chats,RossAscends-mods,PromptManager,welcome-screen,system-messages}.js.
// The session guard suppresses two UI previews, never native Generate or its
// prompt assembly, macros, world-info scan, or tokenizer.
const recorderUrl = new URL(import.meta.url).origin;
const stOrigin = globalThis.location?.origin;
if (!stOrigin || !['localhost', '127.0.0.1', '[::1]'].includes(globalThis.location.hostname)) {
  throw new Error('Load this module from the browser console of the local ST test instance.');
}
const [script, openai, power, world, extensions, notes, groups, ross] = await Promise.all([
  import(`${stOrigin}/script.js`), import(`${stOrigin}/scripts/openai.js`),
  import(`${stOrigin}/scripts/power-user.js`), import(`${stOrigin}/scripts/world-info.js`),
  import(`${stOrigin}/scripts/extensions.js`), import(`${stOrigin}/scripts/authors-note.js`),
  import(`${stOrigin}/scripts/group-chats.js`), import(`${stOrigin}/scripts/RossAscends-mods.js`),
]);
const clone = value => structuredClone(value);
const response = await fetch(`${recorderUrl}/fixtures`);
if (!response.ok) throw new Error(`Fixture load failed: ${response.status}`);
export const fixtures = await response.json();
for (const fixture of fixtures) {
  const entry = fixture.presetEntry ?? 'inline';
  if (!['inline', 'library'].includes(entry)) throw new Error(`Unknown presetEntry: ${entry}`);
  if (entry === 'library' && (!fixture.expectedGlobalVariablesAfter
      || typeof fixture.expectedGlobalVariablesAfter !== 'object' || Array.isArray(fixture.expectedGlobalVariablesAfter))) {
    throw new Error('Library fixtures must declare expectedGlobalVariablesAfter as an object.');
  }
}
export const report = [];
let busy = false;

function sameJson(first, second) {
  if (first === second) return true;
  if (first === null || second === null || typeof first !== 'object' || typeof second !== 'object') return false;
  if (Array.isArray(first) || Array.isArray(second)) {
    return Array.isArray(first) && Array.isArray(second) && first.length === second.length
      && first.every((value, index) => sameJson(value, second[index]));
  }
  const keys = Object.keys(first);
  return keys.length === Object.keys(second).length
    && keys.every(key => Object.hasOwn(second, key) && sameJson(first[key], second[key]));
}
function assertState(actual, expected, label) {
  if (!sameJson(actual, expected)) {
    throw new Error(`${label} differ: actual=${JSON.stringify(actual)}, expected=${JSON.stringify(expected)}`);
  }
}

async function installUiGuard() {
  function requireFreshPage() {
    // openWelcomeScreen awaits its panel/assistant before pushing this pair.
    // An empty chat can mean that initialization is still in flight; allowing
    // it would let a later welcome continuation append to the fixture's chat.
    const [assistant, welcome] = script.chat;
    const types = script.system_message_types;
    const readyWelcome = script.chat.length === 2
      && assistant?.extra?.type === types.ASSISTANT_MESSAGE
      && assistant.is_user === false && assistant.is_system === false && assistant.extra.swipeable === false
      && welcome?.extra?.type === types.WELCOME_PROMPT
      && welcome.is_user === false && welcome.is_system === true && welcome.extra.swipeable === false;
    if (script.this_chid !== undefined || script.getCurrentChatId() !== undefined || groups.selected_group != null
        || script.isGenerating() || !readyWelcome) {
      throw new Error('Use a fresh ST page with its completed native welcome pair and no character, group, or chat previously selected.');
    }
  }
  requireFreshPage();
  const manager = openai.promptManager;
  if (!manager?.serviceSettings || typeof manager.tryGenerate !== 'function') {
    throw new Error('Wait for the native ST PromptManager to initialize, then reload this fresh page.');
  }
  if (typeof ross.RA_CountCharTokens !== 'function') {
    throw new Error('The fixed ST native character-token counter export is unavailable.');
  }
  const originalDescriptor = Object.getOwnPropertyDescriptor(manager, 'tryGenerate');
  const counters = new Map();
  let observer;
  let active = false;
  let failure;
  let suppressedPreviews = 0;
  let counterCutoff;
  let counterInvalidatedAfter;
  const previewGuard = async () => { suppressedPreviews++; };
  function suppressCounters() {
    for (const element of document.querySelectorAll('[data-token-counter]')) {
      const value = element.getAttribute('data-token-counter');
      if (value === null) continue;
      if (!counters.has(element)) counters.set(element, value);
      element.removeAttribute('data-token-counter');
    }
  }
  function status() {
    const sameManager = openai.promptManager === manager;
    const ownsPreview = manager.tryGenerate === previewGuard;
    return {
      active, healthy: active && sameManager && ownsPreview && !failure,
      samePromptManager: sameManager, ownsPreviewGuard: ownsPreview,
      suppressedPreviews, suppressedCounterElements: counters.size,
      counterCutoff, counterInvalidatedAfter,
      ...(failure ? { error: String(failure) } : {}),
    };
  }
  function assertActive() {
    if (!active) throw new Error('The UI guard has been disposed; reload a fresh page before recording again.');
    if (failure) throw failure;
    if (openai.promptManager !== manager || manager.tryGenerate !== previewGuard) {
      throw new Error('The native PromptManager or its session guard changed during recording.');
    }
    // Also cover a mutation in the current task before the observer microtask.
    suppressCounters();
  }
  function restore() {
    const errors = [];
    observer?.disconnect();
    try {
      if (manager.tryGenerate === previewGuard) {
        if (originalDescriptor) Object.defineProperty(manager, 'tryGenerate', originalDescriptor);
        else delete manager.tryGenerate;
      } else if (active) {
        errors.push(new Error('The preview guard was replaced; the later method was left untouched.'));
      }
    } catch (error) {
      errors.push(error);
    } finally {
      active = false;
      // Keep the exact Element and value, including empty attributes and nodes
      // removed from the document while the session was active.
      for (const [element, value] of counters) {
        try { element.setAttribute('data-token-counter', value); }
        catch (error) { errors.push(error); }
      }
    }
    if (errors.length) throw new AggregateError(errors, 'UI guard restoration failed.');
  }
  try {
    manager.tryGenerate = previewGuard;
    if (manager.tryGenerate !== previewGuard) throw new Error('Unable to install the UI preview guard.');
    active = true;
    observer = new MutationObserver(() => {
      try { suppressCounters(); }
      catch (error) { failure ??= error; }
    });
    observer.observe(document.documentElement, {
      subtree: true, childList: true, attributes: true, attributeFilter: ['data-token-counter'],
    });
    suppressCounters();
    counterCutoff = Date.now();
    const deadline = performance.now() + 5000;
    do {
      counterInvalidatedAfter = Date.now();
      if (counterInvalidatedAfter > counterCutoff) break;
      if (performance.now() >= deadline) throw new Error('Native token-counter clock did not advance.');
      await new Promise(resolve => setTimeout(resolve, 1));
    } while (true);
    assertActive();
    // The original function sets its private nonce synchronously at entry.
    // With no counter elements, it only cancels older suspended UI scans.
    // A same-millisecond call would not establish that cancellation.
    await ross.RA_CountCharTokens();
    requireFreshPage();
    assertActive();
    return { status, assertActive, dispose() { if (active) restore(); return status(); } };
  } catch (error) {
    try { restore(); }
    catch (cleanupError) { throw new AggregateError([error, cleanupError], 'UI guard installation and rollback failed.'); }
    throw error;
  }
}

// Imports and fixture loading above must finish before any reversible UI change.
// Keep the guard installed between fixtures and after errors until dispose().
const uiGuard = await installUiGuard();
export function guardStatus() { return uiGuard.status(); }
export function dispose() {
  if (busy) throw new Error('Wait for the active fixture to finish before disposing the UI guard.');
  return uiGuard.dispose();
}

async function jsonFetch(url, options) {
  const response = await fetch(url, options);
  if (!response.ok) throw new Error(`${new URL(url, stOrigin).pathname}: HTTP ${response.status}`);
  return response.json();
}
function connection() {
  if (script.main_api !== 'openai' || openai.oai_settings.chat_completion_source !== 'deepseek') {
    throw new Error('Select Chat Completion / DeepSeek in ST before running the driver.');
  }
  if (script.online_status === 'no_connection') {
    throw new Error('Use ST Connect and confirm its local proxy dialog first.');
  }
  if (String(openai.oai_settings.reverse_proxy).replace(/\/$/, '') !== recorderUrl) {
    throw new Error(`ST reverse proxy must be ${recorderUrl}.`);
  }
  if (script.isGenerating()) throw new Error('Wait for the existing ST generation to finish.');
  return { reverse_proxy: openai.oai_settings.reverse_proxy, proxy_password: openai.oai_settings.proxy_password };
}
async function importCard(fixture) {
  const form = new FormData();
  form.append('avatar', new File([JSON.stringify(fixture.card)], `${fixture.id}.json`, { type: 'application/json' }));
  form.append('file_type', 'json');
  form.append('user_name', fixture.settings.userName);
  const result = await jsonFetch('/api/characters/import', {
    method: 'POST', body: form, headers: script.getRequestHeaders({ omitContentType: true }),
  });
  if (!result.file_name || result.error) throw new Error(`Card import failed for ${fixture.id}.`);
  const avatar = `${result.file_name}.png`;
  await script.getCharacters();
  const id = script.characters.findIndex(character => character.avatar === avatar);
  if (id < 0) throw new Error(`Imported avatar not listed: ${avatar}`);
  await script.selectCharacterById(id, { switchMenu: false });
  if (String(script.this_chid) !== String(id)) throw new Error('ST did not switch to the imported fixture card.');
  return avatar;
}
function applySettings(fixture, proxy) {
  // ST Default contains empty connection fields: preserve the connected local proxy.
  const preset = clone(fixture.preset);
  for (const [key, [, setting]] of Object.entries(openai.settingsToUpdate)) {
    if (Object.hasOwn(preset, key)) openai.oai_settings[setting] = preset[key];
  }
  Object.assign(openai.oai_settings, proxy, {
    function_calling: false, reasoning_effort: fixture.preset.reasoning_effort ?? 'auto',
    bypass_status_check: false, extensions: clone(preset.extensions ?? {}),
  });
  const settings = fixture.settings;
  script.setUserName(settings.userName, { toastPersonaNameChange: false });
  Object.assign(power.power_user, {
    experimental_macro_engine: true, persona_description: settings.persona,
    persona_description_position: settings.personaInPrompt ? power.persona_description_positions.IN_PROMPT
      : power.persona_description_positions.NONE,
    persona_description_lorebook: '', pin_examples: settings.pinExamples, strip_examples: settings.stripExamples,
    custom_stopping_strings: JSON.stringify(settings.stops), custom_stopping_strings_macro: true,
  });
  // The real WI scanner loads these exported-cache entries; no hits are preselected.
  for (const book of fixture.books) world.worldInfoCache.set(book.id, clone(book.json));
  world.updateWorldInfoSettings(clone(settings.worldInfo), fixture.books.map(book => book.id));
  extensions.extension_settings.regex = [];
  extensions.extension_settings.note ??= {};
  extensions.extension_settings.note.chara = [];
  extensions.extension_settings.note.allowWIScan = settings.authorNote?.scan ?? false;
}
function resetMutableInput(fixture) {
  const note = fixture.settings.authorNote;
  const metadata = clone(fixture.chatHeader.chat_metadata);
  // The native chat was already saved under its own integrity UUID. Replacing
  // it with a fixture UUID would trigger ST's normal save-conflict protection.
  if (typeof script.chat_metadata.integrity !== 'string' || !script.chat_metadata.integrity) {
    throw new Error('The imported character chat has no native integrity identifier.');
  }
  metadata.integrity = script.chat_metadata.integrity;
  Object.assign(metadata, {
    note_prompt: note?.content ?? '', note_interval: note ? 1 : 0, note_depth: note?.depth ?? 4,
    note_position: note?.placement === 'beforeMain' ? 2 : note?.placement === 'inChat' ? 1 : 0,
    note_role: ({ system: 0, user: 1, assistant: 2 })[note?.role ?? 'system'],
  });
  script.updateChatMetadata(metadata, true);
  extensions.extension_settings.variables ??= {};
  extensions.extension_settings.variables.global = clone(fixture.globalVariables);
  script.chat.splice(0, script.chat.length, ...clone(fixture.messages));
  for (const key of Object.keys(script.extension_prompts)) delete script.extension_prompts[key];
  // setFloatingPrompt reads the native textarea as well as chat metadata.
  globalThis.$('#extension_floating_prompt').val(note?.content ?? '');
  notes.setFloatingPrompt();
  globalThis.$('#send_textarea').val('');
}
export async function runFixture(id) {
  if (busy) throw new Error('The driver runs one fixture at a time.');
  uiGuard.assertActive();
  const fixture = fixtures.find(value => value.id === id);
  if (!fixture) throw new Error(`Unknown fixture: ${id}`);
  const proxy = connection();
  const checkGlobalState = Object.hasOwn(fixture, 'expectedGlobalVariablesAfter');
  busy = true;
  const result = {
    id, generationType: fixture.generationType, startedAt: new Date().toISOString(), uiGuardBefore: uiGuard.status(),
  };
  try {
    result.avatar = await importCard(fixture);
    uiGuard.assertActive();
    applySettings(fixture, proxy);
    resetMutableInput(fixture);
    await script.redisplayChat({ fade: false });
    // UI rendering may evaluate macros; restore the declared inputs before Generate.
    resetMutableInput(fixture);
    const before = await jsonFetch(`${recorderUrl}/health`);
    await jsonFetch(`${recorderUrl}/active-case`, { method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ id }) });
    uiGuard.assertActive();
    result.uiGuardBeforeGeneration = uiGuard.status();
    result.variablesBefore = clone(script.chat_metadata.variables);
    if (checkGlobalState) {
      result.presetApplication = 'declared-settings';
      result.globalVariablesBefore = clone(extensions.extension_settings.variables.global);
      assertState(result.variablesBefore, fixture.chatHeader.chat_metadata.variables, 'Local variables before generation');
      assertState(result.globalVariablesBefore, fixture.globalVariables, 'Global variables before generation');
    }
    result.sampling = {
      temperature: openai.oai_settings.temp_openai, top_p: openai.oai_settings.top_p_openai,
      presence_penalty: openai.oai_settings.pres_pen_openai,
      frequency_penalty: openai.oai_settings.freq_pen_openai,
      model: openai.oai_settings.deepseek_model,
    };
    await script.Generate(fixture.generationType);
    uiGuard.assertActive();
    const after = await jsonFetch(`${recorderUrl}/health`);
    uiGuard.assertActive();
    result.attempt = after.attempts[id] ?? 0;
    result.newCaptures = (after.counts[id] ?? 0) - (before.counts[id] ?? 0);
    result.variablesAfter = clone(script.chat_metadata.variables);
    if (result.newCaptures !== 1) throw new Error(`Expected exactly one capture; saw ${result.newCaptures}.`);
    if (checkGlobalState) {
      result.globalVariablesAfter = clone(extensions.extension_settings.variables.global);
      assertState(result.variablesAfter, fixture.expectedVariablesAfter, 'Local variables after generation');
      assertState(result.globalVariablesAfter, fixture.expectedGlobalVariablesAfter, 'Global variables after generation');
      result.variableStateMatches = true;
      result.globalVariableStateMatches = true;
    }
    result.status = 'recorded';
    console.info('DSH_RECORDED', clone(result));
    return clone(result);
  } catch (error) {
    result.status = 'failed'; result.error = String(error);
    console.error('DSH_RECORDING_FAILED', clone(result));
    throw error;
  } finally {
    result.uiGuardAfter = uiGuard.status();
    result.finishedAt = new Date().toISOString(); report.push(result); busy = false;
  }
}
export async function runAll({ fromId = fixtures[0].id } = {}) {
  const start = fixtures.findIndex(fixture => fixture.id === fromId);
  if (start < 0) throw new Error(`Unknown start fixture: ${fromId}`);
  for (const fixture of fixtures.slice(start)) await runFixture(fixture.id);
  console.info('DSH_RECORDING_COMPLETE', clone(report));
  return clone(report);
}
export function downloadReport() {
  const url = URL.createObjectURL(new Blob([JSON.stringify(report, null, 2) + '\n'], { type: 'application/json' }));
  const link = document.createElement('a'); link.href = url; link.download = 'st-driver-report.json'; link.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
