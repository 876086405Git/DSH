// Speaking text as it comes: a whole reply for 朗读, or a reply still being
// written during a 语音通话. Text is cut into short pieces at sentence ends;
// each piece is asked for while the one before plays, so the first words are
// heard after one short request.
//
// DeepSeek's voice streams PCM into one native stream (speech_audio.dart), so
// pieces join without gaps. Any other voice goes sentence by sentence through
// the same speaker as her voice in 伙伴小屋 (companion_voice.dart).

import 'dart:async';
import 'dart:collection';
import 'dart:io' show Platform;
import 'dart:math';
import 'dart:typed_data';

import '../diagnostics/diagnostics_channel.dart';
import '../companion/companion_voice.dart';
import '../companion/companion_voice_source.dart';
import 'deepseek_speech.dart';
import 'speech_audio.dart';
import 'speech_compat.dart';

part 'ohos_speech_out.dart';
part 'ohos_speech_preview.dart';

sealed class SpeechOutEvent {
  const SpeechOutEvent();
}

/// The first sound is playing.
final class SpeechOutStarted extends SpeechOutEvent {
  const SpeechOutStarted();
}

/// How loud the voice is now (0–1).
final class SpeechOutLevel extends SpeechOutEvent {
  const SpeechOutLevel(this.value);
  final double value;
}

/// Everything given was spoken (or [stop] ended it).
final class SpeechOutDone extends SpeechOutEvent {
  const SpeechOutDone();
}

final class SpeechOutFailed extends SpeechOutEvent {
  const SpeechOutFailed(this.error);
  final Object error;
}

abstract class SpeechOut {
  /// More text to say (deltas, appended in order).
  void add(String text);

  /// Nothing more is coming: what is left is said, then [SpeechOutDone].
  void finish();

  /// Silence now; [SpeechOutDone] follows.
  void stop();

  Stream<SpeechOutEvent> get events;

  /// Ended: done, stopped or failed.
  bool get ended;

  /// What has been heard of the text so far (the person may cut in midway).
  String get heard;

  /// Quieter while the person may be speaking over it ([on]), or back to full.
  void duck(bool on);

  /// [duck] turns it down (else it cannot, and stops instead).
  bool get canDuck;
}

/// [pieces] joined as they were said: a space only between two Latin ends.
String _joined(Iterable<String> pieces) {
  final out = StringBuffer();
  String? last;
  for (final piece in pieces) {
    if (piece.isEmpty) continue;
    if (last != null && _latin.hasMatch(last[last.length - 1]) && _latin.hasMatch(piece[0])) {
      out.write(' ');
    }
    out.write(piece);
    last = piece;
  }
  return out.toString();
}

final _latin = RegExp(r'[A-Za-z0-9.,!?;:]');

// ── Text ───────────────────────────────────────────────────────────────────

final _fence = RegExp(r'```[\s\S]*?(```|$)');
final _displayMath = RegExp(r'\$\$[\s\S]*?(\$\$|$)');
final _image = RegExp(r'!\[[^\]]*\]\([^)]*\)');
final _link = RegExp(r'\[([^\]]+)\]\([^)]*\)');
final _bareUrl = RegExp(r'https?://\S+');
final _html = RegExp(r'<[^>\n]{1,80}>');
final _inlineCode = RegExp(r'`([^`\n]*)`');
final _emphasis = RegExp(r'(\*\*|__|\*|_|~~)(?=\S)(.+?)(?<=\S)\1');
final _lineMarks = RegExp(r'^\s{0,3}(#{1,6}\s+|>\s?|[-*+]\s+|\d{1,3}[.)]\s+)', multiLine: true);
final _tableRow = RegExp(r'^\s*\|.*\|\s*$', multiLine: true);
final _rule = RegExp(r'^\s*([-*_]\s*){3,}$', multiLine: true);

/// [markdown] as it should sound: no code blocks, tables, images, links'
/// addresses or formatting marks. (DeepSeek also filters on its side; other
/// voices would read the marks out.)
String speakable(String markdown) {
  var s = markdown
      .replaceAll(_fence, '\n')
      .replaceAll(_displayMath, ' ')
      .replaceAll(_image, '')
      .replaceAllMapped(_link, (m) => m[1]!)
      .replaceAll(_bareUrl, '')
      .replaceAll(_html, '')
      .replaceAll(_tableRow, '')
      .replaceAll(_rule, '')
      .replaceAllMapped(_inlineCode, (m) => m[1]!)
      .replaceAll(_lineMarks, '');
  s = s.replaceAllMapped(_emphasis, (m) => m[2]!);
  return s.replaceAll(RegExp(r'\n{2,}'), '\n').trim();
}

