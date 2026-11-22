// Settings search: what a query finds and in what order, in Chinese and
// English alike; the page around it (common words, recent searches, a result
// opening its page at the row, a row that isn't there right now, 问 AI when
// nothing matched and not in 网页模式, what only Android has on HarmonyOS); and
// the two ways in (the hub's capsule, ⚙ held down in the drawer).

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/state/ask_ai.dart';
import 'package:dsh_app/state/compose_inbox.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/features/feature_catalog.dart';
import 'package:dsh_app/ui/settings/index/spot_anchor.dart';
import 'package:dsh_app/ui/settings/index/spots.dart';
import 'package:dsh_app/ui/settings/search/settings_search.dart';
import 'package:dsh_app/ui/settings/search/settings_search_page.dart';
import 'package:dsh_app/ui/settings/settings_screen.dart';
import 'package:dsh_app/ui/shell/sessions_drawer.dart' show IdentityBar;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../phone/support.dart' show FixedActiveHost, FixedHosts;
import '../../shell/golden_harness.dart';

final _zh = lookupL10n(AppLocale.zhCN);
final _en = lookupL10n(AppLocale.en);

List<SearchHit> _search(String q) =>
    searchSettings(q, spots: SettingsIndex.spots, features: featureSections, zh: _zh, en: _en);

List<String> _ids(String q) => [for (final h in _search(q)) h.spot?.id ?? 'feature:${h.feature!.id}'];

List<Override> _overrides({HostRef host = HostRef.local}) => [
  activeHostProvider.overrideWith(() => FixedActiveHost(host)),
  hostsProvider.overrideWith(FixedHosts.new),
  localRuntimeProvider.overrideWith(() => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus))),
  settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
  guidePageReaderProvider.overrideWithValue((asset) async => '# 设置'),
];

