/// Unit tests for message actions, plus an opt-in live group against a
/// throwaway `dsh web` (no real model needed):
/// ```sh
/// DSH_LIVE_URL='http://127.0.0.1:3080/?token=...' DSH_LIVE_CWD=/tmp/x \
///   dart test test/messages_api_test.dart
/// ```
/// Without credentials every turn fails but the prompts are still recorded;
/// the reply branch and feedback checks need a model (any Anthropic-Messages
/// endpoint behind `DEEPSEEK_BASE_URL` will do) and are skipped otherwise.
library;

import 'dart:async';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

/// Unary calls only: a scripted Host behind [DshClient.withCarrier].
class _RpcCarrier extends DshCarrier {
  final Map<String, RpcResult Function(Map<String, Object?> request)> handlers = {};
  final List<(String, Map<String, Object?>)> calls = [];

  @override
  String get kind => 'memory';

  @override
  DshTracer? get tracer => null;

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    final request = (args['request'] as Map).cast<String, Object?>();
    calls.add((endpoint, request));
    return handlers[endpoint]?.call(request) ?? const RpcError(DshRemoteException('gateway/not-found', 'missing'));
  }

  @override
  Future<DshMuxLink> openLink(MuxOptions options) => throw UnsupportedError('no streams in this test');

  @override
  Future<void> close() async {}

  List<String> get endpoints => [for (final (endpoint, _) in calls) endpoint];
}

/// One `SessionWireEvent`.
SessionLogEvent _event(int seq, String type, [Map<String, Object?> data = const {}]) =>
    SessionLogEvent.fromJson({'seq': seq, 'time': 1760000000000 + seq, 'type': type, 'data': data});

SessionLogEvent _prompt(int seq, String text) => _event(seq, 'user/message', {
  'id': 'u$seq',
  'role': 'user',
  'content': [
    {'type': 'text', 'text': text},
  ],
  'source': {'kind': 'user', 'rpcId': 'r$seq'},
});

SessionLogEvent _reply(int seq, String text, {int turn = 1, bool toolCall = false}) =>
    _event(seq, 'assistant/message', {
      'turn': turn,
      'step': 1,
      'message': {
        'id': 'm$seq',
        'role': 'assistant',
        'content': [
          if (text.isNotEmpty) {'type': 'text', 'text': text},
          if (toolCall) {'type': 'toolCall', 'id': 'c$seq', 'name': 'bash', 'arguments': <String, Object?>{}},
        ],
        'source': {'kind': 'assistant'},
      },
    });

SessionLogEvent _turnEnd(int seq, String kind, {int turn = 1}) => _event(seq, 'turn/end', {
  'turn': turn,
  'reason': {'kind': kind},
});

/// The shape DSH 0.2.1-rc.2 writes for two idle-sent prompts (captured live,
/// bookkeeping events kept so the walk has to step over them).
List<SessionLogEvent> _twoTurns() => [
  _event(0, 'permission/preset', {'preset': 'workspace-write'}),
  _event(1, 'sandbox/mode', {'mode': 'workspace-write'}),
  _event(2, 'approval/policy', {'policy': 'ask'}),
  _event(3, 'agent/inbox/spliced', {'target': 'next-turn', 'start': 0, 'inserted': <Object?>[]}),
  _event(4, 'turn/start', {'turn': 1}),
  _event(5, 'agent/inbox/spliced', {'target': 'next-turn', 'start': 0, 'removedCount': 1, 'inserted': <Object?>[]}),
  _event(6, 'step/start', {'turn': 1, 'step': 1}),
  _event(7, 'system/message', {'turn': 1, 'step': 1}),
  _prompt(8, 'first prompt'),
  _event(9, 'request/header'),
  _event(10, 'session/title', {'title': '测试'}),
  _reply(11, '这是测试回复。'),
  _event(12, 'step/end', {'turn': 1, 'step': 1}),
  _turnEnd(13, 'completed'),
  _event(14, 'session/title', {'title': '测试标题'}),
  _event(15, 'agent/inbox/spliced', {'target': 'next-turn', 'start': 0, 'inserted': <Object?>[]}),
  _event(16, 'turn/start', {'turn': 2}),
  _event(17, 'agent/inbox/spliced', {'target': 'next-turn', 'start': 0, 'removedCount': 1, 'inserted': <Object?>[]}),
  _event(18, 'step/start', {'turn': 2, 'step': 1}),
  _prompt(19, 'second prompt'),
  _reply(20, '第二个回复', turn: 2),
  _event(21, 'step/end', {'turn': 2, 'step': 1}),
  _turnEnd(22, 'completed', turn: 2),
];

