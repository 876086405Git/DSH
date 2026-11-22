// Actual SQLite, worker, and light SSE cleanup. Only provider bytes and the
// point at which a transport finishes are controlled by the tests.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/companion/companion_context.dart';
import 'package:dsh_app/companion/companion_light.dart';
import 'package:dsh_app/companion/companion_local.dart';
import 'package:dsh_app/companion/companion_memory.dart';
import 'package:dsh_app/companion/companion_memory_worker.dart';
import 'package:dsh_client/companion.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart';

const _at = 1795260000123;
const _usage = <String, Object?>{
  'provider': 'deepseek',
  'model': 'deepseek-flash',
  'start_usage': {'input_tokens': 90},
  'final_usage': {'input_tokens': 9, 'output_tokens': 3},
  'usage_semantics': 'cumulative',
  'input_uncached': 9,
  'input_cache_read': null,
  'input_cache_write': null,
  'output_tokens': 3,
  'terminal': 'complete',
  'complete': true,
};

class _ClosingStore extends CompanionMemoryStore {
  _ClosingStore() : super(sqlite3.openInMemory(), nowMilliseconds: () => _at);
  final closed = Completer<void>();
  List<MemoryRow> receiptsAtClose = [];
  @override
  void close() {
    receiptsAtClose = requests();
    super.close();
    closed.complete();
  }
}

class _DelayedRoute {
  _DelayedRoute() {
    wire = StreamController<List<int>>(
      onListen: () {
        wire.add(
          _frames([
            {
              'type': 'message_start',
              'message': {'usage': _usage['start_usage']},
            },
            {
              'type': 'content_block_delta',
              'index': 0,
              'delta': {'type': 'text_delta', 'text': 'Still considering.'},
            },
          ]),
        );
        started.complete();
      },
      onCancel: () {
        cancelling.complete();
        return release.future;
      },
    );
    transport = CompanionLightMemoryTransport(
      apiKey: () => 'fixture',
      client: () => MockClient.streaming((request, body) async {
        calls++;
        final sent = jsonDecode(await utf8.decoder.bind(body).join()) as MemoryRow;
        expect((sent['tools'] as List).map((tool) => (tool as Map)['name']), contains('remember'));
        inputs.add(jsonDecode(((sent['messages'] as List).first as Map)['content'] as String) as MemoryRow);
        return http.StreamedResponse(wire.stream, 200, headers: {'content-type': 'text/event-stream; charset=utf-8'});
      }),
    );
    addTearDown(() async {
      if (!release.isCompleted) release.complete();
      if (!started.isCompleted) unawaited(wire.stream.drain<void>());
      await wire.close();
    });
  }

  final started = Completer<void>();
  final cancelling = Completer<void>();
  final release = Completer<void>();
  late final StreamController<List<int>> wire;
  late final CompanionLightMemoryTransport transport;
  final inputs = <MemoryRow>[];
  int calls = 0;

  Future<void> finish() async {
    release.complete();
    wire.add(
      _frames([
        {
          'type': 'message_delta',
          'delta': {'stop_reason': 'end_turn'},
          'usage': _usage['final_usage'],
        },
        {'type': 'message_stop'},
      ]),
    );
    await wire.close();
  }
}

List<int> _frames(List<MemoryRow> events) =>
    utf8.encode(events.map((event) => 'data: ${jsonEncode(event)}\n\n').join());

CompanionMemoryOwner _owner(CompanionMemoryStore store) =>
    CompanionMemoryOwner(store, CompanionLocal.at(Directory('/unused-memory-lifecycle')), nowMilliseconds: () => _at);

void _source(CompanionMemoryStore store) => store.submitMessage(
  id: 'source',
  sessionId: store.lightSessionId,
  text: '今天咖啡喝无糖。',
  saidAtUtc: _at,
  offsetMinutes: 480,
);

