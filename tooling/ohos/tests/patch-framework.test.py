#!/usr/bin/env python3
"""patch_framework.py on verbatim excerpts of the pinned tag's three framework files."""
import difflib
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
PATCHER = HERE.parent / 'patch_framework.py'
NAMES = ('feedback.dart', 'text_selection.dart', 'editable_text.dart')


class PatchFrameworkTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.sdk = Path(self.tmp.name)
        self.widgets = self.sdk / 'packages/flutter/lib/src/widgets'
        self.widgets.mkdir(parents=True)
        for name in NAMES:
            shutil.copy2(HERE / 'fixtures/framework' / name, self.widgets / name)

    def run_patcher(self):
        return subprocess.run([sys.executable, '-I', '-B', str(PATCHER), str(self.sdk)], capture_output=True, text=True)

    def read(self, name):
        return (self.widgets / name).read_text()

    def changes(self, name):
        before = (HERE / 'fixtures/framework' / name).read_text().splitlines()
        return [line for line in difflib.ndiff(before, self.read(name).splitlines()) if line[0] in '+-']

    def test_long_press_vibrates_as_on_android_and_tap_stays(self):
        self.assertEqual(self.run_patcher().returncode, 0)
        source = self.read('feedback.dart')
        tap, long_press = source.split('static Future<void> forLongPress', 1)
        self.assertIn('case TargetPlatform.ohos:\n        return Future<void>.value();', tap)
        self.assertIn(
            'case TargetPlatform.android:\n      case TargetPlatform.ohos:\n      case TargetPlatform.fuchsia:\n'
            '        return HapticFeedback.vibrate();',
            long_press,
        )
        self.assertEqual(long_press.count('TargetPlatform.ohos'), 1)
        self.assertEqual(len(self.changes('feedback.dart')), 2)

    def test_magnifier_shows_and_hides_as_on_android(self):
        self.assertEqual(self.run_patcher().returncode, 0)
        source = self.read('text_selection.dart')
        for call in ('showMagnifier(positionToShow)', 'hideMagnifier()'):
            self.assertIn(
                'case TargetPlatform.android:\n      case TargetPlatform.ohos:\n      case TargetPlatform.iOS:\n'
                f'        editableText.{call};',
                source,
            )
        # The two switches, and the guard for an IME composing, which has no case to move.
        self.assertEqual(source.count('TargetPlatform.ohos'), 3)
        self.assertEqual(len(self.changes('text_selection.dart')), 5)

    def test_a_composition_that_starts_mid_press_leaves_no_magnifier(self):
        self.assertEqual(self.run_patcher().returncode, 0)
        self.assertIn(
            'value.composing.isNormalized) {\n      _hideMagnifierIfSupportedByPlatform();\n      return;\n    }\n'
            '    _onSingleLongTapEndOrCancel();',
            self.read('text_selection.dart'),
        )

    def test_toolbar_fades_as_on_android(self):
        self.assertEqual(self.run_patcher().returncode, 0)
        source = self.read('editable_text.dart')
        self.assertIn('TargetPlatform.android || TargetPlatform.ohos || TargetPlatform.iOS => true,', source)
        self.assertIn('TargetPlatform.windows => false,', source)
        self.assertEqual(source.count('TargetPlatform.ohos'), 1)

    def test_a_second_run_changes_nothing(self):
        self.assertEqual(self.run_patcher().returncode, 0)
        patched = {name: self.read(name) for name in NAMES}
        again = self.run_patcher()
        self.assertEqual(again.returncode, 0)
        self.assertEqual(again.stdout, '')
        self.assertEqual({name: self.read(name) for name in NAMES}, patched)

    def test_other_source_stops_with_nothing_written(self):
        for name, old, new in (
            ('feedback.dart', 'HapticFeedback.vibrate()', 'HapticFeedback.mediumImpact()'),
            ('text_selection.dart', 'editableText.hideMagnifier()', 'editableText.hide()'),
            ('editable_text.dart', 'TargetPlatform.ohos => false', 'TargetPlatform.ohos => null'),
        ):
            with self.subTest(name):
                self.setUp()
                (self.widgets / name).write_text(self.read(name).replace(old, new))
                changed = {other: self.read(other) for other in NAMES}
                result = self.run_patcher()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(name, result.stderr)
                self.assertEqual({other: self.read(other) for other in NAMES}, changed)

    def test_a_missing_file_stops(self):
        (self.widgets / 'editable_text.dart').unlink()
        self.assertNotEqual(self.run_patcher().returncode, 0)
        self.assertEqual(self.changes('feedback.dart'), [])


if __name__ == '__main__':
    unittest.main()
