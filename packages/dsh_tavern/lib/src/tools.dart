import 'dart:convert';

/// A user's explicit choice for an already persisted memory proposal.
enum TavernMemoryDecision { accept, reject }

/// Stable failures of the six tool APIs. A cancelled pre-intent action has no
/// execution identity; an existing intent is instead described by its receipt.
enum TavernToolErrorCode {
  invalidArgument,
  busy,
  policyDisabled,
  unsupportedCapability,
  actionConflict,
  decisionConflict,
  notFound,
  anchorChanged,
  storageFailure,
  cancelled,
}

/// [committed] describes adoption of this API operation, including a durable
/// not-applied decision. It is distinct from a tool receipt's business effect.
/// Null means adoption could not be established, never an assumed rollback.
class TavernToolException implements Exception {
  const TavernToolException({
    required this.code,
    required this.operation,
    required this.message,
    required this.committed,
    this.fieldPath,
    this.chatId,
    this.logicalTurnId,
    this.executionId,
    this.proposalId,
    this.decisionRef,
  });
  final TavernToolErrorCode code;
  final String operation;
  final String message;
  final bool? committed;
  final String? fieldPath;
  final String? chatId;
  final String? logicalTurnId;
  final String? executionId;
  final String? proposalId;
  final TavernMemoryDecisionRef? decisionRef;
  @override
  String toString() => 'TavernToolException(${code.name}, $operation): $message';
}

/// A physical message incarnation and its exact observed body revision.
/// Identity strings are retained verbatim, including whitespace and BOMs.
class TavernToolSourceToken extends _ToolView {
  factory TavernToolSourceToken({
    required String nodeId,
    required int seq,
    required int sourceEpoch,
    required int contentVersion,
  }) => TavernToolSourceToken.fromJson({
    'nodeId': nodeId,
    'seq': seq,
    'sourceEpoch': sourceEpoch,
    'contentVersion': contentVersion,
  });
  factory TavernToolSourceToken.fromJson(Map<String, Object?> json) => TavernToolSourceToken._(json);
  TavernToolSourceToken._(super.json) {
    _stringsRequired(const ['nodeId']);
    _integer('seq');
    _integer('sourceEpoch', minimum: 0);
    _integer('contentVersion', minimum: 1);
  }
  String get nodeId => _string('nodeId');
  int get seq => _integer('seq');
  int get sourceEpoch => _integer('sourceEpoch');
  int get contentVersion => _integer('contentVersion');
}

/// The selected path and tree revision at one observation. A null selected
/// leaf means an actually empty path, not an unspecified comparison.
class TavernToolContextAnchor extends _ToolView {
  factory TavernToolContextAnchor({
    required String chatId,
    required TavernToolSourceToken? selectedLeaf,
    required int treeRevision,
  }) => TavernToolContextAnchor.fromJson({
    'chatId': chatId,
    'selectedLeaf': selectedLeaf?.toJson(),
    'treeRevision': treeRevision,
  });
  factory TavernToolContextAnchor.fromJson(Map<String, Object?> json) => TavernToolContextAnchor._(json);
  TavernToolContextAnchor._(super.json) {
    _stringsRequired(const ['chatId']);
    _integer('treeRevision', minimum: 0);
    final leaf = _optionalObject('selectedLeaf');
    if (leaf != null) TavernToolSourceToken.fromJson(leaf);
  }
  String get chatId => _string('chatId');
  TavernToolSourceToken? get selectedLeaf {
    final value = _optionalObject('selectedLeaf');
    return value == null ? null : TavernToolSourceToken.fromJson(value);
  }

  int get treeRevision => _integer('treeRevision');
}

