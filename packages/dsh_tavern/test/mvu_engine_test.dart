import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_script_test_support.dart' show ScriptHost;
import 'support/t24_engine_harness.dart';

void main() {
  test('disabled InitVar initializes every opening swipe and stays out of the prompt', () async {
    final h = await T24Harness.open(thinking: false);
    addTearDown(h.dispose);
    final opening = await _openingSwipes(h);
    final bridge = h.engine.scripts;
    final context = await bridge.openContext(
      TavernScriptContextSpec(
        instanceId: 'mvu-opening-swipes',
        chatId: opening.chatId,
        characterId: opening.characterId,
      ),
    );
    final before = await bridge.getChatMessages(context.id, const TavernMessageRange(), includeSwipes: true);
    final refs = before.messages.single.swipes.map((swipe) => swipe.ref).toList();
    expect(before.messages.single.messageId, 0);
    expect(before.messages.single.swipeId, 1);
    final initialized = <Object?>[];
    final host = ScriptHost();
    host.onDispatch = (request, cancellation) async {
      if (request.name == 'mag_variable_initialized') {
        initialized.add([
          request.nodeRef,
          request.args[1],
          _object(_object(request.args.first)['stat_data'])['counter'],
        ]);
        // Each event offers its candidate; neither page is stored until all
        // opening candidates have finished their own update commands.
        for (var index = 0; index < refs.length; index++) {
          final saved = await _read(bridge, context.id, opening.chatId, refs[index].nodeId);
          expect(saved.value, {'external_note': index == 0 ? 'keep-a' : 'keep-b'});
        }
      }
      return TavernScriptDispatchAck(eventId: request.eventId);
    };
    bridge.attachHost(host);

    final ready = await bridge.setMvuEnabled(context.id, true);
    expect(ready.issues, isEmpty);
    expect(ready.initializedRefs, refs);
    final book = await bridge.readBook(context.id, TavernScriptBookRef.embedded(characterId: opening.characterId));
    final entry = _object((book.book['entries']! as List<Object?>).first);
    expect(entry['comment'], '[iNiTvAr] opening defaults');
    expect(entry['enabled'], isFalse);
    expect(entry['constant'], isTrue);
    expect(initialized, [
      [refs[0], 0, 1],
      [refs[1], 1, 10],
    ]);
    final first = await _read(bridge, context.id, opening.chatId, refs[0].nodeId);
    final second = await _read(bridge, context.id, opening.chatId, refs[1].nodeId);
    expect(first.value['stat_data'], {'counter': 3, 'label': 'from-book'});
    expect(second.value['stat_data'], {'counter': 15, 'label': 'from-alternate'});
    expect(first.value['external_note'], 'keep-a');
    expect(second.value['external_note'], 'keep-b');
    for (final value in [first.value, second.value]) {
      expect(value['initialized_lorebooks'], {'embedded:${opening.characterId}': <Object?>[]});
    }
    final page = await bridge.getChatMessages(context.id, const TavernMessageRange(), includeSwipes: true);
    expect(page.messages.single.swipeId, 1);
    expect(page.messages.single.swipes.map((swipe) => swipe.data), [first.value, second.value]);

    await h.engine.selectSibling(opening.chatId, refs[1].nodeId, 0);
    expect((await bridge.getChatMessages(context.id, const TavernMessageRange())).messages.single.data, first.value);
    await bridge.selectSwipe(context.id, refs[0], 1);
    expect((await bridge.getChatMessages(context.id, const TavernMessageRange())).messages.single.data, second.value);
    expect((await bridge.setMvuEnabled(context.id, true)).initializedRefs, isEmpty);
    expect((await _read(bridge, context.id, opening.chatId, refs[0].nodeId)).version, first.version);
    expect((await _read(bridge, context.id, opening.chatId, refs[1].nodeId)).version, second.version);
    expect(initialized, hasLength(2));

    await h.reopen();
    final reopened = h.engine.scripts;
    final reopenedContext = await reopened.openContext(
      TavernScriptContextSpec(
        instanceId: 'mvu-opening-reopened',
        chatId: opening.chatId,
        characterId: opening.characterId,
      ),
    );
    expect((await _read(reopened, reopenedContext.id, opening.chatId, refs[0].nodeId)).value, first.value);
    expect((await _read(reopened, reopenedContext.id, opening.chatId, refs[1].nodeId)).value, second.value);
    expect(h.model.generated, 0);
    final turn = await _complete(h, h.engine.send(opening.chatId, 'Please record the current value.'), 'Recorded.');
    expect(turn.done.hookIssues, isEmpty);
    final request = jsonEncode(turn.request);
    expect(request, contains('当前记录：15'));
    expect(request, contains('OPENINGWORLDVISIBLECONTROL'));
    expect(request, isNot(contains('from-book')));
    expect(h.model.generated, 1);
  });

  test('opening initialization does not adopt an earlier page after a later phase conflicts', () async {
    final h = await T24Harness.open(thinking: false);
    addTearDown(h.dispose);
    final opening = await _openingSwipes(h);
    final bridge = h.engine.scripts;
    final context = await bridge.openContext(
      TavernScriptContextSpec(
        instanceId: 'mvu-opening-conflict',
        chatId: opening.chatId,
        characterId: opening.characterId,
      ),
    );
    final before = await bridge.getChatMessages(context.id, const TavernMessageRange(), includeSwipes: true);
    final refs = before.messages.single.swipes.map((swipe) => swipe.ref).toList();
    TavernVariableSnapshot? external;
    final initialized = <Object?>[];
    final host = ScriptHost();
    host.onDispatch = (request, cancellation) async {
      if (request.name == 'mag_variable_initialized') {
        initialized.add(request.args[1]);
        if (request.args[1] == 1) {
          final current = await _read(bridge, context.id, opening.chatId, refs[0].nodeId);
          external = await bridge.replaceVariables(
            context.id,
            TavernVariableTarget(scope: TavernVariableScope.message, messageRef: refs[0]),
            {...current.value, 'external_note': 'written during the second page'},
            expectedVersion: current.version,
          );
        }
      }
      return TavernScriptDispatchAck(eventId: request.eventId);
    };
    bridge.attachHost(host);

    await expectLater(
      bridge.setMvuEnabled(context.id, true),
      throwsA(
        isA<TavernScriptException>().having((error) => error.code, 'code', TavernScriptErrorCode.revisionConflict),
      ),
    );
    expect(initialized, [0, 1]);
    expect(external, isNotNull);
    expect((await _read(bridge, context.id, opening.chatId, refs[0].nodeId)).value, external!.value);
    expect(external!.value, {'external_note': 'written during the second page'});
    expect((await _read(bridge, context.id, opening.chatId, refs[1].nodeId)).value, {'external_note': 'keep-b'});
    expect(h.model.generated, 0);
  });

  test('MVU counter card initializes, updates twice and keeps physical reply branches', () async {
    final h = await T24Harness.open(thinking: false);
    addTearDown(h.dispose);
    final card = await h.engine.importCard(_mvuCard());
    final chatId = await h.engine.createChat(card.id);
    final greeting = (await h.engine.path(chatId)).single;
    final bridge = h.engine.scripts;
    final context = await bridge.openContext(
      TavernScriptContextSpec(instanceId: 'mvu-native-counter', chatId: chatId, characterId: card.id),
    );
    final host = ScriptHost();
    final cache = <String, TavernScriptMessage>{};
    final received = <Object?>[];
    final phases = <String>[];
    host.onDispatch = (request, cancellation) async {
      if (request.kind == TavernScriptDispatchKind.cache) {
        for (final message in request.delta?.upsertMessages ?? <TavernScriptMessage>[]) {
          cache[message.ref.nodeId] = message;
        }
      }
      final name = request.name;
      if (name != null && name.startsWith('mag_')) {
        phases.add(name);
      }
      if (name == 'MESSAGE_RECEIVED') {
        final ref = request.nodeRef!;
        final saved = await _read(bridge, context.id, chatId, ref.nodeId);
        expect(
          cache[ref.nodeId]!.data,
          saved.value,
          reason: 'The physical MVU value must reach the cache before RECEIVED.',
        );
        received.add(_object(saved.value['stat_data'])['counter']);
      }
      return TavernScriptDispatchAck(eventId: request.eventId);
    };
    bridge.attachHost(host);

    expect((await _read(bridge, context.id, chatId, greeting.nodeId)).value, isEmpty);
    final initialized = await bridge.setMvuEnabled(context.id, true);
    expect(initialized.chatId, chatId);
    expect(initialized.enabled, isTrue);
    expect(initialized.initializedRefs, [TavernScriptMessageRef(chatId: chatId, nodeId: greeting.nodeId)]);
    expect(initialized.issues, isEmpty);
    final initial = await _read(bridge, context.id, chatId, greeting.nodeId);
    _expectMvu(initial.value, 10, card.id);
    expect(cache[greeting.nodeId]!.data, initial.value);
    expect(phases, contains('mag_variable_initialized'));
    expect(h.model.generated, 0);
    final originalBook = await bridge.readBook(context.id, TavernScriptBookRef.embedded(characterId: card.id));
    final entry = _object((originalBook.book['entries']! as List<Object?>).single);
    expect(entry['enabled'], isFalse);
    expect(entry['content'], 'counter: 1\nlabel: from-book');

    final first = await _complete(
      h,
      h.engine.send(chatId, '请登记一项。'),
      '已增加一项记录。\n<UpdateVariable>\n'
      "_.add('counter', 1);\n"
      '</UpdateVariable>',
    );
    expect(first.done.hookIssues, isEmpty);
    expect(jsonEncode(first.request), contains('当前记录：10'));
    final firstData = await _read(bridge, context.id, chatId, first.done.message.nodeId);
    _expectMvu(firstData.value, 11, card.id);
    expect(firstData.value['display_data'], {'counter': '10->11 ', 'label': 'from-greeting'});
    expect(firstData.value['delta_data'], {'counter': '10->11 '});

    final second = await _complete(
      h,
      h.engine.send(chatId, '请将记录数定为十二。'),
      '已核对记录。\n<UpdateVariable>\n<JSONPatch>\n'
      '[{"op":"replace","path":"/counter","value":12}]\n'
      '</JSONPatch>\n'
      "_.add('missing', 1);\n"
      '</UpdateVariable>',
    );
    expect(jsonEncode(second.request), contains('当前记录：11'));
    expect(second.done.hookIssues, hasLength(1));
    expect(second.done.hookIssues.single.code, 'command_path_missing');
    expect(second.done.hookIssues.single.stage, 'mvu');
    expect(second.done.hookIssues.single.message, contains('missing'));
    final secondData = await _read(bridge, context.id, chatId, second.done.message.nodeId);
    _expectMvu(secondData.value, 12, card.id);
    expect(secondData.value['display_data'], {'counter': '11->12 (json_patch)', 'label': 'from-greeting'});
    expect(secondData.value['delta_data'], {'counter': '11->12 (json_patch)'});

    final alternate = await _complete(
      h,
      h.engine.regenerate(chatId, second.done.message.nodeId),
      '另存一份记录。\n<UpdateVariable>\n'
      "_.add('counter', 5);\n"
      '</UpdateVariable>',
    );
    expect(alternate.done.hookIssues, isEmpty);
    expect(alternate.done.message.nodeId, isNot(second.done.message.nodeId));
    expect(alternate.done.message.parentId, second.done.message.parentId);
    expect(jsonEncode(alternate.request), contains('当前记录：11'));
    final alternateData = await _read(bridge, context.id, chatId, alternate.done.message.nodeId);
    _expectMvu(alternateData.value, 16, card.id);
    expect(alternateData.value['delta_data'], {'counter': '11->16 '});
    expect(received, [11, 12, 16]);
    expect(h.model.generated, 3);

    final phaseCount = phases.length;
    await h.engine.selectNode(chatId, second.done.message.nodeId);
    final selectedOriginal = await _read(bridge, context.id, chatId, second.done.message.nodeId);
    expect(selectedOriginal.value, secondData.value);
    expect(selectedOriginal.version, secondData.version);
    await h.engine.selectNode(chatId, alternate.done.message.nodeId);
    final selectedAlternate = await _read(bridge, context.id, chatId, alternate.done.message.nodeId);
    expect(selectedAlternate.value, alternateData.value);
    expect(selectedAlternate.version, alternateData.version);
    final page = await bridge.getChatMessages(context.id, const TavernMessageRange(), includeSwipes: true);
    final swipes = page.messages.last.swipes;
    expect(swipes.map((swipe) => swipe.ref.nodeId).toSet(), {
      second.done.message.nodeId,
      alternate.done.message.nodeId,
    });
    expect(swipes.map((swipe) => _object(swipe.data!['stat_data'])['counter']).toSet(), {12, 16});
    expect(phases, hasLength(phaseCount));
    expect(h.model.generated, 3);

    await h.reopen();
    final reopened = h.engine.scripts;
    final reopenedContext = await reopened.openContext(
      TavernScriptContextSpec(instanceId: 'mvu-native-reopened', chatId: chatId, characterId: card.id),
    );
    expect((await _read(reopened, reopenedContext.id, chatId, second.done.message.nodeId)).value, secondData.value);
    expect(
      (await _read(reopened, reopenedContext.id, chatId, alternate.done.message.nodeId)).value,
      alternateData.value,
    );
    expect((await h.engine.path(chatId)).last.nodeId, alternate.done.message.nodeId);
    expect(h.model.generated, 3);
  });

  test('disabled declaration stays inert and explicit enable survives a closed context', () async {
    final h = await T24Harness.open(thinking: false);
    addTearDown(h.dispose);
    final card = await h.engine.importCard(_mvuCard(enabled: false));
    final chatId = await h.engine.createChat(card.id);
    final greeting = (await h.engine.path(chatId)).single;
    final off = await _complete(
      h,
      h.engine.send(chatId, '保持原记录。'),
      "未启用的正文。\n<UpdateVariable>_.add('counter', 1);</UpdateVariable>",
    );
    expect(off.done.hookIssues, isEmpty);
    final bridge = h.engine.scripts;
    final context = await bridge.openContext(
      TavernScriptContextSpec(instanceId: 'mvu-native-toggle', chatId: chatId, characterId: card.id),
    );
    expect((await _read(bridge, context.id, chatId, greeting.nodeId)).value, isEmpty);
    expect((await _read(bridge, context.id, chatId, off.done.message.nodeId)).value, isEmpty);

    await h.engine.selectNode(chatId, greeting.nodeId);
    final ready = await bridge.setMvuEnabled(context.id, true);
    expect(ready.enabled, isTrue);
    expect(ready.issues, isEmpty);
    _expectMvu((await _read(bridge, context.id, chatId, greeting.nodeId)).value, 10, card.id);
    await bridge.closeContext(context.id);
    final on = await _complete(
      h,
      h.engine.send(chatId, '继续登记。'),
      "已启用的正文。\n<UpdateVariable>_.add('counter', 1);</UpdateVariable>",
    );
    expect(on.done.hookIssues, isEmpty);
    final observer = await bridge.openContext(
      TavernScriptContextSpec(instanceId: 'mvu-native-observer', chatId: chatId, characterId: card.id),
    );
    _expectMvu((await _read(bridge, observer.id, chatId, on.done.message.nodeId)).value, 11, card.id);
    expect(h.model.generated, 2);
  });

  test('continue recomputes the full body and a phase write wins the native MVU CAS', () async {
    final h = await T24Harness.open(thinking: false);
    addTearDown(h.dispose);
    final card = await h.engine.importCard(_mvuCard());
    final chatId = await h.engine.createChat(card.id);
    final greeting = (await h.engine.path(chatId)).single;
    final bridge = h.engine.scripts;
    final context = await bridge.openContext(
      TavernScriptContextSpec(instanceId: 'mvu-native-continue-conflict', chatId: chatId, characterId: card.id),
    );
    final host = ScriptHost();
    final cache = <String, TavernScriptMessage>{};
    final received = <Object?>[];
    final phases = <String>[];
    var writeOnEnded = false;
    Object? offeredCounter;
    Object? savedBeforeWrite;
    TavernVariableSnapshot? externalWrite;
    TavernScriptMessageRef? externalRef;
    host.onDispatch = (request, cancellation) async {
      if (request.kind == TavernScriptDispatchKind.cache) {
        for (final message in request.delta?.upsertMessages ?? <TavernScriptMessage>[]) {
          cache[message.ref.nodeId] = message;
        }
      }
      final name = request.name;
      if (name != null && name.startsWith('mag_')) {
        phases.add(name);
      }
      if (writeOnEnded && name == 'mag_variable_update_ended') {
        writeOnEnded = false;
        final ref = request.nodeRef!;
        offeredCounter = _object(_object(request.args.first)['stat_data'])['counter'];
        final current = await _read(bridge, context.id, chatId, ref.nodeId);
        savedBeforeWrite = _object(current.value['stat_data'])['counter'];
        final replacement = current.value;
        _object(replacement['stat_data'])['counter'] = 77;
        replacement['external_note'] = 'written during the MVU phase';
        externalWrite = await bridge.replaceVariables(
          context.id,
          TavernVariableTarget(scope: TavernVariableScope.message, messageRef: ref),
          replacement,
          expectedVersion: current.version,
        );
        externalRef = ref;
      }
      if (name == 'MESSAGE_RECEIVED') {
        final ref = request.nodeRef!;
        final saved = await _read(bridge, context.id, chatId, ref.nodeId);
        expect(
          cache[ref.nodeId]!.data,
          saved.value,
          reason: 'RECEIVED must observe the actual saved value after an MVU conflict.',
        );
        received.add(_object(saved.value['stat_data'])['counter']);
      }
      return TavernScriptDispatchAck(eventId: request.eventId);
    };
    bridge.attachHost(host);

    final enabled = await bridge.setMvuEnabled(context.id, true);
    expect(enabled.issues, isEmpty);
    _expectMvu((await _read(bridge, context.id, chatId, greeting.nodeId)).value, 10, card.id);
    const firstBody =
        '先登记一项。\n<UpdateVariable>\n'
        "_.add('counter', 1);\n"
        '</UpdateVariable>';
    final first = await _complete(h, h.engine.send(chatId, '开始登记。'), firstBody);
    expect(first.done.hookIssues, isEmpty);
    _expectMvu((await _read(bridge, context.id, chatId, first.done.message.nodeId)).value, 11, card.id);
    final directParentId = first.done.message.parentId!;
    final directParent = await _read(bridge, context.id, chatId, directParentId);
    _expectMvu(directParent.value, 10, card.id);

    const continuation =
        '\n再登记两项。\n<UpdateVariable>\n'
        "_.add('counter', 2);\n"
        '</UpdateVariable>';
    final continued = await _complete(h, h.engine.continueReply(chatId, first.done.message.nodeId), continuation);
    expect(continued.done.hookIssues, isEmpty);
    expect(continued.done.message.nodeId, first.done.message.nodeId);
    expect(continued.done.message.parentId, directParentId);
    expect(continued.done.message.text, startsWith(firstBody));
    expect(continued.done.message.text, endsWith(continuation));
    expect(
      jsonEncode(continued.request),
      contains('当前记录：11'),
      reason: 'Continue prompt macros still read the current target page.',
    );
    final continuedData = await _read(bridge, context.id, chatId, continued.done.message.nodeId);
    _expectMvu(continuedData.value, 13, card.id);
    final unchangedParent = await _read(bridge, context.id, chatId, directParentId);
    expect(unchangedParent.value, directParent.value);
    expect(unchangedParent.version, directParent.version);
    expect(received, [11, 13]);

    // The model body is already committed when the ended phase runs. A real
    // message-variable write must invalidate the pending native candidate.
    writeOnEnded = true;
    const conflictBody =
        '候选再增加四项。\n<UpdateVariable>\n'
        "_.add('counter', 4);\n"
        '</UpdateVariable>';
    final conflicted = await _complete(h, h.engine.send(chatId, '请生成下一份记录。'), conflictBody);
    expect(writeOnEnded, isFalse);
    expect(offeredCounter, 17);
    expect(savedBeforeWrite, 13);
    expect(externalWrite, isNotNull);
    expect(externalRef, TavernScriptMessageRef(chatId: chatId, nodeId: conflicted.done.message.nodeId));
    expect(conflicted.done.message.text, conflictBody);
    expect(conflicted.done.hookIssues, hasLength(1));
    final issue = conflicted.done.hookIssues.single;
    expect(issue.code, 'mvu_update_failed');
    expect(issue.stage, 'mvu');
    expect(issue.committed, isTrue);
    expect(issue.cancelled, isFalse);
    final written = externalWrite!;
    final conflictData = await _read(bridge, context.id, chatId, conflicted.done.message.nodeId);
    expect(conflictData.value, written.value);
    expect(conflictData.version, written.version);
    _expectMvu(conflictData.value, 77, card.id);
    expect(conflictData.value['external_note'], 'written during the MVU phase');
    expect(received, [11, 13, 77]);
    expect((await h.engine.path(chatId)).last.text, conflictBody);
    expect(h.model.generated, 3);

    final phaseCount = phases.length;
    await h.engine.selectNode(chatId, continued.done.message.nodeId);
    final selectedContinue = await _read(bridge, context.id, chatId, continued.done.message.nodeId);
    expect(selectedContinue.value, continuedData.value);
    expect(selectedContinue.version, continuedData.version);
    await h.engine.selectNode(chatId, conflicted.done.message.nodeId);
    final selectedConflict = await _read(bridge, context.id, chatId, conflicted.done.message.nodeId);
    expect(selectedConflict.value, written.value);
    expect(selectedConflict.version, written.version);
    expect(phases, hasLength(phaseCount));
    expect(received, [11, 13, 77]);

    await h.reopen();
    final reopened = h.engine.scripts;
    final reopenedContext = await reopened.openContext(
      TavernScriptContextSpec(
        instanceId: 'mvu-native-continue-conflict-reopened',
        chatId: chatId,
        characterId: card.id,
      ),
    );
    final reopenedContinue = await _read(reopened, reopenedContext.id, chatId, continued.done.message.nodeId);
    expect(reopenedContinue.value, continuedData.value);
    expect(reopenedContinue.version, isNot(continuedData.version));
    final reopenedConflict = await _read(reopened, reopenedContext.id, chatId, conflicted.done.message.nodeId);
    expect(reopenedConflict.value, written.value);
    expect(reopenedConflict.version, isNot(written.version));
    expect((await h.engine.path(chatId)).last.text, conflictBody);
    expect(phases, hasLength(phaseCount));
    expect(h.model.generated, 3);
  });

  test('MVU automatic world initialization rechecks name candidates after host acknowledgement', () async {
    for (final change in ['unrelated', 'duplicate', 'delete']) {
      final h = await T24Harness.open(thinking: false);
      addTearDown(h.dispose);
      final cardJson = _object(jsonDecode(utf8.decode(_mvuCard(enabled: false))));
      final data = _object(cardJson['data'])..remove('character_book');
      data['first_mes'] = 'Ready for automatic initialization.';
      _object(data['extensions'])['world'] = 'MVU world';
      final card = await h.engine.importCard(Uint8List.fromList(utf8.encode(jsonEncode(cardJson))));
      final chatId = await h.engine.createChat(card.id);
      final greeting = (await h.engine.path(chatId)).single;
      final book = <String, Object?>{
        'name': 'MVU world',
        'entries': {
          '1': {
            'uid': 1,
            'comment': '[initvar] automatic world',
            'content': 'counter: 1\nlabel: from-auto',
            'disable': true,
          },
        },
      };
      await h.engine.putLorebook('world-mvu', book);
      final bridge = h.engine.scripts;
      final context = await bridge.openContext(
        TavernScriptContextSpec(instanceId: 'mvu-world-$change', chatId: chatId, characterId: card.id),
      );
      final host = ScriptHost();
      var phases = 0;
      host.onDispatch = (request, cancellation) async {
        if (request.name == 'mag_variable_initialized') {
          phases++;
          expect(phases, 1);
          if (change == 'delete') {
            await h.engine.deleteLorebook('world-mvu');
          } else {
            await h.engine.importLorebook(
              jsonEncode({...book, 'name': change == 'duplicate' ? 'MVU world' : 'Other world'}),
              fileName: 'late-world.json',
            );
          }
        }
        return TavernScriptDispatchAck(eventId: request.eventId);
      };
      bridge.attachHost(host);
      if (change == 'unrelated') {
        final initialized = await bridge.setMvuEnabled(context.id, true);
        expect(initialized.issues, isEmpty);
        expect(initialized.initializedRefs, [TavernScriptMessageRef(chatId: chatId, nodeId: greeting.nodeId)]);
        final saved = (await _read(bridge, context.id, chatId, greeting.nodeId)).value;
        expect(saved['stat_data'], {'counter': 1, 'label': 'from-auto'});
        expect(saved['initialized_lorebooks'], {'standalone:world-mvu': <Object?>[]});
      } else {
        await expectLater(
          bridge.setMvuEnabled(context.id, true),
          throwsA(
            isA<TavernScriptException>()
                .having((error) => error.code, 'code', TavernScriptErrorCode.revisionConflict)
                .having((error) => error.committed, 'candidate not committed', isFalse),
          ),
        );
        expect((await _read(bridge, context.id, chatId, greeting.nodeId)).value, isEmpty);
      }
      expect(phases, 1);
      expect(h.model.generated, 0);
    }
  });

  test('MVU macro history preserves physical tail, filtered roles and old source identity', () async {
    for (final mode in ['modern', 'legacy']) {
      final h = await T24Harness.open(thinking: false);
      addTearDown(h.dispose);
      await h.engine.setSettings({'macroEngine': mode});
      final cardJson = _object(jsonDecode(utf8.decode(_mvuCard(enabled: false))));
      final cardData = _object(cardJson['data']);
      final entry = _object((_object(cardData['character_book'])['entries']! as List<Object?>).single);
      entry['comment'] = '[initvar]历史宏';
      final range = mode == 'legacy' ? '|{{allChatRange}}' : '';
      entry['content'] =
          'counter: 1\nlabel: from-book\n'
          'history: "{{lastMessage}}|{{lastMessageId}}|{{lastUserMessage}}|{{lastCharMessage}}|'
          '{{idle_duration}}|{{lastSwipeId}}|{{currentSwipeId}}$range"\n'
          'pick: "{{pick::a::b}}"';
      final card = await h.engine.importCard(Uint8List.fromList(utf8.encode(jsonEncode(cardJson))));
      final imported = [
        {
          'user_name': 'User',
          'character_name': card.name,
          'create_date': '2026-11-10T11:00:00Z',
          'chat_metadata': {'main_chat': 'Review'},
        },
        _historyRow('U-old', minute: 50, user: true),
        _historyRow('C-old', minute: 51),
        _historyRow('U-last', minute: 58, user: true),
        _historyRow('Stage', minute: 59, narrator: true),
        _historyRow('Hidden', minute: 59, user: true, hidden: true),
      ];
      final chatId = (await h.engine.importChats(card.id, [
        TavernChatFile(
          fileName: 'mvu-history.jsonl',
          bytes: Uint8List.fromList(utf8.encode(imported.map(jsonEncode).join('\n'))),
        ),
      ])).chatIds.single;
      final latest = (await h.engine.path(chatId)).last;
      // Restore a real older portable shape before any script context/cache is
      // opened. Its source header owns the identity and the missing hash.
      final store = ChatStore.open('${h.root.path}/tavern.sqlite3', clock: () => T24Harness.at);
      try {
        final extra = store.rawNodeExtra(chatId, latest.nodeId);
        final own = _object(extra['dshgo']);
        final state = _object(own['tavernState']);
        state.remove('stChatId');
        state.remove('stChatIdHash');
        state['messageVariables'] = {
          'dshgo': {'keep': 7},
          'external_note': 'kept',
        };
        own['opaque'] = ['retained'];
        extra['unknown_mvu'] = {'keep': true};
        store.updateMessage(chatId, latest.nodeId, extra: extra);
      } finally {
        await store.close();
      }
      final bridge = h.engine.scripts;
      final context = await bridge.openContext(
        TavernScriptContextSpec(instanceId: 'mvu-history-$mode', chatId: chatId, characterId: card.id),
      );
      expect((await bridge.setMvuEnabled(context.id, true)).issues, isEmpty);
      final initialized = (await _read(bridge, context.id, chatId, latest.nodeId)).value;
      expect(_object(initialized['stat_data'])['counter'], 1);
      expect(_object(initialized['stat_data'])['label'], 'from-book');
      final wholeRange = mode == 'legacy' ? '|0-4' : '';
      expect(_object(initialized['stat_data'])['history'], 'Hidden|4|U-last|Stage|2 minutes|1|1$wholeRange');
      expect(_object(initialized['stat_data'])['pick'], anyOf('a', 'b'));
      expect(initialized['dshgo'], {'keep': 7});
      expect(initialized['external_note'], 'kept');
      final files = await h.engine.exportChat(chatId);
      final exported = StChatDocument.decode(files.first.fileName, files.first.bytes);
      final extra = _object(exported.messages.last['extra']);
      expect(extra['unknown_mvu'], {'keep': true});
      expect(_object(extra['dshgo'])['opaque'], ['retained']);
      final saved = _object(_object(extra['dshgo'])['tavernState']);
      expect(saved['stChatIdHash'], 3994932676295448, reason: 'The existing Review identity hash is restored.');

      final response =
          '<UpdateVariable>'
          "_.set('history', '{{lastMessageId}}|{{lastUserMessage}}|{{idle_duration}}|"
          "{{lastSwipeId}}|{{currentSwipeId}}$range');"
          '</UpdateVariable>';
      final reply = await _complete(h, h.engine.send(chatId, 'New user'), response);
      expect(reply.done.hookIssues, isEmpty);
      final updated = (await _read(bridge, context.id, chatId, reply.done.message.nodeId)).value;
      final replyRange = mode == 'legacy' ? '|0-6' : '';
      expect(_object(updated['stat_data'])['history'], '6|New user|a few seconds|1|1$replyRange');
      expect(updated['dshgo'], {'keep': 7});
      expect(updated['external_note'], 'kept');
    }
  });
}

