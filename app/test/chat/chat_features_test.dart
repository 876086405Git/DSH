// Tool-group summaries, change cards + diff page, slash palette, usage sheet,
// balance banner and the empty model catalog: behaviour tests and goldens
// (light + dark). Regenerate with
// `flutter test --update-goldens test/chat/chat_features_test.dart`.

import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/ui/common/app_sheet.dart';
import 'package:dsh_app/state/balance_state.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/state/usage_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/diff_page.dart';
import 'package:dsh_app/ui/chat/empty_state.dart';
import 'package:dsh_app/ui/chat/slash_palette.dart';
import 'package:dsh_app/ui/chat/turn_summary.dart';
import 'package:dsh_app/ui/chat/usage_sheet.dart';
import 'package:dsh_app/ui/chat/widgets/change_card.dart';
import 'package:dsh_app/ui/chat/widgets/command_row.dart';
import 'package:dsh_app/ui/chat/widgets/tool_row.dart';
import 'package:dsh_app/ui/chat/widgets/turn_process.dart';
import 'package:dsh_app/ui/chat/widgets/whale_tail.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:dsh_app/ui/chat/model_sheet.dart' show ModelChip;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';
import 'support/sample_chat.dart';

ChatTranscript _fixture() {
  final transcript = ChatTranscript();
  for (final line in File('test/chat/fixtures/follow_file_changes.jsonl').readAsLinesSync()) {
    if (line.trim().isEmpty) continue;
    transcript.apply(parseFollowFrame('s1', jsonDecode(line)));
  }
  return transcript;
}

const _compact = CommandNotice(
  id: 'cmd-1',
  name: 'compact',
  seq: 21,
  done: true,
  text: 'Compacted 9 history items (~34000 tokens).',
);

/// The synthetic file-editing session as the chat controller would publish it.
ChatState fileChangesState() {
  final t = _fixture();
  return ChatState(
    items: t.items,
    running: false,
    title: '修复登录重复提交',
    loading: false,
    turns: t.turns,
    commands: const [_compact],
    model: const ModelSelection(provider: 'deepseek-official', model: 'deepseek-v4-pro', reasoningEffort: 'high'),
  );
}

const _usage = SessionUsage(
  uncachedInput: 18240,
  cacheRead: 52736,
  cacheWrite: 0,
  output: 3410,
  pressureTokens: 61800,
  projectedTokens: 62100,
  contextWindow: 1000000,
  systemTokens: 1467,
  toolsTokens: 5157,
  messageTokens: 54876,
  turns: 2,
);

Future<void> _noRespond(ApprovalRequest r, ApprovalDecision d) async {}

Future<void> pumpChat(
  WidgetTester tester,
  ChatHarness harness, {
  Brightness brightness = Brightness.light,
  int frames = 8,
}) async {
  usePhoneView(tester);
  mockClipboard(tester);
  await tester.pumpWidget(testApp(const ChatScreen(), brightness: brightness, overrides: harness.overrides));
  await pumpFrames(tester, frames);
}

ChatHarness _changesHarness({BalanceResult balance = healthyBalance}) =>
    ChatHarness(session: 's1', states: {'s1': fileChangesState()}, usage: const {'s1': _usage}, balance: balance);

