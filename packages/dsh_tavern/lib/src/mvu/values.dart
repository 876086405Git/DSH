part of 'mvu.dart';

Object? _copyMvu(Object? value) {
  if (value is MvuJson) {
    return <String, Object?>{for (final entry in value.entries) entry.key: _copyMvu(entry.value)};
  }
  if (value is List<Object?>) {
    return [for (final item in value) _copyMvu(item)];
  }
  return value;
}

MvuJson _copyMvuMap(MvuJson value) => _copyMvu(value)! as MvuJson;

bool _mvuEqual(Object? a, Object? b) {
  if (a is MvuJson && b is MvuJson) {
    return a.length == b.length &&
        a.entries.every((entry) => b.containsKey(entry.key) && _mvuEqual(entry.value, b[entry.key]));
  }
  if (a is List<Object?> && b is List<Object?>) {
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (!_mvuEqual(a[i], b[i])) {
        return false;
      }
    }
    return true;
  }
  return a == b;
}

/// Merge into an owned destination. The source remains untouched.
Object? _mvuMerge(Object? target, Object? source, {bool replaceArrays = false}) {
  if (source is MvuJson) {
    final result = target is MvuJson ? target : <String, Object?>{};
    for (final entry in source.entries) {
      result[entry.key] = _mvuMerge(result[entry.key], entry.value, replaceArrays: replaceArrays);
    }
    return result;
  }
  if (source is List<Object?>) {
    if (replaceArrays) {
      return _copyMvu(source);
    }
    final result = target is List<Object?> ? target : <Object?>[];
    if (result.length < source.length) {
      result.length = source.length;
    }
    for (var i = 0; i < source.length; i++) {
      result[i] = _mvuMerge(result[i], source[i], replaceArrays: replaceArrays);
    }
    return result;
  }
  return source;
}

bool _mvuTruthy(Object? value) => value != null && value != false && value != 0 && value != '';

List<String> _mvuKeys(MvuJson value) {
  final indices = <(int, String)>[];
  final other = <String>[];
  for (final key in value.keys) {
    final index = RegExp(r'^(0|[1-9]\d*)$').hasMatch(key) ? int.tryParse(key) : null;
    if (index != null && index < 4294967295) {
      indices.add((index, key));
    } else {
      other.add(key);
    }
  }
  indices.sort((a, b) => a.$1.compareTo(b.$1));
  return [...indices.map((entry) => entry.$2), ...other];
}

String _mvuString(Object? value) {
  if (value == null) {
    return 'null';
  }
  if (value is num) {
    return _mvuNumberString(value);
  }
  if (value is List<Object?>) {
    return value.map((item) => item == null ? '' : _mvuString(item)).join(',');
  }
  if (value is MvuJson) {
    return '[object Object]';
  }
  return value.toString();
}

String _mvuJsonText(Object? value) {
  if (value is num) {
    return _mvuNumberString(value);
  }
  if (value is List<Object?>) {
    return '[${value.map(_mvuJsonText).join(',')}]';
  }
  if (value is MvuJson) {
    final entries = _mvuKeys(value).map((key) => '${jsonEncode(key)}:${_mvuJsonText(value[key])}').join(',');
    return '{$entries}';
  }
  return jsonEncode(value);
}

final _mvuBasedNumber = RegExp(r'^0([xbo])([0-9a-f]+)$', caseSensitive: false);
final _mvuDecimalNumber = RegExp(r'^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$');

num? _mvuNumber(Object? value) {
  if (value == null) {
    return 0;
  }
  if (value is num) {
    return value.isFinite ? value.toDouble() : null;
  }
  if (value is bool) {
    return value ? 1 : 0;
  }
  if (value is List<Object?>) {
    return _mvuNumber(_mvuString(value));
  }
  if (value is! String) {
    return null;
  }
  final text = trimJsWhitespace(value);
  if (text.isEmpty) {
    return 0;
  }
  final based = _mvuBasedNumber.firstMatch(text);
  if (based != null) {
    final radix = switch (based[1]!.toLowerCase()) {
      'x' => 16,
      'b' => 2,
      _ => 8,
    };
    final number = BigInt.tryParse(based[2]!, radix: radix)?.toDouble();
    return number != null && number.isFinite ? number : null;
  }
  if (!_mvuDecimalNumber.hasMatch(text)) {
    return null;
  }
  final number = double.tryParse(text);
  return number != null && number.isFinite ? number : null;
}

