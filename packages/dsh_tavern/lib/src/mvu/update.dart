// Ported from MagicalAstrogy/MagVarUpdate, src/function/update_variables.ts,
// commit d03b7dc8a6ebf9bd611c7e2dc91f3b35462deebc.
// Copyright (c) 2025 MagicalAstrogy & StageDog. MIT; see THIRD_PARTY_NOTICES.md.

part of 'mvu.dart';

/// Computes an independent MVU candidate without storage I/O.
/// Expansion and phase callbacks are awaited and can have their own effects.
Future<MvuResult> updateMvu(
  String message,
  MvuJson previous, {
  bool blocksOnly = false,
  MvuExpand? expand,
  MvuPhaseHook? onPhase,
}) async {
  var data = _mvuJson(previous) as MvuJson;
  var before = _copyMvuMap(data);
  var displayExists = data.containsKey('stat_data');
  Object? display = _copyMvu(data['stat_data']);
  var deltaExists = true;
  Object? delta = <String, Object?>{};
  void reconnectDerived(bool hadChannel) {
    final state = data['stat_data'];
    final hasChannel = state is MvuJson && state.containsKey(r'$internal');
    if (!hasChannel && !hadChannel) {
      return;
    }
    final channel = state is MvuJson ? state[r'$internal'] : null;
    if (channel is MvuJson) {
      displayExists = channel.containsKey('display_data');
      deltaExists = channel.containsKey('delta_data');
      display = channel['display_data'];
      delta = channel['delta_data'];
    } else {
      displayExists = false;
      deltaExists = false;
      display = null;
      delta = null;
    }
  }

  final expanded = expand == null ? message : await expand(message);
  final issues = <MvuIssue>[];
  var commands = _mvuExtractCommands(expanded, issues, blocksOnly: blocksOnly);
  // Named array properties are not JSON. Only map roots expose this transient
  // channel; every root retains its actual value and presence.
  final state = data['stat_data'];
  if (state is MvuJson) {
    state[r'$internal'] = <String, Object?>{if (displayExists) 'display_data': display, 'delta_data': delta};
  }
  if (onPhase != null) {
    final hadChannel = state is MvuJson && state.containsKey(r'$internal');
    final phase = MvuPhase(kind: MvuPhaseKind.started, data: data);
    await onPhase(phase);
    data = _mvuJson(phase.data) as MvuJson;
    reconnectDerived(hadChannel);
  }
  // Strict flags are frozen after started. The JSON feedback profile reconnects
  // the executable schema to parsed's returned value; it cannot distinguish a
  // JavaScript in-place schema mutation from replacing the same JSON object.
  var schema = data['schema'];
  final options = schema is MvuJson ? schema : const <String, Object?>{};
  final strictSet = _mvuTruthy(options['strictSet']);
  final strictTemplate = _mvuTruthy(options['strictTemplate']);
  final concatArrays = options['concatTemplateArray'] == null || _mvuTruthy(options['concatTemplateArray']);
  for (final command in commands) {
    command.type = _mvuCommandType(command.type);
  }
  if (onPhase != null) {
    final currentState = data['stat_data'];
    final hadChannel = currentState is MvuJson && currentState.containsKey(r'$internal');
    final phase = MvuPhase(kind: MvuPhaseKind.parsed, data: data, commands: commands, originalMessage: message);
    await onPhase(phase);
    data = _mvuJson(phase.data) as MvuJson;
    reconnectDerived(hadChannel);
    schema = data['schema'];
    commands = [
      for (final command in phase.commands)
        MvuCommand(
          type: command.type,
          fullMatch: command.fullMatch,
          args: _mvuJson(command.args) as List<Object?>,
          reason: command.reason,
          offset: command.offset,
        ),
    ];
    for (final command in commands) {
      if (command.args.isEmpty || command.args.first is! String) {
        throw const FormatException('A returned MVU command requires a string path.');
      }
    }
  }
  for (final command in commands) {
    if (!_mvuCommandArity(command.type, command.args.length) || command.args.first is! String) {
      _mvuCommandIssue(issues, command, 'invalid_command', 'The command requires a string path and valid arguments.');
      continue;
    }
    try {
      final rawPath = command.args.first as String;
      final path = command.reason == 'json_patch' ? rawPath : _mvuFixPath(_mvuTrimQuoted(rawPath));
      final tokens = _mvuPath(path);
      final result = _mvuExecuteCommand(
        data,
        command,
        path,
        tokens,
        issues,
        schema: schema,
        strictSet: strictSet,
        strictTemplate: strictTemplate,
        concatArrays: concatArrays,
      );
      if (result != null && result.isNotEmpty) {
        _mvuSetAt(display, command.reason == 'json_patch' ? tokens : _mvuDataPath(display, path, tokens), result);
        _mvuSetAt(delta, command.reason == 'json_patch' ? tokens : _mvuDataPath(delta, path, tokens), result);
      }
    } on FormatException catch (error) {
      // Input/protocol failures are per-command; unexpected failures propagate.
      _mvuCommandIssue(issues, command, 'invalid_command', error.message);
    }
  }
  if (displayExists) {
    data['display_data'] = display;
  } else {
    data.remove('display_data');
  }
  if (deltaExists) {
    data['delta_data'] = delta;
  } else {
    data.remove('delta_data');
  }
  if (onPhase != null) {
    final phase = MvuPhase(kind: MvuPhaseKind.ended, data: data, beforeData: before);
    await onPhase(phase);
    data = _mvuJson(phase.data) as MvuJson;
    final replacement = phase.beforeData;
    if (replacement != null) {
      before = _mvuJson(replacement) as MvuJson;
    }
  }
  final finalState = data['stat_data'];
  if (finalState is MvuJson) {
    finalState.remove(r'$internal');
  }
  if (data.containsKey('stat_data') != before.containsKey('stat_data') ||
      !_mvuEqual(data['stat_data'], before['stat_data'])) {
    _mvuReconcileSchema(data);
  }
  return MvuResult(data, issues);
}

