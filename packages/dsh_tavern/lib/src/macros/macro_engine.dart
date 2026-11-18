// Port of SillyTavern 1.19.0's new macro engine and common definitions.
// Source: https://github.com/SillyTavern/SillyTavern
// Commit: 7e8663cd9c184a550b37238218bdd32c6efc68e9 (AGPL-3.0).
// The deterministic PRNG below also carries David Bau's MIT notice.
import 'dart:convert';
import 'dart:math' as math;

import 'package:yaml_edit/yaml_edit.dart';

import '../js_string.dart';

part 'legacy_macro_engine.dart';
part 'message_variable_macros.dart';
part 'script_macro_adapter.dart';

/// A message on the active chat path. Message ids are indices in this path.
class MacroMessage {
  const MacroMessage({
    required this.text,
    this.isUser = false,
    this.isSystem = false,
    this.swipeId,
    this.swipeCount,
    this.swipeIdIsNull = false,
    this.sentAt,
  });

  final String text;
  final bool isUser;
  final bool isSystem;
  final int? swipeId;
  final int? swipeCount;

  /// Distinguishes an explicit ST null from an absent swipe_id for legacy
  /// currentSwipeId. Ignored when [swipeId] is present, and by [MacroEngine].
  final bool swipeIdIsNull;
  final DateTime? sentAt;
}

/// Detached history inputs for display. Positions retain the full physical
/// path's indices; only messages actually read by history macros need bodies.
class MacroHistorySnapshot {
  const MacroHistorySnapshot({required this.length, this.last, this.user, this.character, this.previousUser});
  final int length;
  final ({int index, MacroMessage message})? last;
  final ({int index, MacroMessage message})? user;
  final ({int index, MacroMessage message})? character;
  final MacroMessage? previousUser;

  ({int index, MacroMessage message})? latest({bool? isUser}) => isUser == null
      ? last
      : isUser
      ? user
      : character;
}

/// Explicit environment for a single turn; no globals or I/O are consulted.
///
/// Variable maps are retained by reference and mutated synchronously. The
/// caller owns persistence. [card] is the character card's raw data object.
/// [MacroEngine] expands its fields lazily; [LegacyMacroEngine] prepares all
/// fields eagerly. Character-field/value caches belong to a single expand call.
/// [replaceCharacterCard] implements ST's baseChatReplace mode: when false,
/// new character-field macros return empty text; legacy ones remain literal.
/// Names and [original] are independent of that switch.
///
/// Supply [now], [timeZoneOffset], [locale], and [random] for reproducibility.
/// Localized date formats and relative time support en and zh-cn. A random
/// callback must return a finite number in [0, 1). Pick has its own ST PRNG.
class MacroContext {
  MacroContext({
    Map<String, Object?>? localVariables,
    Map<String, Object?>? globalVariables,
    this.messageVariables,
    this.messageVariablesExists = false,
    this.userName = '',
    String? charName,
    String? group,
    String? groupNotMuted,
    String? notChar,
    this.card = const {},
    this.replaceCharacterCard = true,
    this.preferCharacterPrompt = true,
    this.preferCharacterJailbreak = true,
    this.collapseNewlines = false,
    this.systemPromptOverride,
    this.scenarioOverride,
    this.mesExamplesOverride,
    this.persona = '',
    this.history = const [],
    this.historySnapshot,
    this.model = '',
    this.input = '',
    this.maxContext = 0,
    this.maxResponse = 0,
    int? maxPrompt,
    this.firstIncludedMessageId,
    this.firstDisplayedMessageId,
    this.lastGenerationType = '',
    this.extensions = const {},
    this.outlets = const {},
    this.isMobile = false,
    this.original,
    DateTime? now,
    Duration? timeZoneOffset,
    this.locale = 'en',
    double Function()? random,
    this.chatId = '',
    num? chatIdHash,
    this.onChatIdHash,
    this.pickRerollSeed,
    this.onCharacterDependency,
  }) : localVariables = localVariables ?? <String, Object?>{},
       globalVariables = globalVariables ?? <String, Object?>{},
       charName = charName ?? _cardName(card),
       group = group ?? charName ?? _cardName(card),
       groupNotMuted = groupNotMuted ?? group ?? charName ?? _cardName(card),
       _charNameFromCard = charName == null,
       _groupFromCard = group == null && charName == null,
       _groupNotMutedFromCard = groupNotMuted == null && group == null && charName == null,
       notChar = notChar ?? userName,
       maxPrompt = maxPrompt ?? maxContext - maxResponse,
       now = now ?? DateTime.now(),
       timeZoneOffset = timeZoneOffset ?? (now ?? DateTime.now()).timeZoneOffset,
       random = random ?? math.Random.secure().nextDouble,
       chatIdHash = chatIdHash ?? MacroEngine.stringHash(chatId);

  final Map<String, Object?> localVariables;
  final Map<String, Object?> globalVariables;

  /// The message-variable carrier captured by the caller for this expansion.
  /// Presence is separate from null. A missing or non-object carrier leaves
  /// message-variable macros unresolved; an existing nested null is a value.
  /// The reader never queries storage or mutates this caller-owned snapshot.
  final Object? messageVariables;
  final bool messageVariablesExists;
  final String userName;
  final String charName;
  final String group;
  final String groupNotMuted;
  final bool _charNameFromCard;
  final bool _groupFromCard;
  final bool _groupNotMutedFromCard;
  final String notChar;
  final Map<String, Object?> card;
  final bool replaceCharacterCard;
  final bool preferCharacterPrompt;
  final bool preferCharacterJailbreak;
  final bool collapseNewlines;
  final String? systemPromptOverride;
  final String? scenarioOverride;
  final String? mesExamplesOverride;
  final String persona;
  final List<MacroMessage> history;
  final MacroHistorySnapshot? historySnapshot;
  int get _historyLength => historySnapshot?.length ?? history.length;
  MacroMessage? get _historyLast => historySnapshot != null ? historySnapshot!.last?.message : history.lastOrNull;
  final String model;
  final String input;
  final int maxContext;
  final int maxResponse;
  final int maxPrompt;
  final int? firstIncludedMessageId;
  final int? firstDisplayedMessageId;
  final String lastGenerationType;
  final Set<String> extensions;
  final Map<String, String> outlets;
  final bool isMobile;
  final String? original;
  final DateTime now;
  final Duration timeZoneOffset;
  final String locale;
  final double Function() random;

  /// Raw ST chat identity, retained for the legacy engine's falsy cached hash
  /// fallback. The new engine continues to honor an explicitly supplied zero.
  final String chatId;
  final num chatIdHash;

  /// Observes the hash used at ST's getChatIdHash call sites. The new engine
  /// calls this for each evaluated pick with a nonempty list; the legacy
  /// engine calls it while preparing every nonempty expansion's pick pass,
  /// even if that expansion has no pick. Internal card expansions participate
  /// in source order. This does not mutate the context: the caller decides
  /// whether to persist the value and provide it to later contexts.
  final void Function(num)? onChatIdHash;
  final Object? pickRerollSeed;

  /// Observes a character source actually consumed by a macro: `name` or a
  /// card-field key (`charDepthPrompt` names the nested depth prompt). Supplied
  /// names, group lists, per-call constants and selected settings overrides do
  /// not read that source. Legacy eager field preparation alone is not a use;
  /// macros executed inside a prepared field still report their own reads.
  /// An observer failure escapes compatibility fallback as its original error.
  /// Omit this hook to retain ordinary native macro behavior.
  final void Function(String)? onCharacterDependency;

  void _observeCharacterDependency(String field) {
    final observer = onCharacterDependency;
    if (observer == null) return;
    try {
      observer(field);
    } catch (error, stack) {
      throw _MacroDependencyFailure(error, stack);
    }
  }
}

// Keep a caller's dependency failure distinguishable from an ordinary invalid
// macro or post-process failure while it crosses compatibility catch blocks.
class _MacroDependencyFailure implements Exception {
  const _MacroDependencyFailure(this.error, this.stack);
  final Object error;
  final StackTrace stack;
}

/// Synchronous AST-based new-macro expansion, with lazy conditional branches.
class MacroEngine {
  const MacroEngine();

  /// Expands one document. [postProcess] runs on each successfully resolved
  /// ordinary macro, including nested calls, before insertion into the text.
  /// Unknown calls, invalid calls and variable shorthand bypass it. If the
  /// hook throws, the successful macro result is kept. A null hook result
  /// becomes empty text; other JSON-owned values use JavaScript ToString.
  /// Internal base expansion of character fields does not inherit the hook.
  /// [replaceCharacterCard] and [characterOverride] apply only to this call.
  /// The latter supplies char/group/groupNotMuted, including nested card
  /// preparation, without changing the shared context or its notChar value.
  String expand(
    String text,
    MacroContext context, {
    Map<String, String> overrides = const {},
    Object? Function(Object?)? postProcess,
    bool? replaceCharacterCard,
    String? characterOverride,
  }) {
    try {
      return _Evaluation(
        context,
        text,
        overrides,
        postProcess: postProcess,
        replaceCharacterCard: replaceCharacterCard,
        characterOverride: characterOverride,
      ).evaluate(text);
    } on _MacroDependencyFailure catch (failure) {
      Error.throwWithStackTrace(failure.error, failure.stack);
    }
  }

