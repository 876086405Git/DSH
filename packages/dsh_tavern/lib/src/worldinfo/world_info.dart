// Port of SillyTavern 1.19.0 public/scripts/world-info.js (AGPL-3.0),
// commit 7e8663cd9c184a550b37238218bdd32c6efc68e9: WorldInfoBuffer,
// getSortedEntries, checkWorldInfo, inclusion groups and convertCharacterBook.
// Selection order stays here; protected regex work uses a caller-owned
// executor. IO, UI and persistence remain outside the evaluator.

import 'dart:convert';
import 'dart:math' as math;

import '../js_string.dart';
import '../regex/regex_program.dart' show isNativeRegexLiteral;
import '../regex/regex_types.dart';
import '../state/state_engine.dart' as state_core;
import 'world_info_case.dart';

part 'timed_effects.dart';
part 'decorators.dart';

enum WorldInfoSource { global, character, chat, persona, memory }

enum WorldInfoStrategy { evenly, characterFirst, globalFirst }

/// Local book identity and the loader-normalized entry uid. Display titles and
/// ST source names are not interchangeable with this reference.
typedef WorldInfoEntryRef = (String bookId, String uid);

// Engine cache comparison without exposing either private raw map. Remapped
// pack books are freshly allocated each turn even when their captured source
// is identical; public inspection getters must still return detached JSON.
bool sameWorldInfoBook(WorldInfoBook left, WorldInfoBook right) =>
    identical(left, right) ||
    (left.id == right.id &&
        left.source == right.source &&
        left.stWorldName == right.stWorldName &&
        left.entries.length == right.entries.length &&
        Iterable<int>.generate(left.entries.length).every(
          (index) =>
              left.entries[index].uid == right.entries[index].uid &&
              left.entries[index].sourcePointer == right.entries[index].sourcePointer,
        ) &&
        _sameBookJson(left._raw, right._raw));

bool _sameBookJson(Object? left, Object? right) {
  if (identical(left, right)) return true;
  if (left is List<Object?> && right is List<Object?>) {
    return left.length == right.length &&
        Iterable<int>.generate(left.length).every((index) => _sameBookJson(left[index], right[index]));
  }
  if (left is Map<String, Object?> && right is Map<String, Object?>) {
    if (left.length != right.length) return false;
    final rightEntries = right.entries.iterator;
    for (final entry in left.entries) {
      rightEntries.moveNext();
      if (entry.key != rightEntries.current.key || !_sameBookJson(entry.value, rightEntries.current.value)) {
        return false;
      }
    }
    return true;
  }
  return left == right;
}

/// Per-evaluation external requests and their result rows are bounded together.
const worldInfoExternalActivationLimit = 64;

/// The indices are ST's persisted position values, including AN before depth.
enum WorldInfoPosition {
  before,
  after,
  authorNoteBefore,
  authorNoteAfter,
  atDepth,
  examplesBefore,
  examplesAfter,
  outlet,
}

enum WorldInfoRole { system, user, assistant }

enum WorldInfoScanPhase { initial, recursion, minActivations }

/// Keeps the complete original book, including fields this wave does not use.
/// A character book is the card's `data.character_book`, not the whole card.
class WorldInfoBook {
  WorldInfoBook._(this.id, this.source, this._raw, this.stWorldName, {bool shared = false}) : _shared = shared {
    final original = _raw['entries'];
    final byId = <String, (Map<String, Object?>, int)>{};
    final parsed = <WorldInfoEntry>[];
    if (original is Map<String, Object?>) {
      for (final key in _objectKeys(original.keys)) {
        final value = original[key];
        if (value is! Map<String, Object?>) throw FormatException('World info entry $key must be an object.');
        parsed.add(
          WorldInfoEntry._(this, _id(value['uid'] ?? key), value, value, '/entries/${_worldInfoPointerToken(key)}'),
        );
      }
    } else if (original is List<Object?>) {
      for (var index = 0; index < original.length; index++) {
        final value = original[index];
        if (value is! Map<String, Object?>) throw FormatException('Character book entry $index must be an object.');
        byId[_id(value['id'] ?? index)] = (value, index);
      }
      for (final uid in _objectKeys(byId.keys)) {
        final item = byId[uid]!;
        parsed.add(
          WorldInfoEntry._(this, uid, item.$1, _convertCharacterEntry(item.$1, item.$2), '/entries/${item.$2}'),
        );
      }
    } else {
      throw const FormatException('World info must contain an entries object or array.');
    }
    entries = List.unmodifiable(parsed);
  }

  WorldInfoBook._remapped(WorldInfoBook original, this.id, this.stWorldName, Map<String, String> entryUidsByPointer)
    : source = original.source,
      _shared = true,
      _raw = _copyTimedValue(original._raw)! as Map<String, Object?> {
    final rows = _raw['entries'];
    final copiedRows = <String, Map<String, Object?>>{
      if (rows is Map<String, Object?>)
        for (final row in rows.entries)
          '/entries/${_worldInfoPointerToken(row.key)}': row.value! as Map<String, Object?>,
      if (rows is List<Object?>)
        for (var index = 0; index < rows.length; index++) '/entries/$index': rows[index]! as Map<String, Object?>,
    };
    final seen = <String>{};
    final mapped = <WorldInfoEntry>[];
    for (final entry in original.entries) {
      final uid = entryUidsByPointer[entry.sourcePointer];
      if (uid == null || !seen.add(uid)) {
        throw const FormatException('Every effective pack entry needs a distinct stable uid.');
      }
      final value = copiedRows[entry.sourcePointer]!;
      mapped.add(
        WorldInfoEntry._(
          this,
          uid,
          value,
          identical(entry._fields, entry._raw) ? value : _copyTimedValue(entry._fields)! as Map<String, Object?>,
          entry.sourcePointer,
        ),
      );
    }
    entries = List.unmodifiable(mapped);
  }

  factory WorldInfoBook.fromJson({
    required String id,
    required WorldInfoSource source,
    required Map<String, Object?> json,
    String? stWorldName,
  }) => WorldInfoBook._(id, source, jsonDecode(jsonEncode(json)) as Map<String, Object?>, stWorldName ?? id);

  /// A reusable execution view. Public inspection still receives detached JSON.
  factory WorldInfoBook.cached({
    required String id,
    required WorldInfoSource source,
    required Map<String, Object?> json,
    String? stWorldName,
  }) => WorldInfoBook._(id, source, _copyTimedValue(json)! as Map<String, Object?>, stWorldName ?? id, shared: true);

  final String id;

  /// ST's world filename/name, not the display title. Local IDs may differ.
  final String stWorldName;
  final WorldInfoSource source;
  final Map<String, Object?> _raw;
  final bool _shared;
  Map<String, Object?> get raw => _shared ? _copyTimedValue(_raw)! as Map<String, Object?> : _raw;
  late final List<WorldInfoEntry> entries;
  String get name => _raw['name'] is String ? _raw['name'] as String : id;
}

class WorldInfoEntry {
  const WorldInfoEntry._(this.book, this.uid, this._raw, this._fields, this.sourcePointer);
  final WorldInfoBook book;
  final String uid;

  /// The original object location, before V3 uid deduplication and sorting.
  final String sourcePointer;
  final Map<String, Object?> _raw;
  Map<String, Object?> get raw => book._shared ? _copyTimedValue(_raw)! as Map<String, Object?> : _raw;
  final Map<String, Object?> _fields;

  /// Actual loader declarations: absence and explicit null remain distinct.
  Map<String, Object?> get timerDeclarations =>
      _copyTimedValue({
            for (final key in const ['sticky', 'cooldown'])
              if (_fields.containsKey(key)) key: _fields[key],
          })!
          as Map<String, Object?>;

  /// Delay is a current-scan threshold, not part of the timer policy.
  Map<String, Object?> get delayDeclaration =>
      _copyTimedValue({if (_fields.containsKey('delay')) 'delay': _fields['delay']})! as Map<String, Object?>;

  WorldInfoEntryRef get identity => (book.id, uid);
  List<String> get keys => _strings(_fields['key']);
  List<String> get secondaryKeys => _strings(_fields['keysecondary']);
  String get content => _string(_fields['content']);
  String get comment => _string(_fields['comment']);
  bool get constant => _fields['constant'] == true;
  bool get disabled => _fields['disable'] == true;
  bool get selective => _fields['selective'] == true;
  int get selectiveLogic => _integer(_fields['selectiveLogic']) ?? 0;
  num get order => _number(_fields['order']) ?? 100;
  int? get position => _integer(_fields['position']);
  int get depth => _integer(_fields['depth']) ?? 4;
  int get role => _integer(_fields['role']) ?? 0;
  String get outlet => _string(_fields['outletName']);
  bool get ignoreBudget => _fields['ignoreBudget'] == true;
  bool get excludeRecursion => _fields['excludeRecursion'] == true;
  bool get preventRecursion => _fields['preventRecursion'] == true;
  num get delayUntilRecursion =>
      _fields['delayUntilRecursion'] == true ? 1 : _number(_fields['delayUntilRecursion']) ?? 0;
  bool get useProbability => _fields['useProbability'] == true;
  num get probability => _number(_fields['probability']) ?? 100;
  String get group => _string(_fields['group']);
  bool get groupOverride => _fields['groupOverride'] == true;
  num get groupWeight => _number(_fields['groupWeight']) ?? 100;
  int? get scanDepth => _integer(_fields['scanDepth']);
  bool? get caseSensitive => _boolean(_raw['case_sensitive']) ?? _boolean(_fields['caseSensitive']);
  bool get useRegex => _raw['use_regex'] == true;
  bool? get matchWholeWords => _boolean(_fields['matchWholeWords']);
  bool? get useGroupScoring => _boolean(_fields['useGroupScoring']);
  List<String> get triggers => _strings(_fields['triggers']);

