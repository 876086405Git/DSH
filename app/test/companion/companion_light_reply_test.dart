// Light mode uses its real SSE reader and page reply path. Only the HTTP
// response, settings and stage surface are replaced; no model request leaves
// the test process.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/companion/companion_keeper.dart';
import 'package:dsh_app/companion/companion_pack.dart';
import 'package:dsh_app/companion/companion_state.dart';
import 'package:dsh_app/l10n/gen/app_localizations.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/companion/companion_chrome.dart';
import 'package:dsh_app/ui/companion/companion_page.dart';
import 'package:dsh_app/ui/companion/companion_stage.dart';
import 'package:dsh_app/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'phone_keeper_fake.dart';

class _Host extends ActiveHostController {
  @override
  HostRef build() => HostRef.local;
}

class _Settings extends SettingsController {
  @override
  AppSettings build() => const AppSettings(loaded: true, apiKey: 'synthetic-test-key');
}

class _Room {
  _Room(this.root);
  final Directory root;
  final commands = <(String, Map<String, Object?>)>[];
  final requests = <Map<String, Object?>>[];
  final replies = <StreamController<List<int>>>[];
  CompanionStageEvents? events;

  http.Client newClient() => MockClient.streaming((request, body) async {
    requests.add(jsonDecode(await body.bytesToString()) as Map<String, Object?>);
    final reply = StreamController<List<int>>();
    replies.add(reply);
    return http.StreamedResponse(reply.stream, 200);
  });

  String? speech(WidgetTester tester) => tester.widget<CompanionSpeech>(find.byType(CompanionSpeech)).text;

  List<String> names(String kind) => [
    for (final command in commands)
      if (command.$1 == kind) command.$2['name']! as String,
  ];

  void delta(String text) => replies.last.add(
    utf8.encode(
      'data: ${jsonEncode({
        'type': 'content_block_delta',
        'index': 0,
        'delta': {'type': 'text_delta', 'text': text},
      })}\n\n',
    ),
  );

  Future<void> finish(WidgetTester tester) async {
    replies.last.add(
      utf8.encode(
        'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":4}}\n\n'
        'data: {"type":"message_stop"}\n\n',
      ),
    );
    unawaited(replies.last.close());
    await flush(tester);
    // The actual light history writes asynchronously after completion, one
    // queued file step at a time: let real I/O and the test clock both run.
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
  }

  Future<void> send(WidgetTester tester, String text) async {
    final before = requests.length;
    await tester.enterText(find.byType(TextField), text);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('send')));
    for (var i = 0; i < 100 && requests.length == before; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(requests, hasLength(before + 1));
    await flush(tester);
  }

  Future<void> open(WidgetTester tester) async {
    Directory('${root.path}/pack/runtime').createSync(recursive: true);
    Directory('${root.path}/pack/character').createSync(recursive: true);
    File('${root.path}/pack/runtime/live2dcubismcore.min.js').writeAsStringSync('core');
    File('${root.path}/pack/character/index.json').writeAsStringSync('[]');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeHostProvider.overrideWith(_Host.new),
          activeConnectionProvider.overrideWith((ref) => const AsyncData(null)),
          settingsProvider.overrideWith(_Settings.new),
          companionLightClientProvider.overrideWithValue(newClient),
          companionPhoneKeeperProvider.overrideWithValue((_) => FakePhoneKeeper()),
        ],
        child: MaterialApp(
          theme: buildDarkTheme(),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          locale: const Locale('zh'),
          home: CompanionPage(
            storeOverride: CompanionPackStore(root),
            stageController: CompanionStageController(sink: (type, args) => commands.add((type, args))),
            stageBuilder: (_, next) {
              events = next;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    for (var i = 0; i < 100 && events == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(events, isNotNull);
    events!.onReady();
    await flush(tester);
    await tester.pump(const Duration(seconds: 9));
    commands.clear();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await tester.runAsync(() async {
      for (final reply in replies) {
        if (!reply.isClosed) await reply.close();
      }
    });
  }
}

Future<void> flush(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 40));
  await tester.pump();
}

void main() {
  late Directory temporary;
  setUp(() {
    SharedPreferences.setMockInitialValues({'companion_mode': 'light'});
    temporary = Directory.systemTemp.createTempSync('companion-light-reply-');
  });
  // The last history save can still hold the file for a moment, and Windows
  // will not delete an open file: try again briefly.
  tearDown(() async {
    for (var i = 0; ; i++) {
      try {
        temporary.deleteSync(recursive: true);
        return;
      } on FileSystemException {
        if (i == 20) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  testWidgets('light deltas complete a hidden marker once and keep the current words', (tester) async {
    final room = _Room(temporary);
    await room.open(tester);
    try {
      await room.send(tester, '你好');
      room.delta('[表情:开');
      await flush(tester);
      expect(room.speech(tester), isNull);
      expect(room.names('emotion'), isEmpty);
      room.delta('心]你');
      await flush(tester);
      expect(room.speech(tester), '你');
      expect(room.names('emotion'), ['happy']);
      room.delta('好。');
      await flush(tester);
      expect(room.speech(tester), '你好。');
      await room.finish(tester);
      expect(room.speech(tester), '你好。');
      expect(room.names('emotion'), ['happy']);
      expect(room.commands.where((command) => command.$1 == 'say').map((command) => command.$2['chars']), [1, 2]);
    } finally {
      await room.close(tester);
    }
  });

  testWidgets('a later light turn can say the same words after the old bubble expires', (tester) async {
    final room = _Room(temporary);
    await room.open(tester);
    try {
      await room.send(tester, '第一句');
      room.delta('[动作:挥手]好。');
      await room.finish(tester);
      expect(room.speech(tester), '好。');
      await tester.pump(const Duration(seconds: 10));
      expect(room.speech(tester), isNull);
      await room.send(tester, '第二句');
      room.delta('[动作:挥手]好。');
      await room.finish(tester);
      expect(room.speech(tester), '好。');
      expect(room.requests, hasLength(2));
      expect(room.names('action'), ['wave', 'wave']);
      expect(room.commands.where((command) => command.$1 == 'say').map((command) => command.$2['chars']), [2, 2]);
    } finally {
      await room.close(tester);
    }
  });

  testWidgets('light completion reveals unfinished literal text without repeating a valid marker', (tester) async {
    final room = _Room(temporary);
    await room.open(tester);
    try {
      await room.send(tester, '说一句');
      room.delta('[表情:开心]好[动作:挥');
      await flush(tester);
      expect(room.speech(tester), '好');
      expect(room.names('emotion'), ['happy']);
      expect(room.names('action'), isEmpty);
      await room.finish(tester);
      expect(room.speech(tester), '好[动作:挥');
      expect(room.names('emotion'), ['happy']);
      expect(room.names('action'), isEmpty);
      expect(tester.widget<CompanionComposer>(find.byType(CompanionComposer)).running, isFalse);
    } finally {
      await room.close(tester);
    }
  });
}
