part of 'engine.dart';

/// A response-only view of packets already parsed by the production decoder.
/// This does not supply tool identity, permission, receipts, or replay evidence.
class _SPresetResponseMetadata {
  _SPresetResponseMetadata({required this.source, required this.streamingToolsSupported});
  final String source;
  final bool streamingToolsSupported;
  int? _attempt;
  bool observed = false;
  bool hasBlockedPrimaryToolFragments = false;
  Map<String, Object?>? nonStreamingResponse;
  final _choices = <int, Map<int, Map<String, Object?>>>{};
  final _toolSignatures = <String, Object?>{};

  void add(int attempt, bool streaming, Map<String, Object?> frame, {bool? toolsSupported}) {
    if (_attempt != attempt) {
      _attempt = attempt;
      observed = false;
      hasBlockedPrimaryToolFragments = false;
      nonStreamingResponse = null;
      _choices.clear();
      _toolSignatures.clear();
    }
    observed = true;
    if (!streaming) {
      nonStreamingResponse = frame;
      return;
    }
    final choices = _spRows(frame['choices']);
    if (source == 'openrouter' && choices.isNotEmpty) {
      final first = choices.first;
      for (final detail in [
        ..._spRows(_spMap(first['delta'])['reasoning_details']),
        ..._spRows(_spMap(first['message'])['reasoning_details']),
      ]) {
        final id = detail['id'];
        if (detail['type'] == 'reasoning.encrypted' && presetTruthy(detail['data']) && id is String && id.isNotEmpty) {
          _toolSignatures[id] = detail['data'];
        }
      }
    }
    // getStreamingReply records signatures before ToolManager's support gate.
    // A later catalog update can enable a tool referring to an earlier frame.
    if (!(toolsSupported ?? streamingToolsSupported)) {
      // Match the production decoder's _firstChoice, including a non-map row
      // becoming an empty primary choice. Filtering such rows would invent a
      // blocked native fragment that the decoder never emitted.
      Map<String, Object?> primary = const {};
      final rawChoices = frame['choices'];
      if (rawChoices is List<Object?>) {
        for (final value in rawChoices) {
          final choice = _spMap(value);
          if (choice['index'] == null || choice['index'] == 0) {
            primary = choice;
            break;
          }
        }
      }
      final calls = _spMap(primary['delta'])['tool_calls'];
      // The production decoder emits native fragments for every non-null
      // nonempty envelope, including malformed ones requiring rejection. Do
      // not hide that validation/replay path after formatting a different call.
      if (calls != null && (calls is! List<Object?> || calls.isNotEmpty)) {
        hasBlockedPrimaryToolFragments = true;
      }
      return;
    }
    for (final choice in choices) {
      // ToolManager requires a numeric choice index. Array properties that
      // are not JavaScript array indices do not enter its formatting traversal.
      final rawChoiceIndex = choice['index'];
      if (rawChoiceIndex is! num) continue;
      final choiceIndex = _spresetArrayIndex(rawChoiceIndex);
      if (choiceIndex == null) continue;
      final deltas = _spMap(choice['delta'])['tool_calls'];
      if (deltas is! List<Object?>) continue;
      final calls = _choices.putIfAbsent(choiceIndex, () => {});
      for (var ordinal = 0; ordinal < deltas.length; ordinal++) {
        final delta = deltas[ordinal];
        if (delta is! Map<String, Object?>) continue;
        final rawIndex = delta.containsKey('index') && presetJsNumber(delta['index']) >= 0 ? delta['index'] : ordinal;
        final index = _spresetArrayIndex(rawIndex);
        if (index == null) continue;
        final target = calls.putIfAbsent(index, () => {});
        _spresetApplyToolDelta(target, delta);
        final id = target.containsKey('id') ? presetString(target['id']) : 'undefined';
        // ST applies an encrypted signature only while processing a tool
        // delta. A later reasoning-only packet does not rewrite prior calls.
        if (_toolSignatures.containsKey(id)) target['signature'] = _toolSignatures[id];
      }
    }
  }

  List<Object?> get toolCalls {
    final choices = _choices.keys.toList()..sort();
    return [
      for (final choice in choices)
        for (final index in (_choices[choice]!.keys.toList()..sort())) _choices[choice]![index],
    ];
  }
}