Future<({String characterId, String chatId})> _openingSwipes(T24Harness h) async {
  final raw = _object(jsonDecode(utf8.decode(_mvuCard(enabled: false, initComment: '[iNiTvAr] opening defaults'))));
  final entries = _object(_object(raw['data'])['character_book'])['entries']! as List<Object?>;
  _object(entries.first)['constant'] = true;
  entries.add({
    'id': 2,
    'keys': <String>[],
    'enabled': true,
    'constant': true,
    'content': 'OPENINGWORLDVISIBLECONTROL',
    'insertion_order': 1,
    'extensions': <String, Object?>{},
  });
  final card = await h.engine.importCard(Uint8List.fromList(utf8.encode(jsonEncode(raw))));
  const first = "Entry A.\n<UpdateVariable>_.add('counter', 2);</UpdateVariable>";
  const second =
      'Entry B.\n<initvar>counter: 10\nlabel: from-alternate\n</initvar>\n'
      "<UpdateVariable>_.add('counter', 5);</UpdateVariable>";
  final document = StChatDocument(
    fileName: 'mvu-opening.jsonl',
    header: {'user_name': 'User', 'character_name': card.name, 'chat_metadata': <String, Object?>{}},
    messages: [
      {
        'name': card.name,
        'is_user': false,
        'mes': second,
        'swipes': [first, second],
        'swipe_id': 1,
        'variables': [
          {'external_note': 'keep-a'},
          {'external_note': 'keep-b'},
        ],
        'extra': <String, Object?>{},
      },
    ],
  );
  final chatId = (await h.engine.importChats(card.id, [
    TavernChatFile(fileName: document.fileName, bytes: document.encode()),
  ])).chatIds.single;
  return (characterId: card.id, chatId: chatId);
}

