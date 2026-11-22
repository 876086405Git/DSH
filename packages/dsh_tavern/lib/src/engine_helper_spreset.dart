part of 'engine.dart';

/// Helper owns a private StreamingProcessor and emits only js_generation_*
/// events. It does not enter SPreset's global ST stream/MESSAGE_RECEIVED hooks.
extension _HelperSPresetResponse on _SPresetGeneration {
  Stream<({ModelDelta delta, String? text})> helperResponse(
    Stream<ModelDelta> source,
    Map<String, Object?> body,
    _HelperResponseCapture capture,
  ) {
    final output = config.module('OutputPreprocessing');
    if (body['stream'] != false ||
        !config.present ||
        !presetTruthy(output['enabled']) ||
        !presetTruthy(output['consumeToolCalls'])) {
      final number = ++_response;
      return _loggedResponses.contains(number)
          ? _observeResponse(source, number)
          : source.map((delta) => (delta: delta, text: null));
    }
    return _helperFetchResponse(source, capture, output);
  }

  Stream<({ModelDelta delta, String? text})> _helperFetchResponse(
    Stream<ModelDelta> source,
    _HelperResponseCapture capture,
    Map<String, Object?> output,
  ) async* {
    final number = ++_response;
    var raw = '';
    var finished = false;
    Map<String, Object?>? originalMessage;
    try {
      var valid = false;
      try {
        // The fetch interceptor validates the configured output function even
        // though it never invokes that function as a body processor here.
        await evaluate(
          'OutputPreprocessing/validate',
          _spString(output['script']),
          const [],
          kind: TavernSPresetEvaluationKind.validateFunctionExpression,
        );
        valid = true;
      } catch (error) {
        cancellation.check();
        diagnose('OutputPreprocessing', error);
      }
      if (!valid) {
        yield* _loggedResponses.contains(number)
            ? _observeResponse(source, number)
            : source.map((delta) => (delta: delta, text: null));
        return;
      }
      final fragments = <ModelToolFragment>[];
      await for (final delta in source) {
        cancellation.check();
        if (delta is ModelText) {
          raw += delta.text;
          yield (delta: delta, text: null);
        } else if (delta is ModelToolFragment) {
          fragments.add(delta);
        } else if (delta is ModelFinished) {
          finished = true;
          originalMessage = delta.assistantSnapshot?.wireMessage;
          Map<String, Object?>? changed;
          String? finalText;
          var reason = delta.reason;
          try {
            final response = capture.nonStreamingResponse;
            if (response == null) {
              throw const SPresetException('OutputPreprocessing', 'Raw nonstream response metadata is unavailable.');
            }
            final choices = _spRows(response['choices']);
            // Format every choice on the detached response. A later formatter
            // failure restores the complete original response, not a prefix.
            for (final choice in choices) {
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
              message['content'] = _appendHelperSPResponseText(message['content'], addition);
              message.remove('tool_calls');
              message.remove('function_call');
              choice.remove('tool_calls');
              choice.remove('function_call');
              if (choice['finish_reason'] == 'tool_calls' || choice['finish_reason'] == 'function_call') {
                choice['finish_reason'] = 'stop';
              }
              if (identical(choice, choices.first)) {
                changed = message;
                finalText = _helperSPResponseText(message['content']);
                reason = choice['finish_reason'] as String?;
              }
            }
          } catch (error) {
            cancellation.check();
            diagnose('ToolCallFormatter', error);
            changed = null;
            finalText = null;
            reason = delta.reason;
          }
          if (changed == null) {
            for (final fragment in fragments) {
              yield (delta: fragment, text: null);
            }
            yield (delta: delta, text: null);
          } else {
            yield (delta: const ModelText(''), text: finalText);
            yield (
              delta: ModelFinished(
                reason,
                assistantSnapshot: ModelAssistantSnapshot.fromCustomMessage(changed, callIndexes: const []),
                finalUsageReport: delta.finalUsageReport,
              ),
              text: null,
            );
          }
        } else {
          yield (delta: delta, text: null);
        }
      }
      if (!finished) {
        for (final fragment in fragments) {
          yield (delta: fragment, text: null);
        }
      }
    } finally {
      if (_loggedResponses.contains(number)) await _writeResponseLog(number, raw, finished, originalMessage);
    }
  }
}

Object _appendHelperSPResponseText(Object? content, String addition) {
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

String _helperSPResponseText(Object? content) {
  if (content is String) return content;
  if (content == null) return '';
  throw const SPresetException('OutputPreprocessing', 'The Helper text return cannot represent this response shape.');
}
