import 'dart:async';

import 'package:dsh_app/speech/call/voice_call.dart';
import 'package:dsh_app/speech/speech_audio.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../app/test/speech/speech_fakes.dart';

const _channel = MethodChannel('dsh/speech');
const _chosen = (
  bargeIn: true,
  speaker: true,
  spokenHint: null,
  pause: CallPause.quick,
);

class _Rig {
  _Rig({String platform = 'ohos'}) {
    container = ProviderContainer(
      overrides: [operatingSystemProvider.overrideWithValue(platform)],
    );
    audio = container.read(speechAudioProvider);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call);
          if (call.method == 'callStart')
            return starting == null ? 'ok' : await starting!();
          if (call.method == 'callSpeaker')
            return (call.arguments as Map)['on'];
          return null;
        });
    addTearDown(() {
      for (final call in controllers) {
        call.dispose();
      }
      container.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, null);
    });
  }

  late final ProviderContainer container;
  late final SpeechAudio audio;
  final calls = <MethodCall>[];
  final controllers = <VoiceCallController>[];
  Future<String> Function()? starting;

  VoiceCallController controller({
    Future<CallChoices> Function()? choices,
    Future<bool> Function()? permission,
  }) {
    final call = VoiceCallController(
      audio: audio,
      conversation: FakeConversation(),
      recognizer: () async => FakeCloud(),
      voice: FakeOut.new,
      choices: choices ?? () async => _chosen,
      permission: permission,
    );
    controllers.add(call);
    return call;
  }

  Map get startArguments =>
      calls.singleWhere((call) => call.method == 'callStart').arguments as Map;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('OH mute chosen while Flutter permission waits is carried into native start', () async {
    final rig = _Rig(),
        entered = Completer<void>(),
        permission = Completer<bool>();
    final call = rig.controller(
      permission: () {
        entered.complete();
        return permission.future;
      },
    );
    final starting = call.start();
    await entered.future;
    call.setMuted(true);
    await pumpEventQueue();
    final beforePermission = rig.calls.map((call) => call.method).toList();
    permission.complete(true);
    await starting;
    expect(beforePermission, ['callMute']);
    expect(rig.startArguments, {
      'bargeIn': true,
      'pause': 'quick',
      'muted': true,
    });
    expect(call.muted, isTrue);
    expect(call.phase, CallPhase.listening);
  });

  test('OH latest unmute while choices wait reaches start instead of an older mute', () async {
    final rig = _Rig(), choices = Completer<CallChoices>();
    final call = rig.controller(choices: () => choices.future);
    final starting = call.start();
    call.setMuted(true);
    call.setMuted(false);
    await pumpEventQueue();
    choices.complete(_chosen);
    await starting;
    expect(rig.startArguments, {
      'bargeIn': true,
      'pause': 'quick',
      'muted': false,
    });
    expect(call.muted, isFalse);
    expect(
      rig.calls
          .where((call) => call.method == 'callMute')
          .map((call) => call.arguments),
      [
        {'on': true},
        {'on': false},
      ],
    );
  });

  test('OH mute after native start dispatch remains later than its initial unmuted snapshot', () async {
    final rig = _Rig(), entered = Completer<void>(), ack = Completer<String>();
    rig.starting = () {
      entered.complete();
      return ack.future;
    };
    final call = rig.controller(), starting = call.start();
    await entered.future;
    call.setMuted(true);
    await pumpEventQueue();
    final beforeAck = rig.calls.map((call) => call.method).toList();
    ack.complete('ok');
    await starting;
    expect(beforeAck, ['callStart', 'callMute']);
    expect(rig.startArguments, {
      'bargeIn': true,
      'pause': 'quick',
      'muted': false,
    });
    expect(call.muted, isTrue);
    expect(rig.calls.where((call) => call.method == 'callMute'), hasLength(1));
  });

  test('OH ended preparing controller does not start or transfer its mute to the next controller', () async {
    final rig = _Rig(), choices = Completer<CallChoices>();
    final old = rig.controller(choices: () => choices.future),
        starting = old.start();
    old.setMuted(true);
    old.hangUp();
    choices.complete(_chosen);
    await starting;
    expect(rig.calls.where((call) => call.method == 'callStart'), isEmpty);
    final next = rig.controller();
    await next.start();
    expect(rig.startArguments, {
      'bargeIn': true,
      'pause': 'quick',
      'muted': false,
    });
    expect(next.muted, isFalse);
    expect(old.ended, CallEnd.hungUp);
  });

  test('permission refusal still prevents native start even after a preparing mute', () async {
    final rig = _Rig(),
        entered = Completer<void>(),
        permission = Completer<bool>();
    final call = rig.controller(
      permission: () {
        entered.complete();
        return permission.future;
      },
    );
    final starting = call.start();
    await entered.future;
    call.setMuted(true);
    permission.complete(false);
    await starting;
    expect(call.ended, CallEnd.permission);
    expect(rig.calls.where((call) => call.method == 'callStart'), isEmpty);
  });

  test('Android preparing mute keeps the exact existing callStart payload and mute order', () async {
    final rig = _Rig(platform: 'android'), choices = Completer<CallChoices>();
    final call = rig.controller(choices: () => choices.future),
        starting = call.start();
    call.setMuted(true);
    await pumpEventQueue();
    choices.complete(_chosen);
    await starting;
    expect(rig.startArguments, {'bargeIn': true, 'pause': 'quick'});
    expect(rig.calls.map((call) => call.method), [
      'callMute',
      'callStart',
      'callSpeaker',
    ]);
    expect(call.muted, isTrue);
  });

  test('default SpeechAudio startCall keeps the existing payload without an OH field', () async {
    final rig = _Rig(platform: 'android');
    expect(
      await rig.audio.startCall(bargeIn: false, pause: CallPause.patient),
      CallStart.ok,
    );
    expect(rig.startArguments, {'bargeIn': false, 'pause': 'patient'});
  });
}
