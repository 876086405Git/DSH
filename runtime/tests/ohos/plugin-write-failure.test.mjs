// The plain Linux parent controls only its own strict OH simulation child.
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const actor = fileURLToPath(new URL('./plugin-write-failure-actor.mjs', import.meta.url));
const preload = process.env.DSH_PLUGIN_SIM_PRELOAD
  ?? fileURLToPath(new URL('../../ohos/sim/preload.mjs', import.meta.url));

for (const mode of ['manager-rollback', 'commit-marker']) {
  test(`actual EFBIG during ${mode} releases ownership for durable recovery`, { timeout: 30000 }, async t => {
    assert.equal(process.platform, 'linux', 'the kernel resource-limit fixture requires Linux');
    const child = spawn(process.execPath, ['--jitless', '--experimental-import-meta-resolve',
      '--import', preload, actor, mode], {
      env: { ...process.env, DSH_GO_OHOS_SIM_PLATFORM: 'openharmony', DSH_PLUGIN_CONTRACT_REPORT: '' },
      stdio: ['ignore', 'pipe', 'pipe', 'ipc'],
    });
    t.after(() => { if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL'); });
    let stdout = '', stderr = '', fixtureError;
    const facts = [];
    child.stdout.on('data', bytes => { stdout += bytes; });
    child.stderr.on('data', bytes => { stderr += bytes; });
    child.on('message', message => {
      facts.push(message);
      if (message.stage !== 'limit' && message.stage !== 'restore') return;
      try {
        execFileSync('prlimit', ['--pid', String(child.pid),
          message.stage === 'limit' ? '--fsize=0:unlimited' : '--fsize=unlimited:unlimited']);
        child.send({ stage: message.stage });
      } catch (error) {
        fixtureError = error;
        child.kill('SIGKILL');
      }
    });
    const exit = await new Promise((resolve, reject) => {
      child.once('error', reject);
      child.once('exit', (code, signal) => resolve({ code, signal }));
    });
    t.diagnostic(JSON.stringify(facts));
    assert.equal(fixtureError, undefined);
    assert.deepEqual(exit, { code: 0, signal: null }, stdout + stderr);
    const recovered = facts.find(message => message.stage === 'recovered');
    assert(recovered, 'the child must reach the actual successful retry');
    assert.equal(recovered.writesRestored, true);
    assert.equal(recovered.journalRemoved, true);
  });
}
