// The ＋ panel (settings-ia §4.4, media-generation §4.2): tiles equal and 8
// apart, 16 from the sides, the 本对话 card lined up with them; 权限 goes
// through `/permission`, 计划模式 through `/plan` and `/plan off`, 确认方式
// through `setPolicies`; and the permission pill on the composer's edge.

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/features_state.dart';
import 'package:dsh_app/state/risk_notice_store.dart';
import 'package:dsh_app/state/session_modes.dart';
import 'package:dsh_app/state/system_actions_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/widgets/permission_pill.dart';
import 'package:dsh_app/ui/chat/widgets/plus_panel.dart';
import 'package:dsh_app/ui/common/list_page_row.dart';
import 'package:dsh_app/ui/phone/system_actions_page.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../phone/support.dart';
import 'support/harness.dart';

final _zh = lookupL10n(AppLocale.zhCN);

class _Actions extends SystemActionsController {
  _Actions(this.enabled);
  final bool enabled;

  @override
  SystemActionsState build() => SystemActionsState(loaded: true, enabled: enabled);
}

class _NoRiskStore implements RiskNoticeStore {
  @override
  Future<bool> silenced(String id) async => false;

  @override
  Future<void> silence(String id) async {}
}

const _presets = PermissionState(
  options: [
    PermissionOption('read-only', 'Read only'),
    PermissionOption('workspace-write', 'Workspace write'),
    PermissionOption('auto', 'Auto'),
    PermissionOption('danger-full-access', 'Full access'),
  ],
  hostDefault: 'workspace-write',
  current: 'workspace-write',
  defaultRevision: 3,
);

List<Override> _extra({SessionModes modes = const SessionModes(preset: 'workspace-write')}) => [
  riskNoticeStoreProvider.overrideWithValue(_NoRiskStore()),
  permissionStateProvider.overrideWith((ref, id) async => _presets),
  sessionModesProvider.overrideWith((ref, id) => modes),
];

/// A page with one key that opens the panel.
Future<ChatHarness> _openPanel(
  WidgetTester tester, {
  double width = 390,
  double scale = 1,
  bool generate = false,
  bool files = true,
  String? session = 's1',
  Brightness brightness = Brightness.light,
  SessionModes modes = const SessionModes(preset: 'workspace-write'),
  List<Override> more = const [],
}) async {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = Size(width * 2, 844 * 2);
  tester.view.padding = const FakeViewPadding(top: 48, bottom: 32);
  tester.view.viewPadding = const FakeViewPadding(top: 48, bottom: 32);
  addTearDown(tester.view.reset);
  final harness = ChatHarness(newChatCatalogs: true, session: session);
  await tester.pumpWidget(
    testApp(
      MediaQuery.withClampedTextScaling(
        minScaleFactor: scale,
        maxScaleFactor: scale,
        child: Builder(
          builder: (context) => Scaffold(
            backgroundColor: Colors.transparent,
            body: AppBackdrop(
              child: Center(
                child: TextButton(
                  onPressed: () => showPlusPanel(context, files: files, generate: generate, sessionId: session),
                  child: const Text('打开'),
                ),
              ),
            ),
          ),
        ),
      ),
      brightness: brightness,
      overrides: [
        ...harness.overrides,
        ..._extra(modes: modes),
        ...more,
      ],
    ),
  );
  await tester.tap(find.text('打开'));
  await pumpFrames(tester);
  return harness;
}

List<Rect> _tiles(WidgetTester tester) => [
  for (final e in find.byType(PlusTile).evaluate()) tester.getRect(find.byWidget(e.widget)),
];

Rect _card(WidgetTester tester, {int index = 0}) =>
    tester.getRect(find.descendant(of: find.byType(ListPageCard), matching: find.byType(GlassSurface)).at(index));

