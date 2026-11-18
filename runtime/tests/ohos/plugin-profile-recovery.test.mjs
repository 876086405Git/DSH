// Parent deliberately has no simulation preload: it owns real process-death actors.
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const actor = fileURLToPath(new URL('./plugin-profile-recovery-actor.mjs', import.meta.url));
const preload = process.env.DSH_PLUGIN_SIM_PRELOAD ?? fileURLToPath(new URL('../../ohos/sim/preload.mjs', import.meta.url));
function invoke(mode, statePath, prefix) {
  return spawnSync(process.execPath, ['--jitless', '--import', preload, actor, mode], {
    env: { ...process.env, DSH_PREFIX: prefix, DSH_GO_OHOS_SIM_PLATFORM: 'openharmony',
      DSH_PLUGIN_CRASH_STATE: statePath, DSH_PLUGIN_CONTRACT_REPORT: '' },
    encoding: 'utf8', timeout: 20000,
  });
}
for (const mode of ['directory-load', 'named-load', 'reset', 'active-read']) {
  test(`actual app boot ${mode} at an uncommitted manager publication`, { timeout: 50000 }, t => {
    const root = mkdtempSync(join(tmpdir(), 'plugin-recovery-parent-')), statePath = join(root, 'state.json');
    t.after(() => {
      if (existsSync(statePath)) rmSync(JSON.parse(readFileSync(statePath)).root, { recursive: true, force: true });
      rmSync(root, { recursive: true, force: true });
    });
    const stagePrefix = resolve(process.env.DSH_PLUGIN_STAGE_PREFIX ?? process.env.DSH_PREFIX);
    const staged = invoke(mode === 'active-read' ? mode : 'crash', statePath, stagePrefix);
    assert.equal(staged.error, undefined); assert.equal(staged.status, mode === 'active-read' ? 0 : 71, staged.stderr + staged.stdout);
    t.diagnostic(staged.stdout);
    if (mode === 'active-read') return;
    const loaded = invoke(mode, statePath, resolve(process.env.DSH_PREFIX));
    t.diagnostic(loaded.stdout);
    assert.equal(loaded.error, undefined); assert.equal(loaded.status, 0, loaded.stderr + loaded.stdout);
  });
}
