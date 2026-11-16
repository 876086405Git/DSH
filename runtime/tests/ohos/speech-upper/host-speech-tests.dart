// Real Dart product module bodies. Flutter/channel/provider boundaries are
// explicit in prepare-host.py; local HTTP below is real dart:io, with no API.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dsh_app/speech/speech_out.dart';
import 'package:dsh_app/speech/speech_audio.dart';
import 'package:dsh_app/speech/deepseek_speech.dart';
import 'package:dsh_app/host_boundary.dart';
import 'package:dsh_app/companion/companion_voice.dart';
import 'package:dsh_app/companion/companion_voice_source.dart';
import 'package:dsh_app/speech/speech_compat.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

Future<void> settle([int rounds = 25]) async {
  for (var n = 0; n < rounds; n++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class FixtureSpeech implements DeepSeekSpeech {
  FixtureSpeech(this.source);
  final Stream<Uint8List> Function() source;
  final asked = <String>[];
  bool closed = false;
  @override
  DeepSeekSpeechRoute get route => DeepSeekSpeechRoute.apiKey;
  @override
  Stream<Uint8List> synthesize(String text, {String voice = 'stella'}) async* {
    asked.add(text);
    yield* source();
  }
  @override
  Future<String> transcribe(Uint8List _) => throw UnimplementedError();
  @override
  void close() => closed = true;
}

class AudioBoundary {
  AudioBoundary({this.openResult = true, this.openGate, this.rejectWrite = false, this.retain = false}) {
    MethodChannel.outbound['dsh/speech'] = (call) async {
      calls.add(call.method);
      final args = call.arguments as Map? ?? {};
      switch (call.method) {
        case 'open':
          openedId = args['id'] as String;
          if (!entered.isCompleted) entered.complete();
          return await (openGate?.future ?? Future.value(openResult));
        case 'write':
          writes++;
          final bytes = args['bytes'] as Uint8List;
          written += bytes.length;
          if (rejectWrite) return -1;
          waitingBytes = retain ? waitingBytes + bytes.length : 0;
          return waitingBytes;
        case 'waiting':
          return waitingBytes;
        case 'end':
          await emit('done', args['id'] as String);
          return null;
        case 'stop':
          waitingBytes = 0;
          if (openedId != null) await emit('stopped', openedId!);
          return null;
        default:
          return null;
      }
    };
    audio = SpeechAudio();
  }
  final bool openResult;
  final Completer<bool>? openGate;
  final bool rejectWrite, retain;
  final entered = Completer<void>();
  late final SpeechAudio audio;
  final calls = <String>[];
  String? openedId;
  int writes = 0, written = 0, waitingBytes = 0;
  Future<void> emit(String what, String id) async {
    await MethodChannel.inbound['dsh/speech']?.call(MethodCall('event', {'type': 'play', 'id': id, 'what': what}));
  }
  void dispose() {
    audio.dispose();
    MethodChannel.outbound.remove('dsh/speech');
  }
}

SpeechOut output(DeepSeekSpeechResolver resolver, SpeechAudio audio) => speechOutFor(
  const OhosSpeechVoiceSettings(), deepseek: resolver, audio: audio, speaker: UnusedSpeaker(),
);

class Holder {
  Holder(this.value);
  final dynamic value;
}
class ConnectionHolder {
  ConnectionHolder(this.client);
  final DshClient client;
}
class SettingsHolder {
  final String apiKey = '';
}

Future<DeepSeekSpeech> bridgeSpeech(DshConnection connection) async {
  invalidateDeepSeekSpeech();
  final ref = Ref({
    activeConnectionProvider: Holder(ConnectionHolder(DshClient(connection))),
    settingsProvider: SettingsHolder(),
  });
  return (await ref.read(deepSeekSpeechProvider)())!;
}

Future<Map<String, Object?>> preflightFalse() async {
  final audio = AudioBoundary(openResult: false);
  final speech = FixtureSpeech(() => Stream.value(Uint8List.fromList([1, 2])));
  final out = output(() async => speech, audio.audio);
  final events = <SpeechOutEvent>[];
  final sub = out.events.listen(events.add);
  try {
    out..add('这是一句需要播放的语音。')..finish();
    await settle();
    return {'pass': speech.asked.isEmpty && events.whereType<SpeechOutFailed>().length == 1,
      'synthesisCalls': speech.asked.length, 'failedEvents': events.whereType<SpeechOutFailed>().length,
      'nativeCalls': audio.calls.toList()};
  } finally { out.stop(); await sub.cancel(); audio.dispose(); }
}

Future<Map<String, Object?>> stopDuringOpen() async {
  final gate = Completer<bool>();
  final audio = AudioBoundary(openGate: gate);
  final speech = FixtureSpeech(() => Stream.value(Uint8List.fromList([1, 2])));
  final out = output(() async => speech, audio.audio);
  final sub = out.events.listen((_) {});
  try {
    out..add('这里将等待原生播放器打开。')..finish();
    await audio.entered.future.timeout(const Duration(seconds: 2));
    out.stop();
    gate.complete(true);
    await settle();
    return {'pass': speech.asked.isEmpty && audio.writes == 0,
      'synthesisCalls': speech.asked.length, 'writes': audio.writes, 'nativeCalls': audio.calls.toList()};
  } finally { if (!gate.isCompleted) gate.complete(false); out.stop(); await sub.cancel(); audio.dispose(); }
}

Future<Map<String, Object?>> invalidWrite() async {
  final audio = AudioBoundary(rejectWrite: true);
  final speech = FixtureSpeech(() => Stream.fromIterable([Uint8List(2), Uint8List(2)]));
  final out = output(() async => speech, audio.audio);
  final events = <SpeechOutEvent>[];
  final sub = out.events.listen(events.add);
  try {
    out..add('失效的原生流必须明确报错。')..finish();
    await settle();
    return {'pass': events.whereType<SpeechOutFailed>().length == 1 && audio.writes == 1,
      'failedEvents': events.whereType<SpeechOutFailed>().length, 'writes': audio.writes,
      'nativeCalls': audio.calls.toList()};
  } finally { out.stop(); await sub.cancel(); audio.dispose(); }
}

Future<Map<String, Object?>> pullBound() async {
  var produced = 0;
  Stream<Uint8List> source() async* {
    for (var n = 0; n < 20; n++) { produced++; yield Uint8List(65536); }
  }
  final audio = AudioBoundary(retain: true);
  final speech = FixtureSpeech(source);
  final out = output(() async => speech, audio.audio);
  final sub = out.events.listen((_) {});
  try {
    out..add('网络生产者比播放器更快时需要背压。')..finish();
    await settle(60);
    return {'pass': produced <= 4 && audio.waitingBytes <= 209536,
      'producedChunksWhileConsumerBlocked': produced, 'nativeQueuedBytes': audio.waitingBytes,
      'writes': audio.writes};
  } finally { out.stop(); await settle(); await sub.cancel(); audio.dispose(); await Future<void>.delayed(const Duration(milliseconds: 160)); }
}

Future<Map<String, Object?>> bridgeFirstChunk() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final sent = Completer<void>(), release = Completer<void>();
  final serving = server.listen((req) async {
    if (req.method == 'GET') {
      req.response.headers.contentType = ContentType.json;
      req.response.write('{"credential":"api-key"}');
      await req.response.close(); return;
    }
    await req.drain<void>();
    req.response.headers.contentType = ContentType.binary;
    req.response.bufferOutput = false;
    req.response.add([1, 2]); await req.response.flush(); sent.complete();
    await release.future;
    req.response.add([3, 4]); await req.response.close();
  });
  final connection = DshConnection(Uri.parse('http://127.0.0.1:${server.port}'));
  final speech = await bridgeSpeech(connection);
  final first = Completer<void>(), done = Completer<void>();
  final chunks = <List<int>>[];
  final sub = speech.synthesize('本地明确夹具').listen((bytes) {
    chunks.add(bytes.toList()); if (!first.isCompleted) first.complete();
  }, onError: (Object error, StackTrace stack) { if (!done.isCompleted) done.completeError(error, stack); },
     onDone: () { if (!done.isCompleted) done.complete(); });
  try {
    await sent.future.timeout(const Duration(seconds: 2));
    final early = await Future.any([first.future.then((_) => true), Future<bool>.delayed(const Duration(milliseconds: 750), () => false)]);
    final beforeEof = chunks.length;
    release.complete(); await done.future.timeout(const Duration(seconds: 2));
    return {'pass': early && jsonEncode(chunks.expand((x) => x).toList()) == '[1,2,3,4]',
      'firstChunkBeforeControlledEof': early, 'chunksBeforeEof': beforeEof, 'chunksAfterEof': chunks.length,
      'speechType': speech.runtimeType.toString(), 'bytes': chunks.expand((x) => x).toList()};
  } finally {
    if (!release.isCompleted) release.complete();
    speech.close(); await sub.cancel(); connection.close(force: true); await serving.cancel(); await server.close(force: true);
  }
}

Future<void> main(List<String> args) async {
  final tests = <String, Future<Map<String, Object?>> Function()>{
    'open failure prevents synthesis': preflightFalse,
    'stop during open prevents synthesis and late writes': stopDuringOpen,
    'write minus one is a terminal error': invalidWrite,
    'blocked consumer limits Dart producer pulls': pullBound,
    'bridge PCM is visible before controlled EOF': bridgeFirstChunk,
  };
  var failures = 0;
  for (final entry in tests.entries) {
    try {
      final result = await entry.value().timeout(const Duration(seconds: 8));
      if (result['pass'] != true) failures++;
      stdout.writeln(jsonEncode({'name': entry.key, ...result}));
    } catch (error, stack) {
      failures++;
      stdout.writeln(jsonEncode({'name': entry.key, 'pass': false, 'unexpectedError': '$error', 'stack': '$stack'}));
    }
  }
  stdout.writeln(jsonEncode({'scope': 'real Dart bodies; explicit framework/audio boundaries; real local HTTP',
    'tests': tests.length, 'passed': tests.length - failures, 'failed': failures}));
  exitCode = failures == 0 ? 0 : 1;
}

class UnusedSpeaker implements CompanionSpeaker {
  @override
  set settings(CompanionVoiceSettings value) {}
  @override
  Stream<CompanionVoiceEvent> get events => const Stream.empty();
  @override
  void stop() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
