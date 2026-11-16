import test from 'node:test';
import assert from 'node:assert/strict';
import { witnessCommands, validateWitnessResult, compareWitnessResults } from './guest-witness.mjs';

// Synthetic records exercise the evidence validator, never guest execution.
function fixture(phase) {
  const { expected } = witnessCommands({ phase })[0];
  const device = { major: 253, minor: phase === 'write' ? 32 : 0 };
  const metadata = (path, uid, gid, mode, inode) => ({ path, uid, gid, mode, inode,
    mtimeNs: '1794135000123456789', device: { ...device } });
  const file = (name, uid, gid, inode) => ({ ...metadata(expected[name].path, uid, gid, expected[name].mode, inode),
    bytes: expected[name].bytes, sha256: expected[name].sha256 });
  return {
    v: 1, phase, uid: 60081, gid: 60081, pythonVersion: 'synthetic-version',
    uname: { system: 'Linux', nodeName: 'synthetic', release: 'synthetic-kernel', version: 'fixture', machine: 'riscv64' },
    root: metadata('/', 0, 0, '0o755', 2),
    rootMounts: [{ source: expected.targetDevice, target: '/', type: 'ext4', options: ['rw', 'relatime'],
      raw: expected.targetDevice + ' / ext4 rw,relatime 0 0' }],
    targetDevice: { path: expected.targetDevice, isBlock: true, ...device },
    workspace: metadata('/workspace', 60081, 60081, '0o700', 100),
    configDirectory: metadata('/workspace/.config/dsh931', 60081, 60081, '0o700', 101),
    agent: file('agent', 0, 0, 200), init: file('init', 0, 0, 201),
    data: file('data', 60081, 60081, 102), config: file('config', 60081, 60081, 103),
  };
}
const rejected = call => assert.throws(call, { code: 'ERR_OHOS_LINUX_RESUME_WITNESS' });

test('the command factory admits only the two fixed guest phases', () => {
  for (const phase of ['write', 'read']) {
    const commands = witnessCommands({ phase }); assert.equal(commands.length, 1);
    const command = commands[0]; assert.equal(command.cwd, '/workspace');
    assert.deepEqual([command.argv[0], command.argv[1], command.argv[3]], ['python3', '-c', phase]);
    assert.equal(command.argv.length, 4); assert.equal(command.expected.phase, phase);
    assert.ok(Object.isFrozen(command.argv));
  }
  for (const phase of [undefined, '', 'write;sync', 'resume']) rejected(() => witnessCommands({ phase }));
});

test('synthetic paired records preserve bytes and file identities across changed drive numbering', () => {
  const write = validateWitnessResult({ phase: 'write', stdout: Buffer.from(JSON.stringify(fixture('write')) + '\n') });
  const read = validateWitnessResult({ phase: 'read', stdout: JSON.stringify(fixture('read')) });
  const result = compareWitnessResults(write, read);
  assert.equal(result.dataPreserved, true); assert.equal(result.configPreserved, true);
  assert.deepEqual(result.rootDevices, ['/dev/vdc', '/dev/vda']);
  assert.equal(result.kernelRelease, 'synthetic-kernel');
});

test('a bootstrap root cannot be mistaken for the intended writable target', () => {
  const record = fixture('write'); record.root.device.minor = 0;
  rejected(() => validateWitnessResult({ phase: 'write', stdout: record }));
});

test('workspace bytes on another filesystem are outside the claimed root sync scope', () => {
  for (const name of ['workspace', 'configDirectory', 'data', 'config']) {
    const record = fixture('read'); record[name].device = { major: 0, minor: 44 };
    rejected(() => validateWitnessResult({ phase: 'read', stdout: record }));
  }
});

test('the kernel root alias requires the actual target block identity and writable ext4 observation', () => {
  const record = fixture('read'); record.rootMounts[0].source = '/dev/root';
  record.rootMounts[0].raw = '/dev/root / ext4 rw,relatime 0 0';
  assert.equal(validateWitnessResult({ phase: 'read', stdout: record }), record);
  record.targetDevice.isBlock = false; rejected(() => validateWitnessResult({ phase: 'read', stdout: record }));
  record.targetDevice.isBlock = true; record.rootMounts[0].options = ['ro'];
  rejected(() => validateWitnessResult({ phase: 'read', stdout: record }));
});

test('source identity, actual guest UID and root/workspace permissions are mandatory', () => {
  const mutations = [
    record => { record.agent.sha256 = '0'.repeat(64); },
    record => { record.init.sha256 = '0'.repeat(64); },
    record => { record.uid = 0; },
    record => { record.root.mode = '0o777'; },
    record => { record.workspace.uid = 0; },
    record => { record.workspace.mode = '0o777'; },
    record => { record.data.sha256 = '0'.repeat(64); },
    record => { record.config.bytes++; },
  ];
  for (const mutate of mutations) {
    const record = fixture('read'); mutate(record);
    rejected(() => validateWitnessResult({ phase: 'read', stdout: record }));
  }
});

test('matching bytes alone cannot hide a replaced file or changed persistence metadata', () => {
  const write = fixture('write');
  for (const [name, field, value] of [
    ['data', 'inode', 999], ['data', 'mtimeNs', '1794135000123456790'],
    ['config', 'inode', 998], ['configDirectory', 'inode', 997],
  ]) {
    const read = fixture('read'); read[name][field] = value;
    assert.equal(validateWitnessResult({ phase: 'read', stdout: read }), read);
    rejected(() => compareWitnessResults(write, read));
  }
});

test('malformed, mixed or overlarge stdout cannot create a witness record', () => {
  for (const stdout of [null, [], 'boot text\n{}', '{', 'x'.repeat(65537), Buffer.from([0xff])])
    rejected(() => validateWitnessResult({ phase: 'write', stdout }));
  rejected(() => validateWitnessResult({ phase: 'read', stdout: fixture('write') }));
});