/// Facts about one registered model request. Attempts are transport sends,
/// while requestIndex counts logical requests against the captured turn budget.
class TavernToolRequestSnapshot extends _ToolView {
  factory TavernToolRequestSnapshot.fromJson(Map<String, Object?> json) => TavernToolRequestSnapshot._(json);
  TavernToolRequestSnapshot._(super.json) {
    _stringsRequired(const ['requestId', 'status']);
    _integer('requestIndex', minimum: 0);
    _stringList('offeredTools');
    _stringList('receiptIds');
    _integerList('sendAttempts');
    _optionalString('providerFinishReason');
    _boolean('responseComplete');
    _object('usage');
    _object('batchDiagnostics');
  }
  String get requestId => _string('requestId');
  int get requestIndex => _integer('requestIndex');
  String get status => _string('status');
  List<String> get offeredTools => _stringList('offeredTools');
  List<int> get sendAttempts => _integerList('sendAttempts');
  String? get providerFinishReason => _optionalString('providerFinishReason');
  bool get responseComplete => _boolean('responseComplete');
  Map<String, Object?> get usage => _objectCopy('usage');
  Map<String, Object?> get batchDiagnostics => _objectCopy('batchDiagnostics');
  List<String> get receiptIds => _stringList('receiptIds');
}

/// Persisted logical-turn facts and current read-only context. candidateSource
/// is the owner's persisted expectation, never a refreshed final memory source.
class TavernToolTurnSnapshot extends _ToolView {
  factory TavernToolTurnSnapshot.fromJson(Map<String, Object?> json) => TavernToolTurnSnapshot._(json);
  TavernToolTurnSnapshot._(super.json) {
    _version();
    _stringsRequired(const ['logicalTurnId', 'chatId', 'generationType', 'status']);
    _stringsOptional(const ['actorId', 'hostId', 'groupRoundId', 'outcome']);
    _object('capturedPolicy');
    _object('usageSummary');
    TavernToolContextAnchor.fromJson(_object('admissionAnchor'));
    TavernToolContextAnchor.fromJson(_object('currentContextAnchor'));
    final candidate = _optionalObject('candidateSource');
    if (candidate != null) TavernToolSourceToken.fromJson(candidate);
    _integer('budgetUsed', minimum: 0);
    _optionalInteger('budgetMax', minimum: 1);
    for (final request in _objects('requests')) {
      TavernToolRequestSnapshot.fromJson(request);
    }
    for (final proposal in _objects('proposals')) {
      TavernMemoryProposalSnapshot.fromJson(proposal);
    }
    _stringList('receiptIds');
    _boolean('replyCommitAdopted');
    _boolean('normalFinalAdopted');
  }
  int get version => _integer('version');
  String get logicalTurnId => _string('logicalTurnId');
  String get chatId => _string('chatId');
  String get generationType => _string('generationType');
  String? get actorId => _optionalString('actorId');
  String? get hostId => _optionalString('hostId');
  String? get groupRoundId => _optionalString('groupRoundId');
  Map<String, Object?> get capturedPolicy => _objectCopy('capturedPolicy');
  TavernToolContextAnchor get admissionAnchor => TavernToolContextAnchor.fromJson(_object('admissionAnchor'));
  TavernToolContextAnchor get currentContextAnchor => TavernToolContextAnchor.fromJson(_object('currentContextAnchor'));
  TavernToolSourceToken? get candidateSource {
    final value = _optionalObject('candidateSource');
    return value == null ? null : TavernToolSourceToken.fromJson(value);
  }

  int get budgetUsed => _integer('budgetUsed');

  /// Null represents an explicitly unbounded SPreset recursion setting.
  /// Captured logical-request ceiling. Null represents an explicit unbounded
  /// SPreset recursion limit; native-only turns retain the legacy ceiling 4.
  int? get budgetMax => _optionalInteger('budgetMax');
  List<TavernToolRequestSnapshot> get requests =>
      List.unmodifiable([for (final value in _objects('requests')) TavernToolRequestSnapshot.fromJson(value)]);
  List<String> get receiptIds => _stringList('receiptIds');
  List<TavernMemoryProposalSnapshot> get proposals =>
      List.unmodifiable([for (final value in _objects('proposals')) TavernMemoryProposalSnapshot.fromJson(value)]);
  String get status => _string('status');
  String? get outcome => _optionalString('outcome');
  bool get replyCommitAdopted => _boolean('replyCommitAdopted');
  bool get normalFinalAdopted => _boolean('normalFinalAdopted');
  Map<String, Object?> get usageSummary => _objectCopy('usageSummary');
}

