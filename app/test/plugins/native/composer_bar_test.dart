// The row above the composer: ui.json's capsules and the plugins' in one
// row, the plugins' status line above it, and what a tap does — insert,
// never send; static effects without asking the plugin; the 3 s window;
// the one-time 「要读取剪贴板」; deferred results with a working capsule
// that a tap cancels.

import 'dart:async';

import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/plugins/native/native_model.dart';
import 'package:dsh_app/plugins/native/native_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/plugins/native/composer_capsules.dart';
import 'package:dsh_app/ui/plugins/native/composer_strip.dart';
import 'package:dsh_app/ui/plugins/native/native_composer_bar.dart';
import 'package:dsh_app/ui/plugins/native/native_panel.dart';
import 'package:dsh_app/ui_config/ui_config.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../clipboard/fake_paste.dart';
import '../../chat/support/harness.dart';
import 'support.dart';

const _quick = [
  UiQuickAction(label: '总结', action: UiSendAction('总结上面的对话')),
  UiQuickAction(label: '压缩', action: UiCommandAction('compact')),
];

/// The bar over a stand-in composer, at the bottom of a phone screen.
Widget bar(
  FakeBridge bridge, {
  FakeComposer? composer,
  List<UiQuickAction>? quick,
  String? sessionId = 's1',
  bool visible = true,
  DateTime Function()? clock,
  Widget? leading,
  String? os,
}) {
  final host = composer ?? FakeComposer(sessionId: sessionId);
  return testApp(
    Scaffold(
      backgroundColor: Colors.transparent,
      body: withComposer(
        host,
        Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                NativeComposerBar(sessionId: sessionId, visible: visible, leading: leading),
                const SizedBox(key: ValueKey('composer'), height: 56),
              ],
            ),
          ),
        ),
      ),
    ),
    overrides: [
      if (os != null) operatingSystemProvider.overrideWithValue(os),
      ...nativeOverrides(bridge, quick: quick, clock: clock),
    ],
  );
}

