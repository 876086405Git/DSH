// A stand-in for android/.../pet/PetOverlayPlugin.kt on `dsh/pet_overlay`.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeOverlayNative {
  FakeOverlayNative({
    this.platform = 'android',
    this.permission = 'denied',
    this.enabled = false,
    this.alwaysShow = false,
    this.snoozed = false,
    this.sdk = 35,
    this.manufacturer = 'vivo',
    this.opens = true,
    this.companionFallback = false,
  });

  static const channel = MethodChannel('dsh/pet_overlay');

  final String platform;
  String permission;
  bool enabled;
  bool alwaysShow;
  bool snoozed;
  int sdk;
  String manufacturer;

  /// What requestPermission / openAppDetails answer (the settings page opened).
  bool opens;

  /// The companion gave up and the pixel pet is filling in.
  bool companionFallback;

  final calls = <MethodCall>[];

  List<String> get methods => [for (final c in calls) c.method];

  Map<String, Object?> get status => {
    'platform': platform,
    'enabled': enabled,
    'alwaysShow': alwaysShow,
    'permission': permission,
    'canDraw': permission == 'granted' || permission == 'blocked',
    'accessibility': permission == 'accessibility',
    'snoozed': snoozed,
    'showing': false,
    'sdk': sdk,
    'manufacturer': manufacturer,
    if (companionFallback) 'companionFallback': true,
  };

  TestDefaultBinaryMessenger get _messenger => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void install() {
    _messenger.setMockMethodCallHandler(channel, _handle);
    addTearDown(() => _messenger.setMockMethodCallHandler(channel, null));
  }

  Future<Object?> _handle(MethodCall call) async {
    calls.add(call);
    final args = call.arguments is Map ? call.arguments as Map : const {};
    switch (call.method) {
      case 'push' || 'reloadPack':
        return null;
      case 'setEnabled':
        enabled = args['enabled'] == true;
        return status;
      case 'setAlwaysShow':
        alwaysShow = args['on'] == true;
        return status;
      case 'unsnooze':
        snoozed = false;
        return status;
      case 'status' || 'permissionStatus':
        return status;
      case 'configureCompanion':
        return status;
      case 'requestPermission' || 'openAppDetails':
        return opens;
    }
    throw MissingPluginException(call.method);
  }

  /// A status event from the native side (the pet's menu, a permission found out).
  Future<void> emitStatus() => _messenger.handlePlatformMessage(
    channel.name,
    channel.codec.encodeMethodCall(MethodCall('status', status)),
    (_) {},
  );

  /// 「宠物设置」 tapped in the floating pet's menu.
  Future<void> emitOpenSettings() => _messenger.handlePlatformMessage(
    channel.name,
    channel.codec.encodeMethodCall(const MethodCall('openSettings')),
    (_) {},
  );
}

/// No native side at all (desktop, plain widget tests).
void removeOverlayNative() {
  final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  m.setMockMethodCallHandler(FakeOverlayNative.channel, (call) async => throw MissingPluginException(call.method));
  addTearDown(() => m.setMockMethodCallHandler(FakeOverlayNative.channel, null));
}