String _mvuCommandType(String type) => switch (type) {
  'remove' || 'unset' => 'delete',
  'assign' => 'insert',
  _ => type,
};

void _mvuCommandIssue(List<MvuIssue> issues, MvuCommand command, String code, String message) {
  issues.add(MvuIssue(code, message, source: command.fullMatch, offset: command.offset));
}

String _mvuTrimQuoted(String value) =>
    value.replaceFirstMapped(RegExp(r"""^[\\"'` ]*(.*?)[\\"'` ]*$"""), (match) => match.group(1)!);

String _mvuFixPath(String path) {
  final brackets = path.replaceAllMapped(RegExp(r'\[([^\]]*)\]'), (match) {
    var inner = match.group(1)!.trim();
    if (inner.isEmpty) {
      return '[]';
    }
    var quoted = false;
    if (inner.length >= 2 && (inner.startsWith('"') || inner.startsWith("'")) && inner[inner.length - 1] == inner[0]) {
      quoted = true;
      inner = inner.substring(1, inner.length - 1);
    }
    if (RegExp(r'^\d+$').hasMatch(inner) && !quoted) {
      return '[$inner]';
    }
    if (RegExp(r'\s').hasMatch(inner) || quoted && RegExp(r'^\d+$').hasMatch(inner)) {
      final escaped = inner.replaceAll('"', '\\"');
      return '["$escaped"]';
    }
    return '[$inner]';
  });
  return brackets.replaceAllMapped(RegExp(r"""(^|\.)(["'])([^"']*)\2(?=\.|\[|$)"""), (match) {
    final prefix = match.group(1)!;
    final name = match.group(3)!;
    if (!RegExp(r'\s|[.\[\]]').hasMatch(name)) {
      return '$prefix$name';
    }
    final escaped = name.replaceAll('"', '\\"');
    return '["$escaped"]';
  });
}

/// Shared lodash-style tokens. Empty input is the schema root; data operations
/// separately retain the empty-string property's original semantics.
List<String> _mvuPath(String path) {
  if (path.isEmpty) {
    return const [];
  }
  var bracket = false;
  var quote = '';
  var escaped = false;
  for (var index = 0; index < path.length; index++) {
    final character = path[index];
    if (quote.isNotEmpty) {
      if (escaped) {
        escaped = false;
      } else if (character == '\\') {
        escaped = true;
      } else if (character == quote) {
        quote = '';
      }
      continue;
    }
    if (bracket && (character == '"' || character == "'")) {
      quote = character;
    } else if (character == '[') {
      if (bracket) {
        throw const FormatException('Nested path brackets must be quoted.');
      }
      bracket = true;
    } else if (character == ']') {
      if (!bracket) {
        throw const FormatException('The path has an unmatched closing bracket.');
      }
      bracket = false;
    }
  }
  if (bracket || quote.isNotEmpty) {
    throw const FormatException('The path has an incomplete bracket or quote.');
  }
  final tokens = <String>[if (path.startsWith('.')) ''];
  final pattern = RegExp(
    r"""[^.[\]]+|\[(?:(-?\d+(?:\.\d+)?)|(["'])((?:(?!\2)[^\\]|\\.)*?)\2)\]|(?=(?:\.|\[\])(?:\.|\[\]|$))""",
  );
  for (final match in pattern.allMatches(path)) {
    if (match.group(2) != null) {
      tokens.add(match.group(3)!.replaceAllMapped(RegExp(r'\\(\\)?'), (escape) => escape.group(1) ?? ''));
    } else {
      tokens.add(match.group(1) ?? match.group(0)!);
    }
  }
  if (tokens.isEmpty) {
    throw const FormatException('The path has no property.');
  }
  return tokens;
}

