// Linux-only /proc observations; production addon and real Worker termination.
// The kernel is a synthetic initialize barrier, not real iSH or Apple execution.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { Worker, isMainThread, parentPort, workerData } = require('node:worker_threads');
const { once } = require('node:events');

function request(data, identity) {
  return { root: data.root, workspace: data.work, temporary: data.tmp, protectedPaths: [],
    argv: ['/bin/sh', '-c', 'true'], env: [], cwd: '/workspace', readOnly: false,
    rootWritable: true, ...identity };
}
if (!isMainThread) {
  const native = require(workerData.addon);
  const original = fs.lstatSync(workerData.root, { bigint: true });
  const expected = { expectedRootDevice: String(original.dev), expectedRootInode: String(original.ino) };
  assert.throws(() => native.start(request(workerData, expected), () => {}), /no matching retained identity/);
  for (const name of ['missing', 'file', 'link']) {
    assert.throws(() => native.rootIdentity(path.join(workerData.base, name)), { code: 'ERR_IOS_GUEST_NATIVE' });
  }
  const identity = native.rootIdentity(workerData.root);
  assert.deepEqual(identity, expected);
  assert.deepEqual(native.rootIdentity(workerData.root), identity);
  assert.throws(() => native.rootIdentity(workerData.work), /cannot be replaced/);
  assert.throws(() => native.start(request(workerData, { ...identity, expectedRootInode: '0' }), () => {}), /no matching retained identity/);
  parentPort.postMessage({ type: 'pinned', identity });
  parentPort.on('message', value => {
    if (value === 'start') native.start(request(workerData, identity), () => {});
  });
} else {
  const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
  async function until(check, label) {
    const deadline = Date.now() + 5000;
    while (!check()) {
      if (Date.now() >= deadline) throw new Error('timeout: ' + label);
      await sleep(5);
    }
  }
  function count(identity) {
    return fs.readdirSync('/proc/self/fd').filter(name => {
      try {
        const stat = fs.fstatSync(Number(name), { bigint: true });
        return String(stat.dev) === identity.expectedRootDevice && String(stat.ino) === identity.expectedRootInode;
      } catch { return false; }
    }).length;
  }
  async function run(active) {
    const base = fs.mkdtempSync(path.join(os.tmpdir(), 'root-identity-'));
    const data = { base, addon: path.resolve(process.argv[2]), root: path.join(base, 'rootfs'),
      work: path.join(base, 'work'), tmp: path.join(base, 'tmp') };
    for (const name of ['rootfs', 'work', 'tmp', 'control']) fs.mkdirSync(path.join(base, name));
    fs.writeFileSync(path.join(base, 'file'), 'synthetic');
    fs.symlinkSync(data.root, path.join(base, 'link'));
    const worker = new Worker(__filename, { workerData: data, trackUnmanagedFds: false });
    let identity;
    try {
      const [message] = await once(worker, 'message');
      assert.equal(message.type, 'pinned'); identity = message.identity;
      assert.equal(count(identity), 1, 'exactly one retained directory FD after failures and repeated pin');
      if (active) {
        worker.postMessage('start');
        await until(() => fs.existsSync(path.join(base, 'control/entered')), 'coordinator enters initialize');
      }
      const start = Date.now();
      await worker.terminate();
      assert.ok(Date.now() - start < 2000, 'native initialize must not block Worker termination');
      if (active) {
        assert.equal(count(identity), 1, 'coordinator still holds Owner after Env teardown');
        for (let i = 0; i < 32; i++) {
          fs.rmSync(data.root, { recursive: true }); fs.mkdirSync(data.root);
          assert.notEqual(String(fs.lstatSync(data.root, { bigint: true }).ino), identity.expectedRootInode,
            'held inode cannot be reused for a replacement installation');
        }
        fs.writeFileSync(path.join(base, 'control/release'), 'release synthetic initialize');
      }
      await until(() => count(identity) === 0, 'last Owner reference closes its native FD');
      console.log('PASS', active ? 'active coordinator retains identity through forced Env teardown, then releases it' :
        'idle Env teardown releases identity with unmanaged-fd tracking disabled');
    } finally {
      fs.writeFileSync(path.join(base, 'control/release'), 'cleanup');
      await worker.terminate();
      if (identity) await until(() => count(identity) === 0, 'fixture cleanup');
      fs.rmSync(base, { recursive: true });
    }
  }
  (async () => { await run(false); await run(true); })().catch(error => { console.error(error); process.exitCode = 1; });
}
