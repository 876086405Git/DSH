#!/usr/bin/env node
// Developer-only metadata replay. Run the current stage's actual fitting
// methods; never import a second adapter algorithm or emit execution input.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import vm from 'node:vm';

const DEFAULT_STAGE = fileURLToPath(new URL('../../app/assets/companion/stage.js', import.meta.url));
const FIXTURES = new URL('./fixtures/', import.meta.url);
// Explicitly reviewed stage source. A different stage needs a new explicit pin;
// recognizing the same method names alone must not silently accept drift.
export const defaultStageSha256 = '298b4fda879242c21220e653af74857b209bec7160eb51c3fab86ff019d41927';
export const historicalPins = Object.freeze({
  sourcePatchSha256: 'b680a925e6effca5b0bdb3eb5f201709e79f514dbd1beee35cb3b62ec55f86f7',
  sourceBase: '98d4628746e2a37f09ebfb05530a718622357982',
  factsSha256: '26b3df74c076d20e44e6fff9c4d813a22fef1b92d650ed91b6671aeefe43d8c7',
  sourcesSha256: '483df289fb8c5d0f50dc1e284504d458d5912a9159a7d09a3eaac2a052378e06',
});
export const sha256 = (bytes) => createHash('sha256').update(bytes).digest('hex');
const jsonCopy = (value) => JSON.parse(JSON.stringify(value));
const hashPattern = /^[a-f0-9]{64}$/;
const string = (value) => typeof value === 'string' && value.length > 0;
const fail = (condition, message) => { if (!condition) throw new Error(message); };

function readBounded(file, max) {
  const bytes = readFileSync(file);
  fail(bytes.length <= max, `${file}: input exceeds ${max} bytes`);
  return bytes;
}

export function validateCorpus(facts, sources) {
  fail(facts?.format === 'dsh-companion-public-model-compact-facts-v1', 'Unknown historical facts format');
  fail(sources?.format === 'dsh-companion-evaluation-sources-v1', 'Unknown sources format');
  fail(Array.isArray(facts.models) && facts.models.length === 24, 'Expected the complete 24-model corpus');
  fail(Array.isArray(sources.models) && sources.models.length === 24, 'Expected 24 source associations');
  fail(facts.core?.sha256 === sources.core?.core?.sha256 && hashPattern.test(facts.core?.sha256), 'Core provenance differs');
  const byId = new Map(sources.models.map((row) => [row.id, row]));
  fail(byId.size === 24, 'Duplicate source model id');
  const sourceIds = new Set(sources.sources?.map((source) => source.id));
  const seenIds = new Set(), seenMocs = new Set();
  for (const row of facts.models) {
    const source = byId.get(row.id);
    fail(string(row.id) && !seenIds.has(row.id), 'Duplicate or missing model id');
    fail(hashPattern.test(row.moc) && !seenMocs.has(row.moc), 'Duplicate or invalid raw moc fingerprint');
    fail(source && source.mocSha256 === row.moc && source.identity === row.identity
      && sourceIds.has(source.sourceId), `${row.id}: source association differs`);
    assert.deepEqual(row.source, source.source, `${row.id}: source provenance differs`);
    fail(row.metadataFacts?.originalModel3Sha256 === source.model3Sha256
      && row.metadataFacts?.originalCdi3Sha256 === source.cdi3Sha256, `${row.id}: metadata hashes differ`);
    fail(row.coreSha256 === facts.core.sha256 && row.outcome === 'loaded'
      && row.probe?.loaded === true && row.probe.consistency === true, `${row.id}: historical Core result differs`);
    // This corpus is Core-only. FileReferences are inventory, not evidence of
    // Framework parsing, playback, effect safety, pixels or App load success.
    fail(row.probe.frameworkResourcesLoaded === false
      && row.probe.expressions?.length === 0 && row.probe.motions?.length === 0,
    `${row.id}: this replay cannot certify loaded resources`);
    validateParameters(row.probe.parameters);
    fail(row.probe.parameters.length === row.metadataFacts.parameterCount, `${row.id}: parameter count differs`);
    seenIds.add(row.id); seenMocs.add(row.moc);
  }
  fail(new Set(facts.models.map((row) => row.identity)).size === 18, 'Expected 18 identity/source families');
  return { facts, sources };
}

export function loadPinnedCorpus({ factsPath = new URL('live2d-core-facts-v1.json', FIXTURES),
  sourcesPath = new URL('live2d-core-sources-v1.json', FIXTURES) } = {}) {
  const facts = readBounded(factsPath, 1024 * 1024), sources = readBounded(sourcesPath, 128 * 1024);
  fail(sha256(facts) === historicalPins.factsSha256, 'Historical facts bytes differ from the C720 pin');
  fail(sha256(sources) === historicalPins.sourcesSha256, 'Historical source bytes differ from the C720 pin');
  const decoder = new TextDecoder('utf-8', { fatal: true });
  return validateCorpus(JSON.parse(decoder.decode(facts)), JSON.parse(decoder.decode(sources)));
}

