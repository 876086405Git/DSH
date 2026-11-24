"""Reporter semantics only; these do not execute the Dart product."""
import importlib.util
import io
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

    def test_non_boolean_done_cannot_certify_a_pass(self):
        for value in (1, 'true', False, None):
            with self.subTest(value=value):
                report = self.report([start(1, 'observed'), end(1),
                                      {'type': 'done', 'success': value}])
                if value is False:
                    self.assertIs(report.success, False)
                    self.assertTrue(report.complete)
                else:
                    self.assertIsNone(report.success)
                    self.assertEqual(report.check('observed')[0], 'NOT_RUN')

    def test_malformed_completion_cannot_hide_a_late_failure_or_leave_a_green_summary(self):
        started = [start(1, 'observed'), end(1)]
        valid = {'type': 'done', 'success': True}
        invalid = {'type': 'done', 'success': 'true'}
        failure = {'type': 'error', 'testID': 1, 'error': 'late callback', 'isFailure': True}
        for tail in ([valid, invalid], [invalid, valid]):
            report = self.report(started + tail)
            self.assertFalse(report.complete)
            self.assertIsNone(report.success)
            self.assertEqual(report.check('observed')[0], 'NOT_RUN')
        report = self.report(started + [invalid, failure, {'type': 'done', 'success': False}])
        self.assertIs(report.success, False)
        self.assertEqual(report.check('observed')[0], 'FAIL')

    def test_cleanup_error_preserves_the_child_exit(self):
        suite = {'command': ['dart', 'test'], 'cwd': '.', 'guards': ['guard']}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = io.StringIO()
            with patch.object(replay.shutil, 'which', return_value='/tools/dart'), \
                    patch.object(replay.subprocess, 'run', return_value=subprocess.CompletedProcess([], 17)), \
                    patch.object(replay.shutil, 'rmtree', side_effect=PermissionError('locked by scanner')), \
                    patch.object(replay.tempfile, 'mkdtemp', return_value=str(root)):
                self.assertEqual(replay.run_windows_suite(root, 'sdk', suite, [], root, log), 17)
            self.assertIn('locked by scanner', log.getvalue())
            self.assertEqual(json.loads((root / 'sdk.jsonl').read_text().splitlines()[1])['exit_code'], 17)

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

        # Independent Dart processes reuse IDs; only the outer batch owns them.
        guard = 'offline guard'
        plan = {'type': 'replayBatchPlan', 'version': 1, 'suite': 'sdk', 'guards': [guard],
                'batches': [{'id': 1, 'names': ['bad']}, {'id': 2, 'names': ['good']}]}
        data = {'suites': {'sdk': {'guards': [guard]}}, 'cases': [{'checks': [
            {'suite': 'sdk', 'name': 'bad'}, {'suite': 'sdk', 'name': 'good'}]}]}

        def encoded(events):
            return ''.join(json.dumps(event, ensure_ascii=False) + '\n' for event in events).encode('utf-8')

        def result(identifier, name, failed=False, guards=1, code=0):
            events = [start(1, guard), end(1)] if guards else []
            if guards == 2:
                events += [start(3, guard), end(3)]
            events += [start(2, name), end(2, 'failure' if failed else 'success'),
                       {'type': 'done', 'success': not failed}]
            return {'type': 'replayBatchResult', 'id': identifier, 'exit_code': code,
                    'report_base64': replay.base64.b64encode(encoded(events)).decode('ascii')}

        def read(events, code=0, tail=b''):
            return replay.dart_report(Path('sdk.jsonl'), encoded(events) + tail, 'sdk', data, code)

        first = result(1, 'bad')
        second = result(2, 'good')
        footer = {'type': 'replayBatchesDone'}
        complete = read([plan, first, second, footer])
        self.assertIsInstance(complete, replay.BatchReport)
        self.assertTrue(complete.success)
        self.assertEqual([complete.check(name)[0] for name in ('bad', 'good', guard)], ['PASS'] * 3)
        self.assertEqual(replay.unique_test_counts([{'checks': [
            {'suite': 'sdk', 'test_name': name, 'status': complete.check(name)[0]}
            for name in ('bad', 'good', guard, guard)]}]), {'PASS': 3})

        # Both assigned cases passed, but the first child also ran a case
        # owned by the second. The mixed archive cannot certify either case.
        mixed_events = [start(1, guard), end(1), start(2, 'bad'), end(2),
                        start(3, 'good'), end(3), {'type': 'done', 'success': True}]
        mixed = {**first, 'report_base64': replay.base64.b64encode(encoded(mixed_events)).decode('ascii')}
        unexpected = read([plan, mixed, second, footer])
        self.assertFalse(unexpected.complete)
        self.assertEqual(unexpected.check('good')[0], 'NOT_RUN')

        failure = result(1, 'bad', failed=True)
        for events, tail in (([plan, failure, second], b''),
                             ([plan, failure, second, footer], b'{bad json\n')):
            interrupted = read(events, tail=tail)
            self.assertIs(interrupted.success, False)
            self.assertEqual(interrupted.check('bad')[0], 'FAIL')
            self.assertEqual(interrupted.check('good')[0], 'NOT_RUN')

        for events in ([plan, first, second], [plan, first, footer],
                       [plan, first, first, second, footer],
                       [plan, first, {**second, 'id': 9}, footer],
                       [plan, first, {**second, 'report_base64': '!not base64'}, footer],
                       [plan, first, result(2, 'good', guards=0), footer],
                       [plan, first, result(2, 'good', guards=2), footer],
                       [plan, first, {**second, 'exit_code': True}, footer]):
            incomplete = read(events)
            self.assertIsNone(incomplete.success)
            self.assertEqual(incomplete.check('bad')[0], 'NOT_RUN')
        malformed_after_failure = read([plan, failure, {**second, 'report_base64': '!bad'}, footer])
        self.assertIs(malformed_after_failure.success, False)
        self.assertEqual(malformed_after_failure.check('bad')[0], 'FAIL')
        self.assertEqual(malformed_after_failure.check('good')[0], 'NOT_RUN')

        nonzero = [plan, {**first, 'exit_code': 7}, {**second, 'exit_code': 9}, footer]
        self.assertEqual(replay.batch_exit([7, 9, None]), 7)
        self.assertIs(read(nonzero, code=7).success, False)
        mismatch = read(nonzero, code=0)
        self.assertIs(mismatch.success, False)
        self.assertEqual(mismatch.check('good')[0], 'NOT_RUN')
        unknown_exit = read([plan, {**first, 'exit_code': None, 'report_base64': None}, second, footer], code=None)
        self.assertIsNone(unknown_exit.success)
        self.assertEqual(unknown_exit.check('good')[0], 'NOT_RUN')
        invalid_version = read([{**plan, 'version': 2}, first, second, footer])
        self.assertIsInstance(invalid_version, replay.BatchReport)
        self.assertIsNone(invalid_version.success)
        self.assertEqual(invalid_version.check('good')[0], 'NOT_RUN')
        duplicate_name = {**plan, 'batches': [{'id': 1, 'names': ['bad']}, {'id': 2, 'names': ['bad', 'good']}]}
        self.assertIsNone(read([duplicate_name, first, second, footer]).success)

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

        # Exercise the Windows boundary directly without changing os.name for
        # pathlib or the other eleven original test bodies.
        executable = r'C:\Tools (50%)\中文!\flutter.bat'
        comspec = r'C:\Windows (system)\cmd.exe'
        expression = r'^(?:中文|%literal%|a (b)|!|😀|\^\$)$'
        environment = {'COMSPEC': 'actual-cmd', 'PATH': 'actual-path', 'PATHEXT': '.EXE;.BAT;.CMD'}
        launch = replay.windows_command([executable, expression], environment, comspec)
        raw = f'"{comspec}" /d /v:off /s /c ""%DSH_REPLAY_EXE%" "%DSH_REPLAY_ARG_0%""'
        expanded = f'"{comspec}" /d /v:off /s /c ""{executable}" "{expression}""'
        self.assertEqual(launch['args'], raw)
        self.assertEqual(launch['units'], [len(value.encode('utf-16-le')) // 2 + 1 for value in (raw, expanded)])
        self.assertEqual(launch['limit'], 8191)
        self.assertEqual(launch['options'], {'executable': comspec, 'shell': False,
            'env': {**environment, 'DSH_REPLAY_EXE': executable, 'DSH_REPLAY_ARG_0': expression}})
        self.assertNotIn('DSH_REPLAY_EXE', environment)
        for unsupported in ('"', '\r', '\n', '\0'):
            with self.assertRaisesRegex(ValueError, 'not representable'):
                replay.windows_command([executable, 'name' + unsupported], environment, comspec)
        direct = [r'C:\Tools (x)\dart.exe', 'a "b" 😀']
        exe_launch = replay.windows_command(direct, environment)
        self.assertEqual(exe_launch['args'], direct)
        self.assertEqual(exe_launch['limit'], 32767)
        self.assertEqual(exe_launch['units'], [len(subprocess.list2cmdline(direct).encode('utf-16-le')) // 2 + 1])

        with tempfile.TemporaryDirectory(prefix='回放 (space) %literal% ! ') as folder:
            root = Path(folder)
            manifest = json.loads(path.with_name('memory-replay-cases.json').read_text(encoding='utf-8'))
            resolved_comspec = str(root / 'Windows (system)' / 'cmd.exe')
            resolved = {'dart': str(root / '工具 (50%) 中文!' / 'dart.bat'),
                        'flutter': str(root / '工具 (50%) 中文!' / 'flutter.cmd'), 'actual-cmd': resolved_comspec}
            for key in ('sdk', 'app'):
                suite = manifest['suites'][key]
                ordinary = {check['name'] for case in manifest['cases'] for check in case['checks']
                            if check['suite'] == key}.difference(suite['guards'])
                expected = ordinary.union(suite['guards'])
                raw_children = []

                def child(command, **kwargs):
                    self.assertIsInstance(command, str)
                    self.assertEqual(kwargs['executable'], resolved_comspec)
                    self.assertIs(kwargs['shell'], False)
                    self.assertEqual(kwargs['cwd'], root / suite['cwd'])
                    variables = replay.re.findall(r'"%(DSH_REPLAY_(?:EXE|ARG_\d+))%"', command)
                    actual = [kwargs['env'][variable] for variable in variables]
                    self.assertEqual(actual[:len(suite['command'])], [resolved[suite['command'][0]], *suite['command'][1:]])
                    expanded = f'"{resolved_comspec}" /d /v:off /s /c "' + ' '.join(f'"{value}"' for value in actual) + '"'
                    self.assertTrue(all(len(value.encode('utf-16-le')) // 2 + 1 <= 8191 for value in (command, expanded)))
                    self.assertTrue(actual[-1].startswith('json:'))
                    pattern = actual[actual.index('--name') + 1]
                    selected = sorted(name for name in expected if replay.re.fullmatch(pattern, name))
                    self.assertTrue(set(suite['guards']).issubset(selected))
                    self.assertTrue(all(replay.re.fullmatch(pattern, name + ' extra') is None for name in selected))
                    events = []
                    for identifier, name in enumerate(selected, 1):
                        events += [start(identifier, name), end(identifier)]
                    events.append({'type': 'done', 'success': True})
                    raw_child = ''.join(json.dumps(event, ensure_ascii=False) + '\n' for event in events).encode('utf-8')
                    Path(actual[-1][5:]).write_bytes(raw_child)
                    raw_children.append(raw_child)
                    return subprocess.CompletedProcess(command, 0)

                with patch.dict(replay.os.environ, environment), patch.object(replay.shutil, 'which', side_effect=resolved.get) as which, \
                        patch.object(replay.subprocess, 'run', side_effect=child) as run, \
                        (root / f'{key}.log').open('w', encoding='utf-8') as log:
                    code = replay.run_windows_suite(root, key, suite, manifest['cases'], root, log)
                    self.assertEqual(code, 0)
                    self.assertEqual([call.args[0] for call in which.call_args_list], [suite['command'][0], 'actual-cmd'])
                    self.assertGreater(run.call_count, 1)
                canonical = (root / f'{key}.jsonl').read_bytes()
                events = [json.loads(line) for line in canonical.splitlines()]
                planned = [name for batch in events[0]['batches'] for name in batch['names']]
                self.assertEqual(set(planned), ordinary)
                self.assertEqual(len(planned), len(ordinary))
                first_files = {}
                for case in manifest['cases']:
                    for check in case['checks']:
                        if check['suite'] == key:
                            first_files.setdefault(check['name'], check.get('file'))
                self.assertTrue(all(len({first_files[name] for name in batch['names']}) <= 1
                                    for batch in events[0]['batches']))
                self.assertEqual(events[0]['guards'], suite['guards'])
                self.assertEqual([replay.base64.b64decode(event['report_base64']) for event in events[1:-1]], raw_children)
                self.assertEqual(events[-1], {'type': 'replayBatchesDone'})
                parsed = replay.dart_report(root / f'{key}.jsonl', canonical, key, manifest, code)
                self.assertIs(parsed.success, True)
                self.assertTrue(all(parsed.check(name)[0] == 'PASS' for name in expected))
                self.assertEqual(replay.report_hashes({key: canonical})[f'{key}.jsonl'], sha256(canonical).hexdigest())

            suite = {'cwd': '.', 'command': ['dart', 'test'], 'guards': ['offline guard']}
            long_names = ['甲' + '字' * 5000, '乙' + '字' * 5000]
            cases = [{'checks': [{'suite': 'sdk', 'name': name, 'file': 'same.dart'} for name in long_names]}]
            batches = replay.windows_batches('sdk', suite, cases, root, executable, environment, comspec)
            self.assertEqual([batch['names'] for batch in batches], [[name] for name in long_names])
            self.assertTrue(all(max(batch['units']) <= batch['limit'] for batch in batches))
            self.assertEqual(len(replay.windows_batches('sdk', suite, cases, root, direct[0], environment)), 1)
            with self.assertRaisesRegex(ValueError, 'one full name'):
                replay.windows_batches('sdk', suite, [{'checks': [{'suite': 'sdk', 'name': 'x' * 9000}]}],
                                       root, executable, environment, comspec)
            guard_only = replay.windows_batches('sdk', suite, [], root, executable, environment, comspec)
            self.assertEqual([batch['names'] for batch in guard_only], [[]])
            with patch.dict(replay.os.environ, environment), patch.object(replay.shutil, 'which', return_value=None), \
                    (root / 'missing.log').open('w', encoding='utf-8') as log:
                with self.assertRaisesRegex(OSError, 'PATH/PATHEXT'):
                    replay.run_windows_suite(root, 'sdk', suite, [], root, log)
            with patch.dict(replay.os.environ, {'COMSPEC': ''}), patch.object(replay.shutil, 'which', return_value=executable), \
                    (root / 'missing-comspec.log').open('w', encoding='utf-8') as log:
                with self.assertRaisesRegex(OSError, 'COMSPEC'):
                    replay.run_windows_suite(root, 'sdk', suite, [], root, log)
            with patch.dict(replay.os.environ, environment), patch.object(replay.shutil, 'which', side_effect=resolved.get), \
                    patch.object(replay.subprocess, 'run', side_effect=OSError('launch unavailable')) as run, \
                    (root / 'failed.log').open('w', encoding='utf-8') as log:
                self.assertIsNone(replay.run_windows_suite(root, 'sdk', suite, [], root, log))
                self.assertEqual(run.call_count, 1)
            unavailable = replay.dart_report(root / 'sdk.jsonl', (root / 'sdk.jsonl').read_bytes(),
                                            'sdk', {'suites': {'sdk': suite}, 'cases': []}, None)
            self.assertIsNone(unavailable.success)
            self.assertEqual(unavailable.check('offline guard')[0], 'NOT_RUN')

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

    def test_room_replay_catalog_includes_its_shared_host_fixture_bytes(self):
        root = path.resolve().parents[2]
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / 'catalog.json'
            subprocess.run([sys.executable, str(path.with_name('prepare-memory-fixtures.py')),
                            '--output', str(output)], check=True, capture_output=True)
            rows = json.loads(output.read_text(encoding='utf-8'))['sources']
        hashes = {row['path']: row['sha256'] for row in rows}
        for peer in ['app/test/support/companion_notes_peer.dart',
                     'app/test/support/companion_session_peer.dart']:
            with self.subTest(peer=peer):
                self.assertEqual(hashes.get(peer), sha256((root / peer).read_bytes()).hexdigest())

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

            def evidence_bytes():
                return {name: (original / name).read_bytes() if (original / name).is_file() else None
                        for name in ('run-inputs.json', 'summary.json', 'results.jsonl', 'engine.xml', 'engine.log')}

            def reject_in_place(issue):
                saved = evidence_bytes()
                rejected = subprocess.run([*command, '--reports', str(original), '--output', str(original)],
                                          capture_output=True, text=True, check=False)
                self.assertEqual(rejected.returncode, 2, rejected.stderr)
                diagnostic = json.loads(rejected.stdout)
                self.assertFalse(diagnostic['reports_considered'])
                self.assertTrue(diagnostic['output_preserved'])
                self.assertEqual(diagnostic['case_counts'], {'NOT_RUN': 15})
                self.assertIn(issue, diagnostic['fixture_issue'])
                self.assertEqual(evidence_bytes(), saved)

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
                    reject_in_place('production content')
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
                    reject_in_place('raw report bytes')
                finally:
                    (original / 'engine.xml').write_bytes(raw)

            def hidden_index_change(flag, clear_flag):
                relative = production.relative_to(folder).as_posix()
                subprocess.run(['git', 'update-index', flag, '--', relative], cwd=folder,
                               capture_output=True, check=True)
                try:
                    production.write_bytes(b'const selected = 3;\n')
                    self.assertEqual(subprocess.check_output(
                        ['git', 'diff', '--binary', 'HEAD', '--'], cwd=folder), b'')
                    with self.assertRaisesRegex(ValueError, 'assume-unchanged or skip-worktree'):
                        replay.checkout_identity(Path(folder))
                    reject_in_place('assume-unchanged or skip-worktree')
                finally:
                    production.write_bytes(before)
                    subprocess.run(['git', 'update-index', clear_flag, '--', relative], cwd=folder,
                                   capture_output=True, check=True)

            hidden_index_change('--assume-unchanged', '--no-assume-unchanged')
            hidden_index_change('--skip-worktree', '--no-skip-worktree')
            # Restoring the tested checkout still permits recollecting the
            # original failed child; rejection did not consume its completion.
            restored = subprocess.run([*command, '--reports', str(original), '--output', str(original)],
                                      capture_output=True, text=True, check=False)
            self.assertEqual(restored.returncode, 1, restored.stderr)
            self.assertEqual(json.loads((original / 'run-inputs.json').read_text()), inputs)
            self.assertEqual((original / 'engine.xml').read_bytes(), raw)
            self.assertEqual(json.loads((original / 'summary.json').read_text())['suite_exits'], {'engine': 7})

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
            pending_bytes = (output / 'run-inputs.json').read_bytes()
            partial_bytes = (output / 'engine.xml').read_bytes()
            rejected = subprocess.run([*command, '--reports', str(output), '--output', str(output)],
                                      capture_output=True, text=True, check=False)
            self.assertEqual(rejected.returncode, 2, rejected.stderr)
            self.assertFalse(json.loads(rejected.stdout)['reports_considered'])
            self.assertFalse((output / 'summary.json').exists())
            self.assertFalse((output / 'results.jsonl').exists())
            self.assertEqual((output / 'run-inputs.json').read_bytes(), pending_bytes)
            self.assertEqual((output / 'engine.xml').read_bytes(), partial_bytes)
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
            saved = {name: (output / name).read_bytes()
                     for name in ('run-inputs.json', 'summary.json', 'results.jsonl', 'engine.xml')}
            rejected = subprocess.run([*command, '--reports', str(output), '--output', str(output)],
                                      capture_output=True, text=True, check=False)
            self.assertEqual(rejected.returncode, 2, rejected.stderr)
            diagnostic = json.loads(rejected.stdout)
            self.assertFalse(diagnostic['reports_considered'])
            self.assertTrue(diagnostic['output_preserved'])
            self.assertIn('case manifest not verified', diagnostic['fixture_issue'])
            self.assertEqual({name: (output / name).read_bytes() for name in saved}, saved)
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
