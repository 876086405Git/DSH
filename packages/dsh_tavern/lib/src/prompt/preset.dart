// Adapted from SillyTavern public/scripts/PromptManager.js (AGPL-3.0).
// Source commit: 7e8663cd9c184a550b37238218bdd32c6efc68e9 (1.19.0).
import 'dart:convert';

import 'default_preset.dart';

/// A lossless JSON preset plus a normalized, independent execution view.
/// Connection fields are preserved but never used to choose an endpoint or key.
final class ChatPreset {
  ChatPreset(Map<String, Object?> value) : _raw = _copy(value);

  factory ChatPreset.decode(String text) {
    final value = jsonDecode(text.startsWith('\uFEFF') ? text.substring(1) : text);
    if (value is! Map<String, Object?>) throw const FormatException('Preset must be a JSON object');
    return ChatPreset(value);
  }

  factory ChatPreset.stDefault() => _defaultPreset;

  static final _defaultPreset = ChatPreset.decode(stDefaultPresetJson);

  final Map<String, Object?> _raw;

  Map<String, Object?> get raw => _copy(_raw);

  /// Unknown fields and legacy keys survive an ordinary import/export cycle.
  String encode({bool includeConnection = true}) {
    final value = raw;
    if (!includeConnection) {
      for (final key in _connectionFields) {
        value.remove(key);
      }
    }
    return const JsonEncoder.withIndent('  ').convert(value);
  }

  /// Detached normalized settings for callers that need to edit a copy.
  Map<String, Object?> get settings => _copy(executionSettings);

  /// Recursively immutable normalized projection, compiled once per preset.
  /// Read-only execution paths can retain this view without copying extension
  /// payloads; [raw] and [settings] keep their independent mutable contracts.
  late final Map<String, Object?> executionSettings = _freeze(_normalize()) as Map<String, Object?>;

  Map<String, Object?> _normalize() {
    final defaults = jsonDecode(stDefaultPresetJson) as Map<String, Object?>;
    // Runtime defaults differ slightly from the bundled named Default preset.
    defaults['stream_openai'] = false;
    final defaultPrompts = defaults['prompts'] as List<Object?>;
    (defaultPrompts.first as Map<String, Object?>)['content'] =
        "Write {{char}}'s next reply in a fictional chat between {{charIfNotGroup}} and {{user}}.";
    final result = <String, Object?>{
      ...defaults,
      'show_thoughts': true,
      'reasoning_effort': 'auto',
      'function_calling': false,
      ...raw,
    };
    // ST reads these switches by JS truthiness. Numeric settings stay raw:
    // budgets, sampling Number(), and request forwarding are distinct reads.
    for (final key in const ['stream_openai', 'show_thoughts', 'continue_prefill', 'squash_system_messages']) {
      result[key] = presetTruthy(result[key]);
    }
    final builtins = (defaults['prompts'] as List<Object?>).whereType<Map<String, Object?>>().toList();
    final supplied = result['prompts'];
    final prompts = supplied is List<Object?>
        ? supplied.whereType<Map<String, Object?>>().map(_copy).toList()
        : <Map<String, Object?>>[];
    for (final builtin in builtins) {
      if (!prompts.any((prompt) => prompt['identifier'] == builtin['identifier'])) prompts.add(_copy(builtin));
    }
    for (final identifier in ['main', 'nsfw', 'jailbreak']) {
      final legacy = result['${identifier}_prompt'];
      if (legacy is String && legacy.isNotEmpty) {
        prompts.firstWhere((prompt) => prompt['identifier'] == identifier)['content'] = legacy;
        result.remove('${identifier}_prompt');
      }
    }
    for (var i = 0; i < prompts.length; i++) {
      prompts[i]['identifier'] ??= 'unnamed-$i';
    }
    result['prompts'] = prompts;
    final orders = result['prompt_order'];
    final groups = orders is List<Object?>
        ? orders.whereType<Map<String, Object?>>().toList()
        : <Map<String, Object?>>[];
    final active = groups.where((group) => presetString(group['character_id']) == '100001').firstOrNull;
    if (active == null || active['order'] is! List<Object?> || (active['order'] as List<Object?>).isEmpty) {
      final defaultGroups = defaults['prompt_order'] as List<Object?>;
      final fallback = defaultGroups.whereType<Map<String, Object?>>().firstWhere((g) => g['character_id'] == 100001);
      groups.add(_copy(fallback));
    }
    for (final group in groups) {
      // PromptManager matches String(character_id). A present empty/null
      // first match remains empty even after it appends a default group.
      group['character_id'] = presetString(group['character_id']);
      final order = group['order'];
      group['order'] = order is List<Object?>
          ? [
              for (final entry in order.whereType<Map<String, Object?>>())
                {...entry, 'enabled': presetTruthy(entry['enabled'])},
            ]
          : <Object?>[];
    }
    result['prompt_order'] = groups;
    return result;
  }

  static Object? _freeze(Object? value) {
    if (value is Map<String, Object?>) {
      return Map<String, Object?>.unmodifiable({for (final entry in value.entries) entry.key: _freeze(entry.value)});
    }
    if (value is List<Object?>) return List<Object?>.unmodifiable(value.map(_freeze));
    return value;
  }

  static Map<String, Object?> _copy(Map<String, Object?> value) =>
      jsonDecode(jsonEncode(value)) as Map<String, Object?>;

