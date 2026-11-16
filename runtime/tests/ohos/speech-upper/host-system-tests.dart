// Actual OH provider, speaker and routing bodies. Flutter/OS calls are explicit boundaries.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dsh_app/companion/companion_voice.dart';
import 'package:dsh_app/companion/companion_voice_source.dart';
import 'package:dsh_app/speech/deepseek_speech.dart';
import 'package:dsh_app/speech/speech_audio.dart';
import 'package:dsh_app/speech/speech_out.dart';
import 'package:dsh_app/platform_boundary.dart' as target;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

const system = CompanionVoiceSettings(source: CompanionVoiceSource.system);
Future<void> settle() async { for (var n = 0; n < 20; n++) { await Future<void>.delayed(Duration.zero); } }
Future<void> until(bool Function() condition) async {
  final end = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(end)) throw StateError('condition did not complete');
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

class Fixture {
  Fixture() {
    MethodChannel.outbound['dsh/companion_voice'] = (call) async {
      calls.add(call);
      if (call.method == 'ready') return await (readyGate?.future ?? Future.value(ready));
      if (call.method == 'speak') return await (speakGate?.future ?? Future.value(accept));
      if (call.method == 'play') throw StateError('system voice must not play an external file');
      return null;
    };
    MethodChannel.outbound['dsh/speech'] = (call) async { pcm.add(call); return null; };
    voice = CompanionVoice(); audio = SpeechAudio();
    ref = Ref({companionVoiceProvider: voice, speechAudioProvider: audio,
      deepSeekSpeechProvider: () async { resolverCalls++; return null as DeepSeekSpeech?; },
      companionVoiceClientProvider: () { httpClients++; return http.Client(); },
      companionVoiceFolderProvider: () async => Directory.systemTemp});
    speaker = ref.read(speechSpeakerProvider);
  }
  bool ready = true, accept = true;
  Completer<bool>? readyGate;
  Completer<bool>? speakGate;
  final calls = <MethodCall>[], pcm = <MethodCall>[];
  late final CompanionVoice voice;
  late final SpeechAudio audio;
  late final Ref ref;
  late final CompanionSpeaker speaker;
  int resolverCalls = 0, httpClients = 0;
  List<MethodCall> get spoken => calls.where((c) => c.method == 'speak').toList();
  String get lastId => (spoken.last.arguments as Map)['id'] as String;
  Future<void> event(String type, String id) async {
    await MethodChannel.inbound['dsh/companion_voice']!(MethodCall('event', {'type': type, 'id': id}));
    await settle();
  }
  Future<void> dispose() async {
    speaker.dispose(); await settle(); voice.dispose(); audio.dispose(); await settle();
    MethodChannel.outbound.clear(); MethodChannel.inbound.clear();
  }
}

Future<Map<String, Object?>> route() async {
  final f = Fixture(); SpeechOut? out;
  StreamSubscription<SpeechOutEvent>? sub;
  try {
    final ready = await f.speaker.ready(system);
    out = speechOutFor(system, deepseek: () async { f.resolverCalls++; return null; }, audio: f.audio, speaker: f.speaker);
    final events = <SpeechOutEvent>[]; sub = out.events.listen(events.add);
    out..add('鸿蒙系统音色应当读出这句话。')..finish();
    await settle();
    if (f.spoken.isNotEmpty) { await f.event('start', f.lastId); await f.event('done', f.lastId); }
    return {'pass': ready && out is SpeakerOut && f.spoken.length == 1 &&
      events.whereType<SpeechOutStarted>().length == 1 && events.whereType<SpeechOutDone>().length == 1 &&
      events.whereType<SpeechOutFailed>().isEmpty && f.resolverCalls == 0 && f.httpClients == 0 && f.pcm.isEmpty,
      'provider': f.speaker.runtimeType.toString(), 'out': out.runtimeType.toString(),
      'ready': ready, 'spoken': f.spoken.length, 'paidResolvers': f.resolverCalls, 'httpClients': f.httpClients,
      'events': events.map((e) => e.runtimeType.toString()).toList()};
  } finally { out?.stop(); await sub?.cancel(); await f.dispose(); }
}

Future<Map<String, Object?>> preview() async {
  final f = Fixture();
  try {
    bool completed = false;
    final result = f.speaker.preview(system, '试听必须等播放完毕。').then((r) { completed = true; return r; });
    await until(() => f.spoken.length == 1); final id = f.lastId;
    await f.event('start', id); final waited = !completed;
    await f.event('done', id);
    return {'pass': waited && await result == null && f.resolverCalls == 0 && f.httpClients == 0,
      'waitedForPlayback': waited, 'result': await result};
  } finally { await f.dispose(); }
}