  /// ST utils.js getStringHash (cyrb53), including UTF-16 code-unit iteration.
  static int stringHash(String text, [int seed = 0]) {
    const mask = 0xffffffff;
    var h1 = (0xdeadbeef ^ seed) & mask;
    var h2 = (0x41c6ce57 ^ seed) & mask;
    for (final code in text.codeUnits) {
      h1 = ((h1 ^ code) * 2654435761) & mask;
      h2 = ((h2 ^ code) * 1597334677) & mask;
    }
    h1 = (((h1 ^ (h1 >>> 16)) * 2246822507) ^ ((h2 ^ (h2 >>> 13)) * 3266489909)) & mask;
    h2 = (((h2 ^ (h2 >>> 16)) * 2246822507) ^ ((h1 ^ (h1 >>> 13)) * 3266489909)) & mask;
    return 4294967296 * (h2 & 2097151) + h1;
  }
}

String _stringField(Map<String, Object?> map, String key) => map[key] is String ? map[key]! as String : '';

String _cardName(Map<String, Object?> card) {
  final nickname = _stringField(card, 'nickname');
  return nickname.isEmpty ? _stringField(card, 'name') : nickname;
}

const _aliases = {
  'charifnotgroup': 'group',
  'description': 'chardescription',
  'personality': 'charpersonality',
  'scenario': 'charscenario',
  'creatornotes': 'charcreatornotes',
  'greeting': 'charfirstmessage',
  'version': 'charversion',
  'char_version': 'charversion',
  'maxprompttokens': 'maxprompt',
  'maxcontexttokens': 'maxcontext',
  'maxresponsetokens': 'maxresponse',
  'comment': '//',
  'idle_duration': 'idleduration',
  'varexists': 'hasvar',
  'flushvar': 'deletevar',
  'setvarindex': 'setvarkey',
  'getvarindex': 'getvarkey',
  'globalvarexists': 'hasglobalvar',
  'flushglobalvar': 'deleteglobalvar',
  'setglobalvarindex': 'setglobalvarkey',
  'getglobalvarindex': 'getglobalvarkey',
};

String _canonical(String name) {
  final lower = trimJsWhitespace(name).toLowerCase();
  return _aliases[lower] ?? lower;
}

typedef _Spec = ({int min, int max, bool list});

_Spec? _spec(String name) {
  switch (_canonical(name)) {
    case 'space':
    case 'newline':
    case 'trim':
    case 'time':
    case 'charfirstmessage':
      return (min: 0, max: 1, list: false);
    case 'random':
    case 'pick':
      return (min: 0, max: 0, list: true);
    case 'if':
    case 'setvar':
    case 'setglobalvar':
    case 'addvar':
    case 'addglobalvar':
    case 'getvarkey':
    case 'getglobalvarkey':
    case 'timediff':
      return (min: 2, max: 2, list: false);
    case 'setvarkey':
    case 'setglobalvarkey':
      return (min: 3, max: 3, list: false);
    case 'reverse':
    case '//':
    case 'roll':
    case 'banned':
    case 'outlet':
    case 'datetimeformat':
    case 'hasextension':
    case 'getvar':
    case 'getglobalvar':
    case 'get_message_variable':
    case 'format_message_variable':
    case 'incvar':
    case 'incglobalvar':
    case 'decvar':
    case 'decglobalvar':
    case 'hasvar':
    case 'hasglobalvar':
    case 'deletevar':
    case 'deleteglobalvar':
      return (min: 1, max: 1, list: false);
    case 'user':
    case 'char':
    case 'group':
    case 'groupnotmuted':
    case 'notchar':
    case 'charprompt':
    case 'charinstruction':
    case 'chardescription':
    case 'charpersonality':
    case 'charscenario':
    case 'persona':
    case 'mesexamples':
    case 'mesexamplesraw':
    case 'chardepthprompt':
    case 'charcreatornotes':
    case 'charversion':
    case 'model':
    case 'original':
    case 'ismobile':
    case 'lastmessage':
    case 'lastmessageid':
    case 'lastusermessage':
    case 'lastcharmessage':
    case 'firstincludedmessageid':
    case 'firstdisplayedmessageid':
    case 'lastswipeid':
    case 'currentswipeid':
    case 'noop':
    case 'else':
    case 'input':
    case 'maxprompt':
    case 'maxcontext':
    case 'maxresponse':
    case 'date':
    case 'weekday':
    case 'isotime':
    case 'isodate':
    case 'idleduration':
    case 'lastgenerationtype':
      return (min: 0, max: 0, list: false);
    default:
      return null;
  }
}

class _Slice {
  const _Slice(this.start, this.end);
  final int start;
  final int end;
}

class _Call {
  _Call(
    this.start,
    this.end,
    this.name,
    this.args, {
    this.closing = false,
    this.preserveWhitespace = false,
    this.variableScope,
    this.variableOperator,
  });
  final int start;
  final int end;
  final String name;
  final List<_Slice> args;
  final bool closing;
  final bool preserveWhitespace;
  final String? variableScope;
  final String? variableOperator;
  _Slice? body;
  int? closingEnd;
  bool keepRaw = false;

  bool get acceptsBody {
    if (variableScope != null || closing || name.isEmpty) return false;
    final spec = _spec(name);
    return spec == null || (!spec.list && args.length + 1 >= spec.min && args.length < spec.max);
  }
}

class _Document {
  const _Document(this.text, this.calls);
  final String text;
  final List<_Call> calls;
}

/// Keeps source offsets in UTF-16 units, like Chevrotain and JavaScript.
class _Parser {
  _Parser(this.text);
  final String text;
  static final _space = RegExp(r'\s');
  static final _name = RegExp(r'[a-zA-Z][\w-]*');
  static final _variableName = RegExp(r'[a-zA-Z](?:[\w-]*\w)?');

  _Document parse({bool scopes = true}) {
    final calls = <_Call>[];
    var i = 0;
    while (i + 1 < text.length) {
      if (!text.startsWith('{{', i)) {
        i++;
        continue;
      }
      // Chevrotain treats surplus opening braces as ordinary text.
      if (text.startsWith('{{{', i)) {
        i++;
        continue;
      }
      final end = _macroEnd(i);
      if (end == null) {
        i += 2;
        continue;
      }
      calls.add(_readCall(i, end));
      i = end;
    }
    if (scopes) _pairScopes(calls);
    return _Document(text, calls);
  }

  int? _macroEnd(int start) {
    var depth = 1;
    for (var i = start + 2; i + 1 < text.length;) {
      if (text.startsWith('{{', i)) {
        depth++;
        i += 2;
      } else if (text.startsWith('}}', i)) {
        depth--;
        i += 2;
        if (depth == 0) return i;
      } else {
        i++;
      }
    }
    return null;
  }

  int _skipSpace(int position, int end) {
    while (position < end && _space.hasMatch(text[position])) {
      position++;
    }
    return position;
  }

  _Slice _slice(int start, int end) {
    start = _skipSpace(start, end);
    while (end > start && _space.hasMatch(text[end - 1])) {
      end--;
    }
    return _Slice(start, end);
  }

  _Call _invalid(int start, int end) => _Call(start, end, '', [_slice(start + 2, end - 2)]);

  _Call _readCall(int start, int end) {
    final innerEnd = end - 2;
    var i = _skipSpace(start + 2, innerEnd);
    var closing = false;
    var preserve = false;
    while (i < innerEnd && '!?~#/>'.contains(text[i]) && !text.startsWith('//', i)) {
      closing = closing || text[i] == '/';
      preserve = preserve || text[i] == '#';
      i = _skipSpace(i + 1, innerEnd);
    }
    if (i >= innerEnd) return _invalid(start, end);
    if (text[i] == '.' || text[i] == r'$') {
      final scope = text[i++];
      i = _skipSpace(i, innerEnd);
      final match = _variableName.matchAsPrefix(text, i);
      if (match == null || match.end > innerEnd) return _invalid(start, end);
      final name = match.group(0)!;
      i = _skipSpace(match.end, innerEnd);
      String? operator;
      if (i < innerEnd) {
        for (final candidate in const [
          '??=',
          '||=',
          '++',
          '--',
          '??',
          '||',
          '+=',
          '-=',
          '==',
          '!=',
          '>=',
          '<=',
          '>',
          '<',
          '=',
        ]) {
          if (text.startsWith(candidate, i)) {
            operator = candidate;
            i += candidate.length;
            break;
          }
        }
        if (operator == null) return _invalid(start, end);
      }
      final value = _slice(i, innerEnd);
      if ((operator == '++' || operator == '--') && value.start < value.end) {
        return _invalid(start, end);
      }
      return _Call(start, end, name, operator == null ? [] : [value], variableScope: scope, variableOperator: operator);
    }
    String name;
    if (text.startsWith('//', i)) {
      name = '//';
      i += 2;
    } else {
      final match = _name.matchAsPrefix(text, i);
      if (match == null || match.end > innerEnd) return _invalid(start, end);
      name = match.group(0)!;
      i = match.end;
    }
    final args = <_Slice>[];
    if (i < innerEnd) {
      final first = i;
      i = _skipSpace(i, innerEnd);
      if (text.startsWith('::', i)) {
        i += 2;
        var argStart = i;
        while (i < innerEnd) {
          if (text.startsWith('{{', i)) {
            final nestedEnd = _macroEnd(i);
            if (nestedEnd != null && nestedEnd <= innerEnd) {
              i = nestedEnd;
              continue;
            }
          }
          if (text.startsWith('::', i)) {
            args.add(_slice(argStart, i));
            i += 2;
            argStart = i;
          } else {
            i++;
          }
        }
        args.add(_slice(argStart, innerEnd));
      } else if (i < innerEnd && text[i] == ':') {
        args.add(_slice(i + 1, innerEnd));
      } else if (i < innerEnd && (i > first || name == '//' || text[i] == '|')) {
        args.add(_slice(i, innerEnd));
      } else if (i < innerEnd) {
        return _invalid(start, end);
      }
    }
    if (name == '//' && args.isNotEmpty && text.substring(args.first.start, args.first.end).startsWith('/')) {
      closing = true;
    }
    return _Call(start, end, name, args, closing: closing, preserveWhitespace: preserve);
  }