  /// Exact ST loader hash, including field order and the original ST decorator parser.
  int get stHash => book._shared ? (_entryHashes[this] ??= _entryHash(this)) : _entryHash(this);
  String get stKey =>
      '${_fields.containsKey('world') ? _jsString(_fields['world']) : book.stWorldName}.'
      '${_fields.containsKey('uid') ? _jsString(_fields['uid']) : 'undefined'}';
}

final _entryHashes = Expando<int>('world info entry hashes');

/// Engine-only runtime view. The stored book and all loader fields stay intact.
WorldInfoBook remapWorldInfoBook(
  WorldInfoBook book, {
  required String id,
  required String stWorldName,
  required Map<String, String> entryUidsByPointer,
}) => WorldInfoBook._remapped(book, id, stWorldName, entryUidsByPointer);

/// Exports one selected effective pack entry through the existing loader.
/// Same-form exports change only the execution id. Cross-form exports retain
/// unknown fields where they stay inert; callers retain the complete original
/// entry in export provenance. Runtime identities and saved ledgers do not move.
Map<String, Object?> exportGameplayWorldInfoEntry(
  WorldInfoEntry entry, {
  required String id,
  required bool characterBook,
}) {
  final wasCharacterBook = entry.book._raw['entries'] is List<Object?>;
  final result = _copyTimedValue(entry._raw)! as Map<String, Object?>;
  if (wasCharacterBook == characterBook) {
    result[characterBook ? 'id' : 'uid'] = id;
    return result;
  }
  final fields = entry._fields;
  if (characterBook) {
    void copyField(String from, String to) {
      result.remove(to);
      if (fields.containsKey(from)) {
        result[to] = _copyTimedValue(fields[from]);
      }
    }

    copyField('key', 'keys');
    copyField('keysecondary', 'secondary_keys');
    copyField('order', 'insertion_order');
    for (final field in const ['comment', 'content', 'constant', 'selective']) {
      copyField(field, field);
    }
    result['id'] = id;
    result['enabled'] = !entry.disabled;
    // Native position values belong in the existing V3 extension, not in the
    // before_char/after_char top-level slot. A missing/nonrepresentable native
    // position is rejected by the real-loader comparison below.
    result.remove('position');
    final extensions = _object(_copyTimedValue(result['extensions']));
    for (final pair in _gameplayCharacterExtensionFields.entries) {
      extensions.remove(pair.value);
      if (fields.containsKey(pair.key)) {
        extensions[pair.value] = _copyTimedValue(fields[pair.key]);
      }
    }
    // ST's missing/null useProbability is false; V3's nullish default is true.
    // Preserve that actual gate explicitly instead of enabling a new RNG path.
    extensions['useProbability'] = entry.useProbability;
    result['extensions'] = extensions;
  } else {
    // A raw V3 row may contain ignored ST-shaped keys. Do not activate those
    // shadows after changing form (notably characterFilter and disable).
    for (final field in {
      'uid',
      'world',
      'key',
      'keysecondary',
      'comment',
      'content',
      'constant',
      'selective',
      'order',
      'position',
      'disable',
      'characterFilter',
      ..._gameplayCharacterExtensionFields.keys,
    }) {
      result.remove(field);
    }
    result.addAll(_copyTimedValue(fields)! as Map<String, Object?>);
    result['uid'] = id;
  }
  final roundTrip = WorldInfoBook.fromJson(
    id: entry.book.id,
    source: entry.book.source,
    stWorldName: entry.book.stWorldName,
    json: {
      'entries': characterBook ? <Object?>[result] : <String, Object?>{id: result},
    },
  ).entries.single;
  final before = _gameplayWorldInfoExecution(entry);
  final after = _gameplayWorldInfoExecution(roundTrip);
  for (final field in before.keys) {
    if (jsonEncode(before[field]) != jsonEncode(after[field])) {
      throw FormatException('World-info conversion cannot preserve $field at ${entry.sourcePointer}.');
    }
  }
  return result;
}

/// Names accepted by the existing _convertCharacterEntry loader. Values still
/// pass through that loader; this table neither parses nor normalizes them.
const _gameplayCharacterExtensionFields = <String, String>{
  'position': 'position',
  'excludeRecursion': 'exclude_recursion',
  'preventRecursion': 'prevent_recursion',
  'delayUntilRecursion': 'delay_until_recursion',
  'displayIndex': 'display_index',
  'probability': 'probability',
  'useProbability': 'useProbability',
  'depth': 'depth',
  'selectiveLogic': 'selectiveLogic',
  'outletName': 'outlet_name',
  'group': 'group',
  'groupOverride': 'group_override',
  'groupWeight': 'group_weight',
  'scanDepth': 'scan_depth',
  'caseSensitive': 'case_sensitive',
  'matchWholeWords': 'match_whole_words',
  'useGroupScoring': 'use_group_scoring',
  'automationId': 'automation_id',
  'role': 'role',
  'vectorized': 'vectorized',
  'sticky': 'sticky',
  'cooldown': 'cooldown',
  'delay': 'delay',
  'matchPersonaDescription': 'match_persona_description',
  'matchCharacterDescription': 'match_character_description',
  'matchCharacterPersonality': 'match_character_personality',
  'matchCharacterDepthPrompt': 'match_character_depth_prompt',
  'matchScenario': 'match_scenario',
  'matchCreatorNotes': 'match_creator_notes',
  'triggers': 'triggers',
  'ignoreBudget': 'ignore_budget',
};

/// Every per-entry value used by selection, scoring, output, decorators and
/// timer gates. Hash/display order and book/source identity are intentionally
/// excluded: export creates new identities and does not migrate runtime state.
Map<String, Object?> _gameplayWorldInfoExecution(WorldInfoEntry entry) {
  final fields = entry._fields;
  final filter = fields['characterFilter'];
  return {
    'keys': entry.keys,
    'secondaryKeys': entry.secondaryKeys,
    'content': entry.content,
    'comment': entry.comment,
    'constant': entry.constant,
    'disabled': entry.disabled,
    'selective': entry.selective,
    'selectiveLogic': entry.selectiveLogic,
    // Activation defaults nullish logic; inclusion-group scoring does not.
    'secondaryScoringHasLogic':
        entry.keys.isNotEmpty && entry.secondaryKeys.isNotEmpty && fields['selectiveLogic'] != null,
    'order': entry.order,
    'position': entry.position,
    'depth': entry.depth,
    'role': entry.role,
    'outlet': entry.outlet,
    'ignoreBudget': entry.ignoreBudget,
    'excludeRecursion': entry.excludeRecursion,
    'preventRecursion': entry.preventRecursion,
    'delayUntilRecursion': entry.delayUntilRecursion,
    'useProbability': entry.useProbability,
    'probability': entry.probability,
    'group': entry.group,
    'groupOverride': entry.groupOverride,
    'groupWeight': entry.groupWeight,
    'scanDepth': entry.scanDepth,
    'caseSensitive': entry.caseSensitive,
    'useRegex': entry.useRegex,
    'matchWholeWords': entry.matchWholeWords,
    'useGroupScoring': entry.useGroupScoring,
    'triggers': entry.triggers,
    for (final field in const [
      'matchPersonaDescription',
      'matchCharacterDescription',
      'matchCharacterPersonality',
      'matchCharacterDepthPrompt',
      'matchScenario',
      'matchCreatorNotes',
    ])
      field: fields[field] == true,
    'characterFilter':
        filter is Map<String, Object?> && (_strings(filter['names']).isNotEmpty || _strings(filter['tags']).isNotEmpty)
        ? {
            'isExclude': filter['isExclude'] == true,
            'names': _strings(filter['names']),
            'tags': _strings(filter['tags']),
          }
        : null,
    // Timers use JavaScript truthiness/Number on these original JSON values,
    // including strings, arrays and objects. Do not rebuild integer defaults.
    for (final field in const ['sticky', 'cooldown', 'delay']) field: fields[field],
  };
}

String _worldInfoPointerToken(String value) => value.replaceAll('~', '~0').replaceAll('/', '~1');

/// Typed consumption identity; content version is provenance, never the key.
final class WorldInfoPackSource {
  const WorldInfoPackSource({
    required this.source,
    required this.resourceLocalId,
    required this.entryLocalId,
    required this.packVersion,
  });
  final state_core.StateExecutionSource source;
  final String resourceLocalId, entryLocalId, packVersion;
  _PackWorldInfoEntryKey get _key => (source, resourceLocalId, entryLocalId);
}

typedef _PackWorldInfoEntryKey = (state_core.StateExecutionSource, String, String);

/// Static input for import diagnostics. A dynamic pattern must be deferred
/// until normal runtime expansion. Conditional header inputs are conservatively
/// listed, including fallback lines, without deciding their runtime eligibility.
class WorldInfoRegexInput {
  const WorldInfoRegexInput({
    required this.bookId,
    required this.uid,
    required this.source,
    required this.path,
    required this.pattern,
    required this.dialect,
    required this.caseSensitive,
    required this.isDynamic,
    this.conditional = false,
    this.isFallback = false,
    this.line,
    this.decorator,
    this.keyIndex,
  });
  final String bookId;
  final String uid;
  final WorldInfoSource source;
  final String path;
  final String pattern;
  final RegexDialect dialect;
  final bool caseSensitive;
  final bool isDynamic;
  final bool conditional;
  final bool isFallback;

  /// One-based line in content; [path] still points to the actual JSON string.
  final int? line;
  final String? decorator;
  final int? keyIndex;

