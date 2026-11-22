part of '../spreset.dart';

bool spresetHasStructuredBinding(SPresetConfig config, String identifier) {
  final binding = _spMap(config.module('MessageInjections')[identifier]);
  return presetTruthy(binding['enabled']) &&
      (presetTruthy(binding['reasoning']) ||
          presetTruthy(binding['signature']) ||
          _spRows(binding['toolCalls']).isNotEmpty ||
          _spRows(binding['toolResults']).isNotEmpty);
}

List<PromptSegment> spresetInjectSegments(
  List<PromptSegment> input,
  SPresetConfig config,
  SPresetProvider provider,
  PromptTokenCounter counter, {
  SPresetDiagnostic? onDiagnostic,
}) {
  if (!config.present || config.module('MessageInjections').isEmpty) return input;
  final result = <PromptSegment>[];
  for (final segment in input) {
    final binding = _spMap(config.module('MessageInjections')[segment.id]);
    if (!presetTruthy(binding['enabled'])) {
      result.add(segment);
      continue;
    }
    try {
      final messages = spresetInjectMessage(segment.message, binding, provider);
      for (var index = 0; index < messages.length; index++) {
        final message = messages[index];
        result.add(
          PromptSegment(
            id: segment.id,
            message: message,
            sources: segment.sources,
            collectionId: segment.collectionId,
            tokens: counter.countMessage(message),
          ),
        );
      }
    } catch (error) {
      onDiagnostic?.call('MessageInjections', error);
      result.add(segment);
    }
  }
  return result;
}

