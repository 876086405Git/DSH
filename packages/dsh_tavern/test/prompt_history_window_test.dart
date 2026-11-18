import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'p2_script_test_support.dart' show ScriptHost;
import 'support/stage1_engine_harness.dart';
import 'support/t24_engine_harness.dart';

// Real imports, store, macros and assembler. The callback counter deliberately
// retains the complete-history path with exactly the same token convention.
void main() {
  test('cache trimming keeps an admitted boundary across sends and resets on a branch', () async {
    final h = await _Harness.open();
    await h.importHistory(_history(160));
    await h.send('first question');
    final first = h.engine.inspect(h.chat)!.prompt.historyWindow!;
    await h.send('next');
    expect(h.engine.inspect(h.chat)!.prompt.historyWindow!.firstNodeId, first.firstNodeId);
    await h.send('next again');
    expect(h.engine.inspect(h.chat)!.prompt.historyWindow!.firstNodeId, first.firstNodeId);

    final path = await h.engine.path(h.chat, limit: 1000);
    await h.engine.selectNode(h.chat, path[2].nodeId);
    await h.send('a separate branch');
    expect(h.engine.inspect(h.chat)!.prompt.historyWindow, isNull);
    expect(_text(h.model.allCalls.last.body!), contains('TRUE ROOT'));
  });

  test('explicitly disabling cache trimming restores the ordinary larger history window', () async {
    final h = await _Harness.open();
    await h.importHistory(_history(160));
    await h.send('first question');
    final first = h.engine.inspect(h.chat)!.prompt.historyWindow!;
    final original = await h.engine.path(h.chat, limit: 1000);
    final boundary = original.indexWhere((node) => node.nodeId == first.firstNodeId);
    await h.engine.setSettings({'cacheFriendlyTrimming': false}, chatId: h.chat);
    await h.send('next');
    final assembly = h.engine.inspect(h.chat)!.prompt;
    expect(assembly.historyWindow, isNull);
    final sentIds = {
      for (final segment in assembly.beforePostProcessing)
        for (final source in segment.sources)
          if (source.kind == 'history') source.id,
    };
    expect(original.take(boundary).any((node) => sentIds.contains(node.nodeId)), isTrue);
  });

  test('a preset updated during a held hook invalidates the old captured budget window', () async {
    final h = await _Harness.open();
    await h.importHistory(_history(160));
    final selected = await h.engine.importPreset(jsonEncode(h.engine.settings()['preset']));
    await h.engine.bindPreset(h.chat, selected.preset.id);
    await h.engine.scripts.openContext(
      TavernScriptContextSpec(instanceId: 'window-preset-change', chatId: h.chat, characterId: h.characterId),
    );
    final entered = Completer<void>();
    final release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    final host = ScriptHost();
    host.onDispatch = (request, cancellation) async {
      if (request.name == 'GENERATION_AFTER_COMMANDS' && !entered.isCompleted) {
        entered.complete();
        await release.future;
      }
      return TavernScriptDispatchAck(eventId: request.eventId);
    };
    h.engine.scripts.attachHost(host);
    final call = h.model.prepare();
    final events = T24Events(h.engine.send(h.chat, 'captured small budget'));
    await Future.any<void>([
      entered.future,
      events.done.future.then<void>((_) => throw StateError('Turn ended before its held preparation hook.')),
    ]);
    await h.engine.updatePreset(selected.preset.id, {'openai_max_context': 20000});
    release.complete();
    await call.listening.future;
    call.add(const ModelText('The reply.'));
    await call.finish();
    await events.done.future;
    expect(events.values.whereType<TavernTurnFailed>(), isEmpty);
    expect(h.engine.inspect(h.chat)!.prompt.budget, 576);
    expect(h.engine.inspect(h.chat)!.prompt.historyWindow, isNotNull);
    await h.send('use the newly expanded budget');
    expect(h.engine.inspect(h.chat)!.prompt.historyWindow, isNull);
    expect(_text(h.model.allCalls.last.body!), contains('TRUE ROOT'));
  });

  test('plain prompt and WI windows preserve the request, exclusions and full-history effects', () async {
    final embedded = {
      'entries': [
        {
          'id': 0,
          'keys': <String>[],
          'content': 'EMBEDDED DETAIL',
          'enabled': true,
          'constant': true,
          'insertion_order': 100,
          'extensions': {'position': 0},
        },
      ],
    };
    final fast = await _Harness.open(book: embedded);
    final complete = await _Harness.open(counter: _fullCounter(), book: embedded);
    final messages = _history(160);
    for (final h in [fast, complete]) {
      await h.engine.setSettings({
        'authorNote': {'enabled': true, 'interval': 81, 'content': 'GLOBAL NOTE', 'depth': 1},
        'worldInfo': {'world_info_recursive': true},
      });
      await h.engine.putLorebook('scan', {
        'entries': {
          '0': {
            'uid': 0,
            'key': ['new question'],
            'content': 'NEAR DETAIL',
            'position': 0,
            'scanDepth': 1,
            'sticky': 2,
            'useProbability': false,
          },
          '1': {
            'uid': 1,
            'key': ['History 100:'],
            'content': '@@scan_depth 70\nOLDER DETAIL recursive-key',
            'position': 0,
            'scanDepth': 1,
            'useProbability': false,
          },
          '2': {
            'uid': 2,
            'key': ['recursive-key'],
            'content': 'RECURSIVE DETAIL',
            'position': 0,
            'scanDepth': 1,
            'useProbability': false,
          },
          '3': {
            'uid': 3,
            'key': <String>[],
            'constant': true,
            'content': '@@reverse_depth 2\n@@ignore_on_max_context\nDEEP NOT SENT',
            'position': 0,
            'sticky': 10,
            'useProbability': false,
          },
        },
      });
      await h.engine.bindLorebooks(['scan']);
      await h.importHistory(messages);
      await h.send('The new question.');
    }
    expect(fast.model.allCalls.single.body, complete.model.allCalls.single.body);
    expect(_text(fast.model.allCalls.single.body!), contains('GLOBAL NOTE'));
    expect(_text(fast.model.allCalls.single.body!), contains('History 159:'));
    expect(_text(fast.model.allCalls.single.body!), isNot(contains('History 0:')));
    for (final detail in ['EMBEDDED DETAIL', 'NEAR DETAIL', 'OLDER DETAIL', 'RECURSIVE DETAIL']) {
      expect(_text(fast.model.allCalls.single.body!), contains(detail));
    }
    expect(_text(fast.model.allCalls.single.body!), isNot(contains('DEEP NOT SENT')));
    final fastInspection = (await fast.engine.inspectTurn(fast.chat))!;
    final completeInspection = (await complete.engine.inspectTurn(complete.chat))!;
    expect(_historyAndWorldExclusions(fastInspection), _historyAndWorldExclusions(completeInspection));
    expect(
      fastInspection.prompt!.excluded.any(
        (item) =>
            item.reason == 'v3-ignore-on-max-context' &&
            item.sources.any(
              (source) =>
                  source.kind == 'worldInfo' && source.details['bookId'] == 'scan' && source.details['uid'] == '3',
            ),
      ),
      isTrue,
    );
    final fastWorld = fast.engine.inspect(fast.chat)!.worldInfo;
    final completeWorld = complete.engine.inspect(complete.chat)!.worldInfo;
    expect(
      fastWorld.activated.map((hit) => (hit.uid, hit.content, hit.reason, hit.phase, hit.depth)),
      completeWorld.activated.map((hit) => (hit.uid, hit.content, hit.reason, hit.phase, hit.depth)),
    );
    expect(fastWorld.scanRounds, completeWorld.scanRounds);
    expect(fastWorld.scanRounds, greaterThan(1));
    expect(fastWorld.activated.any((hit) => hit.bookId == 'scan' && hit.uid == '3'), isFalse);
    expect(fastWorld.timedWorldInfo, completeWorld.timedWorldInfo);
    final sticky = fastWorld.timedWorldInfo['sticky']! as Map<String, Object?>;
    // 161 imported nodes, two ST-system nodes excluded, then the new user.
    expect((sticky.values.single! as Map<String, Object?>)['start'], 160);
    final saved = await fast.engine.path(fast.chat, limit: 1000);
    expect(saved.first.text, 'TRUE ROOT');
    expect(saved, hasLength(163));

    // Unbinding a book leaves its live timer on the branch. A shorter prompt
    // window must not look like a rewind and erase that remembered duration.
    for (final h in [fast, complete]) {
      await h.engine.putLorebook('timed', {
        'entries': {
          '0': {
            'uid': 0,
            'key': <String>[],
            'constant': true,
            'content': 'A timed detail.',
            'position': 0,
            'sticky': 20,
            'useProbability': false,
          },
        },
      });
      await h.engine.bindLorebooks(['timed']);
      await h.send('activate the timed detail');
      final timers = h.engine.inspect(h.chat)!.worldInfo.timedWorldInfo;
      expect(timers['sticky'], isNotEmpty);
      await h.engine.bindLorebooks([]);
      await h.send('after unbinding');
      expect(h.engine.inspect(h.chat)!.worldInfo.timedWorldInfo, timers);
    }
  });

  test('a scan window preserves separators after empty boundary messages', () async {
    final fast = await _Harness.open();
    final complete = await _Harness.open(counter: _fullCounter());
    for (final h in [fast, complete]) {
      await h.engine.setSettings({
        'worldInfo': {'world_info_depth': 2, 'world_info_include_names': false},
      });
      await h.engine.putLorebook('empty-boundary', {
        'entries': {
          '0': {
            'uid': 0,
            'key': [r'/\n\x01/'],
            'content': 'EMPTY BOUNDARY MATCH',
            'position': 0,
            'useProbability': false,
          },
        },
      });
      await h.engine.bindLorebooks(['empty-boundary']);
      await h.importHistory([..._history(160), _message(''), _message('')]);
      await h.send('');
    }
    expect(fast.model.allCalls.single.body, complete.model.allCalls.single.body);
    expect(_text(fast.model.allCalls.single.body!), contains('EMPTY BOUNDARY MATCH'));
    expect(fast.engine.inspect(fast.chat)!.worldInfo.regexDiagnostics, isEmpty);
  });

  test('loaded WI macros and capture replacements retain complete history without replay', () async {
    final fast = await _Harness.open();
    final complete = await _Harness.open(counter: _fullCounter());
    for (final h in [fast, complete]) {
      await h.engine.putLorebook('dynamic-book', {
        'entries': {
          '0': {
            'uid': 0,
            'key': <String>[],
            'constant': true,
            'content': 'BOOK LAST={{lastMessageId}} STEP={{incvar::bookReads}}',
            'position': 0,
            'useProbability': false,
          },
        },
      });
      await h.engine.bindLorebooks(['dynamic-book']);
      await h.importHistory(
        _history(160),
        metadata: {
          'variables': {'bookReads': 0},
        },
      );
      await h.send('The new question.');
      expect(h.engine.variables(h.chat)['bookReads'], 1);

      // No raw value contains a double brace. The WI capture replacement
      // creates the macro, so raw-string eligibility cannot decide this path.
      await h.engine.putLorebook('dynamic-book', {
        'entries': {
          '0': {
            'uid': 0,
            'key': <String>[],
            'constant': true,
            'content': 'CAPTURED LAST={lastMessageId}',
            'position': 0,
            'useProbability': false,
          },
        },
      });
      await h.engine.setSettings({
        'globalRegexScripts': [
          {
            'id': 'wi-capture',
            'scriptName': 'WI capture',
            'findRegex': '([{]lastMessageId[}])',
            'replaceString': r'{$1}',
            'placement': [5],
            'disabled': false,
            'markdownOnly': false,
            'promptOnly': true,
          },
        ],
      });
      await h.send('The next question.');
    }
    expect(fast.model.allCalls.map((call) => call.body), complete.model.allCalls.map((call) => call.body));
    expect(_text(fast.model.allCalls.first.body!), contains('BOOK LAST=161 STEP=1'));
    expect(_text(fast.model.allCalls.last.body!), contains('CAPTURED LAST=163'));
  });

  test('shrinking prompt regex and history macros keep the complete history and execute the real root once', () async {
    final h = await _Harness.open(main: 'LAST={{lastMessageId}}');
    await h.engine.setSettings({
      'globalRegexScripts': [
        {
          'id': 'short-history',
          'scriptName': 'short-history',
          'findRegex': r'^History (\d+): [\s\S]*$',
          'replaceString': r'm$1',
          'placement': [2],
          'disabled': false,
          'markdownOnly': false,
          'promptOnly': true,
        },
      ],
    });
    await h.importHistory(
      [
        _message('GREETING={{incvar::rootExpansions}}'),
        for (var i = 0; i < 40; i++) _message('History $i: ${'ordinary words '.padRight(600, 'x')}'),
      ],
      metadata: {
        'variables': {'rootExpansions': 0},
      },
    );
    await h.send('question');
    final text = _text(h.model.allCalls.single.body!);
    expect(text, contains('LAST=41'));
    expect(text, contains('m0'));
    expect(text, contains('m39'));
    expect((await h.engine.path(h.chat, limit: 1000)).first.text, 'GREETING=1');
    expect(h.engine.variables(h.chat)['rootExpansions'], 1);
  });

  test('remembered facts can match older history beyond the plain prompt budget window', () async {
    final h = await Stage1Harness.open(state: false);
    await h.enableMemory(mode: 'auto');
    final source = await h.start(input: 'faraway-signal');
    await stage1Finish(
      source.call,
      tools: [
        Stage1Call(0, 'memory', 'remember', {
          'text': 'MEMORY FROM EARLIER',
          'keywords': ['faraway-signal'],
        }),
      ],
    );
    await source.events.done.future;
    expect((await h.turn(source.events)).proposals.single.workflow, 'accepted');
    await h.engine.setPreset(ChatPreset({...t24Preset().raw, 'openai_max_context': 640, 'openai_max_tokens': 64}));
    await h.engine.setSettings({
      'worldInfo': {'world_info_depth': 100},
    });
    for (var i = 0; i < 40; i++) {
      await h.engine.sendOnly(h.chatId, 'ordinary filler $i '.padRight(120, 'x'));
    }
    final active = await h.start(input: 'The current question.');
    expect(jsonEncode(active.call.body), contains('MEMORY FROM EARLIER'));
    await stage1Finish(active.call, content: 'The reply.');
    await active.events.done.future;
    expect(active.events.values.whereType<TavernTurnFailed>(), isEmpty);
  });

  test('a failed inactive regeneration restores remembered edges before the prompt window', () async {
    final h = await _Harness.open();
    await h.importHistory(_history(160));
    final old = await h.engine.path(h.chat, limit: 1000);
    await h.engine.selectNode(h.chat, old.first.nodeId);
    final other = await h.send('another branch');
    await h.engine.selectNode(h.chat, old[10].nodeId);
    await h.engine.selectNode(h.chat, other.nodeId);
    final active = (await h.engine.path(h.chat)).map((node) => node.nodeId).toList();
    final remembered = h.selections();
    expect(remembered[old[10].nodeId], isNull);

    final call = h.model.prepare();
    final events = T24Events(h.engine.regenerate(h.chat, old.last.nodeId));
    await call.listening.future;
    call.fail(TavernFailure.network, 'connection ended before output');
    await events.done.future;
    expect(events.values.whereType<TavernTurnFailed>(), hasLength(1));
    expect((await h.engine.path(h.chat)).map((node) => node.nodeId), active);
    final restored = h.selections();
    expect({for (final id in remembered.keys) id: restored[id]}, remembered);
  });
}

