// Port of SillyTavern 1.19.0's legacy macro passes (AGPL-3.0).
// Source: public/scripts/macros.js, variables.js, instruct-mode.js and
// public/script.js at 7e8663cd9c184a550b37238218bdd32c6efc68e9.
part of 'macro_engine.dart';

/// ST's legacy, ordered-regex macro engine for Chat Completion prompts.
///
/// Unlike [MacroEngine], this normally prepares every character field eagerly.
/// It runs one replacement pass per macro kind and does not parse new blocks, variable
/// shorthands, or nested arguments, and does not iterate to a fixed point.
/// Variable maps in [MacroContext] are shared and changed synchronously.
///
/// The optional maps use ST's raw instruct, sysprompt and context-template
/// setting keys. Omitted settings mean disabled instruct/system prompts and
/// empty context delimiters; no UI settings or implicit globals are consulted.
class LegacyMacroEngine {
  const LegacyMacroEngine({this.instruct = const {}, this.systemPrompt = const {}, this.contextTemplate = const {}});

  final Map<String, Object?> instruct;
  final Map<String, Object?> systemPrompt;
  final Map<String, Object?> contextTemplate;

  /// [overrides] retain the old environment's case-sensitive key insertion
  /// order; matching each key remains case insensitive. The exact `original`
  /// key supplies ST's dedicated, single-use original argument, as it does in
  /// [MacroEngine]. Other overrides are additional environment constants.
  ///
  /// [postProcess] receives a replacement's raw value, before JavaScript
  /// ToString: variable macros may return numbers, arrays or objects. A thrown
  /// hook cancels the whole current regex pass but retains earlier variable
  /// effects. A null hook result becomes `null` text. Internal card base
  /// expansion does not inherit this hook.
  /// Per-call card mode and character override have the same scope as in
  /// [MacroEngine.expand]; they do not mutate the shared context.
  /// [prepareCharacterFieldsOnDemand] is the project's explicit raw-source
  /// mode, not ST's default eager timing. Each consumed field is prepared once
  /// per expansion (including a failed preparation); other fields do not run.
  /// The existing replacement-pass order and actual examples rendering stay
  /// intact. Ordinary callers should retain the default false.
  String expand(
    String text,
    MacroContext context, {
    Map<String, String> overrides = const {},
    Object? Function(Object?)? postProcess,
    bool? replaceCharacterCard,
    String? characterOverride,
    bool prepareCharacterFieldsOnDemand = false,
  }) {
    try {
      return _LegacyEvaluation(
        this,
        context,
        text,
        overrides,
        postProcess: postProcess,
        replaceCharacterCard: replaceCharacterCard,
        characterOverride: characterOverride,
        prepareCharacterFieldsOnDemand: prepareCharacterFieldsOnDemand,
      ).evaluate(text);
    } on _MacroDependencyFailure catch (failure) {
      Error.throwWithStackTrace(failure.error, failure.stack);
    }
  }
}

typedef _LegacyPass = ({RegExp regex, Object? Function(Match) replace, bool preserveOnNull});

// Patterns include fixed passes and escaped environment names. Only compiled
// regex objects are shared; replacements retain this evaluation's captures.
const _legacyPatternCacheLimit = 1000;
final _legacyPatterns = <(String, bool, bool), RegExp>{};

RegExp _legacyPattern(String pattern, {required bool caseSensitive, required bool multiLine}) {
  final key = (pattern, caseSensitive, multiLine);
  final cached = _legacyPatterns.remove(key);
  if (cached != null) {
    _legacyPatterns[key] = cached;
    return cached;
  }
  final compiled = RegExp(pattern, caseSensitive: caseSensitive, multiLine: multiLine);
  if (_legacyPatterns.length >= _legacyPatternCacheLimit) _legacyPatterns.remove(_legacyPatterns.keys.first);
  _legacyPatterns[key] = compiled;
  return compiled;
}

