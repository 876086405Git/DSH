// Her voice. Off until the person turns it on (Pro C205/C309: first silent).
// The source is theirs to pick (companion_voice_source.dart): the phone's own
// text-to-speech, or an external speech API whose audio the app fetches
// sentence by sentence and plays in order. Both play through the native side
// (android CompanionVoicePlugin.kt, channel `dsh/companion_voice`); the app
// keeps no audio once a sentence has played.

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../phone/phone_channel.dart';
import '../speech/deepseek_speech.dart';
import '../speech/speech_audio.dart';
import '../speech/speech_out.dart';
import '../state/android_features.dart';
import 'companion_agent_phone_tools.dart' show companionPhoneWindow;
import 'companion_voice_source.dart';

enum CompanionVoiceEventType {
  start,
  range,
  done,
  stopped,
  error,

  /// The external voice failed for this sentence; the phone's own reads it.
  fallback,
}

class CompanionVoiceEvent {
  const CompanionVoiceEvent(this.type, this.id, {this.start, this.end, this.loudness});

  final CompanionVoiceEventType type;
  final String id;

  /// For [CompanionVoiceEventType.range]: the characters being spoken now.
  final int? start;
  final int? end;

  /// For [CompanionVoiceEventType.start] of fetched WAV audio: how open her
  /// mouth should be every 40 ms (companionLoudness).
  final List<double>? loudness;
}

/// The native side, as it is.
class CompanionVoice {
  CompanionVoice([MethodChannel? channel]) : _channel = channel ?? const MethodChannel('dsh/companion_voice') {
    _channel.setMethodCallHandler(_heard);
  }

  final MethodChannel _channel;
  final _events = StreamController<CompanionVoiceEvent>.broadcast();

  /// Her pitch and pace in the phone's own voice: a little higher than its default.
  static const pitch = 1.12;
  static const rate = 1.0;

  Stream<CompanionVoiceEvent> get events => _events.stream;

  Future<void> _heard(MethodCall call) async {
    if (call.method != 'event') return;
    final args = call.arguments;
    if (args is! Map) return;
    final type = CompanionVoiceEventType.values.asNameMap()[args['type']];
    final id = args['id'];
    if (type == null || id is! String) return;
    _events.add(
      CompanionVoiceEvent(type, id, start: (args['start'] as num?)?.toInt(), end: (args['end'] as num?)?.toInt()),
    );
  }

  /// Whether the phone's engine can speak [language] (starting it the first time).
  Future<bool> ready({String language = 'zh-CN'}) async {
    try {
      return await _channel.invokeMethod<bool>('ready', {'language': language}) ?? false;
    } on Object {
      return false;
    }
  }

  /// Queues [text] under [id] in the phone's voice, or replaces what it is saying with [flush].
  Future<bool> speak(String id, String text, {bool flush = false, bool ohosCall = false}) async {
    try {
      return await _channel.invokeMethod<bool>('speak', {
            'id': id,
            'text': text,
            'flush': flush,
            'pitch': pitch,
            'rate': rate,
            if (Platform.operatingSystem == 'ohos' && ohosCall) 'call': true,
          }) ??
          false;
    } on Object {
      return false;
    }
  }

  /// Plays one fetched sentence from [path] under [id].
  Future<bool> play(String id, String path) async {
    try {
      return await _channel.invokeMethod<bool>('play', {'id': id, 'path': path}) ?? false;
    } on Object {
      return false;
    }
  }

  Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } on Object {
      // Nothing was speaking, or there is no engine.
    }
  }

  void dispose() => unawaited(_events.close());
}

final companionVoiceProvider = Provider<CompanionVoice>((ref) {
  final voice = CompanionVoice();
  ref.onDispose(voice.dispose);
  return voice;
});

/// Where fetched requests go out, and where their audio waits to be played; tests answer both.
final companionVoiceClientProvider = Provider<http.Client Function()>((ref) => http.Client.new);
final companionVoiceFolderProvider = Provider<Future<Directory> Function()>((ref) => getTemporaryDirectory);

/// Where the recording to clone her voice from is kept (it outlives the cache).
final companionVoiceSampleFolderProvider = Provider<Future<Directory> Function()>(
  (ref) =>
      () async => Directory('${(await getApplicationSupportDirectory()).path}/companion'),
);

