import 'dart:convert';
import 'dart:isolate';

import '../import_report.dart';
import '../preset_library.dart';
import '../regex/regex_engine.dart';
import '../regex_library.dart';
import '../state/state_engine.dart' as state_core;
import '../worldinfo/world_info.dart';
import 'world_info_intake.dart';

/// Import inspection is CPU work over owned JSON, with no engine/store access.
/// Materialize iterable inputs before crossing the isolate boundary so a lazy
/// caller iterator cannot carry an engine or queue into the worker.
Future<TavernImportReport> assessImportAsync({
  required TavernImportKind kind,
  required Map<String, Object?> document,
  Map<String, Object?>? envelope,
  Iterable<String> embeddedAssetPaths = const [],
  Iterable<TavernRegexDiagnostic> regexDiagnostics = const [],
  Iterable<TavernPresetIssue> presetIssues = const [],
  required DateTime checkedAt,
  String path = r'$',
}) {
  final assets = embeddedAssetPaths.toList(growable: false);
  final diagnostics = regexDiagnostics.toList(growable: false);
  final issues = presetIssues.toList(growable: false);
  return Isolate.run(
    () => assessImport(
      kind: kind,
      document: document,
      envelope: envelope,
      embeddedAssetPaths: assets,
      regexDiagnostics: diagnostics,
      presetIssues: issues,
      checkedAt: checkedAt,
      path: path,
    ),
  );
}

/// Static capability inspection. JSON, macros, scripts and remote assets are
/// never executed here. Regex evidence comes from the protected importer.
/// State inspection only compiles explicit definitions; it does not construct
/// initial values, evaluate derive/rules, or inspect saved chat state.
/// [path] can retain an imported array member's original location. Preset
/// envelope findings use `$.envelope`; supplied codec issues retain their own
/// original import path, which may include `$.preset.data`.
TavernImportReport assessImport({
  required TavernImportKind kind,
  required Map<String, Object?> document,
  Map<String, Object?>? envelope,
  Iterable<String> embeddedAssetPaths = const [],
  Iterable<TavernRegexDiagnostic> regexDiagnostics = const [],
  Iterable<TavernPresetIssue> presetIssues = const [],
  required DateTime checkedAt,
  String path = r'$',
}) {
  final assets = embeddedAssetPaths.toSet();
  final inspection = _Intake();
  inspection.counts['embeddedFiles'] = assets.length;
  switch (kind) {
    case TavernImportKind.character:
      final data = _map(document['data']) ?? document;
      inspection.card(data, identical(data, document) ? path : '$path.data');
    case TavernImportKind.preset:
      inspection.preset(document, path, envelope, presetIssues);
    case TavernImportKind.lorebook:
      inspection.book(document, path, embedded: false);
    case TavernImportKind.regex:
      inspection.regexScript(document, path);
  }
  final diagnostics = regexDiagnostics.toList();
  inspection.regexChecks(diagnostics);
  final incomplete = diagnostics.any((item) => item.status == TavernRegexCompatibility.skipped);
  final hasGap = inspection.findings.any(
    (item) =>
        !item.conditional &&
        (item.kind == TavernImportFindingKind.unsupported || item.kind == TavernImportFindingKind.invalid),
  );
  var verdict = hasGap || incomplete ? TavernImportVerdict.partial : TavernImportVerdict.usable;
  if (kind == TavernImportKind.regex &&
      !_disabled(document) &&
      diagnostics.any(
        (item) =>
            item.status == TavernRegexCompatibility.incompatible &&
            !item.conditional &&
            (item.path == path || item.path == '$path.findRegex'),
      )) {
    verdict = TavernImportVerdict.preserveOnly;
  }
  if (kind == TavernImportKind.lorebook &&
      inspection.findings.any(
        (item) => const {'wi-invalid-entries', 'wi-invalid-entry', 'wi-invalid-book'}.contains(item.code),
      )) {
    verdict = TavernImportVerdict.preserveOnly;
  }
  return TavernImportReport(
    kind: kind,
    checkedAt: checkedAt,
    verdict: verdict,
    counts: inspection.counts,
    findings: inspection.findings,
    renderLevel: kind == TavernImportKind.character || inspection.renderLevel > 0 ? inspection.renderLevel : null,
    fingerprint: importFingerprint(kind, document, envelope: envelope, embeddedAssetPaths: assets),
  );
}

final class _Intake {
  final counts = <String, int>{
    'prompts': 0,
    'regexScripts': 0,
    'scripts': 0,
    'helperScripts': 0,
    'assets': 0,
    'embeddedFiles': 0,
    'htmlFragments': 0,
    'macroOccurrences': 0,
    'worldInfoBooks': 0,
    'entriesStored': 0,
    'entriesInExecutionView': 0,
    'entriesEnabled': 0,
    'entriesDisabled': 0,
    'primaryKeys': 0,
    'secondaryKeys': 0,
    'decoratorLines': 0,
    'recognizedDecorators': 0,
    'unknownDecorators': 0,
    'regexChecks': 0,
    'regexCompatible': 0,
    'regexLiteralFallback': 0,
    'regexIncompatible': 0,
    'regexDeferred': 0,
    'regexUnchecked': 0,
  };
  final findings = <TavernImportFinding>[];
  final _locations = <(String, String, int?, int?, String?)>{};
  var renderLevel = 0;

