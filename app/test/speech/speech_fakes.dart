import 'dart:async';

import 'package:dsh_app/speech/call/voice_call.dart';
import 'package:dsh_app/speech/deepseek_speech.dart';
import 'package:dsh_app/speech/speech_audio.dart';
import 'package:dsh_app/speech/speech_out.dart';
import 'package:dsh_app/speech/voice_cloud.dart';
import 'package:flutter/services.dart';

/// The native side, played by the test: records what was asked, plays back
/// the events the test emits.
class FakeAudio extends SpeechAudio {
  FakeAudio({this.start = CallStart.ok}) : super(const MethodChannel('test/speech'));

  CallStart start;
  final calls = <String>[];
  final written = <String, List<int>>{};
  final _events = StreamController<SpeechAudioEvent>.broadcast(sync: true);

  void emit(SpeechAudioEvent event) => _events.add(event);

  @override
  Stream<SpeechAudioEvent> get events => _events.stream;

  @override
  Future<bool> open(String id, {int rate = 24000, bool call = false, bool levels = false}) async {
    calls.add('open:$id:call=$call');
    written[id] = [];
    return true;
  }

  @override
  Future<int> write(String id, Uint8List bytes) async {
    written[id]!.addAll(bytes);
    return 0;
  }

  @override
  Future<int> waiting(String id) async => 0;

  @override
  Future<void> end(String id) async => calls.add('end:$id');

  @override
  Future<void> stop() async => calls.add('stop');

  @override
  Future<void> duck(String id, bool on) async => calls.add('duck:$id:$on');

  @override
  Future<CallStart> startCall({required bool bargeIn, CallPause pause = CallPause.normal}) async {
    calls.add('callStart:bargeIn=$bargeIn');
    calls.add('callStart:pause=${pause.name}');
    return start;
  }

  @override
  Future<void> callPause(CallPause pause) async => calls.add('callPause:${pause.name}');

  @override
  Future<void> stopCall() async => calls.add('callStop');

  @override
  Future<void> mute(bool on) async => calls.add('mute:$on');

  @override
  Future<bool> speaker(bool on) async {
    calls.add('speaker:$on');
    return on;
  }

  @override
  Future<void> playing(bool on) async => calls.add('playing:$on');
}

/// DeepSeek, answering with the bytes of each text's UTF-8 (so order shows).
class FakeDeepSeek implements DeepSeekSpeech {
  FakeDeepSeek({this.fail});

  final DeepSeekSpeechError? fail;
  final asked = <String>[];
  final heard = <Uint8List>[];
  String transcript = '你好';
  bool closed = false;

  @override
  DeepSeekSpeechRoute get route => DeepSeekSpeechRoute.apiKey;

  @override
  Stream<Uint8List> synthesize(String text, {String voice = 'stella'}) async* {
    asked.add(text);
    if (fail case final error?) throw error;
    final bytes = Uint8List.fromList(text.codeUnits.expand((c) => [c & 0xFF, c >> 8]).toList());
    yield bytes.sublist(0, bytes.length ~/ 2);
    await Future<void>.delayed(Duration.zero);
    yield bytes.sublist(bytes.length ~/ 2);
  }

  @override
  Future<String> transcribe(Uint8List wav) async {
    heard.add(wav);
    if (fail case final error?) throw error;
    return transcript;
  }

  @override
  void close() => closed = true;
}

class FakeOut implements SpeechOut {
  @override
  bool canDuck = true;

  final added = <String>[];
  bool finished = false;
  bool stopped = false;
  final ducks = <bool>[];

  @override
  String heard = '';

  @override
  void duck(bool on) => ducks.add(on);
  final _events = StreamController<SpeechOutEvent>.broadcast(sync: true);

  void emit(SpeechOutEvent event) => _events.add(event);

  @override
  void add(String text) => added.add(text);

  @override
  void finish() => finished = true;

  @override
  void stop() {
    stopped = true;
    emit(const SpeechOutDone());
  }

  @override
  Stream<SpeechOutEvent> get events => _events.stream;

  @override
  bool get ended => stopped;
}

class FakeConversation implements CallConversation {
  final sent = <String>[];
  int interrupts = 0;
  bool accept = true;
  final _replies = StreamController<CallReply>.broadcast(sync: true);

  void reply(String text, {bool done = false}) => _replies.add(CallReply(text, done: done));

  @override
  Future<bool> send(String text) async {
    sent.add(text);
    return accept;
  }

  @override
  Stream<CallReply> get replies => _replies.stream;

  @override
  Future<void> interrupt() async => interrupts++;

  @override
  bool get waiting => false;

  @override
  void dispose() {}
}

class FakeCloud implements VoiceCloud {
  FakeCloud([this.text = '今天天气怎么样']);
  String text;
  Object? fail;
  final heard = <Uint8List>[];

  /// Answers once this completes, when set.
  Future<void>? wait;

  @override
  int get maxSeconds => 118;

  @override
  Future<String> transcribe(Uint8List wav) async {
    heard.add(wav);
    if (wait case final gate?) await gate;
    if (fail case final error?) throw error;
    return text;
  }
}
