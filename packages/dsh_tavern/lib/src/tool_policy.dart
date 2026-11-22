import 'dart:convert';

import 'api.dart' show TavernModelConfig;
import 'tools.dart';

/// Pure scope capture. The caller owns the real settings read and admission
/// timing; this function neither reads a card nor grants wire authorization.
TavernToolPolicySnapshot toolPolicySnapshot({
  required Map<String, Object?> globalSettings,
  Map<String, Object?>? chatSettings,
}) {
  final global = _copy(globalSettings);
  final chat = chatSettings == null ? null : _copy(chatSettings);
  final diagnostics = <Map<String, Object?>>[];
  final g = _readScope(global, chat: false, diagnostics: diagnostics);
  final c = chat == null ? null : _readScope(chat, chat: true, diagnostics: diagnostics);
  return TavernToolPolicySnapshot.fromJson({
    'configuredGlobal': {'present': global.containsKey('toolPolicy'), 'raw': global['toolPolicy']},
    'configuredChat': chat == null ? null : {'present': chat.containsKey('toolPolicy'), 'raw': chat['toolPolicy']},
    'effectiveScope': {
      'rollAllow': g.rollAvailable && g.roll! && (c == null || (c.rollAvailable && (c.roll ?? true))),
      'rememberAllow':
          g.rememberAvailable && g.remember! && (c == null || (c.rememberAvailable && (c.remember ?? true))),
      'rememberMode': c?.mode ?? g.mode!,
    },
    'diagnostics': diagnostics,
  });
}

class _ScopePolicy {
  _ScopePolicy({required this.roll, required this.remember, required this.mode});
  bool? roll;
  bool? remember;
  String? mode;
  bool rollAvailable = true;
  bool rememberAvailable = true;
}

_ScopePolicy _readScope(
  Map<String, Object?> settings, {
  required bool chat,
  required List<Map<String, Object?>> diagnostics,
}) {
  final result = _ScopePolicy(roll: chat ? null : true, remember: chat ? null : false, mode: chat ? null : 'ask');
  final scope = chat ? 'chat' : 'global';
  void invalid(String path, Object? raw, {String? tool}) {
    diagnostics.add({'code': 'invalid_tool_policy', 'scope': scope, 'fieldPath': path, 'raw': raw});
    if (tool == null || tool == 'roll') result.rollAvailable = false;
    if (tool == null || tool == 'remember') result.rememberAvailable = false;
  }

  if (!settings.containsKey('toolPolicy')) return result;
  final policy = settings['toolPolicy'];
  if (policy is! Map<String, Object?>) {
    invalid('toolPolicy', policy);
    return result;
  }
  for (final name in const ['roll', 'remember']) {
    if (!policy.containsKey(name)) continue;
    final object = policy[name];
    if (object is! Map<String, Object?>) {
      invalid('toolPolicy.$name', object, tool: name);
      continue;
    }
    final enabledKey = chat ? 'enabled' : 'allow';
    if (object.containsKey(enabledKey)) {
      final enabled = object[enabledKey];
      if (enabled is bool || (chat && enabled == null)) {
        if (name == 'roll') {
          result.roll = enabled as bool?;
        } else {
          result.remember = enabled as bool?;
        }
      } else {
        invalid('toolPolicy.$name.$enabledKey', enabled, tool: name);
      }
    }
    if (name == 'remember' && object.containsKey('mode')) {
      final mode = object['mode'];
      if (mode == 'ask' || mode == 'auto' || (chat && mode == null)) {
        result.mode = mode as String?;
      } else {
        invalid('toolPolicy.remember.mode', mode, tool: name);
      }
    }
  }
  return result;
}

/// Only the card's tool domain and malformed-parent evidence are captured.
/// No prompt, hidden state or complete character data is retained here.
class ToolCardPolicy {
  ToolCardPolicy._(Map<String, Object?> value) : _data = _copy(value);
  final Map<String, Object?> _data;
  String get characterId => _data['characterId']! as String;
  bool get rollAvailable => _data['rollAvailable']! as bool;
  bool get rememberAvailable => _data['rememberAvailable']! as bool;
  bool get rollDisabled => _data['rollDisabled']! as bool;
  bool get rememberDisabled => _data['rememberDisabled']! as bool;
  List<Map<String, Object?>> get diagnostics => _diagnostics(_data);
  Map<String, Object?> toJson() => _copy(_data);
}

