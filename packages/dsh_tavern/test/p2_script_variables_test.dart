import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_script_test_support.dart';

void main() {
  test('runtime character snapshots observe external authority edits and retain old captures', () async {
    final h = await ScriptFixture.open();
    final character = await h.card('Runtime authority', extensions: {'tavern_helper': scriptContainer('before')});
    final chat = await h.emptyChat(character);
    final owner = TavernScriptOwner(kind: TavernScriptOwnerKind.character, assetId: character, scriptId: 'same-script');
    final context = await h.context(chat, characterId: character, owner: owner);
    final before = await h.bridge.snapshot(context.id);
    final oldData = scriptMap(before.resourceRefs['characterData']);
    final file = File('${h.root.path}/characters/$character/card.json');
    final envelope = scriptMap(jsonDecode(await file.readAsString()));
    scriptMap(envelope['data'])['extensions'] = {'tavern_helper': scriptContainer('external replacement')};
    await file.writeAsString(jsonEncode(envelope), flush: true);
    expect((await h.bridge.getVariables(context.id, scriptCharacter)).value, {'card-variable': 'external replacement'});
    expect((await h.bridge.getVariables(context.id, scriptOwner)).value, {'start': 'external replacement'});
    final after = await h.bridge.snapshot(context.id);
    final newData = scriptMap(after.resourceRefs['characterData']);
    expect(newData['version'], isNot(oldData['version']));
    expect(scriptMap(scriptMap(scriptMap(newData['data'])['extensions'])['tavern_helper'])['variables'], {
      'card-variable': 'external replacement',
    });
    expect(
      before.variableSnapshots
          .singleWhere((value) => value.resolvedTarget.scope == TavernVariableScope.character)
          .value,
      {'card-variable': 'before'},
    );
    expect(scriptMap(before.resourceRefs['characterData']), oldData);
    h.expectNoGeneration();
  });

  test('five persistent scopes keep script owners and iframe instances distinct', () async {
    final h = await ScriptFixture.open();
    final first = await h.card('Twin', extensions: {'tavern_helper': scriptContainer('A')});
    final second = await h.card('Twin', extensions: {'tavern_helper': scriptContainer('B')});
    final presetRaw = scriptPreset().raw
      ..['name'] = 'Script owner preset'
      ..['extensions'] = {
        'tavern_helper': scriptContainer('P'),
        'foreign_preset': [1, null],
      };
    final preset = (await h.engine.importPreset(jsonEncode(presetRaw))).preset.id;
    final chat = await h.emptyChat(first);
    expect(await h.engine.path(chat), isEmpty);
    final ownerA = TavernScriptOwner(kind: TavernScriptOwnerKind.character, assetId: first, scriptId: 'same-script');
    final ownerB = TavernScriptOwner(kind: TavernScriptOwnerKind.character, assetId: second, scriptId: 'same-script');
    final ownerP = TavernScriptOwner(kind: TavernScriptOwnerKind.preset, assetId: preset, scriptId: 'same-script');
    const ownerG = TavernScriptOwner(kind: TavernScriptOwnerKind.global, scriptId: 'same-script');
    final a = await h.context(chat, characterId: first, owner: ownerA);
    final b = await h.context(chat, characterId: second, owner: ownerB, instanceId: 'second-frame');
    final p = await h.context(chat, characterId: first, owner: ownerP, instanceId: 'preset-frame');
    final g = await h.context(chat, characterId: first, owner: ownerG, instanceId: 'global-frame');
    final a2 = await h.context(chat, characterId: first, owner: ownerA, instanceId: 'another-instance');
    expect(a.id, isNot(a2.id));
    expect((await h.bridge.getVariables(a.id, scriptOwner)).value, {'start': 'A'});
    expect((await h.bridge.getVariables(b.id, scriptOwner)).value, {'start': 'B'});
    expect((await h.bridge.getVariables(p.id, scriptOwner)).value, {'start': 'P'});
    expect((await h.bridge.getVariables(a.id, scriptCharacter)).value, {'card-variable': 'A'});
    final emptyChat = await h.bridge.replaceVariables(a.id, scriptChat, {'local': 7});
    expect(emptyChat.value, {'local': 7});
    expect((await h.bridge.getVariables(a.id, scriptChat)).value, {'local': 7});
    final made = await h.bridge.createChatMessages(a.id, [
      TavernScriptMessageDraft(
        role: TavernScriptRole.user,
        message: 'stored',
        data: {
          'stat_data': {'hp': 3},
        },
      ),
    ]);
    final ref = made.upsertMessages.single.ref;
    final targetMessage = TavernVariableTarget(scope: TavernVariableScope.message, messageRef: ref);
    final writes = [
      (
        context: a.id,
        target: scriptGlobal,
        value: <String, Object?>{
          'global': [1, null],
        },
      ),
      (context: a.id, target: scriptCharacter, value: <String, Object?>{'character': 'A2'}),
      (
        context: a.id,
        target: targetMessage,
        value: <String, Object?>{
          'stat_data': {'hp': 9},
        },
      ),
      (context: a.id, target: scriptOwner, value: <String, Object?>{'owner': 'A'}),
      (context: b.id, target: scriptOwner, value: <String, Object?>{'owner': 'B'}),
      (context: p.id, target: scriptOwner, value: <String, Object?>{'owner': 'P'}),
      (context: g.id, target: scriptOwner, value: <String, Object?>{'owner': 'G'}),
    ];
    for (final write in writes) {
      final actual = await h.bridge.replaceVariables(write.context, write.target, write.value);
      expect(actual.value, write.value);
      expect((await h.bridge.getVariables(write.context, write.target)).value, write.value);
    }
    expect((await h.bridge.getVariables(a2.id, scriptOwner)).value, {'owner': 'A'});
    expect((await h.bridge.getVariables(b.id, scriptCharacter)).value, {'card-variable': 'B'});
    expect((await h.bridge.getVariables(a.id, scriptChat)).value, {'local': 7});
    expect(h.engine.globalVariables, {
      'global': [1, null],
    });
    final fields = (await h.engine.characterFields(first))!;
    final container = scriptMap(scriptMap(fields['extensions'])['tavern_helper']);
    expect(container['unknown_container'], {'keep': true});
    final folder = scriptMap((container['scripts']! as List<Object?>).single);
    final savedScript = scriptMap((folder['scripts']! as List<Object?>).single);
    expect(folder['foreign_folder'], [1, null]);
    expect(savedScript['content'], '/* opaque; never executed by this test */');
    expect(savedScript['foreign_script'], {
      'keep': [1, false],
    });
    expect(savedScript['export_with'], {'data': true, 'button': false});
    expect(savedScript['button'], {
      'enabled': true,
      'buttons': [
        {'name': 'Go', 'visible': true},
      ],
    });
    final versionBeforeClose = (await h.bridge.getVariables(a.id, scriptOwner)).version;
    await h.reopen();
    final fresh = await h.context(chat, characterId: first, owner: ownerA);
    expect(fresh.engineEpoch, isNot(a.engineEpoch));
    expect((await h.bridge.getVariables(fresh.id, scriptOwner)).value, {'owner': 'A'});
    expect((await h.bridge.getVariables(fresh.id, scriptOwner)).version, isNot(versionBeforeClose));
    expect((await h.bridge.getVariables(fresh.id, targetMessage)).value, {
      'stat_data': {'hp': 9},
    });
    expect((await h.bridge.getVariables(fresh.id, scriptChat)).value, {'local': 7});
    for (final owner in [ownerB, ownerP, ownerG]) {
      final other = await h.context(
        chat,
        characterId: first,
        owner: owner,
        instanceId: 'reopened-${owner.kind.name}${owner.assetId ?? ''}',
      );
      final expected = owner == ownerB
          ? 'B'
          : owner == ownerP
          ? 'P'
          : 'G';
      expect((await h.bridge.getVariables(other.id, scriptOwner)).value, {'owner': expected});
    }
    h.expectNoGeneration();
    stdout.writeln('P2_SCRIPT_VARIABLES_READY');
  });

  test('path mutations preserve null presence and reject a whole invalid batch', () async {
    final h = await ScriptFixture.open();
    final character = await h.card('Variables');
    final chat = await h.emptyChat(character);
    final context = await h.context(chat, characterId: character);
    await h.bridge.replaceVariables(context.id, scriptChat, {
      'null': null,
      'false': false,
      'zero': 0,
      'empty': '',
      'array': [10, 20],
      'nested': {
        'a/b': {'~x': 1},
      },
    });
    final result = await h.bridge.mutateVariables(context.id, scriptChat, [
      for (final key in ['null', 'false', 'zero', 'empty'])
        TavernVariableChange(
          kind: TavernVariableChangeKind.insertIfAbsent,
          pathTokens: [key],
          value: 'must not replace',
        ),
      TavernVariableChange(kind: TavernVariableChangeKind.insertIfAbsent, pathTokens: ['new'], value: 7),
      TavernVariableChange(kind: TavernVariableChangeKind.set, pathTokens: ['nested', 'a/b', '~x'], value: 3),
      TavernVariableChange(kind: TavernVariableChangeKind.remove, pathTokens: ['array', 0]),
      TavernVariableChange(kind: TavernVariableChangeKind.remove, pathTokens: ['absent']),
      TavernVariableChange(kind: TavernVariableChangeKind.remove, pathTokens: ['null']),
    ]);
    expect(result.snapshot.value, {
      'false': false,
      'zero': 0,
      'empty': '',
      'array': [20],
      'nested': {
        'a/b': {'~x': 3},
      },
      'new': 7,
    });
    expect(result.results.take(4).map((r) => [r.existed, r.changed]), [
      [true, false],
      [true, false],
      [true, false],
      [true, false],
    ]);
    expect(result.results[4].existed, isFalse);
    expect(result.results[7].changed, isFalse);
    expect(result.results[8].existed, isTrue);
    final before = await h.bridge.getVariables(context.id, scriptChat);
    await expectLater(
      () => h.bridge.mutateVariables(context.id, scriptChat, [
        TavernVariableChange(kind: TavernVariableChangeKind.set, pathTokens: ['half'], value: 'must roll back'),
        TavernVariableChange(kind: TavernVariableChangeKind.set, pathTokens: ['array', 1.5], value: 4),
      ]),
      throwsA(scriptError(TavernScriptErrorCode.invalidArgument)),
    );
    final after = await h.bridge.getVariables(context.id, scriptChat);
    expect(after.value, before.value);
    expect(after.version, before.version);
    await h.bridge.replaceVariables(context.id, scriptChat, {});
    expect((await h.bridge.getVariables(context.id, scriptChat)).value, isEmpty);
    await h.reopen();
    final again = await h.context(chat, characterId: character);
    expect((await h.bridge.getVariables(again.id, scriptChat)).value, isEmpty);
    h.expectNoGeneration();
  });

  test('CAS sees native writes while updater runs once outside storage queues', () async {
    final h = await ScriptFixture.open();
    final character = await h.card('CAS');
    final chat = await h.emptyChat(character);
    final context = await h.context(chat, characterId: character);
    await h.bridge.replaceVariables(context.id, scriptGlobal, {'generation': 0});
    final old = await h.bridge.getVariables(context.id, scriptGlobal);
    await h.engine.setGlobalVariables({'generation': 1});
    await expectLater(
      () => h.bridge.replaceVariables(context.id, scriptGlobal, {'generation': 99}, expectedVersion: old.version),
      throwsA(scriptError(TavernScriptErrorCode.revisionConflict)),
    );
    expect(h.engine.globalVariables, {'generation': 1});
    final beforeAba = await h.bridge.getVariables(context.id, scriptGlobal);
    await h.engine.setGlobalVariables({'generation': 8});
    await h.engine.setGlobalVariables({'generation': 1});
    final afterAba = await h.bridge.getVariables(context.id, scriptGlobal);
    expect(afterAba.value, beforeAba.value);
    expect(
      afterAba.version,
      isNot(beforeAba.version),
      reason: 'A committed intervening change cannot recreate an earlier revision.',
    );
    await expectLater(
      () => h.bridge.replaceVariables(context.id, scriptGlobal, {'generation': 99}, expectedVersion: beforeAba.version),
      throwsA(scriptError(TavernScriptErrorCode.revisionConflict)),
    );
    final entered = Completer<void>();
    final release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) {
        release.complete();
      }
    });
    var calls = 0;
    final updating = h.bridge.updateVariablesWith(context.id, scriptGlobal, (value) async {
      calls++;
      expect(value, {'generation': 1});
      entered.complete();
      await release.future;
      return {'generation': 100};
    });
    final rejected = expectLater(updating, throwsA(scriptError(TavernScriptErrorCode.revisionConflict)));
    await entered.future;
    await h.engine.setGlobalVariables({'generation': 2});
    release.complete();
    await rejected;
    expect(calls, 1);
    expect(h.engine.globalVariables, {'generation': 2});
    final currentGlobal = await h.bridge.getVariables(context.id, scriptGlobal);
    await h.bridge.replaceVariables(context.id, scriptChat, {'unrelated': 4});
    await h.bridge.replaceVariables(context.id, scriptGlobal, {
      'generation': 3,
    }, expectedVersion: currentGlobal.version);
    expect(h.engine.globalVariables, {'generation': 3});
    // A native macro modifies the same persisted chat target and must invalidate
    // a token obtained by the bridge before that normal engine call.
    final oldChat = await h.bridge.getVariables(context.id, scriptChat);
    await h.engine.sendOnly(chat, '{{setvar::native::NATIVE}}body');
    await expectLater(
      () => h.bridge.replaceVariables(context.id, scriptChat, {'stale': true}, expectedVersion: oldChat.version),
      throwsA(scriptError(TavernScriptErrorCode.revisionConflict)),
    );
    expect((await h.bridge.getVariables(context.id, scriptChat)).value['native'], 'NATIVE');
    h.expectNoGeneration();
  });

  test('historical message observations retain physical values and committed ABA revisions', () async {
    final h = await ScriptFixture.open();
    final character = await h.card('Observed history', greeting: 'First message.');
    final chat = await h.engine.createChat(character);
    final first = (await h.engine.path(chat)).single;
    // A legacy physical checkpoint without a portable override is read after
    // reopen, before any bridge observation or managed write is admitted.
    await h.reopen(
      whileClosed: () async {
        h.inspect((db) {
          final row = db.select('SELECT full_json FROM node_states WHERE node_id = ?', [first.nodeId]).single;
          final state = scriptMap(jsonDecode(row['full_json'] as String));
          state['messageVariables'] = {'n': 1};
          db.execute('UPDATE node_states SET full_json = ? WHERE node_id = ?', [jsonEncode(state), first.nodeId]);
        }, writable: true);
      },
    );
    final context = await h.context(chat, characterId: character);
    final target = TavernVariableTarget(
      scope: TavernVariableScope.message,
      messageRef: TavernScriptMessageRef(chatId: chat, nodeId: first.nodeId),
    );
    final before = await h.bridge.getVariables(context.id, target);
    expect(before.value, {'n': 1});
    final oldView = await h.bridge.snapshot(context.id);
    await h.bridge.snapshot(context.id);
    await h.engine.sendOnly(chat, 'Later message.');
    expect((await h.bridge.getVariables(context.id, target)).version, before.version);
    await h.bridge.replaceVariables(context.id, target, {'n': 2}, expectedVersion: before.version);
    await h.bridge.replaceVariables(context.id, target, {'n': 1});
    final after = await h.bridge.getVariables(context.id, target);
    expect(after.value, before.value);
    expect(after.version, isNot(before.version));
    await expectLater(
      h.bridge.replaceVariables(context.id, target, {'stale': true}, expectedVersion: before.version),
      throwsA(scriptError(TavernScriptErrorCode.revisionConflict)),
    );
    expect((await h.bridge.getVariables(context.id, target)).version, after.version);
    expect(oldView.messages.single.data, {'n': 1});
    expect((await h.bridge.snapshot(context.id)).messages.first.data, {'n': 1});
    await h.bridge.deleteChatMessages(context.id, [0]);
    await expectLater(h.bridge.getVariables(context.id, target), throwsA(scriptError(TavernScriptErrorCode.notFound)));
    h.expectNoGeneration();
  });

  test('strict JSON is captured at call time and invalid values never partially save', () async {
    final h = await ScriptFixture.open();
    final character = await h.card('JSON');
    final chat = await h.emptyChat(character);
    final context = await h.context(chat, characterId: character);
    final input = <String, Object?>{
      'nested': <Object?>[
        1,
        <String, Object?>{'x': 2},
      ],
    };
    final writing = h.bridge.replaceVariables(context.id, scriptGlobal, input);
    (input['nested']! as List<Object?>).add('late');
    input['late'] = true;
    final result = await writing;
    expect(result.value, {
      'nested': [
        1,
        {'x': 2},
      ],
    });
    (result.value['nested']! as List<Object?>).clear();
    expect((await h.bridge.getVariables(context.id, scriptGlobal)).value, {
      'nested': [
        1,
        {'x': 2},
      ],
    });
    final before = await h.bridge.getVariables(context.id, scriptGlobal);
    final cycle = <String, Object?>{};
    cycle['self'] = cycle;
    final object = _JsonTrap();
    for (final bad in <Object?>[
      double.nan,
      double.infinity,
      <Object?, Object?>{1: 'non-string-key'},
      cycle,
      object,
      () => 1,
    ]) {
      await expectLater(
        () => h.bridge.replaceVariables(context.id, scriptGlobal, {'valid': 'must not save', 'bad': bad}),
        throwsA(scriptError(TavernScriptErrorCode.invalidJson)),
      );
      final actual = await h.bridge.getVariables(context.id, scriptGlobal);
      expect(actual.value, before.value);
      expect(actual.version, before.version);
    }
    expect(object.calls, 0, reason: 'Arbitrary toJson methods are outside standard JSON input.');
    h.expectNoGeneration();
  });

  test('real file failure rolls back while native settings and macro writes preserve committed globals', () async {
    final h = await ScriptFixture.open();
    final character = await h.card('File');
    final chat = await h.emptyChat(character);
    final context = await h.context(chat, characterId: character);
    final initial = await h.bridge.replaceVariables(context.id, scriptGlobal, {'saved': 'before'});
    final originalFile = await File('${h.root.path}/settings.json').readAsBytes();
    final blocker = Directory('${h.root.path}/settings.json.writing');
    await blocker.create();
    try {
      await expectLater(
        () => h.bridge.replaceVariables(context.id, scriptGlobal, {'saved': 'failed'}),
        throwsA(scriptError(TavernScriptErrorCode.storage).having((error) => error.committed, 'committed', isFalse)),
      );
      expect(await File('${h.root.path}/settings.json').readAsBytes(), originalFile);
      expect(h.engine.globalVariables, {'saved': 'before'});
      final actual = await h.bridge.getVariables(context.id, scriptGlobal);
      expect(actual.value, initial.value);
      expect(actual.version, initial.version);
    } finally {
      await blocker.delete(recursive: true);
    }
    // Both real writers are admitted without waiting for the preceding rename.
    // A native pre-encoded document must not restore the old global object.
    final bridgeWrite = h.bridge.replaceVariables(context.id, scriptGlobal, {'saved': 'after'});
    final nativeWrite = h.engine.setSettings({'userName': 'Native settings'});
    await bridgeWrite;
    await nativeWrite;
    final document = await h.settingsDocument();
    expect(document['globalVariables'], {'saved': 'after'});
    expect(scriptMap(document['settings'])['userName'], 'Native settings');
    expect(h.engine.globalVariables, {'saved': 'after'});
    await h.reopen();
    final fresh = await h.context(chat, characterId: character);
    expect((await h.bridge.getVariables(fresh.id, scriptGlobal)).value, {'saved': 'after'});

    // The real macro calls the injected RNG synchronously. Admit the bridge
    // replacement there, before the native macro mutates globals and queues
    // its own preparation save. This fixes queue order without sleeps or fake
    // filesystem work, and executes the production macro interpreter.
    final otherChat = await h.emptyChat(character);
    final macroBridge = Completer<TavernVariableSnapshot>();
    var randomCalls = 0;
    h.onRandom = () {
      randomCalls++;
      h.onRandom = null;
      macroBridge.complete(h.bridge.replaceVariables(fresh.id, scriptGlobal, {'bridge': 'persisted'}));
    };
    addTearDown(() {
      h.onRandom = null;
    });
    final narrating = h.engine.narrate(otherChat, '{{random::A::B}}{{setglobalvar::native::kept}}');
    await Future.wait<Object?>([narrating, macroBridge.future]);
    expect(randomCalls, 1);
    expect((await narrating).text, 'A');
    const merged = {'bridge': 'persisted', 'native': 'kept'};
    expect(h.engine.globalVariables, merged);
    expect((await h.settingsDocument())['globalVariables'], merged);
    final mergedSnapshot = await h.bridge.getVariables(fresh.id, scriptGlobal);
    expect(mergedSnapshot.value, merged);
    expect(mergedSnapshot.version, isNot((await macroBridge.future).version));
    h.expectNoGeneration();
    await h.reopen();
    final afterMacro = await h.context(chat, characterId: character);
    expect(h.engine.globalVariables, merged);
    expect((await h.bridge.getVariables(afterMacro.id, scriptGlobal)).value, merged);
    expect((await h.engine.path(otherChat)).single.text, 'A');

    // A partial bridge mutation admitted after a native write keeps native
    // keys it does not mention. Its queue callback merges that pending prefix
    // before applying the path plan once.
    final nativeFirstChat = await h.emptyChat(character);
    final pathBridge = Completer<TavernVariableMutation>();
    randomCalls = 0;
    h.onRandom = () {
      randomCalls++;
      h.onRandom = null;
      pathBridge.complete(
        h.bridge.mutateVariables(afterMacro.id, scriptGlobal, [
          TavernVariableChange(
            kind: TavernVariableChangeKind.insertIfAbsent,
            pathTokens: ['pathBridge'],
            value: 'inserted',
          ),
        ]),
      );
    };
    final nativeFirst = h.engine.narrate(nativeFirstChat, '{{setglobalvar::nativeBefore::kept}}{{random::A::B}}');
    await Future.wait<Object?>([nativeFirst, pathBridge.future]);
    expect(randomCalls, 1);
    expect((await nativeFirst).text, 'A');
    const pathMerged = {'bridge': 'persisted', 'native': 'kept', 'nativeBefore': 'kept', 'pathBridge': 'inserted'};
    expect((await pathBridge.future).snapshot.value, pathMerged);
    expect(h.engine.globalVariables, pathMerged);
    expect((await h.settingsDocument())['globalVariables'], pathMerged);

    // These two native operations are intents even though, at execution time,
    // the live value is already 'old' and removeMe is absent. Both must survive
    // the earlier queued replacement without re-running the real macro/RNG.
    await h.bridge.replaceVariables(afterMacro.id, scriptGlobal, {'same': 'old'});
    final intentChat = await h.emptyChat(character);
    final intentBridge = Completer<TavernVariableSnapshot>();
    randomCalls = 0;
    h.onRandom = () {
      randomCalls++;
      h.onRandom = null;
      intentBridge.complete(h.bridge.replaceVariables(afterMacro.id, scriptGlobal, {'same': 'new', 'removeMe': 'new'}));
    };
    final intents = h.engine.narrate(
      intentChat,
      '{{random::A::B}}{{setglobalvar::same::old}}{{deleteglobalvar::removeMe}}',
    );
    await Future.wait<Object?>([intents, intentBridge.future]);
    expect(randomCalls, 1);
    expect((await intents).text, 'A');
    expect((await intentBridge.future).value, {'same': 'new', 'removeMe': 'new'});
    expect(h.engine.globalVariables, {'same': 'old'});
    expect((await h.settingsDocument())['globalVariables'], {'same': 'old'});
    expect((await h.bridge.getVariables(afterMacro.id, scriptGlobal)).value, {'same': 'old'});
    h.expectNoGeneration();
    await h.reopen();
    final afterIntents = await h.context(chat, characterId: character);
    expect(h.engine.globalVariables, {'same': 'old'});
    expect((await h.bridge.getVariables(afterIntents.id, scriptGlobal)).value, {'same': 'old'});
    expect((await h.engine.path(nativeFirstChat)).single.text, 'A');
    expect((await h.engine.path(intentChat)).single.text, 'A');
    h.expectNoGeneration();
  });

  test('historical missing null and array message data stay distinguishable until explicit repair', () async {
    final h = await ScriptFixture.open();
    final character = await h.card('Imported');
    final document = StChatDocument(
      fileName: 'shapes.jsonl',
      header: {'user_name': 'User', 'character_name': 'Imported', 'chat_metadata': <String, Object?>{}},
      messages: [
        {
          'name': 'User',
          'is_user': true,
          'is_system': false,
          'mes': 'missing',
          'send_date': '2026-11-12T05:00:00Z',
          'extra': <String, Object?>{},
        },
        {
          'name': 'Imported',
          'is_user': false,
          'is_system': false,
          'mes': 'valid',
          'send_date': '2026-11-12T05:00:01Z',
          'extra': <String, Object?>{},
          'swipe_id': 2,
          'swipes': ['null page', 'array page', 'valid'],
          'variables': <Object?>[
            null,
            <Object?>['raw-array'],
            <String, Object?>{'good': 1},
          ],
        },
      ],
    );
    final chat = (await h.engine.importChats(character, [
      TavernChatFile(fileName: document.fileName, bytes: document.encode()),
    ])).chatIds.single;
    final context = await h.context(chat, characterId: character);
    final page = await h.bridge.getChatMessages(context.id, const TavernMessageRange(), includeSwipes: true);
    expect(page.messages.first.hasData, isFalse);
    expect(page.messages.first.data, isEmpty);
    final swipes = page.messages.last.swipes;
    expect(swipes, hasLength(3));
    expect(swipes[0].hasData, isTrue);
    expect(swipes[0].rawData, isNull);
    expect(swipes[0].data, isNull);
    expect(swipes[0].dataIssue, isNotNull);
    expect(swipes[1].rawData, ['raw-array']);
    expect(swipes[1].data, isNull);
    expect(swipes[1].dataIssue, isNotNull);
    expect(swipes[2].data, {'good': 1});
    for (final swipe in swipes.take(2)) {
      await expectLater(
        () => h.bridge.getVariables(
          context.id,
          TavernVariableTarget(scope: TavernVariableScope.message, messageRef: swipe.ref),
        ),
        throwsA(scriptError(TavernScriptErrorCode.shapeMismatch)),
      );
    }
    final repaired = await h.bridge.replaceVariables(
      context.id,
      TavernVariableTarget(scope: TavernVariableScope.message, messageRef: swipes[0].ref),
      {'fixed': 0},
    );
    expect(repaired.value, {'fixed': 0});
    expect((await h.bridge.getVariables(context.id, scriptMessage)).value, {'good': 1});
    final exported = (await h.engine.exportChat(chat)).single;
    final out = StChatDocument.decode(exported.fileName, exported.bytes);
    expect(out.messages.last['variables'], [
      {'fixed': 0},
      ['raw-array'],
      {'good': 1},
    ]);
    await h.reopen();
    final fresh = await h.context(chat, characterId: character);
    final again = await h.bridge.getChatMessages(fresh.id, const TavernMessageRange(), includeSwipes: true);
    expect(again.messages.last.ref, swipes[2].ref);
    expect(again.messages.last.swipes[0].data, {'fixed': 0});
    expect(again.messages.last.swipes[1].rawData, ['raw-array']);
    h.expectNoGeneration();
  });

  test('message data shares DSH validation while ordinary sibling writes preserve runtime', () async {
    final h = await ScriptFixture.open();
    final character = await h.card('State', greeting: 'state greeting', extensions: scriptStateExtension());
    final chat = await h.engine.createChat(character);
    final context = await h.context(chat, characterId: character);
    final initial = await h.bridge.getVariables(context.id, scriptMessage);
    expect(initial.value['dshgo'], {'count': 0});
    final withMvu = <String, Object?>{
      ...initial.value,
      'stat_data': {'hp': 3},
      'vendor': [false, null],
    };
    await h.bridge.replaceVariables(context.id, scriptMessage, withMvu);
    final beforeRejected = await h.bridge.getVariables(context.id, scriptMessage);
    await expectLater(
      () => h.bridge.replaceVariables(context.id, scriptMessage, {
        'stat_data': {'hp': 99},
      }),
      throwsA(
        scriptError(TavernScriptErrorCode.stateValidation).having((error) => error.committed, 'committed', isFalse),
      ),
    );
    expect((await h.bridge.getVariables(context.id, scriptMessage)).value, beforeRejected.value);
    final changed = await h.bridge.replaceVariables(context.id, scriptMessage, {
      ...withMvu,
      'dshgo': {'count': 999},
      'stat_data': {'hp': 4},
    });
    expect(changed.value['dshgo'], {'count': 5});
    expect(changed.value['stat_data'], {'hp': 4});
    expect(changed.stateEdit, isNotNull);
    expect(changed.stateEdit!.applied, isTrue);
    expect(changed.stateEdit!.snapshot.effects.single['text'], 'script-rule-once');
    final beforeOrdinary = await _savedState(h, chat);
    await h.bridge.replaceVariables(context.id, scriptMessage, {
      ...changed.value,
      'stat_data': {'hp': 8},
    });
    final afterOrdinary = await _savedState(h, chat);
    for (final key in beforeOrdinary.keys.where((key) => key != 'messageVariables')) {
      expect(afterOrdinary[key], beforeOrdinary[key], reason: key);
    }
    expect(scriptMap(afterOrdinary['messageVariables'])['stat_data'], {'hp': 8});
    final next = await h.bridge.replaceVariables(context.id, scriptMessage, {
      ...changed.value,
      'dshgo': {'count': 999},
      'stat_data': {'hp': 9},
    });
    expect(next.value['dshgo'], {'count': 10}, reason: 'Each user edit has a fresh step invocation.');
    expect(next.stateEdit!.snapshot.effects, isEmpty, reason: 'The once rule ledger survives ordinary data writes.');
    await h.reopen();
    final fresh = await h.context(chat, characterId: character);
    expect((await h.bridge.getVariables(fresh.id, scriptMessage)).value['dshgo'], {'count': 10});
    expect((await h.bridge.getVariables(fresh.id, scriptMessage)).value['stat_data'], {'hp': 9});
    h.expectNoGeneration();
  });

  test('a user updater may close the engine without being retained as storage IO', () async {
    final h = await ScriptFixture.open();
    final character = await h.card('Close updater');
    final chat = await h.emptyChat(character);
    final context = await h.context(chat, characterId: character);
    final bridge = h.bridge;
    await bridge.replaceVariables(context.id, scriptGlobal, {'kept': true});
    var calls = 0;
    final actuallyClosed = Completer<void>();
    final updating = bridge.updateVariablesWith(context.id, scriptGlobal, (value) async {
      calls++;
      await h.close();
      actuallyClosed.complete();
      return {'late': 'must not save after close'};
    });
    await expectLater(updating, throwsA(isA<TavernScriptException>()));
    expect(calls, 1);
    await actuallyClosed.future;
    await h.openEngine();
    expect(h.engine.globalVariables, {'kept': true});
    h.expectNoGeneration();
  });
}

class _JsonTrap {
  int calls = 0;
  Object toJson() {
    calls++;
    return {'converted': true};
  }
}

Future<ScriptJson> _savedState(ScriptFixture h, String chat) async {
  final files = await h.engine.exportChat(chat);
  final document = StChatDocument.decode(files.first.fileName, files.first.bytes);
  final saved = scriptMap(scriptMap(scriptMap(document.messages.last['extra'])['dshgo'])['tavernState']);
  return scriptMap(jsonDecode(jsonEncode(saved)));
}
