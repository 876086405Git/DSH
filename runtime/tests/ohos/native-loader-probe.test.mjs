// Integration regression: each case starts a real fixed Node binary and O0.
// The single allowed addon can be a Linux source rebuild in an explicitly
// simulated x64 fixture. Such a result does not validate the OHOS arm64 ABI.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { isAbsolute } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

function required(name) {
  const path = process.env[name];
  assert(path && isAbsolute(path) && existsSync(path), `${name} must be an existing absolute path`);
  return path;
}
const node = required('DSH_TEST_NODE');
const preload = required('DSH_TEST_O0_PRELOAD');
const prefix = required('DSH_TEST_NATIVE_PREFIX');
const addon = required('DSH_TEST_NATIVE_ADDON');
const probe = fileURLToPath(new URL('../../ohos/native/loader/probe.cjs', import.meta.url));
const environment = {
  ...process.env,
  NODE_OPTIONS: '',
  DSH_GO_OHOS_SIM: '1',
  DSH_GO_OHOS_SIM_PLATFORM: 'openharmony',
  DSH_GO_OHOS_SIM_ADDONS: JSON.stringify([addon]),
  NARB_DISABLE_NATIVE_CACHE: '1',
};
const cases = [
  { name: 'explicit jitless, original native route', flags: ['--jitless'], ok: true },
  { name: 'O0 deleting WebAssembly without jitless is insufficient', flags: [] },
  { name: 'hyphen expose-internals is rejected', flags: ['--jitless', '--expose-internals'] },
  { name: 'underscore expose_internals is rejected', flags: ['--jitless', '--expose_internals'] },
  { name: 'later no-jitless cannot override the required mode', flags: ['--jitless', '--no-jitless'] },
  { name: 'later nojitless alias cannot override the required mode', flags: ['--jitless', '--nojitless'] },
  { name: 'later no_jitless alias cannot override the required mode', flags: ['--jitless', '--no_jitless'] },
  { name: 'single-hyphen nojitless cannot override the required mode', flags: ['--jitless', '-nojitless'] },
  { name: 'single-hyphen no-jitless cannot override the required mode', flags: ['--jitless', '-no-jitless'] },
  { name: 'single-hyphen no_jitless cannot override the required mode', flags: ['--jitless', '-no_jitless'] },
];

for (const item of cases) test(item.name, () => {
  const result = spawnSync(node, [...item.flags, '--import', preload, probe, prefix], {
    env: environment, encoding: 'utf8', timeout: 10000,
  });
  assert.equal(result.error, undefined);
  assert.equal(result.signal, null);
  if (item.ok) {
    assert.equal(result.status, 0, result.stderr);
    const value = JSON.parse(result.stdout);
    assert.equal(value.status, 'NATIVE_MEMBERS_AVAILABLE');
    assert.equal(value.node, 'v24.22.1');
    assert.equal(value.noWasm, true);
    assert.equal(value.explicitJitless, true);
    assert.equal(value.publicInternalsExposed, false);
    assert.equal(value.binding.bindingPath, addon);
    assert(Object.values(value.members).every(type => type === 'function'));
  } else {
    // A Node parser exit is not accepted as proof of our startup guard.
    assert.equal(result.status, 1, result.stderr);
    assert.match(result.stderr, /ERR_OHOS_NATIVE_LOADER_CHECK/);
    assert.equal(result.stdout, '');
  }
});
