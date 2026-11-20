// Goldens of the native plugin slots, light and dark, Chinese and English:
// the bar above the composer (a plugin's status line, ui.json's capsules and
// a plugin's), a reply's menu with a plugin group, a native panel page, and
// the plugin's native settings. Regenerate with
// `flutter test --update-goldens test/plugins/native/native_slots_golden_test.dart`.

import 'package:dsh_app/plugins/native/native_model.dart';
import 'package:dsh_app/plugins/native/native_state.dart';
import 'package:dsh_app/plugins/seams/seams.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/widgets/assistant_message.dart';
import 'package:dsh_app/ui/plugins/native/native_composer_bar.dart';
import 'package:dsh_app/ui/plugins/native/native_panel.dart';
import 'package:dsh_app/ui/plugins/native/native_plugin_section.dart';
import 'package:dsh_app/ui/plugins/seats/session_plugins_tab.dart';
import 'package:dsh_app/ui/theme/backdrop.dart';
import 'package:dsh_app/ui_config/ui_config.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../chat/support/harness.dart';
import '../../support/english_preview.dart';
import 'support.dart';

/// The strings a bridge would give in each language.
class _Copy {
  const _Copy.zh()
    : quick = '快捷指令',
      translate = '译成英文',
      hello = '打招呼',
      speak = '朗读',
      summary = '要点',
      usage = '用量',
      strip = '本对话 ¥0.42 · 今日 ¥3.1',
      summarize = '总结',
      compact = '压缩',
      reply = '可以。先把超时从 30 秒调到 60 秒，再给重试加上幂等键，这样服务端处理过的请求不会被再执行一次。',
      session = '本对话',
      today = '今日',
      models = '按模型',
      reset = '清零';

  const _Copy.en()
    : quick = 'Quick actions',
      translate = 'To English',
      hello = 'Say hi',
      speak = 'Read aloud',
      summary = 'Key points',
      usage = 'Usage',
      strip = 'Chat ¥0.42 · Today ¥3.1',
      summarize = 'Summarize',
      compact = 'Compact',
      reply = 'Sure. Raise the timeout from 30 to 60 seconds, then give retries an idempotency key so a request the server already handled is not run twice.',
      session = 'This chat',
      today = 'Today',
      models = 'By model',
      reset = 'Reset';

  final String quick, translate, hello, speak, summary, usage, strip, summarize, compact, reply;
  final String session, today, models, reset;
}

