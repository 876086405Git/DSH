import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_script_generation_test_support.dart';

final _at = DateTime.utc(2026, 11, 12, 5);
const _deadline = Duration(seconds: 10);

// Real SQLite, files, regex worker and production model transport. Only the
// model response and one actual file read are controlled by these fixtures.
void main() {
  test('captured preparation matches native assembly without adopting macros, resources or a turn', () async {
    final h = await generationFixture();
    final character = await h.card('Guide', description: 'FIELD={{getvar::step}}');
    await h.engine.addCharacterBookEntry(character, {
      'keys': <String>[],
      'content': 'EMBEDDED_DETAIL',
      'enabled': true,
      'constant': true,
      'insertion_order': 100,
      'extensions': {'position': 0},
    });
    final chat = await _chat(
      h,
      character,
      metadata: {
        'variables': {'step': 0},
      },
      messages: [
        _message('ROOT={{incvar::step}}'),
        _message('An earlier question.', user: true),
        _message('UNSELECTED_OLD_REPLY'),
      ],
    );
    final imported = await h.engine.path(chat);
    await h.engine.selectNode(chat, imported[1].nodeId);
    await h.engine.setPreset(
      scriptPreset(main: 'MAIN_STEP={{getvar::step}} SWIPES={{currentSwipeId}}/{{lastSwipeId}}'),
    );
    await h.engine.importRegexScripts(
      jsonEncode([
        _regex('input', r'/^ENTER$/', '{{setvar::step::1}}USER_TEXT', 1),
        _regex('history', r'/^ROOT=(\d+)$/', r'PROMPT_ROOT=$1', 2, promptOnly: true),
      ]),
    );
    final persona = await h.engine.createPersona(name: 'Reader', description: 'PERSONA_DETAIL');
    await h.engine.bindPersona(chat, persona.id);
    await h.engine.putLorebook('global', _book('GLOBAL_BASE', key: 'USER_TEXT'));
    await h.engine.putLorebook('chat', _book('CHAT_DETAIL'));
    await h.engine.putLorebook('character', _book('CHARACTER_DETAIL'));
    await h.engine.putLorebook('persona', _book('PERSONA_BOOK_DETAIL'));
    await h.engine.bindLorebooks(['global', 'missing-book']);
    await h.engine.bindLorebooks(['chat'], source: WorldInfoSource.chat, chatId: chat);
    await h.engine.bindLorebooks(['character'], source: WorldInfoSource.character, characterId: character);
    await h.engine.bindLorebooks(['persona'], source: WorldInfoSource.persona, personaId: persona.id);
    final base = await h.engine.createAuthoringDraft([_bookTarget('global')]);
    final draft = await h.engine.editAuthoringDraft(
      base.id,
      draftRevision: base.draftRevision,
      changes: [
        const TavernAuthoringChange(
          id: 'global-content',
          physicalResourceId: 'lorebook:global',
          path: '/entries/0/content',
          operation: TavernAuthoringChangeKind.set,
          value: 'GLOBAL_SELECTED',
        ),
      ],
    );
    final database = _databaseState(h);
    final files = await _persistentFiles(h.root);
    final variables = await h.engine.readVariables(chat);
    final globals = h.engine.globalVariables;
    var randomCalls = 0;
    h.onRandom = () {
      randomCalls++;
    };

    final invalidContinue = await _preview(
      h,
      draft,
      'continue-rejects-text',
      TavernAuthoringChatContext(chatId: chat, nodeId: imported[2].nodeId, generationType: 'continue'),
      text: 'A continuation has no new user input.',
    );
    expect(invalidContinue.status, TavernAuthoringPreviewStatus.failed);
    expect(invalidContinue.assembly, isNull);
    expect(invalidContinue.issues.single.type, 'invalid_change');

    final preview = await _preview(
      h,
      draft,
      'native-equivalence',
      TavernAuthoringChatContext(chatId: chat),
      text: 'ENTER',
      changes: ['global-content'],
    );
    expect(preview.status, TavernAuthoringPreviewStatus.complete);
    expect(preview.origin['sealed'], isTrue);
    final text = _promptText(preview.assembly!.body);
    for (final expected in [
      'FIELD=1',
      'MAIN_STEP=2',
      'SWIPES=2/2',
      'PROMPT_ROOT=2',
      'USER_TEXT',
      'GLOBAL_SELECTED',
      'CHAT_DETAIL',
      'CHARACTER_DETAIL',
      'PERSONA_BOOK_DETAIL',
      'EMBEDDED_DETAIL',
      'PERSONA_DETAIL',
    ]) {
      expect(text, contains(expected));
    }
    expect(text, isNot(contains('GLOBAL_BASE')));
    expect(text, isNot(contains('UNSELECTED_OLD_REPLY')));
    expect(
      (preview.worldInfo['missing']! as List<Object?>).map(scriptMap).any((entry) => entry['bookId'] == 'missing-book'),
      isTrue,
    );
    expect(
      preview.regexTrace.any(
        (trace) => trace['source'] == 'userInput' && trace['input'] == 'ENTER' && trace['output'] == 'USER_TEXT',
      ),
      isTrue,
    );
    expect(_databaseState(h), database);
    expect(await _persistentFiles(h.root), files);
    expect(await h.engine.readVariables(chat), variables);
    expect(h.engine.globalVariables, globals);
    expect((await h.engine.path(chat)).first.text, 'ROOT={{incvar::step}}');
    expect(await h.engine.inspectTurn(chat), isNull);
    expect(randomCalls, 0);
    h.expectNoGeneration();

    // The saved candidate remains the preview overlay if its live book is
    // absent. Current absence is separate captured evidence, never an observe.
    final bookFile = File('${h.root.path}/lorebooks/global.json');
    final bookBytes = await bookFile.readAsBytes();
    try {
      await bookFile.delete();
      final absentFiles = await _persistentFiles(h.root);
      final absent = await _preview(
        h,
        draft,
        'saved-book-without-live-file',
        TavernAuthoringChatContext(chatId: chat),
        text: 'ENTER',
        changes: ['global-content'],
      );
      expect(absent.status, TavernAuthoringPreviewStatus.complete);
      expect(absent.assembly!.body, preview.assembly!.body);
      expect(_promptText(absent.assembly!.body), contains('GLOBAL_SELECTED'));
      final origin = (absent.origin['resources']! as List<Object?>)
          .map(scriptMap)
          .singleWhere((resource) => resource['physicalResourceId'] == 'lorebook:global');
      expect(scriptMap(origin['capturedSnapshot'])['present'], isFalse);
      expect(scriptMap(origin['candidate'])['origin'], 'draft');
      expect(_databaseState(h), database);
      expect(await _persistentFiles(h.root), absentFiles);
      h.expectNoGeneration();
    } finally {
      await bookFile.writeAsBytes(bookBytes);
    }

    // Adopt only after proving that preparation itself wrote nothing. Native
    // send then sees exactly the selected candidate that the preview used.
    final applied = await h.engine.applyAuthoringChanges(
      draft.id,
      draftRevision: draft.draftRevision,
      physicalResourceId: 'lorebook:global',
      changeIds: ['global-content'],
      expectedAuthorityRevision: base.sources.single.authorityRevision!,
      operationId: 'preview-equivalence-adopt',
    );
    expect(applied.committed, isTrue);
    h.reply('The native reply.');
    final events = await h.engine.send(chat, 'ENTER').toList();
    expect(events.whereType<TavernTurnFailed>(), isEmpty);
    final native = (await h.engine.inspectTurn(chat))!;
    expect(preview.assembly!.body, native.prompt!.body);
    expect((await h.engine.path(chat)).first.text, 'ROOT=2');
    expect((await h.engine.readVariables(chat))['step'], 2);
  });

  test(
    'group input prepares the selected actor user before its empty-input child without adopting the branch',
    () async {
      final h = await generationFixture();
      final host = await h.card('Host');
      final actor = await h.card(
        'Actor',
        description: 'FIELD={{getvar::step}} INPUT=[{{input}}] RANDOM={{random::red::green::blue}}',
        extensions: {'world': 'Actor world'},
      );
      await h.engine.putLorebook('actor-world', {..._book('AUTOMATIC_ACTOR_WORLD'), 'name': 'Actor world'});
      final other = await h.card('Other');
      final chat = await h.engine.createGroupChat([actor, other], hostCharacterId: host, addGreetings: false);
      // Native explicit selection can choose a muted actor. Preview must use
      // that actor for USER_INPUT, rather than the host or automatic selection.
      await h.engine.updateGroupMember(chat, actor, muted: true);
      await h.engine.setPreset(scriptPreset(main: 'MAIN {{char}} {{group}} {{groupNotMuted}}'));
      await h.engine.importRegexScripts(
        jsonEncode(
          _regex(
            'group-user',
            r'/^ENTER$/',
            '{{setvar::step::1}}{{setglobalvar::scratch::local}}GROUP_{{char}}_{{random::one::two::three}}',
            1,
          ),
        ),
      );
      final base = await h.engine.createAuthoringDraft([_characterTarget(host)]);
      final draft = await h.engine.editAuthoringDraft(
        base.id,
        draftRevision: base.draftRevision,
        changes: [
          TavernAuthoringChange(
            id: 'host-state',
            physicalResourceId: 'character:$host',
            path: '/data/extensions/dshgo',
            operation: TavernAuthoringChangeKind.set,
            value: {
              'v': 1,
              'state': {
                'schema': {
                  'type': 'object',
                  'properties': {
                    'n': {'type': 'integer', 'default': 7},
                  },
                },
                'init': {'n': 7},
              },
            },
          ),
        ],
      );
      final database = _databaseState(h);
      final files = await _persistentFiles(h.root);
      final globals = h.engine.globalVariables;
      var liveRandomCalls = 0;
      h.onRandom = () {
        liveRandomCalls++;
      };
      final context = TavernAuthoringChatContext(chatId: chat, actorId: actor);
      final preview = await _preview(h, draft, 'group-first-child', context, text: 'ENTER', changes: ['host-state']);
      expect(preview.status, TavernAuthoringPreviewStatus.complete);
      final body = preview.assembly!.body;
      final text = _promptText(body);
      expect(text, contains('FIELD=1 INPUT=[]'));
      expect(text, contains('GROUP_Actor_'));
      expect('AUTOMATIC_ACTOR_WORLD'.allMatches(text), hasLength(1));
      expect(
        (preview.origin['resources']! as List<Object?>).map(scriptMap).map((row) => row['physicalResourceId']),
        contains('lorebook:actor-world'),
      );
      expect(preview.regexTrace.where((row) => row['source'] == 'userInput'), hasLength(1));
      expect(_databaseState(h), database);
      expect(await _persistentFiles(h.root), files);
      expect(await h.engine.path(chat), isEmpty);
      expect(h.engine.globalVariables, globals);
      expect(liveRandomCalls, 0);
      h.expectNoGeneration();

      final adopted = await h.engine.applyAuthoringChanges(
        draft.id,
        draftRevision: draft.draftRevision,
        physicalResourceId: 'character:$host',
        changeIds: ['host-state'],
        expectedAuthorityRevision: base.sources.single.authorityRevision!,
        operationId: 'group-host-adopt',
      );
      expect(adopted.committed, isTrue);
      await h.close();
      final random = Random(17);
      final native = await TavernEngine.openDirectory(
        h.root,
        config: h.config,
        modelClient: h.model,
        clock: () => _at,
        random: random.nextDouble,
      );
      addTearDown(native.close);
      h.reply('A native group reply.');
      final events = await native.sendGroup(chat, 'ENTER', speakerCharacterId: actor).toList();
      expect(events.whereType<TavernGroupFinished>().single.reason, TavernGroupEndReason.completed);
      expect(h.requests.single.body, body);
      final path = await native.path(chat);
      expect(path.map((message) => message.role), [TavernRole.user, TavernRole.character]);
      expect(path.last.speakerCharacterId, actor);
      expect((await native.readVariables(chat))['step'], '1');
      expect(native.globalVariables['scratch'], 'local');
    },
  );

  test('unchanged regex candidates preserve reopened compatibility until the raw rule is edited', () async {
    final h = await generationFixture();
    final character = await h.card('Guide');
    final chat = await h.emptyChat(character);
    final imported = (await h.engine.importRegexScripts(
      jsonEncode(_regex('stored-incompatible', '[', 'RECHECKED_INPUT', 1)),
    )).scripts.single;
    expect(imported.compatible, isFalse);
    expect(imported.diagnostics.any((issue) => issue.status == TavernRegexCompatibility.incompatible), isTrue);
    await h.reopen(
      whileClosed: () async {
        final file = File('${h.root.path}/regex-library.json');
        final document = scriptMap(jsonDecode(await file.readAsString()));
        final record = scriptMap((document['scripts']! as List<Object?>).single);
        // A valid externally edited raw rule does not silently discard the
        // persisted incompatible diagnostic when the native library reopens.
        scriptMap(record['raw'])['findRegex'] = r'/^INPUT$/';
        await file.writeAsString(jsonEncode(document));
      },
    );
    final reopened = (await h.engine.listRegexScripts()).single;
    expect(reopened.raw['findRegex'], r'/^INPUT$/');
    expect(reopened.enabled, isTrue);
    expect(reopened.compatible, isFalse);
    final base = await h.engine.createAuthoringDraft([
      const TavernAuthoringTarget(kind: TavernAuthoringTargetKind.regexLibrary, id: 'global'),
    ]);

    Future<void> checkPreview(
      TavernAuthoringDraft draft,
      String id,
      List<String> changes, {
      required bool transformed,
    }) async {
      final database = _databaseState(h);
      final files = await _persistentFiles(h.root);
      final preview = await _preview(
        h,
        draft,
        id,
        TavernAuthoringChatContext(chatId: chat),
        text: 'INPUT',
        changes: changes,
      );
      expect(preview.status, TavernAuthoringPreviewStatus.complete);
      final messages = (preview.assembly!.body['messages']! as List<Object?>).map(scriptMap);
      expect(
        messages.lastWhere((message) => message['role'] == 'user')['content'],
        transformed ? 'RECHECKED_INPUT' : 'INPUT',
      );
      expect(_databaseState(h), database);
      expect(await _persistentFiles(h.root), files);
    }

    await checkPreview(base, 'regex-unchanged', const [], transformed: false);
    const archive = TavernAuthoringChange(
      id: 'archive-only',
      physicalResourceId: 'regex-library',
      path: '/scripts/0/sourceText',
      operation: TavernAuthoringChangeKind.set,
      value: 'Changed archive only.',
    );
    final archived = await h.engine.editAuthoringDraft(base.id, draftRevision: base.draftRevision, changes: [archive]);
    await checkPreview(archived, 'regex-archive-only', const ['archive-only'], transformed: false);
    final edited = await h.engine.editAuthoringDraft(
      base.id,
      draftRevision: archived.draftRevision,
      changes: [
        archive,
        const TavernAuthoringChange(
          id: 'pattern',
          physicalResourceId: 'regex-library',
          path: '/scripts/0/raw/findRegex',
          operation: TavernAuthoringChangeKind.set,
          value: r'/^(?:INPUT)$/',
        ),
      ],
    );
    await checkPreview(edited, 'regex-pattern-edit', const ['pattern'], transformed: true);
    h.expectNoGeneration();

    h.reply('The stored rule remains disabled.');
    final disabled = await h.engine.send(chat, 'INPUT').toList();
    expect(disabled.whereType<TavernTurnFailed>(), isEmpty);
    expect((await h.engine.path(chat)).lastWhere((message) => message.role == TavernRole.user).text, 'INPUT');
    final changed = await h.engine.updateRegexScript(imported.id, {'findRegex': r'/^(?:INPUT)$/'});
    expect(changed.compatible, isTrue);
    h.reply('The edited rule now executes.');
    final enabled = await h.engine.send(chat, 'INPUT').toList();
    expect(enabled.whereType<TavernTurnFailed>(), isEmpty);
    expect((await h.engine.path(chat)).lastWhere((message) => message.role == TavernRole.user).text, 'RECHECKED_INPUT');
  });

  test('static persistent and once injections survive repeated previews and still drive native WI', () async {
    final h = await generationFixture();
    final character = await h.card('Guide');
    final chat = await _chat(
      h,
      character,
      metadata: {
        'script_injects': {
          'same': {'value': 'PERSISTENT', 'position': 1, 'depth': 0, 'role': 0, 'scan': false, 'filter': ''},
        },
      },
    );
    final context = await h.context(chat, characterId: character);
    final lease = await h.bridge.injectPrompts(context.id, [
      TavernScriptInjection(id: 'same', content: 'TRANSIENT', depth: 0),
      TavernScriptInjection(
        id: 'scan',
        content: 'SCAN_KEY',
        position: TavernScriptInjectionPosition.scanOnly,
        scan: true,
      ),
      TavernScriptInjection(
        id: 'closed',
        content: '{{incglobalvar::unused}}',
        position: TavernScriptInjectionPosition.scanOnly,
        scan: false,
      ),
    ], once: true);
    await h.engine.putLorebook('scan', _book('SCAN_ACTIVATED', key: 'SCAN_KEY'));
    await h.engine.bindLorebooks(['scan']);
    final draft = await h.engine.createAuthoringDraft([_bookTarget('scan')]);
    final database = _databaseState(h);
    final files = await _persistentFiles(h.root);
    final first = await _preview(h, draft, 'injections-first', TavernAuthoringChatContext(chatId: chat), text: 'Q');
    final second = await _preview(h, draft, 'injections-second', TavernAuthoringChatContext(chatId: chat), text: 'Q');
    expect(first.status, TavernAuthoringPreviewStatus.complete);
    expect(second.status, TavernAuthoringPreviewStatus.complete);
    expect(first.assembly!.body, second.assembly!.body);
    final text = _promptText(first.assembly!.body);
    for (final expected in ['PERSISTENT', 'TRANSIENT', 'SCAN_ACTIVATED']) {
      expect(text, contains(expected));
    }
    expect(text, isNot(contains('SCAN_KEY')));
    expect(text.indexOf('PERSISTENT'), lessThan(text.indexOf('TRANSIENT')));
    expect(h.engine.globalVariables.containsKey('unused'), isFalse);
    expect(_databaseState(h), database);
    expect(await _persistentFiles(h.root), files);
    final before = (await h.bridge.listInjections(context.id)).where((view) => view.once).toList();
    expect(before, hasLength(3));
    expect(before.every((view) => !view.claimed), isTrue);
    expect(
      before.map((view) => view.registrationVersion).toSet(),
      lease.registrations.map((value) => value.registrationVersion).toSet(),
    );
    h.expectNoGeneration();

    h.reply('Consumed by the actual turn.');
    final events = await h.engine.send(chat, 'Q').toList();
    expect(events.whereType<TavernTurnFailed>(), isEmpty);
    expect((await h.engine.inspectTurn(chat))!.prompt!.body, first.assembly!.body);
    final after = (await h.bridge.listInjections(context.id)).where((view) => view.once).toList();
    expect(after.every((view) => view.claimed), isTrue);
    expect(h.engine.globalVariables.containsKey('unused'), isFalse);
  });

  test('live preparation hosts and real filters are unsupported without dispatching them', () async {
    final h = await generationFixture(allowModel: false);
    final character = await h.card('Guide');
    final chat = await h.emptyChat(character);
    final draft = await h.engine.createAuthoringDraft([_characterTarget(character)]);
    final host = GenerationHost();
    // Attach before opening a context: attaching to an existing one itself
    // schedules a cache dispatch, independently of any preview request.
    h.bridge.attachHost(host);
    final context = await h.context(chat, characterId: character);
    final deliveries = host.deliveries.length;
    final refreshes = host.refreshes.length;
    final database = _databaseState(h);
    final hosted = await _preview(h, draft, 'host-required', TavernAuthoringChatContext(chatId: chat));
    expect(hosted.status, TavernAuthoringPreviewStatus.unsupported);
    expect(hosted.assembly, isNull);
    expect(hosted.issues.single.type, 'unsupported_preview');
    expect(host.deliveries, hasLength(deliveries));
    expect(host.refreshes, hasLength(refreshes));
    expect(host.invocations, isEmpty);
    expect(_databaseState(h), database);

    h.bridge.attachHost(null);
    await h.bridge.injectPrompts(context.id, [
      TavernScriptInjection(
        id: 'filter',
        content: 'FILTERED',
        filter: TavernScriptCallbackRef(
          contextId: context.id,
          instanceId: context.instanceId,
          callbackId: 'actual-filter',
        ),
      ),
    ], once: true);
    final filtered = await _preview(h, draft, 'filter-required', TavernAuthoringChatContext(chatId: chat));
    expect(filtered.status, TavernAuthoringPreviewStatus.unsupported);
    expect(filtered.assembly, isNull);
    expect(filtered.issues.single.type, 'unsupported_preview');
    expect(host.invocations, isEmpty);
    expect(host.deliveries, hasLength(deliveries));
    expect((await h.bridge.listInjections(context.id)).single.claimed, isFalse);
    expect(_databaseState(h), database);
    h.expectNoGeneration();

    await h.close();
    final counter = _ForbiddenCounter();
    final reopened = await TavernEngine.openDirectory(
      h.root,
      config: h.config,
      modelClient: h.model,
      clock: () => _at,
      counter: counter,
    );
    try {
      final counted = await reopened
          .previewAuthoringPrompt(_request(draft, 'counter-required', TavernAuthoringChatContext(chatId: chat)))
          .result;
      expect(counted.status, TavernAuthoringPreviewStatus.unsupported);
      expect(counted.assembly, isNull);
      expect(counted.issues.single.type, 'unsupported_counter');
      expect(counter.calls, 0);
      h.expectNoGeneration();
    } finally {
      await reopened.close();
    }
  });

  test('invalid stored global policy rejects normal preview while impersonation still skips policy', () async {
    final h = await generationFixture(allowModel: false);
    final character = await h.card('Guide', greeting: 'Earlier reply.', description: 'POLICY_SCOPE_CARD');
    final chat = await h.engine.createChat(character);
    final draft = await h.engine.createAuthoringDraft([_characterTarget(character)]);
    await h.reopen(
      whileClosed: () async {
        final file = File('${h.root.path}/settings.json');
        final document = scriptMap(jsonDecode(await file.readAsString()));
        document['settings'] = null;
        await file.writeAsString(jsonEncode(document));
      },
    );
    final database = _databaseState(h);
    final files = await _persistentFiles(h.root);

    await expectLater(
      _preview(h, draft, 'invalid-policy', TavernAuthoringChatContext(chatId: chat), text: 'Q'),
      throwsA(
        isA<TavernToolException>()
            .having((error) => error.code, 'code', TavernToolErrorCode.invalidArgument)
            .having((error) => error.message, 'message', 'invalid_stored_policy')
            .having((error) => error.fieldPath, 'fieldPath', 'settings')
            .having((error) => error.committed, 'committed', false),
      ),
    );
    final impersonated = await _preview(
      h,
      draft,
      'impersonate-without-policy',
      TavernAuthoringChatContext(chatId: chat, generationType: 'impersonate'),
    );
    expect(impersonated.status, TavernAuthoringPreviewStatus.complete);
    expect(impersonated.assembly, isNotNull);
    expect(impersonated.assembly!.body.containsKey('tools'), isFalse);
    expect(_databaseState(h), database);
    expect(await _persistentFiles(h.root), files);

    // The ordinary native turn rejects the same stored input before a key
    // lookup or model request; preview must not silently enable its defaults.
    final events = await h.engine.send(chat, 'Q').toList();
    expect(events.whereType<TavernTurnStarted>(), isEmpty);
    expect(events.whereType<TavernTurnDone>(), isEmpty);
    final failure = events.whereType<TavernTurnFailed>().single;
    expect(failure.kind, TavernFailure.server);
    expect(failure.detail, contains('TavernToolException'));
    h.expectNoGeneration();
  });

  test('a managed card ABA during a later queued book read invalidates the whole capture', () async {
    final h = await generationFixture(allowModel: false);
    final character = await h.card('Guide', description: 'A');
    // Establish the normal writer's modification_date before the ABA. The
    // fixture clock is fixed, so the second A really restores identical bytes.
    await h.engine.updateCharacterFields(character, {'description': 'A'});
    final chat = await h.emptyChat(character);
    await h.engine.putLorebook('gate', _book('GATED_BOOK'));
    await h.engine.bindLorebooks(['gate']);
    final draft = await h.engine.createAuthoringDraft([_characterTarget(character)]);
    final cardFile = File('${h.root.path}/characters/$character/card.json');
    final original = await cardFile.readAsBytes();
    final originalRevision = draft.sources.single.authorityRevision!.revision;
    final gate = _ReadGate();
    await _withReadGate(File('${h.root.path}/lorebooks/gate.json'), gate, () async {
      final task = h.engine.previewAuthoringPrompt(
        _request(draft, 'managed-aba', TavernAuthoringChatContext(chatId: chat), text: 'Q'),
      );
      await Future.any<void>([
        gate.entered.future,
        task.result.then<void>((_) => throw TestFailure('Preview ended before the queued book read.')),
      ]).timeout(_deadline);
      await h.engine.updateCharacterFields(character, {'description': 'B'});
      await h.engine.updateCharacterFields(character, {'description': 'A'});
      expect(await cardFile.readAsBytes(), original);
      expect(
        h.inspect(
          (db) => db.select('SELECT revision FROM authoring_resources WHERE physical_resource_id = ?', [
            'character:$character',
          ]).single['revision'],
        ),
        originalRevision + 2,
      );
      final database = _databaseState(h);
      gate.release();
      final preview = await task.result;
      expect(preview.status, TavernAuthoringPreviewStatus.conflict);
      expect(preview.assembly, isNull);
      expect(preview.issues.single.type, 'capture_conflict');
      expect(_databaseState(h), database);
    });
    expect(await h.engine.path(chat), isEmpty);
    h.expectNoGeneration();

    // A second real read is still owned when cancellation stops logical
    // preparation. Neither the task nor engine close may claim it drained.
    final cancelledGate = _ReadGate();
    await _withReadGate(File('${h.root.path}/lorebooks/gate.json'), cancelledGate, () async {
      final task = h.engine.previewAuthoringPrompt(
        _request(draft, 'cancelled-capture', TavernAuthoringChatContext(chatId: chat), text: 'Q'),
      );
      await Future.any<void>([
        cancelledGate.entered.future,
        task.result.then<void>((_) => throw TestFailure('Preview ended before the cancellation read.')),
      ]).timeout(_deadline);
      var resultDone = false;
      unawaited(
        task.result.then<void>(
          (_) {
            resultDone = true;
          },
          onError: (Object _, StackTrace _) {
            resultDone = true;
          },
        ),
      );
      var cancelDone = false;
      final cancelling = task.cancel().then((_) {
        cancelDone = true;
      });
      var closeDone = false;
      final closing = h.engine.close().then((_) {
        closeDone = true;
      });
      await Future<void>(() {});
      expect(resultDone, isFalse);
      expect(cancelDone, isFalse);
      expect(closeDone, isFalse);
      cancelledGate.release();
      await cancelling;
      await closing;
      final preview = await task.result;
      expect(preview.status, TavernAuthoringPreviewStatus.cancelled);
      expect(preview.assembly, isNull);
      expect(preview.issues.single.type, 'cancelled');
    });
    h.expectNoGeneration();
  });

  test('fresh raw resources and seed blobs are read without observing versions or repairing the library', () async {
    final h = await generationFixture(allowModel: false);
    final character = await h.card('Guide', description: 'OLD_RAW');
    final chat = await h.emptyChat(character);
    await h.engine.putLorebook('draft-book', _book('BOOK_DETAIL'));
    await h.engine.bindLorebooks(['draft-book']);
    final draft = await h.engine.createAuthoringDraft([_bookTarget('draft-book')]);
    final cardFile = File('${h.root.path}/characters/$character/card.json');
    final card = scriptMap(jsonDecode(await cardFile.readAsString()));
    scriptMap(card['data'])['description'] = 'CURRENT_RAW';
    card['unknownEnvelope'] = {
      'retained': [null, true],
    };
    await cardFile.writeAsBytes(utf8.encode('\ufeff${jsonEncode(card)}'));
    final index = File('${h.root.path}/character-index/$character.json');
    await index.delete();
    final artifact = File('${h.root.path}/characters/.staging-preview-evidence/retained.txt');
    await artifact.parent.create(recursive: true);
    await artifact.writeAsString('An unrelated staging artifact is not preview work.');
    final database = _databaseState(h);
    final files = await _persistentFiles(h.root);
    expect(
      h.inspect(
        (db) => db.select(
          'SELECT COALESCE(p.raw_text, r.raw_text) AS raw_text '
          'FROM authoring_resources r LEFT JOIN authoring_payloads p ON p.payload_id = r.raw_text_id '
          'WHERE r.physical_resource_id = ?',
          ['character:$character'],
        ).single['raw_text'],
      ),
      contains('OLD_RAW'),
    );

    final preview = await _preview(
      h,
      draft,
      'raw-without-observe',
      TavernAuthoringChatContext(chatId: chat),
      text: 'Q',
    );
    expect(preview.status, TavernAuthoringPreviewStatus.complete);
    expect(_promptText(preview.assembly!.body), contains('CURRENT_RAW'));
    expect(_promptText(preview.assembly!.body), isNot(contains('OLD_RAW')));
    expect(_databaseState(h), database);
    expect(await _persistentFiles(h.root), files);
    expect(await index.exists(), isFalse);
    expect(await artifact.exists(), isTrue);
    h.expectNoGeneration();

    scriptMap(card['data'])['name'] = 'Seed';
    scriptMap(card['data'])['description'] = 'SEED_DETAIL';
    final original = Uint8List.fromList(utf8.encode('\ufeff${jsonEncode(card)}'));
    final seed = await h.engine.createAuthoringSeed(
      TavernAuthoringSeedInput(kind: TavernAuthoringTargetKind.character, bytes: original, fileName: 'sample.json'),
    );
    final seedDatabase = _databaseState(h);
    final seedFiles = await _persistentFiles(h.root);
    final sampled = await _preview(
      h,
      seed,
      'seed-sample',
      TavernAuthoringSampleContext(characterResourceId: seed.sources.single.physicalResourceId),
      text: 'Q',
    );
    expect(sampled.status, TavernAuthoringPreviewStatus.complete);
    expect(_promptText(sampled.assembly!.body), contains('SEED_DETAIL'));
    expect(await Directory('${h.root.path}/characters/${seed.sources.single.target.id}').exists(), isFalse);
    expect(
      h.inspect(
        (db) => db.select('SELECT bytes FROM authoring_seed_blobs WHERE draft_id = ? AND path = ?', [
          seed.id,
          'original.json',
        ]).single['bytes'],
      ),
      original,
    );
    expect(_databaseState(h), seedDatabase);
    expect(await _persistentFiles(h.root), seedFiles);
    h.expectNoGeneration();

    final preset = (await h.engine.importPreset(jsonEncode(scriptPreset(main: 'SAVED_PRESET_MAIN').raw))).preset;
    final presetDraft = await h.engine.createAuthoringDraft([
      _characterTarget(character),
      TavernAuthoringTarget(kind: TavernAuthoringTargetKind.preset, id: preset.id),
    ]);
    await h.engine.bindPreset(chat, preset.id);
    expect((await h.engine.presetSelection(chatId: chat)).boundPresetId, preset.id);
    await h.engine.deletePreset(preset.id);
    expect((await h.engine.presetSelection(chatId: chat)).boundPresetId, isNull);
    expect(await h.engine.preset(preset.id), isNull);
    final presetDatabase = _databaseState(h);
    final presetFiles = await _persistentFiles(h.root);

    // An explicit sample reference selects the saved candidate even though
    // the live preset row has been deleted. It never recreates that row.
    final savedPreset = await _preview(
      h,
      presetDraft,
      'saved-preset-without-live-row',
      TavernAuthoringSampleContext(characterResourceId: 'character:$character', presetId: preset.id),
      text: 'Q',
    );
    expect(savedPreset.status, TavernAuthoringPreviewStatus.complete);
    expect(savedPreset.origin['presetId'], preset.id);
    expect(_promptText(savedPreset.assembly!.body), contains('SAVED_PRESET_MAIN'));

    // Deletion really cleared this chat's binding; merely having P in the
    // draft must not restore that old selection for a real chat preview.
    final unbound = await _preview(
      h,
      presetDraft,
      'deleted-preset-binding-stays-cleared',
      TavernAuthoringChatContext(chatId: chat),
      text: 'Q',
    );
    expect(unbound.status, TavernAuthoringPreviewStatus.complete);
    expect(unbound.origin['presetId'], isNot(preset.id));
    expect(_promptText(unbound.assembly!.body), isNot(contains('SAVED_PRESET_MAIN')));
    expect(await h.engine.preset(preset.id), isNull);
    expect(_databaseState(h), presetDatabase);
    expect(await _persistentFiles(h.root), presetFiles);
    h.expectNoGeneration();
  });
}

