part of 'engine.dart';

class _PromptHistoryWindow {
  _PromptHistoryWindow(this.nodes, this.path, this.first, this.identityNode, this.bodyNodes)
    : unreadCount = path.length - nodes.length;
  final List<StoredNode> nodes;
  final List<StoredHistoryLink> path;
  final StoredNode? first;
  final StoredNode? identityNode;
  final int unreadCount;
  int bodyNodes;

  List<PromptHistoryMessage> get prefix => [
    for (final link in path.take(unreadCount))
      PromptHistoryMessage(
        id: link.nodeId,
        role: link.role.name,
        content: '',
        name: link.speaker,
        hidden: link.hidden,
        isSystem: link.isSystem,
      ),
  ];
}

// An unchanged suffix can be bounded before assembly. Dynamic configurations
// keep the original complete history and macro order; no macro is speculated
// or replayed to decide whether a message will fit.
_PromptHistoryWindow? _plainPromptHistory(
  TavernEngine engine,
  _Turn turn,
  Map<String, Object?> data,
  ChatPreset preset,
  String? leaf, {
  required PromptTokenCounter counter,
  required WorldInfoSettings worldSettings,
}) {
  final settings = preset.executionSettings;
  if (engine._counter is! EstimatedTokenCounter ||
      (turn.kind != _TurnKind.send && turn.kind != _TurnKind.regenerate) ||
      turn.groupView != null ||
      turn.scriptInjectionUses?.used.isNotEmpty == true ||
      _map(turn.settings['reasoning'])['add_to_prompts'] == true ||
      _hasWorldTimers(turn.state['timedWorldInfo']) ||
      _hasGameplayWorldTimers(turn.state, turn.gameplayResources) ||
      worldSettings.minActivations > 0 ||
      !_literalPromptName(data['name']) ||
      !_literalPromptName(data['nickname']) ||
      !_literalPromptName(turn.settings['userName']) ||
      !_plainPromptData(turn.input) ||
      !_plainPromptResource(data) ||
      !_plainPromptSettings(turn.settings) ||
      !_plainPromptResource(settings) ||
      _hasTurnHistoryRules(data, turn.settings, settings, turn.actorId, packRegex: turn.gameplayResources.regex)) {
    return null;
  }
  final budget =
      presetNumber(settings['openai_max_context'], 4095).toInt() -
      presetNumber(settings['openai_max_tokens'], 300).toInt();
  if (budget < 0) return null;
  final path = engine._store.historyLinksTo(turn.chat.id, leaf);
  final reversed = <StoredNode>[];
  var spent = 0;
  var bodyNodes = 0;
  var cursor = leaf;
  while (cursor != null && spent <= budget) {
    final page = engine._store.promptHistoryTo(turn.chat.id, cursor, limit: 32);
    bodyNodes += page.length;
    for (final node in page.reversed) {
      reversed.add(node);
      if (!node.message.hidden && !_systemMessage(node)) {
        if (!_plainPromptText(node.message.text) || !_plainPromptText(node.message.speaker)) return null;
        spent += plainHistoryTokenCost(
          counter,
          _promptHistory(node),
          namesBehavior: settings['names_behavior'],
          userName: turn.settings['userName'] is String ? turn.settings['userName']! as String : 'User',
          group: false,
        );
      }
      // Keep the first overflowing node. Fixed prompts, controls and the new
      // user can only consume more of this budget, never make older text fit.
      if (spent > budget) break;
    }
    cursor = page.first.message.parentId;
  }
  final nodes = reversed.reversed.toList();
  final first = path.isEmpty
      ? null
      : nodes.length == path.length
      ? nodes.first
      : engine._store.promptHistoryTo(turn.chat.id, path.first.nodeId, limit: 1).single;
  if (path.isNotEmpty && nodes.length != path.length) bodyNodes++;
  if (first != null && !_plainPromptText(first.message.text)) return null;
  final identityNode = leaf == null
      ? null
      : engine._store.promptHistoryTo(turn.chat.id, leaf, limit: 1, includeSource: true).single;
  if (identityNode != null) bodyNodes++;
  return _PromptHistoryWindow(nodes, path, first, identityNode, bodyNodes);
}

