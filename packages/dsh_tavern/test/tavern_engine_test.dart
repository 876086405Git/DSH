import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late TavernEngine engine;
  late _Transport transport;
  final now = DateTime.utc(2026, 11, 10, 12);

  Future<TavernEngine> open({TavernModelConfig? config}) => TavernEngine.open(
    directory,
    config: config ?? _config(),
    modelClient: transport.client,
    clock: () => now,
    random: () => 0.25,
  );
  Future<(String, String)> chat([Map<String, Object?> data = const {}]) async {
    final card = await engine.importCard(_card(data));
    return (card.id, await engine.createChat(card.id));
  }

  Future<void> verifyInactiveFailure({required bool continuation}) async {
    final (_, chatId) = await chat();
    final root1 = (await engine.path(chatId)).single;
    transport.reply('第二根');
    final root2 = _done(await engine.regenerate(chatId, root1.nodeId).toList());
    transport.reply('B1');
    final first = _done(await engine.send(chatId, 'U').toList());
    transport.reply('B3');
    final other = _done(await engine.regenerate(chatId, first.nodeId).toList());
    transport.reply('B3后代');
    final tail = _done(await engine.send(chatId, '后代用户').toList());
    await engine.selectSibling(chatId, other.nodeId, 0);
    await engine.selectSibling(chatId, root2.nodeId, 0);
    expect((await engine.path(chatId)).last.nodeId, root1.nodeId);
    engine.configure(_config(key: null));
    final failed =
        (await (continuation ? engine.continueReply(chatId, other.nodeId) : engine.regenerate(chatId, first.nodeId))
                .toList())
            .whereType<TavernTurnFailed>()
            .single;
    expect(failed.kind, TavernFailure.noKey);
    expect((await engine.path(chatId)).last.nodeId, root1.nodeId);
    await engine.selectSibling(chatId, root1.nodeId, 1);
    expect((await engine.path(chatId)).last.nodeId, first.nodeId);
    await engine.selectSibling(chatId, first.nodeId, 1);
    expect((await engine.path(chatId)).last.nodeId, tail.nodeId);
    expect((await engine.path(chatId)).firstWhere((message) => message.nodeId == other.nodeId).text, 'B3');
    await engine.selectSibling(chatId, other.nodeId, 0);
    await engine.selectSibling(chatId, root2.nodeId, 0);
    await engine.close();
    engine = await open();
    expect((await engine.path(chatId)).last.nodeId, root1.nodeId);
    await engine.selectSibling(chatId, root1.nodeId, 1);
    expect((await engine.path(chatId)).last.nodeId, first.nodeId);
    await engine.selectSibling(chatId, first.nodeId, 1);
    expect((await engine.path(chatId)).last.nodeId, tail.nodeId);
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('dsh-tavern-engine-');
    transport = _Transport();
    engine = await open();
  });
  tearDown(() async {
    await engine.close();
    transport.dispose();
    await directory.delete(recursive: true);
  });

  test('import, greeting, macros, card WI, streaming reasoning and usage, then reopen', () async {
    engine.configure(_config(thinking: true));
    await engine.setSettings({
      'userName': '访客',
      'worldInfo': {'world_info_budget': 50},
      'foreign': {'keep': '🐋'},
    });
    final (cardId, chatId) = await chat({
      'first_mes': '{{user}}，我是 {{char}}。',
      'character_book': {
        'name': '灯塔书',
        'entries': [
          {
            'id': 7,
            'keys': ['灯塔'],
            'content': '岛上只有一座灯塔。',
            'enabled': true,
            'insertion_order': 100,
            'position': 'before_char',
            'extensions': {},
          },
        ],
      },
    });
    expect((await engine.path(chatId)).single.text, '访客，我是 小鲸。');
    transport.reply(
      '你好🐋',
      reasoning: '想一想',
      usage: const {'prompt_tokens': 80, 'prompt_cache_hit_tokens': 60, 'completion_tokens': 8},
    );
    final events = await engine.send(chatId, '{{user}}来到灯塔').toList();
    expect(events.first, isA<TavernTurnStarted>());
    expect(events.whereType<TavernTurnStarted>(), hasLength(1));
    expect(events.whereType<TavernReasoningDelta>().map((e) => e.text).join(), '想一想');
    expect(events.whereType<TavernTextDelta>().map((e) => e.text).join(), '你好🐋');
    expect(events.whereType<TavernTurnFailed>(), isEmpty);
    final done = events.whereType<TavernTurnDone>().single.message;
    expect(done.text, '你好🐋');
    expect(done.reasoning, '想一想');
    expect(done.usage!.promptTokens, 80);
    expect(done.usage!.cacheHitTokens, 60);
    expect(done.usage!.completionTokens, 8);
    final path = await engine.path(chatId);
    expect(path.map((m) => m.text), ['访客，我是 小鲸。', '访客来到灯塔', '你好🐋']);
    expect(path.last.nodeId, done.nodeId);
    expect(transport.requests.single.uri.path, '/beta/chat/completions');
    expect(_requestText(transport.requests.single.body), contains('岛上只有一座灯塔。'));
    final inspection = engine.inspect(chatId)!;
    expect(inspection.worldInfo.activated.single.uid, '7');
    expect(inspection.toJson()['generationType'], 'normal');
    expect(inspection.prompt.body['thinking'], {'type': 'enabled'});
    expect((await engine.character(cardId))!.chatCount, 1);
    expect((await engine.watchChats().first).single.messageCount, 3);
    final exported = const CardCodec().decode(await engine.exportCard(cardId, format: TavernCardFormat.json));
    expect(exported.data['name'], '蓝鲸');
    await engine.close();
    engine = await open();
    expect((await engine.path(chatId)).map((m) => m.nodeId), path.map((m) => m.nodeId));
    expect((await engine.path(chatId)).last.usage!.cacheHitTokens, 60);
    expect(engine.settings()['foreign'], {'keep': '🐋'});
    expect(engine.inspect(chatId), isNull);
  });

  test('regenerate creates a sibling and selecting the old sibling restores its remembered descendants', () async {
    final (_, chatId) = await chat({'first_mes': '开场'});
    transport.reply('第一答');
    final first = _done(await engine.send(chatId, '{{incvar::n}} 第一问').toList());
    transport.reply('后续答');
    final tail = _done(await engine.send(chatId, '{{incvar::n}} 后续问').toList());
    expect(engine.variables(chatId)['n'], 2);
    transport.reply('第一答备选');
    final alternate = _done(await engine.regenerate(chatId, first.nodeId).toList());
    expect(alternate.parentId, first.parentId);
    expect(alternate.nodeId, isNot(first.nodeId));
    expect(alternate.siblingCount, 2);
    expect((await engine.path(chatId)).last.nodeId, alternate.nodeId);
    expect(engine.variables(chatId)['n'], 1);
    await engine.selectSibling(chatId, alternate.nodeId, 0);
    expect((await engine.path(chatId)).last.nodeId, tail.nodeId);
    expect(engine.variables(chatId)['n'], 2);
    await engine.selectSibling(chatId, first.nodeId, 1);
    expect((await engine.path(chatId)).last.nodeId, alternate.nodeId);
    expect(engine.variables(chatId)['n'], 1);
  });

  test('eager card fields re-expand greeting macros on each generation like ST', () async {
    final (_, chatId) = await chat({'first_mes': '{{setvar::n::0}}开场'});
    expect((await engine.path(chatId)).single.text, '开场');
    expect(engine.variables(chatId)['n'], '0');
    transport.reply('第一答');
    await engine.send(chatId, '{{incvar::n}} 第一问').drain<void>();
    expect((await engine.path(chatId))[1].text, '1 第一问');
    expect(engine.variables(chatId)['n'], '0');
    transport.reply('后续答');
    await engine.send(chatId, '{{incvar::n}} 后续问').drain<void>();
    expect((await engine.path(chatId))[3].text, '1 后续问');
    expect(engine.variables(chatId)['n'], '0');
  });

  test('editing, hidden history, empty send and subtree deletion use the real tree', () async {
    final (_, chatId) = await chat();
    final greeting = (await engine.path(chatId)).single;
    await engine.edit(chatId, greeting.nodeId, '**改写** <b>开场</b>');
    expect((await engine.watchChats().first).single.lastText, '改写 开场');
    await engine.setHidden(chatId, greeting.nodeId, true);
    transport.reply('下一句');
    await engine.send(chatId, '').drain<void>();
    expect(await engine.path(chatId), hasLength(2));
    expect(
      engine.inspect(chatId)!.prompt.excluded.any((item) => item.id == greeting.nodeId && item.reason == 'hidden'),
      true,
    );
    expect(_requestText(transport.requests.single.body), isNot(contains('改写')));
    await engine.deleteFrom(chatId, greeting.nodeId);
    expect(await engine.path(chatId), isEmpty);
    final empty = (await engine.watchChats().first).single;
    expect(empty.messageCount, 0);
    expect(empty.lastText, isNull);
  });

  test('chat previews retain exact text across edits, branches and external writes', () async {
    final (characterId, chatId) = await chat();
    final root = (await engine.path(chatId)).single;
    final raw =
        '<script>${'s' * 32768}</script><style>${'c' * 32768}</style>'
        '<p>**alpha** &amp;lt;literal&amp;gt; &lt;tag&gt; &amp; tail</p>';
    const tail = '&lt;literal&gt; <tag> & tail';
    Future<TavernChatSummary> preview() async => (await engine.watchChats(characterId: characterId).first).single;
    await engine.edit(chatId, root.nodeId, raw);
    expect((await preview()).lastText, 'alpha $tail');
    expect((await preview()).lastText, 'alpha $tail');
    final edited = raw.replaceFirst('alpha', 'bravo');
    expect(edited.length, raw.length);
    await engine.edit(chatId, root.nodeId, edited);
    expect((await preview()).lastText, 'bravo $tail');

    transport.reply(raw.replaceFirst('alpha', 'delta'));
    final alternate = _done(await engine.regenerate(chatId, root.nodeId).toList());
    expect((await preview()).lastText, 'delta $tail');
    await engine.selectSibling(chatId, alternate.nodeId, 0);
    expect((await preview()).lastText, 'bravo $tail');
    await engine.selectSibling(chatId, root.nodeId, 1);
    expect((await preview()).lastText, 'delta $tail');

    final writer = ChatStore.open('${directory.path}/tavern/tavern.sqlite3');
    try {
      writer.updateChat(chatId, title: 'External title');
      final renamed = await preview();
      expect(renamed.title, 'External title');
      expect(renamed.lastText, 'delta $tail');
      expect(renamed.messageCount, 1);
      writer.updateMessage(chatId, alternate.nodeId, text: raw.replaceFirst('alpha', 'cider'));
      expect((await preview()).lastText, 'cider $tail');
      writer.updateMessage(chatId, alternate.nodeId, text: '');
      expect((await preview()).lastText, '');
    } finally {
      await writer.close();
    }
  });

  test('continue writes the same node; postfix is local and ordinary trailing spaces suppress it', () async {
    final (_, chatId) = await chat();
    await engine.setPreset(_preset({'continue_prefill': true, 'continue_postfix': '~'}), chatId: chatId);
    transport.reply('原文');
    final first = _done(await engine.send(chatId, '问').toList());
    await engine.edit(chatId, first.nodeId, '尾巴\n');
    transport.reply('续文');
    final events = await engine.continueReply(chatId, first.nodeId).toList();
    final continued = _done(events);
    expect(continued.nodeId, first.nodeId);
    expect(continued.text, '尾巴\n~续文');
    expect(events.whereType<TavernTextDelta>().single.text, '~续文');
    final lastRequest = _messages(transport.requests.last.body).last;
    expect(lastRequest['role'], 'assistant');
    expect(lastRequest['prefix'], true);
    expect(lastRequest['content'], '尾巴\n');
    expect(await engine.path(chatId), hasLength(3));
    await engine.edit(chatId, first.nodeId, '已有空格 ');
    transport.reply('继续');
    expect(_done(await engine.continueReply(chatId, first.nodeId).toList()).text, '已有空格 继续');
  });

  test('continue on an earlier node keeps descendants and a no-output failure restores the original leaf', () async {
    final (_, chatId) = await chat();
    transport.reply('答一');
    final first = _done(await engine.send(chatId, '一').toList());
    transport.reply('答二');
    final second = _done(await engine.send(chatId, '二').toList());
    engine.configure(_config(key: null));
    final failed = (await engine.continueReply(chatId, first.nodeId).toList()).whereType<TavernTurnFailed>().single;
    expect(failed.kind, TavernFailure.noKey);
    expect(failed.partial!.text, '答一');
    expect((await engine.path(chatId)).last.nodeId, second.nodeId);
    expect(await engine.path(chatId), hasLength(5));
  });

  test('impersonation produces a temporary user message without storing it', () async {
    final (_, chatId) = await chat();
    final before = await engine.path(chatId);
    transport.reply('替我写的输入');
    final events = await engine.impersonate(chatId).toList();
    expect(events.whereType<TavernTurnStarted>().single.message.role, TavernRole.user);
    final message = _done(events);
    expect(message.role, TavernRole.user);
    expect(message.speaker, 'User');
    expect(message.text, '替我写的输入');
    expect((await engine.path(chatId)).map((m) => m.nodeId), before.map((m) => m.nodeId));
    expect(engine.inspect(chatId)!.generationType, 'impersonate');
    expect(_requestText(transport.requests.single.body), contains('from the point of view of User'));
  });

  test('missing key removes both new nodes, returns partial=null and performs no HTTP', () async {
    final (_, chatId) = await chat();
    final original = (await engine.path(chatId)).single;
    engine.configure(_config(key: null));
    final events = await engine.send(chatId, '回到输入框').toList();
    expect(events.whereType<TavernTurnStarted>(), hasLength(1));
    final failed = events.whereType<TavernTurnFailed>().single;
    expect(failed.kind, TavernFailure.noKey);
    expect(failed.partial, isNull);
    expect(events.whereType<TavernTurnDone>(), isEmpty);
    expect((await engine.path(chatId)).single.nodeId, original.nodeId);
    expect(transport.requests, isEmpty);
    await engine.send(chatId, '').drain<void>();
    expect((await engine.path(chatId)).single.nodeId, original.nodeId);
  });

  test('partial transport failure preserves text, reasoning, usage and user input', () async {
    engine.configure(_config(thinking: true));
    final (_, chatId) = await chat();
    final pending = transport.pending();
    final collected = engine.send(chatId, '问').toList();
    await pending.connected.future;
    pending.event({
      'choices': [
        {
          'index': 0,
          'delta': {'reasoning_content': '想', 'content': '半句'},
        },
      ],
    });
    pending.event({
      'choices': [],
      'usage': {'prompt_tokens': 11, 'prompt_cache_hit_tokens': 9, 'completion_tokens': 2},
    });
    pending.error(const SocketException('test connection ended'));
    final events = await collected;
    final failed = events.whereType<TavernTurnFailed>().single;
    expect(failed.kind, TavernFailure.network);
    expect(failed.partial!.text, '半句');
    expect(failed.partial!.reasoning, '想');
    expect(failed.partial!.usage!.cacheHitTokens, 9);
    expect((await engine.path(chatId)).last.text, '半句');
    expect(await engine.path(chatId), hasLength(3));
    expect(events.whereType<TavernTurnDone>(), isEmpty);
  });

  test('stop while obtaining a key completes promptly and does not store an empty turn', () async {
    final (_, chatId) = await chat();
    final key = Completer<String?>();
    final keyEntered = Completer<void>();
    engine.configure(
      TavernModelConfig(
        apiKey: () {
          keyEntered.complete();
          return key.future;
        },
      ),
    );
    final started = Completer<void>();
    final future = engine.send(chatId, '尚未发出').map((event) {
      if (event is TavernTurnStarted) started.complete();
      return event;
    }).toList();
    await started.future;
    await keyEntered.future.timeout(const Duration(seconds: 3));
    engine.stop(chatId);
    final events = await future.timeout(const Duration(seconds: 3));
    final failed = events.whereType<TavernTurnFailed>().single;
    expect(failed.kind, TavernFailure.cancelled);
    expect(failed.partial, isNull);
    expect(await engine.path(chatId), hasLength(1));
    expect(transport.requests, isEmpty);
    key.complete('unused-test-value');
  });

  test('stop keeps accumulated content and permits a later turn', () async {
    final (_, chatId) = await chat();
    final pending = transport.pending();
    final received = Completer<void>();
    final future = engine.send(chatId, '问').map((event) {
      if (event is TavernTextDelta && !received.isCompleted) received.complete();
      return event;
    }).toList();
    await pending.connected.future;
    pending.text('保留');
    await received.future;
    engine.stop(chatId);
    final failed = (await future.timeout(const Duration(seconds: 3))).whereType<TavernTurnFailed>().single;
    expect(failed.kind, TavernFailure.cancelled);
    expect(failed.partial!.text, '保留');
    expect((await engine.path(chatId)).last.text, '保留');
    transport.reply('新回合');
    expect(_done(await engine.send(chatId, '再问').toList()).text, '新回合');
  });

  test('consumer cancellation has no close cycle and retains already received output', () async {
    final (_, chatId) = await chat();
    final pending = transport.pending(ignoreAbort: true);
    final received = Completer<void>();
    late String nodeId;
    final subscription = engine.send(chatId, '问').listen((event) {
      if (event is TavernTurnStarted) nodeId = event.message.nodeId;
      if (event is TavernTextDelta && !received.isCompleted) received.complete();
    });
    await pending.connected.future;
    pending.text('部分');
    await received.future;
    await subscription.cancel().timeout(const Duration(seconds: 3));
    // T24 detaches the observer; this explicit mutation now cancels the
    // still-active turn and waits for its final flush.
    await engine.setHidden(chatId, nodeId, false).timeout(const Duration(seconds: 3));
    pending.text('迟来的数据');
    expect((await engine.path(chatId)).last.text, '部分');
  });

  test('a second turn is busy and a concurrent edit waits for cancellation before writing', () async {
    final (_, chatId) = await chat();
    final pending = transport.pending(ignoreAbort: true);
    final received = Completer<void>();
    late String nodeId;
    final running = engine.send(chatId, '问').map((event) {
      if (event is TavernTurnStarted) nodeId = event.message.nodeId;
      if (event is TavernTextDelta && !received.isCompleted) received.complete();
      return event;
    }).toList();
    await pending.connected.future;
    final second = await engine.send(chatId, '不可进入').toList();
    expect(second.single, isA<TavernTurnFailed>().having((e) => e.kind, 'kind', TavernFailure.busy));
    expect(transport.requests, hasLength(1));
    pending.text('半句');
    await received.future;
    final editing = engine.edit(chatId, nodeId, '手工修改');
    final duringMutation = await engine.send(chatId, '也不可进入').toList();
    expect(duringMutation.single, isA<TavernTurnFailed>().having((e) => e.kind, 'kind', TavernFailure.busy));
    await editing.timeout(const Duration(seconds: 3));
    pending.text('不得写回');
    await Future<void>.delayed(Duration.zero);
    expect((await engine.path(chatId)).last.text, '手工修改');
    expect((await running).whereType<TavernTurnFailed>().single.kind, TavernFailure.cancelled);
  });

  test('deleting an active chat cannot be undone by a late chunk', () async {
    final (_, chatId) = await chat();
    final pending = transport.pending(ignoreAbort: true);
    final received = Completer<void>();
    final running = engine.send(chatId, '问').map((event) {
      if (event is TavernTextDelta && !received.isCompleted) received.complete();
      return event;
    }).toList();
    await pending.connected.future;
    pending.text('将被删');
    await received.future;
    await engine.deleteChat(chatId).timeout(const Duration(seconds: 3));
    pending.text('迟到');
    await running;
    expect(await engine.watchChats().first, isEmpty);
    await expectLater(engine.path(chatId), throwsStateError);
  });

  test('close finishes even when an external turn listener is paused', () async {
    final (_, chatId) = await chat();
    final pending = transport.pending(ignoreAbort: true);
    final started = Completer<void>();
    final ended = Completer<void>();
    final events = <TavernEvent>[];
    final subscription = engine.send(chatId, '问').listen((event) {
      events.add(event);
      if (event is TavernTurnStarted) started.complete();
    }, onDone: ended.complete);
    await started.future;
    await pending.connected.future;
    subscription.pause();
    await engine.close().timeout(const Duration(seconds: 3));
    subscription.resume();
    await ended.future.timeout(const Duration(seconds: 3));
    expect(events.whereType<TavernTurnFailed>().single.kind, TavernFailure.cancelled);
    expect(() => engine.path(chatId), throwsStateError);
  });

  test('initial watches include stored data and do not lose an import during the first asynchronous load', () async {
    final lists = <List<TavernCharacter>>[];
    final importedVisible = Completer<void>();
    final subscription = engine.watchCharacters().listen((list) {
      lists.add(list);
      if (list.isNotEmpty && !importedVisible.isCompleted) importedVisible.complete();
    });
    final (characterId, chatId) = await chat();
    await importedVisible.future.timeout(const Duration(seconds: 3));
    expect(lists.last.single.id, characterId);
    expect((await engine.watchCharacters().first).single.chatCount, 1);
    expect((await engine.watchChats(characterId: characterId).first).single.id, chatId);
    expect(await engine.watchChats(characterId: 'another-character').first, isEmpty);
    await subscription.cancel();
    final firstSnapshot = Completer<void>();
    final paused = engine.watchCharacters().listen((_) {
      if (!firstSnapshot.isCompleted) firstSnapshot.complete();
    });
    await firstSnapshot.future;
    paused.pause();
    await engine.close().timeout(const Duration(seconds: 3));
    paused.resume();
    await paused.cancel();
  });

  test('deleting a character cancels all its chats while retaining another character', () async {
    final (cardId, firstId) = await chat();
    final secondId = await engine.createChat(cardId);
    final other = await engine.importCard(_card({'name': '其他角色'}));
    final first = transport.pending(ignoreAbort: true);
    final second = transport.pending(ignoreAbort: true);
    final running1 = engine.send(firstId, '一').toList();
    final running2 = engine.send(secondId, '二').toList();
    await Future.wait([first.connected.future, second.connected.future]);
    await engine.deleteCharacter(cardId).timeout(const Duration(seconds: 3));
    first.text('迟到一');
    second.text('迟到二');
    expect((await running1).whereType<TavernTurnFailed>().single.kind, TavernFailure.cancelled);
    expect((await running2).whereType<TavernTurnFailed>().single.kind, TavernFailure.cancelled);
    expect(await engine.character(cardId), isNull);
    expect(await engine.watchChats().first, isEmpty);
    expect((await engine.watchCharacters().first).single.id, other.id);
  });

  test('configure applies to the next turn while the active request keeps its config snapshot', () async {
    final (_, chatId) = await chat();
    final key = Completer<String?>();
    engine.configure(TavernModelConfig(apiKey: () => key.future, model: 'old-model', thinking: true));
    transport.reply('旧配置');
    final started = Completer<void>();
    final running = engine.send(chatId, '问').map((event) {
      if (event is TavernTurnStarted) started.complete();
      return event;
    }).toList();
    await started.future;
    engine.configure(_config(deepseek: false, model: 'new-model'));
    key.complete('fake-test-value');
    expect(_done(await running).text, '旧配置');
    expect(transport.requests.single.body['model'], 'old-model');
    expect(transport.requests.single.body['thinking'], {'type': 'enabled'});
    expect(transport.requests.single.uri.path, '/beta/chat/completions');
    transport.reply('新配置');
    await engine.send(chatId, '再问').drain<void>();
    expect(transport.requests.last.body['model'], 'new-model');
    expect(transport.requests.last.body.containsKey('thinking'), false);
    expect(transport.requests.last.uri.path, '/v1/chat/completions');
  });

  test('prepared card fields precede WI and ordinary macro getters reevaluate raw fields once per expansion', () async {
    final (_, chatId) = await chat({'personality': '{{incvar::x}}'});
    await engine.setPreset(_preset({'personality_format': 'P={{personality}}/{{personality}}'}), chatId: chatId);
    transport.reply('答');
    await engine.send(chatId, '问').drain<void>();
    expect(engine.variables(chatId)['x'], 2);
    expect(_requestText(transport.requests.single.body), contains('P=2/2'));
    final first = engine.inspect(chatId)!.toJson();
    expect(engine.inspect(chatId)!.toJson(), first);
    expect(engine.variables(chatId)['x'], 2);
  });

  test(
    'global macros, unknown settings, bound books, author notes and outlets persist and enter the request',
    () async {
      final (_, chatId) = await chat();
      await engine.setSettings({
        'persona': '读者的人设',
        'foreign': {
          'zero': 0,
          'nested': {'a': 1},
        },
        'authorNote': {'content': '原作者注释', 'depth': 0, 'role': 'system'},
        'injections': [
          {'id': 'outlet-reader', 'content': '出口={{outlet::road}}', 'depth': 1},
        ],
      });
      await engine.setSettings({
        'foreign': {
          'nested': {'b': 2},
        },
      });
      await engine.putLorebook('custom-book', {
        'name': '外置世界书',
        'unknown': {'keep': true},
        'entries': {
          '0': {'uid': 0, 'constant': true, 'content': '注释前', 'position': 2, 'order': 100},
          '1': {'uid': 1, 'constant': true, 'content': '注释后', 'position': 3, 'order': 100},
          '2': {'uid': 2, 'constant': true, 'content': '深度条目', 'position': 4, 'depth': 0, 'role': 1, 'order': 100},
          '3': {'uid': 3, 'constant': true, 'content': '岔路', 'position': 7, 'outletName': 'road', 'order': 100},
        },
      });
      await engine.bindLorebooks(['custom-book']);
      transport.reply('答');
      await engine.send(chatId, '{{setglobalvar::flag::保存}}问').drain<void>();
      final content = _requestText(transport.requests.single.body);
      expect(content, contains('读者的人设'));
      expect(content, contains('注释前\n原作者注释\n注释后'));
      expect(content, contains('深度条目'));
      expect(content, contains('出口=岔路'));
      expect(engine.inspect(chatId)!.worldInfo.activated.map((hit) => hit.bookId).toSet(), {'custom-book'});
      expect(engine.globalVariables['flag'], '保存');
      await engine.close();
      engine = await open();
      expect(engine.globalVariables['flag'], '保存');
      expect(engine.settings()['foreign'], {
        'zero': 0,
        'nested': {'a': 1, 'b': 2},
      });
      expect((await engine.lorebook('custom-book'))!['unknown'], {'keep': true});
      expect(await File('${directory.path}/tavern/settings.json.writing').exists(), false);
      await expectLater(engine.putLorebook('../escape', {'entries': {}}), throwsArgumentError);
      expect(await File('${directory.path}/escape.json').exists(), false);
    },
  );

  test('streaming writes are batched and still notify the current path', () async {
    final (_, chatId) = await chat();
    var changes = 0;
    final subscription = engine.pathChanges(chatId).listen((_) {
      changes++;
    });
    transport.events([
      for (var i = 0; i < 128; i++)
        {
          'choices': [
            {
              'index': 0,
              'delta': {'content': 'x'},
            },
          ],
        },
    ]);
    final events = await engine.send(chatId, '问').toList();
    await Future<void>.delayed(Duration.zero);
    expect(_done(events).text, List.filled(128, 'x').join());
    expect(events.whereType<TavernTextDelta>(), hasLength(128));
    expect(changes, greaterThan(1));
    expect(changes, lessThan(64));
    await subscription.cancel();
  });

  test('a mandatory prompt overflow rolls back input before an empty reply is created', () async {
    final (_, chatId) = await chat();
    await engine.setPreset(_preset({'openai_max_context': 3, 'openai_max_tokens': 0}), chatId: chatId);
    final events = await engine.send(chatId, '不应留下').toList();
    expect(events.whereType<TavernTurnStarted>(), isEmpty);
    final failed = events.whereType<TavernTurnFailed>().single;
    expect(failed.kind, TavernFailure.contextTooLong);
    expect(failed.partial, isNull);
    expect(await engine.path(chatId), hasLength(1));
    expect(transport.requests, isEmpty);
  });

  test('failed regeneration restores an older branch with all of its descendants', () async {
    final (_, chatId) = await chat();
    transport.reply('一答');
    final first = _done(await engine.send(chatId, '一').toList());
    transport.reply('二答');
    final last = _done(await engine.send(chatId, '二').toList());
    engine.configure(_config(key: null));
    final failed = (await engine.regenerate(chatId, first.nodeId).toList()).whereType<TavernTurnFailed>().single;
    expect(failed.partial, isNull);
    final path = await engine.path(chatId);
    expect(path.last.nodeId, last.nodeId);
    expect(path.firstWhere((node) => node.nodeId == first.nodeId).siblingCount, 1);
  });

  test('a generic non-streaming preset is used without changing its stream setting', () async {
    final (_, chatId) = await chat();
    engine.configure(_config(deepseek: false));
    await engine.setPreset(_preset({'stream_openai': false}), chatId: chatId);
    transport.plans.add(
      (_, _) async => http.StreamedResponse(
        Stream.value(
          utf8.encode(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': '一次返回', 'reasoning_content': '完整思考'},
                  'finish_reason': 'stop',
                },
              ],
              'usage': {
                'prompt_tokens': 9,
                'completion_tokens': 2,
                'prompt_tokens_details': {'cached_tokens': 4},
              },
            }),
          ),
        ),
        200,
      ),
    );
    final done = _done(await engine.send(chatId, '问').toList());
    expect(done.text, '一次返回');
    expect(done.reasoning, '完整思考');
    expect(done.usage!.cacheHitTokens, 4);
    expect(transport.requests.single.body['stream'], false);
  });

  test(
    'non-finite variable arithmetic stays live, serializes like JS, and cannot poison the next turn or close',
    () async {
      final (_, chatId) = await chat();
      transport.reply('一答');
      final first = await engine
          .send(
            chatId,
            '{{addglobalvar::huge::1e309}}{{addvar::localHuge::1e309}}'
            'first={{getglobalvar::huge}}/{{getvar::localHuge}}',
          )
          .toList();
      expect(_done(first).text, '一答');
      expect(engine.globalVariables['huge'], double.infinity);
      expect(engine.variables(chatId)['localHuge'], double.infinity);
      expect((await engine.path(chatId))[1].text, contains('first=Infinity/Infinity'));
      final persisted =
          jsonDecode(await File('${directory.path}/tavern/settings.json').readAsString()) as Map<String, Object?>;
      expect((persisted['globalVariables']! as Map<String, Object?>)['huge'], isNull);
      transport.reply('二答');
      final second = await engine
          .send(chatId, 'live={{getglobalvar::huge}}/{{getvar::localHuge}}')
          .toList()
          .timeout(const Duration(seconds: 3));
      expect(_done(second).text, '二答');
      expect((await engine.path(chatId))[3].text, 'live=Infinity/Infinity');
      await engine.close().timeout(const Duration(seconds: 3));
      engine = await open();
      expect(engine.globalVariables['huge'], isNull);
      expect(engine.variables(chatId)['localHuge'], isNull);
      transport.reply('三答');
      expect(
        _done(await engine.send(chatId, 'after={{getglobalvar::huge}}/{{getvar::localHuge}}').toList()).text,
        '三答',
      );
      expect((await engine.path(chatId))[5].text, 'after=0/0');
    },
  );

  test('chat field overrides reach eager fields, world scanning and markers without altering the card', () async {
    final (cardId, chatId) = await chat({
      'scenario': '',
      'character_book': {
        'entries': [
          {
            'id': 0,
            'keys': ['覆盖场景'],
            'content': '覆盖命中',
            'enabled': true,
            'insertion_order': 100,
            'extensions': {'match_scenario': true},
          },
        ],
      },
    });
    await engine.setSettings({
      'scenarioOverride': '覆盖场景',
      'systemPromptOverride': '聊天系统提示',
      'mesExamplesOverride': '<START>\nUser: 示例问\n小鲸: 示例答',
    }, chatId: chatId);
    transport.reply('答');
    await engine.send(chatId, '普通输入').drain<void>();
    final content = _requestText(transport.requests.single.body);
    expect(content, contains('覆盖场景'));
    expect(content, contains('覆盖命中'));
    expect(content, contains('聊天系统提示'));
    expect(content, contains('示例答'));
    expect(engine.inspect(chatId)!.worldInfo.activated.single.uid, '0');
    final exported = const CardCodec().decode(await engine.exportCard(cardId, format: TavernCardFormat.json));
    expect(exported.data['scenario'], '');
    expect(exported.data['system_prompt'], '');
  });

  test('world filters use explicit ST avatar identity and tag-map ids, with absent tags left null', () async {
    final (cardId, chatId) = await chat({
      'tags': ['card-description-tag'],
    });
    await engine.putLorebook('filters', {
      'entries': {
        '0': {
          'uid': 0,
          'constant': true,
          'position': 0,
          'content': '名字命中',
          'characterFilter': {
            'isExclude': false,
            'names': ['Alice'],
          },
        },
        '1': {
          'uid': 1,
          'constant': true,
          'position': 0,
          'content': '标签条件',
          'characterFilter': {
            'isExclude': false,
            'tags': ['tag-id'],
          },
        },
      },
    });
    await engine.bindLorebooks(['filters']);
    await engine.setCharacterIdentity(cardId, avatarFilename: 'Alice.png');
    transport.reply('一');
    await engine.send(chatId, '问').drain<void>();
    expect(engine.inspect(chatId)!.worldInfo.activated.map((hit) => hit.uid).toSet(), {'0', '1'});
    await engine.setCharacterIdentity(cardId, avatarFilename: 'Alice.png', tagIds: []);
    transport.reply('二');
    await engine.send(chatId, '问').drain<void>();
    expect(engine.inspect(chatId)!.worldInfo.activated.map((hit) => hit.uid).toSet(), {'0'});
    await engine.setCharacterIdentity(cardId, avatarFilename: 'Alice.png', tagIds: ['tag-id']);
    transport.reply('三');
    await engine.send(chatId, '问').drain<void>();
    expect(engine.inspect(chatId)!.worldInfo.activated.map((hit) => hit.uid).toSet(), {'0', '1'});
  });

  test('fractional and out-of-range extension depths never become valid integer injections', () async {
    final (_, chatId) = await chat({
      'extensions': {
        'depth_prompt': {'prompt': '无效卡深度', 'depth': 4.5, 'role': 'system'},
      },
    });
    await engine.setSettings({
      'authorNote': {'content': '无效作者注释', 'depth': 0.5},
      'injections': [
        {'content': '无效扩展深度', 'depth': 1.9},
        {'content': '越界扩展深度', 'depth': 10001},
        {'content': '有效深度', 'depth': 0},
      ],
    }, chatId: chatId);
    transport.reply('答');
    await engine.send(chatId, '问').drain<void>();
    final content = _requestText(transport.requests.single.body);
    expect(content, contains('有效深度'));
    for (final excluded in ['无效卡深度', '无效作者注释', '无效扩展深度', '越界扩展深度']) {
      expect(content, isNot(contains(excluded)));
    }
  });

  test('imported metadata supplies the pick seed and nonempty force_avatar URLs preserve speaker names', () async {
    final card = await engine.importCard(_card());
    final document = StChatDocument(
      fileName: 'seeded.jsonl',
      header: {
        'user_name': 'User',
        'character_name': '小鲸',
        'chat_metadata': {'chat_id_hash': 123456789},
      },
      messages: [
        {
          'name': '小鲸',
          'is_user': false,
          'is_system': false,
          'send_date': now.toIso8601String(),
          'mes': '开场',
          'extra': <String, Object?>{},
        },
        {
          'name': '副角',
          'is_user': false,
          'is_system': false,
          'send_date': now.toIso8601String(),
          'mes': '历史正文',
          'force_avatar': 'https://example.invalid/avatar.png',
          'extra': <String, Object?>{},
        },
      ],
    );
    final imported = await engine.importChats(card.id, [
      TavernChatFile(fileName: document.fileName, bytes: document.encode()),
    ]);
    final chatId = imported.chatIds.single;
    await engine.close();
    engine = await open();
    final sourceFile = (await engine.exportChat(chatId)).single;
    final source = StChatDocument.decode(sourceFile.fileName, sourceFile.bytes);
    expect((source.header['chat_metadata']! as Map<String, Object?>)['chat_id_hash'], 123456789);
    const input = '{{pick::a::b::c::d::e::f}}|{{pick::one::two::three::four}}';
    final expected = const MacroEngine().expand(
      input,
      MacroContext(chatIdHash: 123456789, now: now, timeZoneOffset: Duration.zero, random: () => 0.25),
    );
    transport.reply('答');
    await engine.send(chatId, input).drain<void>();
    final path = await engine.path(chatId);
    expect(path[path.length - 2].text, expected);
    expect(_requestText(transport.requests.single.body), contains('副角: 历史正文'));
  });

  test('a per-chat preset is complete and does not inherit fields from the previous global preset', () async {
    final (_, chatId) = await chat();
    await engine.setPreset(ChatPreset({'temperature': 0.37, 'stream_openai': true, 'foreign_old': 'global'}));
    await engine.setPreset(ChatPreset({'temperature': 0.6, 'stream_openai': true}), chatId: chatId);
    final chosen = engine.settings(chatId: chatId)['preset']! as Map<String, Object?>;
    expect(chosen.containsKey('foreign_old'), false);
    transport.reply('答');
    await engine.send(chatId, '问').drain<void>();
    expect(transport.requests.single.body['temperature'], 0.6);
  });

  test('hidden user messages are also excluded from the lastUserMessage macro', () async {
    final (_, chatId) = await chat();
    transport.reply('一答');
    await engine.send(chatId, '可见用户消息').drain<void>();
    transport.reply('二答');
    await engine.send(chatId, '隐藏用户消息').drain<void>();
    final path = await engine.path(chatId);
    await engine.setHidden(chatId, path[path.length - 2].nodeId, true);
    transport.reply('三答');
    await engine.send(chatId, 'last={{lastUserMessage}}').drain<void>();
    final after = await engine.path(chatId);
    expect(after[after.length - 2].text, 'last=可见用户消息');
  });

  test(
    'failed inactive regeneration restores remembered choices outside the old active path and across reopen',
    () => verifyInactiveFailure(continuation: false),
  );

  test(
    'failed inactive continuation restores both ancestor choices and target descendants across reopen',
    () => verifyInactiveFailure(continuation: true),
  );

  test('openTavern accepts the actual tavern root without creating a second tavern child', () async {
    await engine.close();
    final root = Directory('${directory.path}/tavern');
    final Tavern facade = await openTavern(root.path);
    final card = await facade.importCard(_card());
    final id = await facade.createChat(card.id);
    expect((await facade.path(id)).single.text, '开场');
    expect(await File('${directory.path}/tavern/tavern.sqlite3').exists(), true);
    expect(await Directory('${root.path}/characters/${card.id}').exists(), true);
    expect(await Directory('${root.path}/tavern').exists(), false);
    await facade.close();
  });

  test('reasoning-only failure still retains a partial message', () async {
    engine.configure(_config(thinking: true));
    final (_, chatId) = await chat();
    final pending = transport.pending();
    final running = engine.send(chatId, '问').toList();
    await pending.connected.future;
    pending.event({
      'choices': [
        {
          'index': 0,
          'delta': {'reasoning_content': '只有思考'},
        },
      ],
    });
    pending.error(const SocketException('end after reasoning'));
    final failed = (await running).whereType<TavernTurnFailed>().single;
    expect(failed.kind, TavernFailure.network);
    expect(failed.partial!.text, '');
    expect(failed.partial!.reasoning, '只有思考');
    expect(await engine.path(chatId), hasLength(3));
  });

  test('usage-only failure retains reported usage rather than rolling the turn back', () async {
    final (_, chatId) = await chat();
    final pending = transport.pending();
    final running = engine.send(chatId, '问').toList();
    await pending.connected.future;
    pending.event({
      'choices': [],
      'usage': {'prompt_tokens': 7, 'completion_tokens': 0},
    });
    pending.error(const SocketException('end after usage'));
    final failed = (await running).whereType<TavernTurnFailed>().single;
    expect(failed.kind, TavernFailure.network);
    expect(failed.partial!.text, '');
    expect(failed.partial!.usage!.promptTokens, 7);
    expect((await engine.path(chatId)).last.usage!.promptTokens, 7);
    expect(await engine.path(chatId), hasLength(3));
  });
}

