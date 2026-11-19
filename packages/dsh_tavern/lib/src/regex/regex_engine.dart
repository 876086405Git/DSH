// Port of SillyTavern 1.19.0 regex/engine.js, regex/index.js migrations,
// and utils.js regexFromString.
// https://github.com/SillyTavern/SillyTavern
// Commit: 7e8663cd9c184a550b37238218bdd32c6efc68e9 (AGPL-3.0).
// Upstream regexFromString also credits https://github.com/IonicaBizau/regex-parser.js.

import 'regex_program.dart';
import 'regex_worker.dart';

/// ST's numeric placement values; zero and four are legacy import values.
abstract final class RegexPlacement {
  static const userInput = 1;
  static const aiOutput = 2;
  static const slashCommand = 3;
  static const worldInfo = 5;
  static const reasoning = 6;
}

enum RegexPhase { writeBack, prompt, display }

/// The callback must apply [postProcess] to each resolved macro value, including
/// nested evaluations. Escaping the complete expanded pattern is not equivalent.
/// Only trim-string expansion receives [characterOverride].
typedef RegexMacroExpansion =
    String Function(String text, {String? characterOverride, Object? Function(Object? value)? postProcess});

/// An immutable execution view. The original card/preset/settings JSON remains
/// owned by its persistence layer, including fields this engine does not read.
final class RegexScript {
  factory RegexScript.fromJson(Map<String, Object?> json) {
    final rawPlacement = json['placement'];
    final placement = rawPlacement is List ? List<Object?>.of(rawPlacement) : <Object?>[];
    var markdownOnly = _truthy(json['markdownOnly']);
    var promptOnly = _truthy(json['promptOnly']);
    if (placement.contains(0)) {
      if (placement.length == 1) {
        placement
          ..clear()
          ..addAll(const [1, 2, 3, 5, 6]);
      } else {
        placement.removeWhere((value) => value == 0);
      }
      markdownOnly = true;
      promptOnly = true;
    }
    if (placement.contains(4)) {
      if (placement.length == 1) {
        placement[0] = RegexPlacement.slashCommand;
      } else {
        placement.removeWhere((value) => value == 4);
      }
    }
    final rawTrims = json['trimStrings'];
    final trims = rawTrims is List ? rawTrims.whereType<String>().toList() : <String>[];
    return RegexScript._(
      id: json['id'] is String ? json['id']! as String : '',
      scriptName: json['scriptName'] is String ? json['scriptName']! as String : '',
      findRegex: json['findRegex'] is String ? json['findRegex']! as String : '',
      replaceString: json['replaceString'] is String ? json['replaceString']! as String : '',
      trimStrings: List.unmodifiable(trims),
      placement: List.unmodifiable([
        for (final value in placement)
          if (value is num && value.isFinite && value == value.truncateToDouble()) value.toInt(),
      ]),
      disabled: _truthy(json['disabled']),
      markdownOnly: markdownOnly,
      promptOnly: promptOnly,
      runOnEdit: _truthy(json['runOnEdit']),
      substituteRegex: _number(json['substituteRegex']),
      minDepth: json['minDepth'] == null ? null : _number(json['minDepth']),
      maxDepth: json['maxDepth'] == null ? null : _number(json['maxDepth']),
      valid:
          json['findRegex'] is String &&
          json['replaceString'] is String &&
          (rawTrims == null || (rawTrims is List && trims.length == rawTrims.length)),
    );
  }

  RegexScript._({
    required this.id,
    required this.scriptName,
    required this.findRegex,
    required this.replaceString,
    required this.trimStrings,
    required this.placement,
    required this.disabled,
    required this.markdownOnly,
    required this.promptOnly,
    required this.runOnEdit,
    required this.substituteRegex,
    required this.minDepth,
    required this.maxDepth,
    required bool valid,
  }) : _valid = valid;

  final String id;
  final String scriptName;
  final String findRegex;
  final String replaceString;
  final List<String> trimStrings;
  final List<int> placement;
  final bool disabled;
  final bool markdownOnly;
  final bool promptOnly;
  final bool runOnEdit;
  final num substituteRegex;
  final num? minDepth;
  final num? maxDepth;
  final bool _valid;
  late final _RegexReplacement _replacement = _RegexReplacement(replaceString);
}

