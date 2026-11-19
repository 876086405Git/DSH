part of 'chat_store.dart';

enum StoredToolOperation { send, regenerate, continueReply }

enum StoredToolPhase { hooks, native, owned, terminal }

enum StoredToolFinishKind { normal, modelTerminal, failedPartial }

final class StoredToolTurnOwner {
  StoredToolTurnOwner._(this._store, this._owner, this.logicalTurnId, this.chatId, this.operation);
  final ChatStore _store;
  final Object _owner;
  final String logicalTurnId;
  final String chatId;
  final StoredToolOperation operation;
  bool belongsTo(Object owner) => identical(_owner, owner);
}

final class StoredToolOwnership {
  const StoredToolOwnership({
    required this.logicalTurnId,
    required this.chatId,
    required this.phase,
    required this.expectationRevision,
    required this.expectedContextAnchor,
    required this.expectedOperationTarget,
    required this.candidateSource,
  });
  final String logicalTurnId;
  final String chatId;
  final StoredToolPhase phase;
  final int expectationRevision;
  final TavernToolContextAnchor expectedContextAnchor;
  final TavernToolSourceToken? expectedOperationTarget;
  final TavernToolSourceToken? candidateSource;
}

final class StoredToolCommit<T> {
  const StoredToolCommit(this.value, this.ownership);
  final T value;
  final StoredToolOwnership ownership;
}

final class StoredToolPreparation<T> {
  const StoredToolPreparation({
    required this.value,
    required this.chat,
    required this.operationTarget,
    required this.ownership,
  });
  final T value;
  final StoredChat chat;
  final StoredNode? operationTarget;
  final StoredToolOwnership ownership;
}

final class StoredToolSourceEligibility {
  const StoredToolSourceEligibility(this.eligible, this.reason, this.sourceValidity);
  final bool eligible;
  final String? reason;
  final String sourceValidity;
}

final class StoredToolTerminal<T> {
  StoredToolTerminal({
    required this.value,
    required this.ownership,
    required this.snapshot,
    required List<String> affectedReceiptIds,
    required List<String> affectedProposalIds,
  }) : affectedReceiptIds = List.unmodifiable(affectedReceiptIds),
       affectedProposalIds = List.unmodifiable(affectedProposalIds);
  final T value;
  final StoredToolOwnership ownership;
  final TavernToolTurnSnapshot snapshot;
  final List<String> affectedReceiptIds;
  final List<String> affectedProposalIds;
}

final class StoredToolOwnershipException implements Exception {
  const StoredToolOwnershipException(this.logicalTurnId, this.reason);
  final String logicalTurnId;
  final String reason;
  @override
  String toString() => 'Tool turn $logicalTurnId: $reason';
}

final class StoredToolBudgetException implements Exception {
  const StoredToolBudgetException(this.logicalTurnId);
  final String logicalTurnId;
}

final class StoredToolBodyRewrite {
  const StoredToolBodyRewrite({required this.source, required this.text});
  final TavernToolSourceToken source;
  final String text;
}

final class StoredModelToolCall {
  StoredModelToolCall({
    required this.requestId,
    required this.toolIndex,
    required this.callId,
    required this.toolName,
    required this.rawArguments,
    required Map<String, Object?> capturedParameters,
    required Map<String, Object?>? validatedParameters,
  }) : capturedParameters = _toolCopy(capturedParameters),
       validatedParameters = validatedParameters == null ? null : _toolCopy(validatedParameters);
  final String requestId;
  final int toolIndex;
  final String callId;
  final String toolName;
  final String rawArguments;
  final Map<String, Object?> capturedParameters;
  final Map<String, Object?>? validatedParameters;
}

final class StoredToolMemoryStage {
  const StoredToolMemoryStage(this.receipt, this.proposal);
  final TavernToolReceipt receipt;
  final TavernMemoryProposalSnapshot proposal;
}

final class StoredToolStateSettlement {
  StoredToolStateSettlement({
    required this.executionId,
    required this.status,
    Map<String, Object?>? result,
    Map<String, Object?>? error,
  }) : result = result == null ? null : _toolCopy(result),
       error = error == null ? null : _toolCopy(error);
  final String executionId;
  final String status;
  final Map<String, Object?>? result;
  final Map<String, Object?>? error;
}

final class StoredToolRollbackPlan {
  StoredToolRollbackPlan({
    required this.appendedUserSource,
    required StoredNode? continuationRestore,
    required this.firstMessageRestore,
    required List<(String, String?)> previousSelections,
    required this.selectedLeafId,
    required Map<String, Object?> variables,
  }) : continuationRestore = continuationRestore == null
           ? null
           : StoredNode(
               message: continuationRestore.message,
               depth: continuationRestore.depth,
               extra: _toolCopy(continuationRestore.extra),
               original: _toolCopy(continuationRestore.original),
               selectedChildId: continuationRestore.selectedChildId,
             ),
       previousSelections = List.unmodifiable(previousSelections),
       variables = _toolCopy(variables);
  final TavernToolSourceToken? appendedUserSource;
  final StoredNode? continuationRestore;
  final StoredToolBodyRewrite? firstMessageRestore;
  final List<(String, String?)> previousSelections;
  final String? selectedLeafId;
  final Map<String, Object?> variables;
}

final class StoredToolCleanupFacts {
  const StoredToolCleanupFacts({
    required this.casMatched,
    required this.userDeleted,
    required this.replyDeleted,
    required this.continueRestored,
    required this.auditOnly,
    required this.mismatchReason,
    required this.visibleUser,
    required this.visibleReply,
    required this.currentContextAnchor,
  });
  final bool casMatched;
  final bool userDeleted;
  final bool replyDeleted;
  final bool continueRestored;
  final bool auditOnly;
  final String? mismatchReason;

  /// Current visible rows at the original ids, including a different winner.
  /// These observations never establish ownership or this turn's adoption.
  final TavernMessage? visibleUser;
  final TavernMessage? visibleReply;
  final TavernToolContextAnchor currentContextAnchor;
}

final class StoredToolCleanup<T> {
  const StoredToolCleanup({required this.value, required this.facts, required this.snapshot, required this.ownership});
  final T value;
  final StoredToolCleanupFacts facts;
  final TavernToolTurnSnapshot snapshot;
  final StoredToolOwnership ownership;
}

final class StoredRememberMemory {
  StoredRememberMemory({
    required this.id,
    required this.rowId,
    required Map<String, Object?> entry,
    required this.available,
    required this.unavailableReason,
    required this.source,
  }) : entry = _toolCopy(entry);
  final String id;
  final int rowId;
  final Map<String, Object?> entry;
  final bool available;
  final String? unavailableReason;
  final TavernToolSourceToken? source;
}

Map<String, Object?> _toolCopy(Map<String, Object?> value) {
  try {
    return _toolFreeze(jsonDecode(jsonEncode(value))) as Map<String, Object?>;
  } on JsonUnsupportedObjectError {
    throw const FormatException('Tool values must be finite JSON.');
  }
}

Object? _toolFreeze(Object? value) {
  if (value is Map<String, Object?>) {
    return Map<String, Object?>.unmodifiable(value.map((key, item) => MapEntry(key, _toolFreeze(item))));
  }
  if (value is List) return List<Object?>.unmodifiable(value.map(_toolFreeze));
  return value;
}

bool _toolEqual(Object? a, Object? b) {
  if (a is Map && b is Map) {
    return a.length == b.length && a.keys.every((key) => b.containsKey(key) && _toolEqual(a[key], b[key]));
  }
  if (a is List && b is List) {
    return a.length == b.length && Iterable<int>.generate(a.length).every((index) => _toolEqual(a[index], b[index]));
  }
  if (a is num && b is num && a.runtimeType != b.runtimeType) return false;
  return a == b;
}

bool _toolSameSource(TavernToolSourceToken? a, TavernToolSourceToken? b, {bool body = true}) => a == null
    ? b == null
    : b != null &&
          a.nodeId == b.nodeId &&
          a.seq == b.seq &&
          a.sourceEpoch == b.sourceEpoch &&
          (!body || a.contentVersion == b.contentVersion);

void _toolIdentity(String value, String name) {
  if (value.isEmpty) throw ArgumentError.value(value, name, 'Must not be empty.');
}

void _toolSyncAction(Function action) {
  if (action is Future<dynamic> Function()) throw ArgumentError('Tool callbacks must be synchronous.');
}

T _toolSyncValue<T>(T value) {
  if (value is Future<dynamic>) {
    value.ignore();
    throw ArgumentError('Tool callbacks must be synchronous.');
  }
  return value;
}

const _toolGuardColumns = <String, List<String>>{
  'tool_turns': [
    'id',
    'chat_id',
    'actor_character_id',
    'host_character_id',
    'group_round_id',
    'operation_target_node_id',
    'operation_target_live_node_id',
    'expected_selected_leaf_id',
    'candidate_node_id',
    'candidate_live_node_id',
    'outcome',
  ],
  'tool_requests': ['id', 'chat_id', 'logical_turn_id', 'provider_finish_reason'],
  'tool_receipts': [
    'id',
    'chat_id',
    'request_id',
    'raw_call_id',
    'action_id',
    'tool_name',
    'raw_arguments',
    'proposal_id',
    'decision_id',
  ],
  'memory_proposals': [
    'id',
    'chat_id',
    'logical_turn_id',
    'receipt_id',
    'text',
    'candidate_node_id',
    'source_node_id',
    'source_live_node_id',
    'accepted_memory_id',
    'memory_live_id',
    'last_decision_id',
  ],
  'memory_decisions': ['decision_id', 'chat_id', 'proposal_id', 'memory_id'],
  'memories': [
    'id',
    'chat_id',
    'origin_proposal_id',
    'origin_logical_turn_id',
    'origin_receipt_id',
    'source_node_id',
    'source_live_node_id',
  ],
};

extension ToolStore on ChatStore {
  bool toolChatExists(String chatId) {
    _ensureOpen();
    return _db.select('SELECT 1 FROM chats WHERE id = ?', [chatId]).isNotEmpty;
  }

  void _toolActivateProposals(StoredToolTurnOwner owner, TavernToolSourceToken source) {
    final qualification = sourceEligibility(
      owner.chatId,
      origin: 'remember',
      sourceValidity: 'bound',
      source: source,
      requestedLeafId: source.nodeId,
    );
    if (!qualification.eligible) throw StoredToolOwnershipException(owner.logicalTurnId, 'candidate_changed');
    final rows = _toolRows('memory_proposals', "t.logical_turn_id = ? AND t.status = 'staged'", [
      owner.logicalTurnId,
    ], suffix: 'ORDER BY t.rowid');
    for (final before in rows) {
      if (_toolText(before, 'chat_id') != owner.chatId ||
          _toolText(before, 'candidate_node_id') != source.nodeId ||
          before['candidate_seq'] != source.seq ||
          before['candidate_source_epoch'] != source.sourceEpoch ||
          before['source_validity'] != 'candidate') {
        throw StoredToolOwnershipException(owner.logicalTurnId, 'candidate_changed');
      }
      final proposalId = _toolText(before, 'id')!;
      final receiptId = _toolText(before, 'receipt_id')!;
      final auto = before['mode'] == 'auto';
      final memoryId = auto ? _toolCreateRememberMemory(before, source) : null;
      final decisionId = auto ? '$proposalId:auto' : null;
      final now = _toolNow();
      final fields = <String, Object?>{
        ..._toolSourceFields(source),
        'source_validity': 'bound',
        'status': auto ? 'accepted' : 'pending_confirmation',
        'accepted_memory_id': memoryId,
        'memory_live_id': memoryId,
        'last_decision_origin': auto ? 'policy_auto' : null,
        'last_decision_id': decisionId,
        'updated_at_ms': now,
      };
      _db.execute(
        '''UPDATE memory_proposals SET ${fields.keys.map((key) => '$key = ?').join(', ')},
        proposal_version = proposal_version + 1 WHERE id = ? AND status = 'staged' AND proposal_version = ?''',
        [...fields.values, proposalId, before['proposal_version']],
      );
      if (_db.select('SELECT changes() AS n').single['n'] != 1) throw StateError('Proposal activation CAS failed.');
      Map<String, Object?>? decision;
      if (auto) {
        decision = _toolInsertDecision(
          before: before,
          after: _toolRequired('memory_proposals', proposalId),
          origin: 'policy_auto',
          decisionId: decisionId!,
          decision: TavernMemoryDecision.accept,
          outcome: 'accepted',
          reason: null,
          expectedVersion: null,
          expectedContextAnchor: null,
          parameters: {
            'internalActivation': {
              'mode': 'auto',
              'policyLogicalTurnId': owner.logicalTurnId,
              'proposalVersion': before['proposal_version'],
              'source': source.toJson(),
            },
          },
          memoryId: memoryId,
        );
      }
      _toolUpdate(
        'tool_receipts',
        {
          'status': auto ? 'committed' : 'pending_confirmation',
          'committed': auto ? 1 : 0,
          'result_json': _toolResult({
            'proposalId': proposalId,
            'mode': before['mode'],
            'status': auto ? 'accepted' : 'pending_confirmation',
            'memoryId': memoryId,
            if (decision != null) 'decisionRef': decision['decisionRef'],
          }, null),
          'decision_origin': auto ? 'policy_auto' : null,
          'decision_id': decisionId,
          'updated_at_ms': now,
          'result_adopted_at_ms': auto ? now : null,
        },
        'id = ?',
        [receiptId],
      );
    }
  }

  List<Row> _toolTurnReceipts(String logicalTurnId) => _toolRows(
    'tool_receipts',
    't.request_id IN (SELECT id FROM tool_requests WHERE logical_turn_id = ?)',
    [logicalTurnId],
    suffix: 'ORDER BY t.rowid',
  );

  void _toolDiscardStaging(String logicalTurnId, String reason) {
    final now = _toolNow();
    _db.execute(
      '''UPDATE memory_proposals SET status = 'inactive_terminal', terminal_reason = ?,
      proposal_version = proposal_version + 1, updated_at_ms = ? WHERE logical_turn_id = ? AND status = 'staged' ''',
      [reason, now, logicalTurnId],
    );
    for (final receipt in _toolTurnReceipts(logicalTurnId)) {
      if (receipt['status'] == 'staged') {
        final prior = _toolResultParts(receipt)['result'] as Map<String, Object?>?;
        _toolUpdate(
          'tool_receipts',
          {
            'status': 'discarded',
            'committed': 0,
            'updated_at_ms': now,
            'result_json': _toolResult({...?prior, 'status': 'discarded', 'reason': reason}, null),
          },
          'id = ?',
          [_toolText(receipt, 'id')],
        );
      } else if (receipt['status'] == 'prepared' && _toolText(receipt, 'tool_name') == 'roll') {
        _toolUpdate(
          'tool_receipts',
          {
            'status': 'unresolved',
            'committed': null,
            'updated_at_ms': now,
            'result_json': _toolResult(null, {'code': 'turn_terminated', 'reason': reason}),
          },
          'id = ?',
          [_toolText(receipt, 'id')],
        );
      }
    }
  }

  void _toolInterruptRequests(String logicalTurnId, String reason) {
    _db.execute(
      '''UPDATE tool_requests SET status = 'interrupted', response_finished_at_ms = ?, error_json = ?
      WHERE logical_turn_id = ? AND status IN ('registered', 'in_flight')''',
      [
        _toolNow(),
        jsonEncode({'code': reason}),
        logicalTurnId,
      ],
    );
  }