_LegacyPass _legacyPass(
  String pattern,
  Object? Function(Match) replace, {
  bool caseSensitive = false,
  bool multiLine = false,
  bool preserveOnNull = false,
}) => (
  regex: _legacyPattern(pattern, caseSensitive: caseSensitive, multiLine: multiLine),
  replace: replace,
  preserveOnNull: preserveOnNull,
);

class _LegacyEvaluation {
  _LegacyEvaluation(
    this.engine,
    this.context,
    String original,
    this.overrides, {
    bool? replaceCharacterCard,
    this.characterOverride,
    this.inheritOriginal = true,
    this.postProcess,
    this.prepareCharacterFieldsOnDemand = false,
  }) : contentHash = MacroEngine.stringHash(original),
       chatIdHash = _truthy(context.chatIdHash) ? context.chatIdHash : MacroEngine.stringHash(context.chatId),
       replaceCharacterCard = replaceCharacterCard ?? context.replaceCharacterCard,
       // Only the common history, dice and clock helpers are used. The new
       // parser/evaluate/field preparation never handles a legacy expansion.
       common = _Evaluation(
         context,
         original,
         const {},
         replaceCharacterCard: false,
         characterOverride: characterOverride,
         inheritOriginal: false,
       );

  final LegacyMacroEngine engine;
  final MacroContext context;
  final Map<String, String> overrides;
  final int contentHash;
  final num chatIdHash;
  final bool replaceCharacterCard;
  final bool prepareCharacterFieldsOnDemand;
  final String? characterOverride;
  final bool inheritOriginal;
  final Object? Function(Object?)? postProcess;
  final _Evaluation common;
  final _environmentDependencies = <String, String>{};

