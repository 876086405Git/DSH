part of 'speech_out.dart';

/// The existing settings preview uses CompanionSpeaker. OH routes that
/// entry into the same preflight, streaming and physical-owner lane as 朗读.
/// Other encoded voice formats have no matching OH player in this build and
/// fail before any external synthesis request.
class OhosSpeechSpeaker implements CompanionSpeaker {
  OhosSpeechSpeaker(this._resolve, this._audio);

  final DeepSeekSpeechResolver _resolve;
  final SpeechAudio _audio;
  final _events = StreamController<CompanionVoiceEvent>.broadcast();
  CompanionVoiceSettings _settings = const CompanionVoiceSettings();
  _OhosDeepSeekOut? _preview;
  StreamSubscription<SpeechOutEvent>? _sub;
  Completer<String?>? _result;
  bool _disposed = false;
  int _previews = 0;

  @override
  String? lastError;
  @override
  Stream<CompanionVoiceEvent> get events => _events.stream;
  @override
  set settings(CompanionVoiceSettings next) {
    if (next.source != _settings.source) stop();
    _settings = next;
  }
  @override
  Future<bool> ready(CompanionVoiceSettings next) async {
    settings = next;
    return !_disposed && next.usesDeepSeekSpeech;
  }
  @override
  Future<bool> warmPhone() async => false;

  // This provider is used for non-DeepSeek SpeakerOut and for settings
  // previews. DeepSeek read-aloud itself selects _OhosDeepSeekOut directly.
  @override
  void speak(String id, String text, {bool flush = false}) {
    if (flush) stop();
    lastError = 'unsupported voice format';
    if (!_events.isClosed) _events.add(CompanionVoiceEvent(CompanionVoiceEventType.error, id));
  }

  @override
  Future<String?> preview(CompanionVoiceSettings next, String text) {
    stop();
    settings = next;
    if (_disposed) return Future.value('audio output closed');
    if (!next.usesDeepSeekSpeech) {
      return Future.value(next.source == CompanionVoiceSource.system ? 'no-phone-voice' : 'unsupported voice format');
    }
    if (text.trim().isEmpty) return Future.value('deepseek rejected');
    final result = _result = Completer<String?>();
    final id = 'preview-${++_previews}';
    final out = _preview = _OhosDeepSeekOut(_resolve, _audio, voice: next.deepseekVoice);
    lastError = null;
    _sub = out.events.listen((event) {
      if (!identical(_preview, out)) return;
      switch (event) {
        case SpeechOutStarted():
          if (!_events.isClosed) _events.add(CompanionVoiceEvent(CompanionVoiceEventType.start, id));
        case SpeechOutFailed(:final error):
          final reason = error is DeepSeekSpeechError ? 'deepseek ${error.failure.name}' : 'audio output failed';
          lastError = reason;
          _complete(out, reason, CompanionVoiceEvent(CompanionVoiceEventType.error, id));
        case SpeechOutDone():
          // A stopped/evicted preview is not a successful voice sample. Wait
          // for natural playback completion so a late stream failure remains
          // visible through the existing preview Future<String?> contract.
          _complete(out, out._completed ? null : 'cancelled',
            CompanionVoiceEvent(out._completed ? CompanionVoiceEventType.done : CompanionVoiceEventType.stopped, id));
        case SpeechOutLevel():
          break;
      }
    });
    out..add(text)..finish();
    return result.future;
  }

  void _complete(_OhosDeepSeekOut out, String? reason, CompanionVoiceEvent event) {
    if (!identical(_preview, out)) return;
    _preview = null;
    final result = _result;
    _result = null;
    if (result != null && !result.isCompleted) result.complete(reason);
    if (!_events.isClosed) _events.add(event);
    unawaited(_sub?.cancel());
    _sub = null;
  }

  @override
  void stop() {
    final out = _preview;
    _preview = null;
    final result = _result;
    _result = null;
    if (result != null && !result.isCompleted) result.complete('cancelled');
    unawaited(_sub?.cancel());
    _sub = null;
    out?.stop();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    stop();
    unawaited(_events.close());
  }
}

class _OhosUnavailableOut implements SpeechOut {
  final _events = StreamController<SpeechOutEvent>.broadcast();
  bool _ended = false;
  @override
  bool get ended => _ended;
  @override
  bool get canDuck => false;
  @override
  String get heard => '';
  @override
  Stream<SpeechOutEvent> get events => _events.stream;
  @override
  void add(String text) => finish();
  @override
  void finish() => _close(const SpeechOutFailed(DeepSeekSpeechError(DeepSeekSpeechFailure.protocol, 'unsupported voice format')));
  @override
  void stop() => _close(const SpeechOutDone());
  @override
  void duck(bool on) {}
  void _close(SpeechOutEvent event) {
    if (_ended) return;
    _ended = true;
    _events.add(event);
    unawaited(_events.close());
  }
}
