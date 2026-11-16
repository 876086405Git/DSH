// Plain coordinator; only the two real service children use OH simulation.
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
const actor = fileURLToPath(new URL('./plugin-hmr-restart-actor.mjs', import.meta.url));
const preload = process.env.DSH_PLUGIN_SIM_PRELOAD ?? fileURLToPath(new URL('../../ohos/sim/preload.mjs', import.meta.url));
test('successful real HMR update keeps v1 until a fresh process boots and executes v2', { timeout: 60000 }, t => {
  const root = mkdtempSync(join(tmpdir(), 'plugin-hmr-parent-')), statePath = join(root, 'state.json');
  t.after(() => {
    if (existsSync(statePath)) rmSync(JSON.parse(readFileSync(statePath)).root, { recursive: true, force: true });
    rmSync(root, { recursive: true, force: true });
  });
  for (const mode of ['update', 'boot']) {
    const child = spawnSync(process.execPath, ['--jitless', '--import', preload, actor, mode], {
      env: { ...process.env, DSH_GO_OHOS_SIM_PLATFORM: 'openharmony', DSH_PLUGIN_HMR_STATE: statePath, DSH_PLUGIN_CONTRACT_REPORT: '' },
      encoding: 'utf8', timeout: 25000,
    });
    t.diagnostic(child.stdout);
    assert.equal(child.error, undefined); assert.equal(child.status, 0, child.stderr + child.stdout);
    assert(child.stdout.includes(mode === 'update' ? 'disk-v2-running-tool-v1' : 'fresh-process-real-boot-tool-v2'));
  }
});
