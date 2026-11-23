// Her invitation to rest, on the page: shown after a quiet stretch, silently,
// above the input; a yes goes through the cushion's own entry, once.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/companion/companion_initiative.dart';
import 'package:dsh_app/companion/companion_initiative_owner.dart';
import 'package:dsh_app/companion/companion_keeper.dart';
import 'package:dsh_app/companion/companion_memory.dart';
import 'package:dsh_app/companion/companion_pack.dart';
import 'package:dsh_app/companion/companion_context.dart' show estimateCompanionMemoryTokens;
import 'package:dsh_app/companion/companion_state.dart' show companionLightClientProvider;
import 'package:dsh_app/l10n/gen/app_localizations.dart';
import 'package:dsh_app/state/companion_agent_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/companion/companion_chrome.dart';
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
import 'package:sqlite3/sqlite3.dart';

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
      'index': 0,
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

String? _cardId;

/// One complete model tool call, as the Messages stream delivers it.
http.Response _toolUse(String id, String name, Map<String, Object?> input) => http.Response(
  [
    {
      'type': 'content_block_start',
      'index': 0,
      'content_block': {'type': 'tool_use', 'id': id, 'name': name, 'input': <String, Object?>{}},
    },
    {
      'type': 'content_block_delta',
      'index': 0,
      'delta': {'type': 'input_json_delta', 'partial_json': jsonEncode(input)},
    },
    {'type': 'content_block_stop', 'index': 0},
    {
      'type': 'message_delta',
      'delta': {'stop_reason': 'tool_use'},
      'usage': {'input_tokens': 120, 'output_tokens': 9},
    },
    {'type': 'message_stop'},
  ].map((event) => 'data: ${jsonEncode(event)}\n\n').join(),
  200,
  headers: {'content-type': 'text/event-stream; charset=utf-8'},
);

String _requestKind(Map<String, Object?> body) {
  if (body['system'] == companionMemoryFollowupPrompt) {
    return 'followup';
  }
  final messages = body['messages']! as List;
  final content = (messages.first as Map)['content'];
  if (content is String) {
    Object? input;
    try {
      input = jsonDecode(content);
    } on FormatException {
      // Ordinary conversation is not the maintenance JSON envelope.
    }
    if (input is Map && input['type'] == 'memory_maintenance_context') {
      return input['kind']! as String;
    }
  }
  return 'chat';
}

Future<http.Response> _conversationReply(Map<String, Object?> body) async {
  if (_requestKind(body) == 'followup') {
    return _generated(jsonEncode({'action': 'line', 'text': _followup}));
  }
  return _generated('我听到了。');
}

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

// Observe the actual Page preparation future; all owner gates stay in super.
class _FollowupPreparation extends CompanionInitiative {
  _FollowupPreparation(super.clock);
  Future<bool>? work;
  final outcomes = <String>[];

  @override
  bool requestSignal(
    CompanionInitiativeRoom room,
    CompanionInitiativeView view,
    CompanionInitiativeSignal candidate, {
    required bool Function() isCurrent,
    required bool Function(CompanionInitiativeDisplay) present,
    required void Function(String) hide,
    bool nightCareEnabled = false,
    String? followupId,
    Future<bool> Function()? prepare,
    void Function()? cancelPrepare,
    Future<bool> Function(CompanionInitiativeDisplay)? deliver,
    void Function(Future<void>)? retainDelivery,
    String? noticeEventId,
    String? noticePersonId,
    void Function(String)? settled,
  }) => super.requestSignal(
    room,
    view,
    candidate,
    isCurrent: isCurrent,
    present: present,
    hide: hide,
    nightCareEnabled: nightCareEnabled,
    followupId: followupId,
    cancelPrepare: cancelPrepare,
    deliver: deliver,
    retainDelivery: retainDelivery,
    noticeEventId: noticeEventId,
    noticePersonId: noticePersonId,
    settled: settled,
    prepare: prepare == null
        ? null
        : () {
            final result = work = prepare();
            final index = outcomes.length;
            outcomes.add('pending');
            unawaited(
              result.then<void>(
                (ready) {
                  outcomes[index] = '$ready';
                },
                onError: (Object error) {
                  outcomes[index] = 'error: $error';
                },
              ),
            );
            return result;
          },
  );
}

class _Room {
  _Room(this.tester, this.root, {this.capturePreparation = true});

