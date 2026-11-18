import 'dart:async';

import 'package:dsh_app/pets/pet_mood.dart';
import 'package:dsh_app/pets/pet_signals.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/state/bots_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/notify_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../packages/dsh_client/test/support/fake_dsh.dart';
import 'support.dart';

// Keep real loopback HTTP while providing the MethodChannel test messenger.
class _LocalSocketBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

class _Local extends LocalConnectionController {
  @override
  Future<HostConnection?> build() async => null;
}

class _HoldCarrier extends DshCarrier {
  _HoldCarrier(this.http);
  final DshHttpCarrier http;
  final resultArrived = Completer<void>();
  final releaseResult = Completer<void>();
  bool holdResult = false;
  @override
  String get kind => 'notify-live-http';
  @override
  DshTracer? get tracer => null;
  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    final result = await http.call(endpoint, args, timeout: timeout);
    if (endpoint == r'$events/result' && holdResult) {
      if (!resultArrived.isCompleted) resultArrived.complete();
      await releaseResult.future;
    }
    return result;
  }

  @override
  Future<DshMuxLink> openLink(MuxOptions options) => http.openLink(options);
  @override
  Future<void> close() async {
    if (!releaseResult.isCompleted) releaseResult.complete();
    await http.close();
  }
}

const _remote = HostRef.ssh('lab');
const _actionId = '11111111-2222-4333-8444-555555555555';
const _request = ApprovalRequest(eventId: 'e1', sessionId: 'child', toolName: 'write', callId: 'c1');
const _pending = {
  'type': 'waterfall',
  'eventId': 'e1',
  'event': 'approval/request',
  'agentId': 'child',
  'request': {'toolName': 'write', 'callId': 'c1'},
};

NotifyAction _action(NotifyPost post, {String id = _actionId, int? token, String? sessionId}) => NotifyAction.fromMap({
  'host': post.host.encode(),
  'group': post.group,
  'key': post.key,
  'eventId': post.eventId,
  'sessionId': sessionId ?? post.sessionId,
  'requestToken': token ?? post.requestToken,
  'decision': 'allowed-once',
  'actionId': id,
})!;

