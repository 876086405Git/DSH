import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/speech/call/voice_call.dart';
import 'package:dsh_app/speech/speech_audio.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../app/test/speech/speech_fakes.dart';

const _channel = MethodChannel('dsh/speech');

class _Native {
  _Native(this.process) {
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
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
    if (node == null)
      throw StateError(
        'NODE must name the already installed local Node executable',
      );
    return _Native(
      await Process.start(node, [
        File('../runtime/tests/ohos/call-start-mute-rpc.mjs').absolute.path,
      ]),
    );
  }

  Future<Object?> request(String method, [Object? args]) {
    final id = ++next, done = Completer<Object?>();
    pending[id] = done;
    process.stdin.writeln(
      jsonEncode({'id': id, 'method': method, 'args': args}),
    );
    return done.future.timeout(const Duration(seconds: 10));
  }

  Future<void> close() async {
    await request('close');
    await process.stdin.close();
    expect(
      await process.exitCode.timeout(const Duration(seconds: 10)),
      0,
      reason: errors.toString(),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final duringPermission in [false, true]) {
    final scenario = duringPermission
        ? 'native-permission-pending'
        : 'choices-pending';
    test(
      'OH $scenario mute reaches actual ETS before first PCM and WAV publication',
      () async {
        final native = await _Native.start();
        final wire = <Map<String, Object?>>[];
        final firstMute = Completer<void>(), secondMute = Completer<void>();
        var muteRequests = 0;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(_channel, (method) async {
              wire.add({
                'method': method.method,
                'arguments': method.arguments,
              });
              final result = await native.request('speech', {
                'method': method.method,
                'arguments': method.arguments,
              }) as Map;
              if (method.method == 'callMute') {
                if (++muteRequests == 1) {
                  firstMute.complete();
                } else {
                  secondMute.complete();
                }
              }
              if (result['error'] case final String code)
                throw PlatformException(code: code);
              return result['value'];
            });
        final container = ProviderContainer(
          overrides: [operatingSystemProvider.overrideWithValue('ohos')],
        );
        final audio = container.read(speechAudioProvider);
        final choices = Completer<CallChoices>();
        final call = VoiceCallController(
          audio: audio,
          conversation: FakeConversation(),
          recognizer: () async => FakeCloud(),
          voice: FakeOut.new,
          choices: () => choices.future,
        );
        try {
          if (duringPermission) await native.request('permission.hold');
          final starting = call.start();
          const chosen = (
            bargeIn: true,
            speaker: true,
            spokenHint: null,
            pause: CallPause.quick,
          );
          if (duringPermission) {
            choices.complete(chosen);
            await native.request('permission.entered');
          }
          // The actual page enables mute while choices or native permission is pending.
          // Both waits are released below; there is no permanent mock RPC.
          call.setMuted(true);
          await firstMute.future.timeout(const Duration(seconds: 10));
          if (duringPermission) {
            await native.request('permission.release');
          } else {
            choices.complete(chosen);
          }
          await starting.timeout(const Duration(seconds: 10));
          final beforeUnmute = await native.request('input') as Map;
          call.setMuted(false);
          await secondMute.future.timeout(const Duration(seconds: 10));
          final afterUnmute = await native.request('input') as Map;
          call.hangUp();
          await pumpEventQueue();
          final closed = await native.request('close') as Map;
          debugPrint(
            jsonEncode({
              'case': scenario,
              'wire': wire,
              'muted': beforeUnmute,
              'unmuted': afterUnmute,
              'closed': closed,
            }),
          );
          expect(beforeUnmute['capturers'], 1);
          expect(
            beforeUnmute['pcmFrames'],
            0,
            reason: 'muted call must not publish caption PCM',
          );
          expect(
            beforeUnmute['wavUtterances'],
            0,
            reason: 'muted call must not publish utterance WAV',
          );
          expect(beforeUnmute['speechStarts'], 0);
          expect(beforeUnmute['nonzeroLevels'], 0);
          expect(
            afterUnmute['pcmFrames'],
            greaterThan(0),
            reason: 'the same real capture must publish after explicit unmute',
          );
          expect(afterUnmute['wavUtterances'], greaterThan(0));
          expect(closed['releases'], 1);
          expect(closed['keepScreenOn'], isFalse);
        } finally {
          call.dispose();
          await pumpEventQueue();
          container.dispose();
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(_channel, null);
          await native.close();
        }
      },
    );
  }
}
