import 'dart:async';

import 'package:dsh_app/speech/call/voice_call.dart';
import 'package:dsh_app/speech/speech_audio.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../app/test/speech/speech_fakes.dart';

const _channel = MethodChannel('dsh/speech');

class _Rig {
  _Rig({String platform = 'ohos', this.chosenSpeaker = true}) {
    container = ProviderContainer(overrides: [operatingSystemProvider.overrideWithValue(platform)]);
    audio = container.read(speechAudioProvider);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      if (call.method == 'callSpeaker') {
        final on = (call.arguments as Map)['on'] as bool;
        return route == null ? on : await route!(on);
      }
      if (call.method == 'callStart') return starting == null ? 'ok' : await starting!();
      return null;
    });
    addTearDown(() {
      for (final call in controllers) {
        call.dispose();
      }
      container.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null);
    });
  }

  final bool chosenSpeaker;
  late final ProviderContainer container;
  late final SpeechAudio audio;
  final List<MethodCall> calls = <MethodCall>[];
  final List<VoiceCallController> controllers = <VoiceCallController>[];
  Future<Object?> Function(bool)? route;
  Future<Object?> Function()? starting;

  VoiceCallController controller() {
    final call = VoiceCallController(
      audio: audio,
      conversation: FakeConversation(),
      recognizer: () async => FakeCloud(),
      voice: FakeOut.new,
      choices: () async => (bargeIn: true, speaker: chosenSpeaker, spokenHint: null, pause: CallPause.quick),
    );
    controllers.add(call);
    return call;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('OH provider preserves a speech-output refusal instead of acknowledging the requested preference', () async {
    final rig = _Rig();
    rig.route = (_) async => throw PlatformException(code: 'speech-output', message: 'route inactive');
    await expectLater(rig.audio.speaker(false), throwsA(isA<PlatformException>()));
  });

  test('OH provider rejects a missing plugin acknowledgement', () async {
    final rig = _Rig();
    rig.route = (_) async => throw MissingPluginException('speaker missing');
    await expectLater(rig.audio.speaker(false), throwsA(isA<MissingPluginException>()));
  });

  test('OH provider rejects a missing Boolean acknowledgement', () async {
    final rig = _Rig();
    rig.route = (_) async => null;
    await expectLater(rig.audio.speaker(false), throwsA(isA<PlatformException>()));
  });

  test('OH accepts the successful false acknowledgement', () async {
    final rig = _Rig();
    expect(await rig.audio.speaker(false), isFalse);
  });

  test('Android keeps existing refusal, missing plugin and null fallbacks', () async {
    final rig = _Rig(platform: 'android');
    rig.route = (_) async => throw PlatformException(code: 'speech-output');
    expect(await rig.audio.speaker(false), isFalse);
    rig.route = (_) async => throw MissingPluginException();
    expect(await rig.audio.speaker(true), isTrue);
    rig.route = (_) async => null;
    expect(await rig.audio.speaker(false), isFalse);
  });

  test(
    'actual OH call retains acknowledged preference on refusal and a successful retry clears its route error',
    () async {
      final rig = _Rig();
      final call = rig.controller();
      await call.start();
      rig.route = (_) async => throw PlatformException(code: 'speech-output', message: 'session lost');
      await call.setSpeaker(false);
      expect(call.speaker, isTrue);
      expect(call.error, isA<PlatformException>());
      expect(call.phase, CallPhase.listening);
      rig.route = (on) async => on;
      await call.setSpeaker(false);
      expect(call.speaker, isFalse);
      expect(call.error, isNull);
      expect(rig.calls.where((c) => c.method == 'callStop'), isEmpty);
    },
  );

  test('OH initial route refusal ends the call without claiming the unacknowledged saved preference', () async {
    final rig = _Rig(chosenSpeaker: false);
    final call = rig.controller();
    rig.route = (_) async => throw PlatformException(code: 'speech-output', message: 'initial route rejected');
    await call.start();
    expect(call.speaker, isTrue);
    expect(call.error, isA<PlatformException>());
    expect(call.phase, CallPhase.ended);
    expect(call.ended, CallEnd.failed);
  });

  test('OH hang up while initial route is pending cannot be revived by its late acknowledgement', () async {
    final rig = _Rig(chosenSpeaker: false);
    final call = rig.controller();
    final entered = Completer<void>(), reply = Completer<Object?>();
    rig.route = (_) {
      entered.complete();
      return reply.future;
    };
    final starting = call.start();
    await entered.future;
    call.hangUp();
    reply.complete(false);
    await starting;
    expect(call.phase, CallPhase.ended);
    expect(call.ended, CallEnd.hungUp);
    expect(call.speaker, isTrue);
    expect(rig.calls.where((c) => c.method == 'callStop'), hasLength(1));
  });

  test('OH initial route cannot overwrite a newer explicit preference', () async {
    final rig = _Rig();
    final call = rig.controller();
    final entered = Completer<void>(), initial = Completer<Object?>();
    var requests = 0;
    rig.route = (on) {
      if (++requests == 1) {
        entered.complete();
        return initial.future;
      }
      return Future<Object?>.value(on);
    };
    final starting = call.start();
    await entered.future;
    await call.setSpeaker(false);
    initial.complete(true);
    await starting;
    expect(call.speaker, isFalse);
    expect(call.error, isNull);
    expect(call.phase, CallPhase.listening);
  });

  test('OH superseded route refusal does not replace a later accepted preference with an error', () async {
    final rig = _Rig();
    final call = rig.controller();
    await call.start();
    final entered = Completer<void>(), old = Completer<Object?>();
    var requests = 0;
    rig.route = (on) {
      if (++requests == 1) {
        entered.complete();
        return old.future;
      }
      return Future<Object?>.value(on);
    };
    final earlier = call.setSpeaker(false);
    await entered.future;
    await call.setSpeaker(true);
    old.completeError(PlatformException(code: 'speech-output', message: 'superseded'));
    await earlier;
    expect(call.speaker, isTrue);
    expect(call.error, isNull);
  });

  test('OH superseded initial refusal waits for the still-pending latest preference before listening', () async {
    final rig = _Rig();
    final call = rig.controller();
    final initialEntered = Completer<void>(), latestEntered = Completer<void>();
    final initial = Completer<Object?>(), latest = Completer<Object?>();
    var requests = 0;
    rig.route = (_) {
      if (++requests == 1) {
        initialEntered.complete();
        return initial.future;
      }
      latestEntered.complete();
      return latest.future;
    };
    var startDone = false;
    final starting = call.start().then((_) {
      startDone = true;
    });
    await initialEntered.future;
    final changing = call.setSpeaker(false);
    await latestEntered.future;
    initial.completeError(PlatformException(code: 'speech-output', message: 'superseded'));
    await pumpEventQueue();
    final phaseBeforeLatest = call.phase;
    final errorBeforeLatest = call.error;
    final startDoneBeforeLatest = startDone;
    latest.complete(false);
    await changing;
    await starting;
    expect(phaseBeforeLatest, CallPhase.starting);
    expect(errorBeforeLatest, isNull);
    expect(startDoneBeforeLatest, isFalse);
    expect(call.phase, CallPhase.listening);
    expect(call.speaker, isFalse);
  });

  test('OH late old-controller reply neither revives it nor stops the new call sharing the channel', () async {
    final rig = _Rig();
    final oldCall = rig.controller();
    final entered = Completer<void>(), old = Completer<Object?>();
    var requests = 0;
    rig.route = (on) {
      if (++requests == 1) {
        entered.complete();
        return old.future;
      }
      return Future<Object?>.value(on);
    };
    final starting = oldCall.start();
    await entered.future;
    oldCall.hangUp();
    final next = rig.controller();
    await next.start();
    old.complete(true);
    await starting;
    expect(oldCall.phase, CallPhase.ended);
    expect(next.phase, CallPhase.listening);
    expect(next.error, isNull);
    expect(rig.calls.where((c) => c.method == 'callStop'), hasLength(1));
  });

  test('OH disposal suppresses late route refusal and keeps the call ended', () async {
    final rig = _Rig();
    final call = rig.controller();
    final entered = Completer<void>(), reply = Completer<Object?>();
    rig.route = (_) {
      entered.complete();
      return reply.future;
    };
    final starting = call.start();
    await entered.future;
    call.dispose();
    rig.controllers.remove(call);
    reply.completeError(PlatformException(code: 'speech-output', message: 'owner retired'));
    await starting;
    expect(call.phase, CallPhase.ended);
    expect(call.error, isNull);
  });

  for (final platform in ['ohos', 'android']) {
    test('$platform callStart late acknowledgement keeps its platform retirement contract', () async {
      final rig = _Rig(platform: platform);
      final entered = Completer<void>(), nextEntered = Completer<void>();
      final oldReply = Completer<Object?>(), nextReply = Completer<Object?>();
      var starts = 0;
      // Native already computed the old successful acknowledgement. Only its
      // delivery is delayed; no stale native owner is made to succeed again.
      const oldAcknowledgement = 'ok';
      rig.starting = () {
        if (++starts == 1) {
          entered.complete();
          return oldReply.future;
        }
        nextEntered.complete();
        return nextReply.future;
      };
      final oldCall = rig.controller();
      final oldStart = oldCall.start();
      await entered.future;
      oldCall.hangUp();
      final next = rig.controller();
      final nextStart = next.start();
      await nextEntered.future;
      // The new start has been sent, but its acknowledgement need not overtake
      // the old one. An extra global stop here is after that new start request.
      oldReply.complete(oldAcknowledgement);
      await oldStart;
      await pumpEventQueue();
      nextReply.complete('ok');
      await nextStart;
      expect(oldCall.phase, CallPhase.ended);
      expect(next.phase, CallPhase.listening);
      expect(rig.calls.where((c) => c.method == 'callStop'), hasLength(platform == 'ohos' ? 1 : 2));
    });
  }

  for (final platform in ['ohos', 'android']) {
    test('$platform preserves a newer accepted speaker choice made before callStart acknowledgement', () async {
      final rig = _Rig(platform: platform);
      final call = rig.controller();
      final entered = Completer<void>(), started = Completer<Object?>();
      rig.starting = () {
        entered.complete();
        return started.future;
      };
      final starting = call.start();
      await entered.future;
      await call.setSpeaker(false);
      final acceptedBeforeStart = call.speaker;
      started.complete('ok');
      await starting;
      expect(acceptedBeforeStart, isFalse);
      expect(call.speaker, isFalse);
      expect(call.phase, CallPhase.listening);
      expect(rig.calls.where((c) => c.method == 'callSpeaker').map((c) => (c.arguments as Map)['on']), [false, false]);
    });
  }
}