Map<String, Object?> _feedbackItem({String rating = 'positive', String version = 'v1', String? category}) => {
  'messageId': 'm11',
  'rating': rating,
  'version': version,
  'category': ?category,
  'createdAt': 1760000000000,
  'updatedAt': 1760000000001,
};

void main() {
  group('forkPointAfterReply', () {
    test('a reply that closes its turn branches at the turn/end', () {
      final events = _twoTurns();
      expect(forkPointAfterReply(events, 11), 13);
      expect(forkPointAfterReply(events, 20), 22);
    });

    test('a reply is looked up from its own event on', () {
      final transcript = ChatTranscript();
      _twoTurns().forEach(transcript.apply);
      expect(transcript.eventsFrom(20).map((event) => event.seq), [20, 21, 22]);
      expect(forkPointAfterReply(transcript.eventsFrom(20), 20), 22);
    });

    test('an aborted turn still branches after its last reply', () {
      final events = [_prompt(1, 'go'), _reply(2, 'partial'), _turnEnd(3, 'aborted')];
      expect(forkPointAfterReply(events, 2), 3);
    });

    test('not when something visible follows the reply in its turn', () {
      final tool = [
        _reply(1, 'let me look', toolCall: true),
        _event(2, 'tool/call', {'turn': 1}),
        _turnEnd(3, 'completed'),
      ];
      expect(forkPointAfterReply(tool, 1), isNull);
      final laterStep = [_reply(1, 'first'), _reply(2, 'second'), _turnEnd(3, 'completed')];
      expect(forkPointAfterReply(laterStep, 1), isNull);
      expect(forkPointAfterReply(laterStep, 2), 3);
      final failed = [_reply(1, 'text'), _turnEnd(2, 'error')];
      expect(forkPointAfterReply(failed, 1), isNull);
      final retried = [
        _reply(1, 'text'),
        _event(2, 'llm/retry', {'turn': 1, 'retry': 1}),
        _turnEnd(3, 'completed'),
      ];
      expect(forkPointAfterReply(retried, 1), isNull);
    });

    test('not for a running turn, a reply without text, or another event', () {
      expect(forkPointAfterReply([_reply(1, 'streaming done'), _event(2, 'step/end')], 1), isNull);
      expect(forkPointAfterReply([_reply(1, '', toolCall: true), _turnEnd(2, 'completed')], 1), isNull);
      expect(forkPointAfterReply(_twoTurns(), 8), isNull);
      expect(forkPointAfterReply(_twoTurns(), 99), isNull);
    });
  });

  group('forkPointBeforePrompt', () {
    test('steps back over how the prompt was delivered', () {
      final events = _twoTurns();
      // The second prompt: everything through the title written after turn 1.
      expect(forkPointBeforePrompt(events, 19), 14);
      // The first prompt: the session's opening settings.
      expect(forkPointBeforePrompt(events, 8), 2);
    });

    test('a message that joined a running turn cuts after the step before it', () {
      final events = [
        _turnEnd(0, 'completed'),
        _event(1, 'turn/start', {'turn': 2}),
        _prompt(2, 'first'),
        _reply(3, 'working', turn: 2),
        _event(4, 'step/end', {'turn': 2, 'step': 1}),
        _event(5, 'step/start', {'turn': 2, 'step': 2}),
        _event(6, 'agent/inbox/spliced', {'target': 'next-step', 'start': 0, 'removedCount': 1}),
        _prompt(7, 'steer'),
      ];
      expect(forkPointBeforePrompt(events, 7), 4);
    });

    test('null when the events before the prompt are not loaded', () {
      final tail = _twoTurns().where((e) => e.seq >= 16).toList();
      expect(forkPointBeforePrompt(tail, 19), isNull);
      final gap = _twoTurns().where((e) => e.seq != 17).toList();
      expect(forkPointBeforePrompt(gap, 19), isNull);
      expect(forkPointBeforePrompt([_event(0, 'agent/inbox/spliced'), _prompt(1, 'hi')], 1), isNull);
    });
  });

  test('bumpedForkTitle counts up like the web client', () {
    expect(bumpedForkTitle('修复登录'), '修复登录 (1)');
    expect(bumpedForkTitle('修复登录 (1)'), '修复登录 (2)');
    expect(bumpedForkTitle('修复登录（9）'), '修复登录（10）');
    expect(bumpedForkTitle('v(99999999999999999999)'), 'v(100000000000000000000)');
  });

  group('forkAt', () {
    late _RpcCarrier carrier;
    late DshClient client;

    setUp(() {
      carrier = _RpcCarrier();
      client = DshClient.withCarrier(carrier);
      carrier.handlers['session/fork'] = (_) => const RpcOk({'sessionId': 'child'});
      carrier.handlers['session/updateQueue'] = (_) => const RpcOk({'accepted': true});
      carrier.handlers['session/rename'] = (request) => RpcOk({'title': request['title'], 'seq': 30});
    });

    void childProjections({String? title, List<String> queued = const []}) {
      carrier.handlers['session/projections'] = (_) => RpcOk({
        'asOfSeq': 23,
        'values': {
          'title': title,
          'inbox': {
            'next-turn': [
              for (final id in queued)
                {
                  'id': id,
                  'role': 'user',
                  'content': [
                    {'type': 'text', 'text': 'queued'},
                  ],
                  'source': {'kind': 'user-rpc'},
                },
            ],
            'next-step': <Object?>[],
          },
        },
      });
    }

    test('drops inherited queued prompts and numbers the title', () async {
      childProjections(title: '测试标题', queued: ['q1', 'q2']);
      final outcome = await client.forkAt('src', 13, sourceTitle: '我改过的标题');
      expect(outcome.sessionId, 'child');
      expect(outcome.title, '我改过的标题 (1)');
      expect(outcome.leftQueued, 0);
      expect(carrier.endpoints, [
        'session/fork',
        'session/projections',
        'session/updateQueue',
        'session/updateQueue',
        'session/rename',
      ]);
      expect(carrier.calls[0].$2, {'sessionId': 'src', 'atSeq': 13});
      expect(carrier.calls[2].$2, {
        'sessionId': 'child',
        'itemId': 'q1',
        'action': {'kind': 'remove'},
      });
      expect(carrier.calls[4].$2, {'sessionId': 'child', 'title': '我改过的标题 (1)'});
    });

    test('a fork without a title keeps automatic titling', () async {
      childProjections();
      final outcome = await client.forkAt('src', 2, sourceTitle: '测试标题');
      expect(outcome.title, isNull);
      expect(carrier.endpoints, ['session/fork', 'session/projections']);
    });

    test('clean-up failures are reported, not thrown', () async {
      childProjections(title: 'T', queued: ['q1', 'gone']);
      carrier.handlers['session/updateQueue'] = (request) => RpcError(
        request['itemId'] == 'gone'
            ? const DshRemoteException('session/queue-item-not-found', 'already taken')
            : const DshRemoteException('gateway/internal', 'boom'),
      );
      carrier.handlers['session/rename'] = (_) => const RpcError(DshRemoteException('session/title-invalid', 'no'));
      final outcome = await client.forkAt('src', 13);
      expect(outcome.sessionId, 'child');
      expect(outcome.leftQueued, 1);
      expect(outcome.title, isNull);
    });

    test('a refused fork throws the Host error', () async {
      carrier.handlers['session/fork'] = (_) =>
          const RpcError(DshRemoteException('session/fork-unavailable', 'event 99 does not exist'));
      await expectLater(
        client.forkAt('src', 99),
        throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'session/fork-unavailable')),
      );
      expect(carrier.endpoints, ['session/fork']);
    });
  });

  group('message feedback', () {
    late _RpcCarrier carrier;
    late DshClient client;

    setUp(() {
      carrier = _RpcCarrier();
      client = DshClient.withCarrier(carrier);
    });

    test('list parses items and skips unknown shapes', () async {
      carrier.handlers['messageFeedback/list'] = (_) => RpcOk({
        'ok': true,
        'value': {
          'items': [
            _feedbackItem(category: 'task-result'),
            {'messageId': 'x', 'rating': 'meh', 'version': 'v'},
          ],
        },
      });
      final items = await client.listMessageFeedback('s1');
      expect(items, hasLength(1));
      expect(items.single.messageId, 'm11');
      expect(items.single.rating, FeedbackRating.positive);
      expect(items.single.category, FeedbackCategory.taskResult);
      expect(carrier.calls.single.$2, {'sessionId': 's1'});
    });

    test('put sends ifVersion null to create, category and note by wire name', () async {
      carrier.handlers['messageFeedback/put'] = (_) =>
          RpcOk({'ok': true, 'value': _feedbackItem(rating: 'negative', category: 'resource-cost')});
      final item = await client.putMessageFeedback(
        's1',
        'm11',
        FeedbackRating.negative,
        ifVersion: null,
        note: '太贵了',
        category: FeedbackCategory.resourceCost,
      );
      expect(item.rating, FeedbackRating.negative);
      final request = carrier.calls.single.$2;
      expect(request, {
        'sessionId': 's1',
        'messageId': 'm11',
        'rating': 'negative',
        'note': '太贵了',
        'category': 'resource-cost',
        'ifVersion': null,
      });
      expect(request.containsKey('ifVersion'), isTrue);
    });

    test('business failures carry the code and the current item', () async {
      carrier.handlers['messageFeedback/put'] = (_) => RpcOk({
        'ok': false,
        'error': {'code': 'version-conflict', 'current': _feedbackItem(version: 'v2')},
      });
      await expectLater(
        client.putMessageFeedback('s1', 'm11', FeedbackRating.positive, ifVersion: null),
        throwsA(
          isA<MessageFeedbackException>()
              .having((e) => e.isConflict, 'conflict', isTrue)
              .having((e) => e.current?.version, 'current', 'v2'),
        ),
      );
      carrier.handlers['messageFeedback/delete'] = (_) => const RpcOk({
        'ok': false,
        'error': {'code': 'session-not-found', 'sessionId': 's1'},
      });
      await expectLater(
        client.deleteMessageFeedback('s1', 'm11', ifVersion: 'v1'),
        throwsA(isA<MessageFeedbackException>().having((e) => e.code, 'code', 'session-not-found')),
      );
    });

    test('delete sends the observed version', () async {
      carrier.handlers['messageFeedback/delete'] = (_) => const RpcOk({
        'ok': true,
        'value': {'absent': true},
      });
      await client.deleteMessageFeedback('s1', 'm11', ifVersion: 'v1');
      expect(carrier.endpoints, ['messageFeedback/delete']);
      expect(carrier.calls.single.$2, {'sessionId': 's1', 'messageId': 'm11', 'ifVersion': 'v1'});
    });
  });

  _liveGroup();
}