final class _RegexReplacement {
  _RegexReplacement(String source) : template = source.replaceAll(_matchMacro, r'$0');

  final String template;
  late final int templateBytes = regexUtf8Length(template);
  ({List<String> keys, int bytes})? _captureReferences;

  List<String> referenceKeys(int maximum) {
    final cached = _captureReferences;
    var bytes = cached?.bytes ?? 0;
    if (bytes > maximum) {
      throw const _DisplayLimit('capture-limit', '捕获引用描述超过内部传输上限。');
    }
    if (cached != null) return cached.keys;
    final keys = <String>{};
    for (final reference in _captureReference.allMatches(template)) {
      final key = _referenceKey(reference);
      if (!keys.add(key)) continue;
      bytes += regexUtf8Length(key, stopAfter: maximum - bytes - 16) + 16;
      if (bytes > maximum) {
        throw const _DisplayLimit('capture-limit', '捕获引用描述超过内部传输上限。');
      }
    }
    final result = keys.toList();
    _captureReferences = (keys: result, bytes: bytes);
    return result;
  }
}

/// Text transforms with legacy synchronous and protected display paths.
/// This class neither persists text nor counts
/// chat depth. Callers supply a complete message for write-back, and a separate
/// copy for prompt/display. No write-back script is reapplied to prompt copies.
final class RegexEngine {
  RegexEngine({
    Iterable<RegexScript> globalScripts = const [],
    Iterable<RegexScript> presetScripts = const [],
    Iterable<RegexScript> characterScripts = const [],
    Iterable<RegexScript> chatScripts = const [],
    this.enabled = true,
  }) : _scripts = List.unmodifiable([...globalScripts, ...presetScripts, ...characterScripts, ...chatScripts]);

  final bool enabled;
  final List<RegexScript> _scripts;
  final Map<String, _CompiledRegex> _cache = {};

  /// Parse the execution view without mutating its source. Malformed array
  /// members are ignored; malformed known string fields disable that script.
  static List<RegexScript> readScripts(Object? value) {
    if (value is! List) return const [];
    return List.unmodifiable([
      for (final item in value)
        if (item is Map && item.keys.every((key) => key is String)) RegexScript.fromJson(item.cast<String, Object?>()),
    ]);
  }

  String apply(
    String input, {
    required int placement,
    RegexPhase phase = RegexPhase.writeBack,
    bool isEdit = false,
    num? depth,
    String? characterOverride,
    RegexMacroExpansion? expand,
  }) => _apply(
    input,
    placement: placement,
    phase: phase,
    isEdit: isEdit,
    depth: depth,
    characterOverride: characterOverride,
    expand: expand,
  );

  /// Runs the ordinary synchronous phase once while recording its real skips
  /// and replacements. This is not the protected display-worker path.
  RegexDisplayResult applyWithDiagnostics(
    String input, {
    required int placement,
    RegexPhase phase = RegexPhase.prompt,
    bool isEdit = false,
    num? depth,
    String? characterOverride,
    RegexMacroExpansion? expand,
  }) {
    final trace = _RegexRunTrace();
    final text = _apply(
      input,
      placement: placement,
      phase: phase,
      isEdit: isEdit,
      depth: depth,
      characterOverride: characterOverride,
      expand: expand,
      trace: trace,
    );
    return RegexDisplayResult(text: text, warnings: trace.warnings, replacements: trace.replacements);
  }

  String _apply(
    String input, {
    required int placement,
    required RegexPhase phase,
    required bool isEdit,
    num? depth,
    String? characterOverride,
    RegexMacroExpansion? expand,
    _RegexRunTrace? trace,
  }) {
    if (!enabled || input.isEmpty) return input;
    var result = input;
    for (var index = 0; index < _scripts.length; index++) {
      final script = _scripts[index];
      final eligible = switch (phase) {
        RegexPhase.writeBack => !script.markdownOnly && !script.promptOnly,
        RegexPhase.prompt => script.promptOnly,
        RegexPhase.display => script.markdownOnly,
      };
      if (!eligible || (isEdit && !script.runOnEdit) || !script.placement.contains(placement)) continue;
      // ST's write-back call sites omit depth. Even if a caller supplies one,
      // this explicit API keeps the storage path independent of depth filters.
      if (phase != RegexPhase.writeBack && depth != null) {
        final minimum = script.minDepth;
        final maximum = script.maxDepth;
        if (minimum != null && minimum >= -1 && depth < minimum) continue;
        if (maximum != null && maximum >= 0 && depth > maximum) continue;
      }
      result = _runScript(
        script,
        result,
        characterOverride: characterOverride,
        expand: expand,
        trace: trace,
        ruleIndex: index,
      );
    }
    return result;
  }

