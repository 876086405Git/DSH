part of 'engine.dart';

const _presetSamplingKeys = <String>{
  'temperature',
  'top_p',
  'presence_penalty',
  'frequency_penalty',
  'openai_max_tokens',
  'openai_max_context',
};

bool _inheritsGlobalPreset(PresetSelectionSource source) =>
    source == PresetSelectionSource.globalDefault ||
    source == PresetSelectionSource.globalInline ||
    source == PresetSelectionSource.stDefault;

String _presetSelectionIdentity(
  PresetSelectionSource source,
  String? presetId,
  Map<String, Object?> global,
  StoredChat? chat,
) => jsonEncode({
  'source': source.name,
  'presetId': ?presetId,
  if (source == PresetSelectionSource.globalInline) 'inline': global['preset'],
  if (source == PresetSelectionSource.chatInline) 'inline': chat!.settings['preset'],
});

final class _PresetWorkingSlot {
  _PresetWorkingSlot({
    required this.selectionIdentity,
    required this.loadedSource,
    required this.loadedPresetId,
    required Map<String, Object?> raw,
    required Set<String> samplingOwned,
    required this.revision,
  }) : raw = _copy(raw),
       samplingOwned = Set.unmodifiable(samplingOwned);
  final String selectionIdentity;
  final PresetSelectionSource loadedSource;
  final String? loadedPresetId;
  final Map<String, Object?> raw;
  final Set<String> samplingOwned;
  final int revision;

  _PresetWorkingSlot copy({Set<String>? samplingOwned, int? revision}) => _PresetWorkingSlot(
    selectionIdentity: selectionIdentity,
    loadedSource: loadedSource,
    loadedPresetId: loadedPresetId,
    raw: raw,
    samplingOwned: samplingOwned ?? this.samplingOwned,
    revision: revision ?? this.revision,
  );

  Map<String, Object?> toJson() => {
    'selectionIdentity': selectionIdentity,
    'loadedSource': loadedSource.name,
    'loadedPresetId': ?loadedPresetId,
    'raw': _copy(raw),
    'samplingOwned': [
      for (final key in _presetSamplingKeys)
        if (samplingOwned.contains(key)) key,
    ],
    'revision': revision,
  };
}

/// Detached working inputs. Composition after a C2 seal never reads the engine.
final class _PresetWorkingCapture {
  _PresetWorkingCapture({
    required this.chatId,
    required this.token,
    required Map<String, Object?> source,
    _PresetWorkingSlot? global,
    _PresetWorkingSlot? chat,
  }) : source = _copy(source),
       global = global?.copy(),
       chat = chat?.copy();
  final String? chatId;
  final String token;
  final Map<String, Object?> source;
  final _PresetWorkingSlot? global, chat;
}

final class _PresetWorkingMutation {
  const _PresetWorkingMutation(this.slots, this.revision);
  final Map<String?, _PresetWorkingSlot> slots;
  final int revision;
}

({Map<String, Object?> raw, _PresetWorkingSlot? global, _PresetWorkingSlot? chat}) _presetWorkingBase(
  Map<String, Object?> selectedRaw, {
  required PresetSelectionSource selectedSource,
  required String? selectedPresetId,
  required Map<String, Object?> global,
  required StoredChat? chat,
  required _PresetWorkingCapture? working,
}) {
  final identity = _presetSelectionIdentity(selectedSource, selectedPresetId, global, chat);
  final proposedGlobal = working?.global, proposedChat = working?.chat;
  final globalSlot = _inheritsGlobalPreset(selectedSource) && proposedGlobal?.selectionIdentity == identity
      ? proposedGlobal
      : null;
  final chatSlot = chat != null && proposedChat?.selectionIdentity == identity ? proposedChat : null;
  return (raw: _copy(chatSlot?.raw ?? globalSlot?.raw ?? selectedRaw), global: globalSlot, chat: chatSlot);
}

