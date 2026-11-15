import 'dart:async';

import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/state/ui_mode_state.dart';
import 'package:dsh_app/ui/common/discard_guard.dart';
import 'package:dsh_app/ui/web/web_home.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';

Future<ProviderContainer> pumpEntry(WidgetTester tester, String os) async {
  SharedPreferences.setMockInitialValues({});
  usePhoneView(tester);
  for (final name in ['dsh/shortcuts', 'dsh/share']) {
    final channel = MethodChannel(name);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) async => true);
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
  }
  await tester.pumpWidget(
    testApp(
      const Scaffold(body: WebEntryHost()),
      overrides: [...ChatHarness().overrides, operatingSystemProvider.overrideWithValue(os)],
    ),
  );
  await pumpFrames(tester);
  return ProviderScope.containerOf(tester.element(find.byType(WebEntryHost)));
}

Future<void> sendEntry(WidgetTester tester, Map<String, Object?> entry) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'dsh/shortcuts',
    const StandardMethodCodec().encodeMethodCall(MethodCall('entry', entry)),
    (_) {},
  );
  await pumpFrames(tester);
}

Future<void> unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  testWidgets('iOS Ask text reaches the web composer through the launcher bridge', (tester) async {
    final container = await pumpEntry(tester, 'ios');
    const text = '请整理今天的安排\nKeep this paragraph.';
    await sendEntry(tester, {'kind': 'new', 'text': text});
    final request = container.read(webOpenProvider);
    final observed = (request?.target.newSession, request?.compose?.text);
    await unmount(tester);
    expect(observed, (true, text));
  });

  testWidgets('iOS empty new-chat shortcut still opens without a compose payload', (tester) async {
    final container = await pumpEntry(tester, 'ios');
    await sendEntry(tester, {'kind': 'new'});
    final request = container.read(webOpenProvider);
    final observed = (request?.target.newSession, request?.compose);
    await unmount(tester);
    expect(observed, (true, null));
  });

  testWidgets('iOS Ask text respects keeping an unsaved editing page', (tester) async {
    final container = await pumpEntry(tester, 'ios');
    final dirty = ValueNotifier(0);
    unawaited(
      Navigator.of(tester.element(find.byType(WebEntryHost))).push(
        MaterialPageRoute<void>(
          builder: (_) => DiscardGuard(listenable: dirty, isDirty: () => true, child: const Scaffold()),
        ),
      ),
    );
    await pumpFrames(tester);
    await sendEntry(tester, {'kind': 'new', 'text': '不要离开编辑页'});
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(container.read(webOpenProvider), isNull);
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextButton)));
    await pumpFrames(tester);
    expect(find.byType(DiscardGuard), findsOneWidget);
    final request = container.read(webOpenProvider);
    await unmount(tester);
    dirty.dispose();
    expect(request, isNull);
  });

  testWidgets('Android retains its existing new-chat payload contract', (tester) async {
    final container = await pumpEntry(tester, 'android');
    await sendEntry(tester, {'kind': 'new', 'text': 'ordinary text'});
    final request = container.read(webOpenProvider);
    final observed = (request?.target.newSession, request?.compose);
    await unmount(tester);
    expect(observed, (true, null));
  });
}
