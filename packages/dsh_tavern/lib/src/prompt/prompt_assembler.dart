// Adapted from SillyTavern public/scripts/openai.js, PromptManager.js and
// public/script.js (AGPL-3.0).
// Source commit: 7e8663cd9c184a550b37238218bdd32c6efc68e9 (1.19.0).
import 'dart:convert';

import '../js_string.dart';
import '../spreset.dart';
import 'character_fields.dart';
import 'deepseek_processing.dart';
import 'preset.dart';
import 'post_processing.dart';
import 'prompt_types.dart';
import 'prompt_manager_snapshot.dart';
import 'reasoning.dart';

final class PromptInput {
  const PromptInput({
    required this.preset,
    required this.card,
    required this.history,
    required this.model,
    this.userName = 'User',
    this.characterId = '',
    this.generationType = 'normal',
    this.deepseek = true,
    this.chatCompletionSource = 'custom',
    this.persona = '',
    this.personaInPrompt = true,
    this.groupNames = const [],
    this.worldBefore = const [],
    this.worldAfter = const [],
    this.injections = const [],
    this.worldSections = const {},
    this.disabledUiPrompts = const {},
    this.assistantPrefill = const [],
    this.examplesBefore = '',
    this.examplesAfter = '',
    this.worldExamples = const [],
    this.pinExamples = false,
    this.stripExamples = false,
    this.cacheFriendlyTrimming,
    this.historyWindow,
    this.quietPrompt = '',
    this.bias = '',
    this.stops = const [],
    this.tools = const [],
    this.toolChoice,
    this.expansion,
    this.cardExpansion,
    this.preparedFields,
    this.onSPresetDiagnostic,
    this.macroNestRuntime,
    this.spresetProvider,
  });
  final ChatPreset preset;

  /// V3 `data`, with any per-chat field overrides already applied.
  final Map<String, Object?> card;

  /// Chronological order. Hidden and ST is_system messages are excluded here.
  final List<PromptHistoryMessage> history;
  final String model;
  final String userName;
  final String characterId;
  final String generationType;
  final bool deepseek;

  /// Actual connection dialect, not an imported endpoint selection.
  final String chatCompletionSource;

  /// SPreset hooks read the page's current provider even when one Helper
  /// request uses a different custom transport. Omitted by native callers.
  final SPresetProvider? spresetProvider;
  final String persona;
  final bool personaInPrompt;
  final List<String> groupNames;
  final List<PromptFragment> worldBefore;
  final List<PromptFragment> worldAfter;

  /// V3 sections, in final insertion order: before_desc, after_desc,
  /// personality, scenario. The latter two append to the corresponding slot.
  final Map<String, List<PromptFragment>> worldSections;

  /// V3 UI types: system_prompt and post_history_instructions.
  final Set<String> disabledUiPrompts;

  /// Explicit depth-zero assistant pieces, appended after all tail controls.
  /// DeepSeek combines them into its final assistant prefix message.
  final List<PromptFragment> assistantPrefill;
  final List<PromptInjection> injections;
  final String examplesBefore;
  final String examplesAfter;
  final List<PromptExample> worldExamples;
  final bool pinExamples;
  final bool stripExamples;

  /// Explicit turn setting takes priority over the preset. A missing preset
  /// setting enables cache-friendly trimming; false keeps ST's original path.
  final bool? cacheFriendlyTrimming;
  final PromptHistoryWindow? historyWindow;
  final String quietPrompt;
  final String bias;
  final List<String> stops;
  final List<Map<String, Object?>> tools;
  final Object? toolChoice;

  /// Normal substitution with fresh lazy raw-card fields on every invocation.
  /// Overrides contain only temporary values such as original/lastChatMessage.
  final PromptExpansion? expansion;

  /// ST baseChatReplace: names/variables enabled, character-field lookup off.
  /// Full macro integrations should supply both callbacks. Without either,
  /// assembly uses a limited names/fields fallback and retains unknown macros.
  final PromptExpansion? cardExpansion;
  final PreparedCharacterFields? preparedFields;
  final SPresetDiagnostic? onSPresetDiagnostic;

  /// Reuse for one native runtime; isolated previews may omit it.
  final SPresetMacroNestRuntime? macroNestRuntime;
}

final class PromptAssembler {
  const PromptAssembler({this.counter = const EstimatedTokenCounter(), this.onPromptManager});
  final PromptTokenCounter counter;

  /// Runtime-only setter boundary; detached previews omit this observer.
  final void Function(PromptManagerSnapshot)? onPromptManager;
  PromptAssembly assemble(PromptInput input) => _AssemblyRun(input, counter, onPromptManager: onPromptManager).run();
}

/// The engine has already proved the unread prefix cannot fit. Retain its
/// ordinary exclusions without loading its bodies or expanding its macros.
PromptAssembly assemblePromptWindow(
  PromptAssembler assembler,
  PromptInput input, {
  required List<PromptHistoryMessage> prefix,
}) => _AssemblyRun(input, assembler.counter, historyPrefix: prefix, onPromptManager: assembler.onPromptManager).run();

/// Rebuild provider conversion after an asynchronous prompt hook. Admission,
/// macro effects and stop expansion have already happened and are not replayed.
PromptAssembly reprocessPromptAssembly(
  PromptAssembly original,
  List<PromptSegment> before,
  PromptInput input, {
  PromptTokenCounter counter = const EstimatedTokenCounter(),
}) {
  final run = _AssemblyRun(input, counter);
  run.excluded
    ..clear()
    ..addAll(
      original.excluded.where(
        (item) => item.reason != 'reasoning-prefill-unsupported' && item.reason != 'no-preset-prefill-tail',
      ),
    );
  final stops = original.body['stop'];
  return run.finish(before, stops: stops is List<Object?> ? stops.cast<String>() : const [], original: original);
}

/// Cost of an unchanged, meaningful history message, using the assembler's
/// exact name/CR/tool-field normalization. Only pure counters may preflight.
int plainHistoryTokenCost(
  PromptTokenCounter counter,
  PromptHistoryMessage item, {
  required Object? namesBehavior,
  required String userName,
  required bool group,
}) {
  if (item.hidden || item.isSystem) return 0;
  final prompt = _historyPrompt(item, namesBehavior: namesBehavior, userName: userName, group: group);
  final message = _messageData(prompt, prompt.content, includeName: namesBehavior == 1);
  return _meaningfulMessage(message) ? counter.countMessage(message) : 0;
}

/// Internal quiet adapter: call the already-prepared stop supplier once at
/// the assembler's real stop stage, without filtering or expanding it again.
/// Its bias admission uses the first prepared value and JS whitespace; the
/// ordinary assemble/default raw paths retain their original behavior.
PromptAssembly assembleScriptPrompt(
  PromptAssembler assembler,
  PromptInput input, {
  required List<String> Function() preparedStops,
}) => _AssemblyRun(
  input,
  assembler.counter,
  preparedStops: preparedStops,
  onPromptManager: assembler.onPromptManager,
  preparedBiasHasContent: trimJsWhitespace(input.bias).isNotEmpty,
).run();

final class _Prompt {
  _Prompt(
    this.id,
    this.content,
    this.sources, {
    String? windowId,
    this.role = 'system',
    this.data = const {},
    this.injected = false,
    this.expandMacros = true,
    this.placement,
    this.extension = false,
    this.explicitRole = false,
    this.trimGroup,
    this.pieces,
  }) : windowId = windowId ?? id;
  final String id;
  final String windowId;
  String content;
  List<PromptSource> sources;
  Object? role;
  Map<String, Object?> data;
  final bool injected;
  final bool expandMacros;
  PromptPlacement? placement;
  bool extension;
  final bool explicitRole;
  final _TrimGroup? trimGroup;
  final List<_Prompt>? pieces;
  bool get absolute => data['injection_position'] == 1;
  int? get depth {
    final value = data['injection_depth'];
    if (value is! num || value < 0 || value > 10000 || value != value.truncateToDouble()) return null;
    return value.toInt();
  }

  num get order => data['injection_order'] is num
      ? data['injection_order'] as num
      : num.tryParse('${data['injection_order']}') ?? 100;
  _Prompt copy() => _Prompt(
    id,
    content,
    [...sources],
    windowId: windowId,
    role: role,
    data: {...data},
    injected: injected,
    expandMacros: expandMacros,
    placement: placement,
    extension: extension,
    explicitRole: explicitRole,
    trimGroup: trimGroup,
    pieces: pieces?.map((piece) => piece.copy()).toList(),
  );
}

final class _TrimGroup {
  _TrimGroup(this.source);
  final PromptSource source;
  final segments = <PromptSegment>{};
  bool removed = false;
  bool queued = false;
}

