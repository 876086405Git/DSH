import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { assertEntryAbilityImports, createEntryAbilityImports } from './entry-ability-fixture.mjs';

const source = readFileSync(new URL('../../../app/ohos/entry/src/main/ets/entryability/EntryAbility.ets', import.meta.url), 'utf8');

test('shared Entry fixture covers the complete actual product import set', () => {
  assert.doesNotThrow(() => assertEntryAbilityImports(source));
});
test('unknown relative Entry import is rejected rather than silently stubbed', () => {
  assert.throws(() => assertEntryAbilityImports(source.replace("'../plugins/PastePlugin'", "'../plugins/UnknownPlugin'")), /Unregistered EntryAbility import/);
  assert.throws(() => createEntryAbilityImports()('../plugins/UnknownPlugin'), /Unregistered EntryAbility import/);
});
test('unknown named Entry export is rejected in source and at the stub boundary', () => {
  assert.throws(() => assertEntryAbilityImports(source.replace('{ NativeVoiceStopControl }', '{ UnregisteredStopControl }')), /Unregistered EntryAbility exports/);
  assert.throws(() => createEntryAbilityImports()('../plugins/NativeVoiceStopControl').UnregisteredStopControl, /Unregistered EntryAbility export/);
});
test('explicit real target override remains lazy and preserves its module identity', () => {
  let loads = 0;
  const actual = { default: class ActualUsage {} };
  const resolve = createEntryAbilityImports({ '../plugins/UsagePlugin': () => { loads++; return actual; } });
  assert.equal(loads, 0);
  assert.strictEqual(resolve('../plugins/UsagePlugin'), actual);
  assert.equal(loads, 1);
  assert.throws(() => createEntryAbilityImports({ '../plugins/UnknownPlugin': () => actual }), /Unregistered EntryAbility override/);
});
test('NativeHost must have an explicit per-consumer boundary', () => {
  assert.throws(() => createEntryAbilityImports()('../runtime/NativeHost'), /requires explicit boundary/);
});

test('side-effect and multiline Entry imports fail closed before import stripping', () => {
  assert.throws(() => assertEntryAbilityImports(source + "\nimport '../plugins/UnknownPlugin';\n"), /Unsupported EntryAbility import syntax/);
  assert.throws(() => assertEntryAbilityImports(source + "\nimport {\n  UnknownPlugin\n} from '../plugins/UnknownPlugin';\n"), /Unsupported EntryAbility import syntax/);
});
test('namespace and mixed Entry bindings are not accepted as default imports', () => {
  for (const binding of ['* as PastePlugin', 'PastePlugin, { other }']) {
    assert.throws(() => assertEntryAbilityImports(source.replace('import PastePlugin from', 'import ' + binding + ' from')), /Unsupported EntryAbility import binding/);
  }
});