  /// Detached display rendering. User patterns run in [worker]; macros stay
  /// in their caller's independent display context, in ST's original order.
  /// Skipped rules retain the last completed text without replaying macros.
  /// The synchronous prompt/write-back API remains outside this protection.
  Future<RegexDisplayResult> applyDisplay(
    String input, {
    required int placement,
    required RegexWorker worker,
    bool isEdit = false,
    num? depth,
    String? characterOverride,
    RegexMacroExpansion? expand,
    bool Function()? isCancelled,
  }) async {
    final warnings = <RegexDisplayWarning>[];
    var result = input;
    var replacements = 0;
    var rules = 0;
    RegexDisplayResult finish({bool cancelled = false}) =>
        RegexDisplayResult(text: result, warnings: warnings, replacements: replacements, cancelled: cancelled);
    void warn(RegexScript script, int index, String code, String message) {
      warnings.add(
        RegexDisplayWarning(
          ruleId: script.id,
          ruleName: script.scriptName,
          ruleIndex: index,
          reason: code,
          message: message,
        ),
      );
    }

    if (isCancelled?.call() == true) {
      return finish(cancelled: true);
    }
    if (!enabled || input.isEmpty) {
      return finish();
    }
    final limits = worker.limits;
    if (regexUtf8Length(input, stopAfter: limits.maxInputBytes) > limits.maxInputBytes) {
      warnings.add(
        const RegexDisplayWarning(
          ruleId: '',
          ruleName: '',
          ruleIndex: -1,
          reason: 'input-limit',
          message: '显示原文超过保护上限，返回原文。',
        ),
      );
      return finish();
    }
    final substitute = expand ?? _identityExpansion;
    for (var index = 0; index < _scripts.length; index++) {
      if (isCancelled?.call() == true) {
        return finish(cancelled: true);
      }
      final script = _scripts[index];
      if (!script.markdownOnly ||
          script.disabled ||
          (isEdit && !script.runOnEdit) ||
          !script.placement.contains(placement) ||
          result.isEmpty) {
        continue;
      }
      if (depth != null) {
        final minimum = script.minDepth;
        final maximum = script.maxDepth;
        if ((minimum != null && minimum >= -1 && depth < minimum) ||
            (maximum != null && maximum >= 0 && depth > maximum)) {
          continue;
        }
      }
      if (!script._valid) {
        warn(script, index, 'invalid-script', '正则条目的已知字段类型不兼容，已跳过。');
        continue;
      }
      if (script.findRegex.isEmpty) continue;
      if (rules >= limits.maxRules) {
        warn(script, index, 'rule-limit', '本次显示已达规则上限，后续规则跳过。');
        break;
      }
      rules++;
      try {
        final pattern = switch (script.substituteRegex) {
          1 => substitute(script.findRegex),
          2 => substitute(script.findRegex, postProcess: sanitizeRegexMacro),
          _ => script.findRegex,
        };
        if (isCancelled?.call() == true) {
          return finish(cancelled: true);
        }
        final replacementPlan = script._replacement;
        final referenceKeys = replacementPlan.referenceKeys(limits.maxCaptureBytes);
        final captures = await worker.findCaptures(
          pattern,
          result,
          references: referenceKeys,
          maxMatches: limits.maxReplacements - replacements,
        );
        if (isCancelled?.call() == true) {
          return finish(cancelled: true);
        }
        if (captures.compilation.status != RegexCompileStatus.compatible || captures.skipped) {
          warn(script, index, captures.code ?? 'incompatible-pattern', captures.message ?? '正则不兼容或暂不可执行，已跳过。');
          continue;
        }
        if (captures.code == 'literal-fallback') {
          warn(script, index, 'literal-fallback', captures.message!);
        }
        // The worker already checked this unchanged text against maxOutputBytes.
        if (captures.matches.isEmpty) continue;
        final output = _BoundedText(limits.maxOutputBytes);
        var previousEnd = 0;
        for (final match in captures.matches) {
          if (isCancelled?.call() == true) {
            return finish(cancelled: true);
          }
          output.add(result.substring(previousEnd, match.start));
          if (replacements >= limits.maxReplacements) {
            throw const _DisplayLimit('replacement-limit', '本次显示累计替换已达上限。');
          }
          // Attempted replacements also count when a later macro/output check
          // fails. Effects already run remain in the detached display context.
          replacements++;
          final replacement = _replaceDisplayTemplate(
            script,
            replacementPlan,
            (reference) => _captured(match, result, reference),
            substitute,
            characterOverride,
            limits.maxOutputBytes,
          );
          output.add(substitute(replacement));
          previousEnd = match.end;
        }
        output.add(result.substring(previousEnd));
        result = output.toString();
      } on _DisplayLimit catch (error) {
        warn(script, index, error.code, error.message);
      } catch (_) {
        warn(script, index, 'replacement-error', '显示规则的宏或替换失败，保留前一条规则的文本。');
      }
    }
    return finish();
  }

