import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';

import 'companion_light.dart';
import 'companion_memory.dart';

typedef CompanionAgentMemoryCommit = void Function({
  required CompanionMemoryOwner memory,
  required String sourceId,
  required int beforeRevision,
  required int revision,
});

/// The original SQLite source owns this turn and its durable three-card budget.
/// A model HTTP continuation does not create another turn or another allowance.
class CompanionAgentMemoryTools {
  CompanionAgentMemoryTools({
    required this.memory,
    required MemoryRow source,
    required this._isCurrent,
    required this._onCommitted,
    required this.forgottenNotice,
  }) : sourceId = source['id']! as String {
    final turn = memory.store.beginAgentTurn(
      messageId: sourceId,
      expectedSourceRev: source['source_rev']! as int,
      shownCardRevisions: const {},
    );
    turnId = turn['id']! as String;
    _knownControlRevision = turn['control_revision']! as int;
    _closed = turn['closed'] != 0;
  }

  final CompanionMemoryOwner memory;
  final String sourceId, forgottenNotice;
  final bool Function() _isCurrent;
  final CompanionAgentMemoryCommit _onCommitted;
  late final String turnId;
  late int _knownControlRevision;
  bool _closed = false;

  bool get isCurrent => !_closed && _isCurrent() && memory.store.archive['control_revision'] == _knownControlRevision;

  /// Wire this to the Agent's actual onSelected callback, including each new
  /// selection after one of this turn's own control commits.
  void grantSelection(MemorySelection selection) {
    if (!isCurrent || selection.controlRevision != _knownControlRevision) return;
    final selected = selection.ids.toSet();
    final revisions = <String, int>{
      for (final card in memory.store.cards())
        if (selected.contains(card['id'])) card['id']! as String: card['row_rev']! as int,
    };
    if (revisions.length != selected.length) {
      throw const DshRemoteException('companion/conflict', 'Selected memory changed', {'status': 409});
    }
    memory.store.grantAgentCards(turnId: turnId, cardRevisions: revisions);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    memory.store.closeAgentTurn(turnId);
  }

  List<({CompanionAgentTool definition, Future<CompanionAgentToolResult> Function(CompanionAgentToolCall) execute})>
  get bindings => [for (final definition in definitions) (definition: definition, execute: execute)];

  Future<CompanionAgentToolResult> execute(CompanionAgentToolCall call) =>
      Future<CompanionAgentToolResult>.value(_execute(call));

  CompanionAgentToolResult _execute(CompanionAgentToolCall call) {
    if (!isCurrent) return _failure('turn_not_current');
    final CompanionAgentMemoryResult receipt;
    try {
      // No await separates the live check, transaction, acknowledgement and
      // changed notification. An external control never becomes our own commit.
      receipt = memory.store.applyAgentMemoryTool(
        turnId: turnId,
        callId: call.id,
        toolName: call.name,
        input: call.input,
      );
    } on DshRemoteException catch (error) {
      return _failure(error.code);
    } on ArgumentError {
      return _failure('invalid_arguments');
    }
    if (!receipt.applied) return _failure(receipt.code ?? 'not_applied');
    if (!receipt.replayed && receipt.controlRevision != receipt.beforeControlRevision) {
      try {
        _onCommitted(
          memory: memory,
          sourceId: sourceId,
          beforeRevision: receipt.beforeControlRevision,
          revision: receipt.controlRevision,
        );
        _knownControlRevision = receipt.controlRevision;
      } finally {
        // The commit is real even if a caller rejects its presentation context.
        memory.changed();
      }
    }
    final result = <String, Object?>{
      'applied': true,
      'replayed': receipt.replayed,
      'changedCardIds': receipt.changedCardIds,
      'currentCardRevisions': receipt.currentCardRevisions,
      'targetId': receipt.targetId,
    };
    if (call.name == 'recall') {
      final selection = memory.select(call.input['query']! as String);
      grantSelection(selection);
      result['selection'] = jsonDecode(selection.block);
    }
    return CompanionAgentToolResult(
      content: jsonEncode(result),
      notice: call.name == 'forget' ? forgottenNotice : null,
    );
  }

  static CompanionAgentToolResult _failure(String code) => CompanionAgentToolResult(
    // The provider does not interpret is_error. The body must say it failed.
    content: jsonEncode({
      'applied': false,
      'code': code,
      'message': 'This request was not applied. Continue the conversation.',
    }),
    isError: true,
  );

  static const _card = {
    'type': 'string',
    'description': 'An exact card ID supplied in this turn or a successful recall.',
  };
  static const _text = {'type': 'string', 'minLength': 1};
  static const definitions = <CompanionAgentTool>[
    CompanionAgentTool(
      name: 'remember',
      description: 'Save a fact, preference or episode the user wants remembered. Supply concise retrieval keywords; without them only exact-text retrieval is available. At most three distinct cards may change in one user turn.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'text': _text,
          'kind': {
            'type': 'string',
            'enum': ['fact', 'preference', 'episode'],
          },
          'keywords': {'type': 'array', 'items': _text},
        },
        'required': ['text'],
        'additionalProperties': false,
      },
    ),
    CompanionAgentTool(
      name: 'forget',
      description: 'Forget a supplied card and its actual dependent cards. Original chat stays. Tell the user when deletion succeeds.',
      inputSchema: {
        'type': 'object',
        'properties': {'card': _card},
        'required': ['card'],
        'additionalProperties': false,
      },
    ),
    CompanionAgentTool(
      name: 'revise',
      description: 'Replace a supplied card with the new nonempty wording and retrieval keywords. Use the same card ID for a later correction in this turn.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'card': _card,
          'text': _text,
          'keywords': {'type': 'array', 'items': _text},
        },
        'required': ['card', 'text'],
        'additionalProperties': false,
      },
    ),
    CompanionAgentTool(
      name: 'quiet',
      description: 'Mention the topic of this supplied card less, or never proactively. All affected topic cards must be supplied and fit the turn budget.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'card': _card,
          'mode': {
            'type': 'string',
            'enum': ['less', 'never'],
          },
        },
        'required': ['card', 'mode'],
        'additionalProperties': false,
      },
    ),
    CompanionAgentTool(
      name: 'cancel',
      description: 'Mark a supplied memory plan cancelled and retire its followup. This does not cancel a reminder or a computer task.',
      inputSchema: {
        'type': 'object',
        'properties': {'card': _card},
        'required': ['card'],
        'additionalProperties': false,
      },
    ),
    CompanionAgentTool(
      name: 'postpone',
      description: 'Mark a supplied memory plan postponed with no new time yet and retire its current followup. Use ask_later instead when a new time is known.',
      inputSchema: {
        'type': 'object',
        'properties': {'card': _card},
        'required': ['card'],
        'additionalProperties': false,
      },
    ),
    CompanionAgentTool(
      name: 'ask_later',
      description: 'Arrange a real followup opportunity about a supplied card at the chosen UTC epoch millisecond time. Existing presentation limits still apply.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'card': _card,
          'whenMs': {'type': 'integer', 'minimum': 0},
        },
        'required': ['card', 'whenMs'],
        'additionalProperties': false,
      },
    ),
    CompanionAgentTool(
      name: 'recall',
      description: 'Search the current eligible memory cards using the existing bounded selector. Only returned IDs become available to this turn.',
      inputSchema: {
        'type': 'object',
        'properties': {'query': _text},
        'required': ['query'],
        'additionalProperties': false,
      },
    ),
  ];
}
