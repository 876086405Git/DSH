import 'dart:convert';

import '../json_copy.dart';
import '../preset_library.dart';
import '../prompt/preset.dart';

/// Detached validation result. Decoding executes no macro, connection or tool.
final class DecodedPreset {
  DecodedPreset({
    required this.name,
    required Map<String, Object?> raw,
    Map<String, Object?>? envelope,
    Iterable<TavernPresetIssue> issues = const [],
  }) : _raw = _copy(raw),
       _envelope = envelope == null ? null : _copy(envelope),
       issues = List<TavernPresetIssue>.unmodifiable(issues);

  final String name;
  final Map<String, Object?> _raw;
  final Map<String, Object?>? _envelope;
  final List<TavernPresetIssue> issues;
  Map<String, Object?> get raw => _copy(_raw);
  Map<String, Object?>? get envelope => _envelope == null ? null : _copy(_envelope);
}

/// Reads native ST JSON and the MIT dsh-preset-enhance version 1 envelope.
/// Format reference: bychv/dsh-preset-enhance commit
/// a7717ddc76f3985cf6a71ac6ee463911886b15a5, PRESET_FORMAT.md.
/// ADDENDUM-04 requires our default target to be content; the reference
/// plugin's implicit reasoning target is deliberately not inherited.
final class PresetCodec {
  const PresetCodec();

  DecodedPreset decode(String sourceText, {String? fileName}) {
    Object? document;
    try {
      document = jsonDecode(sourceText.startsWith('\uFEFF') ? sourceText.substring(1) : sourceText);
    } on FormatException {
      throw TavernPresetImportError([_issue(r'$', 'invalid-json', '文件不是有效的 JSON。')]);
    }
    if (document is! Map<String, Object?>) {
      throw TavernPresetImportError([_issue(r'$', 'object-required', '预设必须是 JSON 对象。')]);
    }
    final validation = _Validation();
    Map<String, Object?> raw;
    Map<String, Object?>? envelope;
    final wrapper = document['format'] == 'dsh-preset-enhance';
    if (wrapper) {
      envelope = _jsonCopy(document);
      validation.envelope(envelope, requireData: true);
      validation.throwIfInvalid();
      raw = _copy((envelope['preset']! as Map<String, Object?>)['data']! as Map<String, Object?>);
      validation.raw(raw, r'$.preset.data');
      final saved = validation.savedEnvelope(raw, reportFeatures: false, rawPath: r'$.preset.data');
      if (saved != null) {
        final outer = _copy(envelope);
        (outer['preset']! as Map<String, Object?>).remove('data');
        if (!_sameJson(saved, outer)) {
          validation.add(
            r'$.preset.data.extensions.dshgo.presetEnvelope',
            'conflicting-envelope-carrier',
            '内嵌载体与当前分享外壳不同，无法无损确定外壳来源。',
          );
        }
      }
      validation.applyPackagePrefill(raw, envelope);
    } else {
      raw = _jsonCopy(document);
      validation.raw(raw, r'$');
      envelope = validation.savedEnvelope(raw);
    }
    validation.throwIfInvalid();
    _syncEnvelope(envelope, raw);
    return DecodedPreset(name: _name(envelope, fileName), raw: raw, envelope: envelope, issues: validation.issues);
  }

  /// A retained envelope is descriptive data: its old prefill switch never
  /// overrides the edited document's current extensions.dshgo configuration.
  DecodedPreset validate(Map<String, Object?> raw, {Map<String, Object?>? envelope}) {
    final value = _jsonCopy(raw);
    final wrapper = envelope == null ? null : _jsonCopy(envelope);
    final validation = _Validation();
    validation.raw(value, r'$');
    final saved = validation.savedEnvelope(value, reportFeatures: wrapper == null);
    final retained = wrapper ?? saved;
    if (wrapper != null) {
      validation.envelope(wrapper, requireData: false);
    }
    validation.throwIfInvalid();
    _syncEnvelope(retained, value);
    return DecodedPreset(name: _name(retained, null), raw: value, envelope: retained, issues: validation.issues);
  }

