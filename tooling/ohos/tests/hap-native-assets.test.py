#!/usr/bin/env python3
"""The AOT's native assets reach a HAP only as their OH builds; the glibc ones never do.

The ELF cases build tiny libraries with the SDK under $OHOS_SDK (holding native/) and
are skipped without it; run-gates passes its SDK.
"""
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


assets = load('native_assets', 'tooling/ohos/native_assets.py')
hap_libs = load('build_hap_libs', 'runtime/ohos/native/build-hap-libs.py')
sqlite = load('build_sqlite', 'runtime/ohos/native/build-sqlite.py')
SDK = Path(os.environ['OHOS_SDK']) / 'native' if os.environ.get('OHOS_SDK') else None
MAPPING = {'format-version': [1, 0, 0],
           'native-assets': {'ohos_arm64': {'package:sqlite3/src/ffi/libsqlite3.g.dart': ['absolute', 'libsqlite3.so']}}}


def aot_with(root, files, manifest=MAPPING):
    aot = root / 'aot'
    (aot / assets.ASSETS).mkdir(parents=True)
    (aot / 'flutter_assets').mkdir()
    for name, data in files.items():
        (aot / assets.ASSETS / name).write_bytes(data)
    if manifest is not None:
        (aot / assets.MANIFEST).write_text(json.dumps(manifest))
    return aot


def native_with(root, files):
    native = root / 'native'
    native.mkdir()
    for name, data in files.items():
        (native / name).write_bytes(data)
    return native


