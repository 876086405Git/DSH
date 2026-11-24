import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

// The compiler has no Flutter dependency; exercise its output with the actual
// SDK prompt RPC and session/follow decoder on a controlled loopback Host.
// ignore: avoid_relative_lib_imports
import '../../../app/lib/companion/companion_context.dart';
import 'support/fake_dsh.dart';

typedef _Committed = ({SessionLogEvent event, CompanionPromptScope from});

class _Fixture {
  _Fixture(this.host, this.client);
  final FakeDsh host;
  final DshClient client;
  final Object target = Object();
  final records = <Map<String, Object?>>[];
  final received = <_Committed>[];
  late StreamSubscription<DshEvent> subscription;
  late FakeMuxSocket socket;
  late String followId;
  late CompanionPromptScope scope;
  var nextSnapshot = Completer<void>();
  Completer<_Committed>? nextEvent;

  static Future<_Fixture> start() async {
    final host = await FakeDsh.start();
    final client = await DshClient.connect(
      baseUri: host.baseUri,
      token: FakeDsh.token,
      muxOptions: const MuxOptions(autoReconnect: false),
    );
    final f = _Fixture(host, client);
    host.handlers['session/prompt'] = (_) => {'ok': true, 'value': null};
    host.onOpen = (socket, id, endpoint, payload) {
      if (endpoint != 'session/follow') return;
      f.socket = socket;
      f.followId = id;
      socket.item(id, {
        'type': 'snapshot',
        'header': {'version': 4, 'id': 's', 'createdAt': 0, 'isSeeded': false},
        'cursor': f.records.length - 1,
        'records': f.records,
        'hasMore': false,
        'projections': {'asOfSeq': f.records.length - 1, 'values': <String, Object?>{}},
      });
    };
    f.subscription = client
        .watch('s', options: const WatchOptions(includeSyncEvents: true, includeHostEvents: false))
        .listen((event) {
          if (event is SessionSnapshotEvent) {
            f.scope = CompanionPromptScope(
              client: client,
              generation: client.mux.generation!,
              followEpoch: event.followEpoch!,
              sessionScope: f.target,
              instanceId: 'boot',
              sessionId: event.sessionId,
            );
            if (!f.nextSnapshot.isCompleted) f.nextSnapshot.complete();
          } else if (event is SessionLogEvent) {
            // Capture provenance at ingress, before a caller can await or
            // queue UI work. Never re-label this event using a later scope.
            final received = (event: event, from: f.scope);
            f.received.add(received);
            f.nextEvent?.complete(received);
            f.nextEvent = null;
          }
        });
    await f.nextSnapshot.future.timeout(const Duration(seconds: 5));
    return f;
  }

  Future<_Committed> event({
    String type = 'user/message',
    String kind = 'user',
    String requestId = 'chosen-id',
    String role = 'user',
    String text = 'edited while queued',
    Map<String, Object?> source = const {},
  }) {
    final awaited = nextEvent = Completer<_Committed>();
    final frame = <String, Object?>{
      'type': 'event',
      'event': {
        'type': type,
        'seq': records.length,
        'time': 1794111600000 + records.length,
        'data': {
          'id': 'message-${records.length}',
          'role': role,
          'content': [
            {'type': 'text', 'text': text},
          ],
          'source': {'kind': kind, 'rpcId': requestId, ...source},
        },
      },
    };
    records.add(frame);
    socket.item(followId, frame);
    return awaited.future.timeout(const Duration(seconds: 5));
  }

  Future<void> reconnect() async {
    nextSnapshot = Completer<void>();
    client.mux.reconnect();
    await nextSnapshot.future.timeout(const Duration(seconds: 5));
  }

  Future<void> close() async {
    await subscription.cancel();
    await client.close();
    await host.close();
  }
}