  void count(String key, [int amount = 1]) => counts.update(key, (value) => value + amount, ifAbsent: () => amount);

  void add(TavernImportFinding finding, {String? locationDetail}) {
    if (_locations.add((finding.code, finding.path, finding.line, finding.offset, locationDetail))) {
      findings.add(finding);
    }
  }

  void finding(
    String path,
    String code,
    String message, {
    TavernImportFindingKind kind = TavernImportFindingKind.unsupported,
    String? identifier,
    _TextField? field,
    int? offset,
    bool conditional = false,
  }) => add(
    TavernImportFinding(
      path: path,
      code: code,
      message: message,
      kind: conditional && kind == TavernImportFindingKind.unsupported ? TavernImportFindingKind.conditional : kind,
      identifier: identifier ?? field?.identifier,
      offset: offset,
      line: offset == null ? null : field?.lineAt(offset),
      conditional: conditional,
    ),
  );

  void card(Map<String, Object?> data, String path) {
    for (final key in const [
      'description',
      'personality',
      'scenario',
      'first_mes',
      'mes_example',
      'system_prompt',
      'post_history_instructions',
      'creator_notes',
    ]) {
      text(data[key], '$path.$key');
    }
    for (final key in const ['alternate_greetings', 'group_only_greetings']) {
      strings(data[key], '$path.$key');
    }
    final notes = _map(data['creator_notes_multilingual']);
    if (notes != null) {
      for (final entry in notes.entries) {
        text(entry.value, '$path.creator_notes_multilingual[${jsonEncode(entry.key)}]');
      }
    }
    final assets = data['assets'];
    if (assets is List<Object?>) {
      count('assets', assets.length);
    }
    final extensions = _map(data['extensions']);
    if (extensions != null) {
      regexList(extensions['regex_scripts'], '$path.extensions.regex_scripts');
      helpers(extensions, '$path.extensions');
      text(_map(extensions['depth_prompt'])?['prompt'], '$path.extensions.depth_prompt.prompt');
      final dshgo = _map(extensions['dshgo']);
      if (dshgo != null) {
        stateDefinition(dshgo, '$path.extensions.dshgo');
      }
    }
    final embedded = data['character_book'];
    if (embedded is Map<String, Object?>) {
      book(embedded, '$path.character_book', embedded: true);
    } else if (embedded != null) {
      finding(
        '$path.character_book',
        'invalid-world-book',
        '内嵌世界书不是对象，不能按世界书执行。',
        kind: TavernImportFindingKind.invalid,
      );
    }
  }

  void stateDefinition(Map<String, Object?> dshgo, String path) {
    final raw = _map(dshgo['state']);
    // Absence of schema is the legacy-card contract. Do not infer a schema,
    // reinterpret opaque extension values, or add new counts to old reports.
    if (raw == null || !raw.containsKey('schema')) {
      return;
    }
    count('stateDefinitions');
    final rules = raw['rules'];
    // Declared rows, including invalid ones; this is not an execution count.
    count('stateRules', rules is List<Object?> ? rules.length : 0);
    final definition = state_core.StateDefinition.parse(raw, version: dshgo.containsKey('v') ? dshgo['v'] : 1);
    final before = findings.length;
    for (final issue in definition.issues) {
      final code = issue['code']! as String;
      final location = code == 'state_version'
          ? '$path.v'
          : _stateIssuePath(raw, '$path.state', issue['path']! as String);
      finding(
        location,
        code,
        issue['message']! as String,
        kind: switch (issue['kind']) {
          'unknown' => TavernImportFindingKind.unknown,
          'unsupported' => TavernImportFindingKind.unsupported,
          _ => TavernImportFindingKind.invalid,
        },
      );
    }
    count('stateDefinitionIssues', findings.length - before);
  }

