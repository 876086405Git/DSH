part of '../spreset.dart';

const _spUndefined = _SPresetUndefined();

class _SPresetUndefined {
  const _SPresetUndefined();
}

/// Runs at the GENERATE_AFTER_DATA boundary, before provider post-processing.
/// historyIds identifies the assembler's complete chatHistory collection.
Future<List<PromptSegment>> spresetSquashSegments(
  List<PromptSegment> input,
  SPresetConfig config,
  PromptTokenCounter counter, {
  required String Function(String) expand,
  required SPresetEvaluate evaluate,
  required SPresetDiagnostic diagnose,
  Set<String> historyIds = const {},
}) async {
  if (!config.present) return input;
  final settings = config.chatSquash;
  if (!presetTruthy(settings['enabled'])) {
    if (!presetTruthy(settings['squashed_post_script_enable'])) return input;
    final messages = input.map((segment) => segment.message).toList();
    final processed = await _spPostScript(messages, settings, evaluate, diagnose, array: true);
    final values = processed! as List<Object?>;
    return [
      for (var i = 0; i < values.length; i++)
        PromptSegment(
          id: i < input.length ? input[i].id : 'spreset-post-$i',
          message: values[i]! as Map<String, Object?>,
          collectionId: i < input.length ? input[i].collectionId : null,
          sources: i < input.length ? input[i].sources : const [PromptSource('spreset', 'post-script')],
          tokens: counter.countMessage(values[i]! as Map<String, Object?>),
        ),
    ];
  }
  var prepared = input;
  if (presetTruthy(settings['conditional_enabled'])) {
    final tag = _spString(settings['conditional_tag']);
    if (tag.isEmpty) return input;
    var matched = false;
    Object? remove(Object? value) {
      if (value is String) {
        if (value.contains(tag)) matched = true;
        return value.replaceAll(tag, '');
      }
      if (value is List<Object?>) return value.map(remove).toList();
      if (value is Map<String, Object?>) return value.map((key, item) => MapEntry(key, remove(item)));
      return value;
    }

    prepared = [
      for (final segment in input)
        _spSegment(segment, {...segment.message, 'content': remove(segment.message['content'])}, counter),
    ];
    if (!matched) return input;
  }
  if (!presetTruthy(settings['separate_chat_history'])) {
    return _spSquashGroup(prepared, settings, counter, expand, evaluate, diagnose);
  }
  final output = <PromptSegment>[];
  final group = <PromptSegment>[];
  Future<void> flush() async {
    if (group.isEmpty) return;
    output.addAll(await _spSquashGroup(group, settings, counter, expand, evaluate, diagnose));
    group.clear();
  }

  for (final segment in prepared) {
    if (segment.collectionId == 'chatHistory' || historyIds.contains(segment.id)) {
      group.add(segment);
    } else {
      await flush();
      output.add(segment);
    }
  }
  await flush();
  return output;
}

PromptSegment _spSegment(PromptSegment original, Map<String, Object?> message, PromptTokenCounter counter) =>
    PromptSegment(
      id: original.id,
      message: message,
      sources: original.sources,
      collectionId: original.collectionId,
      tokens: counter.countMessage(message),
    );

Future<Object?> _spPostScript(
  Object? target,
  Map<String, Object?> settings,
  SPresetEvaluate evaluate,
  SPresetDiagnostic diagnose, {
  bool array = false,
}) async {
  if (!presetTruthy(settings['squashed_post_script_enable'])) return target;
  final backup = array ? _spCopy(target) : target;
  try {
    final response = await evaluate(
      'ChatSquash',
      _spString(settings['squashed_post_script']),
      [target],
      sessionId: array ? 'post-messages' : 'post-squashed',
      reset: true,
      kind: TavernSPresetEvaluationKind.syncFunctionExpression,
    );
    final result = response.isUndefined
        ? array && response.arguments.isNotEmpty
              ? response.arguments.first
              : _spUndefined
        : response.value;
    if (array) {
      if (result is! List<Object?>) {
        throw const SPresetException('ChatSquash', 'The message postprocessor must return or mutate an array.');
      }
    }
    return result;
  } catch (error) {
    diagnose('ChatSquash', error);
    return backup;
  }
}

