import 'package:dsh_app/tavern/tavern_preview.dart';
import 'package:dsh_app/tavern/tavern_provider.dart';
import 'package:dsh_app/ui/tavern/tavern_backup.dart';
import 'package:dsh_app/ui/tavern/tavern_home_page.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_fonts.dart';

/// The preview, holding a DeepSeek export of three conversations (one of them
/// here already) and recording what is asked to be taken in.
class _Moving extends PreviewTavern {
  _Moving() : super(tick: Duration.zero);

  String? inspected;
  List<String>? taken;

  @override
  Future<List<TavernDeepSeekSession>> inspectDeepSeekExport(String zipPath) async {
    inspected = zipPath;
    return const [
      TavernDeepSeekSession(id: 'long', title: '小满', messageCount: 4200),
      TavernDeepSeekSession(
        id: 'here',
        title: '旧的',
        messageCount: 900,
        imported: TavernDeepSeekImported(sessionId: 'here', characterId: 'c', chatId: 'k'),
      ),
      TavernDeepSeekSession(id: 'short', title: '', messageCount: 12),
    ];
  }

  @override
  Future<List<TavernDeepSeekImported>> importDeepSeekSessions(String zipPath, List<String> sessionIds) async {
    taken = sessionIds;
    return const [];
  }
}

void main() {
  testWidgets('导入 › 从 DeepSeek 接回来 ticks the longest conversation and takes in what is ticked', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844) * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final tavern = _Moving();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tavernProvider.overrideWith((ref) => tavern),
          tavernBackupPickerProvider.overrideWithValue(() async => '/downloads/deepseek_data.zip'),
        ],
        child: MaterialApp(
          theme: withTestFonts(buildLightTheme()),
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: const TavernHomePage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tavern-import')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tavern-import-deepseek')));
    await tester.pumpAndSettle();

    expect(tavern.inspected, '/downloads/deepseek_data.zip');
    // The longest is ticked from the start; one tap would bring it over.
    expect(find.text('接回来（1）'), findsOneWidget);
    expect(find.text('已经接回来了，点开继续'), findsOneWidget);
    expect(find.text('没有标题的对话'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('tavern-deepseek-short')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('接回来（2）'));
    await tester.pumpAndSettle();
    expect(tavern.taken, ['long', 'short']);
  });
}