  void preset(
    Map<String, Object?> raw,
    String path,
    Map<String, Object?>? envelope,
    Iterable<TavernPresetIssue> issues,
  ) {
    final prompts = raw['prompts'];
    if (prompts is List<Object?>) {
      count('prompts', prompts.length);
      for (var index = 0; index < prompts.length; index++) {
        final prompt = _map(prompts[index]);
        if (prompt == null) {
          continue;
        }
        final location = '$path.prompts[$index]';
        final identifier = prompt['identifier'] is String ? prompt['identifier'] as String : null;
        text(prompt['content'], '$location.content', identifier: identifier);
        for (final key in const ['contextFile', 'contextFiles']) {
          final attached = prompt[key];
          if (!_hasValue(attached)) {
            continue;
          }
          if (attached is List<Object?>) {
            for (var item = 0; item < attached.length; item++) {
              if (!_hasValue(attached[item])) {
                continue;
              }
              finding(
                '$location.$key[$item]',
                'preset-attachment-not-injected',
                '预设附件保留，但本引擎不注入该图片或文件。',
                identifier: identifier,
              );
            }
          } else {
            finding(
              '$location.$key',
              'preset-attachment-not-injected',
              '预设附件保留，但本引擎不注入该图片或文件。',
              identifier: identifier,
            );
          }
        }
      }
    }
    for (final key in const [
      'assistant_prefill',
      'assistant_impersonation',
      'main_prompt',
      'nsfw_prompt',
      'jailbreak_prompt',
      'new_chat_prompt',
      'new_group_chat_prompt',
      'new_example_chat_prompt',
      'continue_nudge_prompt',
      'group_nudge_prompt',
      'impersonation_prompt',
      'send_if_empty',
      'scenario_format',
      'personality_format',
    ]) {
      text(raw[key], '$path.$key');
    }
    final extensions = _map(raw['extensions']);
    if (extensions != null) {
      regexList(extensions['regex_scripts'], '$path.extensions.regex_scripts');
      helpers(extensions, '$path.extensions');
    }
    if (envelope != null) {
      final prefix = '$path.envelope';
      final prefill = _map(envelope['prefill']);
      if (prefill != null) {
        final inactive = prefill['enabled'] == false;
        if (prefill['toolCalls'] == true) {
          finding(
            '$prefix.prefill.toolCalls',
            'prefill-tool-conversion-not-executed',
            '分享包的工具调用转换仅保留，不在本引擎执行。',
            conditional: inactive,
          );
        }
        if (prefill['extractOutput'] == true) {
          finding(
            '$prefix.prefill.extractOutput',
            'prefill-output-extraction-not-executed',
            '分享包的正文提取仅保留，不在本引擎执行。',
            conditional: inactive,
          );
        }
        if (_map(prefill['postToolPrefix'])?['mode'] == 'custom') {
          finding(
            '$prefix.prefill.postToolPrefix.mode',
            'prefill-post-tool-prefix-not-executed',
            '分享包的工具后自定义前缀仅保留，不在本引擎执行。',
            conditional: inactive,
          );
        }
      }
      final tools = envelope['tools'];
      if (_hasValue(tools)) {
        finding('$prefix.tools', 'preset-tools-not-executed', '分享包附带的工具配置保留，不自动启用或执行。');
      }
    }
    for (final issue in issues) {
      if (issue.severity == TavernPresetIssueSeverity.normalized ||
          const {'prefill-features-preserved', 'attachments-preserved', 'tools-preserved'}.contains(issue.code)) {
        continue;
      }
      final unusable = const {'missing-prompt', 'depth-outside-st-range'}.contains(issue.code);
      add(
        TavernImportFinding(
          path: issue.path,
          code: issue.code,
          message: issue.message,
          identifier: issue.identifier,
          kind: issue.severity == TavernPresetIssueSeverity.error
              ? TavernImportFindingKind.invalid
              : unusable
              ? TavernImportFindingKind.unsupported
              : TavernImportFindingKind.conditional,
          conditional: !unusable && issue.severity != TavernPresetIssueSeverity.error,
        ),
      );
    }
  }

  void regexList(Object? value, String path) {
    if (value == null) {
      return;
    }
    if (value is! List<Object?>) {
      finding(path, 'invalid-rule-list', '正则列表必须为数组，原值保留但不执行。', kind: TavernImportFindingKind.invalid);
      return;
    }
    for (var index = 0; index < value.length; index++) {
      final raw = _map(value[index]);
      if (raw == null) {
        count('regexScripts');
        finding('$path[$index]', 'invalid-rule', '正则条目必须为对象，原值保留但不执行。', kind: TavernImportFindingKind.invalid);
      } else {
        regexScript(raw, '$path[$index]');
      }
    }
  }

  void regexScript(Map<String, Object?> raw, String path) {
    count('regexScripts');
    final identifier = raw['id'] is String ? raw['id'] as String : null;
    final view = RegexScript.fromJson(raw);
    final inactive = view.disabled;
    // Patterns are not display HTML. Replacement/trim strings are macro
    // inputs, but only a display script's replacement is rendered directly.
    text(
      raw['replaceString'],
      '$path.replaceString',
      identifier: identifier,
      render: view.markdownOnly,
      conditional: inactive,
    );
    strings(raw['trimStrings'], '$path.trimStrings', identifier: identifier, render: false, conditional: inactive);
    if (view.substituteRegex == 1 || view.substituteRegex == 2) {
      text(raw['findRegex'], '$path.findRegex', identifier: identifier, render: false, conditional: inactive);
    }
  }

  void regexChecks(List<TavernRegexDiagnostic> diagnostics) {
    for (final diagnostic in diagnostics) {
      count('regexChecks');
      switch (diagnostic.status) {
        case TavernRegexCompatibility.compatible:
          count('regexCompatible');
          continue;
        case TavernRegexCompatibility.literalFallback:
          count('regexLiteralFallback');
        case TavernRegexCompatibility.incompatible:
          count('regexIncompatible');
        case TavernRegexCompatibility.deferred:
          count('regexDeferred');
        case TavernRegexCompatibility.skipped:
          count('regexUnchecked');
      }
      final type = switch (diagnostic.status) {
        TavernRegexCompatibility.incompatible => TavernImportFindingKind.invalid,
        TavernRegexCompatibility.deferred => TavernImportFindingKind.deferred,
        TavernRegexCompatibility.skipped =>
          diagnostic.code == 'invalid-world-book' ? TavernImportFindingKind.invalid : TavernImportFindingKind.unknown,
        _ => TavernImportFindingKind.conditional,
      };
      // A header may contain several patterns on the same source line. Keep
      // every receipt, without inventing a UTF-16 offset for its parsed key.
      final detail = diagnostic.keyIndex == null
          ? null
          : '${diagnostic.decorator ?? 'decorator'}:${diagnostic.keyIndex}';
      final message = diagnostic.keyIndex == null
          ? diagnostic.message
          : '${diagnostic.message}（${diagnostic.decorator ?? '装饰器'} 的第 ${diagnostic.keyIndex! + 1} 个关键词。）';
      add(
        TavernImportFinding(
          path: diagnostic.path,
          code: diagnostic.code,
          message: message,
          kind: type,
          identifier: diagnostic.identifier,
          line: diagnostic.line,
          conditional: diagnostic.conditional,
          fallback: diagnostic.fallback,
        ),
        locationDetail: detail,
      );
    }
  }