/// The original merge has already selected one complete preset. Preserve its
/// absent/null/empty representation unless a real working slot or sampling key
/// contributes. Ownership is evaluated against each original override carrier.
Map<String, Object?> _applyPresetWorkingSettings(
  Map<String, Object?> settings, {
  required Map<String, Object?> global,
  required StoredChat? chat,
  required PresetSelectionSource selectedSource,
  required String? selectedPresetId,
  required _PresetWorkingCapture? working,
}) {
  final base = _presetWorkingBase(
    _map(settings['preset']),
    selectedSource: selectedSource,
    selectedPresetId: selectedPresetId,
    global: global,
    chat: chat,
    working: working,
  );
  final globalOverrides = _map(global['presetOverrides']);
  final mergedOverrides = _map(settings['presetOverrides']);
  final chatHasOverrides = chat?.settings.containsKey('presetOverrides') == true;
  final chatCarrier = chat?.settings['presetOverrides'];
  final chatOverrides = chatCarrier is Map<String, Object?> ? chatCarrier : null;
  final sampling = <String, Object?>{};
  for (final key in _presetSamplingKeys) {
    if (base.chat?.samplingOwned.contains(key) == true) {
      continue;
    }
    if (chatOverrides != null && chatOverrides.containsKey(key)) {
      sampling[key] = mergedOverrides[key];
    } else if ((!chatHasOverrides || chatOverrides != null) &&
        globalOverrides.containsKey(key) &&
        base.global?.samplingOwned.contains(key) != true) {
      sampling[key] = mergedOverrides[key];
    }
  }
  if (base.global != null || base.chat != null || sampling.isNotEmpty) {
    settings['preset'] = {...base.raw, ...sampling};
  }
  return settings;
}

PresetSelectionSource _capturedPresetSource(Map<String, Object?> global, StoredChat? chat, String? selectedPresetId) {
  if (selectedPresetId != null && chat?.presetId == selectedPresetId) {
    return PresetSelectionSource.chat;
  }
  if (chat?.settings.containsKey('preset') == true) {
    return PresetSelectionSource.chatInline;
  }
  if (selectedPresetId != null) {
    return PresetSelectionSource.globalDefault;
  }
  return global.containsKey('preset') ? PresetSelectionSource.globalInline : PresetSelectionSource.stDefault;
}

extension _PresetWorkingState on TavernEngine {
  ({
    StoredChat? chat,
    Map<String, Object?> global,
    TavernPresetSelection selection,
    Map<String, Object?> selectedRaw,
    _PresetWorkingCapture working,
    Map<String, Object?> base,
    Map<String, Object?> raw,
    Map<String, Object?> source,
  })
  _currentPresetData(String? chatId, {StoredChat? capturedChat}) {
    final chat = capturedChat ?? (chatId == null ? null : _store.chat(chatId));
    final global = _map(_document['settings']);
    final resolved = _resolvePreset(chat);
    final selection = resolved.selection;
    var settings = chat == null ? _copy(global) : _merge(global, chat.settings);
    if (resolved.preset != null) {
      settings['preset'] = resolved.preset!.raw;
    } else if (chat != null && chat.settings.containsKey('preset')) {
      settings['preset'] = _map(chat.settings['preset']);
    }
    final selectedRaw = _map(settings['preset']);
    final identity = _presetSelectionIdentity(selection.source, selection.effectivePresetId, global, chat);
    final globalSlot =
        _inheritsGlobalPreset(selection.source) && _presetWorkingSlots[null]?.selectionIdentity == identity
        ? _presetWorkingSlots[null]
        : null;
    final chatSlot = chatId != null && _presetWorkingSlots[chatId]?.selectionIdentity == identity
        ? _presetWorkingSlots[chatId]
        : null;
    final source = <String, Object?>{
      'kind': 'current',
      'scope': chatId == null ? 'global' : 'chat',
      'chatId': ?chatId,
      'loadedSource': selection.source.name,
      'loadedPresetId': ?selection.effectivePresetId,
      'working': globalSlot != null || chatSlot != null,
    };
    final token = _directorHash({
      'source': source,
      'selectionIdentity': identity,
      'base': chatSlot?.raw ?? globalSlot?.raw ?? selectedRaw,
      'globalWorking': globalSlot?.toJson(),
      'chatWorking': chatSlot?.toJson(),
      'globalOverrides': {'present': global.containsKey('presetOverrides'), 'value': global['presetOverrides']},
      'chatOverrides': {
        'present': chat?.settings.containsKey('presetOverrides') == true,
        'value': chat?.settings['presetOverrides'],
      },
    });
    final working = _PresetWorkingCapture(
      chatId: chatId,
      token: token,
      source: source,
      global: globalSlot,
      chat: chatSlot,
    );
    final base = _presetWorkingBase(
      selectedRaw,
      selectedSource: selection.source,
      selectedPresetId: selection.effectivePresetId,
      global: global,
      chat: chat,
      working: working,
    ).raw;
    settings = _applyPresetWorkingSettings(
      settings,
      global: global,
      chat: chat,
      selectedSource: selection.source,
      selectedPresetId: selection.effectivePresetId,
      working: working,
    );
    final effective = _map(settings['preset']);
    return (
      chat: chat,
      global: global,
      selection: selection,
      selectedRaw: selectedRaw,
      working: working,
      base: base.isEmpty ? ChatPreset.stDefault().raw : base,
      raw: effective.isEmpty ? ChatPreset.stDefault().raw : effective,
      source: source,
    );
  }

