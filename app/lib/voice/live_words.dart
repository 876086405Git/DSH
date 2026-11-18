// Words as they are spoken: a recorder's PCM (a tap on the native capture, no
// second recorder) through the phone's streaming recognizer, while its model is
// downloaded. A call shows them as captions; dictation as provisional text.

import 'dart:async';
import 'dart:typed_data';

import 'native_trial.dart';
import 'streaming_asr.dart';
import 'streaming_pcm.dart';

class LiveWords {
  LiveWords(this._pcm, this._asr, this._model, this._source, this._onWords, {NativeTrial? trial, void Function(Object error)? onFailure})
    : _trial = trial, _onFailure = onFailure; // ignore: prefer_initializing_formals

  final StreamingPcmCapture _pcm;
  final StreamingAsr _asr;
  final StreamingAsrModel _model;
  final StreamingPcmSource _source;
  final void Function(String words) _onWords;
  final void Function(Object error)? _onFailure;
  Object? _failure;
  Object? get failure => _failure;
  StreamSubscription<StreamingPcmReset>? _resets;
  int _reset = 0;
  bool _paused = false;
  bool _systemStartRequested = false;
  Future<void>? _releasing;
  static final _systemAsrOwner = Expando<LiveWords>();
  static final _systemPcmOwner = Expando<LiveWords>();
  bool get _ownsSystem => identical(_systemAsrOwner[_asr], this) && identical(_systemPcmOwner[_pcm], this);

  /// The first run on this phone, watched in case it takes the app down.
  final NativeTrial? _trial;
  bool _proving = false;
  StreamSubscription<StreamingAsrEvent>? _events;
  StreamSubscription<Object>? _frames;
  bool _stopped = false;

  /// Throws when the recognizer or the capture will not start (or, with
  /// [LiveWordsBlocked], once crashed the app here); nothing is left running
  /// then. A [stop] while it starts has the last word.
  Future<void> start() async {
    if (_model.isSystem) {
      if (_systemStartRequested || _stopped) throw StateError('LiveWords can only start once');
      _systemStartRequested = true;
    }
    if (_trial case final trial?) {
      if (trial.blocked()) throw const LiveWordsBlocked();
      _proving = !trial.proven;
      if (_proving) trial.begin();
    }
    try {
      if (_model.isSystem) {
        _systemAsrOwner[_asr] = this;
        _systemPcmOwner[_pcm] = this;
      }
      _events = _asr.events.listen((event) {
        if (!_model.isSystem || (!_stopped && !_paused && _ownsSystem)) _onWords(event.text);
      }, onError: _model.isSystem ? _failed : null);
      await _asr.start(_model);
      if (_stopped) return await _release();
      if (_model.isSystem && !_ownsSystem) throw StateError('LiveWords was replaced');
      // A frame that lands while it stops is simply not heard.
      _frames = _pcm.frames.listen((frame) => unawaited(_feed(frame)),
        onError: _model.isSystem ? _failed : null);
      if (_model.isSystem) _resets = _pcm.resets.listen(_resetCaption);
      await _pcm.start(_source);
      if (_stopped) return await _release();
      if (_model.isSystem && !_ownsSystem) throw StateError('LiveWords was replaced');
    } catch (_) {
      await _release();
      rethrow;
    }
  }

  Future<void> _feed(Uint8List frame) async {
    if (_model.isSystem && (_paused || _stopped || !_ownsSystem)) return;
    final reset = _reset;
    try {
      await _asr.feed(frame);
    } on Object catch (error) {
      if (_model.isSystem && reset == _reset) _failed(error);
      return;
    }
    if (_model.isSystem && (_paused || _stopped || reset != _reset || !_ownsSystem)) return;
    if (_proving) {
      _proving = false;
      _trial?.passed();
    }
  }

  void _failed(Object error) {
    if (_stopped || _failure != null || !_ownsSystem) return;
    _failure = error;
    _paused = true;
    _onWords('');
    _onFailure?.call(error);
    unawaited(stop().catchError((Object _) {}));
  }

  void _resetCaption(StreamingPcmReset reason) {
    if (_stopped || !_ownsSystem) return;
    final reset = ++_reset;
    _paused = true;
    _onWords('');
    if (reason == StreamingPcmReset.stopped) {
      unawaited(stop().catchError(_failed));
    } else if (reason == StreamingPcmReset.muted) {
      unawaited(_asr.stop(finalize: false).catchError(_failed));
    } else {
      unawaited(_resume(reset));
    }
  }

  Future<void> _resume(int reset) async {
    try {
      if (_stopped || reset != _reset || !_ownsSystem) return;
      await _asr.stop(finalize: false);
      if (_stopped || reset != _reset || !_ownsSystem) return;
      await _asr.start(_model);
      if (!_stopped && reset == _reset && _ownsSystem) _paused = false;
    } catch (error) {
      if (!_stopped && reset == _reset) _failed(error);
    }
  }

  Future<void> stop() {
    _stopped = true;
    return _release();
  }

  Future<void> _release() async {
    if (_model.isSystem) {
      final releasing = _releasing ??= _releaseSystem();
      try { await releasing; }
      catch (_) {
        if (identical(_releasing, releasing)) _releasing = null;
        rethrow;
      }
      return;
    }
    if (_proving) {
      _proving = false;
      _trial?.dropped();
    }
    final frames = _frames;
    final events = _events;
    _frames = null;
    _events = null;
    await _pcm.stop();
    await frames?.cancel();
    await _asr.stop(finalize: false);
    await events?.cancel();
  }

  Future<void> _releaseSystem() async {
    if (_proving) { _proving = false; _trial?.dropped(); }
    final frames = _frames;
    final events = _events;
    final resets = _resets;
    _frames = null; _events = null; _resets = null;
    try {
      if (identical(_systemPcmOwner[_pcm], this)) {
        await _pcm.stop();
        if (identical(_systemPcmOwner[_pcm], this)) _systemPcmOwner[_pcm] = null;
      }
    } finally {
      await frames?.cancel();
      await resets?.cancel();
      try {
        if (identical(_systemAsrOwner[_asr], this)) {
          await _asr.stop(finalize: false);
          if (identical(_systemAsrOwner[_asr], this)) _systemAsrOwner[_asr] = null;
        }
      }
      finally { await events?.cancel(); }
    }
  }

}