  void book(Map<String, Object?> raw, String path, {required bool embedded}) {
    final inspected = inspectWorldInfoFeatures(raw, path: path, embedded: embedded);
    for (final entry in inspected.counts.entries) {
      count(entry.key, entry.value);
    }
    for (final issue in inspected.findings) {
      add(issue);
    }
    // Reuse the actual loader's source paths, UID normalization and disabled
    // semantics. Stored rows include shadowed V3 ids, unlike view.entries.
    final WorldInfoBook view;
    try {
      view = WorldInfoBook.fromJson(
        id: 'intake-text',
        source: embedded ? WorldInfoSource.character : WorldInfoSource.global,
        json: raw,
      );
    } on FormatException {
      return; // The WI helper already recorded the invalid structure.
    } on JsonUnsupportedObjectError {
      return;
    }
    final v3 = view.raw['entries'] is List<Object?>;
    for (final row in worldInfoStoredEntries(view)) {
      bookEntry(row.entry, '$path.${row.path}', v3: v3);
    }
  }

  void bookEntry(WorldInfoEntry entry, String path, {required bool v3}) {
    // Native disables only literal true; V3 enables only literal true. Fields
    // from the other dialect remain opaque preserved metadata in both cases.
    text(entry.raw['content'], '$path.content', identifier: entry.uid, conditional: entry.disabled);
    for (final key in v3 ? const ['keys', 'secondary_keys'] : const ['key', 'keysecondary']) {
      strings(entry.raw[key], '$path.$key', identifier: entry.uid, render: false, conditional: entry.disabled);
    }
  }

  void helpers(Map<String, Object?> extensions, String path) {
    final helper = _map(extensions['tavern_helper']);
    if (helper != null) {
      helperScripts(helper['scripts'], '$path.tavern_helper.scripts');
      final variables = helper['variables'];
      if (variables is Map<String, Object?> && variables.isNotEmpty) {
        count('helperVariables', variables.length);
        finding('$path.tavern_helper.variables', 'helper-variables-not-applied', '助手变量配置原样保留，不会自动注入本引擎的变量状态。');
        renderLevel = 2;
      }
    }
    helperScripts(extensions['TavernHelper_scripts'], '$path.TavernHelper_scripts');
  }

  void helperScripts(Object? value, String path, {bool parentDisabled = false}) {
    if (value is! List<Object?>) {
      return;
    }
    for (var index = 0; index < value.length; index++) {
      final script = _map(value[index]);
      if (script == null) {
        continue;
      }
      final itemPath = '$path[$index]';
      final inactive = parentDisabled || _disabled(script) || script['enabled'] == false;
      final children = script['scripts'] ?? script['children'];
      if (script['type'] == 'folder' || children is List<Object?>) {
        helperScripts(
          children,
          '$itemPath.${script['scripts'] != null ? 'scripts' : 'children'}',
          parentDisabled: inactive,
        );
        continue;
      }
      final content = script['content'];
      final source = script['src'];
      if (!(content is String && content.trim().isNotEmpty) && !(source is String && source.trim().isNotEmpty)) {
        continue;
      }
      count('scripts');
      count('helperScripts');
      finding(
        itemPath,
        'helper-script-not-executed',
        '此助手脚本保留原文；本引擎不提供助手脚本执行环境。',
        identifier: script['id'] is String ? script['id'] as String : null,
        conditional: inactive,
      );
      renderLevel = 2;
    }
  }

  void strings(Object? value, String path, {String? identifier, bool render = true, bool conditional = false}) {
    if (value is! List<Object?>) {
      return;
    }
    for (var index = 0; index < value.length; index++) {
      text(value[index], '$path[$index]', identifier: identifier, render: render, conditional: conditional);
    }
  }