  void _pairScopes(List<_Call> calls) {
    // Lists without closing calls need no pairing; avoid quadratic scans.
    if (!calls.any((call) => call.closing)) return;
    final matched = <int>{};
    for (var i = 0; i < calls.length; i++) {
      final open = calls[i];
      if (matched.contains(i)) continue;
      if (open.closing) {
        open.keepRaw = true;
        continue;
      }
      if (open.variableScope != null || open.name.isEmpty) continue;
      var depth = 0;
      for (var j = i + 1; j < calls.length; j++) {
        if (matched.contains(j)) continue;
        final candidate = calls[j];
        if (candidate.name.toLowerCase() != open.name.toLowerCase()) continue;
        if (!candidate.closing && candidate.acceptsBody) {
          depth++;
        }
        if (!candidate.closing) continue;
        if (depth > 0) {
          depth--;
          continue;
        }
        if (open.acceptsBody) {
          open.body = _Slice(open.end, candidate.start);
          open.closingEnd = candidate.end;
          i = j;
        } else {
          open.keepRaw = true;
          candidate.keepRaw = true;
          matched.add(j);
        }
        break;
      }
    }
  }
}

const _elseMarker = '\u0000\u001fELSE\u001f\u0000';

// Grammar-only patterns are shared; match objects and evaluation state are not.
final _macroTimeUtcAlias = RegExp(r'{{time_(UTC[+-]\d+)}}', caseSensitive: false);
final _macroAngleNames = RegExp(r'<(USER|BOT|CHAR|GROUP|CHARIFNOTGROUP)>', caseSensitive: false);
final _macroEscapedBraces = RegExp(r'\\([{}])');
final _macroTrim = RegExp(r'(?:\r?\n)*{{trim}}(?:\r?\n)*', caseSensitive: false);
final _macroInversion = RegExp(r'^\s*!\s*');
final _macroVariableReference = RegExp(r'^([.$])([a-zA-Z](?:[\w-]*\w)?)$');
final _macroNewlines = RegExp(r'\n+');
final _macroDigits = RegExp(r'^\d+$');
final _macroDice = RegExp(r'^([1-9]\d*)?d([1-9]\d*)([+-]\d+)?$', caseSensitive: false);
final _macroUtcOffset = RegExp(r'^UTC([+-]\d+)$');
final _macroIntegerArgument = RegExp(r'^-?\d+$');
final _macroIndentation = RegExp(r'^[ \t]*');
final _macroLeadingWhitespace = RegExp(r'^\s+');
final _macroExampleStart = RegExp('<START>', caseSensitive: false);
final _macroBasedNumber = RegExp(r'^0([xbo])([0-9a-f]+)$', caseSensitive: false);
final _macroDecimalNumber = RegExp(r'^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$');
final _macroArrayIndex = RegExp(r'^(0|[1-9]\d*)$');
final _macroFractionalSeconds = RegExp(r'^S{1,9}$');
final _macroIsoDate = RegExp(
  r'^([+-]\d{6}|\d{4})(?:-?(\d{2})(?:-?(\d{2}))?)?'
  r'(?:[T ](\d{2})(?::?(\d{2}))?(?::?(\d{2}))?(?:[.,](\d+))?'
  r'(Z|[+-]\d{2}(?::?\d{2})?)?)?$',
  caseSensitive: false,
);
final _macroIsoUtcGap = RegExp(
  r'^((?:[+-]\d{6}|\d{4})(?:'
  r'-\d{2}-\d{2}[T ]\d{2}(?::\d{2}(?::\d{2}(?:[.,]\d+)?)?)?'
  r'|\d{4}[T ]\d{2}(?:\d{2}(?:\d{2}(?:[.,]\d+)?)?)?))\s+Z$',
);

class _Evaluation {
  _Evaluation(
    this.context,
    String original,
    Map<String, String> overrides, {
    bool? replaceCharacterCard,
    this.characterOverride,
    this.inheritOriginal = true,
    this.postProcess,
    this.scriptResolver,
  }) : contentHash = MacroEngine.stringHash(original),
       replaceCharacterCard = replaceCharacterCard ?? context.replaceCharacterCard,
       overrides = {for (final entry in overrides.entries) entry.key.toLowerCase(): entry.value};

  final MacroContext context;
  final int contentHash;
  final Map<String, String> overrides;
  final bool replaceCharacterCard;
  final String? characterOverride;
  final bool inheritOriginal;
  final Object? Function(Object?)? postProcess;
  final _ScriptMacroResolver? scriptResolver;
  final Map<String, String> _cardFields = {};
  List<String>? _alternateGreetings;
  bool _originalUsed = false;

  String _prepareText(String text) {
    text = text.replaceAllMapped(_macroTimeUtcAlias, (match) => '{{time::${match[1]}}}');
    const oldNames = {
      'user': 'user',
      'bot': 'char',
      'char': 'char',
      'group': 'group',
      'charifnotgroup': 'charIfNotGroup',
    };
    return text.replaceAllMapped(_macroAngleNames, (match) => '{{${oldNames[match[1]!.toLowerCase()]}}}');
  }

  String _finishText(String text) =>
      text.replaceAllMapped(_macroEscapedBraces, (m) => m[1]!).replaceAll(_macroTrim, '').replaceAll(_elseMarker, '');

  String evaluate(String text, {int offset = 0, bool processors = true, bool scopes = true}) {
    if (processors) text = _prepareText(text);
    final document = _Parser(text).parse(scopes: scopes);
    final output = StringBuffer();
    var cursor = 0;
    for (final call in document.calls) {
      if (call.start < cursor) continue;
      output.write(text.substring(cursor, call.start));
      output.write(_evaluateCall(document, call, offset));
      cursor = call.closingEnd ?? call.end;
    }
    output.write(text.substring(cursor));
    final result = output.toString();
    return processors ? _finishText(result) : result;
  }

  // Only a real scoped resolver result may introduce a private callable.
  // Ordinary macro outputs are String and can never be decoded into one.
  Object evaluateScript(String text) {
    text = _prepareText(text);
    final document = _Parser(text).parse();
    final parts = <Object>[];
    var output = StringBuffer();
    void flushText() {
      final result = _finishText(output.toString());
      if (result.isNotEmpty) parts.add(result);
      output = StringBuffer();
    }

    var cursor = 0;
    for (final call in document.calls) {
      if (call.start < cursor) continue;
      output.write(text.substring(cursor, call.start));
      final result = _evaluateCallValue(document, call, 0);
      if (result is _ScriptMacroValue) {
        flushText();
        parts.add(result.callable!);
      } else {
        output.write(result);
      }
      cursor = call.closingEnd ?? call.end;
    }
    output.write(text.substring(cursor));
    flushText();
    if (parts.isEmpty) return '';
    return parts.length == 1 ? parts.single : parts;
  }

  String _evaluateCall(_Document document, _Call call, int offset) {
    final value = _evaluateCallValue(document, call, offset);
    return value is _ScriptMacroValue ? value.text : value as String;
  }

  Object _evaluateCallValue(_Document document, _Call call, int offset) {
    final text = document.text;
    if (call.keepRaw || call.closing) {
      return text.substring(call.start, call.end);
    }
    if (call.variableScope != null) {
      return _variableExpression(document, call, offset);
    }
    final name = _canonical(call.name);
    final delayed = name == 'if';
    final slices = [...call.args, if (call.body != null) call.body!];
    final arguments = <String>[];
    for (var i = 0; i < slices.length; i++) {
      final slice = slices[i];
      var value = text.substring(slice.start, slice.end);
      if (!delayed) {
        value = evaluate(value, offset: offset + slice.start, processors: false);
        if (call.body == slice && !call.preserveWhitespace) {
          value = _trimScoped(value);
        }
      }
      arguments.add(value);
    }

    // Preserve separators and source whitespace, replacing only argument
    // ranges. This also mirrors ST's rawInner reconstruction for unknown
    // scoped calls (including its unusual closing-brace fallback).
    final raw = StringBuffer('{{');
    var cursor = call.start + 2;
    for (var i = 0; i < slices.length; i++) {
      final slice = slices[i];
      if (slice == call.body && slice.start == slice.end) continue;
      if (slice.start > cursor) raw.write(text.substring(cursor, slice.start));
      raw.write(arguments[i]);
      cursor = slice.end;
    }
    if (cursor < call.end - 2) raw.write(text.substring(cursor, call.end - 2));
    raw.write('}}');
    final fallback = raw.toString();
    if (call.name.isEmpty) return fallback;
    final scripted = scriptResolver?.call(call.name, arguments);
    if (scripted != null) return scripted.callable == null ? scripted.text : scripted;
    final spec = _spec(name);
    if (name != 'original') {
      final override = overrides[call.name.toLowerCase()];
      if (override != null) return arguments.isEmpty ? _postProcess(override) : fallback;
    }
    if (spec == null || (!spec.list && (arguments.length < spec.min || arguments.length > spec.max))) {
      return fallback;
    }
    try {
      final result = _dispatch(name, arguments, call, offset + call.start);
      return result == null ? fallback : _postProcess(result);
    } on ArgumentError {
      return fallback;
    } on FormatException {
      return fallback;
    }
  }