  /// The saved envelope excludes preset.data, preventing recursive growth
  /// across repeated native ST export/import cycles. Export does not re-run
  /// import normalization: legacy setPreset documents retain their raw values.
  String encode(Map<String, Object?> raw, {Map<String, Object?>? envelope}) {
    final value = _jsonCopy(raw);
    final validation = _Validation();
    // A legacy helper may have retained any JSON under this now-reserved key.
    // Only an explicitly supplied stored envelope is materialized on export.
    final retained = envelope == null ? null : _jsonCopy(envelope);
    if (retained != null) {
      validation.envelope(retained, requireData: false);
      final extensions = value['extensions'];
      if (extensions != null && extensions is! Map<String, Object?>) {
        validation.add(r'$.extensions', 'object-required', '保存分享外壳需要对象类型的 extensions。');
      }
      final dshgo = extensions is Map<String, Object?> ? extensions['dshgo'] : null;
      if (dshgo != null && dshgo is! Map<String, Object?>) {
        validation.add(r'$.extensions.dshgo', 'object-required', '保存分享外壳需要对象类型的 dshgo。');
      }
      validation.throwIfInvalid();
      (retained['preset']! as Map<String, Object?>).remove('data');
      _namespace(value)['presetEnvelope'] = retained;
    }
    validation.throwIfInvalid();
    return const JsonEncoder.withIndent('  ').convert(value);
  }
}

final class _Validation {
  final issues = <TavernPresetIssue>[];

  void add(
    String path,
    String code,
    String message, {
    String? identifier,
    TavernPresetIssueSeverity severity = TavernPresetIssueSeverity.error,
  }) {
    issues.add(TavernPresetIssue(path: path, code: code, message: message, identifier: identifier, severity: severity));
  }

  void normalized(String path, String message, {String? identifier}) =>
      add(path, 'normalized', message, identifier: identifier, severity: TavernPresetIssueSeverity.normalized);

  void warning(String path, String code, String message, {String? identifier}) =>
      add(path, code, message, identifier: identifier, severity: TavernPresetIssueSeverity.warning);

  void throwIfInvalid() {
    if (issues.any((issue) => issue.severity == TavernPresetIssueSeverity.error)) {
      throw TavernPresetImportError(issues);
    }
  }

  void raw(Map<String, Object?> value, String path) {
    final extension = value['extensions'];
    if (extension != null && extension is! Map<String, Object?>) {
      add('$path.extensions', 'object-required', 'extensions 必须是对象或 null。');
    }
    final dshgo = extension is Map<String, Object?> ? extension['dshgo'] : null;
    if (dshgo != null && dshgo is! Map<String, Object?>) {
      add('$path.extensions.dshgo', 'object-required', 'dshgo 扩展必须是对象或 null。');
    }
    if (dshgo is Map<String, Object?> && dshgo.containsKey('prefill')) {
      final prefill = dshgo['prefill'];
      if (prefill is! Map<String, Object?>) {
        add('$path.extensions.dshgo.prefill', 'object-required', '增强预填充设置必须是对象。');
      } else {
        if (prefill.containsKey('enabled') && prefill['enabled'] is! bool) {
          add('$path.extensions.dshgo.prefill.enabled', 'boolean-required', 'enabled 必须是布尔值。');
        }
        if (prefill.containsKey('target') && !const ['content', 'reasoning'].contains(prefill['target'])) {
          add('$path.extensions.dshgo.prefill.target', 'invalid-prefill-target', 'target 必须为 content 或 reasoning。');
        }
      }
    }
    if (value.containsKey('dsh_prefill_target') &&
        !const ['content', 'reasoning'].contains(value['dsh_prefill_target'])) {
      add('$path.dsh_prefill_target', 'invalid-prefill-target', 'dsh_prefill_target 必须为 content 或 reasoning。');
    }
    if (value.containsKey('assistant_prefill') && value['assistant_prefill'] is! String) {
      value['assistant_prefill'] = presetContent(value['assistant_prefill']);
      normalized('$path.assistant_prefill', 'assistant_prefill 已按 ST 文本读取规则转为字符串。');
    }
    final identifiers = <String>{};
    final prompts = value['prompts'];
    if (value.containsKey('prompts') && prompts is! List<Object?>) {
      add('$path.prompts', 'array-required', 'prompts 必须是数组；旧格式可省略此字段。');
    }
    if (prompts is List<Object?>) {
      for (var index = 0; index < prompts.length; index++) {
        final prompt = prompts[index];
        final location = '$path.prompts[$index]';
        if (prompt is! Map<String, Object?>) {
          add(location, 'object-required', '提示词条目必须是对象。');
          continue;
        }
        final candidate = prompt['identifier'];
        final id = candidate is String && candidate.isNotEmpty ? candidate : null;
        if (id == null) {
          add('$location.identifier', 'invalid-identifier', 'identifier 必须是非空字符串。');
        } else if (!identifiers.add(id)) {
          add('$location.identifier', 'duplicate-identifier', '提示词 identifier 重复。', identifier: id);
        }
        if (!prompt.containsKey('role')) {
          prompt['role'] = 'system';
          normalized('$location.role', '缺省 role 已设为 system。', identifier: id);
        } else {
          final role = prompt['role'];
          final canonical = role is String ? role.trim().toLowerCase() : null;
          if (!const ['system', 'user', 'assistant', 'model'].contains(canonical)) {
            add('$location.role', 'invalid-role', 'role 必须是 system、user 或 assistant。', identifier: id);
          } else {
            final result = canonical == 'model' ? 'assistant' : canonical!;
            if (result != role) {
              prompt['role'] = result;
              normalized('$location.role', 'role 已规范为 $result。', identifier: id);
            }
          }
        }
        _integer(prompt, 'injection_position', location, id, position: true);
        _integer(prompt, 'injection_depth', location, id);
        if (prompt.containsKey('content') && prompt['content'] is! String) {
          prompt['content'] = presetContent(prompt['content']);
          normalized('$location.content', 'content 已按 ST 文本读取规则转为字符串。', identifier: id);
        }
        if (prompt.containsKey('contextFiles') || prompt.containsKey('contextFile')) {
          warning(location, 'attachments-preserved', '预设附件原样保留，本接口尚不注入图片或文件。', identifier: id);
        }
      }
    }
    final builtins = ChatPreset.stDefault().raw['prompts']! as List<Object?>;
    identifiers.addAll(builtins.whereType<Map<String, Object?>>().map((entry) => entry['identifier']! as String));
    _order(value['prompt_order'], path, identifiers);
  }