List<String> capsuleLabels(WidgetTester tester) => [
  for (final c in tester.widgetList<ComposerCapsule>(find.byType(ComposerCapsule))) c.item.label,
];

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('no ui.json capsules and no plugins: the bar takes no room', (tester) async {
    usePhoneView(tester);
    await tester.pumpWidget(bar(FakeBridge()));
    await pumpFrames(tester);
    expect(tester.getSize(find.byType(NativeComposerBar)).height, 0);
    expect(find.byType(ComposerCapsule), findsNothing);
    expect(find.byType(ComposerStrip), findsNothing);
  });

  testWidgets('ui.json first, then each plugin; eight at most; commands need a conversation', (tester) async {
    usePhoneView(tester);
    final bridge = FakeBridge(
      contributions([
        quickPlugin(),
        plugin(
          'more',
          composer: [
            {'id': 'a', 'label': 'A'},
            {'id': 'b', 'label': 'B'},
          ],
        ),
      ]),
    );
    final many = [for (var i = 0; i < 5; i++) UiQuickAction(label: '模板$i', action: UiSendAction('t$i')), ..._quick];
    await tester.pumpWidget(bar(bridge, quick: many));
    await pumpFrames(tester);
    expect(capsuleLabels(tester), ['模板0', '模板1', '模板2', '模板3', '模板4', '总结', '压缩', '译成英文']);

    await tester.pumpWidget(bar(bridge, quick: _quick, sessionId: null));
    await pumpFrames(tester);
    expect(capsuleLabels(tester), ['总结', '译成英文', '打招呼', 'A', 'B'], reason: 'no 压缩 on the new-chat screen');
  });

  testWidgets('a ui.json capsule fills the composer and never sends', (tester) async {
    usePhoneView(tester);
    final composer = FakeComposer();
    await tester.pumpWidget(bar(FakeBridge(), composer: composer, quick: _quick));
    await pumpFrames(tester);
    await tester.tap(find.text('总结'));
    await pumpFrames(tester);
    expect(composer.inserted, ['总结上面的对话']);
  });

  testWidgets('a plugin capsule asks the plugin and puts its answer in the composer', (tester) async {
    usePhoneView(tester);
    final composer = FakeComposer();
    final bridge = FakeBridge(contributions([quickPlugin()]))
      ..answer = (_) => DshGoInvokeResult.fromJson({
        'v': 1,
        'effects': [
          {'type': 'insert', 'text': 'Hello'},
        ],
      });
    await tester.pumpWidget(bar(bridge, composer: composer));
    await pumpFrames(tester);
    await tester.tap(find.text('译成英文'));
    await pumpFrames(tester);
    final call = bridge.invocations.single;
    expect((call.pkg, call.id, call.surface), ('dsh-go-example-quick', 'translate', 'composer.actions'));
    expect(call.scope, const DshGoScope(sessionId: 's1'));
    expect(call.stream, 'c1', reason: 'the stream connection a deferred result would come back on');
    expect(call.draft, isNull, reason: 'nothing it did not ask for');
    expect(composer.inserted, ['Hello']);
  });

  testWidgets('a static effect runs here; the plugin is never asked', (tester) async {
    usePhoneView(tester);
    final composer = FakeComposer();
    final bridge = FakeBridge(contributions([quickPlugin()]));
    await tester.pumpWidget(bar(bridge, composer: composer));
    await pumpFrames(tester);
    await tester.tap(find.text('打招呼'));
    await pumpFrames(tester);
    expect(composer.inserted, ['你好']);
    expect(bridge.invocations, isEmpty);
  });

  testWidgets('what comes back more than 3 s after the tap is dropped', (tester) async {
    usePhoneView(tester);
    final composer = FakeComposer();
    var now = DateTime(2026, 10, 25, 12);
    final bridge = FakeBridge(contributions([quickPlugin()]))
      ..answer = (_) {
        now = now.add(const Duration(seconds: 4));
        return DshGoInvokeResult.fromJson({
          'effects': [
            {'type': 'insert', 'text': 'late'},
          ],
        });
      };
    late ProviderContainer container;
    await tester.pumpWidget(bar(bridge, composer: composer, clock: () => now));
    await pumpFrames(tester);
    container = ProviderScope.containerOf(tester.element(find.byType(NativeComposerBar)));
    await tester.tap(find.text('译成英文'));
    await pumpFrames(tester);
    expect(composer.inserted, isEmpty);
    final issues = container.read(nativePluginDiagnosticsProvider('dsh-go-example-quick')).issues;
    expect(issues.single.message, '点按 3 秒后才返回，已忽略');
    expect(issues.single.pointer, '/runtime/translate/effects');
  });

  testWidgets('reading the clipboard asks once; declined, nothing is sent', (tester) async {
    usePhoneView(tester);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => call.method == 'Clipboard.getData' ? {'text': '你好世界'} : null,
    );
    final bridge = FakeBridge(
      contributions([
        quickPlugin(wants: ['clipboard']),
      ]),
    );
    await tester.pumpWidget(bar(bridge));
    await pumpFrames(tester);

    await tester.tap(find.text('译成英文'));
    await pumpFrames(tester);
    expect(find.text('「快捷指令」要读取剪贴板'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await pumpFrames(tester);
    expect(bridge.invocations, isEmpty);

    await tester.tap(find.text('译成英文'));
    await pumpFrames(tester);
    await tester.tap(find.text('允许'));
    await pumpFrames(tester);
    expect(bridge.invocations.single.clipboard, '你好世界');

    await tester.tap(find.text('译成英文'));
    await pumpFrames(tester);
    expect(find.text('「快捷指令」要读取剪贴板'), findsNothing, reason: 'asked once');
    expect(bridge.invocations, hasLength(2));
  });

  group('reading the clipboard on HarmonyOS', () {
    Future<FakeBridge> allowed(WidgetTester tester, {DateTime Function()? clock}) async {
      usePhoneView(tester);
      SharedPreferences.setMockInitialValues({});
      final bridge = FakeBridge(
        contributions([
          quickPlugin(wants: ['clipboard']),
        ]),
      );
      await tester.pumpWidget(bar(bridge, os: 'ohos', clock: clock));
      await pumpFrames(tester);
      return bridge;
    }

    Future<void> tapAndAllow(WidgetTester tester) async {
      await tester.tap(find.text('译成英文'));
      await pumpFrames(tester);
      if (find.text('允许').evaluate().isNotEmpty) {
        await tester.tap(find.text('允许'));
        await pumpFrames(tester);
      }
    }

    testWidgets('允许 is not the system\'s grant: the paste button still opens, then the text travels', (tester) async {
      final paste = FakePaste(tester, reply: FakePaste.text('你好世界'), flutterText: 'wrong');
      final bridge = await allowed(tester);
      await tester.tap(find.text('译成英文'));
      await pumpFrames(tester);
      expect(find.text('「快捷指令」要读取剪贴板'), findsOneWidget);
      expect(paste.reads, isEmpty, reason: 'nothing read before 允许');
      await tester.tap(find.text('允许'));
      await pumpFrames(tester);
      expect(paste.reads, hasLength(1));
      expect(paste.flutterReads, 0);
      expect(bridge.invocations.single.clipboard, '你好世界');

      await tester.tap(find.text('译成英文'));
      await pumpFrames(tester);
      expect(paste.reads, hasLength(2), reason: 'each tap asks the system again, though 允许 is remembered');
      expect(bridge.invocations, hasLength(2));
    });

    testWidgets('backed out of: the tap ends, nothing is sent or said', (tester) async {
      FakePaste(tester, reply: {'status': 'cancelled'});
      final bridge = await allowed(tester);
      await tapAndAllow(tester);
      expect(bridge.invocations, isEmpty);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('a read that failed: the tap ends and it says so', (tester) async {
      FakePaste(tester, reply: {'status': 'unavailable'});
      final bridge = await allowed(tester);
      await tapAndAllow(tester);
      expect(bridge.invocations, isEmpty);
      expect(find.text('无法读取剪贴板，请重试或手动输入。'), findsOneWidget);
    });

    testWidgets('an empty clipboard goes on without one, as on Android; the toast has said it', (tester) async {
      FakePaste(tester, reply: {'status': 'empty', 'shown': true});
      final bridge = await allowed(tester);
      await tapAndAllow(tester);
      expect(bridge.invocations.single.clipboard, isNull);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('time spent in the window doesn\'t age the tap: the paste button is the gesture', (tester) async {
      var now = DateTime(2026, 10, 25, 12);
      final paste = FakePaste(tester, reply: FakePaste.text('你好'))..gate = Completer<void>();
      final bridge = await allowed(tester, clock: () => now);
      await tapAndAllow(tester);
      expect(bridge.invocations, isEmpty);
      now = now.add(const Duration(seconds: 10));
      paste.gate!.complete();
      await pumpFrames(tester);
      expect(bridge.invocations.single.userGesture, isTrue);
    });
  });

  testWidgets('deferred: the capsule works in place until the result; a tap cancels; void says so', (tester) async {
    usePhoneView(tester);
    final composer = FakeComposer();
    var next = 0;
    final bridge = FakeBridge(contributions([quickPlugin()]))
      ..answer = (_) => DshGoInvokeResult.fromJson({
        'v': 1,
        'effects': [],
        'pending': {'id': 'p${++next}', 'label': '翻译中', 'timeoutMs': 30000},
      });
    await tester.pumpWidget(bar(bridge, composer: composer));
    await pumpFrames(tester);
    final capsule = find.widgetWithText(ComposerCapsule, '译成英文');
    final before = tester.getRect(capsule);

    // 1. Done: the result lands in the composer.
    await tester.tap(capsule);
    await pumpFrames(tester, 3);
    expect(find.byKey(const ValueKey('capsule-ring')), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(tester.getRect(capsule), before, reason: 'working, the capsule keeps its place and size');
    expect(
      tester.getCenter(find.byType(CircularProgressIndicator)),
      tester.getCenter(capsule),
      reason: 'the ring sits in the middle',
    );
    bridge.socket.push({
      't': 'done',
      'pending': 'p1',
      'effects': [
        {'type': 'insert', 'text': 'Hello'},
      ],
    });
    await pumpFrames(tester, 3);
    expect(composer.inserted, ['Hello']);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    // 2. A tap on the working capsule cancels; no note for that.
    await tester.tap(capsule);
    await pumpFrames(tester, 3);
    await tester.tap(capsule);
    await pumpFrames(tester, 1);
    expect(bridge.socket.sent.last, {'t': 'cancel', 'pending': 'p2'});
    bridge.socket.push({'t': 'void', 'pending': 'p2', 'reason': 'cancelled'});
    await pumpFrames(tester, 3);
    expect(find.text('没完成'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    // 3. Void (timed out on the host): one short note.
    await tester.tap(capsule);
    await pumpFrames(tester, 3);
    bridge.socket.push({'t': 'void', 'pending': 'p3', 'reason': 'timeout'});
    await pumpFrames(tester, 3);
    expect(find.text('没完成'), findsOneWidget);
    expect(composer.inserted, ['Hello']);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('the chat\'s pills lead the capsules in one row, pinned while they scroll', (tester) async {
    usePhoneView(tester);
    const pill = SizedBox(key: ValueKey('pill'), width: 120, height: CapsuleMetrics.height);
    final many = [for (var i = 0; i < 8; i++) UiQuickAction(label: '长长的模板$i', action: UiSendAction('t$i'))];
    await tester.pumpWidget(bar(FakeBridge(), quick: many, leading: pill));
    await pumpFrames(tester);
    final row = tester.getRect(find.byType(ComposerCapsuleRow));
    final lead = tester.getRect(find.byKey(const ValueKey('pill')));
    final first = tester.getRect(find.byType(ComposerCapsule).first);
    final composer = tester.getRect(find.byKey(const ValueKey('composer')));
    expect(row.height, CapsuleMetrics.height + CapsuleMetrics.below);
    expect(lead.left, composer.left);
    expect(lead.top, first.top);
    expect(first.left - lead.right, CapsuleMetrics.gap);
    expect(composer.top - lead.bottom, CapsuleMetrics.below);

    // Scrolled to the end, the pill stays where it was.
    await tester.drag(find.byType(SingleChildScrollView), const Offset(-2000, 0));
    await pumpFrames(tester);
    expect(tester.getRect(find.byKey(const ValueKey('pill'))), lead);
    expect(tester.getRect(find.byType(ComposerCapsule).first).left, lessThan(lead.right));

    // No capsules at all: the pill still has its row.
    await tester.pumpWidget(bar(FakeBridge(), quick: const [], leading: pill));
    await pumpFrames(tester);
    expect(tester.getSize(find.byType(NativeComposerBar)).height, CapsuleMetrics.height + CapsuleMetrics.below);
    expect(find.byKey(const ValueKey('pill')), findsOneWidget);
  });

  testWidgets('a reply generating: the bar steps aside', (tester) async {
    usePhoneView(tester);
    await tester.pumpWidget(bar(FakeBridge(), quick: _quick));
    await pumpFrames(tester);
    expect(tester.getSize(find.byType(NativeComposerBar)).height, greaterThan(0));
    await tester.pumpWidget(bar(FakeBridge(), quick: _quick, visible: false));
    await pumpFrames(tester);
    expect(tester.getSize(find.byType(NativeComposerBar)).height, 0);
  });

  testWidgets('the status line shows the plugin data in its tone, and opens its panel', (tester) async {
    usePhoneView(tester);
    final bridge = FakeBridge(contributions([usagePlugin()]));
    bridge.views['dsh-go-example-usage/usage'] = const DshGoView(
      pkg: 'dsh-go-example-usage',
      id: 'usage',
      title: '用量',
      view: {'type': 'metric', 'label': '本对话', 'value': '¥0.42'},
    );
    await tester.pumpWidget(bar(bridge));
    await pumpFrames(tester);
    final sub = bridge.socket.subOf('cost')!;
    expect(sub['scope'], {'sessionId': 's1'});
    expect(bridge.socket.sent.first, {
      't': 'hello',
      'v': [1],
      'locale': 'zh-CN',
    });
    expect(find.byType(ComposerStrip), findsNothing, reason: 'nothing to say yet');

    bridge.socket.push({
      't': 'data',
      'sub': sub['sub'],
      'rev': '1',
      'data': {'text': '本对话 ¥0.42 · 今日 ¥3.1', 'tone': 'warn'},
    });
    await pumpFrames(tester);
    expect(find.text('本对话 ¥0.42 · 今日 ¥3.1'), findsOneWidget);
    final strip = tester.widget<ComposerStrip>(find.byType(ComposerStrip));
    expect((strip.tone, strip.icon, strip.title), ('warn', 'coin', '用量'));

    await tester.tap(find.byType(ComposerStrip));
    await pumpFrames(tester);
    expect(find.byType(NativePanelPage), findsOneWidget);
    expect(find.text('¥0.42'), findsOneWidget);
  });

  testWidgets('two plugins with a status line take turns', (tester) async {
    usePhoneView(tester);
    final bridge = FakeBridge(
      contributions([
        usagePlugin(),
        plugin(
          'balance',
          strip: [
            {'id': 'left', 'live': true},
          ],
        ),
      ]),
    );
    await tester.pumpWidget(bar(bridge));
    await pumpFrames(tester);
    for (final (id, text) in [('cost', '本对话 ¥0.42'), ('left', '余额 ¥12.00')]) {
      bridge.socket.push({
        't': 'data',
        'sub': bridge.socket.subOf(id)!['sub'],
        'rev': '1',
        'data': {'text': text},
      });
    }
    await pumpFrames(tester);
    expect(find.text('本对话 ¥0.42'), findsOneWidget);
    await tester.pump(StripMetrics.turn);
    await pumpFrames(tester, 4);
    expect(find.text('余额 ¥12.00'), findsOneWidget);
    expect(find.text('本对话 ¥0.42'), findsNothing);
    expect(find.byType(ComposerStrip), findsOneWidget, reason: 'one line at a time');
  });

  testWidgets('a plugin with its capsules switched off shows none', (tester) async {
    usePhoneView(tester);
    final bridge = FakeBridge(contributions([quickPlugin()]));
    await tester.pumpWidget(bar(bridge, quick: _quick));
    await pumpFrames(tester);
    final container = ProviderScope.containerOf(tester.element(find.byType(NativeComposerBar)));
    expect(capsuleLabels(tester), ['总结', '压缩', '译成英文', '打招呼']);
    unawaited(
      container
          .read(nativeSurfacePrefsProvider.notifier)
          .set(container.read(activeHostProvider), 'dsh-go-example-quick', NativeSurface.composerActions, false),
    );
    await pumpFrames(tester);
    expect(capsuleLabels(tester), ['总结', '压缩']);
  });
}
