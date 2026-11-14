// Native initialization profile derived from MagVarUpdate:
// src/function/initvar/variable_init.ts and util/common.ts.
// Commit d03b7dc8a6ebf9bd611c7e2dc91f3b35462deebc.
// Copyright (c) 2025 MagicalAstrogy & StageDog. MIT; see THIRD_PARTY_NOTICES.md.

part of 'mvu.dart';

/// Initializes an owned candidate from books already captured by the caller.
///
/// A non-null [greeting] means the caller has identified the first initialization
/// of an actual greeting page. Later default refreshes pass null. This function
/// neither decides whether MVU is enabled nor selects or writes a physical page.
Future<MvuResult> initializeMvu(
  MvuJson previous,
  List<MvuBook> books, {
  String? greeting,
  int swipeId = 0,
  MvuExpand? expand,
  MvuPhaseHook? onPhase,
}) async {
  var data = _mvuJson(previous)! as MvuJson;
  final issues = <MvuIssue>[];
  final capturedBooks = <MvuBook>[
    for (final book in books) MvuBook(name: book.name, entries: List<MvuInitEntry>.of(book.entries)),
  ];
  final markers = _mvuInitializationMarkers(data, issues);
  final defaults = <String, Object?>{};
  final seen = <String>{};
  for (final book in capturedBooks) {
    if (!seen.add(book.name) || (markers?.containsKey(book.name) ?? false)) {
      continue;
    }
    var succeeded = true;
    for (var index = 0; index < book.entries.length; index++) {
      final entry = book.entries[index];
      if (!entry.comment.toLowerCase().contains('[initvar]')) {
        continue;
      }
      final source = 'book[${_mvuJsonText(book.name)}].entries[${_mvuJsonText(entry.id ?? index)}]';
      var text = _mvuStripInitWrapper(entry.content);
      if (expand != null) {
        text = await expand(text);
      }
      try {
        final value = _mvuInitObject(text);
        _mvuMerge(defaults, value, replaceArrays: true);
      } on FormatException catch (error) {
        succeeded = false;
        issues.add(MvuIssue('invalid_initvar', error.message, source: source));
      }
    }
    if (succeeded && markers != null) {
      markers[book.name] = <Object?>[];
    }
  }
  if (!data.containsKey('stat_data')) {
    data['stat_data'] = defaults;
  } else {
    final current = data['stat_data'];
    if (current is MvuJson) {
      data['stat_data'] = _mvuMerge(defaults, current, replaceArrays: true);
    }
  }
  if (greeting != null) {
    final override = <String, Object?>{};
    var hasOverride = false;
    for (final match in RegExp(r'<initvar>([\s\S]*?)</initvar>', caseSensitive: false).allMatches(greeting)) {
      var text = _mvuStripInitWrapper(match.group(1)!);
      if (expand != null) {
        text = await expand(text);
      }
      try {
        final value = _mvuInitObject(text);
        _mvuMerge(override, value, replaceArrays: true);
        hasOverride = true;
      } on FormatException catch (error) {
        issues.add(MvuIssue('invalid_initvar', error.message, source: 'greeting', offset: match.start));
      }
    }
    if (hasOverride) {
      data['stat_data'] = override;
    }
  }
  _mvuReconcileSchema(data);
  _mvuCleanMetadata(data['stat_data']);
  data.putIfAbsent('display_data', () => <String, Object?>{});
  data.putIfAbsent('delta_data', () => <String, Object?>{});

  if (onPhase != null) {
    final phase = MvuPhase(kind: MvuPhaseKind.initialized, data: data, swipeId: swipeId);
    await onPhase(phase);
    data = _mvuJson(phase.data)! as MvuJson;
  }
  if (greeting != null) {
    final updated = await updateMvu(greeting, data, blocksOnly: true, expand: expand, onPhase: onPhase);
    issues.addAll(updated.issues);
    data = updated.data;
  }
  return MvuResult(data, List<MvuIssue>.unmodifiable(issues));
}

MvuJson? _mvuInitializationMarkers(MvuJson data, List<MvuIssue> issues) {
  if (!data.containsKey('initialized_lorebooks')) {
    final markers = <String, Object?>{};
    data['initialized_lorebooks'] = markers;
    return markers;
  }
  final previous = data['initialized_lorebooks'];
  if (previous is MvuJson) {
    return previous;
  }
  if (previous is List<Object?> && previous.every((value) => value is String)) {
    final markers = <String, Object?>{for (final name in previous.cast<String>()) name: <Object?>[]};
    data['initialized_lorebooks'] = markers;
    return markers;
  }
  issues.add(
    const MvuIssue(
      'invalid_initialized_lorebooks',
      'The initialized book carrier must be an object or a legacy string list.',
      source: 'initialized_lorebooks',
    ),
  );
  return null;
}

MvuJson _mvuInitObject(String source) {
  if (trimJsWhitespace(source).isEmpty) {
    return <String, Object?>{};
  }
  final value = _mvuParseDocument(source);
  if (value is! MvuJson) {
    throw const FormatException('An initvar declaration must be a JSON object.');
  }
  return value;
}

String _mvuStripInitWrapper(String source) {
  var text = source.trim();
  final xml = RegExp(r'^<initvar>([\s\S]*?)</initvar>$', caseSensitive: false).firstMatch(text);
  if (xml != null) {
    text = xml.group(1)!.trim();
  }
  final fence = RegExp(r'^```[^\r\n]*(?:\r\n|\r|\n)([\s\S]*?)(?:\r\n|\r|\n)[ \t]*```$').firstMatch(text);
  return fence == null ? text : fence.group(1)!;
}
