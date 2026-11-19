// Captures the actual T4 HTTP serialization after the T8/T9 integration path.
// The HTTP adapter returns a synthetic response and never opens a connection.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty || arguments.length > 2) {
    stderr.writeln('Usage: dart run tool/st_differential/dart_capture.dart <new-output-directory> [fixtures.json]');
    exitCode = 64;
    return;
  }
  final source = arguments.length == 2
      ? File(arguments[1])
      : File.fromUri(Platform.script.resolve('../../test/fixtures/st-differential.json'));
  final decoded = jsonDecode(await source.readAsString());
  if (decoded is! List<Object?> || decoded.isEmpty) throw const FormatException('Expected nonempty fixtures.');
  final fixtures = [for (final value in decoded) _object(value, 'fixture')];
  final seen = <String>{};
  for (final fixture in fixtures) {
    final id = _text(fixture['id'], 'fixture.id');
    if (!RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$').hasMatch(id) || !seen.add(id)) {
      throw FormatException('Invalid or duplicate fixture id: $id');
    }
    final entry = fixture['presetEntry'] ?? 'inline';
    if (entry != 'inline' && entry != 'library') throw FormatException('Unknown presetEntry: $entry');
    if (entry == 'library') {
      _object(fixture['expectedGlobalVariablesAfter'], 'expectedGlobalVariablesAfter');
      for (final key in ['expectedPresetIssues', 'expectedRegexDiagnostics']) {
        if (fixture[key] is! List<Object?>) throw FormatException('$key must be an array.');
      }
    }
  }
  final output = Directory(arguments[0]);
  if (await output.exists()) {
    throw FileSystemException('Use a new output directory; previous captures are retained.', output.path);
  }
  await output.create(recursive: true);
  final report = <Map<String, Object?>>[];
  for (final fixture in fixtures) {
    final id = fixture['id']! as String;
    try {
      final result = await _capture(fixture, Directory('${output.path}/$id'));
      report.add(result);
      stdout.writeln(jsonEncode(result));
    } catch (error) {
      final result = <String, Object?>{'id': id, 'status': 'failed', 'error': error.toString()};
      report.add(result);
      stdout.writeln(jsonEncode(result));
      exitCode = 1;
    }
  }
  final complete = report.every((result) => result['status'] == 'captured');
  final summary = {
    'complete': complete,
    'expectedCount': fixtures.length,
    'captured': report.where((result) => result['status'] == 'captured').length,
    'scope': 'real T4 request.bodyBytes; synthetic HTTP response; estimated prompt tokens',
    'cases': report,
  };
  await _writeExclusive(File('${output.path}/dart-capture-report.json'), utf8.encode('${jsonEncode(summary)}\n'));
  stdout.writeln(jsonEncode({'complete': complete, 'expectedCount': fixtures.length, 'captured': summary['captured']}));
}

