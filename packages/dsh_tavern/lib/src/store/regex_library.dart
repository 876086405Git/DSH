import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../api.dart';
import '../import_report.dart';
import '../io/authoring_text.dart';
import '../io/import_intake.dart';
import '../io/regex_intake.dart';
import '../regex/regex_types.dart';
import '../regex_library.dart';

/// Managed global scripts. Legacy inline settings remain a separate earlier
/// global source; importing here never rewrites those settings implicitly.
final class RegexLibrary {
  RegexLibrary(this.root, this.worker, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;
  final Directory root;
  final RegexExecutor worker;
  final DateTime Function() _clock;
  final _random = Random.secure();
  List<TavernRegexScript> _scripts = const [];
  Future<void> _queue = Future.value();

  /// Synchronous cache notification after the real runtime collection adopts.
  void Function()? committedObserver;
  File get _file => File('${root.path}/regex-library.json');

  Future<void> initialize() async {
    final file = _file;
    final String text;
    try {
      // A failed existence lookup can hide a committed library; read it.
      text = await file.readAsString();
    } on PathNotFoundException catch (error) {
      final code = error.osError?.errorCode;
      if (code != 2 && (!Platform.isWindows || code != 3)) {
        rethrow;
      }
      // A known non-file can also fail to open with a missing-path error.
      if (await FileSystemEntity.type(file.path) != FileSystemEntityType.notFound) {
        rethrow;
      }
      return;
    }
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Unsupported regex library.');
    }
    _scripts = decodeScripts(decoded);
    committedObserver?.call();
  }

  /// Uses the same stored-record parser as initialize and whole-library writes.
  static List<TavernRegexScript> decodeScripts(Map<String, Object?> document) {
    if (document['version'] != 1 || document['scripts'] is! List<Object?>) {
      throw const FormatException('Unsupported regex library.');
    }
    final result = <TavernRegexScript>[];
    final ids = <String>{};
    for (final value in document['scripts']! as List<Object?>) {
      if (value is! Map<String, Object?> ||
          value['id'] is! String ||
          value['raw'] is! Map<String, Object?> ||
          value['sourceText'] is! String ||
          value['importedAt'] is! String ||
          value['diagnostics'] is! List<Object?> ||
          !ids.add(value['id']! as String)) {
        throw const FormatException('Invalid regex library record.');
      }
      result.add(
        TavernRegexScript(
          id: value['id']! as String,
          sourceText: value['sourceText']! as String,
          raw: value['raw']! as Map<String, Object?>,
          importedAt: DateTime.parse(value['importedAt']! as String),
          diagnostics: [
            for (final item in value['diagnostics']! as List<Object?>)
              TavernRegexDiagnostic.fromJson(item! as Map<String, Object?>),
          ],
          importReport: value['importReport'] == null
              ? null
              : TavernImportReport.fromJson(value['importReport']! as Map<String, Object?>),
        ),
      );
    }
    return List.unmodifiable(result);
  }

  List<TavernRegexScript> get scripts => List.unmodifiable(_scripts);
  List<Map<String, Object?>> get executionScripts => [
    for (final script in _scripts) {...script.raw, if (!script.compatible) 'disabled': true},
  ];

