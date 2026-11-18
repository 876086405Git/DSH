import assert from 'node:assert/strict';
import test from 'node:test';
import { registerHooks } from 'node:module';

const bashRoot = new URL('../../ohos/process/build/just-bash/', import.meta.url).href;
const loaded = [];
const hook = registerHooks({ load(url, context, nextLoad) {
  const result = nextLoad(url, context);
  if (url.startsWith(bashRoot)) loaded.push(url);
  return result;
} });
const { VirtualSubprocessRuntime } = await import('../../ohos/process/runtime.mjs');
const backendImports = [...loaded];

test('main-thread process backend import does not load the worker Bash bundle', () => {
  assert.equal(typeof VirtualSubprocessRuntime, 'function');
  assert.deepEqual(backendImports, []);
});

test('filesystem retains the same path helper functions used by the backend', async () => {
  const helpers = await import('../../ohos/process/paths.mjs');
  const filesystem = await import('../../ohos/process/filesystem.mjs');
  assert.equal(filesystem.isInside, helpers.isInside);
  assert.equal(filesystem.distinctRoots, helpers.distinctRoots);
  assert.equal(helpers.isInside('/工作区', '/工作区/中文.txt'), true);
  assert.equal(helpers.isInside('/工作区', '/工作区外/中文.txt'), false);
  assert.deepEqual(helpers.distinctRoots(['/工作区', '/工作区/子目录', '/临时', '/工作区']), ['/工作区', '/临时']);
  assert(loaded.length > 0, 'the filesystem consumer must still load its real Bash implementation');
  hook.deregister();
});
