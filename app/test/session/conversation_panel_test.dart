// A phone's header and side panel: the title gets the header's width, the model moves
// beside the composer, and the panel shows the conversation's panes.

import 'package:dsh_app/plugins/native/native_model.dart';
import 'package:dsh_app/plugins/native/native_state.dart';
import 'package:dsh_app/state/agents_state.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/quick_panel_state.dart';
import 'package:dsh_app/ui/chat/chat_header.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/empty_state.dart' show chatClock;
import 'package:dsh_app/ui/chat/model_sheet.dart';
import 'package:dsh_app/ui/chat/widgets/attachments.dart' show AttachButton;
import 'package:dsh_app/ui/session/conversation_overview.dart';
import 'package:dsh_app/ui/session/conversation_panel.dart';
import 'package:dsh_app/ui/session/conversation_panes.dart';
import 'package:dsh_app/ui/session/session_tab.dart';
import 'package:dsh_app/ui/shell/drawer/drawer_destination.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderScope;
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import '../chat/support/sample_chat.dart';

ChatState _chat() => ChatState(
  items: <ChatItem>[
    user(1, '问题'),
    assistant(2, '回答', rowKey: 'm'),
  ],
  title: '修复登录重复提交的问题并补上回归测试',
  loading: false,
);

ChatHarness _harness({Map<String, ChatState>? states, List<Override> extra = const []}) =>
    ChatHarness(session: 's1', states: states ?? {'s1': _chat()}, extra: extra);

