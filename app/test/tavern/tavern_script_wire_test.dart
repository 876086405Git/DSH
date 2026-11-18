import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/tavern/tavern_script_wire.dart';
import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter_test/flutter_test.dart';

/// The card's page side: a request as JSON text, the reply read back from
/// JSON text — what crosses the channel.
Future<Map<String, Object?>> _ask(TavernScriptWire wire, String method, [Map<String, Object?>? params]) async {
  final request = jsonDecode(jsonEncode({'id': method, 'method': method, 'params': ?params}));
  final reply = await wire.handle(request);
  return jsonDecode(jsonEncode(reply)) as Map<String, Object?>;
}

Object? _result(Map<String, Object?> reply) {
  expect(reply['ok'], isTrue, reason: '${reply['error']}');
  return reply['result'];
}

Map<String, Object?> _error(Map<String, Object?> reply) {
  expect(reply['ok'], isFalse);
  return reply['error']! as Map<String, Object?>;
}

void main() {
  late Directory dir;
  late Tavern tavern;
  late TavernScriptWire wire;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('script-wire');
    tavern = await openTavern(dir.path);
    wire = TavernScriptWire(tavern.scripts);
  });
  tearDown(() async {
    await tavern.close();
    await dir.delete(recursive: true);
  });

  test('variables over the channel: replaced, changed by path, read back; null stays a member', () async {
    final caps = _result(await _ask(wire, 'capabilities'))! as Map<String, Object?>;
    expect(caps['simulated'], isFalse);
    expect(caps['methods'], containsAll(['getVariables', 'replaceVariables', 'mutateVariables']));
    expect(caps['scopes'], contains('global'));

    final context = _result(await _ask(wire, 'openContext', {'instanceId': 'frame'}))! as Map<String, Object?>;
    final id = context['id']! as String;
    const global = {'scope': 'global'};

    final first =
        _result(
              await _ask(wire, 'replaceVariables', {
                'contextId': id,
                'target': global,
                'value': {
                  'hp': 7,
                  'bag': ['key'],
                  'note': null,
                },
              }),
            )!
            as Map<String, Object?>;
    expect(first['value'], {
      'hp': 7,
      'bag': ['key'],
      'note': null,
    });
    expect(first['version'], isA<String>()); // opaque, as given
    expect((first['target']! as Map)['scope'], 'global');

    final changed =
        _result(
              await _ask(wire, 'mutateVariables', {
                'contextId': id,
                'target': global,
                'changes': [
                  {
                    'kind': 'set',
                    'path': ['bag', 1],
                    'value': 'map',
                  },
                  {
                    'kind': 'insertIfAbsent',
                    'path': ['hp'],
                    'value': 1,
                  },
                  {
                    'kind': 'remove',
                    'path': ['note'],
                  },
                ],
              }),
            )!
            as Map<String, Object?>;
    expect(changed['results'], [
      {
        'kind': 'set',
        'path': ['bag', 1],
        'existed': false,
        'changed': true,
      },
      {
        'kind': 'insertIfAbsent',
        'path': ['hp'],
        'existed': true,
        'changed': false,
      },
      {
        'kind': 'remove',
        'path': ['note'],
        'existed': true,
        'changed': true,
      },
    ]);
    final read = _result(await _ask(wire, 'getVariables', {'contextId': id, 'target': global}))! as Map;
    expect(read['value'], {
      'hp': 7,
      'bag': ['key', 'map'],
    });

    // The version it was read at is stale now: refused, nothing written.
    final stale = _error(
      await _ask(wire, 'replaceVariables', {
        'contextId': id,
        'target': global,
        'value': {'hp': 0},
        'expectedVersion': first['version'],
      }),
    );
    expect(stale['code'], 'revisionConflict');
    expect(stale['committed'], isFalse);
    expect(((await _ask(wire, 'getVariables', {'contextId': id, 'target': global}))['result']! as Map)['value'], {
      'hp': 7,
      'bag': ['key', 'map'],
    });
  });

  test("a chat's messages over the channel, numbered along the path", () async {
    final card = await File('assets/tavern/sample_innkeeper.json').readAsBytes();
    final character = await tavern.importCard(card, fileName: 'sample_innkeeper.json');
    final chat = await tavern.createChat(character.id);
    final context =
        _result(await _ask(wire, 'openContext', {'instanceId': 'frame', 'chatId': chat}))! as Map<String, Object?>;
    final page =
        _result(await _ask(wire, 'getChatMessages', {'contextId': context['id'], 'range': <String, Object?>{}}))!
            as Map<String, Object?>;
    expect(page['pathRevision'], isA<String>());
    final messages = page['messages']! as List;
    expect(messages, hasLength(page['totalPathLength']));
    final greeting = messages.first as Map<String, Object?>;
    expect(greeting['messageId'], 0);
    expect(greeting['role'], 'assistant');
    expect(greeting['nativeRole'], 'character');
    expect(greeting['ref'], {'chatId': chat, 'nodeId': isA<String>()});
    expect(greeting['message'], isNotEmpty);
    // No data yet: an empty object, not null.
    expect(greeting['hasData'], isFalse);
    expect(greeting['data'], <String, Object?>{});
    expect(greeting.containsKey('speakerCharacterId'), isTrue);
  });

  test('a snapshot: the path and every variable the context sees, as of its lastSeq', () async {
    final card = await File('assets/tavern/sample_innkeeper.json').readAsBytes();
    final character = await tavern.importCard(card, fileName: 'sample_innkeeper.json');
    final chat = await tavern.createChat(character.id);
    final context =
        _result(await _ask(wire, 'openContext', {'instanceId': 'frame', 'chatId': chat, 'characterId': character.id}))!
            as Map<String, Object?>;
    _result(
      await _ask(wire, 'replaceVariables', {
        'contextId': context['id'],
        'target': {'scope': 'chat'},
        'value': {'met': true},
      }),
    );
    final snapshot = _result(await _ask(wire, 'snapshot', {'contextId': context['id']}))! as Map<String, Object?>;
    expect(snapshot['lastSeq'], isA<int>());
    expect(snapshot['pathRevision'], isA<String>());
    expect((snapshot['context']! as Map)['id'], context['id']);
    expect(snapshot['messages'], isNotEmpty);
    final variables = {
      for (final v in (snapshot['variables']! as List).cast<Map<String, Object?>>()) (v['target']! as Map)['scope']: v,
    };
    expect(variables.keys, containsAll(['global', 'character', 'chat', 'message']));
    expect(variables['chat']!['value'], {'met': true});
    expect(variables['chat']!['version'], isA<String>());
    // The latest message's own variables, named by its stable ref.
    final latest = (snapshot['messages']! as List).last as Map;
    expect((variables['message']!['target']! as Map)['messageRef'], latest['ref']);
  });

  test('messages written over the channel: created, changed, hidden, moved, deleted', () async {
    final card = await File('assets/tavern/sample_innkeeper.json').readAsBytes();
    final character = await tavern.importCard(card, fileName: 'sample_innkeeper.json');
    final chat = await tavern.createChat(character.id);
    final id =
        (_result(await _ask(wire, 'openContext', {'instanceId': 'frame', 'chatId': chat}))! as Map)['id']! as String;
    Future<List<String>> texts() async {
      final page = _result(await _ask(wire, 'getChatMessages', {'contextId': id})) as Map;
      return [for (final m in page['messages'] as List) (m as Map)['message'] as String];
    }

    final greeting = (await texts()).single;
    final made =
        _result(
              await _ask(wire, 'createChatMessages', {
                'contextId': id,
                'messages': [
                  {'role': 'user', 'message': '一'},
                  {
                    'role': 'assistant',
                    'message': '二',
                    'data': {'hp': 1},
                  },
                ],
              }),
            )!
            as Map;
    expect(made['pathRevision'], isA<String>());
    expect(made['upsertMessages'], hasLength(2));
    expect(await texts(), [greeting, '一', '二']);
    _result(
      await _ask(wire, 'createChatMessages', {
        'contextId': id,
        'messages': [
          {'role': 'system', 'message': '零'},
        ],
        'insertBefore': 1,
      }),
    );
    expect(await texts(), [greeting, '零', '一', '二']);

    // Changed and hidden by floor; the engine's own field names.
    _result(
      await _ask(wire, 'setChatMessages', {
        'contextId': id,
        'patches': [
          {
            'messageId': 2,
            'fields': {'message': '一改'},
          },
          {
            'messageId': -1,
            'fields': {'hidden': true},
          },
        ],
        'options': {'refresh': 'none'},
      }),
    );
    final page = _result(await _ask(wire, 'getChatMessages', {'contextId': id})) as Map;
    final rows = [for (final m in page['messages'] as List) m as Map];
    expect([for (final m in rows) m['message']], [greeting, '零', '一改', '二']);
    expect(rows.last['hidden'], isTrue);
    expect(rows.last['data'], {'hp': 1});

    // [1,3) and [3,4) swap places; then floors 1 and 2 go.
    _result(await _ask(wire, 'rotateChatMessages', {'contextId': id, 'begin': 1, 'middle': 3, 'end': 4}));
    expect(await texts(), [greeting, '二', '零', '一改']);
    _result(
      await _ask(wire, 'deleteChatMessages', {
        'contextId': id,
        'messageIds': [1, 2],
      }),
    );
    expect(await texts(), [greeting, '一改']);

    // Refused, and named: data given as null; a field the engine does not know.
    final nullData = _error(
      await _ask(wire, 'createChatMessages', {
        'contextId': id,
        'messages': [
          {'role': 'user', 'message': 'x', 'data': null},
        ],
      }),
    );
    expect((nullData['code'], nullData['fieldPath']), ('invalidArgument', 'messages[0].data'));
    final unknown = _error(
      await _ask(wire, 'setChatMessages', {
        'contextId': id,
        'patches': [
          {
            'messageId': 1,
            'fields': {'is_hidden': true},
          },
        ],
      }),
    );
    expect(unknown['code'], 'invalidArgument');
    expect(unknown['fieldPath'], '/is_hidden');
    final badRefresh = _error(
      await _ask(wire, 'deleteChatMessages', {
        'contextId': id,
        'messageIds': [1],
        'options': {'refresh': 'sometimes'},
      }),
    );
    expect(badRefresh['fieldPath'], 'options.refresh');
    expect(await texts(), [greeting, '一改']);
  });

  test("asking the model: the engine's request as given, its events told as they come, the result as JSON", () async {
    final bridge = _Generating();
    final told = <Map<String, Object?>>[];
    final wire = TavernScriptWire(bridge, onGeneration: told.add);
    final result =
        _result(
              await _ask(wire, 'generate', {
                'contextId': 'ctx',
                'request': {
                  'generationId': 'g1',
                  'userInput': '在吗',
                  'stream': true,
                  'overrides': {'scenario': '雨夜'},
                },
              }),
            )!
            as Map<String, Object?>;
    expect(result, {'id': 'g1', 'text': '你好', 'reasoning': null, 'finishReason': 'stop', 'hookIssues': <Object?>[]});
    expect(bridge.asked!.userInput, '在吗');
    expect(bridge.asked!.stream, isTrue);
    expect(bridge.asked!.overrides.fields, {'scenario': '雨夜'});
    expect(
      [for (final e in told) (e['event'], e['delta'])],
      [('started', null), ('textDelta', '你'), ('textDelta', '好')],
    );
    expect(told.every((e) => e['id'] == 'g1'), isTrue);

    // Raw: its ordered prompts as the engine reads them.
    told.clear();
    _result(
      await _ask(wire, 'generateRaw', {
        'contextId': 'ctx',
        'request': {
          'generationId': 'g2',
          'orderedPrompts': [
            {'kind': 'placeholder', 'placeholder': 'chatHistory'},
            {'kind': 'literal', 'role': 'system', 'content': '只说一句'},
          ],
        },
      }),
    );
    expect(bridge.raw!.orderedPrompts, hasLength(2));

    // A field the engine does not have is refused by it; a failure is a
    // structured error; a stop for nothing running is false.
    expect(
      _error(
        await _ask(wire, 'generate', {
          'contextId': 'ctx',
          'request': {'tools': <Object?>[]},
        }),
      )['code'],
      isA<String>(),
    );
    bridge.fail = true;
    expect(
      _error(
        await _ask(wire, 'generate', {
          'contextId': 'ctx',
          'request': {'generationId': 'g3'},
        }),
      )['code'],
      'model',
    );
    expect(_result(await _ask(wire, 'stopGenerationById', {'generationId': 'nobody'})), isFalse);
    expect(_result(await _ask(wire, 'stopGenerationById', {'generationId': 'g1'})), isTrue);
  });

  test('a Slash script over the channel: its pipe and how it ended; a failure is the error', () async {
    final context = _result(await _ask(wire, 'openContext', {'instanceId': 'frame'}))! as Map<String, Object?>;
    final id = context['id']! as String;

    final ran =
        _result(
              await _ask(wire, 'triggerSlash', {
                'contextId': id,
                'source': '/setglobalvar key=weather {{arg::w}} | /getglobalvar weather',
                'arguments': {'w': '小雨'},
                'executionId': 'weather',
              }),
            )!
            as Map<String, Object?>;
    expect(ran, {'id': 'weather', 'pipe': '小雨', 'completion': 'completed'});
    final global =
        _result(
              await _ask(wire, 'getVariables', {
                'contextId': id,
                'target': {'scope': 'global'},
              }),
            )!
            as Map<String, Object?>;
    expect((global['value']! as Map)['weather'], '小雨');

    final stopped = _result(await _ask(wire, 'triggerSlash', {'contextId': id, 'source': '/pass 半路 | /abort'}))!;
    expect((stopped as Map)['completion'], 'aborted');

    expect(_error(await _ask(wire, 'triggerSlash', {'contextId': id, 'source': '/nosuchcommand'}))['code'], isNotNull);
    final bad = _error(
      await _ask(wire, 'triggerSlash', {
        'contextId': id,
        'source': '/pass x',
        'arguments': {'n': 1},
      }),
    );
    expect((bad['code'], bad['fieldPath']), ('invalidArgument', 'arguments.n'));
    expect(_result(await _ask(wire, 'stopScript', {'executionId': 'nothing'})), isFalse);
  });

  test('the regexes in play, by source, in the shape 酒馆助手 hands them out', () async {
    await tavern.setSettings({
      'globalRegexScripts': [
        {
          'id': 'r1',
          'scriptName': '去括号',
          'findRegex': r'/\(.*?\)/g',
          'replaceString': '',
          'trimStrings': ['甲', '乙'],
          'placement': [2, 6],
          'disabled': false,
          'markdownOnly': true,
          'promptOnly': false,
          'runOnEdit': true,
          'substituteRegex': 0,
          'minDepth': 2,
          'maxDepth': null,
        },
        {
          'id': 'r2',
          'scriptName': '只改发出去的',
          'findRegex': 'x',
          'replaceString': 'y',
          'trimStrings': <Object?>[],
          'placement': [1, 3, 5],
          'disabled': true,
          'markdownOnly': false,
          'promptOnly': true,
          'runOnEdit': false,
          'substituteRegex': 0,
          'minDepth': null,
          'maxDepth': 4,
        },
      ],
    });
    final id =
        (_result(await _ask(wire, 'openContext', {'instanceId': 'frame'}))! as Map<String, Object?>)['id']! as String;
    final regexes = _result(await _ask(wire, 'getTavernRegexes', {'contextId': id}))! as Map<String, Object?>;
    expect(regexes.keys, unorderedEquals(['global', 'preset', 'character', 'chat']));
    expect(regexes['global'], [
      {
        'id': 'r1',
        'script_name': '去括号',
        'enabled': true,
        'run_on_edit': true,
        'scope': 'global',
        'find_regex': r'/\(.*?\)/g',
        'trim_strings': '甲\n乙',
        'replace_string': '',
        'source': {
          'user_input': false,
          'ai_output': true,
          'slash_command': false,
          'world_info': false,
          'reasoning': true,
        },
        // 仅格式显示 checked.
        'destination': {'display': true, 'prompt': false},
        'min_depth': 2,
        'max_depth': null,
      },
      {
        'id': 'r2',
        'script_name': '只改发出去的',
        'enabled': false,
        'run_on_edit': false,
        'scope': 'global',
        'find_regex': 'x',
        'trim_strings': '',
        'replace_string': 'y',
        'source': {
          'user_input': true,
          'ai_output': false,
          'slash_command': true,
          'world_info': true,
          'reasoning': false,
        },
        'destination': {'display': false, 'prompt': true},
        'min_depth': null,
        'max_depth': 4,
      },
    ]);
    // As the engine runs them: a legacy placement 0 is every source, both
    // boxes checked; neither box checked changes the message itself.
    Map<String, Object?> rule(String id, List<Object?> placement, {bool md = false, bool prompt = false}) => {
      'id': id,
      'scriptName': id,
      'findRegex': 'a',
      'replaceString': 'b',
      'trimStrings': <Object?>[],
      'placement': placement,
      'disabled': false,
      'markdownOnly': md,
      'promptOnly': prompt,
      'runOnEdit': false,
      'substituteRegex': 0,
    };
    await tavern.setSettings({
      'globalRegexScripts': [
        rule('legacy', [0]),
        rule('stored', [2]),
        rule('both', [2], md: true, prompt: true),
      ],
    });
    final again = _result(await _ask(wire, 'getTavernRegexes', {'contextId': id}))! as Map<String, Object?>;
    final byId = {for (final r in (again['global']! as List).cast<Map<String, Object?>>()) r['id']: r};
    expect(byId['legacy']!['source'], {
      'user_input': true,
      'ai_output': true,
      'slash_command': true,
      'world_info': true,
      'reasoning': true,
    });
    expect(byId['legacy']!['destination'], {'display': true, 'prompt': true});
    expect(byId['stored']!['destination'], {'display': false, 'prompt': false});
    expect(byId['both']!['destination'], {'display': true, 'prompt': true});
    expect(regexes['character'], isEmpty);
  });

  test(
    'stage 4 over the channel: a book made, read, written with its version, gone; the preset; the picture; MVU',
    () async {
      final card = await File('assets/tavern/sample_innkeeper.json').readAsBytes();
      final character = await tavern.importCard(card, fileName: 'sample_innkeeper.json');
      final chat = await tavern.createChat(character.id);
      final id =
          (_result(await _ask(wire, 'openContext', {'instanceId': 'frame', 'chatId': chat}))!
                  as Map<String, Object?>)['id']!
              as String;
      Future<Object?> ok(String method, [Map<String, Object?> params = const {}]) async =>
          _result(await _ask(wire, method, {'contextId': id, ...params}));

      final made = await ok('createBook', {
        'name': '旅店传闻',
        'raw': {
          'entries': {
            '0': {
              'uid': 0,
              'key': ['酒'],
              'comment': '酒',
              'content': '老板娘爱喝酒',
            },
          },
        },
      }) as Map<String, Object?>;
      final ref = made['ref']! as Map<String, Object?>;
      expect(ref['kind'], 'standalone');
      final directory = await ok('getBookDirectory') as Map<String, Object?>;
      expect([
        for (final b in (directory['books']! as List).cast<Map<String, Object?>>()) b['displayName'],
      ], contains('旅店传闻'));
      expect(await ok('resolveBook', {'nameOrHandle': '旅店传闻'}), ref);
      final read = await ok('readBook', {'ref': ref}) as Map<String, Object?>;
      final book = read['book']! as Map<String, Object?>;
      ((book['entries']! as Map<String, Object?>)['0']! as Map<String, Object?>)['content'] = '改过了';
      final written = await ok('replaceBook', {
        'ref': ref,
        'book': book,
        'expectedVersion': read['version'],
      }) as Map<String, Object?>;
      final entries = (written['book']! as Map<String, Object?>)['entries']! as Map<String, Object?>;
      expect((entries['0']! as Map<String, Object?>)['content'], '改过了');
      // The version it was read at is gone: refused, said so.
      final stale = _error(
        await _ask(wire, 'replaceBook', {
          'contextId': id,
          'ref': ref,
          'book': book,
          'expectedVersion': read['version'],
        }),
      );
      expect(stale['code'], 'revisionConflict');
      expect(stale['issues'], isA<List<Object?>>());
      await ok('deleteBook', {'ref': ref, 'expectedVersion': written['version']});

      final preset = await ok('readPreset', {
        'ref': {'kind': 'current'},
      }) as Map<String, Object?>;
      expect(preset['ref'], {'kind': 'current'});
      expect(preset['raw'], isA<Map<String, Object?>>());

      // The picture goes as base64; what is not base64 is refused by name.
      final picture = await ok('readCharacterAvatar', {'characterId': character.id}) as Map<String, Object?>;
      expect(picture['bytes'], anyOf(isNull, isA<String>()));
      final bad = _error(
        await _ask(wire, 'replaceCharacterAvatar', {
          'contextId': id,
          'characterId': character.id,
          'bytes': 'not base64!',
          'expectedVersion': picture['version'],
        }),
      );
      expect((bad['code'], bad['fieldPath']), ('invalidArgument', 'bytes'));

      final mvu = await ok('setMvuEnabled', {'enabled': true}) as Map<String, Object?>;
      expect((mvu['chatId'], mvu['enabled']), (chat, true));
      expect(mvu['issues'], isA<List<Object?>>());
      final parsed = await ok('parseMvuMessage', {
        'message': "<UpdateVariable>_.set('好感度', 0, 10);//喝了一杯</UpdateVariable>",
        'previousData': {
          'stat_data': {'好感度': 0},
        },
      }) as Map<String, Object?>;
      expect((parsed['data']! as Map<String, Object?>)['stat_data'], containsPair('好感度', 10));
    },
  );

  test('a wrong request is told why, as an error, not a broken channel', () async {
    final id =
        (_result(await _ask(wire, 'openContext', {'instanceId': 'frame'}))! as Map<String, Object?>)['id']! as String;
    Future<Map<String, Object?>> refused(String method, [Map<String, Object?>? params]) async =>
        _error(await _ask(wire, method, params));

    expect((await refused('runScript'))['code'], 'unsupportedCapability');
    expect((await refused('getVariables', {'contextId': id}))['fieldPath'], 'target');
    expect(
      (await refused('getVariables', {
        'contextId': id,
        'target': {'scope': 'everywhere'},
      }))['fieldPath'],
      'target.scope',
    );
    final notObject = await refused('replaceVariables', {
      'contextId': id,
      'target': {'scope': 'global'},
      'value': [1],
    });
    expect((notObject['code'], notObject['fieldPath']), ('invalidArgument', 'value'));
    // A version is the string it was handed out as, never a number.
    final numeric = await refused('replaceVariables', {
      'contextId': id,
      'target': {'scope': 'global'},
      'value': <String, Object?>{},
      'expectedVersion': 3,
    });
    expect(numeric['fieldPath'], 'expectedVersion');
    expect(
      (await refused('mutateVariables', {
        'contextId': id,
        'target': {'scope': 'global'},
        'changes': [
          {
            'kind': 'set',
            'path': [-1],
            'value': 1,
          },
        ],
      }))['fieldPath'],
      'changes[0].path',
    );
    // The engine's own refusals come through with their code.
    expect(
      (await refused('getVariables', {
        'contextId': 'nobody',
        'target': {'scope': 'global'},
      }))['code'],
      isIn(['noContext', 'closedContext']),
    );
    // Not even an object: still an answer.
    final reply = await wire.handle('hello');
    expect(reply['ok'], isFalse);
    expect(jsonEncode(reply), isA<String>());
  });
}