  Map<String, Object?> toJson() => {
    'bookId': bookId,
    'uid': uid,
    'source': source.name,
    'path': path,
    'pattern': pattern,
    'dialect': dialect.name,
    'caseSensitive': caseSensitive,
    'dynamic': isDynamic,
    'conditional': conditional,
    'fallback': isFallback,
    if (line != null) 'line': line,
    if (decorator != null) 'decorator': decorator,
    if (keyIndex != null) 'keyIndex': keyIndex,
  };
}

/// Extracts stored user regex inputs, including entries shadowed by duplicate
/// V3 ids. It never expands, compiles, matches, changes a book or disables an
/// entire entry. The caller can compile static inputs through its executor.
List<WorldInfoRegexInput> worldInfoRegexInputs(WorldInfoBook book) {
  final result = <WorldInfoRegexInput>[];
  for (final original in _regexInspectionEntries(book)) {
    final entry = original.entry;
    final base = original.path;
    void add(
      String pattern,
      String path, {
      bool conditional = false,
      bool fallback = false,
      int? line,
      String? decorator,
      int? keyIndex,
    }) {
      // Native activation trims after macro expansion; inspect that same
      // possible regex even if its stored key has surrounding whitespace.
      // V3 inputs retain their pattern text. The runtime scorer still reads
      // untrimmed raw keys independently, exactly as before this inspection.
      if (!entry.useRegex) pattern = trimJsWhitespace(pattern);
      final dynamicPattern = pattern.contains('{{') || _worldInfoMacroAlias.hasMatch(pattern);
      if (!entry.useRegex && !dynamicPattern && !isNativeRegexLiteral(pattern)) return;
      result.add(
        WorldInfoRegexInput(
          bookId: book.id,
          uid: entry.uid,
          source: book.source,
          path: path,
          pattern: pattern,
          dialect: entry.useRegex ? RegexDialect.v3Keyword : RegexDialect.nativeKeyword,
          caseSensitive: entry.caseSensitive ?? false,
          isDynamic: dynamicPattern,
          conditional: conditional,
          isFallback: fallback,
          line: line,
          decorator: decorator,
          keyIndex: keyIndex,
        ),
      );
    }

    final primary = entry.keys;
    final secondary = entry.secondaryKeys;
    for (var index = 0; index < primary.length; index++) {
      add(primary[index], '$base.${_keywordPath(entry, false, index)}');
    }
    for (var index = 0; index < secondary.length; index++) {
      add(secondary[index], '$base.${_keywordPath(entry, true, index)}', conditional: true);
    }
    for (final header in _decoratorHeader(entry.content).lines) {
      final name = header.name;
      if (name != 'additional_keys' && name != 'exclude_keys') continue;
      if (name == 'exclude_keys' && entry.useRegex) continue;
      final keys = _decoratorKeys(header.value);
      if (keys == null) continue;
      for (var index = 0; index < keys.length; index++) {
        add(
          keys[index],
          '$base.content',
          conditional: true,
          fallback: header.isFallback,
          line: header.number,
          decorator: name,
          keyIndex: index,
        );
      }
    }
  }
  return List.unmodifiable(result);
}

final _worldInfoMacroAlias = RegExp(r'<(?:USER|BOT|CHAR|GROUP|CHARIFNOTGROUP)>', caseSensitive: false);

/// Original stored rows with their source paths and the loader's exact UID
/// normalization, including rows shadowed by duplicate V3 IDs. This inspection
/// does not change [book] or evaluate its entries.
Iterable<({WorldInfoEntry entry, String path})> worldInfoStoredEntries(WorldInfoBook book) =>
    _regexInspectionEntries(book);

Iterable<({WorldInfoEntry entry, String path})> _regexInspectionEntries(WorldInfoBook book) sync* {
  final entries = book._raw['entries'];
  if (entries is List<Object?>) {
    for (var index = 0; index < entries.length; index++) {
      final value = entries[index]! as Map<String, Object?>;
      yield (
        entry: WorldInfoEntry._(
          book,
          _id(value['id'] ?? index),
          value,
          _convertCharacterEntry(value, index),
          '/entries/$index',
        ),
        path: 'entries[$index]',
      );
    }
  } else if (entries is Map<String, Object?>) {
    for (final key in _objectKeys(entries.keys)) {
      final value = entries[key]! as Map<String, Object?>;
      yield (
        entry: WorldInfoEntry._(
          book,
          _id(value['uid'] ?? key),
          value,
          value,
          '/entries/${_worldInfoPointerToken(key)}',
        ),
        path: 'entries[${jsonEncode(key)}]',
      );
    }
  } else {
    throw StateError('A parsed world-info book no longer has its original entries.');
  }
}

class WorldInfoSettings {
  const WorldInfoSettings({
    this.scanDepth = 2,
    this.budgetPercent = 25,
    this.budgetCap = 0,
    this.includeNames = true,
    this.recursive = false,
    this.caseSensitive = false,
    this.matchWholeWords = false,
    this.useGroupScoring = false,
    this.strategy = WorldInfoStrategy.characterFirst,
    this.minActivations = 0,
    this.minActivationsDepthMax = 0,
    this.maxRecursionSteps = 0,
  });

  factory WorldInfoSettings.fromJson(Map<String, Object?> json) {
    final strategy = _integer(json['world_info_character_strategy']) ?? 1;
    return WorldInfoSettings(
      scanDepth: _integer(json['world_info_depth']) ?? 2,
      budgetPercent: _number(json['world_info_budget']) ?? 25,
      budgetCap: _integer(json['world_info_budget_cap']) ?? 0,
      includeNames: _boolean(json['world_info_include_names']) ?? true,
      recursive: _boolean(json['world_info_recursive']) ?? false,
      caseSensitive: _boolean(json['world_info_case_sensitive']) ?? false,
      matchWholeWords: _boolean(json['world_info_match_whole_words']) ?? false,
      useGroupScoring: _boolean(json['world_info_use_group_scoring']) ?? false,
      strategy: strategy == 1
          ? WorldInfoStrategy.characterFirst
          : strategy == 2
          ? WorldInfoStrategy.globalFirst
          : WorldInfoStrategy.evenly,
      minActivations: _integer(json['world_info_min_activations']) ?? 0,
      minActivationsDepthMax: _integer(json['world_info_min_activations_depth_max']) ?? 0,
      maxRecursionSteps: _integer(json['world_info_max_recursion_steps']) ?? 0,
    );
  }
  final int scanDepth;
  final num budgetPercent;
  final int budgetCap;
  final bool includeNames;
  final bool recursive;
  final bool caseSensitive;
  final bool matchWholeWords;
  final bool useGroupScoring;
  final WorldInfoStrategy strategy;
  final int minActivations;
  final int minActivationsDepthMax;
  final int maxRecursionSteps;
}

class WorldInfoMessage {
  const WorldInfoMessage(this.text, {this.speaker = ''});
  final String text;
  final String speaker;
}

/// All dependencies are explicit. Callers supply only prompt-eligible messages
/// (for example, remove hidden nodes) in oldest-to-newest order. Random values
/// must be in [0, 1); tokenCount must be a deterministic non-negative counter.
class WorldInfoInput {
  const WorldInfoInput({
    required this.books,
    required this.messages,
    required this.maxContext,
    required this.tokenCount,
    required this.random,
    int? messageCount,
    this.expand = _identity,
    this.settings = const WorldInfoSettings(),
    this.externalActivations = const <WorldInfoEntryRef>{},
    this.packSources = const {},
    this.packWorldInfo,
    this.scanInjections = const [],
    this.personaDescription = '',
    this.characterDescription = '',
    this.characterPersonality = '',
    this.characterDepthPrompt = '',
    this.scenario = '',
    this.creatorNotes = '',
    this.trigger = 'normal',
    this.characterName = '',
    this.characterTags,
    this.timedWorldInfo = const {},
    this.dryRun = false,
    this.decoratorState = const {},
    this.assistantMessageCount,
    this.greetingIndex,
    this.userIconName,
    this.contextAtCapacity,
    this.postProcessContent,
    this.availablePromptSections,
    this.checkCancelled,
  }) : _messageCount = messageCount;
  final List<WorldInfoBook> books;
  final List<WorldInfoMessage> messages;
  final int? _messageCount;

  /// Complete prompt-eligible history length when [messages] is a scan suffix.
  /// Hidden and ST-system messages are excluded from both counts.
  int get messageCount => _messageCount ?? messages.length;
  final int maxContext;
  final int Function(String) tokenCount;
  final double Function() random;
  final String Function(String) expand;
  final WorldInfoSettings settings;

  /// Requests activation of already-loaded entries. The evaluator snapshots
  /// at most [worldInfoExternalActivationLimit] references before its first
  /// await. Gates, groups, probability and budget still apply. A duplicate uid
  /// in one effective book is ambiguous and receives no external privilege.
  final Set<WorldInfoEntryRef> externalActivations;

  /// Engine-only sidecars for the same remapped entries used by every WI consumer.
  final Map<WorldInfoEntryRef, WorldInfoPackSource> packSources;
  final state_core.StatePackWorldInfoSnapshot? packWorldInfo;
  final List<String> scanInjections;
  final String personaDescription;
  final String characterDescription;
  final String characterPersonality;
  final String characterDepthPrompt;
  final String scenario;
  final String creatorNotes;
  final String trigger;

  /// ST's character filename identifier, without its image extension.
  final String characterName;

  /// Null means ST has no tag-map entry; an empty list means a known empty one.
  final List<String>? characterTags;

  /// The selected branch's chat_metadata.timedWorldInfo, before this evaluation.
  final Map<String, Object?> timedWorldInfo;

  /// ST preview semantics: ignore sticky/cooldown, still check delay, do not add timers.
  final bool dryRun;

  /// Proven prior V3 admissions for this selected branch, keyed by ST entry hash.
  final Map<String, Object?> decoratorState;