void main() {
  _LocalSocketBinding();

  test('OH request fields are explicit and Android post and ACK wire remain unchanged', () async {
    const post = NotifyPost(
      group: 'g',
      key: 'e',
      attention: true,
      title: 'title',
      text: 'text',
      publicText: 'public',
      sessionId: 's',
      host: _remote,
      kind: 'approval',
      eventId: 'e',
      canApprove: true,
      fullText: 'full',
      requestToken: 7,
    );
    final legacy = {
      'group': 'g',
      'key': 'e',
      'attention': true,
      'title': 'title',
      'text': 'text',
      'publicText': 'public',
      'sessionId': 's',
      'host': _remote.encode(),
      'kind': 'approval',
      'eventId': 'e',
      'canApprove': true,
      'fullText': 'full',
    };
    expect(post.toMap(), legacy);
    expect(post.toMap(ohos: false), legacy);
    expect(post.toMap(ohos: true), {...legacy, 'requestToken': 7});
    final old = NotifyAction.fromMap({
      'host': _remote.encode(),
      'group': 'g',
      'key': 'e',
      'eventId': 'e',
      'decision': 'allowed-once',
    })!;
    final scoped = _action(post);
    expect(old.actionId, isNull);
    expect((scoped.actionId, scoped.sessionId, scoped.requestToken), (_actionId, 's', 7));
    final payload = {
      'host': _remote.encode(),
      'group': 'g',
      'key': 'e',
      'eventId': 'e',
      'decision': 'allowed-once',
      'sessionId': 's',
      'requestToken': 7,
      'actionId': _actionId,
    };
    for (final invalid in [
      {...payload, 'requestToken': 0},
      {...payload, 'requestToken': 1.5},
      {...payload, 'actionId': ''},
      {...payload, 'sessionId': ''},
      {...payload, 'decision': 'allowed-always'},
      {...payload}..remove('requestToken'),
      {...payload}..remove('actionId'),
    ]) {
      expect(NotifyAction.fromMap(invalid), isNull);
    }
    const methods = MethodChannel('test/notify/438-wire');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      return null;
    });
    try {
      final channel = NotifyChannel(methods: methods);
      await channel.completeAction(old, NotifyActionResult.handled);
      await channel.completeAction(scoped, NotifyActionResult.gone);
      expect(calls.map((c) => c.method), ['actionResult', 'actionResult']);
      expect(calls.first.arguments, {'group': 'g', 'key': 'e', 'result': 'handled'});
      expect(calls.last.arguments, {'group': 'g', 'key': 'e', 'result': 'gone', 'actionId': _actionId});
    } finally {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(methods, null);
    }
  });

  group('OH current notification through real client RPC', () {
    late FakeDsh host;
    late DshClient client;
    late _HoldCarrier wire;
    late FakeAlertSource source;
    late FakeNotifyChannel channel;
    late ProviderContainer container;
    late StreamSubscription<HostEvent> hostEvents;
    late StreamSubscription<PetEvent> petEvents;
    late List<PetEvent> events;
    var filtered = false, disposed = false;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      filtered = false;
      disposed = false;
      host = await FakeDsh.start();
      final connection = DshConnection(host.baseUri);
      await connection.login(FakeDsh.token);
      wire = _HoldCarrier(DshHttpCarrier(connection));
      client = await DshClient.connectCarrier(wire);
      host.handlers[r'$events/result'] = (_) => {'ok': true};
      source = FakeAlertSource()
        ..sessions = [session('root'), session('child', parent: 'root')]
        // Longer than the pet's full-action limit, but valid for the original notification preview.
        ..approvalCalls['c1'] = ToolCallPart(
          id: 'c1',
          name: 'write',
          arguments: '{"file_path":"config","content":"${'x' * 240}"}',
        );
      hostEvents = client.hostEvents.listen(source.emit);
      channel = FakeNotifyChannel();
      container = ProviderContainer(
        overrides: [
          operatingSystemProvider.overrideWithValue('ohos'),
          dsBotSessionFilterProvider.overrideWithValue((_, _) => filtered),
          notifyChannelProvider.overrideWithValue(channel),
          alertSourceFactoryProvider.overrideWithValue((_) => source),
          alertTimingProvider.overrideWithValue((announce: Duration.zero, reconcile: const Duration(milliseconds: 30))),
          localConnectionProvider.overrideWith(_Local.new),
          activeConnectionProvider.overrideWithValue(
            AsyncData(HostConnection(client: client, label: 'Lab', isLocal: false, kind: HostKind.ssh, hostId: 'lab')),
          ),
        ],
      );
      container.listen(chatAlertsProvider, (_, _) {});
      container.read(appForegroundProvider.notifier).set(false);
      events = [];
      petEvents = container.read(petEventBusProvider).events.listen(events.add);
      await settle();
    });
    tearDown(() async {
      if (!disposed) container.dispose();
      await petEvents.cancel();
      await hostEvents.cancel();
      await channel.actionController.close();
      await channel.tapController.close();
      await client.close();
      await host.close();
    });
    List<Map> calls() => [
      for (final call in host.rpcCalls)
        if (call['method'] == r'$events/result') (call['payload'] as Map)['args'] as Map,
    ];
    Future<NotifyPost> announce() async {
      source.emit(const ApprovalRequestedEvent(_request));
      await settle();
      return channel.shown.last;
    }

    Future<void> reconnect() async {
      host.pendingWaterfalls.add(_pending);
      final redelivered = client.hostEvents.where((event) => event is ApprovalRequestedEvent).first;
      client.mux.reconnect();
      await client.mux.ready();
      await redelivered.timeout(const Duration(seconds: 2));
      await settle();
    }

    Future<NotifyActionResult> answer(NotifyAction action) =>
        container.read(chatAlertsProvider.notifier).respondAction(action);

    test('display-root scope approves original child request without imposing pet-only limits', () async {
      final post = await announce();
      expect(post.sessionId, 'root');
      expect(post.canApprove, isTrue);
      expect(post.requestToken, isPositive);
      expect(petApprovalText(_request, source.approvalCalls['c1']), isNull);
      final generation = client.mux.generation!;
      expect(await answer(_action(post)), NotifyActionResult.handled);
      expect(calls(), [
        {
          'clientId': generation.clientId,
          'eventId': 'e1',
          'outcome': {'kind': 'result', 'value': 'allowed-once'},
        },
      ]);
    });

    test('wrong display-root or old token never submits a current approval', () async {
      final post = await announce();
      expect(await answer(_action(post, sessionId: 'child')), NotifyActionResult.gone);
      expect(await answer(_action(post, token: post.requestToken! + 1)), NotifyActionResult.gone);
      expect(calls(), isEmpty);
    });

    test('HostReady refreshes only the system notification with a new token', () async {
      final post = await announce();
      final petCount = events.length;
      await reconnect();
      expect(channel.shown, hasLength(2));
      expect(channel.shown.last.requestToken, isNot(post.requestToken));
      expect(events, hasLength(petCount));
      expect(container.read(chatAlertsProvider), isNull);
      expect(await answer(_action(post)), NotifyActionResult.gone);
      expect(calls(), isEmpty);
      expect(await answer(_action(channel.shown.last)), NotifyActionResult.handled);
      expect(calls(), hasLength(1));
    });

    test('reannouncement preserves DS Bot filter and never creates foreground banners or pet repeats', () async {
      await announce();
      final petCount = events.length;
      filtered = true;
      source.emit(const HostReadyEvent('filtered', '/root'));
      await announce();
      expect(channel.shown, hasLength(1));
      filtered = false;
      container.read(appForegroundProvider.notifier).set(true);
      source.emit(const HostReadyEvent('foreground', '/root'));
      await announce();
      expect(channel.shown, hasLength(1));
      expect(events, hasLength(petCount));
      expect(container.read(chatAlertsProvider), isNull);
    });

    test('stale stream rejection makes one RPC and never retries in a new generation', () async {
      final post = await announce();
      final generation = client.mux.generation!;
      host.handlers[r'$events/result'] = (_) {
        client.mux.reconnect();
        return {
          'ok': false,
          'error': {'code': 'gateway/arguments-invalid', 'message': 'clientId identifies no active event stream'},
        };
      };
      expect(await answer(_action(post)), NotifyActionResult.failed);
      await client.mux.ready();
      expect(calls().map((args) => args['clientId']), [generation.clientId]);
      expect(client.mux.generation, isNot(same(generation)));
    });

    test('late accepted RPC ACK keeps the old actionId and leaves redelivered request pending', () async {
      final post = await announce();
      wire.holdResult = true;
      channel.actionController.add(_action(post));
      await wire.resultArrived.future;
      await reconnect();
      expect(client.mux.pendingRequests, hasLength(1));
      expect(channel.shown.last.requestToken, isNot(post.requestToken));
      wire.releaseResult.complete();
      await settle();
      expect(channel.actionResults, hasLength(1));
      expect(channel.actionResults.single.$1.actionId, _actionId);
      expect(channel.actionResults.single.$2, NotifyActionResult.handled);
      expect(client.mux.pendingRequests, hasLength(1));
      expect(await answer(_action(post)), NotifyActionResult.gone);
      expect(calls(), hasLength(1));
    });

    test('controller lifetime ending during RPC cannot clear a later pending request', () async {
      final post = await announce();
      wire.holdResult = true;
      final response = answer(_action(post));
      await wire.resultArrived.future;
      container.dispose();
      disposed = true;
      await reconnect();
      expect(client.mux.pendingRequests, hasLength(1));
      wire.releaseResult.complete();
      expect(await response, NotifyActionResult.handled);
      expect(client.mux.pendingRequests, hasLength(1));
      expect(calls(), hasLength(1));
    });
  });
}