/// One durable execution identity. Reading this view never repeats its action.
/// [wireResult] is a parsed view; replay uses the store's original sealed TEXT.
class TavernToolReceipt extends _ToolView {
  factory TavernToolReceipt.fromJson(Map<String, Object?> json) => TavernToolReceipt._(json);
  TavernToolReceipt._(super.json) {
    _version();
    _stringsRequired(const ['receiptId', 'executionId', 'chatId', 'kind', 'origin', 'status']);
    if (_string('receiptId') != _string('executionId')) {
      throw const FormatException('receiptId must equal executionId.');
    }
    _stringsOptional(const [
      'logicalTurnId',
      'requestId',
      'callId',
      'actionId',
      'rawArguments',
      'proposalId',
      'sourceValidity',
    ]);
    _optionalInteger('requestIndex', minimum: 0);
    _optionalInteger('toolIndex', minimum: 0);
    _optionalBoolean('committed');
    _optionalBoolean('targetMissing');
    _object('capturedParameters');
    for (final key in const ['result', 'error', 'wireResult']) {
      _optionalObject(key);
    }
    final ref = _optionalObject('decisionRef');
    if (ref != null) TavernMemoryDecisionRef.fromJson(ref);
    final record = _optionalObject('decisionRecord');
    if (record != null) TavernMemoryDecisionRecord.fromJson(record);
    _date('createdAt');
    _date('updatedAt');
  }
  int get version => _integer('version');
  String get receiptId => _string('receiptId');
  String get executionId => _string('executionId');
  String get chatId => _string('chatId');
  String get kind => _string('kind');
  String get origin => _string('origin');
  String? get logicalTurnId => _optionalString('logicalTurnId');
  String? get requestId => _optionalString('requestId');
  int? get requestIndex => _optionalInteger('requestIndex');
  int? get toolIndex => _optionalInteger('toolIndex');
  String? get callId => _optionalString('callId');
  String? get actionId => _optionalString('actionId');
  String get status => _string('status');
  bool? get committed => _optionalBoolean('committed');
  Map<String, Object?> get capturedParameters => _objectCopy('capturedParameters');
  String? get rawArguments => _optionalString('rawArguments');
  Map<String, Object?>? get result => _optionalObjectCopy('result');
  Map<String, Object?>? get error => _optionalObjectCopy('error');
  Map<String, Object?>? get wireResult => _optionalObjectCopy('wireResult');
  String? get proposalId => _optionalString('proposalId');
  TavernMemoryDecisionRef? get decisionRef {
    final value = _optionalObject('decisionRef');
    return value == null ? null : TavernMemoryDecisionRef.fromJson(value);
  }

  TavernMemoryDecisionRecord? get decisionRecord {
    final value = _optionalObject('decisionRecord');
    return value == null ? null : TavernMemoryDecisionRecord.fromJson(value);
  }

  String? get sourceValidity => _optionalString('sourceValidity');
  bool? get targetMissing => _optionalBoolean('targetMissing');
  DateTime get createdAt => _date('createdAt');
  DateTime get updatedAt => _date('updatedAt');
}

/// A candidate, pending or historical remember proposal. Eligibility is a
/// current observation; workflow and the original accepted memory are history.
class TavernMemoryProposalSnapshot extends _ToolView {
  factory TavernMemoryProposalSnapshot.fromJson(Map<String, Object?> json) => TavernMemoryProposalSnapshot._(json);
  TavernMemoryProposalSnapshot._(super.json) {
    _stringsRequired(const [
      'proposalId',
      'chatId',
      'logicalTurnId',
      'requestId',
      'executionId',
      'candidateNodeId',
      'text',
      'mode',
      'workflow',
      'sourceValidity',
    ]);
    _integer('candidateSeq');
    _integer('candidateSourceEpoch', minimum: 0);
    _integer('version', minimum: 1);
    _stringList('keywords');
    _stringsOptional(const ['memoryId', 'ineligibleReason']);
    final token = _optionalObject('source');
    if (token != null) TavernToolSourceToken.fromJson(token);
    final ref = _optionalObject('lastDecisionRef');
    if (ref != null) TavernMemoryDecisionRef.fromJson(ref);
    TavernToolContextAnchor.fromJson(_object('contextAnchor'));
    _boolean('eligible');
  }
  String get proposalId => _string('proposalId');
  String get chatId => _string('chatId');
  String get logicalTurnId => _string('logicalTurnId');
  String get requestId => _string('requestId');
  String get executionId => _string('executionId');
  String get candidateNodeId => _string('candidateNodeId');
  int get candidateSeq => _integer('candidateSeq');
  int get candidateSourceEpoch => _integer('candidateSourceEpoch');
  String get text => _string('text');
  List<String> get keywords => _stringList('keywords');
  String get mode => _string('mode');
  int get version => _integer('version');
  String get workflow => _string('workflow');
  String get sourceValidity => _string('sourceValidity');
  TavernToolSourceToken? get source {
    final value = _optionalObject('source');
    return value == null ? null : TavernToolSourceToken.fromJson(value);
  }

