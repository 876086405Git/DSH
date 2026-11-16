import { readFileSync, realpathSync } from 'node:fs';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { createRequire } from 'node:module';
import { createPythonHost } from './host.mjs';
import { createPythonRuntimeBackend } from '../process/python-backend.mjs';

/** Called once by the trusted OH command router after RuntimeInstaller is ready. */
export function loadPythonRuntime({ runtimeRoot, workspaceRoots, temporaryRoot, readOnly, createCollector }) {
  const directory = realpathSync(join(runtimeRoot, 'runtime/ohos/python/assets'));
  const manifest = JSON.parse(readFileSync(join(directory, 'manifest.json'), 'utf8'));
  if (manifest.schema !== 1 || manifest.pythonVersion !== '3.14.7' || !Array.isArray(manifest.files)) throw new Error('ERR_OHOS_PYTHON_MANIFEST');
  const paths = new Set();
  for (const row of manifest.files) {
    if (!/^[A-Za-z0-9_.-]+$/.test(row.path) || ['.', '..'].includes(row.path) || /\.(so|node|dll|dylib)(\.\d+)*$/i.test(row.path) || paths.has(row.path)) throw new Error('ERR_OHOS_PYTHON_MANIFEST_PATH');
    paths.add(row.path);
    const target = join(directory, row.path);
    if (realpathSync(target) !== target) throw new Error('ERR_OHOS_PYTHON_MANIFEST_LINK');
    const bytes = readFileSync(target);
    if (bytes.length !== row.size || createHash('sha256').update(bytes).digest('hex') !== row.sha256) throw new Error('ERR_OHOS_PYTHON_ASSET_HASH');
  }
  if (!paths.has('stdlib.zip') || !paths.has('ca.pem')) throw new Error('ERR_OHOS_PYTHON_ASSET_MISSING');
  const { path: addon, binding } = createRequire(import.meta.url)('@dsh-go/ohos-native').load('python');
  if (binding.pythonVersion !== manifest.pythonVersion) throw new Error('ERR_OHOS_PYTHON_VERSION');
  const native = createPythonHost({ addon, home: directory, paths: [join(directory, 'stdlib.zip')],
    roots: [...workspaceRoots, temporaryRoot], readOnly, caFile: join(directory, 'ca.pem') });
  return createPythonRuntimeBackend({ native, createCollector });
}
