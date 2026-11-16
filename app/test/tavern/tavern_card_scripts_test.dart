import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/tavern/tavern_canvas_calls.dart';
import 'package:dsh_app/tavern/tavern_card_scripts.dart';
import 'package:dsh_app/tavern/tavern_provider.dart';
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
  test("a card's scripts that run: enabled, with code, in the tree's order, not under a folder that is off", () {
    final card = _card({
      'tavern_helper': {
        'scripts': [
          _script(
            'a',
            name: '状态栏',
            button: {
              'enabled': true,
              'buttons': [
                {'name': '前往', 'visible': true},
                {'name': '藏起来的', 'visible': false},
                {'name': '', 'visible': true},
              ],
            },
          ),
          _script('off', enabled: false),
          _script('blank', content: '   '),
          {
            'type': 'folder',
            'enabled': true,
            'name': '工具',
            'id': 'f1',
            'scripts': [
              _script('b'),
              {
                'type': 'folder',
                'enabled': false,
                'name': '关着',
                'id': 'f2',
                'scripts': [_script('hidden')],
              },
            ],
          },
          _script(
            'c',
            button: {
              'enabled': false,
              'buttons': [
                {'name': '不显示', 'visible': true},
              ],
            },
          ),
          'not a script',
          {'type': 'script', 'id': 'no-content', 'enabled': true},
        ],
      },
    });
    final scripts = tavernCardScripts(card);
    expect([for (final s in scripts) s.id], ['a', 'b', 'c']);
    expect(scripts.first.name, '状态栏');
    expect(scripts.first.buttons, ['前往']);
    expect(scripts.last.buttons, isEmpty);
    expect(scripts.first.toJson(), {
      'id': 'a',
      'name': '状态栏',
      'content': 'console.log(1);',
      'buttons': ['前往'],
      'buttonList': [
        {'name': '前往', 'visible': true},
        {'name': '藏起来的', 'visible': false},
      ],
    });
    // Off as a whole, its buttons are still the script's (getScriptButtons).
    expect([for (final b in scripts.last.buttonList) b.name], ['不显示']);
  });

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

  test('the older place for them is read too; a card without any has none', () {
    expect(
      [
        for (final s in tavernCardScripts(
          _card({
            'TavernHelper_scripts': [_script('old')],
          }),
        ))
          s.id,
      ],
      ['old'],
    );
    // The newer place wins when both are there.
    expect(
      [
        for (final s in tavernCardScripts(
          _card({
            'tavern_helper': {
              'scripts': [_script('new')],
            },
            'TavernHelper_scripts': [_script('old')],
          }),
        ))
          s.id,
      ],
      ['new'],
    );
    expect(tavernCardScripts(_card({})), isEmpty);
    expect(tavernCardScripts({'name': 'v1 card'}), isEmpty);
    expect(tavernCardScripts(null), isEmpty);
    // Fields at the top (no data wrapper) are read as well.
    expect(
      tavernCardScripts({
        'extensions': {
          'TavernHelper_scripts': [_script('top')],
        },
      }).single.id,
      'top',
    );
  });

  test("the scripts come back from the engine's own copy of the card", () async {
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
    final container = ProviderContainer(overrides: [tavernProvider.overrideWithValue(tavern)]);
    addTearDown(container.dispose);
    final sub = container.listen(tavernCardScriptsProvider(id), (_, _) {});
    addTearDown(sub.close);
    final scripts = await container.read(tavernCardScriptsProvider(id).future);
    expect(scripts, [const TavernCardScript(id: 's1', name: '变量初始化', content: 'await initVars();')]);
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
    "a script's own variables, asked for by the page by script alone: on this character's card, kept there",
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
      const target = {
        'scope': 'script',
        'scriptOwner': {'kind': 'character', 'scriptId': 's1'},
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
