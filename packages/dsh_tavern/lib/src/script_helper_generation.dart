part of 'scripts.dart';

/// Explicit Helper semantics, separate from the native background request API.
abstract interface class TavernHelperGenerationRequest {
  TavernHelperGenerationOptions get helperOptions;
  TavernJsonObject toHelperJson();
}

final class TavernHelperGenerateRequest extends TavernScriptGenerateRequest implements TavernHelperGenerationRequest {
  factory TavernHelperGenerateRequest.fromJson(TavernJsonObject json) =>
      TavernHelperGenerateRequest._(TavernHelperGenerationOptions._read(json, raw: false));

  TavernHelperGenerateRequest._(this.helperOptions)
    : super(
        generationId: helperOptions.generationId,
        userInput: helperOptions.userInput,
        stream: helperOptions.stream,
        includeReasoning: helperOptions.returnReasoning,
        silent: helperOptions.silent,
        overrides: helperOptions.nativeOverrides,
        injects: helperOptions.nativeInjections,
      );

  @override
  final TavernHelperGenerationOptions helperOptions;
  @override
  TavernJsonObject toHelperJson() => helperOptions.toJson();
}

final class TavernHelperRawRequest extends TavernScriptRawRequest implements TavernHelperGenerationRequest {
  factory TavernHelperRawRequest.fromJson(TavernJsonObject json) =>
      TavernHelperRawRequest._(TavernHelperGenerationOptions._read(json, raw: true));

  TavernHelperRawRequest._(this.helperOptions)
    : super(
        orderedPrompts: helperOptions.orderedPrompts,
        generationId: helperOptions.generationId,
        userInput: helperOptions.userInput,
        stream: helperOptions.stream,
        includeReasoning: helperOptions.returnReasoning,
        silent: helperOptions.silent,
        overrides: helperOptions.nativeOverrides,
        injects: const [],
      );

  @override
  final TavernHelperGenerationOptions helperOptions;
  @override
  TavernJsonObject toHelperJson() => helperOptions.toJson();
}

/// JSON-only capture. App File objects become data URI strings before this boundary.
final class TavernHelperGenerationOptions {
  TavernHelperGenerationOptions._read(TavernJsonObject json, {required this.raw}) : _json = _scriptObject(json) {
    final id = _scriptOptionalString(_json, 'generation_id');
    generationId = id == '' ? null : id;
    userInput = _scriptDefaultString(_json, 'user_input', '');
    stream = _scriptDefaultBool(_json, 'should_stream');
    silent = _scriptDefaultBool(_json, 'should_silence');
    returnReasoning = _scriptDefaultBool(_json, 'should_return_reasoning');
    presetName = _scriptDefaultString(_json, 'preset_name', 'in_use');
    final maximum = _json['max_chat_history'];
    if (_json.containsKey('max_chat_history') && maximum != 'all' && maximum is! num) {
      throw _scriptDtoError('max_chat_history', 'Expected all or a finite number.');
    }
    maxChatHistory = maximum is num ? maximum.toInt() : null;
    images = _helperImages(_json, 'image');
    customApi = _json.containsKey('custom_api')
        ? TavernHelperCustomApi.fromJson(_scriptDefaultObject(_json, 'custom_api'))
        : null;
    _tools = _helperTools(_json);
    _toolChoice = _helperToolChoice(_json);
    _jsonSchema = _helperJsonSchema(_json);
    final overrides = _scriptDefaultObject(_json, 'overrides');
    final native = <String, Object?>{};
    for (final entry in overrides.entries) {
      if (entry.key != 'chat_history' && entry.key != 'user_input' && _helperPlaceholderNames.containsKey(entry.key)) {
        if (entry.value is! String) throw _scriptDtoError('overrides.${entry.key}', 'Expected a string.');
        native[_helperPlaceholderNames[entry.key]!.name] = entry.value;
      }
    }
    final chat = _scriptDefaultObject(overrides, 'chat_history');
    if (chat.containsKey('with_depth_entries')) {
      if (chat['with_depth_entries'] is! bool) {
        throw _scriptDtoError('overrides.chat_history.with_depth_entries', 'Expected a boolean.');
      }
      native['withDepthEntries'] = chat['with_depth_entries'];
    }
    if (chat.containsKey('author_note')) {
      if (chat['author_note'] is! String) {
        throw _scriptDtoError('overrides.chat_history.author_note', 'Expected a string.');
      }
      native['authorNote'] = chat['author_note'];
    }
    final capturedImages = <int, List<String>>{};
    if (chat.containsKey('prompts')) {
      final prompts = chat['prompts'];
      if (prompts is! List<Object?>) {
        throw _scriptDtoError('overrides.chat_history.prompts', 'Expected a list.');
      }
      native['chatHistory'] = [
        for (final (index, prompt) in prompts.indexed)
          _helperRolePrompt(
            prompt,
            'overrides.chat_history.prompts[$index]',
            onImages: (value) {
              if (value.isNotEmpty) capturedImages[index] = value;
            },
          ),
      ];
    }
    historyImages = Map.unmodifiable(capturedImages);
    nativeOverrides = TavernScriptPromptOverrides(fields: native);
    nativeInjections = _helperInjections(_json, raw: raw);
    final ignoredImages = <int>[];
    orderedPrompts = raw ? _helperOrderedPrompts(_json, ignoredImages) : const [];
    ignoredLiteralImages = List.unmodifiable(ignoredImages);
  }

