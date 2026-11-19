part of 'engine.dart';

// These preparation segments own no engine or store. The native driver keeps
// its user/secret/reply adoption points between the same segments; authoring
// supplies a detached turn, local variables, a fixed clock and its own RNG.
String _preparePromptRegex(
  _MacroEnvironment environment,
  String input, {
  required int placement,
  required String source,
  RegexPhase phase = RegexPhase.writeBack,
  num? depth,
  List<Map<String, Object?>>? trace,
}) {
  if (trace == null) {
    return environment.regex.apply(
      input,
      placement: placement,
      phase: phase,
      depth: depth,
      expand: environment.regexExpand,
    );
  }
  final result = environment.regex.applyWithDiagnostics(
    input,
    placement: placement,
    phase: phase,
    depth: depth,
    expand: environment.regexExpand,
  );
  trace.add({
    'source': source,
    'placement': placement,
    'phase': phase.name,
    'depth': depth,
    'input': input,
    'output': result.text,
    'replacements': result.replacements,
    'warnings': [for (final warning in result.warnings) warning.toJson()],
  });
  return result.text;
}

String _preparePromptUser(_MacroEnvironment environment, String input, {List<Map<String, Object?>>? regexTrace}) =>
    environment.expand(
      _preparePromptRegex(
        environment,
        input,
        placement: RegexPlacement.userInput,
        source: 'userInput',
        trace: regexTrace,
      ),
      const {},
    );

// Native manual/group messages persist global macro effects before this
// state initialization. Keep it separate from text preparation so that await
// and its failure semantics stay at the native call site.
Map<String, Object?> _prepareAppendedMessageState(
  Map<String, Object?> state,
  _MacroEnvironment environment, {
  required Map<String, Object?> stateCardData,
  required bool stateEnabled,
  _GameplayRuntime? gameplay,
}) {
  final next = <String, Object?>{
    ...state,
    'variables': _copy(environment.local),
    'stChatId': environment.chatId,
    'stChatIdHash': environment.chatIdHash,
  };
  _initializeDshState(gameplay?.state ?? _stateDefinition(stateCardData), next, stateEnabled, gameplay: gameplay);
  return next;
}

String? _expandPromptFirst(List<StoredNode> history, StoredNode? first, _MacroEnvironment environment) {
  if (first == null) {
    return null;
  }
  final expanded = environment.expand(first.message.text, const {});
  if (expanded == first.message.text) {
    return null;
  }
  final index = history.indexWhere((node) => node.message.nodeId == first.message.nodeId);
  if (index >= 0) {
    history[index] = _nodeWithText(first, expanded);
  }
  return expanded;
}

Future<WorldInfoResult> _evaluatePreparedWorld({
  required WorldInfoEngine worldEngine,
  required _Turn turn,
  required _MacroEnvironment environment,
  required PreparedCharacterFields prepared,
  required List<WorldInfoBook> books,
  required List<StoredNode> eligibleHistory,
  required int messageCount,
  required int assistantMessageCount,
  required ChatPreset preset,
  required WorldInfoSettings worldSettings,
  required PromptTokenCounter counter,
  required List<String> scanInjections,
  List<Map<String, Object?>>? regexTrace,
}) {
  return worldEngine.evaluate(
    WorldInfoInput(
      books: books,
      packSources: turn.gameplayResources.packSources,
      packWorldInfo: _gameplayWorldInfoSnapshot(turn.state, turn.gameplayResources),
      externalActivations: turn.directorPrepared?.external ?? const {},
      messages: [
        for (final node in eligibleHistory) WorldInfoMessage(node.message.text, speaker: node.message.speaker),
      ],
      messageCount: messageCount,
      // ST script.js passes getMaxPromptTokens(), excluding the response.
      maxContext: environment.maxContext - environment.maxResponse,
      tokenCount: counter.countText,
      random: environment.random,
      checkCancelled: turn.cancellation.check,
      expand: (text) => environment.expand(text, const {}),
      settings: worldSettings,
      scanInjections: scanInjections,
      personaDescription: prepared.persona,
      characterDescription: prepared['description'],
      characterPersonality: prepared['personality'],
      characterDepthPrompt: prepared['charDepthPrompt'],
      scenario: prepared['scenario'],
      creatorNotes: prepared['creator_notes'],
      trigger: turn.generationType,
      characterName: _characterFilename(turn.settings, turn.actorId),
      characterTags: _characterTags(turn.settings, turn.actorId),
      timedWorldInfo: _map(turn.state['timedWorldInfo']),
      decoratorState: _map(turn.state['decoratorState']),
      assistantMessageCount: assistantMessageCount,
      greetingIndex: turn.state['greetingIndex'] is int ? turn.state['greetingIndex'] as int : null,
      userIconName: turn.settings['userIconName'] as String?,
      contextAtCapacity: false,
      availablePromptSections: _availableWorldSections(preset, turn.generationType),
      postProcessContent: (entry, content, depth) => _preparePromptRegex(
        environment,
        content,
        placement: RegexPlacement.worldInfo,
        phase: RegexPhase.prompt,
        depth: depth,
        source: 'worldInfo',
        trace: regexTrace,
      ),
    ),
  );
}

