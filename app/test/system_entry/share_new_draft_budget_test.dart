// A share's byte budget, through the real chat screen and draft store. On iOS it is the
// new-chat draft's, where the share lands; elsewhere the selected conversation's.
// The native side is faked: arrivals held until Dart says `ready`, then pushed as calls.

import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/draft_store.dart';
import 'package:dsh_app/state/attachments.dart';

import 'package:dsh_app/links/app_links.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/voice_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/widgets/attachments.dart';
import 'package:dsh_app/ui/shell/system_entry_host.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/composer_fakes.dart';
import '../chat/support/harness.dart';

/// A native plugin: holds pushes until `ready`, answers `setRecent`.
class _Native {
  _Native(this.tester, String channel, this.method) : channel = MethodChannel(channel) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(this.channel, (call) async {
      switch (call.method) {
        case 'ready':
          _ready = true;
          final held = List.of(_held);
          _held.clear();
          Future<void>.microtask(() async {
            for (final args in held) {
              await _send(args);
            }
          });
          return true;
        case 'setRecent':
          recents.add(call.arguments);
          return true;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(this.channel, null));
  }

  final WidgetTester tester;
  final MethodChannel channel;
  final String method;
  final _held = <Map<String, Object?>>[];
  final recents = <Object?>[];
  bool _ready = false;

  Future<void> push(Map<String, Object?> args) async {
    if (!_ready) {
      _held.add(args);
      return;
    }
    await _send(args);
  }

  Future<void> _send(Map<String, Object?> args) => tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    channel.name,
    const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
    (_) {},
  );
}

/// The home shell's stack, without the rest of the shell.
class _Shell extends StatelessWidget {
  const _Shell();

  @override
  Widget build(BuildContext context) =>
      const Stack(fit: StackFit.expand, children: [LinkHost(), SystemEntryHost(), ChatScreen()]);
}

late _Native _shares;
late FakeVoiceBridge _voice;

Future<ProviderContainer> _pump(WidgetTester tester, ChatHarness harness, {String? operatingSystem}) async {
  usePhoneView(tester);
  mockClipboard(tester);
  await tester.pumpWidget(
    testApp(
      const _Shell(),
      overrides: [
        ...harness.overrides,
        if (operatingSystem != null) operatingSystemProvider.overrideWithValue(operatingSystem),
        voiceBridgeProvider.overrideWithValue(_voice),
      ],
    ),
  );
  await pumpFrames(tester);
  return ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
}

/// Real file reads finish only outside the fake clock: alternate both.
Future<void> _settle(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 100 && !done(); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump(const Duration(milliseconds: 50));
  }
  await pumpFrames(tester, 4);
  expect(done(), isTrue);
}

List<String> _tray(WidgetTester tester) {
  final tray = find.byType(ComposerTray);
  if (tray.evaluate().isEmpty) return const [];
  return [for (final a in tester.widget<ComposerTray>(tray).items) a.name];
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  for (final platform in ['ios', 'android', 'ohos']) {
    for (final fullTarget in [false, true]) {
      testWidgets('$platform share budget follows target contract; fullTarget=$fullTarget', (tester) async {
        SharedPreferences.setMockInitialValues({});
        debugDefaultTargetPlatformOverride = platform == 'ios' ? TargetPlatform.iOS : TargetPlatform.android;
        final dir = Directory.systemTemp.createTempSync('ios-share-budget');
        try {
          _shares = _Native(tester, 'dsh/share', 'share');
          _Native(tester, 'dsh/shortcuts', 'entry');
          _voice = FakeVoiceBridge();
          final container = await _pump(
            tester,
            ChatHarness(session: fullTarget ? 's1' : null, states: {'s1': const ChatState(loading: false)}),
            operatingSystem: platform,
          );
          final held = Uint8List(maxFileBytes);
          container.read(draftStoreProvider.notifier).save(fullTarget ? 'new' : 's1', 'saved draft', [
            DraftAttachment(name: 'first.bin', bytes: held),
            DraftAttachment(name: 'second.bin', bytes: held),
          ]);
          container.read(currentSessionProvider.notifier).select('s1');
          await pumpFrames(tester);
          if (fullTarget) {
            container.read(currentSessionProvider.notifier).select(null);
            await pumpFrames(tester);
          }
          expect(_tray(tester), ['first.bin', 'second.bin']);
          if (!fullTarget) expect(container.read(draftStoreProvider).drafts['new'], isNull);
          final file = File('${dir.path}/small.pdf')..writeAsBytesSync(utf8.encode('%PDF-1.7\nsmall'));
          await _shares.push({
            'files': [
              {'path': file.path, 'name': 'small.pdf', 'mime': 'application/pdf'},
            ],
          });
          await _settle(tester, () => !file.existsSync());
          expect(container.read(currentSessionProvider), isNull);
          expect(
            _tray(tester),
            fullTarget
                ? ['first.bin', 'second.bin']
                : platform == 'ios'
                ? ['small.pdf']
                : isEmpty,
          );
          expect(container.read(draftStoreProvider).drafts[fullTarget ? 'new' : 's1']!.attachments.length, 2);
        } finally {
          await _unmount(tester);
          if (dir.existsSync()) dir.deleteSync(recursive: true);
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }
  }
}
