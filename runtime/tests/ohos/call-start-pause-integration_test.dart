import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/speech/call/voice_call.dart';
import 'package:dsh_app/speech/speech_audio.dart';
import 'package:dsh_app/speech/speech_settings.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/method_channel_shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import '../../../app/test/speech/speech_fakes.dart';

const _channel = MethodChannel('dsh/speech');
const _prefsChannel = MethodChannel('plugins.flutter.io/shared_preferences');

class _Native {
  _Native(this.process) {
    process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      final row = jsonDecode(line) as Map<String, dynamic>;
      final done = pending.remove(row['id']);
      if (row.containsKey('error')) {
        done?.completeError(StateError(row['error'] as String));
      } else {
        done?.complete(row['result']);
      }
    });
    process.stderr.transform(utf8.decoder).listen(errors.write);
  }
  final Process process;
  final pending = <int, Completer<Object?>>{};
  final errors = StringBuffer();
  int next = 0;

  static Future<_Native> start() async {
    final node = Platform.environment['NODE'];
    if (node == null) throw StateError('NODE must name the existing local Node executable');
    return _Native(await Process.start(node, [File('../runtime/tests/ohos/call-start-pause-rpc.mjs').absolute.path]));
  }

  Future<Object?> request(String method, [Object? args]) {
    final id = ++next, done = Completer<Object?>();
    pending[id] = done;
    process.stdin.writeln(jsonEncode({'id': id, 'method': method, 'args': args}));
    return done.future.timeout(const Duration(seconds: 10));
  }

  Future<void> close() async {
    await request('close');
    await process.stdin.close();
    expect(await process.exitCode.timeout(const Duration(seconds: 10)), 0, reason: errors.toString());
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final duringLoad in [false, true]) {
    final scenario = duringLoad ? 'actual-settings-load-pending' : 'actual-native-permission-pending';
    test('OH $scenario keeps the newly selected patient pause', () async {
      final native = await _Native.start();
      final wire = <Map<String, Object?>>[];
      final pauseDelivered = Completer<void>();
      final prefsLoaded = Completer<Map<String, Object>>();
      final originalStore = SharedPreferencesStorePlatform.instance;
      // Repository OH tests live outside Dart's conventional test/ directory.
      // ignore: invalid_use_of_visible_for_testing_member
      SharedPreferences.resetStatic();
      SharedPreferencesStorePlatform.instance = MethodChannelSharedPreferencesStore();
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(_prefsChannel, (method) async {
        if (method.method == 'getAll') return prefsLoaded.future;
        if (method.method == 'setString') return true;
        throw StateError('unexpected preferences boundary: ${method.method}');
      });
      messenger.setMockMethodCallHandler(_channel, (method) async {
        wire.add({'method': method.method, 'arguments': method.arguments});
        final result = await native.request('speech', {'method': method.method, 'arguments': method.arguments}) as Map;
        if (method.method == 'callPause' && !pauseDelivered.isCompleted) pauseDelivered.complete();
        if (result['error'] case final String code) throw PlatformException(code: code);
        return result['value'];
      });
      final container = ProviderContainer(overrides: [operatingSystemProvider.overrideWithValue('ohos')]);
      final settings = container.read(callSettingsProvider.notifier);
      final call = VoiceCallController(
        audio: container.read(speechAudioProvider),
        conversation: FakeConversation(),
        recognizer: () async => FakeCloud(),
        voice: FakeOut.new,
        // Same actual settings provider and await order used by VoiceCallPage.
        choices: () async {
          final saved = await settings.ready();
          return (bargeIn: saved.bargeIn, speaker: saved.speaker, spokenHint: null, pause: saved.pause);
        },
      );
      final subscription = container.listen(callSettingsProvider.select((settings) => settings.pause), (_, pause) {
        call.setPause(pause);
      });
      const loaded = <String, Object>{'flutter.speech_call_v1': '{"pause":"normal"}'};
      try {
        if (!duringLoad) {
          prefsLoaded.complete(loaded);
          await settings.ready();
          await native.request('permission.hold');
        }
        final starting = call.start();
        if (!duringLoad) await native.request('permission.entered');
        // The in-call settings sheet uses this exact notifier.edit operation.
        // Its menu is available while phase is starting; no UI implementation is replaced.
        final editing = settings.edit((saved) => saved.copyWith(pause: CallPause.patient));
        if (duringLoad) prefsLoaded.complete(loaded);
        await editing;
        await pauseDelivered.future.timeout(const Duration(seconds: 10));
        if (!duringLoad) await native.request('permission.release');
        await starting.timeout(const Duration(seconds: 10));
        final beforePatientDeadline = await native.request('input', {'loud': 30, 'quiet': 55}) as Map;
        final afterPatientDeadline = await native.request('input', {'loud': 0, 'quiet': 25}) as Map;
        call.hangUp();
        await pumpEventQueue();
        final closed = await native.request('close') as Map;
        debugPrint(
          jsonEncode({
            'case': scenario,
            'providerPause': container.read(callSettingsProvider).pause.name,
            'wire': wire,
            'after1100msQuietFrames': beforePatientDeadline,
            'after1600msQuietFrames': afterPatientDeadline,
            'closed': closed,
          }),
        );
        expect(container.read(callSettingsProvider).pause, CallPause.patient);
        expect(beforePatientDeadline['speechStarts'], 1);
        expect(
          beforePatientDeadline['wavUtterances'],
          0,
          reason: 'patient choice must not end at the old normal threshold',
        );
        expect(afterPatientDeadline['wavUtterances'], 1);
        expect(closed['releases'], 1);
        expect(closed['keepScreenOn'], isFalse);
      } finally {
        subscription.close();
        call.dispose();
        await pumpEventQueue();
        container.dispose();
        messenger.setMockMethodCallHandler(_channel, null);
        messenger.setMockMethodCallHandler(_prefsChannel, null);
        SharedPreferencesStorePlatform.instance = originalStore;
        // Test-only cleanup in the same required external OH test directory.
        // ignore: invalid_use_of_visible_for_testing_member
        SharedPreferences.resetStatic();
        await native.close();
      }
    });
  }
}