Future<List<PromptSegment>> _spSquashGroup(
  List<PromptSegment> input,
  Map<String, Object?> settings,
  PromptTokenCounter counter,
  String Function(String) expand,
  SPresetEvaluate evaluate,
  SPresetDiagnostic diagnose,
) async {
  final prefixes = {
    'user': expand(_spString(settings['user_prefix'])),
    'assistant': expand(_spString(settings['char_prefix'])),
    'system': expand(_spString(settings['prefix_system'])),
  };
  final suffixes = {
    'user': expand(_spString(settings['user_suffix'])),
    'assistant': expand(_spString(settings['char_suffix'])),
    'system': expand(_spString(settings['suffix_system'])),
  };
  final configuredRole = _spString(settings['role'], 'assistant');
  const mergeRoles = {'user', 'system', 'assistant'};
  final firstRole = _spString(input.firstOrNull?.message['role'], 'user');
  var role = configuredRole == 'follow'
      ? mergeRoles.contains(firstRole)
            ? firstRole
            : 'user'
      : mergeRoles.contains(configuredRole)
      ? configuredRole
      : 'assistant';
  final output = <PromptSegment>[];
  final pieces = <PromptSegment>[];
  var merged = '';
  var previousRole = '';
  Future<void> flush() async {
    if (merged.isEmpty) return;
    if (previousRole.isNotEmpty) merged += suffixes[previousRole]!;
    final text = presetTruthy(settings['parse_clewd']) ? _spClewd(merged, diagnose) : merged;
    final processed = await _spPostScript(text, settings, evaluate, diagnose);
    final sources = pieces.expand((piece) => piece.sources).toList();
    final id = pieces.map((piece) => piece.id).join('+');
    final collectionIds = pieces.map((piece) => piece.collectionId).toSet();
    final collectionId = collectionIds.length == 1 ? collectionIds.single : null;
    final messages = presetTruthy(settings['re_split'])
        ? _spReSplitValue(processed, prefixes, suffixes)
        : <Map<String, Object?>>[
            {'role': role, if (!identical(processed, _spUndefined)) 'content': processed},
          ];
    for (final message in messages) {
      output.add(
        PromptSegment(
          id: id,
          message: message,
          sources: sources,
          collectionId: collectionId,
          tokens: counter.countMessage(message),
        ),
      );
    }
    merged = '';
    previousRole = '';
    pieces.clear();
  }

  String clean(String text) {
    final separator = _spString(settings['squashed_separator_string']);
    if (presetTruthy(settings['enable_squashed_separator']) && separator.isNotEmpty) {
      text = text.replaceFirst(presetTruthy(settings['squashed_separator_regex']) ? RegExp(separator) : separator, '');
    }
    return presetTruthy(settings['parse_clewd']) ? text.replaceFirst('<|no-trans|>', '') : text;
  }

  for (final segment in input) {
    final message = segment.message;
    final sourceRole = _spString(message['role']);
    final content = message['content'];
    final nativePayload =
        !prefixes.containsKey(sourceRole) ||
        message.entries.any((entry) => entry.key != 'role' && entry.key != 'content' && entry.value != null) ||
        (content is List<Object?> &&
            content.any(
              (part) =>
                  part is! String &&
                  (part is! Map<String, Object?> ||
                      part['type'] != 'text' ||
                      part['text'] is! String ||
                      part.keys.any((key) => key != 'type' && key != 'text')),
            )) ||
        (content is Map<String, Object?>);
    if (nativePayload) {
      await flush();
      if (configuredRole == 'follow' && sourceRole == 'tool') {
        output.add(_spSegment(segment, message, counter));
        continue;
      }
      final cleaned = content is String
          ? clean(content)
          : content is List<Object?>
          ? [
              for (final part in content)
                if (part is String)
                  clean(part)
                else if (part is Map<String, Object?> &&
                    part['type'] == 'text' &&
                    part['text'] is String &&
                    part.keys.every((key) => key == 'type' || key == 'text'))
                  {...part, 'text': clean(part['text']! as String)}
                else
                  part,
            ]
          : content;
      output.add(_spSegment(segment, {...message, 'content': cleaned}, counter));
      if (configuredRole == 'follow' && mergeRoles.contains(sourceRole)) role = sourceRole;
      continue;
    }
    if (!presetTruthy(content)) continue;
    var text = content is List<Object?>
        ? content.map((part) => part is String ? part : _spString(_spMap(part)['text'])).join()
        : _spString(content);
    final currentRole = presetTruthy(settings['user_role_system']) && sourceRole == 'system' ? 'user' : sourceRole;
    var separate = false;
    final separator = _spString(settings['squashed_separator_string']);
    if (presetTruthy(settings['enable_squashed_separator']) && separator.isNotEmpty) {
      final pattern = presetTruthy(settings['squashed_separator_regex']) ? RegExp(separator) : separator;
      if (text.contains(pattern)) {
        text = text.replaceFirst(pattern, '');
        separate = true;
      }
    }
    if (!separate && presetTruthy(settings['parse_clewd']) && text.contains('<|no-trans|>')) {
      separate = true;
      text = text.replaceFirst('<|no-trans|>', '');
    }
    if (separate) {
      await flush();
      output.add(_spSegment(segment, {...message, 'role': currentRole, 'content': text}, counter));
      if (configuredRole == 'follow' && mergeRoles.contains(currentRole)) role = currentRole;
      continue;
    }
    if (currentRole == previousRole) {
      merged += '\n';
    } else {
      if (previousRole.isNotEmpty) merged += suffixes[previousRole]!;
      merged += prefixes[currentRole]!;
    }
    merged += text;
    previousRole = currentRole;
    pieces.add(segment);
  }
  await flush();
  return output;
}