  String _postProcess(String result) {
    final callback = postProcess;
    if (callback == null) return result;
    try {
      // MacroCstWalker coerces a hook's nullish result to the empty string.
      return _jsString(callback(result) ?? '');
    } on _MacroDependencyFailure {
      rethrow;
    } catch (_) {
      // ST catches postProcess separately from the macro handler. A failed
      // callback keeps the successful, unprocessed result and its effects.
      return result;
    }
  }

  String _variableExpression(_Document document, _Call call, int offset) {
    final vars = call.variableScope == '.' ? context.localVariables : context.globalVariables;
    String? cachedValue;
    String value() => cachedValue ??= call.args.isEmpty
        ? ''
        : trimJsWhitespace(
            evaluate(
              document.text.substring(call.args.first.start, call.args.first.end),
              offset: offset + call.args.first.start,
              processors: false,
              scopes: false,
            ),
          );
    final current = _getVariable(vars, call.name);
    switch (call.variableOperator) {
      case null:
        return _normalize(current);
      case '=':
        _setVariable(vars, call.name, value());
        return '';
      case '++':
        return _normalize(_addVariable(vars, call.name, 1));
      case '--':
        return _normalize(_addVariable(vars, call.name, -1));
      case '+=':
        _addVariable(vars, call.name, value());
        return '';
      case '-=':
        final amount = _number(value());
        if (!amount.isNaN) _addVariable(vars, call.name, -amount);
        return '';
      case '||':
        return _falseValue(current) ? value() : _normalize(current);
      case '??':
        return vars.containsKey(call.name) ? _normalize(current) : value();
      case '||=':
        if (!_falseValue(current)) return _normalize(current);
        _setVariable(vars, call.name, value());
        return value();
      case '??=':
        if (vars.containsKey(call.name)) return _normalize(current);
        _setVariable(vars, call.name, value());
        return value();
      case '==':
        return '${_normalize(current) == value()}';
      case '!=':
        return '${_normalize(current) != value()}';
      case '>':
        return '${_number(current) > _number(value())}';
      case '>=':
        return '${_number(current) >= _number(value())}';
      case '<':
        return '${_number(current) < _number(value())}';
      case '<=':
        return '${_number(current) <= _number(value())}';
      default:
        return document.text.substring(call.start, call.end);
    }
  }

  String _conditional(List<String> args, _Call call, int offset) {
    var condition = args[0];
    final inversion = _macroInversion;
    final inverted = inversion.hasMatch(condition);
    if (inverted) condition = condition.replaceFirst(inversion, '');
    condition = evaluate(condition, offset: offset);
    final variable = _macroVariableReference.firstMatch(condition);
    if (variable != null) {
      condition = _normalize(
        _getVariable(variable[1] == '.' ? context.localVariables : context.globalVariables, variable[2]!),
      );
    } else if (_spec(condition)?.min == 0) {
      condition = evaluate('{{$condition}}', offset: offset);
    }
    var falsy = condition.isEmpty || _falseBoolean(condition);
    if (inverted) falsy = !falsy;
    final content = args[1];
    var depth = 0;
    _Call? divider;
    for (final item in _Parser(content).parse(scopes: false).calls) {
      if (item.name == 'if' && !item.closing && item.args.length == 1) {
        depth++;
      } else if (item.name == 'if' && item.closing) {
        depth--;
      } else if (item.name == 'else' && depth == 0) {
        divider = item;
        break;
      }
    }
    if (falsy && divider == null) return '';
    final chosen = falsy ? content.substring(divider!.end) : content.substring(0, divider?.start ?? content.length);
    final result = evaluate(chosen, offset: offset);
    return call.preserveWhitespace ? result : _trimScoped(result);
  }

  String? _dispatch(String name, List<String> args, _Call call, int offset) {
    switch (name) {
      case 'user':
        return context.userName;
      case 'char':
        if (characterOverride == null && context._charNameFromCard) {
          context._observeCharacterDependency('name');
        }
        return characterOverride ?? context.charName;
      case 'group':
        if (characterOverride == null && context._groupFromCard) {
          context._observeCharacterDependency('name');
        }
        return characterOverride ?? context.group;
      case 'groupnotmuted':
        if (characterOverride == null && context._groupNotMutedFromCard) {
          context._observeCharacterDependency('name');
        }
        return characterOverride ?? context.groupNotMuted;
      case 'notchar':
        return context.notChar;
      case 'charprompt':
        return _cardField('system_prompt');
      case 'charinstruction':
        return _cardField('post_history_instructions');
      case 'chardescription':
        return _cardField('description');
      case 'charpersonality':
        return _cardField('personality');
      case 'charscenario':
        return _cardField('scenario');
      case 'persona':
        return _cardField('persona');
      case 'mesexamplesraw':
        return _cardField('mes_example');
      case 'mesexamples':
        return _examples(_cardField('mes_example'));
      case 'chardepthprompt':
        return _cardField('charDepthPrompt');
      case 'charcreatornotes':
        return _cardField('creator_notes');
      case 'charversion':
        return _cardField('character_version');
      case 'charfirstmessage':
        final rawIndex = args.isEmpty ? '0' : trimJsWhitespace(args[0]);
        if (!_macroIntegerArgument.hasMatch(rawIndex)) throw ArgumentError.value(rawIndex);
        // ST validates integer syntax, then uses Number without an int64 bound.
        // Out-of-range indexes still resolve the lazy alternatives below.
        final index = double.parse(rawIndex);
        if (index == 0) return _cardField('first_mes');
        if (!replaceCharacterCard) return '';
        final alternatives = _alternateGreetings ??= _resolveGreetings();
        return index > 0 && index <= alternatives.length ? alternatives[index.toInt() - 1] : '';
      case 'model':
        return context.model;
      case 'original':
        final original = overrides['original'] ?? (inheritOriginal ? context.original : null);
        if (original == null) return null;
        if (_originalUsed) return '';
        _originalUsed = true;
        return original;
      case 'ismobile':
        return '${context.isMobile}';
      case 'lastmessage':
        return _lastMessage()?.text ?? '';
      case 'lastmessageid':
        return _lastMessageIndex()?.toString() ?? '';
      case 'lastusermessage':
        return _lastMessage(user: true)?.text ?? '';
      case 'lastcharmessage':
        return _lastMessage(user: false)?.text ?? '';
      case 'firstincludedmessageid':
        return context.firstIncludedMessageId?.toString() ?? '';
      case 'firstdisplayedmessageid':
        return context.firstDisplayedMessageId?.toString() ?? '';
      case 'lastswipeid':
        return context._historyLast?.swipeCount?.toString() ?? '';
      case 'currentswipeid':
        final id = context._historyLast?.swipeId;
        return id == null ? '' : '${id + 1}';
      case 'space':
      case 'newline':
        final count = args.isEmpty ? 1 : _integerArgument(args[0]);
        if (count < 0) throw ArgumentError.value(count);
        return ''.padRight(count, name == 'space' ? ' ' : '\n');
      case 'noop':
        return '';
      case 'trim':
        return call.body == null ? '{{trim}}' : args[0];
      case 'if':
        return _conditional(args, call, offset);
      case 'else':
        return _elseMarker;
      case 'input':
        return context.input;
      case 'get_message_variable':
        return _messageVariableMacro(context, args[0]);
      case 'format_message_variable':
        return _messageVariableMacro(context, args[0], format: true);
      case 'maxprompt':
        return '${context.maxPrompt}';
      case 'maxcontext':
        return '${context.maxContext}';
      case 'maxresponse':
        return '${context.maxResponse}';
      case 'reverse':
        return String.fromCharCodes(args[0].runes.toList().reversed);
      case '//':
        return '';
      case 'roll':
        return _roll(args[0]);
      case 'random':
      case 'pick':
        final values = args.length == 1 ? _randomList(args[0]) : args;
        if (values.isEmpty) return '';
        double random;
        if (name == 'random') {
          random = context.random();
        } else {
          context.onChatIdHash?.call(context.chatIdHash);
          final seedParts = <Object>[
            context.chatIdHash,
            contentHash,
            offset,
            if (_truthy(context.pickRerollSeed)) context.pickRerollSeed!,
          ];
          final seed = MacroEngine.stringHash(seedParts.map(_jsString).join('-'));
          random = _SeedRandom('$seed').nextDouble();
        }
        if (!random.isFinite || random < 0 || random >= 1) {
          throw ArgumentError.value(random, 'random', 'Expected [0, 1)');
        }
        return values[(random * values.length).floor()];
      case 'outlet':
        return context.outlets[args[0]] ?? '';
      case 'banned':
        return ''; // Chat Completion has no textgen banned-word list.
      case 'hasextension':
        return '${context.extensions.contains(args[0])}';
      case 'lastgenerationtype':
        return context.lastGenerationType;
      case 'time':
      case 'date':
      case 'weekday':
      case 'isotime':
      case 'isodate':
      case 'datetimeformat':
      case 'idleduration':
      case 'timediff':
        return _time(name, args);
      default:
        return _variableMacro(name, args);
    }
  }

