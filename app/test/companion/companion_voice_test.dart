// Her voice: sentences read as they complete, her mouth on the engine's word
// boundaries, silence the moment the person types.

import 'dart:async';
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
import 'package:dsh_app/phone/phone_channel.dart' show PhoneStatus;
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

  group('CompanionPhoneLines', () {
    test('her line before a step is said as the step starts, even without a full stop', () {
      final lines = CompanionPhoneLines();
      // Streaming her first line: nothing whole to say yet.
      expect(lines.read('我先打开计算器哦', steps: 0, running: true), (line: '我先打开计算器哦', say: ''));
      // She opens the calculator: that line is done.
      expect(lines.read('我先打开计算器哦', steps: 1, running: true), (line: '我先打开计算器哦', say: '我先打开计算器哦'));
      // The bubble moves on to the next line; a whole sentence is said as it comes.
      expect(lines.read('我先打开计算器哦\n好，点 7。', steps: 1, running: true), (line: '好，点 7。', say: '好，点 7。'));
      // Two steps with nothing said between: nothing to say, the line stays.
      expect(lines.read('我先打开计算器哦\n好，点 7。', steps: 3, running: true), (line: '好，点 7。', say: ''));
      // The reply is in: the rest is said.
      expect(lines.read('我先打开计算器哦\n好，点 7。\n算好了，是 7', steps: 3, running: false), (line: '算好了，是 7', say: '算好了，是 7'));
    });

    test('a retried round that took words back is not said again', () {
      final lines = CompanionPhoneLines();
      lines.read('好，点 7。', steps: 1, running: true);
      expect(lines.read('好，', steps: 1, running: true).say, '');
    });
  });

  group('companionPhoneUserStops', () {
    PhoneStatus status(List<Map<String, Object?>> tasks) =>
        PhoneStatus.fromMap({'ready': true, 'taskProtocol': 1, 'tasks': tasks});
    Map<String, Object?> task(String session, {bool stopped = false, String? source}) => {
      'sessionId': session,
      'id': 1,
      'active': !stopped,
      'stopped': stopped,
      'stopSource': ?source,
    };

    test('only her running phone work stopped by the person stops her voice', () async {
      final statuses = StreamController<PhoneStatus>();
      final stops = <void>[];
      final sub = companionPhoneUserStops(statuses.stream).listen(stops.add);
      addTearDown(sub.cancel);
      const her = 'companion:room:t:r';
      // Stopped before she was seen running (an earlier run): not this one.
      statuses.add(status([task('companion:room:old:r', stopped: true, source: 'USER')]));
      statuses.add(status([task(her), task('chat-session')]));
      // An engine conversation's task stopped: not hers.
      statuses.add(status([task(her), task('chat-session', stopped: true, source: 'USER')]));
      await pumpEventQueue();
      expect(stops, isEmpty);
      statuses.add(status([task(her, stopped: true, source: 'USER')]));
      // The same stop reported again counts once.
      statuses.add(status([task(her, stopped: true, source: 'USER')]));
      await pumpEventQueue();
      expect(stops, hasLength(1));
    });

    test('her run ending on its own, or the screen going off, does not', () async {
      final statuses = StreamController<PhoneStatus>();
      final stops = <void>[];
      final sub = companionPhoneUserStops(statuses.stream).listen(stops.add);
      addTearDown(sub.cancel);
      statuses.add(status([task('companion:floating:a:r'), task('companion:room:b:r')]));
      statuses.add(
        status([
          task('companion:floating:a:r', stopped: true),
          task('companion:room:b:r', stopped: true, source: 'SCREEN_OFF'),
        ]),
      );
      await pumpEventQueue();
      expect(stops, isEmpty);
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
      const secureChannel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
      final secureValues = <String, String>{};
      final release = Completer<void>();
      var armed = false;
      var secureEntered = 0;
      var secureReturned = 0;
      var heldEntered = 0;
      var heldReturned = 0;
      var timerStarted = false;
      var timerAdvanced = false;
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(secureChannel, (call) async {
        final args = call.arguments as Map;
        final storageKey = args['key']! as String;
        if (call.method == 'read') return secureValues[storageKey];
        if (call.method != 'write') throw UnsupportedError(call.method);
        final value = args['value']! as String;
        secureEntered++;
        if (armed &&
            storageKey == 'companion_voice_preset_keys' &&
            (jsonDecode(value) as Map)['mimo'] == 'mimo-edited') {
          armed = false;
          heldEntered++;
          await release.future;
          heldReturned++;
        }
        secureValues[storageKey] = value;
        secureReturned++;
        return null;
      });
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
      addTearDown(() async {
        // Release while both real controllers and both platform handlers live.
        armed = false;
        if (!release.isCompleted) release.complete();
        await tester.pump();
        if (timerStarted && !timerAdvanced) {
          await tester.pump(const Duration(milliseconds: 400));
        }
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        messenger.setMockMethodCallHandler(secureChannel, null);
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

      // The public notifier seeds A/B/C; only the following UI choices are
      // under the held write. No private Page field or replacement notifier.
      final container = ProviderScope.containerOf(tester.element(find.byType(CompanionVoicePage)));
      final notifier = container.read(companionVoiceSettingsProvider.notifier);
      const seedKeys = {'mimo': 'mimo-key', 'bailian': 'bailian-key', 'openai': 'openai-key'};
      const voices = {'mimo': '茉莉', 'bailian': 'Cherry', 'openai': 'coral'};
      final seed = notifier.update(
        container.read(companionVoiceSettingsProvider)!.copyWith(
          preset: 'mimo',
          presetKeys: seedKeys,
          presetVoices: voices,
        ),
      );
      await tester.pump();
      await seed;
      await tester.pump();
      final prefs = await SharedPreferences.getInstance();
      expect(container.read(companionVoiceSettingsProvider)!.preset, 'mimo');
      expect((jsonDecode(prefs.getString('companion_voice_v1')!) as Map)['preset'], 'mimo');
      expect(jsonDecode(secureValues['companion_voice_preset_keys']!), seedKeys);
      expect(secureReturned, secureEntered);

      // Arrange visibility before arming; no scroll/focus/rebuild after B
      // returns may repair the stale snapshot that the timer must expose.
      await tester.scrollUntilVisible(find.text('OpenAI'), -300, scrollable: find.byType(Scrollable).first);
      await tester.scrollUntilVisible(key, 200, scrollable: find.byType(Scrollable).first);
      await tester.pump();
      expect(find.text('阿里云百炼').hitTestable(), findsOneWidget);
      expect(find.text('OpenAI').hitTestable(), findsOneWidget);
      expect(key.hitTestable(), findsOneWidget);
      final beforeWrites = secureEntered;
      const editedKeys = {'mimo': 'mimo-edited', 'bailian': 'bailian-key', 'openai': 'openai-key'};
      armed = true;
      timerStarted = true;
      await tester.enterText(key, 'mimo-edited');
      await tester.tap(find.text('阿里云百炼'));
      await tester.pump();
      expect(heldEntered, 1);
      expect(heldReturned, 0);
      expect(secureEntered, beforeWrites + 1);
      expect(container.read(companionVoiceSettingsProvider)!.preset, 'bailian');
      expect((jsonDecode(prefs.getString('companion_voice_v1')!) as Map)['preset'], 'bailian');

      await tester.tap(find.text('OpenAI'));
      await tester.pump();
      expect(container.read(companionVoiceSettingsProvider)!.preset, 'openai');
      expect((jsonDecode(prefs.getString('companion_voice_v1')!) as Map)['preset'], 'openai');
      expect(tester.widget<TextField>(key).controller!.text, 'openai-key');
      final coral = find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == 'coral');
      expect(tester.widget<TextField>(coral).controller!.text, 'coral');
      expect(heldReturned, 0);
      expect(secureEntered, beforeWrites + 1, reason: 'C keeps the already published key map');

      // C's frame has completed. Only the old B storage reply now resumes;
      // its completion schedules no Page build of its own.
      release.complete();
      await tester.pump();
      expect(heldReturned, 1);
      expect(secureReturned, secureEntered);
      expect(jsonDecode(secureValues['companion_voice_preset_keys']!), editedKeys);
      await tester.pump(const Duration(milliseconds: 400));
      timerAdvanced = true;
      await tester.pump();
      final saved = container.read(companionVoiceSettingsProvider)!;
      expect(saved.preset, 'openai');
      expect(saved.presetKeys, editedKeys);
      expect(saved.presetVoices, voices);
      expect(jsonDecode(prefs.getString('companion_voice_v1')!), saved.plain());
      expect(jsonDecode(secureValues['companion_voice_preset_keys']!), editedKeys);
      expect(secureEntered, beforeWrites + 1, reason: 'the timer has no stale service fields to save');
      expect(secureReturned, secureEntered);
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
      final replacementWav = <int>[...wav, 1];
      late Completer<void> copying;
      final replacement = StreamController<List<int>>(onListen: () => copying.complete());
      var picks = 0;
      addTearDown(() async {
        // Retire the page before releasing a copy held by a failed assertion.
        await tester.pumpWidget(const SizedBox());
        if (!replacement.isClosed) {
          await tester.runAsync(() async {
            final listening = replacement.hasListener;
            replacement.add(replacementWav);
            final closed = replacement.close();
            // An unselected single-subscription stream need not have a listener.
            if (listening) await closed;
          });
        }
      });
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
            companionVoicePickerProvider.overrideWithValue(() async {
              picks++;
              return picks == 1
                  ? (Stream.value(wav), wav.length)
                  : (replacement.stream, replacementWav.length);
            }),
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

      final container = ProviderScope.containerOf(tester.element(find.byType(CompanionVoicePage)), listen: false);
      // A public settings write establishes on=true before the tested UI actions.
      await tester.runAsync(
        () => container
            .read(companionVoiceSettingsProvider.notifier)
            .update(container.read(companionVoiceSettingsProvider)!.copyWith(on: true)),
      );
      await tester.pump();
      expect(container.read(companionVoiceSettingsProvider)!.on, isTrue);
      expect(container.read(companionVoiceSettingsProvider)!.cloneOn, isTrue);

      await tester.runAsync(() async {
        copying = Completer<void>();
        await tester.tap(find.text('换一段'));
        await copying.future;
      });
      // The picker has returned and keep is awaiting this recording's bytes.
      expect(picks, 2);
      expect(File('${folder.path}/voice-sample.wav').readAsBytesSync(), wav);
      await tester.tap(find.byType(Switch));
      await tester.pump();
      await tester.tap(find.text('预置音色'));
      await tester.pump();
      await tester.tap(find.text('OpenAI'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('voice-source-system')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('voice-source-follow')));
      await tester.pump();
      final chosen = container.read(companionVoiceSettingsProvider)!;
      expect((chosen.on, chosen.cloneOn, chosen.source, chosen.follow, chosen.preset),
          (false, false, CompanionVoiceSource.system, true, 'openai'));

      // The filename already exists: observe the real settings commit, not exists().
      await tester.runAsync(() async {
        final committed = Completer<CompanionVoiceSettings>();
        final subscription = container.listen(companionVoiceSettingsProvider, (_, next) {
          if (next != null && !committed.isCompleted) committed.complete(next);
        });
        try {
          replacement.add(replacementWav);
          await replacement.close();
          await committed.future;
          // update entered before this barrier and writes through the same loaded prefs.
          await SharedPreferences.getInstance();
        } finally {
          subscription.close();
        }
      });
      await tester.pump();
      final saved = container.read(companionVoiceSettingsProvider)!;
      expect(saved.on, isFalse);
      expect(saved.plain(), chosen.plain());
      expect(saved.presetKeys, chosen.presetKeys);
      expect(saved.cloneSample, '${folder.path}/voice-sample.wav');
      expect(await tester.runAsync(() => File(saved.cloneSample).readAsBytes()), replacementWav);
      final prefs = (await tester.runAsync(SharedPreferences.getInstance))!;
      expect(prefs.getBool('companion_voice_enabled'), isFalse);
      expect(jsonDecode(prefs.getString('companion_voice_v1')!), saved.plain());
      expect(sent, hasLength(1));
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
