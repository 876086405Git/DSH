import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

void main() {
  test('single and array regex imports preserve source unknown fields duplicate ids and order', () async {
    final h = await _open();
    final one = _rule(
      'A',
      'B',
      extra: {
        'id': 'same',
        'foreign': {
          'keep': [false, null, '猫'],
        },
      },
    );
    final text = '\uFEFF${jsonEncode(one)}\r\n';
    final a = (await h.engine.importRegexScripts(text)).scripts.single;
    final b = (await h.engine.importRegexScripts(jsonEncode([one, _rule('B', 'C')]))).scripts;
    expect(a.id, isNot(b.first.id));
    expect(a.raw, one);
    expect(a.sourceText, text);
    (a.raw['foreign']! as Map<String, Object?>)['keep'] = 'caller';
    expect(jsonDecode(await h.engine.exportRegex(regexId: a.id)), one);
    expect(jsonDecode(await h.engine.exportRegex()), [one, one, _rule('B', 'C')]);
    await h.reopen();
    final restored = await h.engine.listRegexScripts();
    expect(restored.map((script) => script.id), [a.id, ...b.map((script) => script.id)]);
    expect(restored.first.sourceText, text);
    expect(restored.first.diagnostics.single.status, TavernRegexCompatibility.compatible);
  });

  test('malformed regex batches create no partial collection', () async {
    final h = await _open();
    for (final value in [
      '{',
      'null',
      jsonEncode([_rule('A', 'B'), 3]),
    ]) {
      await expectLater(h.engine.importRegexScripts(value), throwsA(isA<TavernImportError>()));
    }
    expect(await h.engine.listRegexScripts(), isEmpty);
  });

  test('regex toggle and delete persist without rewriting original source', () async {
    final h = await _open();
    final text = jsonEncode(
      _rule(
        'A',
        'B',
        extra: {
          'opaque': ['saved'],
        },
      ),
    );
    final imported = (await h.engine.importRegexScripts(text)).scripts.single;
    final disabled = await h.engine.setRegexEnabled(imported.id, false);
    expect(disabled.enabled, isFalse);
    expect(disabled.sourceText, text);
    expect(disabled.raw['opaque'], ['saved']);
    await h.reopen();
    expect((await h.engine.listRegexScripts()).single.enabled, isFalse);
    await h.engine.setRegexEnabled(imported.id, true);
    await h.engine.deleteRegex(imported.id);
    await h.engine.deleteRegex(imported.id);
    await h.reopen();
    expect(await h.engine.listRegexScripts(), isEmpty);
    await expectLater(h.engine.exportRegex(regexId: imported.id), throwsA(isA<TavernImportError>()));
  });

  test('failed regex file publication leaves committed memory and disk unchanged', () async {
    final h = await _open();
    final original = (await h.engine.importRegexScripts(jsonEncode(_rule('A', 'B')))).scripts.single;
    final before = await File('${h.directory.path}/regex-library.json').readAsString();
    final obstruction = Directory('${h.directory.path}/regex-library.json.writing');
    await obstruction.create();
    await expectLater(h.engine.setRegexEnabled(original.id, false), throwsA(isA<FileSystemException>()));
    expect((await h.engine.listRegexScripts()).single.enabled, isTrue);
    expect(await File('${h.directory.path}/regex-library.json').readAsString(), before);
    await obstruction.delete();
    await h.engine.setRegexEnabled(original.id, false);
    await h.reopen();
    expect((await h.engine.listRegexScripts()).single.enabled, isFalse);
  });

  test('import checks actual lookbehind named groups and incompatible patterns', () async {
    final h = await _open();
    final result = await h.engine.importRegexScripts(
      jsonEncode([_rule('(?<=猫)咪', 'X'), _rule('(?<cat>猫)', r'$<cat>'), _rule('[', 'broken')]),
    );
    expect(result.diagnostics.map((issue) => issue.status), [
      TavernRegexCompatibility.compatible,
      TavernRegexCompatibility.compatible,
      TavernRegexCompatibility.incompatible,
    ]);
    expect(result.scripts.last.raw['disabled'], isFalse);
    expect(result.scripts.last.compatible, isFalse);
    await h.engine.setRegexEnabled(result.scripts.last.id, true);
    final chat = await h.chat();
    expect((await h.engine.displayText(chat, text: '猫咪')).text, '猫X');
    expect((await h.engine.send(chat, 'Q').toList()).whereType<TavernTurnDone>(), hasLength(1));
  });

  test('global source order is legacy collection preset then card', () async {
    final h = await _open();
    await h.engine.setSettings({
      'globalRegexScripts': [_rule('A', 'B')],
    });
    await h.engine.importRegexScripts(jsonEncode(_rule('B', 'C')));
    final preset = await h.engine.importPreset(
      jsonEncode({
        'extensions': {
          'regex_scripts': [_rule('C', 'D')],
        },
      }),
    );
    await h.engine.setDefaultPreset(preset.preset.id);
    final card = await h.card({
      'extensions': {
        'regex_scripts': [_rule('D', 'E')],
      },
    });
    final chat = await h.engine.createChat(card.id);
    expect((await h.engine.displayText(chat, text: 'A')).text, 'E');
    expect((await h.engine.path(chat)).single.text, 'A');
  });

  test('managed snapshots cannot be overridden or duplicated by read and set', () async {
    final h = await _open();
    await h.engine.importRegexScripts(jsonEncode(_rule('A', 'AA')));
    final chat = await h.chat();
    final read = await h.engine.readSettings();
    await h.engine.setSettings(read);
    await h.engine.setSettings({
      'managedRegexScripts': [_rule('A', 'CORRUPT')],
    }, chatId: chat);
    expect((await h.engine.displayText(chat, text: 'A')).text, 'AA');
    final effective = await h.engine.readSettings(chatId: chat);
    expect((effective['managedRegexScripts']! as List<Object?>).length, 1);
    await h.reopen();
    expect((await h.engine.displayText(chat, text: 'A')).text, 'AA');
  });

  test('each display starts from raw text and never writes its result or inspection', () async {
    final h = await _open();
    await h.engine.importRegexScripts(jsonEncode(_rule('A', 'AA')));
    final chat = await h.chat();
    await h.engine.send(chat, 'Q').drain<void>();
    final node = (await h.engine.path(chat)).last;
    final inspection = jsonEncode((await h.engine.inspectTurn(chat))!.toJson());
    final exportedMessages = utf8.decode((await h.engine.exportChat(chat)).single.bytes).split('\n').skip(1).join('\n');
    expect((await h.engine.displayText(chat, nodeId: node.nodeId)).text, 'AA');
    expect((await h.engine.displayText(chat, text: node.text)).text, 'AA');
    expect((await h.engine.path(chat)).last.text, 'A');
    expect(jsonEncode((await h.engine.inspectTurn(chat))!.toJson()), inspection);
    expect(
      utf8.decode((await h.engine.exportChat(chat)).single.bytes).split('\n').skip(1).join('\n'),
      exportedMessages,
    );
  });

  test('display macro effects and random choices stay in an independent context', () async {
    final h = await _open();
    final chat = await h.chat();
    await h.engine.setGlobalVariables({'kept': 'global'});
    await h.engine.importRegexScripts(
      jsonEncode(_rule('A', '{{setvar::display::local}}{{setglobalvar::display::global}}{{random::one::two}}')),
    );
    final vars = h.engine.variables(chat);
    final global = h.engine.globalVariables;
    final settings = await File('${h.directory.path}/settings.json').readAsString();
    final randomCalls = h.randomCalls;
    final first = await h.engine.displayText(chat, text: 'A');
    final second = await h.engine.displayText(chat, text: 'A');
    expect(first.text, anyOf('one', 'two'));
    expect(second.text, first.text);
    expect(h.randomCalls, randomCalls);
    expect(h.engine.variables(chat), vars);
    expect(h.engine.globalVariables, global);
    expect(await File('${h.directory.path}/settings.json').readAsString(), settings);
  });

  test('stored depth and explicit placement control display eligibility', () async {
    final h = await _open();
    await h.engine.importRegexScripts(jsonEncode(_rule('A', 'DEPTH', extra: {'minDepth': 2, 'maxDepth': 2})));
    final chat = await h.chat();
    await h.engine.send(chat, 'Q').drain<void>();
    final path = await h.engine.path(chat);
    expect((await h.engine.displayText(chat, nodeId: path.first.nodeId)).text, 'DEPTH');
    expect((await h.engine.displayText(chat, nodeId: path.last.nodeId)).text, 'A');
    expect((await h.engine.displayText(chat, text: 'A', depth: 2)).text, 'DEPTH');
    expect((await h.engine.displayText(chat, text: 'A', depth: 2, role: TavernRole.user)).text, 'A');
  });

  test('public display honors a based minDepth beyond signed int range', () async {
    final h = await _open();
    final raw = _rule('A', 'B', extra: {'minDepth': '0x8000000000000000'});
    final source = jsonEncode(raw);
    final imported = await h.engine.importRegexScripts(source);
    expect(imported.scripts, hasLength(1));
    final script = imported.scripts.single;
    expect(script.enabled, isTrue);
    expect(script.compatible, isTrue);
    expect(script.raw, raw);
    expect(script.sourceText, source);
    expect(jsonDecode(await h.engine.exportRegex(regexId: script.id)), raw);

    final chat = await h.chat();
    final path = await h.engine.path(chat);
    expect(path, hasLength(1));
    expect(path.single.text, 'A');
    final withoutDepth = await h.engine.displayText(chat, text: 'A');
    expect(withoutDepth.text, 'B');
    expect(withoutDepth.warnings, isEmpty);
    expect(withoutDepth.superseded, isFalse);
    expect(withoutDepth.replacements, 1);

    final withDepth = await h.engine.displayText(chat, text: 'A', depth: 0);
    expect(withDepth.warnings, isEmpty);
    expect(withDepth.superseded, isFalse);
    expect((await h.engine.path(chat)).map((message) => message.text), ['A']);
    final retained = await h.engine.listRegexScripts();
    expect(retained, hasLength(1));
    expect(retained.single.raw, raw);
    expect(retained.single.sourceText, source);
    expect(h.model.bodies, isEmpty);
    print('T12 based-depth READY: imported rule active without depth; no warning; stored A and raw source intact');

    // Fixed ST coerces this unsigned hex string to positive 2^63, so 0 is below it.
    // The old explicit-radix int parser instead returns null, producing NaN and B.
    expect(withDepth.text, 'A');
    expect(withDepth.replacements, 0);
    expect(jsonDecode(await h.engine.exportRegex(regexId: script.id)), raw);
    expect((await h.engine.path(chat)).map((message) => message.text), ['A']);
    expect(h.model.bodies, isEmpty);
  });

  test('reasoning and body display are independent and leave stored fields intact', () async {
    final h = await _open();
    h.engine.configure(
      TavernModelConfig(apiKey: () async => 'fixture', baseUrl: 'https://configured.invalid', thinking: true),
    );
    h.model.reasoning = 'A';
    await h.engine.importRegexScripts(
      jsonEncode([
        _rule('A', 'BODY'),
        _rule(
          'A',
          'THINK',
          extra: {
            'placement': [6],
          },
        ),
      ]),
    );
    final chat = await h.chat();
    await h.engine.send(chat, 'Q').drain<void>();
    final node = (await h.engine.path(chat)).last;
    expect((await h.engine.displayText(chat, nodeId: node.nodeId)).text, 'BODY');
    expect((await h.engine.displayText(chat, nodeId: node.nodeId, reasoning: true)).text, 'THINK');
    final stored = (await h.engine.path(chat)).last;
    expect(stored.text, 'A');
    expect(stored.reasoning, 'A');
  });

  test('latest raw call supersedes active and pending versions and completes each caller', () async {
    final h = await _open();
    await h.engine.importRegexScripts(jsonEncode(_rule('A', 'B')));
    final chat = await h.chat();
    final a = h.engine.displayText(chat, text: 'A1');
    final b = h.engine.displayText(chat, text: 'A2');
    final c = h.engine.displayText(chat, text: 'A3');
    final results = await Future.wait([a, b, c]);
    expect(results.map((result) => result.superseded), [true, true, false]);
    expect(results.last.text, 'B3');
  });

  test('stored node raw channel and reasoning channel do not supersede each other', () async {
    final h = await _open();
    await h.engine.importRegexScripts(
      jsonEncode(
        _rule(
          'A',
          'B',
          extra: {
            'placement': [2, 6],
          },
        ),
      ),
    );
    final chat = await h.chat();
    final node = (await h.engine.path(chat)).single;
    final results = await Future.wait([
      h.engine.displayText(chat, nodeId: node.nodeId),
      h.engine.displayText(chat, text: 'A'),
      h.engine.displayText(chat, text: 'A', reasoning: true),
    ]);
    expect(results.map((result) => result.superseded), [false, false, false]);
    expect(results.map((result) => result.text), ['B', 'B', 'B']);
  });

  test('close completes all display callers and rejects later admission', () async {
    final h = await _open();
    await h.engine.importRegexScripts(jsonEncode(_rule('A', 'B')));
    final chat = await h.chat();
    final a = h.engine.displayText(chat, text: 'A1');
    final b = h.engine.displayText(chat, text: 'A2');
    await h.engine.close();
    final results = await Future.wait([a, b]);
    expect(results.every((result) => result.superseded), isTrue);
    expect(() => h.engine.displayText(chat, text: 'A'), throwsStateError);
  });

  test('invalid display targets and depths fail without changing the chat', () async {
    final h = await _open();
    final chat = await h.chat();
    await expectLater(h.engine.displayText(chat), throwsArgumentError);
    await expectLater(h.engine.displayText(chat, text: 'A', depth: double.nan), throwsArgumentError);
    await expectLater(h.engine.displayText(chat, text: 'A', depth: -1), throwsArgumentError);
    await expectLater(h.engine.displayText(chat, nodeId: 'missing'), throwsStateError);
    expect((await h.engine.path(chat)).single.text, 'A');
  });

  test('card import checks scripts and embedded keyword headers without running macros', () async {
    final h = await _open();
    await h.engine.setGlobalVariables({'kept': 1});
    final bad = _rule('[', 'bad');
    final dynamicRule = _rule('{{setglobalvar::imported::bad}}[', 'dynamic', extra: {'substituteRegex': 1});
    final card = await h.card({
      'extensions': {
        'regex_scripts': [bad, dynamicRule],
        'opaque': {'keep': 1},
      },
      'character_book': {
        'entries': [
          {
            'id': 7,
            'keys': ['[', '{{setglobalvar::imported::bad}}['],
            'use_regex': true,
            'content': '@@additional_keys [\nbody',
            'extensions': {},
          },
        ],
      },
    });
    expect(h.engine.globalVariables, {'kept': 1});
    expect(card.regexDiagnostics.where((issue) => issue.status == TavernRegexCompatibility.incompatible), hasLength(3));
    expect(card.regexDiagnostics.where((issue) => issue.status == TavernRegexCompatibility.deferred), hasLength(2));
    final header = card.regexDiagnostics.singleWhere((issue) => issue.decorator == 'additional_keys');
    expect(header.path, r'$.data.character_book.entries[0].content');
    expect(header.line, 1);
    expect(header.keyIndex, 0);
    final fields = (await h.engine.characterFields(card.id))!;
    expect((fields['extensions']! as Map<String, Object?>)['regex_scripts'], [bad, dynamicRule]);
  });

  test('preset import exposes regex compatibility without touching source or macros', () async {
    final h = await _open();
    await h.engine.setGlobalVariables({'kept': 1});
    final raw = {
      'extensions': {
        'regex_scripts': [
          _rule('[', 'bad'),
          _rule('{{setglobalvar::imported::bad}}[', 'dynamic', extra: {'substituteRegex': 2}),
        ],
      },
      'foreign': [null, false],
    };
    final source = jsonEncode(raw);
    final result = await h.engine.importPreset(source);
    expect(result.regexDiagnostics.map((issue) => issue.status), [
      TavernRegexCompatibility.incompatible,
      TavernRegexCompatibility.deferred,
    ]);
    expect(result.preset.sourceText, source);
    expect(result.preset.raw, raw);
    expect(h.engine.globalVariables, {'kept': 1});
  });

  test('preset regex fixtures switch one chat A on A prompt-off B A without writing transformed text', () async {
    final fixtures =
        (jsonDecode(await File('test/fixtures/st-native-preset-regex.json').readAsString()) as List<Object?>)
            .cast<Map<String, Object?>>();
    expect(fixtures.map((fixture) => fixture['id']), ['rx-a', 'rx-b']);
    final fixtureA = fixtures[0];
    final fixtureB = fixtures[1];
    final rawA = fixtureA['preset']! as Map<String, Object?>;
    final rawB = fixtureB['preset']! as Map<String, Object?>;
    const anchor = 'DSHRXANCHOR | DSHRXPRAW | RECORDER_OK';
    const input = 'Please continue.';
    final h = await _open();
    h.model.responseText = 'RECORDER_OK';
    await h.engine.setSettings(fixtureA['settings']! as Map<String, Object?>);
    await h.engine.setGlobalVariables(fixtureA['globalVariables']! as Map<String, Object?>);
    await h.engine.setToolPolicy({
      'roll': {'allow': false},
      'remember': {'allow': false},
    });
    final character = await h.engine.importCard(Uint8List.fromList(utf8.encode(jsonEncode(fixtureA['card']))));
    final document = StChatDocument(
      fileName: 'preset-regex.jsonl',
      header: fixtureA['chatHeader']! as Map<String, Object?>,
      messages: (fixtureA['messages']! as List<Object?>).cast<Map<String, Object?>>(),
    );
    final importedChat = await h.engine.importChats(character.id, [
      TavernChatFile(fileName: document.fileName, bytes: document.encode()),
    ]);
    final chat = importedChat.chatIds.single;
    final anchorNodeId = (await h.engine.path(chat)).single.nodeId;

    Future<void> expectStored(int stage, {String? lastNodeId}) async {
      final path = await h.engine.path(chat);
      expect(path.map((message) => (message.role, message.text)), [
        (TavernRole.character, anchor),
        for (var index = 0; index < stage; index++) ...[
          (TavernRole.user, input),
          (TavernRole.character, 'RECORDER_OK'),
        ],
      ], reason: 'complete stored path after stage $stage');
      expect(path.first.nodeId, anchorNodeId);
      if (lastNodeId != null) expect(path.last.nodeId, lastNodeId);
      // exportChat returns the current path first and also preserves other imported paths/branches.
      final exported = (await h.engine.exportChat(chat)).first;
      final rows = StChatDocument.decode(exported.fileName, exported.bytes).messages;
      expect(rows.map((row) => (row['is_user'], row['is_system'] ?? false, row['mes'])), [
        (false, false, anchor),
        for (var index = 0; index < stage; index++) ...[(true, false, input), (false, false, 'RECORDER_OK')],
      ], reason: 'complete exported message sequence after stage $stage');
    }

    await expectStored(0);
    final a = await h.engine.importPreset(jsonEncode(rawA), fileName: 'DSHRXPRESETA.json');
    final b = await h.engine.importPreset(jsonEncode(rawB), fileName: 'DSHRXPRESETB.json');
    expect(a.issues, isEmpty);
    expect(b.issues, isEmpty);
    expect(a.preset.raw, rawA);
    expect(b.preset.raw, rawB);
    expect(a.regexDiagnostics.map((diagnostic) => diagnostic.toJson()), [
      {
        'path': r'$.extensions.regex_scripts[0].findRegex',
        'status': 'compatible',
        'code': 'compiled',
        'message': '已按本来源的解析规则试编译。',
        'identifier': '10000000-0000-4000-8000-000000000001',
      },
      {
        'path': r'$.extensions.regex_scripts[1].findRegex',
        'status': 'compatible',
        'code': 'compiled',
        'message': '已按本来源的解析规则试编译。',
        'identifier': '10000000-0000-4000-8000-000000000002',
      },
    ]);
    expect(b.regexDiagnostics, isEmpty);

    Future<void> expectSelection(String presetId) async {
      final selection = await h.engine.presetSelection(chatId: chat);
      expect(selection.source, PresetSelectionSource.chat);
      expect(selection.boundPresetId, presetId);
      expect(selection.effectivePresetId, presetId);
      expect(selection.missingPresetIds, isEmpty);
    }

    Future<void> setPromptDisabled(bool disabled) async {
      final raw = (await h.engine.preset(a.preset.id))!.raw;
      final rules = ((raw['extensions']! as Map<String, Object?>)['regex_scripts']! as List<Object?>)
          .cast<Map<String, Object?>>();
      rules[0]['disabled'] = disabled;
      final updated = await h.engine.updatePreset(a.preset.id, {
        'extensions': {'regex_scripts': rules},
      });
      final expected = jsonDecode(jsonEncode(rawA)) as Map<String, Object?>;
      final expectedRules = ((expected['extensions']! as Map<String, Object?>)['regex_scripts']! as List<Object?>)
          .cast<Map<String, Object?>>();
      expectedRules[0]['disabled'] = disabled;
      expect(updated.preset.id, a.preset.id);
      expect(updated.issues, isEmpty);
      expect(updated.preset.raw, expected);
      expect((await h.engine.preset(a.preset.id))!.raw, expected);
      expect(jsonDecode(await h.engine.exportPreset(a.preset.id)), expected);
      // updatePreset validates the saved document; it does not recompile rules.
    }

    Future<void> expectDisplay(String nodeId, String text) async {
      final display = await h.engine.displayText(chat, nodeId: nodeId);
      expect(display.text, text);
      expect(display.warnings, isEmpty);
      expect(display.superseded, isFalse);
    }

    await h.engine.bindPreset(chat, a.preset.id);
    await expectSelection(a.preset.id);
    await expectDisplay(anchorNodeId, 'DSHRXANCHOR | DSHRXPRAW | DSHRXDOUT');
    await expectStored(0);
    for (var stage = 1; stage <= 4; stage++) {
      if (stage == 2) await setPromptDisabled(true);
      if (stage == 3) {
        await setPromptDisabled(false);
        await h.engine.bindPreset(chat, b.preset.id);
      }
      if (stage == 4) await h.engine.bindPreset(chat, a.preset.id);
      await expectSelection(stage == 3 ? b.preset.id : a.preset.id);
      final events = await h.engine.send(chat, input).toList();
      expect(events.whereType<TavernTurnFailed>(), isEmpty);
      final completed = events.whereType<TavernTurnDone>();
      expect(completed, hasLength(1));
      final reply = completed.single.message;
      expect(h.model.bodies, hasLength(stage));
      // These are generate-interface assembly snapshots, not HTTP wire bytes.
      final body = h.model.bodies.last;
      expect(body.containsKey('tools'), isFalse);
      expect(body.containsKey('tool_choice'), isFalse);
      final messages = (body['messages']! as List<Object?>).cast<Map<String, Object?>>();
      expect(messages.every((message) => message['content'] is String), isTrue);
      final text = messages.map((message) => message['content']! as String).join('\n');
      int occurrences(String marker) => RegExp(RegExp.escape(marker)).allMatches(text).length;
      final main = stage == 3 ? 'DSHRXPRESETB' : 'DSHRXPRESETA';
      final prompt = stage == 1 || stage == 4 ? 'DSHRXPOUT' : 'DSHRXPRAW';
      expect(occurrences('DSHRXANCHOR'), 1);
      expect(occurrences(main), 1);
      expect(occurrences(stage == 3 ? 'DSHRXPRESETA' : 'DSHRXPRESETB'), 0);
      expect(occurrences(prompt), 1);
      expect(occurrences(prompt == 'DSHRXPOUT' ? 'DSHRXPRAW' : 'DSHRXPOUT'), 0);
      expect(occurrences('DSHRXANCHOR | $prompt | RECORDER_OK'), 1);
      expect(occurrences('RECORDER_OK'), stage);
      expect(occurrences('DSHRXDOUT'), 0);
      final displayedReply = stage == 3 ? 'RECORDER_OK' : 'DSHRXDOUT';
      await expectDisplay(reply.nodeId, displayedReply);
      await expectDisplay(anchorNodeId, 'DSHRXANCHOR | DSHRXPRAW | $displayedReply');
      await expectStored(stage, lastNodeId: reply.nodeId);
    }
  });

  test('independent book import exports unknown JSON and returns scoped regex diagnostics', () async {
    final h = await _open();
    final raw = {
      'entries': [
        {
          'id': 5,
          'keys': ['['],
          'use_regex': true,
          'content': '@@additional_keys [\nbody',
          'extensions': {
            'foreign': [false, '猫'],
          },
        },
      ],
      'opaque': {
        'kept': [null, 9],
      },
    };
    final result = await h.engine.importLorebook(jsonEncode(raw), fileName: '世界.json');
    expect(result.book.name, '世界');
    expect(result.book.stWorldName, '世界');
    expect(result.diagnostics.where((issue) => issue.status == TavernRegexCompatibility.incompatible), hasLength(2));
    result.book.raw['opaque'] = false;
    expect(jsonDecode(await h.engine.exportLorebook(result.book.id)), {...raw, 'name': '世界'});
    expect((await h.engine.listLorebooks()).single.entryCount, 1);
    await h.reopen();
    expect((await h.engine.listLorebooks()).single.name, '世界');
    expect((await h.engine.listLorebooks()).single.stWorldName, '世界');
    expect((await h.engine.lorebook(result.book.id))!['opaque'], {
      'kept': [null, 9],
    });
  });

  test('invalid world books and unsafe identifiers never create a file', () async {
    final h = await _open();
    for (final source in ['{', '{}', '{"entries":[false]}']) {
      await expectLater(h.engine.importLorebook(source), throwsA(isA<TavernImportError>()));
    }
    await expectLater(h.engine.putLorebook('../outside', _book('X')), throwsArgumentError);
    await expectLater(h.engine.deleteLorebook('../outside'), throwsArgumentError);
    expect(await h.engine.listLorebooks(), isEmpty);
  });

  test('global character chat and selected persona bindings remain independent after reopen', () async {
    final h = await _open();
    final a = await h.card();
    final b = await h.card();
    final chatA = await h.engine.createChat(a.id);
    final chatB = await h.engine.createChat(b.id);
    final persona = await h.engine.createPersona(name: 'Reader');
    await h.engine.setDefaultPersona(persona.id);
    for (final id in ['G-BOOK', 'C-BOOK', 'Q-BOOK', 'P-BOOK']) {
      await h.engine.putLorebook(id, _book(id));
    }
    await h.engine.bindLorebooks(['G-BOOK']);
    await h.engine.bindLorebooks(['C-BOOK'], source: WorldInfoSource.character, characterId: a.id);
    await h.engine.bindLorebooks(['Q-BOOK'], source: WorldInfoSource.chat, chatId: chatA);
    await h.engine.bindLorebooks(['P-BOOK'], source: WorldInfoSource.persona, personaId: persona.id);
    await h.reopen();
    final first = await h.request(chatA);
    for (final text in ['G-BOOK', 'C-BOOK', 'Q-BOOK', 'P-BOOK']) {
      expect(first, contains(text));
    }
    final second = await h.request(chatB);
    expect(second, contains('G-BOOK'));
    expect(second, contains('P-BOOK'));
    expect(second, isNot(contains('C-BOOK')));
    expect(second, isNot(contains('Q-BOOK')));
    final other = await h.engine.createPersona(name: 'Other');
    await h.engine.bindPersona(chatB, other.id);
    expect(await h.request(chatB), isNot(contains('P-BOOK')));
    await h.engine.bindLorebooks([], source: WorldInfoSource.character, characterId: a.id);
    expect(await h.request(chatA), isNot(contains('C-BOOK')));
  });

  test('book binding validates identity scopes and snapshots the caller list', () async {
    final h = await _open();
    final card = await h.card();
    final chat = await h.engine.createChat(card.id);
    final ids = ['present'];
    await h.engine.putLorebook('present', _book('PRESENT'));
    final binding = h.engine.bindLorebooks(ids, source: WorldInfoSource.character, characterId: card.id);
    ids[0] = 'mutated';
    await binding;
    expect(await h.request(chat), contains('PRESENT'));
    expect(() => h.engine.bindLorebooks([], characterId: card.id), throwsArgumentError);
    expect(
      () => h.engine.bindLorebooks([], source: WorldInfoSource.character, characterId: card.id, chatId: chat),
      throwsArgumentError,
    );
    await expectLater(
      h.engine.bindLorebooks([], source: WorldInfoSource.persona, personaId: 'missing'),
      throwsA(isA<TavernImportError>()),
    );
  });

  test('deleting a book retains bindings and reports missing until the id is restored', () async {
    final h = await _open();
    final chat = await h.chat();
    await h.engine.putLorebook('book', _book('OLD-BOOK'));
    await h.engine.bindLorebooks(['book']);
    expect(await h.request(chat), contains('OLD-BOOK'));
    await h.engine.deleteLorebook('book');
    expect((await h.engine.readSettings())['lorebooks'], {
      'global': ['book'],
    });
    expect(await h.request(chat), isNot(contains('OLD-BOOK')));
    expect((await h.engine.inspectTurn(chat))!.worldInfo['missing'], [
      {'bookId': 'book', 'source': 'global', 'reason': 'missing'},
    ]);
    expect(await h.engine.listLorebooks(), isEmpty);
    await h.engine.putLorebook('book', _book('NEW-BOOK'));
    expect(await h.request(chat), contains('NEW-BOOK'));
    expect((await h.engine.inspectTurn(chat))!.worldInfo.containsKey('missing'), isFalse);
  });

  test('book deletion does not cancel a turn that has already captured its contents', () async {
    final h = await _open();
    final chat = await h.chat();
    await h.engine.putLorebook('book', _book('CAPTURED-BOOK'));
    await h.engine.bindLorebooks(['book']);
    final started = h.model.holdNext();
    final turn = h.engine.send(chat, 'Q').toList();
    await started;
    await h.engine.deleteLorebook('book');
    expect(_bodyText(h.model.bodies.last), contains('CAPTURED-BOOK'));
    h.model.release();
    expect((await turn).whereType<TavernTurnDone>(), hasLength(1));
    expect(await h.request(chat), isNot(contains('CAPTURED-BOOK')));
  });

  test('book writes reads and deletes share their publication order', () async {
    final h = await _open();
    final write = h.engine.putLorebook('book', _book('ONE'));
    final read = h.engine.lorebook('book');
    final remove = h.engine.deleteLorebook('book');
    await write;
    expect((await read)!['name'], 'ONE');
    await remove;
    expect(await h.engine.lorebook('book'), isNull);
    await h.engine.putLorebook('book', _book('TWO'));
    expect((await h.engine.lorebook('book'))!['name'], 'TWO');
    final detached = (await h.engine.lorebook('book'))!;
    detached['entries'] = [];
    expect((await h.engine.listLorebooks()).single.entryCount, 1);
  });

  test('corrupt book files fail visibly instead of disappearing from the list', () async {
    final h = await _open();
    final file = File('${h.directory.path}/lorebooks/broken.json');
    await file.parent.create(recursive: true);
    await file.writeAsString('{broken');
    await expectLater(h.engine.listLorebooks(), throwsFormatException);
    await h.engine.deleteLorebook('broken');
    expect(await h.engine.listLorebooks(), isEmpty);
  });

  test('a skipped native regex cannot activate NOT and inspection retains the warning', () async {
    final h = await _open();
    final chat = await h.chat();
    await h.engine.putLorebook('guarded', {
      'entries': {
        '0': {
          'uid': 0,
          'key': ['Q'],
          'keysecondary': ['/[/'],
          'selective': true,
          'selectiveLogic': 2,
          'content': 'MUST-NOT-ACTIVATE',
          'position': 0,
        },
        '1': {
          'uid': 1,
          'key': ['Q'],
          'content': 'OTHER-ENTRY',
          'position': 0,
        },
      },
    });
    await h.engine.bindLorebooks(['guarded']);
    final body = await h.request(chat);
    expect(body, isNot(contains('MUST-NOT-ACTIVATE')));
    expect(body, contains('OTHER-ENTRY'));
    final inspection = (await h.engine.inspectTurn(chat))!;
    expect(inspection.worldInfo['regexDiagnostics'], isNotEmpty);
    final before = jsonEncode(inspection.worldInfo['regexDiagnostics']);
    await h.reopen();
    expect(jsonEncode((await h.engine.inspectTurn(chat))!.worldInfo['regexDiagnostics']), before);
  });

  test('empty imported tree restores committed variables for display after reopen', () async {
    final h = await _open();
    final chat = await h.imported(
      [],
      metadata: {
        'variables': {'n': 'persisted'},
      },
    );
    await h.engine.importRegexScripts(jsonEncode(_rule('A', '{{getvar::n}}')));
    await h.reopen();
    expect(await h.engine.path(chat), isEmpty);
    expect(h.engine.variables(chat), {'n': 'persisted'});
    expect((await h.engine.displayText(chat, text: 'A')).text, 'persisted');
    expect(h.engine.variables(chat), {'n': 'persisted'});
  });

  test('narrator trim macros receive the stored speaker like fixed ST messageFormatting', () async {
    final h = await _open();
    final chat = await h.imported([
      _row('Stage', speaker: 'Stage', extra: {'type': 'narrator'}),
    ]);
    await h.engine.importRegexScripts(
      jsonEncode(
        _rule(
          '(Stage)',
          r'$1',
          extra: {
            'placement': [3],
            'trimStrings': ['{{char}}'],
          },
        ),
      ),
    );
    final node = (await h.engine.path(chat)).single;
    expect(node.role, TavernRole.narrator);
    expect(node.speaker, 'Stage');
    expect((await h.engine.displayText(chat, nodeId: node.nodeId)).text, '');
  });

  test('automatic depth excludes hidden rows while only the true system speaker bypasses regex', () async {
    final h = await _open();
    final chat = await h.imported([
      _row('A'),
      {..._row('A'), 'is_system': true},
      {..._row('A', speaker: 'SillyTavern System'), 'is_system': true},
      _row('A'),
    ]);
    await h.engine.importRegexScripts(jsonEncode(_rule('A', 'DEPTH', extra: {'minDepth': 1, 'maxDepth': 1})));
    final path = await h.engine.path(chat);
    expect(path[1].hidden, isTrue);
    expect((await h.engine.displayText(chat, nodeId: path.first.nodeId)).text, 'DEPTH');
    expect((await h.engine.displayText(chat, nodeId: path[1].nodeId, depth: 1)).text, 'DEPTH');
    expect((await h.engine.displayText(chat, nodeId: path[2].nodeId, depth: 1)).text, 'A');
    expect((await h.engine.displayText(chat, text: 'A', role: TavernRole.system, depth: 1)).text, 'A');
    expect(
      (await h.engine.displayText(chat, text: 'A', role: TavernRole.system, speaker: 'Guide', depth: 1)).text,
      'DEPTH',
    );
  });

  test('hidden user and narrator messages retain their display placements', () async {
    final h = await _open();
    final chat = await h.imported([
      {..._row('A', speaker: 'User'), 'is_user': true, 'is_system': true},
      {
        ..._row('A', speaker: 'Stage', extra: {'type': 'narrator'}),
        'is_system': true,
      },
    ]);
    await h.engine.importRegexScripts(
      jsonEncode([
        _rule(
          'A',
          'USER',
          extra: {
            'placement': [1],
          },
        ),
        _rule(
          'A',
          'NARRATOR',
          extra: {
            'placement': [3],
          },
        ),
      ]),
    );
    final path = await h.engine.path(chat);
    expect((await h.engine.displayText(chat, nodeId: path.first.nodeId)).text, 'USER');
    expect((await h.engine.displayText(chat, nodeId: path.last.nodeId)).text, 'NARRATOR');
  });

  test('raw text without a message id has undefined depth unless the caller supplies it', () async {
    final h = await _open();
    final chat = await h.chat();
    await h.engine.importRegexScripts(jsonEncode(_rule('A', 'RAW', extra: {'minDepth': 7, 'maxDepth': 7})));
    expect((await h.engine.displayText(chat, text: 'A')).text, 'RAW');
    expect((await h.engine.displayText(chat, text: 'A', depth: 0)).text, 'A');
  });

  test('raw user and custom narrator trim macros use the supplied display identity', () async {
    final h = await _open();
    final profile = await h.engine.createPersona(name: 'Reader');
    await h.engine.setDefaultPersona(profile.id);
    final chat = await h.chat();
    await h.engine.importRegexScripts(
      jsonEncode(
        _rule(
          '(Reader|Stage)',
          r'$1',
          extra: {
            'placement': [1, 3],
            'trimStrings': ['{{char}}'],
          },
        ),
      ),
    );
    expect((await h.engine.displayText(chat, text: 'Reader', role: TavernRole.user)).text, '');
    expect((await h.engine.displayText(chat, text: 'Stage', role: TavernRole.narrator, speaker: 'Stage')).text, '');
  });

  test('deleting managed regex leaves an active turn captured write-back view unchanged', () async {
    final h = await _open();
    final rule = _rule('A', 'OLD', extra: {'markdownOnly': false});
    final id = (await h.engine.importRegexScripts(jsonEncode(rule))).scripts.single.id;
    final chat = await h.chat();
    final started = h.model.holdNext();
    final turn = h.engine.send(chat, 'Q').toList();
    await started;
    await h.engine.deleteRegex(id);
    h.model.release();
    expect((await turn).whereType<TavernTurnDone>().single.message.text, 'OLD');
    expect((await h.engine.send(chat, 'Q').toList()).whereType<TavernTurnDone>().single.message.text, 'A');
  });
}

