import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/companion/companion_adapt.dart';
import 'package:dsh_app/companion/companion_initiative.dart';
import 'package:dsh_app/companion/companion_initiative_owner.dart';
import 'package:dsh_app/companion/companion_keeper.dart';
import 'package:dsh_app/companion/companion_light.dart';
import 'package:dsh_app/companion/companion_local.dart';
import 'package:dsh_app/companion/companion_memory.dart';
import 'package:dsh_app/companion/companion_memory_worker.dart';
import 'package:dsh_app/companion/companion_moves.dart';
import 'package:dsh_app/companion/companion_pack.dart';
import 'package:dsh_app/companion/companion_public_lookup.dart';
import 'package:dsh_app/companion/companion_state.dart';
import 'package:dsh_app/pets/pet_mood.dart';
import 'package:dsh_app/pets/pet_signals.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/tavern/tavern_card_scripts.dart';
import 'package:dsh_app/tavern/tavern_provider.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:dsh_app/l10n/gen/app_localizations.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/ui/companion/companion_chrome.dart';
import 'package:dsh_app/ui/companion/companion_log.dart';
import 'package:dsh_app/ui/companion/companion_page.dart';
import 'package:dsh_app/ui/companion/companion_stage.dart';
import 'package:dsh_app/ui/companion/companion_tasks_page.dart';
import 'package:dsh_app/ui/tavern/tavern_chat_page.dart';
import 'package:dsh_app/ui/tavern/tavern_home_page.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/ui/theme/app_theme.dart';
import 'package:dsh_app/ui/workspace/directory_picker.dart';
import 'package:dsh_client/dsh_client.dart'
    show
        CompanionMemory,
        CompanionMemoryStore,
        CompanionTaskStore,
        CompanionPublicLookupStore,
        CompanionHostTaskStore,
        MemoryBatch,
        companionMemoryExtractionPrompt,
        companionMemoryConsolidationPrompt,
        isMemoryResponsePreference,
        parseExtractionProposal;
import 'package:dsh_tavern/dsh_tavern.dart' as story;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';

import 'phone_keeper_fake.dart';
import 'companion_test_settle.dart';
import '../support/companion_notes_peer.dart';

