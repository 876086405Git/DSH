// First run's 「想让 DSH Go 帮你做哪些事」 end to end with a fake phone: the
// pick (and what picking asks first), the walk (dialogs answer at once,
// pages on coming back, a maker's switch on the person's word, the
// restricted-settings steps), the summary, a walk resumed after the app was
// killed, and 设置 › 系统权限.

import 'dart:async';
import 'dart:convert';

import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/access_state.dart';
import 'package:dsh_app/state/phone_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/access/access_walk.dart';
import 'package:dsh_app/ui/onboarding/access_step.dart';
import 'package:dsh_app/ui/settings/system_access_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart';
import 'support.dart';

const _primary = ValueKey('access-primary');

Future<void> _frames(WidgetTester tester, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  Widget home,
  FakeAccessDriver driver, {
  List<Override> overrides = const [],
}) async {
  usePhoneSurface(tester);
  await tester.pumpWidget(
    goldenApp(home: home, brightness: Brightness.light, overrides: [...accessOverrides(driver), ...overrides]),
  );
  await _frames(tester);
  return ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
}

String _primaryLabel(WidgetTester tester) =>
    (tester.widget<FilledButton>(find.byKey(_primary)).child! as Text).data!;

Future<void> _tapPrimary(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(_primary));
  await tester.tap(find.byKey(_primary));
  await _frames(tester);
}

