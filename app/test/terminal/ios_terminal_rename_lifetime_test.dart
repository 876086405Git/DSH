import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

void main() {
  for (final save in [false, true]) {
    testWidgets('iOS remote-capability terminal rename ${save ? 'save' : 'cancel'} route lifecycle', (tester) async {
      final old = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      SharedPreferences.setMockInitialValues({});
      final backend = FakeTerminalBackend(terminals: [infoJson('a', title: 'Original terminal')]);
      try {
        await pumpTerminalPage(tester, backend);
        expect(defaultTargetPlatform, TargetPlatform.iOS);
        await tester.longPress(find.byKey(const ValueKey('terminal-tab-a')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('重命名'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        final controller = tester.widget<TextField>(find.byType(TextField)).controller!;
        await tester.enterText(find.byType(TextField), '  新终端  ');
        await tester.tap(find.text(save ? '保存' : '取消'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(backend.host['a']!['title'], save ? '新终端' : 'Original terminal');
        expect(() => controller.addListener(() {}), throwsFlutterError);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        debugDefaultTargetPlatformOverride = old;
      }
    });
  }
}