  void _order(Object? groups, String path, Set<String> identifiers) {
    if (groups != null && groups is! List<Object?>) {
      add('$path.prompt_order', 'array-required', 'prompt_order 必须是数组或 null。');
    }
    if (groups is! List<Object?>) {
      return;
    }
    for (var groupIndex = 0; groupIndex < groups.length; groupIndex++) {
      final group = groups[groupIndex];
      final groupPath = '$path.prompt_order[$groupIndex]';
      if (group is! Map<String, Object?>) {
        add(groupPath, 'object-required', '顺序组必须是对象。');
        continue;
      }
      final order = group['order'];
      if (order == null) {
        warning('$groupPath.order', 'empty-order', '缺省或 null 顺序表保持空组，不借用其他组。');
        continue;
      }
      if (order is! List<Object?>) {
        add('$groupPath.order', 'array-required', 'order 必须是数组或 null。');
        continue;
      }
      final seen = <String>{};
      for (var index = 0; index < order.length; index++) {
        final entry = order[index];
        final location = '$groupPath.order[$index]';
        if (entry is! Map<String, Object?>) {
          add(location, 'object-required', '顺序条目必须是对象。');
          continue;
        }
        final candidate = entry['identifier'];
        final id = candidate is String && candidate.isNotEmpty ? candidate : null;
        if (id == null) {
          add('$location.identifier', 'invalid-identifier', '顺序 identifier 必须是非空字符串。');
        } else if (!seen.add(id)) {
          add('$location.identifier', 'duplicate-order-identifier', '同组顺序 identifier 重复。', identifier: id);
        } else if (!identifiers.contains(id)) {
          warning('$location.identifier', 'missing-prompt', '顺序表引用了不存在的提示词。', identifier: id);
        }
        if (entry['enabled'] is! bool) {
          entry['enabled'] = presetTruthy(entry['enabled']);
          normalized('$location.enabled', 'enabled 已按 ST 真值规则转为布尔值。', identifier: id);
        }
      }
    }
  }