/// Parser output is a boundary: YAML aliases/keys and JSON5 nonfinite numbers
/// must not become invalid persistent JSON or be silently changed to null.
Object? _mvuJson(Object? value) {
  final parents = HashSet<Object>.identity();
  Object? visit(Object? item) {
    if (item == null || item is String || item is bool) {
      return item;
    }
    if (item is num) {
      if (!item.isFinite) {
        throw const FormatException('MVU values must contain finite JSON numbers.');
      }
      return item;
    }
    if (item is Map<Object?, Object?>) {
      if (!parents.add(item)) {
        throw const FormatException('MVU values cannot contain a YAML alias cycle.');
      }
      try {
        final result = <String, Object?>{};
        for (final entry in item.entries) {
          final key = entry.key;
          if (key is! String) {
            throw const FormatException('MVU object keys must be strings.');
          }
          result[key] = visit(entry.value);
        }
        return result;
      } finally {
        parents.remove(item);
      }
    }
    if (item is List<Object?>) {
      if (!parents.add(item)) {
        throw const FormatException('MVU values cannot contain a YAML alias cycle.');
      }
      try {
        return [for (final child in item) visit(child)];
      } finally {
        parents.remove(item);
      }
    }
    throw const FormatException('MVU values must be JSON data.');
  }

  return visit(value);
}

// json5 0.8.2 uses double.parse for hexadecimal tokens. Keep its parser
// and syntax checks, adapting only complete value tokens outside strings/comments.
Object? _mvuParseJson5(String source) {
  int skipTrivia(int index) {
    while (index < source.length) {
      if (trimJsWhitespace(source[index]).isEmpty) {
        index++;
      } else if (source.startsWith('//', index)) {
        index += 2;
        while (index < source.length && !const ['\r', '\n', '\u2028', '\u2029'].contains(source[index])) {
          index++;
        }
      } else if (source.startsWith('/*', index)) {
        final end = source.indexOf('*/', index + 2);
        index = end < 0 ? source.length : end + 2;
      } else {
        break;
      }
    }
    return index;
  }

  bool hexDigit(int code) =>
      code >= 0x30 && code <= 0x39 || code >= 0x41 && code <= 0x46 || code >= 0x61 && code <= 0x66;

  final output = StringBuffer();
  var index = 0;
  var valuePosition = true;
  while (index < source.length) {
    final afterTrivia = skipTrivia(index);
    output.write(source.substring(index, afterTrivia));
    index = afterTrivia;
    if (index == source.length) {
      break;
    }
    final char = source[index];
    if (char == "'" || char == '"') {
      final start = index++;
      while (index < source.length) {
        final next = source[index++];
        if (next == r'\') {
          if (index < source.length) {
            index++;
          }
        } else if (next == char) {
          break;
        }
      }
      output.write(source.substring(start, index));
      valuePosition = false;
      continue;
    }
    var prefix = index;
    final negative = char == '-';
    if (char == '+' || negative) {
      prefix++;
    }
    if (valuePosition && (source.startsWith('0x', prefix) || source.startsWith('0X', prefix))) {
      var end = prefix + 2;
      while (end < source.length && hexDigit(source.codeUnitAt(end))) {
        end++;
      }
      final next = skipTrivia(end);
      if (end > prefix + 2 && (next == source.length || const [',', ']', '}'].contains(source[next]))) {
        final magnitude = BigInt.parse(source.substring(prefix + 2, end), radix: 16).toDouble();
        // Overflow stays Infinity until the existing finite-JSON boundary;
        // throwing here would incorrectly allow the repair fallback to adopt it.
        output.write((negative ? -magnitude : magnitude).toString());
        index = end;
        valuePosition = false;
        continue;
      }
    }
    output.write(char);
    valuePosition = const ['{', '[', ':', ','].contains(char);
    index++;
  }
  return JSON5.parse(output.toString());
}

Object? _mvuParseDocument(String source) {
  Object? decoded;
  try {
    decoded = loadYaml(source);
  } on YamlException {
    try {
      decoded = _mvuParseJson5(source);
    } on Exception {
      // JSON5's public entry throws its unexported SyntaxException.
      decoded = jsonDecode(_repairMvuJson(source));
    }
  }
  return _mvuJson(decoded);
}