/// Picks a recording: its bytes and, when the system says, its size. Null when cancelled.
final companionVoicePickerProvider = Provider<Future<(Stream<List<int>>, int?)?> Function()>(
  (ref) => () async {
    final picked = await FilePicker.pickFile(type: FileType.audio);
    if (picked == null) return null;
    return (picked.readAsByteStream(), picked.lengthSync());
  },
);

class _Line {
  _Line(this.id, this.text, this.generation, this.audio);

  final String id;
  final String text;
  final int generation;
  final Future<CompanionVoiceAudio?> audio;
}

/// Her lines, in whichever voice is chosen, in order. External sentences are
/// fetched as soon as they are queued, so the next is ready while one plays; a
/// sentence that can't be fetched or played is read in the phone's own voice
/// when it has one. Events carry the loudness of fetched WAV audio for her mouth.
class CompanionSpeaker {
  CompanionSpeaker(
    this._voice,
    this._client,
    this._folder, [
    this._deepseek,
    this._ohosCall,
    this._ohosOutput,
    this._ohos = false,
  ]) {
    _native = _voice.events.listen(_heard);
  }

  final CompanionVoice _voice;
  final http.Client Function() _client;
  final Future<Directory> Function() _folder;

  /// Who pays for DeepSeek's voice, asked per sentence (an account may sign in or out).
  final DeepSeekSpeechResolver? _deepseek;
  // OH's system TTS needs communication usage for call audio. Android's
  // native payload remains unchanged; this optional route is only wired on OH.
  final bool Function()? _ohosCall;
  final Object? Function()? _ohosOutput;
  // OH's ordinary companion uses system TTS; fetched files have no player.
  final bool _ohos;
  late final StreamSubscription<CompanionVoiceEvent> _native;
  final _events = StreamController<CompanionVoiceEvent>.broadcast();

  CompanionVoiceSettings _settings = const CompanionVoiceSettings();
  bool _phoneReady = false;
  Future<void> _phoneLines = Future.value();
  int _generation = 0;
  // The room and shared voice settings use the same native player and cache.
  static int _previews = 0;
  // Private native receipts distinguish the parts of a single failed external line.
  static const _fallbackPrefix = 'companion-fallback-';
  static int _fallbackSerial = 0;
  void Function(CompanionVoiceEvent)? _fallbackReceipt;
  bool _pumping = false;
  final _queue = Queue<_Line>();
  final _ends = <String, Completer<void>>{};
  final _loudness = <String, List<double>>{};
  final _files = <String, File>{};
  var _cut = Completer<void>();

  /// Why the last fetched sentence failed, for the settings page.
  String? lastError;

  Stream<CompanionVoiceEvent> get events => _events.stream;

  /// The settings to speak with from now on; a different source cuts what is under way.
  set settings(CompanionVoiceSettings next) {
    if (next.source != _settings.source) stop();
    _settings = next;
  }

  /// Whether [next] can speak now: the engine for the phone's voice; for an
  /// external one, that it is filled in (and the phone's voice warms up as its stand-in).
  Future<bool> ready(CompanionVoiceSettings next) async {
    settings = next;
    if (next.source == CompanionVoiceSource.system) return _phoneReady = await _voice.ready();
    unawaited(_voice.ready().then((ok) => _phoneReady = ok));
    if (next.source == CompanionVoiceSource.deepseek) {
      final speech = await _deepseek?.call();
      speech?.close();
      return speech != null;
    }
    return next.configured;
  }

  /// Starts the phone's engine, leaving what is under way alone (a voice
  /// chosen while she reads: [ready] would cut her off).
  Future<bool> warmPhone() async => _phoneReady = await _voice.ready();

  /// Queues [text] under [id]; [flush] first drops whatever she is saying.
  void speak(String id, String text, {bool flush = false}) {
    if (flush) stop();
    if (_settings.source == CompanionVoiceSource.system) {
      // In order, each after the engine is up; a line it won't take ends as
      // an error, or whoever waits for its end would wait for good.
      final generation = _generation;
      final ohosCall = _ohosCall?.call() ?? false;
      final ohosOutput = _ohosOutput?.call();
      _phoneLines = _phoneLines.then((_) async {
        if (!_phoneReady) await warmPhone();
        if (generation != _generation ||
            (_ohosOutput != null && !identical(ohosOutput, _ohosOutput())) ||
            await _voice.speak(id, text, flush: flush, ohosCall: ohosCall)) {
          return;
        }
        if (!_events.isClosed) _events.add(CompanionVoiceEvent(CompanionVoiceEventType.error, id));
      });
      return;
    }
    _queue.add(_Line(id, text, _generation, _fetch(_settings, text)));
    unawaited(_pump());
  }

