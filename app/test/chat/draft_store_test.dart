import 'dart:async';
import 'dart:convert';

import 'package:dsh_app/state/attachments.dart';
import 'package:dsh_app/state/draft_store.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/voice_state.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/voice/voice_bridge.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/widgets/attachments.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/harness.dart';
import 'support/composer_fakes.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('only text survives a provider scope restart; empty slots are deleted', () async {
    var container = ProviderContainer();
    var store = container.read(draftStoreProvider.notifier);
    final image = DraftAttachment.sniff('图片.png', tinyPng);
    store.save('a', 'A 草稿', [image]);
    store.save('b', 'B 草稿', const []);
    store.clear('b');
    await store.flush();
    container.dispose();
    container = ProviderContainer();
    store = container.read(draftStoreProvider.notifier);
    await store.flush();
    final drafts = container.read(draftStoreProvider).drafts;
    expect(drafts['a']!.text, 'A 草稿');
    expect(drafts['a']!.attachments, isEmpty);
    expect(drafts.containsKey('b'), isFalse);
    container.dispose();
  });

  test('a picture pasted as its bytes is not put back, what was typed before it is (#1684)', () async {
    // As Android reads them: what UTF-8 cannot decode is U+FFFD.
    final jpeg = '\ufffd\ufffd\ufffd\ufffd\u0000\u0010JFIF\u0000MM\u0000*' * 1000;
    final png = '\ufffdPNG\r\n\u001a\n\u0000\u0000\u0000\rIHDR' * 1000;
    SharedPreferences.setMockInitialValues({
      DraftStore.preferenceKey: jsonEncode({
        'pasted': {'t': jpeg, 'at': 5},
        'png': {'t': png, 'at': 4},
        'both': {'t': '看看这张图 $jpeg', 'at': 3},
        'cafe': {'t': 'café$png', 'at': 2},
        'typed': {'t': '明天再问', 'at': 1},
      }),
    });
    final container = ProviderContainer();
    final store = container.read(draftStoreProvider.notifier);
    await store.flush();
    final drafts = container.read(draftStoreProvider).drafts;
    expect(drafts.keys, ['both', 'cafe', 'typed']);
    expect(drafts['both']!.text, '看看这张图');
    expect(drafts['cafe']!.text, 'café');
    expect(drafts['typed']!.text, '明天再问');
    container.dispose();
  });

  test('what was typed before the saved drafts load wins', () async {
    SharedPreferences.setMockInitialValues({
      DraftStore.preferenceKey: jsonEncode({
        'a': {'t': '旧文', 'at': 1},
        'b': {'t': 'B 的旧文', 'at': 2},
      }),
    });
    final container = ProviderContainer();
    final store = container.read(draftStoreProvider.notifier);
    store.save('a', '刚输入的', const []);
    await store.flush();
    final drafts = container.read(draftStoreProvider).drafts;
    expect(drafts['a']!.text, '刚输入的');
    expect(drafts['b']!.text, 'B 的旧文');
    container.dispose();
  });

  test('keeps at most 30 drafts', () async {
    final container = ProviderContainer();
    final store = container.read(draftStoreProvider.notifier);
    for (var i = 0; i < 35; i++) {
      store.save('$i', '草稿 $i', const []);
    }
    await store.flush();
    expect(container.read(draftStoreProvider).drafts, hasLength(30));
    container.dispose();
  });

  testWidgets('switching conversations restores their own text and attachments', (tester) async {
    usePhoneView(tester);
    mockClipboard(tester);
    final harness = ChatHarness(session: 'a');
    await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
    await pumpFrames(tester);
    final container = ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
    final image = DraftAttachment.sniff('图片.png', tinyPng);
    container.read(draftStoreProvider.notifier).save('b', 'B 草稿', [image]);
    await tester.enterText(find.byType(TextField), 'A 草稿');
    container.read(currentSessionProvider.notifier).select('b');
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'B 草稿');
    expect(tester.widget<ComposerTray>(find.byType(ComposerTray)).items, [image]);
    container.read(currentSessionProvider.notifier).select('a');
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'A 草稿');
    expect(find.byType(ComposerTray), findsNothing);
    container.read(currentSessionProvider.notifier).select('c');
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
    expect(find.byType(ComposerTray), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('a delayed send failure restores only its own conversation', (tester) async {
    usePhoneView(tester);
    mockClipboard(tester);
    final harness = ChatHarness(session: 'a');
    await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
    await pumpFrames(tester);
    final result = Completer<bool>();
    harness.controllers['a']!.sendResult = result.future;
    await tester.enterText(find.byType(TextField), 'A 的消息');
    await tester.pump();
    await tester.tap(find.byIcon(AppIcons.send));
    await tester.pump();
    final container = ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
    container.read(currentSessionProvider.notifier).select('b');
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'B 的草稿');
    result.complete(false);
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'B 的草稿');
    container.read(currentSessionProvider.notifier).select('a');
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'A 的消息');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('switching conversations cancels active dictation', (tester) async {
    usePhoneView(tester);
    mockClipboard(tester);
    final bridge = FakeVoiceBridge();
    final harness = ChatHarness(session: 'a');
    await tester.pumpWidget(
      testApp(const ChatScreen(), overrides: [...harness.overrides, voiceBridgeProvider.overrideWithValue(bridge)]),
    );
    await pumpFrames(tester);
    final voice = tester.widget<Composer>(find.byType(Composer)).voice!;
    await voice.start();
    bridge.emit(const VoicePartial('听写内容'));
    await tester.pump();
    expect(voice.active, isTrue);
    final container = ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
    container.read(currentSessionProvider.notifier).select('b');
    await tester.pump();
    expect(bridge.calls, contains('cancel'));
    expect(voice.active, isFalse);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('sending a new conversation leaves the next new draft empty', (tester) async {
    usePhoneView(tester);
    mockClipboard(tester);
    final harness = ChatHarness(created: 'fresh');
    await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
    await pumpFrames(tester);
    final container = ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
    await tester.enterText(find.byType(TextField), '你好');
    await tester.pump();
    await tester.tap(find.byIcon(AppIcons.send));
    await pumpFrames(tester);
    container.read(currentSessionProvider.notifier).select(null);
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
  });
}
