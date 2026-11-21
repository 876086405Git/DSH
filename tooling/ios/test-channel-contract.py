#!/usr/bin/env python3
"""Keep shared channels wired and App/test sources correctly owned by iOS targets."""
from collections import Counter
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


class SpeechChannelContract(unittest.TestCase):
    def test_every_new_shared_channel_has_ios_or_an_explicit_platform_exception(self):
        dart_channels = set()
        for source in (ROOT / 'app/lib').rglob('*.dart'):
            if source.name.startswith('._'):
                continue
            dart_channels.update(re.findall(
                r'(?:MethodChannel|EventChannel)\(\s*[\'\"](dsh/[^\'\"]+)', source.read_text(errors='ignore')))
        ios_channels = set()
        for source in (ROOT / 'app/ios/Runner').rglob('*.swift'):
            if source.name.startswith('._'):
                continue
            ios_channels.update(re.findall(
                r'(?:FlutterMethodChannel|FlutterEventChannel|SilentEvents)\(name:\s*"(dsh/[^"]+)',
                source.read_text(errors='ignore')))
        # These are reviewed in CHANNEL_COVERAGE.md. Some are OHOS/Android-only;
        # unresolved iOS capabilities remain visible there until implemented.
        exceptions = {
            'dsh/attachment-files', 'dsh/authorized-workspaces', 'dsh/dynamic_color', 'dsh/media_video',
            'dsh/paste', 'dsh/phone/preview', 'dsh/picture_shortcut',
            'dsh/secrets', 'dsh/streaming_asr', 'dsh/update', 'dsh/web-files', 'dsh/companion_reminders',
        }
        self.assertFalse(dart_channels - ios_channels - exceptions,
                         sorted(dart_channels - ios_channels - exceptions))

    def test_shared_speech_channel_is_registered_with_its_methods(self):
        dart = (ROOT / 'app/lib/speech/speech_audio.dart').read_text()
        swift = (ROOT / 'app/ios/Runner/VoiceChannel.swift').read_text()
        plugin = (ROOT / 'app/ios/Runner/DshPlugin.swift').read_text()
        self.assertIn("MethodChannel('dsh/speech')", dart)
        self.assertIn('FlutterMethodChannel(name: "dsh/speech"', swift)
        self.assertIn('IOSSpeechChannel(messenger: messenger)', plugin)

        # Read the public Dart wire calls, rather than maintaining a second
        # handwritten method list that can drift with new call controls.
        dart_methods = set(re.findall(r"_invoke(?:<[^>]+>)?\('([^']+)'", dart))
        native = swift.split('final class IOSSpeechChannel:', 1)[1]
        ios_methods = set(re.findall(r'case "([A-Za-z]+)"', native))
        self.assertTrue({'open', 'write', 'callStart'} <= dart_methods)
        self.assertFalse(dart_methods - ios_methods, sorted(dart_methods - ios_methods))

    def test_gallery_video_save_has_a_native_handler(self):
        dart = (ROOT / 'app/lib/media/gallery.dart').read_text()
        swift = (ROOT / 'app/ios/Runner/DshPlugin.swift').read_text()
        self.assertIn("invokeMethod<String>('saveVideoFile'", dart)
        native = swift.split('private final class MediaChannel', 1)[1].split('// MARK: - dsh/notify', 1)[0]
        self.assertIn('case "saveVideoFile":', native)


class IOSProjectSourceContract(unittest.TestCase):
    @staticmethod
    def project_objects():
        project = (ROOT / 'app/ios/Runner.xcodeproj/project.pbxproj').read_text()
        project = re.sub(r'/\*.*?\*/', '', project, flags=re.S)
        # Top-level object definitions have two tabs; nested TargetAttributes
        # also use UUID keys but do not define project objects with an isa.
        headers = list(re.finditer(r'(?m)^\t\t([A-F0-9]{24})\s*=\s*\{', project))
        return [(header.group(1), project[header.end():headers[index + 1].start()
                 if index + 1 < len(headers) else len(project)])
                for index, header in enumerate(headers)]

    @staticmethod
    def field(body, name):
        match = re.search(r'\b' + re.escape(name) + r'\s*=\s*([^;]+);', body)
        return match.group(1).strip().strip('"') if match else None

    @staticmethod
    def references(body, name):
        match = re.search(r'\b' + re.escape(name) + r'\s*=\s*\((.*?)\);', body, re.S)
        return re.findall(r'\b[A-F0-9]{24}\b', match.group(1)) if match else []

    def test_project_object_ids_are_unique(self):
        objects = self.project_objects()
        self.assertTrue(objects)
        self.assertTrue(all(self.field(body, 'isa') for _, body in objects))
        counts = Counter(identifier for identifier, _ in objects)
        self.assertFalse({identifier: count for identifier, count in counts.items() if count > 1})

    def test_app_and_unit_test_sources_have_distinct_membership(self):
        objects = dict(self.project_objects())

        def find(kind, field, value):
            matches = [identifier for identifier, body in objects.items()
                       if self.field(body, 'isa') == kind and self.field(body, field) == value]
            self.assertEqual(len(matches), 1, (kind, field, value, matches))
            return matches[0]

        def source_files(target_name):
            target = objects[find('PBXNativeTarget', 'name', target_name)]
            phases = [objects[identifier] for identifier in self.references(target, 'buildPhases')
                      if self.field(objects[identifier], 'isa') == 'PBXSourcesBuildPhase']
            self.assertEqual(len(phases), 1, target_name)
            files = set()
            for identifier in self.references(phases[0], 'files'):
                build_file = objects[identifier]
                self.assertEqual(self.field(build_file, 'isa'), 'PBXBuildFile')
                file_ref = self.field(build_file, 'fileRef')
                self.assertEqual(self.field(objects[file_ref], 'isa'), 'PBXFileReference')
                files.add(file_ref)
            return files

        app_sources = source_files('Runner')
        unit_sources = source_files('RunnerTests')
        test_group = objects[find('PBXGroup', 'path', 'RunnerTests')]
        test_files = {identifier for identifier in self.references(test_group, 'children')
                      if (self.field(objects[identifier], 'path') or '').endswith('.swift')}
        self.assertTrue(test_files)
        self.assertLessEqual(test_files, unit_sources, 'Keep every unit test in RunnerTests')
        self.assertFalse(app_sources & test_files, 'Unit tests must not compile into Runner')
        self.assertFalse([self.field(objects[identifier], 'path') for identifier in app_sources
                          if (self.field(objects[identifier], 'path') or '').endswith('Tests.swift')])
        protection = find('PBXFileReference', 'path', 'IOSBackgroundProtection.swift')
        self.assertIn(protection, app_sources)
        self.assertNotIn(protection, unit_sources)


if __name__ == '__main__':
    unittest.main()
