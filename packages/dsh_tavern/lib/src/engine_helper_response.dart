part of 'engine.dart';

/// Fixed ST/Helper extraction belongs to this compatibility path. The native
/// decoder keeps its established aliases and completion-envelope validation.
extension _HelperResponseText on _HelperRequestRuntime {
  ({String text, String reasoning}) projectResponseText(bool streaming, Map<String, Object?> frame) {
    var choices = _spRows(frame['choices']);
    if (streaming && response != null) {
      final selected = response!.selectStreamingChoice(choices);
      choices = selected.isEmpty ? const [] : [selected];
    }
    final first = choices.firstOrNull ?? <String, Object?>{};
    final message = _map(first['message']);
    Object? text;
    Object? reasoning;
    if (streaming) {
      final delta = _map(first['delta']);
      Object? firstTruthy(String envelope, String key) {
        for (final choice in choices) {
          final value = _map(choice[envelope])[key];
          if (presetTruthy(value)) return value;
        }
        return null;
      }

      text = source == 'deepseek'
          ? presetTruthy(delta['content'])
                ? delta['content']
                : ''
          : delta['content'] ?? message['content'] ?? first['text'] ?? '';
      reasoning = switch (source) {
        'deepseek' => firstTruthy('delta', 'reasoning_content'),
        'openrouter' =>
          firstTruthy('delta', 'reasoning') ??
              firstTruthy('delta', 'reasoning_content') ??
              firstTruthy('message', 'reasoning') ??
              firstTruthy('message', 'reasoning_content'),
        'custom' => firstTruthy('delta', 'reasoning_content') ?? firstTruthy('delta', 'reasoning'),
        _ => '',
      };
    } else {
      final topMessage = _map(frame['message']);
      final topParts = topMessage['content'];
      text =
          message['content'] ??
          first['text'] ??
          frame['text'] ??
          (topParts is List<Object?> && topParts.isNotEmpty ? _map(topParts.first)['text'] : null) ??
          topMessage['tool_plan'] ??
          '';
      reasoning = switch (source) {
        'deepseek' => message['reasoning_content'],
        'openrouter' => message['reasoning'] ?? message['reasoning_content'],
        'custom' => message['reasoning_content'] ?? message['reasoning'],
        _ => '',
      };
    }
    String string(Object? value, String path) {
      if (value == null) return '';
      if (value is String) return value;
      throw _scriptError(
        TavernScriptErrorCode.unsupportedCapability,
        'helperGenerate',
        'The text generation result cannot represent this structured response field.',
        fieldPath: path,
      );
    }

    return (text: string(text, 'response.content'), reasoning: string(reasoning, 'response.reasoning'));
  }
}

/// Uses the production decoder's complete parsed response frames. Returned
/// metadata never replaces core replay proof or buffers another HTTP body.
class _HelperResponseCapture {
  _HelperResponseCapture({required this.streaming, required this.source, required this.hasTools});
  final bool streaming;
  final String source;
  final bool hasTools;
  final fallback = <ModelToolFragment>[];
  final calls = <int, Map<String, Object?>>{};
  final _callsByChoice = <int, Map<int, Map<String, Object?>>>{};
  int? _streamingChoice;
  final signatures = <String, String>{};
  String? reasoningSignature;
  Map<String, Object?>? _nonstream;
  int? attempt;
  bool framed = false;
  bool _read = false;

  void started(int number, int status, Map<String, String> headers) {
    attempt = number;
    fallback.clear();
    calls.clear();
    _callsByChoice.clear();
    _streamingChoice = null;
    signatures.clear();
    reasoningSignature = null;
    _nonstream = null;
    framed = false;
    _read = false;
  }

  Map<String, Object?>? get nonStreamingChoice {
    final raw = nonStreamingResponse;
    if (raw == null) return null;
    final choice = _spRows(raw['choices']).firstOrNull;
    return choice == null ? null : _captureScriptObject(choice);
  }

  Map<String, Object?>? get nonStreamingResponse {
    if (streaming || _nonstream == null) return null;
    return _captureScriptObject(_nonstream!);
  }

  void decodedFrame(int number, bool isStreaming, Map<String, Object?> value) {
    if (attempt != null && number != attempt) return;
    if (isStreaming) {
      frame(value);
    } else {
      _nonstream = _captureScriptObject(value);
    }
  }

  /// The first response array item owns the Helper body. Keep that identity
  /// when later frames reorder choices or contain only another choice. This
  /// deliberately repairs the upstream cross-choice behavior (ADDENDUM-14).
  Map<String, Object?> selectStreamingChoice(List<Map<String, Object?>> choices) {
    if (choices.isEmpty) return const {};
    _streamingChoice ??= _choiceIndex(choices.first, 0);
    for (final (ordinal, choice) in choices.indexed) {
      if (_choiceIndex(choice, ordinal) == _streamingChoice) return choice;
    }
    return const {};
  }

  static int _choiceIndex(Map<String, Object?> choice, int ordinal) {
    final index = choice['index'];
    return index is num && index.isFinite && index >= 0 && index == index.truncateToDouble() ? index.toInt() : ordinal;
  }

  /// Called after all deltas of exactly one production-decoded event. Neither
  /// an unterminated EOF record nor data after [DONE] reaches this boundary.
  void frame(Map<String, Object?> value) {
    framed = true;
    final choices = _spRows(value['choices']);
    final selected = selectStreamingChoice(choices);
    if (selected.isNotEmpty) {
      _readSignatures(_map(selected['delta']), append: true);
      _readSignatures(_map(selected['message']), append: true);
    }
    for (final (ordinal, choice) in choices.indexed) {
      _readCalls(
        _map(choice['delta']),
        append: true,
        target: _callsByChoice.putIfAbsent(_choiceIndex(choice, ordinal), () => {}),
      );
    }
  }