  /// Null means unavailable: count-dependent decorators are ignored, including fallbacks.
  final int? assistantMessageCount;
  final int? greetingIndex;

  /// V3 asset name, never inferred from an avatar filesystem path.
  final String? userIconName;

  /// Null means the caller cannot determine full-prompt capacity. False also
  /// allows an assembler to honor ignore_on_max_context by trimming first.
  final bool? contextAtCapacity;

  /// ST applies world-info prompt regex after admission and recursion, in
  /// descending insertion order. Only an at-depth entry receives a depth.
  final String Function(WorldInfoEntry entry, String content, int? depth)? postProcessContent;

  /// Actual enabled card slots in the current preset. Null leaves section
  /// availability to the supplied nonempty character fields for standalone use.
  final Set<String>? availablePromptSections;

  /// Called before/after protected work and before owner-side callbacks. The
  /// caller's cancellation exception propagates instead of skipping an entry.
  final void Function()? checkCancelled;
}

/// A required keyword could not be decided safely. This is not a negative
/// match, and cannot activate an entry through NOT or exclusion conditions.
class WorldInfoRegexDiagnostic {
  const WorldInfoRegexDiagnostic({
    required this.bookId,
    required this.uid,
    required this.source,
    required this.keyPath,
    required this.phase,
    required this.round,
    required this.code,
    required this.message,
  });
  final String bookId;
  final String uid;
  final WorldInfoSource source;
  final String keyPath;
  final WorldInfoScanPhase phase;
  final int round;
  final String code;
  final String message;

  Map<String, Object?> toJson() => {
    'bookId': bookId,
    'uid': uid,
    'source': source.name,
    'keyPath': keyPath,
    'phase': phase.name,
    'round': round,
    'code': code,
    'message': message,
  };
}

/// The last actual decision for one bounded external request. This is not a
/// replay of the scan and does not assert that a provider received the content.
/// An ambiguous reference reports its resolution failure independently of any
/// ordinary keyword/sticky admission with the same identity.
class WorldInfoExternalActivation {
  const WorldInfoExternalActivation({
    required this.bookId,
    required this.uid,
    required this.resolved,
    required this.admitted,
    required this.retained,
    this.reason,
    this.code,
    this.stage,
    this.phase,
    this.round,
  });
  final String bookId;
  final String uid;
  final bool resolved;

  /// Admitted by the WI scan before the optional final filter.
  final bool admitted;

  /// Still present after [WorldInfoResult.withoutEntries]. This alone does not
  /// prove consumption of an outlet or inclusion by the prompt assembler.
  final bool retained;
  final String? reason;
  final String? code;
  final String? stage;
  final WorldInfoScanPhase? phase;
  final int? round;
  WorldInfoEntryRef get identity => (bookId, uid);
  Map<String, Object?> toJson() => {
    'bookId': bookId,
    'uid': uid,
    'resolved': resolved,
    'admitted': admitted,
    'retained': retained,
    if (reason != null) 'reason': reason,
    if (code != null) 'code': code,
    if (stage != null) 'stage': stage,
    if (phase != null) 'phase': phase!.name,
    if (round != null) 'round': round,
  };
}

/// One admitted entry, including both original and macro-expanded content.
class WorldInfoHit {
  const WorldInfoHit({
    required this.entry,
    required this.content,
    required this.reason,
    required this.phase,
    required this.round,
    this.primaryKey,
    this.secondaryMatches = const [],
    this.probabilityRoll,
    this.positionOverride,
    this.depthOverride,
    this.roleOverride,
    this.section,
    this.disabledUiPrompt,
    this.ignoreOnMaxContext = false,
    this.assistantPrefill = false,
  });
  final WorldInfoEntry entry;
  final String content;
  final String reason; // constant, keywords, sticky, external or a force decorator.
  final String? primaryKey;
  final List<String> secondaryMatches;
  final WorldInfoScanPhase phase;
  final int round;
  final double? probabilityRoll;
  final int? positionOverride;
  final int? depthOverride;
  final int? roleOverride;
  final String? section;
  final String? disabledUiPrompt;
  final bool ignoreOnMaxContext;

  /// Explicit V3 assistant role at raw depth zero, before depth clamping.
  final bool assistantPrefill;
  int? get position => positionOverride ?? entry.position;
  int get depth => depthOverride ?? entry.depth;
  int get role => roleOverride ?? entry.role;
  String get bookId => entry.book.id;
  String get uid => entry.uid;
  WorldInfoSource get source => entry.book.source;
  String get originalContent => entry.content;
  num get order => entry.order;
  WorldInfoHit withContent(String value) => WorldInfoHit(
    entry: entry,
    content: value,
    reason: reason,
    phase: phase,
    round: round,
    primaryKey: primaryKey,
    secondaryMatches: secondaryMatches,
    probabilityRoll: probabilityRoll,
    positionOverride: positionOverride,
    depthOverride: depthOverride,
    roleOverride: roleOverride,
    section: section,
    disabledUiPrompt: disabledUiPrompt,
    ignoreOnMaxContext: ignoreOnMaxContext,
    assistantPrefill: assistantPrefill,
  );
}

class WorldInfoDepth {
  const WorldInfoDepth({required this.depth, required this.role, required this.entries});
  final int depth;
  final int role;
  final List<WorldInfoHit> entries;
  String get content => entries.map((entry) => entry.content).join('\n');
}

class WorldInfoResult {
  WorldInfoResult._(
    List<WorldInfoHit> hits, {
    required this.budget,
    required this.overflowed,
    required this.scanRounds,
    required this.timedWorldInfo,
    required this.decoratorState,
    required this.packWorldInfo,
    required List<Map<String, Object?>> packIssues,
    required List<WorldInfoRegexDiagnostic> regexDiagnostics,
    List<WorldInfoExternalActivation> externalActivations = const [],
    this.externalActivationsOmitted = 0,
    required WorldInfoResult Function(List<WorldInfoHit>) finalize,
  }) : _finalize = finalize,
       activated = List.unmodifiable(hits),
       regexDiagnostics = List.unmodifiable(regexDiagnostics),
       externalActivations = List.unmodifiable(externalActivations),
       packIssues = List.unmodifiable(packIssues) {
    final groups = <(int, int), List<WorldInfoHit>>{};
    for (final hit in _stableSort(hits, (a, b) => _compareWorldOrder(a.order, b.order))) {
      if (hit.disabledUiPrompt case final prompt?) disabledUiPrompts.add(prompt);
      if (hit.content.isEmpty) continue;
      if (hit.section case final section?) {
        (sections[section] ??= []).insert(0, hit);
        continue;
      }
      switch (hit.position) {
        case 0:
          before.insert(0, hit);
        case 1:
          after.insert(0, hit);
        case 2:
          authorNoteBefore.insert(0, hit);
        case 3:
          authorNoteAfter.insert(0, hit);
        case 4:
          (groups[(hit.depth, hit.role)] ??= []).insert(0, hit);
        case 5:
          examplesBefore.insert(0, hit);
        case 6:
          examplesAfter.insert(0, hit);
        case 7:
          if (hit.entry.outlet.isNotEmpty) (outlets[hit.entry.outlet] ??= []).add(hit);
      }
    }
    depths = [
      for (final item in groups.entries)
        WorldInfoDepth(depth: item.key.$1, role: item.key.$2, entries: List.unmodifiable(item.value)),
    ];
  }
  final List<WorldInfoHit> activated;
  final before = <WorldInfoHit>[];
  final after = <WorldInfoHit>[];
  final examplesBefore = <WorldInfoHit>[];
  final examplesAfter = <WorldInfoHit>[];
  final authorNoteBefore = <WorldInfoHit>[];
  final authorNoteAfter = <WorldInfoHit>[];
  late final List<WorldInfoDepth> depths;
  final outlets = <String, List<WorldInfoHit>>{};
  final int budget;
  final bool overflowed;
  final int scanRounds;
  final Map<String, Object?> timedWorldInfo;
  final Map<String, Object?> decoratorState;
  final List<WorldInfoRegexDiagnostic> regexDiagnostics;
  final state_core.StatePackWorldInfoDelta packWorldInfo;
  final List<Map<String, Object?>> packIssues;
  final List<WorldInfoExternalActivation> externalActivations;

  /// References beyond the bounded input prefix, not evaluated externally.
  final int externalActivationsOmitted;
  final WorldInfoResult Function(List<WorldInfoHit>) _finalize;

  /// Finalize state after the prompt assembler drops optional V3 entries.
  /// This never rescans, expands a macro, consumes entropy, or admits a new hit.
  WorldInfoResult withoutEntries(Set<(String, String)> identities) => identities.isEmpty
      ? this
      : _finalize(activated.where((hit) => !identities.contains(hit.entry.identity)).toList());
  final sections = <String, List<WorldInfoHit>>{};
  final disabledUiPrompts = <String>{};
  String get beforeText => before.map((hit) => hit.content).join('\n');
  String get afterText => after.map((hit) => hit.content).join('\n');
}

class WorldInfoEngine {
  /// Borrows the executor; its owner controls the persistent worker lifetime.
  const WorldInfoEngine({required RegexExecutor worker}) : _worker = worker;
  final RegexExecutor _worker;