List<Map<String, Object?>> _spReSplitValue(Object? value, Map<String, String> prefixes, Map<String, String> suffixes) {
  if (value is String) return _spReSplit(value, prefixes, suffixes);
  if (value == null || identical(value, _spUndefined)) {
    throw const SPresetException('ChatSquash/re_split', 'Cannot read length from null or undefined.');
  }
  final length = value is List<Object?>
      ? value.length
      : value is Map<String, Object?>
      ? value['length']
      : null;
  if (presetJsNumber(length) > 0 && prefixes.values.any((prefix) => prefix.isNotEmpty)) {
    throw const SPresetException('ChatSquash/re_split', 'remaining.startsWith is not a function.');
  }
  return [];
}

List<Map<String, Object?>> _spReSplit(String text, Map<String, String> prefixes, Map<String, String> suffixes) {
  final messages = <Map<String, Object?>>[];
  var remaining = text;
  while (remaining.isNotEmpty) {
    final role = prefixes.keys
        .where((role) => prefixes[role]!.isNotEmpty && remaining.startsWith(prefixes[role]!))
        .firstOrNull;
    if (role == null) break;
    remaining = remaining.substring(prefixes[role]!.length);
    var end = remaining.length;
    for (final prefix in prefixes.values.where((value) => value.isNotEmpty)) {
      final index = remaining.indexOf(prefix);
      if (index >= 0 && index < end) end = index;
    }
    var content = remaining.substring(0, end);
    final suffix = suffixes[role]!;
    if (suffix.isNotEmpty && content.endsWith(suffix)) content = content.substring(0, content.length - suffix.length);
    content = trimJsWhitespace(content);
    if (content.isNotEmpty) messages.add({'role': role, 'content': content});
    remaining = remaining.substring(end);
  }
  return messages;
}

