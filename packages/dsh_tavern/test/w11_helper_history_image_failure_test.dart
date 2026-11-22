// Fixed ST addImage changes the content shape before its caught network/base64 failure.
import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_script_generation_test_support.dart';

const _image = 'https://fixture.invalid/history.png';

void main() {
  final oracle =
      jsonDecode(File('test/fixtures/w11_helper_history_image_failure_source.json').readAsStringSync()) as ScriptJson;
  final rows = (oracle['rows']! as List<Object?>).cast<ScriptJson>();
  for (final history in [true, false]) {
    for (final stage in TavernHelperImageConversionStage.values) {
      final path = history ? 'raw-history-image' : 'top-level-single-image';
      test('$path ${stage.name} failure retains its actual source content shape', () async {
        final h = await generationFixture();
        await h.engine.setPreset(_preset());
        final host = _FailingImageHost(stage);
        h.bridge.attachHost(host);
        final context = await h.bridge.openContext(TavernScriptContextSpec(instanceId: '$path-${stage.name}'));
        final plan = h.reply('MODEL');
        final generation = await h.bridge.generateRaw(context.id, _request(history: history));
        final request = await generationRequest(generation, plan);
        final result = await generation.result;
        expect(result.text, 'MODEL');
        expect(host.sources, [_image]);
        final expected = rows.singleWhere((row) => row['path'] == path && row['stage'] == stage.name);
        expect(generationMessages(request), [
          {'role': 'user', 'content': expected['content']},
        ]);
        final issue = result.hookIssues.singleWhere((issue) => issue.code == 'helperImageConversionFailed');
        expect(issue.details['conversionStage'], stage.name);
      });
    }
  }

  test('failed history image keeps the pre-image text charge at the exact raw budget boundary', () async {
    final h = await generationFixture();
    const counter = EstimatedTokenCounter();
    const text = <String, Object?>{'role': 'user', 'content': 'H'};
    final textCost = counter.countMessage(text);
    await h.engine.setPreset(_preset(context: 1 + 3 + textCost));
    final host = _FailingImageHost(TavernHelperImageConversionStage.download);
    h.bridge.attachHost(host);
    final context = await h.bridge.openContext(const TavernScriptContextSpec(instanceId: 'history-image-budget'));
    final plan = h.reply('MODEL');
    final generation = await h.bridge.generateRaw(context.id, _request(history: true));
    final request = await generationRequest(generation, plan);
    expect((await generation.result).text, 'MODEL');
    expect(host.sources, [_image]);
    expect(generationMessages(request), [
      {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': 'H'},
        ],
      },
    ]);
  });

  test('history media gate off leaves text unconverted and never calls the resolver', () async {
    final h = await generationFixture();
    await h.engine.setPreset(ChatPreset({..._preset().raw, 'media_inlining': false}));
    final host = _FailingImageHost(TavernHelperImageConversionStage.download);
    h.bridge.attachHost(host);
    final context = await h.bridge.openContext(const TavernScriptContextSpec(instanceId: 'history-image-gate'));
    final plan = h.reply('MODEL');
    final generation = await h.bridge.generateRaw(context.id, _request(history: true));
    final request = await generationRequest(generation, plan);
    expect((await generation.result).text, 'MODEL');
    expect(host.sources, isEmpty);
    expect(generationMessages(request), [
      {'role': 'user', 'content': 'H'},
    ]);
  });
}

ChatPreset _preset({int context = 8192}) => ChatPreset({
  ...scriptPreset().raw,
  'media_inlining': true,
  'new_chat_prompt': '',
  'send_if_empty': '',
  'openai_max_context': context,
  'openai_max_tokens': 1,
});

TavernHelperRawRequest _request({required bool history}) => TavernHelperRawRequest.fromJson({
  if (!history) 'user_input': 'H',
  if (!history) 'image': _image,
  'ordered_prompts': [history ? 'chat_history' : 'user_input'],
  'overrides': {
    'chat_history': {
      'with_depth_entries': false,
      'prompts': [
        if (history) {'role': 'user', 'content': 'H', 'image': _image},
      ],
    },
  },
});

class _FailingImageHost extends GenerationHost implements TavernHelperImageHost {
  _FailingImageHost(this.stage);
  final TavernHelperImageConversionStage stage;
  final sources = <String>[];

  @override
  Future<String> resolveHelperImage(String source, TavernScriptCancellation cancellation) async {
    sources.add(source);
    throw TavernHelperImageConversionFailure(stage: stage, message: 'Synthetic ${stage.name} failure.');
  }
}