Map<String, Object?> _historyRow(
  String text, {
  required int minute,
  bool user = false,
  bool hidden = false,
  bool narrator = false,
}) => {
  'name': user
      ? 'User'
      : narrator
      ? 'Stage'
      : 'MVU计数台',
  'is_user': user,
  'is_system': hidden,
  'send_date': DateTime.utc(2026, 11, 10, 11, minute).toIso8601String(),
  'mes': text,
  'extra': <String, Object?>{if (narrator) 'type': 'narrator'},
};

Future<({TavernTurnDone done, Map<String, Object?> request})> _complete(
  T24Harness h,
  Stream<TavernEvent> stream,
  String response,
) async {
  final call = h.model.prepare();
  final events = T24Events(stream);
  await Future.any<void>([
    call.listening.future,
    events.done.future.then<void>((_) {
      throw TestFailure(
        'The native turn ended before the controlled model was reached: '
        '${events.values.whereType<TavernTurnFailed>().toList()}',
      );
    }),
  ]);
  call.add(ModelText(response));
  await call.finish();
  await events.done.future;
  expect(events.values.whereType<TavernTurnFailed>(), isEmpty);
  return (done: events.values.whereType<TavernTurnDone>().single, request: call.body!);
}

Future<TavernVariableSnapshot> _read(TavernScriptBridge bridge, String contextId, String chatId, String nodeId) =>
    bridge.getVariables(
      contextId,
      TavernVariableTarget(
        scope: TavernVariableScope.message,
        messageRef: TavernScriptMessageRef(chatId: chatId, nodeId: nodeId),
      ),
    );

