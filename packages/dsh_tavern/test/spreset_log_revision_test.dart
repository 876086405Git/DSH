import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart';

Map<String, Object?> logPreset({bool streaming = true, bool outputProcessing = false, String? name, String? url}) => {
  ...t24Preset().raw,
  'stream_openai': streaming,
  'name': ?name,
  'extensions': {
    'SPreset': {
      'LogUpload': {'enabled': true, 'url': ?url},
      if (outputProcessing) 'OutputPreprocessing': {'enabled': true, 'script': 'ctx => ctx.chunk'},
    },
  },
};

void main() {
  test('generation diagnostics are detached and bounded during collection', () {
    final logs = SPresetScriptLogBuffer();
    final argument = <String, Object?>{'authToken': 'secret', 'value': 'before'};
    logs.add({
      'arguments': [argument],
    }, upstreamDropped: 3);
    argument['value'] = 'after';
    expect(jsonEncode(logs.records), contains('before'));
    expect(jsonEncode(logs.records), isNot(contains('secret')));
    for (var i = 1; i < 601; i++) {
      logs.add({'index': i});
    }
    expect(logs.records, hasLength(500));
    expect(logs.dropped, 101);
    expect(logs.consoleDropped, 3);
    for (var i = 0; i < 100; i++) {
      logs.add({'result': List.filled(60, 'x' * 8000)});
    }
    final retainedChars = logs.records.fold<int>(0, (sum, item) => sum + jsonEncode(item).length);
    expect(retainedChars, lessThanOrEqualTo(512 * 1024));
    expect(logs.records.every((item) => jsonEncode(item).length <= 65536), isTrue);
    expect(logs.truncatedValues, greaterThan(0));
    expect(logs.dropped, greaterThan(101));
    final adversarial = SPresetScriptLogBuffer()
      ..add({'result': '{"authToken":"CUT_SECRET_${'x' * 10000}"}'})
      ..add({'result': '${'x' * 8187}synthetic-key'}, secrets: ['synthetic-key']);
    final safe = jsonEncode(adversarial.records);
    expect(safe, isNot(contains('CUT_SECRET_')));
    expect(safe, isNot(contains('synth')));
    expect(adversarial.truncatedValues, 2);
    final decoded = SPresetLogBuffer()
      ..add(
        {
          'response': {'text': r'{"synthetic\u002dkey":"synthetic\u002dkey"}'},
        },
        secrets: ['synthetic-key'],
      );
    expect(jsonEncode(decoded.records), isNot(contains('synthetic-key')));
  });

  test('structured raw JSON and multiline SSE are redacted; malformed bodies are omitted', () {
    final json = redactSPresetResponseBody('{"password":"raw-secret","nested":{"authToken":"token-secret"}}');
    expect(json, {
      'password': '[REDACTED]',
      'nested': {'authToken': '[REDACTED]'},
    });
    final sse = redactSPresetResponseBody(
      ': private comment\r\ndata: {"password":\r\ndata: "raw-secret","ok":1}\r\n\r\ndata: [DONE]\r\n\r\n',
    );
    expect(sse, 'data: {"password":"[REDACTED]","ok":1}\n\ndata: [DONE]\n\n');
    for (final text in ['unstructured secret', 'data: {"password":"raw-secret"', '{"password":"raw-secret"']) {
      expect(redactSPresetResponseBody(text), containsPair('omitted', true));
    }
    expect(redactSPresetResponseBody('{"password":"raw-secret"}', truncated: true), containsPair('omitted', true));
    final restored = SPresetLogBuffer()
      ..restore([
        {
          'id': 'old',
          'status': 'pending',
          'response': {
            'transport': [
              {'body': '{"password":"old-secret"}'},
            ],
          },
        },
      ]);
    expect(jsonEncode(restored.records), isNot(contains('old-secret')));
    expect(restored.records.single['status'], 'interrupted');
  });

  test('authToken, embedded JSON and inline Bearer/Basic share structured redaction', () {
    final input = {
      'authToken': 'map-secret',
      'json': r'{"authToken":"json-secret","password":"p\"secret"}',
      'embedded': 'prefix {"authToken":"embedded-secret"} suffix',
      'text': 'prefix Bearer inline-token suffix; Basic YWJjOnBhc3M=\nBearer standalone-token',
    };
    final clean = redactSPresetLogValue(input)! as Map<String, Object?>;
    final encoded = jsonEncode(clean);
    expect(clean['json'], isA<String>());
    expect((jsonDecode(clean['json']! as String) as Map)['authToken'], '[REDACTED]');
    for (final secret in [
      'map-secret',
      'json-secret',
      'embedded-secret',
      'inline-token',
      'YWJjOnBhc3M=',
      'standalone-token',
    ]) {
      expect(encoded, isNot(contains(secret)));
    }
    expect(encoded, contains('prefix'));
    expect(encoded, contains('suffix'));
    expect(input['authToken'], 'map-secret');
  });

  test('manual log upload only admits HTTPS without URL credentials', () async {
    var sends = 0;
    final client = MockClient((request) async {
      sends++;
      expect(request.url.scheme, 'https');
      expect(request.headers['Authorization'], 'Bearer upload-secret');
      expect(request.body, isNot(contains('upload-secret')));
      return http.Response('{"id":"ok"}', 200);
    });
    addTearDown(client.close);
    for (final url in [
      'http://fixture.invalid/upload',
      'https://user:pass@fixture.invalid/upload',
      'file:///tmp/log',
    ]) {
      await expectLater(
        uploadSPresetLogReport(Uri.parse(url), {}, enabled: true, client: client),
        throwsA(isA<SPresetException>()),
      );
    }
    expect(sends, 0);
    await uploadSPresetLogReport(
      Uri.parse('https://fixture.invalid/upload'),
      {'records': []},
      enabled: true,
      bearerToken: 'upload-secret',
      client: client,
    );
    expect(sends, 1);
  });

  test('chat writes cannot grant or revoke the global log opt-in', () async {
    final h = await T24Harness.open();
    addTearDown(h.dispose);
    for (final value in [true, false, null]) {
      await expectLater(
        h.engine.setSettings({'spresetLogUploadEnabled': value}, chatId: h.chatId),
        throwsArgumentError,
      );
    }
    await h.engine.setSettings({'spresetLogUploadEnabled': true});
    expect(h.engine.settings(chatId: h.chatId)['spresetLogUploadEnabled'], isTrue);
  });

  for (final global in [false, true]) {
    test('legacy chat log setting is ignored when global=$global', () async {
      final h = await T24Harness.open();
      addTearDown(h.dispose);
      await h.engine.setPreset(ChatPreset(logPreset()));
      await h.engine.setSettings({'spresetLogUploadEnabled': global});
      await h.engine.close();
      final db = sqlite3.open('${h.root.path}/tavern.sqlite3');
      db.execute('UPDATE chats SET settings = ? WHERE id = ?', [
        jsonEncode({'spresetLogUploadEnabled': !global}),
        h.chatId,
      ]);
      db.close();
      await h.reopen();
      expect(h.engine.settings(chatId: h.chatId)['spresetLogUploadEnabled'], global);
      await h.reply('answer');
      expect((await h.engine.exportSPresetLogs(h.chatId))['records'], hasLength(global ? 1 : 0));
    });
  }

  test('upload captures target and preset name before asynchronous log loading', () async {
    final h = await T24Harness.open();
    addTearDown(h.dispose);
    final a = await h.engine.importPreset(
      jsonEncode(logPreset(name: 'Preset A', url: 'https://a.invalid/upload')),
      fileName: 'Preset A.json',
    );
    final b = await h.engine.importPreset(
      jsonEncode(logPreset(name: 'Preset B', url: 'https://b.invalid/upload')),
      fileName: 'Preset B.json',
    );
    await h.engine.bindPreset(h.chatId, a.preset.id);
    await h.engine.setSettings({'spresetLogUploadEnabled': true});
    final entered = Completer<void>(), release = Completer<void>();
    late http.Request uploaded;
    final pending = IOOverrides.runZoned(
      () => http.runWithClient(
        () => h.engine.uploadSPresetLogs(h.chatId),
        () => MockClient((request) async {
          uploaded = request;
          return http.Response('{"id":"ok"}', 200);
        }),
      ),
      createFile: (path) {
        expect(path, endsWith('spreset-generation-logs.json'));
        return _LogLoadGate(entered, release);
      },
    );
    await entered.future;
    await h.engine.bindPreset(h.chatId, b.preset.id);
    release.complete();
    await pending;
    expect(uploaded.url.host, 'a.invalid');
    expect((jsonDecode(uploaded.body) as Map)['client']['presetName'], 'Preset A');
  });

  test('closing the global opt-in during log loading still settles the pending response', () async {
    final h = await T24Harness.open();
    addTearDown(h.dispose);
    await h.engine.setPreset(ChatPreset(logPreset()));
    await h.engine.setSettings({'spresetLogUploadEnabled': true});
    final entered = Completer<void>(), release = Completer<void>();
    final call = h.model.prepare();
    final events = IOOverrides.runZoned(
      () => T24Events(h.engine.send(h.chatId, 'question')),
      createFile: (path) => path.endsWith('spreset-generation-logs.json')
          ? _LogLoadGate(entered, release, path)
          : Zone.root.run(() => File(path)),
    );
    await entered.future;
    await h.engine.setSettings({'spresetLogUploadEnabled': false});
    release.complete();
    await call.listening.future;
    call.add(const ModelText('after opt-out'));
    await call.finish();
    await events.done.future;
    await h.engine.close();
    final records = jsonDecode(await File('${h.root.path}/spreset-generation-logs.json').readAsString()) as List;
    expect(records, hasLength(1));
    expect((records.single as Map)['status'], 'logging_disabled');
    expect((records.single as Map)['response'], containsPair('omitted', true));
    expect(jsonEncode(records), isNot(contains('after opt-out')));
  });

  for (final streaming in [false, true]) {
    for (final disableWhileKeyPending in [false, true]) {
      test('actual HTTP log key redaction, stream=$streaming disableWhileKeyPending=$disableWhileKeyPending', () async {
        const secret = 'configured-key-猫';
        var keyReads = 0;
        final keyEntered = Completer<void>(), keyReady = Completer<void>();
        final root = await Directory.systemTemp.createTemp('dsh-log-redaction-');
        final wire = streaming
            ? 'data: ${jsonEncode({
                'password': 'field-secret',
                'authToken': 'token-secret',
                'choices': [
                  {
                    'index': 0,
                    'delta': {'content': 'echo $secret'},
                  },
                ],
              })}\n\ndata: ${jsonEncode({
                'choices': [
                  {'index': 0, 'delta': {}, 'finish_reason': 'stop'},
                ],
              })}\n\ndata: [DONE]\n\n'
            : jsonEncode({
                'password': 'field-secret',
                'authToken': 'token-secret',
                'choices': [
                  {
                    'message': {'content': 'echo $secret'},
                    'finish_reason': 'stop',
                  },
                ],
              });
        final model = TavernModelClient(clientFactory: () => _ResponseClient(utf8.encode(wire)));
        final engine = await TavernEngine.openDirectory(
          root,
          config: TavernModelConfig(
            apiKey: () async {
              keyReads++;
              if (disableWhileKeyPending) {
                keyEntered.complete();
                await keyReady.future;
              }
              return secret;
            },
            deepseek: false,
            baseUrl: 'https://fixture.invalid',
            model: 'fixture',
          ),
          modelClient: model,
        );
        addTearDown(() async {
          await engine.close();
          await root.delete(recursive: true);
        });
        final outputProcessing = disableWhileKeyPending && streaming;
        if (outputProcessing) engine.scripts.attachHost(_LogEchoHost());
        await engine.setPreset(ChatPreset(logPreset(streaming: streaming, outputProcessing: outputProcessing)));
        await engine.setSettings({'spresetLogUploadEnabled': true});
        final card = await engine.importCard(t24Card());
        final chat = await engine.createChat(card.id);
        final pending = engine.send(chat, 'question').toList();
        if (disableWhileKeyPending) {
          await keyEntered.future;
          await engine.setSettings({'spresetLogUploadEnabled': false});
          keyReady.complete();
        }
        final events = await pending;
        expect(events.whereType<TavernTurnDone>().single.message.text, 'echo $secret');
        expect(keyReads, 1);
        final report = jsonEncode(await engine.exportSPresetLogs(chat));
        await engine.close();
        final persisted = await File('${root.path}/spreset-generation-logs.json').readAsString();
        final saved = jsonDecode(persisted) as List;
        expect(saved, hasLength(1));
        expect((saved.single as Map)['response'], isNotNull);
        for (final value in [secret, 'field-secret', 'token-secret']) {
          expect(report, isNot(contains(value)));
          expect(persisted, isNot(contains(value)));
        }
        if (disableWhileKeyPending) {
          expect((saved.single as Map)['status'], 'logging_disabled');
          expect((saved.single as Map)['response'], containsPair('omitted', true));
        } else {
          expect(persisted, contains('[REDACTED]'));
        }
      });
    }
  }
}

