import 'dart:async';

import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/ready_mux.dart';
import 'support/wait.dart';

class _Runtime extends LocalRuntimeController {
  @override
  LocalRuntimeState build() => _running('first');

  static LocalRuntimeState _running(String token) => LocalRuntimeState(
    loaded: true,
    status: RuntimeStatus.fromMap({'phase': 'running', 'baseUrl': 'http://127.0.0.1:9', 'token': token}),
  );

  void replace(String token) => state = _running(token);
}

class _Settings extends SettingsController {
  @override
  AppSettings build() => const AppSettings(loaded: true);
}

/// Waiting out a reconnect backoff until asked to try now.
class _BackoffMux extends ReadyMux {
  var current = DshConnectionState.connected;
  var reconnects = 0;

  @override
  DshConnectionState get state => current;

  @override
  void reconnect() => reconnects++;
}

class _Client extends DshClient {
  _Client([DshMux? mux]) : _readyMux = mux ?? ReadyMux(), super(DshConnection(Uri.parse('http://127.0.0.1:9')));
  final DshMux _readyMux;
  @override
  DshMux get mux => _readyMux;
  bool closed = false;

  @override
  Future<void> close() async {
    closed = true;
    await super.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a replaced build closes its late client', () async {
    final pending = <Completer<DshClient>>[];
    final c = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith(_Settings.new),
        localRuntimeProvider.overrideWith(_Runtime.new),
        networkKicksProvider.overrideWithValue(const Stream.empty()),
        localClientConnectorProvider.overrideWithValue(({required baseUri, required token}) {
          final done = Completer<DshClient>();
          pending.add(done);
          return done.future;
        }),
      ],
    );
    addTearDown(c.dispose);
    final sub = c.listen(localConnectionProvider, (_, _) {});
    addTearDown(sub.close);
    await Future<void>.delayed(Duration.zero);
    (c.read(localRuntimeProvider.notifier) as _Runtime).replace('second');
    await Future<void>.delayed(Duration.zero);
    expect(pending, hasLength(2));
    final old = _Client();
    pending.first.complete(old);
    await Future<void>.delayed(Duration.zero);
    expect(old.closed, isTrue);
    final current = _Client();
    pending.last.complete(current);
    await until(c, localConnectionProvider, (s) => s.value != null, what: '新本机连接');
    expect(c.read(localConnectionProvider).value!.client, same(current));
    expect(current.closed, isFalse);
  });

  test('network kick restarts a failed local connection', () async {
    var attempts = 0;
    final kicks = StreamController<void>.broadcast(sync: true);
    addTearDown(kicks.close);
    final c = ProviderContainer(
      retry: (_, _) => null,
      overrides: [
        settingsProvider.overrideWith(_Settings.new),
        localRuntimeProvider.overrideWith(_Runtime.new),
        networkKicksProvider.overrideWithValue(kicks.stream),
        localClientConnectorProvider.overrideWithValue(({required baseUri, required token}) async {
          attempts++;
          if (attempts == 1) throw const DshTransportException('offline');
          return _Client();
        }),
      ],
    );
    addTearDown(c.dispose);
    final sub = c.listen(localConnectionProvider, (_, _) {});
    addTearDown(sub.close);
    await until(c, localConnectionProvider, (s) => s.hasError, what: '本机连接失败');
    kicks.add(null);
    await until(c, localConnectionProvider, (s) => s.value != null, what: '网络恢复后连接');
    expect(attempts, 2);
  });

  test('back on screen, a link waiting out its backoff tries again now on the same client', () async {
    final kicks = StreamController<void>.broadcast(sync: true);
    addTearDown(kicks.close);
    final mux = _BackoffMux();
    final client = _Client(mux);
    final c = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith(_Settings.new),
        localRuntimeProvider.overrideWith(_Runtime.new),
        networkKicksProvider.overrideWithValue(kicks.stream),
        localClientConnectorProvider.overrideWithValue(({required baseUri, required token}) async => client),
      ],
    );
    addTearDown(c.dispose);
    final sub = c.listen(localConnectionProvider, (_, _) {});
    addTearDown(sub.close);
    await until(c, localConnectionProvider, (s) => s.value != null && !s.isLoading, what: '本机连接');
    kicks.add(null);
    expect(mux.reconnects, 0);
    mux.current = DshConnectionState.reconnecting;
    kicks.add(null);
    expect(mux.reconnects, 1);
    expect(c.read(localConnectionProvider).value!.client, same(client));
  });
}
