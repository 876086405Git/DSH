// Pure projection from SillyTavern 1.19.0 public/scripts/openai.js
// (AGPL-3.0), commit 7e8663cd9c184a550b37238218bdd32c6efc68e9.
// This internal module is not yet connected to engine history or transport.
import '../js_string.dart';
import 'preset.dart';

enum ToolReasoningMode {
  disabled('disabled'),
  sinceLastUser('since_last_user'),
  activeChain('active_chain');

  const ToolReasoningMode(this.value);
  final String value;
}

/// The preset and actual connection captured by a caller. Tool support is a
/// separate factual gate; this function neither queries a catalog nor grants
/// permission to execute a tool. Missing show_thoughts is falsey here, as in
/// the source function; normal callers will supply resolved preset settings.
ToolReasoningMode effectiveToolReasoningMode(Map<String, Object?> settings, {required String source}) {
  if (!const {'openrouter', 'custom'}.contains(source) || !presetTruthy(settings['show_thoughts'])) {
    return ToolReasoningMode.disabled;
  }
  final value = presetString(settings['tool_reasoning_mode'] ?? '');
  return switch (value) {
    'since_last_user' => ToolReasoningMode.sinceLastUser,
    'active_chain' => ToolReasoningMode.activeChain,
    _ => ToolReasoningMode.disabled,
  };
}

/// One prepared, chronological history candidate, before token admission.
///
/// These are JSON-owned rows with object-shaped ToolInvocation records. This
/// is not a raw chat importer or a validator for arbitrary script objects.
/// Content/reasoning retain their original JSON types: a non-string content
/// can stop active_chain even when it would later serialize as text. Unknown
/// fields and the absence of invocations versus an empty array are retained.
final class ToolReasoningHistoryRow {
  ToolReasoningHistoryRow.fromJson(Map<String, Object?> value) : _data = _freeze(value) as Map<String, Object?>;

  final Map<String, Object?> _data;
  Object? get role => _data['role'];
  Object? get content => _copy(_data['content']);
  Object? get reasoning => _copy(_data['reasoning']);

  List<Map<String, Object?>>? get invocations {
    final value = _data['invocations'];
    return value is List<Object?> ? [for (final item in value) _copy(item) as Map<String, Object?>] : null;
  }

  bool get _hasInvocations => _data['invocations'] is List<Object?>;
  Map<String, Object?> toJson() => _copy(_data) as Map<String, Object?>;
}

/// Source/model and group checks from setOpenAIMessages. The caller supplies
/// an already prepared row whose reasoning/signature/invocations came from
/// the corresponding chat extra fields; name/media conversion happens outside
/// this function. Unrelated row and invocation fields are preserved.
ToolReasoningHistoryRow projectToolReasoningProvenance(
  ToolReasoningHistoryRow row, {
  required String source,
  required String model,
  required Object? originSource,
  required Object? originModel,
  bool group = false,
  String characterName = '',
}) {
  final result = row.toJson();
  final sameModel = originSource == source && originModel == model;
  final otherGroupMember = group && result['name'] != characterName;
  result['reasoning'] = sameModel && !otherGroupMember ? presetString(result['reasoning'] ?? '') : '';
  if (!sameModel || otherGroupMember) result['signature'] = null;

  final invocations = row.invocations;
  if (invocations != null) {
    if (!sameModel) {
      for (final invocation in invocations) {
        // The source only removes this pair when at least one value is
        // truthy. Preserve a pair of falsey metadata fields verbatim.
        if (presetTruthy(invocation['signature']) || presetTruthy(invocation['reasoning'])) {
          invocation
            ..remove('signature')
            ..remove('reasoning');
        }
      }
    }
    result['invocations'] = invocations;
  }
  return ToolReasoningHistoryRow.fromJson(result);
}

/// Detached invocation clones and the message-level plaintext selected by
/// Message.setToolCalls. Tool parameters, signatures and action identity are
/// not converted here. This result carries no token/admission claim.
final class ToolReasoningProjection {
  ToolReasoningProjection._(List<Map<String, Object?>> invocations, this.reasoning)
    : _invocations = _freeze(invocations) as List<Object?>;

  final List<Object?> _invocations;
  final String? reasoning;
  List<Map<String, Object?>> get invocations => [for (final item in _invocations) _copy(item) as Map<String, Object?>];
}

/// Select over the complete candidate sequence, including older candidates
/// which may subsequently fail admission. Ordinary rows and unsupported tools
/// produce null; an empty invocation array produces an empty projection.
ToolReasoningProjection? projectToolReasoning(
  List<ToolReasoningHistoryRow> history,
  int index, {
  required ToolReasoningMode mode,
  bool toolsSupported = true,
}) {
  final row = history[index];
  if (!toolsSupported) return null;
  final invocations = row.invocations;
  if (invocations == null) return null;

  // populateChatHistory uses messages.indexOf(chatPrompt), which retains the
  // first identity if an in-memory caller repeats the same candidate object.
  final promptIndex = history.indexOf(row);
  final lastUser = history.lastIndexWhere((candidate) => candidate.role == 'user');
  final eligible = mode != ToolReasoningMode.disabled && promptIndex > lastUser;
  var previousReasoning = '';
  if (eligible) {
    for (var prior = promptIndex - 1; prior > lastUser; prior--) {
      final candidate = history[prior];
      final hasAssistantText =
          candidate.role == 'assistant' &&
          !candidate._hasInvocations &&
          candidate._data['content'] is String &&
          trimJsWhitespace(candidate._data['content']! as String).isNotEmpty;
      if (mode == ToolReasoningMode.activeChain) {
        if (candidate.role == 'tool' || candidate.role == 'assistant' && candidate._hasInvocations) continue;
        if (hasAssistantText) previousReasoning = presetString(candidate._data['reasoning'] ?? '');
        break;
      }
      if (!hasAssistantText) continue;
      final reasoning = presetString(candidate._data['reasoning'] ?? '');
      if (reasoning.isNotEmpty) {
        previousReasoning = reasoning;
        break;
      }
    }
  }
  for (final invocation in invocations) {
    if (!eligible) {
      invocation.remove('reasoning');
    } else if (previousReasoning.isNotEmpty && !presetTruthy(invocation['reasoning'])) {
      invocation['reasoning'] = previousReasoning;
    }
  }
  String? messageReasoning;
  if (mode != ToolReasoningMode.disabled) {
    for (final invocation in invocations) {
      final reasoning = invocation['reasoning'];
      if (reasoning is String && reasoning.isNotEmpty) {
        messageReasoning = reasoning;
        break;
      }
    }
  }
  return ToolReasoningProjection._(invocations, messageReasoning);
}

Object? _freeze(Object? value) => switch (value) {
  Map<String, Object?>() => Map<String, Object?>.unmodifiable({
    for (final entry in value.entries) entry.key: _freeze(entry.value),
  }),
  List<Object?>() => List<Object?>.unmodifiable(value.map(_freeze)),
  _ => value,
};

Object? _copy(Object? value) => switch (value) {
  Map<String, Object?>() => {for (final entry in value.entries) entry.key: _copy(entry.value)},
  List<Object?>() => value.map(_copy).toList(),
  _ => value,
};
