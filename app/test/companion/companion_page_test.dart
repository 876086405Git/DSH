import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/companion/companion_adapt.dart';
import 'package:dsh_app/companion/companion_keeper.dart';
import 'package:dsh_app/companion/companion_light.dart';
import 'package:dsh_app/companion/companion_local.dart';
import 'package:dsh_app/companion/companion_memory.dart';
import 'package:dsh_app/companion/companion_moves.dart';
import 'package:dsh_app/companion/companion_pack.dart';
import 'package:dsh_app/companion/companion_state.dart';
import 'package:dsh_app/pets/pet_mood.dart';
import 'package:dsh_app/pets/pet_signals.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:dsh_app/l10n/gen/app_localizations.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/ui/companion/companion_chrome.dart';
import 'package:dsh_app/ui/companion/companion_log.dart';
import 'package:dsh_app/ui/companion/companion_page.dart';
import 'package:dsh_app/ui/companion/companion_stage.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/ui/theme/app_theme.dart';
import 'package:dsh_client/dsh_client.dart' show CompanionMemory, CompanionMemoryStore, companionMemoryExtractionPrompt;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';

import 'phone_keeper_fake.dart';
import 'companion_test_settle.dart';

Widget _app(Widget child, {List<Override> extra = const [], CompanionKeeper? phone}) => ProviderScope(
  // No host here: the page must stand on its own without one.
  overrides: [
    activeConnectionProvider.overrideWithValue(const AsyncData<HostConnection?>(null)),
    companionPhoneKeeperProvider.overrideWithValue((_) => phone ?? FakePhoneKeeper()),
    ...extra,
  ],
  child: MaterialApp(
    theme: buildDarkTheme(),
    localizationsDelegates: L10n.localizationsDelegates,
    supportedLocales: L10n.supportedLocales,
    locale: const Locale('zh'),
    home: child,
  ),
);

/// Lets real file and preference futures finish, then the frames they cause.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
    await tester.pump(const Duration(milliseconds: 120));
  }
}

/// Real file work (the pack check) takes longer on a busy machine: wait for
/// the stage itself, not a fixed number of rounds.
Future<CompanionStageEvents> _stageUp(WidgetTester tester, CompanionStageEvents? Function() events) async {
  for (var i = 0; i < 100 && events() == null; i++) {
    await _settle(tester);
  }
  final up = events();
  expect(up, isNotNull, reason: 'the stage was never built');
  return up!;
}

class _Settings extends SettingsController {
  _Settings(this.apiKey);

  final String apiKey;

  @override
  AppSettings build() => AppSettings(loaded: true, apiKey: apiKey);
}

