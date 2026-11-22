import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart';

Map<String, Object?> _preset({bool streaming = true}) => {
  ...t24Preset().raw,
  'stream_openai': streaming,
  'extensions': {
    'SPreset': {
      'LogUpload': {'enabled': true, 'url': 'https://upload.invalid/report'},
    },
  },
};

void main() {
  for (final change in [(before: true, after: false), (before: false, after: true), (before: true, after: true)]) {
    test('upload reads current global opt-in after loading: ${change.before} -> ${change.after}', () async {
      final h = await T24Harness.open();
      addTearDown(h.dispose);
      await h.engine.setPreset(ChatPreset(_preset()));
      await h.engine.setSettings({'spresetLogUploadEnabled': change.before});
      final entered = Completer<void>(), release = Completer<void>();
      var sends = 0;
      Object? failure;
      Map<String, Object?>? result;
      final pending =
          IOOverrides.runZoned(
            () => http.runWithClient(
              () => h.engine.uploadSPresetLogs(h.chatId),
              () => MockClient((request) async {
                sends++;
                expect(request.url, Uri.parse('https://upload.invalid/report'));
                return http.Response('{"id":"uploaded"}', 200);
              }),
            ),
            createFile: (path) => path.endsWith('spreset-generation-logs.json')
                ? _LogLoadGate(path, entered, release)
                : Zone.root.run(() => File(path)),
          ).then<void>(
            (value) => result = value,
            onError: (Object error, StackTrace stack) {
              failure = error;
            },
          );
      try {
        await entered.future;
        expect(sends, 0);
        await h.engine.setSettings({'spresetLogUploadEnabled': change.after});
      } finally {
        release.complete();
      }
      await pending;
      expect(sends, change.after ? 1 : 0);
      if (change.after) {
        expect(failure, isNull);
        expect(result, containsPair('id', 'uploaded'));
      } else {
        expect(failure, isA<SPresetException>().having((error) => error.detail, 'detail', contains('disabled')));
        expect(result, isNull);
      }
    });
  }

  for (final sse in [false, true]) {
    test('log buffer filters known secrets after ${sse ? 'SSE' : 'JSON'} decoding and keeps ordinary content', () {
      const raw = r'{"content":"echo sk\u002dfixture","ordinary":"keep","nested":"{\"note\":\"sk\\u002dfixture\"}"}';
      final body = sse ? 'data: $raw\n\ndata: [DONE]\n\n' : raw;
      final logs = SPresetLogBuffer()
        ..add(
          {
            'id': 'escaped',
            'presetName': 'fixture',
            'response': {
              'transport': [
                {'body': body},
              ],
            },
          },
          secrets: ['sk-fixture'],
        );
      final report = logs.report(presetName: 'fixture', at: DateTime.utc(2026));
      final record = (report['records']! as List).single as Map;
      final transport = ((record['response'] as Map)['transport'] as List).single as Map;
      final clean = sse
          ? jsonDecode((transport['body'] as String).split('\n').first.substring(6)) as Map
          : transport['body'] as Map;
      expect(clean['content'], 'echo [REDACTED]');
      expect(clean['ordinary'], 'keep');
      expect(jsonDecode(clean['nested'] as String), {'note': '[REDACTED]'});
      expect(jsonEncode(report), isNot(contains('sk-fixture')));
      if (sse) expect(transport['body'], endsWith('data: [DONE]\n\n'));
    });
  }

  test('malformed and truncated transport bodies still retain only omission reasons', () {
    final logs = SPresetLogBuffer()
      ..add(
        {
          'id': 'omitted',
          'response': {
            'transport': [
              {'body': 'data: {"content":"sk\\u002dfixture"'},
              {'body': r'{"content":"sk\u002dfixture"}', 'truncated': true},
            ],
          },
        },
        secrets: ['sk-fixture'],
      );
    final transport = (logs.records.single['response'] as Map)['transport'] as List;
    for (final entry in transport.cast<Map<String, Object?>>()) {
      final body = entry['body'] as Map;
      expect(body['omitted'], isTrue);
      expect(body.keys.toSet(), {'omitted', 'reason'});
    }
    expect(jsonEncode(logs.records), isNot(contains('fixture')));
  });

  for (final key in const [
    (name: 'plain', value: 'sk-fixture'),
    (name: 'quote', value: 'sk-"fixture'),
    (name: 'backslash', value: r'sk-\fixture'),
  ]) {
    for (final streaming in [false, true]) {
      test(
        'actual escaped HTTP response keeps output while decoded logs remove ${key.name} key: stream=$streaming',
        () async {
          final secret = key.value;
          final root = await Directory.systemTemp.createTemp('dsh-r3-escaped-key-');
          final payload = jsonEncode({
            'ordinary': 'keep',
            'choices': [
              {
                'index': 0,
                if (streaming) 'delta': {'content': 'echo $secret'},
                if (!streaming) 'message': {'content': 'echo $secret'},
                'finish_reason': 'stop',
              },
            ],
          }).replaceAll('sk-', r'sk\u002d');
          final wire = streaming ? 'data: $payload\n\ndata: [DONE]\n\n' : payload;
          var modelSends = 0, keyReads = 0;
          final engine = await TavernEngine.openDirectory(
            root,
            config: TavernModelConfig(
              apiKey: () async {
                keyReads++;
                return secret;
              },
              baseUrl: 'https://model.invalid',
              model: 'fixture',
              deepseek: false,
            ),
            modelClient: TavernModelClient(clientFactory: () => _ResponseClient(utf8.encode(wire), () => modelSends++)),
          );
          addTearDown(() async {
            await engine.close();
            await root.delete(recursive: true);
          });
          await engine.setPreset(ChatPreset(_preset(streaming: streaming)));
          await engine.setSettings({'spresetLogUploadEnabled': true});
          final card = await engine.importCard(t24Card());
          final chat = await engine.createChat(card.id);
          final events = await engine.send(chat, 'question').toList();
          expect(events.whereType<TavernTurnDone>().single.message.text, 'echo $secret');
          expect(modelSends, 1);
          expect(keyReads, 1);
          final report = await engine.exportSPresetLogs(chat);
          String? uploaded;
          var uploads = 0;
          await http.runWithClient(
            () => engine.uploadSPresetLogs(chat),
            () => MockClient((request) async {
              uploads++;
              uploaded = request.body;
              return http.Response('{"id":"uploaded"}', 200);
            }),
          );
          expect(uploads, 1);
          await engine.close();
          final persisted = await File('${root.path}/spreset-generation-logs.json').readAsString();
          for (final text in [jsonEncode(report), persisted, uploaded!]) {
            expect(text, isNot(contains(secret)));
            expect(text, contains('keep'));
            expect(text, contains('[REDACTED]'));
          }
          _expectNoDecodedSecret(report, secret);
          _expectNoDecodedSecret(jsonDecode(persisted), secret);
          _expectNoDecodedSecret(jsonDecode(uploaded!), secret);
        },
      );
    }
  }
}

