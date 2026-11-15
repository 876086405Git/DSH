import 'dart:async';

import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/notify_state.dart';
import 'package:dsh_app/state/phone_turn_end.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../notify/support.dart' as notify;
import 'support.dart';

class _Client extends DshClient {
  _Client() : super(DshConnection(Uri.parse('http://127.0.0.1:9')));
  final requests = <Completer<List<SessionSummary>>>[];

  @override
  Future<List<SessionSummary>> listSessions() {
    final result = Completer<List<SessionSummary>>();
    requests.add(result);
    return result.future;
  }
}

class _Local extends LocalConnectionController {
  _Local(this.client);
  final DshClient client;

  @override
  Future<HostConnection?> build() async => HostConnection(client: client, label: 'local', isLocal: true);
}

ChatAlert _end(String id) => ChatAlert(
  host: HostRef.local,
  sessionId: id,
  kind: AlertKind.done,
  key: turnKey,
  title: 'title',
  text: 'done',
  turnEndKind: 'completed',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Client client;
  late FakePhoneNative native;
  late ProviderContainer container;
  late PhoneTurnEndController phone;

  Future<void> start({String? viewed}) async {
    SharedPreferences.setMockInitialValues({});
    client = _Client();
    native = FakePhoneNative()..install();
    container = ProviderContainer(overrides: [localConnectionProvider.overrideWith(() => _Local(client))]);
    addTearDown(container.dispose);
    await container.read(localConnectionProvider.future);
    if (viewed != null) container.read(currentSessionProvider.notifier).select(viewed);
    container.read(appForegroundProvider.notifier).set(false);
    container.listen(phoneTurnEndProvider, (_, _) {});
    await notify.settle();
    phone = container.read(phoneTurnEndProvider.notifier);
  }

  Future<void> begin({int? id = 1}) async {
    native.push(phoneStatus(taskActive: true, taskId: id));
    await notify.settle();
  }

  test('authenticated iOS owner finishes its task without an ambiguous session snapshot', () async {
    await start(viewed: 'unrelated');
    final status = phoneStatus(taskActive: true, taskId: 31);
    (status['task'] as Map)['ownerSessionId'] = 'ios-owner';
    native.push(status);
    await notify.settle();
    expect(client.requests, isEmpty);
    expect(phone.onTurnEnd(_end('unrelated')), isNull);
    final completion = phone.onTurnEnd(_end('ios-owner'));
    expect(completion, isNotNull);
    await completion;
    expect(native.callsOf('finishTask').single.arguments, containsPair('sessionId', 'ios-owner'));

    final next = phoneStatus(taskActive: true, taskId: 32);
    (next['task'] as Map)['ownerSessionId'] = 'next-owner';
    native.push(next);
    await notify.settle();
    expect(phone.onTurnEnd(_end('ios-owner')), isNull);
    expect(client.requests, isEmpty);
  });

  test('unknown owner while a snapshot is pending never finishes another conversation', () async {
    await start();
    await begin();
    expect(phone.onTurnEnd(_end('unrelated')), isNull);
    expect(native.callsOf('finishTask'), isEmpty);
    client.requests.single.complete([]);
    await notify.settle();
  });

  test('a failed or empty snapshot cannot claim an arbitrary turn end', () async {
    await start();
    await begin();
    client.requests.single.completeError(StateError('engine disconnected'));
    await notify.settle();
    expect(phone.onTurnEnd(_end('other')), isNull);
    await begin(id: 2);
    client.requests.last.complete([]);
    await notify.settle();
    expect(phone.onTurnEnd(_end('other')), isNull);
    expect(native.callsOf('finishTask'), isEmpty);
  });

  test('the viewed conversation does not prove which of two running sessions owns the phone', () async {
    await start(viewed: 's2');
    await begin();
    client.requests.single.complete([notify.session('s1', running: true), notify.session('s2', running: true)]);
    await notify.settle();
    expect(phone.onTurnEnd(_end('s2')), isNull);
    expect(phone.onTurnEnd(_end('s1')), isNull);
    expect(native.callsOf('finishTask'), isEmpty);
  });

  test('an old task snapshot cannot replace the owner of the new native task', () async {
    await start();
    await begin();
    await begin(id: 2);
    client.requests.last.complete([notify.session('s2', running: true)]);
    await notify.settle();
    client.requests.first.complete([notify.session('s1', running: true)]);
    await notify.settle();
    expect(phone.link.candidates, {'s2'});
    expect(phone.onTurnEnd(_end('s1')), isNull);
    await phone.onTurnEnd(_end('s2'));
    expect(native.callsOf('finishTask'), hasLength(1));
    expect((native.callsOf('finishTask').single.arguments as Map)['taskId'], 2);
  });

  test('a claimed task is not rearmed by a repeated active push with the same id', () async {
    await start();
    await begin();
    client.requests.single.complete([notify.session('s1', running: true)]);
    await notify.settle();
    await phone.onTurnEnd(_end('s1'));
    await begin();
    if (client.requests.length > 1) {
      client.requests.last.complete([notify.session('s1', running: true)]);
      await notify.settle();
    }
    expect(phone.onTurnEnd(_end('s1')), isNull);
    expect(native.callsOf('finishTask'), hasLength(1));
  });

  test('a native task without an id is not automatically finished', () async {
    await start();
    await begin(id: null);
    if (client.requests.isNotEmpty) {
      client.requests.single.complete([notify.session('s1', running: true)]);
      await notify.settle();
    }
    expect(phone.onTurnEnd(_end('s1')), isNull);
    expect(native.callsOf('finishTask'), isEmpty);
  });
}
