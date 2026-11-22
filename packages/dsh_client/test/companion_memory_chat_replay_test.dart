// Frozen proposals exercise production storage, selection and SDK HTTP. The
// loopback peer acknowledges wire delivery; it does not run an engine/model.
import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

// The existing prompt-commit suite uses this same Flutter-free compiler.
// ignore: avoid_relative_lib_imports
import '../../../app/lib/companion/companion_context.dart';
import 'companion_memory_flow_test.dart' as fixture;

MemoryRow _mergeProposal(MemoryMergeBatch batch, MemoryRow target, MemoryRow from) => {
  'schema_version': 2,
  'batch_id': batch.id,
  'completion': 'complete',
  'operations': <MemoryRow>[
    {
      'op': 'merge',
      'target_id': target['id'],
      'expected_row_rev': target['row_rev'],
      'from': <MemoryRow>[
        {'id': from['id'], 'expected_row_rev': from['row_rev']},
      ],
      'text': target['text'],
      'evidence': <MemoryRow>[
        for (final row in [target, from])
          for (final proof in (row['evidence'] as List).cast<MemoryRow>())
            {'message_id': proof['message_id'], 'quote': proof['quote']},
      ],
    },
  ],
};

void main() {
  late Directory directory;
  late CompanionMemoryStore store;
  late HttpServer server;
  late DshClient client;
  final calls = <({String method, String path, String body})>[];
  final now = DateTime.utc(2026, 11, 20, 2);
  var nextId = 0;
  var nextRequest = 0;
  const session = 'replay-chat';
  const instance = 'replay-bridge';

  void open() {
    store = CompanionMemoryStore(
      sqlite3.open('${directory.path}/memory.sqlite'),
      nowMilliseconds: () => now.millisecondsSinceEpoch,
      createId: () => '00000000-0000-4000-8000-${(++nextId).toString().padLeft(12, '0')}',
    );
  }

  void reopen() {
    store.close();
    open();
  }

  MemoryRow source(String id, String text, {String scope = 'real'}) => store.submitMessage(
    id: id,
    sessionId: session,
    text: text,
    role: 'user',
    scope: scope,
    saidAtUtc: now.millisecondsSinceEpoch,
    offsetMinutes: 480,
  );

  void extract(List<MemoryRow> operations) {
    final batch = store.nextBatch(forceTail: true, estimateTokens: estimateCompanionMemoryTokens)!;
    expect(store.commitExtraction(batch, fixture.parsed(batch, operations)), isTrue);
  }

  Future<MemoryRow> send(String input) async {
    final before = calls.length;
    final cards = store.cards();
    final archive = store.archive;
    final selected = selectMemoryContext(
      cards,
      input: input,
      nowMs: now.millisecondsSinceEpoch,
      controlRevision: archive['control_revision'] as int,
      explicitTopicIds: explicitMemoryTopics(input, cards),
    );
    final cap = (await client.companionPromptCapability(session))!;
    const profile = CompanionContextProfile(name: '小露');
    final plan = companionFullContextPlan(
      text: input,
      sessionId: session,
      requestId: 'chat-${++nextRequest}',
      profile: profile,
      acknowledgedProfile: profile.fingerprint,
      supported: true, // A decoded capability exists only for supported=true.
      instanceId: cap.instanceId,
      profileRevision: cap.profileRevision,
      now: now,
      memoryMode: cap.memoryMode,
      phoneMemory: {
        'archiveId': archive['id'],
        'controlRevision': selected.controlRevision,
        'historyAfterSeq': archive['history_after_seq'],
        'block': selected.block,
      },
    );
    await client.prepareCompanionPromptContext(plan.update!);
    expect(await client.prompt(plan.sessionId, plan.text, requestId: plan.requestId), plan.requestId);
    final sent = calls.sublist(before);
    expect(sent.map((call) => (call.method, call.path)), [
      ('GET', '$dshGoCompanionPath/prompt-context'),
      ('POST', '$dshGoCompanionPath/prompt-context'),
      ('POST', '/api/session/prompt'),
    ]);
    final prepared = jsonDecode(sent[1].body) as MemoryRow;
    expect(prepared, plan.update);
    expect(prepared['requestId'], plan.requestId);
    expect(prepared.containsKey('profile'), isFalse);
    expect(prepared.containsKey('query'), isFalse);
    final phone = prepared['phoneMemory'] as MemoryRow;
    expect(phone['archiveId'], archive['id']);
    expect(phone['controlRevision'], archive['control_revision']);
    expect(phone['historyAfterSeq'], archive['history_after_seq']);
    expect(utf8.encode(phone['block'] as String), utf8.encode(selected.block));
    final block = jsonDecode(phone['block'] as String) as MemoryRow;
    expect((block['items'] as List).map((item) => (item as Map)['id']), selected.ids);
    final rpc = jsonDecode(sent[2].body) as MemoryRow;
    expect(rpc['method'], 'session/prompt');
    final request = ((rpc['payload'] as Map)['args'] as Map)['request'] as Map;
    expect(request['sessionId'], session);
    expect(request['requestId'], plan.requestId);
    expect(request['content'], [
      {'type': 'text', 'text': input},
    ], reason: 'the ordinary user line contains no hidden memory copy');
    return block;
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('companion-memory-chat-replay-');
    nextId = 0;
    nextRequest = 0;
    calls.clear();
    open();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      expect(request.headers.value('cookie'), 'dsh-auth-replay=synthetic');
      final raw = await utf8.decoder.bind(request).join();
      calls.add((method: request.method, path: request.uri.path, body: raw));
      final Object response;
      if (request.uri.path == '$dshGoCompanionPath/prompt-context') {
        response = {
          'v': 1,
          'supported': true,
          'instanceId': instance,
          'sessionId': session,
          'profileRevision': 1,
          'memoryMode': 'phone',
          'phoneMemory': true,
        };
      } else if (request.uri.path == '/api/session/prompt') {
        final envelope = jsonDecode(raw) as MemoryRow;
        response = {
          'type': 'server-response',
          'rpcId': envelope['rpcId'],
          'result': {'ok': true},
        };
      } else {
        request.response.statusCode = 404;
        response = {'error': 'unexpected replay path'};
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(response));
      await request.response.close();
    });
    final uri = Uri.parse('http://127.0.0.1:${server.port}');
    client = DshClient(
      DshConnection(
        uri,
        cookie: DshCookie(name: 'dsh-auth-replay', value: 'synthetic', authority: uri.authority),
      ),
    );
  });
  tearDown(() async {
    await client.close();
    await server.close(force: true);
    store.close();
    await directory.delete(recursive: true);
  });

  test('fixture 13 reopened merge keeps daily and birthday conditions in actual SDK chat requests', () async {
    final first = source('daily-a', '我平常喝拿铁不加糖。');
    final second = source('daily-b', '拿铁我平时都选无糖。');
    final birthday = source('birthday', '生日这杯拿铁，我想喝半糖。');
    extract([
      {
        ...fixture.create(first, text: '你平常点无糖拿铁。', keywords: ['拿铁']),
        'kind': 'preference',
      },
      {
        ...fixture.create(second, text: '平时你喝拿铁不加糖。', keywords: ['拿铁']),
        'kind': 'preference',
      },
      {
        ...fixture.create(birthday, text: '你生日这杯拿铁要半糖。', keywords: ['拿铁']),
        'kind': 'preference',
      },
    ]);
    final batch = store.nextMergeBatch(estimateTokens: estimateCompanionMemoryTokens)!;
    final target = batch.rows.singleWhere((row) => row['text'] == '你平常点无糖拿铁。');
    final from = batch.rows.singleWhere((row) => row['text'] == '平时你喝拿铁不加糖。');
    final proposed = _mergeProposal(batch, target, from);
    final wrong = jsonDecode(jsonEncode(proposed)) as MemoryRow;
    ((wrong['operations'] as List).single as Map)['text'] = '以后所有日子都加糖。';
    expect(() => parseMergeProposal(jsonEncode(wrong), batch), throwsFormatException);
    expect(store.commitMerge(batch, parseMergeProposal(jsonEncode(proposed), batch)), isTrue);
    reopen();
    expect(store.cards(), hasLength(2));
    final merged = store.cards().singleWhere((row) => row['id'] == target['id']);
    expect(
      (merged['evidence'] as List).map((proof) => (proof as Map)['message_id']),
      unorderedEquals(['daily-a', 'daily-b']),
    );
    for (final input in ['我平常喝拿铁，该怎么选？', '生日这杯拿铁呢？']) {
      final block = await send(input);
      final items = (block['items'] as List).cast<MemoryRow>();
      expect(items.map((item) => item['id']).toSet(), hasLength(2));
      expect(items.map((item) => item['text']), unorderedEquals(['你平常点无糖拿铁。', '你生日这杯拿铁要半糖。']));
      expect(items.any((item) => item['id'] == from['id']), isFalse);
    }
    // Supplying both conditional sentences does not prove a model used them.
  });

  test('fixture 14 deleted source never topic and story stay out of the next SDK chat after reopen', () async {
    final original = source('deleted-source', '酸奶我只买原味。');
    final lesson = source('lesson', '我周五上琴课。');
    extract([
      fixture.create(original, text: '你买酸奶只选原味。', keywords: ['酸奶']),
      fixture.create(original, text: '酸奶你只买原味的。', keywords: ['酸奶']),
      fixture.create(lesson, keywords: ['琴课']),
    ]);
    final batch = store.nextMergeBatch(estimateTokens: estimateCompanionMemoryTokens)!;
    final late = parseMergeProposal(jsonEncode(_mergeProposal(batch, batch.rows.first, batch.rows.last)), batch);
    final deletedIds = batch.rows.map((row) => row['id']).toSet();
    store.deleteMessage(id: 'deleted-source', expectedSourceRev: 1);
    expect(store.commitMerge(batch, late), isFalse);
    final forbidden = store.cards().single;
    final control = source('never-command', '别再提琴课');
    store.applyControl(topicIds: [forbidden['topic_id'] as String], kind: 'never', controlMessageId: 'never-command');
    source('roleplay', '故事里的我开了茶馆，是茶馆老板。', scope: 'story');
    final allowed = source('new-fact', '我正在学长笛。');
    extract([
      fixture.create(allowed, text: '你正在学长笛。', keywords: ['长笛']),
    ]);
    reopen();
    expect(store.commitMerge(batch, late), isFalse);
    expect(store.cards().any((row) => deletedIds.contains(row['id'])), isFalse);
    expect(store.messages().any((row) => row['id'] == 'deleted-source'), isFalse);
    expect(store.cards().singleWhere((row) => row['id'] == forbidden['id'])['topic_mode'], 'never');
    final story = store.messages().singleWhere((row) => row['id'] == 'roleplay');
    expect(story['text'], '故事里的我开了茶馆，是茶馆老板。');
    expect(story['first_seq'] as int, greaterThan(control['first_seq'] as int));
    expect(store.messages(forModel: true).map((row) => row['id']), ['new-fact']);
    final block = await send('今天碰巧听到酸奶、琴课、茶馆和长笛这些词。');
    expect((block['items'] as List).map((item) => (item as Map)['text']), ['你正在学长笛。']);
    final actualBodies = calls.where((call) => call.method == 'POST').map((call) => call.body).join('\n');
    for (final absent in [
      'deleted-source',
      '原味',
      '我周五上琴课',
      'roleplay',
      '茶馆老板',
      ...deletedIds.cast<String>(),
      forbidden['id'] as String,
    ]) {
      expect(actualBodies, isNot(contains(absent)), reason: absent);
    }
  });
}
