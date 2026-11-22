part of '../spreset.dart';

/// Read-only projection: preserving large, unrelated extension scripts needs no
/// extra serialization. Import/export retains the owner's complete raw preset.
class SPresetConfig {
  SPresetConfig._(this.value, this.present, {bool external = false}) : _external = external;
  factory SPresetConfig.fromPreset(Map<String, Object?> settings) {
    if (settings['dsh_spreset_runtime'] == 'external') return SPresetConfig._(const {}, false, external: true);
    final direct = _spMap(settings['extensions'])['SPreset'];
    if (direct is Map<String, Object?>) return SPresetConfig._(direct, true);
    for (final prompt in _spRows(settings['prompts'])) {
      if (prompt['identifier'] != 'SPresetSettings' || prompt['content'] is! String) continue;
      if (prompt['content'] == '') return SPresetConfig._(const {}, true);
      final decoded = jsonDecode(prompt['content']! as String);
      if (decoded is! Map<String, Object?>) {
        throw const SPresetException('settings', 'SPresetSettings must contain a JSON object.');
      }
      return SPresetConfig._(decoded, true);
    }
    return SPresetConfig._(const {}, false);
  }
  final Map<String, Object?> value;
  final bool present;
  final bool _external;
  bool get macroNest => present && presetTruthy(value['MacroNest']);
  Map<String, Object?> module(String name) => _spMap(value[name]);
  Map<String, Object?> get chatSquash {
    final result = {..._squashDefaults, ...module('ChatSquash')};
    for (final entry in _squashDefaults.entries) {
      if (entry.value is String && result[entry.key] == null) result[entry.key] = entry.value;
    }
    return result;
  }

  String get fixedPresetName => trimJsWhitespace(_spString(value['FixedPresetName'] ?? value['fixedPresetName']));
  String? get forcedPostProcessing {
    final forced = module('ForcedPostProcessing');
    if (!presetTruthy(forced['enabled'])) return null;
    final raw = _spString(forced['mode']);
    final mode = raw == 'claude' ? 'merge' : raw;
    return const {'', 'merge', 'merge_tools', 'semi', 'semi_tools', 'strict', 'strict_tools', 'single'}.contains(mode)
        ? mode
        : null;
  }

  List<Map<String, Object?>> presetRegexes(Map<String, Object?> preset) {
    final native = _spRows(_spMap(preset['extensions'])['regex_scripts']);
    if (native.isNotEmpty || _external) return native;
    final bound = [..._spRows(module('RegexBinding')['regexes'])];
    if (bound.isEmpty) {
      for (final prompt in _spRows(preset['prompts'])) {
        if (prompt['identifier'] == 'regexes-bindings' && prompt['content'] is String) {
          if (prompt['content'] != '') bound.addAll(_spRows(jsonDecode(prompt['content']! as String)));
          break;
        }
      }
    }
    final orders = _spRows(preset['prompt_order']);
    if (orders.length > 1) {
      final legacy = _spMap(_spMap(orders[1]['xiaobai_ext'])['regexBindings']);
      for (final script in _spRows(legacy['scripts'])) {
        if (!bound.any((current) => current['id'] == script['id'])) bound.add(script);
      }
    }
    return bound;
  }
}

const _squashDefaults = <String, Object?>{
  'enabled': false,
  'conditional_enabled': false,
  'conditional_tag': '',
  'separate_chat_history': false,
  'parse_clewd': true,
  'user_role_system': false,
  'role': 'assistant',
  'enable_stop_string': false,
  'stop_string': 'User:',
  'user_prefix': '\n\nUser:',
  'user_suffix': '',
  'char_prefix': '\n\nAssistant:',
  'char_suffix': '',
  'prefix_system': '',
  'suffix_system': '',
  'enable_squashed_separator': false,
  'squashed_separator_regex': false,
  'squashed_separator_string': '',
  'squashed_post_script_enable': false,
  'squashed_post_script': '',
  're_split': false,
};

