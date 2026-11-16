// A field's 粘贴: Android reads Flutter's clipboard untouched; HarmonyOS goes through the
// system's paste button, says what came of it once, and lets go when the field goes.

import 'dart:async';

import 'package:dsh_app/ui/common/field_paste.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';
import 'fake_paste.dart';

class _Field extends StatefulWidget {
  const _Field({this.inSheet = false});

  final bool inSheet;

  @override
  State<_Field> createState() => _FieldState();
}

class _FieldState extends State<_Field> with FieldPaste<_Field> {
  String? got;
  String? said;

  Future<String?> read() => readClipboard();
  void giveUp() => cancelPaste();

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: () async {
      final text = await readClipboard(say: widget.inSheet ? (message) => setState(() => said = message) : null);
      if (mounted) setState(() => got = text);
    },
    child: const Text('paste'),
  );
}

void main() {
  Future<_FieldState> pump(WidgetTester tester, {String? os, bool inSheet = false}) async {
    await tester.pumpWidget(
      testApp(
        Scaffold(body: _Field(inSheet: inSheet)),
        overrides: [if (os != null) operatingSystemProvider.overrideWithValue(os)],
      ),
    );
    return tester.state<_FieldState>(find.byType(_Field));
  }

  Future<void> tap(WidgetTester tester) async {
    await tester.tap(find.text('paste'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('Android: Flutter\'s clipboard, as it is, and never the native window', (tester) async {
    final paste = FakePaste(tester, flutterText: '  raw\n');
    final field = await pump(tester, os: 'android');
    await tap(tester);
    expect(field.got, '  raw\n');
    expect(paste.flutterReads, 1);
    expect(paste.reads, isEmpty);
  });

  testWidgets('Android: a clipboard that throws still throws, for the field to meet', (tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => call.method == 'Clipboard.getData' ? throw PlatformException(code: 'x') : null,
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await pump(tester, os: 'android');
    final field = tester.state<_FieldState>(find.byType(_Field));
    await expectLater(field.read(), throwsA(isA<PlatformException>()));
  });

  testWidgets('HarmonyOS: the native window\'s text, as it is, and never Flutter\'s clipboard', (tester) async {
    final paste = FakePaste(tester, reply: FakePaste.text('  raw\n'), flutterText: 'wrong');
    final field = await pump(tester, os: 'ohos');
    await tap(tester);
    expect(field.got, '  raw\n');
    expect(paste.flutterReads, 0);
    expect(paste.reads, hasLength(1));
    expect(paste.cancels, paste.reads, reason: 'the window is closed behind a delivered text');
  });

  const words = {
    'empty': '剪贴板中没有可粘贴的文本。',
    'denied': '系统未授予粘贴权限，请重新点击粘贴按钮。',
    'busy': '粘贴窗口尚未结束或仍在关闭，请完成或取消后重试。',
    'readFailed': '无法读取剪贴板，请重试或手动输入。',
    'unavailable': '无法读取剪贴板，请重试或手动输入。',
  };

  for (final MapEntry(key: status, value: text) in words.entries) {
    testWidgets('HarmonyOS, $status: says what happened, once', (tester) async {
      FakePaste(tester, reply: {'status': status});
      final field = await pump(tester, os: 'ohos');
      await tap(tester);
      expect(field.got, isNull);
      expect(find.text(text), findsOneWidget);
      await tester.pumpAndSettle(const Duration(seconds: 3));
    });

    testWidgets('HarmonyOS, $status: nothing more when the native toast has said it', (tester) async {
      FakePaste(tester, reply: {'status': status, 'shown': true});
      await pump(tester, os: 'ohos');
      await tap(tester);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('HarmonyOS, $status: in a sheet it goes where the field shows it', (tester) async {
      FakePaste(tester, reply: {'status': status});
      final field = await pump(tester, os: 'ohos', inSheet: true);
      await tap(tester);
      expect(field.said, text);
      expect(find.byType(SnackBar), findsNothing);
    });
  }

  testWidgets('HarmonyOS, backed out of: silent', (tester) async {
    FakePaste(tester, reply: {'status': 'cancelled'});
    final field = await pump(tester, os: 'ohos', inSheet: true);
    await tap(tester);
    expect(field.got, isNull);
    expect(field.said, isNull);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('HarmonyOS: a second tap while the window is up opens nothing', (tester) async {
    final paste = FakePaste(tester, reply: FakePaste.text('k'))..gate = Completer<void>();
    final field = await pump(tester, os: 'ohos');
    await tap(tester);
    await tap(tester);
    expect(paste.reads, hasLength(1));
    paste.gate!.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(field.got, 'k');
  });

  testWidgets('HarmonyOS: the field going closes the window, and a late answer is dropped', (tester) async {
    final paste = FakePaste(tester, reply: FakePaste.text('secret'))..gate = Completer<void>();
    final field = await pump(tester, os: 'ohos');
    await tap(tester);
    expect(paste.cancels, isEmpty);
    await tester.pumpWidget(
      testApp(const Scaffold(body: SizedBox()), overrides: [operatingSystemProvider.overrideWithValue('ohos')]),
    );
    await tester.pump();
    expect(paste.cancels, contains(paste.reads.single));
    paste.gate!.complete();
    await tester.pump();
    expect(field.got, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('HarmonyOS: cancelPaste gives up on a read for what has changed', (tester) async {
    final paste = FakePaste(tester, reply: FakePaste.text('secret'))..gate = Completer<void>();
    final field = await pump(tester, os: 'ohos');
    await tap(tester);
    field.giveUp();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(paste.cancels, contains(paste.reads.single));
    expect(field.got, isNull);
    paste.gate!.complete();
    await tester.pump();
    expect(field.got, isNull);
  });
}
