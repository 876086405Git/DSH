import 'dart:convert';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/runtime/ohos_linux_runtime.dart';
import 'package:dsh_app/runtime/runtime_state.dart' show runtimeBridgeProvider;
import 'package:dsh_app/secrets/secure_storage.dart';
import 'package:dsh_app/state/ohos_linux_state.dart';
import 'package:dsh_app/ui/settings/linux_environment_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart' show testTheme;
import '../safe_mode/support.dart' show FakeBridge;

Map<String, Object?> _status([Map<String, Object?> extra = const {}]) => {
  'v': 1,
  'instanceId': 'service-1',
  'attemptId': 'attempt-1',
  'state': 'disabled',
  'enabled': false,
  'admission': false,
  'guestOpened': false,
  'ownerRetained': false,
  'workspaceLease': false,
  'restartRequired': false,
  'shutdownComplete': false,
  'nextRequestId': 1,
  'ownerState': null,
  'backendState': null,
  'progress': null,
  'lastErrorCode': null,
  'job': null,
  'retirement': null,
  ...extra,
};

OhosLinuxSnapshot _snapshot([Map<String, Object?> extra = const {}]) =>
    OhosLinuxSnapshot.fromWire(jsonEncode(_status(extra)));

class _Runtime implements OhosLinuxRuntime {
  _Runtime(this.status);
  OhosLinuxSnapshot status;
  final calls = <String>[];
  final proxies = <Map<String, String>>[];
  Object? discardError;

  @override
  Future<OhosLinuxSnapshot> discardRetained() async {
    calls.add('discardRetained');
    if (discardError case final error?) throw error;
    status = _snapshot();
    return status;
  }

  @override
  Future<OhosLinuxSnapshot> getStatus() async {
    calls.add('getStatus');
    return status;
  }

  @override
  Future<OhosLinuxSnapshot> setEnabled(bool enabled) async {
    calls.add('setEnabled($enabled)');
    status = _snapshot({'state': enabled ? 'enabled' : 'disabled', 'enabled': enabled});
    return status;
  }

  @override
  Future<OhosLinuxSnapshot> setProxy(OhosLinuxProxyConfiguration proxy) async {
    calls.add('setProxy(${proxy.mode.name})');
    proxies.add(proxy.toMap());
    return status;
  }

  @override
  Future<OhosLinuxSnapshot> runPrivateGuest({
    required OhosLinuxSnapshot scope,
    required List<String> argv,
    required String cwd,
    Map<String, String> environment = const {},
    String stdin = '',
  }) => throw UnimplementedError();
}

class _Secrets extends AppSecureStorage {
  _Secrets();
  final values = <String, String>{};

  @override
  Future<String?> read({required String key}) async => values[key];

  @override
  Future<void> write({required String key, required String? value}) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> delete({required String key}) async => values.remove(key);
}

class _Bridge extends FakeBridge {
  Object? reopenError;
  int reopened = 0;

