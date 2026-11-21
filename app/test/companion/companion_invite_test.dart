// Her invitation to rest, on the page: shown after a quiet stretch, silently,
// above the input; a yes goes through the cushion's own entry, once.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/companion/companion_initiative.dart';
import 'package:dsh_app/companion/companion_initiative_owner.dart';
import 'package:dsh_app/companion/companion_keeper.dart';
import 'package:dsh_app/companion/companion_light.dart';
import 'package:dsh_app/companion/companion_memory.dart';
import 'package:dsh_app/companion/companion_pack.dart';
import 'package:dsh_app/l10n/gen/app_localizations.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/companion/companion_page.dart';
import 'package:dsh_app/ui/companion/companion_stage.dart';
import 'package:dsh_app/ui/theme/app_theme.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/companion.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'phone_keeper_fake.dart';
import 'initiative_memory.dart';
import 'companion_test_settle.dart';

const _invite = '要不要陪我在软垫上歇一会儿？';
const _followup = '对了，今天那把琴修好了吗？';
const _genericFollowup = '上次提到的这件事，现在想聊聊吗？';

class _Settings extends SettingsController {
  _Settings(this.apiKey);
  final String apiKey;
  @override
  AppSettings build() => AppSettings(loaded: true, apiKey: apiKey);
}

http.Response _generated(String text, {int outputTokens = 12, String stop = 'end_turn'}) => http.Response(
  [
    {
      'type': 'content_block_delta',
      'delta': {'type': 'text_delta', 'text': text},
    },
    {
      'type': 'message_delta',
      'delta': {'stop_reason': stop},
      'usage': {
        'input_tokens': 120,
        'cache_read_input_tokens': 0,
        'cache_creation_input_tokens': 0,
        'output_tokens': outputTokens,
      },
    },
    {'type': 'message_stop'},
  ].map((event) => 'data: ${jsonEncode(event)}\n\n').join(),
  200,
  headers: {'content-type': 'text/event-stream; charset=utf-8'},
);

void _seedFollowup(CompanionMemoryOwner memory, {bool invited = true}) {
  final raw = invited ? '我今天去修琴，今天可以问我琴修好没' : '我今天去修琴';
  memory.store.submitMessage(
    id: 'room-invitation',
    sessionId: memory.store.lightSessionId,
    text: raw,
    role: 'user',
    scope: 'real',
    saidAtUtc: 1793899800000,
    offsetMinutes: 0,
  );
  final batch = memory.store.nextBatch(forceTail: true, estimateTokens: (text) => text.runes.length)!;
  final proposal = parseExtractionProposal(
    jsonEncode({
      'schema_version': 2,
      'batch_id': batch.id,
      'covered_message_ids': ['room-invitation'],
      'completion': 'complete',
      'operations': [
        {
          'op': 'create',
          'kind': 'episode',
          'text': '我今天去修琴',
          'keywords': ['修琴', '琴'],
          'evidence': [
            {'message_id': 'room-invitation', 'quote': raw},
          ],
          'followup': {
            'local_date': '2026-11-05',
            'precision': 'day',
            'wording': invited ? '今天可以问我琴修好没' : raw,
            'basis': 'explicit_invitation',
          },
        },
      ],
    }),
    batch,
  );
  expect(memory.store.commitExtraction(batch, proposal), isTrue);
  memory.changed();
}

class _Room {
  _Room(this.tester, this.root);

  final WidgetTester tester;
  final Directory root;
  final phone = FakePhoneKeeper(state: FakePhoneKeeper.snapshotOf());
  final commands = <(String, Map<String, Object?>)>[];
  CompanionStageEvents? events;
  late CompanionMemoryOwner memory;
  late ProviderContainer container;
  DateTime? _clockStarted;
  int wallStart = 1793899800000;
  String apiKey = 'fixture-key';
  final requests = <Map<String, Object?>>[];
  Future<http.Response> Function(Map<String, Object?>)? answer;

  Iterable<String> get names => commands.map((c) => c.$1);