// Recursion adds admitted entry text, not older messages. Only the separate
// min-activations path widens depth; that path keeps the complete history.
int _worldHistoryDepth(List<WorldInfoBook> books, WorldInfoSettings settings) {
  var depth = 0;
  for (final book in books) {
    for (final entry in book.entries) {
      depth = max(depth, (entry.scanDepth ?? settings.scanDepth).clamp(0, 1000).toInt());
      // Include every finite fallback as an upper bound without selecting a
      // runtime decorator branch or invoking its macros a second time.
      for (final line in worldInfoDecoratorHeader(entry.content)) {
        if (line.name != 'scan_depth') continue;
        final value = num.tryParse(line.value);
        if (value != null && value.isFinite) depth = max(depth, value.clamp(0, 1000).toInt());
      }
    }
  }
  return depth;
}

List<StoredNode> _worldHistoryWindow(
  TavernEngine engine,
  String chatId,
  String? leaf,
  List<StoredNode> promptHistory,
  _PromptHistoryWindow window, {
  required int depth,
  required bool includeNames,
}) {
  if (depth == 0) return [];
  final reversed = <StoredNode>[];
  var complete = false;
  void take(Iterable<StoredNode> nodes) {
    for (final node in nodes) {
      if (node.message.hidden || _systemMessage(node)) continue;
      reversed.add(node);
      // ScanBuffer pads empty slots only when an older nonempty raw message
      // exists. Preserve those separators before trimming, within its 1000 cap.
      if (reversed.length == 1000 || (reversed.length >= depth && (includeNames || node.message.text.isNotEmpty))) {
        complete = true;
        break;
      }
    }
  }

  take(promptHistory.reversed);
  var cursor = promptHistory.isEmpty ? leaf : promptHistory.first.message.parentId;
  while (!complete && cursor != null) {
    final page = engine._store.promptHistoryTo(chatId, cursor, limit: 32);
    window.bodyNodes += page.length;
    take(page.reversed);
    cursor = page.first.message.parentId;
  }
  return reversed.reversed.toList();
}

bool _hasTurnHistoryRules(
  Map<String, Object?> data,
  Map<String, Object?> settings,
  Map<String, Object?> preset,
  String characterId, {
  List<TavernScriptRegex> packRegex = const [],
}) {
  if (settings['regexEnabled'] == false) return false;
  final scripts = [
    for (final rule in packRegex)
      if (rule.effective) rule.execution,
    ...RegexEngine.readScripts(settings['globalRegexScripts'] ?? settings['regex']),
    ...RegexEngine.readScripts(settings['managedRegexScripts']),
    if (settings['presetRegexEnabled'] != false) ..._readRegexScripts(_readMap(preset['extensions'])['regex_scripts']),
    if (settings['characterRegexEnabled'] != false &&
        !_strings(settings['disabledCharacterRegex']).contains(characterId))
      ..._readRegexScripts(_readMap(data['extensions'])['regex_scripts']),
  ];
  // WI captures can synthesize a history macro absent from every raw string.
  // Keep its prompt replacements on the complete-history path as well.
  return scripts.any(
    (script) =>
        !script.disabled &&
        (script.promptOnly || !script.markdownOnly) &&
        script.placement.any(
          (placement) =>
              placement == RegexPlacement.userInput ||
              placement == RegexPlacement.aiOutput ||
              placement == RegexPlacement.reasoning ||
              (placement == RegexPlacement.worldInfo && script.promptOnly),
        ),
  );
}

// Helper script bodies and regex replacement programs are not card macro
// fields. Active prompt regex is checked separately by _hasTurnHistoryRules.
// All other extension carriers retain the conservative complete-history rule.
bool _plainPromptSettings(Map<String, Object?> settings) {
  for (final entry in settings.entries) {
    if (const {'globalRegexScripts', 'managedRegexScripts', 'regex'}.contains(entry.key)) continue;
    if (entry.key == 'preset' && entry.value is Map<String, Object?>) {
      if (!_plainPromptResource(entry.value! as Map<String, Object?>)) return false;
    } else if (!_plainPromptData(entry.value)) {
      return false;
    }
  }
  return true;
}

