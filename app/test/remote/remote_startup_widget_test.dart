import 'dart:convert';

import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/compose_inbox.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/remote/remote_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart';
import 'support/fake_relay.dart';
import 'support/fake_ssh.dart';

const autoConnectKey = 'remote_auto_connect_on_startup';

void main() {
  void seed(HostRef host) => SharedPreferences.setMockInitialValues({
    HostsController.prefsKey: jsonEncode([sampleSsh.toJson()]),
    ActiveHostController.prefsKey: host.encode(),
  });
  final relay = FakeRelayBackend(user: sampleRelayUser);

  testWidgets('startup preference is editable and does not disconnect the active host', (tester) async {
    seed(HostRef.ssh(sampleSsh.id));
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        home: const RemoteScreen(),
        brightness: Brightness.light,
        overrides: [
          secretStoreProvider.overrideWithValue(MemorySecretStore()),
          networkKicksProvider.overrideWithValue(const Stream.empty()),
          relayBackendProvider.overrideWithValue(relay),
          hostLinkStatusProvider.overrideWith((ref, host) => Stream.value(HostLinkStatus.idle)),
          localRuntimeProvider.overrideWith(
            () => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus)),
          ),
        ],
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final c = ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
    final tile = find.byKey(const ValueKey('remote-auto-connect'));
    await tester.scrollUntilVisible(tile, 300);
    await tester.pump();
    final toggle = find.descendant(of: tile, matching: find.byType(Switch));
    expect(tester.widget<Switch>(toggle).value, isTrue);
    await tester.tap(toggle);
    await tester.pump();
    expect(tester.widget<Switch>(toggle).value, isFalse);
    expect((await SharedPreferences.getInstance()).getBool(autoConnectKey), isFalse);
    expect(c.read(activeHostProvider), HostRef.ssh(sampleSsh.id));
    expect(find.text('连接上次使用的主机'), findsOneWidget);
  });

  testWidgets('问 AI in the bar asks how to connect a computer', (tester) async {
    seed(HostRef.local);
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        home: const RemoteScreen(),
        brightness: Brightness.light,
        overrides: [
          secretStoreProvider.overrideWithValue(MemorySecretStore()),
          networkKicksProvider.overrideWithValue(const Stream.empty()),
          relayBackendProvider.overrideWithValue(relay),
          hostLinkStatusProvider.overrideWith((ref, host) => Stream.value(HostLinkStatus.idle)),
          localRuntimeProvider.overrideWith(
            () => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus)),
          ),
        ],
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byTooltip('问 AI'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final c = ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
    expect(c.read(composeInboxProvider).single.text, '/dsh-go-guide 怎么连接自己的电脑或服务器？和用本机有什么不同？');
  });

  testWidgets('the startup preference stays out of the way until a remote host exists', (tester) async {
    SharedPreferences.setMockInitialValues({});
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        home: const RemoteScreen(),
        brightness: Brightness.light,
        overrides: [
          secretStoreProvider.overrideWithValue(MemorySecretStore()),
          networkKicksProvider.overrideWithValue(const Stream.empty()),
          relayBackendProvider.overrideWithValue(FakeRelayBackend()),
          hostLinkStatusProvider.overrideWith((ref, host) => Stream.value(HostLinkStatus.idle)),
          localRuntimeProvider.overrideWith(
            () => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus)),
          ),
        ],
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('remote-auto-connect')), findsNothing);
  });
}