Future<void> _pumpSearch(WidgetTester tester, {List<Override>? overrides}) async {
  usePhoneSurface(tester);
  await tester.pumpWidget(
    goldenApp(home: const SettingsSearchPage(), brightness: Brightness.light, overrides: overrides ?? _overrides()),
  );
  await tester.pumpAndSettle();
}

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pumpAndSettle();
}

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('matching', () {
    test('a catalog resolves its words once across query edits', () {
      var titles = 0;
      var keywords = 0;
      final spot = SettingSpot(
        'counted',
        page: SettingsPageId.about,
        title: (_) {
          titles++;
          return 'Alpha';
        },
        keywords: (_) {
          keywords++;
          return 'First, 首个';
        },
      );
      final index = SettingsSearchIndex(spots: [spot], features: const [], zh: _zh, en: _en);
      expect((titles, keywords), (2, 2));
      for (final query in ['a', 'al', 'alpha', 'first', '首个']) {
        expect(index.search(query).single.spot, same(spot));
      }
      expect(index.search('missing'), isEmpty);
      expect((titles, keywords), (2, 2));
      expect(index.search('First').single.synonym, 'First');
    });

    test('iOS search keeps the available PiP setting and filters unsupported renderer controls', () {
      List<String?> ids(String query) => [
        for (final hit in searchSettings(
          query,
          spots: SettingsIndex.spots,
          features: const [],
          zh: _zh,
          en: _en,
          androidFeatures: false,
          ios: true,
        ))
          hit.spot?.id,
      ];
      expect(ids('桌面宠物'), contains(Spots.petOutsideApp.id));
      expect(ids('悬浮窗里显示'), isNot(contains(Spots.petOverlayShows.id)));
    });

    test('Android system commands find the phone page, not the engine shell', () {
      final androidShell = SettingsIndex.entry(SettingsPageId.phoneAndroidShell);
      for (final query in ['Android Shell', '系统命令', 'system-command']) {
        expect(_search(query).first.spot, androidShell, reason: query);
      }
      expect(_search('bash').first.spot, SettingsIndex.entry(SettingsPageId.shell));
    });

    test('「始终允许」 finds the always-allow page', () {
      final alwaysAllow = SettingsIndex.entry(SettingsPageId.phoneAlwaysAllow);
      for (final query in ['始终允许', 'always allow']) {
        expect(_ids(query).first, alwaysAllow.id, reason: query);
      }
      expect(_ids('不再询问'), contains(alwaysAllow.id));
    });

    test('lower case, full width folded, spaces dropped', () {
      expect(normalizeQuery('ＡＰＩ　Key'), 'apikey');
      expect(normalizeQuery(' Dark  Mode '), 'darkmode');
      expect(normalizeQuery('深 色'), '深色');
    });

    test('「深色」 and 「dark」 both find 外观 first, whatever the app language', () {
      expect(_ids('深色').first, Spots.darkMode.id);
      expect(_ids('dark').first, Spots.darkMode.id);
      expect(_ids('Dark mode').first, Spots.darkMode.id);
    });

    test('「统计」「隐私」「数据」 and 「analytics」 find 发送匿名使用统计', () {
      expect(_ids('统计').first, Spots.usageStats.id);
      expect(_ids('使用统计').first, Spots.usageStats.id);
      expect(_ids('analytics').first, Spots.usageStats.id);
      expect(_ids('usage stats').first, Spots.usageStats.id);
      for (final q in ['隐私', '数据', 'privacy', 'telemetry']) {
        expect(_ids(q), contains(Spots.usageStats.id), reason: q);
      }
      expect(SettingsIndex.trail(Spots.usageStats, _zh), ['设置', '隐私与分享', '发送匿名使用统计']);
    });

    test('「保活」 and 「后台保活」 find 后台运行 by the old names, and say so', () {
      final hit = _search('保活').first;
      expect(hit.spot, SettingsIndex.entry(SettingsPageId.background));
      expect(hit.synonym, '保活');
      expect(_search('后台保活').first.spot, SettingsIndex.entry(SettingsPageId.background));
      final title = _search('后台运行').first;
      expect(title.spot, SettingsIndex.entry(SettingsPageId.background));
      expect(title.synonym, isNull);
    });

    test('renamed pages answer to their old names', () {
      for (final (old, page) in [
        ('模型渠道', SettingsPageId.models),
        ('引擎设置', SettingsPageId.engineParams),
        ('语音识别', SettingsPageId.voice),
        ('通用设置', SettingsPageId.interface),
      ]) {
        expect(_ids(old), contains(SettingsIndex.entry(page).id), reason: old);
      }
      expect(_ids('引擎'), contains(SettingsIndex.entry(SettingsPageId.engine).id));
    });

    test('「别问我」 and 「自动执行命令」 both find 权限', () {
      final permission = SettingsIndex.entry(SettingsPageId.permission).id;
      expect(_ids('别问我'), contains(permission));
      expect(_ids('自动执行命令'), contains(permission));
      // Gone from the hub: it is 权限's 完全权限 now.
      expect(_ids('自动执行命令').first, permission);
    });

    test('「api key」 finds the account and web search', () {
      final ids = _ids('api key');
      expect(ids, contains(SettingsIndex.entry(SettingsPageId.account).id));
      expect(ids, contains(Spots.webSearchKey.id));
    });

    test('「宠物」: the pets page first', () {
      expect(_ids('宠物').first, SettingsIndex.entry(SettingsPageId.pets).id);
      expect(_ids('pets').first, SettingsIndex.entry(SettingsPageId.pets).id);
    });

    test('a title beats a synonym, a synonym the path; frequent wins a tie', () {
      final hits = _search('通知');
      expect(hits.first.match, SearchMatch.titleExact);
      for (final (a, b) in [for (var i = 1; i < hits.length; i++) (hits[i - 1], hits[i])]) {
        expect(a.score, greaterThanOrEqualTo(b.score));
      }
    });

    test('全部功能 cards are searched too, but not the ones that open a settings page', () {
      expect(_ids('自动化'), contains('feature:schedules'));
      expect(_ids('Automations'), contains('feature:schedules'));
      expect(_ids('权限').where((id) => id.startsWith('feature:')), isEmpty);
    });

    test('at most twenty, none for an empty query', () {
      expect(_search('设置').length, lessThanOrEqualTo(searchLimit));
      expect(_search('  '), isEmpty);
    });
  });

  group('the page', () {
    testWidgets('before typing: common words fill the field', (tester) async {
      await _pumpSearch(tester);
      for (final word in SettingsSearchPage.suggestions(_zh)) {
        expect(find.text(word), findsOneWidget);
      }
      await tester.tap(find.text('深色模式'));
      await tester.pumpAndSettle();
      expect(find.textContaining('外观'), findsWidgets);
      expect(find.text('设置 › 外观 › 主题'), findsOneWidget);
    });

    testWidgets('a synonym hit names the synonym after the title', (tester) async {
      await _pumpSearch(tester);
      await _type(tester, '别问我');
      expect(find.textContaining(' · 别问我'), findsWidgets);
    });

    testWidgets('a result opens its page at the row, back comes here, and the search is remembered', (tester) async {
      await _pumpSearch(tester);
      await _type(tester, '字号');
      await tester.tap(find.text('对话字号'));
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(find.byType(SpotFocus), findsOneWidget);
      final row = tester.getRect(find.byKey(SpotKey(Spots.chatTextSize.id)));
      expect(row.top, greaterThan(0));
      expect(row.bottom, lessThan(844));
      await tester.pump(const Duration(seconds: 2));

      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();
      expect(find.byType(SettingsSearchPage), findsOneWidget);
      expect(_container(tester).read(recentSearchesProvider), ['字号']);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(RecentSearches.key), ['字号']);
    });

    testWidgets('recent searches show before typing and fill the field', (tester) async {
      SharedPreferences.setMockInitialValues({
        RecentSearches.key: ['保活', 'api key'],
      });
      await _pumpSearch(tester);
      expect(find.text('最近'), findsOneWidget);
      await tester.tap(find.text('保活'));
      await tester.pumpAndSettle();
      expect(find.text('后台运行 · 保活'), findsOneWidget);
    });

    testWidgets('a row that isn\'t there right now says why', (tester) async {
      await _pumpSearch(tester, overrides: _overrides(host: const HostRef.ssh('lab')));
      await _type(tester, '个人偏好');
      expect(find.text('连接本机时可用'), findsOneWidget);
    });

    testWidgets('nothing found: 问 AI with the question as typed, into a new chat', (tester) async {
      await _pumpSearch(tester);
      await _type(tester, '怎么把对话导出成 PDF');
      expect(find.text('没有找到相关设置'), findsOneWidget);
      await tester.tap(find.text('问 AI：「怎么把对话导出成 PDF」'));
      await tester.pumpAndSettle();
      expect(_container(tester).read(composeInboxProvider).single.text, '/dsh-go-guide 怎么把对话导出成 PDF');
    });

    testWidgets('no 问 AI in 网页模式', (tester) async {
      await _pumpSearch(tester, overrides: [..._overrides(), askAiAvailableProvider.overrideWithValue(false)]);
      await _type(tester, '怎么把对话导出成 PDF');
      expect(find.text('没有找到相关设置'), findsOneWidget);
      expect(find.textContaining('问 AI'), findsNothing);
    });

    testWidgets('on HarmonyOS: the launcher icon, launch screen and picture shortcut are all there', (tester) async {
      await _pumpSearch(tester, overrides: [..._overrides(), operatingSystemProvider.overrideWithValue('ohos')]);
      for (final q in [_zh.pluginsAppIcon, _zh.launchScreenTitle, _zh.iconShortcutRow]) {
        await _type(tester, q);
        expect(find.text(q), findsWidgets, reason: q);
        expect(find.text(_zh.harmonySearchUnavailable), findsNothing, reason: q);
      }
    });

    testWidgets('on HarmonyOS: what only Android has says so, a typo stays a typo', (tester) async {
      await _pumpSearch(tester, overrides: [..._overrides(), operatingSystemProvider.overrideWithValue('ohos')]);
      for (final q in ['悬浮窗', '无障碍', '电池优化']) {
        await _type(tester, q);
        expect(find.text(_zh.harmonySearchUnavailable), findsOneWidget, reason: q);
        expect(find.text('没有找到相关设置'), findsNothing, reason: q);
      }
      // 手机操控 by its old name finds what stands in for it there.
      for (final q in ['手机操控', 'phone control']) {
        await _type(tester, q);
        expect(find.text(_zh.harmonySearchUnavailable), findsNothing, reason: q);
        expect(find.textContaining(_zh.systemActionsTitle, findRichText: true), findsWidgets, reason: q);
      }
      await _type(tester, '怎么把对话导出成 PDF');
      expect(find.text('没有找到相关设置'), findsOneWidget);
      expect(find.text(_zh.harmonySearchUnavailable), findsNothing);
      await _type(tester, '后台运行');
      expect(find.text('没有找到相关设置'), findsNothing);
      expect(find.text(_zh.harmonySearchUnavailable), findsNothing);
    });

    testWidgets('on HarmonyOS: the progress notification is listed by its own name', (tester) async {
      await _pumpSearch(tester, overrides: [..._overrides(), operatingSystemProvider.overrideWithValue('ohos')]);
      await _type(tester, '进度通知');
      expect(find.text(_zh.harmonyLiveSwitch), findsOneWidget);
      expect(find.text(_zh.liveSettingsSwitch), findsNothing);
    });

    testWidgets('on Android: those words find their pages, and it never says so', (tester) async {
      await _pumpSearch(tester, overrides: [..._overrides(), operatingSystemProvider.overrideWithValue('android')]);
      for (final q in ['悬浮窗', '手机操控', '无障碍', 'phone control', '电池优化']) {
        await _type(tester, q);
        expect(find.text('没有找到相关设置'), findsNothing, reason: q);
        expect(find.text(_zh.harmonySearchUnavailable), findsNothing, reason: q);
      }
      await _type(tester, '怎么把对话导出成 PDF');
      expect(find.text('没有找到相关设置'), findsOneWidget);
      expect(find.text(_zh.harmonySearchUnavailable), findsNothing);
    });
  });

  group('ways in', () {
    testWidgets('the hub\'s capsule opens search', (tester) async {
      usePhoneSurface(tester);
      await tester.pumpWidget(
        goldenApp(home: const SettingsScreen(), brightness: Brightness.light, overrides: _overrides()),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-search')));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsSearchPage), findsOneWidget);
    });

    testWidgets('⚙ held down in the drawer goes to search; a tap still opens settings', (tester) async {
      var held = 0;
      var tapped = 0;
      await tester.pumpWidget(
        goldenApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: IdentityBar(
                onHost: () {},
                onFeatures: () {},
                onSettings: () => tapped++,
                onSettingsHold: () => held++,
              ),
            ),
          ),
          brightness: Brightness.light,
          overrides: _overrides(),
        ),
      );
      await tester.pumpAndSettle();
      final gear = find.bySemanticsLabel('设置');
      await tester.longPress(gear);
      await tester.pumpAndSettle();
      expect((held, tapped), (1, 0));
      await tester.tap(gear);
      await tester.pumpAndSettle();
      expect((held, tapped), (1, 1));
    });
  });
}