  String _baseCardValue(Object? raw) {
    final text = raw is String ? trimJsWhitespace(raw) : '';
    if (text.isEmpty) return '';
    var expanded = _Evaluation(
      context,
      text,
      const {},
      replaceCharacterCard: false,
      characterOverride: characterOverride,
      inheritOriginal: false,
    ).evaluate(text);
    if (context.collapseNewlines) expanded = expanded.replaceAll(_macroNewlines, '\n');
    return expanded.replaceAll('\r', '');
  }

  String _cardField(String key) {
    if (!replaceCharacterCard) return '';
    return _cardFields.putIfAbsent(key, () {
      if (key == 'persona') return _baseCardValue(context.persona);
      if (key == 'system_prompt') {
        if (!context.preferCharacterPrompt) return '';
        if (_truthy(context.systemPromptOverride)) return _baseCardValue(context.systemPromptOverride);
      }
      if (key == 'post_history_instructions' && !context.preferCharacterJailbreak) return '';
      if (key == 'scenario' && _truthy(context.scenarioOverride)) {
        return _baseCardValue(context.scenarioOverride);
      }
      if (key == 'mes_example' && _truthy(context.mesExamplesOverride)) {
        return _baseCardValue(context.mesExamplesOverride);
      }
      context._observeCharacterDependency(key);
      final card = context.card;
      if (key == 'character_version') return _stringField(card, key);
      if (key == 'charDepthPrompt') {
        final extensions = card['extensions'];
        final depth = extensions is Map<String, Object?> ? extensions['depth_prompt'] : null;
        return _baseCardValue(depth is Map<String, Object?> ? depth['prompt'] : null);
      }
      return _baseCardValue(card[key]);
    });
  }

  List<String> _resolveGreetings() {
    context._observeCharacterDependency('alternate_greetings');
    final raw = context.card['alternate_greetings'];
    return raw is List<Object?> ? raw.map(_baseCardValue).toList() : [];
  }

  String? _variableMacro(String name, List<String> args) {
    final global = name.contains('global');
    final vars = global ? context.globalVariables : context.localVariables;
    switch (name.replaceFirst('global', '')) {
      case 'getvar':
        return _normalize(_getVariable(vars, args[0]));
      case 'setvar':
        _setVariable(vars, args[0], args[1]);
        return '';
      case 'addvar':
        _addVariable(vars, args[0], args[1]);
        return '';
      case 'incvar':
        return _normalize(_addVariable(vars, args[0], 1));
      case 'decvar':
        return _normalize(_addVariable(vars, args[0], -1));
      case 'hasvar':
        return '${vars.containsKey(args[0])}';
      case 'deletevar':
        vars.remove(args[0]);
        return '';
      case 'getvarkey':
        return _normalize(_getVariable(vars, args[0], args[1]));
      case 'setvarkey':
        _setVariable(vars, args[0], args[2], args[1]);
        return '';
      default:
        return null;
    }
  }

  int? _lastMessageIndex({bool? user}) {
    final snapshot = context.historySnapshot;
    if (snapshot != null) return snapshot.latest(isUser: user)?.index;
    for (var i = context.history.length - 1; i >= 0; i--) {
      final message = context.history[i];
      if (message.swipeCount != null && message.swipeId != null && message.swipeId! >= message.swipeCount!) continue;
      if (user == null || (!message.isSystem && message.isUser == user)) return i;
    }
    return null;
  }

  MacroMessage? _lastMessage({bool? user}) {
    final snapshot = context.historySnapshot;
    if (snapshot != null) return snapshot.latest(isUser: user)?.message;
    final index = _lastMessageIndex(user: user);
    return index == null ? null : context.history[index];
  }

  String _roll(String formula) {
    if (_macroDigits.hasMatch(formula)) formula = '1d$formula';
    final match = _macroDice.firstMatch(formula);
    if (match == null) return '';
    final count = match[1] == null ? 1 : int.tryParse(match[1]!);
    final sides = int.tryParse(match[2]!);
    final modifier = match[3] == null ? 0 : int.tryParse(match[3]!);
    if (count == null || sides == null || modifier == null) return '';
    // Fixed ST 1.19.0 (7e8663cd) uses droll 0.2.1 (MIT):
    // https://github.com/thebinarypenguin/droll/blob/v0.2.1/droll.js
    // This tag supplied the semantics; npm tarball bytes were not compared.
    // Each die and the dice sum use binary64; add the modifier only once, last.
    final doubleSides = sides.toDouble();
    var total = 0.0;
    for (var i = 0; i < count; i++) {
      final random = context.random();
      if (!random.isFinite || random < 0 || random >= 1) {
        throw ArgumentError.value(random);
      }
      total += 1.0 + (random * doubleSides).floorToDouble();
    }
    return _numberString(total + modifier.toDouble());
  }

  String _time(String name, List<String> args) {
    final clock = _MacroClock(context.now, context.timeZoneOffset, context.locale);
    switch (name) {
      case 'idleduration':
        final snapshot = context.historySnapshot;
        if (snapshot != null) {
          final sentAt = snapshot.previousUser?.sentAt;
          return sentAt == null ? 'just now' : clock.humanize(context.now, sentAt);
        }
        var skip = true;
        for (final message in context.history.reversed) {
          if (message.isSystem) continue;
          if (skip) {
            skip = false;
            continue;
          }
          if (message.isUser) {
            final sentAt = message.sentAt;
            return sentAt == null ? 'just now' : clock.humanize(context.now, sentAt);
          }
        }
        return 'just now';
      case 'timediff':
        final left = clock.parse(args[0]);
        final right = clock.parse(args[1]);
        if (left == null || right == null) return 'Invalid date';
        return clock.humanize(left, right, suffix: true);
      case 'datetimeformat':
        return clock.format(args[0]);
      case 'date':
        return clock.format('LL');
      case 'weekday':
        return clock.format('dddd');
      case 'isotime':
        return clock.format('HH:mm');
      case 'isodate':
        return clock.format('YYYY-MM-DD');
      default:
        if (args.isNotEmpty) {
          final match = _macroUtcOffset.firstMatch(args[0]);
          final amount = match == null ? null : int.tryParse(match[1]!);
          if (amount != null) {
            final offset = Duration(minutes: amount.abs() < 16 ? amount * 60 : amount);
            return _MacroClock(context.now, offset, context.locale).format('LT');
          }
        }
        return clock.format('LT');
    }
  }
}

int _integerArgument(String value) {
  final trimmed = trimJsWhitespace(value);
  if (!_macroIntegerArgument.hasMatch(trimmed)) throw ArgumentError.value(value);
  return int.parse(trimmed);
}

String _trimScoped(String text) {
  final lines = text.split('\n');
  var indent = 0;
  for (final line in lines) {
    if (trimJsWhitespace(line).isNotEmpty) {
      indent = _macroIndentation.firstMatch(line)![0]!.length;
      break;
    }
  }
  if (indent == 0) return trimJsWhitespace(text);
  return trimJsWhitespace(
    lines
        .map((line) {
          final count = _macroIndentation.firstMatch(line)![0]!.length;
          return count >= indent ? line.substring(indent) : line.replaceFirst(_macroLeadingWhitespace, '');
        })
        .join('\n'),
  );
}

String _examples(String raw) {
  if (raw.isEmpty || raw == '<START>') return '';
  if (!raw.startsWith('<START>')) raw = '<START>\n${trimJsWhitespace(raw)}';
  return raw.split(_macroExampleStart).skip(1).map((part) => '<START>\n${trimJsWhitespace(part)}\n').join();
}

List<String> _randomList(String input) {
  if (input.contains('::')) return input.split('::').map(trimJsWhitespace).toList();
  return input
      .replaceAll(r'\,', '##�COMMA�##')
      .split(',')
      .map((s) => trimJsWhitespace(s).replaceAll('##�COMMA�##', ','))
      .toList();
}

const _undefined = _Undefined();

class _Undefined {
  const _Undefined();
}

bool _truthy(Object? value) =>
    value != null &&
    !identical(value, _undefined) &&
    value != false &&
    value != '' &&
    !(value is num && (value == 0 || value.isNaN));

bool _falseBoolean(String value) => const {'false', 'off', '0'}.contains(trimJsWhitespace(value).toLowerCase());

bool _falseValue(Object? value) => !_truthy(value) || _falseBoolean(_normalize(value));

double _number(Object? value) {
  if (identical(value, _undefined)) return double.nan;
  if (value == null) return 0;
  if (value is num) return value.toDouble();
  if (value is bool) return value ? 1 : 0;
  if (value is List<Object?>) return _number(_jsString(value));
  if (value is! String) return double.nan;
  final text = trimJsWhitespace(value);
  if (text.isEmpty) return 0;
  if (text == 'Infinity' || text == '+Infinity') return double.infinity;
  if (text == '-Infinity') return double.negativeInfinity;
  final based = _macroBasedNumber.firstMatch(text);
  if (based != null) {
    final radix = switch (based[1]!.toLowerCase()) {
      'x' => 16,
      'b' => 2,
      _ => 8,
    };
    return BigInt.tryParse(based[2]!, radix: radix)?.toDouble() ?? double.nan;
  }
  if (!_macroDecimalNumber.hasMatch(text)) return double.nan;
  return double.tryParse(text) ?? double.nan;
}

