import 'api.dart';
import 'prompt/prompt_types.dart';

/// Reading a recorded attempt never evaluates its prompt again.
enum TavernInspectionStatus { preparing, ready, completed, failed }

/// Assembly is not proof that HTTP was sent (for example, a key may be absent).
class TavernTurnInspection {
  factory TavernTurnInspection({
    required String chatId,
    String? nodeId,
    String? contextNodeId,
    required String generationType,
    required DateTime startedAt,
    DateTime? finishedAt,
    TavernInspectionStatus status = TavernInspectionStatus.preparing,
    PromptAssembly? prompt,
    Map<String, Object?> worldInfo = const {},
    Map<String, Object?> state = const {},
    Map<String, Object?> director = const {},
    TavernUsage? reportedUsage,
    TavernFailure? failure,
    String? detail,
    String? logicalTurnId,
  }) => TavernTurnInspection._(
    chatId,
    nodeId,
    contextNodeId,
    generationType,
    startedAt.toUtc(),
    finishedAt?.toUtc(),
    status,
    prompt == null ? null : _readAssembly(prompt.toJson()),
    _freezeMap(worldInfo),
    _freezeMap(state),
    _freezeMap(director),
    reportedUsage,
    failure,
    detail,
    logicalTurnId,
  );

  const TavernTurnInspection._(
    this.chatId,
    this.nodeId,
    this.contextNodeId,
    this.generationType,
    this.startedAt,
    this.finishedAt,
    this.status,
    this.prompt,
    this.worldInfo,
    this.state,
    this.director,
    this.reportedUsage,
    this.failure,
    this.detail,
    this.logicalTurnId,
  );

  factory TavernTurnInspection.fromJson(Map<String, Object?> json) {
    if (json['version'] != 1) throw const FormatException('Unsupported inspection version.');
    final prompt = json['prompt'];
    final usage = json['reportedUsage'];
    final failure = json['failure'];
    return TavernTurnInspection._(
      _text(json['chatId'], 'chatId'),
      _optionalText(json['nodeId'], 'nodeId'),
      _optionalText(json['contextNodeId'], 'contextNodeId'),
      _text(json['generationType'], 'generationType'),
      _date(json['startedAt'], 'startedAt'),
      json['finishedAt'] == null ? null : _date(json['finishedAt'], 'finishedAt'),
      _enumValue(TavernInspectionStatus.values, json['status'], 'status'),
      prompt == null ? null : _readAssembly(_object(prompt, 'prompt')),
      _freezeMap(_object(json['worldInfo'], 'worldInfo')),
      json.containsKey('state') ? _freezeMap(_object(json['state'], 'state')) : const {},
      json.containsKey('director') ? _freezeMap(_object(json['director'], 'director')) : const {},
      usage == null ? null : _readUsage(_object(usage, 'reportedUsage')),
      failure == null ? null : _enumValue(TavernFailure.values, failure, 'failure'),
      _optionalText(json['detail'], 'detail'),
      _optionalText(json['logicalTurnId'], 'logicalTurnId'),
    );
  }

  final String chatId;
  final String? logicalTurnId;

  /// Null for ephemeral impersonation or an attempt that stored no output.
  final String? nodeId;

  /// The pre-existing context leaf, before this attempt appended a user line.
  /// For an ephemeral attempt this anchors deletion without inventing a reply
  /// node; deleting the anchor also clears the chat's latest snapshot.
  final String? contextNodeId;
  final String generationType;
  final DateTime startedAt;
  final DateTime? finishedAt;
  final TavernInspectionStatus status;

  /// Null if failure occurred before a complete assembly was available.
  final PromptAssembly? prompt;

  /// Actual WI admission trace, including entry ids and match reasons.
  final Map<String, Object?> worldInfo;

  /// Recorded state preparation and settlement. Empty for ordinary legacy
  /// cards; detailed accepted/rejected operations remain in agent runs.
  final Map<String, Object?> state;

  /// The captured prior result and actual beat/prefetch preparation, never
  /// the private helper input or notes. Empty keeps the legacy wire intact.
  final Map<String, Object?> director;

