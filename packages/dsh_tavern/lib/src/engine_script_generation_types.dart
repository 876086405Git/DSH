part of 'engine.dart';

class _ScriptGenerationNeeds {
  const _ScriptGenerationNeeds({this.history = false, this.card = false, this.worldInfo = false});
  final bool history, card, worldInfo;
}

/// Root intents, not a before/after JSON diff or an expression to evaluate again.
class _ScriptRuntimeIntentMap extends MapBase<String, Object?> {
  _ScriptRuntimeIntentMap(Map<String, Object?> initial) : _values = _runtimeCopy(initial);
  final Map<String, Object?> _values;
  final List<_GlobalWrite> writes = [];
  @override
  Object? operator [](Object? key) => _values[key];
  @override
  void operator []=(String key, Object? value) {
    writes.add(_GlobalWrite(writes.length + 1, key, true, _runtimeValue(value)));
    _values[key] = _runtimeValue(value);
  }

  @override
  Object? remove(Object? key) {
    if (key is! String) return null;
    writes.add(_GlobalWrite(writes.length + 1, key, false, null));
    return _values.remove(key);
  }

  @override
  void clear() {
    for (final key in keys.toList()) {
      remove(key);
    }
  }

  @override
  Iterable<String> get keys => _values.keys;
  @override
  bool containsKey(Object? key) => _values.containsKey(key);
  bool get hasIntents => writes.isNotEmpty;
  Map<String, Object?> applyTo(Map<String, Object?> current) {
    final result = _runtimeCopy(current);
    for (final write in writes) {
      _NativeGlobals._apply(result, write);
    }
    return result;
  }
}

class _ScriptGenerationObservation {
  const _ScriptGenerationObservation({
    required this.globalRuntime,
    required this.globalCommitted,
    this.selection,
    this.targets = const {},
  });
  final int globalRuntime;
  final String globalCommitted;
  final String? selection;
  final Map<String, String> targets;
}

class _ScriptGenerationCapture {
  _ScriptGenerationCapture({
    required this.generationId,
    required this.context,
    required this.request,
    required this.config,
    required this.at,
    required this.settings,
    required this.card,
    required this.metadata,
    required this.state,
    required this.local,
    required this.global,
    required this.observation,
    required this.injectionCandidates,
    required this.history,
    required this.contextRegexPresetSettings,
    this.chat,
    this.anchor,
    this.actorId,
    this.personaId,
    this.groupView,
    this.promptPreset,
    this.capturedChatState = false,
    this.gameplayCapture,
    this.helper,
  });
  final String generationId;
  final _ScriptContextState context;
  final TavernScriptGenerateRequest request;
  final TavernModelConfig config;
  final DateTime at;
  final StoredChat? chat;
  final String? anchor, actorId, personaId;
  final _GroupView? groupView;
  final List<StoredNode> history;
  final Map<String, Object?> settings, card, metadata, state;
  final Map<String, Object?> contextRegexPresetSettings;
  final ChatPreset? promptPreset;
  final _ScriptRuntimeIntentMap local, global;
  final _ScriptGenerationObservation observation;
  final List<_ScriptInjectionCandidate> injectionCandidates;
  final bool capturedChatState;
  final _GameplayResourceCapture? gameplayCapture;
  final _HelperRequestRuntime? helper;
  TavernScriptGenerationOrigin get origin => TavernScriptGenerationOrigin(
    contextId: context.value.id,
    instanceId: context.value.instanceId,
    provider: config.deepseek ? 'deepseek' : 'openaiCompatible',
    model: config.model,
    chatId: context.value.chatId,
    nodeAnchor: capturedChatState && chat != null && anchor != null
        ? TavernScriptMessageRef(chatId: chat!.id, nodeId: anchor!)
        : null,
    emptyChatAnchor: capturedChatState && chat != null && anchor == null,
  );
}

class _ScriptPreparedGeneration {
  _ScriptPreparedGeneration({
    required this.capture,
    required Map<String, Object?> body,
    required this.budgetSource,
    this.validateFinalBody,
    required this.injectionUses,
    Map<String, Object?> stateUpdates = const {},
    this.stChatIdHash,
    this.hasHashUpdate = false,
    List<TavernScriptIssue> hookIssues = const [],
    this.packWorldInfo,
  }) : body = _captureScriptObject(body),
       stateUpdates = _runtimeCopy(stateUpdates),
       hookIssues = List.unmodifiable(hookIssues);
  final _ScriptGenerationCapture capture;
  final Map<String, Object?> body;
  final String budgetSource;
  final void Function(Map<String, Object?>)? validateFinalBody;
  final _ScriptInjectionUseSet injectionUses;
  final Map<String, Object?> stateUpdates;
  final state_core.StatePackWorldInfoDelta? packWorldInfo;
  final num? stChatIdHash;
  final bool hasHashUpdate;
  final List<TavernScriptIssue> hookIssues;
  Set<String> get chatTargets => {
    if (capture.local.hasIntents) 'local',
    ...stateUpdates.keys,
    if (packWorldInfo?.isEmpty == false) 'dshgoPackWorldInfo',
    if (hasHashUpdate) 'stChatIdHash',
  };
}

class _ScriptGenerationReceipt {
  bool accepted = false;
  String phase = 'capture';
  String budgetSource = 'none';
  String? failedTarget;
  final requiredTargets = <String>{};
  final startedTargets = <String>{};
  final persistedTargets = <TavernJsonObject>[];
  final claimedInjectionVersions = <TavernJsonObject>[];
  final skippedTargets = <TavernJsonObject>[];
  bool get committed => persistedTargets.isNotEmpty || claimedInjectionVersions.isNotEmpty;
  TavernJsonObject details(String issue) => {
    'preparationAccepted': accepted,
    'persistedTargets': persistedTargets,
    'claimedInjectionVersions': claimedInjectionVersions,
    'skippedTargets': skippedTargets,
    if (failedTarget != null) 'failedTarget': failedTarget,
    'phase': phase,
    'budgetSource': budgetSource,
    'preparationIssue': issue,
  };
}

class _ScriptObservedValue {
  _ScriptObservedValue(this.fingerprint);
  String fingerprint;
  int revision = 0;
  void observe(String next) {
    if (next != fingerprint) {
      fingerprint = next;
      revision++;
    }
  }
}

class _ScriptChatObservation {
  _ScriptChatObservation(this.identity);
  final int identity;
  final fields = <String, _ScriptObservedValue>{};
  final persistent = <String, _ScriptPersistentObservation>{};
  int nextPersistentIdentity = 0;
}

class _ScriptPersistentObservation {
  _ScriptPersistentObservation({
    required this.identity,
    required this.source,
    required this.rawId,
    required String fingerprint,
  }) : value = _ScriptObservedValue(fingerprint);
  final int identity;
  final ChatJsonlMetadataSource source;
  final String rawId;
  final _ScriptObservedValue value;
}

String _scriptRuntimeFingerprint(Object? value) {
  Object? encode(Object? item) {
    if (item is num) {
      return [
        'number',
        item.isNaN
            ? 'NaN'
            : item == double.infinity
            ? '+Inf'
            : item == double.negativeInfinity
            ? '-Inf'
            : item,
      ];
    }
    if (item is Map<String, Object?>) {
      final keys = item.keys.toList()..sort();
      return [
        'object',
        [
          for (final key in keys) [key, encode(item[key])],
        ],
      ];
    }
    if (item is List<Object?>) {
      return [
        'array',
        [for (final child in item) encode(child)],
      ];
    }
    return [item.runtimeType.toString(), item];
  }

  return jsonEncode(encode(value));
}