  void _toolTerminal(
    StoredToolTurnOwner owner, {
    required String status,
    required String outcome,
    required Map<String, Object?> summary,
    required bool reply,
    required bool normal,
  }) {
    _db.execute(
      '''UPDATE tool_turns SET status = ?, outcome = ?, summary_json = ?, finished_at_ms = ?,
      ownership_phase = 'terminal', reply_commit_adopted = MAX(reply_commit_adopted, ?),
      normal_final_adopted = MAX(normal_final_adopted, ?) WHERE id = ? AND status = 'active' ''',
      [status, outcome, jsonEncode(summary), _toolNow(), reply ? 1 : 0, normal ? 1 : 0, owner.logicalTurnId],
    );
    if (_db.select('SELECT changes() AS n').single['n'] != 1) {
      throw StoredToolOwnershipException(owner.logicalTurnId, 'inactive');
    }
    _changedChats.add(owner.chatId);
  }

  StoredToolTerminal<T> _toolTerminalView<T>(StoredToolTurnOwner owner, T value) => StoredToolTerminal(
    value: value,
    ownership: _toolOwnership(_toolRequired('tool_turns', owner.logicalTurnId)),
    snapshot: readToolTurn(owner.logicalTurnId)!,
    affectedReceiptIds: [for (final receipt in _toolTurnReceipts(owner.logicalTurnId)) _toolText(receipt, 'id')!],
    affectedProposalIds: [
      for (final proposal in _toolRows('memory_proposals', 't.logical_turn_id = ?', [owner.logicalTurnId]))
        _toolText(proposal, 'id')!,
    ],
  );

  StoredToolTerminal<T> finishToolTurn<T>(
    StoredToolTurnOwner owner, {
    required StoredToolFinishKind kind,
    required String outcome,
    required Map<String, Object?> summary,
    required List<StoredToolStateSettlement> stateSettlements,
    required T Function() action,
    required void Function(StoredToolTerminal<T>) onCommitted,
    void Function(String)? onTiming,
  }) {
    _toolSyncAction(action);
    final savedSummary = _toolCopy(summary);
    final settlements = List<StoredToolStateSettlement>.unmodifiable(stateSettlements);
    if (kind == StoredToolFinishKind.normal && outcome != 'normal' ||
        kind == StoredToolFinishKind.modelTerminal && outcome != 'model_terminal') {
      throw ArgumentError('Final kind and outcome disagree.');
    }
    onTiming?.call('preamble');
    return _toolOuter(
      () {
        final before = _toolCheck(owner, StoredToolPhase.owned);
        onTiming?.call('ownership');
        final value = _toolSyncValue(action());
        onTiming?.call('action');
        final ownership = _toolAdvance(owner, before);
        onTiming?.call('advance');
        final normal = kind == StoredToolFinishKind.normal;
        if (normal) {
          _toolActivateProposals(owner, ownership.candidateSource!);
          onTiming?.call('proposals');
          final staged = <String, Row>{
            for (final receipt in _toolTurnReceipts(owner.logicalTurnId))
              if (receipt['status'] == 'staged' && _toolText(receipt, 'tool_name') == 'update_state')
                _toolText(receipt, 'id')!: receipt,
          };
          final seen = <String>{};
          for (final settlement in settlements) {
            if (!seen.add(settlement.executionId) ||
                !staged.containsKey(settlement.executionId) ||
                !const ['committed', 'completed_no_change', 'rejected', 'discarded'].contains(settlement.status)) {
              throw StateError('Invalid state receipt settlement.');
            }
            final now = _toolNow();
            _toolUpdate(
              'tool_receipts',
              {
                'status': settlement.status,
                'committed': _toolCommitted(settlement.status),
                'result_json': _toolResult(settlement.result, settlement.error),
                'updated_at_ms': now,
                'result_adopted_at_ms': settlement.status == 'committed' ? now : null,
              },
              'id = ?',
              [settlement.executionId],
            );
          }
          if (seen.length != staged.length) throw StateError('Every staged state receipt requires a final outcome.');
          if (_toolTurnReceipts(owner.logicalTurnId).any((receipt) => receipt['status'] == 'prepared')) {
            throw StateError('Normal completion cannot abandon an executing tool intent.');
          }
        } else {
          if (settlements.any((settlement) => settlement.status == 'committed')) {
            throw StateError('A failed model turn cannot adopt model state.');
          }
          _toolDiscardStaging(owner.logicalTurnId, outcome);
        }
        onTiming?.call('receipts');
        _toolInterruptRequests(owner.logicalTurnId, outcome);
        onTiming?.call('interrupt_requests');
        _toolTerminal(
          owner,
          status: kind == StoredToolFinishKind.failedPartial ? 'failed' : 'completed',
          outcome: outcome,
          summary: savedSummary,
          reply: true,
          normal: normal,
        );
        onTiming?.call('terminal');
        final result = _toolTerminalView(owner, value);
        onTiming?.call('snapshot');
        return result;
      },
      onCommitted,
      onTiming: onTiming,
    );
  }

  TavernMessage? _toolVisibleCurrent(String chatId, TavernToolSourceToken? original) {
    if (original == null) return null;
    final actual = _toolMaybeSource(chatId, original.nodeId);
    return actual == null ? null : message(chatId, original.nodeId);
  }

  StoredToolCleanup<T> _toolRollback<T>(
    StoredToolTurnOwner owner,
    StoredToolPhase phase, {
    required StoredToolRollbackPlan plan,
    required String outcome,
    required Map<String, Object?> summary,
    required T Function(StoredToolCleanupFacts facts) audit,
    required void Function(StoredToolCleanup<T>) onCommitted,
  }) {
    if (audit is Future<dynamic> Function(StoredToolCleanupFacts)) {
      throw ArgumentError('Cleanup audit must be synchronous.');
    }
    final savedSummary = _toolCopy(summary);
    return _toolOuter(() {
      final before = _toolOwnerRow(owner, phase: phase);
      final old = _toolOwnership(before);
      final candidate = old.candidateSource;
      final user = plan.appendedUserSource;
      final first = plan.firstMessageRestore;
      final independentFirst =
          first != null && first.source.nodeId != candidate?.nodeId && first.source.nodeId != user?.nodeId
          ? first
          : null;
      if (phase == StoredToolPhase.native && (plan.continuationRestore != null || first != null)) {
        throw ArgumentError('Pre-reply cleanup has no adopted reply or first-message rewrite.');
      }
      if (phase == StoredToolPhase.owned &&
          owner.operation == StoredToolOperation.continueReply &&
          (plan.continuationRestore == null || plan.continuationRestore!.message.nodeId != candidate?.nodeId)) {
        throw ArgumentError('Continuation cleanup requires its preserved original target.');
      }
      String? mismatch;
      try {
        _toolCheck(owner, phase);
        if (user != null && !_toolSameSource(user, _toolMaybeSource(owner.chatId, user.nodeId))) {
          throw StoredToolOwnershipException(owner.logicalTurnId, 'target_changed');
        }
        if (independentFirst != null &&
            !_toolSameSource(independentFirst.source, _toolMaybeSource(owner.chatId, independentFirst.source.nodeId))) {
          throw StoredToolOwnershipException(owner.logicalTurnId, 'target_changed');
        }
      } on StoredToolOwnershipException catch (error) {
        mismatch = error.reason;
      }
      var restored = false;
      if (mismatch == null && (candidate != null || user != null)) {
        if (candidate != null) {
          if (owner.operation == StoredToolOperation.continueReply) {
            final original = plan.continuationRestore!;
            final message = original.message;
            updateMessage(
              owner.chatId,
              candidate.nodeId,
              text: message.text,
              reasoning: message.reasoning,
              clearReasoning: message.reasoning == null,
              speakerCharacterId: message.speakerCharacterId,
              clearSpeakerCharacterId: message.speakerCharacterId == null,
              usage: message.usage,
              clearUsage: message.usage == null,
              extra: original.extra,
            );
            restored = true;
          } else {
            deleteFrom(owner.chatId, candidate.nodeId);
          }
        }
        if (user != null) deleteFrom(owner.chatId, user.nodeId);
        if (independentFirst != null) {
          updateMessage(owner.chatId, independentFirst.source.nodeId, text: independentFirst.text);
        }
        for (final selection in plan.previousSelections.reversed) {
          selectNode(owner.chatId, selection.$2 ?? selection.$1, restoreDescendants: selection.$2 != null);
        }
        if (plan.selectedLeafId == null) {
          clearSelection(owner.chatId);
        } else {
          selectNode(owner.chatId, plan.selectedLeafId!, restoreDescendants: false);
        }
        updateChat(owner.chatId, variables: plan.variables);
        if (restored) _toolAdvance(owner, before, allowSelectionChange: true);
      }
      final visibleUser = _toolVisibleCurrent(owner.chatId, user);
      final visibleReply = _toolVisibleCurrent(
        owner.chatId,
        candidate ?? (owner.operation == StoredToolOperation.continueReply ? old.expectedOperationTarget : null),
      );
      final facts = StoredToolCleanupFacts(
        casMatched: mismatch == null,
        userDeleted: mismatch == null && user != null && visibleUser == null,
        replyDeleted: mismatch == null && candidate != null && visibleReply == null,
        continueRestored: restored,
        auditOnly: mismatch != null || candidate == null && user == null,
        mismatchReason: mismatch,
        visibleUser: visibleUser,
        visibleReply: visibleReply,
        currentContextAnchor: contextAnchor(owner.chatId),
      );
      final value = _toolSyncValue(audit(facts));
      _toolDiscardStaging(owner.logicalTurnId, mismatch == null ? outcome : 'anchor_changed');
      _toolInterruptRequests(owner.logicalTurnId, mismatch == null ? outcome : 'anchor_changed');
      _toolTerminal(
        owner,
        status: 'failed',
        outcome: mismatch == null ? outcome : 'anchor_changed',
        summary: mismatch == null ? savedSummary : {...savedSummary, 'toolFailureCode': 'anchor_changed'},
        reply: restored,
        normal: false,
      );
      return StoredToolCleanup(
        value: value,
        facts: facts,
        snapshot: readToolTurn(owner.logicalTurnId)!,
        ownership: _toolOwnership(_toolRequired('tool_turns', owner.logicalTurnId)),
      );
    }, onCommitted);
  }

  StoredToolCleanup<T> rollbackPreparingToolTurn<T>(
    StoredToolTurnOwner owner, {
    required StoredToolRollbackPlan plan,
    required String outcome,
    required Map<String, Object?> summary,
    required T Function(StoredToolCleanupFacts facts) audit,
    required void Function(StoredToolCleanup<T>) onCommitted,
  }) => _toolRollback(
    owner,
    StoredToolPhase.native,
    plan: plan,
    outcome: outcome,
    summary: summary,
    audit: audit,
    onCommitted: onCommitted,
  );

  StoredToolCleanup<T> rollbackOwnedToolTurn<T>(
    StoredToolTurnOwner owner, {
    required StoredToolRollbackPlan plan,
    required String outcome,
    required Map<String, Object?> summary,
    required T Function(StoredToolCleanupFacts facts) audit,
    required void Function(StoredToolCleanup<T>) onCommitted,
  }) => _toolRollback(
    owner,
    StoredToolPhase.owned,
    plan: plan,
    outcome: outcome,
    summary: summary,
    audit: audit,
    onCommitted: onCommitted,
  );

  StoredToolTerminal<T> terminateToolTurnAudit<T>(
    StoredToolTurnOwner owner, {
    required String outcome,
    required Map<String, Object?> summary,
    required T Function() audit,
    required void Function(StoredToolTerminal<T>) onCommitted,
  }) {
    _toolSyncAction(audit);
    final savedSummary = _toolCopy(summary);
    return _toolOuter(() {
      _toolOwnerRow(owner);
      final value = _toolSyncValue(audit());
      _toolDiscardStaging(owner.logicalTurnId, outcome);
      _toolInterruptRequests(owner.logicalTurnId, outcome);
      _toolTerminal(owner, status: 'failed', outcome: outcome, summary: savedSummary, reply: false, normal: false);
      return _toolTerminalView(owner, value);
    }, onCommitted);
  }

  bool hasPendingToolRecords() =>
      _db.select("SELECT 1 FROM tool_turns WHERE status = 'active' LIMIT 1").isNotEmpty ||
      _db.select("SELECT 1 FROM tool_requests WHERE status IN ('registered', 'in_flight') LIMIT 1").isNotEmpty ||
      _db.select("SELECT 1 FROM tool_receipts WHERE status = 'prepared' LIMIT 1").isNotEmpty ||
      _db.select("SELECT 1 FROM memory_proposals WHERE status = 'staged' LIMIT 1").isNotEmpty;

  void recoverToolRecords() {
    if (_transactionDepth == 0) throw StateError('Tool recovery must join the initialization transaction.');
    final affected = <String>{};
    for (final turn in _toolRows('tool_turns', "t.status = 'active'", const [])) {
      final id = _toolText(turn, 'id')!;
      affected.add(_toolText(turn, 'chat_id')!);
      _toolDiscardStaging(id, 'interrupted');
    }
    for (final row in _db.select("SELECT DISTINCT chat_id FROM tool_receipts WHERE status = 'prepared'")) {
      affected.add(row['chat_id'] as String);
    }
    final now = _toolNow();
    _db.execute(
      "UPDATE tool_turns SET status = 'interrupted', outcome = 'interrupted', ownership_phase = 'terminal', finished_at_ms = ? WHERE status = 'active'",
      [now],
    );
    _db.execute(
      "UPDATE tool_requests SET status = 'interrupted', response_finished_at_ms = ? WHERE status IN ('registered', 'in_flight')",
      [now],
    );
    _db.execute(
      "UPDATE tool_receipts SET status = 'unresolved', committed = NULL, updated_at_ms = ? WHERE status = 'prepared'",
      [now],
    );
    _db.execute(
      "UPDATE tool_receipts SET status = 'discarded', committed = 0, updated_at_ms = ? WHERE status = 'staged'",
      [now],
    );
    _db.execute(
      "UPDATE memory_proposals SET status = 'inactive_terminal', terminal_reason = 'interrupted', proposal_version = proposal_version + 1, updated_at_ms = ? WHERE status = 'staged'",
      [now],
    );
    _changedChats.addAll(affected);
  }

  TavernToolSourceToken? _toolFinalSource(Row row) =>
      _toolToken(row, 'source_node_id', 'source_seq', 'source_epoch', 'source_content_version');

  Map<String, Object?> _toolProposalFact(Row row) => {
    'version': row['proposal_version'],
    'workflow': row['status'],
    'sourceValidity': row['source_validity'],
    'source': _toolFinalSource(row)?.toJson(),
    'acceptedMemoryId': _toolText(row, 'accepted_memory_id'),
  };

