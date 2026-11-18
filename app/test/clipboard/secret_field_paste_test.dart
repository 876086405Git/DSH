// The engine settings' secret sheet: its 粘贴 strips whitespace and clears an error
// on both OSes, and shows a HarmonyOS failure inline, where a sheet doesn't hide it.

import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/ui/engine_settings/field_sheets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';
import 'fake_paste.dart';

void main() {
  Future<void> pump(WidgetTester tester, {String? os}) async {
    usePhoneView(tester);
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: SecretFieldSheet(
            title: 'Key',
            configured: false,
            writable: true,
            onSave: (_) async {},
            onClear: () async {},
          ),
        ),
        overrides: [if (os != null) operatingSystemProvider.overrideWithValue(os)],
      ),
    );
    await tester.pump();
  }

  Future<void> tapPaste(WidgetTester tester) async {
    await tester.tap(find.byTooltip('粘贴'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  String field(WidgetTester tester) => tester.widget<TextField>(find.byType(TextField)).controller!.text;

  testWidgets('Android: Flutter\'s clipboard, without its whitespace', (tester) async {
    final paste = FakePaste(tester, flutterText: ' a b\n');
    await pump(tester, os: 'android');
    await tapPaste(tester);
    expect(field(tester), 'ab');
    expect(paste.reads, isEmpty);
  });

  testWidgets('HarmonyOS: the system paste button, without its whitespace', (tester) async {
    final paste = FakePaste(tester, reply: FakePaste.text(' a b\n'), flutterText: 'wrong');
    await pump(tester, os: 'ohos');
    await tapPaste(tester);
    expect(field(tester), 'ab');
    expect(paste.flutterReads, 0);
  });

  testWidgets('HarmonyOS: a failure shows in the sheet; a paste that works clears it', (tester) async {
    final paste = FakePaste(tester, reply: {'status': 'busy'});
    await pump(tester, os: 'ohos');
    await tapPaste(tester);
    const text = '粘贴窗口尚未结束或仍在关闭，请完成或取消后重试。';
    expect(find.text(text), findsOneWidget);
    expect(field(tester), isEmpty);
    paste.reply = FakePaste.text('ab');
    await tapPaste(tester);
    expect(find.text(text), findsNothing);
    expect(field(tester), 'ab');
  });

  testWidgets('HarmonyOS: backed out of, nothing is said', (tester) async {
    FakePaste(tester, reply: {'status': 'cancelled'});
    await pump(tester, os: 'ohos');
    await tapPaste(tester);
    expect(field(tester), isEmpty);
    expect(find.byType(SnackBar), findsNothing);
  });
}
