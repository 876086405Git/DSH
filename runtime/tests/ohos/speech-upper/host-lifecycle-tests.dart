// Actual SpeechOut / SpeechAudio methods; the named MethodChannel boundary
// implements the integer queue-size protocol of frozen 1216, not a byte count.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dsh_app/speech/speech_audio.dart';
import 'package:dsh_app/speech/speech_out.dart';
import 'package:dsh_app/speech/deepseek_speech.dart';
import 'package:dsh_app/host_boundary.dart';
import 'package:dsh_app/companion/companion_voice.dart';
import 'package:dsh_app/companion/companion_voice_source.dart';
import 'package:dsh_app/speech/speech_compat.dart';
import 'package:dsh_app/platform_boundary.dart' as target;
import 'package:flutter/services.dart';
import 'host-speech-tests.dart' show FixtureSpeech, settle, UnusedSpeaker;

Future<void> until(bool Function() condition) async {
  final end = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(end)) throw StateError('condition did not complete');
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

class ProtocolAudio {
  ProtocolAudio() {
    MethodChannel.outbound['dsh/speech'] = (call) async {
      final args = call.arguments as Map? ?? {};
      final id = args['id'] as String?;
      calls.add({'method': call.method, 'id': id});
      switch (call.method) {
        case 'open':
          final n = opens++;
          currentId = id;
          return onOpen == null ? true : await onOpen!(n, id!);
        case 'stop':
          stops++;
          final stopped = currentId;
          await onStop?.call(stopped);
          queued = 0;
          if (stopped != null) await event(stopped, 'stopped');
          return null;
        case 'write':
          final bytes = args['bytes'] as Uint8List;
          writes.add(bytes.toList());
          queued = retain ? queued + bytes.length : 0;
          return queued;
        case 'waiting':
          return unavailable ? -1 : queued;
        case 'end':
          ends++;
          if (failEnd) throw const PlatformException(code: 'speech-output');
          await event(id!, 'done');
          return null;
        default:
          return null;
      }
    };
    audio = SpeechAudio();
  }
  late final SpeechAudio audio;
  Future<bool> Function(int n, String id)? onOpen;
  Future<void> Function(String? id)? onStop;
  final calls = <Map<String, Object?>>[];
  final writes = <List<int>>[];
  bool retain = false, unavailable = false, failEnd = false;
  String? currentId;
  int opens = 0, stops = 0, ends = 0, queued = 0;
  Future<void> event(String id, String what) async =>
      await MethodChannel.inbound['dsh/speech']?.call(MethodCall('event', {'type': 'play', 'id': id, 'what': what}));
  void dispose() { audio.dispose(); MethodChannel.outbound.remove('dsh/speech'); }
}

SpeechOut output(ProtocolAudio audio, DeepSeekSpeechResolver resolver) => speechOutFor(
  const OhosSpeechVoiceSettings(), deepseek: resolver, audio: audio.audio, speaker: UnusedSpeaker(),
);

Future<Map<String, Object?>> ownerHandoff() async {
  final audio = ProtocolAudio();
  final open = Completer<bool>(), stopped = Completer<void>();
  final sourceC = StreamController<Uint8List>();
  final a = FixtureSpeech(() => Stream.value(Uint8List(2)));
  final b = FixtureSpeech(() => Stream.value(Uint8List(2)));
  final c = FixtureSpeech(() => sourceC.stream);
  audio.onOpen = (n, _) => n == 0 ? open.future : Future.value(true);
  audio.onStop = (_) => stopped.future;
  final outA = output(audio, () async => a), outB = output(audio, () async => b), outC = output(audio, () async => c);
  final events = <SpeechOutEvent>[];
  final subs = [outA.events.listen((_) {}), outB.events.listen((_) {}), outC.events.listen(events.add)];
  try {
    outA..add('第一个所有者正在等待原生打开。')..finish();
    await until(() => audio.opens == 1);
    final oldId = audio.currentId!;
    outB..add('第二个所有者等待旧流退出。')..finish();
    await until(() => audio.stops == 1);
    outB.stop();
    outC..add('第三个所有者才会成为新的播放流。')..finish();
    await settle();
    final beforeOldOpen = audio.opens;
    open.complete(true);
    await settle();
    final beforeOldStop = audio.opens;
    stopped.complete();
    await until(() => audio.opens == 2 && c.asked.length == 1);
    final newId = audio.currentId;
    outA.stop(); outB.stop();
    await audio.event(oldId, 'error');
    sourceC.add(Uint8List.fromList([1, 2]));
    await until(() => audio.writes.length == 1);
    await sourceC.close();
    await until(() => events.whereType<SpeechOutDone>().length == 1);
    return {'pass': beforeOldOpen == 1 && beforeOldStop == 1 && audio.opens == 2 && audio.stops == 1 &&
        a.asked.isEmpty && b.asked.isEmpty && c.asked.length == 1 && newId != oldId && events.whereType<SpeechOutFailed>().isEmpty,
      'opensBeforeOldOpenRetired': beforeOldOpen, 'opensBeforeOldStopRetired': beforeOldStop,
      'opens': audio.opens, 'stops': audio.stops, 'synthesisByOwner': [a.asked.length, b.asked.length, c.asked.length],
      'events': events.map((x) => x.runtimeType.toString()).toList(), 'calls': audio.calls};
  } finally {
    if (!open.isCompleted) open.complete(false);
    if (!stopped.isCompleted) stopped.complete();
    outA.stop(); outB.stop(); outC.stop();
    await settle();
    for (final sub in subs) { await sub.cancel(); }
    if (!sourceC.isClosed) unawaited(sourceC.close());
    audio.dispose();
  }
}