int? _spresetArrayIndex(Object? value) {
  if (value is num && value.isFinite && value == value.truncateToDouble() && value >= 0 && value < 4294967295) {
    return value.toInt();
  }
  if (value is String) {
    final parsed = int.tryParse(value);
    if (parsed != null && parsed >= 0 && parsed < 4294967295 && parsed.toString() == value) return parsed;
  }
  return null;
}

void _spresetApplyToolDelta(Map<String, Object?> target, Map<String, Object?> delta) {
  for (final entry in delta.entries) {
    final key = entry.key;
    if (key == '__proto__' || key == 'constructor') continue;
    final value = entry.value, current = target[key];
    if (value == null) {
      if (!presetTruthy(current)) target[key] = null;
    } else if (value is String) {
      if (key == 'id' || key == 'name' || key == 'type') {
        if (!presetTruthy(current)) target[key] = value;
      } else {
        target[key] = current is String ? current + value : value;
      }
    } else if (value is Map<String, Object?>) {
      final nested = current is Map<String, Object?> ? current : <String, Object?>{};
      target[key] = nested;
      _spresetApplyToolDelta(nested, value);
    } else {
      target[key] = value;
    }
  }
}

extension _SPresetResponseConsumption on _SPresetGeneration {
  /// OAI-compatible fetch consumption. A later choice failing leaves the
  /// caller's original complete response untouched; formatter effects already
  /// performed remain real and are not retried or declared rolled back.
  Future<Map<String, Object?>?> consumeResponseTools(Map<String, Object?> response, Map<String, Object?> output) async {
    final next = _captureScriptObject(response);
    var consumed = false;
    for (final choice in _spRows(next['choices'])) {
      final message = _spMap(choice['message']);
      final toolCalls = message['tool_calls'];
      final calls = <Object?>[
        if (toolCalls is List<Object?>) ...toolCalls else if (toolCalls is Map<String, Object?>) toolCalls,
        if (message['function_call'] is Map<String, Object?>) message['function_call'],
      ];
      if (calls.isEmpty) continue;
      final addition = await spresetFormatToolCalls(
        calls,
        output,
        provider,
        evaluate,
        stream: false,
        channel: 'choice:${_spString(choice['index'] ?? 0)}',
      );
      cancellation.check();
      message['content'] = _spresetAppendResponseText(message['content'], addition);
      message.remove('tool_calls');
      message.remove('function_call');
      choice.remove('tool_calls');
      choice.remove('function_call');
      if (choice['finish_reason'] == 'tool_calls' || choice['finish_reason'] == 'function_call') {
        choice['finish_reason'] = 'stop';
      }
      consumed = true;
    }
    return consumed ? next : null;
  }
}

Object _spresetAppendResponseText(Object? content, String addition) {
  if (content == null || content is String) return spresetAppendToolText(_string(content), addition);
  if (content is List<Object?>) {
    final parts = [for (final part in content) part is Map<String, Object?> ? _captureScriptObject(part) : part];
    for (var index = parts.length - 1; index >= 0; index--) {
      final part = parts[index];
      if (part is Map<String, Object?> &&
          part['text'] is String &&
          (!presetTruthy(part['type']) || const {'text', 'output_text'}.contains(part['type']))) {
        part['text'] = spresetAppendToolText(part['text']! as String, addition);
        return parts;
      }
      if (part is String) {
        parts[index] = spresetAppendToolText(part, addition);
        return parts;
      }
    }
    return [
      ...parts,
      {'type': 'text', 'text': addition},
    ];
  }
  if (content is Map<String, Object?> && content['text'] is String) {
    return {...content, 'text': spresetAppendToolText(content['text']! as String, addition)};
  }
  throw const SPresetException('OutputPreprocessing', 'Cannot safely append tool arguments to response content.');
}

Map<String, Object?> _spresetPrimaryChoice(Map<String, Object?> response) {
  for (final choice in _spRows(response['choices'])) {
    if (choice['index'] == null || choice['index'] == 0) return choice;
  }
  return const {};
}

String _spresetResponseText(Object? content) {
  if (content == null) return '';
  if (content is String) return content;
  if (content is List<Object?>) {
    final text = StringBuffer();
    for (final part in content) {
      if (part == null) {
        throw const SPresetException(
          'OutputPreprocessing',
          'Response text extraction encountered a null content part.',
        );
      }
      final value = _spMap(part)['text'];
      if (presetTruthy(value)) text.write(presetString(value));
    }
    return text.toString();
  }
  throw const SPresetException('OutputPreprocessing', 'Text output cannot represent this response content shape.');
}
