import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/android_features.dart';
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

  test('OH public check reads bundle version and offers notice without APK operations', () async {
    final dir = await Directory.systemTemp.createTemp('dsh_440_oh_notice_');
    addTearDown(() => dir.delete(recursive: true));
    SharedPreferences.setMockInitialValues({});
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const usageChannel = MethodChannel('dsh/usage');
    const installerChannel = MethodChannel('dsh/update');
    final usageCalls = <String>[];
    final installerCalls = <String>[];
    messenger.setMockMethodCallHandler(usageChannel, (call) async {
      usageCalls.add(call.method);
      if (call.method != 'device') throw MissingPluginException('only bundle device facts are provided');
      return <String, Object>{'versionName': '1.1.0', 'versionCode': 9, 'sdk': 26, 'abi': 'arm64-v8a'};
    });
    messenger.setMockMethodCallHandler(installerChannel, (call) async {
      installerCalls.add(call.method);
      throw MissingPluginException('OH has no APK installer');
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(usageChannel, null);
      messenger.setMockMethodCallHandler(installerChannel, null);
    });

    const feed = 'https://updates.example/ohos/update.json';
    const page = 'https://updates.example/ohos/releases/1.2.0';
    final manifest = jsonDecode(fixture('update.json')) as Map<String, dynamic>;
    // Preserve the original APK-only assets: they must not become OH downloads.
    manifest['page'] = page;
    final http = FakeHttp({feed: (_, _) => textResponse(jsonEncode(manifest))});
    final container = ProviderContainer(overrides: [
      operatingSystemProvider.overrideWithValue('ohos'),
      updateHttpProvider.overrideWithValue(http),
      updateInstallerProvider.overrideWithValue(const ChannelUpdateInstaller()),
      updateSourcesProvider.overrideWithValue(
        UpdateSources(feed: Uri.parse(feed), useGithubApi: false, mirrors: const []),
      ),
      updateClockProvider.overrideWithValue(() => DateTime(2026, 11, 5, 5)),
      // An Android-named build flavor must not expose the APK on OH.
      updateFlavorNameProvider.overrideWithValue('arm64'),
      updateDirectoryProvider.overrideWithValue(() async => dir),
    ]);
    addTearDown(container.dispose);
    final controller = container.read(appUpdateProvider.notifier);
    await controller.ready;
    final phase = await controller.check();

    // First red on tip+433: check() returns idle before any manifest request.
    expect(phase, UpdateCheckPhase.available);
    final state = container.read(appUpdateProvider);
    expect(state.loaded, isTrue);
    expect(state.installable, isFalse);
    expect(state.current.toString(), '1.1.0+9');
    expect(state.latest!.version.toString(), '1.2.0+7');
    expect(state.latest!.pageUrl, Uri.parse(page));
    expect(state.asset, isNull);
    expect(state.patch, isNull);
    expect(state.downloadSize, isNull);
    expect(usageCalls, ['device']);
    expect(installerCalls, isEmpty);
    expect(http.urls, [feed]);

    await controller.startDownload();
    await controller.retry();
    await controller.install();
    expect(await controller.installWithSystem(), isFalse);
    await controller.requestInstallPermission();
    await controller.onAppResumed();
    expect(installerCalls, isEmpty);
    expect(http.urls, [feed]);
    expect(container.read(appUpdateProvider).task, UpdateTaskPhase.idle);
    expect(await dir.list().isEmpty, isTrue);
  });
}