_Prompt _historyPrompt(
  PromptHistoryMessage item, {
  required Object? namesBehavior,
  required String userName,
  required bool group,
}) {
  final role = item.role == 'narrator' ? 'system' : item.role;
  var content = item.content;
  if ((namesBehavior == 2 && role != 'system') ||
      (namesBehavior == 0 && item.name != userName && (group || (item.forceAvatar && role != 'system')))) {
    content = '${item.name}: $content';
  }
  return _Prompt(
    item.id,
    content.replaceAll('\r', ''),
    [PromptSource('history', item.id, label: item.name)],
    role: role,
    expandMacros: item.expandMacros,
    data: {
      'name': item.name,
      if (item.toolCalls != null) 'tool_calls': item.toolCalls,
      if (item.toolCallId != null) 'tool_call_id': item.toolCallId,
    },
  );
}

Map<String, Object?> _messageData(_Prompt prompt, String content, {required bool includeName}) {
  final name = prompt.data['name'];
  return <String, Object?>{
    'role': presetTruthy(prompt.role) ? prompt.role : 'system',
    'content': content,
    if (includeName && name is String && name.isNotEmpty) 'name': sanitizeName(name),
    if (prompt.data['tool_calls'] != null) 'tool_calls': prompt.data['tool_calls'],
    if (prompt.data['tool_call_id'] != null) 'tool_call_id': prompt.data['tool_call_id'],
  };
}

bool _meaningfulMessage(Map<String, Object?> message) =>
    message['content'] != '' || message.containsKey('tool_calls') || message['role'] == 'tool';

final class _ExampleBlock {
  const _ExampleBlock(this.messages, this.source, {this.trimGroup});
  final List<Map<String, Object?>> messages;
  final PromptSource source;
  final _TrimGroup? trimGroup;
}

final class _DepthExtension {
  const _DepthExtension(this.injection, this.fragment, this.index);
  final PromptInjection injection;
  final PromptFragment fragment;
  final int index;
  String get role => fragment.role ?? injection.role;
}

final class _AssemblyRun {
  _AssemblyRun(
    this.input,
    this.counter, {
    this.preparedStops,
    this.preparedBiasHasContent,
    this.historyPrefix = const [],
    this.onPromptManager,
  }) : settings = input.preset.executionSettings {
    cacheFriendlyTrimming = input.cacheFriendlyTrimming ?? (settings['cacheFriendlyTrimming'] != false);
    final window = cacheFriendlyTrimming ? input.historyWindow : null;
    if (window != null) {
      // Bodies are deliberately unnecessary here: unread prefix nodes still
      // carry their physical identities and original depth positions.
      var found = false;
      for (final item in historyPrefix.followedBy(input.history)) {
        if (item.id == window.firstNodeId && !item.hidden && !item.isSystem) {
          found = true;
          break;
        }
        olderHistory.add(item.id);
      }
      if (found) {
        historyWindow = window;
      } else {
        olderHistory.clear();
      }
    }
    if (cacheFriendlyTrimming) unreadHistory.addAll(historyPrefix.map((item) => item.id));
    type = input.generationType.trim().toLowerCase();
    if (type.isEmpty) type = 'normal';
    final extensions = settings['extensions'];
    final dshgo = extensions is Map<String, Object?> ? extensions['dshgo'] : null;
    final prefill = dshgo is Map<String, Object?> ? dshgo['prefill'] : null;
    enhancedPrefillEnabled = prefill is Map<String, Object?> && prefill['enabled'] == true;
    prefillTarget = prefill is Map<String, Object?> && prefill['target'] == 'reasoning' ? 'reasoning' : 'content';
    final prefillMode =
        enhancedPrefillEnabled ||
        input.assistantPrefill.isNotEmpty ||
        (type == 'continue' && settings['continue_prefill'] == true);
    tools = prefillMode ? const [] : input.tools;
    if (prefillMode && input.tools.isNotEmpty) {
      excluded.add(
        PromptExclusion('tools', 'prefill-mode-tools', [
          PromptSource('control', 'tools', details: {'count': input.tools.length}),
        ]),
      );
    }
    final nickname = input.card['nickname'];
    characterName = nickname is String && nickname.isNotEmpty ? nickname : field('name');
    budget = number('openai_max_context', 4095) - number('openai_max_tokens', 300);
    remaining = budget - 3;
  }
  final PromptInput input;
  final void Function(PromptManagerSnapshot)? onPromptManager;
  final List<String> Function()? preparedStops;
  final bool? preparedBiasHasContent;
  final List<PromptHistoryMessage> historyPrefix;
  final PromptTokenCounter counter;
  final Map<String, Object?> settings;
  late final spreset = SPresetConfig.fromPreset(settings);
  late final macroNestRuntime = input.macroNestRuntime ?? SPresetMacroNestRuntime();
  late final bool cacheFriendlyTrimming;
  PromptHistoryWindow? historyWindow;
  final olderHistory = <String>{};
  final unreadHistory = <String>{};
  bool historyOverflow = false;
  final admittedExamples = <({String kind, String id, int block}), _TrimGroup?>{};
  final excludedInjections = <String>{};
  late final bool enhancedPrefillEnabled;
  late final String prefillTarget;
  late final List<Map<String, Object?>> tools;
  late final String characterName;
  late String type;
  late final int budget;
  late int remaining;
  final prompts = <_Prompt>[];
  final collections = <String, List<PromptSegment>>{};
  final tail = <PromptSegment>[];
  final historyTail = <PromptSegment>{};
  final managerTails = <String, List<PromptSegment>>{};
  final logicalIdentifiers = <PromptSegment, String?>{};
  bool historyStoredNewestFirst = false;
  final excluded = <PromptExclusion>[];
  final disabled = <String>{};
  final uiDisabled = <String>{};
  final cardFields = <String, String>{};
  final exampleBlocks = <_ExampleBlock>[];
  final trimGroups = <(String, String), _TrimGroup>{};
  final trimOrder = <_TrimGroup>[];
  final segmentGroups = <PromptSegment, _TrimGroup>{};
  final charges = <PromptSegment, int>{};
  String persona = '';

  int number(String key, int fallback) => presetNumber(settings[key], fallback).toInt();
  String setting(String key) => key == 'continue_postfix' ? presetString(settings[key]) : presetContent(settings[key]);
  String field(String key) => cardFields[key] ?? presetContent(input.card[key]);
  _Prompt? get(String id) => prompts.where((prompt) => prompt.id == id).firstOrNull;

  String expand(String text, [Map<String, String> overrides = const {}]) {
    // A full macro engine creates fresh lazy card getters for every call. Only
    // temporary values (e.g. original) may override that environment.
    if (input.expansion != null) return input.expansion!(text, overrides);
    return fallbackExpand(text, overrides);
  }

  String prepareText(String id, String text, [Map<String, String> overrides = const {}]) {
    final expanded = spreset.macroNest && text.isNotEmpty
        ? macroNestRuntime.expand(text, (value) => expand(value, overrides))
        : expand(text, overrides);
    return expanded.isEmpty && spresetHasStructuredBinding(spreset, id) ? '\u200b' : expanded;
  }

  String baseExpand(String text) =>
      (input.cardExpansion ?? input.expansion)?.call(text, const {}) ??
      fallbackExpand(text, const {}, replaceCharacterCard: false);

  String fallbackExpand(String text, Map<String, String> overrides, {bool replaceCharacterCard = true}) {
    final group = input.groupNames.isEmpty ? characterName : input.groupNames.join(', ');
    String cardValue(String key) => replaceCharacterCard ? field(key) : '';
    final values = <String, String>{
      'user': input.userName,
      'char': characterName,
      'charIfNotGroup': group,
      'group': group,
      'description': cardValue('description'),
      'personality': cardValue('personality'),
      'scenario': cardValue('scenario'),
      'charDescription': cardValue('description'),
      'charPersonality': cardValue('personality'),
      'charScenario': cardValue('scenario'),
      'persona': replaceCharacterCard ? persona : '',
      'model': input.model,
      ...overrides,
    };
    final normalized = {for (final entry in values.entries) entry.key.toLowerCase(): entry.value};
    var originalUsed = false;
    return text.replaceAllMapped(RegExp(r'\{\{([^{}]+)\}\}'), (match) {
      final name = match[1]!.trim().toLowerCase();
      if (name == 'original' && normalized.containsKey(name)) {
        if (originalUsed) return '';
        originalUsed = true;
      }
      return normalized[name] ?? match[0]!;
    });
  }

  PromptSegment message(_Prompt prompt, {bool expandText = false, bool includeName = false}) {
    final content = expandText && prompt.expandMacros ? expand(prompt.content) : prompt.content;
    final data = _messageData(prompt, content, includeName: includeName);
    final segment = PromptSegment(
      id: prompt.id,
      message: data,
      sources: prompt.sources,
      tokens: counter.countMessage(data),
    );
    track(segment, prompt.trimGroup);
    return segment;
  }