void main() {
  setUpAll(() async {
    await loadTestFonts();
    chatClock = () => DateTime(2026, 10, 23, 9);
  });

  group('the header', () {
    Future<void> screen(WidgetTester tester, Size size) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.reset);
      mockClipboard(tester);
      await tester.pumpWidget(testApp(const ChatScreen(), overrides: _harness().overrides));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }

    testWidgets('on a phone the title has the room, the model under it', (tester) async {
      await screen(tester, const Size(390, 844));
      expect(find.byType(ModelChip), findsNothing);
      expect(find.descendant(of: find.byType(ChatHeader), matching: find.textContaining('V4 Pro')), findsNothing);
      final title = tester.getRect(find.byKey(const ValueKey('chat-title-pill')));
      final call = tester.getRect(find.byKey(const ValueKey('chat-call')));
      expect(call.left - title.right, lessThan(12), reason: 'a long title reaches the keys');
      expect(tester.takeException(), isNull);
    });

    testWidgets('typing opens the composer: corners tighten, the model shows, then it folds', (tester) async {
      await screen(tester, const Size(390, 844));
      final row = find.byKey(const ValueKey('composer-model'));
      BorderRadiusGeometry? corners() => tester
          .widget<GlassSurface>(find.ancestor(of: find.byType(TextField), matching: find.byType(GlassSurface)).first)
          .borderRadius;
      final capsule = corners();
      final resting = tester.getSize(find.byType(Composer)).height;
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      expect(corners(), isNot(capsule));
      expect(tester.getSize(find.byType(Composer)).height, greaterThan(resting));
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(find.text('思考深度'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tapAt(const Offset(195, 60));
      await tester.pumpAndSettle();
      expect(corners(), isNot(capsule), reason: 'it waited behind the sheet');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      expect(corners(), capsule);
      expect(tester.getSize(find.byType(Composer)).height, resting);
    });

    testWidgets('the keyboard going down closes it, with the field still focused', (tester) async {
      await screen(tester, const Size(390, 844));
      BorderRadiusGeometry? corners() => tester
          .widget<GlassSurface>(find.ancestor(of: find.byType(TextField), matching: find.byType(GlassSurface)).first)
          .borderRadius;
      final capsule = corners();
      final resting = tester.getSize(find.byType(Composer)).height;
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      final field = tester.getSize(find.byType(TextField)).width;
      expect(find.byType(TextField), findsOneWidget);
      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus?.hasFocus, isTrue);
      expect(corners(), capsule);
      expect(tester.getSize(find.byType(Composer)).height, resting);
      expect(tester.getSize(find.byType(TextField)).width, lessThan(field));
      // And tapping back in opens it again.
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      expect(corners(), isNot(capsule));
    });

    testWidgets('the keys slide down evenly as it opens, no jump', (tester) async {
      await screen(tester, const Size(390, 844));
      final key = find.byKey(const ValueKey('composer-model'));
      expect(tester.getSize(find.byType(Composer)).height, greaterThan(0));
      await tester.tap(find.byType(TextField));
      await tester.pump();
      var last = tester.getSize(find.byType(Composer)).height;
      var largest = 0.0;
      for (var i = 0; i < 24; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        final now = tester.getSize(find.byType(Composer)).height;
        largest = largest > (now - last).abs() ? largest : (now - last).abs();
        last = now;
      }
      await tester.pumpAndSettle();
      expect(largest, lessThan(8), reason: 'the height moves a little every frame');
      final plus = tester.getRect(find.byType(AttachButton));
      final glass = tester.getRect(find.byType(Composer));
      // The same gap all round the second row: beside the pill and to the glass.
      expect(tester.getRect(key).left - plus.right, moreOrLessEquals(plus.left - glass.left, epsilon: 0.5));
      expect(glass.bottom - plus.bottom, moreOrLessEquals(plus.left - glass.left, epsilon: 0.5));
      expect(tester.getRect(key).center.dy, moreOrLessEquals(plus.center.dy, epsilon: 0.5));
      expect(tester.getRect(key).width, lessThan(160), reason: 'as wide as its words, the rest left free');
      expect(tester.getRect(key).top, greaterThan(tester.getRect(find.byType(TextField)).top));
    });

    testWidgets('the model pill grows with large text instead of spilling', (tester) async {
      await tester.pumpWidget(
        testApp(
          Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(4)),
              child: Scaffold(
                body: Center(
                  child: ComposerModelPill(selection: testCatalog.defaultSelection, onSelected: (_) {}),
                ),
              ),
            ),
          ),
          overrides: _harness().overrides,
        ),
      );
      await tester.pump();
      final pill = tester.getRect(find.byKey(const ValueKey('composer-model')));
      final words = tester.getRect(find.byType(RichText).last);
      expect(pill.height, greaterThan(36));
      expect(pill.height, words.height, reason: 'as tall as its words, whatever room it is given');
      expect(pill.top, lessThanOrEqualTo(words.top));
      expect(pill.bottom, greaterThanOrEqualTo(words.bottom));
    });

    testWidgets('a wide window keeps its chip', (tester) async {
      await screen(tester, const Size(900, 800));
      expect(find.byType(ModelChip), findsOneWidget);
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('composer-model')), findsNothing, reason: 'the chip says it');
    });
  });

  group('the composer\'s gaps', () {
    // Something taller than a key beside the send key, as the context ring can be.
    Future<FocusNode> composer(WidgetTester tester) async {
      usePhoneView(tester);
      final focus = FocusNode();
      addTearDown(focus.dispose);
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: Composer(
                controller: TextEditingController(),
                focusNode: focus,
                connected: true,
                running: false,
                onSend: () {},
                onStop: () {},
                leading: AttachButton(onPressed: () {}),
                accessory: const SizedBox(key: Key('ring'), width: 50, height: 44),
                footer: const SizedBox(key: Key('pill'), width: 100, height: 36),
              ),
            ),
          ),
        ),
      );
      return focus;
    }

    void even(WidgetTester tester, {required bool open}) {
      final glass = tester.getRect(find.byType(Composer));
      final plus = tester.getRect(find.byType(AttachButton));
      final side = plus.left - glass.left;
      expect(glass.bottom - plus.bottom, moreOrLessEquals(side, epsilon: 0.5), reason: 'below the keys');
      if (!open) expect(plus.top - glass.top, moreOrLessEquals(side, epsilon: 0.5), reason: 'above them');
      final ring = tester.getRect(find.byKey(const Key('ring')));
      expect(ring.center.dy, moreOrLessEquals(plus.center.dy, epsilon: 0.5), reason: 'one centre line');
      if (open) {
        final pill = tester.getRect(find.byKey(const Key('pill')));
        expect(pill.center.dy, moreOrLessEquals(plus.center.dy, epsilon: 0.5), reason: 'one centre line');
        expect(pill.left - plus.right, moreOrLessEquals(side, epsilon: 0.5), reason: 'beside the pill');
      }
    }

    testWidgets('are even at rest and open, with something tall beside the key', (tester) async {
      final focus = await composer(tester);
      even(tester, open: false);
      focus.requestFocus();
      await tester.pumpAndSettle();
      even(tester, open: true);
      focus.unfocus();
      await tester.pumpAndSettle();
      even(tester, open: false);
    });
  });

  testWidgets('glass over a web page does not blur what it cannot see', (tester) async {
    await tester.pumpWidget(
      testApp(
        const Column(
          children: [
            GlassSurface(tier: GlassTier.chrome, child: SizedBox.square(dimension: 40)),
            GlassOverNativeView(
              child: GlassSurface(
                tier: GlassTier.chrome,
                child: SizedBox.square(key: Key('web'), dimension: 40),
              ),
            ),
          ],
        ),
      ),
    );
    expect(find.byType(BackdropFilter), findsOneWidget, reason: 'the first one only');
    expect(find.ancestor(of: find.byKey(const Key('web')), matching: find.byType(BackdropFilter)), findsNothing);
  });

  group('sliding glass', () {
    testWidgets('fades to glass when it lands and stops sampling when it moves', (tester) async {
      final motion = AnimationController(vsync: const TestVSync());
      addTearDown(motion.dispose);
      await tester.pumpWidget(
        testApp(
          SlidingGlass(
            motion: motion,
            tier: GlassTier.sheet,
            borderRadius: BorderRadius.zero,
            child: const SizedBox.square(key: Key('inside'), dimension: 50),
          ),
        ),
      );
      double settled() => tester.widget<GlassSurface>(find.byType(GlassSurface)).settled!;
      final inside = tester.element(find.byKey(const Key('inside')));
      expect(settled(), 0);
      motion.value = 0.5;
      await tester.pump();
      expect(settled(), 0, reason: 'moving: no sampling');
      motion.value = 1;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(settled(), inExclusiveRange(0, 1), reason: 'landing fades, it does not cut');
      await tester.pumpAndSettle();
      expect(settled(), 1);
      motion.value = 0.9;
      await tester.pump();
      expect(settled(), 0, reason: 'moving: no sampling from the first frame');
      expect(tester.widget<BackdropFilter>(find.byType(BackdropFilter)).enabled, isFalse);
      await tester.pump(const Duration(milliseconds: 40));
      expect(settled(), 0, reason: 'the moving panel stays opaque');
      await tester.pumpAndSettle();
      expect(settled(), 0);
      expect(tester.element(find.byKey(const Key('inside'))), same(inside), reason: 'content is not rebuilt');
    });
  });

  group('the panel', () {
    Future<List<DrawerDestination>> panel(WidgetTester tester, {ChatHarness? harness}) async {
      usePhoneView(tester);
      mockClipboard(tester);
      final opened = <DrawerDestination>[];
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: SizedBox(
              width: 334,
              child: ConversationPanel(sessionId: 's1', onOpen: opened.add),
            ),
          ),
          overrides: (harness ?? _harness()).overrides,
        ),
      );
      await tester.pump();
      return opened;
    }

    testWidgets('opens on 信息, with the whole title', (tester) async {
      await panel(tester);
      expect(find.byType(ConversationOverview), findsOneWidget);
      expect(find.text('修复登录重复提交的问题并补上回归测试'), findsOneWidget);
      expect(find.byKey(const ValueKey('overview-model')), findsOneWidget);
    });

    testWidgets('before the conversation has loaded, 信息 shows the title the list knows', (tester) async {
      final harness = _harness(states: {'s1': const ChatState(loading: true)});
      harness.sessions.listed = [
        SessionSummary(
          sessionId: 's1',
          updatedAt: DateTime(2026, 10, 23),
          running: false,
          blank: false,
          agentAvailable: false,
          projections: const SessionProjections(1, {'title': '列表里的标题'}),
        ),
      ];
      await panel(tester, harness: harness);
      await tester.pump();
      expect(find.text('列表里的标题'), findsOneWidget);
    });

    for (final (mode, opens) in [(SubagentMode.oneShot, false), (SubagentMode.continuable, true)]) {
      testWidgets('a ${mode.name} subagent ${opens ? 'can' : 'cannot'} change model from 信息', (tester) async {
        await panel(
          tester,
          harness: _harness(
            extra: [
              subagentParentProvider.overrideWith(
                (ref, id) => SubagentParent(
                  address: SubagentAddress(parentSessionId: 'p', childSessionId: id, mode: mode),
                  label: '子代理',
                  parentTitle: '上级',
                ),
              ),
            ],
          ),
        );
        await tester.tap(find.byKey(const ValueKey('overview-model')), warnIfMissed: false);
        await tester.pumpAndSettle();
        expect(find.text('思考深度'), opens ? findsOneWidget : findsNothing);
      });
    }

    for (final (turnsOneShot, picks) in [(false, 1), (true, 0)]) {
      testWidgets('a model picked after the conversation ${turnsOneShot ? 'turned out' : 'did not turn out'} '
          'one-shot: $picks set', (tester) async {
        var mode = SubagentMode.continuable;
        final harness = _harness(
          extra: [
            subagentParentProvider.overrideWith(
              (ref, id) => SubagentParent(
                address: SubagentAddress(parentSessionId: 'p', childSessionId: id, mode: mode),
                label: '子代理',
                parentTitle: '上级',
              ),
            ),
          ],
        );
        await panel(tester, harness: harness);
        await tester.tap(find.byKey(const ValueKey('overview-model')));
        await tester.pumpAndSettle();
        if (turnsOneShot) {
          mode = SubagentMode.oneShot;
          ProviderScope.containerOf(tester.element(find.byType(ConversationOverview)))
              .invalidate(subagentParentProvider);
          await tester.pump();
        }
        await tester.tap(find.text('V41 Flash'));
        await tester.pumpAndSettle();
        expect(harness.controllers['s1']!.models, hasLength(picks));
      });
    }

    testWidgets('a plugin\'s conversation action is a row on 信息, signed with its name', (tester) async {
      await panel(
        tester,
        harness: _harness(
          extra: [
            nativeSessionActionsProvider.overrideWithValue(const [
              NativeAction(package: 'toolbox', surface: NativeSurface.sessionActions, id: 'mark', label: '标记这段对话'),
            ]),
          ],
        ),
      );
      final row = find.byKey(const ValueKey('overview-action|toolbox|mark'));
      expect(row, findsOneWidget);
      expect(find.descendant(of: row, matching: find.text('标记这段对话')), findsOneWidget);
      expect(find.descendant(of: row, matching: find.text('toolbox')), findsOneWidget);
    });

    testWidgets('a long action label at a large text size stays inside its row', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await panel(
        tester,
        harness: _harness(
          extra: [
            nativeSessionActionsProvider.overrideWithValue(const [
              NativeAction(
                package: 'toolbox',
                surface: NativeSurface.sessionActions,
                id: 'mark',
                label: '一二三四五六七八九十一二',
              ),
            ]),
          ],
        ),
      );
      final row = find.byKey(const ValueKey('overview-action|toolbox|mark'));
      final name = find.descendant(of: row, matching: find.text('toolbox'));
      expect(tester.getTopRight(name).dx, lessThanOrEqualTo(tester.getTopRight(row).dx));
    });

    testWidgets('a panel that asked only for its plugin page stays out of 插件', (tester) async {
      await panel(
        tester,
        harness: _harness(
          extra: [
            nativePanelsProvider.overrideWithValue(const [
              NativePanel(package: 'toolbox', id: 'about', title: '状态', placement: {DshGoPanel.pluginPage}),
            ]),
          ],
        ),
      );
      await tester.tap(find.text('插件').first);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pane-find-plugins')), findsOneWidget);
    });

    testWidgets('插件 is there with no plugins, and says where they come from', (tester) async {
      final opened = await panel(tester);
      await tester.tap(find.text('插件'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(ConversationOverview), findsNothing);
      expect(find.text('这段对话还没有插件面板'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('pane-find-plugins')));
      expect(opened, [DrawerDestination.plugins]);
    });

    Future<void> withPanels(WidgetTester tester, List<NativePanel> panels) async {
      usePhoneView(tester);
      mockClipboard(tester);
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: SizedBox(
              width: 334,
              child: ConversationPanel(sessionId: 's1', onOpen: (_) {}),
            ),
          ),
          overrides: [..._harness().overrides, nativePanelsProvider.overrideWithValue(panels)],
        ),
      );
      await tester.pump();
      await tester.tap(find.text('插件').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('several plugin panels get a row, whichever place they asked for', (tester) async {
      await withPanels(tester, const [
        NativePanel(package: 'a', id: 'chat', title: '工具', placement: {DshGoPanel.chatPanel}),
        NativePanel(package: 'a', id: 'tab', title: '统计', placement: {DshGoPanel.sessionTab}),
        NativePanel(package: 'b', id: 'all', title: '大全', placement: {DshGoPanel.features}),
      ]);
      expect(find.byKey(const ValueKey('pane-native|a|chat')), findsOneWidget);
      expect(find.byKey(const ValueKey('pane-native|a|tab')), findsOneWidget);
      expect(find.byKey(const ValueKey('pane-native|b|all')), findsOneWidget);
    });

    testWidgets('one plugin panel fills it, no row', (tester) async {
      await withPanels(tester, const [
        NativePanel(package: 'a', id: 'chat', title: '工具', placement: {DshGoPanel.chatPanel}),
      ]);
      expect(find.byKey(const ValueKey('pane-native|a|chat')), findsNothing);
      expect(find.text('这段对话还没有插件面板'), findsNothing);
    });

    testWidgets('every shortcut ticked on a narrow phone still fits', (tester) async {
      SharedPreferences.setMockInitialValues({
        QuickPanelController.itemsKey: [for (final d in DrawerDestination.values) d.name],
      });
      usePhoneView(tester);
      mockClipboard(tester);
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: SizedBox(
              width: 264,
              child: ConversationPanel(sessionId: 's1', onOpen: (_) {}),
            ),
          ),
          overrides: _harness().overrides,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
    });

    testWidgets('its foot opens the shortcuts', (tester) async {
      final opened = await panel(tester);
      await tester.tap(find.byKey(const ValueKey('quick-panel-settings')));
      expect(opened, [DrawerDestination.settings]);
    });
  });

  test('every tab of the page is a registered pane', () {
    for (final tab in SessionTab.values) {
      expect(ConversationPane.ofTab(tab).tab, tab);
    }
  });
}