  String? get memoryId => _optionalString('memoryId');
  TavernMemoryDecisionRef? get lastDecisionRef {
    final value = _optionalObject('lastDecisionRef');
    return value == null ? null : TavernMemoryDecisionRef.fromJson(value);
  }

  TavernToolContextAnchor get contextAnchor => TavernToolContextAnchor.fromJson(_object('contextAnchor'));
  bool get eligible => _boolean('eligible');
  String? get ineligibleReason => _optionalString('ineligibleReason');
}

/// Composite identity: a user id cannot collide with a policy-auto id.
class TavernMemoryDecisionRef extends _ToolView {
  factory TavernMemoryDecisionRef.fromJson(Map<String, Object?> json) => TavernMemoryDecisionRef._(json);
  TavernMemoryDecisionRef._(super.json) {
    _stringsRequired(const ['origin', 'decisionId']);
    if (!const ['user', 'policy_auto'].contains(_string('origin'))) {
      throw const FormatException('Invalid decision origin.');
    }
  }
  String get origin => _string('origin');
  String get decisionId => _string('decisionId');
}

/// The immutable outcome of one decision attempt, including stable failures.
/// proposalBefore/After retain source and acceptedMemoryId at that attempt.
class TavernMemoryDecisionRecord extends _ToolView {
  factory TavernMemoryDecisionRecord.fromJson(Map<String, Object?> json) => TavernMemoryDecisionRecord._(json);
  TavernMemoryDecisionRecord._(super.json) {
    final ref = TavernMemoryDecisionRef.fromJson(_object('decisionRef'));
    _stringsRequired(const ['chatId', 'proposalId', 'decision', 'outcome']);
    _decision(_string('decision'));
    _stringsOptional(const ['reason', 'memoryId']);
    final expected = _optionalInteger('expectedVersion', minimum: 1);
    final anchor = _optionalObject('expectedContextAnchor');
    if (anchor != null) TavernToolContextAnchor.fromJson(anchor);
    if (ref.origin == 'policy_auto' && (expected != null || anchor != null)) {
      throw const FormatException('Policy-auto decisions have no user expectation.');
    }
    if (ref.origin == 'user' && (expected == null || anchor == null)) {
      throw const FormatException('User decisions require version and context.');
    }
    _object('parameters');
    _object('proposalBefore');
    _object('proposalAfter');
    _date('createdAt');
  }
  TavernMemoryDecisionRef get decisionRef => TavernMemoryDecisionRef.fromJson(_object('decisionRef'));
  String get chatId => _string('chatId');
  String get proposalId => _string('proposalId');
  TavernMemoryDecision get decision => _decision(_string('decision'));
  String get outcome => _string('outcome');
  String? get reason => _optionalString('reason');
  int? get expectedVersion => _optionalInteger('expectedVersion');
  TavernToolContextAnchor? get expectedContextAnchor {
    final value = _optionalObject('expectedContextAnchor');
    return value == null ? null : TavernToolContextAnchor.fromJson(value);
  }

  Map<String, Object?> get parameters => _objectCopy('parameters');
  Map<String, Object?> get proposalBefore => _objectCopy('proposalBefore');
  Map<String, Object?> get proposalAfter => _objectCopy('proposalAfter');
  String? get memoryId => _optionalString('memoryId');
  DateTime get createdAt => _date('createdAt');
}