  bool decorated(PromptFragment fragment) => fragment.role != null || fragment.trimOnOverflow || !fragment.expandMacros;
  List<PromptFragment> injectionPieces(PromptInjection injection) =>
      injection.fragments.isEmpty ? [injection.fragment] : injection.fragments;
  bool decoratedInjection(PromptInjection injection) => injection.fragments.isNotEmpty || decorated(injection.fragment);
  bool injectionHasContent(PromptInjection injection) =>
      injectionPieces(injection).any((fragment) => fragment.content.isNotEmpty);
  _TrimGroup? groupFor(PromptFragment fragment) => !fragment.trimOnOverflow
      ? null
      : trimGroups.putIfAbsent((fragment.source.kind, fragment.source.id), () {
          final group = _TrimGroup(fragment.source);
          if (historyWindow?.excludedOptionalSources.contains((kind: fragment.source.kind, id: fragment.source.id)) ==
              true) {
            // Keep the ordinary exclusion reason: WI persistence must not
            // count a source that the retained window continues to exclude.
            drop(group);
          }
          return group;
        });
  Iterable<_Prompt> promptPieces(_Prompt prompt) sync* {
    final pieces = prompt.pieces;
    if (pieces == null) {
      yield prompt;
    } else {
      for (final piece in pieces) {
        yield* promptPieces(piece);
      }
    }
  }

  List<PromptSegment> messages(_Prompt prompt, {bool expandText = false, bool includeName = false}) => [
    for (final piece in promptPieces(prompt)) message(piece, expandText: expandText, includeName: includeName),
  ];
  void track(PromptSegment segment, _TrimGroup? group) {
    if (group == null) return;
    segmentGroups[segment] = group;
    group.segments.add(segment);
  }

  bool removed(PromptSegment segment) => segmentGroups[segment]?.removed == true;
  void charge(PromptSegment segment) {
    remaining -= segment.tokens;
    charges[segment] = (charges[segment] ?? 0) + 1;
    final group = segmentGroups[segment];
    if (group != null && !group.queued) {
      group.queued = true;
      trimOrder.add(group);
    }
  }

  void drop(_TrimGroup group) {
    if (group.removed) return;
    group.removed = true;
    for (final segment in group.segments) {
      remaining += segment.tokens * (charges.remove(segment) ?? 0);
    }
    excluded.add(PromptExclusion(group.source.id, 'v3-ignore-on-max-context', [group.source]));
  }

  void makeRoom(int requiredTokens) {
    for (final group in trimOrder) {
      if (remaining >= requiredTokens) break;
      if (!group.removed) drop(group);
    }
  }

  void reserve(PromptSegment segment) {
    if (removed(segment)) return;
    charge(segment);
    makeRoom(0);
  }

  void spend(PromptSegment segment) {
    if (removed(segment)) return;
    makeRoom(segment.tokens);
    if (removed(segment)) return;
    final group = segmentGroups[segment];
    if (segment.tokens > remaining && group != null) {
      drop(group);
      return;
    }
    if (segment.tokens > remaining) throw PromptBudgetExceeded(segment.id, segment.tokens, remaining);
    charge(segment);
  }

  void commitReserved(PromptSegment segment) {
    if (removed(segment)) return;
    remaining += segment.tokens;
    final count = charges[segment] ?? 0;
    if (count <= 1) {
      charges.remove(segment);
    } else {
      charges[segment] = count - 1;
    }
    spend(segment);
  }

  bool meaningful(PromptSegment segment) => _meaningfulMessage(segment.message);
  void addFixed(String id) {
    final prompt = get(id);
    if (prompt == null || prompt.absolute || (disabled.contains(id) && id != 'main')) return;
    final segments = messages(prompt);
    for (final segment in segments) {
      spend(segment);
    }
    collections[id] = segments;
  }

  void prepare() {
    final prepared =
        input.preparedFields ??
        prepareCharacterFields(input.card, persona: input.persona, expand: (text, _) => baseExpand(text));
    cardFields.addAll(prepared.values);
    persona = prepared.persona;
    prepareExamples();
    final scenario = field('scenario').isNotEmpty && setting('scenario_format').isNotEmpty
        ? expand(setting('scenario_format'))
        : field('scenario');
    final personality = field('personality').isNotEmpty && setting('personality_format').isNotEmpty
        ? expand(setting('personality_format'))
        : field('personality');
    final groupNudge = expand(setting('group_nudge_prompt'));
    final impersonate = expand(setting('impersonation_prompt'));
    if (input.disabledUiPrompts.contains('system_prompt')) uiDisabled.add('main');
    if (input.disabledUiPrompts.contains('post_history_instructions')) uiDisabled.add('jailbreak');
    disabled.addAll(uiDisabled);
    PromptSource cardSource(String key) => PromptSource('card', '${input.characterId}:$key', label: key);
    final definitions = (settings['prompts'] as List<Object?>).whereType<Map<String, Object?>>().toList();
    final group = (settings['prompt_order'] as List<Object?>)
        .whereType<Map<String, Object?>>()
        .where((group) => '${group['character_id']}' == '100001')
        .firstOrNull;
    final rawOrder = group?['order'];
    final order = rawOrder is List<Object?>
        ? rawOrder.whereType<Map<String, Object?>>()
        : const Iterable<Map<String, Object?>>.empty();
    final seenOrder = <Object?>{};
    for (final entry in order) {
      final rawId = entry['identifier'];
      final id = rawId == null ? '' : presetString(rawId);
      final definition = definitions.where((prompt) => prompt['identifier'] == rawId).firstOrNull;
      if (seenOrder.add(rawId) && entry['enabled'] != true) disabled.add(id);
      if (definition == null) continue;
      final triggers = definition['injection_trigger'];
      final allowed =
          entry['enabled'] == true && (triggers is! List<Object?> || triggers.isEmpty || triggers.contains(type));
      final source = PromptSource(
        'preset',
        id,
        label: definition['name'] == null ? id : presetString(definition['name']),
      );
      if (uiDisabled.contains(id)) {
        final fieldKey = id == 'main' ? 'system_prompt' : 'post_history_instructions';
        excluded.add(
          PromptExclusion(id, 'v3-disable-ui-prompt', [source, if (field(fieldKey).isNotEmpty) cardSource(fieldKey)]),
        );
        // An empty main still anchors before/after-main extensions, including
        // when the preset places main at an absolute chat depth.
        if (id == 'main') {
          prompts.add(_Prompt(id, '', [source], role: definition['role'], data: {...definition}));
        }
        continue;
      }
      if (!allowed && id != 'main') {
        excluded.add(PromptExclusion(id, disabled.contains(id) ? 'disabled' : 'generation-trigger', [source]));
        continue;
      }
      prompts.add(
        _Prompt(
          id,
          prepareText(id, allowed ? presetContent(definition['content']) : ''),
          [source],
          role: definition['role'],
          data: {...definition},
        ),
      );
    }

    _Prompt marker(
      String id,
      String content,
      List<PromptSource> sources, {
      Object? role = 'system',
      List<PromptFragment>? fragments,
    }) {
      final existing = get(id);
      final metadata = <String, Object?>{};
      for (final key in ['injection_position', 'injection_depth', 'injection_order']) {
        if (existing?.data[key] != null) metadata[key] = existing!.data[key];
      }
      final inheritedRole = existing?.role ?? role;
      final pieces = fragments == null
          ? null
          : [
              for (var i = 0; i < fragments.length; i++)
                _Prompt(
                  '$id-piece-$i',
                  fragments[i].expandMacros ? prepareText('$id-piece-$i', fragments[i].content) : fragments[i].content,
                  [fragments[i].source],
                  role: fragments[i].role ?? inheritedRole,
                  data: {...metadata},
                  explicitRole: fragments[i].role != null,
                  trimGroup: groupFor(fragments[i]),
                  expandMacros: fragments[i].expandMacros,
                ),
            ];
      final replacement = _Prompt(
        id,
        pieces == null ? prepareText(id, content) : pieces.map((p) => p.content).join('\n'),
        pieces == null ? sources : [for (final piece in pieces) ...piece.sources],
        role: inheritedRole,
        data: metadata,
        pieces: pieces,
      );
      if (existing == null) {
        prompts.add(replacement);
      } else {
        prompts[prompts.indexOf(existing)] = replacement;
      }
      return replacement;
    }

    String world(List<PromptFragment> fragments) {
      final text = fragments.map((fragment) => fragment.content).join('\n');
      if (text.isEmpty || setting('wi_format').trim().isEmpty) return text;
      return setting('wi_format').replaceAll('{0}', text);
    }

    void worldMarker(String id, List<PromptFragment> fragments) {
      marker(
        id,
        world(fragments),
        fragments.map((fragment) => fragment.source).toList(),
        fragments: fragments.any(decorated)
            ? [
                for (final fragment in fragments)
                  PromptFragment(
                    world([fragment]),
                    fragment.source,
                    role: fragment.role,
                    trimOnOverflow: fragment.trimOnOverflow,
                    expandMacros: fragment.expandMacros,
                  ),
              ]
            : null,
      );
    }

    void cardMarker(
      String id,
      String content,
      String key, {
      List<PromptFragment> before = const [],
      List<PromptFragment> after = const [],
    }) {
      final source = cardSource(key);
      marker(id, content, [
        source,
      ], fragments: before.isEmpty && after.isEmpty ? null : [...before, PromptFragment(content, source), ...after]);
    }

    worldMarker('worldInfoBefore', input.worldBefore);
    worldMarker('worldInfoAfter', input.worldAfter);
    cardMarker(
      'charDescription',
      field('description'),
      'description',
      before: input.worldSections['before_desc'] ?? const [],
      after: input.worldSections['after_desc'] ?? const [],
    );
    cardMarker('charPersonality', personality, 'personality', after: input.worldSections['personality'] ?? const []);
    cardMarker('scenario', scenario, 'scenario', after: input.worldSections['scenario'] ?? const []);
    marker('impersonate', impersonate, const [PromptSource('control', 'impersonation_prompt')]);
    marker('quietPrompt', input.quietPrompt, const [PromptSource('control', 'quietPrompt')]);
    marker('groupNudge', groupNudge, const [PromptSource('control', 'group_nudge_prompt')]);
    marker('bias', input.bias, const [PromptSource('control', 'bias')], role: 'assistant');
    const knownExtensions = {
      '1_memory': 'summary',
      '2_floating_prompt': 'authorsNote',
      '3_vectors': 'vectorsMemory',
      '4_vectors_data_bank': 'vectorsDataBank',
      'chromadb': 'smartContext',
    };
    void extension(PromptInjection injection, String id, {bool forceSystem = false, bool unknown = false}) {
      final prompt = marker(
        id,
        injection.fragment.content,
        [injection.fragment.source],
        role: forceSystem ? 'system' : injection.role,
        fragments: decoratedInjection(injection) ? injectionPieces(injection) : null,
      );
      prompt.placement = injection.placement == PromptPlacement.inChat ? null : injection.placement;
      prompt.extension = unknown;
    }

    // ST prepares known extensions even when their relative position is false
    // (e.g. an in-chat author's note). That early macro pass is observable.
    for (final entry in knownExtensions.entries) {
      final injection = input.injections.where((item) => item.fragment.source.id == entry.key).firstOrNull;
      if (injection != null && injectionHasContent(injection)) {
        extension(injection, entry.value, forceSystem: entry.key == '3_vectors' || entry.key == 'chromadb');
      }
    }
    if (input.persona.isNotEmpty && input.personaInPrompt) {
      marker('personaDescription', input.persona, const [PromptSource('persona', 'description')]);
    }
    final occupiedExtensionIds = <String>{
      for (final prompt in prompts) prompt.id,
      for (final injection in input.injections) injection.fragment.source.id.replaceAll(RegExp(r'\W'), '_'),
      ...knownExtensions.values,
    };
    var isolatedExtensionIndex = 0;
    for (final injection in input.injections) {
      final key = injection.fragment.source.id;
      if (injection.placement == PromptPlacement.inChat ||
          !injectionHasContent(injection) ||
          knownExtensions.containsKey(key) ||
          const {'PERSONA_DESCRIPTION', 'QUIET_PROMPT', 'DEPTH_PROMPT'}.contains(key)) {
        continue;
      }
      var identifier = key.replaceAll(RegExp(r'\W'), '_');
      if (injection.fragment.source.kind == 'scriptInjection') {
        do {
          identifier = 'scriptPrivateExtension${isolatedExtensionIndex++}';
        } while (!occupiedExtensionIds.add(identifier));
      }
      extension(injection, identifier, unknown: true);
    }
    for (final pair in [('main', 'system_prompt'), ('jailbreak', 'post_history_instructions')]) {
      final prompt = get(pair.$1);
      if (prompt != null &&
          !disabled.contains(pair.$1) &&
          prompt.data['forbid_overrides'] != true &&
          field(pair.$2).isNotEmpty) {
        prompt.content = prepareText(prompt.id, field(pair.$2), {'original': prompt.content});
        prompt.sources = [cardSource(pair.$2), ...prompt.sources];
      }
    }
  }