Map<String, Object?> _object(Object? value) => value! as Map<String, Object?>;

void _expectMvu(Map<String, Object?> data, num counter, String characterId) {
  expect(data['stat_data'], {'counter': counter, 'label': 'from-greeting'});
  expect(data['schema'], {
    'type': 'object',
    'properties': {
      'counter': {'type': 'number', 'required': true},
      'label': {'type': 'string', 'required': true},
    },
    'extensible': false,
    'recursiveExtensible': false,
  });
  expect(data['initialized_lorebooks'], {'embedded:$characterId': <Object?>[]});
}

Uint8List _mvuCard({bool enabled = true, String? initComment}) => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'spec': 'chara_card_v3',
      'spec_version': '3.0',
      'data': {
        'name': 'MVU计数台',
        'description': '当前记录：{{get_message_variable::stat_data.counter}}',
        'personality': '',
        'scenario': '',
        'first_mes':
            '这是第一份记录。\n<initvar>\ncounter: 10\n'
            'label: from-greeting\n</initvar>',
        'mes_example': '',
        'creator_notes': '',
        'system_prompt': '',
        'post_history_instructions': '',
        'alternate_greetings': <String>[],
        'tags': <String>[],
        'creator': '',
        'character_version': '',
        'extensions': {
          'dshgo': {
            'v': 1,
            'mvu': {'enabled': enabled},
          },
        },
        'character_book': {
          'name': 'B',
          'entries': [
            {
              'id': 1,
              'name': '[initvar]计数初值',
              'comment': ?initComment,
              'keys': <String>[],
              'enabled': false,
              'content': 'counter: 1\nlabel: from-book',
              'insertion_order': 0,
              'extensions': <String, Object?>{},
            },
          ],
        },
      },
    }),
  ),
);
