// Fixed Helper raw Message.createAsync parts admission, with its original plain reserve.
import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_script_generation_test_support.dart';

const _image = 'data:image/png;base64,AQ==';
const _failedImage = 'https://fixture.invalid/failure.png';
const _plain = <String, Object?>{'role': 'user', 'content': 'Q'};
const _parts = <String, Object?>{
  'role': 'user',
  'content': [
    {'type': 'text', 'text': 'Q'},
    {
      'type': 'image_url',
      'image_url': {'url': _image, 'detail': 'low'},
    },
  ],
};

void main() {
  final oracle =
      jsonDecode(File('test/fixtures/w11_helper_raw_array_admission_source.json').readAsStringSync()) as ScriptJson;
  const counter = EstimatedTokenCounter();
  for (final row in (oracle['results']! as List<Object?>).cast<ScriptJson>()) {
    test('explicit raw array admission: ${row['name']}', () async {
      // This change does not replace the public/default token counter.
      expect(counter.countMessage(_plain), oracle['measuredPlainCost']);
      expect(counter.countMessage(_parts), oracle['measuredNativePartsCost']);
      final h = await generationFixture();
      await h.close();
      final counted = <Map<String, Object?>>[];
      final engine = await TavernEngine.openDirectory(
        h.root,
        config: h.config,
        modelClient: h.model,
        counter: CallbackTokenCounter(
          name: counter.name,
          exact: counter.exact,
          text: counter.countText,
          message: (message) {
            counted.add(jsonDecode(jsonEncode(message)) as ScriptJson);
            return counter.countMessage(message);
          },
        ),
      );
      addTearDown(engine.close);
      await engine.setPreset(
        ChatPreset({
          ...scriptPreset().raw,
          'openai_max_context': row['context'],
          'openai_max_tokens': row['maxResponse'],
        }),
      );
      final host = _FailedImageHost();
      engine.scripts.attachHost(host);
      final context = await engine.scripts.openContext(TavernScriptContextSpec(instanceId: row['name']! as String));
      final success = row['failure'] == null;
      final plan = success ? h.reply('MODEL') : null;
      final kind = row['kind']! as String;
      final generation = await engine.scripts.generateRaw(
        context.id,
        TavernHelperRawRequest.fromJson({
          'user_input': 'Q',
          if (kind != 'plain') 'image': [if (kind != 'emptyArray') kind == 'failedArray' ? _failedImage : _image],
          'ordered_prompts': [if (row['explicitInput'] == true) 'user_input'],
          'overrides': {
            'chat_history': {'prompts': [], 'with_depth_entries': false},
          },
        }),
      );
      if (plan == null) {
        final failure = await generationFailure(generation);
        expect(failure.modelFailure, TavernFailure.contextTooLong);
        expect(h.requests, isEmpty);
      } else {
        final request = await generationRequest(generation, plan);
        final result = await generation.result;
        expect(result.text, 'MODEL');
        expect(request.body['messages'], row['wireMessages']);
        expect(h.requests, hasLength(1));
        expect(
          result.hookIssues.where((issue) => issue.code == 'helperImageConversionFailed'),
          hasLength(kind == 'failedArray' ? 1 : 0),
        );
      }
      expect(counted.first, _plain, reason: 'The outer plain user reserve is retained.');
      expect(host.calls, kind == 'failedArray' ? [_failedImage] : isEmpty);
    });
  }
}

class _FailedImageHost extends GenerationHost implements TavernHelperImageHost {
  final calls = <String>[];

  @override
  Future<String> resolveHelperImage(String source, TavernScriptCancellation cancellation) async {
    calls.add(source);
    throw const TavernHelperImageConversionFailure(
      stage: TavernHelperImageConversionStage.download,
      message: 'Controlled download failure.',
    );
  }
}
