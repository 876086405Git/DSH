import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_script_generation_test_support.dart';
import 'spreset_engine_test.dart' show SPresetHost;

void main() {
  test('reused public Helper generation IDs retain separate completed log records', () async {
    final h = await generationFixture();
    final setup = await _setup(h);
    for (final text in ['first answer', 'second answer']) {
      final response = h.reply(text);
      final generation = await h.bridge.generateRaw(setup.contextId, _request());
      await generationRequest(generation, response);
      expect((await generation.result).text, text);
    }
    await h.engine.close();
    final records = jsonDecode(await File('${h.root.path}/spreset-generation-logs.json').readAsString()) as List;
    expect(records, hasLength(2));
    expect(records.map((record) => (record as Map)['id']).toSet(), hasLength(2));
    expect(records.map((record) => (record as Map)['status']), everyElement('completed'));
    expect(records.map((record) => (record as Map)['generationId']), everyElement('reused-helper-id'));
    expect(records.map((record) => ((record as Map)['response'] as Map)['text']), ['first answer', 'second answer']);
  });

  test('Helper nonstream fetch consumption settles its registered log after opt-out during key resolution', () async {
    final h = await generationFixture();
    final setup = await _setup(h, consume: true);
    const secret = 'helper-synthetic-secret';
    final entered = Completer<void>(), ready = Completer<void>();
    addTearDown(() {
      if (!ready.isCompleted) ready.complete();
    });
    var reads = 0;
    h.engine.configure(
      TavernModelConfig(
        apiKey: () async {
          reads++;
          entered.complete();
          await ready.future;
          return secret;
        },
        baseUrl: h.config.baseUrl,
        model: h.config.model,
        deepseek: false,
      ),
    );
    final response = h.reply('echo $secret');
    final generation = await h.bridge.generateRaw(setup.contextId, _request());
    await generationSignal(generation, entered.future);
    await h.engine.setSettings({'spresetLogUploadEnabled': false});
    ready.complete();
    await generationRequest(generation, response);
    expect((await generation.result).text, 'echo $secret');
    expect(reads, 1);
    final exported = await h.engine.exportSPresetLogs(setup.chatId);
    final report = jsonEncode(exported);
    await h.engine.close();
    final logFile = File('${h.root.path}/spreset-generation-logs.json');
    expect(await logFile.exists(), isTrue, reason: 'Closing must drain the registered Helper response log.');
    final persisted = await logFile.readAsString();
    final records = jsonDecode(persisted) as List;
    expect(records, hasLength(1));
    expect((records.single as Map)['status'], 'logging_disabled');
    expect((records.single as Map)['response'], containsPair('omitted', true));
    expect(report, isNot(contains(secret)));
    expect(persisted, isNot(contains(secret)));
  });
}

TavernHelperRawRequest _request() => TavernHelperRawRequest.fromJson({
  'generation_id': 'reused-helper-id',
  'should_stream': false,
  'ordered_prompts': [
    {'role': 'user', 'content': 'Q'},
  ],
});

Future<({String contextId, String chatId})> _setup(ScriptFixture h, {bool consume = false}) async {
  h.bridge.attachHost(SPresetHost());
  await h.engine.setPreset(
    ChatPreset({
      ...scriptPreset().raw,
      'extensions': {
        'SPreset': {
          'LogUpload': {'enabled': true},
          if (consume)
            'OutputPreprocessing': {'enabled': true, 'consumeToolCalls': true, 'script': 'synthetic-validator'},
        },
      },
    }),
  );
  await h.engine.setSettings({'spresetLogUploadEnabled': true});
  final card = await h.card('Helper log scope');
  final chatId = await h.emptyChat(card);
  final context = await h.context(chatId, characterId: card);
  return (contextId: context.id, chatId: chatId);
}
