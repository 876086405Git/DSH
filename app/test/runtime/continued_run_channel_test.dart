import 'package:dsh_app/runtime/continued_run.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Running extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool value) => state = value;
}

final _running = NotifierProvider<_Running, bool>(_Running.new);

Future<void> _flush(ProviderContainer container) async {
  await container.pump();
  await Future<void>.delayed(Duration.zero);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dsh/runtime');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  // The messenger observes real continuedRunProvider -> RuntimeBridge calls. It does
  // not emulate BGTaskScheduler or claim that an iOS background task has run.
  for (final platform in ['ios', 'android', 'ohos']) {
    test('$platform turn start, unchanged observation, end and next turn', () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      final container = ProviderContainer(overrides: [
        operatingSystemProvider.overrideWithValue(platform),
        localTurnRunningProvider.overrideWith((ref) => ref.watch(_running)),
      ]);
      addTearDown(() {
        container.dispose();
        messenger.setMockMethodCallHandler(channel, null);
      });
      container.listen(continuedRunProvider, (_, _) {});
      await _flush(container);
      for (final running in [true, true, false, false, true, false]) {
        container.read(_running.notifier).set(running);
        await _flush(container);
      }
      expect(calls.map((call) => call.method), platform == 'ios' ? List.filled(5, 'turnRunning') : isEmpty);
      expect(
        calls.map((call) => call.arguments),
        platform == 'ios' ? [false, true, false, true, false].map((value) => {'running': value}) : isEmpty,
      );
    });
  }

  for (final missing in [false, true]) {
    test('a ${missing ? 'missing' : 'refusing'} plugin does not prevent the next turn update', () async {
      final calls = <bool>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'turnRunning');
        final running = (call.arguments as Map)['running'] as bool;
        calls.add(running);
        if (calls.length == 2) {
          if (missing) throw MissingPluginException('test plugin unavailable');
          throw PlatformException(code: 'test_refused');
        }
        return null;
      });
      final container = ProviderContainer(overrides: [
        operatingSystemProvider.overrideWithValue('ios'),
        localTurnRunningProvider.overrideWith((ref) => ref.watch(_running)),
      ]);
      addTearDown(() {
        container.dispose();
        messenger.setMockMethodCallHandler(channel, null);
      });
      container.listen(continuedRunProvider, (_, _) {});
      await _flush(container);
      for (final running in [true, false, true, false]) {
        container.read(_running.notifier).set(running);
        await _flush(container);
      }
      expect(calls, [false, true, false, true, false]);
    });
  }
}
