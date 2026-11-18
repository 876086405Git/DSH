// Loads real companion_voice.dart (including speechSpeakerProvider), real
// companion_voice_source.dart, speech factory and new OH methods. Only the
// framework, persistence and platform channel are explicit host boundaries.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dsh_app/companion/companion_voice.dart';
import 'package:dsh_app/companion/companion_voice_source.dart';
import 'package:dsh_app/speech/deepseek_speech.dart';
import 'package:dsh_app/speech/speech_audio.dart';
import 'package:dsh_app/speech/speech_out.dart';
import 'package:dsh_app/speech/speech_compat.dart';
import 'package:dsh_app/platform_boundary.dart' as target;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

Future<void> settle() async { for (var n = 0; n < 30; n++) { await Future<void>.delayed(Duration.zero); } }
Future<void> until(bool Function() condition) async {
  final end = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(end)) throw StateError('condition did not complete');
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}
const settings = OhosSpeechVoiceSettings();

class Speech implements DeepSeekSpeech {
  Speech(this.body);
  final Stream<Uint8List> Function() body;
  int asked = 0;
  bool closed = false;
  @override
  DeepSeekSpeechRoute get route => DeepSeekSpeechRoute.apiKey;
  @override
  Stream<Uint8List> synthesize(String text, {String voice = 'stella'}) async* { asked++; yield* body(); }
  @override
  Future<String> transcribe(Uint8List wav) => throw UnimplementedError();
  @override
  void close() => closed = true;
}

class Fixture {
  Fixture(this.speech, this.folder) {
    MethodChannel.outbound['dsh/speech'] = (call) async {
      calls.add(call.method);
      final args = call.arguments as Map? ?? {};
      switch (call.method) {
        case 'open':
          id = args['id'] as String;
          final ok = await (openGate?.future ?? Future.value(open));
          if (ok) await event('start', id!);
          return ok;
        case 'write': writes++; return 0;
        case 'waiting': return 0;
        case 'end': await event('done', args['id'] as String); return null;
        case 'stop': if (id != null) await event('stopped', id!); return null;
        default: return null;
      }
    };
    MethodChannel.outbound['dsh/companion_voice'] = (call) async {
      companionCalls.add(call.method);
      return call.method == 'ready' || call.method == 'play' || call.method == 'speak' ? false : null;
    };
    audio = SpeechAudio(); voice = CompanionVoice();
    ref = Ref({
      companionVoiceProvider: voice,
      companionVoiceClientProvider: () { clientCreations++; return http.Client(); },
      companionVoiceFolderProvider: () async => folder,
      deepSeekSpeechProvider: () async => speech,
      speechAudioProvider: audio,
    });
    speaker = ref.read(speechSpeakerProvider);
  }
  final Speech speech;
  final Directory folder;
  late final Ref ref;
  late final SpeechAudio audio;
  late final CompanionVoice voice;
  late final CompanionSpeaker speaker;
  bool open = true;
  Completer<bool>? openGate;
  int writes = 0, clientCreations = 0;
  String? id;
  final calls = <String>[], companionCalls = <String>[];
  Future<void> event(String what, String id) async =>
      await MethodChannel.inbound['dsh/speech']?.call(MethodCall('event', {'type': 'play', 'id': id, 'what': what}));
  Future<void> dispose() async {
    speaker.dispose(); audio.dispose(); voice.dispose(); await settle();
    MethodChannel.outbound.clear(); await folder.delete(recursive: true);
  }
}

Future<Fixture> fixture(Speech speech) async => Fixture(speech, await Directory.systemTemp.createTemp('dsh-speech-preview-'));

Future<Map<String, Object?>> preflight() async {
  final speech = Speech(() => Stream.value(Uint8List(2)));
  final f = await fixture(speech)..open = false;
  try {
    final result = await f.speaker.preview(settings, '现有设置页的试听也必须先核播放器。');
    return {'pass': speech.asked == 0 && result != null,
      'providerClass': f.speaker.runtimeType.toString(), 'synthesisCalls': speech.asked,
      'result': result, 'pcmCalls': f.calls, 'companionCalls': f.companionCalls,
      'wholeFileHttpClientCreations': f.clientCreations};
  } finally { await f.dispose(); }
}

Future<Map<String, Object?>> cancelledOpen() async {
  final speech = Speech(() => Stream.value(Uint8List(2))), gate = Completer<bool>();
  final f = await fixture(speech)..openGate = gate;
  try {
    final pending = f.speaker.preview(settings, '在试听打开播放器期间取消。');
    await until(() => f.calls.contains('open'));
    f.speaker.stop(); gate.complete(true);
    final result = await pending; await settle();
    return {'pass': result != null && speech.asked == 0 && f.writes == 0,
      'result': result, 'synthesisCalls': speech.asked, 'writes': f.writes};
  } finally { if (!gate.isCompleted) gate.complete(false); await f.dispose(); }
}