  /// Null until THIS call reports usage. It is never inferred from estimates
  /// or the previous portion of a continued message. Zero is a reported value.
  final TavernUsage? reportedUsage;
  final TavernFailure? failure;
  final String? detail;

  bool get tokenCountsEstimated => prompt != null && !prompt!.exactTokenCounts;
  String get tokenCountLabel => prompt == null
      ? '未组装'
      : tokenCountsEstimated
      ? '估算'
      : '计数';

  TavernTurnInspection copyWith({
    String? nodeId,
    bool clearNodeId = false,
    String? contextNodeId,
    bool clearContextNodeId = false,
    DateTime? finishedAt,
    TavernInspectionStatus? status,
    PromptAssembly? prompt,
    Map<String, Object?>? worldInfo,
    Map<String, Object?>? state,
    Map<String, Object?>? director,
    TavernUsage? reportedUsage,
    bool clearReportedUsage = false,
    TavernFailure? failure,
    String? detail,
    String? logicalTurnId,
  }) => TavernTurnInspection._(
    chatId,
    clearNodeId ? null : nodeId ?? this.nodeId,
    clearContextNodeId ? null : contextNodeId ?? this.contextNodeId,
    generationType,
    startedAt,
    finishedAt?.toUtc() ?? this.finishedAt,
    status ?? this.status,
    prompt == null ? this.prompt : _readAssembly(prompt.toJson()),
    worldInfo == null ? this.worldInfo : _freezeMap(worldInfo),
    state == null ? this.state : _freezeMap(state),
    director == null ? this.director : _freezeMap(director),
    clearReportedUsage ? null : reportedUsage ?? this.reportedUsage,
    failure ?? this.failure,
    detail ?? this.detail,
    logicalTurnId ?? this.logicalTurnId,
  );

  Map<String, Object?> toJson() => {
    'version': 1,
    'chatId': chatId,
    if (logicalTurnId != null) 'logicalTurnId': logicalTurnId,
    'nodeId': nodeId,
    'contextNodeId': contextNodeId,
    'generationType': generationType,
    'startedAt': startedAt.toIso8601String(),
    'finishedAt': finishedAt?.toIso8601String(),
    'status': status.name,
    'prompt': prompt?.toJson(),
    'worldInfo': worldInfo,
    if (state.isNotEmpty) 'state': state,
    if (director.isNotEmpty) 'director': director,
    'reportedUsage': reportedUsage == null
        ? null
        : {
            'promptTokens': reportedUsage!.promptTokens,
            'cacheHitTokens': reportedUsage!.cacheHitTokens,
            'completionTokens': reportedUsage!.completionTokens,
            'model': reportedUsage!.model,
          },
    'failure': failure?.name,
    'detail': detail,
  };
}

PromptAssembly _readAssembly(Map<String, Object?> json) => PromptAssembly(
  body: _freezeMap(_object(json['body'], 'body')),
  beforePostProcessing: _segments(json['beforePostProcessing']),
  afterPostProcessing: _segments(json['afterPostProcessing']),
  excluded: List.unmodifiable([for (final value in _list(json['excluded'], 'excluded')) _readExclusion(value)]),
  budget: _integer(json['budget'], 'budget'),
  remainingBudget: _integer(json['remainingBudget'], 'remainingBudget'),
  counterName: _text(json['counter'], 'counter'),
  exactTokenCounts: _boolean(json['exactTokenCounts'], 'exactTokenCounts'),
  historyWindow: json['historyWindow'] == null ? null : _readHistoryWindow(json['historyWindow']),
);