TavernModelConfig _config({
  String? key = 'fake-test-key',
  bool deepseek = true,
  String model = 'fake-model',
  bool thinking = false,
}) => TavernModelConfig(
  apiKey: () async => key,
  baseUrl: 'https://example.invalid/v1',
  deepseek: deepseek,
  model: model,
  thinking: thinking,
);
ChatPreset _preset([Map<String, Object?> changes = const {}]) =>
    ChatPreset({...ChatPreset.stDefault().raw, 'openai_max_context': 10000, 'openai_max_tokens': 100, ...changes});
Uint8List _card([Map<String, Object?> changes = const {}]) => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'spec': 'chara_card_v3',
      'spec_version': '3.0',
      'data': {
        'name': '蓝鲸',
        'nickname': '小鲸',
        'description': '',
        'personality': '',
        'scenario': '',
        'first_mes': '开场',
        'alternate_greetings': ['备选开场'],
        'mes_example': '',
        'system_prompt': '',
        'post_history_instructions': '',
        'creator_notes': '',
        'tags': [],
        'extensions': {},
        ...changes,
      },
    }),
  ),
);
TavernMessage _done(List<TavernEvent> events) {
  expect(events.whereType<TavernTurnFailed>(), isEmpty);
  return events.whereType<TavernTurnDone>().single.message;
}

