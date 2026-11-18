import 'dart:async';

import 'package:flutter/services.dart';

import 'streaming_asr.dart';

/// Core Speech consumes the existing microphone tap. It does not load sherpa
/// model paths or open a second recorder. SDK/phone behavior remains unverified.
class OhosStreamingAsr extends StreamingAsr {
  OhosStreamingAsr({MethodChannel? channel}) : _channel = channel ?? const MethodChannel('dsh/streaming_asr'), _readinessProbe = false;
  OhosStreamingAsr.forReadiness() : _channel = const MethodChannel('dsh/streaming_asr'), _readinessProbe = true;

  final MethodChannel _channel;
  final bool _readinessProbe;
  final _notices = StreamController<StreamingAsrEvent>.broadcast();
  static OhosStreamingAsr? _owner;
  static int _nextRun = 0;
  int _run = 0;
  int _physicalRun = 0;
  int _feeding = 0;
  int _stopping = 0;
  bool _active = false;
  bool _disposed = false;

  @override
  Stream<StreamingAsrEvent> get events => _notices.stream;
  @override
  bool get active => _active && _owner == this && _run != 0;

  static bool get hasActiveSession => _owner?.active == true && _owner?._readinessProbe == false;
  static bool get isTransitioning {
    final owner = _owner;
    return owner != null && (owner._readinessProbe || owner._stopping != 0 || (owner._run != 0 && !owner.active));
  }

  @override
  Future<void> start(StreamingAsrModel model) async {
    if (_disposed) throw StateError('StreamingAsr is disposed');
    if (!model.isSystem) throw UnsupportedError('HarmonyOS captions require StreamingAsrModel.system()');
    final previous = _owner;
    if (previous != null && previous != this) {
      previous._run = 0;
      previous._active = false;
    }
    _owner = this;
    final run = _run = _physicalRun = ++_nextRun;
    _active = false;
    _channel.setMethodCallHandler(_event);
    try {
      await _channel.invokeMethod<void>('start', {'run': run});
      if (!_disposed && _owner == this && _run == run) _active = true;
    } catch (_) {
      if (_run == run) {
        _run = 0;
        _active = false;
      }
      rethrow;
    }
  }

  Future<void> _event(MethodCall call) async {
    final raw = call.arguments;
    if (_disposed || _owner != this || call.method != 'event' || raw is! Map || raw['run'] != _run || _run == 0) {
      return;
    }
    switch (raw['type']) {
      case 'partial' when raw['text'] is String:
        _notices.add(StreamingAsrPartial(raw['text'] as String));
      case 'final' when raw['text'] is String:
        _notices.add(StreamingAsrFinal(raw['text'] as String));
      case 'error':
        _failed(PlatformException(code: 'streaming_asr', message: raw['reason'] as String? ?? 'recognizer'));
    }
  }

  void _failed(Object error) {
    if (_run == 0 || _disposed) return;
    _run = 0;
    _active = false;
    _notices.addError(error);
    unawaited(stop(finalize: false).catchError((Object _) {}));
  }

  @override
  Future<void> feed(Uint8List pcm16le) async {
    if (_disposed) throw StateError('StreamingAsr is disposed');
    if (!active) throw StateError('StreamingAsr is not started');
    if (pcm16le.length != 640) throw const FormatException('Core Speech requires 640-byte PCM16 frames');
    if (_feeding >= StreamingAsr.maxQueued) {
      final error = StateError('StreamingAsr input queue is full');
      _failed(error);
      throw error;
    }
    final run = _run;
    _feeding++;
    try {
      await _channel.invokeMethod<void>('feed', {'run': run, 'bytes': Uint8List.fromList(pcm16le)});
    } catch (error) {
      if (_run == run) _failed(error);
      rethrow;
    } finally {
      _feeding--;
    }
  }

  @override
  Future<void> stop({bool finalize = true}) async {
    final run = _physicalRun;
    if (run == 0) return;
    if (!finalize) {
      if (_run == run) _run = 0;
      _active = false;
    }
    _stopping++;
    try {
      await _channel.invokeMethod<void>('stop', {'run': run, 'finalize': finalize});
      if (_physicalRun == run) _physicalRun = 0;
    } finally {
      _stopping--;
      if (_run == run) {
        _run = 0;
        _active = false;
      }
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await stop(finalize: false);
    } finally {
      if (_owner == this) {
        _owner = null;
        _channel.setMethodCallHandler(null);
      }
      await _notices.close();
      await super.dispose();
    }
  }
}
