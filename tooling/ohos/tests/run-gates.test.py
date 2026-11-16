#!/usr/bin/env python3
"""Exercise the gate runner with real children, including deceptive exit-zero skips."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('gates', ROOT / 'tooling/ohos/run-gates.py')
gates = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gates)


class SourceInventoryContract(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / 'source'
        self.root.mkdir()

    def test_ignored_directory_link_remains_ignored_after_target_removal(self):
        target = self.base / 'external-target'
        target.mkdir()
        (target / 'dependency.js').write_text('owned fixture')
        (self.root / 'node_modules').symlink_to(target, target_is_directory=True)
        before = gates.source_files(self.root)
        self.assertEqual(before, {})
        shutil.rmtree(target)
        self.assertEqual(gates.source_files(self.root), before)

    def test_custom_ignored_names_cover_files_and_directory_links(self):
        target = self.base / 'external-target'
        target.mkdir()
        (self.root / 'skip-file').write_text('excluded')
        (self.root / 'skip-link').symlink_to(target, target_is_directory=True)
        ignored = {'skip-file', 'skip-link'}
        self.assertEqual(gates.source_files(self.root, ignored=ignored), {})
        target.rmdir()
        self.assertEqual(gates.source_files(self.root, ignored=ignored), {})

    def test_nonignored_link_identity_and_file_bytes_and_mode_stay_protected(self):
        target = self.base / 'external-target'
        target.mkdir()
        link = self.root / 'source-link'
        link.symlink_to(target, target_is_directory=True)
        source = self.root / 'source.js'
        source.write_text('before')
        source.chmod(0o644)
        before = gates.source_files(self.root)
        self.assertEqual(before['source-link'], {'type': 'symlink', 'target': str(target)})
        target.rmdir()
        self.assertEqual(gates.source_files(self.root), before)
        link.unlink()
        link.symlink_to(self.base / 'other-missing')
        self.assertNotEqual(gates.source_files(self.root)['source-link'], before['source-link'])
        source.write_text('after!')  # Same length: SHA, not size, must detect it.
        self.assertNotEqual(gates.source_files(self.root)['source.js']['sha256'], before['source.js']['sha256'])
        source.write_text('before')
        source.chmod(0o755)
        self.assertNotEqual(gates.source_files(self.root)['source.js']['mode'], before['source.js']['mode'])

    def test_empty_ignored_keeps_build_and_node_modules_source_and_rejects_links(self):
        lib = self.root / 'app/lib'
        (lib / 'build').mkdir(parents=True)
        source = lib / 'build/owned.dart'
        source.write_text('source')
        (lib / 'node_modules').write_text('also source')
        before = gates.source_files(lib, ignored=())
        self.assertEqual(set(before), {'build/owned.dart', 'node_modules'})
        protected = gates.flutter_inputs(self.root)
        self.assertIn('app/lib/build/owned.dart', protected)
        self.assertIn('app/lib/node_modules', protected)
        source.write_text('changed')
        self.assertNotEqual(gates.flutter_inputs(self.root), protected)
        (lib / 'node_modules').unlink()
        target = self.base / 'external-target'
        target.mkdir()
        (lib / 'node_modules').symlink_to(target, target_is_directory=True)
        before = gates.source_files(lib, ignored=())
        with self.assertRaisesRegex(ValueError, 'symlink'):
            gates.flutter_inputs(self.root)
        target.rmdir()
        self.assertEqual(gates.source_files(lib, ignored=()), before)
        with self.assertRaisesRegex(ValueError, 'symlink'):
            gates.flutter_inputs(self.root)


class RunnerContract(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        source = root / 'source'
        (source / 'tooling/ohos').mkdir(parents=True)
        (source / 'tooling/ohos/gate-coverage.json').write_text(json.dumps({
            'wrappers': {}, 'historicalOrResearchOnly': {}}))
        for directory in ('app/android', 'app/lib', 'app/test', 'packages/dsh_client/lib', 'packages/dsh_remote/lib'):
            (source / directory).mkdir(parents=True, exist_ok=True)
        (source / 'app/lib/current.dart').write_text('candidate source')
        (source / 'packages/dsh_client/lib/client.dart').write_text('candidate client')
        original = gates.REPOSITORY
        gates.REPOSITORY = source
        self.addCleanup(setattr, gates, 'REPOSITORY', original)
        config = root / 'config.json'
        node = Path(shutil.which('node')).resolve()
        config.write_text(json.dumps({'schema': 1, 'paths': {
            'node_root': str(node.parent.parent), 'cxx': shutil.which('c++')}}))
        self.g = gates.Gates(argparse.Namespace(out=root / 'out', config=config))

    def test_install_record_wire_rejects_absent_or_partial_producer(self):
        path = self.g.out / 'install-record-wire.json'
        with self.assertRaises(gates.Blocked): gates.verify_install_record_wire(path)
        for records in ([], [{'name': 'json'}], [{'name': 'json'}, {'name': 'schema'}]):
            path.write_text(json.dumps(records))
            with self.assertRaises(ValueError): gates.verify_install_record_wire(path)

    def test_flutter_generated_android_files_cannot_pollute_native_identity_tree(self):
        code = "from pathlib import Path; Path('android/local.properties').write_text('sdk.dir=fixture'); p=Path('android/app/src/main/java/GeneratedPluginRegistrant.java'); p.parent.mkdir(parents=True); p.write_text('generated fixture')"
        self.assertTrue(self.g.run('flutter-generator-probe', [sys.executable, '-c', code], cwd=self.g.flutter_source / 'app'))
        self.assertFalse((self.g.source / 'app/android/local.properties').exists())
        self.assertFalse((gates.REPOSITORY / 'app/android/local.properties').exists())
        self.assertTrue((self.g.flutter_source / 'app/android/local.properties').exists())

    def test_flutter_identity_rejects_changed_dart_or_new_test_code(self):
        root = self.g.flutter_source
        current = root / 'app/lib/current.dart'
        current.write_text('older good source')
        with self.assertRaisesRegex(ValueError, 'current.dart'):
            gates.verify_flutter_inputs(root, self.g.flutter_original_inputs)
        current.write_text('candidate source')
        (root / 'app/test/injected.dart').write_text('unexpected test code')
        with self.assertRaisesRegex(ValueError, 'injected.dart'):
            gates.verify_flutter_inputs(root, self.g.flutter_original_inputs)

    def test_flutter_generated_failure_images_are_recorded_without_changing_inputs(self):
        path = self.g.flutter_source / 'app/test/failures/actual.png'
        path.parent.mkdir(); path.write_bytes(b'explicit artifact fixture')
        proof = gates.verify_flutter_inputs(self.g.flutter_source, self.g.flutter_original_inputs)
        self.assertIn('app/test/failures/actual.png', proof['generatedFiles'])
        self.assertEqual(proof['originalInputFilesUnchanged'], len(self.g.flutter_original_inputs))

    def test_flutter_l10n_outputs_can_regenerate_but_other_code_and_missing_outputs_fail(self):
        root = self.g.flutter_source
        path = root / 'app/lib/l10n/gen/app_localizations.dart'
        path.parent.mkdir(parents=True)
        path.write_text('previous generated localization')
        expected = gates.flutter_inputs(root)
        path.write_text('regenerated localization from merged parts')
        proof = gates.verify_flutter_inputs(root, expected)
        self.assertIn('app/lib/l10n/gen/app_localizations.dart', proof['generatedFiles'])
        self.assertEqual(proof['originalInputFilesUnchanged'], len(expected) - 1)
        unexpected = path.with_name('unregistered_generated.dart')
        unexpected.write_text('unexpected executable source')
        with self.assertRaisesRegex(ValueError, 'unregistered_generated.dart'):
            gates.verify_flutter_inputs(root, expected)
        unexpected.unlink()
        path.unlink()
        with self.assertRaisesRegex(ValueError, 'app_localizations.dart'):
            gates.verify_flutter_inputs(root, expected)

    def test_flutter_resolver_cannot_redirect_shared_package_to_an_old_tree(self):
        root = self.g.flutter_source
        config = root / 'app/.dart_tool/package_config.json'; config.parent.mkdir()
        packages = [{'name': 'dsh_app', 'rootUri': '../'},
                    {'name': 'dsh_client', 'rootUri': (root / 'packages/dsh_client').as_uri()},
                    {'name': 'dsh_remote', 'rootUri': (root / 'packages/dsh_remote').as_uri()}]
        for entry in packages: entry['packageUri'] = 'lib/'
        config.write_text(json.dumps({'packages': packages}))
        self.assertEqual(set(gates.verify_flutter_packages(root)), {'dsh_app', 'dsh_client', 'dsh_remote'})
        packages[1]['rootUri'] = (gates.REPOSITORY / 'packages/dsh_client').as_uri()
        config.write_text(json.dumps({'packages': packages}))
        with self.assertRaisesRegex(ValueError, 'escaped Flutter copy: dsh_client'):
            gates.verify_flutter_packages(root)

    def test_flutter_resolver_package_uri_must_select_each_private_lib(self):
        root = self.g.flutter_source
        config = root / 'app/.dart_tool/package_config.json'; config.parent.mkdir()
        packages = [{'name': name, 'rootUri': (root / directory).as_uri(), 'packageUri': 'lib/'}
                    for name, directory in [('dsh_app', 'app'), ('dsh_client', 'packages/dsh_client'),
                                            ('dsh_remote', 'packages/dsh_remote')]]
        for entry in packages:
            for bad in ('test/old-good/', '../old-good/', 'lib/?redirect=1', ''):
                with self.subTest(package=entry['name'], packageUri=bad):
                    entry['packageUri'] = bad
                    config.write_text(json.dumps({'packages': packages}))
                    with self.assertRaisesRegex(ValueError, 'packageUri'):
                        gates.verify_flutter_packages(root)
            entry['packageUri'] = 'lib/'
        config.write_text(json.dumps({'packages': packages}))
        self.assertEqual(len(gates.verify_flutter_packages(root)), 3)
        lib = root / 'packages/dsh_client/lib'
        saved = lib.with_name('saved-lib'); lib.rename(saved)
        lib.symlink_to(saved, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'private lib'):
            gates.verify_flutter_packages(root)

    def test_flutter_inputs_reject_untracked_symlink_files_and_directories(self):
        root = self.g.flutter_source
        outside = root.parent / 'outside.dart'; outside.write_text('old good source')
        for relative, target in [('packages/dsh_client/lib/redirect.dart', outside),
                                 ('app/test/redirected-tests', outside.parent),
                                 ('app/lib/build/redirect.dart', outside),
                                 ('app/lib', root / 'packages/dsh_client/lib')]:
            with self.subTest(path=relative):
                link = root / relative
                link.parent.mkdir(parents=True, exist_ok=True)
                saved = link.with_name(link.name + '-original') if link.exists() else None
                if saved is not None: link.rename(saved)
                link.symlink_to(target, target_is_directory=target.is_dir())
                try:
                    with self.assertRaisesRegex(ValueError, 'symlink'):
                        gates.flutter_inputs(root)
                finally:
                    link.unlink()
                    if saved is not None: saved.rename(link)

    def test_skipped_assertions_cannot_make_a_successful_group(self):
        suite = self.g.source / 'skipped.test.mjs'
        suite.write_text("import test from 'node:test'; test('not executed', { skip: true }, () => {});\n")
        self.assertFalse(self.g.run('skipped', ['node', '--test', '--test-reporter=tap', suite]))
        self.assertEqual(self.g.results['skipped'], 'INCOMPLETE')
        self.assertNotEqual(self.g.finish(), 0)

    def test_wrapper_hidden_skip_cannot_pass_on_parent_json_and_exit_zero(self):
        suite = self.g.source / 'wrapped.test.mjs'
        suite.write_text("import test from 'node:test'; test('not executed', { skip: true }, () => {});\n")
        output = self.g.out / 'git-client-marker'
        output.mkdir()
        code = ("import subprocess,json; from pathlib import Path; "
                "r=subprocess.run(['node','--test','--test-reporter=tap'," + repr(str(suite)) + "],capture_output=True,text=True); "
                "Path(" + repr(str(output / 'stdout.log')) + ").write_text(r.stdout); "
                "print(json.dumps({'exitCode':r.returncode,'summary':[v for v in r.stdout.splitlines() if v.startswith('# ')]})); "
                "raise SystemExit(r.returncode)")
        self.assertFalse(self.g.run('git-client-marker', [sys.executable, '-c', code]))
        self.assertEqual(self.g.results['git-client-marker'], 'INCOMPLETE')

    def test_inherited_source_override_cannot_replace_private_candidate(self):
        candidate = gates.REPOSITORY / 'candidate.ets'
        candidate.write_text('broken')
        outside = self.g.out.parent / 'old-good.ets'
        outside.write_text('good')
        with patch.dict(os.environ, {'OHOS_APP_LINKS_SOURCE': str(outside)}):
            actual = gates.Gates(argparse.Namespace(out=self.g.out.parent / 'isolated', config=self.g.args.config))
        code = ("import os; from pathlib import Path; "
                "p=Path(os.environ.get('OHOS_APP_LINKS_SOURCE'," + repr(str(actual.source / 'candidate.ets')) + ")); "
                "raise SystemExit(0 if p.read_text()=='good' else 3)")
        self.assertFalse(actual.run('source-selection', [sys.executable, '-c', code]))
        self.assertNotIn('OHOS_APP_LINKS_SOURCE', actual.base_env)
        self.assertEqual(actual.rows[0]['exitCode'], 3)

    def test_flutter_json_skipped_success_is_incomplete(self):
        # Fixed official test_core reporter fields; this exercises aggregation,
        # not a claim of having run a Flutter engine in this unit fixture.
        events = [{'type': 'testDone', 'testID': 1, 'result': 'success', 'skipped': True, 'hidden': False},
                  {'type': 'done', 'success': True}]
        code = "import json; events=" + repr(events) + "; [print(json.dumps(e)) for e in events]"
        self.assertFalse(self.g.run('flutter-consumers', [sys.executable, '-c', code]))
        self.assertEqual(self.g.results['flutter-consumers'], 'INCOMPLETE')

    def test_scoped_inventory_exit_zero_retains_full_inventory_incomplete(self):
        report = self.g.out / 'dart-bridge-inventory.json'
        report.write_text(json.dumps({'gateStatus': 'PASS_SCOPED', 'fullInventoryStatus': 'INCOMPLETE'}))
        self.assertFalse(self.g.run('dart-bridge-inventory', [sys.executable, '-c', 'raise SystemExit(0)']))
        self.assertEqual(self.g.results['dart-bridge-inventory'], 'INCOMPLETE')
        self.assertEqual(self.g.rows[-1]['inventoryStatus']['gateStatus'], 'PASS_SCOPED')

    def test_failed_prerequisite_blocks_child_without_executing_it(self):
        self.g.run('failed', [sys.executable, '-c', 'raise SystemExit(7)'])
        marker = self.g.out / 'must-not-exist'
        self.g.run('dependent', [sys.executable, '-c', 'from pathlib import Path; Path(' + repr(str(marker)) + ').touch()'], needs=('failed',))
        self.assertEqual(self.g.results['dependent'], 'BLOCKED_NOT_RUN')
        self.assertFalse(marker.exists())
        self.assertEqual(self.g.rows[0]['exitCode'], 7)

    def test_missing_tool_is_not_a_passing_consumer(self):
        self.g.run('dart-consumer', lambda: [self.g.path('dart'), '--version'])
        self.assertEqual(self.g.results['dart-consumer'], 'BLOCKED_NOT_RUN')
        self.assertIsNone(self.g.rows[0]['exitCode'])

    def test_exit_zero_report_without_real_consumer_is_rejected(self):
        diagnostics = self.g.out / 'diagnostics-dart'
        diagnostics.mkdir()
        (diagnostics / 'commands.json').write_text(json.dumps([{'argv': ['node', 'test'], 'exit': 0}]))
        with self.assertRaisesRegex(ValueError, 'actual Dart consumer'):
            gates.verify_dart_consumers(self.g.out)

    def test_diagnostics_cli_requires_dart_before_running_native_work(self):
        result = subprocess.run([sys.executable, str(ROOT / 'runtime/tests/ohos/diagnostics-linux.py'),
            '--node', 'missing-node', '--typescript-prefix', 'missing-ts', '--zlib-addon', 'missing-addon',
            '--output', str(self.g.out / 'must-not-start')], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn('--dart', result.stderr)
        self.assertFalse((self.g.out / 'must-not-start').exists())

    def test_success_keeps_command_and_raw_output(self):
        self.assertTrue(self.g.run('passed', [sys.executable, '-c', "print('actual child output')"]))
        self.assertEqual((self.g.out / 'groups/passed/stdout.log').read_text(), 'actual child output\n')
        self.assertEqual(self.g.finish(), 0)


class ProcMappingContract(unittest.TestCase):
    def fixture(self, procfs_pid=5000):
        status = f'Pid:\t{procfs_pid}\nNSpid:\t{procfs_pid} 7\n'
        stat = f'{procfs_pid} (fixture ) with spaces) S ' + ' '.join(['0'] * 18 + ['42'])
        files = {str(Path(directory) / name): value
                 for directory in ('/proc/self', f'/proc/{procfs_pid}')
                 for name, value in [('status', status), ('stat', stat)]}
        links = {'/proc/self': str(procfs_pid), '/proc/self/ns/pid': 'pid:[123]',
                 f'/proc/{procfs_pid}/ns/pid': 'pid:[123]'}
        return files, links

    def probe(self, files, links, late_change=False):
        reads = 0
        def read(path):
            nonlocal reads
            value = files[str(path)]
            if isinstance(value, Exception): raise value
            if str(path) == '/proc/self/stat':
                reads += 1
                if late_change and reads > 1: return value[:-2] + '43'
            return value
        with patch.object(gates.os, 'getpid', return_value=7), \
                patch.object(gates.os, 'readlink', side_effect=lambda path: links[str(path)]), \
                patch.object(gates.Path, 'read_text', read):
            return gates.verify_proc_mapping()

    def test_equal_and_verified_outer_procfs_pids_are_supported(self):
        for outer in (7, 5000):
            with self.subTest(procfsPid=outer):
                result = self.probe(*self.fixture(outer))
                self.assertEqual(result['processPid'], 7)
                self.assertEqual(result['procSelfPid'], outer)
                self.assertEqual(result['starttime'], 42)
                self.assertEqual(result['pidNamespace'], 'pid:[123]')

    def test_inconsistent_missing_and_unreadable_identity_is_blocked(self):
        cases = [('/proc/self/status', 'Pid: 1\nNSpid: 5000 7\n'),
                 ('/proc/self/status', 'Pid: 5000\nNSpid: 5000 8\n'),
                 ('/proc/self/status', 'Pid: 5000\n'),
                 ('/proc/self/status', 'Pid: 5000\nNSpid: 0 7\n'),
                 ('/proc/self/stat', 'malformed'),
                 ('/proc/self/status', PermissionError('fixture denied')),
                 ('/proc/5000/status', 'Pid: 5001\nNSpid: 5000 7\n')]
        for path, value in cases:
            with self.subTest(path=path, value=str(value)):
                files, links = self.fixture(); files[path] = value
                with self.assertRaises(gates.Blocked): self.probe(files, links)
        for path, value in [('/proc/self', '0'), ('/proc/self', 'not-a-pid'),
                            ('/proc/self/ns/pid', 'invalid'), ('/proc/5000/ns/pid', 'pid:[456]')]:
            with self.subTest(link=path, value=value):
                files, links = self.fixture(); links[path] = value
                with self.assertRaises(gates.Blocked): self.probe(files, links)

    def test_starttime_change_during_observation_is_blocked(self):
        with self.assertRaisesRegex(gates.Blocked, 'identity changed'):
            self.probe(*self.fixture(), late_change=True)


if __name__ == '__main__':
    unittest.main()