String _numberString(num value) {
  final number = value.toDouble();
  if (number.isNaN) return 'NaN';
  if (number == double.infinity) return 'Infinity';
  if (number == double.negativeInfinity) return '-Infinity';
  if (number == 0) return '0';
  var raw = number.toString();
  final e = raw.indexOf('e');
  if (e < 0) return raw.endsWith('.0') ? raw.substring(0, raw.length - 2) : raw;
  var mantissa = raw.substring(0, e);
  if (mantissa.endsWith('.0')) mantissa = mantissa.substring(0, mantissa.length - 2);
  final exponent = int.parse(raw.substring(e + 1));
  if (exponent >= 21 || exponent < -6) {
    return '${mantissa}e${exponent >= 0 ? '+' : ''}$exponent';
  }
  final negative = mantissa.startsWith('-');
  if (negative) mantissa = mantissa.substring(1);
  final point = mantissa.indexOf('.');
  final digits = mantissa.replaceAll('.', '');
  final decimal = (point < 0 ? mantissa.length : point) + exponent;
  if (decimal <= 0) {
    raw = '0.${''.padRight(-decimal, '0')}$digits';
  } else if (decimal >= digits.length) {
    raw = digits.padRight(decimal, '0');
  } else {
    raw = '${digits.substring(0, decimal)}.${digits.substring(decimal)}';
  }
  return negative ? '-$raw' : raw;
}

String _jsString(Object? value) {
  if (value == null) return 'null';
  if (identical(value, _undefined)) return 'undefined';
  if (value is num) return _numberString(value);
  if (value is List<Object?>) {
    return value.map((v) => v == null || identical(v, _undefined) ? '' : _jsString(v)).join(',');
  }
  if (value is Map<Object?, Object?>) return '[object Object]';
  return value.toString();
}

String _normalize(Object? value) {
  if (value == null || identical(value, _undefined)) return '';
  if (value is List<Object?> || value is Map<Object?, Object?>) return _jsJson(value);
  return _jsString(value);
}

Object? _decodeJsJson(Object? value) =>
    jsonDecode(_jsString(value), reviver: (_, child) => child is num ? child.toDouble() : child);

/// JSON.stringify ordering and finite-number handling for JSON-owned values.
String _jsJson(Object? value) {
  if (value == null || identical(value, _undefined)) return 'null';
  if (value is num) return value.isFinite ? _numberString(value) : 'null';
  if (value is String || value is bool) return jsonEncode(value);
  if (value is List<Object?>) return '[${value.map(_jsJson).join(',')}]';
  if (value is Map<Object?, Object?>) {
    final entries = value.entries.toList();
    final indices = entries.where((e) => _arrayIndex(_jsString(e.key)) != null).toList()
      ..sort((a, b) => _arrayIndex(_jsString(a.key))!.compareTo(_arrayIndex(_jsString(b.key))!));
    final other = entries.where((e) => _arrayIndex(_jsString(e.key)) == null);
    return '{${[...indices, ...other].map((e) => '${jsonEncode(_jsString(e.key))}:${_jsJson(e.value)}').join(',')}}';
  }
  throw ArgumentError.value(value, 'value', 'Expected a JSON value');
}

int? _arrayIndex(String key) {
  if (!_macroArrayIndex.hasMatch(key)) return null;
  final number = int.tryParse(key);
  return number != null && number < 4294967295 ? number : null;
}

Object? _property(Object? object, String key) {
  if (object == null) throw ArgumentError('Cannot index null');
  if (object is Map<String, Object?>) {
    return object.containsKey(key) ? object[key] : _undefined;
  }
  if (object is List<Object?>) {
    if (key == 'length') return object.length;
    final index = _arrayIndex(key);
    return index != null && index < object.length ? object[index] : _undefined;
  }
  if (object is String) {
    if (key == 'length') return object.length;
    final index = _arrayIndex(key);
    return index != null && index < object.length ? object[index] : _undefined;
  }
  return _undefined;
}

Object? _getVariable(Map<String, Object?> vars, String name, [String? index]) {
  Object? value = vars.containsKey(name) ? vars[name] : _undefined;
  if (index != null) {
    try {
      value = _decodeJsJson(value);
      final number = _number(index);
      value = _property(value, number.isNaN ? index : _numberString(number));
      if (value == null || value is List<Object?> || value is Map<Object?, Object?>) {
        value = _jsJson(value);
      }
    } on FormatException {
      // ST retains the value reached before parsing/indexing failed.
    } on ArgumentError {
      // In particular, parsing "null" succeeds before indexing it fails.
    }
  }
  final number = _number(value);
  if ((value is String && value.trim().isEmpty) || number.isNaN) {
    return _truthy(value) ? value : '';
  }
  return number;
}

void _setVariable(Map<String, Object?> vars, String name, Object? value, [String? index]) {
  if (name.isEmpty) throw ArgumentError.value(name, 'name', 'Cannot be empty');
  if (index == null) {
    vars[name] = value;
    return;
  }
  try {
    var parsed = _decodeJsJson(vars[name] ?? 'null');
    final number = _number(index);
    final key = number.isNaN ? index : _numberString(number);
    parsed ??= number.isNaN ? <String, Object?>{} : <Object?>[];
    if (parsed is Map<String, Object?>) {
      // Assignment to the inherited __proto__ setter does not create an own
      // JSON property. Existing JSON-owned properties keep normal semantics.
      if (key != '__proto__' || parsed.containsKey(key)) parsed[key] = value;
    } else if (parsed is List<Object?>) {
      if (key == 'length') {
        final length = _number(value);
        if (!length.isFinite || length < 0 || length >= 4294967296 || length != length.floorToDouble()) return;
        parsed.length = length.toInt();
      } else {
        final position = _arrayIndex(key);
        if (position != null) {
          if (parsed.length <= position) parsed.length = position + 1;
          parsed[position] = value;
        }
        // Other array properties are omitted by JSON.stringify.
      }
    } else {
      return; // Strict-mode JavaScript cannot assign to a primitive.
    }
    vars[name] = _jsJson(parsed);
  } on FormatException {
    // Invalid JSON leaves the original variable intact.
  } on ArgumentError {
    // Invalid array length / unsupported JSON value likewise leaves it intact.
  }
}

Object? _addVariable(Map<String, Object?> vars, String name, Object? value) {
  final existing = _getVariable(vars, name);
  final current = _truthy(existing) ? existing : 0;
  try {
    final parsed = _decodeJsJson(current);
    if (parsed is List<Object?>) {
      parsed.add(value);
      _setVariable(vars, name, _jsJson(parsed));
      return parsed;
    }
  } on FormatException {
    // Non-arrays follow the numeric/string branches.
  }
  final increment = _number(value);
  final base = _number(current);
  if (increment.isNaN || base.isNaN) {
    final result = '${_jsString(_truthy(current) ? current : '')}${_jsString(value)}';
    _setVariable(vars, name, result);
    return result;
  }
  final result = base + increment;
  if (result.isNaN) return '';
  _setVariable(vars, name, result);
  return result;
}

// Translation of seedrandom 3.0.5, string seed + default double generator.
// Copyright 2019 David Bau.
//
// Permission is hereby granted, free of charge, to any person obtaining
// a copy of this software and associated documentation files (the
// "Software"), to deal in the Software without restriction, including
// without limitation the rights to use, copy, modify, merge, publish,
// distribute, sublicense, and/or sell copies of the Software, and to
// permit persons to whom the Software is furnished to do so, subject to
// the following conditions:
//
// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
// IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
// CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
// TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
// SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
class _SeedRandom {
  _SeedRandom(String seed) {
    final key = <int>[];
    var smear = 0;
    for (var j = 0; j < seed.length; j++) {
      final index = j & 255;
      if (key.length <= index) key.add(0);
      smear ^= key[index] * 19;
      key[index] = (smear + seed.codeUnitAt(j)) & 255;
    }
    if (key.isEmpty) key.add(0);
    var j = 0;
    for (var i = 0; i < 256; i++) {
      final t = _s[i];
      j = (j + key[i % key.length] + t) & 255;
      _s[i] = _s[j];
      _s[j] = t;
    }
    // Drop the first 256 bytes without accumulating an unused giant integer.
    for (var i = 0; i < 256; i++) {
      _g(1);
    }
  }

  // seedrandom 3.0.5 flatten(number, 3) appends NUL before mixkey. String
  // seeds do not, so legacy picks must not reuse the new engine's seed text.
  _SeedRandom.numeric(num seed) : this('${_numberString(seed)}\u0000');

  final List<int> _s = List.generate(256, (i) => i);
  int _i = 0;
  int _j = 0;

  int _g(int count) {
    var result = 0;
    for (var n = 0; n < count; n++) {
      _i = (_i + 1) & 255;
      final t = _s[_i];
      _j = (_j + t) & 255;
      _s[_i] = _s[_j];
      _s[_j] = t;
      result = result * 256 + _s[(_s[_i] + _s[_j]) & 255];
    }
    return result;
  }

  double nextDouble() {
    var n = _g(6).toDouble();
    var d = 281474976710656.0;
    var x = 0;
    while (n < 4503599627370496) {
      n = (n + x) * 256;
      d *= 256;
      x = _g(1);
    }
    while (n >= 9007199254740992) {
      n /= 2;
      d /= 2;
      x >>>= 1;
    }
    return (n + x) / d;
  }
}