Future<Map<String, Object?>> failedPreview() async {
  final f = Fixture();
  try {
    final result = f.speaker.preview(system, '系统启动后仍可能失败。');
    await until(() => f.spoken.length == 1); await f.event('error', f.lastId);
    return {'pass': await result == 'no-phone-voice' && f.speaker.lastError == 'no-phone-voice',
      'result': await result, 'lastError': f.speaker.lastError};
  } finally { await f.dispose(); }
}

Future<Map<String, Object?>> cancelInit() async {
  final f = Fixture(); f.readyGate = Completer<bool>();
  try {
    final result = f.speaker.preview(system, '初始化中取消。');
    await until(() => f.calls.any((c) => c.method == 'ready'));
    f.speaker.stop(); f.readyGate!.complete(true);
    final reason = await result; await settle();
    return {'pass': reason == 'cancelled' && f.spoken.isEmpty, 'result': reason, 'spoken': f.spoken.length};
  } finally { await f.dispose(); }
}

Future<Map<String, Object?>> unavailable() async {
  final f = Fixture(); f.ready = false;
  try {
    final ready = await f.speaker.ready(system), result = await f.speaker.preview(system, '没有系统音色。');
    return {'pass': !ready && result == 'no-phone-voice' && f.spoken.isEmpty && f.resolverCalls == 0,
      'ready': ready, 'result': result, 'spoken': f.spoken.length};
  } finally { await f.dispose(); }
}

Future<Map<String, Object?>> rejectedSentence() async {
  final f = Fixture(); f.accept = false;
  SpeechOut? out; StreamSubscription<SpeechOutEvent>? sub;
  try {
    await f.speaker.ready(system);
    out = speechOutFor(system, deepseek: () async => null, audio: f.audio, speaker: f.speaker);
    final events = <SpeechOutEvent>[]; sub = out.events.listen(events.add);
    out..add('原生拒绝必须有终态。')..finish(); await settle();
    return {'pass': out.ended && events.whereType<SpeechOutFailed>().length == 1 && f.spoken.length == 1,
      'events': events.map((e) => e.runtimeType.toString()).toList(), 'ended': out.ended};
  } finally { out?.stop(); await sub?.cancel(); await f.dispose(); }
}

Future<Map<String, Object?>> android() async {
  target.Platform.operatingSystem = 'android'; final f = Fixture();
  try {
    final ready = await f.speaker.ready(system);
    f.speaker.speak('android-wire', '安卓字段保持一致。'); await until(() => f.spoken.length == 1);
    final args = f.spoken.single.arguments as Map;
    final wire = jsonEncode(args);
    return {'pass': f.speaker.runtimeType.toString() == 'CompanionSpeaker' && ready &&
      wire == jsonEncode({'id': 'android-wire', 'text': '安卓字段保持一致。', 'flush': false, 'pitch': 1.12, 'rate': 1.0}),
      'provider': f.speaker.runtimeType.toString(), 'ready': ready, 'wire': args};
  } finally { await f.dispose(); target.Platform.operatingSystem = 'ohos'; }
}

Future<Map<String, Object?>> callRouting() async {
  final f = Fixture(); SpeechOut? out;
  try {
    await f.speaker.ready(system);
    out = speechOutFor(system, deepseek: () async => null, audio: f.audio, speaker: f.speaker, call: true);
    out..add('这是通话中的系统音色回复。')..finish(); await until(() => f.spoken.length == 1);
    final callArgs = f.spoken[0].arguments as Map;
    await f.event('done', f.lastId);
    final sample = f.speaker.preview(system, '这是普通音色试听。'); await until(() => f.spoken.length == 2);
    final previewArgs = f.spoken[1].arguments as Map;
    await f.event('done', f.lastId);
    return {'pass': callArgs['call'] == true && previewArgs['call'] != true && await sample == null,
      'callUsage': callArgs['call'], 'previewUsage': previewArgs['call'], 'previewResult': await sample};
  } finally { out?.stop(); await f.dispose(); }
}

final longText = List.filled(20, '这是一段足够长的系统朗读文本，必须排成超过三个句子，才能看到等待队列。').join();
SpeechOut output(Fixture f) => speechOutFor(system, deepseek: () async => null, audio: f.audio, speaker: f.speaker);

Future<Map<String, Object?>> nativeEviction() async {
  final f = Fixture(); SpeechOut? out;
  try {
    await f.speaker.ready(system); out = output(f);
    out..add(longText)..finish(); await until(() => f.spoken.length == 3);
    final ids = f.spoken.map((c) => (c.arguments as Map)['id'] as String).toList();
    final stops = f.calls.where((c) => c.method == 'stop').length;
    for (final id in ids) { await f.event('stopped', id); }
    return {'pass': out.ended && f.spoken.length == 3 &&
      f.calls.where((c) => c.method == 'stop').length == stops,
      'initialSentences': 3, 'sentencesAfterNativeEviction': f.spoken.length, 'ended': out.ended,
      'extraGlobalStops': f.calls.where((c) => c.method == 'stop').length - stops};
  } finally { out?.stop(); await f.dispose(); }
}