  PromptSource get prefillSource =>
      PromptSource('preset', 'assistant_prefill', details: {'enhanced': true, 'target': prefillTarget});

  PromptHistoryWindow? admit() {
    prepare();
    PromptSegment? configuredPrefill;
    if (enhancedPrefillEnabled && type == 'continue') {
      excluded.add(PromptExclusion('assistant_prefill', 'enhanced-prefill-continue', [prefillSource]));
    } else if (enhancedPrefillEnabled && setting('assistant_prefill').isNotEmpty) {
      final text = expand(setting('assistant_prefill'));
      if (_hasPrefillText(text)) {
        configuredPrefill = message(_Prompt('enhancedAssistantPrefill', text, [prefillSource], role: 'assistant'));
      } else {
        excluded.add(PromptExclusion('assistant_prefill', 'empty-prefill', [prefillSource]));
      }
    }
    for (final id in [
      'worldInfoBefore',
      'main',
      'worldInfoAfter',
      'charDescription',
      'charPersonality',
      'scenario',
      'personaDescription',
    ]) {
      addFixed(id);
    }
    final controls = <PromptSegment>[];
    if (type == 'impersonate') controls.add(message(get('impersonate')!));
    if (get('quietPrompt')!.content.isNotEmpty) controls.add(message(get('quietPrompt')!));
    for (final control in controls) {
      reserve(control);
    }
    final relativeIds = prompts.where((p) => p.data['system_prompt'] == false && !p.absolute).map((p) => p.id);
    for (final id in ['nsfw', 'jailbreak', ...relativeIds, 'enhanceDefinitions']) {
      addFixed(id);
    }
    if (preparedBiasHasContent ?? input.bias.trim().isNotEmpty) addFixed('bias');
    final absolute = prompts.where((prompt) => prompt.absolute).map((prompt) => prompt.copy()).toList();
    final depthExtensions = input.injections
        .where((injection) => injection.placement == PromptPlacement.inChat && injectionHasContent(injection))
        .toList();
    // Resolve the final collection after identifier normalization/replacement.
    // ST intentionally has separate known and extension loops: an unknown key
    // which replaces a known id can therefore be injected by both loops.
    final relativeInjections = <_Prompt>[
      for (final id in ['summary', 'authorsNote', 'vectorsMemory', 'vectorsDataBank', 'smartContext'])
        if (get(id)?.placement != null) get(id)!,
      ...prompts.where((prompt) => prompt.extension && prompt.placement != null),
    ];
    for (final prepared in relativeInjections) {
      final placement = prepared.placement!;
      final prompt = prepared.copy();
      final mainCollection = collections['main'];
      if (mainCollection != null) {
        final segments = messages(prompt);
        for (final segment in segments) {
          spend(segment);
        }
        if (placement == PromptPlacement.beforeMain) {
          mainCollection.insertAll(0, segments);
        } else {
          mainCollection.addAll(segments);
        }
      } else {
        final mainIndex = absolute.indexWhere((prompt) => prompt.id == 'main');
        if (mainIndex >= 0) {
          final main = absolute[mainIndex];
          prompt.role = main.role;
          prompt.data = {...main.data};
          for (final piece in promptPieces(prompt)) {
            if (!piece.explicitRole) piece.role = main.role;
            piece.data = {...main.data};
          }
          absolute.insert(mainIndex + (placement == PromptPlacement.afterMain ? 1 : 0), prompt);
        }
      }
    }
    if (tools.isNotEmpty) {
      final toolData = {'tools': tools, if (input.toolChoice != null) 'tool_choice': input.toolChoice};
      remaining -= counter.countMessage({'role': 'user', 'content': jsonEncode(toolData)});
      makeRoom(0);
    }
    var history = historyPrompts();
    var cyclePrompt = input.history.where((item) => !item.hidden && !item.isSystem).lastOrNull?.content ?? '';
    if (type == 'continue' && !cyclePrompt.endsWith(' ')) cyclePrompt += setting('continue_postfix');
    if (type == 'continue' && settings['continue_prefill'] == true && history.isNotEmpty) {
      final last = history.removeLast();
      final prefill = message(
        _Prompt('continuePrefill', last.content, last.sources, role: last.role, data: last.data),
        includeName: settings['names_behavior'] == 1,
      );
      controls.add(prefill);
      reserve(prefill);
    }
    final worldPrefill = <PromptSegment>[
      for (var i = 0; i < input.assistantPrefill.length; i++)
        message(
          _Prompt(
            'worldPrefill-$i',
            input.assistantPrefill[i].expandMacros
                ? expand(input.assistantPrefill[i].content)
                : input.assistantPrefill[i].content,
            [input.assistantPrefill[i].source],
            role: 'assistant',
            expandMacros: input.assistantPrefill[i].expandMacros,
            trimGroup: groupFor(input.assistantPrefill[i]),
          ),
        ),
    ];
    for (final prefill in worldPrefill) {
      reserve(prefill);
    }
    if (configuredPrefill != null) {
      spend(configuredPrefill);
    }
    history = injectDepth(absolute, depthExtensions, history);
    if (input.pinExamples) {
      addExamples();
      addHistory(history, cyclePrompt);
    } else {
      addHistory(history, cyclePrompt);
      addExamples();
    }
    for (final control in controls) {
      commitReserved(control);
    }
    tail.addAll(controls);
    if (controls.isNotEmpty) managerTails['controlPrompts'] = controls;
    for (final prefill in worldPrefill) {
      commitReserved(prefill);
    }
    // CCV3 prefill follows all native controls. An explicitly enabled preset
    // prefix may follow it; its reasoning channel keeps a separate boundary.
    tail.addAll(worldPrefill);
    if (worldPrefill.isNotEmpty) managerTails['dshWorldPrefill'] = worldPrefill;
    if (configuredPrefill != null) {
      tail.add(configuredPrefill);
      managerTails['dshConfiguredPrefill'] = [configuredPrefill];
    }
    // The decorator says "reaches" maximum context, including an exact fit.
    // This has no effect without optional fragments and never re-expands text.
    makeRoom(1);
    // Unpinned examples have already made their ordinary admission choices.
    // Releasing extra history space any earlier would let them refill it.
    return finishHistoryWindow();
  }

