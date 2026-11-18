#!/usr/bin/env python3
"""Installed-path contracts; fixtures are not an ohpm install or compilation."""
import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest


HELPER = Path(__file__).resolve().parents[1] / 'prepare-forks.py'
SPEC = importlib.util.spec_from_file_location('prepare_forks', HELPER)
FORKS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FORKS)
PAYLOAD = b'Pinned native target fixture, not ArkTS.\n'
PACKAGE = 'webview_flutter_ohos'
TARGET = 'src/main/ets/Target.ets'
ENTRIES = {PACKAGE: {'nativePackage': PACKAGE, 'nativeSubdir': 'ohos',
                     'targets': {'ohos/' + TARGET: {
                         'afterSha256': hashlib.sha256(PAYLOAD).hexdigest()}}}}


class InstalledPaths(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='installed-fork-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.project = self.root / 'ohos'
        (self.project / 'entry').mkdir(parents=True)

    def package(self, path, payload=PAYLOAD):
        (path / TARGET).parent.mkdir(parents=True)
        (path / TARGET).write_bytes(payload)
        (path / 'oh-package.json5').write_text('{"name":"' + PACKAGE + '"}')
        return path

    def verify(self):
        return FORKS.verify_installed(self.project, ENTRIES)

    def test_project_level_install_is_selected(self):
        native = self.package(self.project / 'oh_modules' / PACKAGE)
        self.assertEqual(self.verify()[0]['target'], str(native / TARGET))

    def test_module_alias_resolves_to_ohpm_store(self):
        native = self.package(self.project / 'oh_modules/.ohpm/pinned/oh_modules' / PACKAGE)
        alias = self.project / 'entry/oh_modules' / PACKAGE
        alias.parent.mkdir(parents=True)
        alias.symlink_to(native, target_is_directory=True)
        self.assertEqual(self.verify()[0]['target'], str(native / TARGET))

    def test_first_alias_cannot_be_bypassed_by_a_matching_copy(self):
        selected = self.package(self.project / 'entry/oh_modules' / PACKAGE, b'old native code')
        self.package(self.project / 'oh_modules' / PACKAGE)
        with self.assertRaisesRegex(ValueError, 'installed native target SHA256 mismatch') as caught:
            self.verify()
        self.assertIn(str(selected / TARGET), str(caught.exception))

    def test_dangling_alias_does_not_hide_parent_install(self):
        alias = self.project / 'entry/oh_modules' / PACKAGE
        alias.parent.mkdir(parents=True)
        alias.symlink_to(self.root / 'missing', target_is_directory=True)
        native = self.package(self.project / 'oh_modules' / PACKAGE)
        self.assertEqual(self.verify()[0]['target'], str(native / TARGET))

    def test_missing_install_explains_search_and_remedy(self):
        with self.assertRaisesRegex(ValueError, 'native plugin was not installed') as caught:
            self.verify()
        self.assertIn('ohpm install', str(caught.exception))
        self.assertIn(str(self.project / 'entry/oh_modules' / PACKAGE), str(caught.exception))

    def test_unavailable_selected_target_is_not_another_version(self):
        selected = self.package(self.project / 'entry/oh_modules' / PACKAGE)
        (selected / TARGET).unlink()
        self.package(self.project / 'oh_modules' / PACKAGE)
        with self.assertRaisesRegex(ValueError, 'installed native target unavailable') as caught:
            self.verify()
        self.assertIn(str(selected), str(caught.exception))


if __name__ == '__main__':
    unittest.main(verbosity=2)