  /// Silence now: nothing queued plays, nothing on its way is waited for.
  void stop() {
    _generation++;
    _queue.clear();
    for (final end in _ends.values) {
      if (!end.isCompleted) end.complete();
    }
    _ends.clear();
    if (!_cut.isCompleted) _cut.complete();
    _cut = Completer<void>();
    unawaited(_voice.stop());
  }

  /// Says [text] with [next] at once, for the person to hear what they set up.
  /// Null when it played; else why not.
  Future<String?> preview(CompanionVoiceSettings next, String text) async {
    settings = next;
    stop();
    final generation = _generation;
    final id = 'preview-${++_previews}';
    if (next.source == CompanionVoiceSource.system) {
      final ready = await _voice.ready();
      if (generation != _generation) return 'cancelled';
      if (!ready) return 'no-phone-voice';
      final accepted = await _voice.speak(id, text, flush: true);
      if (generation != _generation) return 'cancelled';
      return accepted ? null : 'no-phone-voice';
    }
    if (!next.configured) return 'not-set-up';
    if (_ohos) return lastError = 'unsupported voice format';
    final client = _client();
    try {
      final audio = await fetchCompanionVoice(next, text, client, deepseek: _deepseek);
      if (generation != _generation) return 'cancelled';
      final file = await _write(id, audio);
      _files[id] = file;
      if (generation != _generation) return 'cancelled';
      final accepted = await _voice.play(id, file.path);
      if (generation != _generation) return 'cancelled';
      return accepted ? null : 'cannot play ${audio.ext}';
    } on CompanionVoiceError catch (error) {
      return error.reason;
    } finally {
      client.close();
      // Android has opened the descriptor and iOS has loaded the clip before
      // play answers. A refusal or a later stop may send no terminal event.
      _finish(id);
    }
  }

  Future<CompanionVoiceAudio?> _fetch(CompanionVoiceSettings settings, String text) async {
    if (_ohos) {
      lastError = 'unsupported voice format';
      // Keep the existing per-line system fallback, including a first line
      // arriving before ready's warm-up. The pump can still leave on _cut.
      if (!_phoneReady) await warmPhone();
      return null;
    }
    final client = _client();
    try {
      final audio = await fetchCompanionVoice(settings, text, client, deepseek: _deepseek);
      lastError = null;
      return audio;
    } on CompanionVoiceError catch (error) {
      lastError = error.reason;
      return null;
    } finally {
      client.close();
    }
  }