List<Map<String, Object?>> _history(int count) => [
  _message('TRUE ROOT'),
  for (var i = 0; i < count; i++)
    _message(
      'History $i: The visitor crossed the room.\r\nThe rain continued outside.',
      user: i.isEven,
      system: i == 17 || i == 157,
    ),
];

PromptTokenCounter _fullCounter() {
  const estimate = EstimatedTokenCounter();
  return CallbackTokenCounter(
    name: estimate.name,
    exact: estimate.exact,
    message: estimate.countMessage,
    text: estimate.countText,
  );
}

Map<String, Object?> _message(String text, {bool user = false, bool system = false}) => {
  'name': user ? 'User' : 'Guide',
  'is_user': user,
  'is_system': system,
  'send_date': T24Harness.at.toIso8601String(),
  'mes': text,
  'extra': <String, Object?>{},
};

String _text(Map<String, Object?> body) => (body['messages']! as List<Object?>)
    .cast<Map<String, Object?>>()
    .map((message) => message['content'] ?? '')
    .join('\n');

List<(String, String, String)> _historyAndWorldExclusions(TavernTurnInspection inspection) => [
  for (final exclusion in inspection.prompt!.excluded)
    for (final source in exclusion.sources)
      if (source.kind == 'history' || source.kind == 'worldInfo')
        (exclusion.reason, source.kind, source.kind == 'history' ? source.label : source.details['uid']! as String),
];

