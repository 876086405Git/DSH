part of 'speech_out.dart';

// One physical dsh/speech stream per engine isolate. The lane survives an
// individual output so its pending global stop also precedes the next open.
final _ohosSpeechLane = _OhosSpeechLane();

class _OhosSpeechLane {
  _OhosDeepSeekOut? owner;
  Future<void> _retiring = Future.value();

  Future<void> claim(_OhosDeepSeekOut next) {
    owner?._finish(const SpeechOutDone(), stopNative: true);
    owner = next;
    return _retiring;
  }

  Future<void> release(_OhosDeepSeekOut previous, {required bool stopNative}) {
    if (!identical(owner, previous)) return Future.value();
    owner = null;
    if (!stopNative || !previous._openAttempted) return _retiring;
    // Issue stop while this owner is still the last submitted native open.
    // Await late open completion too: a new owner cannot pass an old stop.
    final stopped = previous._audio.stopChecked();
    final result = Future.wait<void>([_retiring, stopped, previous._physicalOpenDone.future]);
    // Failure remains observable to the old output. A later open may retry the
    // native retained owner; the native lease decides whether creation is safe.
    _retiring = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result.then<void>((_) {});
  }
}

/// OH uses one active synthesis response and one serial writer. The queued
/// PCM at a write boundary is at most 144000 + 65536 bytes. A response can be
/// arbitrarily long; capacity, cancellation and EOF control its consumption.
class _OhosDeepSeekOut implements SpeechOut {
  _OhosDeepSeekOut(
    this._resolve,
    this._audio, {
    this.voice = 'stella',
    this.call = false,
    this.levels = false,
    DeepSeekSpeechFailure Function()? gap,
  }) : _gap = gap ?? DeepSeekOut._noCredential {
    _sub = _audio.events.listen(_heard, onDone: () {
      if (!_ended) _finish(const SpeechOutFailed('audio channel closed'), stopNative: true);
    });
  }

  final DeepSeekSpeechResolver _resolve;
  final SpeechAudio _audio;
  final String voice;
  final bool call, levels;
  final DeepSeekSpeechFailure Function() _gap;
  final String id = 'ds${++_streams}';
  final _chunker = SpeechChunker();
  final _pieces = Queue<String>();
  final _events = StreamController<SpeechOutEvent>.broadcast();
  final _physicalOpenDone = Completer<void>();
  final _spans = <_Span>[];
  late final StreamSubscription<SpeechAudioEvent> _sub;
  Future<DeepSeekSpeech?>? _speech;
  StreamIterator<Uint8List>? _reader;
  Timer? _capacityTimer;
  Completer<void>? _capacityWake;
  bool _busy = false, _finished = false, _ended = false;
  bool _openAttempted = false, _opened = false, _endSent = false;
  bool _completed = false;
  int _written = 0, _played = 0;
  static const _queueLimit = 144000;
  static const _writeLimit = 65536;

  bool get _current => !_ended && identical(_ohosSpeechLane.owner, this);
  @override
  bool get ended => _ended;
  @override
  Stream<SpeechOutEvent> get events => _events.stream;
  @override
  bool get canDuck => true;

  @override
  void add(String text) {
    if (_finished || _ended) return;
    _chunker.add(text);
    _pieces.addAll(_chunker.take());
    _schedule();
  }

  @override
  void finish() {
    if (_finished || _ended) return;
    _finished = true;
    _pieces.addAll(_chunker.take(final_: true));
    _schedule();
  }

  void _schedule() {
    if (_busy || _ended) return;
    if (_pieces.isEmpty) {
      if (_finished && !_openAttempted) _finish(const SpeechOutDone(), stopNative: false);
      if (!_finished || !_opened || _endSent || _ended) return;
    }
    _busy = true;
    unawaited(_drain());
  }

  Future<bool> _open() async {
    if (_opened) return _current;
    await _ohosSpeechLane.claim(this);
    if (!_current) return false;
    _openAttempted = true;
    unawaited(const DiagnosticsChannel().recordVoiceStage('playback_opening', backend: 'deepseek'));
    bool available;
    try {
      available = await _audio.open(id, call: call, levels: levels);
    } finally {
      if (!_physicalOpenDone.isCompleted) _physicalOpenDone.complete();
    }
    if (!_current) return false;
    if (!available) throw const DeepSeekSpeechError(DeepSeekSpeechFailure.protocol, 'no audio output');
    _opened = true;
    return true;
  }

  Future<bool> _capacity() async {
    while (_current) {
      final queued = await _audio.waiting(id);
      if (!_current) return false;
      if (queued < 0) throw const DeepSeekSpeechError(DeepSeekSpeechFailure.protocol, 'audio output ended');
      if (queued <= _queueLimit) return true;
      final wake = _capacityWake = Completer<void>();
      _capacityTimer = Timer(const Duration(milliseconds: 150), () {
        if (!wake.isCompleted) wake.complete();
      });
      await wake.future;
      _capacityTimer?.cancel();
      _capacityTimer = null;
      if (identical(_capacityWake, wake)) _capacityWake = null;
    }
    return false;
  }

