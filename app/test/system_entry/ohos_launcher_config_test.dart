// How the HarmonyOS project wires the launcher's ways in: the parts a build
// accepts even when they're wrong, and a device only shows by doing nothing.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dsh_app/links/launcher_entries.dart';
import 'package:dsh_app/state/app_icon_state.dart';
import 'package:dsh_app/ui/settings/appearance/app_icon_picker.dart';
import 'package:flutter/painting.dart' show Color;
import 'package:flutter_test/flutter_test.dart';

const _project = 'ohos';
const _entryRes = '$_project/entry/src/main/resources';

Map<String, dynamic> _json(String path) => jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

Future<ByteData> _decode(String path) async {
  final codec = await ui.instantiateImageCodec(File(path).readAsBytesSync());
  final image = (await codec.getNextFrame()).image;
  final pixels = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
  image.dispose();
  return pixels!;
}

Color _pixel(ByteData rgba, int x, int y) {
  final offset = (y * 1024 + x) * 4;
  return Color.fromARGB(
    rgba.getUint8(offset + 3),
    rgba.getUint8(offset),
    rgba.getUint8(offset + 1),
    rgba.getUint8(offset + 2),
  );
}

Color _lerp(AppIconArt art, double t) => Color.lerp(art.from, art.to, t)!;

Matcher _isNear(Color expected) => predicate<Color>(
  (color) => (color.r - expected.r).abs() < 0.03 && (color.g - expected.g).abs() < 0.03 && (color.b - expected.b).abs() < 0.03,
  'close to $expected',
);

/// `$media:name` as a layered icon under [resources]: both layers exist, 1024 px.
void _expectLayered(String resources, String reference) {
  expect(reference, startsWith(r'$media:'));
  final icon = _json('$resources/base/media/${reference.substring(7)}.json')['layered-image'] as Map<String, dynamic>;
  for (final layer in icon.values.cast<String>()) {
    final file = File('$resources/base/media/${layer.substring(7)}.png');
    expect(file.existsSync(), isTrue, reason: layer);
    final bytes = file.readAsBytesSync();
    final data = ByteData.sublistView(bytes);
    expect((data.getUint32(16), data.getUint32(20)), (1024, 1024), reason: layer);
  }
}

void main() {
  group('alternate icons', () {
    final app = _json('$_project/AppScope/app.json5')['app'] as Map<String, dynamic>;
    final icons = (app['alternateIcons'] as List).cast<Map<String, dynamic>>();

    test('one per AppIcon but the app\'s own, under the name Dart asks for', () {
      expect(icons.map((icon) => icon['name']), [
        for (final icon in AppIcon.values)
          if (icon != AppIcon.mist) icon.name,
      ]);
    });

    test('every one is layered like the app\'s own icon, resolved from AppScope', () {
      _expectLayered('$_project/AppScope/resources', app['icon'] as String);
      for (final icon in icons) {
        _expectLayered('$_project/AppScope/resources', icon['icon'] as String);
      }
    });

    test('the layers are the art the previews draw: the gradient\'s two ends, a glyph in the middle', () async {
      for (final choice in AppIcon.values.where((icon) => icon != AppIcon.mist)) {
        final art = AppIconArt.of(choice);
        final background = await _decode('$_project/AppScope/resources/base/media/${choice.name}_background.png');
        // The corners of the visible 72 of the 108 grid lie inside the gradient's ends.
        expect(_pixel(background, 0, 0), _isNear(_lerp(art, 0.069)), reason: '${choice.name} top left');
        expect(_pixel(background, 1023, 1023), _isNear(_lerp(art, 0.931)), reason: '${choice.name} bottom right');
        final foreground = await _decode('$_project/AppScope/resources/base/media/${choice.name}_foreground.png');
        expect(_pixel(foreground, 0, 0).a, 0, reason: 'the launcher masks a transparent layer');
        expect(_pixel(foreground, 512, 720).a, greaterThan(0.9), reason: 'the body of the glyph');
      }
    });
  });

  group('static shortcuts', () {
    final shortcuts = (_json('$_entryRes/base/profile/shortcuts_config.json')['shortcuts'] as List)
        .cast<Map<String, dynamic>>();

    test('EntryAbility declares them', () {
      final module = _json('$_project/entry/src/main/module.json5')['module'] as Map<String, dynamic>;
      final ability = (module['abilities'] as List).single as Map<String, dynamic>;
      expect(ability['name'], 'EntryAbility');
      expect(ability['metadata'], [
        {'name': 'ohos.ability.shortcuts', 'resource': r'$profile:shortcuts_config'},
      ]);
    });

    test('新对话 and 语音输入 go to this app, with what Dart parses', () {
      final app = _json('$_project/AppScope/app.json5')['app'] as Map<String, dynamic>;
      final entries = {
        for (final shortcut in shortcuts)
          shortcut['shortcutId'] as String: () {
            final want = (shortcut['wants'] as List).single as Map<String, dynamic>;
            expect(want['bundleName'], app['bundleName']);
            expect(want['moduleName'], 'entry');
            expect(want['abilityName'], 'EntryAbility');
            return LauncherEntry.parse({'kind': (want['parameters'] as Map)['dshShortcut']});
          }(),
      };
      expect(entries.keys, ['new_chat', 'voice_input']);
      expect(entries['new_chat'], isA<NewChatEntry>().having((e) => e.voice, 'voice', isFalse));
      expect(entries['voice_input'], isA<NewChatEntry>().having((e) => e.voice, 'voice', isTrue));
    });

    test('every label is there in both languages, in Android\'s words', () {
      final android = {
        'shortcut_new_chat': ('New chat', '新对话'),
        'shortcut_voice_input': ('Voice input', '语音输入'),
      };
      String? value(String locale, String name) {
        final strings = (_json('$_entryRes/$locale/element/string.json')['string'] as List).cast<Map<String, dynamic>>();
        return strings.where((s) => s['name'] == name).single['value'] as String?;
      }

      for (final shortcut in shortcuts) {
        final name = (shortcut['label'] as String).replaceFirst(r'$string:', '');
        expect(value('base', name), android[name]!.$1);
        expect(value('en_US', name), android[name]!.$1);
        expect(value('zh_CN', name), android[name]!.$2);
      }
    });

    test('every icon is layered, and follows dark mode as Android\'s does', () {
      for (final shortcut in shortcuts) {
        _expectLayered(_entryRes, shortcut['icon'] as String);
        final icon = _json('$_entryRes/base/media/${(shortcut['icon'] as String).substring(7)}.json')['layered-image'] as Map;
        for (final layer in icon.values.cast<String>()) {
          expect(File('$_entryRes/dark/media/${layer.substring(7)}.png').existsSync(), isTrue, reason: layer);
        }
      }
    });
  });
}
