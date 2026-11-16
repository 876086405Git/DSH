part of 'engine.dart';

/// Rejected preparations retain this same session's budget and receipts on
/// the turn. Only an accepted preparation can reach local frame adoption.
final class _AuthoringSecretPreparation {
  const _AuthoringSecretPreparation({
    required this.proposal,
    required this.anchor,
    required this.plan,
    required this.prepared,
    required this.capability,
    required this.protection,
    required this.saved,
    required this.rawExtra,
  });
  final StoredAgentRun proposal;
  final String anchor;
  final state_core.StateSecretPlan plan;
  final state_core.StateSecretPrepared prepared;
  final state_core.SecretCapability capability;
  final _SecretProtection protection;
  final Map<String, Object?> saved, rawExtra;
}

/// Not an agent run or a serializable audit. Its authority comes from this
/// task's private scope and publication, never from a receipt-shaped string.
final class _PreviewSecretProof {
  const _PreviewSecretProof(
    this.scope,
    this.chatId,
    this.receiptId,
    this.beforeFingerprint,
    this.afterFingerprint,
    this.bindings,
  );
  final Object scope;
  final String chatId, receiptId, beforeFingerprint, afterFingerprint;
  final List<Map<String, Object?>> bindings;

  bool matches(Object owner, String? originChatId, Map<String, Object?> binding) =>
      identical(scope, owner) &&
      chatId == originChatId &&
      binding['bindReceiptId'] == receiptId &&
      binding['beforeStateFingerprint'] == beforeFingerprint &&
      binding['afterStateFingerprint'] == afterFingerprint &&
      bindings.any((row) => _stateJsonEqual(row, binding));
}

final class _PreviewSecretFrame {
  const _PreviewSecretFrame(this.candidate, this.history, this.proof, this.changes);
  final _SecretBindingCandidate candidate;
  final List<StoredNode> history;
  final _PreviewSecretProof proof;
  final List<Map<String, Object?>> changes;
}

typedef _AuthoringSecretDefinitionRead = ({state_core.SecretDefinition? definition, Object? error, StackTrace? stack});

/// Real rows were read from the origin chat before the seal. Local proof is
/// visible only through the single published frame. Neither path has a live
/// fallback, and the native verifier never takes this private reader.
final class _AuthoringSecretProofs {
  _AuthoringSecretProofs({
    required this.captureId,
    required this.chatId,
    required Map<String, StoredAgentRun> captured,
    required Map<String, _AuthoringSecretDefinitionRead> capturedDefinitions,
    required Set<String> reservedIds,
  }) : _captured = captured,
       _capturedDefinitions = capturedDefinitions,
       _reservedIds = reservedIds;
  final String captureId;
  final String? chatId;
  final Object _scope = Object();
  final Map<String, StoredAgentRun> _captured;
  final Map<String, _AuthoringSecretDefinitionRead> _capturedDefinitions;
  final Set<String> _reservedIds;
  _PreviewSecretFrame? _frame;
  _PreviewSecretFrame? get frame => _frame;

  bool matches(Map<String, Object?> binding) {
    final local = _frame?.proof;
    if (local != null && binding['bindReceiptId'] == local.receiptId) {
      return local.matches(_scope, chatId, binding);
    }
    return _secretProofMatches(_captured[binding['bindReceiptId']], binding);
  }

  state_core.SecretDefinition? boundDefinition(Map<String, Object?> binding) {
    if (!matches(binding)) {
      return null;
    }
    // Local frames authorize only their actual published bindings. They are
    // never substituted for a persisted proposal or an immutable config row.
    final receipt = _captured[binding['bindReceiptId']];
    final proposalId = receipt?.result['proposalRunId'];
    if (proposalId is! String || proposalId != binding['proposalRunId']) {
      return null;
    }
    final configId = _secretBindingConfigId(binding, _captured[proposalId]);
    if (configId == null) {
      return null;
    }
    final read = _capturedDefinitions[configId];
    if (read == null) {
      return null;
    }
    if (read.error case final error?) {
      Error.throwWithStackTrace(error, read.stack!);
    }
    return read.definition;
  }

  void adopt(_Turn turn, _AuthoringSecretPreparation preparation, List<StoredNode> history) {
    if (_frame != null || !preparation.prepared.accepted) {
      throw StateError('A preview adopts its accepted secret batch only once.');
    }
    // No await or callback occurs between the frozen-fact checks, prepare,
    // and publication. Build everything first; failure ends this preview,
    // without another prepare or a replacement StateSession.
    final count = preparation.plan.facts.length;
    var serial = 0;
    late String receiptId;
    do {
      receiptId = '$captureId:local-bind:${serial++}';
    } while (_reservedIds.contains(receiptId) ||
        List.generate(count, (index) => '$receiptId:$index').any(_reservedIds.contains));
    final candidate = _buildSecretBindingCandidate(
      turn,
      proposal: preparation.proposal,
      anchor: preparation.anchor,
      invocation: turn.stateInvocationId!,
      receiptId: receiptId,
      plan: preparation.plan,
      prepared: preparation.prepared,
      capability: preparation.capability,
      protection: preparation.protection,
      saved: preparation.saved,
      rawExtra: preparation.rawExtra,
      target: turn.originalTarget,
    );
    final index = history.indexWhere((node) => node.message.nodeId == preparation.anchor);
    if (index < 0) {
      throw StateError('The captured secret anchor is not on the local path.');
    }
    final anchor = history[index];
    // A pending stored node may project away its old inspection. Preserve
    // that projection for history; the exact raw before-image and restored
    // continuation target use preparation.rawExtra through the candidate.
    final historyExtra = _stateNodeExtra(anchor.extra, candidate.persistent, {
      'secretBinding': _map(candidate.extra['dshgo'])['secretBinding'],
    });
    final nextHistory = List<StoredNode>.of(history);
    nextHistory[index] = StoredNode(
      message: anchor.message,
      depth: anchor.depth,
      selectedChildId: anchor.selectedChildId,
      original: anchor.original,
      extra: historyExtra,
    );
    final proof = _PreviewSecretProof(
      _scope,
      chatId!,
      receiptId,
      preparation.plan.baselineFingerprint,
      preparation.prepared.valueFingerprint,
      candidate.bindings,
    );
    final next = _PreviewSecretFrame(candidate, nextHistory, proof, preparation.prepared.changes);
    _frame = next;
    turn.state = candidate.generation;
    turn.originalTarget = candidate.restored;
  }

  Map<String, Object?> trace(_Turn turn, String? parent) {
    final adopted = _frame;
    if (adopted == null && !_hasSecretTrace(turn)) {
      return const {};
    }
    return {
      'scope': 'preview', 'captureId': captureId,
      'origin': {'kind': chatId == null ? 'sample' : 'chat', 'chatId': chatId, 'nodeId': parent},
      'adoptedLocally': adopted != null,
      if (adopted != null) ...{
        'beforeStateFingerprint': adopted.proof.beforeFingerprint,
        'afterStateFingerprint': adopted.proof.afterFingerprint,
        'changes': [for (final change in adopted.changes) _copy(change)],
      },
      'offered': [for (final release in turn.secretOffered.values) _copy(release)],
      'included': turn.secretIncluded.toList(),
      // No authoring preview makes a client call. This is deliberately a
      // bool, not the native trace's list of attempted release source IDs.
      'attempted': false,
    };
  }
}
