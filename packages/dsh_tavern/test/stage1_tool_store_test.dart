import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:dsh_tavern/src/llm/tool_usage.dart';
import 'package:dsh_tavern/src/store/chat_store.dart';
import 'package:dsh_tavern/src/tool_policy.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  test('schema8 migrates legacy memory rowids and original JSON bytes without decoding them', () async {
    final directory = await Directory.systemTemp.createTemp('stage1-schema-');
    final database = sqlite3.open('${directory.path}/chat.sqlite3');
    database.execute(File('test/fixtures/t24_schema_v4.sql').readAsStringSync());
    database.execute('INSERT INTO chats (id, character_id, title, created_at, updated_at) VALUES (?, ?, ?, ?, ?)', [
      'chat',
      'card',
      '',
      1,
      1,
    ]);
    const raw = ' { "content": "literal", "unknown": [1, null], "invalid": 1e999 } ';
    database.execute('INSERT INTO memories (rowid, id, chat_id, entry_json) VALUES (?, ?, ?, ?)', [
      19,
      'legacy',
      'chat',
      raw,
    ]);
    final store = ChatStore.fromDatabase(database);
    addTearDown(() async {
      await store.close();
      await directory.delete(recursive: true);
    });
    expect(database.select('PRAGMA user_version').single['user_version'], ChatStore.schemaVersion);
    final row = database.select('SELECT rowid, * FROM memories').single;
    expect(row['rowid'], 19);
    expect(row['entry_json'], raw);
    expect(row['origin'], 'legacy');
    expect(row['source_node_id'], isNull);
    expect(row['origin_proposal_id'], isNull);
    expect(database.select('PRAGMA foreign_key_check'), isEmpty);
  });

  test('hooks writes advance the old expectation atomically and a later native body ABA is rejected', () async {
    final h = await _StoreHarness.open();
    final owner = h.begin();
    final old = h.store.requireToolOwnership(owner, phase: StoredToolPhase.hooks);
    var adopted = false;
    void failingPreparation() {
      h.store.updateMessage(h.chat, h.root, text: 'rolled back');
      throw StateError('fixture pre-commit failure');
    }

    expect(
      () => h.store.preparationTransaction<void>(
        owner,
        action: failingPreparation,
        onCommitted: (_) {
          adopted = true;
        },
      ),
      throwsStateError,
    );
    expect(adopted, isFalse);
    expect(h.store.message(h.chat, h.root).text, 'greeting');
    expect(
      h.store.requireToolOwnership(owner, phase: StoredToolPhase.hooks).expectationRevision,
      old.expectationRevision,
    );
    final advanced = h.store.preparationTransaction(
      owner,
      action: () => h.store.updateMessage(h.chat, h.root, text: 'adopted hook'),
      onCommitted: (_) {},
    );
    expect(advanced.ownership.expectationRevision, old.expectationRevision + 1);
    expect(
      advanced.ownership.expectedContextAnchor.selectedLeaf!.contentVersion,
      old.expectedContextAnchor.selectedLeaf!.contentVersion + 1,
    );
    h.seal(owner);
    h.database.execute('UPDATE nodes SET text = text WHERE id = ?', [h.root]);
    expect(
      () => h.store.requireToolOwnership(owner, phase: StoredToolPhase.native),
      throwsA(isA<StoredToolOwnershipException>()),
    );
    final cleanup = h.store.rollbackPreparingToolTurn(
      owner,
      plan: h.plan(),
      outcome: 'cancelled',
      summary: const {},
      audit: (facts) => facts,
      onCommitted: (_) {},
    );
    expect(cleanup.facts.casMatched, isFalse);
    expect(cleanup.facts.auditOnly, isTrue);
    expect(cleanup.snapshot.outcome, 'anchor_changed');
    expect(h.store.message(h.chat, h.root).text, 'adopted hook');
  });

  test('pre-reply cleanup adopts actual deletion facts before a throwing commit observer', () async {
    final h = await _StoreHarness.open();
    final owner = h.begin();
    h.seal(owner);
    final user = h.appendUser(owner);
    StoredToolCleanup<StoredToolCleanupFacts>? adopted;
    h.store.committedObserver = (_, _) {
      expect(adopted, isNotNull);
      expect(adopted!.facts.userDeleted, isTrue);
      expect(adopted!.facts.visibleUser, isNull);
      throw StateError('fixture post-commit observer');
    };
    expect(
      () => h.store.rollbackPreparingToolTurn(
        owner,
        plan: h.plan(user: user.source),
        outcome: 'cancelled',
        summary: const {},
        audit: (facts) => facts,
        onCommitted: (value) {
          adopted = value;
        },
      ),
      throwsStateError,
    );
    h.store.committedObserver = null;
    expect(h.store.path(h.chat).map((message) => message.nodeId), [h.root]);
    expect(adopted!.snapshot.status, 'failed');
    expect(adopted!.snapshot.replyCommitAdopted, isFalse);
    expect(adopted!.snapshot.normalFinalAdopted, isFalse);
    expect(h.database.select('SELECT id FROM nodes WHERE id = ?', [user.message.nodeId]), isEmpty);
    expect(h.database.select('PRAGMA foreign_key_check'), isEmpty);
  });

  test('normal final adopts body, auto memory and flags before observer failure and cannot finish twice', () async {
    final h = await _StoreHarness.open();
    final active = h.owned(mode: 'auto');
    final proposal = h.remember(active, mode: 'auto');
    StoredToolTerminal<TavernMessage>? adopted;
    h.store.committedObserver = (_, _) {
      expect(adopted!.snapshot.normalFinalAdopted, isTrue);
      expect(adopted!.snapshot.proposals.single.workflow, 'accepted');
      throw StateError('fixture post-final observer');
    };
    expect(
      () => h.store.finishToolTurn(
        active.owner,
        kind: StoredToolFinishKind.normal,
        outcome: 'normal',
        summary: const {},
        stateSettlements: const [],
        action: () => h.store.updateMessage(h.chat, active.reply.nodeId, text: 'final body'),
        onCommitted: (value) {
          adopted = value;
        },
      ),
      throwsStateError,
    );
    h.store.committedObserver = null;
    expect(adopted!.value.text, 'final body');
    expect(adopted!.snapshot.replyCommitAdopted, isTrue);
    expect(h.store.message(h.chat, active.reply.nodeId).text, 'final body');
    final saved = h.store.readToolReceipt(proposal.receipt.executionId)!;
    expect(saved.committed, isTrue);
    expect(saved.decisionRecord!.outcome, 'accepted');
    expect(h.database.select('SELECT id FROM memories'), hasLength(1));
    expect(() => h.finish(active), throwsA(isA<StoredToolOwnershipException>()));
    expect(h.database.select('SELECT id FROM memories'), hasLength(1));
    expect(h.database.select('PRAGMA foreign_key_check'), isEmpty);
  });

  test('SQL abort before final commit leaves body and staging unadopted, then cleanup discards once', () async {
    final h = await _StoreHarness.open();
    final active = h.owned(mode: 'auto');
    h.remember(active, mode: 'auto');
    h.database.execute("CREATE TRIGGER fail_auto BEFORE INSERT ON memories BEGIN SELECT RAISE(ABORT, 'fixture'); END");
    var adopted = false;
    expect(
      () => h.store.finishToolTurn(
        active.owner,
        kind: StoredToolFinishKind.normal,
        outcome: 'normal',
        summary: const {},
        stateSettlements: const [],
        action: () => h.store.updateMessage(h.chat, active.reply.nodeId, text: 'not committed'),
        onCommitted: (_) {
          adopted = true;
        },
      ),
      throwsA(isA<SqliteException>()),
    );
    expect(adopted, isFalse);
    expect(h.store.message(h.chat, active.reply.nodeId).text, isEmpty);
    expect(h.store.readToolTurn(active.owner.logicalTurnId)!.proposals.single.workflow, 'staged');
    expect(h.database.select('SELECT id FROM memories'), isEmpty);
    h.database.execute('DROP TRIGGER fail_auto');
    final cleanup = h.store.rollbackOwnedToolTurn(
      active.owner,
      plan: h.plan(user: active.user.source),
      outcome: 'storage_failure',
      summary: const {},
      audit: (facts) => facts,
      onCommitted: (_) {},
    );
    expect(cleanup.facts.userDeleted, isTrue);
    expect(cleanup.facts.replyDeleted, isTrue);
    expect(cleanup.snapshot.proposals.single.workflow, 'inactive_terminal');
    expect(cleanup.snapshot.proposals.single.sourceValidity, 'orphaned');
    expect(h.database.select('SELECT id FROM memories'), isEmpty);
  });

  test('lost owned CAS retains real winner and refuses restoration and user deletion', () async {
    final h = await _StoreHarness.open();
    final active = h.owned();
    h.store.updateMessage(h.chat, active.reply.nodeId, text: 'foreign winner');
    final cleanup = h.store.rollbackOwnedToolTurn(
      active.owner,
      plan: h.plan(user: active.user.source),
      outcome: 'cancelled',
      summary: const {},
      audit: (facts) => facts,
      onCommitted: (_) {},
    );
    expect(cleanup.facts.casMatched, isFalse);
    expect(cleanup.facts.auditOnly, isTrue);
    expect(cleanup.facts.userDeleted, isFalse);
    expect(cleanup.facts.replyDeleted, isFalse);
    expect(cleanup.facts.visibleReply!.text, 'foreign winner');
    expect(cleanup.facts.visibleUser!.nodeId, active.user.message.nodeId);
    expect(cleanup.snapshot.outcome, 'anchor_changed');
    expect(h.store.message(h.chat, active.reply.nodeId).text, 'foreign winner');
  });

  test('same textual node ID after physical deletion has a new incarnation and cleanup only observes it', () async {
    final h = await _StoreHarness.open();
    final active = h.owned();
    final old = h.store.sourceToken(h.chat, active.reply.nodeId);
    h.store.deleteFrom(h.chat, old.nodeId);
    h.store.append(
      h.chat,
      id: old.nodeId,
      parentId: active.user.message.nodeId,
      role: TavernRole.character,
      speaker: 'other',
      text: 'replacement',
    );
    final current = h.store.sourceToken(h.chat, old.nodeId);
    expect(current.seq, greaterThan(old.seq));
    expect(
      h.store
          .sourceEligibility(
            h.chat,
            origin: 'remember',
            sourceValidity: 'bound',
            source: old,
            requestedLeafId: current.nodeId,
          )
          .eligible,
      isFalse,
    );
    final cleanup = h.store.rollbackOwnedToolTurn(
      active.owner,
      plan: h.plan(user: active.user.source),
      outcome: 'cancelled',
      summary: const {},
      audit: (facts) => facts,
      onCommitted: (_) {},
    );
    expect(cleanup.facts.casMatched, isFalse);
    expect(cleanup.facts.visibleReply!.text, 'replacement');
    expect(cleanup.facts.replyDeleted, isFalse);
    expect(h.store.sourceToken(h.chat, old.nodeId).seq, current.seq);
  });

  test('manual prepare second identity check does not call new-action admission or adopt its policy', () async {
    final h = await _StoreHarness.open();
    final anchor = h.store.contextAnchor(h.chat);
    final parameters = {
      'chatId': h.chat,
      'actionId': 'action',
      'dice': 'd6',
      'label': null,
      'target': null,
      'expectedNodeId': null,
    };
    final old = h.store.prepareManualToolReceipt(
      h.chat,
      actionId: 'action',
      capturedParameters: parameters,
      validatedParameters: _rollParameters,
      capturedPolicy: const {'rollAllowed': true},
      expectedContextAnchor: anchor,
      checkAdmission: () {},
      onCommitted: (_) {},
    );
    var admitted = false;
    TavernToolReceipt? adopted;
    h.store.committedObserver = (_, _) {
      throw StateError('read replay observer');
    };
    expect(
      () => h.store.prepareManualToolReceipt(
        h.chat,
        actionId: 'action',
        capturedParameters: parameters,
        validatedParameters: _rollParameters,
        capturedPolicy: const {'rollAllowed': false},
        expectedContextAnchor: TavernToolContextAnchor(chatId: h.chat, selectedLeaf: null, treeRevision: 0),
        checkAdmission: () {
          admitted = true;
        },
        onCommitted: (value) {
          adopted = value;
        },
      ),
      throwsStateError,
    );
    h.store.committedObserver = null;
    expect(admitted, isFalse);
    expect(adopted!.executionId, old.executionId);
    expect(h.store.readToolReceipt(old.executionId)!.status, 'prepared');
    expect(h.database.select('SELECT id FROM tool_receipts'), hasLength(1));
  });

  test('reopen records interrupted facts before body recovery and never completes an unknown roll', () async {
    final h = await _StoreHarness.open();
    final active = h.owned(mode: 'auto');
    final committed = h.roll(active, 0);
    final value = h.store.commitToolReceipt(
      committed.executionId,
      result: {
        ..._rollParameters,
        'values': [4],
        'total': 4,
        'pass': null,
      },
      onCommitted: (_) {},
    );
    final unknown = h.roll(active, 1);
    h.remember(active, mode: 'auto', index: 2);
    h.store.registerToolRequest(
      active.owner,
      offeredTools: const ['roll'],
      wireAuthorization: const {'rollAllowed': true},
      onCommitted: (_) {},
    );
    h.store.beginStreamingWrites();
    h.store.writeOwnedStreamingBody(active.owner, text: 'recover partial', reasoning: null, onCommitted: (_) {});
    h.store.endStreamingWrites();
    await h.reopen();
    final turn = h.store.readToolTurn(active.owner.logicalTurnId)!;
    expect(turn.status, 'interrupted');
    expect(turn.requests.first.status, 'response_complete');
    expect(turn.requests.last.status, 'interrupted');
    expect(turn.proposals.single.workflow, 'inactive_terminal');
    expect(turn.proposals.single.source, isNull);
    expect(turn.normalFinalAdopted, isFalse);
    expect(h.store.message(h.chat, active.reply.nodeId).text, 'recover partial');
    expect(h.store.readToolReceipt(committed.executionId)!.toJson(), value.toJson());
    expect(h.store.readToolReceipt(unknown.executionId)!.status, 'unresolved');
    expect(h.store.readToolReceipt(unknown.executionId)!.committed, isNull);
    expect(h.database.select('SELECT id FROM memories'), isEmpty);
    final once = turn.toJson();
    await h.reopen();
    expect(h.store.readToolTurn(active.owner.logicalTurnId)!.toJson(), once);
  });

  for (final terminal in ['rollback', 'audit', 'partial', 'modelTerminal']) {
    test('SPreset prepared receipt becomes unknown at $terminal and only later facts can upgrade it', () async {
      final h = await _StoreHarness.open();
      final active = h.owned(spresetTools: const ['fixture_tool']);
      final receipt = h.store.prepareSPresetToolReceipt(
        active.owner,
        call: h.call(active, 0, 'fixture_tool', const {}),
        onCommitted: (_) {},
      );
      expect(() => h.finish(active), throwsStateError);
      expect(h.store.readToolReceipt(receipt.executionId)!.status, 'prepared');
      switch (terminal) {
        case 'rollback':
          h.store.rollbackOwnedToolTurn(
            active.owner,
            plan: h.plan(user: active.user.source),
            outcome: 'cancelled',
            summary: const {},
            audit: (facts) => facts,
            onCommitted: (_) {},
          );
        case 'audit':
          h.store.terminateToolTurnAudit(
            active.owner,
            outcome: 'cancelled',
            summary: const {},
            audit: () => null,
            onCommitted: (_) {},
          );
        default:
          h.store.finishToolTurn(
            active.owner,
            kind: terminal == 'partial' ? StoredToolFinishKind.failedPartial : StoredToolFinishKind.modelTerminal,
            outcome: terminal == 'partial' ? 'cancelled' : 'model_terminal',
            summary: const {},
            stateSettlements: const [],
            action: () => h.store.updateMessage(h.chat, active.reply.nodeId, text: 'partial'),
            onCommitted: (_) {},
          );
      }
      final settled = h.store.readToolReceipt(receipt.executionId)!;
      expect(settled.status, 'unresolved');
      expect(settled.committed, isNull);
      expect(settled.error!['code'], 'turn_terminated');
      expect(h.store.hasPendingToolRecords(), isFalse);
      const wire = '{"spresetResult":"Error: outcome unknown"}';
      h.store.sealToolReceiptWireResult(receipt.executionId, wireResultJson: wire, onCommitted: (_) {});
      final sealed = h.store.readToolReceipt(receipt.executionId)!;
      final stillUnknown = h.store.finishSPresetToolReceipt(
        receipt.executionId,
        value: null,
        committed: null,
        error: 'cancelled without an actual result',
        late: true,
        onCommitted: (_) {},
      );
      expect(stillUnknown.toJson(), sealed.toJson());
      final committed = terminal == 'audit' || terminal == 'modelTerminal';
      final observed = h.store.finishSPresetToolReceipt(
        receipt.executionId,
        value: {'actual': 'result'},
        committed: committed,
        late: true,
        onCommitted: (_) {},
      );
      expect(observed.status, committed ? 'committed' : 'completed_no_change');
      expect(observed.committed, committed);
      expect(observed.result, {
        'value': {'actual': 'result'},
      });
      expect(h.store.toolWireResult(receipt.executionId), wire);
      // A second, conflicting completion cannot rewrite a known outcome.
      final duplicate = h.store.finishSPresetToolReceipt(
        receipt.executionId,
        value: 'contradiction',
        committed: !committed,
        late: true,
        onCommitted: (_) {},
      );
      expect(duplicate.toJson(), observed.toJson());
      expect(h.store.toolWireResult(receipt.executionId), wire);
      expect(h.database.select('PRAGMA foreign_key_check'), isEmpty);
      await h.reopen();
      expect(h.store.readToolReceipt(receipt.executionId)!.toJson(), observed.toJson());
    });
  }

  test('an accepted memory identity cannot be reused after deletion by a later decision', () async {
    final h = await _StoreHarness.open();
    final first = h.owned(mode: 'auto');
    final firstProposal = h.remember(first, mode: 'auto');
    final terminal = h.finish(first);
    final oldMemory = terminal.snapshot.proposals.single.memoryId!;
    h.database.execute('DELETE FROM memories WHERE id = ?', [oldMemory]);
    final second = h.owned();
    h.remember(second);
    final ready = h.finish(second).snapshot.proposals.single;
    h.forcedId = oldMemory;
    expect(
      () => h.store.resolveMemoryProposal(
        ready.proposalId,
        decisionId: 'new-decision',
        expectedVersion: ready.version,
        decision: TavernMemoryDecision.accept,
        expectedContextAnchor: ready.contextAnchor,
        onCommitted: (_) {},
      ),
      throwsFormatException,
    );
    expect(h.database.select('SELECT id FROM memories'), isEmpty);
    expect(
      h.database.select('SELECT decision_id FROM memory_decisions WHERE decision_id = ?', ['new-decision']),
      isEmpty,
    );
    expect(h.store.readToolReceipt(firstProposal.receipt.executionId)!.targetMissing, isTrue);
    expect(h.store.readToolTurn(second.owner.logicalTurnId)!.proposals.single.workflow, 'pending_confirmation');
  });

  test('corrupt list fields and cross-chat receipt association are rejected as bad stored data', () async {
    final h = await _StoreHarness.open();
    final active = h.owned();
    final receipt = h.roll(active, 0);
    h.database.execute('UPDATE tool_requests SET offered_tools_json = ? WHERE id = ?', [
      Uint8List.fromList([1, 2]),
      active.request.requestId,
    ]);
    expect(() => h.store.readToolTurn(active.owner.logicalTurnId), throwsFormatException);
    h.database.execute('UPDATE tool_requests SET offered_tools_json = ?, send_attempts_json = ? WHERE id = ?', [
      '["roll"]',
      '[0,0]',
      active.request.requestId,
    ]);
    expect(() => h.store.readToolTurn(active.owner.logicalTurnId), throwsFormatException);
    h.database.execute('UPDATE tool_requests SET send_attempts_json = ? WHERE id = ?', [
      '[]',
      active.request.requestId,
    ]);
    final other = h.store.createChat(characterId: 'card');
    h.database.execute('UPDATE tool_receipts SET chat_id = ? WHERE id = ?', [other, receipt.executionId]);
    expect(() => h.store.readToolTurn(active.owner.logicalTurnId), throwsFormatException);
    expect(() => h.store.readToolReceipt(receipt.executionId), throwsFormatException);
  });
}

