// Goldens of the regrouped settings (docs/design/settings-ia.md §4.2–4.3):
// the whole hub on a tall phone, with values in its rows, and the pages it
// gained — 个性化, 界面, 隐私与分享, 关于 DSH Go — light and dark.
//
//   flutter test --update-goldens test/settings/settings_ia_golden_test.dart

import 'dart:io';

import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/share_code/guest_fs.dart';
import 'package:dsh_app/state/account_state.dart';
import 'package:dsh_app/state/balance_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/state/update_state.dart';
import 'package:dsh_app/ui/settings/about_page.dart';
import 'package:dsh_app/ui/settings/interface_page.dart';
import 'package:dsh_app/ui/settings/personalization_page.dart';
import 'package:dsh_app/ui/settings/privacy_page.dart';
import 'package:dsh_app/ui/settings/reply_prefs_page.dart';
import 'package:dsh_app/ui/settings/settings_screen.dart';
import 'package:dsh_app/update/version.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../account/support.dart' show FixedAccount, sampleBalance, sampleProfile;
import '../engine_settings/support.dart' as engine;
import '../phone/support.dart' show FixedActiveHost, FixedHosts;
import '../shell/golden_harness.dart';

/// Pins the shown version so the baselines don't change with every release.
class _FixedVersion extends AppUpdateController {
  @override
  AppUpdateState build() => super.build().copyWith(current: const AppVersion(1, 0, 2, build: 1));
}

List<Override> _local({bool autoApprove = false}) => [
  appUpdateProvider.overrideWith(_FixedVersion.new),
  activeHostProvider.overrideWith(() => FixedActiveHost(HostRef.local)),
  hostsProvider.overrideWith(FixedHosts.new),
  localRuntimeProvider.overrideWith(() => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus))),
  settingsProvider.overrideWith(() => FakeSettings(AppSettings(loaded: true, autoApproveCommands: autoApprove))),
];

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  // The whole hub at once: 完全权限 for new chats (warning), 后台运行 not yet
  // allowed (warning), one saved SSH host.
  for (final brightness in Brightness.values) {
    final mode = brightness == Brightness.dark ? 'dark' : 'light';
    testWidgets('settings_hub_full ($mode)', (tester) async {
      await tester.runAsync(loadGoldenFonts);
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = const Size(390 * 2, 2420 * 2);
      tester.view.padding = const FakeViewPadding(top: 32 * 2, bottom: 24 * 2);
      tester.view.viewPadding = const FakeViewPadding(top: 32 * 2, bottom: 24 * 2);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        goldenApp(
          home: ProviderScope(
            overrides: [accountWalletBalanceProvider.overrideWithValue(sampleBalance)],
            child: const SettingsScreen(),
          ),
          brightness: brightness,
          overrides: [
            ..._local(autoApprove: true),
            batteryExemptProvider.overrideWith((ref) async => false),
            accountProvider.overrideWith(
              () => FixedAccount(
                const AccountState(phase: AccountPhase.signedIn, connected: true, profile: sampleProfile),
              ),
            ),
          ],
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/settings_hub_full_$mode.png'));
    });
  }

  final fs = tempGuestFs();
  goldenBoth(
    'personalization',
    () => const PersonalizationPage(),
    overrides: () => [
      ..._local(),
      guestFsProvider.overrideWith((ref) async => fs),
      replyPrefsProvider.overrideWith((ref) async => '回答简洁，先给结论。\n用中文。'),
    ],
  );

  goldenBoth('about', () => const AboutPage(), overrides: _local);

  // The two pages that also show the host's own settings.
  for (final (name, page) in [('interface', const InterfacePage()), ('privacy', const PrivacyPage())]) {
    for (final brightness in Brightness.values) {
      final mode = brightness == Brightness.dark ? 'dark' : 'light';
      testWidgets('$name ($mode)', (tester) async {
        await engine.pumpPage(
          tester,
          page,
          overrides: engine.engineOverrides(DshClient.withCarrier(engine.FakeSettingsHost())),
          brightness: brightness,
          height: name == 'interface' ? 1500 : 844,
          fonts: true,
        );
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/${name}_$mode.png'));
      });
    }
  }
}

/// A guest file system that exists (个人偏好 shows only with one at hand).
GuestFs tempGuestFs() {
  final dir = Directory.systemTemp.createTempSync('ia-guest-');
  return GuestFs(Directory('${dir.path}/rootfs')..createSync());
}
