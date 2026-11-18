import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/tavern/tavern_canvas_calls.dart';
import 'package:dsh_app/tavern/tavern_card_scripts.dart';
import 'package:dsh_app/tavern/tavern_provider.dart';
import 'package:dsh_app/tavern/tavern_script_wire.dart';
import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _card(Map<String, Object?> extensions) => {
  'spec': 'chara_card_v3',
  'spec_version': '3.0',
  'data': {'name': '林晚', 'description': '店主。', 'first_mes': '进来吧。', 'extensions': extensions},
};

Map<String, Object?> _script(
  String id, {
  bool enabled = true,
  String content = 'console.log(1);',
  Object? button,
  String? name,
}) => {
  'type': 'script',
  'enabled': enabled,
  'name': name ?? id,
  'id': id,
  'content': content,
  'info': '',
  'button': ?button,
  'data': <String, Object?>{},
};

void main() {
  test('a card uses MVU when it says so, or anything in it loads MagVarUpdate', () {
    expect(tavernUsesMvu(null), isFalse);
    expect(tavernUsesMvu({'name': '林晚'}), isFalse);
    expect(
      tavernUsesMvu({
        'extensions': {
          'dshgo': {
            'mvu': {'enabled': true},
          },
        },
      }),
      isTrue,
    );
    expect(
      tavernUsesMvu({
        'extensions': {
          'tavern_helper': {
            'scripts': [
              {'content': "import 'https://testingcf.jsdelivr.net/gh/MagicalAstrogy/MagVarUpdate/artifact/bundle.js';"},
            ],
          },
        },
      }),
      isTrue,
    );
  });

  test("a chat's scripts come from the engine: global, then the card's; the same id in both is two scripts", () async {
    final dir = await Directory.systemTemp.createTemp('card-scripts');
    final tavern = await openTavern(dir.path);
    addTearDown(() async {
      await tavern.close();
      await dir.delete(recursive: true);
    });
    final card = _card({
      'tavern_helper': {
        'scripts': [_script('s1', name: '变量初始化', content: 'await initVars();'), _script('s2', enabled: false)],
        'variables': {'hp': 10},
      },
    });
    final id = (await tavern.importCard(utf8.encode(jsonEncode(card)), fileName: 'card.json')).id;
    await tavern.importGlobalScripts(jsonEncode(_script('s1', name: '全局')));
    final chat = await tavern.createChat(id);
    final container = ProviderContainer(overrides: [tavernProvider.overrideWithValue(tavern)]);
    addTearDown(container.dispose);
    final sub = container.listen(tavernChatScriptsProvider((chat, id)), (_, _) {});
    addTearDown(sub.close);
    final chosen = await container.read(tavernChatScriptsProvider((chat, id)).future);
    expect(
      [for (final s in chosen.scripts) (s.owner.kind, s.name)],
      [(TavernScriptOwnerKind.global, '全局'), (TavernScriptOwnerKind.character, '变量初始化')],
    );
    final [global, own] = chosen.scripts;
    expect(tavernScriptKey(global.owner), isNot(tavernScriptKey(own.owner)));
    expect(tavernScriptJson(own), containsPair('owner', {'kind': 'character', 'scriptId': 's1', 'assetId': id}));

    // Each one's buttons are kept on its own owner, through its own context.
    final calls = TavernCanvasCalls(tavern.scripts, chatId: chat, characterId: () => id)..setScripts(chosen);
    addTearDown(calls.close);
    Future<Map<String, Object?>> buttons(TavernRunnableScript s, String name) => calls.handle({
      'id': name,
      'method': 'replaceScriptButtons',
      'params': {
        'asScript': tavernScriptKey(s.owner),
        'buttons': [
          {'name': name, 'visible': true},
        ],
      },
    });
    expect((await buttons(global, '全局按钮'))['ok'], isTrue);
    expect((await buttons(own, '卡按钮'))['ok'], isTrue);
    final after = await tavern.chatScripts(chat, characterId: id);
    expect(
      [for (final s in after.scripts) tavernScriptButtons(s)],
      [
        ['全局按钮'],
        ['卡按钮'],
      ],
    );
    // A script the page no longer runs: its context is gone, not reopened.
    calls.setScripts(TavernChatScripts(chatId: chat, characterId: id, scripts: [own]));
    expect(((await buttons(global, 'x'))['error']! as Map)['code'], 'closedContext');

    // The card's fields themselves, for the page's character questions.
    final dataSub = container.listen(tavernCardDataProvider(id), (_, _) {});
    addTearDown(dataSub.close);
    final data = (await container.read(tavernCardDataProvider(id).future))!;
    expect((data['name'], data['first_mes']), ('林晚', '进来吧。'));
    expect(((data['extensions']! as Map)['tavern_helper']! as Map)['variables'], {'hp': 10});
  });

  test("a card's fields: under data for V2/V3, the top level for V1, none for what is not a card", () {
    expect(tavernCardData(_card({}))!['name'], '林晚');
    expect(tavernCardData({'name': 'v1', 'description': 'x'}), {'name': 'v1', 'description': 'x'});
    expect(tavernCardData('not a card'), isNull);
    expect(tavernCardData(null), isNull);
  });

  test(
    "a script's own variables, asked for by the page by its whole owner: on this character's card, kept there",
    () async {
      final dir = await Directory.systemTemp.createTemp('card-script-vars');
      final tavern = await openTavern(dir.path);
      addTearDown(() async {
        await tavern.close();
        await dir.delete(recursive: true);
      });
      final card = _card({
        'tavern_helper': {
          'scripts': [
            {
              ..._script('s1'),
              'data': {'count': 1},
            },
          ],
        },
      });
      final id = (await tavern.importCard(utf8.encode(jsonEncode(card)), fileName: 'card.json')).id;
      final chat = await tavern.createChat(id);
      final calls = TavernCanvasCalls(tavern.scripts, chatId: chat, characterId: () => id);
      addTearDown(calls.close);
      final target = {
        'scope': 'script',
        'scriptOwner': {'kind': 'character', 'scriptId': 's1', 'assetId': id},
      };
      final read = await calls.handle({
        'id': 1,
        'method': 'getVariables',
        'params': {'target': target},
      });
      expect(read['ok'], isTrue, reason: '${read['error']}');
      expect((read['result']! as Map)['value'], {'count': 1});
      final written = await calls.handle({
        'id': 2,
        'method': 'replaceVariables',
        'params': {
          'target': target,
          'value': {'count': 2},
        },
      });
      expect(written['ok'], isTrue, reason: '${written['error']}');
      // Kept on the card, in that script's own data.
      final saved = jsonDecode(utf8.decode(await tavern.exportCard(id, format: TavernCardFormat.json))) as Map;
      final entry =
          ((((saved['data'] as Map)['extensions'] as Map)['tavern_helper'] as Map)['scripts'] as List).first as Map;
      expect(entry['data'], {'count': 2});
    },
  );
}