  Future<WorldInfoResult> evaluate(WorldInfoInput input) async {
    input.checkCancelled?.call();
    // Capture the bounded request set before awaited work can publish a
    // different director result or mutate the caller's collection.
    final external = _ExternalActivations(input.externalActivations);
    final packSources = Map<WorldInfoEntryRef, WorldInfoPackSource>.of(input.packSources);
    final settings = input.settings;
    // JS Math.round rounds ties toward +infinity, unlike Dart for negatives.
    var budget = (settings.budgetPercent * input.maxContext / 100 + 0.5).floor();
    if (budget == 0) budget = 1;
    if (settings.budgetCap > 0 && budget > settings.budgetCap) budget = settings.budgetCap;
    final entries = worldInfoExecutionEntries(input.books, strategy: settings.strategy);
    external.resolve(entries);
    final sorted = <_RuntimeEntry>[];
    for (var index = 0; index < entries.length; index++) {
      if (index > 0 && index % 64 == 0) {
        await Future<void>.delayed(Duration.zero);
        input.checkCancelled?.call();
      }
      final entry = entries[index];
      sorted.add(_RuntimeEntry(entry, input, packSources[entry.identity]));
    }
    final pack = _PackWorldInfoState(input, sorted);
    final timed = _TimedEffects(input, sorted, pack);
    final decoratorHistory = _DecoratorHistory(input, pack);
    final buffer = _ScanBuffer(input, _worker, external);
    final activated = <(String, String), WorldInfoHit>{};
    final failedProbability = <_RuntimeEntry>{};
    final levels = sorted.map((item) => item.entry.delayUntilRecursion).where((level) => level != 0).toSet().toList()
      ..sort();
    var currentLevel = levels.isEmpty ? 0 : levels.removeAt(0);
    var overflowed = false;
    var rounds = 0;
    var activatedText = '';
    WorldInfoScanPhase? phase = sorted.isEmpty ? null : WorldInfoScanPhase.initial;
    while (phase != null) {
      if (settings.maxRecursionSteps != 0 && settings.maxRecursionSteps <= rounds) break;
      rounds++;
      buffer.round = rounds;
      WorldInfoScanPhase? next;
      final candidates = <_RuntimeEntry>[];
      final reasons = <_RuntimeEntry, _MatchReason>{};
      for (var index = 0; index < sorted.length; index++) {
        if (index > 0 && index % 64 == 0) await Future<void>.delayed(Duration.zero);
        final item = sorted[index];
        final entry = item.entry;
        buffer.checkCancelled();
        if (buffer.skippedEntries.contains(entry.identity)) continue;
        try {
          if (failedProbability.contains(item) || activated.containsKey(entry.identity)) continue;
          if (!pack.available(item)) {
            external.reject(entry.identity, 'pack-runtime', 'candidate', phase, rounds);
            continue;
          }
          if (entry.disabled) {
            external.reject(entry.identity, 'disabled', 'candidate', phase, rounds);
            continue;
          }
          if (entry.triggers.isNotEmpty && !entry.triggers.contains(input.trigger)) {
            external.reject(entry.identity, 'trigger', 'candidate', phase, rounds);
            continue;
          }
          if (!_characterAllowed(entry, input)) {
            external.reject(entry.identity, 'character-filter', 'candidate', phase, rounds);
            continue;
          }
          final sticky = timed.isActive('sticky', item);
          if (timed.isActive('delay', item) || (timed.isActive('cooldown', item) && !sticky)) {
            external.reject(
              entry.identity,
              timed.isActive('delay', item) ? 'delay' : 'cooldown',
              'candidate',
              phase,
              rounds,
            );
            continue;
          }
          if (!sticky && phase != WorldInfoScanPhase.recursion && entry.delayUntilRecursion != 0) {
            external.reject(entry.identity, 'recursion-phase', 'candidate', phase, rounds);
            continue;
          }
          if (phase == WorldInfoScanPhase.recursion &&
              entry.delayUntilRecursion != 0 &&
              entry.delayUntilRecursion > currentLevel &&
              !sticky) {
            external.reject(entry.identity, 'recursion-level', 'candidate', phase, rounds);
            continue;
          }
          if (phase == WorldInfoScanPhase.recursion && settings.recursive && entry.excludeRecursion && !sticky) {
            external.reject(entry.identity, 'exclude-recursion', 'candidate', phase, rounds);
            continue;
          }
          final decorators = item.decorators;
          _MatchReason? reason;
          if (decorators.activate) {
            reason = const _MatchReason('decorator-activate');
          } else {
            final matchedBefore = decoratorHistory.previous(item) > 1;
            if (decorators.dontActivate || (decorators.dontAfterMatch && matchedBefore)) {
              external.reject(entry.identity, 'decorator-block', 'candidate', phase, rounds);
              continue;
            }
            if (decorators.keepAfterMatch && matchedBefore) {
              reason = const _MatchReason('decorator-keep');
            } else {
              final allowed = await decorators.allows(buffer, phase);
              buffer.checkCancelled();
              if (!allowed) {
                external.reject(entry.identity, 'decorator-condition', 'candidate', phase, rounds);
                continue;
              }
              reason = external.contains(entry.identity)
                  ? const _MatchReason('external')
                  : entry.constant && !entry.useRegex
                  ? const _MatchReason('constant')
                  : sticky
                  ? const _MatchReason('sticky')
                  : await _keywords(entry, buffer, phase, scanDepth: decorators.scanDepth);
              buffer.checkCancelled();
            }
          }
          if ((reason?.kind == 'sticky' || reason?.kind == 'external') && entry.useRegex) {
            // Sticky and external activation are extensions, not V3 IN ANY
            // CASE decorators. They bypass a match, not primary regex validity.
            final keys = entry.keys.map(buffer.expand).toList();
            for (var index = 0; index < keys.length; index++) {
              await buffer.validate(keys[index], entry, phase, _keywordPath(entry, false, index));
              buffer.checkCancelled();
            }
          }
          if (reason != null) {
            candidates.add(item);
            reasons[item] = reason;
          }
        } on _IndeterminateWorldInfoEntry {
          // Keep preceding decisions and effects. Never convert this failure
          // into false inside a NOT/exclusion expression.
          continue;
        }
      }

      var newContent = '';
      final previousTokens = _tokens(input, activatedText);
      final prioritized = _stableSort(
        candidates,
        (a, b) => (timed.isActive('sticky', b) ? 1 : 0) - (timed.isActive('sticky', a) ? 1 : 0),
      );
      candidates
        ..clear()
        ..addAll(prioritized);
      await _filterGroups(candidates, activated.values, buffer, phase, input, timed, external);
      buffer.checkCancelled();
      var ignoresBudget = candidates.where((item) => item.entry.ignoreBudget).length;
      for (final item in candidates) {
        buffer.checkCancelled();
        final entry = item.entry;
        if (entry.ignoreBudget) ignoresBudget--;
        if (overflowed && !entry.ignoreBudget) {
          external.reject(entry.identity, 'world-budget', 'budget', phase, rounds);
          if (ignoresBudget > 0) continue;
          // The remaining ordinary candidates are skipped by this same break.
          external.rejectRemaining(candidates, item, phase, rounds);
          break;
        }
        double? roll;
        if (entry.useProbability && entry.probability != 100 && !timed.isActive('sticky', item)) {
          roll = _random(input) * 100;
          if (roll > entry.probability) {
            failedProbability.add(item);
            external.reject(entry.identity, 'probability', 'probability', phase, rounds);
            continue;
          }
        }
        item.content = buffer.expand(item.content);
        newContent += '${item.content}\n';
        if (!entry.ignoreBudget && previousTokens + _tokens(input, newContent) >= budget) {
          overflowed = true;
          external.reject(entry.identity, 'world-budget', 'budget', phase, rounds);
          continue;
        }
        final reason = reasons[item]!;
        activated[entry.identity] = WorldInfoHit(
          entry: entry,
          content: item.content,
          reason: reason.kind,
          phase: phase,
          round: rounds,
          primaryKey: reason.primary,
          secondaryMatches: reason.secondary,
          probabilityRoll: roll,
          positionOverride: item.decorators.depth == null ? null : 4,
          depthOverride: item.decorators.depth,
          roleOverride: item.decorators.role,
          section: item.decorators.section,
          disabledUiPrompt: item.decorators.disabledUiPrompt,
          ignoreOnMaxContext: item.decorators.ignoreOnMaxContext,
          assistantPrefill: item.decorators.assistantPrefill,
        );
        external.admit(entry.identity, reason.kind, phase, rounds);
      }

      // ST removes only probability failures from this "successful" list.
      // Budget-skipped candidates can enter the buffer when delayed recursion
      // forces another pass; the original book remains untouched.
      final recursiveEntries = candidates
          .where((item) => !failedProbability.contains(item) && !item.entry.preventRecursion)
          .toList();
      if (settings.recursive && !overflowed && recursiveEntries.isNotEmpty) next = WorldInfoScanPhase.recursion;
      if (settings.recursive &&
          !overflowed &&
          phase == WorldInfoScanPhase.minActivations &&
          buffer.recursive.isNotEmpty) {
        next = WorldInfoScanPhase.recursion;
      }
      if (next == null && !overflowed && settings.minActivations > activated.length) {
        final overMax =
            (settings.minActivationsDepthMax > 0 && buffer.depth > settings.minActivationsDepthMax) ||
            buffer.depth > input.messageCount;
        if (!overMax) {
          next = WorldInfoScanPhase.minActivations;
          buffer.skew++;
        }
      }
      if (next == null && levels.isNotEmpty) {
        next = WorldInfoScanPhase.recursion;
        currentLevel = levels.removeAt(0);
      }
      if (next != null) {
        final text = recursiveEntries.map((item) => item.content).join('\n');
        if (text.isNotEmpty) {
          buffer.recursive.add(text);
          activatedText = '$text\n$activatedText';
        }
      }
      phase = next;
    }
    final transform = input.postProcessContent;
    if (transform != null) {
      for (final hit in _stableSort(activated.values.toList(), (a, b) => _compareWorldOrder(a.order, b.order))) {
        buffer.checkCancelled();
        activated[hit.entry.identity] = hit.withContent(
          transform(hit.entry, hit.content, hit.section == null && hit.position == 4 ? hit.depth : null),
        );
        buffer.checkCancelled();
      }
    }
    // Keep the post-expiry, pre-admission state. Optional V3 entries can later
    // be removed by the full-prompt budget without repeating this scan or any
    // macro/regex/random side effect, or accidentally retaining their timers.
    WorldInfoResult finalize(List<WorldInfoHit> hits) {
      final packCandidate = pack.fork();
      final effects = timed.fork(packCandidate)..finish(hits);
      final history = decoratorHistory.fork(packCandidate);
      final retained = hits.map((hit) => hit.entry.identity).toSet();
      history.finish(sorted.where((item) => retained.contains(item.entry.identity)));
      return WorldInfoResult._(
        hits,
        budget: budget,
        overflowed: overflowed,
        scanRounds: rounds,
        timedWorldInfo: effects.state,
        decoratorState: history.state,
        packWorldInfo: packCandidate.delta,
        packIssues: pack.issues,
        regexDiagnostics: buffer.diagnostics,
        externalActivations: external.finish(retained),
        externalActivationsOmitted: external.omitted,
        finalize: finalize,
      );
    }

    buffer.checkCancelled();
    return finalize(activated.values.toList());
  }
}