  @override
  Future<void> reopenApp() async {
    reopened++;
    if (reopenError != null) throw reopenError!;
  }
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  _Runtime runtime,
  _Secrets secrets, {
  bool settle = true,
  _Bridge? bridge,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ohosLinuxRuntimeProvider.overrideWithValue(runtime),
        ohosLinuxSecretsProvider.overrideWithValue(secrets),
        runtimeBridgeProvider.overrideWithValue(bridge ?? _Bridge()),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: const Locale('zh'),
        supportedLocales: L10n.supportedLocales,
        localizationsDelegates: L10n.localizationsDelegates,
        theme: testTheme(Brightness.light),
        home: const LinuxEnvironmentPage(),
      ),
    ),
  );
  // While Linux installs the page polls every second, so it never settles.
  settle ? await tester.pumpAndSettle() : await tester.pump(const Duration(milliseconds: 50));
  return ProviderScope.containerOf(tester.element(find.byType(LinuxEnvironmentPage)));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the switch turns Linux on, saves the wish and applies the proxy first', (tester) async {
    final runtime = _Runtime(_snapshot());
    final secrets = _Secrets();
    await _pump(tester, runtime, secrets);
    expect(find.text('未开启'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('linux-switch')));
    await tester.pumpAndSettle();

    expect(runtime.calls, ['getStatus', 'setProxy(inherit)', 'setEnabled(true)']);
    expect(find.text('已开启'), findsOneWidget);
    expect((await SharedPreferences.getInstance()).getBool(OhosLinuxController.wantedKey), isTrue);
  });

  testWidgets('installing shows the stage and keeps asking until it is done', (tester) async {
    final runtime = _Runtime(
      _snapshot({
        'state': 'installing',
        'enabled': true,
        'progress': {'stage': 'archive', 'done': 1, 'total': 4, 'step': null},
      }),
    );
    await _pump(tester, runtime, _Secrets(), settle: false);
    expect(find.text('下载基础系统'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    runtime.status = _snapshot({'state': 'enabled', 'enabled': true});
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text('下载基础系统'), findsNothing);
    expect(find.text('已开启'), findsOneWidget);
    expect(runtime.calls.where((call) => call == 'getStatus').length, 2);
  });

  testWidgets('a stopped Linux that needs an app restart says so, locks the switch and offers the reopen', (
    tester,
  ) async {
    final runtime = _Runtime(_snapshot({'state': 'stopped', 'restartRequired': true}));
    final bridge = _Bridge();
    await _pump(tester, runtime, _Secrets(), bridge: bridge);
    expect(find.text('Linux 已经停止，重新打开 App 后才能再开启。'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('linux-switch')));
    await tester.pumpAndSettle();
    expect(runtime.calls, ['getStatus']);

    await tester.tap(find.byKey(const ValueKey('linux-reopen')));
    await tester.pumpAndSettle();
    expect(bridge.reopened, 1);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('a reopen the system refuses tells the user to reopen by hand', (tester) async {
    final runtime = _Runtime(_snapshot({'state': 'stopped', 'restartRequired': true}));
    final bridge = _Bridge()..reopenError = PlatformException(code: '16000050');
    await _pump(tester, runtime, _Secrets(), bridge: bridge);
    await tester.tap(find.byKey(const ValueKey('linux-reopen')));
    await tester.pump();
    expect(find.text('没能自动重新打开，请手动退出 App 再打开。'), findsOneWidget);
  });

  testWidgets('a Linux that can still be turned on offers no reopen', (tester) async {
    await _pump(tester, _Runtime(_snapshot()), _Secrets());
    expect(find.byKey(const ValueKey('linux-reopen')), findsNothing);
  });

  testWidgets('a manual proxy is stored in secure storage and sent to the engine', (tester) async {
    final runtime = _Runtime(_snapshot());
    final secrets = _Secrets();
    await _pump(tester, runtime, secrets);

    await tester.tap(find.text('手动'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'http://127.0.0.1:7890');
    await tester.tap(find.text('保存').last);
    await tester.pumpAndSettle();

    expect(runtime.proxies.last, {'mode': 'manual', 'httpProxy': 'http://127.0.0.1:7890'});
    expect(proxyFromJson(secrets.values[OhosLinuxController.proxyKey]!).httpProxy, 'http://127.0.0.1:7890');
    expect(find.text('http://127.0.0.1:7890'), findsOneWidget);
  });

  testWidgets('restore gives the engine back the proxy and the switch after a restart', (tester) async {
    SharedPreferences.setMockInitialValues({OhosLinuxController.wantedKey: true});
    final runtime = _Runtime(_snapshot());
    final secrets = _Secrets()
      ..values[OhosLinuxController.proxyKey] = proxyToJson(
        const OhosLinuxProxyConfiguration.manual(httpProxy: 'http://127.0.0.1:7890'),
      );
    final container = await _pump(tester, runtime, secrets);
    runtime.calls.clear();

    await container.read(ohosLinuxProvider.notifier).restore();
    await tester.pumpAndSettle();
    expect(runtime.calls, ['setProxy(manual)', 'setEnabled(true)']);
  });

  group('重新安装 Linux', () {
    final row = find.byKey(const ValueKey('linux-reinstall'));
    Future<void> tapRow(WidgetTester tester) async {
      await tester.ensureVisible(row);
      await tester.tap(row);
      await tester.pumpAndSettle();
    }

    testWidgets('is locked while Linux is on', (tester) async {
      final runtime = _Runtime(
        _snapshot({'state': 'enabled', 'enabled': true, 'admission': true, 'guestOpened': true}),
      );
      await _pump(tester, runtime, _Secrets());
      await tapRow(tester);
      expect(find.text('重新安装 Linux？'), findsNothing);
      expect(runtime.calls, ['getStatus']);
    });

    testWidgets('cancelling the confirmation deletes nothing', (tester) async {
      final runtime = _Runtime(_snapshot());
      await _pump(tester, runtime, _Secrets());
      await tapRow(tester);
      expect(find.text('重新安装 Linux？'), findsOneWidget);
      expect(find.textContaining('登录过的账号（比如 gh）'), findsOneWidget);
      expect(find.textContaining('对话工作区里的文件不受影响'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('重新安装 Linux？'), findsNothing);
      expect(runtime.calls, ['getStatus']);
    });

    testWidgets('an update that left unusable data points to it; confirming deletes, refreshes and leaves Linux off', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({OhosLinuxController.wantedKey: true});
      // The install after the update was refused: the switch is still on but nothing runs.
      final runtime = _Runtime(
        _snapshot({
          'state': 'failed',
          'enabled': true,
          'ownerRetained': true,
          'restartRequired': true,
          'lastErrorCode': 'ERR_OHOS_LINUX_ASSET_GENERATION',
        }),
      );
      await _pump(tester, runtime, _Secrets());
      expect(find.textContaining('原来的 Linux 数据没法继续用了'), findsOneWidget);
      expect(find.textContaining('ERR_OHOS_LINUX_ASSET_GENERATION'), findsOneWidget);
      expect(find.textContaining('重新打开 App 才能再开启'), findsNothing);

      await tapRow(tester);
      await tester.tap(find.byKey(const ValueKey('linux-reinstall-confirm')));
      await tester.pumpAndSettle();

      expect(runtime.calls, ['getStatus', 'discardRetained', 'getStatus']);
      expect(find.textContaining('原来的 Linux 数据没法继续用了'), findsNothing);
      expect(find.text('未开启'), findsOneWidget);
      // The wish stays as it was, and nothing switched Linux on.
      expect((await SharedPreferences.getInstance()).getBool(OhosLinuxController.wantedKey), isTrue);
    });

    testWidgets('a refusal from the engine says what to do', (tester) async {
      final runtime = _Runtime(_snapshot())..discardError = PlatformException(code: 'ERR_OHOS_LINUX_RESTART_REQUIRED');
      await _pump(tester, runtime, _Secrets());
      await tapRow(tester);
      await tester.tap(find.byKey(const ValueKey('linux-reinstall-confirm')));
      await tester.pumpAndSettle();
      expect(runtime.calls, ['getStatus', 'discardRetained']);
      expect(find.textContaining('完全退出并重新打开 App 后，再点「重新安装 Linux」'), findsOneWidget);

      runtime.discardError = PlatformException(code: 'EIO');
      await tapRow(tester);
      await tester.tap(find.byKey(const ValueKey('linux-reinstall-confirm')));
      await tester.pumpAndSettle();
      expect(find.text('没能重新安装：EIO'), findsOneWidget);
    });

    testWidgets('a VM started in this run of the app locks it until the app restarts', (tester) async {
      final runtime = _Runtime(
        _snapshot({'ownerRetained': true, 'nativeMemoryRelease': 'process-exit', 'guestOpened': true}),
      );
      await _pump(tester, runtime, _Secrets());
      expect(find.textContaining('完全退出并重新打开 App 后才能重新安装'), findsOneWidget);
      await tapRow(tester);
      expect(find.text('重新安装 Linux？'), findsNothing);
      expect(runtime.calls, ['getStatus']);
    });
  });
}
