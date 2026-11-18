// Linux executes the exact manifest validator after type erasure, not Ark bytecode.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import { resolve } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const repo = process.env.OHOS_REQUIREMENTS_TREE || fileURLToPath(new URL('../../..', import.meta.url));
const host = await readFile(resolve(repo, 'app/ohos/entry/src/main/cpp/host_core.cpp'), 'utf8');
const calls = [...host.matchAll(/\bFile\s*\(\s*options\.runtime_root\s*,/g)];
const entries = [...host.matchAll(/\bFile\s*\(\s*options\.runtime_root\s*,\s*"([^"\n]+)"\s*\)/g)].map(match => match[1]);
assert(entries.length > 0);
assert.equal(calls.length, entries.length, 'Every Host runtime File call must remain visible to this gate');
const required = [...new Set(entries)].sort();
const source = await readFile(resolve(repo, 'app/ohos/entry/src/main/ets/runtime/RuntimeCore.ets'), 'utf8');
const match = /for \(const entry of \[([^\]]+)\]\)/.exec(source);
const declared = match ? [...match[1].matchAll(/'([^']+)'/g)].map(value => value[1]).sort() : [];
const code = stripTypeScriptTypes(source, { mode: 'strip' });
const { validateManifest } = await import(`data:text/javascript;base64,${Buffer.from(code).toString('base64')}`);
const manifest = { schema: 1, runtimeVersion: 'fixture', dshVersion: '0.2.1-rc.4', nodeVersion: '24.22.1',
  files: required.map(path => ({ path, size: 0, sha256: 'a'.repeat(64) })) };

test('Host::Start requirements and installer declarations are the same set', () => {
  assert.deepEqual(declared, required);
  assert.equal(validateManifest(manifest), manifest);
});

for (const entry of required) {
  test(`actual installer refuses a manifest missing ${entry}`, () => {
    assert.throws(() => validateManifest({ ...manifest, files: manifest.files.filter(file => file.path !== entry) }),
      { code: 'ohos_manifest_invalid' });
  });
}