TavernAuthoringTarget _characterTarget(String id) =>
    TavernAuthoringTarget(kind: TavernAuthoringTargetKind.character, id: id);
TavernAuthoringTarget _bookTarget(String id) => TavernAuthoringTarget(kind: TavernAuthoringTargetKind.lorebook, id: id);

TavernAuthoringPromptRequest _request(
  TavernAuthoringDraft draft,
  String id,
  TavernAuthoringPromptContext context, {
  String text = '',
  List<String> changes = const [],
}) => TavernAuthoringPromptRequest(
  requestId: id,
  draftId: draft.id,
  draftRevision: draft.draftRevision,
  changeIds: changes,
  context: context,
  text: text,
  at: _at,
  seed: 17,
);

Future<TavernAuthoringPromptPreview> _preview(
  ScriptFixture h,
  TavernAuthoringDraft draft,
  String id,
  TavernAuthoringPromptContext context, {
  String text = '',
  List<String> changes = const [],
}) => h.engine.previewAuthoringPrompt(_request(draft, id, context, text: text, changes: changes)).result;

Future<String> _chat(
  ScriptFixture h,
  String character, {
  ScriptJson metadata = const {},
  List<ScriptJson> messages = const [],
}) async {
  final document = StChatDocument(
    fileName: 'preview.jsonl',
    header: {'user_name': 'User', 'character_name': 'Guide', 'chat_metadata': metadata},
    messages: messages,
  );
  return (await h.engine.importChats(character, [
    TavernChatFile(fileName: document.fileName, bytes: document.encode()),
  ])).chatIds.single;
}