String _spClewd(String text, SPresetDiagnostic diagnose) {
  for (final order in const [1, 2, 3]) {
    final prefix = '<regex(?: +order *= *$order)${order == 2 ? '?' : ''}';
    final matches = RegExp(
      prefix + r'> *"(/?)(.*)\1(.*?)" *: *"(.*?)" *</regex>',
      multiLine: true,
    ).allMatches(text).toList();
    for (final match in matches) {
      try {
        final flags = match[3]!;
        if (flags.split('').toSet().length != flags.length || RegExp(r'[^gimsuyd]').hasMatch(flags)) {
          throw const SPresetException('ChatSquash', 'Unsupported embedded regex flags.');
        }
        final regex = RegExp(
          match[2]!,
          caseSensitive: !flags.contains('i'),
          multiLine: flags.contains('m'),
          dotAll: flags.contains('s'),
          unicode: flags.contains('u'),
        );
        final replacement = jsonDecode('"${match[4]!.replaceAll(RegExp(r'\\?"'), r'\"')}"') as String;
        text = _spReplaceRegex(
          text,
          regex,
          replacement,
          global: flags.contains('g'),
          sticky: flags.contains('y'),
          unicode: flags.contains('u'),
        );
      } catch (error) {
        diagnose('ChatSquash/regex', error);
      }
    }
  }
  text = text
      .replaceAll(RegExp(r'<regex( +order *= *\d)?>.*?</regex>', multiLine: true), '')
      .replaceAll(RegExp(r'\r\n|\r', multiLine: true), '\n')
      .replaceAll(RegExp(r'\s*<\|curtail\|>\s*'), '\n')
      .replaceAll(RegExp(r'\s*<\|join\|>\s*'), '')
      .replaceAll(RegExp(r'\s*<\|space\|>\s*'), ' ')
      .replaceAllMapped(RegExp(r'<\|(\\.*?)\|>'), (match) {
        try {
          return jsonDecode('"${match[1]!}"') as String;
        } catch (_) {
          return match[0]!;
        }
      });
  text = trimJsWhitespace(text.replaceAll(RegExp(r'\s*<\|.*?\|>\s*'), '\n\n'));
  text = text.replaceFirstMapped(RegExp(r'^.+:'), (match) => '\n\n${match[0]!}');
  return text.replaceAll(RegExp(r'(?<=\n)\n(?=\n)'), '');
}

String _spReplaceRegex(
  String input,
  RegExp regex,
  String replacement, {
  required bool global,
  required bool sticky,
  required bool unicode,
}) {
  if (!sticky) {
    var changed = false;
    return input.replaceAllMapped(regex, (match) {
      if (!global && changed) return match[0]!;
      changed = true;
      return _spReplacement(replacement, match, input);
    });
  }
  final output = StringBuffer();
  var offset = 0;
  var lastEnd = 0;
  while (offset <= input.length) {
    final match = regex.matchAsPrefix(input, offset);
    if (match == null) break;
    output.write(input.substring(lastEnd, match.start));
    output.write(_spReplacement(replacement, match, input));
    lastEnd = match.end;
    if (!global) break;
    offset = match.end;
    if (match.start == match.end) {
      final paired =
          unicode &&
          offset + 1 < input.length &&
          input.codeUnitAt(offset) >= 0xd800 &&
          input.codeUnitAt(offset) <= 0xdbff &&
          input.codeUnitAt(offset + 1) >= 0xdc00 &&
          input.codeUnitAt(offset + 1) <= 0xdfff;
      offset += paired ? 2 : 1;
    }
  }
  output.write(input.substring(lastEnd));
  return output.toString();
}

String _spReplacement(String replacement, Match match, String input) =>
    replacement.replaceAllMapped(RegExp(r'\$([$&`\x27]|\d{1,2}|<[^>]+>)'), (token) {
      final value = token[1]!;
      if (value == r'$') return r'$';
      if (value == '&') return match[0]!;
      if (value == '`') return input.substring(0, match.start);
      if (value == "'") return input.substring(match.end);
      if (value.startsWith('<') && match is RegExpMatch) {
        try {
          return match.namedGroup(value.substring(1, value.length - 1)) ?? '';
        } on ArgumentError {
          return match.groupNames.isEmpty ? token[0]! : '';
        }
      }
      final index = int.tryParse(value);
      if (index != null && index > 0 && index <= match.groupCount) return match[index] ?? '';
      if (value.length == 2 && index != null && index ~/ 10 > 0 && index ~/ 10 <= match.groupCount) {
        return (match[index ~/ 10] ?? '') + value[1];
      }
      return token[0]!;
    });

List<Object?> spresetStops(SPresetConfig config, List<Object?> stops) {
  final data = <String, Object?>{'stop': stops};
  spresetApplyStops(config, data);
  return data['stop']! as List<Object?>;
}

/// The source event mutates the request: absence/falsy stop and an existing
/// (even empty) array take different branches. JSON string stops use substring
/// includes and Unicode iteration, not array-only validation.
void spresetApplyStops(SPresetConfig config, Map<String, Object?> data) {
  final settings = config.chatSquash;
  if (!presetTruthy(settings['enabled']) || !presetTruthy(settings['enable_stop_string'])) return;
  final source = _spString(settings['stop_string']);
  if (source.isEmpty) return;
  Object? value;
  try {
    value = jsonDecode(source);
  } on FormatException {
    value = [source];
  }
  final stops = data['stop'];
  if (!presetTruthy(stops)) {
    data['stop'] = value;
    return;
  }
  if (stops is! List<Object?>) {
    throw const SPresetException('ChatSquash/stop', 'data.stop.filter is not a function.');
  }
  bool includes(Object? item) {
    if (value is List<Object?>) return value.contains(item);
    if (value is String) return value.contains(presetString(item));
    throw const SPresetException('ChatSquash/stop', 'custom_stopping_strings.includes is not a function.');
  }

  final filtered = stops.where((stop) => !includes(stop)).toList();
  data['stop'] = filtered;
  if (value is List<Object?>) {
    filtered.addAll(value);
  } else if (value is String) {
    filtered.addAll(value.runes.map(String.fromCharCode));
  } else {
    throw const SPresetException('ChatSquash/stop', 'custom_stopping_strings is not iterable.');
  }
}
