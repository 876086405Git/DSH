// SillyTavern public/scripts/world-info.js and utils.js, AGPL-3.0,
// commit 7e8663cd9c184a550b37238218bdd32c6efc68e9. cyrb53 by bryc, public domain/MIT.
part of 'world_info.dart';

/// Per-evaluation state. The caller's metadata and books are never mutated.
class _TimedEffects {
  _TimedEffects(this.input, this.entries, this.pack)
    : _state = jsonDecode(jsonEncode(input.timedWorldInfo)) as Map<String, Object?>,
      _arrayLengths = {} {
    for (final type in const ['sticky', 'cooldown']) {
      final raw = _state[type];
      if (raw is List<Object?>) _arrayLengths[type] = raw.length;
      final values = _object(_state[type]);
      values.removeWhere((key, value) => value is! Map<String, Object?> && value is! List<Object?>);
      _state[type] = values;
    }
    if (!input.dryRun) {
      _check('sticky');
      _check('cooldown');
    }
    for (final item in entries) {
      if (item.packSource != null) {
        continue;
      }
      final delay = item.entry._fields['delay'];
      if (_truthy(delay) && input.messageCount < _jsNumber(delay)) active['delay']!.add(item.hash);
    }
  }

  final WorldInfoInput input;
  final List<_RuntimeEntry> entries;
  final _PackWorldInfoState pack;
  final Map<String, Object?> _state;
  final Map<String, int> _arrayLengths;
  // JS keeps a newly computed NaN/Infinity during this entire evaluation.
  // Project non-finite values to JSON null only at the persistence boundary;
  // an existing null read from JSON still means Number(null) == 0.
  Map<String, Object?> get state {
    // JS arrays accept named timer keys during this evaluation, but JSON.stringify
    // saves only their original indexed slots. Deleted indices become null holes.
    final projected = Map<String, Object?>.of(_state);
    for (final item in _arrayLengths.entries) {
      projected[item.key] = List<Object?>.generate(item.value, (index) => _effects(item.key)['$index']);
    }
    return jsonDecode(_jsJson(projected)) as Map<String, Object?>;
  }

  final active = <String, Set<int>>{'sticky': {}, 'cooldown': {}, 'delay': {}};
  _TimedEffects._fork(this.input, this.entries, this.pack, this._state, this._arrayLengths);
  _TimedEffects fork(_PackWorldInfoState candidate) => _TimedEffects._fork(
    input,
    entries,
    candidate,
    _copyTimedValue(_state)! as Map<String, Object?>,
    Map<String, int>.of(_arrayLengths),
  );

  bool isActive(String type, _RuntimeEntry entry) =>
      entry.packSource == null ? active[type]!.contains(entry.hash) : pack.isActive(type, entry);
  Map<String, Object?> _effects(String type) => _state[type]! as Map<String, Object?>;
  String _key(_RuntimeEntry item) => item.entry.stKey;

  Map<String, Object?> _effect(String type, _RuntimeEntry item, {bool protected = false}) {
    final end = input.messageCount + _jsNumber(item.entry._fields[type]);
    return {'hash': item.hash, 'start': input.messageCount, 'end': end, 'protected': protected};
  }

  void _check(String type) {
    final values = _effects(type);
    for (final key in _objectKeys(values.keys)) {
      final value = _object(values[key]);
      _RuntimeEntry? found;
      for (final item in entries) {
        if (item.packSource != null) {
          continue;
        }
        if (_jsString(value['hash']) == '${item.hash}') {
          found = item;
          break;
        }
      }
      final start = value.containsKey('start') ? _jsNumber(value['start']) : double.nan;
      final end = value.containsKey('end') ? _jsNumber(value['end']) : double.nan;
      if (input.messageCount <= start && !_truthy(value['protected'])) {
        values.remove(key);
        continue;
      }
      if (found == null) {
        if (input.messageCount >= end) values.remove(key);
        continue;
      }
      if (!_truthy(found.entry._fields[type])) {
        values.remove(key);
        continue;
      }
      if (input.messageCount >= end) {
        values.remove(key);
        if (type == 'sticky' && _truthy(found.entry._fields['cooldown'])) {
          _effects('cooldown')[_key(found)] = _effect('cooldown', found, protected: true);
          active['cooldown']!.add(found.hash);
        }
        continue;
      }
      active[type]!.add(found.hash);
    }
  }

