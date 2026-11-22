import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_script_generation_test_support.dart';
import 'spreset_engine_test.dart' show SPresetHost;

void main() {
  test('malformed entries are unavailable to automatic primary selection and remain repairable', () async {
    final h = await generationFixture(allowModel: false);
    final character = await h.card('Directory shape', extensions: {'world': 'Shared'});
    final chat = await h.emptyChat(character);
    await h.engine.putLorebook('valid-map', {'name': 'Shared', 'entries': <String, Object?>{}});
    await h.engine.putLorebook('valid-array', {'name': 'Array', 'entries': <Object?>[]});
    final folder = Directory('${h.root.path}/lorebooks');
    final malformed = <String, ScriptJson>{
      'bad-null': {'name': 'Shared', 'entries': null},
      'bad-scalar': {'name': 'Shared', 'entries': 1},
      'bad-string': {'name': 'Shared', 'entries': 'not entries'},
      'bad-missing': {'name': 'Shared'},
    };
    for (final entry in malformed.entries) {
      await File('${folder.path}/${entry.key}.json').writeAsString(jsonEncode(entry.value));
    }
    final context = await h.context(chat, characterId: character);
    final directory = await h.bridge.getBookDirectory(context.id);
    expect(directory.books.where((book) => book.readable).map((book) => book.handle).toSet(), {
      'standalone:valid-map',
      'standalone:valid-array',
    });
    expect(directory.issues.where((issue) => issue.code == 'shapeMismatch'), hasLength(4));
    final bindings = await h.bridge.readBookBindings(
      context.id,
      TavernScriptBookBindingsTarget(scope: TavernScriptBookBindingScope.character, targetId: character),
    );
    expect(bindings.primary, TavernScriptBookRef.standalone(bookId: 'valid-map'));
    final ref = TavernScriptBookRef.standalone(bookId: 'bad-null');
    expect(await h.bridge.resolveBook(context.id, 'standalone:bad-null'), ref);
    final raw = await h.bridge.readBook(context.id, ref);
    expect(raw.book, malformed['bad-null']);
    await h.bridge.replaceBook(context.id, ref, {
      'name': 'Repaired',
      'entries': <Object?>[],
    }, expectedVersion: raw.version);
    final repaired = await h.bridge.getBookDirectory(context.id);
    expect(repaired.books.singleWhere((book) => book.ref == ref).readable, isTrue);
    expect(repaired.issues.where((issue) => issue.details['handle'] == 'standalone:bad-null'), isEmpty);
    expect(repaired.version, isNot(directory.version));
    h.expectNoGeneration();
  });

  test('embedded malformed entries are unavailable without rewriting their authority', () async {
    final h = await generationFixture(allowModel: false);
    final card = scriptMap(jsonDecode(await File('test/fixtures/card-v3.json').readAsString()));
    scriptMap(card['data'])['character_book'] = {'name': 'Malformed embedded', 'entries': null};
    final character = (await h.engine.importCard(Uint8List.fromList(utf8.encode(jsonEncode(card))))).id;
    final context = await h.bridge.openContext(
      TavernScriptContextSpec(instanceId: 'embedded-shape', characterId: character),
    );
    final directory = await h.bridge.getBookDirectory(context.id);
    final ref = TavernScriptBookRef.embedded(characterId: character);
    expect(directory.books.singleWhere((book) => book.ref == ref).readable, isFalse);
    expect(directory.issues.single.code, 'shapeMismatch');
    expect((await h.bridge.readBook(context.id, ref)).book, {'name': 'Malformed embedded', 'entries': null});
    h.expectNoGeneration();
  });

  test('raw separate ChatSquash identifies original history and leaves literal/input outside', () async {
    final h = await generationFixture();
    final character = await h.card('Separate raw history');
    final context = await h.context(await h.emptyChat(character), characterId: character);
    await h.bridge.createChatMessages(context.id, [
      TavernScriptMessageDraft(role: TavernScriptRole.user, message: 'one'),
      TavernScriptMessageDraft(role: TavernScriptRole.assistant, message: 'two'),
    ]);
    final preset = await h.engine.importPreset(
      jsonEncode(
        _preset({
          'enabled': true,
          'parse_clewd': false,
          'separate_chat_history': true,
          'user_prefix': 'U:',
          'char_prefix': 'A:',
          'role': 'user',
        }).raw,
      ),
    );
    final response = h.reply('A');
    final generation = await h.bridge.generateRaw(
      context.id,
      TavernScriptRawRequest(
        presetId: preset.preset.id,
        userInput: 'NEW INPUT',
        overrides: TavernScriptPromptOverrides(fields: {'withDepthEntries': false}),
        orderedPrompts: const [
          TavernScriptPromptPart.literal(role: TavernScriptPromptRole.system, content: 'OUTSIDE'),
          TavernScriptPromptPart.placeholder(TavernScriptPromptPlaceholder.chatHistory),
          TavernScriptPromptPart.placeholder(TavernScriptPromptPlaceholder.userInput),
        ],
      ),
    );
    final wire = await generationRequest(generation, response);
    await generation.result;
    expect(generationMessages(wire), [
      {'role': 'system', 'content': 'OUTSIDE'},
      {'role': 'user', 'content': 'U:oneA:two'},
      {'role': 'user', 'content': 'NEW INPUT'},
    ]);
  });

  for (final fits in [false, true]) {
    test('native raw recounts final ChatSquash output once at its original budget threshold (fits=$fits)', () async {
      final h = await generationFixture(allowModel: fits);
      final host = SPresetHost();
      final expanded = List.filled(10000, 'Q').join();
      final expected = <String, Object?>{'role': 'user', 'content': expanded};
      final cost = const EstimatedTokenCounter().countMessage(expected);
      var evaluated = 0;
      host.handler = (request) async {
        expect(request.stage, 'ChatSquash');
        evaluated++;
        return TavernSPresetEvaluationResult(
          requestId: request.requestId,
          value: expanded,
          arguments: request.arguments,
        );
      };
      h.bridge.attachHost(host);
      var draws = 0;
      h.onRandom = () => draws++;
      final context = await h.bridge.openContext(const TavernScriptContextSpec(instanceId: 'postscript-budget'));
      final raw = _preset({
        'enabled': true,
        'parse_clewd': false,
        'role': 'user',
        'squashed_post_script_enable': true,
        'squashed_post_script': 'fixture-expand',
      }).raw;
      raw['openai_max_tokens'] = 1;
      raw['openai_max_context'] = 1 + cost - (fits ? 0 : 1);
      final preset = await h.engine.importPreset(jsonEncode(raw));
      final response = fits ? h.reply('A') : null;
      final generation = await h.bridge.generateRaw(
        context.id,
        TavernScriptRawRequest(
          presetId: preset.preset.id,
          userInput: '{{random::one::two}}',
          orderedPrompts: const [TavernScriptPromptPart.placeholder(TavernScriptPromptPlaceholder.userInput)],
        ),
      );
      if (response == null) {
        final failure = await generationFailure(generation);
        expect(failure.modelFailure, TavernFailure.contextTooLong);
        expect(failure.committed, isFalse);
        h.expectNoGeneration();
      } else {
        final wire = await generationRequest(generation, response);
        await generation.result;
        expect(generationMessages(wire), [expected]);
      }
      expect(evaluated, 1, reason: 'The budget check must not rerun the page postprocessor.');
      expect(draws, 1, reason: 'The budget check must not replay input macros.');
    });
  }
}

ChatPreset _preset(ScriptJson squash) => ChatPreset({
  ...scriptPreset().raw,
  'custom_prompt_post_processing': '',
  'extensions': {
    'SPreset': {'ChatSquash': squash},
  },
});
