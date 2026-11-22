import 'dart:async';

import 'package:dsh_app/runtime/android_background_turns.dart';
import 'package:dsh_app/runtime/background_protection.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../packages/dsh_client/test/support/companion_signal_host.dart';

class _Client extends DshClient {
  _Client(this.source) : super.withCarrier(source.carrier);
  final DshClient source;
  final snapshots = <Completer<List<SessionSummary>>>[];

  @override
  DshMux get mux => source.mux;

  @override
  Future<List<SessionSummary>> listSessions() {
    final read = Completer<List<SessionSummary>>();
    snapshots.add(read);
    return read.future;
  }
}

class _Local extends LocalConnectionController {
  _Local(this.client);
  final DshClient client;

  @override
  Future<HostConnection?> build() async => HostConnection(client: client, isLocal: true);
}

class _Selected extends ActiveHostController {
  @override
  HostRef build() => HostRef.local;

  @override
  void select(HostRef host) => state = host;
}

class _Bridge extends RuntimeBridge {
  final signals = <bool>[];

  @override
  Future<void> setTurnRunning(bool running) async => signals.add(running);
}

List<SessionSummary> _running(String id) => [
  SessionSummary.fromJson({'sessionId': id, 'running': true}),
];

void main() {
  test('keeps only current local work, never restoring a finished turn from a late snapshot', () async {
    final host = await CompanionSignalTestHost.start();
    addTearDown(host.close);
    final client = _Client(await host.connect());
    final bridge = _Bridge();
    final container = ProviderContainer(
      overrides: [
        operatingSystemProvider.overrideWithValue('android'),
        activeHostProvider.overrideWith(_Selected.new),
        localConnectionProvider.overrideWith(() => _Local(client)),
        runtimeBridgeProvider.overrideWithValue(bridge),
        backgroundProtectionProvider.overrideWith(
          (ref) => const BackgroundProtection(supported: true, audioEnabled: true),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.listen(androidBackgroundTurnsProvider, (_, _) {});
    await container.read(backgroundProtectionProvider.future);
    await container.read(localConnectionProvider.future);
    await container.pump();
    expect(client.snapshots, hasLength(1));

    await host.proof(client, session: 'first', running: true);
    await host.proof(client, session: 'second', running: true);
    await host.proof(client, session: 'first');
    expect(bridge.signals, [true]);
    await host.proof(client, session: 'second');
    expect(bridge.signals, [true, false]);
    client.snapshots[0].complete(_running('first'));
    await container.pump();
    expect(bridge.signals, [true, false]);

    await host.proof(client, running: true);
    final selected = container.read(activeHostProvider.notifier);
    selected.select(const HostRef.ssh('remote'));
    await container.pump();
    expect(bridge.signals, [true, false, true, false]);
    await host.proof(client, running: true);
    expect(bridge.signals, [true, false, true, false]);

    selected.select(HostRef.local);
    await container.pump();
    expect(client.snapshots, hasLength(2));
    await host.proof(client, running: true);
    await client.mux.close();
    client.snapshots[1].complete(_running('task'));
    await container.pump();
    expect(bridge.signals, [true, false, true, false, true, false]);
  });
}
