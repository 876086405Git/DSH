import 'package:dsh_app/companion/companion_notice_channel.dart';
import 'package:dsh_app/l10n/gen/app_localizations.dart';
import 'package:dsh_app/ui/companion/companion_notices_page.dart';
import 'package:dsh_app/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'companion_notice_triage_test.dart' show FakeCompanionNotices;

/// The native owner as the page sees it: starts off, with one recent app.
class _Notices extends FakeCompanionNotices {
  _Notices() {
    enabled = false;
    levels.clear();
  }

  final enables = <bool>[];
  final apps = <CompanionNoticeApp>[(pkg: 'com.tencent.mm', name: '微信', count: 3, icon: null)];

  @override
  Future<CompanionNoticeStatus> setEnabled(bool value) {
    enables.add(value);
    return super.setEnabled(value);
  }

  @override
  Future<List<CompanionNoticeApp>> recentApps() async => enabled && granted ? apps : [];
}

void main() {
  Future<void> pump(WidgetTester tester, _Notices notices) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [companionNoticesProvider.overrideWithValue(notices)],
        child: MaterialApp(
          theme: buildDarkTheme(),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          locale: const Locale('zh'),
          home: const CompanionNoticesPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('turning it on asks the listener, and asks for the grant while it is missing', (tester) async {
    final notices = _Notices()..granted = false;
    await pump(tester, notices);
    expect(find.text('开启后收到过通知的 App 会出现在这里'), findsOneWidget);
    expect(find.text('还差一步：允许 DSH Go 读取通知'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('notices-switch')));
    await tester.pumpAndSettle();
    expect(notices.enables, [true]);
    expect(find.text('还差一步：允许 DSH Go 读取通知'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('notices-allow')));
    await tester.pumpAndSettle();
    expect(notices.enables, [true, true]);

    // Back from the system page with the grant: the page reads it again.
    notices.granted = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('还差一步：允许 DSH Go 读取通知'), findsNothing);
    expect(find.text('微信'), findsOneWidget);
  });

  testWidgets('choosing a level for an app sends it to the listener', (tester) async {
    final notices = _Notices()
      ..enabled = true
      ..received = 5
      ..said = 1;
    await pump(tester, notices);
    expect(find.text('今天收到 5 条 · 她说了 1 次'), findsOneWidget);
    expect(find.text('不看'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('notice-app-com.tencent.mm')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('notice-level-remember')));
    await tester.pumpAndSettle();

    expect(notices.levels, {'com.tencent.mm': CompanionNoticeLevel.remember});
    expect(find.text('会记住'), findsOneWidget);
  });
}
