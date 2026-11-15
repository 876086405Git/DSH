import 'dart:async';

import 'package:flutter/services.dart';

import 'voice_platform_events.dart';

enum StreamingPcmSource { call, dictation }

/// OH lifecycle signal from the same native tap; Android PCM is unchanged.
enum StreamingPcmReset { muted, resumed, stopped }

/// Taps an existing recorder; the caller still owns microphone start/stop and permissions.
class StreamingPcmCapture {
  StreamingPcmCapture({MethodChannel? channel, Stream<dynamic>? platformEvents})
    : _channel = channel ?? const MethodChannel('dsh/voice'),
      _platformEvents = platformEvents ?? voicePlatformEvents;

  final MethodChannel _channel;
  final Stream<dynamic> _platformEvents;
  final _frames = StreamController<Uint8List>.broadcast();
  final _resets = StreamController<StreamingPcmReset>.broadcast();
  StreamSubscription<dynamic>? _subscription;
  Future<void> _operation = Future.value();
  static int _nextSession = 0;
  int _session = 0;
  bool _disposed = false;

  Stream<Uint8List> get frames => _frames.stream;
  Stream<StreamingPcmReset> get resets => _resets.stream;

  Future<void> start(StreamingPcmSource source) => _serialize(() async {
    if (_disposed) return;
    await _stop();
    final session = _session = ++_nextSession;
    _subscription = _platformEvents.listen((raw) {
      if (raw is! Map || raw['pcmSession'] != session || _session != session) return;
      if (raw['type'] == 'pcmReset' && raw['source'] == source.name) {
        final reason = switch (raw['reason']) {
          'muted' => StreamingPcmReset.muted,
          'resumed' => StreamingPcmReset.resumed,
          'stopped' => StreamingPcmReset.stopped,
          _ => null,
        };
        if (reason != null) _resets.add(reason);
        return;
      }
      if (raw['type'] != 'pcm') return;
      final bytes = raw['bytes'];
      if (raw['rate'] == 16000 && bytes is Uint8List && bytes.length == 640) _frames.add(bytes);
    }, onError: _frames.addError);
    try {
      await _channel.invokeMethod<void>('streamingPcm', {'source': source.name, 'pcmSession': session});
    } catch (_) {
      await _subscription?.cancel();
      _subscription = null;
      _session = 0;
      rethrow;
    }
  });

  Future<void> stop() => _serialize(_stop);

  Future<void> _stop() async {
    final session = _session;
    _session = 0;
    try {
      if (session != 0) await _channel.invokeMethod<void>('streamingPcm', {'pcmSession': session});
    } finally {
      await _subscription?.cancel();
      _subscription = null;
    }
  }

  Future<void> _serialize(Future<void> Function() action) {
    final next = _operation.then((_) => action());
    _operation = next.then((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<void> dispose() async {
    _disposed = true;
    try {
      await stop();
    } finally {
      await _frames.close();
      await _resets.close();
    }
  }
}