  TavernMemoryProposalSnapshot _toolProposalView(Row row) {
    final chatId = _toolText(row, 'chat_id')!;
    _toolRequireChat(chatId);
    final receipt = _toolProposalReceipt(row);
    final anchor = contextAnchor(chatId);
    final source = _toolFinalSource(row);
    final qualification = sourceEligibility(
      chatId,
      origin: 'remember',
      sourceValidity: row['source_validity'] as String,
      source: source,
      requestedLeafId: anchor.selectedLeaf?.nodeId,
    );
    final workflow = row['status'] as String;
    final reason = workflow == 'accepted' || workflow == 'rejected'
        ? 'already_resolved'
        : workflow != 'pending_confirmation'
        ? 'inactive'
        : qualification.reason;
    final origin = row['last_decision_origin'] as String?;
    final decisionId = _toolText(row, 'last_decision_id');
    if ((origin == null) != (decisionId == null)) {
      throw const FormatException('Incomplete proposal decision reference.');
    }
    final decision = _toolDecisionJson(origin, decisionId);
    if (decision != null && (decision['chatId'] != chatId || decision['proposalId'] != _toolText(row, 'id'))) {
      throw const FormatException('Foreign proposal decision.');
    }
    return TavernMemoryProposalSnapshot.fromJson({
      'proposalId': _toolText(row, 'id'),
      'chatId': chatId,
      'logicalTurnId': _toolText(row, 'logical_turn_id'),
      'requestId': _toolText(receipt, 'request_id'),
      'executionId': _toolText(row, 'receipt_id'),
      'candidateNodeId': _toolText(row, 'candidate_node_id'),
      'candidateSeq': row['candidate_seq'],
      'candidateSourceEpoch': row['candidate_source_epoch'],
      'text': _toolText(row, 'text'),
      'keywords': _toolList(row['keywords_json']),
      'mode': row['mode'],
      'version': row['proposal_version'],
      'workflow': workflow,
      'sourceValidity': row['source_validity'],
      'source': source?.toJson(),
      'memoryId': _toolText(row, 'accepted_memory_id'),
      'lastDecisionRef': origin == null ? null : {'origin': origin, 'decisionId': decisionId},
      'contextAnchor': anchor.toJson(),
      'eligible': workflow == 'pending_confirmation' && qualification.eligible,
      'ineligibleReason': reason,
    });
  }

  /// One statement lists identities without decoding request/inspection data.
  List<TavernToolTurnSummary> recentToolTurns(String chatId, {int limit = 20}) {
    _ensureOpen();
    if (limit < 0) throw ArgumentError.value(limit, 'limit', 'Must be non-negative.');
    final rows = _db.select(
      '''
      WITH recent AS (
        SELECT rowid AS ordinal, id, chat_id, reply_commit_adopted, candidate_live_node_id, candidate_seq
        FROM tool_turns WHERE chat_id = ? ORDER BY rowid DESC LIMIT ?
      )
      SELECT char(1) || t.id AS logical_turn_id, char(1) || n.id AS reply_node_id
      FROM chats c LEFT JOIN recent t ON t.chat_id = c.id
        LEFT JOIN nodes n ON t.reply_commit_adopted = 1 AND n.id = t.candidate_live_node_id
          AND n.chat_id = t.chat_id AND n.seq = t.candidate_seq AND n.deleted_by IS NULL
      WHERE c.id = ? ORDER BY t.ordinal DESC
    ''',
      [chatId, limit, chatId],
    );
    if (rows.isEmpty) throw StateError('Chat not found: $chatId');
    return [
      for (final row in rows)
        if (row['logical_turn_id'] != null)
          TavernToolTurnSummary(
            logicalTurnId: ChatStore._unguardText(row['logical_turn_id'])!,
            replyNodeId: ChatStore._unguardText(row['reply_node_id']),
          ),
    ];
  }

  TavernToolTurnSnapshot? readToolTurn(String logicalTurnId) {
    _toolIdentity(logicalTurnId, 'logicalTurnId');
    final row = _toolRow('tool_turns', logicalTurnId);
    if (row == null) return null;
    final chatId = _toolText(row, 'chat_id')!;
    _toolRequireChat(chatId);
    final requests = _toolRows('tool_requests', 't.logical_turn_id = ?', [
      logicalTurnId,
    ], suffix: 'ORDER BY t.request_index');
    for (final request in requests) {
      if (_toolText(request, 'chat_id') != chatId) throw const FormatException('Foreign turn request.');
    }
    final snapshots = [for (final request in requests) _toolRequestView(request)];
    final proposals = _toolRows('memory_proposals', 't.logical_turn_id = ?', [
      logicalTurnId,
    ], suffix: 'ORDER BY t.rowid');
    for (final proposal in proposals) {
      if (_toolText(proposal, 'chat_id') != chatId) throw const FormatException('Foreign turn proposal.');
    }
    return TavernToolTurnSnapshot.fromJson({
      'version': 1,
      'logicalTurnId': logicalTurnId,
      'chatId': chatId,
      'generationType': switch (row['operation']) {
        'send' => 'normal',
        'regenerate' => 'regenerate',
        'continueReply' => 'continue',
        _ => throw const FormatException('Invalid tool generation type.'),
      },
      'actorId': _toolText(row, 'actor_character_id'),
      'hostId': _toolText(row, 'host_character_id'),
      'groupRoundId': _toolText(row, 'group_round_id'),
      'capturedPolicy': _toolPolicyEnvelope(row['policy_snapshot_json']),
      'admissionAnchor': _toolObject(row['admission_anchor_json']),
      'candidateSource': _toolOwnership(row).candidateSource?.toJson(),
      'budgetUsed': requests.length,
      'budgetMax': 4,
      'requests': [for (final request in snapshots) request.toJson()],
      'receiptIds': [for (final request in snapshots) ...request.receiptIds],
      'proposals': [for (final proposal in proposals) _toolProposalView(proposal).toJson()],
      'status': row['status'],
      'outcome': _toolText(row, 'outcome'),
      'replyCommitAdopted': row['reply_commit_adopted'] == 1,
      'normalFinalAdopted': row['normal_final_adopted'] == 1,
      'usageSummary': summarizeToolUsage([
        for (final request in requests)
          (requestIndex: request['request_index'] as int, usage: _toolObject(request['usage_json'])),
      ]),
      'currentContextAnchor': contextAnchor(chatId).toJson(),
    });
  }

  StoredToolMemoryStage stageMemoryProposal(
    StoredToolTurnOwner owner, {
    required StoredModelToolCall call,
    required String mode,
    required String text,
    required List<String> keywords,
    required void Function(StoredToolMemoryStage) onCommitted,
  }) {
    final keys = List<String>.unmodifiable(keywords);
    if (call.toolName != 'remember' ||
        !const ['ask', 'auto'].contains(mode) ||
        text.isEmpty ||
        text.length > 4096 ||
        keys.isEmpty ||
        keys.length > 16 ||
        keys.any((key) => key.isEmpty || key.length > 128)) {
      throw ArgumentError('Invalid remember proposal.');
    }
    return _toolOuter(() {
      final request = _toolModelRequest(owner, call);
      if (_toolObject(request['wire_authorization_json'])['rememberAllowed'] != true) {
        throw StateError('Remember was not authorized on this request.');
      }
      final turn = _toolRequired('tool_turns', owner.logicalTurnId);
      final policy = _toolPolicyEnvelope(turn['policy_snapshot_json']);
      final captured = policy['captured'];
      if (policy['captureState'] != 'ready' ||
          captured is! Map<String, Object?> ||
          captured['rememberAllowed'] != true ||
          captured['rememberMode'] != mode) {
        throw StateError('Remember mode differs from admission policy.');
      }
      final source = _toolOwnership(turn).candidateSource!;
      final proposalId = _createId();
      final receiptId = _toolInsertModelReceipt(
        owner,
        call,
        'staged',
        proposalId: proposalId,
        result: {'proposalId': proposalId, 'mode': mode, 'status': 'staged'},
      );
      final now = _toolNow();
      _toolInsert('memory_proposals', {
        'id': proposalId,
        'chat_id': owner.chatId,
        'logical_turn_id': owner.logicalTurnId,
        'receipt_id': receiptId,
        'mode': mode,
        'text': text,
        'keywords_json': jsonEncode(keys),
        'proposal_version': 1,
        'status': 'staged',
        'source_validity': 'candidate',
        'created_at_ms': now,
        'updated_at_ms': now,
        'candidate_node_id': source.nodeId,
        'candidate_seq': source.seq,
        'candidate_source_epoch': source.sourceEpoch,
      });
      return StoredToolMemoryStage(
        _toolReceiptView(_toolRequired('tool_receipts', receiptId)),
        _toolProposalView(_toolRequired('memory_proposals', proposalId)),
      );
    }, onCommitted);
  }

  Map<String, Object?> _toolSourceFields(TavernToolSourceToken source) => {
    'source_node_id': source.nodeId,
    'source_seq': source.seq,
    'source_epoch': source.sourceEpoch,
    'source_content_version': source.contentVersion,
    'source_live_node_id': source.nodeId,
  };

  String _toolCreateRememberMemory(Row proposal, TavernToolSourceToken source) {
    final id = _createId();
    if (_db
        .select(
          '''SELECT 1 WHERE EXISTS(SELECT 1 FROM memory_decisions WHERE memory_id = ?)
      OR EXISTS(SELECT 1 FROM memory_proposals WHERE accepted_memory_id = ?)''',
          [id, id],
        )
        .isNotEmpty) {
      throw const FormatException('A remembered memory identity cannot be reused.');
    }
    final chatId = _toolText(proposal, 'chat_id')!;
    final receiptId = _toolText(proposal, 'receipt_id')!;
    final receipt = _toolRequired('tool_receipts', receiptId);
    final turnId = _toolText(proposal, 'logical_turn_id')!;
    final turn = _toolRequired('tool_turns', turnId);
    if (_toolText(receipt, 'chat_id') != chatId || _toolText(turn, 'chat_id') != chatId) {
      throw const FormatException('Foreign remember provenance.');
    }
    _toolInsert('memories', {
      'id': id,
      'chat_id': chatId,
      'origin': 'remember',
      'entry_json': jsonEncode({'content': _toolText(proposal, 'text'), 'key': _toolList(proposal['keywords_json'])}),
      'origin_proposal_id': _toolText(proposal, 'id'),
      'origin_logical_turn_id': turnId,
      'origin_receipt_id': receiptId,
      ..._toolSourceFields(source),
      'source_validity': 'bound',
    });
    return id;
  }

  Map<String, Object?> _toolInsertDecision({
    required Row before,
    required Row after,
    required String origin,
    required String decisionId,
    required TavernMemoryDecision decision,
    required String outcome,
    required String? reason,
    required int? expectedVersion,
    required TavernToolContextAnchor? expectedContextAnchor,
    required Map<String, Object?> parameters,
    required String? memoryId,
  }) {
    final now = _toolNow();
    final chatId = _toolText(before, 'chat_id')!;
    final proposalId = _toolText(before, 'id')!;
    final record = TavernMemoryDecisionRecord.fromJson({
      'decisionRef': {'origin': origin, 'decisionId': decisionId},
      'chatId': chatId,
      'proposalId': proposalId,
      'decision': decision.name,
      'outcome': outcome,
      'reason': reason,
      'expectedVersion': expectedVersion,
      'expectedContextAnchor': expectedContextAnchor?.toJson(),
      'parameters': parameters,
      'proposalBefore': _toolProposalFact(before),
      'proposalAfter': _toolProposalFact(after),
      'memoryId': memoryId,
      'createdAt': _toolDate(now),
    }).toJson();
    _toolInsert('memory_decisions', {
      'decision_origin': origin,
      'decision_id': decisionId,
      'chat_id': chatId,
      'proposal_id': proposalId,
      'decision': decision.name,
      'expected_version': expectedVersion,
      'expected_context_anchor_json': expectedContextAnchor == null ? null : jsonEncode(expectedContextAnchor.toJson()),
      'parameters_json': jsonEncode(parameters),
      'outcome': outcome,
      'resulting_proposal_version': after['proposal_version'],
      'memory_id': memoryId,
      'receipt_json': jsonEncode(record),
      'created_at_ms': now,
    });
    _changedChats.add(chatId);
    return record;
  }

  TavernMemoryDecisionReceipt _toolDecisionReceipt(Map<String, Object?> record, {required bool replayed}) {
    final chatId = record['chatId'] as String;
    final proposal = _toolProposalView(_toolRequired('memory_proposals', record['proposalId'] as String));
    if (proposal.chatId != chatId) throw const FormatException('Foreign current proposal.');
    return TavernMemoryDecisionReceipt.fromJson({
      'version': 1,
      'record': record,
      'replayed': replayed,
      'current': {
        'proposal': proposal.toJson(),
        'contextAnchor': proposal.contextAnchor.toJson(),
        'sourceValidity': proposal.sourceValidity,
        'eligible': proposal.eligible,
        'ineligibleReason': proposal.ineligibleReason,
        'targetMissing': _toolTargetMissing(chatId, record['memoryId'] as String?),
      },
    });
  }

  TavernMemoryDecisionReceipt resolveMemoryProposal(
    String proposalId, {
    required String decisionId,
    required int expectedVersion,
    required TavernMemoryDecision decision,
    required TavernToolContextAnchor expectedContextAnchor,
    required void Function(TavernMemoryDecisionReceipt) onCommitted,
  }) {
    _toolIdentity(proposalId, 'proposalId');
    _toolIdentity(decisionId, 'decisionId');
    if (expectedVersion < 1) throw ArgumentError.value(expectedVersion, 'expectedVersion');
    final anchor = TavernToolContextAnchor.fromJson(expectedContextAnchor.toJson());
    final parameters = _toolCopy({
      'proposalId': proposalId,
      'decisionId': decisionId,
      'expectedVersion': expectedVersion,
      'decision': decision.name,
      'expectedContextAnchor': anchor.toJson(),
    });
    return _toolOuter(() {
      final prior = _toolRows('memory_decisions', "t.decision_origin = 'user' AND t.decision_id = ?", [decisionId]);
      if (prior.isNotEmpty) {
        final row = prior.single;
        final record = _toolText(row, 'chat_id') == anchor.chatId ? _toolDecisionJson('user', decisionId) : null;
        if (record == null || !_toolEqual(record['parameters'], parameters)) {
          throw TavernToolException(
            code: TavernToolErrorCode.decisionConflict,
            operation: 'resolveMemoryProposal',
            message: 'The decisionId already has different parameters.',
            committed: false,
            chatId: anchor.chatId,
            proposalId: proposalId,
            decisionRef: TavernMemoryDecisionRef.fromJson({'origin': 'user', 'decisionId': decisionId}),
          );
        }
        return _toolDecisionReceipt(record, replayed: true);
      }
      final before = _toolRow('memory_proposals', proposalId);
      if (before == null || _toolText(before, 'chat_id') != anchor.chatId) {
        throw TavernToolException(
          code: TavernToolErrorCode.notFound,
          operation: 'resolveMemoryProposal',
          message: 'Memory proposal not found.',
          committed: false,
          chatId: anchor.chatId,
          proposalId: proposalId,
        );
      }
      _toolRequireChat(anchor.chatId);
      String? reason;
      final source = _toolFinalSource(before);
      final currentAnchor = contextAnchor(anchor.chatId);
      if (before['proposal_version'] != expectedVersion) {
        reason = 'revision_conflict';
      } else if (before['status'] == 'accepted' || before['status'] == 'rejected') {
        reason = 'already_resolved';
      } else if (before['status'] != 'pending_confirmation') {
        reason = 'inactive';
      } else if (!_toolEqual(currentAnchor.toJson(), anchor.toJson())) {
        reason = 'context_changed';
      } else {
        reason = sourceEligibility(
          anchor.chatId,
          origin: 'remember',
          sourceValidity: before['source_validity'] as String,
          source: source,
          requestedLeafId: currentAnchor.selectedLeaf?.nodeId,
        ).reason;
      }
      if (reason != null) {
        final record = _toolInsertDecision(
          before: before,
          after: before,
          origin: 'user',
          decisionId: decisionId,
          decision: decision,
          outcome: 'not_applied',
          reason: reason,
          expectedVersion: expectedVersion,
          expectedContextAnchor: anchor,
          parameters: parameters,
          memoryId: null,
        );
        return _toolDecisionReceipt(record, replayed: false);
      }
      final accepted = decision == TavernMemoryDecision.accept;
      final memoryId = accepted ? _toolCreateRememberMemory(before, source!) : null;
      final now = _toolNow();
      _db.execute(
        '''UPDATE memory_proposals SET status = ?, proposal_version = proposal_version + 1,
        accepted_memory_id = ?, memory_live_id = ?, last_decision_origin = 'user', last_decision_id = ?, updated_at_ms = ?
        WHERE id = ? AND proposal_version = ? AND status = 'pending_confirmation' ''',
        [accepted ? 'accepted' : 'rejected', memoryId, memoryId, decisionId, now, proposalId, expectedVersion],
      );
      if (_db.select('SELECT changes() AS n').single['n'] != 1) throw StateError('Proposal decision CAS failed.');
      final after = _toolRequired('memory_proposals', proposalId);
      final record = _toolInsertDecision(
        before: before,
        after: after,
        origin: 'user',
        decisionId: decisionId,
        decision: decision,
        outcome: accepted ? 'accepted' : 'rejected',
        reason: null,
        expectedVersion: expectedVersion,
        expectedContextAnchor: anchor,
        parameters: parameters,
        memoryId: memoryId,
      );
      _toolUpdate(
        'tool_receipts',
        {
          'status': accepted ? 'committed' : 'rejected',
          'committed': accepted ? 1 : 0,
          'result_json': _toolResult({
            'proposalId': proposalId,
            'status': accepted ? 'accepted' : 'rejected',
            'memoryId': memoryId,
            'decisionRef': record['decisionRef'],
          }, null),
          'decision_origin': 'user',
          'decision_id': decisionId,
          'updated_at_ms': now,
          'result_adopted_at_ms': accepted ? now : null,
        },
        'id = ?',
        [_toolText(before, 'receipt_id')],
      );
      return _toolDecisionReceipt(record, replayed: false);
    }, onCommitted);
  }