Future<Map<String, Object?>> queuedAfterNativeEviction() async {
  final f = Fixture(); SpeechOut? out;
  final reply = f.speakGate = Completer<bool>();
  try {
    await f.speaker.ready(system); out = output(f);
    out..add(longText)..finish(); await until(() => f.spoken.length == 1);
    final id = f.lastId;
    final stops = f.calls.where((c) => c.method == 'stop').length;
    await f.event('stopped', id);
    reply.complete(true); await settle();
    return {'pass': out.ended && f.spoken.length == 1 &&
      f.calls.where((c) => c.method == 'stop').length == stops,
      'submittedBeforeEviction': 1, 'submittedAfterLateReply': f.spoken.length, 'ended': out.ended,
      'extraGlobalStops': f.calls.where((c) => c.method == 'stop').length - stops};
  } finally { if (!reply.isCompleted) reply.complete(false); out?.stop(); await f.dispose(); }
}

Future<Map<String, Object?>> replaceWithPreview() async {
  final f = Fixture(); SpeechOut? out;
  try {
    await f.speaker.ready(system); out = output(f);
    out..add(longText)..finish(); await until(() => f.spoken.length == 3);
    final ids = f.spoken.map((c) => (c.arguments as Map)['id'] as String).toList();
    final preview = f.speaker.preview(system, '新的系统音色试听。');
    await until(() => f.spoken.length == 4); final previewId = f.lastId;
    final stops = f.calls.where((c) => c.method == 'stop').length;
    for (final id in ids) { await f.event('stopped', id); }
    final count = f.spoken.length; final retired = out.ended;
    out.stop(); await settle();
    await f.event('done', previewId);
    return {'pass': retired && count == 4 && await preview == null &&
      f.calls.where((c) => c.method == 'stop').length == stops,
      'sentencesIncludingPreview': count, 'oldEnded': retired, 'previewResult': await preview,
      'staleStopReachesNative': f.calls.where((c) => c.method == 'stop').length != stops};
  } finally { out?.stop(); await f.dispose(); }
}

Future<Map<String, Object?>> replaceWithReadAloud() async {
  final f = Fixture(); SpeechOut? old, next;
  try {
    await f.speaker.ready(system); old = output(f);
    old..add(longText)..finish(); await until(() => f.spoken.length == 3);
    final ids = f.spoken.map((c) => (c.arguments as Map)['id'] as String).toList();
    next = output(f); next..add('另一条回复的朗读。')..finish(); await until(() => f.spoken.length == 4);
    final nextId = f.lastId;
    for (final id in ids) { await f.event('stopped', id); }
    await f.event('done', nextId);
    return {'pass': old.ended && next.ended && f.spoken.length == 4,
      'oldEnded': old.ended, 'newEnded': next.ended, 'sentencesIncludingNewReadAloud': f.spoken.length};
  } finally { old?.stop(); next?.stop(); await f.dispose(); }
}

Future<void> main(List<String> args) async {
  final regressions = <String, Future<Map<String, Object?>> Function()>{
    'native PCM eviction ends long system output without resubmission or stale stop': nativeEviction,
    'system preview retires more-than-three-line output before late stopped callbacks': replaceWithPreview,
    'new system read-aloud retires the prior held-sentence queue': replaceWithReadAloud,
    'native eviction drops lines still waiting for an earlier native method reply': queuedAfterNativeEviction,
  };
  final cases = args.contains('--queued-reply') ? {'native eviction drops lines still waiting for an earlier native method reply': queuedAfterNativeEviction} :
      args.contains('--call-routing') ? {'OH call flag reaches only system speech for that call': callRouting} :
      args.contains('--stop-regression') ? regressions : <String, Future<Map<String, Object?>> Function()>{
    'actual OH provider and speechOutFor route system voice without paid synthesis': route,
    if (!args.contains('--baseline')) ...{
      'system preview waits for playback completion': preview,
      'system preview observes late native error': failedPreview,
      'cancel during engine initialization cannot speak later': cancelInit,
      'unavailable system model reports no-phone-voice': unavailable,
      'native rejected sentence closes SpeakerOut as failure': rejectedSentence,
      'Android provider and system readiness remain original': android,
      'OH call flag reaches only system speech for that call': callRouting,
      ...regressions,
    },
  };
  var failures = 0;
  for (final entry in cases.entries) {
    try {
      final result = await entry.value().timeout(const Duration(seconds: 6));
      if (result['pass'] != true) failures++;
      print(jsonEncode({'name': entry.key, ...result}));
    } catch (error, stack) { failures++; print(jsonEncode({'name': entry.key, 'pass': false, 'error': '$error', 'stack': '$stack'})); }
  }
  print(jsonEncode({'scope': 'actual Dart bodies, explicit Flutter/OS channel boundaries', 'tests': cases.length, 'failed': failures}));
  exitCode = failures == 0 ? 0 : 1;
}