  void text(Object? value, String path, {String? identifier, bool render = true, bool conditional = false}) {
    if (value is! String || value.isEmpty) {
      return;
    }
    final field = _TextField(value, identifier);
    for (final macro in _macroUses(value)) {
      count('macroOccurrences');
      if (macro.name == 'banned') {
        finding(
          path,
          'macro-banned-no-effect',
          'banned 不会给当前 Chat Completion 请求添加禁词约束；文本处理取决于宏语法。',
          field: field,
          offset: macro.offset,
          conditional: conditional || macro.nested,
        );
      }
    }
    if (!render) {
      return;
    }
    var hasHtml = false;
    for (final tag in _htmlTags(value)) {
      if (!_htmlNames.contains(tag.name)) {
        continue;
      }
      hasHtml = true;
      if (renderLevel < 1) {
        renderLevel = 1;
      }
      if (tag.closing) {
        continue;
      }
      if (tag.name == 'script') {
        final type = tag.attributes['type']?.value.trim().toLowerCase() ?? '';
        final hasCode =
            (tag.body?.trim().isNotEmpty ?? false) || (tag.attributes['src']?.value.trim().isNotEmpty ?? false);
        if (_javascriptTypes.contains(type) && hasCode) {
          count('scripts');
          finding(
            path,
            'embedded-script-not-executed',
            '检测到脚本元素；原文保留，本引擎不执行其中的脚本。',
            field: field,
            offset: tag.start,
            conditional: conditional,
          );
          renderLevel = 2;
        }
      } else if (tag.name == 'style' && tag.body != null) {
        for (final offset in _crossMessageSelectors(tag.body!)) {
          finding(
            path,
            'cross-message-style',
            '该样式选择器引用跨消息结构，单条消息容器无法完整表达。',
            kind: TavernImportFindingKind.conditional,
            field: field,
            offset: tag.bodyStart! + offset,
            conditional: true,
          );
          renderLevel = 2;
        }
      }
      for (final entry in tag.attributes.entries) {
        if (entry.value.value.trim().isEmpty) {
          continue;
        }
        final event = _eventAttributes.contains(entry.key);
        final javascriptUrl =
            const {'href', 'src', 'action', 'formaction'}.contains(entry.key) &&
            entry.value.value.trimLeft().toLowerCase().startsWith('javascript:');
        if (event || javascriptUrl) {
          count('scripts');
          finding(
            path,
            event ? 'event-script-not-executed' : 'javascript-url-not-executed',
            '检测到显式脚本属性；原文保留，本引擎不执行该代码。',
            field: field,
            offset: entry.value.offset,
            conditional: conditional,
          );
          renderLevel = 2;
        }
      }
    }
    if (hasHtml) {
      count('htmlFragments');
    }
  }
}

Map<String, Object?>? _map(Object? value) => value is Map<String, Object?> ? value : null;

final _pathField = RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$');

/// The pure compiler reports JSON Pointers relative to state. Walk the raw
/// containers so an object key "0" cannot be confused with an array index.
String _stateIssuePath(Object? raw, String path, String pointer) {
  var current = raw;
  for (final escaped in pointer.split('/').skip(1)) {
    final token = escaped.replaceAll('~1', '/').replaceAll('~0', '~');
    final index = current is List<Object?> ? int.tryParse(token) : null;
    if (current is List<Object?> && index != null && index >= 0 && '$index' == token) {
      path += '[$index]';
      current = index < current.length ? current[index] : null;
    } else {
      final simple = _pathField.firstMatch(token);
      path += simple != null && simple.end == token.length ? '.$token' : '[${jsonEncode(token)}]';
      current = _map(current)?[token];
    }
  }
  return path;
}

bool _truthy(Object? value) =>
    value != null && value != false && value != '' && !(value is num && (value == 0 || value.isNaN));
bool _disabled(Map<String, Object?> value) => _truthy(value['disabled']);
bool _hasValue(Object? value) =>
    value != null &&
    !(value is String && value.trim().isEmpty) &&
    !(value is List<Object?> && value.isEmpty) &&
    !(value is Map<String, Object?> && value.isEmpty);

final class _TextField {
  _TextField(this.text, this.identifier);
  final String text;
  final String? identifier;
  late final List<int> _lineStarts = _lines();

  List<int> _lines() {
    final starts = <int>[0];
    for (var index = 0; index < text.length; index++) {
      final unit = text.codeUnitAt(index);
      if (unit == 13) {
        if (index + 1 < text.length && text.codeUnitAt(index + 1) == 10) {
          index++;
        }
        starts.add(index + 1);
      } else if (unit == 10) {
        starts.add(index + 1);
      }
    }
    return starts;
  }

  int lineAt(int offset) {
    var low = 0;
    var high = _lineStarts.length;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (_lineStarts[middle] <= offset) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low;
  }
}

typedef _MacroUse = ({String name, int offset, bool nested});
final _macroSpace = RegExp(r'\s');

/// A name/position scanner, deliberately not a macro evaluator or arity
/// checker. Nested calls may be inside a skipped branch or comment, so their
/// limitations are conditional. Markdown code does not suppress macro input.
List<_MacroUse> _macroUses(String text) {
  final stack = <int>[];
  final uses = <_MacroUse>[];
  var index = 0;
  while (index + 1 < text.length) {
    if (text.startsWith('{{', index)) {
      if (stack.isEmpty && text.startsWith('{{{', index)) {
        index++;
        continue;
      }
      stack.add(index);
      index += 2;
      continue;
    }
    if (!text.startsWith('}}', index) || stack.isEmpty) {
      index++;
      continue;
    }
    final start = stack.removeLast();
    final end = index;
    index += 2;
    var cursor = start + 2;
    while (cursor < end && _macroSpace.hasMatch(text[cursor])) {
      cursor++;
    }
    var closing = false;
    while (cursor < end && '!?~#/>'.contains(text[cursor]) && !text.startsWith('//', cursor)) {
      closing = closing || text[cursor] == '/';
      cursor++;
      while (cursor < end && _macroSpace.hasMatch(text[cursor])) {
        cursor++;
      }
    }
    if (closing || cursor >= end || !_asciiLetter(text.codeUnitAt(cursor))) {
      continue;
    }
    final nameStart = cursor++;
    while (cursor < end && _macroNameUnit(text.codeUnitAt(cursor))) {
      cursor++;
    }
    if (cursor < end && !_macroSpace.hasMatch(text[cursor]) && text[cursor] != ':' && text[cursor] != '|') {
      continue;
    }
    uses.add((name: text.substring(nameStart, cursor).toLowerCase(), offset: start, nested: stack.isNotEmpty));
  }
  uses.sort((a, b) => a.offset.compareTo(b.offset));
  return uses;
}

