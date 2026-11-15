#!/usr/bin/env python3
# The loader the iOS runtime carries, as the specializer makes it from the shared one, run in
# Node against an app-shaped Frameworks folder with only process.dlopen stood in for. A phone
# found that a loader and an app that disagree about where the addons are means an engine that
# won't start, and nothing else catches that before a phone does.
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
LOADER = 'node_modules/@dsh-go/ohos-native/index.cjs'
spec = importlib.util.spec_from_file_location('specialize_runtime', Path(__file__).with_name('specialize-runtime.py'))
specializer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(specializer)

RUN = r'''
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const [root] = process.argv.slice(1);
const opened = [];
const loader = { exports: {} };
vm.runInNewContext(fs.readFileSync(0, 'utf8'), {
  require, module: loader,
  process: {
    platform: 'openharmony',
    env: { DSH_GO_OHOS_NATIVE_LIBRARY_DIR: root },
    dlopen(module, filename) { opened.push(filename); module.exports = { from: filename }; },
  },
});
const results = {};
for (const product of ['flock', 'require-builtin']) {
  try {
    const first = loader.exports.load(product);
    assert.strictEqual(loader.exports.load(product), first);
    results[product] = path.relative(fs.realpathSync(root), first.binding.from).split(path.sep).join('/');
  } catch (error) {
    results[product] = error.code;
  }
}
try { loader.exports.load('other'); } catch (error) { results.other = error.code; }
results.opened = opened.length;
process.stdout.write(JSON.stringify(results));
'''

FLOCK = 'DshFlock.framework/DshFlock'
REQUIRE = 'DshRequireBuiltin.framework/DshRequireBuiltin'


def ios_loader():
    shared = (ROOT / 'runtime/ohos/native/hap-loader/index.cjs').read_bytes()
    return specializer.diagnostics_for_ios(LOADER, shared)


def run(loader, files, links=()):
    with tempfile.TemporaryDirectory() as temp:
        root = Path(temp) / 'Frameworks'
        for name in files:
            (root / name).parent.mkdir(parents=True, exist_ok=True)
            (root / name).write_text('fixture, not a library')
        for name, target in links:
            (root / name).parent.mkdir(parents=True, exist_ok=True)
            os.symlink(target, root / name)
        root.mkdir(exist_ok=True)
        out = subprocess.run(['node', '-e', RUN, str(root)], input=loader, capture_output=True, check=True)
        return json.loads(out.stdout)


class IosNativeLoader(unittest.TestCase):
    def test_loads_each_addon_from_its_framework_once(self):
        result = run(ios_loader(), [FLOCK, REQUIRE])
        self.assertEqual(result, {'flock': FLOCK, 'require-builtin': REQUIRE,
                                  'other': 'ERR_OHOS_NATIVE_PRODUCT', 'opened': 2})

    def test_no_loose_library_is_looked_for(self):
        loader = ios_loader()
        self.assertNotIn(b'libdsh_flock.so', loader)
        self.assertNotIn(b'libdsh_require_builtin.so', loader)
        result = run(loader, ['libdsh_flock.so', 'libdsh_require_builtin.so'])
        self.assertEqual(result['flock'], 'ERR_OHOS_NATIVE_LIBRARY_PATH')
        self.assertEqual(result['opened'], 0)

    def test_a_missing_or_redirected_addon_is_refused(self):
        with tempfile.TemporaryDirectory() as outside:
            elsewhere = Path(outside) / 'DshFlock'
            elsewhere.write_text('fixture')
            result = run(ios_loader(), [REQUIRE], links=[(FLOCK, elsewhere)])
        self.assertEqual(result['flock'], 'ERR_OHOS_NATIVE_LIBRARY_PATH')
        self.assertEqual(result['require-builtin'], REQUIRE)
        self.assertEqual(run(ios_loader(), [FLOCK])['require-builtin'], 'ERR_OHOS_NATIVE_LIBRARY_PATH')

    def test_a_changed_shared_loader_stops_the_build(self):
        with self.assertRaises(ValueError):
            specializer.diagnostics_for_ios(LOADER, b"flock: 'something-else.so',")


if __name__ == '__main__':
    unittest.main()