  String evaluate(String text) {
    if (text.isEmpty) return '';
    final env = _environment();
    final passes = <_LegacyPass>[
      _legacyPass(r'<USER>', (_) => _environmentValue(env, 'user')),
      _legacyPass(r'<BOT>', (_) => _environmentValue(env, 'char')),
      _legacyPass(r'<CHAR>', (_) => _environmentValue(env, 'char')),
      _legacyPass(r'<CHARIFNOTGROUP>', (_) => _environmentValue(env, 'group')),
      _legacyPass(r'<GROUP>', (_) => _environmentValue(env, 'group')),
      _legacyPass(r'{{roll[ : ]([^}]+)}}', (match) => common._roll(trimJsWhitespace(match[1]!))),
      ..._instructPasses(env),
      ..._variablePasses(context.localVariables, global: false),
      ..._variablePasses(context.globalVariables, global: true),
      _legacyPass(
        r'{{get_message_variable::([^{}]*)}}',
        (match) => _messageVariableMacro(context, match[1]!),
        preserveOnNull: true,
      ),
      _legacyPass(
        r'{{format_message_variable::([^{}]*)}}',
        (match) => _messageVariableMacro(context, match[1]!, format: true),
        preserveOnNull: true,
      ),
      _legacyPass(r'{{newline}}', (_) => '\n'),
      _legacyPass(r'(?:\r?\n)*{{trim}}(?:\r?\n)*', (_) => ''),
      _legacyPass(r'{{noop}}', (_) => ''),
      _legacyPass(r'{{input}}', (_) => context.input),
    ];

    // ST constructs getPickReplaceMacro before any replacement pass, after
    // the eager character environment and instruct factories are prepared.
    // Its hash lookup happens even when this nonempty text contains no pick.
    context.onChatIdHash?.call(chatIdHash);

    // The legacy registry populates these after instruct values were captured.
    // An additional environment constant with the exact same key is replaced.
    env['isMobile'] = () => '${context.isMobile}';
    env['lastGenerationType'] = () => context.lastGenerationType;
    for (final key in _environmentKeys(env)) {
      passes.add(_legacyPass('{{${RegExp.escape(key)}}}', (_) => _normalize(_environmentValue(env, key))));
    }
    passes.addAll([
      _legacyPass(r'{{maxPrompt}}', (_) => '${context.maxPrompt}'),
      _legacyPass(r'{{maxPromptTokens}}', (_) => '${context.maxPrompt}'),
      _legacyPass(r'{{maxContext}}', (_) => '${context.maxContext}'),
      _legacyPass(r'{{maxContextTokens}}', (_) => '${context.maxContext}'),
      _legacyPass(r'{{maxResponse}}', (_) => '${context.maxResponse}'),
      _legacyPass(r'{{maxResponseTokens}}', (_) => '${context.maxResponse}'),
      _legacyPass(r'{{lastMessage}}', (_) => common._lastMessage()?.text ?? ''),
      _legacyPass(r'{{lastMessageId}}', (_) => common._lastMessageIndex()?.toString() ?? ''),
      _legacyPass(r'{{lastUserMessage}}', (_) => common._lastMessage(user: true)?.text ?? ''),
      _legacyPass(r'{{lastCharMessage}}', (_) => common._lastMessage(user: false)?.text ?? ''),
      _legacyPass(r'{{firstIncludedMessageId}}', (_) => context.firstIncludedMessageId?.toString() ?? ''),
      _legacyPass(r'{{firstDisplayedMessageId}}', (_) => context.firstDisplayedMessageId?.toString() ?? ''),
      _legacyPass(r'{{lastSwipeId}}', (_) => context._historyLast?.swipeCount?.toString() ?? ''),
      _legacyPass(r'{{currentSwipeId}}', (_) => _currentSwipeId()),
      _legacyPass(r'{{allChatRange}}', (_) => context._historyLength == 0 ? '' : '0-${context._historyLength - 1}'),
      _legacyPass(r'{{reverse:(.+?)}}', (match) => String.fromCharCodes(match[1]!.runes.toList().reversed)),
      _legacyPass(r'\{\{\/\/([\s\S]*?)\}\}', (_) => '', caseSensitive: true, multiLine: true),
      _legacyPass(r'{{time}}', (_) => common._time('time', const [])),
      _legacyPass(r'{{date}}', (_) => common._time('date', const [])),
      _legacyPass(r'{{weekday}}', (_) => common._time('weekday', const [])),
      _legacyPass(r'{{isotime}}', (_) => common._time('isotime', const [])),
      _legacyPass(r'{{isodate}}', (_) => common._time('isodate', const [])),
      _legacyPass(r'{{datetimeformat +([^}]*)}}', (match) => common._time('datetimeformat', [match[1]!])),
      _legacyPass(r'{{idle_duration}}', (_) => common._time('idleduration', const [])),
      _legacyPass(r'{{time_UTC([-+]\d+)}}', (match) => common._time('time', ['UTC${match[1]}'])),
      _legacyPass(r'{{outlet::(.+?)}}', (match) => context.outlets[trimJsWhitespace(match[1]!)] ?? ''),
      _legacyPass(r'{{timeDiff::(.*?)::(.*?)}}', (match) => common._time('timediff', [match[1]!, match[2]!])),
      // Chat Completion has no textgenerationwebui banned-word accumulator.
      _legacyPass(r'{{banned "(.*)"}}', (_) => ''),
      _legacyPass(r'{{random\s?::?([^}]+)}}', (match) => _choose(match[1]!, context.random())),
      _legacyPass(r'{{pick\s?::?([^}]+)}}', (match) {
        // The offset belongs to this late pass's current string, not the raw
        // input; the content hash still belongs to the original input.
        final seed = MacroEngine.stringHash('${_jsString(chatIdHash)}-$contentHash-${match.start}');
        return _choose(match[1]!, _SeedRandom.numeric(seed).nextDouble());
      }),
    ]);
    for (final pass in passes) {
      if (text.isEmpty) break;
      if (!pass.regex.pattern.startsWith('<') && !text.contains('{{')) break;
      try {
        // JS String.replace coerces built-in return values with ToString.
        // Environment values above were sanitized separately by MacrosParser.
        text = text.replaceAllMapped(pass.regex, (match) {
          final value = pass.replace(match);
          if (value == null && pass.preserveOnNull) {
            return match[0]!;
          }
          final callback = postProcess;
          return _jsString(callback == null ? value : callback(value));
        });
      } on _MacroDependencyFailure {
        rethrow;
      } catch (_) {
        // ST catches the whole replace pass: keep its previous input string,
        // retain earlier callback side effects, and proceed to the next kind.
      }
    }
    return text;
  }

