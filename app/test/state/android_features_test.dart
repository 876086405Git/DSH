// A build on an OS without Android's own concepts (HarmonyOS): none of them
// show anywhere, in the hub, 全部功能, search, links, the pages that mention
// them or first run; the relay goes straight to its server. And on Android,
// every one is still there.

import 'package:dsh_app/links/page_links.dart';
import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/pets/pet_prefs.dart';
import 'package:dsh_app/pets/pet_signals.dart';
import 'package:dsh_app/remote/relay/dsh_remote_backend.dart';
import 'package:dsh_app/remote/relay/webrtc_peer.dart';
import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/features_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/onboarding_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/engine/engine_screen.dart';
import 'package:dsh_app/ui/features/all_features_page.dart';
import 'package:dsh_app/ui/features/feature_catalog.dart';
import 'package:dsh_app/ui/features/permission_page.dart';
import 'package:dsh_app/ui/notify/background_net_host.dart';
import 'package:dsh_app/ui/notify/background_pause_host.dart';
import 'package:dsh_app/ui/onboarding/access_step.dart';
import 'package:dsh_app/ui/onboarding/connect_page.dart';
import 'package:dsh_app/ui/onboarding/runtime_setup_page.dart';
import 'package:dsh_app/ui/pets/overlay_settings_tile.dart';
import 'package:dsh_app/ui/pets/pet_settings_page.dart';
import 'package:dsh_app/ui/phone/phone_control_screen.dart';
import 'package:dsh_app/ui/phone/system_actions_page.dart';
import 'package:dsh_app/ui/plugins/native/native_taps.dart' show openNativePage;
import 'package:dsh_app/ui/safe_mode/engine_failure_card.dart';
import 'package:dsh_app/ui/settings/appearance/app_icon_picker.dart';
import 'package:dsh_app/ui/settings/appearance/appearance_page.dart';
import 'package:dsh_app/ui/settings/appearance/icon_shortcut_sheet.dart';
import 'package:dsh_app/ui/settings/appearance/launch_screen_section.dart';
import 'package:dsh_app/ui/settings/appearance/wallpaper_section.dart';
import 'package:dsh_app/ui/settings/background_guide_page.dart';
import 'package:dsh_app/ui/settings/index/spot_anchor.dart';
import 'package:dsh_app/ui/settings/index/spots.dart';
import 'package:dsh_app/ui/settings/performance_page.dart';
import 'package:dsh_app/ui/settings/search/settings_search.dart';
import 'package:dsh_app/ui/settings/search/settings_search_page.dart';
import 'package:dsh_app/ui/settings/settings_screen.dart';
import 'package:dsh_app/ui/settings/system_access_page.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../onboarding/parallel_setup_support.dart';
import '../pets/support.dart' show FixedPetPrefs, diskPack;
import '../phone/support.dart' show FixedActiveHost, FixedHosts;
import '../safe_mode/support.dart' show FakeBridge, failedAt;
import '../shell/golden_harness.dart';

const _pages = {
  'page:phone',
  'page:phoneAppRules',
  'page:phoneAlwaysAllow',
  'page:phoneAndroidShell',
  'page:phoneDnd',
  'page:phoneUnlocks',
};
const _rows = {
  'phone-a11y-restore',
  'phone-confirm',
  'phone-auto-collapse',
  'phone-edge-glow',
  'phone-system-island',
  'phone-return',
  'phone-background-guide',
  'phone-files',
  'permission-phone-confirm',
  'pet-outside-app',
  'pet-display-when',
  'pet-overlay-shows',
  'pet-overlay-framing',
  'auto-safe',
};

final _zh = lookupL10n(AppLocale.zhCN);
final _en = lookupL10n(AppLocale.en);