/// Read-time qualification beside an immutable decision. targetMissing refers
/// only to that record's original memoryId, never to another later decision.
class TavernMemoryDecisionCurrent extends _ToolView {
  factory TavernMemoryDecisionCurrent.fromJson(Map<String, Object?> json) => TavernMemoryDecisionCurrent._(json);
  TavernMemoryDecisionCurrent._(super.json) {
    TavernMemoryProposalSnapshot.fromJson(_object('proposal'));
    TavernToolContextAnchor.fromJson(_object('contextAnchor'));
    _stringsRequired(const ['sourceValidity']);
    _boolean('eligible');
    _optionalString('ineligibleReason');
    _optionalBoolean('targetMissing');
  }
  TavernMemoryProposalSnapshot get proposal => TavernMemoryProposalSnapshot.fromJson(_object('proposal'));
  TavernToolContextAnchor get contextAnchor => TavernToolContextAnchor.fromJson(_object('contextAnchor'));
  String get sourceValidity => _string('sourceValidity');
  bool get eligible => _boolean('eligible');
  String? get ineligibleReason => _optionalString('ineligibleReason');
  bool? get targetMissing => _optionalBoolean('targetMissing');
}

class TavernMemoryDecisionReceipt extends _ToolView {
  factory TavernMemoryDecisionReceipt.fromJson(Map<String, Object?> json) => TavernMemoryDecisionReceipt._(json);
  TavernMemoryDecisionReceipt._(super.json) {
    _version();
    TavernMemoryDecisionRecord.fromJson(_object('record'));
    TavernMemoryDecisionCurrent.fromJson(_object('current'));
    _boolean('replayed');
  }
  int get version => _integer('version');
  TavernMemoryDecisionRecord get record => TavernMemoryDecisionRecord.fromJson(_object('record'));
  TavernMemoryDecisionCurrent get current => TavernMemoryDecisionCurrent.fromJson(_object('current'));
  bool get replayed => _boolean('replayed');
}

/// Scope configuration, not provider/card/wire authorization. Each configured
/// envelope preserves key presence separately from its raw finite JSON value.
class TavernToolPolicySnapshot extends _ToolView {
  factory TavernToolPolicySnapshot.fromJson(Map<String, Object?> json) => TavernToolPolicySnapshot._(json);
  TavernToolPolicySnapshot._(super.json) {
    _policyEnvelope(_object('configuredGlobal'));
    final chat = _optionalObject('configuredChat');
    if (chat != null) _policyEnvelope(chat);
    final effective = _object('effectiveScope');
    if (effective['rollAllow'] is! bool ||
        effective['rememberAllow'] is! bool ||
        !const ['ask', 'auto'].contains(effective['rememberMode'])) {
      throw const FormatException('Invalid effective tool policy.');
    }
    _objects('diagnostics');
  }
  Map<String, Object?> get configuredGlobal => _objectCopy('configuredGlobal');
  Map<String, Object?>? get configuredChat => _optionalObjectCopy('configuredChat');
  Map<String, Object?> get effectiveScope => _objectCopy('effectiveScope');
  List<Map<String, Object?>> get diagnostics => _objectListCopy('diagnostics');
}

class TavernToolPolicyWriteResult extends _ToolView {
  factory TavernToolPolicyWriteResult.fromJson(Map<String, Object?> json) => TavernToolPolicyWriteResult._(json);
  TavernToolPolicyWriteResult._(super.json) {
    TavernToolPolicySnapshot.fromJson(_object('snapshot'));
    _boolean('committed');
    _objects('diagnostics');
  }
  TavernToolPolicySnapshot get snapshot => TavernToolPolicySnapshot.fromJson(_object('snapshot'));
  bool get committed => _boolean('committed');
  List<Map<String, Object?>> get diagnostics => _objectListCopy('diagnostics');
}

abstract class _ToolView {
  _ToolView(Map<String, Object?> json) : _data = _toolObject(json);
  final Map<String, Object?> _data;
  Map<String, Object?> toJson() => _toolObject(_data);
  void _version() {
    if (_integer('version') != 1) throw const FormatException('Unsupported tool view version.');
  }

