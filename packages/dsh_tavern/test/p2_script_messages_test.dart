import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_script_test_support.dart';

void main() {
  test('message-only cache updates retain detached snapshots and send only changed rows', () async {
    final h = await ScriptFixture.open();
    final character = await h.card('Cached rows', description: 'Unchanged authority');
    final chat = await h.emptyChat(character);
    final host = ScriptHost();
    h.bridge.attachHost(host);
    final context = await h.context(chat, characterId: character);
    await h.bridge.createChatMessages(context.id, [
      for (var index = 0; index < 3; index++)
        TavernScriptMessageDraft(
          role: TavernScriptRole.assistant,
          message: 'row-$index',
          data: {'n': index},
          extra: {
            'foreign': [index],
          },
        ),
    ], options: const TavernScriptWriteOptions(refresh: TavernScriptRefresh.none));
    final before = await h.bridge.snapshot(context.id);
    final resources = before.resourceRefs;
    scriptMap(scriptMap(before.resourceRefs['characterData'])['data'])['description'] = 'caller mutation';
    before.messages.first.data!['n'] = -1;
    (before.messages.first.extra['foreign']! as List<Object?>).add('caller mutation');
    scriptMap(before.messages.first.swipes.single.info['extra'])['foreign'] = 'caller mutation';
    host.deliveries.clear();
    await h.bridge.setChatMessages(context.id, [
      TavernScriptMessagePatch(
        messageId: 1,
        fields: {
          'message': 'edited middle',
          'data': {'n': 10},
          'hidden': true,
        },
      ),
    ], options: const TavernScriptWriteOptions(refresh: TavernScriptRefresh.none));
    final after = await h.bridge.snapshot(context.id);
    expect(after.messages.map((value) => value.message), ['row-0', 'edited middle', 'row-2']);
    expect(after.messages.map((value) => value.data), [
      {'n': 0},
      {'n': 10},
      {'n': 2},
    ]);
    expect(after.messages[1].hidden, isTrue);
    expect(after.messages.first.extra, {
      'foreign': [0],
    });
    expect(scriptMap(after.messages.first.swipes.single.info['extra']), {
      'foreign': [0],
    });
    expect(before.messages[1].message, 'row-1');
    expect(before.messages[1].data, {'n': 1});
    expect(before.messages[1].hidden, isFalse);
    expect(after.resourceRefs, resources);
    final deltas = host.deliveries
        .where((value) => value.kind == TavernScriptDispatchKind.cache)
        .map((value) => value.delta!);
    expect(deltas.expand((value) => value.upsertMessages).map((value) => value.ref), [before.messages[1].ref]);
    expect(deltas.every((value) => value.resourceRefs.isEmpty), isTrue);
    await h.bridge.replaceVariables(
      context.id,
      TavernVariableTarget(scope: TavernVariableScope.message, messageRef: before.messages.first.ref),
      {'n': 7},
    );
    final stateOnly = await h.bridge.snapshot(context.id);
    expect(stateOnly.messages.first.message, 'row-0');
    expect(stateOnly.messages.first.data, {'n': 7});
    expect(stateOnly.messages.first.swipes.single.data, {'n': 7});
    expect(before.messages.first.data, {'n': 0});
    h.expectNoGeneration();
  });

  test('script read projections preserve imported shapes and full write evidence', () async {
    final h = await ScriptFixture.open();
    final character = await h.card('Imported projections');
    final document = StChatDocument(
      fileName: 'projection.jsonl',
      header: {'user_name': 'User', 'character_name': 'Imported projections', 'chat_metadata': {}},
      messages: [
        {'name': 'User', 'is_user': true, 'mes': 'absent variables', 'extra': {}},
        {
          'name': 'User',
          'is_user': true,
          'mes': 'explicit null',
          'variables': [null],
          'extra': {},
        },
        {
          'name': '\ufeffSpeaker',
          'is_user': false,
          'mes': '\ufeffselected',
          'swipes': ['alternate', '\ufeffselected'],
          'swipe_id': 1,
          'variables': [
            ['opaque'],
            {'n': 2},
          ],
          'swipe_info': [
            {
              'send_date': null,
              'gen_started': false,
              'unknown': ['alternate'],
              'extra': {'foreign': 'alternate'},
            },
            {
              'unknown': ['selected'],
              'send_date': 'overridden',
              'gen_started': 'not present at top',
            },
          ],
          'send_date': null,
          'gen_finished': [1, 'opaque'],
          'vendor': {'must': 'survive the write'},
          'extra': {
            'foreign': ['selected'],
            'dshgo': {
              'inspection': {'foreignEvidence': 'retain'},
            },
          },
        },
      ],
    );
    final chat = (await h.engine.importChats(character, [
      TavernChatFile(fileName: document.fileName, bytes: document.encode()),
    ])).chatIds.single;
    final context = await h.context(chat, characterId: character);
    final snapshot = await h.bridge.snapshot(context.id);
    expect(snapshot.messages.first.hasData, isFalse);
    expect(snapshot.messages[1].hasData, isTrue);
    expect(snapshot.messages[1].rawData, isNull);
    expect(snapshot.messages[1].dataIssue?.actualKind, 'null');
    final selected = snapshot.messages.last;
    expect([selected.name, selected.message], ['\ufeffSpeaker', '\ufeffselected']);
    expect(selected.data, {'n': 2});
    expect(selected.swipes.first.rawData, ['opaque']);
    expect(selected.swipes.first.dataIssue?.actualKind, 'list');
    expect(selected.swipes.first.info, {
      'unknown': ['alternate'],
      'send_date': null,
      'gen_started': false,
      'extra': {'foreign': 'alternate'},
    });
    expect(selected.swipes.last.info, {
      'unknown': ['selected'],
      'send_date': null,
      'gen_finished': [1, 'opaque'],
      'extra': {
        'foreign': ['selected'],
      },
    });
    (selected.swipes.last.info['unknown']! as List<Object?>).add('caller mutation');
    final before = h.inspect(
      (db) => db.select('SELECT extra, original FROM nodes WHERE id = ?', [selected.ref.nodeId]).single.values.toList(),
    );
    await h.bridge.setChatMessages(context.id, [
      TavernScriptMessagePatch(ref: selected.ref, fields: {'message': 'edited selected'}),
    ]);
    final after = h.inspect(
      (db) => db.select('SELECT extra, original FROM nodes WHERE id = ?', [selected.ref.nodeId]).single.values.toList(),
    );
    expect(after, before);
    final fresh = await h.bridge.snapshot(context.id);
    expect(fresh.messages.last.message, 'edited selected');
    expect(fresh.messages.last.swipes.last.info['unknown'], ['selected']);
    final exported = StChatDocument.decode('export.jsonl', (await h.engine.exportChat(chat)).first.bytes);
    expect(exported.messages.last['mes'], 'edited selected');
    expect(exported.messages.last['vendor'], {'must': 'survive the write'});
    final otherChat = await h.emptyChat(character);
    await h.engine.narrate(otherChat, 'another chat');
    await h.bridge.getVariables(
      context.id,
      TavernVariableTarget(scope: TavernVariableScope.message, chatId: otherChat, messageId: -1),
    );
    expect((await h.bridge.snapshot(context.id)).messages.last.ref, selected.ref);
    await h.engine.selectSibling(chat, selected.ref.nodeId, 0);
    final alternate = (await h.bridge.snapshot(context.id)).messages.last;
    expect(alternate.message, 'alternate');
    expect(alternate.rawData, ['opaque']);
    expect(alternate.swipes.last.data, {'n': 2});
    h.expectNoGeneration();
  });

  test('bridge numbers the complete path before range and role filters', () async {
    final h = await ScriptFixture.open();
    final character = await h.card('Long path');
    final chat = await h.emptyChat(character);
    final context = await h.context(chat, characterId: character);
    await h.bridge.createChatMessages(context.id, [
      for (var index = 0; index < 70; index++)
        TavernScriptMessageDraft(
          role: TavernScriptRole.values[index % 3],
          message: 'line-$index',
          hidden: index % 5 == 0,
          data: {'index': index},
        ),
    ]);
    expect(await h.engine.path(chat), hasLength(60));
    final all = await h.bridge.getChatMessages(context.id, const TavernMessageRange());
    expect(all.totalPathLength, 70);
    expect(all.messages.map((message) => message.messageId), List.generate(70, (i) => i));
    expect(all.messages.map((message) => message.message), List.generate(70, (i) => 'line-$i'));
    expect(all.messages.every((message) => message.swipes.isEmpty), isTrue);
    final tail = await h.bridge.getChatMessages(
      context.id,
      const TavernMessageRange(first: -3, last: -1),
      includeSwipes: true,
    );
    expect(tail.messages.map((message) => message.messageId), [67, 68, 69]);
    expect(tail.messages.every((message) => message.swipes.length == 1), isTrue);
    final intersection = await h.bridge.getChatMessages(context.id, const TavernMessageRange(first: -100, last: 2));
    expect(intersection.messages.map((message) => message.messageId), [0, 1, 2]);
    expect(
      (await h.bridge.getChatMessages(context.id, const TavernMessageRange(first: 90, last: 99))).messages,
      isEmpty,
    );
    final filtered = await h.bridge.getChatMessages(
      context.id,
      const TavernMessageRange(),
      role: TavernScriptRole.system,
      hidden: TavernHiddenFilter.hiddenOnly,
    );
    expect(filtered.messages.map((message) => message.messageId), [5, 20, 35, 50, 65]);
    final anotherChat = await h.emptyChat(character);
    final other = await h.context(anotherChat, characterId: character, instanceId: 'other-view');
    await h.bridge.activateChat(other.id);
    final snapshot = await h.bridge.snapshot(context.id);
    expect(snapshot.context.chatId, chat);
    expect(snapshot.messages, hasLength(70));
    expect(snapshot.pathRevision, all.pathRevision);
    expect(snapshot.capabilities.scopes, TavernVariableScope.values.toSet());
    expect(snapshot.capabilities.generationOptions, {
      'generationId',
      'presetId',
      'speakerCharacterId',
      'userInput',
      'stream',
      'includeReasoning',
      'silent',
      'maxChatHistory',
      'overrides',
      'injects',
      'samplingOverrides',
      'orderedPrompts',
    });
    expect(snapshot.capabilities.slashCommands, h.bridge.capabilities.slashCommands);
    await h.bridge.closeContext(context.id);
    await expectLater(() => h.bridge.snapshot(context.id), throwsA(scriptError(TavernScriptErrorCode.closedContext)));
    expect((await h.bridge.snapshot(other.id)).messages, isEmpty);
    h.expectNoGeneration();
    stdout.writeln('P2_SCRIPT_MESSAGES_READY');
  });

  test('raw message writes retain literal text and preserve private extra and narrator identity', () async {
    final h = await ScriptFixture.open();
    final character = await h.card('Raw');
    final chat = await h.emptyChat(character);
    final context = await h.context(chat, characterId: character);
    await h.engine.setSettings({
      'globalRegexScripts': [
        {
          'id': 'input',
          'scriptName': 'input',
          'findRegex': 'RAW',
          'replaceString': 'REWRITTEN',
          'trimStrings': <String>[],
          'placement': [1, 2, 3],
          'disabled': false,
          'markdownOnly': false,
          'promptOnly': false,
          'runOnEdit': true,
          'substituteRegex': 0,
          'minDepth': null,
          'maxDepth': null,
        },
      ],
    });
    expect((await h.engine.sendOnly(chat, 'RAW')).text, 'REWRITTEN');
    const literal = '  RAW {{incvar::must-not-run}}  ';
    final created = await h.bridge.createChatMessages(context.id, [
      TavernScriptMessageDraft(
        role: TavernScriptRole.assistant,
        message: literal,
        name: '',
        speakerCharacterId: character,
        data: {'opaque': true},
        extra: {
          'foreign': [1, null],
          'type': 'narrator',
        },
      ),
    ]);
    final ref = created.upsertMessages.last.ref;
    expect((await h.engine.path(chat)).last.text, literal);
    expect((await h.engine.path(chat)).last.role, TavernRole.character);
    expect((await h.engine.readVariables(chat)).containsKey('must-not-run'), isFalse);
    await h.engine.nameBranch(chat, ref.nodeId, 'PRIVATE NAME');
    final privateBefore = _privateExtra(h, ref);
    await h.bridge.setChatMessages(context.id, [
      TavernScriptMessagePatch(ref: ref, fields: {'message': '${literal}RAW', 'extra': {}}),
    ]);
    expect(_privateExtra(h, ref), privateBefore);
    final actual = (await h.bridge.getChatMessages(context.id, const TavernMessageRange(first: -1))).messages.single;
    expect(actual.extra, isEmpty);
    expect(actual.message, '${literal}RAW');
    expect(actual.speakerCharacterId, character);
    final before = (await h.bridge.getChatMessages(context.id, const TavernMessageRange())).pathRevision;
    for (final forbidden in <ScriptJson>[
      {
        'extra': {
          'dshgo': {'tavernState': {}},
        },
      },
      {
        'swipesInfo': [
          {
            'extra': {
              'dshgo': {'branchName': 'bypass'},
            },
          },
        ],
      },
    ]) {
      await expectLater(
        () => h.bridge.setChatMessages(context.id, [
          TavernScriptMessagePatch(messageId: 0, fields: {'message': 'must roll back'}),
          TavernScriptMessagePatch(ref: ref, fields: forbidden),
        ]),
        throwsA(scriptError(TavernScriptErrorCode.reservedField)),
      );
      expect((await h.engine.path(chat)).first.text, 'REWRITTEN');
      expect((await h.bridge.getChatMessages(context.id, const TavernMessageRange())).pathRevision, before);
      expect(_privateExtra(h, ref), privateBefore);
    }
    final narrator = await h.engine.narrate(chat, 'narration', speaker: 'Narrator');
    final narratorRef = TavernScriptMessageRef(chatId: chat, nodeId: narrator.nodeId);
    final projected = (await h.bridge.getChatMessages(context.id, const TavernMessageRange(first: -1))).messages.single;
    expect(projected.role, TavernScriptRole.system);
    expect(projected.nativeRole, TavernRole.narrator);
    await h.bridge.setChatMessages(context.id, [
      TavernScriptMessagePatch(ref: narratorRef, fields: {'role': 'system', 'message': 'retained narrator'}),
    ]);
    expect((await h.engine.path(chat)).last.role, TavernRole.narrator);
    await h.bridge.setChatMessages(context.id, [
      TavernScriptMessagePatch(ref: narratorRef, fields: {'role': 'user'}),
      TavernScriptMessagePatch(ref: narratorRef, fields: {'role': 'system'}),
    ]);
    expect((await h.engine.path(chat)).last.role, TavernRole.system);
    final exported = (await h.engine.exportChat(chat)).first;
    final document = StChatDocument.decode(exported.fileName, exported.bytes);
    expect(document.messages.last['is_system'], isTrue);
    await h.reopen();
    expect((await h.engine.path(chat)).last.role, TavernRole.system);
    expect(_privateExtra(h, ref), privateBefore);
    h.expectNoGeneration();
  });

  test('public JSONL round trip preserves authoritative roles and actor IDs with narrator-shaped extra', () async {
    final h = await ScriptFixture.open();
    final character = await h.card('Role round trip');
    final chat = await h.emptyChat(character);
    final context = await h.context(chat, characterId: character);
    await h.bridge.createChatMessages(context.id, [
      TavernScriptMessageDraft(
        role: TavernScriptRole.user,
        message: 'USER',
        extra: {'type': 'narrator', 'foreign': 'user'},
      ),
      TavernScriptMessageDraft(
        role: TavernScriptRole.assistant,
        message: 'ACTOR-0',
        speakerCharacterId: character,
        extra: {'type': 'narrator'},
      ),
    ]);
    final actor = (await h.bridge.getChatMessages(context.id, const TavernMessageRange(first: -1))).messages.single;
    await h.bridge.setChatMessages(context.id, [
      TavernScriptMessagePatch(
        ref: actor.ref,
        fields: {
          'swipes': ['ACTOR-0', 'ACTOR-1'],
          'swipeId': 1,
          'swipesInfo': [
            {
              'extra': {'type': 'narrator', 'page': 0},
            },
            {
              'extra': {'type': 'narrator', 'page': 1},
            },
          ],
        },
      ),
    ]);
    await h.bridge.createChatMessages(context.id, [
      TavernScriptMessageDraft(
        role: TavernScriptRole.system,
        message: 'COMMENT',
        hidden: false,
        extra: {'type': 'narrator', 'foreign': 'comment'},
      ),
    ]);
    await h.engine.narrate(chat, 'NARRATOR', speaker: 'Narrator');
    final expectedRoles = [TavernRole.user, TavernRole.character, TavernRole.system, TavernRole.narrator];
    final expectedIds = <String?>[null, character, null, null];
    expect((await h.engine.path(chat)).map((message) => message.role), expectedRoles);
    expect((await h.engine.path(chat)).map((message) => message.speakerCharacterId), expectedIds);
    ScriptJson own(Object? extra) => scriptMap(scriptMap(scriptMap(extra)['dshgo'])['chatJsonl']);
    void checkWire(List<TavernChatFile> files) {
      final document = StChatDocument.decode(files.first.fileName, files.first.bytes);
      final row = document.messages.singleWhere((message) => message['mes'] == 'ACTOR-1');
      expect(scriptMap(row['extra'])['type'], 'narrator');
      expect(own(row['extra'])['role'], 'character');
      expect(own(row['extra'])['speakerCharacterId'], character);
      final infos = (row['swipe_info']! as List<Object?>).map(scriptMap).toList();
      expect(infos.map((info) => own(info['extra'])['role']), ['character', 'character']);
      expect(infos.map((info) => own(info['extra'])['speakerCharacterId']), [character, character]);
      expect(infos.map((info) => scriptMap(info['extra'])['type']), ['narrator', 'narrator']);
      expect(infos.map((info) => scriptMap(info['extra'])['page']), [0, 1]);
      final comment = document.messages.singleWhere((message) => message['mes'] == 'COMMENT');
      expect(scriptMap(comment['extra'])['type'], 'narrator');
      expect(own(comment['extra'])['role'], 'system');
      expect(own(comment['extra'])['hidden'], isFalse);
      expect(comment['is_system'], isTrue);
    }

    final files = await h.engine.exportChat(chat);
    checkWire(files);
    final imported = await h.engine.importChats(character, files);
    final copy = imported.chatIds.single;
    expect(copy, isNot(chat));
    Future<void> checkStored() async {
      final path = await h.engine.path(copy);
      expect(path.map((message) => message.text), ['USER', 'ACTOR-1', 'COMMENT', 'NARRATOR']);
      expect(path.map((message) => message.role), expectedRoles);
      expect(path.map((message) => message.speakerCharacterId), expectedIds);
      expect(path.map((message) => message.hidden), [false, false, false, false]);
      final pages = (await h.engine.tree(
        copy,
      )).where((node) => node.preview == 'ACTOR-0' || node.preview == 'ACTOR-1').toList();
      expect(pages, hasLength(2));
      expect(pages.map((node) => node.role), everyElement(TavernRole.character));
      expect(pages.map((node) => node.speakerCharacterId), everyElement(character));
      expect(pages.singleWhere((node) => node.preview == 'ACTOR-0').isCurrentPath, isFalse);
      expect(pages.singleWhere((node) => node.preview == 'ACTOR-1').isCurrentPath, isTrue);
    }

    await checkStored();
    final copiedContext = await h.context(copy, characterId: character, instanceId: 'copied-role-view');
    final copiedView = await h.bridge.getChatMessages(
      copiedContext.id,
      const TavernMessageRange(),
      includeSwipes: true,
    );
    expect(copiedView.messages.map((message) => message.nativeRole), expectedRoles);
    expect(copiedView.messages[1].extra['type'], 'narrator');
    expect(copiedView.messages[2].extra['type'], 'narrator');
    expect(copiedView.messages[1].swipes.map((swipe) => swipe.text), ['ACTOR-0', 'ACTOR-1']);
    await h.reopen();
    await checkStored();
    checkWire(await h.engine.exportChat(copy));
    final legacy = TavernChatFile(
      fileName: 'legacy-role.jsonl',
      bytes: Uint8List.fromList(
        utf8.encode(
          <ScriptJson>[
            {'user_name': 'User', 'character_name': 'Role round trip', 'chat_metadata': {}},
            {
              'name': 'Narrator',
              'mes': 'LEGACY-NARRATOR',
              'is_user': false,
              'is_system': false,
              'extra': {'type': 'narrator'},
            },
            {
              'name': 'User',
              'mes': 'LEGACY-USER',
              'is_user': true,
              'is_system': false,
              'extra': {'type': 'narrator'},
            },
          ].map(jsonEncode).join('\n'),
        ),
      ),
    );
    final legacyChat = (await h.engine.importChats(character, [legacy])).chatIds.single;
    final legacyPath = await h.engine.path(legacyChat);
    expect(legacyPath.map((message) => message.role), [TavernRole.narrator, TavernRole.user]);
    expect(legacyPath.map((message) => message.speakerCharacterId), [null, null]);
    h.expectNoGeneration();
  });

  test('batch inputs are captured once and stale or invalid identities never partially write', () async {
    final h = await ScriptFixture.open();
    final character = await h.card('Identity');
    final chat = await h.emptyChat(character);
    final context = await h.context(chat, characterId: character);
    await h.bridge.createChatMessages(context.id, [
      TavernScriptMessageDraft(role: TavernScriptRole.user, message: 'first'),
      TavernScriptMessageDraft(role: TavernScriptRole.assistant, message: 'second'),
    ]);
    final original = await h.bridge.getChatMessages(context.id, const TavernMessageRange());
    final fields = <String, Object?>{
      'message': 'captured',
      'data': <String, Object?>{
        'value': [1],
      },
    };
    final firstPatch = TavernScriptMessagePatch(ref: original.messages.first.ref, fields: fields);
    scriptMap(fields['data'])['late'] = true;
    final patches = [
      firstPatch,
      TavernScriptMessagePatch(messageId: -1, fields: {'hidden': true}),
    ];
    final writing = h.bridge.setChatMessages(context.id, patches);
    patches.clear();
    await writing;
    final captured = await h.bridge.getChatMessages(context.id, const TavernMessageRange());
    expect(captured.messages.first.message, 'captured');
    expect(captured.messages.first.data, {
      'value': [1],
    });
    expect(captured.messages.last.hidden, isTrue);
    await h.engine.edit(chat, original.messages.last.ref.nodeId, 'native change');
    await expectLater(
      () => h.bridge.setChatMessages(context.id, [
        TavernScriptMessagePatch(messageId: 0, fields: {'message': 'stale'}),
      ], options: TavernScriptWriteOptions(expectedPathRevision: captured.pathRevision)),
      throwsA(scriptError(TavernScriptErrorCode.revisionConflict)),
    );
    final before = await h.bridge.getChatMessages(context.id, const TavernMessageRange());
    await expectLater(
      () => h.bridge.setChatMessages(context.id, [
        TavernScriptMessagePatch(messageId: 0, fields: {'message': 'partial'}),
        TavernScriptMessagePatch(messageId: 2, fields: {'message': 'outside'}),
      ]),
      throwsA(scriptError(TavernScriptErrorCode.range)),
    );
    await expectLater(
      () => h.bridge.setChatMessages(context.id, [
        TavernScriptMessagePatch(messageId: 0, ref: before.messages.last.ref, fields: {'message': 'wrong ref'}),
      ]),
      throwsA(scriptError(TavernScriptErrorCode.invalidArgument)),
    );
    final after = await h.bridge.getChatMessages(context.id, const TavernMessageRange());
    expect(after.pathRevision, before.pathRevision);
    expect(after.messages.map((m) => m.message), ['captured', 'native change']);
    h.expectNoGeneration();
  });

  test('historical page writes do not select it or change descendant snapshots', () async {
    final h = await ScriptFixture.open();
    final branch = await _branches(h, withFirstChild: true);
    final beforePath = (await h.engine.path(branch.chat)).map((m) => m.nodeId).toList();
    final beforeY = await _data(h, branch.context.id, branch.y);
    final beforeX = await _data(h, branch.context.id, branch.x!);
    await h.bridge.setChatMessages(branch.context.id, [
      TavernScriptMessagePatch(
        ref: branch.s,
        fields: {
          'message': 'S-EDIT',
          'data': {'owner': 'S-edited'},
        },
      ),
    ]);
    expect((await h.engine.path(branch.chat)).map((m) => m.nodeId), beforePath);
    expect(await _data(h, branch.context.id, branch.s), {'owner': 'S-edited'});
    expect(await _data(h, branch.context.id, branch.x!), beforeX);
    expect(await _data(h, branch.context.id, branch.y), beforeY);
    final selected = (await h.bridge.getChatMessages(
      branch.context.id,
      const TavernMessageRange(first: 1, last: 1),
      includeSwipes: true,
    )).messages.single;
    expect(selected.ref, branch.t);
    expect(selected.swipes.map((s) => s.ref), [branch.s, branch.t]);
    expect(selected.swipes.map((s) => s.text), ['S-EDIT', 'T']);
    await h.reopen();
    final fresh = await h.context(branch.chat, characterId: branch.character);
    expect((await h.engine.path(branch.chat)).map((m) => m.nodeId), beforePath);
    expect(await _data(h, fresh.id, branch.s), {'owner': 'S-edited'});
    expect(await _data(h, fresh.id, branch.x!), beforeX);
    expect(await _data(h, fresh.id, branch.y), beforeY);
    h.expectNoGeneration();
  });

  test('swipe shrink preserves retained remembered child and reparents removed page branches', () async {
    final h = await ScriptFixture.open();
    final branch = await _branches(h, withFirstChild: true);
    final beforeX = await _data(h, branch.context.id, branch.x!);
    final beforeY = await _data(h, branch.context.id, branch.y);
    await expectLater(
      () => h.bridge.setChatMessages(branch.context.id, [
        TavernScriptMessagePatch(
          ref: branch.s,
          fields: {
            'swipes': ['S'],
          },
        ),
      ]),
      throwsA(scriptError(TavernScriptErrorCode.invalidArgument)),
    );
    final mutation = await h.bridge.setChatMessages(branch.context.id, [
      TavernScriptMessagePatch(
        ref: branch.t,
        fields: {
          'swipes': ['S'],
          'swipeId': 0,
        },
      ),
    ]);
    expect(mutation.removedRefs, [branch.t]);
    expect((await h.engine.path(branch.chat)).map((m) => m.nodeId), [
      branch.p.nodeId,
      branch.s.nodeId,
      branch.x!.nodeId,
    ]);
    final tree = await h.engine.tree(branch.chat);
    expect(tree.singleWhere((n) => n.nodeId == branch.y.nodeId).parentId, branch.s.nodeId);
    expect(tree.singleWhere((n) => n.nodeId == branch.y.nodeId).isCurrentPath, isFalse);
    expect(tree.singleWhere((n) => n.nodeId == branch.y.nodeId).branchName, 'Y BRANCH');
    expect(await _data(h, branch.context.id, branch.x!), beforeX);
    expect(await _data(h, branch.context.id, branch.y), beforeY);
    await expectLater(
      () => _data(h, branch.context.id, branch.t),
      throwsA(scriptError(TavernScriptErrorCode.notFound)),
    );
    await h.reopen();
    expect((await h.engine.path(branch.chat)).map((m) => m.nodeId), [
      branch.p.nodeId,
      branch.s.nodeId,
      branch.x!.nodeId,
    ]);
    await h.engine.selectNode(branch.chat, branch.y.nodeId);
    expect((await h.engine.readVariables(branch.chat))['branch-local'], 'Y');
    final fresh = await h.context(branch.chat, characterId: branch.character);
    expect(await _data(h, fresh.id, branch.y), beforeY);
    h.expectNoGeneration();
  });

  test('swipe shrink keeps a retained null successor and rejects conflicting duplicate fields', () async {
    final h = await ScriptFixture.open();
    final branch = await _branches(h, withFirstChild: false);
    final before = await h.bridge.getChatMessages(branch.context.id, const TavernMessageRange(), includeSwipes: true);
    for (final fields in <ScriptJson>[
      {'swipes': <String>[]},
      {
        'swipes': ['S', 'T'],
        'message': 'different',
        'swipeId': 0,
      },
      {
        'swipesData': [
          {'one': 1},
          {'two': 2},
        ],
        'data': {'two': 99},
      },
      {
        'swipesInfo': [
          {'extra': {}},
          {
            'extra': {'x': 1},
          },
        ],
        'extra': {'x': 2},
      },
    ]) {
      await expectLater(
        () => h.bridge.setChatMessages(branch.context.id, [
          TavernScriptMessagePatch(messageId: 0, fields: {'message': 'partial'}),
          TavernScriptMessagePatch(ref: branch.t, fields: fields),
        ]),
        throwsA(scriptError(TavernScriptErrorCode.invalidArgument)),
      );
      expect(
        (await h.bridge.getChatMessages(branch.context.id, const TavernMessageRange())).pathRevision,
        before.pathRevision,
      );
    }
    await h.bridge.setChatMessages(branch.context.id, [
      TavernScriptMessagePatch(
        ref: branch.t,
        fields: {
          'swipes': ['S'],
          'swipeId': 0,
          'message': 'S',
          'swipesData': [
            {'retained': true},
          ],
          'data': {'retained': true},
          'swipesInfo': [
            {
              'extra': {'same': true},
            },
          ],
          'extra': {'same': true},
        },
      ),
    ]);
    expect((await h.engine.path(branch.chat)).map((m) => m.nodeId), [branch.p.nodeId, branch.s.nodeId]);
    expect(
      (await h.engine.tree(branch.chat)).singleWhere((n) => n.nodeId == branch.y.nodeId).parentId,
      branch.s.nodeId,
    );
    await h.reopen();
    expect((await h.engine.path(branch.chat)).map((m) => m.nodeId), [branch.p.nodeId, branch.s.nodeId]);
    h.expectNoGeneration();
  });

  test('deleting a visible floor deletes every swipe and preserves the selected continuation', () async {
    final h = await ScriptFixture.open();
    final branch = await _branches(h, withFirstChild: true);
    final xData = await _data(h, branch.context.id, branch.x!);
    final yData = await _data(h, branch.context.id, branch.y);
    final deleted = await h.bridge.deleteChatMessages(branch.context.id, [1]);
    expect(deleted.removedRefs.toSet(), {branch.s, branch.t});
    expect(deleted.indexChanges[1], branch.y);
    expect((await h.engine.path(branch.chat)).map((m) => m.nodeId), [branch.p.nodeId, branch.y.nodeId]);
    final tree = await h.engine.tree(branch.chat);
    expect(tree.map((n) => n.nodeId).toSet(), {branch.p.nodeId, branch.x!.nodeId, branch.y.nodeId});
    expect(tree.where((n) => n.nodeId != branch.p.nodeId).map((n) => n.parentId), everyElement(branch.p.nodeId));
    expect((await h.engine.readVariables(branch.chat))['branch-local'], 'Y');
    expect(await _data(h, branch.context.id, branch.x!), xData);
    expect(await _data(h, branch.context.id, branch.y), yData);
    for (final gone in [branch.s, branch.t]) {
      await expectLater(() => _data(h, branch.context.id, gone), throwsA(scriptError(TavernScriptErrorCode.notFound)));
    }
    expect((await h.engine.searchChat(branch.chat, 'Y')).map((m) => m.nodeId), [branch.y.nodeId]);
    await h.reopen();
    expect((await h.engine.path(branch.chat)).map((m) => m.nodeId), [branch.p.nodeId, branch.y.nodeId]);
    await h.engine.selectNode(branch.chat, branch.x!.nodeId);
    expect((await h.engine.readVariables(branch.chat))['branch-local'], 'X');
    h.expectNoGeneration();
  });

  test('insert and half-open rotate move complete families without changing their states or IDs', () async {
    final h = await ScriptFixture.open();
    final branch = await _branches(h, withFirstChild: true);
    final beforeIds = (await h.engine.tree(branch.chat)).map((n) => n.nodeId).toSet();
    final states = <String, ScriptJson>{};
    for (final ref in [branch.p, branch.s, branch.t, branch.x!, branch.y]) {
      states[ref.nodeId] = await _data(h, branch.context.id, ref);
    }
    final inserted = await h.bridge.createChatMessages(branch.context.id, [
      TavernScriptMessageDraft(role: TavernScriptRole.system, message: 'INSERT', data: {'insert': 1}),
    ], insertBefore: 1);
    final insertion = inserted.upsertMessages.singleWhere((m) => m.message == 'INSERT').ref;
    expect((await h.engine.path(branch.chat)).map((m) => m.nodeId), [
      branch.p.nodeId,
      insertion.nodeId,
      branch.t.nodeId,
      branch.y.nodeId,
    ]);
    expect(
      (await h.engine.tree(
        branch.chat,
      )).where((n) => n.nodeId == branch.s.nodeId || n.nodeId == branch.t.nodeId).map((n) => n.parentId),
      everyElement(insertion.nodeId),
    );
    await h.bridge.rotateChatMessages(branch.context.id, 1, 2, 4);
    expect((await h.engine.path(branch.chat)).map((m) => m.nodeId), [
      branch.p.nodeId,
      branch.t.nodeId,
      branch.y.nodeId,
      insertion.nodeId,
    ]);
    final moved = await h.engine.tree(branch.chat);
    expect(moved.map((n) => n.nodeId).toSet(), {...beforeIds, insertion.nodeId});
    expect(moved.singleWhere((n) => n.nodeId == branch.s.nodeId).parentId, branch.p.nodeId);
    expect(moved.singleWhere((n) => n.nodeId == branch.x!.nodeId).parentId, branch.s.nodeId);
    for (final entry in states.entries) {
      expect(
        await _data(h, branch.context.id, TavernScriptMessageRef(chatId: branch.chat, nodeId: entry.key)),
        entry.value,
      );
    }
    final copy = (await h.engine.importChats(branch.character, await h.engine.exportChat(branch.chat))).chatIds.single;
    expect((await h.engine.path(copy)).map((m) => m.text), ['P', 'T', 'Y', 'INSERT']);
    await h.reopen();
    expect((await h.engine.path(branch.chat)).map((m) => m.nodeId), [
      branch.p.nodeId,
      branch.t.nodeId,
      branch.y.nodeId,
      insertion.nodeId,
    ]);
    h.expectNoGeneration();
  });

  test('an added swipe inherits its target full state without repeating DSH rules or inventing a model run', () async {
    final h = await ScriptFixture.open();
    final character = await h.card('State pages', greeting: 'S', extensions: scriptStateExtension());
    final chat = await h.engine.createChat(character);
    final context = await h.context(chat, characterId: character);
    final original = (await h.bridge.getChatMessages(context.id, const TavernMessageRange())).messages.single.ref;
    await h.engine.setStateValue(chat, '/count', 999);
    await h.bridge.replaceVariables(context.id, scriptChat, {'local': 'target'});
    final data = await h.bridge.getVariables(context.id, scriptMessage);
    await h.bridge.replaceVariables(context.id, scriptMessage, {
      ...data.value,
      'stat_data': {'hp': 7},
    });
    final beforeFile = (await h.engine.exportChat(chat)).first;
    final beforeDocument = StChatDocument.decode(beforeFile.fileName, beforeFile.bytes);
    final beforeState = scriptMap(
      scriptMap(scriptMap(beforeDocument.messages.single['extra'])['dshgo'])['tavernState'],
    );
    await h.bridge.setChatMessages(context.id, [
      TavernScriptMessagePatch(
        ref: original,
        fields: {
          'swipes': ['S', 'T'],
          'swipeId': 1,
        },
      ),
    ]);
    final page = (await h.bridge.getChatMessages(
      context.id,
      const TavernMessageRange(),
      includeSwipes: true,
    )).messages.single;
    expect(page.swipes.map((swipe) => swipe.ref).first, original);
    expect(page.ref, isNot(original));
    expect(
      page.swipes.map((swipe) => swipe.data),
      everyElement({
        'dshgo': {'count': 5},
        'stat_data': {'hp': 7},
      }),
    );
    expect((await h.engine.readVariables(chat))['local'], 'target');
    expect((await h.engine.path(chat)).single.usage, isNull);
    expect(await h.engine.inspectTurn(chat, nodeId: page.ref.nodeId), isNull);
    final afterFile = (await h.engine.exportChat(chat)).first;
    final afterDocument = StChatDocument.decode(afterFile.fileName, afterFile.bytes);
    final afterState = scriptMap(scriptMap(scriptMap(afterDocument.messages.single['extra'])['dshgo'])['tavernState']);
    expect(afterState, beforeState);
    final updated = await h.bridge.replaceVariables(context.id, scriptMessage, {
      ...page.data!,
      'dshgo': {'count': 999},
    });
    expect(updated.value['dshgo'], {'count': 10});
    expect(updated.stateEdit!.snapshot.effects, isEmpty);
    expect((await _data(h, context.id, original))['dshgo'], {'count': 5});
    await h.reopen();
    final fresh = await h.context(chat, characterId: character);
    expect((await h.bridge.getVariables(fresh.id, scriptMessage)).value['dshgo'], {'count': 10});
    expect((await _data(h, fresh.id, original))['dshgo'], {'count': 5});
    h.expectNoGeneration();
  });

  test('a real SQLite failure rolls back the complete message batch and its revision', () async {
    final h = await ScriptFixture.open();
    final character = await h.card('Atomic');
    final chat = await h.emptyChat(character);
    final context = await h.context(chat, characterId: character);
    await h.bridge.createChatMessages(context.id, [
      TavernScriptMessageDraft(role: TavernScriptRole.user, message: 'A', data: {'value': 'A'}),
      TavernScriptMessageDraft(role: TavernScriptRole.assistant, message: 'B', data: {'value': 'B'}),
    ]);
    final before = await h.bridge.getChatMessages(context.id, const TavernMessageRange());
    h.inspect(
      (db) => db.execute("""
      CREATE TRIGGER script_test_abort BEFORE UPDATE OF text ON nodes
      WHEN NEW.text = 'SQL-ABORT'
      BEGIN SELECT RAISE(ABORT, 'script fixture abort'); END
    """),
      writable: true,
    );
    try {
      await expectLater(
        () => h.bridge.setChatMessages(context.id, [
          TavernScriptMessagePatch(
            messageId: 0,
            fields: {
              'message': 'A-modified',
              'data': {'half': true},
            },
          ),
          TavernScriptMessagePatch(messageId: 1, fields: {'message': 'SQL-ABORT'}),
        ]),
        throwsA(scriptError(TavernScriptErrorCode.storage).having((error) => error.committed, 'committed', isFalse)),
      );
    } finally {
      h.inspect((db) => db.execute('DROP TRIGGER script_test_abort'), writable: true);
    }
    final after = await h.bridge.getChatMessages(context.id, const TavernMessageRange());
    expect(after.pathRevision, before.pathRevision);
    expect(after.messages.map((m) => m.message), ['A', 'B']);
    expect(after.messages.map((m) => m.data), [
      {'value': 'A'},
      {'value': 'B'},
    ]);
    expect(await h.engine.searchChat(chat, 'modified'), isEmpty);
    await h.reopen();
    expect((await h.engine.path(chat)).map((m) => m.text), ['A', 'B']);
    h.expectNoGeneration();
  });
}

