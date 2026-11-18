import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_script_test_support.dart';

void main() {
  test('preparation freezes real writes and prompt visibility before nonblocking SENT', () async {
    final h = await ScriptFixture.open(allowModel: true);
    final character = await h.card('Prepare', greeting: 'G');
    final chat = await h.engine.createChat(character);
    final greeting = (await h.engine.path(chat)).single;
    await h.engine.setHidden(chat, greeting.nodeId, true);
    await h.engine.setPreset(scriptPreset(main: 'PRE {{getvar::phase}}/{{getglobalvar::phase}}'));
    final context = await h.context(chat, characterId: character);
    await h.bridge.setChatMessages(context.id, [
      TavernScriptMessagePatch(messageId: 0, fields: {'hidden': false}),
    ], options: const TavernScriptWriteOptions(refresh: TavernScriptRefresh.none));
    await h.bridge.createChatMessages(context.id, [
      TavernScriptMessageDraft(role: TavernScriptRole.system, message: 'COMMENT MUST STAY OUT', hidden: false),
    ], options: const TavernScriptWriteOptions(refresh: TavernScriptRefresh.none));
    final host = ScriptHost();
    final prepared = Completer<void>();
    final release = Completer<void>();
    final ended = Completer<void>();
    final sentStored = Completer<void>();
    final releaseSent = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) {
        release.complete();
      }
      if (!releaseSent.isCompleted) {
        releaseSent.complete();
      }
      if (!sentStored.isCompleted) {
        sentStored.complete();
      }
    });
    host.onDispatch = (request, cancellation) async {
      if (request.name == 'GENERATION_AFTER_COMMANDS') {
        await h.bridge.replaceVariables(context.id, scriptChat, {'phase': 'LOCAL'});
        await h.bridge.replaceVariables(context.id, scriptGlobal, {'phase': 'GLOBAL'});
        prepared.complete();
        await release.future;
      }
      if (request.name == 'MESSAGE_SENT') {
        await h.bridge.replaceVariables(context.id, scriptGlobal, {'phase': 'AFTER_SENT'});
        if (!sentStored.isCompleted) {
          sentStored.complete();
        }
        await releaseSent.future;
      }
      if (request.name == 'GENERATION_ENDED' && !ended.isCompleted) {
        ended.complete();
      }
      return TavernScriptDispatchAck(eventId: request.eventId);
    };
    h.bridge.attachHost(host);
    final response = h.reply('answer');
    response.beforeResponse = () => sentStored.future;
    final events = ScriptEvents(h.engine.send(chat, 'Q'));
    await Future.any([
      prepared.future,
      events.done.future.then<void>((_) => fail('Turn ended before preparation callback.')),
    ]);
    expect(h.requests, isEmpty);
    expect(h.keyReads, 0);
    expect((await h.bridge.getVariables(context.id, scriptChat)).value, {'phase': 'LOCAL'});
    release.complete();
    await events.waitRequest(response);
    await events.done.future;
    await ended.future;
    expect(releaseSent.isCompleted, isFalse);
    expect((await h.bridge.getVariables(context.id, scriptGlobal)).value, {'phase': 'AFTER_SENT'});
    releaseSent.complete();
    expect(
      h.requests.single.body,
      scriptWire([
        {'role': 'system', 'content': 'PRE LOCAL/GLOBAL'},
        {'role': 'assistant', 'content': 'G'},
        {'role': 'user', 'content': 'Q'},
      ]),
    );
    expect(h.requests.single.method, 'POST');
    expect(h.requests.single.url, Uri.parse('https://p2-script.invalid/v1/chat/completions'));
    expect(events.values.whereType<TavernTurnFailed>(), isEmpty);
    expect(events.values.whereType<TavernTurnDone>().single.hookIssues, isEmpty);
    expect(h.keyReads, 1);
    expect(host.deliveries.where((e) => e.name == 'GENERATION_STARTED'), hasLength(1));
    expect(host.deliveries.where((e) => e.name == 'GENERATION_AFTER_COMMANDS'), hasLength(1));
    expect(host.deliveries.where((e) => e.name == 'MESSAGE_SENT'), hasLength(1));
    expect(host.deliveries.where((e) => e.name == 'GENERATION_ENDED'), hasLength(1));
    stdout.writeln('P2_SCRIPT_LIFECYCLE_READY');
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('received sees committed output and reentrant caches while its derived edit notification waits', () async {
    final h = await ScriptFixture.open(allowModel: true);
    final character = await h.card('Received');
    final chat = await h.emptyChat(character);
    await h.engine.setGlobalVariables({'output': 0});
    await h.engine.setSettings({
      'globalRegexScripts': [_outputCounter()],
    });
    final context = await h.context(chat, characterId: character);
    final host = ScriptHost();
    final receivedWritten = Completer<TavernScriptDispatch>();
    final releaseReceived = Completer<void>();
    final receivedReturning = Completer<void>();
    final editedAcked = Completer<void>();
    final ended = Completer<void>();
    final cache = <String, TavernScriptMessage>{};
    addTearDown(() {
      if (!releaseReceived.isCompleted) {
        releaseReceived.complete();
      }
      if (!receivedReturning.isCompleted) {
        receivedReturning.complete();
      }
    });
    host.onDispatch = (request, cancellation) async {
      if (request.kind == TavernScriptDispatchKind.cache) {
        expect(request.name, isNull);
        expect(request.namespace, isNull);
        for (final message in request.delta?.upsertMessages ?? <TavernScriptMessage>[]) {
          cache[message.ref.nodeId] = message;
        }
      } else if (request.name == 'MESSAGE_RECEIVED') {
        final ref = request.nodeRef!;
        expect(cache[ref.nodeId]!.message, '1FINAL');
        final savedText = h.inspect(
          (db) => db.select('SELECT text FROM nodes WHERE id = ?', [ref.nodeId]).single['text'],
        );
        expect(savedText, '1FINAL');
        expect((await h.engine.inspectTurn(chat, nodeId: ref.nodeId))!.status, TavernInspectionStatus.completed);
        await h.bridge.replaceVariables(
          context.id,
          TavernVariableTarget(scope: TavernVariableScope.message, messageRef: ref),
          {
            'stat_data': {'hp': 7},
          },
        );
        await h.bridge.setChatMessages(context.id, [
          TavernScriptMessagePatch(ref: ref, fields: {'message': 'HOOK BODY'}),
        ], options: const TavernScriptWriteOptions(refresh: TavernScriptRefresh.none));
        expect(cache[ref.nodeId]!.message, 'HOOK BODY');
        expect(cache[ref.nodeId]!.data, {
          'stat_data': {'hp': 7},
        });
        receivedWritten.complete(request);
        await releaseReceived.future;
        if (!receivedReturning.isCompleted) {
          receivedReturning.complete();
        }
      } else if (request.name == 'MESSAGE_EDITED') {
        // The App may serialize this derived listener after its parent
        // RECEIVED while cache acknowledgements remain immediately reentrant.
        await receivedReturning.future;
        editedAcked.complete();
      } else if (request.name == 'GENERATION_ENDED' && !ended.isCompleted) {
        ended.complete();
      }
      return TavernScriptDispatchAck(eventId: request.eventId);
    };
    h.bridge.attachHost(host);
    final watched = ScriptEvents(h.bridge.watchEvents(chatId: chat));
    h.reply('RAW');
    final events = ScriptEvents(h.engine.send(chat, 'Q'));
    final received = await Future.any([
      receivedWritten.future,
      events.done.future.then<TavernScriptDispatch>((_) => throw TestFailure('Missing received hook.')),
    ]);
    expect(events.values.whereType<TavernTurnDone>(), isEmpty);
    expect(editedAcked.isCompleted, isFalse);
    final busy = await h.engine.send(chat, 'blocked while hook waits').toList();
    expect(busy.whereType<TavernTurnFailed>().single.kind, TavernFailure.busy);
    expect(h.requests, hasLength(1));
    final during = await h.bridge.snapshot(context.id);
    expect(during.lastSeq, greaterThanOrEqualTo(received.seq));
    expect(during.messages.last.message, 'HOOK BODY');
    final resumed = ScriptEvents(h.engine.resumeTurn(chat));
    final resumedSnapshot = await resumed.until((event) => event is TavernTurnSnapshot) as TavernTurnSnapshot;
    expect(resumedSnapshot.message!.text, 'HOOK BODY');
    expect(resumedSnapshot.message!.nodeId, received.nodeRef!.nodeId);
    expect(h.requests, hasLength(1));
    await resumed.detach();
    expect(
      host.deliveries.where((e) => e.eventId == received.eventId),
      hasLength(1),
      reason: 'Taking a snapshot does not recreate or acknowledge pending lifecycle.',
    );
    releaseReceived.complete();
    await events.done.future;
    await editedAcked.future;
    await ended.future;
    final done = events.values.whereType<TavernTurnDone>().single;
    expect(done.message.text, 'HOOK BODY');
    expect(done.hookIssues, isEmpty);
    expect(events.values.whereType<TavernTurnFailed>(), isEmpty);
    expect(h.engine.globalVariables['output'], 1, reason: 'Hook edits never replay output regex.');
    expect(host.deliveries.where((e) => e.name == 'MESSAGE_RECEIVED'), hasLength(1));
    expect(host.deliveries.where((e) => e.name == 'MESSAGE_EDITED'), hasLength(1));
    expect(host.deliveries.where((e) => e.name == 'MESSAGE_UPDATED'), isEmpty);
    await watched.until((event) => event.dispatch.eventId == received.eventId && event.phase == 'acknowledged');
    expect(
      h.requests.single.body,
      scriptWire([
        {'role': 'user', 'content': 'Q'},
      ]),
    );
    await h.reopen();
    final fresh = await h.context(chat, characterId: character);
    expect((await h.engine.path(chat)).last.text, 'HOOK BODY');
    expect((await h.bridge.getVariables(fresh.id, scriptMessage)).value, {
      'stat_data': {'hp': 7},
    });
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('hook and model failures retain distinct terminal payloads and committed effects', () async {
    final h = await ScriptFixture.open(allowModel: true);
    final character = await h.card('Hook failure');
    final chat = await h.emptyChat(character);
    await h.engine.setGlobalVariables({'output': 0});
    await h.engine.setSettings({
      'globalRegexScripts': [_outputCounter()],
    });
    final context = await h.context(chat, characterId: character);
    final host = ScriptHost();
    host.onDispatch = (request, cancellation) async {
      if (request.name == 'MESSAGE_RECEIVED') {
        await h.bridge.replaceVariables(
          context.id,
          TavernVariableTarget(scope: TavernVariableScope.message, messageRef: request.nodeRef),
          {'kept': true},
        );
        return TavernScriptDispatchAck(
          eventId: request.eventId,
          status: TavernScriptAckStatus.failed,
          issues: [
            TavernScriptIssue(
              code: 'fixtureHook',
              message: 'Synthetic host handler failure',
              committed: true,
              eventId: request.eventId,
              nodeRef: request.nodeRef,
            ),
          ],
        );
      }
      return TavernScriptDispatchAck(eventId: request.eventId);
    };
    h.bridge.attachHost(host);
    final watched = ScriptEvents(h.bridge.watchEvents(chatId: chat));
    h.reply('RAW');
    final events = await h.engine.send(chat, 'Q').toList();
    final done = events.whereType<TavernTurnDone>().single;
    expect(done.message.text, '1FINAL');
    expect(events.whereType<TavernTurnFailed>(), isEmpty);
    expect(done.hookIssues.map((issue) => issue.code), contains('fixtureHook'));
    expect(done.hookIssues.every((issue) => issue.committed), isTrue);
    expect(h.engine.globalVariables['output'], 1);
    expect((await h.bridge.getVariables(context.id, scriptMessage)).value, {'kept': true});
    expect((await h.engine.inspectTurn(chat, nodeId: done.message.nodeId))!.status, TavernInspectionStatus.completed);
    final failure = await watched.until((event) => event.name == 'MESSAGE_RECEIVED' && event.phase == 'failed');
    expect(failure.committed, isTrue);
    expect(failure.issues.map((issue) => issue.code), contains('fixtureHook'));
    final hookEnd = await watched.until((event) => event.name == 'GENERATION_ENDED' && event.phase == 'acknowledged');
    final hookPayload = scriptMap(hookEnd.dispatch.args.single);
    expect(hookPayload['status'], 'completed');
    expect(hookPayload['committed'], isTrue);
    expect(hookPayload['modelFailure'], isNull);
    expect(hookPayload['replyRef'], {'chatId': chat, 'nodeId': done.message.nodeId});
    expect(hookPayload['partialRef'], isNull);
    expect(
      (hookPayload['hookIssues']! as List<Object?>).map((issue) => scriptMap(issue)['code']),
      contains('fixtureHook'),
    );
    h.reply('denied', status: 401);
    final failedTurn = await h.engine.send(chat, 'failed Q').toList();
    expect(failedTurn.whereType<TavernTurnDone>(), isEmpty);
    final modelFailure = failedTurn.whereType<TavernTurnFailed>().single;
    expect(modelFailure.kind, TavernFailure.badKey);
    expect(modelFailure.partial, isNull);
    final failedEnd = await watched.until(
      (event) =>
          event.name == 'GENERATION_ENDED' &&
          event.phase == 'acknowledged' &&
          event.dispatch.generationId != hookEnd.dispatch.generationId,
    );
    final failedPayload = scriptMap(failedEnd.dispatch.args.single);
    expect(failedPayload['status'], 'failed');
    expect(failedPayload['committed'], isFalse);
    expect(failedPayload['modelFailure'], 'badKey');
    expect(failedPayload['replyRef'], isNull);
    expect(failedPayload['partialRef'], isNull);
    expect(
      host.deliveries.where(
        (event) => event.name == 'MESSAGE_RECEIVED' && event.generationId == failedEnd.dispatch.generationId,
      ),
      isEmpty,
    );
    expect((await h.engine.path(chat)).map((message) => message.text), ['Q', '1FINAL']);
    expect(h.engine.globalVariables['output'], 1);
    await h.reopen();
    expect((await h.engine.path(chat)).last.text, '1FINAL');
    final fresh = await h.context(chat, characterId: character);
    expect((await h.bridge.getVariables(fresh.id, scriptMessage)).value, {'kept': true});
    expect(h.requests, hasLength(2));
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('detaching a host releases an unacknowledged hook and ignores its late acknowledgement', () async {
    final h = await ScriptFixture.open(allowModel: true);
    final character = await h.card('Detach');
    final chat = await h.emptyChat(character);
    final context = await h.context(chat, characterId: character);
    final host = ScriptHost();
    final received = Completer<(TavernScriptDispatch, TavernScriptCancellation)>();
    final lateAck = Completer<TavernScriptDispatchAck>();
    addTearDown(() {
      if (!lateAck.isCompleted && received.isCompleted) {
        lateAck.complete(TavernScriptDispatchAck(eventId: 'late-cleanup'));
      }
    });
    host.onDispatch = (request, cancellation) async {
      if (request.name == 'MESSAGE_RECEIVED') {
        await h.bridge.replaceVariables(
          context.id,
          TavernVariableTarget(scope: TavernVariableScope.message, messageRef: request.nodeRef),
          {'beforeDetach': true},
        );
        received.complete((request, cancellation));
        return lateAck.future;
      }
      return TavernScriptDispatchAck(eventId: request.eventId);
    };
    h.bridge.attachHost(host);
    final watched = ScriptEvents(h.bridge.watchEvents(chatId: chat));
    h.reply('first');
    final turn = ScriptEvents(h.engine.send(chat, 'Q'));
    final held = await Future.any([
      received.future,
      turn.done.future.then<(TavernScriptDispatch, TavernScriptCancellation)>(
        (_) => throw TestFailure('Turn did not reach held received hook.'),
      ),
    ]);
    h.bridge.attachHost(null);
    await held.$2.whenCancelled;
    await turn.done.future;
    final done = turn.values.whereType<TavernTurnDone>().single;
    expect(done.message.text, 'first');
    expect(done.hookIssues.any((issue) => issue.code == 'hostUnavailable'), isTrue);
    final failed = await watched.until((event) => event.dispatch.eventId == held.$1.eventId && event.phase == 'failed');
    expect(failed.committed, isTrue);
    lateAck.complete(TavernScriptDispatchAck(eventId: held.$1.eventId));
    h.reply('second');
    final next = await h.engine.send(chat, 'next').toList();
    expect(next.whereType<TavernTurnDone>().single.message.text, 'second');
    expect(watched.values.where((event) => event.dispatch.eventId == held.$1.eventId).map((event) => event.phase), [
      'published',
      'failed',
    ]);
    expect(
      (await h.bridge.getVariables(
        context.id,
        TavernVariableTarget(scope: TavernVariableScope.message, messageRef: held.$1.nodeRef),
      )).value,
      {'beforeDetach': true},
    );
    expect(h.requests, hasLength(2));
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('snapshot recovery preserves deltas and resource cancellation releases its carrier waits', () async {
    final h = await ScriptFixture.open();
    final character = await h.card('Cache recovery');
    final chat = await h.emptyChat(character);
    final context = await h.context(chat, characterId: character);
    final host = ScriptHost();
    final recovered = <TavernScriptSnapshot>[];
    final firstCache = Completer<void>();
    final releaseFirstCache = Completer<void>();
    final globalCache = Completer<TavernScriptDispatch>();
    addTearDown(() {
      if (!releaseFirstCache.isCompleted) {
        releaseFirstCache.complete();
      }
    });
    host.onDispatch = (request, cancellation) async {
      if (request.kind == TavernScriptDispatchKind.cache) {
        final snapshot = await h.bridge.snapshot(context.id);
        expect(snapshot.lastSeq, greaterThanOrEqualTo(request.seq));
        recovered.add(snapshot);
        final delta = request.delta!;
        if (!firstCache.isCompleted && delta.upsertMessages.any((message) => message.message == 'recover me')) {
          firstCache.complete();
          await releaseFirstCache.future;
        }
        if (!globalCache.isCompleted &&
            delta.variableSnapshots.any(
              (value) =>
                  value.resolvedTarget.scope == TavernVariableScope.global && value.value['afterPull'] == 'committed',
            )) {
          globalCache.complete(request);
        }
      }
      return TavernScriptDispatchAck(eventId: request.eventId);
    };
    h.bridge.attachHost(host);
    final create = h.bridge.createChatMessages(context.id, [
      TavernScriptMessageDraft(role: TavernScriptRole.assistant, message: 'recover me', data: {'value': 1}),
    ], options: const TavernScriptWriteOptions(refresh: TavernScriptRefresh.none));
    await Future.any<void>([
      firstCache.future,
      create.then<void>((_) => throw StateError('The message write completed before its held cache delivery.')),
    ]);
    // A real carrier commit occurs while the earlier cache Ack is held. A pull
    // must see it without moving the baseline used by the still-pending delta.
    await h.engine.setGlobalVariables({'afterPull': 'committed'});
    final cardFile = File('${h.root.path}/characters/$character/card.json');
    final cardRaw = scriptMap(jsonDecode(await cardFile.readAsString()));
    scriptMap(cardRaw['data'])['description'] = 'Resource changed while the cache Ack is held.';
    await cardFile.writeAsString(jsonEncode(cardRaw), flush: true);
    final pulled = await h.bridge.snapshot(context.id);
    expect(
      pulled.variableSnapshots.singleWhere((value) => value.resolvedTarget.scope == TavernVariableScope.global).value,
      {'afterPull': 'committed'},
    );
    final pulledCard = scriptMap(pulled.resourceRefs['characterData']);
    expect(scriptMap(pulledCard['data'])['description'], 'Resource changed while the cache Ack is held.');
    releaseFirstCache.complete();
    final created = await create;
    final deliveredGlobal = await globalCache.future;
    expect(
      deliveredGlobal.delta!.variableSnapshots
          .singleWhere((value) => value.resolvedTarget.scope == TavernVariableScope.global)
          .value,
      {'afterPull': 'committed'},
    );
    expect(deliveredGlobal.delta!.resourceRefs['characterData'], pulledCard);
    expect(created.upsertMessages.single.message, 'recover me');
    expect(
      recovered.any((snapshot) => snapshot.messages.length == 1 && snapshot.messages.single.message == 'recover me'),
      isTrue,
    );
    expect(host.deliveries.where((request) => request.name != null), isEmpty);
    h.expectNoGeneration();

    // listen() registers the native turn synchronously. Its first view awaits
    // the global carrier before it can enqueue the character/preset read.
    // The real resource mutation below therefore owns its resource queue
    // while cancelling and draining that turn. No host or file fake unlocks it.
    h.bridge.attachHost(null);
    final deletedCharacter = await h.card('Delete during script view');
    final deletedChat = await h.emptyChat(deletedCharacter);
    final deletedContext = await h.context(
      deletedChat,
      characterId: deletedCharacter,
      instanceId: 'delete-while-reading',
    );
    final deletingTurn = h.engine.send(deletedChat, 'must not reach a key').toList();
    final deleting = h.engine.deleteCharacter(deletedCharacter);
    await deleting;
    final deletedEvents = await deletingTurn;
    expect(deletedEvents.whereType<TavernTurnFailed>().single.kind, TavernFailure.cancelled);
    expect(deletedEvents.whereType<TavernTurnDone>(), isEmpty);
    expect(await h.engine.character(deletedCharacter), isNull);
    await h.bridge.closeContext(deletedContext.id);

    final presetRaw = scriptPreset().raw
      ..['name'] = 'Preset carrier cancellation'
      ..['extensions'] = {'tavern_helper': scriptContainer('P')};
    final preset = (await h.engine.importPreset(jsonEncode(presetRaw))).preset.id;
    final presetChat = await h.emptyChat(character);
    await h.engine.bindPreset(presetChat, preset);
    final presetContext = await h.context(
      presetChat,
      owner: TavernScriptOwner(kind: TavernScriptOwnerKind.preset, assetId: preset, scriptId: 'same-script'),
      instanceId: 'bind-while-reading',
    );
    final bindingTurn = h.engine.send(presetChat, 'must not reach another key').toList();
    final binding = h.engine.bindPreset(presetChat, null);
    await binding;
    final boundEvents = await bindingTurn;
    expect(boundEvents.whereType<TavernTurnFailed>().single.kind, TavernFailure.cancelled);
    expect(boundEvents.whereType<TavernTurnDone>(), isEmpty);
    expect((await h.engine.presetSelection(chatId: presetChat)).boundPresetId, isNull);
    expect(await h.engine.path(presetChat), isEmpty);
    await h.bridge.closeContext(presetContext.id);
    h.expectNoGeneration();
    await h.reopen();
    expect(await h.engine.character(deletedCharacter), isNull);
    expect((await h.engine.presetSelection(chatId: presetChat)).boundPresetId, isNull);
    expect(await h.engine.path(presetChat), isEmpty);
    h.expectNoGeneration();
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('group B reads A hook writes and final story settlement preserves B hook body and data', () async {
    final h = await ScriptFixture.open(allowModel: true);
    final owner = await h.card(
      'Host',
      extensions: {
        'dshgo': {
          'v': 1,
          'story': {
            'acts': [
              {'id': 'waiting', 'title': 'WAIT', 'when': false},
            ],
          },
        },
      },
    );
    final a = await h.card('A');
    final b = await h.card('B');
    final chat = await h.engine.createGroupChat(
      [a, b],
      hostCharacterId: owner,
      activation: TavernGroupActivation.listOrder,
      addGreetings: false,
    );
    await h.engine.setSettings({
      'director': {'enabled': true, 'every': 2},
    }, chatId: chat);
    await h.engine.setPreset(scriptPreset(main: 'PHASE {{getvar::phase}}'));
    final context = await h.context(chat, characterId: owner);
    await h.bridge.replaceVariables(context.id, scriptChat, {'phase': 'INIT'});
    final host = ScriptHost();
    final receivedRefs = <TavernScriptMessageRef>[];
    host.onDispatch = (request, cancellation) async {
      if (request.name == 'MESSAGE_RECEIVED') {
        final ref = request.nodeRef!;
        final message = (await h.engine.path(chat)).singleWhere((m) => m.nodeId == ref.nodeId);
        receivedRefs.add(ref);
        if (message.speakerCharacterId == a) {
          await h.bridge.replaceVariables(
            context.id,
            TavernVariableTarget(scope: TavernVariableScope.message, messageRef: ref),
            {
              'stat_data': {'hp': 7},
            },
          );
          await h.bridge.replaceVariables(context.id, scriptChat, {'phase': 'AFTER_A'});
          await h.bridge.setChatMessages(context.id, [
            TavernScriptMessagePatch(ref: ref, fields: {'message': 'A HOOK'}),
          ], options: const TavernScriptWriteOptions(refresh: TavernScriptRefresh.none));
        } else if (message.speakerCharacterId == b) {
          await h.bridge.replaceVariables(
            context.id,
            TavernVariableTarget(scope: TavernVariableScope.message, messageRef: ref),
            {
              'stat_data': {'hp': 9},
            },
          );
          await h.bridge.setChatMessages(context.id, [
            TavernScriptMessagePatch(
              ref: ref,
              fields: {
                'message': 'B HOOK',
                'extra': {'callback': 'B'},
              },
            ),
          ], options: const TavernScriptWriteOptions(refresh: TavernScriptRefresh.none));
        }
      }
      return TavernScriptDispatchAck(eventId: request.eventId);
    };
    h.bridge.attachHost(host);
    h.reply('A RAW');
    final second = h.reply('B RAW');
    second.beforeResponse = () async {
      final rows = h.inspect(
        (db) => db
            .select('SELECT text FROM nodes WHERE chat_id = ? AND speaker_character_id = ?', [chat, a])
            .map((row) => row['text'])
            .toList(),
      );
      expect(rows, ['A HOOK']);
      expect((await h.bridge.getVariables(context.id, scriptMessage)).value, {
        'stat_data': {'hp': 7},
      });
      expect((await h.engine.readDirector(chat)).story!['initialized'], isFalse);
    };
    final events = await h.engine.sendGroup(chat, 'Q').toList();
    expect(events.whereType<TavernGroupFinished>().single.reason, TavernGroupEndReason.completed);
    final done = events.whereType<TavernGroupMemberEvent>().map((e) => e.event).whereType<TavernTurnDone>().toList();
    expect(done.map((e) => e.message.text), ['A HOOK', 'B HOOK']);
    expect(done.every((e) => e.hookIssues.isEmpty), isTrue);
    expect(h.requests.map((r) => r.body), [
      scriptWire([
        {'role': 'system', 'content': 'PHASE INIT'},
        {'role': 'user', 'content': 'Q'},
      ]),
      scriptWire([
        {'role': 'system', 'content': 'PHASE AFTER_A'},
        {'role': 'user', 'content': 'Q'},
        {'role': 'assistant', 'content': 'A: A HOOK'},
      ]),
    ]);
    expect((await h.engine.path(chat)).map((m) => m.text), ['Q', 'A HOOK', 'B HOOK']);
    expect((await h.bridge.getVariables(context.id, scriptMessage)).value, {
      'stat_data': {'hp': 9},
    });
    expect(
      (await h.bridge.getChatMessages(context.id, const TavernMessageRange())).messages.last.extra['callback'],
      'B',
    );
    expect(
      (await h.bridge.getVariables(
        context.id,
        TavernVariableTarget(scope: TavernVariableScope.message, messageRef: receivedRefs.first),
      )).value,
      {
        'stat_data': {'hp': 7},
      },
    );
    final runs = await h.engine.readAgentRuns(chat, limit: 1000);
    expect(runs.where((run) => run.kind == 'story.rules'), hasLength(1));
    expect((await h.engine.readDirector(chat)).story!['actTurns'], 1);
    expect(host.deliveries.where((e) => e.name == 'MESSAGE_RECEIVED'), hasLength(2));
    await h.reopen();
    final fresh = await h.context(chat, characterId: owner);
    expect((await h.engine.path(chat)).map((m) => m.text), ['Q', 'A HOOK', 'B HOOK']);
    expect((await h.bridge.getVariables(fresh.id, scriptMessage)).value, {
      'stat_data': {'hp': 9},
    });
    expect((await h.bridge.getChatMessages(fresh.id, const TavernMessageRange())).messages.last.extra['callback'], 'B');
    expect((await h.engine.readDirector(chat)).story!['actTurns'], 1);
    expect(h.requests, hasLength(2));
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('an ended handler may await the next main generation with a distinct lifecycle identity', () async {
    final h = await ScriptFixture.open(allowModel: true);
    final character = await h.card('Chain');
    final chat = await h.emptyChat(character);
    await h.context(chat, characterId: character);
    final host = ScriptHost();
    final chained = Completer<List<TavernEvent>>();
    final secondEnded = Completer<void>();
    var startedNext = false;
    host.onDispatch = (request, cancellation) async {
      if (request.name == 'GENERATION_ENDED') {
        if (!startedNext) {
          startedNext = true;
          final next = await h.engine.send(chat, 'Q2').toList();
          chained.complete(next);
        } else {
          secondEnded.complete();
        }
      }
      return TavernScriptDispatchAck(eventId: request.eventId);
    };
    h.bridge.attachHost(host);
    h.reply('first');
    h.reply('second');
    final first = await h.engine.send(chat, 'Q1').toList();
    expect(first.whereType<TavernTurnDone>().single.message.text, 'first');
    final next = await chained.future;
    await secondEnded.future;
    expect(next.whereType<TavernTurnFailed>(), isEmpty);
    expect(next.whereType<TavernTurnDone>().single.message.text, 'second');
    final starts = host.deliveries.where((e) => e.name == 'GENERATION_STARTED').toList();
    expect(starts, hasLength(2));
    expect(starts.map((e) => e.generationId).toSet(), hasLength(2));
    expect(starts.every((e) => e.generationId != null), isTrue);
    expect(host.deliveries.where((e) => e.name == 'GENERATION_ENDED'), hasLength(2));
    expect(h.requests.map((r) => r.body), [
      scriptWire([
        {'role': 'user', 'content': 'Q1'},
      ]),
      scriptWire([
        {'role': 'user', 'content': 'Q1'},
        {'role': 'assistant', 'content': 'first'},
        {'role': 'user', 'content': 'Q2'},
      ]),
    ]);
    expect((await h.engine.path(chat)).map((m) => m.text), ['Q1', 'first', 'Q2', 'second']);
  }, timeout: const Timeout(Duration(seconds: 15)));

  test(
    'a structure mutation from received cancels its outer group without waiting on its own acknowledgement',
    () async {
      final h = await ScriptFixture.open(allowModel: true);
      final a = await h.card('A');
      final b = await h.card('B');
      final chat = await h.engine.createGroupChat(
        [a, b],
        activation: TavernGroupActivation.listOrder,
        addGreetings: false,
      );
      final context = await h.context(chat, characterId: a);
      final host = ScriptHost();
      final mutationDone = Completer<TavernScriptMutation>();
      var invoked = false;
      host.onDispatch = (request, cancellation) async {
        if (request.name == 'MESSAGE_RECEIVED' && !invoked) {
          invoked = true;
          await h.bridge.replaceVariables(
            context.id,
            TavernVariableTarget(scope: TavernVariableScope.message, messageRef: request.nodeRef),
            {'beforeDelete': true},
          );
          final deleted = await h.bridge.deleteChatMessages(context.id, [
            0,
          ], options: const TavernScriptWriteOptions(refresh: TavernScriptRefresh.none));
          mutationDone.complete(deleted);
        }
        return TavernScriptDispatchAck(eventId: request.eventId);
      };
      h.bridge.attachHost(host);
      final watched = ScriptEvents(h.bridge.watchEvents(chatId: chat));
      h.reply('A complete');
      h.reply('B must not be requested');
      final events = await h.engine.sendGroup(chat, 'one user').toList();
      final mutation = await mutationDone.future;
      expect(events.whereType<TavernGroupFinished>().single.reason, TavernGroupEndReason.cancelled);
      expect(mutation.removedRefs, hasLength(1));
      expect((await h.engine.path(chat)).map((m) => m.text), ['A complete']);
      expect((await h.engine.path(chat)).single.parentId, isNull);
      expect((await h.bridge.getVariables(context.id, scriptMessage)).value, {'beforeDelete': true});
      final stopped = await watched.until(
        (event) => event.name == 'GENERATION_STOPPED' && event.phase == 'acknowledged',
      );
      final stoppedPayload = scriptMap(stopped.dispatch.args.single);
      expect(stoppedPayload['status'], 'completed');
      expect(stoppedPayload['cancelled'], isTrue);
      expect(stoppedPayload['committed'], isTrue);
      expect(stoppedPayload['modelFailure'], isNull);
      expect(stoppedPayload['replyRef'], {'chatId': chat, 'nodeId': (await h.engine.path(chat)).single.nodeId});
      expect(stoppedPayload['partialRef'], isNull);
      expect(h.requests, hasLength(1));
      expect(h.keyReads, 1);
      await h.reopen();
      expect((await h.engine.path(chat)).single.text, 'A complete');
    },
    timeout: const Timeout(Duration(seconds: 15)),
  );

  test('actor ended remains owned by the outer group when its handler changes structure', () async {
    final h = await ScriptFixture.open(allowModel: true);
    final a = await h.card('A');
    final b = await h.card('B');
    final chat = await h.engine.createGroupChat(
      [a, b],
      activation: TavernGroupActivation.listOrder,
      addGreetings: false,
    );
    final context = await h.context(chat, characterId: a);
    final host = ScriptHost();
    final structureAdmitted = Completer<void>();
    final structureDone = Completer<TavernScriptMutation>();
    addTearDown(() {
      if (!structureAdmitted.isCompleted) {
        structureAdmitted.complete();
      }
    });
    var starts = 0;
    var changed = false;
    host.onDispatch = (request, cancellation) async {
      if (request.name == 'GENERATION_STARTED') {
        starts++;
        if (starts > 1) {
          await structureAdmitted.future;
        }
      } else if (request.name == 'GENERATION_ENDED' && !changed) {
        changed = true;
        final writing = h.bridge.createChatMessages(context.id, [
          TavernScriptMessageDraft(role: TavernScriptRole.system, message: 'STRUCTURE'),
        ], options: const TavernScriptWriteOptions(refresh: TavernScriptRefresh.none));
        structureAdmitted.complete();
        structureDone.complete(await writing);
      }
      return TavernScriptDispatchAck(eventId: request.eventId);
    };
    h.bridge.attachHost(host);
    h.reply('A complete');
    h.reply('B must not be requested');
    final events = await h.engine.sendGroup(chat, 'Q').toList();
    await structureDone.future;
    expect(events.whereType<TavernGroupFinished>().single.reason, TavernGroupEndReason.cancelled);
    expect((await h.engine.path(chat)).map((m) => m.text), ['Q', 'A complete', 'STRUCTURE']);
    expect(h.requests, hasLength(1));
    expect(h.keyReads, 1);
    expect((await h.engine.groupChat(chat))!.members.map((m) => m.characterId), [a, b]);
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('engine close cancels host waits and preserves commits without waiting for arbitrary host code', () async {
    final h = await ScriptFixture.open(allowModel: true);
    final character = await h.card('Close');
    final chat = await h.emptyChat(character);
    await h.context(chat, characterId: character);
    final host = ScriptHost();
    final entered = Completer<TavernScriptDispatch>();
    final late = Completer<TavernScriptDispatchAck>();
    addTearDown(() {
      if (!late.isCompleted) {
        late.complete(TavernScriptDispatchAck(eventId: 'cleanup'));
      }
    });
    host.onDispatch = (request, cancellation) async {
      if (request.name == 'MESSAGE_RECEIVED') {
        entered.complete(request);
        return late.future;
      }
      return TavernScriptDispatchAck(eventId: request.eventId);
    };
    h.bridge.attachHost(host);
    h.reply('kept');
    final turn = ScriptEvents(h.engine.send(chat, 'Q'));
    final received = await Future.any([
      entered.future,
      turn.done.future.then<TavernScriptDispatch>((_) => throw TestFailure('Missing hook before close.')),
    ]);
    await h.close();
    await turn.done.future;
    late.complete(TavernScriptDispatchAck(eventId: received.eventId));
    await h.openEngine();
    expect((await h.engine.path(chat)).map((m) => m.text), ['Q', 'kept']);
    expect(turn.values.whereType<TavernTurnDone>().single.hookIssues, isNotEmpty);
    expect(h.requests, hasLength(1));
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('raw CRUD maps its own events without fabricating sent received or rendered events', () async {
    final h = await ScriptFixture.open();
    final character = await h.card('Events');
    final chat = await h.emptyChat(character);
    final context = await h.context(chat, characterId: character);
    final host = ScriptHost();
    h.bridge.attachHost(host);
    final watched = ScriptEvents(h.bridge.watchEvents(chatId: chat));
    const quiet = TavernScriptWriteOptions(refresh: TavernScriptRefresh.none);
    final made = await h.bridge.createChatMessages(context.id, [
      TavernScriptMessageDraft(role: TavernScriptRole.assistant, message: 'raw', data: {'v': 0}),
    ], options: quiet);
    final ref = made.upsertMessages.single.ref;
    await h.bridge.replaceVariables(
      context.id,
      TavernVariableTarget(scope: TavernVariableScope.message, messageRef: ref),
      {'v': 1},
    );
    await h.bridge.setChatMessages(context.id, [
      TavernScriptMessagePatch(ref: ref, fields: {'message': 'edited'}),
    ], options: quiet);
    await watched.until((e) => e.name == 'MESSAGE_EDITED' && e.phase == 'acknowledged');
    await h.bridge.setChatMessages(context.id, [
      TavernScriptMessagePatch(ref: ref, fields: {'name': 'New name'}),
    ], options: quiet);
    await watched.until((e) => e.name == 'MESSAGE_UPDATED' && e.phase == 'acknowledged');
    await h.bridge.setChatMessages(context.id, [
      TavernScriptMessagePatch(
        ref: ref,
        fields: {
          'swipes': ['edited', 'alternate'],
        },
      ),
    ], options: quiet);
    final switched = await h.bridge.selectSwipe(context.id, ref, 1, options: quiet);
    final swipeEvent = await watched.until((e) => e.name == 'MESSAGE_SWIPED' && e.phase == 'acknowledged');
    expect(swipeEvent.dispatch.nodeRef, switched.upsertMessages.last.ref);
    final deleted = await h.bridge.deleteChatMessages(context.id, [0], options: quiet);
    expect(deleted.removedRefs, hasLength(2));
    await watched.until((e) => e.name == 'MESSAGE_DELETED' && e.phase == 'acknowledged');
    expect(
      host.deliveries.where(
        (e) => e.name == 'MESSAGE_SENT' || e.name == 'MESSAGE_RECEIVED' || e.name?.endsWith('_RENDERED') == true,
      ),
      isEmpty,
    );
    expect(host.refreshes, isEmpty);
    final sent = await h.engine.sendOnly(chat, 'manual');
    final narrated = await h.engine.narrate(chat, 'narrated');
    await watched.until(
      (e) => e.name == 'MESSAGE_SENT' && e.phase == 'acknowledged' && e.dispatch.nodeRef?.nodeId == narrated.nodeId,
    );
    expect(host.deliveries.where((e) => e.name == 'MESSAGE_SENT').map((e) => e.nodeRef?.nodeId), [
      sent.nodeId,
      narrated.nodeId,
    ]);
    expect(host.deliveries.where((e) => e.name == 'MESSAGE_RECEIVED'), isEmpty);
    final cacheOnly = host.deliveries.where((e) => e.kind == TavernScriptDispatchKind.cache);
    expect(cacheOnly.every((e) => e.name == null && e.namespace == null), isTrue);
    final seq = host.deliveries.map((e) => e.seq).toList();
    expect(seq.toSet().length, seq.length);
    expect(host.deliveries.map((e) => e.eventId).toSet().length, host.deliveries.length);
    h.expectNoGeneration();
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('preparation cancellation preserves committed handler variables and the next native macro view', () async {
    final h = await ScriptFixture.open();
    final character = await h.card('Preparation stop');
    final chat = await h.emptyChat(character);
    final prior = await h.engine.sendOnly(chat, 'prior');
    final context = await h.context(chat, characterId: character);
    await h.bridge.replaceVariables(context.id, scriptChat, {'before': 3});
    final prepared = Completer<void>();
    final release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) {
        release.complete();
      }
    });
    final host = ScriptHost();
    host.onDispatch = (request, cancellation) async {
      if (request.name == 'GENERATION_AFTER_COMMANDS') {
        await h.bridge.replaceVariables(context.id, scriptChat, {'kept': 7});
        await h.bridge.replaceVariables(context.id, scriptGlobal, {'prepGlobal': 'kept'});
        prepared.complete();
        await release.future;
      }
      return TavernScriptDispatchAck(eventId: request.eventId);
    };
    h.bridge.attachHost(host);
    final turn = ScriptEvents(h.engine.send(chat, 'must not be appended'));
    await Future.any<void>([
      prepared.future,
      turn.done.future.then<void>((_) => throw StateError('Turn ended before its preparation write.')),
    ]);
    expect((await h.bridge.getVariables(context.id, scriptChat)).value, {'kept': 7});
    h.expectNoGeneration();
    h.engine.stop(chat);
    await turn.done.future;
    expect(release.isCompleted, isFalse);
    final failure = turn.values.whereType<TavernTurnFailed>().single;
    expect(failure.kind, TavernFailure.cancelled);
    expect(failure.partial, isNull);
    expect(turn.values.whereType<TavernTurnDone>(), isEmpty);
    expect((await h.engine.path(chat)).map((message) => message.nodeId), [prior.nodeId]);
    expect((await h.bridge.getVariables(context.id, scriptChat)).value, {'kept': 7});
    expect((await h.bridge.getVariables(context.id, scriptGlobal)).value, {'prepGlobal': 'kept'});
    h.bridge.attachHost(null);
    release.complete();
    final macro = await h.engine.sendOnly(chat, 'LOCAL {{getvar::kept}}');
    expect(macro.text, 'LOCAL 7');
    h.expectNoGeneration();
    await h.reopen();
    final fresh = await h.context(chat, characterId: character);
    expect((await h.bridge.getVariables(fresh.id, scriptChat)).value, {'kept': 7});
    expect((await h.bridge.getVariables(fresh.id, scriptGlobal)).value, {'prepGlobal': 'kept'});
    expect((await h.engine.path(chat)).map((message) => message.text), ['prior', 'LOCAL 7']);
    h.expectNoGeneration();
  }, timeout: const Timeout(Duration(seconds: 15)));
}

ScriptJson _outputCounter() => {
  'id': 'output-counter',
  'scriptName': 'output-counter',
  'findRegex': r'^RAW$',
  'replaceString': '{{incglobalvar::output}}FINAL',
  'trimStrings': <String>[],
  'placement': [2],
  'disabled': false,
  'markdownOnly': false,
  'promptOnly': false,
  'runOnEdit': false,
  'substituteRegex': 0,
  'minDepth': null,
  'maxDepth': null,
};
