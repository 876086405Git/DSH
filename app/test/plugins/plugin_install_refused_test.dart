// An engine that takes no market installs (HarmonyOS's own) says so: nothing is
// offered to fail, no relay command is shown, and a refusal that still gets
// through never shows its raw diagnostic. On Android none of this changes.

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/state/bots_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/media_generation.dart';
import 'package:dsh_app/state/plugins_state.dart';
import 'package:dsh_app/state/runtime_capabilities_state.dart';
import 'package:dsh_app/ui/bots/install_card.dart';
import 'package:dsh_app/ui/plugins/plugin_detail_sheet.dart';
import 'package:dsh_app/ui/plugins/plugins_screen.dart';
import 'package:dsh_app/ui/settings/media_settings_page.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';
import 'support/fake_plugin_host.dart';

final _zh = lookupL10n(AppLocale.zhCN);

/// What HarmonyOS's engine answers when asked.
const _refuses = RuntimeCapabilities(plugins: RuntimePluginCapabilities(marketInstall: RuntimeSupport.unsupported));

void main() {
  late FakePluginCarrier carrier;
  late DshClient client;
  setUp(() {
    carrier = FakePluginCarrier();
    client = DshClient.withCarrier(carrier);
    carrier.handlers['pluginManager/listBundles'] = (_) => <Map<String, Object?>>[];
  });
  tearDown(() => client.close());

  PluginHost host({bool refused = true}) =>
      PluginHost(client: client, label: '本机', kind: HostKind.local, installRefused: refused);

  group('the host', () {
    test('can\'t install once refused, whatever the carrier allows', () {
      expect(host(refused: false).canInstall, isTrue);
      expect(host().canInstall, isFalse);
      expect(host().safeMode, isFalse);
    });

    for (final (os, refused) in [('ohos', true), ('android', false)]) {
      test('on $os an engine that refuses makes it $refused', () async {
        final container = ProviderContainer(
          overrides: [
            ...pluginOverrides(fakeHost(client)),
            operatingSystemProvider.overrideWithValue(os),
            runtimeCapabilitiesProvider.overrideWith((ref) async => _refuses),
          ],
        );
        addTearDown(container.dispose);
        final sub = container.listen(pluginHostProvider, (_, _) {});
        await container.read(runtimeCapabilitiesProvider.future);
        expect(sub.read()?.installRefused, refused);
        expect(sub.read()?.canInstall, !refused);
        sub.close();
      });
    }
  });

  test('a refusal that still gets through reads as words, not its diagnostic', () {
    final result = PluginOperationResult.fromJson(
      installResult(
        application: 'failed',
        error: {
          'code': 'operation-error',
          'message': 'failed',
          'diagnostic': '[OHOS_PLUGIN_INSTALL_UNAVAILABLE] 鸿蒙本机不支持安装、更新或卸载插件包',
        },
      ),
    );
    final failure = describeOperationFailure(result, isLocal: true);
    expect(failure.title, _zh.marketInstallRefused);
    expect(failure.message, _zh.harmonyPluginRefusedHint);
    expect(failure.detail, isNull);
    expect(failure.retryable, isFalse);
  });

  List<Override> overrides(PluginHost pluginHost) => [
    ...pluginOverrides(
      fakeHost(client),
      official: () async => officialFixtureMarket(),
      npmIntegrity: (name, _) async => officialFixtureMarket().byName[name]?.listing?.integrity,
    ),
    pluginHostProvider.overrideWithValue(pluginHost),
  ];

  Future<void> pump(WidgetTester tester, Widget home, PluginHost pluginHost) async {
    usePhoneView(tester);
    await tester.pumpWidget(testApp(home, overrides: overrides(pluginHost)));
    await tester.pumpAndSettle();
  }

  group('图像与视频', () {
    Future<void> prompt(WidgetTester tester, PluginHost pluginHost) async {
      await pump(tester, const Scaffold(body: MediaInstallPrompt()), pluginHost);
      ProviderScope.containerOf(tester.element(find.byType(MediaInstallPrompt)))
          .listen(installedPluginsProvider, (_, _) {});
      await tester.pumpAndSettle();
    }

    testWidgets('no install button, and it says why', (tester) async {
      await prompt(tester, host());
      expect(find.text(_zh.mediaInstallAction), findsNothing);
      expect(find.text(_zh.marketInstallRefused), findsOneWidget);
    });

    testWidgets('no 生成 tile either, with the plugin nowhere to be got', (tester) async {
      await prompt(tester, host());
      final container = ProviderScope.containerOf(tester.element(find.byType(MediaInstallPrompt)));
      expect(container.read(mediaPluginProvider), MediaPluginState.absent);
    });

    testWidgets('where installs work: as before', (tester) async {
      await prompt(tester, host(refused: false));
      expect(find.text(_zh.mediaInstallAction), findsOneWidget);
      expect(find.text(_zh.marketInstallRefused), findsNothing);
      final container = ProviderScope.containerOf(tester.element(find.byType(MediaInstallPrompt)));
      expect(container.read(mediaPluginProvider), MediaPluginState.installable);
    });

    testWidgets('installed and off keeps its way to the plugin pages', (tester) async {
      carrier.handlers['pluginManager/listBundles'] = (_) => [bundleJson('@dsh-go/media', enabled: false)];
      await prompt(tester, host());
      expect(find.text(_zh.mediaInstallAction), findsOneWidget);
    });
  });

  group('a plugin\'s own sheet', () {
    PluginBundle removable() => PluginBundle.fromJson(bundleJson('some-plugin', removable: true));

    setUp(() => carrier.handlers['pluginManager/listBundles'] = (_) => [bundleJson('some-plugin', removable: true)]);

    testWidgets('uninstall is turned down in words, with no command to run elsewhere', (tester) async {
      await pump(
        tester,
        Scaffold(
          body: BundleSheet(name: 'some-plugin', initial: removable()),
        ),
        host(),
      );
      final button = tester.widget<FilledButton>(find.widgetWithText(FilledButton, _zh.harmonyPluginRemoveRefused));
      expect(button.onPressed, isNull);
      expect(find.text(_zh.hubPluginRemoveCommand), findsNothing);
      expect(find.text(_zh.hubPluginUninstall), findsNothing);
    });

    testWidgets('where installs work: uninstall as before', (tester) async {
      await pump(
        tester,
        Scaffold(
          body: BundleSheet(name: 'some-plugin', initial: removable()),
        ),
        host(refused: false),
      );
      expect(find.text(_zh.hubPluginUninstall), findsOneWidget);
      expect(find.text(_zh.harmonyPluginRemoveRefused), findsNothing);
    });

    testWidgets('a relay host still shows its command', (tester) async {
      final relay = DshClient.withCarrier(
        FakePluginCarrier(allowInstall: false)
          ..handlers['pluginManager/listBundles'] = (_) => [bundleJson('some-plugin', removable: true)],
      );
      addTearDown(relay.close);
      await pump(
        tester,
        Scaffold(
          body: BundleSheet(name: 'some-plugin', initial: removable()),
        ),
        PluginHost(client: relay, label: '电脑', kind: HostKind.relay),
      );
      expect(find.text(_zh.hubPluginRemoveCommand), findsOneWidget);
    });
  });

  group('the plugin page\'s line', () {
    testWidgets('says the engine refuses, not that a relay is in the way', (tester) async {
      await pump(tester, const PluginsScreen(), host());
      expect(find.text(_zh.marketInstallRefused), findsWidgets);
      expect(find.text(_zh.pluginsRelayToggleOnly('本机')), findsNothing);
    });
  });

  group('DS Bot', () {
    const status = DsBotStatus(availability: DsBotAvailability.missing);

    testWidgets('no install, and no command to copy for an engine that refuses it', (tester) async {
      await pump(tester, const Scaffold(body: DsBotInstallCard(status: status)), host());
      expect(find.text(_zh.commonInstall), findsNothing);
      expect(find.text(dsBotInstallCommand), findsNothing);
      expect(find.text(_zh.marketInstallRefused), findsOneWidget);
    });

    testWidgets('where installs work: install', (tester) async {
      await pump(tester, const Scaffold(body: DsBotInstallCard(status: status)), host(refused: false));
      expect(find.text(_zh.commonInstall), findsOneWidget);
      expect(find.text(_zh.marketInstallRefused), findsNothing);
    });
  });
}