ScriptJson _privateExtra(ScriptFixture h, TavernScriptMessageRef ref) => h.inspect((db) {
  final row = db.select('SELECT extra FROM nodes WHERE id = ?', [ref.nodeId]).single;
  return scriptMap(scriptMap(jsonDecode(row['extra'] as String))['dshgo']);
});

Future<ScriptJson> _data(ScriptFixture h, String contextId, TavernScriptMessageRef ref) async =>
    (await h.bridge.getVariables(
      contextId,
      TavernVariableTarget(scope: TavernVariableScope.message, messageRef: ref),
    )).value;

class _Branches {
  _Branches({
    required this.character,
    required this.chat,
    required this.context,
    required this.p,
    required this.s,
    required this.t,
    required this.y,
    this.x,
  });
  final String character;
  final String chat;
  final TavernScriptContext context;
  final TavernScriptMessageRef p;
  final TavernScriptMessageRef s;
  final TavernScriptMessageRef t;
  final TavernScriptMessageRef? x;
  final TavernScriptMessageRef y;
}

Future<_Branches> _branches(ScriptFixture h, {required bool withFirstChild}) async {
  final character = await h.card('Branch');
  final chat = await h.emptyChat(character);
  final context = await h.context(chat, characterId: character);
  await h.bridge.createChatMessages(context.id, [
    TavernScriptMessageDraft(role: TavernScriptRole.user, message: 'P', data: {'owner': 'P'}),
    TavernScriptMessageDraft(role: TavernScriptRole.assistant, message: 'S', data: {'owner': 'S'}),
  ]);
  final initial = await h.bridge.getChatMessages(context.id, const TavernMessageRange());
  final p = initial.messages.first.ref;
  final s = initial.messages.last.ref;
  await h.bridge.setChatMessages(context.id, [
    TavernScriptMessagePatch(
      ref: s,
      fields: {
        'swipes': ['S', 'T'],
        'swipesData': [
          {'owner': 'S'},
          {'owner': 'T'},
        ],
        'swipeId': 1,
      },
    ),
  ]);
  final t = (await h.bridge.getChatMessages(context.id, const TavernMessageRange(first: -1))).messages.single.ref;
  await h.bridge.createChatMessages(context.id, [
    TavernScriptMessageDraft(role: TavernScriptRole.user, message: 'Y', data: {'owner': 'Y'}),
  ]);
  final y = (await h.bridge.getChatMessages(context.id, const TavernMessageRange(first: -1))).messages.single.ref;
  await h.bridge.replaceVariables(context.id, scriptChat, {'branch-local': 'Y'});
  await h.engine.nameBranch(chat, y.nodeId, 'Y BRANCH');
  await h.bridge.selectSwipe(context.id, s, 0);
  TavernScriptMessageRef? x;
  if (withFirstChild) {
    await h.bridge.createChatMessages(context.id, [
      TavernScriptMessageDraft(role: TavernScriptRole.user, message: 'X', data: {'owner': 'X'}),
    ]);
    x = (await h.bridge.getChatMessages(context.id, const TavernMessageRange(first: -1))).messages.single.ref;
    await h.bridge.replaceVariables(context.id, scriptChat, {'branch-local': 'X'});
  }
  await h.bridge.selectSwipe(context.id, t, 1);
  expect((await h.engine.path(chat)).map((m) => m.nodeId), [p.nodeId, t.nodeId, y.nodeId]);
  return _Branches(character: character, chat: chat, context: context, p: p, s: s, t: t, x: x, y: y);
}
