#!/usr/bin/env python3
"""Keep shared voice-call and read-aloud methods wired to the iOS native host."""
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
            'dsh/secrets', 'dsh/streaming_asr', 'dsh/update', 'dsh/web-files',
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


if __name__ == '__main__':
    unittest.main()