ScriptJson _message(String text, {bool user = false}) => {
  'name': user ? 'User' : 'Guide',
  'is_user': user,
  'is_system': false,
  'send_date': _at.toIso8601String(),
  'mes': text,
  'extra': <String, Object?>{},
};

ScriptJson _book(String content, {String? key}) => {
  'entries': {
    '0': {
      'uid': 0,
      'key': key == null ? <String>[] : [key],
      'content': content,
      'constant': key == null,
      'position': 0,
      'useProbability': false,
    },
  },
};

ScriptJson _regex(String name, String find, String replacement, int placement, {bool promptOnly = false}) => {
  'scriptName': name,
  'findRegex': find,
  'replaceString': replacement,
  'trimStrings': <String>[],
  'placement': [placement],
  'disabled': false,
  'markdownOnly': false,
  'promptOnly': promptOnly,
  'runOnEdit': false,
  'substituteRegex': 0,
};

String _promptText(ScriptJson body) =>
    (body['messages']! as List<Object?>).map(scriptMap).map((message) => message['content']).join('\n');

ScriptJson _databaseState(ScriptFixture h) => h.inspect((db) {
  final result = <String, Object?>{};
  for (final table in db.select("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")) {
    final name = table['name']! as String;
    final quoted = name.replaceAll('"', '""');
    result[name] = [for (final row in db.select('SELECT * FROM "$quoted"')) Map<String, Object?>.from(row)];
  }
  return result;
});