  Future<File> _write(String id, CompanionVoiceAudio audio) async {
    final file = File('${(await _folder()).path}/companion-voice-$id.${audio.ext}');
    await file.writeAsBytes(audio.bytes, flush: true);
    return file;
  }

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (_queue.isNotEmpty) {
        final line = _queue.removeFirst();
        if (line.generation != _generation) continue;
        final cut = _cut.future;
        CompanionVoiceAudio? audio;
        // Complete with nothing: the long-lived cut keeps every race's result
        // until the next stop, and the audio bytes shouldn't stay with it.
        await Future.any([
          line.audio.then<void>((a) {
            audio = a;
          }),
          cut,
        ]);
        if (line.generation != _generation) continue;
        final end = _ends[line.id] = Completer<void>();
        try {
          var started = false;
          if (audio case final fetched?) {
            try {
              final file = await _write(line.id, fetched);
              _files[line.id] = file;
              if (line.generation != _generation) continue;
              if (fetched.ext == 'wav') {
                if (companionLoudness(fetched.bytes) case final levels?) _loudness[line.id] = levels;
              }
              started = await _voice.play(line.id, file.path);
            } on FileSystemException {
              started = false;
            }
          }
          if (line.generation != _generation) continue;
          if (!started && _phoneReady) {
            _events.add(CompanionVoiceEvent(CompanionVoiceEventType.fallback, line.id));
            if (line.text.length > _systemSpeechLimit) {
              await _speakLongFallback(line);
              continue;
            }
            started = await _voice.speak(line.id, line.text);
          }
          if (!started) {
            _events.add(CompanionVoiceEvent(CompanionVoiceEventType.error, line.id));
          } else {
            await end.future.timeout(const Duration(minutes: 1), onTimeout: () {});
          }
        } finally {
          _finish(line.id);
        }
      }
    } finally {
      _pumping = false;
    }
  }

  /// One paid request has already failed. Admit one short native utterance at
  /// a time; the page and any reader keep the original ID until the last one.
  Future<void> _speakLongFallback(_Line line) async {
    var announced = false;
    var offset = 0;
    try {
      // Use the reader's normal group size under the existing one-minute
      // watchdog. A 3999-unit utterance can take many minutes to say.
      for (final part in companionSystemSpeechParts(line.text, limit: SpeechChunker().target)) {
        final nativeId = '$_fallbackPrefix${++_fallbackSerial}';
        final end = _ends[line.id] = Completer<void>();
        var result = CompanionVoiceEventType.error;
        void finish(CompanionVoiceEventType type) {
          if (end.isCompleted) return;
          result = type;
          end.complete();
        }

        Timer? watchdog;
        void progress() {
          watchdog?.cancel();
          watchdog = Timer(const Duration(minutes: 1), () => finish(CompanionVoiceEventType.error));
        }

        _fallbackReceipt = (event) {
          if (event.id != nativeId || end.isCompleted || line.generation != _generation) return;
          switch (event.type) {
            case CompanionVoiceEventType.start:
              progress();
              if (announced) return;
              announced = true;
              _events.add(CompanionVoiceEvent(event.type, line.id));
            case CompanionVoiceEventType.range:
              progress();
              _events.add(
                CompanionVoiceEvent(
                  event.type,
                  line.id,
                  start: event.start == null ? null : offset + event.start!,
                  end: event.end == null ? null : offset + event.end!,
                ),
              );
            case CompanionVoiceEventType.done || CompanionVoiceEventType.stopped || CompanionVoiceEventType.error:
              finish(event.type);
            case CompanionVoiceEventType.fallback:
              break;
          }
        };
        progress();
        unawaited(
          _voice.speak(nativeId, part).then((ok) {
            if (!ok) finish(CompanionVoiceEventType.error);
          }),
        );
        await end.future;
        watchdog?.cancel();
        if (line.generation != _generation) {
          if (!_events.isClosed) _events.add(CompanionVoiceEvent(CompanionVoiceEventType.stopped, line.id));
          return;
        }
        if (result != CompanionVoiceEventType.done) {
          _events.add(CompanionVoiceEvent(result, line.id));
          return;
        }
        offset += part.length;
      }
      _events.add(CompanionVoiceEvent(CompanionVoiceEventType.done, line.id));
    } finally {
      _fallbackReceipt = null;
    }
  }

  void _heard(CompanionVoiceEvent event) {
    if (event.id.startsWith(_fallbackPrefix)) {
      _fallbackReceipt?.call(event);
      return;
    }
    switch (event.type) {
      case CompanionVoiceEventType.start:
        _events.add(CompanionVoiceEvent(event.type, event.id, loudness: _loudness[event.id]));
        return;
      case CompanionVoiceEventType.done || CompanionVoiceEventType.stopped || CompanionVoiceEventType.error:
        final end = _ends.remove(event.id);
        if (end != null && !end.isCompleted) end.complete();
      case CompanionVoiceEventType.range || CompanionVoiceEventType.fallback:
        break;
    }
    _events.add(event);
  }

  void _finish(String id) {
    _ends.remove(id);
    _loudness.remove(id);
    final file = _files.remove(id);
    if (file != null) unawaited(file.delete().then((_) {}, onError: (Object _) {}));
  }

  void dispose() {
    stop();
    unawaited(_native.cancel());
    unawaited(_events.close());
  }
}

final companionSpeakerProvider = Provider<CompanionSpeaker>((ref) {
  final speaker = CompanionSpeaker(
    ref.watch(companionVoiceProvider),
    ref.watch(companionVoiceClientProvider),
    ref.watch(companionVoiceFolderProvider),
    ref.watch(deepSeekSpeechProvider),
    null,
    null,
    ref.watch(operatingSystemProvider) == 'ohos',
  );
  ref.onDispose(speaker.dispose);
  return speaker;
});