  Object? _environmentValue(Map<String, Object? Function()> env, String key) {
    final field = _environmentDependencies[key];
    if (field != null) context._observeCharacterDependency(field);
    return env[key]!();
  }

  Map<String, Object? Function()> _environment() {
    final env = <String, Object? Function()>{};
    void put(String key, Object? value, {String? characterField}) {
      env[key] = () => value;
      if (characterField == null) {
        _environmentDependencies.remove(key);
      } else {
        _environmentDependencies[key] = characterField;
      }
    }

    final original = overrides['original'] ?? (inheritOriginal ? context.original : null);
    if (original != null) {
      var used = false;
      env['original'] = () {
        if (used) return '';
        used = true;
        return original;
      };
    }
    if (replaceCharacterCard && !prepareCharacterFieldsOnDemand) {
      final card = context.card;
      // Exactly getCharacterCardFields' eager access order, including fields
      // that legacy exposes under no macro (greetings still have side effects).
      final system = context.preferCharacterPrompt
          ? _overriddenField('system_prompt', context.systemPromptOverride)
          : '';
      final examples = _overriddenField('mes_example', context.mesExamplesOverride);
      final description = _base(card['description']);
      final personality = _base(card['personality']);
      final persona = _base(context.persona);
      final scenario = _overriddenField('scenario', context.scenarioOverride);
      final jailbreak = context.preferCharacterJailbreak ? _base(card['post_history_instructions']) : '';
      final version = card['character_version'] ?? '';
      final extensions = card['extensions'];
      final depth = extensions is Map<String, Object?> ? extensions['depth_prompt'] : null;
      final depthPrompt = _base(depth is Map<String, Object?> ? depth['prompt'] : null);
      final creatorNotes = _base(card['creator_notes']);
      _base(card['first_mes']);
      final alternatives = card['alternate_greetings'];
      if (alternatives is List<Object?>) {
        for (final greeting in alternatives) {
          _base(greeting);
        }
      }
      put(
        'charPrompt',
        system,
        characterField: context.preferCharacterPrompt && !_truthy(context.systemPromptOverride)
            ? 'system_prompt'
            : null,
      );
      // JS right-associative assignment inserts charJailbreak first.
      put(
        'charJailbreak',
        jailbreak,
        characterField: context.preferCharacterJailbreak ? 'post_history_instructions' : null,
      );
      put(
        'charInstruction',
        jailbreak,
        characterField: context.preferCharacterJailbreak ? 'post_history_instructions' : null,
      );
      put('description', description, characterField: 'description');
      put('personality', personality, characterField: 'personality');
      put('scenario', scenario, characterField: _truthy(context.scenarioOverride) ? null : 'scenario');
      put('persona', persona);
      env['mesExamples'] = () => _renderExamples(examples);
      if (!_truthy(context.mesExamplesOverride)) _environmentDependencies['mesExamples'] = 'mes_example';
      put('mesExamplesRaw', examples, characterField: _truthy(context.mesExamplesOverride) ? null : 'mes_example');
      put('charVersion', _truthy(version) ? version : '', characterField: 'character_version');
      put('char_version', _truthy(version) ? version : '', characterField: 'character_version');
      put('charDepthPrompt', depthPrompt, characterField: 'charDepthPrompt');
      put('creatorNotes', creatorNotes, characterField: 'creator_notes');
    }
    if (replaceCharacterCard && prepareCharacterFieldsOnDemand) {
      _installCharacterFieldsOnDemand(env);
    }
    put('user', context.userName);
    put(
      'char',
      characterOverride ?? context.charName,
      characterField: characterOverride == null && context._charNameFromCard ? 'name' : null,
    );
    put(
      'charIfNotGroup',
      characterOverride ?? context.group,
      characterField: characterOverride == null && context._groupFromCard ? 'name' : null,
    );
    put(
      'group',
      characterOverride ?? context.group,
      characterField: characterOverride == null && context._groupFromCard ? 'name' : null,
    );
    put(
      'groupNotMuted',
      characterOverride ?? context.groupNotMuted,
      characterField: characterOverride == null && context._groupNotMutedFromCard ? 'name' : null,
    );
    put('notChar', context.notChar);
    put('model', context.model);
    for (final entry in overrides.entries) {
      // original is the dedicated input above, not an additional constant.
      // Assigning a string to Object.prototype.__proto__ creates no own key.
      if (entry.key != 'original' && entry.key != '__proto__') put(entry.key, entry.value);
    }
    return env;
  }