  _PresetWorkingCapture _capturePresetWorking({String? chatId}) => _currentPresetData(chatId).working;

  // C2 already resolved the selected stored/draft preset and seals its raw
  // row separately. Capture only the applicable RAM slots here: resolving a
  // live current preset would read unrelated defaults for a sample context.
  _PresetWorkingCapture _captureAuthoringPresetWorking(
    Map<String, Object?> global,
    StoredChat chat,
    String? selectedPresetId, {
    required bool real,
  }) {
    final selectedSource = _capturedPresetSource(global, chat, selectedPresetId);
    final identity = _presetSelectionIdentity(selectedSource, selectedPresetId, global, chat);
    final globalSlot = _inheritsGlobalPreset(selectedSource) && _presetWorkingSlots[null]?.selectionIdentity == identity
        ? _presetWorkingSlots[null]
        : null;
    final chatSlot = real && _presetWorkingSlots[chat.id]?.selectionIdentity == identity
        ? _presetWorkingSlots[chat.id]
        : null;
    final source = <String, Object?>{
      'kind': 'current',
      'scope': real ? 'chat' : 'global',
      if (real) 'chatId': chat.id,
      'loadedSource': selectedSource.name,
      'loadedPresetId': ?selectedPresetId,
      'working': globalSlot != null || chatSlot != null,
    };
    return _PresetWorkingCapture(
      chatId: real ? chat.id : null,
      source: source,
      token: _directorHash({
        'source': source,
        'selectionIdentity': identity,
        'globalWorking': globalSlot?.toJson(),
        'chatWorking': chatSlot?.toJson(),
      }),
      global: globalSlot,
      chat: chatSlot,
    );
  }

  bool _presetWorkingCurrent(_PresetWorkingCapture capture) {
    final chatId = capture.chatId;
    if (chatId != null && !_store.toolChatExists(chatId)) {
      return false;
    }
    return _capturePresetWorking(chatId: chatId).token == capture.token;
  }

  _PresetWorkingMutation _presetMutation(Map<String?, _PresetWorkingSlot> next) =>
      _PresetWorkingMutation(Map.unmodifiable(next), _presetWorkingRevision + 1);

  void _adoptPresetWorking(_PresetWorkingMutation change) {
    _presetWorkingSlots = change.slots;
    _presetWorkingRevision = change.revision;
  }

  void _notifyPresetWorking() {
    if (_presetWorkingNotifiedRevision == _presetWorkingRevision) {
      return;
    }
    _presetWorkingNotifiedRevision = _presetWorkingRevision;
    _scripts.resourcesChanged();
  }

  _PresetWorkingMutation _preparePresetWorkingReset({String? chatId}) {
    final next = Map<String?, _PresetWorkingSlot>.of(_presetWorkingSlots);
    if (chatId != null) {
      next.remove(chatId);
    } else {
      next.removeWhere((key, slot) => key == null || _inheritsGlobalPreset(slot.loadedSource));
    }
    return _presetMutation(next);
  }

  _PresetWorkingMutation _preparePresetSettingsAdoption(Map<String, Object?> patch, {String? chatId}) {
    final next = Map<String?, _PresetWorkingSlot>.of(_presetWorkingSlots);
    if (patch.containsKey('presetOverrides')) {
      final carrier = patch['presetOverrides'];
      final keys = carrier is Map<String, Object?>
          ? _presetSamplingKeys.where(carrier.containsKey).toSet()
          : _presetSamplingKeys;
      for (final entry in next.entries.toList()) {
        final id = entry.key;
        if (chatId != null && id != chatId) {
          continue;
        }
        Set<String> released = keys;
        if (chatId == null && id != null) {
          if (!_store.toolChatExists(id)) {
            next.remove(id);
            continue;
          }
          final settings = _store.chat(id).settings;
          if (settings.containsKey('presetOverrides')) {
            final overrides = settings['presetOverrides'];
            released = overrides is Map<String, Object?>
                ? keys.where((key) => !overrides.containsKey(key)).toSet()
                : const <String>{};
          }
        }
        final owned = entry.value.samplingOwned.difference(released);
        if (owned.length != entry.value.samplingOwned.length) {
          next[id] = entry.value.copy(samplingOwned: owned, revision: _presetWorkingRevision + 1);
        }
      }
    }
    _prunePresetWorking(next);
    return _presetMutation(next);
  }