final _sentenceEnd = RegExp(r'[。！？!?…~～；;\n]+|[.](?=\s)');
final _pause = RegExp(r'[，,、：:）)」』]');

/// Where the first piece may end before its sentence does: a comma or a colon
/// (an ASCII one only before a space, so 1,000 and 3:30 stay whole).
final _firstPause = RegExp(r'[，、：；]|[,:](?=\s)');

/// Cuts text arriving in pieces into what can be spoken: whole sentences,
/// the first one short (to start soon: it may end at a comma once it has
/// [first] characters), later ones grouped up to [target].
class SpeechChunker {
  SpeechChunker({this.first = 8, this.target = 120, this.max = 300});

  final int first;
  final int target;
  final int max;
  final _buffer = StringBuffer();
  int _given = 0;

  void add(String text) => _buffer.write(text);

  /// The pieces ready now; with [final_], everything left.
  List<String> take({bool final_ = false}) {
    final out = <String>[];
    var rest = _buffer.toString();
    while (rest.isNotEmpty) {
      final want = _given == 0 ? first : target;
      // The first sentence end once there is enough to say.
      int? cut = _sentenceEnd.allMatches(rest).where((m) => m.end >= want).firstOrNull?.end;
      // The very first piece goes at a comma already: her voice starts sooner.
      if (_given == 0) {
        final pause = _firstPause.allMatches(rest).where((m) => m.end >= want).firstOrNull?.end;
        if (pause != null && (cut == null || pause < cut)) cut = pause;
      }
      if (cut != null && cut > max) cut = null;
      if (cut == null && rest.length >= max) {
        // Too long without an end: the last sentence end or pause before max, else max.
        final head = rest.substring(0, max);
        cut = _sentenceEnd.allMatches(head).lastOrNull?.end ?? _pause.allMatches(head).lastOrNull?.end ?? max;
      }
      if (cut == null) {
        if (!final_) break;
        cut = rest.length;
      }
      final piece = rest.substring(0, cut).trim();
      rest = rest.substring(cut);
      if (piece.isNotEmpty && RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(piece)) {
        out.add(piece);
        _given++;
      }
    }
    _buffer
      ..clear()
      ..write(rest);
    return out;
  }
}

// ── DeepSeek, streamed ─────────────────────────────────────────────────────

/// Where one piece's audio lies in the stream (bytes), so what was heard can be told.
class _Span {
  _Span(this.text, this.start) : end = start;
  final String text;
  final int start;
  int end;

  /// All its audio is written: [end] is final.
  bool closed = false;

  /// Characters heard once [played] bytes have played. Until its audio is all
  /// there it is measured against a slow reading of the text, so playback that
  /// has caught up with the synthesis does not count it all heard.
  int heardBy(int played) {
    final last = closed ? end : max(end, start + _slowBytes(text));
    if (played <= start || last <= start) return 0;
    if (closed && played >= last) return text.length;
    return min(text.length, text.length * (played - start) ~/ (last - start));
  }

  /// About 0.3 s a CJK character and 0.09 s any other, at the voice's rate.
  static int _slowBytes(String text) {
    var seconds = 0.0;
    for (final rune in text.runes) {
      seconds += rune >= 0x2E80 ? 0.3 : 0.09;
    }
    return (seconds * deepSeekTtsRate * 2).round();
  }
}

class _Piece {
  _Piece(this.text);
  final String text;
  final chunks = <Uint8List>[];
  bool done = false;
  Object? error;
  bool claimed = false;
  StreamSubscription<Uint8List>? fetch;
  Completer<void> _more = Completer<void>();

  Future<void> get more => _more.future;

  void _signal() {
    if (!_more.isCompleted) _more.complete();
    _more = Completer<void>();
  }
}

int _streams = 0;

/// DeepSeek's voice, streamed into one native PCM stream. [call] plays it as
/// the voice of a call; [levels] reports its loudness.
class DeepSeekOut implements SpeechOut {
  DeepSeekOut(
    this._resolve,
    this._audio, {
    this.voice = 'stella',
    this.call = false,
    this.levels = false,
    DeepSeekSpeechFailure Function()? gap,
  }) : _gap = gap ?? _noCredential {
    _sub = _audio.events.listen(_heard);
  }

  /// What to say when nobody can pay ([deepSeekSpeechGapProvider]).
  final DeepSeekSpeechFailure Function() _gap;