  Object? Function() _prepareFieldOnce(Object? Function() load) {
    var prepared = false;
    Object? value;
    Object? failure;
    StackTrace? failureStack;
    return () {
      if (!prepared) {
        prepared = true;
        try {
          value = load();
        } catch (error, stack) {
          failure = error;
          failureStack = stack;
        }
      }
      final error = failure;
      if (error != null) Error.throwWithStackTrace(error, failureStack!);
      return value;
    };
  }

  void _installCharacterFieldsOnDemand(Map<String, Object? Function()> env) {
    final card = context.card;
    void put(String key, Object? Function() value, {String? characterField}) {
      env[key] = value;
      if (characterField == null) {
        _environmentDependencies.remove(key);
      } else {
        _environmentDependencies[key] = characterField;
      }
    }

    final system = _prepareFieldOnce(
      () => context.preferCharacterPrompt ? _overriddenField('system_prompt', context.systemPromptOverride) : '',
    );
    final examples = _prepareFieldOnce(() => _overriddenField('mes_example', context.mesExamplesOverride));
    final description = _prepareFieldOnce(() => _base(card['description']));
    final personality = _prepareFieldOnce(() => _base(card['personality']));
    final persona = _prepareFieldOnce(() => _base(context.persona));
    final scenario = _prepareFieldOnce(() => _overriddenField('scenario', context.scenarioOverride));
    final jailbreak = _prepareFieldOnce(
      () => context.preferCharacterJailbreak ? _base(card['post_history_instructions']) : '',
    );
    final version = _prepareFieldOnce(() {
      final value = card['character_version'];
      return _truthy(value) ? value : '';
    });
    final depthPrompt = _prepareFieldOnce(() {
      final extensions = card['extensions'];
      final depth = extensions is Map<String, Object?> ? extensions['depth_prompt'] : null;
      return _base(depth is Map<String, Object?> ? depth['prompt'] : null);
    });
    final creatorNotes = _prepareFieldOnce(() => _base(card['creator_notes']));
    // Keep the legacy environment key order and alias sharing. First/alternate
    // greetings expose no legacy environment macro, so this raw-only mode has
    // no implicit preparation of them. Explicit history is a separate source.
    put(
      'charPrompt',
      system,
      characterField: context.preferCharacterPrompt && !_truthy(context.systemPromptOverride) ? 'system_prompt' : null,
    );
    put(
      'charJailbreak',
      jailbreak,
      characterField: context.preferCharacterJailbreak ? 'post_history_instructions' : null,
    );
    put(
      'charInstruction',
      jailbreak,
      characterField: context.preferCharacterJailbreak ? 'post_history_instructions' : null,
    );
    put('description', description, characterField: 'description');
    put('personality', personality, characterField: 'personality');
    put('scenario', scenario, characterField: _truthy(context.scenarioOverride) ? null : 'scenario');
    put('persona', persona);
    put(
      'mesExamples',
      () => _renderExamples(examples() as String),
      characterField: _truthy(context.mesExamplesOverride) ? null : 'mes_example',
    );
    put('mesExamplesRaw', examples, characterField: _truthy(context.mesExamplesOverride) ? null : 'mes_example');
    put('charVersion', version, characterField: 'character_version');
    put('char_version', version, characterField: 'character_version');
    put('charDepthPrompt', depthPrompt, characterField: 'charDepthPrompt');
    put('creatorNotes', creatorNotes, characterField: 'creator_notes');
  }