  final bool raw;
  final TavernJsonObject _json;
  late final String? generationId;
  late final String userInput, presetName;
  late final bool stream, silent, returnReasoning;
  late final int? maxChatHistory;
  late final List<String> images;
  late final Map<int, List<String>> historyImages;
  late final TavernHelperCustomApi? customApi;
  late final List<TavernJsonObject> _tools;
  late final Object? _toolChoice;
  late final TavernJsonObject? _jsonSchema;
  late final TavernScriptPromptOverrides nativeOverrides;
  late final List<TavernScriptInjection> nativeInjections;
  late final List<TavernScriptPromptPart> orderedPrompts;
  late final List<int> ignoredLiteralImages;
  List<TavernJsonObject> get tools => [for (final tool in _tools) _scriptObject(tool)];
  Object? get toolChoice => _scriptCopy(_toolChoice);
  TavernJsonObject? get jsonSchema => _jsonSchema == null ? null : _scriptObject(_jsonSchema);
  TavernJsonObject toJson() => _scriptObject(_json);
}

final class TavernHelperCustomApi {
  TavernHelperCustomApi.fromJson(TavernJsonObject json) : _json = _scriptObject(json) {
    for (final key in const ['proxy_preset', 'apiurl', 'key', 'model', 'source']) {
      if (_json.containsKey(key) && _json[key] is! String) {
        throw _scriptDtoError('custom_api.$key', 'Expected a string.');
      }
    }
    for (final key in samplingKeys) {
      if (!_json.containsKey(key)) continue;
      final value = _json[key];
      if (value is! num && value != 'same_as_preset' && value != 'unset') {
        throw _scriptDtoError('custom_api.$key', 'Expected a finite number, same_as_preset or unset.');
      }
    }
    for (final key in const ['custom_include_body', 'custom_include_headers']) {
      if (_json.containsKey(key) && _json[key] is! Map<String, Object?>) {
        throw _scriptDtoError('custom_api.$key', 'Expected an object.');
      }
    }
    if (_json.containsKey('custom_exclude_body')) {
      final values = _json['custom_exclude_body'];
      if (values is! List<Object?> || values.any((value) => value is! String)) {
        throw _scriptDtoError('custom_api.custom_exclude_body', 'Expected a list of strings.');
      }
    }
  }

  static const samplingKeys = {'max_tokens', 'temperature', 'frequency_penalty', 'presence_penalty', 'top_p', 'top_k'};
  final TavernJsonObject _json;
  TavernJsonObject toJson() => _scriptObject(_json);
}

/// Optional shared engine capability. These operations cover only Helper tasks.
abstract interface class TavernHelperGenerationControl {
  TavernHelperGenerationControlState get helperGenerationState;
  Stream<TavernHelperGenerationControlState> watchHelperGenerations();
  Future<bool> stopHelperGenerationById(String generationId);
  Future<bool> stopAllHelperGenerations();
  Future<int> stopNonSilentHelperGenerations();
}

final class TavernHelperGenerationControlState {
  TavernHelperGenerationControlState({required List<String> activeIds, required List<String> nonSilentIds})
    : activeIds = List.unmodifiable(activeIds),
      nonSilentIds = List.unmodifiable(nonSilentIds);
  final List<String> activeIds, nonSilentIds;
  bool get blocksMainGeneration => nonSilentIds.isNotEmpty;
}

/// A named proxy is supplied by the App's actual proxy settings, never invented.
abstract interface class TavernHelperProxyHost {
  Future<TavernHelperProxy?> resolveHelperProxy(String name, TavernScriptCancellation cancellation);
}

final class TavernHelperProxy {
  const TavernHelperProxy({required this.url, required this.key});
  final String url, key;
}

/// An App may resolve URL images when its network/File layer owns that work.
/// Report only actual download/base64 failures with
/// [TavernHelperImageConversionFailure]. These follow the source's undefined
/// result and produce a visible issue while generation continues without that
/// image. Missing capabilities, invalid return values, cancellation and other
/// host errors remain generation failures.
abstract interface class TavernHelperImageHost {
  Future<String> resolveHelperImage(String source, TavernScriptCancellation cancellation);
}

