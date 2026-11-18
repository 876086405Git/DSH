#!/usr/bin/env python3
"""Real asset copies/ZIPs and pre-SDK HAP staging; small data is not a guest image."""
import gzip
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import warnings
import zipfile

ROOT = Path(os.environ.get('OHOS_LINUX_ASSETS_SOURCE', Path(__file__).resolve().parents[3]))
PREFIX = 'runtime/ohos/linux/assets/'
NAMES = ('install-manifest.json', 'bbl64.bin', 'kernel-riscv64.bin',
         'tools.block', 'bootstrap.ext4.gz', 'empty.ext4.gz')
ARCHIVE = {'url': 'https://repo.huaweicloud.com/alpine/v3.24/releases/riscv64/alpine-minirootfs-3.24.4-riscv64.tar.gz',
           'bytes': 3451625, 'sha256': '010683db6c73b3ad1c334fc8f93f64ae748ef67ae6d69e964929aeaf8517bff3'}


def module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'runtime/ohos/package' / (name + '.py'))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


def sha(data):
    return hashlib.sha256(data).hexdigest()


def fixture(directory):
    directory.mkdir()
    content = {'bbl64.bin': b'approved bios data', 'kernel-riscv64.bin': b'approved kernel data',
               'tools.block': gzip.compress(b'opaque tools archive fixture', mtime=0)}
    content['tools.block'] += b'\0' * (-len(content['tools.block']) % 512)
    expanded = {'bootstrap': b'bootstrap image fixture' * 1024, 'empty': b'\0' * 32768}
    for key, data in expanded.items():
        content[key + '.ext4.gz'] = gzip.compress(data, mtime=0)
    manifest = {'archive': dict(ARCHIVE)}
    for key, name in [('bios', 'bbl64.bin'), ('kernel', 'kernel-riscv64.bin'),
                      ('tools', 'tools.block'), ('bootstrap', 'bootstrap.ext4.gz'), ('empty', 'empty.ext4.gz')]:
        data = content[name]
        (directory / name).write_bytes(data)
        manifest[key] = {'path': name, 'bytes': len(data), 'sha256': sha(data)}
        if key in expanded:
            manifest[key].update(expandedBytes=len(expanded[key]), expandedSha256=sha(expanded[key]))
    write_manifest(directory, manifest)
    return manifest


def write_manifest(directory, value):
    (directory / NAMES[0]).write_text(json.dumps(value, indent=2) + '\n')


def runtime_zip(directory=None, omit=(), extra=()):
    output = io.BytesIO()
    with warnings.catch_warnings(), zipfile.ZipFile(output, 'w') as archive:
        warnings.simplefilter('ignore', UserWarning)
        archive.writestr('manifest.json', b'{}')  # staging fixture, not a complete Host runtime
        if directory:
            for name in NAMES:
                if name not in omit:
                    archive.writestr('files/' + PREFIX + name, (directory / name).read_bytes())
        for name, data in extra:
            archive.writestr(name, data)
    return output.getvalue()


class AssetTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='linux-assets-package-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.assets = self.root / 'assets'
        self.manifest = fixture(self.assets)
        self.compose = module('compose-runtime')
        self.check = module('linux-assets')

    def rejected(self):
        with self.assertRaises((ValueError, OSError)):
            self.check.verify_assets(self.assets)

    def test_actual_composer_copies_six_and_zip_round_trip(self):
        expanded = self.root / 'expanded'
        composer = self.compose.Composer(expanded / 'files')
        receipt = self.compose.compose_linux_assets(composer, self.assets)
        self.assertEqual(receipt['manifestSha256'], sha((self.assets / NAMES[0]).read_bytes()))
        self.assertEqual(set(composer.payload), {PREFIX + name for name in NAMES})
        self.assertEqual(len(composer.inputs), 6)
        rows = sorted(composer.payload.values(), key=lambda row: row['path'])
        (expanded / 'manifest.json').write_bytes(self.compose.json_bytes({'files': rows}))
        archive_path = self.root / 'runtime.zip'
        self.compose.write_runtime_archive(expanded, archive_path)
        with zipfile.ZipFile(archive_path) as archive:
            for name in NAMES:
                data = archive.read('files/' + PREFIX + name)
                self.assertEqual(data, (self.assets / name).read_bytes())
                self.assertEqual(composer.payload[PREFIX + name]['sha256'], sha(data))
            self.assertEqual(set(archive.namelist()), {'manifest.json'} | {'files/' + PREFIX + name for name in NAMES})

    def test_publish_excludes_raw_intermediates_and_preserves_existing_destination(self):
        (self.assets / 'bootstrap.ext4').write_bytes(b'raw diagnostic image')
        output = self.root / 'published'
        self.check.publish_assets(self.assets, output)
        self.assertEqual(set(p.name for p in output.iterdir()), set(NAMES))
        first = (output / NAMES[0]).read_bytes()
        with self.assertRaises(ValueError):
            self.check.publish_assets(self.assets, output)
        self.assertEqual((output / NAMES[0]).read_bytes(), first)

    def test_missing_or_extra_file(self):
        (self.assets / 'unlisted.txt').write_text('extra')
        self.rejected()
        (self.assets / 'unlisted.txt').unlink()
        (self.assets / 'tools.block').unlink()
        self.rejected()

    def test_symlink_directory_symlink_leaf_hardlink_and_directory_leaf(self):
        original = self.assets / 'bbl64.bin'
        data = original.read_bytes()
        saved = self.root / 'saved'
        saved.write_bytes(data)
        original.unlink()
        original.symlink_to(saved)
        self.rejected()
        original.unlink()
        os.link(saved, original)
        self.rejected()
        original.unlink()
        original.mkdir()
        self.rejected()
        original.rmdir()
        os.mkfifo(original)
        self.rejected()
        original.unlink()
        original.write_bytes(data)
        linked = self.root / 'linked'
        linked.symlink_to(self.assets, target_is_directory=True)
        with self.assertRaises(ValueError):
            self.check.verify_assets(linked)

    def test_paths_and_unknown_fields_are_rejected(self):
        for path in ('../bbl64.bin', '/tmp/bbl64.bin', 'x/bbl64.bin', 'x\\bbl64.bin'):
            with self.subTest(path=path):
                self.manifest['bios']['path'] = path
                write_manifest(self.assets, self.manifest)
                self.rejected()
        self.manifest['bios']['path'] = 'bbl64.bin'
        self.manifest['nativeLibrary'] = '/tmp/attacker.so'
        write_manifest(self.assets, self.manifest)
        self.rejected()

    def test_duplicate_manifest_keys_are_rejected(self):
        raw = (self.assets / NAMES[0]).read_text()
        (self.assets / NAMES[0]).write_text(raw.replace('"bios": {', '"bios": {}, "bios": {'))
        self.rejected()

    def test_fixed_archive_identity_cannot_be_replaced(self):
        self.manifest['archive']['url'] = 'https://example.invalid/base.tar.gz'
        write_manifest(self.assets, self.manifest)
        self.rejected()

    def test_bytes_digest_types_and_gzip_expansion_are_checked(self):
        for key, field, invalid in [('bios', 'bytes', True), ('bios', 'sha256', '0' * 64),
                                     ('bootstrap', 'expandedBytes', 1), ('empty', 'expandedSha256', '0' * 64)]:
            with self.subTest(key=key, field=field):
                previous = self.manifest[key][field]
                self.manifest[key][field] = invalid
                write_manifest(self.assets, self.manifest)
                self.rejected()
                self.manifest[key][field] = previous
        write_manifest(self.assets, self.manifest)
        (self.assets / 'bbl64.bin').write_bytes(b'changed')
        self.rejected()

    def test_invalid_gzip_with_matching_compressed_identity_is_rejected(self):
        data = b'not a gzip image'
        (self.assets / 'empty.ext4.gz').write_bytes(data)
        self.manifest['empty'].update(bytes=len(data), sha256=sha(data))
        write_manifest(self.assets, self.manifest)
        self.rejected()

    def test_copy_cannot_publish_a_different_source_snapshot(self):
        composer = self.compose.Composer(self.root / 'output/files')
        original = composer.add
        def changing_source(source, *args, **kwargs):
            if source.name == 'bbl64.bin':
                source.write_bytes(b'a replacement after initial validation')
            return original(source, *args, **kwargs)
        composer.add = changing_source
        with self.assertRaises(ValueError):
            self.compose.compose_linux_assets(composer, self.assets)

    def test_archive_guard_validates_fixed_set_bytes_and_native_pair(self):
        with zipfile.ZipFile(io.BytesIO(runtime_zip(self.assets))) as archive:
            receipt = self.check.verify_runtime_archive(archive, {'libdsh_linux.so'})
            self.assertEqual(receipt['manifestSha256'], sha((self.assets / NAMES[0]).read_bytes()))
        variants = [runtime_zip(self.assets, omit=('tools.block',)),
                    runtime_zip(self.assets, extra=[('files/' + PREFIX + 'raw.ext4', b'raw')]),
                    runtime_zip(self.assets, extra=[('files/' + PREFIX + 'tools.block', b'duplicate')]),
                    runtime_zip(self.assets, extra=[('files/' + PREFIX + 'tools.block/child', b'child')])]
        for value in variants:
            with self.subTest(size=len(value)), zipfile.ZipFile(io.BytesIO(value)) as archive:
                with self.assertRaises(ValueError):
                    self.check.verify_runtime_archive(archive, {'libdsh_linux.so'})
        bios = (self.assets / 'bbl64.bin').read_bytes()
        (self.assets / 'bbl64.bin').write_bytes(b'X' * len(bios))
        with zipfile.ZipFile(io.BytesIO(runtime_zip(self.assets))) as archive:
            with self.assertRaisesRegex(ValueError, 'SHA256'):
                self.check.verify_runtime_archive(archive, {'libdsh_linux.so'})
        (self.assets / 'bbl64.bin').write_bytes(bios)
        with zipfile.ZipFile(io.BytesIO(runtime_zip(self.assets))) as archive:
            with self.assertRaisesRegex(ValueError, 'require libdsh_linux.so'):
                self.check.verify_runtime_archive(archive, set())
        with zipfile.ZipFile(io.BytesIO(runtime_zip())) as archive:
            self.assertIsNone(self.check.verify_runtime_archive(archive, {'libdsh_linux.so'}))