Object? _mvuParseArgument(Object? raw) {
  if (raw is! String) {
    return _copyMvu(raw);
  }
  final source = trimJsWhitespace(raw);
  if (source.isEmpty) {
    throw const FormatException('MVU command value is empty.');
  }
  if (source == 'undefined' ||
      source == 'NaN' ||
      source == 'Infinity' ||
      source == '+Infinity' ||
      source == '-Infinity') {
    throw const FormatException('MVU command values must be finite JSON data.');
  }

  Object? decoded;
  var parsed = false;
  try {
    decoded = jsonDecode(source);
    parsed = true;
  } on FormatException {
    // Continue with data-literal parsers.
  }
  if (parsed) {
    return _mvuJson(decoded);
  }
  try {
    decoded = _mvuParseJson5(source);
    parsed = true;
  } on Exception {
    // SyntaxException is not exported by package:json5/json5.dart.
  }
  if (parsed) {
    return _mvuJson(decoded);
  }

  Object? yamlValue;
  var yamlParsed = false;
  try {
    yamlValue = loadYaml(source);
    yamlParsed = true;
  } on YamlException {
    // A non-YAML string can still be an arithmetic expression or plain text.
  }
  final quoted =
      source.length >= 2 &&
      (source.startsWith("'") && source.endsWith("'") || source.startsWith('"') && source.endsWith('"'));
  if (yamlParsed && (yamlValue is! String || quoted)) {
    return _mvuJson(yamlValue);
  }
  final calculated = _mvuCalculate(source);
  if (calculated != null) {
    return calculated;
  }
  return yamlParsed ? _mvuJson(yamlValue) : source;
}

final _mvuMathParser = _createMvuMathParser();

math_expr.GrammarParser _createMvuMathParser() {
  final parser = math_expr.GrammarParser();
  parser.addFunction('round', (args) {
    if (args.length != 1) {
      throw const FormatException('round expects one argument.');
    }
    final value = args.single;
    if (value < 0 && value >= -0.5) {
      return -0.0;
    }
    final floor = value.floorToDouble();
    return value - floor >= 0.5 ? floor + 1 : floor;
  });
  parser.addFunction('min', (args) {
    if (args.isEmpty) {
      throw const FormatException('min expects at least one argument.');
    }
    return args.reduce((a, b) => a < b ? a : b);
  });
  parser.addFunction('max', (args) {
    if (args.isEmpty) {
      throw const FormatException('max expects at least one argument.');
    }
    return args.reduce((a, b) => a > b ? a : b);
  });
  parser.addFunction('pow', (args) {
    if (args.length != 2) {
      throw const FormatException('pow expects two arguments.');
    }
    return math.pow(args[0], args[1]).toDouble();
  });
  return parser;
}

num? _mvuCalculate(String source) {
  const names = <String, String>{
    'PI': 'pi',
    'E': 'e',
    'log': 'ln',
    'exp': 'e',
    'acos': 'arccos',
    'asin': 'arcsin',
    'atan': 'arctan',
    'sign': 'sgn',
    'abs': 'abs',
    'ceil': 'ceil',
    'floor': 'floor',
    'sqrt': 'sqrt',
    'sin': 'sin',
    'cos': 'cos',
    'tan': 'tan',
    'round': 'round',
    'min': 'min',
    'max': 'max',
    'pow': 'pow',
  };
  final expression = source.replaceAllMapped(
    RegExp(r'\b(?:Math|math)\.([A-Za-z_][A-Za-z0-9_]*)\b'),
    (match) => names[match.group(1)] ?? match.group(0)!,
  );
  num result;
  try {
    final parsed = _mvuMathParser.parse(expression);
    result = math_expr.RealEvaluator(math_expr.ContextModel()).evaluate(parsed);
  } on FormatException {
    return null;
  } on ArgumentError {
    return null;
  } on StateError {
    return null;
  } on UnsupportedError {
    return null;
  }
  return result.isFinite ? double.parse(result.toStringAsPrecision(12)) : null;
}

// Same finite-number representation used by the existing macro engine.
String _mvuNumberString(num value) {
  final number = value.toDouble();
  if (number == 0) {
    return '0';
  }
  var raw = number.toString();
  final e = raw.indexOf('e');
  if (e < 0) {
    return raw.endsWith('.0') ? raw.substring(0, raw.length - 2) : raw;
  }
  var mantissa = raw.substring(0, e);
  if (mantissa.endsWith('.0')) {
    mantissa = mantissa.substring(0, mantissa.length - 2);
  }
  final exponent = int.parse(raw.substring(e + 1));
  if (exponent >= 21 || exponent < -6) {
    return '${mantissa}e${exponent >= 0 ? '+' : ''}$exponent';
  }
  final negative = mantissa.startsWith('-');
  if (negative) {
    mantissa = mantissa.substring(1);
  }
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