  /// Import checks never execute macros. A dynamic pattern is checked after
  /// its runtime expansion inside the same protected worker path.
  static Future<RegexCompileResult> checkScript(RegexScript script, RegexExecutor executor) async {
    if (!script._valid) {
      return const RegexCompileResult(
        status: RegexCompileStatus.incompatible,
        code: 'invalid-script',
        message: '正则条目的已知字段类型不兼容。',
      );
    }
    if (script.substituteRegex == 1 || script.substituteRegex == 2) {
      return const RegexCompileResult(
        status: RegexCompileStatus.skipped,
        code: 'runtime-check',
        message: '模式依赖运行时宏，执行时再受控编译。',
      );
    }
    return executor.compile(script.findRegex);
  }

  /// Direct execution, like ST's /regex command: placement/phase/edit/depth
  /// selection is bypassed, while disabled and invalid-pattern guards remain.
  String runScript(RegexScript script, String input, {String? characterOverride, RegexMacroExpansion? expand}) =>
      _runScript(script, input, characterOverride: characterOverride, expand: expand);

  String _runScript(
    RegexScript script,
    String input, {
    String? characterOverride,
    RegexMacroExpansion? expand,
    _RegexRunTrace? trace,
    int ruleIndex = -1,
  }) {
    if (script.disabled || input.isEmpty) return input;
    if (!script._valid) {
      trace?.warn(script, ruleIndex, 'invalid-script', 'Regex known fields are incompatible; this rule was skipped.');
      return input;
    }
    if (script.findRegex.isEmpty) return input;
    final substitute = expand ?? _identityExpansion;
    final pattern = switch (script.substituteRegex) {
      1 => substitute(script.findRegex),
      2 => substitute(script.findRegex, postProcess: sanitizeRegexMacro),
      _ => script.findRegex,
    };
    final compiled = _compile(pattern);
    if (compiled == null) {
      trace?.warn(
        script,
        ruleIndex,
        'unsupported-pattern',
        'The expanded regex could not be compiled; this rule was skipped.',
      );
      return input;
    }
    final matches = compiled.global ? compiled.regex.allMatches(input) : compiled.regex.allMatches(input).take(1);
    final output = StringBuffer();
    var previousEnd = 0;
    for (final match in matches) {
      if (trace != null) trace.replacements++;
      output.write(input.substring(previousEnd, match.start));
      final template = script._replacement.template;
      final replacement = _replaceTemplate(
        script,
        template,
        (reference) => _capture(match, input, reference),
        substitute,
        characterOverride,
      );
      output.write(substitute(replacement));
      previousEnd = match.end;
    }
    output.write(input.substring(previousEnd));
    return output.toString();
  }

