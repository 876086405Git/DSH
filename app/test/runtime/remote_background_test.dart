import 'dart:async';

import 'package:dsh_app/remote/remote_background.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _host = HostRef.ssh('remote');
const _channel = MethodChannel('io.github.ccch1mneyyy.dsh_app/remote_background');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('remote enhancements are opt-in and independent of the remote link signal', () async {
    SharedPreferences.setMockInitialValues({});
    final calls = <String>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add('${call.method}:${call.arguments}');
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(_channel, null));
    final container = ProviderContainer(overrides: [operatingSystemProvider.overrideWithValue('android')]);
    addTearDown(container.dispose);
    container.listen(remoteBackgroundProvider, (_, _) {});
    expect(await container.read(remoteBackgroundOptionsProvider.future), (audio: false, location: false));
    expect(calls, isEmpty);

    final options = container.read(remoteBackgroundOptionsProvider.notifier);
    await options.setAudio(true);
    await options.setLocation(true);
    await options.setAudio(false);
    await container.pump();
    expect(calls, ['setRemoteAudio:true', 'setRemoteLocation:true', 'setRemoteAudio:false']);
    expect(container.read(remoteBackgroundOptionsProvider).value, (audio: false, location: true));
  });

  test('arms only after the remote link connects, keeps recovery armed, then releases', () async {
    SharedPreferences.setMockInitialValues({ActiveHostController.prefsKey: _host.encode()});
    final signals = <bool>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_channel, (call) async {
      expect(call.method, 'setRemoteActive');
      signals.add(call.arguments as bool);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(_channel, null));
    final statuses = StreamController<HostLinkStatus>();
    addTearDown(statuses.close);
    final container = ProviderContainer(
      overrides: [
        operatingSystemProvider.overrideWithValue('android'),
        hostLinkStatusProvider(_host).overrideWith((ref) => statuses.stream),
      ],
    );
    addTearDown(container.dispose);
    container.listen(remoteBackgroundProvider, (_, _) {});
    await container.read(activeHostProvider.notifier).ready;

    Future<void> phase(HostLinkPhase phase) async {
      statuses.add(HostLinkStatus(phase));
      await Future<void>.delayed(Duration.zero);
      await container.pump();
    }

    await phase(HostLinkPhase.reconnecting);
    expect(signals, isEmpty);
    await phase(HostLinkPhase.connected);
    expect(signals, [true]);
    await phase(HostLinkPhase.reconnecting);
    expect(signals, [true]);
    await phase(HostLinkPhase.failed);
    expect(signals, [true, false]);

    await phase(HostLinkPhase.connected);
    container.read(activeHostProvider.notifier).select(HostRef.local);
    await container.pump();
    expect(signals, [true, false, true, false]);
  });
}