class _RuntimeEntry {
  _RuntimeEntry(this.entry, WorldInfoInput input, this.packSource)
    : decorators = _Decorators(entry, input),
      hash = entry.stHash {
    content = decorators.content;
  }
  final WorldInfoEntry entry;
  final WorldInfoPackSource? packSource;
  final int hash;
  final _Decorators decorators;
  late String content;
}

class _MatchReason {
  const _MatchReason(this.kind, {this.primary, this.secondary = const []});
  final String kind;
  final String? primary;
  final List<String> secondary;
}

/// A bounded snapshot and one final decision per requested identity. No
/// expanded content, regex result, entropy or per-round history is retained.
class _ExternalActivations {
  _ExternalActivations(Set<WorldInfoEntryRef> requests)
    : _decisions = {
        for (final identity in requests.take(worldInfoExternalActivationLimit)) identity: _ExternalDecision(identity),
      },
      omitted = math.max(0, requests.length - worldInfoExternalActivationLimit);

  final Map<WorldInfoEntryRef, _ExternalDecision> _decisions;
  final int omitted;

  void resolve(List<WorldInfoEntry> entries) {
    if (_decisions.isEmpty) return;
    for (final entry in entries) {
      final decision = _decisions[entry.identity];
      if (decision != null) decision.matches++;
    }
    for (final decision in _decisions.values) {
      if (decision.matches != 1) {
        decision.code = decision.matches == 0 ? 'unresolved-reference' : 'ambiguous-reference';
        decision.stage = 'resolution';
      }
    }
  }

  bool contains(WorldInfoEntryRef identity) => _decisions[identity]?.matches == 1;

  void reject(WorldInfoEntryRef identity, String code, String stage, WorldInfoScanPhase phase, int round) {
    final decision = _decisions[identity];
    if (decision == null || decision.matches != 1 || decision.admitted) return;
    decision
      ..code = code
      ..stage = stage
      ..phase = phase
      ..round = round;
  }

  void rejectRemaining(List<_RuntimeEntry> candidates, _RuntimeEntry from, WorldInfoScanPhase phase, int round) {
    if (_decisions.isEmpty) return;
    var remaining = false;
    for (final item in candidates) {
      if (identical(item, from)) remaining = true;
      if (remaining && !item.entry.ignoreBudget) {
        reject(item.entry.identity, 'world-budget', 'budget', phase, round);
      }
    }
  }

  void admit(WorldInfoEntryRef identity, String reason, WorldInfoScanPhase phase, int round) {
    final decision = _decisions[identity];
    if (decision == null || decision.matches != 1) return;
    decision
      ..admitted = true
      ..reason = reason
      ..phase = phase
      ..round = round
      ..code = null
      ..stage = null;
  }

  List<WorldInfoExternalActivation> finish(Set<WorldInfoEntryRef> retained) => [
    for (final decision in _decisions.values)
      WorldInfoExternalActivation(
        bookId: decision.identity.$1,
        uid: decision.identity.$2,
        resolved: decision.matches == 1,
        admitted: decision.admitted,
        retained: decision.admitted && retained.contains(decision.identity),
        reason: decision.reason,
        code: decision.admitted
            ? (retained.contains(decision.identity) ? null : 'final-filter')
            : (decision.code ?? 'not-admitted'),
        stage: decision.admitted ? (retained.contains(decision.identity) ? null : 'final') : (decision.stage ?? 'scan'),
        phase: decision.phase,
        round: decision.round,
      ),
  ];
}

class _ExternalDecision {
  _ExternalDecision(this.identity);
  final WorldInfoEntryRef identity;
  var matches = 0;
  var admitted = false;
  String? reason;
  String? code;
  String? stage;
  WorldInfoScanPhase? phase;
  int? round;
}

final _worldInfoWhitespace = RegExp(r'\s+');
final _worldInfoGroupSeparator = RegExp(r',\s*');
const _worldInfoPlainPatternLimit = 1000;
final _worldInfoPlainPatterns = <String, RegExp>{};

// The needle is already case-normalized by _plainMatches. Escaping keeps this
// cache separate from user regex programs, which remain in the T21 worker.
RegExp _worldInfoPlainPattern(String needle) {
  final cached = _worldInfoPlainPatterns.remove(needle);
  if (cached != null) {
    _worldInfoPlainPatterns[needle] = cached;
    return cached;
  }
  final compiled = RegExp('(?:^|\\W)(${RegExp.escape(needle)})(?:\$|\\W)');
  if (_worldInfoPlainPatterns.length >= _worldInfoPlainPatternLimit) {
    _worldInfoPlainPatterns.remove(_worldInfoPlainPatterns.keys.first);
  }
  _worldInfoPlainPatterns[needle] = compiled;
  return compiled;
}

class _ScanBuffer {
  _ScanBuffer(this.input, this.worker, this.external) {
    var index = 0;
    for (final message in input.messages.reversed.take(1000)) {
      final text = input.settings.includeNames ? '${message.speaker}: ${message.text}' : message.text;
      if (text.isNotEmpty) {
        while (messages.length <= index) {
          messages.add('');
        }
        messages[index] = trimJsWhitespace(text);
      }
      index++;
    }
  }
  final WorldInfoInput input;
  final RegexExecutor worker;
  final _ExternalActivations external;
  final messages = <String>[];
  final recursive = <String>[];
  final skippedEntries = <(String, String)>{};
  final diagnostics = <WorldInfoRegexDiagnostic>[];
  final _diagnosticKeys = <(String, String, String, String)>{};
  final _rules = <(String, String, String)>{};
  var skew = 0;
  var round = 0;
  int get depth => input.settings.scanDepth + skew;

  void checkCancelled() => input.checkCancelled?.call();

  String expand(String text) {
    checkCancelled();
    final result = input.expand(text);
    checkCancelled();
    return result;
  }

  Never _skip(WorldInfoEntry entry, WorldInfoScanPhase phase, String keyPath, String code, String message) {
    skippedEntries.add(entry.identity);
    external.reject(entry.identity, code, 'regex', phase, round);
    if (_diagnosticKeys.add((entry.book.id, entry.uid, keyPath, code))) {
      diagnostics.add(
        WorldInfoRegexDiagnostic(
          bookId: entry.book.id,
          uid: entry.uid,
          source: entry.book.source,
          keyPath: keyPath,
          phase: phase,
          round: round,
          code: code,
          message: message,
        ),
      );
    }
    throw const _IndeterminateWorldInfoEntry();
  }

  void _admitRule(WorldInfoEntry entry, WorldInfoScanPhase phase, String keyPath) {
    checkCancelled();
    final identity = (entry.book.id, entry.uid, keyPath);
    if (_rules.contains(identity)) return;
    if (_rules.length >= worker.limits.maxRules) {
      _skip(entry, phase, keyPath, 'rule-limit', '本次世界书求值的正则规则数量已达上限，跳过此候选。');
    }
    _rules.add(identity);
  }

  Future<void> validate(String pattern, WorldInfoEntry entry, WorldInfoScanPhase phase, String keyPath) async {
    _admitRule(entry, phase, keyPath);
    checkCancelled();
    final result = await worker.compile(
      pattern,
      dialect: RegexDialect.v3Keyword,
      caseSensitive: entry.caseSensitive ?? false,
    );
    checkCancelled();
    if (result.status != RegexCompileStatus.compatible) {
      _skip(entry, phase, keyPath, result.code ?? 'regex-skipped', result.message ?? '无法安全校验所需正则，跳过此候选。');
    }
  }

  String get(WorldInfoEntry entry, WorldInfoScanPhase phase, {int? scanDepth}) {
    final effectiveDepth = scanDepth ?? entry.scanDepth ?? depth;
    if (effectiveDepth <= 0) return '';
    const joiner = '\n\x01';
    var result = '\x01${messages.take(math.min(effectiveDepth, 1000)).join(joiner)}';
    final global = {
      'matchPersonaDescription': input.personaDescription,
      'matchCharacterDescription': input.characterDescription,
      'matchCharacterPersonality': input.characterPersonality,
      'matchCharacterDepthPrompt': input.characterDepthPrompt,
      'matchScenario': input.scenario,
      'matchCreatorNotes': input.creatorNotes,
    };
    for (final item in global.entries) {
      if (entry._fields[item.key] == true && item.value.isNotEmpty) result += '$joiner${item.value}';
    }
    final injections = input.scanInjections.where((text) => text.isNotEmpty).toList();
    if (injections.isNotEmpty) result += '$joiner${injections.join(joiner)}';
    if (recursive.isNotEmpty && phase != WorldInfoScanPhase.minActivations) {
      result += '$joiner${recursive.join(joiner)}';
    }
    return result;
  }

