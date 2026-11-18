// The guide and the settings index agree: every path in docs/guide that
// starts at 设置 (`<!-- nav: commonSettings,… -->`), read through the ARB in
// its language, is the way to some page or row of the index — so the guide,
// and the answers AI gives from it, can't point where the app no longer is.
// HarmonyOS reads its own pages (docs/guide/harmony) over Android's, and only
// what it has counts there. (tool/guide_sync.py checks the labels themselves.)

import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/ui/settings/index/spots.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

final _nav = RegExp(r'^<!-- nav: ([A-Za-z0-9_,]+) -->$');

Map<String, String> _arb(String lang) => {
  for (final file in Directory('lib/l10n/parts').listSync().whereType<File>())
    if (file.path.endsWith('_$lang.arb'))
      for (final MapEntry(:key, :value) in (jsonDecode(file.readAsStringSync()) as Map<String, Object?>).entries)
        if (!key.startsWith('@') && value is String) key: value,
};

void main() {
  for (final lang in ['zh', 'en']) {
    test('every 设置 path in the $lang guide is a way the index knows', () {
      final l10n = lookupL10n(Locale(lang));
      final arb = _arb(lang);
      final trails = {
        [l10n.commonSettings].join(' › '),
        for (final spot in SettingsIndex.spots) SettingsIndex.trail(spot, l10n).join(' › '),
      };
      final pages = Directory('../docs/guide/$lang').listSync().whereType<File>().where((f) => f.path.endsWith('.md'));
      var checked = 0;
      for (final page in pages) {
        for (final (i, line) in page.readAsLinesSync().indexed) {
          final keys = _nav.firstMatch(line)?.group(1)?.split(',');
          if (keys == null || keys.first != 'commonSettings') continue;
          final path = [for (final k in keys) arb[k] ?? '<$k>'].join(' › ');
          expect(trails, contains(path), reason: '${page.path}:${i + 1}: $path');
          checked++;
        }
      }
      expect(checked, greaterThan(10));
    });

    test('every 设置 path the $lang guide gives on HarmonyOS is a way there, on HarmonyOS', () {
      final l10n = lookupL10n(Locale(lang));
      final arb = _arb(lang);
      final trails = {
        l10n.commonSettings,
        for (final spot in SettingsIndex.spots)
          if (!SettingsIndex.androidOnly(spot)) SettingsIndex.trail(spot, l10n).join(' › '),
      };
      File page(File android) {
        final own = File('../docs/guide/harmony/$lang/${android.uri.pathSegments.last}');
        return own.existsSync() ? own : android;
      }

      final pages = Directory('../docs/guide/$lang')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.md'))
          .map(page);
      var checked = 0;
      for (final page in pages) {
        for (final (i, line) in page.readAsLinesSync().indexed) {
          final keys = _nav.firstMatch(line)?.group(1)?.split(',');
          if (keys == null || keys.first != 'commonSettings') continue;
          final path = [for (final k in keys) arb[k] ?? '<$k>'].join(' › ');
          expect(trails, contains(path), reason: '${page.path}:${i + 1}: $path');
          checked++;
        }
      }
      expect(checked, greaterThan(10));
    });
  }
}
