// Installs from before usage statistics: the first time they reach the home,
// one toast says so (了解 → 设置 › 隐私与分享, 关闭 → off), and only from then
// on is anything counted. Once only; never during first run; never over
// another page; 关闭 means not one request. Goldens light and dark, and the
// toast measured: as far from either screen edge, the text 16 in on the
// left, the last key's label 16 in on the right.
//
//   flutter test --update-goldens test/usage/usage_upgrade_notice_test.dart

import 'dart:async';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/settings/index/spot_anchor.dart';
import 'package:dsh_app/ui/settings/privacy_page.dart';
import 'package:dsh_app/ui/shell/root_gate.dart';
import 'package:dsh_app/ui/shell/usage_upgrade_notice.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_app/usage/usage_net.dart';
import 'package:dsh_app/usage/usage_stats.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../engine_settings/support.dart' as engine;
import '../shell/golden_harness.dart';
import 'support.dart';

const _notice = ValueKey('usage-upgrade-notice');

late FakeUsageHttp http;
late DateTime now;
VoidCallback? resume;

List<Override> _overrides() => [
  ...usageOverrides(clock: () => now, http: http, onResumes: (r) => resume = r),
  ...engine.engineOverrides(DshClient.withCarrier(engine.FakeSettingsHost())),
];

/// The home stand-in, under the notice as the root gate puts it.
Widget _home() => UsageUpgradeNotice(
  child: AppBackdrop(
    child: Scaffold(
      backgroundColor: Colors.transparent,
      body: Builder(builder: (context) => const SizedBox.expand()),
    ),
  ),
);

Future<void> _pumpHome(WidgetTester tester, {Brightness brightness = Brightness.light}) async {
  usePhoneSurface(tester);
  await tester.pumpWidget(goldenApp(home: _home(), brightness: brightness, overrides: _overrides()));
  await tester.pump();
}

/// Past the notice's delay, and its slide in.
Future<void> _wait(WidgetTester tester, [Duration time = const Duration(seconds: 2)]) async {
  await tester.pump(time);
  await tester.pump(const Duration(milliseconds: 400));
}

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));

Future<Map<String, Object>> _stored(WidgetTester tester) async {
  final prefs = (await tester.runAsync(SharedPreferences.getInstance))!;
  return {for (final k in prefs.getKeys()) k: prefs.get(k)!};
}

/// The app coming back to the front.
Future<void> _comeBack(WidgetTester tester) async {
  resume!();
  await tester.pump();
  await tester.pump();
}

