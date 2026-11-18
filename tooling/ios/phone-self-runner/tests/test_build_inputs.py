"""Portable preparation and attribution tests; no device or network required."""
import hashlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


class BuildInputs(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='dsh-phone-input-test-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.prepare = module('prepare_test', ROOT / 'prepare_upstream.py')
        self.prepare.HERE = self.root
        self.pins = {'commit': 'test', 'archive': 'https://invalid.example/unused',
                     'archiveSha256': '0' * 64, 'patch': 'local.patch'}
        (self.root / 'local.patch').write_text('test patch\n')
        self.save_pins()

    def save_pins(self):
        (self.root / 'source-pins.json').write_text(json.dumps(self.pins))

    def archive(self, name, *, link=None):
        path = self.root / 'test.tar.gz'
        with tarfile.open(path, 'w:gz') as archive:
            entry = tarfile.TarInfo(name)
            if link:
                entry.type = tarfile.SYMTYPE
                entry.linkname = link
                archive.addfile(entry)
            else:
                data = b'fixture'
                entry.size = len(data)
                archive.addfile(entry, io.BytesIO(data))
        self.pins['archiveSha256'] = hashlib.sha256(path.read_bytes()).hexdigest()
        self.save_pins()
        return path

    def test_checksum_is_verified_before_extraction(self):
        path = self.root / 'bad.tar.gz'
        path.write_bytes(b'not the pinned archive')
        with self.assertRaisesRegex(ValueError, 'SHA256'):
            self.prepare.prepare(path)
        self.assertFalse((self.root / '.upstream').exists())

    def test_archive_paths_cannot_escape_source_root(self):
        for name in ['/absolute/file', 'idevice-test/../outside', 'wrong-prefix/file']:
            with self.subTest(name=name):
                with self.assertRaisesRegex(ValueError, 'Unsafe'):
                    self.prepare.prepare(self.archive(name))
        self.assertFalse((self.root / 'outside').exists())

    def test_archive_links_must_match_the_single_materialized_readme(self):
        with self.assertRaisesRegex(ValueError, 'non-regular'):
            self.prepare.prepare(self.archive('idevice-test/idevice/README.md', link='../../outside'))

    def test_existing_symlinked_output_is_never_written(self):
        outside = self.root / 'outside'
        outside.mkdir()
        (self.root / '.upstream').symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'symlinked'):
            self.prepare.prepare()
        self.assertEqual(list(outside.iterdir()), [])

    def test_changed_prepared_source_is_preserved_and_rejected(self):
        output = self.root / '.upstream'
        output.mkdir()
        (output / 'source.rs').write_text('changed\n')
        identity = {'commit': 'test', 'archiveSha256': self.pins['archiveSha256'],
                    'patchSha256': hashlib.sha256((self.root / 'local.patch').read_bytes()).hexdigest()}
        (output / '.dsh-source.json').write_text(json.dumps({'identity': identity, 'files': {'source.rs': 'wrong'}}))
        with self.assertRaisesRegex(ValueError, 'differs'):
            self.prepare.prepare()
        self.assertEqual((output / 'source.rs').read_text(), 'changed\n')

    def prepared_fixture(self):
        output = self.root / '.upstream'
        output.mkdir()
        (output / 'source.rs').write_bytes(b'original source\r\n')
        identity = {'commit': 'test', 'archiveSha256': self.pins['archiveSha256'],
                    'patchSha256': hashlib.sha256((self.root / 'local.patch').read_bytes()).hexdigest()}
        report = {'identity': identity, 'files': self.prepare.inventory(output)}
        (output / '.dsh-source.json').write_text(json.dumps(report))
        return output, identity, report

    def byte_snapshot(self, root):
        return {path.relative_to(root).as_posix(): path.read_bytes()
                for path in root.rglob('*') if path.is_file()}

    def test_stale_identity_explains_backup_pins_hashes_and_quoted_rerun(self):
        output, identity, report = self.prepared_fixture()
        report['identity'] = dict(identity, commit='old-test')
        (output / '.dsh-source.json').write_text(json.dumps(report))
        archive = self.root / "archive with 'quotes' and spaces.tar.gz"
        archive.write_bytes(b'not accessed while existing output is rejected')
        before = self.byte_snapshot(self.root)
        with mock.patch.object(self.prepare.urllib.request, 'urlopen', side_effect=AssertionError('no download')):
            with self.assertRaises(ValueError) as raised:
                self.prepare.prepare(archive)
        message = str(raised.exception)
        self.assertIn(str(output), message)
        self.assertIn('left unchanged', message)
        self.assertIn('source-pins.json', message)
        self.assertIn('local.patch', message)
        for key, value in identity.items():
            self.assertIn(key, message)
            self.assertIn(value, message)
        self.assertIn('explicitly move', message)
        self.assertIn('backup', message)
        command = message.split('After moving it aside, rerun: ', 1)[1].splitlines()[0]
        self.assertEqual(shlex.split(command), [sys.executable, str(self.root / 'prepare_upstream.py'),
                                               '--archive', str(archive)])
        self.assertEqual(self.byte_snapshot(self.root), before)

    def test_missing_or_invalid_metadata_keeps_every_existing_byte(self):
        output, _, _ = self.prepared_fixture()
        metadata = output / '.dsh-source.json'
        for value in [None, b'{incomplete', b'[]', b'{"files":{}}']:
            with self.subTest(value=value):
                if value is None:
                    metadata.unlink()
                else:
                    metadata.write_bytes(value)
                before = self.byte_snapshot(self.root)
                with mock.patch.object(self.prepare.urllib.request, 'urlopen', side_effect=AssertionError('no download')):
                    with self.assertRaises(ValueError) as raised:
                        self.prepare.prepare()
                message = str(raised.exception)
                self.assertIn('left unchanged', message)
                self.assertIn('source-pins.json', message)
                self.assertIn('explicitly move', message)
                self.assertIn('rerun:', message)
                self.assertEqual(self.byte_snapshot(self.root), before)

    def test_verified_existing_output_is_reused_without_download_or_write(self):
        output, _, _ = self.prepared_fixture()
        before = self.byte_snapshot(self.root)
        with mock.patch.object(self.prepare.urllib.request, 'urlopen', side_effect=AssertionError('no download')):
            self.assertEqual(self.prepare.prepare(self.root / 'unused-missing-archive'), output)
        self.assertEqual(self.byte_snapshot(self.root), before)

    def test_license_inventory_has_no_host_paths_or_raw_metadata(self):
        exporter = module('license_test', ROOT / 'license_inventory.py')
        packages = [{'name': 'idevice', 'version': '0.1.68', 'license': 'MIT', 'source': None,
                     'manifest_path': '/private/user/credentials/Cargo.toml'},
                    {'name': 'dsh-phone-self-runner', 'version': '0.1.0', 'license': 'AGPL-3.0-only', 'source': None},
                    {'name': 'serde', 'version': '1', 'license': 'MIT OR Apache-2.0', 'source': 'registry+https://github.com/rust-lang/crates.io-index'}]
        report = exporter.inventory({'packages': packages})
        self.assertNotIn('/private', json.dumps(report))
        self.assertEqual(set(report['packages'][0]), {'name', 'version', 'license', 'source'})
        with self.assertRaisesRegex(ValueError, 'Unexpected local'):
            exporter.inventory({'packages': [{'name': 'unknown-local', 'version': '1', 'source': None}]})