  void _integer(Map<String, Object?> entry, String key, String path, String? id, {bool position = false}) {
    if (!entry.containsKey(key)) {
      return;
    }
    final input = entry[key];
    num? number;
    if (input is num && input.isFinite && input == input.truncateToDouble()) {
      number = input;
    } else if (input is String && RegExp(r'^[+-]?[0-9]+$').hasMatch(input.trim())) {
      final parsed = num.tryParse(input.trim());
      if (parsed != null && parsed.isFinite && parsed == parsed.truncateToDouble()) {
        number = parsed;
      }
    }
    if (number == null || number < 0 || (position && number != 0 && number != 1)) {
      add(
        '$path.$key',
        position ? 'invalid-injection-position' : 'invalid-injection-depth',
        position ? '注入位置必须为整数 0 或 1。' : '注入深度必须为有限非负整数。',
        identifier: id,
      );
      return;
    }
    // Values beyond ST's accepted depth stay numeric without a saturating
    // double-to-int conversion. They are preserved and diagnosed below.
    if (input is String || (input is double && number <= 10000)) {
      entry[key] = number <= 10000 ? number.toInt() : number;
      normalized('$path.$key', '$key 已规范为整数。', identifier: id);
    }
    if (!position && number > 10000) {
      warning('$path.$key', 'depth-outside-st-range', '深度超过当前 ST 注入范围 10000，数据保留但不会注入。', identifier: id);
    }
  }

  void envelope(
    Map<String, Object?> value, {
    required bool requireData,
    String path = r'$',
    bool reportFeatures = true,
  }) {
    if (value['format'] != 'dsh-preset-enhance') {
      add('$path.format', 'unknown-envelope-format', '无法识别预设分享格式。');
    }
    if (value['version'] != 1) {
      add('$path.version', 'unsupported-envelope-version', '不支持此分享包主版本，未按普通 ST 文件降级读取。');
    }
    final preset = value['preset'];
    if (preset is! Map<String, Object?>) {
      add('$path.preset', 'object-required', 'preset 包装必须是对象。');
    } else {
      if (preset['format'] != 'sillytavern') {
        add('$path.preset.format', 'unknown-preset-format', 'preset.format 必须为 sillytavern。');
      }
      if (requireData && preset['data'] is! Map<String, Object?>) {
        add('$path.preset.data', 'object-required', 'preset.data 必须是 ST JSON 对象。');
      }
    }
    final metadata = value['metadata'];
    if (value.containsKey('metadata') && metadata is! Map<String, Object?>) {
      add('$path.metadata', 'object-required', 'metadata 必须是对象。');
    } else if (metadata is Map<String, Object?> && metadata.containsKey('name') && metadata['name'] is! String) {
      add('$path.metadata.name', 'string-required', '分享名称必须是字符串。');
    }
    if (value.containsKey('extensions') && value['extensions'] is! Map<String, Object?>) {
      add('$path.extensions', 'object-required', '分享包 extensions 必须是对象。');
    }
    final prefill = value['prefill'];
    if (prefill != null) {
      if (prefill is! Map<String, Object?>) {
        add('$path.prefill', 'object-required', 'prefill 必须是对象或 null。');
      } else {
        for (final key in ['enabled', 'toolCalls', 'removeNonOfficialTools']) {
          if (prefill[key] is! bool) {
            add('$path.prefill.$key', 'boolean-required', '$key 必须是布尔值。');
          }
        }
        if (prefill.containsKey('extractOutput') && prefill['extractOutput'] is! bool) {
          add('$path.prefill.extractOutput', 'boolean-required', 'extractOutput 必须是布尔值。');
        }
        final post = prefill['postToolPrefix'];
        if (post is! Map<String, Object?> ||
            !const ['inherit', 'custom'].contains(post['mode']) ||
            post['text'] is! String) {
          add(
            '$path.prefill.postToolPrefix',
            'invalid-post-tool-prefix',
            'postToolPrefix 须含 inherit/custom 的 mode 和字符串 text。',
          );
        }
        if (reportFeatures &&
            (prefill['toolCalls'] == true ||
                prefill['extractOutput'] == true ||
                (post is Map<String, Object?> && post['mode'] == 'custom'))) {
          warning('$path.prefill', 'prefill-features-preserved', '工具转换、正文提取及工具后自定义前缀仅保留，不在本项目执行。');
        }
      }
    }
    if (reportFeatures && value.containsKey('tools')) {
      warning('$path.tools', 'tools-preserved', '附带工具配置原样保留，不自动启用或执行。');
    }
  }

