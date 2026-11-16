// Her voice: sentences read as they complete, her mouth on the engine's word
// boundaries, silence the moment the person types.

import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/companion/companion_keeper.dart';
import 'package:dsh_app/companion/companion_pack.dart';
import 'package:dsh_app/companion/companion_voice.dart';
import 'package:dsh_app/companion/companion_voice_source.dart';
import 'package:dsh_app/ui/companion/companion_voice_page.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:dsh_app/l10n/gen/app_localizations.dart';
import 'package:dsh_app/speech/speech_settings.dart' show companionEffectiveVoiceProvider;
import 'package:dsh_app/state/android_features.dart' show operatingSystemProvider;
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/ui/companion/companion_page.dart';
import 'package:dsh_app/ui/companion/companion_stage.dart';
import 'package:dsh_app/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'phone_keeper_fake.dart';

const _channel = MethodChannel('dsh/companion_voice');

void main() {
  group('companionSpeakable', () {
    test('whole sentences while streaming, the rest once finished', () {
      expect(companionSpeakable('你好', 0, final_: false), ('', 0));
      expect(companionSpeakable('你好。今天', 0, final_: false), ('你好。', 3));
      expect(companionSpeakable('你好。今天好累！我', 3, final_: false), ('今天好累！', 8));
      expect(companionSpeakable('你好。今天好累！我在', 8, final_: true), ('我在', 10));
      expect(companionSpeakable('你好。', 3, final_: true), ('', 3));
    });

    test('a retry that took words back starts over from where it now ends', () {
      expect(companionSpeakable('好。', 10, final_: false), ('', 2));
    });
  });

  group('page', () {
    late Directory root;
    final calls = <MethodCall>[];

    setUp(() {
      root = Directory.systemTemp.createTempSync('companion-voice');
      calls.clear();
      SharedPreferences.setMockInitialValues({
        'companion_touch_hint_done': true,
        'companion_home_hint_done': true,
        'companion_voice_enabled': true,
        // Her own voice, the phone's (not following 朗读's).
        'companion_voice_v1': '{"source": "system"}',
      });
    });
    tearDown(() {
      try {
        root.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows can hold a file a moment longer; the system clears temp.
      }
    });

    Future<void> event(WidgetTester tester, Map<String, Object?> args) =>
        tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          _channel.name,
          const StandardMethodCodec().encodeMethodCall(MethodCall('event', args)),
          (_) {},
        );

    testWidgets('her lines are read aloud, her mouth follows the voice, typing silences her', (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (call) async {
        calls.add(call);
        return switch (call.method) {
          'ready' || 'speak' => true,
          _ => null,
        };
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null));
      Directory('${root.path}/pack/runtime').createSync(recursive: true);
      Directory('${root.path}/pack/character').createSync(recursive: true);
      File('${root.path}/pack/runtime/live2dcubismcore.min.js').writeAsStringSync('core');
      File('${root.path}/pack/character/index.json').writeAsStringSync('[]');
      File('${root.path}/pack/character/character.json').writeAsStringSync('{"name":"鲸鱼娘"}');
      final commands = <(String, Map<String, Object?>)>[];
      CompanionStageEvents? stage;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            activeConnectionProvider.overrideWithValue(const AsyncData<HostConnection?>(null)),
            companionPhoneKeeperProvider.overrideWithValue((_) => FakePhoneKeeper() as CompanionKeeper),
          ],
          child: MaterialApp(
            theme: buildDarkTheme(),
            localizationsDelegates: L10n.localizationsDelegates,
            supportedLocales: L10n.supportedLocales,
            locale: const Locale('zh'),
            home: CompanionPage(
              storeOverride: CompanionPackStore(root),
              stageBuilder: (controller, events) {
                stage = events;
                return const SizedBox.expand();
              },
              stageController: CompanionStageController(sink: (type, args) => commands.add((type, args))),
            ),
          ),
        ),
      );
      for (var i = 0; i < 100 && stage == null; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
        await tester.pump(const Duration(milliseconds: 120));
      }
      expect(calls.map((c) => c.method), contains('ready'));
      stage!.onReady();
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
        await tester.pump(const Duration(milliseconds: 120));
      }
      // The greeting, aloud.
      final greeting = calls.where((c) => c.method == 'speak').single.arguments as Map;
      expect(greeting['text'], '你好呀，我是鲸鱼娘。以后就住在这里了，请多指教。');
      expect(greeting['flush'], isTrue);

      await tester.pump(const Duration(seconds: 8));
      calls.clear();
      commands.clear();
      stage!.onTouch('tail', 'tap');
      await tester.pump(const Duration(milliseconds: 100));
      final line = calls.where((c) => c.method == 'speak').single.arguments as Map;
      expect(find.text(line['text'] as String), findsOneWidget);
      // Her mouth waits for the voice, not the text.
      expect(commands.where((c) => c.$1 == 'say'), isEmpty);
      await event(tester, {'type': 'start', 'id': line['id']});
      await event(tester, {'type': 'range', 'id': line['id'], 'start': 0, 'end': 2});
      await tester.pump();
      expect(commands.where((c) => c.$1 == 'say').map((c) => c.$2['chars']), [line['text'].toString().length, 2]);

      // The person types: she stops.
      await tester.enterText(find.byType(TextField), '等等');
      await tester.pump();
      expect(calls.map((c) => c.method), contains('stop'));

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
    });
  });

  group('voice page', () {
    testWidgets('MiMo from the presets: a key and a voice are all it takes', (tester) async {
      // A phone-tall screen: the whole form fits, nothing hides under the bar.
      tester.view.physicalSize = const Size(1080, 3600);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (call) async {
        calls.add(call);
        return switch (call.method) {
          'ready' || 'speak' || 'play' => true,
          _ => null,
        };
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null));
      final folder = Directory.systemTemp.createTempSync('companion-voice-preset');
      addTearDown(() {
        try {
          folder.deleteSync(recursive: true);
        } on FileSystemException {
          // The system clears temp.
        }
      });
      final sent = <http.Request>[];
      final wav = [...'RIFF'.codeUnits, 36, 0, 0, 0, ...'WAVE'.codeUnits];
      final client = MockClient((request) async {
        sent.add(request);
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'audio': {'data': base64.encode(wav)},
                },
              },
            ],
          }),
          200,
        );
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            companionVoiceClientProvider.overrideWithValue(() => client),
            companionVoiceFolderProvider.overrideWithValue(() async => folder),
          ],
          child: MaterialApp(
            theme: buildDarkTheme(),
            localizationsDelegates: L10n.localizationsDelegates,
            supportedLocales: L10n.supportedLocales,
            locale: const Locale('zh'),
            home: const CompanionVoicePage(),
          ),
        ),
      );
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('常用服务'));
      await tester.pumpAndSettle();
      expect(find.text('小米 MiMo'), findsOneWidget);
      final key = find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == 'sk-…');
      await tester.scrollUntilVisible(key, 200, scrollable: find.byType(Scrollable).first);
      await tester.enterText(key, 'mimo-key');
      await tester.scrollUntilVisible(find.text('茉莉 · 女声'), 200, scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('茉莉 · 女声'));
      await tester.pump(const Duration(milliseconds: 500));

      await tester.scrollUntilVisible(find.text('试听'), 300, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('试听'));
      for (var i = 0; i < 20 && !calls.any((c) => c.method == 'play'); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump();
      }
      expect(find.text('能用，听到了吗？'), findsOneWidget);
      expect(sent.single.url.host, 'api.xiaomimimo.com');
      expect(sent.single.headers['api-key'], 'mimo-key');
      expect(((jsonDecode(sent.single.body) as Map)['audio'] as Map)['voice'], '茉莉');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('MiMo cloning: choose a recording, then hear her in that voice', (tester) async {
      tester.view.physicalSize = const Size(1080, 3600);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (call) async {
        calls.add(call);
        return switch (call.method) {
          'ready' || 'speak' || 'play' => true,
          _ => null,
        };
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null));
      final folder = Directory.systemTemp.createTempSync('companion-voice-clone');
      addTearDown(() {
        try {
          folder.deleteSync(recursive: true);
        } on FileSystemException {
          // The system clears temp.
        }
      });
      final wav = <int>[...'RIFF'.codeUnits, 36, 0, 0, 0, ...'WAVE'.codeUnits, ...List.filled(64, 0)];
      final sent = <http.Request>[];
      final client = MockClient((request) async {
        sent.add(request);
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'audio': {'data': base64.encode(wav)},
                },
              },
            ],
          }),
          200,
        );
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            companionVoiceClientProvider.overrideWithValue(() => client),
            companionVoiceFolderProvider.overrideWithValue(() async => folder),
            companionVoiceSampleFolderProvider.overrideWithValue(() async => folder),
            companionVoicePickerProvider.overrideWithValue(() async => (Stream.value(wav), wav.length)),
          ],
          child: MaterialApp(
            theme: buildDarkTheme(),
            localizationsDelegates: L10n.localizationsDelegates,
            supportedLocales: L10n.supportedLocales,
            locale: const Locale('zh'),
            home: const CompanionVoicePage(),
          ),
        ),
      );
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('常用服务'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == 'sk-…'),
        'mimo-key',
      );
      await tester.tap(find.text('克隆声音'));
      await tester.pumpAndSettle();
      expect(find.text('还没有录音'), findsOneWidget);
      expect(find.text('茉莉 · 女声'), findsNothing);

      await tester.tap(find.text('选一段录音'));
      for (var i = 0; i < 20 && find.textContaining('已上传').evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump();
      }
      expect(find.textContaining('已上传'), findsOneWidget);
      expect(File('${folder.path}/voice-sample.wav').existsSync(), isTrue);

      await tester.tap(find.text('试听'));
      for (var i = 0; i < 20 && !calls.any((c) => c.method == 'play'); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump();
      }
      expect(find.text('能用，听到了吗？'), findsOneWidget);
      final body = jsonDecode(sent.single.body) as Map;
      expect(body['model'], 'mimo-v2.5-tts-voiceclone');
      expect((body['audio'] as Map)['voice'], startsWith('data:audio/wav;base64,'));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an OpenAI-compatible voice: fill it in, hear it, or see why not', (tester) async {
      // Tall enough for the sources list (跟朗读一样 and DeepSeek come first) and the form.
      tester.view.physicalSize = const Size(1080, 3600);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (call) async {
        calls.add(call);
        return switch (call.method) {
          'ready' || 'speak' || 'play' => true,
          _ => null,
        };
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null));
      final folder = Directory.systemTemp.createTempSync('companion-voice-page');
      addTearDown(() {
        try {
          folder.deleteSync(recursive: true);
        } on FileSystemException {
          // The system clears temp.
        }
      });
      var status = 200;
      final sent = <http.Request>[];
      final client = MockClient((request) async {
        sent.add(request);
        if (status != 200) return http.Response('{"error":"invalid key"}', status);
        // A minimal WAV header with no samples is enough to be audio.
        return http.Response.bytes([...'RIFF'.codeUnits, 36, 0, 0, 0, ...'WAVE'.codeUnits], 200);
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            companionVoiceClientProvider.overrideWithValue(() => client),
            companionVoiceFolderProvider.overrideWithValue(() async => folder),
          ],
          child: MaterialApp(
            theme: buildDarkTheme(),
            localizationsDelegates: L10n.localizationsDelegates,
            supportedLocales: L10n.supportedLocales,
            locale: const Locale('zh'),
            home: const CompanionVoicePage(),
          ),
        ),
      );
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('OpenAI 兼容接口'));
      await tester.pumpAndSettle();
      Finder field(String hint) => find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == hint);
      await tester.enterText(field('sk-…'), 'sk-voice');
      await tester.enterText(field('alloy'), 'nova');
      await tester.pump(const Duration(milliseconds: 500));

      // The page builds as it scrolls.
      await tester.scrollUntilVisible(find.text('试听'), 300, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('试听'));
      for (var i = 0; i < 20 && !calls.any((c) => c.method == 'play'); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump();
      }
      expect(find.text('能用，听到了吗？'), findsOneWidget);
      expect(sent.single.headers['authorization'], 'Bearer sk-voice');
      expect((jsonDecode(sent.single.body) as Map)['voice'], 'nova');

      status = 401;
      await tester.tap(find.text('试听'));
      for (var i = 0; i < 20 && find.textContaining('没成功').evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump();
      }
      expect(find.textContaining('没成功：HTTP 401'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    for (final (os, sources) in [
      ('ohos', ['deepseek', 'system']),
      ('android', ['deepseek', 'system', 'preset', 'openai', 'custom']),
    ]) {
      testWidgets('朗读 on $os offers the voices it can play: $sources', (tester) async {
        SharedPreferences.setMockInitialValues({});
        // The page saves on its way out, so the container outlives it.
        final container = ProviderContainer(overrides: [operatingSystemProvider.overrideWithValue(os)]);
        addTearDown(container.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: buildDarkTheme(),
              localizationsDelegates: L10n.localizationsDelegates,
              supportedLocales: L10n.supportedLocales,
              locale: const Locale('zh'),
              home: const CompanionVoicePage(shared: true),
            ),
          ),
        );
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pumpAndSettle();
        expect([
          for (final source in CompanionVoiceSource.values)
            if (find.byKey(ValueKey('voice-source-${source.name}')).evaluate().isNotEmpty) source.name,
        ], sources);
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      });
    }

    testWidgets('her room on ohos offers only the phone voice, whatever was saved', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer(overrides: [operatingSystemProvider.overrideWithValue('ohos')]);
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildDarkTheme(),
            localizationsDelegates: L10n.localizationsDelegates,
            supportedLocales: L10n.supportedLocales,
            locale: const Locale('zh'),
            home: const CompanionVoicePage(),
          ),
        ),
      );
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('voice-source-follow')), findsNothing);
      expect(
        [
          for (final source in CompanionVoiceSource.values)
            if (find.byKey(ValueKey('voice-source-${source.name}')).evaluate().isNotEmpty) source.name,
        ],
        ['system'],
      );

      // A DeepSeek or followed voice saved before still speaks with the phone's.
      for (final saved in const [
        CompanionVoiceSettings(on: true, source: CompanionVoiceSource.deepseek),
        CompanionVoiceSettings(on: true, follow: true),
      ]) {
        await tester.runAsync(() => container.read(companionVoiceSettingsProvider.notifier).update(saved));
        final used = container.read(companionEffectiveVoiceProvider)!;
        expect((used.source, used.follow, used.on), (CompanionVoiceSource.system, false, true));
      }
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    });
  });
}