  PromptManagerSnapshot managerSnapshot() {
    PromptManagerMessage message(PromptSegment segment) => PromptManagerMessage(
      segment,
      identifier: logicalIdentifiers.containsKey(segment)
          ? logicalIdentifiers[segment]
          : segment.message['role'] == 'tool'
          ? segment.message['tool_call_id'] as String?
          : segment.id,
    );
    final snapshot = PromptManagerSnapshot([
      for (final id in prompts.map((prompt) => prompt.id).toSet())
        if (collections.containsKey(id))
          PromptManagerCollection(id, [
            for (final segment
                in id == 'chatHistory' && historyStoredNewestFirst ? collections[id]!.reversed : collections[id]!)
              if (!removed(segment)) message(segment),
          ]),
      for (final entry in managerTails.entries)
        PromptManagerCollection(entry.key, [
          for (final segment in entry.value)
            if (!removed(segment)) message(segment),
        ]),
    ]);
    return settings['squash_system_messages'] == true ? snapshot.squashSystems() : snapshot;
  }

  PromptAssembly run() {
    PromptHistoryWindow? nextHistoryWindow;
    try {
      nextHistoryWindow = admit();
    } finally {
      // A failed admission publishes only objects already added to root.
      // This runs before MI and does not retry expansions or token admission.
      onPromptManager?.call(managerSnapshot());
    }
    var flattened = <PromptSegment>[
      for (final id in prompts.map((prompt) => prompt.id).toSet())
        for (final segment in collections[id] ?? const <PromptSegment>[])
          if (!removed(segment)) inCollection(segment, id),
      for (final segment in tail)
        if (!removed(segment)) historyTail.contains(segment) ? inCollection(segment, 'chatHistory') : segment,
    ];
    flattened = spresetInjectSegments(
      flattened.where(meaningful).toList(),
      spreset,
      input.spresetProvider ??
          SPresetProvider(source: input.deepseek ? 'deepseek' : input.chatCompletionSource, model: input.model),
      counter,
      onDiagnostic: (stage, error) {
        excluded.add(PromptExclusion('SPreset.$stage', '$error', const [PromptSource('control', 'SPreset')]));
        input.onSPresetDiagnostic?.call(stage, error);
      },
    );
    if (settings['squash_system_messages'] == true) flattened = squash(flattened);
    // The SPreset hook may replace its nonempty placeholder with an empty
    // content channel carrying reasoning/signatures/tools. ST retains it.
    final before = flattened;
    final stops = preparedStops == null
        ? input.stops.where((stop) => stop.isNotEmpty).map((stop) => expand(stop)).toList()
        : List<String>.of(preparedStops!());
    return finish(before, stops: stops, nextHistoryWindow: nextHistoryWindow);
  }

  PromptAssembly finish(
    List<PromptSegment> before, {
    required List<String> stops,
    PromptAssembly? original,
    PromptHistoryWindow? nextHistoryWindow,
  }) {
    final last = before.lastOrNull;
    final enhancedTail =
        enhancedPrefillEnabled &&
        type != 'continue' &&
        last != null &&
        last.message['role'] == 'assistant' &&
        _hasPrefillText(presetContent(last.message['content'])) &&
        !last.message.containsKey('tool_calls') &&
        !last.message.containsKey('tool_call_id') &&
        last.sources.isNotEmpty &&
        last.sources.every((source) => source.kind == 'preset');
    if (enhancedTail && prefillTarget == 'reasoning' && !input.deepseek) {
      excluded.add(PromptExclusion(before.last.id, 'reasoning-prefill-unsupported', before.last.sources));
    } else if (enhancedPrefillEnabled && type != 'continue' && prefillTarget == 'reasoning' && !enhancedTail) {
      excluded.add(PromptExclusion('assistant_prefill', 'no-preset-prefill-tail', [prefillSource]));
    }
    final converted = postProcessPrompt(
      before,
      presetString(settings['custom_prompt_post_processing']),
      userName: input.userName,
      characterName: characterName,
      groupNames: input.groupNames,
      counter: counter,
      separateLast: enhancedTail && input.deepseek && prefillTarget == 'reasoning' && settings['show_thoughts'] == true,
    );
    final after = input.deepseek
        ? postProcessDeepSeek(
            converted,
            userName: input.userName,
            characterName: characterName,
            groupNames: input.groupNames,
            tools: tools,
            enhancedPrefill: enhancedTail,
            reasoningPrefill: enhancedTail && prefillTarget == 'reasoning' && settings['show_thoughts'] == true,
            counter: counter,
          )
        : converted;
    final body = input.deepseek
        ? deepSeekRequestBody(
            messages: after,
            settings: settings,
            model: input.model,
            generationType: type,
            stops: stops,
            tools: tools,
            toolChoice: input.toolChoice,
          )
        : genericBody(after, stops);
    return PromptAssembly(
      body: body,
      beforePostProcessing: before,
      afterPostProcessing: after,
      excluded: excluded,
      budget: original?.budget ?? budget,
      remainingBudget: original?.remainingBudget ?? remaining,
      counterName: original?.counterName ?? counter.name,
      exactTokenCounts: original?.exactTokenCounts ?? counter.exact,
      historyWindow: original?.historyWindow ?? nextHistoryWindow,
    );
  }

  List<_Prompt> historyPrompts() {
    final result = <_Prompt>[];
    final names = settings['names_behavior'];
    for (final item in historyPrefix) {
      if (item.hidden || item.isSystem) {
        excluded.add(
          PromptExclusion(item.id, item.hidden ? 'hidden' : 'is_system', [
            PromptSource('history', item.id, label: item.name),
          ]),
        );
      } else {
        // Keep the original depth positions. The proven overflowing real
        // suffix stops addHistory before these unread bodies are evaluated.
        result.add(
          _historyPrompt(item, namesBehavior: names, userName: input.userName, group: input.groupNames.isNotEmpty),
        );
      }
    }
    for (final item in input.history) {
      if (item.hidden || item.isSystem) {
        excluded.add(
          PromptExclusion(item.id, item.hidden ? 'hidden' : 'is_system', [
            PromptSource('history', item.id, label: item.name),
          ]),
        );
        continue;
      }
      result.add(
        _historyPrompt(item, namesBehavior: names, userName: input.userName, group: input.groupNames.isNotEmpty),
      );
    }
    return result;
  }