  void finish(Iterable<WorldInfoHit> hits) {
    if (input.dryRun) return;
    for (final hit in hits) {
      final item = entries.firstWhere((item) => item.entry.identity == hit.entry.identity);
      if (item.packSource != null) {
        pack.finishTimers(item);
        continue;
      }
      for (final type in const ['sticky', 'cooldown']) {
        if (_truthy(item.entry._fields[type]) && !_truthy(_effects(type)[_key(item)])) {
          _effects(type)[_key(item)] = _effect(type, item);
        }
      }
    }
  }
}

/// Pack effects share the original scan/finalizer, but never use legacy hashes
/// as consumption keys. Only loaded sources enter the expiry/count gates.
class _PackWorldInfoState {
  _PackWorldInfoState(this.input, this.entries)
    : _domains = {},
      _original = {},
      _invalid = {},
      issues = [],
      _active = {'sticky': {}, 'cooldown': {}} {
    final snapshot = input.packWorldInfo ?? state_core.StatePackWorldInfoSnapshot(exists: false);
    for (final item in entries) {
      final source = item.packSource;
      if (source == null || _domains.containsKey(source.source) || _invalid.contains(source.source)) {
        continue;
      }
      final read = snapshot.read(source.source);
      if (read.issues.isNotEmpty) {
        _invalid.add(source.source);
        issues.addAll(read.issues);
        continue;
      }
      final raw = read.exists ? read.raw! as Map<String, Object?> : null;
      _original[source.source] = raw;
      _domains[source.source] = raw == null ? <String, Object?>{} : _copyTimedValue(raw)! as Map<String, Object?>;
    }
    for (final item in entries) {
      final source = item.packSource;
      if (source != null && !_invalid.contains(source.source)) {
        _checkEntry(source);
      }
    }
    if (!input.dryRun) {
      for (final type in const ['sticky', 'cooldown']) {
        for (final item in entries) {
          if (item.packSource != null && available(item)) {
            _checkTimer(type, item);
          }
        }
      }
    }
  }

  _PackWorldInfoState._fork(
    this.input,
    this.entries,
    this._domains,
    this._original,
    this._invalid,
    this.issues,
    this._active,
  );

  final WorldInfoInput input;
  final List<_RuntimeEntry> entries;
  final Map<state_core.StateExecutionSource, Map<String, Object?>> _domains;
  final Map<state_core.StateExecutionSource, Map<String, Object?>?> _original;
  final Set<state_core.StateExecutionSource> _invalid;
  final List<Map<String, Object?>> issues;
  final Map<String, Set<_PackWorldInfoEntryKey>> _active;

  _PackWorldInfoState fork() => _PackWorldInfoState._fork(
    input,
    entries,
    {for (final row in _domains.entries) row.key: _copyTimedValue(row.value)! as Map<String, Object?>},
    Map.of(_original),
    Set.of(_invalid),
    [for (final issue in issues) _copyTimedValue(issue)! as Map<String, Object?>],
    {for (final row in _active.entries) row.key: Set.of(row.value)},
  );

  bool available(_RuntimeEntry item) => item.packSource == null || !_invalid.contains(item.packSource!.source);

  void _bad(WorldInfoPackSource source, String suffix) {
    _invalid.add(source.source);
    issues.add({
      'code': 'pack_world_info_shape',
      'path': '/dshgoPackRuntime/bindings/${_worldInfoPointerToken(source.source.bindingId!)}/worldInfo$suffix',
      'message': 'The required saved world-info carrier is malformed and is preserved.',
      'source': source.source.toJson(),
      'resourceLocalId': source.resourceLocalId,
      'entryLocalId': source.entryLocalId,
    });
  }