List<Override> _on({required bool android, String? os, RuntimeStatus status = runningStatus}) => [
  operatingSystemProvider.overrideWithValue(os ?? (android ? 'android' : 'ohos')),
  activeHostProvider.overrideWith(() => FixedActiveHost(HostRef.local)),
  hostsProvider.overrideWith(FixedHosts.new),
  localRuntimeProvider.overrideWith(() => FakeRuntime(LocalRuntimeState(loaded: true, status: status))),
  settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
];

/// A surface tall enough that a list page builds every row.
Future<void> _pump(
  WidgetTester tester,
  Widget home, {
  required bool android,
  String? os,
  List<Override> overrides = const [],
}) async {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = const Size(390 * 2, 3600 * 2);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    goldenApp(
      home: home,
      brightness: Brightness.light,
      overrides: [
        ..._on(android: android, os: os),
        ...overrides,
      ],
    ),
  );
  await tester.pumpAndSettle();
}

class _NotExempt extends FakeBridge {
  @override
  Future<bool?> batteryExempt() async => false;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('everything but ohos and ios counts as Android, so tests run on the Android path', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(androidSystemFeaturesProvider), isTrue);
  });

  group('the index', () {
    test('Android\'s own is exactly these pages and rows', () {
      expect(
        {
          for (final spot in SettingsIndex.spots)
            if (SettingsIndex.androidOnly(spot)) spot.id,
        },
        {..._pages, ..._rows},
      );
    });

    test('links to them are known by name', () {
      for (final id in ['phone', 'phone-unlocks', 'phone-confirm', 'phone-files']) {
        expect(SettingsIndex.androidOnlyLink(id), isTrue, reason: id);
      }
      for (final id in ['engine', 'appearance', 'dark-mode', 'background', 'system-permissions', 'nope']) {
        expect(SettingsIndex.androidOnlyLink(id), isFalse, reason: id);
      }
    });

    test('HarmonyOS\'s own are 系统操作 and Linux 环境', () {
      expect(
        {
          for (final spot in SettingsIndex.spots)
            if (spot.ohosOnly) spot.id,
        },
        {'page:systemActions', 'page:linuxEnvironment'},
      );
      expect(SettingsIndex.ohosOnlyLink('system-actions'), isTrue);
      expect(SettingsIndex.ohosOnlyLink('phone'), isFalse);
    });
  });

  group('settings hub', () {
    const both = ['page:background', 'page:systemAccess'];

    testWidgets('on Android: phone control, background and system access', (tester) async {
      await _pump(tester, const SettingsScreen(), android: true);
      for (final id in ['page:phone', ...both]) {
        expect(find.byKey(SpotKey(id)), findsOneWidget, reason: id);
      }
      expect(find.byKey(const SpotKey('page:systemActions')), findsNothing);
      expect(find.text(_zh.systemActionsTitle), findsNothing);
    });

    testWidgets('on HarmonyOS: 系统操作 instead of phone control, every group still there', (tester) async {
      await _pump(tester, const SettingsScreen(), android: false);
      expect(find.byKey(const SpotKey('page:phone')), findsNothing);
      expect(find.byKey(const SpotKey('page:systemActions')), findsOneWidget);
      expect(find.text(_zh.systemActionsTitle), findsOneWidget);
      for (final id in both) {
        expect(find.byKey(SpotKey(id)), findsOneWidget, reason: id);
      }
      expect(find.text('手机操控'), findsNothing);
      expect(find.byKey(const SpotKey('page:webSearch')), findsOneWidget);
      expect(find.byKey(const SpotKey('page:privacy')), findsOneWidget);
    });

    for (final android in [true, false]) {
      testWidgets('后台运行 reports the battery exemption with android=$android', (tester) async {
        await _pump(
          tester,
          const SettingsScreen(),
          android: android,
          overrides: [runtimeBridgeProvider.overrideWithValue(_NotExempt())],
        );
        expect(
          find.descendant(
            of: find.byKey(const SpotKey('page:background')),
            matching: find.text(_zh.hubValueNeedsSetup),
          ),
          android ? findsOneWidget : findsNothing,
        );
        expect(find.text(_zh.hubValueAllowed), findsNothing);
      });
    }
  });

  group('全部功能', () {
    testWidgets('on Android: 手机操控 is a card', (tester) async {
      await _pump(tester, const AllFeaturesPage(), android: true);
      expect(find.text('手机操控'), findsOneWidget);
      expect(find.text(_zh.catalogSystemActions), findsNothing);
    });

    testWidgets('on HarmonyOS: 系统操作 in its place, the rest of its group stays', (tester) async {
      await _pump(tester, const AllFeaturesPage(), android: false);
      expect(find.text('手机操控'), findsNothing);
      expect(find.text(_zh.catalogSystemActions), findsOneWidget);
      expect(find.text(_zh.catalogModels), findsOneWidget);
      expect(find.byKey(const ValueKey('all-settings')), findsOneWidget);
    });
  });

  group('search', () {
    List<String> ids(String q, {required bool android}) => [
      for (final h in searchSettings(
        q,
        spots: SettingsIndex.spots,
        features: featureSections,
        zh: _zh,
        en: _en,
        androidFeatures: android,
      ))
        h.spot?.id ?? 'feature:${h.feature!.id}',
    ];

    test('on Android: found by name in both languages', () {
      expect(ids('手机操控', android: true), contains('page:phone'));
      expect(ids('phone control', android: true), contains('page:phone'));
      expect(ids('后台', android: true), contains('page:background'));
      expect(ids('电池优化', android: true), contains('page:background'));
      expect(ids('桌面图标', android: true), contains('app-icon'));
      expect(ids('悬浮窗', android: true), contains('pet-outside-app'));
      expect(ids('系统操作', android: true), isNot(contains('page:systemActions')));
      expect(ids('日历', android: true), isNot(contains('page:systemActions')));
    });

    test('on HarmonyOS: the words for what isn\'t there don\'t lead to pages without it', () {
      for (final q in ['取色', 'wallpaper']) {
        expect(ids(q, android: false), isNot(contains('accent')), reason: q);
        expect(ids(q, android: true), contains('accent'), reason: q);
      }
      for (final q in ['悬浮', 'overlay']) {
        expect(ids(q, android: false), isNot(contains('page:pets')), reason: q);
        expect(ids(q, android: true), contains('page:pets'), reason: q);
      }
      expect(ids('主题色', android: false), contains('accent'));
      expect(ids('桌宠', android: false), contains('page:pets'));
    });

    test('what isn\'t there isn\'t promised for later', () {
      for (final l in [_zh, _en]) {
        for (final text in [l.harmonyPageUnavailable, l.harmonySearchUnavailable]) {
          expect(text, isNot(contains('暂时')), reason: text);
          expect(text, isNot(contains('yet')), reason: text);
        }
      }
    });

    test('the progress notification goes by its own name on HarmonyOS, the live activity on Android', () {
      for (final q in ['进度通知', '通知栏进度', '显示进度通知', 'progress notification']) {
        expect(ids(q, android: false), contains('notify-live'), reason: q);
        expect(ids(q, android: true), isNot(contains('notify-live')), reason: q);
      }
      for (final q in ['实时活动', '灵动岛', 'live activity']) {
        expect(ids(q, android: true), contains('notify-live'), reason: q);
        expect(ids(q, android: false), isNot(contains('notify-live')), reason: q);
      }
    });

    test('on HarmonyOS: 系统操作 by its name and what it does, in both languages', () {
      for (final q in [
        '系统操作',
        'system actions',
        '拨号',
        'dialer',
        '发通知',
        '写剪贴板',
        'clipboard',
        '手机操控',
        '操作手机',
        '代操作',
        'phone control',
      ]) {
        expect(ids(q, android: false), contains('page:systemActions'), reason: q);
      }
      // Its words don't promise what it can't do.
      for (final q in ['无障碍', '点按', 'tap', 'accessibility']) {
        expect(ids(q, android: false), isNot(contains('page:systemActions')), reason: q);
      }
    });

    test('on HarmonyOS: nothing of Android\'s by any of its names, the rest as before', () {
      for (final spot in SettingsIndex.spots.where(SettingsIndex.androidOnly)) {
        for (final name in [spot.title(_zh), spot.title(_en)]) {
          final found = ids(name, android: false);
          expect(found.toSet().intersection({..._pages, ..._rows}), isEmpty, reason: name);
        }
      }
      expect(ids('深色', android: false), contains('dark-mode'));
      expect(ids('引擎', android: false), contains('page:engine'));
    });

    test('on HarmonyOS: 后台运行 by what happens there, not by a battery switch it hasn\'t got', () {
      for (final q in ['后台', '后台运行', '杀后台', '挂起', 'suspended']) {
        expect(ids(q, android: false), contains('page:background'), reason: q);
      }
      for (final q in ['电池优化', '自启动', 'autostart']) {
        expect(ids(q, android: false), isNot(contains('page:background')), reason: q);
      }
    });

    testWidgets('on Android: the page offers 后台运行 and lists the page', (tester) async {
      await _pump(tester, const SettingsSearchPage(), android: true);
      expect(find.text(_zh.searchSuggestBackground), findsOneWidget);
      await tester.enterText(find.byType(TextField), '手机操控');
      await tester.pumpAndSettle();
      expect(find.text('手机操控'), findsWidgets);
      expect(find.text(_zh.searchNoResults), findsNothing);
    });

    testWidgets('on HarmonyOS: 后台运行 is there, 手机操控 finds 系统操作, and 无障碍 says it isn\'t', (tester) async {
      await _pump(tester, const SettingsSearchPage(), android: false);
      expect(find.text(_zh.searchSuggestBackground), findsOneWidget);
      expect(find.text(_zh.searchSuggestDark), findsOneWidget);
      await tester.enterText(find.byType(TextField), '手机操控');
      await tester.pumpAndSettle();
      expect(find.textContaining(_zh.systemActionsTitle, findRichText: true), findsWidgets);
      expect(find.text(_zh.harmonySearchUnavailable), findsNothing);
      await tester.enterText(find.byType(TextField), '无障碍');
      await tester.pumpAndSettle();
      expect(find.text(_zh.harmonySearchUnavailable), findsOneWidget);
      expect(find.text(_zh.searchNoResults), findsNothing);
    });
  });

  group('links', () {
    Widget? resolve(String id, {required bool android}) {
      final os = android ? 'android' : 'ohos';
      final container = ProviderContainer(overrides: [operatingSystemProvider.overrideWithValue(os)]);
      addTearDown(container.dispose);
      return container.read(pageLinkResolverProvider)(id, null);
    }

    test('on Android they open', () {
      expect(resolve('phone', android: true), isA<PhoneControlScreen>());
      expect(resolve('background', android: true), isNotNull);
      expect(resolve('system-permissions', android: true), isNotNull);
      expect(resolve('system-actions', android: true), isNull, reason: 'HarmonyOS\'s own');
    });

    test('on HarmonyOS 系统操作 stands in for 手机操控, and the rest say they aren\'t there', () {
      for (final id in ['phone', 'phone-unlocks']) {
        expect(resolve(id, android: false), isA<SystemActionsPage>(), reason: id);
      }
      expect(resolve('phone-confirm', android: false), isA<PermissionPage>());
      expect(resolve('phone-files', android: false), isNull);
      expect(resolve('system-actions', android: false), isA<SystemActionsPage>());
      expect(resolve('engine', android: false), isA<EngineScreen>());
      expect(resolve('background', android: false), isA<BackgroundGuidePage>());
      expect(resolve('system-permissions', android: false), isA<SystemAccessPage>());
    });

    for (final android in [true, false]) {
      Future<void> open(WidgetTester tester, String page) async {
        usePhoneSurface(tester);
        await tester.pumpWidget(
          goldenApp(
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) =>
                    TextButton(onPressed: () => openNativePage(context, ref, page), child: const Text('open')),
              ),
            ),
            brightness: Brightness.light,
            overrides: _on(android: android),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
      }

      testWidgets('a plugin\'s `open phone` with android=$android', (tester) async {
        await open(tester, 'phone');
        expect(find.byType(PhoneControlScreen), android ? findsOneWidget : findsNothing);
        expect(find.byType(SystemActionsPage), android ? findsNothing : findsOneWidget);
        expect(find.text(_zh.harmonyPageUnavailable), findsNothing);
      });

      testWidgets('a plugin\'s `open phone-files` with android=$android', (tester) async {
        await open(tester, 'phone-files');
        expect(find.text(_zh.harmonyPageUnavailable), android ? findsNothing : findsOneWidget);
      });

      testWidgets('a plugin\'s `open system-actions` with android=$android', (tester) async {
        await open(tester, 'system-actions');
        expect(find.byType(SystemActionsPage), android ? findsNothing : findsOneWidget);
      });
    }
  });

  group('the line about the background', () {
    for (final android in [true, false]) {
      testWidgets('in the shell: one of them with android=$android', (tester) async {
        usePhoneSurface(tester);
        await tester.pumpWidget(
          goldenApp(
            home: HomeShell(chatBuilder: (_) => const SizedBox.expand()),
            brightness: Brightness.light,
            overrides: _on(android: android),
          ),
        );
        await tester.pump();
        expect(find.byType(BackgroundNetHost), android ? findsOneWidget : findsNothing);
        expect(find.byType(BackgroundPauseHost), android ? findsNothing : findsOneWidget);
        // Away from the shell before its first timers matter.
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));
      });
    }
  });

  group('宠物设置', () {
    List<Override> pets() => [
      petPackProvider.overrideWith((ref, id) async => diskPack(id)),
      petPrefsProvider.overrideWith(() => FixedPetPrefs(const PetPrefs(loaded: true))),
    ];

    testWidgets('on Android: App 外显示', (tester) async {
      await _pump(tester, const PetSettingsPage(), android: true, overrides: pets());
      expect(find.byType(PetOverlaySettingsSection), findsOneWidget);
    });

    testWidgets('on HarmonyOS: the in-app pet\'s rows only', (tester) async {
      await _pump(tester, const PetSettingsPage(), android: false, overrides: pets());
      expect(find.byType(PetOverlaySettingsSection), findsNothing);
      expect(find.text(_zh.botsPetSize), findsOneWidget);
      expect(find.text(_zh.botsPetQuiet), findsOneWidget);
    });

    testWidgets('on iOS: the optional out-of-app pet section remains available', (tester) async {
      await _pump(tester, const PetSettingsPage(), android: false, os: 'ios', overrides: pets());
      expect(find.byType(PetOverlaySettingsSection), findsOneWidget);
    });
  });

  group('主题', () {
    testWidgets('on Android: launcher icon, picture shortcut, launch screen', (tester) async {
      await _pump(tester, const AppearancePage(), android: true);
      expect(find.byType(AppIconPicker), findsOneWidget);
      expect(find.byType(IconShortcutTile), findsOneWidget);
      expect(find.byType(LaunchScreenSection), findsOneWidget);
    });

    testWidgets('on HarmonyOS: the launcher icon, picture shortcut and launch screen, the rest of the page stays', (
      tester,
    ) async {
      await _pump(tester, const AppearancePage(), android: false);
      expect(find.byType(AppIconPicker), findsOneWidget);
      expect(find.text(_zh.pluginsAppIcon), findsOneWidget);
      expect(find.byType(IconShortcutTile), findsOneWidget);
      expect(find.byType(LaunchScreenSection), findsOneWidget);
      expect(find.text(_zh.launchScreenTitle), findsOneWidget);
      expect(find.byType(ThemeModePicker), findsOneWidget);
      expect(find.byType(WallpaperSection), findsOneWidget);
    });
  });

  group('主题 on iOS', () {
    Future<void> pump(WidgetTester tester) async {
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = const Size(390 * 2, 3600 * 2);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        goldenApp(
          home: const AppearancePage(),
          brightness: Brightness.light,
          overrides: _on(android: false, os: 'ios'),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('its own launch screen: Flutter draws it. No picture shortcut: nothing can pin one', (tester) async {
      await pump(tester);
      expect(find.byType(AppIconPicker), findsOneWidget);
      expect(find.byType(LaunchScreenSection), findsOneWidget);
      expect(find.byType(IconShortcutTile), findsNothing);
      expect(find.byType(WallpaperSection), findsOneWidget);
    });

    testWidgets('no 跟随壁纸: no wallpaper colour to follow', (tester) async {
      await pump(tester);
      expect(find.text(_zh.pluginsFollowWallpaper), findsNothing);
    });

    test(
      'iOS: the launch screen and engine reset are searchable, the picture shortcut isn\'t; HarmonyOS has all three',
      () {
        List<String> ids(String q, {required bool ios}) => [
          for (final h in searchSettings(
            q,
            spots: SettingsIndex.spots,
            features: featureSections,
            zh: _zh,
            en: _en,
            androidFeatures: false,
            ios: ios,
          ))
            h.spot?.id ?? 'feature:${h.feature!.id}',
        ];
        expect(ids(_zh.launchScreenTitle, ios: true), contains('launch-screen'));
        expect(ids(_zh.iconShortcutRow, ios: true), isNot(contains('icon-shortcut')));
        expect(ids(_zh.phoneEngineReset, ios: true), contains('engine-reset'));
        expect(ids(_zh.localEnvUninstall, ios: true), contains('engine-uninstall'));
        expect(ids(_zh.launchScreenTitle, ios: false), contains('launch-screen'));
        expect(ids(_zh.iconShortcutRow, ios: false), contains('icon-shortcut'));
        expect(ids(_zh.phoneEngineReset, ios: false), contains('engine-reset'));
      },
    );
  });

  group('性能', () {
    Finder refreshRate() => find.byKey(const ValueKey('performance-refresh-rate'));

    testWidgets('on Android: the refresh rate choice', (tester) async {
      await _pump(tester, const PerformancePage(), android: true);
      expect(refreshRate(), findsOneWidget);
      expect(find.byKey(const ValueKey('performance-frame-cache')), findsNothing);
    });

    testWidgets('on HarmonyOS: the refresh rate choice too, and what max costs', (tester) async {
      await _pump(tester, const PerformancePage(), android: false);
      expect(refreshRate(), findsOneWidget);
      expect(find.text(_zh.performanceRefreshHintOhos), findsOneWidget);
      expect(find.byKey(const ValueKey('performance-blur')), findsOneWidget);
    });

    testWidgets('on HarmonyOS: the frame cache, on until it is turned off', (tester) async {
      await _pump(tester, const PerformancePage(), android: false);
      final row = find.byKey(const ValueKey('performance-frame-cache'));
      expect(row, findsOneWidget);
      expect(find.text(_zh.performanceFrameCache), findsOneWidget);
      expect(find.text(_zh.performanceFrameCacheHint), findsOneWidget);
      expect(tester.widget<Switch>(find.descendant(of: row, matching: find.byType(Switch))).value, isTrue);
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(find.descendant(of: row, matching: find.byType(Switch))).value, isFalse);
    });
  });

  group('权限', () {
    List<Override> permission() => [
      activeConnectionProvider.overrideWithValue(const AsyncData(null)),
      permissionStateProvider.overrideWith((ref, id) => Future.error('offline')),
    ];

    testWidgets('on Android: the phone group', (tester) async {
      await _pump(tester, const PermissionPage(), android: true, overrides: permission());
      expect(find.text(_zh.hubPermissionPhone), findsOneWidget);
      expect(find.text(_zh.hubPermissionPhoneConfirm), findsOneWidget);
    });

    testWidgets('on HarmonyOS: no phone group', (tester) async {
      await _pump(tester, const PermissionPage(), android: false, overrides: permission());
      expect(find.text(_zh.hubPermissionPhone), findsNothing);
      expect(find.text(_zh.hubPermissionPhoneConfirm), findsNothing);
      expect(find.text(_zh.hubSettingsPhoneFiles), findsNothing);
    });
  });

  group('引擎', () {
    List<Override> bridge() => [runtimeBridgeProvider.overrideWithValue(FakeBridge())];

    testWidgets('on Android: safe mode, reset and uninstall', (tester) async {
      await _pump(tester, const EngineScreen(), android: true, overrides: bridge());
      expect(find.text(_zh.phoneEngineReset), findsOneWidget);
      expect(find.text(_zh.phoneSafeAutoSettingsHint), findsOneWidget);
      expect(find.text(_zh.engineStartReopensApp), findsNothing);
    });

    testWidgets('on HarmonyOS: reset, uninstall and safe mode by hand, and it says what starting again does', (
      tester,
    ) async {
      await _pump(tester, const EngineScreen(), android: false, overrides: bridge());
      expect(find.text(_zh.phoneEngineReset), findsOneWidget);
      expect(find.text(_zh.localEnvUninstall), findsOneWidget);
      expect(find.text(_zh.phoneSafeStartSettings), findsOneWidget);
      expect(find.text(_zh.phoneSafeAutoSettingsHint), findsNothing, reason: 'nothing there switches it on by itself');
      expect(find.text(_zh.engineStartReopensApp), findsOneWidget);
    });

    testWidgets('on Android: 后台保活 under 更多', (tester) async {
      await _pump(tester, const EngineScreen(), android: true, overrides: bridge());
      expect(find.byKey(const SpotKey('page:background')), findsOneWidget);
    });

    testWidgets('on HarmonyOS, a build that may ask for a long task: its hint says so', (tester) async {
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = const Size(390 * 2, 3600 * 2);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        goldenApp(
          home: const EngineScreen(),
          brightness: Brightness.light,
          overrides: [
            ..._on(android: false, status: const RuntimeStatus(phase: RuntimePhase.running, longTaskEligible: true)),
            ...bridge(),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(_zh.harmonyEngineBackgroundHintLong), findsOneWidget);
      expect(find.text(_zh.harmonyEngineBackgroundHint), findsNothing);
    });

    testWidgets('on HarmonyOS: 后台运行 under 更多, and what it says is true there', (tester) async {
      await _pump(tester, const EngineScreen(), android: false, overrides: bridge());
      expect(find.byKey(const SpotKey('page:background')), findsOneWidget);
      expect(find.byKey(const SpotKey('page:diagnostics')), findsOneWidget);
      expect(find.text(_zh.harmonyEngineBackgroundHint), findsOneWidget);
      expect(find.text(_zh.phoneEngineKeepAliveHint), findsNothing);
    });

    final killed = RuntimeStatus(
      phase: RuntimePhase.error,
      bundledVersion: 'r4',
      installedVersion: 'r4',
      failure: RuntimeFailure(kind: FailureKind.killed, at: failedAt),
    );

    for (final android in [true, false]) {
      testWidgets('killed: the failure card with android=$android', (tester) async {
        usePhoneSurface(tester);
        await tester.pumpWidget(
          goldenApp(
            home: const Scaffold(body: EngineFailureCard()),
            brightness: Brightness.light,
            overrides: [
              ..._on(android: android, status: killed),
              ...bridge(),
            ],
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text(_zh.phoneFailureKilled), findsOneWidget);
        expect(find.text(_zh.phoneEngineKeepAlive), findsOneWidget);
        expect(find.text(_zh.commonRetry), findsOneWidget);
      });
    }
  });

  group('first run', () {
    final harmony = [operatingSystemProvider.overrideWithValue('ohos')];

    testWidgets('on Android: 外观 → what DSH Go should do → 连接, four steps', (tester) async {
      final rig = await pumpGate(tester);
      await chooseThisPhone(tester);
      expect(find.bySemanticsLabel('第 2 步，共 4 步'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '继续'));
      await frames(tester);
      expect(find.byType(AccessStepPage), findsOneWidget);
      expect(rig.prefs.setupStep, SetupStep.access);
    });

    testWidgets('on HarmonyOS: the same four steps, with what it has to offer', (tester) async {
      final rig = await pumpGate(tester, overrides: harmony);
      expect(find.bySemanticsLabel('第 1 步，共 4 步'), findsOneWidget);
      await chooseThisPhone(tester);
      expect(find.bySemanticsLabel('第 2 步，共 4 步'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '继续'));
      await frames(tester);
      expect(find.byType(AccessStepPage), findsOneWidget);
      expect(find.bySemanticsLabel('第 3 步，共 4 步'), findsOneWidget);
      expect(find.text(_zh.accessFeatureAlerts), findsOneWidget);
      expect(find.text(_zh.accessFeatureVoice), findsOneWidget);
      expect(find.text(_zh.accessFeaturePhone), findsNothing);
      expect(rig.prefs.setupStep, SetupStep.access);

      await tester.tap(find.widgetWithText(TextButton, _zh.accessSkip));
      await frames(tester);
      expect(find.byType(ConnectPage), findsOneWidget);
      expect(find.bySemanticsLabel('第 4 步，共 4 步'), findsOneWidget);
      expect(rig.prefs.setupStep, SetupStep.connect);
    });

    testWidgets('on HarmonyOS, connected already: past the step, the waiting page', (tester) async {
      final rig = await pumpGate(
        tester,
        settings: const AppSettings(loaded: true, apiKey: 'sk-test'),
        overrides: harmony,
      );
      await chooseThisPhone(tester);
      await tester.tap(find.widgetWithText(FilledButton, '继续'));
      await frames(tester);
      await tester.tap(find.widgetWithText(TextButton, _zh.accessSkip));
      await frames(tester);
      expect(find.byType(RuntimeSetupPage), findsOneWidget);
      expect(rig.prefs.setupStep, SetupStep.finishing);
    });
  });

  group('relay', () {
    DshRemoteRelayBackend backend({required bool webRtc}) {
      final container = ProviderContainer(
        overrides: [
          secretStoreProvider.overrideWithValue(MemorySecretStore()),
          webRtcAvailableProvider.overrideWithValue(webRtc),
        ],
      );
      addTearDown(container.dispose);
      return container.read(relayBackendProvider) as DshRemoteRelayBackend;
    }

    test('on Android: direct first', () {
      final relay = backend(webRtc: true);
      expect(relay.peerConnector, flutterPeerConnector);
      expect(relay.account.peerConnector, flutterPeerConnector);
    });

    test('on HarmonyOS: straight to the relay', () {
      final relay = backend(webRtc: false);
      expect(relay.peerConnector, isNull);
      expect(relay.account.peerConnector, isNull);
    });
  });

  test("Android's own system features stay off HarmonyOS and iOS", () {
    expect(androidSystemFeaturesOn('android'), isTrue);
    expect(androidSystemFeaturesOn('ohos'), isFalse);
    expect(androidSystemFeaturesOn('ios'), isFalse);
  });

  test('turning those off on iOS leaves its WebRTC path alone', () {
    expect(webRtcOn('android'), isTrue);
    expect(webRtcOn('ios'), isTrue);
    expect(webRtcOn('ohos'), isFalse);
  });
}