bool _plainPromptResource(Map<String, Object?> value) {
  for (final entry in value.entries) {
    if (entry.key != 'extensions' || entry.value is! Map<String, Object?>) {
      if (!_plainPromptData(entry.value)) return false;
      continue;
    }
    for (final extension in (entry.value! as Map<String, Object?>).entries) {
      if (const {'regex_scripts', 'tavern_helper', 'tavern_helper_scripts'}.contains(extension.key)) continue;
      if (!_plainPromptData(extension.value)) return false;
    }
  }
  return true;
}

// Dynamic macros still see the whole ancestry. Their prompt-only rows omit
// inspection/state/unused import bodies and yield between bounded SQL pages.
Future<List<StoredNode>> _completePromptHistory(TavernEngine engine, _Turn turn, String? leaf) async {
  final reversed = <StoredNode>[];
  final seen = <String>{};
  var cursor = leaf;
  while (cursor != null) {
    final page = engine._store.promptHistoryTo(turn.chat.id, cursor, limit: 32, includeRuntime: true);
    for (final node in page.reversed) {
      if (!seen.add(node.message.nodeId)) throw StateError('Cycle in the ancestor path: ${node.message.nodeId}');
      reversed.add(node);
    }
    cursor = page.first.message.parentId;
    if (cursor != null) {
      await Future<void>.delayed(Duration.zero);
      turn.cancellation.check();
      _requireOrdinaryOwnership(engine, turn, StoredToolPhase.native);
    }
  }
  return reversed.reversed.toList();
}

bool _plainPromptData(Object? value) {
  if (value is String) return _plainPromptText(value.replaceAll(_promptNameMacro, ''));
  if (value is List<Object?>) return value.every(_plainPromptData);
  if (value is Map<String, Object?>) return value.values.every(_plainPromptData);
  return true;
}

bool _hasWorldTimers(Object? value) {
  if (value is! Map<String, Object?>) return false;
  for (final key in const ['sticky', 'cooldown']) {
    final timers = value[key];
    if ((timers is Map<String, Object?> && timers.isNotEmpty) || (timers is List<Object?> && timers.isNotEmpty)) {
      return true;
    }
  }
  return false;
}

bool _literalPromptName(Object? value) =>
    value is! String ||
    (_plainPromptText(value) && !value.contains('{') && !value.contains('}') && !value.contains('<'));

// Both dialects recognize brace/angle macros. The modern postprocessor also
// unescapes braces and removes its private ELSE marker without a parsed call.
bool _plainPromptText(String text) {
  final normalized = text.replaceAll('\r', '');
  return !normalized.contains('{{') &&
      !normalized.contains('}}') &&
      !normalized.contains(r'\{') &&
      !normalized.contains(r'\}') &&
      !normalized.contains('\u0000') &&
      !_promptAngleMacro.hasMatch(normalized);
}

final _promptAngleMacro = RegExp(r'<(USER|BOT|CHAR|GROUP|CHARIFNOTGROUP)>', caseSensitive: false);
// Normalized presets eagerly prepare name-only controls even on a normal
// send. These macros do not consult history or mutate variables; their literal
// names above cannot introduce a new macro in legacy replacement passes.
final _promptNameMacro = RegExp(
  r'{{\s*(user|char|charIfNotGroup|group|groupNotMuted|notChar)\s*}}',
  caseSensitive: false,
);

bool _hasGameplayWorldTimers(Map<String, Object?> state, _GameplayResources resources) {
  final snapshot = _gameplayWorldInfoSnapshot(state, resources);
  if (snapshot == null) {
    return false;
  }
  for (final source in resources.packSources.values.map((entry) => entry.source).toSet()) {
    final saved = snapshot.read(source);
    if (saved.issues.isNotEmpty) {
      return true;
    }
    final raw = saved.raw;
    if (!saved.exists || raw is! Map<String, Object?>) {
      continue;
    }
    final entries = raw['entries'];
    if (entries is Map<String, Object?>) {
      for (final resource in entries.values) {
        if (resource is Map<String, Object?> &&
            resource.values.any(
              (entry) =>
                  entry is Map<String, Object?> && (entry.containsKey('sticky') || entry.containsKey('cooldown')),
            )) {
          return true;
        }
      }
    }
  }
  return false;
}