  void _checkEntry(WorldInfoPackSource source) {
    final domain = _domains[source.source]!;
    if (!domain.containsKey('entries')) {
      return;
    }
    final resources = domain['entries'];
    if (resources is! Map<String, Object?>) {
      _bad(source, '/entries');
      return;
    }
    if (!resources.containsKey(source.resourceLocalId)) {
      return;
    }
    final resourcePath = '/entries/${_worldInfoPointerToken(source.resourceLocalId)}';
    final resource = resources[source.resourceLocalId];
    if (resource is! Map<String, Object?>) {
      _bad(source, resourcePath);
      return;
    }
    if (!resource.containsKey(source.entryLocalId)) {
      return;
    }
    final entryPath = '$resourcePath/${_worldInfoPointerToken(source.entryLocalId)}';
    final row = resource[source.entryLocalId];
    if (row is! Map<String, Object?>) {
      _bad(source, entryPath);
      return;
    }
    if (row.containsKey('matches') && (row['matches'] is! int || (row['matches']! as int) < 0)) {
      _bad(source, '$entryPath/matches');
      return;
    }
    if (row.containsKey('lastMessageCount') && row['lastMessageCount'] is! int) {
      _bad(source, '$entryPath/lastMessageCount');
      return;
    }
    for (final type in const ['sticky', 'cooldown']) {
      if (row.containsKey(type)) {
        final timer = row[type];
        if (timer is! Map<String, Object?> || !timer.containsKey('start') || !timer.containsKey('end')) {
          _bad(source, '$entryPath/$type');
          return;
        }
      }
    }
  }

  Map<String, Object?>? _entry(WorldInfoPackSource source) {
    final resources = _domains[source.source]!['entries'] as Map<String, Object?>?;
    final resource = resources?[source.resourceLocalId] as Map<String, Object?>?;
    return resource?[source.entryLocalId] as Map<String, Object?>?;
  }

  Map<String, Object?> _writeEntry(WorldInfoPackSource source) {
    final resources =
        _domains[source.source]!.putIfAbsent('entries', () => <String, Object?>{})! as Map<String, Object?>;
    final resource = resources.putIfAbsent(source.resourceLocalId, () => <String, Object?>{})! as Map<String, Object?>;
    return resource.putIfAbsent(source.entryLocalId, () => <String, Object?>{})! as Map<String, Object?>;
  }

  bool isActive(String type, _RuntimeEntry item) {
    if (!available(item)) {
      return false;
    }
    if (type == 'delay') {
      final delay = item.entry._fields['delay'];
      return _truthy(delay) && input.messageCount < _jsNumber(delay);
    }
    return _active[type]!.contains(item.packSource!._key);
  }

  void _checkTimer(String type, _RuntimeEntry item) {
    final source = item.packSource!;
    final row = _entry(source);
    if (row == null || !row.containsKey(type)) {
      return;
    }
    final value = row[type]! as Map<String, Object?>;
    final start = value.containsKey('start') ? _jsNumber(value['start']) : double.nan;
    final end = value.containsKey('end') ? _jsNumber(value['end']) : double.nan;
    if (input.messageCount <= start && !_truthy(value['protected'])) {
      row.remove(type);
      return;
    }
    if (input.messageCount >= end) {
      row.remove(type);
      if (type == 'sticky' && _truthy(value['cooldownOnStickyEnd'])) {
        final cooldownEnd = end + _jsNumber(value['cooldownOnStickyEnd']);
        // An inactive interval does not postpone a stored deadline. A fully
        // expired conversion leaves no shell that could prevent a new hit.
        if (!(input.messageCount >= cooldownEnd)) {
          row['cooldown'] = {
            'start': end,
            'end': cooldownEnd,
            'protected': true,
            'triggeredHash': value['triggeredHash'],
            'triggeredVersion': value['triggeredVersion'],
          };
        }
      }
      return;
    }
    _active[type]!.add(source._key);
  }

  Map<String, Object?> _effect(String type, _RuntimeEntry item) => {
    'start': input.messageCount,
    'end': input.messageCount + _jsNumber(item.entry._fields[type]),
    'protected': false,
    'triggeredHash': item.hash,
    'triggeredVersion': item.packSource!.packVersion,
    if (type == 'sticky' && item.entry._fields.containsKey('cooldown'))
      'cooldownOnStickyEnd': _copyTimedValue(item.entry._fields['cooldown']),
  };

  void finishTimers(_RuntimeEntry item) {
    if (!available(item) || input.dryRun) {
      return;
    }
    final source = item.packSource!;
    for (final type in const ['sticky', 'cooldown']) {
      if (_truthy(item.entry._fields[type]) && !(_entry(source)?.containsKey(type) ?? false)) {
        _writeEntry(source)[type] = _effect(type, item);
      }
    }
  }