List<Map<String, Object?>> _messages(Map<String, Object?> body) =>
    (body['messages']! as List<Object?>).cast<Map<String, Object?>>();
String _requestText(Map<String, Object?> body) => _messages(body).map((message) => message['content']).join('\n');

class _Request {
  const _Request(this.uri, this.body);
  final Uri uri;
  final Map<String, Object?> body;
}

typedef _Plan = Future<http.StreamedResponse> Function(http.BaseRequest request, Map<String, Object?> body);

class _Transport {
  final requests = <_Request>[];
  final plans = Queue<_Plan>();
  final pendingResponses = <_PendingResponse>[];
  TavernModelClient get client => TavernModelClient(
    clientFactory: () => _Client((request) async {
      final body = jsonDecode(utf8.decode(await request.finalize().toBytes())) as Map<String, Object?>;
      requests.add(_Request(request.url, body));
      if (plans.isEmpty) throw StateError('Unexpected HTTP request in test.');
      return plans.removeFirst()(request, body);
    }),
  );
  void reply(String text, {String? reasoning, Map<String, Object?>? usage}) => events([
    if (reasoning != null)
      {
        'choices': [
          {
            'index': 0,
            'delta': {'reasoning_content': reasoning},
          },
        ],
      },
    {
      'choices': [
        {
          'index': 0,
          'delta': {'content': text},
        },
      ],
    },
    if (usage != null) {'choices': [], 'model': 'fake-response', 'usage': usage},
  ]);
  void events(List<Map<String, Object?>> events) {
    plans.add((_, _) async {
      final all = [
        ...events,
        {
          'choices': [
            {'index': 0, 'delta': <String, Object?>{}, 'finish_reason': 'stop'},
          ],
        },
      ];
      final text = '${all.map((event) => 'data: ${jsonEncode(event)}\n\n').join()}data: [DONE]\n\n';
      return http.StreamedResponse(Stream.value(utf8.encode(text)), 200);
    });
  }