Future<Map<String, Object?>> largeOddChunks() async {
  final audio = ProtocolAudio();
  // Two arbitrary transport chunk boundaries, both odd; combined PCM is even.
  const count = 2 * 1024 * 1024 + 8;
  final data = Uint8List.fromList(List<int>.generate(count, (i) => i % 251));
  final speech = FixtureSpeech(() => Stream.fromIterable([
    Uint8List.sublistView(data, 0, count - 5), Uint8List.sublistView(data, count - 5),
  ]));
  final out = output(audio, () async => speech);
  final events = <SpeechOutEvent>[];
  final sub = out.events.listen(events.add);
  try {
    out.add('所有字节都必须按原次序送达而且分片不丢奇数尾字节。');
    await until(() => audio.writes.fold<int>(0, (n, x) => n + x.length) == count);
    // finish() after the last response already ended still sends native EOF.
    await settle(); out.finish();
    await until(() => audio.ends == 1 && out.ended);
    var index = 0, correct = true, largest = 0;
    for (final chunk in audio.writes) {
      if (chunk.length > largest) largest = chunk.length;
      for (final byte in chunk) { if (byte != (index++ % 251)) correct = false; }
    }
    return {'pass': correct && index == count && largest <= 65536 && audio.ends == 1 && events.whereType<SpeechOutFailed>().isEmpty,
      'inputBytes': count, 'outputBytes': index, 'inputChunkLengths': [count - 5, 5],
      'largestMethodWrite': largest, 'methodWrites': audio.writes.length, 'nonnegativeResultForAllWrites': 0,
      'orderedBytesMatch': correct, 'endCalls': audio.ends};
  } finally { out.stop(); await settle(); await sub.cancel(); audio.dispose(); }
}

Future<Map<String, Object?>> cancelLargeChunk() async {
  final audio = ProtocolAudio()..retain = true;
  var produced = 0;
  final speech = FixtureSpeech(() async* { produced++; yield Uint8List(2 * 1024 * 1024 + 3); produced++; yield Uint8List(5); });
  final out = output(audio, () async => speech);
  final sub = out.events.listen((_) {});
  try {
    out..add('消费没有继续时，应停在当前大网络块内。')..finish();
    await until(() => audio.writes.length == 3);
    final queued = audio.queued;
    out.stop();
    await Future<void>.delayed(const Duration(milliseconds: 190));
    return {'pass': produced == 1 && audio.writes.length == 3 && queued == 196608 && speech.closed,
      'sourceChunkBytes': 2 * 1024 * 1024 + 3, 'pulledChunks': produced,
      'acceptedBytesBeforeStop': queued, 'methodWritesAfterStopSettled': audio.writes.length,
      'speechClosed': speech.closed};
  } finally { out.stop(); await settle(); await sub.cancel(); audio.dispose(); }
}

Future<Map<String, Object?>> cancelResolver() async {
  final audio = ProtocolAudio(), resolver = Completer<DeepSeekSpeech?>();
  final speech = FixtureSpeech(() => Stream.value(Uint8List(2)));
  final out = output(audio, () => resolver.future);
  final sub = out.events.listen((_) {});
  try {
    out..add('已预检但凭据解析尚未返回。')..finish();
    await until(() => audio.opens == 1); await settle();
    out.stop(); resolver.complete(speech); await settle();
    return {'pass': speech.asked.isEmpty && speech.closed && audio.writes.isEmpty,
      'synthesisCalls': speech.asked.length, 'lateResolvedOwnerClosed': speech.closed, 'writes': audio.writes.length};
  } finally { if (!resolver.isCompleted) resolver.complete(null); out.stop(); await settle(); await sub.cancel(); audio.dispose(); }
}