// Moment 2.30.1 format conventions and duration thresholds; common en/zh-cn
// tokens are translated here so the pure-Dart engine does not consult a
// platform locale or an implicit timezone.
// Copyright (c) JS Foundation and other contributors
//
// Permission is hereby granted, free of charge, to any person
// obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without
// restriction, including without limitation the rights to use,
// copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the
// Software is furnished to do so, subject to the following
// conditions:
//
// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
// OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
// HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
// WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
// OTHER DEALINGS IN THE SOFTWARE.
class _MacroClock {
  _MacroClock(this.instant, this.offset, String locale)
    : locale = locale.toLowerCase().replaceAll('_', '-'),
      local = instant.toUtc().add(offset);

  final DateTime instant;
  final DateTime local;
  final Duration offset;
  final String locale;
  bool get chinese => locale == 'zh-cn';

  // Moment 2.30.1 src/lib/units/era.js and src/lib/locale/en.js define these outputs.
  // src/locale/zh-cn.js has no eras, so era.js falls back to en.
  // Boundaries use this context's fixed-offset local calendar, not hidden host anchors.
  int get _eraYear => local.year >= 1 ? local.year : 1 - local.year;

  void _checkLocale() {
    if (!chinese && locale != 'en' && locale != 'en-us') {
      throw ArgumentError.value(locale, 'locale', 'Supported: en, zh-cn');
    }
  }

  static const _months = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
  static const _zhMonths = ['一月', '二月', '三月', '四月', '五月', '六月', '七月', '八月', '九月', '十月', '十一月', '十二月'];
  static const _days = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
  static const _zhDays = ['日', '一', '二', '三', '四', '五', '六'];
  static const _longEn = {
    'LT': 'h:mm A',
    'LTS': 'h:mm:ss A',
    'L': 'MM/DD/YYYY',
    'LL': 'MMMM D, YYYY',
    'LLL': 'MMMM D, YYYY h:mm A',
    'LLLL': 'dddd, MMMM D, YYYY h:mm A',
    'l': 'M/D/YYYY',
    'll': 'MMM D, YYYY',
    'lll': 'MMM D, YYYY h:mm A',
    'llll': 'ddd, MMM D, YYYY h:mm A',
  };
  static const _longZh = {
    'LT': 'HH:mm',
    'LTS': 'HH:mm:ss',
    'L': 'YYYY/MM/DD',
    'LL': 'YYYY年M月D日',
    'LLL': 'YYYY年M月D日Ah点mm分',
    'LLLL': 'YYYY年M月D日ddddAh点mm分',
    'l': 'YYYY/M/D',
    'll': 'YYYY年M月D日',
    'lll': 'YYYY年M月D日 HH:mm',
    'llll': 'YYYY年M月D日dddd HH:mm',
  };
  static final _tokens = <String>[
    'YYYYYY',
    'YYYYY',
    'YYYY',
    'YY',
    'Y',
    'NNNNN',
    'NNNN',
    'NNN',
    'NN',
    'N',
    'yyyy',
    'yyy',
    'yy',
    'yo',
    'y',
    'Qo',
    'Q',
    'MMMM',
    'MMM',
    'MM',
    'Mo',
    'M',
    'DDDo',
    'DDDD',
    'DDD',
    'DD',
    'Do',
    'D',
    'dddd',
    'ddd',
    'dd',
    'do',
    'd',
    'e',
    'E',
    'ww',
    'wo',
    'w',
    'WW',
    'Wo',
    'W',
    'gggg',
    'gg',
    'GGGG',
    'GG',
    'Hmmss',
    'Hmm',
    'hmmss',
    'hmm',
    'HH',
    'H',
    'hh',
    'h',
    'kk',
    'k',
    'mm',
    'm',
    'ss',
    's',
    'SSSSSSSSS',
    'SSSSSSSS',
    'SSSSSSS',
    'SSSSSS',
    'SSSSS',
    'SSSS',
    'SSS',
    'SS',
    'S',
    'a',
    'A',
    'ZZ',
    'Z',
    'zz',
    'z',
    'X',
    'x',
  ]..sort((a, b) => b.length.compareTo(a.length));

  // Moment 2.30.1 src/lib/format/format.js expands aliases before rendering.
  // Escapes consume its full lexical token, including unsupported output tokens.
  static final _longFormatTokens = RegExp(r'(\[[^\[]*\])|(\\)?(LTS|LT|LL?L?L?|l{1,4})');
  static final _formatTokens = RegExp(
    r'(\[[^\[]*\])|\\(?:'
    r'[Hh]mm(?:ss)?|Mo|MM?M?M?|Do|DDDo|DD?D?D?|ddd?d?|do?|w[o|w]?|W[o|W]?|Qo?|N{1,5}|'
    r'YYYYYY|YYYYY|YYYY|YY|y{2,4}|yo?|gg(?:ggg?)?|GG(?:GGG?)?|e|E|a|A|hh?|HH?|kk?|mm?|ss?|'
    r'S{1,9}|x|X|zz?|ZZ?|.)|(?:'
    // Moment's unescaped w[o|w]? / W[o|W]? also consumes a literal pipe.
    r'[wW]\||'
    '${_tokens.map(RegExp.escape).join('|')}|.)',
  );

  String format(String pattern) {
    _checkLocale();
    return _format(pattern.isEmpty ? 'YYYY-MM-DDTHH:mm:ssZ' : pattern);
  }

  String _format(String pattern) {
    final longFormats = chinese ? _longZh : _longEn;
    // The fixed locale definitions contain no further long-format aliases.
    final expanded = pattern.replaceAllMapped(_longFormatTokens, (match) => longFormats[match[0]] ?? match[0]!);
    final result = StringBuffer();
    for (final match in _formatTokens.allMatches(expanded)) {
      final token = match[0]!;
      if (match[1] != null) {
        result.write(token.substring(1, token.length - 1));
      } else if (token.contains('\\')) {
        result.write(token.replaceAll('\\', ''));
      } else {
        result.write(_token(token));
      }
    }
    return result.toString();
  }

  String _pad(int n, [int length = 2]) =>
      n < 0 ? '-${(-n).toString().padLeft(length, '0')}' : n.toString().padLeft(length, '0');

  String _ordinal(int n, String unit) {
    if (chinese) {
      return switch (unit) {
        'd' || 'D' || 'DDD' => '$n日',
        'M' => '$n月',
        'w' || 'W' => '$n周',
        _ => '$n',
      };
    }
    final suffix = n % 100 >= 11 && n % 100 <= 13
        ? 'th'
        : switch (n % 10) {
            1 => 'st',
            2 => 'nd',
            3 => 'rd',
            _ => 'th',
          };
    return '$n$suffix';
  }

  String _meridiem() {
    if (!chinese) return local.hour < 12 ? 'AM' : 'PM';
    final hm = local.hour * 100 + local.minute;
    if (hm < 600) return '凌晨';
    if (hm < 900) return '早上';
    if (hm < 1130) return '上午';
    if (hm < 1230) return '中午';
    if (hm < 1800) return '下午';
    return '晚上';
  }