  Future<void> open({void Function(CompanionMemoryOwner)? seed}) async {
    events = null;
    final stageBuilt = Completer<void>();
    // A phone reports this long before the room opens; tests start with none,
    // and an unknown state never permits an invitation.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    Directory('${root.path}/pack/runtime').createSync(recursive: true);
    Directory('${root.path}/pack/character').createSync(recursive: true);
    File('${root.path}/pack/runtime/live2dcubismcore.min.js').writeAsStringSync('core');
    File('${root.path}/pack/character/index.json').writeAsStringSync('[]');
    File('${root.path}/pack/character/character.json').writeAsStringSync('{"name":"鲸鱼娘"}');
    // Both clocks follow the test's fake time, timers and all.
    final start = _clockStarted ??= tester.binding.clock.now();
    CompanionInitiativeClock clock() {
      final ms = tester.binding.clock.now().difference(start).inMilliseconds;
      return CompanionInitiativeClock(wallMs: wallStart + ms, monoMs: ms);
    }

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeConnectionProvider.overrideWithValue(const AsyncData<HostConnection?>(null)),
          companionPhoneKeeperProvider.overrideWithValue((_) => phone as CompanionKeeper),
          companionInitiativeClockProvider.overrideWithValue(clock),
          settingsProvider.overrideWith(() => _Settings(apiKey)),
          companionLightClientProvider.overrideWithValue(
            () => MockClient((request) async {
              final body = jsonDecode(request.body) as Map<String, Object?>;
              requests.add(body);
              if (answer != null) {
                return answer!(body);
              }
              expect(body['system'], companionMemoryFollowupPrompt);
              return _generated(jsonEncode({'action': 'line', 'text': _followup}));
            }),
          ),
          initiativeMemory(clock),
        ],
        child: MaterialApp(
          theme: buildDarkTheme(),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          locale: const Locale('zh'),
          home: CompanionPage(
            storeOverride: CompanionPackStore(root),
            stageBuilder: (controller, stage) {
              events = stage;
              if (!stageBuilt.isCompleted) {
                stageBuilt.complete();
              }
              return const SizedBox.expand();
            },
            stageController: CompanionStageController(sink: (type, args) => commands.add((type, args))),
          ),
        ),
      ),
    );
    await settleMixed(tester, stageBuilt.future);
    expect(events, isNotNull, reason: 'the stage was never built');
    container = ProviderScope.containerOf(tester.element(find.byType(CompanionPage)));
    memory = await settleMixed(tester, container.read(companionMemoryOwnerProvider(root.absolute.path).future));
    await settleMixed(tester, container.read(companionInitiativeProvider).ready);
    await settleMixed(tester, memory.migrateLocal());
    seed?.call(memory);
    events!.onReady();
    await settle();
  }

  /// Real file and preference work, then the frames it causes.
  Future<void> settle() async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  Future<void> wait(Duration time) async {
    for (var left = time; left > Duration.zero; left -= const Duration(seconds: 1)) {
      await tester.pump(const Duration(seconds: 1));
    }
  }

  Future<void> close() async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
  }

  Future<void> waitForFollowup() async {
    for (var second = 0; second < 70 && find.text(_followup).evaluate().isEmpty; second++) {
      await wait(const Duration(seconds: 1));
    }
    expect(find.text(_followup), findsOneWidget);
  }

  Future<void> waitForRequest() async {
    for (var second = 0; second < 70 && requests.isEmpty; second++) {
      await wait(const Duration(seconds: 1));
    }
    expect(requests, isNotEmpty);
  }

  Future<void> sendControl(String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.pump();
    await tester.tap(find.byIcon(AppIcons.send).last);
    await settle();
  }
}

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('companion-invite');
    SharedPreferences.setMockInitialValues({'companion_touch_hint_done': true, 'companion_home_hint_done': true});
  });
  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows can hold a file a moment longer; the system clears temp.
    }
  });

  for (final pace in ['off', 'rare', 'often', 'chatty']) {
    for (final invited in [true, false]) {
      testWidgets('fixture 9 $pace ${invited ? 'invitation' : 'date-only plan'} uses the actual room gate', (tester) async {
        SharedPreferences.setMockInitialValues({
          'companion_touch_hint_done': true,
          'companion_home_hint_done': true,
          'companion_initiative_enabled': pace != 'off',
          'companion_initiative_pace': pace == 'off' ? 'rare' : pace,
        });
        final room = _Room(tester, root);
        await room.open(seed: (memory) {
          _seedFollowup(memory, invited: invited);
          // Even the date-only proposal falsely labels itself an invitation.
          // The real store must qualify the original words before Page sees it.
          final candidate = memory.store.nextFollowup(nowMs: 1793899800000);
          expect(candidate != null, invited);
        });
        expect(room.memory.store.cards().single['text'], '我今天去修琴');
        var appearances = 0;
        var previouslyVisible = false;
        // Known virtual room opportunities exceed every existing pace's quiet
        // gate. Observe the actual bubble rather than inferring display from a row.
        for (var second = 0; second < 90; second++) {
          await room.wait(const Duration(seconds: 1));
          final visible = find.text(_followup).evaluate().isNotEmpty;
          if (visible && !previouslyVisible) {
            appearances++;
          }
          previouslyVisible = visible;
        }
        final expected = invited && pace != 'off' ? 1 : 0;
        expect(appearances, expected);
        final ledger = room.memory.store.initiativeRecord()!;
        expect(ledger['signalAtMs'], hasLength(expected));
        if (invited) {
          expect(room.memory.store.followups().single['state'], expected == 1 ? 'asked' : 'pending');
        } else {
          expect(room.memory.store.followups(), isEmpty);
        }
        if (pace == 'off') {
          expect(ledger['inviteAtMs'], isEmpty);
        }
        // An ordinary cushion invitation in a plan-only branch remains a
        // separate existing feature; only memory questions are counted here.
        expect(room.requests, hasLength(expected));
        final requests = room.memory.store.requests();
        expect(requests, hasLength(expected));
        if (expected == 1) {
          final request = room.requests.single;
          expect(request['system'], companionMemoryFollowupPrompt);
          expect(request['max_tokens'], 128);
          final input = jsonDecode(((request['messages']! as List).single as Map)['content']! as String) as Map;
          expect(input['card'], {'text': '我今天去修琴'});
          expect((input['invitation'] as Map)['quote'], '我今天去修琴，今天可以问我琴修好没');
          expect(requests.single['category'], 'followup');
          expect(requests.single['state'], 'finished');
          expect(((requests.single['raw_usage']! as Map)['final_usage'] as Map)['output_tokens'], 12);
        }
        await room.close();
      });
    }
  }

  testWidgets('an invited memory question stays visible and is not repeated after a silent restart', (tester) async {
    final room = _Room(tester, root);
    await room.open(seed: _seedFollowup);
    await room.waitForFollowup();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text(_followup), findsOneWidget, reason: 'its own bubble is not an external busy prompt');
    expect(room.memory.store.followups().single['state'], 'asked');
    expect(room.memory.store.initiativeRecord()!['signalAtMs'], hasLength(1));
    expect(room.requests, hasLength(1));
    final request = room.requests.single;
    expect(request['system'], companionMemoryFollowupPrompt);
    expect(request['max_tokens'], 128);
    expect(request.containsKey('tools'), isFalse);
    final messages = request['messages']! as List;
    expect(messages, hasLength(1));
    final input = jsonDecode((messages.single as Map)['content'] as String) as Map;
    expect(input['card'], {'text': '我今天去修琴'});
    expect(input['persona'], contains('鲸鱼娘'));
    expect(input['invitation'], {
      'message_id': 'room-invitation',
      'source_rev': 1,
      'said_at_utc': DateTime.fromMillisecondsSinceEpoch(1793899800000, isUtc: true).toIso8601String(),
      'offset_minutes': 0,
      'quote': '我今天去修琴，今天可以问我琴修好没',
    });
    expect(input['support'], isEmpty);
    expect(input.containsKey('history'), isFalse);
    final receipt = room.memory.store.requests().single;
    expect(receipt['category'], 'followup');
    expect(receipt['state'], 'finished');
    expect((receipt['raw_usage']! as Map)['final_usage'], containsPair('output_tokens', 12));
    expect(find.text(_genericFollowup), findsNothing);
    await room.close();
    await room.open();
    await room.wait(const Duration(minutes: 2));
    expect(find.text(_followup), findsNothing);
    expect(room.memory.store.followups().single['state'], 'asked');
    expect(room.memory.store.initiativeRecord()!['signalAtMs'], hasLength(1));
    expect(room.requests, hasLength(1), reason: 'asked remains consumed after reopening');
    await room.close();
  });

  for (final failure in ['offline', 'silent', 'invalid', 'max_tokens']) {
    testWidgets('B03 $failure wording stays silent without a display debit or idle request loop', (tester) async {
      final room = _Room(tester, root)
        ..answer = (_) async {
          if (failure == 'offline') {
            throw http.ClientException('fixture offline');
          }
          if (failure == 'silent') {
            return _generated('{"action":"silent","text":""}');
          }
          if (failure == 'invalid') {
            return _generated('not JSON');
          }
          return _generated('{"action":"line","text":"$_followup"}', stop: 'max_tokens');
        };
      await room.open(seed: _seedFollowup);
      await room.waitForRequest();
      await room.wait(const Duration(minutes: 3));
      expect(room.requests, hasLength(1));
      expect(find.text(_followup), findsNothing);
      expect(find.text(_genericFollowup), findsNothing);
      expect(room.memory.store.followups().single['state'], 'pending');
      expect(room.memory.store.initiativeRecord()!['signalAtMs'], isEmpty);
      expect(room.memory.store.requests().single['category'], 'followup');
      expect(room.memory.store.requests().single['sent_at_ms'], isNotNull);
      await room.close();
    });
  }

  testWidgets('B03 a later room visit can retry failed wording and show the new actual line', (tester) async {
    final room = _Room(tester, root)..answer = (_) async => _generated('{"action":"silent","text":""}');
    await room.open(seed: _seedFollowup);
    await room.waitForRequest();
    await tester.pump();
    expect(room.memory.store.initiativeRecord()!['signalAtMs'], isEmpty);
    await room.close();
    room.answer = null;
    await room.open();
    await room.waitForFollowup();
    expect(room.requests, hasLength(2));
    expect(room.memory.store.requests().where((row) => row['category'] == 'followup'), hasLength(2));
    expect(room.memory.store.initiativeRecord()!['signalAtMs'], hasLength(1));
    await room.close();
  });

  testWidgets('B03 absent credentials keep the current invitation pending without any HTTP', (tester) async {
    final room = _Room(tester, root)..apiKey = '';
    await room.open(seed: _seedFollowup);
    await room.wait(const Duration(minutes: 2));
    expect(room.requests, isEmpty);
    expect(room.memory.store.requests(), isEmpty);
    expect(room.memory.store.followups().single['state'], 'pending');
    expect(room.memory.store.initiativeRecord()!['signalAtMs'], isEmpty);
    expect(find.text(_followup), findsNothing);
    expect(find.text(_genericFollowup), findsNothing);
    await room.close();
  });

  testWidgets('B03 actual auxiliary usage exhausting the shared output budget suppresses the Page wording POST', (tester) async {
    final room = _Room(tester, root)
      ..answer = (body) async {
        expect(body['system'], companionMemoryExtractionPrompt);
        final messages = body['messages']! as List;
        final input = jsonDecode((messages.single as Map)['content'] as String) as Map;
        return _generated(
          jsonEncode({
            'schema_version': 2,
            'batch_id': input['batch_id'],
            'covered_message_ids': [for (final source in input['source'] as List) (source as Map)['id']],
            'operations': [],
            'completion': 'complete',
          }),
          outputTokens: 720,
        );
      };
    await room.open(seed: _seedFollowup);
    for (var i = 0; i < 4; i++) {
      room.memory.store.submitMessage(
        id: 'budget-source-$i',
        sessionId: room.memory.store.lightSessionId,
        text: '今天随便聊聊$i。',
        saidAtUtc: room.wallStart,
        offsetMinutes: 0,
      );
      await settleMixed(tester, room.memory.extract(tester.state(find.byType(CompanionPage)), forceTail: true));
    }
    expect(room.requests, hasLength(4));
    expect(room.memory.store.requests().map((row) => row['category']), everyElement('extract'));
    expect(room.memory.store.requests().map((row) => (row['raw_usage']! as Map)['output_tokens']), everyElement(720));
    await room.wait(const Duration(minutes: 2));
    expect(room.requests, hasLength(4), reason: 'four 720-token receipts leave 120, less than the 128-token followup reservation');
    expect(room.memory.store.requests().where((row) => row['category'] == 'followup'), isEmpty);
    expect(room.memory.store.followups().single['state'], 'pending');
    expect(room.memory.store.initiativeRecord()!['signalAtMs'], isEmpty);
    expect(find.text(_followup), findsNothing);
    expect(find.text(_genericFollowup), findsNothing);
    await room.close();
  });

  for (final control in ['修琴取消了', '以后别提修琴']) {
    testWidgets('B03 $control arriving during generation fences the late wording but retains usage', (tester) async {
      final answer = Completer<http.Response>();
      final room = _Room(tester, root)..answer = (_) => answer.future;
      await room.open(seed: _seedFollowup);
      await room.waitForRequest();
      expect(room.memory.store.initiativeRecord()!['signalAtMs'], isEmpty, reason: 'no display reserve during HTTP');
      expect(room.memory.store.followups().single['state'], 'pending');
      await room.sendControl(control);
      answer.complete(_generated('{"action":"line","text":"$_followup"}'));
      await room.settle();
      expect(find.text(_followup), findsNothing);
      expect(find.text(_genericFollowup), findsNothing);
      expect(room.memory.store.initiativeRecord()!['signalAtMs'], isEmpty);
      expect(room.memory.store.requests().where((row) => row['category'] == 'followup'), hasLength(1));
      final receipt = room.memory.store.requests().singleWhere((row) => row['category'] == 'followup');
      expect(receipt['sent_at_ms'], isNotNull);
      expect(receipt['state'], 'finished');
      await room.close();
    });
  }

  testWidgets('B03 wording completed after 23:00 is not presented or spent', (tester) async {
    final answer = Completer<http.Response>();
    final room = _Room(tester, root)
      ..wallStart = DateTime.utc(2026, 11, 5, 22, 59).millisecondsSinceEpoch
      ..answer = (_) => answer.future;
    await room.open(seed: _seedFollowup);
    await room.waitForRequest();
    expect(room.memory.store.initiativeRecord()!['signalAtMs'], isEmpty);
    // Cross the exact local boundary, keeping both clocks moving together.
    final stamp = room.container.read(companionInitiativeClockProvider)();
    final remaining = DateTime.utc(2026, 11, 5, 23).millisecondsSinceEpoch - stamp.wallMs;
    expect(remaining, inExclusiveRange(0, 30000));
    await tester.pump(Duration(milliseconds: remaining + 1));
    answer.complete(_generated('{"action":"line","text":"$_followup"}'));
    await room.settle();
    expect(find.text(_followup), findsNothing);
    expect(find.text(_genericFollowup), findsNothing);
    expect(room.memory.store.initiativeRecord()!['signalAtMs'], isEmpty);
    expect(room.memory.store.requests().single['category'], 'followup');
    await room.close();
  });

  for (final (control, state) in [('修琴取消了', 'cancelled'), ('修琴改期，时间还没定', 'postponed')]) {
    testWidgets('a pending memory question yields to $state through the real composer', (tester) async {
      final room = _Room(tester, root);
      await room.open(seed: _seedFollowup);
      await room.wait(const Duration(seconds: 15));
      expect(room.memory.store.followups().single['state'], 'pending');
      await tester.enterText(find.byType(TextField), control);
      await tester.pump();
      await tester.tap(find.byIcon(AppIcons.send).last);
      await room.settle();
      expect(room.memory.store.cards().single['plan_state'], state);
      await room.wait(const Duration(minutes: 2));
      expect(find.text(_followup), findsNothing);
      expect(room.memory.store.initiativeRecord()!['signalAtMs'], isEmpty);
      expect(room.memory.store.requests(), isEmpty);
      await room.close();
    });
  }

  testWidgets('deleting the source withdraws the currently shown memory question without refunding it', (tester) async {
    final room = _Room(tester, root);
    await room.open(seed: _seedFollowup);
    await room.waitForFollowup();
    final source = room.memory.store.messages().singleWhere((row) => row['id'] == 'room-invitation');
    room.memory.store.deleteMessage(id: source['id']! as String, expectedSourceRev: source['source_rev']! as int);
    room.memory.changed();
    await tester.pump();
    expect(find.text(_followup), findsNothing);
    expect(room.memory.store.initiativeRecord()!['signalAtMs'], hasLength(1));
    await room.close();
  });

  testWidgets('a vanished question bubble still owns unfinished speech until the room backgrounds', (tester) async {
    SharedPreferences.setMockInitialValues({
      'companion_touch_hint_done': true,
      'companion_home_hint_done': true,
      'companion_voice_enabled': true,
      'companion_voice_v1': '{"source":"system"}',
    });
    const channel = MethodChannel('dsh/companion_voice');
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'ready' || 'speak' => true,
        _ => null,
      };
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    final room = _Room(tester, root);
    await room.open(seed: _seedFollowup);
    final greeting = calls.where((call) => call.method == 'speak').single.arguments as Map;
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall('event', {'type': 'done', 'id': greeting['id']})),
      (_) {},
    );
    await tester.pump();
    await room.waitForFollowup();
    expect(calls.where((call) => call.method == 'speak' && (call.arguments as Map)['text'] == _followup), hasLength(1));
    // No completion callback for that sentence: its speech is still pending.
    await room.wait(const Duration(seconds: 6));
    expect(find.text(_followup), findsNothing);
    final stops = calls.where((call) => call.method == 'stop').length;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(calls.where((call) => call.method == 'stop').length, greaterThan(stops));
    expect(room.memory.store.initiativeRecord()!['signalAtMs'], hasLength(1));
    await room.close();
  });

  testWidgets('after a quiet while she asks, silently; yes takes her to the cushion once', (tester) async {
    final room = _Room(tester, root);
    await room.open();
    // Her greeting first; the quiet only starts once it's gone.
    // Her greeting is on screen for about five seconds; the quiet starts after it.
    await room.wait(const Duration(seconds: 44));
    expect(find.text(_invite), findsNothing);
    await room.wait(const Duration(seconds: 8));
    expect(find.text(_invite), findsOneWidget);
    expect(room.names, containsAll(['glance', 'beckon']));
    // Nothing spoken for it: no mouth, no words.
    final shownAt = room.commands.lastIndexWhere((c) => c.$1 == 'beckon');
    expect(room.names.skip(shownAt).where((n) => n == 'say'), isEmpty);
    expect(tester.binding.focusManager.primaryFocus?.context?.widget, isNot(isA<EditableText>()));

    await tester.tap(find.text('好呀'));
    await room.settle();
    expect(room.phone.events.where((e) => e == 'rest'), hasLength(1));
    expect(room.commands.where((c) => c.$1 == 'prop').single.$2, {'name': 'rest'});
    expect(room.commands.where((c) => c.$1 == 'beckon').last.$2, {'prop': null});
    await room.wait(const Duration(seconds: 2));
    expect(find.text(_invite), findsNothing);
    expect(find.textContaining(RegExp('歇一小会儿|躺好啦')), findsOneWidget);

    // One per visit.
    await room.wait(const Duration(minutes: 2));
    expect(find.text(_invite), findsNothing);
    await room.close();
  });

  testWidgets('not now: she nods, nothing else happens', (tester) async {
    final room = _Room(tester, root);
    await room.open();
    await room.wait(const Duration(seconds: 52));
    expect(find.text(_invite), findsOneWidget);
    room.commands.clear();

    await tester.tap(find.text('等会儿'));
    await room.settle();
    expect(room.commands.where((c) => c.$1 == 'action').single.$2, {'name': 'nodSmall'});
    expect(room.phone.events, isNot(contains('rest')));
    expect(room.names, isNot(contains('say')));
    await room.wait(const Duration(seconds: 1));
    expect(find.text(_invite), findsNothing);
    expect(room.memory.store.initiativeRecord()!['declinedUntilMs'], greaterThan(1793899800000));
    await room.close();
  });

  testWidgets('left alone it goes by itself after a few seconds', (tester) async {
    final room = _Room(tester, root);
    await room.open();
    await room.wait(const Duration(seconds: 52));
    expect(find.text(_invite), findsOneWidget);
    await room.wait(const Duration(seconds: 9));
    expect(find.text(_invite), findsNothing);
    expect(room.phone.events, isNot(contains('rest')));
    await room.close();
  });

  testWidgets('touching her first means no invitation this visit', (tester) async {
    final room = _Room(tester, root);
    await room.open();
    await room.wait(const Duration(seconds: 20));
    await tester.tapAt(const Offset(200, 300));
    await room.wait(const Duration(minutes: 2));
    expect(find.text(_invite), findsNothing);
    await room.close();
  });

  testWidgets('switched off in her menu: no invitation', (tester) async {
    SharedPreferences.setMockInitialValues({
      'companion_touch_hint_done': true,
      'companion_home_hint_done': true,
      'companion_initiative_enabled': false,
    });
    final room = _Room(tester, root);
    await room.open();
    await room.wait(const Duration(minutes: 2));
    expect(find.text(_invite), findsNothing);
    await room.close();
  });
}