  void _stringsRequired(List<String> keys) {
    for (final key in keys) {
      _string(key);
    }
  }

  void _stringsOptional(List<String> keys) {
    for (final key in keys) {
      _optionalString(key);
    }
  }

  String _string(String key) {
    final value = _data[key];
    if (value is! String || value.isEmpty) throw FormatException('$key must be a nonempty string.');
    return value;
  }

  String? _optionalString(String key) {
    final value = _data[key];
    if (value != null && value is! String) throw FormatException('$key must be a string or null.');
    return value as String?;
  }

  int _integer(String key, {int? minimum}) {
    final value = _data[key];
    if (value is! int || (minimum != null && value < minimum)) throw FormatException('$key has an invalid integer.');
    return value;
  }

  int? _optionalInteger(String key, {int? minimum}) => _data[key] == null ? null : _integer(key, minimum: minimum);
  bool _boolean(String key) {
    final value = _data[key];
    if (value is! bool) throw FormatException('$key must be a boolean.');
    return value;
  }

  bool? _optionalBoolean(String key) => _data[key] == null ? null : _boolean(key);
  Map<String, Object?> _object(String key) {
    final value = _data[key];
    if (value is! Map<String, Object?>) throw FormatException('$key must be an object.');
    return value;
  }

  Map<String, Object?>? _optionalObject(String key) => _data[key] == null ? null : _object(key);
  Map<String, Object?> _objectCopy(String key) => _toolObject(_object(key));
  Map<String, Object?>? _optionalObjectCopy(String key) {
    final value = _optionalObject(key);
    return value == null ? null : _toolObject(value);
  }

  List<Object?> _list(String key) {
    final value = _data[key];
    if (value is! List<Object?>) throw FormatException('$key must be an array.');
    return value;
  }

  List<String> _stringList(String key) => List.unmodifiable([
    for (final value in _list(key))
      if (value is String) value else throw FormatException('$key contains a non-string.'),
  ]);
  List<int> _integerList(String key) => List.unmodifiable([
    for (final value in _list(key))
      if (value is int && value >= 0) value else throw FormatException('$key contains an invalid integer.'),
  ]);
  List<Map<String, Object?>> _objects(String key) => [
    for (final value in _list(key))
      if (value is Map<String, Object?>) value else throw FormatException('$key contains a non-object.'),
  ];
  List<Map<String, Object?>> _objectListCopy(String key) =>
      List.unmodifiable([for (final value in _objects(key)) _toolObject(value)]);
  DateTime _date(String key) {
    final value = _data[key];
    final parsed = value is String ? DateTime.tryParse(value) : null;
    if (parsed == null || !parsed.isUtc) throw FormatException('$key must be an ISO8601 UTC date.');
    _data[key] = parsed.toUtc().toIso8601String();
    return parsed.toUtc();
  }
}

TavernMemoryDecision _decision(String value) => switch (value) {
  'accept' => TavernMemoryDecision.accept,
  'reject' => TavernMemoryDecision.reject,
  _ => throw const FormatException('Invalid memory decision.'),
};

void _policyEnvelope(Map<String, Object?> value) {
  if (value['present'] is! bool || !value.containsKey('raw') || (value['present'] == false && value['raw'] != null)) {
    throw const FormatException('Invalid configured policy envelope.');
  }
}

Map<String, Object?> _toolObject(Map<String, Object?> value) {
  // Do not invoke arbitrary toJson methods on caller objects. Only finite JSON
  // data is supported; the encoder additionally rejects cyclic containers.
  void check(Object? item, Set<Object> parents) {
    if (item == null || item is String || item is bool || item is int) return;
    if (item is double && item.isFinite) return;
    if (item is Map<String, Object?> || item is List<Object?>) {
      if (!parents.add(item)) throw const FormatException('Cyclic tool JSON.');
      final values = item is Map<String, Object?> ? item.values : (item as List<Object?>);
      for (final child in values) {
        check(child, parents);
      }
      parents.remove(item);
      return;
    }
    throw const FormatException('Tool views require finite JSON.');
  }

  check(value, Set<Object>.identity());
  return jsonDecode(jsonEncode(value)) as Map<String, Object?>;
}