const _rollParameters = <String, Object?>{
  'dice': 'd6',
  'count': 1,
  'sides': 6,
  'modifier': 0,
  'label': null,
  'target': null,
};

class _StoreHarness {
  _StoreHarness(this.directory) {
    _open();
    chat = store.createChat(characterId: 'card');
    root = store
        .append(
          chat,
          parentId: null,
          role: TavernRole.character,
          speaker: 'Guide',
          speakerCharacterId: 'card',
          text: 'greeting',
          state: const {},
        )
        .nodeId;
  }
  static Future<_StoreHarness> open() async {
    final h = _StoreHarness(await Directory.systemTemp.createTemp('stage1-store-'));
    addTearDown(() async {
      await h.store.close();
      await h.directory.delete(recursive: true);
    });
    return h;
  }

  final Directory directory;
  late Database database;
  late ChatStore store;
  late final String chat, root;
  var serial = 0;
  String? forcedId;
  String nextId() {
    final forced = forcedId;
    forcedId = null;
    return forced ?? 'id-${++serial}';
  }

  void _open() {
    database = sqlite3.open('${directory.path}/chat.sqlite3');
    store = ChatStore.fromDatabase(database, clock: () => DateTime.utc(2026, 11, 13), createId: nextId);
  }

  Future<void> reopen() async {
    await store.close();
    _open();
  }