  static DeepSeekSpeechFailure _noCredential() => DeepSeekSpeechFailure.noCredential;

  final DeepSeekSpeechResolver _resolve;
  final SpeechAudio _audio;
  final String voice;
  final bool call;
  final bool levels;

  final id = 'ds${++_streams}';
  final _chunker = SpeechChunker();
  final _pieces = Queue<_Piece>();
  final _events = StreamController<SpeechOutEvent>.broadcast();
  late final StreamSubscription<SpeechAudioEvent> _sub;
  Future<DeepSeekSpeech?>? _speech;
  bool _finished = false;
  bool _stopped = false;
  bool _ended = false;
  bool _opened = false;
  bool _writing = false;
  bool _endSent = false;
  final _spans = <_Span>[];
  int _written = 0;
  int _played = 0;

  /// Each level tick is 40 ms heard (the native PcmStream posts it when that audio plays).
  static const _tickBytes = deepSeekTtsRate * 2 * 40 ~/ 1000;

  @override
  Stream<SpeechOutEvent> get events => _events.stream;

  @override
  bool get ended => _ended;

  /// How many pieces are asked for ahead of the one playing.
  static const _ahead = 2;

  /// At most this much audio waits on the phone to be played (3 s): beyond
  /// it, writing waits for playback to catch up.
  static const _waitingBytes = deepSeekTtsRate * 2 * 3;

  @override
  void add(String text) {
    if (_finished || _stopped) return;
    _chunker.add(text);
    _queue(_chunker.take());
  }

  @override
  void finish() {
    if (_finished || _stopped) return;
    _finished = true;
    _queue(_chunker.take(final_: true));
    if (_pieces.isEmpty && !_writing) _end();
  }

  void _queue(List<String> texts) {
    for (final text in texts) {
      _pieces.add(_Piece(text));
    }
    _prefetch();
    unawaited(_write());
  }

  void _prefetch() {
    var started = 0;
    for (final piece in _pieces) {
      if (started >= _ahead + 1) break;
      started++;
      if (piece.claimed || piece.done) continue;
      unawaited(_start(piece));
    }
  }

  Future<void> _start(_Piece piece) async {
    piece.claimed = true;
    final speech = await (_speech ??= _resolve());
    if (_stopped) return;
    if (speech == null) {
      piece
        ..error = DeepSeekSpeechError(_gap())
        ..done = true
        .._signal();
      return;
    }
    if (_pieces.isNotEmpty && identical(_pieces.first, piece) && _written == 0) {
      unawaited(const DiagnosticsChannel().recordVoiceStage('synthesis_requested', backend: 'deepseek'));
    }
    piece.fetch = speech
        .synthesize(piece.text, voice: voice)
        .listen(
          (chunk) {
            piece.chunks.add(chunk);
            piece._signal();
          },
          onError: (Object error) {
            piece
              ..error = error
              ..done = true
              .._signal();
          },
          onDone: () {
            piece
              ..done = true
              .._signal();
          },
          cancelOnError: true,
        );
  }

  Future<void> _write() async {
    if (_writing) return;
    _writing = true;
    try {
      while (_pieces.isNotEmpty && !_stopped) {
        final piece = _pieces.first;
        final span = _Span(piece.text, _written);
        _spans.add(span);
        while (!_stopped) {
          while (piece.chunks.isNotEmpty && !_stopped) {
            final chunk = piece.chunks.removeAt(0);
            _written += chunk.length;
            span.end = _written;
            if (!_opened) {
              _opened = true;
              unawaited(const DiagnosticsChannel().recordVoiceStage('playback_opening', backend: 'deepseek'));
              if (!await _audio.open(id, call: call, levels: levels)) {
                _fail(const DeepSeekSpeechError(DeepSeekSpeechFailure.protocol, 'no audio output'));
                return;
              }
            }
            var waiting = await _audio.write(id, chunk);
            while (waiting > _waitingBytes && !_stopped) {
              await Future<void>.delayed(const Duration(milliseconds: 150));
              waiting = await _audio.waiting(id);
            }
          }
          if (piece.done) break;
          await piece.more;
        }
        span.closed = piece.done && piece.chunks.isEmpty;
        if (_stopped) return;
        if (piece.error case final error?) {
          _fail(error);
          return;
        }
        _pieces.removeFirst();
        _prefetch();
      }
    } finally {
      _writing = false;
    }
    if (_finished && _pieces.isEmpty && !_stopped) _end();
  }