  Future<void> _drain() async {
    try {
      if (!await _open()) return;
      final speech = await (_speech ??= _resolve());
      if (!_current) return;
      if (speech == null) throw DeepSeekSpeechError(_gap());
      while (_pieces.isNotEmpty && _current) {
        final text = _pieces.removeFirst();
        final span = _Span(text, _written);
        _spans.add(span);
        if (!await _capacity()) return;
        if (!_current) return;
        // Only this checked, already-open owner may begin a billable request.
        unawaited(const DiagnosticsChannel().recordVoiceStage('synthesis_requested', backend: 'deepseek'));
        final reader = _reader = StreamIterator<Uint8List>(speech.synthesize(text, voice: voice));
        try {
          while (_current && await reader.moveNext()) {
            if (!_current) return;
            final chunk = reader.current;
            for (var offset = 0; offset < chunk.length; offset += _writeLimit) {
              if (!await _capacity()) return;
              final end = min(offset + _writeLimit, chunk.length);
              final part = Uint8List.sublistView(chunk, offset, end);
              if (!_current) return;
              final queued = await _audio.write(id, part);
              if (!_current) return;
              // The native result is total queued bytes, never an accepted
              // prefix length. Every nonnegative result accepts the whole part.
              if (queued < 0) throw const DeepSeekSpeechError(DeepSeekSpeechFailure.protocol, 'audio output ended');
              _written += part.length;
              span.end = _written;
            }
          }
          if (_current) {
            final bytes = _written - span.start;
            if (bytes == 0 || bytes.isOdd) {
              throw const DeepSeekSpeechError(DeepSeekSpeechFailure.protocol, 'incomplete PCM response');
            }
            span.closed = true;
          }
        } finally {
          await reader.cancel();
          if (identical(_reader, reader)) _reader = null;
        }
      }
      if (_finished && _pieces.isEmpty && _current && !_endSent) {
        _endSent = true;
        await _audio.endChecked(id);
      }
    } catch (error) {
      if (!_ended) _finish(SpeechOutFailed(error), stopNative: true);
    } finally {
      _busy = false;
      if (!_ended && _pieces.isNotEmpty) _schedule();
    }
  }

  @override
  void stop() => _finish(const SpeechOutDone(), stopNative: true);

  void _finish(SpeechOutEvent terminal, {required bool stopNative}) {
    if (_ended) return;
    _ended = true;
    _pieces.clear();
    _capacityTimer?.cancel();
    _capacityTimer = null;
    final wake = _capacityWake;
    if (wake != null && !wake.isCompleted) wake.complete();
    _capacityWake = null;
    // Close this speech owner before cancelling its reader. Closing a bridge
    // aborts only its exchange group; a direct owner owns its HTTP client.
    unawaited(_speech?.then<void>((speech) => speech?.close(), onError: (Object _, StackTrace _) {}));
    unawaited(_reader?.cancel().then<void>((_) {}, onError: (Object _, StackTrace _) {}));
    final retirement = _ohosSpeechLane.release(this, stopNative: stopNative);
    unawaited(retirement.then<void>((_) {
      _publish(terminal);
    }, onError: (Object _, StackTrace _) {
      _publish(const SpeechOutFailed(DeepSeekSpeechError(DeepSeekSpeechFailure.protocol, 'audio stop failed')));
    }));
  }

  void _publish(SpeechOutEvent terminal) {
    if (_events.isClosed) return;
    if (terminal is SpeechOutFailed) {
      unawaited(const DiagnosticsChannel().recordVoiceStage('failed', backend: 'deepseek'));
    }
    _events.add(terminal);
    unawaited(_events.close());
    unawaited(_sub.cancel());
  }

  void _heard(SpeechAudioEvent event) {
    if (!_current) return;
    switch (event) {
      case PlayEvent(id: final which, :final phase) when which == id:
        switch (phase) {
          case PlayPhase.start:
            unawaited(const DiagnosticsChannel().recordVoiceStage('playback_started', backend: 'deepseek'));
            if (!_events.isClosed) _events.add(const SpeechOutStarted());
          case PlayPhase.done:
            _completed = true;
            _played = _written;
            _finish(const SpeechOutDone(), stopNative: false);
          case PlayPhase.stopped:
            _finish(const SpeechOutDone(), stopNative: false);
          case PlayPhase.error:
            _finish(const SpeechOutFailed('playback'), stopNative: true);
        }
      case PlayLevel(id: final which, :final value) when which == id:
        _played += DeepSeekOut._tickBytes;
        if (!_events.isClosed) _events.add(SpeechOutLevel(value));
      default:
        break;
    }
  }

  @override
  void duck(bool on) {
    if (_opened && _current) unawaited(_audio.duck(id, on));
  }

  @override
  String get heard {
    final parts = <String>[];
    for (final span in _spans) {
      final count = span.heardBy(_played);
      if (count > 0) parts.add(span.text.substring(0, count));
      if (count < span.text.length) break;
    }
    return _joined(parts);
  }
}
