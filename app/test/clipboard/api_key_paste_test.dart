// The key page's 粘贴 is the first thing a person does on a phone, and on a plain HarmonyOS
// package Flutter's clipboard comes back empty, through a fake `dsh/paste` here.

import 'dart:async';

import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/onboarding/api_key_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart';
import 'fake_paste.dart';

void main() {
  Future<void> pump(WidgetTester tester, {String? os}) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        home: const ApiKeyPage(onboarding: false),
        brightness: Brightness.light,
        overrides: [
          if (os != null) operatingSystemProvider.overrideWithValue(os),
          settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
        ],
      ),
    );
    await tester.pump();
  }

  Future<void> tapPaste(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(TextButton, '粘贴'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  TextEditingValue value(WidgetTester tester) => tester.widget<TextField>(find.byType(TextField)).controller!.value;

  testWidgets('Android: Flutter\'s clipboard, spaces gone, cursor at the end', (tester) async {
    final paste = FakePaste(tester, flutterText: ' sk-a b\n');
    await pump(tester, os: 'android');
    await tapPaste(tester);
    expect(value(tester).text, 'sk-ab');
    expect(value(tester).selection, const TextSelection.collapsed(offset: 5));
    expect(paste.flutterReads, 1);
    expect(paste.reads, isEmpty);
  });

  testWidgets('Android: nothing on the clipboard, nothing happens', (tester) async {
    final paste = FakePaste(tester);
    await pump(tester, os: 'android');
    await tapPaste(tester);
    expect(value(tester).text, isEmpty);
    expect(paste.flutterReads, 1);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('HarmonyOS: the system paste button\'s text, spaces gone, cursor at the end', (tester) async {
    final paste = FakePaste(tester, reply: FakePaste.text(' sk-a b\n'), flutterText: 'wrong');
    await pump(tester, os: 'ohos');
    await tapPaste(tester);
    expect(value(tester).text, 'sk-ab');
    expect(value(tester).selection, const TextSelection.collapsed(offset: 5));
    expect(paste.flutterReads, 0);
    expect(paste.reads, hasLength(1));
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('HarmonyOS: only blank on the clipboard leaves the field empty', (tester) async {
    FakePaste(tester, reply: FakePaste.text(' \n'));
    await pump(tester, os: 'ohos');
    await tapPaste(tester);
    expect(value(tester).text, isEmpty);
  });

  testWidgets('HarmonyOS: backed out of, nothing happens and nothing is said', (tester) async {
    FakePaste(tester, reply: {'status': 'cancelled'});
    await pump(tester, os: 'ohos');
    await tapPaste(tester);
    expect(value(tester).text, isEmpty);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('HarmonyOS: refused with the native toast up, no second notice', (tester) async {
    FakePaste(tester, reply: {'status': 'denied', 'shown': true});
    await pump(tester, os: 'ohos');
    await tapPaste(tester);
    expect(value(tester).text, isEmpty);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('HarmonyOS: no window to show one in, the page says it', (tester) async {
    FakePaste(tester, reply: {'status': 'unavailable'});
    await pump(tester, os: 'ohos');
    await tapPaste(tester);
    expect(value(tester).text, isEmpty);
    expect(find.text('无法读取剪贴板，请重试或手动输入。'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 3));
  });

  testWidgets('HarmonyOS: leaving the page closes the window, and the late text goes nowhere', (tester) async {
    final paste = FakePaste(tester, reply: FakePaste.text('sk-late'))..gate = Completer<void>();
    await pump(tester, os: 'ohos');
    await tapPaste(tester);
    await tester.pumpWidget(
      goldenApp(
        home: const SizedBox(),
        brightness: Brightness.light,
        overrides: [
          operatingSystemProvider.overrideWithValue('ohos'),
          settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
        ],
      ),
    );
    await tester.pump();
    expect(paste.cancels, contains(paste.reads.single));
    paste.gate!.complete();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