  List<_Prompt> injectDepth(List<_Prompt> absolute, List<PromptInjection> extensions, List<_Prompt> history) {
    if (!absolute.any(
          (prompt) => prompt.pieces != null || prompt.explicitRole || prompt.trimGroup != null || !prompt.expandMacros,
        ) &&
        !extensions.any((injection) => injection.v3Depth || decoratedInjection(injection))) {
      return injectDepthLegacy(absolute, extensions, history);
    }
    final ownPieces = [for (final prompt in absolute) ...promptPieces(prompt)];
    final extensionPieces = <_DepthExtension>[];
    for (final injection in extensions) {
      if (injection.depth < 0 || (!injection.v3Depth && injection.depth > 10000)) continue;
      for (final fragment in injectionPieces(injection)) {
        extensionPieces.add(_DepthExtension(injection, fragment, extensionPieces.length));
      }
    }
    final reversed = history.reversed.toList();
    final depths = <int>{
      for (final prompt in ownPieces)
        if (prompt.depth != null && prompt.content.isNotEmpty) prompt.depth!,
      for (final piece in extensionPieces) piece.injection.depth,
    }.toList()..sort();
    var inserted = 0;
    for (final depth in depths) {
      final atDepth = ownPieces.where((prompt) => prompt.depth == depth).toList();
      final orders = <num>{
        100,
        ...atDepth.where((prompt) => prompt.content.isNotEmpty).map((prompt) => prompt.order),
      }.toList()..sort((a, b) => b.compareTo(a));
      final injected = <_Prompt>[];
      for (final order in orders) {
        for (final role in ['system', 'user', 'assistant']) {
          final allOwn = atDepth.where((prompt) => prompt.order == order && prompt.role == role).toList();
          final own = allOwn.where((prompt) => prompt.content.isNotEmpty).toList();
          final ext = order == 100
              ? extensionPieces.where((piece) => piece.injection.depth == depth && piece.role == role).toList()
              : <_DepthExtension>[];
          ext.sort((a, b) {
            final byKey = (a.injection.sortKey ?? a.injection.fragment.source.id).compareTo(
              b.injection.sortKey ?? b.injection.fragment.source.id,
            );
            if (byKey != 0) return byKey;
            final bySource = a.injection.sourceOrder.compareTo(b.injection.sourceOrder);
            return bySource != 0 ? bySource : a.index.compareTo(b.index);
          });
          final split =
              own.any((prompt) => prompt.explicitRole || prompt.trimGroup != null || !prompt.expandMacros) ||
              ext.any((piece) => decoratedInjection(piece.injection));
          if (!split) {
            final ownText = own.map((prompt) => prompt.content).join('\n');
            final extensionRaw = ext.map((piece) => trimJsWhitespace(piece.fragment.content)).join('\n');
            final extensionText = extensionRaw.isEmpty ? '' : expand(extensionRaw);
            final text = [ownText, extensionText].where((text) => text.isNotEmpty).map(trimJsWhitespace).join('\n');
            if (text.isEmpty) continue;
            injected.add(
              _Prompt(
                'depth-$depth-$order-$role',
                text,
                [for (final prompt in own) ...prompt.sources, for (final piece in ext) piece.fragment.source],
                role: role,
                injected: true,
              ),
            );
            continue;
          }
          // A role or trim boundary needs an independent message. Keep the
          // complete entry together so later refunds cannot erase base AN text
          // or another mandatory entry in the same native depth group.
          final parts = <_Prompt>[];
          // Other sources can activate between turns. Only this source's own
          // occurrence distinguishes its pieces; empty declarations still count.
          final sourceOccurrences = <String, int>{};
          final windowIds = <Object, String>{};
          void rememberWindowId(Object piece, List<PromptSource> sources) {
            final key = jsonEncode([
              for (final source in sources) [source.kind, source.id],
            ]);
            final occurrence = sourceOccurrences[key] ?? 0;
            sourceOccurrences[key] = occurrence + 1;
            windowIds[piece] = 'depth-$depth-$order-$role-source-$occurrence';
          }

          for (final prompt in allOwn) {
            rememberWindowId(prompt, prompt.sources);
          }
          for (final piece in ext) {
            rememberWindowId(piece, [piece.fragment.source]);
          }

          for (final prompt in own) {
            final text = trimJsWhitespace(prompt.content);
            if (text.isEmpty) continue;
            parts.add(
              _Prompt(
                'depth-$depth-$order-$role-piece-${parts.length}',
                text,
                prompt.sources,
                windowId: windowIds[prompt]!,
                role: role,
                injected: true,
                trimGroup: prompt.trimGroup,
                expandMacros: prompt.expandMacros,
              ),
            );
          }
          for (final piece in ext) {
            final raw = trimJsWhitespace(piece.fragment.content);
            final text = raw.isEmpty ? '' : trimJsWhitespace(piece.fragment.expandMacros ? expand(raw) : raw);
            if (text.isEmpty) continue;
            final sources = [piece.fragment.source];
            parts.add(
              _Prompt(
                'depth-$depth-$order-$role-piece-${parts.length}',
                text,
                sources,
                windowId: windowIds[piece]!,
                role: role,
                injected: true,
                trimGroup: groupFor(piece.fragment),
                expandMacros: piece.fragment.expandMacros,
              ),
            );
          }
          // The outer algorithm reverses the full history. Reverse this one
          // group now to retain its final entry order, while leaving the ST
          // assistant/user/system and low/high-order group sequence intact.
          injected.addAll(parts.reversed);
        }
      }
      final desired = depth + inserted;
      reversed.insertAll(desired < reversed.length ? desired : reversed.length, injected);
      inserted += injected.length;
    }
    return reversed.reversed.toList();
  }

  List<_Prompt> injectDepthLegacy(List<_Prompt> absolute, List<PromptInjection> extensions, List<_Prompt> history) {
    final reversed = history.reversed.toList();
    final depths = <int>{
      for (final p in absolute)
        if (p.depth != null && p.depth! >= 0 && p.content.isNotEmpty) p.depth!,
      for (final p in extensions)
        if (p.depth >= 0 && p.depth <= 10000) p.depth,
    }.toList()..sort();
    var inserted = 0;
    for (final depth in depths) {
      final atDepth = absolute.where((prompt) => prompt.depth == depth && prompt.content.isNotEmpty).toList();
      final orders = <num>{100, ...atDepth.map((prompt) => prompt.order)}.toList()..sort((a, b) => b.compareTo(a));
      final messages = <_Prompt>[];
      for (final order in orders) {
        for (final role in ['system', 'user', 'assistant']) {
          final own = atDepth.where((prompt) => prompt.order == order && prompt.role == role).toList();
          final ext = order == 100
              ? extensions.where((prompt) => prompt.depth == depth && prompt.role == role).toList()
              : <PromptInjection>[];
          final ownText = own.map((prompt) => prompt.content).join('\n');
          ext.sort((a, b) {
            final byKey = (a.sortKey ?? a.fragment.source.id).compareTo(b.sortKey ?? b.fragment.source.id);
            return byKey != 0 ? byKey : a.sourceOrder.compareTo(b.sourceOrder);
          });
          final extensionRaw = ext.map((prompt) => trimJsWhitespace(prompt.fragment.content)).join('\n');
          final extensionText = extensionRaw.isEmpty ? '' : expand(extensionRaw);
          final text = [ownText, extensionText].where((text) => text.isNotEmpty).map(trimJsWhitespace).join('\n');
          if (text.isEmpty) continue;
          messages.add(
            _Prompt(
              'depth-$depth-$order-$role',
              text,
              [for (final prompt in own) ...prompt.sources, for (final prompt in ext) prompt.fragment.source],
              role: role,
              injected: true,
            ),
          );
        }
      }
      final desired = depth + inserted;
      reversed.insertAll(desired < reversed.length ? desired : reversed.length, messages);
      inserted += messages.length;
    }
    return reversed.reversed.toList();
  }

