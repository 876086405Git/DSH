// Pages and the settings index agree: every settings page, pumped with
// everything it can show, carries exactly the rows the index lists for it —
// each once, each titled as the index says in Chinese and in English — and
// no settings row goes unlisted (choices in a list and rows that come and go
// with a moment's state are named below). Add a row without registering it,
// or drop one and leave it in the index, and this fails.

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/account_state.dart';
import 'package:dsh_app/state/balance_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/engine/engine_screen.dart';
import 'package:dsh_app/ui/engine_settings/engine_settings_hub.dart';
import 'package:dsh_app/ui/engine_settings/runtime_settings_pages.dart';
import 'package:dsh_app/ui/engine_settings/subagent_settings_page.dart';
import 'package:dsh_app/ui/engine_settings/web_search_page.dart';
import 'package:dsh_app/ui/features/permission_page.dart';
import 'package:dsh_app/ui/pets/pet_settings_page.dart';
import 'package:dsh_app/ui/common/list_page_row.dart';
import 'package:dsh_app/ui/phone/phone_control_screen.dart';
import 'package:dsh_app/ui/phone/phone_widgets.dart';
import 'package:dsh_app/ui/providers/providers_page.dart';
import 'package:dsh_app/ui/remote/remote_screen.dart';
import 'package:dsh_app/ui/settings/appearance/appearance_page.dart';
import 'package:dsh_app/ui/settings/about_page.dart';
import 'package:dsh_app/ui/settings/background_guide_page.dart';
import 'package:dsh_app/ui/settings/notification_settings.dart';
import 'package:dsh_app/ui/settings/interface_page.dart';
import 'package:dsh_app/ui/settings/performance_page.dart';
import 'package:dsh_app/ui/settings/personalization_page.dart';
import 'package:dsh_app/ui/settings/privacy_page.dart';
import 'package:dsh_app/ui/settings/settings_screen.dart';
import 'package:dsh_app/state/app_info.dart';
import 'package:dsh_app/ui/settings/index/spots.dart';
import 'package:dsh_app/ui/settings/settings_widgets.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../account/support.dart' show FixedAccount, sampleBalance, sampleProfile;
import '../../engine_settings/support.dart' as engine;
import '../../phone/harness.dart';
import '../../plugins/support/fake_plugin_host.dart';
import '../../providers/support.dart' as providers;
import '../../shell/golden_harness.dart';

/// Rows that carry no spot on purpose, by page: a choice in a list (the
/// list's spot covers it) or a row that only shows for a moment.
final Map<SettingsPageId, List<String Function(L10n)>> _unlisted = {
  // The author's profiles are links, not settings to look up.
  SettingsPageId.about: [(_) => AppInfo.author, (l) => l.hubAboutBilibili, (l) => l.hubAboutX, (l) => l.hubAboutGithub],
  SettingsPageId.performance: [
    (l) => l.performanceAuto,
    (l) => l.performanceFull,
    (l) => l.performanceLight,
    (l) => l.performanceFollowMode,
  ],
  SettingsPageId.pets: [(l) => l.botsPetShowNow, (l) => l.botsPetSwitchDisabled, (l) => l.botsPetHiddenToday],
  SettingsPageId.remote: [(l) => l.remoteWebConsole],
};

/// Entries whose row shows the thing itself rather than the page's name
/// (the overview card shows who is signed in).
const _ownTitle = {'page:account'};

/// Spots drawn as a section of the page (a picker, a card of choices): the
/// title is the section's heading, above the anchor.
const _sections = {
  'dark-mode',
  'accent',
  'tile-style',
  'app-icon',
  'launch-screen',
  'wallpaper',
  'permission-current',
  'permission-default',
  'ui-mode',
  'quick-panel',
  'table-tint',
  'web-app',
};

/// An entry may also sit on another page than its home (one page, more
/// than one way in; the name is the same).
const _aliases = {
  SettingsPageId.phone: {'page:background'},
  SettingsPageId.engine: {'page:background', 'page:diagnostics'},
};

/// Pumps the page in Chinese, checks it, then again in English.
Future<void> _check(
  WidgetTester tester,
  SettingsPageId page,
  Future<void> Function() pump, {
  Set<String> absent = const {},
}) async {
  addTearDown(() => AppLocale.use(AppLocale.zhCN));
  for (final locale in [AppLocale.zhCN, AppLocale.en]) {
    AppLocale.use(locale);
    await tester.pumpWidget(const SizedBox());
    await pump();
    await _expandFolds(tester);
    _verify(tester, page, appL10n, absent: absent);
  }
}