  Future<bool> matches(
    String haystack,
    String needle,
    WorldInfoEntry entry,
    WorldInfoScanPhase phase,
    String keyPath,
  ) async {
    checkCancelled();
    if (!entry.useRegex && !isNativeRegexLiteral(needle)) {
      return _plainMatches(haystack, needle, entry);
    }
    _admitRule(entry, phase, keyPath);
    checkCancelled();
    final result = await worker.hasMatch(
      needle,
      haystack,
      dialect: entry.useRegex ? RegexDialect.v3Keyword : RegexDialect.nativeKeyword,
      caseSensitive: entry.caseSensitive ?? input.settings.caseSensitive,
    );
    checkCancelled();
    if (!entry.useRegex && result.compilation.status == RegexCompileStatus.literalFallback) {
      return _plainMatches(haystack, needle, entry);
    }
    if (result.compilation.status != RegexCompileStatus.compatible || result.status == RegexMatchStatus.skipped) {
      _skip(
        entry,
        phase,
        keyPath,
        result.code ?? result.compilation.code ?? 'regex-skipped',
        result.message ?? result.compilation.message ?? '无法安全判断所需正则，跳过此候选。',
      );
    }
    return result.status == RegexMatchStatus.matched;
  }

  bool _plainMatches(String haystack, String needle, WorldInfoEntry entry) {
    if (!(entry.caseSensitive ?? input.settings.caseSensitive)) {
      haystack = lowercaseWorldInfoPlain(haystack);
      needle = lowercaseWorldInfoPlain(needle);
    }
    if (!(entry.matchWholeWords ?? input.settings.matchWholeWords) || needle.split(_worldInfoWhitespace).length > 1) {
      return haystack.contains(needle);
    }
    return _worldInfoPlainPattern(needle).hasMatch(haystack);
  }

  Future<int> score(WorldInfoEntry entry, WorldInfoScanPhase phase, {int? scanDepth}) async {
    final text = get(entry, phase, scanDepth: scanDepth);
    // ST scoring does not substitute or trim keys, unlike activation matching.
    final keys = entry.keys;
    final secondaryKeys = entry.secondaryKeys;
    var primary = 0;
    var secondary = 0;
    for (var index = 0; index < keys.length; index++) {
      final found = await matches(text, keys[index], entry, phase, _keywordPath(entry, false, index));
      checkCancelled();
      if (found) primary++;
    }
    for (var index = 0; index < secondaryKeys.length; index++) {
      final found = await matches(text, secondaryKeys[index], entry, phase, _keywordPath(entry, true, index));
      checkCancelled();
      if (found) secondary++;
    }
    if (keys.isEmpty) return 0;
    // ST defaults nullish logic during activation, but not during scoring.
    if (secondaryKeys.isNotEmpty &&
        entry._fields['selectiveLogic'] != null &&
        (entry.selectiveLogic == 0 || (entry.selectiveLogic == 3 && secondary == secondaryKeys.length))) {
      return primary + secondary;
    }
    return primary;
  }
}

class _IndeterminateWorldInfoEntry implements Exception {
  const _IndeterminateWorldInfoEntry();
}

String _keywordPath(WorldInfoEntry entry, bool secondary, int index) {
  final field = entry.book._raw['entries'] is List<Object?>
      ? (secondary ? 'secondary_keys' : 'keys')
      : (secondary ? 'keysecondary' : 'key');
  final original = entry._fields[secondary ? 'keysecondary' : 'key'];
  if (original is List<Object?>) {
    var stringIndex = 0;
    for (var rawIndex = 0; rawIndex < original.length; rawIndex++) {
      if (original[rawIndex] is! String) continue;
      if (stringIndex == index) return '$field[$rawIndex]';
      stringIndex++;
    }
  }
  return '$field[$index]';
}

Future<_MatchReason?> _keywords(
  WorldInfoEntry entry,
  _ScanBuffer buffer,
  WorldInfoScanPhase phase, {
  int? scanDepth,
}) async {
  final text = buffer.get(entry, phase, scanDepth: scanDepth);
  final keys = entry.keys;
  if (entry.useRegex) {
    final expanded = [for (final key in keys) buffer.expand(key)];
    for (var index = 0; index < expanded.length; index++) {
      await buffer.validate(expanded[index], entry, phase, _keywordPath(entry, false, index));
      buffer.checkCancelled();
    }
    for (var index = 0; index < expanded.length; index++) {
      final found = await buffer.matches(text, expanded[index], entry, phase, _keywordPath(entry, false, index));
      buffer.checkCancelled();
      if (found) return _MatchReason('keywords', primary: keys[index]);
    }
    return null;
  }
  String? primary;
  for (var index = 0; index < keys.length; index++) {
    final key = keys[index];
    final substituted = buffer.expand(key);
    final found =
        substituted.isNotEmpty &&
        await buffer.matches(text, trimJsWhitespace(substituted), entry, phase, _keywordPath(entry, false, index));
    buffer.checkCancelled();
    if (found) {
      primary = key;
      break;
    }
  }
  if (primary == null || primary.isEmpty) return null;
  if (!entry.selective || entry.secondaryKeys.isEmpty) return _MatchReason('keywords', primary: primary);
  var any = false;
  var all = true;
  final matched = <String>[];
  final secondaryKeys = entry.secondaryKeys;
  for (var index = 0; index < secondaryKeys.length; index++) {
    final key = secondaryKeys[index];
    final substituted = buffer.expand(key);
    final found =
        substituted.isNotEmpty &&
        await buffer.matches(text, trimJsWhitespace(substituted), entry, phase, _keywordPath(entry, true, index));
    buffer.checkCancelled();
    if (found) {
      any = true;
      matched.add(key);
    } else {
      all = false;
    }
    if ((entry.selectiveLogic == 0 && found) || (entry.selectiveLogic == 1 && !found)) {
      return _MatchReason('keywords', primary: primary, secondary: matched);
    }
  }
  return (entry.selectiveLogic == 2 && !any) || (entry.selectiveLogic == 3 && all)
      ? _MatchReason('keywords', primary: primary, secondary: matched)
      : null;
}

Future<void> _filterGroups(
  List<_RuntimeEntry> candidates,
  Iterable<WorldInfoHit> activated,
  _ScanBuffer buffer,
  WorldInfoScanPhase phase,
  WorldInfoInput input,
  _TimedEffects timed,
  _ExternalActivations external,
) async {
  final groups = <String, List<_RuntimeEntry>>{};
  for (final item in candidates) {
    for (final group in item.entry.group.split(_worldInfoGroupSeparator).where((name) => name.isNotEmpty)) {
      (groups[group] ??= []).add(item);
    }
  }
  // JS uses splice(indexOf(entry), 1), including -1 for entries already removed
  // by another group. Preserve its candidate-only effect for ST parity; see the
  // independent overlapping-group fixture. No original book data is removed.
  void remove(_RuntimeEntry item, String code) {
    if (candidates.isEmpty) return;
    final index = candidates.indexOf(item);
    final removed = candidates.removeAt(index < 0 ? candidates.length - 1 : index);
    // In an overlapping group the actual victim can differ from item. Record
    // what the preserved ST splice(-1) operation really removed.
    external.reject(removed.entry.identity, code, 'group', phase, buffer.round);
  }

  final stickyGroups = <String>{};
  for (final key in _objectKeys(groups.keys)) {
    final group = groups[key]!;
    final sticky = group.where((item) => timed.isActive('sticky', item)).toSet();
    if (sticky.isNotEmpty) {
      for (final item in group) {
        if (!sticky.contains(item)) remove(item, 'group-sticky');
      }
      stickyGroups.add(key);
    }
    // ST also removes sticky entries if they are simultaneously on cooldown.
    // This group-specific behavior intentionally differs from candidate filtering.
    for (final item in group) {
      if (timed.isActive('cooldown', item)) remove(item, 'group-cooldown');
    }
    for (final item in group) {
      if (timed.isActive('delay', item)) remove(item, 'group-delay');
    }
  }
  // Scoring is pure: it expands no macros and draws no random values. Resolve
  // each needed entry before pruning groups so an undecidable entry cannot
  // first defeat another candidate in an overlapping group. The ordinary ST
  // splice(-1) behavior below is retained only for ordinary group decisions.
  final scoreByEntry = <_RuntimeEntry, int>{};
  for (final key in _objectKeys(groups.keys)) {
    final group = groups[key]!;
    if (stickyGroups.contains(key)) continue;
    if (!input.settings.useGroupScoring && !group.any((item) => item.entry.useGroupScoring == true)) continue;
    for (final item in group) {
      if (scoreByEntry.containsKey(item) || buffer.skippedEntries.contains(item.entry.identity)) continue;
      try {
        scoreByEntry[item] = await buffer.score(item.entry, phase, scanDepth: item.decorators.scanDepth);
        buffer.checkCancelled();
      } on _IndeterminateWorldInfoEntry {
        // The diagnostic and whole-evaluation skip were recorded by buffer.
      }
    }
  }
  candidates.removeWhere((item) => buffer.skippedEntries.contains(item.entry.identity));
  for (final group in groups.values) {
    group.removeWhere((item) => buffer.skippedEntries.contains(item.entry.identity));
  }
  for (final key in _objectKeys(groups.keys)) {
    final group = groups[key]!;
    if (stickyGroups.contains(key)) continue;
    if (!input.settings.useGroupScoring && !group.any((item) => item.entry.useGroupScoring == true)) continue;
    if (group.isEmpty) continue;
    final scores = [for (final item in group) scoreByEntry[item]!];
    final maximum = scores.reduce(math.max);
    for (var index = 0; index < group.length; index++) {
      if ((group[index].entry.useGroupScoring ?? input.settings.useGroupScoring) && scores[index] < maximum) {
        remove(group[index], 'group-score');
        group.removeAt(index);
        scores.removeAt(index);
        index--;
      }
    }
  }
  for (final key in _objectKeys(groups.keys)) {
    final group = groups[key]!;
    if (stickyGroups.contains(key)) continue;
    if (activated.any((hit) => hit.entry.group == key)) {
      for (final item in group) {
        remove(item, 'group-already-activated');
      }
      continue;
    }
    if (group.length <= 1) continue;
    final priority = _stableSort(
      group.where((item) => item.entry.groupOverride).toList(),
      (a, b) => _compareWorldOrder(a.entry.order, b.entry.order),
    );
    _RuntimeEntry? winner;
    if (priority.isNotEmpty) {
      winner = priority.first;
    } else {
      // ST accumulates both totals as Number; native integer sums can wrap.
      final weight = group.fold<double>(0.0, (sum, item) => sum + item.entry.groupWeight);
      final roll = _random(input) * weight;
      var current = 0.0;
      for (final item in group) {
        current += item.entry.groupWeight;
        if (roll <= current) {
          winner = item;
          break;
        }
      }
    }
    if (winner != null) {
      for (final item in group) {
        if (!identical(item, winner)) remove(item, priority.isNotEmpty ? 'group-override' : 'group-weight');
      }
    }
  }
}

