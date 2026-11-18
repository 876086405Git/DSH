import 'dart:async';

import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/remote/link_status.dart';
import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/remote/network_details_sheet.dart';
import 'package:dsh_app/ui/remote/remote_screen.dart';
import 'package:dsh_app/ui/settings/settings_widgets.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart';
import 'support/fake_relay.dart';

const _host = HostRef.relay('mac');

class _InspectableLink extends HostLink implements NetworkInspectableHostLink {
  _InspectableLink(this.status);

  @override
  HostLinkStatus status;
  final changes = StreamController<HostLinkStatus>.broadcast(sync: true);
  int inspections = 0;
  Future<RemoteNetworkStatus?> Function()? inspect;

  void emit(HostLinkStatus next) {
    status = next;
    changes.add(next);
  }

  @override
  Future<RemoteNetworkStatus?> inspectNetwork() async {
    inspections++;
    final result = await inspect?.call();
    if (result != null && status.isConnected) {
      emit(HostLinkStatus(HostLinkPhase.connected, path: result.path, network: result));
    }
    return result;
  }

  @override
  Stream<HostLinkStatus> get statuses => changes.stream;
  @override
  DshClient? get currentClient => null;
  @override
  Stream<DshClient> get clients => const Stream.empty();
  @override
  Future<DshClient> open() => throw UnimplementedError();
  @override
  void kick() {}
  @override
  void retry() {}
  @override
  Future<void> close() async {}
}

