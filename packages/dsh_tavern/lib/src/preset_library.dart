import 'json_copy.dart';

import 'regex_library.dart';

/// A normalization is an explicit change to a known field. Warnings preserve
/// the data but describe an unsupported or inactive feature; errors reject it.
enum TavernPresetIssueSeverity { normalized, warning, error }

final class TavernPresetIssue {
  const TavernPresetIssue({
    required this.path,
    required this.code,
    required this.message,
    this.identifier,
    this.severity = TavernPresetIssueSeverity.warning,
  });

  final String path;
  final String code;
  final String message;
  final String? identifier;
  final TavernPresetIssueSeverity severity;

  Map<String, Object?> toJson() => {
    'path': path,
    'code': code,
    'message': message,
    if (identifier != null) 'identifier': identifier,
    'severity': severity.name,
  };
}

/// Import is all-or-nothing. Diagnostics do not contain the original document
/// or connection credentials; callers may display each affected JSON path.
final class TavernPresetImportError implements Exception {
  TavernPresetImportError(Iterable<TavernPresetIssue> issues) : issues = List<TavernPresetIssue>.unmodifiable(issues);

  final List<TavernPresetIssue> issues;

  @override
  String toString() =>
      '预设导入失败：${issues.where((issue) => issue.severity == TavernPresetIssueSeverity.error).map((issue) => '${issue.path} ${issue.message}').join('；')}';
}

class TavernPresetSummary {
  const TavernPresetSummary({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    required this.hasEnvelope,
  });

  final String id;
  final String name;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool hasEnvelope;
}

/// The source text is the exact imported String, including any BOM/whitespace.
/// It stays unchanged when the editable [raw] document is updated.
final class TavernPreset extends TavernPresetSummary {
  TavernPreset({
    required super.id,
    required super.name,
    required this.sourceText,
    required Map<String, Object?> raw,
    Map<String, Object?>? envelope,
    required super.createdAt,
    required super.updatedAt,
  }) : _raw = _copy(raw),
       _envelope = envelope == null ? null : _copy(envelope),
       super(hasEnvelope: envelope != null);

  final String sourceText;
  final Map<String, Object?> _raw;
  final Map<String, Object?>? _envelope;

  Map<String, Object?> get raw => _copy(_raw);
  Map<String, Object?>? get envelope => _envelope == null ? null : _copy(_envelope);

  TavernPresetSummary get summary =>
      TavernPresetSummary(id: id, name: name, createdAt: createdAt, updatedAt: updatedAt, hasEnvelope: hasEnvelope);
}

final class TavernPresetImportResult {
  TavernPresetImportResult(
    this.preset,
    Iterable<TavernPresetIssue> issues, {
    Iterable<TavernRegexDiagnostic> regexDiagnostics = const [],
  }) : issues = List<TavernPresetIssue>.unmodifiable(issues),
       regexDiagnostics = List.unmodifiable(regexDiagnostics);

  final TavernPreset preset;
  final List<TavernPresetIssue> issues;
  final List<TavernRegexDiagnostic> regexDiagnostics;
}

Map<String, Object?> _copy(Map<String, Object?> value) => copyJsonObject(value);
