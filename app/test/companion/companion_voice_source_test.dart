// An external voice: what is sent, what comes back, how loud it is, and the
// order sentences play in (with the phone's voice standing in when one fails).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dsh_app/companion/companion_state.dart';
import 'package:dsh_app/companion/companion_voice.dart';
import 'package:dsh_app/companion/companion_voice_source.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 16-bit mono PCM: [quiet] ms of silence, then [loud] ms of a 440 Hz tone.
Uint8List _wav({int quiet = 200, int loud = 200, int rate = 16000}) {
  final samples = [
    for (var i = 0; i < rate * quiet ~/ 1000; i++) 0,
    for (var i = 0; i < rate * loud ~/ 1000; i++) (sin(2 * pi * 440 * i / rate) * 12000).round(),
  ];
  final data = ByteData(44 + samples.length * 2);
  void text(int at, String s) => s.codeUnits.asMap().forEach((i, c) => data.setUint8(at + i, c));
  text(0, 'RIFF');
  data.setUint32(4, 36 + samples.length * 2, Endian.little);
  text(8, 'WAVE');
  text(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  text(36, 'data');
  data.setUint32(40, samples.length * 2, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    data.setInt16(44 + i * 2, samples[i], Endian.little);
  }
  return data.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('audio', () {
    test('kinds by their first bytes', () {
      expect(companionAudioKind(_wav()), 'wav');
      expect(companionAudioKind(Uint8List.fromList([...ascii.encode('ID3'), 3, 0])), 'mp3');
      expect(companionAudioKind(Uint8List.fromList([0xFF, 0xFB, 0x90, 0])), 'mp3');
      expect(companionAudioKind(Uint8List.fromList(ascii.encode('OggS....'))), 'ogg');
      expect(companionAudioKind(Uint8List.fromList(utf8.encode('{"error":1}'))), 'bin');
    });

    test('her mouth stays closed in silence and opens with the voice', () {
      final levels = companionLoudness(_wav())!;
      expect(levels, hasLength(10)); // 400 ms at 40 ms.
      expect(levels.take(5), everyElement(0));
      expect(levels.skip(5), everyElement(greaterThan(0.6)));
      expect(levels, everyElement(lessThanOrEqualTo(0.9)));
      expect(companionLoudness(Uint8List.fromList([0xFF, 0xFB, 0, 0])), isNull);
    });
  });

  group('fetch', () {
    test('OpenAI-compatible: the speech endpoint, the key, the voice, wav please', () async {
      late http.Request sent;
      final client = MockClient((request) async {
        sent = request;
        return http.Response.bytes(_wav(), 200);
      });
      const settings = CompanionVoiceSettings(
        source: CompanionVoiceSource.openai,
        openaiBase: 'https://api.siliconflow.cn/v1/',
        openaiKey: 'sk-test',
        openaiModel: 'FunAudioLLM/CosyVoice2-0.5B',
        openaiVoice: 'FunAudioLLM/CosyVoice2-0.5B:anna',
      );
      final audio = await fetchCompanionVoice(settings, '你好呀', client);
      expect(sent.url.toString(), 'https://api.siliconflow.cn/v1/audio/speech');
      expect(sent.headers['authorization'], 'Bearer sk-test');
      expect(jsonDecode(sent.body), {
        'model': 'FunAudioLLM/CosyVoice2-0.5B',
        'input': '你好呀',
        'voice': 'FunAudioLLM/CosyVoice2-0.5B:anna',
        'response_format': 'wav',
      });
      expect(audio.ext, 'wav');
    });

    test('custom POST: headers per line, the text escaped inside the template', () async {
      late http.Request sent;
      final client = MockClient((request) async {
        sent = request;
        return http.Response.bytes([0xFF, 0xFB, 0x90, 0x00], 200);
      });
      const settings = CompanionVoiceSettings(
        source: CompanionVoiceSource.custom,
        customUrl: 'http://192.168.1.5:9880/tts',
        customHeaders: 'X-Token: abc\nbroken line\nX-Speaker: 鲸鱼娘',
        customBody: '{"text": "{text}", "lang": "zh"}',
      );
      final audio = await fetchCompanionVoice(settings, '她说"你好"\n然后笑了', client);
      expect(sent.method, 'POST');
      expect(sent.headers['X-Token'], 'abc');
      expect(sent.headers['X-Speaker'], '鲸鱼娘');
      expect(jsonDecode(sent.body), {'text': '她说"你好"\n然后笑了', 'lang': 'zh'});
      expect(audio.ext, 'mp3');
    });

    test('custom GET with the text in the URL; JSON replies by field, base64 or link', () async {
      final wav = _wav(quiet: 0, loud: 40);
      final client = MockClient((request) async {
        if (request.url.path == '/speak') {
          expect(request.method, 'GET');
          expect(request.url.queryParameters['q'], '早上好');
          return http.Response(
            jsonEncode({
              'data': {'audio': base64.encode(wav)},
            }),
            200,
          );
        }
        if (request.url.path == '/link') {
          return http.Response(
            jsonEncode({
              'items': [
                {'url': 'https://cdn.example/a.wav'},
              ],
            }),
            200,
          );
        }
        if (request.url.host == 'cdn.example') return http.Response.bytes(wav, 200);
        return http.Response('', 404);
      });
      final b64 = await fetchCompanionVoice(
        const CompanionVoiceSettings(
          source: CompanionVoiceSource.custom,
          customUrl: 'https://tts.example/speak?q={text}',
          customPost: false,
          customField: 'data.audio',
        ),
        '早上好',
        client,
      );
      expect(b64.bytes, wav);
      final link = await fetchCompanionVoice(
        const CompanionVoiceSettings(
          source: CompanionVoiceSource.custom,
          customUrl: 'https://tts.example/link',
          customField: 'items.0.url',
        ),
        '早上好',
        client,
      );
      expect(link.ext, 'wav');
    });

    test('failures say why', () async {
      Future<String> why(http.Response response, {String field = ''}) async {
        try {
          await fetchCompanionVoice(
            CompanionVoiceSettings(
              source: CompanionVoiceSource.custom,
              customUrl: 'https://x.example',
              customField: field,
            ),
            'hi',
            MockClient((_) async => response),
          );
          return 'no error';
        } on CompanionVoiceError catch (error) {
          return error.reason;
        }
      }

      expect(await why(http.Response('{"error":"bad key"}', 401)), startsWith('HTTP 401'));
      expect(await why(http.Response('{"error":"quota"}', 200)), 'not audio');
      expect(await why(http.Response('{"data":{}}', 200), field: 'data.audio'), 'no field data.audio');
      expect(await why(http.Response('<html>', 200), field: 'data'), 'reply is not JSON');
    });
  });

  group('presets', () {
    Future<http.Request> sentBy(CompanionVoiceSettings settings, http.Response Function(http.Request) reply) async {
      late http.Request sent;
      await fetchCompanionVoice(
        settings,
        '你好呀',
        MockClient((request) async {
          if (request.url.host == 'oss.example') return http.Response.bytes(_wav(quiet: 0, loud: 40), 200);
          sent = request;
          return reply(request);
        }),
      );
      return sent;
    }

    test('MiMo: chat completions, the line as the assistant, the style as the user, base64 WAV back', () async {
      const settings = CompanionVoiceSettings(
        source: CompanionVoiceSource.preset,
        presetKeys: {'mimo': 'mimo-key'},
        presetVoices: {'mimo': '茉莉'},
      );
      expect(settings.configured, isTrue);
      final sent = await sentBy(
        settings,
        (_) => http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'audio': {'data': base64.encode(_wav(quiet: 0, loud: 40))},
                },
              },
            ],
          }),
          200,
        ),
      );
      expect(sent.url.toString(), 'https://api.xiaomimimo.com/v1/chat/completions');
      expect(sent.headers['api-key'], 'mimo-key');
      expect(sent.headers['Authorization'], 'Bearer mimo-key');
      expect(jsonDecode(sent.body), {
        'model': 'mimo-v2.5-tts',
        'messages': [
          {'role': 'user', 'content': companionVoiceStyleDefault},
          {'role': 'assistant', 'content': '你好呀'},
        ],
        'audio': {'format': 'wav', 'voice': '茉莉'},
      });
    });

    test('OpenAI takes the style as instructions; SiliconFlow names its voices; Bailian links its audio', () async {
      final openai = await sentBy(
        const CompanionVoiceSettings(
          source: CompanionVoiceSource.preset,
          preset: 'openai',
          presetKeys: {'openai': 'sk-o'},
          presetStyle: '轻声细语',
        ),
        (_) => http.Response.bytes(_wav(quiet: 0, loud: 40), 200),
      );
      expect(openai.url.toString(), 'https://api.openai.com/v1/audio/speech');
      expect(jsonDecode(openai.body), containsPair('instructions', '轻声细语'));
      expect(jsonDecode(openai.body), containsPair('voice', 'coral'));

      final silicon = await sentBy(
        const CompanionVoiceSettings(
          source: CompanionVoiceSource.preset,
          preset: 'siliconflow',
          presetKeys: {'siliconflow': 'sk-s'},
          presetVoices: {'siliconflow': 'anna'},
        ),
        (_) => http.Response.bytes(_wav(quiet: 0, loud: 40), 200),
      );
      expect(silicon.url.toString(), 'https://api.siliconflow.cn/v1/audio/speech');
      expect(jsonDecode(silicon.body), containsPair('voice', 'FunAudioLLM/CosyVoice2-0.5B:anna'));
      expect(jsonDecode(silicon.body), isNot(contains('instructions')));

      final bailian = await sentBy(
        const CompanionVoiceSettings(
          source: CompanionVoiceSource.preset,
          preset: 'bailian',
          presetKeys: {'bailian': 'sk-b'},
        ),
        (_) => http.Response(
          jsonEncode({
            'output': {
              'audio': {'url': 'https://oss.example/a.wav'},
            },
          }),
          200,
        ),
      );
      expect(bailian.headers['Authorization'], 'Bearer sk-b');
      expect(jsonDecode(bailian.body), {
        'model': 'qwen3-tts-flash',
        'input': {'text': '你好呀', 'voice': 'Cherry'},
      });
    });

    test('MiMo cloning: the cloning model, the recording as the voice', () async {
      final folder = Directory.systemTemp.createTempSync('companion-clone');
      addTearDown(() => folder.deleteSync(recursive: true));
      final sample = File('${folder.path}/voice-sample.wav')..writeAsBytesSync(_wav(quiet: 0, loud: 200));
      final settings = CompanionVoiceSettings(
        source: CompanionVoiceSource.preset,
        presetKeys: const {'mimo': 'mimo-key'},
        cloneOn: true,
        cloneSample: sample.path,
      );
      expect(settings.cloning, isTrue);
      expect(settings.configured, isTrue);
      expect(settings.copyWith(cloneSample: '').configured, isFalse);
      final sent = await sentBy(
        settings,
        (_) => http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'audio': {'data': base64.encode(_wav(quiet: 0, loud: 40))},
                },
              },
            ],
          }),
          200,
        ),
      );
      final body = jsonDecode(sent.body) as Map;
      expect(body['model'], 'mimo-v2.5-tts-voiceclone');
      final voice = (body['audio'] as Map)['voice'] as String;
      expect(voice, startsWith('data:audio/wav;base64,'));
      expect(base64.decode(voice.substring(voice.indexOf(',') + 1)), sample.readAsBytesSync());
    });

    test('a kept recording: mp3 or wav only, 7 MB at most, nothing half-written left', () async {
      final folder = Directory.systemTemp.createTempSync('companion-keep');
      addTearDown(() => folder.deleteSync(recursive: true));
      final wav = _wav(quiet: 0, loud: 200);
      final kept = await companionKeepRecording(Stream.value(wav), folder);
      expect(kept.path, endsWith('voice-sample.wav'));
      expect(kept.readAsBytesSync(), wav);
      expect(
        companionRecordingLength(Uint8List.fromList(wav.take(44).toList()), wav.length),
        const Duration(milliseconds: 200),
      );

      Future<String> refused(Stream<List<int>> bytes) async {
        try {
          await companionKeepRecording(bytes, folder);
          return 'kept';
        } on CompanionVoiceError catch (error) {
          return error.reason;
        }
      }

      expect(await refused(Stream.value(utf8.encode('hello, not audio'))), 'not-audio');
      expect(await refused(Stream.fromIterable(List.generate(8, (_) => List.filled(1024 * 1024, 0)))), 'too-large');
      // The good one is still the one kept, and nothing else is lying around.
      expect(folder.listSync().map((f) => f.uri.pathSegments.last), ['voice-sample.wav']);
    });

    test('a preset without its key is not set up; keys stay out of plain preferences', () {
      const settings = CompanionVoiceSettings(source: CompanionVoiceSource.preset, presetKeys: {'openai': 'sk-o'});
      expect(settings.configured, isFalse); // MiMo is chosen, its key is missing.
      expect(jsonEncode(settings.plain()), isNot(contains('sk-o')));
    });
  });

  group('settings', () {
    test('keys and headers stay out of plain preferences', () {
      const settings = CompanionVoiceSettings(openaiKey: 'sk-secret', customHeaders: 'Authorization: Bearer x');
      expect(jsonEncode(settings.plain()), isNot(contains('sk-secret')));
      expect(jsonEncode(settings.plain()), isNot(contains('Bearer')));
      final back = CompanionVoiceSettings.fromPlain(jsonDecode(jsonEncode(settings.plain())), on: true);
      expect(back.on, isTrue);
      expect(back.openaiKey, '');
      expect(back.source, CompanionVoiceSource.system);
    });

    test('her persona: the person\'s part first, the app\'s rules always after', () {
      expect(companionPersona(), companionPersonaCore);
      expect(companionPersonaCore, startsWith(companionPersonaDefault));
      final own = companionPersona(custom: '你是一只猫娘。', name: '小蓝', callMe: '阿周');
      expect(own, startsWith('你的名字是「小蓝」。\n你是一只猫娘。\n称呼对方为「阿周」。'));
      expect(own, endsWith('你就去做。'));
      expect(own, contains(companionPersonaRules));
      expect(companionPersona(custom: '你是一只猫娘。', tools: true), isNot(contains('用不上工具')));
      expect(companionPersona(custom: '你是一只猫娘。', tools: true), endsWith('不念步骤、编号或工具名。'));
    });

    test('her persona under the name she was given', () {
      expect(companionPersona(name: null), companionPersonaCore);
      expect(companionPersona(name: '  '), companionPersonaCore);
      expect(companionPersona(name: '小蓝'), startsWith('你是小蓝，一只'));
    });
  });

  group('speaker', () {
    const channel = MethodChannel('dsh/companion_voice');
    late List<MethodCall> calls;
    late Directory folder;

    setUp(() {
      calls = [];
      folder = Directory.systemTemp.createTempSync('companion-speaker');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return switch (call.method) {
          'ready' || 'speak' || 'play' => true,
          _ => null,
        };
      });
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      try {
        folder.deleteSync(recursive: true);
      } on FileSystemException {
        // The system clears temp.
      }
    });

    Future<void> native(String type, String id, {int? start, int? end}) =>
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
          channel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('event', {
              'type': type,
              'id': id,
              'start': ?start,
              'end': ?end,
            }),
          ),
          (_) {},
        );

    Future<void> until(bool Function() done) async {
      for (var i = 0; i < 200 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(done(), isTrue);
    }

    test('fetched sentences play in order, each after the one before; a failed one is read by the phone', () async {
      final client = MockClient((request) async {
        final text = (jsonDecode(request.body) as Map)['input'];
        if (text == '坏的。') return http.Response('nope', 500);
        return http.Response.bytes(_wav(quiet: 0, loud: 80), 200);
      });
      final speaker = CompanionSpeaker(CompanionVoice(), () => client, () async => folder);
      addTearDown(speaker.dispose);
      final events = <CompanionVoiceEvent>[];
      speaker.events.listen(events.add);
      expect(await speaker.ready(const CompanionVoiceSettings(on: true, source: CompanionVoiceSource.openai)), isTrue);
      await until(() => calls.any((c) => c.method == 'ready'));

      speaker
        ..speak('a', '第一句。')
        ..speak('b', '坏的。')
        ..speak('c', '第三句。');
      await until(() => calls.where((c) => c.method == 'play').length == 1);
      expect((calls.lastWhere((c) => c.method == 'play').arguments as Map)['id'], 'a');
      await native('start', 'a');
      await until(() => events.any((e) => e.type == CompanionVoiceEventType.start && e.id == 'a'));
      expect(events.firstWhere((e) => e.id == 'a').loudness, isNotEmpty);

      await native('done', 'a');
      // b couldn't be fetched: the phone's voice reads it, and says so.
      await until(() => calls.any((c) => c.method == 'speak'));
      expect((calls.lastWhere((c) => c.method == 'speak').arguments as Map)['text'], '坏的。');
      expect(events.map((e) => (e.type, e.id)), contains((CompanionVoiceEventType.fallback, 'b')));
      expect(calls.where((c) => c.method == 'play'), hasLength(1));

      await native('done', 'b');
      await until(() => calls.where((c) => c.method == 'play').length == 2);
      expect((calls.lastWhere((c) => c.method == 'play').arguments as Map)['id'], 'c');
      await native('done', 'c');
      // Played files don't stay.
      await until(() => folder.listSync().isEmpty);
    });

    test(
      "the phone's voice set without ready (chosen mid-call): the engine starts first; a refused line ends",
      () async {
        final client = MockClient((_) async => http.Response('', 500));
        final speaker = CompanionSpeaker(CompanionVoice(), () => client, () async => folder);
        addTearDown(speaker.dispose);
        final events = <CompanionVoiceEvent>[];
        speaker.events.listen(events.add);
        speaker.settings = const CompanionVoiceSettings(on: true);
        speaker
          ..speak('a', '一。')
          ..speak('b', '二。');
        await until(() => calls.where((c) => c.method == 'speak').length == 2);
        expect(calls.map((c) => c.method).where((m) => m != 'stop'), ['ready', 'speak', 'speak']);
        expect(calls.where((c) => c.method == 'speak').map((c) => (c.arguments as Map)['id']), ['a', 'b']);

        // The engine won't take it: no progress will come, so it ends here.
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (call) async => false,
        );
        speaker.speak('c', '三。');
        await until(() => events.any((e) => e.id == 'c'));
        expect(events.singleWhere((e) => e.id == 'c').type, CompanionVoiceEventType.error);
      },
    );

    test('one failed long fetch reads the whole line once, with its original progress and terminal ID', () async {
      final long = '${'甲' * 119}🐳${'乙' * 4000}。';
      final fetched = <String>[];
      final voice = CompanionVoice();
      final speaker = CompanionSpeaker(
        voice,
        () => MockClient((request) async {
          final text = (jsonDecode(request.body) as Map)['input'] as String;
          fetched.add(text);
          return text == long ? http.Response('unavailable', 503) : http.Response.bytes(_wav(), 200);
        }),
        () async => folder,
      );
      final other = CompanionSpeaker(voice, () => throw StateError('no fetch'), () async => folder);
      addTearDown(speaker.dispose);
      addTearDown(other.dispose);
      final events = <CompanionVoiceEvent>[];
      final unrelated = <CompanionVoiceEvent>[];
      speaker.events.listen(events.add);
      other.events.listen(unrelated.add);
      await speaker.ready(const CompanionVoiceSettings(on: true, source: CompanionVoiceSource.openai));
      expect(await speaker.warmPhone(), isTrue);
      speaker
        ..speak('long', long)
        ..speak('next', '下一句。');

      final heard = StringBuffer();
      final ids = <String>{};
      var count = 0;
      while (heard.length < long.length) {
        count++;
        await until(() => calls.where((c) => c.method == 'speak').length == count);
        expect(calls.where((c) => c.method == 'play'), isEmpty);
        final args = calls.lastWhere((c) => c.method == 'speak').arguments as Map;
        final id = args['id'] as String;
        final text = args['text'] as String;
        expect(ids.add(id), isTrue);
        expect(text.length, inInclusiveRange(1, 3999));
        if (count == 1) expect(text, '甲' * 119);
        await native('start', id);
        await native('range', id, start: 0, end: text.length);
        await until(() => events.any((e) => e.type == CompanionVoiceEventType.range && e.start == heard.length));
        expect(events.last.end, heard.length + text.length);
        expect(events.any((e) => e.type == CompanionVoiceEventType.done), isFalse);
        heard.write(text);
        await native('done', id);
        await native('done', id); // Duplicate receipts can arrive after the next piece is admitted.
      }
      await until(() => calls.any((c) => c.method == 'play'));
      expect(heard.toString(), long);
      expect(fetched, unorderedEquals([long, '下一句。']));
      expect(events.every((e) => e.id == 'long'), isTrue);
      for (final type in [
        CompanionVoiceEventType.fallback,
        CompanionVoiceEventType.start,
        CompanionVoiceEventType.done,
      ]) {
        expect(events.where((e) => e.type == type), hasLength(1));
      }
      expect(unrelated, isEmpty);
      expect(calls.singleWhere((c) => c.method == 'play').arguments['id'], 'next');
      await native('done', 'next');
      await until(() => folder.listSync().isEmpty);
    });

    testWidgets('ongoing fallback progress renews the minute guard; a silent engine errors without advancing', (
      tester,
    ) async {
      final speaker = CompanionSpeaker(
        CompanionVoice(),
        () => MockClient((_) async => http.Response('', 503)),
        () async => folder,
      );
      addTearDown(speaker.dispose);
      final events = <CompanionVoiceEvent>[];
      speaker.events.listen(events.add);
      await speaker.ready(const CompanionVoiceSettings(on: true, source: CompanionVoiceSource.openai));
      expect(await speaker.warmPhone(), isTrue);
      speaker.speak('slow', '读' * 4000);
      await tester.pump();
      final first = calls.singleWhere((c) => c.method == 'speak').arguments['id'] as String;
      await tester.pump(const Duration(seconds: 59));
      await native('range', first, start: 0, end: 2);
      await tester.pump();
      await tester.pump(const Duration(seconds: 59));
      expect(events.map((e) => e.type), [CompanionVoiceEventType.fallback, CompanionVoiceEventType.range]);
      await tester.pump(const Duration(seconds: 1));
      await native('done', first);
      await tester.pump();
      expect(events.last.id, 'slow');
      expect(events.last.type, CompanionVoiceEventType.error);
      expect(events.where((e) => e.type == CompanionVoiceEventType.done), isEmpty);
      expect(calls.where((c) => c.method == 'speak'), hasLength(1));
    });

    for (final cancel in [false, true]) {
      test('a long clip refused by native stops between parts (explicit stop: $cancel)', () async {
        var fetched = 0;
        final speaker = CompanionSpeaker(
          CompanionVoice(),
          () => MockClient((_) async {
            fetched++;
            return http.Response.bytes(_wav(), 200);
          }),
          () async => folder,
        );
        addTearDown(speaker.dispose);
        final events = <CompanionVoiceEvent>[];
        speaker.events.listen(events.add);
        final secondAdmission = Completer<bool>();
        var admitted = 0;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
          call,
        ) async {
          calls.add(call);
          if (call.method == 'ready') return true;
          if (call.method == 'play') return false;
          if (call.method == 'speak') return ++admitted == 1 ? true : secondAdmission.future;
          return null;
        });
        await speaker.ready(const CompanionVoiceSettings(on: true, source: CompanionVoiceSource.openai));
        expect(await speaker.warmPhone(), isTrue);
        speaker.speak('long', '答' * 4000);
        await until(() => admitted == 1);
        final first = calls.lastWhere((c) => c.method == 'speak').arguments['id'] as String;
        await native('start', first);
        await native('done', first);
        await until(() => admitted == 2);
        final second = calls.lastWhere((c) => c.method == 'speak').arguments['id'] as String;
        if (cancel) speaker.stop();
        secondAdmission.complete(cancel);
        final terminal = cancel ? CompanionVoiceEventType.stopped : CompanionVoiceEventType.error;
        await until(() => events.any((e) => e.type == terminal));
        await native('start', second);
        await native('done', second);
        await Future<void>.delayed(Duration.zero);
        expect(events.map((e) => (e.id, e.type)), [
          ('long', CompanionVoiceEventType.fallback),
          ('long', CompanionVoiceEventType.start),
          ('long', terminal),
        ]);
        expect(admitted, 2);
        expect(fetched, 1);
        expect(calls.where((c) => c.method == 'play'), hasLength(1));
        await until(() => folder.listSync().isEmpty);
      });
    }

    test('each fetched preview keeps its own file until native admission answers', () async {
      const external = CompanionVoiceSettings(on: true, source: CompanionVoiceSource.openai);
      final nativeVoice = CompanionVoice();
      final wav = _wav(quiet: 0, loud: 40);
      http.Client client() => MockClient((_) async => http.Response.bytes(wav, 200));
      final room = CompanionSpeaker(nativeVoice, client, () async => folder);
      final shared = CompanionSpeaker(nativeVoice, client, () async => folder);
      addTearDown(room.dispose);
      addTearDown(shared.dispose);
      final firstAnswer = Completer<bool>();
      final files = <File>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'play') return null;
        final args = call.arguments as Map;
        final file = File(args['path'] as String);
        files.add(file);
        if (files.length == 1) return firstAnswer.future;
        return false;
      });
      final first = room.preview(external, '小屋试听。');
      try {
        await until(() => files.isNotEmpty);
        expect(files[0].readAsBytesSync(), wav);
        expect(await shared.preview(external, '通用试听。'), 'cannot play wav');
        expect(files, hasLength(2));
        expect(files[1].path, isNot(files[0].path));
        await until(() => !files[1].existsSync());
        expect(files[0].readAsBytesSync(), wav);
      } finally {
        firstAnswer.complete(true);
      }
      expect(await first, isNull);
      await until(() => !files[0].existsSync());
    });

    test('stop: nothing queued plays after it', () async {
      final gate = Completer<void>();
      final client = MockClient((request) async {
        await gate.future;
        return http.Response.bytes(_wav(quiet: 0, loud: 40), 200);
      });
      var holdFolder = false;
      final folderEntered = Completer<void>();
      final folderReady = Completer<Directory>();
      final speaker = CompanionSpeaker(CompanionVoice(), () => client, () {
        if (!holdFolder) return Future.value(folder);
        folderEntered.complete();
        return folderReady.future;
      });
      addTearDown(speaker.dispose);
      const external = CompanionVoiceSettings(on: true, source: CompanionVoiceSource.openai);
      await speaker.ready(external);
      final fetchedPreview = speaker.preview(external, '试听。');
      speaker
        ..speak('a', '一。')
        ..speak('b', '二。')
        ..stop();
      gate.complete();
      expect(await fetchedPreview, 'cancelled');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(calls.where((c) => c.method == 'play'), isEmpty);
      expect(calls.map((c) => c.method), contains('stop'));

      // The response already arrived, but the original file write is pending.
      holdFolder = true;
      final writingPreview = speaker.preview(external, '写入中的试听。');
      await folderEntered.future;
      speaker.stop();
      folderReady.complete(folder);
      expect(await writingPreview, 'cancelled');
      expect(calls.where((c) => c.method == 'play'), isEmpty);

      // Android's first system-voice initialization can also finish after stop.
      final readyEntered = Completer<void>();
      final ready = Completer<bool>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'ready') {
          readyEntered.complete();
          return ready.future;
        }
        return switch (call.method) {
          'speak' || 'play' => true,
          _ => null,
        };
      });
      final systemPreview = speaker.preview(const CompanionVoiceSettings(on: true), '系统试听。');
      await readyEntered.future;
      speaker.stop();
      ready.complete(true);
      expect(await systemPreview, 'cancelled');
      expect(calls.where((c) => c.method == 'speak'), isEmpty);
    });
  });
}