ToolCardPolicy captureToolCardPolicy(Map<String, Object?> cardData, {required String characterId}) {
  if (characterId.isEmpty) {
    throw const FormatException('A card policy requires a character identity.');
  }
  final declaration = parseToolCardDeclaration(cardData);
  return ToolCardPolicy._({
    'characterId': characterId,
    ...declaration,
    'diagnostics': [
      for (final issue in declaration['diagnostics']! as List<Map<String, Object?>>)
        {'code': issue['code'], 'characterId': characterId, ...issue},
    ],
  });
}

/// Internal declaration parsing shared with pure inspection. No character
/// identity, scope permission or model-wire authorization is manufactured.
Map<String, Object?> parseToolCardDeclaration(Map<String, Object?> cardData) {
  final diagnostics = <Map<String, Object?>>[];
  final captured = <String, Object?>{};
  var rollAvailable = true;
  var rememberAvailable = true;
  var rollDisabled = false;
  var rememberDisabled = false;
  void invalid(String path, Object? value, {String? tool}) {
    diagnostics.add({'code': 'invalid_card_tool_policy', 'fieldPath': path, 'raw': _copyValue(value)});
    if (tool == null || tool == 'roll') {
      rollAvailable = false;
    }
    if (tool == null || tool == 'remember') {
      rememberAvailable = false;
    }
  }

  Map<String, Object?>? child(Map<String, Object?> parent, String key, String path) {
    captured['$path.present'] = parent.containsKey(key);
    if (!parent.containsKey(key)) {
      return null;
    }
    final value = parent[key];
    if (value is! Map<String, Object?>) {
      invalid(path, value);
      return null;
    }
    return value;
  }

  final extensions = child(cardData, 'extensions', 'extensions');
  final dshgo = extensions == null ? null : child(extensions, 'dshgo', 'extensions.dshgo');
  if (dshgo != null) {
    captured['v'] = {'present': dshgo.containsKey('v'), 'raw': _copyValue(dshgo['v'])};
    if (dshgo.containsKey('v') && (dshgo['v'] is! int || dshgo['v'] != 1)) {
      invalid('extensions.dshgo.v', dshgo['v']);
    }
    final tools = child(dshgo, 'tools', 'extensions.dshgo.tools');
    if (tools != null) {
      for (final name in const ['roll', 'remember']) {
        captured[name] = {'present': tools.containsKey(name), 'raw': _copyValue(tools[name])};
        if (!tools.containsKey(name)) {
          continue;
        }
        final tool = tools[name];
        if (tool is! Map<String, Object?>) {
          invalid('extensions.dshgo.tools.$name', tool, tool: name);
          continue;
        }
        if (!tool.containsKey('disabled')) {
          continue;
        }
        final disabled = tool['disabled'];
        if (disabled is! bool) {
          invalid('extensions.dshgo.tools.$name.disabled', disabled, tool: name);
        } else if (name == 'roll') {
          rollDisabled = disabled;
        } else {
          rememberDisabled = disabled;
        }
      }
    }
  }
  return {
    'rollAvailable': rollAvailable,
    'rememberAvailable': rememberAvailable,
    'rollDisabled': rollDisabled,
    'rememberDisabled': rememberDisabled,
    'configured': captured,
    'diagnostics': diagnostics,
  };
}

/// The fixed scope and host/actor veto snapshot for one admitted operation.
/// The pending/ready persistence envelope belongs to the engine and store.
class ToolCapturedPolicy {
  ToolCapturedPolicy._(Map<String, Object?> value) : _data = _copy(value);
  final Map<String, Object?> _data;
  TavernToolPolicySnapshot get scope => TavernToolPolicySnapshot.fromJson(_data['scope']! as Map<String, Object?>);
  bool get rollAllowed => _data['rollAllowed']! as bool;
  bool get rememberAllowed => _data['rememberAllowed']! as bool;
  String get rememberMode => _data['rememberMode']! as String;
  List<Map<String, Object?>> get diagnostics => _diagnostics(_data);
  Map<String, Object?> toJson() => _copy(_data);
}