  int previous(_RuntimeEntry item) => (_entry(item.packSource!)?['matches'] as int?) ?? 0;

  void finishAdmission(_RuntimeEntry item) {
    if (!available(item) || input.dryRun) {
      return;
    }
    final source = item.packSource!;
    if (_entry(source)?['lastMessageCount'] == input.messageCount) {
      return;
    }
    final count = previous(item);
    _writeEntry(source).addAll({'matches': count + 1, 'lastMessageCount': input.messageCount});
  }

  state_core.StatePackWorldInfoDelta get delta {
    final replacements = <state_core.StateExecutionSource, Map<String, Object?>>{};
    for (final row in _domains.entries) {
      if (_invalid.contains(row.key)) {
        continue;
      }
      final projected = jsonDecode(_jsJson(row.value)) as Map<String, Object?>;
      final original = _original[row.key];
      if (original == null ? projected.isNotEmpty : _jsJson(original) != _jsJson(projected)) {
        replacements[row.key] = projected;
      }
    }
    return state_core.StatePackWorldInfoDelta(replacements);
  }
}

Object? _copyTimedValue(Object? value) {
  if (value is Map<String, Object?>) return {for (final item in value.entries) item.key: _copyTimedValue(item.value)};
  if (value is List<Object?>) return value.map(_copyTimedValue).toList();
  return value; // Includes internal non-finite numbers until the final JSON projection.
}

Map<String, Object?> _object(Object? value) {
  if (value is Map<String, Object?>) return Map<String, Object?>.of(value);
  if (value is List<Object?>) return {for (var i = 0; i < value.length; i++) '$i': value[i]};
  return {};
}

bool _truthy(Object? value) =>
    value != null && value != false && value != '' && value != 0 && !(value is double && value.isNaN);

num _jsNumber(Object? value) {
  if (value == null) return 0;
  if (value is num) return value.toDouble();
  if (value is bool) return value ? 1 : 0;
  if (value is Map<String, Object?>) return double.nan;
  // Dart VM trim also removes NEL (U+0085); ECMAScript Number does not.
  final text = _jsString(value).replaceAll(
    RegExp(
      r'^[\u0009-\u000d\u0020\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]+'
      r'|[\u0009-\u000d\u0020\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]+$',
    ),
    '',
  );
  if (text.isEmpty) return 0;
  final radix = RegExp(r'^0([xXbBoO])([0-9a-fA-F]+)$').firstMatch(text);
  if (radix != null) {
    final base = switch (radix[1]!.toLowerCase()) {
      'x' => 16,
      'b' => 2,
      _ => 8,
    };
    return BigInt.tryParse(radix[2]!, radix: base)?.toDouble() ?? double.nan;
  }
  if (text == 'Infinity' || text == '+Infinity') return double.infinity;
  if (text == '-Infinity') return double.negativeInfinity;
  if (!RegExp(r'^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$').hasMatch(text)) return double.nan;
  return double.tryParse(text) ?? double.nan;
}

String _jsString(Object? value) {
  if (value == null) return 'null';
  if (value is num) return _jsNumberString(value);
  if (value is Map<String, Object?>) return '[object Object]';
  if (value is List<Object?>) return value.map((item) => item == null ? '' : _jsString(item)).join(',');
  return '$value';
}

/// ST hashes the original loader object after its two-decorator parser. Full V3
/// interpretation below must not silently change the identity of imported ST timers.
int _entryHash(WorldInfoEntry entry) {
  final fields = entry._fields;
  final mapped = <String, Object?>{
    if (fields.containsKey('uid')) 'uid': fields['uid'],
    'world': entry.book.stWorldName,
    for (final key in _objectKeys(fields.keys))
      if (key != 'uid') key: fields[key],
  };
  final parsed = _stDecorators(_string(fields['content']));
  mapped['decorators'] = parsed.$1;
  mapped['content'] = parsed.$2;
  return _cyrb53(_jsJson(mapped));
}