  _PendingResponse pending({bool ignoreAbort = false}) {
    final pending = _PendingResponse(ignoreAbort);
    pendingResponses.add(pending);
    plans.add(pending.respond);
    return pending;
  }

  void dispose() {
    for (final response in pendingResponses) {
      response.dispose();
    }
  }
}

class _PendingResponse {
  _PendingResponse(this.ignoreAbort) {
    stream = StreamController<List<int>>(
      onListen: () {
        if (!connected.isCompleted) connected.complete();
      },
    );
  }
  final bool ignoreAbort;
  final connected = Completer<void>();
  late final StreamController<List<int>> stream;
  Future<http.StreamedResponse> respond(http.BaseRequest request, Map<String, Object?> body) async {
    if (!ignoreAbort) {
      unawaited(
        (request as http.AbortableRequest).abortTrigger!.then<void>((_) {
          if (!stream.isClosed) {
            stream.addError(http.RequestAbortedException(request.url));
            unawaited(stream.close());
          }
        }),
      );
    }
    return http.StreamedResponse(stream.stream, 200);
  }

  void event(Map<String, Object?> data) {
    if (!stream.isClosed) stream.add(utf8.encode('data: ${jsonEncode(data)}\n\n'));
  }

  void text(String text) => event({
    'choices': [
      {
        'index': 0,
        'delta': {'content': text},
      },
    ],
  });
  void error(Object error) {
    if (!stream.isClosed) {
      stream.addError(error);
      unawaited(stream.close());
    }
  }

  void dispose() {
    if (!stream.isClosed) unawaited(stream.close());
  }
}

class _Client extends http.BaseClient {
  _Client(this.handler);
  final Future<http.StreamedResponse> Function(http.BaseRequest request) handler;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => handler(request);
  @override
  void close() {}
}