List<Map<String, Object?>> spresetInjectMessage(
  Map<String, Object?> original,
  Map<String, Object?> binding,
  SPresetProvider provider,
) {
  final rawCalls = binding['toolCalls'];
  final rawResults = binding['toolResults'];
  if (rawCalls is! List<Object?> || rawResults is! List<Object?>) {
    throw const SPresetException('MessageInjections', 'toolCalls and toolResults must be arrays.');
  }
  final ids = <String>{};
  final calls = <Map<String, Object?>>[];
  final arguments = <Map<String, Object?>>[];
  final topSignature = _spString(binding['signature']);
  final reasoning = _spString(binding['reasoning']);
  final topSignatureOnTool =
      provider.adapter == 'gemini' ||
      (provider.adapter == 'openrouter' && RegExp(r'google/gemini', caseSensitive: false).hasMatch(provider.model));
  for (var index = 0; index < rawCalls.length; index++) {
    final call = _spMap(rawCalls[index]);
    final function = _spMap(call['function']);
    final id = trimJsWhitespace(presetTruthy(call['id']) ? _spString(call['id']) : '');
    final rawName = presetTruthy(call['name']) ? call['name'] : function['name'];
    final name = trimJsWhitespace(presetTruthy(rawName) ? _spString(rawName) : '');
    final rawArguments = call['arguments'] ?? function['arguments'] ?? <String, Object?>{};
    final args = rawArguments is String ? jsonDecode(rawArguments.isEmpty ? '{}' : rawArguments) : rawArguments;
    if (id.isEmpty || name.isEmpty || !ids.add(id) || args is! Map<String, Object?>) {
      throw const SPresetException('MessageInjections', 'Tool calls require unique ids, names and object arguments.');
    }
    arguments.add(args);
    final signature = _spString(call['signature']).isNotEmpty
        ? _spString(call['signature'])
        : topSignatureOnTool && index == 0
        ? topSignature
        : '';
    calls.add({
      'id': id,
      'type': 'function',
      'function': {'name': name, 'arguments': jsonEncode(args)},
      if (signature.isNotEmpty) 'signature': signature,
    });
  }
  final results = <Map<String, Object?>>[];
  for (final raw in rawResults) {
    final result = _spMap(raw);
    final rawId = presetTruthy(result['toolCallId']) ? result['toolCallId'] : result['tool_call_id'];
    final id = trimJsWhitespace(presetTruthy(rawId) ? _spString(rawId) : '');
    if (id.isEmpty) throw const SPresetException('MessageInjections', 'Tool results require toolCallId.');
    final value = result.containsKey('content') ? result['content'] : '';
    results.add({
      'id': id,
      'content': value is String ? value : jsonEncode(value),
      'isError': presetTruthy(result['isError'] ?? result['is_error']),
    });
  }
  final message = _spObjectCopy(original);
  final placeholder = message['content'] == '\u200b';
  if (placeholder) message['content'] = '';
  final claudeThinking = provider.adapter == 'claude' && reasoning.isNotEmpty && topSignature.isNotEmpty;
  final existingCalls = _spRows(original['tool_calls']);
  final assistant =
      calls.isNotEmpty ||
      (provider.adapter == 'gemini' && existingCalls.isNotEmpty) ||
      claudeThinking ||
      (const {'gemini', 'openrouter'}.contains(provider.adapter) &&
          (reasoning.isNotEmpty || topSignature.isNotEmpty)) ||
      (provider.adapter == 'deepseek' && reasoning.isNotEmpty);
  if (assistant) message['role'] = 'assistant';
  if (provider.adapter == 'claude' && (claudeThinking || calls.isNotEmpty)) {
    final content = <Object?>[
      if (claudeThinking) {'type': 'thinking', 'thinking': reasoning, 'signature': topSignature},
    ];
    final baseContent = original['content'];
    if (baseContent is List<Object?>) {
      content.addAll(_spCopy(baseContent)! as List<Object?>);
    } else if (!placeholder && baseContent != null && _spString(baseContent).isNotEmpty) {
      content.add({'type': 'text', 'text': _spString(baseContent)});
    }
    for (var i = 0; i < calls.length; i++) {
      content.add({
        'type': 'tool_use',
        'id': calls[i]['id'],
        'name': _spMap(calls[i]['function'])['name'],
        'input': _spCopy(arguments[i]),
      });
    }
    message['content'] = content;
    for (final key in const ['tool_calls', 'tool_call_id', 'reasoning', 'reasoning_content', 'signature']) {
      message.remove(key);
    }
  } else if (provider.adapter == 'gemini') {
    if (calls.isNotEmpty || existingCalls.isNotEmpty) {
      final baseContent = original['content'];
      final parts = baseContent is List<Object?>
          ? _spCopy(baseContent)! as List<Object?>
          : <Object?>[
              if (!placeholder && baseContent != null && _spString(baseContent).isNotEmpty)
                {'type': 'text', 'text': _spString(baseContent)},
            ];
      final normalized = <Object?>[];
      final mergedCalls = <Map<String, Object?>>[];
      final seen = <String>{};
      int? position;
      void appendCall(Map<String, Object?> call) {
        final id = _spString(call['id']);
        if (seen.add(id.isEmpty ? jsonEncode(call) : 'id:$id')) mergedCalls.add(call);
      }

      for (final part in parts) {
        if (part is Map<String, Object?> && part['type'] == 'tool_calls' && part['tool_calls'] is List<Object?>) {
          position ??= normalized.length;
          _spRows(part['tool_calls']).forEach(appendCall);
        } else {
          normalized.add(part is String ? {'type': 'text', 'text': part} : part);
        }
      }
      existingCalls.forEach(appendCall);
      calls.forEach(appendCall);
      normalized.insert(position ?? normalized.length, {'type': 'tool_calls', 'tool_calls': mergedCalls});
      message['content'] = normalized;
      message.remove('tool_calls');
    }
    if (reasoning.isNotEmpty) message['reasoning'] = reasoning;
    final moved =
        calls.isNotEmpty &&
        _spString(_spMap(rawCalls.first)['signature']).isEmpty &&
        calls.first['signature'] == topSignature;
    if (topSignature.isNotEmpty && !moved) message['signature'] = topSignature;
  } else {
    if (calls.isNotEmpty) message['tool_calls'] = calls;
    if (provider.adapter == 'openrouter') {
      if (reasoning.isNotEmpty) message['reasoning'] = reasoning;
      final moved =
          calls.isNotEmpty &&
          _spString(_spMap(rawCalls.first)['signature']).isEmpty &&
          calls.first['signature'] == topSignature;
      if (topSignature.isNotEmpty && !moved) message['signature'] = topSignature;
    } else if (provider.adapter == 'deepseek') {
      if (reasoning.isNotEmpty) message['reasoning_content'] = reasoning;
      message.remove('signature');
    }
  }
  return [
    if (!(placeholder && !assistant && results.isNotEmpty)) message,
    if (results.isNotEmpty && provider.adapter == 'claude')
      {
        'role': 'user',
        'content': [
          for (final result in results)
            {
              'type': 'tool_result',
              'tool_use_id': result['id'],
              'content': result['content'],
              if (result['isError'] == true) 'is_error': true,
            },
        ],
      }
    else
      for (final result in results) {'role': 'tool', 'tool_call_id': result['id'], 'content': result['content']},
  ];
}

class SPresetTool {
  const SPresetTool({required this.identifier, required this.code, required this.sessionId, required this.definition});
  final String identifier, code, sessionId;
  final Map<String, Object?> definition;
  String get name => definition['name']! as String;
  Map<String, Object?> get wire => {
    'type': 'function',
    'function': {'name': name, 'description': definition['description'], 'parameters': definition['parameters']},
  };
}

