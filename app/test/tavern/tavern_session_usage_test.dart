import 'package:dsh_app/tavern/tavern_preview.dart';
import 'package:dsh_app/tavern/tavern_provider.dart';
import 'package:dsh_app/tavern/tavern_session_usage.dart';
import 'package:dsh_app/ui/tavern/tavern_stage_panel.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_fonts.dart';

/// The preview, its chat a long line of [replies] exchanges handed out a
/// page at a time as the engine does; each reply reports 1000 in (400 from
/// the cache) and 100 out, except every tenth, which reports nothing.
class _LongChat extends PreviewTavern {
  _LongChat(int replies, {String? model}) : super(tick: Duration.zero) {
    for (var i = 0; i < replies; i++) {
      line
        ..add(TavernMessage(nodeId: 'u$i', role: TavernRole.user, speaker: 'User', text: '问$i', at: DateTime(2026)))
        ..add(
          TavernMessage(
            nodeId: 'c$i',
            role: TavernRole.character,
            speaker: '林晚',
            text: '答$i',
            at: DateTime(2026),
            reportedUsage: i % 10 == 9
                ? null
                : TavernUsage(promptTokens: 1000, cacheHitTokens: 400, completionTokens: 100, model: model),
          ),
        );
    }
  }

  final line = <TavernMessage>[];
  var pages = 0;

  @override
  Future<List<TavernMessage>> path(String chatId, {int limit = 60, String? beforeNodeId}) async {
    pages++;
    final end = beforeNodeId == null ? line.length : line.indexWhere((m) => m.nodeId == beforeNodeId);
    return line.sublist((end - limit).clamp(0, end), end);
  }
}

void main() {
  test('a token count at a glance', () {
    expect(tavernTokenCount(8421, zh: true), '8421');
    expect(tavernTokenCount(12345, zh: true), '1.2万');
    expect(tavernTokenCount(1234567, zh: true), '123万');
    expect(tavernTokenCount(12345, zh: false), '12.3k');
    expect(tavernTokenCount(123456, zh: false), '123k');
    expect(tavernTokenCount(2500000, zh: false), '2.5M');
  });

  test("the engine's sum of the line: its replies' usage added up", () async {
    final tavern = _LongChat(150); // 300 messages: two pages of 200
    final usage = await tavernSessionUsage(tavern, 'chat');
    expect(tavern.pages, 2);
    expect(usage.replies, 135); // every tenth reports nothing
    expect((usage.prompt, usage.cacheHit, usage.completion), (135000, 54000, 13500));

    final empty = await tavernSessionUsage(_LongChat(0), 'chat');
    expect(empty.replies, 0);
  });

  test("DeepSeek's prices by the model a reply names; others are not guessed at", () {
    expect(tavernModelPrice('deepseek-flash'), tavernDeepSeekFlash);
    expect(tavernModelPrice('deepseek-v4-flash'), tavernDeepSeekFlash);
    expect(tavernModelPrice('DeepSeek-V4.1-Flash-1017'), tavernDeepSeekFlash);
    expect(tavernModelPrice('deepseek-v4-pro'), tavernDeepSeekPro);
    expect(tavernModelPrice('deepseek-chat'), isNull);
    expect(tavernModelPrice('gpt-4o'), isNull);
    expect(tavernModelPrice(null), isNull);
  });

  test('peak hours are weekdays 01–04 and 06–10 UTC; the rest costs half', () {
    // 2026-11-12 is a Thursday, 2026-11-14 a Saturday.
    expect(tavernDeepSeekPeak(DateTime.utc(2026, 11, 12, 1)), isTrue);
    expect(tavernDeepSeekPeak(DateTime.utc(2026, 11, 12, 3, 59)), isTrue);
    expect(tavernDeepSeekPeak(DateTime.utc(2026, 11, 12, 4)), isFalse);
    expect(tavernDeepSeekPeak(DateTime.utc(2026, 11, 12, 9, 59)), isTrue);
    expect(tavernDeepSeekPeak(DateTime.utc(2026, 11, 12, 10)), isFalse);
    expect(tavernDeepSeekPeak(DateTime.utc(2026, 11, 12, 0, 59)), isFalse);
    expect(tavernDeepSeekPeak(DateTime.utc(2026, 11, 14, 2)), isFalse);

    // 400 from the cache, 600 not, 100 out, on flash.
    const usage = TavernUsage(promptTokens: 1000, cacheHitTokens: 400, completionTokens: 100);
    expect(tavernReplyCost(usage, tavernDeepSeekFlash, DateTime.utc(2026, 11, 12, 2)), closeTo(0.0003024, 1e-12));
    expect(tavernReplyCost(usage, tavernDeepSeekFlash, DateTime.utc(2026, 11, 12, 12)), closeTo(0.0001512, 1e-12));
    expect(tavernUsd(0.020412), '0.0204');
    expect(tavernUsd(3.456), '3.46');
  });

  test("the line's cost: priced replies added up, the rest counted apart", () async {
    final usage = await tavernSessionUsage(_LongChat(20, model: 'deepseek-flash'), 'chat');
    expect(usage.unpriced, 0);
    final at = DateTime(2026);
    expect(
      usage.cost,
      closeTo(
        18 *
            tavernReplyCost(
              const TavernUsage(promptTokens: 1000, cacheHitTokens: 400, completionTokens: 100),
              tavernDeepSeekFlash,
              at,
            ),
        1e-12,
      ),
    );
    expect((await tavernSessionUsage(_LongChat(20), 'chat')).unpriced, 18);
  });

  testWidgets('本局 opens with what the chat took so far', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844) * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [tavernProvider.overrideWith((ref) => _LongChat(150))],
        child: MaterialApp(
          theme: withTestFonts(buildLightTheme()),
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: const Scaffold(
            body: TavernStagePanel(chatId: 'chat', name: '林晚'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final usage = find.byKey(const ValueKey('tavern-session-usage'));
    expect(usage, findsOneWidget);
    for (final text in ['本局用量', '13.5万', '40%', '1.4万']) {
      expect(
        find.descendant(of: usage, matching: find.text(text)),
        findsOneWidget,
        reason: text,
      );
    }
    expect(find.descendant(of: usage, matching: find.textContaining('当前分支 135 条回复')), findsOneWidget);
  });

  testWidgets('本局 says about what the line cost, and says which replies it could not price', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844) * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    Future<void> open(PreviewTavern tavern) async {
      await tester.pumpWidget(
        ProviderScope(
          key: UniqueKey(),
          overrides: [tavernProvider.overrideWith((ref) => tavern)],
          child: MaterialApp(
            theme: withTestFonts(buildLightTheme()),
            locale: const Locale('zh', 'CN'),
            supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: const Scaffold(
              body: TavernStagePanel(chatId: 'chat', name: '林晚'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await open(_LongChat(150, model: 'deepseek-flash'));
    final cost = tester.widget<Text>(find.byKey(const ValueKey('tavern-session-cost'))).data!;
    expect(cost, startsWith('约 US'));
    expect(find.textContaining('不在价目表里'), findsNothing);

    await open(_LongChat(150));
    expect(find.byKey(const ValueKey('tavern-session-cost')), findsNothing);
    expect(find.textContaining('135 条回复用的模型不在价目表里'), findsOneWidget);
  });
}