Widget _app(Widget child, {List<Override> extra = const [], CompanionKeeper? phone, HostConnection? connection}) =>
    ProviderScope(
      // By default there is no host: the page must stand on its own without one.
      overrides: [
        activeConnectionProvider.overrideWithValue(AsyncData<HostConnection?>(connection)),
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

class _NotesLightMode extends CompanionModeSetting {
  @override
  CompanionMode? build() => CompanionMode.light;
}

Future<void> _notesVisible(WidgetTester tester, Finder finder, {bool absent = false}) async {
  for (var i = 0; i < 200 && (finder.evaluate().isEmpty != absent); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(finder, absent ? findsNothing : findsWidgets);
}

/// Observes the Page's real completion future; all receipt handling stays
/// with the production owner. The story replay waits for it before leaving.
class _ReceiptMemory extends CompanionMemoryOwner {
  _ReceiptMemory(super.store, super.legacy, {super.nowMilliseconds});

  late Future<void> lastReceipt;

  @override
  void retainReceipt(Future<void> settled) {
    super.retainReceipt(settled);
    lastReceipt = settled;
  }
}

/// Both clocks for the initiative owner, moved by the test.
class _Clock {
  int wall = DateTime.utc(2026, 11, 5, 10, 30).millisecondsSinceEpoch;
  int mono = 0;
  int offset = 0;

  CompanionInitiativeClock call() => CompanionInitiativeClock(wallMs: wall, monoMs: mono, offsetMinutes: offset);
}

/// The owner, plus what the page told it: the room's gates as observed, and
/// whether anything touched her (a tap or a typed word would hide an
/// invitation without the gate ever seeing the room become busy).
class _RecordingInitiative extends CompanionInitiative {
  _RecordingInitiative(super.clock);

  final observed = <CompanionInitiativeView>[];
  int activations = 0;

  @override
  void observe(CompanionInitiativeRoom room, CompanionInitiativeView view) {
    observed.add(view);
    super.observe(room, view);
  }

  @override
  void activate(CompanionInitiativeRoom room) {
    activations++;
    super.activate(room);
  }
}

/// Her invitation to rest (companion_invite_test.dart drives the same one).
const _inviteText = '要不要陪我在软垫上歇一会儿？';

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

    testWidgets('a key builds the composer, not her stage; the gate still hears the room is busy', (tester) async {
      SharedPreferences.setMockInitialValues({'companion_touch_hint_done': true, 'companion_home_hint_done': true});
      final clock = _Clock();
      final initiative = _RecordingInitiative(clock.call);
      addTearDown(initiative.dispose);
      await tester.runAsync(() => initiative.ready);

      CompanionStageEvents? stageEvents;
      var stageBuilds = 0;
      await tester.pumpWidget(
        _app(
          CompanionPage(
            storeOverride: installedStore(),
            stageBuilder: (controller, events) {
              stageBuilds++;
              stageEvents = events;
              return const SizedBox.expand();
            },
          ),
          extra: [companionInitiativeProvider.overrideWithValue(initiative)],
        ),
      );
      final up = await _stageUp(tester, () => stageEvents);
      up.onReady();
      await _settle(tester);
      // Her greeting first: nothing else of hers is on screen when this starts.
      await tester.pump(const Duration(seconds: 10));
      await _settle(tester);
      // The field is not focused: only the text can make the room busy.
      final field = tester.widget<TextField>(find.byType(TextField)).controller!;
      initiative.observed.clear();
      final builds = stageBuilds;

      for (final text in ['在', '在吗', '在吗？']) {
        field.text = text;
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(find.byKey(const ValueKey('send')), findsOneWidget);
      expect(stageBuilds, builds, reason: 'a key must not build her room or her stage again');
      expect(initiative.observed, isNotEmpty);
      expect(initiative.observed.last.blocked, isTrue, reason: 'the gate hears the input is busy');

      field.text = '';
      await tester.pump(const Duration(milliseconds: 16));
      // The key's switch-out animation keeps the old key a moment.
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(find.byKey(const ValueKey('send')), findsNothing);
      expect(initiative.observed.last.blocked, isFalse, reason: 'the gate hears the input let go');

      // Unmount the scope rather than updating it with fewer overrides.
      await tester.pumpWidget(const SizedBox());
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
        HostConnection? connection,
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
            connection: connection,
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

      for (final scenario in [
        'accepted',
        'source-failure',
        'leave-during-bind',
        'cancel-during-bind',
        'leave-after-acceptance',
      ]) {
        testWidgets('F actual Page directory binding and stable source: $scenario', (tester) async {
          const channel = MethodChannel('dsh/companion_reminders');
          const now = 1795219200000;
          final db = sqlite3.open('${root.path}/memory.sqlite');
          final memory = _ReceiptMemory(
            CompanionMemoryStore(db, nowMilliseconds: () => now),
            CompanionLocal.at(root),
            nowMilliseconds: () => now,
          );
          final peer = (await tester.runAsync(NotesPeer.open))!;
          final clockRead = Completer<void>();
          final browserRead = Completer<void>();
          final bindRead = Completer<void>();
          final releaseBind = Completer<void>();
          final postReceived = Completer<void>();
          final releasePost = Completer<void>();
          final posted = Completer<void>();
          Map<String, Object?>? snapshot;
          var closed = false;
          addTearDown(() async {
            if (!releaseBind.isCompleted) {
              releaseBind.complete();
            }
            if (!releasePost.isCompleted) {
              releasePost.complete();
            }
            await tester.pumpWidget(const SizedBox());
            if (!closed) {
              memory.dispose();
            }
            await tester.pump();
            await tester.runAsync(peer.close);
            tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
          });
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'clock') {
              if (!clockRead.isCompleted) {
                clockRead.complete();
              }
              return {'utcMs': now, 'zoneId': 'Asia/Shanghai', 'offsetSeconds': 28800};
            }
            if (call.method == 'capabilities') {
              return {'executorId': 'phone-original', 'exact': true, 'notifications': true};
            }
            if (call.method == 'recover') {
              return {'recoveryQueued': true};
            }
            throw StateError('Unexpected native task call ${call.method}');
          });
          peer.respond = (request, body) async {
            if (request.uri.path == '/api/directoryPicker/list') {
              expect(memory.store.messages().where((row) => row['role'] == 'user'), hasLength(1));
              await NotesPeer.json(request, {
                'type': 'server-response',
                'rpcId': body!['rpcId'],
                'result': {
                  'ok': true,
                  'value': {
                    'path': '/实际笔记',
                    'home': '/实际笔记',
                    'crumbs': [
                      {'name': '实际笔记', 'path': '/实际笔记'},
                    ],
                    'entries': [],
                  },
                },
              });
              browserRead.complete();
            } else if (request.uri.path == '$notesPath/folders') {
              expect(body, {'v': 1, 'hostStoreId': 'original-store', 'path': '/实际笔记'});
              expect(memory.store.tasks(), isEmpty);
              bindRead.complete();
              if (scenario.endsWith('during-bind')) {
                await releaseBind.future;
              }
              await NotesPeer.json(request, {
                'v': 1,
                'hostStoreId': 'original-store',
                'folderRef': 'bound-source',
                'displayPath': '/实际笔记',
              });
            } else if (request.method == 'POST' && request.uri.path == notesPath) {
              final row = memory.store.tasks().single;
              final command = memory.store.hostTaskCommands(row['task_id']! as String).single;
              expect(command['possible_sent_at_ms'], now);
              expect(body!['deadlineAtMs'], isNull);
              expect(body['afterExit'], scenario == 'leave-after-acceptance' ? 'continue' : 'pause');
              expect(body['hostSessionId'], isNull);
              expect((body['args']! as Map)['localDate'], '2026-11-21');
              expect((body['args']! as Map)['folderRef'], 'bound-source');
              expect(jsonEncode(body), isNot(contains('练长笛')));
              snapshot = notesSnapshot(body, state: scenario == 'leave-after-acceptance' ? 'running' : 'waiting');
              postReceived.complete();
              if (scenario == 'leave-after-acceptance') {
                await releasePost.future;
              }
              await NotesPeer.json(request, snapshot!, status: 201);
              posted.complete();
            } else if (request.method == 'GET' &&
                snapshot != null &&
                request.uri.path == '$notesPath/${snapshot!['taskId']}') {
              await NotesPeer.json(request, snapshot!);
            } else {
              await NotesPeer.json(request, {
                'error': {'code': 'companion/not-found', 'message': 'No route'},
              }, status: 404);
            }
          };
          await openLight(
            tester,
            apiKey: '',
            client: MockClient((_) async => throw StateError('F must not call the light model')),
            connection: HostConnection(client: peer.client, isLocal: false),
            extra: [
              companionModeProvider.overrideWith(_NotesLightMode.new),
              companionMemoryOwnerProvider(root.absolute.path).overrideWith((ref) => memory),
            ],
          );
          expect(await memoryOf(tester), same(memory));
          await settleMixed(tester, memory.migrateLocal());
          final sourceRoom = memory.store.lightSessionId;
          if (scenario == 'source-failure') {
            db.execute(
              "CREATE TRIGGER reject_notes_source BEFORE INSERT ON memory_events BEGIN SELECT RAISE(ABORT,'fixture'); END",
            );
          }
          final afterExit = scenario == 'leave-after-acceptance' ? '我先走了也继续' : '我离开就停';
          final raw = '请电脑把今天的笔记另存成一页待办，原件别动，$afterExit；我午后练长笛';
          await tester.enterText(find.byType(TextField), raw);
          await tester.pump();
          await tester.tap(find.byIcon(AppIcons.send).last);
          await settleMixed(tester, clockRead.future);
          if (scenario == 'source-failure') {
            await tester.pumpAndSettle();
            expect(find.text('刚才没办成，这件事还在，等会儿再试试？'), findsOneWidget);
            expect(tester.widget<CompanionComposer>(find.byType(CompanionComposer)).busy, isFalse);
            expect(memory.store.messages(), isEmpty);
            expect(memory.store.tasks(), isEmpty);
            expect(
              peer.calls.where(
                (call) => call.uri.path.startsWith(notesPath) || call.uri.path.contains('directoryPicker'),
              ),
              isEmpty,
            );
            expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, raw);
            return;
          }
          await _notesVisible(tester, find.byType(DirectoryLocationsSheet));
          expect(find.byType(DirectoryLocationsSheet), findsOneWidget);
          final handling = memory.lastReceipt;
          await tester.tap(find.text('主目录').last);
          await settleMixed(tester, browserRead.future);
          final choose = find
              .descendant(
                of: find.byType(DirectoryBrowserPage),
                matching: find.byWidgetPredicate((widget) => widget is FilledButton && widget.onPressed != null),
              )
              .last;
          await _notesVisible(tester, choose);
          expect(tester.widget<FilledButton>(choose).onPressed, isNotNull);
          await tester.tap(choose);
          await settleMixed(tester, bindRead.future);
          if (scenario == 'leave-during-bind') {
            await tester.pumpWidget(const SizedBox());
          } else if (scenario == 'cancel-during-bind') {
            await _notesVisible(tester, find.byType(DirectoryLocationsSheet), absent: true);
            await tester.enterText(find.byType(TextField), '取消这次笔记整理');
            await tester.pump();
            expect(tester.widget<CompanionComposer>(find.byType(CompanionComposer)).busy, isFalse);
            await tester.tap(find.byIcon(AppIcons.send).last);
            await tester.pumpAndSettle();
            expect(find.text('想撤哪一件整理？去「交代的事」里点一下。'), findsOneWidget);
          }
          releaseBind.complete();
          if (scenario == 'leave-after-acceptance') {
            await settleMixed(tester, postReceived.future);
            final accepted = memory.store.tasks().single;
            expect(memory.store.hostTaskCommands(accepted['task_id']! as String).single['possible_sent_at_ms'], now);
            await tester.pumpWidget(const SizedBox());
            // The production room-identity operation opens a different Page
            // while the original accepted task is still awaiting its receipt.
            // This does not claim to exercise the restart-menu gesture.
            memory.store.startLightConversation();
            expect(memory.store.lightSessionId, isNot(sourceRoom));
            await openLight(
              tester,
              apiKey: '',
              client: MockClient((_) async => throw StateError('F must not call the light model')),
              connection: HostConnection(client: peer.client, isLocal: false),
              extra: [
                companionModeProvider.overrideWith(_NotesLightMode.new),
                companionMemoryOwnerProvider(root.absolute.path).overrideWith((ref) => memory),
              ],
            );
            expect(await memoryOf(tester), same(memory));
            releasePost.complete();
          }
          if (scenario == 'accepted' || scenario == 'leave-after-acceptance') {
            await settleMixed(tester, posted.future);
          }
          await settleMixed(tester, handling);
          await tester.pump();
          final sources = memory.store.messages().where((row) => row['role'] == 'user').toList();
          expect(sources.first['text'], raw);
          if (scenario != 'accepted' && scenario != 'leave-after-acceptance') {
            expect(memory.store.tasks(), isEmpty);
            expect(peer.calls.where((call) => call.method == 'POST' && call.uri.path == notesPath), isEmpty);
          } else {
            final row = memory.store.tasks().single;
            expect(row['source_message_id'], sources.single['id']);
            expect(row['source_session_id'], sourceRoom);
            expect(row['item_no'], 0);
            final task = memory.store.hostTask(row['task_id']! as String)!;
            expect(task['state'], scenario == 'leave-after-acceptance' ? 'running' : 'waiting');
            expect(task['task_rev'], 1);
            expect(task['cancel_requested'], 0);
            expect(task['directory_labels'], {'source': '/实际笔记', 'output': '/实际笔记'});
            if (scenario == 'accepted') {
              expect(find.text('看看这件事'), findsOneWidget);
              await tester.tap(find.text('看看这件事'));
              await _notesVisible(tester, find.byType(CompanionTasksPage));
              await settleMixed(tester, memory.lastReceipt);
              await tester.pump();
              expect(find.byType(CompanionTasksPage), findsOneWidget);
              expect(find.text('笔记在：/实际笔记'), findsOneWidget);
              expect(find.textContaining('没法确定你离没离开'), findsOneWidget);
              expect(find.text('让电脑接着做'), findsNothing);
            } else {
              expect(find.text('看看这件事'), findsNothing);
              expect(find.text('电脑接手了，正在整理。'), findsNothing);
              expect(find.textContaining('2026-11-21-待办.md'), findsNothing);
              expect(memory.store.tasks(sourceSessionId: memory.store.lightSessionId), isEmpty);
            }
            expect(peer.calls.where((call) => call.method == 'POST' && call.uri.path == notesPath), hasLength(1));
            await tester.pumpWidget(const SizedBox());
            memory.dispose();
            closed = true;
            await tester.pump();
            final reopened = CompanionMemoryStore(
              sqlite3.open('${root.path}/memory.sqlite'),
              nowMilliseconds: () => now,
            );
            expect(reopened.hostTask(row['task_id']! as String)!['agreement'], task['agreement']);
            expect(reopened.messages().singleWhere((item) => item['id'] == sources.single['id'])['said_at_utc'], now);
            reopened.close();
          }
        });
      }

      for (final rejectSource in [false, true]) {
        testWidgets('E actual Page keeps reminder lookup and factual clause identities, sourceFailure=$rejectSource', (
          tester,
        ) async {
          const channel = MethodChannel('dsh/companion_reminders');
          final now = DateTime.utc(2026, 11, 21, 10).millisecondsSinceEpoch;
          final db = sqlite3.open('${root.path}/memory.sqlite');
          final memory = _ReceiptMemory(
            CompanionMemoryStore(db, nowMilliseconds: () => now),
            CompanionLocal.at(root),
            nowMilliseconds: () => now,
          );
          final clockRead = Completer<void>();
          final answerSent = Completer<void>();
          final calls = <String>[];
          final posts = <http.Request>[];
          addTearDown(() async {
            await tester.pumpWidget(const SizedBox());
            memory.dispose();
            await tester.pump();
            tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
          });
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            if (call.method == 'clock') {
              if (!clockRead.isCompleted) {
                clockRead.complete();
              }
              return {'utcMs': now, 'zoneId': 'Asia/Shanghai', 'offsetSeconds': 28800};
            }
            if (call.method == 'capabilities') {
              return {'executorId': 'installation-A', 'exact': true, 'notifications': true};
            }
            if (call.method == 'resolve') {
              return {
                'kind': 'unique',
                'moments': [
                  {'epochMs': now + 72000000, 'offsetSeconds': 28800},
                ],
              };
            }
            if (call.method == 'recover') {
              return {'recoveryQueued': true};
            }
            if (call.method == 'wake') {
              final taskId = (call.arguments as Map)['taskId'];
              // The existing D native boundary is controlled here. E still
              // executes all of its real HTTP, claim and answer parsing code.
              db.execute("UPDATE companion_task_revisions SET state='done' WHERE task_id=? AND task_rev=1", [taskId]);
              return {'wakeCompleted': true};
            }
            throw StateError('Unexpected platform method ${call.method}');
          });
          final client = MockClient((request) async {
            posts.add(request);
            Object body;
            if (request.url.toString() == companionLookupSearchEndpoint) {
              expect(jsonDecode(request.body), {'query': '青桥美术馆 2026-11-21 开放 公告', 'count': 5, 'need_content': false});
              body = {
                'results': [
                  {'url': 'https://museum.example/notice', 'title': '青桥美术馆公告', 'snippet': '临时安排'},
                ],
              };
            } else if (request.url.toString() == companionLookupFetchEndpoint) {
              body = {'title': '青桥美术馆公告', 'content': '2026-11-21临时闭馆一天。'};
            } else {
              final sent = jsonDecode(request.body) as Map;
              if (sent['system'] == companionMemoryExtractionPrompt) {
                return http.Response.bytes(
                  utf8.encode(_sse(['{"ops":[]}'])),
                  200,
                  headers: {'content-type': 'text/event-stream; charset=utf-8'},
                );
              }
              expect(sent['system'], companionLookupAnswerPrompt);
              final input = jsonDecode(sent['messages'][0]['content']) as Map;
              expect(input.keys.toSet(), {'task', 'sources'});
              expect(jsonEncode(input), isNot(contains('带证件')));
              expect(jsonEncode(input), isNot(contains('练长笛')));
              final source = (input['sources'] as List).single as Map;
              final answer = {
                'status': 'done',
                'conclusion': '馆方公告说明今天临时闭馆。',
                'applicable_date': '2026-11-21',
                'evidence': [
                  {'fetchRequestId': source['fetchRequestId'], 'quote': '2026-11-21临时闭馆一天。'},
                ],
              };
              answerSent.complete();
              return http.Response.bytes(
                utf8.encode(_sse([jsonEncode(answer)])),
                200,
                headers: {'content-type': 'text/event-stream; charset=utf-8'},
              );
            }
            return http.Response.bytes(
              utf8.encode(jsonEncode(body)),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          });
          await openLight(
            tester,
            apiKey: 'dedicated-test-key',
            client: client,
            extra: [companionMemoryOwnerProvider(root.absolute.path).overrideWith((ref) => memory)],
          );
          expect(await memoryOf(tester), same(memory));
          await settleMixed(tester, memory.migrateLocal());
          if (rejectSource) {
            db.execute(
              "CREATE TRIGGER reject_lookup_source BEFORE INSERT ON memory_events BEGIN SELECT RAISE(ABORT,'fixture'); END",
            );
          }
          const raw = '明天十四点提醒我带证件；帮我查今天青桥美术馆开不开，给我馆方公告；我午后练长笛';
          await tester.enterText(find.byType(TextField), raw);
          await tester.pump();
          await tester.tap(find.byIcon(AppIcons.send).last);
          await settleMixed(tester, clockRead.future);
          if (rejectSource) {
            await tester.pumpAndSettle();
            expect(find.text('刚才没记下来，你写的还在，再试一次？'), findsOneWidget);
            expect(tester.widget<CompanionComposer>(find.byType(CompanionComposer)).busy, isFalse);
            expect(memory.store.messages(), isEmpty);
            expect(memory.store.tasks(), isEmpty);
            expect(posts, isEmpty);
            expect(calls.where((method) => method == 'resolve' || method == 'wake'), isEmpty);
            expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, raw);
          } else {
            await settleMixed(tester, answerSent.future);
            await settleMixed(tester, memory.lastReceipt);
            await tester.pump();
            final original = memory.store.messages().singleWhere((message) => message['role'] == 'user');
            expect(original['text'], raw);
            final tasks = memory.store.tasks();
            expect(tasks, hasLength(2));
            expect(tasks.map((task) => task['source_message_id']), everyElement(original['id']));
            expect(tasks.map((task) => task['item_no']).toSet(), {0, 1});
            final query = tasks.singleWhere((task) => task['kind'] == 'public.lookup');
            final result = memory.store.lookupTask(query['task_id']! as String)!;
            expect(result['state'], 'done');
            expect(result['source_session_id'], memory.store.lightSessionId);
            expect(memory.store.lookupAttempts(query['task_id']! as String), hasLength(3));
            expect(find.textContaining('馆方公告说明今天临时闭馆。'), findsWidgets);
            expect(posts.where((request) => request.url.toString() == companionLookupSearchEndpoint), hasLength(1));
            expect(posts.where((request) => request.url.toString() == companionLookupFetchEndpoint), hasLength(1));
            final postsBeforeOpening = posts.length;
            await tester.tap(find.text('看看出处 · 青桥美术馆'));
            await tester.pumpAndSettle();
            expect(find.byType(CompanionTasksPage), findsOneWidget);
            expect(find.text('2026-11-21 Asia/Shanghai'), findsOneWidget);
            expect(find.text('2026-11-21临时闭馆一天。'), findsOneWidget);
            final link = find.widgetWithText(TextButton, 'https://museum.example/notice');
            expect(link, findsOneWidget);
            expect(tester.widget<TextButton>(link).onPressed, isNotNull);
            expect(find.byType(ExpansionTile), findsNothing);
            expect(find.textContaining('¥'), findsNothing);
            expect(
              posts,
              hasLength(postsBeforeOpening),
              reason: 'The source action opens the original result without querying again',
            );
          }
        });
      }

      for (final after in ['cancel', 'leave']) {
        testWidgets('E actual Page $after after search dispatch preserves the original task and late receipt', (
          tester,
        ) async {
          const channel = MethodChannel('dsh/companion_reminders');
          final now = DateTime.utc(2026, 11, 21, 10).millisecondsSinceEpoch;
          final memory = _ReceiptMemory(
            CompanionMemoryStore(sqlite3.open('${root.path}/memory.sqlite'), nowMilliseconds: () => now),
            CompanionLocal.at(root),
            nowMilliseconds: () => now,
          );
          final sent = Completer<void>();
          final release = Completer<void>();
          var searches = 0;
          var fetches = 0;
          var answers = 0;
          addTearDown(() async {
            if (!release.isCompleted) {
              release.complete();
            }
            await tester.pumpWidget(const SizedBox());
            memory.dispose();
            await tester.pump();
            tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
          });
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            (call) async => switch (call.method) {
              'clock' => {'utcMs': now, 'zoneId': 'Asia/Shanghai', 'offsetSeconds': 28800},
              'capabilities' => {'executorId': 'installation-A', 'exact': true, 'notifications': true},
              'recover' => {'recoveryQueued': true},
              _ => throw StateError('Unexpected reminder call ${call.method}'),
            },
          );
          final commands = await openLight(
            tester,
            apiKey: 'dedicated-test-key',
            client: MockClient((request) async {
              if (request.url.toString() == companionLookupSearchEndpoint) {
                searches++;
                sent.complete();
                await release.future;
                return http.Response.bytes(
                  utf8.encode(
                    jsonEncode({
                      'results': [
                        {'url': 'https://museum.example/notice', 'title': '青桥美术馆公告', 'snippet': '临时安排'},
                      ],
                    }),
                  ),
                  200,
                  headers: {'content-type': 'application/json; charset=utf-8'},
                );
              }
              if (request.url.toString() == companionLookupFetchEndpoint) {
                fetches++;
                return http.Response.bytes(
                  utf8.encode(jsonEncode({'content': '2026-11-21临时闭馆一天。'})),
                  200,
                  headers: {'content-type': 'application/json; charset=utf-8'},
                );
              }
              final body = jsonDecode(request.body) as Map;
              if (body['system'] == companionMemoryExtractionPrompt) {
                return http.Response.bytes(
                  utf8.encode(_sse(['{"ops":[]}'])),
                  200,
                  headers: {'content-type': 'text/event-stream; charset=utf-8'},
                );
              }
              expect(body['system'], companionLookupAnswerPrompt);
              answers++;
              final input = jsonDecode(body['messages'][0]['content']) as Map;
              final answer = {
                'status': 'done',
                'conclusion': '馆方公告说明今天临时闭馆。',
                'applicable_date': '2026-11-21',
                'evidence': [
                  {'fetchRequestId': input['sources'][0]['fetchRequestId'], 'quote': '2026-11-21临时闭馆一天。'},
                ],
              };
              return http.Response.bytes(
                utf8.encode(_sse([jsonEncode(answer)])),
                200,
                headers: {'content-type': 'text/event-stream; charset=utf-8'},
              );
            }),
            extra: [companionMemoryOwnerProvider(root.absolute.path).overrideWith((ref) => memory)],
          );
          await settleMixed(tester, memory.migrateLocal());
          await tester.enterText(find.byType(TextField), '帮我查今天青桥美术馆开不开，给我馆方公告');
          await tester.pump();
          await tester.tap(find.byIcon(AppIcons.send).last);
          await settleMixed(tester, sent.future);
          final initial = memory.store.tasks().single;
          final originalDrain = memory.lastReceipt;
          expect(memory.store.lookupAttempts(initial['task_id']! as String).single['dispatched'], 1);
          commands.clear();
          if (after == 'cancel') {
            final cancelledTask = Completer<void>();
            void changed() {
              if (!cancelledTask.isCompleted &&
                  memory.store.lookupTask(initial['task_id']! as String)!['cancel_requested'] == 1) {
                cancelledTask.complete();
              }
            }

            memory.addListener(changed);
            await tester.enterText(find.byType(TextField), '取消青桥美术馆的查询');
            await tester.pump();
            await tester.tap(find.byIcon(AppIcons.send).last);
            await settleMixed(tester, cancelledTask.future);
            memory.removeListener(changed);
            await settleMixed(tester, memory.lastReceipt);
            expect(memory.store.lookupTask(initial['task_id']! as String)!['cancel_requested'], 1);
          } else {
            await tester.pumpWidget(const SizedBox());
            await tester.pump();
          }
          release.complete();
          await settleMixed(tester, originalDrain);
          await tester.pump();
          final finalTask = memory.store.lookupTask(initial['task_id']! as String)!;
          expect(finalTask['task_id'], initial['task_id']);
          expect(finalTask['source_session_id'], initial['source_session_id']);
          expect(searches, 1);
          expect([fetches, answers], after == 'cancel' ? [0, 0] : [1, 1]);
          expect(finalTask['state'], after == 'cancel' ? 'cancelled' : 'done');
          expect(
            commands.where((command) => command.$1 == 'say' && jsonEncode(command.$2).contains('馆方公告说明今天临时闭馆')),
            isEmpty,
          );
        });
      }

      for (final after in ['cancel', 'leave', 'accepted then leave']) {
        testWidgets(
          'D actual Page $after while the reminder platform call is pending preserves the acceptance boundary',
          (tester) async {
            const channel = MethodChannel('dsh/companion_reminders');
            final started = Completer<void>();
            final release = Completer<void>();
            final calls = <MethodCall>[];
            final memory = _ReceiptMemory(
              CompanionMemoryStore(sqlite3.open('${root.path}/memory.sqlite'), nowMilliseconds: () => 1772877000000),
              CompanionLocal.at(root),
            );
            Future<void>? operation;
            var posts = 0;
            addTearDown(() async {
              if (!release.isCompleted) {
                release.complete();
              }
              final pending = operation;
              if (pending != null) {
                await settleMixed(tester, pending);
              }
              await tester.pumpWidget(const SizedBox());
              memory.dispose();
              await tester.pump();
              tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
            });
            tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
              calls.add(call);
              if ((after == 'accepted then leave' && call.method == 'wake') ||
                  (after != 'accepted then leave' && call.method == 'resolve')) {
                started.complete();
                await release.future;
              }
              return switch (call.method) {
                'clock' => {'utcMs': 1772877000000, 'zoneId': 'America/Los_Angeles', 'offsetSeconds': -28800},
                'capabilities' => {'executorId': 'installation-A', 'exact': true, 'notifications': true},
                'resolve' => {
                  'kind': 'unique',
                  'moments': [
                    {'epochMs': 1772964600000, 'offsetSeconds': -25200},
                  ],
                },
                'wake' => {'wakeCompleted': true},
                'recover' => {'recoveryQueued': true},
                _ => throw StateError('Unexpected reminder method ${call.method}'),
              };
            });
            await openLight(
              tester,
              apiKey: 'sk-test',
              client: MockClient((_) async {
                posts++;
                return http.Response('', 401);
              }),
              extra: [companionMemoryOwnerProvider(root.absolute.path).overrideWith((ref) => memory)],
            );
            expect(await memoryOf(tester), same(memory));
            await settleMixed(tester, memory.migrateLocal());
            const first = '2026-03-08 03:10 America/Los_Angeles提醒我带钥匙';
            final raw = after == 'accepted then leave' ? '$first；2026-03-08 03:10 America/Los_Angeles提醒我带证件' : first;
            await tester.enterText(find.byType(TextField), raw);
            await tester.pump();
            await tester.tap(find.byIcon(AppIcons.send).last);
            await settleMixed(tester, started.future);
            operation = memory.lastReceipt;
            final original = memory.store.messages().single;
            expect(original['text'], raw);
            expect(original['said_at_utc'], 1772877000000);
            expect(original['zone_id'], 'America/Los_Angeles');
            expect(original['offset_seconds'], -28800);
            final accepted = memory.store.tasks();
            expect(accepted, hasLength(after == 'accepted then leave' ? 1 : 0));
            if (after == 'cancel') {
              final cancelledSource = Completer<void>();
              void changed() {
                if (!cancelledSource.isCompleted && memory.store.messages().any((row) => row['text'] == '不用提醒了')) {
                  cancelledSource.complete();
                }
              }

              memory.addListener(changed);
              await tester.enterText(find.byType(TextField), '我午后练长笛');
              await tester.pump();
              expect(tester.widget<CompanionComposer>(find.byType(CompanionComposer)).busy, isTrue);
              await tester.enterText(find.byType(TextField), '不用提醒了');
              await tester.pump();
              expect(tester.widget<CompanionComposer>(find.byType(CompanionComposer)).busy, isFalse);
              await tester.tap(find.byIcon(AppIcons.send).last);
              await settleMixed(tester, cancelledSource.future);
              memory.removeListener(changed);
              final cancellation = memory.lastReceipt;
              expect(identical(cancellation, operation), isFalse);
              await settleMixed(tester, cancellation);
              expect(memory.store.messages().where((row) => row['text'] == '不用提醒了'), hasLength(1));
            } else {
              await tester.pumpWidget(const SizedBox());
              await tester.pumpWidget(_app(const Scaffold(body: Text('新的页面'))));
            }
            release.complete();
            await settleMixed(tester, operation);
            await tester.pump();
            expect(memory.store.tasks(), hasLength(accepted.length));
            expect(calls.where((call) => call.method == 'wake'), hasLength(accepted.length));
            expect(posts, 0);
            if (accepted.isNotEmpty) {
              final task = memory.store.tasks().single;
              expect(task['task_id'], accepted.single['task_id']);
              expect(task['task_rev'], 1);
              expect(task['source_message_id'], original['id']);
              expect(task['source_session_id'], original['session_id']);
              expect(task['state'], 'queued', reason: 'wake completion alone is not a registration receipt');
              expect(memory.store.taskReceipts(task['task_id']! as String), isEmpty);
              expect(find.text('新的页面'), findsOneWidget);
              expect(find.textContaining('这条提醒'), findsNothing);
            }
          },
        );
      }

      for (final rejectSource in [false, true]) {
        testWidgets('D actual Page separates reminder receipts from acceptance, sourceFailure=$rejectSource', (
          tester,
        ) async {
          const channel = MethodChannel('dsh/companion_reminders');
          final clockRead = Completer<void>();
          final twoWakes = Completer<void>();
          final calls = <MethodCall>[];
          final db = sqlite3.open('${root.path}/memory.sqlite');
          final memory = _ReceiptMemory(
            CompanionMemoryStore(db, nowMilliseconds: () => 1772877000000),
            CompanionLocal.at(root),
          );
          var wakes = 0;
          var posts = 0;
          addTearDown(() async {
            await tester.pumpWidget(const SizedBox());
            memory.dispose();
            await tester.pump();
            tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
          });
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            switch (call.method) {
              case 'clock':
                clockRead.complete();
                return {'utcMs': 1772877000000, 'zoneId': 'America/Los_Angeles', 'offsetSeconds': -28800};
              case 'capabilities':
                return {'executorId': 'installation-A', 'exact': true, 'notifications': true};
              case 'resolve':
                return {
                  'kind': 'unique',
                  'moments': [
                    {'epochMs': 1772964600000, 'offsetSeconds': -25200},
                  ],
                };
              case 'recover':
                return {'recoveryQueued': true};
              case 'wake':
                final task = memory.store.task((call.arguments as Map)['taskId']! as String)!;
                wakes++;
                // Controlled native receipt input, not an Android execution.
                // The Page must read the same database after wake completes.
                if (wakes == 1) {
                  for (final event in ['claimed', 'returned']) {
                    db.execute(
                      '''
                      INSERT INTO companion_task_receipts(task_id,task_rev,step_key,attempt_id,event_kind,
                        executor_id,occurred_at_ms,outcome)
                      VALUES(?,?,'alarm.register','page-native-peer',?,'installation-A',1772877000000,?)
                    ''',
                      [task['task_id'], task['task_rev'], event, event == 'returned' ? 'succeeded' : null],
                    );
                  }
                  db.execute("UPDATE companion_task_revisions SET state='done' WHERE task_id=? AND task_rev=?", [
                    task['task_id'],
                    task['task_rev'],
                  ]);
                } else {
                  db.execute(
                    '''
                    INSERT INTO companion_task_receipts(task_id,task_rev,step_key,attempt_id,event_kind,
                      executor_id,occurred_at_ms,outcome,detail_json)
                    VALUES(?,?,'executor','page-native-peer','blocked','installation-A',1772877000000,
                      'not_performed',?)
                  ''',
                    [
                      task['task_id'],
                      task['task_rev'],
                      jsonEncode({'reason': 'notifications_disabled'}),
                    ],
                  );
                  db.execute(
                    '''
                    UPDATE companion_task_revisions SET state='waiting',wait_reason='notifications_disabled'
                    WHERE task_id=? AND task_rev=?
                  ''',
                    [task['task_id'], task['task_rev']],
                  );
                  twoWakes.complete();
                }
                return {'wakeCompleted': true};
              default:
                throw StateError('Unexpected reminder method ${call.method}');
            }
          });
          await openLight(
            tester,
            apiKey: 'sk-test',
            client: MockClient((_) async {
              posts++;
              return http.Response('', 401);
            }),
            extra: [companionMemoryOwnerProvider(root.absolute.path).overrideWith((ref) => memory)],
          );
          expect(await memoryOf(tester), same(memory));
          await settleMixed(tester, memory.migrateLocal());
          if (rejectSource) {
            db.execute(
              "CREATE TRIGGER reject_reminder BEFORE INSERT ON memory_events BEGIN SELECT RAISE(ABORT,'fixture'); END",
            );
          }
          const raw = '2026-03-08 03:10 America/Los_Angeles提醒我带钥匙；2026-03-08 03:10 America/Los_Angeles提醒我带证件';
          await tester.enterText(find.byType(TextField), raw);
          await tester.pump();
          await tester.tap(find.byIcon(AppIcons.send).last);
          await settleMixed(tester, clockRead.future);
          if (rejectSource) {
            await tester.pump();
            expect(memory.store.messages(), isEmpty);
            expect(memory.store.tasks(), isEmpty);
            expect(calls.where((call) => call.method == 'resolve' || call.method == 'wake'), isEmpty);
            expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, raw);
            expect(find.text('刚才没记下来，你写的还在，再试一次？'), findsOneWidget);
          } else {
            await settleMixed(tester, twoWakes.future);
            await settleMixed(tester, memory.lastReceipt);
            await tester.pump();
            final source = memory.store.messages().single;
            final tasks = memory.store.tasks();
            expect(source['text'], raw);
            expect(tasks, hasLength(2));
            expect(tasks.map((task) => task['source_message_id']), everyElement(source['id']));
            expect(tasks.map((task) => task['command_item_no']).toSet(), {0, 1});
            final done = tasks.singleWhere((task) => task['reminder_text'] == '带钥匙');
            final waiting = tasks.singleWhere((task) => task['reminder_text'] == '带证件');
            expect(done['state'], 'done');
            expect(memory.store.taskReceipts(done['task_id']! as String).last['outcome'], 'succeeded');
            expect(waiting['state'], 'waiting');
            expect(waiting['wait_reason'], 'notifications_disabled');
            expect(memory.store.taskReceipts(waiting['task_id']! as String).single['outcome'], 'not_performed');
            expect(find.text('带钥匙：设好了，到点我叫你。\n带证件：通知没开，这条还没设上。去系统设置里打开通知就好。'), findsOneWidget);
          }
          expect(posts, 0);
        });
      }

      testWidgets('fixture 6 original Tavern chat reopens with its story name while the real Page keeps its own name', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(const Size(390, 844));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final storyRoot = Directory('${root.path}/tavern');
        final storyPosts = <Map<String, Object?>>[];
        final engines = <story.TavernEngine>[];
        ProviderContainer? storyScope;
        _ReceiptMemory? phoneMemory;
        late story.TavernEngine engine;
        late String characterId;
        late String chatId;
        late Completer<void> storyEntered;
        Completer<http.Response>? storyResponse;
        addTearDown(() async {
          final pendingResponse = storyResponse;
          if (pendingResponse != null && !pendingResponse.isCompleted) {
            pendingResponse.complete(http.Response('', 499));
          }
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
          storyScope?.dispose();
          phoneMemory?.dispose();
          await tester.pump();
          for (final opened in engines) {
            await settleMixed(tester, opened.close());
          }
        });

        // Read the same metadata and display providers the pages use. Before
        // mounting they start in the real zone; later reads may join Page work.
        Future<void> readStoryRows() async {
          final scope = storyScope!;
          for (final row in await engine.path(chatId)) {
            final shown = tavernShownTextProvider((chatId, row.nodeId, row.text));
            scope.listen(shown, (_, _) {});
            await scope.read(shown.future);
          }
        }

        Future<void> openStory({bool first = false}) async {
          await tester.runAsync(() async {
            engine = await story.TavernEngine.openDirectory(
              storyRoot,
              config: story.TavernModelConfig(apiKey: () async => 'sk-story-test', baseUrl: 'https://example.invalid'),
              modelClient: story.TavernModelClient(
                clientFactory: () => MockClient((request) async {
                  expect(request.method, 'POST');
                  expect(request.url.path, endsWith('/chat/completions'));
                  storyPosts.add(jsonDecode(request.body) as Map<String, Object?>);
                  storyEntered.complete();
                  return storyResponse!.future;
                }),
              ),
            );
            engines.add(engine);
            if (first) {
              final character = await engine.importCard(
                Uint8List.fromList(
                  utf8.encode(
                    jsonEncode({
                      'spec': 'chara_card_v3',
                      'spec_version': '3.0',
                      'data': {
                        'name': '故事同行者',
                        'nickname': '',
                        'description': '',
                        'personality': '',
                        'scenario': '',
                        'first_mes': '故事从这里开始。',
                        'alternate_greetings': [],
                        'mes_example': '',
                        'system_prompt': '',
                        'post_history_instructions': '',
                        'creator_notes': '',
                        'tags': [],
                        'extensions': {},
                      },
                    }),
                  ),
                ),
              );
              characterId = character.id;
              chatId = await engine.createChat(characterId);
            }
            final scope = ProviderContainer(
              overrides: [
                tavernProvider.overrideWithValue(engine),
                settingsProvider.overrideWith(() => _Settings('sk-story-test')),
              ],
            );
            storyScope = scope;
            // Riverpod 3 pauses an unobserved StreamProvider. Keep these real
            // streams observed before mounting, just as the home page does.
            scope.listen(tavernCharactersProvider, (_, _) {});
            scope.listen(tavernChatsProvider(null), (_, _) {});
            await scope.read(tavernCharactersProvider.future);
            await scope.read(tavernChatsProvider(null).future);
            scope.listen(tavernCharacterDetailProvider(characterId), (_, _) {});
            scope.listen(tavernCardDataProvider(characterId), (_, _) {});
            await scope.read(tavernCharacterDetailProvider(characterId).future);
            await scope.read(tavernCardDataProvider(characterId).future);
            final scripts = tavernChatScriptsProvider((chatId, characterId));
            scope.listen(scripts, (_, _) {});
            await scope.read(scripts.future);
            await readStoryRows();
          });
          await tester.pumpWidget(
            UncontrolledProviderScope(container: storyScope!, child: _app(const TavernHomePage())),
          );
          await tester.pumpAndSettle();
          final resume = find.byKey(ValueKey('tavern-continue-$chatId'));
          expect(resume, findsOneWidget);
          await tester.ensureVisible(resume);
          await tester.tap(resume);
          await tester.pumpAndSettle();
          expect(tester.widget<TavernChatPage>(find.byType(TavernChatPage)).chatId, chatId);
        }

        Future<void> storySay(String text) async {
          await tester.enterText(find.byType(TextField), text);
          await tester.pump();
          storyEntered = Completer<void>();
          final response = Completer<http.Response>();
          storyResponse = response;
          await tester.tap(find.byIcon(AppIcons.send).last);
          await settleMixed(tester, storyEntered.future);
          // Subscribe to the actual Page-started turn while HTTP is held.
          final done = engine.resumeTurn(chatId).toList();
          response.complete(
            http.Response(
              [
                'data: ${jsonEncode({
                  'choices': [
                    {
                      'index': 0,
                      'delta': {'content': '故事继续了。'},
                    },
                  ],
                })}\n\n',
                'data: ${jsonEncode({
                  'choices': [
                    {'index': 0, 'delta': <String, Object?>{}, 'finish_reason': 'stop'},
                  ],
                })}\n\n',
                'data: [DONE]\n\n',
              ].join(),
              200,
              headers: {'content-type': 'text/event-stream; charset=utf-8'},
            ),
          );
          final events = await settleMixed(tester, done);
          expect(events.whereType<story.TavernTurnFailed>(), isEmpty);
          expect(events.whereType<story.TavernTurnDone>(), hasLength(1));
          // These display providers may already have been started by the Page.
          await settleMixed(tester, readStoryRows());
          await tester.pumpAndSettle();
        }

        Future<void> leaveStory() async {
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          expect(find.byType(TavernChatPage), findsNothing);
          expect(find.byType(TavernHomePage), findsOneWidget);
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
          storyScope!.dispose();
          storyScope = null;
          await settleMixed(tester, engine.close());
        }

        const storyName = '故事里叫我校长。';
        await openStory(first: true);
        expect(storyPosts, isEmpty);
        await storySay(storyName);
        expect(storyPosts, hasLength(1));
        expect(
          (storyPosts.single['messages']! as List)
              .cast<Map>()
              .where((row) => row['role'] == 'user')
              .map((row) => row['content'])
              .join('\n'),
          contains(storyName),
        );
        final before = (await tester.runAsync(() => engine.path(chatId)))!;
        expect(before.where((row) => row.role == story.TavernRole.user).single.text, storyName);
        final oldPath = [for (final row in before) (row.nodeId, row.parentId, row.role, row.text, row.at)];
        await leaveStory();

        // The phone owner lives across room visits, as in the app. The test
        // adds only a receipt observer; the Page still submits and extracts.
        final memory = _ReceiptMemory(
          CompanionMemoryStore(
            sqlite3.open('${root.path}/memory.sqlite'),
            nowMilliseconds: () => DateTime.now().millisecondsSinceEpoch,
          ),
          CompanionLocal.at(root),
        );
        phoneMemory = memory;
        final chats = <Map<String, Object?>>[];
        final extracts = <Map<String, Object?>>[];
        late Completer<void> phoneEntered;
        const realName = '现实里，我的称呼是阿橙。';
        final phoneClient = MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, Object?>;
          if (body['system'] == companionMemoryExtractionPrompt) {
            final input =
                jsonDecode(((body['messages']! as List).single as Map)['content'] as String) as Map<String, Object?>;
            extracts.add(input);
            final source = (input['source']! as List).cast<Map>().single;
            expect(source['text'], realName);
            return http.Response(
              _sse([
                jsonEncode({
                  'schema_version': 2,
                  'batch_id': input['batch_id'],
                  'covered_message_ids': [source['id']],
                  'completion': 'complete',
                  'operations': [
                    {
                      'op': 'create',
                      'kind': 'fact',
                      'text': realName,
                      'keywords': ['称呼', '阿橙'],
                      'evidence': [
                        {'message_id': source['id'], 'quote': source['text']},
                      ],
                    },
                  ],
                }),
              ]),
              200,
              headers: {'content-type': 'text/event-stream; charset=utf-8'},
            );
          }
          chats.add(body);
          phoneEntered.complete();
          return http.Response(_sse(['我听到了。']), 200, headers: {'content-type': 'text/event-stream; charset=utf-8'});
        });
        await openLight(
          tester,
          apiKey: 'sk-test',
          client: phoneClient,
          extra: [companionMemoryOwnerProvider(root.absolute.path).overrideWith((ref) => memory)],
        );
        expect(await memoryOf(tester), same(memory));
        await settleMixed(tester, memory.migrateLocal());
        await tester.pumpAndSettle();
        expect(memory.store.messages(), isEmpty);
        expect(memory.store.cards(), isEmpty);

        Future<void> realSay(String text) async {
          await tester.enterText(find.byType(TextField), text);
          await tester.pump();
          phoneEntered = Completer<void>();
          await tester.tap(find.byIcon(AppIcons.send).last);
          await settleMixed(tester, phoneEntered.future);
          await settleMixed(tester, memory.lastReceipt);
          await tester.pumpAndSettle();
          expect(memory.store.requests().where((row) => row['category'] == 'chat').last['terminal'], 'complete');
        }

        await realSay(realName);
        final source = memory.store.messages().singleWhere((row) => row['role'] == 'user');
        expect(source['text'], realName);
        expect(source['scope'], 'real');
        final page = tester.state(find.byType(CompanionPage));
        expect(await tester.runAsync(() => memory.extract(page, forceTail: true)), CompanionMemoryWork.committed);
        expect(extracts, hasLength(1));
        final card = memory.store.cards().single;
        expect(card['text'], realName);
        final proof = (card['evidence']! as List).cast<Map>().single;
        expect(proof['message_id'], source['id']);
        expect(proof['source_rev'], source['source_rev']);
        expect(proof['quote'], realName);
        await realSay('我怎么称呼？');
        expect(chats, hasLength(2));
        expect(jsonEncode(chats), isNot(contains('校长')));
        final lastContent = (((chats.last['messages']! as List).last as Map)['content']! as List).cast<Map>();
        final block = lastContent
            .map((part) => part['text'] as String)
            .singleWhere((text) => text.contains('companion_memory'));
        expect((jsonDecode(block) as Map)['items'], [
          {'id': card['id'], 'kind': 'fact', 'text': realName},
        ]);
        final phoneMessages = memory.store.messages();
        final phoneCards = memory.store.cards();
        final phoneReceipts = memory.store.requests();
        expect(jsonEncode(phoneMessages), isNot(contains('校长')));
        expect(phoneReceipts.where((row) => row['category'] == 'chat'), hasLength(2));
        expect(phoneReceipts.where((row) => row['category'] == 'extract'), hasLength(1));
        expect(phoneReceipts.every((row) => row['state'] == 'finished' && row['terminal'] == 'complete'), isTrue);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();

        // The home opens the saved chat, not a replacement chat or a new
        // story card. No test writes the old name back into either archive.
        await openStory();
        final reopened = (await tester.runAsync(() => engine.path(chatId)))!;
        expect([for (final row in reopened) (row.nodeId, row.parentId, row.role, row.text, row.at)], oldPath);
        const continuation = '我们接着刚才的故事说。';
        await storySay(continuation);
        expect(storyPosts, hasLength(2));
        final storyMessages = (storyPosts.last['messages']! as List).cast<Map>();
        final userText = storyMessages.where((row) => row['role'] == 'user').map((row) => row['content']).join('\n');
        expect(userText, contains(storyName));
        expect(userText, contains(continuation));
        final outgoing = jsonEncode(storyPosts.last);
        expect(outgoing, isNot(contains('阿橙')));
        expect(outgoing, isNot(contains('companion_memory')));
        expect(outgoing, isNot(contains('phoneMemory')));
        final after = (await tester.runAsync(() => engine.path(chatId)))!;
        expect([
          for (final row in after.take(before.length)) (row.nodeId, row.parentId, row.role, row.text, row.at),
        ], oldPath);
        expect(memory.store.messages(), phoneMessages);
        expect(memory.store.cards(), phoneCards);
        expect(memory.store.requests(), phoneReceipts);
        await leaveStory();
      });

      for (final changedPreference in [false, true]) {
        testWidgets(
          changedPreference
              ? 'fixture 4 a personal writing change reaches the next Page request with its own complete source'
              : 'fixture 4 joining a writing group keeps the original preference in the next Page request',
          (tester) async {
            final posts = <Map<String, Object?>>[];
            await openLight(
              tester,
              apiKey: 'sk-test',
              client: MockClient((request) async {
                posts.add(jsonDecode(request.body) as Map<String, Object?>);
                return http.Response(
                  _sse(['我们按你的习惯慢慢来。']),
                  200,
                  headers: {'content-type': 'text/event-stream; charset=utf-8'},
                );
              }),
            );
            final memory = await memoryOf(tester);
            Map<String, Object?> source(String id, String text, {String role = 'user'}) => memory.store.submitMessage(
              id: id,
              sessionId: memory.store.lightSessionId,
              text: text,
              role: role,
              saidAtUtc: DateTime.now().millisecondsSinceEpoch,
              offsetMinutes: 0,
            );
            void commit(MemoryBatch batch, List<Map<String, Object?>> operations) {
              final proposal = parseExtractionProposal(
                jsonEncode({
                  'schema_version': 2,
                  'batch_id': batch.id,
                  'covered_message_ids': batch.sources.map((row) => row['id']).toList(),
                  'operations': operations,
                  'completion': 'complete',
                }),
                batch,
              );
              expect(memory.store.commitExtraction(batch, proposal), isTrue);
              memory.changed();
            }

            const originalText = '我练写作喜欢先看一个例子';
            final originalSource = source('writing-original', originalText);
            final first = memory.store.nextBatch(forceTail: true, estimateTokens: (text) => text.runes.length)!;
            expect(first.sources.map((row) => row['id']), ['writing-original']);
            commit(first, [
              {
                'op': 'create',
                'kind': 'preference',
                'text': originalText,
                'keywords': ['写作', '例子'],
                'evidence': [
                  {'message_id': 'writing-original', 'quote': originalText},
                ],
              },
            ]);
            final originalCard = memory.store.cards().single;
            expect(isMemoryResponsePreference(originalCard), isTrue);
            // The group-membership fact and an assistant's steps do not stand in
            // for the person's own statement of a new response preference.
            const groupText = '我最近加入了写作小组';
            final groupSource = source('writing-group', groupText);
            const assistantText = '练写作先列三个步骤，例子放最后。';
            source('assistant-suggestion', assistantText, role: 'assistant');
            final joining = memory.store.nextBatch(forceTail: true, estimateTokens: (text) => text.runes.length)!;
            expect(joining.sources.map((row) => row['id']), ['writing-group']);
            expect(
              () => parseExtractionProposal(
                jsonEncode({
                  'schema_version': 2,
                  'batch_id': joining.id,
                  'covered_message_ids': ['writing-group'],
                  'completion': 'complete',
                  'operations': [
                    {
                      'op': 'replace',
                      'target_id': originalCard['id'],
                      'expected_row_rev': originalCard['row_rev'],
                      'kind': 'preference',
                      'text': assistantText,
                      'keywords': ['写作', '步骤'],
                      'evidence': [
                        {'message_id': 'assistant-suggestion', 'quote': assistantText},
                      ],
                      'change_kind': 'new_current_value',
                    },
                  ],
                }),
                joining,
              ),
              throwsFormatException,
            );
            commit(joining, [
              {
                'op': 'create',
                'kind': 'fact',
                'text': groupText,
                'keywords': ['写作', '小组'],
                'evidence': [
                  {'message_id': 'writing-group', 'quote': groupText},
                ],
              },
            ]);
            expect(memory.store.cards().singleWhere((row) => row['id'] == originalCard['id']), originalCard);
            final groupCard = memory.store.cards().singleWhere((row) => row['text'] == groupText);
            var expectedSource = originalSource;
            var expectedText = originalText;
            if (changedPreference) {
              const newText = '我现在改习惯了，练写作时先给我三个步骤，例子放最后';
              expectedSource = source('writing-new-preference', newText);
              expectedText = newText;
              final replacement = memory.store.nextBatch(forceTail: true, estimateTokens: (text) => text.runes.length)!;
              expect(replacement.sources.map((row) => row['id']), ['writing-new-preference']);
              expect(
                replacement.existing.singleWhere((row) => row['id'] == originalCard['id'])['row_rev'],
                originalCard['row_rev'],
              );
              commit(replacement, [
                {
                  'op': 'replace',
                  'target_id': originalCard['id'],
                  'expected_row_rev': originalCard['row_rev'],
                  'kind': 'preference',
                  'text': newText,
                  'keywords': ['写作', '步骤', '例子'],
                  'evidence': [
                    {'message_id': 'writing-new-preference', 'quote': newText},
                  ],
                  'change_kind': 'new_current_value',
                },
              ]);
            }
            final preference = memory.store.cards().singleWhere((row) => row['kind'] == 'preference');
            expect(preference['id'], originalCard['id']);
            expect(preference['text'], expectedText);
            expect(preference['row_rev'], (originalCard['row_rev']! as int) + (changedPreference ? 1 : 0));
            expect(preference['current_basis_seq'], expectedSource['first_seq']);
            expect(isMemoryResponsePreference(preference), isTrue);
            final proof = (preference['evidence']! as List).cast<Map>().single;
            expect(proof['message_id'], expectedSource['id']);
            expect(proof['source_rev'], expectedSource['source_rev']);
            expect(proof['first_seq'], expectedSource['first_seq']);
            expect(proof['said_at_utc'], expectedSource['said_at_utc']);
            expect(proof['offset_minutes'], expectedSource['offset_minutes']);
            expect(proof['role'], 'user');
            expect(proof['scope'], 'real');
            expect(proof['quote'], expectedText);
            final groupProof = (groupCard['evidence']! as List).cast<Map>().single;
            expect(groupProof['message_id'], groupSource['id']);
            expect(groupProof['source_rev'], groupSource['source_rev']);
            expect(groupProof['quote'], groupText);
            for (final original in [originalSource, groupSource]) {
              final saved = memory.store.messages().singleWhere((row) => row['id'] == original['id']);
              expect({for (final key in original.keys) key: saved[key]}, original);
            }
            expect(
              memory.store.messages().singleWhere((row) => row['id'] == 'assistant-suggestion')['role'],
              'assistant',
            );
            const query = '今天练写作，怎么起手？';
            await say(tester, query);
            expect(posts, hasLength(1));
            final content = (((posts.single['messages']! as List).last as Map)['content']! as List).cast<Map>();
            expect(content.first['text'], changedPreference ? '$expectedText\n$query' : query);
            // Check the actual selected block, not matching words in old chat
            // history (which legitimately still includes the assistant's idea).
            final block = content
                .where((part) => part['type'] == 'text')
                .map((part) => part['text'] as String)
                .singleWhere((text) => text.startsWith('{"type":"companion_memory",'));
            final items = ((jsonDecode(block) as Map)['items']! as List).cast<Map>();
            expect(items.map((row) => row['id']), unorderedEquals([originalCard['id'], groupCard['id']]));
            expect(items.singleWhere((row) => row['kind'] == 'preference')['text'], expectedText);
            expect(items.singleWhere((row) => row['kind'] == 'fact')['text'], groupText);
            if (!changedPreference) {
              expect(items.any((row) => (row['text'] as String).contains('三个步骤')), isFalse);
            }
            await tester.pumpWidget(const SizedBox());
            await tester.pump(const Duration(seconds: 10));
          },
        );
      }

      testWidgets('fixture 15 ordinary Page chat still sends after a real organize request reaches the daily limit', (
        tester,
      ) async {
        late CompanionMemoryOwner memory;
        final categories = <String>[];
        final posts = <Map<String, Object?>>[];
        final client = MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, Object?>;
          posts.add(body);
          final system = body['system'];
          final category = system == companionMemoryExtractionPrompt
              ? 'extract'
              : system == companionMemoryConsolidationPrompt
              ? 'organize'
              : 'chat';
          categories.add(category);
          final receipt = memory.store.requests().singleWhere(
            (row) => row['category'] == category && row['state'] == 'sent',
          );
          expect(receipt['sent_at_ms'], isNotNull);
          var answer = '可以，我们慢慢聊。';
          if (category != 'chat') {
            final messages = body['messages']! as List;
            final input = jsonDecode((messages.single as Map)['content'] as String) as Map<String, Object?>;
            expect(receipt['batch_id'], input['batch_id']);
            if (category == 'extract') {
              answer = jsonEncode({
                'schema_version': 2,
                'batch_id': input['batch_id'],
                'covered_message_ids': ['yogurt-a', 'yogurt-b'],
                'completion': 'complete',
                'operations': [
                  {
                    'op': 'create',
                    'kind': 'preference',
                    'text': '你买酸奶只选原味。',
                    'keywords': ['酸奶'],
                    'evidence': [
                      {'message_id': 'yogurt-a', 'quote': '酸奶我只买原味。'},
                    ],
                  },
                  {
                    'op': 'create',
                    'kind': 'preference',
                    'text': '酸奶你只买原味的。',
                    'keywords': ['酸奶'],
                    'evidence': [
                      {'message_id': 'yogurt-b', 'quote': '我买酸奶一直只选原味。'},
                    ],
                  },
                ],
              });
            } else {
              expect(input['rows'] as List, hasLength(2));
              answer = jsonEncode({
                'schema_version': 2,
                'batch_id': input['batch_id'],
                'operations': [],
                'completion': 'complete',
              });
            }
          }
          return http.Response.bytes(
            utf8.encode(
              [
                {
                  'type': 'message_start',
                  'message': {
                    'usage': {'input_tokens': 900},
                  },
                },
                {
                  'type': 'content_block_delta',
                  'delta': {'type': 'text_delta', 'text': answer},
                },
                {
                  'type': 'message_delta',
                  'delta': {'stop_reason': 'end_turn'},
                  'usage': {
                    'input_tokens': 20,
                    'cache_read_input_tokens': 3,
                    'cache_creation_input_tokens': 0,
                    'output_tokens': category == 'chat' ? 7 : 12,
                  },
                },
                {'type': 'message_stop'},
              ].map((event) => 'data: ${jsonEncode(event)}\n\n').join(),
            ),
            200,
            headers: {'content-type': 'text/event-stream; charset=utf-8'},
          );
        });
        await openLight(tester, apiKey: 'sk-test', client: client);
        memory = await memoryOf(tester);
        await settleMixed(tester, memory.migrateLocal());
        final page = tester.state(find.byType(CompanionPage));
        // Use earlier real messages from another room with the Page's already
        // attached owner/transport. They remain memory sources without becoming
        // unanswered user turns in this room's ordinary chat history.
        for (final (id, text) in [('yogurt-a', '酸奶我只买原味。'), ('yogurt-b', '我买酸奶一直只选原味。')]) {
          memory.store.submitMessage(
            id: id,
            sessionId: 'light:prior-organize-room',
            text: text,
            saidAtUtc: DateTime.now().millisecondsSinceEpoch,
            offsetMinutes: 0,
          );
        }
        expect(await tester.runAsync(() => memory.extract(page, forceTail: true)), CompanionMemoryWork.committed);
        expect(await tester.runAsync(() => memory.consolidate(page)), CompanionMemoryWork.committed);
        expect(categories, ['extract', 'organize']);
        expect(memory.store.cards(), hasLength(2));
        final row = memory.store.cards().first;
        memory.store.setPinned(id: row['id']! as String, expectedRowRev: row['row_rev']! as int, pinned: true);
        memory.changed();
        final auxiliary = memory.store.requests();
        final organized = auxiliary.singleWhere((row) => row['category'] == 'organize');
        expect(organized['state'], 'finished');
        expect(organized['terminal'], 'complete');
        expect(await tester.runAsync(() => memory.consolidate(page)), CompanionMemoryWork.waiting);
        expect(categories, ['extract', 'organize']);
        expect(memory.store.requests(), auxiliary);
        expect(memory.store.messages(sessionId: memory.store.lightSessionId), isEmpty);
        // Within the same rolling window, an explicit ordinary composer send
        // still makes its own actual HTTP request and settles its own receipt.
        const query = '我想换个话题，今天过得怎么样？';
        await say(tester, query);
        expect(categories, ['extract', 'organize', 'chat']);
        final content = (((posts.last['messages']! as List).last as Map)['content']! as List).cast<Map>();
        expect(content.first['text'], query);
        expect(find.text('可以，我们慢慢聊。'), findsOneWidget);
        final receipts = memory.store.requests();
        expect(receipts, hasLength(3));
        expect(receipts.where((row) => row['category'] != 'chat').toList(), auxiliary);
        final chat = receipts.singleWhere((row) => row['category'] == 'chat');
        expect(chat['state'], 'finished');
        expect(chat['terminal'], 'complete');
        expect((chat['sent_at_ms']! as int) - (organized['sent_at_ms']! as int), inInclusiveRange(0, 86399999));
        expect(chat['output_tokens'], 7);
        expect((chat['raw_usage']! as Map)['final_usage'], {
          'input_tokens': 20,
          'cache_read_input_tokens': 3,
          'cache_creation_input_tokens': 0,
          'output_tokens': 7,
        });
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 10));
      });

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

      testWidgets('fixture 2 grouped Log names keep two submitted originals after reopening SQLite', (tester) async {
        final chats = <Map<String, Object?>>[];
        final extracts = <Map<String, Object?>>[];
        final client = MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, Object?>;
          if (body['system'] == companionMemoryExtractionPrompt) {
            final input =
                jsonDecode(((body['messages']! as List).single as Map)['content'] as String) as Map<String, Object?>;
            extracts.add(input);
            final sources = (input['source']! as List).cast<Map>();
            return http.Response(
              _sse([
                jsonEncode({
                  'schema_version': 2,
                  'batch_id': input['batch_id'],
                  'covered_message_ids': sources.map((row) => row['id']).toList(),
                  'operations': [
                    for (final row in sources)
                      {
                        'op': 'create',
                        'kind': 'fact',
                        'text': row['text'],
                        'evidence': [
                          {'message_id': row['id'], 'quote': row['text']},
                        ],
                      },
                  ],
                  'completion': 'complete',
                }),
              ]),
              200,
              headers: {'content-type': 'text/event-stream; charset=utf-8'},
            );
          }
          chats.add(body);
          return http.Response('{"error":"bad key"}', 401);
        });
        await openLight(tester, apiKey: 'sk-test', client: client);
        const firstText = '我改学长笛了';
        const secondText = '老师约在周六';
        await say(tester, firstText);
        expect(find.textContaining('API Key 好像不对'), findsOneWidget);
        final memory = await memoryOf(tester);
        final first = Map<String, Object?>.from(memory.store.messages().single);
        expect(first['text'], firstText);
        await say(tester, secondText);
        expect(find.textContaining('API Key 好像不对'), findsOneWidget);
        expect(chats, hasLength(2));
        expect(extracts, isEmpty);
        final originals = {for (final row in memory.store.messages()) row['text']: row};
        expect(originals.keys, unorderedEquals([firstText, secondText]));
        final second = Map<String, Object?>.from(originals[secondText]!);
        expect(first['id'], isNot(second['id']));
        expect(first['session_id'], second['session_id']);
        expect(first['first_seq'] as int, lessThan(second['first_seq'] as int));
        for (final row in [first, second]) {
          expect(row['role'], 'user');
          expect(row['scope'], 'real');
          expect(row['source_rev'], 1);
          expect(row['said_at_utc'], isA<int>());
          expect(row['offset_minutes'], isA<int>());
        }
        // These really are two failed HTTP attempts, with no fabricated
        // assistant turn between them. Only the API view joins adjacent users.
        String sentText(Map<String, Object?> body) {
          final message = (body['messages']! as List).single as Map;
          expect(message['role'], 'user');
          final content = message['content'];
          return content is String ? content : ((content! as List).first as Map)['text'] as String;
        }

        expect(chats.map(sentText), [firstText, '$firstText\n$secondText']);
        final receipts = memory.store.requests();
        expect(receipts, hasLength(2));
        expect(receipts.map((row) => row['id']).toSet(), hasLength(2));
        expect(
          receipts.every(
            (row) =>
                row['category'] == 'chat' &&
                row['state'] == 'finished' &&
                row['terminal'] == 'http_error' &&
                row['sent_at_ms'] != null,
          ),
          isTrue,
        );
        await tester.tap(find.byIcon(AppIcons.history));
        await settleMixed(tester, CompanionLightHistory.at(root).load());
        await tester.pumpAndSettle();
        final log = find.byType(CompanionLog);
        expect(log, findsOneWidget);
        final entries = tester.widget<CompanionLog>(log).entries;
        expect(entries.map((entry) => entry.text), [firstText, secondText]);
        expect(entries.every((entry) => entry.speaker == CompanionLogSpeaker.you), isTrue);
        expect(find.descendant(of: log, matching: find.text(firstText)), findsOneWidget);
        expect(find.descendant(of: log, matching: find.text(secondText)), findsOneWidget);
        expect(
          find.descendant(of: log, matching: find.text('你')),
          findsOneWidget,
          reason: 'the real Log groups names while keeping two separately rendered originals',
        );
        expect(find.descendant(of: log, matching: find.text('$firstText\n$secondText')), findsNothing);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 20));
        await openLight(tester, apiKey: 'sk-test', client: client);
        final reopened = await memoryOf(tester);
        final extracted = Completer<void>();
        final sourceIds = {first['id'], second['id']};
        void observeExtraction() {
          final rows = reopened.store.messages().where((row) => sourceIds.contains(row['id'])).toList();
          if (rows.length == 2 && rows.every((row) => row['extraction_state'] == 'done') && !extracted.isCompleted) {
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
        expect(identical(reopened.store, memory.store), isFalse);
        final restored = {for (final row in reopened.store.messages()) row['id']: row};
        expect(restored.keys, unorderedEquals([first['id'], second['id']]));
        for (final original in [first, second]) {
          final saved = restored[original['id']]!;
          for (final field in [
            'id',
            'session_id',
            'first_seq',
            'source_rev',
            'said_at_utc',
            'offset_minutes',
            'text',
          ]) {
            expect(saved[field], original[field], reason: field);
          }
        }
        // Reopening legitimately extracts both pending originals. This is a
        // separate real request, with parsed proposals and a completed receipt.
        expect(extracts, hasLength(1));
        final sentSources = {for (final row in (extracts.single['source']! as List).cast<Map>()) row['id']: row};
        expect(sentSources.keys, unorderedEquals([first['id'], second['id']]));
        final cards = reopened.store.cards();
        expect(cards, hasLength(2));
        for (final original in [first, second]) {
          final saved = restored[original['id']]!;
          expect(saved['extraction_state'], 'done');
          expect(saved['format_failures'], 0);
          final sent = sentSources[original['id']]!;
          for (final field in ['id', 'first_seq', 'source_rev', 'offset_minutes', 'text']) {
            expect(sent[field], original[field], reason: field);
          }
          expect(
            sent['said_at_utc'],
            DateTime.fromMillisecondsSinceEpoch(original['said_at_utc']! as int, isUtc: true).toIso8601String(),
          );
          final proof = (cards.singleWhere((row) => row['text'] == original['text'])['evidence']! as List)
              .cast<Map>()
              .single;
          expect(proof['message_id'], original['id']);
          expect(proof['source_rev'], original['source_rev']);
          expect(proof['quote'], original['text']);
        }
        final after = reopened.store.requests();
        expect(after.where((row) => row['category'] == 'chat').toList(), receipts);
        final extract = after.singleWhere((row) => row['category'] == 'extract');
        expect(extract['batch_id'], extracts.single['batch_id']);
        expect(extract['state'], 'finished');
        expect(extract['terminal'], 'complete');
        expect(extract['sent_at_ms'], isNotNull);
        expect(chats, hasLength(2), reason: 'opening extracts the originals without resending either ordinary chat');
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
            final input =
                jsonDecode(((body['messages']! as List).single as Map)['content'] as String) as Map<String, Object?>;
            extracts.add(input);
            return http.Response(
              _sse([
                jsonEncode({
                  'schema_version': 2,
                  'batch_id': input['batch_id'],
                  'covered_message_ids': (input['source']! as List).cast<Map>().map((row) => row['id']).toList(),
                  'operations': [],
                  'completion': 'complete',
                }),
              ]),
              200,
              headers: {'content-type': 'text/event-stream; charset=utf-8'},
            );
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
        expect(
          sentSource['said_at_utc'],
          DateTime.fromMillisecondsSinceEpoch(original['said_at_utc']! as int, isUtc: true).toIso8601String(),
        );
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
        db.execute(
          "CREATE TRIGGER reject_source BEFORE INSERT ON memory_events BEGIN SELECT RAISE(ABORT,'fixture'); END",
        );
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

      testWidgets('explicit story and generic unconfirmed cards survive reentry but stay out of the real request', (
        tester,
      ) async {
        final asked = <Map<String, Object?>>[];
        final client = MockClient((request) async {
          asked.add(jsonDecode(request.body) as Map<String, Object?>);
          return http.Response(_sse(['阿橙。']), 200, headers: {'content-type': 'text/event-stream; charset=utf-8'});
        });
        await openLight(tester, apiKey: 'sk-test', client: client);
        final memory = await memoryOf(tester);
        memory.store.submitMessage(
          id: 'original-story',
          sessionId: memory.store.lightSessionId,
          text: '故事里叫我校长。',
          scope: 'story',
          saidAtUtc: 1793899800000,
          offsetMinutes: 480,
        );
        // Explicit SDK eligibility fixtures; the App legacy importer still
        // treats the owner's old handwritten cards as real.
        memory.store.saveManual(
          const CompanionMemory(
            id: '11111111-1111-4111-8111-111111111111',
            text: '这是剧本，我是海盗。',
            keywords: ['称呼'],
            pinned: true,
          ),
          expectedRowRev: null,
          currentValueChange: false,
          realityKnown: false,
        );
        memory.store.saveManual(
          const CompanionMemory(
            id: '22222222-2222-4222-8222-222222222222',
            text: '归属未知的称呼是店长。',
            keywords: ['称呼'],
            pinned: true,
          ),
          expectedRowRev: null,
          currentValueChange: false,
          realityKnown: false,
        );
        memory.store.saveManual(
          const CompanionMemory(id: '33333333-3333-4333-8333-333333333333', text: '本人现实称呼是阿橙。', keywords: ['称呼']),
          expectedRowRev: null,
          currentValueChange: true,
          realityKnown: true,
        );
        memory.changed();
        await _settle(tester);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 20));

        await openLight(tester, apiKey: 'sk-test', client: client);
        final reopened = await memoryOf(tester);
        expect(reopened.store.messages().single['id'], 'original-story');
        expect(reopened.store.messages().single['scope'], 'story');
        expect(reopened.store.cards(), hasLength(3));
        expect(reopened.store.cards().where((row) => row['eligible'] == true), hasLength(1));
        await tester.tap(find.byIcon(AppIcons.history));
        await settleMixed(tester, CompanionLightHistory.at(root).load());
        await tester.pumpAndSettle();
        expect(find.text('故事里叫我校长。'), findsOneWidget);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        await say(tester, '现实里我的称呼是什么？');
        final sent = jsonEncode(asked.single['messages']);
        expect(sent, contains('本人现实称呼是阿橙。'));
        for (final absent in ['校长', '海盗', '店长']) {
          expect(sent, isNot(contains(absent)), reason: absent);
        }
        expect(reopened.store.messages().singleWhere((row) => row['id'] == 'original-story')['text'], '故事里叫我校长。');
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

    testWidgets('an invitation on screen goes the moment the person types', (tester) async {
      SharedPreferences.setMockInitialValues({'companion_touch_hint_done': true, 'companion_home_hint_done': true});
      // A phone reports this long before the room opens; tests start with none.
      final resumedBefore = tester.binding.lifecycleState;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      addTearDown(() {
        if (resumedBefore != null) tester.binding.handleAppLifecycleStateChanged(resumedBefore);
      });
      // Both clocks follow the test's fake time, timers and all.
      final start = tester.binding.clock.now();
      CompanionInitiativeClock clock() {
        final ms = tester.binding.clock.now().difference(start).inMilliseconds;
        return CompanionInitiativeClock(wallMs: 1793899800000 + ms, monoMs: ms);
      }

      final owner = _RecordingInitiative(clock);
      addTearDown(owner.dispose);
      await tester.runAsync(() => owner.ready);

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
            companionInitiativeProvider.overrideWithValue(owner),
            companionInitiativeClockProvider.overrideWithValue(clock),
          ],
        ),
      );
      final up = await _stageUp(tester, () => stageEvents);
      up.onReady();
      await _settle(tester);
      // Her greeting goes, then the quiet stretch: at the original pace she
      // asks after ~45 s of quiet. Poll (up to 80 s of fake time) instead of
      // trusting that number, so a pace change fails as "no invitation" here.
      for (var i = 0; i < 80 && find.text(_inviteText).evaluate().isEmpty; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(find.text(_inviteText), findsOneWidget);
      commands.clear();

      // One key of text, the field not focused: no tap and no onUserInput
      // runs, so only the page telling the gate can take her invitation away.
      tester.widget<TextField>(find.byType(TextField)).controller!.text = '在吗';
      await tester.pump(const Duration(milliseconds: 16)); // the gate is told
      await tester.pump(); // the hide reaches the page
      await tester.pump(const Duration(milliseconds: 300)); // its switch-out
      await tester.pump();
      expect(owner.activations, 0, reason: 'nothing touched her: the gate alone must hide it');
      expect(owner.observed, isNotEmpty);
      expect(owner.observed.last.blocked, isTrue, reason: 'the gate hears the room is busy');
      expect(find.text(_inviteText), findsNothing);
      expect(commands.where((c) => c.$1 == 'beckon').last.$2, {'prop': null});

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
    });
  });
}