class BuildScript(unittest.TestCase):
    """Exercise publication with fixture tools, not an Apple compiler."""
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='dsh-phone-build-test-')
        self.addCleanup(self.temporary.cleanup)
        self.repo = Path(self.temporary.name) / 'repo with spaces'
        native = self.repo / 'tooling/ios/phone-self-runner'
        native.mkdir(parents=True)
        self.script = native.parent / 'build-phone-self-runner.sh'
        shutil.copyfile(ROOT.parent / 'build-phone-self-runner.sh', self.script)
        for name in ['license_inventory.py', 'source-pins.json', 'notice-supplements.json']:
            shutil.copyfile(ROOT / name, native / name)
        (native / 'prepare_upstream.py').write_text('print("fixture upstream only")\n')
        (native / '.upstream').mkdir()
        (native / '.upstream/LICENSE.txt').write_text('fixture upstream MIT license\n')
        (native / '.upstream/idevice').mkdir()
        (native / '.upstream/idevice/Cargo.toml').write_text('fixture manifest\n')
        (native / 'Cargo.toml').write_text('fixture manifest\n')
        (self.repo / 'LICENSE').write_text('fixture application license\n')
        self.tools = self.repo / 'tools'
        self.tools.mkdir()
        for name, body in {
            'uname': '#!/bin/sh\nprintf Darwin',
            'xcrun': '#!/bin/sh\nexit 0',
            'rustup': '#!/bin/sh\nexit 0',
            'cargo': '''#!/usr/bin/env python3
import json,os,pathlib,sys
if 'metadata' in sys.argv:
 native=pathlib.Path.cwd()
 if os.environ.get('FAIL_NOTICE'): (native/'.upstream/LICENSE.txt').unlink()
 packages=[{'id':'native','name':'dsh-phone-self-runner','version':'0.1.0','license':'AGPL-3.0-only','source':None,'manifest_path':str(native/'Cargo.toml')},
           {'id':'upstream','name':'idevice','version':'0.1.68','license':'MIT','source':None,'manifest_path':str(native/'.upstream/idevice/Cargo.toml')}]
 print(json.dumps({'packages':packages,'resolve':{'root':'native','nodes':[{'id':p['id']} for p in packages]}}))
else:
 target=sys.argv[sys.argv.index('--target')+1]
 if os.environ.get('FAIL_SLICE')==target: sys.exit(23)
 base=pathlib.Path(sys.argv[sys.argv.index('--target-dir')+1])/target/'release'
 base.mkdir(parents=True,exist_ok=True)
 (base/'libdsh_phone_self_runner.a').write_text('fixture slice '+target)
''',
        }.items():
            path = self.tools / name
            path.write_text(body)
            path.chmod(0o755)
        self.out = self.repo / 'app/ios/PhoneSelfRunnerNative'

    def run_build(self, fail=None, missing_notice=False):
        env = {**os.environ, 'PATH': str(self.tools) + os.pathsep + os.environ['PATH']}
        if fail:
            env['FAIL_SLICE'] = fail
        if missing_notice:
            env['FAIL_NOTICE'] = '1'
        return subprocess.run(['bash', str(self.script)], env=env, capture_output=True, text=True, timeout=20)

    def test_success_publishes_three_slices_and_sanitized_attribution(self):
        result = self.run_build()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for platform, arch in [('iphoneos','arm64'),('iphonesimulator','arm64'),('iphonesimulator','x86_64')]:
            self.assertTrue((self.out / platform / arch / 'libdsh_phone_self_runner.a').is_file())
        config = (self.out / 'PhoneSelfRunner.xcconfig').read_text()
        self.assertIn('DSH_PHONE_SELF_RUNNER_ENABLED = YES', config)
        self.assertIn('$(PLATFORM_NAME)/$(CURRENT_ARCH)', config)
        report = (self.out / 'THIRD_PARTY_CRATES.json').read_text()
        self.assertNotIn('/private', report)
        package = next(p for p in json.loads(report)['packages'] if p['name'] == 'idevice')
        self.assertEqual(package['license'], 'MIT')
        self.assertTrue((self.out / 'LICENSE.idevice.txt').is_file())
        notices = (self.out / 'NOTICES.txt').read_bytes()
        self.assertIn(b'fixture upstream MIT license\n', notices)
        self.assertIn(b'fixture application license\n', notices)
        self.assertNotIn(str(self.repo).encode(), notices)
        self.assertEqual(json.loads(report)['notices']['sha256'], hashlib.sha256(notices).hexdigest())
        self.assertEqual(list(self.out.glob('.build.*')), [])

    def test_failed_slice_cannot_enable_a_first_build(self):
        result = self.run_build('aarch64-apple-ios-sim')
        self.assertEqual(result.returncode, 23, result.stdout + result.stderr)
        self.assertFalse((self.out / 'PhoneSelfRunner.xcconfig').exists())
        self.assertFalse((self.out / 'iphoneos').exists())
        self.assertEqual(list(self.out.glob('.build.*')), [])

    def test_missing_original_notice_cannot_publish_completed_slices(self):
        result = self.run_build(missing_notice=True)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('Notice must be a regular', result.stderr)
        self.assertFalse((self.out / 'PhoneSelfRunner.xcconfig').exists())
        self.assertFalse((self.out / 'iphoneos').exists())
        self.assertEqual(list(self.out.glob('.build.*')), [])