/// The same kind of speaker for 朗读 and 语音通话 when their voice isn't
/// DeepSeek's (that one streams: speech_out.dart). Its own queue: reading a
/// reply aloud never cuts into her lines' bookkeeping.
final speechSpeakerProvider = Provider<CompanionSpeaker>((ref) {
  if (Platform.operatingSystem == 'ohos') {
    late final OhosSpeechSpeaker speaker;
    speaker = OhosSpeechSpeaker(
      ref.watch(deepSeekSpeechProvider),
      ref.watch(speechAudioProvider),
      CompanionSpeaker(
        ref.watch(companionVoiceProvider),
        ref.watch(companionVoiceClientProvider),
        ref.watch(companionVoiceFolderProvider),
        null,
        () => speaker.systemCall,
        () => speaker.systemOutput,
      ),
    );
    ref.onDispose(speaker.dispose);
    return speaker;
  }
  final speaker = CompanionSpeaker(
    ref.watch(companionVoiceProvider),
    ref.watch(companionVoiceClientProvider),
    ref.watch(companionVoiceFolderProvider),
    ref.watch(deepSeekSpeechProvider),
  );
  ref.onDispose(speaker.dispose);
  return speaker;
});

// Android 9 rejects even exactly getMaxSpeechInputLength() (4000 UTF-16 units).
const _systemSpeechLimit = 3999;
final companionSentenceEnd = RegExp(r'[。！？!?…~～]');

/// Lossless, bounded pieces for the phone's synthesizer. Keep surrogate pairs
/// together and prefer the last sentence end inside the available space.
Iterable<String> companionSystemSpeechParts(String text, {int limit = _systemSpeechLimit}) sync* {
  for (var start = 0; start < text.length;) {
    var end = text.length;
    if (end - start > limit) {
      end = start + limit;
      final boundary = companionSentenceEnd.allMatches(text.substring(start, end)).lastOrNull;
      if (boundary != null) {
        end = start + boundary.end;
      } else if ((text.codeUnitAt(end - 1) & 0xfc00) == 0xd800) {
        end--;
      }
    }
    yield text.substring(start, end);
    start = end;
  }
}

/// The sentences ready to be read aloud in [words] after [from]: up to the last
/// sentence end, or all of it once [final_] (a reply that has finished).
(String, int) companionSpeakable(String words, int from, {required bool final_}) {
  if (from >= words.length) return ('', words.length.clamp(0, from));
  final rest = words.substring(from);
  if (final_) return (rest.trim(), words.length);
  final end = RegExp(r'[。！？!?…~～\n]').allMatches(rest).lastOrNull?.end;
  if (end == null) return ('', from);
  return (rest.substring(0, end).trim(), from + end);
}

/// One reply's words while she works on the phone, line by line as she goes:
/// the [line] since her last step for her bubble, and what to [say] now. Whole
/// sentences as they come; the rest once she starts a step (what she said
/// before it is done) or the reply is in.
class CompanionPhoneLines {
  int _steps = 0;
  int _said = 0;
  int _lineFrom = 0;
  String _words = '';

  ({String line, String say}) read(String words, {required int steps, required bool running}) {
    final stepped = steps > _steps;
    _steps = steps;
    // What was read holds up to the first change. A retry can take words
    // back, and what was said stays said; the Host's saved reply can rewrite
    // them ("东。" saved as "西。"), and that is read again from the change.
    final read = min(max(_said, _lineFrom), min(words.length, _words.length));
    var same = 0;
    while (same < read && words.codeUnitAt(same) == _words.codeUnitAt(same)) {
      same++;
    }
    // Never between an emoji's two halves: "😀" rewritten as "😁" shares the first.
    if (same > 0 && words.codeUnitAt(same - 1) & 0xFC00 == 0xD800) same--;
    _words = words;
    final (say, said) = companionSpeakable(words, min(_said, same), final_: !running || stepped);
    _said = said;
    final line = words.substring(min(_lineFrom, same)).trim();
    if (stepped) _lineFrom = words.length;
    return (line: line, say: say);
  }
}

/// Each time the person stops her phone work from outside her room (the
/// island, the pill, the notification): a task of hers seen running, now
/// stopped by them. Her voice stops with it.
Stream<void> companionPhoneUserStops(Stream<PhoneStatus> statuses) {
  final running = <String>{};
  return statuses.expand((status) {
    var stopped = false;
    for (final task in status.tasks) {
      final id = task.sessionId;
      if (id == null || companionPhoneWindow(id) == null) continue;
      if (!task.stopped) {
        running.add(id);
      } else if (running.remove(id) && task.stopSource == 'USER') {
        stopped = true;
      }
    }
    return [if (stopped) null];
  });
}
