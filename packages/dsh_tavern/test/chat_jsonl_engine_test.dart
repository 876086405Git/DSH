import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late TavernEngine engine;
  late _Model model;
  Future<TavernEngine> open({DateTime Function()? clock}) => TavernEngine.openDirectory(
    directory,
    config: TavernModelConfig(apiKey: () async => 'fixture', model: 'fixture'),
    modelClient: model,
    clock: clock ?? () => _at,
    random: () => 0.25,
  );
  Future<String> card([Map<String, Object?> fields = const {}]) async => (await engine.importCard(_card(fields))).id;
  Future<void> executeSql(String sql) async {
    await engine.close();
    final database = sqlite3.open('${directory.path}/tavern.sqlite3');
    try {
      database.execute(sql);
    } finally {
      database.close();
    }
    engine = await open();
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('dsh-jsonl-engine-');
    model = _Model();
    engine = await open();
  });
  tearDown(() async {
    await engine.close();
    model.dispose();
    await directory.delete(recursive: true);
  });

  test('Tavern imports and exports JSONL without adding a greeting or evaluating macros', () async {
    final id = await card({'first_mes': '{{incglobalvar::unexpected}}GREETING'});
    final Tavern facade = engine;
    final imported = await facade.importChats(id, [
      _file(
        '对话.jsonl',
        [
          _message(
            '原始{{incglobalvar::unexpected}}文本',
            user: true,
            extra: {
              'foreign': {'keep': 7},
            },
          ),
        ],
        metadata: {
          'variables': {'x': 4},
          'quickReply': {'unknown': true},
        },
        header: {
          'foreignHeader': ['鲸🐋'],
        },
      ),
    ]);
    expect(imported.chatIds, hasLength(1));
    final chatId = imported.chatIds.single;
    expect(imported.chatsByFile['对话.jsonl'], chatId);
    final path = await facade.path(chatId);
    expect(path, hasLength(1));
    expect(path.single.text, '原始{{incglobalvar::unexpected}}文本');
    expect(path.single.role, TavernRole.user);
    expect(engine.globalVariables, isEmpty);
    expect(engine.variables(chatId), {'x': 4});
    expect((await facade.character(id))!.chatCount, 1);
    final exported = await facade.exportChat(chatId);
    final document = StChatDocument.decode(exported.first.fileName, exported.first.bytes);
    expect(document.header['foreignHeader'], ['鲸🐋']);
    expect(document.messages.single['mes'], path.single.text);
    expect((document.messages.single['extra']! as Map<String, Object?>)['foreign'], {'keep': 7});
    expect(engine.globalVariables, isEmpty);
    await engine.close();
    engine = await open();
    expect((await engine.path(chatId)).single.text, path.single.text);
    expect(engine.variables(chatId), {'x': 4});
  });

  test('file bytes are detached and malformed batches leave no partial chat', () async {
    final id = await card();
    final source = _file('good.jsonl', [_message('kept')]);
    final mutable = Uint8List.fromList(source.bytes);
    final frozen = TavernChatFile(fileName: source.fileName, bytes: mutable);
    mutable.fillRange(0, mutable.length, 0);
    expect(frozen.bytes, source.bytes);
    expect(() => frozen.bytes[0] = 0, throwsUnsupportedError);
    final bad = TavernChatFile(fileName: 'bad.jsonl', bytes: Uint8List.fromList(utf8.encode('{}\n{"mes":')));
    await expectLater(engine.importChats(id, [frozen, bad]), throwsA(isA<FormatException>()));
    expect(await engine.watchChats(characterId: id).first, isEmpty);
    final result = await engine.importChats(id, [frozen]);
    expect(result.chatIds, hasLength(1));
    expect((await engine.path(result.chatIds.single)).single.text, 'kept');
  });

  test('missing character does not create an orphan and close waits for accepted import', () async {
    final file = _file('one.jsonl', [_message('one')]);
    await expectLater(engine.importChats('missing', [file]), throwsA(isA<TavernImportError>()));
    expect(await engine.watchChats().first, isEmpty);
    final id = await card();
    final imported = engine.importChats(id, [file]);
    final closing = engine.close();
    final result = await imported;
    await closing;
    engine = await open();
    expect((await engine.path(result.chatIds.single)).single.text, 'one');
  });

  test('concurrent chat imports finish in call order while preparation is asynchronous', () async {
    final id = await card();
    final completed = <String>[];
    final large = engine
        .importChats(id, [
          _file('large.jsonl', [for (var index = 0; index < 45; index++) _message('entry $index')]),
        ])
        .then((result) {
          completed.add('large');
          return result;
        });
    final small = engine
        .importChats(id, [
          _file('small.jsonl', [_message('one')]),
        ])
        .then((result) {
          completed.add('small');
          return result;
        });
    final imported = await Future.wait([large, small]);
    expect(completed, ['large', 'small']);
    expect(await engine.path(imported[0].chatIds.single), hasLength(45));
    expect((await engine.path(imported[1].chatIds.single)).single.text, 'one');
  });

  test('unhide changes ST is_system together with prompt, WI and macro visibility', () async {
    final id = await card({
      'description': 'LAST_USER={{lastUserMessage}}',
      'character_book': {
        'name': '灯塔书',
        'entries': [
          {
            'id': 1,
            'keys': ['灯塔_secret'],
            'content': 'WI_VISIBLE',
            'enabled': true,
            'insertion_order': 100,
            'position': 'before_char',
            'extensions': {},
          },
        ],
      },
    });
    final imported = await engine.importChats(id, [
      _file('hidden.jsonl', [
        _message('开头'),
        {..._message('灯塔_secret', user: true), 'is_system': true},
      ]),
    ]);
    final chatId = imported.chatIds.single;
    final hidden = (await engine.path(chatId)).last;
    expect(hidden.role, TavernRole.user);
    expect(hidden.hidden, isTrue);
    await engine.setSettings({
      'worldInfo': {'world_info_depth': 10},
    }, chatId: chatId);
    _done(await engine.send(chatId, '').toList());
    expect(_bodyText(model.bodies.last), isNot(contains('灯塔_secret')));
    expect(_bodyText(model.bodies.last), isNot(contains('WI_VISIBLE')));
    await engine.setHidden(chatId, hidden.nodeId, false);
    _done(await engine.send(chatId, '').toList());
    expect(_bodyText(model.bodies.last), contains('灯塔_secret'));
    expect(_bodyText(model.bodies.last), contains('LAST_USER=灯塔_secret'));
    expect(_bodyText(model.bodies.last), contains('WI_VISIBLE'));
    final files = await engine.exportChat(chatId);
    final messages = StChatDocument.decode(files.first.fileName, files.first.bytes).messages;
    expect(messages.firstWhere((message) => message['mes'] == '灯塔_secret')['is_system'], isFalse);
    await engine.close();
    engine = await open();
    expect((await engine.path(chatId)).firstWhere((message) => message.nodeId == hidden.nodeId).hidden, isFalse);
    await engine.setHidden(chatId, hidden.nodeId, true);
    _done(await engine.send(chatId, '').toList());
    expect(_bodyText(model.bodies.last), isNot(contains('灯塔_secret')));
    expect(_bodyText(model.bodies.last), isNot(contains('WI_VISIBLE')));
  });

  test('imported chat overrides are used by the next actual assembly', () async {
    final id = await card({
      'scenario': 'CARD_SCENARIO',
      'system_prompt': 'CARD_SYSTEM',
      'mes_example': '<START>\nUser: CARD_EXAMPLE\n鲸: card answer',
    });
    final imported = await engine.importChats(id, [
      _file(
        'overrides.jsonl',
        [_message('问', user: true)],
        metadata: {
          'scenario': 'CHAT_SCENARIO',
          'system_prompt': 'CHAT_SYSTEM',
          'mes_example': '<START>\nUser: CHAT_EXAMPLE\n鲸: chat answer',
        },
      ),
    ]);
    _done(await engine.send(imported.chatIds.single, '').toList());
    final body = _bodyText(model.bodies.last);
    expect(body, contains('CHAT_SCENARIO'));
    expect(body, contains('CHAT_SYSTEM'));
    expect(body, contains('CHAT_EXAMPLE'));
    expect(body, isNot(contains('CARD_SCENARIO')));
    expect(body, isNot(contains('CARD_SYSTEM')));
    expect(body, isNot(contains('CARD_EXAMPLE')));
  });

  test('imported author note interval follows user messages instead of becoming constant', () async {
    final id = await card();
    final imported = await engine.importChats(id, [
      _file(
        'note.jsonl',
        [_message('开头'), _message('one', user: true)],
        metadata: {
          'note_prompt': 'INTERVAL_NOTE',
          'note_interval': 2,
          'note_depth': 4,
          'note_position': 2,
          'note_role': 0,
        },
      ),
    ]);
    final chatId = imported.chatIds.single;
    _done(await engine.send(chatId, '').toList());
    expect(_bodyText(model.bodies.last), isNot(contains('INTERVAL_NOTE')));
    _done(await engine.send(chatId, 'two').toList());
    expect(_bodyText(model.bodies.last), contains('INTERVAL_NOTE'));
    _done(await engine.send(chatId, 'three').toList());
    expect(_bodyText(model.bodies.last), isNot(contains('INTERVAL_NOTE')));
    final files = await engine.exportChat(chatId);
    final header = StChatDocument.decode(files.first.fileName, files.first.bytes).header;
    expect((header['chat_metadata']! as Map<String, Object?>)['note_interval'], 2);
  });

  test('export during an active turn reads a committed snapshot without cancelling it', () async {
    final id = await card();
    final imported = await engine.importChats(id, [
      _file('running.jsonl', [_message('问', user: true)]),
    ]);
    final chatId = imported.chatIds.single;
    final hold = model.hold();
    final events = engine.send(chatId, '').toList();
    await hold.connected;
    final files = await engine.exportChat(chatId);
    expect(files, isNotEmpty);
    expect(StChatDocument.decode(files.first.fileName, files.first.bytes).messages.first['mes'], '问');
    expect(hold.cancelled(), isFalse);
    hold.stream.add(const ModelText('完成'));
    hold.stream.add(const ModelFinished('stop'));
    await hold.stream.close();
    expect(_done(await events).text, '完成');
  });

  test('a noncurrent regeneration captures its target source and keeps it on the new reply', () async {
    final id = await card({'scenario': 'CARD_SCENARIO'});
    final rows = [_message('相同提问', user: true), _message('相同回答')];
    final imported = await engine.importChats(id, [
      _file(
        'main.jsonl',
        rows,
        metadata: {
          'scenario': 'MAIN_SCENARIO',
          'variables': {'last': 'main'},
        },
      ),
      _file(
        'branch.jsonl',
        rows,
        metadata: {
          'main_chat': 'main',
          'scenario': 'BRANCH_SCENARIO',
          'variables': {'last': 'branch'},
        },
      ),
    ]);
    final chatId = imported.chatIds.single;
    final main = await engine.path(chatId);
    expect(main.first.siblingCount, 2);
    await engine.selectSibling(chatId, main.first.nodeId, 1);
    final branch = await engine.path(chatId);
    expect(engine.settings(chatId: chatId)['scenarioOverride'], 'BRANCH_SCENARIO');
    await engine.selectSibling(chatId, main.first.nodeId, 0);
    expect(engine.settings(chatId: chatId)['scenarioOverride'], 'MAIN_SCENARIO');
    _done(await engine.regenerate(chatId, branch.last.nodeId).toList());
    expect(_bodyText(model.bodies.last), contains('BRANCH_SCENARIO'));
    expect(_bodyText(model.bodies.last), isNot(contains('MAIN_SCENARIO')));
    expect(engine.variables(chatId).containsKey('last'), isFalse);
    _done(await engine.send(chatId, '').toList());
    expect(_bodyText(model.bodies.last), contains('BRANCH_SCENARIO'));
    await engine.close();
    engine = await open();
    expect(engine.settings(chatId: chatId)['scenarioOverride'], 'BRANCH_SCENARIO');
  });

  test('continuing an unknown inactive swipe does not borrow the selected file end variables', () async {
    final id = await card({'description': 'N={{getvar::n}}'});
    final imported = await engine.importChats(id, [
      _file(
        'unknown.jsonl',
        [
          {
            ..._message('main'),
            'swipes': ['main', 'side'],
            'swipe_id': 0,
          },
        ],
        metadata: {
          'variables': {'n': 9},
        },
      ),
    ]);
    final chatId = imported.chatIds.single;
    final main = (await engine.path(chatId)).single;
    await engine.selectSibling(chatId, main.nodeId, 1);
    final side = (await engine.path(chatId)).single;
    await engine.selectSibling(chatId, main.nodeId, 0);
    expect(engine.variables(chatId), {'n': 9});
    _done(await engine.continueReply(chatId, side.nodeId).toList());
    expect(_bodyText(model.bodies.last), contains('N='));
    expect(_bodyText(model.bodies.last), isNot(contains('N=9')));
    expect(engine.variables(chatId), isEmpty);
    await engine.selectSibling(chatId, main.nodeId, 0);
    expect(engine.variables(chatId), {'n': 9});
  });

  test('source empty override clears global override and explicit chat settings win last', () async {
    final id = await card({'scenario': 'CARD_SCENARIO'});
    await engine.setSettings({'scenarioOverride': 'GLOBAL_SCENARIO'});
    final imported = await engine.importChats(id, [
      _file('empty.jsonl', [_message('问', user: true)], metadata: {'scenario': ''}),
    ]);
    final chatId = imported.chatIds.single;
    _done(await engine.send(chatId, '').toList());
    expect(_bodyText(model.bodies.last), contains('CARD_SCENARIO'));
    expect(_bodyText(model.bodies.last), isNot(contains('GLOBAL_SCENARIO')));
    await engine.setSettings({'scenarioOverride': 'MANUAL_SCENARIO'}, chatId: chatId);
    _done(await engine.send(chatId, '').toList());
    expect(_bodyText(model.bodies.last), contains('MANUAL_SCENARIO'));
    expect(_bodyText(model.bodies.last), isNot(contains('CARD_SCENARIO')));
  });

  test('world_info uses an explicit existing local mapping and exports the original name', () async {
    final id = await card();
    final source = _file('book.jsonl', [_message('问', user: true)], metadata: {'world_info': '中文世界书'});
    final file = TavernChatFile(fileName: source.fileName, bytes: Uint8List.fromList([10, 10, ...source.bytes]));
    await engine.putLorebook('local-wi', {
      'entries': {
        '1': {
          'uid': 1,
          'key': [],
          'content': 'MAPPED_WORLD_INFO',
          'constant': true,
          'disable': false,
          'position': 0,
          'order': 100,
        },
      },
    });
    final unmapped = await engine.importChats(id, [file]);
    expect(unmapped.notices.join('\n'), contains('book.jsonl:3: 世界书“中文世界书”没有本地映射'));
    _done(await engine.send(unmapped.chatIds.single, '').toList());
    expect(_bodyText(model.bodies.last), isNot(contains('MAPPED_WORLD_INFO')));
    final mapped = await engine.importChats(id, [file], lorebookIds: {'中文世界书': 'local-wi'});
    final chatId = mapped.chatIds.single;
    expect(mapped.notices, isEmpty);
    _done(await engine.send(chatId, '').toList());
    expect(_bodyText(model.bodies.last), contains('MAPPED_WORLD_INFO'));
    final exported = (await engine.exportChat(chatId)).first;
    final header = StChatDocument.decode(exported.fileName, exported.bytes).header;
    expect((header['chat_metadata']! as Map<String, Object?>)['world_info'], '中文世界书');
    await engine.close();
    engine = await open();
    _done(await engine.send(chatId, '').toList());
    expect(_bodyText(model.bodies.last), contains('MAPPED_WORLD_INFO'));
    final before = (await engine.watchChats().first).length;
    await expectLater(
      engine.importChats(id, [file], lorebookIds: {'中文世界书': 'missing'}),
      throwsA(isA<TavernImportError>()),
    );
    expect(await engine.watchChats().first, hasLength(before));
  });

  test('mapped lorebook deletion queued during preparation prevents chat import', () async {
    final id = await card();
    await engine.putLorebook('mapped', {'entries': <String, Object?>{}});
    await engine.close();
    var deleteDuringPreparation = false;
    Future<void>? deleting;
    engine = await open(
      clock: () {
        if (deleteDuringPreparation) {
          deleteDuringPreparation = false;
          deleting = engine.deleteLorebook('mapped');
        }
        return _at;
      },
    );
    await engine.character(id);
    // With the character cached, import's next clock read is the synchronous
    // prepareBatchAsync call, before it awaits its worker. Queue deletion there.
    deleteDuringPreparation = true;
    await expectLater(
      engine.importChats(
        id,
        [
          _file('mapped.jsonl', [_message('kept')], metadata: {'world_info': 'source'}),
        ],
        lorebookIds: {'source': 'mapped'},
      ),
      throwsA(isA<TavernImportError>()),
    );
    expect(deleteDuringPreparation, isFalse);
    expect(deleting, isNotNull);
    await deleting!;
    expect(await engine.lorebook('mapped'), isNull);
    expect(await engine.watchChats(characterId: id).first, isEmpty);
  });

  test('unhide rolls back the original ST flag if the canonical hidden write fails', () async {
    final id = await card();
    final imported = await engine.importChats(id, [
      _file('atomic.jsonl', [
        {
          ..._message('secret', user: true),
          'is_system': true,
          'unknown': {
            'keep': [1, null],
          },
        },
      ]),
    ]);
    final chatId = imported.chatIds.single;
    final nodeId = (await engine.path(chatId)).single.nodeId;
    await executeSql('''CREATE TRIGGER reject_unhide BEFORE UPDATE OF hidden ON nodes
      WHEN NEW.hidden = 0 BEGIN SELECT RAISE(ABORT, 'unhide fixture'); END''');
    await expectLater(engine.setHidden(chatId, nodeId, false), throwsA(isA<SqliteException>()));
    expect((await engine.path(chatId)).single.hidden, isTrue);
    final database = sqlite3.open('${directory.path}/tavern.sqlite3');
    try {
      final stored = database.select('SELECT original FROM nodes WHERE id = ?', [nodeId]).single;
      final original = jsonDecode(stored['original']! as String) as Map<String, Object?>;
      expect(original['is_system'], isNot(false));
    } finally {
      database.close();
    }
    var file = (await engine.exportChat(chatId)).first;
    var row = StChatDocument.decode(file.fileName, file.bytes).messages.single;
    expect(row['is_system'], isTrue);
    expect(row['unknown'], {
      'keep': [1, null],
    });
    await executeSql('DROP TRIGGER reject_unhide');
    await engine.setHidden(chatId, nodeId, false);
    file = (await engine.exportChat(chatId)).first;
    row = StChatDocument.decode(file.fileName, file.bytes).messages.single;
    expect(row['is_system'], isFalse);
    expect(row['unknown'], {
      'keep': [1, null],
    });
  });

  test('the first raw message expands after eager fields and before WI, and is committed once', () async {
    final id = await card({
      'description': 'BEFORE={{getvar::n}}',
      'character_book': {
        'name': 'first phase',
        'entries': [
          {
            'id': 1,
            'keys': ['灯塔_User'],
            'content': 'WI_N={{getvar::n}}',
            'enabled': true,
            'insertion_order': 100,
            'position': 'before_char',
            'extensions': {},
          },
        ],
      },
    });
    const raw = '{{incvar::n}}灯塔_{{user}}';
    final imported = await engine.importChats(id, [
      _file(
        'first.jsonl',
        [_message(raw)],
        metadata: {
          'variables': {'n': 0},
        },
      ),
    ]);
    final chatId = imported.chatIds.single;
    expect((await engine.path(chatId)).single.text, raw);
    _done(await engine.send(chatId, '').toList());
    expect(_bodyText(model.bodies.last), contains('BEFORE=0'));
    expect(_bodyText(model.bodies.last), contains('WI_N=1'));
    expect((await engine.path(chatId)).first.text, '1灯塔_User');
    expect(engine.variables(chatId), {'n': 1});
    _done(await engine.send(chatId, '').toList());
    expect(engine.variables(chatId), {'n': 1});
    await engine.close();
    engine = await open();
    expect((await engine.path(chatId)).first.text, '1灯塔_User');
  });

  test('a hidden first message has its ST pre-WI side effect but remains excluded from history', () async {
    final id = await card({
      'character_book': {
        'name': 'hidden first',
        'entries': [
          {
            'id': 1,
            'keys': [],
            'constant': true,
            'content': 'HIDDEN_N={{getvar::n}}',
            'enabled': true,
            'insertion_order': 100,
            'position': 'before_char',
            'extensions': {},
          },
        ],
      },
    });
    final imported = await engine.importChats(id, [
      _file(
        'hidden-first.jsonl',
        [
          {..._message('{{setvar::n::1}}HIDDEN_FIRST'), 'is_system': true},
          _message('visible', user: true),
        ],
        metadata: {
          'variables': {'n': 0},
        },
      ),
    ]);
    final chatId = imported.chatIds.single;
    _done(await engine.send(chatId, '').toList());
    expect(_bodyText(model.bodies.last), contains('HIDDEN_N=1'));
    expect(_bodyText(model.bodies.last), isNot(contains('HIDDEN_FIRST')));
    expect((await engine.path(chatId)).first.hidden, isTrue);
  });

  test('an empty failed turn restores the raw first message together with local variables', () async {
    final id = await card();
    const raw = '{{incvar::n}}first';
    final imported = await engine.importChats(id, [
      _file(
        'failed-first.jsonl',
        [_message(raw)],
        metadata: {
          'variables': {'n': 0},
        },
      ),
    ]);
    final chatId = imported.chatIds.single;
    model.failure = const TavernModelException(TavernFailure.network, 'fixture');
    final events = await engine.send(chatId, '').toList();
    expect(events.whereType<TavernTurnFailed>().single.partial, isNull);
    expect((await engine.path(chatId)).single.text, raw);
    expect(engine.variables(chatId), {'n': 0});
    model.failure = null;
    _done(await engine.send(chatId, '').toList());
    expect((await engine.path(chatId)).first.text, '1first');
    expect(engine.variables(chatId), {'n': 1});
  });

  test('impersonation preserves first-message text and commits local macro state only with output', () async {
    final id = await card();
    const raw = '{{incvar::n}}first';
    final imported = await engine.importChats(id, [
      _file(
        'draft-first.jsonl',
        [_message(raw)],
        metadata: {
          'variables': {'n': 0},
        },
      ),
    ]);
    final chatId = imported.chatIds.single;
    final first = (await engine.path(chatId)).single;
    model.failure = const TavernModelException(TavernFailure.network, 'fixture-before-output');
    final failed = (await engine.impersonate(chatId).toList()).whereType<TavernTurnFailed>().single;
    expect(failed.kind, TavernFailure.network);
    expect(failed.partial, isNull);
    expect(_bodyText(model.bodies.last), contains('1first'));
    expect((await engine.path(chatId)).single.text, raw);
    expect(engine.variables(chatId), {'n': 0});
    model.failure = null;
    _done(await engine.impersonate(chatId).toList());
    expect(_bodyText(model.bodies.last), contains('1first'));
    expect((await engine.path(chatId)).single.nodeId, first.nodeId);
    expect((await engine.path(chatId)).single.text, raw);
    expect(engine.variables(chatId), {'n': 1});
    final file = (await engine.exportChat(chatId)).single;
    final document = StChatDocument.decode(file.fileName, file.bytes);
    expect((document.header['chat_metadata']! as Map<String, Object?>)['variables'], {'n': 1});
    final extra = document.messages.single['extra']! as Map<String, Object?>;
    final own = extra['dshgo']! as Map<String, Object?>;
    expect((own['tavernState']! as Map<String, Object?>)['variables'], {'n': 1});
    await engine.close();
    engine = await open();
    expect((await engine.path(chatId)).single.nodeId, first.nodeId);
    expect((await engine.path(chatId)).single.text, raw);
    expect(engine.variables(chatId), {'n': 1});
  });

  test('continuing the first message appends to its expanded text and uses its actual trailing space', () async {
    final id = await card();
    await engine.setSettings({'userName': 'User '});
    final imported = await engine.importChats(id, [
      _file('continued-first.jsonl', [_message('Hello {{user}}')]),
    ]);
    final chatId = imported.chatIds.single;
    final target = (await engine.path(chatId)).single;
    final done = _done(await engine.continueReply(chatId, target.nodeId).toList());
    expect(done.nodeId, target.nodeId);
    expect(done.text, 'Hello User 回复');
    expect((await engine.path(chatId)).single.text, done.text);
  });

  test('imported inspection identifiers remain opaque instead of pointing into the new chat', () async {
    final id = await card();
    final source = await engine.createChat(id);
    final done = _done(await engine.send(source, 'question').toList());
    expect(await engine.inspectTurn(source, nodeId: done.nodeId), isNotNull);
    final files = await engine.exportChat(source);
    final imported = await engine.importChats(id, files);
    final chatId = imported.chatIds.single;
    expect(chatId, isNot(source));
    expect(await engine.inspectTurn(chatId), isNull);
    for (final node in await engine.path(chatId)) {
      expect(await engine.inspectTurn(chatId, nodeId: node.nodeId), isNull);
    }
    final reread = await engine.exportChat(chatId);
    expect(utf8.decode(reread.first.bytes), contains(done.nodeId));
    expect(await engine.inspectTurn(source, nodeId: done.nodeId), isNotNull);
  });
}