Future<Map<String, List<int>>> _persistentFiles(Directory root) async {
  final result = <String, List<int>>{};
  await for (final entity in root.list(recursive: true, followLinks: false)) {
    if (entity is! File) {
      continue;
    }
    final path = entity.path.substring(root.path.length + 1);
    // Compare every logical DB table above; SQLite reader lock/WAL files are
    // not source documents and may change merely when a connection opens.
    if (const {'tavern.sqlite3', 'tavern.sqlite3-wal', 'tavern.sqlite3-shm'}.contains(path)) {
      continue;
    }
    result[path] = await entity.readAsBytes();
  }
  return result;
}

Future<void> _withReadGate(File file, _ReadGate gate, Future<void> Function() body) async {
  final parent = Zone.current;
  final aliases = {file.absolute.uri, File(await file.resolveSymbolicLinks()).absolute.uri};
  try {
    await IOOverrides.runZoned(
      body,
      createFile: (path) {
        final real = parent.run(() => File(path));
        return aliases.contains(parent.run(() => real.absolute.uri)) ? _GatedFile(real, gate) : real;
      },
    );
  } finally {
    gate.release();
    if (gate.entered.isCompleted) {
      await gate.finished.future;
    }
  }
}

class _ReadGate {
  final entered = Completer<void>();
  final finished = Completer<void>();
  final _released = Completer<void>();
  void release() {
    if (!_released.isCompleted) {
      _released.complete();
    }
  }