/// ST 1.13.5+ removes the older runtime's global copies after migrating the
/// preset scope. Keep unrelated global scripts and all source documents intact.
List<Map<String, Object?>> spresetGlobalRegexes(Object? raw, SPresetConfig config) => [
  for (final script in _spRows(raw))
    if (!config.present ||
        (!_spString(script['id']).startsWith('preset_') &&
            !_spString(script['scriptName']).startsWith('[s]') &&
            !presetTruthy(script['preset-regex'])))
      script,
];

/// SPreset's scope order replaces ST's order only when its runtime is active.
List<int> spresetRegexOrder(SPresetConfig config, Map<String, Object?> settings) {
  if (!config.present) return const [0, 2, 1];
  final global = _spMap(settings['SPreset'] ?? _spMap(settings['extensions'])['SPreset']);
  final order = _spMap(global['RegexBinding'])['activationOrder'];
  if (order is List<Object?> && order.length == 3 && order.toSet().containsAll(const [0, 1, 2])) {
    return order.map((value) => (value! as num).toInt()).toList();
  }
  return const [2, 0, 1];
}

/// A native-owned bootstrap remains inspectable and user selectable. Detection
/// uses the actual loader URL/path; script names and sizes are not identities.
bool isSPresetBootstrap(String source) {
  final canonical = StringBuffer();
  var i = 0;
  while (i < source.length) {
    final c = source[i];
    if (RegExp(r'\s').hasMatch(c)) {
      i++;
      continue;
    }
    if (source.startsWith('//', i)) {
      final end = source.indexOf('\n', i + 2);
      i = end < 0 ? source.length : end + 1;
      continue;
    }
    if (source.startsWith('/*', i)) {
      final end = source.indexOf('*/', i + 2);
      if (end < 0) return false;
      i = end + 2;
      continue;
    }
    if (c == "'" || c == '"') {
      final end = source.indexOf(c, i + 1);
      if (end < 0) return false;
      var literal = source.substring(i + 1, end);
      // Escaped or generated loaders have not been identified by this fixed
      // source identity. Leave them visible for the user's runtime choice.
      if (literal.contains(r'\')) return false;
      if (literal == 'https://starowo.github.io/regex_bind/inject.js') {
        literal = 'https://jnai2d9kgnbs6xzx5c.com/regex_bind/inject.js';
      }
      canonical.write('"$literal"');
      i = end + 1;
      continue;
    }
    if (c == '`') return false;
    canonical.write(c);
    i++;
  }
  // Public 702-character regex_bind/index.js at 53bd585..., with comments,
  // insignificant whitespace and quote spelling normalized. No names/size
  // heuristic: extra executable code or a quoted loader is not this identity.
  return crypto.sha256.convert(utf8.encode(canonical.toString())).toString() ==
      'a80916e82f38145aa2e14846ed85d2d167598eb1c5104a576d681ad3bd8afc43';
}

String? spresetScriptSkipReason(String source, {String runtimeMode = 'native'}) =>
    runtimeMode != 'external' && isSPresetBootstrap(source)
    ? 'SPreset bootstrap is owned by the native runtime; select external runtime to run it.'
    : null;

/// FixedPresetName is consumed only by a successful import, never by export or
/// an ordinary save. The caller owns conflict handling before clearing it.
void clearSPresetFixedPresetName(Map<String, Object?> preset) {
  final direct = _spMap(preset['extensions'])['SPreset'];
  if (direct is Map<String, Object?>) {
    direct['FixedPresetName'] = '';
    if (direct.containsKey('fixedPresetName')) direct['fixedPresetName'] = '';
  }
  for (final prompt in _spRows(preset['prompts'])) {
    if (prompt['identifier'] != 'SPresetSettings') continue;
    if (prompt['content'] is! String) break;
    Object? decoded;
    try {
      decoded = jsonDecode(prompt['content']! as String);
    } on FormatException {
      break;
    }
    if (decoded is Map<String, Object?>) {
      decoded['FixedPresetName'] = '';
      if (decoded.containsKey('fixedPresetName')) decoded['fixedPresetName'] = '';
      prompt['content'] = jsonEncode(decoded);
    }
    break;
  }
}

/// Innermost-leftmost evaluation. Braces produced by an expansion are protected
/// until the entire pass finishes, rather than being recursively re-executed.
String spresetExpandNested(String content, String Function(String) expandOne) {
  var result = content;
  var steps = 0;
  while (true) {
    var cursor = 0;
    var replaced = false;
    final stack = <int>[];
    while (cursor < result.length) {
      // This exact limit is part of the pinned source's macro algorithm
      // (substituteParamsRecursive), not an added App script-size policy.
      if (++steps > 1000000) {
        throw const SPresetException('MacroNest', 'resolveMacrosSync: exceeded MAX_STEPS');
      }
      if (result.startsWith('{{', cursor)) {
        stack.add(cursor);
        cursor += 2;
      } else if (result.startsWith('}}', cursor)) {
        if (stack.isNotEmpty) {
          final start = stack.removeLast();
          final inner = result.substring(start + 2, cursor).replaceAll('{', '<|lb|>').replaceAll('}', '<|rb|>');
          final expanded = expandOne('{{$inner}}').replaceAll('{', '<|lb|>').replaceAll('}', '<|rb|>');
          result = result.substring(0, start) + expanded + result.substring(cursor + 2);
          cursor = start + expanded.length;
          replaced = true;
        } else {
          cursor += 2;
        }
      } else {
        cursor++;
      }
    }
    if (!replaced) break;
  }
  return result.replaceAll('<|lb|>', '{').replaceAll('<|rb|>', '}');
}

class SPresetProvider {
  const SPresetProvider({required this.source, required this.model});
  final String source, model;
  String get adapter => switch (source.toLowerCase()) {
    'makersuite' || 'vertexai' => 'gemini',
    'claude' => 'claude',
    'deepseek' => 'deepseek',
    'openrouter' => 'openrouter',
    _ => 'openai',
  };
  Map<String, Object?> toJson() => {'adapter': adapter, 'source': source, 'model': model};
}

/// The first enabled preparePrompt call obtains Prompt's constructor by invoking
/// the previous implementation, so its normal macro pass has real side effects.
/// Keep this object for the native runtime's lifetime, including preset changes.
class SPresetMacroNestRuntime {
  bool _primed = false;
  String expand(String text, String Function(String) expandOne) {
    if (text.isEmpty) return expandOne(text);
    if (!_primed) {
      expandOne(text);
      _primed = true;
    }
    return spresetExpandNested(text, expandOne);
  }
}

/// FixedPresetName reads the legacy prompt when a direct name is absent, even
/// when other direct SPreset settings are already present.
String spresetFixedPresetName(Map<String, Object?> preset) {
  final direct = _spMap(_spMap(preset['extensions'])['SPreset']);
  final name = trimJsWhitespace(_spString(direct['FixedPresetName'] ?? direct['fixedPresetName']));
  if (name.isNotEmpty) return name;
  for (final prompt in _spRows(preset['prompts'])) {
    if (prompt['identifier'] != 'SPresetSettings') continue;
    if (prompt['content'] is! String) return '';
    try {
      final legacy = _spMap(jsonDecode(prompt['content']! as String));
      return trimJsWhitespace(_spString(legacy['FixedPresetName'] ?? legacy['fixedPresetName']));
    } on FormatException {
      return '';
    }
  }
  return '';
}

/// ST /api/files/sanitize-filename delegates to sanitize-filename 1.6.3.
/// Mirrors that package's empty replacement and UTF-8 255-byte truncation.
String spresetSanitizedPresetName(String name) {
  final text = name
      .replaceAll(RegExp(r'[\/\?<>\\:\*\|"]'), '')
      .replaceAll(RegExp(r'[\x00-\x1f\x80-\x9f]'), '')
      .replaceAll(RegExp(r'^\.+$'), '')
      .replaceAll(RegExp(r'^(con|prn|aux|nul|com[0-9]|lpt[0-9])(\..*)?$', caseSensitive: false), '')
      .replaceAll(RegExp(r'[\. ]+$'), '');
  if (utf8.encode(text).length <= 255) return text;
  final result = StringBuffer();
  var size = 0;
  for (final rune in text.runes) {
    final character = String.fromCharCode(rune);
    final length = utf8.encode(character).length;
    if (size + length > 255) break;
    result.write(character);
    size += length;
  }
  return result.toString();
}