List<String> _mvuDataPath(Object? root, String path, List<String> parsed) {
  if (root is MvuJson && root.containsKey(path)) {
    return [path];
  }
  return parsed;
}

int? _mvuArrayIndex(String key) {
  if (!RegExp(r'^(?:0|[1-9]\d*)$').hasMatch(key)) {
    return null;
  }
  return int.tryParse(key);
}

({bool exists, Object? value}) _mvuAt(Object? root, List<String> segments) {
  Object? current = root;
  final path = segments.isEmpty ? const [''] : segments;
  for (final key in path) {
    if (current is MvuJson && current.containsKey(key)) {
      current = current[key];
    } else if (current is List<Object?>) {
      final index = _mvuArrayIndex(key);
      if (index == null || index >= current.length) {
        return (exists: false, value: null);
      }
      current = current[index];
    } else {
      return (exists: false, value: null);
    }
  }
  return (exists: true, value: current);
}

bool _mvuPutMember(Object? target, String key, Object? value) {
  if (target is MvuJson) {
    target[key] = value;
    return true;
  }
  if (target is List<Object?>) {
    final index = _mvuArrayIndex(key);
    if (index == null) {
      return false;
    }
    while (target.length <= index) {
      target.add(null);
    }
    target[index] = value;
    return true;
  }
  return false;
}

bool _mvuSetAt(Object? root, List<String> segments, Object? value) {
  final path = segments.isEmpty ? const [''] : segments;
  Object? parent = root;
  for (var index = 0; index < path.length - 1; index++) {
    final key = path[index];
    final found = _mvuAt(parent, [key]);
    var next = found.value;
    if (next is! MvuJson && next is! List<Object?>) {
      next = _mvuArrayIndex(path[index + 1]) == null ? <String, Object?>{} : <Object?>[];
      if (!_mvuPutMember(parent, key, next)) {
        return false;
      }
    }
    parent = next;
  }
  return _mvuPutMember(parent, path.last, value);
}

bool _mvuUnsetAt(Object? root, List<String> segments) {
  final path = segments.isEmpty ? const [''] : segments;
  final parent = path.length == 1 ? root : _mvuAt(root, path.sublist(0, path.length - 1)).value;
  if (parent is MvuJson) {
    parent.remove(path.last);
    return true;
  }
  if (parent is List<Object?>) {
    final index = _mvuArrayIndex(path.last);
    if (index != null && index < parent.length) {
      parent[index] = null; // lodash unset's array hole serializes as JSON null.
      return true;
    }
  }
  return false;
}

bool _mvuVwd(Object? value) => value is List<Object?> && value.length == 2 && value[1] is String;