  List<StoredRememberMemory> rememberMemories(String chatId, {required String? requestedLeafId}) {
    _chatRow(chatId);
    final result = <StoredRememberMemory>[];
    for (final row in _toolRows('memories', "t.chat_id = ? AND (t.origin != 'legacy' OR t.origin IS NULL)", [
      chatId,
    ], suffix: 'ORDER BY t.rowid')) {
      var entry = <String, Object?>{};
      TavernToolSourceToken? source;
      String? reason;
      try {
        entry = _toolObject(row['entry_json']);
        source = _toolFinalSource(row);
        reason = row['origin'] != 'remember'
            ? 'invalid_origin'
            : source == null
            ? 'missing_source'
            : sourceEligibility(
                chatId,
                origin: 'remember',
                sourceValidity: row['source_validity'] as String,
                source: source,
                requestedLeafId: requestedLeafId,
              ).reason;
      } on FormatException {
        reason = 'invalid_saved_remember_json';
      } on TypeError {
        reason = 'invalid_saved_remember_source';
      }
      result.add(
        StoredRememberMemory(
          id: _toolText(row, 'id')!,
          rowId: row['_row_id'] as int,
          entry: entry,
          available: reason == null,
          unavailableReason: reason,
          source: source,
        ),
      );
    }
    return List.unmodifiable(result);
  }

  void _toolCheckRequestTurn(Row request) {
    final turn = _toolRequired('tool_turns', _toolText(request, 'logical_turn_id')!);
    if (_toolText(turn, 'chat_id') != _toolText(request, 'chat_id')) {
      throw const FormatException('Foreign request logical turn.');
    }
  }

  void _toolCheckReceiptRequest(Row receipt, Row request) {
    if (receipt['origin'] != 'model' ||
        _toolText(receipt, 'request_id') != _toolText(request, 'id') ||
        _toolText(receipt, 'chat_id') != _toolText(request, 'chat_id')) {
      throw const FormatException('Foreign receipt request.');
    }
  }

  Row? _toolReceiptRequest(Row receipt) {
    final requestId = _toolText(receipt, 'request_id');
    if (requestId == null) {
      if (receipt['origin'] != 'manual') throw const FormatException('Missing model receipt request.');
      return null;
    }
    final request = _toolRequired('tool_requests', requestId);
    _toolCheckReceiptRequest(receipt, request);
    _toolCheckRequestTurn(request);
    return request;
  }

  void _toolCheckProposalReceipt(Row proposal, Row receipt, Row? request) {
    if (request == null ||
        receipt['origin'] != 'model' ||
        _toolText(receipt, 'tool_name') != 'remember' ||
        _toolText(proposal, 'receipt_id') != _toolText(receipt, 'id') ||
        _toolText(receipt, 'proposal_id') != _toolText(proposal, 'id') ||
        _toolText(proposal, 'chat_id') != _toolText(receipt, 'chat_id') ||
        _toolText(proposal, 'logical_turn_id') != _toolText(request, 'logical_turn_id')) {
      throw const FormatException('Memory proposal and receipt provenance disagree.');
    }
  }

  Row _toolProposalReceipt(Row proposal) {
    final receipt = _toolRequired('tool_receipts', _toolText(proposal, 'receipt_id')!);
    _toolCheckProposalReceipt(proposal, receipt, _toolReceiptRequest(receipt));
    return receipt;
  }

  Row? _toolReceiptProposal(Row receipt, Row? request) {
    final proposalId = _toolText(receipt, 'proposal_id');
    if (proposalId == null) return null;
    final proposal = _toolRequired('memory_proposals', proposalId);
    _toolCheckProposalReceipt(proposal, receipt, request);
    return proposal;
  }

  TavernToolRequestSnapshot _toolRequestView(Row row) {
    final id = _toolText(row, 'id')!;
    _toolRequireChat(_toolText(row, 'chat_id')!);
    _toolCheckRequestTurn(row);
    final receipts = _toolRows('tool_receipts', 't.request_id = ?', [id], suffix: 'ORDER BY t.tool_index');
    for (final receipt in receipts) {
      _toolCheckReceiptRequest(receipt, row);
      _toolReceiptProposal(receipt, row);
    }
    return TavernToolRequestSnapshot.fromJson({
      'requestId': id,
      'requestIndex': row['request_index'],
      'status': row['status'],
      'offeredTools': _toolList(row['offered_tools_json']),
      'sendAttempts': _toolSendAttempts(row['send_attempts_json']),
      'providerFinishReason': _toolText(row, 'provider_finish_reason'),
      'responseComplete': row['response_complete'] == 1,
      'usage': _toolObject(row['usage_json']),
      'batchDiagnostics': _toolObject(row['batch_diagnostics_json']),
      'receiptIds': [for (final receipt in receipts) _toolText(receipt, 'id')],
    });
  }

  TavernToolRequestSnapshot registerToolRequest(
    StoredToolTurnOwner owner, {
    required List<String> offeredTools,
    required Map<String, Object?> wireAuthorization,
    required void Function(TavernToolRequestSnapshot) onCommitted,
  }) {
    final offered = List<String>.unmodifiable(offeredTools);
    final authorization = _toolCopy(wireAuthorization);
    return _toolOuter(() {
      final turn = _toolCheck(owner, StoredToolPhase.owned);
      if (_toolPolicyEnvelope(turn['policy_snapshot_json'])['captureState'] != 'ready') {
        throw StateError('A request requires completed admission policy.');
      }
      final count = _toolRows('tool_requests', 't.logical_turn_id = ?', [owner.logicalTurnId]).length;
      if (count >= 4) throw StoredToolBudgetException(owner.logicalTurnId);
      final index = count + 1;
      final id = '${owner.logicalTurnId}:request:$index';
      _toolInsert('tool_requests', {
        'id': id,
        'chat_id': owner.chatId,
        'logical_turn_id': owner.logicalTurnId,
        'request_index': index,
        'created_at_ms': _toolNow(),
        'offered_tools_json': jsonEncode(offered),
        'wire_authorization_json': jsonEncode(authorization),
        'batch_diagnostics_json': '{}',
        'status': 'registered',
        'response_complete': 0,
        'send_attempts_json': '[]',
        'usage_json': jsonEncode(emptyToolUsageLedger()),
      });
      _changedChats.add(owner.chatId);
      return _toolRequestView(_toolRequired('tool_requests', id));
    }, onCommitted);
  }

  void _toolCheckUsage(Row request, Map<String, Object?> next) {
    final old = _toolObject(request['usage_json']);
    final before = old['observations'];
    final after = next['observations'];
    if (before is! List ||
        after is! List ||
        after.length < before.length ||
        next['version'] != 1 ||
        next['reportedUsageObserved'] is! bool ||
        old['reportedUsageObserved'] == true && next['reportedUsageObserved'] != true) {
      throw const FormatException('Invalid tool usage ledger advance.');
    }
    for (var index = 0; index < before.length; index++) {
      if (!_toolEqual(before[index], after[index])) throw const FormatException('A usage observation is immutable.');
    }
    final selected = next['selectedObservationSequence'];
    final previousSelected = old['selectedObservationSequence'];
    if (previousSelected is int && (selected is! int || selected < previousSelected)) {
      throw const FormatException('Selected usage observation cannot move backwards.');
    }
    summarizeToolUsage([(requestIndex: request['request_index'] as int, usage: next)]);
  }

  TavernToolRequestSnapshot observeToolRequest(
    String requestId, {
    int? sendAttempt,
    Map<String, Object?>? usage,
    Map<String, Object?>? batchDiagnostics,
    required void Function(TavernToolRequestSnapshot) onCommitted,
  }) {
    if (sendAttempt != null && (sendAttempt < 0 || sendAttempt > 2)) {
      throw ArgumentError.value(sendAttempt, 'sendAttempt');
    }
    final nextUsage = usage == null ? null : _toolCopy(usage);
    final diagnostics = batchDiagnostics == null ? null : _toolCopy(batchDiagnostics);
    return _toolOuter(() {
      final row = _toolRequired('tool_requests', requestId);
      final fields = <String, Object?>{};
      if (sendAttempt != null) {
        final attempts = _toolSendAttempts(row['send_attempts_json']);
        if (!attempts.contains(sendAttempt)) attempts.add(sendAttempt);
        fields['send_attempts_json'] = jsonEncode(attempts);
        if (row['status'] == 'registered') fields['status'] = 'in_flight';
      }
      if (nextUsage != null) {
        _toolCheckUsage(row, nextUsage);
        fields['usage_json'] = jsonEncode(nextUsage);
      }
      if (diagnostics != null) fields['batch_diagnostics_json'] = jsonEncode(diagnostics);
      if (fields.isNotEmpty) {
        _toolUpdate('tool_requests', fields, 'id = ?', [requestId]);
        _changedChats.add(_toolText(row, 'chat_id')!);
      }
      return _toolRequestView(_toolRequired('tool_requests', requestId));
    }, onCommitted);
  }

  TavernToolRequestSnapshot finishToolRequest(
    String requestId, {
    required String status,
    required bool responseComplete,
    required String? providerFinishReason,
    required Map<String, Object?>? responseSnapshot,
    required Map<String, Object?> usage,
    required Map<String, Object?> batchDiagnostics,
    required Map<String, Object?>? error,
    required void Function(TavernToolRequestSnapshot) onCommitted,
  }) {
    if (!const ['response_complete', 'failed', 'interrupted'].contains(status)) {
      throw ArgumentError.value(status, 'status');
    }
    final snapshot = responseSnapshot == null ? null : _toolCopy(responseSnapshot);
    final nextUsage = _toolCopy(usage);
    final diagnostics = _toolCopy(batchDiagnostics);
    final capturedError = error == null ? null : _toolCopy(error);
    return _toolOuter(() {
      final row = _toolRequired('tool_requests', requestId);
      _toolCheckUsage(row, nextUsage);
      if (row['response_finished_at_ms'] != null &&
          (row['status'] != status ||
              (row['response_complete'] == 1) != responseComplete ||
              _toolText(row, 'provider_finish_reason') != providerFinishReason ||
              !_toolEqual(
                row['response_snapshot_json'] == null ? null : _toolObject(row['response_snapshot_json']),
                snapshot,
              ))) {
        throw StateError('A request response is already sealed.');
      }
      _toolUpdate(
        'tool_requests',
        {
          'status': status,
          'response_complete': responseComplete ? 1 : 0,
          'provider_finish_reason': providerFinishReason,
          'response_snapshot_json': snapshot == null ? null : jsonEncode(snapshot),
          'response_finished_at_ms': row['response_finished_at_ms'] ?? _toolNow(),
          'usage_json': jsonEncode(nextUsage),
          'batch_diagnostics_json': jsonEncode(diagnostics),
          'error_json': capturedError == null ? null : jsonEncode(capturedError),
        },
        'id = ?',
        [requestId],
      );
      _changedChats.add(_toolText(row, 'chat_id')!);
      return _toolRequestView(_toolRequired('tool_requests', requestId));
    }, onCommitted);
  }

  int? _toolCommitted(String status) => switch (status) {
    'prepared' || 'unresolved' => null,
    'committed' => 1,
    'staged' ||
    'pending_confirmation' ||
    'rejected' ||
    'cancelled_before_execution' ||
    'discarded' ||
    'completed_no_change' => 0,
    _ => throw FormatException('Invalid tool receipt status: $status'),
  };

  String? _toolResult(Map<String, Object?>? result, Map<String, Object?>? error) =>
      result == null && error == null ? null : jsonEncode({'version': 1, 'result': result, 'error': error});

  Map<String, Object?> _toolResultParts(Row row) {
    if (row['result_json'] == null) return const {'version': 1, 'result': null, 'error': null};
    final parts = _toolObject(row['result_json']);
    if (parts['version'] != 1 ||
        parts['result'] != null && parts['result'] is! Map<String, Object?> ||
        parts['error'] != null && parts['error'] is! Map<String, Object?>) {
      throw const FormatException('Invalid tool receipt result envelope.');
    }
    return parts;
  }

  Map<String, Object?>? _toolDecisionJson(String? origin, String? id) {
    if (origin == null && id == null) return null;
    if (origin == null || id == null) throw const FormatException('Incomplete decision reference.');
    final rows = _toolRows('memory_decisions', 't.decision_origin = ? AND t.decision_id = ?', [origin, id]);
    if (rows.length != 1) throw const FormatException('Missing referenced memory decision.');
    final row = rows.single;
    final value = TavernMemoryDecisionRecord.fromJson(_toolObject(row['receipt_json']));
    final expectedAnchor = row['expected_context_anchor_json'] == null
        ? null
        : TavernToolContextAnchor.fromJson(_toolObject(row['expected_context_anchor_json'])).toJson();
    if (value.decisionRef.origin != origin ||
        value.decisionRef.decisionId != id ||
        value.chatId != _toolText(row, 'chat_id') ||
        value.proposalId != _toolText(row, 'proposal_id') ||
        value.outcome != row['outcome'] ||
        value.memoryId != _toolText(row, 'memory_id') ||
        value.decision.name != row['decision'] ||
        value.expectedVersion != row['expected_version'] ||
        !_toolEqual(value.expectedContextAnchor?.toJson(), expectedAnchor) ||
        !_toolEqual(value.parameters, _toolObject(row['parameters_json'])) ||
        !_toolEqual(value.proposalAfter['version'], row['resulting_proposal_version']) ||
        value.createdAt.toUtc().toIso8601String() != _toolDate(row['created_at_ms'])) {
      throw const FormatException('Memory decision record does not match its identity.');
    }
    _toolRequireChat(value.chatId);
    return value.toJson();
  }

