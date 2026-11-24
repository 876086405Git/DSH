#!/usr/bin/env python3
"""Small real archives exercise partitioning, compatibility evidence and byte reuse."""
import copy
import errno
import gzip
import hashlib
import importlib.util
import io
import json
import lzma
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('rtbuild', HERE / 'lib/rtbuild.py')
rt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rt)


def archive(path, rows):
    with tarfile.open(path, 'w:gz', format=tarfile.GNU_FORMAT) as tar:
        for name, kind, value, mode in rows:
            item = tarfile.TarInfo(name)
            item.mode = mode
            if kind == 'file':
                data = value.encode()
                item.size = len(data)
                tar.addfile(item, io.BytesIO(data))
            else:
                item.type = {'dir': tarfile.DIRTYPE, 'symlink': tarfile.SYMTYPE,
                             'hardlink': tarfile.LNKTYPE}[kind]
                item.linkname = value
                tar.addfile(item)


def members(path):
    with tarfile.open(path) as tar:
        return {item.name: (item.type, item.mode, item.linkname,
                            tar.extractfile(item).read() if item.isfile() else None,
                            item.uid, item.gid, item.mtime)
                for item in tar}


class LayerPackaging(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.base, self.node, self.python = [self.root / name for name in ('ubuntu.gz', 'node.gz', 'python.gz')]
        archive(self.base, [
            ('usr/lib/os-release', 'file', 'ID=ubuntu\nVERSION_ID="24.04"\n', 0o644),
            ('etc/os-release', 'symlink', '../usr/lib/os-release', 0o777),
            ('usr/lib/fixture', 'file', 'base content', 0o4755),
            ('usr/lib/copy', 'hardlink', 'usr/lib/fixture', 0o644),
            ('usr/share/link', 'symlink', '/usr/lib/fixture', 0o777),
            ('tmp', 'dir', '', 0o1777),
            ('root/' + 'long-name-' * 15 + '/data', 'file', 'long path', 0o600),
        ])
        archive(self.node, [('node/bin/node', 'file', 'node fixture', 0o755)])
        archive(self.python, [('python/bin/python3.14', 'file', 'python fixture', 0o755),
                              ('python/bin/python3', 'symlink', 'python3.14', 0o777)])
        self.dsh = self.root / 'dsh/node_modules/example/index.js'
        self.bridge = self.root / 'bridge/lib/index.js'
        self.pnpm = self.root / 'pnpm/node_modules/pnpm/bin'
        for path in (self.dsh, self.bridge):
            path.parent.mkdir(parents=True)
            path.write_text('synthetic engine input')
        self.pnpm.mkdir(parents=True)
        for name in ('pnpm.mjs', 'pnpx.mjs'):
            (self.pnpm / name).write_text('pnpm fixture')
        self.versions = dict(runtimeVersion='layer-fixture', abi='arm64-v8a', ubuntuVersion='24.04.5',
                             nodeVersion='24', dshVersion='test', pnpmVersion='11', prootVersion='5',
                             tallocVersion='2', androidShmemVersion='0', dshGoBridge='fixture')
        self.jni = self.root / 'jni.json'
        self.jni.write_text('{}')

    def command(self, name, *, layered=True, with_python=True, compress='gz'):
        out = self.root / name
        out.mkdir()
        command = [sys.executable, '-I', str(HERE / 'lib/rtbuild.py'), 'assemble',
                   '--abi', 'arm64-v8a', '--base', str(self.base), '--node', str(self.node),
                   '--dsh-prefix', str(self.root / 'dsh'), '--pnpm-prefix', str(self.root / 'pnpm'),
                   '--bridge', str(self.root / 'bridge'), '--runtime-info', json.dumps(self.versions),
                   '--report', str(out / 'report.json'), '--compress', compress, '--threads', '4']
        if with_python:
            command += ['--python', str(self.python)]
        if layered:
            command += ['--base-out', str(out / ('base-arm64-v8a.tar.' + compress)),
                        '--engine-out', str(out / ('engine-arm64-v8a.tar.' + compress)),
                        '--base-cache', str(self.root / 'cache')]
        else:
            command += ['--out', str(out / ('rootfs.tar.' + compress))]
        return out, command

    def build(self, name, **options):
        out, command = self.command(name, **options)
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return out, json.loads((out / 'report.json').read_text())

    def manifest(self, out, *, check=True):
        result = subprocess.run([sys.executable, '-I', str(HERE / 'lib/rtbuild.py'), 'manifest',
                                 '--abi', 'arm64-v8a', '--report', str(out / 'report.json'),
                                 '--jnilibs', str(self.jni), '--versions', json.dumps(self.versions),
                                 '--out', str(out / 'manifest.json')], capture_output=True, text=True)
        if check:
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads((out / 'manifest.json').read_text())
        return result

    def test_typescript_source_pruning_keeps_runtime_files_and_licenses(self):
        dropped = {'openai/src/client.ts', '@anthropic-ai/sdk/src/client.ts', '@js-temporal/polyfill/lib/instant.ts',
                   'minisearch/src/MiniSearch.ts', 'openai/index.d.mts.map',
                   'openai/internal/auth/x509-transport-state.d.cts.map', 'koffi/src/koffi/src/call.cc',
                   'koffi/lib/native/base/base.hh', 'koffi/vendor/node-addon-api/napi.h',
                   '@agentclientprotocol/sdk/dist/acp.test.js', '@agentclientprotocol/sdk/dist/v2/acp.test.js'}
        kept = {
            'openai/index.js', '@anthropic-ai/sdk/index.mjs', '@js-temporal/polyfill/dist/index.cjs',
            'openai/src/internal/auth/x509-transport-state.cts',
            'openai/src/internal/qs/LICENSE.md', 'openai/plain.mts.map', 'openai/plain.cts.map',
            'zod/src/index.ts', 'minisearch/dist/es/index.js',
            'koffi/src/koffi/src/static.js', 'koffi/LICENSE.txt', 'other/src/call.cc',
            '@agentclientprotocol/sdk/dist/acp.js', '@agentclientprotocol/sdk/LICENSE', 'other/dist/acp.test.js',
        }
        for relative in dropped | kept:
            path = self.root / 'dsh/node_modules' / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(relative)
        for kind in ('esm', 'cjs'):
            prefix = f'gaxios/build/{kind}'
            test_file = prefix + '/test/test.getch.js'
            dropped.add(test_file)
            kept |= {prefix + '/src/index.js', 'gaxios/LICENSE'}
            for relative in (test_file, prefix + '/src/index.js', 'gaxios/LICENSE'):
                path = self.root / 'dsh/node_modules' / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(relative)
        before, _ = self.build('ts-source-unpruned')
        after, command = self.command('ts-source-pruned')
        result = subprocess.run(command + ['--prune-dev-metadata'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        original = members(before / 'engine-arm64-v8a.tar.gz')
        candidate = members(after / 'engine-arm64-v8a.tar.gz')
        removed = {'opt/dsh/node_modules/' + relative for relative in dropped}
        self.assertTrue({'opt/dsh/node_modules/' + relative for relative in dropped | kept} <= original.keys())
        self.assertEqual(candidate, {path: value for path, value in original.items() if path not in removed})
        self.assertEqual((before / 'base-arm64-v8a.tar.gz').read_bytes(),
                         (after / 'base-arm64-v8a.tar.gz').read_bytes())

    def test_assembly_without_file_digest_keeps_archives_and_report(self):
        # Simulate the missing Python 3.11 API, not a different interpreter.
        runner = ('import hashlib, runpy, sys; '
                  'hashlib.__dict__.pop("file_digest", None); '
                  'sys.argv = sys.argv[1:]; '
                  'runpy.run_path(sys.argv[0], run_name="__main__")')
        for name, layered in (('legacy', False), ('layers', True)):
            with self.subTest(layered=layered):
                baseline, report = self.build(name + '-baseline', layered=layered)
                out, command = self.command(name + '-without-file-digest', layered=layered)
                if layered:
                    # Exercise a fresh base build, rather than reusing the baseline archive.
                    command[command.index('--base-cache') + 1] = str(out / 'cache')
                result = subprocess.run(command[:2] + ['-c', runner] + command[2:],
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads((out / 'report.json').read_text()), report)
                expected = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                            for p in baseline.glob('*.tar.gz')}
                actual = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                          for p in out.glob('*.tar.gz')}
                self.assertEqual(actual, expected)

    def test_layers_reconstruct_legacy_tree_and_manifest_contract(self):
        old_dir, old_report = self.build('legacy', layered=False)
        out, report = self.build('layers')
        old = members(old_dir / 'rootfs.tar.gz')
        base = members(out / 'base-arm64-v8a.tar.gz')
        engine = members(out / 'engine-arm64-v8a.tar.gz')
        for path in base.keys() & engine.keys():
            self.assertEqual(base[path][0], tarfile.DIRTYPE)
            self.assertEqual(base[path], engine[path])
        for path in base:
            self.assertFalse(any(path == p or path.startswith(p + '/') for p in rt.ENGINE_PATHS), path)
        for path in engine:
            if not any(path == p or path.startswith(p + '/') for p in rt.ENGINE_PATHS):
                self.assertEqual(engine[path][0], tarfile.DIRTYPE)
                self.assertTrue(any(p.startswith(path + '/') for p in rt.ENGINE_PATHS), path)
        combined = {**base, **engine}
        runtime_path = 'etc/dsh-app/runtime.json'
        updated = json.loads(combined[runtime_path][3])
        self.assertEqual(updated.pop('baseCompatibility'), report['baseCompatibility'])
        self.assertEqual(updated, json.loads(old[runtime_path][3]))
        self.assertEqual(combined[runtime_path][:3] + combined[runtime_path][4:],
                         old[runtime_path][:3] + old[runtime_path][4:])
        combined[runtime_path] = old[runtime_path]
        self.assertEqual(combined, old)
        self.assertEqual(report['counts'], old_report['counts'])
        self.assertEqual(report['upgrade'], old_report['upgrade'])
        manifest = self.manifest(out)
        self.assertEqual(manifest['schema'], 2)
        for field in ('rootfs', 'rootfsSha256', 'rootfsFormat', 'tarSha256'):
            self.assertNotIn(field, manifest)
        self.assertEqual(manifest['baseCompatibility'], report['baseCompatibility'])
        self.assertEqual(manifest['baseCompatibility']['python3Sha256'],
                         hashlib.sha256(b'python fixture').hexdigest())
        self.assertEqual(manifest['upgrade'], old_report['upgrade'])
        for total, field in (('rootfsBytes', 'bytes'), ('tarBytes', 'tarBytes'),
                             ('uncompressedBytes', 'uncompressedBytes')):
            self.assertEqual(manifest[total], sum(layer[field] for layer in manifest['layers'].values()))
        for layer in manifest['layers'].values():
            data = (out / layer['asset']).read_bytes()
            self.assertEqual(layer['bytes'], len(data))
            self.assertEqual(layer['sha256'], hashlib.sha256(data).hexdigest())
            tar = gzip.decompress(data)
            self.assertEqual(layer['tarBytes'], len(tar))
            self.assertEqual(layer['tarSha256'], hashlib.sha256(tar).hexdigest())
            self.assertEqual(layer['uncompressedBytes'], sum(len(row[3]) for row in
                             members(out / layer['asset']).values() if row[3] is not None))

    @unittest.skipUnless(shutil.which('xz'), 'xz is unavailable')
    def test_real_xz_layer_cli_and_manifest(self):
        out, _ = self.build('xz-layers', compress='xz')
        manifest = self.manifest(out)
        for kind, layer in manifest['layers'].items():
            self.assertEqual(layer['asset'], kind + '-arm64-v8a.tar.xz')
            data = (out / layer['asset']).read_bytes()
            self.assertEqual(layer['sha256'], hashlib.sha256(data).hexdigest())
            tar = lzma.decompress(data)
            self.assertEqual(layer['tarBytes'], len(tar))
            self.assertEqual(layer['tarSha256'], hashlib.sha256(tar).hexdigest())

    def test_engine_only_changes_reuse_base_bytes(self):
        out, first = self.build('first')
        base_bytes = (out / first['layers']['base']['asset']).read_bytes()
        previous_engine = first['layers']['engine']['sha256']
        for change in ('runtimeVersion', 'node', 'dsh', 'bridge'):
            with self.subTest(change=change):
                if change == 'runtimeVersion':
                    self.versions['runtimeVersion'] = 'updated-engine'
                elif change == 'node':
                    archive(self.node, [('node/bin/node', 'file', 'updated node fixture', 0o755)])
                else:
                    getattr(self, change).write_text('updated ' + change)
                out, report = self.build('changed-' + change)
                self.assertEqual(report['baseCache']['status'], 'reused')
                self.assertEqual(report['baseCache']['key'], first['baseCache']['key'])
                self.assertEqual(report['layers']['base'], first['layers']['base'])
                self.assertEqual((out / report['layers']['base']['asset']).read_bytes(), base_bytes)
                self.assertEqual(report['upgrade'], first['upgrade'])
                self.assertNotEqual(report['layers']['engine']['sha256'], previous_engine)
                previous_engine = report['layers']['engine']['sha256']

    def test_no_python_is_explicit_null_in_both_documents(self):
        out, report = self.build('without-python', with_python=False)
        self.assertIsNone(report['baseCompatibility']['python3Sha256'])
        manifest = self.manifest(out)
        embedded = json.loads(members(out / 'engine-arm64-v8a.tar.gz')['etc/dsh-app/runtime.json'][3])
        self.assertEqual(embedded['baseCompatibility'], manifest['baseCompatibility'])
        self.assertIn('python3Sha256', embedded['baseCompatibility'])

    def test_tree_read_error_aborts_assembly_without_success_report(self):
        real_scandir = os.scandir
        for layered in (False, True):
            for relative in ('dsh/node_modules', 'pnpm/node_modules/pnpm/bin', 'bridge/lib'):
                with self.subTest(layered=layered, directory=relative):
                    out, command = self.command(
                        'denied-%s-%s' % (layered, relative.split('/')[0]), layered=layered)
                    denied = self.root / relative
                    problem = PermissionError(errno.EACCES, 'synthetic directory read failure', str(denied))

                    def scandir(path):
                        if Path(path) == denied:
                            raise problem
                        return real_scandir(path)

                    with mock.patch.object(sys, 'argv', command[2:]), \
                            mock.patch.object(os, 'scandir', side_effect=scandir), \
                            mock.patch.object(sys, 'stdout', io.StringIO()):
                        with self.assertRaises(PermissionError) as raised:
                            rt.main()
                    self.assertIs(raised.exception, problem)
                    self.assertFalse((out / 'report.json').exists())

    def test_cli_requires_one_mode_and_stable_layer_names(self):
        for name, change in (
            ('mixed', lambda command: command + ['--out', 'rootfs.tar.gz']),
            ('unpaired', lambda command: command[:command.index('--engine-out')]),
            ('name', lambda command: [x.replace('base-arm64-v8a.tar.gz', 'custom.tar.gz') for x in command]),
        ):
            with self.subTest(name=name):
                out, command = self.command(name)
                result = subprocess.run(change(command), capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((out / 'report.json').exists())

    def test_manifest_rejects_mixed_or_wrong_abi_report(self):
        out, report = self.build('manifest-input')
        for name in ('mixed', 'abi'):
            with self.subTest(name=name):
                changed = copy.deepcopy(report)
                if name == 'mixed':
                    changed['archive'] = 'rootfs.tar.gz'
                else:
                    changed['layers']['base']['asset'] = 'base-x86_64.tar.gz'
                (out / 'report.json').write_text(json.dumps(changed))
                self.assertNotEqual(self.manifest(out, check=False).returncode, 0)
                self.assertFalse((out / 'manifest.json').exists())


class BaseCache(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.args = SimpleNamespace(abi='arm64-v8a', compress='gz', gzip_level=9,
                                    xz_preset='6', threads=4, epoch=1767225600,
                                    base_cache=str(self.root / 'cache'))
        self.entries = {'etc': rt.Entry('dir', 0o755),
                        'etc/os-release': rt.Entry('file', 0o644, data=b'ID=ubuntu\nVERSION_ID="24.04"\n'),
                        'etc/release-link': rt.Entry('symlink', 0o777, link='os-release')}
        self.sources = {'ubuntu': 'original-ubuntu-sha', 'debs': ['deb-a', 'deb-b'], 'python': None}
        self.out = str(self.root / 'base.tar.gz')

    def write(self):
        return rt.write_base_archive(self.entries, self.out, self.args, self.sources)

    def test_key_covers_inputs_and_final_tree_without_changing_base_id(self):
        self.args.compress = 'xz'
        key = rt.base_cache_identity(self.entries, self.args, self.sources)[0]
        changes = (
            ('abi', 'x86_64'), ('epoch', self.args.epoch + 1), ('compress', 'gz'),
            ('threads', 1), ('threads', 0), ('xz_preset', '7'),
        )
        for field, value in changes:
            with self.subTest(field=field, value=value):
                args = copy.copy(self.args)
                setattr(args, field, value)
                self.assertNotEqual(key, rt.base_cache_identity(self.entries, args, self.sources)[0])
        for field, value in (('ubuntu', 'another-ubuntu'), ('python', 'a-python'),
                             ('debs', ['deb-b', 'deb-a'])):
            source = {**self.sources, field: value}
            self.assertNotEqual(key, rt.base_cache_identity(self.entries, self.args, source)[0])
        self.assertEqual(rt.upgrade_descriptor('arm64-v8a', '24.04', 'u', ['a', 'b'], None),
                         rt.upgrade_descriptor('arm64-v8a', '24.04', 'u', ['b', 'a'], None))
        for field, value in (('mode', 0o600), ('data', b'changed base content')):
            entries = copy.deepcopy(self.entries)
            setattr(entries['etc/os-release'], field, value)
            self.assertNotEqual(key, rt.base_cache_identity(entries, self.args, self.sources)[0])
        entries = copy.deepcopy(self.entries)
        entries['etc/release-link'].link = 'another-release'
        self.assertNotEqual(key, rt.base_cache_identity(entries, self.args, self.sources)[0])
        entries = dict(reversed(list(self.entries.items())))
        self.assertEqual(key, rt.base_cache_identity(entries, self.args, self.sources)[0])
        entries['etc/os-release'].origin = 'another source label'
        self.assertEqual(key, rt.base_cache_identity(entries, self.args, self.sources)[0])
        self.args.compress = 'gz'
        gzip_key = rt.base_cache_identity(self.entries, self.args, self.sources)[0]
        self.args.gzip_level = 8
        self.assertNotEqual(gzip_key, rt.base_cache_identity(self.entries, self.args, self.sources)[0])

    @unittest.skipUnless(shutil.which('xz'), 'xz is unavailable')
    def test_valid_xz_cache_is_reused_without_any_compressor_call(self):
        self.args.compress = 'xz'
        self.out = str(self.root / 'base.tar.xz')
        stats, info = self.write()
        original = Path(self.out).read_bytes()
        record_path = Path(self.args.base_cache) / (info['key'] + '.json')
        record = json.loads(record_path.read_text())
        record['compressor']['xz'] = 'synthetic prior host version'
        record_path.write_text(json.dumps(record))
        with mock.patch.object(rt.subprocess, 'Popen', side_effect=AssertionError('compressor must not run')), \
                mock.patch.object(rt.subprocess, 'check_output', side_effect=AssertionError('no version probe')):
            after, reused = self.write()
        self.assertEqual(after, stats)
        self.assertEqual(reused['status'], 'reused')
        self.assertEqual(reused['compressor']['xz'], 'synthetic prior host version')
        self.assertEqual(Path(self.out).read_bytes(), original)

    @unittest.skipUnless(shutil.which('xz'), 'xz is unavailable')
    def test_layer_xz_policy_ignores_ambient_options(self):
        self.args.compress = 'xz'
        self.out = str(self.root / 'base.tar.xz')
        with mock.patch.dict(os.environ, {'XZ_OPT': '--invalid-fixture-option',
                                          'XZ_DEFAULTS': '--another-invalid-fixture-option'}):
            first, info = self.write()
        self.args.base_cache = str(self.root / 'other-cache')
        second, other = self.write()
        self.assertEqual(first, second)
        self.assertEqual(info['key'], other['key'])

    def test_invalid_cache_is_rebuilt_including_tar_hash_only_mismatch(self):
        stats, info = self.write()
        record_path = Path(self.args.base_cache) / (info['key'] + '.json')
        cached = Path(self.args.base_cache) / (info['key'] + '.tar.gz')
        for fault in ('compressed', 'tar', 'metadata', 'missing', 'decode'):
            with self.subTest(fault=fault):
                record = json.loads(record_path.read_text())
                if fault == 'compressed':
                    cached.write_bytes(cached.read_bytes() + b'incomplete-cache-copy')
                elif fault == 'tar':
                    record['archive']['tarSha256'] = '0' * 64
                    record_path.write_text(json.dumps(record))
                elif fault == 'metadata':
                    record_path.write_text('{')
                elif fault == 'missing':
                    record_path.unlink()
                    Path(str(record_path) + '.tmp').write_text('unfinished metadata')
                else:
                    cached.write_bytes(b'not a gzip stream')
                    record['archive']['archiveSha256'] = hashlib.sha256(cached.read_bytes()).hexdigest()
                    record['archive']['archiveBytes'] = cached.stat().st_size
                    record_path.write_text(json.dumps(record))
                after, rebuilt = self.write()
                self.assertEqual(after, stats)
                self.assertEqual(rebuilt['status'], 'rebuilt')
                if fault == 'tar':
                    self.assertIn('tar SHA256', rebuilt['reason'])
                self.assertEqual(self.write()[1]['status'], 'reused')

    def test_failed_rebuild_does_not_publish_a_valid_cache_record(self):
        _, info = self.write()
        original = Path(self.out).read_bytes()
        record = Path(self.args.base_cache) / (info['key'] + '.json')
        previous = record.read_bytes()
        cached = Path(self.args.base_cache) / (info['key'] + '.tar.gz')
        cached.write_bytes(b'interrupted cache archive')
        with mock.patch.object(rt, 'write_archive', side_effect=OSError('synthetic compressor failure')):
            with self.assertRaisesRegex(OSError, 'synthetic compressor failure'):
                self.write()
        self.assertEqual(Path(self.out).read_bytes(), original)
        self.assertEqual(record.read_bytes(), previous)
        self.assertEqual(cached.read_bytes(), b'interrupted cache archive')

    def test_compatibility_resolves_parent_and_file_links_without_host_reads(self):
        entries = {
            'etc': rt.Entry('dir', 0o755), 'usr': rt.Entry('dir', 0o755),
            'usr/lib': rt.Entry('dir', 0o755),
            'usr/lib/os-release': self.entries['etc/os-release'],
            'etc/os-release': rt.Entry('symlink', 0o777, link='../usr/lib/os-release'),
            'opt': rt.Entry('dir', 0o755), 'opt/python': rt.Entry('dir', 0o755),
            'opt/python/bin': rt.Entry('symlink', 0o777, link='executables'),
            'opt/python/executables': rt.Entry('dir', 0o755),
            'opt/python/executables/python3': rt.Entry('symlink', 0o777, link='python3.14'),
            'opt/python/executables/python3.14': rt.Entry('file', 0o755, data=b'python fixture'),
        }
        with mock.patch('builtins.open', side_effect=AssertionError('host filesystem read')):
            evidence = rt.base_compatibility(entries, with_python=True)
        self.assertEqual(evidence['osRelease'], {'ID': 'ubuntu', 'VERSION_ID': '24.04'})
        self.assertEqual(evidence['python3Sha256'], hashlib.sha256(b'python fixture').hexdigest())
        self.assertIsNone(rt.base_compatibility(self.entries, with_python=False)['python3Sha256'])
        with self.assertRaises(SystemExit):
            rt.base_compatibility(self.entries, with_python=True)
        entries['opt/python/executables/python3'].link = 'python3'
        with self.assertRaisesRegex(SystemExit, 'too many archive links'):
            rt.base_compatibility(entries, with_python=True)


if __name__ == '__main__':
    unittest.main(verbosity=2)