void main() {
  final wasActive = UsageBuild.active;
  setUp(() {
    UsageBuild.active = true;
    http = FakeUsageHttp();
    now = DateTime(2026, 10, 30, 9);
    resume = null;
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() => UsageBuild.active = wasActive);

  for (final brightness in Brightness.values) {
    final mode = brightness == Brightness.dark ? 'dark' : 'light';
    testWidgets('the toast ($mode)', (tester) async {
      await tester.runAsync(loadGoldenFonts);
      await _pumpHome(tester, brightness: brightness);
      await _wait(tester);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/usage_notice_$mode.png'));
    });
  }

  for (final english in [false, true]) {
    testWidgets('mirrored: 16 in on either side, as far from either screen edge (${english ? 'en' : 'zh'})', (
      tester,
    ) async {
      await tester.runAsync(loadGoldenFonts);
      if (english) {
        AppLocale.use(AppLocale.en);
        addTearDown(() => AppLocale.use(AppLocale.zhCN));
      }
      await _pumpHome(tester);
      await _wait(tester);
      final bar = tester.getRect(find.descendant(of: find.byKey(_notice), matching: find.byType(Material)).first);
      final text = tester.getRect(find.byKey(const ValueKey('usage-upgrade-text')));
      final last = tester.getRect(
        find.descendant(of: find.byKey(const ValueKey('usage-upgrade-off')), matching: find.byType(Text)),
      );
      final learn = tester.getRect(
        find.descendant(of: find.byKey(const ValueKey('usage-upgrade-learn')), matching: find.byType(Text)),
      );
      expect(bar.left, moreOrLessEquals(390 - bar.right, epsilon: 0.01));
      expect(text.left - bar.left, moreOrLessEquals(16, epsilon: 0.01));
      expect(bar.right - text.right, moreOrLessEquals(16, epsilon: 0.01), reason: 'the text box keeps the same 16');
      expect(bar.right - last.right, moreOrLessEquals(16, epsilon: 0.01));
      // Both keys on one line, their labels level.
      expect(learn.center.dy, moreOrLessEquals(last.center.dy, epsilon: 0.01));
      expect(learn.right, lessThan(last.left));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('on HarmonyOS, where nothing is sent: no toast about it', (tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        home: _home(),
        brightness: Brightness.light,
        overrides: [..._overrides(), operatingSystemProvider.overrideWithValue('ohos')],
      ),
    );
    await tester.pump();
    await _wait(tester);
    expect(find.byKey(_notice), findsNothing);
  });

  testWidgets('an install from before: shown once, and told from then on', (tester) async {
    await _pumpHome(tester);
    expect(find.byKey(_notice), findsNothing, reason: 'not before the home has settled');
    await _wait(tester);
    expect(find.text(appL10n.usageUpgradeNotice), findsOneWidget);
    expect(_container(tester).read(usageStatsProvider).noticed, isTrue);
    expect((await _stored(tester))[UsageStatsController.noticedKey], isTrue);

    // It goes by itself after about 8 seconds.
    await tester.pump(usageNoticeDuration);
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(_notice), findsNothing);

    // The next launch, with what was kept: never again.
    final kept = await _stored(tester);
    await tester.pumpWidget(const SizedBox());
    SharedPreferences.setMockInitialValues(kept);
    await _pumpHome(tester);
    await _wait(tester, const Duration(seconds: 10));
    expect(find.byKey(_notice), findsNothing);
  });

  testWidgets('counting starts when it shows, not before', (tester) async {
    await _pumpHome(tester);
    final usage = _container(tester).read(usageStatsProvider.notifier);
    usage.count(UsageCount.turns);
    usage.count(UsageCount.turns);
    await tester.pump();
    expect((await _stored(tester)).containsKey(UsageStatsController.daysKey), isFalse);

    await _wait(tester);
    usage.count(UsageCount.turns);
    await tester.pump();
    now = DateTime(2026, 10, 31, 9);
    await _comeBack(tester);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
    expect(http.days, ['2026-10-30']);
    expect((http.requests.single['counts']! as Map)['turns'], 1, reason: 'only what came after the toast');
  });

  testWidgets('关闭: off at once, nothing kept, and not one request after', (tester) async {
    await _pumpHome(tester);
    await _wait(tester);
    await tester.tap(find.text(appL10n.usageUpgradeOff));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(_notice), findsNothing);
    final state = _container(tester).read(usageStatsProvider);
    expect(state.enabled, isFalse);
    final stored = await _stored(tester);
    expect(stored[UsageStatsController.enabledKey], isFalse);
    expect(stored.containsKey(UsageStatsController.iidKey), isFalse);

    final usage = _container(tester).read(usageStatsProvider.notifier);
    for (var d = 31; d <= 33; d++) {
      now = DateTime(2026, 10, 30, 9).add(Duration(days: d - 30));
      usage.count(UsageCount.turns);
      usage.count(UsageCount.share);
      await _comeBack(tester);
      await usage.send();
    }
    expect(http.requests, isEmpty);
    expect((await _stored(tester)).containsKey(UsageStatsController.daysKey), isFalse);
  });

  testWidgets('了解 opens 设置 › 隐私与分享 at the switch', (tester) async {
    await _pumpHome(tester);
    await _wait(tester);
    await tester.tap(find.text(appL10n.usageUpgradeLearn));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.byType(PrivacyPage), findsOneWidget);
    expect(tester.widget<SpotFocus>(find.byType(SpotFocus)).target, 'usage-stats');
    expect(_container(tester).read(usageStatsProvider).enabled, isTrue);
  });

  testWidgets('not over another page: it waits until the home is back', (tester) async {
    await _pumpHome(tester);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
    unawaited(navigator.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('elsewhere')))));
    await _wait(tester, const Duration(seconds: 5));
    expect(find.byKey(_notice), findsNothing);
    expect(_container(tester).read(usageStatsProvider).noticed, isFalse, reason: 'not told while it couldn\'t be seen');
    navigator.pop();
    await _wait(tester, const Duration(seconds: 3));
    expect(find.text(appL10n.usageUpgradeNotice), findsOneWidget);
  });

  testWidgets('a fresh install that saw the welcome row never gets it', (tester) async {
    SharedPreferences.setMockInitialValues({UsageStatsController.noticedKey: true});
    await _pumpHome(tester);
    await _wait(tester, const Duration(seconds: 10));
    expect(find.byKey(_notice), findsNothing);
  });

  testWidgets('builds that count nothing say nothing', (tester) async {
    UsageBuild.active = false;
    await _pumpHome(tester);
    await _wait(tester, const Duration(seconds: 10));
    expect(find.byKey(_notice), findsNothing);
  });

  group('first run', () {
    Future<void> pumpGate(WidgetTester tester, {required bool connected}) async {
      usePhoneSurface(tester);
      await tester.pumpWidget(
        goldenApp(
          home: RootGate(home: _home()),
          brightness: Brightness.light,
          overrides: [
            // The root gate's own settings, not the engine pages' ones.
            ...usageOverrides(
              clock: () => now,
              http: http,
              onResumes: (r) => resume = r,
              runtime: const LocalRuntimeState(
                loaded: true,
                status: RuntimeStatus(phase: RuntimePhase.installed, installedVersion: 'r1', bundledVersion: 'r1'),
              ),
            ),
            settingsProvider.overrideWith(
              () => FakeSettings(AppSettings(loaded: true, apiKey: connected ? 'sk-0123456789abcdef' : '')),
            ),
          ],
        ),
      );
      await tester.pump();
    }

    testWidgets('never during first run', (tester) async {
      // Nothing to talk to yet: the connect step, part of first run.
      await pumpGate(tester, connected: false);
      await _wait(tester, const Duration(seconds: 10));
      expect(find.byKey(_notice), findsNothing);
      expect(_container(tester).read(usageStatsProvider).noticed, isFalse);
    });

    testWidgets('on the home, after it', (tester) async {
      await pumpGate(tester, connected: true);
      await _wait(tester);
      expect(find.text(appL10n.usageUpgradeNotice), findsOneWidget);
    });
  });
}