Future<void> _tapText(WidgetTester tester, String text) async {
  await tester.ensureVisible(find.text(text).last);
  await tester.tap(find.text(text).last);
  await _frames(tester);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('the pick', () {
    testWidgets('nothing picked to begin with; 跳过 goes on and writes nothing', (tester) async {
      var done = 0;
      await _pump(tester, AccessStepPage(onDone: () => done++), FakeAccessDriver(offPhone));
      expect(find.text('想让 DSH Go 帮你做哪些事'), findsOneWidget);
      for (final name in ['读写手机里的文件', '桌宠与悬浮窗', '手机操控', '后台持续运行', '语音输入']) {
        expect(find.text(name), findsOneWidget);
        expect(tester.getSemantics(find.text(name)), isSemantics(isChecked: false, hasCheckedState: true));
      }
      expect(tester.widget<FilledButton>(find.byKey(_primary)).onPressed, isNull);

      await _tapText(tester, '跳过');
      expect(done, 1);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey(onboardingWantsVoiceKey), isFalse);
      expect(prefs.containsKey(AccessSetupController.prefsKey), isFalse);
    });

    testWidgets('voice says its download before it is picked', (tester) async {
      await _pump(tester, AccessStepPage(onDone: () {}), FakeAccessDriver(offPhone));
      expect(find.text('需要麦克风权限'), findsOneWidget);
      expect(find.text('离线识别，需下载约 241 MB 语音模型'), findsOneWidget);
      expect(find.text('当前是移动数据，下载会消耗流量'), findsNothing);
    });

    testWidgets('…and that it would use mobile data, when on it', (tester) async {
      await _pump(tester, AccessStepPage(onDone: () {}), FakeAccessDriver(readingsWith(offPhone, metered: true)));
      expect(find.text('离线识别，需下载约 241 MB 语音模型'), findsOneWidget);
      expect(find.text('当前是移动数据，下载会消耗流量'), findsOneWidget);
    });

    testWidgets('手机操控 shows its disclosure first; not now leaves it unpicked', (tester) async {
      final c = await _pump(tester, AccessStepPage(onDone: () {}), FakeAccessDriver(offPhone));
      await _tapText(tester, '手机操控');
      expect(find.text('开启手机操控前'), findsOneWidget);
      await _tapText(tester, '先不开');
      expect(tester.getSemantics(find.text('手机操控')), isSemantics(isChecked: false, hasCheckedState: true));
      expect(c.read(phoneProvider).disclosureAccepted, isFalse);

      await _tapText(tester, '手机操控');
      await _tapText(tester, '同意并开启');
      // Then how it confirms (test/access/phone_mode_test.dart).
      await _tapText(tester, '关键步骤先问我');
      await _tapText(tester, '继续');
      expect(tester.getSemantics(find.text('手机操控')), isSemantics(isChecked: true, hasCheckedState: true));
      expect(c.read(phoneProvider).disclosureAccepted, isTrue);
      // Accepted once: unpicking and picking again doesn't show it again.
      await _tapText(tester, '手机操控');
      await _tapText(tester, '手机操控');
      expect(find.text('开启手机操控前'), findsNothing);
    });

    testWidgets('files says what AI may then do, without an engine restart to mention', (tester) async {
      await _pump(tester, AccessStepPage(onDone: () {}), FakeAccessDriver(offPhone));
      await _tapText(tester, '读写手机里的文件');
      expect(find.text('让 AI 访问手机文件？'), findsOneWidget);
      expect(find.text('AI 能读取和修改相册、下载、文档等手机文件。'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('risk-confirm')));
      await _frames(tester);
      expect(tester.getSemantics(find.text('读写手机里的文件')), isSemantics(isChecked: true, hasCheckedState: true));
    });
  });

  group('the walk', () {
    testWidgets('voice and background on vivo: dialog, page, retry, a maker\'s switch, a skip, the summary', (
      tester,
    ) async {
      var batteryAsks = 0;
      final driver = FakeAccessDriver(
        offPhone,
        answer: (item, r) => switch (item) {
          AccessItem.mic => readingsWith(r, mic: true),
          AccessItem.notifications => readingsWith(r, notifications: true),
          // Dismissed the first time, allowed the second.
          AccessItem.battery => readingsWith(r, battery: ++batteryAsks > 1),
          _ => r,
        },
      );
      var done = 0;
      final c = await _pump(tester, AccessStepPage(onDone: () => done++), driver);
      await _tapText(tester, '语音输入');
      await _tapText(tester, '后台持续运行');
      await _tapPrimary(tester);

      // 1 / 5: the microphone's dialog answers when the call returns.
      expect(find.text('允许使用麦克风'), findsOneWidget);
      expect(find.text('1 / 5'), findsOneWidget);
      expect(find.text('语音输入要用到'), findsOneWidget);
      expect(_primaryLabel(tester), '去开启');
      await _tapPrimary(tester);
      expect(driver.opened, ['mic']);

      // 2 / 5: notifications' page; on when the person comes back with it on.
      expect(find.text('允许通知'), findsOneWidget);
      expect(find.text('2 / 5'), findsOneWidget);
      await _tapPrimary(tester);
      expect(find.text('允许通知'), findsOneWidget);
      await awayAndBack(tester);
      expect(driver.opened, ['mic', 'notifications']);

      // 3 / 5: dismissed: 还没开启, 重试 asks again.
      expect(find.text('允许在后台运行'), findsOneWidget);
      await _tapPrimary(tester);
      expect(find.text('还没开启'), findsOneWidget);
      expect(_primaryLabel(tester), '重试');
      await _tapPrimary(tester);
      expect(driver.opened.last, 'battery+');

      // 4 / 5: vivo's own switch, with where it lives; the person's word for it.
      expect(find.text('允许后台高耗电'), findsOneWidget);
      expect(find.text('位置：电池 › 后台耗电管理 › DSH Go'), findsOneWidget);
      expect(_primaryLabel(tester), '去设置');
      await _tapPrimary(tester);
      await awayAndBack(tester);
      expect(driver.opened.last, 'vendorBackground');
      expect(find.text('在那一页打开了吗？'), findsOneWidget);
      expect(_primaryLabel(tester), '设好了');
      expect(find.text('再去一次'), findsOneWidget);
      await _tapPrimary(tester);
      expect(c.read(accessVisitedProvider), {AccessItem.vendorBackground});

      // 5 / 5: skipped.
      expect(find.text('允许自启动'), findsOneWidget);
      expect(find.text('5 / 5'), findsOneWidget);
      await _tapText(tester, '跳过');
      expect(c.read(accessSetupProvider).skipped, {AccessItem.autostart});

      // Where everything ended up, and what voice does next.
      expect(find.text('还有 1 项没开'), findsOneWidget);
      expect(find.text('随时可在「设置 › 通用 › 系统权限」补开'), findsOneWidget);
      for (final (title, state) in [
        ('允许使用麦克风', '已开启'),
        ('允许通知', '已开启'),
        ('允许在后台运行', '已开启'),
        ('允许后台高耗电', '已去设置'),
        ('允许自启动', '去设置'),
      ]) {
        expect(
          find.descendant(of: find.ancestor(of: find.text(title), matching: find.byType(InkWell)), matching: find.text(state)),
          findsOneWidget,
          reason: title,
        );
      }
      expect(find.text('语音模型（约 241 MB）会在引擎就绪后开始下载，进度在「设置 › 通用 › 语音输入」里查看'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('access-summary-done')));
      await _frames(tester);
      expect(done, 1);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(onboardingWantsVoiceKey), isTrue);
      expect(prefs.containsKey(AccessSetupController.prefsKey), isFalse);
      expect(prefs.getStringList(AccessVisitedController.prefsKey), ['vendorBackground']);
    });

    testWidgets('restricted: tap the switch once, allow it on App info, then turn it on', (tester) async {
      final driver = FakeAccessDriver(
        readingsWith(offPhone, clearVendor: true, notifications: true, restricted: RestrictedSettingsState.guarded),
        answer: (item, r) => item != AccessItem.accessibility
            ? r
            : switch (r.restricted) {
                RestrictedSettingsState.guarded => readingsWith(r, restricted: RestrictedSettingsState.acknowledged),
                RestrictedSettingsState.acknowledged => readingsWith(r, restricted: RestrictedSettingsState.clear),
                _ => readingsWith(r, accessibility: true),
              },
      );
      final c = await _pump(tester, AccessStepPage(onDone: () {}), driver);
      c.read(phoneProvider.notifier);
      await c.read(phoneProvider.notifier).acceptDisclosure();
      await c.read(accessSetupProvider.notifier).choose({AccessFeature.phone});
      await _frames(tester);

      expect(find.text('打开无障碍'), findsOneWidget);
      expect(find.text('先允许受限制的设置'), findsOneWidget);
      expect(find.text('在无障碍里点一下「DSH 手机操控」，出现「受限制的设置」时点确定'), findsOneWidget);
      expect(find.text('在应用信息里点右上角的三个点，选「允许受限制的设置」'), findsOneWidget);
      expect(find.text('看图示'), findsOneWidget);
      expect(_primaryLabel(tester), '去无障碍');

      await _tapPrimary(tester);
      await awayAndBack(tester);
      expect(_primaryLabel(tester), '去应用信息');

      await _tapPrimary(tester);
      await awayAndBack(tester);
      expect(driver.opened, ['accessibility', 'appInfo']);
      expect(_primaryLabel(tester), '去无障碍');
      expect(find.text('先允许受限制的设置'), findsOneWidget);

      await _tapPrimary(tester);
      await awayAndBack(tester);
      expect(driver.opened, ['accessibility', 'appInfo', 'accessibility+']);
      expect(find.text('都开好了'), findsOneWidget);
    });

    testWidgets('restriction unknown: the switch first; back without it, the way through App info', (tester) async {
      final driver = FakeAccessDriver(
        readingsWith(offPhone, clearVendor: true, notifications: true, clearRestricted: true),
      );
      final c = await _pump(tester, AccessStepPage(onDone: () {}), driver);
      await c.read(phoneProvider.notifier).acceptDisclosure();
      await c.read(accessSetupProvider.notifier).choose({AccessFeature.phone});
      await _frames(tester);

      expect(find.text('先允许受限制的设置'), findsNothing);
      expect(_primaryLabel(tester), '去开启');
      await _tapPrimary(tester);
      await awayAndBack(tester);
      expect(find.text('先允许受限制的设置'), findsOneWidget);
      expect(_primaryLabel(tester), '去应用信息');
    });

    testWidgets('Xiaomi keeps the option under 高级设置', (tester) async {
      final driver = FakeAccessDriver(
        readingsWith(
          offPhone,
          vendor: 'xiaomi',
          manufacturer: 'Xiaomi',
          notifications: true,
          restricted: RestrictedSettingsState.acknowledged,
        ),
      );
      final c = await _pump(tester, AccessStepPage(onDone: () {}), driver);
      await c.read(phoneProvider.notifier).acceptDisclosure();
      await c.read(accessSetupProvider.notifier).choose({AccessFeature.phone});
      await _frames(tester);
      expect(find.text('在应用信息的「高级设置」里打开「允许受限制的设置」'), findsOneWidget);
      expect(_primaryLabel(tester), '去应用信息');
    });

    testWidgets('killed in system settings: back on the same walk, past what was done and skipped', (tester) async {
      SharedPreferences.setMockInitialValues({
        AccessSetupController.prefsKey: jsonEncode({
          'features': ['voice', 'files'],
          'skipped': ['mic'],
        }),
      });
      await _pump(tester, AccessStepPage(onDone: () {}), FakeAccessDriver(offPhone));
      expect(find.byType(AccessWalk), findsOneWidget);
      expect(find.text('允许访问文件'), findsOneWidget);
      expect(find.text('2 / 2'), findsOneWidget);
    });

    testWidgets('everything already on: straight to the summary', (tester) async {
      final on = readingsWith(offPhone, mic: true, storage: true);
      await _pump(tester, AccessStepPage(onDone: () {}), FakeAccessDriver(on));
      await _tapText(tester, '语音输入');
      await _tapPrimary(tester);
      expect(find.text('都开好了'), findsOneWidget);
    });
  });

  group('继续 on the summary', () {
    /// Picks 读写手机里的文件 (through its risk notice) and starts the walk.
    Future<void> pickFiles(WidgetTester tester) async {
      await _tapText(tester, '读写手机里的文件');
      await tester.tap(find.byKey(const ValueKey('risk-confirm')));
      await _frames(tester);
      await _tapPrimary(tester);
    }

    testWidgets('files skipped on the walk, then allowed from the summary: 访问手机文件 goes on, the engine mounts them', (
      tester,
    ) async {
      final driver = FakeAccessDriver(
        offPhone,
        answer: (item, r) => item == AccessItem.storage ? readingsWith(r, storage: true) : r,
      );
      // Running, started before any of this: without the phone's files.
      final engine = FakeEngine(RuntimePhase.running);
      var done = 0;
      final c = await _pump(
        tester,
        AccessStepPage(onDone: () => done++),
        driver,
        overrides: [
          settingsProvider.overrideWith(StorageSettings.new),
          localRuntimeProvider.overrideWith(() => engine),
        ],
      );
      await pickFiles(tester);
      expect(find.text('允许访问文件'), findsOneWidget);
      await _tapText(tester, '跳过');
      expect(find.text('还有 1 项没开'), findsOneWidget);

      // Its row: the same step, allowed this time, back on the summary.
      await _tapText(tester, '允许访问文件');
      expect(find.byType(AccessWalk), findsOneWidget);
      await _tapPrimary(tester);
      await _frames(tester);
      expect(find.byType(AccessWalk), findsNothing);
      expect(find.text('都开好了'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('access-summary-done')));
      await _frames(tester);
      expect(done, 1);
      expect(c.read(settingsProvider).phoneStorage, isTrue);
      // Restarted once, and this start has them.
      expect(engine.stops, 1);
      expect(engine.starts, [true]);
      expect(engine.storageMounted, isTrue);
    });

    testWidgets('the step is over only once what it turns on is written', (tester) async {
      final settings = StorageSettings()..hold = Completer<void>();
      var done = 0;
      final c = await _pump(
        tester,
        AccessStepPage(onDone: () => done++),
        FakeAccessDriver(readingsWith(offPhone, storage: true)),
        overrides: [
          settingsProvider.overrideWith(() => settings),
          localRuntimeProvider.overrideWith(() => FakeEngine(RuntimePhase.installed)),
        ],
      );
      await pickFiles(tester);
      expect(find.text('都开好了'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('access-summary-done')));
      await _frames(tester);
      // 访问手机文件 not written yet: killed now, the next launch comes back here.
      expect(done, 0);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey(AccessSetupController.prefsKey), isTrue);

      settings.hold!.complete();
      await _frames(tester);
      expect(c.read(settingsProvider).phoneStorage, isTrue);
      expect(prefs.containsKey(AccessSetupController.prefsKey), isFalse);
      expect(done, 1);
    });
  });

  group('设置 › 系统权限', () {
    testWidgets('by feature, each item\'s state; a row opens its step, which closes once on', (tester) async {
      SharedPreferences.setMockInitialValues({
        AccessVisitedController.prefsKey: ['autostart'],
      });
      final driver = FakeAccessDriver(
        readingsWith(offPhone, notifications: true),
        answer: (item, r) => item == AccessItem.mic ? readingsWith(r, mic: true) : r,
      );
      await _pump(tester, const SystemAccessPage(), driver);
      expect(find.text('系统权限'), findsWidgets);
      final list = find.byType(Scrollable).first;
      for (final feature in accessFeaturesFor('android')) {
        final section = find.byKey(ValueKey('access-section-${feature.name}'));
        await tester.scrollUntilVisible(section, 120, scrollable: list);
        expect(section, findsOneWidget, reason: feature.name);
      }
      for (final (feature, title) in [
        (AccessFeature.files, '读写手机里的文件'),
        (AccessFeature.pet, '桌宠与悬浮窗'),
        (AccessFeature.phone, '手机操控'),
        (AccessFeature.background, '后台持续运行'),
        (AccessFeature.voice, '语音输入'),
      ]) {
        await tester.scrollUntilVisible(find.byKey(ValueKey('access-section-${feature.name}')), -120, scrollable: list);
        expect(
          find.descendant(of: find.byKey(ValueKey('access-section-${feature.name}')), matching: find.text(title)),
          findsOneWidget,
          reason: title,
        );
      }
      // 通知 under both features that need it, one state.
      for (final feature in [AccessFeature.phone, AccessFeature.background]) {
        final section = find.byKey(ValueKey('access-section-${feature.name}'));
        await tester.scrollUntilVisible(section, -120, scrollable: list);
        expect(
          find.descendant(
            of: find.descendant(of: section, matching: find.byKey(const ValueKey('access-item-notifications'))),
            matching: find.text('已开启'),
          ),
          findsOneWidget,
        );
      }
      await tester.scrollUntilVisible(find.byKey(const ValueKey('access-item-autostart')), -120, scrollable: list);
      expect(find.byKey(const ValueKey('access-item-autostart')), findsOneWidget);
      expect(
        find.descendant(of: find.byKey(const ValueKey('access-item-autostart')), matching: find.text('已去设置')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: find.byKey(const ValueKey('access-item-popup')), matching: find.text('去设置')),
        findsOneWidget,
      );

      await tester.scrollUntilVisible(find.byKey(const ValueKey('access-item-mic')), 120, scrollable: list);
      await _tapText(tester, '允许使用麦克风');
      expect(find.byType(AccessWalk), findsOneWidget);
      await _tapPrimary(tester);
      await _frames(tester);
      expect(find.byType(AccessWalk), findsNothing);
      expect(
        find.descendant(of: find.byKey(const ValueKey('access-item-mic')), matching: find.text('已开启')),
        findsOneWidget,
      );

      // A switch already visited opens again rather than closing at once.
      await tester.scrollUntilVisible(find.byKey(const ValueKey('access-item-autostart')), -120, scrollable: list);
      await tester.tap(find.byKey(const ValueKey('access-item-autostart')));
      await _frames(tester);
      expect(find.byType(AccessWalk), findsOneWidget);
      expect(_primaryLabel(tester), '去设置');
    });
  });
}