function validateParameters(parameters) {
  fail(Array.isArray(parameters) && parameters.length > 0 && parameters.length <= 2000, 'Invalid measured parameter list');
  const ids = new Set();
  for (const parameter of parameters) {
    fail(string(parameter.id) && parameter.id.length <= 256 && !ids.has(parameter.id), 'Duplicate or invalid parameter id');
    fail([parameter.min, parameter.max, parameter.default].every(Number.isFinite)
      && parameter.min <= parameter.default && parameter.default <= parameter.max, `${parameter.id}: invalid measured range`);
    ids.add(parameter.id);
  }
}

/** Exact current source slice, with only metadata dependencies supplied.
 * No browser boot, download, rendering, model load, or persisted source edit.
 * The VM is an isolation convenience, not a sandbox for an untrusted stage.
 */
export function createStageReplay(stageSource, filename = DEFAULT_STAGE, expectedStageSha256 = defaultStageSha256) {
  fail(hashPattern.test(expectedStageSha256) && sha256(stageSource) === expectedStageSha256,
    'Stage SHA differs from the explicit pin; inspect the source before supplying --expected-stage-sha256');
  const startMarker = '  const STANDARD = {';
  const endMarker = "  const encodePath = (path) => path.split('/').map(encodeURIComponent).join('/');";
  const unique = (marker) => {
    const start = stageSource.indexOf(marker);
    fail(start >= 0 && stageSource.indexOf(marker, start + marker.length) === -1, 'Stage source boundary changed; inspect before updating the harness');
    return start;
  };
  const start = unique(startMarker), end = unique(endMarker);
  fail(end > start, 'Stage source boundaries are out of order');
  const slice = stageSource.slice(start, end);
  fail(slice.includes('class StageModel extends Fw.CubismUserModel'), 'StageModel definition is missing');
  const handles = new Map();
  const idManager = { getId(id) {
    if (!handles.has(id)) handles.set(id, Object.freeze({ getString: () => id }));
    return handles.get(id);
  } };
  const context = vm.createContext({
    Fw: { CubismUserModel: class {}, CubismFramework: { getIdManager: () => idManager } },
    // Used by other defined stage methods; replay below calls only fit/has/
    // range/id/set/add. No geometry is reconstructed from compact bounds.
    clamp: (value, lo, hi) => Math.min(hi, Math.max(lo, value)),
  });
  new vm.Script(`'use strict';\n${slice}\nglobalThis.corpusReplay = { StageModel, STANDARD };`, { filename })
    .runInContext(context, { timeout: 1000 });
  const { StageModel, STANDARD } = context.corpusReplay;
  fail(['fitParams', 'has', 'range', 'set', 'add'].every((name) => typeof StageModel?.prototype?.[name] === 'function'), 'Stage fitting interface changed');
  const standard = jsonCopy(STANDARD);
  fail(Object.keys(standard).length > 0 && Object.values(standard).every((range) =>
    Array.isArray(range) && range.length === 2 && range.every(Number.isFinite) && range[1] > range[0]), 'Invalid current stage vocabulary');

  function replay(parameters, model3 = {}) {
    validateParameters(parameters);
    const ids = parameters.map((parameter) => parameter.id);
    const raw = { ids, count: ids.length,
      minimumValues: parameters.map((parameter) => parameter.min),
      maximumValues: parameters.map((parameter) => parameter.max),
      defaultValues: parameters.map((parameter) => parameter.default) };
    const model = new StageModel();
    let calls = [];
    // These stand in for access to already measured metadata, not for a Core
    // implementation. Captures below are arguments, not post-clamp pixels.
    const capture = (operation, handle, value, weight) => {
      const id = handle.getString();
      fail(ids.includes(id) && Number.isFinite(value), 'Stage emitted an unknown/non-finite parameter call');
      calls.push({ operation, id, value, ...(weight === undefined ? {} : { weight }) });
    };
    model._model = {
      getModel: () => ({ parameters: raw }), getParameterCount: () => ids.length,
      getParameterIndex: (handle) => { const i = ids.indexOf(handle.getString()); return i < 0 ? ids.length : i; },
      setParameterValueById: (handle, value, weight) => capture('set', handle, value, weight),
      addParameterValueById: (handle, value) => capture('add', handle, value),
    };
    const group = (name) => (model3.Groups ?? []).filter((item) => item.Target === 'Parameter' && item.Name === name)
      .flatMap((item) => Array.isArray(item.Ids) ? item.Ids : []);
    const blink = group('EyeBlink'), lip = group('LipSync');
    model.fitParams({
      getEyeBlinkParameterCount: () => blink.length, getEyeBlinkParameterId: (i) => idManager.getId(blink[i]),
      getLipSyncParameterCount: () => lip.length, getLipSyncParameterId: (i) => idManager.getId(lip[i]),
    });
    const missing = [...model.missing];
    fail(missing.every((name) => Object.hasOwn(standard, name)), 'Stage returned an unknown semantic parameter');
    const bindings = {};
    for (const [name, domain] of Object.entries(standard)) {
      if (missing.includes(name)) continue;
      const link = model.alias.get(name);
      const targets = link ? [...link.ids] : [name];
      fail(targets.length > 0 && targets.every((id) => model.has(id)), 'Stage mapping targets do not exist in the measured model');
      const sample = (operation, value) => { calls = []; model[operation](name, value); return jsonCopy(calls); };
      bindings[name] = {
        targets: targets.map((id) => ({ id, measuredRange: jsonCopy(model.range(id)) })),
        scale: link?.scale ?? 1, offset: link?.offset ?? 0, standardDomain: [...domain],
        callsAtLow: sample('set', domain[0]), callsAtHigh: sample('set', domain[1]),
        callsAtZeroDelta: sample('add', 0),
      };
    }
    return { bindings, missing };
  }
  return Object.freeze({ replay, standard, stageSha256: sha256(stageSource),
    sourceSliceSha256: sha256(slice), sourceSlice: { startMarker, endMarker }, filename });
}