  void _end() {
    if (_endSent) return;
    _endSent = true;
    if (_opened) {
      unawaited(_audio.end(id));
    } else {
      _close(const SpeechOutDone());
    }
  }

  void _fail(Object error) {
    if (_ended) return;
    _stopped = true;
    _cancelFetches();
    if (_opened) unawaited(_audio.stop());
    _close(SpeechOutFailed(error));
  }

  @override
  void stop() {
    if (_stopped || _ended) return;
    _stopped = true;
    _cancelFetches();
    if (_opened) unawaited(_audio.stop());
    _close(const SpeechOutDone());
  }

  @override
  String get heard {
    final out = <String>[];
    for (final span in _spans) {
      final n = span.heardBy(_played);
      if (n == span.text.length) {
        out.add(span.text);
        continue;
      }
      if (n > 0) out.add(span.text.substring(0, n));
      break;
    }
    return _joined(out);
  }

  @override
  void duck(bool on) {
    if (_opened && !_stopped) unawaited(_audio.duck(id, on));
  }

  @override
  bool get canDuck => true;

  void _cancelFetches() {
    for (final piece in _pieces) {
      unawaited(piece.fetch?.cancel());
      piece._signal();
    }
    _pieces.clear();
    unawaited(_speech?.then((s) => s?.close()));
  }

  void _heard(SpeechAudioEvent event) {
    switch (event) {
      case PlayEvent(id: final which, :final phase) when which == id:
        switch (phase) {
          case PlayPhase.start:
            unawaited(const DiagnosticsChannel().recordVoiceStage('playback_started', backend: 'deepseek'));
            if (!_events.isClosed) _events.add(const SpeechOutStarted());
          case PlayPhase.done:
            _played = _written;
            _close(const SpeechOutDone());
          case PlayPhase.stopped:
            _close(const SpeechOutDone());
          case PlayPhase.error:
            _close(const SpeechOutFailed('playback'));
        }
      case PlayLevel(id: final which, :final value) when which == id:
        _played += _tickBytes;
        if (!_events.isClosed) _events.add(SpeechOutLevel(value));
      default:
        break;
    }
  }

  void _close(SpeechOutEvent last) {
    if (_ended) return;
    if (last is SpeechOutFailed) unawaited(const DiagnosticsChannel().recordVoiceStage('failed', backend: 'deepseek'));
    _ended = true;
    _stopped = true;
    if (!_events.isClosed) {
      _events.add(last);
      unawaited(_events.close());
    }
    unawaited(_sub.cancel());
    unawaited(_speech?.then((s) => s?.close()));
  }
}

// ── Any other voice, sentence by sentence ─────────────────────────────────

int _lines = 0;

/// Another voice (the phone's own, a preset service, an OpenAI-compatible or
/// custom API) through [speaker], which the caller has set up with its settings.
class SpeakerOut implements SpeechOut {
  SpeakerOut(this._speaker, {this.onPlaying}) {
    _sub = _speaker.events.listen(_heard);
  }

  final CompanionSpeaker _speaker;

  /// Told when a line starts and when the last one ends (a call listens
  /// more strictly while the voice plays).
  final void Function(bool playing)? onPlaying;
  final _chunker = SpeechChunker(first: 8, target: 60, max: 200);
  final _events = StreamController<SpeechOutEvent>.broadcast();
  late final StreamSubscription<CompanionVoiceEvent> _sub;
  final _open = <String>{};
  final _lineText = <String, String>{};
  final _saidLines = <String>[];

  /// Pieces not handed to the speaker yet: it fetches each line as soon as it
  /// is queued, so only a few go ahead of the one playing.
  final _held = Queue<String>();
  static const _ahead = 3;
  bool _finished = false;
  bool _ended = false;
  bool _started = false;
  int _failed = 0;
  int _said = 0;
  Timer? _levels;

  @override
  Stream<SpeechOutEvent> get events => _events.stream;

  @override
  bool get ended => _ended;

  @override
  void add(String text) {
    if (_finished || _ended) return;
    _chunker.add(text);
    _say(_chunker.take());
  }

  @override
  void finish() {
    if (_finished || _ended) return;
    _finished = true;
    _say(_chunker.take(final_: true));
    if (_open.isEmpty && _held.isEmpty) {
      _close(_said > 0 && _failed == _said ? const SpeechOutFailed('voice') : const SpeechOutDone());
    }
  }

  void _say(List<String> pieces) {
    _held.addAll(pieces);
    _release();
  }