/// Folded rows are still real entries; open them before asserting reachability.
Future<void> _expandFolds(WidgetTester tester) async {
  for (var i = 0; i < find.byType(PhoneOptionsFold, skipOffstage: false).evaluate().length; i++) {
    final header = find
        .descendant(
          of: find.byType(PhoneOptionsFold, skipOffstage: false).at(i),
          matching: find.byType(ListPageRow, skipOffstage: false),
        )
        .first;
    await tester.ensureVisible(header);
    await tester.pumpAndSettle();
    await tester.tap(header, warnIfMissed: false);
    await tester.pumpAndSettle();
  }
}

void _verify(WidgetTester tester, SettingsPageId page, L10n l10n, {required Set<String> absent}) {
  final lang = l10n.localeName;
  // A plugin's own form is a row the host decides on (not in the table).
  final anchors = tester
      .widgetList<SpotAnchor>(find.byType(SpotAnchor, skipOffstage: false))
      .where((a) => !a.spot.id.startsWith(pluginFormPrefix))
      .toList();
  final ids = [for (final a in anchors) a.spot.id];

  expect(ids.toSet().length, ids.length, reason: '$page: a spot shows twice: $ids');
  final aliases = _aliases[page] ?? const {};
  for (final a in anchors) {
    expect(a.spot.page == page || aliases.contains(a.spot.id), isTrue, reason: '$page shows ${a.spot.id}');
  }
  final expected = {
    for (final s in SettingsIndex.on(page))
      if (!s.isEntry || SettingsIndex.page(s.opens!).row) s.id,
  }.difference(absent);
  expect(ids.toSet().difference(aliases), expected, reason: '$page ($lang)');

  for (final a in anchors) {
    if (_ownTitle.contains(a.spot.id)) continue;
    final titles = {a.spot.title(l10n), ?a.spot.altTitle?.call(l10n)};
    final inside = {
      for (final t in tester.widgetList<Text>(
        find.descendant(of: find.byWidget(a), matching: find.byType(Text), skipOffstage: false),
      ))
        ?t.data,
    };
    final shown = _sections.contains(a.spot.id)
        ? titles.any((t) => find.text(t, skipOffstage: false).evaluate().isNotEmpty)
        : titles.any(inside.contains);
    expect(shown, isTrue, reason: '${a.spot.id} ($lang): want one of $titles, the row says $inside');
  }

  final unlisted = {for (final t in _unlisted[page] ?? const <String Function(L10n)>[]) t(l10n)};
  for (final type in [SettingsTile, SettingsSwitchTile, SettingsSegmentTile]) {
    for (final element in find.byType(type, skipOffstage: false).evaluate()) {
      final covered =
          find.ancestor(of: find.byWidget(element.widget), matching: find.byType(SpotAnchor)).evaluate().isNotEmpty ||
          find.descendant(of: find.byWidget(element.widget), matching: find.byType(SpotAnchor)).evaluate().isNotEmpty;
      if (covered) continue;
      final texts = [
        for (final t in tester.widgetList<Text>(
          find.descendant(of: find.byWidget(element.widget), matching: find.byType(Text), skipOffstage: false),
        ))
          ?t.data,
      ];
      expect(texts.any(unlisted.contains), isTrue, reason: '$page ($lang): a settings row with no spot: $texts');
    }
  }
}

/// A tall phone, so each page is built top to bottom without scrolling.
Future<void> _app(WidgetTester tester, Widget home, List<Override> overrides) async {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = const Size(390 * 2, 3200 * 2);
  tester.view.padding = const FakeViewPadding(top: 64, bottom: 48);
  tester.view.viewPadding = const FakeViewPadding(top: 64, bottom: 48);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(goldenApp(home: home, brightness: Brightness.light, overrides: overrides));
  for (var i = 0; i < 4; i++) {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }
}

