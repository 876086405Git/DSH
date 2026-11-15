#!/usr/bin/env python3
"""Run the Xcode embed phase with fixture compilers; this does not compile Apple code."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import zipfile


SCRIPT = Path(__file__).with_name('embed-engine.sh')
LOADER = 'files/node_modules/@dsh-go/ohos-native/index.cjs'


class GuestEmbedding(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'repository with spaces'
        self.engine = self.root / 'app/ios/Engine'
        scripts = self.root / 'tooling/ios'
        scripts.mkdir(parents=True)
        self.engine.mkdir(parents=True)
        shutil.copy2(SCRIPT, scripts / SCRIPT.name)
        (self.engine / '.ready').touch()
        with zipfile.ZipFile(self.engine / 'runtime.zip', 'w') as archive:
            archive.writestr(LOADER, "  flock: 'DshFlock.framework/DshFlock',\n"
                             "  'require-builtin': 'DshRequireBuiltin.framework/DshRequireBuiltin',\n")
        for path in ('runtime/ios/host/fixture.cc',
                     'runtime/ohos/host/publication_binding.cc',
                     'app/ohos/entry/src/main/cpp/host_core.cpp',
                     'app/ohos/entry/src/main/cpp/host_core.h'):
            file = self.root / path
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text('fixture\n')
        for name in ('actions.mjs', 'bridge.mjs', 'plugin.mjs', 'descriptions.mjs', 'catalog.json'):
            file = self.root / 'runtime/ios/phone' / name
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text('fixture\n')
        for slice_name in ('ios-arm64', 'ios-arm64-simulator'):
            framework = self.engine / 'NodeMobile.xcframework' / slice_name / 'NodeMobile.framework'
            framework.mkdir(parents=True)
            (framework / 'NodeMobile').write_text('fixture\n')
        (scripts / 'build-engine-native.sh').write_text('''#!/bin/bash
set -eu
for name in DshNodeHost DshFlock DshRequireBuiltin; do
  mkdir -p "$2/$name.framework"
  printf '%s' "$1" >"$2/$name.framework/$name"
done
''')
        (scripts / 'build-guest-addon.sh').write_text('''#!/bin/bash
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if [ -f "$ROOT/fail-guest" ]; then exit 23; fi
mkdir -p "$2/DshGuest.framework"
printf '%s' "$1" >"$2/DshGuest.framework/DshGuest"
printf 'fixture source notice' >"$2/DshGuest.framework/SOURCE.txt"
if [ -f "$ROOT/fail-addon" ]; then exit 24; fi
mkdir -p "$2/DshGuestBridge.framework"
printf '%s' "$1" >"$2/DshGuestBridge.framework/DshGuestBridge"
''')

    def run_embed(self, sdk='iphoneos'):
        target = self.root / 'products' / sdk
        env = os.environ.copy()
        env.update(SRCROOT=str(self.root / 'app/ios'), PLATFORM_NAME=sdk,
                   TARGET_BUILD_DIR=str(target), FRAMEWORKS_FOLDER_PATH='Runner.app/Frameworks',
                   UNLOCALIZED_RESOURCES_FOLDER_PATH='Runner.app', CODE_SIGNING_ALLOWED='NO')
        return subprocess.run(['sh', str(self.root / 'tooling/ios/embed-engine.sh')],
                              env=env, text=True, capture_output=True, timeout=20), target / 'Runner.app'

    def test_prepared_build_embeds_guest_for_both_sdks_and_removes_stale_content(self):
        for sdk in ('iphoneos', 'iphonesimulator'):
            with self.subTest(sdk=sdk):
                stale = self.root / 'products' / sdk / 'Runner.app/Frameworks/DshGuest.framework/old.node'
                stale.parent.mkdir(parents=True)
                stale.write_text('stale native code')
                stale_owner = stale.parent.parent / 'DshGuestBridge.framework/old.node'
                stale_owner.parent.mkdir(parents=True)
                stale_owner.write_text('stale owner code')
                result, app = self.run_embed(sdk)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                guest = app / 'Frameworks/DshGuest.framework'
                self.assertEqual((guest / 'DshGuest').read_text(), sdk)
                self.assertEqual((guest / 'SOURCE.txt').read_text(), 'fixture source notice')
                self.assertFalse(stale.exists())
                self.assertFalse(stale_owner.exists())
                owner = app / 'Frameworks/DshGuestBridge.framework/DshGuestBridge'
                self.assertEqual(owner.read_text(), sdk)
                self.assertTrue((app / 'dsh-runtime/runtime.zip').is_file())
                self.assertFalse((app / 'dsh-runtime/DshGuest').exists())

    def test_guest_compile_failure_stops_the_embed_phase(self):
        (self.root / 'fail-guest').touch()
        result, app = self.run_embed()
        self.assertEqual(result.returncode, 23, result.stdout + result.stderr)
        self.assertFalse((app / 'Frameworks/DshGuest.framework').exists())

    def test_addon_compile_failure_stops_before_copying_frameworks(self):
        (self.root / 'fail-addon').touch()
        result, app = self.run_embed()
        self.assertEqual(result.returncode, 24, result.stdout + result.stderr)
        self.assertFalse((app / 'Frameworks').exists())

    def test_remote_only_build_does_not_build_or_embed_a_guest(self):
        (self.engine / '.ready').unlink()
        (self.root / 'fail-guest').touch()
        result, app = self.run_embed()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('remote hosts only', result.stdout)
        self.assertFalse(app.exists())

    def test_incompatible_runtime_is_rejected_before_guest_build(self):
        with zipfile.ZipFile(self.engine / 'runtime.zip', 'w') as archive:
            archive.writestr(LOADER, "flock: 'libdsh_flock.so'")
        result, app = self.run_embed()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('incompatible addon layout', result.stderr)
        self.assertFalse((self.engine / 'build').exists())
        self.assertFalse(app.exists())


if __name__ == '__main__':
    unittest.main()
