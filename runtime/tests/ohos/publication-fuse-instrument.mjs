// Explicit test-only pre-import. Production never consumes this configuration.
import * as fs from 'node:fs';
import * as promises from 'node:fs/promises';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { syncBuiltinESMExports } from 'node:module';

const config = JSON.parse(fs.readFileSync(process.env.M6_FUSE_TEST_CONFIG, 'utf8'));
const hash = value => createHash('sha256').update(value).digest('hex');
const send = value => fs.writeSync(1, JSON.stringify(value) + '\n');
const statePath = join(config.home, 'ohos-ownership', 'atomic-state.json');
function state() {
  try {
    const bytes = fs.readFileSync(statePath), info = fs.statSync(statePath, { bigint: true });
    return { value: JSON.parse(bytes), sha256: hash(bytes), dev: String(info.dev), ino: String(info.ino),
      mtimeNs: String(info.mtimeNs), ctimeNs: String(info.ctimeNs) };
  } catch (error) {
    if (error.code === 'ENOENT') return null;
    throw error;
  }
}
const observed = { wrapperCalls: 0, realNativeCalls: 0, state,
  get versionFixture() { return config.versionFixture ?? null; } };
Object.defineProperty(globalThis, Symbol.for('dsh.go.ohos.fuse.test'), { value: observed });
function gate(phase, source, target, input) {
  send({ type: 'gate', phase, source, target, state: state(),
    wrapperCalls: observed.wrapperCalls, realNativeCalls: observed.realNativeCalls, input });
  // Synchronous, inside the native wrapper: no timer or Promise may run between
  // the production identity check and the real rename, even in this fixture.
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0);
  throw new Error('test gate unexpectedly resumed');
}
const original = process._linkedBinding;
let recordedNativeIdentity = false;
process._linkedBinding = function(name) {
  const binding = Reflect.apply(original, this, [name]);
  if (name !== 'dsh_ohos_publication') return binding;
  if (!recordedNativeIdentity) {
    recordedNativeIdentity = true;
    send({ type: 'native-system-build-identity', available: typeof binding.getSystemBuildIdentity === 'function',
      value: typeof binding.getSystemBuildIdentity === 'function' ? binding.getSystemBuildIdentity() : null,
      source: 'unwrapped Linux linked test fixture; distinct from the A/B input override' });
  }
  const wrapped = { ...binding, renameNoReplace(source, target) {
    observed.wrapperCalls++;
    const bytes = fs.readFileSync(source), input = { bytes: bytes.length, sha256: hash(bytes) };
    send({ type: 'native-entry', source, target, state: state(), call: observed.wrapperCalls, input });
    if (config.stop === 'before-native' && observed.wrapperCalls === 1) gate(config.stop, source, target, input);
    if (config.injectNativeError) {
      throw Object.assign(new Error(`explicit test injection: ${config.injectNativeError}`),
        { code: config.injectNativeError, errno: -22, syscall: 'renameat2' });
    }
    observed.realNativeCalls++;
    const result = binding.renameNoReplace(source, target);
    if (config.stop === 'after-native-success' && observed.wrapperCalls === 1) gate(config.stop, source, target, input);
    return result;
  } };
  if (config.versionBindingMember) {
    wrapped[config.versionBindingMember] = () => structuredClone(config.versionFixture);
  }
  return wrapped;
};
if (config.mode === 'jit') {
  // The real provider chooses its outer OH path by process.platform. A marker
  // alone installs the service but does not select that provider branch.
  Object.defineProperty(process, 'platform', { value: 'openharmony' });
  // A normal Linux hard link succeeds and would never reach rename. Only the
  // JIT comparison injects this one fallback prerequisite; strict O0 does it.
  const denied = async () => { throw Object.assign(new Error('explicit test link prerequisite'), { code: 'EACCES' }); };
  promises.default.link = denied;
  syncBuiltinESMExports();
}
send({ type: 'test-instrument', platform: process.platform, jit: !process.execArgv.includes('--jitless'), versionBindingMember: config.versionBindingMember ?? null,
  versionFixture: config.versionFixture ?? null, linkPrerequisite: config.mode === 'jit' ? 'injected-EACCES' : 'strict-O0' });