void main() {
  setUp(() {
    AppLocale.use(AppLocale.zhCN);
    SharedPreferences.setMockInitialValues({ActiveHostController.prefsKey: _host.encode()});
  });

  Future<void> frames(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> pump(WidgetTester tester, _InspectableLink link, {bool page = false, String? os}) async {
    usePhoneSurface(tester);
    addTearDown(link.changes.close);
    await tester.pumpWidget(
      goldenApp(
        home: page ? const RemoteScreen() : const Scaffold(body: RemoteNetworkDetailsSheet(host: _host)),
        brightness: Brightness.light,
        overrides: [
          secretStoreProvider.overrideWithValue(MemorySecretStore()),
          networkKicksProvider.overrideWithValue(const Stream.empty()),
          relayBackendProvider.overrideWithValue(FakeRelayBackend(user: sampleRelayUser)),
          hostLinkProvider.overrideWith((ref, host) => link),
          hostNameProvider.overrideWith((ref, host) => 'Workstation'),
          if (os != null) operatingSystemProvider.overrideWithValue(os),
          localRuntimeProvider.overrideWith(
            () => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus)),
          ),
        ],
      ),
    );
    await frames(tester);
  }

  testWidgets('automatic routing has no direct toggle or stale search setting', (tester) async {
    await pump(tester, _InspectableLink(HostLinkStatus.idle), page: true);
    expect(find.byKey(const ValueKey('remote-direct')), findsNothing);
    expect(SettingsIndex.spot('remote-direct'), isNull);
    expect(SettingsIndex.spot('remote-auto-connect'), isNotNull);
    final startup = find.byKey(const ValueKey('remote-auto-connect'));
    await tester.scrollUntilVisible(startup, 300);
    expect(startup, findsOneWidget);
  });

  testWidgets('compact history is an opt-in searchable preference with delayed application explained', (tester) async {
    await pump(tester, _InspectableLink(HostLinkStatus.idle), page: true);
    final compact = find.byKey(const ValueKey('remote-compact-history'));
    await tester.scrollUntilVisible(compact, 300);
    expect(SettingsIndex.spot('remote-compact-history'), isNotNull);
    expect(tester.widget<SettingsSwitchTile>(compact).value, isFalse);
    expect(find.textContaining('切换主机或重启 App 后生效'), findsOneWidget);
    await tester.tap(compact);
    await frames(tester);
    expect(tester.widget<SettingsSwitchTile>(compact).value, isTrue);
    expect((await SharedPreferences.getInstance()).getBool(RemoteCompactHistoryController.prefsKey), isTrue);
  });

  for (final path in [RelayPath.lan, RelayPath.p2p, RelayPath.turn, RelayPath.relay]) {
    testWidgets('connected host shows ${path.name} and opens network details', (tester) async {
      final link = _InspectableLink(HostLinkStatus(HostLinkPhase.connected, path: path));
      await pump(tester, link, page: true);
      expect(find.text('已连接 · ${path.label} · 端到端加密'), findsOneWidget);
      final entry = find.byKey(const ValueKey('remote-network-mac'));
      await tester.ensureVisible(entry);
      await tester.tap(entry);
      await frames(tester);
      final sheet = find.byType(RemoteNetworkDetailsSheet);
      expect(sheet, findsOneWidget);
      expect(find.descendant(of: sheet, matching: find.text('Workstation')), findsOneWidget);
      expect(find.descendant(of: sheet, matching: find.text('DSH Remote')), findsOneWidget);
      expect(find.text(path.label), findsWidgets);
      expect(find.text('未测量'), findsNWidgets(2));
      expect(link.inspections, 0, reason: 'opening details does not continuously probe the connection');
    });
  }

  testWidgets('measurement is on demand and shows actual timing', (tester) async {
    final link = _InspectableLink(
      const HostLinkStatus(
        HostLinkPhase.connected,
        path: RelayPath.lan,
        network: RemoteNetworkStatus(path: RelayPath.lan, connectDuration: Duration(milliseconds: 315)),
      ),
    );
    final pending = Completer<RemoteNetworkStatus?>();
    link.inspect = () => pending.future;
    await pump(tester, link);
    expect(find.text('315 毫秒'), findsOneWidget);
    expect(find.text('未测量'), findsOneWidget);
    await tester.tap(find.text('刷新网络信息 / 测量延迟'));
    await frames(tester);
    expect(find.text('正在测量…'), findsOneWidget);
    expect(link.inspections, 1);
    pending.complete(
      const RemoteNetworkStatus(
        path: RelayPath.p2p,
        connectDuration: Duration(milliseconds: 315),
        roundTripTime: Duration(milliseconds: 47),
      ),
    );
    await frames(tester);
    expect(find.text('47 毫秒'), findsOneWidget);
    expect(find.text(RelayPath.p2p.label), findsOneWidget);
    expect(link.status.isConnected, isTrue);
  });

  testWidgets('selected IPv6 and ICE protocol are visible without candidate addresses', (tester) async {
    final link = _InspectableLink(
      const HostLinkStatus(
        HostLinkPhase.connected,
        path: RelayPath.p2p,
        network: RemoteNetworkStatus(
          path: RelayPath.p2p,
          localIpVersion: NetworkIpVersion.ipv6,
          remoteIpVersion: NetworkIpVersion.ipv6,
          iceProtocol: NetworkIceProtocol.udp,
        ),
      ),
    );
    await pump(tester, link);
    expect(find.text('IPv6'), findsNWidgets(2));
    expect(find.text('UDP'), findsOneWidget);
    expect(find.text('手机 ICE IP 版本'), findsOneWidget);
    expect(find.text('主机 ICE IP 版本'), findsOneWidget);
    expect(link.inspections, 0);
    link.emit(const HostLinkStatus(HostLinkPhase.reconnecting));
    await frames(tester);
    expect(find.text('IPv6'), findsNothing);
    expect(find.text('UDP'), findsNothing);
  });

  testWidgets('Relay never borrows IP metadata from a previous ICE path', (tester) async {
    final link = _InspectableLink(
      const HostLinkStatus(
        HostLinkPhase.connected,
        path: RelayPath.relay,
        network: RemoteNetworkStatus(
          path: RelayPath.relay,
          localIpVersion: NetworkIpVersion.ipv6,
          iceProtocol: NetworkIceProtocol.udp,
        ),
      ),
    );
    await pump(tester, link);
    expect(find.text('IPv6'), findsNothing);
    expect(find.text('UDP'), findsNothing);
    expect(find.text('手机 ICE IP 版本'), findsNothing);
  });

  testWidgets('unknown fallback and measurement failure never expose technical data', (tester) async {
    final link = _InspectableLink(
      const HostLinkStatus(
        HostLinkPhase.connected,
        path: RelayPath.relay,
        network: RemoteNetworkStatus(path: RelayPath.relay, fallbackReason: 'token=secret 192.168.0.1 SDP'),
      ),
    );
    link.inspect = () async => throw StateError('token=secret 192.168.0.1 SDP');
    await pump(tester, link);
    expect(find.text('回落原因'), findsOneWidget);
    expect(find.textContaining('token='), findsNothing);
    await tester.tap(find.text('刷新网络信息 / 测量延迟'));
    await frames(tester);
    expect(find.text('暂时无法测量，可以稍后重试'), findsOneWidget);
    expect(find.textContaining('192.168'), findsNothing);
    expect(find.textContaining('SDP'), findsNothing);
    expect(link.status.isConnected, isTrue);
  });

  group('without a direct path to try (HarmonyOS)', () {
    final zh = lookupL10n(AppLocale.zhCN);
    _InspectableLink relayOnly() => _InspectableLink(
      const HostLinkStatus(
        HostLinkPhase.connected,
        path: RelayPath.relay,
        network: RemoteNetworkStatus(path: RelayPath.relay, fallbackReason: 'webrtcUnavailable'),
      ),
    );

    testWidgets('on HarmonyOS: the relay is simply how this version connects', (tester) async {
      await pump(tester, relayOnly(), os: 'ohos');
      expect(find.textContaining(zh.harmonyNetworkRelayOnly), findsOneWidget);
      expect(find.text(zh.harmonyNetworkFallbackRelayOnly), findsOneWidget);
      expect(find.textContaining('LAN → P2P'), findsNothing);
      expect(find.text(zh.remoteNetworkFallbackWebrtcUnavailable), findsNothing);
    });

    testWidgets('on Android: the order it tries, and the device at fault', (tester) async {
      await pump(tester, relayOnly(), os: 'android');
      expect(find.textContaining(zh.remoteNetworkAutomatic), findsOneWidget);
      expect(find.text(zh.remoteNetworkFallbackWebrtcUnavailable), findsOneWidget);
    });
  });

  testWidgets('fallback codes are explained in the current language', (tester) async {
    final link = _InspectableLink(
      const HostLinkStatus(
        HostLinkPhase.connected,
        path: RelayPath.relay,
        network: RemoteNetworkStatus(path: RelayPath.relay, fallbackReason: 'turnTimeout'),
      ),
    );
    await pump(tester, link);
    expect(find.text('TURN 连接超时，已使用 Relay 中继'), findsOneWidget);
    expect(find.text('turnTimeout'), findsNothing);
    AppLocale.use(AppLocale.en);
    await tester.pumpWidget(const SizedBox.shrink());
    await frames(tester);
    await tester.pumpWidget(
      goldenApp(
        home: const Scaffold(body: RemoteNetworkDetailsSheet(host: _host)),
        brightness: Brightness.light,
        overrides: [
          hostLinkProvider.overrideWith((ref, host) => link),
          hostNameProvider.overrideWith((ref, host) => 'Workstation'),
        ],
      ),
    );
    await frames(tester);
    expect(find.text('TURN timed out; using Relay.'), findsOneWidget);
  });

  testWidgets('disconnect clears measurements and ignores a late result', (tester) async {
    final pending = Completer<RemoteNetworkStatus?>();
    final link = _InspectableLink(const HostLinkStatus(HostLinkPhase.connected, path: RelayPath.lan));
    link.inspect = () => pending.future;
    await pump(tester, link);
    await tester.tap(find.text('刷新网络信息 / 测量延迟'));
    await frames(tester);
    link.emit(const HostLinkStatus(HostLinkPhase.reconnecting));
    await frames(tester);
    pending.complete(const RemoteNetworkStatus(path: RelayPath.lan, roundTripTime: Duration(milliseconds: 12)));
    await frames(tester);
    expect(find.text('12 毫秒'), findsNothing);
    expect(find.text('连接已断开，重新连接后可测量'), findsOneWidget);
    expect(find.text('尚未确认'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
  });
}