List<Override> _running() => [
  localRuntimeProvider.overrideWith(() => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus))),
  settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
];

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('设置', (tester) async {
    await _check(
      tester,
      SettingsPageId.hub,
      () => _app(
        tester,
        ProviderScope(
          overrides: [accountWalletBalanceProvider.overrideWithValue(sampleBalance)],
          child: const SettingsScreen(),
        ),
        [
          ..._running(),
          accountProvider.overrideWith(
            () =>
                FixedAccount(const AccountState(phase: AccountPhase.signedIn, connected: true, profile: sampleProfile)),
          ),
        ],
      ),
      // HarmonyOS's own pages: 系统操作 stands in for 手机操控, Linux 环境 is extra.
      absent: {'page:systemActions', 'page:linuxEnvironment'},
    );
  });

  testWidgets('个性化', (tester) async {
    await _check(
      tester,
      SettingsPageId.personalization,
      () => _app(tester, const PersonalizationPage(), _running()),
      // Only with this phone's engine files at hand.
      absent: {'page:replyPrefs'},
    );
  });

  testWidgets('关于 DSH Go', (tester) async {
    await _check(tester, SettingsPageId.about, () => _app(tester, const AboutPage(), _running()));
  });

  testWidgets('主题', (tester) async {
    await _check(tester, SettingsPageId.appearance, () => _app(tester, const AppearancePage(), _running()));
  });

  testWidgets('宠物', (tester) async {
    await _check(
      tester,
      SettingsPageId.pets,
      () => _app(tester, const PetSettingsPage(), _running()),
      // Once 「App 外显示」 is on.
      absent: {'pet-display-when', 'pet-overlay-shows', 'pet-overlay-framing'},
    );
  });

  testWidgets('性能', (tester) async {
    await _check(
      tester,
      SettingsPageId.performance,
      () => _app(tester, const PerformancePage(), _running()),
      // Only with animations on, which tests run without.
      absent: {'fluid-motion'},
    );
  });

  testWidgets('通知', (tester) async {
    await _check(
      tester,
      SettingsPageId.notifications,
      () => _app(tester, const NotificationSettingsPage(), _running()),
    );
  });

  testWidgets('后台运行', (tester) async {
    await _check(tester, SettingsPageId.background, () => _app(tester, const BackgroundGuidePage(), _running()));
  });

  testWidgets('本机引擎', (tester) async {
    await _check(tester, SettingsPageId.engine, () => _app(tester, const EngineScreen(), _running()));
  });

  testWidgets('手机操控', (tester) async {
    await _check(tester, SettingsPageId.phone, () async {
      await pumpPhone(tester, const PhoneControlScreen(), size: const Size(390, 4400));
    });
  });

  testWidgets('权限', (tester) async {
    final carrier = FakePluginCarrier();
    final client = DshClient.withCarrier(carrier);
    addTearDown(client.close);
    carrier.handlers['settings/describe'] = (_) => {
      'writable': true,
      'namespaces': [
        {
          'ns': 'permission',
          'value': {'defaultPreset': 'workspace-write'},
          'revision': 7,
        },
      ],
    };
    carrier.handlers['session/projections'] = (_) => {
      'kind': 'sequenced',
      'asOfSeq': 1,
      'values': {
        'permissions': {'currentValue': 'workspace-write'},
      },
    };
    const options = [
      {'value': 'read-only', 'name': 'read-only'},
      {'value': 'workspace-write', 'name': 'workspace-write'},
      {'value': 'danger-full-access', 'name': 'danger-full-access'},
    ];
    carrier.handlers['permissionPresets/catalog'] = (_) => {
      'options': options,
      'defaultOptions': options,
      'defaultPreset': 'workspace-write',
    };
    await _check(tester, SettingsPageId.permission, () async {
      await _app(tester, const PermissionPage(sessionId: 's1'), [
        activeConnectionProvider.overrideWithValue(AsyncData(engine.fakeConnection(client, local: false))),
        ..._running(),
      ]);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    });
  });

  testWidgets('模型', (tester) async {
    await _check(
      tester,
      SettingsPageId.models,
      () => _app(tester, const ProvidersPage(), providers.providerOverrides(providers.sampleBackend())),
    );
  });

  testWidgets('远程主机', (tester) async {
    await _check(
      tester,
      SettingsPageId.remote,
      () => _app(tester, const RemoteScreen(), _running()),
      // Once there is a host to come back to; 直连优先 once signed in to DSH Remote.
      absent: {'remote-auto-connect', 'remote-direct'},
    );
  });

  group('引擎参数', () {
    Future<void> pumpEngine(WidgetTester tester, Widget page) async {
      final host = engine.FakeSettingsHost();
      await engine.pumpPage(tester, page, overrides: engine.engineOverrides(DshClient.withCarrier(host)), height: 3200);
    }

    testWidgets('引擎参数', (tester) async {
      await _check(tester, SettingsPageId.engineParams, () => pumpEngine(tester, const EngineSettingsHubPage()));
    });
    testWidgets('子代理', (tester) async {
      await _check(tester, SettingsPageId.subagent, () => pumpEngine(tester, const SubagentSettingsPage()));
    });
    testWidgets('Agent 循环', (tester) async {
      await _check(tester, SettingsPageId.agentLoop, () => pumpEngine(tester, const AgentLoopSettingsPage()));
    });
    testWidgets('命令执行', (tester) async {
      await _check(tester, SettingsPageId.shell, () => pumpEngine(tester, const ShellSettingsPage()));
    });
    testWidgets('联网搜索', (tester) async {
      await _check(tester, SettingsPageId.webSearch, () => pumpEngine(tester, const WebSearchSettingsPage()));
    });
    testWidgets('界面', (tester) async {
      await _check(tester, SettingsPageId.interface, () => pumpEngine(tester, const InterfacePage()));
    });
    testWidgets('隐私与分享', (tester) async {
      await _check(tester, SettingsPageId.privacy, () => pumpEngine(tester, const PrivacyPage()));
    });
  });
}
