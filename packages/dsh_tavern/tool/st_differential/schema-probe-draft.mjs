// Standalone Tavern Helper character script. Run only in the synthetic lab in schema-probe-ops.md.
// No restricted implementation is embedded or inspected. Dynamic import runs the public module.
const PROBE = Object.freeze({
  format: 'dsh-schema-probe-v1',
  cardName: 'DSH_SCHEMA_PROBE_ONLY',
  marker: 'dsh_schema_probe',
  markerValue: 'synthetic-laboratory-v1',
  greeting: 'DSH schema probe: synthetic laboratory opening.',
  runButton: 'Schema probe: run once',
  exportButton: 'Schema probe: export log',
  stVersion: '1.19.0',
  stCommit: '7e8663cd9c184a550b37238218bdd32c6efc68e9',
  helperVersion: '4.12.0',
  mvuCommit: 'd03b7dc8a6ebf9bd611c7e2dc91f3b35462deebc',
  schemaCommit: '1d7a409d46f44487e7d8073e91b8a3adcbd83c68',
  schemaBlob: '171f96692ef1ca22cc365586c7645a6f8dc11f88',
  schemaUrl: 'https://testingcf.jsdelivr.net/gh/StageDog/tavern_resource@1d7a409d46f44487e7d8073e91b8a3adcbd83c68/dist/util/mvu_zod.js',
});
const EVENTS = [
  'mag_variable_initialized',
  'mag_variable_update_started',
  'mag_command_parsed',
  'mag_command_parsed_for_zod',
  'mag_command_parsed_ended_for_zod',
  'mag_variable_update_ended',
  'mag_variable_update_ended_for_zod',
  'mag_before_message_update',
];
const COMMAND_FIELDS = new Set(['type', 'full_match', 'args', 'reason']);
const INPUT = "_.set('meter', 20);\n_.add('meter', -8);";
const records = [];
const objectIds = new WeakMap();
const symbolIds = new Map();
const ownListeners = [];
let nextIdentity = 1;
let sequence = 0;
let region = 'setup';
let anchor = null;
let used = false;
let observerActive = true;
let registrationInvoked = false;
let transformCount = 0;
let failure = false;
let runtimeVersions = null;
const startedAt = new Date().toISOString();
const startTick = performance.now();

function identity(value) {
  const map = typeof value === 'symbol' ? symbolIds : objectIds;
  if (!map.has(value)) map.set(value, nextIdentity++);
  return map.get(value);
}

function ownValue(value, key) {
  if (value === null || !['object', 'function'].includes(typeof value)) return undefined;
  const descriptor = Object.getOwnPropertyDescriptor(value, key);
  return descriptor && Object.hasOwn(descriptor, 'value') ? descriptor.value : undefined;
}

function keyInfo(key) {
  return typeof key === 'symbol'
    ? { kind: 'symbol', id: identity(key), text: String(key) }
    : { kind: 'string', text: key };
}

function zodVersion() {
  const version = ownValue(ownValue(ownValue(globalThis, 'z'), 'core'), 'version');
  const parts = ['major', 'minor', 'patch'].map(key => ownValue(version, key));
  return parts.every(value => Number.isSafeInteger(value) && value >= 0)
    ? { status: 'observed', source: 'global z.core.version own data properties', value: parts.join('.') }
    : { status: 'unknown', reason: 'No numeric major/minor/patch own-data metadata was available; helper version is not a Zod version pin.' };
}

// No subject-property reads, getters, toJSON, function source, or prototype walks.
// Reflection on a Proxy can still invoke its traps; this is not a proof of transparency.
function describe(root) {
  const seen = new Set();
  let objects = 0;
  let truncated = false;
  function visit(value, depth) {
    const kind = typeof value;
    if (value === null) return { kind: 'null' };
    if (kind === 'undefined') return { kind };
    if (kind === 'string') return { kind, value: value.slice(0, 2000), truncated: value.length > 2000 };
    if (kind === 'number') return { kind, value: Number.isFinite(value) ? value : String(value) };
    if (kind === 'boolean') return { kind, value };
    if (kind === 'bigint') return { kind, value: String(value) };
    if (kind === 'symbol') return keyInfo(value);
    const id = identity(value);
    if (kind === 'function') return { kind, id };
    if (seen.has(value)) return { kind: 'reference', id };
    if (depth > 9 || ++objects > 1200) {
      truncated = true;
      return { kind: 'truncated', id };
    }
    seen.add(value);
    try {
      const descriptors = Object.getOwnPropertyDescriptors(value);
      const prototype = Object.getPrototypeOf(value);
      const properties = Reflect.ownKeys(descriptors).map(key => {
        const descriptor = descriptors[key];
        const common = {
          key: keyInfo(key), enumerable: descriptor.enumerable, configurable: descriptor.configurable,
        };
        return Object.hasOwn(descriptor, 'value')
          ? { ...common, kind: 'data', writable: descriptor.writable, value: visit(descriptor.value, depth + 1) }
          : { ...common, kind: 'accessor', hasGet: typeof descriptor.get === 'function', hasSet: typeof descriptor.set === 'function' };
      });
      return { kind: Array.isArray(value) ? 'array' : 'object', id, prototypeId: prototype === null ? null : identity(prototype), properties };
    } catch (error) {
      return { kind: 'reflection-failed', id, errorType: typeof error };
    }
  }
  return { value: visit(root, 0), truncated };
}