Future<List<SPresetTool>> resolveSPresetTools(
  SPresetConfig config,
  Map<String, Object?> preset,
  SPresetEvaluate evaluate,
  SPresetDiagnostic diagnose, {
  bool synchronizeEmpty = false,
  String registryMode = 'sync',
  void Function(Set<String>)? onRegistryModes,
}) async {
  final active = <String>{};
  for (final group in _spRows(preset['prompt_order'])) {
    if (_spString(group['character_id']) != '100001') continue;
    for (final row in _spRows(group['order'])) {
      if (row['enabled'] != false) active.add(_spString(row['identifier']));
    }
    break;
  }
  final bindings = <Map<String, Object?>>[];
  for (final entry in config.module('ToolBindings').entries) {
    final binding = _spMap(entry.value);
    if (!active.contains(entry.key) || !presetTruthy(binding['enabled']) || !presetTruthy(binding['valid'])) continue;
    bindings.add({
      'identifier': entry.key,
      'code': _spString(binding['code']),
      if (binding.containsKey('uuid')) 'uuid': binding['uuid'],
    });
  }
  if (registryMode == 'sync' && bindings.isEmpty && !synchronizeEmpty) return const [];
  final result = <SPresetTool>[];
  try {
    // One registry synchronization preserves UUID sharing, the transient
    // evaluation cache, unregister/prune order and retained registrations.
    final response = await evaluate(
      'ToolBindings',
      '',
      [
        {
          if (registryMode != 'read') 'bindings': bindings,
          'activeIdentifiers': active.toList(),
          if (registryMode != 'sync') 'registryMode': registryMode,
        },
      ],
      sessionId: 'tool-registry',
      kind: TavernSPresetEvaluationKind.toolRegistry,
    );
    final registry = _spMap(response.value);
    if (registryMode != 'sync' && registry['registryMode'] != registryMode) {
      throw SPresetException('ToolBindings', 'The host did not acknowledge tool registry mode $registryMode.');
    }
    if (registry['registryModes'] case final List<Object?> modes) {
      onRegistryModes?.call(modes.whereType<String>().toSet());
    }
    if (registry['tools'] is! List<Object?>) {
      throw const SPresetException('ToolBindings', 'Host must return a synchronized tool registry.');
    }
    for (final diagnostic in _spRows(registry['diagnostics'])) {
      diagnose(
        'ToolBindings',
        SPresetException('ToolBindings', '${_spString(diagnostic['identifier'])}: ${_spString(diagnostic['message'])}'),
      );
    }
    final names = <String>{};
    for (final registered in _spRows(registry['tools'])) {
      final definition = registered['definition'];
      if (definition is! Map<String, Object?> ||
          definition['name'] is! String ||
          trimJsWhitespace(definition['name']! as String).isEmpty ||
          definition['description'] is! String ||
          (!definition.containsKey('parameters') ||
              definition['parameters'] != null &&
                  definition['parameters'] is! Map<String, Object?> &&
                  definition['parameters'] is! List<Object?>) ||
          definition['hasAction'] != true) {
        throw const SPresetException('ToolBindings', 'Host must return name, description, parameters and hasAction.');
      }
      final name = definition['name']! as String;
      if (!names.add(name)) throw SPresetException('ToolBindings', 'Duplicate tool name: $name');
      result.add(
        SPresetTool(
          identifier: _spString(registered['identifier']),
          code: _spString(registered['code']),
          sessionId: _spString(registered['sessionId']),
          definition: definition,
        ),
      );
    }
  } catch (error) {
    diagnose('ToolBindings', error);
    if (registryMode != 'sync') rethrow;
  }
  return result;
}

Future<Map<String, Object?>> spresetFinalRequest(
  SPresetConfig config,
  Map<String, Object?> request,
  SPresetProvider provider,
  SPresetEvaluate evaluate, {
  String? requestSource,
}) async {
  final module = config.module('FinalRequestProcessing');
  if (!presetTruthy(module['enabled'])) return request;
  final input = {
    'request': _spObjectCopy(request),
    'provider': provider.toJson(),
    'model': _spString(request['model'], provider.model),
    'source': requestSource ?? _spString(request['chat_completion_source'], provider.source),
    'stream': request['stream'] == true,
    'preview': false,
  };
  final result = await evaluate('FinalRequestProcessing', _spString(module['script']), [input]);
  final value = result.isUndefined && result.arguments.isNotEmpty
      ? _spMap(result.arguments.first)['request']
      : result.value;
  if (value is! Map<String, Object?>) {
    throw const SPresetException('FinalRequestProcessing', 'Script must return or mutate a request object.');
  }
  final output = _spObjectCopy(value);
  if (output['stream'] != request['stream'] || output['chat_completion_source'] != request['chat_completion_source']) {
    throw const SPresetException('FinalRequestProcessing', 'stream and chat_completion_source cannot change.');
  }
  return output;
}