  void _prunePresetWorking(Map<String?, _PresetWorkingSlot> slots, {Set<String>? chatIds, bool presetsChanged = true}) {
    final global = _map(_document['settings']);
    for (final entry in slots.entries.toList()) {
      final id = entry.key;
      if (!presetsChanged && (id == null || chatIds?.contains(id) != true)) {
        continue;
      }
      if (id != null && !_store.toolChatExists(id)) {
        slots.remove(id);
        continue;
      }
      final chat = id == null ? null : _store.chat(id);
      final selection = _resolvePreset(chat).selection;
      final identity = _presetSelectionIdentity(selection.source, selection.effectivePresetId, global, chat);
      if (identity != entry.value.selectionIdentity) {
        slots.remove(id);
      }
    }
  }

  void _presetWorkingStoreCommitted(Set<String> chatIds, bool presetsChanged) {
    if (_presetWorkingSlots.isNotEmpty && (presetsChanged || chatIds.isNotEmpty)) {
      final next = Map<String?, _PresetWorkingSlot>.of(_presetWorkingSlots);
      _prunePresetWorking(next, chatIds: chatIds, presetsChanged: presetsChanged);
      if (next.length != _presetWorkingSlots.length) {
        _adoptPresetWorking(_presetMutation(next));
      }
    }
    _notifyPresetWorking();
  }

  void _restoreCapturedPresetWorking(_PresetWorkingCapture captured, String chatId) {
    final next = <String?, _PresetWorkingSlot>{
      if (captured.global case final global?) null: global.copy(),
      if (captured.chat case final chat?) chatId: chat.copy(),
    };
    _adoptPresetWorking(_presetMutation(next));
    _notifyPresetWorking();
  }
}

extension _ScriptPresets on _ScriptCoordinator {
  TavernScriptPresetSnapshot _scriptPresetViewNow(_ScriptContextState context, TavernScriptPresetRef ref) {
    _checkScriptPresetContext(context);
    if (ref.kind == TavernScriptPresetRefKind.stored) {
      final id = ref.presetId!;
      final saved = engine._store.preset(id);
      if (saved == null) {
        throw _scriptError(
          TavernScriptErrorCode.notFound,
          'readPreset',
          'The stored preset does not exist.',
          contextId: context.value.id,
        );
      }
      return TavernScriptPresetSnapshot(
        ref: ref,
        version: _resourceVersion('preset:stored:$id', {
          'raw': saved.raw,
          'envelope': saved.envelope,
          'name': saved.name,
        }),
        source: {'kind': 'stored', 'presetId': id},
        raw: saved.raw,
      );
    }
    final value = engine._currentPresetData(context.value.chatId);
    return TavernScriptPresetSnapshot(
      ref: ref,
      version: _resourceVersion('preset:current:${jsonEncode(context.value.chatId)}', {
        'token': value.working.token,
        'raw': value.raw,
      }),
      source: value.source,
      raw: value.raw,
    );
  }

  Future<TavernScriptPresetSnapshot> _readScriptPreset(String contextId, TavernScriptPresetRef ref) {
    final context = _context(contextId);
    return engine._presetOperation(() => _scriptPresetViewNow(context, ref));
  }

  Future<TavernScriptPresetSnapshot> _replaceScriptPreset(
    String contextId,
    TavernScriptPresetRef ref,
    TavernJsonObject raw, {
    required String expectedVersion,
  }) {
    final context = _context(contextId);
    final captured = _captureScriptObject(raw);
    return _writeScriptPreset(context, ref, expectedVersion, whole: true, prepare: (_) => captured);
  }