bool _asciiLetter(int unit) => (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122);
bool _digit(int unit) => unit >= 48 && unit <= 57;
bool _macroNameUnit(int unit) => _asciiLetter(unit) || _digit(unit) || unit == 95 || unit == 45;
bool _htmlSpace(int unit) => unit == 32 || unit == 9 || unit == 10 || unit == 12 || unit == 13;

final class _HtmlAttribute {
  const _HtmlAttribute(this.value, this.offset);
  final String value;
  final int offset;
}

final class _HtmlTag {
  const _HtmlTag({
    required this.name,
    required this.start,
    required this.end,
    required this.closing,
    required this.attributes,
    this.body,
    this.bodyStart,
  });
  final String name;
  final int start;
  final int end;
  final bool closing;
  final Map<String, _HtmlAttribute> attributes;
  final String? body;
  final int? bodyStart;
}

/// Conservative lexical HTML evidence, with source UTF-16 positions. This is
/// not a browser/Markdown parser: no entities, CSS escapes, macros, template
/// output or remote document is expanded. A negative result is not a promise
/// about eventual rendered output.
Iterable<_HtmlTag> _htmlTags(String text) sync* {
  var index = 0;
  int? fence;
  var fenceLength = 0;
  while (index < text.length) {
    final lineStart = index == 0 || text.codeUnitAt(index - 1) == 10 || text.codeUnitAt(index - 1) == 13;
    if (lineStart) {
      var marker = index;
      while (marker < text.length && marker - index < 3 && text.codeUnitAt(marker) == 32) {
        marker++;
      }
      if (marker < text.length && (text.codeUnitAt(marker) == 96 || text.codeUnitAt(marker) == 126)) {
        final unit = text.codeUnitAt(marker);
        var end = marker;
        while (end < text.length && text.codeUnitAt(end) == unit) {
          end++;
        }
        if (fence != null) {
          var suffix = end;
          while (suffix < text.length &&
              _htmlSpace(text.codeUnitAt(suffix)) &&
              text.codeUnitAt(suffix) != 10 &&
              text.codeUnitAt(suffix) != 13) {
            suffix++;
          }
          if (unit == fence &&
              end - marker >= fenceLength &&
              (suffix == text.length || text.codeUnitAt(suffix) == 10 || text.codeUnitAt(suffix) == 13)) {
            fence = null;
          }
          index = _afterLine(text, end);
          continue;
        }
        if (end - marker >= 3) {
          fence = unit;
          fenceLength = end - marker;
          index = _afterLine(text, end);
          continue;
        }
      }
      if (fence != null) {
        index = _afterLine(text, index);
        continue;
      }
      // Obvious indented code lines are not positive markup evidence. An
      // eventual Markdown renderer may apply additional surrounding context.
      if (text.codeUnitAt(index) == 9 || text.startsWith('    ', index)) {
        index = _afterLine(text, index);
        continue;
      }
    }
    if (fence != null) {
      index++;
      continue;
    }
    if (text.codeUnitAt(index) == 92 && index + 1 < text.length && _markdownPunctuation(text.codeUnitAt(index + 1))) {
      index += 2;
      continue;
    }
    if (text.codeUnitAt(index) == 96) {
      var end = index + 1;
      while (end < text.length && text.codeUnitAt(end) == 96) {
        end++;
      }
      final marker = text.substring(index, end);
      var close = text.indexOf(marker, end);
      while (close >= 0 &&
          ((close > 0 && text.codeUnitAt(close - 1) == 96) ||
              (close + marker.length < text.length && text.codeUnitAt(close + marker.length) == 96))) {
        close = text.indexOf(marker, close + marker.length);
      }
      index = close < 0 ? end : close + marker.length;
      continue;
    }
    if (text.startsWith('<!--', index)) {
      final end = text.indexOf('-->', index + 4);
      index = end < 0 ? text.length : end + 3;
      continue;
    }
    if (text.codeUnitAt(index) != 60) {
      index++;
      continue;
    }
    final tag = _readTag(text, index);
    if (tag == null) {
      index++;
      continue;
    }
    if (!tag.closing && _rawTextNames.contains(tag.name)) {
      final close = _rawTagClose(text, tag.end, tag.name);
      final bodyEnd = close < 0 || tag.name == 'plaintext' ? text.length : close;
      yield _HtmlTag(
        name: tag.name,
        start: tag.start,
        end: tag.end,
        closing: false,
        attributes: tag.attributes,
        body: text.substring(tag.end, bodyEnd),
        bodyStart: tag.end,
      );
      index = bodyEnd;
    } else {
      yield tag;
      index = tag.end;
    }
  }
}

