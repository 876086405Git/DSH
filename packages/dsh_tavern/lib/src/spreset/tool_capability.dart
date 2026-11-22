part of '../spreset.dart';

/// Optional factual catalog lookup for native streaming tool formatting.
/// Existing TavernScriptHost implementations need not implement this interface.
/// Read the active chat page's actual catalog, taking its first strictly equal
/// model id. An id-only list is not evidence of absent capability fields.
///
/// A synchronous result preserves the decoder's synchronous observation path.
/// A Future must settle after cancellation or page teardown; cancellation and
/// host replacement prevent its result from being adopted. Do not fetch a new
/// catalog for each packet when the App already owns the current local data.
abstract interface class TavernSPresetToolCapabilityHost {
  FutureOr<TavernSPresetToolModelLookup> lookupSPresetToolModel(
    TavernSPresetToolCapabilityRequest request,
    TavernScriptCancellation cancellation,
  );
}

/// The connection captured for this generation, before FinalRequestProcessing
/// changes its wire body. Public generation ids can be reused; this request is
/// answered by the returned value/Future, not by matching that id alone.
final class TavernSPresetToolCapabilityRequest {
  const TavernSPresetToolCapabilityRequest({
    required this.generationId,
    required this.chatId,
    required this.source,
    required this.model,
  });
  final String generationId, chatId, source, model;
  Map<String, Object?> toJson() => {'generationId': generationId, 'chatId': chatId, 'source': source, 'model': model};
}

enum TavernSPresetToolModelLookupKind { notSupplied, noMatch, matched }

/// Keep unavailable catalog evidence distinct from an actual empty/no-match
/// catalog and from a matching row whose capability field is absent. The first
/// two use ST's empty-catalog provider fallback, without certifying the model.
final class TavernSPresetToolModelLookup {
  const TavernSPresetToolModelLookup.notSupplied({this.reason})
    : kind = TavernSPresetToolModelLookupKind.notSupplied,
      _row = null;
  const TavernSPresetToolModelLookup.noMatch()
    : kind = TavernSPresetToolModelLookupKind.noMatch,
      _row = null,
      reason = null;
  TavernSPresetToolModelLookup.matched(Map<String, Object?> row)
    : kind = TavernSPresetToolModelLookupKind.matched,
      _row = _spObjectCopy(row),
      reason = null;

  final TavernSPresetToolModelLookupKind kind;
  final String? reason;
  final Map<String, Object?>? _row;
  Map<String, Object?>? get row => _row == null ? null : _spObjectCopy(_row);
}

/// Catalog portion of ST 1.19 ToolManager.isToolCallingSupported, fixed at
/// 7e8663cd9c184a550b37238218bdd32c6efc68e9, tool-calling.js:638-690.
/// This reads metadata for formatting; it does not authorize tool actions.
/// Common preset/API/model gates remain with the generation's captured inputs.
bool spresetToolModelSupportsTools(String source, TavernSPresetToolModelLookup lookup) {
  final row = lookup._row;
  if (lookup.kind == TavernSPresetToolModelLookupKind.matched && row != null) {
    switch (source) {
      case 'pollinations':
        return presetTruthy(row['tools']);
      case 'fireworks':
        return presetTruthy(row['supports_tools']);
      case 'openrouter':
        return _spresetCapabilityIncludes(row['supported_parameters'], 'tools');
      case 'mistralai':
        return presetTruthy(_spMap(row['capabilities'])['function_calling']);
      case 'aimlapi':
        return _spresetCapabilityIncludes(row['features'], 'openai/chat-completion.function');
      case 'chutes':
        return _spresetCapabilityIncludes(row['supported_features'], 'tools');
      case 'electronhub':
        return presetTruthy(_spMap(row['metadata'])['function_call']);
      case 'workers_ai':
        final properties = row['properties'];
        if (properties is! List<Object?>) return false;
        for (final property in properties) {
          if (property == null) {
            throw const SPresetException('ToolCapability', 'Cannot read property_id of a null model property.');
          }
          final item = _spMap(property);
          if (item['property_id'] == 'function_calling' && item['value'] == 'true') return true;
        }
        return false;
    }
  }
  return const {
    'openai',
    'custom',
    'mistralai',
    'claude',
    'openrouter',
    'aimlapi',
    'groq',
    'cohere',
    'deepseek',
    'makersuite',
    'vertexai',
    'ai21',
    'xai',
    'pollinations',
    'moonshot',
    'fireworks',
    'cometapi',
    'chutes',
    'electronhub',
    'azure_openai',
    'zai',
    'siliconflow',
    'nanogpt',
    'workers_ai',
    'minimax',
  }.contains(source);
}

bool _spresetCapabilityIncludes(Object? value, String needle) {
  if (value == null) return false;
  if (value is List<Object?>) return value.contains(needle);
  if (value is String) return value.contains(needle);
  throw const SPresetException('ToolCapability', 'The model capability includes member is not callable.');
}