FakeBridge _bridge(_Copy c) {
  final bridge = FakeBridge(
    contributions([
      plugin(
        'dsh-go-example-quick',
        title: c.quick,
        icon: 'bolt',
        composer: [
          {'id': 'translate', 'label': c.translate, 'icon': 'translate'},
          {
            'id': 'hello',
            'label': c.hello,
            'effect': [
              {'type': 'insert', 'text': 'hi'},
            ],
          },
        ],
        menu: [
          {'id': 'speak', 'label': c.speak, 'icon': 'speaker'},
          {'id': 'summary', 'label': c.summary, 'icon': 'summary'},
        ],
      ),
      plugin(
        'dsh-go-example-usage',
        title: c.usage,
        icon: 'chart',
        strip: [
          {'id': 'cost', 'icon': 'coin', 'panel': 'usage', 'tappable': true, 'live': true},
        ],
        panels: [
          {
            'id': 'usage',
            'title': c.usage,
            'icon': 'chart',
            'placement': ['session.tab', 'features'],
            'live': true,
          },
        ],
      ),
    ]),
  );
  bridge.views['dsh-go-example-usage/usage'] = DshGoView(
    pkg: 'dsh-go-example-usage',
    id: 'usage',
    title: c.usage,
    view: {
      'type': 'stack',
      'children': [
        {
          'type': 'row',
          'children': [
            {
              'type': 'metric',
              'label': c.session,
              'value': {r'$': 'data.session'},
            },
            {
              'type': 'metric',
              'label': c.today,
              'value': {r'$': 'data.today'},
            },
          ],
        },
        {
          'type': 'chart',
          'kind': 'bar',
          'categories': ['10/19', '10/20', '10/21', '10/22', '10/23', '10/24', '10/25'],
          'series': [
            {
              'values': [1.2, 2.8, 0.9, 3.4, 2.1, 1.6, 3.1],
            },
          ],
          'unit': '¥',
        },
        {
          'type': 'keyValue',
          'items': [
            ['deepseek-v4-pro', '¥2.40'],
            ['deepseek-v4-flash', '¥0.70'],
          ],
        },
        {
          'type': 'actions',
          'items': [
            {'label': c.reset, 'action': 'reset'},
          ],
        },
      ],
    },
    data: const {'session': '¥0.42', 'today': '¥3.1'},
    rev: 'r1',
    live: true,
  );
  return bridge;
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final english in [false, true]) {
    for (final brightness in Brightness.values) {
      final lang = english ? 'en' : 'zh';
      final suffix = '${lang}_${brightness == Brightness.dark ? 'dark' : 'light'}';
      const c0 = _Copy.zh();
      const c1 = _Copy.en();
      final c = english ? c1 : c0;

      // No seats unless a test brings its own: the capsule row asks them
      // whether to show 「插件」, and the real ones would open a connection.
      Widget app(
        Widget home,
        FakeBridge bridge, {
        List<UiQuickAction>? quick,
        SeatInventory? inventory,
        List<Override> more = const [],
      }) => testApp(
        english ? inEnglish(home) : home,
        brightness: brightness,
        overrides: [
          ...nativeOverrides(bridge, quick: quick),
          seatInventoryProvider.overrideWith((ref) => inventory),
          ...more,
        ],
      );

      testWidgets('the bar above the composer ($suffix)', (tester) async {
        if (english) useEnglish();
        usePhoneView(tester);
        final bridge = _bridge(c);
        final input = TextEditingController();
        addTearDown(input.dispose);
        await tester.pumpWidget(
          app(
            AppBackdrop(
              child: Scaffold(
                backgroundColor: Colors.transparent,
                body: withComposer(
                  FakeComposer(),
                  Stack(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 80, 16, 0),
                        child: Builder(
                          builder: (context) => Text(c.reply, style: Theme.of(context).textTheme.bodyLarge),
                        ),
                      ),
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 40),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const NativeComposerBar(sessionId: 's1', visible: true),
                              Composer(
                                controller: input,
                                connected: true,
                                running: false,
                                onSend: () {},
                                onStop: () {},
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            bridge,
            quick: [
              UiQuickAction(label: c.summarize, action: const UiSendAction('…')),
              UiQuickAction(label: c.compact, action: const UiCommandAction('compact')),
            ],
          ),
        );
        await pumpFrames(tester);
        bridge.socket.push({
          't': 'data',
          'sub': bridge.socket.subOf('cost')!['sub'],
          'rev': '1',
          'data': {'text': c.strip},
        });
        await pumpFrames(tester);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/composer_bar_$suffix.png'));
      });

      testWidgets('a reply menu with a plugin group ($suffix)', (tester) async {
        if (english) useEnglish();
        usePhoneView(tester);
        final reply = AssistantChatItem(id: 'a18', seq: 18, text: c.reply, reasoning: '');
        await tester.pumpWidget(
          app(
            Scaffold(
              body: SafeArea(
                child: withComposer(
                  FakeComposer(),
                  Column(
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(16),
                          child: AssistantMessage(item: reply, showActions: true),
                        ),
                      ),
                      const NativeComposerBar(sessionId: 's1', visible: false),
                    ],
                  ),
                ),
              ),
            ),
            _bridge(c),
            more: [
              chatProvider.overrideWith2(
                (id) => FakeChatController(id, const ChatState(loading: false))..replyIds[18] = 'm18',
              ),
            ],
          ),
        );
        await pumpFrames(tester);
        // ⋯ under the reply: a long-press selects text now, and on a narrow
        // English toolbar 「More」 folds into the overflow.
        await tester.tap(find.byTooltip(english ? 'More' : '更多'));
        await tester.pumpAndSettle();
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/message_menu_$suffix.png'));
      });

      testWidgets('a native panel page ($suffix)', (tester) async {
        if (english) useEnglish();
        usePhoneView(tester);
        await tester.pumpWidget(
          app(
            NativePanelPage(
              panel: NativePanel(
                package: 'dsh-go-example-usage',
                id: 'usage',
                title: c.usage,
                icon: 'chart',
                placement: const {'session.tab', 'features'},
                live: true,
              ),
              sessionId: 's1',
            ),
            _bridge(c),
          ),
        );
        await pumpFrames(tester, 10);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/panel_page_$suffix.png'));
      });

      testWidgets('对话详情 › 插件 with one native panel ($suffix)', (tester) async {
        if (english) useEnglish();
        usePhoneView(tester);
        await tester.pumpWidget(
          app(
            const AppBackdrop(
              child: Scaffold(
                backgroundColor: Colors.transparent,
                body: SafeArea(child: SessionPluginsTab(sessionId: 's1')),
              ),
            ),
            _bridge(c),
            inventory: SeatInventory(
              tier: ClientInventoryTier.bridge,
              routeGuard: true,
              webReachable: true,
              occupancy: const {Slots.rightPaneTab: []},
              nativePanels: [
                NativePanel(
                  package: 'dsh-go-example-usage',
                  id: 'usage',
                  title: c.usage,
                  icon: 'chart',
                  placement: const {'session.tab', 'features'},
                  live: true,
                ),
              ],
            ),
            more: [islandBudgetProvider.overrideWithValue(const NoIslandBudget())],
          ),
        );
        await pumpFrames(tester, 10);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/session_tab_$suffix.png'));
      });

      testWidgets('the plugin native settings ($suffix)', (tester) async {
        if (english) useEnglish();
        usePhoneView(tester);
        await tester.pumpWidget(
          app(
            Scaffold(
              body: SafeArea(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                  child: Consumer(
                    builder: (context, ref, _) {
                      ref.watch(nativeContributionsProvider);
                      return const Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          NativePluginSection(package: 'dsh-go-example-quick'),
                          NativePluginSection(package: 'dsh-go-example-usage'),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
            _bridge(c),
          ),
        );
        await pumpFrames(tester);
        final container = ProviderScope.containerOf(tester.element(find.byType(Consumer).first));
        container.read(nativeDiagnosticsProvider.notifier)
          ..view('dsh-go-example-usage', 3277)
          ..invoked('dsh-go-example-usage', const Duration(milliseconds: 48))
          ..report('dsh-go-example-usage', '/runtime/usage', [
            NativeIssue('', nativeIssueText('timeout'), code: 'timeout'),
          ]);
        await pumpFrames(tester);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/settings_$suffix.png'));
      });
    }
  }
}
