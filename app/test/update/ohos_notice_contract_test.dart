import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/state/app_info.dart';
import 'package:dsh_app/state/update_state.dart';
import 'package:dsh_app/update/installer.dart';
import 'package:dsh_app/update/update_config.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const usage = MethodChannel('dsh/usage');
  const apk = MethodChannel('dsh/update');
  const feed = 'https://updates.example/ohos/update.json';
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory dir;
  late FakeHttp http;
  late DateTime now;
  late List<String> usageCalls;
  late List<String> apkCalls;
  Map<String, Object>? device;
  Future<Map<String, Object>>? delayedDevice;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('dsh_440_oh_contract_');
    http = FakeHttp();
    now = DateTime(2026, 11, 5, 6);
    usageCalls = [];
    apkCalls = [];
    device = {'versionName': '1.1.0', 'versionCode': 9};
    delayedDevice = null;
    messenger.setMockMethodCallHandler(usage, (call) async {
      usageCalls.add(call.method);
      if (call.method != 'device' || device == null) throw MissingPluginException();
      return delayedDevice ?? device;
    });
    messenger.setMockMethodCallHandler(apk, (call) async {
      apkCalls.add(call.method);
      throw MissingPluginException('no APK installer');
    });
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(usage, null);
    messenger.setMockMethodCallHandler(apk, null);
    await dir.delete(recursive: true);
  });

  Map<String, dynamic> manifest({String? page = 'https://updates.example/ohos/releases/1.2.0'}) {
    final result = jsonDecode(fixture('update.json')) as Map<String, dynamic>;
    if (page == null) {
      result.remove('page');
    } else {
      result['page'] = page;
    }
    return result;
  }

  ProviderContainer container({String os = 'ohos'}) {
    final c = ProviderContainer(overrides: [
      operatingSystemProvider.overrideWithValue(os),
      updateHttpProvider.overrideWithValue(http),
      updateInstallerProvider.overrideWithValue(const ChannelUpdateInstaller()),
      updateSourcesProvider.overrideWithValue(
        UpdateSources(feed: Uri.parse(feed), useGithubApi: false, mirrors: const []),
      ),
      updateClockProvider.overrideWithValue(() => now),
      updateFlavorNameProvider.overrideWithValue('arm64'),
      updateDirectoryProvider.overrideWithValue(() async => dir),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  for (final page in <String?>[null, 'file:///private/update.hap', 'dsh://open/update', '/releases/new', 'https://name:secret@updates.example/release']) {
    test('OH detects version but never offers unsafe or missing page: $page', () async {
      http.routes[feed] = (_, _) => textResponse(jsonEncode(manifest(page: page)));
      final c = container();
      final control = c.read(appUpdateProvider.notifier);
      expect(await control.autoCheckIfDue(), isFalse);
      expect(c.read(appUpdateProvider).hasUpdate, isTrue);
      expect(c.read(appUpdateProvider).check, UpdateCheckPhase.available);
      expect(c.read(appUpdateProvider).noticePage, isNull);
      expect(c.read(appUpdateProvider).asset, isNull);
      expect(http.urls, [feed]);
      expect(apkCalls, isEmpty);
    });
  }

  for (final page in ['http://updates.example/ohos/release', 'https://updates.example/ohos/release']) {
    test('OH offers valid web page without downloading its APK assets: $page', () async {
      http.routes[feed] = (_, _) => textResponse(jsonEncode(manifest(page: page)));
      final c = container();
      expect(await c.read(appUpdateProvider.notifier).autoCheckIfDue(), isTrue);
      expect(c.read(appUpdateProvider).checkable, isTrue);
      expect(c.read(appUpdateProvider).noticePage, Uri.parse(page));
      expect(c.read(appUpdateProvider).installable, isFalse);
      expect(c.read(appUpdateProvider).asset, isNull);
      expect(http.urls, [feed]);
      expect(apkCalls, isEmpty);
    });
  }

  test('OH keeps original 24h throttle and skipped version through cached reload', () async {
    http.routes[feed] = (_, _) => textResponse(jsonEncode(manifest()));
    final c = container();
    final control = c.read(appUpdateProvider.notifier);
    expect(await control.autoCheckIfDue(), isTrue);
    expect(await control.autoCheckIfDue(), isFalse);
    expect(http.urls, [feed]);
    await control.skipLatest();
    now = now.add(const Duration(hours: 25));
    expect(await control.autoCheckIfDue(), isFalse);
    expect(http.urls, [feed, feed]);
    final reloaded = container();
    await reloaded.read(appUpdateProvider.notifier).ready;
    final state = reloaded.read(appUpdateProvider);
    expect(state.hasUpdate, isTrue);
    expect(state.isSkipped, isTrue);
    expect(state.noticePage, Uri.parse('https://updates.example/ohos/releases/1.2.0'));
    expect(await reloaded.read(appUpdateProvider.notifier).check(), UpdateCheckPhase.available);
    expect(apkCalls, isEmpty);
  });

  test('OH cached offer survives failed refresh and preserves four-hour failure backoff', () async {
    SharedPreferences.setMockInitialValues({'update_latest': jsonEncode(manifest())});
    final c = container();
    final control = c.read(appUpdateProvider.notifier);
    expect(await control.autoCheckIfDue(), isTrue);
    expect(c.read(appUpdateProvider).checkFailure, isNotNull);
    expect(c.read(appUpdateProvider).noticePage, isNotNull);
    expect(http.urls, [feed]);
    now = now.add(const Duration(hours: 3));
    expect(await control.autoCheckIfDue(), isFalse);
    expect(http.urls, [feed]);
    now = now.add(const Duration(hours: 1));
    expect(await control.autoCheckIfDue(), isTrue);
    expect(http.urls, [feed, feed]);
    expect(apkCalls, isEmpty);
  });

  for (final missing in [true, false]) {
    test('OH bundle ${missing ? 'missing' : 'invalid'} retains compiled version and can check', () async {
      device = missing ? null : {'versionName': 'not-a-version', 'versionCode': 42};
      http.routes[feed] = (_, _) => textResponse(jsonEncode(manifest()));
      final c = container();
      final control = c.read(appUpdateProvider.notifier);
      await control.ready;
      expect(c.read(appUpdateProvider).current.toString(), AppInfo.version);
      expect(await control.check(), UpdateCheckPhase.available);
      expect(usageCalls, ['device']);
      expect(apkCalls, isEmpty);
    });
  }

  test('OH bundle newer than feed removes stale cache without touching APK directory', () async {
    device = {'versionName': '1.3.0', 'versionCode': 100};
    SharedPreferences.setMockInitialValues({'update_latest': jsonEncode(manifest())});
    final marker = File('${dir.path}/unrelated.apk');
    await marker.writeAsString('owned by neither this OH prompt nor its feed');
    http.routes[feed] = (_, _) => textResponse(jsonEncode(manifest()));
    final c = container();
    final control = c.read(appUpdateProvider.notifier);
    await control.ready;
    expect(c.read(appUpdateProvider).hasUpdate, isFalse);
    expect(await control.check(), UpdateCheckPhase.upToDate);
    expect(c.read(appUpdateProvider).current.toString(), '1.3.0+100');
    expect(await marker.exists(), isTrue);
    expect(apkCalls, isEmpty);
  });

  test('OH APK entrypoints remain disabled while device initialization is pending', () async {
    final pending = Completer<Map<String, Object>>();
    delayedDevice = pending.future;
    final c = container();
    final control = c.read(appUpdateProvider.notifier);
    expect(c.read(appUpdateProvider).installable, isFalse);
    await control.startDownload();
    await control.retry();
    await control.install();
    expect(await control.installWithSystem(), isFalse);
    await control.requestInstallPermission();
    await control.onAppResumed();
    expect(apkCalls, isEmpty);
    expect(http.urls, isEmpty);
    pending.complete({'versionName': '1.1.0', 'versionCode': 9});
    await control.ready;
  });

  test('non-OH missing installer keeps its original no-check behavior', () async {
    final c = container(os: 'linux');
    final control = c.read(appUpdateProvider.notifier);
    expect(await control.check(), UpdateCheckPhase.idle);
    expect(await control.autoCheckIfDue(), isFalse);
    expect(c.read(appUpdateProvider).checkable, isFalse);
    expect(c.read(appUpdateProvider).noticeOnly, isFalse);
    expect(usageCalls, isEmpty);
    expect(apkCalls, ['info']);
    expect(http.urls, isEmpty);
  });
}