export function replayCorpus({ stagePath = DEFAULT_STAGE, expectedStageSha256 = defaultStageSha256 } = {}) {
  const { facts, sources } = loadPinnedCorpus();
  const stageBytes = readBounded(stagePath, 512 * 1024);
  const stage = createStageReplay(new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(stageBytes),
    String(stagePath), expectedStageSha256);
  const vocabulary = Object.keys(stage.standard);
  const rows = facts.models.map((row) => ({
    id: row.id, identity: row.identity, rawMocSha256: row.moc,
    historical: { coreLoaded: row.probe.loaded, mocVersion: row.mocVersion,
      measuredParameterCount: row.metadataFacts.parameterCount, measuredDrawableCount: row.probe.drawablesCount,
      distinctMaskSets: row.probe.distinctMaskSets, source: row.source },
    ...stage.replay(row.probe.parameters, row.model3),
    frameworkResourcesLoaded: false,
    verifiedEffects: { expressions: {}, motions: {} },
    visualAccuracy: null, frameRate: null, aiRequests: null, aiTokens: null,
  }));
  const mapped = rows.reduce((count, row) => count + Object.keys(row.bindings).length, 0);
  return {
    format: 'dsh-go/current-stage-metadata-replay-v1',
    artifactRole: 'developer report; not an adapter, runtime probe, or execution permission',
    historicalInput: { ...historicalPins, measuredAtUtc: facts.measuredAtUtc,
      method: facts.method, core: facts.core, fullProbeSha256: facts.compaction.fullProbeSha256,
      priorAppRuntimeMatch: sources.core.runtimeMatch },
    currentReplay: { stagePath: resolve(String(stagePath)), stageSha256: stage.stageSha256, expectedStageSha256,
      sourceSliceSha256: stage.sourceSliceSha256, sourceSlice: stage.sourceSlice,
      nodeVersion: process.version, methods: ['StageModel.fitParams', 'has', 'range', 'set', 'add'],
      metadataHarness: true, currentCoreMeasured: false, installedRuntimeDigestVerified: false,
      geometryReplayed: false, frameworkResourcesLoaded: false, rendererStarted: false,
      networkRequests: 0, appSourceModified: false },
    summary: { modelFingerprints: rows.length, identityFamilies: new Set(rows.map((row) => row.identity)).size,
      semanticParameters: vocabulary.length, mapped, possibleBindings: vocabulary.length * rows.length,
      ruleCoverage: mapped / (vocabulary.length * rows.length), unknownMappedIds: 0,
      verifiedEffectCount: 0, visualAccuracy: null, frameRate: null, aiRequests: null, aiTokens: null },
    definitions: {
      ruleCoverage: 'Current StageModel rule bindings divided by current STANDARD count times unique raw moc hashes. Coverage is not visual correctness.',
      calls: 'Arguments passed by current stage set/add to a metadata capture. No Core clamping, rendering or model playback was measured.',
      history: 'The historical Core load facts and prior App-runtime non-verification are preserved, not rerun or certified by this tool.',
      effects: 'Resource names/FileReferences alone authorize nothing. Historical Framework loading is unmeasured; all effect evidence is empty.',
    }, vocabulary, rows,
  };
}

function main(args) {
  let stagePath = DEFAULT_STAGE, expectedStageSha256 = defaultStageSha256, out;
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (!['--stage', '--expected-stage-sha256', '--out'].includes(arg) || !args[i + 1] || args[i + 1].startsWith('--')) {
      throw new Error('Usage: node tooling/companion/replay-model-corpus.mjs [--stage trusted-stage.js] [--expected-stage-sha256 reviewed-hash] [--out new-report.json]');
    }
    if (arg === '--stage') stagePath = args[++i];
    else if (arg === '--expected-stage-sha256') expectedStageSha256 = args[++i];
    else out = args[++i];
  }
  const report = replayCorpus({ stagePath, expectedStageSha256 });
  const json = JSON.stringify(report, null, 2) + '\n';
  if (out) {
    // Never overwrite a model, fixture, stage or previous measurement report.
    writeFileSync(out, json, { flag: 'wx' });
    process.stdout.write(JSON.stringify(report.summary, null, 2) + '\n');
  } else process.stdout.write(json);
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try { main(process.argv.slice(2)); }
  catch (error) { console.error(error.message); process.exitCode = 1; }
}