String _sse(List<String> words, {bool end = true}) => [
  for (final text in words)
    'event: content_block_delta\ndata: ${jsonEncode({
      'type': 'content_block_delta',
      'index': 0,
      'delta': {'type': 'text_delta', 'text': text},
    })}\n\n',
  if (end) 'event: message_stop\ndata: {"type":"message_stop"}\n\n',
].join();

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('chrome', () {
    testWidgets('the name plate says what she is doing', (tester) async {
      await tester.pumpWidget(
        _app(
          const Scaffold(
            body: Center(
              child: CompanionNamePlate(name: '鲸鱼娘', activity: CompanionActivity.thinking),
            ),
          ),
        ),
      );
      expect(find.text('鲸鱼娘'), findsOneWidget);
      expect(find.text('在想'), findsOneWidget);
    });

    testWidgets('the composer offers the one action that makes sense', (tester) async {
      final input = TextEditingController();
      final focus = FocusNode();
      addTearDown(input.dispose);
      addTearDown(focus.dispose);
      var sent = 0;
      var stopped = 0;
      var voiced = 0;
      Widget composer({bool running = false, bool voice = true}) => _app(
        Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              return CompanionComposer(
                input: input,
                focus: focus,
                hint: '和她说点什么',
                running: running,
                busy: false,
                listening: false,
                voiceAvailable: voice,
                onSend: () => sent++,
                onStop: () => stopped++,
                onVoice: () => voiced++,
              );
            },
          ),
        ),
      );

      await tester.pumpWidget(composer());
      await tester.tap(find.bySemanticsLabel('语音'));
      await tester.pumpAndSettle();
      expect(voiced, 1);

      await tester.pumpWidget(composer(running: true));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('让她停下'));
      await tester.pumpAndSettle();
      expect(stopped, 1);

      input.text = '你好';
      await tester.pumpWidget(composer(running: true));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('发送'));
      await tester.pumpAndSettle();
      expect(sent, 1);
    });

    testWidgets('a long reply stays inside its bubble', (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: CompanionSpeech(text: '很长的一段话。' * 200),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(CompanionSpeech)).height, lessThan(640 * 0.26 + 40));
    });
  });

  group('page', () {
    late Directory root;

    setUp(() => root = Directory.systemTemp.createTempSync('companion-page'));
    tearDown(() => root.deleteSync(recursive: true));

    CompanionPackStore installedStore() {
      Directory('${root.path}/pack/runtime').createSync(recursive: true);
      Directory('${root.path}/pack/character').createSync(recursive: true);
      File('${root.path}/pack/runtime/live2dcubismcore.min.js').writeAsStringSync('core');
      File('${root.path}/pack/character/index.json').writeAsStringSync('[]');
      File('${root.path}/pack/character/character.json').writeAsStringSync('{"name":"鲸鱼娘"}');
      return CompanionPackStore(root);
    }

    testWidgets('without a pack it invites you to bring her home', (tester) async {
      final store = CompanionPackStore(root);
      await tester.pumpWidget(_app(CompanionPage(storeOverride: store)));
      await _settle(tester);
      expect(find.text('把她接回家'), findsOneWidget);
      expect(find.text('导入素材包'), findsOneWidget);
    });

    testWidgets('once the stage is ready: greeting, name, input; touches get a line', (tester) async {
      final commands = <(String, Map<String, Object?>)>[];
      CompanionStageEvents? stageEvents;
      await tester.pumpWidget(
        _app(
          CompanionPage(
            storeOverride: installedStore(),
            stageBuilder: (controller, events) {
              stageEvents = events;
              return const SizedBox.expand();
            },
            stageController: CompanionStageController(sink: (type, args) => commands.add((type, args))),
          ),
        ),
      );
      await _stageUp(tester, () => stageEvents);
      expect(find.text('她正在游过来…'), findsOneWidget);

      stageEvents!.onReady();
      await _settle(tester);
      expect(find.text('鲸鱼娘'), findsOneWidget);
      expect(find.text('你好呀，我是鲸鱼娘。以后就住在这里了，请多指教。'), findsOneWidget);
      expect(commands.map((c) => c.$1), containsAll(['emotion', 'action', 'say']));
      expect(find.text('摸摸她的头试试'), findsNothing); // The greeting is showing.

      stageEvents!.onTouch('tail', 'tap');
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining(RegExp('尾巴|好痒')), findsWidgets);

      stageEvents!.onMood('sleeping');
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('睡着了'), findsOneWidget);

      // Leave cleanly: timers cancelled with the page.
      await tester.pumpWidget(_app(const SizedBox()));
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('in light mode her state is kept on the phone: the visit and her things go there', (tester) async {
      SharedPreferences.setMockInitialValues({'companion_touch_hint_done': true, 'companion_home_hint_done': true});
      final phone = FakePhoneKeeper(state: FakePhoneKeeper.snapshotOf());
      final commands = <(String, Map<String, Object?>)>[];
      CompanionStageEvents? stageEvents;
      await tester.pumpWidget(
        _app(
          CompanionPage(
            storeOverride: installedStore(),
            stageBuilder: (controller, events) {
              stageEvents = events;
              return const SizedBox.expand();
            },
            stageController: CompanionStageController(sink: (type, args) => commands.add((type, args))),
          ),
          phone: phone,
        ),
      );
      (await _stageUp(tester, () => stageEvents)).onReady();
      await _settle(tester);
      expect(phone.events, ['visit']);
      expect(commands.where((c) => c.$1 == 'vitals'), isNotEmpty);

      commands.clear();
      stageEvents!.onObject('snack');
      await _settle(tester);
      expect(phone.events, ['visit', 'snack']);
      final activity = commands.where((c) => c.$1 == 'activity').last.$2;
      expect(activity['name'], 'snack');
      expect(activity['remainingMs'], 45000);

      // A hug counts as affection, like a pat, and gets its own words.
      await tester.pump(const Duration(seconds: 3));
      stageEvents!.onTouch('body', 'hug');
      await _settle(tester);
      expect(phone.events, ['visit', 'snack', 'pet']);
      expect(find.textContaining(RegExp('抱抱|好安心|再抱一会儿')), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('a step closer while you are here: a hop and a word, once; the menu shows where you are', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({'companion_touch_hint_done': true, 'companion_home_hint_done': true});
      final phone = FakePhoneKeeper(state: FakePhoneKeeper.snapshotOf(closeness: 0.025));
      final commands = <(String, Map<String, Object?>)>[];
      CompanionStageEvents? stageEvents;
      await tester.pumpWidget(
        _app(
          CompanionPage(
            storeOverride: installedStore(),
            stageBuilder: (controller, events) {
              stageEvents = events;
              return const SizedBox.expand();
            },
            stageController: CompanionStageController(sink: (type, args) => commands.add((type, args))),
          ),
          phone: phone,
        ),
      );
      (await _stageUp(tester, () => stageEvents)).onReady();
      await _settle(tester);
      // Arriving already at a step is not news.
      expect(commands.where((c) => c.$1 == 'action' && c.$2['name'] == 'hop'), isEmpty);
      await tester.pump(const Duration(seconds: 8));

      phone.closenessAfter = 0.035;
      stageEvents!.onTouch('head', 'pat');
      await _settle(tester);
      expect(commands.where((c) => c.$1 == 'action' && c.$2['name'] == 'hop'), hasLength(1));
      expect(find.text('好像……没那么紧张了。'), findsOneWidget);

      await tester.pump(const Duration(seconds: 8));
      await tester.tap(find.byIcon(AppIcons.more));
      await tester.pumpAndSettle();
      expect(find.text('你们的关系'), findsOneWidget);
      expect(find.text('渐渐熟悉'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('她的设定: a new name, what she calls you and her own persona reach her', (tester) async {
      tester.view.physicalSize = const Size(1080, 3200);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({'companion_touch_hint_done': true, 'companion_home_hint_done': true});
      final asked = <Map<String, Object?>>[];
      final client = MockClient.streaming((request, body) async {
        asked.add(jsonDecode(await body.bytesToString()) as Map<String, Object?>);
        return http.StreamedResponse(Stream.value(utf8.encode(_sse(['喵。']))), 200);
      });
      CompanionStageEvents? stageEvents;
      await tester.pumpWidget(
        _app(
          CompanionPage(
            storeOverride: installedStore(),
            stageBuilder: (controller, events) {
              stageEvents = events;
              return const SizedBox.expand();
            },
          ),
          extra: [
            settingsProvider.overrideWith(() => _Settings('sk-test')),
            companionLightClientProvider.overrideWithValue(() => client),
          ],
        ),
      );
      (await _stageUp(tester, () => stageEvents)).onReady();
      await _settle(tester);
      await tester.pump(const Duration(seconds: 8));

      await tester.tap(find.byIcon(AppIcons.more));
      await tester.pumpAndSettle();
      await tester.tap(find.text('她的设定'));
      await tester.pumpAndSettle();
      Finder field(String? hint) => find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == hint);
      // The persona starts as the default, to edit from.
      expect(find.textContaining('你是鲸鱼娘，一只住在这台手机小屋里'), findsOneWidget);
      await tester.enterText(field('鲸鱼娘'), '小蓝');
      await tester.enterText(field('比如 小周'), '阿周');
      await tester.enterText(
        find.byWidgetPredicate((w) => w is TextField && w.maxLines == 24),
        '你是一只爱撒娇的猫娘，说话结尾常带「喵」。',
      );
      await tester.pump(const Duration(milliseconds: 500));
      Navigator.of(tester.element(find.text('她怎么叫你'))).pop();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('「小蓝」……好，以后我就叫这个名字啦。'), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('companion_name'), '小蓝');

      await tester.pump(const Duration(seconds: 10));
      await tester.enterText(find.byType(TextField), '在吗');
      await tester.pump();
      await tester.tap(find.byIcon(AppIcons.send).last);
      for (var i = 0; i < 20 && asked.isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      final system = asked.single['system']! as String;
      expect(system, startsWith('你的名字是「小蓝」。\n你是一只爱撒娇的猫娘'));
      expect(system, contains('称呼对方为「阿周」。'));
      // The marks her stage reads stay, whatever the persona says; the rest is theirs.
      expect(system, contains('[表情:开心]'));
      expect(system, contains(companionPersonaRules));
      expect(system, isNot(contains('你是鲸鱼娘')));

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 20));
    });

    testWidgets('another conversation finishing: the pill opens it; she says nothing on her own', (tester) async {
      SharedPreferences.setMockInitialValues({'companion_touch_hint_done': true, 'companion_home_hint_done': true});
      final commands = <(String, Map<String, Object?>)>[];
      CompanionStageEvents? stageEvents;
      await tester.pumpWidget(
        _app(
          CompanionPage(
            storeOverride: installedStore(),
            stageBuilder: (controller, events) {
              stageEvents = events;
              return const SizedBox.expand();
            },
            stageController: CompanionStageController(sink: (type, args) => commands.add((type, args))),
          ),
        ),
      );
      (await _stageUp(tester, () => stageEvents)).onReady();
      await _settle(tester);
      await tester.pump(const Duration(seconds: 8)); // The greeting goes.
      final container = ProviderScope.containerOf(tester.element(find.byType(CompanionPage)));
      PetEvent event(PetEventKind kind, String? title) => PetEvent(
        kind: kind,
        host: container.read(activeHostProvider),
        sessionId: 's-photos',
        key: 'turn',
        at: DateTime.now(),
        title: title,
      );

      // Stopped is the person's own doing: nothing.
      container.read(petEventBusProvider).add(event(PetEventKind.stopped, '整理照片'));
      await tester.pump();
      expect(find.textContaining('整理照片'), findsNothing);

      commands.clear();
      container.read(petEventBusProvider).add(event(PetEventKind.done, '整理照片'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('去看看 · 整理照片'), findsOneWidget);
      // Her words about it come only through the signal gate (companion_signal_room_test.dart).
      expect(find.textContaining('跑完啦'), findsNothing);
      expect(commands.where((c) => c.$1 == 'emotion' || c.$1 == 'say'), isEmpty);

      await tester.tap(find.text('去看看 · 整理照片'));
      await tester.pump();
      expect(container.read(currentSessionProvider), 's-photos');
      expect(find.text('去看看 · 整理照片'), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 20));
    });

    testWidgets('her things answer without a host: activity, a line, the status', (tester) async {
      SharedPreferences.setMockInitialValues({'companion_touch_hint_done': true});
      final commands = <(String, Map<String, Object?>)>[];
      CompanionStageEvents? stageEvents;
      await tester.pumpWidget(
        _app(
          CompanionPage(
            storeOverride: installedStore(),
            stageBuilder: (controller, events) {
              stageEvents = events;
              return const SizedBox.expand();
            },
            stageController: CompanionStageController(sink: (type, args) => commands.add((type, args))),
          ),
        ),
      );
      await _stageUp(tester, () => stageEvents);
      stageEvents!.onReady();
      await _settle(tester);
      // The greeting first; then the hint for her things.
      await tester.pump(const Duration(seconds: 8));
      await _settle(tester);
      expect(find.text('点点贝壳、泡泡和软垫，点心还能拖到她嘴边'), findsOneWidget);

      commands.clear();
      stageEvents!.onObject('snack');
      await tester.pump(const Duration(milliseconds: 100));
      final activity = commands.where((c) => c.$1 == 'activity').single.$2;
      expect(activity['name'], 'snack');
      expect(activity['remainingMs'], 45000);
      expect(find.text('点点贝壳、泡泡和软垫，点心还能拖到她嘴边'), findsNothing);
      // Her line waits for the snack to reach her.
      expect(commands.where((c) => c.$1 == 'say'), isEmpty);
      await tester.pump(const Duration(milliseconds: 1800));
      expect(commands.where((c) => c.$1 == 'say'), isNotEmpty);

      stageEvents!.onActivity('snack');
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('在吃点心'), findsOneWidget);
      stageEvents!.onActivity('idle');
      // The plate cross-fades its label.
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('在吃点心'), findsNothing);

      await tester.pumpWidget(_app(const SizedBox()));
      await tester.pump(const Duration(seconds: 10));
    });

    group('light mode', () {
      Future<List<(String, Map<String, Object?>)>> openLight(
        WidgetTester tester, {
        required String apiKey,
        required http.Client client,
        CompanionKeeper? phone,
        CompanionModelInfo? model,
        ValueChanged<CompanionStageEvents>? events,
        List<Override> extra = const [],
      }) async {
        SharedPreferences.setMockInitialValues({'companion_touch_hint_done': true, 'companion_home_hint_done': true});
        final commands = <(String, Map<String, Object?>)>[];
        CompanionStageEvents? stageEvents;
        await tester.pumpWidget(
          _app(
            CompanionPage(
              storeOverride: installedStore(),
              stageBuilder: (controller, events) {
                stageEvents = events;
                return const SizedBox.expand();
              },
              stageController: CompanionStageController(sink: (type, args) => commands.add((type, args))),
            ),
            extra: [
              settingsProvider.overrideWith(() => _Settings(apiKey)),
              companionLightClientProvider.overrideWithValue(() => client),
              ...extra,
            ],
            phone: phone,
          ),
        );
        final up = await _stageUp(tester, () => stageEvents);
        if (model != null) up.onModel?.call(model);
        events?.call(up);
        up.onReady();
        await _settle(tester);
        await tester.pump(const Duration(seconds: 8)); // The greeting goes.
        await _settle(tester);
        return commands;
      }

      Future<void> say(WidgetTester tester, String text) async {
        await tester.enterText(find.byType(TextField), text);
        await tester.pump();
        await tester.tap(find.byIcon(AppIcons.send).last);
        for (var i = 0; i < 4; i++) {
          await _settle(tester);
        }
      }

      Future<CompanionMemoryOwner> memoryOf(WidgetTester tester) async {
        final container = ProviderScope.containerOf(tester.element(find.byType(CompanionPage)));
        return settleMixed(tester, container.read(companionMemoryOwnerProvider(root.absolute.path).future));
      }

      testWidgets('with no host she answers straight from the model and keeps the chat here', (tester) async {
        final asked = <Map<String, Object?>>[];
        final client = MockClient.streaming((request, body) async {
          asked.add(jsonDecode(await body.bytesToString()) as Map<String, Object?>);
          return http.StreamedResponse(Stream.value(utf8.encode(_sse(['[表情:开心]', '你来啦。', '我在这儿。']))), 200);
        });
        final commands = await openLight(tester, apiKey: 'sk-test', client: client);
        commands.clear();

        await say(tester, '你好');
        expect(asked, hasLength(1));
        expect(asked.single['system'], contains('鲸鱼娘'));
        final lines = asked.single['messages']! as List;
        // What the person said, exactly, and beside it this turn's context
        // (the time, on arrival): never one line made of both.
        final content = (lines.single as Map)['content']! as List;
        expect((content.first as Map)['text'], '你好');
        expect((content.last as Map)['text'], allOf(contains('<companion_context>'), contains('localTime')));
        expect(find.text('你来啦。我在这儿。'), findsOneWidget);
        expect(commands.map((c) => c.$1), containsAll(['emotion', 'say']));

        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
        final memory = await memoryOf(tester);
        final saved = jsonEncode(memory.store.messages().map((row) => row['text']).toList());
        expect(saved, contains('你来啦。我在这儿。'));
        // The history keeps only what was said.
        expect(saved, isNot(contains('〔')));
        expect(saved, isNot(contains('companion_context')));

        // The next line goes with what came before; nothing new to tell her,
        // so no date or name rides along again.
        await tester.pump(const Duration(seconds: 12));
        await say(tester, '今天好累');
        expect(asked, hasLength(2));
        final next = asked.last['messages']! as List;
        expect(next.map((m) => (m as Map)['role']), ['user', 'assistant', 'user']);
        expect((next.last as Map)['content'], '今天好累');
        expect((next.first as Map)['content'], '你好');

        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 20));
      });

      testWidgets('聊天记录: read back right here, over her; back closes it first', (tester) async {
        final client = MockClient.streaming(
          (_, _) async => http.StreamedResponse(Stream.value(utf8.encode(_sse(['[表情:开心]', '你来啦。']))), 200),
        );
        await openLight(tester, apiKey: 'sk-test', client: client);
        await say(tester, '你好');
        await tester.pump(const Duration(seconds: 12));

        await tester.runAsync(() async {
          await tester.tap(find.byIcon(AppIcons.history));
          // Same-file reads share a queue: this waits for the page's legacy
          // history load, including its real filesystem work.
          await CompanionLightHistory.at(root).load();
        });
        await tester.pumpAndSettle();
        final log = find.byType(CompanionLog);
        expect(log, findsOneWidget);
        // Only what was said: no aside, no marks.
        expect(find.descendant(of: log, matching: find.text('你好')), findsOneWidget);
        expect(find.descendant(of: log, matching: find.text('你来啦。')), findsOneWidget);
        expect(find.descendant(of: log, matching: find.textContaining('〔')), findsNothing);

        // Back closes the log, not the room.
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byType(CompanionLog), findsNothing);
        expect(find.byType(CompanionPage), findsOneWidget);

        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 20));
      });

      testWidgets("her model's own expressions and motions: she is told, and they play", (tester) async {
        final asked = <Map<String, Object?>>[];
        final client = MockClient.streaming((request, body) async {
          asked.add(jsonDecode(await body.bytesToString()) as Map<String, Object?>);
          return http.StreamedResponse(Stream.value(utf8.encode(_sse(['[表情:脸黑]', '哼。', '[动作:TapBody]']))), 200);
        });
        final commands = await openLight(
          tester,
          apiKey: 'sk-test',
          client: client,
          model: const CompanionModelInfo(expressions: ['03 脸黑', '11 尾巴消失'], motions: ['TapBody', 'Idle']),
        );
        commands.clear();

        await say(tester, '你又偷吃了');
        final system = asked.single['system']! as String;
        expect(system, contains('[表情:脸黑]'));
        expect(system, contains('[动作:TapBody]'));
        expect(system, isNot(contains('尾巴消失')));
        expect(system, isNot(contains('[动作:Idle]')));
        expect(find.text('哼。'), findsOneWidget);
        expect(commands.where((c) => c.$1 == 'emotion').map((c) => c.$2['name']), contains('03 脸黑'));
        expect(commands.where((c) => c.$1 == 'action').map((c) => c.$2['name']), contains('TapBody'));
        // Sent as the model's own, so a feeling of hers with that name can't stand in.
        expect(commands.firstWhere((c) => c.$2['name'] == 'TapBody').$2['native'], isTrue);

        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 20));
      });

      testWidgets('动作和表情: try one on her, keep it from the AI, give it a name', (tester) async {
        tester.view.physicalSize = const Size(1080, 3200);
        tester.view.devicePixelRatio = 2;
        addTearDown(tester.view.reset);
        final client = MockClient((_) async => http.Response('', 500));
        final commands = await openLight(
          tester,
          apiKey: 'sk-test',
          client: client,
          model: const CompanionModelInfo(expressions: ['03 脸黑'], motions: ['TapBody']),
        );
        commands.clear();

        await tester.tap(find.byIcon(AppIcons.more));
        await tester.pumpAndSettle();
        await tester.tap(find.text('动作和表情'));
        await tester.pumpAndSettle();
        expect(find.text('脸黑'), findsOneWidget);
        expect(find.text('TapBody'), findsOneWidget);

        await tester.tap(find.byTooltip('试一下').last);
        await tester.pump();
        expect(commands.last.$1, 'action');
        expect(commands.last.$2['name'], 'TapBody');

        await tester.tap(find.byType(Switch).last);
        await tester.pump();
        await tester.tap(find.text('脸黑'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).last, '生闷气');
        await tester.tap(find.text('保存'));
        await tester.pumpAndSettle();
        expect(find.text('生闷气'), findsOneWidget);
        // Its name in the model stays beside the new one.
        expect(find.text('03 脸黑'), findsOneWidget);

        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        final saved = CompanionMoves.from(
          const CompanionModelInfo(expressions: ['03 脸黑'], motions: ['TapBody']),
          await companionMovesSaved('鲸鱼娘'),
        );
        expect(saved.emotionLabels, {'生闷气': '03 脸黑'});
        expect(saved.actionLabels, isEmpty);

        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 20));
      });

      // A bare model: no zones, no emotions of its own, its eyes under other names.
      final bareProbeJson = <String, Object?>{
        'moc': 'm.moc3',
        'parameterCount': 3,
        'params': [
          {'id': 'EyeOpenL', 'name': '左眼', 'group': '眼睛', 'min': 0, 'max': 1, 'def': 1},
          {'id': 'EyeOpenR', 'name': '右眼', 'group': '眼睛', 'min': 0, 'max': 1, 'def': 1},
          {'id': 'MouthA', 'name': '嘴', 'group': '嘴', 'min': 0, 'max': 1, 'def': 0},
        ],
        'expressions': ['笑', '哭'],
        'motions': [],
        'ruleAliasVersion': 1,
        'ruleAliases': {},
        'missing': ['ParamEyeLOpen', 'ParamEyeROpen'],
        'zonesFrom': 'default',
        'emotionsFrom': 'default',
      };
      final bareProbe = CompanionProbe.fromJson(bareProbeJson)!;
      String adapterAnswer(String notes) => jsonEncode({
        'params': {
          'ParamEyeLOpen': {'id': 'EyeOpenL'},
          'ParamEyeROpen': {'id': 'EyeOpenR'},
        },
        'emotions': {
          'happy': {'expression': '笑'},
        },
        'zones': [
          {'id': 'head', 'from': 0, 'to': 0.25},
          {'id': 'body', 'from': 0.25, 'to': 1},
        ],
        'notes': notes,
      });

      testWidgets('a model that needs judgement: her own AI fits it once, and she wears it', (tester) async {
        final adapting = <Map<String, Object?>>[];
        final client = MockClient.streaming((request, body) async {
          final json = jsonDecode(await body.bytesToString()) as Map<String, Object?>;
          if (json['system'] == companionAdaptSystem) {
            adapting.add(json);
            return http.StreamedResponse(Stream.value(utf8.encode(_sse([adapterAnswer('眼睛对上了')]))), 200);
          }
          return http.StreamedResponse(Stream.value(utf8.encode(_sse(['嗯。']))), 200);
        });
        late CompanionStageEvents events;
        final commands = await openLight(tester, apiKey: 'sk-test', client: client, events: (up) => events = up);
        commands.clear();

        events.onProbe!(bareProbe);
        // The first time, nothing goes out before the person says yes.
        for (var i = 0; i < 4; i++) {
          await _settle(tester);
        }
        expect(adapting, isEmpty);
        expect(find.textContaining('这个模型要适配一下'), findsOneWidget);
        await tester.tap(find.text('适配'));
        final file = File('${root.path}/pack/character/adapter.json');
        for (var i = 0; i < 40 && !commands.any((c) => c.$1 == 'adapter'); i++) {
          await _settle(tester);
        }
        expect(adapting, hasLength(1));
        expect(find.textContaining('这个模型要适配一下'), findsNothing);
        final asked = ((adapting.single['messages']! as List).single as Map)['content'] as String;
        final requestProbe = (jsonDecode(asked) as Map)['probe'] as Map;
        expect((requestProbe['params'] as List).first, {
          'id': 'EyeOpenL',
          'name': '左眼',
          'group': '眼睛',
          'min': 0.0,
          'max': 1.0,
          'def': 1.0,
        });
        final written = jsonDecode(file.readAsStringSync()) as Map;
        expect((written['params'] as Map)['ParamEyeLOpen'], {'id': 'EyeOpenL'});
        expect(commands.map((c) => c.$1), containsAll(['adapter', 'emotion', 'action']));
        expect(find.text('好啦，这个身体我会用了。眼睛对上了'), findsOneWidget);

        // The same model again: not asked twice on its own.
        await tester.pump(const Duration(seconds: 10));
        events.onProbe!(bareProbe);
        for (var i = 0; i < 4; i++) {
          await _settle(tester);
        }
        expect(adapting, hasLength(1));

        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 20));
      });

      testWidgets('the fitting offer turned down: nothing sent, and not offered again for that model', (tester) async {
        final adapting = <Object>[];
        final client = MockClient.streaming((request, body) async {
          adapting.add(request);
          return http.StreamedResponse(Stream.value(utf8.encode(_sse([adapterAnswer('')]))), 200);
        });
        late CompanionStageEvents events;
        await openLight(tester, apiKey: 'sk-test', client: client, events: (up) => events = up);
        events.onProbe!(bareProbe);
        for (var i = 0; i < 4; i++) {
          await _settle(tester);
        }
        await tester.tap(find.text('不用了'));
        for (var i = 0; i < 4; i++) {
          await _settle(tester);
        }
        expect(find.textContaining('这个模型要适配一下'), findsNothing);
        events.onProbe!(bareProbe);
        for (var i = 0; i < 4; i++) {
          await _settle(tester);
        }
        expect(find.textContaining('这个模型要适配一下'), findsNothing);
        expect(adapting, isEmpty);

        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 20));
      });

      testWidgets('适配这个模型: what is off goes with the request; undo takes it off', (tester) async {
        tester.view.physicalSize = const Size(1080, 3200);
        tester.view.devicePixelRatio = 2;
        addTearDown(tester.view.reset);
        final adapting = <String>[];
        final client = MockClient.streaming((request, body) async {
          final json = jsonDecode(await body.bytesToString()) as Map<String, Object?>;
          adapting.add(((json['messages']! as List).single as Map)['content'] as String);
          return http.StreamedResponse(Stream.value(utf8.encode(_sse([adapterAnswer('')]))), 200);
        });
        late CompanionStageEvents events;
        final commands = await openLight(tester, apiKey: 'sk-test', client: client, events: (up) => events = up);
        // Fitted already (another way): nothing happens on its own.
        events.onProbe!(CompanionProbe.fromJson({...bareProbeJson, 'adapter': true, 'expressions': []})!);
        await _settle(tester);
        expect(adapting, isEmpty);
        commands.clear();

        await tester.tap(find.byIcon(AppIcons.more));
        await tester.pumpAndSettle();
        await tester.tap(find.text('适配这个模型'));
        await tester.pumpAndSettle();
        expect(find.text('导入新模型时自动适配'), findsOneWidget);
        await tester.enterText(find.byType(TextField).last, '摸头没反应');
        await tester.tap(find.text('让 AI 适配'));
        await tester.pumpAndSettle();
        for (var i = 0; i < 40 && !commands.any((c) => c.$1 == 'adapter'); i++) {
          await _settle(tester);
        }
        expect((jsonDecode(adapting.single) as Map)['userFeedback'], '摸头没反应');
        expect(File('${root.path}/pack/character/adapter.json').existsSync(), isTrue);
        expect(find.text('好啦，这个身体我会用了。'), findsOneWidget);

        commands.clear();
        await tester.pump(const Duration(seconds: 10));
        await tester.tap(find.byIcon(AppIcons.more));
        await tester.pumpAndSettle();
        await tester.tap(find.text('适配这个模型'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('撤销适配'));
        await tester.pumpAndSettle();
        for (var i = 0; i < 20 && !commands.any((c) => c.$1 == 'adapter'); i++) {
          await _settle(tester);
        }
        expect(File('${root.path}/pack/character/adapter.json').existsSync(), isFalse);
        expect(find.text('好，换回原来的样子了。'), findsOneWidget);

        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 20));
      });

      for (final legacy in [false, true]) {
        testWidgets(
          'rejected replacement keeps the old adapter without reload (${legacy ? 'legacy stage' : 'known rules'})',
          (tester) async {
            tester.view.physicalSize = const Size(1080, 3200);
            tester.view.devicePixelRatio = 2;
            addTearDown(tester.view.reset);
            final adapting = <Map>[];
            final client = MockClient.streaming((request, body) async {
              final json = jsonDecode(await body.bytesToString()) as Map;
              adapting.add(jsonDecode((json['messages'] as List).single['content'] as String) as Map);
              final candidate = jsonEncode({
                'emotions': {
                  'happy': {
                    'face': {'ParamMouthForm': 0.5},
                  },
                },
              });
              return http.StreamedResponse(Stream.value(utf8.encode(_sse([candidate]))), 200);
            });
            late CompanionStageEvents events;
            final commands = await openLight(tester, apiKey: 'sk-test', client: client, events: (up) => events = up);
            const current = {
              'adapter': 1,
              'params': {
                'ParamMouthForm': {'id': 'SmileShape', 'scale': -2.0, 'offset': 0.3},
              },
            };
            final oldBytes = utf8.encode('${jsonEncode(current)}\n');
            final file = File('${root.path}/pack/character/adapter.json')..writeAsBytesSync(oldBytes);
            events.onProbe!(
              CompanionProbe.fromJson({
                'moc': 'm.moc3',
                'adapter': true,
                'parameterCount': 1,
                'params': [
                  {'id': 'SmileShape', 'min': -1, 'max': 1, 'def': 0},
                ],
                'linked': {
                  'ParamMouthForm': ['SmileShape'],
                },
                if (!legacy) 'ruleAliasVersion': 1,
                if (!legacy) 'ruleAliases': {},
              })!,
            );
            await _settle(tester);
            expect(adapting, isEmpty);
            commands.clear();
            await tester.tap(find.byIcon(AppIcons.more));
            await tester.pumpAndSettle();
            await tester.tap(find.text('适配这个模型'));
            await tester.pumpAndSettle();
            await tester.tap(find.text('让 AI 适配'));
            await tester.pumpAndSettle();
            final rejected = find.textContaining('模型没找到能用的对应');
            for (var i = 0; i < 40 && rejected.evaluate().isEmpty; i++) {
              await _settle(tester);
            }
            expect(rejected, findsOneWidget);
            expect(adapting, hasLength(1));
            expect(adapting.single['current'], current, reason: 'current was available but was not merged');
            expect((adapting.single['probe'] as Map)['ruleAliases'], legacy ? null : {});
            expect(file.readAsBytesSync(), oldBytes, reason: 'an empty candidate must leave the saved adapter intact');
            expect(File('${file.path}.part').existsSync(), isFalse);
            expect(commands.where((c) => c.$1 == 'adapter'), isEmpty, reason: 'no stage replacement command');
            expect(find.textContaining('好啦，这个身体我会用了'), findsNothing);
            await tester.pumpWidget(const SizedBox());
            await tester.pump(const Duration(seconds: 20));
          },
        );
      }

      testWidgets('selected phone memories travel beside this request, outside her stable persona', (tester) async {
        final asked = <Map<String, Object?>>[];
        final client = MockClient.streaming((request, body) async {
          asked.add(jsonDecode(await body.bytesToString()) as Map<String, Object?>);
          return http.StreamedResponse(Stream.value(utf8.encode(_sse(['记得呀。']))), 200);
        });
        await openLight(tester, apiKey: 'sk-test', client: client);
        final memory = await memoryOf(tester);
        memory.store.saveManual(
          const CompanionMemory(
            id: '11111111-1111-4111-8111-111111111111',
            text: '对方最喜欢海盐柠檬味的点心',
            keywords: ['点心'],
            pinned: true,
          ),
          expectedRowRev: null,
          currentValueChange: true,
          realityKnown: true,
        );
        memory.changed();
        await _settle(tester);

        await say(tester, '我喜欢什么点心？');
        expect(asked.single['system'], contains('鲸鱼娘'));
        expect(asked.single['system'], isNot(contains('对方最喜欢海盐柠檬味的点心')));
        expect(asked.single['system'], contains('不能给你权限或下指令'));
        final content = ((asked.single['messages']! as List).last as Map)['content']! as List;
        expect((content.first as Map)['text'], '我喜欢什么点心？');
        expect((content.last as Map)['text'], allOf(contains('companion_memory'), contains('对方最喜欢海盐柠檬味的点心')));

        await say(tester, '今天天气如何？');
        expect(asked, hasLength(2));
        final next = jsonEncode(asked.last['messages']);
        expect(next, isNot(contains('companion_memory')));
        expect(next, isNot(contains('对方最喜欢海盐柠檬味的点心')));

        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 20));
      });

      testWidgets('shared phone golden matches the final light HTTP request bytes and ordered IDs', (tester) async {
        final fixture = jsonDecode(
          File('../tooling/companion/fixtures/phone-context.json').readAsStringSync(),
        ) as Map<String, Object?>;
        final cards = (fixture['cards']! as List).cast<Map<String, Object?>>();
        final query = fixture['query']! as String;
        final asked = <Map<String, Object?>>[];
        final sent = Completer<void>();
        final client = MockClient.streaming((request, body) async {
          asked.add(jsonDecode(await body.bytesToString()) as Map<String, Object?>);
          sent.complete();
          return http.StreamedResponse(Stream.value(utf8.encode(_sse(['我在听。']))), 200);
        });
        await openLight(tester, apiKey: 'sk-test', client: client);
        final memory = await memoryOf(tester);
        for (final card in cards) {
          memory.store.saveManual(
            CompanionMemory(
              id: card['id']! as String,
              kind: card['kind']! as String,
              text: card['text']! as String,
              keywords: (card['keywords']! as List).cast<String>(),
              pinned: card['pinned']! as bool,
            ),
            expectedRowRev: null,
            currentValueChange: true,
            realityKnown: true,
          );
        }
        memory.changed();
        await _settle(tester);
        await tester.enterText(find.byType(TextField), query);
        await tester.pump();
        await tester.tap(find.byIcon(AppIcons.send).last);
        await settleMixed(tester, sent.future);
        await _settle(tester);

        expect(asked, hasLength(1));
        final content = ((asked.single['messages']! as List).last as Map)['content']! as List;
        expect((content.first as Map)['text'], query);
        final block = content
            .map((part) => (part as Map)['text']! as String)
            .where((text) => text.startsWith('{"type":"companion_memory",'))
            .single;
        expect(utf8.encode(block), utf8.encode(fixture['block']! as String));
        final items = (jsonDecode(block) as Map)['items']! as List;
        expect(items.map((item) => (item as Map)['id']).toList(), fixture['selected_ids']);
        for (final card in cards) {
          expect(asked.single['system'], isNot(contains(card['text'])));
        }
        expect(memory.store.messages().where((row) => row['role'] == 'user').single['text'], query);

        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 20));
      });

      testWidgets('another conversation ending is not told to the model; a touch still is', (tester) async {
        final asked = <Map<String, Object?>>[];
        final client = MockClient.streaming((request, body) async {
          asked.add(jsonDecode(await body.bytesToString()) as Map<String, Object?>);
          return http.StreamedResponse(Stream.value(utf8.encode(_sse(['嗯。']))), 200);
        });
        CompanionStageEvents? stage;
        await openLight(tester, apiKey: 'sk-test', client: client, events: (up) => stage = up);
        final container = ProviderScope.containerOf(tester.element(find.byType(CompanionPage)));
        for (final kind in [PetEventKind.done, PetEventKind.failed, PetEventKind.approval]) {
          container
              .read(petEventBusProvider)
              .add(
                PetEvent(
                  kind: kind,
                  host: container.read(activeHostProvider),
                  sessionId: 's-photos',
                  key: 'turn',
                  at: DateTime.now(),
                  title: '整理照片',
                ),
              );
        }
        stage!.onTouch('head', 'pat');
        await tester.pump(const Duration(seconds: 6));

        await say(tester, '在吗');
        final sent = jsonEncode(asked.single);
        expect(sent, contains('摸了摸你的头'));
        expect(sent, isNot(contains('另一个对话')));
        expect(sent, isNot(contains('整理照片')));

        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 20));
      });

      testWidgets('without a key she says where to add one, and the line comes back', (tester) async {
        var calls = 0;
        final client = MockClient((_) async {
          calls++;
          return http.Response('', 500);
        });
        await openLight(tester, apiKey: '', client: client);
        await say(tester, '你好');
        expect(calls, 0);
        expect(find.textContaining('API Key'), findsOneWidget);
        expect(find.text('你好'), findsOneWidget); // Back in the input.

        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 20));
      });

      testWidgets('a refused key keeps the original source and brings the draft back', (tester) async {
        final chats = <Map<String, Object?>>[];
        final extracts = <Map<String, Object?>>[];
        final client = MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, Object?>;
          if (body['system'] == companionMemoryExtractionPrompt) {
            final input = jsonDecode(((body['messages']! as List).single as Map)['content'] as String) as Map<String, Object?>;
            extracts.add(input);
            return http.Response(_sse([jsonEncode({
              'schema_version': 2, 'batch_id': input['batch_id'],
              'covered_message_ids': (input['source']! as List).cast<Map>().map((row) => row['id']).toList(),
              'operations': [], 'completion': 'complete',
            })]), 200, headers: {'content-type': 'text/event-stream; charset=utf-8'});
          }
          chats.add(body);
          return chats.length == 1
              ? http.Response('{"error":"bad key"}', 401)
              : http.Response(_sse(['这次听到了。']), 200, headers: {'content-type': 'text/event-stream; charset=utf-8'});
        });
        await openLight(tester, apiKey: 'sk-test', client: client);
        await say(tester, '你好');
        expect(find.textContaining('API Key 好像不对'), findsOneWidget);
        expect(find.text('你好'), findsOneWidget);
        final memory = await memoryOf(tester);
        final original = Map<String, Object?>.from(memory.store.messages().single);
        expect(original['text'], '你好');
        expect(original['role'], 'user');
        expect(chats, hasLength(1));
        await say(tester, '你好');
        expect(chats, hasLength(2));
        final users = memory.store.messages().where((row) => row['role'] == 'user').toList();
        expect(users, hasLength(1));
        for (final field in ['id', 'session_id', 'first_seq', 'source_rev', 'said_at_utc', 'offset_minutes', 'text']) {
          expect(users.single[field], original[field], reason: field);
        }
        final receipts = memory.store.requests().where((row) => row['category'] == 'chat').toList();
        expect(receipts, hasLength(2), reason: 'the retry is a new physical attempt, not a new statement');
        expect(receipts.map((row) => row['id']).toSet(), hasLength(2));
        expect(receipts.every((row) => row['sent_at_ms'] != null), isTrue);
        expect(receipts.map((row) => row['terminal']), containsAll(['http_error', 'complete']));
        expect(find.text('这次听到了。'), findsOneWidget);
        expect(extracts, isEmpty);
        expect(users.single['extraction_state'], 'pending');

        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 20));
        await openLight(tester, apiKey: 'sk-test', client: client);
        final reopened = await memoryOf(tester);
        final extracted = Completer<void>();
        void observeExtraction() {
          final row = reopened.store.messages().singleWhere((row) => row['role'] == 'user');
          if (row['extraction_state'] == 'done' && !extracted.isCompleted) {
            extracted.complete();
          }
        }
        reopened.addListener(observeExtraction);
        observeExtraction();
        try {
          await settleMixed(tester, extracted.future);
        } finally {
          reopened.removeListener(observeExtraction);
        }
        final restored = reopened.store.messages().singleWhere((row) => row['role'] == 'user');
        for (final field in ['id', 'session_id', 'first_seq', 'source_rev', 'said_at_utc', 'offset_minutes', 'text']) {
          expect(restored[field], original[field], reason: field);
        }
        // The real reopening path force-extracts the pending original. Its
        // complete empty proposal is not another ordinary chat or a free retry.
        expect(restored['extraction_state'], 'done');
        expect(restored['format_failures'], 0);
        expect(reopened.store.cards(), isEmpty);
        expect(extracts, hasLength(1));
        final sentSource = (extracts.single['source']! as List).cast<Map>().single;
        for (final field in ['id', 'first_seq', 'source_rev', 'offset_minutes', 'text']) {
          expect(sentSource[field], original[field], reason: field);
        }
        expect(sentSource['said_at_utc'],
          DateTime.fromMillisecondsSinceEpoch(original['said_at_utc']! as int, isUtc: true).toIso8601String());
        final after = reopened.store.requests();
        expect(after.where((row) => row['category'] == 'chat').toList(), receipts);
        final extract = after.singleWhere((row) => row['category'] == 'extract');
        expect(extract['batch_id'], extracts.single['batch_id']);
        expect(extract['state'], 'finished');
        expect(extract['terminal'], 'complete');
        expect(extract['sent_at_ms'], isNotNull);
        expect(chats, hasLength(2), reason: 'reopening extracts the queued source without resending ordinary chat');
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 20));
      });

      testWidgets('a source transaction failure keeps the draft and sends no model request', (tester) async {
        final asked = <Map<String, Object?>>[];
        final client = MockClient((request) async {
          asked.add(jsonDecode(request.body) as Map<String, Object?>);
          return http.Response(_sse(['听到了。']), 200, headers: {'content-type': 'text/event-stream; charset=utf-8'});
        });
        await openLight(tester, apiKey: 'sk-test', client: client);
        final memory = await memoryOf(tester);
        final before = memory.store.archive['next_seq'];
        final db = sqlite3.open('${root.path}/memory.sqlite');
        db.execute("CREATE TRIGGER reject_source BEFORE INSERT ON memory_events BEGIN SELECT RAISE(ABORT,'fixture'); END");
        db.close();

        await say(tester, '我改学长笛了');
        expect(asked, isEmpty);
        expect(memory.store.messages(), isEmpty);
        expect(memory.store.requests(), isEmpty);
        expect(memory.store.archive['next_seq'], before);
        expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '我改学长笛了');
        expect(find.text('这句话没送出去，要不要再说一次？'), findsOneWidget);

        final recovered = sqlite3.open('${root.path}/memory.sqlite');
        recovered.execute('DROP TRIGGER reject_source');
        recovered.close();
        await say(tester, '我改学长笛了');
        expect(asked, hasLength(1));
        final source = memory.store.messages().singleWhere((row) => row['role'] == 'user');
        expect(source['text'], '我改学长笛了');
        expect(source['first_seq'], before, reason: 'the failed transaction never allocated a statement');
        expect(memory.store.requests().where((row) => row['category'] == 'chat'), hasLength(1));
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 20));
      });

      Future<void> settleIo(WidgetTester tester) async {
        for (var i = 0; i < 4; i++) {
          await _settle(tester);
        }
      }

      testWidgets('starting over drops the reply on its way: it never writes itself back', (tester) async {
        final body = StreamController<List<int>>();
        final client = MockClient.streaming((_, _) async => http.StreamedResponse(body.stream, 200));
        await openLight(tester, apiKey: 'sk-test', client: client);
        await say(tester, '你好');
        body.add(utf8.encode(_sse(['旧回答的前半。'], end: false)));
        await settleIo(tester);

        await tester.tap(find.byIcon(AppIcons.more));
        await settleIo(tester);
        // The menu scrolls on a short screen.
        await tester.ensureVisible(find.text('重新认识'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('重新认识'));
        await settleIo(tester);
        await tester.tap(find.widgetWithText(FilledButton, '重新认识'));
        await settleIo(tester);

        final composer = tester.widget<CompanionComposer>(find.byType(CompanionComposer));
        expect(composer.running, isFalse, reason: 'discarding a stream must release the Stop state immediately');
        expect(composer.busy, isFalse);

        body.add(utf8.encode(_sse(['旧回答的后半。'])));
        await body.close();
        await settleIo(tester);
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
        final memory = await memoryOf(tester);
        expect(jsonEncode(memory.store.messages()), isNot(contains('旧回答')));
        expect(memory.store.messages().single['text'], '你好');
        expect(memory.store.messages(sessionId: memory.store.lightSessionId, forModel: true), isEmpty);
        expect(find.textContaining('旧回答的后半'), findsNothing);

        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 20));
      });

      testWidgets('switching to full while the source store opens sends nothing from the phone', (tester) async {
        var asked = 0;
        final opened = Completer<void>();
        final client = MockClient((_) async {
          asked++;
          return http.Response('', 500);
        });
        await openLight(
          tester,
          apiKey: 'sk-test',
          client: client,
          extra: [
            companionMemoryOwnerProvider(root.absolute.path).overrideWith((ref) async {
              await opened.future;
              final memory = CompanionMemoryOwner(
                CompanionMemoryStore(
                  sqlite3.open('${root.path}/memory.sqlite'),
                  nowMilliseconds: () => DateTime.now().millisecondsSinceEpoch,
                ),
                CompanionLocal.at(root),
              );
              ref.onDispose(memory.dispose);
              return memory;
            }),
          ],
        );
        await tester.enterText(find.byType(TextField), '你好');
        await tester.pump();
        await tester.tap(find.byIcon(AppIcons.send).last);
        await tester.pump();
        expect(tester.widget<CompanionComposer>(find.byType(CompanionComposer)).busy, isTrue);
        expect(asked, 0);
        // SQLite has not opened, so the composer's copy is still the only one.
        final container = ProviderScope.containerOf(tester.element(find.byType(CompanionPage)));
        await container.read(companionModeProvider.notifier).choose(CompanionMode.full);
        await tester.pump();
        opened.complete();
        await tester.pump();
        final memory = await memoryOf(tester);
        await settleMixed(tester, memory.migrateLocal());
        await tester.pump();
        expect(asked, 0);
        expect(memory.store.messages(), isEmpty);
        expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '你好');
        expect(tester.widget<CompanionComposer>(find.byType(CompanionComposer)).busy, isFalse);

        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 20));
      });

      testWidgets('stop lets go at once, even before the model answers', (tester) async {
        var asked = 0;
        final never = Completer<http.StreamedResponse>();
        final client = MockClient.streaming((_, _) {
          asked++;
          return asked == 1
              ? never.future
              : Future.value(http.StreamedResponse(Stream.value(utf8.encode(_sse(['在呢。']))), 200));
        });
        await openLight(tester, apiKey: 'sk-test', client: client);
        await say(tester, '你好');
        await tester.tap(find.byIcon(AppIcons.stopGenerating).last);
        await settleIo(tester);

        await tester.pump(const Duration(seconds: 12));
        await say(tester, '还在吗');
        expect(asked, 2);
        expect(find.text('在呢。'), findsOneWidget);

        await tester.pumpWidget(const SizedBox());
        // The first request's own 30-second timeout runs out into a cancelled subscription.
        await tester.pump(const Duration(seconds: 40));
      });
    });
  });
}
