import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:dsh_tavern/src/store/chat_store.dart';
import 'package:test/test.dart';

import 'p2_script_test_support.dart';

typedef Json = Map<String, Object?>;

void main() {
  test('unchanged remapped pack books preserve the prompt window across ordinary appends', () async {
    final h = await ScriptFixture.open(allowModel: true);
    await h.engine.setPreset(ChatPreset({...scriptPreset().raw, 'openai_max_context': 640, 'openai_max_tokens': 64}));
    final actor = await h.card('Guide', greeting: 'hello');
    final document = StChatDocument(
      fileName: 'window.jsonl',
      header: {'user_name': 'User', 'character_name': 'Guide', 'chat_metadata': <String, Object?>{}},
      messages: [
        for (var i = 0; i < 160; i++)
          {
            'name': i.isEven ? 'User' : 'Guide',
            'is_user': i.isEven,
            'is_system': false,
            'send_date': '2026-11-01T12:00:00Z',
            'mes': 'History $i: The rain continued outside. '.padRight(100, 'x'),
            'extra': <String, Object?>{},
          },
      ],
    );
    final chat = (await h.engine.importChats(actor, [
      TavernChatFile(fileName: document.fileName, bytes: document.encode()),
    ])).chatIds.single;
    final pack = await _install(
      h,
      'stable-window-book',
      'one',
      resources: [
        {
          'kind': 'lorebook',
          'localId': 'lore',
          'path': 'lore.json',
          'entries': [
            {'localId': 'detail', 'pointer': '/entries/entry'},
          ],
        },
      ],
      files: {
        'lore.json': {
          'entries': {
            'entry': {'uid': 0, 'key': <String>[], 'constant': true, 'content': 'STATIC PACK DETAIL', 'position': 0},
          },
        },
      },
    );
    await _bind(h, TavernPackScopeTarget(kind: TavernGameplayScope.chat, targetId: chat), pack, 'stable');
    await _send(h, chat, 'first', 'reply');
    final inspected = h.engine.inspect(chat)!;
    final boundary = inspected.prompt.historyWindow!.firstNodeId;
    for (final hit in inspected.worldInfo.activated) {
      hit.entry.raw['content'] = 'edited inspection copy';
      hit.entry.book.raw['name'] = 'edited inspection name';
    }
    for (var i = 0; i < 2; i++) {
      final sent = await _send(h, chat, 'next', 'reply');
      expect(h.engine.inspect(chat)!.prompt.historyWindow!.firstNodeId, boundary);
      expect(_requestText(sent.request.body), contains('STATIC PACK DETAIL'));
    }
  });

  test('pack regex order and switches agree across query format display and a real prompt', () async {
    final h = await ScriptFixture.open(allowModel: true);
    final actor = await h.card('Actor', greeting: 'hello');
    final chat = await h.engine.createChat(actor);
    final global = await _regexPack(h, 'global-regex', 'TOKEN', 'GLOBAL');
    final character = await _regexPack(h, 'actor-regex', 'GLOBAL', 'ACTOR');
    final local = await _regexPack(h, 'chat-regex', 'ACTOR', 'CHAT');
    final g = await _bind(h, const TavernPackScopeTarget(kind: TavernGameplayScope.global), global, 'global');
    final a = await _bind(
      h,
      TavernPackScopeTarget(kind: TavernGameplayScope.character, targetId: actor),
      character,
      'actor',
    );
    final c = await _bind(h, TavernPackScopeTarget(kind: TavernGameplayScope.chat, targetId: chat), local, 'chat');
    final ids = [g.createdBindings['global'], a.createdBindings['actor'], c.createdBindings['chat']];
    final context = await h.context(chat, characterId: actor);

    final initial = await h.bridge.getTavernRegexes(context.id, TavernScriptRegexQuery());
    final packs = initial.where((rule) => rule.sourceRef['kind'] == 'pack').toList();
    expect(packs.map((rule) => rule.sourceRef['bindingId']), ids);
    expect(packs.map((rule) => rule.source.name), ['global', 'character', 'chat']);
    expect(packs.every((rule) => rule.enabled && rule.effective), isTrue);
    expect(packs.map((rule) => rule.raw['replaceString']), ['GLOBAL', 'ACTOR', 'CHAT']);
    expect(packs.map((rule) => rule.stId), everyElement('shared-regex-id'));
    expect(packs.map((rule) => rule.raw['id']), everyElement('shared-regex-id'));
    final stableIds = packs.map((rule) => rule.sourceRef['stableId']).toList();
    expect(stableIds, everyElement(isA<String>()));
    expect(stableIds.toSet(), hasLength(3));
    expect(packs.map((rule) => rule.execution.id), stableIds);
    expect(packs.map((rule) => rule.engineId), stableIds);
    final beforeFormat = await _saved(h.engine, chat);
    final prompt = await h.bridge.formatAsTavernRegexedString(
      context.id,
      'TOKEN',
      source: RegexPlacement.userInput,
      destination: RegexPhase.prompt,
    );
    final display = await h.bridge.formatAsTavernRegexedString(
      context.id,
      'TOKEN',
      source: RegexPlacement.userInput,
      destination: RegexPhase.display,
    );
    final native = await h.engine.displayText(chat, text: 'TOKEN', role: TavernRole.user);
    expect(prompt.text, 'CHAT');
    expect(display.text, 'CHAT');
    expect(native.text, 'CHAT');
    expect(display.superseded || native.superseded, isFalse);
    expect(await _saved(h.engine, chat), beforeFormat);
    h.expectNoGeneration();

    final sent = await _send(h, chat, 'TOKEN', 'reply');
    expect(_lastUser(sent.request.body), 'CHAT');
    expect((await h.engine.path(chat)).where((message) => message.role == TavernRole.user).single.text, 'TOKEN');

    await h.engine.setSettings({'characterRegexEnabled': false}, chatId: chat);
    final withoutActor = (await h.bridge.getTavernRegexes(
      context.id,
      TavernScriptRegexQuery(),
    )).where((rule) => rule.sourceRef['kind'] == 'pack').toList();
    expect(withoutActor.map((rule) => rule.sourceRef['bindingId']), ids);
    expect(withoutActor.map((rule) => rule.effective), [true, false, true]);
    expect(
      (await h.bridge.formatAsTavernRegexedString(
        context.id,
        'TOKEN',
        source: RegexPlacement.userInput,
        destination: RegexPhase.prompt,
      )).text,
      'GLOBAL',
    );
    expect((await h.engine.displayText(chat, text: 'TOKEN', role: TavernRole.user)).text, 'GLOBAL');

    await h.engine.setSettings({'regexEnabled': false}, chatId: chat);
    expect(await h.bridge.getTavernRegexes(context.id, TavernScriptRegexQuery(effectiveOnly: true)), isEmpty);
    expect(
      (await h.bridge.formatAsTavernRegexedString(
        context.id,
        'TOKEN',
        source: RegexPlacement.userInput,
        destination: RegexPhase.display,
      )).text,
      'TOKEN',
    );
    expect((await h.engine.displayText(chat, text: 'TOKEN', role: TavernRole.user)).text, 'TOKEN');
    expect(h.requests, hasLength(1));
  });

  test('real WI adoption preserves rule and event once across branches and a content upgrade', () async {
    final h = await ScriptFixture.open(allowModel: true);
    final actor = await h.card(
      'Guide',
      greeting: 'opening',
      extensions: {
        'dshgo': {
          'v': 1,
          'state': {
            'schema': {
              'type': 'object',
              'additionalProperties': false,
              'required': ['n'],
              'properties': {
                'n': {'type': 'integer'},
              },
            },
            'init': {'n': 0},
          },
        },
      },
    );
    final first = await _worldPack(h, 'one', 'PACK-WI-ONE');
    final scope = TavernPackScopeTarget(kind: TavernGameplayScope.character, targetId: actor);
    final binding = await _bind(h, scope, first, 'world');
    final bindingId = binding.createdBindings['world']!;
    final chat = await h.engine.createChat(actor);
    final greeting = (await h.engine.path(chat)).single.nodeId;
    await h.engine.setSettings({
      'director': {'enabled': true, 'every': 1000},
    });
    final run = await _direct(h, chat, bindingId);

    final branchA = await _send(h, chat, 'ember', 'branch A');
    expect(_requestText(branchA.request.body), contains('PACK-WI-ONE'));
    final savedA = await _saved(h.engine, chat);
    final rowA = _binding(savedA, bindingId);
    final entryA = _worldEntry(rowA);
    expect(_map((await h.engine.readState(chat)).values)['n'], 11);
    expect(rowA['rules'], ['rule-once']);
    expect(_map(rowA['events'])['once'], ['event-once']);
    expect(_map(rowA['events'])['consumed'], [
      {'eventId': '${run.id}:event:0', 'handlerId': 'event-once'},
    ]);
    expect(entryA['matches'], 1);
    expect(entryA['lastMessageCount'], 2);
    final firstSticky = _map(entryA['sticky']);
    expect(firstSticky['start'], 2);
    expect(firstSticky['end'], 6);
    expect(firstSticky['triggeredVersion'], 'one');

    // Return to an actual ancestor before any of the three domains consumed.
    // The same durable proposal remains eligible on this independent branch.
    await h.engine.selectNode(chat, greeting);
    expect((await _saved(h.engine, chat)).containsKey('dshgoPackRuntime'), isFalse);
    final branchB = await _send(h, chat, 'ember', 'branch B');
    expect(branchB.message.nodeId, isNot(branchA.message.nodeId));
    final savedB = await _saved(h.engine, chat);
    final rowB = _binding(savedB, bindingId);
    expect(_map((await h.engine.readState(chat)).values)['n'], 11);
    expect(rowB['rules'], rowA['rules']);
    expect(rowB['events'], rowA['events']);
    expect(_worldEntry(rowB)['matches'], 1);

    // A real version change keeps the stable entry and its triggering policy.
    // Only the content changes; sticky/cooldown declarations are identical.
    final second = await _worldPack(h, 'two', 'PACK-WI-TWO');
    final upgraded = await h.engine.updateGameplayBindings(
      scope,
      expected: binding.snapshot.token,
      operationId: 'world-content-two',
      edits: [TavernPackBindingEdit.selectVersion(bindingId: bindingId, packVersion: second.packVersion)],
    );
    expect(upgraded.snapshot.bindings.single.onceEpoch, binding.snapshot.bindings.single.onceEpoch);

    final draft = await h.engine.createAuthoringDraft([
      TavernAuthoringTarget(kind: TavernAuthoringTargetKind.character, id: actor),
    ]);
    final beforePreview = await _saved(h.engine, chat);
    final requestsBeforePreview = h.requests.length;
    final preview = await h.engine
        .previewAuthoringPrompt(
          TavernAuthoringPromptRequest(
            requestId: 'wi-content-two-preview',
            draftId: draft.id,
            draftRevision: draft.draftRevision,
            changeIds: const [],
            context: TavernAuthoringChatContext(chatId: chat),
            text: 'quiet',
            at: DateTime.utc(2026, 11, 12, 5),
            seed: 41,
          ),
        )
        .result;
    expect(preview.status, TavernAuthoringPreviewStatus.complete);
    expect(_requestText(preview.assembly!.body), contains('PACK-WI-TWO'));
    final previewHit = _maps(
      preview.worldInfo['activated'],
    ).singleWhere((hit) => _map(hit['sourceRef'])['bindingId'] == bindingId);
    expect(previewHit['sourceRef'], {
      'kind': 'pack',
      'installedPackId': second.installedPackId,
      'bindingId': bindingId,
      'onceEpoch': upgraded.snapshot.bindings.single.onceEpoch,
      'packVersion': 'two',
      'resourceLocalId': 'lore',
      'entryLocalId': 'memory',
    });
    expect(await _saved(h.engine, chat), beforePreview);
    expect(h.requests, hasLength(requestsBeforePreview));
    final next = await _send(h, chat, 'quiet', 'upgraded branch B');
    expect(_requestText(next.request.body), contains('PACK-WI-TWO'));
    expect(_requestText(next.request.body), isNot(contains('PACK-WI-ONE')));
    final inspection = (await h.engine.inspectTurn(chat))!;
    expect(_requestText(inspection.prompt!.body), _requestText(preview.assembly!.body));
    final nativeHit = _maps(
      inspection.worldInfo['activated'],
    ).singleWhere((hit) => _map(hit['sourceRef'])['bindingId'] == bindingId);
    expect(nativeHit['sourceRef'], previewHit['sourceRef']);
    final after = await _saved(h.engine, chat);
    final current = _binding(after, bindingId);
    expect(_map((await h.engine.readState(chat)).values)['n'], 11);
    expect(current['rules'], rowB['rules']);
    expect(current['events'], rowB['events']);
    expect(_worldEntry(current)['matches'], 2);
    expect(_worldEntry(current)['lastMessageCount'], 4);
    expect(_worldEntry(current)['sticky'], _worldEntry(rowB)['sticky']);

    await h.engine.selectNode(chat, branchA.message.nodeId);
    expect((await _saved(h.engine, chat))['dshgoPackRuntime'], savedA['dshgoPackRuntime']);
    await h.reopen();
    expect((await _saved(h.engine, chat))['dshgoPackRuntime'], savedA['dshgoPackRuntime']);
    expect(_map((await h.engine.readState(chat)).values)['n'], 11);
    expect(h.requests, hasLength(4));
  });

  test('pending display observes first binding, roster order and pack availability from another connection', () async {
    final h = await ScriptFixture.open();
    final actor = await h.card('Display actor');
    final other = await h.card('Display member');
    final chat = await h.engine.createGroupChat([actor, other], addGreetings: false);
    final ref = await _regexPack(h, 'late-display-regex', 'TOKEN', 'LATE');
    final store = ChatStore.open('${h.root.path}/tavern.sqlite3');
    addTearDown(store.close);
    final scope = TavernPackScopeTarget(kind: TavernGameplayScope.chat, targetId: chat);

    // displayText captures bindings synchronously, then yields at its real
    // card/name read. A committed external write must be observed on resume
    // even when the admitted scope was empty and no engine event was emitted.
    final first = h.engine.displayText(chat, text: 'TOKEN', role: TavernRole.user);
    store.updateGameplayBindingsData(
      scope,
      expected: store.readGameplayScopeData(scope).token,
      operationId: 'first-display-binding',
      edits: [TavernPackBindingEdit.create(clientKey: 'late', packRef: ref)],
    );
    expect((await first).superseded, isTrue);
    final fresh = await h.engine.displayText(chat, text: 'TOKEN', role: TavernRole.user);
    expect(fresh.text, 'LATE');
    expect(fresh.superseded, isFalse);

    final beforeRoster = h.engine.displayText(chat, text: 'TOKEN', role: TavernRole.user);
    final group = store.groupChat(chat)!;
    store.saveGroup(
      TavernGroupChat(
        chatId: chat,
        title: group.title,
        hostCharacterId: group.hostCharacterId,
        members: group.members.reversed.toList(),
        activation: group.activation,
        maxSpeakersPerTurn: group.maxSpeakersPerTurn,
        allowSelfResponses: group.allowSelfResponses,
      ),
    );
    expect((await beforeRoster).superseded, isTrue);
    final reordered = await h.engine.displayText(chat, text: 'TOKEN', role: TavernRole.user);
    expect(reordered.text, 'LATE');
    expect(reordered.superseded, isFalse);

    final beforeRemoval = h.engine.displayText(chat, text: 'TOKEN', role: TavernRole.user);
    store.removeGameplayPackVersionData(
      ref,
      expected: store.readGameplayPackVersion(ref)!.availability,
      operationId: 'remove-display-version',
    );
    expect((await beforeRemoval).superseded, isTrue);
    h.expectNoGeneration();
  });

  test('a display with warm binding checks observes an external change during its worker request', () async {
    final h = await ScriptFixture.open();
    final actor = await h.card('Display actor');
    final chat = await h.engine.createChat(actor);
    final ref = await _regexPack(h, 'warm-display-regex', 'TOKEN', 'CHANGED');
    final scope = TavernPackScopeTarget(kind: TavernGameplayScope.chat, targetId: chat);
    final bound = await _bind(h, scope, ref, 'display');
    final store = ChatStore.open('${h.root.path}/tavern.sqlite3');
    addTearDown(store.close);

    final warm = await h.engine.displayText(chat, text: 'TOKEN', role: TavernRole.user);
    expect(warm.text, 'CHANGED');
    expect(warm.superseded, isFalse);
    var changes = 0;
    const limits = RegexLimits();
    final pending = await runZoned(
      () => h.engine.displayText(chat, text: 'TOKEN', role: TavernRole.user),
      zoneSpecification: ZoneSpecification(
        createTimer: (self, parent, zone, duration, callback) {
          final timer = parent.createTimer(zone, duration, callback);
          // The real worker creates its deadline after this job's initial
          // guards and before dispatch. Keep the deadline and timer intact.
          if (changes == 0 && duration == limits.timeout) {
            changes++;
            try {
              store.updateGameplayBindingsData(
                scope,
                expected: store.readGameplayScopeData(scope).token,
                operationId: 'disable-after-display-stamp',
                edits: [TavernPackBindingEdit.setEnabled(bindingId: bound.createdBindings['display']!, enabled: false)],
              );
            } catch (_) {
              timer.cancel();
              rethrow;
            }
          }
          return timer;
        },
      ),
    );
    expect(changes, 1);
    expect(pending.superseded, isTrue);
    expect(pending.replacements, 0);
    expect(pending.text, 'TOKEN');
    final fresh = await h.engine.displayText(chat, text: 'TOKEN', role: TavernRole.user);
    expect(fresh.text, 'TOKEN');
    expect(fresh.superseded, isFalse);
    h.expectNoGeneration();
  });

  test('raw scripts ignore unused broken WI and revoke an empty resource vector on first enable', () async {
    final h = await ScriptFixture.open(allowModel: true);
    final actor = await h.card('Raw actor', greeting: 'opening', description: 'RAW-CARD');
    final chat = await h.engine.createChat(actor);
    final ref = await _install(
      h,
      'unused-world',
      'one',
      resources: [
        {
          'kind': 'lorebook',
          'localId': 'lore',
          'path': 'lore.json',
          'entries': [
            {'localId': 'only', 'pointer': '/entries/only'},
          ],
        },
      ],
      files: {
        'lore.json': {
          'entries': {
            'only': {'uid': 1, 'key': <String>[], 'constant': true, 'content': 'UNUSED-PACK-WI'},
          },
        },
      },
    );
    await _bind(h, TavernPackScopeTarget(kind: TavernGameplayScope.chat, targetId: chat), ref, 'unused-world');
    h.inspect((db) {
      final parameters = [ref.installedPackId, ref.packVersion, 'lore.json'];
      expect(
        db.select(
          'SELECT bytes FROM gameplay_pack_files '
          'WHERE installed_pack_id = ? AND pack_version = ? AND path = ?',
          parameters,
        ),
        hasLength(1),
      );
      db.execute(
        'DELETE FROM gameplay_pack_files '
        'WHERE installed_pack_id = ? AND pack_version = ? AND path = ?',
        parameters,
      );
      expect(
        db.select(
          'SELECT bytes FROM gameplay_pack_files '
          'WHERE installed_pack_id = ? AND pack_version = ? AND path = ?',
          parameters,
        ),
        isEmpty,
      );
    }, writable: true);
    final context = await h.context(chat, characterId: actor);
    final before = await _saved(h.engine, chat);
    final reply = h.reply('raw-ok');
    final raw = await h.bridge.generateRaw(
      context.id,
      TavernScriptRawRequest(
        orderedPrompts: const [
          TavernScriptPromptPart.placeholder(TavernScriptPromptPlaceholder.charDescription),
          TavernScriptPromptPart.literal(role: TavernScriptPromptRole.user, content: 'literal input'),
        ],
      ),
    );
    expect((await raw.result).text, 'raw-ok');
    final request = await reply.seen.future;
    expect(_requestText(request.body), contains('RAW-CARD'));
    expect(_requestText(request.body), isNot(contains('UNUSED-PACK-WI')));
    expect(await _saved(h.engine, chat), before);

    // This other chat really has an empty binding vector. The damaged file
    // belongs only to the first chat; no disabled/removed row stands in for
    // an absent scope here.
    final other = await h.engine.createChat(actor);
    final otherContext = await h.context(other, characterId: actor, instanceId: 'late-resource-context');
    final scope = TavernPackScopeTarget(kind: TavernGameplayScope.chat, targetId: other);
    expect((await h.engine.readGameplayBindings(scope)).bindings, isEmpty);
    final lateRef = await _regexPack(h, 'first-late-regex', 'TOKEN', 'LATE');
    final otherBefore = await _saved(h.engine, other);
    final lateReply = h.reply('STALE-RESPONSE');
    var enabled = false;
    lateReply.beforeResponse = () async {
      await _bind(h, scope, lateRef, 'first-late');
      enabled = true;
    };
    final generation = await h.bridge.generateRaw(
      otherContext.id,
      TavernScriptRawRequest(
        userInput: 'TOKEN',
        orderedPrompts: const [TavernScriptPromptPart.placeholder(TavernScriptPromptPlaceholder.userInput)],
      ),
    );
    await expectLater(generation.result, throwsA(scriptError(TavernScriptErrorCode.cancelled)));
    expect(enabled, isTrue);
    expect(_lastUser((await lateReply.seen.future).body), 'TOKEN');
    final terminal = await generation.events.last;
    expect(terminal.status, TavernScriptGenerationStatus.cancelled);
    expect(terminal.text, isEmpty);
    expect((await h.engine.readGameplayBindings(scope)).bindings.single.enabled, isTrue);
    expect(await _saved(h.engine, other), otherBefore);
    expect((await h.engine.path(other)), hasLength(1));
    expect(h.requests, hasLength(2));
  });
}

