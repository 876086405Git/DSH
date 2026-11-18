import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/usage/usage_net.dart';
import 'package:dsh_app/usage/usage_ledger.dart';
import 'package:dsh_app/usage/usage_stats.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

Future<void> settle() async {
  for (var i = 0; i < 30; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dsh/usage');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final input = Platform.environment['OHOS_USAGE_FACTS'];
  final native = input == null
      ? <String, dynamic>{
          'versionName': '0.9.9',
          'versionCode': 123,
          'platform': 'ohos',
          'apiVersion': 23,
          'sdk': 0,
          'abi': 'arm64-v8a',
          'maker': 'huawei',
        }
      : jsonDecode(File(input).readAsStringSync()) as Map<String, dynamic>;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
  test('actual Ark response flows through UsageDeviceChannel without Android SDK substitution', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'device');
      return native;
    });
    final device = await const UsageDeviceChannel().read();
    expect(device.app, native['versionName']);
    expect(device.build, native['versionCode']);
    expect(device.sdk, 0);
    expect(device.abi, native['abi']);
    expect(device.maker, native['maker']);
  });
  test('real controller startup and foreground keep OH usage v1 off the network', () async {
    final wasActive = UsageBuild.active;
    UsageBuild.active = true;
    addTearDown(() => UsageBuild.active = wasActive);
    messenger.setMockMethodCallHandler(channel, (call) async => native);
    var now = DateTime(2026, 10, 28, 9);
    final http = FakeUsageHttp();
    final ledger = UsageLedger()..count(UsageCount.turns, DateTime(2026, 10, 27, 12));
    SharedPreferences.setMockInitialValues({
      UsageStatsController.noticedKey: true,
      UsageStatsController.daysKey: ledger.encode(),
    });
    final overrides = usageOverrides(clock: () => now, http: http, onResumes: (_) {}, engine: 'proot');
    // usageOverrides declares its device override as the third item. Replace it.
    overrides[2] = usageDeviceProvider.overrideWithValue(const UsageDeviceChannel().read);
    final c = ProviderContainer(overrides: overrides);
    addTearDown(c.dispose);
    c.read(usageStatsProvider);
    await settle();
    await c.read(usageStatsProvider.notifier).send();
    expect(http.requests, isEmpty);
    c.read(usageStatsProvider.notifier).count(UsageCount.turns);
    await settle();
    now = DateTime(2026, 10, 29, 9);
    await c.read(usageStatsProvider.notifier).foreground();
    expect(http.requests, isEmpty);
  });
  test('native failure falls back to unknown facts and cannot enable valid v1 payload', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => throw PlatformException(code: 'ohos_usage_unavailable'),
    );
    final device = await const UsageDeviceChannel().read();
    expect(device.sdk, 0);
    expect(device.build, 0);
  });
}