(List<String>, String) _stDecorators(String content) {
  if (!content.startsWith('@@')) return ([], content);
  final lines = content.split('\n');
  final values = <String>[];
  var fallback = false;
  var rest = content;
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i];
    if (!line.startsWith('@@')) {
      rest = lines.skip(i).join('\n');
      break;
    }
    if (line.startsWith('@@@')) {
      if (!fallback) continue;
      line = line.substring(1);
    }
    if (line.startsWith('@@activate') || line.startsWith('@@dont_activate')) {
      values.add(line);
      fallback = false;
    } else {
      fallback = true;
    }
  }
  return (values, rest);
}

int _cyrb53(String text) {
  var h1 = 0xdeadbeef;
  var h2 = 0x41c6ce57;
  for (final unit in text.codeUnits) {
    h1 = ((h1 ^ unit) * 2654435761) & 0xffffffff;
    h2 = ((h2 ^ unit) * 1597334677) & 0xffffffff;
  }
  h1 = (((h1 ^ (h1 >>> 16)) * 2246822507) ^ ((h2 ^ (h2 >>> 13)) * 3266489909)) & 0xffffffff;
  h2 = (((h2 ^ (h2 >>> 16)) * 2246822507) ^ ((h1 ^ (h1 >>> 13)) * 3266489909)) & 0xffffffff;
  return 4294967296 * (2097151 & h2) + h1;
}

String _jsJson(Object? value) {
  if (value == null) return 'null';
  if (value is bool) return '$value';
  if (value is num) return value.isFinite ? _jsNumberString(value) : 'null';
  if (value is String) return _jsQuote(value);
  if (value is List<Object?>) return '[${value.map(_jsJson).join(',')}]';
  if (value is Map<String, Object?>) {
    return '{${_objectKeys(value.keys).map((key) => '${_jsQuote(key)}:${_jsJson(value[key])}').join(',')}}';
  }
  throw const FormatException('World info state must contain only JSON values.');
}

String _jsQuote(String value) {
  final result = StringBuffer('"');
  for (var i = 0; i < value.length; i++) {
    final unit = value.codeUnitAt(i);
    switch (unit) {
      case 0x22:
        result.write(r'\"');
      case 0x5c:
        result.write(r'\\');
      case 8:
        result.write(r'\b');
      case 9:
        result.write(r'\t');
      case 10:
        result.write(r'\n');
      case 12:
        result.write(r'\f');
      case 13:
        result.write(r'\r');
      default:
        if (unit < 32 ||
            (unit >= 0xd800 &&
                unit <= 0xdfff &&
                !(unit <= 0xdbff &&
                    i + 1 < value.length &&
                    value.codeUnitAt(i + 1) >= 0xdc00 &&
                    value.codeUnitAt(i + 1) <= 0xdfff))) {
          result.write('\\u${unit.toRadixString(16).padLeft(4, '0')}');
        } else {
          result.writeCharCode(unit);
          if (unit >= 0xd800 && unit <= 0xdbff) result.writeCharCode(value.codeUnitAt(++i));
        }
    }
  }
  result.write('"');
  return '$result';
}

String _jsNumberString(num value) {
  final number = value.toDouble();
  if (number == 0) return '0';
  if (!number.isFinite) return '$number';
  final negative = number < 0;
  final text = number.abs().toString().toLowerCase();
  final parts = text.split('e');
  final coefficient = parts.first;
  final point = coefficient.indexOf('.');
  var digits = coefficient.replaceAll('.', '').replaceFirst(RegExp(r'0+$'), '');
  var decimal = (point < 0 ? coefficient.length : point) + (parts.length == 2 ? int.parse(parts[1]) : 0);
  while (digits.startsWith('0')) {
    digits = digits.substring(1);
    decimal--;
  }
  String result;
  if (decimal > 0 && decimal <= 21) {
    result = decimal >= digits.length
        ? digits.padRight(decimal, '0')
        : '${digits.substring(0, decimal)}.${digits.substring(decimal)}';
  } else if (decimal <= 0 && decimal > -6) {
    result = '0.${''.padRight(-decimal, '0')}$digits';
  } else {
    final exponent = decimal - 1;
    result = '${digits[0]}${digits.length > 1 ? '.${digits.substring(1)}' : ''}e${exponent >= 0 ? '+' : ''}$exponent';
  }
  return negative ? '-$result' : result;
}