void main() {
  group('geometry', () {
    for (final width in [320.0, 390.0]) {
      for (final generate in [false, true]) {
        for (final scale in [1.0, 1.3]) {
          testWidgets('${generate ? 4 : 3} tiles at ${width.round()} (×$scale): equal, 8 apart, 16 in; card lined up', (
            tester,
          ) async {
            await _openPanel(tester, width: width, generate: generate, scale: scale);
            final tiles = _tiles(tester);
            expect(tiles, hasLength(generate ? 4 : 3));
            expect(tiles.first.left, moreOrLessEquals(PlusPanelMetrics.side, epsilon: 0.01));
            expect(width - tiles.last.right, moreOrLessEquals(PlusPanelMetrics.side, epsilon: 0.01));
            for (var i = 1; i < tiles.length; i++) {
              expect(tiles[i].width, moreOrLessEquals(tiles.first.width, epsilon: 0.01));
              expect(tiles[i].left - tiles[i - 1].right, moreOrLessEquals(PlusPanelMetrics.gap, epsilon: 0.01));
              expect(tiles[i].top, tiles.first.top);
            }
            if (width == 320 && generate) expect(tiles.first.width, moreOrLessEquals(66, epsilon: 0.01));
            // The coloured squares sit centred in their tiles: mirrored.
            final squares = [
              for (final e in find.byType(PlusTile).evaluate())
                tester.getRect(find.descendant(of: find.byWidget(e.widget), matching: find.byType(Container)).first),
            ];
            expect(
              squares.first.left - tiles.first.left,
              moreOrLessEquals(tiles.last.right - squares.last.right, epsilon: 0.01),
            );
            final card = _card(tester);
            expect(card.left, moreOrLessEquals(tiles.first.left, epsilon: 0.01));
            expect(card.right, moreOrLessEquals(tiles.last.right, epsilon: 0.01));
            expect(tester.takeException(), isNull);
          });
        }
      }
    }

    testWidgets('a new chat has tiles only', (tester) async {
      await _openPanel(tester, session: null);
      expect(find.text('本对话'), findsNothing);
      expect(find.byType(ListPageCard), findsNothing);
    });

    testWidgets('生成 closes the panel with its choice', (tester) async {
      PlusChoice? picked;
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = const Size(780, 1688);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        testApp(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async => picked = await showPlusPanel(context, generate: true),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await pumpFrames(tester);
      await tester.tap(find.text('生成'));
      await pumpFrames(tester);
      expect(picked, isA<GenerateChoice>());
    });
  });

  group('本对话', () {
    testWidgets('权限 shows the preset and opens its page; a pick runs /permission', (tester) async {
      final harness = await _openPanel(tester);
      final row = find.ancestor(of: find.text('权限'), matching: find.byType(ListPageRow));
      expect(find.descendant(of: row, matching: find.text('工作区内修改')), findsOneWidget);
      await tester.tap(row);
      await pumpFrames(tester);
      expect(find.text('本对话的权限'), findsOneWidget);
      expect(find.text('新对话默认：工作区内修改'), findsOneWidget);
      await tester.tap(find.text('仅可查看'));
      await pumpFrames(tester);
      expect(harness.controllers['s1']!.commandLines, ['/permission read-only']);
      // Now looser than the default would not be; 只读 is offered as default.
      expect(find.text('设为新对话默认'), findsOneWidget);
    });

    testWidgets('完全权限 asks first', (tester) async {
      final harness = await _openPanel(tester);
      await tester.tap(find.text('权限'));
      await pumpFrames(tester);
      await tester.tap(find.text('完全权限'));
      await tester.pumpAndSettle();
      expect(harness.controllers['s1']?.commandLines ?? const <String>[], isEmpty);
      await tester.tap(find.widgetWithText(FilledButton, appL10n.riskFullAccessAction));
      await tester.pumpAndSettle();
      expect(harness.controllers['s1']!.commandLines, ['/permission danger-full-access']);
    });

    testWidgets('计划模式 runs /plan, then /plan off', (tester) async {
      final harness = await _openPanel(tester);
      final toggle = find.descendant(
        of: find.ancestor(of: find.text('计划模式'), matching: find.byType(ListPageRow)),
        matching: find.byType(Switch),
      );
      expect(tester.widget<Switch>(toggle).value, isFalse);
      await tester.tap(toggle);
      await pumpFrames(tester);
      expect(tester.widget<Switch>(toggle).value, isTrue);
      await tester.tap(toggle);
      await pumpFrames(tester);
      expect(harness.controllers['s1']!.commandLines, ['/plan', '/plan off']);
    });

    testWidgets('a plan mode already on reads on', (tester) async {
      await _openPanel(tester, modes: const SessionModes(preset: 'workspace-write', plan: true));
      final toggle = find.descendant(
        of: find.ancestor(of: find.text('计划模式'), matching: find.byType(ListPageRow)),
        matching: find.byType(Switch),
      );
      expect(tester.widget<Switch>(toggle).value, isTrue);
    });
  });

  group('系统操作', () {
    List<Override> on(String os, {required bool enabled}) => [
      operatingSystemProvider.overrideWithValue(os),
      systemActionsProvider.overrideWith(() => _Actions(enabled)),
    ];

    testWidgets('on HarmonyOS while it is on: follows the permissions, and the row opens its page', (tester) async {
      await _openPanel(tester, more: on('ohos', enabled: true));
      expect(find.text(_zh.systemActionsTitle), findsOneWidget);
      expect(find.text(_zh.systemActionsConfirmValue), findsOneWidget);
      await tester.tap(find.text(_zh.systemActionsConfirmTitle));
      await pumpFrames(tester);
      expect(find.byType(SystemActionsPage), findsOneWidget);
    });

    testWidgets('hidden while it is off', (tester) async {
      await _openPanel(tester, more: on('ohos', enabled: false));
      expect(find.text(_zh.systemActionsTitle), findsNothing);
    });

    testWidgets('never on Android', (tester) async {
      await _openPanel(tester, more: on('android', enabled: true));
      expect(find.text(_zh.systemActionsTitle), findsNothing);
    });
  });

  group('手机操控', () {
    testWidgets('hidden while phone control is off', (tester) async {
      FakePhoneNative(status: phoneStatus(enabled: false)).install();
      await _openPanel(tester);
      expect(find.text('确认方式'), findsNothing);
    });

    testWidgets('确认方式 picks a mode through setPolicies', (tester) async {
      final native = FakePhoneNative(status: phoneStatus(enabled: true))..install();
      await _openPanel(tester);
      await tester.pumpAndSettle();
      expect(find.text('确认方式'), findsOneWidget);
      expect(find.text('每次都询问'), findsOneWidget);
      // The two cards line up with each other.
      expect(_card(tester, index: 1).left, _card(tester).left);
      expect(_card(tester, index: 1).right, _card(tester).right);
      await tester.tap(find.text('确认方式'));
      await pumpFrames(tester);
      await tester.tap(find.text('本任务免确认'));
      await pumpFrames(tester);
      final call = native.callsOf('setPolicies').single;
      expect((call.arguments as Map)['confirmMode'], 'task');
    });
  });

  group('permission pill', () {
    Future<ChatHarness> pumpChat(WidgetTester tester, SessionModes modes, {double scale = 1}) async {
      usePhoneView(tester);
      final harness = ChatHarness(newChatCatalogs: true, session: 's1');
      await tester.pumpWidget(
        testApp(
          MediaQuery.withClampedTextScaling(minScaleFactor: scale, maxScaleFactor: scale, child: const ChatScreen()),
          overrides: [
            ...harness.overrides,
            ..._extra(modes: modes),
          ],
        ),
      );
      await pumpFrames(tester);
      return harness;
    }

    testWidgets('nothing for 工作区内修改', (tester) async {
      await pumpChat(tester, const SessionModes(preset: 'workspace-write'));
      expect(find.byType(PermissionPill), findsNothing);
    });

    for (final scale in [1.0, 1.3]) {
      testWidgets('完全权限: on the composer\'s edge, 34 high, equal end insets (×$scale)', (tester) async {
        await pumpChat(tester, const SessionModes(preset: 'danger-full-access'), scale: scale);
        final pill = tester.getRect(find.byType(PermissionPill));
        final composer = tester.getRect(find.byType(Composer));
        expect(pill.left, moreOrLessEquals(composer.left, epsilon: 0.01));
        expect(pill.height, PermissionPillMetrics.height);
        expect(composer.top - pill.bottom, moreOrLessEquals(8, epsilon: 0.01));
        final lead = tester.getRect(
          find.descendant(of: find.byType(PermissionPill), matching: find.byIcon(AppIcons.permissionRisky)),
        );
        final trail = tester.getRect(
          find
              .ancestor(
                of: find.descendant(of: find.byType(PermissionPill), matching: find.byIcon(AppIcons.disclosure)),
                matching: find.byType(SizedBox),
              )
              .first,
        );
        expect(lead.left - pill.left, moreOrLessEquals(PermissionPillMetrics.inset, epsilon: 0.01));
        expect(pill.right - trail.right, moreOrLessEquals(PermissionPillMetrics.inset, epsilon: 0.01));
        expect(lead.size, trail.size);
        expect(lead.center.dy, moreOrLessEquals(pill.center.dy, epsilon: 0.01));
        expect(trail.center.dy, moreOrLessEquals(pill.center.dy, epsilon: 0.01));
      });
    }

    testWidgets('a tap opens this chat\'s permissions', (tester) async {
      await pumpChat(tester, const SessionModes(preset: 'auto'));
      expect(find.text('自动审查'), findsOneWidget);
      await tester.tap(find.byType(PermissionPill));
      await pumpFrames(tester);
      expect(find.text('本对话的权限'), findsOneWidget);
    });

    testWidgets('自动允许中 wins while this client allows everything', (tester) async {
      usePhoneView(tester);
      final harness = ChatHarness(newChatCatalogs: true, session: 's1', states: {'s1': const ChatState(loading: false, autoApprove: true)});
      await tester.pumpWidget(
        testApp(
          const ChatScreen(),
          overrides: [
            ...harness.overrides,
            ..._extra(modes: const SessionModes(preset: 'danger-full-access')),
          ],
        ),
      );
      await pumpFrames(tester);
      expect(find.byType(AutoApprovePill), findsOneWidget);
      expect(find.byType(PermissionPill), findsNothing);
    });
  });

  goldens();
}

/// Goldens, run last in [main].
void goldens() {
  group('goldens', () {
    for (final brightness in Brightness.values) {
      final suffix = brightness.name;
      testWidgets('panel with 生成, 本对话 and 手机操控 ($suffix)', (tester) async {
        FakePhoneNative(status: phoneStatus(enabled: true)).install();
        await _openPanel(tester, generate: true, brightness: brightness);
        await tester.pumpAndSettle();
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/plus_panel_$suffix.png'));
      });

      testWidgets('panel at 320 ×1.3 ($suffix)', (tester) async {
        FakePhoneNative(status: phoneStatus(enabled: false)).install();
        await _openPanel(tester, generate: true, width: 320, scale: 1.3, brightness: brightness);
        await tester.pumpAndSettle();
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/plus_panel_320_$suffix.png'));
      });

      testWidgets('本对话的权限 ($suffix)', (tester) async {
        await _openPanel(tester, brightness: brightness);
        await tester.tap(find.text('权限'));
        await tester.pumpAndSettle();
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/plus_panel_permission_$suffix.png'));
      });

      testWidgets('permission pill ($suffix)', (tester) async {
        usePhoneView(tester);
        final harness = ChatHarness(newChatCatalogs: true, session: 's1');
        await tester.pumpWidget(
          testApp(
            const ChatScreen(),
            brightness: brightness,
            overrides: [
              ...harness.overrides,
              ..._extra(modes: const SessionModes(preset: 'danger-full-access')),
            ],
          ),
        );
        await pumpFrames(tester);
        await expectLater(find.byType(ChatScreen), matchesGoldenFile('goldens/permission_pill_$suffix.png'));
      });
    }
  });
}