  Future<TavernScriptPresetSnapshot> _replaceScriptPresetRegex(
    String contextId,
    TavernScriptPresetRef ref,
    List<TavernJsonObject> raw, {
    required String expectedVersion,
  }) {
    final context = _context(contextId);
    final captured = [for (final item in raw) _captureScriptObject(item)];
    return _writeScriptPreset(
      context,
      ref,
      expectedVersion,
      whole: false,
      prepare: (base) {
        final extensions = _optionalObject(base, 'extensions');
        extensions['regex_scripts'] = captured;
        return {...base, 'extensions': extensions};
      },
    );
  }

  Future<TavernScriptPresetSnapshot> _writeScriptPreset(
    _ScriptContextState context,
    TavernScriptPresetRef ref,
    String expectedVersion, {
    required bool whole,
    required Map<String, Object?> Function(Map<String, Object?>) prepare,
  }) async {
    var adopted = false;
    TavernScriptPresetSnapshot? result;
    try {
      await engine._presetOperation(() {
        _checkScriptPresetContext(context);
        final current = _scriptPresetViewNow(context, ref);
        _resourceExpected(expectedVersion, current.version, 'replacePreset');
        if (ref.kind == TavernScriptPresetRefKind.stored) {
          final original = engine._requirePreset(ref.presetId!);
          if (engine._deletingPresets.contains(original.id)) {
            throw _scriptError(TavernScriptErrorCode.busy, 'replacePreset', 'Preset deletion is active.');
          }
          final candidate = prepare(original.raw);
          engine._guardPresetCarrier(original.raw, candidate);
          late TavernScriptPresetSnapshot actual;
          engine._store.transaction(
            () {
              engine._savePresetEdit(original, candidate);
              actual = _scriptPresetViewNow(context, ref);
            },
            onCommitted: () {
              adopted = true;
              result = actual;
            },
          );
        } else {
          final value = engine._currentPresetData(context.value.chatId);
          if (engine._deletingPresets.contains(value.selection.effectivePresetId)) {
            throw _scriptError(TavernScriptErrorCode.busy, 'replacePreset', 'Preset deletion is active.');
          }
          final candidate = prepare(value.base);
          final decoded = engine._presetCodec.validate(candidate);
          final slot = _PresetWorkingSlot(
            selectionIdentity: _presetSelectionIdentity(
              value.selection.source,
              value.selection.effectivePresetId,
              value.global,
              value.chat,
            ),
            loadedSource: value.selection.source,
            loadedPresetId: value.selection.effectivePresetId,
            raw: decoded.raw,
            samplingOwned: whole
                ? _presetSamplingKeys
                : (context.value.chatId == null
                          ? value.working.global?.samplingOwned
                          : value.working.chat?.samplingOwned) ??
                      const {},
            revision: engine._presetWorkingRevision + 1,
          );
          final next = Map<String?, _PresetWorkingSlot>.of(engine._presetWorkingSlots)..[context.value.chatId] = slot;
          engine._adoptPresetWorking(engine._presetMutation(next));
          adopted = true;
          result = _scriptPresetViewNow(context, ref);
          engine._notifyPresetWorking();
        }
      });
      await _refreshHelperResourceContexts();
      return result!;
    } catch (error, stack) {
      if (!adopted) {
        rethrow;
      }
      final failure = _scriptFailure(error);
      final working = ref.kind == TavernScriptPresetRefKind.current;
      Error.throwWithStackTrace(
        TavernScriptException(
          code: failure.code,
          operation: 'replacePreset',
          message: failure.message,
          contextId: context.value.id,
          fieldPath: failure.fieldPath,
          committed: true,
          issues: [
            ...failure.issues,
            TavernScriptIssue(
              code: 'resourceAdopted',
              message: working
                  ? 'The current preset was adopted in memory before a later step failed.'
                  : 'The stored preset was committed to SQL before a later step failed.',
              contextId: context.value.id,
              committed: true,
              stage: 'storage',
              details: {
                'targetKind': working ? 'presetWorking' : 'preset',
                'ref': ref.toJson(),
                'version': ?result?.version,
              },
            ),
          ],
        ),
        stack,
      );
    }
  }

  void _checkScriptPresetContext(_ScriptContextState context) {
    if (!identical(_context(context.value.id), context)) {
      throw _scriptError(
        TavernScriptErrorCode.closedContext,
        'preset',
        'The context instance changed.',
        contextId: context.value.id,
      );
    }
  }
}
