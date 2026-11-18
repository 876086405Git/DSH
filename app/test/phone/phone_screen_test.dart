// PhoneControlScreen, section by section: master switch + disclosure, blockers
// (未就绪 / safe mode / remote host), permission rows with fixes, the test read,
// a running task, the recent log and live status events.

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/compose_inbox.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/phone_state.dart';
import 'package:dsh_app/ui/common/list_page_row.dart';
import 'package:dsh_app/ui/common/overview_card.dart';
import 'package:dsh_app/ui/phone/action_log_page.dart';
import 'package:dsh_app/ui/phone/dnd_mode_page.dart';
import 'package:dsh_app/ui/phone/phone_control_screen.dart';
import 'package:dsh_app/ui/phone/phone_background_guide.dart';
import 'package:dsh_app/ui/phone/phone_widgets.dart';
import 'package:dsh_app/ui/phone/restricted_settings_guide.dart';
import 'package:dsh_app/ui/settings/background_guide_page.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'harness.dart';
import 'support.dart';

Finder tileWith(String title) => find.ancestor(of: find.text(title), matching: find.byType(ListPageRow)).first;

Finder inTile(String title, Finder inner) => find.descendant(of: tileWith(title), matching: inner);

Switch masterSwitch(WidgetTester tester) => tester.widget<Switch>(find.byType(Switch).first);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final kind in ['active', 'waiting', 'stopped', 'cleanup', 'interruption']) {
    testWidgets('unavailable modern status retains $kind facts but disables its controls', (tester) async {
      Map<String, Object?> snapshot(int revision) => {
        ...phoneStatus(a11y: true),
        'statusRevision': revision,
        'taskProtocol': 1,
        'selectedTaskId': 12,
        'tasks': [
          {
            'id': 12,
            'sessionId': 'original',
            'app': '美团',
            'active': kind == 'active' || kind == 'waiting',
            'stopped': kind == 'stopped' || kind == 'cleanup',
            if (kind == 'waiting') 'waitingForScreen': 'background',
            if (kind == 'cleanup') 'cleanupFailed': true,
          },
        ],
        if (kind == 'interruption')
          'taskInterruption': {
            'version': 1,
            'state': 'ready',
            'count': 1,
            'batchToken': '00000000-0000-0000-0000-000000000001',
          },
      };
      final native = FakePhoneNative(status: snapshot(1));
      await pumpPhone(tester, const PhoneControlScreen(), native: native);
      final button = switch (kind) {
        'active' => inTile('正在操作「美团」', find.byType(FixButton)),
        'waiting' => find.descendant(
          of: find.byKey(const ValueKey('phone-waiting-12')),
          matching: find.byType(FixButton),
        ),
        'interruption' => find.byKey(const ValueKey('phone-task-interruption-action')),
        _ => find.byKey(const ValueKey('phone-resume-12')),
      };
      expect(button, findsOneWidget);
      expect(tester.widget<FixButton>(button).onPressed, isNotNull);
      native.onStatus = () async => throw PlatformException(code: 'offline');
      expect(await containerOf(tester).read(phoneProvider.notifier).refreshStatus(), isFalse);
      await settlePhone(tester);
      expect(phoneOf(tester).status.ready, isFalse);
      expect(phoneOf(tester).status.task.id, 12);
      expect(button, findsOneWidget);
      expect(tester.widget<FixButton>(button).onPressed, isNull);
      expect(masterSwitch(tester).onChanged, isNull);
      native.calls.clear();
      await tester.ensureVisible(button);
      await tester.tap(button);
      await settlePhone(tester);
      expect(native.calls, isEmpty);
      native.onStatus = null;
      native.push(snapshot(2));
      await settlePhone(tester);
      expect(phoneOf(tester).status.ready, isTrue);
      expect(phoneOf(tester).status.task.id, 12);
      expect(button, findsOneWidget);
      expect(tester.widget<FixButton>(button).onPressed, isNotNull);
    });
  }

  group('问 AI', () {
    const question = '/dsh-go-guide 手机操控是怎么工作的？有什么风险？';
    String? queued(WidgetTester tester) =>
        ProviderScope.containerOf(tester.element(find.byType(MaterialApp)))
            .read(composeInboxProvider)
            .singleOrNull
            ?.text;

    testWidgets('the bar key asks how phone control works', (tester) async {
      await pumpPhone(tester, const PhoneControlScreen());
      await tester.tap(find.byTooltip('问 AI'));
      await tester.pumpAndSettle();
      expect(queued(tester), question);
    });

    testWidgets('the disclosure offers it, and asking leaves phone control off', (tester) async {
      final h = await pumpPhone(
        tester,
        const PhoneControlScreen(),
        native: FakePhoneNative(status: phoneStatus(enabled: false)),
      );
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      expect(find.text('开启手机操控前'), findsOneWidget);
      await tester.tap(find.text('不确定？问 AI'));
      await tester.pumpAndSettle();
      expect(find.text('开启手机操控前'), findsNothing);
      expect(h.native!.callsOf('setEnabled'), isEmpty);
      expect((await SharedPreferences.getInstance()).getBool(PhoneController.disclosureKey), isNot(true));
      expect(queued(tester), question);
    });
  });

  group('master switch', () {
    testWidgets('first enable goes through the disclosure; 先不开 keeps it off', (tester) async {
      final h = await pumpPhone(
        tester,
        const PhoneControlScreen(),
        native: FakePhoneNative(status: phoneStatus(enabled: false)),
      );
      // The status card's line; 始终允许's row says 未开启 too when off.
      expect(find.descendant(of: find.byType(OverviewCard), matching: find.text('未开启')), findsOneWidget);
      expect(find.text('开启后能做什么'), findsOneWidget);
      expect(find.text('准备'), findsNothing);
      // Setup and Shell remain reachable while off; background controls do not.
      expect(find.text('不打扰模式'), findsNothing);

      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      expect(find.text('开启手机操控前'), findsOneWidget);
      for (final t in ['读什么', '什么时候读', '发给谁', '默认不做', '你随时能停']) {
        expect(find.text(t), findsOneWidget);
      }
      await tester.tap(find.text('先不开'));
      await tester.pumpAndSettle();
      expect(h.native!.callsOf('setEnabled'), isEmpty);
      expect(masterSwitch(tester).value, isFalse);

      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('同意并开启'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('phone-background-guide')), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '知道了'));
      await tester.pumpAndSettle();
      expect(h.native!.callsOf('setEnabled').single.arguments, {'enabled': true});
      expect(masterSwitch(tester).value, isTrue);
      expect(h.runtime.stops, 1);
      expect(h.runtime.starts, ['start']);
      expect(find.text('已开启，引擎正在重启'), findsOneWidget);
      expect(find.text('准备'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('phone-more-options')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(find.text(appL10n.phoneControlAdvanced), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(PhoneController.disclosureKey), isTrue);
      expect(prefs.getBool(phoneBackgroundGuideSeenKey), isTrue);

      // Return to the master card after checking the lower advanced section.
      await tester.scrollUntilVisible(
        find.descendant(of: find.byType(OverviewCard), matching: find.byType(Switch)),
        -200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      // Off, then on again: no second disclosure.
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      expect(h.native!.callsOf('setEnabled').last.arguments, {'enabled': false});
      expect(find.text('开启后能做什么'), findsOneWidget);
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      expect(find.text('开启手机操控前'), findsNothing);
      expect(find.byKey(const Key('phone-background-guide')), findsNothing);
      expect(h.native!.callsOf('setEnabled').last.arguments, {'enabled': true});
    });

    testWidgets('a refused switch says so and stays put', (tester) async {
      SharedPreferences.setMockInitialValues({PhoneController.disclosureKey: true});
      final native = FakePhoneNative(status: phoneStatus(enabled: false))..accept = false;
      final h = await pumpPhone(tester, const PhoneControlScreen(), native: native);
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      expect(find.text('开启手机操控前'), findsNothing);
      expect(find.text('没能开启，稍后再试'), findsOneWidget);
      expect(masterSwitch(tester).value, isFalse);
      expect(h.runtime.stops, 0);
    });
  });

  group('blockers', () {
    testWidgets('no native module: 未就绪, switch disabled, nothing else', (tester) async {
      await pumpPhone(tester, const PhoneControlScreen(), missingNative: true);
      expect(find.text('未就绪'), findsWidgets);
      expect(find.textContaining('手机操控模块还没有就绪'), findsOneWidget);
      expect(masterSwitch(tester).onChanged, isNull);
      expect(find.text('应用名单'), findsNothing);
    });

    testWidgets('safe mode: unavailable, can turn off but not on', (tester) async {
      final h = await pumpPhone(
        tester,
        const PhoneControlScreen(),
        engine: safeRuntime,
        native: FakePhoneNative(status: phoneStatus(enabled: false)),
      );
      expect(find.text('安全模式下不可用'), findsOneWidget);
      expect(masterSwitch(tester).onChanged, isNull);

      h.native!.push(phoneStatus(enabled: true));
      await settlePhone(tester);
      expect(find.text('安全模式下不加载'), findsOneWidget);
      expect(masterSwitch(tester).onChanged, isNotNull);
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      expect(h.native!.callsOf('setEnabled').single.arguments, {'enabled': false});
      // Safe mode loads no plugins: no restart needed.
      expect(h.runtime.stops, 0);
      expect(find.text('已关闭'), findsOneWidget);
    });

    testWidgets('remote host: explains it only works on the local engine', (tester) async {
      await pumpPhone(tester, const PhoneControlScreen(), host: const HostRef.ssh('lab'));
      expect(find.text('当前连的是远程主机'), findsOneWidget);
      expect(find.textContaining('「实验室服务器」上的 DSH 操作不了这台手机'), findsOneWidget);
      expect(find.text('只在本机引擎可用'), findsOneWidget);
    });
  });

  group('准备', () {
    testWidgets('accessibility: opens settings, detects on resume, else points at restricted settings', (tester) async {
      final h = await pumpPhone(tester, const PhoneControlScreen());
      expect(find.text('还差一步：打开无障碍'), findsOneWidget);
      // vivo, Android 15, sideloaded: the hint is there from the start.
      expect(find.text('无障碍开关点不动？'), findsOneWidget);
      expect(find.text('侧载安装的 App 要先「允许受限制的设置」'), findsOneWidget);

      await tester.tap(inTile('无障碍服务', find.text('去开启')));
      await tester.pump();
      expect(h.native!.callsOf('openAccessibilitySettings'), hasLength(1));

      // Came back without turning it on.
      await leaveAndResume(tester);
      expect(find.text('看起来没开成。侧载的 App 要先「允许受限制的设置」'), findsOneWidget);

      await tester.tap(inTile('无障碍服务', find.text('去开启')));
      await tester.pump();
      h.native!.status = phoneStatus(a11y: true);
      await leaveAndResume(tester);
      expect(find.text('无障碍服务'), findsNothing);
      expect(find.text('无障碍开关点不动？'), findsNothing);
      expect(find.text('可以操作手机'), findsOneWidget);
    });

    testWidgets('restricted-settings row leads to the guide for this ROM', (tester) async {
      await pumpPhone(tester, const PhoneControlScreen());
      await tester.tap(find.text('无障碍开关点不动？'));
      await tester.pumpAndSettle();
      expect(find.byType(RestrictedSettingsGuidePage), findsOneWidget);
      final vivo = tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'vivo / iQOO'));
      expect(vivo.selected, isTrue);
    });

    testWidgets('no restricted-settings hint on Android 12 or a store install', (tester) async {
      await pumpPhone(
        tester,
        const PhoneControlScreen(),
        native: FakePhoneNative(
          status: phoneStatus(device: {'manufacturer': 'Xiaomi', 'sdkInt': 32, 'sideloaded': true}),
        ),
      );
      expect(find.text('无障碍开关点不动？'), findsNothing);
    });

    testWidgets('a connected-but-dead service asks to toggle it again', (tester) async {
      await pumpPhone(
        tester,
        const PhoneControlScreen(),
        native: FakePhoneNative(status: phoneStatus(a11y: true, serviceConnected: false)),
      );
      expect(find.text('服务没连上，关掉再打开一次'), findsOneWidget);
      expect(inTile('无障碍服务', find.text('去设置')), findsOneWidget);
    });

    testWidgets('notifications open App info; background opens the keep-alive guide', (tester) async {
      final h = await pumpPhone(
        tester,
        const PhoneControlScreen(),
        native: FakePhoneNative(status: phoneStatus(a11y: true, notifications: false)),
      );
      await tester.tap(inTile('通知', find.text('去开启')));
      await tester.pump();
      expect(h.native!.callsOf('openAppDetails'), hasLength(1));

      h.native!.status = phoneStatus(a11y: true, notifications: true);
      await leaveAndResume(tester);
      expect(find.text('通知'), findsNothing);
      await openPhoneFold(tester, 'phone-more-options');

      await tester.scrollUntilVisible(find.text('后台运行'), 200, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('后台运行'));
      await tester.pumpAndSettle();
      expect(find.byType(BackgroundGuidePage), findsOneWidget);
    });
  });

  group('试一下', () {
    testWidgets('reads the screen into a monospace sheet', (tester) async {
      final h = await pumpPhone(
        tester,
        const PhoneControlScreen(),
        native: FakePhoneNative(status: phoneStatus(a11y: true)),
      );
      await tester.tap(find.text('读一下当前屏幕'));
      await tester.pumpAndSettle();
      expect(h.native!.callsOf('testScreen'), hasLength(1));
      expect(find.text('当前屏幕'), findsOneWidget);
      final text = tester.widget<SelectableText>(find.byType(SelectableText));
      expect(text.data, sampleScreenText);
      expect(text.style?.fontFamily, AppType.monoFamily);
      expect(find.textContaining('没有发给模型'), findsOneWidget);
    });

    testWidgets('a failed read shows the reason', (tester) async {
      final native = FakePhoneNative(status: phoneStatus(a11y: true))..screen = {'ok': false, 'reason': '这个页面不允许读取'};
      await pumpPhone(tester, const PhoneControlScreen(), native: native);
      await tester.tap(find.text('读一下当前屏幕'));
      await tester.pumpAndSettle();
      expect(find.text('没能读到屏幕'), findsOneWidget);
      expect(find.text('这个页面不允许读取'), findsOneWidget);
    });

    testWidgets('disabled until accessibility is on', (tester) async {
      final h = await pumpPhone(tester, const PhoneControlScreen());
      expect(find.text('无障碍服务'), findsOneWidget);
      expect(find.text('读一下当前屏幕'), findsNothing);
      expect(h.native!.callsOf('testScreen'), isEmpty);
    });
  });

  testWidgets('a running task can be stopped from here', (tester) async {
    final h = await pumpPhone(
      tester,
      const PhoneControlScreen(),
      native: FakePhoneNative(status: phoneStatus(a11y: true, taskActive: true, taskApp: '美团')),
    );
    expect(find.text('正在操作「美团」'), findsOneWidget);
    await tester.tap(inTile('正在操作「美团」', find.text('停止')));
    await tester.pump();
    expect(h.native!.callsOf('stopTask'), hasLength(1));

    h.native!.push(phoneStatus(a11y: true));
    await settlePhone(tester);
    expect(find.text('正在操作「美团」'), findsNothing);
  });

  testWidgets('停止 stops the task it was shown for, even after another one is selected', (tester) async {
    Map<String, Object?> selected(int id) => {
      ...phoneStatus(a11y: true),
      'taskProtocol': 1,
      'selectedTaskId': id,
      'tasks': [
        {'id': 12, 'sessionId': 'A', 'runId': '1', 'active': true, 'app': '美团'},
        {'id': 13, 'sessionId': 'B', 'runId': '1', 'active': true, 'app': '京东'},
      ],
    };
    final h = await pumpPhone(tester, const PhoneControlScreen(), native: FakePhoneNative(status: selected(12)));
    // A tap already on its way when B became the selected task.
    final shownForA = tester.widget<FixButton>(inTile('正在操作「美团」', find.byType(FixButton))).onPressed!;
    h.native!.push(selected(13));
    await settlePhone(tester);
    expect(find.text('正在操作「京东」'), findsOneWidget);
    shownForA();
    await tester.pump();
    expect(h.native!.callsOf('stopTask').single.arguments, {'taskId': 12});
  });

  testWidgets('each waiting row stops its own task without stopping the selected holder', (tester) async {
    Map<String, Object?> selected(int id) => {
      ...phoneStatus(a11y: true),
      'taskProtocol': 1,
      'selectedTaskId': id,
      'tasks': [
        {'id': 70, 'sessionId': 'holder', 'active': true, 'app': '美团'},
        {
          'id': 71,
          'sessionId': 'waiter-a',
          'active': true,
          'waitingForApp': {'kind': 'unknown'},
        },
        {'id': 72, 'sessionId': 'waiter-b', 'active': true, 'waitingForScreen': 'background'},
      ],
    };
    final h = await pumpPhone(tester, const PhoneControlScreen(), native: FakePhoneNative(status: selected(70)));
    Finder stopFor(int id) =>
        find.descendant(of: find.byKey(ValueKey('phone-waiting-$id')), matching: find.byType(FixButton));
    final holder = find.text('正在操作「美团」');
    expect(holder, findsOneWidget);
    expect(stopFor(71), findsOneWidget);
    expect(stopFor(72), findsOneWidget);
    final shownFor71 = tester.widget<FixButton>(stopFor(71)).onPressed!;
    await tester.ensureVisible(stopFor(72));
    await tester.tap(stopFor(72));
    await tester.pump();
    expect(h.native!.callsOf('stopTask').map((call) => call.arguments).toList(), [
      {'taskId': 72},
    ]);
    final selectedHolder = phoneOf(tester).status.task;
    expect(selectedHolder.id, 70);
    expect(selectedHolder.active, isTrue);
    expect(selectedHolder.stopped, isFalse);
    // ensureVisible(waiter) can scroll the earlier holder out of the lazy list.
    await tester.scrollUntilVisible(holder, -200, scrollable: find.byType(Scrollable).first);
    expect(find.text('正在操作「美团」'), findsOneWidget);

    // The already-displayed row keeps its identity even if selection changes.
    h.native!.push(selected(72));
    await settlePhone(tester);
    shownFor71();
    await tester.pump();
    expect(h.native!.callsOf('stopTask').map((call) => call.arguments).toList(), [
      {'taskId': 72},
      {'taskId': 71},
    ]);
    expect(h.native!.callsOf('connectBackground'), isEmpty);
    expect(h.native!.callsOf('startBackground'), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('resource wait rows consume native targets and elapsed snapshots without exposing holders', (
    tester,
  ) async {
    Map<String, Object?> status(List<Map<String, Object?>> tasks) => {
      ...phoneStatus(a11y: true),
      'taskProtocol': 1,
      'tasks': tasks,
    };
    final native = FakePhoneNative(
      status: status([
        {
          'id': 71,
          'sessionId': 'secret-holder',
          'active': true,
          'waitingForApp': {'kind': 'known', 'packageName': 'example.app', 'uid': 10123},
          'waitingForMs': 2501,
        },
        {
          'id': 72,
          'active': true,
          'waitingForApp': {'kind': 'unknown'},
          'waitingForMs': 900,
        },
      ]),
    );
    await pumpPhone(tester, const PhoneControlScreen(), native: native);
    expect(find.text('任务 71 · 等待资源'), findsOneWidget);
    expect(find.text('等待应用 example.app，已等待 2 秒。'), findsOneWidget);
    expect(find.text('等待界面资源（应用身份未确认），已等待 0 秒。'), findsOneWidget);
    expect(find.textContaining('secret-holder'), findsNothing);
    expect(find.textContaining('10123'), findsNothing);
    native.push(
      status([
        {
          'id': 71,
          'active': true,
          'waitingForApp': {'kind': 'known', 'packageName': 'example.app'},
          'waitingForMs': 4501,
        },
      ]),
    );
    await settlePhone(tester);
    expect(find.text('等待应用 example.app，已等待 4 秒。'), findsOneWidget);
    expect(find.byKey(const ValueKey('phone-waiting-72')), findsNothing);
    native.push(
      status([
        {'id': 71, 'active': true},
      ]),
    );
    await settlePhone(tester);
    expect(find.byKey(const ValueKey('phone-waiting-71')), findsNothing);
  });

  testWidgets('legacy screen waiting remains visible and malformed app status does not invent a target', (
    tester,
  ) async {
    await pumpPhone(
      tester,
      const PhoneControlScreen(),
      native: FakePhoneNative(
        status: {
          ...phoneStatus(a11y: true),
          'taskProtocol': 1,
          'tasks': [
            {'id': 81, 'active': true, 'waitingForScreen': 'background', 'waitingForMs': 3000},
            {
              'id': 82,
              'active': true,
              'waitingForApp': {'kind': 'known'},
              'waitingForMs': 999,
            },
            {
              'id': 83,
              'stopped': true,
              'sessionId': 'stopped',
              'waitingForApp': {'kind': 'unknown'},
            },
          ],
        },
      ),
    );
    expect(find.text('等待后台屏，已等待 3 秒。'), findsOneWidget);
    expect(find.byKey(const ValueKey('phone-waiting-82')), findsNothing);
    expect(find.byKey(const ValueKey('phone-waiting-83')), findsNothing);
    expect(find.byKey(const ValueKey('phone-resume-83')), findsOneWidget);
  });

  testWidgets('inactive modern sessions have an explicit exact resume action', (tester) async {
    final status = {
      ...phoneStatus(a11y: true),
      'taskProtocol': 1,
      'selectedTaskId': 12,
      'tasks': [
        {'id': 10, 'sessionId': 'A', 'runId': 'old', 'active': false, 'stopped': true},
        {'id': 11, 'sessionId': 'A', 'runId': 'new', 'active': false, 'stopped': true},
        {'id': 12, 'sessionId': 'B', 'runId': 'run', 'active': false, 'stopped': true},
      ],
    };
    final h = await pumpPhone(tester, const PhoneControlScreen(), native: FakePhoneNative(status: status));
    expect(find.byKey(const ValueKey('phone-resume-10')), findsNothing);
    final resumeA = find.byKey(const ValueKey('phone-resume-11'));
    await tester.ensureVisible(resumeA);
    await tester.tap(resumeA);
    await tester.pump();
    final call = h.native!.callsOf('resumeTask').single;
    expect(call.arguments, {'taskId': 11});
    expect(h.native!.callsOf('stopTask'), isEmpty);
    expect(find.byKey(const ValueKey('phone-resume-12')), findsOneWidget);
  });

  testWidgets('retiring or draining tasks cannot be resumed before physical cleanup', (tester) async {
    final h = await pumpPhone(
      tester,
      const PhoneControlScreen(),
      native: FakePhoneNative(
        status: {
          ...phoneStatus(a11y: true),
          'taskProtocol': 1,
          'tasks': [
            {'id': 11, 'sessionId': 'A', 'runId': 'run', 'stopped': true, 'draining': true},
            {'id': 12, 'sessionId': 'B', 'runId': 'run', 'stopped': true, 'retiring': true},
          ],
        },
      ),
    );
    for (final id in [11, 12]) {
      final button = find.descendant(of: find.byKey(ValueKey('phone-resume-$id')), matching: find.byType(FilledButton));
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
    }
    expect(h.native!.callsOf('resumeTask'), isEmpty);
  });

  testWidgets('cleanup retry is a separate exact action and never implicitly resumes', (tester) async {
    Map<String, Object?> status(bool failed) => {
      ...phoneStatus(a11y: true),
      'taskProtocol': 1,
      'tasks': [
        {'id': 11, 'sessionId': 'A', 'runId': 'run', 'stopped': true, 'cleanupFailed': failed, 'finishing': failed},
      ],
    };
    final h = await pumpPhone(tester, const PhoneControlScreen(), native: FakePhoneNative(status: status(true)));
    final action = find.byKey(const ValueKey('phone-resume-11'));
    await tester.ensureVisible(action);
    await tester.tap(action);
    await tester.pump();
    expect(h.native!.callsOf('retryTaskCleanup').single.arguments, {'taskId': 11});
    expect(h.native!.callsOf('resumeTask'), isEmpty);
    h.native!.push(status(false));
    await settlePhone(tester);
    await tester.tap(action);
    await tester.pump();
    expect(h.native!.callsOf('resumeTask').single.arguments, {'taskId': 11});
  });

  testWidgets('a newer stopped run cannot hide an older cleanup failure in its session', (tester) async {
    final h = await pumpPhone(
      tester,
      const PhoneControlScreen(),
      native: FakePhoneNative(
        status: {
          ...phoneStatus(a11y: true),
          'taskProtocol': 1,
          'tasks': [
            {'id': 11, 'sessionId': 'A', 'runId': 'old', 'cleanupFailed': true, 'finishing': true},
            {'id': 12, 'sessionId': 'A', 'runId': 'new', 'stopped': true},
          ],
        },
      ),
    );
    expect(find.byKey(const ValueKey('phone-resume-12')), findsNothing);
    final retry = find.byKey(const ValueKey('phone-resume-11'));
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    await tester.pump();
    expect(h.native!.callsOf('retryTaskCleanup').single.arguments, {'taskId': 11});
    expect(h.native!.callsOf('resumeTask'), isEmpty);
  });

  testWidgets('legacy cleanup failure is recoverable without adding modern sticky resume', (tester) async {
    final h = await pumpPhone(
      tester,
      const PhoneControlScreen(),
      native: FakePhoneNative(
        status: {
          ...phoneStatus(a11y: true),
          'taskProtocol': 1,
          'tasks': [
            {'id': 9, 'stopped': true, 'cleanupFailed': true, 'finishing': true},
          ],
        },
      ),
    );
    final retry = find.byKey(const ValueKey('phone-resume-9'));
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    await tester.pump();
    expect(h.native!.callsOf('retryTaskCleanup').single.arguments, {'taskId': 9});
    h.native!.push({
      ...phoneStatus(a11y: true),
      'taskProtocol': 1,
      'tasks': [
        {'id': 9, 'stopped': true},
      ],
    });
    await settlePhone(tester);
    expect(find.byKey(const ValueKey('phone-resume-9')), findsNothing);
    expect(h.native!.callsOf('resumeTask'), isEmpty);
  });

  testWidgets('status events update the page live', (tester) async {
    final h = await pumpPhone(tester, const PhoneControlScreen());
    expect(inTile('无障碍服务', find.byType(DoneMark)), findsNothing);
    h.native!.push(phoneStatus(a11y: true));
    await settlePhone(tester);
    expect(find.text('无障碍服务'), findsNothing);
  });

  group('规则 and 最近操作', () {
    testWidgets('shows the newest three actions and the full log page', (tester) async {
      final h = await pumpPhone(tester, const PhoneControlScreen());
      expect(find.text('4 个不碰 · 1 个每步确认'), findsOneWidget);
      expect(find.text('点「路线」'), findsNothing);
      await openPhoneFold(tester, 'phone-more-options');
      expect(find.text('点「路线」'), findsOneWidget);
      expect(find.text('给 张三 发送：“晚上见”'), findsOneWidget);
      expect(find.text('打开「支付宝」'), findsOneWidget);
      expect(find.text('看屏幕'), findsNothing);
      expect(find.text('已执行'), findsOneWidget);
      expect(find.text('你允许了'), findsOneWidget);
      expect(find.text('已拦下'), findsOneWidget);

      await tester.ensureVisible(find.text('全部记录'));
      await tester.tap(find.text('全部记录'));
      await tester.pumpAndSettle();
      expect(find.byType(PhoneActionLogPage), findsOneWidget);
      expect(find.byType(ActionLogRow), findsNWidgets(4));
      expect(find.text('看屏幕'), findsOneWidget);
      expect(h.native!.callsOf('actionLog').last.arguments, {'limit': PhoneActionLogPage.limit});
    });

    testWidgets('an empty log says what will appear there', (tester) async {
      await pumpPhone(tester, const PhoneControlScreen(), native: FakePhoneNative(log: const []));
      await openPhoneFold(tester, 'phone-more-options');
      expect(find.text('还没有记录'), findsOneWidget);
      expect(find.text('全部记录'), findsNothing);
    });

    testWidgets('不打扰模式 row shows its state and opens the page', (tester) async {
      await pumpPhone(
        tester,
        const PhoneControlScreen(),
        native: FakePhoneNative(
          status: phoneStatus(mode: 'shizuku', backgroundReason: 'Shizuku 没有在运行'),
        ),
      );
      await tester.scrollUntilVisible(find.text('不打扰模式'), 200, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expect(find.text('Shizuku · Shizuku 没有在运行'), findsOneWidget);
      await tester.tap(find.text('不打扰模式'));
      await tester.pumpAndSettle();
      expect(find.byType(PhoneDndPage), findsOneWidget);
    });
  });
}