function commandShapes(commands) {
  if (!Array.isArray(commands)) return { kind: 'not-array' };
  return Reflect.ownKeys(commands).filter(key => typeof key === 'string' && /^(0|[1-9]\d*)$/.test(key)).map(index => {
    const descriptor = Object.getOwnPropertyDescriptor(commands, index);
    if (!descriptor || !Object.hasOwn(descriptor, 'value')) return { index, kind: 'array-accessor' };
    const command = descriptor.value;
    if (command === null || typeof command !== 'object') return { index, kind: typeof command };
    const keys = Reflect.ownKeys(command);
    return {
      index, id: identity(command), keys: keys.map(keyInfo),
      extraKeysRejectedByNative: keys.filter(key => typeof key !== 'string' || !COMMAND_FIELDS.has(key)).map(keyInfo),
      missingOwnFields: [...COMMAND_FIELDS].filter(key => !Object.hasOwn(command, key)),
    };
  });
}

function record(kind, value = {}) {
  records.push({ seq: ++sequence, ms: Math.round((performance.now() - startTick) * 1000) / 1000, region, kind, ...value });
}

function sameChat() {
  return anchor !== null && getCurrentCharacterName() === PROBE.cardName &&
    SillyTavern.getCurrentChatId() === anchor.chatId;
}

async function assertSynthetic() {
  if (getCurrentCharacterName() !== PROBE.cardName) throw new Error('Probe refused: the synthetic laboratory card is not open.');
  const card = await getCharacter('current');
  if (getCurrentCharacterName() !== PROBE.cardName ||
      ownValue(ownValue(card, 'extensions'), PROBE.marker) !== PROBE.markerValue) {
    throw new Error('Probe refused: the synthetic laboratory marker is missing.');
  }
  const messages = getChatMessages(0);
  const message = messages[0];
  const text = ownValue(message, 'message');
  if (getLastMessageId() !== 0 || messages.length !== 1 || ownValue(message, 'role') !== 'assistant' ||
      (text !== PROBE.greeting && text !== `${PROBE.greeting}\n\n<StatusPlaceHolderImpl/>`)) {
    throw new Error('Probe refused: expected the one-message synthetic opening.');
  }
  const chatId = SillyTavern.getCurrentChatId();
  if (anchor !== null && chatId !== anchor.chatId) throw new Error('Probe refused: the laboratory chat changed.');
  anchor = { chatId };
}

function observe(event, edge) {
  return (...args) => {
    if (!observerActive) return;
    try {
      if (!sameChat()) return;
      record('event', {
        event, edge, args: describe(args),
        commandShapes: event.startsWith('mag_command_parsed') ? commandShapes(args[1]) : undefined,
      });
    } catch (error) {
      record('observer-error', { event, edge, error: describe(error) });
    }
  };
}

async function waitForMvu() {
  let timeout;
  try {
    await Promise.race([
      waitGlobalInitialized('Mvu'),
      new Promise((_, reject) => {
        timeout = setTimeout(() => reject(new Error('Mvu provider was not published within 30 seconds; check its fixed import and public error log.')), 30000);
      }),
    ]);
  } finally {
    clearTimeout(timeout);
  }
}

function installObservers() {
  for (const event of EVENTS) {
    const first = observe(event, 'first-observer');
    const last = observe(event, 'last-observer');
    ownListeners.push({ event, first, last });
    eventMakeFirst(event, first);
    eventMakeLast(event, last);
  }
}

function moveOwnObserversToEnds() {
  for (const { event, first, last } of ownListeners) {
    eventMakeFirst(event, first);
    eventMakeLast(event, last);
  }
  record('observer-order', { meaning: 'Moved our observers to the ends immediately before this call; later dynamic registrations can change the order.' });
}

function stopObservers() {
  observerActive = false;
  for (const { event, first, last } of ownListeners) {
    eventRemoveListener(event, first);
    eventRemoveListener(event, last);
  }
}

function floorSnapshot(name) {
  const data = Mvu.getMvuData({ type: 'message', message_id: 0 });
  record(name, { data: describe(data) });
  return data;
}

