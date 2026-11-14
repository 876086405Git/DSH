// Dart side of `dsh/speech` (android/.../speech/SpeechPlugin.kt): PCM streams
// played as they arrive, and the microphone during a voice call cut into
// utterances. One stream plays at a time; opening one stops the one before.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

sealed class SpeechAudioEvent {
  const SpeechAudioEvent();
}

enum PlayPhase { start, done, stopped, error }

/// A stream started, played to its end, was stopped, or failed.
final class PlayEvent extends SpeechAudioEvent {
  const PlayEvent(this.id, this.phase);
  final String id;
  final PlayPhase phase;
}

/// How loud the stream [id] is right now (0–1), timed to what is heard.
final class PlayLevel extends SpeechAudioEvent {
  const PlayLevel(this.id, this.value);
  final String id;
  final double value;
}

/// The person started speaking; [over] the app's own voice (which, with
/// barge-in on, has already stopped).
final class SpeechStart extends SpeechAudioEvent {
  const SpeechStart({required this.over});
  final bool over;
}

/// One utterance, as a 16 kHz mono WAV, once the person paused.
final class Utterance extends SpeechAudioEvent {
  const Utterance(this.wav, this.duration);
  final Uint8List wav;
  final Duration duration;
}

/// The microphone's level (0–1) during a call.
final class MicLevel extends SpeechAudioEvent {
  const MicLevel(this.value);
  final double value;
}

final class CallError extends SpeechAudioEvent {
  const CallError(this.reason);
  final String reason;
}

/// How long the person may pause before what they said counts as finished
/// (通话设置 → 停顿多久算说完): 快 is how calls were before it was a choice.
enum CallPause {
  quick(Duration.zero),
  normal(Duration(milliseconds: 400)),
  patient(Duration(milliseconds: 1000));

  const CallPause(this.longer);

  /// How much longer than 快 a finished utterance takes to come through
  /// (its trailing quiet: TurnPause.doneMs on the native side).
  final Duration longer;
}

enum CallStart { ok, permission, microphone, unavailable }

class SpeechAudio {
  SpeechAudio([MethodChannel? channel]) : _channel = channel ?? const MethodChannel('dsh/speech') {
    _channel.setMethodCallHandler(_heard);
  }

  final MethodChannel _channel;
  final _events = StreamController<SpeechAudioEvent>.broadcast();

  Stream<SpeechAudioEvent> get events => _events.stream;

  Future<void> _heard(MethodCall call) async {
    if (call.method != 'event') return;
    final args = call.arguments;
    if (args is! Map) return;
    double value() => ((args['value'] as num?) ?? 0).toDouble().clamp(0.0, 1.0);
    final event = switch (args['type']) {
      'play' => switch (PlayPhase.values.asNameMap()[args['what']]) {
        final phase? when args['id'] is String => PlayEvent(args['id'] as String, phase),
        _ => null,
      },
      'playLevel' when args['id'] is String => PlayLevel(args['id'] as String, value()),
      'speechStart' => SpeechStart(over: args['over'] == true),
      'utterance' when args['wav'] is Uint8List => Utterance(
        args['wav'] as Uint8List,
        Duration(milliseconds: (args['ms'] as num?)?.toInt() ?? 0),
      ),
      'micLevel' => MicLevel(value()),
      'callError' => CallError('${args['reason']}'),
      _ => null,
    };
    if (event != null && !_events.isClosed) _events.add(event);
  }

  Future<T?> _invoke<T>(String method, [Object? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Opens stream [id] of PCM16 mono at [rate]; [call] plays it as the voice
  /// of a call, [levels] reports its loudness. False when it can't play.
  Future<bool> open(String id, {int rate = 24000, bool call = false, bool levels = false}) async =>
      await _invoke<bool>('open', {'id': id, 'rate': rate, 'call': call, 'levels': levels}) ?? false;

  /// Queues [bytes] on stream [id]; the bytes now waiting to play, or -1 when
  /// the stream is gone.
  Future<int> write(String id, Uint8List bytes) async => await _invoke<int>('write', {'id': id, 'bytes': bytes}) ?? -1;

  /// The bytes waiting to play on stream [id], or -1 when it is gone.
  Future<int> waiting(String id) async => await _invoke<int>('waiting', {'id': id}) ?? -1;

  /// Nothing more for [id]: it reports done once the last sample is heard.
  Future<void> end(String id) => _invoke<void>('end', {'id': id});

  Future<void> stop() => _invoke<void>('stop');

  /// Stream [id] quieter while the person may be speaking over it, or back to full.
  Future<void> duck(String id, bool on) => _invoke<void>('duck', {'id': id, 'on': on});

  Future<CallStart> startCall({required bool bargeIn, CallPause pause = CallPause.normal}) async =>
      switch (await _invoke<String>('callStart', {'bargeIn': bargeIn, 'pause': pause.name})) {
        'ok' => CallStart.ok,
        'permission' => CallStart.permission,
        'microphone' => CallStart.microphone,
        _ => CallStart.unavailable,
      };

  Future<void> stopCall() => _invoke<void>('callStop');
  Future<void> mute(bool on) => _invoke<void>('callMute', {'on': on});
  Future<void> bargeIn(bool on) => _invoke<void>('callBargeIn', {'on': on});

  /// How long a pause ends what the person says, from now on in this call.
  Future<void> callPause(CallPause pause) => _invoke<void>('callPause', {'pause': pause.name});

  /// Another player of the app's voice (the phone's own text-to-speech, a
  /// fetched file) started or stopped: the call listens more strictly meanwhile.
  Future<void> playing(bool on) => _invoke<void>('callPlaying', {'on': on});

  /// Loudspeaker or not; the answer is what is in effect.
  Future<bool> speaker(bool on) async => await _invoke<bool>('callSpeaker', {'on': on}) ?? on;

  void dispose() {
    _channel.setMethodCallHandler(null);
    unawaited(_events.close());
  }
}

final speechAudioProvider = Provider<SpeechAudio>((ref) {
  final audio = SpeechAudio();
  ref.onDispose(audio.dispose);
  return audio;
});
