const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const native = require(process.argv[2]);
const base = fs.mkdtempSync(path.join(os.tmpdir(), 'guest-addon-resume-'));
const root = path.join(base, 'rootfs');
fs.mkdirSync(root);
const request = {
  root, cwd: '/workspace',
  workspace: '/synthetic/workspace', temporary: '/synthetic/temp',
  argv: ['/bin/true'], env: [], protectedPaths: ['/synthetic/private'],
  readOnly: true,
};
(async () => {
  for (let index = 0; index < 2; ++index) {
    const seen = [];
    const exit = await new Promise(resolve => {
      native.start(request, event => {
        seen.push(event.type);
        if (event.type === 'exit') resolve(event);
      });
    });
    assert.deepEqual(seen, ['exit']);
    assert.equal(exit.errorCode, 'ios_guest_suspended');
    assert.ok(exit.error > 0);
    assert.equal(exit.resourcesSettled, true);
    assert.equal(exit.abandoned, false);
    assert.equal(native.status().state, 'cold');
    assert.equal(fs.existsSync(path.join(base, 'active-task')), false);
  }
  console.log('PASS: real N-API adapter retains ios_guest_suspended after fsync failure and early resume, twice');
})().catch(error => { console.error(error); process.exitCode = 1; })
  .finally(() => fs.rmSync(base, { recursive: true, force: true }));