  /// ST's sanitizeRegexMacro, deliberately different from RegExp.escape:
  /// escapes line controls, slash and regex syntax, but leaves hyphen alone.
  static Object? sanitizeRegexMacro(Object? value) {
    // Legacy ST passes raw number/object macro values here; unlike the new
    // engine, it does not stringify them before this callback.
    if (value is! String) return value;
    const controls = {10: r'\n', 13: r'\r', 9: r'\t', 11: r'\v', 12: r'\f', 0: r'\0'};
    const syntax = r'.^$*+?{}[]\/|()';
    final output = StringBuffer();
    for (final unit in value.codeUnits) {
      final control = controls[unit];
      if (control != null) {
        output.write(control);
      } else {
        final character = String.fromCharCode(unit);
        if (syntax.contains(character)) output.write(r'\');
        output.writeCharCode(unit);
      }
    }
    return output.toString();
  }

  void clearCache() => _cache.clear();

  _CompiledRegex? _compile(String input) {
    final cached = _cache.remove(input);
    if (cached != null) {
      _cache[input] = cached;
      return cached;
    }
    final parsed = _regexFromString(input);
    if (parsed == null) return null;
    if (_cache.length >= 1000) _cache.remove(_cache.keys.first);
    _cache[input] = parsed;
    return parsed;
  }
}

final class _RegexRunTrace {
  final warnings = <RegexDisplayWarning>[];
  int replacements = 0;
  void warn(RegexScript script, int index, String reason, String message) {
    warnings.add(
      RegexDisplayWarning(
        ruleId: script.id,
        ruleName: script.scriptName,
        ruleIndex: index,
        reason: reason,
        message: message,
      ),
    );
  }
}

final _matchMacro = RegExp(r'\{\{match\}\}', caseSensitive: false);
final _captureReference = RegExp(r'\$(\d+)|\$<([^>]+)>');

final class _CompiledRegex {
  const _CompiledRegex(this.regex, this.global);
  final RegExp regex;
  final bool global;
}

_CompiledRegex? _regexFromString(String input) {
  final program = compileRegexProgram(input, RegexDialect.script);
  return program.regex == null ? null : _CompiledRegex(program.regex!, program.global);
}

Object? _capture(RegExpMatch match, String input, Match reference) {
  final number = reference[1];
  if (number != null) {
    final index = int.tryParse(number);
    if (index == null) return null;
    if (index <= match.groupCount) return match[index];
    // Preserve ST 1.19's actual callback-argument indexing, not JavaScript's
    // built-in replacement-string syntax: the next two slots are offset/input.
    if (index == match.groupCount + 1) return match.start;
    if (index == match.groupCount + 2) return input;
    if (index == match.groupCount + 3 && match.groupNames.isNotEmpty) return const _NamedGroups();
    return null;
  }
  final name = reference[2]!;
  return match.groupNames.contains(name) ? match.namedGroup(name) : null;
}

final class _NamedGroups {
  const _NamedGroups();
}

String _identityExpansion(String text, {String? characterOverride, Object? Function(Object?)? postProcess}) => text;

bool _truthy(Object? value) {
  if (value == null || value == false || value == '') return false;
  if (value is num) return value != 0 && !value.isNaN;
  return true;
}

num _number(Object? value) {
  if (value == null || value == false) return 0;
  if (value == true) return 1;
  if (value is num) return value;
  if (value is List) value = _arrayString(value);
  if (value is! String) return double.nan;
  final text = value.replaceAll(_numberWhitespace, '');
  if (text.isEmpty) return 0;
  if (text == 'Infinity' || text == '+Infinity') return double.infinity;
  if (text == '-Infinity') return double.negativeInfinity;
  if (RegExp(r'^0[xX][0-9a-fA-F]+$').hasMatch(text)) {
    return BigInt.tryParse(text.substring(2), radix: 16)?.toDouble() ?? double.nan;
  }
  if (RegExp(r'^0[bB][01]+$').hasMatch(text)) {
    return BigInt.tryParse(text.substring(2), radix: 2)?.toDouble() ?? double.nan;
  }
  if (RegExp(r'^0[oO][0-7]+$').hasMatch(text)) {
    return BigInt.tryParse(text.substring(2), radix: 8)?.toDouble() ?? double.nan;
  }
  if (!RegExp(r'^[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?$').hasMatch(text)) return double.nan;
  return num.tryParse(text) ?? double.nan;
}

final _numberWhitespace = RegExp(
  r'^[\u0009-\u000d\u0020\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]+|'
  r'[\u0009-\u000d\u0020\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]+$',
);

String _arrayString(List<Object?> values) => values
    .map((value) {
      if (value == null) return '';
      if (value is List) return _arrayString(value);
      if (value is Map) return '[object Object]';
      return value.toString();
    })
    .join(',');

String _replaceTemplate(
  RegexScript script,
  String template,
  Object? Function(Match) capture,
  RegexMacroExpansion substitute,
  String? characterOverride,
) => template.replaceAllMapped(
  _captureReference,
  (reference) => _replaceCapture(script, reference, capture(reference), substitute, characterOverride),
);

// The protected path must bound capture expansion before assembling the whole
// replacement. A repeated reference can otherwise allocate far more than the
// output limit before the outer text builder sees the result. Macro callbacks
// still run on the owner; their internal allocations are outside this worker.
String _replaceDisplayTemplate(
  RegexScript script,
  _RegexReplacement plan,
  Object? Function(Match) capture,
  RegexMacroExpansion substitute,
  String? characterOverride,
  int maximum,
) {
  // An existing macro template may itself exceed the output budget and shrink
  // when expanded. Permit its original size, but no extra capture growth past
  // the greater of that size and the output budget. The outer builder still
  // enforces the strict final-output limit after expansion.
  final template = plan.template;
  final output = _BoundedText(plan.templateBytes > maximum ? plan.templateBytes : maximum);
  var offset = 0;
  for (final reference in _captureReference.allMatches(template)) {
    output.add(template.substring(offset, reference.start));
    output.add(_replaceCapture(script, reference, capture(reference), substitute, characterOverride));
    offset = reference.end;
  }
  output.add(template.substring(offset));
  return output.toString();
}

String _replaceCapture(
  RegexScript script,
  Match reference,
  Object? value,
  RegexMacroExpansion substitute,
  String? characterOverride,
) {
  if (!_truthy(value)) {
    return '';
  }
  var filtered = value;
  for (final trim in script.trimStrings) {
    final text = substitute(trim, characterOverride: characterOverride);
    if (filtered is! String) {
      throw StateError('ST regex ${script.scriptName}: ${reference[0]} is not a string capture and cannot be trimmed');
    }
    filtered = filtered.replaceAll(text, '');
  }
  if (filtered is String) {
    return filtered;
  }
  if (filtered is num) {
    return filtered.toString();
  }
  throw StateError('ST regex ${script.scriptName}: ${reference[0]} resolves to the named-groups object');
}

String _referenceKey(Match reference) {
  final number = reference[1];
  return number == null ? 'n:${reference[2]}' : (int.tryParse(number)?.toString() ?? number);
}

Object? _captured(RegexCapture match, String input, Match reference) {
  final number = reference[1];
  if (number != null) {
    final index = int.tryParse(number);
    if (index == null) {
      return null;
    }
    if (index <= match.groupCount) {
      return match.groups[index.toString()];
    }
    if (index == match.groupCount + 1) {
      return match.start;
    }
    if (index == match.groupCount + 2) {
      return input;
    }
    if (index == match.groupCount + 3 && match.hasNamedGroups) {
      return const _NamedGroups();
    }
    return null;
  }
  return match.groups['n:${reference[2]}'];
}

final class _DisplayLimit implements Exception {
  const _DisplayLimit(this.code, this.message);
  final String code;
  final String message;
}

final class _BoundedText {
  _BoundedText(this.maximum);
  final int maximum;
  final _buffer = StringBuffer();
  var _bytes = 0;
  int? _lastUnit;

  void add(String text) {
    if (text.isEmpty) {
      return;
    }
    final previous = _lastUnit;
    final first = text.codeUnitAt(0);
    final joinsPair =
        previous != null && previous >= 0xd800 && previous <= 0xdbff && first >= 0xdc00 && first <= 0xdfff;
    final correction = joinsPair ? 2 : 0;
    final size = regexUtf8Length(text, stopAfter: maximum - _bytes + correction) - correction;
    if (_bytes + size > maximum) {
      throw const _DisplayLimit('output-limit', '规则输出超过保护上限，保留前一条规则的文本。');
    }
    _bytes += size;
    _buffer.write(text);
    _lastUnit = text.codeUnitAt(text.length - 1);
  }

  @override
  String toString() => _buffer.toString();
}