ToolCapturedPolicy captureToolPolicy({
  required TavernToolPolicySnapshot scope,
  required ToolCardPolicy host,
  ToolCardPolicy? actor,
}) {
  final effective = scope.effectiveScope;
  return ToolCapturedPolicy._({
    'scope': scope.toJson(),
    'host': host.toJson(),
    'actor': actor?.toJson(),
    'rollAllowed':
        effective['rollAllow'] == true &&
        host.rollAvailable &&
        !host.rollDisabled &&
        (actor == null || (actor.rollAvailable && !actor.rollDisabled)),
    'rememberAllowed':
        effective['rememberAllow'] == true &&
        host.rememberAvailable &&
        !host.rememberDisabled &&
        (actor == null || (actor.rememberAvailable && !actor.rememberDisabled)),
    'rememberMode': effective['rememberMode'],
    'diagnostics': [
      ...scope.diagnostics,
      ...host.diagnostics,
      if (actor != null && !identical(actor, host)) ...actor.diagnostics,
    ],
  });
}

/// New tools use non-strict schemas; local parameter validation is decisive.
List<Map<String, Object?>> ordinaryToolDefinitions(ToolCapturedPolicy policy) => [
  if (policy.rollAllowed)
    {
      'type': 'function',
      'function': {
        'name': 'roll',
        'strict': false,
        'description': 'Roll the requested dice once and use the returned persisted result.',
        'parameters': {
          'type': 'object',
          'additionalProperties': false,
          'required': ['dice'],
          'properties': {
            'dice': {
              'type': 'string',
              'description': '[N]dM with optional +K or -K; N 1..100, M 2..1000, K 0..1000000.',
            },
            'label': {'type': 'string', 'maxLength': 256},
            'target': {'type': 'integer', 'minimum': -1000000, 'maximum': 1000000},
          },
        },
      },
    },
  if (policy.rememberAllowed)
    {
      'type': 'function',
      'function': {
        'name': 'remember',
        'strict': false,
        'description': 'Propose a memory bound to the final reply; it is not committed before that reply succeeds.',
        'parameters': {
          'type': 'object',
          'additionalProperties': false,
          'required': ['text', 'keywords'],
          'properties': {
            'text': {'type': 'string', 'minLength': 1, 'maxLength': 4096},
            'keywords': {
              'type': 'array',
              'minItems': 1,
              'maxItems': 16,
              'items': {'type': 'string', 'minLength': 1, 'maxLength': 128},
            },
          },
        },
      },
    },
];

class ToolWireAuthorization {
  ToolWireAuthorization._(Map<String, Object?> value) : _data = _copy(value);
  final Map<String, Object?> _data;
  bool get rollAllowed => _data['rollAllowed']! as bool;
  bool get rememberAllowed => _data['rememberAllowed']! as bool;
  List<String> get offeredTools => List.unmodifiable((_data['offeredTools']! as List<Object?>).cast<String>());
  List<Map<String, Object?>> get diagnostics => _diagnostics(_data);
  Map<String, Object?> toJson() => _copy(_data);
}

ToolWireAuthorization toolWireAuthorization({
  required TavernModelConfig config,
  required Map<String, Object?> body,
  required ToolCapturedPolicy policy,
  bool? showThoughts,
}) {
  final diagnostics = <Map<String, Object?>>[];
  final offered = <String>[];
  final tools = body['tools'];
  if (tools is List<Object?>) {
    for (final value in tools) {
      if (value is! Map<String, Object?> || value['type'] != 'function') continue;
      final function = value['function'];
      if (function is Map<String, Object?> && function['name'] is String) offered.add(function['name']! as String);
    }
  }
  var common = config.deepseek && !(showThoughts ?? config.thinking);
  if (!common) diagnostics.add({'code': 'unsupported_tool_model_mode'});
  if (body.containsKey('thinking')) {
    final thinking = body['thinking'];
    if (thinking is! Map<String, Object?> || thinking['type'] != 'disabled') {
      common = false;
      diagnostics.add({'code': 'unsupported_tool_wire_thinking'});
    }
  }
  final messages = body['messages'];
  if (messages is! List<Object?> || messages.any((value) => value is! Map<String, Object?>)) {
    common = false;
    diagnostics.add({'code': 'invalid_tool_wire_messages'});
  } else if (messages.any((value) => (value! as Map<String, Object?>).containsKey('prefix'))) {
    common = false;
    diagnostics.add({'code': 'tool_wire_prefix_present'});
  }
  bool choiceAllows(String name) {
    final choice = body['tool_choice'];
    if (choice == null || choice == 'auto' || choice == 'required') return true;
    if (choice is! Map<String, Object?> || choice['type'] != 'function') return false;
    final function = choice['function'];
    return function is Map<String, Object?> && function['name'] == name;
  }

  return ToolWireAuthorization._({
    'rollAllowed': common && policy.rollAllowed && offered.contains('roll') && choiceAllows('roll'),
    'rememberAllowed': common && policy.rememberAllowed && offered.contains('remember') && choiceAllows('remember'),
    'offeredTools': offered,
    'diagnostics': diagnostics,
  });
}