  String _base(Object? value) {
    if (value == null) return '';
    if (value is! String) throw ArgumentError.value(value, 'card field', 'Expected a string');
    final text = trimJsWhitespace(value);
    if (text.isEmpty) return '';
    var result = _LegacyEvaluation(
      engine,
      context,
      text,
      const {},
      replaceCharacterCard: false,
      characterOverride: characterOverride,
      inheritOriginal: false,
      prepareCharacterFieldsOnDemand: prepareCharacterFieldsOnDemand,
    ).evaluate(text);
    if (context.collapseNewlines) result = result.replaceAll(_macroNewlines, '\n');
    return result.replaceAll('\r', '');
  }

  String _overriddenField(String key, String? override) {
    final value = _truthy(override) ? override : context.card[key];
    return _base(_truthy(value) ? value : '');
  }

  String _renderExamples(String raw) {
    if (raw.isEmpty || raw == '<START>') return '';
    final separator = _stringField(engine.contextTemplate, 'example_separator');
    if (separator.isNotEmpty) {
      // parseMesExamples expands this even though Chat Completion selects the
      // <START> heading instead of using the expanded separator's text.
      _LegacyEvaluation(
        engine,
        context,
        separator,
        const {},
        replaceCharacterCard: true,
        characterOverride: characterOverride,
        inheritOriginal: false,
        prepareCharacterFieldsOnDemand: prepareCharacterFieldsOnDemand,
      ).evaluate(separator);
    }
    return _examples(raw);
  }

  List<String> _environmentKeys(Map<String, Object? Function()> env) {
    final indices = env.keys.where((key) => _arrayIndex(key) != null).toList()
      ..sort((a, b) => _arrayIndex(a)!.compareTo(_arrayIndex(b)!));
    return [...indices, ...env.keys.where((key) => _arrayIndex(key) == null)];
  }

  List<_LegacyPass> _variablePasses(Map<String, Object?> vars, {required bool global}) {
    final scope = global ? 'globalvar' : 'var';
    return [
      _legacyPass('{{set$scope::([^:]+)::([^}]*)}}', (match) {
        _setVariable(vars, trimJsWhitespace(match[1]!), match[2]!);
        return '';
      }),
      _legacyPass('{{add$scope::([^:]+)::([^}]+)}}', (match) {
        _addVariable(vars, trimJsWhitespace(match[1]!), match[2]!);
        return '';
      }),
      _legacyPass('{{inc$scope::([^}]+)}}', (match) => _addVariable(vars, trimJsWhitespace(match[1]!), 1)),
      _legacyPass('{{dec$scope::([^}]+)}}', (match) => _addVariable(vars, trimJsWhitespace(match[1]!), -1)),
      _legacyPass('{{get$scope::([^}]+)}}', (match) => _getVariable(vars, trimJsWhitespace(match[1]!))),
    ];
  }