  void addHistory(List<_Prompt> history, String cyclePrompt) {
    if (get('chatHistory') == null) return;
    final reverseOutput = <PromptSegment>[];
    collections['chatHistory'] = reverseOutput;
    historyStoredNewestFirst = true;
    final newChatKey = input.groupNames.isEmpty ? 'new_chat_prompt' : 'new_group_chat_prompt';
    final newChat = message(_Prompt('newMainChat', expand(setting(newChatKey)), [PromptSource('control', newChatKey)]));
    reserve(newChat);
    final groupNudge = input.groupNames.isNotEmpty && type != 'impersonate' ? message(get('groupNudge')!) : null;
    if (groupNudge != null) reserve(groupNudge);
    final continuation = <PromptSegment>[];
    if (type == 'continue' && cyclePrompt.isNotEmpty && settings['continue_prefill'] != true) {
      final nudge = expand(setting('continue_nudge_prompt'), {'lastChatMessage': cyclePrompt.trim()});
      final index = history.lastIndexWhere((prompt) => !prompt.injected);
      if (index >= 0) {
        final continued = message(history.removeAt(index), expandText: true);
        continuation.add(continued);
        // ST displaces the original chat object before assigning loop IDs.
        logicalIdentifiers[continued] = null;
      }
      continuation.add(
        message(_Prompt('continueNudge', expand(nudge), const [PromptSource('control', 'continue_nudge_prompt')])),
      );
      for (final segment in continuation) {
        reserve(segment);
      }
    }
    final emptyUser = message(
      _Prompt('emptyUserMessageReplacement', setting('send_if_empty'), const [
        PromptSource('control', 'send_if_empty'),
      ], role: 'user'),
    );
    if (history.isNotEmpty && history.last.role == 'assistant' && emptyUser.message['content'] != '') {
      makeRoom(emptyUser.tokens);
      if (emptyUser.tokens <= remaining) {
        spend(emptyUser);
        reverseOutput.add(emptyUser);
      }
    }
    final pool = history.reversed.toList();
    for (var i = 0; i < pool.length; i++) {
      final prompt = pool[i];
      if (prompt.injected && historyWindow?.excludedInjections.contains(injectionKey(prompt)) == true) {
        excluded.add(PromptExclusion(prompt.id, 'cache-friendly-window', prompt.sources));
        continue;
      }
      if (cacheFriendlyTrimming && !prompt.injected) {
        if (olderHistory.contains(prompt.id)) {
          excluded.add(PromptExclusion(prompt.id, 'cache-friendly-window', prompt.sources));
          continue;
        }
        if (unreadHistory.contains(prompt.id)) {
          // Preflight supplies identities, not zero-token history. If an
          // existing window lets us reach them, they still cannot be admitted.
          historyOverflow = true;
          excluded.add(PromptExclusion(prompt.id, 'history-budget', prompt.sources));
          continue;
        }
      }
      final segment = message(prompt, expandText: true, includeName: settings['names_behavior'] == 1);
      logicalIdentifiers[segment] = segment.message['role'] == 'tool'
          ? segment.message['tool_call_id'] as String?
          : '${segment.message.containsKey('tool_calls') ? 'toolCall-' : ''}chatHistory-${pool.length - i}';
      makeRoom(segment.tokens);
      if (removed(segment)) continue;
      if (segment.tokens > remaining) {
        final group = segmentGroups[segment];
        if (group != null) {
          drop(group);
          continue;
        }
        for (final dropped in pool.skip(i)) {
          // An injected depth piece can be the first miss while its older
          // tail still contains eligible history. That is also a history
          // overflow; already excluded old-window nodes alone are not.
          if (cacheFriendlyTrimming && !dropped.injected && !olderHistory.contains(dropped.id)) {
            historyOverflow = true;
          }
          final tailGroup = dropped.trimGroup;
          // These older entries have not been visited/charged. Still report
          // optional exclusions so WI persistence cannot count an unsent
          // admission. Reading prepared metadata must not expand their macros.
          if (tailGroup != null) {
            drop(tailGroup);
            continue;
          }
          if (cacheFriendlyTrimming && dropped.injected) excludedInjections.add(injectionKey(dropped));
          excluded.add(PromptExclusion(dropped.id, 'history-budget', dropped.sources));
        }
        break;
      }
      if (meaningful(segment)) {
        spend(segment);
        reverseOutput.add(segment);
      }
    }
    commitReserved(newChat);
    // Keep newest-first expansion and budgeting, then order references once.
    final output = <PromptSegment>[newChat, ...reverseOutput.reversed];
    collections['chatHistory'] = output;
    historyStoredNewestFirst = false;
    if (groupNudge != null) {
      commitReserved(groupNudge);
      output.add(groupNudge);
    }
    for (final segment in continuation) {
      commitReserved(segment);
    }
    historyTail.addAll(continuation);
    tail.addAll(continuation);
    if (continuation.isNotEmpty) managerTails['continueNudge'] = continuation;
  }

  void prepareExamples() {
    List<_ExampleBlock> parse(String text, PromptSource source, {String? role, _TrimGroup? trimGroup}) {
      if (role != null) {
        // CCV3 gives the complete entry a role. Keep its body even when it has
        // no ST dialogue-speaker prefix, which the native example parser drops.
        return [
          _ExampleBlock(
            [
              {'role': role, 'content': text},
            ],
            source,
            trimGroup: trimGroup,
          ),
        ];
      }
      return [
        for (final block in parseDialogueExamples(
          text,
          userName: input.userName,
          characterName: characterName,
          groupNames: input.groupNames,
        ))
          _ExampleBlock(block, source, trimGroup: trimGroup),
      ];
    }

    exampleBlocks.addAll(
      parse(field('mes_example'), PromptSource('card', '${input.characterId}:mes_example', label: 'mes_example')),
    );
    final examples = [
      if (input.examplesBefore.isNotEmpty)
        PromptExample(
          before: true,
          fragment: PromptFragment(input.examplesBefore, const PromptSource('world', 'examplesBefore')),
        ),
      ...input.worldExamples,
      if (input.examplesAfter.isNotEmpty)
        PromptExample(
          before: false,
          fragment: PromptFragment(input.examplesAfter, const PromptSource('world', 'examplesAfter')),
        ),
    ];
    for (final example in examples) {
      if (example.fragment.content.isEmpty) continue;
      // S4646 applies baseChatReplace again, after the WI activation expansion.
      // Keep mixed order for side effects; each before item unshifts its blocks.
      final blocks = parse(
        example.fragment.expandMacros ? baseExpand(example.fragment.content) : example.fragment.content,
        example.fragment.source,
        role: example.fragment.role,
        trimGroup: groupFor(example.fragment),
      );
      if (example.before) {
        exampleBlocks.insertAll(0, blocks);
      } else {
        exampleBlocks.addAll(blocks);
      }
    }
  }

  void addExamples() {
    if (get('dialogueExamples') == null || input.stripExamples) return;
    final output = <PromptSegment>[];
    collections['dialogueExamples'] = output;
    if (exampleBlocks.isEmpty) return;
    final prefix = message(
      _Prompt('newChat', expand(setting('new_example_chat_prompt')), const [
        PromptSource('control', 'new_example_chat_prompt'),
      ]),
    );
    final sourceBlocks = <({String kind, String id}), int>{};
    for (var i = 0; i < exampleBlocks.length; i++) {
      final entry = exampleBlocks[i];
      final block = entry.messages;
      final source = entry.source;
      final group = entry.trimGroup;
      final sourceKey = (kind: source.kind, id: source.id);
      final blockIndex = sourceBlocks[sourceKey] ?? 0;
      sourceBlocks[sourceKey] = blockIndex + 1;
      final key = (kind: source.kind, id: source.id, block: blockIndex);
      if (group?.removed == true) continue;
      if (historyWindow != null && !historyWindow!.admittedExamples.contains(key)) {
        excluded.add(PromptExclusion('dialogueExamples-$i', 'cache-friendly-window', [source]));
        if (group != null) drop(group);
        continue;
      }
      // Native blocks share their immutable prefix. An optional entry needs
      // its own charged instance so dropping it cannot remove another block.
      final blockPrefix = group == null
          ? prefix
          : PromptSegment(id: prefix.id, message: prefix.message, sources: prefix.sources, tokens: prefix.tokens);
      final candidates = <PromptSegment>[blockPrefix];
      for (var j = 0; j < block.length; j++) {
        final data = block[j];
        candidates.add(
          PromptSegment(
            id: 'dialogueExamples-$i-$j',
            message: data,
            sources: [source],
            tokens: counter.countMessage(data),
          ),
        );
      }
      for (final segment in candidates) {
        track(segment, group);
      }
      final cost = candidates.fold<int>(0, (sum, segment) => sum + segment.tokens);
      makeRoom(cost);
      if (group?.removed == true) continue;
      if (cost > remaining) {
        if (group != null) {
          drop(group);
          continue;
        }
        excluded.add(PromptExclusion('dialogueExamples-$i', 'whole-example-budget', [source]));
        for (final dropped in exampleBlocks.skip(i + 1)) {
          final tailGroup = dropped.trimGroup;
          if (tailGroup != null) drop(tailGroup);
        }
        break;
      }
      if (cacheFriendlyTrimming) admittedExamples[key] = group;
      for (final segment in candidates) {
        // ST canAffordAll counts empty named examples; insert then skips them.
        if (!meaningful(segment)) continue;
        spend(segment);
        output.add(segment);
      }
    }
  }

  bool actualHistory(PromptSegment segment) =>
      segment.sources.length == 1 &&
      segment.sources.single.kind == 'history' &&
      segment.sources.single.id == segment.id;

  bool trimmableHistory(PromptSegment segment) =>
      actualHistory(segment) &&
      segment.message['role'] != 'tool' &&
      !segment.message.containsKey('tool_calls') &&
      !segment.message.containsKey('tool_call_id');

