// Compile and execute the pinned a836, b452 and 1317 module/type contexts, with
// original companion settings and diagnostics methods in each source tree.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dsh_app/speech/speech_out.dart';
import 'package:dsh_app/speech/speech_audio.dart';
import 'package:dsh_app/speech/deepseek_speech.dart';
import 'package:dsh_app/speech/speech_compat.dart';
import 'package:dsh_app/companion/companion_voice.dart';
import 'package:dsh_app/companion/companion_voice_source.dart';
import 'package:dsh_app/diagnostics/diagnostics_channel.dart';

import 'package:flutter/services.dart';

class Speech implements DeepSeekSpeech {
  final voices = <String>[];
  @override
  DeepSeekSpeechRoute get route => DeepSeekSpeechRoute.apiKey;
  @override
  Stream<Uint8List> synthesize(String text, {String voice = 'stella'}) async* { voices.add(voice); yield Uint8List(2); }
  @override
  Future<String> transcribe(Uint8List wav) => throw UnimplementedError();
  @override
  void close() {}
}
class UnusedSpeaker implements CompanionSpeaker {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

Future<void> main(List<String> args) async {
  final diagnostics = <Map>[];
  MethodChannel.outbound['dsh/diagnostics'] = (call) async { diagnostics.add(call.arguments as Map); return null; };
  final calls = <String>[];
  MethodChannel.outbound['dsh/speech'] = (call) async {
    calls.add(call.method);
    if (call.method == 'open') return true;
    if (call.method == 'write' || call.method == 'waiting') return 0;
    if (call.method == 'end') {
      final id = (call.arguments as Map)['id'];
      await MethodChannel.inbound['dsh/speech']!(MethodCall('event', {'type': 'play', 'what': 'done', 'id': id}));
    }
    return null;
  };
  final audio = SpeechAudio(), speech = Speech();
  const adapter = OhosSpeechVoiceSettings(voice: 'tide');
  final out = speechOutFor(adapter, deepseek: () async => speech, audio: audio, speaker: UnusedSpeaker());
  final done = Completer<void>(), events = <SpeechOutEvent>[];
  final sub = out.events.listen((event) {
    events.add(event); if ((event is SpeechOutDone || event is SpeechOutFailed) && !done.isCompleted) done.complete();
  });
  out..add('旧基底的显式协议设置无需修改既有语音枚举。')..finish();
  await done.future.timeout(const Duration(seconds: 3));
  final playback = speech.voices.length == 1 && speech.voices.single == 'tide' && events.whereType<SpeechOutFailed>().isEmpty;
  print(jsonEncode({'name': 'explicit request settings compile and play', 'pass': playback,
    'voices': speech.voices, 'enumValues': CompanionVoiceSource.values.map((x) => x.name).toList(), 'calls': calls}));
  diagnostics.clear();
  await const DiagnosticsChannel().recordVoiceStage('call_started', backend: 'cloud');
  final mainContext = args.single == 'b452' || args.single == '1317';
  final memberPriority = diagnostics.length == (mainContext ? 1 : 0);
  print(jsonEncode({'name': 'real diagnostics instance member precedes extension', 'pass': memberPriority,
    'context': args.single, 'callStartedRecorded': diagnostics.length}));
  final restored = CompanionVoiceSettings.fromPlain({'source': 'deepseek', 'deepseekVoice': 'tide'});
  final getterPriority = restored.deepseekVoice == (mainContext ? 'tide' : 'stella');
  print(jsonEncode({'name': 'real settings member precedes exact old-source fallback', 'pass': getterPriority,
    'restoredSource': restored.source.name, 'voice': restored.deepseekVoice}));
  out.stop(); await sub.cancel(); audio.dispose();
  print(jsonEncode({'scope': 'actual companion/diagnostics source; host Flutter/persistence boundaries only',
    'tests': 3, 'failed': [playback, memberPriority, getterPriority].where((ok) => !ok).length}));
  exitCode = playback && memberPriority && getterPriority ? 0 : 1;
}
