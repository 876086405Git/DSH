// Real SQLite owner, production usage SDK, and a loopback HTTP transport.
// Responses are protocol fixtures; no model, vendor bill or full engine runs.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/companion/companion_local.dart';
import 'package:dsh_app/companion/companion_memory.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

const _at = 1795260000123;
const _host = 'local:test-owner';

class _Store extends CompanionMemoryStore {
  _Store(super.database, int Function() now) : super(nowMilliseconds: now);
  final closed = Completer<void>();
  List<MemoryRow> atClose = [];
  @override
  void close() {
    atClose = requests();
    super.close();
    closed.complete();
  }
}

class _Fixture {
  int now = _at;
  late final store = _Store(sqlite3.openInMemory(), () => now);
  late final owner = CompanionMemoryOwner(
    store,
    CompanionLocal.at(Directory('/unused-usage-owner')),
    nowMilliseconds: () => now,
  );
  late final HttpServer server;
  late final DshClient client;
  final queries = <Map<String, String>>[];
  final methods = <String>[];
  final started = Completer<void>();
  int status = 200;
  bool disposed = false;
  late Future<Map<String, Object?>> Function(Map<String, String>) answer;

  Future<void> open() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    client = DshClient(DshConnection(Uri.parse('http://127.0.0.1:${server.port}')));
    server.listen((request) async {
      methods.add(request.method);
      final query = Map<String, String>.from(request.uri.queryParameters);
      queries.add(query);
      expect(request.uri.path, '/dsh-go/v1/companion/usage');
      if (!started.isCompleted) started.complete();
      final response = await answer(query);
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(response));
      await request.response.close();
    });
    addTearDown(() async {
      await server.close(force: true);
      await client.close();
      disposeOwner();
      await store.closed.future;
    });
  }

  void disposeOwner() {
    if (disposed) return;
    disposed = true;
    owner.dispose();
  }

  MemoryRow delivery([String id = 'request']) => store.rememberHostChatDelivery(
    hostKey: _host,
    instanceId: 'original-instance',
    sessionId: 'old-session',
    requestId: id,
    archiveId: store.archive['id']! as String,
    controlRevision: store.archive['control_revision']! as int,
    historyAfterSeq: store.archive['history_after_seq']! as int,
    observedAt: now,
  );

  Future<void> pull() => owner.refreshHostChatUsage(client, _host);
}

Map<String, Object?> _snapshot(MemoryRow delivery, {String state = 'settled', int revision = 3}) {
  final running = state == 'running';
  return {
    'v': 1,
    'instanceId': delivery['instance_id'],
    'sessionId': delivery['session_id'],
    'requestId': delivery['request_id'],
    'binding': {
      'archiveId': delivery['archive_id'],
      'controlRevision': delivery['control_revision'],
      'historyAfterSeq': delivery['history_after_seq'],
    },
    'state': state,
    'complete': !running,
    'revision': revision,
    'gaps': [],
    'observedAdapterCalls': 1,
    'activeCalls': running ? 1 : 0,
    'physicalRequests': 1,
    'receipts': [
      {
        'receiptId': 'physical-${delivery['request_id']}',
        'callId': 'call-${delivery['request_id']}',
        'revision': revision,
        'requestIds': [delivery['request_id']],
        'provider': 'deepseek',
        'model': 'deepseek-flash',
        'phase': running ? 'active' : 'finished',
        'observation': 'fetch-invoked',
        'dispatched': true,
        'dispatchAtMs': _at - 1200,
        'handoffAtMs': _at - 1300,
        'physicalRequests': 1,
        'terminal': running ? 'incomplete' : 'complete',
        'complete': !running,
        'httpStatus': 200,
        'errorCode': null,
        'usage': {
          'provider': 'deepseek',
          'model': 'deepseek-flash',
          'start_usage': {'input_tokens': 90, 'vendor_extra': 7},
          'final_usage': {'input_tokens': 9, 'cache_read_input_tokens': 4, 'output_tokens': 3, 'vendor_extra': 11},
          'start_event': 'message_start',
          'final_event': 'message_delta',
          'usage_semantics': 'cumulative',
          'input_uncached': 9,
          'input_cache_read': 4,
          'input_cache_write': null,
          'output_tokens': 3,
          'stop_reason': running ? null : 'end_turn',
          'terminal': running ? 'incomplete' : 'complete',
          'complete': !running,
          'http_status': 200,
        },
      },
    ],
  };
}

Map<String, Object?> _unknown(MemoryRow delivery, {String instance = 'new-instance'}) => {
  'v': 1,
  'instanceId': instance,
  'sessionId': delivery['session_id'],
  'requestId': delivery['request_id'],
  'binding': null,
  'state': 'unknown',
  'complete': false,
  'revision': 0,
  'gaps': [if (instance != delivery['instance_id']) 'instance-changed' else 'missing-root'],
  'observedAdapterCalls': 0,
  'activeCalls': 0,
  'physicalRequests': null,
  'receipts': [],
};

