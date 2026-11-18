// Prerequisites: install runtime/locks/dsh-0.2.2-rc.1 into a separate npm prefix
// with npm ci --ignore-scripts, then run rtbuild.py patch-dsh --target ohos
// --dsh-version 0.2.2-rc.1 --prefix PREFIX --target-report PREFIX/target-report.json.
// Build with runtime/ohos/process/build-just-bash.py and build-rg-regex.mjs,
// then set IOS_GUEST_TEST_PREFIX=PREFIX.
// This test uses the real generated overrides, parser, Worker, tool and approval
// services, but a recording native channel. It does not run iSH or Apple code.
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, realpathSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const repo = fileURLToPath(new URL('../../../', import.meta.url));
test('generated iOS overrides preserve real tool approval, tickets and Worker routing', t => {
  assert.ok(process.env.IOS_GUEST_TEST_PREFIX, 'Set IOS_GUEST_TEST_PREFIX to an isolated, OHOS-patched locked DSH prefix');
  // macOS aliases /var to /private/var. Match the canonical module URLs used
  // by Node so the inherited product preload passes its exact-path check.
  const temporary = realpathSync(mkdtempSync(join(tmpdir(), 'ios-guest-runtime-')));
  try {
    const fixture = join(temporary, 'runtime');
    execFileSync('python3', ['-I', '-B', join(repo, 'tooling/ios/tests/guest-runtime-fixture.py'),
      resolve(process.env.IOS_GUEST_TEST_PREFIX), fixture], { encoding: 'utf8' });
    const env = { ...process.env };
    delete env.NODE_TEST_CONTEXT; // The nested Node runner must actually execute its files.
    for (const flags of [[], ['--jitless']]) {
      const result = spawnSync(process.execPath, [...flags,
        '--import', join(repo, 'runtime/ohos/sim/marker.mjs'),
        '--import', join(fixture, 'runtime/ios/guest/overrides.mjs'),
        '--import', join(fixture, 'runtime/ohos/process/node-worker-preload.mjs'),
        '--test', '--test-reporter=tap', join(fixture, 'fixture.test.mjs'),
        join(fixture, 'root-grants-channel.test.mjs')], { encoding: 'utf8', timeout: 90000, env });
      t.diagnostic(`${flags.join(' ') || 'JIT'}\n${result.stdout}\n${result.stderr}`);
      assert.equal(result.error, undefined);
      assert.equal(result.status, 0, result.stdout + result.stderr);
      assert.match(result.stdout, /# tests 22\b/);
      assert.match(result.stdout, /# skipped 0\b/);
    }
  } finally {
    rmSync(temporary, { recursive: true, force: true });
  }
});