  List<_LegacyPass> _instructPasses(Map<String, Object? Function()> env) {
    const sequences = <(String, String, String?)>[
      ('instructStoryStringPrefix', 'story_string_prefix', null),
      ('instructStoryStringSuffix', 'story_string_suffix', null),
      ('instructInput|instructUserPrefix', 'input_sequence', null),
      ('instructUserSuffix', 'input_suffix', null),
      ('instructOutput|instructAssistantPrefix', 'output_sequence', null),
      ('instructSeparator|instructAssistantSuffix', 'output_suffix', null),
      ('instructSystemPrefix', 'system_sequence', null),
      ('instructSystemSuffix', 'system_suffix', null),
      ('instructFirstOutput|instructFirstAssistantPrefix', 'first_output_sequence', 'output_sequence'),
      ('instructLastOutput|instructLastAssistantPrefix', 'last_output_sequence', 'output_sequence'),
      ('instructStop', 'stop_sequence', null),
      ('instructUserFiller', 'user_alignment_message', null),
      ('instructSystemInstructionPrefix', 'last_system_sequence', null),
      ('instructFirstInput|instructFirstUserPrefix', 'first_input_sequence', 'input_sequence'),
      ('instructLastInput|instructLastUserPrefix', 'last_input_sequence', 'input_sequence'),
    ];
    final result = <_LegacyPass>[];
    final enabled = _truthy(engine.instruct['enabled']);
    for (final (names, key, fallback) in sequences) {
      var value = _stringField(engine.instruct, key);
      if (value.isEmpty && fallback != null) value = _stringField(engine.instruct, fallback);
      final replacement = enabled ? value : '';
      result.add(_legacyPass('{{($names)}}', (_) => replacement));
    }
    final systemEnabled = _truthy(engine.systemPrompt['enabled']);
    final defaultPrompt = _stringField(engine.systemPrompt, 'content');
    // Default legacy captures this value at factory time. Raw source isolation
    // must leave its lazy field untouched until an actual enabled macro uses it.
    final charPrompt = prepareCharacterFieldsOnDemand ? null : env['charPrompt']?.call();
    final usesCharPrompt = context.preferCharacterPrompt && _truthy(charPrompt);
    final preferredPrompt = usesCharPrompt ? charPrompt : defaultPrompt;
    result.addAll([
      _legacyPass(r'{{(systemPrompt)}}', (_) {
        if (!systemEnabled) return '';
        final field = context.preferCharacterPrompt ? _environmentDependencies['charPrompt'] : null;
        if (field != null) context._observeCharacterDependency(field);
        if (prepareCharacterFieldsOnDemand) {
          final selected = context.preferCharacterPrompt ? env['charPrompt']?.call() : null;
          return context.preferCharacterPrompt && _truthy(selected) ? selected : defaultPrompt;
        }
        return preferredPrompt;
      }),
      _legacyPass(
        r'{{(defaultSystemPrompt|instructSystem|instructSystemPrompt)}}',
        (_) => systemEnabled ? defaultPrompt : '',
      ),
      _legacyPass(r'{{(chatSeparator)}}', (_) => _stringField(engine.contextTemplate, 'example_separator')),
      _legacyPass(r'{{(chatStart)}}', (_) => _stringField(engine.contextTemplate, 'chat_start')),
    ]);
    return result;
  }

  String _currentSwipeId() {
    final last = context._historyLast;
    if (last == null) return 'NaN';
    if (last.swipeId != null) return '${last.swipeId! + 1}';
    return last.swipeIdIsNull ? '' : 'NaN';
  }

  String _choose(String input, double random) {
    if (!random.isFinite || random < 0 || random >= 1) throw ArgumentError.value(random);
    final values = input.contains('::')
        ? input.split('::')
        : input
              .replaceAll(r'\,', '##�COMMA�##')
              .split(',')
              .map((item) => trimJsWhitespace(item).replaceAll('##�COMMA�##', ','))
              .toList();
    return values[(random * values.length).floor()];
  }
}