Future<TavernPackVersionRef> _regexPack(ScriptFixture h, String id, String from, String to) => _install(
  h,
  id,
  'one',
  resources: [
    {'kind': 'regex', 'localId': 'rule', 'path': 'rule.json'},
  ],
  files: {
    'rule.json': {
      'id': 'shared-regex-id',
      'scriptName': id,
      'findRegex': '/$from/g',
      'replaceString': to,
      'placement': [RegexPlacement.userInput, RegexPlacement.aiOutput],
      'promptOnly': true,
      'markdownOnly': true,
    },
  },
);

Future<TavernPackVersionRef> _worldPack(ScriptFixture h, String version, String content) => _install(
  h,
  'world-and-once',
  version,
  resources: [
    {
      'kind': 'lorebook',
      'localId': 'lore',
      'path': 'lore.json',
      'entries': [
        {'localId': 'memory', 'pointer': '/entries/entry'},
      ],
    },
  ],
  files: {
    'lore.json': {
      'entries': {
        'entry': {
          'uid': 7,
          'key': ['ember'],
          'constant': false,
          'content': '@@keep_activate_after_match\n$content',
          'position': 0,
          'order': 100,
          'sticky': 4,
          'cooldown': 2,
        },
      },
    },
  },
  dshgo: {
    'v': 1,
    'state': {
      'rules': [
        {
          'id': 'rule-once',
          'when': true,
          'once': true,
          'do': [
            {
              'type': 'state',
              'ops': [
                {'op': 'add', 'path': '/n', 'value': 1, 'why': 'once rule'},
              ],
            },
          ],
        },
      ],
    },
    'director': {
      'eventRules': {
        'v': 1,
        'rules': [
          {
            'id': 'event-once',
            'name': 'fixed',
            'when': true,
            'once': true,
            'do': [
              {
                'type': 'state',
                'ops': [
                  {'op': 'add', 'path': '/n', 'value': 10, 'why': 'once event'},
                ],
              },
            ],
          },
        ],
      },
    },
  },
);

