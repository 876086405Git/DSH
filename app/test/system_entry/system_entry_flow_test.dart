// The ways in from the rest of the phone, end to end through the real chat
// screen: the share sheet, launcher shortcuts, the tile and opened files.
// The native sides are faked the way SharePlugin.kt / ShortcutsPlugin.kt
// behave: arrivals held until Dart says `ready`, then pushed as calls.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/links/app_links.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/state/draft_store.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/ui_mode_state.dart';
import 'package:dsh_app/state/voice_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/widgets/attachments.dart';
import 'package:dsh_app/ui/common/discard_guard.dart';
import 'package:dsh_app/ui/shell/system_entry_host.dart';
import 'package:dsh_app/ui/web/web_home.dart';
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
late _Native _entries;
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

String _composerText(WidgetTester tester) => tester
    .widget<TextField>(find.descendant(of: find.byType(Composer), matching: find.byType(TextField)))
    .controller!
    .text;

bool _composerFocused(WidgetTester tester) => tester
    .widget<TextField>(find.descendant(of: find.byType(Composer), matching: find.byType(TextField)))
    .focusNode!
    .hasFocus;

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
  late Directory dir;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    dir = Directory.systemTemp.createTempSync('dsh-share');
  });
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  void natives(WidgetTester tester) {
    _shares = _Native(tester, 'dsh/share', 'share');
    _entries = _Native(tester, 'dsh/shortcuts', 'entry');
    _voice = FakeVoiceBridge();
  }

  File cached(String name, List<int> bytes) {
    final slot = Directory('${dir.path}/slot-$name')..createSync();
    return File('${slot.path}/$name')..writeAsBytesSync(bytes);
  }

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    for (final mode in ['created-paused', 'existing-paused', 'created-resumed']) {
      testWidgets('voice initial state $platform $mode', (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        try {
          natives(tester);
          for (final phase
              in tester.binding.lifecycleState == AppLifecycleState.paused
                  ? [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]
                  : [AppLifecycleState.resumed]) {
            tester.binding.handleAppLifecycleStateChanged(phase);
          }
          if (mode == 'created-paused') {
            for (final phase in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
              tester.binding.handleAppLifecycleStateChanged(phase);
            }
          }
          await _pump(tester, ChatHarness(session: 's1', states: {'s1': const ChatState(loading: false)}));
          if (mode == 'existing-paused') {
            for (final phase in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
              tester.binding.handleAppLifecycleStateChanged(phase);
            }
          }
          final expectedState = mode == 'created-resumed' ? AppLifecycleState.resumed : AppLifecycleState.paused;
          expect(tester.binding.lifecycleState, expectedState);
          await _entries.push({'kind': 'voice'});
          await tester.pump();
          if (mode != 'created-resumed') {
            expect(_voice.calls, isEmpty);
            await tester.pump(const Duration(milliseconds: 2999));
            expect(_voice.calls, isEmpty);
            await tester.pump(const Duration(milliseconds: 2));
          }
          await pumpFrames(tester, 6);
          expect(tester.binding.lifecycleState, expectedState);
          final observed = List<String>.of(_voice.calls);
          await _unmount(tester);
          for (final phase
              in tester.binding.lifecycleState == AppLifecycleState.paused
                  ? [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]
                  : [AppLifecycleState.resumed]) {
            tester.binding.handleAppLifecycleStateChanged(phase);
          }
          if (mode == 'existing-paused' || (platform == TargetPlatform.iOS && mode == 'created-paused')) {
            expect(observed, isEmpty);
          } else {
            expect(observed, containsAllInOrder(['permission', 'recognizer']));
          }
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }
  }

  testWidgets('iOS voice resumes during the launch wait', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      natives(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      for (final phase in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
        tester.binding.handleAppLifecycleStateChanged(phase);
      }
      await _pump(tester, ChatHarness(session: 's1', states: {'s1': const ChatState(loading: false)}));
      await _entries.push({'kind': 'voice'});
      await tester.pump(const Duration(seconds: 1));
      expect(_voice.calls, isEmpty);
      for (final phase in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
        tester.binding.handleAppLifecycleStateChanged(phase);
      }
      await pumpFrames(tester, 6);
      final observed = List<String>.of(_voice.calls);
      await _unmount(tester);
      expect(observed, containsAllInOrder(['permission', 'recognizer']));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('a share opens 新对话 with its text and files in the composer, not sent', (tester) async {
    natives(tester);
    final image = cached('IMG_1.png', tinyPng);
    final pdf = cached('报价单.pdf', utf8.encode('%PDF-1.7'));
    final harness = ChatHarness(session: 's1', states: {'s1': const ChatState(loading: false)});
    final container = await _pump(tester, harness);
    expect(container.read(currentSessionProvider), 's1');

    await _shares.push({
      'text': '帮我看看这份报价',
      'files': [
        {'path': image.path, 'name': 'IMG_1.png', 'mime': 'image/png'},
        {'path': pdf.path, 'name': '报价单.pdf', 'mime': 'application/pdf'},
      ],
      'skipped': [],
    });
    await _settle(tester, () => _tray(tester).isNotEmpty);

    expect(container.read(currentSessionProvider), isNull);
    expect(_composerText(tester), '帮我看看这份报价');
    expect(_tray(tester), ['IMG_1.png', '报价单.pdf']);
    expect(_composerFocused(tester), isTrue);
    expect(harness.controllers['s1']!.sent, isEmpty);
    // The cached copies are gone; the bytes live in the draft.
    expect(image.existsSync(), isFalse);
    expect(pdf.existsSync(), isFalse);
    await _unmount(tester);
  });

  // A page with unsaved edits above [anchor], which asks before anyone leaves.
  Future<void> openDirtyPage(WidgetTester tester, Finder anchor) async {
    unawaited(
      Navigator.of(tester.element(anchor)).push(
        MaterialPageRoute<void>(
          builder: (_) => DiscardGuard(listenable: ValueNotifier(0), isDirty: () => true, child: const Scaffold()),
        ),
      ),
    );
    await pumpFrames(tester);
  }

  // The share has reached the dialog, and any read it started has had real
  // time to finish.
  Future<void> untilAsked(WidgetTester tester) async {
    await _settle(tester, () => find.byType(AlertDialog).evaluate().isNotEmpty);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }

  Finder dialogButton<T extends Widget>() => find.descendant(of: find.byType(AlertDialog), matching: find.byType(T));

  Map<String, Object?> sharing(File file) => {
    'files': [
      {'path': file.path, 'name': file.uri.pathSegments.last, 'mime': 'application/pdf'},
    ],
    'skipped': [],
  };

  group('behind an unanswered 放弃修改', () {
    testWidgets('a share stays in the cache until the person leaves the page', (tester) async {
      natives(tester);
      final file = cached('a.pdf', utf8.encode('%PDF-1.7'));
      await _pump(tester, ChatHarness());
      await openDirtyPage(tester, find.byType(ChatScreen));

      await _shares.push(sharing(file));
      await untilAsked(tester);
      expect(file.existsSync(), isTrue);

      await tester.tap(dialogButton<FilledButton>());
      await _settle(tester, () => _tray(tester).isNotEmpty);
      expect(_tray(tester), ['a.pdf']);
      expect(file.existsSync(), isFalse);
      await _unmount(tester);
    });

    testWidgets('a share still lands for later when the person keeps editing', (tester) async {
      natives(tester);
      final file = cached('a.pdf', utf8.encode('%PDF-1.7'));
      await _pump(tester, ChatHarness());
      await openDirtyPage(tester, find.byType(ChatScreen));

      await _shares.push(sharing(file));
      await untilAsked(tester);
      expect(file.existsSync(), isTrue);

      await tester.tap(dialogButton<TextButton>());
      await _settle(tester, () => !file.existsSync());
      expect(find.byType(DiscardGuard), findsOneWidget);
      // The composer under the page has taken it, ready for when they're back.
      final tray = tester.widget<ComposerTray>(find.byType(ComposerTray, skipOffstage: false));
      expect([for (final a in tray.items) a.name], ['a.pdf']);
      await _unmount(tester);
    });

    Future<ProviderContainer> pumpWeb(WidgetTester tester, File file) async {
      natives(tester);
      await tester.pumpWidget(
        testApp(
          const Stack(fit: StackFit.expand, children: [LinkHost(), WebEntryHost(), Scaffold()]),
          overrides: ChatHarness().overrides,
        ),
      );
      await pumpFrames(tester);
      final container = ProviderScope.containerOf(tester.element(find.byType(WebEntryHost)));
      await openDirtyPage(tester, find.byType(WebEntryHost));
      await _shares.push(sharing(file));
      await untilAsked(tester);
      expect(file.existsSync(), isTrue);
      return container;
    }

    testWidgets('the web home reads a share once the person leaves the page', (tester) async {
      final file = cached('a.pdf', utf8.encode('%PDF-1.7'));
      final container = await pumpWeb(tester, file);

      await tester.tap(dialogButton<FilledButton>());
      await _settle(tester, () => container.read(webOpenProvider) != null);
      expect([for (final a in container.read(webOpenProvider)!.compose!.attachments) a.name], ['a.pdf']);
      expect(file.existsSync(), isFalse);
      await _unmount(tester);
    });

    testWidgets('the web home drops a share unread when the person keeps editing', (tester) async {
      final file = cached('a.pdf', utf8.encode('%PDF-1.7'));
      final container = await pumpWeb(tester, file);

      await tester.tap(dialogButton<TextButton>());
      await _settle(tester, () => !file.existsSync());
      expect(container.read(webOpenProvider), isNull);
      await _unmount(tester);
    });
  });

  testWidgets('a share joins what the new chat already holds and says what did not fit', (tester) async {
    natives(tester);
    final container = await _pump(tester, ChatHarness());
    final field = find.descendant(of: find.byType(Composer), matching: find.byType(TextField));
    await tester.enterText(field, '先写好的');
    await tester.pump();

    await _shares.push({
      'text': '分享来的一段话',
      'skipped': [
        {'name': '电影.mp4', 'reason': 'too_large'},
      ],
    });
    await _settle(tester, () => _composerText(tester) != '先写好的');
    expect(container.read(currentSessionProvider), isNull);
    expect(_composerText(tester), '先写好的\n\n分享来的一段话');
    expect(find.text('「电影.mp4」太大，未添加'), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets('a share that arrives before the app is up lands once it is', (tester) async {
    natives(tester);
    await _shares.push({'text': '冷启动时分享的'});
    await _pump(tester, ChatHarness(session: 's1'));
    await _settle(tester, () => _composerText(tester).isNotEmpty);
    expect(_composerText(tester), '冷启动时分享的');
    await _unmount(tester);
  });

  testWidgets('consecutive shares keep all draft text but only the latest warning', (tester) async {
    natives(tester);
    final harness = ChatHarness();
    await _pump(tester, harness);
    Future<void> share(String name) => _shares.push({
      'text': name,
      'skipped': [
        {'name': '$name.bin', 'reason': 'too_large'},
      ],
    });
    await share('first');
    await _settle(tester, () => _composerText(tester) == 'first');
    expect(find.text('「first.bin」太大，未添加'), findsOneWidget);

    // Native arrivals can finish while the first warning is still exiting.
    await share('middle');
    await share('latest');
    await tester.idle();
    await pumpFrames(tester);
    expect(_composerText(tester), 'first\n\nmiddle\n\nlatest');
    expect(find.text('「latest.bin」太大，未添加'), findsOneWidget);
    expect(find.text('「middle.bin」太大，未添加'), findsNothing);
    expect(harness.controllers.values.every((c) => c.sent.isEmpty), isTrue);
    await _settle(tester, () => tester.widget<SnackBar>(find.byType(SnackBar)).animation!.isCompleted);
    await tester.pump(const Duration(seconds: 2));
    await pumpFrames(tester);
    expect(find.byType(SnackBar), findsNothing);
    await _unmount(tester);
  });

  testWidgets('a lone share-code file goes to the importer, not to a chat', (tester) async {
    natives(tester);
    final code = cached('读书笔记.dshgo', utf8.encode('{"dshgo":1}'));
    final container = await _pump(tester, ChatHarness(session: 's1'));
    final opened = <Uri>[];
    container.read(linkRouterProvider).registerFileHandler('dshgo', (uri) async {
      opened.add(uri);
      return true;
    });
    await _shares.push({
      'files': [
        {'path': code.path, 'name': '读书笔记.dshgo', 'mime': 'application/octet-stream'},
      ],
    });
    await _settle(tester, () => opened.isNotEmpty);
    expect(opened.single.toFilePath(), code.path);
    expect(container.read(currentSessionProvider), 's1');
    expect(code.existsSync(), isTrue);
    await _unmount(tester);
  });

  testWidgets('新对话 from the launcher or the tile: an empty, focused composer', (tester) async {
    natives(tester);
    final container = await _pump(tester, ChatHarness(session: 's1', states: {'s1': const ChatState(loading: false)}));
    await _entries.push({'kind': 'new'});
    await pumpFrames(tester);
    expect(container.read(currentSessionProvider), isNull);
    expect(_composerText(tester), isEmpty);
    expect(_composerFocused(tester), isTrue);
    expect(_voice.calls, isEmpty);
    await _unmount(tester);
  });

  group('Siri navigation permission', () {
    Future<Map<String, Object?>> afterAnswer(
      WidgetTester tester, {
      required bool discard,
      String os = 'ios',
      bool voice = true,
    }) async {
      debugDefaultTargetPlatformOverride = os == 'ios' ? TargetPlatform.iOS : TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      natives(tester);
      await _pump(tester, ChatHarness(), operatingSystem: os);
      await openDirtyPage(tester, find.byType(ChatScreen));
      await _entries.push(voice ? {'kind': 'voice'} : {'kind': 'new', 'text': '留到返回聊天时'});
      await untilAsked(tester);
      expect(_voice.calls, isEmpty);
      await tester.tap(discard ? dialogButton<FilledButton>() : dialogButton<TextButton>());
      await pumpFrames(tester);
      final composer = tester.widget<Composer>(find.byType(Composer, skipOffstage: false));
      final field = tester.widget<TextField>(
        find.descendant(
          of: find.byType(Composer, skipOffstage: false),
          matching: find.byType(TextField, skipOffstage: false),
        ),
      );
      final observed = <String, Object?>{
        'calls': List.of(_voice.calls),
        'voiceActive': composer.voice!.active,
        'editing': find.byType(DiscardGuard).evaluate().isNotEmpty,
        'text': field.controller!.text,
      };
      await _unmount(tester);
      debugDefaultTargetPlatformOverride = null;
      return observed;
    }

    testWidgets('iOS keeps editing without starting hidden dictation', (tester) async {
      expect(await afterAnswer(tester, discard: false), {
        'calls': <String>[],
        'voiceActive': false,
        'editing': true,
        'text': '',
      });
    });

    testWidgets('iOS discard opens the chat and starts dictation', (tester) async {
      expect(await afterAnswer(tester, discard: true), {
        'calls': ['permission', 'recognizer'],
        'voiceActive': true,
        'editing': false,
        'text': '',
      });
    });

    testWidgets('iOS text still fills the draft behind a kept page', (tester) async {
      expect(await afterAnswer(tester, discard: false, voice: false), {
        'calls': <String>[],
        'voiceActive': false,
        'editing': true,
        'text': '留到返回聊天时',
      });
    });

    testWidgets('Android shortcut retains its existing behavior', (tester) async {
      expect(await afterAnswer(tester, discard: false, os: 'android'), {
        'calls': ['permission', 'recognizer'],
        'voiceActive': true,
        'editing': true,
        'text': '',
      });
    });
  });

  testWidgets('语音输入 opens 新对话 listening', (tester) async {
    natives(tester);
    final container = await _pump(tester, ChatHarness(session: 's1', states: {'s1': const ChatState(loading: false)}));
    await _entries.push({'kind': 'voice'});
    await pumpFrames(tester);
    expect(container.read(currentSessionProvider), isNull);
    expect(_voice.calls, containsAllInOrder(['permission', 'recognizer']));
    expect(tester.widget<Composer>(find.byType(Composer)).voice!.active, isTrue);
    await _unmount(tester);
  });

  testWidgets('a pet screenshot opens an editable image draft without sending or losing text', (tester) async {
    natives(tester);
    final image = cached('screenshot.png', tinyPng);
    final harness = ChatHarness(session: 's1', states: {'s1': const ChatState(loading: false, running: true)});
    final container = await _pump(tester, harness);
    final field = find.descendant(of: find.byType(Composer), matching: find.byType(TextField));
    await tester.enterText(field, 'old chat draft');
    container.read(draftStoreProvider.notifier).save('new', 'existing question', const []);

    await _entries.push({'kind': 'screenshot', 'path': image.path});
    await _settle(tester, () => _tray(tester).isNotEmpty);

    expect(container.read(currentSessionProvider), isNull);
    expect(_composerText(tester), 'existing question');
    expect(_tray(tester), ['screenshot.png']);
    expect(_composerFocused(tester), isTrue);
    final drafts = container.read(draftStoreProvider).drafts;
    expect(drafts['s1']!.text, 'old chat draft');
    expect(drafts['new']!.attachments.single.bytes, tinyPng);
    expect(harness.controllers.values.every((c) => c.sent.isEmpty), isTrue);
    expect(image.existsSync(), isFalse);

    await tester.enterText(field, 'what does this mean?');
    await tester.pump();
    expect(_tray(tester), ['screenshot.png']);
    expect(harness.controllers.values.every((c) => c.sent.isEmpty), isTrue);
    await _unmount(tester);
  });

  testWidgets('a screenshot waiting at startup is attached once when the composer is ready', (tester) async {
    natives(tester);
    final image = cached('startup-screen.png', tinyPng);
    await _entries.push({'kind': 'screenshot', 'path': image.path});
    final harness = ChatHarness(session: 's1');
    final container = await _pump(tester, harness);
    await _settle(tester, () => _tray(tester).isNotEmpty);

    expect(container.read(currentSessionProvider), isNull);
    expect(_tray(tester), ['startup-screen.png']);
    expect(_composerText(tester), isEmpty);
    expect(_composerFocused(tester), isTrue);
    expect(image.existsSync(), isFalse);
    expect(harness.controllers.values.every((c) => c.sent.isEmpty), isTrue);
    await _unmount(tester);
  });

  testWidgets('an unreadable screenshot reports the problem rather than submitting a message', (tester) async {
    natives(tester);
    final harness = ChatHarness(session: 's1');
    final container = await _pump(tester, harness);
    await _entries.push({'kind': 'screenshot', 'path': '${dir.path}/missing.png'});
    await _settle(tester, () => container.read(currentSessionProvider) == null);

    expect(_tray(tester), isEmpty);
    expect(find.text('没能读取「missing.png」'), findsOneWidget);
    expect(harness.controllers.values.every((c) => c.sent.isEmpty), isTrue);
    await _unmount(tester);
  });

  testWidgets('a recent conversation opens on its host', (tester) async {
    natives(tester);
    final container = await _pump(tester, ChatHarness());
    await _entries.push({'kind': 'chat', 'sessionId': 's2', 'host': HostRef.local.encode()});
    await pumpFrames(tester);
    expect(container.read(activeHostProvider), HostRef.local);
    expect(container.read(currentSessionProvider), 's2');
    await _unmount(tester);
  });

  testWidgets('a file opened with the app that nothing claims is attached to 新对话', (tester) async {
    natives(tester);
    final notes = cached('notes.md', utf8.encode('# 会议记录'));
    final container = await _pump(tester, ChatHarness(session: 's1'));
    container.read(appLinksProvider).add(Uri.file(notes.path));
    await _settle(tester, () => _tray(tester).isNotEmpty);
    expect(container.read(currentSessionProvider), isNull);
    expect(_tray(tester), ['notes.md']);
    await _unmount(tester);
  });

  testWidgets('the launcher gets the latest conversations once connected', (tester) async {
    natives(tester);
    await _pump(tester, ChatHarness());
    await pumpFrames(tester);
    expect(_entries.recents, [
      {'items': <Object?>[]},
    ]);
    await _unmount(tester);
  });
}