enum TavernHelperImageConversionStage { download, base64 }

/// An observed failure inside the fixed Helper's fetch/blob/base64 try block.
/// The App must not use this type for cancellation, page replacement, an RPC
/// protocol error or an unavailable image capability.
final class TavernHelperImageConversionFailure implements Exception {
  const TavernHelperImageConversionFailure({required this.stage, required this.message});
  final TavernHelperImageConversionStage stage;
  final String message;

  @override
  String toString() => 'TavernHelperImageConversionFailure(${stage.name}): $message';
}

/// Optional factual model-catalog capability. The current page connection is
/// supplied before a per-request custom_api override; do not infer vision from
/// an OpenRouter model name or substitute the request's destination model.
abstract interface class TavernHelperImageCapabilityHost {
  Future<bool> supportsHelperModelImages(
    TavernHelperImageCapabilityRequest request,
    TavernScriptCancellation cancellation,
  );
}

final class TavernHelperImageCapabilityRequest {
  const TavernHelperImageCapabilityRequest({
    required this.generationId,
    required this.contextId,
    required this.chatId,
    required this.source,
    required this.model,
  });
  final String generationId, contextId, source, model;
  final String? chatId;
}

final class TavernHelperToolCall {
  TavernHelperToolCall({required this.id, required this.name, required this.arguments, this.thoughtSignature});
  final String id, name, arguments;
  final String? thoughtSignature;
  TavernJsonObject toJson() => {
    'id': id,
    'type': 'function',
    'function': {'name': name, 'arguments': arguments},
    if (thoughtSignature?.isNotEmpty == true) 'thought_signature': thoughtSignature,
  };
}

final class TavernHelperGenerationMetadata {
  TavernHelperGenerationMetadata({this.reasoningSignature, List<TavernHelperToolCall> toolCalls = const []})
    : toolCalls = List.unmodifiable(toolCalls);
  final String? reasoningSignature;
  final List<TavernHelperToolCall> toolCalls;

  Object toHelperValue({required String content, String? reasoning, required bool shouldReturnReasoning}) {
    if (!shouldReturnReasoning && toolCalls.isEmpty) return content;
    return <String, Object?>{
      'content': content,
      if (reasoning?.isNotEmpty == true) 'reasoning': reasoning,
      if (reasoningSignature?.isNotEmpty == true) 'reasoning_signature': reasoningSignature,
      if (toolCalls.isNotEmpty) 'tool_calls': [for (final call in toolCalls) call.toJson()],
    };
  }
}

const _helperPlaceholderNames = <String, TavernScriptPromptPlaceholder>{
  'world_info_before': TavernScriptPromptPlaceholder.worldInfoBefore,
  'persona_description': TavernScriptPromptPlaceholder.personaDescription,
  'char_description': TavernScriptPromptPlaceholder.charDescription,
  'char_personality': TavernScriptPromptPlaceholder.charPersonality,
  'scenario': TavernScriptPromptPlaceholder.scenario,
  'world_info_after': TavernScriptPromptPlaceholder.worldInfoAfter,
  'dialogue_examples': TavernScriptPromptPlaceholder.dialogueExamples,
  'chat_history': TavernScriptPromptPlaceholder.chatHistory,
  'user_input': TavernScriptPromptPlaceholder.userInput,
};

List<String> _helperImages(TavernJsonObject object, String key) {
  if (!object.containsKey(key)) return const [];
  final raw = object[key];
  final images = raw is String ? <Object?>[raw] : raw;
  if (images is! List<Object?> || images.any((image) => image is! String || image.isEmpty)) {
    throw _scriptDtoError(key, 'Expected image URL/data URI strings; encode App File objects before bridging.');
  }
  return List.unmodifiable(images.cast<String>());
}

TavernJsonObject _helperRolePrompt(Object? raw, String path, {required void Function(List<String>) onImages}) {
  if (raw is! Map<String, Object?>) throw _scriptDtoError(path, 'Expected a role prompt.');
  final role = _scriptEnum(TavernScriptPromptRole.values, raw['role'], '$path.role');
  if (raw['content'] is! String) throw _scriptDtoError('$path.content', 'Expected a string.');
  onImages(_helperImages(raw, 'image'));
  return {'role': role.name, 'content': raw['content']};
}