  String _token(String token) {
    final day = local.weekday % 7;
    final hour12 = local.hour % 12 == 0 ? 12 : local.hour % 12;
    late final dayOfYear = _dayOfYear(local);
    if (_macroFractionalSeconds.hasMatch(token)) {
      return _pad(local.millisecond, 3).padRight(9, '0').substring(0, token.length);
    }
    switch (token) {
      case 'Y':
        return local.year <= 9999 ? _pad(local.year, 4) : '+${local.year}';
      case 'YY':
        return _pad(local.year.remainder(100).toInt());
      case 'YYYY':
        return _pad(local.year, 4);
      case 'YYYYY':
        return _pad(local.year, 5);
      case 'YYYYYY':
        return '${local.year >= 0 ? '+' : '-'}${_pad(local.year.abs(), 6)}';
      case 'N':
      case 'NN':
      case 'NNN':
      case 'NNNNN':
        return local.year >= 1 ? 'AD' : 'BC';
      case 'NNNN':
        return local.year >= 1 ? 'Anno Domini' : 'Before Christ';
      case 'y':
      case 'yy':
      case 'yyy':
      case 'yyyy':
        return _pad(_eraYear, token.length);
      case 'yo':
        return _ordinal(_eraYear, 'y');
      case 'Q':
        return '${(local.month + 2) ~/ 3}';
      case 'Qo':
        return _ordinal((local.month + 2) ~/ 3, 'Q');
      case 'M':
        return '${local.month}';
      case 'Mo':
        return _ordinal(local.month, 'M');
      case 'MM':
        return _pad(local.month);
      case 'MMM':
        return chinese ? '${local.month}月' : _months[local.month - 1].substring(0, 3);
      case 'MMMM':
        return (chinese ? _zhMonths : _months)[local.month - 1];
      case 'D':
        return '${local.day}';
      case 'DD':
        return _pad(local.day);
      case 'Do':
        return _ordinal(local.day, 'D');
      case 'DDD':
        return dayOfYear == null ? 'NaN' : '$dayOfYear';
      case 'DDDD':
        return dayOfYear == null ? '-NaN' : _pad(dayOfYear, 3);
      case 'DDDo':
        return dayOfYear == null ? (chinese ? 'NaN日' : 'NaNth') : _ordinal(dayOfYear, 'DDD');
      case 'd':
        return '$day';
      case 'do':
        return _ordinal(day, 'd');
      case 'dd':
        return chinese ? _zhDays[day] : _days[day].substring(0, 2);
      case 'ddd':
        return chinese ? '周${_zhDays[day]}' : _days[day].substring(0, 3);
      case 'dddd':
        return chinese ? '星期${_zhDays[day]}' : _days[day];
      case 'e':
        return '${(day + (chinese ? 6 : 0)) % 7}';
      case 'E':
        return '${local.weekday}';
      case 'w':
      case 'ww':
      case 'wo':
      case 'W':
      case 'WW':
      case 'Wo':
      case 'gg':
      case 'gggg':
      case 'GG':
      case 'GGGG':
        final iso = token[0] == token[0].toUpperCase() || chinese;
        final week = _weekOfYear(local, iso ? 1 : 0, iso ? 4 : 6);
        if (token[0].toLowerCase() == 'g') {
          return token.length == 2 ? _pad(week.year.remainder(100).toInt()) : _pad(week.year, 4);
        }
        final weekNumber = week.week;
        if (weekNumber == null) {
          if (token.endsWith('o')) return chinese ? 'NaN周' : 'NaNth';
          return token.length == 2 ? '-NaN' : 'NaN';
        }
        if (token.endsWith('o')) return _ordinal(weekNumber, token[0]);
        return token.length == 2 ? _pad(weekNumber) : '$weekNumber';
      case 'H':
        return '${local.hour}';
      case 'HH':
        return _pad(local.hour);
      case 'h':
        return '$hour12';
      case 'hh':
        return _pad(hour12);
      case 'k':
        return '${local.hour == 0 ? 24 : local.hour}';
      case 'kk':
        return _pad(local.hour == 0 ? 24 : local.hour);
      case 'Hmm':
        return '${local.hour}${_pad(local.minute)}';
      case 'Hmmss':
        return '${local.hour}${_pad(local.minute)}${_pad(local.second)}';
      case 'hmm':
        return '$hour12${_pad(local.minute)}';
      case 'hmmss':
        return '$hour12${_pad(local.minute)}${_pad(local.second)}';
      case 'm':
        return '${local.minute}';
      case 'mm':
        return _pad(local.minute);
      case 's':
        return '${local.second}';
      case 'ss':
        return _pad(local.second);
      case 'a':
        return _meridiem().toLowerCase();
      case 'A':
        return _meridiem();
      case 'Z':
      case 'ZZ':
        final minutes = offset.inMinutes;
        return '${minutes < 0 ? '-' : '+'}${_pad(minutes.abs() ~/ 60)}'
            '${token == 'Z' ? ':' : ''}${_pad(minutes.abs() % 60)}';
      case 'z':
      case 'zz':
        return ''; // Moment local/fixed-offset inputs have no zone name.
      case 'X':
        return '${(instant.millisecondsSinceEpoch / 1000).floor()}';
      case 'x':
        return '${instant.millisecondsSinceEpoch}';
      default:
        return token;
    }
  }

  /// ISO calendar dates/timestamps, with optional timezone and milliseconds.
  /// Locale-dependent free-form Date parsing is intentionally not delegated to
  /// the host. Invalid calendar dates are rejected rather than normalized.
  DateTime? parse(String input) {
    var match = _macroIsoDate.firstMatch(input.trim());
    if (match == null && input.endsWith('Z')) {
      // Only complete Moment ISO calendar forms gain pre-Z whitespace. Do not
      // promote legacy arguments with trailing whitespace into the ISO path.
      final utcGap = _macroIsoUtcGap.firstMatch(trimJsWhitespace(input));
      if (utcGap != null) match = _macroIsoDate.firstMatch('${utcGap[1]}Z');
    }
    if (match == null) return null;
    final year = int.parse(match[1]!);
    // Reject impossible years before DateTime's microsecond arithmetic can wrap.
    if (year < -271821 || year > 275760) return null;
    final month = int.parse(match[2] ?? '1');
    final day = int.parse(match[3] ?? '1');
    final hour = int.parse(match[4] ?? '0');
    final minute = int.parse(match[5] ?? '0');
    final second = int.parse(match[6] ?? '0');
    final millis = int.parse((match[7] ?? '').padRight(3, '0').substring(0, 3));
    if (month < 1 || month > 12) return null;
    // A synthetic month end can exceed DateTime's range even for a valid day.
    final leapYear = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
    final daysInMonth = switch (month) {
      2 => leapYear ? 29 : 28,
      4 || 6 || 9 || 11 => 30,
      _ => 31,
    };
    if (day < 1 ||
        day > daysInMonth ||
        hour > 24 ||
        minute > 59 ||
        second > 59 ||
        (hour == 24 && (minute != 0 || second != 0 || millis != 0))) {
      return null;
    }
    var zone = offset;
    final zoneText = match[8];
    if (zoneText != null) {
      if (zoneText.toUpperCase() == 'Z') {
        zone = Duration.zero;
      } else {
        final digits = zoneText.substring(1).replaceAll(':', '');
        final minutes =
            int.parse(digits.substring(0, 2)) * 60 + (digits.length == 4 ? int.parse(digits.substring(2)) : 0);
        zone = Duration(minutes: zoneText.startsWith('-') ? -minutes : minutes);
      }
    }
    try {
      // Moment constructs the wall date first; an offset cannot rescue it.
      return DateTime.utc(year, month, day, hour, minute, second, millis).subtract(zone);
    } on ArgumentError {
      return null;
    }
  }

  String humanize(DateTime left, DateTime right, {bool suffix = false}) {
    _checkLocale();
    // Epoch milliseconds use floor. Correct the quotient toward zero
    // without forming a microsecond difference that can overflow int64.
    final differenceMilliseconds = left.millisecondsSinceEpoch - right.millisecondsSinceEpoch;
    final remainder = left.microsecond - right.microsecond;
    final wholeMilliseconds = differenceMilliseconds > 0 && remainder < 0
        ? differenceMilliseconds - 1
        : differenceMilliseconds < 0 && remainder > 0
        ? differenceMilliseconds + 1
        : differenceMilliseconds;
    final milliseconds = wholeMilliseconds.abs().toDouble();
    final seconds = (milliseconds / 1000).round();
    final minutes = (milliseconds / 60000).round();
    final hours = (milliseconds / 3600000).round();
    final days = (milliseconds / 86400000).round();
    final monthsFloat = milliseconds / 86400000 * 4800 / 146097;
    final months = monthsFloat.round();
    final years = (monthsFloat / 12).round();
    final (unit, count) = seconds <= 44
        ? ('s', seconds)
        : seconds < 45
        ? ('ss', seconds)
        : minutes <= 1
        ? ('m', 1)
        : minutes < 45
        ? ('mm', minutes)
        : hours <= 1
        ? ('h', 1)
        : hours < 22
        ? ('hh', hours)
        : days <= 1
        ? ('d', 1)
        : days < 26
        ? ('dd', days)
        : months <= 1
        ? ('M', 1)
        : months < 11
        ? ('MM', months)
        : years <= 1
        ? ('y', 1)
        : ('yy', years);
    final forms = chinese
        ? const {
            's': '几秒',
            'ss': '%d 秒',
            'm': '1 分钟',
            'mm': '%d 分钟',
            'h': '1 小时',
            'hh': '%d 小时',
            'd': '1 天',
            'dd': '%d 天',
            'M': '1 个月',
            'MM': '%d 个月',
            'y': '1 年',
            'yy': '%d 年',
          }
        : const {
            's': 'a few seconds',
            'ss': '%d seconds',
            'm': 'a minute',
            'mm': '%d minutes',
            'h': 'an hour',
            'hh': '%d hours',
            'd': 'a day',
            'dd': '%d days',
            'M': 'a month',
            'MM': '%d months',
            'y': 'a year',
            'yy': '%d years',
          };
    final text = forms[unit]!.replaceAll('%d', '$count');
    if (!suffix) return text;
    final future = left.isAfter(right);
    return chinese
        ? '$text${future ? '后' : '前'}'
        : future
        ? 'in $text'
        : '$text ago';
  }
}

// Moment keeps a valid date but can derive NaN from an unavailable year start.
int? _dayOfYear(DateTime date) {
  try {
    return DateTime.utc(date.year, date.month, date.day).difference(DateTime.utc(date.year)).inDays + 1;
  } on ArgumentError {
    return null;
  }
}

int? _firstWeekOffset(int year, int dow, int doy) {
  try {
    final first = 7 + dow - doy;
    final weekday = (7 + DateTime.utc(year, 1, first).weekday % 7 - dow) % 7;
    return -weekday + first - 1;
  } on ArgumentError {
    return null;
  }
}

int? _weeksInYear(int year, int dow, int doy) {
  final offset = _firstWeekOffset(year, dow, doy);
  final nextOffset = _firstWeekOffset(year + 1, dow, doy);
  if (offset == null || nextOffset == null) return null;
  return (DateTime.utc(year + 1).difference(DateTime.utc(year)).inDays - offset + nextOffset) ~/ 7;
}

({int year, int? week}) _weekOfYear(DateTime date, int dow, int doy) {
  final year = date.year;
  final day = _dayOfYear(date);
  final offset = _firstWeekOffset(year, dow, doy);
  if (day == null || offset == null) return (year: year, week: null);
  final week = ((day - offset - 1) / 7).floor() + 1;
  if (week < 1) {
    final total = _weeksInYear(year - 1, dow, doy);
    return (year: year - 1, week: total == null ? null : week + total);
  }
  final total = _weeksInYear(year, dow, doy);
  if (total != null && week > total) return (year: year + 1, week: week - total);
  return (year: year, week: week);
}
