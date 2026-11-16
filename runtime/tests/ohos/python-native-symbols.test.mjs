import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createPythonHost } from '../../ohos/python/host.mjs';

test('real unlinked CPython extension resolves PyList_New through the production native loader', { timeout: 10000 }, async () => {
  const root = mkdtempSync(join(tmpdir(), 'python-native-symbols-'));
  const config = JSON.parse(process.env.OHOS_PYTHON_HOST_CONFIG);
  const native = createPythonHost({ ...config, roots: [root] });
  try {
    for (let attempt = 0; attempt < 2; attempt++) {
      let stdout = '', stderr = '';
      const job = native.start({ argv: ['-c', 'import _dsh_link_probe\nprint(_dsh_link_probe.make_list())'],
        cwd: root, env: {}, stdout: bytes => { stdout += bytes; }, stderr: bytes => { stderr += bytes; } });
      const outcome = await job.completion;
      assert.equal(outcome.exitCode, 0, stderr);
      assert.equal(stdout, '[]\n');
    }
  } finally { await native.dispose(); rmSync(root, { recursive: true, force: true }); }
});