void main() {
  late _Fixture f;
  setUp(() async => f = await _Fixture.start());
  tearDown(() async => f.close());

  CompanionPromptScope scope({
    DshClient? client,
    MuxGeneration? generation,
    SessionFollowEpoch? followEpoch,
    Object? sessionScope,
    String instanceId = 'boot',
    String sessionId = 's',
  }) => CompanionPromptScope(
    client: client ?? f.scope.client,
    generation: generation ?? f.scope.generation,
    followEpoch: followEpoch ?? f.scope.followEpoch,
    sessionScope: sessionScope ?? f.scope.sessionScope,
    instanceId: instanceId,
    sessionId: sessionId,
  );

  test('RPC acceptance keeps events; only the exact durable commit yields snapshot ids', () async {
    final now = DateTime.utc(2026, 11, 8, 5);
    final touch = CompanionContextEvent(id: 'touch', kind: 'pet', at: now);
    final feed = CompanionContextEvent(id: 'later-feed', kind: 'feed', at: now.add(const Duration(seconds: 1)));
    const raw = '  我自己输入的文字\n 保留换行和空格。  ';
    final plan = companionFullContextPlan(
      text: raw,
      sessionId: 's',
      requestId: 'chosen-id',
      profile: const CompanionContextProfile(persona: '记得看天气。', name: '小鲸', callMe: '阿周'),
      supported: true,
      instanceId: 'boot',
      now: now,
      events: [touch],
    );
    final receipt = CompanionPromptCommit(scope: f.scope, requestId: plan.requestId, eventIds: plan.eventIds);
    expect(await f.client.prompt(plan.sessionId, plan.text, requestId: plan.requestId), 'chosen-id');
    final payload = f.host.rpcCalls.last['payload'] as Map;
    final request = (payload['args'] as Map)['request'] as Map;
    expect(request['requestId'], plan.requestId);
    expect(request['content'], [
      {'type': 'text', 'text': raw},
    ]);
    expect(plan.update!['profile'], {'persona': '记得看天气。', 'name': '小鲸', 'callMe': '阿周', 'moves': ''});
    expect(f.received, isEmpty, reason: 'A prompt ACK is only inbox acceptance');
    final pending = [touch, feed];
    final queue = await f.event(type: 'inbox/splice');
    expect(receipt.committedEventIds(queue.event, from: queue.from, current: f.scope), isEmpty);
    // Queue editing changes text while the request and physical touch persist.
    final commit = await f.event(text: '用户主动编辑后的原话');
    final ids = receipt.committedEventIds(commit.event, from: commit.from, current: f.scope);
    expect(ids, ['touch']);
    expect(companionConsumeEvents(pending, ids).map((e) => e.id), ['later-feed']);
    // Replay is harmless: consuming the same snapshot ids is idempotent.
    expect(companionConsumeEvents(companionConsumeEvents(pending, ids), ids).map((e) => e.id), ['later-feed']);
    expect(() => ids.add('later-feed'), throwsUnsupportedError);
  });

  test('human kind alone is insufficient: principal, rpcId and message role must match', () async {
    final receipt = CompanionPromptCommit(scope: f.scope, requestId: 'chosen-id', eventIds: ['touch']);
    for (final event in [
      await f.event(kind: 'runtime-context'),
      await f.event(requestId: 'other-id'),
      await f.event(
        source: {
          'principal': {'kind': 'guest'},
        },
      ),
      await f.event(source: {'principal': null}),
      await f.event(role: 'assistant'),
      await f.event(type: 'turn/end'),
    ]) {
      expect(receipt.committedEventIds(event.event, from: event.from, current: f.scope), isEmpty);
    }
    final owner = await f.event();
    expect(receipt.committedEventIds(owner.event, from: owner.from, current: f.scope), ['touch']);
  });

  test('event ingress and current selection both need actual object identities', () async {
    final receipt = CompanionPromptCommit(scope: f.scope, requestId: 'chosen-id', eventIds: ['touch']);
    final event = await f.event();
    final otherClient = DshClient(DshConnection(f.host.baseUri));
    addTearDown(otherClient.close);
    final actual = f.scope.generation;
    final mismatches = [
      scope(client: otherClient),
      scope(generation: MuxGeneration(actual.number, actual.clientId, actual.home)),
      scope(followEpoch: SessionFollowEpoch(generation: actual)),
      scope(sessionScope: Object()),
      scope(instanceId: 'other-boot'),
      scope(sessionId: 'other-session'),
    ];
    for (final mismatch in mismatches) {
      expect(receipt.committedEventIds(event.event, from: mismatch, current: f.scope), isEmpty);
      expect(receipt.committedEventIds(event.event, from: event.from, current: mismatch), isEmpty);
    }
    expect(receipt.committedEventIds(event.event, from: event.from, current: scope()), ['touch']);
  });

  test('retired follow rejects a queued old callback before a replacement mux exists', () async {
    final receipt = CompanionPromptCommit(scope: f.scope, requestId: 'chosen-id', eventIds: ['touch']);
    final event = await f.event();
    f.scope.followEpoch.retire();
    expect(receipt.committedEventIds(event.event, from: event.from, current: f.scope), isEmpty);
  });

  test('same client reconnect never lets an old event consume a new target snapshot', () async {
    final original = CompanionPromptCommit(scope: f.scope, requestId: 'chosen-id', eventIds: ['old-touch']);
    final oldEvent = await f.event();
    await f.reconnect();
    expect(original.scope.isCurrent, isFalse);
    expect(original.committedEventIds(oldEvent.event, from: oldEvent.from, current: f.scope), isEmpty);
    final replacement = CompanionPromptCommit(scope: f.scope, requestId: 'chosen-id', eventIds: ['new-touch']);
    expect(replacement.committedEventIds(oldEvent.event, from: oldEvent.from, current: f.scope), isEmpty);
  });

  test('snapshot identity is copied and validates bounded unique event ids', () {
    final ids = ['touch'];
    final receipt = CompanionPromptCommit(scope: f.scope, requestId: 'chosen-id', eventIds: ids);
    ids.add('later');
    expect(receipt.eventIds, ['touch']);
    for (final bad in [
      <String>['touch', 'touch'],
      [''],
      ['line\nbreak'],
      List.generate(9, (i) => '$i'),
    ]) {
      expect(() => CompanionPromptCommit(scope: f.scope, requestId: 'chosen-id', eventIds: bad), throwsFormatException);
    }
    expect(() => CompanionPromptCommit(scope: f.scope, requestId: '', eventIds: []), throwsFormatException);
  });
}
