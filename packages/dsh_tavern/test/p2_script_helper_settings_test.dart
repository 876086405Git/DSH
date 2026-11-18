import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_script_test_support.dart';

void main() {
  test('helper settings and owner buttons adopt real carriers with narrow CAS', () async {
    final h = await ScriptFixture.open();
    final character = await h.card(
      '设置台',
      extensions: {
        'tavern_helper': _container('card'),
        'foreign_extension': {
          'keep': [false, null],
        },
      },
    );
    final presetRaw = scriptPreset().raw
      ..['name'] = '按钮预设'
      ..['extensions'] = {
        'tavern_helper': _container('preset'),
        'foreign_preset': {'keep': 1},
      };
    final preset = (await h.engine.importPreset(jsonEncode(presetRaw))).preset.id;
    await h.engine.putLorebook('helper-book', {'name': '初始化资料', 'entries': <String, Object?>{}});
    await h.engine.bindLorebooks(['helper-book']);
    await h.engine.setSettings({
      'foreign_setting': {'keep': 1},
      'worldInfo': {
        'foreign_wi': ['opaque', null],
      },
    });
    final chat = await h.engine.createChat(character);
    final cardOwner = TavernScriptOwner(
      kind: TavernScriptOwnerKind.character,
      assetId: character,
      scriptId: 'same-script',
    );
    final presetOwner = TavernScriptOwner(kind: TavernScriptOwnerKind.preset, assetId: preset, scriptId: 'same-script');
    const globalOwner = TavernScriptOwner(kind: TavernScriptOwnerKind.global, scriptId: 'same-script');
    final card = await h.context(chat, characterId: character, owner: cardOwner, instanceId: 'card-owner');
    final otherFrame = await h.context(
      chat,
      characterId: character,
      owner: cardOwner,
      instanceId: 'same-card-other-frame',
    );
    final presetContext = await h.context(chat, characterId: character, owner: presetOwner, instanceId: 'preset-owner');
    final global = await h.context(chat, characterId: character, owner: globalOwner, instanceId: 'global-owner');
    final noOwner = await h.context(chat, characterId: character, instanceId: 'without-owner');
    final beforeChat = _chatContent((await h.engine.exportChat(chat)).single.bytes);
    final initialDocument = await h.settingsDocument();
    final initial = await h.bridge.snapshot(card.id);
    final wi = scriptMap(initial.resourceRefs['worldInfoSettings']);
    expect(scriptMap(wi['value'])['selected_global_lorebooks'], ['standalone:helper-book']);
    final oldCardButtons = scriptMap(initial.resourceRefs['scriptButtons']);
    final oldPresetButtons = scriptMap((await h.bridge.snapshot(presetContext.id)).resourceRefs['scriptButtons']);
    final oldGlobalButtons = scriptMap((await h.bridge.snapshot(global.id)).resourceRefs['scriptButtons']);
    expect(oldGlobalButtons['buttons'], isEmpty);
    expect((await h.bridge.snapshot(noOwner.id)).resourceRefs.containsKey('scriptButtons'), isFalse);
    await expectLater(
      () => h.bridge.replaceScriptButtons(noOwner.id, const []),
      throwsA(scriptError(TavernScriptErrorCode.noContext)),
    );

    // An unrelated setting does not invalidate the captured WI projection.
    await h.engine.setSettings({
      'foreign_setting': {'keep': 2},
    });
    final changed = await h.bridge.updateWorldInfoSettings(card.id, {
      'scan_depth': 7,
      'context_percentage': 55.5,
      'budget_cap': 321,
      'insertion_strategy': 'global_first',
      'recursive': true,
      'overflow_alert': true,
    }, expectedVersion: wi['version']! as String);
    expect(changed.version, isNot(wi['version']));
    expect(changed.value['selected_global_lorebooks'], ['standalone:helper-book']);
    final document = await h.settingsDocument();
    final settings = scriptMap(document['settings']);
    final nativeRaw = scriptMap(settings['worldInfo']);
    final native = WorldInfoSettings.fromJson(nativeRaw);
    expect(native.scanDepth, 7);
    expect(native.budgetPercent, 55.5);
    expect(native.budgetCap, 321);
    expect(native.strategy, WorldInfoStrategy.globalFirst);
    expect(native.recursive, isTrue);
    expect(nativeRaw['overflow_alert'], isTrue);
    expect(nativeRaw['foreign_wi'], ['opaque', null]);
    expect(settings['foreign_setting'], {'keep': 2});
    expect(
      scriptMap((await h.bridge.snapshot(otherFrame.id)).resourceRefs['worldInfoSettings'])['value'],
      changed.value,
    );

    await expectLater(
      () => h.bridge.updateWorldInfoSettings(card.id, {'scan_depth': 99}, expectedVersion: wi['version']! as String),
      throwsA(scriptError(TavernScriptErrorCode.revisionConflict)),
    );
    await expectLater(
      () => h.bridge.updateWorldInfoSettings(card.id, {
        'scan_depth': 99,
        'selected_global_lorebooks': <Object?>[],
      }, expectedVersion: changed.version),
      throwsA(scriptError(TavernScriptErrorCode.invalidArgument)),
    );
    expect(await h.settingsDocument(), document);

    // Real write failure before rename must not change adopted memory/cache.
    final blocked = Directory('${h.root.path}/settings.json.writing');
    await blocked.create();
    try {
      await expectLater(
        () => h.bridge.updateWorldInfoSettings(card.id, {'scan_depth': 99}, expectedVersion: changed.version),
        throwsA(scriptError(TavernScriptErrorCode.storage).having((error) => error.committed, 'committed', isFalse)),
      );
    } finally {
      await blocked.delete(recursive: true);
    }
    expect(await h.settingsDocument(), document);
    final afterFailure = scriptMap((await h.bridge.snapshot(card.id)).resourceRefs['worldInfoSettings']);
    expect(afterFailure['version'], changed.version);
    expect(afterFailure['value'], changed.value);

    // Both public writers share the original preset -> file queue order.
    await Future.wait<void>([
      h.bridge.updateWorldInfoSettings(card.id, {'recursive': true}, expectedVersion: changed.version).then((_) {}),
      h.engine.setSettings({
        'foreign_setting': {'keep': 3},
      }),
    ]);
    expect(scriptMap((await h.settingsDocument())['settings'])['foreign_setting'], {'keep': 3});

    final cardResult = await h.bridge.replaceScriptButtons(card.id, const [
      TavernScriptButton(name: 'Go', visible: false),
      TavernScriptButton(name: 'Go', visible: true),
      TavernScriptButton(name: '', visible: false),
    ], expectedVersion: oldCardButtons['version']! as String);
    expect(cardResult.owner, cardOwner);
    expect(cardResult.buttons.map((button) => [button.name, button.visible]), [
      ['Go', false],
      ['Go', true],
      ['', false],
    ]);
    final fields = (await h.engine.characterFields(character))!;
    final helper = scriptMap(scriptMap(fields['extensions'])['tavern_helper']);
    final stored = _script(helper);
    final button = scriptMap(stored['button']);
    expect(button['enabled'], isFalse);
    expect(button['foreign_button'], {'owner': 'card'});
    expect(button['buttons'], [
      {
        'name': 'Go',
        'visible': false,
        'foreign_row': ['card', null],
      },
      {'name': 'Go', 'visible': true},
      {'name': '', 'visible': false},
    ]);
    expect(helper['unknown_container'], {'keep': true});
    expect(scriptMap((helper['scripts']! as List<Object?>).single)['foreign_folder'], [1, null]);
    expect(stored['foreign_script'], {
      'keep': [1, false],
    });
    expect(stored['export_with'], {'data': true, 'button': false});
    expect(stored['data'], {'start': 'card'});
    expect(scriptMap(fields['extensions'])['foreign_extension'], {
      'keep': [false, null],
    });
    final sameOwner = scriptMap((await h.bridge.snapshot(otherFrame.id)).resourceRefs['scriptButtons']);
    expect(sameOwner['version'], cardResult.version);
    expect(sameOwner['buttons'], [
      {'name': 'Go', 'visible': false},
      {'name': 'Go', 'visible': true},
      {'name': '', 'visible': false},
    ]);
    expect(
      scriptMap((await h.bridge.snapshot(presetContext.id)).resourceRefs['scriptButtons'])['version'],
      oldPresetButtons['version'],
    );
    await expectLater(
      () => h.bridge.replaceScriptButtons(otherFrame.id, const [
        TavernScriptButton(name: 'stale', visible: true),
      ], expectedVersion: oldCardButtons['version']! as String),
      throwsA(scriptError(TavernScriptErrorCode.revisionConflict)),
    );
    expect((await h.engine.characterFields(character))!['extensions'], fields['extensions']);

    final presetResult = await h.bridge.replaceScriptButtons(presetContext.id, const [
      TavernScriptButton(name: 'Preset', visible: true),
    ], expectedVersion: oldPresetButtons['version']! as String);
    expect(presetResult.owner, presetOwner);
    final presetAfter = (await h.engine.preset(preset))!;
    final presetHelper = scriptMap(scriptMap(presetAfter.raw['extensions'])['tavern_helper']);
    final presetScript = _script(presetHelper);
    expect(scriptMap(presetScript['button']), {
      'enabled': false,
      'foreign_button': {'owner': 'preset'},
      'buttons': [
        {'name': 'Preset', 'visible': true},
      ],
    });
    expect(presetScript['data'], {'start': 'preset'});
    expect(scriptMap(presetAfter.raw['extensions'])['foreign_preset'], {'keep': 1});

    final globalResult = await h.bridge.replaceScriptButtons(global.id, const [
      TavernScriptButton(name: 'Global', visible: false),
    ], expectedVersion: oldGlobalButtons['version']! as String);
    expect(globalResult.owner, globalOwner);
    final afterButtons = await h.settingsDocument();
    expect(scriptMap(afterButtons['scriptButtons'])['same-script'], [
      {'name': 'Global', 'visible': false},
    ]);
    expect(afterButtons.containsKey('scriptData'), initialDocument.containsKey('scriptData'));
    expect(afterButtons['scriptData'], initialDocument['scriptData']);
    expect((await h.bridge.getVariables(card.id, scriptOwner)).value, {'start': 'card'});
    expect((await h.bridge.getVariables(presetContext.id, scriptOwner)).value, {'start': 'preset'});
    expect(_chatContent((await h.engine.exportChat(chat)).single.bytes), beforeChat);
    h.expectNoGeneration();

    await h.reopen();
    final freshCard = await h.context(chat, characterId: character, owner: cardOwner, instanceId: 'reopened-card');
    final freshPreset = await h.context(
      chat,
      characterId: character,
      owner: presetOwner,
      instanceId: 'reopened-preset',
    );
    final freshGlobal = await h.context(
      chat,
      characterId: character,
      owner: globalOwner,
      instanceId: 'reopened-global',
    );
    final reopened = await h.bridge.snapshot(freshCard.id);
    expect(scriptMap(reopened.resourceRefs['worldInfoSettings'])['value'], changed.value);
    expect(scriptMap(reopened.resourceRefs['scriptButtons'])['buttons'], sameOwner['buttons']);
    expect(scriptMap((await h.bridge.snapshot(freshPreset.id)).resourceRefs['scriptButtons'])['buttons'], [
      {'name': 'Preset', 'visible': true},
    ]);
    expect(scriptMap((await h.bridge.snapshot(freshGlobal.id)).resourceRefs['scriptButtons'])['buttons'], [
      {'name': 'Global', 'visible': false},
    ]);
    h.expectNoGeneration();
  });
}

List<ScriptJson> _chatContent(List<int> bytes) {
  final rows = [for (final line in const LineSplitter().convert(utf8.decode(bytes))) scriptMap(jsonDecode(line))];
  // Each export intentionally assigns a fresh integrity UUID.
  scriptMap(rows.first['chat_metadata']).remove('integrity');
  return rows;
}

ScriptJson _container(String owner) {
  final result = scriptContainer(owner);
  _script(result)['button'] = {
    'enabled': false,
    'foreign_button': {'owner': owner},
    'buttons': [
      {
        'name': 'Go',
        'visible': true,
        'foreign_row': [owner, null],
      },
    ],
  };
  return result;
}

ScriptJson _script(ScriptJson container) {
  final folder = scriptMap((container['scripts']! as List<Object?>).single);
  return scriptMap((folder['scripts']! as List<Object?>).single);
}