  String injectionKey(_Prompt prompt) => jsonEncode([
    prompt.windowId,
    [
      for (final source in prompt.sources) [source.kind, source.id],
    ],
  ]);

  PromptHistoryWindow? finishHistoryWindow() {
    if (!cacheFriendlyTrimming || (!historyOverflow && historyWindow == null)) return null;
    final history = collections['chatHistory'];
    if (historyOverflow && history != null) {
      var tokens = 0;
      var count = 0;
      String? latestUser;
      for (final segment in history) {
        if (!trimmableHistory(segment)) continue;
        tokens += segment.tokens * (charges[segment] ?? 0);
        count++;
        if (segment.message['role'] == 'user') latestUser = segment.id;
      }
      // Everything else has already been charged: fixed prompts, examples,
      // tools, controls, continuation and retained depth injections. Only the
      // remaining pure-history allowance receives the 75% target.
      final target = (remaining + tokens) * 3 ~/ 4;
      final trimmed = <PromptSegment>{};
      for (final segment in history) {
        if (tokens <= target || count <= 1) break;
        if (!actualHistory(segment)) continue;
        // Advancing a single prefix cannot leave a protected tool exchange
        // behind and then remove later history. The target is best effort.
        if (!trimmableHistory(segment) || segment.id == latestUser) break;
        final refund = segment.tokens * (charges.remove(segment) ?? 0);
        remaining += refund;
        tokens -= refund;
        count--;
        trimmed.add(segment);
        excluded.add(PromptExclusion(segment.id, 'cache-friendly-trim', segment.sources));
      }
      history.removeWhere(trimmed.contains);
    }
    String? firstNodeId = historyWindow?.firstNodeId;
    if (historyOverflow) {
      // Read physical sources before squash or DeepSeek can combine them with
      // controls/injections. Continue-prefill carries its original source id.
      firstNodeId = (history ?? const <PromptSegment>[])
          .followedBy(tail)
          .where((segment) => !removed(segment))
          .expand((segment) => segment.sources)
          .where((source) => source.kind == 'history')
          .firstOrNull
          ?.id;
    }
    if (firstNodeId == null) return null;
    return PromptHistoryWindow(
      firstNodeId: firstNodeId,
      admittedExamples: [
        for (final entry in admittedExamples.entries)
          if (entry.value?.removed != true) entry.key,
      ],
      excludedOptionalSources: {
        ...?historyWindow?.excludedOptionalSources,
        for (final group in trimGroups.values)
          if (group.removed) (kind: group.source.kind, id: group.source.id),
      },
      excludedInjections: {...?historyWindow?.excludedInjections, ...excludedInjections},
    );
  }

  PromptSegment inCollection(PromptSegment segment, String id) => PromptSegment(
    id: segment.id,
    message: segment.message,
    sources: segment.sources,
    tokens: segment.tokens,
    collectionId: id,
  );

  List<PromptSegment> squash(List<PromptSegment> input) {
    const protected = {'newMainChat', 'newChat', 'groupNudge'};
    bool eligible(PromptSegment message) =>
        message.message['role'] == 'system' && !message.message.containsKey('name') && !protected.contains(message.id);
    final result = <PromptSegment>[];
    for (final segment in input) {
      if (segment.message['role'] == 'system' && segment.message['content'] == '') continue;
      if (result.isNotEmpty && eligible(result.last) && eligible(segment)) {
        final previous = result.removeLast();
        final data = {...previous.message, 'content': '${previous.message['content']}\n${segment.message['content']}'};
        result.add(
          PromptSegment(
            id: previous.id,
            message: data,
            sources: [...previous.sources, ...segment.sources],
            tokens: counter.countMessage(data),
            collectionId: previous.collectionId == segment.collectionId ? previous.collectionId : null,
          ),
        );
      } else {
        result.add(segment);
      }
    }
    return result;
  }

  Map<String, Object?> genericBody(List<PromptSegment> messages, List<String> stops) => genericChatRequestBody(
    messages: messages,
    settings: settings,
    model: input.model,
    generationType: type,
    stops: stops,
    tools: tools,
    toolChoice: input.toolChoice,
    source: input.chatCompletionSource,
  );
}

/// The existing provider parameter projection, exposed independently of prompt
/// assembly so an explicit raw sequence need not manufacture preset prompts.
Map<String, Object?> genericChatRequestBody({
  required List<PromptSegment> messages,
  required Map<String, Object?> settings,
  required String model,
  required String generationType,
  List<String> stops = const [],
  List<Map<String, Object?>> tools = const [],
  Object? toolChoice,
  String source = 'custom',
}) => {
  'messages': messages.map((segment) => segment.message).toList(),
  'model': model,
  'temperature': presetSamplingNumber(settings['temperature']),
  'max_tokens': settings['openai_max_tokens'],
  'stream': settings['stream_openai'] == true && generationType != 'quiet',
  'presence_penalty': presetSamplingNumber(settings['presence_penalty']),
  'frequency_penalty': presetSamplingNumber(settings['frequency_penalty']),
  'top_p': presetSamplingNumber(settings['top_p']),
  if (stops.isNotEmpty) 'stop': stops.take(4).toList(),
  if (presetJsNumber(settings['seed']) >= 0) 'seed': settings['seed'],
  if (tools.isNotEmpty) 'tools': tools,
  if (tools.isNotEmpty && toolChoice != null) 'tool_choice': toolChoice,
  ...genericReasoningFields(settings, model, source),
};

List<PromptSegment> convertExplicitPromptMessages(
  List<PromptSegment> messages, {
  required bool deepseek,
  required String userName,
  required String characterName,
  List<String> groupNames = const [],
  required PromptTokenCounter counter,
}) => deepseek
    ? postProcessDeepSeek(
        messages,
        userName: userName,
        characterName: characterName,
        groupNames: groupNames,
        counter: counter,
      )
    : messages;

Map<String, Object?> explicitPromptRequestBody({
  required List<PromptSegment> messages,
  required Map<String, Object?>? settings,
  required bool deepseek,
  required String model,
  List<String> preparedStops = const [],
}) => settings == null
    ? {
        'model': model,
        'messages': messages.map((message) => message.message).toList(),
        if (preparedStops.isNotEmpty) 'stop': preparedStops.take(4).toList(),
      }
    : deepseek
    ? deepSeekRequestBody(
        messages: messages,
        settings: settings,
        model: model,
        generationType: 'normal',
        stops: preparedStops,
      )
    : genericChatRequestBody(
        messages: messages,
        settings: settings,
        model: model,
        generationType: 'normal',
        stops: preparedStops,
      );

// JS trim's exact WhiteSpace/LineTerminator set. In particular U+0085 NEL is
// meaningful text; Dart String.trim would incorrectly discard that prefix.
bool _hasPrefillText(String value) =>
    RegExp(r'[^\u0009-\u000d\u0020\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]').hasMatch(value);

String sanitizeName(String name) {
  final normalized = name.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');
  return normalized.length > 64 ? normalized.substring(0, 64) : normalized;
}

/// ST parseMesExamples + parseExampleIntoIndividual, including same-speaker
/// continuation lines and the example_user/example_assistant system names.
List<List<Map<String, Object?>>> parseDialogueExamples(
  String text, {
  required String userName,
  required String characterName,
  List<String> groupNames = const [],
}) {
  if (text.isEmpty || text == '<START>') return [];
  if (!text.startsWith('<START>')) text = '<START>\n${trimJsWhitespace(text)}';
  final blocks = text.split(RegExp('<START>', caseSensitive: false)).skip(1);
  final result = <List<Map<String, Object?>>>[];
  for (final block in blocks) {
    final lines = '${trimJsWhitespace(block)}\n'.replaceAll('\r', '').split('\n');
    final messages = <Map<String, Object?>>[];
    var buffer = <String>[];
    String? mode;
    var botName = characterName;
    void flush(String name, String marker) {
      var content = trimJsWhitespace(buffer.join('\n').replaceFirst('$name:', ''));
      if (groupNames.isNotEmpty) content = '$name: $content';
      messages.add({'role': 'system', 'content': content, 'name': marker});
      buffer = [];
    }

    for (final line in lines) {
      if (line.startsWith('$userName:')) {
        if (mode == 'bot') flush(botName, 'example_assistant');
        mode = 'user';
      } else if (line.startsWith('$characterName:') || groupNames.any((name) => line.startsWith('$name:'))) {
        if (!line.startsWith('$characterName:') && groupNames.isNotEmpty) botName = line.split(':').first;
        if (mode == 'user') flush(userName, 'example_user');
        mode = 'bot';
      }
      buffer.add(line);
    }
    if (mode == 'user') flush(userName, 'example_user');
    if (mode == 'bot') flush(botName, 'example_assistant');
    result.add(messages);
  }
  return result;
}