Future<Map<String, Object?>> lateFailure() async {
  final body = StreamController<Uint8List>(), speech = Speech(() => body.stream);
  final f = await fixture(speech);
  try {
    var completed = false;
    final pending = f.speaker.preview(settings, '试听中途失败必须传回现有错误结果。').then((result) { completed = true; return result; });
    await until(() => speech.asked == 1);
    body.add(Uint8List(2)); await until(() => f.writes == 1);
    final completedBeforeFailure = completed;
    body.addError(const DeepSeekSpeechError(DeepSeekSpeechFailure.network));
    final result = await pending;
    return {'pass': !completedBeforeFailure && result == 'deepseek network',
      'futureCompletedAtPlaybackStart': completedBeforeFailure, 'result': result, 'writes': f.writes};
  } finally { unawaited(body.close()); await f.dispose(); }
}

Future<Map<String, Object?>> fullPreview() async {
  final speech = Speech(() => Stream.fromIterable([Uint8List.fromList([1, 2, 3]), Uint8List.fromList([4, 5, 6])]));
  final f = await fixture(speech);
  try {
    final result = await f.speaker.preview(settings, '完整试听必须保持两个奇数网络块的所有字节。');
    return {'pass': result == null && speech.asked == 1 && f.writes == 2 && f.clientCreations == 0,
      'result': result, 'synthesisCalls': speech.asked, 'writes': f.writes,
      'wholeFileHttpClientCreations': f.clientCreations, 'pcmCalls': f.calls};
  } finally { await f.dispose(); }
}

Future<Map<String, Object?>> unsupported() async {
  final speech = Speech(() => Stream.value(Uint8List(2))), f = await fixture(Speech(() => Stream.empty()));
  try {
    final result = await f.speaker.preview(const CompanionVoiceSettings(source: CompanionVoiceSource.openai,
      openaiKey: 'fixture-not-a-credential'), '不支持的编码在付费前失败。');
    return {'pass': result != null && f.clientCreations == 0 && f.speech.asked == 0 && f.calls.isEmpty,
      'result': result, 'externalClientCreations': f.clientCreations, 'pcmCalls': f.calls};
  } finally { speech.close(); await f.dispose(); }
}

Future<Map<String, Object?>> previewEvicted() async {
  final body = StreamController<Uint8List>(), speech = Speech(() => body.stream);
  final f = await fixture(speech);
  final next = Speech(() => Stream.value(Uint8List(2)));
  SpeechOut? out;
  StreamSubscription<SpeechOutEvent>? sub;
  try {
    final pending = f.speaker.preview(settings, '旧试听正在等待下一段音频。');
    await until(() => speech.asked == 1);
    out = speechOutFor(settings, deepseek: () async => next, audio: f.audio, speaker: f.speaker);
    final events = <SpeechOutEvent>[]; sub = out.events.listen(events.add);
    out..add('新的朗读占有会话后继续播放。')..finish();
    final result = await pending;
    f.speaker.stop();
    await until(() => events.whereType<SpeechOutDone>().isNotEmpty);
    return {'pass': result == 'cancelled' && next.asked == 1 && events.whereType<SpeechOutFailed>().isEmpty,
      'oldPreviewResult': result, 'newSynthesisCalls': next.asked, 'pcmCalls': f.calls,
      'newTerminalEvents': events.map((x) => x.runtimeType.toString()).toList()};
  } finally { out?.stop(); await sub?.cancel(); unawaited(body.close()); await f.dispose(); }
}

Future<Map<String, Object?>> androidProvider() async {
  target.Platform.operatingSystem = 'android';
  final f = await fixture(Speech(() => Stream.value(Uint8List(2))));
  try { return {'pass': f.speaker.runtimeType.toString() == 'CompanionSpeaker', 'selectedClass': f.speaker.runtimeType.toString()}; }
  finally { await f.dispose(); target.Platform.operatingSystem = 'ohos'; }
}

Future<void> main(List<String> args) async {
  final tests = <String, Future<Map<String, Object?>> Function()>{
    'actual preview provider preflights before synthesis': preflight,
    if (!args.contains('--baseline')) ...{
      'preview stop during late open prevents synthesis': cancelledOpen,
      'preview propagates stream failure after playback starts': lateFailure,
      'preview naturally completes with no whole-file fetch': fullPreview,
      'unsupported preview refuses before synthesis': unsupported,
      'read-aloud evicts preview without stale stop': previewEvicted,
      'Android preview provider remains original': androidProvider,
    },
  };
  var failed = 0;
  for (final entry in tests.entries) {
    try {
      final result = await entry.value().timeout(const Duration(seconds: 6));
      if (result['pass'] != true) failed++;
      print(jsonEncode({'name': entry.key, ...result}));
    } catch (error, stack) { failed++; print(jsonEncode({'name': entry.key, 'pass': false, 'error': '$error', 'stack': '$stack'})); }
  }
  print(jsonEncode({'scope': 'actual companion provider and Dart methods; explicit framework/audio boundary', 'tests': tests.length, 'failed': failed}));
  exitCode = failed == 0 ? 0 : 1;
}
