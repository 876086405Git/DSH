// How the manifest wires the ways in (share sheet, launcher shortcuts, Quick
// Settings tile, the launcher icon's activity-aliases) — the parts a build
// accepts even when they're wrong, and a device only shows by doing nothing.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final _manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();

/// The `<activity|service …>` element named [name], self-closing or with its
/// children.
String _component(String tag, String name) {
  final start = RegExp('<$tag\\s[^>]*android:name="${RegExp.escape(name)}"[^>]*>').firstMatch(_manifest);
  expect(start, isNotNull, reason: '$tag $name');
  final open = start!.group(0)!;
  if (open.endsWith('/>')) return open;
  final end = _manifest.indexOf('</$tag>', start.end);
  return _manifest.substring(start.start, end + '</$tag>'.length);
}

/// Every `<activity-alias …>…</activity-alias>`: the launcher entries, one per
/// 桌面图标 (icons/LauncherIcons.kt).
List<String> _aliases() => [
  for (final m in RegExp(r'<activity-alias\s[\s\S]*?</activity-alias>').allMatches(_manifest)) m.group(0)!,
];

const _launcher = 'android.intent.category.LAUNCHER';

void main() {
  test('the share sheet target takes SEND and SEND_MULTIPLE of any type', () {
    final share = _component('activity', '.share.ShareActivity');
    expect(share, contains('android:exported="true"'));
    expect(share, contains('android.intent.action.SEND"'));
    expect(share, contains('android.intent.action.SEND_MULTIPLE"'));
    expect(share, contains('android:mimeType="*/*"'));
    expect(share, contains('android:excludeFromRecents="true"'));
    expect(share, contains('@android:style/Theme.NoDisplay'));
  });

  test('share codes still open as files and links, but are no second share target', () {
    final links = _component('activity', '.links.LinkTrampolineActivity');
    expect(links, contains('<data android:scheme="dshgo" />'));
    expect(links, contains('application/vnd.dshgo+json'));
    expect(links, contains('android.intent.action.VIEW'));
    // Two entries named DSH in the share sheet otherwise.
    expect(links, isNot(contains('android.intent.action.SEND')));
  });

  test('shortcuts and the tile go through the unexported EntryActivity', () {
    final entry = _component('activity', '.shortcuts.EntryActivity');
    expect(entry, contains('android:exported="false"'));
    expect(entry, isNot(contains('<intent-filter')));
  });

  test('the launcher entries are the aliases, each with the long-press shortcuts', () {
    final aliases = _aliases();
    expect(aliases, hasLength(5));
    for (final alias in aliases) {
      expect(alias, contains('android:targetActivity=".MainActivity"'));
      expect(alias, contains('android:exported="true"'));
      expect(alias, contains('android.intent.action.MAIN"'));
      expect(alias, contains(_launcher));
      expect(alias, contains('android:name="android.app.shortcuts"'));
      expect(alias, contains('android:resource="@xml/shortcuts"'));
      // Only the launcher entry: shares, links and the tile stay on their activities.
      expect('<intent-filter'.allMatches(alias), hasLength(1));
      expect(alias, isNot(contains('android.intent.action.SEND')));
      expect(alias, isNot(contains('android.intent.action.VIEW')));
      expect(alias, isNot(contains('QS_TILE')));
    }
    // Exactly one is on for a fresh install.
    expect(aliases.where((a) => a.contains('android:enabled="true"')), hasLength(1));
    expect(aliases.where((a) => a.contains('android:enabled="false"')), hasLength(4));
  });

  test('no activity is a launcher entry of its own', () {
    final main = _component('activity', '.MainActivity');
    expect(main, isNot(contains(_launcher)));
    // Its meta-data is read for every alias (MainActivity.getMetaData).
    expect(main, contains('android:name="flutter_deeplinking_enabled" android:value="false"'));
    expect(main, isNot(contains('android.app.shortcuts')));
    final activities = RegExp(r'<activity\s[\s\S]*?(?:/>|</activity>)').allMatches(_manifest);
    expect(activities, isNotEmpty);
    for (final a in activities) {
      expect(a.group(0), isNot(contains(_launcher)));
    }
  });

  test('the tile is bound only by the system', () {
    final tile = _component('service', '.tile.NewChatTileService');
    expect(tile, contains('android:permission="android.permission.BIND_QUICK_SETTINGS_TILE"'));
    expect(tile, contains('android.service.quicksettings.action.QS_TILE'));
    expect(tile, contains('android:icon="@drawable/ic_tile_new_chat"'));
    expect(tile, contains('android:label="@string/tile_new_chat"'));
  });

  test('the shared engine registers both plugins and MainActivity keeps its metadata', () {
    // The engine is shared with the resident companion, so plugins are added
    // where it is created, not in the Activity.
    final engine = File('android/app/src/main/kotlin/io/github/ccch1mneyyy/dsh_app/DshFlutterEngine.kt')
        .readAsStringSync();
    expect(engine, contains('engine.plugins.add(SharePlugin())'));
    expect(engine, contains('engine.plugins.add(ShortcutsPlugin())'));
    expect(engine, contains('LauncherIconPlugin()'));
    final activity = File('android/app/src/main/kotlin/io/github/ccch1mneyyy/dsh_app/MainActivity.kt')
        .readAsStringSync();
    expect(activity, contains('override fun getMetaData()'));
  });
}