Future<TavernPackVersionRef> _install(
  ScriptFixture h,
  String id,
  String version, {
  List<Json> resources = const [],
  Map<String, Object?> files = const {},
  Json? dshgo,
}) async {
  final manifest = Uint8List.fromList(
    utf8.encode(
      jsonEncode({'formatVersion': 1, 'packId': id, 'packVersion': version, 'resources': resources, 'dshgo': ?dshgo}),
    ),
  );
  final archive = Archive()..addFile(ArchiveFile('pack.json', manifest.length, manifest));
  for (final entry in files.entries) {
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(entry.value)));
    archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
  }
  return (await h.engine.importGameplayPack(Uint8List.fromList(ZipEncoder().encode(archive)))).ref;
}

Future<TavernPackBindingReceipt> _bind(
  ScriptFixture h,
  TavernPackScopeTarget scope,
  TavernPackVersionRef ref,
  String key,
) async {
  final before = await h.engine.readGameplayBindings(scope);
  return h.engine.updateGameplayBindings(
    scope,
    expected: before.token,
    operationId: 'bind-$key',
    edits: [TavernPackBindingEdit.create(clientKey: key, packRef: ref)],
  );
}

Future<({TavernMessage message, ScriptRequest request})> _send(
  ScriptFixture h,
  String chat,
  String input,
  String output,
) async {
  final plan = h.reply(output);
  final events = await h.engine.send(chat, input).toList();
  expect(events.whereType<TavernTurnFailed>(), isEmpty);
  final message = events.whereType<TavernTurnDone>().single.message;
  return (message: message, request: await plan.seen.future);
}

