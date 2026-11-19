import 'package:dsh_app/runtime/background_protection.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dsh/runtime');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final bridge = RuntimeBridge();

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('native preferences never imply an active grant', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => {
        'supported': true,
        'audioEnabled': true,
        'locationEnabled': true,
        'locationAuthorization': 'denied',
        'error': 'ios_background_location_denied',
      },
    );
    final protection = (await bridge.backgroundProtection())!;
    expect(protection.supported, isTrue);
    expect(protection.audioEnabled, isTrue);
    expect(protection.locationEnabled, isTrue);
    expect(protection.audioActive, isFalse);
    expect(protection.locationActive, isFalse);
    expect(protection.locationAuthorization, 'denied');
    expect(protection.hasError, isTrue);
  });

  test('continuous task status preserves actual eligibility and cleanup', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => {
        'supported': true,
        'taskEnabled': true,
        'taskActive': false,
        'permissionStatus': 'eligibility_required',
        'actionRequired': 'obtain_task_keeping_acl_and_install_entitled_build',
        'cleanupPending': true,
      },
    );
    final protection = (await bridge.backgroundProtection())!;
    expect(protection.taskEnabled, isTrue);
    expect(protection.taskActive, isFalse);
    expect(protection.permissionStatus, 'eligibility_required');
    expect(protection.actionRequired, 'obtain_task_keeping_acl_and_install_entitled_build');
    expect(protection.cleanupPending, isTrue);
  });

  test('null and missing legacy methods do not invent support', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    expect(await bridge.backgroundProtection(), isNull);
    messenger.setMockMethodCallHandler(channel, null);
    expect(await bridge.backgroundProtection(), isNull);
    expect(BackgroundProtection.fromMap({'audioEnabled': true})!.supported, isFalse);
  });

  test('updates send only the requested preference, including false', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return {'supported': true, 'taskEnabled': false, 'taskActive': false};
    });
    await bridge.setBackgroundProtection(audioEnabled: true);
    await bridge.setBackgroundProtection(locationEnabled: false);
    final protection = await bridge.setBackgroundProtection(taskEnabled: false);
    expect(calls.map((call) => call.method), everyElement('setBackgroundProtection'));
    expect(calls.map((call) => call.arguments), [
      {'audioEnabled': true},
      {'locationEnabled': false},
      {'taskEnabled': false},
    ]);
    expect(protection!.taskActive, isFalse);
  });

  test('platform failures stay failures, not disabled or successful updates', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'native_failed');
    });
    await expectLater(bridge.backgroundProtection(), throwsA(isA<PlatformException>()));
    await expectLater(bridge.setBackgroundProtection(audioEnabled: true), throwsA(isA<PlatformException>()));
    expect(await bridge.openBackgroundProtectionSettings(), isFalse);
  });

  test('opening settings reports acceptance, not a permission grant', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'openBackgroundProtectionSettings');
      return true;
    });
    expect(await bridge.openBackgroundProtectionSettings(), isTrue);
  });
}
