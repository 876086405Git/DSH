// Dart side of the voice platform channel
// (`android/.../voice/VoicePlugin.kt`): the system speech recognizer with
// partial results, and a 16 kHz PCM recorder for the engine's recognizer.

import 'dart:async';

import 'package:flutter/services.dart';

import '../../../voice/voice_platform_events.dart';

/// What the phone can do.
/// 「内置模型」的状态：模型是否已加载，以及加载失败的原因。
class VoiceOfflineStatus {
  const VoiceOfflineStatus({required this.ready, this.failure});

  static const unavailable = VoiceOfflineStatus(ready: false);

  final bool ready;

  /// 加载失败的原因；null 表示没失败过（可能还没加载）。
  final String? failure;

  factory VoiceOfflineStatus.fromMap(Map<Object?, Object?>? map) => VoiceOfflineStatus(
    ready: map?['ready'] == true,
    failure: map?['failure'] as String?,
  );
}

class VoiceCapabilities {
  const VoiceCapabilities({
    required this.recognizer,
    required this.recorder,
    this.systemUnreliable = false,
    this.environmentId,
  });

  static const none = VoiceCapabilities(recognizer: false, recorder: false);

  /// `SpeechRecognizer.isRecognitionAvailable`: a recognition service is
  /// installed (Google's, or the vendor's own).
  final bool recognizer;

  /// The microphone can be recorded for the engine's recognizer.
  final bool recorder;

  /// A service failure remembered for this OS build and recognition service version.
  final bool systemUnreliable;
  final String? environmentId;
}

enum VoicePermission { granted, denied, blocked }

/// Events while listening.
sealed class VoiceEvent {
  const VoiceEvent();
}

/// Input level, 0 (silence) to 1.
final class VoiceLevel extends VoiceEvent {
  const VoiceLevel(this.value);
  final double value;
}

/// The recognizer's best guess so far (system recognizer only).
final class VoicePartial extends VoiceEvent {
  const VoicePartial(this.text);
  final String text;
}

/// The final text of a system recognition.
final class VoiceFinal extends VoiceEvent {
  const VoiceFinal(this.text);
  final String text;
}

/// `SpeechRecognizer.ERROR_*` codes; 100+ are the recorder's own.
final class VoiceError extends VoiceEvent {
  const VoiceError(this.code);
  final int code;

  static const network = {1, 2, 4, 11};
  static const noSpeech = {6, 7};
  static const audio = 3;
  static const busy = 8;
  static const permission = 9;
  static const language = {12, 13};

  /// Explicit cancellation retires the session before the platform can emit ERROR_CLIENT.
  static bool canFallback(int code) => !{6, 7, 9}.contains(code);

  /// The recorder could not open the microphone.
  static const recorderFailed = 100;
}

/// The recorder reached its length limit and stopped on its own.
final class VoiceLimit extends VoiceEvent {
  const VoiceLimit();
}

/// The session is over (after a final result or an error).
final class VoiceEnd extends VoiceEvent {
  const VoiceEnd();
}

abstract class VoiceBridge {
  Future<VoiceCapabilities> capabilities();
  Future<VoicePermission> requestPermission();
  Future<void> openSettings();

  /// Live events of the current session.
  Stream<VoiceEvent> get events;

  /// System recognizer with partial results, in the recognizer's own
  /// language unless [language] (a BCP-47 tag) is given.
  Future<void> startRecognizer({String? language});

  /// Records for the engine's recognizer, at most [maxSeconds].
  Future<void> startRecorder({required int maxSeconds});

  /// 「内置模型」是否可用：SenseVoice 在 App 进程里就绪。
  ///
  /// 不依赖引擎、不依赖系统识别服务，所以本机/远程、在线/离线都一样。
  Future<VoiceOfflineStatus> offlineStatus();

  /// Loads the bundled model (first call copies ~228 MB out of assets).
  Future<void> prepareOffline();

  /// Records for the bundled model, at most [maxSeconds].
  Future<void> startOffline({required int maxSeconds});