PromptAssembly _assemblePreparedPrompt({
  required _Turn turn,
  required Map<String, Object?> data,
  required _MacroEnvironment environment,
  required ChatPreset preset,
  required WorldInfoResult world,
  required List<StoredNode> promptHistory,
  required PreparedCharacterFields prepared,
  required List<PromptInjection> injections,
  required PromptTokenCounter counter,
  List<PromptHistoryMessage> prefix = const [],
  PromptHistoryWindow? cacheWindow,
}) {
  final examples = [for (var index = 0; index < world.activated.length; index++) (index, world.activated[index])];
  examples.sort((a, b) {
    final aOrder = a.$2.order;
    final bOrder = b.$2.order;
    final byOrder = aOrder == bOrder ? 0 : bOrder.compareTo(aOrder);
    return byOrder != 0 ? byOrder : a.$1.compareTo(b.$1);
  });
  return assemblePromptWindow(
    PromptAssembler(counter: counter),
    PromptInput(
      preset: preset,
      cacheFriendlyTrimming: switch (turn.settings['cacheFriendlyTrimming']) {
        final bool value => value,
        _ => null,
      },
      historyWindow: cacheWindow,
      card: data,
      history: [for (final node in promptHistory) _promptHistory(node)],
      model: turn.config.model,
      userName: environment.userName,
      characterId: turn.actorId,
      groupNames: turn.groupView?.names ?? const [],
      generationType: turn.generationType,
      deepseek: turn.config.deepseek,
      persona: environment.persona,
      personaInPrompt: turn.settings['personaInPrompt'] != false,
      worldBefore: world.before.map(_worldFragment).toList(),
      worldAfter: world.after.map(_worldFragment).toList(),
      worldSections: {for (final entry in world.sections.entries) entry.key: entry.value.map(_worldFragment).toList()},
      disabledUiPrompts: world.disabledUiPrompts,
      assistantPrefill: [
        if (turn.config.deepseek)
          for (final depth in world.depths)
            for (final hit in depth.entries)
              if (_worldPrefill(hit)) _worldFragment(hit),
      ],
      injections: injections,
      tools: _ordinaryTurnTools(turn),
      worldExamples: [
        for (final item in examples.reversed)
          if (item.$2.content.isNotEmpty && item.$2.section == null && (item.$2.position == 5 || item.$2.position == 6))
            PromptExample(fragment: _worldFragment(item.$2), before: item.$2.position == 5),
      ],
      pinExamples: turn.settings['pinExamples'] == true,
      stripExamples: turn.settings['stripExamples'] == true,
      bias: _string(turn.settings['bias']),
      stops: _strings(turn.settings['stops']),
      expansion: environment.expand,
      cardExpansion: environment.baseExpand,
      preparedFields: prepared,
    ),
    prefix: prefix,
  );
}