  bool? _toolTargetMissing(String chatId, String? memoryId) => memoryId == null
      ? null
      : _db.select('SELECT 1 FROM memories WHERE chat_id = ? AND id = ?', [chatId, memoryId]).isEmpty;

  TavernToolReceipt _toolReceiptView(Row row) {
    final id = _toolText(row, 'id')!;
    final chatId = _toolText(row, 'chat_id')!;
    _toolRequireChat(chatId);
    final requestId = _toolText(row, 'request_id');
    final request = _toolReceiptRequest(row);
    final proposalId = _toolText(row, 'proposal_id');
    final proposal = _toolReceiptProposal(row, request);
    final decision = _toolDecisionJson(row['decision_origin'] as String?, _toolText(row, 'decision_id'));
    if (decision != null && (decision['chatId'] != chatId || decision['proposalId'] != proposalId)) {
      throw const FormatException('Foreign receipt decision.');
    }
    final parts = _toolResultParts(row);
    if (row['committed'] != _toolCommitted(row['status'] as String)) {
      throw const FormatException('Invalid receipt adoption flag.');
    }
    return TavernToolReceipt.fromJson({
      'version': 1,
      'receiptId': id,
      'executionId': id,
      'chatId': chatId,
      'kind': _toolText(row, 'tool_name'),
      'origin': row['origin'],
      'logicalTurnId': request == null ? null : _toolText(request, 'logical_turn_id'),
      'requestId': requestId,
      'requestIndex': request?['request_index'],
      'toolIndex': row['tool_index'],
      'callId': _toolText(row, 'raw_call_id'),
      'actionId': _toolText(row, 'action_id'),
      'status': row['status'],
      'committed': row['committed'] == null ? null : row['committed'] == 1,
      'capturedParameters': _toolObject(row['input_json']),
      'rawArguments': _toolText(row, 'raw_arguments'),
      'result': parts['result'],
      'error': parts['error'],
      'wireResult': row['wire_result_json'] == null ? null : _toolObject(row['wire_result_json']),
      'proposalId': proposalId,
      'decisionRef': decision?['decisionRef'],
      'decisionRecord': decision,
      'sourceValidity': proposal?['source_validity'],
      'targetMissing': _toolTargetMissing(chatId, decision?['memoryId'] as String?),
      'createdAt': _toolDate(row['created_at_ms']),
      'updatedAt': _toolDate(row['updated_at_ms']),
    });
  }

  TavernToolReceipt? readToolReceipt(String executionId) {
    _toolIdentity(executionId, 'executionId');
    final row = _toolRow('tool_receipts', executionId);
    return row == null ? null : _toolReceiptView(row);
  }

  Row _toolModelRequest(StoredToolTurnOwner owner, StoredModelToolCall call) {
    _toolCheck(owner, StoredToolPhase.owned);
    _toolIdentity(call.callId, 'callId');
    _toolIdentity(call.toolName, 'toolName');
    if (call.toolIndex < 0) throw ArgumentError.value(call.toolIndex, 'toolIndex');
    final request = _toolRequired('tool_requests', call.requestId);
    if (_toolText(request, 'logical_turn_id') != owner.logicalTurnId || _toolText(request, 'chat_id') != owner.chatId) {
      throw StateError('Tool call belongs to another logical turn.');
    }
    if (request['response_complete'] != 1 ||
        request['status'] != 'response_complete' ||
        !const ['stop', 'tool_calls'].contains(_toolText(request, 'provider_finish_reason'))) {
      throw StateError('Tools require a complete normal response.');
    }
    return request;
  }

  String _toolInsertModelReceipt(
    StoredToolTurnOwner owner,
    StoredModelToolCall call,
    String status, {
    Map<String, Object?>? result,
    Map<String, Object?>? error,
    String? proposalId,
  }) {
    final turn = _toolRequired('tool_turns', owner.logicalTurnId);
    final id = _createId();
    final now = _toolNow();
    _toolInsert('tool_receipts', {
      'id': id,
      'chat_id': owner.chatId,
      'origin': 'model',
      'request_id': call.requestId,
      'tool_index': call.toolIndex,
      'raw_call_id': call.callId,
      'tool_name': call.toolName,
      'raw_arguments': call.rawArguments,
      'input_json': jsonEncode(call.capturedParameters),
      'validated_parameters_json': call.validatedParameters == null ? null : jsonEncode(call.validatedParameters),
      'policy_snapshot_json': turn['policy_snapshot_json'],
      'status': status,
      'committed': _toolCommitted(status),
      'result_json': _toolResult(result, error),
      'proposal_id': proposalId,
      'created_at_ms': now,
      'updated_at_ms': now,
    });
    _changedChats.add(owner.chatId);
    return id;
  }

  TavernToolReceipt prepareToolReceipt(
    StoredToolTurnOwner owner, {
    required StoredModelToolCall call,
    required String status,
    Map<String, Object?>? result,
    Map<String, Object?>? error,
    required void Function(TavernToolReceipt) onCommitted,
  }) {
    if (status != 'rejected' &&
        !(status == 'prepared' && call.toolName == 'roll') &&
        !(status == 'staged' && call.toolName == 'update_state')) {
      throw ArgumentError('Invalid model receipt initial status.');
    }
    final capturedResult = result == null ? null : _toolCopy(result);
    final capturedError = error == null ? null : _toolCopy(error);
    return _toolOuter(() {
      final request = _toolModelRequest(owner, call);
      if (status == 'prepared' && _toolObject(request['wire_authorization_json'])['rollAllowed'] != true) {
        throw StateError('Roll was not authorized on this request.');
      }
      final id = _toolInsertModelReceipt(owner, call, status, result: capturedResult, error: capturedError);
      return _toolReceiptView(_toolRequired('tool_receipts', id));
    }, onCommitted);
  }

  TavernToolReceipt? readManualToolReceipt(
    String chatId, {
    required String actionId,
    required Map<String, Object?> capturedParameters,
  }) {
    final rows = _toolRows('tool_receipts', 't.chat_id = ? AND t.action_id = ?', [chatId, actionId]);
    if (rows.isEmpty) return null;
    final row = rows.single;
    if (!_toolEqual(_toolObject(row['input_json']), capturedParameters)) {
      throw TavernToolException(
        code: TavernToolErrorCode.actionConflict,
        operation: 'rollDice',
        message: 'The actionId already has different parameters.',
        committed: false,
        chatId: chatId,
        executionId: _toolText(row, 'id'),
      );
    }
    return _toolReceiptView(row);
  }

  TavernToolReceipt prepareManualToolReceipt(
    String chatId, {
    required String actionId,
    required Map<String, Object?> capturedParameters,
    required Map<String, Object?> validatedParameters,
    required Map<String, Object?> capturedPolicy,
    required TavernToolContextAnchor expectedContextAnchor,
    required void Function() checkAdmission,
    required void Function(TavernToolReceipt) onCommitted,
  }) {
    _toolIdentity(chatId, 'chatId');
    _toolIdentity(actionId, 'actionId');
    final input = _toolCopy(capturedParameters);
    final validated = _toolCopy(validatedParameters);
    final policy = _toolCopy(capturedPolicy);
    final anchor = TavernToolContextAnchor.fromJson(expectedContextAnchor.toJson());
    return _toolOuter(() {
      final existing = readManualToolReceipt(chatId, actionId: actionId, capturedParameters: input);
      if (existing != null) return existing;
      _toolSyncAction(checkAdmission);
      checkAdmission();
      if (policy['rollAllowed'] != true) {
        throw TavernToolException(
          code: TavernToolErrorCode.policyDisabled,
          operation: 'rollDice',
          message: 'Manual roll is disabled by the captured policy.',
          committed: false,
          chatId: chatId,
        );
      }
      if (anchor.chatId != chatId ||
          !_toolEqual(contextAnchor(chatId).toJson(), anchor.toJson()) ||
          input['expectedNodeId'] != null && input['expectedNodeId'] != anchor.selectedLeaf?.nodeId) {
        throw TavernToolException(
          code: TavernToolErrorCode.anchorChanged,
          operation: 'rollDice',
          message: 'The action context changed.',
          committed: false,
          chatId: chatId,
        );
      }
      if (input['chatId'] != chatId || input['actionId'] != actionId) {
        throw ArgumentError('Manual identity differs from input.');
      }
      final now = _toolNow();
      final id = _createId();
      _toolInsert('tool_receipts', {
        'id': id,
        'chat_id': chatId,
        'origin': 'manual',
        'action_id': actionId,
        'tool_name': 'roll',
        'input_json': jsonEncode(input),
        'validated_parameters_json': jsonEncode(validated),
        'policy_snapshot_json': jsonEncode(policy),
        'action_anchor_json': jsonEncode(anchor.toJson()),
        'status': 'prepared',
        'committed': null,
        'created_at_ms': now,
        'updated_at_ms': now,
      });
      _changedChats.add(chatId);
      return _toolReceiptView(_toolRequired('tool_receipts', id));
    }, onCommitted);
  }

  void _toolValidateRollResult(Row row, Map<String, Object?> result) {
    if (_toolText(row, 'tool_name') != 'roll') throw StateError('Only a prepared roll can adopt a dice result.');
    final parameters = _toolObject(row['validated_parameters_json']);
    final input = _toolObject(row['input_json']);
    final count = parameters['count'];
    final sides = parameters['sides'];
    final modifier = parameters['modifier'];
    final values = result['values'];
    if (count is! int ||
        count < 1 ||
        count > 100 ||
        sides is! int ||
        sides < 2 ||
        sides > 1000 ||
        modifier is! int ||
        modifier.abs() > 1000000 ||
        values is! List ||
        values.length != count ||
        values.any((value) => value is! int || value < 1 || value > sides)) {
      throw const FormatException('Dice result does not match validated parameters.');
    }
    final total = values.cast<int>().fold<int>(modifier, (sum, value) => sum + value);
    final rawTarget = input['target'];
    final target = rawTarget is num ? rawTarget.toInt() : null;
    if (result['count'] is! int ||
        result['sides'] is! int ||
        result['modifier'] is! int ||
        result['total'] is! int ||
        result['target'] != null && result['target'] is! int ||
        result['pass'] != null && result['pass'] is! bool ||
        result['dice'] != input['dice'] ||
        result['count'] != count ||
        result['sides'] != sides ||
        result['modifier'] != modifier ||
        result['total'] != total ||
        result['label'] != input['label'] ||
        result['target'] != target ||
        result['pass'] != (target == null ? null : total >= target)) {
      throw const FormatException('Dice result disagrees with its captured action.');
    }
  }

  TavernToolReceipt commitToolReceipt(
    String executionId, {
    required Map<String, Object?> result,
    required void Function(TavernToolReceipt) onCommitted,
  }) {
    final captured = _toolCopy(result);
    return _toolOuter(() {
      final row = _toolRequired('tool_receipts', executionId);
      _toolValidateRollResult(row, captured);
      if (row['status'] == 'committed') {
        if (!_toolEqual(_toolResultParts(row)['result'], captured)) throw StateError('A dice result is immutable.');
        return _toolReceiptView(row);
      }
      if (row['status'] != 'prepared') throw StateError('This dice execution cannot be completed again.');
      final now = _toolNow();
      _toolUpdate(
        'tool_receipts',
        {
          'status': 'committed',
          'committed': 1,
          'result_json': _toolResult(captured, null),
          'updated_at_ms': now,
          'result_adopted_at_ms': now,
        },
        'id = ?',
        [executionId],
      );
      _changedChats.add(_toolText(row, 'chat_id')!);
      return _toolReceiptView(_toolRequired('tool_receipts', executionId));
    }, onCommitted);
  }

  TavernToolReceipt _toolEndPreparedRoll(
    String executionId,
    String status,
    Map<String, Object?> reason,
    void Function(TavernToolReceipt) onCommitted,
  ) {
    final captured = _toolCopy(reason);
    return _toolOuter(() {
      final row = _toolRequired('tool_receipts', executionId);
      if (_toolText(row, 'tool_name') != 'roll') throw StateError('Only a roll has an execution intent.');
      if (row['status'] == 'prepared') {
        _toolUpdate(
          'tool_receipts',
          {
            'status': status,
            'committed': _toolCommitted(status),
            'result_json': _toolResult(null, captured),
            'updated_at_ms': _toolNow(),
          },
          'id = ?',
          [executionId],
        );
        _changedChats.add(_toolText(row, 'chat_id')!);
      }
      return _toolReceiptView(_toolRequired('tool_receipts', executionId));
    }, onCommitted);
  }

  TavernToolReceipt cancelToolReceiptBeforeExecution(
    String executionId, {
    required Map<String, Object?> reason,
    required void Function(TavernToolReceipt) onCommitted,
  }) => _toolEndPreparedRoll(executionId, 'cancelled_before_execution', reason, onCommitted);

  TavernToolReceipt markToolReceiptUnresolved(
    String executionId, {
    required Map<String, Object?> reason,
    required void Function(TavernToolReceipt) onCommitted,
  }) => _toolEndPreparedRoll(executionId, 'unresolved', reason, onCommitted);

  TavernToolReceipt sealToolReceiptWireResult(
    String executionId, {
    required String wireResultJson,
    required void Function(TavernToolReceipt) onCommitted,
  }) {
    _toolObject(wireResultJson);
    return _toolOuter(() {
      final row = _toolRequired('tool_receipts', executionId);
      final existing = toolWireResult(executionId);
      if (existing != null && existing != wireResultJson) throw StateError('Tool wire result is already sealed.');
      if (existing == null) {
        _toolUpdate('tool_receipts', {'wire_result_json': wireResultJson}, 'id = ?', [executionId]);
        _changedChats.add(_toolText(row, 'chat_id')!);
      }
      return _toolReceiptView(_toolRequired('tool_receipts', executionId));
    }, onCommitted);
  }

  String? toolWireResult(String executionId) {
    final rows = _db.select('SELECT char(1) || wire_result_json AS value FROM tool_receipts WHERE id = ?', [
      executionId,
    ]);
    if (rows.isEmpty) return null;
    final value = ChatStore._unguardText(rows.single['value']);
    if (value != null) _toolObject(value);
    return value;
  }

  T _toolOuter<T>(
    T Function() action,
    void Function(T) onCommitted, {
    bool bodyOnly = false,
    void Function(String)? onTiming,
  }) {
    _outsideTransaction();
    if (onCommitted is Future<dynamic> Function(T)) {
      throw ArgumentError('Tool adoption must be synchronous.');
    }
    late T prepared;
    final result = _withDurability(
      bodyOnly ? 1 : 2,
      () {
        onTiming?.call('begin');
        return prepared = action();
      },
      onCommitted: () {
        onCommitted(prepared);
        onTiming?.call('commit_adopt');
      },
      bodyOnly: bodyOnly,
    );
    onTiming?.call('publish_restore');
    return result;
  }