Map<String, Object?> _rule(String find, String replace, {Map<String, Object?> extra = const {}}) => {
  'id': 'script',
  'scriptName': 'test rule',
  'findRegex': '/$find/g',
  'replaceString': replace,
  'trimStrings': <String>[],
  'placement': [2],
  'disabled': false,
  'markdownOnly': true,
  'promptOnly': false,
  'runOnEdit': true,
  'substituteRegex': 0,
  ...extra,
};

Map<String, Object?> _book(String name) => {
  'name': name,
  'entries': {
    '0': {
      'uid': 0,
      'key': ['Q'],
      'constant': true,
      'content': name,
      'position': 0,
      'order': 100,
    },
  },
};

Map<String, Object?> _row(String text, {String speaker = 'Guide', Map<String, Object?> extra = const {}}) => {
  'name': speaker,
  'is_user': false,
  'is_system': false,
  'send_date': '2026-11-10T00:00:00Z',
  'mes': text,
  'extra': extra,
};

String _bodyText(Map<String, Object?> body) => (body['messages']! as List<Object?>)
    .cast<Map<String, Object?>>()
    .map((message) => message['content'] ?? '')
    .join('\n');

Future<_Harness> _open() async {
  final directory = await Directory.systemTemp.createTemp('dsh-t21-library-display-');
  final h = _Harness(directory);
  await h.open();
  addTearDown(() async {
    await h.engine.close();
    await directory.delete(recursive: true);
  });
  return h;
}

