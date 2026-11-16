import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdirSync, mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { createHash } from 'node:crypto';
import { loadPythonRuntime } from '../../ohos/python/loader.mjs';

test('loader verifies installed asset hashes before native loading', () => {
  const root = mkdtempSync(join(tmpdir(), 'python-loader-'));
  try {
    const dir = join(root, 'runtime/ohos/python/assets'); mkdirSync(dir, { recursive: true });
    const rows = ['stdlib.zip', 'ca.pem'].map(path => {
      writeFileSync(join(dir, path), 'expected');
      return { path, size: 8, sha256: createHash('sha256').update('expected').digest('hex') };
    });
    const manifest = { schema: 1, pythonVersion: '3.14.7', files: rows };
    writeFileSync(join(dir, 'manifest.json'), JSON.stringify(manifest));
    writeFileSync(join(dir, 'stdlib.zip'), 'tampered');
    assert.throws(() => loadPythonRuntime({ runtimeRoot: root }), /ERR_OHOS_PYTHON_ASSET_HASH/);
    manifest.files = [{ path: '../outside', size: 0, sha256: '' }];
    writeFileSync(join(dir, 'manifest.json'), JSON.stringify(manifest));
    assert.throws(() => loadPythonRuntime({ runtimeRoot: root }), /ERR_OHOS_PYTHON_MANIFEST_PATH/);
    manifest.files = [{ path: 'native.so', size: 0, sha256: '' }];
    writeFileSync(join(dir, 'manifest.json'), JSON.stringify(manifest));
    assert.throws(() => loadPythonRuntime({ runtimeRoot: root }), /ERR_OHOS_PYTHON_MANIFEST_PATH/);
  } finally { rmSync(root, { recursive: true }); }
});