  // Explicit export choice; this does not remove unfamiliar extension data.
  static const _connectionFields = {
    'chat_completion_source',
    'openai_model',
    'claude_model',
    'google_model',
    'vertexai_model',
    'openrouter_model',
    'ai21_model',
    'mistralai_model',
    'cohere_model',
    'perplexity_model',
    'groq_model',
    'chutes_model',
    'siliconflow_model',
    'siliconflow_endpoint',
    'minimax_model',
    'minimax_endpoint',
    'electronhub_model',
    'nanogpt_model',
    'nanogpt_provider',
    'nanogpt_payg_override',
    'deepseek_model',
    'aimlapi_model',
    'xai_model',
    'pollinations_model',
    'pollinations_endpoint',
    'cometapi_model',
    'moonshot_model',
    'fireworks_model',
    'zai_model',
    'zai_endpoint',
    'workers_ai_model',
    'workers_ai_account_id',
    'custom_model',
    'custom_url',
    'custom_include_body',
    'custom_exclude_body',
    'custom_include_headers',
    'reverse_proxy',
    'proxy_password',
    'azure_base_url',
    'azure_deployment_name',
    'azure_api_version',
    'azure_openai_model',
    'vertexai_auth_mode',
    'vertexai_region',
    'vertexai_express_project_id',
    'show_external_models',
    'bypass_status_check',
  };
}

/// ST's direct JS truth-value checks, not a parser for words such as "false".
bool presetTruthy(Object? value) =>
    value != null && value != false && value != '' && !(value is num && (value == 0 || value.isNaN));

/// The entry guard and String conversion used by ST substituteParams.
String presetContent(Object? value) => presetTruthy(value) ? presetString(value) : '';

/// JavaScript String for JSON-owned preset values.
String presetString(Object? value) {
  if (value == null) {
    return 'null';
  }
  if (value is num) {
    return _numberString(value);
  }
  if (value is List<Object?>) {
    return value.map((item) => item == null ? '' : presetString(item)).join(',');
  }
  if (value is Map<String, Object?>) {
    return '[object Object]';
  }
  return value.toString();
}

/// Finite JS Number conversion for executable settings. Invalid/nonfinite
/// values use the field default: Dart's integer token budget cannot use NaN
/// or Infinity. This fallback is a host tolerance policy, not a ST coercion.
num presetNumber(Object? value, num fallback) {
  final number = presetJsNumber(value);
  return number.isFinite ? number : fallback;
}

/// ST's Number(value), followed by JSON.stringify's nonfinite-to-null rule.
/// Used once at request construction, so an invalid string does not become a
/// default sampler or get reinterpreted as Number(null) on a second pass.
num? presetSamplingNumber(Object? value) {
  final number = presetJsNumber(value);
  return number.isFinite ? number : null;
}

/// Unbounded JS Number conversion, including NaN and infinities for coercive
/// comparisons. Callers constructing JSON must use [presetSamplingNumber].
num presetJsNumber(Object? value) {
  final num number;
  if (value == null) {
    number = 0;
  } else if (value is num) {
    number = value.toDouble();
  } else if (value is bool) {
    number = value ? 1 : 0;
  } else if (value is List<Object?>) {
    return presetJsNumber(presetString(value));
  } else if (value is String) {
    var start = 0;
    var end = value.length;
    while (start < end && _numberWhitespace(value.codeUnitAt(start))) {
      start++;
    }
    while (end > start && _numberWhitespace(value.codeUnitAt(end - 1))) {
      end--;
    }
    final text = value.substring(start, end);
    if (text.isEmpty) {
      return 0;
    }
    if (text == 'Infinity' || text == '+Infinity') {
      return double.infinity;
    }
    if (text == '-Infinity') {
      return double.negativeInfinity;
    }
    final based = _basedNumber.firstMatch(text);
    if (based != null) {
      final radix = switch (based[1]!.toLowerCase()) {
        'x' => 16,
        'b' => 2,
        _ => 8,
      };
      number = BigInt.tryParse(based[2]!, radix: radix)?.toDouble() ?? double.nan;
    } else {
      number = _decimalNumber.hasMatch(text) ? double.tryParse(text) ?? double.nan : double.nan;
    }
  } else {
    return double.nan;
  }
  if (!number.isFinite) {
    return number;
  }
  // Keep JSON integer spellings for ordinary API values, matching JS's one
  // Number type without overflowing Dart's machine integer range.
  if (number.abs() <= 9007199254740991 && number == number.truncateToDouble()) {
    return number.toInt();
  }
  return number;
}

final _basedNumber = RegExp(r'^0([xbo])([0-9a-f]+)$', caseSensitive: false);
final _decimalNumber = RegExp(r'^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$');
bool _numberWhitespace(int code) =>
    (code >= 0x0009 && code <= 0x000d) ||
    code == 0x0020 ||
    code == 0x00a0 ||
    code == 0x1680 ||
    (code >= 0x2000 && code <= 0x200a) ||
    code == 0x2028 ||
    code == 0x2029 ||
    code == 0x202f ||
    code == 0x205f ||
    code == 0x3000 ||
    code == 0xfeff;

String _numberString(num value) {
  final number = value.toDouble();
  if (number.isNaN) {
    return 'NaN';
  }
  if (number == double.infinity) {
    return 'Infinity';
  }
  if (number == double.negativeInfinity) {
    return '-Infinity';
  }
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