class _Harness {
  _Harness(this.directory);
  final Directory directory;
  final model = _Model();
  late TavernEngine engine;
  int randomCalls = 0;
  Future<void> open() async {
    engine = await TavernEngine.openDirectory(
      directory,
      modelClient: model,
      config: TavernModelConfig(apiKey: () async => 'fixture', baseUrl: 'https://configured.invalid'),
      clock: () => DateTime.utc(2026, 11, 10),
      random: () {
        randomCalls++;
        return 0.25;
      },
    );
  }

  Future<void> reopen() async {
    await engine.close();
    await open();
  }

  Future<TavernCharacter> card([Map<String, Object?> fields = const {}]) => engine.importCard(
    Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'spec': 'chara_card_v3',
          'spec_version': '3.0',
          'data': {
            'name': 'Guide',
            'description': '',
            'personality': '',
            'scenario': '',
            'first_mes': 'A',
            'mes_example': '',
            'creator_notes': '',
            'system_prompt': '',
            'post_history_instructions': '',
            'alternate_greetings': <String>[],
            'tags': <String>[],
            'creator': '',
            'character_version': '',
            'extensions': <String, Object?>{},
            ...fields,
          },
        }),
      ),
    ),
  );
  Future<String> chat() async => engine.createChat((await card()).id);
  Future<String> imported(List<Map<String, Object?>> rows, {Map<String, Object?> metadata = const {}}) async {
    final character = await card();
    final source = [
      jsonEncode({
        'user_name': 'User',
        'character_name': 'Guide',
        'create_date': '2026-11-10T00:00:00Z',
        'chat_metadata': metadata,
      }),
      ...rows.map(jsonEncode),
    ].join('\n');
    final result = await engine.importChats(character.id, [
      TavernChatFile(fileName: 'display.jsonl', bytes: Uint8List.fromList(utf8.encode('$source\n'))),
    ]);
    return result.chatIds.single;
  }

  Future<String> request(String chat) async {
    final events = await engine.send(chat, 'Q').toList();
    expect(events.whereType<TavernTurnDone>(), hasLength(1));
    return _bodyText(model.bodies.last);
  }
}

class _Model extends TavernModelClient {
  final bodies = <Map<String, Object?>>[];
  String responseText = 'A';
  String? reasoning;
  Completer<void>? _held;
  Completer<void>? _started;
  Future<void> holdNext() {
    _held = Completer<void>();
    _started = Completer<void>();
    return _started!.future;
  }

  void release() {
    if (_held != null && !_held!.isCompleted) _held!.complete();
  }

  @override
  Stream<ModelDelta> generate({
    required TavernModelConfig config,
    required Map<String, Object?> body,
    required ModelCancellation cancellation,
    void Function(int attempt)? onRequestStarted,
  }) async* {
    bodies.add(jsonDecode(jsonEncode(body)) as Map<String, Object?>);
    final held = _held;
    if (held != null) {
      _started!.complete();
      try {
        await cancellation.wait(held.future);
      } finally {
        _held = null;
      }
    }
    if (reasoning != null) yield ModelReasoning(reasoning!);
    yield ModelText(responseText);
    yield const ModelFinished('stop');
  }
}