  Future<T> _exclusive<T>(Future<T> Function() operation) {
    final result = _queue.then((_) => operation());
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  /// Captures the complete physical library, including fields not represented
  /// by runtime script records. An absent library has an explicit empty base.
  Future<({Map<String, Object?> document, String? rawText, bool present})> readAuthoringSnapshot() =>
      _exclusive(() async {
        final source = await _readAuthoringText();
        if (source == null) {
          return (document: <String, Object?>{'version': 1, 'scripts': <Object?>[]}, rawText: null, present: false);
        }
        final document = jsonDecode(source.text);
        if (document is! Map<String, Object?> || document['version'] != 1 || document['scripts'] is! List<Object?>) {
          throw const FormatException('Unsupported regex library.');
        }
        return (document: document, rawText: source.rawText, present: true);
      });

  /// Preview seal compares the original text without parsing a changed file
  /// or updating the runtime collection.
  Future<bool> recheckAuthoringSnapshot({required bool present, required String? rawText}) => _exclusive(() async {
    final source = await _readAuthoringText();
    return present == (source != null) && rawText == source?.rawText;
  });

  Future<({String text, String rawText})?> _readAuthoringText() async {
    try {
      return await readAuthoringText(_file);
    } on PathNotFoundException catch (error) {
      final code = error.osError?.errorCode;
      if (code != 2 && (!Platform.isWindows || code != 3)) {
        rethrow;
      }
      if (await FileSystemEntity.type(_file.path) != FileSystemEntityType.notFound) {
        rethrow;
      }
      return null;
    }
  }

  Future<TavernRegexImportResult> importScripts(String text) async {
    final Object? value;
    try {
      value = jsonDecode(text.startsWith('\uFEFF') ? text.substring(1) : text);
    } on FormatException {
      throw const TavernImportError('正则文件不是有效JSON。');
    }
    final values = value is List<Object?> ? value : <Object?>[value];
    if (values.any((value) => value is! Map<String, Object?>)) {
      throw const TavernImportError('正则文件须为单个对象或对象数组。');
    }
    final prepared = <({Map<String, Object?> raw, TavernRegexDiagnostic diagnostic, String path})>[];
    for (var index = 0; index < values.length; index++) {
      final raw = values[index]! as Map<String, Object?>;
      final path = value is List<Object?> ? '\$[$index]' : r'$';
      final diagnostic = await inspectRegexScript(raw, worker, path: path);
      prepared.add((raw: raw, diagnostic: diagnostic, path: path));
    }
    return _exclusive(() async {
      final ids = _scripts.map((value) => value.id).toSet();
      final records = <TavernRegexScript>[];
      for (final value in prepared) {
        final at = _clock().toUtc();
        final report = assessImport(
          kind: TavernImportKind.regex,
          document: value.raw,
          path: value.path,
          regexDiagnostics: [value.diagnostic],
          checkedAt: at,
        );
        records.add(
          TavernRegexScript(
            id: _newId(ids),
            raw: value.raw,
            sourceText: text,
            importedAt: at,
            diagnostics: [value.diagnostic],
            importReport: report,
          ),
        );
      }
      if (records.isNotEmpty) await _save([..._scripts, ...records]);
      return TavernRegexImportResult(records);
    });
  }

  /// Replaces one physical library. A null result means its exact before-image
  /// changed. The caller owns the detached input and maps that conflict.
  Future<({Map<String, Object?> document, String rawText, List<TavernRegexScript> scripts})?> replaceScripts(
    List<({String? engineId, Map<String, Object?> raw})> items, {
    required bool expectedPresent,
    required String? expectedRawText,
    void Function()? check,
    void Function(({Map<String, Object?> document, String rawText, List<TavernRegexScript> scripts}))? onCommitted,
  }) => _exclusive(() async {
    check?.call();
    final source = await _readAuthoringText();
    check?.call();
    bool matches(({String text, String rawText})? value) =>
        expectedPresent == (value != null) && expectedRawText == value?.rawText;
    if (!matches(source)) {
      return null;
    }
    final document = source == null ? <String, Object?>{'version': 1, 'scripts': <Object?>[]} : jsonDecode(source.text);
    if (document is! Map<String, Object?>) {
      throw const FormatException('Unsupported regex library.');
    }
    final originals = decodeScripts(document);
    final byId = {for (final value in originals) value.id: value};
    final rawById = {
      for (final value in document['scripts']! as List<Object?>)
        (value! as Map<String, Object?>)['id']! as String: value,
    };
    final used = <String>{};
    for (final item in items) {
      final id = item.engineId;
      if (id != null && (!byId.containsKey(id) || !used.add(id))) {
        throw ArgumentError.value(id, 'engineId', 'The library identity is absent or repeated.');
      }
    }
    final reserved = byId.keys.toSet();
    final records = <Map<String, Object?>>[];
    for (final (index, item) in items.indexed) {
      check?.call();
      final id = item.engineId ?? _newId(reserved);
      final original = byId[id];
      final row = original == null
          ? <String, Object?>{
              'id': id,
              'sourceText': jsonEncode(item.raw),
              'importedAt': _clock().toUtc().toIso8601String(),
            }
          : Map<String, Object?>.from(rawById[id]! as Map<String, Object?>);
      row['raw'] = item.raw;
      if (original == null || !_sameRaw(original.raw, item.raw)) {
        final path = '\$.scripts[$index].raw';
        final diagnostic = await inspectRegexScript(item.raw, worker, path: path);
        check?.call();
        final report = assessImport(
          kind: TavernImportKind.regex,
          document: item.raw,
          path: path,
          regexDiagnostics: [diagnostic],
          checkedAt: _clock().toUtc(),
        );
        row['diagnostics'] = [diagnostic.toJson()];
        row['importReport'] = report.toJson();
      }
      records.add(row);
    }
    final next = Map<String, Object?>.from(document)..['scripts'] = records;
    final prepared = decodeScripts(next);
    Future<bool> current() async => matches(await _readAuthoringText());
    if (!await current()) {
      return null;
    }
    check?.call();
    ({Map<String, Object?> document, String rawText, List<TavernRegexScript> scripts})? adopted;
    final saved = await _save(
      prepared,
      document: next,
      current: current,
      check: check,
      onCommitted: (text) {
        adopted = (document: next, rawText: text, scripts: prepared);
        onCommitted?.call(adopted!);
      },
    );
    return saved ? adopted : null;
  });

  static bool _sameRaw(Object? left, Object? right) {
    if (left is Map<String, Object?> && right is Map<String, Object?>) {
      return left.length == right.length &&
          left.entries.every((entry) => right.containsKey(entry.key) && _sameRaw(entry.value, right[entry.key]));
    }
    if (left is List<Object?> && right is List<Object?>) {
      return left.length == right.length && left.indexed.every((entry) => _sameRaw(entry.$2, right[entry.$1]));
    }
    return left == right;
  }

  Future<TavernRegexScript> updateScript(String id, Map<String, Object?> patch) {
    final captured = jsonDecode(jsonEncode(patch)) as Map<String, Object?>;
    return _exclusive(() async {
      final original = _require(id);
      final raw = _merge(original.raw, captured);
      final diagnostic = await inspectRegexScript(raw, worker);
      final report = assessImport(
        kind: TavernImportKind.regex,
        document: raw,
        regexDiagnostics: [diagnostic],
        checkedAt: _clock().toUtc(),
      );
      final updated = TavernRegexScript(
        id: original.id,
        sourceText: original.sourceText,
        raw: raw,
        importedAt: original.importedAt,
        diagnostics: [diagnostic],
        importReport: report,
      );
      await _save([for (final script in _scripts) script.id == id ? updated : script]);
      return updated;
    });
  }

  Future<TavernRegexScript> setEnabled(String id, bool enabled) => _exclusive(() async {
    final original = _require(id);
    final updated = TavernRegexScript(
      id: id,
      sourceText: original.sourceText,
      raw: {...original.raw, 'disabled': !enabled},
      importedAt: original.importedAt,
      diagnostics: original.diagnostics,
      importReport: original.importReport,
    );
    await _save([for (final script in _scripts) script.id == id ? updated : script]);
    return updated;
  });

  Future<void> delete(String id) => _exclusive(() async {
    if (!_scripts.any((script) => script.id == id)) return;
    await _save([
      for (final script in _scripts)
        if (script.id != id) script,
    ]);
  });

  Future<TavernImportReport?> readImportReport(String id) => _exclusive(() async {
    final matches = _scripts.where((value) => value.id == id);
    if (matches.isEmpty) return null;
    final record = matches.single;
    final report = record.importReport;
    if (report == null) return null;
    if (report.kind != TavernImportKind.regex) throw const FormatException('Invalid regex import report.');
    return report.withStale(report.fingerprint != importFingerprint(TavernImportKind.regex, record.raw));
  });

  Future<TavernImportReport> recheckImport(String id) => _exclusive(() async {
    final record = _require(id);
    final diagnostic = await inspectRegexScript(record.raw, worker);
    final report = assessImport(
      kind: TavernImportKind.regex,
      document: record.raw,
      regexDiagnostics: [diagnostic],
      checkedAt: _clock().toUtc(),
    );
    final updated = TavernRegexScript(
      id: id,
      sourceText: record.sourceText,
      raw: record.raw,
      importedAt: record.importedAt,
      diagnostics: [diagnostic],
      importReport: report,
    );
    await _save([for (final script in _scripts) script.id == id ? updated : script]);
    return report;
  });

  String exportScripts({String? id}) =>
      jsonEncode(id == null ? [for (final script in _scripts) script.raw] : _require(id).raw);

  TavernRegexScript _require(String id) =>
      _scripts.firstWhere((script) => script.id == id, orElse: () => throw const TavernImportError('正则不存在。'));

  String _newId(Set<String> reserved) {
    String id;
    do {
      id = List.generate(16, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    } while (!reserved.add(id));
    return id;
  }

  Map<String, Object?> _merge(Map<String, Object?> original, Map<String, Object?> patch) {
    final result = Map<String, Object?>.from(original);
    for (final entry in patch.entries) {
      final previous = result[entry.key];
      final replacement = entry.value;
      result[entry.key] = previous is Map<String, Object?> && replacement is Map<String, Object?>
          ? _merge(previous, replacement)
          : replacement;
    }
    return result;
  }

  Future<bool> _save(
    List<TavernRegexScript> scripts, {
    Map<String, Object?>? document,
    Future<bool> Function()? current,
    void Function()? check,
    void Function(String text)? onCommitted,
  }) async {
    final temporary = File('${_file.path}.writing');
    final text = jsonEncode(
      document ??
          {
            'version': 1,
            'scripts': [
              for (final script in scripts)
                {
                  'id': script.id,
                  'raw': script.raw,
                  'sourceText': script.sourceText,
                  'importedAt': script.importedAt.toIso8601String(),
                  'diagnostics': [for (final issue in script.diagnostics) issue.toJson()],
                  if (script.importReport != null) 'importReport': script.importReport!.toJson(),
                },
            ],
          },
    );
    try {
      await root.create(recursive: true);
      await temporary.writeAsString(text, flush: true);
      if (current != null && !await current()) {
        return false;
      }
      check?.call();
      await temporary.rename(_file.path);
      _scripts = List.unmodifiable(scripts);
      onCommitted?.call(text);
      committedObserver?.call();
      return true;
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }
}