void _expectNoDecodedSecret(Object? value, String secret) {
  if (value is Map<String, Object?>) {
    for (final entry in value.entries) {
      expect(entry.key, isNot(contains(secret)));
      _expectNoDecodedSecret(entry.value, secret);
    }
    return;
  }
  if (value is List<Object?>) {
    for (final item in value) {
      _expectNoDecodedSecret(item, secret);
    }
    return;
  }
  if (value is! String) return;
  expect(value, isNot(contains(secret)));
  if (value.trimLeft().startsWith('data:')) {
    for (final line in const LineSplitter().convert(value)) {
      if (!line.startsWith('data:')) continue;
      final payload = line.substring(5).trim();
      if (payload == '[DONE]') continue;
      _expectNoDecodedSecret(jsonDecode(payload), secret);
    }
    return;
  }
  Object? decoded;
  try {
    decoded = jsonDecode(value);
  } on FormatException {
    return;
  }
  _expectNoDecodedSecret(decoded, secret);
}

class _LogLoadGate implements File {
  _LogLoadGate(this.path, this.entered, this.release);
  @override
  final String path;
  final Completer<void> entered, release;
  @override
  Future<bool> exists() async {
    entered.complete();
    await release.future;
    return false;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ResponseClient extends http.BaseClient {
  _ResponseClient(this.bytes, this.onSend);
  final List<int> bytes;
  final void Function() onSend;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    onSend();
    return http.StreamedResponse(Stream.fromIterable(bytes.map((byte) => [byte])), 200);
  }
}