/// A bridge that only generates: two words, as events and as the result
/// (or a model failure); nothing else is asked of it here.
class _Generating implements TavernScriptBridge {
  TavernScriptGenerateRequest? asked;
  TavernScriptRawRequest? raw;
  bool fail = false;

  TavernScriptGeneration _run(TavernScriptGenerateRequest request) {
    final id = request.generationId ?? 'g';
    const origin = TavernScriptGenerationOrigin(contextId: 'ctx', instanceId: 'frame', provider: 'test', model: 'test');
    return _Handle(
      id,
      Stream.fromIterable([
        TavernScriptGenerationEvent(
          id: id,
          seq: 1,
          kind: TavernScriptGenerationEventKind.started,
          status: TavernScriptGenerationStatus.running,
        ),
        for (final (i, word) in ['你', '好'].indexed)
          TavernScriptGenerationEvent(
            id: id,
            seq: 2 + i,
            kind: TavernScriptGenerationEventKind.textDelta,
            status: TavernScriptGenerationStatus.running,
            delta: word,
          ),
      ]),
      fail
          // Failing later, as a model does: by then the wire is waiting for it.
          ? Future.delayed(
              const Duration(milliseconds: 5),
              () => throw TavernScriptException(
                code: TavernScriptErrorCode.model,
                operation: 'generate',
                message: 'boom',
              ),
            )
          : Future.delayed(
              const Duration(milliseconds: 5),
              () => TavernScriptGenerationResult(id: id, text: '你好', origin: origin, finishReason: 'stop'),
            ),
    );
  }

  @override
  Future<TavernScriptGeneration> generate(String contextId, TavernScriptGenerateRequest request) async =>
      _run(asked = request);

  @override
  Future<TavernScriptGeneration> generateRaw(String contextId, TavernScriptRawRequest request) async =>
      _run(raw = request);

  @override
  bool stopGenerationById(String generationId) => generationId == 'g1';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Handle implements TavernScriptGeneration {
  _Handle(this.id, this.events, this.result);

  @override
  final String id;
  @override
  final Stream<TavernScriptGenerationEvent> events;
  @override
  final Future<TavernScriptGenerationResult> result;
}