Map<String, Object?> captureToolPolicyPatch(Map<String, Object?> patch, {required bool chatScope}) {
  Map<String, Object?> captured;
  try {
    captured = _copy(patch);
  } on FormatException {
    throw _policyError('invalid_tool_policy', 'toolPolicy');
  }
  for (final entry in captured.entries) {
    if (!const ['roll', 'remember'].contains(entry.key) || entry.value is! Map<String, Object?>) {
      throw _policyError('invalid_tool_policy', 'toolPolicy.${entry.key}');
    }
    final fields = entry.value! as Map<String, Object?>;
    for (final field in fields.entries) {
      final path = 'toolPolicy.${entry.key}.${field.key}';
      if (field.key == (chatScope ? 'enabled' : 'allow')) {
        if (field.value is! bool && !(chatScope && field.value == null)) {
          throw _policyError('invalid_tool_policy', path);
        }
      } else if (entry.key == 'remember' && field.key == 'mode') {
        if (field.value != 'ask' && field.value != 'auto' && !(chatScope && field.value == null)) {
          throw _policyError('invalid_tool_policy', path);
        }
      } else {
        throw _policyError('invalid_tool_policy', path);
      }
    }
  }
  return captured;
}

/// Merge against the caller's fresh carrier. Unknown original fields survive;
/// malformed existing containers are rejected instead of silently repaired.
Map<String, Object?> mergeToolPolicySettings(
  Map<String, Object?> currentSettings,
  Map<String, Object?> capturedPatch, {
  required bool chatScope,
}) {
  final patch = captureToolPolicyPatch(capturedPatch, chatScope: chatScope);
  final settings = _copy(currentSettings);
  final previous = settings['toolPolicy'];
  if (settings.containsKey('toolPolicy') && previous is! Map<String, Object?>) {
    throw _policyError('invalid_stored_policy', 'toolPolicy');
  }
  if (patch.isEmpty) return settings;
  final policy = previous == null ? <String, Object?>{} : _copy(previous as Map<String, Object?>);
  for (final entry in patch.entries) {
    final old = policy[entry.key];
    if (policy.containsKey(entry.key) && old is! Map<String, Object?>) {
      throw _policyError('invalid_stored_policy', 'toolPolicy.${entry.key}');
    }
    policy[entry.key] = {if (old is Map<String, Object?>) ...old, ...(entry.value! as Map<String, Object?>)};
  }
  settings['toolPolicy'] = policy;
  return settings;
}

TavernToolException _policyError(String message, String path) => TavernToolException(
  code: TavernToolErrorCode.invalidArgument,
  operation: 'setToolPolicy',
  message: message,
  committed: false,
  fieldPath: path,
);

List<Map<String, Object?>> _diagnostics(Map<String, Object?> data) =>
    List.unmodifiable([for (final item in data['diagnostics']! as List<Object?>) _copy(item! as Map<String, Object?>)]);

Map<String, Object?> _copy(Map<String, Object?> value) => _copyValue(value)! as Map<String, Object?>;
Object? _copyValue(Object? value) {
  void check(Object? item, Set<Object> parents) {
    if (item == null || item is String || item is bool || item is int) return;
    if (item is double && item.isFinite) return;
    if (item is Map<String, Object?> || item is List<Object?>) {
      if (!parents.add(item)) throw const FormatException('Cyclic tool policy JSON.');
      final children = item is Map<String, Object?> ? item.values : (item as List<Object?>);
      for (final child in children) {
        check(child, parents);
      }
      parents.remove(item);
      return;
    }
    throw const FormatException('Tool policy requires finite JSON.');
  }

  check(value, Set<Object>.identity());
  return jsonDecode(jsonEncode(value));
}