String? _mvuExecuteCommand(
  MvuJson data,
  MvuCommand command,
  String path,
  List<String> tokens,
  List<MvuIssue> issues, {
  required Object? schema,
  required bool strictSet,
  required bool strictTemplate,
  required bool concatArrays,
}) {
  final state = data['stat_data'];
  final dataPath = command.reason == 'json_patch' ? tokens : _mvuDataPath(state, path, tokens);
  final found = _mvuAt(state, dataPath);
  final reason = command.reason.isEmpty ? '' : '(${command.reason})';
  String? reject(String code, String message) {
    _mvuCommandIssue(issues, command, code, message);
    return null;
  }

  switch (_mvuCommandType(command.type)) {
    case 'set':
      if (path.isNotEmpty && !found.exists) {
        return reject('command_path_missing', 'The set path does not exist: $path.');
      }
      var oldValue = path.isEmpty ? _copyMvu(state) : found.value;
      final newValue = _mvuParseArgument(command.args.last);
      var isVwd = false;
      if (!strictSet &&
          oldValue is List<Object?> &&
          oldValue.length == 2 &&
          oldValue[1] is String &&
          oldValue.first is! List<Object?>) {
        final pair = oldValue;
        final original = _copyMvu(pair.first);
        final Object? next;
        if (pair.first is num && newValue != null) {
          next = _mvuNumber(newValue);
          if (next == null) {
            return reject('command_value', 'The numeric VWD value cannot be converted to a finite number.');
          }
        } else {
          next = newValue;
        }
        pair[0] = next;
        oldValue = original;
        isVwd = true;
      } else if (oldValue is num && newValue is String) {
        final number = _mvuNumber(newValue);
        if (number == null) {
          return reject('command_value', 'The numeric value cannot be converted to a finite number.');
        }
        // The numeric-root/string branch calls lodash.set on the primitive,
        // rather than replacing the root. Preserve that historical no-op.
        if (path.isNotEmpty && !_mvuSetAt(state, dataPath, number)) {
          return reject('command_target', 'The path does not have a writable JSON container.');
        }
      } else if (path.isEmpty) {
        data['stat_data'] = newValue;
      } else if (!_mvuSetAt(state, dataPath, newValue)) {
        return reject('command_target', 'The path does not have a writable JSON container.');
      }
      Object? finalValue = path.isEmpty ? data['stat_data'] : _mvuAt(state, dataPath).value;
      if (isVwd) {
        finalValue = (finalValue as List<Object?>).first;
      }
      if (!strictSet && _mvuVwd(oldValue) && finalValue is List<Object?>) {
        oldValue = (oldValue as List<Object?>).first;
        finalValue = finalValue.isEmpty ? null : finalValue.first;
      }
      return '${_mvuTrimQuoted(_mvuJsonText(oldValue))}->${_mvuTrimQuoted(_mvuJsonText(finalValue))} $reason';

    case 'insert':
      final existing = path.isEmpty ? (exists: data.containsKey('stat_data'), value: state) : found;
      final targetSchema = _mvuSchemaAt(schema, tokens);
      if (!existing.exists ||
          existing.value != null && existing.value is! MvuJson && existing.value is! List<Object?>) {
        return reject('command_target', 'Insertion requires an existing collection or null target: $path.');
      }
      final Object? key = command.args.length >= 3 ? _mvuParseArgument(command.args[1]) : null;
      if (targetSchema != null) {
        if (targetSchema['type'] == 'object' && targetSchema['extensible'] == false) {
          if (command.args.length == 2) {
            return reject('command_schema', 'Cannot merge into a non-extensible object: $path.');
          }
          final properties = targetSchema['properties'];
          final name = _mvuString(key);
          if (!_mvuAt(properties, _mvuDataPath(properties, name, _mvuPath(name))).exists) {
            return reject('command_schema', 'The object schema does not declare the insertion key: $name.');
          }
        } else if (targetSchema['type'] == 'array' &&
            (!targetSchema.containsKey('extensible') || targetSchema['extensible'] == false)) {
          return reject('command_schema', 'The array schema does not permit insertion: $path.');
        }
      } else if (path.isNotEmpty && !_mvuTruthy(_mvuAt(state, tokens.take(tokens.length - 1).toList()).value)) {
        return reject('command_path_missing', 'Insertion requires an existing parent: $path.');
      }
      final value = _mvuParseArgument(command.args[command.args.length == 2 ? 1 : 2]);
      Object? collection = existing.value;
      if (collection is! MvuJson && collection is! List<Object?>) {
        collection = command.args.length == 2 && value is List<Object?> ? <Object?>[] : <String, Object?>{};
        if (!_mvuSetAt(state, dataPath, collection)) {
          return reject('command_target', 'The insertion target has no writable JSON parent.');
        }
      }
      String description;
      if (command.args.length == 2) {
        if (collection is List<Object?>) {
          Object? template;
          if (targetSchema != null && targetSchema['type'] == 'array') {
            template = targetSchema['template'];
          }
          final inserted = _mvuApplyTemplate(
            value,
            template,
            strictArrayCast: strictTemplate,
            concatArrays: concatArrays,
          );
          collection.add(inserted);
          description = "ASSIGNED ${_mvuJsonText(inserted)} into array '$path' $reason";
        } else if (value is MvuJson) {
          _mvuMerge(collection, value);
          description = "MERGED object ${_mvuJsonText(value)} into object '$path' $reason";
        } else {
          return reject('command_type', 'Only an object can be merged into an object: $path.');
        }
      } else {
        Object? template;
        if (targetSchema != null && const {'object', 'array'}.contains(targetSchema['type'])) {
          template = targetSchema['template'];
        }
        final inserted = _mvuApplyTemplate(
          value,
          template,
          strictArrayCast: strictTemplate,
          concatArrays: concatArrays,
        );
        if (collection is List<Object?> && (key is num || key == '-')) {
          final rawIndex = key == '-' ? collection.length : (key as num).toInt();
          final index = rawIndex < 0
              ? math.max(0, collection.length + rawIndex)
              : math.min(rawIndex, collection.length);
          collection.insert(index, inserted);
          final position = key == '-' || key == -1 ? 'tail' : _mvuString(key);
          description = "ASSIGNED ${_mvuJsonText(inserted)} into '$path' at index $position $reason";
        } else {
          final name = _mvuString(key);
          if (!_mvuPutMember(collection, name, inserted)) {
            return reject(
              'command_target',
              'A JSON array requires an index; named array properties are not persisted.',
            );
          }
          description = "ASSIGNED key '$name' with value ${_mvuJsonText(inserted)} into object '$path' $reason";
        }
      }
      final current = path.isEmpty ? data['stat_data'] : _mvuAt(state, dataPath).value;
      try {
        final nextSchema = _mvuGenerateSchema(current, previous: targetSchema);
        if (targetSchema != null) {
          _mvuMerge(targetSchema, nextSchema);
        }
        _mvuCleanMetadata(current);
      } on FormatException catch (error) {
        _mvuCommandIssue(issues, command, 'template_resolution', error.message);
      }
      return description;

    case 'delete':
      // This shortcut precedes schema checks and display/delta writes upstream.
      if (command.args.length == 1 && tokens.isNotEmpty && RegExp(r'^\d+$').hasMatch(tokens.last)) {
        final parentPath = tokens.sublist(0, tokens.length - 1);
        final container = _mvuAt(state, parentPath).value;
        final index = int.tryParse(tokens.last);
        if (container is List<Object?> && index != null && index < container.length) {
          container.removeAt(index);
          return null;
        }
      }
      if (!found.exists) {
        return reject('command_path_missing', 'The remove path does not exist: $path.');
      }
      var containerTokens = tokens;
      Object? key;
      if (command.args.length > 1) {
        key = _mvuParseArgument(command.args[1]);
        if (key is String) {
          key = _mvuTrimQuoted(key);
        }
      } else {
        if (tokens.isEmpty || tokens.last.isEmpty) {
          return reject('command_target', 'The removal target cannot be determined.');
        }
        final last = tokens.last;
        key = RegExp(r'^\d+$').hasMatch(last) ? num.tryParse(last) : last;
        containerTokens = tokens.sublist(0, tokens.length - 1);
      }
      if (containerTokens.isNotEmpty && !_mvuAt(state, containerTokens).exists) {
        return reject('command_path_missing', 'The removal container does not exist.');
      }
      final containerSchema = _mvuSchemaAt(schema, containerTokens);
      if (containerSchema != null) {
        if (containerSchema['type'] == 'array' && containerSchema['extensible'] != true) {
          return reject('command_schema', 'The array schema does not permit removal: $path.');
        }
        if (containerSchema['type'] == 'object') {
          final properties = containerSchema['properties'];
          final child = properties is MvuJson ? properties[_mvuString(key)] : null;
          if (child is MvuJson && child['required'] == true) {
            return reject('command_schema', 'The property is required by its schema: $key.');
          }
        }
      }
      if (command.args.length == 1) {
        if (!_mvuUnsetAt(state, dataPath)) {
          return reject('command_target', 'The removal target has no writable JSON container.');
        }
        return "REMOVED path '$path' $reason";
      }
      final target = _mvuParseArgument(command.args[1]);
      final collection = found.value;
      if (collection is List<Object?>) {
        final num index = target is num ? target : collection.indexWhere((item) => _mvuEqual(item, target));
        if (index < 0 || index >= collection.length) {
          return reject('command_target', 'The array removal target was not found: $path.');
        }
        collection.removeAt(index.toInt());
        return "REMOVED item from '$path' $reason";
      }
      if (collection is MvuJson) {
        if (target is num) {
          final keys = _mvuKeys(collection);
          if (target < 0 || target >= keys.length || target != target.truncateToDouble()) {
            return reject('command_target', 'The object property index was not found: $path.');
          }
          final name = keys[target.toInt()];
          _mvuUnsetAt(collection, _mvuDataPath(collection, name, _mvuPath(name)));
          final ordinal = _mvuString(target + 1);
          return "REMOVED ${ordinal}th entry ('$name') from object '$path' $reason";
        }
        final name = _mvuString(target);
        if (!_mvuAt(collection, _mvuDataPath(collection, name, _mvuPath(name))).exists) {
          return reject('command_target', 'The object removal key was not found: $name.');
        }
        collection.remove(name);
        return "REMOVED key '$name' from object '$path' $reason";
      }
      return reject('command_type', 'Removal requires a collection: $path.');

    case 'add':
      if (!found.exists) {
        return reject('command_path_missing', 'The add path does not exist: $path.');
      }
      final oldValue = found.value;
      final initial = _copyMvu(oldValue);
      final pair = _mvuVwd(oldValue) ? oldValue as List<Object?> : null;
      final isVwd = pair != null && pair.first != null && pair.first is! MvuJson && pair.first is! List<Object?>;
      final value = isVwd ? (oldValue as List<Object?>).first : oldValue;
      final delta = _mvuParseArgument(command.args[1]);
      if (delta is! num) {
        return reject('command_type', 'A numeric or date delta must be a number: $path.');
      }
      Object? next;
      final date = value is String ? _mvuIsoDate(value) : null;
      if (date != null) {
        final millis = date.millisecondsSinceEpoch + delta;
        if (!millis.isFinite || millis.abs() > 8640000000000000) {
          return reject('command_value', 'The date delta is outside the ISO date range.');
        }
        next = DateTime.fromMillisecondsSinceEpoch(millis.toInt(), isUtc: true).toIso8601String();
      } else if (value is num) {
        final number = value + delta;
        if (!number.isFinite) {
          return reject('command_value', 'The numeric update must remain finite.');
        }
        next = num.parse(number.toStringAsPrecision(12));
      } else {
        return reject('command_type', 'Add requires a numeric value or an ISO date: $path.');
      }
      if (isVwd) {
        (oldValue as List<Object?>)[0] = next;
      } else if (!_mvuSetAt(state, dataPath, next)) {
        return reject('command_target', 'The add target has no writable JSON container.');
      }
      final finalValue = _mvuAt(state, dataPath).value;
      final oldText = _mvuJsonText(isVwd ? (initial as List<Object?>).first : initial);
      final newText = _mvuJsonText(isVwd ? (finalValue as List<Object?>).first : finalValue);
      return '$oldText->$newText $reason';
  }
  return reject('invalid_command', 'Unsupported MVU command: ${command.type}.');
}

