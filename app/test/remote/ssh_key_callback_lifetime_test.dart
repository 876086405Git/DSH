import 'dart:async';

import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/state/attachments.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/remote/ssh_host_form.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../clipboard/fake_paste.dart';
import '../shell/golden_harness.dart';

const _host = SshHostConfig(
  id: 'key-callback-test',
  name: 'Test host',
  host: 'example.invalid',
  user: 'test',
  auth: SshAuthMethod.privateKey,
);
const _syntheticKey = '-----BEGIN OPENSSH PRIVATE KEY-----\nsynthetic-only\n-----END OPENSSH PRIVATE KEY-----';

class _PendingPicker implements AttachmentPicker {
  final result = Completer<String?>();
  int calls = 0;

  @override
  Future<String?> pickTextFile({int maxBytes = 64 * 1024}) {
    calls++;
    return result.future;
  }

  @override
  Future<PickedAttachments> pickFiles({int limit = maxAttachments, int heldBytes = 0}) => throw UnimplementedError();
  @override
  Future<List<DraftAttachment>> pickImages({required int limit}) => throw UnimplementedError();
  @override
  Future<DraftAttachment?> takePhoto() => throw UnimplementedError();
}

class _Rig {
  _Rig({this.os});

  final String? os;
  final formVisible = ValueNotifier(true);
  final picker = _PendingPicker();
  final clipboard = Completer<Map<String, dynamic>?>();
  int clipboardCalls = 0;

  Future<void> pump(WidgetTester tester) async {
    usePhoneSurface(tester);
    SharedPreferences.setMockInitialValues({});
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method != 'Clipboard.getData') return null;
      clipboardCalls++;
      return clipboard.future;
    });
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null);
      formVisible.dispose();
    });
    await tester.pumpWidget(
      goldenApp(
        brightness: Brightness.light,
        overrides: [
          if (os != null) operatingSystemProvider.overrideWithValue(os!),
          secretStoreProvider.overrideWithValue(MemorySecretStore()),
          attachmentPickerProvider.overrideWithValue(picker),
        ],
        home: ValueListenableBuilder<bool>(
          valueListenable: formVisible,
          builder: (context, visible, _) =>
              visible ? const SshHostFormPage(existing: _host) : const Scaffold(body: Center(child: Text('next page'))),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, String text) async {
    await tester.ensureVisible(find.text(text));
    await tester.tap(find.text(text));
    await tester.pump();
  }

  Future<void> leave(WidgetTester tester) async {
    formVisible.value = false;
    await tester.pumpAndSettle();
    expect(find.byType(SshHostFormPage), findsNothing);
  }

  String keyText(WidgetTester tester) => tester
      .widget<TextField>(
        find.byWidgetPredicate(
          (widget) => widget is TextField && widget.decoration?.hintText?.startsWith('-----BEGIN') == true,
        ),
      )
      .controller!
      .text;
}

void main() {
  testWidgets('clipboard completion after form disposal is ignored', (tester) async {
    final rig = _Rig();
    await rig.pump(tester);
    await rig.tap(tester, '粘贴');
    expect(rig.clipboardCalls, 1);
    await rig.leave(tester);
    rig.clipboard.complete({'text': '  synthetic-pasted-key  '});
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('next page'), findsOneWidget);
  });

  testWidgets('clipboard completion in the active form still trims and applies', (tester) async {
    final rig = _Rig();
    await rig.pump(tester);
    await rig.tap(tester, '粘贴');
    rig.clipboard.complete({'text': '  synthetic-pasted-key  '});
    await tester.pumpAndSettle();
    expect(rig.keyText(tester), 'synthetic-pasted-key');
    expect(tester.takeException(), isNull);
  });

  group('HarmonyOS, through the system paste button', () {
    Future<_Rig> open(WidgetTester tester) async {
      final rig = _Rig(os: 'ohos');
      await rig.pump(tester);
      return rig;
    }

    testWidgets('the key arrives trimmed with its lines, and Flutter\'s clipboard stays unread', (tester) async {
      final rig = await open(tester);
      FakePaste(tester, reply: FakePaste.text('  -----BEGIN KEY-----\nabc\n-----END KEY-----\n'));
      await rig.tap(tester, '粘贴');
      await tester.pumpAndSettle();
      expect(rig.keyText(tester), '-----BEGIN KEY-----\nabc\n-----END KEY-----');
      expect(rig.clipboardCalls, 0);
    });

    testWidgets('backed out of leaves the key as it was, silently', (tester) async {
      final rig = await open(tester);
      final before = rig.keyText(tester);
      FakePaste(tester, reply: {'status': 'cancelled'});
      await rig.tap(tester, '粘贴');
      await tester.pumpAndSettle();
      expect(rig.keyText(tester), before);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('a busy window says so', (tester) async {
      final rig = await open(tester);
      FakePaste(tester, reply: {'status': 'busy'});
      await rig.tap(tester, '粘贴');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('粘贴窗口尚未结束或仍在关闭，请完成或取消后重试。'), findsOneWidget);
      await tester.pumpAndSettle(const Duration(seconds: 3));
    });

    testWidgets('leaving the form closes the window; the late key goes nowhere', (tester) async {
      final rig = await open(tester);
      final paste = FakePaste(tester, reply: FakePaste.text('late'))..gate = Completer<void>();
      await rig.tap(tester, '粘贴');
      await tester.pump();
      await rig.leave(tester);
      expect(paste.cancels, contains(paste.reads.single));
      paste.gate!.complete();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('next page'), findsOneWidget);
    });
  });

  testWidgets('late file failure does not show a snackbar on the successor page', (tester) async {
    final rig = _Rig();
    await rig.pump(tester);
    await rig.tap(tester, '从文件导入');
    expect(rig.picker.calls, 1);
    await rig.leave(tester);
    rig.picker.result.completeError(const FormatException('synthetic read failure'));
    await tester.pumpAndSettle();
    expect(find.textContaining('synthetic read failure'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('file failure is still explained in the active form', (tester) async {
    final rig = _Rig();
    await rig.pump(tester);
    await rig.tap(tester, '从文件导入');
    rig.picker.result.completeError(const FormatException('synthetic read failure'));
    await tester.pumpAndSettle();
    expect(find.textContaining('synthetic read failure'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('valid file text still reaches the active key field', (tester) async {
    final rig = _Rig();
    await rig.pump(tester);
    await rig.tap(tester, '从文件导入');
    rig.picker.result.complete('  $_syntheticKey  ');
    await tester.pumpAndSettle();
    expect(rig.keyText(tester), _syntheticKey);
    expect(tester.takeException(), isNull);
  });

  testWidgets('successful file completion after form disposal remains ignored', (tester) async {
    final rig = _Rig();
    await rig.pump(tester);
    await rig.tap(tester, '从文件导入');
    await rig.leave(tester);
    rig.picker.result.complete(_syntheticKey);
    await tester.pumpAndSettle();
    expect(find.textContaining('已导入'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
