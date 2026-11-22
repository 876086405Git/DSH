import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_script_generation_test_support.dart';

const _image = 'data:image/png;base64,AQ==';
const _url = 'https://fixture.invalid/image.png';
const _failed = 'https://fixture.invalid/failure.png';

void main() {
  final oracle =
      jsonDecode(File('test/fixtures/w11_helper_history_array_coercion_source.json').readAsStringSync()) as ScriptJson;
  for (final (index, row) in (oracle['results']! as List<Object?>).cast<ScriptJson>().indexed) {
    test('fixed history-array coercion $index: ${row['modern']} ${row['kind']} ${row['explicitInput']}', () async {
      final h = await generationFixture();
      await h.engine.setSettings({'macroEngine': row['modern'] == true ? 'modern' : 'legacy'});
      await h.engine.setPreset(
        ChatPreset({...scriptPreset().raw, 'new_chat_prompt': '', 'send_if_empty': '', 'media_inlining': true}),
      );
      final card = await h.card('History array coercion');
      final chat = await h.emptyChat(card);
      final host = _ImageHost((source, cancellation) async {
        throw const TavernHelperImageConversionFailure(
          stage: TavernHelperImageConversionStage.download,
          message: 'Controlled download failure.',
        );
      });
      h.bridge.attachHost(host);
      final context = await h.context(chat, characterId: card, instanceId: 'coercion-$index');
      final kind = row['kind']! as String;
      final explicitInput = row['explicitInput'] == true;
      final filtered = row['filteredHistory'] == true;
      final coerced = !explicitInput && !filtered && (kind == 'array' || kind == 'failedArray');
      final plan = h.reply('MODEL');
      final generation = await h.bridge.generateRaw(
        context.id,
        TavernHelperRawRequest.fromJson({
          if (row['inputPresent'] == true) 'user_input': row['input'],
          if (kind != 'plain')
            'image': kind == 'failedSingle'
                ? _failed
                : [if (kind != 'emptyArray') kind == 'failedArray' ? _failed : _image],
          'ordered_prompts': [explicitInput ? 'user_input' : 'chat_history'],
          'overrides': {
            'chat_history': {'with_depth_entries': false, if (filtered) 'prompts': <Object?>[]},
          },
        }),
      );
      final wire = await generationRequest(generation, plan);
      final result = await generation.result;
      expect(result.text, 'MODEL');
      expect(h.requests, hasLength(1));
      expect(wire.body['messages'], row['wireMessages']);
      expect(host.sources, kind == 'failedArray' || kind == 'failedSingle' ? [_failed] : isEmpty);
      expect(
        result.hookIssues.where((issue) => issue.code == 'helperImageConversionFailed'),
        hasLength(kind == 'failedArray' || kind == 'failedSingle' ? 1 : 0),
      );
      expect(
        result.hookIssues.where((issue) => issue.code == 'helperHistoryImageArrayCoerced'),
        hasLength(coerced ? 1 : 0),
      );
    });
  }

  for (final modern in [false, true]) {
    test('history array keeps actual ${modern ? 'modern' : 'legacy'} macro effects around conversion', () async {
      final h = await generationFixture();
      final trace = <String>[];
      var macroCalls = 0;
      h.onRandom = () => trace.add('macro${++macroCalls}');
      await h.engine.setSettings({'macroEngine': modern ? 'modern' : 'legacy'});
      await h.engine.setPreset(
        ChatPreset({...scriptPreset().raw, 'new_chat_prompt': '', 'send_if_empty': '', 'media_inlining': true}),
      );
      final card = await h.card('History array macro phases');
      final chat = await h.emptyChat(card);
      final context = await h.context(chat, characterId: card);
      await h.bridge.replaceVariables(context.id, scriptGlobal, {'phase': 0});
      final host = _ImageHost((source, cancellation) async {
        trace.add('resolve');
        expect(macroCalls, 1, reason: 'Input macros precede array conversion; depth macros follow it.');
        return _image;
      });
      h.bridge.attachHost(host);
      final plan = h.reply('MODEL');
      final generation = await h.bridge.generateRaw(
        context.id,
        TavernHelperRawRequest.fromJson({
          'user_input': 'Q{{incglobalvar::phase}}{{random::A::B}}',
          'image': [_url],
          'ordered_prompts': ['chat_history'],
          'overrides': {
            'chat_history': {'with_depth_entries': false},
          },
          'injects': [
            {'role': 'system', 'content': 'I{{incglobalvar::phase}}{{random::C::D}}', 'depth': 0},
          ],
        }),
      );
      final wire = await generationRequest(generation, plan);
      final result = await generation.result;
      expect(result.text, 'MODEL');
      expect(wire.body['messages'], [
        {'role': 'user', 'content': '[object Object],[object Object]'},
        {'role': 'system', 'content': 'I2C'},
      ]);
      expect(trace, ['macro1', 'resolve', 'macro2']);
      expect((await h.bridge.getVariables(context.id, scriptGlobal)).value['phase'], 2);
      expect(host.sources, [_url]);
      expect(result.hookIssues.where((issue) => issue.code == 'helperHistoryImageArrayCoerced'), hasLength(1));
      expect(generationNodes(h, chat), isEmpty);
    });
  }

  test('existing DTO distinguishes omitted and empty image arrays from null or empty strings', () {
    expect(
      TavernHelperRawRequest.fromJson({
        'ordered_prompts': ['chat_history'],
      }).helperOptions.images,
      isEmpty,
    );
    expect(
      TavernHelperRawRequest.fromJson({
        'image': [],
        'ordered_prompts': ['chat_history'],
      }).helperOptions.images,
      isEmpty,
    );
    for (final raw in [
      {'image': null},
      {'image': ''},
      {'user_input': null},
      {
        'overrides': {
          'chat_history': {'prompts': null},
        },
      },
    ]) {
      expect(() => TavernHelperRawRequest.fromJson(raw), throwsA(isA<TavernScriptException>()));
    }
  });
}

class _ImageHost extends GenerationHost implements TavernHelperImageHost {
  _ImageHost(this.handler);
  final Future<String> Function(String, TavernScriptCancellation) handler;
  final sources = <String>[];
  @override
  Future<String> resolveHelperImage(String source, TavernScriptCancellation cancellation) {
    sources.add(source);
    return handler(source, cancellation);
  }
}