class HapStagingTests(unittest.TestCase):
    def stage(self, *, assets=True, native=True):
        with tempfile.TemporaryDirectory(prefix='linux-hap-assets-') as temporary:
            root = Path(temporary)
            app = root / 'app'
            helpers = root / 'tooling/ohos'
            helpers.mkdir(parents=True)
            (app / 'ohos/entry/src/main').mkdir(parents=True)
            (app / 'pubspec.lock').write_text('original lock\n')
            module_text = json.dumps({'module': {'abilities': [{'name': 'EntryAbility'}], 'requestPermissions': []}})
            (app / 'ohos/entry/src/main/module.json5').write_text(module_text)
            (app / 'ohos/build-profile.json5').write_text('{"app":{"signingConfigs":[]}}')
            for name in ['build-hap.sh', 'hap-distribution.py']:
                shutil.copy2(ROOT / 'tooling/ohos' / name, helpers / name)
            checker = ROOT / 'runtime/ohos/package/linux-assets.py'
            if checker.exists():
                destination = root / 'runtime/ohos/package'
                destination.mkdir(parents=True)
                shutil.copy2(checker, destination / checker.name)
            observed = root / 'sdk-handoff'
            (helpers / 'patch_framework.py').write_text('from pathlib import Path\nPath(' + repr(str(observed)) + ').write_text("reached")\nraise SystemExit(73)\n')
            libs = root / 'libs'
            libs.mkdir()
            for name in ['libnode.so', 'libdsh_flock.so', 'libdsh_require_builtin.so'] + (['libdsh_linux.so'] if native else []):
                (libs / name).write_bytes(b'explicit pre-SDK placeholder')
            flutter = root / 'flutter/bin/flutter'
            flutter.parent.mkdir(parents=True)
            flutter.write_text('#!/bin/sh\nexit 0\n')
            flutter.chmod(0o755)
            source_assets = root / 'assets'
            fixture(source_assets)
            transport = root / 'transport.zip'
            with zipfile.ZipFile(transport, 'w', compression=zipfile.ZIP_STORED) as archive:
                archive.writestr('dsh-runtime/runtime.zip', runtime_zip(source_assets if assets else None))
            env = {**os.environ, 'FLUTTER_OHOS': str(flutter), 'DSH_OHOS_NATIVE_LIBS': str(libs),
                   'DSH_NODE_HEADERS': str(root), 'DSH_OHOS_RUNTIME': str(transport)}
            result = subprocess.run(['bash', str(helpers / 'build-hap.sh'), '--debug'], env=env,
                                    capture_output=True, text=True, timeout=30)
            self.assertFalse((app / 'ohos/entry/src/main/resources/rawfile/dsh-runtime').exists())
            self.assertFalse((app / 'ohos/entry/libs/arm64-v8a/libdsh_linux.so').exists())
            self.assertEqual((app / 'pubspec.lock').read_text(), 'original lock\n')
            self.assertEqual((app / 'ohos/entry/src/main/module.json5').read_text(), module_text)
            return result, observed.exists()

    def test_assets_require_native_library(self):
        result, reached = self.stage(assets=True, native=False)
        self.assertFalse(reached, result.stderr)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('require libdsh_linux.so', result.stderr)

    def test_complete_assets_reach_sdk_handoff(self):
        result, reached = self.stage(assets=True, native=True)
        self.assertTrue(reached, result.stderr)
        self.assertEqual(result.returncode, 73)

    def test_library_only_keeps_component_staging_compatible(self):
        result, reached = self.stage(assets=False, native=True)
        self.assertTrue(reached, result.stderr)
        self.assertEqual(result.returncode, 73)


if __name__ == '__main__':
    unittest.main(verbosity=2)