class _Harness {
  _Harness(this.root, this.model, this.engine, this.characterId);

  static Future<_Harness> open({
    PromptTokenCounter counter = const EstimatedTokenCounter(),
    String main = '',
    Map<String, Object?>? book,
  }) async {
    final root = await Directory.systemTemp.createTemp('dsh-prompt-window-');
    final model = T24Model();
    final engine = await TavernEngine.openDirectory(
      root,
      counter: counter,
      config: TavernModelConfig(
        apiKey: () async => 'fixture-key',
        model: 'fixture-model',
        deepseek: true,
        thinking: true,
      ),
      modelClient: model,
      clock: () => T24Harness.at,
      random: () => 0.25,
    );
    addTearDown(() async {
      await engine.close();
      for (final call in model.allCalls) {
        await call.close();
      }
      await root.delete(recursive: true);
    });
    final preset = t24Preset().raw;
    final prompts = (preset['prompts']! as List<Object?>).cast<Map<String, Object?>>();
    prompts.firstWhere((prompt) => prompt['identifier'] == 'main')['content'] = main;
    await engine.setPreset(
      ChatPreset({...preset, 'openai_max_context': 640, 'openai_max_tokens': 64, 'names_behavior': 1}),
    );
    final card = jsonDecode(utf8.decode(t24Card())) as Map<String, Object?>;
    if (book != null) (card['data']! as Map<String, Object?>)['character_book'] = book;
    final character = await engine.importCard(Uint8List.fromList(utf8.encode(jsonEncode(card))));
    return _Harness(root, model, engine, character.id);
  }