  void _release() {
    while (_held.isNotEmpty && _open.length < _ahead && !_ended) {
      final id = 'r${++_lines}';
      final text = _held.removeFirst();
      _open.add(id);
      _lineText[id] = text;
      _said++;
      if (_said == 1) unawaited(const DiagnosticsChannel().recordVoiceStage('synthesis_requested'));
      _speaker.speak(id, text);
    }
  }

  void _heard(CompanionVoiceEvent event) {
    if (!_open.contains(event.id)) return;
    switch (event.type) {
      case CompanionVoiceEventType.start:
        if (!_started) {
          unawaited(const DiagnosticsChannel().recordVoiceStage('playback_started'));
          _started = true;
          if (!_events.isClosed) _events.add(const SpeechOutStarted());
        }
        onPlaying?.call(true);
        _animate(event.loudness);
      case CompanionVoiceEventType.done || CompanionVoiceEventType.stopped || CompanionVoiceEventType.error:
        if (event.type == CompanionVoiceEventType.error) _failed++;
        if (event.type == CompanionVoiceEventType.done) _saidLines.add(_lineText[event.id] ?? '');
        _open.remove(event.id);
        _release();
        if (_open.isEmpty) {
          _levels?.cancel();
          onPlaying?.call(false);
          if (_finished) {
            _close(_failed == _said ? const SpeechOutFailed('voice') : const SpeechOutDone());
          }
        }
      case CompanionVoiceEventType.range:
        // The phone's voice: a rough level while it speaks.
        if (!_events.isClosed) _events.add(SpeechOutLevel(0.4 + Random().nextDouble() * 0.4));
      case CompanionVoiceEventType.fallback:
        break;
    }
  }

  void _animate(List<double>? levels) {
    _levels?.cancel();
    if (levels == null || levels.isEmpty) return;
    var i = 0;
    _levels = Timer.periodic(const Duration(milliseconds: 40), (timer) {
      if (i >= levels.length || _events.isClosed) {
        timer.cancel();
        return;
      }
      _events.add(SpeechOutLevel(levels[i++]));
    });
  }

  /// Whole lines, as each finishes (the phone's voice tells no finer progress).
  @override
  String get heard => _joined(_saidLines);

  /// The phone's voice keeps its volume; the call's echo canceller copes.
  @override
  void duck(bool on) {}

  @override
  bool get canDuck => false;

  @override
  void stop() {
    if (_ended) return;
    if (_open.isNotEmpty) _speaker.stop();
    _open.clear();
    _held.clear();
    onPlaying?.call(false);
    _close(const SpeechOutDone());
  }

  void _close(SpeechOutEvent last) {
    if (_ended) return;
    if (last is SpeechOutFailed) unawaited(const DiagnosticsChannel().recordVoiceStage('failed'));
    _ended = true;
    _levels?.cancel();
    if (!_events.isClosed) {
      _events.add(last);
      unawaited(_events.close());
    }
    unawaited(_sub.cancel());
  }
}

/// A voice for [settings]: DeepSeek's streamed, anything else through [speaker].
SpeechOut speechOutFor(
  CompanionVoiceSettings settings, {
  required DeepSeekSpeechResolver deepseek,
  required SpeechAudio audio,
  required CompanionSpeaker speaker,
  bool call = false,
  bool levels = false,
  DeepSeekSpeechFailure Function()? gap,
}) {
  if (Platform.operatingSystem == 'ohos' && settings is OhosSpeechVoiceSettings) {
    return _OhosDeepSeekOut(deepseek, audio, voice: settings.voice, call: call, levels: levels, gap: gap);
  }
  if (settings.source == CompanionVoiceSource.deepseek) {
    if (Platform.operatingSystem == 'ohos') {
      return _OhosDeepSeekOut(deepseek, audio, voice: settings.deepseekVoice, call: call, levels: levels, gap: gap);
    }
    return DeepSeekOut(deepseek, audio, voice: settings.deepseekVoice, call: call, levels: levels, gap: gap);
  }
  if (Platform.operatingSystem == 'ohos' && settings.source != CompanionVoiceSource.system) return _OhosUnavailableOut();
  speaker.settings = settings;
  if (Platform.operatingSystem == 'ohos') {
    final out = _OhosSystemOut(speaker, onPlaying: call ? (on) => unawaited(audio.playing(on)) : null);
    if (speaker is OhosSpeechSpeaker) speaker._attachSystemOut(out, call: call);
    return out;
  }
  return SpeakerOut(speaker, onPlaying: call ? (on) => unawaited(audio.playing(on)) : null);
}
