// Adapted from SillyTavern src/prompt-converters.js and
// src/endpoints/backends/chat-completions.js (AGPL-3.0).
// Source commit: 7e8663cd9c184a550b37238218bdd32c6efc68e9 (1.19.0).
import 'dart:convert';

import 'preset.dart';
import 'post_processing.dart';
import 'prompt_types.dart';

/// The `semi_tools` path used by ST's native DeepSeek backend.
/// It preserves historical tool messages even when no new tools are configured.
/// [enhancedPrefill] identifies a verified final preset assistant, not a history
/// message. [reasoningPrefill] additionally requires the caller's thinking mode
/// and explicit target selection; it keeps that tail separate before merging.
List<PromptSegment> postProcessDeepSeek(
  List<PromptSegment> input, {
  required String userName,
  required String characterName,
  List<String> groupNames = const [],
  List<Map<String, Object?>> tools = const [],
  bool enhancedPrefill = false,
  bool reasoningPrefill = false,
  required PromptTokenCounter counter,
}) {
  final separateTail = enhancedPrefill && reasoningPrefill;
  final messages = postProcessPrompt(
    input,
    'semi_tools',
    userName: userName,
    characterName: characterName,
    groupNames: groupNames,
    counter: counter,
    separateLast: separateTail,
  );
  final hasTools = tools.isNotEmpty || messages.any((message) => message.message['role'] == 'tool');
  if ((!hasTools || enhancedPrefill) && messages.last.message['role'] == 'assistant') {
    final last = messages.last;
    final message = {...last.message, 'prefix': true};
    if (separateTail) {
      message['reasoning_content'] = _reasoningPrefixText(message['content']! as String);
      message['content'] = '';
    }
    messages[messages.length - 1] = _segment(last, message, counter);
  }
  for (var i = 0; i < messages.length; i++) {
    final item = messages[i];
    if (item.message['tool_calls'] is List<Object?> && !item.message.containsKey('reasoning_content')) {
      messages[i] = _segment(item, {...item.message, 'reasoning_content': ''}, counter);
    }
  }
  return messages;
}

PromptSegment _segment(PromptSegment original, Map<String, Object?> message, PromptTokenCounter counter) =>
    PromptSegment(
      id: original.id,
      message: message,
      sources: original.sources,
      collectionId: original.collectionId,
      tokens: counter.countMessage(_countable(message)),
    );

Map<String, Object?> _countable(Map<String, Object?> message) {
  final reasoning = message['reasoning_content'];
  final content = message['content'];
  // Include CoT input in the existing role/content counter contract.
  return {
    'role': message['role'],
    'content': reasoning is String && reasoning.isNotEmpty
        ? [reasoning, if (content is String && content.isNotEmpty) content].join('\n\n')
        : content,
    if (message.containsKey('name')) 'name': message['name'],
  };
}

// Prefix tag behavior follows the MIT dsh-preset-enhance implementation,
// src/lib/deepseek-beta.mts, commit a7717ddc76f3985cf6a71ac6ee463911886b15a5.
// Copyright (c) 2026 bychv
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
String _reasoningPrefixText(String text) {
  final open = RegExp(
    r'^\s*<\s*(think|thinking)\s*>[ \t]*(?:\r?\n)?',
    caseSensitive: false,
    unicode: true,
  ).firstMatch(text);
  if (open == null) {
    return text;
  }
  final rest = text.substring(open.end);
  final close = RegExp('</\\s*${open[1]}\\s*>', caseSensitive: false, unicode: true).firstMatch(rest);
  if (close == null) {
    return rest;
  }
  final after = rest.substring(close.end).replaceFirst(RegExp(r'^\r?\n'), '');
  return '${rest.substring(0, close.start)}${after.isEmpty ? '' : '\n$after'}';
}

/// Produces the actual DeepSeek request, not the browser-to-ST intermediate body.
Map<String, Object?> deepSeekRequestBody({
  required List<PromptSegment> messages,
  required Map<String, Object?> settings,
  required String model,
  required String generationType,
  List<String> stops = const [],
  List<Map<String, Object?>> tools = const [],
  Object? toolChoice,
}) {
  final thinking = presetTruthy(settings['show_thoughts']);
  // ST applies its NaN/zero fallback before JSON turns Infinity into null.
  final topP = settings.containsKey('top_p') ? presetJsNumber(settings['top_p']) : 1;
  final effort = settings.containsKey('reasoning_effort') ? settings['reasoning_effort'] : 'auto';
  final body = <String, Object?>{
    'messages': messages.map((message) => message.message).toList(),
    'model': model,
    'temperature': _sampling(settings, 'temperature', 1),
    // Both ST's frontend and sendDeepSeekRequest forward this value unchanged;
    // only the prompt-budget calculation uses numeric coercion.
    'max_tokens': settings.containsKey('openai_max_tokens') ? settings['openai_max_tokens'] : 300,
    'stream': presetTruthy(settings['stream_openai']) && generationType != 'quiet',
    'presence_penalty': _sampling(settings, 'presence_penalty', 0),
    'frequency_penalty': _sampling(settings, 'frequency_penalty', 0),
    'top_p': topP == 0 || topP.isNaN
        ? 2.220446049250313e-16
        : topP.isFinite
        ? topP
        : null,
    if (stops.isNotEmpty) 'stop': stops.take(4).toList(),
    // ST's normal DeepSeek frontend excludes seed, though its backend accepts it.
    'thinking': {'type': thinking ? 'enabled' : 'disabled'},
    if (thinking && effort != 'auto')
      'reasoning_effort': switch (effort) {
        'min' || 'low' => 'low',
        'max' => 'max',
        _ => 'high',
      },
  };
  // Prefix turns do not mount new tools; historical tool messages survive.
  if (tools.isNotEmpty && !messages.any((message) => message.message['prefix'] == true)) {
    final copy = jsonDecode(jsonEncode(tools)) as List<Object?>;
    for (final tool in copy.whereType<Map<String, Object?>>()) {
      final function = tool['function'];
      if (function is! Map<String, Object?>) continue;
      final parameters = function['parameters'];
      if (parameters is Map<String, Object?> &&
          parameters['required'] is List<Object?> &&
          (parameters['required'] as List<Object?>).isEmpty) {
        parameters.remove('required');
      }
    }
    body['tools'] = copy;
    if (toolChoice != null) body['tool_choice'] = toolChoice;
  }
  return body;
}

num? _sampling(Map<String, Object?> settings, String key, num fallback) =>
    settings.containsKey(key) ? presetSamplingNumber(settings[key]) : fallback;