  void _readSignatures(Map<String, Object?> value, {required bool append}) {
    if (source != 'openrouter') return;
    for (final raw
        in value['reasoning_details'] is List<Object?> ? value['reasoning_details']! as List<Object?> : const []) {
      if (raw is! Map<String, Object?> ||
          raw['type'] != 'reasoning.encrypted' ||
          raw['data'] is! String ||
          raw['data'] == '') {
        continue;
      }
      final id = raw['id'];
      final toolId = id is String && (id.startsWith('tool_') || id.startsWith('call_'));
      if (id is String && id.isNotEmpty && (append || toolId)) signatures[id] = raw['data']! as String;
      if (!toolId) {
        if (append) {
          reasoningSignature = raw['data']! as String;
        } else {
          reasoningSignature ??= raw['data']! as String;
        }
      }
    }
  }

  void _readCalls(Map<String, Object?> value, {required bool append, Map<int, Map<String, Object?>>? target}) {
    final destination = target ?? calls;
    final rawCalls = value['tool_calls'];
    if (rawCalls is! List<Object?>) return;
    for (final (ordinal, raw) in rawCalls.indexed) {
      final item = _map(raw);
      final rawIndex = item['index'];
      // Non-integer/negative JS array properties are not returned by filter.
      if (append &&
          rawIndex is num &&
          (!rawIndex.isFinite || rawIndex < 0 || rawIndex != rawIndex.truncateToDouble())) {
        continue;
      }
      final index = append && rawIndex is num
          ? rawIndex.toInt()
          : append
          ? 0
          : ordinal;
      if (append) {
        _merge(destination.putIfAbsent(index, () => {}), item);
      } else {
        destination[index] = _captureScriptObject(item);
      }
    }
  }

  static void _merge(Map<String, Object?> target, Map<String, Object?> delta) {
    for (final entry in delta.entries) {
      if (entry.key == '__proto__' || entry.key == 'constructor') continue;
      final value = entry.value;
      final previous = target[entry.key];
      if (value is String) {
        target[entry.key] = previous is String ? '$previous$value' : value;
      } else if (value is Map<String, Object?>) {
        final nested = previous is Map<String, Object?> ? previous : <String, Object?>{};
        target[entry.key] = nested;
        _merge(nested, value);
      } else {
        // Null clears an earlier object; arrays and primitives replace it.
        target[entry.key] = value;
      }
    }
  }

  void _readFallback(ModelAssistantSnapshot? finalSnapshot) {
    if (_read || framed) return;
    _read = true;
    if (!streaming && nonStreamingResponse != null) {
      final message = _map(nonStreamingChoice?['message']);
      _readSignatures(message, append: false);
      _readCalls(message, append: false);
    } else if ((!streaming || fallback.isEmpty) && finalSnapshot != null) {
      _readSignatures(finalSnapshot.wireMessage, append: false);
      _readCalls(finalSnapshot.wireMessage, append: false);
    } else {
      for (final fragment in fallback) {
        _readCalls({
          'tool_calls': [
            {
              'index': fragment.index ?? 0,
              'id': ?fragment.id,
              'function': {'name': ?fragment.name, 'arguments': ?fragment.arguments},
            },
          ],
        }, append: true);
      }
    }
  }

  TavernHelperGenerationMetadata finish(ModelAssistantSnapshot? finalSnapshot) {
    _readFallback(finalSnapshot);
    final selected = streaming && framed
        ? _callsByChoice[_streamingChoice] ?? const <int, Map<String, Object?>>{}
        : calls;
    // Helper streaming does not run the SPreset fetch tool-consumption hook.
    // The native decoder's index-zero snapshot may describe a different
    // choice, so absence there cannot erase this selected choice's calls.
    final consumed =
        !(streaming && framed) && finalSnapshot != null && !finalSnapshot.wireMessage.containsKey('tool_calls');
    final indices = selected.keys.toList()..sort();
    return TavernHelperGenerationMetadata(
      reasoningSignature: reasoningSignature,
      toolCalls: [
        if (hasTools && !consumed)
          for (final index in indices) _call(selected[index]!),
      ],
    );
  }

  TavernHelperToolCall _call(Map<String, Object?> value) {
    final id = value['id'] is String ? value['id']! as String : _helperCallId();
    final function = _map(value['function']);
    final arguments = function['arguments'] ?? value['input'] ?? value['args'];
    Object? signature =
        value['thought_signature'] ??
        value['thoughtSignature'] ??
        (streaming ? value['signature'] : signatures[id] ?? value['signature']);
    if (streaming && !presetTruthy(signature)) signature = signatures[id];
    return TavernHelperToolCall(
      id: id,
      name: _string(function['name'] ?? value['name']),
      arguments: arguments is String ? arguments : jsonEncode(arguments ?? <String, Object?>{}),
      thoughtSignature: signature is String && signature.isNotEmpty ? signature : null,
    );
  }
}

String _helperCallId() {
  final bytes = _newStateId();
  final variant = (int.parse(bytes[16], radix: 16) & 3 | 8).toRadixString(16);
  return '${bytes.substring(0, 8)}-${bytes.substring(8, 12)}-4${bytes.substring(13, 16)}-'
      '$variant${bytes.substring(17, 20)}-${bytes.substring(20)}';
}