class _LogLoadGate implements File {
  _LogLoadGate(this.entered, this.release, [this.path = 'spreset-generation-logs.json']);
  final Completer<void> entered, release;
  @override
  final String path;
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
  _ResponseClient(this.bytes);
  final List<int> bytes;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async => http.StreamedResponse(
    Stream.fromIterable(bytes.map((byte) => [byte])),
    200,
    headers: {'content-type': 'application/json'},
  );
}

class _LogEchoHost implements TavernScriptHost, TavernSPresetScriptHost {
  @override
  Future<TavernSPresetEvaluationResult> evaluateSPreset(
    TavernSPresetEvaluationRequest request,
    TavernScriptCancellation cancellation,
  ) async => TavernSPresetEvaluationResult(
    requestId: request.requestId,
    value: switch (request.kind) {
      TavernSPresetEvaluationKind.validateFunctionExpression => true,
      TavernSPresetEvaluationKind.toolRegistry => {
        'registryMode': (request.arguments.single! as Map<String, Object?>)['registryMode'] ?? 'sync',
        'registryModes': ['sync', 'read', 'refresh'],
        'tools': <Object?>[],
      },
      _ => (request.arguments.first as Map)['chunk'],
    },
    arguments: request.arguments,
  );
  @override
  Future<void> releaseSPresetSession(String sessionId) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
