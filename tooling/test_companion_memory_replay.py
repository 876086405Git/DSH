"""Reporter semantics only; these do not execute the Dart product."""
import importlib.util
from hashlib import sha256
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


path = Path(__file__).parent / 'companion' / 'replay-memory.py'
spec = importlib.util.spec_from_file_location('memory_replay', path)
replay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(replay)


def start(identifier, name):
    return {'type': 'testStart', 'test': {'id': identifier, 'name': name, 'suiteID': 0}}


def end(identifier, result='success', **extra):
    return {'type': 'testDone', 'testID': identifier, 'result': result,
            'hidden': False, 'skipped': False, **extra}


class ReporterTests(unittest.TestCase):
    def report(self, events):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        path = Path(folder.name) / 'sdk.jsonl'
        path.write_text(''.join(json.dumps(e) + '\n' for e in events), encoding='utf-8')
        return replay.Report(path)

    def test_late_error_overrides_completed_success(self):
        report = self.report([start(1, 'product'), end(1),
            {'type': 'error', 'testID': 1, 'error': 'late callback', 'isFailure': True},
            {'type': 'done', 'success': False}])
        self.assertEqual(report.check('product')[0], 'FAIL')

    def test_skip_and_hidden_loading_are_not_product_passes(self):
        report = self.report([start(1, 'skipped'), end(1, skipped=True),
            start(2, 'loading'), end(2, hidden=True), start(3, 'product'), end(3),
            {'type': 'done', 'success': True}])
        self.assertEqual(report.check('skipped')[0], 'NOT_RUN')
        self.assertEqual(report.check('loading')[0], 'NOT_RUN')
        self.assertEqual(report.check('missing')[0], 'NOT_RUN')
        self.assertEqual(report.check('product')[0], 'PASS')

    def test_interrupted_report_retains_failure_but_not_provisional_success(self):
        report = self.report([start(1, 'bad'), end(1, 'failure'), start(2, 'good'), end(2)])
        self.assertEqual(report.check('bad')[0], 'FAIL')
        self.assertEqual(report.check('good')[0], 'NOT_RUN')
        self.assertEqual(replay.aggregate(['NOT_RUN', 'FAIL']), 'FAIL')

    def test_duplicate_full_names_cannot_silently_choose_a_passing_instance(self):
        report = self.report([start(1, 'same'), end(1), start(2, 'same'), end(2, skipped=True),
            {'type': 'done', 'success': True}])
        self.assertEqual(report.check('same')[0], 'NOT_RUN')

    def test_failed_launch_discards_stale_report(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / '.dart_tool').mkdir()
            for name in ('package_config.json', 'package_graph.json'):
                (root / '.dart_tool' / name).write_text('{}', encoding='utf-8')
            old = root / 'sdk.jsonl'
            old.write_text('old green output', encoding='utf-8')
            data = {'suites': {'sdk': {'guards': ['offline guard'], 'cwd': '.',
                    'command': [str(root / 'missing-dart')]}}, 'cases': []}
            self.assertEqual(replay.run_suites(root, data, root), {'sdk': None})
            self.assertFalse(old.exists())
            self.assertEqual(replay.Report(old).check('product')[0], 'NOT_RUN')

    def test_node_skips_are_not_engine_passes_even_when_node_exits_zero(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'engine.xml'
            path.write_text('<testsuites><testcase name="actual engine"><skipped '
                            'message="Set DSH_PREFIX"/></testcase></testsuites>', encoding='utf-8')
            report = replay.EngineReport(path)
            self.assertEqual(report.check('actual engine'), ('NOT_RUN', 'Set DSH_PREFIX'))

    def test_required_missing_observation_blocks_an_otherwise_green_fixture(self):
        report = self.report([start(1, 'offline guard'), end(1), start(2, 'observed'), end(2),
                              {'type': 'done', 'success': True}])
        data = {'ruleset': '09e-r2+r2.1', 'fixture_version': 1,
                'suites': {'sdk': {'guards': ['offline guard']}},
                'cases': [{'id': 7, 'original_ids': ['07-45'],
                           'checks': [{'id': 'phone', 'suite': 'sdk', 'name': 'observed'}],
                           'required_gaps': [{'id': 'engine-reload', 'reason': 'not observed'}]}]}
        result = replay.collect(data, {'sdk': report}, 'reporter-fixture').pop()
        self.assertEqual(result['status'], 'NOT_RUN')
        self.assertEqual(result['checks'][-1]['id'], 'engine-reload')

    def test_compiled_fixture_catalog_rejects_changed_or_missing_source(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            source = root / 'fixture.dart'
            source.write_bytes(b'compiled synthetic response')
            catalog = root / 'model-fixtures.json'
            catalog.write_text(json.dumps({'fixture_version': 1, 'kind': 'compiled-product-fixtures',
                'sources': [{'path': source.name, 'sha256': sha256(source.read_bytes()).hexdigest()}]}), encoding='utf-8')
            verified = replay.read_fixtures(catalog, root, [source.name])
            self.assertEqual(verified['sha256'], sha256(catalog.read_bytes()).hexdigest())
            source.write_bytes(b'different synthetic response')
            with self.assertRaisesRegex(ValueError, 'fixture source changed'):
                replay.read_fixtures(catalog, root, [source.name])
            source.unlink()
            with self.assertRaises(FileNotFoundError):
                replay.read_fixtures(catalog, root, [source.name])

    def test_catalog_failure_cannot_reuse_an_existing_green_report(self):
        report = self.report([start(1, 'offline guard'), end(1), start(2, 'observed'), end(2),
                              {'type': 'done', 'success': True}])
        data = {'ruleset': '09e-r2+r2.1', 'fixture_version': 1,
                'suites': {'sdk': {'guards': ['offline guard']}},
                'cases': [{'id': 1, 'original_ids': ['07-48'],
                           'checks': [{'id': 'import', 'suite': 'sdk', 'name': 'observed'}]}]}
        result = replay.collect(data, {'sdk': report}, 'unverified', fixture_issue='fixture source changed').pop()
        self.assertEqual(result['status'], 'NOT_RUN')
        self.assertIsNone(result['usage']['requests'])
        self.assertTrue(all(check['status'] == 'NOT_RUN' for check in result['checks']))

    def test_shared_test_and_guard_are_counted_once_across_acceptance_groups(self):
        shared = {'suite': 'sdk', 'test_name': 'same product test', 'status': 'PASS'}
        guard = {'suite': 'sdk', 'test_name': 'offline guard', 'status': 'PASS'}
        rows = [{'checks': [shared, guard]}, {'checks': [shared, guard,
                {'id': 'unobserved', 'status': 'NOT_RUN'}]}]
        self.assertEqual(replay.unique_test_counts(rows), {'PASS': 2})

    def test_dart_guard_cannot_claim_zero_provider_calls_for_an_unrun_engine(self):
        sdk = self.report([start(1, 'offline guard'), end(1), start(2, 'observed'), end(2),
                           {'type': 'done', 'success': True}])
        with tempfile.TemporaryDirectory() as folder:
            xml = Path(folder) / 'engine.xml'
            xml.write_text('<testsuites><testcase name="engine observed"><skipped/></testcase></testsuites>', encoding='utf-8')
            data = {'ruleset': '09e-r2+r2.1', 'fixture_version': 1,
                    'suites': {'sdk': {'guards': ['offline guard']}, 'engine': {'guards': []}},
                    'cases': [{'id': 7, 'original_ids': [], 'checks': [
                        {'id': 'phone', 'suite': 'sdk', 'name': 'observed'},
                        {'id': 'host', 'suite': 'engine', 'name': 'engine observed'}]}]}
            row = replay.collect(data, {'sdk': sdk, 'engine': replay.EngineReport(xml)}, 'reporter-fixture').pop()
            self.assertEqual(row['status'], 'NOT_RUN')
            self.assertIsNone(row['usage']['requests'])

    def cli_fixture(self, folder, exit_code):
        root = Path(folder)
        runner = root / 'tooling/companion/replay-memory.py'
        runner.parent.mkdir(parents=True)
        shutil.copy2(path, runner)
        child = root / 'fixture.py'
        child.write_text('import sys\nprint(\'<testsuites><testcase name="reporter child"/></testsuites>\')\n'
                         f'sys.exit({exit_code})\n', encoding='utf-8')
        data = {'fixture_version': 1, 'ruleset': '09e-r2+r2.1',
                'suites': {'engine': {'guards': [], 'cwd': '.', 'command': [sys.executable, str(child)]}},
                'cases': [{'id': index, 'original_ids': [], 'checks': [
                    {'id': 'child', 'suite': 'engine', 'name': 'reporter child', 'file': child.name}]}
                          for index in range(1, 16)], 'fixture_sources': [child.name], 'limits': []}
        cases = root / 'cases.json'
        cases.write_text(json.dumps(data), encoding='utf-8')
        catalog = root / 'catalog.json'
        catalog.write_text(json.dumps({'fixture_version': 1, 'kind': 'compiled-product-fixtures',
            'sources': [{'path': child.name, 'sha256': sha256(child.read_bytes()).hexdigest()}]}), encoding='utf-8')
        production = root / 'app/lib/companion_memory_rules.dart'
        production.parent.mkdir(parents=True)
        production.write_text('const selected = 1;\n', encoding='utf-8')
        for command in (['git', 'init', '--quiet'], ['git', 'add', '.'],
                        ['git', '-c', 'user.name=Reporter fixture', '-c', 'user.email=reporter@example.invalid',
                         '-c', 'commit.gpgsign=false', 'commit', '--quiet', '-m', 'reporter fixture']):
            subprocess.run(command, cwd=root, capture_output=True, check=True)
        return [sys.executable, str(runner), '--cases', str(cases), '--model-fixtures', str(catalog)]

    def test_recollection_preserves_original_nonzero_child_exit(self):
        with tempfile.TemporaryDirectory() as folder:
            command = self.cli_fixture(folder, exit_code=7)
            original = Path(folder) / 'original'
            imported = Path(folder) / 'imported'
            first = subprocess.run([*command, '--output', str(original)], capture_output=True, text=True, check=False)
            self.assertEqual(first.returncode, 1, first.stderr)
            first_summary = json.loads((original / 'summary.json').read_text())
            second = subprocess.run([*command, '--reports', str(original), '--output', str(imported)],
                                    capture_output=True, text=True, check=False)
            self.assertEqual(second.returncode, 1, second.stderr)
            summary = json.loads((imported / 'summary.json').read_text())
            self.assertEqual(summary['suite_exits'], {'engine': 7})
            self.assertEqual(summary['execution_status'], 'FAIL')
            self.assertEqual(summary['acceptance_status'], 'FAIL')
            self.assertEqual(summary['run_id'], first_summary['run_id'])
            self.assertTrue(summary['collection_only'])
            inputs = json.loads((original / 'run-inputs.json').read_text())
            raw = (original / 'engine.xml').read_bytes()
            self.assertTrue(inputs['execution_complete'])
            self.assertEqual(inputs['report_sha256'], {'engine.xml': sha256(raw).hexdigest()})
            self.assertEqual((imported / 'engine.xml').read_bytes(), raw)

            # A source file changing after parsing must not change the published
            # evidence. This also exercises collecting directly over its input.
            checked = False
            check = replay.EngineReport.check

            def change_after_parse(report, name):
                nonlocal checked
                if not checked:
                    (original / 'engine.xml').write_bytes(b'<testsuites/>')
                    checked = True
                return check(report, name)

            with patch.object(replay, '__file__', command[1]), \
                    patch.object(sys, 'argv', [*command[1:], '--reports', str(original), '--output', str(original)]), \
                    patch.object(replay.EngineReport, 'check', change_after_parse), patch('builtins.print'):
                self.assertEqual(replay.main(), 1)
            self.assertTrue(checked)
            self.assertEqual((original / 'engine.xml').read_bytes(), raw)
            self.assertEqual(json.loads((original / 'run-inputs.json').read_text()), inputs)
            rows = [json.loads(line) for line in (original / 'results.jsonl').read_text().splitlines()]
            self.assertTrue(all(row['status'] == 'PASS' for row in rows))
            self.assertEqual(json.loads((original / 'summary.json').read_text())['suite_exits'], {'engine': 7})

            # Neither HEAD nor the fixture catalog changes when a tracked
            # production file, or an untracked production import, changes.
            production = Path(folder) / 'app/lib/companion_memory_rules.dart'
            before = production.read_bytes()
            extra = production.with_name('new_source.dart')
            for target, content in ((production, b'const selected = 2;\n'),
                                    (extra, b'const added = true;\n')):
                try:
                    target.write_bytes(content)
                    self.assertEqual(subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=folder)
                                     .decode().strip(), inputs['checkout_identity']['head'])
                    self.assertEqual(sha256((Path(folder) / 'catalog.json').read_bytes()).hexdigest(),
                                     inputs['fixture_catalog_sha256'])
                    rejected = subprocess.run([*command, '--reports', str(original), '--output', str(imported)],
                                              capture_output=True, text=True, check=False)
                    self.assertEqual(rejected.returncode, 1, rejected.stderr)
                    rejected_summary = json.loads((imported / 'summary.json').read_text())
                    self.assertFalse(rejected_summary['reports_considered'])
                    self.assertIn('production content', rejected_summary['fixture_issue'])
                    self.assertEqual(rejected_summary['case_counts'], {'NOT_RUN': 15})
                    self.assertEqual(rejected_summary['suite_exits'], {'engine': 7})
                    self.assertFalse((imported / 'run-inputs.json').exists())
                finally:
                    production.write_bytes(before)
                    extra.unlink(missing_ok=True)

            for replacement in (None, b'<testsuites><testcase name="different run"/></testsuites>'):
                try:
                    if replacement is None:
                        (original / 'engine.xml').unlink()
                    else:
                        (original / 'engine.xml').write_bytes(replacement)
                    rejected = subprocess.run([*command, '--reports', str(original), '--output', str(imported)],
                                              capture_output=True, text=True, check=False)
                    self.assertEqual(rejected.returncode, 1, rejected.stderr)
                    rejected_summary = json.loads((imported / 'summary.json').read_text())
                    self.assertFalse(rejected_summary['reports_considered'])
                    self.assertIn('raw report bytes', rejected_summary['fixture_issue'])
                    self.assertEqual(rejected_summary['suite_exits'], {'engine': 7})
                    self.assertFalse((imported / 'run-inputs.json').exists())
                finally:
                    (original / 'engine.xml').write_bytes(raw)

    def test_invalid_cases_replace_old_green_summary_with_current_not_run(self):
        with tempfile.TemporaryDirectory() as folder:
            command = self.cli_fixture(folder, exit_code=0)
            output = Path(folder) / 'result'
            first = subprocess.run([*command, '--output', str(output)], capture_output=True, text=True, check=False)
            self.assertEqual(first.returncode, 0, first.stderr)
            original = json.loads((output / 'summary.json').read_text())
            self.assertEqual(original['execution_status'], 'PASS')
            write_bytes = Path.write_bytes

            def interrupted_copy(target, raw):
                if target == output / 'engine.xml':
                    pending = json.loads((output / 'run-inputs.json').read_text())
                    self.assertFalse(pending['execution_complete'])
                    self.assertFalse((output / 'summary.json').exists())
                    write_bytes(target, b'<partial-new-report')
                    raise OSError('interrupted report copy')
                return write_bytes(target, raw)

            with patch.object(replay, '__file__', command[1]), \
                    patch.object(sys, 'argv', [*command[1:], '--reports', str(output), '--output', str(output)]), \
                    patch.object(Path, 'write_bytes', interrupted_copy):
                with self.assertRaisesRegex(OSError, 'interrupted report copy'):
                    replay.main()
            self.assertFalse(json.loads((output / 'run-inputs.json').read_text())['execution_complete'])
            self.assertFalse((output / 'summary.json').exists())
            self.assertFalse((output / 'results.jsonl').exists())
            rejected = subprocess.run([*command, '--reports', str(output), '--output', str(output)],
                                      capture_output=True, text=True, check=False)
            self.assertEqual(rejected.returncode, 2, rejected.stderr)
            self.assertFalse(json.loads((output / 'summary.json').read_text())['reports_considered'])
            # Only a new real child execution can create a new complete record.
            rerun = subprocess.run([*command, '--output', str(output)], capture_output=True, text=True, check=False)
            self.assertEqual(rerun.returncode, 0, rerun.stderr)
            repaired = json.loads((output / 'run-inputs.json').read_text())
            self.assertTrue(repaired['execution_complete'])
            self.assertEqual(repaired['report_sha256']['engine.xml'],
                             sha256((output / 'engine.xml').read_bytes()).hexdigest())
            cases = Path(folder) / 'cases.json'
            data = json.loads(cases.read_text())
            data['fixture_version'] = 2
            cases.write_text(json.dumps(data), encoding='utf-8')
            second = subprocess.run([*command, '--output', str(output)], capture_output=True, text=True, check=False)
            self.assertEqual(second.returncode, 2, second.stderr)
            summary = json.loads((output / 'summary.json').read_text())
            self.assertEqual(summary['execution_status'], 'NOT_RUN')
            self.assertEqual(summary['acceptance_status'], 'NOT_RUN')
            self.assertFalse(summary['reports_considered'])
            self.assertNotEqual(summary['run_id'], original['run_id'])
            self.assertFalse((output / 'run-inputs.json').exists())
            self.assertFalse((output / 'engine.xml').exists())
            rows = [json.loads(line) for line in (output / 'results.jsonl').read_text().splitlines()]
            self.assertEqual(len(rows), 15)
            self.assertTrue(all(row['status'] == 'NOT_RUN' for row in rows))


if __name__ == '__main__':
    unittest.main()