PromptHistoryWindow _readHistoryWindow(Object? value) {
  final item = _object(value, 'historyWindow');
  final examples = <({String kind, String id, int block})>[];
  for (final value in _list(item['admittedExamples'], 'historyWindow.admittedExamples')) {
    final example = _object(value, 'historyWindow.example');
    examples.add((
      kind: _text(example['kind'], 'historyWindow.example.kind'),
      id: _text(example['id'], 'historyWindow.example.id'),
      block: _integer(example['block'], 'historyWindow.example.block'),
    ));
  }
  final sources = <({String kind, String id})>[];
  for (final value in _list(item['excludedOptionalSources'], 'historyWindow.excludedOptionalSources')) {
    final source = _object(value, 'historyWindow.source');
    sources.add((
      kind: _text(source['kind'], 'historyWindow.source.kind'),
      id: _text(source['id'], 'historyWindow.source.id'),
    ));
  }
  return PromptHistoryWindow(
    firstNodeId: _text(item['firstNodeId'], 'historyWindow.firstNodeId'),
    admittedExamples: examples,
    excludedOptionalSources: sources,
    excludedInjections: [
      for (final value in _list(item['excludedInjections'], 'historyWindow.excludedInjections'))
        _text(value, 'historyWindow.excludedInjection'),
    ],
  );
}

List<PromptSegment> _segments(Object? value) =>
    List.unmodifiable([for (final item in _list(value, 'segments')) _readSegment(item)]);

PromptSegment _readSegment(Object? value) {
  final item = _object(value, 'segment');
  return PromptSegment(
    id: _text(item['id'], 'segment.id'),
    message: _freezeMap(_object(item['message'], 'message')),
    sources: _sources(item['sources']),
    tokens: _integer(item['tokens'], 'tokens'),
  );
}

PromptExclusion _readExclusion(Object? value) {
  final item = _object(value, 'exclusion');
  return PromptExclusion(_text(item['id'], 'exclusion.id'), _text(item['reason'], 'reason'), _sources(item['sources']));
}

List<PromptSource> _sources(Object? value) =>
    List.unmodifiable([for (final item in _list(value, 'sources')) _readSource(_object(item, 'source'))]);

PromptSource _readSource(Map<String, Object?> item) => PromptSource(
  _text(item['kind'], 'source.kind'),
  _text(item['id'], 'source.id'),
  label: _text(item['label'], 'source.label'),
  details: _freezeMap(_object(item['details'], 'source.details')),
);

TavernUsage _readUsage(Map<String, Object?> item) => TavernUsage(
  promptTokens: _integer(item['promptTokens'], 'promptTokens'),
  cacheHitTokens: _integer(item['cacheHitTokens'], 'cacheHitTokens'),
  completionTokens: _integer(item['completionTokens'], 'completionTokens'),
  model: _optionalText(item['model'], 'model'),
);

Map<String, Object?> _freezeMap(Map<String, Object?> value) =>
    Map.unmodifiable({for (final entry in value.entries) entry.key: _freeze(entry.value)});

Object? _freeze(Object? value) {
  if (value is Map<String, Object?>) return _freezeMap(value);
  if (value is List<Object?>) return List<Object?>.unmodifiable(value.map(_freeze));
  if (value == null || value is String || value is bool || (value is num && value.isFinite)) return value;
  throw const FormatException('Inspection data must contain only finite JSON values.');
}

Map<String, Object?> _object(Object? value, String name) {
  if (value is Map<String, Object?>) return value;
  throw FormatException('$name must be an object.');
}

List<Object?> _list(Object? value, String name) {
  if (value is List<Object?>) return value;
  throw FormatException('$name must be an array.');
}

String _text(Object? value, String name) {
  if (value is String) return value;
  throw FormatException('$name must be text.');
}

String? _optionalText(Object? value, String name) => value == null ? null : _text(value, name);

int _integer(Object? value, String name) {
  if (value is int) return value;
  throw FormatException('$name must be an integer.');
}

bool _boolean(Object? value, String name) {
  if (value is bool) return value;
  throw FormatException('$name must be a boolean.');
}

DateTime _date(Object? value, String name) {
  final result = DateTime.tryParse(_text(value, name));
  if (result != null) return result.toUtc();
  throw FormatException('$name must be a date.');
}

T _enumValue<T extends Enum>(List<T> values, Object? value, String name) =>
    values.firstWhere((item) => item.name == value, orElse: () => throw FormatException('Invalid $name.'));