  /// Ends an [startOffline] session and returns the transcript.
  ///
  /// Separate from [stop] on purpose: that one returns a WAV for the engine's
  /// recognizer, while the bundled model transcribes in this process and hands
  /// back text.
  Future<String> stopOffline();

  /// Ends listening: the recognizer delivers its final text as an event;
  /// the recorder returns its WAV (16 kHz mono PCM16), or null when there
  /// was nothing.
  Future<Uint8List?> stop();

  /// Ends listening and drops everything.
  Future<void> cancel();
}

class MethodChannelVoiceBridge implements VoiceBridge {
  static const _methods = MethodChannel('dsh/voice');

  Stream<VoiceEvent>? _stream;
  static int _nextSession = 0;
  int _session = 0;

  @override
  Future<VoiceCapabilities> capabilities() async {
    try {
      final map = await _methods.invokeMapMethod<String, Object?>('capabilities');
      return VoiceCapabilities(
        recognizer: map?['recognizer'] == true,
        recorder: map?['recorder'] == true,
        systemUnreliable: map?['systemUnreliable'] == true,
        environmentId: map?['environmentId'] as String?,
      );
    } on MissingPluginException {
      return VoiceCapabilities.none;
    } on PlatformException {
      return VoiceCapabilities.none;
    }
  }

  @override
  Future<VoicePermission> requestPermission() async {
    final result = await _methods.invokeMethod<String>('requestPermission');
    return switch (result) {
      'granted' => VoicePermission.granted,
      'blocked' => VoicePermission.blocked,
      _ => VoicePermission.denied,
    };
  }

  @override
  Future<void> openSettings() async {
    try {
      await _methods.invokeMethod<void>('openSettings');
    } on PlatformException {
      // Nothing to open on this ROM.
    }
  }

  @override
  Stream<VoiceEvent> get events => _stream ??= voicePlatformEvents
      .map(_decode)
      .where((e) => e != null)
      .cast<VoiceEvent>();

  VoiceEvent? _decode(Object? raw) {
    if (raw is! Map || raw['sessionId'] != _session) return null;
    return switch (raw['type']) {
      'level' => VoiceLevel(((raw['value'] as num?) ?? 0).toDouble()),
      'partial' => VoicePartial(raw['text'] as String? ?? ''),
      'final' => VoiceFinal(raw['text'] as String? ?? ''),
      'error' => VoiceError((raw['code'] as num?)?.toInt() ?? 0),
      'limit' => const VoiceLimit(),
      'end' => const VoiceEnd(),
      _ => null,
    };
  }

  @override
  Future<void> startRecognizer({String? language}) {
    _session = ++_nextSession;
    return _methods.invokeMethod<void>('startRecognizer', {'language': ?language, 'sessionId': _session});
  }

  @override
  Future<void> startRecorder({required int maxSeconds}) {
    _session = ++_nextSession;
    return _methods.invokeMethod<void>('startRecorder', {'maxSeconds': maxSeconds, 'sessionId': _session});
  }

  @override
  Future<Uint8List?> stop() => _methods.invokeMethod<Uint8List>('stop');

  @override
  Future<VoiceOfflineStatus> offlineStatus() async {
    try {
      final map = await _methods.invokeMethod<Map<Object?, Object?>>('offlineStatus');
      return VoiceOfflineStatus.fromMap(map);
    } on MissingPluginException {
      return VoiceOfflineStatus.unavailable;
    } on PlatformException {
      return VoiceOfflineStatus.unavailable;
    }
  }

  @override
  Future<void> prepareOffline() =>
      _methods.invokeMethod<void>('prepareOffline');

  @override
  Future<void> startOffline({required int maxSeconds}) =>
      _methods.invokeMethod<void>('startOffline', {'maxSeconds': maxSeconds, 'sessionId': _session});

  @override
  Future<String> stopOffline() async {
    final map = await _methods.invokeMethod<Map<Object?, Object?>>('stop');
    return (map?['text'] as String?)?.trim() ?? '';
  }

  @override
  Future<void> cancel() async {
    _session = ++_nextSession;
    try {
      await _methods.invokeMethod<void>('cancel');
    } on PlatformException {
      // Already stopped.
    }
  }
}