  StoredToolTurnOwner begin({
    String mode = 'ask',
    StoredToolOperation operation = StoredToolOperation.send,
    String? target,
  }) {
    final scope = toolPolicySnapshot(
      globalSettings: {
        'toolPolicy': {
          'roll': {'allow': true},
          'remember': {'allow': true, 'mode': mode},
        },
      },
    );
    final card = captureToolCardPolicy(const {}, characterId: 'card');
    final policy = captureToolPolicy(scope: scope, host: card, actor: card);
    return store
        .beginToolTurn(
          owner: Object(),
          logicalTurnId: 'logical-${++serial}',
          chatId: chat,
          operation: operation,
          actorCharacterId: 'card',
          hostCharacterId: 'card',
          groupRoundId: null,
          operationTargetNodeId: target,
          policyScope: scope,
          capturedPolicy: policy.toJson(),
          onCommitted: (_) {},
        )
        .value;
  }

  void seal(StoredToolTurnOwner owner) {
    store.sealToolPreparation(owner, capture: (chat, target) => chat, onCommitted: (_) {});
  }

  ({TavernMessage message, TavernToolSourceToken source}) appendUser(StoredToolTurnOwner owner) => store
      .commitToolUserAppend(
        owner,
        parentId: store.chat(chat).currentLeafId,
        speaker: 'User',
        text: 'question',
        state: const {},
        variables: const {},
        prepare: (message, source) => (message: message, source: source),
        onCommitted: (_) {},
      )
      .value;
  _Owned owned({String mode = 'ask', List<String> spresetTools = const []}) {
    final owner = begin(mode: mode);
    seal(owner);
    final user = appendUser(owner);
    final reply = store
        .bindToolCandidate(
          owner,
          parentId: user.message.nodeId,
          speaker: 'Guide',
          state: const {},
          variables: const {},
          extra: const {},
          prepare: (message, source) => message,
          onCommitted: (_) {},
        )
        .value;
    final registered = store.registerToolRequest(
      owner,
      offeredTools: ['roll', 'remember', ...spresetTools],
      wireAuthorization: {'rollAllowed': true, 'rememberAllowed': true, 'spresetTools': spresetTools},
      onCommitted: (_) {},
    );
    final request = store.finishToolRequest(
      registered.requestId,
      status: 'response_complete',
      responseComplete: true,
      providerFinishReason: 'stop',
      responseSnapshot: null,
      usage: emptyToolUsageLedger(),
      batchDiagnostics: const {},
      error: null,
      onCommitted: (_) {},
    );
    return _Owned(owner, user, reply, request);
  }