Future<Map<String, Object?>> _capture(Map<String, Object?> fixture, Directory output) async {
  final id = fixture['id']! as String;
  final preset = _object(fixture['preset'], 'preset');
  final model = _text(preset['deepseek_model'], 'deepseek_model');
  final captured = <({Uint8List bytes, String method, String url})>[];
  final client = TavernModelClient(
    clientFactory: () => MockClient((request) async {
      captured.add((bytes: Uint8List.fromList(request.bodyBytes), method: request.method, url: request.url.toString()));
      final body = _object(jsonDecode(utf8.decode(request.bodyBytes, allowMalformed: false)), 'wire body');
      if (body['stream'] == false) {
        return http.Response(
          jsonEncode({
            'id': 'dsh-recorder',
            'object': 'chat.completion',
            'model': model,
            'choices': [
              {
                'index': 0,
                'message': {'role': 'assistant', 'content': 'RECORDER_OK'},
                'finish_reason': 'stop',
              },
            ],
            'usage': {'prompt_tokens': 0, 'completion_tokens': 0, 'total_tokens': 0, 'prompt_cache_hit_tokens': 0},
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      final chunk = jsonEncode({
        'id': 'dsh-recorder',
        'model': model,
        'choices': [
          {
            'index': 0,
            'delta': {'content': 'RECORDER_OK'},
            'finish_reason': null,
          },
        ],
      });
      final finished = jsonEncode({
        'id': 'dsh-recorder',
        'model': model,
        'choices': [
          {'index': 0, 'delta': <String, Object?>{}, 'finish_reason': 'stop'},
        ],
        'usage': {'prompt_tokens': 0, 'completion_tokens': 0, 'total_tokens': 0, 'prompt_cache_hit_tokens': 0},
      });
      return http.Response(
        'data: $chunk\n\ndata: $finished\n\ndata: [DONE]\n\n',
        200,
        headers: {'content-type': 'text/event-stream; charset=utf-8'},
      );
    }),
  );
  final directory = await Directory.systemTemp.createTemp('dsh-diff-$id-');
  TavernEngine? engine;
  try {
    final tavern = await TavernEngine.openDirectory(
      directory,
      config: TavernModelConfig(
        apiKey: () async => 'synthetic-fixture',
        baseUrl: 'http://127.0.0.1:19091',
        model: model,
        thinking: preset['show_thoughts'] == true,
      ),
      modelClient: client,
      clock: () => DateTime.utc(2024, 2, 29, 12),
      random: () => 0.25,
    );
    engine = tavern;
    final character = await tavern.importCard(
      Uint8List.fromList(utf8.encode(jsonEncode(fixture['card']))),
      fileName: '$id.json',
    );
    await tavern.setSettings(_object(fixture['settings'], 'settings'));
    Map<String, Object?>? presetImport;
    String? importedPresetId;
    if (fixture['presetEntry'] == 'library') {
      final imported = await tavern.importPreset(jsonEncode(preset), fileName: '$id.json');
      importedPresetId = imported.preset.id;
      final issues = [for (final issue in imported.issues) issue.toJson()];
      final diagnostics = [for (final diagnostic in imported.regexDiagnostics) diagnostic.toJson()];
      if (!_sameJson(issues, fixture['expectedPresetIssues']) ||
          !_sameJson(diagnostics, fixture['expectedRegexDiagnostics'])) {
        throw StateError(
          'Preset import diagnostics differ: issues=${jsonEncode(issues)}, '
          'regexDiagnostics=${jsonEncode(diagnostics)}',
        );
      }
      presetImport = {'id': importedPresetId, 'issues': issues, 'regexDiagnostics': diagnostics};
    } else {
      await tavern.setPreset(ChatPreset(preset));
    }
    await tavern.setGlobalVariables(_object(fixture['globalVariables'], 'globalVariables'));
    final books = fixture['books'];
    if (books is! List<Object?>) throw const FormatException('books must be an array.');
    final bindings = <WorldInfoSource, List<String>>{};
    for (final value in books) {
      final book = _object(value, 'book');
      final bookId = _text(book['id'], 'book.id');
      final source = WorldInfoSource.values.firstWhere((source) => source.name == book['source']);
      await tavern.putLorebook(bookId, _object(book['json'], 'book.json'));
      bindings.putIfAbsent(source, () => []).add(bookId);
    }
    final rows = fixture['messages'];
    if (rows is! List<Object?>) throw const FormatException('messages must be an array.');
    final document = StChatDocument(
      fileName: '$id.jsonl',
      header: _object(fixture['chatHeader'], 'chatHeader'),
      messages: [for (final row in rows) _object(row, 'message')],
    );
    final imported = await tavern.importChats(character.id, [
      TavernChatFile(fileName: document.fileName, bytes: document.encode()),
    ]);
    if (imported.chatIds.length != 1 || imported.notices.isNotEmpty) {
      throw StateError('Fixture import must be one chat without notices: ${imported.notices}');
    }
    final chatId = imported.chatIds.single;
    if (importedPresetId != null) {
      await tavern.bindPreset(chatId, importedPresetId);
      final selection = await tavern.presetSelection(chatId: chatId);
      if (selection.source != PresetSelectionSource.chat || selection.effectivePresetId != importedPresetId) {
        throw StateError('The imported library preset is not the effective chat selection.');
      }
      final importReport = presetImport!;
      importReport['selectionSource'] = selection.source.name;
      importReport['effectivePresetId'] = selection.effectivePresetId;
    }
    for (final binding in bindings.entries) {
      await tavern.bindLorebooks(binding.value, source: binding.key, chatId: chatId);
    }
    // These ST fixtures exercise prompt assembly without tools.
    await tavern.setToolPolicy({
      'roll': {'allow': false},
      'remember': {'allow': false},
    });
    final beforeVariables = tavern.variables(chatId);
    final metadata = _object(_object(fixture['chatHeader'], 'chatHeader')['chat_metadata'], 'chat_metadata');
    final expectedBefore = _object(metadata['variables'] ?? <String, Object?>{}, 'chat_metadata.variables');
    if (!_sameJson(beforeVariables, expectedBefore)) {
      throw StateError(
        'Variables after import differ: actual=${jsonEncode(beforeVariables)}, '
        'expected=${jsonEncode(expectedBefore)}',
      );
    }
    final checkGlobalState = fixture.containsKey('expectedGlobalVariablesAfter');
    final beforeGlobalVariables = checkGlobalState ? tavern.globalVariables : null;
    if (checkGlobalState && !_sameJson(beforeGlobalVariables, fixture['globalVariables'])) {
      throw StateError('Global variables after import differ: actual=${jsonEncode(beforeGlobalVariables)}');
    }
    final type = _text(fixture['generationType'], 'generationType');
    final path = await tavern.path(chatId);
    final events = await switch (type) {
      'normal' => tavern.send(chatId, '').toList(),
      'continue' => tavern.continueReply(chatId, path.last.nodeId).toList(),
      'impersonate' => tavern.impersonate(chatId).toList(),
      'regenerate' => tavern.regenerate(chatId, path.last.nodeId).toList(),
      _ => throw FormatException('Unsupported fixture generationType: $type'),
    };
    final failures = events.whereType<TavernTurnFailed>().toList();
    if (failures.isNotEmpty || events.whereType<TavernTurnDone>().length != 1) {
      throw StateError(
        'Fixture generation did not finish: ${failures.map((event) => '${event.kind.name}:${event.detail}').join(', ')}',
      );
    }
    if (captured.length != 1) throw StateError('Expected one actual HTTP request, saw ${captured.length}.');
    final capture = captured.single;
    if (capture.method != 'POST' || Uri.parse(capture.url).path != '/beta/chat/completions') {
      throw StateError('Unexpected transport endpoint: ${capture.method} ${capture.url}');
    }
    // Keep the actual request available if later state/inspection checks fail.
    // Only a successful capture report can accompany a valid byte comparison.
    await output.create(recursive: true);
    await _writeExclusive(File('${output.path}/001.request.raw.json'), capture.bytes);
    final requestBody = _object(jsonDecode(utf8.decode(capture.bytes, allowMalformed: false)), 'wire body');
    await _writeExclusive(
      File('${output.path}/001.request.json'),
      utf8.encode('${const JsonEncoder.withIndent('  ').convert(requestBody)}\n'),
    );
    if (requestBody.containsKey('tools') || requestBody.containsKey('tool_choice')) {
      throw StateError('The ST prompt-assembly fixtures require tools and tool_choice to be absent.');
    }
    final inspection = await tavern.inspectTurn(chatId);
    if (inspection?.prompt == null) throw StateError('The generated turn has no assembly inspection.');
    final afterVariables = tavern.variables(chatId);
    final expectedAfter = _object(fixture['expectedVariablesAfter'], 'expectedVariablesAfter');
    if (!_sameJson(afterVariables, expectedAfter)) {
      throw StateError(
        'Variables after generation differ: actual=${jsonEncode(afterVariables)}, '
        'expected=${jsonEncode(expectedAfter)}',
      );
    }
    final afterGlobalVariables = checkGlobalState ? tavern.globalVariables : null;
    if (checkGlobalState &&
        !_sameJson(
          afterGlobalVariables,
          _object(fixture['expectedGlobalVariablesAfter'], 'expectedGlobalVariablesAfter'),
        )) {
      throw StateError(
        'Global variables after generation differ: actual=${jsonEncode(afterGlobalVariables)}, '
        'expected=${jsonEncode(fixture['expectedGlobalVariablesAfter'])}',
      );
    }
    await _writeExclusive(
      File('${output.path}/001.inspection.json'),
      utf8.encode('${jsonEncode(inspection!.toJson())}\n'),
    );
    final result = <String, Object?>{
      'id': id,
      'status': 'captured',
      'generationType': type,
      'captures': captured.length,
      'toolsAbsent': true,
      'bytes': capture.bytes.length,
      'variablesBefore': beforeVariables,
      'variablesAfter': afterVariables,
      'variableStateMatches': true,
      'presetImport': ?presetImport,
      if (checkGlobalState) ...{
        'globalVariablesBefore': beforeGlobalVariables,
        'globalVariablesAfter': afterGlobalVariables,
        'globalVariableStateMatches': true,
      },
      'tokenCount': 'estimated',
      'httpResponse': 'synthetic',
    };
    await _writeExclusive(File('${output.path}/001.meta.json'), utf8.encode('${jsonEncode(result)}\n'));
    return result;
  } finally {
    await engine?.close();
    await directory.delete(recursive: true);
  }
}

Future<void> _writeExclusive(File file, List<int> bytes) async {
  await file.create(exclusive: true);
  await file.writeAsBytes(bytes, flush: true);
}

Map<String, Object?> _object(Object? value, String name) {
  if (value is! Map<String, Object?>) throw FormatException('$name must be an object.');
  return value;
}

String _text(Object? value, String name) {
  if (value is! String || value.isEmpty) throw FormatException('$name must be nonempty text.');
  return value;
}

bool _sameJson(Object? first, Object? second) {
  if (first is Map<String, Object?> && second is Map<String, Object?>) {
    return first.length == second.length &&
        first.keys.every((key) => second.containsKey(key) && _sameJson(first[key], second[key]));
  }
  if (first is List<Object?> && second is List<Object?>) {
    return first.length == second.length &&
        Iterable<int>.generate(first.length).every((index) => _sameJson(first[index], second[index]));
  }
  return first == second;
}