class NoticeCollection(unittest.TestCase):
    """Use real collection, publication and verification with synthetic sources."""
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='dsh-notice-texts-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.native = self.root / 'repo/tooling/ios/phone-self-runner'
        self.native.mkdir(parents=True)
        self.exporter = module('notice_collection_test', ROOT / 'license_inventory.py')
        self.exporter.HERE = self.native
        shutil.copyfile(ROOT / 'source-pins.json', self.native / 'source-pins.json')
        (self.native / 'notice-supplements.json').write_text('{}\n')
        (self.native / 'Cargo.toml').write_text('synthetic native manifest\n')
        (self.root / 'repo/LICENSE').write_bytes(b'application original\r\n')
        upstream = self.native / '.upstream/idevice'
        upstream.mkdir(parents=True)
        (upstream / 'Cargo.toml').write_text('synthetic upstream manifest\n')
        (upstream.parent / 'LICENSE.txt').write_text('upstream original\n')
        self.crate = self.root / 'registry/fixture-1.0.0'
        self.crate.mkdir(parents=True)
        (self.crate / 'Cargo.toml').write_text('synthetic registry manifest\n')
        (self.crate / 'LICENSE-MIT').write_bytes(b'fixture MIT original\r\nCopyright fixture\n')
        (self.crate / 'third_party').mkdir()
        (self.crate / 'third_party/NOTICE').write_bytes(b'nested original attribution\n')
        packages = [
            {'id': 'native', 'name': 'dsh-phone-self-runner', 'version': '0.1.0', 'license': 'AGPL-3.0-only',
             'source': None, 'manifest_path': str(self.native / 'Cargo.toml')},
            {'id': 'upstream', 'name': 'idevice', 'version': '0.1.68', 'license': 'MIT',
             'source': None, 'manifest_path': str(upstream / 'Cargo.toml')},
            {'id': 'fixture', 'name': 'fixture', 'version': '1.0.0', 'license': 'MIT',
             'source': 'registry+https://github.com/rust-lang/crates.io-index',
             'manifest_path': str(self.crate / 'Cargo.toml')},
        ]
        self.metadata = {'packages': packages,
                         'resolve': {'root': 'native', 'nodes': [{'id': p['id']} for p in packages]}}

    def test_all_originals_and_nested_attributions_are_kept_byte_for_byte(self):
        report, notices = self.exporter.generate(self.metadata)
        self.exporter.verify(report, notices)
        fixture = next(p for p in report['notices']['packages'] if p['name'] == 'fixture')
        self.assertEqual({p['path'] for p in fixture['files']}, {'LICENSE-MIT', 'third_party/NOTICE'})
        for item in fixture['files']:
            original = (self.crate / item['path']).read_bytes()
            self.assertEqual(notices[item['offset']:item['offset'] + item['bytes']], original)
        self.assertIn(b'application original\r\n', notices)
        self.assertNotIn(str(self.root).encode(), notices)
        self.assertNotIn(str(self.root), json.dumps(report))

    def test_order_of_cargo_metadata_does_not_change_the_notice_artifact(self):
        expected = self.exporter.generate(self.metadata)
        self.metadata['packages'].reverse()
        self.assertEqual(self.exporter.generate(self.metadata), expected)

    def test_source_suffixes_do_not_count_as_automatic_notices(self):
        code_paths = ['src/license.rs', 'notice.RS', 'src/COPYRIGHT.c', 'LICENSE.h',
                      'NOTICE.py', 'license.js', 'notice.ts', 'LICENSE.go', 'licenses/source.rs']
        for path in code_paths:
            target = self.crate / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(b'synthetic code is not an original notice\n')
        report, notices = self.exporter.generate(self.metadata)
        fixture = next(p for p in report['notices']['packages'] if p['name'] == 'fixture')
        self.assertEqual({p['path'] for p in fixture['files']}, {'LICENSE-MIT', 'third_party/NOTICE'})
        self.assertNotIn(b'synthetic code is not an original notice', notices)
        (self.crate / 'LICENSE-MIT').unlink()
        (self.crate / 'third_party/NOTICE').unlink()
        with self.assertRaisesRegex(ValueError, 'No license or notice text'):
            self.exporter.generate(self.metadata)

    def test_text_suffixes_multiple_licenses_and_nested_originals_stay_verbatim(self):
        names = ['LICENSE.APACHE', 'LICENSE.Apache2.0', 'LICENCE-BSD.txt', 'LICENSE-MIT.md',
                 'COPYING.LESSER', 'COPYING.GPL-3.0', 'COPYRIGHT.rst', 'NOTICE.html', 'AUTHORS',
                 'licenses/OFL-1.1.txt', 'src/third_party/LICENSE-ISC']
        originals = {}
        for name in names:
            data = ('synthetic original for ' + name + '\r\n').encode('utf-8')
            target = self.crate / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            originals[name] = data
        report, notices = self.exporter.generate(self.metadata)
        self.exporter.verify(report, notices)
        fixture = next(p for p in report['notices']['packages'] if p['name'] == 'fixture')
        self.assertEqual({p['path'] for p in fixture['files']},
                         set(names) | {'LICENSE-MIT', 'third_party/NOTICE'})
        for item in fixture['files']:
            if item['path'] in originals:
                self.assertEqual(notices[item['offset']:item['offset'] + item['bytes']], originals[item['path']])

    def test_declared_nonstandard_license_path_remains_explicit_input(self):
        target = self.crate / 'legal/terms.custom'
        target.parent.mkdir()
        target.write_bytes(b'explicitly declared original terms\r\n')
        self.metadata['packages'][2]['license_file'] = 'legal/terms.custom'
        report, notices = self.exporter.generate(self.metadata)
        fixture = next(p for p in report['notices']['packages'] if p['name'] == 'fixture')
        item = next(p for p in fixture['files'] if p['path'] == 'legal/terms.custom')
        self.assertEqual(notices[item['offset']:item['offset'] + item['bytes']], target.read_bytes())

    def test_missing_empty_and_binary_license_text_cannot_generate_a_bundle(self):
        (self.crate / 'third_party/NOTICE').unlink()
        license_file = self.crate / 'LICENSE-MIT'
        license_file.unlink()
        with self.assertRaisesRegex(ValueError, 'No license'):
            self.exporter.generate(self.metadata)
        for invalid in [b'', b' \n\t', b'license\0suffix']:
            license_file.write_bytes(invalid)
            with self.assertRaisesRegex(ValueError, 'Empty, binary'):
                self.exporter.generate(self.metadata)

    def test_license_links_and_declared_paths_outside_the_crate_are_rejected(self):
        (self.crate / 'LICENSE-MIT').unlink()
        outside = self.root / 'outside-license'
        outside.write_text('must not read this into a package\n')
        (self.crate / 'LICENSE-MIT').symlink_to(outside)
        with self.assertRaisesRegex(ValueError, 'non-symlink'):
            self.exporter.generate(self.metadata)
        (self.crate / 'LICENSE-MIT').unlink()
        self.metadata['packages'][2]['license_file'] = str(outside)
        with self.assertRaisesRegex(ValueError, 'escapes package'):
            self.exporter.generate(self.metadata)

    def test_no_deps_metadata_cannot_silently_produce_partial_coverage(self):
        self.metadata['resolve'] = None
        with self.assertRaisesRegex(ValueError, 'Full resolved'):
            self.exporter.generate(self.metadata)

    def test_tampered_notice_bytes_and_missing_package_entries_fail_verification(self):
        report, notices = self.exporter.generate(self.metadata)
        with self.assertRaisesRegex(ValueError, 'identity mismatch'):
            self.exporter.verify(report, notices + b'changed')
        missing = copy.deepcopy(report)
        missing['notices']['packages'].pop()
        with self.assertRaisesRegex(ValueError, 'coverage'):
            self.exporter.verify(missing, notices)
        missing = copy.deepcopy(report)
        missing['notices']['packages'][0]['files'] = []
        with self.assertRaisesRegex(ValueError, 'no notice'):
            self.exporter.verify(missing, notices)

    def test_rehashed_document_still_checks_each_original_byte_range(self):
        report, notices = self.exporter.generate(self.metadata)
        first = report['notices']['packages'][0]['files'][0]
        changed = bytearray(notices)
        changed[first['offset']] ^= 1
        report['notices']['sha256'] = hashlib.sha256(changed).hexdigest()
        with self.assertRaisesRegex(ValueError, 'source text identity'):
            self.exporter.verify(report, bytes(changed))

    def test_source_pins_and_native_package_coverage_are_checked_in_the_bundle(self):
        report, notices = self.exporter.generate(self.metadata)
        bundle = self.root / 'bundle'
        bundle.mkdir()
        (bundle / 'THIRD_PARTY_CRATES.json').write_text(json.dumps(report))
        (bundle / 'NOTICES.txt').write_bytes(notices)
        shutil.copyfile(self.native / 'source-pins.json', bundle / 'SOURCE.json')
        self.exporter.verify_bundle(bundle)
        (bundle / 'SOURCE.json').write_text('{"commit":"wrong"}')
        with self.assertRaisesRegex(ValueError, 'source pin mismatch'):
            self.exporter.verify_bundle(bundle)

    def test_every_package_retains_archive_identity_type_checks(self):
        report, notices = self.exporter.generate(self.metadata)
        for field in ['name', 'version', 'source']:
            for invalid in [None, 3, {}, '']:
                changed = copy.deepcopy(report)
                next(p for p in changed['packages'] if p['name'] == 'fixture')[field] = invalid
                with self.subTest(field=field, invalid=invalid):
                    with self.assertRaisesRegex(ValueError, 'Invalid package'):
                        self.exporter.verify(changed, notices)

    def test_oversized_original_is_rejected_before_collecting_its_payload(self):
        original = self.crate / 'LICENSE-MIT'
        with original.open('wb') as output:
            output.truncate(self.exporter.MAX_NOTICE_BYTES + 1)
        with self.assertRaisesRegex(ValueError, 'oversized'):
            self.exporter.read_notice(original)

    def test_curated_text_is_bound_to_manifest_vcs_license_and_exact_bytes(self):
        original = b'synthetic published manifest\n'
        (self.crate / 'Cargo.toml.orig').write_bytes(original)
        (self.crate / '.cargo_vcs_info.json').write_text(json.dumps({'git': {'sha1': 'fixture-commit'}}))
        texts = self.native / 'notice-texts'
        texts.mkdir()
        document = b'synthetic upstream original terms\r\n'
        (texts / 'fixture.txt').write_bytes(document)
        supplement = {'fixture@1.0.0': {'manifest_sha256': hashlib.sha256(original).hexdigest(),
                      'commit': 'fixture-commit', 'license': 'MIT', 'originals': ['Cargo.toml.orig'],
                      'documents': [{'file': 'fixture.txt', 'sha256': hashlib.sha256(document).hexdigest(),
                                     'provenance': 'synthetic test source'}]}}
        config = self.native / 'notice-supplements.json'
        config.write_text(json.dumps(supplement))
        _, notices = self.exporter.generate(self.metadata)
        self.assertIn(document, notices)
        for field in ['manifest_sha256', 'commit', 'license']:
            changed = copy.deepcopy(supplement)
            changed['fixture@1.0.0'][field] = 'different'
            config.write_text(json.dumps(changed))
            with self.subTest(field=field):
                with self.assertRaisesRegex(ValueError, 'does not match'):
                    self.exporter.generate(self.metadata)
        config.write_text(json.dumps(supplement))
        (texts / 'fixture.txt').write_bytes(document + b'changed')
        with self.assertRaisesRegex(ValueError, 'SHA256 mismatch'):
            self.exporter.generate(self.metadata)

    def test_real_verify_cli_rejects_removed_notice_sources(self):
        report, notices = self.exporter.generate(self.metadata)
        bundle = self.root / 'cli-bundle'
        bundle.mkdir()
        inventory = bundle / 'THIRD_PARTY_CRATES.json'
        inventory.write_text(json.dumps(report))
        (bundle / 'NOTICES.txt').write_bytes(notices)
        shutil.copyfile(ROOT / 'source-pins.json', bundle / 'SOURCE.json')
        command = [sys.executable, '-I', '-B', str(ROOT / 'license_inventory.py'), '--verify', str(bundle)]
        good = subprocess.run(command, capture_output=True, timeout=10)
        self.assertEqual(good.returncode, 0, good.stderr)
        report['notices']['packages'].pop()
        inventory.write_text(json.dumps(report))
        bad = subprocess.run(command, capture_output=True, timeout=10)
        self.assertNotEqual(bad.returncode, 0)
        self.assertIn(b'coverage', bad.stderr)


if __name__ == '__main__':
    unittest.main()
