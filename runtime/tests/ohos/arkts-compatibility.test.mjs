// Narrow source contracts from the owner's SDK 26 compile findings (ADDENDUM 3).
// These are host AST/type checks, not an ArkTS compiler or a device test.
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { mkdtempSync, readFileSync, writeFileSync, mkdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const testsRoot = dirname(fileURLToPath(import.meta.url));
const repository = resolve(testsRoot, '../../..');
// Only for replaying these checks against an earlier, immutable product snapshot.
const product = resolve(process.env.OHOS_ARKTS_COMPATIBILITY_ROOT || repository);
const prefix = process.env.OHOS_TYPESCRIPT_PREFIX;
assert.ok(prefix, 'OHOS_TYPESCRIPT_PREFIX is required');
const require = createRequire(import.meta.url);
const ts = require(join(prefix, 'node_modules/typescript'));
assert.match(ts.version, /^5\.9\./, 'Use the TypeScript 5.9 series; record the observed version separately');

function source(relative) {
  return ts.createSourceFile(relative, readFileSync(join(product, relative), 'utf8'),
    ts.ScriptTarget.ES2022, true, ts.ScriptKind.TS);
}

function nodes(root, predicate) {
  const found = [];
  function visit(node) {
    if (predicate(node)) found.push(node);
    ts.forEachChild(node, visit);
  }
  visit(root);
  return found;
}

function unparenthesized(node) {
  while (ts.isParenthesizedExpression(node)) node = node.expression;
  return node;
}

test('diagnostic evidence uses explicitly typed indexed loops', () => {
  const file = source('app/ohos/entry/src/main/ets/plugins/OhosDiagnosticEvidence.ets');
  assert.equal(nodes(file, ts.isForOfStatement).length, 0,
    'SDK 26 owner finding: avoid inferred for-of binding types in this store');
  const loops = nodes(file, ts.isForStatement);
  assert.equal(loops.length, 4, 'All four former iteration sites remain present');
  for (const loop of loops) {
    assert.ok(loop.initializer && ts.isVariableDeclarationList(loop.initializer));
    for (const variable of loop.initializer.declarations) {
      assert.equal(variable.type?.kind, ts.SyntaxKind.NumberKeyword, 'Index type must be explicit');
    }
    const bindings = nodes(loop.statement, node => ts.isVariableDeclaration(node) &&
      node.initializer && ts.isElementAccessExpression(node.initializer));
    assert.ok(bindings.length > 0, 'An indexed item binding must be retained');
    assert.ok(bindings.every(binding => binding.type), 'Indexed item types must be explicit');
  }
});

test('media close gives the preparation callback an explicit Error', () => {
  const file = source('app/ohos/entry/src/main/ets/plugins/OhosMediaVideo.ets');
  const close = nodes(file, node => ts.isMethodDeclaration(node) && node.name.getText(file) === 'close');
  assert.equal(close.length, 1);
  const calls = nodes(close[0], node => ts.isCallExpression(node) &&
    ts.isPropertyAccessExpression(node.expression) && node.expression.name.text === 'cancelPreparation');
  assert.equal(calls.length, 1);
  const argument = unparenthesized(calls[0].arguments[0]);
  assert.ok(ts.isAsExpression(argument), 'SDK owner finding: explicit cast at the callback boundary');
  assert.equal(argument.type.getText(file), 'Error');
});

test('widget store static cache is accessed through the class', () => {
  const file = source('app/ohos/entry/src/main/ets/companion/CompanionWidgetStore.ets');
  const at = nodes(file, node => ts.isMethodDeclaration(node) && node.name.getText(file) === 'at');
  assert.equal(at.length, 1);
  const accesses = nodes(at[0], node => ts.isPropertyAccessExpression(node) && node.name.text === 'stores');
  assert.equal(accesses.length, 2);
  for (const access of accesses) {
    assert.equal(access.expression.getText(file), 'CompanionWidgetStore',
      'SDK owner finding: static this is not supported here');
  }
});

test('keyboard source typechecks with required AvoidArea.visible and keeps four rectangle JSON', () => {
  const stage = mkdtempSync(join(tmpdir(), 'dsh-arkts-compatibility-'));
  try {
    const name = 'app/ohos/entry/src/main/ets/plugins/OhosKeyboardLog.ets';
    writeFileSync(join(stage, 'OhosKeyboardLog.ts'), readFileSync(join(product, name)));
    for (const fixture of ['diagnostic-evidence-host.d.ts', 'keyboard-geometry-host.d.ts']) {
      writeFileSync(join(stage, fixture), readFileSync(join(testsRoot, fixture)));
    }
    mkdirSync(join(stage, 'empty-types'));
    const program = ts.createProgram({
      rootNames: [join(stage, 'OhosKeyboardLog.ts'), join(stage, 'diagnostic-evidence-host.d.ts'),
        join(stage, 'keyboard-geometry-host.d.ts')],
      options: { strict: true, noEmit: true, target: ts.ScriptTarget.ES2022,
        module: ts.ModuleKind.CommonJS, lib: ['lib.es2022.d.ts'], typeRoots: [join(stage, 'empty-types')] },
    });
    const diagnostics = ts.getPreEmitDiagnostics(program);
    assert.equal(diagnostics.length, 0, ts.formatDiagnostics(diagnostics, {
      getCanonicalFileName: value => value, getCurrentDirectory: () => stage, getNewLine: () => '\n',
    }));
    const file = source(name);
    const local = nodes(file, node => ts.isInterfaceDeclaration(node) && node.name.text === 'KeyboardAvoidRects');
    assert.equal(local.length, 1);
    assert.deepEqual(local[0].members.map(member => member.name.getText(file)).sort(),
      ['bottomRect', 'leftRect', 'rightRect', 'topRect']);
    const clean = nodes(file, node => ts.isVariableDeclaration(node) && node.name.getText(file) === 'clean' &&
      node.initializer && ts.isObjectLiteralExpression(node.initializer) &&
      node.initializer.properties.some(property => property.name?.getText(file) === 'leftRect'));
    assert.equal(clean.length, 1);
    assert.equal(clean[0].type?.getText(file), 'KeyboardAvoidRects');
    assert.deepEqual(clean[0].initializer.properties.map(property => property.name.getText(file)).sort(),
      ['bottomRect', 'leftRect', 'rightRect', 'topRect']);
  } finally {
    rmSync(stage, { recursive: true, force: true });
  }
});

test('speech upper retains distinct recorded 1306 and 1317 source contexts', () => {
  const contexts = JSON.parse(readFileSync(join(product, 'runtime/tests/ohos/speech-upper/source-contexts.json'), 'utf8'));
  const voice = 'app/lib/companion/companion_voice_source.dart';
  const diagnostics = 'app/lib/diagnostics/diagnostics_channel.dart';
  assert.deepEqual(contexts['1306'], {
    [voice]: 'cc9924c384708d37787b66a5f093ae55854252ad274e8060ba1589d20bae7562',
    [diagnostics]: '0680013a0bab6859fb91a52df5a9ffa4586978cf0e12baae7327f97440531df7',
  });
  assert.deepEqual(contexts['1317'], {
    [voice]: 'cc9924c384708d37787b66a5f093ae55854252ad274e8060ba1589d20bae7562',
    [diagnostics]: '0ddc68345c6b271f63af885443bac7ac30963349c6626eb137b59b147219a384',
  });
  assert.ok(contexts.a836 && contexts.b452, 'Earlier recorded contexts stay available');
});

test('independent runtime-channel EntryAbility fixture includes its four existing plugin stubs', () => {
  const text = readFileSync(join(product, 'tooling/ohos/tests/runtime-channel.test.mjs'), 'utf8');
  for (const name of ['CompanionVoicePlugin', 'StreamingAsrPlugin', 'MediaVideoPlugin', 'PictureShortcutPlugin']) {
    assert.match(text, new RegExp('const\\s+' + name + '\\s*=\\s*\\{'),
      'This independent EntryAbility fixture must declare ' + name);
  }
});