Widget _featureSheet(List<FileChange> turnOne) {
  final t = _fixture();
  final tools = t.items.whereType<ToolChatItem>().toList();
  final many = [
    for (final (i, name) in [
      'lib/main.dart',
      'lib/app.dart',
      'lib/ui/home.dart',
      'lib/ui/settings.dart',
      'test/home_test.dart',
      'pubspec.yaml',
      'README.md',
    ].indexed)
      FileChange(
        path: '/root/workspace/$name',
        created: i == 4,
        added: 3 + i * 2,
        removed: i.isEven ? i : 0,
        lines: const [],
        edits: 1,
      ),
  ];
  return Builder(
    builder: (context) => AppBackdrop(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 40, 16, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ToolGroup(tools: tools.take(6).toList(), onRespond: _noRespond),
            const SizedBox(height: 8),
            ToolGroup(
              key: const ValueKey('expand-me'),
              tools: [
                tools[0],
                tools[1],
                tool('x', 'web_search', {'query': 'flutter double submit'}),
                tools.last, // the failed CHANGELOG edit
              ],
              onRespond: _noRespond,
            ),
            const SizedBox(height: 16),
            ChangeCard(files: turnOne),
            const SizedBox(height: 12),
            ChangeCard(files: many),
            const SizedBox(height: 16),
            const CommandRow(notice: _compact),
            const SizedBox(height: 8),
            const CommandRow(
              notice: CommandNotice(id: 'local-1', name: 'permission', args: ' read-only'),
            ),
            const SizedBox(height: 8),
            const CommandRow(
              notice: CommandNotice(
                id: 'cmd-2',
                name: 'feedback',
                seq: 30,
                done: true,
                success: false,
                text: 'Feedback text is required. Usage: /feedback <text>',
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

void main() {
  setUpAll(() async {
    await loadTestFonts();
    await WhaleSprites.load();
    chatClock = () => DateTime(2026, 10, 23, 15, 20);
  });

  group('behaviour', () {
    testWidgets('a finished turn ends with its change card', (tester) async {
      await pumpChat(tester, _changesHarness());
      // The latest turn sits right above the composer, its card last.
      expect(find.text('改动了 1 个文件'), findsOneWidget);
      final card = tester.getRect(find.text('改动了 1 个文件'));
      final answer = tester.getRect(find.textContaining('加好了'));
      expect(card.top, greaterThan(answer.bottom));
    });

    testWidgets('change card → diff page → copy path', (tester) async {
      tester.view.physicalSize = const Size(780, 3600);
      final copied = <String>[];
      await pumpChat(tester, _changesHarness());
      tester.view.physicalSize = const Size(780, 3600);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      });
      await pumpFrames(tester);
      // Finished turns fold their process; the cards stay outside.
      final folds = find.byType(TurnProcess).evaluate().length;
      expect(folds, greaterThan(0));
      for (var i = 0; i < folds; i++) {
        await tester.tap(find.byType(TurnProcess).at(i));
        await pumpFrames(tester);
      }
      expect(find.text('执行 1 条命令 · 改了 2 个文件 · 读了 1 个文件 · 搜索 1 次'), findsOneWidget);
      expect(find.text('改动了 2 个文件'), findsOneWidget);
      expect(find.text('/compact'), findsOneWidget);

      await tester.tap(
        find.descendant(of: find.byType(ChangeCard).first, matching: find.textContaining('login_controller.dart')),
      );
      await pumpFrames(tester);
      expect(find.byType(ChangeDiffPage), findsOneWidget);
      expect(find.text('修改 2 次'), findsOneWidget);
      await tester.tap(find.text('复制路径'));
      await pumpFrames(tester, 2);
      expect(copied, ['/root/workspace/app/lib/auth/login_controller.dart']);
      expect(find.text('已复制路径'), findsOneWidget);
    });

    testWidgets('diff page with animations off: another file is a jump, not a zero-length scroll (#798)', (
      tester,
    ) async {
      usePhoneView(tester);
      final files = turnChanges(_fixture().items).first.files;
      expect(files.length, greaterThan(1));
      await tester.pumpWidget(
        testApp(
          Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: ChangeDiffPage(files: files),
            ),
          ),
        ),
      );
      await pumpFrames(tester);
      await tester.tap(find.descendant(of: find.byType(ListView), matching: find.text(files[1].fileName)).first);
      await pumpFrames(tester);
      expect(tester.takeException(), isNull);
      expect(tester.widget<PageView>(find.byType(PageView)).controller!.page, 1);
    });

    testWidgets('tool group summary expands to the individual rows', (tester) async {
      usePhoneView(tester);
      final tools = _fixture().items.whereType<ToolChatItem>().take(6).toList();
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: ToolGroup(tools: tools, onRespond: _noRespond),
          ),
        ),
      );
      expect(find.byType(ToolRow), findsNothing);
      await tester.tap(find.text('执行 1 条命令 · 改了 2 个文件 · 读了 1 个文件 · 搜索 1 次'));
      await pumpFrames(tester, 4);
      expect(find.byType(ToolRow), findsNWidgets(6));
    });

    testWidgets('slash palette filters, runs, inserts and hints', (tester) async {
      final harness = _changesHarness();
      await pumpChat(tester, harness);
      final field = find.byType(TextField);

      await tester.enterText(field, '/');
      await pumpFrames(tester, 3);
      expect(find.byType(SlashPalette), findsOneWidget);
      expect(find.text('/compact'), findsWidgets);
      expect(find.text('/export'), findsNothing);

      await tester.enterText(field, '/comp');
      await pumpFrames(tester, 3);
      final palette = find.byType(SlashPalette);
      expect(find.descendant(of: palette, matching: find.textContaining('/permission')), findsNothing);
      await tester.tap(find.descendant(of: palette, matching: find.textContaining('/compact')).first);
      await pumpFrames(tester, 3);
      final chat = harness.controllers['s1']!;
      expect(chat.commandLines, ['/compact']);
      expect(tester.widget<TextField>(field).controller!.text, isEmpty);

      // A command with input fills the composer and closes the palette.
      await tester.enterText(field, '/权');
      await pumpFrames(tester, 3);
      await tester.tap(find.textContaining('/permission').first);
      await pumpFrames(tester, 3);
      expect(tester.widget<TextField>(field).controller!.text, '/permission ');
      expect(find.byType(SlashPalette), findsNothing);

      await tester.enterText(field, '/permission read-only');
      await tester.tap(find.byIcon(AppIcons.send));
      await pumpFrames(tester, 3);
      expect(chat.commandLines, ['/compact', '/permission read-only']);
      expect(chat.sent, isEmpty, reason: 'commands never become prompts');

      // Unknown name with input: a normal message (a path, for example).
      await tester.enterText(field, '/sdcard/notes.txt 总结一下');
      await pumpFrames(tester, 2);
      expect(find.byType(SlashPalette), findsNothing);
      await tester.tap(find.byIcon(AppIcons.send));
      await pumpFrames(tester, 2);
      expect(chat.sent, ['/sdcard/notes.txt 总结一下']);
    });

    testWidgets('inserting a leading slash opens the palette and keeps the existing draft', (tester) async {
      final harness = _changesHarness();
      await pumpChat(tester, harness);
      final field = find.byType(TextField);
      final controller = tester.widget<TextField>(field).controller!;
      controller.value = const TextEditingValue(text: '/已有文字', selection: TextSelection.collapsed(offset: 1));
      await pumpFrames(tester, 3);
      final palette = find.byType(SlashPalette);
      expect(palette, findsOneWidget);
      await tester.tap(find.descendant(of: palette, matching: find.textContaining('/permission')).first);
      await pumpFrames(tester, 3);
      expect(controller.text, '/permission 已有文字');
      expect(harness.controllers['s1']!.commandLines, isEmpty);
      expect(harness.controllers['s1']!.sent, isEmpty);

      // A command that normally runs immediately must also retain the draft
      // until the user explicitly sends it. Start a fresh draft for this case.
      controller.clear();
      controller.value = const TextEditingValue(text: '  /已有文字', selection: TextSelection.collapsed(offset: 3));
      await pumpFrames(tester, 3);
      await tester.tap(find.descendant(of: palette, matching: find.textContaining('/compact')).first);
      await pumpFrames(tester, 3);
      expect(controller.text, '  /compact 已有文字');
      expect(harness.controllers['s1']!.commandLines, isEmpty);

      // Completing inside a known name replaces it without duplicating its
      // unselected suffix or discarding the arguments.
      controller.clear();
      controller.value = const TextEditingValue(
        text: '/permission read-only',
        selection: TextSelection.collapsed(offset: 4),
      );
      await pumpFrames(tester, 3);
      await tester.tap(find.descendant(of: palette, matching: find.textContaining('/permission')).first);
      await pumpFrames(tester, 3);
      expect(controller.text, '/permission read-only');

      controller.value = const TextEditingValue(text: 'hello /', selection: TextSelection.collapsed(offset: 7));
      await pumpFrames(tester, 3);
      expect(palette, findsNothing);

      // Sending still resolves the complete command line, independent of
      // where the cursor was left while editing it.
      controller.value = const TextEditingValue(text: '/comp', selection: TextSelection.collapsed(offset: 0));
      await tester.tap(find.byIcon(AppIcons.send));
      await pumpFrames(tester, 3);
      expect(harness.controllers['s1']!.commandLines, ['/compact']);
      expect(controller.text, isEmpty);
    });

    testWidgets('/model opens the model sheet, /new starts a new chat', (tester) async {
      final harness = _changesHarness();
      await pumpChat(tester, harness);
      final field = find.byType(TextField);

      await tester.enterText(field, '/model');
      await tester.pump();
      await tester.tap(find.byIcon(AppIcons.send));
      await pumpFrames(tester, 6);
      expect(find.text('选择模型'), findsOneWidget);
      await tester.tap(find.byType(SheetDragHandle));
      await pumpFrames(tester, 6);

      await tester.enterText(field, '/新');
      await tester.pump();
      await tester.tap(find.byIcon(AppIcons.send));
      await pumpFrames(tester, 6);
      final container = ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
      expect(container.read(currentSessionProvider), isNull);
      expect(find.byType(ChatEmptyState), findsOneWidget);
    });

    testWidgets('a command in a new chat creates the session first', (tester) async {
      final harness = ChatHarness(created: 'fresh');
      await pumpChat(tester, harness);
      await tester.enterText(find.byType(TextField), '/compact');
      await tester.pump();
      await tester.tap(find.byIcon(AppIcons.send));
      await pumpFrames(tester, 4);
      expect(harness.sessions.creates, 1);
      expect(harness.controllers['fresh']!.commandLines, ['/compact']);
    });

    testWidgets('context ring opens the usage sheet with the balance', (tester) async {
      final harness = _changesHarness();
      await pumpChat(tester, harness);
      expect(find.descendant(of: find.byType(ContextRing), matching: find.text('6%')), findsOneWidget);
      await tester.tap(find.byType(ContextRing));
      await pumpFrames(tester, 8);
      expect(find.text('用量'), findsOneWidget);
      expect(find.text('6%'), findsNWidgets(2)); // the ring and the sheet
      expect(find.text('71K'), findsOneWidget); // input incl. cache
      expect(find.text('74%'), findsOneWidget); // cache hit rate
      expect(find.text('¥110.00'), findsOneWidget);
      expect(harness.balanceRequests, [testKey], reason: 'throttled');
    });

    testWidgets('low balance banner: top-up link and dismiss', (tester) async {
      final harness = _changesHarness(balance: lowBalance);
      await pumpChat(tester, harness);
      expect(find.textContaining('余额仅剩 ¥3.20'), findsOneWidget);
      expect(find.text('去充值'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭').last);
      await pumpFrames(tester, 4);
      expect(find.textContaining('余额仅剩 ¥3.20'), findsNothing);
    });

    testWidgets('empty catalog asks for an API key', (tester) async {
      final harness = ChatHarness(
        settings: const AppSettings(loaded: true),
        catalog: ModelCatalog.fromJson(const {'groups': <Object?>[]}),
      );
      await pumpChat(tester, harness);
      // The new chat's header chip (and the composer's, once typing) asks for one.
      expect(find.descendant(of: find.byType(ModelChip), matching: find.text('选择模型')), findsOneWidget);
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byKey(const ValueKey('composer-model')));
      await pumpFrames(tester, 8);
      expect(find.text('需要 API Key'), findsOneWidget);
      expect(find.text('填写 API Key'), findsOneWidget);
      expect(harness.balanceRequests, isEmpty);
    });
  });

  for (final brightness in Brightness.values) {
    final suffix = brightness == Brightness.dark ? 'dark' : 'light';

    group('goldens ($suffix)', () {
      testWidgets('feature sheet', (tester) async {
        usePhoneView(tester);
        tester.view.physicalSize = const Size(780, 2400);
        final files = turnChanges(_fixture().items).first.files;
        await tester.pumpWidget(testApp(Scaffold(body: _featureSheet(files)), brightness: brightness));
        await tester.tap(
          find.descendant(of: find.byKey(const ValueKey('expand-me')), matching: find.byType(InkWell)).first,
        );
        await pumpFrames(tester, 6);
        await expectLater(find.byType(Scaffold), matchesGoldenFile('goldens/features_$suffix.png'));
      });

      testWidgets('conversation with change cards', (tester) async {
        usePhoneView(tester);
        tester.view.physicalSize = const Size(780, 3400);
        await pumpChat(tester, _changesHarness(), brightness: brightness);
        tester.view.physicalSize = const Size(780, 3400);
        await pumpFrames(tester, 10);
        await expectLater(find.byType(ChatScreen), matchesGoldenFile('goldens/changes_$suffix.png'));
      });

      testWidgets('diff page', (tester) async {
        usePhoneView(tester);
        final files = turnChanges(_fixture().items).first.files;
        await tester.pumpWidget(testApp(ChangeDiffPage(files: files, initialIndex: 1), brightness: brightness));
        await pumpFrames(tester, 4);
        await expectLater(find.byType(ChangeDiffPage), matchesGoldenFile('goldens/diff_page_$suffix.png'));
      });

      testWidgets('slash palette', (tester) async {
        await pumpChat(tester, _changesHarness(), brightness: brightness);
        await tester.enterText(find.byType(TextField), '/');
        await pumpFrames(tester, 6);
        await expectLater(find.byType(ChatScreen), matchesGoldenFile('goldens/slash_palette_$suffix.png'));
      });

      testWidgets('usage sheet with balance', (tester) async {
        await pumpChat(tester, _changesHarness(), brightness: brightness);
        await tester.tap(find.byType(ContextRing));
        await pumpFrames(tester, 10);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/usage_sheet_$suffix.png'));
      });

      testWidgets('low balance banner', (tester) async {
        await pumpChat(tester, _changesHarness(balance: lowBalance), brightness: brightness);
        await expectLater(find.byType(ChatScreen), matchesGoldenFile('goldens/low_balance_$suffix.png'));
      });

      testWidgets('model sheet', (tester) async {
        await pumpChat(tester, ChatHarness(), brightness: brightness);
        await tester.tap(find.byType(TextField));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        await tester.tap(find.byKey(const ValueKey('composer-model')));
        await pumpFrames(tester, 10);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/model_sheet_$suffix.png'));
      });

      testWidgets('model sheet without a key', (tester) async {
        await pumpChat(
          tester,
          ChatHarness(
            settings: const AppSettings(loaded: true),
            catalog: ModelCatalog.fromJson(const {'groups': <Object?>[]}),
          ),
          brightness: brightness,
        );
        await tester.tap(find.byType(TextField));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        await tester.tap(find.byKey(const ValueKey('composer-model')));
        await pumpFrames(tester, 10);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/model_empty_$suffix.png'));
      });
    });
  }
}