List<TavernScriptPromptPart> _helperOrderedPrompts(TavernJsonObject json, List<int> ignoredImages) {
  if (!json.containsKey('ordered_prompts')) {
    return List.unmodifiable([
      for (final placeholder in _helperPlaceholderNames.values) TavernScriptPromptPart.placeholder(placeholder),
    ]);
  }
  final raw = json['ordered_prompts'];
  if (raw is! List<Object?>) throw _scriptDtoError('ordered_prompts', 'Expected a list.');
  final result = <TavernScriptPromptPart>[];
  for (final (index, item) in raw.indexed) {
    final path = 'ordered_prompts[$index]';
    if (item is String) {
      // The raw control slots are located case-insensitively by upstream
      // process/handle functions. Its other system-prompt names stay exact.
      final lower = item.toLowerCase();
      final name = const {'chat_history', 'user_input', 'dialogue_examples'}.contains(lower) ? lower : item;
      final kind = _helperPlaceholderNames[name];
      if (kind == null) continue; // The fixed raw builder ignores unmatched source names.
      result.add(TavernScriptPromptPart.placeholder(kind));
    } else {
      final role = _helperRolePrompt(
        item,
        path,
        onImages: (images) {
          if (images.isNotEmpty) ignoredImages.add(index);
        },
      );
      result.add(
        TavernScriptPromptPart.literal(
          role: _scriptEnum(TavernScriptPromptRole.values, role['role'], '$path.role'),
          content: role['content']! as String,
        ),
      );
    }
  }
  return List.unmodifiable(result);
}

List<TavernScriptInjection> _helperInjections(TavernJsonObject json, {required bool raw}) {
  if (!json.containsKey('injects')) return const [];
  final rows = json['injects'];
  if (rows is! List<Object?>) throw _scriptDtoError('injects', 'Expected a list.');
  final result = <TavernScriptInjection>[];
  for (final (index, item) in rows.indexed) {
    final path = 'injects[$index]';
    if (item is! Map<String, Object?>) throw _scriptDtoError(path, 'Expected an injection object.');
    final position = item['position'] ?? 'in_chat';
    if (!raw && position != 'in_chat' && position != 'none') {
      throw _scriptDtoError('$path.position', 'Expected in_chat or none.');
    }
    result.add(
      TavernScriptInjection.fromJson({
        'id': 'helper-request-$index',
        'role': item['role'] ?? 'system',
        'content': item['content'] ?? '',
        'position': position == 'none' ? 'scanOnly' : 'inChat',
        'depth': item['depth'] ?? 0,
        if (!raw && item.containsKey('should_scan')) 'scan': item['should_scan'],
        if (!raw && item.containsKey('filter')) 'filter': item['filter'],
      }),
    );
  }
  return List.unmodifiable(result);
}

List<TavernJsonObject> _helperTools(TavernJsonObject json) {
  if (!json.containsKey('tools')) return const [];
  final raw = json['tools'];
  if (raw is! List<Object?>) throw _scriptDtoError('tools', 'Expected a list.');
  final result = <TavernJsonObject>[];
  for (final (index, value) in raw.indexed) {
    final path = 'tools[$index]';
    if (value is! Map<String, Object?>) throw _scriptDtoError(path, 'Expected a function tool.');
    final function = value['function'];
    if (value['type'] != 'function' || function is! Map<String, Object?>) {
      throw _scriptDtoError(path, 'Expected a function tool.');
    }
    if (function['name'] is! String || (function['name']! as String).isEmpty) {
      throw _scriptDtoError('$path.function.name', 'Expected a nonempty name.');
    }
    if (function.containsKey('description') && function['description'] is! String) {
      throw _scriptDtoError('$path.function.description', 'Expected a string.');
    }
    if (function.containsKey('parameters') && function['parameters'] is! Map<String, Object?>) {
      throw _scriptDtoError('$path.function.parameters', 'Expected an object.');
    }
    result.add(_scriptObject(value));
  }
  return List.unmodifiable(result);
}

Object? _helperToolChoice(TavernJsonObject json) {
  if (!json.containsKey('tool_choice')) return null;
  final value = json['tool_choice'];
  if (value is String && const {'auto', 'required', 'none', 'any'}.contains(value)) return value;
  if (value is Map<String, Object?>) {
    final function = value['function'];
    if (value['type'] == 'function' && function is Map<String, Object?>) {
      if (function['name'] is String && (function['name']! as String).isNotEmpty) return _scriptObject(value);
    }
  }
  throw _scriptDtoError('tool_choice', 'Expected a supported tool choice or named function.');
}

TavernJsonObject? _helperJsonSchema(TavernJsonObject json) {
  if (!json.containsKey('json_schema')) return null;
  final schema = _scriptDefaultObject(json, 'json_schema');
  if (schema['name'] is! String || schema['value'] is! Map<String, Object?>) {
    throw _scriptDtoError('json_schema', 'Expected a name and schema value object.');
  }
  if (schema.containsKey('description') && schema['description'] is! String) {
    throw _scriptDtoError('json_schema.description', 'Expected a string.');
  }
  if (schema.containsKey('strict') && schema['strict'] is! bool) {
    throw _scriptDtoError('json_schema.strict', 'Expected a boolean.');
  }
  return _scriptObject(schema);
}
