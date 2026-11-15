#!/usr/bin/env python3
"""Integrity failure gates; no SDK, downloads or guest execution."""
import importlib.util
import json
import os
import sys
from unittest import mock
import pathlib
import struct
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('ish_build', pathlib.Path(__file__).with_name('build.py'))
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)


class IntegrityTests(unittest.TestCase):
    def test_vdso_rejects_dummy_and_wrong_arch(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / 'vdso'
            for data in (b'', b'not ELF', b'\x7fELF\x02\x01\x01' + b'\0' * 57):
                path.write_bytes(data)
                with self.assertRaises(RuntimeError):
                    build.verify_vdso(path)
            data = bytearray(64)
            data[:7] = b'\x7fELF\x02\x01\x01'
            struct.pack_into('<HHI', data, 16, 3, 183, 1)
            path.write_bytes(data)
            self.assertEqual(build.verify_vdso(path), build.digest(path))

    def test_cached_archive_is_reverified_before_extraction(self):
        with tempfile.TemporaryDirectory() as tmp:
            old = build.CACHE
            build.CACHE = pathlib.Path(tmp)
            try:
                (build.CACHE / (build.LOCK['commit'] + '.tar.gz')).write_bytes(b'corrupted cache')
                with self.assertRaisesRegex(RuntimeError, 'SHA256 mismatch'):
                    build.download()
            finally:
                build.CACHE = old


class ReceiptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.out = pathlib.Path(self.temp.name)
        self.calls = []
        def xcode_output(args):
            self.calls.append(args)
            replies = {('xcodebuild', '-version'): 'Xcode fixture',
                       ('xcrun', '--sdk', 'iphoneos', '--show-sdk-version'): 'fixture-sdk',
                       ('xcrun', '--sdk', 'iphoneos', '--find', 'clang'): '/Xcode/clang',
                       ('/Xcode/clang', '--version'): 'Apple clang fixture'}
            return replies[tuple(args)]  # Any Meson/LLVM probe fails this test.
        self.addCleanup(mock.patch.stopall)
        mock.patch.object(build, 'output', side_effect=xcode_output).start()
        self.identity = build.target_identity('iphoneos')
        names = ('DshGuest', 'Info.plist', 'LICENSE.txt', 'SOURCE.txt', 'iSH-LICENSE.md',
                 'iSH-LICENSE.IOS', 'iSH-build.patch', 'iSH-job-runtime.patch')
        self.products = {}
        for name in names:
            path = self.out / 'DshGuest.framework' / name
            path.parent.mkdir(exist_ok=True)
            path.write_text('fixture ' + name)
            self.products[str(path.relative_to(self.out))] = build.digest(path)
        self.save()

    def save(self):
        (self.out / '.ish-build.json').write_text(json.dumps(
            {'identity': self.identity, 'products': self.products}))

    def invoke(self):
        with mock.patch.object(sys, 'argv', ['build.py', 'iphoneos', str(self.out)]):
            build.main()

    def test_path_reordering_and_absent_build_tools_reuse(self):
        with mock.patch.object(build.shutil, 'which', side_effect=AssertionError('must not probe build tools')), \
             mock.patch.object(build, 'download', side_effect=AssertionError('must not download')), \
             mock.patch.object(build.tarfile, 'open', side_effect=AssertionError('must not extract')):
            for path in ('/opt/homebrew/opt/llvm/bin:/Xcode/bin', '/Xcode/bin', ''):
                with mock.patch.dict(os.environ, {'PATH': path}):
                    self.invoke()

    def test_corrupt_product_requires_rebuild_with_actionable_error(self):
        (self.out / 'DshGuest.framework/DshGuest').write_text('corrupt')
        with mock.patch.object(build.shutil, 'which', return_value=None):
            with self.assertRaisesRegex(RuntimeError, 'brew install llvm lld meson ninja') as raised:
                self.invoke()
            self.assertIn('$(brew --prefix llvm)/bin:$(brew --prefix lld)/bin:$PATH', str(raised.exception))

    def test_changed_source_or_target_rejects(self):
        for key in ('inputs', 'sdk_version', 'compiler'):
            changed = dict(self.identity, **{key: 'changed'})
            self.assertFalse(build.verified_receipt(self.out, changed))

    def test_incomplete_products_and_malformed_receipt_reject(self):
        self.products.pop('DshGuest.framework/DshGuest')
        self.save()
        self.assertFalse(build.verified_receipt(self.out, self.identity))
        (self.out / '.ish-build.json').write_text('{partial')
        self.assertFalse(build.verified_receipt(self.out, self.identity))


def load_tests(loader, tests, pattern):
    # Existing CI invokes this file; keep the compatibility checks on that path.
    spec = importlib.util.spec_from_file_location('ish_extract_tests', pathlib.Path(__file__).with_name('test-extract.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    tests.addTests(loader.loadTestsFromModule(module))
    return tests


if __name__ == '__main__':
    unittest.main()