  StoredToolRollbackPlan plan({TavernToolSourceToken? user}) => StoredToolRollbackPlan(
    appendedUserSource: user,
    continuationRestore: null,
    firstMessageRestore: null,
    previousSelections: const [],
    selectedLeafId: root,
    variables: const {},
  );
  StoredModelToolCall call(
    _Owned active,
    int index,
    String name,
    Map<String, Object?> parameters, {
    Map<String, Object?>? validated,
  }) => StoredModelToolCall(
    requestId: active.request.requestId,
    toolIndex: index,
    callId: 'call-$index',
    toolName: name,
    rawArguments: jsonEncode(parameters),
    capturedParameters: parameters,
    validatedParameters: validated,
  );
  TavernToolReceipt roll(_Owned active, int index) => store.prepareToolReceipt(
    active.owner,
    call: call(active, index, 'roll', const {'dice': 'd6'}, validated: _rollParameters),
    status: 'prepared',
    onCommitted: (_) {},
  );
  StoredToolMemoryStage remember(_Owned active, {String mode = 'ask', int index = 0}) => store.stageMemoryProposal(
    active.owner,
    call: call(active, index, 'remember', const {
      'text': 'fact',
      'keywords': ['signal'],
    }),
    mode: mode,
    text: 'fact',
    keywords: const ['signal'],
    onCommitted: (_) {},
  );
  StoredToolTerminal<TavernMessage> finish(_Owned active) {
    return store.finishToolTurn(
      active.owner,
      kind: StoredToolFinishKind.normal,
      outcome: 'normal',
      summary: const {},
      stateSettlements: const [],
      action: () => store.updateMessage(chat, active.reply.nodeId, text: 'final'),
      onCommitted: (_) {},
    );
  }
}

class _Owned {
  const _Owned(this.owner, this.user, this.reply, this.request);
  final StoredToolTurnOwner owner;
  final ({TavernMessage message, TavernToolSourceToken source}) user;
  final TavernMessage reply;
  final TavernToolRequestSnapshot request;
}