  List<Row> _toolRows(String table, String where, List<Object?> parameters, {String suffix = ''}) {
    final guards = _toolGuardColumns[table];
    if (guards == null) throw StateError('Unknown internal tool table.');
    final projection = guards.map((column) => 'char(1) || t.$column AS _read_$column').join(', ');
    return _db.select('SELECT t.*, t.rowid AS _row_id, $projection FROM $table t WHERE $where $suffix', parameters);
  }

  Row? _toolRow(String table, String id) {
    final rows = _toolRows(table, 't.id = ?', [id]);
    return rows.isEmpty ? null : rows.single;
  }

  Row _toolRequired(String table, String id) =>
      _toolRow(table, id) ?? (throw FormatException('Missing required $table record: $id'));

  void _toolRequireChat(String chatId) {
    if (_db.select('SELECT 1 FROM chats WHERE id = ?', [chatId]).isEmpty) {
      throw const FormatException('Missing required tool parent chat.');
    }
  }

  String? _toolText(Row row, String column) =>
      row.containsKey('_read_$column') ? ChatStore._unguardText(row['_read_$column']) : row[column] as String?;

  Map<String, Object?> _toolObject(Object? value) {
    if (value is! String) throw const FormatException('Missing tool JSON object.');
    final decoded = jsonDecode(value);
    if (decoded is! Map<String, Object?>) throw const FormatException('Invalid tool JSON object.');
    return _toolCopy(decoded);
  }

  List<Object?> _toolList(Object? value) {
    if (value is! String) throw const FormatException('Missing tool JSON list.');
    final decoded = jsonDecode(value);
    if (decoded is! List<Object?>) throw const FormatException('Invalid tool JSON list.');
    return decoded;
  }

  List<int> _toolSendAttempts(Object? value) {
    final values = _toolList(value);
    if (values.length > 3) throw const FormatException('Invalid stored tool send attempts.');
    final seen = <int>{};
    final result = <int>[];
    for (final attempt in values) {
      if (attempt is! int || attempt < 0 || attempt > 2 || !seen.add(attempt)) {
        throw const FormatException('Invalid stored tool send attempts.');
      }
      result.add(attempt);
    }
    return result;
  }

  Map<String, Object?> _toolPolicyEnvelope(Object? value) {
    final policy = _toolObject(value);
    final scope = policy['scope'];
    final captured = policy['captured'];
    if (policy['version'] != 1 ||
        scope is! Map<String, Object?> ||
        !const ['pending', 'ready'].contains(policy['captureState'])) {
      throw const FormatException('Invalid captured policy envelope.');
    }
    TavernToolPolicySnapshot.fromJson(scope);
    if (policy['captureState'] == 'pending') {
      if (captured != null) throw const FormatException('A pending policy cannot contain a captured grant.');
    } else if (captured is! Map<String, Object?> ||
        !_toolEqual(captured['scope'], scope) ||
        captured['rollAllowed'] is! bool ||
        captured['rememberAllowed'] is! bool ||
        !const ['ask', 'auto'].contains(captured['rememberMode'])) {
      throw const FormatException('Invalid completed admission policy.');
    }
    return policy;
  }

  void _toolInsert(String table, Map<String, Object?> fields) {
    _db.execute(
      'INSERT INTO $table (${fields.keys.join(', ')}) VALUES (${List.filled(fields.length, '?').join(', ')})',
      fields.values.toList(growable: false),
    );
  }

  void _toolUpdate(String table, Map<String, Object?> fields, String where, List<Object?> parameters) {
    _db.execute('UPDATE $table SET ${fields.keys.map((key) => '$key = ?').join(', ')} WHERE $where', [
      ...fields.values,
      ...parameters,
    ]);
  }

  int _toolNow() => _clock().toUtc().millisecondsSinceEpoch;
  String _toolDate(Object? value) {
    if (value is! int) throw const FormatException('Invalid stored tool timestamp.');
    try {
      return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true).toIso8601String();
    } on RangeError {
      throw const FormatException('Stored tool timestamp is out of range.');
    }
  }

  TavernToolSourceToken? _toolMaybeSource(String chatId, String nodeId) {
    final rows = _db.select(
      '''SELECT char(1) || id AS id, seq, source_epoch, content_version
      FROM nodes WHERE chat_id = ? AND id = ? AND deleted_by IS NULL''',
      [chatId, nodeId],
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    return TavernToolSourceToken(
      nodeId: ChatStore._unguardText(row['id'])!,
      seq: row['seq'] as int,
      sourceEpoch: row['source_epoch'] as int,
      contentVersion: row['content_version'] as int,
    );
  }

  TavernToolSourceToken sourceToken(String chatId, String nodeId) =>
      _toolMaybeSource(chatId, nodeId) ?? (throw StateError('Node does not belong to chat: $nodeId'));

  TavernToolContextAnchor contextAnchor(String chatId) {
    _ensureOpen();
    final rows = _db.select('SELECT char(1) || current_leaf_id AS leaf, tree_revision FROM chats WHERE id = ?', [
      chatId,
    ]);
    if (rows.isEmpty) throw StateError('Chat not found: $chatId');
    final saved = rows.single;
    final id = ChatStore._unguardText(saved['leaf']);
    final source = id == null ? null : _toolMaybeSource(chatId, id);
    if (id != null && source == null) throw const FormatException('Selected leaf is not visible in this chat.');
    final revision = saved['tree_revision'];
    if (revision is! int) throw const FormatException('Invalid stored chat tree revision.');
    return TavernToolContextAnchor(chatId: chatId, selectedLeaf: source, treeRevision: revision);
  }

  StoredToolSourceEligibility sourceEligibility(
    String chatId, {
    required String origin,
    required String sourceValidity,
    required TavernToolSourceToken? source,
    required String? requestedLeafId,
  }) {
    if (sourceValidity == 'orphaned') return const StoredToolSourceEligibility(false, 'source_deleted', 'orphaned');
    if (sourceValidity == 'invalidated') {
      return const StoredToolSourceEligibility(false, 'source_changed', 'invalidated');
    }
    if (origin != 'remember' || sourceValidity != 'bound' || source == null) {
      return StoredToolSourceEligibility(false, 'inactive', sourceValidity);
    }
    final actual = _toolMaybeSource(chatId, source.nodeId);
    if (actual == null || actual.seq != source.seq || actual.sourceEpoch != source.sourceEpoch) {
      return StoredToolSourceEligibility(false, 'source_deleted', sourceValidity);
    }
    if (actual.contentVersion != source.contentVersion) {
      return StoredToolSourceEligibility(false, 'source_changed', sourceValidity);
    }
    try {
      if (requestedLeafId == null ||
          _toolMaybeSource(chatId, requestedLeafId) == null ||
          !ancestorIds(chatId, requestedLeafId).contains(source.nodeId)) {
        return StoredToolSourceEligibility(false, 'not_on_branch', sourceValidity);
      }
    } on _StoredAncestorDataError catch (error) {
      throw FormatException(error.message);
    }
    return StoredToolSourceEligibility(true, null, sourceValidity);
  }

  TavernToolSourceToken? _toolToken(Row row, String id, String seq, String epoch, String version) {
    final nodeId = _toolText(row, id);
    if (nodeId == null) {
      if (row[seq] != null || row[epoch] != null || row[version] != null) {
        throw const FormatException('Incomplete tool source token.');
      }
      return null;
    }
    return TavernToolSourceToken(
      nodeId: nodeId,
      seq: row[seq] as int,
      sourceEpoch: row[epoch] as int,
      contentVersion: row[version] as int,
    );
  }

  StoredToolOwnership _toolOwnership(Row row) {
    final chatId = _toolText(row, 'chat_id')!;
    return StoredToolOwnership(
      logicalTurnId: _toolText(row, 'id')!,
      chatId: chatId,
      phase: StoredToolPhase.values.byName(row['ownership_phase'] as String),
      expectationRevision: row['expectation_revision'] as int,
      expectedContextAnchor: TavernToolContextAnchor(
        chatId: chatId,
        selectedLeaf: _toolToken(
          row,
          'expected_selected_leaf_id',
          'expected_selected_leaf_seq',
          'expected_selected_leaf_epoch',
          'expected_selected_leaf_version',
        ),
        treeRevision: row['expected_tree_revision'] as int,
      ),
      expectedOperationTarget: _toolToken(
        row,
        'operation_target_node_id',
        'operation_target_seq',
        'operation_target_source_epoch',
        'expected_target_content_version',
      ),
      candidateSource: _toolToken(
        row,
        'candidate_node_id',
        'candidate_seq',
        'candidate_source_epoch',
        'expected_body_version',
      ),
    );
  }

  Row _toolOwnerRow(StoredToolTurnOwner owner, {StoredToolPhase? phase}) {
    if (!identical(owner._store, this)) throw ArgumentError('Tool owner belongs to another store.');
    final row = _toolRequired('tool_turns', owner.logicalTurnId);
    if (_toolText(row, 'chat_id') != owner.chatId || row['operation'] != owner.operation.name) {
      throw StateError('Tool owner identity mismatch.');
    }
    if (row['status'] != 'active') throw StoredToolOwnershipException(owner.logicalTurnId, 'inactive');
    if (phase != null && row['ownership_phase'] != phase.name) {
      throw StoredToolOwnershipException(owner.logicalTurnId, 'wrong_phase');
    }
    return row;
  }

  Row _toolCheck(StoredToolTurnOwner owner, StoredToolPhase phase) {
    final row = _toolOwnerRow(owner, phase: phase);
    final expected = _toolOwnership(row);
    if (!_toolEqual(expected.expectedContextAnchor.toJson(), contextAnchor(owner.chatId).toJson())) {
      throw StoredToolOwnershipException(owner.logicalTurnId, 'context_changed');
    }
    final target = expected.expectedOperationTarget;
    if (target != null && !_toolSameSource(target, _toolMaybeSource(owner.chatId, target.nodeId))) {
      throw StoredToolOwnershipException(owner.logicalTurnId, 'target_changed');
    }
    final candidate = expected.candidateSource;
    if (phase == StoredToolPhase.owned &&
        (candidate == null || !_toolSameSource(candidate, _toolMaybeSource(owner.chatId, candidate.nodeId)))) {
      throw StoredToolOwnershipException(owner.logicalTurnId, 'candidate_changed');
    }
    return row;
  }

  StoredToolOwnership requireToolOwnership(StoredToolTurnOwner owner, {required StoredToolPhase phase}) =>
      _toolOwnership(_toolCheck(owner, phase));

  Map<String, Object?> _toolExpectedFields(TavernToolContextAnchor anchor) => {
    'expected_selected_leaf_id': anchor.selectedLeaf?.nodeId,
    'expected_selected_leaf_seq': anchor.selectedLeaf?.seq,
    'expected_selected_leaf_epoch': anchor.selectedLeaf?.sourceEpoch,
    'expected_selected_leaf_version': anchor.selectedLeaf?.contentVersion,
    'expected_tree_revision': anchor.treeRevision,
  };

  StoredToolOwnership _toolAdvance(
    StoredToolTurnOwner owner,
    Row before, {
    StoredToolPhase? phase,
    bool allowSelectionChange = false,
    TavernToolSourceToken? bindCandidate,
  }) {
    final old = _toolOwnership(before);
    final anchor = contextAnchor(owner.chatId);
    if (!allowSelectionChange &&
        !_toolSameSource(old.expectedContextAnchor.selectedLeaf, anchor.selectedLeaf, body: false)) {
      throw StoredToolOwnershipException(owner.logicalTurnId, 'context_changed');
    }
    final oldTarget = old.expectedOperationTarget;
    final target = oldTarget == null ? null : _toolMaybeSource(owner.chatId, oldTarget.nodeId);
    if (!_toolSameSource(oldTarget, target, body: false)) {
      throw StoredToolOwnershipException(owner.logicalTurnId, 'target_changed');
    }
    final priorCandidate = old.candidateSource;
    final candidate =
        bindCandidate ?? (priorCandidate == null ? null : _toolMaybeSource(owner.chatId, priorCandidate.nodeId));
    if (bindCandidate == null && !_toolSameSource(priorCandidate, candidate, body: false)) {
      throw StoredToolOwnershipException(owner.logicalTurnId, 'candidate_changed');
    }
    final fields = <String, Object?>{
      ..._toolExpectedFields(anchor),
      'ownership_phase': (phase ?? old.phase).name,
      'expected_target_content_version': target?.contentVersion,
      'candidate_node_id': candidate?.nodeId,
      'candidate_seq': candidate?.seq,
      'candidate_source_epoch': candidate?.sourceEpoch,
      'candidate_live_node_id': candidate?.nodeId,
      'expected_body_version': candidate?.contentVersion,
    };
    _db.execute(
      '''UPDATE tool_turns SET ${fields.keys.map((key) => '$key = ?').join(', ')},
      expectation_revision = expectation_revision + 1 WHERE id = ? AND status = 'active' AND expectation_revision = ?''',
      [...fields.values, owner.logicalTurnId, old.expectationRevision],
    );
    if (_db.select('SELECT changes() AS n').single['n'] != 1) {
      throw StoredToolOwnershipException(owner.logicalTurnId, 'inactive');
    }
    _changedChats.add(owner.chatId);
    return _toolOwnership(_toolRequired('tool_turns', owner.logicalTurnId));
  }

  StoredToolCommit<StoredToolTurnOwner> beginToolTurn({
    required Object owner,
    required String logicalTurnId,
    required String chatId,
    required StoredToolOperation operation,
    required String actorCharacterId,
    required String hostCharacterId,
    required String? groupRoundId,
    required String? operationTargetNodeId,
    required TavernToolPolicySnapshot policyScope,
    required Map<String, Object?>? capturedPolicy,
    required void Function(StoredToolCommit<StoredToolTurnOwner>) onCommitted,
  }) {
    _toolIdentity(logicalTurnId, 'logicalTurnId');
    final scope = policyScope.toJson();
    final captured = capturedPolicy == null ? null : _toolCopy(capturedPolicy);
    if (captured != null && !_toolEqual(scope, captured['scope'])) {
      throw ArgumentError('Admission policy scope differs.');
    }
    final policyJson = jsonEncode({
      'version': 1,
      'captureState': captured == null ? 'pending' : 'ready',
      'scope': scope,
      'captured': captured,
    });
    _toolPolicyEnvelope(policyJson);
    return _toolOuter(() {
      final anchor = contextAnchor(chatId);
      if ((operation == StoredToolOperation.send) != (operationTargetNodeId == null)) {
        throw ArgumentError('Operation target does not match the generation kind.');
      }
      final target = operationTargetNodeId == null ? null : sourceToken(chatId, operationTargetNodeId);
      final now = _toolNow();
      _toolInsert('tool_turns', {
        'id': logicalTurnId,
        'chat_id': chatId,
        'operation': operation.name,
        'actor_character_id': actorCharacterId,
        'host_character_id': hostCharacterId,
        'group_round_id': groupRoundId,
        'created_at_ms': now,
        'policy_snapshot_json': policyJson,
        'admission_anchor_json': jsonEncode(anchor.toJson()),
        'status': 'active',
        'summary_json': '{}',
        'reply_commit_adopted': 0,
        'normal_final_adopted': 0,
        'ownership_phase': 'hooks',
        'expectation_revision': 0,
        'operation_target_node_id': target?.nodeId,
        'operation_target_seq': target?.seq,
        'operation_target_source_epoch': target?.sourceEpoch,
        'operation_target_live_node_id': target?.nodeId,
        'admission_target_content_version': target?.contentVersion,
        'expected_target_content_version': target?.contentVersion,
        ..._toolExpectedFields(anchor),
      });
      writeAgentRun(
        StoredAgentRun(
          id: '$logicalTurnId:tool-turn',
          chatId: chatId,
          kind: 'tool.turn',
          at: DateTime.fromMillisecondsSinceEpoch(now, isUtc: true),
          result: {'version': 1, 'logicalTurnId': logicalTurnId},
        ),
      );
      final handle = StoredToolTurnOwner._(this, owner, logicalTurnId, chatId, operation);
      _changedChats.add(chatId);
      return StoredToolCommit(handle, _toolOwnership(_toolRequired('tool_turns', logicalTurnId)));
    }, onCommitted);
  }

  StoredToolCommit<Map<String, Object?>> completeToolTurnPolicy(
    StoredToolTurnOwner owner, {
    required Map<String, Object?> capturedPolicy,
    required void Function(StoredToolCommit<Map<String, Object?>>) onCommitted,
  }) {
    final captured = _toolCopy(capturedPolicy);
    return _toolOuter(() {
      final row = _toolOwnerRow(owner);
      final old = _toolPolicyEnvelope(row['policy_snapshot_json']);
      if (!_toolEqual(old['scope'], captured['scope'])) throw StateError('Admission policy scope changed.');
      if (old['captureState'] == 'ready') {
        if (!_toolEqual(old['captured'], captured)) throw StateError('Admission policy is already complete.');
        return StoredToolCommit(old, _toolOwnership(row));
      }
      if (old['captureState'] != 'pending' ||
          _toolRows('tool_requests', 't.logical_turn_id = ?', [owner.logicalTurnId]).isNotEmpty) {
        throw StateError('Policy completion must precede requests.');
      }
      final next = _toolCopy({'version': 1, 'captureState': 'ready', 'scope': old['scope'], 'captured': captured});
      _toolPolicyEnvelope(jsonEncode(next));
      _toolUpdate('tool_turns', {'policy_snapshot_json': jsonEncode(next)}, 'id = ?', [owner.logicalTurnId]);
      _changedChats.add(owner.chatId);
      return StoredToolCommit(next, _toolOwnership(row));
    }, onCommitted);
  }

  StoredToolCommit<T> preparationTransaction<T>(
    StoredToolTurnOwner owner, {
    required T Function() action,
    required void Function(StoredToolCommit<T>) onCommitted,
  }) => _toolOuter(() {
    _toolSyncAction(action);
    final old = _toolCheck(owner, StoredToolPhase.hooks);
    final value = _toolSyncValue(action());
    return StoredToolCommit(value, _toolAdvance(owner, old));
  }, onCommitted);

  StoredToolPreparation<T> sealToolPreparation<T>(
    StoredToolTurnOwner owner, {
    required T Function(StoredChat chat, StoredNode? operationTarget) capture,
    required void Function(StoredToolPreparation<T>) onCommitted,
    void Function(String)? onTiming,
  }) => _toolOuter(
    () {
      if (capture is Future<dynamic> Function(StoredChat, StoredNode?)) {
        throw ArgumentError('Preparation capture must be synchronous.');
      }
      final old = _toolCheck(owner, StoredToolPhase.hooks);
      onTiming?.call('ownership');
      final savedChat = chat(owner.chatId);
      final targetId = _toolText(old, 'operation_target_node_id');
      final target = targetId == null ? null : node(owner.chatId, targetId);
      onTiming?.call('snapshot');
      final value = _toolSyncValue(capture(savedChat, target));
      onTiming?.call('capture');
      final ownership = _toolAdvance(owner, old, phase: StoredToolPhase.native);
      onTiming?.call('advance');
      return StoredToolPreparation(value: value, chat: savedChat, operationTarget: target, ownership: ownership);
    },
    onCommitted,
    onTiming: onTiming,
  );

  StoredToolCommit<T> commitToolSecretBinding<T>(
    StoredToolTurnOwner owner, {
    required String anchorNodeId,
    required Map<String, Object?> expectedExtra,
    required Map<String, Object?> extra,
    required StoredAgentRun audit,
    required void Function() checkBinding,
    required T prepared,
    required void Function(StoredToolCommit<T>) onCommitted,
  }) {
    _toolSyncAction(checkBinding);
    _toolSyncValue(prepared);
    final expected = _toolCopy(expectedExtra);
    final next = _toolCopy(extra);
    return _toolOuter(() {
      final old = _toolCheck(owner, StoredToolPhase.native);
      checkBinding();
      if (audit.chatId != owner.chatId ||
          audit.nodeId != anchorNodeId ||
          !_toolEqual(rawNodeExtra(owner.chatId, anchorNodeId), expected)) {
        throw StoredToolOwnershipException(owner.logicalTurnId, 'target_changed');
      }
      updateMessage(owner.chatId, anchorNodeId, extra: next);
      writeAgentRun(audit);
      return StoredToolCommit(prepared, _toolAdvance(owner, old));
    }, onCommitted);
  }

  StoredToolCommit<T> commitToolUserAppend<T>(
    StoredToolTurnOwner owner, {
    required String? parentId,
    required String speaker,
    required String text,
    required Map<String, Object?> state,
    required Map<String, Object?> variables,
    required T Function(TavernMessage message, TavernToolSourceToken source) prepare,
    required void Function(StoredToolCommit<T>) onCommitted,
  }) {
    if (prepare is Future<dynamic> Function(TavernMessage, TavernToolSourceToken)) {
      throw ArgumentError('User adoption preparation must be synchronous.');
    }
    final savedState = _toolCopy(state);
    final savedVariables = _toolCopy(variables);
    return _toolOuter(() {
      final old = _toolCheck(owner, StoredToolPhase.native);
      if (owner.operation != StoredToolOperation.send || _toolText(old, 'expected_selected_leaf_id') != parentId) {
        throw StateError('User append is not the admitted send parent.');
      }
      final message = append(
        owner.chatId,
        parentId: parentId,
        role: TavernRole.user,
        speaker: speaker,
        text: text,
        state: savedState,
      );
      updateChat(owner.chatId, variables: savedVariables);
      final value = _toolSyncValue(prepare(message, sourceToken(owner.chatId, message.nodeId)));
      return StoredToolCommit(value, _toolAdvance(owner, old, allowSelectionChange: true));
    }, onCommitted);
  }

  StoredToolCommit<T> bindToolCandidate<T>(
    StoredToolTurnOwner owner, {
    required String? parentId,
    required String speaker,
    required Map<String, Object?> state,
    required Map<String, Object?> variables,
    required Map<String, Object?> extra,
    StoredToolBodyRewrite? firstMessage,
    required T Function(TavernMessage message, TavernToolSourceToken source) prepare,
    required void Function(StoredToolCommit<T>) onCommitted,
  }) {
    if (prepare is Future<dynamic> Function(TavernMessage, TavernToolSourceToken)) {
      throw ArgumentError('Reply adoption preparation must be synchronous.');
    }
    final savedState = _toolCopy(state);
    final savedVariables = _toolCopy(variables);
    final savedExtra = _toolCopy(extra);
    return _toolOuter(() {
      final old = _toolCheck(owner, StoredToolPhase.native);
      final targetId = _toolText(old, 'operation_target_node_id');
      final expectedParent = switch (owner.operation) {
        StoredToolOperation.send => _toolText(old, 'expected_selected_leaf_id'),
        StoredToolOperation.regenerate => node(owner.chatId, targetId!).message.parentId,
        StoredToolOperation.continueReply => targetId,
      };
      if (parentId != expectedParent) throw StateError('Reply parent is not the admitted source branch.');
      if (firstMessage != null) {
        if (!_toolSameSource(firstMessage.source, _toolMaybeSource(owner.chatId, firstMessage.source.nodeId))) {
          throw StoredToolOwnershipException(owner.logicalTurnId, 'target_changed');
        }
        if (!ancestorIds(owner.chatId, parentId).contains(firstMessage.source.nodeId)) {
          throw StateError('First-message rewrite is not on the prepared branch.');
        }
        updateMessage(owner.chatId, firstMessage.source.nodeId, text: firstMessage.text);
      }
      updateChat(owner.chatId, variables: savedVariables);
      final actor = _toolText(old, 'actor_character_id');
      TavernMessage message;
      if (owner.operation == StoredToolOperation.continueReply) {
        selectNode(owner.chatId, targetId!, restoreDescendants: false);
        message = updateMessage(owner.chatId, targetId, extra: savedExtra, speakerCharacterId: actor);
      } else {
        message = append(
          owner.chatId,
          parentId: parentId,
          role: TavernRole.character,
          speaker: speaker,
          speakerCharacterId: actor,
          text: '',
          state: savedState,
          extra: savedExtra,
        );
      }
      final source = sourceToken(owner.chatId, message.nodeId);
      final value = _toolSyncValue(prepare(message, source));
      return StoredToolCommit(
        value,
        _toolAdvance(owner, old, phase: StoredToolPhase.owned, allowSelectionChange: true, bindCandidate: source),
      );
    }, onCommitted);
  }

  StoredToolCommit<T> withOwnedToolTurn<T>(
    StoredToolTurnOwner owner, {
    required T Function() action,
    required void Function(StoredToolCommit<T>) onCommitted,
  }) => _toolOuter(() {
    _toolSyncAction(action);
    final old = _toolCheck(owner, StoredToolPhase.owned);
    final value = _toolSyncValue(action());
    return StoredToolCommit(value, _toolAdvance(owner, old));
  }, onCommitted);

  StoredToolCommit<TavernMessage> writeOwnedStreamingBody(
    StoredToolTurnOwner owner, {
    required String text,
    required String? reasoning,
    required void Function(StoredToolCommit<TavernMessage>) onCommitted,
  }) {
    if (_streamingWriters == 0) throw StateError('A body checkpoint requires an active streaming writer.');
    return _toolOuter(
      () {
        final old = _toolCheck(owner, StoredToolPhase.owned);
        final candidate = _toolText(old, 'candidate_node_id')!;
        _db.execute('UPDATE nodes SET stream_text = ?, stream_reasoning = ? WHERE chat_id = ? AND id = ?', [
          text,
          reasoning,
          owner.chatId,
          candidate,
        ]);
        _changedChats.add(owner.chatId);
        return StoredToolCommit(message(owner.chatId, candidate), _toolAdvance(owner, old));
      },
      onCommitted,
      bodyOnly: true,
    );
  }

  T updateToolPolicySettings<T>(
    String chatId, {
    required Map<String, Object?> Function(Map<String, Object?> currentSettings) merge,
    required T Function(StoredChat updatedChat) prepare,
    required void Function(T) onCommitted,
  }) => _toolOuter(() {
    if (prepare is Future<dynamic> Function(StoredChat)) {
      throw ArgumentError('Policy adoption preparation must be synchronous.');
    }
    final next = _toolCopy(merge(chat(chatId).settings));
    updateChat(chatId, settings: next);
    return _toolSyncValue(prepare(chat(chatId)));
  }, onCommitted);
}