void main() {
  test('pull uses the saved instance and old Session, retaining nullable raw fields exactly once', () async {
    final fixture = _Fixture();
    final saved = fixture.delivery();
    fixture.answer = (_) async => _snapshot(saved);
    await fixture.open();
    await fixture.pull();
    await fixture.pull();
    expect(fixture.methods, ['GET']);
    expect(fixture.queries.single, {
      'instanceId': 'original-instance',
      'sessionId': 'old-session',
      'requestId': 'request',
    });
    final receipt = fixture.store.requests().single;
    expect(receipt['input_uncached'], 9);
    expect(receipt['input_cache_read'], 4);
    expect(receipt['input_cache_write'], isNull);
    expect(receipt['output_tokens'], 3);
    expect(receipt['estimated_cny'], isNull);
    expect((receipt['raw_usage'] as Map)['start_usage'], {'input_tokens': 90, 'vendor_extra': 7});
    expect(((receipt['raw_usage'] as Map)['final_usage'] as Map)['vendor_extra'], 11);
    expect(fixture.store.pendingHostChatDeliveries(_host), isEmpty);
  });

  test('same-host readers coalesce and a late receipt stays with its original control binding', () async {
    final fixture = _Fixture();
    final saved = fixture.delivery();
    final release = Completer<void>();
    fixture.answer = (_) async {
      await release.future;
      return _snapshot(saved);
    };
    await fixture.open();
    final first = fixture.pull();
    await fixture.started.future;
    final second = fixture.pull();
    expect(identical(first, second), isTrue);
    fixture.store.saveManual(
      const CompanionMemory(id: '11111111-1111-4111-8111-111111111111', text: '新的现况'),
      expectedRowRev: null,
      currentValueChange: true,
      realityKnown: true,
    );
    expect(fixture.store.archive['control_revision'], isNot(saved['control_revision']));
    release.complete();
    await first;
    expect(fixture.methods, ['GET']);
    expect(fixture.store.requests(), hasLength(1));
    expect(fixture.store.cards().single['text'], '新的现况');
    expect(fixture.store.hostChatDeliveries().single['control_revision'], saved['control_revision']);
  });

  test('unknown after an active receipt keeps evidence and backs off without adopting the new instance', () async {
    final fixture = _Fixture();
    final saved = fixture.delivery();
    fixture.answer = (_) async => _snapshot(saved, state: 'running', revision: 7);
    await fixture.open();
    await fixture.pull();
    fixture.now += 15000;
    fixture.answer = (_) async => _unknown(saved);
    await fixture.pull();
    final row = fixture.store.hostChatDeliveries().single;
    expect(row['state'], 'unknown');
    expect(row['snapshot_revision'], 7);
    expect(row['instance_id'], 'original-instance');
    expect(row['unknown_instance_id'], 'new-instance');
    expect(fixture.store.requests().single['output_tokens'], 3);
    fixture.now += 5 * 60000 - 1;
    await fixture.pull();
    expect(fixture.queries, hasLength(2));
    fixture.now++;
    await fixture.pull();
    expect(fixture.queries, hasLength(3));
    expect(fixture.queries.last['instanceId'], 'original-instance');
    expect(fixture.methods.every((method) => method == 'GET'), isTrue);
  });

  test('old route and HTTP failure do not release a delivery or manufacture free usage', () async {
    final fixture = _Fixture();
    fixture.delivery();
    fixture.status = 404;
    fixture.answer = (_) async => {
      'error': {'code': 'companion/not-found'},
    };
    await fixture.open();
    await fixture.pull();
    expect(fixture.store.hostChatDeliveries().single['state'], 'pending');
    expect(fixture.store.requests(), isEmpty);
    fixture.now += 299999;
    await fixture.pull();
    expect(fixture.queries, hasLength(1));
    fixture.now++;
    fixture.status = 503;
    fixture.answer = (_) async => {
      'error': {'code': 'companion/usage-unavailable', 'message': 'fixture'},
    };
    await fixture.pull();
    expect(fixture.queries, hasLength(2));
    expect(fixture.store.hostChatDeliveries().single['state'], 'pending');
    expect(fixture.store.requests(), isEmpty);
  });

  test('owner disposal waits for an already issued GET to import before SQLite closes', () async {
    final fixture = _Fixture();
    final saved = fixture.delivery();
    final release = Completer<void>();
    fixture.answer = (_) async {
      await release.future;
      return _snapshot(saved);
    };
    await fixture.open();
    final read = fixture.pull();
    await fixture.started.future;
    fixture.disposeOwner();
    expect(fixture.store.closed.isCompleted, isFalse);
    release.complete();
    await read;
    await fixture.store.closed.future;
    expect(fixture.store.atClose.single['output_tokens'], 3);
  });

  test('one opportunity visits every pending delivery', () async {
    final fixture = _Fixture();
    final rows = {for (var i = 0; i < 5; i++) 'request-$i': fixture.delivery('request-$i')};
    fixture.answer = (query) async => _snapshot(rows[query['requestId']]!);
    await fixture.open();
    await fixture.pull();
    expect(fixture.queries, hasLength(5));
    expect(fixture.store.requests(), hasLength(5));
    expect(fixture.store.pendingHostChatDeliveries(_host), isEmpty);
  });

  test('reopening the actual SQLite file retains a pending root without a new model request', () async {
    final root = Directory.systemTemp.createTempSync('companion-pending-usage');
    addTearDown(() => root.deleteSync(recursive: true));
    final first = CompanionMemoryStore(sqlite3.open('${root.path}/memory.sqlite'), nowMilliseconds: () => _at);
    final saved = first.rememberHostChatDelivery(
      hostKey: _host,
      instanceId: 'old',
      sessionId: 'old-session',
      requestId: 'unsettled',
      archiveId: first.archive['id']! as String,
      controlRevision: 0,
      historyAfterSeq: 0,
      observedAt: _at,
    );
    first.close();
    final reopened = CompanionMemoryStore(
      sqlite3.open('${root.path}/memory.sqlite'),
      nowMilliseconds: () => _at + 60000,
    );
    addTearDown(reopened.close);
    expect(reopened.pendingHostChatDeliveries(_host).single['id'], saved['id']);
    expect(reopened.pendingHostChatDeliveries(_host).single['instance_id'], 'old');
    expect(reopened.requests(), isEmpty);
  });
}