class Plan(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def test_the_oh_build_is_taken_and_byte_identity_is_required(self):
        aot = aot_with(self.root, {'libsqlite3.so': b'glibc'})
        native = native_with(self.root, {'libsqlite3.so': b'musl'})
        sources, problems = assets.plan(aot, native)
        self.assertEqual((sources, problems), ({'libsqlite3.so': native / 'libsqlite3.so'}, []))
        self.assertEqual(assets.packaged_problems(sources, aot, {'libsqlite3.so': b'musl'}), [])
        self.assertIn("is the AOT's hook binary", assets.packaged_problems(sources, aot, {'libsqlite3.so': b'glibc'})[0])
        self.assertIn('differs from its OH build', assets.packaged_problems(sources, aot, {'libsqlite3.so': b'other'})[0])

    def test_a_missing_native_sqlite_is_refused(self):
        aot = aot_with(self.root, {'libsqlite3.so': b'glibc'})
        sources, problems = assets.plan(aot, native_with(self.root, {'libnode.so': b'x'}))
        self.assertEqual(sources, {})
        self.assertEqual(len(problems), 1)
        self.assertIn('build-sqlite.py', problems[0])

    def test_an_unknown_asset_is_refused_not_copied(self):
        aot = aot_with(self.root, {'libsqlite3.so': b'glibc', 'libfoo.so': b'glibc'})
        sources, problems = assets.plan(aot, native_with(self.root, {'libsqlite3.so': b'musl', 'libfoo.so': b'musl'}))
        self.assertEqual(set(sources), {'libsqlite3.so'})
        self.assertEqual(len(problems), 1)
        self.assertIn('libfoo.so has no known OH build', problems[0])

    def test_the_manifest_cannot_name_an_asset_the_aot_lacks(self):
        aot = aot_with(self.root, {})
        _, problems = assets.plan(aot, native_with(self.root, {'libsqlite3.so': b'musl'}))
        self.assertEqual(len(problems), 1)
        self.assertIn('does not hold', problems[0])

    def test_no_native_assets_means_nothing_to_package(self):
        aot = self.root / 'aot'
        (aot / 'flutter_assets').mkdir(parents=True)
        self.assertEqual(assets.plan(aot, native_with(self.root, {'libsqlite3.so': b'musl'})), ({}, []))

    def test_the_command_copies_the_oh_build_or_exits_2(self):
        aot = aot_with(self.root, {'libsqlite3.so': b'glibc'})
        libs = self.root / 'libs'
        libs.mkdir()
        command = [sys.executable, '-I', '-B', str(ROOT / 'tooling/ohos/native_assets.py'), '--aot', str(aot)]
        missing = subprocess.run(command + ['--native', str(self.root), '--copy-to', str(libs)], capture_output=True, text=True)
        self.assertEqual(missing.returncode, 2)
        self.assertEqual(list(libs.iterdir()), [])
        native = native_with(self.root, {'libsqlite3.so': b'musl'})
        subprocess.run(command + ['--native', str(native), '--copy-to', str(libs)], check=True, capture_output=True)
        self.assertEqual((libs / 'libsqlite3.so').read_bytes(), b'musl')


class Packaging(unittest.TestCase):
    def test_check_arkts_packages_what_audit_hap_expects(self):
        script = (ROOT / 'tooling/ohos/check-arkts.sh').read_text()
        audit = (ROOT / 'tooling/ohos/audit-hap.py').read_text()
        self.assertNotIn('"$AOT/native_assets', script)
        self.assertIn('native_assets.py" --aot "$AOT" --native "$NATIVE" --copy-to "$LIBS"', script)
        optional = re.search(r"optional = \{name for name in \(([^)]*)\)", audit).group(1)
        copied = re.search(r'for optional in ([^;]*); do', script).group(1).split()
        self.assertEqual(sorted(re.findall(r"'([\w.+]+)'", optional)), sorted(copied))


class SqliteInputs(unittest.TestCase):
    def test_the_hook_defines_and_symbols_are_read_and_windows_ones_dropped(self):
        with tempfile.TemporaryDirectory() as temp:
            package = Path(temp)
            (package / 'lib/src/hook/compile').mkdir(parents=True)
            (package / 'pubspec.yaml').write_text('name: sqlite3\nversion: 3.9.1\n')
            (package / 'lib/src/hook/compile/description.dart').write_text(
                "x\nconst _defaultDefines = '''\n  SQLITE_DQS=0\n  SQLITE_HAVE_LOCALTIME_S\n  SQLITE_OMIT_DEPRECATED\n''';\n")
            (package / 'lib/src/hook/compile/used_symbols.dart').write_text(
                "const usedSqliteSymbols = {\n  'sqlite3_free',\n  'sqlite3_temp_directory',\n};\n")
            version, defines, used = sqlite.package_inputs(package)
        self.assertEqual(version, '3.9.1')
        self.assertEqual(defines, [('SQLITE_DQS', '0'), ('SQLITE_HAVE_LOCALTIME_S', None), ('SQLITE_OMIT_DEPRECATED', None)])
        self.assertEqual(used, ['sqlite3_free', 'sqlite3_temp_directory'])
        self.assertIn('SQLITE_HAVE_LOCALTIME_S', sqlite.WINDOWS_ONLY)

    def test_the_lock_and_header_are_read(self):
        lock = '  shelf:\n    version: "1.0.0"\n  sqlite3:\n    dependency: transitive\n    source: hosted\n    version: "3.9.1"\n'
        self.assertEqual(sqlite.locked_version(lock), '3.9.1')
        with self.assertRaises(ValueError):
            sqlite.locked_version('  shelf:\n    version: "1.0.0"\n')
        header = ('SQLITE_API int sqlite3_free(void*);\nSQLITE_API SQLITE_EXTERN char *sqlite3_temp_directory;\n'
                  '/* SQLITE_API int sqlite3_commented(void); */\nSQLITE_API sqlite3_int64 sqlite3_changes64(\n  sqlite3*);\n')
        self.assertEqual(sqlite.declared(header), {'sqlite3_free', 'sqlite3_temp_directory', 'sqlite3_changes64'})


@unittest.skipUnless(SDK, 'set OHOS_SDK to an SDK holding native/ for the ELF cases')
class Elf(unittest.TestCase):
    SOURCE = ('void *malloc(unsigned long);\nvoid *sqlite3_malloc(int n) { return malloc((unsigned long)n); }\n'
              'int sqlite3_libversion_number(void) { return 3054001; }\n')

    def build(self, folder, *flags):
        (folder / 'lib.c').write_text(self.SOURCE)
        subprocess.run([str(SDK / 'llvm/bin/clang'), '-shared', '-fPIC', '-O2', *flags, '-Wl,-soname,libsqlite3.so',
                        str(folder / 'lib.c'), '-o', str(folder / 'set/libsqlite3.so')], check=True, cwd=folder)

    def audit(self, folder):
        problems, report = hap_libs.audit(folder / 'set', SDK)
        return [item for item in problems if item != 'The set needs libdsh_host.so and libnode.so'], report

    def test_an_oh_build_passes_the_native_set_audit(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            (folder / 'set').mkdir()
            self.build(folder, '--target=aarch64-linux-ohos', f'--sysroot={SDK / "sysroot"}')
            problems, report = self.audit(folder)
        self.assertEqual(problems, [])
        self.assertEqual(report['libraries']['libsqlite3.so']['needed'], ['libc.so'])

    def test_a_glibc_build_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            (folder / 'set').mkdir()
            # A stand-in for glibc: soname libc.so.6, malloc versioned GLIBC_2.17.
            (folder / 'glibc.c').write_text('void *malloc(unsigned long n) { return (void *)n; }\n')
            (folder / 'glibc.map').write_text('GLIBC_2.17 { global: malloc; local: *; };\n')
            gnu = ['--target=aarch64-linux-gnu', '-nostdlib', '-fuse-ld=lld']
            subprocess.run([str(SDK / 'llvm/bin/clang'), *gnu, '-shared', '-fPIC', '-Wl,-soname,libc.so.6',
                            f'-Wl,--version-script={folder / "glibc.map"}', str(folder / 'glibc.c'),
                            '-o', str(folder / 'libc.so.6')], check=True)
            self.build(folder, *gnu, str(folder / 'libc.so.6'), '-Wl,-rpath,$ORIGIN')
            problems, _ = self.audit(folder)
        self.assertTrue(any('carries a RUNPATH' in item for item in problems), problems)
        self.assertTrue(any('glibc-versioned symbols' in item and 'malloc@GLIBC_2.17' in item for item in problems), problems)
        self.assertTrue(any('needs libc.so.6, outside the set' in item for item in problems), problems)


if __name__ == '__main__':
    unittest.main()