/// The same effective book selection and insertion order used by evaluation.
/// This keeps native duplicate uids visible so callers can diagnose ambiguity;
/// V3 duplicate ids have already been resolved by [WorldInfoBook]. No macros,
/// conditions or regexes are evaluated to construct this immutable view.
List<WorldInfoEntry> worldInfoExecutionEntries(
  List<WorldInfoBook> books, {
  WorldInfoStrategy strategy = WorldInfoStrategy.evenly,
}) => List.unmodifiable(_sortedEntries(books, strategy));

List<WorldInfoEntry> _sortedEntries(List<WorldInfoBook> books, WorldInfoStrategy strategy) {
  // Loading deduplicates by book identity before applying insertion priorities.
  final bySource = {for (final source in WorldInfoSource.values) source: <WorldInfoEntry>[]};
  final seen = <String>{};
  for (final source in [
    WorldInfoSource.global,
    WorldInfoSource.chat,
    WorldInfoSource.persona,
    WorldInfoSource.character,
    WorldInfoSource.memory,
  ]) {
    for (final book in books.where((book) => book.source == source)) {
      if (seen.add(book.id)) bySource[source]!.addAll(book.entries);
    }
  }
  List<WorldInfoEntry> sort(List<WorldInfoEntry> values) =>
      _stableSort(values, (a, b) => _compareWorldOrder(a.order, b.order));
  final global = bySource[WorldInfoSource.global]!;
  final character = [...bySource[WorldInfoSource.character]!, ...bySource[WorldInfoSource.memory]!];
  final rest = switch (strategy) {
    WorldInfoStrategy.evenly => sort([...global, ...character]),
    WorldInfoStrategy.characterFirst => [...sort(character), ...sort(global)],
    WorldInfoStrategy.globalFirst => [...sort(global), ...sort(character)],
  };
  return [...sort(bySource[WorldInfoSource.chat]!), ...sort(bySource[WorldInfoSource.persona]!), ...rest];
}

bool _characterAllowed(WorldInfoEntry entry, WorldInfoInput input) {
  final filter = entry._fields['characterFilter'];
  if (filter is! Map<String, Object?>) return true;
  final exclude = filter['isExclude'] == true;
  final names = _strings(filter['names']);
  if (names.isNotEmpty && names.contains(input.characterName) == exclude) return false;
  final tags = _strings(filter['tags']);
  return tags.isEmpty || input.characterTags == null || input.characterTags!.any(tags.contains) != exclude;
}

Map<String, Object?> _convertCharacterEntry(Map<String, Object?> raw, int index) {
  final extensions = _object(raw['extensions']);
  // Property insertion order is ST's template order. It participates in timer hashes.
  final result = <String, Object?>{
    'key': <Object?>[],
    'keysecondary': <Object?>[],
    'comment': '',
    'content': '',
    'constant': false,
    'vectorized': false,
    'selective': true,
    'selectiveLogic': 0,
    'addMemo': false,
    'order': 100,
    'position': 0,
    'disable': false,
    'ignoreBudget': false,
    'excludeRecursion': false,
    'preventRecursion': false,
    'matchPersonaDescription': false,
    'matchCharacterDescription': false,
    'matchCharacterPersonality': false,
    'matchCharacterDepthPrompt': false,
    'matchScenario': false,
    'matchCreatorNotes': false,
    'delayUntilRecursion': 0,
    'probability': 100,
    'useProbability': true,
    'depth': 4,
    'outletName': '',
    'group': '',
    'groupOverride': false,
    'groupWeight': 100,
    'scanDepth': null,
    'caseSensitive': null,
    'matchWholeWords': null,
    'useGroupScoring': null,
    'automationId': '',
    'role': 0,
    'sticky': null,
    'cooldown': null,
    'delay': null,
    'triggers': <Object?>[],
  };
  result.addAll({
    'uid': raw.containsKey('id') ? raw['id'] : index,
    'key': raw['keys'],
    'keysecondary': raw['secondary_keys'] ?? <Object?>[],
    'comment': raw['comment'] ?? '',
    'content': raw['content'],
    'constant': raw['constant'] ?? false,
    'selective': raw['selective'] ?? false,
    'order': raw['insertion_order'],
    'position': extensions['position'] ?? (raw['position'] == 'before_char' ? 0 : 1),
    'excludeRecursion': extensions['exclude_recursion'] ?? false,
    'preventRecursion': extensions['prevent_recursion'] ?? false,
    'delayUntilRecursion': extensions['delay_until_recursion'] ?? false,
    'disable': raw['enabled'] != true,
    'addMemo': _truthy(raw['comment']),
    'displayIndex': extensions['display_index'] ?? index,
    'probability': extensions['probability'] ?? 100,
    'useProbability': extensions['useProbability'] ?? true,
    'depth': extensions['depth'] ?? 4,
    'selectiveLogic': extensions['selectiveLogic'] ?? 0,
    'outletName': extensions['outlet_name'] ?? '',
    'group': extensions['group'] ?? '',
    'groupOverride': extensions['group_override'] ?? false,
    'groupWeight': extensions['group_weight'] ?? 100,
    'scanDepth': extensions['scan_depth'],
    'caseSensitive': extensions['case_sensitive'],
    'matchWholeWords': extensions['match_whole_words'],
    'useGroupScoring': extensions['use_group_scoring'],
    'automationId': extensions['automation_id'] ?? '',
    'role': extensions['role'] ?? 0,
    'vectorized': extensions['vectorized'] ?? false,
    'sticky': extensions['sticky'],
    'cooldown': extensions['cooldown'],
    'delay': extensions['delay'],
    'matchPersonaDescription': extensions['match_persona_description'] ?? false,
    'matchCharacterDescription': extensions['match_character_description'] ?? false,
    'matchCharacterPersonality': extensions['match_character_personality'] ?? false,
    'matchCharacterDepthPrompt': extensions['match_character_depth_prompt'] ?? false,
    'matchScenario': extensions['match_scenario'] ?? false,
    'matchCreatorNotes': extensions['match_creator_notes'] ?? false,
    'extensions': extensions,
    'triggers': extensions['triggers'] ?? <Object?>[],
    'ignoreBudget': extensions['ignore_budget'] ?? false,
  });
  // JSON.stringify omits undefined assignments in converted incomplete cards.
  for (final pair in [('keys', 'key'), ('insertion_order', 'order')]) {
    if (!raw.containsKey(pair.$1)) result.remove(pair.$2);
  }
  return result;
}

// ST subtraction treats signed zeros as a tie; order getters admit only finite numbers.
int _compareWorldOrder(num a, num b) => a == b ? 0 : b.compareTo(a);

List<T> _stableSort<T>(List<T> items, int Function(T, T) compare) {
  final indexed = [for (var index = 0; index < items.length; index++) (index, items[index])];
  indexed.sort((a, b) {
    final result = compare(a.$2, b.$2);
    return result == 0 ? a.$1.compareTo(b.$1) : result;
  });
  return [for (final item in indexed) item.$2];
}

/// JavaScript Object.keys enumerates array-index keys before other keys.
List<String> _objectKeys(Iterable<String> keys) {
  final indexes = <int>[];
  final others = <String>[];
  for (final key in keys) {
    final value = int.tryParse(key);
    if (value != null && value >= 0 && value < 4294967295 && value.toString() == key) {
      indexes.add(value);
    } else {
      others.add(key);
    }
  }
  indexes.sort();
  return [...indexes.map((value) => '$value'), ...others];
}

int _tokens(WorldInfoInput input, String text) {
  input.checkCancelled?.call();
  final count = input.tokenCount(text);
  input.checkCancelled?.call();
  if (count < 0) throw ArgumentError.value(count, 'tokenCount', 'Must return a non-negative count.');
  return count;
}

double _random(WorldInfoInput input) {
  input.checkCancelled?.call();
  final value = input.random();
  input.checkCancelled?.call();
  if (!value.isFinite || value < 0 || value >= 1) {
    throw ArgumentError.value(value, 'random', 'Must return 0 <= value < 1.');
  }
  return value;
}

String _identity(String value) => value;
String _string(Object? value) => value is String ? value : '';
num? _number(Object? value) => value is num && value.isFinite ? value : null;
int? _integer(Object? value) => _number(value)?.toInt();
bool? _boolean(Object? value) => value is bool ? value : null;
List<String> _strings(Object? value) => value is List<Object?> ? value.whereType<String>().toList() : [];
String _id(Object value) => _jsString(value);
