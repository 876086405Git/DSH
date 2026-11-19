import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/src/api.dart';
import 'package:dsh_tavern/src/io/chat_jsonl.dart';
import 'package:dsh_tavern/src/io/st_chat_document.dart';
import 'package:dsh_tavern/src/store/chat_store.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

final _time = DateTime.utc(2026, 2, 3, 4, 5, 6);

void main() {
  late ChatStore store;
  late ChatJsonlCodec codec;
  var integrity = 0;
  setUp(() {
    integrity = 0;
    store = ChatStore.inMemory(clock: () => _time);
    codec = ChatJsonlCodec(clock: () => _time, createIntegrity: () => 'fresh-${integrity++}');
  });
  tearDown(() => store.close());

  String load(List<StChatDocument> documents) =>
      codec.importBatch(store, characterId: 'card', documents: documents).chatIds.single;

  test('selected mes and pristine raw swipe stay distinct without macro execution', () {
    final chat = load([
      _document('opening.jsonl', [
        _row('Hello Alice', swipes: ['Hello {{user}}', 'Alt']),
      ]),
    ]);
    expect(store.path(chat).single.text, 'Hello Alice');
    expect(store.children(chat, null).map((node) => node.message.text), ['Hello Alice', 'Alt']);
    final output = codec.exportChat(store, chat).single.messages.single;
    expect(output['mes'], 'Hello Alice');
    expect(output['swipes'], ['Hello {{user}}', 'Alt']);
    store.edit(chat, store.chat(chat).currentLeafId!, 'Edited');
    expect(codec.exportChat(store, chat).single.messages.single['swipes'], ['Edited', 'Alt']);
  });

  test('duplicate swipes retain occurrence and full inactive info rather than current extra', () {
    final chat = load([
      _document(
        'same',
        [
          {
            ..._row('same', swipes: ['same', 'same', 'third'], selected: 1),
            'extra': {
              'reasoning': 'selected',
              'model': 'new',
              'tool_invocations': [
                {'id': 1},
              ],
            },
            'swipe_info': [
              {
                'send_date': 1000,
                'gen_started': 's0',
                'extra': {
                  'reasoning': 'old',
                  'unknown': {'a': 1},
                },
                'vendor': 7,
              },
              {
                'extra': {'reasoning': 'stale'},
              },
            ],
            'variables': [
              {'slot': 0},
              {'slot': 1},
              null,
            ],
          },
        ],
        metadata: {
          'variables': {'local': 9},
        },
      ),
    ]);
    final roots = store.children(chat, null);
    expect(roots, hasLength(3));
    expect(store.chat(chat).selectedRootId, roots[1].message.nodeId);
    expect(roots[0].message.reasoning, 'old');
    expect(roots[0].extra['unknown'], {'a': 1});
    expect(roots[0].message.at.millisecondsSinceEpoch, 1000);
    expect(roots[1].message.reasoning, 'selected');
    expect(roots[2].message.reasoning, isNull);
    expect(_state(store, chat, roots[0]), {
      'messageVariables': {'slot': 0},
    });
    expect(_state(store, chat, roots[1]), {
      'messageVariables': {'slot': 1},
      'variables': {'local': 9},
    });
    expect(_state(store, chat, roots[2]), {'messageVariables': null});
    final output = codec.exportChat(store, chat).single.messages.single;
    expect(output['swipe_id'], 1);
    final infos = output['swipe_info'] as List<Object?>;
    expect(_map(infos[0])['vendor'], 7);
    expect(_map(_map(infos[0])['extra'])['unknown'], {'a': 1});
    expect(_map(_map(infos[2])['extra']).containsKey('reasoning'), isFalse);
  });

  test('missing ordinary swipe info follows ensure then sync with all three date fields', () {
    final chat = load([
      _document('missing', [
        {
          ..._row('A', swipes: ['A', 'B', 'C']),
          'gen_started': 'GS',
          'gen_finished': 'GF',
          'extra': {'reasoning': 'R'},
          'swipe_info': [null, null, {}],
        },
      ]),
    ]);
    final roots = store.children(chat, null);
    expect(roots[1].message.reasoning, isNull);
    expect(roots[1].message.at, _time);
    // T11 assigns identity to every imported variant, including one whose
    // ordinary swipe_info was absent. No hash has been computed for this file.
    expect(roots[1].extra, {
      'dshgo': {
        'tavernState': {'stChatId': 'missing', 'stChatIdHash': null, 'chatJsonlSourceFile': 'missing'},
      },
    });
    expect(roots[1].original['gen_started'], 'GS');
    expect(roots[1].original['gen_finished'], 'GF');
    expect(roots[2].original.containsKey('gen_started'), isFalse);
    expect(roots[2].original.containsKey('gen_finished'), isFalse);
  });

  test('file end variables never fill earlier nodes and metadata projection is detached', () {
    final chat = load([
      _document(
        'main',
        [_row('U', user: true), _row('A'), _row('B')],
        metadata: {
          'variables': {'n': 3},
          'chat_id_hash': 42,
          'scenario': 'raw {{getvar::x}}',
          'unknown': {
            'list': [1, null],
          },
        },
      ),
    ]);
    final path = store.path(chat);
    expect(_state(store, chat, store.node(chat, path[0].nodeId)), isEmpty);
    expect(_state(store, chat, store.node(chat, path[1].nodeId)), isEmpty);
    expect(_state(store, chat, store.node(chat, path[2].nodeId)), {
      'variables': {'n': 3},
    });
    expect(codec.metadataForNode(store, chat, nodeId: path[0].nodeId).containsKey('variables'), isFalse);
    expect(codec.metadataForNode(store, chat)['variables'], {'n': 3});
    final projected = codec.metadataForNode(store, chat);
    (projected['unknown'] as Map<String, Object?>)['list'] = 'changed';
    expect(codec.metadataForNode(store, chat)['unknown'], {
      'list': [1, null],
    });
    expect(store.chat(chat).variables, {'n': 3});
  });

  test('continue tavernState wins over older node_states and header final variables', () {
    final chat = load([
      _document(
        'continue',
        [
          {
            ..._row('A'),
            'extra': {
              'dshgo': {
                'tavernState': {
                  'variables': {'n': 4},
                  'messageVariables': {'flag': true},
                },
                'vendor': [1, null],
              },
            },
          },
        ],
        metadata: {
          'variables': {'n': 99},
        },
      ),
    ]);
    final leaf = store.chat(chat).currentLeafId!;
    final node = store.node(chat, leaf);
    store.updateMessage(
      chat,
      leaf,
      extra: {
        'dshgo': {
          ..._map(node.extra['dshgo']),
          'tavernState': {
            'variables': {'n': 5},
            'messageVariables': {'flag': false},
            'chatJsonlSourceFile': 'continue',
          },
        },
      },
    );
    expect(store.nodeState(chat, leaf)['variables'], {'n': 4});
    expect(codec.metadataForNode(store, chat)['variables'], {'n': 5});
    final output = codec.exportChat(store, chat).single;
    expect(_map(output.header['chat_metadata'])['variables'], {'n': 5});
    final other = ChatStore.inMemory();
    addTearDown(other.close);
    final imported = codec.importBatch(other, characterId: 'card', documents: [output]).chatIds.single;
    expect(other.chat(imported).variables, {'n': 5});
    expect(_map(other.node(imported, other.chat(imported).currentLeafId!).extra['dshgo'])['vendor'], [1, null]);
  });

  test('is_system is independent hidden state for both users and characters', () {
    final chat = load([
      _document('hidden', [_row('U', user: true, hidden: true), _row('A', hidden: true)]),
    ]);
    final path = store.path(chat);
    expect(path.map((message) => message.role), [TavernRole.user, TavernRole.character]);
    expect(path.every((message) => message.hidden), isTrue);
    for (final message in path) {
      expect(store.node(chat, message.nodeId).original.containsKey('is_system'), isFalse);
      store.setHidden(chat, message.nodeId, false);
    }
    expect(codec.exportChat(store, chat).single.messages.map((row) => row['is_system']), [false, false]);
  });

  test('reversed multilevel main_chat merges semantic prefixes and keeps internal stops', () {
    // All three files explicitly share their pick cache. Without it, the
    // child's main_chat=branch is a distinct fallback identity from main.
    final main = _document(
      'main.jsonl',
      [
        _row('U', user: true),
        {
          ..._row('A'),
          'extra': {
            'branches': ['branch'],
          },
        },
        _row('B'),
      ],
      metadata: {'chat_id_hash': 42},
    );
    final branch = _document(
      'branch.jsonl',
      [_row('U', user: true), _row('A'), _row('C')],
      metadata: {'main_chat': 'main', 'chat_id_hash': 42},
    );
    final child = _document(
      'child.jsonl',
      [_row('U', user: true), _row('A'), _row('C'), _row('D')],
      metadata: {'main_chat': 'branch', 'chat_id_hash': 42},
    );
    final chat = load([child, main, branch]);
    expect(store.allNodes(chat), hasLength(5));
    expect(store.path(chat).map((message) => message.text), ['U', 'A', 'B']);
    final c = store.allNodes(chat).singleWhere((node) => node.message.text == 'C');
    expect(c.selectedChildId, isNull);
    expect(store.children(chat, c.message.nodeId).single.message.text, 'D');
    store.selectNode(chat, c.message.nodeId);
    expect(store.path(chat).map((message) => message.text), ['U', 'A', 'C']);
    expect(store.allNodes(chat).singleWhere((node) => node.message.text == 'A').extra['branches'], ['branch']);
  });

  test('unrelated identical files are distinct and missing parents produce a diagnostic', () {
    final result = codec.importBatch(
      store,
      characterId: 'card',
      documents: [
        _document('one', [_row('same')]),
        _document('two', [_row('same')]),
        _document('orphan', [_row('same')], metadata: {'main_chat': '../../absent.jsonl'}),
      ],
    );
    expect(result.chatIds, hasLength(3));
    expect(result.notices.single, contains('orphan:1:'));
    expect(store.chat(result.chatsByFile['orphan']!).metadata['main_chat'], '../../absent.jsonl');
    expect(store.listChats(characterId: 'card'), hasLength(3));
  });

  test('cycles and case-folded leaf-label collisions reject the whole batch', () {
    final batches = <List<StChatDocument>>[
      [
        _document('ok', []),
        _document('a', [], metadata: {'main_chat': 'a'}),
      ],
      [
        _document('a', [], metadata: {'main_chat': 'b'}),
        _document('b', [], metadata: {'main_chat': 'a'}),
      ],
      [_document('../Folder/MAIN.JSONL', []), _document(r'C:\other\main.jsonl', [])],
    ];
    for (final batch in batches) {
      expect(
        () => codec.importBatch(store, characterId: 'card', documents: batch),
        throwsA(isA<StChatFormatException>()),
      );
      expect(store.listChats(), isEmpty);
    }
  });

  test('conflicting known terminal variables fork before matching, unknown history stays unknown', () {
    final chat = load([
      _document(
        'main',
        [_row('U', user: true), _row('A')],
        metadata: {
          'variables': {'n': 1},
        },
      ),
      _document(
        'branch',
        [_row('U', user: true), _row('A')],
        metadata: {
          'main_chat': 'main',
          'variables': {'n': 2},
        },
      ),
      _document('unknown', [_row('U', user: true), _row('A')], metadata: {'main_chat': 'main'}),
    ]);
    final root = store.children(chat, null).single;
    expect(_state(store, chat, root), isEmpty);
    final variants = store.children(chat, root.message.nodeId);
    expect(variants, hasLength(3));
    expect(variants.map((node) => _state(store, chat, node)), [
      {
        'variables': {'n': 1},
      },
      {
        'variables': {'n': 2},
      },
      <String, Object?>{},
    ]);
    for (var index = 0; index < variants.length; index++) {
      final projected = codec.metadataForNode(store, chat, nodeId: variants[index].message.nodeId);
      expect(projected['variables'], index < 2 ? {'n': index + 1} : isNull);
    }
    expect(store.chat(chat).variables, {'n': 1});
  });

  test('prefix matching compares unknown content and reasoning, with unordered object keys', () {
    final base = {
      ..._row('same'),
      'unknown': {
        'a': 1,
        'b': [true, null],
      },
      'extra': {'reasoning': 'R'},
    };
    final chat = load([
      _document('main', [base, _row('end')]),
      _document(
        'order',
        [
          {
            ...base,
            'unknown': {
              'b': [true, null],
              'a': 1,
            },
          },
          _row('other'),
        ],
        metadata: {'main_chat': 'main'},
      ),
      _document(
        'reason',
        [
          {
            ...base,
            'extra': {'reasoning': 'different'},
          },
          _row('end'),
        ],
        metadata: {'main_chat': 'main'},
      ),
      _document(
        'unknown',
        [
          {
            ...base,
            'unknown': {
              'a': 2,
              'b': [true, null],
            },
          },
          _row('end'),
        ],
        metadata: {'main_chat': 'main'},
      ),
    ]);
    expect(store.children(chat, null), hasLength(3));
    expect(store.children(chat, store.children(chat, null).first.message.nodeId), hasLength(2));
    expect(store.allNodes(chat), hasLength(7));
  });

  test(
    'different branch configuration is available by explicit inactive node and is never replaced by root metadata',
    () {
      final chat = load([
        _document(
          'main',
          [_row('U', user: true), _row('same')],
          header: {'custom_header': 'M'},
          metadata: {
            'scenario': 'root',
            'chat_id_hash': 1,
            'note_prompt': 'note M',
            'variables': {'x': 1},
          },
        ),
        _document(
          'branch',
          [_row('U', user: true), _row('same')],
          header: {'custom_header': 'B'},
          metadata: {
            'main_chat': 'main',
            'scenario': 'branch',
            'chat_id_hash': 2,
            'note_prompt': 'note B',
            'variables': {'x': 2},
          },
        ),
      ]);
      final roots = store.children(chat, null);
      expect(roots, hasLength(2));
      final branchEnd = store.children(chat, roots[1].message.nodeId).single;
      final branchMetadata = codec.metadataForNode(store, chat, nodeId: branchEnd.message.nodeId);
      expect(branchMetadata['scenario'], 'branch');
      expect(branchMetadata['note_prompt'], 'note B');
      expect(branchMetadata['chat_id_hash'], 2);
      expect(branchMetadata['variables'], {'x': 2});
      expect(codec.metadataForNode(store, chat, nodeId: roots[1].message.nodeId).containsKey('variables'), isFalse);
      expect(codec.metadataForNode(store, chat)['scenario'], 'root');
      final exported = codec.exportChat(store, chat);
      expect(exported.map((document) => document.header['custom_header']), ['M', 'B']);
    },
  );

  test('header-only documents retain nested unknowns, detached data, and fresh per-export integrity', () {
    final header = {
      'unknown_header': {'raw': 'line\n😀', 'null': null},
    };
    final chat = load([
      _document(
        '../empty',
        [],
        header: header,
        metadata: {
          'integrity': 'old',
          'variables': {
            'key': [
              1,
              {'x': true},
            ],
          },
          'unknown': [1, null],
        },
      ),
    ]);
    final first = codec.exportChat(store, chat, fileName: r'..\CON.jsonl').single;
    final second = codec.exportChat(store, chat).single;
    expect(first.messages, isEmpty);
    expect(first.fileName, '_CON.jsonl');
    expect(first.header['unknown_header'], header['unknown_header']);
    expect(_map(first.header['chat_metadata'])['variables'], {
      'key': [
        1,
        {'x': true},
      ],
    });
    expect(_map(first.header['chat_metadata'])['integrity'], 'fresh-0');
    expect(_map(second.header['chat_metadata'])['integrity'], 'fresh-1');
    expect(first.encode().last, isNot(10));
  });

  test('known semantic errors report physical lines and reject all documents before writing', () {
    final invalid = StChatDocument.decode(
      'bad.jsonl',
      Uint8List.fromList(
        utf8.encode('\uFEFF{"chat_metadata":{}}\r\n\r\n\r\n{"mes":"bad","swipes":["x"],"swipe_id":2}'),
      ),
    );
    expect(
      () => codec.importBatch(
        store,
        characterId: 'card',
        documents: [
          _document('valid', [_row('ok')]),
          invalid,
        ],
      ),
      throwsA(
        isA<StChatFormatException>()
            .having((error) => error.fileName, 'file', 'bad.jsonl')
            .having((error) => error.lineNumber, 'physical line', 4),
      ),
    );
    expect(store.listChats(), isEmpty);
  });

  test('header semantic diagnostics use the decoded physical header line', () {
    for (final header in <Map<String, Object?>>[
      {
        'chat_metadata': {'note_depth': 'bad'},
      },
      {'chat_metadata': []},
      {
        'chat_metadata': {'variables': []},
      },
      {
        'chat_metadata': {'dshgo': []},
      },
      {
        'chat_metadata': {
          'dshgo': {
            'chatJsonl': {'version': 2},
          },
        },
      },
      {
        'chat_metadata': {'main_chat': 2},
      },
      {
        'chat_metadata': {'main_chat': '../'},
      },
    ]) {
      final document = StChatDocument.decode(
        'header.jsonl',
        Uint8List.fromList(utf8.encode('\n\n${jsonEncode(header)}')),
      );
      expect(
        () => load([
          _document('valid', [_row('ok')]),
          document,
        ]),
        throwsA(
          isA<StChatFormatException>()
              .having((error) => error.fileName, 'file', 'header.jsonl')
              .having((error) => error.lineNumber, 'header physical line', 3),
        ),
      );
      expect(store.listChats(), isEmpty);
    }
  });

  test('graph and label diagnostics plus notices retain physical header locations', () {
    StChatDocument atThree(String name, Map<String, Object?> metadata) => StChatDocument.decode(
      name,
      Uint8List.fromList(utf8.encode('\r\n \t\r\n${jsonEncode({'chat_metadata': metadata})}')),
    );
    final documents = <List<StChatDocument>>[
      [
        atThree('self.jsonl', {'main_chat': 'self'}),
      ],
      [_document('duplicate', []), atThree('DUPLICATE.JSONL', {})],
      [atThree('../', {})],
    ];
    for (final batch in documents) {
      expect(
        () => codec.importBatch(store, characterId: 'card', documents: batch),
        throwsA(isA<StChatFormatException>().having((error) => error.lineNumber, 'header physical line', 3)),
      );
      expect(store.listChats(), isEmpty);
    }
    final orphan = codec.importBatch(
      store,
      characterId: 'card',
      documents: [
        atThree('orphan.jsonl', {'main_chat': 'absent'}),
      ],
    );
    expect(orphan.notices.single, startsWith('orphan.jsonl:3:'));
    final contexts = codec.importBatch(
      store,
      characterId: 'card',
      documents: [
        _document('main', [], metadata: {'scenario': 'M'}),
        atThree('branch.jsonl', {'main_chat': 'main', 'scenario': 'B'}),
      ],
    );
    expect(contexts.notices.single, startsWith('branch.jsonl:3:'));
  });

  test('strict known shapes and unknown portable versions cannot partially construct a tree', () {
    final badRows = <Map<String, Object?>>[
      {..._row('x'), 'swipes': []},
      {
        ..._row('x'),
        'swipes': [1],
      },
      {
        ..._row('x', swipes: ['x']),
        'swipe_id': -1,
      },
      {
        ..._row('x', swipes: ['x']),
        'swipe_id': 0.5,
      },
      {
        ..._row('x'),
        'swipe_info': [1],
      },
      {..._row('x'), 'variables': {}},
      {..._row('x'), 'name': 3},
      {..._row('x'), 'is_system': 1},
      {
        ..._row('x'),
        'extra': {'reasoning': 4},
      },
      {
        ..._row('x'),
        'extra': {
          'dshgo': {
            'tavernState': {'variables': []},
          },
        },
      },
      {
        ..._row('x'),
        'extra': {
          'dshgo': {
            'chatJsonl': {'version': 2, 'unknown': 'preserved by caller'},
          },
        },
      },
      {
        ..._row('x'),
        'extra': {
          'dshgo': {
            'chatJsonl': {'version': 1, 'message': []},
          },
        },
      },
    ];
    for (final row in badRows) {
      expect(
        () => load([
          _document('valid', [_row('ok')]),
          _document('invalid', [row]),
        ]),
        throwsA(isA<StChatFormatException>()),
      );
      expect(store.listChats(), isEmpty);
    }
    expect(
      () => load([
        _document(
          'future',
          [],
          metadata: {
            'dshgo': {
              'chatJsonl': {'version': 99},
            },
          },
        ),
      ]),
      throwsA(isA<StChatFormatException>()),
    );
    expect(store.listChats(), isEmpty);
    expect(
      () => load([
        _document('bad-parent.jsonl', [], metadata: {'main_chat': '../'}),
      ]),
      throwsA(isA<StChatFormatException>().having((error) => error.fileName, 'containing file', 'bad-parent.jsonl')),
    );
  });

  test('unused swipe-info and variable tails are preserved without making extra nodes', () {
    final infoTail = <Object?>[
      {
        'unused': {
          'data': [false, null],
        },
      },
      null,
    ];
    final variableTail = <Object?>[
      {'unused': 7},
      'opaque',
      13,
      true,
      ['future', null],
      null,
    ];
    final chat = load([
      _document('tails', [
        {
          ..._row('A', swipes: ['A', 'B']),
          'swipe_info': [null, null, ...infoTail],
          'variables': [
            {'v': 0},
            null,
            ...variableTail,
          ],
        },
      ]),
    ]);
    expect(store.allNodes(chat), hasLength(2));
    final exported = codec.exportChat(store, chat).single;
    final row = exported.messages.single;
    expect((row['swipe_info'] as List<Object?>).skip(2).toList(), infoTail);
    expect(row['variables'], [
      {'v': 0},
      null,
      ...variableTail,
    ]);
    final again = load([StChatDocument.decode(exported.fileName, exported.encode())]);
    expect(store.allNodes(again), hasLength(2));
    final second = codec.exportChat(store, again).single.messages.single;
    expect((second['swipe_info'] as List<Object?>).skip(2).toList(), infoTail);
    expect(second['variables'], [
      {'v': 0},
      null,
      ...variableTail,
    ]);
  });

  test('runtime metadata types are checked in both headers and inactive source envelopes', () {
    for (final key in ['scenario', 'system_prompt', 'mes_example', 'world_info', 'note_prompt']) {
      expect(
        () => load([
          _document('bad', [], metadata: {key: 7}),
        ]),
        throwsA(isA<StChatFormatException>()),
      );
    }
    for (final key in ['chat_id_hash', 'note_interval', 'note_depth', 'note_position', 'note_role']) {
      expect(
        () => load([
          _document('bad', [], metadata: {key: '1'}),
        ]),
        throwsA(isA<StChatFormatException>()),
      );
    }
    expect(
      () => load([
        _document('bad', [
          {
            ..._row('A', swipes: ['A', 'B']),
            'swipe_info': [
              null,
              {
                'extra': {
                  'dshgo': {
                    'chatJsonl': {
                      'version': 1,
                      'sourceHeader': {
                        'chat_metadata': {'note_prompt': 7},
                      },
                    },
                  },
                },
              },
            ],
          },
        ]),
      ]),
      throwsA(isA<StChatFormatException>()),
    );
    expect(store.listChats(), isEmpty);
    expect(
      load([
        _document('null', [], metadata: {'scenario': null, 'note_role': null}),
      ]),
      isNotEmpty,
    );
  });

  test('a real SQLite failure in a later file rolls back every new chat and node', () {
    final db = sqlite3.openInMemory();
    final target = ChatStore.fromDatabase(db, clock: () => _time);
    addTearDown(target.close);
    final old = target.createChat(characterId: 'existing', title: 'Keep');
    db.execute(
      "CREATE TRIGGER fixture_import BEFORE INSERT ON nodes WHEN NEW.text = 'FAIL' "
      "BEGIN SELECT RAISE(ABORT, 'fixture_import'); END",
    );
    expect(
      () => codec.importBatch(
        target,
        characterId: 'card',
        documents: [
          _document('first', [_row('OK')]),
          _document('second', [_row('FAIL')]),
        ],
      ),
      throwsA(isA<SqliteException>()),
    );
    expect(target.listChats().map((chat) => chat.id), [old]);
    expect(db.select('SELECT COUNT(*) AS n FROM nodes').single['n'], 0);
    db.execute('DROP TRIGGER fixture_import');
    expect(
      codec
          .importBatch(
            target,
            characterId: 'card',
            documents: [
              _document('recovery', [_row('OK')]),
            ],
          )
          .chatIds,
      hasLength(1),
    );
  });

  test('old inspection identifiers are opaque archives, never live lookup records', () {
    final oldInspection = {
      'version': 1,
      'chatId': 'old-chat',
      'nodeId': 'old-node',
      'sources': [
        {
          'nodeIds': ['old-node', 'old-parent'],
        },
      ],
      'unknown': {'keep': true},
    };
    final oldLatest = {'version': 1, 'nodeId': 'old-node', 'chatId': 'old-chat'};
    var chat = load([
      _document(
        'archive',
        [
          {
            ..._row('A'),
            'extra': {
              'dshgo': {
                'inspection': oldInspection,
                'vendor': {'unchanged': 8},
              },
            },
          },
        ],
        metadata: {
          'dshgo': {'latestInspection': oldLatest},
          'unknown': [true, null],
        },
      ),
    ]);
    var current = store;
    int? encodedLength;
    for (var round = 0; round < 3; round++) {
      final node = current.node(chat, current.chat(chat).currentLeafId!);
      final dshgo = _map(node.extra['dshgo']);
      expect(dshgo.containsKey('inspection'), isFalse);
      expect(_map(dshgo['chatJsonl'])['opaqueInspection'], oldInspection);
      expect(dshgo['vendor'], {'unchanged': 8});
      final chatDshgo = _map(current.chat(chat).metadata['dshgo']);
      expect(chatDshgo.containsKey('latestInspection'), isFalse);
      expect(_map(chatDshgo['chatJsonl'])['opaqueLatestInspection'], oldLatest);
      final files = codec.exportChat(current, chat);
      final encoded = utf8.decode(files.single.encode());
      expect(encoded.contains('"files":'), isFalse);
      expect(encoded.contains('"sources":{"'), isFalse);
      if (encodedLength != null) {
        expect(encoded.length, lessThanOrEqualTo(encodedLength + 50));
      }
      encodedLength = encoded.length;
      final next = ChatStore.inMemory(clock: () => _time);
      addTearDown(next.close);
      chat = codec.importBatch(next, characterId: 'card', documents: files).chatIds.single;
      current = next;
    }
  });

  test('an unrecognized date keeps its raw value and portable internal timestamp across clocks', () {
    final chat = load([
      _document('date', [
        {..._row('A'), 'send_date': 'old human date (opaque)'},
      ]),
    ]);
    final exported = codec.exportChat(store, chat).single;
    expect(exported.messages.single['send_date'], 'old human date (opaque)');
    final later = ChatJsonlCodec(clock: () => DateTime.utc(2099), createIntegrity: () => 'later');
    final result = later.importBatch(store, characterId: 'card', documents: [exported]);
    final recovered = result.chatIds.single;
    expect(store.path(recovered).single.at, _time);
    expect(result.notices.single, contains('portable timestamp'));
  });

  test('unknown header and message values survive reopening a real database', () async {
    final directory = Directory.systemTemp.createTempSync('chat-jsonl-reopen-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}/chat.sqlite';
    var disk = ChatStore.open(path);
    final input = _document(
      'disk',
      [
        {
          ..._row('A'),
          'force_avatar': '/old/avatar.png',
          'unknown': {
            'null': null,
            'array': [false, 1.25, '😀'],
          },
          'extra': {
            'tool_invocations': [
              {'arguments': '{}'},
            ],
          },
        },
      ],
      header: {
        'header_vendor': {'v': 3},
      },
      metadata: {
        'quickReply': {'raw': true},
        'script_injects': ['opaque'],
      },
    );
    final chat = codec.importBatch(disk, characterId: 'card', documents: [input]).chatIds.single;
    await disk.close();
    disk = ChatStore.open(path);
    try {
      final output = codec.exportChat(disk, chat).single;
      expect(output.header['header_vendor'], {'v': 3});
      expect(_map(output.header['chat_metadata'])['quickReply'], {'raw': true});
      expect(_map(output.header['chat_metadata'])['script_injects'], ['opaque']);
      expect(output.messages.single['unknown'], input.messages.single['unknown']);
      expect(output.messages.single['force_avatar'], '/old/avatar.png');
      expect(_map(output.messages.single['extra'])['tool_invocations'], [
        {'arguments': '{}'},
      ]);
    } finally {
      await disk.close();
    }
  });

  test('export filename labels are safe and output documents have distinct fresh integrity', () {
    final chat = load([
      _document('../main?.jsonl', [_row('A'), _row('B')]),
      _document(r'C:\dir\branch*.jsonl', [_row('A'), _row('C')], metadata: {'main_chat': 'main?'}),
    ]);
    final files = codec.exportChat(store, chat, fileName: '../../CON.jsonl');
    expect(files.map((file) => file.fileName), ['_CON.jsonl', 'branch_.jsonl']);
    expect(_map(files[1].header['chat_metadata'])['main_chat'], '_CON');
    expect(files.map((file) => _map(file.header['chat_metadata'])['integrity']).toSet(), hasLength(2));
    expect(_map(files.first.messages[1]['extra'])['branches'], contains('branch_'));
    expect(files.every((file) => !file.fileName.contains('/') && !file.fileName.contains('\\')), isTrue);
  });

  test('three round trips preserve mixed siblings, duplicate occurrences, every choice and state', () {
    final original = store.createChat(characterId: 'card', title: 'Forest', variables: {'v': 1});
    TavernMessage add(
      String text, {
      String? parent,
      TavernRole role = TavernRole.character,
      String name = 'A',
      bool hidden = false,
      String? reasoning,
      Map<String, Object?> state = const {},
      Map<String, Object?> extra = const {},
      Map<String, Object?> raw = const {},
      TavernUsage? usage,
    }) => store.append(
      original,
      parentId: parent,
      role: role,
      speaker: name,
      text: text,
      hidden: hidden,
      at: _time,
      reasoning: reasoning,
      state: state,
      extra: extra,
      original: raw,
      usage: usage,
      makeCurrent: false,
    );
    final u = add(
      'root',
      role: TavernRole.user,
      state: {
        'variables': {'v': 0},
      },
    );
    final system = add('root', role: TavernRole.system, name: 'System');
    final narrator = add('root', role: TavernRole.narrator, name: 'Narrator', extra: {'type': 'narrator'});
    final systemChild = add('system child', parent: system.nodeId, state: {'messageVariables': null});
    final a = add(
      'same',
      parent: u.nodeId,
      name: 'Alpha',
      reasoning: 'private A',
      raw: {
        'force_avatar': 'a.png',
        'only_a': {'x': true},
      },
      state: {
        'variables': {'v': 2},
        'messageVariables': {'m': 7},
      },
      extra: {
        'unknown': [1, null],
        'dshgo': {
          'chatJsonl': {
            'version': 1,
            'future': {'keep': 3},
          },
        },
      },
      usage: const TavernUsage(promptTokens: 3, completionTokens: 4, cacheHitTokens: 2, model: 'reported'),
    );
    final b = add(
      'same',
      parent: u.nodeId,
      role: TavernRole.user,
      name: 'Beta',
      hidden: true,
      raw: {'force_avatar': 'b.png'},
      state: {
        'variables': {'v': 1},
        'messageVariables': null,
      },
    );
    final duplicate = add(
      'same',
      parent: u.nodeId,
      role: TavernRole.user,
      name: 'Beta',
      hidden: true,
      raw: {'force_avatar': 'b.png'},
      state: {
        'variables': {'v': 1},
        'messageVariables': null,
      },
    );
    final a0 = add('first child', parent: a.nodeId);
    final a1 = add('second child', parent: a.nodeId);
    final b0 = add(
      'hidden descendant',
      parent: b.nodeId,
      state: {
        'messageVariables': {'only': 'here'},
      },
    );
    store.restoreSelection(
      original,
      selectedRootId: u.nodeId,
      selectedChildren: {
        u.nodeId: b.nodeId,
        system.nodeId: systemChild.nodeId,
        narrator.nodeId: null,
        systemChild.nodeId: null,
        a.nodeId: a1.nodeId,
        b.nodeId: null,
        duplicate.nodeId: null,
        a0.nodeId: null,
        a1.nodeId: null,
        b0.nodeId: null,
      },
    );
    final before = _tree(store, original);
    var current = store;
    var chat = original;
    int? previousFileCount;
    for (var round = 0; round < 3; round++) {
      final files = codec.exportChat(current, chat);
      if (previousFileCount != null) {
        expect(files.length, previousFileCount);
      }
      previousFileCount = files.length;
      final next = ChatStore.inMemory(clock: () => _time);
      addTearDown(next.close);
      final result = codec.importBatch(next, characterId: 'card', documents: files);
      expect(result.chatIds, hasLength(1));
      chat = result.chatIds.single;
      expect(_tree(next, chat), before, reason: 'whole tree, round $round');
      expect(next.chat(chat).variables, {'v': 1});
      final betas = next.allNodes(chat).where((node) => node.message.speaker == 'Beta').toList();
      expect(betas, hasLength(2));
      expect(betas.every((node) => !node.original.containsKey('only_a')), isTrue);
      final recoveredSystem = next.allNodes(chat).singleWhere((node) => node.message.role == TavernRole.system);
      expect(recoveredSystem.message.hidden, isFalse);
      current = next;
    }
  });

  test('source headers and runtime contexts survive three rounds without recursive provenance', () {
    var chat = load([
      _document(
        'main',
        [_row('U', user: true), _row('A')],
        header: {
          'marker': {'source': 'M'},
        },
        metadata: {
          'scenario': 'M',
          'chat_id_hash': 11,
          'variables': {'n': 1},
          'unknown': {'m': true},
        },
      ),
      _document(
        'branch',
        [_row('U', user: true), _row('A')],
        header: {
          'marker': {'source': 'B'},
        },
        metadata: {
          'main_chat': 'main',
          'scenario': 'B',
          'chat_id_hash': 12,
          'variables': {'n': 2},
          'unknown': {'b': true},
        },
      ),
    ]);
    var current = store;
    int? size;
    for (var round = 0; round < 3; round++) {
      final roots = current.children(chat, null);
      expect(roots, hasLength(2));
      for (var index = 0; index < roots.length; index++) {
        final root = roots[index];
        final end = current.children(chat, root.message.nodeId).single;
        final projection = codec.metadataForNode(current, chat, nodeId: end.message.nodeId);
        expect(projection['scenario'], index == 0 ? 'M' : 'B');
        expect(projection['variables'], {'n': index + 1});
        expect(codec.metadataForNode(current, chat, nodeId: root.message.nodeId).containsKey('variables'), isFalse);
      }
      final files = codec.exportChat(current, chat);
      expect(files, hasLength(2));
      expect(files.map((file) => file.header['marker']), [
        {'source': 'M'},
        {'source': 'B'},
      ]);
      final bytes = files.fold<int>(0, (sum, file) => sum + file.encode().length);
      if (size != null) {
        expect(bytes, lessThanOrEqualTo(size + 100));
      }
      size = bytes;
      for (final file in files) {
        expect(utf8.decode(file.encode()).contains('"files":'), isFalse);
        expect(utf8.decode(file.encode()).contains('"sources":'), isFalse);
      }
      final next = ChatStore.inMemory(clock: () => _time);
      addTearDown(next.close);
      chat = codec.importBatch(next, characterId: 'card', documents: files).chatIds.single;
      current = next;
    }
  });

  test('per-node configuration on one path survives, while an externally edited file header wins', () {
    final chat = store.createChat(
      characterId: 'card',
      title: '@source-1',
      metadata: {
        'scenario': 'M',
        'dshgo': {
          'chatJsonl': {
            'version': 1,
            'sources': {
              'M': {
                'chat_metadata': {'scenario': 'M'},
              },
              'B': {
                'chat_metadata': {'scenario': 'B'},
              },
            },
          },
        },
      },
    );
    final a = store.append(
      chat,
      parentId: null,
      role: TavernRole.user,
      speaker: 'U',
      text: 'A',
      at: _time,
      state: {'chatJsonlSourceFile': 'M'},
    );
    store.append(
      chat,
      parentId: a.nodeId,
      role: TavernRole.character,
      speaker: 'A',
      text: 'B',
      at: _time,
      state: {'chatJsonlSourceFile': 'B'},
    );
    final output = codec.exportChat(store, chat).single;
    final imported = load([output]);
    final path = store.path(imported);
    expect(codec.metadataForNode(store, imported, nodeId: path.first.nodeId)['scenario'], 'M');
    expect(codec.metadataForNode(store, imported)['scenario'], 'B');
    final changedHeader = _map(output.header);
    changedHeader['chat_metadata'] = {..._map(changedHeader['chat_metadata']), 'scenario': 'EDITED'};
    final changed = load([StChatDocument(fileName: output.fileName, header: changedHeader, messages: output.messages)]);
    for (final message in store.path(changed)) {
      expect(codec.metadataForNode(store, changed, nodeId: message.nodeId)['scenario'], 'EDITED');
    }
  });

  test('an externally selected inactive swipe supersedes its stale remembered edge', () {
    final chat = store.createChat(characterId: 'card', title: 'edit branch');
    TavernMessage add(String text, String? parent) => store.append(
      chat,
      parentId: parent,
      role: TavernRole.character,
      speaker: 'A',
      text: text,
      at: _time,
      makeCurrent: false,
    );
    final a = add('A', null);
    final ax = add('AX', a.nodeId);
    final b = add('B', null);
    final bx = add('BX', b.nodeId);
    final by = add('BY', b.nodeId);
    store.restoreSelection(
      chat,
      selectedRootId: a.nodeId,
      selectedChildren: {a.nodeId: ax.nodeId, ax.nodeId: null, b.nodeId: bx.nodeId, bx.nodeId: null, by.nodeId: null},
    );
    final files = codec.exportChat(store, chat);
    expect(files, hasLength(2));
    final branch = files[1];
    final changedLast = _map(branch.messages.last);
    final info = _map((changedLast['swipe_info'] as List<Object?>)[1]);
    changedLast.addAll({'swipe_id': 1, 'mes': 'BY', 'extra': info['extra'], 'send_date': info['send_date']});
    final imported = load([
      files.first,
      StChatDocument(fileName: branch.fileName, header: branch.header, messages: [branch.messages.first, changedLast]),
    ]);
    expect(store.path(imported).map((message) => message.text), ['A', 'AX']);
    final recoveredB = store.children(imported, null).singleWhere((node) => node.message.text == 'B');
    store.selectNode(imported, recoveredB.message.nodeId);
    expect(store.path(imported).map((message) => message.text), ['B', 'BY']);
  });

  test('an empty selected path retains the forest and all inactive null stops', () {
    final chat = store.createChat(characterId: 'card', title: 'Empty selection');
    final a = store.append(chat, parentId: null, role: TavernRole.character, speaker: 'A', text: 'A', at: _time);
    final b = store.append(chat, parentId: a.nodeId, role: TavernRole.character, speaker: 'A', text: 'B', at: _time);
    store.restoreSelection(chat, selectedRootId: null, selectedChildren: {a.nodeId: null, b.nodeId: null});
    final expected = _tree(store, chat);
    final files = codec.exportChat(store, chat);
    expect(files.first.messages, isEmpty);
    expect(files, hasLength(2));
    final result = codec.importBatch(store, characterId: 'card', documents: files);
    expect(_tree(store, result.chatIds.single), expected);
  });

  test('speaker identities omit null carriers and cannot revive cleared selected swipes', () {
    Map<String, Object?> extra(String id, int marker) => {
      'vendor': [marker, null],
      'dshgo': {
        'outerUnknown': false,
        'chatJsonl': {
          'version': 1,
          'speakerCharacterId': id,
          'future': {'keep': marker},
        },
      },
    };
    Map<String, Object?> identity(Object? value) => _map(_map(_map(value)['dshgo'])['chatJsonl']);
    final chat = load([
      _document('speaker-identities.jsonl', [
        {..._row('User', user: true), 'extra': extra('ignored-user-id', 1)},
        {
          ..._row('Selected', swipes: ['Inactive', 'Selected'], selected: 1),
          'extra': extra('selected-id', 3),
          'swipe_info': [
            {'send_date': _time.toIso8601String(), 'extra': extra('inactive-id', 2)},
            {'send_date': _time.toIso8601String(), 'extra': extra('selected-id', 3)},
          ],
        },
      ]),
    ]);
    final path = store.path(chat);
    expect(path.map((message) => message.speakerCharacterId), [null, 'selected-id']);
    expect(store.children(chat, path.first.nodeId).map((node) => node.message.speakerCharacterId), [
      'inactive-id',
      'selected-id',
    ]);
    final first = codec.exportChat(store, chat).single;
    expect(identity(first.messages.first['extra']).containsKey('speakerCharacterId'), isFalse);
    expect(identity(first.messages.last['extra'])['speakerCharacterId'], 'selected-id');
    final initialInfos = first.messages.last['swipe_info']! as List<Object?>;
    expect(initialInfos.map((info) => identity(_map(info)['extra'])['speakerCharacterId']), [
      'inactive-id',
      'selected-id',
    ]);
    expect(_map(first.messages.first['extra'])['vendor'], [1, null]);
    expect(_map(_map(first.messages.first['extra'])['dshgo'])['outerUnknown'], isFalse);
    expect(identity(first.messages.first['extra'])['future'], {'keep': 1});

    store.updateMessage(chat, path.last.nodeId, clearSpeakerCharacterId: true);
    expect(store.message(chat, path.last.nodeId).speakerCharacterId, isNull);
    expect(
      identity(store.node(chat, path.last.nodeId).extra)['speakerCharacterId'],
      'selected-id',
      reason: 'The real canonical field is cleared while imported provenance still has its former value.',
    );
    final clearedFiles = codec.exportChat(store, chat);
    final cleared = clearedFiles.single;
    expect(identity(cleared.messages.first['extra']).containsKey('speakerCharacterId'), isFalse);
    expect(identity(cleared.messages.last['extra']).containsKey('speakerCharacterId'), isFalse);
    final clearedInfos = cleared.messages.last['swipe_info']! as List<Object?>;
    expect(identity(_map(clearedInfos.first)['extra'])['speakerCharacterId'], 'inactive-id');
    expect(identity(_map(clearedInfos.last)['extra']).containsKey('speakerCharacterId'), isFalse);
    expect(identity(_map(clearedInfos.first)['extra'])['future'], {'keep': 2});
    expect(identity(cleared.messages.last['extra'])['future'], {'keep': 3});
    expect(_map(cleared.messages.last['extra'])['vendor'], [3, null]);
    expect(
      identity(store.node(chat, path.last.nodeId).extra)['speakerCharacterId'],
      'selected-id',
      reason: 'Export must not mutate stored provenance.',
    );

    final copy = load(clearedFiles);
    final copiedPath = store.path(copy);
    expect(copiedPath.map((message) => message.speakerCharacterId), [null, null]);
    expect(store.children(copy, copiedPath.first.nodeId).map((node) => node.message.speakerCharacterId), [
      'inactive-id',
      null,
    ]);
    final again = codec.exportChat(store, copy).single;
    expect(identity(again.messages.last['extra']).containsKey('speakerCharacterId'), isFalse);
    expect(identity(again.messages.last['extra'])['future'], {'keep': 3});
  });

  test('prepared long trees preserve physical states, inactive swipes and round trips', () async {
    final plan = await codec.prepareBatchAsync([
      _document('prepared-long', [
        for (var index = 0; index < 45; index++)
          {
            ..._row('entry $index', swipes: index == 19 ? ['entry 19', 'side entry 19'] : null),
            'variables': [
              {'slot': index},
              if (index == 19) {'slot': 190},
            ],
          },
      ]),
    ]);
    expect(store.listChats(), isEmpty);
    final chat = codec.commitBatch(store, characterId: 'card', plan: plan).chatIds.single;
    final nodes = store.allNodes(chat);
    expect(nodes, hasLength(46));
    for (final node in nodes) {
      final text = node.message.text;
      final slot = text.startsWith('side ') ? 190 : int.parse(text.split(' ').last);
      expect(store.nodeState(chat, node.message.nodeId)['messageVariables'], {'slot': slot});
    }
    final side = store.search('side', chatId: chat).single;
    expect(side.text, 'side entry 19');
    store.selectNode(chat, side.nodeId);
    expect(store.path(chat), hasLength(20));
    expect(store.path(chat).last.nodeId, side.nodeId);
    final restored = load(codec.exportChat(store, chat));
    expect(_tree(store, restored), _tree(store, chat));
  });

  test('a 2005-node chain imports and exports without recursive tree traversal', () {
    final chat = load([
      _document('long', [for (var index = 0; index < 2005; index++) _row('line $index')]),
    ]);
    expect(store.allNodes(chat), hasLength(2005));
    expect(store.node(chat, store.chat(chat).currentLeafId!).depth, 2005);
    final files = codec.exportChat(store, chat);
    expect(files, hasLength(1));
    expect(files.single.messages, hasLength(2005));
    expect(files.single.messages.first['mes'], 'line 0');
    expect(files.single.messages.last['mes'], 'line 2004');
  });
}

StChatDocument _document(
  String name,
  List<Map<String, Object?>> messages, {
  Map<String, Object?> metadata = const {},
  Map<String, Object?> header = const {},
}) => StChatDocument(
  fileName: name,
  header: {'user_name': 'unused', 'character_name': 'unused', ...header, 'chat_metadata': metadata},
  messages: messages,
);

Map<String, Object?> _row(
  String text, {
  String name = 'Alice',
  bool user = false,
  bool hidden = false,
  List<String>? swipes,
  int selected = 0,
}) => {
  'name': name,
  'is_user': user,
  'is_system': hidden,
  'send_date': _time.toIso8601String(),
  'mes': text,
  'swipes': ?swipes,
  if (swipes != null) 'swipe_id': selected,
};

Map<String, Object?> _map(Object? value) =>
    value is Map<String, Object?> ? jsonDecode(jsonEncode(value)) as Map<String, Object?> : {};

Map<String, Object?> _state(ChatStore store, String chat, StoredNode node) {
  final direct = _map(node.extra['dshgo'])['tavernState'];
  return (direct is Map<String, Object?> ? _map(direct) : store.nodeState(chat, node.message.nodeId))
    ..remove('chatJsonlSourceFile')
    ..remove('stChatId')
    ..remove('stChatIdHash');
}

Map<String, Object?> _tree(ChatStore store, String chat) {
  final nodes = store.allNodes(chat);
  final codes = <String, String>{};
  for (final node in nodes) {
    final parent = node.message.parentId;
    codes[node.message.nodeId] = '${parent == null ? '' : '${codes[parent]}/'}${node.message.siblingIndex}';
  }
  final records = <Map<String, Object?>>[];
  for (final node in nodes) {
    final message = node.message;
    final unknown = _map(node.original)
      ..removeWhere(
        (key, _) => const {
          'name',
          'is_user',
          'is_system',
          'mes',
          'send_date',
          'swipes',
          'swipe_id',
          'swipe_info',
          'variables',
          'extra',
        }.contains(key),
      );
    final extra = _map(node.extra)
      ..remove('branches')
      ..remove('bookmark_link')
      ..remove('reasoning');
    final dshgo = _map(extra['dshgo'])..remove('tavernState');
    final own = _map(dshgo['chatJsonl']);
    for (final key in [
      'version',
      'nodeId',
      'selectedChildId',
      'message',
      'text',
      'role',
      'hidden',
      'usage',
      'at',
      'hasMessageVariables',
      'sourceHeader',
    ]) {
      own.remove(key);
    }
    if (own.isEmpty) {
      dshgo.remove('chatJsonl');
    } else {
      dshgo['chatJsonl'] = own;
    }
    if (dshgo.isEmpty) {
      extra.remove('dshgo');
    } else {
      extra['dshgo'] = dshgo;
    }
    records.add({
      'path': codes[message.nodeId],
      'choice': codes[node.selectedChildId],
      'role': message.role.name,
      'name': message.speaker,
      'text': message.text,
      'hidden': message.hidden,
      'reasoning': message.reasoning,
      'at': message.at.toIso8601String(),
      'unknown': unknown,
      'extra': extra,
      'state': _state(store, chat, node),
      'usage': message.usage == null
          ? null
          : {
              'prompt': message.usage!.promptTokens,
              'completion': message.usage!.completionTokens,
              'cache': message.usage!.cacheHitTokens,
              'model': message.usage!.model,
            },
    });
  }
  records.sort((first, second) => (first['path'] as String).compareTo(second['path'] as String));
  return {
    'nodes': records,
    'root': codes[store.chat(chat).selectedRootId],
    'leaf': codes[store.chat(chat).currentLeafId],
  };
}