int _afterLine(String text, int index) {
  while (index < text.length && text.codeUnitAt(index) != 10 && text.codeUnitAt(index) != 13) {
    index++;
  }
  if (index < text.length && text.codeUnitAt(index) == 13) {
    index++;
  }
  if (index < text.length && text.codeUnitAt(index) == 10) {
    index++;
  }
  return index;
}

bool _markdownPunctuation(int unit) =>
    (unit >= 33 && unit <= 47) ||
    (unit >= 58 && unit <= 64) ||
    (unit >= 91 && unit <= 96) ||
    (unit >= 123 && unit <= 126);

_HtmlTag? _readTag(String text, int start) {
  var index = start + 1;
  final closing = index < text.length && text.codeUnitAt(index) == 47;
  if (closing) {
    index++;
  }
  if (index >= text.length || !_asciiLetter(text.codeUnitAt(index))) {
    return null;
  }
  final nameStart = index++;
  while (index < text.length &&
      (_asciiLetter(text.codeUnitAt(index)) ||
          _digit(text.codeUnitAt(index)) ||
          text.codeUnitAt(index) == 45 ||
          text.codeUnitAt(index) == 58)) {
    index++;
  }
  final name = text.substring(nameStart, index).toLowerCase();
  if (index >= text.length || (!_htmlSpace(text.codeUnitAt(index)) && text[index] != '>' && text[index] != '/')) {
    return null;
  }
  final attributes = <String, _HtmlAttribute>{};
  while (index < text.length) {
    while (index < text.length && _htmlSpace(text.codeUnitAt(index))) {
      index++;
    }
    if (index >= text.length) {
      return null;
    }
    if (text[index] == '<') {
      return null;
    }
    if (text[index] == '>') {
      return _HtmlTag(name: name, start: start, end: index + 1, closing: closing, attributes: attributes);
    }
    if (text[index] == '/' && index + 1 < text.length && text[index + 1] == '>') {
      return _HtmlTag(name: name, start: start, end: index + 2, closing: closing, attributes: attributes);
    }
    final attributeStart = index;
    while (index < text.length &&
        !_htmlSpace(text.codeUnitAt(index)) &&
        !const {'=', '>', '/', '<', '"', "'"}.contains(text[index])) {
      index++;
    }
    if (index == attributeStart) {
      index++;
      continue;
    }
    final attributeName = text.substring(attributeStart, index).toLowerCase();
    while (index < text.length && _htmlSpace(text.codeUnitAt(index))) {
      index++;
    }
    var value = '';
    if (index < text.length && text[index] == '=') {
      index++;
      while (index < text.length && _htmlSpace(text.codeUnitAt(index))) {
        index++;
      }
      if (index >= text.length) {
        return null;
      }
      final quote = text[index];
      if (quote == '"' || quote == "'") {
        final valueStart = ++index;
        final end = text.indexOf(quote, index);
        if (end < 0) {
          return null;
        }
        value = text.substring(valueStart, end);
        index = end + 1;
      } else {
        final valueStart = index;
        while (index < text.length && !_htmlSpace(text.codeUnitAt(index)) && text[index] != '>') {
          index++;
        }
        value = text.substring(valueStart, index);
      }
    }
    // HTML ignores later duplicate attributes; they are not extra scripts.
    attributes.putIfAbsent(attributeName, () => _HtmlAttribute(value, attributeStart));
  }
  return null;
}

int _rawTagClose(String text, int start, String name) {
  var index = text.indexOf('</', start);
  while (index >= 0) {
    final end = index + 2 + name.length;
    if (end <= text.length &&
        text.substring(index + 2, end).toLowerCase() == name &&
        (end == text.length || _htmlSpace(text.codeUnitAt(end)) || text[end] == '>' || text[end] == '/')) {
      return index;
    }
    index = text.indexOf('</', index + 2);
  }
  return -1;
}

Iterable<int> _crossMessageSelectors(String css) sync* {
  // Mask quoted values and comments without changing any source offsets.
  final units = css.codeUnits.toList();
  var index = 0;
  while (index < units.length) {
    if (css.startsWith('/*', index)) {
      final close = css.indexOf('*/', index + 2);
      final end = close < 0 ? css.length : close + 2;
      // A comment between #chat and .mes is not a descendant combinator.
      // NUL is an internal ignored marker, never inserted into source JSON.
      while (index < end) {
        units[index++] = 0;
      }
      continue;
    }
    if (units[index] == 34 || units[index] == 39) {
      final quote = units[index];
      units[index++] = 32;
      while (index < units.length) {
        final unit = units[index];
        units[index++] = 32;
        if (unit == 92 && index < units.length) {
          units[index++] = 32;
          continue;
        }
        if (unit == quote) {
          break;
        }
      }
      continue;
    }
    index++;
  }
  final masked = String.fromCharCodes(units);
  var start = 0;
  var parentheses = 0;
  var brackets = 0;
  for (index = 0; index < masked.length; index++) {
    final unit = masked.codeUnitAt(index);
    if (unit == 40) {
      parentheses++;
      continue;
    }
    if (unit == 41) {
      if (parentheses > 0) {
        parentheses--;
      }
      continue;
    }
    if (unit == 91) {
      brackets++;
      continue;
    }
    if (unit == 93) {
      if (brackets > 0) {
        brackets--;
      }
      continue;
    }
    if (parentheses != 0 || brackets != 0) {
      continue;
    }
    if (unit == 123) {
      var first = start;
      while (first < index && (_htmlSpace(masked.codeUnitAt(first)) || masked.codeUnitAt(first) == 0)) {
        first++;
      }
      if (first < index && masked.codeUnitAt(first) != 64 && _crossSelector(masked.substring(first, index))) {
        yield first;
      }
      start = index + 1;
    } else if (unit == 125 || unit == 59) {
      start = index + 1;
    }
  }
}