final _at = DateTime.utc(2024, 2, 29, 12);
Uint8List _card(Map<String, Object?> fields) => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'spec': 'chara_card_v3',
      'spec_version': '3.0',
      'data': {
        'name': '鲸',
        'description': '',
        'personality': '',
        'scenario': '',
        'first_mes': '开场',
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
);
Map<String, Object?> _message(String text, {bool user = false, Map<String, Object?> extra = const {}}) => {
  'name': user ? 'User' : '鲸',
  'is_user': user,
  'is_system': false,
  'send_date': _at.toIso8601String(),
  'mes': text,
  'extra': extra,
};
TavernChatFile _file(
  String name,
  List<Map<String, Object?>> messages, {
  Map<String, Object?> metadata = const {},
  Map<String, Object?> header = const {},
}) => TavernChatFile(
  fileName: name,
  bytes: StChatDocument(
    fileName: name,
    header: {'user_name': 'unused', 'character_name': 'unused', 'chat_metadata': metadata, ...header},
    messages: messages,
  ).encode(),
);
String _bodyText(Map<String, Object?> body) =>
    (body['messages']! as List<Object?>).cast<Map<String, Object?>>().map((message) => message['content']).join('\n');
TavernMessage _done(List<TavernEvent> events) {
  expect(events.whereType<TavernTurnFailed>(), isEmpty);
  return events.whereType<TavernTurnDone>().single.message;
}

class _Model extends TavernModelClient {
  final bodies = <Map<String, Object?>>[];
  TavernModelException? failure;
  StreamController<ModelDelta>? _held;
  Completer<void>? _connected;
  ModelCancellation? _cancellation;
  ({StreamController<ModelDelta> stream, Future<void> connected, bool Function() cancelled}) hold() {
    final stream = StreamController<ModelDelta>();
    final connected = Completer<void>();
    _held = stream;
    _connected = connected;
    return (stream: stream, connected: connected.future, cancelled: () => _cancellation?.isCancelled ?? false);
  }

  @override
  Stream<ModelDelta> generate({
    required TavernModelConfig config,
    required Map<String, Object?> body,
    required ModelCancellation cancellation,
    void Function(int attempt)? onRequestStarted,
  }) {
    bodies.add(jsonDecode(jsonEncode(body)) as Map<String, Object?>);
    if (failure case final error?) return Stream<ModelDelta>.error(error);
    if (_held case final stream?) {
      _cancellation = cancellation;
      _connected!.complete();
      _held = null;
      return stream.stream;
    }
    return Stream.fromIterable([const ModelText('回复'), const ModelFinished('stop')]);
  }

  void dispose() {
    if (_held case final stream?) unawaited(stream.close());
  }
}
