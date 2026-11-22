part of '../spreset.dart';

/// Owns the upstream cumulative/delta/hold protocol. Host closures are reused
/// within this session, and reset only when a provider revises an earlier prefix.
class SPresetOutputSession {
  SPresetOutputSession({
    required this.script,
    required this.evaluate,
    required this.diagnose,
    required this.stream,
    required this.sessionId,
    this.channel = 'main',
  });
  final String script, sessionId, channel;
  final SPresetEvaluate evaluate;
  final SPresetDiagnostic diagnose;
  final bool stream;
  String raw = '', output = '', hold = '';
  Object? state = <String, Object?>{};
  bool failed = false;
  bool _resetHost = false;

  Future<String> updateCumulative(String value, {bool finalChunk = false}) async {
    if (!value.startsWith(raw)) {
      raw = '';
      output = '';
      hold = '';
      state = <String, Object?>{};
      failed = false;
      _resetHost = true;
    }
    final chunk = value.substring(raw.length);
    if (chunk.isEmpty && !finalChunk) return output;
    raw = value;
    if (failed) {
      output = raw;
      return output;
    }
    try {
      final arguments = <String, Object?>{
        'buffer': hold + chunk,
        'chunk': chunk,
        'hold': hold,
        'output': output,
        'raw': raw,
        'final': finalChunk,
        'stream': stream,
        'state': state,
        'channel': channel,
      };
      final response = await evaluate(
        'OutputPreprocessing',
        script,
        [arguments],
        sessionId: sessionId,
        reset: _resetHost,
      );
      _resetHost = false;
      final value = response.value;
      String emitted;
      if (value is String) {
        emitted = value;
        hold = '';
      } else if (value is Map<String, Object?>) {
        final key = const ['output', 'emit', 'text', 'content'].where(value.containsKey).firstOrNull;
        if (key == null) throw const SPresetException('OutputPreprocessing', 'Missing output in script result.');
        emitted = _spString(value[key]);
        hold = _spString(value['hold']);
        if (value.containsKey('state')) state = value['state'];
      } else {
        throw const SPresetException('OutputPreprocessing', 'Script must return text or an output/hold object.');
      }
      // Mutating the passed state is part of the contract, even without an
      // explicit result.state. The host returns the post-call arguments.
      if (value is! Map<String, Object?> || !value.containsKey('state')) {
        if (response.arguments.isNotEmpty && _spMap(response.arguments.first).containsKey('state')) {
          state = _spMap(response.arguments.first)['state'];
        }
      }
      if (finalChunk && hold.isNotEmpty) {
        emitted += hold;
        hold = '';
      }
      output += emitted;
    } catch (error) {
      diagnose('OutputPreprocessing', error);
      failed = true;
      hold = '';
      output = raw;
    }
    return output;
  }

  Future<String> finish() => updateCumulative(raw, finalChunk: true);
}

String spresetAppendToolText(String source, String addition) => source.isEmpty
    ? addition
    : addition.isEmpty
    ? source
    : source + (source.endsWith('\n') ? '' : '\n') + addition;

List<Map<String, Object?>> _spToolCalls(Object? value) {
  final calls = <Map<String, Object?>>[];
  void visit(Object? value, [String inheritedSignature = '']) {
    if (value is List<Object?>) {
      for (final item in value) {
        visit(item, inheritedSignature);
      }
      return;
    }
    if (value is! Map<String, Object?>) return;
    final function = _spMap(value['function']);
    Object? argument;
    if (function.containsKey('arguments')) {
      argument = function['arguments'];
    } else if (value['functionCall'] is Map<String, Object?>) {
      visit(value['functionCall'], _spString(value['thoughtSignature'], inheritedSignature));
      return;
    } else if (value.containsKey('args') && (value.containsKey('name') || value.containsKey('id'))) {
      argument = value['args'];
    } else if (value.containsKey('input') &&
        (value['type'] == 'tool_use' || value.containsKey('name') || value.containsKey('id'))) {
      argument = value['input'];
    } else if (value.containsKey('arguments') && value.containsKey('name')) {
      argument = value['arguments'];
    } else if (value['function_call'] is Map<String, Object?>) {
      visit(value['function_call']);
      return;
    } else {
      for (final key in const ['tool_calls', 'toolCalls', 'calls']) {
        if (value.containsKey(key)) visit(value[key]);
      }
      return;
    }
    if (argument is String) {
      final trimmed = trimJsWhitespace(argument);
      if (trimmed.isEmpty) {
        argument = '';
      } else {
        try {
          argument = jsonDecode(trimmed);
        } on FormatException {
          if (RegExp(r'^[\[{"]').hasMatch(trimmed)) rethrow;
        }
      }
    }
    calls.add({
      'id': _spString(value['id']),
      'name': _spString(value['name'] ?? function['name']),
      'arguments': argument,
      'signature': _spString(value['signature'] ?? value['thoughtSignature'], inheritedSignature),
    });
  }

  visit(value);
  if (calls.isEmpty) throw const SPresetException('OutputPreprocessing', 'No supported tool-call arguments.');
  return calls;
}

Future<String> spresetFormatToolCalls(
  Object? value,
  Map<String, Object?> settings,
  SPresetProvider provider,
  SPresetEvaluate evaluate, {
  required bool stream,
  String channel = 'main',
}) async {
  final calls = _spToolCalls(value);
  final text = calls
      .map((call) {
        final arguments = call['arguments'];
        if (arguments is String) return arguments;
        if (arguments is Map<String, Object?> && arguments.length == 1) {
          final item = arguments.entries.first;
          if (const {'content', 'text', 'output', 'answer', 'message', 'response'}.contains(item.key) ||
              item.value is String) {
            return item.value is String ? item.value! as String : jsonEncode(item.value);
          }
        }
        return jsonEncode(arguments);
      })
      .join('\n');
  final formatter = _spMap(settings['toolCallFormatter']);
  if (!presetTruthy(formatter['enabled'])) return text;
  final response = await evaluate('ToolCallFormatter', _spString(formatter['script']), [
    {
      'calls': calls,
      'defaultText': text,
      'provider': provider.toJson(),
      'stream': stream,
      'final': true,
      'channel': channel,
    },
  ]);
  final result = response.value;
  if (result is String) return result;
  if (result is Map<String, Object?>) {
    final key = const ['output', 'text', 'content'].where(result.containsKey).firstOrNull;
    if (key != null) return _spString(result[key]);
  }
  throw const SPresetException('ToolCallFormatter', 'Script must return text or an output/text/content object.');
}