Future<Map<String, Object?>> queueUnavailable() async {
  final audio = ProtocolAudio()..unavailable = true;
  final speech = FixtureSpeech(() => Stream.value(Uint8List(2)));
  final out = output(audio, () async => speech), events = <SpeechOutEvent>[];
  final sub = out.events.listen(events.add);
  try {
    out..add('原生流在开始合成之前已经失效。')..finish(); await settle();
    return {'pass': speech.asked.isEmpty && events.whereType<SpeechOutFailed>().length == 1,
      'synthesisCalls': speech.asked.length, 'failedEvents': events.whereType<SpeechOutFailed>().length};
  } finally { out.stop(); await settle(); await sub.cancel(); audio.dispose(); }
}

Future<Map<String, Object?>> endFailure() async {
  final audio = ProtocolAudio()..failEnd = true;
  final speech = FixtureSpeech(() => Stream.value(Uint8List(2)));
  final out = output(audio, () async => speech), events = <SpeechOutEvent>[];
  final sub = out.events.listen(events.add);
  try {
    out..add('原生结束失败必须发出失败事件。')..finish(); await settle();
    return {'pass': events.whereType<SpeechOutFailed>().length == 1 && events.whereType<SpeechOutDone>().isEmpty,
      'failedEvents': events.whereType<SpeechOutFailed>().length, 'doneEvents': events.whereType<SpeechOutDone>().length};
  } finally { out.stop(); await settle(); await sub.cancel(); audio.dispose(); }
}

Future<Map<String, Object?>> androidSelection() async {
  final audio = ProtocolAudio();
  target.Platform.operatingSystem = 'android';
  final hasMainSpeechSetting = CompanionVoiceSource.values.any((value) => value.name == 'deepseek');
  final out = speechOutFor(CompanionVoiceSettings.fromPlain({'source': 'deepseek'}),
    deepseek: () async => null, audio: audio.audio, speaker: UnusedSpeaker());
  try { return {'pass': hasMainSpeechSetting ? out is DeepSeekOut : out is SpeakerOut,
    'hasMainSpeechSetting': hasMainSpeechSetting, 'selectedClass': out.runtimeType.toString()}; }
  finally { out.stop(); await settle(); audio.dispose(); target.Platform.operatingSystem = 'ohos'; }
}

Future<Map<String, Object?>> malformedResponse(int bytes) async {
  final audio = ProtocolAudio();
  final speech = FixtureSpeech(() => Stream.value(Uint8List(bytes)));
  final out = output(audio, () async => speech), events = <SpeechOutEvent>[];
  final sub = out.events.listen(events.add);
  try {
    out..add('第一段应该在这里结束，后面这一段不得被用来补齐上一段的半个样本。')..finish();
    await settle();
    return {'pass': speech.asked.length == 1 && events.whereType<SpeechOutFailed>().length == 1 && audio.ends == 0,
      'responseBytes': bytes, 'independentSynthesisResponsesRequested': speech.asked.length,
      'failedEvents': events.whereType<SpeechOutFailed>().length, 'nativeEndCalls': audio.ends};
  } finally { out.stop(); await settle(); await sub.cancel(); audio.dispose(); }
}

Future<void> main() async {
  final tests = <String, Future<Map<String, Object?>> Function()>{
    'late open and stop retire before third owner opens': ownerHandoff,
    'large odd chunks preserve all bytes and late finish': largeOddChunks,
    'cancel during large chunk capacity wait': cancelLargeChunk,
    'late resolver closes without synthesis': cancelResolver,
    'queue unavailable prevents synthesis': queueUnavailable,
    'native end failure stays failure': endFailure,
    'Android still selects original class': androidSelection,
    'independent odd PCM response fails before next sentence': () => malformedResponse(3),
    'empty successful response is an explicit failure': () => malformedResponse(0),
  };
  var failed = 0;
  for (final entry in tests.entries) {
    try {
      final result = await entry.value().timeout(const Duration(seconds: 8));
      if (result['pass'] != true) failed++;
      print(jsonEncode({'name': entry.key, ...result}));
    } catch (error, stack) { failed++; print(jsonEncode({'name': entry.key, 'pass': false, 'error': '$error', 'stack': '$stack'})); }
  }
  print(jsonEncode({'scope': 'actual Dart; explicit protocol audio boundary, not native audio execution', 'tests': tests.length, 'failed': failed}));
  exitCode = failed == 0 ? 0 : 1;
}