void main() {
  test('disposal cancels the worker but waits for its late receipt before closing SQLite', () async {
    final store = _ClosingStore();
    final owner = _owner(store);
    final route = _DelayedRoute();
    final room = Object();
    _source(store);
    owner.enter(room, transport: () => route.transport, estimateTokens: estimateCompanionMemoryTokens);
    final active = owner.extract(room, forceTail: true, offsetMinutes: 480);
    await route.started.future;
    owner.dispose();
    await route.cancelling.future;
    expect(store.closed.isCompleted, isFalse);
    expect(store.requests().single['state'], 'sent');
    route.release.complete();
    expect(await active, CompanionMemoryWork.stale);
    await store.closed.future;
    expect(store.receiptsAtClose, hasLength(1));
    expect(store.receiptsAtClose.single['state'], 'finished');
    final raw = store.receiptsAtClose.single['raw_usage']! as Map;
    expect(raw['terminal'], 'cancelled');
    expect(raw['complete'], isFalse);
    expect(raw['final_usage'], isNull, reason: 'cancelled real SSE does not invent unseen final provider usage');
    expect(raw['output_tokens'], isNull);
  });

  test('changing rooms never starts a second worker until the first has settled', () async {
    final store = _ClosingStore();
    final owner = _owner(store);
    final a = _DelayedRoute(), b = _DelayedRoute();
    final roomA = Object(), roomB = Object();
    _source(store);
    owner.enter(roomA, transport: () => a.transport, estimateTokens: estimateCompanionMemoryTokens);
    final old = owner.extract(roomA, forceTail: true, offsetMinutes: 480);
    await a.started.future;
    owner.enter(roomB, transport: () => b.transport, estimateTokens: estimateCompanionMemoryTokens);
    await a.cancelling.future;
    store.submitMessage(
      id: 'source-two',
      sessionId: store.lightSessionId,
      text: '今天还想聊聊练琴。',
      saidAtUtc: _at,
      offsetMinutes: 480,
    );
    expect(await owner.extract(roomB, forceTail: true, offsetMinutes: 480), CompanionMemoryWork.idle);
    expect(b.calls, 0);
    a.release.complete();
    expect(await old, CompanionMemoryWork.stale);
    expect(await owner.extract(roomA, forceTail: true, offsetMinutes: 480), CompanionMemoryWork.idle);
    final fresh = owner.extract(roomB, forceTail: true, offsetMinutes: 480);
    await b.started.future;
    expect((b.inputs.single['sources'] as List).map((row) => (row as Map)['id']), ['source-two']);
    await b.finish();
    expect(await fresh, CompanionMemoryWork.committed);
    expect(store.requests(), hasLength(2));
    expect(store.messages().map((row) => row['id']), ['source', 'source-two']);
    expect(store.messages().first['extraction_state'], 'skipped');
    expect(store.messages().last['extraction_state'], 'done');
    expect(store.cards(), isEmpty);
    owner.dispose();
    await store.closed.future;
  });

  test('ordinary light chat drains its real SSE finally receipt before owner disposal closes SQLite', () async {
    final store = _ClosingStore();
    final owner = _owner(store);
    final releaseCancel = Completer<void>();
    final body = StreamController<List<int>>(onCancel: () => releaseCancel.future);
    final client = MockClient.streaming((_, _) async => http.StreamedResponse(body.stream, 200));
    final id = store.reserveRequest(
      category: 'chat',
      provider: 'deepseek',
      model: companionLightModel,
      inputTokens: 100,
      outputTokens: 800,
    )!;
    final drained = Completer<void>(), received = Completer<void>();
    owner.retainReceipt(drained.future);
    final subscription =
        streamCompanionReply(
          client: client,
          apiKey: 'fixture',
          system: 'fixture',
          lines: const [CompanionLine.user('原话')],
          onSent: () => store.markRequestSent(id),
          onUsage: (usage) {
            store.recordUsage(id, usage.toJson());
            store.finishRequest(id, terminal: usage.terminal);
          },
        ).listen((_) {
          if (!received.isCompleted) received.complete();
        });
    body.add(
      utf8.encode(
        'data: {"type":"message_start","message":{"usage":{"input_tokens":90}}}\n\n'
        'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"半句"}}\n\n',
      ),
    );
    await received.future;
    final cancelled = subscription.cancel().whenComplete(drained.complete);
    owner.dispose();
    expect(store.closed.isCompleted, isFalse);
    releaseCancel.complete();
    await cancelled;
    await store.closed.future;
    final raw = store.receiptsAtClose.single['raw_usage']! as Map;
    expect(raw['start_usage'], {'input_tokens': 90});
    expect(raw['final_usage'], isNull);
    expect(raw['complete'], isFalse);
    expect(raw['output_tokens'], isNull);
    await body.close();
    client.close();
  });

  test('one path gives one owner across visits, and an ordinary container restart reopens its archive', () async {
    final root = Directory.systemTemp.createTempSync('companion-owner-reopen');
    final first = ProviderContainer();
    final a = await first.read(companionMemoryOwnerProvider(root.absolute.path).future);
    final b = await first.read(companionMemoryOwnerProvider(Directory(root.path).absolute.path).future);
    expect(identical(a, b), isTrue);
    _source(a.store);
    final archive = a.store.archive['id'];
    first.dispose();
    final second = ProviderContainer();
    try {
      final reopened = await second.read(companionMemoryOwnerProvider(root.absolute.path).future);
      expect(reopened.store.archive['id'], archive);
      expect(reopened.store.messages().single['id'], 'source');
    } finally {
      second.dispose();
      root.deleteSync(recursive: true);
    }
  });
}