  final WidgetTester tester;
  final Directory root;
  final bool capturePreparation;
  late _FollowupPreparation preparation;
  final phone = FakePhoneKeeper(state: FakePhoneKeeper.snapshotOf());
  final commands = <(String, Map<String, Object?>)>[];
  CompanionStageEvents? events;
  late CompanionMemoryOwner memory;
  late ProviderContainer container;
  DateTime? _clockStarted;
  int wallStart = 1793899800000;
  String apiKey = 'fixture-key';
  final requests = <Map<String, Object?>>[];
  final defaultRequests = <Map<String, Object?>>[];
  Future<http.Response> Function(Map<String, Object?>)? answer;
  Future<http.Response> Function(Map<String, Object?>)? maintenanceAnswer;

  Iterable<Map<String, Object?>> get followupRequests => requests.where((body) => _requestKind(body) == 'followup');
  Iterable<MemoryRow> get followupReceipts => memory.store.requests().where((row) => row['category'] == 'followup');

  Iterable<String> get names => commands.map((c) => c.$1);

  String get followupObservation => jsonEncode({
    'preparation': capturePreparation ? preparation.outcomes : null,
    'ownerFault': container.read(companionInitiativeProvider).fault,
    'opportunities': [
      for (final row in memory.store.followups())
        {
          for (final key in ['state', 'row_rev', 'card_rev', 'control_revision', 'reason']) key: row[key],
        },
    ],
    'requests': [for (final body in requests) _requestKind(body)],
    'receipts': [
      for (final row in memory.store.requests().where((row) => row['category'] == 'followup'))
        {
          for (final key in ['state', 'terminal', 'sent_at_ms']) key: row[key],
          'complete': (row['raw_usage'] as Map<String, Object?>?)?['complete'],
        },
    ],
    'signalAtMs': memory.store.initiativeRecord()?['signalAtMs'],
  });

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
          if (capturePreparation)
            companionInitiativeProvider.overrideWith((ref) {
              final owner = preparation = _FollowupPreparation(clock);
              ref.onDispose(owner.dispose);
              return owner;
            }),
          settingsProvider.overrideWith(() => _Settings(apiKey)),
          companionLightClientProvider.overrideWithValue(
            () => MockClient((request) async {
              final body = jsonDecode(request.body) as Map<String, Object?>;
              requests.add(body);
              final kind = _requestKind(body);
              if (kind == 'extract' || kind == 'organize') {
                if (maintenanceAnswer != null) return maintenanceAnswer!(body);
                // Let the actual maintenance claim finish with a normal
                // Messages end_turn. It is not a chat or a followup attempt.
                return _generated('');
              }
              if (answer != null) {
                return answer!(body);
              }
              defaultRequests.add(body);
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

  /// Fake seconds, each preceded by one real event-loop turn. Leaving an
  /// `await for` early (the light reply returns at message_stop) awaits a
  /// subscription cancel whose completed future lives in the root zone, so its
  /// continuation is a real microtask that fake pumps alone never run.
  Future<void> wait(Duration time) async {
    for (var left = time; left > Duration.zero; left -= const Duration(seconds: 1)) {
      await tester.runAsync(() async {});
      await tester.pump(const Duration(seconds: 1));
    }
  }

  Future<void> close() async {
    // Check the real maintenance receipts outside the transport callback:
    // its catch must not turn a fixture assertion into a hidden network error.
    Iterable<MemoryRow> maintenanceReceipts() =>
        memory.store.requests().where((row) => row['category'] == 'extract' || row['category'] == 'organize');
    for (var i = 0; i < 100 && memory.working; i++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
    }
    if (maintenanceReceipts().isNotEmpty) {
      expect(memory.working, isFalse, reason: 'the real maintenance claim drains before the room closes');
    }
    for (final kind in ['extract', 'organize']) {
      final receipts = maintenanceReceipts().where((row) => row['category'] == kind).toList();
      expect(receipts, hasLength(requests.where((body) => _requestKind(body) == kind).length));
      for (final receipt in receipts) {
        expect(receipt['state'], 'finished');
        expect(receipt['terminal'], 'complete');
        expect((receipt['raw_usage']! as Map)['complete'], isTrue);
      }
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
    // The timer callback records its observation; a guarded test assertion
    // belongs after pump, outside the production transport's error handler.
    expect(defaultRequests.map((body) => body['system']), everyElement(companionMemoryFollowupPrompt));
  }

  Future<void> waitForFollowup() async {
    for (var second = 0; second < 70 && find.text(_followup).evaluate().isEmpty; second++) {
      await wait(const Duration(seconds: 1));
    }
    expect(find.text(_followup), findsOneWidget, reason: followupObservation);
  }

  Future<void> waitForRequest() async {
    for (var second = 0; second < 70 && followupRequests.isEmpty; second++) {
      await wait(const Duration(seconds: 1));
    }
    expect(followupRequests, isNotEmpty);
  }

  Future<void> sendControl(String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.pump();
    await tester.tap(find.byIcon(AppIcons.send).last);
    await settle();
  }

  Future<MemoryRow> sendChat(String text) async {
    final before = memory.store.requests().map((row) => row['id']).toSet();
    final terminal = Completer<MemoryRow>();
    void receiptChanged() {
      for (final row in memory.store.requests()) {
        if (!terminal.isCompleted &&
            row['category'] == 'chat' &&
            !before.contains(row['id']) &&
            row['state'] == 'finished') {
          terminal.complete(row);
        }
      }
    }

    memory.addListener(receiptChanged);
    try {
      await tester.enterText(find.byType(TextField), text);
      await tester.pump();
      await tester.tap(find.byIcon(AppIcons.send).last);
      final receipt = await settleMixed(tester, terminal.future);
      await tester.pump();
      // The phone loop settles its receipt before the stream's cancel drain;
      // the reply row and the idle composer follow on that real future.
      for (var i = 0; i < 100 && tester.widget<CompanionComposer>(find.byType(CompanionComposer)).running; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
        await tester.pump();
      }
      expect(receipt['terminal'], 'complete');
      return receipt;
    } finally {
      memory.removeListener(receiptChanged);
    }
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
      testWidgets('fixture 9 $pace ${invited ? 'invitation' : 'date-only plan'} uses the actual room gate', (
        tester,
      ) async {
        SharedPreferences.setMockInitialValues({
          'companion_touch_hint_done': true,
          'companion_home_hint_done': true,
          'companion_initiative_enabled': pace != 'off',
          'companion_initiative_pace': pace == 'off' ? 'rare' : pace,
        });
        final room = _Room(tester, root);
        await room.open(
          seed: (memory) {
            _seedFollowup(memory, invited: invited);
            // Even the date-only proposal falsely labels itself an invitation.
            // The real store must qualify the original words before Page sees it.
            final candidate = memory.store.nextFollowup(nowMs: 1793899800000);
            expect(candidate != null, invited);
          },
        );
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
        expect(appearances, expected, reason: room.followupObservation);
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
        expect(room.followupRequests, hasLength(expected));
        final requests = room.followupReceipts.toList();
        expect(requests, hasLength(expected));
        if (expected == 1) {
          final request = room.followupRequests.single;
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

  for (final (label, raw, farewell) in [
    ('farewell', '晚安，我先走了', true),
    ('English farewell', 'Good night.', true),
    ('ordinary chat', '我今天想聊点别的', false),
    ('quoted farewell', '“晚安，我先走了”这句话怎么翻译？', false),
    ('negated farewell', '我还不想说再见，我们继续聊。', false),
    ('story dialogue', '故事里我说：“晚安，我先走了”。', false),
  ]) {
    testWidgets(
      label == 'farewell'
          ? 'saying goodbye before the pending question is shown retires this visit without a spend'
          : 'fixture 11 $label is distinguished after a successful chat becomes idle',
      (tester) async {
        final room = _Room(tester, root)..answer = _conversationReply;
        await room.open(seed: _seedFollowup);
        await room.wait(const Duration(seconds: 15));
        final opportunity = room.memory.store.followups().single;
        expect(opportunity['state'], 'pending');
        expect(find.text(_followup), findsNothing);
        final receipt = await room.sendChat(raw);
        final chats = room.requests.where((body) => _requestKind(body) == 'chat');
        expect(chats, hasLength(1));
        expect(jsonEncode(chats.single), contains(raw));
        expect(room.memory.store.messages().where((row) => row['role'] == 'user' && row['text'] == raw), hasLength(1));
        expect(
          room.memory.store.messages().where((row) => row['role'] == 'assistant' && row['text'] == '我听到了。'),
          hasLength(1),
        );
        expect(receipt['sent_at_ms'], isNotNull);
        expect((receipt['raw_usage']! as Map)['complete'], isTrue);
        var composer = tester.widget<CompanionComposer>(find.byType(CompanionComposer));
        expect(composer.input.text, isEmpty, reason: 'a failed send must not masquerade as a farewell gate');
        expect(composer.busy, isFalse);
        expect(composer.running, isFalse);
        expect(composer.listening, isFalse);
        composer.focus.unfocus();
        await tester.pump();
        await room.wait(const Duration(seconds: 12));
        composer = tester.widget<CompanionComposer>(find.byType(CompanionComposer));
        expect(composer.focus.hasFocus, isFalse);
        expect(composer.input.text, isEmpty);
        expect(tester.widget<CompanionMyLine>(find.byType(CompanionMyLine)).text, isNull);
        final speech = tester.widget<CompanionSpeech>(find.byType(CompanionSpeech));
        expect(speech.text, isNull);
        expect(speech.thinking, isFalse);
        expect(room.memory.store.initiativeRecord()!['signalAtMs'], isEmpty);
        var appearances = 0;
        var visible = false;
        for (var second = 0; second < 120; second++) {
          await room.wait(const Duration(seconds: 1));
          final next = find.text(_followup).evaluate().isNotEmpty;
          if (next && !visible) {
            appearances++;
          }
          visible = next;
        }
        expect(appearances, farewell ? 0 : 1, reason: room.followupObservation);
        expect(room.memory.store.followups().single['state'], farewell ? 'pending' : 'asked');
        expect(room.memory.store.initiativeRecord()!['signalAtMs'], hasLength(farewell ? 0 : 1));
        final generated = room.requests.where((body) => body['system'] == companionMemoryFollowupPrompt);
        expect(generated, hasLength(farewell ? 0 : 1));
        final auxiliary = room.memory.store.requests().where((row) => row['category'] == 'followup');
        expect(auxiliary, hasLength(farewell ? 0 : 1));
        if (!farewell) {
          expect(auxiliary.single['state'], 'finished');
          expect(((auxiliary.single['raw_usage']! as Map)['final_usage'] as Map)['output_tokens'], 12);
        }
        expect(chats, hasLength(1));
        if (label == 'farewell') {
          await room.close();
          await room.open();
          await room.waitForFollowup();
          expect(room.memory.store.followups().single['id'], opportunity['id']);
          expect(room.memory.store.followups().single['state'], 'asked');
          expect(room.memory.store.initiativeRecord()!['signalAtMs'], hasLength(1));
          expect(room.requests.where((body) => body['system'] == companionMemoryFollowupPrompt), hasLength(1));
          expect(chats, hasLength(1));
          expect(
            room.requests.where((body) => _requestKind(body) == 'extract'),
            isNotEmpty,
            reason: 'the submitted original receives its real tail opportunity',
          );
        }
        await room.close();
      },
    );
  }

  testWidgets('fixture 11 a failed farewell source does not retire the invitation after the draft is cleared', (
    tester,
  ) async {
    final room = _Room(tester, root)..answer = _conversationReply;
    await room.open(seed: _seedFollowup);
    await room.wait(const Duration(seconds: 15));
    final before = room.memory.store.messages();
    final db = sqlite3.open('${root.path}/memory.sqlite');
    db.execute(
      "CREATE TRIGGER reject_farewell BEFORE INSERT ON memory_events BEGIN SELECT RAISE(ABORT,'fixture'); END",
    );
    db.close();
    await tester.enterText(find.byType(TextField), '晚安，我先走了');
    await tester.pump();
    await tester.tap(find.byIcon(AppIcons.send).last);
    await room.settle();
    await tester.pumpAndSettle();
    expect(room.requests, isEmpty);
    expect(room.memory.store.messages(), before);
    expect(room.memory.store.requests(), isEmpty);
    expect(find.text('这句话没送出去，要不要再说一次？'), findsOneWidget);
    expect(tester.widget<CompanionComposer>(find.byType(CompanionComposer)).input.text, '晚安，我先走了');
    final recovered = sqlite3.open('${root.path}/memory.sqlite');
    recovered.execute('DROP TRIGGER reject_farewell');
    recovered.close();
    await tester.enterText(find.byType(TextField), '');
    tester.widget<CompanionComposer>(find.byType(CompanionComposer)).focus.unfocus();
    await tester.pump();
    await room.wait(const Duration(seconds: 8));
    expect(tester.widget<CompanionComposer>(find.byType(CompanionComposer)).focus.hasFocus, isFalse);
    expect(tester.widget<CompanionSpeech>(find.byType(CompanionSpeech)).text, isNull);
    await room.waitForFollowup();
    expect(room.memory.store.followups().single['state'], 'asked');
    expect(room.memory.store.initiativeRecord()!['signalAtMs'], hasLength(1));
    expect(room.followupRequests, hasLength(1));
    expect(room.followupRequests.single['system'], companionMemoryFollowupPrompt);
    expect(room.followupReceipts.single['category'], 'followup');
    await room.close();
  });

  testWidgets('fixture 11 a successful farewell during generation fences late wording without a display debit', (
    tester,
  ) async {
    final answer = Completer<http.Response>();
    addTearDown(() {
      if (!answer.isCompleted) {
        answer.complete(http.Response('', 499));
      }
    });
    final room = _Room(tester, root, capturePreparation: true)
      ..answer = (body) => body['system'] == companionMemoryFollowupPrompt ? answer.future : _conversationReply(body);
    await room.open(seed: _seedFollowup);
    await room.waitForRequest();
    expect(room.followupRequests.single['system'], companionMemoryFollowupPrompt);
    final followupRequest = room.followupReceipts.single;
    expect(followupRequest['category'], 'followup');
    expect(followupRequest['sent_at_ms'], isNotNull);
    expect(room.memory.store.initiativeRecord()!['signalAtMs'], isEmpty);
    await room.sendChat('晚安，我先走了');
    var composer = tester.widget<CompanionComposer>(find.byType(CompanionComposer));
    expect(composer.input.text, isEmpty);
    expect(composer.busy, isFalse);
    expect(composer.running, isFalse);
    composer.focus.unfocus();
    await tester.pump();
    final prepared = room.preparation.work!;
    answer.complete(_generated(jsonEncode({'action': 'line', 'text': _followup})));
    expect(await settleMixed(tester, prepared), isFalse);
    final receipt = room.memory.store.requests().singleWhere((row) => row['id'] == followupRequest['id']);
    expect(receipt['state'], 'finished');
    expect(receipt['terminal'], 'complete');
    expect(((receipt['raw_usage']! as Map)['final_usage'] as Map)['output_tokens'], 12);
    await room.wait(const Duration(seconds: 120));
    composer = tester.widget<CompanionComposer>(find.byType(CompanionComposer));
    expect(composer.focus.hasFocus, isFalse);
    expect(composer.input.text, isEmpty);
    expect(tester.widget<CompanionSpeech>(find.byType(CompanionSpeech)).text, isNull);
    expect(find.text(_followup), findsNothing);
    expect(room.memory.store.followups().single['state'], 'pending');
    expect(room.memory.store.initiativeRecord()!['signalAtMs'], isEmpty);
    expect(room.requests.where((body) => body['system'] == companionMemoryFollowupPrompt), hasLength(1));
    expect(room.memory.store.requests().where((row) => row['category'] == 'chat'), hasLength(1));
    await room.close();
  });

  testWidgets('an invited memory question stays visible and is not repeated after a silent restart', (tester) async {
    final room = _Room(tester, root);
    await room.open(seed: _seedFollowup);
    await room.waitForFollowup();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text(_followup), findsOneWidget, reason: 'its own bubble is not an external busy prompt');
    expect(room.memory.store.followups().single['state'], 'asked');
    expect(room.memory.store.initiativeRecord()!['signalAtMs'], hasLength(1));
    expect(room.followupRequests, hasLength(1));
    final request = room.followupRequests.single;
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
    final receipt = room.followupReceipts.single;
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
    expect(room.followupRequests, hasLength(1), reason: 'asked remains consumed after reopening');
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
      expect(room.followupRequests, hasLength(1));
      expect(find.text(_followup), findsNothing);
      expect(find.text(_genericFollowup), findsNothing);
      expect(room.memory.store.followups().single['state'], 'pending');
      expect(room.memory.store.initiativeRecord()!['signalAtMs'], isEmpty);
      expect(room.followupReceipts.single['category'], 'followup');
      expect(room.followupReceipts.single['sent_at_ms'], isNotNull);
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
    expect(room.followupRequests, hasLength(2));
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

  testWidgets('B03 actual auxiliary usage exhausting the shared output budget suppresses the Page wording POST', (
    tester,
  ) async {
    var maintenanceCalls = 0;
    final room = _Room(tester, root)
      ..maintenanceAnswer = (body) async {
        final messages = body['messages']! as List;
        final input = jsonDecode((messages.single as Map)['content'] as String) as Map;
        expect(input['type'], 'memory_maintenance_context');
        expect(input['kind'], 'extract');
        expect((input['sources'] as List).map((source) => (source as Map)['id']), [
          'budget-source-${maintenanceCalls++}',
        ]);
        expect((body['tools'] as List).map((tool) => (tool as Map)['name']), contains('remember'));
        expect(body['max_tokens'], 800);
        // A real complete end_turn with no tool calls finishes this source;
        // each physical Messages request reports its actual fixed usage.
        return _generated('这轮没有新增记忆。', outputTokens: 720);
      };
    await room.open(seed: _seedFollowup);
    // The room's worker belongs to its process-level visit, which a test cannot
    // name. Run the same owner's real extraction under a stand-in room, then
    // hand the owner back to a fresh actual visit for the wording opportunity.
    final standIn = Object();
    room.memory.enter(
      standIn,
      transport: () => room.container.read(companionAgentMemoryTransportProvider),
      estimateTokens: estimateCompanionMemoryTokens,
    );
    for (var i = 0; i < 4; i++) {
      room.memory.store.submitMessage(
        id: 'budget-source-$i',
        sessionId: room.memory.store.lightSessionId,
        text: '今天随便聊聊$i。',
        saidAtUtc: room.wallStart,
        offsetMinutes: 0,
      );
      await settleMixed(tester, room.memory.extract(standIn, forceTail: true, offsetMinutes: 0));
      expect(
        room.memory.store.messages().singleWhere((source) => source['id'] == 'budget-source-$i')['extraction_state'],
        'done',
      );
    }
    room.memory.leave(standIn);
    await room.close();
    await room.open();
    expect(maintenanceCalls, 4);
    expect(room.requests, hasLength(4));
    expect(
      room.requests.map((body) => body['system']),
      everyElement(contains('phone memory using the supplied memory tools')),
    );
    expect(room.memory.store.requests().map((row) => row['id']).toSet(), hasLength(4));
    expect(room.memory.store.requests().map((row) => row['state']), everyElement('finished'));
    expect(room.memory.store.requests().map((row) => row['category']), everyElement('extract'));
    expect(room.memory.store.requests().map((row) => (row['raw_usage']! as Map)['output_tokens']), everyElement(720));
    await room.wait(const Duration(minutes: 2));
    expect(
      room.requests,
      hasLength(4),
      reason: 'four 720-token receipts leave 120, less than the 128-token followup reservation',
    );
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
    expect(room.followupReceipts.single['category'], 'followup');
    await room.close();
  });

  for (final (control, state) in [('修琴取消了', 'cancelled'), ('修琴改期，时间还没定', 'postponed')]) {
    // A plan change is now the model's tool call on the card it was shown,
    // not a phrase the room recognizes itself. The chat turn costs its own
    // receipts; the memory question costs nothing.
    testWidgets('a pending memory question yields to $state through the real composer', (tester) async {
      final chats = <Map<String, Object?>>[];
      final room = _Room(tester, root)
        ..answer = (body) async {
          if (_requestKind(body) == 'followup') {
            return _conversationReply(body);
          }
          chats.add(body);
          if (chats.length == 1) {
            expect(jsonEncode(body['messages']), contains(_cardId!));
            return _toolUse('call-plan', state == 'cancelled' ? 'cancel' : 'postpone', {'card': _cardId!});
          }
          final results = (((body['messages']! as List).last as Map)['content']! as List).cast<Map>();
          expect(results.single['tool_use_id'], 'call-plan');
          expect(jsonDecode(results.single['content']! as String), containsPair('applied', true));
          return _generated('好，那就不问啦。');
        };
      await room.open(seed: _seedFollowup);
      _cardId = room.memory.store.cards().single['id']! as String;
      await room.wait(const Duration(seconds: 15));
      expect(room.memory.store.followups().single['state'], 'pending');
      await tester.enterText(find.byType(TextField), control);
      await tester.pump();
      await tester.tap(find.byIcon(AppIcons.send).last);
      await room.settle();
      expect(chats, hasLength(2));
      expect(room.memory.store.cards().single['plan_state'], state);
      await room.wait(const Duration(minutes: 2));
      expect(find.text(_followup), findsNothing);
      expect(room.memory.store.initiativeRecord()!['signalAtMs'], isEmpty);
      expect(room.memory.store.requests().where((row) => row['category'] == 'followup'), isEmpty);
      expect(room.memory.store.cards().single['plan_state'], state, reason: 'the later extraction keeps the plan');
      expect(room.requests.where((body) => body['system'] == companionMemoryFollowupPrompt), isEmpty);
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
    // The framework only accepts the real path from resumed to paused.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
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