  void applyPackagePrefill(Map<String, Object?> raw, Map<String, Object?> envelope) {
    final attached = envelope['prefill'];
    if (attached is! Map<String, Object?> || attached['enabled'] is! bool) {
      return;
    }
    if (issues.any((issue) => issue.severity == TavernPresetIssueSeverity.error)) {
      return;
    }
    final dshgo = _namespace(raw);
    final previous = dshgo['prefill'];
    final current = previous is Map<String, Object?> ? previous : <String, Object?>{};
    final enabled = attached['enabled'];
    final target = raw['dsh_prefill_target'] ?? 'content';
    if ((current.containsKey('enabled') && current['enabled'] != enabled) ||
        (current.containsKey('target') && current['target'] != target)) {
      normalized(r'$.preset.data.extensions.dshgo.prefill', '附带的接口开关与目标已替换旧增强配置；未知增强字段保留。');
    }
    dshgo['prefill'] = {...current, 'enabled': enabled, 'target': target};
  }

  Map<String, Object?>? savedEnvelope(Map<String, Object?> raw, {bool reportFeatures = true, String rawPath = r'$'}) {
    final extension = raw['extensions'];
    final dshgo = extension is Map<String, Object?> ? extension['dshgo'] : null;
    if (dshgo is! Map<String, Object?> || !dshgo.containsKey('presetEnvelope')) {
      return null;
    }
    final saved = dshgo['presetEnvelope'];
    final path = '$rawPath.extensions.dshgo.presetEnvelope';
    if (saved is! Map<String, Object?>) {
      add(path, 'object-required', '保存的分享外壳必须是对象。');
      return null;
    }
    final result = _copy(saved);
    envelope(result, requireData: false, path: path, reportFeatures: reportFeatures);
    final preset = result['preset'];
    if (preset is Map<String, Object?> && preset.containsKey('data')) {
      add('$path.preset.data', 'noncanonical-envelope-carrier', '保存的分享外壳不能再次包含 preset.data。');
      return null;
    }
    return result;
  }
}

TavernPresetIssue _issue(String path, String code, String message) =>
    TavernPresetIssue(path: path, code: code, message: message, severity: TavernPresetIssueSeverity.error);

Map<String, Object?> _jsonCopy(Map<String, Object?> value) {
  try {
    return _copy(value);
  } on JsonUnsupportedObjectError {
    throw TavernPresetImportError([_issue(r'$', 'invalid-json-value', '预设只能包含有限数值及合法 JSON 数据。')]);
  }
}

Map<String, Object?> _copy(Map<String, Object?> value) => copyJsonObject(value);

bool _sameJson(Object? left, Object? right) {
  if (left is Map<String, Object?> && right is Map<String, Object?>) {
    return left.length == right.length &&
        left.keys.every((key) => right.containsKey(key) && _sameJson(left[key], right[key]));
  }
  if (left is List<Object?> && right is List<Object?>) {
    if (left.length != right.length) {
      return false;
    }
    for (var index = 0; index < left.length; index++) {
      if (!_sameJson(left[index], right[index])) {
        return false;
      }
    }
    return true;
  }
  return left == right;
}

Map<String, Object?> _namespace(Map<String, Object?> raw) {
  final extensions = raw['extensions'] ??= <String, Object?>{};
  final dshgo = (extensions as Map<String, Object?>)['dshgo'] ??= <String, Object?>{};
  return dshgo as Map<String, Object?>;
}

void _syncEnvelope(Map<String, Object?>? envelope, Map<String, Object?> raw) {
  if (envelope != null) {
    (envelope['preset']! as Map<String, Object?>)['data'] = _copy(raw);
  }
}

String _name(Map<String, Object?>? envelope, String? fileName) {
  final metadata = envelope?['metadata'];
  final name = metadata is Map<String, Object?> ? metadata['name'] : null;
  if (name is String && name.isNotEmpty) {
    return name;
  }
  final file = (fileName ?? '').replaceAll('\\', '/').split('/').last;
  final fallback = file.replaceFirst(RegExp(r'(?:\.dsh-preset)?\.json$', caseSensitive: false), '');
  return fallback.isEmpty ? '未命名预设' : fallback;
}