Future<TavernDirectorRun> _direct(ScriptFixture h, String chat, String bindingId) async {
  final plan = h.reply('');
  plan.beforeResponse = () async {
    final request = await plan.seen.future;
    final input = _map(jsonDecode(_maps(request.body['messages']).last['content']! as String));
    final capability = _map(input['eventCapability']);
    final wire =
        _maps(capability['eventMap']).singleWhere((item) => _map(item['source'])['bindingId'] == bindingId)['wireName']!
            as String;
    final choice = _maps(plan.body!['choices']).single;
    choice['message'] = {
      'role': 'assistant',
      'content': null,
      'tool_calls': [
        {
          'index': 0,
          'id': 'pack-event-call',
          'type': 'function',
          'function': {
            'name': 'direct',
            'arguments': jsonEncode({
              'notes': '',
              'beat': 'KEEP MOVING',
              'prefetch': <Object?>[],
              'suggestions': [
                for (var i = 0; i < 3; i++) {'text': 'choice-$i', 'risk': ''},
              ],
              'events': [
                {'name': wire, 'data': 'actual captured pack event'},
              ],
            }),
          },
        },
      ],
    };
    choice['finish_reason'] = 'tool_calls';
  };
  final run = await h.engine.runDirector(chat);
  expect(run.success, isTrue, reason: run.failure);
  return run;
}

String _lastUser(Json body) =>
    _maps(body['messages']).lastWhere((message) => message['role'] == 'user')['content']! as String;
String _requestText(Json body) =>
    _maps(body['messages']).map((message) => message['content']).whereType<String>().join('\n');

Future<Json> _saved(TavernEngine engine, String chat) async {
  final files = await engine.exportChat(chat);
  final document = StChatDocument.decode(files.first.fileName, files.first.bytes);
  final raw = _map(_map(_map(document.messages.last['extra'])['dshgo'])['tavernState']);
  return _map(jsonDecode(jsonEncode(raw)));
}

Json _map(Object? value) => value! as Json;
List<Json> _maps(Object? value) => (value! as List<Object?>).map(_map).toList();
Json _binding(Json saved, String binding) => _map(_map(_map(saved['dshgoPackRuntime'])['bindings'])[binding]);
Json _worldEntry(Json row) => _map(_map(_map(_map(row['worldInfo'])['entries'])['lore'])['memory']);