  Future<T> read<T>(Future<T> Function() action) async {
    if (entered.isCompleted) {
      return action();
    }
    entered.complete();
    try {
      await _released.future;
      return await action();
    } finally {
      finished.complete();
    }
  }
}

class _GatedFile implements File {
  _GatedFile(this.real, this.gate);
  final File real;
  final _ReadGate gate;
  @override
  String get path => real.path;
  @override
  Uri get uri => real.uri;
  @override
  bool get isAbsolute => real.isAbsolute;
  @override
  File get absolute => real.absolute;
  @override
  Directory get parent => real.parent;
  @override
  Future<bool> exists() => real.exists();
  @override
  bool existsSync() => real.existsSync();
  @override
  Future<Uint8List> readAsBytes() => gate.read(real.readAsBytes);
  @override
  Future<String> readAsString({Encoding encoding = utf8}) => gate.read(() => real.readAsString(encoding: encoding));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ForbiddenCounter implements PromptTokenCounter {
  var calls = 0;
  Never _called() {
    calls++;
    throw StateError('An isolated preview must not touch an unsupported counter.');
  }

  @override
  String get name => _called();
  @override
  bool get exact => _called();
  @override
  int countMessage(Map<String, Object?> message) => _called();
  @override
  int countText(String text) => _called();
}
