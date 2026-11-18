#!/usr/bin/env python3
"""Real CLI checks against the fixed fork. Set DSH_WEBVIEW_FORK; no downloads.

Native installation here is a filesystem fixture, not an OHOS compilation.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


HELPER = Path(__file__).resolve().parents[1] / 'prepare-forks.py'
SOURCE = Path(os.environ['DSH_WEBVIEW_FORK']).resolve(strict=True)
CONFIG = json.loads((HELPER.parent / 'fork-fixes/patches.json').read_bytes())
ENTRY = CONFIG['packages']['webview_flutter_ohos']


def files(root):
    return {p.relative_to(root).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in root.rglob('*') if p.is_file()}


class ForkContract(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='fork-contract-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source_before = files(SOURCE)
        self.addCleanup(lambda: self.assertEqual(files(SOURCE), self.source_before))

    def cli(self, *args, ok=True, helper=HELPER, contains=None):
        result = subprocess.run([sys.executable, '-I', '-B', str(helper), *map(str, args)],
                                capture_output=True, text=True, timeout=30)
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
            if contains:
                self.assertIn(contains, result.stderr)
        return result

    def prepare(self, source=SOURCE, output=None, **kwargs):
        output = output or self.root / 'prepared'
        result = self.cli('--input', source, '--package', 'webview_flutter_ohos',
                          '--output', output, **kwargs)
        return output, result

    def test_complete_package_preserved_except_pinned_targets(self):
        output, _ = self.prepare()
        actual = files(output / 'package')
        self.assertEqual(actual.keys(), self.source_before.keys())
        changed = {name for name in actual if actual[name] != self.source_before[name]}
        self.assertEqual(changed, set(ENTRY['targets']))
        self.assertEqual(actual['LICENSE'], self.source_before['LICENSE'])
        report = json.loads((output / 'report.json').read_bytes())
        self.assertEqual(report['outputTreeSha256'], ENTRY['outputTreeSha256'])
        self.assertEqual(report['inputTreeSha256'], ENTRY['inputTreeSha256'])

    def test_wrong_target_other_file_added_and_deleted_file_are_refused(self):
        for kind in ('target', 'other', 'added', 'deleted'):
            with self.subTest(kind=kind):
                source = self.root / kind
                shutil.copytree(SOURCE, source)
                if kind == 'target':
                    p = source / next(iter(ENTRY['targets']))
                    p.write_bytes(p.read_bytes() + b'\n')
                elif kind == 'other':
                    p = source / 'lib/webview_flutter_ohos.dart'
                    p.write_bytes(p.read_bytes() + b'\n')
                elif kind == 'added':
                    (source / 'unrecognized.dart').write_text('')
                else:
                    (source / 'LICENSE').unlink()
                output = self.root / ('output-' + kind)
                self.prepare(source, output, ok=False, contains='input package SHA256 mismatch')
                self.assertFalse(output.exists())

    def test_symlink_member_and_symlink_root_are_refused(self):
        source = self.root / 'linked-member'
        shutil.copytree(SOURCE, source)
        (source / 'link').symlink_to(SOURCE / 'LICENSE')
        self.prepare(source, ok=False, contains='non-regular package member')
        root_link = self.root / 'linked-root'
        root_link.symlink_to(SOURCE, target_is_directory=True)
        self.prepare(root_link, ok=False, contains='input package must not be a symlink')

    def test_existing_output_is_not_modified(self):
        output, _ = self.prepare()
        before = files(output)
        self.prepare(output=output, ok=False, contains='output must be a new directory')
        self.assertEqual(files(output), before)

    def test_patch_and_output_pins_are_enforced(self):
        for kind in ('patch', 'output-pin'):
            with self.subTest(kind=kind):
                private = self.root / kind
                private.mkdir()
                shutil.copy2(HELPER, private / HELPER.name)
                shutil.copytree(HELPER.parent / 'fork-fixes', private / 'fork-fixes')
                if kind == 'patch':
                    p = private / 'fork-fixes' / ENTRY['patch']
                    p.write_bytes(p.read_bytes() + b'\n')
                    message = 'patch SHA256 mismatch'
                else:
                    p = private / 'fork-fixes/patches.json'
                    config = json.loads(p.read_bytes())
                    config['packages']['webview_flutter_ohos']['outputTreeSha256'] = '0' * 64
                    p.write_text(json.dumps(config))
                    message = 'output package SHA256 mismatch'
                output = self.root / ('prepared-' + kind)
                self.prepare(output=output, helper=private / HELPER.name, ok=False, contains=message)
                self.assertFalse(output.exists())

    def test_pub_resolution_must_use_the_exact_prepared_package(self):
        app = self.root / 'app'
        config = app / '.dart_tool/package_config.json'
        config.parent.mkdir(parents=True)
        config.write_text(json.dumps({'packages': [{'name': 'webview_flutter_ohos', 'rootUri': SOURCE.as_uri()}]}))
        overrides = app / 'pubspec_overrides.yaml'
        original = 'dependency_overrides:\n  unrelated:\n    path: ../unchanged\n'
        overrides.write_text(original)
        output = app / 'ohos/.vendor/forks'
        self.cli('--package-config', config, '--output', output, '--overrides', overrides)
        self.assertTrue(overrides.read_text().startswith(original))
        self.assertIn('path: "ohos/.vendor/forks/webview_flutter_ohos/package"', overrides.read_text())
        self.cli('--verify-package-config', config, '--output', output, ok=False,
                 contains='pub did not select the prepared package')
        selected = output / 'webview_flutter_ohos/package'
        config.write_text(json.dumps({'packages': [{'name': 'webview_flutter_ohos',
                                                    'rootUri': '../ohos/.vendor/forks/webview_flutter_ohos/package'}]}))
        self.cli('--verify-package-config', config, '--output', output)
        (selected / 'lib/webview_flutter_ohos.dart').write_text('changed')
        self.cli('--verify-package-config', config, '--output', output, ok=False,
                 contains='resolved package SHA256 mismatch')

    def test_installed_native_targets_must_match(self):
        output, _ = self.prepare()
        project = self.root / 'ohos'
        native = project / 'entry/oh_modules/webview_flutter_ohos'
        native.parent.mkdir(parents=True)
        self.cli('--verify-installed', project, ok=False, contains='native plugin was not installed')
        shutil.copytree(output / 'package/ohos', native)
        self.cli('--verify-installed', project)
        target = next(iter(ENTRY['targets']))
        relative = Path(target).relative_to('ohos')
        (native / relative).write_bytes((SOURCE / target).read_bytes())
        self.cli('--verify-installed', project, ok=False, contains='installed native target SHA256 mismatch')

    def test_generated_outputs_are_allowed_only_after_build_and_do_not_hide_source_drift(self):
        output_root = self.root / 'vendor'
        output, _ = self.prepare(output=output_root / 'webview_flutter_ohos')
        package = output / 'package'
        config = self.root / 'package_config.json'
        config.write_text(json.dumps({'packages': [{'name': 'webview_flutter_ohos', 'rootUri': package.as_uri()}]}))
        args = ('--verify-package-config', config, '--output', output_root)
        self.cli(*args)
        generated = package / 'ohos/build/default/outputs/default/webview_flutter_ohos.har'
        generated.parent.mkdir(parents=True)
        generated.write_bytes(b'Explicit generated-file fixture, not a compiled HAR')
        self.cli(*args, ok=False, contains='resolved package SHA256 mismatch')
        (package / 'ohos/oh_modules').symlink_to(self.root / 'dependency-store', target_is_directory=True)
        (package / 'ohos/.hvigor').mkdir()
        (package / 'ohos/.hvigor/log').write_text('build data')
        (package / 'ohos/oh-package-lock.json5').write_text('{}')
        self.cli(*args, '--after-build')
        extra = package / 'lib/unrecognized.dart'
        extra.write_text('unexpected source')
        self.cli(*args, '--after-build', ok=False, contains='resolved package SHA256 mismatch')
        extra.unlink()
        protected = package / next(iter(ENTRY['targets']))
        protected.write_bytes(protected.read_bytes() + b'\n')
        self.cli(*args, '--after-build', ok=False, contains='resolved package SHA256 mismatch')

    def test_failed_preparation_does_not_rewrite_overrides(self):
        config = self.root / 'package_config.json'
        config.write_text(json.dumps({'packages': []}))
        overrides = self.root / 'pubspec_overrides.yaml'
        original = b'dependency_overrides:\n'
        overrides.write_bytes(original)
        self.cli('--package-config', config, '--output', self.root / 'vendor', '--overrides', overrides,
                 ok=False, contains='fork missing from package config')
        self.assertEqual(overrides.read_bytes(), original)


if __name__ == '__main__':
    unittest.main(verbosity=2)
