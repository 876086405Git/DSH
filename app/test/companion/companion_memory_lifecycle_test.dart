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

class _DelayedRoute implements CompanionMemoryTransport {
  final started = Completer<void>();
  final release = Completer<void>();
  int calls = 0;
  bool cancellationSeen = false;
  @override
  String get provider => 'deepseek';
  @override
  String get model => 'deepseek-flash';
  @override
  bool get configured => true;
  @override
  Future<CompanionAuxiliaryReply> call({
    required String requestId,
    required String category,
    required String system,
    required String input,
    required int maxTokens,
    required Future<void> cancelled,
    required void Function() onDispatchUncertain,
    required void Function() onSent,
    required void Function(Map<String, Object?>) onUsage,
  }) async {
    calls++;
    onSent();
    if (!started.isCompleted) started.complete();
    unawaited(
      cancelled.then((_) {
        cancellationSeen = true;
      }),
    );
    await release.future;
    onUsage(_usage);
    final batch = jsonDecode(input) as Map;
    return CompanionAuxiliaryReply(
      text: jsonEncode({
        'schema_version': 2,
        'batch_id': batch['batch_id'],
        'operations': [],
        'completion': 'complete',
        'covered_message_ids': [for (final row in batch['source'] as List) (row as Map)['id']],
      }),
      terminal: 'complete',
      complete: true,
    );
  }
}

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
    owner.enter(room, transport: () => route, estimateTokens: estimateCompanionMemoryTokens);
    final active = owner.extract(room, forceTail: true);
    await route.started.future;
    owner.dispose();
    expect(store.closed.isCompleted, isFalse);
    route.release.complete();
    expect(await active, CompanionMemoryWork.stale);
    await store.closed.future;
    expect(route.cancellationSeen, isTrue);
    expect(store.receiptsAtClose, hasLength(1));
    final raw = store.receiptsAtClose.single['raw_usage']! as Map;
    expect(raw['final_usage'], _usage['final_usage']);
  });

  test('changing rooms never starts a second worker until the first has settled', () async {
    final store = _ClosingStore();
    final owner = _owner(store);
    final a = _DelayedRoute(), b = _DelayedRoute();
    final roomA = Object(), roomB = Object();
    _source(store);
    owner.enter(roomA, transport: () => a, estimateTokens: estimateCompanionMemoryTokens);
    final old = owner.extract(roomA, forceTail: true);
    await a.started.future;
    owner.enter(roomB, transport: () => b, estimateTokens: estimateCompanionMemoryTokens);
    expect(await owner.extract(roomB, forceTail: true), CompanionMemoryWork.idle);
    expect(b.calls, 0);
    a.release.complete();
    expect(await old, CompanionMemoryWork.stale);
    expect(await owner.extract(roomA, forceTail: true), CompanionMemoryWork.idle);
    final fresh = owner.extract(roomB, forceTail: true);
    await b.started.future;
    b.release.complete();
    expect(await fresh, CompanionMemoryWork.committed);
    expect(store.requests(), hasLength(2));
    expect(store.messages().single['id'], 'source');
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