void _liveGroup() {
  final url = Platform.environment['DSH_LIVE_URL'];
  final cwd = Platform.environment['DSH_LIVE_CWD'];
  group('live dsh web', tags: ['live'], skip: url == null ? 'set DSH_LIVE_URL to run live tests' : null, () {
    late DshClient client;

    setUpAll(() async {
      final launch = DshLaunchUrl.tryParse(url!)!;
      client = await DshClient.connect(baseUri: launch.baseUri, token: launch.token);
    });

    tearDownAll(() async => client.close());

    Future<SessionSnapshotEvent> snapshot(String sessionId) async =>
        await client
                .watch(sessionId, options: const WatchOptions(turnWindow: TurnWindow(400, 100), maxMessages: 400))
                .firstWhere((e) => e is SessionSnapshotEvent)
            as SessionSnapshotEvent;

    /// Waits until [turns] turns have ended and the inbox holds [queued] items.
    Future<List<SessionLogEvent>> settle(String sessionId, int turns, {int queued = 0}) async {
      for (var i = 0; i < 120; i++) {
        final snap = await snapshot(sessionId);
        final ended = snap.events.whereType<TurnEndedEvent>().length;
        final inbox = snap.projections.queuedMessages.length;
        if (ended >= turns &&
            inbox == queued &&
            !snap.events.any(
              (e) => e is TurnStartedEvent && e.seq > snap.events.whereType<TurnEndedEvent>().last.seq,
            )) {
          return snap.events;
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      fail('session $sessionId did not settle');
    }

    test('edit and resend: fork just before a prompt', () async {
      final source = (await client.createSession(cwd: cwd)).sessionId;
      await client.prompt(source, 'first prompt');
      await settle(source, 1);
      await client.prompt(source, 'second prompt');
      final events = await settle(source, 2);
      final second = events.whereType<UserMessageEvent>().lastWhere((e) => e.message.text == 'second prompt');
      final cut = forkPointBeforePrompt(events, second.seq);
      expect(cut, isNotNull);
      expect(events.firstWhere((e) => e.seq == cut), isNot(isA<InboxSplicedEvent>()));

      final outcome = await client.forkAt(source, cut!);
      final child = await snapshot(outcome.sessionId);
      final inherited = child.events.where((e) => e.seq <= cut).map((e) => (e.seq, e.type)).toList();
      expect(inherited, [for (final e in events.where((e) => e.seq <= cut)) (e.seq, e.type)]);
      expect(child.events.map((e) => e.type), contains('session/end-seed'));
      expect(child.events.whereType<UserMessageEvent>().map((e) => e.message.text), isNot(contains('second prompt')));
      expect(child.projections.queuedMessages, isEmpty);
      expect(
        child.events.whereType<TurnStartedEvent>().where((e) => e.seq > cut),
        isEmpty,
        reason: 'no turn runs by itself',
      );

      // The first prompt: a fork of the session's opening settings only.
      final first = events.whereType<UserMessageEvent>().firstWhere((e) => e.message.text == 'first prompt');
      final opening = forkPointBeforePrompt(events, first.seq)!;
      final blank = await client.forkAt(source, opening, sourceTitle: 'ignored');
      expect(blank.title, isNull, reason: 'no inherited title: automatic titling stays on');
      final row = (await client.listSessions()).firstWhere((s) => s.sessionId == blank.sessionId);
      expect(row.parentSessionId, source);
      expect(row.blank, isTrue);
    });

    test('a fork drops prompts it inherited from the inbox', () async {
      final source = (await client.createSession(cwd: cwd)).sessionId;
      // B and C reach the inbox while A's turn is open.
      await Future.wait([client.prompt(source, 'A'), client.prompt(source, 'B'), client.prompt(source, 'C')]);
      await Future<void>.delayed(const Duration(seconds: 2));
      final events = (await snapshot(source)).events;
      final firstEnd = events.whereType<TurnEndedEvent>().first;
      final insertsBefore = events.whereType<InboxSplicedEvent>().where(
        (e) => e.seq < firstEnd.seq && e.inserted.isNotEmpty,
      );
      expect(insertsBefore.length, greaterThan(1), reason: 'B/C were queued during turn 1');

      final outcome = await client.forkAt(source, firstEnd.seq);
      expect(outcome.leftQueued, 0);
      final child = await snapshot(outcome.sessionId);
      expect(child.projections.queuedMessages, isEmpty);
    });

    test('branch from a reply, and rate it', () async {
      final source = (await client.createSession(cwd: cwd)).sessionId;
      await client.prompt(source, 'hello');
      final events = await settle(source, 1);
      final replies = events.whereType<AssistantMessageEvent>().where((e) => e.message.text.trim().isNotEmpty);
      if (replies.isEmpty) {
        markTestSkipped('no model answered (no credentials): reply branch and feedback not checked');
        return;
      }
      final reply = replies.last;
      final cut = forkPointAfterReply(events, reply.seq);
      final end = events.whereType<TurnEndedEvent>().last;
      expect(cut, end.seq);

      final title = (await client.projections(source))?.title;
      final outcome = await client.forkAt(source, cut!, sourceTitle: title);
      if (title != null) expect(outcome.title, bumpedForkTitle(title));
      final child = await snapshot(outcome.sessionId);
      expect(child.events.whereType<AssistantMessageEvent>().map((e) => e.message.id), contains(reply.message.id));
      expect(child.events.where((e) => e.seq <= cut).last.type, 'turn/end');

      // Feedback targets the reply's message id.
      expect(await client.listMessageFeedback(source), isEmpty);
      final liked = await client.putMessageFeedback(source, reply.message.id, FeedbackRating.positive, ifVersion: null);
      expect(liked.rating, FeedbackRating.positive);
      final disliked = await client.putMessageFeedback(
        source,
        reply.message.id,
        FeedbackRating.negative,
        ifVersion: liked.version,
        category: FeedbackCategory.taskResult,
        note: '测试反馈',
      );
      expect(disliked.version, isNot(liked.version));
      final listed = await client.listMessageFeedback(source);
      expect(listed.single.category, FeedbackCategory.taskResult);
      expect(listed.single.note, '测试反馈');
      await expectLater(
        client.putMessageFeedback(source, reply.message.id, FeedbackRating.positive, ifVersion: liked.version),
        throwsA(isA<MessageFeedbackException>().having((e) => e.current?.version, 'current', disliked.version)),
      );
      final prompt = events.whereType<UserMessageEvent>().firstWhere((e) => e.isHumanPrompt);
      await expectLater(
        client.putMessageFeedback(source, prompt.message.id, FeedbackRating.positive, ifVersion: null),
        throwsA(isA<MessageFeedbackException>().having((e) => e.code, 'code', 'target-not-found')),
      );
      // A fork starts without the parent's feedback.
      expect(await client.listMessageFeedback(outcome.sessionId), isEmpty);
      await client.deleteMessageFeedback(source, reply.message.id, ifVersion: disliked.version);
      expect(await client.listMessageFeedback(source), isEmpty);
    });
  });
}