const _schemaV8 = r'''
ALTER TABLE nodes ADD COLUMN source_epoch INTEGER NOT NULL DEFAULT 0
  CHECK(typeof(source_epoch) = 'integer' AND source_epoch >= 0);
ALTER TABLE nodes ADD COLUMN content_version INTEGER NOT NULL DEFAULT 1
  CHECK(typeof(content_version) = 'integer' AND content_version > 0);

ALTER TABLE memories RENAME TO memories_schema7;
CREATE TABLE memories (
  id TEXT PRIMARY KEY NOT NULL,
  chat_id TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  entry_json TEXT NOT NULL,
  origin TEXT NOT NULL CHECK(origin IN ('legacy', 'remember')),
  origin_proposal_id TEXT UNIQUE,
  origin_logical_turn_id TEXT,
  origin_receipt_id TEXT,
  source_node_id TEXT,
  source_seq INTEGER,
  source_epoch INTEGER,
  source_content_version INTEGER,
  source_live_node_id TEXT REFERENCES nodes(id) ON DELETE SET NULL,
  source_validity TEXT,
  invalidated_reason TEXT,
  CHECK(source_live_node_id IS NULL OR source_live_node_id = source_node_id),
  CHECK((origin = 'legacy' AND origin_proposal_id IS NULL AND origin_logical_turn_id IS NULL
      AND origin_receipt_id IS NULL AND source_node_id IS NULL AND source_seq IS NULL
      AND source_epoch IS NULL AND source_content_version IS NULL AND source_live_node_id IS NULL
      AND source_validity IS NULL AND invalidated_reason IS NULL)
    OR (origin = 'remember' AND origin_proposal_id IS NOT NULL AND origin_logical_turn_id IS NOT NULL
      AND origin_receipt_id IS NOT NULL AND source_node_id IS NOT NULL
      AND typeof(source_seq) = 'integer'
      AND typeof(source_epoch) = 'integer' AND source_epoch >= 0
      AND typeof(source_content_version) = 'integer' AND source_content_version > 0
      AND source_validity IS NOT NULL AND source_validity IN ('bound', 'invalidated', 'orphaned')))
);
INSERT INTO memories(rowid, id, chat_id, entry_json, origin)
  SELECT rowid, id, chat_id, entry_json, 'legacy' FROM memories_schema7;
DROP TABLE memories_schema7;
CREATE INDEX memories_chat_origin ON memories(chat_id, origin);
CREATE INDEX memories_source ON memories(source_node_id, source_seq) WHERE origin = 'remember';

CREATE TABLE tool_turns (
  id TEXT PRIMARY KEY NOT NULL,
  chat_id TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  operation TEXT NOT NULL CHECK(operation IN ('send', 'regenerate', 'continueReply')),
  actor_character_id TEXT NOT NULL,
  host_character_id TEXT NOT NULL,
  group_round_id TEXT,
  created_at_ms INTEGER NOT NULL CHECK(typeof(created_at_ms) = 'integer'),
  policy_snapshot_json TEXT NOT NULL,
  admission_anchor_json TEXT NOT NULL,
  status TEXT NOT NULL CHECK(status IN ('active', 'completed', 'failed', 'interrupted')),
  outcome TEXT,
  summary_json TEXT NOT NULL,
  finished_at_ms INTEGER CHECK(finished_at_ms IS NULL OR typeof(finished_at_ms) = 'integer'),
  reply_commit_adopted INTEGER NOT NULL CHECK(reply_commit_adopted IN (0, 1)),
  normal_final_adopted INTEGER NOT NULL CHECK(normal_final_adopted IN (0, 1) AND normal_final_adopted <= reply_commit_adopted),
  ownership_phase TEXT NOT NULL CHECK(ownership_phase IN ('hooks', 'native', 'owned', 'terminal')),
  expectation_revision INTEGER NOT NULL CHECK(typeof(expectation_revision) = 'integer' AND expectation_revision >= 0),
  operation_target_node_id TEXT,
  operation_target_seq INTEGER,
  operation_target_source_epoch INTEGER,
  operation_target_live_node_id TEXT REFERENCES nodes(id) ON DELETE SET NULL,
  admission_target_content_version INTEGER,
  expected_target_content_version INTEGER,
  expected_selected_leaf_id TEXT,
  expected_selected_leaf_seq INTEGER,
  expected_selected_leaf_epoch INTEGER,
  expected_selected_leaf_version INTEGER,
  expected_tree_revision INTEGER NOT NULL CHECK(typeof(expected_tree_revision) = 'integer' AND expected_tree_revision >= 0),
  candidate_node_id TEXT,
  candidate_seq INTEGER,
  candidate_source_epoch INTEGER,
  candidate_live_node_id TEXT REFERENCES nodes(id) ON DELETE SET NULL,
  expected_body_version INTEGER,
  UNIQUE(chat_id, id),
  CHECK((status = 'active' AND ownership_phase IN ('hooks', 'native', 'owned'))
    OR (status != 'active' AND ownership_phase = 'terminal')),
  CHECK(operation_target_live_node_id IS NULL OR operation_target_live_node_id = operation_target_node_id),
  CHECK(candidate_live_node_id IS NULL OR candidate_live_node_id = candidate_node_id),
  CHECK((operation = 'send' AND operation_target_node_id IS NULL AND operation_target_seq IS NULL
      AND operation_target_source_epoch IS NULL AND operation_target_live_node_id IS NULL
      AND admission_target_content_version IS NULL AND expected_target_content_version IS NULL)
    OR (operation != 'send' AND operation_target_node_id IS NOT NULL
      AND typeof(operation_target_seq) = 'integer'
      AND typeof(operation_target_source_epoch) = 'integer' AND operation_target_source_epoch >= 0
      AND typeof(admission_target_content_version) = 'integer' AND admission_target_content_version > 0
      AND typeof(expected_target_content_version) = 'integer' AND expected_target_content_version > 0)),
  CHECK((expected_selected_leaf_id IS NULL AND expected_selected_leaf_seq IS NULL
      AND expected_selected_leaf_epoch IS NULL AND expected_selected_leaf_version IS NULL)
    OR (expected_selected_leaf_id IS NOT NULL AND typeof(expected_selected_leaf_seq) = 'integer'
      AND typeof(expected_selected_leaf_epoch) = 'integer'
      AND expected_selected_leaf_epoch >= 0 AND typeof(expected_selected_leaf_version) = 'integer'
      AND expected_selected_leaf_version > 0)),
  CHECK((candidate_node_id IS NULL AND candidate_seq IS NULL AND candidate_source_epoch IS NULL
      AND candidate_live_node_id IS NULL AND expected_body_version IS NULL)
    OR (candidate_node_id IS NOT NULL AND typeof(candidate_seq) = 'integer'
      AND typeof(candidate_source_epoch) = 'integer' AND candidate_source_epoch >= 0
      AND typeof(expected_body_version) = 'integer' AND expected_body_version > 0)),
  CHECK(ownership_phase = 'terminal' OR (ownership_phase IN ('hooks', 'native') AND candidate_node_id IS NULL)
    OR (ownership_phase = 'owned' AND candidate_node_id IS NOT NULL))
);
CREATE UNIQUE INDEX tool_turns_one_active_chat ON tool_turns(chat_id) WHERE status = 'active';
CREATE INDEX tool_turns_chat_created ON tool_turns(chat_id, created_at_ms);

CREATE TABLE tool_requests (
  id TEXT PRIMARY KEY NOT NULL,
  chat_id TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  logical_turn_id TEXT NOT NULL REFERENCES tool_turns(id) ON DELETE CASCADE,
  request_index INTEGER NOT NULL CHECK(typeof(request_index) = 'integer' AND request_index BETWEEN 1 AND 4),
  created_at_ms INTEGER NOT NULL CHECK(typeof(created_at_ms) = 'integer'),
  offered_tools_json TEXT NOT NULL,
  wire_authorization_json TEXT NOT NULL,
  response_snapshot_json TEXT,
  batch_diagnostics_json TEXT NOT NULL,
  status TEXT NOT NULL CHECK(status IN ('registered', 'in_flight', 'response_complete', 'failed', 'interrupted')),
  provider_finish_reason TEXT,
  response_finished_at_ms INTEGER,
  response_complete INTEGER NOT NULL CHECK(response_complete IN (0, 1)),
  error_json TEXT,
  send_attempts_json TEXT NOT NULL,
  usage_json TEXT NOT NULL,
  UNIQUE(logical_turn_id, request_index), UNIQUE(chat_id, id)
);

CREATE TABLE tool_receipts (
  id TEXT PRIMARY KEY NOT NULL,
  chat_id TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  origin TEXT NOT NULL CHECK(origin IN ('model', 'manual')),
  request_id TEXT REFERENCES tool_requests(id) ON DELETE CASCADE,
  tool_index INTEGER,
  raw_call_id TEXT,
  action_id TEXT,
  tool_name TEXT NOT NULL CHECK(length(tool_name) > 0),
  raw_arguments TEXT,
  input_json TEXT NOT NULL,
  validated_parameters_json TEXT,
  policy_snapshot_json TEXT,
  action_anchor_json TEXT,
  status TEXT NOT NULL CHECK(status IN ('prepared', 'unresolved', 'staged', 'pending_confirmation',
    'rejected', 'cancelled_before_execution', 'discarded', 'completed_no_change', 'committed')),
  committed INTEGER,
  result_json TEXT,
  wire_result_json TEXT,
  proposal_id TEXT REFERENCES memory_proposals(id) DEFERRABLE INITIALLY DEFERRED,
  decision_origin TEXT,
  decision_id TEXT,
  created_at_ms INTEGER NOT NULL CHECK(typeof(created_at_ms) = 'integer'),
  updated_at_ms INTEGER NOT NULL CHECK(typeof(updated_at_ms) = 'integer'),
  result_adopted_at_ms INTEGER,
  UNIQUE(request_id, tool_index), UNIQUE(request_id, raw_call_id), UNIQUE(chat_id, action_id),
  FOREIGN KEY(decision_origin, decision_id) REFERENCES memory_decisions(decision_origin, decision_id)
    DEFERRABLE INITIALLY DEFERRED,
  CHECK((origin = 'model' AND request_id IS NOT NULL AND typeof(tool_index) = 'integer' AND tool_index >= 0
      AND raw_call_id IS NOT NULL AND length(raw_call_id) > 0 AND action_id IS NULL)
    OR (origin = 'manual' AND action_id IS NOT NULL AND length(action_id) > 0 AND tool_name = 'roll'
      AND request_id IS NULL AND tool_index IS NULL AND raw_call_id IS NULL)),
  CHECK((status IN ('prepared', 'unresolved') AND committed IS NULL)
    OR (status = 'committed' AND committed IS NOT NULL AND committed = 1)
    OR (status IN ('staged', 'pending_confirmation', 'rejected', 'cancelled_before_execution', 'discarded',
      'completed_no_change') AND committed IS NOT NULL AND committed = 0)),
  CHECK((decision_origin IS NULL AND decision_id IS NULL)
    OR (decision_origin IS NOT NULL AND decision_origin IN ('user', 'policy_auto') AND decision_id IS NOT NULL))
);
CREATE INDEX tool_receipts_chat_created ON tool_receipts(chat_id, created_at_ms);

CREATE TABLE memory_proposals (
  id TEXT PRIMARY KEY NOT NULL,
  chat_id TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  logical_turn_id TEXT NOT NULL REFERENCES tool_turns(id) ON DELETE CASCADE,
  receipt_id TEXT NOT NULL UNIQUE REFERENCES tool_receipts(id) ON DELETE CASCADE,
  mode TEXT NOT NULL CHECK(mode IN ('ask', 'auto')),
  text TEXT NOT NULL,
  keywords_json TEXT NOT NULL,
  proposal_version INTEGER NOT NULL CHECK(typeof(proposal_version) = 'integer' AND proposal_version > 0),
  status TEXT NOT NULL CHECK(status IN ('staged', 'pending_confirmation', 'accepted', 'rejected', 'inactive_terminal')),
  source_validity TEXT NOT NULL CHECK(source_validity IN ('candidate', 'bound', 'invalidated', 'orphaned')),
  terminal_reason TEXT,
  created_at_ms INTEGER NOT NULL CHECK(typeof(created_at_ms) = 'integer'),
  updated_at_ms INTEGER NOT NULL CHECK(typeof(updated_at_ms) = 'integer'),
  candidate_node_id TEXT NOT NULL,
  candidate_seq INTEGER NOT NULL CHECK(typeof(candidate_seq) = 'integer'),
  candidate_source_epoch INTEGER NOT NULL CHECK(typeof(candidate_source_epoch) = 'integer' AND candidate_source_epoch >= 0),
  source_node_id TEXT,
  source_seq INTEGER,
  source_epoch INTEGER,
  source_content_version INTEGER,
  source_live_node_id TEXT REFERENCES nodes(id) ON DELETE SET NULL,
  accepted_memory_id TEXT,
  memory_live_id TEXT REFERENCES memories(id) ON DELETE SET NULL,
  last_decision_origin TEXT,
  last_decision_id TEXT,
  FOREIGN KEY(last_decision_origin, last_decision_id) REFERENCES memory_decisions(decision_origin, decision_id)
    DEFERRABLE INITIALLY DEFERRED,
  CHECK(source_live_node_id IS NULL OR source_live_node_id = source_node_id),
  CHECK(memory_live_id IS NULL OR (accepted_memory_id IS NOT NULL AND memory_live_id = accepted_memory_id)),
  CHECK((status = 'accepted' AND accepted_memory_id IS NOT NULL)
    OR (status != 'accepted' AND accepted_memory_id IS NULL AND memory_live_id IS NULL)),
  CHECK((source_node_id IS NULL AND source_seq IS NULL AND source_epoch IS NULL
      AND source_content_version IS NULL AND source_live_node_id IS NULL)
    OR (source_node_id IS NOT NULL AND typeof(source_seq) = 'integer'
      AND typeof(source_epoch) = 'integer' AND source_epoch >= 0
      AND typeof(source_content_version) = 'integer' AND source_content_version > 0)),
  CHECK((status IN ('staged', 'inactive_terminal') AND source_node_id IS NULL
      AND source_validity IN ('candidate', 'orphaned'))
    OR (status IN ('pending_confirmation', 'accepted', 'rejected') AND source_node_id IS NOT NULL
      AND source_validity IN ('bound', 'invalidated', 'orphaned'))),
  CHECK((last_decision_origin IS NULL AND last_decision_id IS NULL)
    OR (last_decision_origin IS NOT NULL AND last_decision_origin IN ('user', 'policy_auto') AND last_decision_id IS NOT NULL))
);
CREATE INDEX memory_proposals_turn ON memory_proposals(logical_turn_id);
CREATE INDEX memory_proposals_source ON memory_proposals(source_node_id, source_seq);
CREATE INDEX memory_proposals_candidate ON memory_proposals(candidate_node_id, candidate_seq) WHERE source_node_id IS NULL;

CREATE TABLE memory_decisions (
  decision_origin TEXT NOT NULL CHECK(decision_origin IN ('user', 'policy_auto')),
  decision_id TEXT NOT NULL CHECK(length(decision_id) > 0),
  chat_id TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  proposal_id TEXT NOT NULL REFERENCES memory_proposals(id) ON DELETE CASCADE,
  decision TEXT NOT NULL CHECK(decision IN ('accept', 'reject')),
  expected_version INTEGER,
  expected_context_anchor_json TEXT,
  parameters_json TEXT NOT NULL,
  outcome TEXT NOT NULL CHECK(outcome IN ('accepted', 'rejected', 'not_applied')),
  resulting_proposal_version INTEGER NOT NULL CHECK(typeof(resulting_proposal_version) = 'integer' AND resulting_proposal_version > 0),
  memory_id TEXT,
  receipt_json TEXT NOT NULL,
  created_at_ms INTEGER NOT NULL CHECK(typeof(created_at_ms) = 'integer'),
  PRIMARY KEY(decision_origin, decision_id),
  CHECK((decision_origin = 'user' AND typeof(expected_version) = 'integer' AND expected_version > 0
      AND expected_context_anchor_json IS NOT NULL)
    OR (decision_origin = 'policy_auto' AND expected_version IS NULL AND expected_context_anchor_json IS NULL)),
  CHECK((outcome = 'accepted' AND memory_id IS NOT NULL) OR (outcome != 'accepted' AND memory_id IS NULL))
);
CREATE INDEX memory_decisions_proposal ON memory_decisions(proposal_id);

CREATE TRIGGER nodes_tool_body_version AFTER UPDATE OF text, reasoning, stream_text, stream_reasoning ON nodes BEGIN
  UPDATE nodes SET content_version = OLD.content_version + 1 WHERE seq = NEW.seq;
  UPDATE memory_proposals SET source_validity = 'invalidated', proposal_version = proposal_version + 1,
    updated_at_ms = CAST(strftime('%s', 'now') AS INTEGER) * 1000
    WHERE NEW.deleted_by IS NULL AND chat_id = NEW.chat_id AND source_node_id = NEW.id
      AND source_seq = NEW.seq AND source_validity = 'bound';
  UPDATE memories SET source_validity = 'invalidated', invalidated_reason = 'body_changed'
    WHERE NEW.deleted_by IS NULL AND chat_id = NEW.chat_id AND origin = 'remember'
      AND source_node_id = NEW.id AND source_seq = NEW.seq AND source_validity = 'bound';
END;

CREATE TRIGGER nodes_tool_soft_delete AFTER UPDATE OF deleted_by ON nodes
  WHEN OLD.deleted_by IS NULL AND NEW.deleted_by IS NOT NULL BEGIN
  UPDATE nodes SET source_epoch = OLD.source_epoch + 1 WHERE seq = NEW.seq;
  UPDATE memory_proposals SET source_validity = 'orphaned', proposal_version = proposal_version + 1,
    updated_at_ms = CAST(strftime('%s', 'now') AS INTEGER) * 1000
    WHERE chat_id = OLD.chat_id AND source_validity != 'orphaned' AND
      ((source_node_id = OLD.id AND source_seq = OLD.seq)
       OR (source_node_id IS NULL AND candidate_node_id = OLD.id AND candidate_seq = OLD.seq));
  UPDATE memories SET source_validity = 'orphaned', invalidated_reason = 'source_deleted'
    WHERE chat_id = OLD.chat_id AND origin = 'remember' AND source_node_id = OLD.id AND source_seq = OLD.seq
      AND source_validity != 'orphaned';
END;

CREATE TRIGGER nodes_tool_physical_delete AFTER DELETE ON nodes BEGIN
  UPDATE memory_proposals SET source_validity = 'orphaned', proposal_version = proposal_version + 1,
    updated_at_ms = CAST(strftime('%s', 'now') AS INTEGER) * 1000
    WHERE chat_id = OLD.chat_id AND source_validity != 'orphaned' AND
      ((source_node_id = OLD.id AND source_seq = OLD.seq)
       OR (source_node_id IS NULL AND candidate_node_id = OLD.id AND candidate_seq = OLD.seq));
  UPDATE memories SET source_validity = 'orphaned', invalidated_reason = 'source_deleted'
    WHERE chat_id = OLD.chat_id AND origin = 'remember' AND source_node_id = OLD.id AND source_seq = OLD.seq
      AND source_validity != 'orphaned';
END;
''';