  final Directory root;
  final T24Model model;
  final TavernEngine engine;
  final String characterId;
  late String chat;

  Future<void> importHistory(List<Map<String, Object?>> messages, {Map<String, Object?> metadata = const {}}) async {
    final document = StChatDocument(
      fileName: 'history.jsonl',
      header: {'user_name': 'User', 'character_name': 'Guide', 'chat_metadata': metadata},
      messages: messages,
    );
    chat = (await engine.importChats(characterId, [
      TavernChatFile(fileName: document.fileName, bytes: document.encode()),
    ])).chatIds.single;
  }

  Future<TavernMessage> send(String text) async {
    final call = model.prepare();
    final events = T24Events(engine.send(chat, text));
    await call.listening.future;
    call.add(const ModelText('The reply.'));
    await call.finish();
    await events.done.future;
    expect(events.values.whereType<TavernTurnFailed>(), isEmpty);
    return events.values.whereType<TavernTurnDone>().single.message;
  }

  Map<String, String?> selections() {
    final database = sqlite3.open('${root.path}/tavern.sqlite3');
    try {
      return {
        for (final row in database.select('SELECT id, selected_child_id FROM nodes WHERE chat_id = ?', [chat]))
          row['id'] as String: row['selected_child_id'] as String?,
      };
    } finally {
      database.close();
    }
  }
}
