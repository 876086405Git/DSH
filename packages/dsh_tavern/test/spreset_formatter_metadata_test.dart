import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_script_generation_test_support.dart';
import 'spreset_engine_test.dart' show SPresetHost, preset;

void main() {
  final vectors = scriptMap(jsonDecode(File('test/fixtures/spreset/formatter-metadata.json').readAsStringSync()));
  for (final streaming in [false, true]) {
    test('ordinary turn consumes observed signature without executing tools, stream=$streaming', () async {
      final h = await generationFixture();
      final actor = await h.card('Ordinary formatter actor');
      final chat = await h.engine.createChat(actor);
      final host = SPresetHost();
      host.handler = (request) async {
        if (request.stage == 'ToolCallFormatter') {
          final data = scriptMap(request.arguments.single);
          expect(data['channel'], streaming ? 'main' : 'choice:0');
          expect(data['stream'], streaming);
          expect(scriptMap((data['calls']! as List<Object?>).single)['signature'], 'wire-signature');
          return TavernSPresetEvaluationResult(requestId: request.requestId, value: 'formatted');
        }
        return host.defaultEvaluate(request);
      };
      h.bridge.attachHost(host);
      await h.engine.setPreset(
        preset(
          {
            'OutputPreprocessing': {
              'enabled': true,
              'script': 'uppercase',
              'consumeToolCalls': true,
              'toolCallFormatter': {'enabled': true, 'script': 'fixture'},
            },
          },
          stream: streaming,
          calling: true,
        ),
      );
      final message = <String, Object?>{
        'role': 'assistant',
        'content': 'body',
        'tool_calls': [
          {
            'index': 0,
            'id': 'call',
            'type': 'function',
            'signature': 'wire-signature',
            'function': {'name': 'not_authorized', 'arguments': '{"text":"argument"}'},
          },
        ],
      };
      final response = streaming
          ? h.stream()
          : generationJsonResponse(h, {
              'choices': [
                {'index': 0, 'message': message, 'finish_reason': 'tool_calls'},
              ],
            });
      final events = ScriptEvents(h.engine.send(chat, 'question'));
      await events.waitRequest(response);
      if (streaming) {
        await response.listening.future;
        generationSse(response, {
          'choices': [
            {'index': 0, 'delta': message, 'finish_reason': 'tool_calls'},
          ],
        }, splitAt: 7);
        response.finish();
      }
      await events.done.future;
      expect(events.values.whereType<TavernTurnFailed>(), isEmpty);
      expect(events.values.whereType<TavernTurnDone>().single.message.text, 'BODY\nFORMATTED');
      expect(host.actions, 0);
      expect(
        h.inspect((db) => db.select('SELECT COUNT(*) AS n FROM tool_receipts WHERE chat_id = ?', [chat]).single['n']),
        0,
      );
      expect(h.requests, hasLength(1));
    });
  }
  test('stream tool metadata respects disabled ST ToolManager support', () async {
    final h = await generationFixture();
    final actor = await h.card('Tools disabled');
    final context = await h.context(await h.emptyChat(actor), characterId: actor);
    final host = SPresetHost();
    h.bridge.attachHost(host);
    await h.engine.setPreset(
      preset({
        'OutputPreprocessing': {
          'enabled': true,
          'script': 'uppercase',
          'consumeToolCalls': true,
          'toolCallFormatter': {'enabled': true, 'script': 'fixture'},
        },
      }, calling: false),
    );
    final response = h.stream();
    final generation = await h.bridge.generate(
      context.id,
      TavernScriptGenerateRequest(userInput: 'question', stream: true),
    );
    await generationRequest(generation, response);
    await generationSignal(generation, response.listening.future);
    generationSse(response, {
      'choices': [
        {
          'index': 0,
          'delta': {
            'tool_calls': [
              {
                'index': 0,
                'id': 'call',
                'type': 'function',
                'signature': 's',
                'function': {'name': 'look', 'arguments': '{}'},
              },
            ],
          },
          'finish_reason': 'tool_calls',
        },
      ],
    });
    response.finish();
    expect((await generationFailure(generation)).code, TavernScriptErrorCode.unsupportedCapability);
    expect(host.evaluations.where((request) => request.stage == 'ToolCallFormatter'), isEmpty);
    expect(host.actions, 0);
  });
  for (final streaming in [false, true]) {
    final section = streaming ? 'stream' : 'nonstream';
    for (final value in vectors[section]! as List<Object?>) {
      final vector = scriptMap(value);
      test('native SP formatter parsed metadata $section: ${vector['name']}', () async {
        final h = await generationFixture();
        final source = vector['source'] as String? ?? 'openrouter';
        h.config = TavernModelConfig(
          apiKey: () async => 'synthetic-key',
          baseUrl: source == 'openrouter' ? 'https://openrouter.ai/api/v1' : 'https://fixture.invalid/v1',
          model: 'fixture',
          deepseek: false,
          thinking: false,
        );
        await h.reopen();
        final formatter = <Map<String, Object?>>[];
        final host = SPresetHost();
        host.handler = (request) async {
          if (request.stage == 'ToolCallFormatter') {
            final data = scriptMap(request.arguments.single);
            formatter.add(data);
            final calls = (data['calls']! as List<Object?>).map(scriptMap).toList();
            if (calls.any((call) => call['id'] == 'fail')) throw StateError('fixture formatter failure');
            return TavernSPresetEvaluationResult(
              requestId: request.requestId,
              value: '${data['channel']}|${calls.map((call) => '${call['id']}:${call['signature']}').join(',')}',
            );
          }
          if (request.stage == 'OutputPreprocessing') {
            return TavernSPresetEvaluationResult(
              requestId: request.requestId,
              value: scriptMap(request.arguments.single)['chunk'],
            );
          }
          return host.defaultEvaluate(request);
        };
        h.bridge.attachHost(host);
        await h.engine.setPreset(
          preset(
            {
              'OutputPreprocessing': {
                'enabled': true,
                'script': 'echo',
                'consumeToolCalls': true,
                'toolCallFormatter': {'enabled': true, 'script': 'fixture'},
              },
            },
            stream: streaming,
            calling: true,
          ),
        );
        final actor = await h.card('Metadata actor');
        final context = await h.context(await h.emptyChat(actor), characterId: actor, instanceId: 'native-metadata');
        var addedPrimary = false;
        final ScriptResponsePlan response;
        if (streaming) {
          response = h.stream();
        } else {
          final input = scriptMap(jsonDecode(jsonEncode(vector['input'])));
          final choices = input['choices']! as List<Object?>;
          if (!choices.map(scriptMap).any((choice) => choice['index'] == null || choice['index'] == 0)) {
            // Native transport requires a primary choice. Keep the oracle's
            // non-primary formatter input intact and add an unrelated primary.
            choices.insert(0, {
              'index': 0,
              'message': {'role': 'assistant', 'content': 'primary'},
              'finish_reason': 'stop',
            });
            addedPrimary = true;
          }
          response = generationJsonResponse(h, input);
        }
        final generation = await h.bridge.generate(
          context.id,
          TavernScriptGenerateRequest(userInput: 'question', stream: streaming),
        );
        await generationRequest(generation, response);
        if (streaming) {
          await generationSignal(generation, response.listening.future);
          for (final frame in vector['frames']! as List<Object?>) {
            generationSse(response, scriptMap(frame), splitAt: 7);
          }
          generationSse(response, {
            'choices': [
              {'index': 0, 'delta': <String, Object?>{}, 'finish_reason': 'tool_calls'},
            ],
          });
          response.finish();
        }
        final expectedCalls = vector['formatter']! as List<Object?>;
        final restoresCalls = vector['failed'] == true || (streaming && expectedCalls.isEmpty);
        if (restoresCalls) {
          final failure = await generationFailure(generation);
          expect(
            failure.code,
            TavernScriptErrorCode.unsupportedCapability,
            reason: 'Restored native background calls keep their existing unsupported action boundary.',
          );
        } else {
          final result = await generation.result;
          final expectedText = streaming
              ? vector['result']
              : addedPrimary
              ? 'primary'
              : scriptMap(
                  scriptMap((scriptMap(vector['result'])['choices']! as List<Object?>).first)['message'],
                )['content'];
          expect(
            result.text,
            expectedText is List<Object?>
                ? expectedText.map((part) => scriptMap(part)['text']).where((text) => text != null && text != '').join()
                : expectedText,
          );
        }
        expect(formatter, expectedCalls);
        expect(host.actions, 0);
        expect(h.requests, hasLength(1));
      });
    }
  }
}
