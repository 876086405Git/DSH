import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_script_test_support.dart';

const _current = TavernScriptPresetRef.current();
const _deadline = Duration(seconds: 10);
final _at = DateTime.utc(2026, 11, 14, 12);

// Real preset SQL, settings files, native requests, C2 capture and the C7
// temporary engine. HTTP response bodies and the App acknowledgement are the
// only supplied peers; no private writer or replacement assembler is used.
void main() {
  test('current ownership, stored edits and explicit reload retain their actual carriers', () async {
    final h = await ScriptFixture.open();
    final character = await h.card('Preset reader', greeting: 'Hello.');
    final chat = await h.engine.createChat(character);
    final boundChat = await h.engine.createChat(character);
    final id = (await h.engine.presetSelection()).effectivePresetId!;
    await h.engine.bindPreset(boundChat, id);
    await h.engine.setSettings({
      'presetOverrides': {'temperature': 0.2},
    });
    final original = (await h.engine.preset(id))!;
    final storedRef = TavernScriptPresetRef.stored(id);
    final acknowledged = <TavernScriptPresetSnapshot>[];
    final host = ScriptHost();
    host.onDispatch = (request, cancellation) async {
      if (request.kind == TavernScriptDispatchKind.cache &&
          request.delta?.resourceRefs.containsKey('presetLibrary') == true) {
        // The writer must have released its preset queue before waiting for
        // this actual cache acknowledgement to read the changed stored row.
        acknowledged.add(await h.bridge.readPreset(request.contextId, storedRef));
      }
      return TavernScriptDispatchAck(eventId: request.eventId);
    };
    h.bridge.attachHost(host);
    final global = await h.bridge.openContext(const TavernScriptContextSpec(instanceId: 'preset-global'));
    final scoped = await h.context(chat, characterId: character, instanceId: 'preset-chat');
    final bound = await h.context(boundChat, characterId: character, instanceId: 'preset-bound');
    final before = await h.bridge.readPreset(global.id, _current);
    expect(before.raw['temperature'], 0.2);
    expect(before.source, {
      'kind': 'current',
      'scope': 'global',
      'loadedSource': 'globalDefault',
      'loadedPresetId': id,
      'working': false,
    });

    final globalWorking = await h.bridge
        .replacePreset(global.id, _current, _preset(0.9, 'GLOBAL_WORKING'), expectedVersion: before.version)
        .timeout(_deadline);
    expect(globalWorking.raw['temperature'], 0.9);
    expect(globalWorking.source['working'], isTrue);
    expect((await h.bridge.readPreset(scoped.id, _current)).raw['temperature'], 0.9);
    expect(
      (await h.bridge.readPreset(bound.id, _current)).raw['temperature'],
      0.2,
      reason: 'An explicit binding to the same saved ID does not inherit global working raw.',
    );
    expect((await h.bridge.readPreset(bound.id, _current)).source['loadedSource'], 'chat');

    const regexTarget = TavernScriptRegexWriteTarget.preset(preset: _current);
    final regex = await h.bridge.readTavernRegexesForWrite(scoped.id, regexTarget);
    await h.bridge
        .replaceTavernRegexes(scoped.id, regexTarget, [
          TavernScriptRegexWriteItem(
            raw: {
              'id': 'working-rule',
              'scriptName': 'Only the regex list changes',
              'findRegex': '/unused/g',
              'replaceString': 'unused',
              'placement': [2],
              'disabled': true,
            },
          ),
        ], expectedVersion: regex.version)
        .timeout(_deadline);
    final regexOnly = await h.bridge.readPreset(scoped.id, _current);
    expect(
      regexOnly.raw['temperature'],
      0.9,
      reason: 'The empty chat ownership set must not revive the older inherited 0.2 override.',
    );
    expect(scriptMap(regexOnly.raw['extensions'])['regex_scripts'], hasLength(1));
    expect((await h.bridge.readPreset(global.id, _current)).raw['extensions'], isNull);
    expect((await h.bridge.readPreset(global.id, storedRef)).raw, original.raw);
    await expectLater(
      h.bridge.replacePreset(global.id, _current, _preset(0.1, 'STALE'), expectedVersion: before.version),
      throwsA(scriptError(TavernScriptErrorCode.revisionConflict)),
    );

    await h.engine.setSettings({
      'presetOverrides': {'temperature': 0.6},
    }, chatId: chat);
    expect((await h.bridge.readPreset(scoped.id, _current)).raw['temperature'], 0.6);
    final beforeChat = await h.bridge.readPreset(scoped.id, _current);
    await h.bridge.replacePreset(
      scoped.id,
      _current,
      _preset(0.8, 'CHAT_WORKING'),
      expectedVersion: beforeChat.version,
    );
    await h.engine.setSettings({
      'presetOverrides': {'temperature': 0.3},
    });
    expect((await h.bridge.readPreset(global.id, _current)).raw['temperature'], 0.3);
    expect(
      (await h.bridge.readPreset(scoped.id, _current)).raw['temperature'],
      0.8,
      reason: 'A global edit cannot release ownership hidden by an explicit chat override.',
    );
    await h.engine.setSettings({
      'presetOverrides': {'temperature': 0.6},
    }, chatId: chat);
    expect(
      (await h.bridge.readPreset(scoped.id, _current)).raw['temperature'],
      0.6,
      reason: 'An explicit same-value UI write is still the later write.',
    );
    await h.engine.setSettings({'presetOverrides': null}, chatId: chat);
    expect(
      (await h.bridge.readPreset(scoped.id, _current)).raw['temperature'],
      0.8,
      reason: 'Clearing the entire override carrier reveals working raw, not the old UI value.',
    );

    final libraryBefore = scriptMap((await h.bridge.snapshot(scoped.id)).resourceRefs['presetLibrary']);
    final savedBefore = await h.bridge.readPreset(global.id, storedRef);
    final savedRaw = savedBefore.raw
      ..['temperature'] = 0.5
      ..['saved_unknown'] = {
        'keep': [1, false, null],
      };
    final saved = await h.bridge
        .replacePreset(global.id, storedRef, savedRaw, expectedVersion: savedBefore.version)
        .timeout(_deadline);
    expect(saved.source, {'kind': 'stored', 'presetId': id});
    expect(saved.raw['temperature'], 0.5);
    expect((await h.engine.preset(id))!.sourceText, original.sourceText);
    expect((await h.engine.preset(id))!.envelope, original.envelope);
    final currentAfterSaved = await h.bridge.readPreset(scoped.id, _current);
    expect(currentAfterSaved.raw['foreign'], {
      'label': 'CHAT_WORKING',
      'keep': [null, true],
    });
    expect(currentAfterSaved.raw['temperature'], 0.8);
    final snapshot = await h.bridge.snapshot(scoped.id);
    final cached = scriptMap(snapshot.resourceRefs['preset']);
    expect(cached['raw'], currentAfterSaved.raw);
    expect(cached['source'], currentAfterSaved.source);
    expect(cached['version'], currentAfterSaved.version);
    final libraryAfter = scriptMap(snapshot.resourceRefs['presetLibrary']);
    expect(libraryAfter['version'], isNot(libraryBefore['version']));
    expect(
      (libraryAfter['presets']! as List<Object?>).map(scriptMap).singleWhere((row) => row['id'] == id)['name'],
      original.name,
    );
    expect(
      acknowledged.any((value) => value.raw['saved_unknown'] is Map<String, Object?>),
      isTrue,
      reason: 'The actual cache Ack reentered the released writer and read the new stored raw.',
    );

    final boundBefore = await h.bridge.readPreset(bound.id, _current);
    await h.bridge.replacePreset(
      bound.id,
      _current,
      _preset(0.7, 'BOUND_WORKING'),
      expectedVersion: boundBefore.version,
    );
    await h.engine.setDefaultPreset(id);
    expect((await h.bridge.readPreset(global.id, _current)).source['working'], isFalse);
    expect((await h.bridge.readPreset(scoped.id, _current)).raw['temperature'], 0.5);
    expect(
      (await h.bridge.readPreset(bound.id, _current)).raw['temperature'],
      0.7,
      reason: 'Reloading the global default does not discard an explicitly bound chat slot.',
    );
    await h.engine.bindPreset(boundChat, id);
    expect((await h.bridge.readPreset(bound.id, _current)).source['working'], isFalse);
    expect((await h.bridge.readPreset(bound.id, _current)).raw['temperature'], 0.3);

    final reset = await h.bridge.readPreset(global.id, _current);
    await h.bridge.replacePreset(global.id, _current, _preset(0.95, 'RAM_ONLY'), expectedVersion: reset.version);
    final settingsFile = File('${h.root.path}/settings.json');
    final disk = await settingsFile.readAsBytes();
    final blocker = Directory('${settingsFile.path}.writing');
    await blocker.create();
    try {
      await expectLater(
        h.engine.setSettings({
          'presetOverrides': {'temperature': 0.45},
        }),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        (await h.bridge.readPreset(global.id, _current)).raw['temperature'],
        0.45,
        reason: 'The existing global setter adopts RAM before its failed disk write.',
      );
      expect(await settingsFile.readAsBytes(), disk);
    } finally {
      await blocker.delete();
    }
    h.bridge.attachHost(null);
    await h.reopen();
    final reopened = await h.bridge.openContext(const TavernScriptContextSpec(instanceId: 'preset-reopened'));
    final reopenedCurrent = await h.bridge.readPreset(reopened.id, _current);
    expect(reopenedCurrent.source['working'], isFalse);
    expect(reopenedCurrent.raw['temperature'], 0.3);
    expect((await h.bridge.readPreset(reopened.id, storedRef)).raw['saved_unknown'], {
      'keep': [1, false, null],
    });
    h.expectNoGeneration();
  });

  test('C2, admitted native turns and C7 use their captured working preset', () async {
    final h = await ScriptFixture.open(allowModel: true);
    final character = await h.card('Captured preset', greeting: 'Quiet greeting.');
    final chat = await h.engine.createChat(character);
    final id = (await h.engine.presetSelection()).effectivePresetId!;
    await h.engine.setSettings({
      'presetOverrides': {'temperature': 0.2},
    });
    final global = await h.bridge.openContext(const TavernScriptContextSpec(instanceId: 'capture-global'));
    final scoped = await h.context(chat, characterId: character, instanceId: 'capture-chat');
    final globalBefore = await h.bridge.readPreset(global.id, _current);
    await h.bridge.replacePreset(
      global.id,
      _current,
      _preset(0.9, 'GLOBAL_CAPTURED'),
      expectedVersion: globalBefore.version,
    );
    final chatBefore = await h.bridge.readPreset(scoped.id, _current);
    await h.bridge.replacePreset(
      scoped.id,
      _current,
      _preset(0.75, 'CHAT_CAPTURED'),
      expectedVersion: chatBefore.version,
    );
    final draft0 = await h.engine.createAuthoringDraft([
      TavernAuthoringTarget(kind: TavernAuthoringTargetKind.character, id: character),
      TavernAuthoringTarget(kind: TavernAuthoringTargetKind.preset, id: id),
    ]);
    final draft = await h.engine.editAuthoringDraft(
      draft0.id,
      draftRevision: draft0.draftRevision,
      changes: [
        TavernAuthoringChange(
          id: 'preset-candidate',
          physicalResourceId: 'preset:$id',
          path: '/raw',
          operation: TavernAuthoringChangeKind.set,
          value: _preset(0.15, 'SAVED_DRAFT_CANDIDATE'),
        ),
      ],
    );
    final beforePreview = _rows(h);
    final settingsBytes = await File('${h.root.path}/settings.json').readAsBytes();
    final preview = await h.engine
        .previewAuthoringPrompt(
          TavernAuthoringPromptRequest(
            requestId: 'working-c2',
            draftId: draft.id,
            draftRevision: draft.draftRevision,
            changeIds: const ['preset-candidate'],
            context: TavernAuthoringChatContext(chatId: chat),
            text: 'Question one.',
            at: _at,
            seed: 31,
          ),
        )
        .result
        .timeout(_deadline);
    expect(preview.status, TavernAuthoringPreviewStatus.complete);
    expect(preview.assembly!.body['temperature'], 0.75);
    expect(_prompt(preview.assembly!.body), contains('CHAT_CAPTURED'));
    expect(_prompt(preview.assembly!.body), isNot(contains('SAVED_DRAFT_CANDIDATE')));
    expect(scriptMap(preview.origin['presetWorking'])['chat'], isTrue);
    expect(_rows(h), beforePreview);
    expect(await File('${h.root.path}/settings.json').readAsBytes(), settingsBytes);
    h.expectNoGeneration();

    final native = h.reply('FIRST_NATIVE_REPLY');
    native.beforeResponse = () async {
      final current = await h.bridge.readPreset(scoped.id, _current);
      await h.bridge.replacePreset(scoped.id, _current, _preset(0.65, 'CHAT_LATER'), expectedVersion: current.version);
    };
    final firstEvents = await h.engine.send(chat, 'Question one.').toList().timeout(_deadline);
    expect(firstEvents.whereType<TavernTurnFailed>(), isEmpty);
    expect(firstEvents.whereType<TavernTurnDone>().single.message.text, 'FIRST_NATIVE_REPLY');
    expect(h.requests.single.body['temperature'], 0.75);
    expect(_prompt(h.requests.single.body), contains('CHAT_CAPTURED'));
    expect((await h.bridge.readPreset(scoped.id, _current)).raw['temperature'], 0.65);

    final beforeSimulation = _rows(h);
    final firstSimulation = h.reply('SIMULATED_ONE');
    h.reply('SIMULATED_TWO');
    firstSimulation.beforeResponse = () async {
      final current = await h.bridge.readPreset(global.id, _current);
      await h.bridge.replacePreset(
        global.id,
        _current,
        _preset(0.55, 'GLOBAL_LATER'),
        expectedVersion: current.version,
      );
    };
    final simulation = await h.engine
        .simulateAuthoringDraft(
          TavernAuthoringSimulationRequest(
            requestId: 'working-c7',
            draftId: draft.id,
            draftRevision: draft.draftRevision,
            changeIds: const ['preset-candidate'],
            context: TavernAuthoringSampleContext(characterResourceId: 'character:$character'),
            userInputs: const ['Sample one.', 'Sample two.'],
            at: _at,
            seed: 31,
          ),
        )
        .result
        .timeout(_deadline);
    expect(simulation.status, TavernAuthoringSimulationStatus.completed);
    expect(simulation.requests, hasLength(2));
    for (final request in simulation.requests) {
      expect(request.body['temperature'], 0.9);
      expect(_prompt(request.body), contains('GLOBAL_CAPTURED'));
      expect(_prompt(request.body), isNot(contains('GLOBAL_LATER')));
      expect(_prompt(request.body), isNot(contains('SAVED_DRAFT_CANDIDATE')));
    }
    expect(_prompt(simulation.requests.last.body), contains('SIMULATED_ONE'));
    expect(simulation.cleanup, {'rootCreated': true, 'closeConfirmed': true, 'removed': true});
    expect(_rows(h), beforeSimulation);
    expect(await File('${h.root.path}/settings.json').readAsBytes(), settingsBytes);
    expect((await h.bridge.readPreset(global.id, _current)).raw['temperature'], 0.55);
    expect((await h.bridge.readPreset(scoped.id, _current)).raw['temperature'], 0.65);

    h.reply('SECOND_NATIVE_REPLY');
    final secondEvents = await h.engine.send(chat, 'Question two.').toList().timeout(_deadline);
    expect(secondEvents.whereType<TavernTurnFailed>(), isEmpty);
    expect(h.requests, hasLength(4));
    expect(h.requests.last.body['temperature'], 0.65);
    expect(_prompt(h.requests.last.body), contains('CHAT_LATER'));
    expect(_prompt(h.requests.last.body), isNot(contains('GLOBAL_LATER')));
    expect((await h.engine.preset(id))!.raw['temperature'], 0.4);
  });
}

ScriptJson _preset(num temperature, String label) => scriptPreset(main: label).raw
  ..['temperature'] = temperature
  ..['foreign'] = {
    'label': label,
    'keep': [null, true],
  };

String _prompt(Map<String, Object?> body) =>
    (body['messages']! as List<Object?>).map(scriptMap).map((message) => message['content']).join('\n');

// SELECT * also works for the existing WITHOUT ROWID FTS configuration table.
// Reads compare all logical data, not SQLite WAL/shm file bytes.
ScriptJson _rows(ScriptFixture h) => h.inspect((db) {
  final result = <String, Object?>{};
  for (final table in db.select("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")) {
    final name = table['name']! as String;
    final quoted = name.replaceAll('"', '""');
    result[name] = [for (final row in db.select('SELECT * FROM "$quoted"')) Map<String, Object?>.from(row)];
  }
  return result;
});