// Persist only the prompt admission boundary, never a second chat history.
// Source/content versions let ordinary appends reuse the boundary while edits,
// hiding, deletion, branch changes and imported replacements start a new one.
class _CachedPromptWindow {
  const _CachedPromptWindow(this.window, this.path, this.configuration);
  final PromptHistoryWindow window;
  final List<StoredHistoryLink> path;
  final _PromptWindowConfiguration configuration;

  bool accepts(List<StoredHistoryLink> current, _PromptWindowConfiguration next) {
    if (!configuration.matches(next) || current.length < path.length) return false;
    for (var index = 0; index < path.length; index++) {
      final before = path[index], after = current[index];
      if (before.nodeId != after.nodeId ||
          before.seq != after.seq ||
          before.sourceEpoch != after.sourceEpoch ||
          before.contentVersion != after.contentVersion ||
          before.role != after.role ||
          before.speaker != after.speaker ||
          before.speakerCharacterId != after.speakerCharacterId ||
          before.hidden != after.hidden ||
          before.isSystem != after.isSystem) {
        return false;
      }
    }
    return current.any((node) => node.nodeId == window.firstNodeId);
  }
}

class _PromptWindowConfiguration {
  _PromptWindowConfiguration(_Turn turn, this.card, this.hostCard, this.books)
    : settings = turn.settings,
      values = {
        'actor': turn.actorId,
        'preset': turn.presetId,
        'persona': turn.chat.personaId,
        'model': turn.config.model,
        'generationType': turn.generationType,
        'thinking': turn.config.thinking,
        'deepseek': turn.config.deepseek,
        'tools': _ordinaryTurnTools(turn),
        'groupNames': turn.groupView?.names,
      };

  // This is the turn's actual captured input. Current library/document tokens
  // may already describe newer data after a held preparation hook, so they
  // cannot stand in for the preset and overrides used by this assembly.
  final Map<String, Object?> settings, values, card, hostCard;
  final List<WorldInfoBook> books;

  bool matches(_PromptWindowConfiguration other) =>
      _samePromptSettings(settings, other.settings) &&
      _samePromptSettings(card, other.card) &&
      _samePromptSettings(hostCard, other.hostCard) &&
      _samePromptBooks(books, other.books) &&
      _stateJsonEqual(values, other.values);
}

bool _samePromptBooks(List<WorldInfoBook> left, List<WorldInfoBook> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    final before = left[index], after = right[index];
    if (identical(before, after)) continue;
    // Pack remapping creates fresh book objects from the same captured source.
    // Compare those actual projections; current library tokens are unrelated
    // to a previously captured turn and would miss a concurrent replacement.
    if (!sameWorldInfoBook(before, after)) return false;
  }
  return true;
}

bool _samePromptSettings(Map<String, Object?> left, Map<String, Object?> right) {
  if (left.length != right.length) return false;
  for (final entry in left.entries) {
    if (!right.containsKey(entry.key)) return false;
    final other = right[entry.key];
    // Read projections share unmodified source containers. Only a genuinely
    // different override/source needs structural comparison, never encoding.
    if (!identical(entry.value, other) && !_stateJsonEqual(entry.value, other)) return false;
  }
  return true;
}

class _PendingPromptWindow {
  const _PendingPromptWindow(this.window, this.contextLeaf, this.configuration);
  final PromptHistoryWindow window;
  final String? contextLeaf;
  final _PromptWindowConfiguration configuration;
}

extension _PromptWindowState on TavernEngine {
  PromptHistoryWindow? _reusePromptWindow(_Turn turn, String? leaf, _PromptWindowConfiguration configuration) {
    final previous = _promptCacheWindows[turn.chat.id];
    if (previous == null) return null;
    final path = _store.historyLinksTo(turn.chat.id, leaf);
    if (previous.accepts(path, configuration)) return previous.window;
    _promptCacheWindows.remove(turn.chat.id);
    return null;
  }

  void _adoptPromptWindow(_Turn turn) {
    final pending = turn.pendingPromptWindow;
    if (pending == null) return;
    // Called after the model stream accepts its first subscription. Preparation
    // failures and authoring previews therefore never advance the chat window.
    _promptCacheWindows[turn.chat.id] = _CachedPromptWindow(
      pending.window,
      _store.historyLinksTo(turn.chat.id, pending.contextLeaf),
      pending.configuration,
    );
    turn.pendingPromptWindow = null;
  }
}
