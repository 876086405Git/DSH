import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_script_generation_test_support.dart';

const _url = 'https://fixture.invalid/image.png';
const _png = 'data:image/png;base64,AA==';

int _imageCount(ScriptRequest request) => generationMessages(request).fold(
  0,
  (count, row) =>
      count +
      (row['content'] is List<Object?>
          ? (row['content']! as List<Object?>)
                .whereType<ScriptJson>()
                .where((part) => part['type'] == 'image_url')
                .length
          : 0),
);

void main() {
  final fixture = jsonDecode(File('test/fixtures/w11_helper_image_paths.json').readAsStringSync()) as ScriptJson;
  for (final row in (fixture['paths']! as List<Object?>).cast<ScriptJson>()) {
    test('Helper image source path: ${row['name']}', () async {
      final h = await generationFixture();
      await h.engine.setPreset(
        ChatPreset({...scriptPreset().raw, 'new_chat_prompt': '', 'send_if_empty': '', 'media_inlining': row['media']}),
      );
      final host = _ImageHost();
      h.bridge.attachHost(host);
      final actor = await h.card('Image fixture');
      final context = await h.context(await h.emptyChat(actor), characterId: actor);
      final json = <String, Object?>{
        'user_input': 'Q',
        'should_silence': true,
        if (row['image'] != null)
          'image': switch (row['image']) {
            'array' => [_url],
            'data' => _png,
            _ => _url,
          },
        if (row.containsKey('order')) 'ordered_prompts': row['order'],
        'overrides': {
          'chat_history': {
            'with_depth_entries': false,
            'prompts': [
              if (row['filtered'] != true)
                {'role': 'user', 'content': 'H', if (row['historyImage'] == true) 'image': _url},
            ],
          },
        },
      };
      final response = h.reply('A');
      final generation = row['mode'] == 'normal'
          ? await h.bridge.generate(context.id, TavernHelperGenerateRequest.fromJson(json))
          : await h.bridge.generateRaw(context.id, TavernHelperRawRequest.fromJson(json));
      final wire = await generationRequest(generation, response);
      expect((await generation.result).text, 'A');
      expect(host.resolved, List.filled(row['resolverCalls']! as int, _url));
      expect(_imageCount(wire), row['sentImages']);
    });
  }

  for (final row in (fixture['gates']! as List<Object?>).cast<ScriptJson>()) {
    if (row['mainApi'] != null) continue;
    test('Helper image provider gate: ${row['name']}', () async {
      final h = await generationFixture();
      final source = row['source']! as String;
      final model = row['model'] as String? ?? 'fixture-custom';
      h.config = TavernModelConfig(
        apiKey: () async => 'fixture-key',
        baseUrl: switch (source) {
          'openai' => 'https://api.openai.com/v1',
          'deepseek' => 'https://api.deepseek.com',
          'openrouter' => 'https://openrouter.ai/api/v1',
          _ => 'https://fixture.invalid/v1',
        },
        model: model,
        deepseek: source == 'deepseek',
        thinking: true,
      );
      await h.reopen();
      await h.engine.setPreset(
        ChatPreset({...scriptPreset().raw, 'new_chat_prompt': '', 'send_if_empty': '', 'media_inlining': row['media']}),
      );
      final host = _CatalogHost(row['catalog']);
      h.bridge.attachHost(host);
      final context = await h.bridge.openContext(const TavernScriptContextSpec(instanceId: 'image-catalog'));
      final response = h.reply('A');
      final generation = await h.bridge.generateRaw(
        context.id,
        TavernHelperRawRequest.fromJson({
          'user_input': 'Q',
          'image': _url,
          'ordered_prompts': ['chat_history'],
          'overrides': {
            'chat_history': {
              'with_depth_entries': false,
              'prompts': [
                {'role': 'user', 'content': 'H'},
              ],
            },
          },
          // The capability must still describe the current main connection.
          'custom_api': {'source': 'custom', 'apiurl': 'https://request.invalid/v1', 'model': 'request-model'},
        }),
      );
      final wire = await generationRequest(generation, response);
      await generation.result;
      expect(wire.url.host, 'request.invalid');
      expect(wire.body['model'], 'request-model');
      expect(host.resolved, [_url], reason: 'The top single resolves before the history gate.');
      expect(_imageCount(wire), row['expected'] == true ? 1 : 0);
      if (source == 'openrouter' && row['media'] == true) {
        expect(host.capabilities, hasLength(1));
        final request = host.capabilities.single;
        expect(request.source, source);
        expect(request.model, model);
        expect(request.contextId, context.id);
        expect(request.chatId, isNull);
        expect(request.generationId, generation.id);
      } else {
        expect(host.capabilities, isEmpty);
      }
    });
  }

  test('Helper OpenRouter demands catalog only for consumed history images', () async {
    final h = await generationFixture();
    h.config = TavernModelConfig(
      apiKey: () async => 'fixture-key',
      baseUrl: 'https://openrouter.ai/api/v1',
      model: 'fixture/model',
      deepseek: false,
      thinking: false,
    );
    await h.reopen();
    final host = _ImageHost();
    h.bridge.attachHost(host);
    final context = await h.bridge.openContext(const TavernScriptContextSpec(instanceId: 'no-catalog'));
    for (final inputSlot in [false, true]) {
      final response = inputSlot ? h.reply('A') : null;
      final generation = await h.bridge.generateRaw(
        context.id,
        TavernHelperRawRequest.fromJson({
          'user_input': 'Q',
          'image': _url,
          'ordered_prompts': [inputSlot ? 'user_input' : 'chat_history'],
          'overrides': {
            'chat_history': {
              'with_depth_entries': false,
              'prompts': [
                {'role': 'user', 'content': 'H'},
              ],
            },
          },
        }),
      );
      if (response == null) {
        final failure = await generationFailure(generation);
        expect(failure.code, TavernScriptErrorCode.unsupportedCapability);
        expect(failure.fieldPath, 'image');
        expect(h.requests, isEmpty);
      } else {
        final wire = await generationRequest(generation, response);
        await generation.result;
        expect(_imageCount(wire), 1);
      }
    }
    expect(host.resolved, [_url, _url]);
  });
}

class _ImageHost extends ScriptHost implements TavernHelperImageHost {
  final resolved = <String>[];
  @override
  Future<String> resolveHelperImage(String source, TavernScriptCancellation cancellation) async {
    resolved.add(source);
    if (cancellation.isCancelled) throw StateError('Cancelled synthetic image resolver.');
    return _png;
  }
}

class _CatalogHost extends _ImageHost implements TavernHelperImageCapabilityHost {
  _CatalogHost(this.catalog);
  final Object? catalog;
  final capabilities = <TavernHelperImageCapabilityRequest>[];
  @override
  Future<bool> supportsHelperModelImages(
    TavernHelperImageCapabilityRequest request,
    TavernScriptCancellation cancellation,
  ) async {
    capabilities.add(request);
    if (catalog is! List<Object?>) return false;
    for (final row in (catalog! as List<Object?>).cast<ScriptJson>()) {
      if (row['id'] != request.model) continue;
      return (scriptMap(row['architecture'])['input_modalities'] as List<Object?>?)?.contains('image') ?? false;
    }
    return false;
  }
}