DateTime? _mvuIsoDate(String value) {
  final dateOnly = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value);
  if (dateOnly != null) {
    final month = int.parse(dateOnly.group(2)!);
    final day = int.parse(dateOnly.group(3)!);
    if (month < 1 || month > 12 || day < 1 || day > 31) {
      return null;
    }
    return DateTime.tryParse('${value}T00:00:00.000Z');
  }
  final dateTime = RegExp(
    r'^(\d{4}|[+-]\d{6})-(\d{2})-(\d{2})[Tt](\d{2}):(\d{2})(?::(\d{2})(?:\.(\d+))?)?(?:[Zz]|[+-](\d{2}):?(\d{2}))$',
  ).firstMatch(value);
  if (dateTime == null || dateTime.group(1) == '-000000') {
    return null;
  }
  final month = int.parse(dateTime.group(2)!);
  final day = int.parse(dateTime.group(3)!);
  final hour = int.parse(dateTime.group(4)!);
  final minute = int.parse(dateTime.group(5)!);
  final second = int.parse(dateTime.group(6) ?? '0');
  final fraction = dateTime.group(7) ?? '';
  final offsetHour = int.parse(dateTime.group(8) ?? '0');
  final offsetMinute = int.parse(dateTime.group(9) ?? '0');
  if (month < 1 ||
      month > 12 ||
      day < 1 ||
      day > 31 ||
      hour > 24 ||
      minute > 59 ||
      second > 59 ||
      offsetHour > 23 ||
      offsetMinute > 59 ||
      hour == 24 && (minute != 0 || second != 0 || RegExp(r'[1-9]').hasMatch(fraction))) {
    return null;
  }
  // Keep the source's day-of-month rollover (for example February 31) and
  // exactly 24:00, while rejecting overflow in the other ISO components.
  return DateTime.tryParse(value)?.toUtc();
}