/// Recognizes exact #chat ... .mes and .mes +/~ .mes selector relationships.
/// Attribute values and functional pseudo-class arguments are deliberately
/// opaque. A comma starts a new selector rather than relating two messages.
bool _crossSelector(String selector) {
  var chat = false;
  var afterChat = false;
  var message = false;
  var afterSibling = false;
  var index = 0;
  while (index < selector.length) {
    final unit = selector.codeUnitAt(index);
    if (unit == 44) {
      chat = false;
      afterChat = false;
      message = false;
      afterSibling = false;
      index++;
      continue;
    }
    if (unit == 91 || unit == 40) {
      final open = unit;
      final close = unit == 91 ? 93 : 41;
      var depth = 1;
      index++;
      while (index < selector.length && depth > 0) {
        if (selector.codeUnitAt(index) == open) {
          depth++;
        }
        if (selector.codeUnitAt(index) == close) {
          depth--;
        }
        index++;
      }
      continue;
    }
    if (_htmlSpace(unit) || unit == 62 || unit == 43 || unit == 126) {
      if (chat) {
        afterChat = true;
      }
      if (message && (unit == 43 || unit == 126)) {
        afterSibling = true;
      }
      index++;
      continue;
    }
    if (unit == 35 || unit == 46) {
      final start = ++index;
      while (index < selector.length && _cssNameUnit(selector.codeUnitAt(index))) {
        index++;
      }
      // Escaped identifiers require a CSS parser. Do not accept a prefix.
      if (index < selector.length && selector.codeUnitAt(index) == 92) {
        chat = false;
        afterChat = false;
        message = false;
        afterSibling = false;
        index++;
        continue;
      }
      final name = selector.substring(start, index);
      if (unit == 35 && name == 'chat') {
        chat = true;
        afterChat = false;
      }
      if (unit == 46 && name == 'mes') {
        if ((chat && afterChat) || (message && afterSibling)) {
          return true;
        }
        message = true;
        afterSibling = false;
      }
      continue;
    }
    index++;
  }
  return false;
}

bool _cssNameUnit(int unit) => _macroNameUnit(unit) || unit >= 128;

const _javascriptTypes = <String>{
  '',
  'module',
  'text/javascript',
  'application/javascript',
  'text/ecmascript',
  'application/ecmascript',
};

const _rawTextNames = <String>{
  'script',
  'style',
  'textarea',
  'title',
  'iframe',
  'xmp',
  'noembed',
  'noframes',
  'plaintext',
};

const _eventAttributes = <String>{
  'onclick',
  'ondblclick',
  'onload',
  'onerror',
  'oninput',
  'onchange',
  'onsubmit',
  'onreset',
  'onfocus',
  'onblur',
  'onkeydown',
  'onkeyup',
  'onkeypress',
  'onmouseover',
  'onmouseout',
  'onmousemove',
  'onmousedown',
  'onmouseup',
  'onpointerdown',
  'onpointerup',
  'oncontextmenu',
  'onanimationstart',
  'onanimationend',
  'ontransitionend',
  'ondragstart',
  'ondrop',
};

// Excludes prompt/macros such as <USER>, <BOT>, <CHAR>, <GROUP> and <START>.
const _htmlNames = <String>{
  'html',
  'head',
  'body',
  'title',
  'meta',
  'link',
  'base',
  'div',
  'span',
  'p',
  'br',
  'hr',
  'a',
  'img',
  'picture',
  'source',
  'video',
  'audio',
  'track',
  'style',
  'script',
  'iframe',
  'object',
  'embed',
  'svg',
  'path',
  'circle',
  'rect',
  'g',
  'canvas',
  'table',
  'thead',
  'tbody',
  'tfoot',
  'tr',
  'td',
  'th',
  'caption',
  'colgroup',
  'col',
  'ul',
  'ol',
  'li',
  'dl',
  'dt',
  'dd',
  'details',
  'summary',
  'form',
  'input',
  'button',
  'select',
  'option',
  'textarea',
  'label',
  'fieldset',
  'legend',
  'output',
  'progress',
  'meter',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'header',
  'footer',
  'main',
  'section',
  'article',
  'aside',
  'nav',
  'address',
  'blockquote',
  'figure',
  'figcaption',
  'pre',
  'code',
  'em',
  'strong',
  'b',
  'i',
  'u',
  's',
  'small',
  'sub',
  'sup',
  'mark',
  'del',
  'ins',
  'abbr',
  'time',
  'kbd',
  'samp',
  'var',
  'ruby',
  'rt',
  'rp',
  'template',
  'noscript',
  'wbr',
  'dialog',
  'xmp',
  'noembed',
  'noframes',
  'plaintext',
};
