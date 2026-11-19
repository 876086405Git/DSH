import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_script_test_support.dart';

const _current = TavernScriptPresetRef.current();

void main() {
  test('global imports use live owner carriers, preserve trees and survive reopen', () async {
    final h = await ScriptFixture.open();
    // Bare-object shape follows the published NE-Memory import instructions;
    // omitted optional export fields are deliberate. Content stays inert.
    final single = (await h.engine.importGlobalScripts(jsonEncode(_script('same', 'Global')))).single;
    final imported = (await h.engine.importGlobalScripts(
      jsonEncode({
        'type': 'folder',
        'id': 'folder',
        'name': 'Tools',
        'enabled': false,
        'icon': 'book',
        'foreign_folder': [1, null],
        'scripts': [
          {
            ..._script('nested', 'Nested'),
            'data': {'count': 1},
            'button': {
              'enabled': false,
              'foreign_button': true,
              'buttons': [
                {'name': 'Go', 'visible': true, 'foreign_row': 7},
              ],
            },
            'export_with': {'data': true, 'button': true},
          },
          _script('last', 'Last'),
        ],
      }),
    )).single;
    expect(single.id, 'same');
    expect(imported.children.map((entry) => entry.id), ['nested', 'last']);
    final document = await h.settingsDocument();
    final storedFolder = scriptMap((document['scriptLibrary']! as List<Object?>)[1]);
    final storedScript = scriptMap((storedFolder['scripts']! as List<Object?>).first);
    expect(storedScript.containsKey('data'), isFalse);
    expect(scriptMap(storedScript['button']).containsKey('buttons'), isFalse);
    expect(scriptMap(document['scriptData'])['nested'], {'count': 1});

    final character = await h.card('Library owner');
    final chat = await h.engine.createChat(character);
    const owner = TavernScriptOwner(kind: TavernScriptOwnerKind.global, scriptId: 'nested');
    final context = await h.context(chat, owner: owner);
    final before = await h.bridge.getVariables(context.id, scriptOwner);
    await h.bridge.replaceVariables(context.id, scriptOwner, {'count': 2}, expectedVersion: before.version);
    await h.bridge.replaceScriptButtons(context.id, const [TavernScriptButton(name: 'Go', visible: false)]);
    final current = scriptMap(jsonDecode(await h.engine.exportGlobalScripts(id: 'nested')));
    expect(current['data'], {'count': 2});
    expect(scriptMap(current['button']), {
      'enabled': false,
      'foreign_button': true,
      'buttons': [
        {'name': 'Go', 'visible': false, 'foreign_row': 7},
      ],
    });
    final detached = (await h.engine.listGlobalScripts())[1].raw;
    scriptMap((detached['scripts']! as List<Object?>).first)['content'] = 'caller edit';
    expect(await h.engine.exportGlobalScripts(id: 'nested'), contains('// Nested'));

    final duplicate = (await h.engine.importGlobalScripts(jsonEncode(_script('same', 'Second copy')))).single;
    expect(duplicate.id, isNot(single.id));
    await h.engine.setGlobalScriptEnabled('folder', true);
    await h.engine.setGlobalScriptOrder(['last', 'nested'], folderId: 'folder');
    await h.engine.setGlobalScriptOrder([duplicate.id, 'folder', 'same']);
    expect((await h.engine.chatScripts(chat)).scripts.map((script) => script.name), [
      'Second copy',
      'Last',
      'Nested',
      'Global',
    ]);
    final exported = await h.engine.exportGlobalScripts();
    await h.reopen();
    expect(await h.engine.exportGlobalScripts(), exported);
    await h.engine.deleteGlobalScript('folder');
    final afterDelete = await h.settingsDocument();
    expect(scriptMap(afterDelete['scriptData']).containsKey('nested'), isFalse);
    expect(scriptMap(afterDelete['scriptButtons']).containsKey('nested'), isFalse);
    expect((await h.engine.listGlobalScripts()).map((entry) => entry.id), [duplicate.id, 'same']);
  });

  test('import validation and a real failed settings write leave the old library intact', () async {
    final h = await ScriptFixture.open();
    await h.engine.importGlobalScripts(jsonEncode(_script('one', 'One')));
    final before = await h.settingsDocument();
    await expectLater(
      h.engine.importGlobalScripts(jsonEncode({'wrapper': _script('two', 'Two')})),
      throwsFormatException,
    );
    await expectLater(h.engine.setGlobalScriptOrder([]), throwsArgumentError);
    final blocked = Directory('${h.root.path}/settings.json.writing');
    await blocked.create();
    try {
      await expectLater(
        h.engine.importGlobalScripts(
          jsonEncode({
            ..._script('two', 'Two'),
            'data': {'value': 1},
          }),
        ),
        throwsA(isA<FileSystemException>()),
      );
    } finally {
      await blocked.delete();
    }
    expect(await h.settingsDocument(), before);
    expect((await h.engine.listGlobalScripts()).single.id, 'one');
    await h.reopen();
    expect((await h.engine.listGlobalScripts()).single.id, 'one');
  });

  test('effective scripts retain scope owners, legacy precedence and explicit group character', () async {
    final h = await ScriptFixture.open();
    await h.engine.importGlobalScripts(jsonEncode(_script('same', 'Global')));
    final preset = (await h.engine.importPreset(jsonEncode(_preset([_script('same', 'Preset')], legacy: true)))).preset;
    await h.engine.setDefaultPreset(preset.id);
    final character = await h.card(
      'Trees',
      extensions: {
        'tavern_helper': {
          'scripts': [
            _script('same', 'Character'),
            {
              'type': 'folder',
              'enabled': false,
              'scripts': [_script('hidden', 'Hidden')],
            },
            {
              'type': 'folder',
              'children': [_script('child', 'Child')],
            },
            {..._script('', 'Missing'), 'id': ''},
            _script('duplicate', 'Duplicate A'),
            {..._script('duplicate', 'Duplicate B'), 'enabled': false},
          ],
        },
        'TavernHelper_scripts': [_script('legacy', 'Not selected')],
      },
    );
    final chat = await h.engine.createChat(character);
    final value = await h.engine.chatScripts(chat);
    expect(value.characterId, character);
    expect(value.scripts.map((script) => script.name), ['Global', 'Preset', 'Character', 'Child']);
    expect(value.scripts.take(3).map((script) => script.owner).toSet(), hasLength(3));
    expect(value.issues.map((issue) => issue.code), ['missingScriptId', 'ambiguousName']);
    final cardOwner = value.scripts[2].owner;
    expect(cardOwner.assetId, character);
    final context = await h.context(chat, owner: cardOwner);
    expect((await h.bridge.getVariables(context.id, scriptOwner)).value, isEmpty);

    await h.engine.updatePreset(preset.id, {
      'extensions': {
        'tavern_helper': {'scripts': <Object?>[]},
      },
    });
    expect((await h.engine.chatScripts(chat)).scripts.any((script) => script.name == 'Preset'), isFalse);
    final group = await h.engine.createGroupChat([character], addGreetings: false);
    final noCharacter = await h.engine.chatScripts(group);
    expect(noCharacter.characterId, isNull);
    expect(noCharacter.scripts.map((script) => script.name), ['Global']);
    expect((await h.engine.chatScripts(group, characterId: character)).scripts.last.name, 'Child');
  });

  test('working preset owners follow their real slot and keep versions through current edits', () async {
    final h = await ScriptFixture.open();
    await h.engine.setSettings({
      'preset': _preset([_script('saved', 'Saved')]),
    });
    final savedId = (await h.engine.presetSelection()).effectivePresetId!;
    final character = await h.card('Current preset');
    final chat = await h.engine.createChat(character);
    final otherChat = await h.engine.createChat(character);
    final controller = await h.bridge.openContext(const TavernScriptContextSpec(instanceId: 'current-controller'));
    final initial = await h.bridge.readPreset(controller.id, _current);
    await h.bridge.replacePreset(
      controller.id,
      _current,
      _preset([
        {
          ..._script('new', 'Working'),
          'data': {'count': 1},
          'button': {
            'enabled': true,
            'buttons': [
              {'name': 'One', 'visible': true},
            ],
          },
        },
      ]),
      expectedVersion: initial.version,
    );
    final selected = (await h.engine.chatScripts(chat)).scripts.single;
    final owner = selected.owner;
    expect(owner.assetId, savedId);
    expect(owner.presetCarrier!.kind, TavernScriptPresetCarrierKind.working);
    expect(owner.presetCarrier!.chatId, isNull);
    expect((await h.engine.chatScripts(otherChat)).scripts.single.owner, owner);
    final context = await h.context(chat, owner: owner, instanceId: 'working-script');
    final other = await h.context(otherChat, owner: owner, instanceId: 'other-working-script');
    final variables = await h.bridge.getVariables(context.id, scriptOwner);
    await h.bridge.replaceVariables(context.id, scriptOwner, {'count': 2}, expectedVersion: variables.version);
    expect((await h.bridge.getVariables(other.id, scriptOwner)).value, {'count': 2});
    await h.bridge.replaceScriptButtons(context.id, const [TavernScriptButton(name: 'Two', visible: false)]);
    final beforeEdit = await h.bridge.getVariables(context.id, scriptOwner);
    final beforeButtons = scriptMap((await h.bridge.snapshot(context.id)).resourceRefs['scriptButtons']);

    final current = await h.bridge.readPreset(controller.id, _current);
    await h.bridge.replacePreset(
      controller.id,
      _current,
      current.raw..['temperature'] = 0.4,
      expectedVersion: current.version,
    );
    expect((await h.engine.chatScripts(chat)).scripts.single.owner, owner);
    const regexTarget = TavernScriptRegexWriteTarget.preset(preset: _current);
    final regex = await h.bridge.readTavernRegexesForWrite(controller.id, regexTarget);
    await h.bridge.replaceTavernRegexes(controller.id, regexTarget, const [], expectedVersion: regex.version);
    expect((await h.engine.chatScripts(chat)).scripts.single.owner, owner);
    expect((await h.bridge.getVariables(context.id, scriptOwner)).version, beforeEdit.version);

    final editData = await h.bridge.readPreset(controller.id, _current);
    final changedRaw = editData.raw;
    final node = scriptMap(
      (scriptMap(scriptMap(changedRaw['extensions'])['tavern_helper'])['scripts']! as List<Object?>).single,
    );
    node['data'] = {'count': 9};
    node['button'] = {
      'enabled': true,
      'buttons': [
        {'name': 'Nine', 'visible': true},
      ],
    };
    await h.bridge.replacePreset(controller.id, _current, changedRaw, expectedVersion: editData.version);
    expect((await h.bridge.getVariables(other.id, scriptOwner)).value, {'count': 9});
    await expectLater(
      h.bridge.replaceVariables(context.id, scriptOwner, {'count': 3}, expectedVersion: beforeEdit.version),
      throwsA(scriptError(TavernScriptErrorCode.revisionConflict)),
    );
    await expectLater(
      h.bridge.replaceScriptButtons(context.id, const [], expectedVersion: beforeButtons['version']! as String),
      throwsA(scriptError(TavernScriptErrorCode.revisionConflict)),
    );
    expect((await h.engine.preset(savedId))!.raw['extensions'], _preset([_script('saved', 'Saved')])['extensions']);

    await h.engine.setDefaultPreset(savedId);
    expect((await h.engine.chatScripts(chat)).scripts.single.name, 'Saved');
    await expectLater(
      h.bridge.getVariables(context.id, scriptOwner),
      throwsA(scriptError(TavernScriptErrorCode.notFound)),
    );
    await h.bridge.closeContext(context.id);
    await h.bridge.closeContext(other.id);
    final reset = await h.bridge.readPreset(controller.id, _current);
    await h.bridge.replacePreset(controller.id, _current, changedRaw, expectedVersion: reset.version);
    expect((await h.engine.chatScripts(chat)).scripts.single.owner, isNot(owner));
    await h.reopen();
    expect((await h.engine.chatScripts(chat)).scripts.single.owner.presetCarrier, isNull);
  });

  test('legacy inline preset owners persist data and buttons in the original carriers', () async {
    final h = await ScriptFixture.open();
    await h.engine.setSettings({
      'preset': _preset([_script('inline', 'Global inline')]),
    });
    final globalId = (await h.engine.presetSelection()).effectivePresetId!;
    await h.engine.deletePreset(globalId);
    final character = await h.card('Inline owner');
    final chat = await h.engine.createChat(character);
    final scoped = await h.engine.createChat(character);
    await h.engine.setSettings({
      'preset': _preset([_script('inline', 'Chat inline')]),
    }, chatId: scoped);
    final scopedId = (await h.engine.presetSelection(chatId: scoped)).effectivePresetId!;
    await h.engine.deletePreset(scopedId);
    final globalOwner = (await h.engine.chatScripts(chat)).scripts.single.owner;
    final chatOwner = (await h.engine.chatScripts(scoped)).scripts.single.owner;
    expect(globalOwner.assetId, isNull);
    expect(globalOwner.presetCarrier, const TavernScriptPresetCarrier.inline());
    expect(chatOwner.presetCarrier, TavernScriptPresetCarrier.inline(chatId: scoped));
    final global = await h.context(chat, owner: globalOwner, instanceId: 'global-inline');
    final local = await h.context(scoped, owner: chatOwner, instanceId: 'chat-inline');
    await h.bridge.replaceVariables(global.id, scriptOwner, {'store': 'file'});
    await h.bridge.replaceVariables(local.id, scriptOwner, {'store': 'sql'});
    await h.bridge.replaceScriptButtons(local.id, const [TavernScriptButton(name: 'Local', visible: true)]);
    expect((await h.bridge.getVariables(global.id, scriptOwner)).value, {'store': 'file'});
    expect((await h.engine.chatScripts(scoped)).scripts.single.buttons.single.name, 'Local');
    await h.reopen();
    final reopenedGlobal = await h.context(chat, owner: globalOwner);
    final reopenedLocal = await h.context(scoped, owner: chatOwner, instanceId: 'reopened-local');
    expect((await h.bridge.getVariables(reopenedGlobal.id, scriptOwner)).value, {'store': 'file'});
    expect((await h.bridge.getVariables(reopenedLocal.id, scriptOwner)).value, {'store': 'sql'});
    expect((await h.engine.chatScripts(scoped)).scripts.single.buttons.single.name, 'Local');
  });

  test('closed global inline preset context cannot publish a completed temporary write', () async {
    final h = await ScriptFixture.open();
    await h.engine.setSettings({
      'preset': _preset([
        {
          ..._script('inline', 'Global inline'),
          'data': {'kept': 'before'},
        },
      ]),
    });
    await h.engine.deletePreset((await h.engine.presetSelection()).effectivePresetId!);
    final character = await h.card('Inline cancellation');
    final chat = await h.engine.createChat(character);
    final owner = (await h.engine.chatScripts(chat)).scripts.single.owner;
    expect(owner.presetCarrier, const TavernScriptPresetCarrier.inline());
    final context = await h.context(chat, owner: owner, instanceId: 'closing-inline');
    final before = await h.bridge.getVariables(context.id, scriptOwner);
    final file = File('${h.root.path}/settings.json');
    final original = await file.readAsBytes();
    final parent = Zone.current;
    final temporary = File('${file.path}.writing').absolute.uri;
    var closedAfterWrite = false;
    await IOOverrides.runZoned(
      () async {
        await expectLater(
          h.bridge.replaceVariables(context.id, scriptOwner, {
            'kept': 'must not publish',
          }, expectedVersion: before.version),
          throwsA(
            scriptError(TavernScriptErrorCode.closedContext).having((error) => error.committed, 'committed', isFalse),
          ),
        );
      },
      createFile: (path) {
        final real = parent.run(() => File(path));
        if (parent.run(() => real.absolute.uri) != temporary) return real;
        return _AfterWriteFile(real, () async {
          expect(closedAfterWrite, isFalse);
          closedAfterWrite = true;
          await h.bridge.closeContext(context.id);
        });
      },
    );
    expect(closedAfterWrite, isTrue);
    expect(await file.readAsBytes(), original);
    final fresh = await h.context(chat, owner: owner, instanceId: 'after-close');
    expect((await h.bridge.getVariables(fresh.id, scriptOwner)).value, before.value);
    await h.reopen();
    final reopened = await h.context(chat, owner: owner, instanceId: 'reopened-inline');
    expect((await h.bridge.getVariables(reopened.id, scriptOwner)).value, before.value);
    h.expectNoGeneration();
  });

  test('catalog watch responds to definitions and ignores ordinary message commits', () async {
    final h = await ScriptFixture.open();
    final character = await h.card('Watching scripts');
    final chat = await h.engine.createChat(character);
    final context = await h.context(chat);
    final snapshots = <TavernChatScripts>[];
    var next = Completer<void>();
    final subscription = h.engine.watchChatScripts(chat).listen((value) {
      snapshots.add(value);
      if (!next.isCompleted) next.complete();
    });
    addTearDown(subscription.cancel);
    await next.future.timeout(const Duration(seconds: 5));
    await h.bridge.createChatMessages(context.id, [
      TavernScriptMessageDraft(role: TavernScriptRole.user, message: 'A short note.'),
    ]);
    await Future<void>.delayed(Duration.zero);
    expect(snapshots, hasLength(1));
    next = Completer<void>();
    await h.engine.importGlobalScripts(jsonEncode(_script('watch', 'Watch')));
    await next.future.timeout(const Duration(seconds: 5));
    expect(snapshots.last.scripts.single.name, 'Watch');
    final owner = snapshots.last.scripts.single.owner;
    final global = await h.context(chat, owner: owner, instanceId: 'watch-global-buttons');
    next = Completer<void>();
    await h.bridge.replaceScriptButtons(global.id, const [TavernScriptButton(name: 'Updated', visible: false)]);
    await next.future.timeout(const Duration(seconds: 5));
    expect(snapshots.last.scripts.single.buttons.single.name, 'Updated');
    expect(snapshots.last.scripts.single.buttons.single.visible, isFalse);
    next = Completer<void>();
    await h.engine.setGlobalScriptEnabled('watch', false);
    await next.future.timeout(const Duration(seconds: 5));
    expect(snapshots.last.scripts, isEmpty);
    await subscription.cancel();
  });
}

ScriptJson _script(String id, String name) => {
  'type': 'script',
  'enabled': true,
  'id': id,
  'name': name,
  'content': '// $name',
};

ScriptJson _preset(List<Object?> scripts, {bool legacy = false}) => scriptPreset().raw
  ..['extensions'] = {
    if (legacy) 'TavernHelper_scripts': scripts else 'tavern_helper': {'scripts': scripts},
  };

class _AfterWriteFile implements File {
  _AfterWriteFile(this.real, this.afterWrite);
  final File real;
  final Future<void> Function() afterWrite;
  @override
  String get path => real.path;
  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) async {
    final written = await real.writeAsString(contents, mode: mode, encoding: encoding, flush: flush);
    await afterWrite();
    return written;
  }

  @override
  Future<File> rename(String newPath) => real.rename(newPath);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
