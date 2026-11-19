"""python3 -m unittest discover -s app/tool -p 'test_bundle_tests.py'"""
import contextlib
import io
import json
import os
import tempfile
import unittest
from pathlib import Path

import bundle_tests

WIDGET = "import 'package:flutter_test/flutter_test.dart';\nvoid main() {\n  testWidgets('x', (tester) async {});\n}\n"
PLAIN = "import 'package:test/test.dart';\nvoid main() {\n  test('x', () {});\n}\n"


class BundleTests(unittest.TestCase):
    def setUp(self):
        work = tempfile.TemporaryDirectory()
        self.addCleanup(work.cleanup)
        self.addCleanup(os.chdir, os.getcwd())
        os.chdir(work.name)
        bundle_tests._text.clear()
        for path, body in {
            'test/flutter_test_config.dart': '',
            'test/bundle_solo.txt': '# why\ntest/chat/listed_test.dart\n',
            'test/chat/a_test.dart': WIDGET,
            'test/chat/listed_test.dart': WIDGET,
            'test/chat/helper.dart': 'class _B extends AutomatedTestWidgetsFlutterBinding {}\n',
            'test/chat/own_binding_test.dart': "import 'helper.dart';\n" + WIDGET,
            'test/state/b_test.dart': PLAIN,
            'test/secrets/flutter_test_config.dart': '',
            'test/secrets/c_test.dart': PLAIN,
        }.items():
            Path(path).parent.mkdir(parents=True, exist_ok=True)
            Path(path).write_text(body, encoding='utf-8')

    def run_tool(self, call, *args):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            call(*args)
        return out.getvalue().split()

    def test_a_shard_is_bundles_by_directory_and_kind_plus_the_files_that_stay_alone(self):
        targets = self.run_tool(bundle_tests.shard, 0, 1)
        self.assertEqual(sorted(targets), [
            'test/_bundles/chat_widget_0_test.dart',
            'test/_bundles/state_plain_0_test.dart',
            'test/chat/listed_test.dart',
            'test/chat/own_binding_test.dart',
            'test/secrets/c_test.dart',
        ])
        bundle = Path('test/_bundles/chat_widget_0_test.dart').read_text(encoding='utf-8')
        self.assertIn("import '../chat/a_test.dart' as t0;", bundle)
        self.assertIn("bundledWidgets('test/chat/a_test.dart', t0.main);", bundle)
        self.assertIn("bundled('test/state/b_test.dart', t0.main);", Path('test/_bundles/state_plain_0_test.dart').read_text(encoding='utf-8'))

    def test_every_target_lands_on_exactly_one_shard(self):
        everything = self.run_tool(bundle_tests.shard, 0, 1)
        split = self.run_tool(bundle_tests.shard, 0, 2) + self.run_tool(bundle_tests.shard, 1, 2)
        self.assertEqual(sorted(split), sorted(everything))

    def test_a_listed_file_that_is_gone_stops_the_run(self):
        Path('test/chat/listed_test.dart').unlink()
        with self.assertRaises(SystemExit):
            self.run_tool(bundle_tests.shard, 0, 1)

    def test_failures_name_the_file_in_the_bundle_or_the_whole_bundle_that_did_not_load(self):
        self.run_tool(bundle_tests.shard, 0, 1)
        root = Path.cwd().as_posix()
        events = [
            {'type': 'suite', 'suite': {'id': 0, 'path': f'{root}/test/_bundles/chat_widget_0_test.dart'}},
            {'type': 'suite', 'suite': {'id': 1, 'path': f'{root}/test/_bundles/state_plain_0_test.dart'}},
            {'type': 'suite', 'suite': {'id': 2, 'path': f'{root}/test/secrets/c_test.dart'}},
            {'type': 'testStart', 'test': {'id': 1, 'name': 'test/chat/a_test.dart x', 'suiteID': 0}},
            {'type': 'testDone', 'testID': 1, 'result': 'failure'},
            {'type': 'testStart', 'test': {'id': 2, 'name': f'loading {root}/test/_bundles/state_plain_0_test.dart', 'suiteID': 1}},
            {'type': 'testDone', 'testID': 2, 'result': 'error'},
            {'type': 'testStart', 'test': {'id': 3, 'name': 'x', 'suiteID': 2}},
            {'type': 'testDone', 'testID': 3, 'result': 'success'},
        ]
        Path('report.json').write_text('\n'.join(json.dumps(event) for event in events), encoding='utf-8')
        self.assertEqual(self.run_tool(bundle_tests.failed, 'report.json'), ['test/chat/a_test.dart', 'test/state/b_test.dart'])

    def test_a_failed_run_with_no_failed_test_is_not_a_pass(self):
        Path('report.json').write_text('{"type":"done","success":false}\n', encoding='utf-8')
        with self.assertRaises(SystemExit):
            self.run_tool(bundle_tests.failed, 'report.json')


if __name__ == '__main__':
    unittest.main()