function report() {
  return {
    format: PROBE.format, mode: 'normal-reference-only', startedAt,
    runtimeVersions, declaredPins: {
      stCommit: PROBE.stCommit, mvuCommit: PROBE.mvuCommit,
      schemaCommit: PROBE.schemaCommit, schemaBlob: PROBE.schemaBlob, schemaUrl: PROBE.schemaUrl,
      note: 'ST/helper versions are queried; ST/MVU commits are operator declarations. Schema entry SHA/blob were checked through Git ref/tree metadata, not by reading source. Transitive dependency pins are not established.',
    },
    used, failure, registrationInvoked, transformCount,
    observedInitializationEdges: records.filter(row => row.kind === 'event' && row.event === 'mag_variable_initialized').length,
    limits: [
      'No native bridge ran. Result 2 or no visible function is not a compatibility proof.',
      'WeakMap state, closures, object identity and Proxy behavior may be unobserved.',
      'Native command feedback rejects pure-JSON extra keys as well as unsupported values.',
      'Initialization snapshots are not evidence that the first initialization event was observed.',
      'No explicit persistence API is called by this probe; module registration may initialize only the isolated synthetic chat.',
    ],
    records,
  };
}

function emitReport() {
  // Only our descriptor records and primitives are serialized, never the subject graph.
  console.info('[DSH-SCHEMA-PROBE] REPORT_JSON', JSON.stringify(report()));
}

function fail(error) {
  failure = true;
  record('failure', { error: describe(error) });
  stopObservers();
  console.error('[DSH-SCHEMA-PROBE] Stopped. Inspect the descriptor-only REPORT_JSON.');
  emitReport();
}

async function runOnce() {
  if (used || failure) {
    console.warn('[DSH-SCHEMA-PROBE] No second run is allowed in this script session.');
    return;
  }
  used = true;
  try {
    if (!registrationInvoked) throw new Error('Schema registration has not been invoked.');
    await assertSynthetic();
    record('operator-ready', { evidence: 'The operator clicked run after checking the public registration-success log. This is not an API readiness guarantee.' });
    const oldData = floorSnapshot('floor-before-candidate');
    const stat = ownValue(oldData, 'stat_data');
    if (ownValue(stat, 'meter') !== 0) throw new Error('Expected synthetic floor 0 meter=0 before the candidate call.');
    const before = describe(oldData);
    const countBefore = transformCount;
    moveOwnObserversToEnds();
    region = 'candidate';
    record('candidate-input', { message: INPUT, data: before });
    const result = await Mvu.parseMessage(INPUT, oldData);
    if (!sameChat()) throw new Error('The laboratory chat changed during the candidate call.');
    record('candidate-result', {
      data: describe(result),
      meter: describe(ownValue(ownValue(result, 'stat_data'), 'meter')),
      label: describe(ownValue(ownValue(result, 'stat_data'), 'label')),
      transformCallsDuringCandidate: transformCount - countBefore,
      interpretation: '2 is the sequential-clamp prediction; 10 is the final-only-clamp prediction. Neither establishes native bridge compatibility. Zero transform calls leaves schema execution unconfirmed.',
    });
    record('input-after-candidate', { data: describe(oldData) });
    floorSnapshot('floor-after-candidate');
    region = 'complete';
    stopObservers();
    emitReport();
  } catch (error) {
    fail(error);
  }
}

function exportLog() {
  const text = JSON.stringify(report(), null, 2);
  const url = URL.createObjectURL(new Blob([text], { type: 'application/json' }));
  const link = document.createElement('a');
  link.href = url;
  link.download = 'dsh-schema-probe-normal.json';
  link.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
  emitReport();
}

async function start() {
  await new Promise(resolve => { $(resolve); });
  await assertSynthetic();
  runtimeVersions = { st: getTavernVersion(), helper: getTavernHelperVersion(), zod: zodVersion() };
  if (runtimeVersions.st !== PROBE.stVersion || runtimeVersions.helper !== PROBE.helperVersion) {
    throw new Error('Probe refused: ST/helper version differs from the declared experiment.');
  }
  installObservers();
  eventOn(getButtonEvent(PROBE.runButton), runOnce);
  eventOn(getButtonEvent(PROBE.exportButton), exportLog);
  record('armed', { card: PROBE.cardName, expectedOpeningMeter: 0, expectedDefaultLabel: 'sample' });
  console.info('[DSH-SCHEMA-PROBE] Observers armed; waiting for Mvu provider.');
  await waitForMvu();
  await assertSynthetic();
  floorSnapshot('floor-before-schema-registration');
  region = 'registration';
  const Schema = z.object({
    meter: z.coerce.number().transform(value => {
      const output = Math.max(0, Math.min(10, value));
      transformCount++;
      record('our-schema-transform', { input: value, output });
      return output;
    }),
    label: z.string().prefault('sample'),
  });
  const schemaModule = await import(PROBE.schemaUrl);
  await assertSynthetic();
  const returned = schemaModule.registerMvuSchema(Schema);
  registrationInvoked = true;
  record('registration-invoked', { returned: describe(returned), readiness: 'Not inferred from the return value or promise.' });
  region = 'awaiting-operator';
  console.info('[DSH-SCHEMA-PROBE] Check the module public registration-success log, then click "Schema probe: run once". No candidate runs automatically.');
}

window.addEventListener('pagehide', stopObservers, { once: true });
void start().catch(fail);
